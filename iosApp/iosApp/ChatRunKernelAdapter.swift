import Foundation
@preconcurrency import Shared

/// P0-2 A2: 审批决定三态。ask_user 需要文本答案;其余类目为布尔
/// (memory 的 deny 在适配层映射 `.deniedByUser` 写策略)。决定形状与
/// 审批卡类目不匹配视为 Host bug——run 诚实失败,不猜测执行。
enum ChatKernelApprovalDecision: Equatable {
    case approve
    case deny
    case answer(String)

    /// 布尔类目的决定值;`.answer` 返回 nil。
    var boolValue: Bool? {
        switch self {
        case .approve: return true
        case .deny: return false
        case .answer: return nil
        }
    }
}

/// P0-2 B3: 前台循环的内核形态适配器。
///
/// 用 B1 钩子 + B2 前台执行器把 `IOSAgentToolEngine` 装配成与
/// `ChatGenerationCoordinator` 前台循环语义对齐的 run 内核:
/// - kind 优先级批排序(`sortPendingToolCalls`,序同 `nextPendingToolCall`);
/// - 轮边界 mailbox→steer 消费(引擎钩子;首轮头消费由适配器 pre-fold);
/// - 工具轮预算(`preemptToolBatch`,语义同 `maxToolResumeCount`:流完成后、
///   执行前裁定,耗尽即整批失败化终止);
/// - 未暴露工具引导软失败(`resolveUnexposedToolCall`:目录有、可见集没有 →
///   Finished(failed) 无 Started,续跑;彻底未知 → 批量硬失败);
/// - 审批暂停/恢复:引擎 `.needsApproval` → 适配器发布审批卡并挂起,
///   决定后按 `executeApprovedAsyncTool` 账本纪律重放(新尝试 Started →
///   resume → runtime finisher → Finished),随后以回填后的消息重启引擎循环。
/// - Host 取消:`cancel()` 把未决工具原地填 "User cancelled." 并取消引擎
///   驱动子任务(A3#7);迟到 Finished 经账本诚实落地,终态只报一次。
///
/// 该适配器是生产前台文本路径的唯一模型—工具循环；回调面与 Host/
/// Projection 的边界一一对应。
@MainActor
final class ChatRunKernelAdapter {

    /// 与 CGC bindings 录制点等价的回调面。
    struct Callbacks {
        /// 终态(AgentRunStatus.wireName:completed/failed/cancelled)。
        var onRunTerminal: (String) -> Void = { _ in }
        var onForegroundYield: () -> Void = {}
        /// CGC `markRunAwaitingPermission` 位置:暂停先于发卡。
        var onAwaitingPermission: (String) -> Void = { _ in }
        /// CGC `claimRunAfterPermission` 位置:新尝试 Started 之后、执行之前。
        /// 返回 false = resume 绑定持久化失败(CG-C :4310-4325:账本补
        /// Finished(not_executed_permission_claim_failed),run 以 failed 收口)。
        var onRunResumed: () async -> Bool = { true }
        var onApprovalPrompt: (ChatToolApprovalPrompt) -> Void = { _ in }
        var onMessagesUpdated: ([UIMessage]) -> Void = { _ in }
        /// B1: provider/上传准备失败的原始错误串,先于 onRunTerminal(.failed)
        /// 上报——Host 据此产出 CGC presentStreamError 同款的用户向错误泡。
        var onProviderFailure: (String) -> Void = { _ in }
        /// A side-effect tool reported that it may have applied but could not
        /// be verified. The host surfaces the existing reconciliation card.
        var onToolOutcomeUnknown: (IOSToolOutcomeUnknownSignal) -> Void = { _ in }
        /// B2 流式投影:引擎回调的 MainActor 转递(取消后一律忽略)。
        var onAssistantTurnStarted: () -> Void = {}
        var onAssistantTurnCompleted: ([UIMessage]) -> Bool = { _ in true }
        var onToolExecutionStarted: (String, String) -> Void = { _, _ in }
        var onAssistantStage: (AgentActivityStage) -> Void = { _ in }
        /// Optional so a Host that only needs first-visible progress does not
        /// enqueue one MainActor task for every streamed delta. Consumers that
        /// need the complete per-delta stream still opt in here.
        var onAssistantText: ((String) -> Void)? = nil
        var onAssistantReasoning: ((String) -> Void)? = nil
        /// One signal per model round for progress/latency bookkeeping. The
        /// full text/reasoning callbacks above remain available independently.
        var onAssistantFirstVisibleDelta: (() -> Void)? = nil
        /// B2:引擎逐 chunk 推送的在途 assistant 累加器快照(citation 已剥离,
        /// id 本轮稳定且与终态权威消息同 id)——provisional 气泡的唯一数据源。
        var onAssistantMessageSnapshot: (UIMessage) -> Void = { _ in }
    }

    /// 一次内核 run 的输入。`params.tools` 必须是首轮可见集(桥装配产物,
    /// 生产 ChatViewModel:3583 同款)。
    struct RunRequest {
        let provider: any IOSAgentTextProvider
        let providerSetting: ProviderSetting
        let params: TextGenerationParams
        let runId: String
        let startedAt: Int64
        let inputDigest: String
        let conversationId: KotlinUuid?
        let initialMessages: [UIMessage]
        let toolExposureBridge: IosToolExposureBridge
        /// 当前 run 开始时与 recipe declarations 同源的不可变目录快照。
        /// 执行器只从该快照解析 `recipe__*`，不回读 live store。
        var recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot? = nil
        /// Re-reads the Recipe registry at each post-tool model boundary. The
        /// adapter applies a changed snapshot to the existing exposure bridge,
        /// so lifecycle operations are visible on the immediately next round.
        var recipeCatalogRefresh: (@MainActor () async -> IOSDynamicToolCatalogSnapshot?)? = nil
        var executionPolicy: IOSExecutionPolicySnapshot? = nil
        var phoneAutomaticReasoning: Bool = false
        var phoneControl: IOSPhoneControlController? = nil
        /// CGC `maxToolResumeCount` 语义:每个工具轮消耗 1,耗尽拒执。
        let maxToolResumeCount: Int
        /// 首轮头 steer 消费(CG-C startStreaming :2141 同款位置)之后的轮边界
        /// 消费由引擎 drainSteer 钩子承担。闭包按调用序消费队列,与 CGC 的
        /// drain 序号对齐:#1 = 首轮头(适配器),#2 = 工具循环边界(引擎)。
        let drainSteer: (@Sendable () async -> [UIMessage])?
        /// 轮边界 mailbox 消费(引擎钩子,先于 drainSteer——序同 CG-C
        /// nextRoundMessagesAfterMailboxAndSteerConsumption :3701-3702)。
        let mailboxDrain: (@Sendable () async -> IOSMailboxDrainResult)?
        /// B1: citation 剥离 tracker,逐段透传给引擎(引擎终态统一 flush
        /// remainder 进 result.messages);Host 在 run 终态读 citationIds
        /// 记 memory 使用。适配器 cancel 时用同一 tracker 把 remainder 折进
        /// 取消快照(对齐 CG-C cancel :1490 的 flushingCitationTracker)。
        let citationTracker: IOSMemoryCitationTracker?
        /// B1: Host 的每轮上传准备(运行时语境注入 + 压缩 + 记忆召回标记),
        /// 在 G7 预算提示之后、上传之前执行(CG-C prepareAndStartStreaming
        /// :1960-2050 的逐轮等价)。抛错 = 上传准备失败,run 以 failed 收口
        /// (CG-C 压缩失败 → presentStreamError 语义)。
        let prepareUploadMessages: (@MainActor ([UIMessage]) async throws -> [UIMessage])?
        let nestedToolRunner: IosExecNestedToolRunner?
        /// 审批决定器:挂起等待用户选择。ask_user 卡须回 `.answer`,其余卡
        /// 回 `.approve`/`.deny`;形状不匹配即 run 失败(诚实,不猜测)。
        /// 返回 nil = Host 已自行终态化(如暂停持久化失败走了错误收口),
        /// 适配器不再写任何账本/副作用,直接以 failed 结束循环。
        let approvalDecider: @MainActor (ChatToolApprovalPrompt) async -> ChatKernelApprovalDecision?
    }

