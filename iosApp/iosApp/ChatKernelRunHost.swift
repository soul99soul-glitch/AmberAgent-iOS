import Foundation
import UIKit
@preconcurrency import Shared

/// App 持有的前台 run 协调器。它唯一决定 runId、取消、终态认领和身份清理。
/// 请求准备、图片工具、审批等待及终态持久化分别由同一 run 的具体 owner 执行。
/// 开始时先冻结设置和工具目录；审批先持久化等待态再发卡；结束时先写
/// durable terminal，再发布 Watch/LiveActivity 结果。取消后迟到的适配器
/// 快照不再覆盖权威消息，后台交接也只作用于当前 run。
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

    private typealias ImageToolTerminalClaimResult = ChatImageToolRun.TerminalClaimResult

    private let dependencies: ChatGenerationDependencies
    private let bindings: ChatGenerationBindings
    private let backgroundExecution: BackgroundGenerationKeepAlive
    private let toolLedger: IOSAgentRunLedgering
    private let phoneControl: IOSPhoneControlController
    private let backgroundCoordinator: IOSChatBackgroundGenerationCoordinator
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
    func installDurableResponseSessionForTesting() {
        guard let runId = currentRunId else { return }
        durableResponseSession = ChatDurableResponseSession(host: self, runId: runId, backgroundCoordinator: backgroundCoordinator)
    }
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
    private var uploadPreparation: ChatRunUploadPreparation?
    private var backgroundHandoff: IOSChatBackgroundHandoff?
    private weak var pendingBackgroundConversationStore: IOSConversationStore?
    private var activeToolExecutionName: String?
    private var activeToolEffectClass: IOSToolEffectClass?
    private var activeTextProvider: (any IOSAgentTextProvider)?
    private var durableResponseSession: ChatDurableResponseSession?
    private var imageToolRun: ChatImageToolRun?
#if DEBUG
    var imageToolExecutionOverrideForTesting: (@MainActor (UIMessagePart.Tool, [UIMessage]) async -> [UIMessage])?
