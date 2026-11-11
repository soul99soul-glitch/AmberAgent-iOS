import XCTest
@preconcurrency import Shared
@testable import iosApp

/// Agent 形象人设（Soul）存储与工具的最小契约测试。
///
/// 只覆盖会影响用户可见行为的三件事：称呼/签名/正文能存住、旧版进快照可回退、
/// 注入片段只在有内容时出现且带称呼。不做渲染或网络验证。
@MainActor
final class AgentSoulStoreTests: XCTestCase {

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "AgentSoulStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    func testUpdatePersistsAndInjectsDisplayName() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var posted: [String] = []
        let store = AgentSoulStore(userDefaults: defaults, notePoster: { posted.append($0) })

        XCTAssertEqual(store.displayName, AgentSoulStore.defaultDisplayName)
        XCTAssertTrue(store.isDefault)

        let changed = store.update(
            displayName: "赵大哥",
            tagline: "《燕云十六声》里亲切和蔼的老哥",
            soulPrompt: "说话慢半拍，爱用北方口语，逗逼但靠得住。",
            summary: "对话自塑"
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(store.displayName, "赵大哥")
        XCTAssertFalse(store.isDefault)

        // 正文必须写进既有的 soul 注入通道，否则 system prompt 拿不到。
        XCTAssertEqual(posted.last, "说话慢半拍，爱用北方口语，逗逼但靠得住。")
        let section = store.systemPromptSection
        XCTAssertTrue(section.contains("赵大哥"))
        XCTAssertTrue(section.contains("北方口语"))

        // 重新读盘仍是新值。
        let reloaded = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        XCTAssertEqual(reloaded.displayName, "赵大哥")
        XCTAssertEqual(reloaded.tagline, "《燕云十六声》里亲切和蔼的老哥")
    }

    func testUpdateSnapshotsPreviousVersionAndCanRollBack() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        store.update(displayName: "赵大哥", tagline: nil, soulPrompt: "第一版人设", summary: "v1")
        store.update(displayName: "赵大哥", tagline: nil, soulPrompt: "第二版人设", summary: "v2")

        XCTAssertEqual(store.soulPrompt, "第二版人设")
        // 首次设置前是空白默认态，不值得占一档；所以两次写入只留下 v1 这一条。
        XCTAssertEqual(store.snapshots.count, 1)
        let firstSnapshot = try XCTUnwrap(store.snapshots.first)
        XCTAssertEqual(firstSnapshot.soulPrompt, "第一版人设")

