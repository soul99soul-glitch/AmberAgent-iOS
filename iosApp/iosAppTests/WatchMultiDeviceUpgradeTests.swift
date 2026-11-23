import XCTest
@testable import iosApp

private final class WatchUpgradeTestTransport: WatchConnectivityTransporting {
    var isSupported = true
    var isPaired = true
    var isWatchAppInstalled = true
    var isReachable: Bool
    var sentActions: [WatchTaskActionRequest] = []

    init(isReachable: Bool = true) {
        self.isReachable = isReachable
    }

    func activate() {}
    func updateApplicationContext(_ context: [String: Any]) throws {}
    func transferUserInfo(_ userInfo: [String: Any]) -> String { "transfer" }

    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    ) {
        guard let data = message[WatchConnectivityPayloadKey.action] as? Data,
              let request = try? WatchTaskCodec.decodeAction(data) else { return }
        sentActions.append(request)
    }
}

@MainActor
private final class FakeWatchRemoteGateway: WatchRemoteExecutionRouting {
    var projection = WatchRemoteExecutionProjection.unpaired
    var submittedQuestions: [(text: String, requestId: String, preferredOrigin: WatchExecutionOrigin?)] = []
    var resolvedApprovals: [(sessionKey: String, toolCallId: String, allow: Bool)] = []
    var askUserReplies: [(workItemId: String?, conversationId: String?, text: String, requestId: String)] = []
    var cancelledTasks: [(workItemId: String?, requestId: String?)] = []

    var nextDispatchOutcome = WatchRemoteDispatchOutcome(
        accepted: true,
        message: "已发送到云端",
        runId: "remote:cloud:wi-1",
        conversationId: "cloud-conv-1",
        deliveryUnknown: false
    )
    var nextApprovalResult: (Bool, String) = (true, "已允许")
    var nextAskUserResult: (Bool, String) = (true, "已提交回答")
    var nextCancelResult: (Bool, String) = (true, "已取消")

    func currentProjection() -> WatchRemoteExecutionProjection {
        projection
    }

    func submitQuestion(
        text: String,
        requestId: String,
        preferredOrigin: WatchExecutionOrigin?
    ) async -> WatchRemoteDispatchOutcome {
        submittedQuestions.append((text, requestId, preferredOrigin))
        return nextDispatchOutcome
    }

    func resolveApproval(
        sessionKey: String,
        toolCallId: String,
        allow: Bool
    ) async -> (accepted: Bool, message: String) {
        resolvedApprovals.append((sessionKey, toolCallId, allow))
        return nextApprovalResult
    }

    func submitAskUserReply(
        workItemId: String?,
        conversationId: String?,
        text: String,
        requestId: String
    ) async -> (accepted: Bool, message: String) {
        askUserReplies.append((workItemId, conversationId, text, requestId))
        return nextAskUserResult
    }

    func cancelRemoteTask(
        workItemId: String?,
        requestId: String?
    ) async -> (accepted: Bool, message: String) {
        cancelledTasks.append((workItemId, requestId))
        return nextCancelResult
    }

    func openRemoteDeepLink(
        workItemId: String?,
        origin: WatchExecutionOrigin
    ) -> IOSAppDeepLink.Destination {
        if let workItemId, origin == .cloud {
            return .cloudTask(workItemId: workItemId)
        }
        return .macTasks
    }
}

@MainActor
final class WatchMultiDeviceUpgradeTests: XCTestCase {

    // MARK: - 1. Cloud / Mac Projection & Priority

