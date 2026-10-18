import XCTest
import SQLite3
@preconcurrency import Shared
@testable import iosApp

/// Shared isolated storage, scheduler, and service fixtures for orchestration suites.
/// Original contract: spawn_agent / list_agents / interrupt_agent +
/// FINAL_ANSWER 终态回传）。基建参考 IOSMailboxDeliveryTests / IOSAgentToolEngineTests：
/// 隔离临时目录的会话存储 + 隔离 Room 库（IosDatabaseFactory atFilePath）+ fake
/// 后台调度器（捕获 handoff，不提交真实 BGTask）。
@MainActor
class IOSOrchestrationToolTestCase: XCTestCase {

    // MARK: - Fakes

    /// 捕获 handoff 的后台调度 fake（生产 = IOSChatBackgroundGenerationCoordinator.shared）。
    final class FakeBackgroundScheduler: IOSThreadOrchestrationToolService.BackgroundScheduling {
        var startedHandoff: IOSChatBackgroundHandoff?
        var startedHandoffs: [IOSChatBackgroundHandoff] = []
        var startedReturn = true
        var activeRunByHex: [String: String] = [:]
        var cancelledRunIds: [String] = []
        var cancelReturn = true
        /// P1-e: 子代理活跃 job 计数（生产 = activeSubAgentJobCount；测试手动驱动）。
        var activeJobCount = 0
        var activeSubAgentJobCount = 0
        var activeModelCounts: [String: Int] = [:]
        var activeProviderCounts: [String: Int] = [:]

        func start(
            handoff: IOSChatBackgroundHandoff,
            conversationStore: IOSConversationStore,
            toolRuntime: ChatToolRuntime,
            liveActivityController: AgentLiveActivityController,
            saveMiniAppIfPresent: (@MainActor ([UIMessage], KotlinUuid?) -> ChatMiniAppOutputApplication?)?
        ) -> Bool {
            startedHandoff = handoff
            startedHandoffs.append(handoff)
            return startedReturn
        }

        func activeRunId(conversationHex: String) -> String? {
            activeRunByHex[conversationHex]
        }

        @discardableResult
        func cancelJob(runId: String) -> Bool {
            cancelledRunIds.append(runId)
            return cancelReturn
        }
    }

    // MARK: - Fixtures

    func isolatedDefaults() -> UserDefaults {
        let suite = "IOSOrchestrationToolTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func makeTempDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeStore(directory: URL) -> IOSConversationStore {
        IOSConversationStore(baseDirectory: directory)
    }

    func makeDatabase(directory: URL) -> AgentRuntimeDatabase {
        IosDatabaseFactory.shared.createDatabase(
            atFilePath: directory.appendingPathComponent("orchestration.db").path
        )
    }

    func makeProviderSetting() -> ProviderSetting.OpenAI {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "orch-test",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
    }

