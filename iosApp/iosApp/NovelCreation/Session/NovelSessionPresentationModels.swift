import Foundation

enum NovelSessionContextRing {
    /// Novel composer ring: last packed injection versus the **current model's**
    /// context window. Injection budget (16K/64K) is a separate packing cap.
    static func snapshot(
        messageCount: Int,
        modelId: String,
        modelWindowTokens: Int?,
        estimatedInjectionTokens: Int,
        supportsReasoning: Bool
    ) -> ChatContextSnapshot {
        ChatContextSnapshot(
            messageCount: messageCount,
            modelId: modelId,
            supportsReasoning: supportsReasoning,
            pendingSelectedFileName: nil,
            pendingSelectedFileBytesText: nil,
            promptTokens: estimatedInjectionTokens,
            completionTokens: 0,
            totalTokens: estimatedInjectionTokens,
            cachedTokens: 0,
            tokensPerSecond: nil,
            contextWindowTokens: ChatContextSnapshot.resolvedContextWindowTokens(
                modelWindow: modelWindowTokens,
                modelId: modelId
            ),
            currentContextTokens: estimatedInjectionTokens
        )
    }
}

enum NovelSessionComposerPolicy {
    static func canSubmit(canSend: Bool, text: String) -> Bool {
        canSend && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func askUserBlocker(
        access: NovelProjectLoadAccess?,
        requiresReload: Bool,
        isBusy: Bool
    ) -> NovelSessionActionBlocker? {
        guard access == .readWrite else { return .projectReadOnly }
        if requiresReload { return .reloadRequired }
        if isBusy { return .transactionInProgress }
        return nil
    }

    static func polishTransactionBlocker(
        access: NovelProjectLoadAccess?,
        requiresReload: Bool,
        isRunning: Bool,
        isBusy: Bool
    ) -> NovelSessionActionBlocker? {
        guard access == .readWrite else { return .projectReadOnly }
        if requiresReload { return .reloadRequired }
        if isRunning { return .generationRunning }
        if isBusy { return .transactionInProgress }
        return nil
    }

    static func showsGenerationStatus(
        isRunning: Bool,
        isTerminalPresenting: Bool = false,
        activeRunKind: NovelRunKind?,
        hasGhostwriteProgress: Bool = false
    ) -> Bool {
        // Ghostwrite owns its own dock chrome; do not stack co-create status above it.
        if hasGhostwriteProgress { return false }
        guard activeRunKind == .prose ||
                activeRunKind == .regenerate ||
                activeRunKind == .polish else { return false }
        // Keep the strip slot through terminal presentation drain so safeArea
        // height does not collapse mid-finish (scroll jump).
        return isRunning || isTerminalPresenting
    }

    static func runtimeActionBlocker(
        requiresReload: Bool,
        hasRefreshError: Bool,
        isBusy: Bool
    ) -> NovelSessionActionBlocker? {
        if requiresReload || hasRefreshError { return .reloadRequired }
        if isBusy { return .transactionInProgress }
        return nil
    }
}

enum NovelSessionTransientTailPhase: Equatable, Sendable {
    case waitingForFirstToken
    case streaming
    case terminalAwaitingRefresh
    case interrupted
    case failed(NovelFailure)
    case persistenceBlocked(NovelFailure)
}

struct NovelSessionTransientTail: Equatable, Sendable {
    let branchID: NovelBranchID
    let sessionID: NovelSessionID
    let runID: NovelRunID
    let userMessageID: NovelMessageID
    let startingUserContent: String?
    let messageID: NovelMessageID
    let candidateID: NovelCandidateID?
    let mode: NovelSessionMode
    let granularity: NovelGenerationGranularity?
    let kind: NovelSessionMessageKind
    let content: String
    /// Presentation-only thinking stream. Never manuscript / candidate content.
    let reasoningContent: String
    let isReasoningLive: Bool
    /// Monotonic per-tail revision owned by the Session ViewModel.
    /// The row digest uses this instead of hashing an ever-growing whole chapter.
    let renderRevision: UInt64
    let startedAt: Date
    let phase: NovelSessionTransientTailPhase
    /// 滚动跟随的滞后允许度（与 Chat 同源）：1=流式期；终态排空期间随剩余积压
    /// 连续衰减到 0，driver 据此连续收紧跟随时间常数（τ_eff = τ × allowance），
    /// 排空最后一拍前视口已贴回底部——完成瞬间无需一次性清掉跟随滞后。
    let lagAllowance: Double
    /// Completed Ask User / 审批卡. Durable overlay hides this message while the
    /// tail is live, so the card has to live on the tail itself until retire.
    let askUser: NovelAskUserPresentation?

