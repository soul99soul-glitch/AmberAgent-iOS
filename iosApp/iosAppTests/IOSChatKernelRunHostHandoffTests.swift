import XCTest
@preconcurrency import Shared
@testable import iosApp


/// Cancellation, handoff, and direct image transaction lifecycle.
@MainActor
final class IOSChatKernelRunHostHandoffTests: IOSChatKernelRunHostTestCase {
    func testAdapterCancelDuringNonCooperativeToolPublishesTerminalBeforeResult() async {
        let transport = NonCooperativeSearchTransport()
        let harness = makeHarness(searchTransport: transport)
        let runtime = makeHost(harness: harness, provider: HostScriptedProvider(rounds: [])).toolRuntimeForTesting
        let provider = HostScriptedProvider(rounds: [
            toolRound("uncancellable-search", "search_web", #"{"query":"amber"}"#),
            textRound("must not overwrite cancellation"),
        ])
        var terminals: [String] = []
        var published = harness.messages
        var callbacks = ChatRunKernelAdapter.Callbacks()
        callbacks.onRunTerminal = { terminals.append($0) }
        callbacks.onMessagesUpdated = { published = $0 }
        let adapter = ChatRunKernelAdapter(runtime: runtime, ledger: harness.ledger, callbacks: callbacks)
        let task = Task { @MainActor in
            await adapter.run(.init(
                provider: provider, providerSetting: harness.providerSetting, params: harness.params,
                runId: "noncooperative-tool", startedAt: 1, inputDigest: "test", conversationId: harness.conversationId,
                initialMessages: harness.messages, toolExposureBridge: harness.toolExposureBridge,
                executionPolicy: IOSExecutionPolicySnapshot(
                    capabilityPolicies: [:], globalAutoApproveEnabled: true,
                    highRiskAutoApproveEnabled: false, execJavaScriptEnabled: false, webSearchEnabled: true
                ),
                maxToolResumeCount: 4, drainSteer: nil, mailboxDrain: nil, citationTracker: nil,
                prepareUploadMessages: nil, nestedToolRunner: nil, approvalDecider: { _ in .approve }
            ))
        }
        let executing = await waitForCondition { transport.isExecuting }
        XCTAssertTrue(executing)
        XCTAssertNotNil(F.toolPart(toolCallId: "uncancellable-search", in: published))
        adapter.cancel()
        // Assert before releasing the operation: a cancelled callback must not
        // wait for an executor that cannot cooperatively stop.
        XCTAssertEqual(terminals, [AgentRunStatus.cancelled.wireName])
        let cancelled = F.toolOutputText(toolCallId: "uncancellable-search", in: published)
        XCTAssertTrue(cancelled.contains("User cancelled."))
        transport.release()
        _ = await task.value
        XCTAssertEqual(terminals, [AgentRunStatus.cancelled.wireName])
        XCTAssertEqual(F.toolOutputText(toolCallId: "uncancellable-search", in: published), cancelled)
        XCTAssertEqual(provider.callCount, 1)
    }

    func testHostCancelPreservesExactStreamTailInTerminalSnapshot() async {
        let harness = makeHarness()
        let provider = IOSAgentToolEngineTests.InterruptedStreamingProvider([
            F.streamChunk(delta: F.assistantText("已显示"), finishReason: ""),
            F.streamChunk(delta: F.assistantText("未节流尾段"), finishReason: ""),
        ], fails: false)
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)
        let emitted = await waitForCondition { provider.didEmit }
        XCTAssertTrue(emitted)
        host.cancel()
        let idle = await waitForHostIdle(host)
        XCTAssertTrue(idle)
        XCTAssertEqual(harness.messages.last?.toText(), "已显示未节流尾段")
        XCTAssertEqual(harness.log.terminalStatus(), AgentRunStatus.cancelled.wireName)
        provider.completeLate()
        await Task.yield()
        XCTAssertEqual(harness.messages.last?.toText(), "已显示未节流尾段")
    }

    func testHandoffRejectsCompletedRunWhileTerminalPersistenceIsInFlight() async throws {
        try await assertHandoffRejectedDuringTerminalPersistence(
            provider: HostScriptedProvider(rounds: [textRound("完成")]),
            finalText: "完成", terminalStatus: .completed
        )
    }

    func testHandoffRejectsFailedRunWhileTerminalPersistenceIsInFlight() async throws {
        try await assertHandoffRejectedDuringTerminalPersistence(
            provider: IOSAgentToolEngineTests.ThrowingProvider(),
            finalText: "upstream unavailable", terminalStatus: .failed
        )
    }

