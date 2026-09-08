import XCTest
import Shared
@testable import iosApp

private final class WatchTestTransport: WatchConnectivityTransporting {
    var isSupported = true
    var isPaired = true
    var isWatchAppInstalled = true
    var isReachable = true
    var sendError: Error?
    private(set) var transferredUserInfoCount = 0

    init(sendError: Error? = nil) {
        self.sendError = sendError
    }

    func activate() {}
    func updateApplicationContext(_ context: [String: Any]) throws {}
    func transferUserInfo(_ userInfo: [String: Any]) -> String {
        transferredUserInfoCount += 1
        return "transfer"
    }
    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    ) {
        if let sendError {
            errorHandler?(sendError)
        }
    }
}

// @MainActor:部分用例直接构造 MainActor 隔离的 ViewModel/运行时依赖。
@MainActor
final class WatchTaskSnapshotTests: XCTestCase {
    private func makeCoordinator(
        bridge: WatchConnectivityBridge,
        deepLinkInbox: IOSDeepLinkInbox? = nil
    ) -> WatchTaskCoordinator {
        let suite = "WatchCoordinatorTests.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return WatchTaskCoordinator(bridge: bridge, companionService: IOSWatchCompanionService(
            baseDirectory: root, defaults: UserDefaults(suiteName: suite)!
        ), deepLinkInbox: deepLinkInbox ?? IOSDeepLinkInbox())
    }
    func testBridgeActionTimeoutReportsTheMatchingRequestId() async {
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 10_000_000)
        bridge.configure(transport: WatchTestTransport())
        let request = WatchTaskActionRequest(
            requestId: "request-timeout",
            runId: "run-timeout",
            conversationId: "conversation-timeout",
            decisionId: nil,
            action: .cancel,
            optionId: nil,
            text: nil,
            createdAt: Date()
        )
        let resultReceived = expectation(description: "action timeout")
        bridge.onActionResult = { result in
            XCTAssertEqual(result.requestId, request.requestId)
            XCTAssertEqual(result.runId, request.runId)
            XCTAssertFalse(result.accepted)
            XCTAssertTrue(result.message?.contains("超时") == true)
            resultReceived.fulfill()
        }

        bridge.sendAction(request)

        await fulfillment(of: [resultReceived], timeout: 1)
    }

    func testBridgeActionSendFailureReportsTheMatchingRequestId() async {
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000)
        bridge.configure(transport: WatchTestTransport(sendError: NSError(
            domain: "WatchTaskSnapshotTests",
            code: 1
        )))
        let request = WatchTaskActionRequest(
            requestId: "request-failure",
            runId: "run-failure",
            conversationId: "conversation-failure",
            decisionId: nil,
            action: .cancel,
            optionId: nil,
            text: nil,
            createdAt: Date()
        )
        let resultReceived = expectation(description: "action failure")
        bridge.onActionResult = { result in
            XCTAssertEqual(result.requestId, request.requestId)
            XCTAssertEqual(result.runId, request.runId)
            XCTAssertFalse(result.accepted)
            XCTAssertTrue(result.message?.contains("失败") == true)
            resultReceived.fulfill()
        }

        bridge.sendAction(request)

        await fulfillment(of: [resultReceived], timeout: 1)
    }

    func testBridgeDoesNotQueueOfflineCommandsForLateDelivery() async {
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000)
        let transport = WatchTestTransport()
        transport.isReachable = false
        bridge.configure(transport: transport)
        let request = WatchTaskActionRequest(
            requestId: "request-offline",
            runId: "run-offline",
            conversationId: "conversation-offline",
            decisionId: nil,
            action: .cancel,
            optionId: nil,
            text: nil,
            createdAt: Date()
        )
        let resultReceived = expectation(description: "offline failure")
        bridge.onActionResult = { result in
            XCTAssertEqual(result.requestId, request.requestId)
            XCTAssertFalse(result.accepted)
            XCTAssertTrue(result.message?.contains("无法连接") == true)
            resultReceived.fulfill()
        }

        bridge.sendAction(request)

        await fulfillment(of: [resultReceived], timeout: 1)
        XCTAssertEqual(transport.transferredUserInfoCount, 0)
    }

    func testCoordinatorRejectsDecisionFromEarlierNodeInSameRun() async {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        coordinator.publishAskUser(
            runId: "run-1",
            conversationId: "conversation-1",
            request: WatchAskUserRequest(
                id: "decision-b",
                question: "第二个问题",
                options: ["B1", "B2"]
            )
        )

        let result = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: "request-a",
            runId: "run-1",
            conversationId: "conversation-1",
            decisionId: "decision-a",
            action: .choose,
            optionId: "choice-0",
            text: nil,
            createdAt: Date()
        ))

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.message, "这个确认步骤已失效")
        XCTAssertEqual(coordinator.currentSnapshot().decision?.id, "decision-b")
    }

    func testCoordinatorClearsSummaryWhenANewRunStartsWithoutOne() {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        coordinator.publishCompleted(
            runId: "run-a",
            conversationId: "conversation-a",
            summary: "A 的结果"
        )

        coordinator.publish(
            runId: "run-b",
            conversationId: "conversation-b",
            presentation: .generatingResponse(modelName: "model-b")
        )

        let snapshot = coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.runId, "run-b")
        XCTAssertNil(snapshot.summary)
    }

    func testCoordinatorDoesNotClaimCancellationWhenNoRunOwnerAcceptsIt() async {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        coordinator.attach(chatViewModel: viewModel)
        coordinator.publish(
            runId: "background-run-without-owner",
            conversationId: "conversation-1",
            presentation: .generatingResponse(modelName: "model")
        )

        let result = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: "cancel-1",
            runId: "background-run-without-owner",
            conversationId: "conversation-1",
            decisionId: nil,
            action: .cancel,
            optionId: nil,
            text: nil,
            createdAt: Date()
        ))

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.message, "当前任务已经结束或不再由 iPhone 执行")
    }

    func testAttachProjectsHydratedBackgroundRunAsReconnectingInsteadOfIdle() {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )

        coordinator.attach(
            chatViewModel: viewModel,
            reconnecting: [WatchTaskReconnectProjection(
                runId: "hydrated-background-run",
                conversationId: "hydrated-conversation",
                startedAt: 1_700_000_000_000
            )]
        )

        let snapshot = coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.runId, "hydrated-background-run")
        XCTAssertEqual(snapshot.conversationId, "hydrated-conversation")
        XCTAssertEqual(snapshot.phase, AgentActivityPhase.reconnecting.rawValue)
        XCTAssertNotEqual(snapshot.phase, "idle")
    }

    func testColdAttachPrimesAllBackgroundRunGenerationsBeforePublishingLatest() {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        coordinator.attach(
            chatViewModel: viewModel,
            reconnecting: [
                WatchTaskReconnectProjection(
                    runId: "run-old",
                    conversationId: "conversation-old",
                    startedAt: 100
                ),
                WatchTaskReconnectProjection(
                    runId: "run-new",
                    conversationId: "conversation-new",
                    startedAt: 200
                )
            ]
        )

        coordinator.publish(
            runId: "run-old",
            conversationId: "conversation-old",
            presentation: .generatingResponse(modelName: "model")
        )

        XCTAssertEqual(coordinator.currentSnapshot().runId, "run-new")
        XCTAssertEqual(coordinator.currentSnapshot().phase, AgentActivityPhase.reconnecting.rawValue)
    }

    func testRepeatedAttachDoesNotLetAnOlderRunReclaimTheWatchProjection() {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        coordinator.publish(
            runId: "run-new",
            conversationId: "conversation-new",
            presentation: .generatingResponse(modelName: "model")
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        coordinator.attach(
            chatViewModel: viewModel,
            reconnecting: [
                WatchTaskReconnectProjection(
                    runId: "run-old",
                    conversationId: "conversation-old",
                    startedAt: 100
                ),
                WatchTaskReconnectProjection(
                    runId: "run-new",
                    conversationId: "conversation-new",
                    startedAt: 200
                )
            ]
        )

        coordinator.publish(
            runId: "run-old",
            conversationId: "conversation-old",
            presentation: .completed()
        )

        XCTAssertEqual(coordinator.currentSnapshot().runId, "run-new")
        XCTAssertEqual(coordinator.currentSnapshot().phase, AgentActivityPhase.running.rawValue)
    }

    func testRegisteredStartTimeWinsWhenOlderRunPublishesLater() {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        coordinator.registerRun(runId: "run-old", startedAt: 100)
        coordinator.registerRun(runId: "run-new", startedAt: 200)
        coordinator.publish(
            runId: "run-new",
            conversationId: "conversation-new",
            presentation: .generatingResponse(modelName: "model")
        )

        coordinator.publish(
            runId: "run-old",
            conversationId: "conversation-old",
            presentation: .completed()
        )

        XCTAssertEqual(coordinator.currentSnapshot().runId, "run-new")
        XCTAssertEqual(coordinator.currentSnapshot().phase, AgentActivityPhase.running.rawValue)
    }

    func testCodecRoundTripKeepsDecisionAndSummary() throws {
        let decision = WatchDecision(
            id: "decision-1",
            type: .approval,
            title: "网络搜索",
            body: "查询 Swift concurrency",
            options: [
                WatchDecisionOption(id: "deny", title: "拒绝", style: .deny),
                WatchDecisionOption(id: "approve", title: "允许", style: .approve)
            ],
            riskLevel: .medium,
            allowsVoice: false
        )
        let snapshot = WatchTaskSnapshot(
            runId: "run-123",
            languageCode: IOSAppLanguage.japanese.rawValue,
            conversationId: "01234567-89ab-cdef-0123-456789abcdef",
            kind: AgentActivityKind.research.rawValue,
            phase: AgentActivityPhase.waitingForUser.rawValue,
            stage: AgentActivityStage.waitingForConfirmation.rawValue,
            headline: "Deep research",
            detail: "Waiting for confirmation",
            summary: nil,
            metricText: "3",
            decision: decision,
            actions: [.openOnPhone, .approve, .deny, .cancel],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isStale: false
        )

        let data = try WatchTaskCodec.encodeSnapshot(snapshot)
        let decoded = try WatchTaskCodec.decodeSnapshot(data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.languageCode, IOSAppLanguage.japanese.rawValue)

        let message = try WatchTaskCodec.snapshotMessage(for: snapshot)
        XCTAssertEqual(message[WatchConnectivityPayloadKey.type] as? String, WatchConnectivityPayloadKey.typeSnapshot)
        XCTAssertEqual(
            message[WatchConnectivityPayloadKey.protocolVersion] as? Int,
            WatchConnectivityPayloadKey.currentProtocolVersion
        )
    }

    func testCodecDecodesLegacySnapshotWithoutLanguageCode() throws {
        let data = Data(
            #"{"actions":[],"conversationId":null,"detail":null,"headline":"Amber","isStale":false,"kind":"workflow","metricText":null,"phase":"idle","runId":"","stage":"idle","summary":null,"updatedAt":"1970-01-01T00:00:00Z"}"#.utf8
        )

        let decoded = try WatchTaskCodec.decodeSnapshot(data)

        XCTAssertNil(decoded.languageCode)
        XCTAssertEqual(decoded.runId, "")
        XCTAssertEqual(decoded.phase, "idle")
        XCTAssertEqual(decoded.headline, "Amber")
    }

    func testBuilderApprovalDecisionDoesNotLeakRawToolPayload() {
        let request = SearchToolApprovalRequest(
            id: "search-1",
            toolName: "search_web",
            target: "https://example.com/secret-token=abc",
            providerName: "Bing",
            providerType: "bing",
            reason: "网络搜索和网页读取会访问外部站点，需要你确认。"
        )
        let decision = WatchTaskSnapshotBuilder.decision(from: .search(request))
        XCTAssertEqual(decision.type, .approval)
        XCTAssertEqual(decision.title, "执行网络搜索")
        XCTAssertTrue(decision.body.contains("example.com"))
        XCTAssertTrue(decision.body.contains("Bing"))
        XCTAssertTrue(decision.body.contains("bing"))
        XCTAssertFalse(decision.body.contains("api_key"))
        XCTAssertEqual(decision.options.map(\.id), ["deny", "approve", "open-phone"])
    }

    func testBuilderSkillImportDecisionKeepsCandidateIdentityCompact() {
        let request = McpToolApprovalRequest(
            id: "skill-import-1",
            serverName: "local",
            toolName: "skill_import",
            argumentsPreview: "this fallback must not define candidate identity",
            reason: "请核对完整文件变更。",
            skillImportPreview: McpSkillImportPreview(
                skillName: "a-very-long-skill-name-that-needs-watch-truncation",
                mutationKind: .update,
                baseHash: "0123456789abcdef",
                candidateHash: "fedcba9876543210",
                beforeSummary: "before",
                afterSummary: "after",
                changedFiles: [
                    McpSkillImportFileChange(path: "SKILL.md", kind: .modified),
                    McpSkillImportFileChange(path: "mcp.json", kind: .added)
                ]
            )
        )

        let decision = WatchTaskSnapshotBuilder.decision(from: .mcp(request))

        XCTAssertTrue(decision.body.contains("更新"))
        XCTAssertTrue(decision.body.contains("a-very-long-skill-name-that-…"))
        XCTAssertTrue(decision.body.contains("2 处变更"))
        XCTAssertTrue(decision.body.contains("01234567"))
        XCTAssertTrue(decision.body.contains("fedcba98"))
        XCTAssertEqual(decision.options.map(\.id), ["deny", "open-phone"])
        XCTAssertFalse(decision.options.contains(where: { $0.style == .approve }))
        XCTAssertFalse(decision.body.contains("local.skill_import"))
        XCTAssertFalse(decision.body.contains("SKILL.md"))
    }

    func testBuilderClipsCompletedSummary() {
        let long = String(repeating: "总结", count: 200)
        let snapshot = WatchTaskSnapshotBuilder.make(
            runId: "run-9",
            conversationId: "conv-1",
            presentation: .completed(),
            summary: long
        )
        XCTAssertEqual(snapshot.phase, AgentActivityPhase.completed.rawValue)
        XCTAssertNotNil(snapshot.summary)
        XCTAssertLessThanOrEqual(snapshot.summary?.count ?? 0, 281)
        XCTAssertTrue(snapshot.actions.contains(.openOnPhone))
        XCTAssertFalse(snapshot.actions.contains(.approve))
    }

    func testDecisionWithoutConversationOffersNoOpenPhonePath() {
        let snapshot = WatchTaskSnapshotBuilder.make(
            runId: "run-no-conversation",
            conversationId: nil,
            presentation: .waitingForUser(kind: .workflow),
            decision: WatchTaskSnapshotBuilder.askUserDecision(from: WatchAskUserRequest(
                id: "ask-no-conversation",
                question: "继续吗？",
                options: ["继续"]
            ))
        )

        XCTAssertFalse(snapshot.actions.contains(.openOnPhone))
        XCTAssertFalse(snapshot.decision?.options.contains(where: { $0.style == .openOnPhone }) == true)
    }

    func testCoordinatorRejectsOpenPhoneWithoutConversation() async {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        coordinator.publishAskUser(
            runId: "run-no-conversation",
            conversationId: nil,
            request: WatchAskUserRequest(
                id: "ask-no-conversation",
                question: "继续吗？",
                options: ["继续"]
            )
        )

        let result = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: "open-no-conversation",
            runId: "run-no-conversation",
            conversationId: nil,
            decisionId: "ask-no-conversation",
            action: .openOnPhone,
            optionId: "open-phone",
            text: nil,
            createdAt: Date()
        ))

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.message, "当前任务没有可打开的会话")
    }

    func testCoordinatorDeduplicatesTheSameWatchCommand() async {
        let inbox = IOSDeepLinkInbox()
        var handedOffURLs: [URL] = []
        inbox.installHandler { handedOffURLs.append($0) }
        let coordinator = makeCoordinator(
            bridge: WatchConnectivityBridge(),
            deepLinkInbox: inbox
        )
        coordinator.publish(
            runId: "run-deduplicated",
            conversationId: "conversation-deduplicated",
            presentation: .failed()
        )
        let request = WatchTaskActionRequest(
            requestId: "stable-idempotency-key",
            runId: "run-deduplicated",
            conversationId: "conversation-deduplicated",
            decisionId: nil,
            action: .openOnPhone,
            optionId: nil,
            text: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let first = await coordinator.handleWatchAction(request)
        let duplicate = await coordinator.handleWatchAction(request)

        XCTAssertTrue(first.accepted)
        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(handedOffURLs.count, 1)
        XCTAssertEqual(
            handedOffURLs.first.flatMap { IOSAppDeepLink.parse($0) },
            .agentActivity(AgentActivityDeepLink.Target(
                runId: "run-deduplicated",
                conversationId: "conversation-deduplicated",
                focus: .task
            ))
        )
    }

    func testCoordinatorOpensPersistedCompletedRunAfterColdAttach() async throws {
        let runId = "watch-cold-open-\(UUID().uuidString)"
        let conversationId = "conversation-\(UUID().uuidString)"
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let dao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao()
        let run = AgentRunEntity(
            runId: runId,
            parentRunId: nil,
            agentDescriptorId: "chat",
            agentVersion: "1",
            conversationId: conversationId,
            messageNodeId: nil,
            producesMessageId: nil,
            assistantId: nil,
            status: "completed",
            inputDigest: "watch-cold-open",
            inputSnapshotRef: nil,
            inputSchemaVersion: 1,
            startedAt: now,
            finishedAt: KotlinLong(value: now),
            interruptedReason: nil,
            terminalReason: nil,
            providerId: nil,
            modelId: nil,
            promptVersion: nil,
            toolCatalogVersion: nil,
            capabilitySnapshot: nil
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dao.insertRunIfAbsent(run: run) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        let inbox = IOSDeepLinkInbox()
        var handedOffURLs: [URL] = []
        inbox.installHandler { handedOffURLs.append($0) }
        let coordinator = makeCoordinator(
            bridge: WatchConnectivityBridge(),
            deepLinkInbox: inbox
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        coordinator.attach(chatViewModel: viewModel)

        let result = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: "cold-open-\(UUID().uuidString)",
            runId: runId,
            conversationId: conversationId,
            decisionId: nil,
            action: .openOnPhone,
            optionId: nil,
            text: nil,
            createdAt: Date()
        ))

        XCTAssertTrue(result.accepted)
        XCTAssertEqual(handedOffURLs.count, 1)
        XCTAssertEqual(
            handedOffURLs.first.flatMap { IOSAppDeepLink.parse($0) },
            .agentActivity(AgentActivityDeepLink.Target(
                runId: runId,
                conversationId: conversationId,
                focus: .result
            ))
        )
    }

    func testCoordinatorRejectsRetryFromAnOlderWatchSnapshot() async {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        coordinator.publish(
            runId: "run-new",
            conversationId: "conversation-1",
            presentation: .generatingResponse(modelName: "model")
        )

        let result = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: "retry-old",
            runId: "run-old",
            conversationId: "conversation-1",
            decisionId: nil,
            action: .retry,
            optionId: nil,
            text: nil,
            createdAt: Date()
        ))

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.message, "这个失败任务已失效")
    }

    func testOlderRunCannotOverwriteTheNewestWatchProjection() {
        let bridge = WatchConnectivityBridge()
        let coordinator = makeCoordinator(bridge: bridge)
        coordinator.publish(
            runId: "run-old",
            conversationId: "conversation-old",
            presentation: .generatingResponse(modelName: "model")
        )
        coordinator.publish(
            runId: "run-new",
            conversationId: "conversation-new",
            presentation: .generatingResponse(modelName: "model")
        )

        coordinator.publish(
            runId: "run-old",
            conversationId: "conversation-old",
            presentation: .failed(retryable: true)
        )

        XCTAssertEqual(coordinator.currentSnapshot().runId, "run-new")
        XCTAssertEqual(coordinator.currentSnapshot().phase, "running")
    }

    func testOlderRunCannotReclaimWatchProjectionAfterNewestRunCompletes() {
        let bridge = WatchConnectivityBridge()
        let coordinator = makeCoordinator(bridge: bridge)
        coordinator.publish(
            runId: "run-old",
            conversationId: "conversation-old",
            presentation: .generatingResponse(modelName: "model")
        )
        coordinator.publish(
            runId: "run-new",
            conversationId: "conversation-new",
            presentation: .generatingResponse(modelName: "model")
        )
        coordinator.publishCompleted(
            runId: "run-new",
            conversationId: "conversation-new",
            summary: "done"
        )

        coordinator.publish(
            runId: "run-old",
            conversationId: "conversation-old",
            presentation: .generatingResponse(modelName: "model")
        )

        XCTAssertEqual(coordinator.currentSnapshot().runId, "run-new")
        XCTAssertEqual(coordinator.currentSnapshot().phase, "completed")
    }

    func testAskUserDecisionSupportsChoicesAndVoice() {
        let longOption = String(repeating: "选", count: 500)
        let question = "下一章要不要加入反转？"
        let request = WatchAskUserRequest(
            id: "ask-1",
            question: question,
            options: ["加入", "不加入", "先缓一缓", "四", "五", longOption]
        )
        let decision = WatchTaskSnapshotBuilder.askUserDecision(from: request)
        XCTAssertEqual(decision.type, .askUser)
        XCTAssertTrue(decision.allowsVoice)
        XCTAssertEqual(decision.body, question)
        XCTAssertTrue(decision.options.contains(where: { $0.id == "choice-0" }))
        XCTAssertTrue(decision.options.contains(where: { $0.id == "choice-5" }))
        XCTAssertFalse(decision.options.contains(where: { $0.id == "choice-6" }))
        XCTAssertEqual(
            decision.options.first(where: { $0.id == "choice-5" })?.title,
            longOption
        )
        XCTAssertTrue(decision.options.contains(where: { $0.id == "skip" }))
        XCTAssertTrue(decision.options.contains(where: { $0.id == "dictate" }))

        let snapshot = WatchTaskSnapshotBuilder.make(
            runId: "run-ask-valid",
            conversationId: "conversation-ask-valid",
            presentation: .waitingForUser(kind: .workflow),
            decision: decision
        )
        XCTAssertTrue(snapshot.actions.contains(.choose))
        XCTAssertTrue(snapshot.actions.contains(.dictate))
    }

    func testAskUserDecisionRejectsIncompleteContentAndProjectsOnlyPhoneActions() {
        let cases = [
            WatchAskUserRequest(
                id: "ask-empty-question",
                question: " \n ",
                options: ["继续"]
            ),
            WatchAskUserRequest(
                id: "ask-long-question",
                question: String(repeating: "问", count: 2_001),
                options: ["继续"]
            ),
            WatchAskUserRequest(
                id: "ask-too-many-options",
                question: "选择方案",
                options: ["一", "二", "三", "四", "五", "六", "七"]
            ),
            WatchAskUserRequest(
                id: "ask-long-option",
                question: "选择方案",
                options: [String(repeating: "选", count: 501)]
            )
        ]

        for request in cases {
            let decision = WatchTaskSnapshotBuilder.askUserDecision(from: request)
            XCTAssertEqual(decision.options.map(\.id), ["skip", "open-phone"])
            XCTAssertFalse(decision.allowsVoice)

            let snapshot = WatchTaskSnapshotBuilder.make(
                runId: "run-\(request.id)",
                conversationId: "conversation-\(request.id)",
                presentation: .waitingForUser(kind: .workflow),
                decision: decision
            )
            XCTAssertFalse(snapshot.actions.contains(.choose))
            XCTAssertFalse(snapshot.actions.contains(.dictate))
            XCTAssertTrue(snapshot.actions.contains(.cancel))
        }
    }

    func testOutcomeUnknownDecisionOnlyOffersPhoneReconciliation() {
        let decision = WatchTaskSnapshotBuilder.outcomeUnknownDecision(id: "unknown-run")

        XCTAssertEqual(decision.type, .voiceReply)
        XCTAssertEqual(decision.options.map(\.id), ["open-phone"])
        XCTAssertFalse(decision.allowsVoice)
        XCTAssertTrue(WatchTaskSnapshotBuilder.isPhoneOnlyDecision(decision))

        let snapshot = WatchTaskSnapshotBuilder.make(
            runId: "unknown-run",
            conversationId: "conversation-unknown",
            presentation: .waitingForUser(kind: .workflow),
            decision: decision
        )

        XCTAssertEqual(snapshot.decision?.options.map(\.style), [.openOnPhone])
        XCTAssertTrue(snapshot.actions.isEmpty)
        XCTAssertFalse(snapshot.actions.contains(.cancel))
        XCTAssertFalse(snapshot.actions.contains(.approve))
        XCTAssertFalse(snapshot.actions.contains(.deny))
        XCTAssertFalse(snapshot.actions.contains(.retry))
    }

    func testCoordinatorReconciledOutcomeUnknownClearsOnlyResolvedGate() {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        let descriptor = IOSToolOutcomeUnknownDescriptor(
            runId: "unknown-run",
            conversationId: "conversation-unknown",
            toolCallId: "tool-1",
            toolName: "workspace_write"
        )

        XCTAssertTrue(coordinator.publishOutcomeUnknown(descriptor))
        XCTAssertEqual(coordinator.currentSnapshot().phase, AgentActivityPhase.waitingForUser.rawValue)
        XCTAssertTrue(
            WatchTaskSnapshotBuilder.isPhoneOnlyDecision(coordinator.currentSnapshot().decision)
        )

        XCTAssertTrue(coordinator.publishOutcomeUnknownReconciled(
            runId: descriptor.runId,
            conversationId: descriptor.conversationId,
            toolCallId: descriptor.toolCallId,
            hasRemainingUnknown: false,
            didApply: true
        ))
        XCTAssertEqual(coordinator.currentSnapshot().phase, WatchTaskSnapshot.idle.phase)
        XCTAssertNil(coordinator.currentSnapshot().decision)
    }

    func testCoordinatorReconciledOutcomeUnknownDoesNotInventTerminalResult() {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        let descriptor = IOSToolOutcomeUnknownDescriptor(
            runId: "unknown-not-applied",
            conversationId: "conversation-unknown",
            toolCallId: "tool-2",
            toolName: "workspace_write"
        )

        XCTAssertTrue(coordinator.publishOutcomeUnknown(descriptor))
        XCTAssertTrue(coordinator.publishOutcomeUnknownReconciled(
            runId: descriptor.runId,
            conversationId: descriptor.conversationId,
            toolCallId: descriptor.toolCallId,
            hasRemainingUnknown: false,
            didApply: false
        ))

        let snapshot = coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.phase, WatchTaskSnapshot.idle.phase)
        XCTAssertNil(snapshot.decision)
    }

    func testCoordinatorKeepsPhoneGateWhenAnotherUnknownToolRemains() {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        let descriptor = IOSToolOutcomeUnknownDescriptor(
            runId: "unknown-multiple",
            conversationId: "conversation-unknown",
            toolCallId: "tool-1",
            toolName: "workspace_write"
        )

        XCTAssertTrue(coordinator.publishOutcomeUnknown(descriptor))
        XCTAssertTrue(coordinator.publishOutcomeUnknownReconciled(
            runId: descriptor.runId,
            conversationId: descriptor.conversationId,
            toolCallId: descriptor.toolCallId,
            hasRemainingUnknown: true,
            didApply: true
        ))

        let snapshot = coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.phase, AgentActivityPhase.waitingForUser.rawValue)
        XCTAssertTrue(WatchTaskSnapshotBuilder.isPhoneOnlyDecision(snapshot.decision))
        XCTAssertFalse(snapshot.actions.contains(.cancel))
    }

    func testCoordinatorRejectsCancelForOutcomeUnknown() async {
        let coordinator = makeCoordinator(bridge: WatchConnectivityBridge())
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        coordinator.attach(chatViewModel: viewModel)
        coordinator.publishOutcomeUnknown(
            runId: "unknown-cancel",
            conversationId: "conversation-unknown"
        )

        let result = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: "cancel-outcome-unknown",
            runId: "unknown-cancel",
            conversationId: "conversation-unknown",
            decisionId: nil,
            action: .cancel,
            optionId: nil,
            text: nil,
            createdAt: Date()
        ))

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.message, "操作结果待核实，请在原 iPhone 对话中确认")
        XCTAssertEqual(
            coordinator.currentSnapshot().phase,
            AgentActivityPhase.waitingForUser.rawValue
        )
    }

    func testTextHelpersClipAndCollapseNewlines() {
        XCTAssertEqual(WatchTaskText.clipped("  hello  ", maxLength: 10), "hello")
        XCTAssertEqual(
            WatchTaskText.singleLine("a\nb\tc", maxLength: 10),
            "a b c"
        )
        let clipped = WatchTaskText.clipped(String(repeating: "x", count: 20), maxLength: 8)
        XCTAssertEqual(clipped?.count, 9) // 8 + ellipsis
        XCTAssertTrue(clipped?.hasSuffix("…") == true)
    }

    func testSnapshotMessageCarriesCurrentProtocolVersion() throws {
        let snapshot = WatchTaskSnapshotBuilder.make(
            runId: "run-1",
            conversationId: "conv-1",
            presentation: .generatingResponse(modelName: "m")
        )
        let message = try WatchTaskCodec.snapshotMessage(for: snapshot)
        XCTAssertEqual(
            message[WatchConnectivityPayloadKey.protocolVersion] as? Int,
            WatchConnectivityPayloadKey.currentProtocolVersion
        )
        XCTAssertEqual(
            message[WatchConnectivityPayloadKey.type] as? String,
            WatchConnectivityPayloadKey.typeSnapshot
        )
    }

    func testApprovalDecisionUsesConfirmationOpenPath() {
        let prompt: ChatToolApprovalPrompt = .search(
            SearchToolApprovalRequest(
                id: "search-2",
                toolName: "search_web",
                target: "swift concurrency",
                providerName: "Bing",
                providerType: "bing",
                reason: "需要确认"
            )
        )
        let decision = WatchTaskSnapshotBuilder.decision(from: prompt)
        XCTAssertEqual(decision.type, .approval)
        XCTAssertTrue(WatchTaskSnapshotBuilder.allowsApprovalOnWatch(prompt))
        XCTAssertTrue(decision.options.contains(where: { $0.style == .approve }))
        XCTAssertTrue(decision.options.contains(where: { $0.style == .openOnPhone }))
        XCTAssertTrue(decision.body.contains("swift concurrency"))
        XCTAssertTrue(decision.body.contains("Bing"))
        XCTAssertTrue(decision.body.contains("bing"))
    }

    func testBuilderDeniesWatchApprovalForNonSearchPromptsRegardlessOfRisk() {
        let prompts: [ChatToolApprovalPrompt] = [
            .memory(
                MemoryToolApprovalRequest(
                    id: "memory-high-risk",
                    action: "create",
                    scope: "core",
                    kind: "note",
                    contentPreview: "记忆内容",
                    targetId: nil,
                    expectedUpdatedAt: nil,
                    reason: "需要确认"
                )
            ),
            .workspace(
                WorkspaceToolApprovalRequest(
                    id: "workspace-high-risk",
                    toolName: "workspace_write",
                    action: "写入",
                    target: "notes/today.md",
                    isWrite: true,
                    reason: "需要确认"
                )
            ),
            .ish(
                IshHandoffToolApprovalRequest(
                    id: "ish-high-risk",
                    mode: .embeddedExecute,
                    commandPreview: "echo unsafe",
                    filename: "script.sh",
                    reason: "需要确认"
                )
            ),
            .mcp(
                McpToolApprovalRequest(
                    id: "mcp-high-risk",
                    serverName: "remote",
                    toolName: "send_message",
                    argumentsPreview: "{\"body\":\"secret\"}",
                    reason: "需要确认"
                )
            ),
            .council(
                CouncilToolApprovalRequest(
                    id: "council-high-risk",
                    objectivePreview: "并行执行任务",
                    maxSeats: 3,
                    reason: "需要确认"
                )
            )
        ]

        for prompt in prompts {
            let decision = WatchTaskSnapshotBuilder.decision(from: prompt)
            let snapshot = WatchTaskSnapshotBuilder.make(
                runId: "run-\(decision.id)",
                conversationId: "conversation-\(decision.id)",
                presentation: .waitingForUser(kind: .workflow),
                decision: decision
            )
            XCTAssertFalse(
                WatchTaskSnapshotBuilder.allowsApprovalOnWatch(prompt),
                "非 search prompt 不得在 Watch 批准"
            )
            XCTAssertFalse(decision.options.contains(where: { $0.style == .approve }))
            XCTAssertTrue(decision.options.contains(where: { $0.style == .deny }))
            XCTAssertTrue(decision.options.contains(where: { $0.style == .openOnPhone }))
            XCTAssertFalse(snapshot.actions.contains(.approve))
            XCTAssertTrue(snapshot.actions.contains(.deny))
        }
    }

    func testBuilderDeniesApprovalWhenSearchPreviewIsTooLongOrIncomplete() {
        let cases: [SearchToolApprovalRequest] = [
            SearchToolApprovalRequest(
                id: "search-too-long",
                toolName: "search_web",
                target: String(repeating: "x", count: 181),
                providerName: "Bing",
                providerType: "bing",
                reason: "需要确认"
            ),
            SearchToolApprovalRequest(
                id: "search-truncated",
                toolName: "search_web",
                target: "swift concurrency...",
                providerName: "Bing",
                providerType: "bing",
                reason: "需要确认"
            ),
            SearchToolApprovalRequest(
                id: "search-missing-service",
                toolName: "search_web",
                target: "swift concurrency",
                providerName: "",
                providerType: "bing",
                reason: "需要确认"
            ),
            SearchToolApprovalRequest(
                id: "search-missing-content",
                toolName: "search_web",
                target: "",
                providerName: "Bing",
                providerType: "bing",
                reason: "需要确认"
            )
        ]

        for request in cases {
            let prompt: ChatToolApprovalPrompt = .search(request)
            let decision = WatchTaskSnapshotBuilder.decision(from: prompt)
            XCTAssertFalse(WatchTaskSnapshotBuilder.allowsApprovalOnWatch(prompt))
            XCTAssertFalse(decision.options.contains(where: { $0.style == .approve }))
            XCTAssertEqual(decision.options.map(\.id), ["deny", "open-phone"])
            XCTAssertTrue(decision.body.contains("iPhone"))
        }
    }

    func testBuilderDeniesUnknownSearchToolEvenWithCompletePreview() {
        let prompt: ChatToolApprovalPrompt = .search(
            SearchToolApprovalRequest(
                id: "unknown-search-tool",
                toolName: "search_and_send",
                target: "swift concurrency",
                providerName: "Bing",
                providerType: "bing",
                reason: "需要确认"
            )
        )

        let decision = WatchTaskSnapshotBuilder.decision(from: prompt)

        XCTAssertFalse(WatchTaskSnapshotBuilder.allowsApprovalOnWatch(prompt))
        XCTAssertFalse(decision.options.contains(where: { $0.style == .approve }))
        XCTAssertEqual(decision.options.map(\.id), ["deny", "open-phone"])
    }

    func testBuilderAllowsOnlyPublicHTTPWebReadsOnWatch() {
        let safePrompt: ChatToolApprovalPrompt = .search(
            SearchToolApprovalRequest(
                id: "web-read-safe",
                toolName: "scrape_web",
                target: "https://example.com/article",
                providerName: "公开网页读取",
                providerType: "scrape_web",
                reason: "需要确认"
            )
        )
        let unsafePrompt: ChatToolApprovalPrompt = .search(
            SearchToolApprovalRequest(
                id: "web-read-unsafe",
                toolName: "scrape_web",
                target: "file:///private/secret.txt",
                providerName: "公开网页读取",
                providerType: "scrape_web",
                reason: "需要确认"
            )
        )

        let safeDecision = WatchTaskSnapshotBuilder.decision(from: safePrompt)
        let unsafeDecision = WatchTaskSnapshotBuilder.decision(from: unsafePrompt)

        XCTAssertTrue(WatchTaskSnapshotBuilder.allowsApprovalOnWatch(safePrompt))
        XCTAssertTrue(safeDecision.options.contains(where: { $0.style == .approve }))
        XCTAssertTrue(safeDecision.body.contains("example.com/article"))
        XCTAssertTrue(safeDecision.body.contains("公开网页读取"))
        XCTAssertTrue(safeDecision.body.contains("scrape_web"))
        XCTAssertFalse(WatchTaskSnapshotBuilder.allowsApprovalOnWatch(unsafePrompt))
        XCTAssertFalse(unsafeDecision.options.contains(where: { $0.style == .approve }))
    }

    func testPublishCompletedPathOmitsDecisionInBuilderUsage() {
        // Production publishCompleted passes decision:nil; completed snapshots must not expose approve/deny.
        let snapshot = WatchTaskSnapshotBuilder.make(
            runId: "run-done",
            conversationId: "conv",
            presentation: .completed(),
            summary: "done",
            decision: nil
        )
        XCTAssertEqual(snapshot.phase, AgentActivityPhase.completed.rawValue)
        XCTAssertNil(snapshot.decision)
        XCTAssertFalse(snapshot.actions.contains(.approve))
        XCTAssertFalse(snapshot.actions.contains(.deny))
        XCTAssertTrue(snapshot.actions.contains(.openOnPhone))
    }

    func testFailedSnapshotOffersRetryButStaleSnapshotDoesNot() {
        let failed = WatchTaskSnapshotBuilder.make(
            runId: "run-failed",
            conversationId: "conversation-1",
            presentation: .failed(retryable: true)
        )
        let stale = WatchTaskSnapshotBuilder.make(
            runId: "run-stale",
            conversationId: "conversation-1",
            presentation: AgentActivityPresentation(
                kind: .response,
                phase: .stale,
                stage: .stale
            )
        )

        XCTAssertTrue(failed.actions.contains(.retry))
        XCTAssertFalse(failed.actions.contains(.cancel))
        XCTAssertFalse(stale.actions.contains(.retry))
        XCTAssertFalse(stale.actions.contains(.cancel))
    }

    func testDecisionSwitchMapsAskUserPromptToAskUserDecision() {
        let request = ChatAskUserRequest(
            id: "ask-prompt-1",
            question: "继续用 A 方案还是 B 方案？",
            options: ["A", "B"]
        )
        let decision = WatchTaskSnapshotBuilder.decision(from: .askUser(request))
        XCTAssertEqual(decision.type, .askUser)
        XCTAssertEqual(decision.id, "ask-prompt-1")
        XCTAssertTrue(decision.body.contains("A 方案") || decision.body.contains("继续用"))
        XCTAssertTrue(decision.options.contains(where: { $0.id == "choice-0" }))
        XCTAssertTrue(decision.options.contains(where: { $0.id == "skip" }))
        XCTAssertTrue(decision.allowsVoice)
    }

    func testAskUserRequestBuilderDecodesQuestionAndOptions() {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "tool-ask-1",
            toolName: "ask_user",
            input: #"{"question":"下一步做什么？","options":["继续","暂停","换方向"]}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let request = ChatToolApprovalRequestBuilder.askUser(for: toolCall)
        XCTAssertEqual(request?.question, "下一步做什么？")
        XCTAssertEqual(request?.options, ["继续", "暂停", "换方向"])
        XCTAssertEqual(request?.id, "tool-ask-1")
    }

    func testFinishAskUserAnswerWritesAnswerJSON() {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "tool-ask-2",
            toolName: "ask_user",
            input: #"{"question":"是否继续？","options":["是","否"]}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let assistantSeed = UIMessage.companion.assistant(prompt: "")
        let assistant = UIMessage(
            id: assistantSeed.id,
            role: assistantSeed.role,
            parts: [toolCall],
            annotations: assistantSeed.annotations,
            createdAt: assistantSeed.createdAt,
            finishedAt: assistantSeed.finishedAt,
            modelId: assistantSeed.modelId,
            usage: assistantSeed.usage,
            translation: assistantSeed.translation
        )
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(
                userDefaults: UserDefaults(suiteName: "WatchAskUserTests-\(UUID().uuidString)")!
            ),
            localToolExecutor: nil,
            searchTransport: IOSURLSessionSearchHTTPTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "OpenAI",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "test-key",
            baseUrl: "https://example.com",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        let model = Model(
            modelId: "test-model",
            displayName: "Test Model",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let pending = ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: provider,
            params: TextGenerationParams(
                model: model,
                temperature: nil,
                topP: nil,
                maxTokens: nil,
                tools: [],
                reasoningLevel: ReasoningLevel.off,
                customHeaders: [],
                customBody: []
            ),
            runId: "run-ask",
            startedAt: 1,
            inputDigest: "digest",
            conversationId: nil,
            baseMessages: [assistant]
        )
        let answered = runtime.finishAskUserAnswer(pending: pending, answer: "继续")
        let finishedTool = answered
            .flatMap { $0.parts.compactMap { $0 as? UIMessagePart.Tool } }
            .first { $0.toolCallId == "tool-ask-2" }
        XCTAssertNotNil(finishedTool)
        let outputText = finishedTool?.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined() ?? ""
        XCTAssertTrue(outputText.contains("\"answer\""))
        XCTAssertTrue(outputText.contains("继续"))

        let skipped = runtime.finishAskUserAnswer(pending: pending, answer: "  ")
        let skippedTool = skipped
            .flatMap { $0.parts.compactMap { $0 as? UIMessagePart.Tool } }
            .first { $0.toolCallId == "tool-ask-2" }
        let skippedText = skippedTool?.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined() ?? ""
        XCTAssertTrue(skippedText.contains("denied"))
    }
}
