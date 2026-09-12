import Foundation
import UIKit
@preconcurrency import Shared

/// P0-2 B1: 内核前台 run 的 Host——把 `ChatRunKernelAdapter` 的回调面接到
/// 与 `ChatGenerationCoordinator`(CGC)完全相同的副作用序列:
///
/// - start preamble(CG-C start :1037-1166):runId/startedAt、I-4 设置定格、
///   LiveActivity 起步、keepalive begin + 0/4 进度、recordRun(.running) →
///   mcp sync → Codex resolve → 适配器 run;
/// - 逐轮上传准备(prepareUploadMessages,CG-C prepareAndStartStreaming
///   :1960-2050 等价):Generative UI 引导/单次补绘 → 运行时语境注入 →
///   压缩 → 图像提示 → 编排链接刷新 →
///   记忆召回标记 → finalize → coalesce;
/// - 暂停(approvalDecider,CG-C pauseForApproval :3798-3873):bump
///   .awaitingToolApproval → markRunAwaitingPermission → 脱敏快照持久化 →
///   keepalive end → LiveActivity waitingForUser → setIsLoading(false) →
///   Watch 发布 → 发卡,随后挂起等待审批入口恢复;
/// - 恢复(CG-C executeApprovedAsyncTool :4425-4476 + resumeAfterApproval
///   :4551-4623):入口清卡 + setIsLoading(true) + keepalive begin +
///   LiveActivity generating,适配器在 Started 之后经 onRunResumed 做
///   resumeRunAfterPermission 持久化认领(失败 → 账本补
///   Finished(not_executed_permission_claim_failed) + failed 收口);
/// - 终态:completed = CG-C :2732-2797(miniApp 事务 + persist → recordRun →
///   Watch/LiveActivity 收尾)+ finishStreaming :4919-4979 收尾序列;
///   failed = presentStreamError :2483-2533(provider/上传失败带用户向
///   错误泡;截断由适配器 A4 分支追加提示,这里不再加泡);
///   cancelled = cancel :1485-1581(填充/快照持久化 → recordRun(cause)→
///   Watch/LiveActivity cancelled → keepalive end,restoreSteerQueueLeftover
///   而非 handleSteerQueueAtTerminal)。
///
/// 记录在案的 v1 差异(相对 CGC 前台):
/// - 无逐拍推进/终端 drain:B2 投影在引擎侧按 CGC 同一 48ms 节拍门控推送,
///   provisional 气泡一次放出全部已收增量(CG-C 是每拍推进 12-36 字);
/// - 取消的同步拆解比 CGC 晚一个 MainActor hop(取消填充仍同步上屏);
/// - 首轮 mailbox/steer 预折进 working,上传准备会覆盖它们(CG-C 首轮是
///   准备后再追加;上传字节序差异接受)。
@MainActor
final class ChatKernelRunHost {

    /// 取消原因(CG-C CancellationCause :1452 同款):决定 durable 终态。
    enum CancellationCause {
        case user
        case backgroundInterruption

        var durableStatus: AgentRunStatus {
            switch self {
            case .user: return .cancelled
            case .backgroundInterruption: return .interrupted
            }
        }
    }

    /// 审批卡类目(入口分发用;与 ChatToolApprovalPrompt 九案一一对应)。
    private enum ApprovalCategory {
        case memory, search, webMount, workspace, ish, mcp, council, askUser, recipe
    }

    private enum ImageToolTerminalClaimResult: Equatable {
        case recorded
        case alreadyClaimed
        case failed
    }

    private let dependencies: ChatGenerationDependencies
    private let bindings: ChatGenerationBindings
    private let backgroundExecution: BackgroundGenerationKeepAlive
    private let toolLedger: IOSAgentRunLedgering
    /// 全 provider 文本适配器；OpenAI/Claude/Codex/Grok/Gemini 的协议分流
    /// 由唯一 Engine/Adapter 边界完成。
    private let textProviderOverride: (any IOSAgentTextProvider)?
#if DEBUG
    var backgroundStartOverrideForTesting: ((IOSChatBackgroundHandoff, IOSConversationStore) -> Bool)?
#endif
    private lazy var projection = ChatKernelProjection(bindings: bindings)

    /// 与 CGC :832-851 同配方的 tool runtime(prepared 候选按 toolCallId
    /// 挂在其实例上,kernel run 独占一个实例,不与 CGC 共享)。
    private lazy var toolRuntime: ChatToolRuntime = {
        ChatToolRuntime(
            settingsStore: dependencies.settingsStore,
            sharedSettings: dependencies.sharedSettings,
            localToolExecutor: dependencies.localToolExecutor,
            searchTransport: dependencies.searchTransport,
            mcpManager: dependencies.mcpManager,
            orchestrationToolService: dependencies.orchestrationToolService,
            memoryPollutionMarker: dependencies.memoryPollutionMarker,
            conversationStoreProvider: dependencies.conversationStoreProvider,
            ledger: toolLedger
        )
    }()
#if DEBUG
    var toolRuntimeForTesting: ChatToolRuntime { toolRuntime }
#endif

    // MARK: - run 作用域状态

    private var adapter: ChatRunKernelAdapter?
    private var runTask: Task<Void, Never>?
    private(set) var currentRunId: String?
    private var didYieldForeground = false
    private var currentStartedAt: Int64 = 0
    private var currentInputDigest: String = ""
    private var currentConversationIdForRun: KotlinUuid?
    private var currentParams: TextGenerationParams?
    private var currentToolExposureBridge: IosToolExposureBridge?
    private var currentDynamicToolSnapshot: IOSDynamicToolCatalogSnapshot?
    /// I-4:run 开始时定格的设置快照(逐轮压缩配置只从这里取,CG-C
    /// settingsSnapshot(forRun:) 等价)。
    private var runSettings: Settings?
    private var runExecutionPolicy: IOSExecutionPolicySnapshot?
    /// 空回复判定里的 miniApp 语境基线(CG-C 用 run 的展示基线)。
    private var displayBaseline: [UIMessage] = []
    private var currentGenerativeUiRequirement: IOSGenerativeUiRequirement = .none
    private var currentGenerativeUiFallbackAttempted = false
    private var currentGenerativeUiRetryIssue: String?
    private var backgroundHandoff: IOSChatBackgroundHandoff?
    private weak var pendingBackgroundConversationStore: IOSConversationStore?
    private var activeToolExecutionName: String?
    private var activeToolEffectClass: IOSToolEffectClass?
    private var activeTextProvider: (any IOSAgentTextProvider)?
    private var activeDurableTextProvider: ChatKernelDurableTextProvider?
    private var activeImageToolCall: UIMessagePart.Tool?
    private var imageExecutionTask: Task<[UIMessage], Never>?
    private var imageExecutionToken: UUID?
    private var imageToolDidStart = false
    private var imageToolTerminalClaimed = false
#if DEBUG
    var imageToolExecutionOverrideForTesting: (@MainActor (UIMessagePart.Tool, [UIMessage]) async -> [UIMessage])?
#endif
    private var durableResponseCursor: (responseId: String, sequenceNumber: Int64)?
    private var durableCheckpointPersisted = false
    private var citationTracker: IOSMemoryCitationTracker?
    private var streamClock = ChatGenerationSpeedClock()
    private var keepaliveHeld = false
    private var didReportFirstDeltaThisRound = false
    /// 适配器已进入 run()(决定 cancel 是否调用 adapter.cancel——进入前
    /// working 还是空的,取消填充会把空数组发布成 transcript)。
    private var adapterDidStart = false

    // MARK: - 终态/取消状态

    private var didFinalizeTerminal = false
    private var cancelCause: CancellationCause?
    private var cancelBaseline: IOSConversationWriteBaseline?
    private var terminalWireName: String?
    /// provider/上传准备失败的原始错误串(适配器 onProviderFailure 或
    /// Host 自己的暂停持久化失败),failed 终态据此产出用户向错误泡。
    private var lastFailureMessage: String?
    private var toolOutcomeUnknownSignal: IOSToolOutcomeUnknownSignal?

    // MARK: - 审批挂起状态

    private var pendingApprovalToolCallId: String?
    private var pendingPrompt: ChatToolApprovalPrompt?
    private var approvalWaiter: CheckedContinuation<ChatKernelApprovalDecision?, Never>?

    var isRunning: Bool { currentRunId != nil }
    var hasPendingToolApproval: Bool { approvalWaiter != nil }
    private var canHandoffActiveTool: Bool {
        activeToolExecutionName == nil ||
            activeToolEffectClass == .pure ||
            activeToolEffectClass == .networkRead
    }

    init(
        dependencies: ChatGenerationDependencies,
        bindings: ChatGenerationBindings,
        backgroundExecution: BackgroundGenerationKeepAlive = .shared,
        toolLedger: IOSAgentRunLedgering = IOSAgentRunLedger(),
        textProvider: (any IOSAgentTextProvider)? = nil
    ) {
        self.dependencies = dependencies
        self.bindings = bindings
        self.backgroundExecution = backgroundExecution
        self.toolLedger = toolLedger
        self.textProviderOverride = textProvider
    }

    /// P1-c 编排服务用(CG-C :971 同款):按会话 hex 匹配当前 run。
    func activeForegroundRunId(matchingHex conversationHex: String) -> String? {
        guard let runId = currentRunId,
              let conversationId = currentConversationIdForRun,
              conversationId.toHexDashString() == conversationHex else {
            return nil
        }
        return runId
    }

    /// CG-C :980 同款:当前 run 的会话归属(UI 状态按会话判定)。
    var activeConversationId: KotlinUuid? {
        currentConversationIdForRun
    }

    /// CG-C :984 同款(Watch 确认入口的归属判定)。
    func hasPendingApproval(runId: String) -> Bool {
        currentRunId == runId && hasPendingToolApproval
    }

    // MARK: - start(CG-C start :1037-1166)

