import XCTest
@preconcurrency import Shared
@testable import iosApp


/// Phone reasoning and background progress ownership.
@MainActor
final class IOSChatKernelRunHostPhoneProgressTests: IOSChatKernelRunHostTestCase {
    func testPhoneAutomaticReasoningEligibilityRequiresClaimAndPreservesExplicitLevels() async throws {
        let choices: [(String, ReasoningLevel, Bool)] = [
            ("auto", .high, true), ("high", .high, true), ("low", .low, true),
            ("off", .off, true), ("max", .max, true), ("auto", .high, false)
        ]
        for (storedLevel, resolvedLevel, userInitiated) in choices {
            let suite = "KernelHostPhoneReasoning-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = IOSPhoneControlController(defaults: defaults, credentials: HostPhonePairingStore())
            controller.enabled = true
            controller.selectedBundleIDs = ["app.example.target"]
            let harness = makeHarness()
            let provider = IOSChatProgressStreamingProvider()
            let host = makeHost(harness: harness, provider: provider, phoneControl: controller)
            let bridge = IosToolExposureBridge(tools: IOSPhoneControlToolCatalog.declarations)
            let (setting, params) = try phoneReasoningParams(
                harness: harness, storedLevel: storedLevel, resolvedLevel: resolvedLevel,
                tools: bridge.visibleTools()
            )
            var transferred: IOSChatBackgroundHandoff?
            host.backgroundStartOverrideForTesting = { handoff, _ in
                transferred = handoff
                return true
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = IOSConversationStore(baseDirectory: directory)
            host.start(providerSetting: setting, params: params,
                       inputDigest: suite, conversationId: harness.conversationId,
                       uploadMessages: harness.messages, toolExposureBridge: bridge,
                       phoneControlUserInitiated: userInitiated)
            let started = await waitForCondition { provider.callCount == 1 }
            XCTAssertTrue(started)
            let runID = try XCTUnwrap(host.currentRunId)
            XCTAssertEqual(controller.ownerRunID == runID, userInitiated)
            XCTAssertFalse(controller.hasRequestedSession(runID: runID))
            XCTAssertEqual(provider.capturedParams.first?.reasoningLevel, resolvedLevel,
                           "A reserved phone scope must not change an ordinary first request")
            XCTAssertTrue(host.handoffCurrentGenerationToBackground(conversationStore: store))
            XCTAssertEqual(transferred?.phoneAutomaticReasoning, storedLevel == "auto" && userInitiated)
            XCTAssertEqual(transferred?.params.reasoningLevel, resolvedLevel)
            XCTAssertEqual(harness.dependencies.sharedSettings.snapshot.getCurrentAssistant().reasoningLevel.name.lowercased(), storedLevel)
            await controller.stop(runID: runID)
        }
    }

    func testPhoneAutomaticReasoningEarlyHandoffKeepsFrozenAutoAfterSettingsChange() async throws {
        let suite = "KernelHostFrozenPhoneReasoning-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = IOSPhoneControlController(defaults: defaults, credentials: HostPhonePairingStore())
        controller.enabled = true
        controller.selectedBundleIDs = ["app.example.target"]
        let harness = makeHarness()
        let provider = IOSChatProgressStreamingProvider()
        let host = makeHost(harness: harness, provider: provider, phoneControl: controller)
        let bridge = IosToolExposureBridge(tools: IOSPhoneControlToolCatalog.declarations)
        let (setting, params) = try phoneReasoningParams(
            harness: harness, storedLevel: "auto", resolvedLevel: .high, tools: bridge.visibleTools()
        )
        var transferred: IOSChatBackgroundHandoff?
        host.backgroundStartOverrideForTesting = { handoff, _ in transferred = handoff; return true }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        host.start(providerSetting: setting, params: params,
                   inputDigest: suite, conversationId: harness.conversationId,
                   uploadMessages: harness.messages, toolExposureBridge: bridge,
                   phoneControlUserInitiated: true)
        harness.dependencies.sharedSettings.updateCurrentAssistantReasoningLevel(.max)
        let started = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(host.currentRunId)
        XCTAssertFalse(controller.hasRequestedSession(runID: runID))
        XCTAssertEqual(provider.capturedParams.first?.reasoningLevel, .high)
        XCTAssertTrue(host.handoffCurrentGenerationToBackground(conversationStore: store))
        XCTAssertEqual(transferred?.phoneAutomaticReasoning, true,
                       "Handoff before the first phone call must retain the run's frozen AUTO eligibility")
        XCTAssertEqual(transferred?.params.reasoningLevel, .high)
        XCTAssertEqual(harness.dependencies.sharedSettings.snapshot.getCurrentAssistant().reasoningLevel, .max)
        await controller.stop(runID: runID)
    }

    func testPhoneApprovedToolResultAdvancesProgressBeforeNextModelChunk() async throws {
        let (host, harness, provider, phoneControl, defaults, suite) = try await startPhoneProgressRun(exposedToolNames: ["search_web"])
        defer { host.cancel(); defaults.removePersistentDomain(forName: suite) }
        let started = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(host.currentRunId)
        XCTAssertEqual(phoneControl.ownerRunID, runID)
        provider.emit(F.streamChunk(delta: toolRound("approved-phone-progress", "search_web", #"{"query":"amber"}"#).message))
        provider.finishRound()
        let approval = await harness.waitForPendingSearchApproval()
        XCTAssertNotNil(approval)
        XCTAssertTrue(host.hasPendingToolApproval)
        XCTAssertNil(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID), "Waiting for approval releases execution rights")
        host.approvePendingSearchTool()
        let resumed = await waitForCondition {
            provider.callCount == 2
                && !(F.toolPart(toolCallId: "approved-phone-progress", in: harness.messages)?.output.isEmpty ?? true)
        }
        XCTAssertTrue(resumed)
        XCTAssertTrue(harness.log.snapshot().contains(.toolCallFinished(tool: "search_web", outcome: "completed")))
        let progress = try XCTUnwrap(iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID))
        XCTAssertEqual(progress.total, -1)
        XCTAssertGreaterThan(progress.completed, 0,
                             "The approved tool completed real work even while the next model has emitted no chunk")
        provider.emit(F.streamChunk(delta: F.assistantText("完成")))
        provider.finishRound()
        let stopped = await waitForHostIdle(host)
        XCTAssertTrue(stopped)
    }

    func testPhoneBackgroundProgressAdvancesForModelSnapshotsAndCompletedToolsAcrossRounds() async throws {
        let (host, harness, provider, phoneControl, defaults, suite) = try await startPhoneProgressRun()
        defer { host.cancel(); defaults.removePersistentDomain(forName: suite) }
        let started = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(host.currentRunId)
        XCTAssertEqual(phoneControl.ownerRunID, runID)
        let initial = try XCTUnwrap(iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID))
        XCTAssertEqual(initial.completed, 0, "Starting a request is not a received chunk or a completed tool")
        XCTAssertEqual(initial.total, -1,
                       "A phone task cannot predict its number of model chunks or tools")

        provider.emit(F.streamChunk(delta: F.assistantText("计划")))
        let firstVisible = await waitForCondition { harness.messages.last?.toText() == "计划" }
        XCTAssertTrue(firstVisible)
        let first = try XCTUnwrap(iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID))
        XCTAssertGreaterThan(first.completed, 0)
        try await Task.sleep(for: .milliseconds(80))
        provider.emit(F.streamChunk(delta: F.assistantText("已核对目标")))
        let secondVisible = await waitForCondition { harness.messages.last?.toText() == "计划已核对目标" }
        XCTAssertTrue(secondVisible)
        let second = try XCTUnwrap(iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID))
        XCTAssertGreaterThan(second.completed, first.completed, "Real streaming work must advance beyond the first delta")

