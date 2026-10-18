import Foundation
@preconcurrency import Shared

@MainActor
final class ChatToolRuntime {
    private let settingsStore: SettingsStore
    let sharedSettings: IOSSharedSettingsStore
    let localToolExecutor: IOSLocalToolExecutor?
    let searchTransport: any IOSSearchHTTPTransport
    let mcpManager: IOSMcpManager
    private let skillFileStore: IOSSkillFileStore
    private let workspaceStore: IOSWorkspaceStore
    /// §15 Phase 0: approval-denial ledger events (§11.1 evidence source).
    /// Optional — nil keeps every existing construction site (tests included)
    /// on the pre-contract behavior; the chat coordinator wires its real
    /// ledger here so user denials become durable, attributable facts.
    let ledger: IOSAgentRunLedgering?
    /// Wave B2: recipe store 的基目录（nil = documents，与 registry 同源）。
    /// 也用于 checkpoint 落盘（`recipes/.checkpoints/`）。
    private let recipeStoreBaseDirectory: URL?
    /// Registry over the same store root. Tests with an isolated root must not
    /// accidentally publish lifecycle changes into the app-global registry.
    let recipeRegistry: IOSDynamicToolRegistry
    private let mcpConfigStore: IOSMcpConfigStore
    /// P1-c: 线程编排工具执行体（spawn_agent/list_agents/interrupt_agent）。
    /// 可选：未注入时三工具返回结构化「不可用」错误而不是静默缺失。
    let orchestrationToolService: IOSThreadOrchestrationToolService?
    /// 小说讨论写工具的领域入口（weak：AppShell 先构造本 runtime 再构造
    /// DefaultNovelCreation，由 NovelCreationComposition 回填；weak 保证
    /// runtime ↔ creation 不形成引用环）。nil 时讨论引擎不注册小说写工具。
    weak var novelProjectCreation: DefaultNovelCreation?
    /// 跨会话读取工具（session_search/session_read）的会话存储源。可选：
    /// 未注入时两工具返回结构化「不可用」错误（照 orchestrationToolService 先例；
    /// 测试注入隔离 store）。
    let conversationStoreProvider: (() -> IOSConversationStore?)?
    /// P2-a: harness 拥有的记忆污染置位回调（conversationId, toolName）。由接线方
    /// 注入持久化（storage 写 + baseline 守卫）；nil = 不置位（零行为变化）。置位
    /// 判定（工具名 + 成功输出）在本 runtime 收口处完成，不经过模型。
    let memoryPollutionMarker: ((KotlinUuid, String) -> Void)?
    /// 当前进程内的终端 session 授权按能力隔离，不落盘；global run scope
    /// 只用于桥接本轮已冻结的 execution-policy snapshot。
    private var ishAutoApprovedConversationCapabilities: Set<String> = []
    private var ishAutoApprovedRunCapabilities: Set<String> = []
    private var ishAutoApprovedRunIds: Set<String> = []
    lazy var subAgentRunner = SubAgentRunner()
    /// Legacy `subagent_dispatch` shares the same pool selection and
    /// reservation semantics as thread orchestration. Its provider/model count
    /// view is process-local because the runner predates BackgroundScheduling.
    let subAgentModelPool = IOSSubAgentModelPool()
    var activeLegacySubAgentRuns = 0
    var activeLegacyModelCounts: [String: Int] = [:]
    var activeLegacyProviderCounts: [String: Int] = [:]
    lazy var councilRunner = CouncilRunner()
    /// Agent 自配置 provider/model（SharedSettings 真源；密钥永不进 tool result）。
    lazy var providerConfigToolService = IOSProviderConfigToolService(
        sharedSettings: sharedSettings
    )
    lazy var themePackToolService = IOSThemePackToolService()
    /// P3-a: JavaScriptCore 沙箱引擎（exec 纯求值）。每次求值独立 context +
    /// 独立串行队列；超时 abandon 语义见 IOSJsSandboxEngine。
    lazy var jsSandboxEngine = IOSJsSandboxEngine()
    /// P3-c: 会话级 cell 注册表（exec cell + store/load KV 的唯一 owner，
    /// 跨 run 共享）。默认生产单例；测试注入隔离实例。
    let jsCellRegistry: IOSJsCellRegistry
    private let soulPreviousStore: IOSSoulPreviousStore
    private let mcpImportClientFactory: ((IOSMcpServerConfig) -> any IOSMcpClienting)?
    let autoApprovalGate: IOSJevAutoApprovalGate
    lazy var skillMcpToolService = IOSSkillMcpToolService(
        skillStore: skillFileStore,
        sharedSettings: sharedSettings,
        workspaceStore: workspaceStore,
        mcpConfigStore: mcpConfigStore,
        mcpManager: mcpManager,
        ephemeralClientFactory: mcpImportClientFactory
    )
    lazy var soulService = IOSSoulService(
        workspaceStore: workspaceStore,
        sharedSettings: sharedSettings,
        previousStore: soulPreviousStore
    )
    /// Wave B2: `recipe_import` 服务（preview → 批准 → CAS apply → registry
    /// refresh）。recipe store 基目录与 registry 同源（nil = documents）。
    let recipeToolService: IOSRecipeToolService
    let pluginToolService: IOSPluginToolService
    let pluginHealthStore: IOSPluginHealthStore
    /// Wave B2: checkpoint 落盘（`<base>/recipes/.checkpoints/`）。