        XCTAssertTrue(store.restore(snapshotID: firstSnapshot.id))
        XCTAssertEqual(store.soulPrompt, "第一版人设")
        // 回退本身也会压栈，保证还能再撤回。
        XCTAssertEqual(store.snapshots.count, 2)
    }

    func testSnapshotStackIsCappedAtEight() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        store.update(displayName: "Amber", tagline: nil, soulPrompt: "seed", summary: "seed")
        for index in 0..<12 {
            store.update(displayName: "Amber", tagline: nil, soulPrompt: "版本 \(index)", summary: "v\(index)")
        }
        XCTAssertEqual(store.snapshots.count, AgentSoulStore.maximumSnapshots)
    }

    func testResetToDefaultClearsAndKeepsRollback() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        store.update(displayName: "赵大哥", tagline: "老哥", soulPrompt: "人设", summary: "v1")
        XCTAssertTrue(store.resetToDefault())
        XCTAssertTrue(store.isDefault)
        XCTAssertEqual(store.displayName, AgentSoulStore.defaultDisplayName)
        XCTAssertEqual(store.soulPrompt, "")
        XCTAssertFalse(store.snapshots.isEmpty, "恢复默认前必须留下可回退快照")
    }

    func testDefaultStoreInjectsNothing() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        // 默认状态下不往 system prompt 塞任何东西，避免污染普通对话。
        XCTAssertEqual(store.systemPromptSection, "")
    }

    // MARK: - 工具

    func testSoulToolGetReturnsCurrentSoul() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        store.update(displayName: "赵大哥", tagline: "老哥", soulPrompt: "人设正文", summary: "v1")

        let service = AgentSoulToolService(store: store)
        let json = service.execute(toolName: AgentSoulToolCatalog.getToolName, arguments: "{}")
        XCTAssertTrue(json.contains("\"status\":\"ok\""))
        XCTAssertTrue(json.contains("赵大哥"))
        XCTAssertTrue(json.contains("人设正文"))
    }

    func testSoulToolUpdateAppliesAndReportsChange() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        let service = AgentSoulToolService(store: store)

        let arguments = #"{"displayName":"赵大哥","tagline":"老哥","soulPrompt":"新写的人设","summary":"对话自塑"}"#
        let json = service.execute(toolName: AgentSoulToolCatalog.updateToolName, arguments: arguments)

        XCTAssertTrue(json.contains("\"changed\":true"))
        XCTAssertEqual(store.displayName, "赵大哥")
        XCTAssertEqual(store.soulPrompt, "新写的人设")
        XCTAssertEqual(store.source, .conversation)
    }

    func testSoulToolUpdateRejectsEmptyPayload() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        let service = AgentSoulToolService(store: store)
        let json = service.execute(
            toolName: AgentSoulToolCatalog.updateToolName,
            arguments: #"{"displayName":"","tagline":"","soulPrompt":""}"#
        )
        XCTAssertTrue(json.contains("empty_update"))
        XCTAssertTrue(store.isDefault, "空更新不得改动既有设定")
    }

    func testSoulUpdateToolNeedsNoApproval() {
        // 产品决定：对话内自塑人设免审批。若将来改回审批，这里会先失败。
        XCTAssertTrue(AgentSoulToolCatalog.toolNames.contains("agent_soul_get"))
        XCTAssertTrue(AgentSoulToolCatalog.toolNames.contains("agent_soul_update"))
        XCTAssertFalse(
            AgentSoulToolCatalog.toolNames.contains(where: { $0.contains("soul_import") }),
            "旧的 soul_import 仍是独立的高风险导入工具，不应被混入"
        )
    }

    func testRuntimeContextBuilderInjectsSoulEmbodimentAndPreservesLegacyMarkdown() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var credentials: [String: String] = [:]
        let settings = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { credentials[$0] },
            storeCredential: { credentials[$0] = $1; return true },
            deleteCredential: { credentials.removeValue(forKey: $0); return true }
        )
        let soulStore = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        let baseMessages = [UIMessage.companion.user(prompt: "你好")]

        settings.setAgentSoulMarkdown("")
        let emptyPrepared = ChatRuntimeContextBuilder(
            sharedSettings: settings,
            mcpTools: [],
            miniAppRepository: .shared,
            miniAppRuntimeEnabled: false,
            soulStore: soulStore
        ).injectingRuntimeContext(into: baseMessages, coalesceSystemMessages: false)
        XCTAssertFalse(emptyPrepared.contains { $0.toText().contains("<agents_md>") })

        settings.setAgentSoulMarkdown("# Legacy Soul Rule\nYou are Amber, a personal agent on the user's device.")
        let legacyPrepared = ChatRuntimeContextBuilder(
            sharedSettings: settings,
            mcpTools: [],
            miniAppRepository: .shared,
            miniAppRuntimeEnabled: false,
            soulStore: soulStore
        ).injectingRuntimeContext(into: baseMessages, coalesceSystemMessages: false)
        XCTAssertTrue(legacyPrepared.contains { $0.toText().contains("# Legacy Soul Rule") })

        soulStore.update(
            displayName: "赵大哥",
            tagline: "燕云十六声热心老哥",
            soulPrompt: "说话豪爽接地气，自称老哥。",
            summary: "测试自塑"
        )
        let embodiedPrepared = ChatRuntimeContextBuilder(
            sharedSettings: settings,
            mcpTools: [],
            miniAppRepository: .shared,
            miniAppRuntimeEnabled: false,
            soulStore: soulStore
        ).injectingRuntimeContext(into: baseMessages, coalesceSystemMessages: false)
        let soulSystemText = embodiedPrepared
            .filter { $0.role == MessageRole.system }
            .map { $0.toText() }
            .joined(separator: "\n")
        XCTAssertTrue(soulSystemText.contains("赵大哥"))
        XCTAssertTrue(soulSystemText.contains("燕云十六声热心老哥"))
        XCTAssertTrue(soulSystemText.contains("说话豪爽接地气，自称老哥。"))
        XCTAssertTrue(soulSystemText.contains("# Legacy Soul Rule"))
        XCTAssertTrue(soulSystemText.contains("You are 赵大哥, a personal agent on the user's device."))
        XCTAssertFalse(soulSystemText.contains("You are Amber, a personal agent on the user's device."))
    }

    func testExplicitSoulUpdateRequestRejectsKeywordOverlapNegationAndIsolatedHubTurns() throws {
        // 1. 子串自触发（"角色设定"/"性格设定" 自含 "设定"）、否定句与小说第三方人设不得被判定为改 Agent 人设
        XCTAssertFalse(AgentSoulCloudBridge.isExplicitSoulUpdateRequest("帮我分析一下这部小说的角色设定"))
        XCTAssertFalse(AgentSoulCloudBridge.isExplicitSoulUpdateRequest("这个人物的性格设定很有张力"))
        XCTAssertFalse(AgentSoulCloudBridge.isExplicitSoulUpdateRequest("不要改你的人设"))
        XCTAssertFalse(AgentSoulCloudBridge.isExplicitSoulUpdateRequest("别换人设，保持现在这样"))
        XCTAssertFalse(AgentSoulCloudBridge.isExplicitSoulUpdateRequest("帮我给男主写个腹黑反派人设"))

        // 真实改 Agent 自身人设的表达仍须命中
        XCTAssertTrue(AgentSoulCloudBridge.isExplicitSoulUpdateRequest("把你的人设改成逗逼靠谱的赵大哥"))
        XCTAssertTrue(AgentSoulCloudBridge.isExplicitSoulUpdateRequest("给自己弄个毒舌管家人设，写进你的 soul"))
        XCTAssertTrue(AgentSoulCloudBridge.isExplicitSoulUpdateRequest("认，就这么来，性格归性格，底线归底线"))

        // 2. `.hubIsolated` 独立记忆中心与子代理回合不得污染全局 AgentSoulStore.shared
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let sharedSoul = AgentSoulStore.shared
        let savedName = sharedSoul.displayName
        let savedTagline = sharedSoul.tagline
        let savedPrompt = sharedSoul.soulPrompt
        let savedHubs = AmberHubStore.shared.hubs
        let savedActiveHubId = AmberHubStore.shared.activeHubId
        let savedMutationHandler = sharedSoul.localMutationHandler
        defer {
            sharedSoul.localMutationHandler = nil
            _ = sharedSoul.resetToDefault()
            if savedName != AgentSoulStore.defaultDisplayName || !savedTagline.isEmpty || !savedPrompt.isEmpty {
                _ = sharedSoul.update(displayName: savedName, tagline: savedTagline, soulPrompt: savedPrompt, summary: "restore")
            }
            sharedSoul.localMutationHandler = savedMutationHandler
            AmberHubStore.shared.replaceForPreview(hubs: savedHubs, activeHubId: savedActiveHubId, collections: AmberHubStore.shared.smartCollections)
        }
        sharedSoul.localMutationHandler = nil
        _ = sharedSoul.resetToDefault()

        let isolatedConvUuid = KotlinUuid.companion.random()
        let isolatedHub = AmberHubItem(
            id: "hub-isolated-novel-test",
            title: "长篇小说",
            thesis: "独立世界观",
            template: .novel,
            memoryPolicy: .hubIsolated,
            conversationIds: [isolatedConvUuid.toHexDashString()]
        )
        AmberHubStore.shared.replaceForPreview(hubs: [isolatedHub], activeHubId: isolatedHub.id, collections: [])

        let legacySettings = SettingsStore(userDefaults: defaults)
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let viewModel = ChatViewModel(settingsStore: legacySettings, sharedSettings: sharedSettings)

        let isolatedState = ChatConversationRunState(conversationId: isolatedConvUuid)
        isolatedState.messages = [
            UIMessage.companion.user(prompt: "把你的人设改成逗逼靠谱的赵大哥"),
            UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [UIMessagePart.Text(text: "好嘞，从下一句起就按赵大哥的性子来！", metadata: nil)],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: chatNowLocalDateTime(),
                modelId: nil,
                usage: nil,
                translation: nil
            )
        ]
        viewModel.onGenerationCompleted(state: isolatedState)
        XCTAssertTrue(sharedSoul.isDefault, "独立记忆中心（.hubIsolated）会话不得写入全局 AgentSoulStore.shared")

        let childState = ChatConversationRunState(conversationId: KotlinUuid.companion.random())
        childState.isOrchestratedChild = true
        childState.messages = isolatedState.messages
        viewModel.onGenerationCompleted(state: childState)
        XCTAssertTrue(sharedSoul.isDefault, "子代理会话（isOrchestratedChild）不得写入全局 AgentSoulStore.shared")
    }

    func testCloudDialoguePollWithServerSoulRevisionDoesNotReverseOverwriteAuthoritativeSoul() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let sharedSoul = AgentSoulStore.shared
        let savedName = sharedSoul.displayName
        let savedTagline = sharedSoul.tagline
        let savedPrompt = sharedSoul.soulPrompt
        let savedMutationHandler = sharedSoul.localMutationHandler
        defer {
            sharedSoul.localMutationHandler = nil
            _ = sharedSoul.resetToDefault()
            if savedName != AgentSoulStore.defaultDisplayName || !savedTagline.isEmpty || !savedPrompt.isEmpty {
                _ = sharedSoul.update(displayName: savedName, tagline: savedTagline, soulPrompt: savedPrompt, summary: "restore")
            }
            sharedSoul.localMutationHandler = savedMutationHandler
        }
        sharedSoul.localMutationHandler = nil
        _ = sharedSoul.resetToDefault()

        actor CloudSoulRecorder {
            var putBodies: [String] = []
            func recordPut(_ body: String) { putBodies.append(body) }
        }
        let recorder = CloudSoulRecorder()

        let client = MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            token: "tok",
            transport: { req, _ in
                let url = req.url!
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                switch (req.httpMethod ?? "GET", url.path) {
                case ("GET", "/v2/dialogue/events"):
                    let pageJSON = #"""
                    {
                      "items": [
                        {"seq": 1, "id": "ev-u1", "kind": "user_message", "role": "user", "text": "把你的人设改成诸葛亮，自称孔明", "topicId": "topic-1"},
                        {"seq": 2, "id": "ev-a1", "kind": "assistant_reply", "role": "assistant", "text": "亮谨遵钧命，已为你切换为卧龙先生人设。", "topicId": "topic-1"}
                      ],
                      "nextCursor": 2,
                      "soulRevision": 5
                    }
                    """#
                    return (Data(pageJSON.utf8), resp)
                case ("GET", "/v2/soul"):
                    let soulJSON = #"""
                    {
                      "revision": 5,
                      "displayName": "孔明",
                      "tagline": "鞠躬尽瘁的蜀汉丞相",
                      "soulMarkdown": "服务端工具精修完整诸葛亮设定，不可被客户端正则模板覆盖。",
                      "isDefault": false,
                      "updatedAtMs": 1793500010000,
                      "source": "chat_self_update",
                      "history": []
                    }
                    """#
                    return (Data(soulJSON.utf8), resp)
                case ("PUT", "/v2/soul"):
                    let body = req.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    await recorder.recordPut(body)
                    let overriddenJSON = #"""
                    {
                      "revision": 6,
                      "displayName": "被客户端覆盖",
                      "tagline": "bad",
                      "soulMarkdown": "bad",
                      "isDefault": false,
                      "updatedAtMs": 1793500011000,
                      "source": "chat_self_update",
                      "history": []
                    }
                    """#
                    return (Data(overriddenJSON.utf8), resp)
                default:
                    let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
                    return (Data(#"{"error":"not_found"}"#.utf8), notFound)
                }
            }
        )
        let store = MacGatewayStore(defaults: defaults)
        store.configureForTesting(
            connection: .init(gatewayId: "gw-soul-1", name: "Cloud", addrs: ["cloud.example"], port: 443, fingerprint: "fp", deviceId: "dev-1"),
            client: client
        )
        store.bindCloudSoulStoreIfNeeded(sharedSoul)

        let pollResult = await store.pollCloudDialogueEvents()
        if case .failure(let error) = pollResult {
            XCTFail("Expected pollCloudDialogueEvents to succeed, got \(error)")
        }
        try await Task.sleep(for: .milliseconds(80))

        let puts = await recorder.putBodies
        XCTAssertTrue(puts.isEmpty, "服务端已返回新 soulRevision 时，客户端绝不能反向 PUT /v2/soul 覆盖权威人设，实际 PUT=\(puts)")
        XCTAssertEqual(sharedSoul.displayName, "孔明")
        XCTAssertEqual(sharedSoul.soulPrompt, "服务端工具精修完整诸葛亮设定，不可被客户端正则模板覆盖。")
    }

    func testGatewayUnpairResetsSoulRevisionAndPreventsCrossGatewayPersonaLeak() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let soulStore = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        let gatewayStore = MacGatewayStore(defaults: defaults)

        // 1. 配对网关 A（revision = 10），拉取权威人设
        let clientA = MacGatewayClient(
            addrs: ["gwa.example"],
            port: 443,
            fingerprint: "fp-a",
            token: "tok-a",
            transport: { req, _ in
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                let json = #"""
                {
                  "revision": 10,
                  "displayName": "网关A老哥",
                  "tagline": "网关A签名",
                  "soulMarkdown": "网关A专属设定正文",
                  "isDefault": false,
                  "updatedAtMs": 1793500020000,
                  "source": "mac_ui",
                  "history": []
                }
                """#
                return (Data(json.utf8), resp)
            }
        )
        gatewayStore.configureForTesting(
            connection: .init(gatewayId: "gw-a", name: "Mac A", addrs: ["gwa.example"], port: 443, fingerprint: "fp-a", deviceId: "dev-a"),
            client: clientA
        )
        let pulledA = await gatewayStore.syncCloudSoulIfNeeded(forcePull: true, soulStore: soulStore)
        XCTAssertTrue(pulledA)
        XCTAssertEqual(soulStore.displayName, "网关A老哥")
        XCTAssertEqual(soulStore.lastSyncedRevision, 10)

        // 2. 解绑网关 A 后重配对网关 B（revision = 2 < 10），observedRevision = 2 仍须成功拉取并对齐 revision = 2
        await gatewayStore.unpair()
        let clientB = MacGatewayClient(
            addrs: ["gwb.example"],
            port: 443,
            fingerprint: "fp-b",
            token: "tok-b",
            transport: { req, _ in
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                let json = #"""
                {
                  "revision": 2,
                  "displayName": "网关B管家",
                  "tagline": "网关B签名",
                  "soulMarkdown": "网关B专属设定正文",
                  "isDefault": false,
                  "updatedAtMs": 1793500030000,
                  "source": "mac_ui",
                  "history": []
                }
                """#
                return (Data(json.utf8), resp)
            }
        )
        gatewayStore.configureForTesting(
            connection: .init(gatewayId: "gw-b", name: "Mac B", addrs: ["gwb.example"], port: 443, fingerprint: "fp-b", deviceId: "dev-b"),
            client: clientB
        )
        let pulledB = await gatewayStore.syncCloudSoulIfNeeded(observedRevision: 2, soulStore: soulStore)
        XCTAssertTrue(pulledB, "切换到低 revision 网关 B 后，observedRevision=2 必须能正常拉取同步")
        XCTAssertEqual(soulStore.displayName, "网关B管家")
        XCTAssertEqual(soulStore.lastSyncedRevision, 2)

        // 3. 解绑网关 B 后重配对全新未初始化网关 C（revision = 0），绝不能把网关 B 的旧人设静默 PUT 外泄到网关 C
        await gatewayStore.unpair()
        actor PutCounter {
            var count = 0
            func inc() { count += 1 }
        }
        let putCounterC = PutCounter()
        let clientC = MacGatewayClient(
            addrs: ["gwc.example"],
            port: 443,
            fingerprint: "fp-c",
            token: "tok-c",
            transport: { req, _ in
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                if req.httpMethod == "PUT" && req.url?.path == "/v2/soul" {
                    await putCounterC.inc()
                }
                let json = #"""
                {
                  "revision": 0,
                  "displayName": "Amber",
                  "tagline": "",
                  "soulMarkdown": "",
                  "isDefault": true,
                  "updatedAtMs": 0,
                  "source": "default",
                  "history": []
                }
                """#
                return (Data(json.utf8), resp)
            }
        )
        gatewayStore.configureForTesting(
            connection: .init(gatewayId: "gw-c", name: "Cloud C", addrs: ["gwc.example"], port: 443, fingerprint: "fp-c", deviceId: "dev-c"),
            client: clientC
        )
        _ = await gatewayStore.syncCloudSoulIfNeeded(forcePull: true, soulStore: soulStore)
        let leakedPuts = await putCounterC.count
        XCTAssertEqual(leakedPuts, 0, "前序网关同步得到的人设不得在重配对全新网关（revision=0）时静默自动上传外泄")
    }
}
