import Foundation
import Observation
import UIKit

func novelRunBackgroundLeaseID(for runID: NovelRunID) -> String {
    "novel-run-\(runID)"
}

func novelStateSyncBackgroundLeaseID(for ownerID: UUID) -> String {
    "novel-state-sync-\(ownerID.uuidString)"
}

func novelContinuityBackgroundLeaseID(for ownerID: UUID) -> String {
    "novel-continuity-\(ownerID.uuidString)"
}

func novelGhostwriteBackgroundLeaseID(
    projectID: NovelProjectID,
    branchID: NovelBranchID
) -> String {
    "novel-ghostwrite-\(projectID)-\(branchID)"
}

func isProtectedNovelBackgroundLeaseID(_ leaseID: String) -> Bool {
    leaseID.hasPrefix("novel-run-") ||
        leaseID.hasPrefix("novel-state-sync-") ||
        leaseID.hasPrefix("novel-continuity-") ||
        leaseID.hasPrefix("novel-ghostwrite-")
}

enum NovelBranchSelectionResult: Equatable, Sendable {
    case selected
    case requiresStoppingActiveRun
    case failed
}

struct NovelComposerDraft: Equatable, Sendable {
    let text: String
    let injectionOverrides: NovelInjectionOverrides
    let inputBudgetTokens: Int

    static let empty = NovelComposerDraft(
        text: "",
        injectionOverrides: .none,
        inputBudgetTokens: 16_000
    )
}

struct NovelComposerDraftOwner: Hashable, Sendable {
    let projectID: NovelProjectID
    let branchID: NovelBranchID
}

struct NovelChapterPlanDraft: Equatable, Sendable {
    let outlinePlacement: String
    let goalAndConflict: String
    let mustHappen: [String]
    let mustNotHappen: [String]
    let endingHook: String
    let visibleFacts: [String]
}

private enum NovelBackgroundGenerationProbe {
    case active
    case inactive
    case unknown
}

@MainActor
@Observable
final class NovelCreationViewModel {
    var projects: [NovelProjectSummary] = []
    var selectedProjectID: NovelProjectID?
    var selectedBranchID: NovelBranchID?
    var projectSnapshot: NovelProjectSnapshot?
    var branchSnapshot: NovelBranchSnapshot? {
        didSet { scheduleStalePlotAutoSyncIfNeeded() }
    }
    var checkoutSidecarFailure: String?
    var injectionPreview: NovelInjectionPreviewSnapshot?
    /// 剧情矛盾检查的结果。**只活在内存里**:它是一份诊断报告,不是故事状态的一部分,
    /// 退出项目或换分支就丢弃,需要重扫(见 `NovelContinuityAuditReport` 的说明)。
    ///
    /// 归属由**读取侧**判定,不靠「每个切换点手动清一次」——新建/导入项目、fork、
    /// 删分支走的是 `reloadSelection` 而不是 `selectProject`/`selectBranch`,
    /// 靠手动清必然漏,漏了就会把上一个项目的报告显示在当前项目的剧情页上。
    var continuityAudit: NovelContinuityAuditReport? {
        guard let report = continuityAuditReport,
              report.projectID == selectedProjectID,
              report.branchID == selectedBranchID else { return nil }
        return report
    }

    var continuityAuditReport: NovelContinuityAuditReport?
    var continuityAuditPlanStorage: NovelContinuityAuditPlan?
    var continuityAuditFailureStorage: NovelContinuityAuditFailure?
    var continuityRepairReport: NovelContinuityRepairReport?
    @ObservationIgnored var continuityAuditExpirationOwnerID: UUID?
    var isPlanningContinuity = false
    var isAuditingContinuity = false
    var isRepairingContinuity = false
    @ObservationIgnored var continuityAuditTask: Task<Void, Never>?
    var isLoading = false
    /// loadProjects 并发防护：首页 onAppear 与项目列表 .task 可并发触发同一加载，
    /// 较早响应不得回写覆盖较晚结果（latest-wins）。
    @ObservationIgnored private var projectsLoadRevision = 0
    @ObservationIgnored var projectListReadRevision = 0
    private(set) var isPerforming = false
    var pendingSettingProposalIDs: Set<NovelProposalID> = []
    var pendingMaterialDeletionIDs: Set<NovelMaterialID> = []
    var isRejectingAllSettingProposals = false
    var isAcceptingStalePlot = false
    /// 每次自动「按正文接受」成功后递增；界面据此弹一次几秒后消失的轻提示。
    var stalePlotAutoSyncNoticeID = 0
    @ObservationIgnored var stalePlotAutoSyncTask: Task<Void, Never>?
    var stateSyncActivity: NovelStateSyncActivity?
    private(set) var projectListLoadError: String?
    var errorMessage: String?
    var reloadNoticeMessage: String?
    var reloadNoticeProjectID: NovelProjectID?
    var reloadNoticeBranchID: NovelBranchID?
    var quickStartStatuses: [NovelQuickStartOwner: NovelQuickStartStatus] = [:]
    var quickStartStartingProjectID: NovelProjectID?
    var quickStartStartingRun: NovelActiveRunRecord?