    init(
        run: NovelActiveRunRecord,
        content: String,
        renderRevision: UInt64,
        startingUserContent: String? = nil,
        phase: NovelSessionTransientTailPhase,
        reasoningContent: String = "",
        isReasoningLive: Bool = false,
        lagAllowance: Double = 1,
        askUser: NovelAskUserPresentation? = nil
    ) {
        branchID = run.branchID
        sessionID = run.sessionID
        runID = run.id
        userMessageID = run.userMessageID
        self.startingUserContent = startingUserContent
        messageID = run.messageID
        candidateID = run.candidateID
        mode = run.mode
        granularity = run.granularity
        kind = switch run.kind {
        case .quickStart, .characterProposal, .discussion: .discussion
        case .prose, .regenerate: .proseCandidate
        case .polish: .polishCandidate
        }
        self.content = content
        self.reasoningContent = reasoningContent
        self.isReasoningLive = isReasoningLive
        self.renderRevision = renderRevision
        startedAt = run.startedAt
        self.phase = phase
        self.lagAllowance = lagAllowance
        self.askUser = askUser
    }

    func updating(
        content: String,
        renderRevision: UInt64,
        phase: NovelSessionTransientTailPhase,
        reasoningContent: String? = nil,
        isReasoningLive: Bool? = nil,
        lagAllowance: Double? = nil,
        askUser: NovelAskUserPresentation? = nil
    ) -> NovelSessionTransientTail {
        NovelSessionTransientTail(
            branchID: branchID,
            sessionID: sessionID,
            runID: runID,
            userMessageID: userMessageID,
            startingUserContent: startingUserContent,
            messageID: messageID,
            candidateID: candidateID,
            mode: mode,
            granularity: granularity,
            kind: kind,
            content: content,
            reasoningContent: reasoningContent ?? self.reasoningContent,
            isReasoningLive: isReasoningLive ?? self.isReasoningLive,
            renderRevision: renderRevision,
            startedAt: startedAt,
            phase: phase,
            lagAllowance: lagAllowance ?? self.lagAllowance,
            askUser: askUser ?? self.askUser
        )
    }

    func updating(
        content: String,
        phase: NovelSessionTransientTailPhase,
        lagAllowance: Double? = nil
    ) -> NovelSessionTransientTail {
        updating(
            content: content,
            renderRevision: renderRevision &+ 1,
            phase: phase,
            lagAllowance: lagAllowance
        )
    }

    func updatingReasoning(
        content: String,
        isLive: Bool
    ) -> NovelSessionTransientTail {
        updating(
            content: self.content,
            renderRevision: renderRevision &+ 1,
            phase: phase,
            reasoningContent: content,
            isReasoningLive: isLive
        )
    }

