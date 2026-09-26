import XCTest
@preconcurrency import Shared
@testable import iosApp

/// I-3 (§W3, "把结果未知交给用户") coverage: see
/// `docs/IOS_AGENT_HARDENING_PLAN_2026-07-29.md` §W3. Two layers, mirroring
/// `IOSToolBoundaryTests`' style (own self-contained fixtures):
///
///  1. Pure functions — `IOSToolCallLedgerRow.decode`, `IOSToolCallRecoveryPlanner.plan`,
///     `IOSToolCallRecoveryApplier.apply` — no I/O, exercised directly against
///     hand-built event/message fixtures.
///  2. Integration — real Room ledger writes (`IOSAgentRunLedger`) + a real
///     `IOSConversationStore`, driving `IOSRunRecovery.planToolCallRecovery`
///     end to end and asserting the persisted tool part + `nextPendingToolCall`
///     reachability, per `AgentRuntimeDaoListAllRunsTests`/`IOSConversationStoreTests`'
///     established DB/store construction pattern.
///
/// All three `IOSToolCallRecoveryAction` states write a structured `output`
/// (§ review correction 2026-07-29): `groupPartsByToolBoundary`
/// (`ai-core/.../ProviderMessageUtils.kt:46`) only treats `isExecuted`
/// (output non-empty) Tool parts as boundaries — an empty-output Tool part is
/// silently dropped from the next provider request, so a call left with empty
/// output does not "auto-retry", it vanishes from the model's view. Handing
/// the "not executed, safe to retry" state back to the model as text (same
/// W2 fail-closed philosophy: state goes back to the model, never silently
/// discarded) is what makes retry mechanically real.
final class IOSToolRecoveryTests: XCTestCase {

    // MARK: - Fixtures