    private func assertHandoffRejectedDuringTerminalPersistence(
        provider: any IOSAgentTextProvider,
        finalText: String,
        terminalStatus: AgentRunStatus
    ) async throws {
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        weak var observedHarness: IOSChatForegroundHarness?
        let harness = makeHarness(persistMessages: { _ in
            // Gate only the published final answer; context preparation and
            // earlier transcript snapshots must not satisfy this regression.
            guard observedHarness?.messages.last?.toText() == finalText else { return true }
            entered = true
            await withCheckedContinuation { release = $0 }
            return true
        })
        observedHarness = harness
        let host = makeHost(harness: harness, provider: provider)
        var starts = 0
        host.backgroundStartOverrideForTesting = { _, _ in starts += 1; return true }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        start(host, harness: harness)
        let persisting = await waitForCondition { entered }
        XCTAssertTrue(persisting)
        XCTAssertFalse(host.handoffCurrentGenerationToBackground(conversationStore: store))
        XCTAssertEqual(starts, 0)
        release?.resume()
        let idle = await waitForHostIdle(host)
        XCTAssertTrue(idle)
        XCTAssertEqual(harness.log.terminalStatus(), terminalStatus.wireName)
    }

    func testEnabledPhoneControlDoesNotStartNativeOrBlockOrdinaryReply() async throws {
        let suite = "KernelHostPhoneGate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let phoneControl = IOSPhoneControlController(defaults: defaults, credentials: HostPhonePairingStore())
        await phoneControl.refreshPreparation()
        phoneControl.enabled = true
        phoneControl.selectedBundleIDs = ["app.example.target"]
        let harness = makeHarness()
        let provider = HostScriptedProvider(rounds: [textRound("hello")])
        let host = makeHost(harness: harness, provider: provider, phoneControl: phoneControl)
        let bridge = IosToolExposureBridge(tools: IOSPhoneControlToolCatalog.declarations)
        bridge.exposeToolNames(names: Array(IOSPhoneControlToolCatalog.toolNames).sorted())
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isSubset(of: Set(bridge.visibleTools().map(\.name))))
        host.start(providerSetting: harness.providerSetting, params: harness.params,
                   inputDigest: "phone-gate-test", conversationId: harness.conversationId,
                   uploadMessages: harness.messages, toolExposureBridge: bridge,
                   phoneControlUserInitiated: true)
        let stopped = await waitForHostIdle(host)
        XCTAssertTrue(stopped)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertTrue(phoneControl.enabled)
        XCTAssertEqual(harness.log.terminalStatus(), AgentRunStatus.completed.wireName)
        XCTAssertEqual(harness.messages.last?.toText(), "hello")
        XCTAssertEqual(phoneControl.phase, .idle)
        XCTAssertNil(phoneControl.ownerRunID)
        let gate = try XCTUnwrap(IOSBackgroundLifecycleLog.recentEntries.last { $0.line.contains("phoneControlRunGate") })
        XCTAssertTrue(gate.line.contains("declared=true claimed=false"))
        XCTAssertFalse(gate.line.contains("private_key"))
        await phoneControl.stopCurrent()
    }

    func testDisablingUnusedPhoneControlDoesNotCancelOrdinaryProviderRun() async throws {
        let suite = "KernelHostUnusedPhoneSwitch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let phoneControl = IOSPhoneControlController(defaults: defaults, credentials: HostPhonePairingStore())
        await phoneControl.refreshPreparation()
        phoneControl.enabled = true
        phoneControl.selectedBundleIDs = ["app.example.target"]
        let harness = makeHarness()
        let provider = HostBlockingProvider()
        let host = makeHost(harness: harness, provider: provider, phoneControl: phoneControl)
        let bridge = IosToolExposureBridge(tools: IOSPhoneControlToolCatalog.declarations)
        bridge.exposeToolNames(names: Array(IOSPhoneControlToolCatalog.toolNames).sorted())
        host.start(providerSetting: harness.providerSetting, params: harness.params,
                   inputDigest: "unused-phone-switch", conversationId: harness.conversationId,
                   uploadMessages: harness.messages, toolExposureBridge: bridge,
                   phoneControlUserInitiated: true)
        let providerStarted = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(providerStarted)
        let runID = try XCTUnwrap(host.currentRunId)
        XCTAssertFalse(phoneControl.hasRequestedSession(runID: runID))
        phoneControl.enabled = false
        await phoneControl.stop(runID: runID)
        XCTAssertFalse(phoneControl.enabled)
        XCTAssertNil(phoneControl.ownerRunID)
        XCTAssertTrue(host.isRunning)
        XCTAssertNil(harness.log.terminalStatus())
        host.cancel()
        let stopped = await waitForHostIdle(host)
        XCTAssertTrue(stopped)
    }

    func testKeepAliveExpirationPreservesPhoneOwnerOnlyWhenHandoffSucceeds() async throws {
        for handoffSucceeds in [true, false] {
            let suite = "KernelHostPhoneOwner-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let phoneControl = IOSPhoneControlController(defaults: defaults, credentials: HostPhonePairingStore())
            await phoneControl.refreshPreparation()
            phoneControl.enabled = true
            phoneControl.selectedBundleIDs = ["app.example.target"]

            let harness = makeHarness()
            let provider = HostBlockingProvider()
            let host = makeHost(harness: harness, provider: provider, phoneControl: phoneControl)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = IOSConversationStore(baseDirectory: directory)
            var handedRunID: String?
            host.backgroundStartOverrideForTesting = { handoff, _ in
                handedRunID = handoff.runId
                return handoffSucceeds
            }
            start(host, harness: harness)
            let started = await waitForCondition { provider.callCount == 1 }
            XCTAssertTrue(started)
            let runID = try XCTUnwrap(host.currentRunId)
            XCTAssertTrue(phoneControl.claim(runID: runID, onStop: {}))
            XCTAssertFalse(host.handoffCurrentGenerationToBackground(conversationStore: store, honorKeepAliveLease: true))
            host.handleKeepAliveExpiration(runId: "stale-run", applicationState: .background)
            XCTAssertTrue(phoneControl.statusText(runID: runID).contains("scope=app.example.target"))

            host.handleKeepAliveExpiration(runId: runID, applicationState: .background)
            XCTAssertEqual(handedRunID, runID)
            if handoffSucceeds {
                XCTAssertEqual(phoneControl.ownerRunID, runID)
                XCTAssertTrue(phoneControl.statusText(runID: runID).contains("scope=app.example.target"))
                XCTAssertFalse(host.isRunning)
                XCTAssertNil(harness.log.terminalStatus())
            } else {
                XCTAssertTrue(phoneControl.enabled)
                XCTAssertFalse(phoneControl.statusText(runID: runID).contains("scope="))
                let stopped = await waitForHostIdle(host)
                XCTAssertTrue(stopped)
                XCTAssertEqual(harness.log.terminalStatus(), AgentRunStatus.interrupted.wireName)
            }
            await phoneControl.stop(runID: runID)
            XCTAssertNil(phoneControl.ownerRunID)
        }
    }

    func testHostHandsPreparedRunToBackgroundOwner() async throws {
        let harness = makeHarness()
        let provider = HostBlockingProvider()
        let host = makeHost(harness: harness, provider: provider)
        var capturedHandoff: IOSChatBackgroundHandoff?
        host.backgroundStartOverrideForTesting = { handoff, _ in
            capturedHandoff = handoff
            return true
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernelHostHandoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)

        start(host, harness: harness)
        let providerStarted = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(providerStarted)

        let didHandoff = host.handoffCurrentGenerationToBackground(conversationStore: store)

        XCTAssertTrue(didHandoff)
        XCTAssertEqual(capturedHandoff?.runId, harness.capturedRunId)
        XCTAssertFalse(host.isRunning)
        XCTAssertFalse(harness.isLoading)
        XCTAssertNil(harness.log.terminalStatus(), "成功交接后终态归后台 owner，前台不得抢报")
    }

    func testHandoffAllowsInFlightNetworkRead() async throws {
        let transport = HostBlockingSearchTransport()
        let harness = makeHarness(searchTransport: transport)
        let provider = HostScriptedProvider(rounds: [
            toolRound("tc-search", "search_web", #"{"query":"amber"}"#),
        ])
        let host = makeHost(harness: harness, provider: provider)
        var capturedHandoff: IOSChatBackgroundHandoff?
        host.backgroundStartOverrideForTesting = { handoff, _ in
            capturedHandoff = handoff
            return true
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernelHostSearchHandoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)

        start(host, harness: harness)
        let approval = await harness.waitForPendingSearchApproval()
        XCTAssertNotNil(approval)
        host.approvePendingSearchTool()
        // Free aggregate search starts several HTTP requests for one tool call.
        let searchStarted = await waitForCondition { transport.callCount > 0 }
        XCTAssertTrue(searchStarted)

        XCTAssertTrue(host.handoffCurrentGenerationToBackground(conversationStore: store))
        XCTAssertEqual(capturedHandoff?.runId, harness.capturedRunId)
        XCTAssertFalse(host.isRunning)
        XCTAssertFalse(harness.isLoading)
        XCTAssertNil(harness.log.terminalStatus(), "networkRead 交接后终态归后台 owner")
    }

    func testHandoffRejectsInFlightImageGeneration() async throws {
        let harness = makeHarness()
        let host = makeHost(harness: harness, provider: HostScriptedProvider(rounds: []))
        var backgroundStartCount = 0
        host.backgroundStartOverrideForTesting = { _, _ in
            backgroundStartCount += 1
            return true
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernelHostImageHandoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)

        host.runImageTool(
            input: #"{"prompt":"make it brighter","source_image_url":"file:///tmp/source.png"}"#,
            conversationId: harness.conversationId,
            modelDisplayName: "image-test"
        )

        XCTAssertTrue(host.isRunning)
        XCTAssertFalse(host.handoffCurrentGenerationToBackground(conversationStore: store))
        XCTAssertEqual(backgroundStartCount, 0)

        host.cancel()
        let becameIdle = await waitForHostIdle(host)
        XCTAssertTrue(becameIdle)
    }

    func testDirectImageRunFailsClosedWhenLedgerStartCannotPersist() async {
        let harness = makeHarness()
        harness.ledger.failStarts = true
        let host = makeHost(harness: harness, provider: HostScriptedProvider(rounds: []))

        host.runImageTool(
            input: #"{"prompt":"make it brighter","source_image_url":"file:///tmp/source.png"}"#,
            conversationId: harness.conversationId,
            modelDisplayName: "image-test"
        )

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, AgentRunStatus.failed.wireName)
        XCTAssertFalse(host.isRunning)
        XCTAssertFalse(harness.isLoading)
        XCTAssertFalse(harness.messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first?.output.isEmpty ?? true)
        XCTAssertFalse(harness.log.snapshot().contains { event in
            switch event {
            case .toolCallStarted, .toolCallFinished:
                return true
            default:
                return false
            }
        }, "Started 写失败后不得执行或记录图片副作用终态")
    }

    func testDirectImageImmediateCancelDoesNotStartRunAfterTerminal() async {
        let harness = makeHarness()
        let host = makeHost(harness: harness, provider: HostScriptedProvider(rounds: []))

        host.runImageTool(
            input: #"{"prompt":"make it brighter","source_image_url":"file:///tmp/source.png"}"#,
            conversationId: harness.conversationId,
            modelDisplayName: "image-test"
        )
        host.cancel()

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, AgentRunStatus.cancelled.wireName)
        XCTAssertFalse(host.isRunning)
        XCTAssertFalse(harness.log.snapshot().contains(.runStarted))
    }

    func testDirectImagePrepareFailureReconcilesPreparedTransaction() async {
        let harness = makeHarness()
        harness.ledger.preparationResult = .blocked(reason: "event append failed")
        let host = makeHost(harness: harness, provider: HostScriptedProvider(rounds: []))

        host.runImageTool(
            input: #"{"prompt":"make it brighter","source_image_url":"file:///tmp/source.png"}"#,
            conversationId: harness.conversationId,
            modelDisplayName: "image-test"
        )

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, AgentRunStatus.failed.wireName)
        XCTAssertTrue(harness.ledger.recoveryTransitions.contains(.init(
            expected: .prepared,
            state: .reconciled,
            outcome: "not_executed_prepare_failed"
        )))
        XCTAssertFalse(harness.log.snapshot().contains { event in
            if case .toolCallStarted = event { return true }
            return false
        })
    }

    func testDirectImageTerminalFailureDoesNotPublishExecutorResult() async {
        let harness = makeHarness()
        harness.ledger.failTerminals = true
        let host = makeHost(harness: harness, provider: HostScriptedProvider(rounds: []))
        let runtime = host.toolRuntimeForTesting
        host.imageToolExecutionOverrideForTesting = { toolCall, messages in
            runtime.messagesByFinishingToolCall(
                toolCall,
                outputText: #"{"ok":true,"status":"completed"}"#,
                in: messages
            )
        }

        host.runImageTool(
            input: #"{"prompt":"make it brighter","source_image_url":"file:///tmp/source.png"}"#,
            conversationId: harness.conversationId,
            modelDisplayName: "image-test"
        )

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, AgentRunStatus.recoveryPending.wireName)
        let idleAfterFailure = await waitForHostIdle(host)
        XCTAssertTrue(idleAfterFailure)
        let imageOutput = harness.messages
            .flatMap(\.parts)
            .compactMap { $0 as? UIMessagePart.Tool }
            .first { $0.toolName == "generate_image" }?
            .output
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined() ?? ""
        XCTAssertFalse(
            imageOutput.contains(#""ok":true"#),
            "账本终态失败时不得发布执行器真实结果"
        )
    }

    func testDirectImageSystemInterruptionClosesStartedTransactionWithoutWaitingForExecutor() async {
        let harness = makeHarness()
        let host = makeHost(harness: harness, provider: HostScriptedProvider(rounds: []))
        let executionGate = ImageExecutionGate()
        host.imageToolExecutionOverrideForTesting = { _, messages in
            executionGate.started = true
            while !executionGate.released {
                await Task.yield()
            }
            return messages
        }

        host.runImageTool(
            input: #"{"prompt":"make it brighter","source_image_url":"file:///tmp/source.png"}"#,
            conversationId: harness.conversationId,
            modelDisplayName: "image-test"
        )
        let didStartExecution = await waitForCondition {
            executionGate.started && harness.log.snapshot().contains(.toolCallStarted(tool: "generate_image"))
        }
        XCTAssertTrue(didStartExecution)

        host.cancel(cause: .backgroundInterruption)

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, AgentRunStatus.interrupted.wireName)
        XCTAssertFalse(host.isRunning)
        XCTAssertTrue(harness.ledger.recoveryTransitions.contains(.init(
            expected: .started,
            state: .outcomeUnknown,
            outcome: "cancelled_during_execution"
        )))
        let imageOutput = harness.messages
            .flatMap(\.parts)
            .compactMap { $0 as? UIMessagePart.Tool }
            .first { $0.toolName == "generate_image" }?
            .output
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined() ?? ""
        XCTAssertTrue(imageOutput.contains("Generation interrupted by the system."))
        XCTAssertFalse(imageOutput.contains("User cancelled."))

        executionGate.released = true
    }

    func testAdapterCancelMidMultiToolBatchPreservesCompletedSiblingToolOutput() async {
        final class FirstFastSecondBlockingSearchTransport: IOSSearchHTTPTransport, @unchecked Sendable {
            private let lock = NSLock()
            private var secondEntered = false
            private var released = false
            private var continuations: [CheckedContinuation<Void, Never>] = []

            var isSecondExecuting: Bool { lock.withLock { secondEntered } }

            private static let threeResultsHTML = """
            <html><body>
            <a class="result__a" href="https://example.test/1">Amber Result 1</a>
            <a class="result__a" href="https://example.test/2">Amber Result 2</a>
            <a class="result__a" href="https://example.test/3">Amber Result 3</a>
            </body></html>
            """

            func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
                let urlText = request.url?.absoluteString ?? ""
                let bodyText = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let isSecondSearch = urlText.localizedCaseInsensitiveContains("second")
                    || bodyText.localizedCaseInsensitiveContains("second")
                if !isSecondSearch {
                    return (
                        IOSForegroundNoopSearchTransport.okResponse(for: request),
                        Data(Self.threeResultsHTML.utf8)
                    )
                }
                await withCheckedContinuation { continuation in
                    let shouldResume = lock.withLock {
                        secondEntered = true
                        if released { return true }
                        continuations.append(continuation)
                        return false
                    }
                    if shouldResume { continuation.resume() }
                }
                return (
                    IOSForegroundNoopSearchTransport.okResponse(for: request),
                    Data(Self.threeResultsHTML.utf8)
                )
            }

            func release() {
                let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    released = true
                    defer { continuations.removeAll() }
                    return continuations
                }
                pending.forEach { $0.resume() }
            }
        }

        let transport = FirstFastSecondBlockingSearchTransport()
        let harness = makeHarness(searchTransport: transport)
        let runtime = makeHost(harness: harness, provider: HostScriptedProvider(rounds: [])).toolRuntimeForTesting
        let multiToolRound = HostScriptedProvider.Round(
            message: F.assistantMessage(parts: [
                UIMessagePart.Tool(
                    toolCallId: "fast-search-1",
                    toolName: "search_web",
                    input: #"{"query":"first completed search","maxResults":1}"#,
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                ),
                UIMessagePart.Tool(
                    toolCallId: "blocking-search-2",
                    toolName: "search_web",
                    input: #"{"query":"second cancelled search","maxResults":1}"#,
                    output: [],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                ),
            ]),
            finishReason: "tool_calls"
        )
        let provider = HostScriptedProvider(rounds: [
            multiToolRound,
            textRound("must not run after cancel"),
        ])
        var terminals: [String] = []
        var published = harness.messages
        var callbacks = ChatRunKernelAdapter.Callbacks()
        callbacks.onRunTerminal = { terminals.append($0) }
        callbacks.onMessagesUpdated = { published = $0 }
        let adapter = ChatRunKernelAdapter(runtime: runtime, ledger: harness.ledger, callbacks: callbacks)
        let task = Task { @MainActor in
            await adapter.run(.init(
                provider: provider, providerSetting: harness.providerSetting, params: harness.params,
                runId: "multi-tool-cancel", startedAt: 1, inputDigest: "test", conversationId: harness.conversationId,
                initialMessages: harness.messages, toolExposureBridge: harness.toolExposureBridge,
                executionPolicy: IOSExecutionPolicySnapshot(
                    capabilityPolicies: [:], globalAutoApproveEnabled: true,
                    highRiskAutoApproveEnabled: false, execJavaScriptEnabled: false, webSearchEnabled: true
                ),
                maxToolResumeCount: 4, drainSteer: nil, mailboxDrain: nil, citationTracker: nil,
                prepareUploadMessages: nil, nestedToolRunner: nil, approvalDecider: { _ in .approve }
            ))
        }

        let secondStarted = await waitForCondition { transport.isSecondExecuting }
        XCTAssertTrue(secondStarted)

        adapter.cancel()
        XCTAssertEqual(terminals, [AgentRunStatus.cancelled.wireName])

        let firstOutput = F.toolOutputText(toolCallId: "fast-search-1", in: published)
        let secondOutput = F.toolOutputText(toolCallId: "blocking-search-2", in: published)
        XCTAssertFalse(
            firstOutput.contains("User cancelled."),
            "earlier completed tool in the same batch must keep its real output instead of being overwritten with User cancelled."
        )
        XCTAssertFalse(firstOutput.isEmpty)
        XCTAssertTrue(secondOutput.contains("User cancelled."))

        transport.release()
        _ = await task.value
        XCTAssertEqual(F.toolOutputText(toolCallId: "fast-search-1", in: published), firstOutput)
        XCTAssertTrue(F.toolOutputText(toolCallId: "blocking-search-2", in: published).contains("User cancelled."))
    }

    func testOrdinaryReplyWithPhoneDeclarationsDoesNotClaimPhoneControlOrEnableHeartbeat() async throws {
        let suite = "KernelHostOrdinaryNoClaim-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let phoneControl = IOSPhoneControlController(
            defaults: defaults,
            credentials: HostPhonePairingStore(),
            localTunnel: PhoneControlTunnelStub()
        )
        await phoneControl.refreshPreparation()
        phoneControl.enabled = true
        phoneControl.selectedBundleIDs = ["app.example.target"]

        let harness = makeHarness()
        let provider = IOSChatProgressStreamingProvider()
        let host = makeHost(harness: harness, provider: provider, phoneControl: phoneControl)
        let bridge = IosToolExposureBridge(tools: IOSPhoneControlToolCatalog.declarations)
        bridge.exposeToolNames(names: Array(IOSPhoneControlToolCatalog.toolNames).sorted())

        host.start(
            providerSetting: harness.providerSetting,
            params: F.makeParams(toolNames: [], tools: bridge.visibleTools()),
            inputDigest: "ordinary-no-phone-claim",
            conversationId: harness.conversationId,
            uploadMessages: harness.messages,
            toolExposureBridge: bridge,
            phoneControlUserInitiated: true
        )
        let started = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(host.currentRunId)

        XCTAssertNil(phoneControl.ownerRunID, "Ordinary Q&A must not eagerly claim global phoneControl slot")
        XCTAssertFalse(phoneControl.isOccupied)
        XCTAssertFalse(harness.keepAlive.hasLivenessHeartbeat(runID))
        XCTAssertEqual(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)?.total, 4)

        provider.emit(F.streamChunk(delta: F.assistantText("普通问答回复")))
        provider.finishRound()
        let idle = await waitForHostIdle(host)
        XCTAssertTrue(idle)
        XCTAssertEqual(harness.log.terminalStatus(), AgentRunStatus.completed.wireName)
        XCTAssertEqual(harness.messages.last?.toText(), "普通问答回复")
        XCTAssertNil(phoneControl.ownerRunID)
        XCTAssertEqual(phoneControl.phase, .idle)
        XCTAssertFalse(harness.keepAlive.hasLivenessHeartbeat(runID))
        await phoneControl.stopCurrent()
    }

    func testFirstPhoneToolLazilyClaimsOwnershipAndOccupiedControllerIsNotPreempted() async throws {
        actor StaticPhoneAppDiscoverer: PhoneControlApplicationDiscovering {
            let apps: [PhoneControlInstalledApp]
            init(_ apps: [PhoneControlInstalledApp]) { self.apps = apps }
            func installedApplications(pairing: Data, connectionMode: IOSPhoneControlConnectionMode) async throws -> [PhoneControlInstalledApp] {
                apps
            }
        }

        let suite = "KernelHostLazyPhoneClaim-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let discoverer = StaticPhoneAppDiscoverer([
            PhoneControlInstalledApp(bundleID: "app.example.target", name: "Target App")
        ])
        let phoneControl = IOSPhoneControlController(
            defaults: defaults,
            credentials: HostPhonePairingStore(),
            applications: discoverer,
            localTunnel: PhoneControlTunnelStub()
        )
        await phoneControl.refreshPreparation()
        phoneControl.enabled = true
        phoneControl.selectedBundleIDs = ["app.example.target"]

        let combinedDeclarations = IOSPhoneControlToolCatalog.declarations + ToolKt.iosToolDeclarations(names: ["search_web"])
        let exposedNames = (Array(IOSPhoneControlToolCatalog.toolNames) + ["search_web"]).sorted()

        // 1) Idle phoneControl: keeps phone_* tools exposed, stays unclaimed until first phone_* tool runs, then lazily claims.
        let harness1 = makeHarness(exposedToolNames: ["search_web"])
        let provider1 = IOSChatProgressStreamingProvider()
        let host1 = makeHost(harness: harness1, provider: provider1, phoneControl: phoneControl)
        let bridge1 = IosToolExposureBridge(tools: combinedDeclarations)
        bridge1.exposeToolNames(names: exposedNames)
        host1.start(
            providerSetting: harness1.providerSetting,
            params: F.makeParams(toolNames: [], tools: bridge1.visibleTools()),
            inputDigest: "lazy-claim-first-phone-tool",
            conversationId: harness1.conversationId,
            uploadMessages: harness1.messages,
            toolExposureBridge: bridge1,
            phoneControlUserInitiated: true
        )
        let started1 = await waitForCondition { provider1.callCount == 1 }
        XCTAssertTrue(started1)
        let runID1 = try XCTUnwrap(host1.currentRunId)
        let firstRoundTools1 = Set(provider1.capturedParams.first?.tools.map(\.name) ?? [])
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isSubset(of: firstRoundTools1))
        XCTAssertNil(phoneControl.ownerRunID, "Idle phoneControl must remain unclaimed before any phone_* tool runs")
        XCTAssertFalse(harness1.keepAlive.hasLivenessHeartbeat(runID1))

        let phoneToolTurn = F.assistantMessage(parts: [
            UIMessagePart.Tool(
                toolCallId: "lazy-status",
                toolName: "phone_status",
                input: "{}",
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            ),
            UIMessagePart.Tool(
                toolCallId: "lazy-apps",
                toolName: "phone_apps",
                input: "{}",
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            ),
        ])
        provider1.emit(F.streamChunk(delta: phoneToolTurn))
        provider1.finishRound()
        let round2Started1 = await waitForCondition { provider1.callCount == 2 }
        XCTAssertTrue(round2Started1)
        XCTAssertEqual(phoneControl.ownerRunID, runID1)
        XCTAssertTrue(phoneControl.isOccupied)
        XCTAssertTrue(harness1.keepAlive.hasLivenessHeartbeat(runID1))
        XCTAssertEqual(try iosChatBackgroundLeaseProgress(harness1.keepAlive, runID: runID1)?.total, -1)
        XCTAssertTrue(F.toolOutputText(toolCallId: "lazy-status", in: harness1.messages).contains("scope=app.example.target"))
        XCTAssertTrue(F.toolOutputText(toolCallId: "lazy-apps", in: harness1.messages).contains("app.example.target"))

        provider1.emit(F.streamChunk(delta: F.assistantText("手机查询完成")))
        provider1.finishRound()
        let idle1 = await waitForHostIdle(host1)
        XCTAssertTrue(idle1)
        XCTAssertNil(phoneControl.ownerRunID)

        // 2) Occupied by another run at start: strips phone_* tools without preempting existing owner.
        XCTAssertTrue(phoneControl.claim(runID: "other-active-run", onStop: {}))
        let harness2 = makeHarness(exposedToolNames: ["search_web"])
        let provider2 = IOSChatProgressStreamingProvider()
        let host2 = makeHost(harness: harness2, provider: provider2, phoneControl: phoneControl)
        let bridge2 = IosToolExposureBridge(tools: combinedDeclarations)
        bridge2.exposeToolNames(names: exposedNames)
        host2.start(
            providerSetting: harness2.providerSetting,
            params: F.makeParams(toolNames: [], tools: bridge2.visibleTools()),
            inputDigest: "occupied-no-preempt",
            conversationId: harness2.conversationId,
            uploadMessages: harness2.messages,
            toolExposureBridge: bridge2,
            phoneControlUserInitiated: true
        )
        let started2 = await waitForCondition { provider2.callCount == 1 }
        XCTAssertTrue(started2)
        XCTAssertEqual(phoneControl.ownerRunID, "other-active-run")
        let firstRoundTools2 = Set(provider2.capturedParams.first?.tools.map(\.name) ?? [])
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: firstRoundTools2),
                      "Occupied phoneControl must strip phone_* tools from a competing run")
        XCTAssertTrue(firstRoundTools2.contains("search_web"))
        provider2.emit(F.streamChunk(delta: F.assistantText("不抢占直接回复")))
        provider2.finishRound()
        let idle2 = await waitForHostIdle(host2)
        XCTAssertTrue(idle2)
        XCTAssertEqual(phoneControl.ownerRunID, "other-active-run")
        await phoneControl.stop(runID: "other-active-run")
        XCTAssertNil(phoneControl.ownerRunID)

        // 3) Race after start: idle when Round 1 starts, occupied before phone_apps executes -> denied cleanly without preemption.
        let harness3 = makeHarness(exposedToolNames: ["search_web"])
        let provider3 = IOSChatProgressStreamingProvider()
        let host3 = makeHost(harness: harness3, provider: provider3, phoneControl: phoneControl)
        let bridge3 = IosToolExposureBridge(tools: combinedDeclarations)
        bridge3.exposeToolNames(names: exposedNames)
        host3.start(
            providerSetting: harness3.providerSetting,
            params: F.makeParams(toolNames: [], tools: bridge3.visibleTools()),
            inputDigest: "race-no-preempt",
            conversationId: harness3.conversationId,
            uploadMessages: harness3.messages,
            toolExposureBridge: bridge3,
            phoneControlUserInitiated: true
        )
        let started3 = await waitForCondition { provider3.callCount == 1 }
        XCTAssertTrue(started3)
        let runID3 = try XCTUnwrap(host3.currentRunId)
        XCTAssertNil(phoneControl.ownerRunID)
        XCTAssertTrue(phoneControl.claim(runID: "race-owner-run", onStop: {}))

        provider3.emit(F.streamChunk(delta: toolRound("race-apps", "phone_apps", "{}").message))
        provider3.finishRound()
        let round2Started3 = await waitForCondition { provider3.callCount == 2 }
        XCTAssertTrue(round2Started3)
        XCTAssertEqual(phoneControl.ownerRunID, "race-owner-run")
        XCTAssertFalse(harness3.keepAlive.hasLivenessHeartbeat(runID3))
        XCTAssertTrue(F.toolOutputText(toolCallId: "race-apps", in: harness3.messages).contains("run_not_authorized"))

        provider3.emit(F.streamChunk(delta: F.assistantText("已处理占用冲突")))
        provider3.finishRound()
        let idle3 = await waitForHostIdle(host3)
        XCTAssertTrue(idle3)
        XCTAssertEqual(phoneControl.ownerRunID, "race-owner-run")
        await phoneControl.stop(runID: "race-owner-run")
        XCTAssertNil(phoneControl.ownerRunID)
    }
}
