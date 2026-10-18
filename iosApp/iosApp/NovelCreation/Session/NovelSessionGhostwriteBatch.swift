import Foundation

extension NovelSessionViewModel {
    var ghostwriteProgress: NovelGhostwriteProgress? {
        guard let progress = ghostwriteProgressStorage,
              progress.binding == binding,
              snapshotMatchesBinding else { return nil }
        return progress
    }

    var isGhostwriting: Bool {
        switch ghostwriteProgress?.phase {
        case .writing, .accepting, .collecting, .syncing, .planning, .revising: true
        case .paused, .waitingUser, .failed, nil: false
        }
    }

    /// 书名面板左上「结束」：进行中或本批仍可续时，结束整批而不是只收起面板。
    var canCancelGhostwriteBatch: Bool {
        if isGhostwriting { return true }
        return ghostwriteProgress?.shouldContinueSameBatch == true
    }

    /// 批中合同已消费、同步失败或拟计划失败时，允许无确认合同续跑。
    private var canResumeGhostwriteWithoutPlan: Bool {
        guard let progress = ghostwriteProgressStorage,
              progress.binding == binding,
              progress.canResumeWithoutConfirmedPlan else { return false }
        return true
    }

    var ghostwriteReadinessIssue: NovelGhostwriteReadinessIssue? {
        guard let project = workspace.projectSnapshot,
              let branchID = binding?.branchID else { return .branchNeedsSync }
        var issues = NovelGhostwriteReadiness.issues(
            materials: project.materials,
            materialRevisions: project.materialRevisions,
            branches: project.branches,
            pendingOperations: project.pendingOperations,
            polishTransactions: project.polishTransactions,
            activeRuns: project.activeRuns,
            chapterPlans: project.chapterPlans,
            stateSnapshots: project.stateSnapshots,
            mainBranchID: project.project.mainBranchID,
            branchID: branchID,
            requireChapterPlan: !canResumeGhostwriteWithoutPlan
        )
        if canResumeGhostwriteWithoutPlan {
            issues.removeAll { $0 == .missingChapterPlan }
        }
        // 批中续跑：同步由 pipeline 内 await，不在入口把「继续」整灰。
        if ghostwriteProgressStorage?.shouldContinueSameBatch == true {
            issues.removeAll { $0 == .branchNeedsSync }
            let onlyManualSyncPending = branchPendingOperations.allSatisfy {
                $0.kind == .manualSync
            }
            if unresolvedBranchPolishTransactions.isEmpty,
               onlyManualSyncPending || branchPendingOperations.isEmpty {
                issues.removeAll { $0 == .pendingOperations }
            }
        }
        return issues.first
    }

    var canStartGhostwriteChapter: Bool {
        guard ghostwriteBlocker == nil,
              let branchID = binding?.branchID,
              workspace.projectSnapshot?.project.collaborationMode == .ghostwrite
        else { return false }
        // Contract v1.1 D-D: unresolved plot modules gate forward writing;
        // the underlying prose run explains the reason via startBlockerMessage.
        if workspace.branchSnapshot?.currentState.hasStaleChapterPlots == true {
            return false
        }
        if canResumeGhostwriteWithoutPlan { return true }
        // 完批后开新批：允许没有确认计划（pipeline 自动拟定），与批内第 2～N 章同路径。
        if ghostwriteProgressStorage?.pauseReason == .batchCompleted
            || ghostwriteProgressStorage?.pauseReason == .chapterCompleted {
            return true
        }
        return workspace.projectSnapshot?.confirmedChapterPlan(for: branchID) != nil
    }

    /// 主界面继续键禁用时的原因；面板已有缺项行，状态条原先不显示。
    var ghostwriteContinueBlockerMessage: String? {
        guard !canStartGhostwriteChapter else { return nil }
        if let issue = ghostwriteReadinessIssue {
            return issue.displayName
        }
        if workspace.branchSnapshot?.currentState.hasStaleChapterPlots == true {
            return NovelWorkspaceLedger.unresolvedPlotGateMessage
        }
        return ghostwriteBlocker?.displayName
    }

