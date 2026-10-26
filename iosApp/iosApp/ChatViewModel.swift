import Foundation
import CryptoKit
import Observation
import OSLog
import SwiftUI
@preconcurrency import Shared

// MARK: - ChatViewModel

enum ChatComposerSendBlockReason: Equatable {
    case emptyInput
    case generationActive
    case steerQueueFull
    case attachingSelectedFile
    case recognizingImages
    case pendingApproval
    /// P1-e: 当前会话是编排子线程（存在 thread_edge 即只读，含 interrupt 取消/
    /// 已完成线程）。UI 只消费 disabled 态；文案由 VM 提供（零 UI 改动）。
    case orchestratedThread
    case configuration(ChatConfigurationIssue)

    /// P1-e: 用户可见文案（现有 UI 只按 `== nil` 禁用发送键；文案留给后续
    /// UI 分支/语音播报，测试断言使用）。
    var userVisibleMessage: String? {
        switch self {
        case .orchestratedThread:
            return IOSAppLocalization.string(
                "此会话由父线程编排，暂不支持直接输入",
                defaultValue: "此会话由父线程编排，暂不支持直接输入"
            )
        case .configuration(let issue):
            return issue.message
        default:
            return nil
        }
    }
}

/// Result of a Watch-originated question. The coordinator uses the stable
/// conversation id for handoff and the run id for live task projection.
struct IOSWatchQuestionStartResult: Equatable, Sendable {
    let conversationId: String?
    let runId: String?
    let failureMessage: String?

    var started: Bool {
        conversationId != nil && runId != nil && failureMessage == nil
    }

    static func failure(_ message: String) -> Self {
        Self(conversationId: nil, runId: nil, failureMessage: message)
    }
}

@MainActor
@Observable
final class ChatViewModel {

    private struct ImageGenerationResumeCacheEntry {
        let summaryUpdatedAtMillis: Int64
        let isGenerationActive: Bool
        let context: ChatImageGenerationResumeContext?
    }

    /// 用户消息入场弹簧；生成启动也以它的视觉时长为界，二者不会脱节。
    static let userMessageSendSpring = Spring(response: 0.34, dampingRatio: 0.8)

    /// 生成启动（参数与工具目录组装、Kernel、后台保活、记忆召回）在主线程上要
    /// 同步跑上百毫秒；与发送放在同一事件里会挡住用户气泡上屏并打断入场动画。
    /// composer 发送因此等入场动画落位再启动；需要 run 已存在的入口先补启动。
    struct DeferredGenerationStart {
        let token: UUID
        let run: ChatConversationRun
        let inputDigest: String
        let conversationId: KotlinUuid?
    }

    @ObservationIgnored var deferredGenerationStart: DeferredGenerationStart?
    @ObservationIgnored var wakeTaskStartsInFlight: Set<String> = []

#if DEBUG
    @ObservationIgnored var beforeIdleMailboxPreviewApplyForTesting: (() async -> Void)?
    @ObservationIgnored var beforeChildResultWakeApplyForTesting: (() async throws -> Void)?

    func beginChildResultWaitForTesting(runId: String, provider: ProviderSetting, params: TextGenerationParams) {
        _ = kernelRunHost
        let state = currentRun.state
        state.generationConfiguration = (provider, params, nil)
        makeGenerationBindings(state: state).onForegroundYield(runId)
        observeYieldedChildResults(state: state, runId: runId)
    }

#endif

    static let maxImagesPerMessage = 4

    static let orchestrationContextPrompt = """
    Thread orchestration is active for this conversation.
    - Messages prefixed `[mailbox MESSAGE|NEW_TASK|FINAL_ANSWER from /root/...]` are inter-agent mail, not user input; FINAL_ANSWER is a child thread's completion report.
    - FINAL_ANSWER ends that child run. A truncated delivery excerpt is not a pending continuation: read its stored message with session_read and follow next_offset until null. If the full report still needs work, use followup_task to restart the child before waiting; send_message alone cannot wake an idle child. Retrieve omitted results and continue already-delegated work without asking the user to repeat the instruction.
    - spawn_agent, list_agents, interrupt_agent, send_message, followup_task, wait_agent and session_read are native functions, not MCP tools. If a needed function is hidden, use tool_search for its exact name and then call it directly. Never wrap these functions in mcp_call.
    - Child threads run in the background and their completed reports appear automatically as compact cards. Keep working on independent work; when none remains, call wait_agent to yield the foreground turn when you still need child results. A completed child report automatically resumes that waiting task so you can summarize it. Finishing a reply without wait_agent does not request automatic continuation. Do not repeatedly wait or poll for children and occupy the user's conversation.
    - Use send_message/followup_task to contact a child, interrupt_agent to stop one (the thread stays addressable). The user can also append tasks from the child conversation UI. Respond to new user input normally; completed reports remain available as context for your next reply.
    """

    @ObservationIgnored let attachmentOperations = ChatAttachmentOperationOwner()
    @ObservationIgnored let inboxIO: ChatConversationInboxIO

    // MARK: - State