    private let runtime: ChatToolRuntime
    private let ledger: any IOSAgentRunLedgering
    private var callbacks: Callbacks
    private let nestedApprovalQueue = ChatNestedApprovalQueue()
    private lazy var approvalResolver = ChatKernelApprovalResolver(
        runtime: runtime,
        ledger: ledger,
        onRunResumed: { [weak self] in await self?.resumeRunForApproval() ?? false },
        onDurabilityFailure: { [weak self] in self?.markDurabilityFailure() }
    )

    private func resumeRunForApproval() async -> Bool {
        await callbacks.onRunResumed()
    }

    /// 当前工作消息——B2 执行器的 baseMessagesProvider 锚点。
    /// nonisolated(unsafe):引擎 run 的非隔离入口需接收当前快照;实际读写全部
    /// 发生在 MainActor(适配器方法与 @MainActor baseMessagesProvider),且数组
    /// 值语义保证引擎内部迭代不受适配器覆写影响。
    nonisolated(unsafe) private var working: [UIMessage] = []

    /// 引擎段的驱动子任务——Host 取消手势的取消点(只取消引擎段,适配器自身
    /// 任务保持存活以完成收口)。
    private var driverTask: Task<IOSAgentToolEngineResult, Never>?
    /// 审批后的执行不在引擎 driver 内，仍由同一 run 持有取消权。
    private var approvalExecutionTask: Task<ApprovalResolution, Never>?
    /// Host 取消(CG C cancel 的适配层等价)。取消后:引擎回调一律忽略
    /// (取消填充是权威快照),迟到的引擎结果不回灌。
    private var isCancelledByHost = false
    private var cancellationFailureReason = "User cancelled."
    private var isExecutingTool = false
    private var isDetachedByHost = false
    private var isStoppedByHost: Bool { isCancelledByHost || isDetachedByHost }
    /// 终态只报一次(cancel 与正常终态互斥)。
    private var didReportTerminal = false
    /// A direct nested/approval executor can finish outside the engine's own
    /// terminal recording path. If that durable terminal write fails, cancel
    /// the driver and keep the run recoverable instead of publishing output.
    private var durabilityFailureMessage: String?
    private var toolOutcomeUnknownSignal: IOSToolOutcomeUnknownSignal?
    /// 当前 run 的 citation tracker(run() 开始时取自 request;cancel() 的
    /// remainder 折入需要它)。
    private var activeCitationTracker: IOSMemoryCitationTracker?
    /// onMessagesUpdated 转递的单调序号。引擎在驱动任务内串行回调,Task 跳到
    /// MainActor 后与终态/取消的同步发布存在竞序——序号小的迟到快照不得
    /// 覆盖序号大的权威发布(终态/取消把序号钉到 max,之后一律忽略)。
    nonisolated(unsafe) private var snapshotSeq = 0
    private var lastAppliedSnapshotSeq = 0
    /// The engine invokes text/reasoning hooks serially, while the callbacks
    /// hop to MainActor. Keep only the first claim for the current round and
    /// carry its round number into the hop so an old queued signal cannot land
    /// in a later round.
    nonisolated(unsafe) private var firstVisibleDeltaRound = 0
    nonisolated(unsafe) private var didClaimFirstVisibleDelta = false

    init(
        runtime: ChatToolRuntime,
        ledger: any IOSAgentRunLedgering,
        callbacks: Callbacks = Callbacks()
    ) {
        self.runtime = runtime
        self.ledger = ledger
        self.callbacks = callbacks
    }

