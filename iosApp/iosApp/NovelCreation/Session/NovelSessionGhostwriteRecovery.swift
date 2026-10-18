import Foundation
import UIKit

extension NovelSessionViewModel {
    func pauseGhostwritePipeline(
        binding expectedBinding: NovelSessionBinding,
        reason: NovelGhostwritePauseReason,
        detail: String?,
        candidateID: NovelCandidateID?
    ) {
        let phase: NovelGhostwritePhase = switch reason {
        case .chapterCompleted, .batchCompleted, .planProposedForNewBatch: .waitingUser
        case .healBudgetExhausted: .waitingUser
        case .acceptanceFailed, .obviousRepetition, .blockingContinuity,
             .continuityAuditIncomplete, .userPaused, .cancelled,
             .planProposalFailed, .backgroundInterrupted:
            .paused
        case .collectFailed, .collectBaseStale, .syncFailed, .incompleteCandidate,
             .planMismatch, .infrastructureFailed:
            .failed
        }
        mutateGhostwriteProgress(binding: expectedBinding) {
            $0.phase = phase
            $0.pauseReason = reason
            $0.detailMessage = detail ?? reason.displayMessage
            $0.candidateID = candidateID ?? $0.candidateID
            if reason.requiresRewriteOnContinue, let candidateID {
                $0.supersededCandidateIDs.insert(candidateID)
            }
        }
        // 代笔中断由 ghostwrite status bar 独占呈现与恢复动作；不要再把同一
        // 文案投到通用 error banner，后者的「重试」并不拥有整条 pipeline。
        operationErrorMessage = nil
    }

    func ghostwriteRecentHighlightCount(
        for expectedBinding: NovelSessionBinding
    ) -> Int {
        guard let project = workspace.projectSnapshot,
              let branch = project.branches.first(where: {
                  $0.id == expectedBinding.branchID
              }),
              let state = project.stateSnapshots.first(where: {
                  $0.id == branch.currentStateSnapshotID
              }) else {
            return 0
        }
        return state.recentWrittenHighlights.count
    }

    func mutateGhostwriteProgress(
        binding expectedBinding: NovelSessionBinding? = nil,
        persist: Bool = true,
        _ body: (inout NovelGhostwriteProgress) -> Void
    ) {
        guard var progress = ghostwriteProgressStorage else { return }
        if let expectedBinding, progress.binding != expectedBinding { return }
        body(&progress)
        ghostwriteProgressStorage = progress
        if persist {
            persistGhostwriteProgress(progress)
        }
        advanceGhostwriteBackgroundProgress(by: 1, subtitle: progress.statusLabel)
    }