    func testCoordinatorPrioritizesRemotePendingDecisionOverIdleAndTagsOrigin() async {
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000)
        bridge.configure(transport: WatchUpgradeTestTransport())
        let remote = FakeWatchRemoteGateway()
        let now = Date()
        remote.projection = WatchRemoteExecutionProjection(
            isPaired: true,
            isOnline: true,
            remoteOrigin: .mac,
            remoteHostName: "Studio Mac",
            selectedExecutionTarget: .mac,
            primaryTask: WatchRemoteTaskProjection(
                runId: "remote:mac:approval:c-l1",
                origin: .mac,
                hostName: "Studio Mac",
                workItemId: "wi-mac-1",
                sessionKey: "amber:r1",
                conversationId: nil,
                phase: "waitingForUser",
                headline: "整理桌面文档",
                detail: "等你确认 · workspace_read",
                summary: nil,
                updatedAt: now,
                isLive: true,
                needsAttention: true,
                canCancel: false,
                decision: WatchRemotePendingDecision(
                    id: "amber:r1::c-l1",
                    origin: .mac,
                    hostName: "Studio Mac",
                    kind: .approval(sessionKey: "amber:r1", toolCallId: "c-l1", tool: "workspace_read"),
                    title: "workspace_read",
                    body: "读取 notes/plan.md",
                    riskLevel: .low,
                    localApprovalOnly: false,
                    workItemId: "wi-mac-1",
                    conversationId: nil
                )
            ),
            recentActivities: [
                WatchRecentActivity(
                    id: "remote:mac:done:1",
                    runId: "remote:mac:done:1",
                    conversationId: nil,
                    kind: "workflow",
                    phase: "completed",
                    title: "每日新闻汇总",
                    summary: "已汇总 12 条新闻",
                    updatedAt: now.addingTimeInterval(-120),
                    origin: .mac
                )
            ]
        )

        let coordinator = makeCoordinator(bridge: bridge, remoteGateway: remote)
        coordinator.handleRemoteStateChanged()
        try? await Task.sleep(nanoseconds: 40_000_000)