#endif
    private var citationTracker: IOSMemoryCitationTracker?
    private var streamClock = ChatGenerationSpeedClock()
    private var progressPresentation: ChatRunProgressPresentation?
    private var keepaliveHeld = false
    private var phoneAutomaticReasoning = false
    private var reportsPhoneWorkProgress: Bool { progressPresentation?.reportsPhoneWorkProgress ?? false }
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
    private var approvalSession = ChatRunApprovalSession()

    var isRunning: Bool { currentRunId != nil }
    var hasPendingToolApproval: Bool { approvalSession.hasPendingApproval }
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
        textProvider: (any IOSAgentTextProvider)? = nil,
        phoneControl: IOSPhoneControlController = .shared,
        backgroundCoordinator: IOSChatBackgroundGenerationCoordinator = .shared
    ) {
        self.dependencies = dependencies
        self.bindings = bindings
        self.backgroundExecution = backgroundExecution
        self.toolLedger = toolLedger
        self.textProviderOverride = textProvider
        self.phoneControl = phoneControl
        self.backgroundCoordinator = backgroundCoordinator
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

    func isImageRunCurrent(_ runId: String) -> Bool { currentRunId == runId }
    func isImageRunCancelled(_ runId: String) -> Bool {
        currentRunId == runId && cancelCause != nil
    }
    func isImageRunActive(_ runId: String) -> Bool {
        currentRunId == runId && cancelCause == nil
    }
    func claimImageFailureTerminal(_ runId: String) -> Bool {
        guard currentRunId == runId, !didFinalizeTerminal else { return false }
        didFinalizeTerminal = true
        return true
    }
    func claimImageTerminal(_ runId: String) -> Bool {
        guard currentRunId == runId, cancelCause == nil, !didFinalizeTerminal else { return false }
        didFinalizeTerminal = true
        return true
    }

    // MARK: - start(CG-C start :1037-1166)

    func start(
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        inputDigest: String,
        conversationId: KotlinUuid?,
        uploadMessages: [UIMessage],
        toolExposureBridge: IosToolExposureBridge? = nil,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot? = nil,
        phoneControlUserInitiated: Bool = false
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
        uploadPreparation = ChatRunUploadPreparation(
            runId: runId,
            conversationId: conversationId,
            settings: runSettings ?? dependencies.sharedSettings.snapshot,
            toolExposureBridge: bridge,
            mcpEnabled: { [weak self] in self?.mcpEnabledForRun ?? false },
            bindings: bindings,
            isCurrentRun: { [weak self] in self?.currentRunId == runId },
            onPreparedUpload: { [weak self] provider, effectiveParams, messages in
                try self?.refreshBackgroundHandoff(
                    runId: runId, providerSetting: provider,
                    params: effectiveParams, uploadMessages: messages
                )
            }
        )
        backgroundHandoff = nil
        pendingBackgroundConversationStore = nil
        activeToolExecutionName = nil
        activeToolEffectClass = nil
        activeTextProvider = nil
        durableResponseSession = nil
        imageToolRun = nil
        approvalSession = ChatRunApprovalSession()
        didFinalizeTerminal = false
        cancelCause = nil
        cancelBaseline = nil
        terminalWireName = nil
        lastFailureMessage = nil
        adapterDidStart = false
        keepaliveHeld = false
        streamClock = ChatGenerationSpeedClock()
        let tracker = IOSMemoryCitationTracker(enforceCitationAllowlist: true)
        citationTracker = tracker

        progressPresentation = ChatRunProgressPresentation(
            runId: runId, startedAt: startedAt, displayBaseline: displayBaseline,
            reportsPhoneWorkProgress: false,
            initialMessages: uploadMessages,
            backgroundExecution: backgroundExecution,
            liveActivityController: dependencies.liveActivityController,
            conversationId: conversationId,
            isCurrentRun: { [weak self] in self?.currentRunId == runId }
        )
        bindings.startLiveActivity(
            runId,
            conversationId,
            AgentActivityPresentation.response(stage: AgentActivityResponseStagePolicy.initialStage)
        )
        // 生成一开始就拿后台执行权(CG-C :1084-1104 同款纪律与注释语义)。
        beginKeepAlive(runId: runId, subtitle: params.model.displayName)
        // Reserve this run's selected apps; only a phone tool may start the local test session.
        // Keep the same owner across a foreground/background handoff.
        let hasPhoneDeclarations = bridge.fullToolDeclarations().contains {
            IOSPhoneControlToolCatalog.isPhoneTool(name: $0.name)
        }
        let phoneControlClaimed = phoneControlUserInitiated && hasPhoneDeclarations
            && phoneControl.claim(runID: runId) { [weak self, weak phoneControl, backgroundCoordinator] in
            guard phoneControl?.hasRequestedSession(runID: runId) == true else { return }
            if self?.currentRunId == runId { self?.cancel(cause: .backgroundInterruption) }
            _ = backgroundCoordinator.cancelJob(runId: runId)
        }
        if phoneControlClaimed {
            // Screenshots, actions and model thinking can each exceed the system's ~30s
            // progress cadence; without a heartbeat the continued-processing task is
            // marked stalled and reclaimed as soon as the app is backgrounded.
            backgroundExecution.enableLivenessHeartbeat(runId)
        }
        // Preserve the user's raw choice before AUTO is resolved to a model default.
        // Actual phone activity is checked by the engine at each request boundary.
        phoneAutomaticReasoning = phoneControlClaimed
            && runSettings?.getCurrentAssistant().reasoningLevel == .auto_
        progressPresentation?.activatePhoneProgress(phoneControlClaimed)
        // Phone loops have no fixed number of turns; only actual work advances their progress.
        backgroundExecution.updateProgress(
            runId,
            completed: 0,
            total: phoneControlClaimed ? -1 : 4,
            subtitle: IOSAppLocalization.string("准备上下文", defaultValue: "准备上下文")
        )
        if phoneControl.enabled || hasPhoneDeclarations {
            IOSBackgroundLifecycleLog.record("phoneControlRunGate",
                detail: "userInitiated=\(phoneControlUserInitiated) enabled=\(phoneControl.enabled) prepared=\(phoneControl.hasPreparedPairing) declared=\(hasPhoneDeclarations) claimed=\(phoneControlClaimed)")
        }

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
            // mcp sync(CG-C :1125-1128)。本轮工具目录已在 start 前由 VM 钉住
            // (toolExposureBridge),同步只保活连接并为后续轮次刷新目录,
            // 所以不阻塞首 token;本轮 MCP 调用由 mcpManager 等待同步完成。
            if self.mcpEnabledForRun {
                let mcpManager = self.dependencies.mcpManager
                // 冷启动首轮:先无网络发布持久化目录,注入不依赖同步先完成。
                mcpManager.loadPersistedCatalogIfNeeded()
                Task { @MainActor in
                    await mcpManager.syncAll(enabledOverride: true)
                }
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
        uploadPreparation = nil
        backgroundHandoff = nil
        pendingBackgroundConversationStore = nil
        activeToolExecutionName = "generate_image"
        activeToolEffectClass = .sideEffect
        activeTextProvider = nil
        durableResponseSession = nil
        approvalSession = ChatRunApprovalSession()
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

        progressPresentation = ChatRunProgressPresentation(
            runId: runId, startedAt: startedAt, displayBaseline: displayBaseline,
            reportsPhoneWorkProgress: false, initialMessages: displayBaseline,
            backgroundExecution: backgroundExecution,
            liveActivityController: dependencies.liveActivityController,
            conversationId: conversationId,
            isCurrentRun: { [weak self] in self?.currentRunId == runId }
        )
        ChatImageToolRun.beginActivity(
            runId: runId, conversationId: conversationId,
            modelDisplayName: modelDisplayName,
            bindings: bindings, backgroundExecution: backgroundExecution,
            onExpire: { [weak self] in
                guard let self, self.currentRunId == runId else { return }
                self.cancel(cause: .backgroundInterruption)
            }
        )

        let toolCall = toolRuntime.userInitiatedImageToolCall(input: input)
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

        let imageRun = ChatImageToolRun(
            toolCall: toolCall, bindings: bindings, toolRuntime: toolRuntime,
            toolLedger: toolLedger, dependencies: dependencies
        )
#if DEBUG
        imageRun.executionOverrideForTesting = imageToolExecutionOverrideForTesting
#endif
        imageToolRun = imageRun
        let context = ChatImageToolRun.Run(
            runId: runId, startedAt: startedAt, inputDigest: inputDigest,
            conversationId: conversationId, snapshot: snapshot
        )
        runTask = Task { @MainActor [weak self, imageRun] in
            guard let self else { return }
            await imageRun.execute(run: context, host: self)
        }
    }

    func failImageToolDurability(runId: String) async {
        guard currentRunId == runId, !didFinalizeTerminal else { return }
        didFinalizeTerminal = true
        lastFailureMessage = IOSAppLocalization.string(
            "tool result ledger write failed",
            defaultValue: "tool result ledger write failed"
        )
        await commitTerminal(runId: runId, requiresRecovery: true)
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
        ChatRunRequestFactory(
            bindings: bindings,
            maxToolResumeCount: dependencies.settingsStore.chatMaxToolResumeCount,
            executionPolicy: runExecutionPolicy,
            phoneAutomaticReasoning: phoneAutomaticReasoning,
            phoneControl: phoneControl,
            prepareUploadMessages: { [weak self] messages in
                guard let self, self.currentRunId == runId,
                      let preparation = self.uploadPreparation else { return messages }
                return try await preparation.prepareUploadMessages(
                    messages, provider: providerSetting, params: params
                )
            },
            approvalDecider: { [weak self] prompt in
                guard let self else { return nil }
                return await self.approvalDecider(prompt, runId: runId)
            }
        ).make(
            adapterProvider: adapterProvider, providerSetting: providerSetting,
            params: params, runId: runId, startedAt: startedAt,
            inputDigest: inputDigest, conversationId: conversationId,
            initialMessages: initialMessages, toolExposureBridge: toolExposureBridge,
            recipeCatalogSnapshot: recipeCatalogSnapshot, citationTracker: citationTracker
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
        guard let uploadPreparation,
              terminalWireName == AgentRunStatus.completed.wireName,
              !uploadPreparation.fallbackAttempted,
              !toolRuntime.hasUnresolvedToolCall(in: bindings.getMessages()),
              let issue = IOSGenerativeUiRequestPolicy.widgetIssue(
                in: bindings.getMessages(),
                afterDisplayMessageCount: displayBaseline.count,
                requirement: uploadPreparation.requirement
              ) else { return }

        uploadPreparation.fallbackAttempted = true
        uploadPreparation.retryIssue = issue
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
            requirement: uploadPreparation.requirement
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
        if imageToolRun?.terminalClaimed == true { return }
        cancelCause = cause
        phoneControl.revoke(runID: runId)
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
        backgroundCoordinator.discardDurableResponse(runId: runId)
        cancelRemoteDurableResponseIfNeeded()
        cancelBaseline = bindings.capturePersistMessagesBaseline(currentConversationIdForRun)
        if let imageToolRun {
            let activeImageToolCall = imageToolRun.toolCall
            let wasExecuting = imageToolRun.isExecuting
            imageToolRun.cancelExecution()
            var messages = bindings.getMessages()
            if toolRuntime.hasUnresolvedToolCall(in: messages) {
                messages = toolRuntime.messagesByFailingPendingToolCalls(
                    in: messages,
                    failureReason: toolFailureReason,
                    denied: true
                )
                bindings.setMessages(messages)
            }
            if imageToolRun.didStart {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let terminalClaim: ImageToolTerminalClaimResult
                    if wasExecuting {
                        terminalClaim = await imageToolRun.markOutcomeUnknownIfNeeded(
                            host: self, runId: runId,
                            toolCall: activeImageToolCall,
                            outcome: "cancelled_during_execution"
                        )
                    } else {
                        terminalClaim = await imageToolRun.recordTerminalIfNeeded(
                            host: self, runId: runId,
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
        approvalSession.cancel()
    }

    @discardableResult
    func handoffCurrentGenerationToBackground(
        conversationStore: IOSConversationStore?,
        honorKeepAliveLease: Bool = false
    ) -> Bool {
        guard let runId = currentRunId,
              cancelCause == nil,
              !didFinalizeTerminal,
              !hasPendingToolApproval,
              durableResponseSession?.requiresRecovery != true else { return false }
        if detachDurableResponse(runId: runId) { return true }
        if honorKeepAliveLease {
            switch backgroundExecution.executionAssertion(for: runId) {
            case .uiOnly, .submitted, .adopted, .audio, .location:
                pendingBackgroundConversationStore = conversationStore
                return false
            case .none:
                break
            }
        }
        guard canHandoffActiveTool,
              let handoff = ChatRunBackgroundHandoffBuilder.displaySnapshot(
                  backgroundHandoff,
                  messages: bindings.getMessages(),
                  baseline: displayBaseline
              ),
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
            return backgroundCoordinator.startForegroundHandoff(
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

    private func makeTextProvider(runId: String) -> any IOSAgentTextProvider {
        if let textProviderOverride { return textProviderOverride }
        let session = ChatDurableResponseSession(host: self, runId: runId, backgroundCoordinator: backgroundCoordinator)
        durableResponseSession = session
        return session.provider
    }

    func recordDurableResponseCheckpoint(
        runId: String, responseId: String, sequenceNumber: Int64,
        requestToken: UUID? = nil
    ) {
        guard currentRunId == runId, cancelCause == nil,
              let handoff = backgroundHandoff,
              let session = durableResponseSession,
              let checkpoint = session.checkpoint(
                responseId: responseId, sequenceNumber: sequenceNumber, handoff: handoff,
                requestToken: requestToken
              ) else { return }
        backgroundHandoff = checkpoint.handoff
        if checkpoint.isNew, canReportPhoneWorkProgress(runId: runId) {
            backgroundExecution.advanceProgress(runId)
        }
        if pendingBackgroundConversationStore != nil {
            _ = detachDurableResponse(runId: runId)
        }
    }

    func handleDurableDisconnect(runId: String, message: String, requestToken: UUID? = nil) {
        guard currentRunId == runId, cancelCause == nil else { return }
        if let requestToken, durableResponseSession?.provider.isCurrentRequest(requestToken) != true { return }
        if !detachDurableResponse(runId: runId) {
            durableResponseSession?.provider.failLocalStream(message: message)
        }
    }

    @discardableResult
    private func detachDurableResponse(runId: String) -> Bool {
        guard currentRunId == runId,
              cancelCause == nil,
              !didFinalizeTerminal,
              durableResponseSession?.canDetach(handoff: backgroundHandoff) == true,
              canHandoffActiveTool,
              !hasPendingToolApproval else { return false }
        durableResponseSession?.provider.cancelLocalStream()
        adapter?.detachForBackgroundHandoff()
        runTask?.cancel()
        runTask = nil
        backgroundExecution.end(runId)
        ChatStreamRecorder.shared.finish(runId: runId)
        clearRunIdentity()
        adapter = nil
        citationTracker = nil
        activeTextProvider = nil
        durableResponseSession = nil
        keepaliveHeld = false
        bindings.setContextCompactState(.idle)
        bindings.setIsLoading(false)
        projection.clearAllApprovals()
        bindings.bumpMessageRevision(.generationHandedOffToBackground, 1)
        backgroundCoordinator.resumeDetachedResponsesIfNeeded()
        return true
    }

    private func cancelRemoteDurableResponseIfNeeded() {
        durableResponseSession?.cancelRemote(handoff: backgroundHandoff)
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
        guard case .ish(let approvalRequest) = approvalSession.prompt,
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
        guard case .ish(let approvalRequest) = approvalSession.prompt,
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
              let prompt = approvalSession.prompt,
              ChatRunApprovalSession.requestId(of: prompt) == requestId,
              ChatRunApprovalSession.category(of: prompt) != .askUser else {
            return false
        }
        return resolvePendingApproval(
            decision: allow ? .approve : .deny,
            category: ChatRunApprovalSession.category(of: prompt),
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
              let prompt = approvalSession.prompt,
              case .askUser = prompt,
              ChatRunApprovalSession.requestId(of: prompt) == requestId else {
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
        category: ChatRunApprovalSession.Category,
        requestId: String? = nil
    ) -> Bool {
        guard let runId = currentRunId,
              let claim = approvalSession.claim(
                category: category, requestId: requestId, runId: runId
              ) else { return false }
        projection.clearApproval(claim.prompt)
        bindings.setIsLoading(true)
        if !keepaliveHeld {
            beginKeepAlive(runId: runId, subtitle: currentParams?.model.displayName ?? "")
        }
        bindings.startLiveActivity(
            runId,
            currentConversationIdForRun,
            AgentActivityPresentation.response(stage: .generating)
        )
        claim.waiter.resume(returning: decision)
        return true
    }

    // MARK: - 适配器装配

    private func makeAdapter(runId: String) -> ChatRunKernelAdapter {
        var callbacks = ChatRunKernelAdapter.Callbacks()
        callbacks.onMessagesUpdated = { [weak self] messages in
            guard let self, self.currentRunId == runId else { return }
            if self.canReportPhoneWorkProgress(runId: runId) {
                self.progressPresentation?.recordPhoneToolResultProgress(messages)
            }
            if self.currentRunId == runId {
                self.progressPresentation?.recordJevNextModelStepIfNeeded(messages)
            }
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
            self.phoneControl.revoke(runID: runId)
        }
        callbacks.onAssistantTurnCompleted = { [weak self] messages in
            guard let self, self.currentRunId == runId, self.cancelCause == nil else { return false }
            guard let session = self.durableResponseSession, session.hasPersistedOwner,
                  let handoff = self.backgroundHandoff else { return true }
            let continuation = ChatRunBackgroundHandoffBuilder.continuingAfterResponse(handoff, messages: messages)
            guard session.persistContinuation(continuation) else { return false }
            self.backgroundHandoff = continuation
            return true
        }
        callbacks.onAssistantTurnStarted = { [weak self] in
            guard let self, self.currentRunId == runId else { return }
            self.progressPresentation?.recordModelStep()
            self.streamClock.resetRound()
            self.bindings.setMessages(
                self.bindings.getMessages().clearingLastAssistantGenerationDuration()
            )
            self.projection.discardProvisionalAssistant()
            self.progressPresentation?.beginModelRound()
            self.backgroundExecution.updateProgress(
                runId,
                completed: self.reportsPhoneWorkProgress ? 0 : 1,
                total: self.reportsPhoneWorkProgress ? -1 : 4,
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
            } else {
                // 工具之后的新一轮：先离开工具步骤（与后台路径每轮先发 preparing 一致）。
                // 否则要等模型出第一个字才更新，非流式模型整轮都不会更新，
                // 工具心跳还会一直续期，岛上停在"正在阅读网页"直到任务结束。
                let preparing = AgentActivityPresentation.response(
                    stage: AgentActivityResponseStagePolicy.initialStage
                )
                WatchTaskCoordinator.shared.publish(
                    runId: runId,
                    conversationId: self.currentConversationIdForRun?.toHexDashString(),
                    presentation: preparing
                )
                Task { @MainActor [weak self] in
                    guard let self, self.currentRunId == runId else { return }
                    await self.dependencies.liveActivityController.update(
                        runId: runId,
                        presentation: preparing
                    )
                }
            }
        }
        callbacks.onToolExecutionStarted = { [weak self] toolName, input in
            guard let self, self.currentRunId == runId else { return }
            self.activeToolExecutionName = toolName
            self.activeToolEffectClass = IOSToolEffectClassMapping.forToolName(toolName, input: input)
            self.progressPresentation?.publishToolStarted(toolName: toolName, input: input)
        }
        callbacks.onAssistantStage = { [weak self] stage in
            guard let self, self.currentRunId == runId else { return }
            self.progressPresentation?.publishAssistantStage(stage)
        }
        callbacks.onAssistantFirstVisibleDelta = { [weak self] in
            guard let self, self.currentRunId == runId, !self.didFinalizeTerminal else { return }
            self.progressPresentation?.recordFirstJevDelta()
            self.streamClock.noteVisibleDelta()
            self.progressPresentation?.recordFirstVisibleProgress()
        }
        callbacks.onAssistantMessageSnapshot = { [weak self] message in
            guard let self, self.currentRunId == runId else { return }
            if self.canReportPhoneWorkProgress(runId: runId) {
                self.progressPresentation?.recordPhoneModelProgress(message)
            }
            self.projection.publishProvisionalAssistant(message)
            // 同一步骤长时间输出时续期灵动岛，避免仍在输出却被系统判为过期。
            self.dependencies.liveActivityController.noteProgress(runId: runId)
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
        let result = await approvalSession.pause(
            prompt: prompt,
            runId: runId,
            toolCallId: pendingApprovalToolCallId ?? "",
            conversationId: currentConversationIdForRun,
            bindings: bindings,
            projection: projection,
            backgroundExecution: backgroundExecution,
            liveActivityController: dependencies.liveActivityController,
            isCurrentRun: { [weak self] in self?.currentRunId == runId && self?.cancelCause == nil },
            onKeepAliveReleased: { [weak self] in self?.keepaliveHeld = false }
        )
        switch result {
        case .decision(let decision): return decision
        case .storageFailure(let message):
            lastFailureMessage = message
            return nil
        }
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

    private func refreshBackgroundHandoff(
        runId: String, providerSetting: ProviderSetting,
        params: TextGenerationParams, uploadMessages: [UIMessage]
    ) throws {
        guard currentRunId == runId, let conversationId = currentConversationIdForRun else {
            backgroundHandoff = nil
            return
        }
        let preparedHandoff = ChatRunBackgroundHandoffBuilder.prepare(
            runId: runId, startedAt: currentStartedAt, inputDigest: currentInputDigest,
            conversationId: conversationId, providerSetting: providerSetting, params: params,
            uploadMessages: uploadMessages, displayMessages: bindings.getMessages(), displayBaseline: displayBaseline,
            toolExposureBridge: currentToolExposureBridge, dynamicSnapshot: currentDynamicToolSnapshot,
            executionPolicy: runExecutionPolicy, phoneAutomaticReasoning: phoneAutomaticReasoning,
            generativeUiRequirement: uploadPreparation?.requirement ?? .none,
            generativeUiFallbackAttempted: uploadPreparation?.fallbackAttempted ?? false
        )
        guard durableResponseSession?.persistContinuation(preparedHandoff) != false else {
            throw NSError(domain: "AmberAgent.ChatCheckpoint", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法保存下一轮恢复信息，生成已暂停，请重试。"])
        }
        backgroundHandoff = preparedHandoff
    }

    // MARK: - 终态收口

    private func preambleFailed(rawMessage: String, modelId: String, runId: String) async {
        guard currentRunId == runId, !didFinalizeTerminal else { return }
        didFinalizeTerminal = true
        lastFailureMessage = rawMessage
        await commitTerminal(runId: runId)
    }

    func finalizeTerminal(runId: String) async {
        guard currentRunId == runId, !didFinalizeTerminal else { return }
        didFinalizeTerminal = true
        await commitTerminal(runId: runId)
    }

    private func commitTerminal(runId: String, requiresRecovery: Bool = false) async {
        let run = ChatRunTerminalCommit.Run(
            runId: runId, startedAt: currentStartedAt, inputDigest: currentInputDigest,
            conversationId: currentConversationIdForRun, displayBaseline: displayBaseline,
            citationTracker: citationTracker, streamClock: streamClock, failureMessage: lastFailureMessage,
            modelId: currentParams?.model.modelId ?? "", cancelCause: cancelCause,
            cancelBaseline: cancelBaseline, outcomeUnknownSignal: toolOutcomeUnknownSignal
        )
        let committer = ChatRunTerminalCommit(
            bindings: bindings, dependencies: dependencies, phoneControl: phoneControl,
            projection: projection, toolRuntime: toolRuntime, backgroundExecution: backgroundExecution
        )
        let result: ChatRunTerminalCommit.Result
        if cancelCause != nil {
            result = await committer.cancelled(run: run)
        } else {
            switch terminalWireName {
            case AgentRunStatus.completed.wireName:
                result = await committer.completed(run: run)
            case AgentRunStatus.outcomeUnknown.wireName:
                result = await committer.outcomeUnknown(run: run)
            case AgentRunStatus.recoveryPending.wireName:
                result = await committer.failed(run: run, requiresRecovery: true)
            default:
                result = await committer.failed(
                    run: run, requiresRecovery: requiresRecovery || durableResponseSession?.requiresRecovery == true
                )
            }
        }
        switch result {
        case .recordRejected:
            releaseLocalRunAfterTerminalRecordFailure(runId: runId)
        case .recorded(let event, let status, let succeeded, let cancelled):
            if cancelled {
                finishCancelledRun(runId: runId, terminalStatus: status)
            } else {
                teardownRun(runId: runId, terminalEvent: event, terminalStatus: status)
            }
            if succeeded { bindings.generationSucceeded() }
        }
    }

    private func finishCancelledRun(runId: String, terminalStatus: AgentRunStatus) {
        backgroundExecution.end(runId)
        keepaliveHeld = false
        let terminalMessages = bindings.getMessages(), terminalBaseline = displayBaseline
        progressPresentation?.finishJevToolDiscoveryStep(
            messages: terminalMessages, terminalStatus: terminalStatus
        )
        progressPresentation?.recordJevRunCompletion(messages: terminalMessages)
        let conversationId = currentConversationIdForRun
        IOSWebMountController.shared.releaseAgentOwnership(runId: runId)
        phoneControl.revoke(runID: runId)
        clearRunIdentity()
        adapter = nil
        citationTracker = nil
        Task { @MainActor [bindings, conversationId, runId, terminalMessages, terminalBaseline, terminalStatus] in
            await bindings.onRunTerminal(conversationId, runId, terminalStatus, terminalMessages, terminalBaseline)
        }
    }

    /// finishStreaming :4919-4979 的 kernel 等价。durable checkpoint 在正常
    /// 终态丢弃，前台投影没有 CGC 独立 pacer/consumer 任务需要清理。
    func teardownRun(
        runId: String,
        terminalEvent: ChatMessageUpdateReason,
        terminalStatus: AgentRunStatus
    ) {
        // 完成/失败共用的收尾路径；取消走 cancelledTerminal 下方单独打点。
        ChatPerfTrace.event("RunTerminal")
        let runConversationId = currentConversationIdForRun
        if terminalStatus != .recoveryPending || durableResponseSession?.hasPersistedOwner != true {
            backgroundCoordinator.discardDurableResponse(runId: runId)
        }
        if terminalEvent == .generationCompleted {
            backgroundExecution.updateProgress(
                runId,
                completed: reportsPhoneWorkProgress ? 0 : 4,
                total: reportsPhoneWorkProgress ? -1 : 4,
                subtitle: IOSAppLocalization.string("回复已完成", defaultValue: "回复已完成")
            )
        }
        backgroundExecution.end(runId)
        keepaliveHeld = false
        ChatStreamRecorder.shared.finish(runId: runId)
        IOSWebMountController.shared.releaseAgentOwnership(runId: runId)
        phoneControl.revoke(runID: runId)
        let terminalMessages = bindings.getMessages(), terminalBaseline = displayBaseline
        progressPresentation?.finishJevToolDiscoveryStep(
            messages: terminalMessages, terminalStatus: terminalStatus
        )
        progressPresentation?.recordJevRunCompletion(messages: terminalMessages)
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
        Task { @MainActor [bindings, runConversationId, runId, terminalMessages, terminalBaseline, terminalStatus] in
            await bindings.onRunTerminal(runConversationId, runId, terminalStatus, terminalMessages, terminalBaseline)
        }
    }

    /// The durable row rejected this terminal, so do not publish a terminal to
    /// Watch/orchestration. The provider is already done; release only the
    /// process-local owner so the composer cannot remain stuck forever.
    func releaseLocalRunAfterTerminalRecordFailure(runId: String) {
        guard currentRunId == runId else { return }
        ChatPerfTrace.event("RunTerminal")
        IOSJevToolDiscoveryMetricsTracker.discardPending(runId: runId)
        let runConversationId = currentConversationIdForRun
        backgroundExecution.end(runId)
        keepaliveHeld = false
        ChatStreamRecorder.shared.finish(runId: runId)
        IOSWebMountController.shared.releaseAgentOwnership(runId: runId)
        phoneControl.revoke(runID: runId)
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
        phoneAutomaticReasoning = false
        displayBaseline = []
        uploadPreparation = nil
        backgroundHandoff = nil
        pendingBackgroundConversationStore = nil
        activeToolExecutionName = nil
        activeToolEffectClass = nil
        activeTextProvider = nil
        durableResponseSession = nil
        imageToolRun = nil
        cancelCause = nil
        cancelBaseline = nil
        terminalWireName = nil
        lastFailureMessage = nil
        toolOutcomeUnknownSignal = nil
        pendingApprovalToolCallId = nil
        approvalSession.cancel()
        adapterDidStart = false
    }

    // MARK: - keepalive

    private func canReportPhoneWorkProgress(runId: String) -> Bool {
        reportsPhoneWorkProgress && currentRunId == runId && cancelCause == nil
            && !didFinalizeTerminal && keepaliveHeld && phoneControl.handoffState(runID: runId) != nil
    }

    private func beginKeepAlive(runId: String, subtitle: String) {
        guard currentRunId == runId, let progressPresentation else { return }
        progressPresentation.beginKeepAlive(subtitle: subtitle) { [weak self] in
            guard let self, self.currentRunId == runId else { return }
            self.handleKeepAliveExpiration(runId: runId)
        }
        keepaliveHeld = true
    }

    /// 租约到期且 App 已不在前台时先尝试把模型轮交给后台协调器；无法安全
    /// 交接（审批/在途工具/不支持的 provider）才按 interrupted 收口。
    func handleKeepAliveExpiration(runId: String, applicationState: UIApplication.State? = nil) {
        guard currentRunId == runId,
              (applicationState ?? UIApplication.shared.applicationState) != .active else { return }
        if handoffCurrentGenerationToBackground(
            conversationStore: pendingBackgroundConversationStore
        ) {
            return
        }
        cancel(cause: .backgroundInterruption)
    }

}