    var ghostwriteBlocker: NovelSessionActionBlocker? {
        guard access == .readWrite else { return .projectReadOnly }
        if workspace.requiresReload || hasRefreshError { return .reloadRequired }
        if isGhostwriting { return .transactionInProgress }
        if isBatchPolishing { return .transactionInProgress }
        if isRunning { return .generationRunning }
        let continuingBatch = ghostwriteProgressStorage?.shouldContinueSameBatch == true
        // 续跑时允许在 needsSync / 仅剩 manualSync pending 下点继续，pipeline 内再等同步。
        if needsSync, !continuingBatch, !canResumeGhostwriteWithoutPlan {
            return .branchNeedsSync
        }
        let blockingPending = branchPendingOperations.filter { pending in
            if continuingBatch, pending.kind == .manualSync { return false }
            return true
        }
        if !blockingPending.isEmpty || !unresolvedBranchPolishTransactions.isEmpty {
            return .pendingOperation
        }
        if isBusy { return .transactionInProgress }
        if workspace.projectSnapshot?.project.collaborationMode != .ghostwrite {
            return .chapterPlanRequired
        }
        if ghostwriteReadinessIssue != nil { return .ghostwriteRequirementsMissing }
        return nil
    }

    @discardableResult
    func startGhostwriteChapter(
        targetChapterCount: Int? = nil,
        preservingAttemptBudget: Bool = false
    ) -> Bool {
        guard ghostwriteTask == nil,
              let binding,
              canStartGhostwriteChapter
        else {
            let blocker = ghostwriteBlocker
            if blocker == .ghostwriteRequirementsMissing,
               let readinessIssue = ghostwriteReadinessIssue {
                operationErrorMessage = readinessIssue.displayName
            } else if workspace.branchSnapshot?.currentState.hasStaleChapterPlots == true {
                // Contract v1.1 D-D gate: surface the actionable reason.
                operationErrorMessage = NovelWorkspaceLedger.unresolvedPlotGateMessage
            } else {
                operationErrorMessage = blocker?.displayName ?? "代笔暂时不能开始。"
            }
            return false
        }
        let previous = ghostwriteProgressStorage
        let sameBinding = previous?.binding == binding
        // 与面板「继续代笔」同义，避免 cancelled 显示「开始」却仍续旧批。
        let resumingBatch = sameBinding && (previous?.shouldContinueSameBatch == true)
        let target = NovelGhostwriteBatch.clamp(
            resumingBatch
                ? (previous?.targetChapterCount ?? ghostwriteTargetChapterCount)
                : (targetChapterCount ?? ghostwriteTargetChapterCount)
        )
        let confirmedPlan = workspace.projectSnapshot?.confirmedChapterPlan(for: binding.branchID)
        let planChangedOnResume = resumingBatch
            && previous?.shouldDropCandidateBecauseConfirmedPlanChanged(confirmedPlan?.contentDigest) == true
        let rewriteOnResume = planChangedOnResume || previous?.mustRewriteCandidateOnResume == true
        // 完批后开新批：允许没有确认计划直接进入 pipeline 的 planning 阶段自动拟定
        //（与批内第 2～N 章同路径，proposeAndConfirmNextChapterPlan）。
        // 首次启动（无前批）仍需用户手动确认计划。
        let isStartingNewBatchAfterCompletion = !resumingBatch
            && (previous?.pauseReason == .batchCompleted || previous?.pauseReason == .chapterCompleted)
        if confirmedPlan == nil,
           !canResumeGhostwriteWithoutPlan,
           !isStartingNewBatchAfterCompletion {
            operationErrorMessage = "代笔需要已确认的本章计划。"
            return false
        }
        operationErrorMessage = nil
        // 续跑保留本批幂等集合；新批清空，避免「进度 0/N」却显示「本批已收录 5 章」。
        let retainedCollected = resumingBatch
            ? (previous?.autoCollectedCandidateIDs ?? [])
            : []
        // 质量失败或合同已换：继续必须重写，禁止同稿再验。
        let retainedCandidate: NovelCandidateID? = {
            guard resumingBatch else { return nil }
            if rewriteOnResume { return nil }
            return previous?.candidateID
        }()
        let retainedSuperseded: Set<NovelCandidateID> = {
            guard resumingBatch else { return [] }
            var set = previous?.supersededCandidateIDs ?? []
            if rewriteOnResume {
                if let old = previous?.candidateID { set.insert(old) }
                if let source = previous?.lastFailureReceipt?.sourceCandidateID {
                    set.insert(source)
                }
            }
            return set
        }()
        let completed = resumingBatch ? (previous?.completedChapterCount ?? 0) : 0
        let currentIndex = resumingBatch
            ? max(previous?.currentChapterIndex ?? 1, completed + 1)
            : 1
        if resumingBatch, let previousTarget = previous?.targetChapterCount {
            // 本批 N 在开跑时固定；面板 Stepper 不得在续跑时改写目标。
            ghostwriteTargetChapterCount = previousTarget
        }
        let openingPhase: NovelGhostwritePhase = {
            if resumingBatch, previous?.pendingSyncChapterCredit == true { return .syncing }
            if confirmedPlan == nil { return .planning }
            if resumingBatch, previous?.revisionBriefOverride != nil { return .revising }
            return .writing
        }()
        ghostwriteProgressStorage = NovelGhostwriteProgress(
            binding: binding,
            phase: openingPhase,
            // 一旦真正开始续跑，旧暂停原因就不再是当前状态；失败回执仍单独保留，
            // 因此质量续跑依旧会重写对应候选。
            pauseReason: nil,
            detailMessage: nil,
            candidateID: retainedCandidate,
            chapterPlanDigest: confirmedPlan?.contentDigest,
            autoCollectedCandidateIDs: retainedCollected,
            startedAt: resumingBatch ? (previous?.startedAt ?? Date()) : Date(),
            targetChapterCount: target,
            completedChapterCount: completed,
            currentChapterIndex: currentIndex,
            lastCompletedPlanSummary: resumingBatch ? previous?.lastCompletedPlanSummary : nil,
            pendingSyncChapterCredit: resumingBatch
                ? (previous?.pendingSyncChapterCredit ?? false)
                : false,
            // 人手点继续/润修后给新的自动改写预算，并清空指纹环（避免立刻熔断）。
            qualityAttemptIndex: {
                guard resumingBatch else { return 0 }
                if rewriteOnResume, !preservingAttemptBudget { return 0 }
                return previous?.qualityAttemptIndex ?? 0
            }(),
            maxQualityAttempts: resumingBatch
                ? (previous?.maxQualityAttempts ?? NovelGhostwriteHeal.defaultMaxQualityAttempts)
                : NovelGhostwriteHeal.defaultMaxQualityAttempts,
            lastFailureReceipt: {
                guard resumingBatch, !planChangedOnResume else { return nil }
                return previous?.lastFailureReceipt
            }(),
            supersededCandidateIDs: retainedSuperseded,
            recentFailureFingerprints: {
                guard resumingBatch else { return [] }
                // 人手续跑：清 fuse，避免「两次同指纹后继续」第一次就熔断。
                if (rewriteOnResume && !preservingAttemptBudget)
                    || previous?.revisionBriefOverride != nil {
                    return []
                }
                return previous?.recentFailureFingerprints ?? []
            }(),
            revisionBriefOverride: resumingBatch ? previous?.revisionBriefOverride : nil,
            didThinContractAmendThisChapter: {
                guard resumingBatch, !planChangedOnResume else { return false }
                return previous?.didThinContractAmendThisChapter ?? false
            }(),
            contractAmendments: {
                guard resumingBatch, !planChangedOnResume else { return [] }
                return previous?.contractAmendments ?? []
            }(),
            infraRetryCount: 0
        )
        ghostwriteTaskBinding = binding
        let backgroundLeaseOwnerID = UUID()
        ghostwriteBackgroundLeaseOwnerID = backgroundLeaseOwnerID
        beginGhostwriteBackgroundLease(
            binding: binding,
            ownerID: backgroundLeaseOwnerID
        )
        ghostwriteTask = Task { @MainActor [weak self] in
            await self?.runGhostwriteBatch(binding: binding)
            if let self,
               self.ghostwriteBackgroundLeaseOwnerID == backgroundLeaseOwnerID {
                BackgroundGenerationKeepAlive.shared.end(
                    novelGhostwriteBackgroundLeaseID(
                        projectID: binding.projectID,
                        branchID: binding.branchID
                    )
                )
            }
            guard let self,
                  self.ghostwriteBackgroundLeaseOwnerID == backgroundLeaseOwnerID,
                  self.ghostwriteTaskBinding == binding else { return }
            self.ghostwriteBackgroundLeaseOwnerID = nil
            self.ghostwriteTask = nil
            self.ghostwriteTaskBinding = nil
            self.ghostwriteOwnedRunID = nil
            self.isGhostwriteStartingRun = false
        }
        if let progress = ghostwriteProgressStorage {
            persistGhostwriteProgress(progress)
        }
        return true
    }