    @ObservationIgnored let creation: any NovelCreation
    @ObservationIgnored var selectionToken = UUID()
    @ObservationIgnored private var selectionIntentToken = UUID()
    @ObservationIgnored var quickStartTasks: [NovelQuickStartOwner: Task<Void, Never>] = [:]
    @ObservationIgnored var quickStartTaskRunIDs: [NovelQuickStartOwner: NovelRunID] = [:]
    @ObservationIgnored var quickStartCreationStartRunIDs: Set<NovelRunID> = []
    @ObservationIgnored var cancelledQuickStartRunIDs: Set<NovelRunID> = []
    @ObservationIgnored private var composerDrafts: [NovelComposerDraftOwner: NovelComposerDraft] = [:]
    @ObservationIgnored private var chapterPlanDrafts: [NovelProjectID: [NovelBranchID: NovelChapterPlanDraft]] = [:]
    @ObservationIgnored var lastSelectedBranchIDs: [NovelProjectID: NovelBranchID] = [:]
    @ObservationIgnored var operationOwnerID: UUID?
    @ObservationIgnored var stateSyncActivityOwnerID: UUID?
    @ObservationIgnored var stateSyncActivityTask: Task<Void, Never>?
    @ObservationIgnored var stateSyncReportedWorkByOwnerID: [UUID: Int64] = [:]
    /// Keep the visible progress strip across outer heal `perform()`s.
    @ObservationIgnored var automaticStateSyncKeepAlive = false
    @ObservationIgnored var manualStateSyncTask: Task<Void, Never>?
    @ObservationIgnored var manualStateSyncPendingID: NovelPendingOperationID?
    var manualStateSyncTarget: NovelAutomaticStateSyncTarget?
    @ObservationIgnored var automaticStateSyncTask: Task<Void, Never>?
    @ObservationIgnored var automaticStateSyncTarget: NovelAutomaticStateSyncTarget?
    @ObservationIgnored var queuedAutomaticStateSyncTarget: NovelAutomaticStateSyncTarget?
    var automaticStateSyncPresentationTarget: NovelAutomaticStateSyncTarget?
    var automaticStateSyncFailure: NovelAutomaticStateSyncFailure?
    /// Last error from a state-sync `perform` (reportsError: false path). Used when
    /// pending.lastError was not written yet so retry banners do not collapse to a
    /// useless generic "没有完成，请重试".
    @ObservationIgnored var lastStateSyncOperationError: String?
    @ObservationIgnored var lastStateSyncOperationCause: Error?
    /// Targets the user explicitly stopped. Prevents cancel from looking like a no-op when
    /// `needsSync` remains true and would immediately reschedule the same work.
    var userSuppressedStateSyncTargets: Set<NovelAutomaticStateSyncTarget> = []
    /// Targets whose Stop was pressed but mutation/task teardown has not finished yet.
    /// Keeps a visible “正在停止” state so selection block is not unexplained.
    var stateSyncStoppingTargets: Set<NovelAutomaticStateSyncTarget> = []
    /// 领域 mutation 广播的订阅任务；weak self 退出，不占额外生命周期管理。
    @ObservationIgnored private var mutationEventsTask: Task<Void, Never>?
    /// 本 VM 发起的 mutation 的 operationID 集合，用于抑制广播回声；成功广播到达即移除。
    @ObservationIgnored var ownMutationOperationIDs: Set<NovelOperationID> = []
    /// Coalesce external mutation refreshes (discussion tools often fire many
    /// commits in one agent turn). Serial full-project reloads freeze large novels.
    @ObservationIgnored private var pendingExternalMutationProjectIDs: [NovelProjectID: Bool] = [:]
    @ObservationIgnored private var externalMutationRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var ghostwriteProgressWriteTask: Task<Bool, Never>?

    init(creation: any NovelCreation) {
        self.creation = creation
        // 非 UI 写入源（讨论工具 executor 等）落盘后广播的 mutation 事件：复用
        // refreshCurrentSelection 一处刷新项目列表与选中快照，否则顶栏标题/面板/
        // 设定页/列表行要等 run 终态甚至重进才更新。自身 UI 写入的回流是幂等重复
        // 刷新（latest-wins），不额外抑制；VM 释放后下一条事件让任务自行退出。
        mutationEventsTask = Task { @MainActor [weak self] in
            guard let stream = await self?.creation.mutationEvents() else { return }
            for await event in stream {
                guard let self else { return }
                // 自身发起的写入已在自己的流程里刷新；回声刷新会与这些流程的
                // 中间状态竞争（分支选择/快照序列），必须按 operationID 抑制。
                if self.ownMutationOperationIDs.remove(event.operationID) != nil { continue }
                self.scheduleExternalMutationRefresh(
                    projectID: event.projectID,
                    refreshesSelection: event.refreshesSelection
                )
            }
        }
    }

    /// Batch tool writes into one UI refresh after a short quiet window.
    private func scheduleExternalMutationRefresh(
        projectID: NovelProjectID,
        refreshesSelection: Bool
    ) {
        pendingExternalMutationProjectIDs[projectID] =
            (pendingExternalMutationProjectIDs[projectID] ?? false) || refreshesSelection
        guard externalMutationRefreshTask == nil else { return }
        externalMutationRefreshTask = Task { @MainActor [weak self] in
            // 150ms covers typical multi-tool bursts without making title/panel lag feel stuck.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            let projectIDs = self.pendingExternalMutationProjectIDs
            self.pendingExternalMutationProjectIDs = [:]
            self.externalMutationRefreshTask = nil
            var needsProjectListRefresh = false
            for (id, refreshesSelection) in projectIDs {
                guard refreshesSelection else {
                    needsProjectListRefresh = true
                    continue
                }
                guard self.selectedProjectID == id else {
                    needsProjectListRefresh = true
                    continue
                }
                do {
                    if try await self.refreshCurrentSelection(
                        projectID: id,
                        refreshProjectList: false,
                        fallbackProjectListOnMiss: false
                    ) == false {
                        needsProjectListRefresh = true
                    }
                } catch {
                    needsProjectListRefresh = true
                }
            }
            if needsProjectListRefresh {
                _ = try? await self.refreshProjectListIfLatest()
            }
        }
    }