    var messages: [UIMessage] {
        get { currentRun.state.messages }
        set { currentRun.state.messages = newValue }
    }
    var inputText: String {
        get { currentRun.state.inputText }
        set { currentRun.state.inputText = newValue }
    }
    var isLoading: Bool {
        get { currentRun.state.isLoading }
        set { currentRun.state.isLoading = newValue }
    }
    /// 助手回复完成后用 suggestionModelId 生成的对话建议(输入框上方胶囊)。
    /// 用户发送或切换会话时清空。
    var chatSuggestions: [String] = []
    var isAttachingSelectedFile: Bool = false
    var pendingSelectedFilePreview: SelectedDocumentReadResult?
    var pendingImages: [PendingChatImage] = []
    var isRecognizingImages = false
    var selectedFileContextError: String?
    var reasoningLevel: ReasoningLevel = .off
    var messageRevision: Int = 0
    var messageUpdateSignal = ChatMessageUpdateSignal()
    var artifactUpdateSignal = ChatMessageUpdateSignal()
    var artifactUpdateWasRunning = false
    /// token 聚合只在结构性消息事件后重算；流式 delta 不改 usage，跳过 O(n) 扫描。
    @ObservationIgnored var tokenRevision: Int = 0
    @ObservationIgnored private var cachedTokenSnapshot: ChatContextSnapshot?
    @ObservationIgnored private var cachedTokenRevision: Int = -1
    @ObservationIgnored private var imageGenerationResumeCache: [String: ImageGenerationResumeCacheEntry] = [:]
    @ObservationIgnored private var imageGenerationResumeCacheStoreID: ObjectIdentifier?
    @ObservationIgnored private var retryingFailedRunIds: Set<String> = []
    @ObservationIgnored var retryMutationRunId: String?
    @ObservationIgnored var isStartingWatchQuestion = false
    var pendingMemoryApproval: MemoryToolApprovalRequest? {
        get { currentRun.state.pendingMemoryApproval }
        set { currentRun.state.pendingMemoryApproval = newValue }
    }
    var pendingSearchApproval: SearchToolApprovalRequest? {
        get { currentRun.state.pendingSearchApproval }
        set { currentRun.state.pendingSearchApproval = newValue }
    }
    var pendingWebMountApproval: WebMountToolApprovalRequest? {
        get { currentRun.state.pendingWebMountApproval }
        set { currentRun.state.pendingWebMountApproval = newValue }
    }
    var pendingWorkspaceApproval: WorkspaceToolApprovalRequest? {
        get { currentRun.state.pendingWorkspaceApproval }
        set { currentRun.state.pendingWorkspaceApproval = newValue }
    }
    var pendingIshHandoffApproval: IshHandoffToolApprovalRequest? {
        get { currentRun.state.pendingIshHandoffApproval }
        set { currentRun.state.pendingIshHandoffApproval = newValue }
    }
    var pendingMcpApproval: McpToolApprovalRequest? {
        get { currentRun.state.pendingMcpApproval }
        set { currentRun.state.pendingMcpApproval = newValue }
    }
    var pendingCouncilApproval: CouncilToolApprovalRequest? {
        get { currentRun.state.pendingCouncilApproval }
        set { currentRun.state.pendingCouncilApproval = newValue }
    }
    var pendingAskUser: ChatAskUserRequest? {
        get { currentRun.state.pendingAskUser }
        set { currentRun.state.pendingAskUser = newValue }
    }
    /// 增强 Phase E：当前 pending 审批的分诊标注（只读，由 triagePendingApproval 写入）。
    var jevApprovalTriage: IOSJevApprovalTriage? {
        currentRun.state.jevApprovalTriage
    }
    var jevAutoApprovalEscalation: [String]? {
        currentRun.state.jevAutoApprovalEscalation
    }
    var showsJevCompletionNotice: Bool {
        let state = currentRun.state
        guard let id = state.jevCompletionNoticeMessageId, !isGenerationActiveForCurrentConversation else { return false }
        return state.messages.last?.id.description() == id
    }

    /// "让助手验证"：输入框（含附件）为空时直接发送验证请求；有草稿时追加到草稿后由用户确认。
    func requestCompletionVerification() {
        let prompt = IOSJevCompletionCheckService.verificationPrompt
        let draft = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.isEmpty, pendingImages.isEmpty, pendingSelectedFilePreview == nil else {
            if !draft.contains(prompt) { inputText = draft.isEmpty ? prompt : draft + "\n" + prompt }
            return
        }
        inputText = prompt
        if !sendMessage() { inputText = "" }
    }
    /// Wave B2: recipe 审批卡（mutation step / recipe_import）。
    var pendingRecipeApproval: RecipeToolApprovalRequest? {
        get { currentRun.state.pendingRecipeApproval }
        set { currentRun.state.pendingRecipeApproval = newValue }
    }

    /// 增强 Phase E：pending 审批出现时异步分诊标注，永不阻塞审批链。
    /// 清除 pending 时同步清除标注；token 守卫保证迟到结果只在同一审批
    /// 仍 pending 时落地。关闭或 shadow 不加标签；Jev 失败时保留本地已知事实。
    func triagePendingApproval(
        _ state: ChatConversationRunState,
        requestId: String?,
        toolName: String,
        actionSummary: String,
        parameterSummary: String? = nil,
        invocationArgumentsJSON: String? = nil,
        staticFacts: IOSJevApprovalTriageService.StaticFacts? = nil,
        requiresParameterSummary: Bool = false
    ) {
        state.approvalTriageToken &+= 1
        let token = state.approvalTriageToken
        state.jevAutoApprovalEscalation = requestId.flatMap { IOSJevAutoApprovalGate.shared.escalationReasons(requestId: $0) }
        guard let requestId else {
            state.jevApprovalTriage = nil
            return
        }
        state.jevApprovalTriage = nil
        let goalText = state.messages.reversed().first { $0.role == MessageRole.user }?.toText()
        // 审批产生自 run 的工具循环：预算记在该 run 账上；拿不到 runId 时
        // 退化到按审批记账的独立 key。
        let runKey = state.conversationId
            .flatMap { runRegistry.run(for: $0)?.host?.currentRunId }
            ?? "approval-triage-\(requestId)"
        let metadataJSON: String?
        if let invocationArgumentsJSON {
            metadataJSON = state.toolExposureBridge?.approvalTriageFactsJsonForInvocation(
                toolName: toolName,
                argumentsJson: invocationArgumentsJSON
            )
        } else {
            metadataJSON = state.toolExposureBridge?.approvalTriageFactsJson(toolName: toolName)
        }
        let facts = staticFacts ?? IOSJevApprovalTriageService.StaticFacts.registeredTool(metadataJSON: metadataJSON)
        Task { @MainActor in
            let triage = await IOSJevApprovalTriageService.shared.triage(
                requestId: requestId,
                toolName: toolName,
                actionSummary: actionSummary,
                parameterSummary: parameterSummary,
                staticFacts: facts,
                requiresParameterSummary: requiresParameterSummary,
                goalText: goalText,
                turnBudgetKey: runKey
            )
            guard let triage, state.approvalTriageToken == token else { return }
            state.jevApprovalTriage = triage
        }
    }
    var toolOutcomeUnknownDescriptors: [IOSToolOutcomeUnknownDescriptor] = []

    var pendingToolOutcomeUnknown: IOSToolOutcomeUnknownDescriptor? {
        guard let conversationId = currentConversationId?.toHexDashString() else { return nil }
        return toolOutcomeUnknownDescriptors.first { $0.conversationId == conversationId }
    }

    var configurationError: String?
    var contextCompactState: ChatContextCompactState {
        get { currentRun.state.contextCompactState }
        set { currentRun.state.contextCompactState = newValue }
    }
    var contextCompactBoundaries: [ChatContextCompactBoundary] = []

    // MARK: - Steer 队列（P1-a）