    func pauseGhostwrite() {
        guard ghostwriteTask != nil else { return }
        ghostwriteAbandonBatch = false
        ghostwriteCancelAsUserPause = true
        mutateGhostwriteProgress {
            $0.pauseReason = .userPaused
            if $0.phase == .writing || $0.phase == .accepting || $0.phase == .collecting
                || $0.phase == .planning || $0.phase == .revising {
                $0.phase = .paused
            }
        }
        ghostwriteTask?.cancel()
    }

    /// 结束当前这一批：已收录的章留在正文；未写完的停掉。下次「开始」算新批。
    func cancelGhostwriteBatch() {
        guard canCancelGhostwriteBatch else { return }
        ghostwriteCancelAsUserPause = false
        ghostwriteAbandonBatch = true
        mutateGhostwriteProgress {
            if $0.pendingSyncChapterCredit {
                _ = $0.applyPendingSyncChapterCredit()
            }
            $0.revisionBriefOverride = nil
            if $0.isBatchComplete {
                $0.phase = .waitingUser
                $0.pauseReason = .batchCompleted
                $0.detailMessage = NovelGhostwritePauseReason.batchCompleted.displayMessage
            } else {
                $0.phase = .paused
                $0.pauseReason = .cancelled
                $0.detailMessage = "本批代笔已结束。已收录的章节仍在正文里。"
            }
        }
        if ghostwriteTask != nil {
            ghostwriteTask?.cancel()
        } else {
            ghostwriteAbandonBatch = false
        }
    }