    private init(
        branchID: NovelBranchID,
        sessionID: NovelSessionID,
        runID: NovelRunID,
        userMessageID: NovelMessageID,
        startingUserContent: String?,
        messageID: NovelMessageID,
        candidateID: NovelCandidateID?,
        mode: NovelSessionMode,
        granularity: NovelGenerationGranularity?,
        kind: NovelSessionMessageKind,
        content: String,
        reasoningContent: String,
        isReasoningLive: Bool,
        renderRevision: UInt64,
        startedAt: Date,
        phase: NovelSessionTransientTailPhase,
        lagAllowance: Double,
        askUser: NovelAskUserPresentation?
    ) {
        self.branchID = branchID
        self.sessionID = sessionID
        self.runID = runID
        self.userMessageID = userMessageID
        self.startingUserContent = startingUserContent
        self.messageID = messageID
        self.candidateID = candidateID
        self.mode = mode
        self.granularity = granularity
        self.kind = kind
        self.content = content
        self.reasoningContent = reasoningContent
        self.isReasoningLive = isReasoningLive
        self.renderRevision = renderRevision
        self.startedAt = startedAt
        self.phase = phase
        self.lagAllowance = lagAllowance
        self.askUser = askUser
    }
}

enum NovelSettingProposalRoute: Hashable, Sendable {
    case characters
    case world
    case story
    case more

    init(kind: NovelMaterialKind?) {
        self = switch kind {
        case .character: .characters
        case .world: .world
        case .relationship, .masterOutline: .story
        case .writingRequirements, .decisionLog, .custom, nil: .more
        }
    }
}

enum NovelSessionRowAction: Hashable, Sendable {
    case collectProse(NovelCandidateID)
    case adoptPolish(NovelCandidateID)
    case retryGeneration(NovelRunID)
    case retryTerminalPersistence(NovelRunID)
    case retryPending(NovelPendingOperationID)
    case retryPolish(NovelPendingOperationID)
    case abandonPolish(NovelPendingOperationID)
    case convertPolishToManualRewrite(
        candidateID: NovelCandidateID,
        sourceChapterVersionID: NovelChapterVersionID
    )
    case cloneCollectedProse(NovelCandidateID)
    case forkFromCheckpoint(NovelCheckpointID)
    case viewSettingProposals(NovelSettingProposalRoute)
    case undoCommittedChange(checkpointID: NovelCheckpointID, kind: NovelCandidateKind)
}

enum NovelSessionActionBlocker: String, Hashable, Sendable {
    case projectReadOnly
    case reloadRequired
    case branchInactive
    case branchNeedsSync
    case chapterPlanRequired
    case ghostwriteReviewRequired
    case ghostwriteRequirementsMissing
    case generationRunning
    case pendingOperation
    case transactionInProgress
    case transactionBlocked
    case staleCandidate
    case sourceChapterChanged
    case failureNotRetryable
}

struct NovelSessionRowActionAvailability: Equatable, Hashable, Sendable {
    let action: NovelSessionRowAction
    let blocker: NovelSessionActionBlocker?

    var isEnabled: Bool { blocker == nil }
}

struct NovelSessionCandidatePresentation: Equatable, Sendable {
    let id: NovelCandidateID
    let kind: NovelCandidateKind
    let status: NovelCandidateStatus
    let sourceChapterVersionID: NovelChapterVersionID?
    let pendingStatus: NovelPendingOperationStatus?
    let polishTransactionStatus: NovelPolishTransactionStatus?
}

struct NovelSessionCommittedChangeSummary: Equatable, Sendable {
    let checkpointID: NovelCheckpointID
    let stateSnapshotID: NovelStateSnapshotID
    let stateSummary: String
    let eventSummaries: [String]
    /// Whether the branch's plot state is currently synchronized, as of the last projection.
    ///
    /// This is `branch.syncStatus` — a **branch-level**, persisted fact — not a per-row
    /// history entry. Every committed row on the branch shares this same value: if the
    /// user later commits more chapters and the branch drops back to `.needsSync`, a row
    /// that previously showed "synchronized" will flip back to showing nothing (or the
    /// existing "needs sync" notice) the next time it's projected, even though this exact
    /// row's own content hasn't changed. That is semantically correct (the branch really
    /// did go stale again), but it is not a durable "this paragraph was synced at time T"
    /// stamp.
    ///
    /// A true per-paragraph sync stamp is not derivable: a manual sync's input is *all*
    /// backlog chapters since the last sync (aggregated, not scoped to one message — see
    /// `NovelFactTransactions.manualSync`), the resulting checkpoint's
    /// `sourceCandidateID` is `nil` (it cannot be traced back to any one candidate/message),
    /// and the pending manual-sync operation record is deleted on success. There is nothing
    /// left to hang a per-segment "synced" fact off of after the fact.
    let branchSyncStatus: NovelBranchSyncStatus
}

struct NovelAskUserPresentation: Equatable, Sendable {
    let prompt: NovelAskUserPrompt
    let response: NovelAskUserResponse?