    /// 生成激活期间排队、待折入下一轮模型请求的 user 消息（v1 仅文本 STEER）。
    /// 队列由各会话状态持有；`ChatRunKernelAdapter` 在工具循环
    /// 边界经 bindings 消费，不持有第二份队列。非活动会话从持久化恢复。
    var steerQueue: [IOSSteerQueueEntry] {
        get { currentRun.state.steerQueue }
        set { currentRun.state.steerQueue = newValue }
    }
    /// 磁盘镜像（Documents/steer-queue/{conversationId}.json），进程死亡后队列不丢。
    @ObservationIgnored var steerQueueLoadTask: Task<Void, Never>?
    /// P1-b: mailbox 信封访问层（Room 即真相，无内存态；drain 事务化 exactly-once）。
    /// P1-d: mailbox 活动广播（wait_agent 事件源；steer 打断 wait 的信号点）。

    /// 顶部活动岛「等待确认」聚合信号：与 sendMessage 的 pending 门禁集合保持一致。
    var hasPendingUserGate: Bool {
        pendingMemoryApproval != nil || pendingSearchApproval != nil ||
            pendingWebMountApproval != nil || pendingWorkspaceApproval != nil ||
            pendingIshHandoffApproval != nil || pendingMcpApproval != nil ||
            pendingCouncilApproval != nil || pendingAskUser != nil ||
            pendingRecipeApproval != nil || pendingToolOutcomeUnknown != nil
    }

    /// 顶部活动岛等待连接副标题（取不到则 nil，文案规则：宁缺毋滥）。
    var islandModelDisplayName: String? { currentModel?.displayName }

    /// 识别图片期间的总张数（>1 时才作为副标题事实展示）。
    var visionRecognitionImageCount = 0
    static var visionRecognitionPendingMessage: String {
        IOSAppLocalization.string(
            "图片识别中，请稍候",
            defaultValue: "图片识别中，请稍候"
        )
    }

    /// 持久化存储（由 AppShell 注入）。nil 时退化为纯内存模式（向后兼容旧调用方）。
    weak var conversationStore: IOSConversationStore?

    @ObservationIgnored private var cachedIntelligentUIHost: IOSIntelligentUIHost?
    var intelligentUISubmissionsInFlight: Set<String> = []

    var isIntelligentUISubmissionInFlight: Bool {
        intelligentUISubmissionsInFlight.contains(currentConversationId?.toHexDashString() ?? "")
    }

    func rejectIntelligentUISubmissionMutationIfNeeded() -> Bool {
        guard isIntelligentUISubmissionInFlight else { return false }
        configurationError = "任务卡选择正在保存，请等待完成后修改消息或切换分支。"
        return true
    }

    var intelligentUIHost: IOSIntelligentUIHost? {
        guard let store = conversationStore else { return nil }
        if let host = cachedIntelligentUIHost, host.stateStore === store.intelligentUIStateStore { return host }
        let host = IOSIntelligentUIHost(stateStore: store.intelligentUIStateStore) { [weak self] submission in
            guard let self else { return .failure("聊天页面已关闭，请重新打开会话。") }
            return await self.submitIntelligentUI(submission)
        }
        cachedIntelligentUIHost = host
        return host
    }

    /// 当前会话 id，与 conversationStore.currentConversation.id 同步。
    /// 留作快速访问；切换会话后由 reloadFromStore() 刷新。
    var currentConversationId: KotlinUuid? {
        conversationStore?.currentConversation?.id
    }

    /// Run owner identity used by the Watch cold-start handoff. The headless
    /// ChatViewModel remains authoritative until its kernel host reaches a
    /// terminal state, even after AppShell attaches its foreground VM.
    var currentKernelRunId: String? {
        runRegistry.allRuns
            .compactMap(\.host)
            .first(where: { $0.isRunning })?
            .currentRunId
    }

    /// 当前会话实际持有的运行标识；不跨会话挑选仍在后台运行的任务。
    var currentConversationRunId: String? {
        guard let conversationId = currentConversationId?.toHexDashString() else { return nil }
        return runRegistry.run(forHex: conversationId)?.host?.currentRunId
    }

    // MARK: - P1-e 编排子线程只读缓存

    /// 当前会话是否编排子线程（存在 thread_edge）。composerSendBlockReason 每条
    /// keystroke 都读，必须缓存；会话切换时由 reloadFromStore() 异步刷新（经
    /// 注入的编排服务查一次 Room）。测试可 `await orchestratedStatusRefreshTask?.value`。
    var currentConversationIsOrchestratedChild: Bool {
        get { currentRun.state.isOrchestratedChild }
        set { currentRun.state.isOrchestratedChild = newValue }
    }
    @ObservationIgnored var orchestratedStatusRefreshTask: Task<Void, Never>?
    /// 当前会话是否参与线程树（是子线程或有子线程）。参与的会话才注入 mailbox
    /// 语义说明（普通会话不付这笔 token）；与只读判定同一刷新任务。
    var currentConversationHasOrchestrationLinks: Bool {
        get { currentRun.state.hasOrchestrationLinks }
        set { currentRun.state.hasOrchestrationLinks = newValue }
    }

    /// 刷新当前会话的子线程判定（Room 查询一次）。reloadFromStore 与测试共用。
    func refreshCurrentConversationOrchestratedStatus() async {
        await refreshOrchestratedStatus(state: currentRun.state)
    }

    func refreshOrchestratedStatus(state: ChatConversationRunState) async {
        guard let conversationId = state.conversationId else {
            state.isOrchestratedChild = false
            state.hasOrchestrationLinks = false
            return
        }
        let isChild = await orchestrationToolService.isOrchestratedChild(conversationId: conversationId)
        state.isOrchestratedChild = isChild
        if isChild {
            state.hasOrchestrationLinks = true
        } else {
            state.hasOrchestrationLinks = await orchestrationToolService
                .hasOrchestrationChildren(conversationId: conversationId)
        }
    }

    /// P1-e: 供会话列表徽标/只读标识查询（ConversationsView 在用户 WIP 中，本轮
    /// 不加视觉徽标；此查询留待后续 UI 接线）。
    func isOrchestratedChild(conversationId: KotlinUuid) async -> Bool {
        await orchestrationToolService.isOrchestratedChild(conversationId: conversationId)
    }

    /// The hidden child transcript has its own composer. Reuse the same
    /// orchestration service as model-driven followup_task so a user message
    /// is queued at an active child's next boundary or starts an idle child.
    func appendTaskToSubAgent(conversationId: KotlinUuid, message: String) async -> String {
        guard let provider = makeProviderSetting() else {
            return IOSThreadOrchestrationToolService.errorJSON(
                toolName: "followup_task",
                code: "missing_provider",
                reason: "当前模型或服务商不可用，无法追加子代理任务。"
            )
        }
        let params = makeTextGenerationParams()
        return await orchestrationToolService.appendUserTask(
            to: conversationId,
            message: message,
            providerSetting: provider,
            params: params,
            toolExposureBridge: lastAssembledToolExposureBridge
        )
    }