    private func toolPart(toolCallId: String, toolName: String = "ask_user", output: [UIMessagePart] = []) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: toolCallId,
            toolName: toolName,
            input: "{}",
            output: output,
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    private func toolCallMessage(toolCallId: String, toolName: String = "ask_user", output: [UIMessagePart] = []) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [toolPart(toolCallId: toolCallId, toolName: toolName, output: output)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    private func startedPayload(effectClass: String?) -> String {
        var fields = ["toolCallId": "tc-1"]
        if let effectClass { fields["effectClass"] = effectClass }
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func finishedPayload(toolCallId: String = "tc-1", outcome: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["toolCallId": toolCallId, "outcome": outcome], options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    @MainActor
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

    // MARK: - Layer 1a: IOSToolCallLedgerRow.decode (payload parse tolerance)

    func testDecodeDropsRowWithMissingToolCallId() {
        let payload = "{\"effectClass\":\"pure\"}"
        XCTAssertNil(IOSToolCallLedgerRow.decode(type: "tool_call_started", seq: 1, payload: payload))
    }

    func testDecodeDropsRowWithUnparsableJson() {
        XCTAssertNil(IOSToolCallLedgerRow.decode(type: "tool_call_started", seq: 1, payload: "not json at all"))
    }

    func testDecodeDefaultsCorruptEffectClassToSideEffect() {
        let payload = startedPayload(effectClass: "not_a_real_class")
        guard let row = IOSToolCallLedgerRow.decode(type: "tool_call_started", seq: 1, payload: payload) else {
            return XCTFail("Expected a row with a recoverable toolCallId")
        }
        XCTAssertEqual(row.effectClass, .sideEffect, "corrupt/unrecognized effectClass must fail-closed to sideEffect, never be dropped or guessed pure/idempotent")
    }

    func testDecodeMissingEffectClassOnStartedDefaultsToSideEffect() {
        let payload = startedPayload(effectClass: nil)
        guard let row = IOSToolCallLedgerRow.decode(type: "tool_call_started", seq: 1, payload: payload) else {
            return XCTFail("Expected a row with a recoverable toolCallId")
        }
        XCTAssertEqual(row.effectClass, .sideEffect)
    }

    func testDecodeFinishedRowCarriesOutcomeAndNoEffectClass() {
        let payload = finishedPayload(outcome: "completed")
        guard let row = IOSToolCallLedgerRow.decode(type: "tool_call_finished", seq: 2, payload: payload) else {
            return XCTFail("Expected a decodable Finished row")
        }
        XCTAssertEqual(row.outcome, "completed")
        XCTAssertNil(row.effectClass, "effectClass is only meaningful on Started rows")
    }

    // MARK: - Layer 1b: IOSToolCallRecoveryPlanner.plan (three states + narratives)

    func testPlanMarksUnresolvedSideEffectAsMarkUnknown() {
        let rows = [IOSToolCallLedgerRow(toolCallId: "tc-1", type: "tool_call_started", seq: 1, effectClass: .sideEffect, outcome: nil)]
        let actions = IOSToolCallRecoveryPlanner.plan(rows: rows) { _ in true }
        XCTAssertEqual(actions["tc-1"], .markUnknown)
    }

    func testPlanMarksUnresolvedPureAsRetryable() {
        let rows = [IOSToolCallLedgerRow(toolCallId: "tc-1", type: "tool_call_started", seq: 1, effectClass: .pure, outcome: nil)]
        let actions = IOSToolCallRecoveryPlanner.plan(rows: rows) { _ in true }
        XCTAssertEqual(actions["tc-1"], .markRetryable)
    }

    func testPlanMarksUnresolvedIdempotentAsRetryable() {
        let rows = [IOSToolCallLedgerRow(toolCallId: "tc-1", type: "tool_call_started", seq: 1, effectClass: .idempotent, outcome: nil)]
        let actions = IOSToolCallRecoveryPlanner.plan(rows: rows) { _ in true }
        XCTAssertEqual(actions["tc-1"], .markRetryable)
    }

    func testPlanProducesNoActionForPausedForApprovalNarrative() {
        // Single Started -> Finished(paused_for_approval): the awaiting-approval
        // hand-off, already owned by IOSRunRecovery's pending-approval path.
        let rows = [
            IOSToolCallLedgerRow(toolCallId: "tc-1", type: "tool_call_started", seq: 1, effectClass: .sideEffect, outcome: nil),
            IOSToolCallLedgerRow(toolCallId: "tc-1", type: "tool_call_finished", seq: 2, effectClass: nil, outcome: "paused_for_approval"),
        ]
        let actions = IOSToolCallRecoveryPlanner.plan(rows: rows) { _ in true }
        XCTAssertTrue(actions.isEmpty, "a genuinely-still-pending approval must not get a recovery action of its own")
    }

    func testPlanPairsAgainstTheLastStartedForApprovedThenCrashedNarrative() {
        // Started -> Finished(paused) -> Started (re-executed after approval,
        // still in flight when the process died) -> no Finished. Must classify
        // against the SECOND Started, not the first (already-resolved) pair.
        let rows = [
            IOSToolCallLedgerRow(toolCallId: "tc-1", type: "tool_call_started", seq: 1, effectClass: .sideEffect, outcome: nil),
            IOSToolCallLedgerRow(toolCallId: "tc-1", type: "tool_call_finished", seq: 2, effectClass: nil, outcome: "paused_for_approval"),
            IOSToolCallLedgerRow(toolCallId: "tc-1", type: "tool_call_started", seq: 3, effectClass: .sideEffect, outcome: nil),
        ]
        let actions = IOSToolCallRecoveryPlanner.plan(rows: rows) { _ in true }
        XCTAssertEqual(actions["tc-1"], .markUnknown, "approved-then-crashed side effect must be markUnknown, not left as a plain pending-approval cancellation")
    }

    func testPlanMarksCleanCompletedWithEmptyPersistedOutputAsResultLost() {
        let rows = [
            IOSToolCallLedgerRow(toolCallId: "tc-1", type: "tool_call_started", seq: 1, effectClass: .sideEffect, outcome: nil),
            IOSToolCallLedgerRow(toolCallId: "tc-1", type: "tool_call_finished", seq: 2, effectClass: nil, outcome: "completed"),
        ]
        let actions = IOSToolCallRecoveryPlanner.plan(rows: rows) { toolCallId in toolCallId == "tc-1" }
        XCTAssertEqual(actions["tc-1"], .markResultLost)
    }

    func testPlanProducesNoActionForCleanCompletedWithNonEmptyPersistedOutput() {
        let rows = [
            IOSToolCallLedgerRow(toolCallId: "tc-1", type: "tool_call_started", seq: 1, effectClass: .sideEffect, outcome: nil),
            IOSToolCallLedgerRow(toolCallId: "tc-1", type: "tool_call_finished", seq: 2, effectClass: nil, outcome: "completed"),
        ]
        let actions = IOSToolCallRecoveryPlanner.plan(rows: rows) { _ in false }
        XCTAssertTrue(actions.isEmpty, "result already on disk — nothing to reconcile")
    }

    func testPlanIgnoresToolCallIdThatWasNeverStarted() {
        let actions = IOSToolCallRecoveryPlanner.plan(rows: []) { _ in true }
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - Layer 1c: IOSToolCallRecoveryApplier.apply
    //
    // One code path for all three states now (§ review correction): every
    // action writes a structured, distinguishable `output`. These tests
    // assert both "output got written" (the mechanism) and "each state's
    // text is actually distinct" (so the model/user can tell them apart).

    func testApplyWritesStructuredMarkerForMarkUnknown() {
        let messages = [toolCallMessage(toolCallId: "tc-1", toolName: "workspace_write")]
        let result = IOSToolCallRecoveryApplier.apply(["tc-1": .markUnknown], to: messages)
        let toolPart = result.first?.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertFalse(toolPart?.output.isEmpty ?? true, "markUnknown must write a non-empty output so it can never be picked up as still-pending")
        let text = toolPart?.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.first ?? ""
        XCTAssertEqual(ChatToolOutputFormatter.failureReason(from: toolPart?.output ?? []), IOSToolCallRecoveryAction.markUnknown.toolPartMessage)
        XCTAssertTrue(text.contains("\"ok\":false"))
        XCTAssertTrue(IOSToolCallRecoveryAction.markUnknown.toolPartMessage.contains("是否已生效未知"))
    }

    func testApplyWritesStructuredMarkerForMarkRetryable() {
        let messages = [toolCallMessage(toolCallId: "tc-1", toolName: "search_web")]
        let result = IOSToolCallRecoveryApplier.apply(["tc-1": .markRetryable], to: messages)
        let toolPart = result.first?.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertFalse(toolPart?.output.isEmpty ?? true, "markRetryable must ALSO write output — an empty-output Tool part is dropped by groupPartsByToolBoundary, not auto-retried")
        XCTAssertEqual(ChatToolOutputFormatter.failureReason(from: toolPart?.output ?? []), IOSToolCallRecoveryAction.markRetryable.toolPartMessage)
        XCTAssertTrue(IOSToolCallRecoveryAction.markRetryable.toolPartMessage.contains("可安全重试"))
    }

    func testApplyWritesStructuredMarkerForMarkResultLost() {
        let messages = [toolCallMessage(toolCallId: "tc-1", toolName: "workspace_write")]
        let result = IOSToolCallRecoveryApplier.apply(["tc-1": .markResultLost], to: messages)
        let toolPart = result.first?.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertEqual(ChatToolOutputFormatter.failureReason(from: toolPart?.output ?? []), IOSToolCallRecoveryAction.markResultLost.toolPartMessage)
        XCTAssertTrue(IOSToolCallRecoveryAction.markResultLost.toolPartMessage.contains("结果在应用中断中丢失"))
    }

    func testApplyIgnoresActionForToolCallIdNotFoundOrAlreadyResolved() {
        let messages = [toolCallMessage(toolCallId: "tc-1", toolName: "ask_user", output: [UIMessagePart.Text(text: "already resolved", metadata: nil)])]
        let result = IOSToolCallRecoveryApplier.apply(["tc-1": .markUnknown, "tc-missing": .markUnknown], to: messages)
        XCTAssertEqual(result, messages, "an already-resolved or missing toolCallId must be left completely untouched")
    }

    func testApplyPreservesPromptTranscriptMetadataWhenReplacingToolOutput() {
        let user = UIMessage.companion.user(prompt: "继续")
        let request = PromptTranscript.shared.prepare(
            canonicalMessages: [user],
            preparedMessages: [
                PromptTranscript.shared.sectionMessage(name: "system", text: "继承的提示"),
                user,
            ],
            tools: []
        )
        let recorded = PromptTranscript.shared.recordResponse(
            message: toolCallMessage(toolCallId: "tc-1", toolName: "ask_user"),
            request: request
        )
        XCTAssertNotNil(PromptTranscript.shared.event(message: recorded))

        let recovered = IOSToolCallRecoveryApplier.apply(["tc-1": .markUnknown], to: [recorded])
        XCTAssertNotNil(
            PromptTranscript.shared.event(message: try! XCTUnwrap(recovered.first)),
            "tool-result recovery must retain the prompt transition metadata on the assistant message"
        )
    }

    // MARK: - Layer 2: integration (real Room ledger + real IOSConversationStore)

    @MainActor
    private func makeConversationStore() -> IOSConversationStore {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSToolRecoveryTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return IOSConversationStore(baseDirectory: baseDirectory)
    }

    private func makeDatabase(_ name: String = #function) -> AgentRuntimeDatabase {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).db")
            .path
        return IosDatabaseFactory.shared.createDatabase(atFilePath: path)
    }

    @MainActor
    private func makeRuntime() -> ChatToolRuntime {
        ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(),
            localToolExecutor: nil,
            searchTransport: MockRecoveryTestSearchTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
    }

    @MainActor
    func testRecoverySweepMarksSideEffectUnknownAndBlocksNextPendingToolCall() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "w3-sideeffect-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)

        // Crashed mid-execution: Started with no Finished after it.
        let started = await ledger.recordToolCallStarted(
            runId: runId, toolCallId: "tc-1", toolName: "ish_run",
            argsDigest: "d1", effectClass: .sideEffect
        )
        XCTAssertTrue(started)

        let store = makeConversationStore()
        await store.bootstrap()
        await store.saveCurrent(messages: [toolCallMessage(toolCallId: "tc-1", toolName: "ish_run")])
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let rawMessages = await store.messages(for: conversationId)
        let messages = try XCTUnwrap(rawMessages)

        let plannedActions = await IOSRunRecovery.planToolCallRecovery(
            runId: runId,
            messages: messages,
            dao: dao
        )
        let actions = try XCTUnwrap(plannedActions)
        XCTAssertEqual(actions["tc-1"], .markUnknown)
        let loadedUnknownTransactions = await ledger.toolTransactions(runId: runId)
        let unknownTransactions = try XCTUnwrap(loadedUnknownTransactions)
        XCTAssertEqual(unknownTransactions.first?.state, .outcomeUnknown)
        XCTAssertEqual(unknownTransactions.first?.outcome, "process_interrupted")

        let recovered = IOSToolCallRecoveryApplier.apply(actions, to: messages)
        await store.saveCurrent(messages: recovered)

        let rawReloaded = await store.messages(for: conversationId)
        let reloaded = try XCTUnwrap(rawReloaded)
        let runtime = makeRuntime()
        XCTAssertTrue(runtime.hasUnresolvedToolCall(in: messages), "sanity: before recovery the call is still open")
        XCTAssertFalse(runtime.hasUnresolvedToolCall(in: reloaded), "after markUnknown the call must never again be found as pending — I-3, never auto-rerun")
    }

    @MainActor
    func testTransactionRecoverySynthesizesMissingToolPartWithoutReexecution() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "w3-missing-message-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)
        let started = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-missing",
            toolName: "workspace_write",
            argsDigest: "d1",
            effectClass: .sideEffect
        )
        XCTAssertTrue(started)

        let loadedPlan = await IOSRunRecovery.planToolCallRecovery(
            runId: runId,
            messages: [],
            dao: dao
        )
        let plan = try XCTUnwrap(loadedPlan)
        XCTAssertEqual(plan["tc-missing"], .markUnknown)

        let recovered = IOSToolCallRecoveryApplier.apply(plan, to: [])
        let toolPart = recovered.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertEqual(toolPart?.toolCallId, "tc-missing")
        XCTAssertEqual(toolPart?.toolName, "workspace_write")
        XCTAssertEqual(
            ChatToolOutputFormatter.failureReason(from: toolPart?.output ?? []),
            IOSToolCallRecoveryAction.markUnknown.toolPartMessage
        )
    }

    @MainActor
    func testWaitingApprovalIsClosedAsNotExecutedAfterProcessInterruption() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "w3-waiting-approval-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)
        let started = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-approval",
            toolName: "workspace_write",
            argsDigest: "d1",
            effectClass: .sideEffect
        )
        XCTAssertTrue(started)
        await ledger.recordToolCallTerminal(
            runId: runId,
            toolCallId: "tc-approval",
            outcome: "paused_for_approval",
            resultPayload: nil
        )