    @discardableResult
    func continueGhostwriteChapter() -> Bool {
        guard ghostwriteTask == nil else { return false }
        return startGhostwriteChapter()
    }

    /// 人工润修：写入可编辑 brief 后按自愈写路径重开本章（隔离会话历史）。
    @discardableResult
    func startGhostwriteRevision(brief: String) -> Bool {
        guard ghostwriteTask == nil, binding != nil else {
            operationErrorMessage = "代笔暂时不能开始。"
            return false
        }
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            operationErrorMessage = "请先填写润修要求。"
            return false
        }
        guard var progress = ghostwriteProgressStorage,
              progress.binding == binding,
              progress.shouldOfferRevisionSheet
        else {
            operationErrorMessage = "当前没有可润修的代笔中断状态。"
            return false
        }
        // 保留 pauseReason 使 shouldContinueSameBatch 仍为 true；brief 在 start 重建 progress 时带上。
        // receipt.sourceCandidateID 供 obtain 取上一稿正文；candidateID 仍作废以免同稿再验。
        if let old = progress.candidateID {
            if progress.lastFailureReceipt?.sourceCandidateID == nil {
                if let receipt = progress.lastFailureReceipt {
                    progress.lastFailureReceipt = NovelGhostwriteFailureReceipt.make(
                        reason: receipt.reason,
                        summary: receipt.summary,
                        missingMustHappen: receipt.missingMustHappen,
                        repetitionBeats: receipt.repetitionBeats,
                        continuityNotes: receipt.continuityNotes,
                        attemptIndex: receipt.attemptIndex,
                        sourceCandidateID: old,
                        planDigest: receipt.planDigest
                    )
                } else {
                    progress.lastFailureReceipt = NovelGhostwriteFailureReceipt.make(
                        reason: progress.pauseReason ?? .healBudgetExhausted,
                        summary: progress.detailMessage ?? "",
                        attemptIndex: progress.qualityAttemptIndex,
                        sourceCandidateID: old,
                        planDigest: progress.chapterPlanDigest
                    )
                }
            }
            progress.supersededCandidateIDs.insert(old)
        }
        progress.candidateID = nil
        progress.revisionBriefOverride = trimmed
        progress.qualityAttemptIndex = 0
        progress.detailMessage = "按审稿意见润修中…"
        ghostwriteProgressStorage = progress
        return startGhostwriteChapter()
    }

    func cancelGhostwriteForBindingChange(
        from expectedBinding: NovelSessionBinding?
    ) async {
        guard let expectedBinding else {
            ghostwriteProgressStorage = nil
            return
        }
        if ghostwriteTaskBinding == expectedBinding, let task = ghostwriteTask {
            // 先落盘暂停态再取消：切分支/退页后仍可从 sidecar 续本批。
            ghostwriteCancelAsUserPause = true
            mutateGhostwriteProgress {
                if $0.pendingSyncChapterCredit {
                    $0.phase = .failed
                    $0.pauseReason = .syncFailed
                } else {
                    $0.phase = .paused
                    $0.pauseReason = .userPaused
                }
                $0.detailMessage = Self.mergeGhostwriteDetail(
                    $0.detailMessage,
                    "离开页面时已保存本批进度，回来可继续。"
                )
            }
            task.cancel()
            await task.value
        }
        // 只清内存；sidecar 按 project+branch 保留，bind 时 restore。
        if ghostwriteProgressStorage?.binding == expectedBinding {
            ghostwriteProgressStorage = nil
        }
    }

    static func mergeGhostwriteDetail(_ existing: String?, _ note: String) -> String {
        let base = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if base.isEmpty { return note }
        if base.contains(note) { return base }
        return base + "\n" + note
    }

    private func runGhostwriteBatch(binding expectedBinding: NovelSessionBinding) async {
        do {
            while true {
                try Task.checkCancellation()
                _ = await refreshDurable(binding: binding, token: bindingToken)
                guard ghostwriteProgressStorage?.binding == expectedBinding else { return }

                // 已收录待同步：先完成记账，禁止少计章后再开写下一章。
                if ghostwriteProgressStorage?.pendingSyncChapterCredit == true {
                    let credited = try await settlePendingGhostwriteSyncCredit(
                        expectedBinding: expectedBinding
                    )
                    if !credited { return }
                    if ghostwriteProgressStorage?.isBatchComplete == true {
                        finishGhostwriteBatch(
                            binding: expectedBinding,
                            candidateID: ghostwriteProgressStorage?.candidateID
                        )
                        return
                    }
                    continue
                }

                let needsStateSync = workspace.branchSnapshot?.branch.syncStatus == .needsSync
                    || !branchPendingOperations.isEmpty
                if needsStateSync {
                    mutateGhostwriteProgress(binding: expectedBinding) {
                        $0.phase = .syncing
                        $0.detailMessage = "正在更新剧情记录…"
                    }
                    let synced = await awaitGhostwriteStateSync(expectedBinding: expectedBinding)
                    try Task.checkCancellation()
                    guard synced else {
                        pauseGhostwritePipeline(
                            binding: expectedBinding,
                            reason: .syncFailed,
                            detail: "剧情记录没能更新，暂时无法继续代笔。",
                            candidateID: ghostwriteProgressStorage?.candidateID
                        )
                        return
                    }
                }

                let target = ghostwriteProgressStorage?.targetChapterCount
                    ?? NovelGhostwriteBatch.minChapterCount
                let completed = ghostwriteProgressStorage?.completedChapterCount ?? 0
                if completed >= target {
                    finishGhostwriteBatch(
                        binding: expectedBinding,
                        candidateID: ghostwriteProgressStorage?.candidateID
                    )
                    return
                }

                mutateGhostwriteProgress(binding: expectedBinding) {
                    $0.currentChapterIndex = completed + 1
                }

                // 每章入口只取一次最新确认合同；章内修订始终绑定同一 ID 与 digest。
                let plan: NovelChapterPlanRecord
                if let existing = workspace.projectSnapshot?.confirmedChapterPlan(
                    for: expectedBinding.branchID
                ) {
                    plan = existing
                } else {
                    guard let proposed = try await proposeNextGhostwritePlan(
                        expectedBinding: expectedBinding
                    ) else { return }
                    plan = proposed
                }

                let chapterOK = try await runOneGhostwriteChapter(
                    initialPlan: plan,
                    expectedBinding: expectedBinding,
                    prepareNextPlan: completed + 1 < target
                )
                if !chapterOK { return }

                // runOne 在原子收录后已标 pending；成功同步后在此记账。
                let candidateID = ghostwriteProgressStorage?.candidateID
                mutateGhostwriteProgress(binding: expectedBinding) {
                    _ = $0.applyPendingSyncChapterCredit()
                }

                if (ghostwriteProgressStorage?.completedChapterCount ?? 0) >= target {
                    finishGhostwriteBatch(
                        binding: expectedBinding,
                        candidateID: candidateID
                    )
                    return
                }
                // 下一章：优先用联合审核已原子轮换的合同；缺失时才单独拟定。
            }
        } catch is CancellationError {
            await stopOwnedGhostwriteRun(
                binding: expectedBinding,
                reason: ghostwriteRunInterruptionReason()
            )
            let reason = ghostwriteCancellationPauseReason()
            pauseGhostwritePipeline(
                binding: expectedBinding,
                reason: reason,
                detail: ghostwriteAbandonBatch
                    ? ghostwriteProgressStorage?.detailMessage
                    : nil,
                candidateID: ghostwriteProgressStorage?.candidateID
            )
            ghostwriteCancelAsUserPause = false
            ghostwriteAbandonBatch = false
        } catch let failure as NovelStructuredModelExecutionFailure where failure.failure.code == "cancelled" {
            await stopOwnedGhostwriteRun(
                binding: expectedBinding,
                reason: ghostwriteRunInterruptionReason()
            )
            let reason = ghostwriteCancellationPauseReason()
            pauseGhostwritePipeline(
                binding: expectedBinding,
                reason: reason,
                detail: ghostwriteAbandonBatch
                    ? ghostwriteProgressStorage?.detailMessage
                    : nil,
                candidateID: ghostwriteProgressStorage?.candidateID
            )
            ghostwriteCancelAsUserPause = false
            ghostwriteAbandonBatch = false
        } catch {
            ghostwriteCancelAsUserPause = false
            ghostwriteAbandonBatch = false
            pauseGhostwritePipeline(
                binding: expectedBinding,
                reason: .failedReason(from: error),
                detail: describe(error),
                candidateID: ghostwriteProgressStorage?.candidateID
            )
        }
    }

    /// 协作取消：默认视为用户暂停（可续跑），绝不因 heal 清 pauseReason 而落到 `.cancelled`。
    private func ghostwriteCancellationPauseReason() -> NovelGhostwritePauseReason {
        if ghostwriteProgressStorage?.pauseReason == .batchCompleted {
            return .batchCompleted
        }
        if ghostwriteAbandonBatch {
            return .cancelled
        }
        if ghostwriteProgressStorage?.pendingSyncChapterCredit == true {
            return .syncFailed
        }
        if ghostwriteCancelAsUserPause {
            return .userPaused
        }
        switch ghostwriteProgressStorage?.pauseReason {
        case .userPaused, .syncFailed, .infrastructureFailed, .backgroundInterrupted:
            return ghostwriteProgressStorage?.pauseReason ?? .userPaused
        case .healBudgetExhausted, .acceptanceFailed, .obviousRepetition,
             .blockingContinuity, .continuityAuditIncomplete:
            // 质量停机中途再被取消：保留可续跑的质量终态语义。
            return ghostwriteProgressStorage?.pauseReason ?? .userPaused
        default:
            if ghostwriteBackgroundExpirationOwnerID != nil {
                return .backgroundInterrupted
            }
            // 批内协作取消一律可续，不把本批作废。
            return .userPaused
        }
    }

    private func ghostwriteRunInterruptionReason() -> NovelRunInterruptionReason {
        if ghostwriteBackgroundExpirationOwnerID != nil {
            return .expiration
        }
        switch ghostwriteProgressStorage?.pauseReason {
        case .infrastructureFailed, .backgroundInterrupted:
            return .expiration
        default:
            return .user
        }
    }

}