    var isAnswered: Bool { response != nil }
}

struct NovelDiscussionArchivePresentation: Equatable, Sendable {
    let id: NovelMessageID
    let title: String
    let summary: String
    let messageCount: Int
    let revealedRowCount: Int
    let isExpanded: Bool
}

struct NovelSessionRowDigest: Equatable, Hashable, Sendable {
    /// Inputs that can change the row's measured height.
    let layout: String
    /// Inputs that only reroute interaction while keeping the same content row.
    let presentation: String
}

struct NovelSessionRowModel: Identifiable, Equatable, Sendable {
    let id: NovelMessageID
    let sequence: Int64
    let role: NovelSessionRole
    let mode: NovelSessionMode
    let granularity: NovelGenerationGranularity?
    let kind: NovelSessionMessageKind
    let content: String
    /// Presentation-only thinking text for the active/transient assistant row.
    let reasoningContent: String
    let isReasoningLive: Bool
    let createdAt: Date
    let runID: NovelRunID?
    let runStatus: NovelRunStatus?
    let candidate: NovelSessionCandidatePresentation?
    let committedChange: NovelSessionCommittedChangeSummary?
    let askUser: NovelAskUserPresentation?
    let archive: NovelDiscussionArchivePresentation?
    let transientPhase: NovelSessionTransientTailPhase?
    let actions: [NovelSessionRowActionAvailability]
    let digest: NovelSessionRowDigest
    /// 活动尾行的跟随滞后允许度（流式 1 → 终态排空连续衰减到 0），视图层透传
    /// 给 streamContentGrew(lagAllowance:)。非活动行恒为 1。
    let lagAllowance: Double

    var isTransient: Bool { transientPhase != nil }

    var isStreaming: Bool {
        switch transientPhase {
        case .waitingForFirstToken, .streaming: true
        case .terminalAwaitingRefresh, .interrupted, .failed, .persistenceBlocked, nil: false
        }
    }

    init(
        id: NovelMessageID,
        sequence: Int64,
        role: NovelSessionRole,
        mode: NovelSessionMode,
        granularity: NovelGenerationGranularity?,
        kind: NovelSessionMessageKind,
        content: String,
        reasoningContent: String = "",
        isReasoningLive: Bool = false,
        createdAt: Date,
        runID: NovelRunID?,
        runStatus: NovelRunStatus?,
        candidate: NovelSessionCandidatePresentation?,
        committedChange: NovelSessionCommittedChangeSummary?,
        askUser: NovelAskUserPresentation?,
        archive: NovelDiscussionArchivePresentation?,
        transientPhase: NovelSessionTransientTailPhase?,
        actions: [NovelSessionRowActionAvailability],
        digest: NovelSessionRowDigest,
        lagAllowance: Double = 1
    ) {
        self.id = id
        self.sequence = sequence
        self.role = role
        self.mode = mode
        self.granularity = granularity
        self.kind = kind
        self.content = content
        self.reasoningContent = reasoningContent
        self.isReasoningLive = isReasoningLive
        self.createdAt = createdAt
        self.runID = runID
        self.runStatus = runStatus
        self.candidate = candidate
        self.committedChange = committedChange
        self.askUser = askUser
        self.archive = archive
        self.transientPhase = transientPhase
        self.actions = actions
        self.digest = digest
        self.lagAllowance = lagAllowance
    }
}

private enum NovelSessionRowLocation: Equatable, Sendable {
    case historical(Int)
    case activeRun(Int)
}

struct NovelSessionListModel: Equatable, Sendable {
    let sessionID: NovelSessionID
    let historicalRows: [NovelSessionRowModel]
    let activeRunRows: [NovelSessionRowModel]
    let activeTailID: NovelMessageID?
    /// Index of the active tail in `activeRunRows`, captured during projection.
    let activeTailIndex: Int?
    private let rowOrder: [NovelSessionRowLocation]