    /// 跑完整个 run,返回最终消息。终态经 `callbacks.onRunTerminal` 上报。
    func run(_ request: RunRequest) async -> [UIMessage] {
        // Host 可能在 run() 进入前已取消(preamble 期间):不发任何回调,
        // 直接以初始消息返回(Host 的终态序列走 cancel 分支)。
        if isStoppedByHost { return request.initialMessages }
        durabilityFailureMessage = nil
        toolOutcomeUnknownSignal = nil
        activeCitationTracker = request.citationTracker
        // CGC 首轮头消费:mailbox(:1928)先于 steer(:2141);后续轮边界由
        // 引擎钩子承担(引擎内同序 :1199-1216)。
        working = request.initialMessages
        var initial = request.initialMessages
        if let mailboxDrain = request.mailboxDrain {
            initial.append(contentsOf: (await mailboxDrain()).values)
        }
        if let drainSteer = request.drainSteer {
            initial.append(contentsOf: await drainSteer())
        }
        working = initial

        let promptBox = ChatToolRuntime.IOSForegroundApprovalPromptBox()
        // CGC 的预算按 run 累计(currentToolResumeCount),跨审批恢复不重置。
        let budget = ToolRoundBudget(limit: request.maxToolResumeCount)
        let fullCatalogNames = KernelExecutorNamesBox(
            Set(request.toolExposureBridge.fullToolDeclarations().map(\.name))
        )
        let recipeCatalog = KernelRecipeCatalogSnapshotBox(request.recipeCatalogSnapshot)
        let bridgeBox = UncheckedToolExposureBridgeBox(request.toolExposureBridge)
        let refreshBox = UncheckedRecipeCatalogRefreshBox(request.recipeCatalogRefresh)
        let refreshToolExposure: @MainActor @Sendable () async -> Void = {
            guard let refresh = refreshBox.value,
                  let latest = await refresh(),
                  latest.contentHash != recipeCatalog.snapshot()?.contentHash else { return }
            IOSDynamicToolBridgeRebuilder.apply(snapshot: latest, to: bridgeBox.value)
            recipeCatalog.replace(with: latest)
            fullCatalogNames.replace(with: Set(bridgeBox.value.fullToolDeclarations().map(\.name)))
        }
        // B1: Host 上传准备器(MainActor 闭包值也非 Sendable)与消息一样
        // 盒装,供 @Sendable 引擎钩子跨边界调用。
        let uploadPreparer = UncheckedUploadPreparerBox(request.prepareUploadMessages)
        let toolRuntime = runtime
        let nestedToolRunner = request.nestedToolRunner ?? makeNestedExecToolRunner(
            request: request,
            recipeCatalog: recipeCatalog
        )
        // 执行器的 baseMessages 锚点:引擎在非隔离上下文调钩子,但执行器
        // 读锚点在 @MainActor dispatch 内(dispatch → baseMessagesProvider),
        // 故弱捕获 self 合法且安全。
        let baseMessagesProvider: @MainActor @Sendable () -> [UIMessage] = { [weak self] in
            self?.working ?? []
        }
        let nestedOutcomeUnknownProvider: @MainActor () -> IOSToolOutcomeUnknownSignal? = { [weak self] in
            self?.toolOutcomeUnknownSignal
        }
        let hasAssistantTextCallback = callbacks.onAssistantText != nil
        let hasAssistantReasoningCallback = callbacks.onAssistantReasoning != nil
        let hasFirstVisibleDeltaCallback = callbacks.onAssistantFirstVisibleDelta != nil

        while true {
            if isStoppedByHost { return working }
            // Approval finishers (notably recipe_import) complete outside the
            // engine's post-batch hook. Refresh again at the adapter boundary
            // so the very next model round sees the published catalog.
            await refreshToolExposure()
            // tool_search 的 exposure bridge 跨审批暂停继续存活；每次重建
            // Engine 时都从当前可见目录恢复 params，不能退回首轮工具集。
            let effectiveParams = request.params.replacingTools(
                request.toolExposureBridge.visibleTools()
            )
            let executors = Self.buildExecutors(
                runtime: toolRuntime,
                request: request,
                params: effectiveParams,
                promptBox: promptBox,
                baseMessagesProvider: baseMessagesProvider,
                nestedToolRunner: nestedToolRunner,
                nestedOutcomeUnknownProvider: nestedOutcomeUnknownProvider,
                recipeCatalogSnapshot: recipeCatalog.snapshot()
            )
            // @Sendable 钩子只携带 Sendable 快照(名字集/目录/计数),不捕获执行器表。
            let executorNames = KernelExecutorNamesBox(Set(executors.keys))
            let maxToolResumeCount = request.maxToolResumeCount
            let engine = IOSAgentToolEngine(
                provider: request.provider,
                executors: executors,
                configuration: .init(
                    // 预算由准入钩子精确承担;maxSteps 只是防失控兜底——
                    // 预算内工具轮 + 一次超额轮(准入拒执)必须都放得下。
                    maxSteps: request.maxToolResumeCount + 2,
                    honorApprovalPause: true
                ),
                ledger: ledger,
                ledgerRunId: request.runId,
                phoneAutomaticReasoning: request.phoneAutomaticReasoning,
                phoneSessionIsActive: { @MainActor @Sendable [phoneControl = request.phoneControl] runID in
                    let controller = phoneControl ?? IOSPhoneControlController.shared
                    return controller.handoffState(runID: runID) != nil
                        && controller.hasRequestedSession(runID: runID)
                },
                // 重组闭包经 SE-0420 继承 MainActor 隔离(参数类型非 @Sendable),
                // 运行时由引擎线程同步执行——与后台协调器 :1260 的 executorRebuilder
                // 同一模式(纯装配读取,不触碰可变 UI 状态)。切勿在此
                // assumeIsolated:引擎跑在协作线程池,运行期断言必陷阱。
                executorRebuilder: { newParams in
                    let rebuilt = Self.buildExecutors(
                        runtime: toolRuntime,
                        request: request,
                        params: newParams,
                        promptBox: promptBox,
                        baseMessagesProvider: baseMessagesProvider,
                        nestedToolRunner: nestedToolRunner,
                        nestedOutcomeUnknownProvider: nestedOutcomeUnknownProvider,
                        recipeCatalogSnapshot: recipeCatalog.snapshot()
                    )
                    executorNames.replace(with: Set(rebuilt.keys))
                    return rebuilt
                }
            )

            // 引擎段由驱动子任务承载:Host 取消只取消该子任务(协作式——
            // 执行器跨 actor await 在同一任务内,Task.checkCancellation 直接
            // 命中 gated transport),适配器自身任务存活以完成收口。
            let driver = Task {
                await engine.run(
                    providerSetting: request.providerSetting,
                    messages: working,
                    params: effectiveParams,
                    citationTracker: request.citationTracker,
                    toolExposureBridge: request.toolExposureBridge,
                    refreshToolExposure: refreshToolExposure,
                    mailboxDrain: request.mailboxDrain,
                    drainSteer: request.drainSteer,
                    prepareRequestMessages: { messages in
                        // G7 预算耗尽收尾提示(CG-C :3684 静态同款,upload-only:
                        // 引擎 working 保持权威,提示只进本轮上传)。budget.usedCount
                        // 语义同 currentToolResumeCount。未耗尽直通(绝大多数轮次
                        // 零跨隔离开销);耗尽时经盒跨 MainActor 边界复用 CGC 静态,
                        // 保证提示文案/系统消息形状单一来源(删除 CGC 自循环时
                        // 该静态随 Host 拆分迁出)。
                        var upload = messages
                        if budget.usedCount >= maxToolResumeCount {
                            let inbox = UncheckedMessagesBox(upload)
                            let outbox = await MainActor.run {
                                UncheckedMessagesBox(
                                    ChatGenerationSupport.continuationMessagesAfterToolBudgetExhaustion(
                                        inbox.value,
                                        resumeCount: budget.usedCount,
                                        maxResumeCount: maxToolResumeCount
                                    )
                                )
                            }
                            upload = outbox.value
                        }
                        // B1: Host 的逐轮上传准备(语境注入/压缩/记忆召回),
                        // 序同 CG-C:预算提示先入列,Host 准备再往头部前置,
                        // 最终头部次序 [运行时语境…, 图像提示?, 预算提示, …]。
                        // @MainActor async 闭包需要独立任务跨 actor；driver
                        // 取消时同步取消它，准备阶段才能停止后续辅助请求。
                        if uploadPreparer.value != nil {
                            let inbox = UncheckedMessagesBox(upload)
                            let preparation = Task { @MainActor () throws -> UncheckedMessagesBox in
                                try Task.checkCancellation()
                                guard let prepare = uploadPreparer.value else { return inbox }
                                return UncheckedMessagesBox(try await prepare(inbox.value))
                            }
                            let outbox = try await withTaskCancellationHandler {
                                try await preparation.value
                            } onCancel: {
                                preparation.cancel()
                            }
                            try Task.checkCancellation()
                            upload = outbox.value
                        }
                        return upload
                    },
                    sortPendingToolCalls: { tools in
                        tools.sorted { Self.kindRank(of: $0.toolName) < Self.kindRank(of: $1.toolName) }
                    },
                    preemptToolBatch: { tools in
                        Self.preemptReason(
                            for: tools,
                            executorNames: executorNames.snapshot(),
                            fullCatalogNames: fullCatalogNames.snapshot(),
                            budget: budget,
                            maxToolResumeCount: maxToolResumeCount
                        )
                    },
                    resolveUnexposedToolCall: { tool in
                        Self.guidedSoftFailParts(
                            for: tool,
                            executorNames: executorNames.snapshot(),
                            fullCatalogNames: fullCatalogNames.snapshot()
                        )
                    },
                    onAssistantTurnStarted: { [weak self] in
                        guard let self, !self.isStoppedByHost else { return }
                        // 换轮是 provisional epoch 边界：先使上一轮已排队但尚未
                        // 回到 MainActor 的节流快照失效，再发布新一轮状态。
                        self.snapshotSeq += 1
                        self.lastAppliedSnapshotSeq = self.snapshotSeq
                        self.firstVisibleDeltaRound &+= 1
                        self.didClaimFirstVisibleDelta = false
                        self.isExecutingTool = false
                        self.callbacks.onAssistantTurnStarted()
                    },
                    onAssistantTurnCompleted: { [weak self] messages in
                        let box = UncheckedMessagesBox(messages)
                        return await MainActor.run {
                            guard let self, !self.isStoppedByHost else { return false }
                            self.lastAppliedSnapshotSeq = self.snapshotSeq
                            if self.working != box.value {
                                self.working = box.value
                                self.callbacks.onMessagesUpdated(box.value)
                            }
                            return self.callbacks.onAssistantTurnCompleted(box.value)
                        }
                    },
                    onToolExecutionStarted: { [weak self] toolName, input in
                        guard let self, !self.isStoppedByHost else { return }
                        self.isExecutingTool = true
                        self.callbacks.onToolExecutionStarted(toolName, input)
                    },
                    onAssistantStage: { [weak self] stage in
                        // 引擎从 KMP 流协程串行回调;盒跨边界回 MainActor。
                        let box = UncheckedStageBox(stage)
                        Task { @MainActor [weak self] in
                            guard let self, !self.isStoppedByHost,
                                  self.durabilityFailureMessage == nil else { return }
                            self.callbacks.onAssistantStage(box.value)
                        }
                    },
                    onAssistantText: { [weak self] text in
                        guard let self else { return }
                        if hasFirstVisibleDeltaCallback,
                           let round = self.claimFirstVisibleDeltaRound() {
                            Task { @MainActor [weak self] in
                                guard let self,
                                      !self.isStoppedByHost,
                                      !self.didReportTerminal,
                                      self.durabilityFailureMessage == nil,
                                      self.firstVisibleDeltaRound == round else { return }
                                self.callbacks.onAssistantFirstVisibleDelta?()
                            }
                        }
                        guard hasAssistantTextCallback else { return }
                        Task { @MainActor [weak self] in
                            guard let self, !self.isStoppedByHost,
                                  self.durabilityFailureMessage == nil else { return }
                            self.callbacks.onAssistantText?(text)
                        }
                    },
                    onAssistantReasoning: { [weak self] text in
                        guard let self else { return }
                        if hasFirstVisibleDeltaCallback,
                           let round = self.claimFirstVisibleDeltaRound() {
                            Task { @MainActor [weak self] in
                                guard let self,
                                      !self.isStoppedByHost,
                                      !self.didReportTerminal,
                                      self.durabilityFailureMessage == nil,
                                      self.firstVisibleDeltaRound == round else { return }
                                self.callbacks.onAssistantFirstVisibleDelta?()
                            }
                        }
                        guard hasAssistantReasoningCallback else { return }
                        Task { @MainActor [weak self] in
                            guard let self, !self.isStoppedByHost,
                                  self.durabilityFailureMessage == nil else { return }
                            self.callbacks.onAssistantReasoning?(text)
                        }
                    },
                    onAssistantMessageSnapshot: { [weak self] message in
                        // UIMessage 非 Sendable——与 onMessagesUpdated 同款盒装跳
                        // 主 actor;引擎串行回调保证盒无并发访问。
                        guard let self else { return }
                        self.snapshotSeq += 1
                        let seq = self.snapshotSeq
                        let box = UncheckedMessageSnapshotBox(message)
                        Task { @MainActor [weak self] in
                            guard let self, !self.isStoppedByHost,
                                  self.durabilityFailureMessage == nil,
                                  seq > self.lastAppliedSnapshotSeq else { return }
                            self.lastAppliedSnapshotSeq = seq
                            self.callbacks.onAssistantMessageSnapshot(box.value)
                        }
                    },
                    onMessagesUpdated: { [weak self] messages in
                        // 引擎在非 MainActor 上下文串行回调;序号在此同步递增
                        // (nonisolated(unsafe),与 working 同一纪律),消息经盒
                        // 回到 MainActor 后只应用更新的快照——迟到旧快照不得
                        // 覆盖终态/取消发布。
                        guard let self else { return }
                        self.snapshotSeq += 1
                        let seq = self.snapshotSeq
                        let box = UncheckedMessagesBox(messages)
                        Task { @MainActor [weak self] in
                            guard let self, !self.isStoppedByHost,
                                  self.durabilityFailureMessage == nil,
                                  seq > self.lastAppliedSnapshotSeq else { return }
                            self.lastAppliedSnapshotSeq = seq
                            self.working = box.value
                            self.callbacks.onMessagesUpdated(box.value)
                        }
                    }
                )
            }
            driverTask = driver
            let result = await driver.value
            driverTask = nil
            // Keep completed tool outcomes frozen while accepting only the
            // interrupted assistant snapshot returned by the cancelled driver.
            if isCancelledByHost {
                guard !didReportTerminal else { return working }
                // Cancellation freezes existing tool outcomes. Only a new in-flight
                // assistant turn from the engine may extend that snapshot.
                let existingIds = Set(working.map { $0.id.toHexDashString() })
                working.append(contentsOf: result.messages.filter {
                    $0.role == MessageRole.assistant && !existingIds.contains($0.id.toHexDashString())
                })
                publishCancellation()
                return working
            }
            if isDetachedByHost { return working }
            if let durabilityFailureMessage {
                callbacks.onProviderFailure(durabilityFailureMessage)
                didReportTerminal = true
                callbacks.onRunTerminal(AgentRunStatus.recoveryPending.wireName)
                return working
            }
            if let unknown = toolOutcomeUnknownSignal ?? result.toolOutcomeUnknown {
                working = result.messages
                lastAppliedSnapshotSeq = .max
                callbacks.onMessagesUpdated(result.messages)
                callbacks.onToolOutcomeUnknown(unknown)
                didReportTerminal = true
                callbacks.onRunTerminal(AgentRunStatus.outcomeUnknown.wireName)
                return working
            }

            if result.hitOutputLimit {
                // A4 截断收口(CG-C completeTruncatedStream :2802 语义,适配器侧
                // 后处理,不动引擎的后台语义):未决工具原地失败化 + 追加输出上限
                // 提示消息,单次发布,终态 failed。
                var final = result.messages
                if runtime.hasUnresolvedToolCall(in: final) {
                    final = runtime.messagesByFailingPendingToolCalls(
                        in: final,
                        failureReason: "The model output ended before the tool call completed."
                    )
                }
                final.append(ChatGenerationSupport.outputLimitNotice())
                working = final
                lastAppliedSnapshotSeq = .max
                callbacks.onMessagesUpdated(final)
                didReportTerminal = true
                callbacks.onRunTerminal(AgentRunStatus.failed.wireName)
                return final
            }

            if result.hitStepLimit {
                // 限步终止不能把空 output 工具留进持久化转录；否则冷启动恢复
                // 会把它当成尚可执行的历史调用。
                var final = result.messages
                if runtime.hasUnresolvedToolCall(in: final) {
                    final = runtime.messagesByFailingPendingToolCalls(
                        in: final,
                        failureReason: "Generation stopped after reaching the tool step limit."
                    )
                }
                working = final
                lastAppliedSnapshotSeq = .max
                callbacks.onMessagesUpdated(final)
                didReportTerminal = true
                callbacks.onRunTerminal(AgentRunStatus.failed.wireName)
                return final
            }

            working = result.messages
            // 终态发布是权威快照:序号钉死,迟到的引擎转递一律忽略。
            lastAppliedSnapshotSeq = .max
            callbacks.onMessagesUpdated(result.messages)

            if let approval = result.pendingApproval {
                let didContinue = await handleApproval(
                    approval,
                    request: request,
                    params: effectiveParams,
                    promptBox: promptBox
                )
                // 审批等待期间 Host 取消:取消优先,不再走失败收口。
                if isStoppedByHost { return working }
                if !didContinue {
                    didReportTerminal = true
                    if let unknown = toolOutcomeUnknownSignal {
                        callbacks.onToolOutcomeUnknown(unknown)
                        callbacks.onRunTerminal(AgentRunStatus.outcomeUnknown.wireName)
                    } else if let durabilityFailureMessage {
                        callbacks.onProviderFailure(durabilityFailureMessage)
                        callbacks.onRunTerminal(AgentRunStatus.recoveryPending.wireName)
                    } else {
                        callbacks.onRunTerminal(AgentRunStatus.failed.wireName)
                    }
                    return working
                }
                continue
            }

            if let failure = result.durabilityFailureMessage {
                callbacks.onProviderFailure(failure)
            } else if let failure = result.providerFailureMessage {
                // B1: provider/上传准备失败——先把原始错误串交给 Host(产出
                // CG-C presentStreamError 同款用户向错误泡),再报 failed。
                // hitOutputLimit 已在上方 A4 分支提前返回,不会到达这里。
                callbacks.onProviderFailure(failure)
            }
            if result.yielded { callbacks.onForegroundYield() }
            didReportTerminal = true
            callbacks.onRunTerminal(Self.terminalWireName(of: result))
            return result.messages
        }
    }