    /// 跨进程：写入本批代笔进度 sidecar；不该保留时删除。
    func persistGhostwriteBatchProgress(_ progress: NovelGhostwriteProgress) {
        _ = enqueueGhostwriteProgressWrite { [weak self] in
            await self?.writeGhostwriteBatchProgress(progress) ?? false
        }
    }

    /// 系统即将收回执行机会时使用：确认最新 sidecar 已完成原子写入再取消编排。
    func flushGhostwriteBatchProgress(_ progress: NovelGhostwriteProgress) async -> Bool {
        await enqueueGhostwriteProgressWrite { [weak self] in
            await self?.writeGhostwriteBatchProgress(progress) ?? false
        }.value
    }

    private func writeGhostwriteBatchProgress(_ progress: NovelGhostwriteProgress) async -> Bool {
        let record = NovelGhostwriteBatchProgressRecord.from(progress: progress)
        do {
            if record.shouldPersist {
                try await creation.saveGhostwriteBatchProgress(record)
            } else {
                try await creation.removeGhostwriteBatchProgress(
                    projectID: record.projectID,
                    branchID: record.branchID
                )
            }
            return true
        } catch {
            return false
        }
    }

    private func enqueueGhostwriteProgressWrite(
        _ operation: @escaping @MainActor () async -> Bool
    ) -> Task<Bool, Never> {
        let previous = ghostwriteProgressWriteTask
        let task = Task { @MainActor in
            _ = await previous?.value
            return await operation()
        }
        ghostwriteProgressWriteTask = task
        return task
    }