    /// Compatibility view for projection callers and tests that need source order.
    /// The stream update path reads the precomputed sections and tail directly.
    var rows: [NovelSessionRowModel] {
        rowOrder.map { location in
            switch location {
            case .historical(let index):
                historicalRows[index]
            case .activeRun(let index):
                activeRunRows[index]
            }
        }
    }

    var rowCount: Int { rowOrder.count }
    var isEmpty: Bool { rowOrder.isEmpty }
    var lastRowDigest: NovelSessionRowDigest? {
        guard let location = rowOrder.last else { return nil }
        switch location {
        case .historical(let index): return historicalRows[index].digest
        case .activeRun(let index): return activeRunRows[index].digest
        }
    }
    var activeTailRow: NovelSessionRowModel? {
        guard let activeTailIndex else { return nil }
        return activeRunRows[activeTailIndex]
    }

    init(
        sessionID: NovelSessionID,
        rows: [NovelSessionRowModel],
        activeTailID: NovelMessageID?
    ) {
        let activeRunID: NovelRunID? = {
            if let activeTailID {
                return rows.first(where: { $0.id == activeTailID })?.runID
            }
            // Keep the just-finished run in the active stack after the tail
            // retires. Moving those rows into history remounts its markdown.
            return rows.last(where: { $0.runID != nil })?.runID
        }()
        var historicalRows: [NovelSessionRowModel] = []
        var activeRunRows: [NovelSessionRowModel] = []
        var rowOrder: [NovelSessionRowLocation] = []
        historicalRows.reserveCapacity(rows.count)
        rowOrder.reserveCapacity(rows.count)
        for row in rows {
            if let activeRunID, row.runID == activeRunID {
                rowOrder.append(.activeRun(activeRunRows.count))
                activeRunRows.append(row)
            } else {
                rowOrder.append(.historical(historicalRows.count))
                historicalRows.append(row)
            }
        }
        self.init(
            sessionID: sessionID,
            historicalRows: historicalRows,
            activeRunRows: activeRunRows,
            activeTailID: activeTailID,
            activeTailIndex: activeTailID.flatMap { tailID in
                activeRunRows.firstIndex(where: { $0.id == tailID })
            },
            rowOrder: rowOrder
        )
    }

    private init(
        sessionID: NovelSessionID,
        historicalRows: [NovelSessionRowModel],
        activeRunRows: [NovelSessionRowModel],
        activeTailID: NovelMessageID?,
        activeTailIndex: Int?,
        rowOrder: [NovelSessionRowLocation]
    ) {
        self.sessionID = sessionID
        self.historicalRows = historicalRows
        self.activeRunRows = activeRunRows
        self.activeTailID = activeTailID
        self.activeTailIndex = activeTailIndex
        self.rowOrder = rowOrder
    }