    func beginGhostwriteBackgroundLease(
        binding: NovelSessionBinding,
        ownerID: UUID
    ) {
        let leaseID = novelGhostwriteBackgroundLeaseID(
            projectID: binding.projectID,
            branchID: binding.branchID
        )
        BackgroundGenerationKeepAlive.shared.begin(
            leaseID,
            title: IOSAppLocalization.string("Amber 代笔中", defaultValue: "Amber 代笔中"),
            subtitle: ghostwriteProgressStorage?.statusLabel
                ?? IOSAppLocalization.string("准备代笔", defaultValue: "准备代笔"),
            onExpire: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.expireGhostwriteBackgroundLease(
                        binding: binding,
                        ownerID: ownerID
                    )
                }
            },
            onSystemTaskExpiration: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.expireGhostwriteBackgroundLease(
                        binding: binding,
                        ownerID: ownerID
                    )
                }
            }
        )
        BackgroundGenerationKeepAlive.shared.updateProgress(
            leaseID,
            completed: 0,
            total: -1,
            subtitle: ghostwriteProgressStorage?.statusLabel
                ?? IOSAppLocalization.string("准备代笔", defaultValue: "准备代笔")
        )
        advanceGhostwriteBackgroundProgress(by: 1)
    }

    func advanceGhostwriteBackgroundProgress(
        by units: Int64,
        subtitle: String? = nil
    ) {
        guard let progress = ghostwriteProgressStorage,
              progress.binding == ghostwriteTaskBinding else { return }
        BackgroundGenerationKeepAlive.shared.advanceProgress(
            novelGhostwriteBackgroundLeaseID(
                projectID: progress.binding.projectID,
                branchID: progress.binding.branchID
            ),
            by: units,
            subtitle: subtitle ?? progress.statusLabel
        )
    }

    private func expireGhostwriteBackgroundLease(
        binding expectedBinding: NovelSessionBinding,
        ownerID: UUID
    ) async {
        guard ghostwriteTaskBinding == expectedBinding,
              ghostwriteBackgroundLeaseOwnerID == ownerID,
              let task = ghostwriteTask,
              let progress = ghostwriteProgressStorage,
              progress.binding == expectedBinding else { return }
        switch progress.phase {
        case .writing, .accepting, .collecting, .syncing, .planning, .revising:
            break
        case .paused, .waitingUser, .failed:
            return
        }
        ghostwriteBackgroundExpirationOwnerID = ownerID
        mutateGhostwriteProgress(binding: expectedBinding, persist: false) {
            $0.phase = .paused
            $0.pauseReason = NovelGhostwritePauseReason.afterBackgroundExpiration(
                current: $0.pauseReason
            )
            if $0.pauseReason == .backgroundInterrupted {
                $0.detailMessage = NovelGhostwritePauseReason.backgroundInterrupted.displayMessage
            } else {
                let quality = $0.pauseReason?.displayMessage ?? "代笔已暂停。"
                $0.detailMessage = quality + "\n系统已暂停后台执行，当前批次进度已保存。"
            }
        }
        if let paused = ghostwriteProgressStorage,
           paused.binding == expectedBinding,
           await !workspace.flushGhostwriteBatchProgress(paused) {
            IOSBackgroundLifecycleLog.record(
                "ghostwriteProgressCheckpointFailed",
                detail: "project=\(expectedBinding.projectID) branch=\(expectedBinding.branchID)"
            )
        }
        workspace.cancelAutomaticStateSync(
            projectID: expectedBinding.projectID,
            branchID: expectedBinding.branchID,
            suppressReschedule: false
        )
        task.cancel()
        await task.value
        if ghostwriteBackgroundExpirationOwnerID == ownerID {
            ghostwriteBackgroundExpirationOwnerID = nil
        }
        if let latest = ghostwriteProgressStorage,
           latest.binding == expectedBinding,
           await !workspace.flushGhostwriteBatchProgress(latest) {
            // The final flush yields. Do not let an old expiration callback
            // annotate a new batch that the user started in that window.
            if ghostwriteTask == nil,
               ghostwriteBackgroundLeaseOwnerID == nil,
               ghostwriteProgressStorage?.binding == expectedBinding,
               ghostwriteProgressStorage?.pauseReason == .backgroundInterrupted {
                mutateGhostwriteProgress(binding: expectedBinding, persist: false) {
                    $0.detailMessage = ($0.detailMessage ?? "系统已暂停后台代笔。")
                        + "\n恢复记录未能确认写入；请保持 Amber 在前台并手动继续。"
                }
            }
            IOSBackgroundLifecycleLog.record(
                "ghostwriteProgressFinalFlushFailed",
                detail: "project=\(expectedBinding.projectID) branch=\(expectedBinding.branchID)"
            )
        }
        if UIApplication.shared.applicationState == .active {
            _ = await resumeGhostwriteAfterBackgroundInterruptionIfNeeded()
        }
    }

    /// 只自动恢复系统后台中断；质量、供应商和同步失败仍由各自门禁处理。
    @discardableResult
    func resumeGhostwriteAfterBackgroundInterruptionIfNeeded() async -> Bool {
        guard UIApplication.shared.applicationState == .active,
              ghostwriteTask == nil,
              let binding,
              let progress = ghostwriteProgressStorage,
              progress.binding == binding,
              progress.pauseReason == .backgroundInterrupted,
              progress.shouldContinueSameBatch else {
            return false
        }
        if startGhostwriteChapter(preservingAttemptBudget: true) {
            return true
        }

        // automatic-sync/run cleanup can finish one actor turn after the expired
        // task. Give that real transient gate one bounded settle, then try once.
        let expectedBinding = binding
        let expectedToken = bindingToken
        try? await Task.sleep(for: .milliseconds(500))
        _ = await refreshDurable(binding: expectedBinding, token: expectedToken)
        guard UIApplication.shared.applicationState == .active,
              ghostwriteTask == nil,
              self.binding == expectedBinding,
              ghostwriteProgressStorage?.pauseReason == .backgroundInterrupted else {
            return false
        }
        return startGhostwriteChapter(preservingAttemptBudget: true)
    }

    /// 验收/连续性审计的基建重试入口：重试时在进度面板给出阶段性提示。
    func withGhostwriteInfraRetry<T: Sendable>(
        binding expectedBinding: NovelSessionBinding,
        stage: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await NovelGhostwriteInfraRetry.run(onRetry: { [weak self] attempt in
            await self?.mutateGhostwriteProgress(binding: expectedBinding) {
                $0.detailMessage =
                    "\(stage)调用失败，正在重试 \(attempt + 1)/\(NovelGhostwriteInfraRetry.maxAttempts)…"
            }
        }, operation: operation)
    }

    /// 冷启动 / 重绑会话：从 sidecar 恢复本批代笔进度（不抢正在跑的 task）。
    func restoreGhostwriteProgressIfNeeded(
        for expectedBinding: NovelSessionBinding
    ) async {
        guard ghostwriteTask == nil else { return }
        if let current = ghostwriteProgressStorage, current.binding == expectedBinding {
            return
        }
        guard var restored = await workspace.loadGhostwriteBatchProgress(
            projectID: expectedBinding.projectID,
            branchID: expectedBinding.branchID
        ) else {
            if ghostwriteProgressStorage?.binding != expectedBinding {
                ghostwriteProgressStorage = nil
            }
            return
        }
        guard restored.binding == expectedBinding else { return }
        if reconcileCommittedGhostwriteChapter(
            in: &restored,
            for: expectedBinding
        ) {
            persistGhostwriteProgress(restored)
        }
        // 完批记录不应继续占面板；清掉磁盘脏文件。
        if restored.isBatchComplete, restored.pendingSyncChapterCredit != true {
            clearPersistedGhostwriteProgress(for: expectedBinding)
            if ghostwriteProgressStorage?.binding == expectedBinding {
                ghostwriteProgressStorage = nil
            }
            return
        }
        ghostwriteProgressStorage = restored
    }

    /// If the app died after the atomic project commit but before the sidecar write,
    /// recover that already-collected chapter instead of generating it again.
    private func reconcileCommittedGhostwriteChapter(
        in progress: inout NovelGhostwriteProgress,
        for expectedBinding: NovelSessionBinding
    ) -> Bool {
        guard !progress.pendingSyncChapterCredit,
              let project = workspace.projectSnapshot,
              project.project.id == expectedBinding.projectID,
              let branch = workspace.branchSnapshot?.branch,
              branch.id == expectedBinding.branchID else {
            return false
        }
        let selectedVersionIDs = Set(branch.workingChapterSelections.map(\.versionID))
        let selectedCandidateIDs = Set(project.chapterVersions.compactMap { version in
            selectedVersionIDs.contains(version.id) ? version.sourceCandidateID : nil
        })
        let recovered = project.candidates
            .filter { candidate in
                candidate.branchID == expectedBinding.branchID &&
                    candidate.status == .collected &&
                    candidate.ghostwritePlanID != nil &&
                    candidate.createdAt >= progress.startedAt &&
                    selectedCandidateIDs.contains(candidate.id) &&
                    !progress.autoCollectedCandidateIDs.contains(candidate.id)
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.description < rhs.id.description
            }
        let remaining = max(0, progress.targetChapterCount - progress.completedChapterCount)
        let accepted = Array(recovered.prefix(remaining))
        guard let newest = accepted.last else { return false }

        progress.autoCollectedCandidateIDs.formUnion(accepted.map(\.id))
        progress.completedChapterCount += max(0, accepted.count - 1)
        progress.currentChapterIndex = min(
            progress.completedChapterCount + 1,
            progress.targetChapterCount
        )
        progress.candidateID = newest.id
        progress.chapterPlanDigest = nil
        progress.pendingSyncChapterCredit = true
        progress.phase = .syncing
        progress.pauseReason = .syncFailed
        progress.detailMessage = Self.mergeGhostwriteDetail(
            progress.detailMessage,
            "已找回原子收录成功的章节，同步确认后继续，不会重写。"
        )
        return true
    }

    func persistGhostwriteProgress(_ progress: NovelGhostwriteProgress) {
        workspace.persistGhostwriteBatchProgress(progress)
    }

    private func clearPersistedGhostwriteProgress(for binding: NovelSessionBinding) {
        workspace.clearGhostwriteBatchProgress(
            projectID: binding.projectID,
            branchID: binding.branchID
        )
    }
}