    var contextSnapshot: ChatContextSnapshot {
        // O(n) token 聚合按 tokenRevision 缓存：流式 delta 不改 usage，跳过重算。
        // 廉价字段（modelId、filePreview）每次 live 读取，不进缓存。
        let cached: ChatContextSnapshot
        if let hit = cachedTokenSnapshot, cachedTokenRevision == tokenRevision {
            cached = hit
        } else {
            cached = Self.snapshot(from: ChatContextUsageMetrics.lastAssistantTurn(in: messages))
            cachedTokenSnapshot = cached
            cachedTokenRevision = tokenRevision
        }
        return ChatContextSnapshot(
            messageCount: messages.count,
            modelId: currentModelId,
            supportsReasoning: currentModelSupportsReasoning,
            pendingSelectedFileName: pendingSelectedFilePreview?.fileName,
            pendingSelectedFileBytesText: pendingSelectedFilePreview?.byteSummary,
            promptTokens: cached.promptTokens,
            completionTokens: cached.completionTokens,
            totalTokens: cached.totalTokens,
            cachedTokens: cached.cachedTokens,
            tokensPerSecond: cached.tokensPerSecond,
            contextWindowTokens: ChatContextSnapshot.resolvedContextWindowTokens(
                modelWindow: currentModel?.contextWindowTokens.map { Int(truncating: $0) },
                modelId: currentModelId
            ),
            currentContextTokens: occupancyTokens()
        )
    }

    private func occupancyTokens() -> Int {
        IOSContextCompactionCoordinator.shared.nextTurnOccupancyTokens(
            messages: messages,
            conversationId: currentConversationId,
            draftText: inputText,
            extraWeightedChars: occupancyExtraWeightedChars,
            systemOverheadText: occupancySystemOverheadText
        )
    }

    private var occupancyExtraWeightedChars: Int {
        var extra = pendingImages.count * 4_500
        if let file = pendingSelectedFilePreview {
            extra += max(Int(file.characterCount), file.preview.count)
        }
        return extra
    }

