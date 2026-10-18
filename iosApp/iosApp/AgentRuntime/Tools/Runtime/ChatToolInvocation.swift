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

enum IOSExecutionPolicyContext {
    @TaskLocal static var snapshot: IOSExecutionPolicySnapshot?
}

/// Only an interrupted in-flight action is terminal. A dispatched or ambiguous
/// result stays in the model loop so WebMount can re-observe before continuing.
func isWebMountInterruptedOutcome(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    return object["status"] as? String == "unknown_after_action"
        && object["may_have_applied"] as? Bool == true
}

final class IOSClosureToolExecutor: IOSToolExecutor {
    private let handler: @MainActor (String, String, Bool) async -> IOSAgentToolOutcome
    private let executionPolicy: IOSExecutionPolicySnapshot?
    /// Jev 自动批准复核：返回 true 时本次调用在关闭自动批准的策略下执行。
    private let tighten: (@MainActor (String, String) async -> Bool)?

    init(
        executionPolicy: IOSExecutionPolicySnapshot? = IOSExecutionPolicyContext.snapshot,
        tighten: (@MainActor (String, String) async -> Bool)? = nil,
        _ handler: @escaping @MainActor (String, String, Bool) async -> IOSAgentToolOutcome
    ) {
        self.handler = handler
        self.executionPolicy = executionPolicy
        self.tighten = tighten
    }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        await IOSExecutionPolicyContext.$snapshot.withValue(executionPolicy) {
            if !isUserInitiated, let tighten, await tighten(name, arguments),
               let tightened = executionPolicy?.withoutAutoApprove() {
                return await IOSExecutionPolicyContext.$snapshot.withValue(tightened) {
                    await handler(name, arguments, isUserInitiated)
                }
            }
            return await handler(name, arguments, isUserInitiated)
        }
    }
}

/// Closure executor that needs the engine's real tool call (toolCallId), e.g.
/// background `exec`, whose store writes are tagged with their source call.
final class IOSToolCallClosureToolExecutor: IOSToolExecutor {
    private let handler: @MainActor (UIMessagePart.Tool) async -> IOSAgentToolOutcome
    private let executionPolicy: IOSExecutionPolicySnapshot?

    init(
        executionPolicy: IOSExecutionPolicySnapshot? = IOSExecutionPolicyContext.snapshot,
        _ handler: @escaping @MainActor (UIMessagePart.Tool) async -> IOSAgentToolOutcome
    ) {
        self.handler = handler
        self.executionPolicy = executionPolicy
    }

    func execute(tool: UIMessagePart.Tool, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        await IOSExecutionPolicyContext.$snapshot.withValue(executionPolicy) {
            await handler(tool)
        }
    }

    /// Callers without a real tool call get a synthetic one (fresh id).
    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        await execute(
            tool: UIMessagePart.Tool(
                toolCallId: "direct-\(name)-\(UUID().uuidString)",
                toolName: name,
                input: arguments,
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            ),
            isUserInitiated: isUserInitiated
        )
    }
}

extension IOSLocalToolExecutionOutput {
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
        guard IOSProviderConfigToolCatalog.highRiskToolNames.contains(toolName) else { return false }
        guard let data = outputText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true else {
            return false
        }
        let status = (obj["api_key_status"] as? String) ?? ""
        return status == "updated" || status == "cleared"
            || (toolName == "provider_config_create" && obj["has_api_key"] as? Bool == true)
    }
}

struct ChatPendingToolCall {
    let kind: ChatPendingToolKind
    let toolCall: UIMessagePart.Tool
}

// MARK: - Wave B2: recipe execution state (mutation-step approval pause)

/// Outcome of one `advanceRecipeExecution` sweep.
enum RecipeAdvanceOutcome {
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
enum RecipeStepGate {
    case proceed
    case approvalRequired(reason: String)
    case unsupported(reason: String)
}

/// One post-gate step execution result.
enum RecipePrimitiveStepResult {
    case output(String)
    case failure(String)
    case needsApproval(reason: String)
    case outcomeUnknown(String)
}

enum IOSPluginRuntimeError: LocalizedError {
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

struct IOSPluginHostCallFailure: Sendable {
    let reason: String
    let mayHaveApplied: Bool
}

final class IOSPluginHostCallState: @unchecked Sendable {
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

enum ChatCodexImageConfig {
    case signedIn(providerId: String, modelId: String, preferredRoutingModelID: String?)
    case notSignedIn
    case notSelected
}