    func start(
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        inputDigest: String,
        conversationId: KotlinUuid?,
        uploadMessages: [UIMessage],
        toolExposureBridge: IosToolExposureBridge? = nil,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot? = nil
    ) {
        if isRunning {
            cancel()
        }
        didYieldForeground = false
        bindings.setIsLoading(true)
        bindings.setContextCompactState(.idle)

        let runId = UUID().uuidString
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        currentRunId = runId
        currentStartedAt = startedAt
        WatchTaskCoordinator.shared.registerRun(runId: runId, startedAt: startedAt)
        currentInputDigest = inputDigest
        currentConversationIdForRun = conversationId
        currentParams = params
        runSettings = dependencies.sharedSettings.snapshot
        runExecutionPolicy = dependencies.localToolExecutor?.executionPolicySnapshot(
            execJavaScriptEnabled: dependencies.settingsStore.execJavaScriptEnabled,
            webSearchEnabled: dependencies.sharedSettings.snapshot.enableWebSearch,
            mcpEnabled: dependencies.sharedSettings.isCapabilityGateEnabled(.mcp)
        )
        let runProtocolContext = AgentRunProtocolContext(
            providerId: providerSetting.id.description(),
            modelId: params.model.modelId,
            promptVersion: nil,
            toolCatalogVersion: chatInputDigest(
                for: IosRunRequestSnapshotJsonBridge.shared.encodeToolCatalog(tools: params.tools)
            ),
            capabilitySnapshot: runExecutionPolicy?.encodedJSON
        )
        displayBaseline = uploadMessages
        let bridge = toolExposureBridge ?? IosToolExposureBridge(tools: params.tools)
        // Capture at start, before MCP/provider awaits. Production passes the
        // same snapshot that built `bridge`; the fallback keeps direct Host
        // callers deterministic at their own start boundary.
        let pinnedRecipeCatalog = recipeCatalogSnapshot
            ?? IOSDynamicToolRegistry.shared.currentSnapshot
        currentToolExposureBridge = bridge
        currentDynamicToolSnapshot = pinnedRecipeCatalog
        currentGenerativeUiRequirement = .none
        currentGenerativeUiFallbackAttempted = false
        currentGenerativeUiRetryIssue = nil
        backgroundHandoff = nil
        pendingBackgroundConversationStore = nil
        activeToolExecutionName = nil
        activeToolEffectClass = nil
        activeTextProvider = nil
        activeDurableTextProvider = nil
        activeImageToolCall = nil
        imageExecutionTask = nil
        imageExecutionToken = nil
        imageToolDidStart = false
        imageToolTerminalClaimed = false
        durableResponseCursor = nil
        durableCheckpointPersisted = false
        didFinalizeTerminal = false
        cancelCause = nil
        cancelBaseline = nil
        terminalWireName = nil
        lastFailureMessage = nil
        adapterDidStart = false
        keepaliveHeld = false
        didReportFirstDeltaThisRound = false
        streamClock = ChatGenerationSpeedClock()
        let tracker = IOSMemoryCitationTracker()
        citationTracker = tracker

        bindings.startLiveActivity(
            runId,
            conversationId,
            AgentActivityPresentation.response(stage: AgentActivityResponseStagePolicy.initialStage)
        )
        // 生成一开始就拿后台执行权(CG-C :1084-1104 同款纪律与注释语义)。
        beginKeepAlive(runId: runId, subtitle: params.model.displayName)
        backgroundExecution.updateProgress(
            runId,
            completed: 0,
            total: 4,
            subtitle: IOSAppLocalization.string("准备上下文", defaultValue: "准备上下文")
        )

        let adapter = makeAdapter(runId: runId)
        self.adapter = adapter

        runTask = Task { @MainActor [weak self] in
            guard let self, self.currentRunId == runId else { return }
            // start 后、recordRun 前的同步窗口内取消(CG-C 同款竞态——cancel
            // 已收口,running 不得再落账)。
            if self.cancelCause != nil {
                await self.finalizeTerminal(runId: runId)
                return
            }
            // 运行册 .running(CG-C :1108)。
            guard await self.bindings.recordRun(
                runId,
                startedAt,
                .running,
                inputDigest,
                conversationId?.toHexDashString(),
                runProtocolContext
            ) else {
                await self.preambleFailed(
                    rawMessage: IOSAppLocalization.string(
                        "无法保存任务状态，生成未开始。",
                        defaultValue: "无法保存任务状态，生成未开始。"
                    ),
                    modelId: params.model.modelId,
                    runId: runId
                )
                return
            }
            if self.cancelCause != nil {
                await self.finalizeTerminal(runId: runId)
                return
            }
            guard self.currentRunId == runId else { return }
            // mcp sync(CG-C :1125-1128)。
            if self.mcpEnabledForRun {
                await self.dependencies.mcpManager.syncAll(enabledOverride: true)
            }
            guard self.currentRunId == runId else { return }
            if self.cancelCause != nil {
                await self.finalizeTerminal(runId: runId)
                return
            }
            // Codex / Grok OAuth resolve：保持与旧生产入口相同的身份重写链。
            let effectiveProvider: ProviderSetting
            do {
                effectiveProvider = try await IOSGrokWebProviderResolver.resolved(
                    try await IOSCodexProviderResolver.resolved(providerSetting)
                )
            } catch {
                await self.preambleFailed(
                    rawMessage: (error as NSError).localizedDescription,
                    modelId: params.model.modelId,
                    runId: runId
                )
                return
            }
            guard self.currentRunId == runId else { return }
            if self.cancelCause != nil {
                await self.finalizeTerminal(runId: runId)
                return
            }
            // Codex authMode 迁移(CG-C :1150-1158)。
            if let openAI = providerSetting as? ProviderSetting.OpenAI,
               openAI.authMode != OpenAIAuthMode.codexOauth,
               IOSCodexProviderResolver.isCodexProvider(providerSetting) {
                _ = self.dependencies.sharedSettings.setOpenAIAuthMode(
                    providerId: openAI.id.description(),
                    authMode: OpenAIAuthMode.codexOauth
                )
                self.dependencies.sharedSettings.syncLegacySettingsStoreForCurrentChat(self.dependencies.settingsStore)
            }
            let effectiveParams = IOSGrokWebProviderResolver.augmentParamsForGrok(
                IOSCodexProviderResolver.augmentParamsForCodex(params, provider: effectiveProvider),
                provider: effectiveProvider
            )
            IOSCodexProviderResolver.writeRequestDiagnostic(
                originalProvider: providerSetting,
                resolvedProvider: effectiveProvider,
                params: effectiveParams
            )

            let adapterProvider = self.makeTextProvider(runId: runId)
            self.activeTextProvider = adapterProvider
            let request = self.makeRunRequest(
                adapterProvider: adapterProvider,
                providerSetting: effectiveProvider,
                params: effectiveParams,
                runId: runId,
                startedAt: startedAt,
                inputDigest: inputDigest,
                conversationId: conversationId,
                initialMessages: uploadMessages,
                toolExposureBridge: bridge,
                recipeCatalogSnapshot: pinnedRecipeCatalog,
                citationTracker: tracker
            )
            self.adapterDidStart = true
            _ = await adapter.run(request)
            guard self.currentRunId == runId else { return }
            await self.runGenerativeUiRepairIfNeeded(
                runId: runId,
                provider: effectiveProvider,
                params: effectiveParams,
                startedAt: startedAt,
                inputDigest: inputDigest,
                conversationId: conversationId,
                bridge: bridge,
                recipeCatalogSnapshot: pinnedRecipeCatalog,
                tracker: tracker
            )
            guard self.currentRunId == runId else { return }
            await self.finalizeTerminal(runId: runId)
        }
    }

    /// 用户从图片卡片发起的单次修改。它不是模型轮，也不进入 Agent Engine；
    /// 但仍由唯一前台 Host 持有 run 生命周期，并保持付费副作用的
    /// persist → Started → execute → Finished 顺序。
    func runImageTool(
        input: String,
        conversationId: KotlinUuid?,
        modelDisplayName: String
    ) {
        guard !isRunning else { return }
        bindings.setIsLoading(true)
        bindings.setContextCompactState(.idle)

        let runId = UUID().uuidString
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let inputDigest = chatInputDigest(for: input)
        currentRunId = runId
        currentStartedAt = startedAt
        WatchTaskCoordinator.shared.registerRun(runId: runId, startedAt: startedAt)
        currentInputDigest = inputDigest
        currentConversationIdForRun = conversationId
        currentParams = nil
        currentToolExposureBridge = nil
        runSettings = nil
        runExecutionPolicy = nil
        displayBaseline = bindings.getMessages()
        currentGenerativeUiRequirement = .none
        currentGenerativeUiFallbackAttempted = false
        currentGenerativeUiRetryIssue = nil
        backgroundHandoff = nil
        pendingBackgroundConversationStore = nil
        activeToolExecutionName = "generate_image"
        activeToolEffectClass = .sideEffect
        activeTextProvider = nil
        activeDurableTextProvider = nil
        durableResponseCursor = nil
        durableCheckpointPersisted = false
        didFinalizeTerminal = false
        cancelCause = nil
        cancelBaseline = nil
        terminalWireName = nil
        lastFailureMessage = nil
        adapter = nil
        adapterDidStart = false
        keepaliveHeld = true
        citationTracker = nil
        streamClock = ChatGenerationSpeedClock()

        let imagePresentation = AgentActivityPresentation.runningTool(toolName: "generate_image")
        bindings.startLiveActivity(runId, conversationId, imagePresentation)
        backgroundExecution.begin(
            runId,
            title: IOSAppLocalization.string(
                "Amber 正在生成图片",
                defaultValue: "Amber 正在生成图片"
            ),
            subtitle: modelDisplayName,
            onExpire: { [weak self] in
                guard let self, self.currentRunId == runId else { return }
                self.cancel(cause: .backgroundInterruption)
            },
            onSystemTaskExpiration: { [weak self] in
                guard let self, self.currentRunId == runId else { return }
                self.cancel(cause: .backgroundInterruption)
            }
        )
        backgroundExecution.updateProgress(
            runId,
            completed: 0,
            total: 3,
            subtitle: IOSAppLocalization.string("准备图片请求", defaultValue: "准备图片请求")
        )

        let toolCall = toolRuntime.userInitiatedImageToolCall(input: input)
        activeImageToolCall = toolCall
        imageToolDidStart = false
        imageToolTerminalClaimed = false
        var snapshot = bindings.getMessages()
        snapshot.append(UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [toolCall],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        ))
        bindings.setMessages(snapshot)
        bindings.bumpMessageRevision(.toolCallStarted, 1)