    private var occupancySystemOverheadText: String {
        let systemPrompt = sharedSettings.snapshot.getCurrentAssistant().systemPrompt
        let soul = sharedSettings.agentRuntime.agentSoulMarkdown
        return [systemPrompt, soul]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func snapshot(from metrics: ChatContextUsageMetrics) -> ChatContextSnapshot {
        ChatContextSnapshot(
            messageCount: 0,
            modelId: "",
            supportsReasoning: false,
            pendingSelectedFileName: nil,
            pendingSelectedFileBytesText: nil,
            promptTokens: metrics.promptTokens,
            completionTokens: metrics.completionTokens,
            totalTokens: metrics.promptTokens + metrics.completionTokens,
            cachedTokens: metrics.cachedTokens,
            tokensPerSecond: metrics.tokensPerSecond,
            contextWindowTokens: nil,
            currentContextTokens: metrics.currentContextTokens
        )
    }

    var currentModelSupportsReasoning: Bool {
        sharedSettings.currentAssistantReasoningLevels().contains { $0 != .off }
    }

#if DEBUG
    var generationActiveOverrideForTesting: ((KotlinUuid?) -> Bool)?
    /// P0-2 e2e:kernel 路径的剧本化 provider 注入缝。lazy Host 必须在
    /// 首次发送前完成注入，之后改动不生效。nil = 生产统一 provider adapter。
    @ObservationIgnored var kernelTextProviderOverrideForTesting: (any IOSAgentTextProvider)?
#endif
    var isGenerationActive: Bool {
        _ = runActivityRevision
#if DEBUG
        if generationActiveOverrideForTesting?(currentConversationId) == true { return true }
#endif
        return kernelRunHost.isRunning
            || hasActiveBackgroundGenerationForCurrentConversation
    }

    var isForegroundGenerationActiveForCurrentConversation: Bool {
        guard kernelRunHost.isRunning else { return false }
        let activeConversationId = kernelRunHost.activeConversationId
        switch (currentConversationId, activeConversationId) {
        case (nil, nil):
            return true
        case let (current?, active?):
            return String(describing: current) == String(describing: active)
        default:
            return false
        }
    }

    var isGenerationActiveForCurrentConversation: Bool {
        guard let currentConversationId else { return false }
        if kernelRunHost.isRunning,
           let activeConversationId = kernelRunHost.activeConversationId,
           String(describing: currentConversationId) == String(describing: activeConversationId) {
            return true
        }
        return IOSChatBackgroundGenerationCoordinator.shared.hasActiveJob(conversationId: currentConversationId)
    }

    var isBackgroundGenerationWaitingForForegroundResume: Bool {
        guard let currentConversationId else { return false }
        return IOSChatBackgroundGenerationCoordinator.shared
            .isWaitingForForegroundResume(conversationId: currentConversationId)
    }

    func isGenerationActive(conversationId: KotlinUuid) -> Bool {
        _ = runActivityRevision
#if DEBUG
        if generationActiveOverrideForTesting?(conversationId) == true { return true }
#endif
        if host(for: conversationId)?.isRunning == true {
            return true
        }
        return IOSChatBackgroundGenerationCoordinator.shared.hasActiveJob(conversationId: conversationId)
    }

    /// Restore replaces conversation documents. It must not race an in-flight
    /// foreground or background owner that could later persist an old snapshot.
    /// `runActivityRevision` makes this observable to the settings action while
    /// the coordinator itself remains its existing source of truth.
    var hasActiveChatGeneration: Bool {
        _ = runActivityRevision
        return runRegistry.allRuns.contains { $0.host?.isRunning == true }
            || IOSChatBackgroundGenerationCoordinator.shared.hasPendingConversationWrites
    }

    func latestImageGenerationResumeContext() async -> ChatImageGenerationResumeContext? {
        guard let conversationStore else { return nil }
        let storeID = ObjectIdentifier(conversationStore)
        if imageGenerationResumeCacheStoreID != storeID {
            imageGenerationResumeCache.removeAll()
            imageGenerationResumeCacheStoreID = storeID
        }
        // The selected conversation is already in memory and may have changed
        // branches before the list summary refreshes. Historical conversations
        // need a persisted image-tool marker before their messages are loaded.
        let currentConversationID = conversationStore.currentConversation?.id
        let summaries = conversationStore.summaries.filter {
            $0.hasImageGenerationTool || $0.id == currentConversationID
        }
        let liveConversationIDs = Set(summaries.map { $0.id.toHexDashString() })
        imageGenerationResumeCache = imageGenerationResumeCache.filter {
            liveConversationIDs.contains($0.key)
        }
        var candidates: [ChatImageGenerationResumeContext] = []

        for summary in summaries {
            guard !Task.isCancelled else { return nil }
            let conversationID = summary.id.toHexDashString()
            let summaryUpdatedAtMillis = summary.updateAt.toEpochMilliseconds()
            let generationActive = isGenerationActive(conversationId: summary.id)
            let context: ChatImageGenerationResumeContext?
            if let cached = imageGenerationResumeCache[conversationID],
               cached.summaryUpdatedAtMillis == summaryUpdatedAtMillis,
               cached.isGenerationActive == generationActive {
                context = cached.context
            } else if let messages = await conversationStore.messages(for: summary.id) {
                context = ChatImageGenerationResumeProjection.latest(
                    in: messages,
                    conversationID: conversationID,
                    isGenerationActive: generationActive
                )
                imageGenerationResumeCache[conversationID] = ImageGenerationResumeCacheEntry(
                    summaryUpdatedAtMillis: summaryUpdatedAtMillis,
                    isGenerationActive: generationActive,
                    context: context
                )
            } else {
                continue
            }
            if let context {
                candidates.append(context)
            }
        }
        return ChatImageGenerationResumeProjection.preferred(in: candidates)
    }

    func reconcilePendingMiniAppMutationsAfterConversationBootstrap() async {
        guard miniAppRepository.hasPendingConversationMutations,
              let conversationStore,
              conversationStore.lastIOError == nil else {
            return
        }
        let pendingMutationIds = miniAppRepository.pendingConversationMutationIds()
        guard !pendingMutationIds.isEmpty else { return }

        var references = Set<IOSMiniAppConversationReference>()
        for summary in conversationStore.summaries {
            guard let storedMessages = await conversationStore.messages(for: summary.id) else {
                // Absence is only authoritative when every conversation could be read.
                return
            }
            references.formUnion(
                IOSMiniAppChatMessageFactory.persistedConversationReferences(in: storedMessages)
            )
        }

        do {
            try miniAppRepository.reconcilePendingConversationMutations(
                referenced: references,
                mutationIds: pendingMutationIds
            )
        } catch {
            NSLog("[AmberChat] Failed to reconcile pending MiniApp transactions: \(error)")
        }
    }

    private var hasActiveBackgroundGenerationForCurrentConversation: Bool {
        guard let currentConversationId else { return false }
        return IOSChatBackgroundGenerationCoordinator.shared.hasActiveJob(conversationId: currentConversationId)
    }

    /// The settings entry must not discard a composer draft or queue a blocked navigation.
    func prepareForThemeGeneration() -> String? {
        guard inputText.isEmpty, pendingImages.isEmpty, pendingSelectedFilePreview == nil,
              !isAttachingSelectedFile, !isRecognizingImages else {
            return "聊天中还有未发送的文字或附件，请先发送或清空草稿，再生成主题。"
        }
        guard prepareForConversationChange(to: nil) else {
            let message = conversationStore?.lastUserVisibleError?.message
                ?? "当前会话仍在生成中，正在执行的工具完成后才能生成主题。"
            conversationStore?.clearUserVisibleError()
            return message
        }
        return nil
    }

    @discardableResult
    func prepareForConversationChange(to targetConversationId: KotlinUuid?) -> Bool {
        guard retryMutationRunId == nil else {
            conversationStore?.publishUserVisibleError(IOSUserVisibleError(
                title: IOSAppLocalization.string(
                    "暂时无法切换会话",
                    defaultValue: "暂时无法切换会话"
                ),
                message: IOSAppLocalization.string(
                    "当前会话仍在生成中，正在执行的工具完成后才能切换。",
                    defaultValue: "当前会话仍在生成中，正在执行的工具完成后才能切换。"
                ),
                severity: .warning
            ))
            return false
        }
        let changesConversation: Bool
        if let targetConversationId {
            changesConversation = currentConversationId.map {
                String(describing: $0) != String(describing: targetConversationId)
            } ?? true
        } else {
            changesConversation = true
        }
        if changesConversation {
            configurationError = nil
            invalidateSuggestionRequest()
            discardSelectedFileContextForConversationChange()
        }
        return true
    }

    func recordedAgentRunBelongsToConversation(
        runId: String,
        conversationId: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            agentRuntimeDao.getRun(id: runId) { result, _ in
                let belongs = result?.conversationId?.caseInsensitiveCompare(conversationId) == .orderedSame
                continuation.resume(returning: belongs)
            }
        }
    }

    @discardableResult
    func retryFailedGeneration(
        sourceRunId: String,
        conversationId: String
    ) async -> Bool {
        guard retryingFailedRunIds.insert(sourceRunId).inserted else { return false }
        defer { retryingFailedRunIds.remove(sourceRunId) }
        guard !isGenerationActive, let store = conversationStore else { return false }
        guard AgentActivityRetryEligibilityStore.shared.isEligible(
            runId: sourceRunId,
            conversationId: conversationId
        ) else { return false }
        let entryConversationRevision = store.conversationSwitchedRevision
        let availableConversations = await store.appIntentSummaries(limit: nil)
        let latestRun = await latestChatRun(conversationId: conversationId)
        guard !isGenerationActive,
              AgentActivityRetryOwnershipPolicy.allows(
                  sourceRunId: sourceRunId,
                  conversationId: conversationId,
                  latestRun: latestRun
              ),
              let summary = availableConversations.first(where: {
                  $0.id.toHexDashString().caseInsensitiveCompare(conversationId) == .orderedSame
              }),
              store.conversationSwitchedRevision == entryConversationRevision,
              prepareForConversationChange(to: summary.id) else {
            return false
        }

        if store.currentConversation?.id != summary.id {
            guard await store.selectConversationIfAvailable(
                id: summary.id,
                commitIf: {
                    store.conversationSwitchedRevision == entryConversationRevision
                        && !self.isGenerationActive
                }
            ) else { return false }
        }
        guard retryMutationRunId == nil else { return false }
        retryMutationRunId = sourceRunId
        defer { retryMutationRunId = nil }
        let ownedConversationRevision = store.conversationSwitchedRevision
        reloadFromStore(reason: .conversationSwitch)
        await refreshCurrentConversationOrchestratedStatus()
        let revalidatedRun = await latestChatRun(conversationId: conversationId)
        guard !isGenerationActive,
              store.conversationSwitchedRevision == ownedConversationRevision,
              store.currentConversation?.id == summary.id,
              AgentActivityRetryOwnershipPolicy.allows(
                  sourceRunId: sourceRunId,
                  conversationId: conversationId,
                  latestRun: revalidatedRun
              ),
              !currentConversationIsOrchestratedChild,
              let index = messages.lastIndex(where: {
                  $0.role == MessageRole.user || $0.role == MessageRole.assistant
              }),
              let lastUserIndex = messages.lastIndex(where: { $0.role == MessageRole.user }),
              !messages[lastUserIndex...].contains(where: { message in
                  message.parts.contains { $0 is UIMessagePart.Tool }
              }) else {
            return false
        }
        guard let conversation = store.currentConversation,
              AgentActivityRetryEligibilityStore.shared.consume(
            runId: sourceRunId,
            conversationId: conversationId
        ) else { return false }
        let started = await regenerateImmediately(
            atMessageIndex: index,
            conversation: conversation,
            state: currentRun.state
        )
        if !started {
            AgentActivityRetryEligibilityStore.shared.setEligible(
                true,
                runId: sourceRunId,
                conversationId: conversationId
            )
        }
        return started
    }