        let snapshot = coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.runId, "remote:mac:approval:c-l1")
        XCTAssertEqual(snapshot.origin, .mac)
        XCTAssertEqual(snapshot.originName, "Studio Mac")
        XCTAssertEqual(snapshot.needsAttention, true)
        XCTAssertEqual(snapshot.decision?.riskLevel, .low)
        XCTAssertEqual(snapshot.decision?.doubleTapPrimaryOptionId, "approve")
        XCTAssertTrue(snapshot.actions.contains(.approve))
        XCTAssertTrue(snapshot.actions.contains(.deny))

        // Approving L1 routes cleanly to remote gateway.
        let approveResult = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: UUID().uuidString,
            runId: snapshot.runId,
            conversationId: nil,
            decisionId: snapshot.decision?.id,
            action: .approve,
            optionId: "approve",
            text: nil,
            createdAt: Date()
        ))
        XCTAssertTrue(approveResult.accepted)
        XCTAssertEqual(remote.resolvedApprovals.count, 1)
        XCTAssertEqual(remote.resolvedApprovals.first?.allow, true)
        XCTAssertEqual(remote.resolvedApprovals.first?.toolCallId, "c-l1")
    }

    // MARK: - 2. L3 Redline Enforcement (Watch UI + Builder + Coordinator)

    func testL3HighRiskDecisionHidesApproveDisablesDoubleTapAndRejectsForgedApprove() async {
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000)
        bridge.configure(transport: WatchUpgradeTestTransport())
        let remote = FakeWatchRemoteGateway()
        let l3Decision = WatchRemotePendingDecision(
            id: "amber:r2::c-l3",
            origin: .mac,
            hostName: "Studio Mac",
            kind: .approval(sessionKey: "amber:r2", toolCallId: "c-l3", tool: "shell_run"),
            title: "shell_run",
            body: "rm -rf ~/Downloads/tmp",
            riskLevel: .high,
            localApprovalOnly: true,
            workItemId: "wi-l3",
            conversationId: nil
        )
        remote.projection = WatchRemoteExecutionProjection(
            isPaired: true,
            isOnline: true,
            remoteOrigin: .mac,
            remoteHostName: "Studio Mac",
            selectedExecutionTarget: .mac,
            primaryTask: WatchRemoteTaskProjection(
                runId: "remote:mac:approval:c-l3",
                origin: .mac,
                hostName: "Studio Mac",
                workItemId: "wi-l3",
                sessionKey: "amber:r2",
                conversationId: nil,
                phase: "waitingForUser",
                headline: "清理下载文件夹",
                detail: "高危审批 · 需在主机核对",
                summary: nil,
                updatedAt: Date(),
                isLive: true,
                needsAttention: true,
                canCancel: false,
                decision: l3Decision
            )
        )

        let built = WatchTaskSnapshotBuilder.remoteDecision(from: l3Decision, languageCode: "zh-Hans")
        XCTAssertTrue(built.blocksWatchApproval)
        XCTAssertFalse(built.options.contains(where: { $0.style == .approve }))
        XCTAssertFalse(built.visibleOptionsForWatch.contains(where: { $0.style == .approve }))
        XCTAssertTrue(built.visibleOptionsForWatch.contains(where: { $0.style == .deny }))
        XCTAssertTrue(built.visibleOptionsForWatch.contains(where: { $0.style == .openOnPhone }))
        XCTAssertNil(built.doubleTapPrimaryOptionId, "L3 must completely disable Double Tap")

        // Even if a stale or tampered payload carries an `.approve` option on a high-risk decision,
        // `visibleOptionsForWatch` and `doubleTapPrimaryOptionId` fail closed.
        var tampered = built
        tampered.options.insert(WatchDecisionOption(id: "approve", title: "允许", style: .approve), at: 0)
        XCTAssertFalse(tampered.visibleOptionsForWatch.contains(where: { $0.style == .approve }))
        XCTAssertNil(tampered.doubleTapPrimaryOptionId)

        let coordinator = makeCoordinator(bridge: bridge, remoteGateway: remote)
        coordinator.handleRemoteStateChanged()
        try? await Task.sleep(nanoseconds: 40_000_000)

        let snapshot = coordinator.currentSnapshot()
        XCTAssertFalse(snapshot.actions.contains(.approve))
        XCTAssertTrue(snapshot.actions.contains(.deny))

        // Forged approve from Watch must be rejected before calling remote gateway.
        let forgedApprove = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: UUID().uuidString,
            runId: snapshot.runId,
            conversationId: nil,
            decisionId: snapshot.decision?.id,
            action: .approve,
            optionId: "approve",
            text: nil,
            createdAt: Date()
        ))
        XCTAssertFalse(forgedApprove.accepted)
        XCTAssertTrue(remote.resolvedApprovals.isEmpty, "L3 approve must never reach remote gateway")

        // Deny remains allowed on L3.
        remote.nextApprovalResult = (true, "已拒绝")
        let denyResult = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: UUID().uuidString,
            runId: snapshot.runId,
            conversationId: nil,
            decisionId: snapshot.decision?.id,
            action: .deny,
            optionId: "deny",
            text: nil,
            createdAt: Date()
        ))
        XCTAssertTrue(denyResult.accepted)
        XCTAssertEqual(remote.resolvedApprovals.first?.allow, false)
    }

    func testL2MediumRiskAllowsTapApproveButNotDoubleTap() {
        let l2 = WatchRemotePendingDecision(
            id: "amber:r3::c-l2",
            origin: .cloud,
            hostName: "Amber Cloud",
            kind: .approval(sessionKey: "amber:r3", toolCallId: "c-l2", tool: "workspace_file_write"),
            title: "workspace_file_write",
            body: "写入 notes/summary.md",
            riskLevel: .medium,
            localApprovalOnly: false,
            workItemId: "wi-l2",
            conversationId: nil
        )
        let decision = WatchTaskSnapshotBuilder.remoteDecision(from: l2, languageCode: "zh-Hans")
        XCTAssertFalse(decision.blocksWatchApproval)
        XCTAssertTrue(decision.visibleOptionsForWatch.contains(where: { $0.style == .approve }))
        XCTAssertNil(decision.doubleTapPrimaryOptionId, "Only L1/low risk enables Double Tap instant confirm")
    }

    // MARK: - 3. Direct-Send After Dictation Toggle & Persistence

    func testDirectSendTogglePersistsAndAutoSendsNonEmptyDictationOnlyWhenEnabled() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-direct-send-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }

        let store = WatchLocalStore(fileURL: fileURL)
        XCTAssertFalse(store.settings.directSendAfterDictation)
        store.updateSettings { $0.directSendAfterDictation = true }

        let reloaded = WatchLocalStore(fileURL: fileURL)
        XCTAssertTrue(reloaded.settings.directSendAfterDictation)

        let transport = WatchUpgradeTestTransport(isReachable: true)
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000)
        bridge.configure(transport: transport)
        var ready = WatchTaskSnapshot.idle
        ready.library = WatchLibrarySnapshot(
            assistantName: "Amber",
            isConfigured: true,
            quickActions: [],
            recent: [],
            updatedAt: Date(),
            preferredExecutionTarget: .cloud,
            remoteTargetOrigin: .cloud,
            remoteTargetName: "Amber Cloud",
            remoteTargetOnline: true
        )
        bridge.publish(ready)

        let model = WatchTaskViewModel(bridge: bridge, store: reloaded)
        model.start()
        bridge.onSnapshotUpdated?(bridge.latestSnapshot)

        // With direct-send ON, dictating non-empty text submits immediately.
        model.compose(mode: .ask)
        model.handleComposerTextChange(key: "ask", newText: "帮我查一下今晚天气")
        XCTAssertEqual(transport.sentActions.count, 1)
        XCTAssertEqual(transport.sentActions.first?.action, .ask)
        XCTAssertEqual(transport.sentActions.first?.text, "帮我查一下今晚天气")

        // Turning direct-send OFF restores draft review safety net.
        reloaded.updateSettings { $0.directSendAfterDictation = false }
        model.compose(mode: .ask, conversationId: "conv-review")
        model.handleComposerTextChange(key: "ask:conv-review", newText: "先检查再发")
        XCTAssertEqual(transport.sentActions.count, 1, "must not auto-send when toggle is off")
        XCTAssertEqual(reloaded.draft(forKey: "ask:conv-review")?.text, "先检查再发")
    }

    func testAskAmberIntentAutoSubmitsWhenQuestionProvidedAndFallsBackToDraftOffline() {
        let transport = WatchUpgradeTestTransport(isReachable: true)
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000)
        bridge.configure(transport: transport)
        var ready = WatchTaskSnapshot.idle
        ready.library = WatchLibrarySnapshot(
            assistantName: "Amber",
            isConfigured: true,
            quickActions: [],
            recent: [],
            updatedAt: Date()
        )
        bridge.publish(ready)

        let model = WatchTaskViewModel(bridge: bridge, store: makeLocalStore())
        model.start()
        bridge.onSnapshotUpdated?(bridge.latestSnapshot)

        model.startAsk(prefill: "总结今天待办", autoSubmit: true)
        XCTAssertEqual(transport.sentActions.count, 1)
        XCTAssertEqual(transport.sentActions.first?.text, "总结今天待办")

        // When offline, keeps draft safely without dropping user text.
        transport.isReachable = false
        bridge.onReachabilityChanged?(false)
        let offlineModel = WatchTaskViewModel(bridge: bridge, store: makeLocalStore())
        offlineModel.start()
        offlineModel.startAsk(prefill: "离线问题", autoSubmit: true)
        XCTAssertEqual(offlineModel.store.draft(forKey: "ask")?.text, "离线问题")
        XCTAssertEqual(offlineModel.path, [.compose("ask")])
    }

    // MARK: - 4. Watch Questions Follow Execution Target & Weak Network Safety

    func testWatchQuestionFollowsSelectedCloudTargetAndDoesNotSilentFallbackOnWeakNetwork() async {
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000)
        bridge.configure(transport: WatchUpgradeTestTransport())
        let remote = FakeWatchRemoteGateway()
        remote.projection = WatchRemoteExecutionProjection(
            isPaired: true,
            isOnline: true,
            remoteOrigin: .cloud,
            remoteHostName: "Amber Cloud",
            selectedExecutionTarget: .cloud
        )
        let coordinator = makeCoordinator(bridge: bridge, remoteGateway: remote)

        let request = WatchTaskActionRequest(
            requestId: UUID().uuidString,
            runId: "",
            conversationId: nil,
            decisionId: nil,
            action: .ask,
            optionId: nil,
            text: "帮我盯一下明天航班",
            createdAt: Date()
        )
        let result = await coordinator.handleWatchAction(request)
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.runId, "remote:cloud:wi-1")
        XCTAssertEqual(remote.submittedQuestions.count, 1)

        // Weak-network failure returns deliveryUnknown=true and preserves draft rather than silently dropping.
        remote.nextDispatchOutcome = WatchRemoteDispatchOutcome(
            accepted: false,
            message: "网络波动，正在确认云端是否已接收",
            runId: nil,
            conversationId: nil,
            deliveryUnknown: true
        )
        let weakRequest = WatchTaskActionRequest(
            requestId: UUID().uuidString,
            runId: "",
            conversationId: nil,
            decisionId: nil,
            action: .ask,
            optionId: nil,
            text: "弱网问题",
            createdAt: Date()
        )
        let weakResult = await coordinator.handleWatchAction(weakRequest)
        XCTAssertFalse(weakResult.accepted)
        XCTAssertEqual(weakResult.deliveryUnknown, true)
    }

    // MARK: - 5. Quick Notes Flow Into Main Intent Inbox & One-Tap Remote Handoff

    func testSavingWatchNoteEnqueuesIntentInboxCandidateWithoutAutoExecuting() async throws {
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000)
        bridge.configure(transport: WatchUpgradeTestTransport())
        let inboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-inbox-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: inboxURL) }
        let inbox = AmberIntentInboxStore(userDefaults: nil, fileURL: inboxURL)

        let service = makeCompanionService()
        let coordinator = makeCoordinator(bridge: bridge, companionService: service, intentInboxStore: inbox)

        let noteId = UUID().uuidString
        let result = await coordinator.handleWatchAction(WatchTaskActionRequest(
            requestId: noteId,
            runId: "",
            conversationId: nil,
            decisionId: nil,
            action: .saveNote,
            optionId: nil,
            text: "明天上午整理季度复盘 PPT\n补充数据图表",
            createdAt: Date()
        ))

        XCTAssertTrue(result.accepted)
        XCTAssertEqual(service.notes.count, 1)
        XCTAssertEqual(inbox.pendingCandidates.count, 1)
        let candidate = try XCTUnwrap(inbox.pendingCandidates.first)
        XCTAssertEqual(candidate.id, "watch-note:\(noteId)")
        XCTAssertEqual(candidate.suggestedKind, .actionTodo)
        XCTAssertTrue(candidate.sourceQuote.contains("季度复盘 PPT"))
        XCTAssertEqual(candidate.status, .pending)
    }

    func testWatchNoteOneTapHandOffTargetsRemoteOriginAndSubmits() {
        let transport = WatchUpgradeTestTransport(isReachable: true)
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000)
        bridge.configure(transport: transport)
        var ready = WatchTaskSnapshot.idle
        ready.library = WatchLibrarySnapshot(
            assistantName: "Amber",
            isConfigured: false,
            configurationMessage: "未配置本地模型",
            quickActions: [],
            recent: [],
            updatedAt: Date(),
            preferredExecutionTarget: .local,
            remoteTargetOrigin: .cloud,
            remoteTargetName: "Amber Cloud",
            remoteTargetOnline: true
        )
        bridge.publish(ready)

        let model = WatchTaskViewModel(bridge: bridge, store: makeLocalStore())
        model.start()
        bridge.onSnapshotUpdated?(bridge.latestSnapshot)
        let note = WatchNote(id: "note-cloud-1", text: "整理本周工作记录", createdAt: Date())
        XCTAssertTrue(model.store.saveNote(note))

        model.composeFromNote(
            note,
            instruction: "请整理并处理这条随手记：",
            targetOrigin: .cloud,
            autoSubmit: true
        )
        XCTAssertEqual(transport.sentActions.count, 1)
        XCTAssertEqual(transport.sentActions.first?.targetOrigin, .cloud)
        XCTAssertTrue(transport.sentActions.first?.text?.contains("整理本周工作记录") == true)
    }

    // MARK: - 6. Smart Stack Relevance & Privacy-Safe Cache

    func testSmartStackRelevancePromotesCloudAndMacAttentionAndDemotesIdle() throws {
        let now = Date()

        // Remote Cloud running task stays relevant beyond 60s (up to 5m remote freshness window).
        var cloudRunning = WatchTaskSnapshot.idle
        cloudRunning.runId = "remote:cloud:wi-99"
        cloudRunning.phase = "running"
        cloudRunning.origin = .cloud
        cloudRunning.originName = "Secret Host Name"
        cloudRunning.headline = "Private Task Title"
        cloudRunning.updatedAt = now.addingTimeInterval(-120)
        let cloudRunningScore = WatchWidgetRelevance.score(for: cloudRunning, now: now).score
        XCTAssertEqual(cloudRunningScore, 70)

        // Remote needsAttention promotes to top score 100.
        var cloudAttention = cloudRunning
        cloudAttention.needsAttention = true
        XCTAssertEqual(WatchWidgetRelevance.score(for: cloudAttention, now: now).score, 100)

        // Remote stale/expired demotes quietly to 0.
        XCTAssertEqual(
            WatchWidgetRelevance.score(for: cloudRunning, now: now.addingTimeInterval(6 * 60)).score,
            0
        )

        // Privacy cache keeps origin + needsAttention while stripping host name and private content.
        let suite = "watch-smart-stack-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(WatchWidgetCache.save(cloudAttention, defaults: defaults))
        let cached = try XCTUnwrap(WatchWidgetCache.load(defaults: defaults))
        XCTAssertEqual(cached.origin, .cloud)
        XCTAssertEqual(cached.needsAttention, true)
        XCTAssertNil(cached.originName)
        XCTAssertEqual(cached.headline, "Amber")
        XCTAssertNil(cached.summary)
        XCTAssertNil(cached.decision)
    }

    // MARK: - 7. Dual-Slot MacGatewayWatchExecutionAdapter Integration

    nonisolated private static func jsonResp(_ url: URL, status: Int = 200, _ json: String) -> (Data, URLResponse) {
        let resp = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(json.utf8), resp)
    }

    func testDualSlotWatchAdapterProjectsMacApprovalRoutesByPreferredOriginAndEnforcesL3Redline() async throws {
        let suite = "WatchDualSlotAdapter.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let store = MacGatewayStore(defaults: defaults, isApplicationForeground: { true })
        let cloudClient = MacGatewayClient(
            addrs: ["cloud.watch.test"],
            port: 443,
            fingerprint: "fp-c",
            token: "tok-c",
            transport: { req, _ in
                let url = req.url!
                switch url.path {
                case "/v1/status":
                    return Self.jsonResp(url, #"{"gateway":{"id":"gw-c","name":"Amber Cloud"},"device":{"id":"d-c","name":"iPhone","pushRegistered":true},"serverTime":1800000000,"sessions":[]}"#)
                case "/v1/amber/board":
                    return Self.jsonResp(url, #"{"board":[]}"#)
                case "/v1/amber/schedules":
                    return Self.jsonResp(url, #"{"schedules":[]}"#)
                case "/v2/dialogue/messages":
                    return Self.jsonResp(url, status: 202, #"{"requestId":"req-w-cloud","eventId":"ev-wc","topicId":"t-wc","workItemIds":["wi-w-cloud"],"state":"received","replayed":false}"#)
                default:
                    return Self.jsonResp(url, #"{"items":[],"nextCursor":0}"#)
                }
            }
        )
        let macClient = MacGatewayClient(
            addrs: ["mac.watch.test"],
            port: 47821,
            fingerprint: "fp-m",
            token: "tok-m",
            transport: { req, _ in
                let url = req.url!
                switch url.path {
                case "/v1/status":
                    return Self.jsonResp(url, #"{"gateway":{"id":"gw-m","name":"Studio Mac"},"device":{"id":"d-m","name":"iPhone","pushRegistered":true},"serverTime":1800000000,"sessions":[]}"#)
                case "/v1/amber/board":
                    return Self.jsonResp(url, #"""
                    {
                      "board":[
                        {
                          "id":"run:mac-l3",
                          "kind":"run",
                          "column":"needsYou",
                          "title":"高危构建清理",
                          "detail":"等你确认 · shell_run",
                          "updatedAt":1800000000,
                          "waitingForReply":false,
                          "failed":false,
                          "approval":{
                            "sessionKey":"amber:mac-watch-l3",
                            "toolCallId":"call-watch-l3",
                            "tool":"shell_run",
                            "detail":"rm -rf DerivedData",
                            "highRisk":true,
                            "requiresLocalApproval":true,
                            "riskLevel":"L3"
                          }
                        },
                        {
                          "id":"run:mac-done",
                          "kind":"run",
                          "column":"done",
                          "title":"同步仓库完成",
                          "detail":"所有测试通过",
                          "updatedAt":1799999900,
                          "waitingForReply":false,
                          "failed":false
                        }
                      ]
                    }
                    """#)
                case "/v1/amber/schedules":
                    return Self.jsonResp(url, #"{"schedules":[]}"#)
                case "/v2/dialogue/messages":
                    return Self.jsonResp(url, status: 202, #"{"requestId":"req-w-mac","eventId":"ev-wm","topicId":"t-wm","workItemIds":["wi-w-mac"],"state":"received","replayed":false}"#)
                default:
                    return Self.jsonResp(url, #"{"items":[],"nextCursor":0}"#)
                }
            }
        )

        store.configureForTesting(
            role: .cloud,
            connection: MacGatewayConnection(gatewayId: "gw-c", name: "Amber Cloud", addrs: ["cloud.watch.test"], port: 443, fingerprint: "fp-c", deviceId: "d-c"),
            client: cloudClient
        )
        store.configureForTesting(
            role: .mac,
            connection: MacGatewayConnection(gatewayId: "gw-m", name: "Studio Mac", addrs: ["mac.watch.test"], port: 47821, fingerprint: "fp-m", deviceId: "d-m"),
            client: macClient
        )
        await store.refreshAll()
        defer {
            store.stopCloudDialoguePolling()
            store.mac.stopCloudDialoguePolling()
        }

        let adapter = MacGatewayWatchExecutionAdapter(store: store)
        let projection = adapter.currentProjection()
        XCTAssertTrue(projection.isPaired)
        XCTAssertTrue(projection.isOnline)
        XCTAssertEqual(projection.remoteOrigin, .mac)
        XCTAssertEqual(projection.remoteHostName, "Studio Mac")
        XCTAssertEqual(projection.primaryTask?.origin, .mac)
        XCTAssertEqual(projection.primaryTask?.decision?.localApprovalOnly, true)
        XCTAssertTrue(projection.recentActivities.contains(where: { $0.origin == .mac && $0.title == "同步仓库完成" }))

        // L3 approval on Mac slot must fail closed from Watch.
        let blocked = await adapter.resolveApproval(
            sessionKey: "amber:mac-watch-l3",
            toolCallId: "call-watch-l3",
            allow: true
        )
        XCTAssertFalse(blocked.accepted)

        // Preferred origin routes cleanly to each independent slot.
        let macDispatch = await adapter.submitQuestion(
            text: "在 Mac 跑构建",
            requestId: "req-w-mac",
            preferredOrigin: .mac
        )
        let cloudDispatch = await adapter.submitQuestion(
            text: "在云端查日程",
            requestId: "req-w-cloud",
            preferredOrigin: .cloud
        )
        store.stopCloudDialoguePolling()
        store.mac.stopCloudDialoguePolling()

        XCTAssertTrue(macDispatch.accepted)
        XCTAssertEqual(macDispatch.runId, "remote:mac:wi-w-mac")
        XCTAssertTrue(cloudDispatch.accepted)
        XCTAssertEqual(cloudDispatch.runId, "remote:cloud:wi-w-cloud")
    }

    // MARK: - Helpers

    private func makeCompanionService() -> IOSWatchCompanionService {
        let suite = "WatchMultiDeviceUpgradeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return IOSWatchCompanionService(baseDirectory: root, defaults: defaults)
    }

    private func makeLocalStore() -> WatchLocalStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-upgrade-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return WatchLocalStore(fileURL: url)
    }

    private func makeCoordinator(
        bridge: WatchConnectivityBridge,
        companionService: IOSWatchCompanionService? = nil,
        remoteGateway: WatchRemoteExecutionRouting? = nil,
        intentInboxStore: AmberIntentInboxStore? = nil
    ) -> WatchTaskCoordinator {
        WatchTaskCoordinator(
            bridge: bridge,
            companionService: companionService ?? makeCompanionService(),
            remoteGateway: remoteGateway,
            intentInboxStore: intentInboxStore
        )
    }
}
