import XCTest
@preconcurrency import Shared
@testable import iosApp

/// I-1 (durable tool-execution boundary) coverage: see
/// `docs/IOS_AGENT_HARDENING_PLAN_2026-07-29.md` §W1. Two layers, mirroring
/// `IOSToolArgumentsFailClosedTests`' style (own self-contained fixtures, no
/// cross-file coupling to another test class' privates):
///
///  1. `IOSAgentToolEngine.executeBatch`'s ledger hook — ordering (Started
///     before the executor, Finished after) and the fail-closed gate (a
///     Started write failure must stop the executor from ever being called),
///     exercised via the public `executePreExistingToolsOnly` entry point so
///     no scripted provider/model turn is needed.
///  2. `IOSAgentRunLedger` itself — seq monotonicity across a simulated app
///     relaunch (a fresh ledger instance sharing the same underlying Room DB),
///     and that a real write round-trips through `listEventsForRun` with the
///     expected shape.
final class IOSToolBoundaryTests: XCTestCase {

    // MARK: - Fixtures (mirrors IOSToolArgumentsFailClosedTests' style)

    private func toolPart(toolCallId: String, toolName: String, input: String) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: toolCallId,
            toolName: toolName,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    private func toolCallMessage(toolCallId: String, toolName: String, input: String) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [toolPart(toolCallId: toolCallId, toolName: toolName, input: input)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    /// The engine must never call this for `executePreExistingToolsOnly` —
    /// that path only drives pre-existing tool calls through `executeBatch`,
    /// never a fresh model turn.
    private final class UnusedProvider: IOSAgentTextProvider, @unchecked Sendable {
        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            XCTFail("provider must not be invoked by executePreExistingToolsOnly")
            throw NSError(domain: "IOSToolBoundaryTests", code: 1)
        }
    }

    /// Records every call so a test can assert whether (and with what
    /// arguments) the executor was ever reached. Optionally appends to a
    /// shared `TestEventLog` so ordering relative to ledger writes can be
    /// asserted across two independently-injected test doubles.
    private final class RecordingExecutor: IOSToolExecutor {
        private(set) var calls: [(name: String, arguments: String, isUserInitiated: Bool)] = []
        private let result: IOSAgentToolOutcome
        private let log: TestEventLog?

        init(_ result: IOSAgentToolOutcome = .filled("{\"ok\":true}"), log: TestEventLog? = nil) {
            self.result = result
            self.log = log
        }

