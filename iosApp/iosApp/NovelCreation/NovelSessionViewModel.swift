import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class NovelSessionViewModel {
    var mode: NovelSessionMode = .discussPlan
    var granularity: NovelGenerationGranularity = .wholeChapter
    var binding: NovelSessionBinding?
    var transientTail: NovelSessionTransientTail? {
        didSet {
            let next = NovelSessionTailChromeState(transientTail)
            if transientTailChromeState != next {
                transientTailChromeState = next
            }
            latestTailLagAllowance = transientTail?.lagAllowance ?? 1
        }
    }
    /// Low-frequency presentation facts for chrome outside the transcript. The
    /// stream body remains observed only by the transcript child.
    private(set) var transientTailChromeState = NovelSessionTailChromeState(nil)
    @ObservationIgnored private(set) var latestTailLagAllowance: Double = 1
    var sessionStartingRunID: NovelRunID?
    var isPerformingAction = false
    var stoppingRunID: NovelRunID?
    var retryingRunID: NovelRunID?
    var cloningCandidateID: NovelCandidateID?
    var undoingCheckpointID: NovelCheckpointID?
    /// 正在采用润色版的候选 ID：气泡据此显示加载指示器。
    var adoptingPolishCandidateID: NovelCandidateID?
    var operationErrorMessage: String?
    var refreshErrorMessage: String?
    var lastFailure: NovelFailure?
    var polishRetryTransactionID: NovelPendingOperationID?
    var batchPolishProgressStorage: NovelBatchPolishProgress?

    var batchPolishProgress: NovelBatchPolishProgress? {
        guard let progress = batchPolishProgressStorage,
              progress.binding == binding,
              snapshotMatchesBinding else { return nil }
        return progress
    }

    @ObservationIgnored let workspace: NovelCreationViewModel
    @ObservationIgnored var consumerTask: Task<Void, Never>?
    @ObservationIgnored var consumerID: UUID?
    @ObservationIgnored var attachAttemptID: UUID?
    @ObservationIgnored var attachingRunID: NovelRunID?
    @ObservationIgnored var attachingBindingToken: UUID?
    @ObservationIgnored var consumerAttachmentDesired = true
    @ObservationIgnored var bindingToken = UUID()
    @ObservationIgnored var currentRunDraft: NovelSessionRunDraft?
    @ObservationIgnored var lastRetryDraft: NovelSessionRunDraft?
    @ObservationIgnored var lastRetryRunID: NovelRunID?
    @ObservationIgnored var lastStartFailure: Error?
    @ObservationIgnored var transientRunRecord: NovelActiveRunRecord?
    var terminalAwaitingRefresh = false
    @ObservationIgnored var cancelledStartRunIDs: Set<NovelRunID> = []
    var answeringAskUserMessageID: NovelMessageID?
    /// Session-local card close after 写入正文. Not a durable message; leaving
    /// the project drops it. Avoids starting a follow-up model turn that locks the UI.
    var locallyResolvedAskUser: [NovelMessageID: NovelAskUserResponse] = [:] {
        didSet { localAskUserRevision &+= 1 }
    }
    var localAskUserRevision: UInt64 = 0
    @ObservationIgnored var sessionActionOwnerID: UUID?
    @ObservationIgnored var polishRetryTask: Task<Void, Never>?
    @ObservationIgnored var polishRetryTaskBinding: NovelSessionBinding?
    @ObservationIgnored var batchPolishTask: Task<Void, Never>?
    @ObservationIgnored var batchPolishTaskBinding: NovelSessionBinding?
    @ObservationIgnored var batchPolishOwnedRunID: NovelRunID?
    @ObservationIgnored var batchPolishCancellationReason: NovelRunInterruptionReason = .user
    /// 批量循环自己发起单章润色时短暂置真,让 `canStart` 放行——否则折进 `isBusy` 的
    /// `isBatchPolishing` 会把批量自己的 `start` 也挡掉。只在 start 握手期间为真。
    @ObservationIgnored var isBatchStartingRun = false
    /// 与 `batchPolishProgressStorage` 一样可观察，面板才能跟相位刷新。
    var ghostwriteProgressStorage: NovelGhostwriteProgress?
    /// 面板选择的目标章数（1...10）；开跑时写入 progress。
    var ghostwriteTargetChapterCount: Int = NovelGhostwriteBatch.minChapterCount
    @ObservationIgnored var ghostwriteTask: Task<Void, Never>?
    @ObservationIgnored var ghostwriteTaskBinding: NovelSessionBinding?
    @ObservationIgnored var ghostwriteBackgroundLeaseOwnerID: UUID?
    @ObservationIgnored var ghostwriteBackgroundExpirationOwnerID: UUID?
    @ObservationIgnored var ghostwriteOwnedRunID: NovelRunID?
    /// pause / 离页取消时置 true：catch 不得把本批标成 `.cancelled`（会丢续跑与 sidecar）。
    @ObservationIgnored var ghostwriteCancelAsUserPause = false
    /// 用户点「结束」整批：catch 必须落到 `.cancelled`，不得收成可续的暂停。
    @ObservationIgnored var ghostwriteAbandonBatch = false
    /// 代笔 pipeline 自己发起整章时短暂置真，避免 `isGhostwriting` 折进 `isBusy` 挡掉自己的 start。
    @ObservationIgnored var isGhostwriteStartingRun = false
    @ObservationIgnored var projectionCache: NovelSessionProjectionCacheEntry?
    @ObservationIgnored var projectionBuildTask: Task<Bool, Never>?
    @ObservationIgnored var projectionBuildKey: NovelSessionProjectionCacheKey?
    @ObservationIgnored var projectionBuildID: UUID?
    @ObservationIgnored var projectionExpandedArchiveIDs: Set<NovelMessageID> = []
    var projectionRevision: UInt64 = 0
    @ObservationIgnored var pendingCharacterIdentityMentionsCache:
        NovelCharacterIdentityMentionsCacheEntry?
    @ObservationIgnored var characterIdentityCardsCache:
        NovelCharacterIdentityCardsCacheEntry?
    @ObservationIgnored var characterIdentityChoicesCache:
        (projectRevision: Int64, configRevision: Int64, branchID: NovelBranchID,
         stateSnapshotID: NovelStateSnapshotID,
         value: [(material: NovelMaterialRecord, title: String)])?
    @ObservationIgnored var latestContextReceiptCache:
        (projectID: NovelProjectID, revision: Int64, branchID: NovelBranchID,
         value: NovelInjectionReceiptRecord?)?
    @ObservationIgnored var archivableDiscussionCache:
        (sessionID: NovelSessionID, revision: Int64, archiveCursor: NovelSessionCursor?,
         value: Bool)?
    /// Session-open staging: body must not pull secondary chrome until this advances.
    var loadStage: NovelSessionLoadStage = .idle
#if DEBUG
    @ObservationIgnored var fullProjectionBuildCountForTesting = 0
#endif
    @ObservationIgnored var presentationBuffer: NovelSessionPresentationBuffer?
    /// Quick Start keeps its structured transport text separate from the user-facing tail.
    /// Only the strict terminal decoder is allowed to commit proposal records.
    @ObservationIgnored var quickStartStructuredContent: String?
    @ObservationIgnored var characterProposalStructuredContent: String?
    @ObservationIgnored var quickStartStructuredPresentationDirty = false
    @ObservationIgnored var characterProposalStructuredPresentationDirty = false
    @ObservationIgnored var presentationFlushTask: Task<Void, Never>?
    /// 思考流 48ms 拍合并（与正文 presentationFlush 同源时钟）：网络 chunk 先并入
    /// pendingReasoningText，每拍一次合并进 row.reasoningContent。卡片内优化
    /// （尾段整体淡入、sizeThatFades 去 layoutIfNeeded、内部滚动 540pt/s 限速、
    /// cadence 门禁 p95≤40ms）都以「每拍一次 append」为前提——逐 chunk 直上 UI 时
    /// 每个网络 chunk 都触发整行重建+测量（真机思考框整体卡顿，探针实测 p95 88ms/
    /// max 1.38s）。只影响呈现节奏，不动 lifecycle broadcast 语义与 storage。
    @ObservationIgnored var reasoningFlushTask: Task<Void, Never>?
    @ObservationIgnored var reasoningFlushToken = UUID()
    @ObservationIgnored var pendingReasoningText: String?
    /// 视图已为不可见的流式尾部持有冻结快照时为真：逐拍发布只会让转录区
    /// 整体重算却不产生可见变化。节拍游标照常推进，恢复时一次发布。
    @ObservationIgnored var isTailPresentationSuspended = false
    /// Once visible output has started, later thought deltas must not reopen
    /// the live thinking card (Gemini 3.7 / tool-loop often emit thoughts after
    /// the reply is already on screen).
    @ObservationIgnored var reasoningClosedAfterVisibleOutput = false
    /// 终态 tail 的延迟退役任务:完成后保留 tail 一个静窗再清空,避免完成瞬间整屏一跳。
    @ObservationIgnored var terminalTailRetirementTask: Task<Void, Never>?
    /// 终态 tail 退役前的静窗时长,默认与底部跟随的 terminalQuietDelay 对齐(滚动落定
    /// 与 tail 退役同步)。测试可注入 0 走立即退役的快路径,保持旧的「完成即清空」契约。
    @ObservationIgnored let terminalQuietDelay: TimeInterval
    @ObservationIgnored private let composerDefaults: UserDefaults
    /// 批量润色等待候选时的「run 落定」宽限窗:activeRunID 在 terminalAwaitingRefresh
    /// 窗口会短暂为 nil,落定判失败前必须先过这个窗。测试可注入小值加快失败用例。
    @ObservationIgnored let batchPolishSettleGrace: TimeInterval
    @ObservationIgnored let batchPolishCandidateTimeout: TimeInterval

    static let presentationFlushDelayNanos: UInt64 = 48_000_000

    /// 由会话视图按其冻结快照状态驱动。恢复时立即发布屏外累积的正文节拍与思考，
    /// 与未暂停时回到可见区看到的内容一致。
    func setTailPresentationSuspended(_ suspended: Bool) {
        guard isTailPresentationSuspended != suspended else { return }
        isTailPresentationSuspended = suspended
        guard !suspended, let current = transientTail else { return }
        let token = bindingToken
        if pendingReasoningText != nil {
            flushPendingReasoning(runID: current.runID, token: token, finishing: false)
        }
        if presentationBuffer != nil
            || quickStartStructuredPresentationDirty
            || characterProposalStructuredPresentationDirty {
            flushPendingPresentation(
                runID: current.runID,
                messageID: current.messageID,
                token: token
            )
        }
    }

    init(
        workspace: NovelCreationViewModel,
        terminalQuietDelay: TimeInterval = NovelSessionBottomFollowPolicy.terminalQuietDelay,
        batchPolishSettleGrace: TimeInterval = 5,
        batchPolishCandidateTimeout: TimeInterval = 900,
        composerDefaults: UserDefaults = .standard
    ) {
        self.workspace = workspace
        self.terminalQuietDelay = terminalQuietDelay
        self.batchPolishSettleGrace = batchPolishSettleGrace
        self.batchPolishCandidateTimeout = batchPolishCandidateTimeout
        self.composerDefaults = composerDefaults
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              workspace.selectedProjectID == project.project.id,
              workspace.selectedBranchID == branch.branch.id else {
            return
        }
        binding = NovelSessionBinding(
            projectID: project.project.id,
            branchID: branch.branch.id
        )
        applyComposerPreference(project: project, branch: branch, persistFallback: true)
        hydrateTerminalState()
    }

    func setComposerIntent(_ intent: NovelComposerIntent) {
        if let projectID = binding?.projectID ?? workspace.selectedProjectID {
            NovelComposerIntentPreference.store(intent, for: projectID, defaults: composerDefaults)
        }
        if needsSync, intent != .discuss {
            applyComposerIntent(.discuss)
            return
        }
        applyComposerIntent(intent)
    }

    func reconcileComposerIntent() {
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot else {
            mode = .discussPlan
            return
        }
        applyComposerPreference(project: project, branch: branch, persistFallback: true)
    }

    private func applyComposerPreference(
        project: NovelProjectSnapshot,
        branch: NovelBranchSnapshot,
        persistFallback: Bool
    ) {
        let stored = NovelComposerIntentPreference.stored(
            for: project.project.id,
            defaults: composerDefaults
        )
        let needsSync = branch.branch.syncStatus == .needsSync
        let resolved = NovelComposerIntentPreference.resolve(
            stored: stored,
            collaborationMode: project.project.collaborationMode,
            hasConfirmedChapterPlan: project.confirmedChapterPlan(for: branch.branch.id) != nil,
            branchNeedsSync: needsSync
        )
        applyComposerIntent(resolved)
        // needsSync 只是临时改成讨论，不能覆盖用户记住的写正文偏好。
        if persistFallback, resolved != stored, !needsSync {
            NovelComposerIntentPreference.store(
                resolved,
                for: project.project.id,
                defaults: composerDefaults
            )
        }
    }

    private func applyComposerIntent(_ intent: NovelComposerIntent) {
        let values = intent.requestValues
        mode = values.mode
        if intent != .discuss {
            granularity = values.granularity
        }
    }

    var currentChapterVersions: [NovelChapterVersionRecord] {
        guard snapshotMatchesBinding,
              let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot else { return [] }
        let versionsByID = Dictionary(uniqueKeysWithValues: project.chapterVersions.map { ($0.id, $0) })
        return branch.chapterSelections.compactMap { versionsByID[$0.versionID] }
    }

    var hasPolishableChapters: Bool {
        guard snapshotMatchesBinding,
              let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot else { return false }
        let selectedChapterIDs = Set(branch.chapterSelections.map(\.chapterID))
        return project.chapters.contains {
            selectedChapterIDs.contains($0.id) && $0.discardedAt == nil
        }
    }

    var availableProseCandidates: [NovelCandidateRecord] {
        candidates(kind: .prose).filter { $0.status == .available }
    }

    var availablePolishCandidates: [NovelCandidateRecord] {
        candidates(kind: .polish).filter { $0.status == .available }
    }

    var branchPendingOperations: [NovelPendingOperationRecord] {
        guard let branchID = binding?.branchID else { return [] }
        return workspace.projectSnapshot?.pendingOperations.filter { $0.branchID == branchID } ?? []
    }

    var retryableBranchPendingOperations: [NovelPendingOperationRecord] {
        branchPendingOperations.filter { $0.status == .retryable }
    }

    var branchPolishTransactions: [NovelPendingPolishTransactionRecord] {
        guard let branchID = binding?.branchID else { return [] }
        return workspace.projectSnapshot?.polishTransactions.filter { $0.branchID == branchID } ?? []
    }

    var unresolvedBranchPolishTransactions: [NovelPendingPolishTransactionRecord] {
        branchPolishTransactions.filter {
            $0.status == .pending || $0.status == .retryable || $0.status == .blocked
        }
    }

    var access: NovelProjectLoadAccess? {
        guard snapshotMatchesBinding else { return nil }
        return workspace.projectSnapshot?.access
    }

    var needsSync: Bool {
        workspace.branchSnapshot?.branch.syncStatus == .needsSync
    }

    var activeRunID: NovelRunID? {
        if terminalAwaitingRefresh { return nil }
        if let runID = transientTailChromeState.runID {
            switch transientTailChromeState.phase {
            case .waitingForFirstToken, .streaming:
                return runID
            case .persistenceBlocked, .terminalAwaitingRefresh, .interrupted, .failed:
                return nil
            case nil:
                break
            }
        }
        return activeRun?.id ?? boundQuickStartStartingRun?.id
    }

    var isStarting: Bool {
        sessionStartingRunID != nil || boundQuickStartStartingRun != nil
    }

    var isRunning: Bool {
        activeRunID != nil
    }

    var isStreaming: Bool {
        guard !terminalAwaitingRefresh else { return false }
        return switch transientTailChromeState.phase {
        case .waitingForFirstToken, .streaming: true
        case .persistenceBlocked, .terminalAwaitingRefresh, .interrupted, .failed, nil: false
        }
    }

    var isBusy: Bool {
        isStarting || terminalAwaitingRefresh || stoppingRunID != nil ||
            retryingRunID != nil || cloningCandidateID != nil || undoingCheckpointID != nil ||
            isPerformingAction ||
            workspace.isPerforming || isBatchPolishing ||
            (isGhostwriting && !isGhostwriteStartingRun)
    }

    var isStopping: Bool { stoppingRunID != nil }

    var isRetryingLastTerminal: Bool {
        guard let retryingRunID else { return false }
        return retryingRunID == lastRetryRunID
    }

    /// 批量整章润色是否正在进行。派生自进度阶段,随 `batchPolishProgress` 一起被观察;
    /// 折进 `isBusy` 后,现有 `canStart`、阅读器门禁与输入框禁用都自动挡住并发起跑。
    var isBatchPolishing: Bool {
        batchPolishProgress?.phase == .running
    }

    /// 目录入口、选择页和报告重试共用同一个门禁，避免先看到可用按钮、
    /// 进入下一层才发现不能开始。
    var batchPolishBlocker: NovelSessionActionBlocker? {
        guard access == .readWrite else { return .projectReadOnly }
        if workspace.requiresReload || hasRefreshError { return .reloadRequired }
        if isRunning { return .generationRunning }
        if needsSync { return .branchNeedsSync }
        if !branchPendingOperations.isEmpty || !unresolvedBranchPolishTransactions.isEmpty {
            return .pendingOperation
        }
        if isBusy { return .transactionInProgress }
        return nil
    }

    var canStartBatchPolish: Bool {
        hasPolishableChapters && batchPolishBlocker == nil
    }

    /// `needsSync` 时正式正文仍禁止，发送走讨论规划，避免输入框看起来像坏了。
    var composerSendKind: NovelRunKind {
        needsSync ? .discussion : (mode == .discussPlan ? .discussion : .prose)
    }

    var canSend: Bool {
        canStart(kind: composerSendKind)
    }

    var canStop: Bool {
        activeRunID != nil && access == .readWrite && !isPerformingAction && stoppingRunID == nil
    }

    var canRetryLastTerminal: Bool {
        guard lastRetryDraft != nil,
              let runID = lastRetryRunID,
              !isRunning,
              !isBusy,
              access == .readWrite,
              let run = workspace.projectSnapshot?.activeRuns.first(where: { $0.id == runID }) else {
            return false
        }
        return run.kind != .quickStart &&
            canStart(kind: run.kind, granularity: run.granularity) &&
            isEligibleForExactRetry(run)
    }

    var canRetryPendingTerminal: Bool {
        guard case .persistenceBlocked = transientTailChromeState.phase else { return false }
        return access == .readWrite && !workspace.requiresReload && !isPerformingAction
    }

    var errorMessage: String? {
        operationErrorMessage ?? refreshErrorMessage
    }

    var hasRefreshError: Bool {
        refreshErrorMessage != nil
    }

    func bindToCurrentSelection(
        expandedArchiveIDs: Set<NovelMessageID> = []
    ) async {
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot,
              workspace.selectedProjectID == project.project.id,
              workspace.selectedBranchID == branch.branch.id else {
            await resetBinding()
            return
        }
        let next = NovelSessionBinding(
            projectID: project.project.id,
            branchID: branch.branch.id
        )
        let didChange = binding != next
        if didChange {
            await cancelPolishRetryForBindingChange(from: binding)
            await cancelBatchPolishForBindingChange(from: binding)
            await cancelGhostwriteForBindingChange(from: binding)
            detachConsumer()
            cancelProjectionBuild()
            // 切 binding 即作废旧 token:顺带取消可能仍在静窗里等待的 tail 退役任务。
            terminalTailRetirementTask?.cancel()
            terminalTailRetirementTask = nil
            bindingToken = UUID()
            binding = next
            transientTail = nil
            transientRunRecord = nil
            stoppingRunID = nil
            retryingRunID = nil
            cloningCandidateID = nil
            undoingCheckpointID = nil
            terminalAwaitingRefresh = false
            currentRunDraft = nil
            lastRetryDraft = nil
            lastRetryRunID = nil
            operationErrorMessage = nil
            refreshErrorMessage = nil
            lastFailure = nil
            applyComposerPreference(project: project, branch: branch, persistFallback: true)
            // New session: drop secondary chrome and projection until staged open advances.
            advanceLoadStage(to: .idle)
            projectionCache = nil
            pendingCharacterIdentityMentionsCache = nil
            characterIdentityChoicesCache = nil
            locallyResolvedAskUser = [:]
        }
        consumerAttachmentDesired = true
        hydrateTerminalState()
        let expectedToken = bindingToken
        // Project off the main actor while still at .idle so the open spinner can
        // animate; sync project() on MainActor was freezing the scene (watchdog).
        await warmProjectionCache(
            project: project,
            branch: branch,
            expandedArchiveIDs: expandedArchiveIDs
        )
        guard binding == next, bindingToken == expectedToken else { return }
        advanceLoadStage(to: .coreTranscript)
        // Ghostwrite restore / run attach after first core frame is allowed to commit.
        await Task.yield()
        guard binding == next, bindingToken == expectedToken else { return }
        await restoreGhostwriteProgressIfNeeded(for: next)
        _ = await resumeGhostwriteAfterBackgroundInterruptionIfNeeded()
        let currentActiveRun = activeRun
        if let run = currentActiveRun,
           consumerTask == nil || transientTail?.runID != run.id {
            await attach(to: run)
        } else if let startingRun = boundQuickStartStartingRun {
            if transientTail?.runID != startingRun.id {
                installTail(
                    run: startingRun,
                    content: "",
                    phase: .waitingForFirstToken
                )
            }
        } else if currentActiveRun == nil,
                  sessionStartingRunID == nil,
                  !terminalAwaitingRefresh,
                  isActiveTailPhase(transientTail?.phase) {
            transientTail = nil
            transientRunRecord = nil
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        guard let binding else {
            await bindToCurrentSelection()
            return self.binding != nil
        }
        let token = bindingToken
        guard await refreshDurable(binding: binding, token: token) else { return false }
        if consumerAttachmentDesired, consumerTask == nil, let run = activeRun {
            await attach(to: run)
        }
        return bindingToken == token && refreshErrorMessage == nil
    }

    func detachConsumer() {
        consumerAttachmentDesired = false
        clearConsumer()
    }

    func clearConsumer() {
        consumerID = nil
        consumerTask?.cancel()
        consumerTask = nil
        attachAttemptID = nil
        attachingRunID = nil
        attachingBindingToken = nil
        cancelPendingPresentation()
    }

    func clearError() {
        operationErrorMessage = nil
        refreshErrorMessage = nil
        lastFailure = nil
    }

    @discardableResult
    func send(
        text: String,
        injectionOverrides: NovelInjectionOverrides = .none,
        inputBudgetTokens: Int = 16_000
    ) async -> Bool {
        let kind = composerSendKind
        let sendMode: NovelSessionMode = kind == .discussion ? .discussPlan : mode
        let draft = NovelSessionRunDraft(
            kind: kind,
            mode: sendMode,
            granularity: kind == .prose ? granularity : nil,
            userText: text,
            sourceChapterVersionID: nil,
            askUserResponse: nil,
            injectionOverrides: injectionOverrides,
            inputBudgetTokens: inputBudgetTokens
        )
        return await start(draft)
    }

    func syncManualEdits() async {
        guard needsSync, !isPerformingAction, !workspace.requiresReload else { return }
        isPerformingAction = true
        workspace.clearError()
        await workspace.syncManualEdits()
        isPerformingAction = false
        operationErrorMessage = workspace.errorMessage
        _ = await refreshDurable(binding: binding, token: bindingToken)
    }
}

extension NovelSessionViewModel {
    /// 生成中状态条按**真实 run** 显示文案,而不是 composer 的当前设置:
    /// `start(_:)` 不回写 mode/granularity,重试失败 run 时两者会分叉。
    /// Prefer the live run record; fall back to the bound transient run so status
    /// chrome stays correct through terminal presentation drain.
    var activeRunKind: NovelRunKind? {
        activeRun?.kind ?? transientRunRecord?.kind
    }
    var activeRunGranularity: NovelGenerationGranularity? {
        activeRun?.granularity ?? transientRunRecord?.granularity
    }
    /// True while the manuscript terminal is still chrome-visible.
    ///
    /// Covers both the drain/save lock (`terminalAwaitingRefresh`) and the quiet
    /// window after unlock: retire clears the flag first so composer unlocks, but
    /// the tail stays on `.terminalAwaitingRefresh` until quiet elapses. Without
    /// this, the generation strip collapses ~28pt before the tail retires.
    var isTerminalPresenting: Bool {
        if terminalAwaitingRefresh { return true }
        if case .terminalAwaitingRefresh = transientTailChromeState.phase { return true }
        return false
    }
}