    /// Called only from the engine's serial streaming callbacks. The state is
    /// deliberately nonisolated(unsafe), matching snapshotSeq above; the
    /// round-start callback is awaited on MainActor before the next delta.
    private nonisolated func claimFirstVisibleDeltaRound() -> Int? {
        guard !didClaimFirstVisibleDelta else { return nil }
        didClaimFirstVisibleDelta = true
        return firstVisibleDeltaRound
    }

    // MARK: - Host 取消

    /// CGC cancel(:1438-1581)的适配层等价:
    /// 1) 未决工具原地填调用方给出的取消原因结构化 denied JSON,
    ///    取消填充是权威快照;
    /// 2) citation remainder 折入取消快照(:1490 flushingCitationTracker 同款——
    ///    引擎段被腰斩,其终态 flush 随迟到结果一起被丢弃,这里补上);
    /// 3) 取消引擎驱动子任务——执行中的工具经 CancellationError 走
    ///    dispatchSearchToolCall 的 catch,产出 cancelled JSON 的 .completed,
    ///    当前模型流等待驱动退出取回准确尾部；工具执行期已有完整 assistant，
    ///    直接发布取消快照，不等待工具返回;
    /// 4) 终态 cancelled 只报一次；无 driver 的审批等待即时收口。
    func cancel(failureReason: String = "User cancelled.") {
        guard !didReportTerminal, !isStoppedByHost else { return }
        isCancelledByHost = true
        cancellationFailureReason = failureReason
        approvalExecutionTask?.cancel()
        if let driverTask {
            // A streaming driver returns the exact terminal accumulator,
            // including any tail absent from the throttled UI snapshot.
            driverTask.cancel()
            if isExecutingTool {
                // The assistant turn is already authoritative before execution;
                // a tool that ignores cancellation must not delay its UI terminal.
                publishCancellation()
            }
            return
        }
        publishCancellation()
    }