    func replacingActiveTail(with row: NovelSessionRowModel) -> NovelSessionListModel {
        guard let activeTailIndex else { return self }
        var activeRunRows = activeRunRows
        activeRunRows[activeTailIndex] = row
        return NovelSessionListModel(
            sessionID: sessionID,
            historicalRows: historicalRows,
            activeRunRows: activeRunRows,
            activeTailID: activeTailID,
            activeTailIndex: activeTailIndex,
            rowOrder: rowOrder
        )
    }
}

/// Staged session open so large projects never pay transcript + long layout +
/// identity chrome in a single main-thread turn (0x8BADF00D on 赵大来了-scale).
enum NovelSessionLoadStage: Int, Comparable, Sendable {
    /// Binding / snapshot not ready — avoid projecting heavy lists.
    case idle = 0
    /// Bound: tiny history window only (row count capped; body not truncated).
    case coreTranscript = 1
    /// After first layout: expand steady history window.
    case steadyTranscript = 2
    /// After core is on screen: identity cards and other secondary chrome.
    case secondaryChrome = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum NovelSessionHistoryWindowPolicy {
    /// First paint after open — latest exchange only (user + assistant).
    static let coldOpenLimit = 2
    /// After the first layout commits, grow to this many historical rows.
    static let initialLimit = 4
    /// "更早的创作记录" page size.
    static let pageSize = 12

    static func startIndex(totalCount: Int, limit: Int) -> Int {
        max(0, totalCount - max(0, limit))
    }

    static func expandedLimit(currentLimit: Int, totalCount: Int) -> Int {
        min(totalCount, max(0, currentLimit) + pageSize)
    }

    /// Cold open → steady window without shrinking a user-expanded history.
    static func limitAfterColdOpenSettles(currentLimit: Int) -> Int {
        max(currentLimit, initialLimit)
    }

    /// 追加新行时窗口必须吸收增量,否则 `startIndex` 前移会把**已经渲染过的**
    /// 顶部行踢出窗口。那些行可能有几万 pt 高,一旦被踢,contentSize 当场收缩,
    /// 而收缩发生在视口上方——没有任何锚点补偿(底锚已在 0eea3d38b 撤除),
    /// 结果就是整列表大幅位移、视口里冒出本条回复更早的内容。
    ///
    /// 这里不区分「是否贴底」:贴底与否只影响用户看不看得见,不影响
    /// 「已渲染的行不得中途消失」这条不变量。
    static func limitAfterRowsAppended(
        currentLimit: Int,
        previousRowCount: Int,
        currentRowCount: Int
    ) -> Int {
        let appended = max(0, currentRowCount - previousRowCount)
        guard appended > 0 else { return currentLimit }
        return min(currentRowCount, currentLimit + appended)
    }

    static func limitAfterArchiveExpansion(
        currentLimit: Int,
        revealedRowCount: Int
    ) -> Int {
        currentLimit + revealedRowCount
    }

    /// 活动 run 的行离开 eager 尾部时，窗口上限必须吸收真正转入历史的行数，
    /// 否则完成瞬间窗口会裁掉完成前已可见的旧行，表现为内容位移。
    /// 行数按快照差推导：整体消失的行（启动失败恢复）不计入，避免无谓扩窗。
    static func limitAfterActiveRunReturnsToHistory(
        currentLimit: Int,
        activeRunRowCount: Int,
        previousRowCount: Int,
        currentRowCount: Int
    ) -> Int {
        let vanished = max(0, previousRowCount - currentRowCount)
        let returned = max(0, activeRunRowCount - vanished)
        return currentLimit + returned
    }
}

struct NovelSessionProjectionInput: Equatable, Sendable {
    let branch: NovelBranchRecord
    let session: NovelSessionRecord
    let candidates: [NovelCandidateRecord]
    let runs: [NovelActiveRunRecord]
    let pendingOperations: [NovelPendingOperationRecord]
    let polishTransactions: [NovelPendingPolishTransactionRecord]
    let discardedChapterVersionIDs: Set<NovelChapterVersionID>
    let checkpoints: [NovelBranchCheckpointRecord]
    let stateSnapshots: [NovelStateSnapshotRecord]
    let events: [NovelStoryEventRecord]
    let settingProposals: [NovelSettingProposalRecord]
    let collaborationMode: NovelCollaborationMode
    let hasConfirmedChapterPlan: Bool
    let access: NovelProjectLoadAccess
    let expandedArchiveIDs: Set<NovelMessageID>
    let transientTail: NovelSessionTransientTail?
    let hasLiveTail: Bool