    private func latestChatRun(conversationId: String) async -> AgentActivityDurableRunIdentity? {
        await withCheckedContinuation { continuation in
            agentRuntimeDao.listAllRuns { result, _ in
                let latest = (result ?? [])
                    .filter {
                        IOSDurableRunStore.Descriptor.chatRecoveryAliases.contains($0.agentDescriptorId)
                            && $0.conversationId?.caseInsensitiveCompare(conversationId) == .orderedSame
                    }
                    .max {
                        if $0.startedAt == $1.startedAt { return $0.runId < $1.runId }
                        return $0.startedAt < $1.startedAt
                    }
                continuation.resume(returning: latest.flatMap { run in
                    guard let owner = run.conversationId else { return nil }
                    return AgentActivityDurableRunIdentity(
                        runId: run.runId,
                        conversationId: owner,
                        status: run.status
                    )
                })
            }
        }
    }

    func canOpenActivityConfirmation(runId: String) -> Bool {
        host(runId: runId)?.hasPendingApproval(runId: runId) == true
    }

    func prepareForConversationDeletion(_ conversationId: KotlinUuid) {
        if currentConversationId.map({ String(describing: $0) }) == String(describing: conversationId) {
            discardSelectedFileContextForConversationChange()
        }
        if let run = runRegistry.run(for: conversationId) {
            run.state.steerQueue = []
            run.state.inputText = ""
        }
        host(for: conversationId)?.cancel()
        // P1-a: 删除会话时清掉其队列 sidecar，避免孤儿条目。
        inboxIO.removeQueue(for: conversationId)
        IOSChatBackgroundGenerationCoordinator.shared.cancelJobs(conversationId: conversationId)
    }

    private func discardSelectedFileContextForConversationChange() {
        cancelVisionRecognitionForConversationChange()
        inputText = ""
        clearPendingImages()
        pendingSelectedFilePreview = nil
        selectedFileContextError = nil
        guard let requestId = attachmentOperations.selectedFileRequestId else {
            isAttachingSelectedFile = false
            return
        }

        attachmentOperations.selectedFileRequestId = nil
        isAttachingSelectedFile = false
        let activityRunId = "tool-\(requestId.uuidString)"
        Task { @MainActor [liveActivityController] in
            await liveActivityController.end(
                runId: activityRunId,
                presentation: .cancelled(toolTitle: "文档读取"),
                dismissalDelay: 1
            )
        }
    }

    var configurationIssue: ChatConfigurationIssue? {
        if let currentModel {
            return ChatProviderConfiguration.issue(
                for: currentModel,
                provider: ChatProviderConfiguration.provider(
                    for: currentModel,
                    providers: sharedSettings.snapshot.providers
                )
            )
        }

        if !ChatProviderConfiguration.configuredChatModels(in: sharedSettings.snapshot.providers).isEmpty {
            return .missingModel
        }

        // Legacy scalar fallback for callers that have not selected a KMP
        // provider-backed chat model yet.
        return ChatProviderConfiguration.issue(
            baseUrl: settingsStore.baseUrl,
            apiKey: settingsStore.apiKey,
            modelId: settingsStore.modelId
        )
    }