    private func publishCancellation() {
        guard !didReportTerminal else { return }
        var filled = runtime.messagesByFailingPendingToolCalls(
            in: working,
            failureReason: cancellationFailureReason,
            denied: true
        )
        if let tracker = activeCitationTracker {
            let remainder = tracker.finish()
            if !remainder.isEmpty {
                filled = IOSMemoryCitationTracker.appendingCitationRemainder(remainder, to: filled)
            }
        }
        working = filled
        lastAppliedSnapshotSeq = .max
        callbacks.onMessagesUpdated(filled)
        didReportTerminal = true
        callbacks.onRunTerminal(AgentRunStatus.cancelled.wireName)
    }

    /// 后台协调器成功接管后只停止前台 driver，不发布 cancelled/failed，
    /// durable run 与可见 transcript 的终态所有权同时转移给后台。
    func detachForBackgroundHandoff() {
        guard !didReportTerminal, !isStoppedByHost else { return }
        isDetachedByHost = true
        lastAppliedSnapshotSeq = .max
        driverTask?.cancel()
        driverTask = nil
        approvalExecutionTask?.cancel()
    }

    // MARK: - 执行器装配

    /// 纯装配(读当前可见集 + 构造执行器闭包),无可变状态写入。重组点由
    /// 引擎线程同步调用(隔离经 SE-0420 静态继承、运行期不强制),与后台
    /// 协调器的 executorRebuilder 同模式。
    private static func buildExecutors(
        runtime: ChatToolRuntime,
        request: RunRequest,
        params: TextGenerationParams,
        promptBox: ChatToolRuntime.IOSForegroundApprovalPromptBox,
        baseMessagesProvider: @escaping @MainActor @Sendable () -> [UIMessage],
        nestedToolRunner: IosExecNestedToolRunner?,
        nestedOutcomeUnknownProvider: @escaping @MainActor () -> IOSToolOutcomeUnknownSignal?,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?
    ) -> [String: any IOSToolExecutor] {
        runtime.foregroundToolExecutors(
            providerSetting: request.providerSetting,
            params: params,
            runId: request.runId,
            startedAt: request.startedAt,
            inputDigest: request.inputDigest,
            conversationId: request.conversationId,
            toolExposureBridge: request.toolExposureBridge,
            baseMessagesProvider: baseMessagesProvider,
            approvalPromptBox: promptBox,
            nestedToolRunner: nestedToolRunner,
            nestedOutcomeUnknownProvider: nestedOutcomeUnknownProvider,
            recipeCatalogSnapshot: recipeCatalogSnapshot,
            executionPolicy: request.executionPolicy,
            phoneControl: request.phoneControl
        )
    }

