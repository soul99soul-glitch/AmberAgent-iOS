import Foundation
import Observation
import UIKit

extension NovelCreationViewModel {
    @discardableResult
    func syncWorkingManuscript(preferStateDelta: Bool) async -> Bool {
        guard let project = projectSnapshot,
              let branch = branchSnapshot,
              branch.branch.syncStatus == .needsSync else {
            return true
        }
        let target = NovelAutomaticStateSyncTarget(
            projectID: project.project.id,
            branchID: branch.branch.id
        )
        automaticStateSyncPresentationTarget = target
        defer {
            if automaticStateSyncPresentationTarget == target {
                automaticStateSyncPresentationTarget = nil
            }
            stateSyncStoppingTargets.remove(target)
        }
        return await perform(.syncManualEdits(NovelSyncManualEditsCommand(
            context: mutationContext(
                projectRevision: project.project.revision,
                configRevision: project.project.configRevision,
                branchHeadRevision: branch.branch.headRevision
            ),
            projectID: project.project.id,
            branchID: branch.branch.id,
            pendingID: NovelPendingOperationID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            expectedWorkingRevision: branch.branch.workingRevision,
            preferStateDelta: preferStateDelta
        )))
    }

    func startSessionRun(
        _ request: NovelRunRequest,
        acquiresBackgroundLease: Bool = true
    ) async throws -> NovelRun {
        if acquiresBackgroundLease {
            beginBackgroundGeneration(for: request)
        }
        do {
            return try await creation.start(request)
        } catch {
            if acquiresBackgroundLease {
                endBackgroundGeneration(for: request.id)
            }
            throw error
        }
    }

