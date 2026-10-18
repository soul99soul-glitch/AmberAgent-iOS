import Foundation
import Observation
@preconcurrency import Shared

struct PendingAssistantRegeneration {
    let conversationId: KotlinUuid
    let targetMessageIndex: Int
    let generatedMessageIndex: Int
}

/// A live run keeps its presentation even while another conversation is on screen.
/// The Host's bindings capture this state, never the currently selected conversation.
@MainActor @Observable
final class ChatConversationRunState {
    let conversationId: KotlinUuid?
    var messages: [UIMessage] = []
    var isLoading = false
    var pendingMemoryApproval: MemoryToolApprovalRequest?
    var pendingSearchApproval: SearchToolApprovalRequest?
    var pendingWebMountApproval: WebMountToolApprovalRequest?
    var pendingWorkspaceApproval: WorkspaceToolApprovalRequest?
    var pendingIshHandoffApproval: IshHandoffToolApprovalRequest?
    var pendingMcpApproval: McpToolApprovalRequest?
    var pendingCouncilApproval: CouncilToolApprovalRequest?
    var pendingAskUser: ChatAskUserRequest?
    var pendingRecipeApproval: RecipeToolApprovalRequest?
    /// 增强 Phase E：当前 pending 审批的 Jev 分诊标注（三态中性事实）。
    /// nil = 无标注（未配置/失败/非 active）——审批卡片与原样一致。
    var jevApprovalTriage: IOSJevApprovalTriage?
    /// Jev 自动批准复核：当前 pending 审批由复核收紧而来时的风险标签。
    var jevAutoApprovalEscalation: [String]?
    /// Jev 完成校验：触发提示的最终消息 id；它不再是最后一条消息时提示自动消失。
    var jevCompletionNoticeMessageId: String?
    /// 分诊迟到守卫：每次触发/清除递增，迟到结果比对 token 决定是否落地。
    var approvalTriageToken: Int = 0
    var contextCompactState: ChatContextCompactState = .idle
    var pendingAssistantRegeneration: PendingAssistantRegeneration?
    var steerQueue: [IOSSteerQueueEntry] = [] {
        didSet { steerQueueRevision &+= 1 }
    }
    var steerQueueRevision = 0
    var steerQueueLoaded = true
    var waitingForChildRunId: String?
    var childResultWakeTask: Task<Void, Never>?

    func clearChildResultWait() {
        waitingForChildRunId = nil
        childResultWakeTask?.cancel()
        childResultWakeTask = nil
    }

    var isOrchestratedChild = false
    var hasOrchestrationLinks = false
    var toolExposureBridge: IosToolExposureBridge?
    var inputText = ""
    var generationConfiguration: (provider: ProviderSetting, params: TextGenerationParams, dynamicSnapshot: IOSDynamicToolCatalogSnapshot?)?
    @ObservationIgnored private var lastMemoryUsageRunId: String?
    @ObservationIgnored private var lastMarkedMemoryIds: Set<Int32> = []

    @discardableResult
    func recordMemoryUsage(
        ids: Set<Int32>, runId: String?, now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        force: Bool = false, persistence: IOSMemoryPersistence = .shared
    ) -> Bool {
        if !force, let runId, runId == lastMemoryUsageRunId, ids == lastMarkedMemoryIds {
            return false
        }
        guard persistence.markUsed(ids: ids, now: now, force: force) else { return false }
        if let runId {
            lastMemoryUsageRunId = runId
            lastMarkedMemoryIds = ids
        }
        return true
    }

    init(conversationId: KotlinUuid?) {
        self.conversationId = conversationId
    }
}