    /// One derived contract shared by the composer and the send action.
    func composerSendBlockReason(for text: String) -> ChatComposerSendBlockReason? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingImages.isEmpty || pendingSelectedFilePreview != nil else {
            return .emptyInput
        }
        // P1-e: 编排子线程只读（存在 thread_edge 即拦截，含生成中/已取消/已完成；
        // 缓存判定在会话切换时刷新，不逐 keystroke 查 Room）。已知取舍：切换后到
        // 刷新完成前的毫秒级窗口内按缓存（可能为 false）放行——接受该窗口（checker
        // 评级低），未决期拦截的方案会让 Room 查询挂起/变慢时 composer 永久死锁，弃用。
        if currentConversationIsOrchestratedChild {
            return .orchestratedThread
        }
        if isIntelligentUISubmissionInFlight {
            return .generationActive
        }
        if retryMutationRunId != nil {
            return .generationActive
        }
        if isGenerationActive {
            // 生成中发送改为入队（含图/附件）；队列满时回到禁用态。
            return steerQueue.count >= IOSSteerQueueStore.maxPendingUserMessages
                ? .steerQueueFull
                : nil
        }
        guard !isAttachingSelectedFile else { return .attachingSelectedFile }
        guard !isRecognizingImages else { return .recognizingImages }
        guard !hasPendingUserGate else { return .pendingApproval }
        if autoGenerateResponses, let configurationIssue {
            return .configuration(configurationIssue)
        }
        return nil
    }

    // MARK: - Private

    let settingsStore: SettingsStore
    let sharedSettings: IOSSharedSettingsStore
    let localToolExecutor: IOSLocalToolExecutor?
    let searchTransport: any IOSSearchHTTPTransport
    let miniAppRepository: IOSMiniAppRepository
    let workspaceStore: IOSWorkspaceStore
    let autoGenerateResponses: Bool
    let auxiliaryTextProvider: any IOSAgentTextProvider
    let liveActivityController: AgentLiveActivityController
    @ObservationIgnored private lazy var db: AgentRuntimeDatabase = IosDatabaseFactory.shared.createDatabase()
    @ObservationIgnored private let injectedAgentRuntimeDao: AgentRuntimeDao?
    @ObservationIgnored lazy var agentRuntimeDao = injectedAgentRuntimeDao ?? db.agentRuntimeDao()
    @ObservationIgnored lazy var runStore = IOSDurableRunStore(dao: agentRuntimeDao)
    /// 前台兼容入口与 kernel Host 共用的工具账本。必须显式绑到
    /// agentRuntimeDao:run 行经 runStore 落同一个库,账本的 insertRunEvent
    /// 是 INSERT…SELECT agent_run 的 identity 拷贝——各走各的默认库时事件
    /// 静默落空(注入测试库的场景必现),默认参数 IOSAgentRunLedger() 只在
    /// 「run 行也在默认库」时才安全。
    @ObservationIgnored lazy var chatRunLedger: IOSAgentRunLedgering = IOSAgentRunLedger(dao: agentRuntimeDao)
    @ObservationIgnored let mcpManager: IOSMcpManager
    @ObservationIgnored let phoneControl: IOSPhoneControlController
    @ObservationIgnored let wakeScheduler: IOSWakeScheduler
    /// App lifetime retains one observable presentation and Host per live conversation.
    @ObservationIgnored let runRegistry = ChatConversationRunRegistry()
    var runActivityRevision = 0

    var currentRun: ChatConversationRun {
        runRegistry.current(for: currentConversationId)
    }

    var kernelRunHost: ChatKernelRunHost {
        let run = currentRun
        if let host = run.host { return host }
        let host = makeKernelRunHost(state: run.state)
        run.host = host
        return host
    }

    func host(for conversationId: KotlinUuid) -> ChatKernelRunHost? {
        runRegistry.host(for: conversationId)
    }

    func host(runId: String) -> ChatKernelRunHost? {
        runRegistry.host(runId: runId)
    }

    var currentModel: Model? {
        sharedSettings.snapshot.getCurrentChatModel()
    }

    var currentModelId: String {
        (currentModel?.modelId ?? settingsStore.modelId).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var currentModelAbilities: [ModelAbility] {
        if let abilities = currentModel?.abilities, !abilities.isEmpty {
            return abilities
        }
        return ModelRegistry.shared.MODEL_ABILITIES.getData(modelId: currentModelId) as? [ModelAbility] ?? []
    }

    var liveActivityPreferenceEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: IOSExecutionPreferenceKeys.liveActivity) != nil else { return true }
        return defaults.bool(forKey: IOSExecutionPreferenceKeys.liveActivity)
    }

    var pendingAssistantRegeneration: PendingAssistantRegeneration? {
        get { currentRun.state.pendingAssistantRegeneration }
        set { currentRun.state.pendingAssistantRegeneration = newValue }
    }
    @ObservationIgnored let suggestionRequests = ChatSuggestionRequestOwner()
    /// P0-a: the bridge built by the latest makeTextGenerationParams() assembly;
    /// generateResponse hands it to the run coordinator, which owns it for the
    /// whole run (run-level reuse is what makes tool_search hits callable on
    /// the next round). A new user turn gets a new bridge seeded from the
    /// current conversation's recent tool activity.
    var lastAssembledToolExposureBridge: IosToolExposureBridge? {
        get { currentRun.state.toolExposureBridge }
        set { currentRun.state.toolExposureBridge = newValue }
    }
    /// The exact dynamic snapshot used to build the bridge above. They travel
    /// together into the Host so async preamble work cannot swap execution to
    /// a newer manifest while the first-round declaration is still older.
    @ObservationIgnored var lastAssembledDynamicToolSnapshot: IOSDynamicToolCatalogSnapshot?
    /// P1-c: 线程编排工具服务（spawn/list/interrupt + FINAL_ANSWER 回传）。
    /// 测试可注入隔离 DAO 的服务实例（照 mailboxStore 注入先例）；否则用默认
    /// 懒实例（共享 Room + 当前 VM 依赖）。
    @ObservationIgnored private let injectedOrchestrationToolService: IOSThreadOrchestrationToolService?
    @ObservationIgnored private lazy var defaultOrchestrationToolService: IOSThreadOrchestrationToolService = {
        let sharedSettings = self.sharedSettings
        let wakeScheduler = self.wakeScheduler
        let runtimeDao = db.agentRuntimeDao()
        let mailboxDao = db.mailboxDao()
        let threadEdgeDao = db.threadEdgeDao()
        return IOSThreadOrchestrationToolService(
            conversationStoreProvider: { [weak self] in self?.conversationStore },
            mailboxDaoProvider: { mailboxDao },
            threadEdgeDaoProvider: { threadEdgeDao },
            agentRuntimeDaoProvider: { runtimeDao },
            backgroundCoordinator: IOSChatBackgroundGenerationCoordinator.shared,
            makeBackgroundToolRuntime: { [weak self] in
                guard let self else {
                    // self 已释放时无编排服务可注入（服务本体随 VM 析构），
                    // 显式 nil 保证构造点不静默缺参；该分支只在 VM 销毁后才可达。
                    return ChatToolRuntime(
                        settingsStore: SettingsStore(),
                        sharedSettings: IOSSharedSettingsStore(),
                        localToolExecutor: nil,
                        searchTransport: IOSURLSessionSearchHTTPTransport(),
                        mcpManager: IOSMcpManager(sharedSettings: IOSSharedSettingsStore(), configStore: .shared),
                        orchestrationToolService: nil,
                        wakeScheduler: wakeScheduler
                    )
                }
                return self.makeBackgroundToolRuntime()
            },
            currentConversationId: { [weak self] in self?.currentConversationId },
            foregroundActiveRunId: { [weak self] childHex in
                self?.runRegistry.allRuns.compactMap(\.host)
                    .compactMap { $0.activeForegroundRunId(matchingHex: childHex) }.first
            },
            cancelForegroundRun: { [weak self] runId in
                self?.host(runId: runId)?.cancel(runId: runId) ?? false
            },
            foregroundRunCount: { [weak self] in
                self?.runRegistry.allRuns.filter { $0.host?.isRunning == true }.count ?? 0
            },
            // M4: role_assistant_id 存在性校验——对照当前设置快照的 assistants。
            roleAssistantExists: { [weak self] assistantId in
                guard let self else { return false }
                return self.sharedSettings.snapshot.assistants.contains { $0.id == assistantId }
            },
            soulMarkdown: { [weak self] in
                self?.sharedSettings.agentRuntime.agentSoulMarkdown ?? ""
            },
            sharedSettingsProvider: {
                sharedSettings
            }
        )
    }()
    var orchestrationToolService: IOSThreadOrchestrationToolService {
        injectedOrchestrationToolService ?? defaultOrchestrationToolService
    }

    /// P1-c: 后台 job 工具 runtime 构造（AppShell 冷启动恢复、spawnAgent 的
    /// `makeBackgroundToolRuntime` 闭包与测试缝共用同一构造点）。子线程在后台
    /// 引擎里同样注册编排工具，必须注入本 VM 的编排服务。
    func makeBackgroundToolRuntime() -> ChatToolRuntime {
        ChatToolRuntime(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            localToolExecutor: localToolExecutor,
            searchTransport: searchTransport,
            mcpManager: mcpManager,
            orchestrationToolService: orchestrationToolService,
            memoryPollutionMarker: memoryPollutionMarker,
            conversationStoreProvider: { [weak self] in self?.conversationStore },
            wakeScheduler: wakeScheduler
        )
    }

    /// P2-a: harness 拥有的记忆污染置位接线。run 的工具输出收口处判定成功后回调
    /// 这里，把 run 锚定会话写 POLLUTED（KMP 原子 RMW 只升不降）。fire-and-forget：
    /// 失败只记日志，不阻塞工具结果；store 未接好时静默跳过（不会标记到别的会话）。
    var memoryPollutionMarker: ((KotlinUuid, String) -> Void)? {
        { [weak self] conversationId, _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, let store = self.conversationStore else { return }
                _ = await store.markConversationMemoryPolluted(conversationId)
            }
        }
    }