    lazy var dynamicToolLifecycle = ChatDynamicToolLifecycle(runtime: self)
    lazy var pluginExecution = ChatPluginExecution(runtime: self)
    lazy var recipeExecution = ChatRecipeExecution(runtime: self, baseDirectory: recipeStoreBaseDirectory)
    lazy var sessionReadTool = ChatSessionReadTool(conversationStoreProvider: conversationStoreProvider)
    lazy var runtimeStatusTool = ChatRuntimeStatusTool(runtime: self)
    lazy var javaScriptTool = ChatJavaScriptTool(
        jsCellRegistry: jsCellRegistry, jsSandboxEngine: jsSandboxEngine, sharedSettings: sharedSettings
    )

    var effectiveGlobalAutoApproveEnabled: Bool {
        IOSExecutionPolicyContext.snapshot?.globalAutoApproveEnabled
            ?? IOSLocalToolExecutor.isGlobalAutoApproveEnabled
    }

    var effectiveHighRiskAutoApproveEnabled: Bool {
        IOSExecutionPolicyContext.snapshot?.highRiskAutoApproveEnabled
            ?? IOSLocalToolExecutor.isHighRiskAutoApproveEnabled
    }

    func autoApproveIshForSession(
        runId: String,
        conversationId: KotlinUuid?,
        capabilityId: String
    ) {
        if let conversationId {
            ishAutoApprovedConversationCapabilities.insert(
                ishApprovalKey(scopeId: conversationId.toHexDashString(), capabilityId: capabilityId)
            )
        } else {
            ishAutoApprovedRunCapabilities.insert(
                ishApprovalKey(scopeId: runId, capabilityId: capabilityId)
            )
        }
    }

    func autoApproveIshForRun(_ runId: String) {
        ishAutoApprovedRunIds.insert(runId)
    }

    func isIshAutoApproved(
        toolName: String,
        input: String,
        runId: String,
        conversationId: KotlinUuid?
    ) -> Bool {
        if toolName == IOSAmberShellToolCatalog.executeToolName {
            return false
        }
        if ishAutoApprovedRunIds.contains(runId) { return true }
        guard let capabilityId = localToolExecutor?.terminalApprovalCapabilityId(
            toolName: toolName,
            input: input
        ) ?? IOSCapabilityRegistry.capability(forToolName: toolName)?.id else {
            return false
        }
        if ishAutoApprovedRunCapabilities.contains(
            ishApprovalKey(scopeId: runId, capabilityId: capabilityId)
        ) {
            return true
        }
        guard let conversationId else { return false }
        return ishAutoApprovedConversationCapabilities.contains(
            ishApprovalKey(scopeId: conversationId.toHexDashString(), capabilityId: capabilityId)
        )
    }

    private func ishApprovalKey(scopeId: String, capabilityId: String) -> String {
        "\(scopeId)|\(capabilityId)"
    }

    func isIshToolAutoApproved(
        toolName: String,
        input: String,
        runId: String,
        conversationId: KotlinUuid?
    ) -> Bool {
        if isIshAutoApproved(
            toolName: toolName,
            input: input,
            runId: runId,
            conversationId: conversationId
        )
            || effectiveHighRiskAutoApproveEnabled {
            return true
        }
        guard let capability = IOSCapabilityRegistry.capability(forToolName: toolName) else {
            return false
        }
        let policy = IOSExecutionPolicyContext.snapshot?.policy(for: capability)
            ?? localToolExecutor?.permissionPolicy(capabilityId: capability.id)
        return policy == .autoApproveHighRisk
    }

    var effectiveExecJavaScriptEnabled: Bool {
        IOSExecutionPolicyContext.snapshot?.execJavaScriptEnabled
            ?? settingsStore.execJavaScriptEnabled
    }

    var effectiveWebSearchEnabled: Bool {
        IOSExecutionPolicyContext.snapshot?.webSearchEnabled
            ?? sharedSettings.snapshot.enableWebSearch
    }

    func withExecutionPolicy<T>(
        _ executionPolicy: IOSExecutionPolicySnapshot?,
        operation: @MainActor () async -> T
    ) async -> T {
        await IOSExecutionPolicyContext.$snapshot.withValue(executionPolicy) {
            await operation()
        }
    }