    static func hasLiveTail(
        _ tail: NovelSessionTransientTail?,
        branchID: NovelBranchID,
        sessionID: NovelSessionID
    ) -> Bool {
        guard let tail,
              tail.branchID == branchID,
              tail.sessionID == sessionID else { return false }
        return tail.phase == .waitingForFirstToken || tail.phase == .streaming
    }

    init(
        branch: NovelBranchRecord,
        session: NovelSessionRecord,
        candidates: [NovelCandidateRecord],
        runs: [NovelActiveRunRecord],
        pendingOperations: [NovelPendingOperationRecord],
        polishTransactions: [NovelPendingPolishTransactionRecord],
        discardedChapterVersionIDs: Set<NovelChapterVersionID> = [],
        checkpoints: [NovelBranchCheckpointRecord] = [],
        stateSnapshots: [NovelStateSnapshotRecord] = [],
        events: [NovelStoryEventRecord] = [],
        settingProposals: [NovelSettingProposalRecord] = [],
        collaborationMode: NovelCollaborationMode = .cocreation,
        hasConfirmedChapterPlan: Bool = false,
        access: NovelProjectLoadAccess,
        expandedArchiveIDs: Set<NovelMessageID> = [],
        transientTail: NovelSessionTransientTail?,
        hasLiveTail: Bool? = nil
    ) {
        self.branch = branch
        self.session = session
        self.candidates = candidates
        self.runs = runs
        self.pendingOperations = pendingOperations
        self.polishTransactions = polishTransactions
        self.discardedChapterVersionIDs = discardedChapterVersionIDs
        self.checkpoints = checkpoints
        self.stateSnapshots = stateSnapshots
        self.events = events
        self.settingProposals = settingProposals
        self.collaborationMode = collaborationMode
        self.hasConfirmedChapterPlan = hasConfirmedChapterPlan
        self.access = access
        self.expandedArchiveIDs = expandedArchiveIDs
        self.transientTail = transientTail
        self.hasLiveTail = hasLiveTail ?? Self.hasLiveTail(
            transientTail,
            branchID: branch.id,
            sessionID: session.id
        )
    }

    init(
        project: NovelProjectSnapshot,
        branch: NovelBranchSnapshot,
        expandedArchiveIDs: Set<NovelMessageID> = [],
        transientTail: NovelSessionTransientTail?,
        hasLiveTail: Bool? = nil
    ) {
        let discardedChapterIDs = Set(project.chapters.lazy.filter {
            $0.discardedAt != nil
        }.map(\.id))
        self.init(
            branch: branch.branch,
            session: branch.session,
            candidates: project.candidates,
            runs: project.activeRuns,
            pendingOperations: project.pendingOperations,
            polishTransactions: project.polishTransactions,
            discardedChapterVersionIDs: Set(project.chapterVersions.lazy.filter {
                discardedChapterIDs.contains($0.chapterID)
            }.map(\.id)),
            checkpoints: project.checkpoints,
            stateSnapshots: project.stateSnapshots,
            events: project.events,
            settingProposals: branch.activeSettingProposals,
            collaborationMode: project.project.collaborationMode,
            hasConfirmedChapterPlan: project.confirmedChapterPlan(for: branch.branch.id) != nil,
            access: project.access,
            expandedArchiveIDs: expandedArchiveIDs,
            transientTail: transientTail,
            hasLiveTail: hasLiveTail
        )
    }
}

struct NovelSessionPreparedProjection: Sendable {
    let model: NovelSessionListModel
    let index: NovelSessionProjectionIndex
}