    /// 在已经取得 session 单写者之后、第一次 await 之前取得后台执行权。
    /// 代笔内层正文沿用整批 lease，避免每章再挂一条会独立过期的短 lease。
    func beginBackgroundGeneration(for request: NovelRunRequest) {
        let leaseID = novelRunBackgroundLeaseID(for: request.id)
        let ghostwriteLeaseID = novelGhostwriteBackgroundLeaseID(
            projectID: request.projectID,
            branchID: request.branchID
        )
        if request.ghostwritePlanID != nil,
           BackgroundGenerationKeepAlive.shared.holdsLease(ghostwriteLeaseID) {
            BackgroundGenerationKeepAlive.shared.advanceProgress(
                ghostwriteLeaseID,
                by: 1,
                subtitle: IOSAppLocalization.string("正在生成正文", defaultValue: "正在生成正文")
            )
            return
        }

        // 普通正文生成由当前用户动作直接申请 continued-processing；等首段输出
        // 再提交会错过退后台后的申请窗口。
        BackgroundGenerationKeepAlive.shared.begin(
            leaseID,
            title: IOSAppLocalization.string(
                "Amber 小说创作中",
                defaultValue: "Amber 小说创作中"
            ),
            subtitle: IOSAppLocalization.string("准备生成", defaultValue: "准备生成"),
            onExpire: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleNovelGenerationKeepAliveLoss(
                        projectID: request.projectID,
                        runID: request.id,
                        rearm: { self?.beginBackgroundGeneration(for: request) }
                    )
                }
            },
            onSystemTaskExpiration: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleNovelGenerationKeepAliveLoss(
                        projectID: request.projectID,
                        runID: request.id,
                        rearm: { self?.beginBackgroundGeneration(for: request) }
                    )
                }
            }
        )
        BackgroundGenerationKeepAlive.shared.updateProgress(
            leaseID,
            completed: 0,
            total: -1,
            subtitle: IOSAppLocalization.string("准备生成", defaultValue: "准备生成")
        )
    }

    /// KeepAlive 短窗/系统进度卡丢失时：
    /// - 非后台（前台 / inactive 控制中心等）：不砍流，重挂租约。
    /// - 真正进后台：可持久化中断（有 cursor 则 detach，否则 interrupt）。
    private func handleNovelGenerationKeepAliveLoss(
        projectID: NovelProjectID,
        runID: NovelRunID,
        rearm: () -> Void
    ) async {
        // inactive（下拉通知中心、App Switcher 半屏）不能当后台砍流。
        if UIApplication.shared.applicationState != .background {
            rearm()
            return
        }
        await interruptSessionForBackground(
            projectID: projectID,
            runID: runID,
            deadline: Date()
        )
    }

    func endBackgroundGeneration(for runID: NovelRunID) {
        BackgroundGenerationKeepAlive.shared.end(novelRunBackgroundLeaseID(for: runID))
    }

    func performSessionAction(_ action: NovelAction) async throws -> NovelOutcome {
        // Session-driven actions (e.g. explicit "retry") reach here without going
        // through the private `perform(_:)` wiring, so this call is the only place
        // left to publish `stateSyncActivity` for them. Reuse the exact same
        // start/stop helpers and key them off the operation owner that the caller
        // (NovelSessionViewModel.beginAction) already acquired, so ownership stays
        // single-writer and consistent with the automatic-sync path.
        let stateSyncContext = stateSyncContext(for: action)
        let activityOwnerID = stateSyncContext != nil ? operationOwnerID : nil
        if let stateSyncContext, let activityOwnerID {
            startStateSyncActivity(
                ownerID: activityOwnerID,
                projectID: action.projectID,
                branchID: stateSyncContext.branchID,
                pendingID: stateSyncContext.pendingID,
                attemptOperationID: stateSyncContext.attemptOperationID
            )
        }
        defer {
            if stateSyncContext != nil, let activityOwnerID {
                stopStateSyncActivity(ownerID: activityOwnerID)
            }
        }
        ownMutationOperationIDs.insert(action.context.operationID)
        return try await creation.perform(action)
    }

    func distillDiscussionArchive(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        chapterID: NovelChapterID?
    ) async throws -> NovelDiscussionArchiveDraft {
        try await creation.distillDiscussionArchive(
            projectID: projectID,
            branchID: branchID,
            chapterID: chapterID
        )
    }

    func acceptChapterPlan(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID
    ) async throws -> NovelChapterPlanAcceptanceV1 {
        try await creation.acceptChapterPlan(
            projectID: projectID,
            branchID: branchID,
            candidateID: candidateID
        )
    }

    func adjudicateAndCollectGhostwriteChapter(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID,
        prepareNextPlan: Bool
    ) async throws -> NovelGhostwriteChapterAdjudicationResult {
        let result = try await creation.adjudicateAndCollectGhostwriteChapter(
            projectID: projectID,
            branchID: branchID,
            candidateID: candidateID,
            prepareNextPlan: prepareNextPlan
        )
        // A refresh failure after the atomic commit must not turn into another
        // adjudication/model request. The session performs its own durable refresh too.
        if result.didCollect {
            _ = try? await refreshCurrentSelection(
                projectID: projectID,
                refreshProjectList: false
            )
        }
        return result
    }

    func proposeAndConfirmNextChapterPlan(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        nextChapterOrdinal: Int,
        previousPlanSummary: String?
    ) async throws -> NovelChapterPlanRecord {
        let plan = try await creation.proposeAndConfirmNextChapterPlan(
            projectID: projectID,
            branchID: branchID,
            nextChapterOrdinal: nextChapterOrdinal,
            previousPlanSummary: previousPlanSummary
        )
        // 自动确认合同后刷新快照，供代笔 pipeline 立刻读到新 digest。
        try await refreshCurrentSelection(
            projectID: projectID,
            refreshProjectList: false
        )
        return plan
    }

    /// 根据前文生成草稿本章计划（不自动确认）；成功后尽量刷新快照。
    /// 刷新失败不吞掉已生成的 plan（调用方可用返回值回填）。
    func proposeNextChapterPlanDraft(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        nextChapterOrdinal: Int,
        previousPlanSummary: String?
    ) async throws -> NovelChapterPlanRecord {
        let plan = try await creation.proposeNextChapterPlanDraft(
            projectID: projectID,
            branchID: branchID,
            nextChapterOrdinal: nextChapterOrdinal,
            previousPlanSummary: previousPlanSummary
        )
        // 刷新失败不抛：盘上已有 draft，调用方用返回的 plan 回填字段。
        _ = try? await refreshCurrentSelection(
            projectID: projectID,
            refreshProjectList: false
        )
        return plan
    }

    func auditContinuityIncludingCandidate(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID,
        maxPriorManuscriptChapters: Int? = nil
    ) async throws -> NovelContinuityAuditReport {
        try await creation.auditContinuityIncludingCandidate(
            projectID: projectID,
            branchID: branchID,
            candidateID: candidateID,
            maxPriorManuscriptChapters: maxPriorManuscriptChapters
        )
    }

    func interruptSessionRun(_ command: NovelCancelRunCommand) async throws {
        let quickStartOwner = quickStartOwner(
            projectID: command.projectID,
            runID: command.runID
        )
        if let quickStartOwner {
            cancelledQuickStartRunIDs.insert(command.runID)
            if !quickStartCreationStartRunIDs.contains(command.runID) {
                quickStartTasks[quickStartOwner]?.cancel()
            }
        }
        do {
            try await creation.interruptRun(command)
        } catch {
            if let quickStartOwner,
               let novelError = error as? NovelError,
               novelError == .runNotFound(command.runID) {
                clearQuickStartTask(
                    owner: quickStartOwner,
                    runID: command.runID,
                    status: .failed(message: IOSAppLocalization.string(
                        "建议生成已中断，可以重新生成。",
                        defaultValue: "建议生成已中断，可以重新生成。"
                    ))
                )
                return
            }
            if quickStartOwner != nil {
                cancelledQuickStartRunIDs.remove(command.runID)
            }
            throw error
        }
        if let quickStartOwner {
            await reconcileQuickStartAfterInterrupt(
                owner: quickStartOwner,
                runID: command.runID
            )
        }
    }

    func retrySessionTerminal(runID: NovelRunID) async throws {
        try await creation.retryPendingTerminal(runID: runID)
    }

    func interruptSessionForBackground(
        projectID: NovelProjectID,
        runID: NovelRunID?,
        deadline: Date
    ) async {
        let quickStartOwner = quickStartTaskRunIDs.keys.first(where: {
            $0.projectID == projectID &&
                (runID == nil || quickStartTaskRunIDs[$0] == runID)
        })
        let quickStartRunID = quickStartOwner.flatMap { quickStartTaskRunIDs[$0] }
        let effectiveRunID = runID ?? quickStartRunID
        if let quickStartOwner, let quickStartRunID {
            cancelledQuickStartRunIDs.insert(quickStartRunID)
            if !quickStartCreationStartRunIDs.contains(quickStartRunID) {
                quickStartTasks[quickStartOwner]?.cancel()
            }
        }
        await creation.interruptForBackground(
            projectID: projectID,
            deadline: deadline,
            runID: effectiveRunID
        )
        if let quickStartOwner, let quickStartRunID {
            await reconcileQuickStartAfterInterrupt(
                owner: quickStartOwner,
                runID: quickStartRunID
            )
        }
        // Foreground recovery can race ahead of the expiration callback and
        // scan before this method has detached the response. Re-scan only when
        // the app is actually active after the interruption finishes.
        if UIApplication.shared.applicationState == .active {
            await creation.resumeDetachedGenerationRuns()
        }
    }

}