    /// `exec` 内调用仍走当前 Kernel 的真实 runtime/ledger/审批边界；白名单
    /// 每次调用时从 exposure bridge 读取，避免 tool_search 后使用旧目录。
    private func makeNestedExecToolRunner(
        request: RunRequest,
        recipeCatalog: KernelRecipeCatalogSnapshotBox
    ) -> IosExecNestedToolRunner {
        { [weak self] name, arguments in
            guard let self else {
                return Self.nestedExecToolUnavailable(name: name)
            }
            guard self.toolOutcomeUnknownSignal == nil else {
                return Self.nestedExecToolUnavailable(name: name)
            }
            return await self.runNestedExecTool(
                name: name,
                arguments: arguments,
                request: request,
                recipeCatalogSnapshot: recipeCatalog.snapshot()
            )
        }
    }

#if DEBUG
    func nestedExecToolRunnerForTesting(request: RunRequest) -> IosExecNestedToolRunner {
        makeNestedExecToolRunner(
            request: request,
            recipeCatalog: KernelRecipeCatalogSnapshotBox(request.recipeCatalogSnapshot)
        )
    }
#endif

    private func runNestedExecTool(
        name: String,
        arguments: String,
        request: RunRequest,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?
    ) async -> String {
        let whitelist = ChatToolRuntime.execNestedToolWhitelist(
            visibleToolNames: Set(request.toolExposureBridge.visibleTools().map(\.name))
        )
        let toolCall = UIMessagePart.Tool(
            toolCallId: "exec-nested-\(UUID().uuidString)",
            toolName: name,
            input: arguments,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let syntheticMessage = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [toolCall],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        guard whitelist.contains(name),
              let pendingToolCall = runtime.nextPendingToolCall(
                in: [syntheticMessage],
                availableToolNames: whitelist
              ) else {
            return Self.nestedExecToolUnavailable(name: name)
        }
        let effectiveParams = request.params.replacingTools(
            request.toolExposureBridge.visibleTools()
        )
        let pending = ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: request.providerSetting,
            params: effectiveParams,
            runId: request.runId,
            startedAt: request.startedAt,
            inputDigest: request.inputDigest,
            conversationId: request.conversationId,
            baseMessages: [syntheticMessage],
            executionPolicy: request.executionPolicy,
            recentUserTexts: working.filter { $0.role == MessageRole.user }.suffix(3).map { $0.toText() }
        )
        // forChatKind 只按粗粒度 kind 分类；工具名可再细分（如 ssh_profile_list
        // 走 advanced 但是只读），因此这里以 forToolName 为准。
        let effectClass = IOSToolEffectClassMapping.forToolName(name, input: arguments)
        guard await ledger.recordToolCallStarted(
            runId: request.runId,
            toolCallId: toolCall.toolCallId,
            toolName: name,
            argsDigest: chatInputDigest(for: arguments),
            effectClass: effectClass
        ) else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: name,
                reason: "无法保存工具执行前状态，请检查存储空间后重试。",
                status: "failed"
            )
        }

        switch await runtime.execute(
            pendingToolCall,
            context: pending,
            toolExposureBridge: request.toolExposureBridge,
            nestedToolRunner: request.nestedToolRunner,
            recipeCatalogSnapshot: recipeCatalogSnapshot
        ) {
        case .completed(let messages):
            guard await approvalResolver.recordToolTerminal(
                runId: request.runId,
                toolCallId: toolCall.toolCallId,
                outcome: "completed",
                messages: messages
            ) else { return Self.nestedExecToolUnavailable(name: name) }
            return Self.nestedExecToolOutputText(from: messages, toolCallId: toolCall.toolCallId)
        case .waitingForApproval(let prompt):
            guard await ledger.recordToolCallFinished(
                runId: request.runId,
                toolCallId: toolCall.toolCallId,
                outcome: "paused_for_approval"
            ) else {
                markDurabilityFailure()
                return Self.nestedExecToolUnavailable(name: name)
            }
            return await nestedApprovalQueue.withTurn {
                await resolveNestedExecApproval(
                    prompt,
                    pending: pending,
                    request: request
                )
            }
        case .durabilityFailure:
            markDurabilityFailure()
            return Self.nestedExecToolUnavailable(name: name)
        case .outcomeUnknown(let messages):
            guard await ledger.recordToolCallRecoveryTransition(
                runId: request.runId,
                toolCallId: toolCall.toolCallId,
                expected: .started,
                to: .outcomeUnknown,
                outcome: "executor_reported_unknown_after_action"
            ) else {
                markDurabilityFailure()
                return Self.nestedExecToolUnavailable(name: name)
            }
            toolOutcomeUnknownSignal = IOSToolOutcomeUnknownSignal(
                toolCallId: toolCall.toolCallId,
                toolName: toolCall.toolName
            )
            return Self.nestedExecToolOutputText(from: messages, toolCallId: toolCall.toolCallId)
        }
    }

    private func resolveNestedExecApproval(
        _ initialPrompt: ChatToolApprovalPrompt,
        pending: ChatPendingToolApproval,
        request: RunRequest
    ) async -> String {
        var prompt = initialPrompt
        while true {
            let candidates = approvalResolver.takePreparedCandidates(
                for: prompt,
                toolCallId: pending.toolCall.toolCallId
            )
            callbacks.onAwaitingPermission(pending.toolCall.toolCallId)
            callbacks.onApprovalPrompt(prompt)
            guard let decision = await request.approvalDecider(prompt),
                  !isStoppedByHost else {
                return Self.nestedExecToolUnavailable(name: pending.toolCall.toolName)
            }
            switch await resolveApproval(
                prompt: prompt,
                decision: decision,
                pending: pending,
                candidates: candidates,
                request: request
            ) {
            case .resumed(let messages):
                return Self.nestedExecToolOutputText(
                    from: messages,
                    toolCallId: pending.toolCall.toolCallId
                )
            case .rePause(let nextPrompt):
                prompt = nextPrompt
            case .outcomeUnknown(let messages):
                toolOutcomeUnknownSignal = IOSToolOutcomeUnknownSignal(
                    toolCallId: pending.toolCall.toolCallId,
                    toolName: pending.toolCall.toolName
                )
                return Self.nestedExecToolOutputText(
                    from: messages,
                    toolCallId: pending.toolCall.toolCallId
                )
            case .failed:
                return Self.nestedExecToolUnavailable(name: pending.toolCall.toolName)
            }
        }
    }

    private static func nestedExecToolUnavailable(name: String) -> String {
        ChatToolOutputFormatter.toolFailureJSON(
            toolName: name,
            reason: "tool not available in exec: \(name)",
            status: "failed"
        )
    }

    private static func nestedExecToolOutputText(
        from messages: [UIMessage],
        toolCallId: String
    ) -> String {
        for message in messages where message.role == MessageRole.assistant {
            for part in message.parts {
                guard let tool = part as? UIMessagePart.Tool,
                      tool.toolCallId == toolCallId else { continue }
                return tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
            }
        }
        return #"{"ok":false,"error":"nested tool output not found"}"#
    }

    // MARK: - 审批暂停/恢复

    typealias PreparedApprovalCandidates = ChatKernelApprovalResolver.PreparedApprovalCandidates
    typealias ApprovalResolution = ChatKernelApprovalResolver.ApprovalResolution

    /// 返回 false = 恢复失败,run 以 failed 收口。
    private func handleApproval(
        _ approval: IOSPendingToolApproval,
        request: RunRequest,
        params: TextGenerationParams,
        promptBox: ChatToolRuntime.IOSForegroundApprovalPromptBox
    ) async -> Bool {
        var prompt: ChatToolApprovalPrompt? = promptBox.take(approval.toolCallId)
        // recipe step 的 pausedForNextStep 带新审批请求重进本循环(CG-C
        // :4176-4189:同一 tool call 不闭合,Finished(paused_for_approval) 后再发卡)。
        while let current = prompt {
            let candidates = approvalResolver.takePreparedCandidates(for: current, toolCallId: approval.toolCallId)
            // CGC pauseForApproval 顺序(:3800 先于 :3873):先持久化等待态,再发卡。
            callbacks.onAwaitingPermission(approval.toolCallId)
            callbacks.onApprovalPrompt(current)
            // 返回 nil = Host 已自行终态化(暂停持久化失败等):不再写任何
            // 账本/副作用,直接以 failed 结束循环。
            guard let decision = await request.approvalDecider(current) else { return false }
            // 审批等待期间 Host 取消:cancel() 已把未决工具原地填 "User cancelled."
            // 并上报终态;此处不得再写账本 Started/执行 finisher。
            guard !isStoppedByHost else { return false }
            guard let toolPart = Self.toolPart(toolCallId: approval.toolCallId, in: working) else {
                return false
            }
            let pending = ChatPendingToolApproval(
                toolCall: toolPart,
                providerSetting: request.providerSetting,
                params: params,
                runId: request.runId,
                startedAt: request.startedAt,
                inputDigest: request.inputDigest,
                conversationId: request.conversationId,
                baseMessages: working,
                executionPolicy: request.executionPolicy
            )
            switch await resolveApproval(
                prompt: current,
                decision: decision,
                pending: pending,
                candidates: candidates,
                request: request
            ) {
            case .resumed(let messages):
                working = messages
                callbacks.onMessagesUpdated(messages)
                return true
            case .rePause(let nextPrompt):
                prompt = nextPrompt
            case .outcomeUnknown(let messages):
                working = messages
                callbacks.onMessagesUpdated(messages)
                toolOutcomeUnknownSignal = IOSToolOutcomeUnknownSignal(
                    toolCallId: approval.toolCallId,
                    toolName: approval.toolName
                )
                return false
            case .failed:
                return false
            }
        }
        // 执行器命中 needsApproval 必然已登记;缺失即适配层 bug,诚实失败。
        return false
    }

    func resolveApproval(
        prompt: ChatToolApprovalPrompt,
        decision: ChatKernelApprovalDecision,
        pending: ChatPendingToolApproval,
        candidates: PreparedApprovalCandidates,
        request: RunRequest
    ) async -> ApprovalResolution {
        guard !isStoppedByHost else { return .failed }
        let execution = Task { @MainActor in
            await approvalResolver.resolveApproval(
                prompt: prompt, decision: decision, pending: pending,
                candidates: candidates, request: request
            )
        }
        approvalExecutionTask = execution
        let resolution = await execution.value
        approvalExecutionTask = nil
        // 已发出的工具仍记录真实终态；迟到结果不能夺回取消或后台交接的快照。
        guard !isStoppedByHost else { return .failed }
        return resolution
    }

    private func markDurabilityFailure() {
        if durabilityFailureMessage == nil {
            durabilityFailureMessage = "tool result ledger write failed"
        }
        driverTask?.cancel()
    }

    // MARK: - 分类与终态映射

    /// kind 优先级序,与 `ChatToolRuntime.nextPendingToolCall` 的扫描序一致。
    /// 未注册名排最后(它们不进入执行,由 preempt/resolve 钩子处理)。
    private nonisolated static func kindRank(of toolName: String) -> Int {
        switch toolName {
        case "tool_search", "tools_list": return 0
        default: break
        }
        if IOSSearchExecutor.supportedToolNames.contains(toolName) { return 1 }
        if IOSWorkspaceToolCatalog.supportedToolNames.contains(toolName) { return 2 }
        if IOSAgentTerminalToolCatalog.supportedToolNames.contains(toolName) { return 3 }
        if webMountToolNames.contains(toolName) { return 4 }
        if toolName == "memory_tool" { return 5 }
        if toolName == "generate_image" { return 6 }
        if toolName == "ask_user" { return 7 }
        if ["session_search", "session_read", "history_search", "history_fetch", "runtime_status"].contains(toolName) { return 8 }
        return 9
    }

    /// `kindRank` runs once per comparator call while ordering a tool batch.
    /// Keep this union out of the comparator so a parallel tool batch does not
    /// allocate the same set repeatedly; both source sets are immutable catalogs.
    private nonisolated static let webMountToolNames =
        IOSWebMountToolCatalog.supportedToolNames.union(IOSWebMountToolCatalog.unsupportedToolNames)

    /// CGC 的轮后裁定:彻底未知的名字(全目录之外)整批硬失败;预算耗尽
    /// 整批失败化。返回 nil = 放行。
    private nonisolated static func preemptReason(
        for tools: [UIMessagePart.Tool],
        executorNames: Set<String>,
        fullCatalogNames: Set<String>,
        budget: ToolRoundBudget,
        maxToolResumeCount: Int
    ) -> String? {
        let allUnknown = tools.allSatisfy {
            !executorNames.contains($0.toolName) && !fullCatalogNames.contains($0.toolName)
        }
        if allUnknown {
            return "工具调用未执行:该工具当前未启用或不可执行。请在设置中启用对应能力后重试。"
        }
        if !budget.admit() {
            return "工具调用未执行:已达到本轮工具循环上限(\(maxToolResumeCount) 次)。请继续对话或拆分任务后重试。"
        }
        return nil
    }

    /// 目录有、可见集没有 → 引导软失败输出(CG-C P0-a Fix B 同款文案语义)。
    private nonisolated static func guidedSoftFailParts(
        for tool: UIMessagePart.Tool,
        executorNames: Set<String>,
        fullCatalogNames: Set<String>
    ) -> [UIMessagePart]? {
        guard !executorNames.contains(tool.toolName),
              fullCatalogNames.contains(tool.toolName) else { return nil }
        return [UIMessagePart.Text(
            text: """
            {"ok":false,"error":"tool_not_exposed","tool":"\(tool.toolName)","message":"该工具在当前轮未暴露。请先调用 tool_search 发现并重试。","status":"failed"}
            """,
            metadata: nil
        )]
    }

    private nonisolated static func terminalWireName(of result: IOSAgentToolEngineResult) -> String {
        if result.durabilityFailureMessage != nil { return AgentRunStatus.recoveryPending.wireName }
        if result.wasCancelled { return AgentRunStatus.cancelled.wireName }
        if result.guardStopped { return AgentRunStatus.failed.wireName }
        if result.hitStepLimit { return AgentRunStatus.failed.wireName }
        if result.hitOutputLimit { return AgentRunStatus.failed.wireName }
        if result.providerFailureMessage != nil { return AgentRunStatus.failed.wireName }
        return AgentRunStatus.completed.wireName
    }

    nonisolated static func toolPart(toolCallId: String, in messages: [UIMessage]) -> UIMessagePart.Tool? {
        for message in messages {
            for part in message.parts {
                if let tool = part as? UIMessagePart.Tool, tool.toolCallId == toolCallId {
                    return tool
                }
            }
        }
        return nil
    }

    /// run 级预算计数器(跨引擎多次 run 调用累计,@Sendable 钩子内可变)。
    private final class ToolRoundBudget: @unchecked Sendable {
        private var used = 0
        private let limit: Int
        init(limit: Int) { self.limit = limit }
        /// CGC 语义:guard count < limit 再 count += 1。
        func admit() -> Bool {
            guard used < limit else { return false }
            used += 1
            return true
        }
        /// G7 收尾提示的判定读数(语义同 CGC currentToolResumeCount)。
        var usedCount: Int { used }
    }
}

