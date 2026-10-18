import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class WatchCoordinatorDecisionOwnershipTests: IOSChatKernelRunHostTestCase {
    func testOlderApprovalDoesNotPreventAnsweringCurrentRun() async throws {
        let harness = makeHarness(exposedToolNames: ["ask_user"])
        let provider = HostScriptedProvider(rounds: [
            toolRound("current-question", "ask_user", #"{"question":"继续吗？","options":["继续","暂停"]}"#),
            textRound("已收到回答")
        ])
        let host = makeHost(harness: harness, provider: provider)
        defer { host.cancel() }
        let fixture = try makeCoordinator(owning: host)
        defer { _ = fixture.owner }
        let coordinator = fixture.coordinator
        start(host, harness: harness)
        let didPause = await waitForCondition { host.hasPendingToolApproval }
        XCTAssertTrue(didPause)
        let question = WatchAskUserRequest(id: "current-question", question: "继续吗？", options: ["继续", "暂停"])
        let runID = try XCTUnwrap(host.currentRunId)
        coordinator.registerRun(runId: "older-run", startedAt: 100)
        coordinator.registerRun(runId: runID, startedAt: 200)
        coordinator.publishAskUser(
            runId: runID,
            conversationId: harness.conversationId.toHexDashString(),
            request: WatchAskUserRequest(id: question.id, question: question.question, options: question.options)
        )

        coordinator.publishWaitingApproval(
            runId: "older-run", conversationId: "older-conversation",
            prompt: .search(SearchToolApprovalRequest(
                id: "older-approval", toolName: "search_web", target: "amber",
                providerName: "Test", providerType: "test", reason: "确认搜索"
            ))
        )
        let result = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: UUID().uuidString, runId: runID,
            conversationId: harness.conversationId.toHexDashString(), decisionId: question.id,
            action: .choose, optionId: "choice-0", text: nil, createdAt: Date()
        ))

        XCTAssertEqual(coordinator.currentSnapshot().runId, runID)
        XCTAssertTrue(result.accepted, result.message ?? "当前问题必须仍可回答")
        guard result.accepted else {
            host.cancel()
            _ = await waitForHostIdle(host)
            return
        }
        let didFinish = await waitForHostIdle(host)
        XCTAssertTrue(didFinish)
        XCTAssertEqual(provider.callCount, 2, "Watch 回答必须让原 run 实际续跑")
        XCTAssertEqual(harness.messages.last?.toText(), "已收到回答")
        XCTAssertTrue(F.toolOutputText(toolCallId: "current-question", in: harness.messages).contains("继续"))
    }

    func testOlderQuestionDoesNotPreventApprovingCurrentRun() async throws {
        let harness = makeHarness()
        let provider = HostScriptedProvider(rounds: [
            toolRound("current-search", "search_web", #"{"query":"amber"}"#),
            textRound("搜索已完成")
        ])
        let host = makeHost(harness: harness, provider: provider)
        defer { host.cancel() }
        let fixture = try makeCoordinator(owning: host)
        defer { _ = fixture.owner }
        let coordinator = fixture.coordinator
        start(host, harness: harness)
        let didPause = await waitForCondition { harness.pendingSearchApproval != nil && host.hasPendingToolApproval }
        XCTAssertTrue(didPause)
        let approval = try XCTUnwrap(harness.pendingSearchApproval)
        let runID = try XCTUnwrap(host.currentRunId)
        coordinator.registerRun(runId: "older-run", startedAt: 100)
        coordinator.registerRun(runId: runID, startedAt: 200)
        coordinator.publishWaitingApproval(
            runId: runID, conversationId: harness.conversationId.toHexDashString(),
            prompt: .search(approval)
        )

        coordinator.publishAskUser(
            runId: "older-run", conversationId: "older-conversation",
            request: WatchAskUserRequest(id: "older-question", question: "旧问题", options: ["继续"])
        )
        let result = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: UUID().uuidString, runId: runID,
            conversationId: harness.conversationId.toHexDashString(), decisionId: approval.id,
            action: .approve, optionId: "approve", text: nil, createdAt: Date()
        ))

        XCTAssertEqual(coordinator.currentSnapshot().runId, runID)
        XCTAssertTrue(result.accepted, result.message ?? "当前审批必须仍可执行")
        guard result.accepted else {
            host.cancel()
            _ = await waitForHostIdle(host)
            return
        }
        let didFinish = await waitForHostIdle(host)
        XCTAssertTrue(didFinish)
        XCTAssertEqual(provider.callCount, 2, "Watch 批准必须让原 run 实际续跑")
        XCTAssertEqual(harness.messages.last?.toText(), "搜索已完成")
        XCTAssertTrue(harness.log.snapshot().contains(.toolCallFinished(tool: "search_web", outcome: "completed")))
        XCTAssertFalse(F.toolOutputText(toolCallId: "current-search", in: harness.messages).isEmpty)
    }

    private func makeCoordinator(owning host: ChatKernelRunHost) throws -> (coordinator: WatchTaskCoordinator, owner: ChatViewModel) {
        let suite = "WatchCoordinatorDecisionOwnership.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = IosDatabaseFactory.shared.createDatabase(atFilePath: root.appendingPathComponent("runs.db").path)
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(userDefaults: defaults), sharedSettings: settings,
            autoGenerateResponses: false
        )
        viewModel.currentRun.host = host
        let coordinator = WatchTaskCoordinator(
            bridge: WatchConnectivityBridge(),
            companionService: IOSWatchCompanionService(baseDirectory: root.appendingPathComponent("watch"), defaults: defaults),
            deepLinkInbox: IOSDeepLinkInbox(defaults: defaults),
            librarySnapshotProvider: { _, _, _ in
                WatchLibrarySnapshot(assistantName: "Test", isConfigured: true, quickActions: [], recent: [], updatedAt: Date())
            },
            agentRuntimeDao: database.agentRuntimeDao()
        )
        coordinator.attach(chatViewModel: viewModel, sharedSettings: settings)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return (coordinator, viewModel)
    }
}