    func makePoolModel(
        id: KotlinUuid,
        modelId: String,
        displayName: String
    ) -> Model {
        Model(
            modelId: modelId,
            displayName: displayName,
            id: id,
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
    }

    func makePoolClaudeProvider(
        id: KotlinUuid,
        model: Model
    ) -> ProviderSetting.Claude {
        ProviderSetting.Claude(
            id: id,
            enabled: true,
            name: "Pool Claude",
            models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "test-key",
            baseUrl: "https://api.anthropic.com/v1",
            promptCaching: false
        )
    }

    func makeParams(maxTokens: Int32? = nil) -> TextGenerationParams {
        let model = Model(
            modelId: "test-model",
            displayName: "test-model",
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
        return TextGenerationParams(
            model: model,
            temperature: KotlinFloat(value: 0.7),
            topP: nil,
            maxTokens: maxTokens.map { KotlinInt(value: $0) },
            tools: [],
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
    }

    func makePoolSettings(
        modelA: Model,
        providerA: ProviderSetting,
        modelB: Model,
        providerB: ProviderSetting,
        timeoutMinutes: Int = 10
    ) -> IOSSharedSettingsStore {
        let settings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        settings.addProvider(providerA)
        settings.addProvider(providerB)
        settings.setSubAgentExecutionLimits(maxConcurrentRuns: 10, timeoutMinutes: timeoutMinutes)
        settings.setSubAgentModelPool(modelIds: [modelA.id.toHexDashString(), modelB.id.toHexDashString()])
        settings.setSubAgentPoolReasoning(modelId: modelA.id.toHexDashString(), reasoningLevel: .low)
        settings.setSubAgentPoolReasoning(modelId: modelB.id.toHexDashString(), reasoningLevel: .high)
        return settings
    }

    /// 全量 iOS 声明目录（>40 → lazy 模式；M3 测试需要含 deferred wm_* 的目录）。
    func fullIosDeclarations() -> [Tool] {
        let names =
            IOSWorkspaceToolCatalog.supportedToolNames
            .union(IOSAgentTerminalToolCatalog.supportedToolNames)
            .union(IOSWebMountToolCatalog.supportedToolNames)
            .union(IOSSkillToolCatalog.toolNames)
            .union(IOSMcpManagementToolCatalog.toolNames)
            .union([
                "search_web", "scrape_web", "memory_tool", "generate_image",
                "mcp_call", "subagent_dispatch", "model_council_run", "ask_user",
                "spawn_agent", "list_agents", "interrupt_agent",
                "send_message", "followup_task", "wait_agent",
                "tools_list",
            ])
        return ToolKt.iosToolDeclarations(names: Array(names).sorted())
    }

    func makeRuntime() -> ChatToolRuntime {
        let defaults = isolatedDefaults()
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        return ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: IOSURLSessionSearchHTTPTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
    }

    func makeService(
        store: IOSConversationStore,
        db: AgentRuntimeDatabase,
        scheduler: FakeBackgroundScheduler,
        currentConversationId: @escaping () -> KotlinUuid?,
        foregroundActiveRunId: @escaping (String) -> String? = { _ in nil },
        cancelForegroundRun: @escaping (String) -> Bool = { _ in false },
        foregroundRunCount: @escaping () -> Int = { 0 },
        maxConcurrentRuns: Int? = nil,
        roleAssistantExists: @escaping (KotlinUuid) -> Bool = { _ in true },
        sharedSettings: IOSSharedSettingsStore? = nil,
        jevCoordinator: IOSJevDecisionCoordinator = .shared,
        jevSettingsProvider: @escaping () -> IOSJevSettings = { IOSSharedSettingsStore.loadPersistedJevSettings() }
    ) -> IOSThreadOrchestrationToolService {
        IOSThreadOrchestrationToolService(
            conversationStoreProvider: { store },
            mailboxDaoProvider: { db.mailboxDao() },
            threadEdgeDaoProvider: { db.threadEdgeDao() },
            agentRuntimeDaoProvider: { db.agentRuntimeDao() },
            backgroundCoordinator: scheduler,
            makeBackgroundToolRuntime: { [weak self] in self?.makeRuntime() ?? ChatToolRuntime(
                settingsStore: SettingsStore(),
                sharedSettings: IOSSharedSettingsStore(),
                localToolExecutor: nil,
                searchTransport: IOSURLSessionSearchHTTPTransport(),
                mcpManager: IOSMcpManager(serverProvider: { [] })
            ) },
            currentConversationId: currentConversationId,
            foregroundActiveRunId: foregroundActiveRunId,
            cancelForegroundRun: cancelForegroundRun,
            foregroundRunCount: foregroundRunCount,
            maxConcurrentRuns: maxConcurrentRuns,
            roleAssistantExists: roleAssistantExists,
            sharedSettingsProvider: { sharedSettings },
            jevCoordinator: jevCoordinator,
            jevSettingsProvider: jevSettingsProvider
        )
    }

    func makeJevCoordinator(
        settings: IOSJevSettings,
        transport: JevStubTransport
    ) -> IOSJevDecisionCoordinator {
        IOSJevDecisionCoordinator(deps: .init(
            client: IOSJevClient(transport: transport),
            settingsProvider: { settings },
            apiKeyProvider: { "test-key" },
            now: { Date() }
        ))
    }

    func spawnArguments(
        taskName: String,
        message: String = "初始任务",
        forkTurns: String? = "all",
        roleAssistantId: String? = nil,
        roleId: String? = nil,
        systemPrompt: String? = nil,
        context: String? = nil,
        toolScope: [String]? = nil,
        skillNames: [String]? = nil,
        modelId: String? = nil,
        reasoningLevel: String? = nil
    ) -> String {
        var object: [String: Any] = ["task_name": taskName, "message": message]
        if let forkTurns { object["fork_turns"] = forkTurns }
        if let roleAssistantId { object["role_assistant_id"] = roleAssistantId }
        if let roleId { object["role_id"] = roleId }
        if let systemPrompt { object["system_prompt"] = systemPrompt }
        if let context { object["context"] = context }
        if let toolScope { object["tool_scope"] = toolScope }
        if let skillNames { object["skill_names"] = skillNames }
        if let modelId { object["model_id"] = modelId }
        if let reasoningLevel { object["reasoning_level"] = reasoningLevel }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    func parseJSON(_ text: String) -> [String: Any] {
        let data = text.data(using: .utf8)!
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