        func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
            calls.append((name, arguments, isUserInitiated))
            log?.record("executor:\(name)")
            return result
        }
    }

    /// Thread-unsafe-by-design event log for ordering assertions: the engine
    /// only ever awaits one ledger/executor call at a time inside
    /// `executeBatch` (no concurrent tool execution within one batch), so a
    /// plain array under a lock is enough — no need for an actor.
    private final class TestEventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var events: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func record(_ event: String) {
            lock.lock(); defer { lock.unlock() }
            storage.append(event)
        }
    }

    /// Spy ledger: records every call, optionally mirrors them into a shared
    /// `TestEventLog`, and can be told to fail `recordToolCallStarted` to
    /// exercise the fail-closed gate without touching the real Room DB.
    private final class SpyLedger: IOSAgentRunLedgering, @unchecked Sendable {
        private(set) var preparedCalls: [(runId: String, toolCallId: String)] = []
        private(set) var startedCalls: [(runId: String, toolCallId: String, toolName: String, argsDigest: String, effectClass: IOSToolEffectClass)] = []
        private(set) var finishedCalls: [(runId: String, toolCallId: String, outcome: String)] = []
        private(set) var approvalDeniedCalls: [(runId: String, toolCallId: String, toolName: String)] = []
        private let startResult: Bool
        private let terminalResult: Bool
        private let log: TestEventLog?

        init(startResult: Bool = true, terminalResult: Bool = true, log: TestEventLog? = nil) {
            self.startResult = startResult
            self.terminalResult = terminalResult
            self.log = log
        }

        func recordToolCallPrepared(
            runId: String,
            toolCallId: String,
            toolName: String,
            argsDigest: String,
            effectClass: IOSToolEffectClass
        ) async -> IOSToolTransactionPreparation {
            preparedCalls.append((runId, toolCallId))
            log?.record("prepared:\(toolCallId)")
            return .ready
        }

        func recordToolCallStarted(
            runId: String,
            toolCallId: String,
            toolName: String,
            argsDigest: String,
            effectClass: IOSToolEffectClass
        ) async -> Bool {
            startedCalls.append((runId, toolCallId, toolName, argsDigest, effectClass))
            log?.record("started:\(toolCallId)")
            return startResult
        }

        func recordToolCallFinished(
            runId: String,
            toolCallId: String,
            outcome: String
        ) async -> Bool {
            await recordToolCallFinished(
                runId: runId, toolCallId: toolCallId, outcome: outcome,
                artifactId: nil, artifactVersion: nil, outcomeKind: nil, errorCode: nil, sourceRef: nil
            )
        }

        func recordToolCallFinished(
            runId: String,
            toolCallId: String,
            outcome: String,
            artifactId: String? = nil,
            artifactVersion: String? = nil,
            outcomeKind: String? = nil,
            errorCode: String? = nil,
            sourceRef: String? = nil
        ) async -> Bool {
            finishedCalls.append((runId, toolCallId, outcome))
            log?.record("finished:\(toolCallId):\(outcome)")
            return terminalResult
        }

        func recordApprovalDenied(
            runId: String,
            toolCallId: String,
            toolName: String,
            reason: String,
            capabilityId: String?
        ) async {
            approvalDeniedCalls.append((runId, toolCallId, toolName))
            log?.record("approvalDenied:\(toolCallId)")
        }
    }

    // MARK: - Layer 1: IOSAgentToolEngine.executeBatch ledger hook

    func testEngineRecordsStartedBeforeExecutorAndFinishedAfterOnCompletion() async {
        let log = TestEventLog()
        let ledger = SpyLedger(log: log)
        let executor = RecordingExecutor(.filled("{\"ok\":true}"), log: log)
        let engine = IOSAgentToolEngine(
            provider: UnusedProvider(),
            executors: ["test_tool": executor],
            ledger: ledger,
            ledgerRunId: "run-order-1"
        )

        let result = await engine.executePreExistingToolsOnly(messages: [
            toolCallMessage(toolCallId: "tc-1", toolName: "test_tool", input: "{}"),
        ])

        XCTAssertEqual(
            log.events,
            ["prepared:tc-1", "started:tc-1", "executor:test_tool", "finished:tc-1:completed"],
            "Prepared and Started must land before the executor runs; Finished only after it returns"
        )
        XCTAssertEqual(ledger.preparedCalls.first?.toolCallId, "tc-1")
        XCTAssertEqual(ledger.startedCalls.first?.toolCallId, "tc-1")
        XCTAssertEqual(ledger.startedCalls.first?.toolName, "test_tool")
        XCTAssertEqual(ledger.startedCalls.first?.effectClass, .sideEffect, "unknown tool name must default to the fail-safe sideEffect class")
        XCTAssertEqual(ledger.finishedCalls.first?.outcome, "completed")
        let toolPart = result.messages.first?.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertEqual(toolPart?.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.first, "{\"ok\":true}")
    }

    func testEngineDoesNotInvokeExecutorWhenLedgerFailsToRecordStart() async {
        let ledger = SpyLedger(startResult: false)
        let executor = RecordingExecutor(.filled("{\"ok\":true}"))
        let engine = IOSAgentToolEngine(
            provider: UnusedProvider(),
            executors: ["test_tool": executor],
            ledger: ledger,
            ledgerRunId: "run-fail-1"
        )

        let result = await engine.executePreExistingToolsOnly(messages: [
            toolCallMessage(toolCallId: "tc-1", toolName: "test_tool", input: "{}"),
        ])

        XCTAssertEqual(executor.calls.count, 0, "the executor must never run when the ledger could not durably record Started (I-1)")
        XCTAssertEqual(ledger.finishedCalls.count, 0, "no Finished is written for a tool that never ran")
        let toolPart = result.messages.first?.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        let outputText = toolPart?.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.first ?? ""
        XCTAssertTrue(outputText.contains("tool_ledger_write_failed"), "output was: \(outputText)")
        // F5 fix: `ChatToolOutputFormatter.failureReason` only recognizes
        // failure via `"ok":false`/`"denied"`/`"status"`/`"exit_code"` fields —
        // without an explicit `"ok":false`, this ledger-write-failure notice
        // rendered as an ordinary "succeeded" step in the tool timeline.
        XCTAssertTrue(outputText.contains("\"ok\":false"), "output was: \(outputText)")
    }

    func testEngineStopsWithoutPublishingToolOutputWhenTerminalCannotPersist() async {
        let ledger = SpyLedger(terminalResult: false)
        let executor = RecordingExecutor(.filled("{\"ok\":true}"))
        let engine = IOSAgentToolEngine(
            provider: UnusedProvider(),
            executors: ["test_tool": executor],
            ledger: ledger,
            ledgerRunId: "run-terminal-fail-1"
        )

        let result = await engine.executePreExistingToolsOnly(messages: [
            toolCallMessage(toolCallId: "tc-1", toolName: "test_tool", input: "{}"),
        ])

        XCTAssertEqual(executor.calls.count, 1, "the executor returned before the terminal write failed")
        XCTAssertEqual(result.durabilityFailureMessage, "tool result ledger write failed")
        let toolPart = result.messages.first?.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertTrue(toolPart?.output.isEmpty == true, "an uncommitted result must not enter the transcript")
    }

    func testEngineWithoutALedgerRunsNormallyAndWritesNothing() async {
        // Default `ledger: nil` (SubAgent/Novel path) must be a complete no-op:
        // zero ledger traffic, tool executes exactly as before W1.
        let executor = RecordingExecutor(.filled("{\"ok\":true}"))
        let engine = IOSAgentToolEngine(
            provider: UnusedProvider(),
            executors: ["test_tool": executor]
        )

        let result = await engine.executePreExistingToolsOnly(messages: [
            toolCallMessage(toolCallId: "tc-1", toolName: "test_tool", input: "{}"),
        ])

        XCTAssertEqual(executor.calls.count, 1)
        let toolPart = result.messages.first?.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertEqual(toolPart?.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.first, "{\"ok\":true}")
    }

    /// Sendable projection of the fields these tests need from
    /// `AgentEventEntity`. `listEventsForRun`'s completion handler hands back a
    /// non-Sendable KMP `[AgentEventEntity]`; per `AgentRuntimeDaoListAllRunsTests`'
    /// established pattern, everything needed must be extracted INSIDE the
    /// callback before resuming the continuation, rather than crossing the
    /// isolation boundary with the raw list.
    private struct LedgerEventFixture: Sendable {
        let type: String
        let seq: Int64
        let agentDescriptorId: String
        let agentVersion: String
        let payloadSchemaVersion: Int
        let isFinal: Bool
        let payload: String
    }

    private func fetchLedgerEvents(dao: AgentRuntimeDao, runId: String) async -> [LedgerEventFixture] {
        await withCheckedContinuation { continuation in
            dao.listEventsForRun(id: runId) { result, _ in
                let projected = (result ?? []).map {
                    LedgerEventFixture(
                        type: $0.type,
                        seq: $0.seq,
                        agentDescriptorId: $0.agentDescriptorId,
                        agentVersion: $0.agentVersion,
                        payloadSchemaVersion: Int($0.payloadSchemaVersion),
                        isFinal: $0.isFinal,
                        payload: $0.payload
                    )
                }
                continuation.resume(returning: projected)
            }
        }
    }

    private func insertRunningRun(dao: AgentRuntimeDao, runId: String) async throws {
        let run = AgentRunEntity(
            runId: runId, parentRunId: nil,
            agentDescriptorId: IOSDurableRunStore.Descriptor.chat,
            agentVersion: IOSDurableRunStore.Descriptor.chatVersion,
            conversationId: nil, messageNodeId: nil, producesMessageId: nil, assistantId: nil,
            status: "running", inputDigest: "digest", inputSnapshotRef: nil,
            inputSchemaVersion: 1, startedAt: 1, finishedAt: nil, interruptedReason: nil,
            terminalReason: nil, providerId: nil, modelId: nil, promptVersion: nil,
            toolCatalogVersion: nil, capabilitySnapshot: nil
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dao.insertRunIfAbsent(run: run) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func makeDatabase(_ name: String = #function) -> AgentRuntimeDatabase {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).db")
            .path
        return IosDatabaseFactory.shared.createDatabase(atFilePath: path)
    }

    // MARK: - Layer 2: IOSAgentRunLedger (real Room writes)

    func testPreparedClaimAllowsOnlyOneLedgerInstanceToOwnAToolCall() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let runId = "tool-claim-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)
        let foreground = IOSAgentRunLedger(dao: dao)
        let background = IOSAgentRunLedger(dao: dao)

        let first = await foreground.recordToolCallPrepared(
            runId: runId,
            toolCallId: "tc-claim",
            toolName: "workspace_file_write",
            argsDigest: "digest",
            effectClass: .sideEffect
        )
        let second = await background.recordToolCallPrepared(
            runId: runId,
            toolCallId: "tc-claim",
            toolName: "workspace_file_write",
            argsDigest: "digest",
            effectClass: .sideEffect
        )

        XCTAssertEqual(first, .ready)
        guard case .blocked = second else {
            return XCTFail("the second ledger instance must not own the same run/toolCallId")
        }
        let loadedTransactions = await foreground.toolTransactions(runId: runId)
        let transactions = try XCTUnwrap(loadedTransactions)
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.state, .prepared)
        let claimEvents = await fetchLedgerEvents(dao: dao, runId: runId)
        let eventTypes = claimEvents.map(\.type)
        XCTAssertEqual(eventTypes, ["tool_prepared"])
    }

    func testEventAppendFailureReconcilesTransactionsThatNeverExecuted() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let runId = "missing-run-\(UUID().uuidString)"
        let ledger = IOSAgentRunLedger(dao: dao)

        let preparation = await ledger.recordToolCallPrepared(
            runId: runId,
            toolCallId: "tc-prepared",
            toolName: "search_web",
            argsDigest: "digest-prepared",
            effectClass: .pure
        )
        guard case .blocked = preparation else {
            return XCTFail("missing run must make tool_prepared append fail closed")
        }

        let startedTransaction = AgentToolTransactionEntity(
            runId: runId,
            toolCallId: "tc-started",
            toolName: "search_web",
            argsDigest: "digest-started",
            effectClass: IOSToolEffectClass.pure.rawValue,
            state: IOSToolTransactionState.prepared.rawValue,
            outcome: nil,
            resultPayload: nil,
            updatedAt: 1
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dao.insertToolTransactionIfAbsent(transaction: startedTransaction) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let started = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-started",
            toolName: "search_web",
            argsDigest: "digest-started",
            effectClass: .pure
        )
        XCTAssertFalse(started, "missing run must make tool_started append fail closed")

        let loadedTransactions = await ledger.toolTransactions(runId: runId)
        let transactions = try XCTUnwrap(loadedTransactions)
        let prepared = try XCTUnwrap(transactions.first { $0.toolCallId == "tc-prepared" })
        XCTAssertEqual(prepared.state, .reconciled)
        XCTAssertEqual(prepared.outcome, "not_executed_prepared_event_failed")
        let startedRow = try XCTUnwrap(transactions.first { $0.toolCallId == "tc-started" })
        XCTAssertEqual(startedRow.state, .reconciled)
        XCTAssertEqual(startedRow.outcome, "not_executed_started_event_failed")
        let events = await fetchLedgerEvents(dao: dao, runId: runId)
        XCTAssertTrue(events.isEmpty)
    }

    func testSeqIsMonotonicAcrossLedgerInstancesSharingTheSameRun() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let runId = "w1-seq-test-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)

        let ledgerBeforeRelaunch = IOSAgentRunLedger(dao: dao)
        let startedOk = await ledgerBeforeRelaunch.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-1",
            toolName: "search_web",
            argsDigest: "digest-1",
            effectClass: .pure
        )
        XCTAssertTrue(startedOk)
        await ledgerBeforeRelaunch.recordToolCallFinished(runId: runId, toolCallId: "tc-1", outcome: "completed")

        // Simulate the app relaunching mid-run: a brand-new ledger instance
        // with no in-memory seq counter, sharing the same underlying DB (the
        // real production scenario — both instances share this test's same
        // isolated on-disk database, while holding no in-memory seq state).
        let ledgerAfterRelaunch = IOSAgentRunLedger(dao: dao)
        let startedOk2 = await ledgerAfterRelaunch.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-2",
            toolName: "search_web",
            argsDigest: "digest-2",
            effectClass: .pure
        )
        XCTAssertTrue(startedOk2)
        await ledgerAfterRelaunch.recordToolCallFinished(runId: runId, toolCallId: "tc-2", outcome: "completed")

        let events = await fetchLedgerEvents(dao: dao, runId: runId)

        XCTAssertEqual(events.count, 6, "two Prepared/Started/Finished transactions across two ledger instances")
        let seqs = events.map { $0.seq }
        XCTAssertEqual(seqs, seqs.sorted(), "listEventsForRun already orders by seq ASC")
        XCTAssertEqual(Set(seqs).count, 6, "no seq collision across the simulated relaunch")
        XCTAssertEqual(seqs, [1, 2, 3, 4, 5, 6], "fresh run starts seq at 1 and increments by 1 per event, unbroken across instances")
    }

    func testRequestSnapshotIndexContinuesAcrossLedgerInstances() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let runId = "request-index-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)
        let snapshot = IOSRunRequestSnapshot(
            roundIndex: 1,
            requestDigest: "request",
            messageCount: 1,
            systemPromptDigest: "system",
            generationParamsDigest: "params",
            toolCatalogDigest: "tools",
            toolNames: [],
            providerId: "provider",
            modelId: "model",
            compactionRefs: []
        )

        let firstWriteSucceeded = await IOSAgentRunLedger(dao: dao).recordRequestSnapshot(
            runId: runId,
            snapshot: snapshot
        )
        let secondWriteSucceeded = await IOSAgentRunLedger(dao: dao).recordRequestSnapshot(
            runId: runId,
            snapshot: snapshot
        )
        XCTAssertTrue(firstWriteSucceeded)
        XCTAssertTrue(secondWriteSucceeded)

        let events = await fetchLedgerEvents(dao: dao, runId: runId)
        let indices = events.compactMap { event -> Int? in
            guard event.type == IOSAgentRunLedger.requestSnapshotEventType,
                  let data = event.payload.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(IOSRunRequestSnapshot.self, from: data) else {
                return nil
            }
            return decoded.roundIndex
        }
        XCTAssertEqual(indices, [1, 2])
    }

    /// 前台/后台协调器各持一个账本实例、写同一 runId,用户来回切 app 会让两个
    /// 实例交替写(ping-pong)。任何一侧缓存 seq 计数器都会在对侧写入后过期、
    /// 撞 (run_id, seq) 唯一索引,把无辜的切 app 升级成轮次失败——所以账本必须
    /// 现查现写。这个测试在缓存实现下第三轮必失败,锁死该回归。
    func testSeqSurvivesForegroundBackgroundPingPongBetweenTwoLiveLedgerInstances() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let runId = "w1-pingpong-test-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)

        let foreground = IOSAgentRunLedger(dao: dao)
        let background = IOSAgentRunLedger(dao: dao)

        let ok1 = await foreground.recordToolCallStarted(
            runId: runId, toolCallId: "tc-1", toolName: "search_web",
            argsDigest: "d1", effectClass: .pure
        )
        await foreground.recordToolCallFinished(runId: runId, toolCallId: "tc-1", outcome: "completed")

        let ok2 = await background.recordToolCallStarted(
            runId: runId, toolCallId: "tc-2", toolName: "search_web",
            argsDigest: "d2", effectClass: .pure
        )
        await background.recordToolCallFinished(runId: runId, toolCallId: "tc-2", outcome: "completed")

        // 回到前台:同一个(仍然活着的)前台实例再写。缓存实现在这里过期碰撞。
        let ok3 = await foreground.recordToolCallStarted(
            runId: runId, toolCallId: "tc-3", toolName: "search_web",
            argsDigest: "d3", effectClass: .pure
        )
        await foreground.recordToolCallFinished(runId: runId, toolCallId: "tc-3", outcome: "completed")

        XCTAssertTrue(ok1 && ok2 && ok3, "no Started write may fail just because the other coordinator wrote in between")

        let events = await fetchLedgerEvents(dao: dao, runId: runId)
        let seqs = events.map { $0.seq }
        XCTAssertEqual(seqs, [1, 2, 3, 4, 5, 6, 7, 8, 9], "ping-pong writes stay gapless and collision-free")
    }

    func testRealLedgerWriteRoundTripsThroughListEventsForRun() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let runId = "w1-content-test-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)
        let ledger = IOSAgentRunLedger(dao: dao)

        let started = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-1",
            toolName: "search_web",
            argsDigest: "abc123",
            effectClass: .pure
        )
        XCTAssertTrue(started)
        await ledger.recordToolCallFinished(runId: runId, toolCallId: "tc-1", outcome: "completed")

        let events = await fetchLedgerEvents(dao: dao, runId: runId)

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].type, "tool_prepared")
        XCTAssertEqual(events[1].type, "tool_started")
        XCTAssertEqual(events[2].type, "tool_finished")
        XCTAssertTrue(events[0].seq < events[1].seq)
        XCTAssertTrue(events[1].seq < events[2].seq)
        XCTAssertEqual(events[0].agentDescriptorId, "chat")
        XCTAssertEqual(events[0].agentVersion, "1")
        XCTAssertEqual(events[0].payloadSchemaVersion, 1)
        XCTAssertFalse(events[0].isFinal)

        guard let startedPayload = try? JSONSerialization.jsonObject(with: Data(events[1].payload.utf8)) as? [String: String] else {
            return XCTFail("Started payload must be a flat string dictionary, was: \(events[1].payload)")
        }
        XCTAssertEqual(startedPayload["toolCallId"], "tc-1")
        XCTAssertEqual(startedPayload["toolName"], "search_web")
        XCTAssertEqual(startedPayload["argsDigest"], "abc123")
        XCTAssertEqual(startedPayload["effectClass"], "pure")

        guard let finishedPayload = try? JSONSerialization.jsonObject(with: Data(events[2].payload.utf8)) as? [String: String] else {
            return XCTFail("Finished payload must be a flat string dictionary, was: \(events[2].payload)")
        }
        XCTAssertEqual(finishedPayload["toolCallId"], "tc-1")
        XCTAssertEqual(finishedPayload["outcome"], "completed")
    }

    func testToolTerminalRetryIsIdempotentButConflictingTerminalFails() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let runId = "tool-terminal-idempotency-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)
        let ledger = IOSAgentRunLedger(dao: dao)

        let didStart = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-1",
            toolName: "search_web",
            argsDigest: "digest",
            effectClass: .networkRead
        )
        XCTAssertTrue(didStart)
        let didFinish = await ledger.recordToolCallFinished(
            runId: runId,
            toolCallId: "tc-1",
            outcome: "completed"
        )
        XCTAssertTrue(didFinish)
        let didRepeatFinish = await ledger.recordToolCallFinished(
            runId: runId,
            toolCallId: "tc-1",
            outcome: "completed"
        )
        XCTAssertTrue(didRepeatFinish)
        let didConflictingFinish = await ledger.recordToolCallFinished(
            runId: runId,
            toolCallId: "tc-1",
            outcome: "failed"
        )
        XCTAssertFalse(didConflictingFinish)

        let transactions = await ledger.toolTransactions(runId: runId)
        let transaction = try XCTUnwrap(transactions?.first)
        XCTAssertEqual(transaction.state, .finished)
        XCTAssertEqual(transaction.outcome, "completed")
        let eventTypes = (await fetchLedgerEvents(dao: dao, runId: runId)).map(\.type)
        XCTAssertEqual(eventTypes, [
            "tool_prepared", "tool_started", "tool_finished",
        ])
    }

    // MARK: - Layer 2b: memory effect classification

    func testMemoryEffectClassificationDistinguishesReadsStableWritesAndCreates() {
        XCTAssertEqual(
            IOSToolEffectClassMapping.forToolName(
                "memory_tool",
                input: #"{"action":"read","id":1}"#
            ),
            .pure
        )
        XCTAssertEqual(
            IOSToolEffectClassMapping.forToolName(
                "memory_tool",
                input: #"{"action":"edit","id":1,"content":"updated"}"#
            ),
            .idempotent
        )
        XCTAssertEqual(
            IOSToolEffectClassMapping.forToolName(
                "memory_tool",
                input: #"{"action":"create","content":"new record"}"#
            ),
            .sideEffect,
            "create allocates a fresh memory id and must never be advertised as safely retryable"
        )
    }

    func testUnknownMemoryActionFailsClosedToSideEffect() {
        XCTAssertEqual(
            IOSToolEffectClassMapping.forChatKind(.memory, input: #"{"action":"future_action"}"#),
            .sideEffect
        )
    }

    /// Recipe runtime contract: effect class
    /// 标注审计结论的定点锁定。审计核对了每个标注 primitive 的真实实现——
    /// 本地只读工具标 pure（含 mcp_describe_tool：只读目录查询，实现注释明确
    /// "never touches the network and never mutates config"，与 mcp_list 同组）；
    /// search_web/scrape_web 是网络读取：无本地写、重放安全，但请求外泄
    /// query/URL/API key，已按审计决定升一级为 networkRead（计划 §20）；
    /// 写本地的编排/skill/MCP/exec 类必须 sideEffect；未知工具 fail-closed。
    func testAuditedEffectClassMappingIsPinned() {
        let pureLocalReads: [String] = [
            "tool_search", "tools_list", "ask_user",
            "session_search", "session_read",
            "skills_list", "use_skill", "skill_validate",
            "mcp_list", "mcp_describe_tool",
            "list_agents", "wait_agent",
            "provider_config_status",
            "theme_pack_status",
        ]
        for toolName in pureLocalReads {
            XCTAssertEqual(
                IOSToolEffectClassMapping.forToolName(toolName, input: "{}"),
                .pure,
                "\(toolName) is a local read and must stay pure"
            )
        }
        // 网络读取：出网但无本地写，重放不会双重应用——networkRead（比 pure
        // 保守一档：请求本身会把 query/URL/API key 带给第三方，晋升策略须升级）。
        for toolName in ["search_web", "scrape_web"] {
            XCTAssertEqual(
                IOSToolEffectClassMapping.forToolName(toolName, input: #"{"query":"q"}"#),
                .networkRead,
                "\(toolName) is a network read: retry-safe but egressing, must stay networkRead"
            )
        }
        let sideEffects: [String] = [
            "workspace_file_write", "workspace_file_edit", "workspace_file_move",
            "workspace_artifact_delete", "ios_ish_execute", "ish_handoff",
            "wm_open", "wm_site_remove", "generate_image", "mcp_call",
            "mcp_test", "mcp_import_from_skill", "skill_import", "soul_import", "skill_enable",
            "skill_disable", "subagent_dispatch", "model_council_run",
            "spawn_agent", "interrupt_agent", "send_message", "followup_task",
            "exec", "wait",
            "provider_config_apply", "provider_config_create",
            "provider_refresh_models", "settings_set_model_slot",
            "theme_pack_import",
        ]
        for toolName in sideEffects {
            XCTAssertEqual(
                IOSToolEffectClassMapping.forToolName(toolName, input: "{}"),
                .sideEffect,
                "\(toolName) mutates or egresses and must stay sideEffect"
            )
        }
        XCTAssertEqual(
            IOSToolEffectClassMapping.forToolName("not_a_real_tool", input: "{}"),
            .sideEffect,
            "unknown tool names must fail closed to sideEffect"
        )
    }

}