    init(
        settingsStore: SettingsStore,
        sharedSettings: IOSSharedSettingsStore,
        localToolExecutor: IOSLocalToolExecutor?,
        searchTransport: any IOSSearchHTTPTransport,
        mcpManager: IOSMcpManager,
        skillFileStore: IOSSkillFileStore = IOSSkillFileStore(),
        workspaceStore: IOSWorkspaceStore = .shared,
        mcpConfigStore: IOSMcpConfigStore = .shared,
        orchestrationToolService: IOSThreadOrchestrationToolService? = nil,
        memoryPollutionMarker: ((KotlinUuid, String) -> Void)? = nil,
        jsCellRegistry: IOSJsCellRegistry? = nil,
        conversationStoreProvider: (() -> IOSConversationStore?)? = nil,
        ledger: IOSAgentRunLedgering? = nil,
        recipeStoreBaseDirectory: URL? = nil,
        recipeRegistry: IOSDynamicToolRegistry? = nil,
        soulPreviousStore: IOSSoulPreviousStore? = nil,
        mcpImportClientFactory: ((IOSMcpServerConfig) -> any IOSMcpClienting)? = nil,
        autoApprovalGate: IOSJevAutoApprovalGate? = nil
    ) {
        self.settingsStore = settingsStore
        self.sharedSettings = sharedSettings
        self.localToolExecutor = localToolExecutor
        self.searchTransport = searchTransport
        self.mcpManager = mcpManager
        self.skillFileStore = skillFileStore
        self.workspaceStore = workspaceStore
        self.mcpConfigStore = mcpConfigStore
        self.orchestrationToolService = orchestrationToolService
        self.memoryPollutionMarker = memoryPollutionMarker
        self.jsCellRegistry = jsCellRegistry ?? .shared
        self.conversationStoreProvider = conversationStoreProvider
        self.ledger = ledger
        self.recipeStoreBaseDirectory = recipeStoreBaseDirectory
        let resolvedRecipeRegistry = recipeRegistry
            ?? recipeStoreBaseDirectory.map(IOSDynamicToolRegistry.init(baseDirectory:))
            ?? .shared
        self.recipeRegistry = resolvedRecipeRegistry
        let resolvedRecipeBaseDirectory = recipeStoreBaseDirectory
            ?? (try? FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ))
            ?? FileManager.default.temporaryDirectory
        self.recipeToolService = IOSRecipeToolService(
            workspaceStore: workspaceStore,
            recipeStore: IOSRecipeFileStore(
                baseDirectory: resolvedRecipeBaseDirectory,
                fileManager: .default
            ),
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry,
            refreshRegistry: {
                await resolvedRecipeRegistry.refresh()
            }
        )
        self.pluginToolService = IOSPluginToolService(
            workspaceStore: workspaceStore,
            pluginStore: IOSPluginFileStore(
                baseDirectory: resolvedRecipeBaseDirectory,
                fileManager: .default
            ),
            refreshRegistry: {
                await resolvedRecipeRegistry.refresh()
            }
        )
        self.pluginHealthStore = IOSPluginHealthStore(
            baseDirectory: resolvedRecipeBaseDirectory,
            fileManager: .default
        )
        self.soulPreviousStore = soulPreviousStore ?? IOSSoulPreviousStore()
        self.mcpImportClientFactory = mcpImportClientFactory
        self.autoApprovalGate = autoApprovalGate ?? .shared
    }

    /// 把只读 preview 对应的 CAS 上下文交给 Coordinator 的 pending MCP 槽。
    /// 取走即删除，避免批准恢复时重复消费同一个候选。
    func takePreparedSkillImportForApproval(toolCallId: String) -> IOSPreparedSkillImport? {
        dynamicToolLifecycle.takePreparedSkillImport(toolCallId: toolCallId)
    }

    func discardPreparedSkillImportForApproval(toolCallId: String) {
        dynamicToolLifecycle.discardPreparedImports(toolCallId: toolCallId)
    }

    func discardPreparedThemeImport() {
        themePackToolService.discardPreparedImport()
    }

    func takePreparedSoulImportForApproval(toolCallId: String) -> IOSPreparedSoulImport? {
        dynamicToolLifecycle.takePreparedSoulImport(toolCallId: toolCallId)
    }

    func takePreparedMcpImportForApproval(toolCallId: String) -> IOSPreparedMcpImport? {
        dynamicToolLifecycle.takePreparedMcpImport(toolCallId: toolCallId)
    }

    /// Wave B2: `recipe_import` 的批准上下文（与 skill_import 同模式）。
    func takePreparedRecipeImportForApproval(toolCallId: String) -> IOSPreparedRecipeImport? {
        recipeExecution.takePreparedImport(toolCallId: toolCallId)
    }

    func discardPreparedRecipeImportForApproval(toolCallId: String) {
        recipeExecution.discardPreparedImport(toolCallId: toolCallId)
        pluginExecution.discardPreparedImport(toolCallId: toolCallId)
    }

    func takePreparedPluginImportForApproval(toolCallId: String) -> IOSPreparedPluginImport? {
        pluginExecution.takePreparedImport(toolCallId: toolCallId)
    }

    func takePreparedPluginInvocationForApproval(toolCallId: String) -> IOSPreparedPluginInvocation? {
        pluginExecution.takePreparedInvocation(toolCallId: toolCallId)
    }

    func discardPreparedPluginInvocationForApproval(toolCallId: String) {
        pluginExecution.discardPreparedInvocation(toolCallId: toolCallId)
    }

    func takePreparedRecipeExecution(toolCallId: String) -> IOSRecipeExecutionState? {
        recipeExecution.takePreparedExecution(toolCallId: toolCallId)
    }

    func discardPreparedRecipeExecution(toolCallId: String) {
        recipeExecution.discardPreparedExecution(toolCallId: toolCallId)
    }

    func finishPluginInvocationApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        prepared: IOSPreparedPluginInvocation?,
        toolExposureBridge: IosToolExposureBridge?
    ) async -> [UIMessage] {
        await pluginExecution.finishPluginInvocationApproval(
            pending: pending, allow: allow, prepared: prepared, toolExposureBridge: toolExposureBridge
        )
    }

    func finishPluginImportApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        prepared: IOSPreparedPluginImport?
    ) async -> [UIMessage] {
        await pluginExecution.finishPluginImportApproval(pending: pending, allow: allow, prepared: prepared)
    }

    func finishRecipeStepApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        executionContext: IOSRecipeExecutionState?,
        toolExposureBridge: IosToolExposureBridge?
    ) async -> RecipeApprovalFinishResult {
        await recipeExecution.finishRecipeStepApproval(
            pending: pending, allow: allow, executionContext: executionContext,
            toolExposureBridge: toolExposureBridge
        )
    }

    func finishRecipeImportApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        prepared: IOSPreparedRecipeImport?
    ) async -> [UIMessage] {
        await recipeExecution.finishRecipeImportApproval(pending: pending, allow: allow, prepared: prepared)
    }

    func isPluginOutcomeUnknown(in messages: [UIMessage], toolCallId: String) -> Bool {
        pluginExecution.isPluginOutcomeUnknown(in: messages, toolCallId: toolCallId)
    }

    /// Tool set for the novel discussion agent. Ask User is always available;
    /// search continues to respect the global Web Search consent switch. The
    /// novel project write tools are registered only when a per-run project
    /// context is provided (discussion runs started by the novel lifecycle),
    /// regardless of the web-search switch.
    func nextPendingToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> ChatPendingToolCall? {
        // tool_search runs first: it changes which tools the NEXT round declares,
        // so its result should reach the model before any other pending call.
        if let toolCall = pendingToolSearchToolCall(in: messages, availableToolNames: availableToolNames) {
            return ChatPendingToolCall(kind: .toolSearch, toolCall: toolCall)
        }
        if let toolCall = pendingSearchToolCall(in: messages, availableToolNames: availableToolNames) {
            return ChatPendingToolCall(kind: .search, toolCall: toolCall)
        }
        if let toolCall = pendingWorkspaceToolCall(in: messages, availableToolNames: availableToolNames) {
            return ChatPendingToolCall(kind: .workspace, toolCall: toolCall)
        }
        if let toolCall = pendingIshToolCall(in: messages, availableToolNames: availableToolNames) {
            return ChatPendingToolCall(kind: .ish, toolCall: toolCall)
        }
        if let toolCall = pendingWebMountToolCall(in: messages, availableToolNames: availableToolNames) {
            return ChatPendingToolCall(kind: .webMount, toolCall: toolCall)
        }
        if let toolCall = pendingMemoryToolCall(in: messages, availableToolNames: availableToolNames) {
            return ChatPendingToolCall(kind: .memory, toolCall: toolCall)
        }
        if let toolCall = pendingImageToolCall(in: messages, availableToolNames: availableToolNames) {
            return ChatPendingToolCall(kind: .image, toolCall: toolCall)
        }
        if let toolCall = pendingAskUserToolCall(in: messages, availableToolNames: availableToolNames) {
            return ChatPendingToolCall(kind: .askUser, toolCall: toolCall)
        }
        if let toolCall = pendingSessionReadToolCall(in: messages, availableToolNames: availableToolNames) {
            return ChatPendingToolCall(kind: .sessionRead, toolCall: toolCall)
        }
        if let toolCall = pendingRuntimeStatusToolCall(in: messages, availableToolNames: availableToolNames) {
            return ChatPendingToolCall(kind: .runtimeStatus, toolCall: toolCall)
        }
        if let toolCall = pendingAdvancedToolCall(in: messages, availableToolNames: availableToolNames) {
            return ChatPendingToolCall(kind: .advanced, toolCall: toolCall)
        }
        return nil
    }

    func hasUnresolvedToolCall(in messages: [UIMessage]) -> Bool {
        unresolvedToolCall(in: messages) != nil
    }

    func execute(
        _ pendingToolCall: ChatPendingToolCall,
        context: ChatPendingToolApproval,
        toolExposureBridge: IosToolExposureBridge? = nil,
        nestedToolRunner: IosExecNestedToolRunner? = nil,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot? = nil
    ) async -> ChatToolRuntimeResult {
        let executionPolicy = context.executionPolicy ?? IOSExecutionPolicyContext.snapshot
        return await IOSExecutionPolicyContext.$snapshot.withValue(executionPolicy) {
            await executeWithCurrentExecutionPolicy(
                pendingToolCall,
                context: context,
                toolExposureBridge: toolExposureBridge,
                nestedToolRunner: nestedToolRunner,
                recipeCatalogSnapshot: recipeCatalogSnapshot
            )
        }
    }

    private func executeWithCurrentExecutionPolicy(
        _ pendingToolCall: ChatPendingToolCall,
        context: ChatPendingToolApproval,
        toolExposureBridge: IosToolExposureBridge?,
        nestedToolRunner: IosExecNestedToolRunner?,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?
    ) async -> ChatToolRuntimeResult {
        // I-2 fail-closed: gate every kind on the same check before it reaches its
        // own dispatch* function, all of which read `context.toolCall.input`
        // directly. A gateway that double-writes a call, truncates one mid
        // argument, or a model that emits bare non-JSON text must not run with
        // silently wrong (not absent) arguments — see `parseInputStrict()`. This
        // does not execute the tool; it resolves it in place with a structured
        // error and lets the existing resume path hand that back to the model.
        if let invalid = context.toolCall.parseInputStrict() as? ToolInputParse.Invalid {
            let resolvedMessages = messagesByFinishingToolCall(
                context.toolCall,
                outputText: ChatToolOutputFormatter.toolArgumentsInvalidJSON(
                    toolName: context.toolCall.toolName,
                    message: invalid.message,
                    rawPrefix: invalid.rawPrefix
                ),
                in: context.baseMessages
            )
            return .completed(resolvedMessages)
        }
        if await shouldTightenAutoApproval(pendingToolCall, context: context, toolExposureBridge: toolExposureBridge),
           let tightened = (IOSExecutionPolicyContext.snapshot ?? localToolExecutor?.executionPolicySnapshot(
               execJavaScriptEnabled: effectiveExecJavaScriptEnabled,
               webSearchEnabled: effectiveWebSearchEnabled
           ))?.withoutAutoApprove() {
            return await IOSExecutionPolicyContext.$snapshot.withValue(tightened) {
                await dispatchPendingToolCall(
                    pendingToolCall,
                    context: context,
                    toolExposureBridge: toolExposureBridge,
                    nestedToolRunner: nestedToolRunner,
                    recipeCatalogSnapshot: recipeCatalogSnapshot
                )
            }
        }
        return await dispatchPendingToolCall(
            pendingToolCall,
            context: context,
            toolExposureBridge: toolExposureBridge,
            nestedToolRunner: nestedToolRunner,
            recipeCatalogSnapshot: recipeCatalogSnapshot
        )
    }

    /// Jev 自动批准复核（前台入口）：只看可能弹出审批卡的工具类别。
    func shouldTightenAutoApproval(
        _ pendingToolCall: ChatPendingToolCall,
        context: ChatPendingToolApproval,
        toolExposureBridge: IosToolExposureBridge?
    ) async -> Bool {
        switch pendingToolCall.kind {
        case .ish, .workspace, .webMount, .advanced, .search: break
        default: return false
        }
        return await shouldTightenAutoApproval(
            toolCall: context.toolCall,
            recentUserTexts: context.recentUserTexts
                ?? context.baseMessages.filter { $0.role == MessageRole.user }.suffix(3).map { $0.toText() },
            runId: context.runId,
            conversationId: context.conversationId,
            toolExposureBridge: toolExposureBridge
        )
    }

    /// 自动批准生效时，非低风险调用经 Jev 判定高风险则改为人工审批（前台与后台共用）。
    func hasAutoApprovalPolicy(for toolCall: UIMessagePart.Tool) -> Bool {
        // Terminal job tools can resolve to a different capability from their
        // static declaration. Use the same resolver as the local executor.
        let capabilityId = localToolExecutor?.terminalApprovalCapabilityId(
            toolName: toolCall.toolName, input: toolCall.input
        ) ?? IOSCapabilityRegistry.capability(forToolName: toolCall.toolName)?.id
        let capability = capabilityId.flatMap { id in
            IOSCapabilityRegistry.capabilities.first { $0.id == id }
        }
        let policy = capability.map {
            IOSExecutionPolicyContext.snapshot?.policy(for: $0)
                ?? localToolExecutor?.permissionPolicy(capabilityId: $0.id)
                ?? IOSPermissionStore.defaultPolicy(for: $0)
        }
        guard policy != .disabled else { return false }
        return effectiveGlobalAutoApproveEnabled || effectiveHighRiskAutoApproveEnabled
            || policy == .autoApprove || policy == .autoApproveHighRisk
    }

    func shouldTightenAutoApproval(
        toolCall: UIMessagePart.Tool,
        recentUserTexts: [String],
        runId: String,
        conversationId: KotlinUuid?,
        toolExposureBridge: IosToolExposureBridge?
    ) async -> Bool {
        guard hasAutoApprovalPolicy(for: toolCall),
              sharedSettings.jevSettings.effectiveMode(for: .autoApprovalGate) != .off else { return false }
        let name = toolCall.toolName
        // 只读检索、编排/交互类工具（无审批分支，收紧快照还会传给子运行）、
        // 已获会话/运行级授权的终端调用不复核。
        guard !IOSJevContextSelectionService.isRereadableTool(name),
              !Self.execNestedToolExclusions.contains(name),
              !isIshAutoApproved(toolName: name, input: toolCall.input, runId: runId, conversationId: conversationId)
        else { return false }
        let facts = IOSJevApprovalTriageService.StaticFacts.registeredTool(
            metadataJSON: toolExposureBridge?.approvalTriageFactsJsonForInvocation(
                toolName: name,
                argumentsJson: toolCall.input
            )
        )
        guard !IOSJevAutoApprovalGate.isStaticallyLowRisk(facts) else { return false }
        return await autoApprovalGate.shouldEscalate(
            requestId: ChatToolCallParsing.requestId(for: toolCall),
            toolName: name,
            argumentsJSON: toolCall.input,
            recentUserTexts: recentUserTexts,
            runKey: runId
        )
    }

    private func dispatchPendingToolCall(
        _ pendingToolCall: ChatPendingToolCall,
        context: ChatPendingToolApproval,
        toolExposureBridge: IosToolExposureBridge?,
        nestedToolRunner: IosExecNestedToolRunner?,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?
    ) async -> ChatToolRuntimeResult {
        switch pendingToolCall.kind {
        case .toolSearch:
            return await executeToolSearchToolCall(context, toolExposureBridge: toolExposureBridge)
        case .search:
            return await executeSearchToolCall(context)
        case .workspace:
            return await executeWorkspaceToolCall(context)
        case .ish:
            return await executeIshToolCall(context)
        case .webMount:
            return await executeWebMountToolCall(context)
        case .memory:
            return executeMemoryToolCall(context)
        case .image:
            return await executeImageToolCall(context)
        case .askUser:
            return executeAskUserToolCall(context)
        case .sessionRead:
            return await executeSessionReadToolCall(context)
        case .runtimeStatus:
            return executeRuntimeStatusToolCall(context, toolExposureBridge: toolExposureBridge)
        case .advanced:
            return await executeAdvancedToolCall(
                context,
                nestedTools: Self.execNestedToolsBridge(
                    toolExposureBridge: toolExposureBridge,
                    nestedToolRunner: nestedToolRunner
                ),
                toolExposureBridge: toolExposureBridge,
                recipeCatalogSnapshot: recipeCatalogSnapshot
            )
        }
    }
    func unresolvedToolCall(in messages: [UIMessage]) -> UIMessagePart.Tool? {
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: { $0.output.isEmpty }) {
                return toolCall
            }
        }
        return nil
    }

    private func pendingToolSearchToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        // M5: tools_list 与 tool_search 同属本地目录调用（发现引导同一路径）。
        let localDiscoveryNames: Set<String> = ["tool_search", "tools_list"]
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    localDiscoveryNames.contains($0.toolName)
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    private func pendingSearchToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    IOSSearchExecutor.supportedToolNames.contains($0.toolName)
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    private func pendingWorkspaceToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        guard localToolExecutor != nil else { return nil }
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    IOSWorkspaceToolCatalog.supportedToolNames.contains($0.toolName)
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    private func pendingIshToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        guard localToolExecutor != nil else { return nil }
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    IOSAgentTerminalToolCatalog.supportedToolNames.contains($0.toolName)
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    private func pendingWebMountToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        guard isWebMountRuntimeEnabled else { return nil }
        let webMountNames = IOSWebMountToolCatalog.supportedToolNames
            .union(IOSWebMountToolCatalog.unsupportedToolNames)
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    webMountNames.contains($0.toolName)
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    private func pendingMemoryToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    $0.toolName == "memory_tool"
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    private func pendingImageToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    $0.toolName == "generate_image"
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    /// Resolve the designated image-generation model (Settings.imageGenerationModelId) to
    /// its modelId + provider apiKey/baseURL. Returns nil when no usable image model is set,
    /// which gates the generate_image tool off (image generation disabled).
    func resolvedImageGenerationConfig() -> (modelId: String, apiKey: String, baseURL: String)? {
        let snap = sharedSettings.snapshot
        guard let model = snap.findModelById(uuid: snap.imageGenerationModelId),
              let provider = ChatProviderConfiguration.provider(for: model, providers: snap.providers) else {
            return nil
        }
        let apiKey = ChatProviderConfiguration.apiKey(of: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = ChatProviderConfiguration.baseURL(of: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !baseURL.isEmpty else { return nil }
        return (model.modelId, apiKey, baseURL)
    }

    /// Keep the chosen image model separate from the account's chat router.
    func codexImageConfig() -> ChatCodexImageConfig {
        let snap = sharedSettings.snapshot
        guard let model = snap.findModelById(uuid: snap.imageGenerationModelId),
              let provider = ChatProviderConfiguration.provider(for: model, providers: snap.providers) as? ProviderSetting.OpenAI,
              provider.authMode == OpenAIAuthMode.codexOauth else {
            return .notSelected
        }
        let providerId = provider.id.description()
        guard IOSCodexAuthStore.load(providerId: providerId) != nil else { return .notSignedIn }
        let chatModel = snap.getCurrentChatModel()
        let preferred = chatModel.flatMap { chat in
            ChatProviderConfiguration.provider(for: chat, providers: snap.providers)?.id == provider.id
                ? chat.modelId : nil
        }
        return .signedIn(providerId: providerId, modelId: model.modelId, preferredRoutingModelID: preferred)
    }

    private func pendingAskUserToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    $0.toolName == "ask_user"
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    private func executeAskUserToolCall(_ pending: ChatPendingToolApproval) -> ChatToolRuntimeResult {
        if let request = ChatToolApprovalRequestBuilder.askUser(for: pending.toolCall) {
            return .waitingForApproval(.askUser(request))
        }
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: #"{"error":"ask_user requires a non-empty question."}"#,
            in: pending.baseMessages
        ))
    }

    /// 跨会话读取工具（session_search/session_read）的待执行检测。只识别
    /// 可见且 output 为空的调用（照 pendingAskUserToolCall 模式）。
    private func pendingAdvancedToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        var advancedNames: Set<String> = Set([
            "mcp_call", "subagent_dispatch", "model_council_run",
            IOSSoulToolCatalog.toolName,
            // P1-c/P1-d: 线程编排工具（非常驻，tool_search 命中后与 mcp__* 同样可执行）。
            "spawn_agent", "list_agents", "interrupt_agent",
            "send_message", "followup_task", "wait_agent",
        ])
        .union(IOSAppleAgentToolCatalog.toolNames)
        .union(IOSSkillToolCatalog.toolNames)
        .union(IOSMcpManagementToolCatalog.toolNames)
        .union(IOSProviderConfigToolCatalog.toolNames)
        .union(IOSThemePackToolCatalog.toolNames)
        // Wave B2: recipe_import（与 skill_import 同级，deferred 池）。
        .union(IOSRecipeToolCatalog.toolNames)
        // P3-a: exec 仅开关开时存在执行路径；关时零痕迹——模型调用 exec 走
        // 未知名硬失败语义（与声明侧 gate 同源：settingsStore.execJavaScriptEnabled）。
        // P3-c: wait 与 exec 同开关（cell 生命周期续取，无独立设置项）。
        if effectiveExecJavaScriptEnabled {
            advancedNames.insert("exec")
            advancedNames.insert("wait")
        }
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    (advancedNames.contains($0.toolName)
                        || ToolKt.isExpandedMcpToolName(name: $0.toolName)
                        // Wave B2: `recipe__*` 通用路由——与 mcp__* 同模式，
                        // 命中后下一轮才可执行（声明与执行同 snapshot，§16.1）。
                        || IOSDynamicToolRegistry.isDynamicWorkflowToolName($0.toolName))
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    /// P0-a: `tool_search`/`tools_list` are pure local discovery calls — no
    /// approval; `tools_list` has no network either. `tool_search` runs through
    /// the KMP bridge (parses query/category/limit, searches the full
    /// declaration catalog, feeds `expanded_tools` back into the run exposure
    /// state so hits become callable on the NEXT round); `tools_list` returns
    /// the full catalog {name, description} list from the same bridge (M5).
    /// Jev Phase 1: tool_search 可选走语义发现服务（off 零网络；shadow 只观测；
    /// active 应用排序，失败回退原搜索）。tools_list 永远直连 bridge。
    private func executeToolSearchToolCall(
        _ pending: ChatPendingToolApproval,
        toolExposureBridge: IosToolExposureBridge?
    ) async -> ChatToolRuntimeResult {
        let resultText: String
        if pending.toolCall.toolName == "tools_list" {
            guard let bridge = toolExposureBridge else {
                return .completed(messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: "tools_list 当前不可用。"
                    ),
                    in: pending.baseMessages
                ))
            }
            resultText = bridge.executeToolsList()
        } else {
            resultText = await IOSJevToolDiscoveryService.execute(
                argumentsJson: pending.toolCall.input,
                selectedTaskText: pending.baseMessages.reversed().first(where: { $0.role == MessageRole.user })?.toText() ?? "",
                bridge: toolExposureBridge,
                identity: IOSJevToolDiscoveryService.RunIdentity(
                    runId: pending.runId,
                    turnBudgetKey: IOSJevToolDiscoveryService.turnBudgetKey(runId: pending.runId),
                    trackNextForegroundStep: true
                )
            )
        }
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        ))
    }

    func toolCall(name: String, input: String) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: "subagent-\(name)-\(chatInputDigest(for: input))",
            toolName: name,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    /// All user approval-card finish paths funnel their audit record here
    /// (memory/search/webMount/ish/MCP/council). `isUserDecision` is false
    /// only for policy-level denials (e.g. a disabled capability rejecting a
    /// model call), which are not user signals and must not surface as
    /// `approvalDenied` evidence.
    func recordToolApproval(
        capabilityId: String,
        toolCall: UIMessagePart.Tool,
        action: IOSToolApprovalAction,
        reason: String,
        runId: String,
        executionPolicy: IOSExecutionPolicySnapshot? = nil,
        isUserDecision: Bool = true,
        conversationId: KotlinUuid? = nil
    ) {
        let policy = executionPolicy ?? IOSExecutionPolicyContext.snapshot
        if let localToolExecutor {
            let request = localToolExecutor.executionRequest(
                toolName: toolCall.toolName,
                operation: toolCall.input,
                isUserInitiated: true,
                runId: runId,
                conversationId: conversationId?.toHexDashString() ?? "",
                executionPolicy: policy
            )
            localToolExecutor.recordApproval(
                capabilityId: capabilityId,
                toolName: toolCall.toolName,
                action: action,
                reason: reason,
                runId: runId,
                scopeDigest: request.scopeDigest,
                payloadDigest: request.payloadDigest,
                policyDigest: policy?.digest
            )
        }
        if action == .denied, isUserDecision {
            recordApprovalDeniedInLedger(
                runId: runId,
                toolCall: toolCall,
                reason: reason,
                capabilityId: capabilityId
            )
        }
    }

    /// §15 Phase 0 (§11.1): a user denial of an approval card is a required
    /// evolution evidence source. Writes the ledger's `approval_denied` event
    /// (best-effort, same tier as Finished — the decision is already final in
    /// the approval UI; a failed write only loses attribution). Fire-and-forget
    /// so sync finish paths (memory) do not gain an await.
    private func recordApprovalDeniedInLedger(
        runId: String,
        toolCall: UIMessagePart.Tool,
        reason: String,
        capabilityId: String?
    ) {
        guard let ledger else { return }
        Task { [ledger] in
            await ledger.recordApprovalDenied(
                runId: runId,
                toolCallId: toolCall.toolCallId,
                toolName: toolCall.toolName,
                reason: reason,
                capabilityId: capabilityId
            )
        }
    }

    func messagesByFinishingToolCall(
        _ targetToolCall: UIMessagePart.Tool,
        outputParts: [UIMessagePart],
        in messages: [UIMessage]
    ) -> [UIMessage] {
        var didFinishToolCall = false

        return messages.map { message in
            guard message.role == MessageRole.assistant else { return message }
            var didChangeMessage = false
            let parts = message.parts.map { part -> UIMessagePart in
                guard !didFinishToolCall,
                      let toolPart = part as? UIMessagePart.Tool,
                      chatToolCallKey(toolPart) == chatToolCallKey(targetToolCall) else {
                    return part
                }

                didFinishToolCall = true
                didChangeMessage = true
                // Provider apply 入参可能含 api_key：落盘与后续轮次重传必须脱敏。
                let persistedInput: String
                if IOSProviderConfigToolCatalog.toolNames.contains(toolPart.toolName) {
                    persistedInput = IOSProviderConfigToolCatalog.redactedArgumentsJSON(toolPart.input)
                } else {
                    persistedInput = toolPart.input
                }
                // 工具输出统一收口：总文本超上限就地截断（JSON 形态保形），
                // 防止 Exa 全文等巨量输出被持久化进会话。
                return PromptTranscript.shared.doCopyTool(
                    tool: toolPart,
                    input: persistedInput,
                    output: ChatToolOutputFormatter.cappedToolOutputParts(outputParts)
                )
            }

            guard didChangeMessage else { return message }
            return UIMessage(
                id: message.id,
                role: message.role,
                parts: parts,
                annotations: message.annotations,
                createdAt: message.createdAt,
                finishedAt: message.finishedAt ?? chatNowLocalDateTime(),
                modelId: message.modelId,
                usage: message.usage,
                translation: message.translation
            )
        }
    }

    func isMcpNetworkTool(_ toolName: String) -> Bool {
        toolName == "mcp_call"
            || toolName == "mcp_test"
            || ToolKt.isExpandedMcpToolName(name: toolName)
    }

    func isAdvancedToolEnabled(_ toolName: String) -> Bool {
        switch toolName {
        case "mcp_list", "mcp_describe_tool", "mcp_import_from_skill":
            true
        case let name where IOSAppleAgentToolCatalog.toolNames.contains(name):
            IOSCapabilityRegistry.capability(forToolName: name).map { isCapabilityPolicyEnabled($0.id) } ?? false
        case "mcp_call", "mcp_test":
            isMcpNetworkAllowed()
        case let name where ToolKt.isExpandedMcpToolName(name: name):
            isMcpNetworkAllowed()
        case IOSSoulToolCatalog.toolName:
            true
        case "skills_list", "use_skill", "skill_validate", "skill_import", "skill_enable", "skill_disable":
            true
        case let name where IOSRecipeToolCatalog.toolNames.contains(name):
            true
        case let name where IOSPluginToolCatalog.toolNames.contains(name):
            true
        case let name where IOSDynamicToolRegistry.isDynamicWorkflowToolName(name):
            true
        case "subagent_dispatch":
            isCapabilityPolicyEnabled("ios.agent.subagent_dispatch")
        case "model_council_run":
            isCapabilityPolicyEnabled("ios.agent.model_council_run")
        case "spawn_agent", "list_agents", "interrupt_agent", "send_message", "followup_task", "wait_agent":
            // P1-c/P1-d: 编排工具非常驻、不加新设置项——与 mcp 一样恒可用
            // （暴露与否由 tool_search 的 deferred 池决定）。
            true
        case let name where IOSProviderConfigToolCatalog.toolNames.contains(name):
            // Provider 配置：无独立 capability 开关；写路径靠审批 + 前台限制。
            true
        case let name where IOSThemePackToolCatalog.toolNames.contains(name):
            true
        case "exec":
            // P3-a: 与声明侧同源 gate。开关关时（理论上调用到不了这里，因为
            // pendingAdvancedToolCall 不收 exec）诚实拒绝而非静默执行。
            effectiveExecJavaScriptEnabled
        case "wait":
            // P3-c: 与 exec 同开关（cell 续取工具没有独立设置项）。
            effectiveExecJavaScriptEnabled
        default:
            false
        }
    }

    func isCapabilityPolicyEnabled(_ capabilityId: String) -> Bool {
        if let snapshot = IOSExecutionPolicyContext.snapshot,
           let capability = IOSCapabilityRegistry.capabilities.first(where: { $0.id == capabilityId }) {
            return snapshot.policy(for: capability) != .disabled
        }
        guard let localToolExecutor else { return true }
        return localToolExecutor.permissionPolicy(capabilityId: capabilityId) != .disabled
    }

    var requiresCouncilApproval: Bool {
        let capabilityId = "ios.agent.model_council_run"
        let policy: IOSAgentPermissionPolicy?
        if let snapshot = IOSExecutionPolicyContext.snapshot,
           let capability = IOSCapabilityRegistry.capabilities.first(where: { $0.id == capabilityId }) {
            policy = snapshot.policy(for: capability)
        } else {
            policy = localToolExecutor?.permissionPolicy(capabilityId: capabilityId)
        }
        return Self.councilRequiresApproval(
            policy: policy,
            globalAutoApprove: effectiveGlobalAutoApproveEnabled,
            highRiskAutoApprove: effectiveHighRiskAutoApproveEnabled
        )
    }

    /// 议会是"询问"类能力：任一全局自动批准开关开启时直接执行，与 Skill/MCP 配置写入同口径。
    static func councilRequiresApproval(
        policy: IOSAgentPermissionPolicy?,
        globalAutoApprove: Bool,
        highRiskAutoApprove: Bool
    ) -> Bool {
        guard let policy, !globalAutoApprove, !highRiskAutoApprove else {
            return false
        }
        return policy == .askEveryTime || policy == .allowOncePerRun
    }

}