#if DEBUG
    /// 测试缝：直接取真实闭包路径构造的后台工具 runtime（不驱动 spawn 全链路）。
    func makeBackgroundToolRuntimeForTesting() -> ChatToolRuntime {
        makeBackgroundToolRuntime()
    }
#endif

    // MARK: - Init

    init(
        settingsStore: SettingsStore,
        sharedSettings: IOSSharedSettingsStore = IOSSharedSettingsStore(),
        localToolExecutor: IOSLocalToolExecutor? = nil,
        searchTransport: any IOSSearchHTTPTransport = IOSURLSessionSearchHTTPTransport(),
        miniAppRepository: IOSMiniAppRepository? = nil,
        workspaceStore: IOSWorkspaceStore? = nil,
        autoGenerateResponses: Bool = true,
        auxiliaryTextProvider: any IOSAgentTextProvider = OpenAIKmpProviderAdapter(),
        liveActivityController: AgentLiveActivityController? = nil,
        mcpManager: IOSMcpManager? = nil,
        steerQueueStore: IOSSteerQueueStore? = nil,
        mailboxStore: IOSMailboxStore? = nil,
        orchestrationToolService: IOSThreadOrchestrationToolService? = nil,
        mailboxActivityCenter: IOSMailboxActivityCenter? = nil,
        agentRuntimeDao: AgentRuntimeDao? = nil,
        phoneControl: IOSPhoneControlController = .shared,
        wakeScheduler: IOSWakeScheduler? = nil
    ) {
        self.settingsStore = settingsStore
        self.sharedSettings = sharedSettings
        self.localToolExecutor = localToolExecutor
        self.searchTransport = searchTransport
        self.miniAppRepository = miniAppRepository ?? IOSMiniAppRepository.shared
        self.workspaceStore = workspaceStore ?? IOSWorkspaceStore.shared
        self.autoGenerateResponses = autoGenerateResponses
        self.auxiliaryTextProvider = auxiliaryTextProvider
        self.liveActivityController = liveActivityController ?? .shared
        self.injectedAgentRuntimeDao = agentRuntimeDao
        self.phoneControl = phoneControl
        self.wakeScheduler = wakeScheduler ?? .shared
        // Build from the shared config store (same UserDefaults key as
        // McpServersView) so callTool reaches the same configured servers;
        // tests inject a manager with a deterministic directory instead.
        self.mcpManager = mcpManager ?? IOSMcpManager(
            sharedSettings: sharedSettings,
            configStore: .shared,
            isNetworkAllowed: { [localToolExecutor] in
                guard let localToolExecutor else { return true }
                return localToolExecutor.permissionPolicy(capabilityId: "ios.mcp.tool_call") != .disabled
            }
        )
        self.injectedOrchestrationToolService = orchestrationToolService
        // P1-d: mailbox 活动广播（wait_agent 事件源）。测试注入独立实例隔离信号；
        // 生产与编排服务共用 `.shared`。
        self.inboxIO = ChatConversationInboxIO(
            steerQueueStore: steerQueueStore ?? IOSSteerQueueStore(),
            mailboxStore: mailboxStore ?? IOSMailboxStore(),
            activityCenter: mailboxActivityCenter ?? .shared
        )
        // P1-c: 后台 job 终态（FINAL_ANSWER）由本 VM 的编排服务回传父线程。
        // 单例协调器在 App 内只有一份 job 面；VM 重建时后注册者生效（App 实际
        // 只有单个 VM，测试不驱动真实后台 job）。
        IOSChatBackgroundGenerationCoordinator.shared.onRunTerminal = {
            [weak self] conversationId, runId, finalMessages, displayBaseline in
            guard let self else { return }
            self.refreshIntelligentUIReceipts(messages: finalMessages, conversationID: conversationId.toHexDashString())
            let terminal = try? await self.runStore.snapshot(runId: runId)
            if let terminal, terminal.status.isTerminal, terminal.finishedAt != nil {
                await self.wakeScheduler.recordRunTerminal(
                    runID: runId, status: terminal.status.wireName,
                    result: IOSWakeTaskOutput.text(in: finalMessages, baseline: displayBaseline)
                )
            }
            await self.orchestrationToolService.notifyRunTerminal(
                conversationId: conversationId,
                runId: runId,
                finalMessages: finalMessages,
                displayBaseline: displayBaseline,
                terminalStatus: terminal?.status,
                terminalReason: terminal?.terminalReason
            )
        }
        IOSChatBackgroundGenerationCoordinator.shared.onRunFinishedWithPendingTasks = {
            [weak self] conversationId, provider, params, bridge, policy in
            _ = await self?.orchestrationToolService.resumePendingTasks(
                for: conversationId,
                providerSetting: provider,
                params: params,
                toolExposureBridge: bridge,
                executionPolicy: policy
            )
        }
        IOSChatBackgroundGenerationCoordinator.shared.onToolOutcomeUnknown = {
            [weak self] descriptor in
            guard let self,
                  !self.toolOutcomeUnknownDescriptors.contains(descriptor) else { return }
            self.toolOutcomeUnknownDescriptors.append(descriptor)
        }
    }

    // MARK: - Actions


}
