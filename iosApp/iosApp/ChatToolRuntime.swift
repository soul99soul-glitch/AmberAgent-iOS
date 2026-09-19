import Foundation
@preconcurrency import Shared

func chatToolCallKey(_ toolCall: UIMessagePart.Tool) -> String {
    let id = toolCall.toolCallId.trimmingCharacters(in: .whitespacesAndNewlines)
    if !id.isEmpty { return id }
    return "\(toolCall.toolName):\(toolCall.input)"
}

/// P3-b: runs one nested tool call from inside an `exec` evaluation through
/// the same top-level execution path (same `ChatToolRuntime` dispatch with
/// its approval pause/resume, same ledger Started/Finished pair). Implemented
/// by `ChatRunKernelAdapter` (it owns the ledger and approval decisions);
/// `ChatToolRuntime` only threads it into the sandbox's synchronous
/// `tools` bridge.
typealias IosExecNestedToolRunner = @MainActor (String, String) async -> String

private enum IOSExecutionPolicyContext {
    @TaskLocal static var snapshot: IOSExecutionPolicySnapshot?
}

/// Only an interrupted in-flight action is terminal. A dispatched or ambiguous
/// result stays in the model loop so WebMount can re-observe before continuing.
private func isWebMountInterruptedOutcome(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    return object["status"] as? String == "unknown_after_action"
        && object["may_have_applied"] as? Bool == true
}

private final class IOSClosureToolExecutor: IOSToolExecutor {
    private let handler: @MainActor (String, String, Bool) async -> IOSAgentToolOutcome
    private let executionPolicy: IOSExecutionPolicySnapshot?

    init(
        executionPolicy: IOSExecutionPolicySnapshot? = IOSExecutionPolicyContext.snapshot,
        _ handler: @escaping @MainActor (String, String, Bool) async -> IOSAgentToolOutcome
    ) {
        self.handler = handler
        self.executionPolicy = executionPolicy
    }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        await IOSExecutionPolicyContext.$snapshot.withValue(executionPolicy) {
            await handler(name, arguments, isUserInitiated)
        }
    }
}

private extension IOSLocalToolExecutionOutput {
    var isSuccessfulToolResult: Bool {
        switch self {
        case .selectedFilePreview, .permissionsStatus, .terminalResult, .ishExecuteResult, .ishHandoffResult, .workspaceResult, .webMountResult:
            true
        case .needsUserAction, .denied, .failed:
            false
        }
    }

    var isWebMountOutcomeUnknown: Bool {
        guard case .webMountResult(let text) = self else { return false }
        return isWebMountInterruptedOutcome(text)
    }
}

enum ChatPendingToolKind {
    case toolSearch
    case search
    case workspace
    case ish
    case webMount
    case memory
    case image
    case advanced
    case askUser
    /// 跨会话读取工具（session_search/session_read）：本地只读，无审批，照
    /// tool_search/tools_list 模式独立成类（进 advanced 会因分类侧副作用违约）。
    case sessionRead
    /// runtime_status：本地运行时自省（Jev 模式/凭据存在性/门控/目录计数），
    /// 只读无副作用，照 sessionRead 先例独立成类。
    case runtimeStatus
}

/// P2-a: 记忆污染置位的工具名判定（harness 拥有，不经模型）。只含明确外部上下文
/// 来源：web 搜索 / 网页读取 / MCP 直调与 `mcp__*` 展开。`wm_*` 读内网也读外网，
/// 误标会扩大停抽范围，待有 URL 分类后再纳入（AGENT_ORCHESTRATION_ADOPTION_PLAN
/// P2.5）。与 Android 侧常量集合保持一致，避免双轨漂移。
enum ConversationMemoryPollutionPolicy {
    static let pollutingToolNames: Set<String> = ["search_web", "scrape_web", "mcp_call"]

    static func isPollutingToolName(_ name: String) -> Bool {
        pollutingToolNames.contains(name) || name.hasPrefix("mcp__")
    }

    /// Whether a successful tool output should mark the conversation polluted.
    /// Provider key writes are secrets entering the agent loop even when the
    /// model never sees the key material again.
    static func shouldMarkPolluted(toolName: String, outputText: String) -> Bool {
        if isPollutingToolName(toolName) { return true }
        guard toolName == "provider_config_apply" else { return false }
        guard let data = outputText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true else {
            return false
        }
        let status = (obj["api_key_status"] as? String) ?? ""
        return status == "updated" || status == "cleared"
    }
}

struct ChatPendingToolCall {
    let kind: ChatPendingToolKind
    let toolCall: UIMessagePart.Tool
}

// MARK: - Wave B2: recipe execution state (mutation-step approval pause)

/// Outcome of one `advanceRecipeExecution` sweep.
private enum RecipeAdvanceOutcome {
    /// The recipe call reached a terminal (success, structured failure or
    /// denied-stop) — the messages carry the final tool output.
    case completed([UIMessage])
    /// A mutation step needs user approval; the execution state is stashed
    /// and the checkpoint persisted.
    case needsApproval(RecipeToolApprovalRequest)
    /// A step side effect returned, but its own durable terminal did not.
    case durabilityFailure(String)
    /// A step was dispatched but its outcome cannot be inferred.
    case outcomeUnknown([UIMessage])
}

/// Result of the recipe step approval finisher.
enum RecipeApprovalFinishResult {
    /// The recipe call reached a terminal — messages carry the final output.
    case completed([UIMessage])
    /// The approved step ran and a LATER mutation step needs another card.
    case pausedForNextStep(RecipeToolApprovalRequest)
    case durabilityFailure(String)
    case outcomeUnknown([UIMessage])
}

/// Per-step approval gate verdict.
private enum RecipeStepGate {
    case proceed
    case approvalRequired(reason: String)
    case unsupported(reason: String)
}

/// One post-gate step execution result.
private enum RecipePrimitiveStepResult {
    case output(String)
    case failure(String)
    case needsApproval(reason: String)
    case outcomeUnknown(String)
}

private enum IOSPluginRuntimeError: LocalizedError {
    case invalidRemoteDefinition
    case requestTooLarge
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRemoteDefinition: "远端处理器定义无效。"
        case .requestTooLarge: "远端请求体超过 256 KiB。"
        case .httpStatus(let code): "远端返回 HTTP \(code)。"
        }
    }
}

private struct IOSPluginHostCallFailure: Sendable {
    let reason: String
    let mayHaveApplied: Bool
}

private final class IOSPluginHostCallState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var storedFailure: IOSPluginHostCallFailure?

    func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    func fail(_ reason: String, mayHaveApplied: Bool = false) {
        lock.lock()
        if storedFailure == nil {
            storedFailure = IOSPluginHostCallFailure(reason: reason, mayHaveApplied: mayHaveApplied)
        }
        lock.unlock()
    }

    func snapshot() -> (started: Bool, failure: IOSPluginHostCallFailure?) {
        lock.lock()
        defer { lock.unlock() }
        return (started, storedFailure)
    }
}

/// In-flight execution state of one `recipe__*` call. Lives in
/// `ChatToolRuntime.preparedRecipeExecutions` keyed by the model's toolCallId
/// while the call is paused for a mutation-step approval; a JSON mirror is
/// persisted to the checkpoint store BEFORE the durable pause (W1 discipline:
/// the resume contract exists on disk before the card is shown). The manifest
/// comes from the round's registry snapshot, so the paused execution is pinned
/// to the version the model saw (§13.3) even if a promotion happens while the
/// card is open.
struct IOSRecipeExecutionState {
    let toolCallId: String
    let executionId: String
    let recipeName: String
    let recipeVersion: String
    /// Present only when this recipe is a handler inside an installed plugin.
    /// Kept with the pinned manifest so terminal health attribution cannot
    /// drift to a newer package revision while an approval is open.
    let pluginId: String?
    let pluginPackageHash: String?
    let capabilityBroker: IOSPluginCapabilityBroker?
    let catalogRevision: Int64?
    let manifest: IOSRecipeManifest
    let plan: IOSRecipeExecutionPlan
    let inputs: [String: IOSRecipeJSONValue]
    var stepOutputs: [String: String]
    var completedSteps: [String]
    var nextStepIndex: Int
    var candidateTest: IOSPluginTestContext? = nil

    func checkpoint() -> IOSRecipeExecutionCheckpoint {
        IOSRecipeExecutionCheckpoint(
            schemaVersion: IOSRecipeExecutionCheckpointStore.schemaVersion,
            toolCallId: toolCallId,
            recipeName: recipeName,
            recipeVersion: recipeVersion,
            catalogRevision: catalogRevision,
            inputs: inputs,
            stepOutputs: stepOutputs,
            completedSteps: completedSteps,
            nextStepIndex: nextStepIndex,
            executionId: executionId
        )
    }
}

/// Pinned non-Recipe plugin handler held while its execution approval card is
/// visible. The original arguments remain in `ChatPendingToolApproval`; this
/// descriptor keeps execution on the exact package revision the model saw.
struct IOSPreparedPluginInvocation: Equatable, Sendable {
    let descriptor: IOSDynamicRecipeToolDescriptor
    var argumentsJSON: String? = nil
    var candidateTest: IOSPluginTestContext? = nil
}

enum ChatToolApprovalPrompt {
    case memory(MemoryToolApprovalRequest)
    case search(SearchToolApprovalRequest)
    case webMount(WebMountToolApprovalRequest)
    case workspace(WorkspaceToolApprovalRequest)
    case ish(IshHandoffToolApprovalRequest)
    case mcp(McpToolApprovalRequest)
    case council(CouncilToolApprovalRequest)
    case askUser(ChatAskUserRequest)
    /// Wave B2: recipe surface — a mutation STEP of an in-flight
    /// `recipe__*` call, or a `recipe_import` promotion (§10.3.5 / §13.1).
    case recipe(RecipeToolApprovalRequest)

    var toolTitle: String {
        switch self {
        case .memory:
            "记忆写入"
        case .search(let request):
            request.toolName == "scrape_web" ? "网页读取" : "网络搜索"
        case .webMount:
            "WebMount"
        case .workspace:
            "Workspace"
        case .ish(let request):
            request.title
        case .mcp:
            "MCP 工具"
        case .council(let request):
            request.title
        case .askUser:
            "需要你的回答"
        case .recipe(let request):
            request.title
        }
    }

    var activityKind: AgentActivityKind {
        switch self {
        case .memory:
            .memory
        case .search(let request):
            request.toolName == "scrape_web" ? .web : .research
        case .webMount:
            .web
        case .workspace:
            .document
        case .ish:
            .command
        case .mcp, .council, .askUser, .recipe:
            .workflow
        }
    }
}

enum ChatToolRuntimeResult {
    case completed([UIMessage])
    case waitingForApproval(ChatToolApprovalPrompt)
    case durabilityFailure(String)
    case outcomeUnknown([UIMessage])
}

private enum ChatCodexImageConfig {
    case signedIn(providerId: String, modelId: String, preferredRoutingModelID: String?)
    case notSignedIn
    case notSelected
}

@MainActor
final class ChatToolRuntime {
    private let settingsStore: SettingsStore
    private let sharedSettings: IOSSharedSettingsStore
    private let localToolExecutor: IOSLocalToolExecutor?
    private let searchTransport: any IOSSearchHTTPTransport
    private let mcpManager: IOSMcpManager
    private let skillFileStore: IOSSkillFileStore
    private let workspaceStore: IOSWorkspaceStore
    /// §15 Phase 0: approval-denial ledger events (§11.1 evidence source).
    /// Optional — nil keeps every existing construction site (tests included)
    /// on the pre-contract behavior; the chat coordinator wires its real
    /// ledger here so user denials become durable, attributable facts.
    private let ledger: IOSAgentRunLedgering?
    /// `skill_import` 的获批应用上下文只在本次进程内、按 toolCallId 暂存。
    /// Coordinator 接住审批卡时立即取走；冷启动不会恢复或静默应用候选包。
    private var preparedSkillImportsForApproval: [String: IOSPreparedSkillImport] = [:]
    private var preparedSoulImportsForApproval: [String: IOSPreparedSoulImport] = [:]
    private var preparedMcpImportsForApproval: [String: IOSPreparedMcpImport] = [:]
    /// Wave B2: `recipe_import` 的获批应用上下文，与 skill_import 同生命周期
    /// （仅内存、按 toolCallId、冷启动不恢复）。
    private var preparedRecipeImportsForApproval: [String: IOSPreparedRecipeImport] = [:]
    private var preparedPluginImportsForApproval: [String: IOSPreparedPluginImport] = [:]
    private var preparedPluginInvocationsForApproval: [String: IOSPreparedPluginInvocation] = [:]
    /// Wave B2: 暂停在 mutation step 审批处的 `recipe__*` 执行状态（含已
    /// 完成 steps 的输出与下一 step 索引）。暂停前先持久化 checkpoint，恢复
    /// 走 finisher，不经过模型循环。
    private var preparedRecipeExecutions: [String: IOSRecipeExecutionState] = [:]
    /// Wave B2: recipe store 的基目录（nil = documents，与 registry 同源）。
    /// 也用于 checkpoint 落盘（`recipes/.checkpoints/`）。
    private let recipeStoreBaseDirectory: URL?
    /// Registry over the same store root. Tests with an isolated root must not
    /// accidentally publish lifecycle changes into the app-global registry.
    private let recipeRegistry: IOSDynamicToolRegistry
    private let mcpConfigStore: IOSMcpConfigStore
    /// P1-c: 线程编排工具执行体（spawn_agent/list_agents/interrupt_agent）。
    /// 可选：未注入时三工具返回结构化「不可用」错误而不是静默缺失。
    private let orchestrationToolService: IOSThreadOrchestrationToolService?
    /// 小说讨论写工具的领域入口（weak：AppShell 先构造本 runtime 再构造
    /// DefaultNovelCreation，由 NovelCreationComposition 回填；weak 保证
    /// runtime ↔ creation 不形成引用环）。nil 时讨论引擎不注册小说写工具。
    weak var novelProjectCreation: DefaultNovelCreation?
    /// 跨会话读取工具（session_search/session_read）的会话存储源。可选：
    /// 未注入时两工具返回结构化「不可用」错误（照 orchestrationToolService 先例；
    /// 测试注入隔离 store）。
    private let conversationStoreProvider: (() -> IOSConversationStore?)?
    /// P2-a: harness 拥有的记忆污染置位回调（conversationId, toolName）。由接线方
    /// 注入持久化（storage 写 + baseline 守卫）；nil = 不置位（零行为变化）。置位
    /// 判定（工具名 + 成功输出）在本 runtime 收口处完成，不经过模型。
    private let memoryPollutionMarker: ((KotlinUuid, String) -> Void)?
    /// 当前进程内的终端 session 授权按能力隔离，不落盘；global run scope
    /// 只用于桥接本轮已冻结的 execution-policy snapshot。
    private var ishAutoApprovedConversationCapabilities: Set<String> = []
    private var ishAutoApprovedRunCapabilities: Set<String> = []
    private var ishAutoApprovedRunIds: Set<String> = []
    private lazy var subAgentRunner = SubAgentRunner()
    /// Legacy `subagent_dispatch` shares the same pool selection and
    /// reservation semantics as thread orchestration. Its provider/model count
    /// view is process-local because the runner predates BackgroundScheduling.
    private let subAgentModelPool = IOSSubAgentModelPool()
    private var activeLegacySubAgentRuns = 0
    private var activeLegacyModelCounts: [String: Int] = [:]
    private var activeLegacyProviderCounts: [String: Int] = [:]
    private lazy var councilRunner = CouncilRunner()
    /// Agent 自配置 provider/model（SharedSettings 真源；密钥永不进 tool result）。
    private lazy var providerConfigToolService = IOSProviderConfigToolService(
        sharedSettings: sharedSettings
    )
    private lazy var themePackToolService = IOSThemePackToolService()
    /// P3-a: JavaScriptCore 沙箱引擎（exec 纯求值）。每次求值独立 context +
    /// 独立串行队列；超时 abandon 语义见 IOSJsSandboxEngine。
    private lazy var jsSandboxEngine = IOSJsSandboxEngine()
    /// P3-c: 会话级 cell 注册表（exec cell + store/load KV 的唯一 owner，
    /// 跨 run 共享）。默认生产单例；测试注入隔离实例。
    private let jsCellRegistry: IOSJsCellRegistry
    private let soulPreviousStore: IOSSoulPreviousStore
    private let mcpImportClientFactory: ((IOSMcpServerConfig) -> any IOSMcpClienting)?
    private lazy var skillMcpToolService = IOSSkillMcpToolService(
        skillStore: skillFileStore,
        sharedSettings: sharedSettings,
        workspaceStore: workspaceStore,
        mcpConfigStore: mcpConfigStore,
        mcpManager: mcpManager,
        ephemeralClientFactory: mcpImportClientFactory
    )
    private lazy var soulService = IOSSoulService(
        workspaceStore: workspaceStore,
        sharedSettings: sharedSettings,
        previousStore: soulPreviousStore
    )
    /// Wave B2: `recipe_import` 服务（preview → 批准 → CAS apply → registry
    /// refresh）。recipe store 基目录与 registry 同源（nil = documents）。
    private let recipeToolService: IOSRecipeToolService
    private let pluginToolService: IOSPluginToolService
    private let pluginHealthStore: IOSPluginHealthStore
    /// Wave B2: checkpoint 落盘（`<base>/recipes/.checkpoints/`）。
    private let recipeExecutionCheckpointStore: IOSRecipeExecutionCheckpointStore

    private var effectiveGlobalAutoApproveEnabled: Bool {
        IOSExecutionPolicyContext.snapshot?.globalAutoApproveEnabled
            ?? IOSLocalToolExecutor.isGlobalAutoApproveEnabled
    }

    private var effectiveHighRiskAutoApproveEnabled: Bool {
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

    private func isIshAutoApproved(
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

    private func isIshToolAutoApproved(
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

    private var effectiveExecJavaScriptEnabled: Bool {
        IOSExecutionPolicyContext.snapshot?.execJavaScriptEnabled
            ?? settingsStore.execJavaScriptEnabled
    }

    private var effectiveWebSearchEnabled: Bool {
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
        mcpImportClientFactory: ((IOSMcpServerConfig) -> any IOSMcpClienting)? = nil
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
        self.recipeExecutionCheckpointStore = IOSRecipeExecutionCheckpointStore(
            baseDirectory: resolvedRecipeBaseDirectory,
            fileManager: .default
        )
        self.soulPreviousStore = soulPreviousStore ?? IOSSoulPreviousStore()
        self.mcpImportClientFactory = mcpImportClientFactory
    }

    /// 把只读 preview 对应的 CAS 上下文交给 Coordinator 的 pending MCP 槽。
    /// 取走即删除，避免批准恢复时重复消费同一个候选。
    func takePreparedSkillImportForApproval(toolCallId: String) -> IOSPreparedSkillImport? {
        preparedSkillImportsForApproval.removeValue(forKey: toolCallId)
    }

    func discardPreparedSkillImportForApproval(toolCallId: String) {
        preparedSkillImportsForApproval.removeValue(forKey: toolCallId)
        preparedSoulImportsForApproval.removeValue(forKey: toolCallId)
        preparedMcpImportsForApproval.removeValue(forKey: toolCallId)
    }

    func discardPreparedThemeImport() {
        themePackToolService.discardPreparedImport()
    }

    func takePreparedSoulImportForApproval(toolCallId: String) -> IOSPreparedSoulImport? {
        preparedSoulImportsForApproval.removeValue(forKey: toolCallId)
    }

    func takePreparedMcpImportForApproval(toolCallId: String) -> IOSPreparedMcpImport? {
        preparedMcpImportsForApproval.removeValue(forKey: toolCallId)
    }

    /// Wave B2: `recipe_import` 的批准上下文（与 skill_import 同模式）。
    func takePreparedRecipeImportForApproval(toolCallId: String) -> IOSPreparedRecipeImport? {
        preparedRecipeImportsForApproval.removeValue(forKey: toolCallId)
    }

    func discardPreparedRecipeImportForApproval(toolCallId: String) {
        preparedRecipeImportsForApproval.removeValue(forKey: toolCallId)
        preparedPluginImportsForApproval.removeValue(forKey: toolCallId)
    }

    func takePreparedPluginImportForApproval(toolCallId: String) -> IOSPreparedPluginImport? {
        preparedPluginImportsForApproval.removeValue(forKey: toolCallId)
    }

    func takePreparedPluginInvocationForApproval(toolCallId: String) -> IOSPreparedPluginInvocation? {
        preparedPluginInvocationsForApproval.removeValue(forKey: toolCallId)
    }

    func discardPreparedPluginInvocationForApproval(toolCallId: String) {
        preparedPluginInvocationsForApproval.removeValue(forKey: toolCallId)
    }

    /// Wave B2: 暂停中的 `recipe__*` 执行状态。Coordinator 接住审批卡时取走；
    /// 冷启动/取消/run 替换都会丢弃（同时清 checkpoint），绝不跨 run 复用。
    func takePreparedRecipeExecution(toolCallId: String) -> IOSRecipeExecutionState? {
        preparedRecipeExecutions.removeValue(forKey: toolCallId)
    }

    func discardPreparedRecipeExecution(toolCallId: String) {
        preparedRecipeExecutions.removeValue(forKey: toolCallId)
        recipeExecutionCheckpointStore.remove(toolCallId: toolCallId)
    }

    /// Tool set for the novel discussion agent. Ask User is always available;
    /// search continues to respect the global Web Search consent switch. The
    /// novel project write tools are registered only when a per-run project
    /// context is provided (discussion runs started by the novel lifecycle),
    /// regardless of the web-search switch.
    func novelDiscussionToolExecutors(
        projectContext: NovelProjectToolRunContext? = nil
    ) -> [String: any IOSToolExecutor] {
        var executors: [String: any IOSToolExecutor] = [
            "ask_user": IOSClosureToolExecutor { _, _, _ in
                .needsApproval("等待用户回答")
            }
        ]
        if let projectContext {
            let projectExecutor = IOSNovelProjectToolExecutor(
                projectContext: projectContext,
                creation: novelProjectCreation
            )
            for name in IOSNovelProjectToolExecutor.supportedToolNames {
                executors[name] = projectExecutor
            }
        }
        guard effectiveWebSearchEnabled else { return executors }
        for name in IOSSearchExecutor.supportedToolNames {
            executors[name] = IOSClosureToolExecutor { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                let call = self.toolCall(name: toolName, input: arguments)
                return .filled(await self.dispatchSearchToolCall(call))
            }
        }
        return executors
    }

    func backgroundToolExecutors(
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        toolExposureBridge: IosToolExposureBridge? = nil,
        conversationId: KotlinUuid? = nil,
        /// Job-frozen display messages for generate_image pad-image enrich.
        /// Must be the snapshot that owns this tool call — not a live store read.
        messages: [UIMessage] = [],
        executionPolicy: IOSExecutionPolicySnapshot? = nil,
        dynamicToolSnapshot: IOSDynamicToolCatalogSnapshot? = nil
    ) -> [String: any IOSToolExecutor] {
        backgroundToolExecutorsWithCurrentPolicy(
            providerSetting: providerSetting,
            params: params,
            runId: runId,
            toolExposureBridge: toolExposureBridge,
            conversationId: conversationId,
            messages: messages,
            executionPolicy: executionPolicy,
            dynamicToolSnapshot: dynamicToolSnapshot
        )
    }

    private func backgroundToolExecutorsWithCurrentPolicy(
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        toolExposureBridge: IosToolExposureBridge?,
        conversationId: KotlinUuid?,
        messages: [UIMessage],
        executionPolicy: IOSExecutionPolicySnapshot?,
        dynamicToolSnapshot: IOSDynamicToolCatalogSnapshot?
    ) -> [String: any IOSToolExecutor] {
        var executors: [String: any IOSToolExecutor] = [:]
        let availableToolNames = Set(params.tools.map(\.name))

        // P0-a: tool_search is a local discovery call, safe in background. The
        // background job owns its own bridge instance (rebuilt from the handoff
        // declarations with exposure reset — the foreground's expanded hits are
        // not transferred). IOSAgentToolEngine re-derives params from the same
        // bridge after every batch (Fix C), so hits expanded inside a
        // background round become callable on the next background round.
        if availableToolNames.contains("tool_search") {
            executors["tool_search"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, arguments, _ in
                guard let bridge = toolExposureBridge else {
                    return .failed("tool_search is unavailable in this run.")
                }
                // Jev Phase 1：后台与前台共用语义发现服务（off 零网络）。
                let output = await IOSJevToolDiscoveryService.execute(
                    argumentsJson: arguments,
                    bridge: bridge,
                    identity: IOSJevToolDiscoveryService.RunIdentity(
                        runId: runId,
                        turnBudgetKey: IOSJevToolDiscoveryService.turnBudgetKey(runId: runId)
                    )
                )
                return .filled(output)
            }
        }
        // M5: tools_list 与 tool_search 同属本地目录调用（discovery 引导引用它）——
        // 后台安全，注册为桥的本地执行（返回全目录 {name, description} 清单）。
        if availableToolNames.contains("tools_list") {
            executors["tools_list"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, _, _ in
                guard let bridge = toolExposureBridge else {
                    return .failed("tools_list is unavailable in this run.")
                }
                return .filled(bridge.executeToolsList())
            }
        }

        // Dynamic plugins are background-capable only when the exact
        // process-local snapshot opted in and the handler is declarative or
        // remote read-only. Restricted JS, side effects, Shell/Python/iSH and
        // cold-restored name-only payloads never enter this table.
        for descriptor in dynamicToolSnapshot?.backgroundEligibleDescriptors ?? []
        where availableToolNames.contains(descriptor.toolId) {
            executors[descriptor.toolId] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] _, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                return await self.executeBackgroundPlugin(
                    descriptor: descriptor,
                    argumentsJSON: arguments,
                    providerSetting: providerSetting,
                    params: params,
                    runId: runId,
                    conversationId: conversationId,
                    bridge: toolExposureBridge,
                    executionPolicy: executionPolicy
                )
            }
        }

        for name in IOSSearchExecutor.supportedToolNames where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                guard self.shouldExecuteSearchInBackground(toolName: toolName, arguments: arguments) else {
                    return .denied("后台生成期间需要回到 App 确认网络搜索或网页读取。")
                }
                let result = await self.dispatchSearchToolCall(self.toolCall(name: toolName, input: arguments))
                // P2-a: 后台 run 标记到 run 锚定会话（conversationId 由 job 传入），
                // 不得标到前台当前会话。
                self.markMemoryPollutionIfNeeded(
                    toolName: toolName,
                    outputText: result,
                    conversationId: conversationId
                )
                return .filled(result)
            }
        }

        if localToolExecutor != nil {
            for name in IOSWorkspaceToolCatalog.supportedToolNames where availableToolNames.contains(name) {
                executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                    guard let self else { return .failed("Chat runtime is unavailable.") }
                    let toolCall = self.toolCall(name: toolName, input: arguments)
                    let output = await self.workspaceToolExecutionOutput(toolCall, isUserInitiated: false)
                    if case .needsUserAction(let reason) = output {
                        return .denied("后台生成期间需要回到 App 确认 Workspace 操作：\(reason)")
                    }
                    return .filled(ChatToolOutputFormatter.workspaceResultText(for: toolCall, output: output))
                }
            }