        for unchanged in [F.chunk(with: F.assistantText("计划已核对目标")),
                          F.streamChunk(delta: F.assistantText(""))] {
            try await Task.sleep(for: .milliseconds(80))
            let revisions = harness.revisions.filter { $0 == .streamDelta }.count
            provider.emit(unchanged)
            let applied = await waitForCondition { harness.revisions.filter { $0 == .streamDelta }.count > revisions }
            XCTAssertTrue(applied, "The unchanged or empty chunk must reach the real snapshot callback")
            XCTAssertEqual(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)?.completed, second.completed,
                           "Repeated content and empty chunks must not manufacture progress")
        }
        let instant = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0)
        try await Task.sleep(for: .milliseconds(80))
        provider.emit(F.streamChunk(delta: F.assistantMessage(parts: [UIMessagePart.Reasoning(
            reasoning: "核对位置", createdAt: instant, finishedAt: nil, metadata: nil)])))
        let reasoningApplied = await waitForCondition {
            (harness.messages.last?.parts.last as? UIMessagePart.Reasoning)?.reasoning == "核对位置"
        }
        XCTAssertTrue(reasoningApplied)
        let afterReasoning = try XCTUnwrap(iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)).completed
        XCTAssertGreaterThan(afterReasoning, second.completed, "New reasoning text is real model work")
        try await Task.sleep(for: .milliseconds(80))
        let revisions = harness.revisions.filter { $0 == .streamDelta }.count
        provider.emit(F.chunk(with: F.assistantMessage(parts: [
            UIMessagePart.Text(text: "计划已核对目标", metadata: nil),
            UIMessagePart.Reasoning(reasoning: "核对位置", createdAt: instant, finishedAt: instant, metadata: nil)
        ])))
        let metadataApplied = await waitForCondition { harness.revisions.filter { $0 == .streamDelta }.count > revisions }
        XCTAssertTrue(metadataApplied)
        XCTAssertEqual(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)?.completed, afterReasoning,
                       "Reasoning timestamps alone do not count as more model work")

        for turn in 1...2 {
            let beforeTool = try XCTUnwrap(iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)).completed
            provider.emit(F.streamChunk(delta: toolRound("phone-progress-\(turn)", "session_search", #"{"query":"amber"}"#).message))
            provider.finishRound()
            let completed = await waitForCondition {
                provider.callCount == turn + 1
                    && !(F.toolPart(toolCallId: "phone-progress-\(turn)", in: harness.messages)?.output.isEmpty ?? true)
            }
            XCTAssertTrue(completed)
            XCTAssertFalse(F.toolPart(toolCallId: "phone-progress-\(turn)", in: harness.messages)?.output.isEmpty ?? true)
            let afterTool = try XCTUnwrap(iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID))
            XCTAssertGreaterThan(afterTool.completed, beforeTool, "A completed tool must advance real progress in every round")
            XCTAssertEqual(afterTool.total, -1)
            provider.emit(F.streamChunk(delta: F.assistantText("继续\(turn)")))
            let nextVisible = await waitForCondition { harness.messages.last?.toText() == "继续\(turn)" }
            XCTAssertTrue(nextVisible)
            XCTAssertGreaterThan(try XCTUnwrap(iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)).completed,
                                 afterTool.completed, "The next model turn must not remain clamped at 3/4")
        }
        provider.finishRound()
        let stopped = await waitForHostIdle(host)
        XCTAssertTrue(stopped)
        XCTAssertEqual(harness.log.terminalStatus(), AgentRunStatus.completed.wireName)
        XCTAssertNil(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID))
        XCTAssertNil(phoneControl.ownerRunID)
    }

    func testPhoneWorkProgressStopsAfterOwnerRevocationAndCancellation() async throws {
        let (host, harness, provider, phoneControl, defaults, suite) = try await startPhoneProgressRun()
        defer { host.cancel(); defaults.removePersistentDomain(forName: suite) }
        let started = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(host.currentRunId)
        provider.emit(F.streamChunk(delta: F.assistantText("计划")))
        let appeared = await waitForCondition { harness.messages.last?.toText() == "计划" }
        XCTAssertTrue(appeared)
        let progress = try XCTUnwrap(iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)).completed
        phoneControl.revoke(runID: runID)
        XCTAssertNil(phoneControl.handoffState(runID: runID), "Revocation invalidates active ownership synchronously")
        let released = await waitForCondition { phoneControl.ownerRunID == nil }
        XCTAssertTrue(released, "The existing teardown must naturally release its slot")
        XCTAssertNil(phoneControl.ownerRunID)
        try await Task.sleep(for: .milliseconds(80))
        provider.emit(F.streamChunk(delta: F.assistantText("撤销后到达")))
        let lateApplied = await waitForCondition { harness.messages.last?.toText() == "计划撤销后到达" }
        XCTAssertTrue(lateApplied)
        XCTAssertEqual(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)?.completed, progress,
                       "An ownerless phone run must not report new work")
        host.cancel()
        let stopped = await waitForHostIdle(host)
        XCTAssertTrue(stopped)
        provider.emit(F.streamChunk(delta: F.assistantText("取消后到达")))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID))
        XCTAssertEqual(harness.log.terminalStatus(), AgentRunStatus.cancelled.wireName)
    }

    func testPhoneProgressSurvivesFailedTransferAndStopsAfterSuccessfulTransfer() async throws {
        let (host, harness, provider, phoneControl, defaults, suite) = try await startPhoneProgressRun()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneProgressTransfer-\(UUID().uuidString)")
        defer {
            host.cancel()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = IOSConversationStore(baseDirectory: directory)
        var transferSucceeds = false
        var transferredRunID: String?
        host.backgroundStartOverrideForTesting = { handoff, _ in
            transferredRunID = handoff.runId
            return transferSucceeds
        }
        let started = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(host.currentRunId)
        provider.emit(F.streamChunk(delta: F.assistantText("计划")))
        let appeared = await waitForCondition { harness.messages.last?.toText() == "计划" }
        XCTAssertTrue(appeared)
        let before = try XCTUnwrap(iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID))
        XCTAssertFalse(host.handoffCurrentGenerationToBackground(conversationStore: store))
        XCTAssertEqual(transferredRunID, runID)
        XCTAssertEqual(host.currentRunId, runID)
        XCTAssertEqual(phoneControl.ownerRunID, runID)
        let restored = try XCTUnwrap(iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID))
        XCTAssertEqual(restored.completed, before.completed)
        XCTAssertEqual(restored.total, -1)
        try await Task.sleep(for: .milliseconds(80))
        provider.emit(F.streamChunk(delta: F.assistantText("继续")))
        let continued = await waitForCondition { harness.messages.last?.toText() == "计划继续" }
        XCTAssertTrue(continued)
        XCTAssertGreaterThan(try XCTUnwrap(iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)).completed, before.completed)
        transferSucceeds = true
        XCTAssertTrue(host.handoffCurrentGenerationToBackground(conversationStore: store))
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(phoneControl.ownerRunID, runID, "The successful background owner retains phone authorization")
        XCTAssertNil(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID))
        provider.emit(F.streamChunk(delta: F.assistantText("交接后到达")))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID))
        XCTAssertNil(harness.log.terminalStatus(), "A handoff is not a business terminal")
        await phoneControl.stop(runID: runID)
    }

    func testOrdinaryChatBackgroundProgressKeepsFourStageBehavior() async throws {
        let harness = makeHarness(exposedToolNames: ["session_search"])
        let provider = IOSChatProgressStreamingProvider()
        let host = makeHost(harness: harness, provider: provider)
        start(host, harness: harness)
        defer { host.cancel() }
        let started = await waitForCondition { provider.callCount == 1 }
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(host.currentRunId)
        XCTAssertEqual(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)?.total, 4)
        XCTAssertEqual(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)?.completed, 1)
        provider.emit(F.streamChunk(delta: F.assistantText("回复")))
        let appeared = await waitForCondition { harness.messages.last?.toText() == "回复" }
        XCTAssertTrue(appeared)
        XCTAssertEqual(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)?.completed, 2)
        try await Task.sleep(for: .milliseconds(80))
        provider.emit(F.streamChunk(delta: F.assistantText("继续")))
        let continued = await waitForCondition { harness.messages.last?.toText() == "回复继续" }
        XCTAssertTrue(continued)
        XCTAssertEqual(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)?.completed, 2)
        provider.emit(F.streamChunk(delta: toolRound("ordinary-progress", "session_search", #"{"query":"amber"}"#).message))
        provider.finishRound()
        let nextRound = await waitForCondition { provider.callCount == 2 }
        XCTAssertTrue(nextRound)
        XCTAssertEqual(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)?.completed, 3)
        XCTAssertEqual(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)?.total, 4)
        provider.emit(F.streamChunk(delta: F.assistantText("完成")))
        let completedText = await waitForCondition { harness.messages.last?.toText() == "完成" }
        XCTAssertTrue(completedText)
        XCTAssertEqual(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID)?.completed, 3)
        provider.finishRound()
        let stopped = await waitForHostIdle(host)
        XCTAssertTrue(stopped)
        XCTAssertEqual(harness.log.terminalStatus(), AgentRunStatus.completed.wireName)
        XCTAssertNil(try iosChatBackgroundLeaseProgress(harness.keepAlive, runID: runID))
    }

}