        let loadedPlan = await IOSRunRecovery.planToolCallRecovery(
            runId: runId,
            messages: [],
            dao: dao
        )
        let plan = try XCTUnwrap(loadedPlan)
        XCTAssertEqual(plan["tc-approval"], .markApprovalInterrupted)
        let loadedTransactions = await ledger.toolTransactions(runId: runId)
        let transaction = try XCTUnwrap(loadedTransactions?.first)
        XCTAssertEqual(transaction.state, .reconciled)
        XCTAssertEqual(transaction.outcome, "process_interrupted_before_approval")

        let recovered = IOSToolCallRecoveryApplier.apply(plan, to: [])
        let output = recovered.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first?.output ?? []
        XCTAssertEqual(
            ChatToolOutputFormatter.failureReason(from: output),
            IOSToolCallRecoveryAction.markApprovalInterrupted.toolPartMessage
        )
    }

    @MainActor
    func testRecoveryMergesLegacyEventOnlyCallWithTransactionBackedCall() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "w3-mixed-ledger-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)
        let started = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-new",
            toolName: "ask_user",
            argsDigest: "d1",
            effectClass: .pure
        )
        XCTAssertTrue(started)
        _ = try await dao.insertRunEvent(
            runId: runId,
            eventId: UUID().uuidString,
            type: "tool_call_started",
            payloadType: "tool_call_started",
            payload: "{\"effectClass\":\"sideEffect\",\"toolCallId\":\"tc-legacy\"}",
            payloadSchemaVersion: 1,
            isFinal: false,
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            turnId: nil,
            stepId: nil,
            toolCallId: "tc-legacy"
        )

        let loadedPlan = await IOSRunRecovery.planToolCallRecovery(
            runId: runId,
            messages: [],
            dao: dao
        )
        let plan = try XCTUnwrap(loadedPlan)
        XCTAssertEqual(plan["tc-new"], .markRetryable)
        XCTAssertEqual(plan["tc-legacy"], .markUnknown)
    }

    @MainActor
    func testRecoverySweepMarksRetryableAndAlsoBlocksNextPendingToolCall() async throws {
        // § review correction: retryable now writes output too, so — like the
        // other two states — it must NOT be found by nextPendingToolCall
        // anymore. The retry path is model-mediated (the model reads this
        // tool's result text and decides to call it again), not app-mediated
        // replay via an empty-output Tool part.
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "w3-retryable-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)

        let started = await ledger.recordToolCallStarted(
            runId: runId, toolCallId: "tc-1", toolName: "ask_user",
            argsDigest: "d1", effectClass: .pure
        )
        XCTAssertTrue(started)

        let store = makeConversationStore()
        await store.bootstrap()
        await store.saveCurrent(messages: [toolCallMessage(toolCallId: "tc-1", toolName: "ask_user")])
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let rawMessages = await store.messages(for: conversationId)
        let messages = try XCTUnwrap(rawMessages)

        let plannedActions = await IOSRunRecovery.planToolCallRecovery(
            runId: runId,
            messages: messages,
            dao: dao
        )
        let actions = try XCTUnwrap(plannedActions)
        XCTAssertEqual(actions["tc-1"], .markRetryable)
        let loadedRetryableTransactions = await ledger.toolTransactions(runId: runId)
        let retryableTransactions = try XCTUnwrap(loadedRetryableTransactions)
        XCTAssertEqual(retryableTransactions.first?.state, .reconciled)
        XCTAssertEqual(retryableTransactions.first?.outcome, "safe_to_retry")

        let recovered = IOSToolCallRecoveryApplier.apply(actions, to: messages)
        let recoveredToolPart = recovered.first?.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertFalse(recoveredToolPart?.output.isEmpty ?? true, "markRetryable must write output, not leave it empty")
        await store.saveCurrent(messages: recovered)

        let rawReloaded = await store.messages(for: conversationId)
        let reloaded = try XCTUnwrap(rawReloaded)
        let runtime = makeRuntime()
        let pending = runtime.nextPendingToolCall(
            in: reloaded,
            availableToolNames: ["ask_user"]
        )
        XCTAssertNil(pending, "a resolved (even if 'not executed, retryable') tool part must not be re-offered by nextPendingToolCall — retry is model-mediated via the written text, not app-level replay")
    }

    @MainActor
    func testRecoverySweepMarksResultLostWhenCompletedButOutputNeverPersisted() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "w3-resultlost-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)

        let started = await ledger.recordToolCallStarted(
            runId: runId, toolCallId: "tc-1", toolName: "workspace_write",
            argsDigest: "d1", effectClass: .sideEffect
        )
        XCTAssertTrue(started)
        await ledger.recordToolCallFinished(runId: runId, toolCallId: "tc-1", outcome: "completed")

        let store = makeConversationStore()
        await store.bootstrap()
        // The tool finished per the ledger, but the turn died before its
        // result was ever written back into the persisted conversation.
        await store.saveCurrent(messages: [toolCallMessage(toolCallId: "tc-1", toolName: "workspace_write")])
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let rawMessages = await store.messages(for: conversationId)
        let messages = try XCTUnwrap(rawMessages)

        let plannedActions = await IOSRunRecovery.planToolCallRecovery(
            runId: runId,
            messages: messages,
            dao: dao
        )
        let actions = try XCTUnwrap(plannedActions)
        XCTAssertEqual(actions["tc-1"], .markResultLost)

        let recovered = IOSToolCallRecoveryApplier.apply(actions, to: messages)
        let toolPart = recovered.first?.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        XCTAssertEqual(
            ChatToolOutputFormatter.failureReason(from: toolPart?.output ?? []),
            IOSToolCallRecoveryAction.markResultLost.toolPartMessage
        )
    }

    @MainActor
    func testFinishedResultIsReplayedThenReconciledWithoutReexecution() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "tool-result-replay-\(UUID().uuidString)"
        try await insertRunningRun(dao: dao, runId: runId)
        let didStartTool = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-replay",
            toolName: "generate_image",
            argsDigest: "digest",
            effectClass: .sideEffect
        )
        XCTAssertTrue(didStartTool)
        let payload = IosToolOutputJsonBridge.shared.encode(parts: [
            UIMessagePart.Text(text: "{\"ok\":true,\"restored\":true}", metadata: nil),
        ])
        await ledger.recordToolCallTerminal(
            runId: runId,
            toolCallId: "tc-replay",
            outcome: "completed",
            resultPayload: payload
        )
        let messages = [toolCallMessage(toolCallId: "tc-replay", toolName: "generate_image")]

        let plannedActions = await IOSRunRecovery.planToolCallRecovery(
            runId: runId,
            messages: messages,
            dao: dao
        )
        let actions = try XCTUnwrap(plannedActions)
        XCTAssertEqual(actions["tc-replay"], .replayResult(payload))
        let recovered = IOSToolCallRecoveryApplier.apply(actions, to: messages)
        let restoredText = recovered
            .flatMap(\.parts)
            .compactMap { $0 as? UIMessagePart.Tool }
            .first?.output
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .first
        XCTAssertEqual(restoredText, "{\"ok\":true,\"restored\":true}")

        await IOSRunRecovery.finalizeToolCallRecovery(runId: runId, plan: actions, dao: dao)
        let loadedFinalized = await ledger.toolTransactions(runId: runId)
        let finalized = try XCTUnwrap(loadedFinalized).first
        XCTAssertEqual(finalized?.state, .reconciled)
        XCTAssertEqual(finalized?.outcome, "result_replayed")
        XCTAssertNil(finalized?.resultPayload)
    }

    @MainActor
    func testOutcomeUnknownRemainsAUserGateUntilExplicitReconciliation() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let ledger = IOSAgentRunLedger(dao: dao)
        let store = makeConversationStore()
        await store.bootstrap()
        await store.saveCurrent(messages: [toolCallMessage(toolCallId: "tc-unknown", toolName: "workspace_file_write")])
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let runId = "tool-unknown-user-gate-\(UUID().uuidString)"
        let didStartRun = try await IOSDurableRunStore(dao: dao).startChatRun(
            runId: runId,
            startedAt: 1,
            inputDigest: "digest",
            conversationId: conversationId.toHexDashString()
        )
        XCTAssertTrue(didStartRun)
        let didStartTool = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-unknown",
            toolName: "workspace_file_write",
            argsDigest: "digest",
            effectClass: .sideEffect
        )
        XCTAssertTrue(didStartTool)

        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false,
            agentRuntimeDao: dao
        )
        viewModel.conversationStore = store
        viewModel.reloadFromStore()
        let sweep = await viewModel.applyToolCallLedgerRecovery(
            forInterruptedRuns: [(runId: runId, conversationId: conversationId.toHexDashString())]
        )

        XCTAssertTrue(sweep.outcomeUnknownRunIds.contains(runId))
        XCTAssertEqual(viewModel.pendingToolOutcomeUnknown?.toolCallId, "tc-unknown")
        XCTAssertTrue(viewModel.hasPendingUserGate)
        let unknownRun = try await IOSDurableRunStore(dao: dao).snapshot(runId: runId)
        XCTAssertEqual(unknownRun?.status, .outcomeUnknown)

        await viewModel.reconcilePendingToolOutcome(didApply: true)

        XCTAssertNil(viewModel.pendingToolOutcomeUnknown)
        let loadedPersisted = await store.messages(for: conversationId)
        let persisted = try XCTUnwrap(loadedPersisted)
        let reason = ChatToolOutputFormatter.failureReason(
            from: persisted.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first?.output ?? []
        )
        XCTAssertTrue(reason?.contains("用户确认：该操作已经生效") == true)
        let loadedTransactions = await ledger.toolTransactions(runId: runId)
        let transaction = try XCTUnwrap(loadedTransactions).first
        XCTAssertEqual(transaction?.state, .reconciled)
        XCTAssertEqual(transaction?.outcome, "user_confirmed_applied")
        let interruptedRun = try await IOSDurableRunStore(dao: dao).snapshot(runId: runId)
        XCTAssertEqual(interruptedRun?.status, .interrupted)
    }

    @MainActor
    func testTwoOutcomeUnknownCallsKeepTheSecondGateAcrossReconcileRetryAndW3() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let ledger = IOSAgentRunLedger(dao: dao)
        let runStore = IOSDurableRunStore(dao: dao)
        let store = makeConversationStore()
        await store.bootstrap()
        await store.saveCurrent(messages: [
            toolCallMessage(toolCallId: "tc-1", toolName: "workspace_file_write"),
            toolCallMessage(toolCallId: "tc-2", toolName: "workspace_file_write"),
        ])
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let conversationIdString = conversationId.toHexDashString()
        let runId = "tool-unknown-two-gates-\(UUID().uuidString)"

        let didStartRun = try await runStore.startChatRun(
            runId: runId,
            startedAt: 1,
            inputDigest: "digest",
            conversationId: conversationIdString
        )
        XCTAssertTrue(didStartRun)
        let firstStarted = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-1",
            toolName: "workspace_file_write",
            argsDigest: "digest-1",
            effectClass: .sideEffect
        )
        let secondStarted = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: "tc-2",
            toolName: "workspace_file_write",
            argsDigest: "digest-2",
            effectClass: .sideEffect
        )
        XCTAssertTrue(firstStarted)
        XCTAssertTrue(secondStarted)

        let firstViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false,
            agentRuntimeDao: dao
        )
        firstViewModel.conversationStore = store
        firstViewModel.reloadFromStore()
        let firstSweep = await firstViewModel.applyToolCallLedgerRecovery(
            forInterruptedRuns: [(runId: runId, conversationId: conversationIdString)]
        )

        XCTAssertTrue(firstSweep.outcomeUnknownRunIds.contains(runId))
        XCTAssertEqual(firstViewModel.pendingToolOutcomeUnknown?.toolCallId, "tc-1")
        XCTAssertTrue(firstViewModel.hasPendingUserGate)

        await firstViewModel.reconcilePendingToolOutcome(didApply: true)
        XCTAssertEqual(firstViewModel.pendingToolOutcomeUnknown?.toolCallId, "tc-2")
        XCTAssertTrue(firstViewModel.hasPendingUserGate)

        // The same decision may be delivered again after its ledger transition
        // committed but a later read failed. It must be idempotent and leave the
        // second unknown gate in place.
        let repeatedReconcile = await IOSRunRecovery.reconcileOutcomeUnknown(
            runId: runId,
            toolCallId: "tc-1",
            didApply: true,
            dao: dao,
            runStore: runStore
        )
        XCTAssertTrue(repeatedReconcile)
        let runAfterRepeatedReconcile = try await runStore.snapshot(runId: runId)
        XCTAssertEqual(runAfterRepeatedReconcile?.status, .outcomeUnknown)
        let loadedAfterRepeatedReconcile = await ledger.toolTransactions(runId: runId)
        let transactionsAfterRepeatedReconcile = try XCTUnwrap(loadedAfterRepeatedReconcile)
        let stateByToolCallId = Dictionary(uniqueKeysWithValues: transactionsAfterRepeatedReconcile.map {
            ($0.toolCallId, $0.state)
        })
        XCTAssertEqual(stateByToolCallId["tc-1"], .reconciled)
        XCTAssertEqual(stateByToolCallId["tc-2"], .outcomeUnknown)

        // A newly composed VM must rediscover the remaining gate from Room/W3.
        let restoredViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false,
            agentRuntimeDao: dao
        )
        restoredViewModel.conversationStore = store
        restoredViewModel.reloadFromStore()
        let loadedPairs = await IOSRunRecovery.unfinishedRunConversationPairs(runStore: runStore)
        let restoredPairs = try XCTUnwrap(loadedPairs).filter { $0.runId == runId }
        XCTAssertEqual(restoredPairs.count, 1)
        let restoredSweep = await restoredViewModel.applyToolCallLedgerRecovery(
            forInterruptedRuns: restoredPairs
        )

        XCTAssertTrue(restoredSweep.outcomeUnknownRunIds.contains(runId))
        XCTAssertEqual(restoredViewModel.pendingToolOutcomeUnknown?.toolCallId, "tc-2")
        XCTAssertTrue(restoredViewModel.hasPendingUserGate)
        let runAfterW3 = try await runStore.snapshot(runId: runId)
        XCTAssertEqual(runAfterW3?.status, .outcomeUnknown)

        await restoredViewModel.reconcilePendingToolOutcome(didApply: false)
        XCTAssertNil(restoredViewModel.pendingToolOutcomeUnknown)
        let runAfterLastDecision = try await runStore.snapshot(runId: runId)
        XCTAssertEqual(runAfterLastDecision?.status, .interrupted)

        WatchTaskCoordinator.shared.clear(runId: runId)
    }

    @MainActor
    func testColdCancelRejectsRecoveryPendingRunWithUnknownLedger() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let runStore = IOSDurableRunStore(dao: dao)
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "watch-cold-cancel-unknown-\(UUID().uuidString)"
        let conversationId = "conversation-\(UUID().uuidString)"
        let toolCallId = "tc-cold-cancel"

        let didStartRun = try await runStore.startChatRun(
            runId: runId,
            startedAt: 1,
            inputDigest: "digest",
            conversationId: conversationId
        )
        XCTAssertTrue(didStartRun)
        let didMarkRecoveryPending = try await runStore.transition(
            runId: runId,
            expected: .running,
            to: .recoveryPending,
            detail: "tool_outcome_unknown"
        )
        XCTAssertTrue(didMarkRecoveryPending)
        let didStartTool = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: toolCallId,
            toolName: "workspace_file_write",
            argsDigest: "digest",
            effectClass: .sideEffect
        )
        XCTAssertTrue(didStartTool)
        let didMarkUnknown = await ledger.recordToolCallRecoveryTransition(
            runId: runId,
            toolCallId: toolCallId,
            expected: .started,
            to: .outcomeUnknown,
            outcome: "process_interrupted"
        )
        XCTAssertTrue(didMarkUnknown)

        let suite = "IOSToolRecoveryTests.WatchColdCancel.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSToolRecoveryTests-WatchColdCancel-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let service = IOSWatchCompanionService(baseDirectory: root, defaults: defaults)
        let noColdStart: WatchTaskColdStartPreparer = { nil }
        let coordinator = WatchTaskCoordinator(
            bridge: WatchConnectivityBridge(),
            companionService: service,
            coldStartPreparer: noColdStart,
            attachmentWaitNanoseconds: 0,
            agentRuntimeDao: dao
        )
        let result = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: "cold-cancel-\(UUID().uuidString)",
            runId: runId,
            conversationId: conversationId,
            decisionId: nil,
            action: .cancel,
            optionId: nil,
            text: nil,
            createdAt: Date()
        ))

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.message, "操作结果待核实，请在原 iPhone 对话中确认")
        let snapshot = coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.runId, runId)
        XCTAssertTrue(WatchTaskSnapshotBuilder.isPhoneOnlyDecision(snapshot.decision))
        let runAfterCancel = try await runStore.snapshot(runId: runId)
        XCTAssertEqual(runAfterCancel?.status, .recoveryPending)
        let loadedTransactions = await ledger.toolTransactions(runId: runId)
        let transactions = try XCTUnwrap(loadedTransactions)
        let transaction = transactions.first(where: { $0.toolCallId == toolCallId })
        XCTAssertEqual(transaction?.state, .outcomeUnknown)
    }

    // F1 fix (docs/IOS_AGENT_HARDENING_PLAN_2026-07-29.md's independent-review
    // findings): `ChatViewModel.terminateRecoveredPendingApprovals` used to
    // short-circuit — `guard let pendingTool = ... first(where: descriptor's
    // own toolCallId has empty output) else { complete; continue }` — BEFORE
    // ever calling `planToolCallRecovery`. That short-circuit fires whenever
    // the descriptor's own tool call (tc-1) already has a real, non-empty
    // output: "approve tc-1 -> it fully executes -> model immediately issues
    // tc-2 -> app dies mid tc-2 execution" leaves tc-1 resolved but tc-2
    // dangling with an open ledger Started and empty message output. The
    // run's `agent_run.status` never left `waiting_user` (approving a
    // tool never flips it back to "running" — see this function's own W3
    // comment), so AppShell's startup sweep still produces a descriptor for
    // this run, pointing at tc-1 (the run's original inputSnapshotRef). Before
    // the fix, tc-2 was never even looked at: `planToolCallRecovery` was
    // skipped entirely, and `completePendingApprovalRecovery` permanently
    // reclassified the run away from `waiting_user` — so no future
    // sweep would ever revisit it either. On next resume, `nextPendingToolCall`
    // would find tc-2 still open with empty output and silently re-fire a real
    // sideEffect tool — a direct I-3 violation.
    @MainActor
    func testTerminateRecoveredPendingApprovalsMarksDanglingSecondCallUnknownWithoutOverwritingTheFirst() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let ledger = IOSAgentRunLedger(dao: dao)
        let runId = "f1-tc2-dangling-\(UUID().uuidString)"

        let store = makeConversationStore()
        await store.bootstrap()
        await store.saveCurrent(messages: [
            toolCallMessage(toolCallId: "tc-1", toolName: "workspace_write", output: [
                UIMessagePart.Text(text: "{\"ok\":true,\"path\":\"/tmp/a\"}", metadata: nil),
            ]),
            toolCallMessage(toolCallId: "tc-2", toolName: "workspace_write"),
        ])
        let conversationId = try XCTUnwrap(store.currentConversation?.id)

        // The run row: still `waiting_user` per the I-3 doc comment —
        // approving a tool never flips status back to "running".
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let run = AgentRunEntity(
            runId: runId, parentRunId: nil, agentDescriptorId: "chat", agentVersion: "1",
            conversationId: conversationId.toHexDashString(), messageNodeId: nil, producesMessageId: nil, assistantId: nil,
            status: AgentRunStatus.awaitingPermission.wireName, inputDigest: "digest", inputSnapshotRef: "tool_call:tc-1", inputSchemaVersion: 1,
            startedAt: startedAt, finishedAt: nil, interruptedReason: nil,
            terminalReason: nil, providerId: nil, modelId: nil, promptVersion: nil,
            toolCatalogVersion: nil, capabilitySnapshot: nil
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            dao.insertRunIfAbsent(run: run) { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }

        // tc-2's dangling ledger Started: the model issued it right after tc-1
        // executed; the app died before it ever got a Finished.
        let tc2Started = await ledger.recordToolCallStarted(
            runId: runId, toolCallId: "tc-2", toolName: "workspace_write",
            argsDigest: "d2", effectClass: .sideEffect
        )
        XCTAssertTrue(tc2Started)

        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false,
            agentRuntimeDao: dao
        )
        viewModel.conversationStore = store

        let descriptor = IOSPendingApprovalRecoveryDescriptor(
            runId: runId,
            conversationId: conversationId.toHexDashString(),
            toolCallId: "tc-1"
        )
        await viewModel.terminateRecoveredPendingApprovals([descriptor])

        let rawReloaded = await store.messages(for: conversationId)
        let reloaded = try XCTUnwrap(rawReloaded)
        let toolParts = reloaded.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }

        let tc1 = toolParts.first { $0.toolCallId == "tc-1" }
        let tc1Text = tc1?.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.first ?? ""
        XCTAssertTrue(
            tc1Text.contains("/tmp/a"),
            "tc-1's real output must survive untouched — must NOT be overwritten with the plain 'App restarted' cancellation text"
        )

        let tc2 = toolParts.first { $0.toolCallId == "tc-2" }
        XCTAssertFalse(
            tc2?.output.isEmpty ?? true,
            "tc-2 must no longer be left with empty output — an empty-output Tool part is exactly what makes it silently re-fireable"
        )
        XCTAssertEqual(
            ChatToolOutputFormatter.failureReason(from: tc2?.output ?? []),
            IOSToolCallRecoveryAction.markUnknown.toolPartMessage,
            "a dangling sideEffect Started with no Finished must be marked outcome-unknown, never silently retried"
        )

        let runtime = makeRuntime()
        XCTAssertNil(
            runtime.nextPendingToolCall(
                in: reloaded,
                availableToolNames: ["workspace_write"]
            ),
            "tc-2 must never again be offered as pending — I-3, never silently re-fired"
        )

        let finalStatus = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            dao.getRun(id: runId) { result, _ in cont.resume(returning: result?.status) }
        }
        XCTAssertNotEqual(finalStatus, AgentRunStatus.awaitingPermission.wireName, "the run must reach a terminal classification, not be left stuck awaiting a decision nobody can make anymore")
    }

    func testUnfinishedRunConversationPairsExcludesRunsWithoutConversationId() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let runId = "w3-noconv-\(UUID().uuidString)"
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let run = AgentRunEntity(
            runId: runId, parentRunId: nil, agentDescriptorId: "chat", agentVersion: "1",
            conversationId: nil, messageNodeId: nil, producesMessageId: nil, assistantId: nil,
            status: "running", inputDigest: "digest", inputSnapshotRef: nil, inputSchemaVersion: 1,
            startedAt: startedAt, finishedAt: nil, interruptedReason: nil,
            terminalReason: nil, providerId: nil, modelId: nil, promptVersion: nil,
            toolCatalogVersion: nil, capabilitySnapshot: nil
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            dao.insertRunIfAbsent(run: run) { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        let loadedPairs = await IOSRunRecovery.unfinishedRunConversationPairs(
            runStore: IOSDurableRunStore(dao: dao)
        )
        let pairs = try XCTUnwrap(loadedPairs)
        XCTAssertFalse(pairs.contains { $0.runId == runId }, "a run with no conversationId has nothing for W3 to write into and must be excluded")
    }

    func testRecoveryPendingRunRemainsDiscoverableUntilConversationReconciliation() async throws {
        let db = makeDatabase()
        let dao = db.agentRuntimeDao()
        let runId = "w3-recovery-pending-\(UUID().uuidString)"
        let conversationId = UUID().uuidString
        let run = AgentRunEntity(
            runId: runId, parentRunId: nil, agentDescriptorId: "chat", agentVersion: "1",
            conversationId: conversationId, messageNodeId: nil, producesMessageId: nil, assistantId: nil,
            status: AgentRunStatus.recoveryPending.wireName, inputDigest: "digest", inputSnapshotRef: nil, inputSchemaVersion: 1,
            startedAt: Int64(Date().timeIntervalSince1970 * 1000), finishedAt: nil, interruptedReason: nil,
            terminalReason: nil, providerId: nil, modelId: nil, promptVersion: nil,
            toolCatalogVersion: nil, capabilitySnapshot: nil
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            dao.insertRunIfAbsent(run: run) { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }

        let loadedPairs = await IOSRunRecovery.unfinishedRunConversationPairs(
            runStore: IOSDurableRunStore(dao: dao)
        )
        let pairs = try XCTUnwrap(loadedPairs)
        XCTAssertTrue(
            pairs.contains { $0.runId == runId && $0.conversationId == conversationId },
            "a failed result save must remain eligible for the next recovery sweep"
        )
    }
}

/// Minimal no-op search transport so `ChatToolRuntime` can be constructed for
/// `nextPendingToolCall`/`hasUnresolvedToolCall` checks without any network
/// dependency — these tests never actually dispatch a search tool call.
private final class MockRecoveryTestSearchTransport: IOSSearchHTTPTransport, @unchecked Sendable {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        throw NSError(domain: "IOSToolRecoveryTests", code: 1)
    }
}