/// 引擎 onMessagesUpdated 从非 MainActor 上下文回调;KMP 消息非 Sendable,
/// 照 IOSMailboxDrainResult 先例用盒跨边界(引擎侧一次性交出,不再持有)。
private struct UncheckedMessagesBox: @unchecked Sendable {
    let value: [UIMessage]
    init(_ value: [UIMessage]) { self.value = value }
}

/// onAssistantStage 同款跨边界盒(KMP 枚举非 Sendable;引擎串行回调,
/// 盒一次性交出)。
private struct UncheckedStageBox: @unchecked Sendable {
    let value: AgentActivityStage
    init(_ value: AgentActivityStage) { self.value = value }
}

/// Host 上传准备闭包(@MainActor async throws)的跨边界盒——闭包值本身
/// 也非 Sendable,与消息同纪律盒装。
private struct UncheckedUploadPreparerBox: @unchecked Sendable {
    let value: (@MainActor ([UIMessage]) async throws -> [UIMessage])?
    init(_ value: (@MainActor ([UIMessage]) async throws -> [UIMessage])?) { self.value = value }
}

/// onAssistantMessageSnapshot 同款跨边界盒(单条 KMP 消息非 Sendable;
/// 引擎串行回调,盒一次性交出)。
private struct UncheckedMessageSnapshotBox: @unchecked Sendable {
    let value: UIMessage
    init(_ value: UIMessage) { self.value = value }
}