            for name in IOSAgentTerminalToolCatalog.supportedToolNames
            where availableToolNames.contains(name) {
                executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                    guard let self else { return .failed("Chat runtime is unavailable.") }
                    let toolCall = self.toolCall(name: toolName, input: arguments)
                    let output = await self.ishToolExecutionOutput(
                        toolCall,
                        isUserInitiated: self.isIshAutoApproved(
                            toolName: toolName,
                            input: arguments,
                            runId: runId,
                            conversationId: conversationId
                        )
                    )
                    if case .needsUserAction(let reason) = output {
                        return .denied("后台生成期间需要回到 App 确认终端操作：\(reason)")
                    }
                    return .filled(ChatToolOutputFormatter.ishHandoffResultText(for: toolCall, output: output))
                }
            }
        }

        if isWebMountRuntimeEnabled {
            for name in IOSWebMountToolCatalog.supportedToolNames.union(IOSWebMountToolCatalog.unsupportedToolNames)
            where availableToolNames.contains(name) {
                executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                    guard let self else { return .failed("Chat runtime is unavailable.") }
                    let toolCall = self.toolCall(name: toolName, input: arguments)
                    let output = await self.webMountToolExecutionOutput(
                        toolCall,
                        isUserInitiated: false,
                        runId: runId,
                        conversationId: conversationId
                    )
                    if case .needsUserAction(let reason) = output {
                        return .denied("后台生成期间需要回到 App 确认 WebMount 操作：\(reason)")
                    }
                    let resultText = ChatToolOutputFormatter.webMountResultText(for: toolCall, output: output)
                    if output.isWebMountOutcomeUnknown {
                        return .outcomeUnknown([UIMessagePart.Text(text: resultText, metadata: nil)])
                    }
                    return .filled(resultText)
                }
            }
        }

        if availableToolNames.contains("memory_tool") {
            executors["memory_tool"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] _, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                let policy = self.memoryToolWritePolicy(input: arguments, isUserInitiated: false)
                if case .needsUserAction(let reason) = policy {
                    return .denied("后台生成期间需要回到 App 确认记忆写入：\(reason)")
                }
                return .filled(self.dispatchMemoryToolCall(self.toolCall(name: "memory_tool", input: arguments), writePolicy: policy))
            }
        }

        if availableToolNames.contains("generate_image") {
            let enrichMessages = messages
            executors["generate_image"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] _, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                return .filledParts(
                    await self.dispatchImageToolCall(
                        self.toolCall(name: "generate_image", input: arguments),
                        messages: enrichMessages
                    )
                )
            }
        }

        // Advanced tools in background. The foreground approval UI cannot surface
        // during a BGContinuedProcessingTask, so:
        //  - subagent_dispatch: orchestration may run when enabled. The worker is
        //    read-only and every nested tool keeps its own permission boundary.
        //  - mcp_call: high-risk (external/remote), mirrors the foreground gate —
        //    only runs when the high-risk auto-approve switch is on, otherwise
        //    denied so the user returns to the app to confirm.
        //  - model_council_run: DENIED in background. A council run is a long,
        //    multi-seat/multi-round streaming sequence (many sequential HTTP calls,
        //    potentially tens of minutes) that occupies a single executor step. The
        //    BGTask expirationHandler cannot interrupt an in-flight streamText, so a
        //    background council would overrun the BGTask window and be force-killed,
        //    leaving an incomplete run. It also drives the council-room @Observable
        //    UI, which has no subscriber in background. Revert to foreground.
        if availableToolNames.contains("subagent_dispatch") {
            executors["subagent_dispatch"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                let toolCall = self.toolCall(name: toolName, input: arguments)
                guard self.isAdvancedToolEnabled(toolName) else {
                    return .failed("\(toolName) 未开启。请先在设置中启用对应能力。")
                }
                let result = await self.dispatchAdvancedToolCall(
                    toolCall,
                    providerSetting: providerSetting,
                    params: params,
                    runId: runId,
                    conversationId: conversationId
                )
                return .filled(result)
            }
        }

        if availableToolNames.contains("model_council_run") {
            executors["model_council_run"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, _, _ in
                .denied("模型委员会运行时间较长且依赖前台房间界面，请回到 App 内执行。")
            }
        }

        if availableToolNames.contains(IOSWeatherToolCatalog.toolName) {
            executors[IOSWeatherToolCatalog.toolName] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, arguments, _ in
                guard !IOSWeatherToolExecutor.requestsCurrentLocation(input: arguments) else {
                    return .denied("后台生成期间不能申请当前位置，请回到 App 内使用天气工具。")
                }
                return .filled(await IOSWeatherToolExecutor.execute(input: arguments))
            }
        }
        if availableToolNames.contains(IOSAppleAgentToolCatalog.workoutPlanPreview) {
            executors[IOSAppleAgentToolCatalog.workoutPlanPreview] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { name, arguments, _ in
                .filled(await IOSWorkoutAgentToolExecutor.execute(toolName: name, input: arguments))
            }
        }
        for name in IOSAppleAgentToolCatalog.approvalRequiredToolNames
        where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, _, _ in
                .denied("Apple 健康、日历、提醒事项、通知与闹钟工具需要回到 App 前台确认。")
            }
        }
        for name in IOSAppleAgentToolCatalog.pickerToolNames
        where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, _, _ in
                .denied("个人资料选取需要回到 App 前台使用系统选择器。")
            }
        }
        // ask_user is a foreground HITL node. Background cannot present the card or
        // Watch decision, so deny with an explicit return-to-app reason instead of
        // leaving the tool unregistered (engine would otherwise error-fill and continue).
        if availableToolNames.contains("ask_user") {
            executors["ask_user"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, _, _ in
                .denied("后台生成期间需要回到 App 回答问题。")
            }
        }

        if availableToolNames.contains("mcp_call") {
            executors["mcp_call"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                // High-risk gate mirrors the foreground path (executeAdvancedToolCall):
                // MCP may touch external services, so only auto-run when the high-risk
                // auto-approve switch is on. Otherwise deny so the user returns to confirm.
                guard self.effectiveHighRiskAutoApproveEnabled else {
                    return .denied("后台生成期间需要回到 App 确认 MCP 工具。")
                }
                guard self.isAdvancedToolEnabled(toolName) else {
                    return .failed("\(toolName) 未开启。请先在设置中启用对应能力。")
                }
                let result = await self.dispatchAdvancedToolCall(
                    self.toolCall(name: toolName, input: arguments),
                    providerSetting: providerSetting,
                    params: params,
                    runId: runId,
                    conversationId: conversationId
                )
                // P2-a: 后台 run 标记到 run 锚定会话。
                self.markMemoryPollutionIfNeeded(
                    toolName: toolName,
                    outputText: result,
                    conversationId: conversationId
                )
                return .filled(result)
            }
        }

        // P0-b: flattened `mcp__*` tools mirror the mcp_call background gate
        // (high-risk auto-approve required; same dispatch path). Only names
        // visible in the current round's params are registered.
        for tool in params.tools where ToolKt.isExpandedMcpToolName(name: tool.name) {
            let expandedName = tool.name
            executors[expandedName] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                guard self.effectiveHighRiskAutoApproveEnabled else {
                    return .denied("后台生成期间需要回到 App 确认 MCP 工具。")
                }
                guard self.isAdvancedToolEnabled(toolName) else {
                    return .failed("\(toolName) 未开启。请先在设置中启用对应能力。")
                }
                let result = await self.dispatchAdvancedToolCall(
                    self.toolCall(name: toolName, input: arguments),
                    providerSetting: providerSetting,
                    params: params,
                    runId: runId,
                    conversationId: conversationId
                )
                // P2-a: 后台 run 标记到 run 锚定会话。
                self.markMemoryPollutionIfNeeded(
                    toolName: toolName,
                    outputText: result,
                    conversationId: conversationId
                )
                return .filled(result)
            }
        }

        let skillMcpNames = IOSSkillToolCatalog.toolNames
            .union(IOSMcpManagementToolCatalog.toolNames)
            .union([IOSSoulToolCatalog.toolName])
        for name in skillMcpNames where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                if Self.isHostPublishTool(toolName) {
                    return await self.backgroundHostPublishOutcome(
                        toolName: toolName,
                        arguments: arguments
                    )
                }
                let mutating = IOSSkillToolCatalog.mutatingToolNames.contains(toolName)
                    || IOSMcpManagementToolCatalog.mutatingToolNames.contains(toolName)
                let highRisk = IOSMcpManagementToolCatalog.highRiskToolNames.contains(toolName)
                let autoApproved = highRisk
                    ? self.effectiveHighRiskAutoApproveEnabled
                    : self.effectiveGlobalAutoApproveEnabled
                        || self.effectiveHighRiskAutoApproveEnabled
                if mutating, !autoApproved {
                    return .denied("后台生成期间需要回到 App 确认 \(toolName)。")
                }
                if IOSMcpManagementToolCatalog.toolNames.contains(toolName),
                   !self.isAdvancedToolEnabled(toolName) {
                    return .failed("\(toolName) 未开启。请先在设置中启用 MCP。")
                }
                let result = await self.dispatchAdvancedToolCall(
                    self.toolCall(name: toolName, input: arguments),
                    providerSetting: providerSetting,
                    params: params,
                    runId: runId,
                    conversationId: conversationId
                )
                return .filled(result)
            }
        }

        // Recipe 管理工具可在后台读取；写操作只有对应自动批准策略已开启时
        // 执行。独立 recipe__* 仍不进入后台目录；显式声明且只读的
        // plugin__* 工具已在上方按固定目录快照注册。
        for name in IOSRecipeToolCatalog.toolNames where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                if Self.isHostPublishTool(toolName) {
                    return await self.backgroundHostPublishOutcome(
                        toolName: toolName,
                        arguments: arguments
                    )
                }
                let mutating = IOSRecipeToolCatalog.mutatingToolNames.contains(toolName)
                let highRisk = IOSRecipeToolCatalog.highRiskToolNames.contains(toolName)
                let autoApproved = highRisk
                    ? self.effectiveHighRiskAutoApproveEnabled
                    : self.effectiveGlobalAutoApproveEnabled || self.effectiveHighRiskAutoApproveEnabled
                if mutating, !autoApproved {
                    return .denied("后台生成期间需要回到 App 确认 \(toolName)。")
                }
                let result = await self.dispatchAdvancedToolCall(
                    self.toolCall(name: toolName, input: arguments),
                    providerSetting: providerSetting,
                    params: params,
                    runId: runId,
                    conversationId: conversationId
                )
                return .filled(result)
            }
        }

        // P1-c/P1-d: 线程编排工具后台注册——子线程在后台引擎里同样可 spawn 孙线程 /
        // list / interrupt / 收发消息 / wait（深度与并发上限由服务内检查兜底）。
        // 与 mcp 先例同：只注册当前轮 params 可见的名字。conversationId = 本 job
        // 的 run 锚定会话（由后台协调器传入），生成中切会话不串到当前会话。
        for name in ["spawn_agent", "list_agents", "interrupt_agent", "send_message", "followup_task", "wait_agent"]
            where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                guard let service = self.orchestrationToolService else {
                    return .failed("线程编排工具当前不可用。")
                }
                let result = await service.execute(
                    toolName: toolName,
                    arguments: arguments,
                    providerSetting: providerSetting,
                    params: params,
                    runId: runId,
                    conversationId: conversationId,
                    // M3: 传 run 的桥——子 run 的 fullToolNames 取全目录而非当轮
                    // 可见子集（闭包捕获的是本 job 的桥实例，全 run 不变）。
                    toolExposureBridge: toolExposureBridge,
                    executionPolicy: IOSExecutionPolicyContext.snapshot
                )
                return .filled(result)
            }
        }

        // 跨会话读取（session_search/session_read）：本地只读、无审批，前后台
        // 同注册（照 tool_search 先例）。只注册当前轮 params 可见的名字。
        for name in ["session_search", "session_read"] where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                return .filled(await self.dispatchSessionReadToolCall(
                    self.toolCall(name: toolName, input: arguments)
                ))
            }
        }

        // runtime_status：本地运行时自省（Jev 模式/凭据存在性/门控/目录计数），
        // 无网络无副作用——前后台同注册（照 session_read 先例）。
        if availableToolNames.contains("runtime_status") {
            executors["runtime_status"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                return .filled(self.dispatchRuntimeStatusToolCall(
                    self.toolCall(name: toolName, input: arguments),
                    toolExposureBridge: toolExposureBridge
                ))
            }
        }

        // Provider/model 配置：后台仅 status（纯读）；写工具拒绝（审批卡只在前台）。
        for name in IOSProviderConfigToolCatalog.toolNames where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                if !IOSProviderConfigToolCatalog.backgroundAllowedToolNames.contains(toolName) {
                    return .denied("provider 配置写入仅前台可用，请回到 App 确认后再试。")
                }
                let result = await self.providerConfigToolService.execute(
                    toolName: toolName,
                    argumentsJSON: arguments
                )
                return .filled(result)
            }
        }

        // Theme pack: background only status (pure read); import needs the try-on card.
        for name in IOSThemePackToolCatalog.toolNames where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                if !IOSThemePackToolCatalog.backgroundAllowedToolNames.contains(toolName) {
                    return .denied("主题试穿仅前台可用，请回到 App 确认后再试。")
                }
                let result = self.themePackToolService.execute(
                    toolName: toolName,
                    argumentsJSON: arguments
                )
                return .filled(result)
            }
        }

        // P3-a: exec 求值——后台 run 也能跑（每次求值独立队列/context，与
        // 前台生命周期无关）。只注册当前轮 params 可见的名字；开关关时声明侧
        // 零痕迹（params 不会含 exec），此处双重门控避免陈旧轮次执行。
        // P3-b: 后台 run 没有协调器级嵌套 runner（账本与审批卡都归前台
        // 协调器），所以 tools 对象按当轮可见集注入白名单、但每个嵌套调用都
        // 报 "tool not available in exec"——诚实拒绝而不是静默缺失。
        // P3-c: 后台 run 同样按会话注册 cell（conversationId 由 job 传入），
        // 前台 yield 的 cell 后台可以 wait，反之亦然——注册表跨 run/前后台共享。
        if availableToolNames.contains("exec") {
            executors["exec"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                guard self.effectiveExecJavaScriptEnabled else {
                    return .failed("exec 未开启。请先在设置中启用 JavaScript 执行工具。")
                }
                let whitelist = ChatToolRuntime.execNestedToolWhitelist(
                    visibleToolNames: availableToolNames
                )
                let nestedTools = IOSJsSandboxTools(
                    availableToolNames: whitelist.sorted(),
                    hostCall: { _, _ in nil },
                    // P3-d: 后台同样注入 ALL_TOOLS 发现元数据——描述来自同一轮
                    // params.tools 声明（与白名单同源）。嵌套调用仍诚实拒绝
                    // （hostCall nil → "tool not available in exec"），但脚本可以
                    // 用 ALL_TOOLS 发现工具名，避免在后续轮次猜名字。
                    toolDescriptions: Self.execToolDescriptions(
                        from: params.tools,
                        whitelist: whitelist
                    )
                )
                return .filled(await self.dispatchExecToolCall(
                    self.toolCall(name: toolName, input: arguments),
                    nestedTools: nestedTools,
                    conversationId: conversationId
                ))
            }
        }
        // P3-c: wait 与 exec 同开关同池——后台 run 可 wait 本会话的 cell。
        if availableToolNames.contains("wait") {
            executors["wait"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                guard self.effectiveExecJavaScriptEnabled else {
                    return .failed("wait 未开启。请先在设置中启用 JavaScript 执行工具。")
                }
                return .filled(await self.dispatchWaitToolCall(
                    self.toolCall(name: toolName, input: arguments),
                    conversationId: conversationId
                ))
            }
        }

        return executors
    }

    // MARK: - P0-2 B2: 前台内核执行器适配

    /// 审批卡暂存盒:引擎执行器回调(nonisolated 上下文)命中 `.waitingForApproval`
    /// 时按 toolCallId 登记 prompt;`ChatRunKernelAdapter` 在引擎返回
    /// `pendingApproval` 后取出、走 bindings 发布。审批请求类型未标 Sendable,
    /// 照 `IOSMailboxDrainResult` 先例用锁 + @unchecked Sendable 跨边界。
    final class IOSForegroundApprovalPromptBox: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String: ChatToolApprovalPrompt] = [:]

        func put(_ toolCallId: String, _ prompt: ChatToolApprovalPrompt) {
            lock.withLock { prompts[toolCallId] = prompt }
        }

        func take(_ toolCallId: String) -> ChatToolApprovalPrompt? {
            lock.withLock { prompts.removeValue(forKey: toolCallId) }
        }
    }

    /// 工具名 → 前台 kind 分类。与 `nextPendingToolCall` 的逐类扫描同源
    /// (各名字集互斥,单名分类与扫描序无关);实例级闸门保持一致:
    /// workspace/ish 需 localToolExecutor,webMount 需运行时开关,exec/wait
    /// 需 execJavaScriptEnabled。全部集合之外的名字返回 nil(= CGC 的
    /// 「未知名」档位,由调用方决定硬失败,不在此伪装成 advanced)。
    func pendingKindForForegroundTool(
        named name: String,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) -> ChatPendingToolKind? {
        if ["tool_search", "tools_list"].contains(name) { return .toolSearch }
        if IOSSearchExecutor.supportedToolNames.contains(name) { return .search }
        if localToolExecutor != nil {
            if IOSWorkspaceToolCatalog.supportedToolNames.contains(name) { return .workspace }
            if IOSAgentTerminalToolCatalog.supportedToolNames.contains(name) { return .ish }
        }
        if isWebMountRuntimeEnabled {
            let webMountNames = IOSWebMountToolCatalog.supportedToolNames
                .union(IOSWebMountToolCatalog.unsupportedToolNames)
            if webMountNames.contains(name) { return .webMount }
        }
        if name == "memory_tool" { return .memory }
        if name == "generate_image" { return .image }
        if name == "ask_user" { return .askUser }
        if ["session_search", "session_read"].contains(name) { return .sessionRead }
        if name == "runtime_status" { return .runtimeStatus }
        var advancedNames: Set<String> = Set([
            "mcp_call", "subagent_dispatch", "model_council_run",
            IOSSoulToolCatalog.toolName,
            "spawn_agent", "list_agents", "interrupt_agent",
            "send_message", "followup_task", "wait_agent",
        ])
        .union(IOSAppleAgentToolCatalog.toolNames)
        .union(IOSSkillToolCatalog.toolNames)
        .union(IOSMcpManagementToolCatalog.toolNames)
        .union(IOSProviderConfigToolCatalog.toolNames)
        .union(IOSThemePackToolCatalog.toolNames)
        .union(IOSRecipeToolCatalog.toolNames)
        .union(IOSPluginToolCatalog.toolNames)
        if IOSDynamicToolRegistry.isDynamicWorkflowToolName(name) { return .advanced }
        if executionPolicy?.execJavaScriptEnabled ?? effectiveExecJavaScriptEnabled {
            advancedNames.formUnion(["exec", "wait"])
        }
        if advancedNames.contains(name) || name.hasPrefix("mcp__") { return .advanced }
        return nil
    }

    /// 前台策略的内核执行器表:与 `backgroundToolExecutors` 同构,但走
    /// `execute(...)` 前台分发(kind 分发、审批卡、记忆污染置位全部沿用),
    /// `isUserInitiated` 由调用点语义决定。审批命中时 prompt 登记进
    /// `approvalPromptBox`(引擎的 `.needsApproval` 只有 reason 字符串,
    /// 审批卡对象经盒子交接),引擎随后以 `pendingApproval` 暂停,由
    /// `ChatRunKernelAdapter` 决定批准/拒绝并调用对应 finish*Approval。
    ///
    /// - parameter baseMessagesProvider: 执行器被引擎调用时取当前 run 的
    ///   工作消息,充当 `ChatPendingToolApproval.baseMessages`(回填锚点)。
    ///   适配器必须返回引擎当轮 working 的最新值。
    func foregroundToolExecutors(
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        startedAt: Int64,
        inputDigest: String,
        conversationId: KotlinUuid?,
        toolExposureBridge: IosToolExposureBridge?,
        baseMessagesProvider: @escaping @MainActor @Sendable () -> [UIMessage],
        approvalPromptBox: IOSForegroundApprovalPromptBox,
        nestedToolRunner: IosExecNestedToolRunner? = nil,
        nestedOutcomeUnknownProvider: (@MainActor () -> IOSToolOutcomeUnknownSignal?)? = nil,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot? = nil,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) -> [String: any IOSToolExecutor] {
        var executors: [String: any IOSToolExecutor] = [:]
        for tool in params.tools {
            let name = tool.name
            let kind = pendingKindForForegroundTool(named: name, executionPolicy: executionPolicy)
            guard let kind else { continue }
            executors[name] = IOSForegroundKernelToolExecutor(
                runtime: self,
                kind: kind,
                providerSetting: providerSetting,
                params: params,
                runId: runId,
                startedAt: startedAt,
                inputDigest: inputDigest,
                conversationId: conversationId,
                toolExposureBridge: toolExposureBridge,
                baseMessagesProvider: baseMessagesProvider,
                approvalPromptBox: approvalPromptBox,
                nestedToolRunner: nestedToolRunner,
                nestedOutcomeUnknownProvider: nestedOutcomeUnknownProvider,
                recipeCatalogSnapshot: recipeCatalogSnapshot,
                executionPolicy: executionPolicy
            )
        }
        return executors
    }

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

    /// P3-b: names that are NEVER injectable as nested `tools` functions —
    /// `exec` itself (self-call guard), the thread-orchestration tools
    /// (aligned with codex "collaboration tools cannot be called from exec"),
    /// the discovery tool, and `ask_user` (its HITL card cannot be re-entered
    /// from inside an evaluation). Single source for the engine's function
    /// injection AND the coordinator's nested-runner classification.
    static let execNestedToolExclusions: Set<String> = Set([
        "exec", "spawn_agent", "list_agents", "interrupt_agent",
        "send_message", "followup_task", "wait_agent", "tool_search", "ask_user",
        // Nested exec only sees a synthetic assistant message — pad-image enrich
        // cannot resolve user attachments, and image gen is a paid side effect.
        "generate_image",
        "theme_pack_import",
    ]).union(IOSRemoteTerminalToolCatalog.jobToolNames)

    /// P3-b: whitelist for one evaluation's `tools` object = the current
    /// round's visible tool set minus the exec exclusions. Same source for
    /// the engine's function injection and the coordinator's nested-runner
    /// classification, so the two can never disagree.
    static func execNestedToolWhitelist(visibleToolNames: Set<String>) -> Set<String> {
        visibleToolNames.subtracting(execNestedToolExclusions)
    }

    /// P3-d: ALL_TOOLS discovery descriptions for the whitelisted names, taken
    /// from the same round's `[Tool]` declarations (the same objects that made
    /// the whitelist visible). Names outside the whitelist are ignored; a
    /// declared-but-descriptionless tool falls back to an empty string and the
    /// engine still installs its name-only ALL_TOOLS entry.
    static func execToolDescriptions(from tools: [Tool], whitelist: Set<String>) -> [String: String] {
        var descriptions: [String: String] = [:]
        for tool in tools where whitelist.contains(tool.name) {
            descriptions[tool.name] = tool.description_
        }
        return descriptions
    }

    /// P3-b: builds the sandbox bridge from the run's exposure bridge and the
    /// coordinator-provided nested runner. Nil when there is no runner or no
    /// bridge (the evaluation then runs without a `tools` object, exactly like
    /// P3-a).
    private static func execNestedToolsBridge(
        toolExposureBridge: IosToolExposureBridge?,
        nestedToolRunner: IosExecNestedToolRunner?
    ) -> IOSJsSandboxTools? {
        guard let toolExposureBridge, let nestedToolRunner else { return nil }
        let visible = toolExposureBridge.visibleTools()
        let whitelist = execNestedToolWhitelist(
            visibleToolNames: Set(visible.map(\.name))
        )
        guard !whitelist.isEmpty else { return nil }
        return IOSJsSandboxTools(
            availableToolNames: whitelist.sorted(),
            hostCall: { name, arguments in
                await nestedToolRunner(name, arguments)
            },
            // P3-d: ALL_TOOLS 与白名单同一来源（同轮可见工具集），描述直接来自
            // 可见声明的 KMP description。
            toolDescriptions: execToolDescriptions(from: visible, whitelist: whitelist)
        )
    }

    func userInitiatedImageToolCall(input: String) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: "image-\(UUID().uuidString)-\(chatInputDigest(for: input))",
            toolName: "generate_image",
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    func messagesByExecutingImageToolCall(
        _ toolCall: UIMessagePart.Tool,
        in messages: [UIMessage]
    ) async -> [UIMessage] {
        let resultParts = await dispatchImageToolCall(toolCall, messages: messages)
        return messagesByFinishingToolCall(
            toolCall,
            outputParts: resultParts,
            in: messages
        )
    }

    func finishMemoryApproval(
        pending: ChatPendingToolApproval,
        writePolicy: IOSMemoryToolWritePolicy,
        expectedUpdatedAt: Int64? = nil
    ) -> [UIMessage] {
        let allowed: Bool
        if case .allow = writePolicy {
            allowed = true
        } else {
            allowed = false
        }
        recordToolApproval(
            capabilityId: "ios.agent.memory_write",
            toolCall: pending.toolCall,
            action: allowed ? .allowed : .denied,
            reason: allowed ? "User approved memory write." : "User denied memory write.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )

        let resultText = IOSMemoryToolExecutor.execute(
            input: pending.toolCall.input,
            runtime: sharedSettings.agentRuntime,
            writePolicy: writePolicy,
            expectedUpdatedAt: expectedUpdatedAt
        )
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    func finishSearchApproval(
        pending: ChatPendingToolApproval,
        allow: Bool
    ) async -> [UIMessage] {
        recordToolApproval(
            capabilityId: "ios.network.search_tools",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved network search." : "User denied network search.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        let resultText = allow
            ? await dispatchSearchToolCall(pending.toolCall)
            : ChatToolOutputFormatter.toolFailureJSON(
                toolName: pending.toolCall.toolName,
                reason: "User denied network search.",
                denied: true
            )
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages,
            conversationId: allow ? pending.conversationId : nil
        )
    }

    func finishWebMountApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        approvalRequest: WebMountToolApprovalRequest
    ) async -> [UIMessage] {
        recordToolApproval(
            capabilityId: "ios.webmount.browser",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved WebMount foreground action." : "User denied WebMount foreground action.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy,
            conversationId: pending.conversationId
        )

        let resultText: String
        let currentPreview = localToolExecutor?.webMountApprovalPreview(
            toolName: pending.toolCall.toolName,
            input: pending.toolCall.input
        )
        let handoffContextMatches = allow
            && approvalRequest.requiresHumanHandoff
            && approvalRequest.sessionId?.nilIfBlank != nil
            && approvalRequest.sessionId?.nilIfBlank == currentPreview?.sessionId?.nilIfBlank
            && approvalRequest.runId?.nilIfBlank != nil
            && approvalRequest.runId?.nilIfBlank == pending.runId.nilIfBlank
        let humanHandoffCompleted = handoffContextMatches
            && approvalRequest.backend == "local"
            && localToolExecutor?.completeWebMountHumanHandoff(
                toolName: pending.toolCall.toolName,
                input: pending.toolCall.input,
                runId: pending.runId
            ) == true
        if allow, approvalRequest.requiresHumanHandoff, !handoffContextMatches {
            resultText = IOSWebMountController.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "status": "stale_handoff",
                "error_code": "stale_handoff",
                "requires_reobserve": true,
                "may_have_applied": false,
                "message": "The WebMount handoff context changed; re-observe before continuing."
            ])
        } else if allow, approvalRequest.requiresHumanHandoff, approvalRequest.backend != "local" {
            resultText = IOSWebMountController.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "status": "requires_human",
                "error_code": "local_privacy_session_required",
                "requires_human": true,
                "handoff": true,
                "may_have_applied": false,
                "message": "The sensitive desktop action remained blocked. Complete it in local WebMount, then re-observe."
            ])
        } else if humanHandoffCompleted {
            resultText = IOSWebMountController.json([
                "ok": true,
                "tool": pending.toolCall.toolName,
                "status": "human_handoff_completed",
                "requires_reobserve": true,
                "message": "Foreground WebMount handoff completed; re-observe before continuing."
            ])
        } else if allow, approvalRequest.requiresHumanHandoff {
            resultText = IOSWebMountController.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "status": "stale_handoff",
                "error_code": "stale_handoff",
                "requires_reobserve": true,
                "may_have_applied": false,
                "message": "The local handoff is no longer active; re-observe before continuing."
            ])
        } else if allow {
            let output = await webMountToolExecutionOutput(
                pending.toolCall,
                isUserInitiated: true,
                executionPolicy: pending.executionPolicy,
                runId: pending.runId,
                conversationId: pending.conversationId
            )
            resultText = ChatToolOutputFormatter.webMountResultText(for: pending.toolCall, output: output)
        } else {
            resultText = IOSWebMountController.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "denied": true,
                "policy": "user_denied",
                "reason": "User denied WebMount foreground action."
            ])
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    func finishWorkspaceApproval(
        pending: ChatPendingToolApproval,
        allow: Bool
    ) async -> [UIMessage] {
        recordToolApproval(
            capabilityId: IOSCapabilityRegistry.capability(forToolName: pending.toolCall.toolName)?.id
                ?? "ios.workspace.files",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved Workspace tool access." : "User denied Workspace tool access.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        let resultText: String
        if allow {
            let output = await workspaceToolExecutionOutput(
                pending.toolCall,
                isUserInitiated: true,
                executionPolicy: pending.executionPolicy
            )
            resultText = ChatToolOutputFormatter.workspaceResultText(for: pending.toolCall, output: output)
        } else {
            resultText = IOSWorkspaceStore.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "denied": true,
                "policy": "user_denied",
                "reason": "User denied Workspace tool access."
            ])
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    func finishIshHandoffApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        approvalRequest: IshHandoffToolApprovalRequest? = nil
    ) async -> [UIMessage] {
        let capabilityId = approvalRequest?.capabilityId
            ?? IOSCapabilityRegistry.capability(forToolName: pending.toolCall.toolName)?.id
            ?? "ios.external.ish_handoff"
        let canReturnExecutionOutput = IOSRemoteTerminalToolCatalog.supportedToolNames.contains(pending.toolCall.toolName)
            || IOSAmberShellToolCatalog.supportedToolNames.contains(pending.toolCall.toolName)
            || IOSEmbeddedIshToolCatalog.supportedToolNames.contains(pending.toolCall.toolName)
        recordToolApproval(
            capabilityId: capabilityId,
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved terminal tool." : "User denied terminal tool.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )

        let resultText: String
        if allow {
            let output = await ishToolExecutionOutput(
                pending.toolCall,
                isUserInitiated: true,
                executionPolicy: pending.executionPolicy,
                approvalRequest: approvalRequest
            )
            resultText = ChatToolOutputFormatter.ishHandoffResultText(for: pending.toolCall, output: output)
        } else {
            resultText = IOSWorkspaceStore.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "denied": true,
                "policy": "user_denied",
                "reason": "User denied terminal tool.",
                "stdout_available": canReturnExecutionOutput,
                "stderr_available": canReturnExecutionOutput,
                "exit_code_available": false
            ])
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    func finishMcpApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        preparedSkillImport: IOSPreparedSkillImport? = nil,
        preparedSoulImport: IOSPreparedSoulImport? = nil,
        preparedMcpImport: IOSPreparedMcpImport? = nil
    ) async -> [UIMessage] {
        let audit: (capabilityId: String, actionName: String)
        if pending.toolCall.toolName == "mcp_call"
            || ToolKt.isExpandedMcpToolName(name: pending.toolCall.toolName)
            || pending.toolCall.toolName == "mcp_test"
            || pending.toolCall.toolName == "mcp_import_from_skill" {
            audit = ("ios.mcp.tool_call", "MCP tool call")
        } else if IOSMcpManagementToolCatalog.toolNames.contains(pending.toolCall.toolName) {
            audit = ("ios.mcp.management", "MCP management operation")
        } else if pending.toolCall.toolName == "provider_config_apply" {
            audit = ("ios.settings.provider_config", "Provider configuration")
        } else if pending.toolCall.toolName == "theme_pack_import" {
            audit = ("ios.settings.theme_pack", "Theme pack try-on")
        } else if pending.toolCall.toolName == IOSSoulToolCatalog.toolName {
            audit = ("ios.skills.management", "Soul update")
        } else if IOSRecipeToolCatalog.toolNames.contains(pending.toolCall.toolName)
                    || IOSPluginToolCatalog.toolNames.contains(pending.toolCall.toolName) {
            audit = ("ios.recipes.management", "Recipe management operation")
        } else if IOSAppleAgentToolCatalog.toolNames.contains(pending.toolCall.toolName) {
            audit = (
                IOSCapabilityRegistry.capability(forToolName: pending.toolCall.toolName)?.id
                    ?? "ios.apple.agent_tools",
                "Apple device capability"
            )
        } else {
            audit = ("ios.skills.management", "local Skill operation")
        }
        recordToolApproval(
            capabilityId: audit.capabilityId,
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved \(audit.actionName)." : "User denied \(audit.actionName).",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )

        let resultText: String
        if allow {
            if pending.toolCall.toolName == "skill_import" {
                if let preparedSkillImport {
                    do {
                        resultText = try skillMcpToolService.applyPreparedSkillImport(preparedSkillImport)
                    } catch {
                        resultText = ChatToolOutputFormatter.toolFailureJSON(
                            toolName: pending.toolCall.toolName,
                            reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                            status: "failed"
                        )
                    }
                } else {
                    // 冷启动或审批内存态丢失时 fail closed；绝不能退回普通
                    // dispatch（那会重新 preview，或让未来实现意外绕过本次审批）。
                    resultText = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: "Skill 导入预览已失效，请重新发起导入并确认最新变更。",
                        status: "failed"
                    )
                }
            } else if pending.toolCall.toolName == IOSSoulToolCatalog.toolName {
                if let preparedSoulImport {
                    do {
                        resultText = try soulService.applyPreparedImport(preparedSoulImport)
                    } catch {
                        resultText = ChatToolOutputFormatter.toolFailureJSON(
                            toolName: pending.toolCall.toolName,
                            reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                            status: "failed"
                        )
                    }
                } else {
                    resultText = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: "核心指令预览已失效，请重新发起导入并确认最新变更。",
                        status: "failed"
                    )
                }
            } else if pending.toolCall.toolName == "mcp_import_from_skill" {
                if !isMcpNetworkAllowed() {
                    resultText = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: "MCP 调用已关闭，未发起网络测试或写入。",
                        status: "denied"
                    )
                } else if let preparedMcpImport {
                    resultText = await skillMcpToolService.applyPreparedMcpImport(preparedMcpImport) { [weak self] in
                        self?.isMcpNetworkAllowed() ?? false
                    }
                } else {
                    resultText = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: "MCP 导入预览已失效，请重新发起导入并确认最新变更。",
                        status: "failed"
                    )
                }
            } else if pending.toolCall.toolName == "theme_pack_import" {
                do {
                    resultText = try themePackToolService.commitPreparedImport()
                } catch {
                    resultText = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    )
                }
            } else if isMcpNetworkTool(pending.toolCall.toolName), !isMcpNetworkAllowed() {
                resultText = ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: "MCP 调用已关闭。",
                    status: "denied"
                )
            } else {
                resultText = await dispatchAdvancedToolCall(
                    pending.toolCall,
                    providerSetting: pending.providerSetting,
                    params: pending.params,
                    runId: pending.runId,
                    conversationId: pending.conversationId
                )
            }
        } else if pending.toolCall.toolName == "theme_pack_import" {
            themePackToolService.discardPreparedImport()
            resultText = ChatToolOutputFormatter.toolFailureJSON(
                toolName: pending.toolCall.toolName,
                reason: "用户还原了试穿，主题未保存。",
                denied: true,
                status: "denied"
            )
        } else {
            resultText = "用户拒绝执行 \(pending.toolCall.toolName)。"
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages,
            // 拒绝分支输出是纯文本（无 ok:false 可判定），显式只在 allow 时置位。
            conversationId: allow ? pending.conversationId : nil
        )
    }

    func finishCouncilApproval(
        pending: ChatPendingToolApproval,
        allow: Bool
    ) async -> [UIMessage] {
        recordToolApproval(
            capabilityId: "ios.agent.model_council_run",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow
                ? "User approved \(pending.toolCall.toolName)."
                : "User denied \(pending.toolCall.toolName).",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        let resultText: String
        if allow {
            resultText = await dispatchAdvancedToolCall(
                pending.toolCall,
                providerSetting: pending.providerSetting,
                params: pending.params,
                runId: pending.runId,
                conversationId: pending.conversationId
            )
        } else {
            resultText = IOSWorkspaceStore.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "status": "denied",
                "denied": true,
                "policy": "user_denied",
                "reason": "用户拒绝启动模型议会。"
            ])
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    func finishAskUserAnswer(
        pending: ChatPendingToolApproval,
        answer: String
    ) -> [UIMessage] {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: Any]
        if trimmed.isEmpty {
            payload = [
                "denied": true,
                "reason": "User skipped ask_user."
            ]
        } else {
            payload = ["answer": trimmed]
        }
        let outputText: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            outputText = text
        } else if trimmed.isEmpty {
            outputText = #"{"denied":true,"reason":"User skipped ask_user."}"#
        } else {
            outputText = #"{"answer":"\#(trimmed)"}"#
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: outputText,
            in: pending.baseMessages
        )
    }

    func messagesByFinishingToolCall(
        _ targetToolCall: UIMessagePart.Tool,
        outputText: String,
        in messages: [UIMessage],
        conversationId: KotlinUuid? = nil
    ) -> [UIMessage] {
        // P2-a: 工具输出唯一收口——成功的外部上下文输出进会话时由 harness 置
        // POLLUTED（只升不降；失败输出不置位；置位失败只记日志，不阻塞工具结果）。
        // conversationId 只由 run 锚定会话传入（前台 pending / 后台 job），
        // 恢复/失败路径（nil）与 UI 当前会话天然隔离。
        markMemoryPollutionIfNeeded(
            toolName: targetToolCall.toolName,
            outputText: outputText,
            conversationId: conversationId
        )
        let outputPart = UIMessagePart.Text(text: outputText, metadata: nil)
        return messagesByFinishingToolCall(targetToolCall, outputParts: [outputPart], in: messages)
    }

    /// P2-a: 判定并触发记忆污染置位。只标「外部上下文」工具（web 搜索/网页读取/
    /// MCP 直调与 mcp__* 展开）且输出为成功（failureReason 与 toolFailureJSON 的
    /// ok:false/status 契约一致）；wm_* 待 URL 分类后纳入（P2.5）。幂等只升不降由
    /// 存储层保证，这里只负责「成功输出进会话」这一 harness 时机。
    private func markMemoryPollutionIfNeeded(
        toolName: String,
        outputText: String,
        conversationId: KotlinUuid?
    ) {
        guard let conversationId,
              let marker = memoryPollutionMarker,
              ConversationMemoryPollutionPolicy.shouldMarkPolluted(toolName: toolName, outputText: outputText),
              ChatToolOutputFormatter.failureReason(from: [UIMessagePart.Text(text: outputText, metadata: nil)]) == nil
        else { return }
        marker(conversationId, toolName)
    }

    func messagesByFailingPendingToolCalls(
        in messages: [UIMessage],
        outputText: String
    ) -> [UIMessage] {
        var resolvedMessages = messages
        var resolvedKeys = Set<String>()

        while let toolCall = unresolvedToolCall(in: resolvedMessages) {
            let key = chatToolCallKey(toolCall)
            guard resolvedKeys.insert(key).inserted else { break }
            resolvedMessages = messagesByFinishingToolCall(
                toolCall,
                outputText: outputText,
                in: resolvedMessages
            )
        }

        return resolvedMessages
    }

    func messagesByFailingPendingToolCalls(
        in messages: [UIMessage],
        failureReason: String,
        denied: Bool = false
    ) -> [UIMessage] {
        var resolvedMessages = messages
        var resolvedKeys = Set<String>()

        while let toolCall = unresolvedToolCall(in: resolvedMessages) {
            let key = chatToolCallKey(toolCall)
            guard resolvedKeys.insert(key).inserted else { break }
            resolvedMessages = messagesByFinishingToolCall(
                toolCall,
                outputText: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: failureReason,
                    denied: denied
                ),
                in: resolvedMessages
            )
        }

        return resolvedMessages
    }

    /// P0-a Fix B: soft-fail a tool call whose name EXISTS in the run's full
    /// catalog but is NOT in the current round's visible set — the model
    /// called a real tool that was never exposed (deferred behind tool_search).
    /// Fills that part in place with a structured failure output telling the
    /// model to call `tool_search` first, so the run CONTINUES instead of
    /// hard-failing. Returns nil when nothing needs guidance: a visible tool is
    /// handled by the normal execution path, and a truly unknown name stays on
    /// the existing unresolved-tool hard-fail path (never mask a real bug).
    func messagesByGuidingUnexposedToolCalls(
        in messages: [UIMessage],
        fullCatalogNames: Set<String>,
        visibleToolNames: Set<String>
    ) -> (messages: [UIMessage], toolCallId: String)? {
        guard let toolCall = unresolvedToolCall(in: messages) else { return nil }
        guard fullCatalogNames.contains(toolCall.toolName),
              !visibleToolNames.contains(toolCall.toolName) else { return nil }
        let outputText = ChatToolOutputFormatter.toolFailureJSON(
            toolName: toolCall.toolName,
            reason: "该工具本轮未暴露，请先调用 tool_search 获取，下一步再执行",
            status: "failed"
        )
        return (
            messagesByFinishingToolCall(toolCall, outputText: outputText, in: messages),
            toolCall.toolCallId
        )
    }

    private func unresolvedToolCall(in messages: [UIMessage]) -> UIMessagePart.Tool? {
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
    private func resolvedImageGenerationConfig() -> (modelId: String, apiKey: String, baseURL: String)? {
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
    private func codexImageConfig() -> ChatCodexImageConfig {
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
    private func pendingSessionReadToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        let sessionToolNames: Set<String> = ["session_search", "session_read"]
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    sessionToolNames.contains($0.toolName)
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    /// runtime_status 的待执行检测。只识别可见且 output 为空的调用
    /// （照 pendingSessionReadToolCall 模式）。
    private func pendingRuntimeStatusToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    $0.toolName == "runtime_status"
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    /// session_search / session_read 执行入口：本地只读，无审批、无网络。
    private func executeSessionReadToolCall(_ pending: ChatPendingToolApproval) async -> ChatToolRuntimeResult {
        let resultText = await dispatchSessionReadToolCall(pending.toolCall)
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        ))
    }

    // MARK: - 跨会话读取（session_search / session_read）执行体

    // 契约常量与 KMP 声明默认值/上限同源（session_search limit [1,20] 默认 8；
    // session_read max_messages [1,50] 默认 20）。
    static let sessionSearchDefaultLimit = 8
    static let sessionSearchMaxLimit = 20
    static let sessionReadDefaultMaxMessages = 20
    static let sessionReadMaxMessages = 50
    /// 单条消息投影文本截断上限（字符）。
    static let sessionReadMessageTextLimit = 2_000
    /// 总输出截断上限（消息投影合计，JSON 编码前）。
    static let sessionReadTotalOutputLimit = 12_000
    /// 单条全文分页的默认字符数与请求上限。分页结果还会按实际 JSON
    /// 序列化长度再收窄，避免下面的工具输出收口改写 text 而跳过游标。
    static let sessionReadPageDefaultMaxChars = 2_000
    static let sessionReadPageMaxChars = 8_000

    /// 执行体：无 store 注入时结构化「不可用」；会话不存在给
    /// `{status:error, reason:"conversation not found"}`；非法 conversation_id
    /// 走 Foundation 预校验（M4 先例：K/N `Uuid.parse` 对非法串终止进程，
    /// 必须先用 `UUID(uuidString:)` 拦截）。
    private func dispatchSessionReadToolCall(_ toolCall: UIMessagePart.Tool) async -> String {
        // recipe 原语把 runtime_status 路由到 .sessionRead（同为本地只读）——
        // 在 store 检查之前分流，避免"会话读取不可用"误报。
        if toolCall.toolName == "runtime_status" {
            return dispatchRuntimeStatusToolCall(toolCall, toolExposureBridge: nil)
        }
        guard let store = conversationStoreProvider?() else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "会话读取工具当前不可用。",
                status: "failed"
            )
        }
        switch toolCall.toolName {
        case "session_search":
            return await Self.executeSessionSearch(toolCall: toolCall, store: store)
        case "session_read":
            return await Self.executeSessionRead(toolCall: toolCall, store: store)
        default:
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "未知的会话工具。",
                status: "failed"
            )
        }
    }

    private static func executeSessionSearch(
        toolCall: UIMessagePart.Tool,
        store: IOSConversationStore
    ) async -> String {
        guard let args = ChatToolCallParsing.jsonObject(toolCall.input),
              let query = args["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "session_search 参数无效：需要非空 query。",
                status: "failed"
            )
        }
        let requestedLimit = (args["limit"] as? Int) ?? sessionSearchDefaultLimit
        let limit = min(max(requestedLimit, 1), sessionSearchMaxLimit)
        let hits = await store.sessionSearchHits(query: query, limit: limit)
        var payload: [String: Any] = [
            "ok": true,
            "tool": toolCall.toolName,
            "status": "ok",
            "query": query,
            "results": hits.map { hit -> [String: Any] in
                [
                    "conversation_id": hit.conversationId.toHexDashString(),
                    "title": hit.title,
                    "snippet": hit.snippet,
                    "updated_at": hit.updatedAt,
                    "message_count": hit.messageCount,
                ]
            },
        ]
        if hits.isEmpty {
            payload["hint"] = "没有找到匹配的会话，试试换一个关键词。"
        }
        return IOSWorkspaceStore.json(payload)
    }

    private static func executeSessionRead(
        toolCall: UIMessagePart.Tool,
        store: IOSConversationStore
    ) async -> String {
        guard let args = ChatToolCallParsing.jsonObject(toolCall.input),
              let rawId = args["conversation_id"] as? String else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "session_read 参数无效：需要 conversation_id。",
                status: "failed"
            )
        }
        // M4 先例：K/N 的 KotlinUuid.parse 对非法串在导出下终止进程（NSException）——
        // 先用 Foundation UUID(uuidString:) 正则级预校验拦截（并归一化小写）。
        let normalizedId = rawId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: normalizedId) != nil else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "conversation_id 不是合法的会话 id：\(rawId)。请用 session_search 获取 conversation_id。",
                status: "failed"
            )
        }
        let conversationId = KotlinUuid.companion.parse(uuidString: normalizedId)
        let requestedMax = (args["max_messages"] as? Int) ?? sessionReadDefaultMaxMessages
        let maxMessages = min(max(requestedMax, 1), sessionReadMaxMessages)

        // 当前会话优先走内存（P1-c loadConversationForOrchestration 同契约）。
        let conversation: Conversation?
        if store.currentConversation?.id == conversationId {
            conversation = store.currentConversation
        } else {
            conversation = try? await store.loadConversationForOrchestration(conversationId)
        }
        guard let conversation else {
            return IOSWorkspaceStore.json([
                "status": "error",
                "reason": "conversation not found",
            ])
        }
        let messages = Self.searchableMessages(of: conversation)

        // `message_id` selects a single persisted message for lossless paging.
        // It is deliberately matched as the stored string; unlike the
        // conversation id above, it must not pass through KotlinUuid.parse.
        if let rawMessageId = args["message_id"] {
            guard let requestedMessageId = (rawMessageId as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !requestedMessageId.isEmpty else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "session_read 参数无效：message_id 必须是非空字符串。",
                    status: "failed"
                )
            }

            let normalizedMessageId = requestedMessageId.lowercased()
            guard let message = messages.first(where: {
                Self.sessionMessageId($0).lowercased() == normalizedMessageId
            }) else {
                return IOSWorkspaceStore.json([
                    "ok": false,
                    "tool": toolCall.toolName,
                    "status": "error",
                    "error": "message_not_found",
                    "reason": "message not found",
                    "message_id": requestedMessageId,
                ])
            }

            let fullText = Self.projectMessageText(message)
            let totalChars = fullText.count
            let offset: Int
            if let rawOffset = args["offset"] {
                guard let value = rawOffset as? Int else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName,
                        reason: "session_read 参数无效：offset 必须是非负整数。",
                        status: "failed"
                    )
                }
                offset = value
            } else {
                offset = 0
            }
            guard offset >= 0, offset <= totalChars else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "session_read 参数无效：offset 必须在 0 到 \(totalChars) 之间。",
                    status: "failed"
                )
            }

            let maxChars: Int
            if let rawMaxChars = args["max_chars"] {
                guard let value = rawMaxChars as? Int, value > 0 else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName,
                        reason: "session_read 参数无效：max_chars 必须是正整数。",
                        status: "failed"
                    )
                }
                maxChars = min(value, sessionReadPageMaxChars)
            } else {
                maxChars = sessionReadPageDefaultMaxChars
            }

            return Self.projectSessionMessagePage(
                message: message,
                conversationId: conversation.id.toHexDashString(),
                fullText: fullText,
                offset: offset,
                maxChars: maxChars
            )
        }

        guard args["offset"] == nil, args["max_chars"] == nil else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "session_read 分页需要 message_id；请使用结果中的消息引用和 next_offset。",
                status: "failed"
            )
        }
        let rows = Self.projectLatestMessages(messages, maxMessages: maxMessages)
        return Self.boundedSessionReadJSON(
            conversationId: conversation.id.toHexDashString(),
            title: conversation.title,
            messageCount: messages.count,
            rows: rows
        )
    }

    /// 与 IOSConversationStore.searchableMessages 同源：分支节点优先，兜底 currentMessages。
    private static func searchableMessages(of conversation: Conversation) -> [UIMessage] {
        let nodeMessages = conversation.messageNodes.flatMap { node in
            node.messages
        }
        if !nodeMessages.isEmpty { return nodeMessages }
        return conversation.currentMessages
    }

    /// 最新 N 条消息的投影；总预算 [sessionReadTotalOutputLimit] 耗尽即停（截断
    /// 发生在 JSON 编码前，逐条前缀截断不截半条以上内容）。
    private static func projectLatestMessages(
        _ messages: [UIMessage],
        maxMessages: Int
    ) -> [[String: Any]] {
        let latest = messages.suffix(max(maxMessages, 1))
        var remainingBudget = sessionReadTotalOutputLimit
        var rows: [[String: Any]] = []
        for message in latest {
            let fullText = projectMessageText(message)
            let projected = String(fullText.prefix(min(sessionReadMessageTextLimit, remainingBudget)))
            guard !projected.isEmpty else { break }
            let truncated = projected.count < fullText.count
            rows.append([
                "message_id": sessionMessageId(message),
                "role": roleName(message.role),
                "text": projected,
                "total_chars": fullText.count,
                "truncated": truncated,
                "next_offset": truncated ? projected.count as Any : NSNull(),
            ])
            remainingBudget -= projected.count
        }
        return rows
    }

    /// 单条消息完整投影：Text parts 拼接、Tool parts 摘要为 `[tool: 名称 状态]` 一行。
    /// 默认读取和分页必须共用这份全文，保证分页 offset 与默认结果一致。
    private static func projectMessageText(_ message: UIMessage) -> String {
        message.parts.map { part -> String in
            if let textPart = part as? UIMessagePart.Text {
                return textPart.text
            }
            if let tool = part as? UIMessagePart.Tool {
                return toolPartSummary(tool)
            }
            return ""
        }.joined(separator: "\n")
    }

    private static func sessionMessageId(_ message: UIMessage) -> String {
        message.id.toHexDashString()
    }

    /// 分页结果的 JSON 也受统一工具输出 12k 收口约束。按实际序列化长度
    /// 二分可返回字符数，next_offset 始终对应真正返回的 text 尾部。
    private static func projectSessionMessagePage(
        message: UIMessage,
        conversationId: String,
        fullText: String,
        offset: Int,
        maxChars: Int
    ) -> String {
        let totalChars = fullText.count
        let requestedLength = min(maxChars, totalChars - offset)
        let messageId = sessionMessageId(message)
        let remainingText = fullText.dropFirst(offset)

        func serializedPage(length: Int) -> String {
            let text = String(remainingText.prefix(length))
            let reachedEnd = offset + length >= totalChars
            return IOSWorkspaceStore.json([
                "ok": true,
                "tool": "session_read",
                "status": "ok",
                "conversation_id": conversationId,
                "message_id": messageId,
                "role": roleName(message.role),
                "text": text,
                "offset": offset,
                "next_offset": reachedEnd ? NSNull() : (offset + length) as Any,
                "total_chars": totalChars,
                "truncated": !reachedEnd,
            ])
        }

        let hardLimit = IOSToolOutputLimits.maxOutputChars
        let requestedOutput = serializedPage(length: requestedLength)
        if requestedOutput.count <= hardLimit { return requestedOutput }
        // A page's fixed UUID/offset metadata plus one character fits the
        // budget. Search only when JSON escaping makes the requested page larger.
        var lower = 1
        var upper = requestedLength - 1
        var bestOutput = serializedPage(length: 1)
        while lower <= upper {
            let candidate = (lower + upper) / 2
            let output = serializedPage(length: candidate)
            if output.count <= hardLimit {
                bestOutput = output
                lower = candidate + 1
            } else {
                upper = candidate - 1
            }
        }

        return bestOutput
    }

    /// Default recent-message mode keeps its existing text and total budgets,
    /// then shrinks only text fields if metadata would push serialized JSON over
    /// the same 12k output cap. Metadata remains truthful after each shrink.
    private static func boundedSessionReadJSON(
        conversationId: String,
        title: String,
        messageCount: Int,
        rows: [[String: Any]]
    ) -> String {
        var workingRows = rows

        func serialized() -> String {
            IOSWorkspaceStore.json([
                "ok": true,
                "tool": "session_read",
                "status": "ok",
                "conversation_id": conversationId,
                "title": title,
                "message_count": messageCount,
                "messages": workingRows,
            ])
        }

        var output = serialized()
        while output.count > IOSToolOutputLimits.maxOutputChars {
            guard let index = workingRows.indices.max(by: {
                ((workingRows[$0]["text"] as? String)?.count ?? 0)
                    < ((workingRows[$1]["text"] as? String)?.count ?? 0)
            }),
            let text = workingRows[index]["text"] as? String,
            !text.isEmpty else {
                break
            }

            let keepCount = text.count == 1 ? 0 : text.count / 2
            workingRows[index]["text"] = String(text.prefix(keepCount))
            let totalChars = workingRows[index]["total_chars"] as? Int ?? text.count
            let truncated = keepCount < totalChars
            workingRows[index]["truncated"] = truncated
            workingRows[index]["next_offset"] = truncated ? keepCount as Any : NSNull()
            output = serialized()
        }
        return output
    }

    private static func toolPartSummary(_ tool: UIMessagePart.Tool) -> String {
        let status: String
        if tool.isExecuted {
            status = "completed"
        } else if tool.isPending {
            status = "pending"
        } else {
            status = "waiting"
        }
        return "[tool: \(tool.toolName) \(status)]"
    }

    private static func roleName(_ role: MessageRole) -> String {
        if role == MessageRole.user { return "user" }
        if role == MessageRole.assistant { return "assistant" }
        if role == MessageRole.system { return "system" }
        if role == MessageRole.tool { return "tool" }
        return String(describing: role).lowercased()
    }

    // MARK: - 运行时自省（runtime_status）执行体

    /// runtime_status 执行入口：本地只读自省，无审批、无网络、无副作用。
    /// 回答"我有什么能力/现在什么状态"——Jev 模式、凭据存在性（绝不回传
    /// Key 本体）、门控与目录计数；不触发任何 Jev 判断，不改设置/缓存/指标。
    private func executeRuntimeStatusToolCall(
        _ pending: ChatPendingToolApproval,
        toolExposureBridge: IosToolExposureBridge?
    ) -> ChatToolRuntimeResult {
        let resultText = dispatchRuntimeStatusToolCall(
            pending.toolCall,
            toolExposureBridge: toolExposureBridge
        )
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        ))
    }

    /// 稳定契约：{ok, tool:"runtime_status", schema, platform, runtime, tools, jev}。
    /// 只暴露布尔/枚举/计数/版本号——Key、原文、URL、会话内容一律不进输出。
    func dispatchRuntimeStatusToolCall(
        _ toolCall: UIMessagePart.Tool,
        toolExposureBridge: IosToolExposureBridge? = nil
    ) -> String {
        let jevSettings = sharedSettings.jevSettings
        let jevKeyConfigured = sharedSettings.hasJevApiKey()
        let jevCoordinatorStatus = IOSJevDecisionCoordinator.shared.status
        let jevMetrics = IOSJevMetricsStore.summary()

        var useCases: [String: Any] = [:]
        for useCase in IOSJevUseCase.allCases {
            let configured = jevSettings.mode(for: useCase)
            let effective = jevSettings.effectiveMode(for: useCase)
            let required = useCase.defaultDataScopes
            let canSend = jevSettings.canSend(useCase: useCase, required: required)
            let availableNow = effective != .off
                && canSend
                && jevKeyConfigured
                && jevSettings.modelConfigured
                && !jevCoordinatorStatus.pausedForAuth
                && jevCoordinatorStatus.cooldownRemaining == nil
            useCases[Self.jevUseCaseStatusKey(useCase)] = [
                "mode": configured.rawValue,
                "effective_mode": effective.rawValue,
                "scopes_allowed": jevSettings.allowedScopes(for: useCase).map(\.rawValue).sorted(),
                "scopes_required": required.map(\.rawValue).sorted(),
                "can_send_scopes": canSend,
                "available_now": availableNow,
            ]
        }

        var jev: [String: Any] = [
            "role": "internal_fast_judgment",
            "summary": "Jev 是宿主侧快速判断服务，不是模型也不可被直接调用。host 用它排序 tool_search 候选、召回记忆、筛选超长工具输出、为子代理选模型、驱动 wm_run_goal 网页循环。出站契约见 api_mode（systemone=TypeSafe 原生，vercel_gateway=Vercel AI Gateway）。每个用途独立 off/shadow/active；off 零网络，shadow 只观测不改业务结果，active 需已验收固定模型版本。",
            "service": jevSettings.apiStyle.serviceIdentifier,
            "api_mode": jevSettings.apiStyle.statusValue,
            "model": jevSettings.modelConfigured ? jevSettings.activeModelVersion : NSNull(),
            "model_configured": jevSettings.modelConfigured,
            "key_configured": jevKeyConfigured,
            "settings_revision": jevSettings.revision,
            "pinned_model_version": jevSettings.pinnedModelVersion ?? NSNull(),
            "policy_version": jevSettings.policy.policyVersion,
            "coordinator": [
                "paused_for_auth": jevCoordinatorStatus.pausedForAuth,
                "cooldown_remaining_s": jevCoordinatorStatus.cooldownRemaining.map { Int($0) } ?? 0,
            ],
            "use_cases": useCases,
            "budget": [
                "per_turn_request_limit": jevSettings.policy.perTurnRequestBudget,
                "daily_request_limit": jevSettings.policy.dailyRequestBudget,
            ],
            "metrics": [
                "today_requests": jevMetrics.todayRequests,
                "today_request_bytes": jevMetrics.todayRequestBytes,
                "last24h_applied": jevMetrics.last24hApplied,
                "last24h_fallback": jevMetrics.last24hFallback,
                "last_error_reason": jevMetrics.lastErrorReason.map { $0 as Any } ?? NSNull(),
            ],
        ]
        if jevSettings.apiStyle == .systemone,
           jevSettings.activeModelVersion == "jev-latest" {
            jev["model_version_note"] = "jev-latest 不是已验收固定版本：配置为 active 的用途按 shadow 收口。"
        }
        if jevSettings.apiStyle == .vercelGateway, !jevSettings.modelConfigured {
            jev["model_version_note"] = "vercel_gateway 未配置模型：填写评估模型 slug（默认 typesafe-ai/jev）后才可出站。"
        }

        var tools: [String: Any] = [:]
        if let bridge = toolExposureBridge {
            tools["catalog_total"] = bridge.fullToolDeclarations().count
            tools["visible_now"] = bridge.visibleTools().count
            tools["lazy_mode"] = bridge.lazyModeEnabled()
            tools["deferred_note"] = "未列出的工具经 tool_search 命中后下一轮可见。"
        } else {
            tools["catalog_available"] = false
        }

        let imageGenerationConfigured = resolvedImageGenerationConfig() != nil
            || { if case .signedIn = codexImageConfig() { return true }; return false }()

        let runtime: [String: Any] = [
            "search_enabled": effectiveWebSearchEnabled,
            "exec_javascript_enabled": effectiveExecJavaScriptEnabled,
            "webmount_enabled": isWebMountRuntimeEnabled,
            "memory_tool_enabled": IOSMemoryToolExecutor.isEnabled(runtime: sharedSettings.agentRuntime),
            "image_generation_configured": imageGenerationConfigured,
            "local_tool_executor_available": localToolExecutor != nil,
            "mcp_network_allowed": isMcpNetworkAllowed(),
            "mcp_servers_enabled": mcpManager.servers.filter(\.enabled).count,
            "subagent_dispatch_enabled": isCapabilityPolicyEnabled("ios.agent.subagent_dispatch"),
            "subagent_dynamic_enabled": sharedSettings.agentRuntime.subAgent.allowDynamicSubAgents,
            "model_council_enabled": isCapabilityPolicyEnabled("ios.agent.model_council_run"),
            "miniapp_enabled": sharedSettings.agentRuntime.miniApp.enabled,
        ]

        return IOSWorkspaceStore.json([
            "ok": true,
            "tool": "runtime_status",
            "schema": 1,
            "platform": "ios",
            "runtime": runtime,
            "tools": tools,
            "jev": jev,
        ])
    }

    /// 用例的稳定 JSON 键（rawValue 是 camelCase，契约统一 snake_case）。
    private static func jevUseCaseStatusKey(_ useCase: IOSJevUseCase) -> String {
        switch useCase {
        case .toolDiscovery: "tool_discovery"
        case .memoryRecall: "memory_recall"
        case .contextSelection: "context_selection"
        case .modelRouting: "model_routing"
        case .webActions: "web_actions"
        }
    }

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
                bridge: toolExposureBridge,
                identity: IOSJevToolDiscoveryService.RunIdentity(
                    runId: pending.runId,
                    turnBudgetKey: IOSJevToolDiscoveryService.turnBudgetKey(runId: pending.runId)
                )
            )
        }
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        ))
    }

    private func executeSearchToolCall(_ pending: ChatPendingToolApproval) async -> ChatToolRuntimeResult {
        // Honor the global / high-risk auto-approve switches (Permissions page). When on,
        // skip the per-call approval card and dispatch directly.
        let autoApprove = effectiveGlobalAutoApproveEnabled
            || effectiveHighRiskAutoApproveEnabled
        if !autoApprove,
           let request = ChatToolApprovalRequestBuilder.search(
               for: pending.toolCall,
               reason: "网络搜索和网页读取会访问外部站点，需要你确认。",
               settings: sharedSettings.snapshot
           ) {
            return .waitingForApproval(.search(request))
        }

        let resultText = await dispatchSearchToolCall(pending.toolCall)
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages,
            conversationId: pending.conversationId
        ))
    }

    private func executeWorkspaceToolCall(_ pending: ChatPendingToolApproval) async -> ChatToolRuntimeResult {
        let output = await workspaceToolExecutionOutput(pending.toolCall, isUserInitiated: false)
        if case .needsUserAction(let reason) = output,
           let request = ChatToolApprovalRequestBuilder.workspace(
               for: pending.toolCall,
               reason: reason,
               localToolExecutor: localToolExecutor
           ) {
            return .waitingForApproval(.workspace(request))
        }

        let resultText = ChatToolOutputFormatter.workspaceResultText(for: pending.toolCall, output: output)
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        ))
    }

    private func executeIshToolCall(_ pending: ChatPendingToolApproval) async -> ChatToolRuntimeResult {
        let output = await ishToolExecutionOutput(
            pending.toolCall,
            isUserInitiated: isIshAutoApproved(
                toolName: pending.toolCall.toolName,
                input: pending.toolCall.input,
                runId: pending.runId,
                conversationId: pending.conversationId
            )
        )
        if case .needsUserAction(let reason) = output,
           let request = ChatToolApprovalRequestBuilder.ishHandoff(
               for: pending.toolCall,
               reason: reason,
               localToolExecutor: localToolExecutor,
               runId: pending.runId
           ) {
            return .waitingForApproval(.ish(request))
        }

        let resultText = ChatToolOutputFormatter.ishHandoffResultText(for: pending.toolCall, output: output)
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        ))
    }

    private func executeWebMountToolCall(_ pending: ChatPendingToolApproval) async -> ChatToolRuntimeResult {
        let output = await webMountToolExecutionOutput(
            pending.toolCall,
            isUserInitiated: false,
            runId: pending.runId,
            conversationId: pending.conversationId
        )
        if case .needsUserAction(let reason) = output,
           let request = ChatToolApprovalRequestBuilder.webMount(
               for: pending.toolCall,
               reason: reason,
               localToolExecutor: localToolExecutor,
               runId: pending.runId
           ) {
            return .waitingForApproval(.webMount(request))
        }

        let resultText = ChatToolOutputFormatter.webMountResultText(for: pending.toolCall, output: output)
        let messages = messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
        return output.isWebMountOutcomeUnknown ? .outcomeUnknown(messages) : .completed(messages)
    }

    private func executeMemoryToolCall(_ pending: ChatPendingToolApproval) -> ChatToolRuntimeResult {
        let writePolicy = memoryToolWritePolicy(input: pending.toolCall.input, isUserInitiated: false)
        if case .needsUserAction(let reason) = writePolicy,
           let request = ChatToolApprovalRequestBuilder.memory(for: pending.toolCall, reason: reason) {
            return .waitingForApproval(.memory(request))
        }

        let resultText = dispatchMemoryToolCall(pending.toolCall, writePolicy: writePolicy)
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        ))
    }

    private func executeImageToolCall(_ pending: ChatPendingToolApproval) async -> ChatToolRuntimeResult {
        let resultParts = await dispatchImageToolCall(pending.toolCall, messages: pending.baseMessages)
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputParts: resultParts,
            in: pending.baseMessages
        ))
    }

    private func executeAdvancedToolCall(
        _ pending: ChatPendingToolApproval,
        nestedTools: IOSJsSandboxTools? = nil,
        toolExposureBridge: IosToolExposureBridge? = nil,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot? = nil
    ) async -> ChatToolRuntimeResult {
        let toolName = pending.toolCall.toolName

        if IOSAppleAgentToolCatalog.pickerToolNames.contains(toolName) {
            guard isAdvancedToolEnabled(toolName) else {
                let output = IOSWorkspaceStore.json([
                    "ok": false,
                    "tool": toolName,
                    "status": "denied",
                    "denied": true,
                    "policy": "disabled",
                    "reason": "\(toolName) 未开启。请先在设置中启用对应能力。"
                ])
                return .completed(messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: output,
                    in: pending.baseMessages
                ))
            }
            let result = await IOSPersonalContextPickerCoordinator.shared.requestResult(
                toolName: toolName,
                input: pending.toolCall.input
            )
            return .completed(messagesByFinishingToolCall(
                pending.toolCall,
                outputParts: result.messageParts,
                in: pending.baseMessages
            ))
        }

        if IOSAppleAgentToolCatalog.approvalRequiredToolNames.contains(toolName),
           let request = ChatToolApprovalRequestBuilder.appleCapability(
               for: pending.toolCall,
               reason: appleCapabilityApprovalReason(toolName: toolName)
           ) {
            return .waitingForApproval(.mcp(request))
        }

        // Wave B2: `recipe__*` 通用前缀路由（§13.2.5 / §16.1）——镜像 mcp__*
        // 模式，单一路由不为每个 recipe 写分支。manifest 从「当前 round 的
        // registry snapshot」解析（in-flight pinning，不用 live store）；
        // snapshot 无此 recipe → 结构化错误（不崩、不静默）。mutation step
        // 走现有审批（invariant 11），在这里与 skill_import 同层拦截。
        if IOSDynamicToolRegistry.isDynamicWorkflowToolName(toolName) {
            guard let descriptor = recipeCatalogSnapshot?.recipeTools.first(where: { $0.toolId == toolName }) else {
                return .completed(messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: "此动态工具不在当前目录中；请先调用 tool_search 获取最新工具。",
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
            switch descriptor.implementation {
            case .recipe:
                return await executeRecipeToolCall(
                    pending,
                    snapshot: recipeCatalogSnapshot,
                    bridge: toolExposureBridge
                )
            case .javascript, .remote, .command:
                return await executePluginToolCall(
                    pending,
                    descriptor: descriptor,
                    bridge: toolExposureBridge
                )
            }
        }

        if toolName == IOSSoulToolCatalog.toolName {
            preparedSoulImportsForApproval.removeValue(forKey: pending.toolCall.toolCallId)
            do {
                let prepared = try soulService.prepareImport()
                guard let request = ChatToolApprovalRequestBuilder.extensionMutation(
                    for: pending.toolCall,
                    reason: "请核对 /workspace/SOUL.md 的核心指令变更；批准后会复核当前版本与候选 hash。",
                    soulImportPreview: SoulImportPreview(
                        baseHash: prepared.preview.baseHash,
                        candidateHash: prepared.preview.candidateHash,
                        changedLineCount: prepared.preview.changedLineCount,
                        diffPreview: prepared.preview.diffPreview,
                        afterSummary: prepared.preview.afterSummary
                    )
                ) else {
                    return .completed(messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: ChatToolOutputFormatter.toolFailureJSON(
                            toolName: toolName,
                            reason: "无法构造核心指令审批请求。",
                            status: "failed"
                        ),
                        in: pending.baseMessages
                    ))
                }
                if effectiveHighRiskAutoApproveEnabled {
                    let resultText = try soulService.applyPreparedImport(prepared)
                    return .completed(messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: resultText,
                        in: pending.baseMessages
                    ))
                }
                preparedSoulImportsForApproval[pending.toolCall.toolCallId] = prepared
                return .waitingForApproval(.mcp(request))
            } catch {
                return .completed(messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        if toolName == "mcp_import_from_skill" {
            preparedMcpImportsForApproval.removeValue(forKey: pending.toolCall.toolCallId)
            do {
                let prepared = try skillMcpToolService.prepareMcpImport(arguments: pending.toolCall.input)
                guard let request = ChatToolApprovalRequestBuilder.extensionMutation(
                    for: pending.toolCall,
                    reason: "请核对将导入的 MCP 服务；批准后会复核 digest、临时连通测试，再一次写入。",
                    mcpImportPreview: prepared.preview
                ) else {
                    return .completed(messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: ChatToolOutputFormatter.toolFailureJSON(
                            toolName: toolName,
                            reason: "无法构造 MCP 导入审批请求。",
                            status: "failed"
                        ),
                        in: pending.baseMessages
                    ))
                }
                if effectiveHighRiskAutoApproveEnabled {
                    let resultText = await skillMcpToolService.applyPreparedMcpImport(prepared) { [weak self] in
                        self?.isMcpNetworkAllowed() ?? false
                    }
                    return .completed(messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: resultText,
                        in: pending.baseMessages,
                        conversationId: pending.conversationId
                    ))
                }
                preparedMcpImportsForApproval[pending.toolCall.toolCallId] = prepared
                return .waitingForApproval(.mcp(request))
            } catch {
                return .completed(messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        // Provider 配置写入：高风险自动批准开启时沿用同一安全写入服务并跳过逐次审批。
        if toolName == "provider_config_apply" {
            if effectiveHighRiskAutoApproveEnabled {
                let resultText = await providerConfigToolService.execute(
                    toolName: toolName,
                    argumentsJSON: pending.toolCall.input
                )
                return .completed(messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: resultText,
                    in: pending.baseMessages,
                    conversationId: pending.conversationId
                ))
            }
            let request = McpToolApprovalRequest(
                id: ChatToolCallParsing.requestId(for: pending.toolCall),
                serverName: "local",
                toolName: toolName,
                argumentsPreview: IOSProviderConfigToolCatalog.redactedApprovalPreview(
                    argumentsJSON: pending.toolCall.input
                ),
                reason: IOSProviderConfigToolCatalog.approvalReason(
                    argumentsJSON: pending.toolCall.input
                )
            )
            return .waitingForApproval(.mcp(request))
        }

        // Theme pack import: try-on immediately, always show 套用/还原 (never skip the card).
        if toolName == "theme_pack_import" {
            do {
                let document = try themePackToolService.prepareImport(
                    argumentsJSON: pending.toolCall.input,
                    approval: AmberThemeTryOnApproval(
                        runId: pending.runId,
                        requestId: ChatToolCallParsing.requestId(for: pending.toolCall)
                    )
                )
                let request = McpToolApprovalRequest(
                    id: ChatToolCallParsing.requestId(for: pending.toolCall),
                    serverName: "local",
                    toolName: toolName,
                    argumentsPreview: IOSThemePackToolCatalog.argumentsPreview(for: document),
                    reason: IOSThemePackToolCatalog.approvalReason(
                        displayName: document.displayName,
                        replacesInstalled: AmberThemePackLibrary.shared.contains(id: document.id)
                    ),
                    themePackPreview: document
                )
                return .waitingForApproval(.mcp(request))
            } catch {
                return .completed(messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        if isMcpNetworkTool(toolName), !isMcpNetworkAllowed() {
            return .completed(messagesByFinishingToolCall(
                pending.toolCall,
                outputText: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolName,
                    reason: "MCP 调用已关闭。",
                    status: "denied"
                ),
                in: pending.baseMessages
            ))
        }

        if toolName == "skill_import" {
            preparedSkillImportsForApproval.removeValue(forKey: pending.toolCall.toolCallId)
            do {
                let prepared = try skillMcpToolService.prepareSkillImport(
                    arguments: pending.toolCall.input
                )
                guard let request = ChatToolApprovalRequestBuilder.extensionMutation(
                    for: pending.toolCall,
                    reason: "请核对候选 Skill 的文件变更；批准后会复核 CAS 并原子替换技能包。",
                    skillImportPreview: Self.mcpSkillImportPreview(from: prepared.preview)
                ) else {
                    return .completed(messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: ChatToolOutputFormatter.toolFailureJSON(
                            toolName: toolName,
                            reason: "无法构造 Skill 导入审批请求。",
                            status: "failed"
                        ),
                        in: pending.baseMessages
                    ))
                }
                if effectiveHighRiskAutoApproveEnabled {
                    let resultText = try skillMcpToolService.applyPreparedSkillImport(prepared)
                    return .completed(messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: resultText,
                        in: pending.baseMessages
                    ))
                }
                preparedSkillImportsForApproval[pending.toolCall.toolCallId] = prepared
                return .waitingForApproval(.mcp(request))
            } catch {
                return .completed(messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        if toolName == "recipe_import" {
            preparedRecipeImportsForApproval.removeValue(forKey: pending.toolCall.toolCallId)
            do {
                let prepared = try recipeToolService.prepareRecipeImport(
                    arguments: pending.toolCall.input
                )
                let request = RecipeToolApprovalRequestBuilder.importRequest(
                    for: pending.toolCall,
                    prepared: prepared
                )
                if effectiveHighRiskAutoApproveEnabled {
                    let resultText = try await recipeToolService.applyPreparedRecipeImport(prepared)
                    return .completed(messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: resultText,
                        in: pending.baseMessages
                    ))
                }
                preparedRecipeImportsForApproval[pending.toolCall.toolCallId] = prepared
                return .waitingForApproval(.recipe(request))
            } catch {
                return .completed(messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        if toolName == "plugin_test" {
            do {
                let test = try pluginToolService.preparePluginTest(arguments: pending.toolCall.input)
                if case .recipe = test.descriptor.implementation {
                    return await executeRecipeToolCall(
                        pending, snapshot: nil, bridge: toolExposureBridge,
                        candidate: test.descriptor, argumentsJSON: test.argumentsJSON,
                        candidateTest: test.context
                    )
                }
                return await executePluginToolCall(
                    pending, descriptor: test.descriptor, bridge: toolExposureBridge,
                    argumentsJSON: test.argumentsJSON, candidateTest: test.context
                )
            } catch {
                return .completed(messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName, reason: error.localizedDescription, status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        if toolName == "plugin_import" {
            preparedPluginImportsForApproval.removeValue(forKey: pending.toolCall.toolCallId)
            do {
                let prepared = try pluginToolService.preparePluginImport(arguments: pending.toolCall.input)
                let request = RecipeToolApprovalRequestBuilder.pluginImportRequest(
                    for: pending.toolCall,
                    prepared: prepared
                )
                // Agent-authored packages are never self-approved, including
                // when high-risk auto approve is enabled.
                preparedPluginImportsForApproval[pending.toolCall.toolCallId] = prepared
                return .waitingForApproval(.recipe(request))
            } catch {
                return .completed(messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        let highRiskWorkflow = IOSRecipeToolCatalog.highRiskToolNames.contains(toolName)
            || IOSPluginToolCatalog.highRiskToolNames.contains(toolName)
        if highRiskWorkflow,
           !effectiveHighRiskAutoApproveEnabled,
           let request = ChatToolApprovalRequestBuilder.extensionMutation(
               for: pending.toolCall,
               reason: "该操作会替换或移除本机工作流包与回退版本，需要你确认。"
           ) {
            return .waitingForApproval(.mcp(request))
        }

        let mutatingWorkflow = IOSRecipeToolCatalog.mutatingToolNames.contains(toolName)
            || IOSPluginToolCatalog.mutatingToolNames.contains(toolName)
        if mutatingWorkflow,
           !effectiveGlobalAutoApproveEnabled,
           !effectiveHighRiskAutoApproveEnabled,
           let request = ChatToolApprovalRequestBuilder.extensionMutation(
               for: pending.toolCall,
               reason: "将修改本机工作流的启用状态，需要你确认。"
           ) {
            return .waitingForApproval(.mcp(request))
        }

        // MCP calls and MCP management can access remote services or import
        // connection configuration. Ordinary global auto-approve must not cross
        // this high-risk boundary.
        let highRiskMcp = toolName == "mcp_call"
            || ToolKt.isExpandedMcpToolName(name: toolName)
            || IOSMcpManagementToolCatalog.highRiskToolNames.contains(toolName)
        if highRiskMcp, !effectiveHighRiskAutoApproveEnabled {
            let request: McpToolApprovalRequest?
            if toolName == "mcp_call" {
                request = ChatToolApprovalRequestBuilder.mcp(
                    for: pending.toolCall,
                    reason: "MCP 工具可能访问外部服务或执行远端操作，需要你确认。"
                )
            } else if ToolKt.isExpandedMcpToolName(name: toolName),
                      let target = resolvedMcpTarget(forExpandedName: toolName) {
                // P0-b: flattened calls carry the tool's own arguments; the
                // approval card resolves server/tool from the directory —
                // same gate and resume path as mcp_call.
                request = ChatToolApprovalRequestBuilder.expandedMcp(
                    for: pending.toolCall,
                    server: target.server,
                    tool: target.tool,
                    reason: "MCP 工具可能访问外部服务或执行远端操作，需要你确认。"
                )
            } else {
                request = ChatToolApprovalRequestBuilder.extensionMutation(
                    for: pending.toolCall,
                    reason: "MCP 管理操作可能访问外部服务或写入连接配置，需要你确认。"
                )
            }
            if let request {
                return .waitingForApproval(.mcp(request))
            }
        }

        let mutatingSkill = IOSSkillToolCatalog.mutatingToolNames.contains(pending.toolCall.toolName)
        if mutatingSkill,
           !effectiveGlobalAutoApproveEnabled,
           !effectiveHighRiskAutoApproveEnabled,
           let request = ChatToolApprovalRequestBuilder.extensionMutation(
               for: pending.toolCall,
               reason: "将写入本机 Skill 或 MCP 配置，需要你确认。"
           ) {
            return .waitingForApproval(.mcp(request))
        }

        if pending.toolCall.toolName == "model_council_run",
           requiresCouncilApproval,
           let request = ChatToolApprovalRequestBuilder.council(
               for: pending.toolCall,
               reason: "模型议会会发起多次模型请求，需要你确认。"
           ) {
            return .waitingForApproval(.council(request))
        }

        let resultText = await dispatchAdvancedToolCall(
            pending.toolCall,
            providerSetting: pending.providerSetting,
            params: pending.params,
            runId: pending.runId,
            conversationId: pending.conversationId,
            nestedTools: nestedTools,
            toolExposureBridge: toolExposureBridge
        )
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages,
            conversationId: pending.conversationId
        ))
    }

    // MARK: - Wave B2: `recipe__*` generic route (§13.2.5 / §16.1 / §10.3)

    private func executePluginToolCall(
        _ pending: ChatPendingToolApproval,
        descriptor: IOSDynamicRecipeToolDescriptor,
        bridge: IosToolExposureBridge?,
        argumentsJSON: String? = nil,
        candidateTest: IOSPluginTestContext? = nil
    ) async -> ChatToolRuntimeResult {
        let invocationArguments = argumentsJSON ?? pending.toolCall.input
        guard descriptor.pluginId != nil else {
            return .completed(messagesByFinishingToolCall(
                pending.toolCall,
                outputText: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: "动态工具缺少插件归属。",
                    status: "failed"
                ),
                in: pending.baseMessages
            ))
        }
        if let issue = pluginInputIssue(invocationArguments, matches: descriptor) {
            return .completed(messagesByFinishingToolCall(
                pending.toolCall,
                outputText: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: issue,
                    status: "failed"
                ),
                in: pending.baseMessages
            ))
        }

        let autoApproved: Bool
        var argumentsPreview = recipeArgumentsPreview(invocationArguments)
        if case .command(let source) = descriptor.implementation {
            do {
                if let reason = pluginCommandAvailabilityIssue(source) {
                    throw IOSPluginCommandError.unavailable(reason)
                }
                let invocation = try IOSPluginCommandBuilder.build(
                    source: source.source, manifest: source.manifest,
                    inputObject: ChatToolCallParsing.jsonObject(invocationArguments) ?? [:],
                    timeoutMs: descriptor.timeoutMs
                )
                autoApproved = isIshToolAutoApproved(
                    toolName: invocation.toolName, input: invocation.argumentsJSON,
                    runId: pending.runId, conversationId: pending.conversationId
                )
                argumentsPreview = recipeArgumentsPreview(invocation.argumentsJSON)
            } catch {
                return .completed(messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName, reason: error.localizedDescription, status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        } else {
            autoApproved = pluginRequiresHighRiskApproval(descriptor)
                ? effectiveHighRiskAutoApproveEnabled
                : (effectiveGlobalAutoApproveEnabled || effectiveHighRiskAutoApproveEnabled)
        }
        if descriptor.effectClassRawValue != IOSToolEffectClass.pure.rawValue, !autoApproved {
            let capabilities = pluginInvocationCapabilities(descriptor)
            preparedPluginInvocationsForApproval[pending.toolCall.toolCallId] = IOSPreparedPluginInvocation(
                descriptor: descriptor,
                argumentsJSON: invocationArguments,
                candidateTest: candidateTest
            )
            let payload = PluginInvocationApprovalPayload(
                toolId: descriptor.toolId,
                handler: (candidateTest == nil ? "" : "试运行 · ") + pluginHandlerTitle(descriptor.implementation),
                argumentsPreview: argumentsPreview,
                effectClass: IOSToolEffectClass(rawValue: descriptor.effectClassRawValue) ?? .sideEffect,
                capabilities: capabilities
            )
            return .waitingForApproval(.recipe(
                RecipeToolApprovalRequestBuilder.pluginInvocationRequest(
                    for: pending.toolCall,
                    pluginId: descriptor.pluginId ?? descriptor.recipeName,
                    pluginVersion: descriptor.version,
                    payload: payload
                )
            ))
        }

        let output = await executePinnedPlugin(
            descriptor: descriptor,
            argumentsJSON: invocationArguments,
            context: pending,
            bridge: bridge,
            isUserInitiated: autoApproved,
            candidateTest: candidateTest
        )
        let messages = messagesByFinishingToolCall(
            pending.toolCall,
            outputText: output,
            in: pending.baseMessages
        )
        return Self.isPluginOutcomeUnknown(output)
            ? .outcomeUnknown(messages)
            : .completed(messages)
    }

    private func executeBackgroundPlugin(
        descriptor: IOSDynamicRecipeToolDescriptor,
        argumentsJSON: String,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        conversationId: KotlinUuid?,
        bridge: IosToolExposureBridge?,
        executionPolicy: IOSExecutionPolicySnapshot?
    ) async -> IOSAgentToolOutcome {
        guard descriptor.isBackgroundEligible else {
            return .denied("该插件处理器未获后台只读执行许可。")
        }
        if let issue = pluginInputIssue(argumentsJSON, matches: descriptor) {
            return .filled(ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: issue,
                status: "failed"
            ))
        }
        let toolCall = UIMessagePart.Tool(
            toolCallId: "background-plugin-\(UUID().uuidString)",
            toolName: descriptor.toolId,
            input: argumentsJSON,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let context = ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: providerSetting,
            params: params,
            runId: runId,
            startedAt: Int64(Date().timeIntervalSince1970 * 1_000),
            inputDigest: chatInputDigest(for: argumentsJSON),
            conversationId: conversationId,
            baseMessages: [],
            executionPolicy: executionPolicy
        )
        switch descriptor.implementation {
        case .javascript, .command:
            return .denied("脚本和本地命令插件不在后台白名单中。")
        case .remote:
            let output = await executePinnedPlugin(
                descriptor: descriptor,
                argumentsJSON: argumentsJSON,
                context: context,
                bridge: bridge,
                isUserInitiated: false
            )
            let part = UIMessagePart.Text(text: output, metadata: nil)
            return Self.isPluginOutcomeUnknown(output) ? .outcomeUnknown([part]) : .filled(output)
        case .recipe(let manifest):
            let inputs: [String: IOSRecipeJSONValue]
            do {
                let decoded = try JSONDecoder().decode(
                    IOSRecipeJSONValue.self,
                    from: Data(argumentsJSON.utf8)
                )
                guard case .object(let object) = decoded else {
                    return .filled(ChatToolOutputFormatter.toolFailureJSON(
                        toolName: descriptor.toolId,
                        reason: "Recipe 插件参数必须是 JSON 对象。",
                        status: "failed"
                    ))
                }
                inputs = object
            } catch {
                return .filled(ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptor.toolId,
                    reason: "Recipe 插件参数无法解析。",
                    status: "failed"
                ))
            }
            let runner = IOSRecipeRunner(
                manifest: manifest,
                artifactId: descriptor.toolId,
                catalog: IOSDynamicToolRegistry.primitiveCatalogEntry,
                executePrimitive: { [weak self] tool, argsJSON in
                    guard let self else { throw CancellationError() }
                    switch await self.executeRecipePrimitiveStep(
                        tool: tool,
                        argsJSON: argsJSON,
                        isUserInitiated: false,
                        context: context,
                        bridge: bridge
                    ) {
                    case .output(let text): return text
                    case .failure(let reason), .needsApproval(let reason):
                        throw IOSRecipeRunError.stepFailed(stepId: "", tool: tool, message: reason)
                    case .outcomeUnknown(let text):
                        throw IOSRecipePrimitiveOutcomeUnknownError(outputText: text)
                    }
                },
                ledger: ledger,
                runId: runId
            )
            let outcome = await runner.run(inputs: inputs)
            switch outcome {
            case .succeeded(let outputs, let completedSteps):
                let output = recipeResultJSON(outputs: outputs, completedSteps: completedSteps)
                _ = pluginHealthStore.recordSuccess(
                    pluginId: descriptor.pluginId ?? descriptor.recipeName,
                    packageHash: descriptor.manifestHash
                )
                return .filled(output)
            case .failed(_, let error, _):
                let output = runner.structuredErrorJSON(for: outcome)
                    ?? ChatToolOutputFormatter.toolFailureJSON(
                        toolName: descriptor.toolId,
                        reason: "后台 Recipe 插件执行失败。",
                        status: "failed"
                    )
                let kind: IOSPluginDiagnosticKind?
                switch error {
                case .stepTimeout: kind = .timeout
                case .outputResolution: kind = .schema
                case .stepFailed: kind = .exception
                case .planInvalid, .inputInvalid, .argumentBinding: kind = nil
                }
                if let pluginId = descriptor.pluginId, let kind {
                    let transition = pluginHealthStore.recordFailure(
                        pluginId: pluginId,
                        packageHash: descriptor.manifestHash,
                        toolId: descriptor.toolId,
                        kind: kind,
                        detail: output
                    )
                    if transition.didQuarantine { _ = await recipeRegistry.refresh() }
                }
                return .filled(output)
            }
        }
    }

    func finishPluginInvocationApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        prepared: IOSPreparedPluginInvocation?,
        toolExposureBridge: IosToolExposureBridge?
    ) async -> [UIMessage] {
        recordToolApproval(
            capabilityId: "ios.agent.plugin_execution",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved plugin invocation." : "User denied plugin invocation.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        let output: String
        if !allow {
            output = ChatToolOutputFormatter.toolFailureJSON(
                toolName: pending.toolCall.toolName,
                reason: "用户拒绝执行插件工具。",
                denied: true
            )
        } else if let prepared,
                  pluginInputIssue(prepared.argumentsJSON ?? pending.toolCall.input, matches: prepared.descriptor) == nil {
            output = await executePinnedPlugin(
                descriptor: prepared.descriptor,
                argumentsJSON: prepared.argumentsJSON ?? pending.toolCall.input,
                context: pending,
                bridge: toolExposureBridge,
                isUserInitiated: true,
                candidateTest: prepared.candidateTest
            )
        } else {
            output = ChatToolOutputFormatter.toolFailureJSON(
                toolName: pending.toolCall.toolName,
                reason: "插件执行上下文已失效，请重新发起调用。",
                status: "failed"
            )
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: output,
            in: pending.baseMessages
        )
    }

    private func executePinnedPlugin(
        descriptor: IOSDynamicRecipeToolDescriptor,
        argumentsJSON: String,
        context: ChatPendingToolApproval,
        bridge: IosToolExposureBridge?,
        isUserInitiated: Bool,
        candidateTest: IOSPluginTestContext? = nil
    ) async -> String {
        let output = await executePinnedPluginBody(
            descriptor: descriptor,
            argumentsJSON: argumentsJSON,
            context: context,
            bridge: bridge,
            isUserInitiated: isUserInitiated
        )
        if let candidateTest { return candidateTest.resultJSON(output) }
        await recordPluginHealth(output: output, descriptor: descriptor)
        return output
    }

    private func executePinnedPluginBody(
        descriptor: IOSDynamicRecipeToolDescriptor,
        argumentsJSON: String,
        context: ChatPendingToolApproval,
        bridge: IosToolExposureBridge?,
        isUserInitiated: Bool
    ) async -> String {
        switch descriptor.implementation {
        case .recipe:
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: "Recipe 插件处理器进入了错误的执行路径。",
                status: "failed"
            )
        case .javascript(let source, let hostTools):
            guard let broker = descriptor.capabilityBroker else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptor.toolId,
                    reason: "插件能力 Broker 不可用。",
                    status: "failed"
                )
            }
            let hostCallState = IOSPluginHostCallState()
            let toolDescriptions = Dictionary(uniqueKeysWithValues: hostTools.map { ($0, "插件声明的主机工具") })
            let tools = IOSJsSandboxTools(
                availableToolNames: hostTools.sorted(),
                hostCall: { [weak self] tool, argsJSON in
                    guard let self else {
                        hostCallState.fail("插件运行时已释放。")
                        return nil
                    }
                    if let reason = broker.authorize(tool: tool, argumentsJSON: argsJSON) {
                        NSLog("[IOSPluginRuntime] capability denied plugin=\(broker.pluginId) tool=\(tool): \(reason)")
                        hostCallState.fail("主机工具 \(tool) 被能力代理拒绝：\(reason)")
                        return nil
                    }
                    hostCallState.markStarted()
                    switch await self.executeRecipePrimitiveStep(
                        tool: tool,
                        argsJSON: argsJSON,
                        isUserInitiated: isUserInitiated,
                        context: context,
                        bridge: bridge
                    ) {
                    case .output(let text): return text
                    case .failure(let reason):
                        hostCallState.fail("主机工具 \(tool) 失败：\(reason)")
                        return nil
                    case .needsApproval(let reason):
                        hostCallState.fail("主机工具 \(tool) 仍需批准：\(reason)")
                        return nil
                    case .outcomeUnknown(let reason):
                        hostCallState.fail(
                            "主机工具 \(tool) 的结果未知：\(reason)",
                            mayHaveApplied: true
                        )
                        return nil
                    }
                },
                toolDescriptions: toolDescriptions
            )
            guard let inputLiteral = Self.javascriptStringLiteral(argumentsJSON) else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptor.toolId,
                    reason: "插件参数无法安全注入脚本。",
                    status: "failed"
                )
            }
            let wrapped = """
            (function () {
              'use strict';
              const input = JSON.parse(\(inputLiteral));
              return (function (input) {
            \(source)
              })(input);
            })()
            """
            let result = await jsSandboxEngine.evaluate(
                code: wrapped,
                timeoutMs: descriptor.timeoutMs,
                maxOutputChars: descriptor.maxOutputChars,
                tools: tools,
                store: nil,
                restrictedPluginMode: true
            )
            let hostState = hostCallState.snapshot()
            if let failure = hostState.failure {
                return pluginHostFailurePayload(failure, descriptor: descriptor)
            }
            switch result {
            case .success(let raw, let logs):
                return pluginOutputPayload(
                    rawJSON: raw,
                    logs: logs,
                    descriptor: descriptor
                )
            case .failure(let message):
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptor.toolId,
                    reason: "插件脚本失败：\(message)",
                    status: "failed"
                )
            case .timedOut(let timeoutMs):
                if hostState.started,
                   descriptor.effectClassRawValue == IOSToolEffectClass.sideEffect.rawValue {
                    return pluginHostFailurePayload(
                        IOSPluginHostCallFailure(
                            reason: "插件脚本在主机操作开始后超时，结果无法确认。",
                            mayHaveApplied: true
                        ),
                        descriptor: descriptor
                    )
                }
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptor.toolId,
                    reason: "插件脚本在 \(timeoutMs) ms 后超时；本次结果已丢弃。",
                    status: "timeout"
                )
            }
        case .command(let source):
            do {
                if let reason = pluginCommandAvailabilityIssue(source) {
                    throw IOSPluginCommandError.unavailable(reason)
                }
                let invocation = try IOSPluginCommandBuilder.build(
                    source: source.source, manifest: source.manifest,
                    inputObject: ChatToolCallParsing.jsonObject(argumentsJSON) ?? [:],
                    timeoutMs: descriptor.timeoutMs
                )
                let call = UIMessagePart.Tool(
                    toolCallId: "plugin-command-\(UUID().uuidString)",
                    toolName: invocation.toolName, input: invocation.argumentsJSON,
                    output: [], approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil, metadata: nil
                )
                let output = await ishToolExecutionOutput(call, isUserInitiated: isUserInitiated)
                let text = ChatToolOutputFormatter.ishHandoffResultText(for: call, output: output)
                // Preserve stderr, exit status and unknown-after-action markers
                // so the author can diagnose failures without unsafe retries.
                if ChatToolCallParsing.jsonObject(text)?["ok"] as? Bool == false { return text }
                let raw = try IOSPluginCommandBuilder.parseOutput(text, outputType: descriptor.outputType)
                return pluginOutputPayload(rawJSON: raw, logs: [], descriptor: descriptor)
            } catch {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptor.toolId, reason: error.localizedDescription, status: "failed"
                )
            }
        case .remote(let remote):
            return await executePluginRemote(
                remote,
                descriptor: descriptor,
                argumentsJSON: argumentsJSON
            )
        }
    }

    private func recordPluginHealth(
        output: String,
        descriptor: IOSDynamicRecipeToolDescriptor
    ) async {
        guard let pluginId = descriptor.pluginId,
              let object = ChatToolCallParsing.jsonObject(output) else { return }
        if object["ok"] as? Bool == true {
            _ = pluginHealthStore.recordSuccess(pluginId: pluginId, packageHash: descriptor.manifestHash)
            return
        }
        let status = object["status"] as? String ?? ""
        let errorCode = object["error_code"] as? String ?? ""
        let reason = (object["reason"] as? String) ?? (object["error"] as? String) ?? "插件运行失败。"
        let kind: IOSPluginDiagnosticKind?
        if status == "timeout" || status == "timed_out" || errorCode == "step_timeout" || reason.localizedCaseInsensitiveContains("超时") {
            kind = .timeout
        } else if errorCode == "output_resolution" || reason.contains("输出不符合") || reason.contains("输出超过") {
            kind = .schema
        } else if reason.contains("插件脚本失败") {
            kind = .exception
        } else if reason.contains("远端插件") {
            kind = .remote
        } else if case .command = descriptor.implementation,
                  status == "failed",
                  object["runtime"] as? String != nil {
            kind = .exception
        } else {
            kind = nil
        }
        guard let kind else { return }
        let transition = pluginHealthStore.recordFailure(
            pluginId: pluginId,
            packageHash: descriptor.manifestHash,
            toolId: descriptor.toolId,
            kind: kind,
            detail: reason
        )
        if transition.didQuarantine {
            NSLog("[IOSPluginRuntime] quarantined plugin=\(pluginId) hash=\(descriptor.manifestHash)")
            _ = await recipeRegistry.refresh()
        }
    }

    private func pluginRequiresHighRiskApproval(
        _ descriptor: IOSDynamicRecipeToolDescriptor
    ) -> Bool {
        switch descriptor.implementation {
        case .recipe:
            return false
        case .command:
            return true
        case .remote:
            return descriptor.effectClassRawValue == IOSToolEffectClass.sideEffect.rawValue
        case .javascript(_, let hostTools):
            return hostTools.contains { tool in
                IOSCapabilityRegistry.capability(forToolName: tool)?.risk == .high
            }
        }
    }

    private func pluginHostFailurePayload(
        _ failure: IOSPluginHostCallFailure,
        descriptor: IOSDynamicRecipeToolDescriptor
    ) -> String {
        IOSWorkspaceStore.json([
            "ok": false,
            "tool": descriptor.toolId,
            "status": failure.mayHaveApplied ? "outcome_unknown" : "failed",
            "reason": failure.reason,
            "may_have_applied": failure.mayHaveApplied,
            "retry_safe": !failure.mayHaveApplied,
        ])
    }

    private func executePluginRemote(
        _ remote: IOSPluginRemoteManifest,
        descriptor: IOSDynamicRecipeToolDescriptor,
        argumentsJSON: String
    ) async -> String {
        guard let arguments = ChatToolCallParsing.jsonObject(argumentsJSON) else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: "远端插件参数必须是 JSON 对象。",
                status: "failed"
            )
        }
        var requestMayHaveApplied = false
        do {
            let raw: String
            switch remote.kind {
            case .mcp:
                guard let server = remote.server, let tool = remote.tool else {
                    throw IOSPluginRuntimeError.invalidRemoteDefinition
                }
                guard isMcpNetworkAllowed() else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: descriptor.toolId,
                        reason: "MCP 当前未启用。",
                        status: "failed"
                    )
                }
                requestMayHaveApplied = descriptor.effectClassRawValue == IOSToolEffectClass.sideEffect.rawValue
                raw = try await mcpManager.callTool(
                    serverName: server,
                    toolName: tool,
                    arguments: arguments,
                    enabledOverride: isMcpNetworkAllowed()
                )
            case .openapi:
                guard let rawURL = remote.url, var components = URLComponents(string: rawURL) else {
                    throw IOSPluginRuntimeError.invalidRemoteDefinition
                }
                let method = remote.method ?? "GET"
                if method == "GET" || method == "HEAD" {
                    let additions = try arguments.keys.sorted().map { key -> URLQueryItem in
                        URLQueryItem(name: key, value: try Self.queryValue(arguments[key]))
                    }
                    components.queryItems = (components.queryItems ?? []) + additions
                }
                guard let url = components.url else { throw IOSPluginRuntimeError.invalidRemoteDefinition }
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.timeoutInterval = TimeInterval(descriptor.timeoutMs) / 1_000
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                if method != "GET" && method != "HEAD" {
                    let body = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
                    guard body.count <= IOSPluginLimits.maxFileBytes else {
                        throw IOSPluginRuntimeError.requestTooLarge
                    }
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = TimeInterval(descriptor.timeoutMs) / 1_000
                let validated = try IOSSearchExecutor.allowedPublicHTTPURL(from: url.absoluteString)
                guard let host = validated.host else { throw IOSPluginRuntimeError.invalidRemoteDefinition }
                let addresses = try await Task.detached(priority: .userInitiated) {
                    try IOSSearchExecutor.resolveIPAddresses(host)
                }.value
                guard !addresses.isEmpty, addresses.allSatisfy(IOSSearchExecutor.publicHostAllowed) else {
                    throw IOSSearchExecutorError.disallowedURL("plugin endpoint resolves to a non-public address")
                }
                let loader = IOSBoundedPublicURLSessionLoader(
                    configuration: configuration,
                    maximumResponseBytes: descriptor.maxOutputChars * 4,
                    requiresHTTPS: true,
                    resolveHost: IOSSearchExecutor.resolveIPAddresses,
                    allowedRedirectDomains: descriptor.capabilityBroker?.capabilities.networkDomains
                )
                requestMayHaveApplied = descriptor.effectClassRawValue == IOSToolEffectClass.sideEffect.rawValue
                let (http, data) = try await loader.load(request)
                guard (200..<300).contains(http.statusCode) else {
                    throw IOSPluginRuntimeError.httpStatus(http.statusCode)
                }
                raw = data.isEmpty ? "null" : (String(data: data, encoding: .utf8) ?? "")
            }
            return pluginOutputPayload(rawJSON: raw, logs: [], descriptor: descriptor)
        } catch {
            if requestMayHaveApplied, !Self.isMcpLocalPreflightFailure(error) {
                return pluginHostFailurePayload(
                    IOSPluginHostCallFailure(
                        reason: "远端插件请求发出后失败，服务端结果无法确认：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)",
                        mayHaveApplied: true
                    ),
                    descriptor: descriptor
                )
            }
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: "远端插件调用失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)",
                status: "failed"
            )
        }
    }

    private static func isMcpLocalPreflightFailure(_ error: Error) -> Bool {
        if error is IOSMcpManagerError { return true }
        guard let error = error as? IOSMcpClientError else { return false }
        switch error {
        case .invalidURL, .unsafeEndpoint, .serverNotFound, .serverDisabled,
             .toolNotFound, .toolDisabled, .notConnected:
            return true
        case .httpStatus, .mcpSessionExpired, .invalidResponse, .rpcError,
             .requestTimedOut, .unsupportedContent:
            return false
        }
    }

    private static func isPluginOutcomeUnknown(_ output: String) -> Bool {
        guard let object = ChatToolCallParsing.jsonObject(output) else { return false }
        return (object["status"] as? String == "outcome_unknown"
            || object["status"] as? String == "unknown_after_action")
            && object["may_have_applied"] as? Bool == true
    }

    func isPluginOutcomeUnknown(in messages: [UIMessage], toolCallId: String) -> Bool {
        for message in messages where message.role == MessageRole.assistant {
            for case let tool as UIMessagePart.Tool in message.parts
            where tool.toolCallId == toolCallId {
                for case let text as UIMessagePart.Text in tool.output
                where Self.isPluginOutcomeUnknown(text.text) {
                    return true
                }
            }
        }
        return false
    }

    private func pluginOutputPayload(
        rawJSON: String,
        logs: [String],
        descriptor: IOSDynamicRecipeToolDescriptor
    ) -> String {
        guard let data = rawJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let typedValue = try? JSONDecoder().decode(IOSRecipeJSONValue.self, from: data) else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: "插件输出不是合法 JSON。",
                status: "failed"
            )
        }
        let outputIssues = IOSPluginJSONSchema.legacyOutputSchema(from: descriptor.outputType).validateValue(typedValue)
            + (descriptor.outputSchema?.validateValue(typedValue) ?? [])
        if let issue = outputIssues.first {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: "插件输出不符合声明：\(issue)",
                status: "failed"
            )
        }
        let object: [String: Any] = ["ok": true, "result": value, "logs": logs]
        guard let payload = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: payload, encoding: .utf8),
              text.count <= descriptor.maxOutputChars else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: "插件输出超过 \(descriptor.maxOutputChars) 字符上限。",
                status: "failed"
            )
        }
        return text
    }

    private func pluginInputIssue(
        _ raw: String,
        matches descriptor: IOSDynamicRecipeToolDescriptor
    ) -> String? {
        guard let value = try? JSONDecoder().decode(IOSRecipeJSONValue.self, from: Data(raw.utf8)),
              case .object = value else { return "插件参数必须是合法的 JSON 对象。" }
        let schema = descriptor.inputSchema
            ?? IOSPluginJSONSchema.legacyInputSchema(from: descriptorInputTypes(descriptor))
        return schema.validateValue(value).first.map { "插件参数不符合声明：\($0)" }
    }

    private func descriptorInputTypes(_ descriptor: IOSDynamicRecipeToolDescriptor) -> [String: IOSRecipeInputType] {
        switch descriptor.implementation {
        case .recipe(let manifest): manifest.inputs
        case .javascript, .remote, .command:
            (try? JSONDecoder().decode(
                [String: IOSRecipeInputType].self,
                from: Data(descriptor.inputsJSON.utf8)
            )) ?? [:]
        }
    }

    private func pluginInvocationCapabilities(_ descriptor: IOSDynamicRecipeToolDescriptor) -> [String] {
        switch descriptor.implementation {
        case .recipe: []
        case .javascript(_, let hostTools): hostTools.sorted()
        case .command(let source): [source.manifest.runtime.permissionSummary, "入口：\(source.manifest.entry)"]
        case .remote(let remote):
            switch remote.kind {
            case .mcp: ["MCP \(remote.server ?? "?")/\(remote.tool ?? "?")"]
            case .openapi: ["\(remote.method ?? "GET") \(remote.url ?? "?")"]
            }
        }
    }

    private func pluginHandlerTitle(_ implementation: IOSPluginToolImplementation) -> String {
        switch implementation {
        case .recipe: "Recipe"
        case .javascript: "受限 JavaScript"
        case .command(let source): source.manifest.runtime.title
        case .remote(let remote): remote.kind == .mcp ? "MCP 适配" : "OpenAPI 适配"
        }
    }

    private static func javascriptStringLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func pluginCommandAvailabilityIssue(_ source: IOSPluginCommandSource) -> String? {
        if source.manifest.runtime == .amberShell, source.manifest.entry.hasSuffix(".py"),
           !IOSAmberShellEngine.supportedCommands.contains("python") {
            return "当前构建未包含 AmberShell Python，无法执行该 .py 插件入口。"
        }
        #if !ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
        if source.manifest.runtime == .ish {
            return "当前构建未包含嵌入 iSH；该插件需要 ExperimentalGPL 运行环境。"
        }
        #endif
        return nil
    }

    private static func queryValue(_ value: Any?) throws -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// One `recipe__<name>` call, resolved against the ROUND's pinned catalog
    /// snapshot (never the live store): the manifest for execution is the
    /// snapshot's immutable copy, so a promotion/rollback during the call
    /// cannot retarget it (§13.3). Steps run through the EXISTING per-tool
    /// execution paths (no duplicated tool implementations); a mutation step
    /// pauses the whole call at the existing approval machinery (invariant 11).
    private func executeRecipeToolCall(
        _ pending: ChatPendingToolApproval,
        snapshot: IOSDynamicToolCatalogSnapshot?,
        bridge: IosToolExposureBridge?,
        candidate: IOSDynamicRecipeToolDescriptor? = nil,
        argumentsJSON: String? = nil,
        candidateTest: IOSPluginTestContext? = nil
    ) async -> ChatToolRuntimeResult {
        let toolName = pending.toolCall.toolName
        let recipeCallFailure = { (reason: String) -> ChatToolRuntimeResult in
            .completed(self.messagesByFinishingToolCall(
                pending.toolCall,
                outputText: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolName,
                    reason: reason,
                    status: "failed"
                ),
                in: pending.baseMessages
            ))
        }

        // At most one recipe pause can be live per process; any checkpoint
        // file on disk at the start of a new execution is an orphan from a
        // crashed pause (cold-start recovery terminates approvals fail-closed,
        // so it is never resumed — sweep instead of resurrecting).
        recipeExecutionCheckpointStore.sweepOrphans()

        // Fail closed: the round's snapshot does not declare this recipe
        // (rolled back, or the model used a stale name). Never execute from
        // the live store — a call the model saw must match what it saw.
        guard let descriptor = candidate ?? snapshot?.recipeTools.first(where: { $0.toolId == toolName }) else {
            return recipeCallFailure("此 Recipe 不在当前工具目录中（可能已被回退或版本已更新）。请先调用 tool_search 获取最新工具。")
        }
        guard case .recipe(let recipeManifest) = descriptor.implementation else {
            return recipeCallFailure("动态工具处理器类型不匹配，请刷新工具目录后重试。")
        }
        guard preparedRecipeExecutions[pending.toolCall.toolCallId] == nil else {
            // Continuations go through the finisher, never through a second
            // dispatch of the same call; a re-entry is a stale round.
            return recipeCallFailure("此 Recipe 调用已在审批中，请先在审批卡上确认。")
        }

        let inputs: [String: IOSRecipeJSONValue]
        do {
            let value = try JSONDecoder().decode(IOSRecipeJSONValue.self, from: Data((argumentsJSON ?? pending.toolCall.input).utf8))
            guard case .object(let object) = value else {
                return recipeCallFailure("Recipe 调用参数必须是 JSON 对象。")
            }
            inputs = object
        } catch {
            return recipeCallFailure("Recipe 调用参数不是合法的 JSON：\(error.localizedDescription)")
        }

        let runner = makeRecipeRunner(manifest: recipeManifest, context: pending, bridge: bridge)
        let plan: IOSRecipeExecutionPlan
        do {
            plan = try runner.resolvePlan(inputs: inputs)
        } catch let error as IOSRecipeRunError {
            await recordRecipeLevelFinished(
                recipeName: descriptor.recipeName,
                recipeVersion: descriptor.version,
                executionId: "recipe-\(UUID().uuidString)",
                outcome: "failed", outcomeKind: "error",
                errorCode: Self.recipeErrorCode(for: error),
                runId: pending.runId
            )
            let outcome = IOSRecipeRunOutcome.failed(failedStep: nil, error: error, completedSteps: [])
            return .completed(messagesByFinishingToolCall(
                pending.toolCall,
                outputText: runner.structuredErrorJSON(for: outcome)
                    ?? ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: "Recipe 执行计划校验失败。",
                        status: "failed"
                    ),
                in: pending.baseMessages
            ))
        } catch {
            return recipeCallFailure("Recipe 执行计划无法解析：\(error.localizedDescription)")
        }

        var state = IOSRecipeExecutionState(
            toolCallId: pending.toolCall.toolCallId,
            executionId: "recipe-\(UUID().uuidString)",
            recipeName: descriptor.recipeName,
            recipeVersion: descriptor.version,
            pluginId: descriptor.pluginId,
            pluginPackageHash: descriptor.pluginId == nil ? nil : descriptor.manifestHash,
            capabilityBroker: descriptor.capabilityBroker,
            catalogRevision: snapshot?.revision,
            manifest: recipeManifest,
            plan: plan,
            inputs: inputs,
            stepOutputs: [:],
            completedSteps: [],
            nextStepIndex: 0
        )
        state.candidateTest = candidateTest
        switch await advanceRecipeExecution(state: &state, context: pending, bridge: bridge) {
        case .completed(let messages):
            return .completed(messages)
        case .needsApproval(let request):
            return .waitingForApproval(.recipe(request))
        case .durabilityFailure(let message):
            return .durabilityFailure(message)
        case .outcomeUnknown(let messages):
            return .outcomeUnknown(messages)
        }
    }

    /// Runs steps from `state.nextStepIndex` until the next approval-requiring
    /// step or completion. When a step needs approval the checkpoint is
    /// persisted and the state is stashed (keyed by toolCallId) so the
    /// finisher can continue the recipe on approval (§10.3.5: each mutation
    /// step pauses again). On completion/failure the checkpoint and the
    /// stashed state are removed here.
    ///
    /// `skipGateForFirstStep`: the finisher's allow path resumes AT the step
    /// the user just approved — re-gating it would pause the same step again
    /// (an approval loop). The approved step bypasses the gate exactly like
    /// the top-level post-approval path (`isUserInitiated: true`); every
    /// LATER step is gated normally.
    private func advanceRecipeExecution(
        state: inout IOSRecipeExecutionState,
        context: ChatPendingToolApproval,
        bridge: IosToolExposureBridge?,
        skipGateForFirstStep: Bool = false
    ) async -> RecipeAdvanceOutcome {
        let runner = makeRecipeRunner(manifest: state.manifest, context: context, bridge: bridge)
        var skipGate = skipGateForFirstStep
        while state.nextStepIndex < state.plan.steps.count {
            let step = state.plan.steps[state.nextStepIndex]

            // Resolve the step's arguments BEFORE the approval gate so the
            // card can show what the step will actually call with.
            let argsJSON: String
            do {
                argsJSON = try runner.resolveArguments(
                    step: step,
                    inputs: state.inputs,
                    stepOutputs: state.stepOutputs
                )
            } catch let error as IOSRecipeRunError {
                // Same Finished-only trace as the pre-refactor runner (the
                // step never Started), then stop the recipe.
                await recordRecipeStepFinishedOnly(
                    state: state, step: step, errorCode: "argument_binding", runId: context.runId
                )
                await recordRecipeLevelFinished(
                    recipeName: state.recipeName,
                    recipeVersion: state.recipeVersion,
                    executionId: state.executionId,
                    outcome: "failed", outcomeKind: "error",
                    errorCode: Self.recipeErrorCode(for: error),
                    runId: context.runId
                )
                let outcome = IOSRecipeRunOutcome.failed(
                    failedStep: step.id, error: error, completedSteps: state.completedSteps
                )
                return .completed(finishRecipeCall(
                    state: state, context: context,
                    outputText: runner.structuredErrorJSON(for: outcome)
                        ?? ChatToolOutputFormatter.toolFailureJSON(
                            toolName: context.toolCall.toolName,
                            reason: "Recipe 步骤参数解析失败。",
                            status: "failed"
                        )
                ))
            } catch {
                let runError = IOSRecipeRunError.argumentBinding(
                    stepId: step.id, key: "", reason: error.localizedDescription
                )
                await recordRecipeStepFinishedOnly(
                    state: state, step: step, errorCode: "argument_binding", runId: context.runId
                )
                await recordRecipeLevelFinished(
                    recipeName: state.recipeName,
                    recipeVersion: state.recipeVersion,
                    executionId: state.executionId,
                    outcome: "failed", outcomeKind: "error",
                    errorCode: "argument_binding",
                    runId: context.runId
                )
                let outcome = IOSRecipeRunOutcome.failed(
                    failedStep: step.id, error: runError, completedSteps: state.completedSteps
                )
                return .completed(finishRecipeCall(
                    state: state, context: context,
                    outputText: runner.structuredErrorJSON(for: outcome)
                        ?? ChatToolOutputFormatter.toolFailureJSON(
                            toolName: context.toolCall.toolName,
                            reason: "Recipe 步骤参数解析失败。",
                            status: "failed"
                        )
                ))
            }

            if let broker = state.capabilityBroker,
               let reason = broker.authorize(tool: step.tool, argumentsJSON: argsJSON) {
                let error = IOSRecipeRunError.stepFailed(
                    stepId: step.id,
                    tool: step.tool,
                    message: reason
                )
                await recordRecipeStepFinishedOnly(
                    state: state,
                    step: step,
                    errorCode: "capability_denied",
                    runId: context.runId
                )
                await recordRecipeLevelFinished(
                    recipeName: state.recipeName,
                    recipeVersion: state.recipeVersion,
                    executionId: state.executionId,
                    outcome: "failed",
                    outcomeKind: "denied",
                    errorCode: "capability_denied",
                    runId: context.runId
                )
                let outcome = IOSRecipeRunOutcome.failed(
                    failedStep: step.id,
                    error: error,
                    completedSteps: state.completedSteps
                )
                return .completed(finishRecipeCall(
                    state: state,
                    context: context,
                    outputText: runner.structuredErrorJSON(for: outcome)
                        ?? ChatToolOutputFormatter.toolFailureJSON(
                            toolName: context.toolCall.toolName,
                            reason: reason,
                            status: "failed"
                        )
                ))
            }

            if !skipGate {
                switch await recipeStepGate(
                    tool: step.tool,
                    argsJSON: argsJSON,
                    context: context
                ) {
                case .unsupported(let reason):
                    let error = IOSRecipeRunError.stepFailed(stepId: step.id, tool: step.tool, message: reason)
                    await recordRecipeLevelFinished(
                        recipeName: state.recipeName,
                        recipeVersion: state.recipeVersion,
                        executionId: state.executionId,
                        outcome: "failed", outcomeKind: "error",
                        errorCode: "unsupported_step",
                        runId: context.runId
                    )
                    let outcome = IOSRecipeRunOutcome.failed(
                        failedStep: step.id, error: error, completedSteps: state.completedSteps
                    )
                    return .completed(finishRecipeCall(
                        state: state, context: context,
                        outputText: runner.structuredErrorJSON(for: outcome)
                            ?? ChatToolOutputFormatter.toolFailureJSON(
                                toolName: context.toolCall.toolName,
                                reason: reason,
                                status: "failed"
                            )
                    ))
                case .approvalRequired(let reason):
                    // Durable pause: the checkpoint is on disk BEFORE the
                    // coordinator marks the run awaiting permission.
                    guard recipeExecutionCheckpointStore.save(state.checkpoint()) else {
                        let failureReason = "无法保存 Recipe 待确认状态，请检查存储空间后重试。"
                        let error = IOSRecipeRunError.stepFailed(
                            stepId: step.id,
                            tool: step.tool,
                            message: failureReason
                        )
                        await recordRecipeStepFinishedOnly(
                            state: state,
                            step: step,
                            errorCode: "checkpoint_write",
                            runId: context.runId
                        )
                        await recordRecipeLevelFinished(
                            recipeName: state.recipeName,
                            recipeVersion: state.recipeVersion,
                            executionId: state.executionId,
                            outcome: "failed",
                            outcomeKind: "error",
                            errorCode: "checkpoint_write",
                            runId: context.runId
                        )
                        let outcome = IOSRecipeRunOutcome.failed(
                            failedStep: step.id,
                            error: error,
                            completedSteps: state.completedSteps
                        )
                        return .completed(finishRecipeCall(
                            state: state,
                            context: context,
                            outputText: runner.structuredErrorJSON(for: outcome)
                                ?? ChatToolOutputFormatter.toolFailureJSON(
                                    toolName: context.toolCall.toolName,
                                    reason: failureReason,
                                    status: "failed"
                                )
                        ))
                    }
                    preparedRecipeExecutions[state.toolCallId] = state
                    let payload = RecipeStepApprovalPayload(
                        stepId: step.id,
                        tool: step.tool,
                        argumentsPreview: recipeArgumentsPreview(argsJSON),
                        effectClass: step.effectClass
                    )
                    return .needsApproval(RecipeToolApprovalRequestBuilder.stepRequest(
                        for: context.toolCall,
                        recipeName: state.recipeName,
                        recipeVersion: state.recipeVersion,
                        payload: payload,
                        reason: reason,
                        executionId: state.executionId
                    ))
                case .proceed:
                    break
                }
            }
            // Only the resumed (just-approved) step bypasses the gate; from
            // here on every step is gated again.
            skipGate = false

            do {
                let output = try await runner.runStep(
                    plan: state.plan, step: step, executionId: state.executionId,
                    inputs: state.inputs, stepOutputs: state.stepOutputs
                )
                state.stepOutputs[step.id] = output
                state.completedSteps.append(step.id)
                state.nextStepIndex += 1
            } catch let error as IOSRecipePrimitiveOutcomeUnknownError {
                await recordRecipeLevelFinished(
                    recipeName: state.recipeName,
                    recipeVersion: state.recipeVersion,
                    executionId: state.executionId,
                    outcome: "outcome_unknown",
                    outcomeKind: "unknown",
                    errorCode: "unknown_after_action",
                    runId: context.runId
                )
                let resultText = IOSWebMountController.json([
                    "ok": false,
                    "tool": context.toolCall.toolName,
                    "status": "unknown_after_action",
                    "error_code": "unknown_after_action",
                    "may_have_applied": true,
                    "failed_step": step.id,
                    "completed_steps": state.completedSteps,
                    "reason": "Recipe 中的 WebMount 操作已发出，但无法确认是否生效；后续步骤已停止。",
                    "step_output": error.outputText
                ])
                return .outcomeUnknown(finishRecipeCall(
                    state: state,
                    context: context,
                    outputText: resultText
                ))
            } catch is IOSRecipeToolTerminalPersistenceError {
                discardPreparedRecipeExecution(toolCallId: state.toolCallId)
                return .durabilityFailure("tool result ledger write failed")
            } catch let error as IOSRecipeRunError {
                await recordRecipeLevelFinished(
                    recipeName: state.recipeName,
                    recipeVersion: state.recipeVersion,
                    executionId: state.executionId,
                    outcome: "failed", outcomeKind: "error",
                    errorCode: Self.recipeErrorCode(for: error),
                    runId: context.runId
                )
                let outcome = IOSRecipeRunOutcome.failed(
                    failedStep: step.id, error: error, completedSteps: state.completedSteps
                )
                return .completed(finishRecipeCall(
                    state: state, context: context,
                    outputText: runner.structuredErrorJSON(for: outcome)
                        ?? ChatToolOutputFormatter.toolFailureJSON(
                            toolName: context.toolCall.toolName,
                            reason: "Recipe 步骤执行失败。",
                            status: "failed"
                        )
                ))
            } catch {
                let runError = IOSRecipeRunError.stepFailed(
                    stepId: step.id, tool: step.tool, message: error.localizedDescription
                )
                await recordRecipeLevelFinished(
                    recipeName: state.recipeName,
                    recipeVersion: state.recipeVersion,
                    executionId: state.executionId,
                    outcome: "failed", outcomeKind: "error",
                    errorCode: "step_failed",
                    runId: context.runId
                )
                let outcome = IOSRecipeRunOutcome.failed(
                    failedStep: step.id, error: runError, completedSteps: state.completedSteps
                )
                return .completed(finishRecipeCall(
                    state: state, context: context,
                    outputText: runner.structuredErrorJSON(for: outcome)
                        ?? ChatToolOutputFormatter.toolFailureJSON(
                            toolName: context.toolCall.toolName,
                            reason: "Recipe 步骤执行失败。",
                            status: "failed"
                        )
                ))
            }
        }

        // All steps completed: resolve the recipe outputs (§10.3.1).
        do {
            let outputs = try runner.resolveOutputs(plan: state.plan, stepOutputs: state.stepOutputs)
            await recordRecipeLevelFinished(
                recipeName: state.recipeName,
                recipeVersion: state.recipeVersion,
                executionId: state.executionId,
                outcome: "completed", outcomeKind: "success",
                errorCode: nil,
                runId: context.runId
            )
            let resultText = recipeResultJSON(outputs: outputs, completedSteps: state.completedSteps)
            return .completed(finishRecipeCall(state: state, context: context, outputText: resultText))
        } catch let error as IOSRecipeRunError {
            await recordRecipeLevelFinished(
                recipeName: state.recipeName,
                recipeVersion: state.recipeVersion,
                executionId: state.executionId,
                outcome: "failed", outcomeKind: "error",
                errorCode: Self.recipeErrorCode(for: error),
                runId: context.runId
            )
            let outcome = IOSRecipeRunOutcome.failed(
                failedStep: nil, error: error, completedSteps: state.completedSteps
            )
            return .completed(finishRecipeCall(
                state: state, context: context,
                outputText: runner.structuredErrorJSON(for: outcome)
                    ?? ChatToolOutputFormatter.toolFailureJSON(
                        toolName: context.toolCall.toolName,
                        reason: "Recipe 输出解析失败。",
                        status: "failed"
                    )
            ))
        } catch {
            let runError = IOSRecipeRunError.outputResolution(outputName: "", reason: error.localizedDescription)
            await recordRecipeLevelFinished(
                recipeName: state.recipeName,
                recipeVersion: state.recipeVersion,
                executionId: state.executionId,
                outcome: "failed", outcomeKind: "error",
                errorCode: "output_resolution",
                runId: context.runId
            )
            let outcome = IOSRecipeRunOutcome.failed(
                failedStep: nil, error: runError, completedSteps: state.completedSteps
            )
            return .completed(finishRecipeCall(
                state: state, context: context,
                outputText: runner.structuredErrorJSON(for: outcome)
                    ?? ChatToolOutputFormatter.toolFailureJSON(
                        toolName: context.toolCall.toolName,
                        reason: "Recipe 输出解析失败。",
                        status: "failed"
                    )
            ))
        }
    }

    /// Finisher continuation of a paused mutation step. `allow`:
    /// - executes the approved step (its policy gate is bypassed via
    ///   `isUserInitiated: true`, the existing post-approval contract) and
    ///   CONTINUES the recipe — a later mutation step pauses again;
    /// - deny: the step fails, the recipe stops, a structured error with the
    ///   completed-side-effects list is returned (§10.3.6) and the
    ///   `approval_denied` ledger event is written through `recordToolApproval`
    ///   (the Phase 0 evidence funnel).
    func finishRecipeStepApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        executionContext: IOSRecipeExecutionState?,
        toolExposureBridge: IosToolExposureBridge?
    ) async -> RecipeApprovalFinishResult {
        let toolCallId = pending.toolCall.toolCallId
        guard var state = executionContext ?? preparedRecipeExecutions[toolCallId] else {
            // Fail closed: the prepared execution is gone (cold start or run
            // replaced); never fall back to a fresh preview/execution.
            let failure = ChatToolOutputFormatter.toolFailureJSON(
                toolName: pending.toolCall.toolName,
                reason: "Recipe 执行上下文已失效，请重新发起调用。",
                status: "failed"
            )
            return .completed(messagesByFinishingToolCall(
                pending.toolCall,
                outputText: failure,
                in: pending.baseMessages
            ))
        }

        guard !allow else {
            recordToolApproval(
                capabilityId: "ios.agent.recipe_execution",
                toolCall: pending.toolCall,
                action: .allowed,
                reason: "User approved recipe step.",
                runId: pending.runId,
                executionPolicy: pending.executionPolicy
            )
            // The resumed step is the one the user just approved — skip its
            // gate (the top-level post-approval contract); later steps gate
            // normally (§10.3.5: each mutation step pauses again).
            switch await advanceRecipeExecution(
                state: &state, context: pending, bridge: toolExposureBridge,
                skipGateForFirstStep: true
            ) {
            case .completed(let messages):
                return .completed(messages)
            case .needsApproval(let request):
                return .pausedForNextStep(request)
            case .durabilityFailure(let message):
                return .durabilityFailure(message)
            case .outcomeUnknown(let messages):
                return .outcomeUnknown(messages)
            }
        }

        // Denial: the approved step fails, the recipe stops (§10.3.6).
        recordToolApproval(
            capabilityId: "ios.agent.recipe_execution",
            toolCall: pending.toolCall,
            action: .denied,
            reason: "User denied recipe step.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        discardPreparedRecipeExecution(toolCallId: toolCallId)
        let step = state.plan.steps[state.nextStepIndex]
        let error = IOSRecipeRunError.stepFailed(
            stepId: step.id, tool: step.tool, message: "用户拒绝了该步骤，Recipe 已停止。"
        )
        await recordRecipeLevelFinished(
            recipeName: state.recipeName,
            recipeVersion: state.recipeVersion,
            executionId: state.executionId,
            outcome: "failed", outcomeKind: "denied",
            errorCode: "step_denied",
            runId: pending.runId
        )
        let runner = makeRecipeRunner(manifest: state.manifest, context: pending, bridge: toolExposureBridge)
        let outcome = IOSRecipeRunOutcome.failed(
            failedStep: step.id, error: error, completedSteps: state.completedSteps
        )
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: runner.structuredErrorJSON(for: outcome)
                ?? ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: "用户拒绝了该步骤，Recipe 已停止。",
                    denied: true
                ),
            in: pending.baseMessages
        ))
    }

    /// `recipe_import` approval resolution: re-reads the Workspace candidate,
    /// re-validates base/candidate CAS + semantics, applies (zero writes on
    /// any stale change) and refreshes the registry so the next model round
    /// sees the promotion. Denial records the `approval_denied` ledger event.
    func finishRecipeImportApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        prepared: IOSPreparedRecipeImport?
    ) async -> [UIMessage] {
        recordToolApproval(
            capabilityId: "ios.agent.recipe_import",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved recipe import." : "User denied recipe import.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        let resultText: String
        if allow {
            if let prepared {
                do {
                    resultText = try await recipeToolService.applyPreparedRecipeImport(prepared)
                } catch {
                    resultText = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    )
                }
            } else {
                // 冷启动或审批内存态丢失时 fail closed；绝不能退回普通 dispatch。
                resultText = ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: "Recipe 导入预览已失效，请重新发起导入并确认最新变更。",
                    status: "failed"
                )
            }
        } else {
            resultText = "用户拒绝导入 Recipe。"
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    func finishPluginImportApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        prepared: IOSPreparedPluginImport?
    ) async -> [UIMessage] {
        recordToolApproval(
            capabilityId: "ios.agent.plugin_import",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved plugin import." : "User denied plugin import.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        let resultText: String
        if allow, let prepared {
            do {
                resultText = try await pluginToolService.applyPreparedPluginImport(prepared)
            } catch {
                resultText = ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    status: "failed"
                )
            }
        } else if allow {
            resultText = ChatToolOutputFormatter.toolFailureJSON(
                toolName: pending.toolCall.toolName,
                reason: "插件导入预览已失效，请重新预览。",
                status: "failed"
            )
        } else {
            resultText = "用户拒绝导入插件。"
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    /// Builds the production primitive executor: every step routes back to
    /// this runtime's EXISTING per-tool execution paths (workspace/search/
    /// iSH/webMount/memory/advanced/skill/discovery), never a duplicated
    /// implementation. `isUserInitiated: true` is the post-approval contract
    /// (the user already approved the step's card).
    private func makeRecipeRunner(
        manifest: IOSRecipeManifest,
        context: ChatPendingToolApproval,
        bridge: IosToolExposureBridge?
    ) -> IOSRecipeRunner {
        IOSRecipeRunner(
            manifest: manifest,
            artifactId: context.toolCall.toolName,
            catalog: IOSDynamicToolRegistry.primitiveCatalogEntry,
            executePrimitive: { [weak self] tool, argsJSON in
                guard let self else {
                    throw IOSRecipeRunError.stepFailed(
                        stepId: "", tool: tool, message: "Chat runtime is unavailable."
                    )
                }
                switch await self.executeRecipePrimitiveStep(
                    tool: tool,
                    argsJSON: argsJSON,
                    isUserInitiated: true,
                    context: context,
                    bridge: bridge
                ) {
                case .output(let text):
                    return text
                case .failure(let reason):
                    throw IOSRecipeRunError.stepFailed(stepId: "", tool: tool, message: reason)
                case .needsApproval:
                    throw IOSRecipeRunError.stepFailed(
                        stepId: "", tool: tool,
                        message: "步骤需要批准但未通过审批前置检查。"
                    )
                case .outcomeUnknown(let outputText):
                    throw IOSRecipePrimitiveOutcomeUnknownError(outputText: outputText)
                }
            },
            ledger: ledger,
            runId: context.runId
        )
    }

    /// One step routed through the existing dispatcher (post-approval path).
    /// The gate was already checked by `advanceRecipeExecution`; this only
    /// executes and formats the output.
    private func executeRecipePrimitiveStep(
        tool: String,
        argsJSON: String,
        isUserInitiated: Bool,
        context: ChatPendingToolApproval,
        bridge: IosToolExposureBridge?
    ) async -> RecipePrimitiveStepResult {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "recipe-step-\(UUID().uuidString)",
            toolName: tool,
            input: argsJSON,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        switch IOSRecipePrimitiveCatalog.route(for: tool) {
        case .workspace:
            let output = await workspaceToolExecutionOutput(toolCall, isUserInitiated: isUserInitiated)
            if case .needsUserAction(let reason) = output {
                return .needsApproval(reason: reason)
            }
            let text = ChatToolOutputFormatter.workspaceResultText(for: toolCall, output: output)
            // Slice A / §10.3.6：recipe step 是 stop-on-failure 语义，workspace
            // 的 ok:false 必须冒泡为 step 失败（否则路径/参数错误永远不产生
            // typed evidence，自进化诊断无从归因）。普通聊天工具路径不变——
            // 那里 ok:false 是给模型看的正常输出。
            if let failure = ChatToolOutputFormatter.workspaceFailureReason(inOutputJSON: text) {
                return .failure(failure)
            }
            return .output(text)
        case .search:
            return recipePrimitiveResult(await dispatchSearchToolCall(toolCall))
        case .memory:
            let policy = memoryToolWritePolicy(input: argsJSON, isUserInitiated: isUserInitiated)
            if case .needsUserAction(let reason) = policy {
                return .needsApproval(reason: reason)
            }
            return recipePrimitiveResult(dispatchMemoryToolCall(toolCall, writePolicy: policy))
        case .ish:
            let output = await ishToolExecutionOutput(toolCall, isUserInitiated: isUserInitiated)
            switch output {
            case .needsUserAction(let reason):
                return .needsApproval(reason: reason)
            case .denied(let reason), .failed(let reason):
                return .failure(reason)
            default:
                return recipePrimitiveResult(
                    ChatToolOutputFormatter.ishHandoffResultText(for: toolCall, output: output)
                )
            }
        case .webMount:
            let output = await webMountToolExecutionOutput(
                toolCall,
                isUserInitiated: isUserInitiated,
                runId: context.runId,
                conversationId: context.conversationId
            )
            if case .needsUserAction(let reason) = output {
                return .needsApproval(reason: reason)
            }
            if output.isWebMountOutcomeUnknown {
                return .outcomeUnknown(ChatToolOutputFormatter.webMountResultText(for: toolCall, output: output))
            }
            return recipePrimitiveResult(
                ChatToolOutputFormatter.webMountResultText(for: toolCall, output: output)
            )
        case .sessionRead:
            return recipePrimitiveResult(await dispatchSessionReadToolCall(toolCall))
        case .discovery:
            guard let bridge else {
                return .failure("\(tool) 当前不可用（缺少工具目录）。")
            }
            if tool == "tools_list" {
                return recipePrimitiveResult(bridge.executeToolsList())
            }
            // Jev Phase 1：Recipe discovery 与前台/后台共用语义发现服务。
            let result = await IOSJevToolDiscoveryService.execute(
                argumentsJson: argsJSON,
                bridge: bridge,
                identity: IOSJevToolDiscoveryService.RunIdentity(
                    runId: context.runId,
                    turnBudgetKey: IOSJevToolDiscoveryService.turnBudgetKey(runId: context.runId)
                )
            )
            return recipePrimitiveResult(result)
        case .skill:
            let result = await skillMcpToolService.execute(
                toolName: tool,
                arguments: argsJSON,
                mcpEnabledOverride: isMcpNetworkAllowed()
            )
            return recipePrimitiveResult(result)
        case .advanced:
            return recipePrimitiveResult(await dispatchAdvancedToolCall(
                toolCall,
                providerSetting: context.providerSetting,
                params: context.params,
                runId: context.runId,
                conversationId: context.conversationId,
                nestedTools: nil,
                toolExposureBridge: bridge
            ))
        case .recipeImport, .unsupported:
            return .failure("工具「\(tool)」不支持作为 Recipe step。")
        }
    }

    private func recipePrimitiveResult(_ output: String) -> RecipePrimitiveStepResult {
        let part = UIMessagePart.Text(text: output, metadata: nil)
        if let reason = ChatToolOutputFormatter.failureReason(from: [part]) {
            return .failure(reason)
        }
        return .output(output)
    }

    /// Step-level approval gate, mirroring the TOP-LEVEL approval decisions
    /// (`executeWorkspaceToolCall` / `executeSearchToolCall` /
    /// `executeAdvancedToolCall` / the local executor's policy gates). The
    /// execution itself is never duplicated — only the "would this need a
    /// card" decision, so a recipe step cannot silently skip a gate.
    private func recipeStepGate(
        tool: String,
        argsJSON: String,
        context: ChatPendingToolApproval
    ) async -> RecipeStepGate {
        switch IOSRecipePrimitiveCatalog.route(for: tool) {
        case .workspace:
            return workspaceRecipeStepGate(toolName: tool)
        case .search:
            let autoApprove = effectiveGlobalAutoApproveEnabled
                || effectiveHighRiskAutoApproveEnabled
            if !autoApprove,
               ChatToolApprovalRequestBuilder.search(
                   for: toolCall(name: tool, input: argsJSON),
                   reason: "网络搜索和网页读取会访问外部站点，需要你确认。",
                   settings: sharedSettings.snapshot
               ) != nil {
                return .approvalRequired(reason: "网络搜索和网页读取会访问外部站点，需要你确认。")
            }
            return .proceed
        case .memory:
            if case .needsUserAction(let reason) = memoryToolWritePolicy(input: argsJSON, isUserInitiated: false) {
                return .approvalRequired(reason: reason)
            }
            return .proceed
        case .ish:
            if isIshToolAutoApproved(
                toolName: tool,
                input: argsJSON,
                runId: context.runId,
                conversationId: context.conversationId
            ) {
                return .proceed
            }
            return .approvalRequired(reason: "终端执行需要显式批准。")
        case .webMount:
            return await webMountRecipeStepGate(
                toolName: tool,
                argsJSON: argsJSON,
                context: context
            )
        case .advanced:
            if IOSAppleAgentToolCatalog.approvalRequiredToolNames.contains(tool) {
                return .approvalRequired(reason: appleCapabilityApprovalReason(toolName: tool))
            }
            switch tool {
            case "mcp_call":
                guard effectiveHighRiskAutoApproveEnabled else {
                    return .approvalRequired(reason: "MCP 工具可能访问外部服务或执行远端操作，需要你确认。")
                }
                return .proceed
            case let name where ToolKt.isExpandedMcpToolName(name: name):
                guard effectiveHighRiskAutoApproveEnabled else {
                    return .approvalRequired(reason: "MCP 工具可能访问外部服务或执行远端操作，需要你确认。")
                }
                return .proceed
            case let name where IOSProviderConfigToolCatalog.highRiskToolNames.contains(name):
                guard effectiveHighRiskAutoApproveEnabled else {
                    return .approvalRequired(
                        reason: IOSProviderConfigToolCatalog.approvalReason(argumentsJSON: argsJSON)
                    )
                }
                return .proceed
            case let name where IOSThemePackToolCatalog.highRiskToolNames.contains(name):
                return .approvalRequired(
                    reason: "主题试穿会立刻换皮，需要你确认套用或还原。"
                )
            case "subagent_dispatch":
                return .proceed
            case "model_council_run":
                if requiresCouncilApproval {
                    return .approvalRequired(reason: "模型议会会发起多次模型请求，需要你确认。")
                }
                return .proceed
            default:
                // 编排工具（spawn/list/interrupt/send/followup/wait_agent）与
                // exec/wait：顶层路径无审批卡，步骤同样直接执行。
                return .proceed
            }
        case .skill:
            let mutating = IOSSkillToolCatalog.mutatingToolNames.contains(tool)
            if mutating, !effectiveGlobalAutoApproveEnabled,
               !effectiveHighRiskAutoApproveEnabled {
                return .approvalRequired(reason: "将写入本机 Skill 或 MCP 配置，需要你确认。")
            }
            return .proceed
        case .sessionRead, .discovery:
            return .proceed
        case .recipeImport:
            return .unsupported(reason: "recipe_import 需要单独的候选预览审批，不支持作为 Recipe step。")
        case .unsupported:
            return .unsupported(reason: "工具「\(tool)」不支持作为 Recipe step。")
        }
    }

    private func appleCapabilityApprovalReason(toolName: String) -> String {
        if IOSAppleAgentToolCatalog.alarmToolNames.contains(toolName) {
            return IOSAppleAgentToolCatalog.mutatingToolNames.contains(toolName)
                ? IOSAlarmCopy.mutatingReason
                : IOSAlarmCopy.listReason
        }
        return IOSAppleAgentToolCatalog.mutatingToolNames.contains(toolName)
            ? "该操作会读取或修改你在 iPhone 上的私密 Apple 数据，需要你确认。"
            : "该操作会读取你在 iPhone 上的私密 Apple 数据，并交给当前 Agent 处理，需要你确认。"
    }

    /// Mirror of `IOSLocalToolExecutor.resolveWorkspace`'s gate: the policy
    /// check that decides whether the workspace call needs a card. The
    /// execution itself (when allowed) happens through the existing path.
    private func workspaceRecipeStepGate(toolName: String) -> RecipeStepGate {
        guard let localToolExecutor,
              let capability = IOSCapabilityRegistry.capability(forToolName: toolName) else {
            return .proceed
        }
        guard let policy = IOSExecutionPolicyContext.snapshot?.policy(for: capability)
            ?? localToolExecutor.permissionPolicy(capabilityId: capability.id) else {
            return .proceed
        }
        if policy == .disabled {
            // Execution will fail with the disabled message; no card needed.
            return .proceed
        }
        if policy == .autoApprove || policy == .autoApproveHighRisk {
            return .proceed
        }
        if IOSWorkspaceToolCatalog.writeToolNames.contains(toolName) {
            if effectiveGlobalAutoApproveEnabled
                && (capability.risk != .high || effectiveHighRiskAutoApproveEnabled) {
                return .proceed
            }
            return .approvalRequired(reason: "Workspace 写入与删除需要显式批准。")
        }
        if policy == .askEveryTime || capability.gate.requiresFreshUserPresence {
            if effectiveGlobalAutoApproveEnabled
                && (capability.risk != .high || effectiveHighRiskAutoApproveEnabled) {
                return .proceed
            }
            return .approvalRequired(reason: "Workspace 读取需要显式批准。")
        }
        return .proceed
    }

    /// Reuse the same WebMount gate as top-level execution so recipe steps do
    /// not drift from the executor's policy or explicit-user-action rules.
    private func webMountRecipeStepGate(
        toolName: String,
        argsJSON: String,
        context: ChatPendingToolApproval
    ) async -> RecipeStepGate {
        guard let localToolExecutor else {
            return .unsupported(reason: "WebMount executor is unavailable.")
        }
        switch localToolExecutor.webMountGateDecision(
            toolName: toolName,
            isUserInitiated: false,
            executionPolicy: IOSExecutionPolicyContext.snapshot
        ) {
        case .allow:
            return await webMountRecipeActionPreflight(
                toolName: toolName,
                argsJSON: argsJSON,
                context: context
            ) ?? .proceed
        case .deny(let reason):
            return .unsupported(reason: reason)
        case .needsUserAction(let reason):
            if let preflight = await webMountRecipeActionPreflight(
                toolName: toolName,
                argsJSON: argsJSON,
                context: context
            ), case .approvalRequired = preflight {
                return preflight
            }
            return .approvalRequired(reason: reason)
        }
    }

    private func webMountRecipeActionPreflight(
        toolName: String,
        argsJSON: String,
        context: ChatPendingToolApproval
    ) async -> RecipeStepGate? {
        guard let localToolExecutor,
              let output = await localToolExecutor.webMountActionPreflight(
                  toolName: toolName,
                  input: argsJSON,
                  runId: context.runId,
                  conversationId: context.conversationId?.toHexDashString() ?? "",
                  executionPolicy: IOSExecutionPolicyContext.snapshot
              ) else {
            return nil
        }
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unsupported(reason: "WebMount action preflight returned invalid output.")
        }

        let reason = (object["reason"] as? String)?.nilIfBlank
            ?? (object["consequence"] as? String)?.nilIfBlank
            ?? (object["error"] as? String)?.nilIfBlank
            ?? "WebMount action preflight failed."
        if object["requires_human"] as? Bool == true {
            return .approvalRequired(reason: "human_handoff: \(reason)")
        }
        if object["needs_user_action"] as? Bool == true {
            return .approvalRequired(reason: reason)
        }
        if object["ok"] as? Bool == false {
            return .unsupported(reason: reason)
        }
        return .proceed
    }

    /// Recipe-level ledger record (§15 Phase 0 attribution): one Finished row
    /// per recipe call under `recipe-level-<executionId>` carrying
    /// artifactId/artifactVersion/outcomeKind, so evidence projection can
    /// attribute the whole run to the exact recipe version. The per-step
    /// Started/Finished pairs come from `IOSRecipeRunner.runStep` under
    /// `recipe-<executionId>-<stepId>` (the distinct prefix keeps the two
    /// namespaces unambiguous in the ledger).
    private func recordRecipeLevelFinished(
        recipeName: String,
        recipeVersion: String,
        executionId: String,
        outcome: String,
        outcomeKind: String,
        errorCode: String?,
        runId: String
    ) async {
        guard let ledger else { return }
        await ledger.recordToolCallFinished(
            runId: runId,
            toolCallId: "recipe-level-\(executionId)",
            outcome: outcome,
            artifactId: Self.dynamicArtifactId(recipeName),
            artifactVersion: recipeVersion,
            outcomeKind: outcomeKind,
            errorCode: errorCode,
            sourceRef: executionId
        )
    }

    /// Finished-only trace for a step that failed before it ever Started
    /// (argument resolution failure), matching the runner's pre-refactor
    /// record shape so old and new ledgers read identically.
    private func recordRecipeStepFinishedOnly(
        state: IOSRecipeExecutionState,
        step: IOSRecipePlanStep,
        errorCode: String,
        runId: String
    ) async {
        guard let ledger else { return }
        await ledger.recordToolCallFinished(
            runId: runId,
            toolCallId: "recipe-\(state.executionId)-\(step.id)",
            outcome: "failed",
            artifactId: Self.dynamicArtifactId(state.recipeName),
            artifactVersion: state.recipeVersion,
            outcomeKind: "error",
            errorCode: errorCode,
            sourceRef: state.executionId
        )
    }

    /// Fills the recipe tool call's output and clears the paused state
    /// (checkpoint + in-memory) — the terminal resolution of the call.
    private func finishRecipeCall(
        state: IOSRecipeExecutionState,
        context: ChatPendingToolApproval,
        outputText: String
    ) -> [UIMessage] {
        preparedRecipeExecutions.removeValue(forKey: state.toolCallId)
        recipeExecutionCheckpointStore.remove(toolCallId: state.toolCallId)
        if state.candidateTest == nil { recordRecipePluginHealth(output: outputText, state: state) }
        return messagesByFinishingToolCall(
            context.toolCall,
            outputText: state.candidateTest?.resultJSON(outputText) ?? outputText,
            in: context.baseMessages
        )
    }

    private func recordRecipePluginHealth(
        output: String,
        state: IOSRecipeExecutionState
    ) {
        guard let pluginId = state.pluginId,
              let packageHash = state.pluginPackageHash,
              let object = ChatToolCallParsing.jsonObject(output) else { return }
        if object["ok"] as? Bool == true {
            _ = pluginHealthStore.recordSuccess(pluginId: pluginId, packageHash: packageHash)
            return
        }
        let status = object["status"] as? String ?? ""
        let errorCode = object["error_code"] as? String ?? ""
        let reason = (object["reason"] as? String) ?? (object["error"] as? String) ?? "插件运行失败。"
        let kind: IOSPluginDiagnosticKind?
        if status == "timeout" || status == "timed_out" || errorCode == "step_timeout" || reason.localizedCaseInsensitiveContains("超时") {
            kind = .timeout
        } else if errorCode == "output_resolution" || reason.contains("输出解析") {
            kind = .schema
        } else {
            kind = nil
        }
        guard let kind else { return }
        let transition = pluginHealthStore.recordFailure(
            pluginId: pluginId,
            packageHash: packageHash,
            toolId: state.recipeName,
            kind: kind,
            detail: reason
        )
        if transition.didQuarantine {
            Task { [recipeRegistry] in _ = await recipeRegistry.refresh() }
        }
    }

    private static func dynamicArtifactId(_ recipeName: String) -> String {
        recipeName.hasPrefix("plugin__") ? recipeName : "recipe__\(recipeName)"
    }

    private func recipeResultJSON(
        outputs: [String: IOSRecipeJSONValue],
        completedSteps: [String]
    ) -> String {
        let outputsObject: Any
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(outputs)
            outputsObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            outputsObject = [:]
        }
        return IOSWorkspaceStore.json([
            "ok": true,
            "status": "completed",
            "steps": completedSteps,
            "outputs": outputsObject,
        ])
    }

    private func recipeArgumentsPreview(_ argsJSON: String) -> String {
        guard argsJSON.count > 360 else { return argsJSON }
        return String(argsJSON.prefix(360)) + "…"
    }

    private static func recipeErrorCode(for error: IOSRecipeRunError) -> String {
        switch error {
        case .planInvalid: "plan_invalid"
        case .inputInvalid: "input_invalid"
        case .argumentBinding: "argument_binding"
        case .stepFailed: "step_failed"
        case .stepTimeout: "step_timeout"
        case .outputResolution: "output_resolution"
        }
    }

    private static func mcpSkillImportPreview(
        from preview: IOSSkillImportPreview
    ) -> McpSkillImportPreview {
        let mutationKind: McpSkillImportMutationKind = switch preview.kind {
        case .new: .new
        case .update: .update
        }
        let changedFiles = preview.changedFiles.map { change in
            let kind: McpSkillImportFileChangeKind = switch change.kind {
            case .added: .added
            case .modified: .modified
            case .removed: .removed
            }
            return McpSkillImportFileChange(
                path: change.path,
                kind: kind,
                beforeText: change.beforeText,
                afterText: change.afterText
            )
        }
        return McpSkillImportPreview(
            skillName: preview.name,
            mutationKind: mutationKind,
            baseHash: preview.baseHash,
            candidateHash: preview.candidateHash,
            beforeSummary: preview.beforeSummary ?? "尚未安装",
            afterSummary: preview.afterSummary,
            changedFiles: changedFiles,
            containsMcpConfig: preview.containsMcpConfig
        )
    }

    private func dispatchSearchToolCall(_ toolCall: UIMessagePart.Tool) async -> String {
        guard effectiveWebSearchEnabled else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "Web search is disabled in settings."
            )
        }
        do {
            if toolCall.toolName == "search_web" {
                return try await executeSearchWebWithFallback(toolCall)
            }
            return try await IOSSearchExecutor.execute(
                toolName: toolCall.toolName,
                toolInput: toolCall.input,
                settings: sharedSettings.snapshot,
                transport: searchTransport
            )
        } catch is CancellationError {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "User cancelled.",
                cancelled: true
            )
        } catch {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    private func shouldExecuteSearchInBackground(toolName: String, arguments: String) -> Bool {
        let autoApprove = effectiveGlobalAutoApproveEnabled
            || effectiveHighRiskAutoApproveEnabled
        guard !autoApprove else { return true }
        let toolCall = toolCall(name: toolName, input: arguments)
        return ChatToolApprovalRequestBuilder.search(
            for: toolCall,
            reason: "网络搜索和网页读取会访问外部站点，需要你确认。",
            settings: sharedSettings.snapshot
        ) == nil
    }

    private func executeSearchWebWithFallback(_ toolCall: UIMessagePart.Tool) async throws -> String {
        let settings = sharedSettings.snapshot
        let maxResults = Int(settings.searchCommonOptions.resultSize)
        let request = try IOSSearchExecutor.searchRequest(
            from: toolCall.input,
            defaultMaxResults: maxResults
        )
        let initialSelection = IOSSearchExecutor.searchProviderSelection(settings: settings)
        do {
            let execution = try await IOSSearchExecutor.searchResults(
                toolInput: toolCall.input,
                maxResults: maxResults,
                settings: settings,
                transport: searchTransport
            )
            return IOSSearchExecutor.format(
                query: execution.request.query,
                results: execution.results,
                selection: execution.selection
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard let fallbackSelection = chatSearchFallbackSelection(
                after: initialSelection,
                settings: settings,
                initialError: error
            ) else {
                throw error
            }
            let results: [IOSSearchResult]
            switch fallbackSelection.route {
            case .duckDuckGoLite:
                results = try await IOSSearchExecutor.searchDuckDuckGoLite(
                    query: request.query,
                    maxResults: request.maxResults,
                    transport: searchTransport
                )
            case .bingHTML:
                results = try await IOSSearchExecutor.searchBingHTML(
                    query: request.query,
                    maxResults: request.maxResults,
                    transport: searchTransport
                )
            default:
                throw error
            }
            return IOSSearchExecutor.format(
                query: request.query,
                results: results,
                selection: fallbackSelection
            )
        }
    }

    private func chatSearchFallbackSelection(
        after selection: IOSSearchProviderSelection,
        settings: Settings,
        initialError: Error
    ) -> IOSSearchProviderSelection? {
        let reason = "原搜索服务 \(selection.providerName) 失败：\(searchErrorSummary(initialError))"
        if selection.route != .duckDuckGoLite, settings.searchBuiltinDuckDuckGoEnabled {
            return IOSSearchProviderSelection(
                route: .duckDuckGoLite,
                providerName: "DuckDuckGo Lite",
                providerType: "duckduckgo_builtin",
                serviceId: nil,
                fallbackReason: reason
            )
        }
        if selection.route != .bingHTML, settings.searchBuiltinBingEnabled {
            return IOSSearchProviderSelection(
                route: .bingHTML,
                providerName: "Bing HTML",
                providerType: "bing_builtin",
                serviceId: nil,
                fallbackReason: reason
            )
        }
        return nil
    }

    private func searchErrorSummary(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        guard message.count > 120 else { return message }
        return String(message.prefix(120)) + "..."
    }

    private func workspaceToolExecutionOutput(
        _ toolCall: UIMessagePart.Tool,
        isUserInitiated: Bool,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) async -> IOSLocalToolExecutionOutput {
        guard let localToolExecutor else {
            return .failed("Local iOS tool executor is unavailable.")
        }
        return await localToolExecutor.execute(localToolExecutor.executionRequest(
            toolName: toolCall.toolName,
            operation: toolCall.input,
            isUserInitiated: isUserInitiated,
            executionPolicy: executionPolicy ?? IOSExecutionPolicyContext.snapshot
        ))
    }

    private func ishToolExecutionOutput(
        _ toolCall: UIMessagePart.Tool,
        isUserInitiated: Bool,
        executionPolicy: IOSExecutionPolicySnapshot? = nil,
        approvalRequest: IshHandoffToolApprovalRequest? = nil
    ) async -> IOSLocalToolExecutionOutput {
        guard let localToolExecutor else {
            return .failed("Local iOS tool executor is unavailable.")
        }
        return await localToolExecutor.execute(localToolExecutor.executionRequest(
            toolName: toolCall.toolName,
            operation: toolCall.input,
            isUserInitiated: isUserInitiated,
            executionPolicy: executionPolicy ?? IOSExecutionPolicyContext.snapshot,
            approvedRemoteProfileId: approvalRequest?.remoteProfileId,
            approvedRemoteTargetDigest: approvalRequest?.remoteTargetDigest
        ))
    }

    private func dispatchWebMountToolCall(_ toolCall: UIMessagePart.Tool) async -> String {
        let output = await webMountToolExecutionOutput(toolCall, isUserInitiated: false)
        return ChatToolOutputFormatter.webMountResultText(for: toolCall, output: output)
    }

    func isWebMountOutcomeUnknown(
        in messages: [UIMessage],
        toolCallId: String
    ) -> Bool {
        for message in messages where message.role == MessageRole.assistant {
            for case let tool as UIMessagePart.Tool in message.parts
            where tool.toolCallId == toolCallId {
                for case let text as UIMessagePart.Text in tool.output {
                    if isWebMountInterruptedOutcome(text.text) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func webMountToolExecutionOutput(
        _ toolCall: UIMessagePart.Tool,
        isUserInitiated: Bool,
        executionPolicy: IOSExecutionPolicySnapshot? = nil,
        runId: String = "",
        conversationId: KotlinUuid? = nil
    ) async -> IOSLocalToolExecutionOutput {
        // Jev Phase 3：wm_run_goal 是本地编排工具（不是远端后端操作），
        // 先于后端映射分支；每个内层动作仍走下方既有 WebMount 执行链。
        if toolCall.toolName == "wm_run_goal" {
            return await runJevWebGoalLoopOutput(
                toolCall,
                isUserInitiated: isUserInitiated,
                runId: runId,
                conversationId: conversationId
            )
        }
        guard let localToolExecutor else {
            return .failed("Local iOS tool executor is unavailable.")
        }
        return await localToolExecutor.execute(localToolExecutor.executionRequest(
            toolName: toolCall.toolName,
            operation: toolCall.input,
            isUserInitiated: isUserInitiated,
            runId: runId,
            conversationId: conversationId?.toHexDashString() ?? "",
            executionPolicy: executionPolicy ?? IOSExecutionPolicyContext.snapshot
        ), visualRead: { [sharedSettings, conversationId] capture, question in
            try await IOSWebMountVisionReader().read(
                capture: capture,
                question: question,
                settings: sharedSettings.snapshot,
                conversationId: conversationId?.toHexDashString()
            )
        })
    }

    // MARK: - wm_run_goal（Jev Phase 3 有界网页快速循环）

    /// 工具入口绑定：循环的观察/执行都经既有 WebMount 工具路径，内层审批与
    /// 账本免费继承。off / 无 Key / 低置信 / 范围不允许时循环自身 handback，
    /// 不会触碰页面；只有 active（pinned 验收版本 + 全范围允许）才真正执行。
    private func runJevWebGoalLoopOutput(
        _ toolCall: UIMessagePart.Tool,
        isUserInitiated: Bool,
        runId: String,
        conversationId: KotlinUuid?
    ) async -> IOSLocalToolExecutionOutput {
        let arguments = (try? JSONSerialization.jsonObject(
            with: Data(toolCall.input.utf8)
        )) as? [String: Any] ?? [:]
        guard let input = IOSJevWebMountLoopService.loopInput(fromArguments: arguments) else {
            return .webMountResult(ChatToolOutputFormatter.toolFailureJSON(
                toolName: "wm_run_goal",
                reason: "wm_run_goal 需要 session_id 与 goal。"
            ))
        }
        // completion_text 必填：空标记永远无法核验完成，循环只能烧完预算退回，
        // 直接拒收并告知模型比空转诚实（文档契约即"由页面状态证明完成"）。
        guard let completionMarker = (arguments["completion_text"] as? String)?.nilIfBlank else {
            return .webMountResult(ChatToolOutputFormatter.toolFailureJSON(
                toolName: "wm_run_goal",
                reason: "wm_run_goal 需要非空 completion_text 用于完成核验。"
            ))
        }

        let service = IOSJevWebMountLoopService(deps: .init(
            coordinator: .shared,
            settingsProvider: { IOSSharedSettingsStore.loadPersistedJevSettings() },
            observe: { sessionId in
                await self.webMountLoopObservation(sessionId: sessionId, runId: runId, conversationId: conversationId)
            },
            execute: { sessionId, action in
                await self.webMountLoopExecute(
                    sessionId: sessionId,
                    action: action,
                    runId: runId,
                    conversationId: conversationId
                )
            },
            probe: { sessionId in
                await self.webMountLoopProbe(sessionId: sessionId, runId: runId, conversationId: conversationId)
            },
            replay: IOSJevWebMountLoopService.sharedReplay,
            isComplete: { _, observation in
                IOSJevWebMountLoopService.isComplete(marker: completionMarker, observation: observation)
            }
        ))
        // 报告循环启动时的 mode（与服务 settingsProvider 同源同刻）：跑完后重读
        // 会在中途改配置时谎报——active 执行却被标 shadow，或 dry-run 被标 active。
        let preRunMode = IOSSharedSettingsStore.loadPersistedJevSettings().effectiveMode(for: .webActions)
        let outcome = await service.run(input, runId: runId)
        return .webMountResult(IOSJevWebMountLoopService.outputText(for: outcome, goal: input.goal, effectiveMode: preRunMode))
    }

    /// 观察端口：走 wm_observe 既有路径并映射为循环快照。
    private func webMountLoopObservation(
        sessionId: String,
        runId: String,
        conversationId: KotlinUuid?
    ) async -> IOSJevWebMountLoopService.PageObservation? {
        let payload = Self.webMountJSON(["session_id": sessionId])
        let output = await webMountToolExecutionOutput(
            toolCall(name: "wm_observe", input: payload),
            isUserInitiated: false,
            runId: runId,
            conversationId: conversationId
        )
        guard case .webMountResult(let text) = output,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return nil
        }
        return IOSJevWebMountLoopService.observation(fromObservePayload: object)
    }

    /// 轻量探测端口：走 wm_state（单次 JS 调用，无元素提取）。DOM 未变时
    /// 循环复用上轮元素表，只更新 url/title/revision/scrollY；快照解析
    /// 复用 wm_observe 同一映射（page.* 字段同构）。
    private func webMountLoopProbe(
        sessionId: String,
        runId: String,
        conversationId: KotlinUuid?
    ) async -> IOSJevWebMountLoopService.PageObservation? {
        let payload = Self.webMountJSON(["session_id": sessionId])
        let output = await webMountToolExecutionOutput(
            toolCall(name: "wm_state", input: payload),
            isUserInitiated: false,
            runId: runId,
            conversationId: conversationId
        )
        guard case .webMountResult(let text) = output,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return nil
        }
        return IOSJevWebMountLoopService.observation(fromObservePayload: object)
    }

    /// 执行端口：按动作映射到既有具体工具，一次一步，审批与账本内层继承。
    /// 快照失效由 wm_* 工具自身的 snapshot_id 绑定拒收（stale_snapshot →
    /// .stale 回到重观察），不在此重复一次全量观察——那是每动作多付的
    /// 一次完整 DOM 提取。
    private func webMountLoopExecute(
        sessionId: String,
        action: IOSJevWebMountLoopService.PlannedAction,
        runId: String,
        conversationId: KotlinUuid?
    ) async -> IOSJevWebMountLoopService.ExecutorResult {
        guard let (toolName, payload) = Self.webMountLoopActionCall(sessionId: sessionId, action: action) else {
            return .failed(reason: "动作不在可执行白名单内。")
        }
        let output = await webMountToolExecutionOutput(
            toolCall(name: toolName, input: payload),
            isUserInitiated: false,
            runId: runId,
            conversationId: conversationId
        )
        switch output {
        case .failed(let reason):
            return .failed(reason: reason)
        case .needsUserAction(let reason):
            return .denied(reason: reason)
        case .denied(let reason):
            return .denied(reason: reason)
        case .webMountResult(let text):
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            // 先判工具级错误：ok:false / 失败 status 不得落到重观察 fallback
            // 被吞成 applied（此前缺 snapshot_id 的动作全在此被误记已应用）。
            if let mapped = Self.webMountLoopActionResult(object) {
                return mapped
            }
            // 输出未带 revision：重观察一次取值（保持无进展判定有效）。
            if let observation = await webMountLoopObservation(sessionId: sessionId, runId: runId, conversationId: conversationId) {
                return .applied(newRevision: observation.revision)
            }
            return .failed(reason: "动作后无法确认页面状态。")
        default:
            return .failed(reason: "WebMount 动作返回了不支持的输出。")
        }
    }

    /// 工具输出 JSON → ExecutorResult。返回 nil = 成功但未带 revision（调用方
    /// 重观察取值）。错误/stale/审批/unknown 全部显式映射，不吞。
    static func webMountLoopActionResult(
        _ object: [String: Any]?
    ) -> IOSJevWebMountLoopService.ExecutorResult? {
        guard let object else { return nil }
        let status = (object["status"] as? String)?.lowercased()
        let code = (object["error_code"] as? String)?.lowercased()
        let key = status ?? code
        if key == "unknown_after_action" { return .unknown }
        let failed = (object["ok"] as? Bool == false) || status == "failed" || status == "error"
        if failed {
            // 工具级快照/元素失效与循环 .stale 同语义：重观察重决策，不算失败。
            // stale_ref = 目标 ref 在派发点已死（frame 文档替换等），可恢复。
            let staleKeys: Set<String> = ["stale_snapshot", "stale_ref"]
            if staleKeys.contains(key ?? "") || staleKeys.contains(code ?? "") { return .stale }
            // 本地 gate 产出 needs_user_action/requires_human 布尔位（无 status
            // 字段）——与 status 形态等价映射 .denied：语义是需要用户处理，
            // 不是动作执行失败。
            if (object["needs_user_action"] as? Bool == true)
                || (object["requires_human"] as? Bool == true) {
                return .denied(reason: webMountResultReason(object) ?? "动作需要用户处理。")
            }
            switch key {
            case "approval_required", "requires_human":
                return .denied(reason: webMountResultReason(object) ?? key ?? "动作需要用户处理。")
            default:
                return .failed(reason: webMountResultReason(object) ?? key ?? "WebMount 动作失败。")
            }
        }
        if let revision = (object["page_revision"] as? NSNumber).flatMap({ Int($0.doubleValue) }) {
            return .applied(newRevision: revision)
        }
        return nil
    }

    /// 错误输出里的可读原因：reason / error(string|dict.message) / error_code。
    private static func webMountResultReason(_ object: [String: Any]) -> String? {
        if let reason = (object["reason"] as? String)?.nilIfBlank { return reason }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        if let error = object["error"] as? [String: Any],
           let message = (error["message"] as? String)?.nilIfBlank { return message }
        if let code = (object["error_code"] as? String)?.nilIfBlank { return code }
        return nil
    }

    /// 动作 → 既有工具调用映射。只映射循环白名单内的动作；wm_* 变更工具
    /// required session_id+snapshot_id（绑定决策快照，stale 由工具拒收）。
    static func webMountLoopActionCall(
        sessionId: String,
        action: IOSJevWebMountLoopService.PlannedAction
    ) -> (String, String)? {
        var payload: [String: Any] = ["session_id": sessionId, "snapshot_id": action.snapshotId]
        switch action.kind {
        case .scroll:
            // 逐段下滚由观察反馈驱动（不用 to:bottom 跳页——会跳过目标可视区）。
            payload["by_y"] = 700
            return ("wm_scroll", webMountJSON(payload))
        case .clickNav:
            guard let elementId = action.elementId else { return nil }
            payload["target"] = elementId
            return ("wm_click", webMountJSON(payload))
        case .select:
            guard let elementId = action.elementId else { return nil }
            payload["target"] = elementId
            return ("wm_select", webMountJSON(payload))
        case .typeDraft, .submitReadonlySearch:
            // 均经 wm_type 填草稿词；Enter/提交键留在白名单外（保守边界），
            // 搜索候选项经下轮观察进入 click_nav 候选。
            guard let elementId = action.elementId, let value = action.value, !value.isEmpty else { return nil }
            payload["target"] = elementId
            payload["text"] = value
            return ("wm_type", webMountJSON(payload))
        }
    }

    private static func webMountJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func dispatchMemoryToolCall(
        _ toolCall: UIMessagePart.Tool,
        writePolicy: IOSMemoryToolWritePolicy
    ) -> String {
        IOSMemoryToolExecutor.execute(
            input: toolCall.input,
            runtime: sharedSettings.agentRuntime,
            writePolicy: writePolicy
        )
    }

    private func memoryToolWritePolicy(input: String, isUserInitiated: Bool) -> IOSMemoryToolWritePolicy {
        localToolExecutor?.memoryToolWritePolicy(
            input: input,
            isUserInitiated: isUserInitiated,
            executionPolicy: IOSExecutionPolicyContext.snapshot
        ) ?? (IOSMemoryToolExecutor.requiresWriteApproval(input: input)
            ? .needsUserAction("Memory writes require foreground approval.")
            : .allow)
    }

    private func dispatchImageToolCall(
        _ toolCall: UIMessagePart.Tool,
        messages: [UIMessage] = []
    ) async -> [UIMessagePart] {
        let enrichedInput: String
        switch ChatImageGenerationReference.enrichToolInput(toolCall.input, messages: messages) {
        case .success(let input):
            enrichedInput = input
        case .failure(.attachedImageRequestedButMissing):
            return [UIMessagePart.Text(
                text: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: "generate_image",
                    reason: "当前消息没有可垫的附图。请先上传参考图，或改用文字描述重新生成。"
                ),
                metadata: nil
            )]
        }
        let resolvedToolCall = UIMessagePart.Tool(
            toolCallId: toolCall.toolCallId,
            toolName: toolCall.toolName,
            input: enrichedInput,
            output: toolCall.output,
            approvalState: toolCall.approvalState,
            streamIndex: toolCall.streamIndex,
            metadata: toolCall.metadata
        )

        do {
            switch codexImageConfig() {
            case let .signedIn(codex, imageModelID, preferredRoutingModelID):
                let request = try IOSImageGenerationRepository.shared.toolRequest(
                    from: resolvedToolCall.input,
                    modelId: imageModelID
                )
                let record = try await IOSImageGenerationRepository.shared.generateViaCodex(
                    request: request,
                    providerId: codex,
                    preferredRoutingModelID: preferredRoutingModelID
                )
                var parts: [UIMessagePart] = record.files.map { file in
                    UIMessagePart.Image(
                        url: IOSImageGenerationRepository.chatImageURLString(filePath: file.path),
                        metadata: nil
                    )
                }
                parts.append(UIMessagePart.Text(text: IOSImageGenerationRepository.shared.toolResultJSON(record: record), metadata: nil))
                return parts
            case .notSignedIn:
                return [UIMessagePart.Text(
                    text: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: "generate_image",
                        reason: "请先在服务商设置里登录 Codex 后再生成或修改图片。"
                    ),
                    metadata: nil
                )]
            case .notSelected:
                break
            }
            guard let config = resolvedImageGenerationConfig() else {
                return [UIMessagePart.Text(
                    text: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: "generate_image",
                        reason: "请先在「默认模型 → 辅助任务」里设置生图模型。"
                    ),
                    metadata: nil
                )]
            }
            let request = try IOSImageGenerationRepository.shared.toolRequest(
                from: resolvedToolCall.input,
                modelId: config.modelId
            )
            if request.sourceImageURL != nil {
                return [UIMessagePart.Text(
                    text: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: "generate_image",
                        reason: "当前图片修改只支持 Codex 生图。"
                    ),
                    metadata: nil
                )]
            }
            let record = try await IOSImageGenerationRepository.shared.generate(
                request: request,
                apiKey: config.apiKey,
                baseURL: config.baseURL
            )
            var parts: [UIMessagePart] = record.files.map { file in
                UIMessagePart.Image(
                    url: IOSImageGenerationRepository.chatImageURLString(filePath: file.path),
                    metadata: nil
                )
            }
            parts.append(UIMessagePart.Text(text: IOSImageGenerationRepository.shared.toolResultJSON(record: record), metadata: nil))
            return parts
        } catch {
            return [
                UIMessagePart.Text(
                    text: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: "generate_image",
                        reason: error.localizedDescription
                    ),
                    metadata: nil
                )
            ]
        }
    }

    private func dispatchAdvancedToolCall(
        _ toolCall: UIMessagePart.Tool,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        conversationId: KotlinUuid? = nil,
        nestedTools: IOSJsSandboxTools? = nil,
        toolExposureBridge: IosToolExposureBridge? = nil
    ) async -> String {
        guard isAdvancedToolEnabled(toolCall.toolName) else {
            return IOSWorkspaceStore.json([
                "ok": false,
                "tool": toolCall.toolName,
                "status": "denied",
                "denied": true,
                "policy": "disabled",
                "reason": "\(toolCall.toolName) 未开启。请先在设置中启用对应能力。"
            ])
        }
        switch toolCall.toolName {
        case IOSWeatherToolCatalog.toolName:
            return await IOSWeatherToolExecutor.execute(input: toolCall.input)
        case IOSHealthAgentToolCatalog.toolName:
            return await IOSHealthAgentToolExecutor.execute(input: toolCall.input)
        case let name where IOSAppleAgentToolCatalog.eventKitToolNames.contains(name):
            return await IOSEventKitAgentToolExecutor.execute(toolName: name, input: toolCall.input)
        case let name where IOSAppleAgentToolCatalog.notificationToolNames.contains(name):
            return await IOSNotificationAgentToolExecutor.execute(toolName: name, input: toolCall.input)
        case let name where IOSAppleAgentToolCatalog.alarmToolNames.contains(name):
            return await IOSAlarmAgentToolExecutor.execute(toolName: name, input: toolCall.input)
        case let name where IOSAppleAgentToolCatalog.workoutToolNames.contains(name):
            return await IOSWorkoutAgentToolExecutor.execute(toolName: name, input: toolCall.input)
        case "subagent_dispatch":
            let args = ChatToolCallParsing.jsonObject(toolCall.input)
            let maxLegacySubAgents = min(10, max(1, sharedSettings.subAgentMaxConcurrentRuns))
            guard activeLegacySubAgentRuns < maxLegacySubAgents else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "并发运行数已达上限（\(maxLegacySubAgents) 个子代理）。",
                    status: "agent_limit_reached"
                )
            }
            activeLegacySubAgentRuns += 1
            defer { activeLegacySubAgentRuns -= 1 }
            let customRolePrompt = args?["custom_role_prompt"] as? String
            let isCustomRole = customRolePrompt?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            if !sharedSettings.allowsDynamicSubAgents, isCustomRole {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName, reason: "动态子代理开关已关闭，请使用已配置的内置角色。"
                )
            }
            let objective = args?["objective"] as? String ?? toolCall.input
            let roleId = args?["role_id"] as? String ?? args?["subagent_id"] as? String ?? "explorer"
            let scope = ChatToolCallParsing.stringArray(args?["tool_scope"])
                ?? ChatToolCallParsing.stringArray(args?["tools"])
                ?? []
            let settingsSnapshot = sharedSettings.snapshot
            let roleOverride = settingsSnapshot.agentRuntime.subAgent.overrides[roleId]
            let expandedMcpDeclarations = expandedMcpToolDeclarations(mcpManager: mcpManager)
            let expandedMcpNames = Set(expandedMcpDeclarations.map(\.name))
            let roleDefaultToolNames = IOSSubAgentRoleCatalog.defaultToolNames(
                roleId: roleId,
                availableToolNames: ToolKt.iosToolDeclarationNames() + expandedMcpDeclarations.map(\.name),
                mcpServers: mcpManager.servers
            )
            let requestedMcpNames = Set(scope.filter { expandedMcpNames.contains($0) })
            let allowedMcpNames: Set<String>
            if isCustomRole {
                // A one-off role gets MCP only when this invocation names the
                // currently enabled/discovered tool explicitly.
                allowedMcpNames = requestedMcpNames
            } else if let configuredToolNames = roleOverride?.toolAllowlist {
                // A saved built-in allowlist is the upper bound for task-level
                // scope; an explicit task scope cannot grant another MCP tool.
                allowedMcpNames = Set(configuredToolNames).intersection(expandedMcpNames)
            } else {
                allowedMcpNames = Set(roleDefaultToolNames).intersection(expandedMcpNames)
            }
            let mcpDeclarations = expandedMcpDeclarations.filter { allowedMcpNames.contains($0.name) }
            var effectiveToolAllowlistOverride = roleOverride?.toolAllowlist.map { Array($0) }
            if isCustomRole, !requestedMcpNames.isEmpty {
                effectiveToolAllowlistOverride = Array(
                    IOSSubAgentToolPolicy.readOnlyParentToolNames.union(requestedMcpNames)
                )
            } else if !isCustomRole, roleOverride?.toolAllowlist == nil, !allowedMcpNames.isEmpty {
                effectiveToolAllowlistOverride = roleDefaultToolNames
            }
            let skillContext: String?
            if let defaultSkillNames = roleOverride?.defaultSkillNames, !defaultSkillNames.isEmpty {
                do {
                    skillContext = try IOSSkillMcpToolService.loadEnabledSkillContext(
                        skillNames: defaultSkillNames,
                        enabledSkillNames: sharedSettings.currentAssistantEnabledSkillNames
                    )
                } catch {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName,
                        reason: "子代理默认技能不可用：\(error.localizedDescription)"
                    )
                }
            } else {
                skillContext = nil
            }
            let poolCandidates = subAgentModelPool.candidates(
                settings: settingsSnapshot,
                sharedSettings: sharedSettings
            )
            let explicitModelId = (args?["model_id"] as? String).flatMap { raw -> String? in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            let explicitReasoningRaw = (args?["reasoning_level"] as? String).flatMap { raw -> String? in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            let selectedPoolCandidate: IOSSubAgentModelPool.Candidate?
            if let explicitModelId {
                guard let parsed = Self.parseSubAgentModelUUID(explicitModelId),
                      let candidate = subAgentModelPool.candidate(
                        for: parsed.toHexDashString(),
                        from: poolCandidates
                      ) else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName,
                        reason: "显式 model_id 必须是当前用户模型池中的可用模型：\(explicitModelId)"
                    )
                }
                selectedPoolCandidate = candidate
            } else if roleOverride?.modelId == nil, !poolCandidates.isEmpty {
                selectedPoolCandidate = subAgentModelPool.select(
                    from: poolCandidates,
                    activeModelCounts: activeLegacyModelCounts,
                    activeProviderCounts: activeLegacyProviderCounts
                )
            } else if roleOverride?.modelId == nil,
                      settingsSnapshot.agentRuntime.subAgent.modelPool.isEmpty == false {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "模型池中的模型均已停用、移除或配置不可用。"
                )
            } else {
                selectedPoolCandidate = nil
            }
            let selectedModel = selectedPoolCandidate?.model
                ?? roleOverride?.modelId.flatMap { settingsSnapshot.findModelById(uuid: $0) }
            let selectedProvider = selectedPoolCandidate?.provider ?? selectedModel.flatMap {
                ChatProviderConfiguration.provider(for: $0, providers: settingsSnapshot.providers)
            }
            if roleOverride?.modelId != nil, selectedPoolCandidate == nil {
                guard let selectedModel else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName, reason: "子代理配置的模型已不存在，请重新选择模型。"
                    )
                }
                if let issue = ChatProviderConfiguration.issue(for: selectedModel, provider: selectedProvider) {
                    return ChatToolOutputFormatter.toolFailureJSON(toolName: toolCall.toolName, reason: issue.message)
                }
            }
            let effectiveReasoningOverride: ReasoningLevel?
            if let explicitReasoningRaw {
                guard let parsed = Self.reasoningLevel(named: explicitReasoningRaw) else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName,
                        reason: "reasoning_level 无效：\(explicitReasoningRaw)"
                    )
                }
                let reasoningModelId = selectedModel?.id.toHexDashString() ?? params.model.id.toHexDashString()
                let supported = sharedSettings.subAgentReasoningLevels(modelId: reasoningModelId)
                guard supported.contains(parsed) else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName,
                        reason: "模型不支持 reasoning_level=\(explicitReasoningRaw)。"
                    )
                }
                effectiveReasoningOverride = parsed
            } else if let selectedPoolCandidate {
                effectiveReasoningOverride = selectedPoolCandidate.configuredReasoning
                    .flatMap { selectedPoolCandidate.supportedReasoning.contains($0) ? $0 : nil }
                    ?? subAgentModelPool.defaultReasoning(for: selectedPoolCandidate)
            } else {
                effectiveReasoningOverride = roleOverride?.reasoningLevel
            }
            let runParams: TextGenerationParams
            if let selectedModel, let selectedProvider,
               selectedModel.id != params.model.id || effectiveReasoningOverride != nil {
                let assistant = settingsSnapshot.getCurrentAssistant()
                runParams = TextGenerationParams(
                    model: selectedModel,
                    temperature: params.temperature,
                    topP: params.topP,
                    maxTokens: params.maxTokens,
                    tools: params.tools,
                    reasoningLevel: effectiveReasoningOverride ?? params.reasoningLevel,
                    customHeaders: IOSProviderRequestHeaderStore.headers(for: selectedProvider.id.description())
                        + assistant.customHeaders + selectedModel.customHeaders,
                    customBody: assistant.customBodies + selectedModel.customBodies
                )
            } else {
                runParams = params
            }
            let modelReservation = selectedPoolCandidate.map { subAgentModelPool.reserve($0) }
            if let selectedPoolCandidate {
                activeLegacyModelCounts[selectedPoolCandidate.modelId, default: 0] += 1
                activeLegacyProviderCounts[selectedPoolCandidate.providerId, default: 0] += 1
            }
            defer {
                subAgentModelPool.release(modelReservation)
                if let selectedPoolCandidate {
                    decrementLegacyCount(&activeLegacyModelCounts, key: selectedPoolCandidate.modelId)
                    decrementLegacyCount(&activeLegacyProviderCounts, key: selectedPoolCandidate.providerId)
                }
            }
            let globalTimeoutSeconds = min(
                3_600,
                max(1, Double(settingsSnapshot.agentRuntime.subAgent.timeoutMs) / 1_000)
            )
            let roleTimeoutSeconds = roleOverride?.timeoutMsOverride.map {
                min(3_600, max(1, Double(truncating: $0) / 1_000))
            } ?? TimeInterval(IOSSubAgentRoleCatalog.resolve(roleId: roleId)?.timeoutSeconds ?? 300)
            let timeoutSeconds = min(globalTimeoutSeconds, roleTimeoutSeconds)
            return await subAgentRunner.runViaEngine(
                objective: objective,
                roleId: roleId,
                requestedToolScope: scope,
                customRoleName: args?["custom_role_name"] as? String,
                customRoleLens: args?["custom_role_lens"] as? String,
                customRolePrompt: customRolePrompt,
                skillContext: skillContext,
                savedRolePromptOverride: roleOverride?.systemPrompt,
                toolAllowlistOverride: effectiveToolAllowlistOverride,
                maxTurnsOverride: (args?["max_turns"] as? Int)
                    ?? roleOverride?.maxTurnsOverride.map { Int(truncating: $0) },
                outputBudgetCharsOverride: (args?["output_budget_chars"] as? Int)
                    ?? roleOverride?.outputBudgetOverride.map { Int(truncating: $0) },
                providerSetting: selectedProvider ?? providerSetting,
                modelId: selectedModel?.modelId ?? params.model.modelId,
                baseParams: runParams,
                modelOverride: selectedModel,
                temperatureOverride: roleOverride?.temperature.map { Float(truncating: $0) },
                reasoningLevelOverride: effectiveReasoningOverride,
                additionalToolDeclarations: mcpDeclarations,
                parentToolExecutors: subAgentParentToolExecutors(
                    runId: runId,
                    conversationId: conversationId?.description() ?? "",
                    additionalToolNames: Set(mcpDeclarations.map(\.name))
                ),
                toolCallId: toolCall.toolCallId,
                sourceConversationId: conversationId?.toHexDashString(),
                timeoutSeconds: timeoutSeconds
            )
        case "model_council_run":
            let args = ChatToolCallParsing.jsonObject(toolCall.input)
            let objective = args?["objective"] as? String ?? toolCall.input
            let maxSeats = args?["max_seats"] as? Int
            return await councilRunner.run(
                objective: objective,
                maxSeats: maxSeats,
                providerSetting: providerSetting,
                currentModel: params.model,
                baseParams: params
            )
        case "mcp_call":
            guard let args = ChatToolCallParsing.jsonObject(toolCall.input),
                  let server = args["server"] as? String,
                  let tool = args["tool"] as? String else {
                return "mcp_call 参数无效：需要 server 与 tool。"
            }
            let arguments = (args["arguments"] as? [String: Any]) ?? [:]
            do {
                return try await mcpManager.callTool(
                    serverName: server,
                    toolName: tool,
                    arguments: arguments,
                    enabledOverride: isMcpNetworkAllowed()
                )
            } catch {
                // P2-a：失败输出必须是结构化 JSON（与 search 路径同契约），否则
                // failureReason 识别不到 → 误把失败调用标成 POLLUTED。
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "MCP 调用失败（server: \(server)，tool: \(tool)）：\(error.localizedDescription)",
                    status: "failed"
                )
            }
        case let name where ToolKt.isExpandedMcpToolName(name: name):
            // P0-b: prefix routing — the flattened name is resolved against the
            // CURRENT discovery directory (sanitization is not reversible).
            // A name whose server/tool vanished mid-run gets an honest
            // status=failed payload, never a crash.
            guard let target = resolvedMcpTarget(forExpandedName: name) else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: name,
                    reason: "MCP 工具已不可用：当前已启用的 server 中不存在该工具。请调用 mcp_list 检查可用的 MCP 工具。",
                    status: "failed"
                )
            }
            guard let arguments = ChatToolCallParsing.jsonObject(toolCall.input) else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: name,
                    reason: "MCP 工具参数无效：需要 JSON 对象。",
                    status: "failed"
                )
            }
            do {
                return try await mcpManager.callTool(
                    serverName: target.server,
                    toolName: target.tool,
                    arguments: arguments,
                    enabledOverride: isMcpNetworkAllowed()
                )
            } catch {
                // P2-a：与 mcp_call 同一契约——结构化失败输出，failureReason 可识别，
                // 不把失败调用误标成 POLLUTED。
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: name,
                    reason: "MCP 调用失败（server: \(target.server)，tool: \(target.tool)）：\(error.localizedDescription)",
                    status: "failed"
                )
            }
        case let name where IOSSkillToolCatalog.toolNames.contains(name)
            || IOSMcpManagementToolCatalog.toolNames.contains(name):
            return await skillMcpToolService.execute(
                toolName: name,
                arguments: toolCall.input,
                mcpEnabledOverride: isMcpNetworkAllowed()
            )
        case let name where IOSRecipeToolCatalog.toolNames.contains(name) && name != "recipe_import":
            return await recipeToolService.execute(toolName: name, arguments: toolCall.input)
        case let name where IOSPluginToolCatalog.toolNames.contains(name) && name != "plugin_import":
            return await pluginToolService.execute(toolName: name, arguments: toolCall.input)
        case "recipe_import":
            // Host-publish apply lives in executeAdvancedToolCall / background
            // host-publish; this dispatch table must not silently import.
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "Recipe 导入需要查看候选变更并显式批准。",
                status: "failed"
            )
        case "plugin_import":
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "插件导入需要查看候选能力并显式批准。",
                status: "failed"
            )
        case "spawn_agent", "list_agents", "interrupt_agent", "send_message", "followup_task", "wait_agent":
            // P1-c/P1-d: 线程编排工具走独立服务（会话 fork / edge / mailbox / 子 run
            // 启动与取消全部收口在服务内；未注入时诚实报错而非静默缺失）。
            // conversationId = run 锚定会话（前台由 pending/conversationId 透传，
            // 后台由 job 透传）——生成中切会话不会建错边或误拒。
            guard let orchestrationToolService else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "线程编排工具当前不可用。",
                    status: "failed"
                )
            }
            return await orchestrationToolService.execute(
                toolName: toolCall.toolName,
                arguments: toolCall.input,
                providerSetting: providerSetting,
                params: params,
                runId: runId,
                conversationId: conversationId,
                // M3: 子 run 的 fullToolNames 取 run 桥全目录（spawn/followup
                // 不被当轮可见子集截断）；nil 时服务回退 params.tools。
                toolExposureBridge: toolExposureBridge,
                executionPolicy: IOSExecutionPolicyContext.snapshot
            )
        case let name where IOSProviderConfigToolCatalog.toolNames.contains(name):
            return await providerConfigToolService.execute(
                toolName: name,
                argumentsJSON: toolCall.input
            )
        case let name where IOSThemePackToolCatalog.toolNames.contains(name):
            return themePackToolService.execute(
                toolName: name,
                argumentsJSON: toolCall.input
            )
        case "exec":
            // P3-b: exec 求值可带嵌套 tools 桥（白名单 + 宿主 runner 由
            // executeAdvancedToolCall 传入；nil = 纯求值，同 P3-a）。
            // P3-c: conversationId = 会话作用域键（cell 注册表 + store/load）。
            return await dispatchExecToolCall(
                toolCall,
                nestedTools: nestedTools,
                conversationId: conversationId
            )
        case "wait":
            // P3-c: 续取本会话的 exec cell（yield/wait/terminate 三路径）。
            return await dispatchWaitToolCall(toolCall, conversationId: conversationId)
        default:
            return "未知工具：\(toolCall.toolName)"
        }
    }

    /// P3-c: wait timeout clamp (declaration contract: [1000, 60000], default 10000).
    static func clampWaitTimeoutMs(_ value: Int) -> Int {
        min(max(value, 1000), 60000)
    }

    /// P3-d: max_output_chars hard cap (declaration contract: [1, 100000],
    /// default 10000). The returned payload lands in the tool output and the
    /// ledger, so a model-supplied unbounded limit must not bypass truncation.
    static let maxOutputCharsHardCap = 100000

    static func clampMaxOutputChars(_ value: Int) -> Int {
        min(max(value, 1), maxOutputCharsHardCap)
    }

    /// P3-c: one `exec` call with the cell lifecycle.
    ///
    /// Every evaluation registers a Running cell first (per-session
    /// concurrency cap of 4, enforced before any JS runs). On timeout the
    /// handle is NOT dropped: exec returns the codex wording
    /// "Script running with cell ID {cell_id}" and the evaluation keeps
    /// running on its own queue (abandon semantics); the completion listener
    /// delivers the eventual result to the registry so a later `wait` can
    /// retrieve it. Inline terminal (success/failure within the timeout) cells
    /// are consumed here — the model never saw a cell_id, so nothing can wait
    /// on them (read-once, zero residue).
    private func dispatchExecToolCall(
        _ toolCall: UIMessagePart.Tool,
        nestedTools: IOSJsSandboxTools? = nil,
        conversationId: KotlinUuid? = nil
    ) async -> String {
        guard let args = ChatToolCallParsing.jsonObject(toolCall.input),
              let code = args["code"] as? String, !code.isEmpty else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "exec 参数无效：需要非空 code（JavaScript 源码）。"
            )
        }
        let timeoutMs = IOSJsSandboxEngine.clampTimeoutMs(
            (args["timeout_ms"] as? Int) ?? IOSJsSandboxEngine.defaultTimeoutMs
        )
        let maxOutputChars = Self.clampMaxOutputChars(
            (args["max_output_chars"] as? Int)
                ?? IOSJsSandboxEngine.defaultMaxOutputChars
        )
        let sessionKey = conversationId?.description() ?? "global"
        let cellId = UUID().uuidString

        let started = await jsCellRegistry.startCell(sessionKey: sessionKey, cellId: cellId)
        guard started == .started else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "exec 并发 cell 已达上限（每会话 \(IOSJsCellRegistry.maxRunningCellsPerSession) 个）。请先 wait 或 terminate 已有 cell。",
                status: "failed"
            )
        }

        // P3-c: session-scoped store/load bridge — shared by every cell of the
        // conversation, persisted by the registry (single writer).
        let storeBridge = IOSJsSandboxStore(
            load: { [registry = jsCellRegistry] key in
                await registry.loadValue(sessionKey: sessionKey, key: key)
            },
            store: { [registry = jsCellRegistry] key, value in
                switch await registry.storeValue(sessionKey: sessionKey, key: key, valueJSON: value) {
                case .stored:
                    return nil
                case .overLimit(let reason):
                    return reason
                }
            }
        )
        let result = await jsSandboxEngine.evaluate(
            code: code,
            timeoutMs: timeoutMs,
            maxOutputChars: maxOutputChars,
            tools: nestedTools,
            store: storeBridge,
            completion: { [registry = jsCellRegistry] final in
                Task { @Sendable in
                    await registry.finishCell(
                        sessionKey: sessionKey,
                        cellId: cellId,
                        result: final,
                        maxOutputChars: maxOutputChars
                    )
                }
            }
        )
        switch result {
        case .success, .failure:
            // Inline terminal: exec's own payload carries the result/error;
            // consume the cell (nothing can reference it without a cell_id).
            await jsCellRegistry.removeCell(sessionKey: sessionKey, cellId: cellId)
            return IOSJsSandboxEngine.toolPayload(result, maxOutputChars: maxOutputChars)
        case .timedOut:
            // P3-c yield: the cell keeps running; the model continues it with
            // wait(cell_id). The evaluation's completion listener will deliver
            // the eventual result to the registry.
            return IOSWorkspaceStore.json([
                "status": "running",
                "cell_id": cellId,
                "output": "Script running with cell ID \(cellId)",
            ])
        }
    }

    /// P3-c: one `wait` call — the three paths:
    /// - cell missing → structured error (never silent).
    /// - `terminate: true` → mark Terminated (abandon semantics: JavaScriptCore
    ///   cannot force-kill the runaway script; it keeps burning CPU until it
    ///   ends by itself, and its result is discarded) and return the terminal.
    /// - otherwise block until the cell completes or the wait timeout elapses
    ///   (clamped [1000, 60000], default 10000); a still-running cell returns
    ///   its current running status so the model can wait again.
    /// Every wait is an ordinary tool call — it consumes one tool-resume
    /// budget slot via the existing maxToolResumeCount/maxSteps machinery, no
    /// separate budget mechanism.
    private func dispatchWaitToolCall(
        _ toolCall: UIMessagePart.Tool,
        conversationId: KotlinUuid?
    ) async -> String {
        guard let args = ChatToolCallParsing.jsonObject(toolCall.input),
              let cellId = args["cell_id"] as? String, !cellId.isEmpty else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "wait 参数无效：需要 cell_id（exec 超时 yield 返回的 cell ID）。"
            )
        }
        let timeoutMs = Self.clampWaitTimeoutMs(
            (args["timeout_ms"] as? Int) ?? IOSJsSandboxEngine.defaultTimeoutMs
        )
        let terminate = (args["terminate"] as? Bool) ?? false
        let sessionKey = conversationId?.description() ?? "global"
        let outcome = await jsCellRegistry.wait(
            cellId: cellId,
            sessionKey: sessionKey,
            timeoutMs: timeoutMs,
            terminate: terminate
        )
        switch outcome {
        case .notFound:
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "cell \(cellId) 不存在或已读取。exec 超时会返回 cell ID；同一 cell 的输出只可读取一次。",
                status: "failed"
            )
        case .stillRunning:
            return IOSWorkspaceStore.json([
                "status": "running",
                "cell_id": cellId,
                "output": "Script running with cell ID \(cellId)",
            ])
        case .cancelled:
            // M6: run 取消期间 wait 立即收口（不等超时）——结构化终态，不冒充
            // running/超时；cell 保持 Running 可再 wait。
            return IOSWorkspaceStore.json([
                "status": "cancelled",
                "cell_id": cellId,
            ])
        case .terminal(let record):
            var object: [String: Any] = [
                "status": record.status.rawValue,
                "output": record.output ?? NSNull(),
                "logs": record.logs,
            ]
            if let error = record.error {
                object["error"] = error
            }
            return IOSWorkspaceStore.json(object)
        }
    }

    private func subAgentParentToolExecutors(
        runId: String,
        conversationId: String,
        additionalToolNames: Set<String> = []
    ) -> [String: any IOSToolExecutor] {
        // Browser-capable roles opt into this second set. The LocalToolExecutor
        // still applies the normal WebMount permission and session-binding
        // checks; registering the adapter only makes the selected names
        // executable when that parent gate allows them.
        let allowedNames = IOSSubAgentToolPolicy.readOnlyParentToolNames
            .union(IOSSubAgentToolPolicy.browserAutomationToolNames)
            .union(additionalToolNames)
        return Dictionary(uniqueKeysWithValues: allowedNames.map { name in
            (name, IOSClosureToolExecutor { [weak self] toolName, arguments, _ in
                guard let self else {
                    return .failed("Chat runtime is unavailable.")
                }
                return await self.executeSubAgentParentTool(
                    name: toolName,
                    arguments: arguments,
                    runId: runId,
                    conversationId: conversationId
                )
            } as any IOSToolExecutor)
        })
    }

    private func executeSubAgentParentTool(
        name: String,
        arguments: String,
        runId: String,
        conversationId: String
    ) async -> IOSAgentToolOutcome {
        guard IOSSubAgentToolPolicy.readOnlyParentToolNames.contains(name)
            || IOSSubAgentToolPolicy.browserAutomationToolNames.contains(name)
            || ToolKt.isExpandedMcpToolName(name: name) else {
            return .denied("SubAgent parent scope does not allow \(name).")
        }

        if IOSSearchExecutor.supportedToolNames.contains(name) {
            let output = await dispatchSearchToolCall(toolCall(name: name, input: arguments))
            recordSubAgentParentToolApproval(
                toolName: name,
                arguments: arguments,
                action: .allowed,
                runId: runId
            )
            return .filled(output)
        }

        // runtime_status：本地自省只读，不经 localToolExecutor（无 capability
        // 映射）；子代理 catalog 无桥上下文，传 nil 只省略目录计数。
        if name == "runtime_status" {
            return .filled(dispatchRuntimeStatusToolCall(
                toolCall(name: name, input: arguments),
                toolExposureBridge: nil
            ))
        }

        if ToolKt.isExpandedMcpToolName(name: name) {
            guard let target = resolvedMcpTarget(forExpandedName: name),
                  let mcpArguments = ChatToolCallParsing.jsonObject(arguments) else {
                return .failed("MCP tool \(name) is unavailable or its arguments are not a JSON object.")
            }
            guard let discovered = mcpManager.tools.first(where: {
                $0.serverName == target.server
                    && $0.tool.name == target.tool
            }) else {
                return .failed("MCP tool \(name) is no longer in the current discovery directory.")
            }
            // Read-only MCP tools can run under the parent network gate. A
            // tool without a read-only hint is treated as high-risk and can
            // run only when the same high-risk auto-approval already used by
            // foreground mcp_call is active.
            guard discovered.tool.readOnlyHint == true || effectiveHighRiskAutoApproveEnabled else {
                return .denied("MCP tool \(name) is not marked read-only; enable high-risk auto-approval or run it in the foreground.")
            }
            do {
                let output = try await mcpManager.callTool(
                    serverName: target.server,
                    toolName: target.tool,
                    arguments: mcpArguments,
                    enabledOverride: isMcpNetworkAllowed()
                )
                recordSubAgentParentToolApproval(
                    toolName: name,
                    arguments: arguments,
                    action: .allowed,
                    runId: runId
                )
                return .filled(output)
            } catch {
                recordSubAgentParentToolApproval(
                    toolName: name,
                    arguments: arguments,
                    action: .denied,
                    runId: runId
                )
                return .failed("MCP 调用失败（server: \(target.server)，tool: \(target.tool)）：\(error.localizedDescription)")
            }
        }

        guard let localToolExecutor else {
            return .failed("Local iOS tool executor is unavailable.")
        }

        let request = localToolExecutor.executionRequest(
            toolName: name,
            operation: arguments,
            isUserInitiated: name == "file_read_selected",
            runId: runId,
            conversationId: conversationId,
            executionPolicy: IOSExecutionPolicyContext.snapshot
        )
        let output = await localToolExecutor.execute(request)
        recordSubAgentParentToolApproval(
            toolName: name,
            arguments: arguments,
            action: output.isSuccessfulToolResult ? .allowed : .denied,
            runId: runId,
            request: request
        )
        return ChatToolOutputFormatter.subAgentOutcome(for: name, output: output)
    }

    private func recordSubAgentParentToolApproval(
        toolName: String,
        arguments: String,
        action: IOSToolApprovalAction,
        runId: String,
        request: IOSLocalToolExecutionRequest? = nil
    ) {
        guard let localToolExecutor,
              let capability = IOSCapabilityRegistry.capability(forToolName: toolName) else { return }
        let auditRequest = request ?? localToolExecutor.executionRequest(
            toolName: toolName,
            operation: arguments,
            isUserInitiated: false,
            runId: runId,
            executionPolicy: IOSExecutionPolicyContext.snapshot
        )
        localToolExecutor.recordApproval(
            capabilityId: capability.id,
            toolName: toolName,
            action: action,
            reason: "SubAgent read-only parent tool \(action == .allowed ? "executed" : "denied").",
            runId: runId,
            scopeDigest: auditRequest.scopeDigest,
            payloadDigest: auditRequest.payloadDigest,
            policyDigest: auditRequest.executionPolicy?.digest
        )
    }

    private func toolCall(name: String, input: String) -> UIMessagePart.Tool {
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
    private func recordToolApproval(
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

    private func messagesByFinishingToolCall(
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
                return UIMessagePart.Tool(
                    toolCallId: toolPart.toolCallId,
                    toolName: toolPart.toolName,
                    input: persistedInput,
                    // 工具输出统一收口：总文本超上限就地截断（JSON 形态保形），
                    // 防止 Exa 全文等巨量输出被持久化进会话。
                    output: ChatToolOutputFormatter.cappedToolOutputParts(outputParts),
                    approvalState: toolPart.approvalState,
                    streamIndex: toolPart.streamIndex,
                    metadata: nil
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

    private var isWebMountRuntimeEnabled: Bool {
        true
    }

    /// P0-b: resolve a flattened `mcp__{server}__{tool}` name back to the
    /// discovery directory (enabled servers only). Sanitization is not
    /// reversible, so this is the authoritative lookup for execution routing.
    private func resolvedMcpTarget(forExpandedName name: String) -> (server: String, tool: String)? {
        let enabledServerNames = Set(mcpManager.servers.filter(\.enabled).map(\.name))
        for discovered in mcpManager.tools
            where enabledServerNames.contains(discovered.serverName) && discovered.tool.enabled {
            if ToolKt.expandedMcpToolName(server: discovered.serverName, tool: discovered.tool.name) == name {
                return (discovered.serverName, discovered.tool.name)
            }
        }
        return nil
    }

    /// P0-b: flattened MCP declarations over the CURRENT directory. The
    /// background job regenerates them so its exposure bridge catalog stays in
    /// parity with the foreground run — handoff payloads carry tool NAMES only,
    /// and dynamic `mcp__*` tools cannot be rebuilt from a name.
    func mcpExpandedDeclarations() -> [Tool] {
        expandedMcpToolDeclarations(mcpManager: mcpManager)
    }

    private func isMcpNetworkAllowed() -> Bool {
        let masterEnabled = IOSExecutionPolicyContext.snapshot?.mcpEnabled
            ?? sharedSettings.isCapabilityGateEnabled(.mcp)
        return masterEnabled && isCapabilityPolicyEnabled("ios.mcp.tool_call")
    }

    private static func parseSubAgentModelUUID(_ value: String) -> KotlinUuid? {
        let normalized = value.lowercased()
        guard UUID(uuidString: normalized) != nil else { return nil }
        return KotlinUuid.companion.parse(uuidString: normalized)
    }

    private static func reasoningLevel(named raw: String) -> ReasoningLevel? {
        switch raw.lowercased() {
        case "off": return .off
        case "auto": return .auto_
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        case "xhigh": return .xhigh
        case "max": return .max
        default: return nil
        }
    }

    private func decrementLegacyCount(_ values: inout [String: Int], key: String) {
        guard let count = values[key] else { return }
        if count <= 1 {
            values.removeValue(forKey: key)
        } else {
            values[key] = count - 1
        }
    }

    private static func isHostPublishTool(_ toolName: String) -> Bool {
        toolName == IOSSoulToolCatalog.toolName
            || toolName == "skill_import"
            || toolName == "mcp_import_from_skill"
            || toolName == "recipe_import"
    }

    /// Soul / Skill / MCP / Recipe 导入：普通自动批准仍弹卡；高风险自动批准
    /// 走与前台相同的 prepare → CAS apply。Disabled MCP 仍由 apply 内复核拦下。
    private func backgroundHostPublishOutcome(
        toolName: String,
        arguments: String
    ) async -> IOSAgentToolOutcome {
        guard effectiveHighRiskAutoApproveEnabled else {
            return .denied("后台生成期间需要回到 App 确认 \(toolName)。")
        }
        do {
            switch toolName {
            case IOSSoulToolCatalog.toolName:
                return .filled(try soulService.applyPreparedImport(try soulService.prepareImport()))
            case "skill_import":
                return .filled(try skillMcpToolService.applyPreparedSkillImport(
                    try skillMcpToolService.prepareSkillImport(arguments: arguments)
                ))
            case "mcp_import_from_skill":
                let prepared = try skillMcpToolService.prepareMcpImport(arguments: arguments)
                return .filled(await skillMcpToolService.applyPreparedMcpImport(prepared) { [weak self] in
                    self?.isMcpNetworkAllowed() ?? false
                })
            case "recipe_import":
                return .filled(try await recipeToolService.applyPreparedRecipeImport(
                    try recipeToolService.prepareRecipeImport(arguments: arguments)
                ))
            default:
                return .failed("未知发布工具：\(toolName)")
            }
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func isMcpNetworkTool(_ toolName: String) -> Bool {
        toolName == "mcp_call"
            || toolName == "mcp_test"
            || ToolKt.isExpandedMcpToolName(name: toolName)
    }

    private func isAdvancedToolEnabled(_ toolName: String) -> Bool {
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

    private func isCapabilityPolicyEnabled(_ capabilityId: String) -> Bool {
        if let snapshot = IOSExecutionPolicyContext.snapshot,
           let capability = IOSCapabilityRegistry.capabilities.first(where: { $0.id == capabilityId }) {
            return snapshot.policy(for: capability) != .disabled
        }
        guard let localToolExecutor else { return true }
        let snapshot = localToolExecutor.permissionsStatus()
        return snapshot.capabilities.first { $0.id == capabilityId }?.policy != IOSAgentPermissionPolicy.disabled.title
    }

    private var requiresCouncilApproval: Bool {
        let capabilityId = "ios.agent.model_council_run"
        let policy: IOSAgentPermissionPolicy?
        if let snapshot = IOSExecutionPolicyContext.snapshot,
           let capability = IOSCapabilityRegistry.capabilities.first(where: { $0.id == capabilityId }) {
            policy = snapshot.policy(for: capability)
        } else {
            policy = localToolExecutor?.permissionPolicy(capabilityId: capabilityId)
        }
        guard let policy else {
            return false
        }
        return policy == .askEveryTime || policy == .allowOncePerRun
    }

#if DEBUG
    func finishedToolCallMessagesForTesting(
        _ targetToolCall: UIMessagePart.Tool,
        outputText: String,
        in messages: [UIMessage]
    ) -> [UIMessage] {
        messagesByFinishingToolCall(targetToolCall, outputText: outputText, in: messages)
    }

    func memoryToolOutputForTesting(input: String) -> String {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-memory-tool",
            toolName: "memory_tool",
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        return dispatchMemoryToolCall(
            toolCall,
            writePolicy: memoryToolWritePolicy(input: input, isUserInitiated: false)
        )
    }

    func memoryApprovalRequestForTesting(input: String) -> MemoryToolApprovalRequest? {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-memory-tool",
            toolName: "memory_tool",
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        guard case .needsUserAction(let reason) = memoryToolWritePolicy(input: input, isUserInitiated: false) else {
            return nil
        }
        return ChatToolApprovalRequestBuilder.memory(for: toolCall, reason: reason)
    }

    func memoryToolApprovalOutputForTesting(
        input: String,
        allow: Bool,
        expectedUpdatedAt: Int64? = nil
    ) -> String {
        IOSMemoryToolExecutor.execute(
            input: input,
            runtime: sharedSettings.agentRuntime,
            writePolicy: allow ? .allow : .deniedByUser("User denied memory write."),
            expectedUpdatedAt: expectedUpdatedAt
        )
    }

    func webMountToolOutputForTesting(
        toolName: String,
        input: String,
        isUserInitiated: Bool = false
    ) async -> String {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-webmount-tool",
            toolName: toolName,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        if !isUserInitiated {
            return await dispatchWebMountToolCall(toolCall)
        }
        let output = await webMountToolExecutionOutput(toolCall, isUserInitiated: isUserInitiated)
        return ChatToolOutputFormatter.webMountResultText(for: toolCall, output: output)
    }

    func webMountApprovalRequestForTesting(
        toolName: String,
        input: String
    ) async -> WebMountToolApprovalRequest? {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-webmount-tool",
            toolName: toolName,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let output = await webMountToolExecutionOutput(toolCall, isUserInitiated: false)
        guard case .needsUserAction(let reason) = output else { return nil }
        return ChatToolApprovalRequestBuilder.webMount(
            for: toolCall,
            reason: reason,
            localToolExecutor: localToolExecutor
        )
    }

    func webMountToolApprovalOutputForTesting(
        toolName: String,
        input: String,
        allow: Bool
    ) async -> String {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-webmount-tool",
            toolName: toolName,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        guard allow else {
            return IOSWebMountController.json([
                "ok": false,
                "tool": toolName,
                "denied": true,
                "policy": "user_denied",
                "reason": "User denied WebMount foreground action."
            ])
        }
        let output = await webMountToolExecutionOutput(toolCall, isUserInitiated: true)
        return ChatToolOutputFormatter.webMountResultText(for: toolCall, output: output)
    }

    func searchApprovalRequestForTesting(
        toolName: String,
        input: String
    ) -> SearchToolApprovalRequest? {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-search-tool",
            toolName: toolName,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        return ChatToolApprovalRequestBuilder.search(
            for: toolCall,
            reason: "Test approval",
            settings: sharedSettings.snapshot
        )
    }

    func searchToolApprovalOutputForTesting(
        toolName: String,
        input: String,
        allow: Bool
    ) async -> String {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-search-tool",
            toolName: toolName,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        guard allow else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolName,
                reason: "User denied network search.",
                denied: true
            )
        }
        return await dispatchSearchToolCall(toolCall)
    }
#endif
}

// MARK: - P0-2 B2: 前台内核执行器

/// 前台工具面的引擎执行器:把引擎的 (tool) 调用桥进 `ChatToolRuntime.execute`
/// 的 kind 分发——审批卡、记忆污染置位、回填格式化全部沿用前台实现,不复制
/// dispatch 逻辑。命中审批时 prompt 登记进盒子(引擎的 `.needsApproval` 只有
/// reason 字符串),`ChatRunKernelAdapter` 后续从盒子取出发布。
///
/// 三参 legacy 入口不被引擎调用(引擎优先 `execute(tool:)`);返回诚实失败,
/// 防止绕过 toolCallId 键控语义的直连。
///
/// @unchecked Sendable:引擎从 nonisolated 上下文调 `execute(tool:)`,随即
/// hop 到 MainActor 的 `dispatch`——跨域发送 self 是这次 hop 本身;全部
/// 存储属性 init 后不可变,且只在 MainActor 上读取。
private final class IOSForegroundKernelToolExecutor: IOSToolExecutor, @unchecked Sendable {
    private weak var runtime: ChatToolRuntime?
    private let kind: ChatPendingToolKind
    private let providerSetting: ProviderSetting
    private let params: TextGenerationParams
    private let runId: String
    private let startedAt: Int64
    private let inputDigest: String
    private let conversationId: KotlinUuid?
    private let toolExposureBridge: IosToolExposureBridge?
    private let baseMessagesProvider: @MainActor @Sendable () -> [UIMessage]
    private let approvalPromptBox: ChatToolRuntime.IOSForegroundApprovalPromptBox
    private let nestedToolRunner: IosExecNestedToolRunner?
    private let nestedOutcomeUnknownProvider: (@MainActor () -> IOSToolOutcomeUnknownSignal?)?
    private let recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?
    private let executionPolicy: IOSExecutionPolicySnapshot?

    init(
        runtime: ChatToolRuntime,
        kind: ChatPendingToolKind,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        startedAt: Int64,
        inputDigest: String,
        conversationId: KotlinUuid?,
        toolExposureBridge: IosToolExposureBridge?,
        baseMessagesProvider: @escaping @MainActor @Sendable () -> [UIMessage],
        approvalPromptBox: ChatToolRuntime.IOSForegroundApprovalPromptBox,
        nestedToolRunner: IosExecNestedToolRunner?,
        nestedOutcomeUnknownProvider: (@MainActor () -> IOSToolOutcomeUnknownSignal?)?,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?,
        executionPolicy: IOSExecutionPolicySnapshot?
    ) {
        self.runtime = runtime
        self.kind = kind
        self.providerSetting = providerSetting
        self.params = params
        self.runId = runId
        self.startedAt = startedAt
        self.inputDigest = inputDigest
        self.conversationId = conversationId
        self.toolExposureBridge = toolExposureBridge
        self.baseMessagesProvider = baseMessagesProvider
        self.approvalPromptBox = approvalPromptBox
        self.nestedToolRunner = nestedToolRunner
        self.nestedOutcomeUnknownProvider = nestedOutcomeUnknownProvider
        self.recipeCatalogSnapshot = recipeCatalogSnapshot
        self.executionPolicy = executionPolicy
    }

    func execute(
        tool: UIMessagePart.Tool,
        isUserInitiated: Bool
    ) async -> IOSAgentToolOutcome {
        await dispatch(tool: tool)
    }

    func execute(
        name: String,
        arguments: String,
        isUserInitiated: Bool
    ) async -> IOSAgentToolOutcome {
        .failed("[engine] foreground kernel executor requires the tool-carrying execute(tool:) entry")
    }

    @MainActor
    private func dispatch(tool: UIMessagePart.Tool) async -> IOSAgentToolOutcome {
        guard let runtime else { return .failed("Chat runtime is unavailable.") }
        let context = ChatPendingToolApproval(
            toolCall: tool,
            providerSetting: providerSetting,
            params: params,
            runId: runId,
            startedAt: startedAt,
            inputDigest: inputDigest,
            conversationId: conversationId,
            baseMessages: baseMessagesProvider(),
            executionPolicy: executionPolicy
        )
        let result = await runtime.execute(
            ChatPendingToolCall(kind: kind, toolCall: tool),
            context: context,
            toolExposureBridge: toolExposureBridge,
            nestedToolRunner: nestedToolRunner,
            recipeCatalogSnapshot: recipeCatalogSnapshot
        )
        switch result {
        case .completed(let messages):
            // 引擎只认 output parts:从回填后的消息里按 toolCallId 提取。
            // 回填函数(messagesByFinishingToolCall)已把结构化结果写进
            // 该 part 的 output。
            for message in messages where message.role == MessageRole.assistant {
                for part in message.parts {
                    guard let toolPart = part as? UIMessagePart.Tool,
                          toolPart.toolCallId == tool.toolCallId else { continue }
                    guard !toolPart.output.isEmpty else {
                        return .failed("foreground tool produced no output")
                    }
                    if nestedOutcomeUnknownProvider?() != nil {
                        return .outcomeUnknown(toolPart.output)
                    }
                    return .filledParts(toolPart.output)
                }
            }
            return .failed("foreground tool output not found in completed messages")
        case .outcomeUnknown(let messages):
            for message in messages where message.role == MessageRole.assistant {
                for part in message.parts {
                    guard let toolPart = part as? UIMessagePart.Tool,
                          toolPart.toolCallId == tool.toolCallId else { continue }
                    return toolPart.output.isEmpty
                        ? .durabilityFailure("WebMount outcome-unknown output was not persisted in the transcript.")
                        : .outcomeUnknown(toolPart.output)
                }
            }
            return .durabilityFailure("WebMount outcome-unknown tool output was not found.")
        case .waitingForApproval(let prompt):
            approvalPromptBox.put(tool.toolCallId, prompt)
            return .needsApproval(prompt.toolTitle)
        case .durabilityFailure(let message):
            return .durabilityFailure(message)
        }
    }
}
