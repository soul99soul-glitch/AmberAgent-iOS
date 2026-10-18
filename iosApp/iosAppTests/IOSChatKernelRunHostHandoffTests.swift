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
        XCTAssertTrue(gate.line.contains("declared=true claimed=true"))
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
}