private struct UncheckedToolExposureBridgeBox: @unchecked Sendable {
    let value: IosToolExposureBridge
    init(_ value: IosToolExposureBridge) { self.value = value }
}

private struct UncheckedRecipeCatalogRefreshBox: @unchecked Sendable {
    let value: (@MainActor () async -> IOSDynamicToolCatalogSnapshot?)?
    init(_ value: (@MainActor () async -> IOSDynamicToolCatalogSnapshot?)?) {
        self.value = value
    }
}

private final class KernelRecipeCatalogSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: IOSDynamicToolCatalogSnapshot?

    init(_ value: IOSDynamicToolCatalogSnapshot?) {
        self.value = value
    }

    func replace(with value: IOSDynamicToolCatalogSnapshot?) {
        lock.withLock { self.value = value }
    }

    func snapshot() -> IOSDynamicToolCatalogSnapshot? {
        lock.withLock { value }
    }
}

/// Engine 内一次 `tool_search` 可同步重建 executor table；软失败/硬失败
/// 两个 @Sendable 判定也必须读取同一版名字集，不能捕获首轮快照。
private final class KernelExecutorNamesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String>

    init(_ names: Set<String>) {
        self.names = names
    }

    func replace(with names: Set<String>) {
        lock.withLock { self.names = names }
    }

    func snapshot() -> Set<String> {
        lock.withLock { names }
    }
}