        runTask = Task { @MainActor [weak self] in
            guard let self, self.currentRunId == runId else { return }
            if self.cancelCause != nil {
                await self.finalizeTerminal(runId: runId)
                return
            }
            let didRecordRun = await self.bindings.recordRun(
                runId,
                startedAt,
                .running,
                inputDigest,
                conversationId?.toHexDashString(),
                nil
            )
            guard didRecordRun else {
                if self.cancelCause != nil {
                    await self.finalizeTerminal(runId: runId)
                    return
                }
                await self.failImageToolCallBeforeExecution(
                    toolCall,
                    in: snapshot,
                    runId: runId,
                    startedAt: startedAt,
                    inputDigest: inputDigest,
                    conversationId: conversationId,
                    reason: IOSAppLocalization.string(
                        "无法保存任务状态，图片生成未开始。",
                        defaultValue: "无法保存任务状态，图片生成未开始。"
                    )
                )
                return
            }
            guard self.currentRunId == runId, self.cancelCause == nil else {
                await self.finalizeTerminal(runId: runId)
                return
            }

            let argsDigest = chatInputDigest(for: toolCall.input)
            let preparation = await self.toolLedger.recordToolCallPrepared(
                runId: runId,
                toolCallId: toolCall.toolCallId,
                toolName: toolCall.toolName,
                argsDigest: argsDigest,
                effectClass: .sideEffect
            )
            guard self.currentRunId == runId, self.cancelCause == nil else {
                _ = await self.toolLedger.recordToolCallRecoveryTransition(
                    runId: runId,
                    toolCallId: toolCall.toolCallId,
                    expected: .prepared,
                    to: .reconciled,
                    outcome: "cancelled_before_execution"
                )
                await self.finalizeTerminal(runId: runId)
                return
            }
            guard preparation == .ready else {
                _ = await self.toolLedger.recordToolCallRecoveryTransition(
                    runId: runId,
                    toolCallId: toolCall.toolCallId,
                    expected: .prepared,
                    to: .reconciled,
                    outcome: "not_executed_prepare_failed"
                )
                await self.failImageToolCallBeforeExecution(
                    toolCall,
                    in: snapshot,
                    runId: runId,
                    startedAt: startedAt,
                    inputDigest: inputDigest,
                    conversationId: conversationId,
                    reason: IOSAppLocalization.string(
                        "无法保存工具执行前状态，请检查存储空间后重试。",
                        defaultValue: "无法保存工具执行前状态，请检查存储空间后重试。"
                    )
                )
                return
            }

            let baseline = self.bindings.capturePersistMessagesBaseline(conversationId)
            let didPersistBeforeExecution = await self.bindings.persistMessagesSnapshot(
                snapshot,
                conversationId,
                baseline
            )
            guard self.currentRunId == runId, self.cancelCause == nil else {
                _ = await self.toolLedger.recordToolCallRecoveryTransition(
                    runId: runId,
                    toolCallId: toolCall.toolCallId,
                    expected: .prepared,
                    to: .reconciled,
                    outcome: "cancelled_before_execution"
                )
                await self.finalizeTerminal(runId: runId)
                return
            }
            guard didPersistBeforeExecution else {
                _ = await self.toolLedger.recordToolCallRecoveryTransition(
                    runId: runId,
                    toolCallId: toolCall.toolCallId,
                    expected: .prepared,
                    to: .reconciled,
                    outcome: "not_executed_persist_failed"
                )
                await self.failImageToolCallBeforeExecution(
                    toolCall,
                    in: snapshot,
                    runId: runId,
                    startedAt: startedAt,
                    inputDigest: inputDigest,
                    conversationId: conversationId,
                    reason: IOSAppLocalization.string(
                        "无法保存工具执行前状态，请检查存储空间后重试。",
                        defaultValue: "无法保存工具执行前状态，请检查存储空间后重试。"
                    )
                )
                return
            }

            let didRecordStarted = await self.toolLedger.recordToolCallStarted(
                runId: runId,
                toolCallId: toolCall.toolCallId,
                toolName: toolCall.toolName,
                argsDigest: argsDigest,
                effectClass: .sideEffect
            )
            self.imageToolDidStart = didRecordStarted
            guard self.currentRunId == runId, self.cancelCause == nil else {
                if didRecordStarted {
                    let terminalClaim = await self.recordImageToolTerminalIfNeeded(
                        runId: runId,
                        toolCall: toolCall,
                        outcome: "cancelled_before_execution",
                        resultPayload: nil
                    )
                    if terminalClaim == .failed {
                        await self.failImageToolDurability(runId: runId)
                        return
                    }
                    guard terminalClaim == .recorded else { return }
                } else {
                    await self.reconcileImageToolStartFailure(
                        runId: runId,
                        toolCallId: toolCall.toolCallId,
                        outcome: "cancelled_before_execution"
                    )
                }
                await self.finalizeTerminal(runId: runId)
                return
            }
            guard didRecordStarted else {
                await self.reconcileImageToolStartFailure(
                    runId: runId,
                    toolCallId: toolCall.toolCallId,
                    outcome: "not_executed_start_failed"
                )
                await self.failImageToolCallBeforeExecution(
                    toolCall,
                    in: snapshot,
                    runId: runId,
                    startedAt: startedAt,
                    inputDigest: inputDigest,
                    conversationId: conversationId,
                    reason: IOSAppLocalization.string(
                        "无法保存工具执行前状态，请检查存储空间后重试。",
                        defaultValue: "无法保存工具执行前状态，请检查存储空间后重试。"
                    )
                )
                return
            }

            let executionToken = UUID()
#if DEBUG
            let imageToolExecutionOverrideForTesting = self.imageToolExecutionOverrideForTesting
            let executionTask = Task { @MainActor [toolRuntime = self.toolRuntime] in
                if let imageToolExecutionOverrideForTesting {
                    return await imageToolExecutionOverrideForTesting(toolCall, snapshot)
                }
                return await toolRuntime.messagesByExecutingImageToolCall(toolCall, in: snapshot)
            }
#else
            let executionTask = Task { @MainActor [toolRuntime = self.toolRuntime] in
                await toolRuntime.messagesByExecutingImageToolCall(toolCall, in: snapshot)
            }
#endif
            self.imageExecutionToken = executionToken
            self.imageExecutionTask = executionTask
            let resumed = await executionTask.value
            if self.imageExecutionToken == executionToken {
                self.imageExecutionToken = nil
                self.imageExecutionTask = nil
            }
            let failureReason = ChatToolOutputFormatter.imageFailureReason(in: resumed, matching: toolCall)
            let resultParts = resumed
                .flatMap(\.parts)
                .compactMap { $0 as? UIMessagePart.Tool }
                .first { $0.toolCallId == toolCall.toolCallId }?
                .output
            guard self.currentRunId == runId else { return }
            if self.cancelCause != nil {
                let terminalClaim = await self.markImageToolOutcomeUnknownIfNeeded(
                    runId: runId,
                    toolCall: toolCall,
                    outcome: "cancelled_during_execution"
                )
                if terminalClaim == .failed {
                    await self.failImageToolDurability(runId: runId)
                    return
                }
                guard terminalClaim == .recorded else { return }
                await self.finalizeTerminal(runId: runId)
                return
            }
            let terminalClaim = await self.recordImageToolTerminalIfNeeded(
                runId: runId,
                toolCall: toolCall,
                outcome: failureReason == nil ? "completed" : "failed",
                resultPayload: resultParts.map { IosToolOutputJsonBridge.shared.encode(parts: $0) }
            )
            if terminalClaim == .failed {
                await self.failImageToolDurability(runId: runId)
                return
            }
            guard terminalClaim == .recorded else { return }
            guard self.currentRunId == runId else { return }
            if self.cancelCause != nil {
                await self.finalizeTerminal(runId: runId)
                return
            }
            guard !self.didFinalizeTerminal else { return }
            self.didFinalizeTerminal = true

            self.bindings.setMessages(resumed)
            self.bindings.bumpMessageRevision(.toolResultAppended, 1)
            let conversationHex = conversationId?.toHexDashString()
            let didPersist = await self.bindings.persistMessages(conversationId)
            if didPersist {
                await IOSRunRecovery.reconcilePersistedToolResults(runId: runId)
            }
            let succeeded = failureReason == nil && didPersist
            let didRecordTerminalRun = await self.bindings.recordRun(
                runId,
                startedAt,
                didPersist ? (failureReason == nil ? .completed : .failed) : .recoveryPending,
                inputDigest,
                conversationHex,
                nil
            )
            guard didRecordTerminalRun else {
                self.releaseLocalRunAfterTerminalRecordFailure(runId: runId)
                return
            }
            if succeeded {
                WatchTaskCoordinator.shared.publishCompleted(
                    runId: runId,
                    conversationId: conversationHex,
                    summary: ChatGenerationSupport.watchSummary(from: resumed),
                    kind: .imageGeneration
                )
            } else {
                WatchTaskCoordinator.shared.publish(
                    runId: runId,
                    conversationId: conversationHex,
                    presentation: .failed(),
                    summary: WatchTaskText.clipped(
                        failureReason ?? IOSAppLocalization.string(
                            "图片已生成，但结果保存失败。",
                            defaultValue: "图片已生成，但结果保存失败。"
                        ),
                        maxLength: 200
                    )
                )
            }
            await self.dependencies.liveActivityController.end(
                runId: runId,
                presentation: succeeded ? .completed(toolTitle: "图片生成") : .failed()
            )
            self.teardownRun(
                runId: runId,
                terminalEvent: succeeded ? .generationCompleted : .generationFailed
            )
            if succeeded {
                self.bindings.generationSucceeded()
            }
        }
    }

    private func failImageToolCallBeforeExecution(
        _ toolCall: UIMessagePart.Tool,
        in snapshot: [UIMessage],
        runId: String,
        startedAt: Int64,
        inputDigest: String,
        conversationId: KotlinUuid?,
        reason: String
    ) async {
        guard currentRunId == runId, !didFinalizeTerminal else { return }
        didFinalizeTerminal = true
        let failure = ChatToolOutputFormatter.toolFailureJSON(
            toolName: toolCall.toolName,
            reason: reason,
            cancelled: false
        )
        let failedMessages = toolRuntime.messagesByFinishingToolCall(
            toolCall,
            outputText: failure,
            in: snapshot
        )
        bindings.setMessages(failedMessages)
        bindings.bumpMessageRevision(.toolResultAppended, 1)
        let conversationHex = conversationId?.toHexDashString()
        let didPersist = await bindings.persistMessages(conversationId)
        let didRecordRun = await bindings.recordRun(
            runId,
            startedAt,
            didPersist ? .failed : .recoveryPending,
            inputDigest,
            conversationHex,
            nil
        )
        guard didRecordRun else {
            releaseLocalRunAfterTerminalRecordFailure(runId: runId)
            return
        }
        WatchTaskCoordinator.shared.publish(
            runId: runId,
            conversationId: conversationHex,
            presentation: .failed(),
            summary: WatchTaskText.clipped(reason, maxLength: 200)
        )
        await dependencies.liveActivityController.end(runId: runId, presentation: .failed())
        teardownRun(runId: runId, terminalEvent: .generationFailed)
    }

    private func recordImageToolTerminalIfNeeded(
        runId: String,
        toolCall: UIMessagePart.Tool,
        outcome: String,
        resultPayload: String?
    ) async -> ImageToolTerminalClaimResult {
        guard currentRunId == runId,
              imageToolDidStart else { return .failed }
        guard !imageToolTerminalClaimed else { return .alreadyClaimed }
        imageToolTerminalClaimed = true
        return await toolLedger.recordToolCallTerminal(
            runId: runId,
            toolCallId: toolCall.toolCallId,
            outcome: outcome,
            resultPayload: resultPayload
        ) ? .recorded : .failed
    }

    private func failImageToolDurability(runId: String) async {
        guard currentRunId == runId, !didFinalizeTerminal else { return }
        didFinalizeTerminal = true
        lastFailureMessage = IOSAppLocalization.string(
            "tool result ledger write failed",
            defaultValue: "tool result ledger write failed"
        )
        await failedTerminal(runId: runId, requiresRecovery: true)
    }

    private func markImageToolOutcomeUnknownIfNeeded(
        runId: String,
        toolCall: UIMessagePart.Tool,
        outcome: String
    ) async -> ImageToolTerminalClaimResult {
        guard currentRunId == runId,
              imageToolDidStart else { return .failed }
        guard !imageToolTerminalClaimed else { return .alreadyClaimed }
        imageToolTerminalClaimed = true
        return await toolLedger.recordToolCallRecoveryTransition(
            runId: runId,
            toolCallId: toolCall.toolCallId,
            expected: .started,
            to: .outcomeUnknown,
            outcome: outcome
        ) ? .recorded : .failed
    }

    private func reconcileImageToolStartFailure(
        runId: String,
        toolCallId: String,
        outcome: String
    ) async {
        let closedStarted = await toolLedger.recordToolCallRecoveryTransition(
            runId: runId,
            toolCallId: toolCallId,
            expected: .started,
            to: .reconciled,
            outcome: outcome
        )
        if !closedStarted {
            _ = await toolLedger.recordToolCallRecoveryTransition(
                runId: runId,
                toolCallId: toolCallId,
                expected: .prepared,
                to: .reconciled,
                outcome: outcome
            )
        }
    }

    private func makeRunRequest(
        adapterProvider: any IOSAgentTextProvider,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        startedAt: Int64,
        inputDigest: String,
        conversationId: KotlinUuid?,
        initialMessages: [UIMessage],
        toolExposureBridge: IosToolExposureBridge,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?,
        citationTracker: IOSMemoryCitationTracker
    ) -> ChatRunKernelAdapter.RunRequest {
        let bindingsBox = UncheckedHostBindingsBox(bindings)
        let conversationBox = UncheckedHostConversationIdBox(conversationId)
        return ChatRunKernelAdapter.RunRequest(
            provider: adapterProvider,
            providerSetting: providerSetting,
            params: params,
            runId: runId,
            startedAt: startedAt,
            inputDigest: inputDigest,
            conversationId: conversationId,
            initialMessages: initialMessages,
            toolExposureBridge: toolExposureBridge,
            recipeCatalogSnapshot: recipeCatalogSnapshot,
            recipeCatalogRefresh: {
                await IOSDynamicToolRegistry.shared.refresh()
            },
            executionPolicy: runExecutionPolicy,
            maxToolResumeCount: dependencies.settingsStore.chatMaxToolResumeCount,
            drainSteer: {
                let boxed = await MainActor.run {
                    IOSMailboxDrainResult(values: bindingsBox.value.drainSteerQueue(conversationBox.value))
                }
                return boxed.values
            },
            mailboxDrain: {
                await Task { @MainActor in
                    IOSMailboxDrainResult(values: await bindingsBox.value.drainMailbox(conversationBox.value))
                }.value
            },
            citationTracker: citationTracker,
            prepareUploadMessages: { [weak self] messages in
                guard let self else { return messages }
                return try await self.prepareUploadMessages(
                    messages,
                    runId: runId,
                    provider: providerSetting,
                    params: params
                )
            },
            nestedToolRunner: nil,
            approvalDecider: { [weak self] prompt in
                guard let self else { return nil }
                return await self.approvalDecider(prompt, runId: runId)
            }
        )
    }

    private func runGenerativeUiRepairIfNeeded(
        runId: String,
        provider: ProviderSetting,
        params: TextGenerationParams,
        startedAt: Int64,
        inputDigest: String,
        conversationId: KotlinUuid?,
        bridge: IosToolExposureBridge,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?,
        tracker: IOSMemoryCitationTracker
    ) async {
        guard terminalWireName == AgentRunStatus.completed.wireName,
              !currentGenerativeUiFallbackAttempted,
              !toolRuntime.hasUnresolvedToolCall(in: bindings.getMessages()),
              let issue = IOSGenerativeUiRequestPolicy.widgetIssue(
                in: bindings.getMessages(),
                afterDisplayMessageCount: displayBaseline.count,
                requirement: currentGenerativeUiRequirement
              ) else { return }

        currentGenerativeUiFallbackAttempted = true
        currentGenerativeUiRetryIssue = issue
        let retryBase = IOSGenerativeUiRequestPolicy.retryBaseMessages(bindings.getMessages())
        projection.publishClosedAssistantMessages(retryBase)
        terminalWireName = nil

        let repairAdapter = makeAdapter(runId: runId)
        adapter = repairAdapter
        guard let adapterProvider = activeTextProvider else {
            projection.publishClosedAssistantMessages(
                IOSGenerativeUiRequestPolicy.terminalRepairFailureMessages(retryBase)
            )
            terminalWireName = AgentRunStatus.failed.wireName
            return
        }
        let request = makeRunRequest(
            adapterProvider: adapterProvider,
            providerSetting: provider,
            params: IOSGenerativeUiRequestPolicy.retryParams(params),
            runId: runId,
            startedAt: startedAt,
            inputDigest: inputDigest,
            conversationId: conversationId,
            initialMessages: retryBase,
            toolExposureBridge: bridge,
            recipeCatalogSnapshot: recipeCatalogSnapshot,
            citationTracker: tracker
        )
        _ = await repairAdapter.run(request)
        guard currentRunId == runId else { return }
        let hasUnresolvedToolCall = toolRuntime.hasUnresolvedToolCall(in: bindings.getMessages())
        guard terminalWireName == AgentRunStatus.completed.wireName,
              !hasUnresolvedToolCall else {
            projection.publishClosedAssistantMessages(
                IOSGenerativeUiRequestPolicy.terminalRepairFailureMessages(bindings.getMessages())
            )
            if terminalWireName == AgentRunStatus.completed.wireName,
               hasUnresolvedToolCall {
                terminalWireName = AgentRunStatus.failed.wireName
            }
            return
        }
        if IOSGenerativeUiRequestPolicy.widgetIssue(
            in: bindings.getMessages(),
            afterDisplayMessageCount: retryBase.count,
            requirement: currentGenerativeUiRequirement
        ) != nil {
            projection.publishClosedAssistantMessages(
                IOSGenerativeUiRequestPolicy.terminalRepairFailureMessages(
                    bindings.getMessages(),
                    afterDisplayMessageCount: retryBase.count
                )
            )
            // 用户明确要求的可视化仍未生成，保留原回答但终态必须如实失败。
            terminalWireName = AgentRunStatus.failed.wireName
        } else {
            projection.publishClosedAssistantMessages(
                IOSGenerativeUiRequestPolicy.terminalRepairSuccessMessages(bindings.getMessages())
            )
        }
    }

    // MARK: - cancel(CG-C cancel :1438-1581)

    func cancel() {
        cancel(cause: .user)
    }

    @discardableResult
    func cancel(runId expectedRunId: String) -> Bool {
        guard currentRunId == expectedRunId else { return false }
        cancel(cause: .user)
        return true
    }

    /// B4:入后台/租约到期按 `.backgroundInterruption` 取消(durable 终态
    /// interrupted,CG-C finishKeepAliveExpiration :1002-1011 同款)。
    func cancel(cause: CancellationCause) {
        guard let runId = currentRunId, cancelCause == nil, !didFinalizeTerminal else { return }
        // 图片结果已返回并开始写工具终态后即进入提交点；此时再把 UI 改写为
        // cancelled 会制造 Finished(completed) 与取消消息互相矛盾的快照。
        if activeImageToolCall != nil, imageToolTerminalClaimed { return }
        cancelCause = cause
        toolRuntime.discardPreparedThemeImport()
        let toolFailureReason: String
        switch cause {
        case .user:
            toolFailureReason = IOSAppLocalization.string(
                "User cancelled.",
                defaultValue: "User cancelled."
            )
        case .backgroundInterruption:
            toolFailureReason = IOSAppLocalization.string(
                "Generation interrupted by the system.",
                defaultValue: "Generation interrupted by the system."
            )
        }
        IOSChatBackgroundGenerationCoordinator.shared.discardDurableResponse(runId: runId)
        cancelRemoteDurableResponseIfNeeded()
        cancelBaseline = bindings.capturePersistMessagesBaseline(currentConversationIdForRun)
        if let activeImageToolCall {
            let wasExecuting = imageExecutionTask != nil
            imageExecutionTask?.cancel()
            var messages = bindings.getMessages()
            if toolRuntime.hasUnresolvedToolCall(in: messages) {
                messages = toolRuntime.messagesByFailingPendingToolCalls(
                    in: messages,
                    failureReason: toolFailureReason,
                    denied: true
                )
                bindings.setMessages(messages)
            }
            if imageToolDidStart {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let terminalClaim: ImageToolTerminalClaimResult
                    if wasExecuting {
                        terminalClaim = await self.markImageToolOutcomeUnknownIfNeeded(
                            runId: runId,
                            toolCall: activeImageToolCall,
                            outcome: "cancelled_during_execution"
                        )
                    } else {
                        terminalClaim = await self.recordImageToolTerminalIfNeeded(
                            runId: runId,
                            toolCall: activeImageToolCall,
                            outcome: "cancelled_before_execution",
                            resultPayload: nil
                        )
                    }
                    if terminalClaim == .failed {
                        await self.failImageToolDurability(runId: runId)
                        return
                    }
                    guard terminalClaim == .recorded else { return }
                    await self.finalizeTerminal(runId: runId)
                }
            }
            return
        }
        // 适配器已起跑:同步填充未决工具("User cancelled.")+ citation
        // remainder 折入 + 终态 cancelled 上报;preamble 期间则跳过(空
        // working 不得发布成 transcript),由 runTask 收口。
        if adapterDidStart {
            adapter?.cancel(failureReason: toolFailureReason)
        }
        // 审批等待中取消:放行决定器(返回 nil),适配器走 cancel 优先分支,
        // 不再写账本/副作用。
        approvalWaiter?.resume(returning: nil)
        approvalWaiter = nil
        pendingPrompt = nil
    }

    @discardableResult
    func handoffCurrentGenerationToBackground(
        conversationStore: IOSConversationStore?,
        honorKeepAliveLease: Bool = false
    ) -> Bool {
        guard let runId = currentRunId,
              cancelCause == nil,
              !hasPendingToolApproval else { return false }
        if detachDurableResponse(runId: runId) { return true }
        if honorKeepAliveLease {
            switch backgroundExecution.executionAssertion(for: runId) {
            case .uiOnly, .submitted, .adopted, .audio:
                pendingBackgroundConversationStore = conversationStore
                return false
            case .none:
                break
            }
        }
        guard canHandoffActiveTool,
              let handoff = currentBackgroundHandoff(),
              let conversationStore else {
            pendingBackgroundConversationStore = conversationStore
            return false
        }
        if let openAI = handoff.providerSetting as? ProviderSetting.OpenAI,
           IOSGrokWebProviderResolver.isGrokWebConfiguration(openAI) {
            return false
        }
        guard !(handoff.providerSetting is ProviderSetting.Google) else { return false }

        let didStart = backgroundExecution.transfer(runId) { [self] in
#if DEBUG
            if let override = backgroundStartOverrideForTesting {
                return override(handoff, conversationStore)
            }
#endif
            return IOSChatBackgroundGenerationCoordinator.shared.start(
                handoff: handoff,
                conversationStore: conversationStore,
                toolRuntime: toolRuntime,
                liveActivityController: dependencies.liveActivityController,
                saveMiniAppIfPresent: { [bindings] messages, conversationId in
                    bindings.saveMiniAppIfPresent(messages, conversationId)
                }
            )
        }
        guard didStart else { return false }

        adapter?.detachForBackgroundHandoff()
        runTask?.cancel()
        runTask = nil
        ChatStreamRecorder.shared.finish(runId: runId)
        clearRunIdentity()
        adapter = nil
        citationTracker = nil
        keepaliveHeld = false
        bindings.setContextCompactState(.idle)
        bindings.setIsLoading(false)
        projection.clearAllApprovals()
        bindings.bumpMessageRevision(.generationHandedOffToBackground, 1)
        return true
    }

    private func currentBackgroundHandoff() -> IOSChatBackgroundHandoff? {
        guard let handoff = backgroundHandoff else { return nil }
        return IOSChatBackgroundHandoff(
            runId: handoff.runId,
            startedAt: handoff.startedAt,
            inputDigest: handoff.inputDigest,
            conversationId: handoff.conversationId,
            providerId: handoff.providerId,
            providerSetting: handoff.providerSetting,
            params: handoff.params,
            uploadMessages: handoff.uploadMessages,
            displayMessages: bindings.getMessages(),
            mode: handoff.mode,
            responseId: handoff.responseId,
            responseSequenceNumber: handoff.responseSequenceNumber,
            generativeUiRequirement: handoff.generativeUiRequirement,
            generativeUiFallbackAttempted: handoff.generativeUiFallbackAttempted,
            fullToolNames: handoff.fullToolNames,
            dynamicToolSnapshot: handoff.dynamicToolSnapshot,
            executionPolicy: handoff.executionPolicy
        )
    }

    private func makeTextProvider(runId: String) -> any IOSAgentTextProvider {
        if let textProviderOverride { return textProviderOverride }
        let provider = ChatKernelDurableTextProvider(
            onCheckpoint: { [weak self] responseId, sequenceNumber in
                Task { @MainActor in
                    self?.recordDurableResponseCheckpoint(
                        runId: runId,
                        responseId: responseId,
                        sequenceNumber: sequenceNumber
                    )
                }
            },
            onDurableDisconnect: { [weak self] message in
                Task { @MainActor in
                    guard let self,
                          self.currentRunId == runId,
                          self.cancelCause == nil else { return }
                    if !self.detachDurableResponse(runId: runId) {
                        self.activeDurableTextProvider?.failLocalStream(message: message)
                    }
                }
            }
        )
        activeDurableTextProvider = provider
        return provider
    }

    private func recordDurableResponseCheckpoint(
        runId: String,
        responseId: String,
        sequenceNumber: Int64
    ) {
        guard currentRunId == runId,
              cancelCause == nil,
              var handoff = backgroundHandoff else { return }
        durableResponseCursor = (responseId, sequenceNumber)
        handoff.mode = .resumeResponse
        handoff.responseId = responseId
        handoff.responseSequenceNumber = sequenceNumber
        guard IOSChatBackgroundGenerationCoordinator.shared.checkpointDurableResponse(handoff) else {
            return
        }
        backgroundHandoff = handoff
        durableCheckpointPersisted = true
        if pendingBackgroundConversationStore != nil {
            _ = detachDurableResponse(runId: runId)
        }
    }

    @discardableResult
    private func detachDurableResponse(runId: String) -> Bool {
        guard currentRunId == runId,
              cancelCause == nil,
              durableCheckpointPersisted,
              canHandoffActiveTool,
              !hasPendingToolApproval else { return false }
        activeDurableTextProvider?.cancelLocalStream()
        adapter?.detachForBackgroundHandoff()
        runTask?.cancel()
        runTask = nil
        backgroundExecution.end(runId)
        ChatStreamRecorder.shared.finish(runId: runId)
        clearRunIdentity()
        adapter = nil
        citationTracker = nil
        activeTextProvider = nil
        activeDurableTextProvider = nil
        keepaliveHeld = false
        bindings.setContextCompactState(.idle)
        bindings.setIsLoading(false)
        projection.clearAllApprovals()
        bindings.bumpMessageRevision(.generationHandedOffToBackground, 1)
        IOSChatBackgroundGenerationCoordinator.shared.resumeDetachedResponsesIfNeeded()
        return true
    }

    private func cancelRemoteDurableResponseIfNeeded() {
        guard let cursor = durableResponseCursor,
              let handoff = backgroundHandoff,
              let openAI = handoff.providerSetting as? ProviderSetting.OpenAI else { return }
        activeDurableTextProvider?.cancelLocalStream()
        _ = try? OpenAIResponsesBackgroundTransport().cancelBackground(
            providerSetting: openAI,
            responseId: cursor.responseId,
            customHeaders: handoff.params.customHeaders,
            onComplete: {},
            onError: { _ in }
        )
    }

    // MARK: - 审批入口(CG-C :1819-1882 同款面)

    func approvePendingMemoryTool() {
        _ = resolvePendingApproval(decision: .approve, category: .memory)
    }

    func denyPendingMemoryTool() {
        _ = resolvePendingApproval(decision: .deny, category: .memory)
    }

    func approvePendingSearchTool() {
        _ = resolvePendingApproval(decision: .approve, category: .search)
    }

    func denyPendingSearchTool() {
        _ = resolvePendingApproval(decision: .deny, category: .search)
    }

    func approvePendingWebMountTool(requestId: String) {
        _ = resolvePendingApproval(decision: .approve, category: .webMount, requestId: requestId)
    }

    func denyPendingWebMountTool(requestId: String) {
        _ = resolvePendingApproval(decision: .deny, category: .webMount, requestId: requestId)
    }

    func approvePendingWorkspaceTool() {
        _ = resolvePendingApproval(decision: .approve, category: .workspace)
    }

    func denyPendingWorkspaceTool() {
        _ = resolvePendingApproval(decision: .deny, category: .workspace)
    }

    func approvePendingIshHandoffTool(
        requestId: String,
        requestRunId: String?,
        scope: IshToolApprovalScope = .once
    ) {
        let runId = currentRunId
        let conversationId = currentConversationIdForRun
        guard case .ish(let approvalRequest) = pendingPrompt,
              approvalRequest.runId == requestRunId else { return }
        guard resolvePendingApproval(
            decision: .approve,
            category: .ish,
            requestId: requestId
        ) else { return }

        let effectiveScope: IshToolApprovalScope = approvalRequest.mode == .amberShell ? .once : scope
        switch effectiveScope {
        case .once:
            break
        case .session:
            if let runId {
                toolRuntime.autoApproveIshForSession(
                    runId: runId,
                    conversationId: conversationId,
                    capabilityId: approvalRequest.capabilityId
                )
            }
        case .global:
            IOSLocalToolExecutor.setHighRiskAutoApproveEnabled(true)
            if let runId {
                toolRuntime.autoApproveIshForRun(runId)
            }
        }
    }

    func denyPendingIshHandoffTool(requestId: String, requestRunId: String?) {
        guard case .ish(let approvalRequest) = pendingPrompt,
              approvalRequest.runId == requestRunId else { return }
        _ = resolvePendingApproval(decision: .deny, category: .ish, requestId: requestId)
    }

    @discardableResult
    func approvePendingMcpTool(requestId: String? = nil) -> Bool {
        resolvePendingApproval(decision: .approve, category: .mcp, requestId: requestId)
    }

    @discardableResult
    func denyPendingMcpTool(requestId: String? = nil) -> Bool {
        resolvePendingApproval(decision: .deny, category: .mcp, requestId: requestId)
    }

    func approvePendingRecipeTool(requestId: String? = nil) {
        _ = resolvePendingApproval(decision: .approve, category: .recipe, requestId: requestId)
    }

    func denyPendingRecipeTool(requestId: String? = nil) {
        _ = resolvePendingApproval(decision: .deny, category: .recipe, requestId: requestId)
    }

    func approvePendingCouncilTool() {
        _ = resolvePendingApproval(decision: .approve, category: .council)
    }

    func denyPendingCouncilTool() {
        _ = resolvePendingApproval(decision: .deny, category: .council)
    }

    @discardableResult
    func answerPendingAskUser(_ answer: String) -> Bool {
        resolvePendingApproval(decision: .answer(answer), category: .askUser)
    }

    @discardableResult
    func skipPendingAskUser() -> Bool {
        answerPendingAskUser("")
    }

    @discardableResult
    func resolvePendingToolApprovalFromWatch(
        runId: String,
        requestId: String,
        allow: Bool
    ) -> Bool {
        guard currentRunId == runId,
              let prompt = pendingPrompt,
              Self.requestId(of: prompt) == requestId,
              Self.category(of: prompt) != .askUser else {
            return false
        }
        return resolvePendingApproval(
            decision: allow ? .approve : .deny,
            category: Self.category(of: prompt),
            requestId: requestId
        )
    }

    @discardableResult
    func answerPendingAskUserFromWatch(
        runId: String,
        requestId: String,
        answer: String
    ) -> Bool {
        guard currentRunId == runId,
              let prompt = pendingPrompt,
              case .askUser = prompt,
              Self.requestId(of: prompt) == requestId else {
            return false
        }
        return resolvePendingApproval(
            decision: .answer(answer),
            category: .askUser,
            requestId: requestId
        )
    }

    /// 类目 + requestId 核对(mcp/recipe 卡带 id,陈旧点击不消费)→ 清卡 →
    /// 恢复前奏(CG-C :4474-4475/:4598-4610:isLoading + keepalive +
    /// LiveActivity generating;deny 路径 CG-C 在 resumeAfterApproval 才做,
    /// 此处统一提前,净效果一致)→ 放行决定器。
    @discardableResult
    private func resolvePendingApproval(
        decision: ChatKernelApprovalDecision,
        category: ApprovalCategory,
        requestId: String? = nil
    ) -> Bool {
        guard let waiter = approvalWaiter,
              let prompt = pendingPrompt,
              let runId = currentRunId,
              Self.category(of: prompt) == category else { return false }
        if let requestId, Self.requestId(of: prompt) != requestId { return false }
        if case .webMount(let request) = prompt,
           let requestRunId = request.runId,
           requestRunId != runId { return false }
        if case .ish(let request) = prompt,
           let requestRunId = request.runId,
           requestRunId != runId { return false }
        projection.clearApproval(prompt)
        approvalWaiter = nil
        pendingPrompt = nil
        bindings.setIsLoading(true)
        if !keepaliveHeld {
            beginKeepAlive(runId: runId, subtitle: currentParams?.model.displayName ?? "")
        }
        bindings.startLiveActivity(
            runId,
            currentConversationIdForRun,
            AgentActivityPresentation.response(stage: .generating)
        )
        waiter.resume(returning: decision)
        return true
    }

    private static func category(of prompt: ChatToolApprovalPrompt) -> ApprovalCategory {
        switch prompt {
        case .memory: return .memory
        case .search: return .search
        case .webMount: return .webMount
        case .workspace: return .workspace
        case .ish: return .ish
        case .mcp: return .mcp
        case .council: return .council
        case .askUser: return .askUser
        case .recipe: return .recipe
        }
    }

    private static func requestId(of prompt: ChatToolApprovalPrompt) -> String? {
        switch prompt {
        case .memory(let request): return request.id
        case .search(let request): return request.id
        case .webMount(let request): return request.id
        case .workspace(let request): return request.id
        case .ish(let request): return request.id
        case .mcp(let request): return request.id
        case .council(let request): return request.id
        case .askUser(let request): return request.id
        case .recipe(let request): return request.id
        }
    }

    // MARK: - 适配器装配

    private func makeAdapter(runId: String) -> ChatRunKernelAdapter {
        var callbacks = ChatRunKernelAdapter.Callbacks()
        callbacks.onMessagesUpdated = { [weak self] messages in
            guard let self, self.currentRunId == runId else { return }
            self.activeToolExecutionName = nil
            self.activeToolEffectClass = nil
            // 权威快照落地:刚完成的 assistant 消息已在其中(与 provisional
            // 同 id),投影状态必须丢弃——否则迟到的节流连拍会把旧增量盖回去。
            self.projection.publishAuthoritativeMessages(messages)
        }
        callbacks.onAwaitingPermission = { [weak self] toolCallId in
            self?.pendingApprovalToolCallId = toolCallId
        }
        callbacks.onRunResumed = { [weak self] in
            guard let self, self.currentRunId == runId else { return false }
            let didResume = await self.bindings.resumeRunAfterPermission(runId)
            if !didResume {
                // CG-C claimRunAfterPermission :4310-4325:认领失败 → 账本由
                // 适配器补 Finished(not_executed_permission_claim_failed),
                // 这里备好用户向错误串,failed 终态呈现。
                self.lastFailureMessage = IOSAppLocalization.string(
                    "无法恢复待确认任务，请重试。",
                    defaultValue: "无法恢复待确认任务，请重试。"
                )
            }
            return didResume
        }
        callbacks.onForegroundYield = { [weak self] in
            guard let self, self.currentRunId == runId else { return }
            self.didYieldForeground = true
        }
        callbacks.onRunTerminal = { [weak self] status in
            guard let self, self.currentRunId == runId else { return }
            self.terminalWireName = status
        }
        callbacks.onProviderFailure = { [weak self] message in
            guard let self, self.currentRunId == runId else { return }
            self.lastFailureMessage = message
        }
        callbacks.onToolOutcomeUnknown = { [weak self] signal in
            guard let self, self.currentRunId == runId else { return }
            self.toolOutcomeUnknownSignal = signal
        }
        callbacks.onAssistantTurnStarted = { [weak self] in
            guard let self, self.currentRunId == runId else { return }
            self.didReportFirstDeltaThisRound = false
            self.streamClock.resetRound()
            self.bindings.setMessages(
                self.bindings.getMessages().clearingLastAssistantGenerationDuration()
            )
            self.projection.discardProvisionalAssistant()
            self.backgroundExecution.updateProgress(
                runId,
                completed: 1,
                total: 4,
                subtitle: IOSAppLocalization.string("正在生成回复", defaultValue: "正在生成回复")
            )
            // 审批恢复(含 recipe 再暂停恢复)后首轮:keepalive 已还在暂停时
            // 归还,这里拿回;LiveActivity/Watch 回到 generating(CG-C
            // continueAfterToolResult :3657-3668 同款)。
            if !self.keepaliveHeld {
                self.beginKeepAlive(runId: runId, subtitle: self.currentParams?.model.displayName ?? "")
                let generating = AgentActivityPresentation.response(stage: .generating)
                WatchTaskCoordinator.shared.publish(
                    runId: runId,
                    conversationId: self.currentConversationIdForRun?.toHexDashString(),
                    presentation: generating
                )
                Task { @MainActor [weak self] in
                    guard let self, self.currentRunId == runId else { return }
                    await self.dependencies.liveActivityController.update(
                        runId: runId,
                        presentation: generating,
                        force: true
                    )
                }
            }
        }
        callbacks.onToolExecutionStarted = { [weak self] toolName, input in
            guard let self, self.currentRunId == runId else { return }
            self.activeToolExecutionName = toolName
            self.activeToolEffectClass = IOSToolEffectClassMapping.forToolName(toolName, input: input)
            self.backgroundExecution.updateProgress(
                runId,
                completed: 3,
                total: 4,
                subtitle: IOSAppLocalization.string("正在执行工具", defaultValue: "正在执行工具")
            )
            let presentation = AgentActivityPresentation.runningTool(toolName: toolName)
            WatchTaskCoordinator.shared.publish(
                runId: runId,
                conversationId: self.currentConversationIdForRun?.toHexDashString(),
                presentation: presentation
            )
            Task { @MainActor [weak self] in
                guard let self, self.currentRunId == runId else { return }
                await self.dependencies.liveActivityController.update(
                    runId: runId,
                    presentation: presentation,
                    force: true
                )
            }
        }
        callbacks.onAssistantStage = { [weak self] stage in
            guard let self, self.currentRunId == runId else { return }
            let presentation = AgentActivityPresentation.response(stage: stage)
            WatchTaskCoordinator.shared.publish(
                runId: runId,
                conversationId: self.currentConversationIdForRun?.toHexDashString(),
                presentation: presentation
            )
            Task { @MainActor [weak self] in
                guard let self, self.currentRunId == runId else { return }
                await self.dependencies.liveActivityController.update(
                    runId: runId,
                    presentation: presentation
                )
            }
        }
        callbacks.onAssistantFirstVisibleDelta = { [weak self] in
            // 文本与推理都沿 CG-C chunkHasVisibleContent 口径计为可见内容;
            // 适配器已按真实模型轮次只转递首次事件。
            guard let self,
                  self.currentRunId == runId,
                  !self.didFinalizeTerminal else { return }
            self.streamClock.noteVisibleDelta()
            if !self.didReportFirstDeltaThisRound {
                self.didReportFirstDeltaThisRound = true
                self.backgroundExecution.updateProgress(
                    runId,
                    completed: 2,
                    total: 4,
                    subtitle: IOSAppLocalization.string("正在接收回复", defaultValue: "正在接收回复")
                )
            }
        }
        callbacks.onAssistantMessageSnapshot = { [weak self] message in
            guard let self, self.currentRunId == runId else { return }
            self.projection.publishProvisionalAssistant(message)
        }
        return ChatRunKernelAdapter(runtime: toolRuntime, ledger: toolLedger, callbacks: callbacks)
    }

    // MARK: - 审批决定器(CG-C pauseForApproval :3798-3873)

    /// 暂停序列全在决定器内(它是 async 的,适配器的同步回调点只够记录)。
    /// 返回 nil 的两种情形:run 已被替换/取消;暂停持久化失败——后者已
    /// 备好 lastFailureMessage,适配器以 failed 结束后 failed 终态呈现。
    private func approvalDecider(
        _ prompt: ChatToolApprovalPrompt,
        runId: String
    ) async -> ChatKernelApprovalDecision? {
        guard currentRunId == runId, cancelCause == nil else { return nil }
        let conversationId = currentConversationIdForRun
        let toolCallId = pendingApprovalToolCallId ?? ""
        // CG-C :3798-3799:暂停快照即适配器刚发布的 working,这里只补
        // awaitingToolApproval 的 revision 语义。
        bindings.bumpMessageRevision(.awaitingToolApproval, 1)
        let writeBaseline = bindings.capturePersistMessagesBaseline(conversationId)
        let didMark = await bindings.markRunAwaitingPermission(runId, toolCallId)
        guard currentRunId == runId, cancelCause == nil else { return nil }
        guard didMark else {
            await pauseStorageFailed(rawMessage: IOSAppLocalization.string(
                "无法保存待确认恢复信息，请重试。",
                defaultValue: "无法保存待确认恢复信息，请重试。"
            ))
            return nil
        }
        // 脱敏快照持久化(CG-C :3817-3824):审批中快照不含敏感配置。
        let approvalMessages = IOSProviderConfigToolCatalog.redactedApprovalMessages(bindings.getMessages())
        let didPersist = await bindings.persistMessagesSnapshot(approvalMessages, conversationId, writeBaseline)
        guard currentRunId == runId, cancelCause == nil else { return nil }
        guard didPersist else {
            await pauseStorageFailed(rawMessage: IOSAppLocalization.string(
                "无法保存待确认状态，请检查存储空间后重试。",
                defaultValue: "无法保存待确认状态，请检查存储空间后重试。"
            ))
            return nil
        }

        // 等人点按钮不需要后台执行权(CG-C :3844-3846);可见 baseMessages
        // 已耐久保存后才还租约。
        backgroundExecution.end(runId)
        keepaliveHeld = false
        await dependencies.liveActivityController.update(
            runId: runId,
            presentation: .waitingForUser(kind: prompt.activityKind),
            force: true
        )
        guard currentRunId == runId, cancelCause == nil else { return nil }
        bindings.setIsLoading(false)
        if case .askUser(let request) = prompt {
            WatchTaskCoordinator.shared.publishAskUser(
                runId: runId,
                conversationId: conversationId?.toHexDashString(),
                request: WatchAskUserRequest(
                    id: request.id,
                    question: request.question,
                    options: request.options
                )
            )
        } else {
            WatchTaskCoordinator.shared.publishWaitingApproval(
                runId: runId,
                conversationId: conversationId?.toHexDashString(),
                prompt: prompt
            )
        }
        projection.publishApproval(prompt)

        pendingPrompt = prompt
        let decision = await withCheckedContinuation {
            (continuation: CheckedContinuation<ChatKernelApprovalDecision?, Never>) in
            approvalWaiter = continuation
        }
        approvalWaiter = nil
        pendingPrompt = nil
        return decision
    }

    /// 暂停持久化失败(CG-C :3805-3816/:3826-3837):清卡 + 备好错误串;
    /// 适配器收到 nil 后以 failed 收口,failed 终态统一呈现。
    private func pauseStorageFailed(rawMessage: String) async {
        projection.clearAllApprovals()
        lastFailureMessage = rawMessage
    }

    // MARK: - 逐轮上传准备(CG-C prepareAndStartStreaming :1960-2050)

    private var mcpEnabledForRun: Bool {
        let masterEnabled = runExecutionPolicy?.mcpEnabled
            ?? dependencies.sharedSettings.isCapabilityGateEnabled(.mcp)
        guard masterEnabled else { return false }
        guard let policy = runExecutionPolicy,
              let capability = IOSCapabilityRegistry.capabilities.first(where: {
                  $0.id == "ios.mcp.tool_call"
              }) else {
            return ChatGenerationSupport.isMcpNetworkAllowed(
                executor: dependencies.localToolExecutor
            )
        }
        return policy.policy(for: capability) != .disabled
    }

    private func messagesByInjectingRuntimeContext(_ messages: [UIMessage]) -> [UIMessage] {
        bindings.messagesByInjectingRuntimeContextForRun?(messages, mcpEnabledForRun)
            ?? bindings.messagesByInjectingRuntimeContext(messages)
    }

    /// 每轮上传前的完整准备。压缩失败抛错,沿引擎
    /// 通用 catch 以 providerFailure 收口(CG-C 压缩失败 → presentStreamError
    /// 语义),错误串带「上下文压缩失败：」前缀。
    private func prepareUploadMessages(
        _ messages: [UIMessage],
        runId: String,
        provider: ProviderSetting,
        params: TextGenerationParams
    ) async throws -> [UIMessage] {
        guard currentRunId == runId else { return messages }
        let settings = runSettings ?? dependencies.sharedSettings.snapshot
        let conversationId = currentConversationIdForRun
        let effectiveParams = params.replacingTools(
            currentToolExposureBridge?.visibleTools() ?? params.tools
        )
        let plan = IOSGenerativeUiRequestPolicy.plan(
            setting: settings.agentRuntime.generativeUi,
            messages: messages,
            params: effectiveParams,
            suppressForMiniApp: settings.agentRuntime.miniApp.enabled
                && ChatRuntimeContextBuilder.miniAppTurnContext(in: messages) != nil
        )
        if !currentGenerativeUiFallbackAttempted {
            currentGenerativeUiRequirement = plan.requirement
        }
        let requestMessages: [UIMessage]
        if let issue = currentGenerativeUiRetryIssue {
            requestMessages = IOSGenerativeUiRequestPolicy.retryMessages(
                plan.uploadMessages,
                requirement: currentGenerativeUiRequirement,
                issue: issue
            )
        } else {
            requestMessages = plan.uploadMessages
        }

        let runtimeBaseline = messagesByInjectingRuntimeContext(requestMessages)
        let runtimeOverheadTokens = max(
            IOSContextCompactionCoordinator.estimatedTokensForRequest(runtimeBaseline) -
                IOSContextCompactionCoordinator.estimatedTokensForRequest(requestMessages),
            0
        )

        let preparedUploadMessages: [UIMessage]
        do {
            preparedUploadMessages = try await IOSContextCompactionCoordinator.shared.prepareMessagesForRequest(
                uploadMessages: requestMessages,
                conversationId: conversationId,
                settings: settings,
                params: effectiveParams,
                fallbackProvider: provider,
                promptOverheadTokens: runtimeOverheadTokens,
                onEvent: { [weak self] event in
                    guard let self,
                          ChatContextCompactEventRouter.shouldApply(
                            event: event,
                            eventRunId: runId,
                            currentRunId: self.currentRunId
                          ) else { return }
                    self.applyCompactEvent(event)
                }
            )
        } catch {
            if currentRunId == runId {
                applyCompactEvent(.failed(message: (error as NSError).localizedDescription))
            }
            throw Self.uploadPrepError(IOSAppLocalization.formatted(
                "上下文压缩失败：%@",
                defaultValue: "上下文压缩失败：%@",
                arguments: [(error as NSError).localizedDescription]
            ))
        }
        guard currentRunId == runId else { return messages }
        let promptedUploadMessages = Self.messagesByInjectingImageGenerationPromptIfNeeded(
            preparedUploadMessages,
            params: effectiveParams
        )
        // 每轮组装前刷新编排链接缓存(CG-C :2022-2024)。
        await bindings.refreshOrchestrationLinks()
        let runtimePreparedMessages = messagesByInjectingRuntimeContext(promptedUploadMessages)
        let selectedMemoryIds = bindings.memoryRecordIdsForRuntimeContext(promptedUploadMessages)
        let finalizedUploadMessages: [UIMessage]
        do {
            finalizedUploadMessages = try IOSContextCompactionCoordinator.shared.finalizedMessagesForRequest(
                runtimePreparedMessages,
                settings: settings,
                params: effectiveParams
            )
        } catch {
            if currentRunId == runId {
                applyCompactEvent(.failed(message: (error as NSError).localizedDescription))
            }
            throw Self.uploadPrepError(IOSAppLocalization.formatted(
                "上下文压缩失败：%@",
                defaultValue: "上下文压缩失败：%@",
                arguments: [(error as NSError).localizedDescription]
            ))
        }
        let finalUploadMessages = ChatRuntimeContextBuilder.coalescingSystemMessages(finalizedUploadMessages)
        // 召回标记(P2-b):不 force,去抖生效(CG-C :2049-2050)。
        bindings.recordMemoryUsage(selectedMemoryIds, false)
        refreshBackgroundHandoff(
            runId: runId,
            providerSetting: provider,
            params: effectiveParams,
            uploadMessages: finalUploadMessages
        )
        return finalUploadMessages
    }

    private func refreshBackgroundHandoff(
        runId: String,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        uploadMessages: [UIMessage]
    ) {
        guard currentRunId == runId,
              let conversationId = currentConversationIdForRun else {
            backgroundHandoff = nil
            return
        }
        let dynamicSnapshot = currentDynamicToolSnapshot
        let backgroundDynamicNames = Set(
            dynamicSnapshot?.backgroundEligibleDescriptors.map(\.toolId) ?? []
        )
        let backgroundVisibleTools = params.tools.filter { tool in
            !IOSDynamicToolRegistry.isDynamicWorkflowToolName(tool.name)
                || backgroundDynamicNames.contains(tool.name)
        }
        backgroundHandoff = IOSChatBackgroundHandoff(
            runId: runId,
            startedAt: currentStartedAt,
            inputDigest: currentInputDigest,
            conversationId: conversationId,
            providerId: providerSetting.id.toHexDashString(),
            providerSetting: providerSetting,
            params: params.replacingTools(backgroundVisibleTools),
            uploadMessages: uploadMessages,
            displayMessages: bindings.getMessages(),
            mode: .continueModel,
            generativeUiRequirement: currentGenerativeUiRequirement,
            generativeUiFallbackAttempted: currentGenerativeUiFallbackAttempted,
            fullToolNames: (currentToolExposureBridge?.fullToolDeclarations().map(\.name) ?? [])
                .filter {
                    !IOSDynamicToolRegistry.isDynamicWorkflowToolName($0)
                        || backgroundDynamicNames.contains($0)
                },
            dynamicToolSnapshot: dynamicSnapshot,
            executionPolicy: runExecutionPolicy
        )
    }

    private static func uploadPrepError(_ message: String) -> NSError {
        NSError(
            domain: "AmberAgent.ChatKernelRunHost",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// CG-C :2098-2118 同款:generate_image 在目录时前置路由指引系统消息。
    private static func messagesByInjectingImageGenerationPromptIfNeeded(
        _ messages: [UIMessage],
        params: TextGenerationParams
    ) -> [UIMessage] {
        guard params.tools.contains(where: { $0.name == "generate_image" }) else {
            return messages
        }
        let prompt = ChatImageGenerationReference.routingGuidancePrompt
        let systemMessage = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.system,
            parts: [UIMessagePart.Text(text: prompt, metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        return [systemMessage] + messages
    }

    /// CG-C applyCompactEvent :2067-2096 同款映射。
    private func applyCompactEvent(_ event: IOSContextCompactionEvent) {
        switch event {
        case .planning:
            bindings.setContextCompactState(ChatContextCompactState(status: .planning, summary: "", updatedAt: Date()))
        case .compacting:
            bindings.setContextCompactState(ChatContextCompactState(status: .compacting, summary: "", updatedAt: Date()))
        case .completed(let summary):
            bindings.setContextCompactState(ChatContextCompactState(status: .completed, summary: summary, updatedAt: Date()))
        case .failed(let message):
            bindings.setContextCompactState(ChatContextCompactState(status: .failed, summary: message, updatedAt: Date()))
        case .idle:
            bindings.setContextCompactState(.idle)
        }
    }

    // MARK: - 终态收口

    private func preambleFailed(rawMessage: String, modelId: String, runId: String) async {
        guard currentRunId == runId, !didFinalizeTerminal else { return }
        didFinalizeTerminal = true
        lastFailureMessage = rawMessage
        await failedTerminal(runId: runId)
    }

    private func finalizeTerminal(runId: String) async {
        guard currentRunId == runId, !didFinalizeTerminal else { return }
        didFinalizeTerminal = true
        if cancelCause != nil {
            await cancelledTerminal(runId: runId)
            return
        }
        switch terminalWireName {
        case AgentRunStatus.completed.wireName:
            await completedTerminal(runId: runId)
        case AgentRunStatus.outcomeUnknown.wireName:
            await outcomeUnknownTerminal(runId: runId)
        case AgentRunStatus.recoveryPending.wireName:
            await failedTerminal(runId: runId, requiresRecovery: true)
        default:
            await failedTerminal(runId: runId)
        }
    }

    private func outcomeUnknownTerminal(runId: String) async {
        projection.discardProvisionalAssistant()
        let startedAt = currentStartedAt
        let inputDigest = currentInputDigest
        let conversationId = currentConversationIdForRun
        let conversationHex = conversationId?.toHexDashString()
        let finalMessages = bindings.getMessages()
        let didPersist = await bindings.persistMessages(conversationId)
        let didRecordRun = await bindings.recordRun(
            runId,
            startedAt,
            didPersist ? .outcomeUnknown : .recoveryPending,
            inputDigest,
            conversationHex,
            nil
        )
        guard didRecordRun else {
            releaseLocalRunAfterTerminalRecordFailure(runId: runId)
            return
        }
        if didPersist, let conversationHex {
            if let signal = toolOutcomeUnknownSignal {
                let descriptor = IOSToolOutcomeUnknownDescriptor(
                    runId: runId,
                    conversationId: conversationHex,
                    toolCallId: signal.toolCallId,
                    toolName: signal.toolName
                )
                bindings.setToolOutcomeUnknown(descriptor)
                _ = WatchTaskCoordinator.shared.publishOutcomeUnknown(descriptor)
            } else {
                _ = WatchTaskCoordinator.shared.publishOutcomeUnknown(
                    runId: runId,
                    conversationId: conversationHex
                )
            }
        } else {
            WatchTaskCoordinator.shared.publish(
                runId: runId,
                conversationId: conversationHex,
                presentation: .failed(),
                summary: IOSAppLocalization.string(
                    didPersist
                        ? "操作结果待核实，但没有可打开的 iPhone 对话。"
                        : "操作结果尚未保存，请在 iPhone 恢复。",
                    defaultValue: didPersist
                        ? "操作结果待核实，但没有可打开的 iPhone 对话。"
                        : "操作结果尚未保存，请在 iPhone 恢复。"
                )
            )
        }
        await dependencies.liveActivityController.end(runId: runId, presentation: .failed())
        bindings.setMessages(finalMessages)
        teardownRun(runId: runId, terminalEvent: .generationFailed)
    }

    /// completed(CG-C handleCompletedStream 正常分支 :2732-2797 +
    /// 空回复分支 :2685-2730)。
    private func completedTerminal(runId: String) async {
        projection.discardProvisionalAssistant()
        let startedAt = currentStartedAt
        let inputDigest = currentInputDigest
        let conversationId = currentConversationIdForRun
        let conversationHex = conversationId?.toHexDashString()
        var final = bindings.getMessages()
        // citation 使用标记:remainder 已由引擎逐段折进 transcript;这里记
        // memory 使用(force:true,引用是模型信号,CG-C :2464-2466 同款)。
        if let tracker = citationTracker {
            let ids = tracker.citationIds
            if !ids.isEmpty {
                bindings.recordMemoryUsage(ids.sorted(), true)
            }
        }

        // 空回复检测(CG-C :2685-2730)。
        if ChatGenerationSupport.isEmptyAssistantResponse(final) {
            let miniAppExpected = ChatRuntimeContextBuilder.miniAppTurnContext(in: displayBaseline) != nil
            final.append(miniAppExpected
                ? ChatGenerationSupport.emptyMiniAppResponseNotice()
                : ChatGenerationSupport.emptyResponseNotice())
            bindings.setMessages(final)
            bindings.bumpMessageRevision(.toolResultAppended, 1)
            let didPersist = await bindings.persistMessages(conversationId)
            if didPersist {
                await IOSRunRecovery.reconcilePersistedToolResults(runId: runId)
            }
            let succeeded = didPersist && !miniAppExpected
            let didRecordRun = await bindings.recordRun(
                runId, startedAt,
                didPersist ? (miniAppExpected ? .failed : .completed) : .recoveryPending,
                inputDigest, conversationHex, nil
            )
            guard didRecordRun else {
                releaseLocalRunAfterTerminalRecordFailure(runId: runId)
                return
            }
            if succeeded {
                WatchTaskCoordinator.shared.publishCompleted(runId: runId, conversationId: conversationHex, summary: nil)
            } else {
                WatchTaskCoordinator.shared.publish(
                    runId: runId,
                    conversationId: conversationHex,
                    presentation: .failed(),
                    summary: miniAppExpected && didPersist
                        ? IOSAppLocalization.string(
                            "小应用生成失败：模型没有返回任何内容。",
                            defaultValue: "小应用生成失败：模型没有返回任何内容。"
                        )
                        : IOSAppLocalization.string(
                            "回复已生成，但最终结果保存失败。",
                            defaultValue: "回复已生成，但最终结果保存失败。"
                        )
                )
            }
            await dependencies.liveActivityController.end(
                runId: runId,
                presentation: succeeded ? .completed() : .failed()
            )
            teardownRun(runId: runId, terminalEvent: succeeded ? .generationCompleted : .generationFailed)
            if succeeded {
                bindings.generationSucceeded()
            }
            return
        }

        // miniApp 输出事务(CG-C :2732-2762)。
        var finalSnapshot = final
        let miniAppApplication = bindings.saveMiniAppIfPresent(final, conversationId)
        if let miniAppApplication {
            finalSnapshot = miniAppApplication.messages
            bindings.setMessages(finalSnapshot)
            bindings.bumpMessageRevision(.toolResultAppended, 1)
        }

        let summary = ChatGenerationSupport.watchSummary(from: finalSnapshot)
        let didPersist = await bindings.persistMessages(conversationId)
        if didPersist {
            await IOSRunRecovery.reconcilePersistedToolResults(runId: runId)
        }
        let miniAppFailed = miniAppApplication?.outcome == .failed
        if !didPersist, let miniAppApplication {
            if miniAppApplication.rollback() {
                bindings.setMessages(miniAppApplication.rollbackMessages)
                bindings.bumpMessageRevision(.toolResultAppended, 1)
            } else {
                NSLog("[AmberChat] MiniApp rollback skipped because its persisted state changed")
            }
        }
        if didPersist, let miniAppApplication, !miniAppApplication.commit() {
            NSLog("[AmberChat] MiniApp transaction commit remains pending for cold-start reconciliation")
        }
        if didPersist,
           let workspaceFailure = miniAppApplication?.syncWorkspaceAfterConversationPersistence() {
            finalSnapshot = workspaceFailure.messages
            bindings.setMessages(finalSnapshot)
            bindings.bumpMessageRevision(.toolResultAppended, 1)
            _ = await bindings.persistMessages(conversationId)
        }
        let didRecordRun = await bindings.recordRun(
            runId, startedAt,
            didPersist ? (miniAppFailed ? .failed : .completed) : .recoveryPending,
            inputDigest, conversationHex, nil
        )
        guard didRecordRun else {
            releaseLocalRunAfterTerminalRecordFailure(runId: runId)
            return
        }
        if didPersist, !miniAppFailed {
            WatchTaskCoordinator.shared.publishCompleted(
                runId: runId,
                conversationId: conversationHex,
                summary: summary,
                resultTitle: miniAppApplication?.resultTitle
            )
        } else {
            WatchTaskCoordinator.shared.publish(
                runId: runId,
                conversationId: conversationHex,
                presentation: .failed(),
                summary: miniAppFailed && didPersist
                    ? IOSAppLocalization.string(
                        "小应用生成未完成，错误详情已保存在会话中。",
                        defaultValue: "小应用生成未完成，错误详情已保存在会话中。"
                    )
                    : IOSAppLocalization.string(
                        "回复已生成，但最终结果保存失败。",
                        defaultValue: "回复已生成，但最终结果保存失败。"
                    )
            )
        }
        await dependencies.liveActivityController.end(
            runId: runId,
            presentation: didPersist && !miniAppFailed ? .completed() : .failed()
        )
        if didPersist, !miniAppFailed, let conversationId {
            bindings.scheduleMemoryExtraction(conversationId, displayBaseline, finalSnapshot)
        }
        teardownRun(
            runId: runId,
            terminalEvent: didPersist && !miniAppFailed ? .generationCompleted : .generationFailed
        )
        if didPersist && !miniAppFailed {
            bindings.generationSucceeded()
        }
    }

    /// failed(CG-C presentStreamError :2483-2533;截断终态由适配器 A4 分支
    /// 追加过输出上限提示,这里不再加泡,对齐 completeTruncatedStream
    /// :2802-2843 的 Watch/LiveActivity 形状)。
    private func failedTerminal(runId: String, requiresRecovery: Bool = false) async {
        projection.discardProvisionalAssistant()
        let startedAt = currentStartedAt
        let inputDigest = currentInputDigest
        let conversationId = currentConversationIdForRun
        let conversationHex = conversationId?.toHexDashString()
        var updated = bindings.getMessages()
        var watchSummary: String? = ChatGenerationSupport.watchSummary(from: updated)

        if let rawMessage = lastFailureMessage {
            let userFacing = bindings.userFacingGenerationError(
                rawMessage,
                currentParams?.model.modelId ?? ""
            )
            if toolRuntime.hasUnresolvedToolCall(in: updated) {
                updated = toolRuntime.messagesByFailingPendingToolCalls(
                    in: updated,
                    failureReason: IOSAppLocalization.string(
                        "Generation failed before the tool call completed.",
                        defaultValue: "Generation failed before the tool call completed."
                    )
                )
            }
            // 引擎在 provider 失败时已在尾部追加 "[engine] provider error: …"
            // 占位泡——升级为 CG-C 同款用户向错误泡(保留位置/id);没有则追加。
            if let lastIndex = updated.indices.last,
               updated[lastIndex].role == MessageRole.assistant,
               let text = updated[lastIndex].parts.first as? UIMessagePart.Text,
               text.text.hasPrefix("[engine] provider error:") {
                let last = updated[lastIndex]
                updated[lastIndex] = UIMessage(
                    id: last.id,
                    role: MessageRole.assistant,
                    parts: [MessageKt.localGenerationErrorTextPart(text: userFacing)],
                    annotations: last.annotations,
                    createdAt: last.createdAt,
                    finishedAt: chatNowLocalDateTime(),
                    modelId: last.modelId,
                    usage: last.usage,
                    translation: last.translation
                )
            } else {
                updated.append(UIMessage(
                    id: KotlinUuid.companion.random(),
                    role: MessageRole.assistant,
                    parts: [MessageKt.localGenerationErrorTextPart(text: userFacing)],
                    annotations: [],
                    createdAt: chatNowLocalDateTime(),
                    finishedAt: chatNowLocalDateTime(),
                    modelId: nil,
                    usage: nil,
                    translation: nil
                ))
            }
            bindings.setMessages(updated)
            watchSummary = WatchTaskText.clipped(userFacing, maxLength: 200)
        }

        let didPersist = await bindings.persistMessages(conversationId)
        if didPersist {
            await IOSRunRecovery.reconcilePersistedToolResults(runId: runId)
        }
        let didRecordRun = await bindings.recordRun(
            runId, startedAt,
            didPersist && !requiresRecovery ? .failed : .recoveryPending,
            inputDigest, conversationHex, nil
        )
        guard didRecordRun else {
            releaseLocalRunAfterTerminalRecordFailure(runId: runId)
            return
        }
        let currentRunMessages = updated.dropFirst(min(displayBaseline.count, updated.count))
        let retryableFailure = didPersist
            && !requiresRecovery
            && !currentRunMessages.contains { message in
                message.parts.contains { $0 is UIMessagePart.Tool }
            }
        let failurePresentation = AgentActivityPresentation.failed(
            retryable: retryableFailure
        )
        AgentActivityRetryEligibilityStore.shared.setEligible(
            retryableFailure,
            runId: runId,
            conversationId: conversationHex
        )
        WatchTaskCoordinator.shared.publish(
            runId: runId,
            conversationId: conversationHex,
            presentation: failurePresentation,
            summary: watchSummary
        )
        await dependencies.liveActivityController.end(
            runId: runId,
            presentation: failurePresentation
        )
        if !didPersist {
            print("[AmberChat] Failed to persist kernel failure terminal run=\(runId)")
        }
        teardownRun(runId: runId, terminalEvent: .generationFailed)
    }

    /// cancelled(CG-C cancel 尾 :1501-1581):取消填充/快照已由适配器同步
    /// 发布;这里补 stamp、持久化、durable 终态与收尾。注意与 finishStreaming
    /// 尾的差异:恢复 steer leftover 进 composer,不走 handleSteerQueueAtTerminal,
    /// 也不 generationSucceeded。
    private func cancelledTerminal(runId: String) async {
        projection.discardProvisionalAssistant()
        let cause = cancelCause ?? .user
        let startedAt = currentStartedAt
        let inputDigest = currentInputDigest
        let conversationId = currentConversationIdForRun
        let conversationHex = conversationId?.toHexDashString()

        var messages = bindings.getMessages()
        // preamble 取消时适配器未起跑,tracker 还没被 flush 过;已起跑时
        // adapter.cancel() 已把 remainder 折进填充,这里 finish() 幂等返回空。
        if let tracker = citationTracker {
            let remainder = tracker.finish()
            if !remainder.isEmpty {
                messages = IOSMemoryCitationTracker.appendingCitationRemainder(remainder, to: messages)
            }
            let ids = tracker.citationIds
            if !ids.isEmpty {
                bindings.recordMemoryUsage(ids.sorted(), true)
            }
        }
        messages = messages.applyingLastAssistantGenerationDuration(streamClock.duration())
        bindings.setMessages(messages)
        ChatStreamRecorder.shared.finish(runId: runId)
        projection.clearAllApprovals()
        bindings.setIsLoading(false)
        bindings.setContextCompactState(.idle)
        bindings.restoreSteerQueueLeftover(conversationId)
        bindings.bumpMessageRevision(.generationCancelled, 1)
        // 系统 continued-processing 立即掐掉(CG-C :1539-1542);持久化完成前
        // 保留 UIKit 短窗,下方 end 统一归还。
        backgroundExecution.abandonSystemAssertion(runId)
        keepaliveHeld = false

        let baseline = cancelBaseline ?? bindings.capturePersistMessagesBaseline(conversationId)
        let didPersist = await bindings.persistMessagesSnapshot(messages, conversationId, baseline)
        if didPersist {
            await IOSRunRecovery.reconcilePersistedToolResults(runId: runId)
        }
        let didRecordRun = await bindings.recordRun(
            runId, startedAt,
            didPersist ? cause.durableStatus : .recoveryPending,
            inputDigest, conversationHex, nil
        )
        guard didRecordRun else {
            releaseLocalRunAfterTerminalRecordFailure(runId: runId)
            return
        }
        let terminalPresentation: AgentActivityPresentation
        let terminalSummary: String?
        if !didPersist {
            terminalPresentation = .failed()
            terminalSummary = IOSAppLocalization.string(
                "已停止生成，但最终状态保存失败。",
                defaultValue: "已停止生成，但最终状态保存失败。"
            )
        } else {
            switch cause {
            case .user:
                terminalPresentation = .cancelled()
                terminalSummary = nil
            case .backgroundInterruption:
                terminalPresentation = .failed()
                terminalSummary = IOSAppLocalization.string(
                    "后台生成被系统中断，可以重试。",
                    defaultValue: "后台生成被系统中断，可以重试。"
                )
            }
        }
        WatchTaskCoordinator.shared.publish(
            runId: runId,
            conversationId: conversationHex,
            presentation: terminalPresentation,
            summary: terminalSummary
        )
        await dependencies.liveActivityController.end(
            runId: runId,
            presentation: terminalPresentation
        )
        backgroundExecution.end(runId)
        // P1-c 终态回传(CG-C :1570-1579 同款;服务按 runId 幂等去重)。
        let terminalMessages = messages
        let terminalConversationId = conversationId
        IOSWebMountController.shared.releaseAgentOwnership(runId: runId)
        clearRunIdentity()
        adapter = nil
        citationTracker = nil
        Task { @MainActor [bindings, terminalConversationId, runId, terminalMessages] in
            await bindings.onRunTerminal(terminalConversationId, runId, terminalMessages)
        }
    }

    /// finishStreaming :4919-4979 的 kernel 等价。durable checkpoint 在正常
    /// 终态丢弃，前台投影没有 CGC 独立 pacer/consumer 任务需要清理。
    private func teardownRun(runId: String, terminalEvent: ChatMessageUpdateReason) {
        let runConversationId = currentConversationIdForRun
        IOSChatBackgroundGenerationCoordinator.shared.discardDurableResponse(runId: runId)
        if terminalEvent == .generationCompleted {
            backgroundExecution.updateProgress(
                runId,
                completed: 4,
                total: 4,
                subtitle: IOSAppLocalization.string("回复已完成", defaultValue: "回复已完成")
            )
        }
        backgroundExecution.end(runId)
        keepaliveHeld = false
        ChatStreamRecorder.shared.finish(runId: runId)
        IOSWebMountController.shared.releaseAgentOwnership(runId: runId)
        clearRunIdentity()
        adapter = nil
        citationTracker = nil
        bindings.setIsLoading(false)
        projection.clearAllApprovals()
        bindings.bumpMessageRevision(terminalEvent, 1)
        // P1-a:成功收尾自动发队列下一条;失败回填 composer(CG-C :4965-4969)。
        if didYieldForeground, terminalEvent == .generationCompleted {
            bindings.onForegroundYield(runId)
        }
        bindings.handleSteerQueueAtTerminal(runConversationId, terminalEvent == .generationCompleted)
        // P1-c 终态回传(CG-C :4970-4977 同款 fire-and-forget)。
        let terminalMessages = bindings.getMessages()
        Task { @MainActor [bindings, runConversationId, runId, terminalMessages] in
            await bindings.onRunTerminal(runConversationId, runId, terminalMessages)
        }
    }

    /// The durable row rejected this terminal, so do not publish a terminal to
    /// Watch/orchestration. The provider is already done; release only the
    /// process-local owner so the composer cannot remain stuck forever.
    private func releaseLocalRunAfterTerminalRecordFailure(runId: String) {
        guard currentRunId == runId else { return }
        let runConversationId = currentConversationIdForRun
        backgroundExecution.end(runId)
        keepaliveHeld = false
        ChatStreamRecorder.shared.finish(runId: runId)
        IOSWebMountController.shared.releaseAgentOwnership(runId: runId)
        clearRunIdentity()
        adapter = nil
        citationTracker = nil
        bindings.setIsLoading(false)
        bindings.setContextCompactState(.idle)
        projection.clearAllApprovals()
        bindings.bumpMessageRevision(.generationFailed, 1)
        bindings.handleSteerQueueAtTerminal(runConversationId, false)
    }

    private func clearRunIdentity() {
        toolRuntime.discardPreparedThemeImport()
        currentRunId = nil
        currentStartedAt = 0
        currentInputDigest = ""
        currentConversationIdForRun = nil
        currentParams = nil
        currentToolExposureBridge = nil
        currentDynamicToolSnapshot = nil
        runSettings = nil
        runExecutionPolicy = nil
        displayBaseline = []
        currentGenerativeUiRequirement = .none
        currentGenerativeUiFallbackAttempted = false
        currentGenerativeUiRetryIssue = nil
        backgroundHandoff = nil
        pendingBackgroundConversationStore = nil
        activeToolExecutionName = nil
        activeToolEffectClass = nil
        activeTextProvider = nil
        activeDurableTextProvider = nil
        activeImageToolCall = nil
        imageExecutionTask = nil
        imageExecutionToken = nil
        imageToolDidStart = false
        imageToolTerminalClaimed = false
        durableResponseCursor = nil
        durableCheckpointPersisted = false
        cancelCause = nil
        cancelBaseline = nil
        terminalWireName = nil
        lastFailureMessage = nil
        toolOutcomeUnknownSignal = nil
        pendingApprovalToolCallId = nil
        pendingPrompt = nil
        approvalWaiter = nil
        adapterDidStart = false
        didReportFirstDeltaThisRound = false
    }

    // MARK: - keepalive

    private func beginKeepAlive(runId: String, subtitle: String) {
        backgroundExecution.begin(
            runId,
            title: IOSAppLocalization.string(
                "Amber 正在生成",
                defaultValue: "Amber 正在生成"
            ),
            subtitle: subtitle,
            onExpire: { [weak self] in
                guard let self, self.currentRunId == runId else { return }
                self.handleKeepAliveExpiration(runId: runId)
            },
            onSystemTaskExpiration: { [weak self] in
                guard let self, self.currentRunId == runId else { return }
                self.handleKeepAliveExpiration(runId: runId)
            }
        )
        keepaliveHeld = true
    }

    /// 租约到期且 App 已不在前台时先尝试把模型轮交给后台协调器；无法安全
    /// 交接（审批/在途工具/不支持的 provider）才按 interrupted 收口。
    private func handleKeepAliveExpiration(runId: String) {
        guard currentRunId == runId,
              UIApplication.shared.applicationState != .active else { return }
        if handoffCurrentGenerationToBackground(
            conversationStore: pendingBackgroundConversationStore
        ) {
            return
        }
        cancel(cause: .backgroundInterruption)
    }

}

/// 引擎 @Sendable 钩子捕获 bindings(非 Sendable 闭包结构体)的跨边界盒;
/// 所有实际访问都经 MainActor.run 回到主 actor。
private struct UncheckedHostBindingsBox: @unchecked Sendable {
    let value: ChatGenerationBindings
    init(_ value: ChatGenerationBindings) { self.value = value }
}

/// 会话 id(KMP KotlinUuid 非 Sendable)的同款跨边界盒。
private struct UncheckedHostConversationIdBox: @unchecked Sendable {
    let value: KotlinUuid?
    init(_ value: KotlinUuid?) { self.value = value }
}

/// 官方 Responses background transport 的 Kernel provider 薄适配。它只管
/// 流与 checkpoint；消息累加、工具循环、审批和终态仍由 Engine/Host 拥有。
private final class ChatKernelDurableTextProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
    private let base = OpenAIKmpProviderAdapter()
    private let onCheckpoint: @Sendable (String, Int64) -> Void
    private let onDurableDisconnect: @Sendable (String) -> Void
    private let lock = NSLock()
    private var activeJob: Kotlinx_coroutines_coreJob?
    private var activeOnError: (@Sendable (KotlinThrowable) -> Void)?
    private var hasCheckpoint = false

    init(
        onCheckpoint: @escaping @Sendable (String, Int64) -> Void,
        onDurableDisconnect: @escaping @Sendable (String) -> Void
    ) {
        self.onCheckpoint = onCheckpoint
        self.onDurableDisconnect = onDurableDisconnect
    }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        try await base.generateText(
            providerSetting: providerSetting,
            messages: messages,
            params: params
        )
    }

    func prepareRequest(
        providerSetting: ProviderSetting,
        params: TextGenerationParams
    ) async throws -> (ProviderSetting, TextGenerationParams) {
        try await base.prepareRequest(providerSetting: providerSetting, params: params)
    }

    func supportsStreaming(providerSetting: ProviderSetting) -> Bool {
        if let openAI = providerSetting as? ProviderSetting.OpenAI,
           Self.usesBackgroundResponses(openAI) {
            return true
        }
        return base.supportsStreaming(providerSetting: providerSetting)
    }

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onChunk: @escaping @Sendable (MessageChunk) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (KotlinThrowable) -> Void
    ) -> Kotlinx_coroutines_coreJob? {
        guard let openAI = providerSetting as? ProviderSetting.OpenAI,
              Self.usesBackgroundResponses(openAI) else {
            return base.streamText(
                providerSetting: providerSetting,
                messages: messages,
                params: params,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError
            )
        }

        lock.lock()
        hasCheckpoint = false
        activeOnError = onError
        lock.unlock()
        do {
            let job = try OpenAIResponsesBackgroundTransport().startBackground(
                providerSetting: openAI,
                messages: messages,
                params: params,
                onChunk: onChunk,
                onCheckpoint: { [weak self] responseId, sequenceNumber in
                    guard let self else { return }
                    self.lock.lock()
                    self.hasCheckpoint = true
                    self.lock.unlock()
                    self.onCheckpoint(responseId, sequenceNumber.int64Value)
                },
                onComplete: { [weak self] in
                    self?.clearActiveJob()
                    onComplete()
                },
                onDisconnected: { [weak self] error in
                    guard let self else { return }
                    self.lock.lock()
                    let canDetach = self.hasCheckpoint
                    self.lock.unlock()
                    if canDetach {
                        self.onDurableDisconnect(error.message ?? String(describing: error))
                    } else {
                        self.clearActiveJob()
                        onError(KotlinThrowable(message: error.message ?? String(describing: error)))
                    }
                },
                onFailure: { [weak self] error in
                    self?.clearActiveJob()
                    onError(KotlinThrowable(message: error.message ?? String(describing: error)))
                }
            )
            lock.lock()
            activeJob = job
            lock.unlock()
            return job
        } catch {
            clearActiveJob()
            onError(KotlinThrowable(message: (error as NSError).localizedDescription))
            return nil
        }
    }

    func cancelLocalStream() {
        lock.lock()
        let job = activeJob
        activeJob = nil
        activeOnError = nil
        lock.unlock()
        job?.cancel(cause: nil)
    }

    /// 服务端已有 checkpoint、但本地持久化/接管失败时，必须恢复 Engine 的
    /// continuation；否则 provider 已断线而 Host 又没有后台 owner，run 会挂住。
    func failLocalStream(message: String) {
        lock.lock()
        let job = activeJob
        let onError = activeOnError
        activeJob = nil
        activeOnError = nil
        lock.unlock()
        job?.cancel(cause: nil)
        onError?(KotlinThrowable(message: message))
    }

    private func clearActiveJob() {
        lock.lock()
        activeJob = nil
        activeOnError = nil
        lock.unlock()
    }

    private static func usesBackgroundResponses(_ provider: ProviderSetting.OpenAI) -> Bool {
        guard provider.useResponseApi,
              provider.authMode != OpenAIAuthMode.codexOauth,
              let url = URL(string: provider.baseUrl),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.openai.com",
              url.port == nil,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }
}
