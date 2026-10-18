import XCTest
import SQLite3
@preconcurrency import Shared
@testable import iosApp


/// Child conversation controls, dynamic scope, and ViewModel projection.
@MainActor
final class IOSOrchestrationScopeViewModelTests: IOSOrchestrationToolTestCase {
    // MARK: - P1-e 控制面纪律（子线程会话只读）

    /// 子线程会话：composer 被 `.orchestratedThread` 拦截（含文案）；编辑/重生成/
    /// 删除/变体选择全部 no-op；普通会话不受影响。edge 缓存随会话切换刷新。
    func testChildConversationIsReadOnlyInViewModel() async throws {
        let base = makeTempDirectory("ChildReadOnly")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler,
            currentConversationId: { store.currentConversation?.id }
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            autoGenerateResponses: false,
            orchestrationToolService: service
        )
        viewModel.conversationStore = store

        // 普通（根）会话不受影响：composer 放行、徽标查询 false。
        viewModel.reloadFromStore()
        await viewModel.orchestratedStatusRefreshTask?.value
        XCTAssertNil(viewModel.composerSendBlockReason(for: "你好"))
        let rootIsChild = await viewModel.isOrchestratedChild(conversationId: parentId)
        XCTAssertFalse(rootIsChild)

        // spawn 一个子线程（写 thread_edge）。
        let spawnResult = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "child"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r1",
            conversationId: parentId
        ))
        XCTAssertEqual(spawnResult["ok"] as? Bool, true)
        let childHex = try XCTUnwrap(spawnResult["child_thread_id"] as? String)
        let childId = KotlinUuid.companion.parse(uuidString: childHex)

        // 切到子会话 → reloadFromStore 触发 edge 缓存刷新 → 立即生效。
        await store.selectConversation(id: childId)
        viewModel.reloadFromStore()
        await viewModel.orchestratedStatusRefreshTask?.value
        XCTAssertEqual(viewModel.composerSendBlockReason(for: "你好"), .orchestratedThread)
        XCTAssertEqual(
            viewModel.composerSendBlockReason(for: "你好")?.userVisibleMessage,
            IOSAppLocalization.string("此会话由父线程编排，暂不支持直接输入", defaultValue: "此会话由父线程编排，暂不支持直接输入")
        )
        let childIsOrchestrated = await viewModel.isOrchestratedChild(conversationId: childId)
        XCTAssertTrue(childIsOrchestrated)

        // 编辑/重生成/删除/变体守卫：全部 no-op，消息不变。
        let messageCountBefore = viewModel.messages.count
        viewModel.editMessage(atMessageIndex: 0, newText: "篡改")
        viewModel.regenerate(atMessageIndex: 0)
        viewModel.deleteMessage(atMessageIndex: 0)
        viewModel.selectVariant(messageIndex: 0, variantIndex: 0)
        XCTAssertEqual(viewModel.messages.count, messageCountBefore)

        // 切回根会话：缓存刷新后恢复可输入。
        await store.selectConversation(id: parentId)
        viewModel.reloadFromStore()
        await viewModel.orchestratedStatusRefreshTask?.value
        XCTAssertNil(viewModel.composerSendBlockReason(for: "你好"))
    }
    /// 管线闭环：mailbox 语义说明只注入参与线程树的会话（父或子），普通会话不注入。
    func testOrchestrationContextPromptInjectedOnlyForLinkedConversations() async throws {
        let base = makeTempDirectory("OrchestrationPrompt")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler,
            currentConversationId: { store.currentConversation?.id }
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            autoGenerateResponses: false,
            orchestrationToolService: service
        )
        viewModel.conversationStore = store

        func injectedSystemText(_ viewModel: ChatViewModel) -> String {
            viewModel.preparedUploadMessagesForTesting([UIMessage.companion.user(prompt: "hi")])
                .filter { $0.role == MessageRole.system }
                .map { $0.toText() }
                .joined(separator: "\n")
        }

        // 普通会话：不注入编排语境。
        viewModel.reloadFromStore()
        await viewModel.orchestratedStatusRefreshTask?.value
        XCTAssertFalse(injectedSystemText(viewModel).contains("[mailbox"))

        // spawn 后父会话（有子边）：注入。
        let spawnResult = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "child"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r1",
            conversationId: parentId
        ))
        XCTAssertEqual(spawnResult["ok"] as? Bool, true)
        viewModel.reloadFromStore()
        await viewModel.orchestratedStatusRefreshTask?.value
        let parentText = injectedSystemText(viewModel)
        XCTAssertTrue(parentText.contains("[mailbox"))
        XCTAssertTrue(parentText.contains("FINAL_ANSWER"))

        // 切到子会话（有父边）：同样注入。
        let childHex = try XCTUnwrap(spawnResult["child_thread_id"] as? String)
        let childId = KotlinUuid.companion.parse(uuidString: childHex)
        await store.selectConversation(id: childId)
        viewModel.reloadFromStore()
        await viewModel.orchestratedStatusRefreshTask?.value
        XCTAssertTrue(injectedSystemText(viewModel).contains("[mailbox"))
    }

    /// 管线闭环场景 A/B：spawn 后不切换会话，run 级刷新路径（bindings.refreshOrchestrationLinks
    /// 每轮组装前调用）必须让缓存跟上——否则信封折入时模型看不到编排语境。
    func testOrchestrationLinksRefreshWithoutConversationSwitch() async throws {
        let base = makeTempDirectory("OrchestrationRefresh")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler,
            currentConversationId: { store.currentConversation?.id }
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            autoGenerateResponses: false,
            orchestrationToolService: service
        )
        viewModel.conversationStore = store

        viewModel.reloadFromStore()
        await viewModel.orchestratedStatusRefreshTask?.value
        XCTAssertFalse(viewModel.currentConversationHasOrchestrationLinks)

        let spawnResult = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "child"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r1",
            conversationId: parentId
        ))
        XCTAssertEqual(spawnResult["ok"] as? Bool, true)

        // 不 reloadFromStore（不切会话）——直接走 run 级刷新路径。
        await viewModel.refreshCurrentConversationOrchestratedStatus()
        XCTAssertTrue(viewModel.currentConversationHasOrchestrationLinks)

        // 场景 C：子线程 handoff 的 upload 首条是子线程向编排语境，display 不带。
        let handoff = try XCTUnwrap(scheduler.startedHandoff)
        XCTAssertEqual(handoff.uploadMessages.first?.role, MessageRole.system)
        XCTAssertTrue(handoff.uploadMessages.first?.toText().contains("child agent thread") == true)
        XCTAssertFalse(handoff.displayMessages.first?.toText().contains("child agent thread") == true)
        // 真机回归：子线程 handoff 的 maxTokens 被地板提升（makeParams 为 nil）。
        XCTAssertEqual(handoff.params.maxTokens?.int32Value, 32_768)
    }

    /// 子线程 maxTokens 地板 helper：nil/小值 → 32k；显式大值保留；其余字段不动。
    func testChildRunMaxTokenFloorHelper() {
        XCTAssertEqual(makeParams().withMaxTokenFloor(32_768).maxTokens?.int32Value, 32_768)
        XCTAssertEqual(makeParams(maxTokens: 4_000).withMaxTokenFloor(32_768).maxTokens?.int32Value, 32_768)
        XCTAssertEqual(makeParams(maxTokens: 65_536).withMaxTokenFloor(32_768).maxTokens?.int32Value, 65_536)
        XCTAssertEqual(makeParams(maxTokens: 65_536).withMaxTokenFloor(32_768).reasoningLevel, .off)
    }

    func testDynamicSpawnScopeIsPersistedAndRestoredForFollowup() async throws {
        let base = makeTempDirectory("SpawnDynamicScope")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let settings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let service = makeService(
            store: store,
            db: db,
            scheduler: scheduler,
            currentConversationId: { parentId },
            sharedSettings: settings
        )
        let declarations = ToolKt.iosToolDeclarations(names: ["search_web", "tools_list"])
        let params = makeParams().replacingTools(declarations)
        let bridge = IosToolExposureBridge(tools: declarations)

        let spawn = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(
                taskName: "dynamic_worker",
                message: "查资料",
                roleId: "one_off_researcher",
                systemPrompt: "只做来源核对。",
                context: "输出每条结论的来源。",
                toolScope: ["search_web"]
            ),
            providerSetting: makeProviderSetting(),
            params: params,
            runId: "parent-dynamic",
            conversationId: parentId,
            toolExposureBridge: bridge
        ))
        XCTAssertEqual(spawn["ok"] as? Bool, true)
        let childHex = try XCTUnwrap(spawn["child_thread_id"] as? String)
        let handoff = try XCTUnwrap(scheduler.startedHandoff)
        XCTAssertEqual(handoff.fullToolNames, ["search_web"])
        let systemText = handoff.uploadMessages
            .filter { $0.role == MessageRole.system }
            .map { $0.toText() }
            .joined(separator: "\n")
        XCTAssertTrue(systemText.contains("只做来源核对。"))
        XCTAssertTrue(systemText.contains("输出每条结论的来源。"))

        let emptyScope = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(
                taskName: "empty_scope",
                message: "不使用工具",
                roleId: "one_off_no_tools",
                toolScope: []
            ),
            providerSetting: makeProviderSetting(),
            params: params,
            runId: "parent-empty-scope",
            conversationId: parentId,
            toolExposureBridge: bridge
        ))
        XCTAssertEqual(emptyScope["ok"] as? Bool, true)
        XCTAssertEqual(scheduler.startedHandoff?.fullToolNames, [])
        XCTAssertEqual(scheduler.startedHandoff?.params.tools.count, 0)

        let followup = parseJSON(await service.execute(
            toolName: "followup_task",
            arguments: #"{"target":"\#(childHex)","message":"继续核对"}"#,
            providerSetting: makeProviderSetting(),
            params: params,
            runId: "parent-followup",
            conversationId: parentId,
            toolExposureBridge: bridge
        ))
        XCTAssertEqual(followup["status"] as? String, "started")
        XCTAssertEqual(scheduler.startedHandoff?.fullToolNames, ["search_web"])
    }

    func testDynamicDefinitionIsRejectedWhenSwitchIsDisabledButBuiltinRoleWorks() async throws {
        let base = makeTempDirectory("SpawnDynamicDisabled")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let settings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        settings.setDynamicSubAgentsAllowed(false)
        settings.addCustomModel(name: "Worker model", modelId: "worker-model", providerName: "Worker provider")
        let selectedProvider = try XCTUnwrap(settings.snapshot.providers.last)
        let selectedModel = try XCTUnwrap(selectedProvider.models.first)
        _ = settings.updateProviderApiKey(providerId: selectedProvider.id.description(), apiKey: "sk-test")
        defer { _ = settings.removeProvider(providerId: selectedProvider.id.description()) }
        let skillStore = IOSSkillFileStore()
        let skill = try skillStore.createSkill(name: "agent-test-" + UUID().uuidString.lowercased(),
                                              description: "Check task sources", allowedTools: [])
        defer { try? skillStore.deleteSkill(dirName: skill) }
        let markdown = try skillStore.readSkillMarkdown(dirName: skill)
        try skillStore.saveSkillMarkdown(dirName: skill, expectedName: skill,
                                         content: markdown + "\nVerify each claim against its source.\n")
        settings.setSkillEnabled(name: skill, enabled: true)
        settings.configureSubAgentRole(roleId: "explorer", systemPrompt: "核对来源后回答。",
                                       modelId: selectedModel.id.description(), reasoningLevel: .high,
                                       toolAllowlist: [], defaultSkillNames: [skill])
        let service = makeService(
            store: store,
            db: db,
            scheduler: scheduler,
            currentConversationId: { parentId },
            sharedSettings: settings
        )

        let rejected = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(
                taskName: "oneoff",
                roleId: "custom",
                systemPrompt: "动态定义"
            ),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "parent-disabled",
            conversationId: parentId
        ))
        XCTAssertEqual(rejected["error"] as? String, "invalid_arguments")
        XCTAssertNil(scheduler.startedHandoff)

        let builtin = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(
                taskName: "explorer_worker",
                roleId: "explorer"
            ),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "parent-builtin",
            conversationId: parentId
        ))
        XCTAssertEqual(builtin["ok"] as? Bool, true)
        let handoff = try XCTUnwrap(scheduler.startedHandoff)
        XCTAssertEqual(handoff.params.model.id, selectedModel.id)
        XCTAssertEqual(handoff.params.reasoningLevel, .high)
        XCTAssertEqual(handoff.fullToolNames, [])
        let upload = handoff.uploadMessages.map { $0.toText() }.joined(separator: "\n")
        XCTAssertTrue(upload.contains("核对来源后回答。"))
        XCTAssertTrue(upload.contains("Verify each claim against its source."))
    }

    func testInheritedConfigurationSuppressesJevRoleSuggestion() {
        let inherited = IOSOrchestrationAgentConfiguration(
            roleId: nil,
            systemPrompt: "继承的提示",
            context: "继承的上下文",
            toolScope: ["search_web"]
        )

        XCTAssertFalse(
            IOSThreadOrchestrationToolService.shouldRequestJevSubAgentIntent(
                arguments: ["task_name": "worker", "message": "继续"],
                inheritedConfiguration: inherited
            )
        )
        XCTAssertTrue(
            IOSThreadOrchestrationToolService.shouldRequestJevSubAgentIntent(
                arguments: ["task_name": "worker", "message": "继续"],
                inheritedConfiguration: nil
            )
        )
        XCTAssertFalse(
            IOSThreadOrchestrationToolService.shouldRequestJevSubAgentIntent(
                arguments: ["task_name": "worker", "message": "继续", "role_id": "explorer"],
                inheritedConfiguration: nil
            )
        )
    }

}