// The ownership regression never starts native services or writes Keychain.
actor HostPhonePairingStore: IOSPhoneControlCredentialStoring {
    func loadPairing() -> Data? { Data([1]) }
    func savePairing(_ data: Data) { }
    func deletePairing() { }
}

final class IOSChatProgressStreamingProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var chunk: (@Sendable (MessageChunk) -> Void)?
    private var completion: (@Sendable () -> Void)?
    private var uploads: [[UIMessage]] = []
    private var requestParams: [TextGenerationParams] = []

    var callCount: Int { lock.withLock { calls } }
    var latestMessages: [UIMessage] { lock.withLock { uploads.last ?? [] } }
    var capturedParams: [TextGenerationParams] { lock.withLock { requestParams } }

    func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
        IOSChatForegroundFixtures.chunk(with: IOSChatForegroundFixtures.assistantText("unused blocking path"))
    }

    func streamText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams,
                    onChunk: @escaping @Sendable (MessageChunk) -> Void,
                    onComplete: @escaping @Sendable () -> Void,
                    onError: @escaping @Sendable (KotlinThrowable) -> Void) -> Kotlinx_coroutines_coreJob? {
        lock.withLock {
            calls += 1
            uploads.append(messages)
            requestParams.append(params)
            chunk = onChunk
            completion = onComplete
        }
        return nil
    }

    func emit(_ value: MessageChunk) {
        let handler = lock.withLock { chunk }
        handler?(value)
    }

    func finishRound() {
        let handler = lock.withLock { completion }
        handler?()
    }
}

/// Inspect the concrete lease without replacing its clamping behavior or adding a production test API.
@MainActor
func iosChatBackgroundLeaseProgress(_ keepAlive: BackgroundGenerationKeepAlive, runID: String) throws -> (completed: Int64, total: Int64?)? {
    let leases = try XCTUnwrap(Mirror(reflecting: keepAlive).children.first { $0.label == "leases" }?.value)
    for entry in Mirror(reflecting: leases).children {
        let pair = Array(Mirror(reflecting: entry.value).children)
        guard pair.first?.value as? String == runID else { continue }
        let lease = try XCTUnwrap(pair.last?.value)
        let fields = Array(Mirror(reflecting: lease).children)
        let completed = try XCTUnwrap(fields.first { $0.label == "progressCompletedUnitCount" }?.value as? Int64)
        let total = fields.first { $0.label == "progressTotalUnitCount" }?.value as? Int64
        return (completed, total)
    }
    return nil
}