    func loadGhostwriteBatchProgress(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async -> NovelGhostwriteProgress? {
        _ = await ghostwriteProgressWriteTask?.value
        do {
            guard let record = try await creation.loadGhostwriteBatchProgress(
                projectID: projectID,
                branchID: branchID
            ) else { return nil }
            return record.makeProgress()
        } catch {
            return nil
        }
    }

    func clearGhostwriteBatchProgress(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) {
        _ = enqueueGhostwriteProgressWrite { [weak self] in
            guard let self else { return false }
            do {
                try await self.creation.removeGhostwriteBatchProgress(
                    projectID: projectID,
                    branchID: branchID
                )
                return true
            } catch {
                return false
            }
        }
    }

    func composerDraft(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) -> NovelComposerDraft {
        composerDrafts[NovelComposerDraftOwner(projectID: projectID, branchID: branchID)] ?? .empty
    }

    func saveComposerDraft(
        _ draft: NovelComposerDraft,
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) {
        let owner = NovelComposerDraftOwner(projectID: projectID, branchID: branchID)
        if draft == .empty {
            composerDrafts[owner] = nil
        } else {
            composerDrafts[owner] = draft
        }
    }

    func restoreComposerDraftAfterFailedSend(
        _ draft: NovelComposerDraft,
        owner: NovelComposerDraftOwner
    ) {
        guard composerDraft(
            projectID: owner.projectID,
            branchID: owner.branchID
        ).text.isEmpty else { return }
        saveComposerDraft(draft, projectID: owner.projectID, branchID: owner.branchID)
    }

    func acquireSessionOperation(ownerID: UUID) -> Bool {
        acquireOperation(ownerID: ownerID)
    }

    func chapterPlanDraft(projectID: NovelProjectID, branchID: NovelBranchID) -> NovelChapterPlanDraft? {
        chapterPlanDrafts[projectID]?[branchID]
    }

    func retainChapterPlanDraft(_ draft: NovelChapterPlanDraft, projectID: NovelProjectID, branchID: NovelBranchID) {
        chapterPlanDrafts[projectID, default: [:]][branchID] = draft
    }

    func clearChapterPlanDraft(ifMatching draft: NovelChapterPlanDraft, projectID: NovelProjectID, branchID: NovelBranchID) {
        guard chapterPlanDrafts[projectID]?[branchID] == draft else { return }
        clearChapterPlanDraft(projectID: projectID, branchID: branchID)
    }

    func clearChapterPlanDraft(projectID: NovelProjectID, branchID: NovelBranchID) {
        chapterPlanDrafts[projectID]?[branchID] = nil
        if chapterPlanDrafts[projectID]?.isEmpty == true {
            chapterPlanDrafts[projectID] = nil
        }
    }

    func releaseSessionOperation(ownerID: UUID) {
        releaseOperation(ownerID: ownerID)
    }

    func acquireOperation(ownerID: UUID) -> Bool {
        guard !isPerforming else { return false }
        operationOwnerID = ownerID
        isPerforming = true
        return true
    }

    func releaseOperation(ownerID: UUID) {
        guard operationOwnerID == ownerID else { return }
        operationOwnerID = nil
        isPerforming = false
        // 过期标记可能在别的操作进行中写入；操作结束时补一次自动同步。
        scheduleStalePlotAutoSyncIfNeeded()
    }

    var canMutate: Bool {
        guard !isPerforming, quickStartStartingRun == nil, let projectSnapshot else { return false }
        return projectSnapshot.access == .readWrite &&
            !requiresReload &&
            !projectSnapshot.activeRuns.contains(where: { $0.status == .running })
    }

    var isProjectSelectionBlocked: Bool {
        isPerforming ||
            manualStateSyncTarget != nil ||
            automaticStateSyncPresentationTarget != nil ||
            !stateSyncStoppingTargets.isEmpty
    }

    var isStateSyncOperationRunning: Bool {
        manualStateSyncTarget != nil ||
            automaticStateSyncPresentationTarget != nil ||
            !stateSyncStoppingTargets.isEmpty
    }

    func canCancelAutomaticStateSync(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) -> Bool {
        let target = NovelAutomaticStateSyncTarget(
            projectID: projectID,
            branchID: branchID
        )
        // Stopping targets are no longer cancellable — Stop already took effect.
        return (manualStateSyncTarget == target || automaticStateSyncPresentationTarget == target)
            && !stateSyncStoppingTargets.contains(target)
    }

    func isStateSyncStopping(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) -> Bool {
        stateSyncStoppingTargets.contains(
            NovelAutomaticStateSyncTarget(projectID: projectID, branchID: branchID)
        )
    }

    /// User-visible phase copy for sync banners (running / preparing / stopping).
    func stateSyncStatusTitle(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) -> String? {
        let target = NovelAutomaticStateSyncTarget(projectID: projectID, branchID: branchID)
        if stateSyncStoppingTargets.contains(target) {
            return "正在停止剧情同步"
        }
        guard manualStateSyncTarget == target ||
                automaticStateSyncPresentationTarget == target else { return nil }
        if let activity = stateSyncActivity,
           activity.projectID == projectID,
           activity.branchID == branchID {
            return activity.statusTitle
        }
        return "正在按正文更新剧情记录"
    }

    func cancelAutomaticStateSync(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        suppressReschedule: Bool = true
    ) {
        guard canCancelAutomaticStateSync(projectID: projectID, branchID: branchID) else {
            return
        }
        let target = NovelAutomaticStateSyncTarget(projectID: projectID, branchID: branchID)
        // Only an explicit user Stop suppresses automatic reschedule. System lease
        // expiration cancels the current mutation but keeps the durable retry path live.
        if suppressReschedule {
            userSuppressedStateSyncTargets.insert(target)
        }
        // Keep a short “正在停止” presentation until task/mutation teardown finishes so
        // selection block is not unexplained after the running banner disappears.
        stateSyncStoppingTargets.insert(target)
        if let failure = automaticStateSyncFailure, failure.target == target {
            if errorMessage == failure.message {
                errorMessage = nil
            }
            automaticStateSyncFailure = nil
        }

        // Clear running presentation immediately so Stop is not a silent no-op.
        if automaticStateSyncPresentationTarget == target || automaticStateSyncTarget == target {
            automaticStateSyncTask?.cancel()
            automaticStateSyncPresentationTarget = nil
            automaticStateSyncTarget = nil
        }
        if manualStateSyncTarget == target {
            // Clear the task slot immediately. The task body previously gated cleanup on
            // `manualStateSyncPendingID == pendingID`, so cancel left an orphan task that
            // permanently blocked `startManualStateSyncRetry`.
            manualStateSyncTask?.cancel()
            manualStateSyncTask = nil
            manualStateSyncTarget = nil
            manualStateSyncPendingID = nil
        }
        if queuedAutomaticStateSyncTarget == target {
            queuedAutomaticStateSyncTarget = nil
        }
        if stateSyncActivity?.projectID == projectID,
           stateSyncActivity?.branchID == branchID,
           let activityOwnerID = stateSyncActivityOwnerID {
            stopStateSyncActivity(ownerID: activityOwnerID)
        }

        // Outer Task.cancel alone does not stop `perform` / model streaming. Cancel the
        // durable fact-sync mutation tasks so structured model requests receive cancellation.
        Task { @MainActor [weak self] in
            await self?.creation.cancelInFlightBackgroundMutations(projectID: projectID)
            // If no outer task remains to clear stopping (edge race), drop it once
            // mutation cancel returns and we are not mid-perform for another reason.
            guard let self else { return }
            if self.automaticStateSyncTask == nil,
               self.manualStateSyncTask == nil,
               !self.isPerforming {
                self.stateSyncStoppingTargets.remove(target)
            }
        }
    }

    var continuityAuditPlan: NovelContinuityAuditPlan? {
        guard let plan = continuityAuditPlanStorage,
              plan.projectID == selectedProjectID,
              plan.branchID == selectedBranchID else { return nil }
        return plan
    }

    var continuityAuditFailure: String? {
        guard let failure = continuityAuditFailureStorage,
              failure.target.projectID == selectedProjectID,
              failure.target.branchID == selectedBranchID else { return nil }
        return failure.message
    }

    var continuityRepair: NovelContinuityRepairReport? {
        guard let report = continuityRepairReport,
              report.projectID == selectedProjectID,
              report.branchID == selectedBranchID else { return nil }
        return report
    }

    var visibleContinuityIssues: [NovelContinuityIssue] {
        guard let report = continuityAudit else { return [] }
        let repaired = Set(continuityRepair?.repairedIssueIDs ?? [])
        return report.issues.filter { !repaired.contains($0.id) }
    }

    var isContinuityOperationRunning: Bool {
        isPlanningContinuity || isAuditingContinuity || isRepairingContinuity
    }

    var continuityOperationTitle: String {
        if isPlanningContinuity {
            return "正在准备剧情矛盾检查"
        }
        if isRepairingContinuity {
            return "正在修复剧情矛盾"
        }
        return "正在通读全书正文"
    }

    var presentedMessage: String? {
        errorMessage ?? reloadNoticeMessage
    }

    var requiresReload: Bool {
        reloadNoticeProjectID != nil && reloadNoticeProjectID == selectedProjectID
    }

    var hasReloadRequirement: Bool {
        reloadNoticeProjectID != nil
    }

    var activeMaterials: [NovelMaterialRecord] {
        projectSnapshot?.materials.filter { !$0.isDeleted } ?? []
    }

    func effectiveAliases(for material: NovelMaterialRecord) -> [String] {
        guard let projectSnapshot else { return material.aliases }
        return NovelPresentation.effectiveAliases(
            for: material,
            project: projectSnapshot,
            branch: branchSnapshot
        )
    }

    var activeBranches: [NovelBranchRecord] {
        projectSnapshot?.branches.filter { $0.lifecycle == .active } ?? []
    }

    var quickStartStatus: NovelQuickStartStatus {
        guard let selectedProjectID, let selectedBranchID else { return .idle }
        let owner = NovelQuickStartOwner(
            projectID: selectedProjectID,
            branchID: selectedBranchID
        )
        if let status = quickStartStatuses[owner] {
            return status
        }
        guard let projectSnapshot,
              projectSnapshot.project.creationMode == .quickStart else {
            return .idle
        }
        if let running = projectSnapshot.activeRuns.first(where: {
            $0.branchID == selectedBranchID &&
                $0.kind == .quickStart &&
                $0.status == .running
        }) {
            return .generating(runID: running.id)
        }
        let answeredPromptIDs = Set(projectSnapshot.sessions.flatMap { session in
            session.messages.compactMap { message -> NovelMessageID? in
                guard case .some(.askUserAnswer(let response)) = message.interaction else {
                    return nil
                }
                return response.promptMessageID
            }
        })
        if let promptMessage = projectSnapshot.sessions
            .first(where: { $0.branchID == selectedBranchID })?
            .messages
            .last(where: { message in
                guard message.role == .assistant,
                      case .some(.askUser) = message.interaction,
                      !answeredPromptIDs.contains(message.id),
                      let runID = message.runID else { return false }
                return projectSnapshot.activeRuns.first(where: { $0.id == runID })?.kind == .quickStart
            }) {
            return .awaitingUser(promptMessageID: promptMessage.id)
        }
        // 注意：这里用当前分支未过滤 isResolved 的 settingProposals 判空，
        // 与卡片列表用的 activeSettingProposals 不一致——用户全部接受/拒绝后
        // 仍会走到 idle 而非 failed。这是已知行为，不在本次改动范围内；
        // 「重新生成设定建议」入口走显式按钮，不依赖本状态机。
        if !projectSnapshot.settingProposals.contains(where: {
            $0.branchID == selectedBranchID
        }) {
            return .failed(message: IOSAppLocalization.string(
                "尚未生成创作建议，可以重新生成。",
                defaultValue: "尚未生成创作建议，可以重新生成。"
            ))
        }
        return .idle
    }

    func automaticStateSyncFailureMessage(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) -> String? {
        let target = NovelAutomaticStateSyncTarget(projectID: projectID, branchID: branchID)
        guard automaticStateSyncFailure?.target == target,
              selectedProjectID == projectID,
              selectedBranchID == branchID,
              branchSnapshot?.branch.syncStatus == .needsSync else { return nil }
        return automaticStateSyncFailure?.message
    }

    func retryAutomaticStateSync(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) {
        let target = NovelAutomaticStateSyncTarget(projectID: projectID, branchID: branchID)
        guard automaticStateSyncFailure?.target == target else { return }
        retryStateSync(projectID: projectID, branchID: branchID)
    }

    func retryStateSync(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) {
        let target = NovelAutomaticStateSyncTarget(projectID: projectID, branchID: branchID)
        guard selectedProjectID == projectID,
              selectedBranchID == branchID else { return }

        // Already running this branch — progress banner should be visible.
        if manualStateSyncTarget == target ||
            automaticStateSyncPresentationTarget == target {
            return
        }
        if stateSyncStoppingTargets.contains(target) {
            publishAutomaticStateSyncFailure(
                target: target,
                message: "正在停止上次同步，请稍后再点重试。"
            )
            return
        }
        guard branchSnapshot?.branch.syncStatus == .needsSync else {
            // Nothing to do; clear stale failure strip.
            if automaticStateSyncFailure?.target == target {
                automaticStateSyncFailure = nil
            }
            return
        }
        if requiresReload {
            publishAutomaticStateSyncFailure(
                target: target,
                message: "请先重新载入项目，再重试剧情同步。"
            )
            return
        }
        if projectSnapshot?.access != .readWrite {
            publishAutomaticStateSyncFailure(
                target: target,
                message: "项目当前只读，无法同步剧情。"
            )
            return
        }

        // Explicit retry must always lift Stop suppress.
        userSuppressedStateSyncTargets.remove(target)
        lastStateSyncOperationError = nil
        lastStateSyncOperationCause = nil
        if let message = errorMessage,
           message.contains("剧情同步") || message.contains("剧情状态") {
            errorMessage = nil
        }

        // Force-start: do not go through scheduleAutomaticStateSync, which can
        // silently no-op when target/task bookkeeping is stale — that cleared the
        // failure banner first and looked like a dead button.
        if automaticStateSyncTask == nil {
            // Drop zombie bookkeeping so start is not skipped.
            if automaticStateSyncTarget == target {
                automaticStateSyncTarget = nil
            }
            if queuedAutomaticStateSyncTarget == target {
                queuedAutomaticStateSyncTarget = nil
            }
            startAutomaticStateSync(target)
            return
        }

        // Another sync task is live (other branch / stuck). Queue and keep feedback visible.
        queuedAutomaticStateSyncTarget = target
        publishAutomaticStateSyncFailure(
            target: target,
            message: "已排队，等待当前同步结束后自动开始"
        )
    }

    func canRetryStateSync(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) -> Bool {
        guard selectedProjectID == projectID,
              selectedBranchID == branchID,
              branchSnapshot?.branch.syncStatus == .needsSync,
              !requiresReload,
              projectSnapshot?.access == .readWrite else { return false }
        let target = NovelAutomaticStateSyncTarget(projectID: projectID, branchID: branchID)
        // Only block retry when THIS branch is already syncing/stopping.
        // Do not use global isProjectSelectionBlocked — isPerforming from an
        // unrelated action would disable the only recovery button.
        if manualStateSyncTarget == target ||
            automaticStateSyncPresentationTarget == target ||
            stateSyncStoppingTargets.contains(target) {
            return false
        }
        return true
    }

    func stateSyncRecoveryMessage(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) -> String? {
        let target = NovelAutomaticStateSyncTarget(projectID: projectID, branchID: branchID)
        guard selectedProjectID == projectID,
              selectedBranchID == branchID,
              branchSnapshot?.branch.syncStatus == .needsSync,
              manualStateSyncTarget != target,
              automaticStateSyncPresentationTarget != target,
              !stateSyncStoppingTargets.contains(target) else { return nil }
        if let failure = automaticStateSyncFailure, failure.target == target {
            return failure.message
        }
        // Leftover cancelled JSON extract is recovered by pointer relink.
        // Do not keep its lastError (or a generic "尚未同步") as a dead banner
        // that makes 重试同步 look like the only path while relink is already
        // running without progress chrome.
        return nil
    }

    func waitForBackgroundGeneration() async {
        var unknownProbeDelayMilliseconds = 1_000
        while !Task.isCancelled {
            switch await backgroundGenerationProbe() {
            case .inactive:
                return
            case .active:
                unknownProbeDelayMilliseconds = 1_000
                try? await Task.sleep(for: .milliseconds(250))
            case .unknown:
                try? await Task.sleep(for: .milliseconds(unknownProbeDelayMilliseconds))
                unknownProbeDelayMilliseconds = min(
                    unknownProbeDelayMilliseconds * 2,
                    4_000
                )
            }
        }
    }

    func resumeDetachedBackgroundGeneration() async {
        await creation.resumeDetachedGenerationRuns()
        await loadProjects(restoresSelection: false)
    }

    func interruptSessionForBackground(deadline: Date) async {
        guard !Task.isCancelled else { return }
        // 不在这里 cancel 自动/手动剧情同步：它们有独立 keepAlive 与 expire 回调。
        // 后台总中断若一并掐掉 sync，会和代笔 awaitGhostwriteStateSync 竞态成假 syncFailed
        // （正文已收录，批进度却停在待记账）。生成 run 仍由下方 interrupt 收口。
        continuityAuditTask?.cancel()
        queuedAutomaticStateSyncTarget = nil
        var projectIDs = Set(projects.map(\.id))
        if let selectedProjectID { projectIDs.insert(selectedProjectID) }
        if let quickStartStartingProjectID { projectIDs.insert(quickStartStartingProjectID) }
        for projectID in projectIDs.sorted(by: { $0.description < $1.description }) {
            guard !Task.isCancelled else { return }
            await interruptSessionForBackground(
                projectID: projectID,
                runID: nil,
                deadline: deadline
            )
        }
        guard !Task.isCancelled, Date() < deadline else { return }
        guard let summaries = try? await projectSummaries() else { return }
        guard !Task.isCancelled, Date() < deadline else { return }
        let freshProjectIDs = Set(summaries.map(\.id)).subtracting(projectIDs)
        for projectID in freshProjectIDs.sorted(by: { $0.description < $1.description }) {
            guard !Task.isCancelled, Date() < deadline else { return }
            await interruptSessionForBackground(
                projectID: projectID,
                runID: nil,
                deadline: deadline
            )
        }
    }

    private func backgroundGenerationProbe() async -> NovelBackgroundGenerationProbe {
        if isPerforming ||
            manualStateSyncTask != nil ||
            automaticStateSyncTask != nil ||
            continuityAuditTask != nil ||
            quickStartStartingProjectID != nil {
            return .active
        }
        let summaries: [NovelProjectSummary]
        do {
            summaries = try await projectSummaries()
        } catch {
            return Task.isCancelled ? .inactive : .unknown
        }
        for summary in summaries {
            guard !Task.isCancelled else { return .inactive }
            guard summary.loadError == nil else { return .unknown }
            do {
                let snapshot = try await project(id: summary.id)
                if snapshot.activeRuns.contains(where: { $0.status == .running }) {
                    return .active
                }
            } catch {
                return Task.isCancelled ? .inactive : .unknown
            }
        }
        return .inactive
    }

    func loadProjects(
        selecting preferredProjectID: NovelProjectID? = nil,
        restoresSelection: Bool = true
    ) async {
        projectsLoadRevision &+= 1
        let revision = projectsLoadRevision
        projectListReadRevision &+= 1
        let projectListRevision = projectListReadRevision
        isLoading = true
        defer {
            if revision == projectsLoadRevision {
                isLoading = false
            }
        }
        do {
            let loadedProjects = try await projectSummaries()
            try Task.checkCancellation()
            // 仅接受最新一次加载的结果；较早响应静默丢弃，防止旧快照回写。
            guard revision == projectsLoadRevision,
                  projectListRevision == projectListReadRevision else { return }
            updateProjectsIfChanged(loadedProjects)
            projectListLoadError = nil
            guard restoresSelection else {
                errorMessage = nil
                return
            }
            let nextID = preferredProjectID.flatMap { preferred in
                projects.contains(where: { $0.id == preferred }) ? preferred : nil
            } ?? selectedProjectID.flatMap { selected in
                projects.contains(where: { $0.id == selected }) ? selected : nil
            }
            if let nextID {
                await selectProject(nextID)
            } else {
                if selectedProjectID != nil {
                    clearSelection()
                }
                errorMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            // 过期加载的失败同样不得覆盖最新状态。
            guard revision == projectsLoadRevision,
                  projectListRevision == projectListReadRevision else { return }
            projectListLoadError = errorDescription(error)
            report(error)
        }
    }

    @discardableResult
    func selectProject(_ projectID: NovelProjectID) async -> Bool {
        if selectedProjectID != projectID, isProjectSelectionBlocked {
            report(NovelError.projectBusy(selectedProjectID ?? projectID))
            return false
        }
        let preferredBranchID = selectedProjectID == projectID
            ? selectedBranchID
            : lastSelectedBranchIDs[projectID]
        let intentToken = UUID()
        selectionIntentToken = intentToken
        let token = UUID()
        selectionToken = token
        isLoading = true
        defer {
            if selectionToken == token { isLoading = false }
        }
        do {
            let project = try await project(id: projectID)
            let branchID = preferredBranchID.flatMap { preferred in
                project.branches.first(where: {
                    $0.id == preferred && $0.lifecycle == .active
                })?.id
            } ?? project.branches.first(where: {
                $0.id == project.project.mainBranchID && $0.lifecycle == .active
            })?.id ?? project.branches.first(where: { $0.lifecycle == .active })?.id
            let loadedBranch: NovelBranchSnapshot?
            if let branchID {
                loadedBranch = try await branch(projectID: projectID, branchID: branchID)
            } else {
                loadedBranch = nil
            }
            try Task.checkCancellation()
            guard selectionIntentToken == intentToken,
                  selectionToken == token else { return false }
            selectedProjectID = projectID
            projectSnapshot = project
            refreshCheckoutSidecarFailure(for: projectID)
            selectedBranchID = branchID
            branchSnapshot = loadedBranch
            if let branchID { lastSelectedBranchIDs[projectID] = branchID }
            injectionPreview = nil
            errorMessage = nil
            if reloadNoticeProjectID == projectID {
                clearReloadRequirement()
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard selectionIntentToken == intentToken,
                  selectionToken == token else { return false }
            report(error)
            return false
        }
    }

    @discardableResult
    func selectBranch(
        _ branchID: NovelBranchID,
        stoppingActiveRun: Bool = true
    ) async -> NovelBranchSelectionResult {
        guard let projectID = selectedProjectID else { return .failed }
        guard branchID != selectedBranchID else { return .selected }
        guard !isProjectSelectionBlocked else {
            report(NovelError.projectBusy(projectID))
            return .failed
        }
        let operationOwnerID = UUID()
        guard acquireOperation(ownerID: operationOwnerID) else { return .failed }
        let intentToken = UUID()
        selectionIntentToken = intentToken
        selectionToken = UUID()
        isLoading = true
        defer {
            if self.operationOwnerID == operationOwnerID,
               selectionIntentToken == intentToken {
                isLoading = false
            }
            releaseOperation(ownerID: operationOwnerID)
        }
        var interruptedSourceBranchID: NovelBranchID?
        do {
            guard let sourceBranchID = selectedBranchID else { return .failed }
            let authoritativeSource = try await branch(
                projectID: projectID,
                branchID: sourceBranchID
            )
            let authoritativeProject = try await project(id: projectID)
            guard selectionIntentToken == intentToken,
                  self.operationOwnerID == operationOwnerID,
                  selectedProjectID == projectID,
                  selectedBranchID == sourceBranchID else { return .failed }
            selectionToken = UUID()
            projectSnapshot = authoritativeProject
            branchSnapshot = rebasedBranchSnapshot(
                authoritativeSource,
                onto: authoritativeProject
            )
            injectionPreview = nil

            let validatedTarget = try await branch(
                projectID: projectID,
                branchID: branchID
            )
            guard selectionIntentToken == intentToken,
                  self.operationOwnerID == operationOwnerID,
                  selectedProjectID == projectID,
                  selectedBranchID == sourceBranchID else { return .failed }

            let activeRun = authoritativeProject.activeRuns.first(where: {
                $0.branchID == sourceBranchID && $0.status == .running
            })
            if activeRun != nil, !stoppingActiveRun {
                errorMessage = nil
                return .requiresStoppingActiveRun
            }

            let refreshedProject: NovelProjectSnapshot
            let snapshot: NovelBranchSnapshot
            if let activeRun {
                let source = authoritativeProject.branches.first(where: {
                    $0.id == sourceBranchID
                }) ?? authoritativeSource.branch
                try await interruptSessionRun(NovelCancelRunCommand(
                    context: NovelMutationContext(
                        operationID: NovelOperationID(),
                        expectedProjectRevision: authoritativeProject.project.revision,
                        expectedConfigRevision: authoritativeProject.project.configRevision,
                        expectedBranchHeadRevision: source.headRevision
                    ),
                    projectID: projectID,
                    runID: activeRun.id,
                    reason: .routeExit
                ))
                interruptedSourceBranchID = sourceBranchID
                let project = try await project(id: projectID)
                refreshedProject = project
                snapshot = rebasedBranchSnapshot(validatedTarget, onto: project)
            } else {
                refreshedProject = authoritativeProject
                snapshot = rebasedBranchSnapshot(validatedTarget, onto: authoritativeProject)
            }
            guard selectionIntentToken == intentToken,
                  self.operationOwnerID == operationOwnerID,
                  selectedProjectID == projectID,
                  selectedBranchID == sourceBranchID else { return .failed }
            selectionToken = UUID()
            projectSnapshot = refreshedProject
            refreshCheckoutSidecarFailure(for: projectID)
            selectedBranchID = branchID
            branchSnapshot = snapshot
            lastSelectedBranchIDs[projectID] = branchID
            injectionPreview = nil
            errorMessage = nil
            return .selected
        } catch {
            if let interruptedSourceBranchID,
               let refreshedProject = try? await project(id: projectID),
               let refreshedBranch = try? await branch(
                   projectID: projectID,
                   branchID: interruptedSourceBranchID
               ),
               selectionIntentToken == intentToken,
               self.operationOwnerID == operationOwnerID,
               selectedProjectID == projectID {
                selectionToken = UUID()
                projectSnapshot = refreshedProject
                refreshCheckoutSidecarFailure(for: projectID)
                selectedBranchID = interruptedSourceBranchID
                branchSnapshot = refreshedBranch
                lastSelectedBranchIDs[projectID] = interruptedSourceBranchID
                injectionPreview = nil
            }
            guard selectionIntentToken == intentToken,
                  self.operationOwnerID == operationOwnerID,
                  selectedProjectID == projectID else { return .failed }
            report(error)
            return .failed
        }
    }

    @discardableResult
    func createProject(
        name: String,
        branchName: String = "主线",
        mode: NovelProjectCreationMode,
        genre: String = "",
        coreIdea: String = ""
    ) async -> NovelProjectID? {
        let projectID = NovelProjectID()
        let command = NovelCreateProjectCommand(
            context: mutationContext(),
            projectID: projectID,
            branchID: NovelBranchID(),
            sessionID: NovelSessionID(),
            initialStateSnapshotID: NovelStateSnapshotID(),
            initialCheckpointID: NovelCheckpointID(),
            name: name,
            branchName: branchName,
            creationMode: mode,
            quickStartSeed: mode == .quickStart
                ? NovelQuickStartSeed(genre: genre, coreIdea: coreIdea)
                : nil
        )
        guard await perform(.createProject(command), selecting: projectID) else { return nil }
        if mode == .quickStart, projectSnapshot?.project.id == projectID {
            await startQuickStartSuggestions()
        }
        return projectID
    }

    @discardableResult
    func previewInjection(
        _ request: NovelInjectionPreviewRequest
    ) async -> NovelInjectionPreviewSnapshot? {
        let ownerID = UUID()
        guard acquireOperation(ownerID: ownerID) else { return nil }
        defer { releaseOperation(ownerID: ownerID) }
        injectionPreview = nil
        do {
            guard case .injectionPreview(let preview) = try await creation.snapshot(
                .injectionPreview(request)
            ) else {
                throw NovelError.invalidInput("注入预览返回了意外的快照，请重试。")
            }
            guard preview.projectID == selectedProjectID,
                  preview.branchID == selectedBranchID else { return nil }
            injectionPreview = preview
            errorMessage = nil
            return preview
        } catch {
            report(error)
            return nil
        }
    }

}

extension NovelProjectSummary {
    init(snapshot: NovelProjectSnapshot) {
        id = snapshot.project.id
        name = snapshot.project.name
        mainBranchID = snapshot.project.mainBranchID
        updatedAt = snapshot.project.updatedAt
        revision = snapshot.project.revision
        isDegraded = snapshot.access != .readWrite
        hasRunningRun = snapshot.activeRuns.contains(where: { $0.status == .running })
        loadError = nil
    }
}
