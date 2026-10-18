import Foundation

extension NovelSessionViewModel {
    /// 单章闭环：写→联合审查并原子收录→同步确认。
    /// 明确计划缺口在预算内自动改写；用尽或严重连续性则暂停。成功 true；已暂停 false。
    func runOneGhostwriteChapter(
        initialPlan: NovelChapterPlanRecord,
        expectedBinding: NovelSessionBinding,
        prepareNextPlan: Bool
    ) async throws -> Bool {
        let plan = initialPlan
        // 兼容旧版本留下的「候选已收录但合同未清」恢复态。
        if let alreadyCollected = candidates(kind: .prose).first(where: {
            NovelGhostwriteCandidateOwnership.belongs($0, to: plan) && $0.status == .collected
        }) {
            mutateGhostwriteProgress(binding: expectedBinding) {
                $0.autoCollectedCandidateIDs.insert(alreadyCollected.id)
                $0.candidateID = alreadyCollected.id
            }
            if workspace.projectSnapshot?.chapterPlan(for: expectedBinding.branchID) != nil {
                let planCleared = await workspace.clearChapterPlan(
                    branchID: expectedBinding.branchID
                )
                if !planCleared {
                    pauseGhostwritePipeline(
                        binding: expectedBinding,
                        reason: .collectFailed,
                        detail: "本章已收录，但未能清除计划。请手动清除后再继续。",
                        candidateID: alreadyCollected.id
                    )
                    return false
                }
            }
            mutateGhostwriteProgress(binding: expectedBinding) {
                $0.chapterPlanDigest = nil
                $0.phase = .syncing
                $0.pendingSyncChapterCredit = true
                $0.lastCompletedPlanSummary = plan.ghostwriteBatchSummary()
            }
            let synced = await awaitGhostwriteStateSync(expectedBinding: expectedBinding)
            try Task.checkCancellation()
            if !synced {
                pauseGhostwritePipeline(
                    binding: expectedBinding,
                    reason: .syncFailed,
                    detail: "本章已收录；同步完成后可继续本批下一章。",
                    candidateID: alreadyCollected.id
                )
                return false
            }
            return true
        }

        while true {
            try Task.checkCancellation()
            guard let live = workspace.projectSnapshot?
                .confirmedChapterPlan(for: expectedBinding.branchID),
                live.id == plan.id,
                live.contentDigest == plan.contentDigest else {
                pauseGhostwritePipeline(
                    binding: expectedBinding,
                    reason: .planMismatch,
                    detail: "本章计划已不存在、未确认或内容已变化，无法继续代笔。",
                    candidateID: ghostwriteProgressStorage?.candidateID
                )
                return false
            }
            let candidateID = try await obtainGhostwriteCandidate(
                plan: plan,
                expectedBinding: expectedBinding
            )
            try Task.checkCancellation()

            // Candidate persistence can precede the run's terminal branch update by
            // a brief moment. Keep the existing bounded settle before adjudication.
            _ = await refreshDurable(binding: binding, token: bindingToken)
            let settleDeadline = Date().addingTimeInterval(3)
            while Date() < settleDeadline,
                  workspace.branchSnapshot?.branch.activeRunID != nil {
                try Task.checkCancellation()
                try? await Task.sleep(for: .milliseconds(150))
                _ = await refreshDurable(binding: binding, token: bindingToken)
            }

            if await workspace.worktreeManifestExists() {
                do {
                    try await requireWorktreeDraft(candidateID)
                } catch {
                    operationErrorMessage = describe(error)
                    pauseGhostwritePipeline(
                        binding: expectedBinding,
                        reason: .collectFailed,
                        detail: operationErrorMessage,
                        candidateID: candidateID
                    )
                    return false
                }
            }

            mutateGhostwriteProgress(binding: expectedBinding) {
                $0.phase = .accepting
                $0.candidateID = candidateID
                $0.chapterPlanDigest = plan.contentDigest
            }
            let result = try await withGhostwriteInfraRetry(
                binding: expectedBinding,
                stage: "审核并收录"
            ) {
                try await workspace.adjudicateAndCollectGhostwriteChapter(
                    projectID: expectedBinding.projectID,
                    branchID: expectedBinding.branchID,
                    candidateID: candidateID,
                    prepareNextPlan: prepareNextPlan
                )
            }
            if result.didCollect {
                // The project commit already consumed the plan. Persist the matching
                // chapter credit before observing cancellation so resume cannot write it twice.
                operationErrorMessage = nil
                mutateGhostwriteProgress(binding: expectedBinding) {
                    $0.autoCollectedCandidateIDs.insert(candidateID)
                    $0.candidateID = candidateID
                    $0.resetChapterHealState()
                    $0.chapterPlanDigest = nil
                    $0.phase = .syncing
                    $0.pendingSyncChapterCredit = true
                    $0.lastCompletedPlanSummary = plan.ghostwriteBatchSummary()
                }
            }
            try Task.checkCancellation()
            let acceptance = result.adjudication.acceptance
            let missing = acceptance.missingMustHappen.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let forbidden = acceptance.forbiddenViolations.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !missing.isEmpty || !forbidden.isEmpty {
                var detailParts: [String] = []
                let summary = acceptance.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !summary.isEmpty { detailParts.append(summary) }
                if !missing.isEmpty {
                    detailParts.append("缺少：" + missing.joined(separator: "；"))
                }
                if !forbidden.isEmpty {
                    detailParts.append("违反禁写：" + forbidden.joined(separator: "；"))
                }
                let detail = detailParts.joined(separator: "\n")
                let healed = await registerGhostwriteQualityFailure(
                    binding: expectedBinding,
                    reason: .acceptanceFailed,
                    detail: detail,
                    missingMustHappen: missing,
                    repetitionBeats: acceptance.obviousRepetition,
                    continuityNotes: [],
                    candidateID: candidateID,
                    planDigest: plan.contentDigest
                )
                if healed { continue }
                return false
            }
            if !result.blockingContinuityIssues.isEmpty {
                let summaries = result.blockingContinuityIssues.map(\.summary).filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                let detail = summaries.joined(separator: "；")
                let receipt = NovelGhostwriteFailureReceipt.make(
                    reason: .blockingContinuity,
                    summary: detail,
                    missingMustHappen: [],
                    repetitionBeats: [],
                    continuityNotes: summaries,
                    attemptIndex: (ghostwriteProgressStorage?.qualityAttemptIndex ?? 0) + 1,
                    sourceCandidateID: candidateID,
                    planDigest: plan.contentDigest
                )
                mutateGhostwriteProgress(binding: expectedBinding) {
                    $0.qualityAttemptIndex += 1
                    $0.lastFailureReceipt = receipt
                    $0.supersededCandidateIDs.insert(candidateID)
                }
                pauseGhostwritePipeline(
                    binding: expectedBinding,
                    reason: .blockingContinuity,
                    detail: detail,
                    candidateID: candidateID
                )
                return false
            }

            guard result.didCollect else {
                pauseGhostwritePipeline(
                    binding: expectedBinding,
                    reason: .collectFailed,
                    detail: "联合审查已结束，但本章没有完成原子收录，请重试。",
                    candidateID: candidateID
                )
                return false
            }
            _ = await refreshDurable(binding: expectedBinding, token: bindingToken)

            let synced = await awaitGhostwriteStateSync(expectedBinding: expectedBinding)
            try Task.checkCancellation()
            guard synced else {
                let syncDetail = [
                    workspace.errorMessage,
                    "本章已收录；同步完成后可继续本批下一章。",
                ]
                .compactMap { $0 }
                .joined(separator: " ")
                pauseGhostwritePipeline(
                    binding: expectedBinding,
                    reason: .syncFailed,
                    detail: syncDetail,
                    candidateID: candidateID
                )
                return false
            }
            return true
        }
    }

    /// 登记质量失败；若预算允许则准备自动改写并返回 true（调用方 `continue` 重写）。
    @discardableResult
    private func registerGhostwriteQualityFailure(
        binding expectedBinding: NovelSessionBinding,
        reason: NovelGhostwritePauseReason,
        detail: String,
        missingMustHappen: [String],
        repetitionBeats: [String],
        continuityNotes: [String],
        candidateID: NovelCandidateID,
        planDigest: String?
    ) async -> Bool {
        let priorIndex = ghostwriteProgressStorage?.qualityAttemptIndex ?? 0
        let receipt = NovelGhostwriteFailureReceipt.make(
            reason: reason,
            summary: detail,
            missingMustHappen: missingMustHappen,
            repetitionBeats: repetitionBeats,
            continuityNotes: continuityNotes,
            attemptIndex: priorIndex + 1,
            sourceCandidateID: candidateID,
            planDigest: planDigest
        )
        var healResult = (willRewrite: false, blockedByFingerprint: false)
        mutateGhostwriteProgress(binding: expectedBinding) {
            healResult = $0.registerQualityFailureForHeal(
                reason: reason,
                receipt: receipt,
                failedCandidateID: candidateID
            )
        }
        if healResult.willRewrite {
            return true
        }

        let maxAttempts = ghostwriteProgressStorage?.maxQualityAttempts
            ?? NovelGhostwriteHeal.defaultMaxQualityAttempts
        let exhaustedDetail: String
        if reason.allowsAutomaticQualityHeal {
            var lines = [detail]
            if healResult.blockedByFingerprint {
                lines.append("连续两次同一类问题，已停止空转改写。")
            } else {
                lines.append(
                    "已自动改写 \(max(0, maxAttempts - 1)) 次仍未过关。"
                )
            }
            lines.append("可按审稿意见润修，或整章重写 / 改计划。")
            exhaustedDetail = lines.joined(separator: "\n")
        } else {
            exhaustedDetail = detail
        }
        pauseGhostwritePipeline(
            binding: expectedBinding,
            reason: reason.allowsAutomaticQualityHeal ? .healBudgetExhausted : reason,
            detail: exhaustedDetail,
            candidateID: candidateID
        )
        // 预算用尽时 pauseReason 用 healBudgetExhausted，但 receipt.reason 保留原始质量原因。
        mutateGhostwriteProgress(binding: expectedBinding) {
            $0.lastFailureReceipt = receipt
        }
        return false
    }

    /// 处理「已收录、待同步记账」：同步成功后 completed+=1，不重写、不新拟合同。
    func settlePendingGhostwriteSyncCredit(
        expectedBinding: NovelSessionBinding
    ) async throws -> Bool {
        mutateGhostwriteProgress(binding: expectedBinding) {
            $0.phase = .syncing
            $0.pauseReason = nil
            $0.detailMessage = nil
        }
        let synced = await awaitGhostwriteStateSync(expectedBinding: expectedBinding)
        try Task.checkCancellation()
        guard synced else {
            pauseGhostwritePipeline(
                binding: expectedBinding,
                reason: .syncFailed,
                detail: "本章已收录；同步完成后可继续本批下一章。",
                candidateID: ghostwriteProgressStorage?.candidateID
            )
            return false
        }
        mutateGhostwriteProgress(binding: expectedBinding) {
            _ = $0.applyPendingSyncChapterCredit()
        }
        return true
    }

    func proposeNextGhostwritePlan(
        expectedBinding: NovelSessionBinding
    ) async throws -> NovelChapterPlanRecord? {
        // 新批首章（completed==0）：拟完计划后暂停让用户确认。
        // 批内后续（completed>0）：拟完直接连写，不中断节奏。
        let completedBeforeProposal = ghostwriteProgressStorage?.completedChapterCount ?? 0
        let isAutoProposalForUserConfirmation = completedBeforeProposal == 0

        mutateGhostwriteProgress(binding: expectedBinding) {
            $0.phase = .planning
            $0.pauseReason = nil
            $0.detailMessage = nil
            $0.chapterPlanDigest = nil
        }
        let synced = await awaitGhostwriteStateSync(expectedBinding: expectedBinding)
        try Task.checkCancellation()
        guard synced else {
            pauseGhostwritePipeline(
                binding: expectedBinding,
                reason: .syncFailed,
                detail: "拟定下一章计划前需要完成剧情同步。",
                candidateID: ghostwriteProgressStorage?.candidateID
            )
            return nil
        }
        let ordinal = (ghostwriteProgressStorage?.completedChapterCount ?? 0) + 1
        let previousSummary = ghostwriteProgressStorage?.lastCompletedPlanSummary
        let maxProposalAttempts = NovelGhostwriteHeal.defaultMaxInfraRetries
        var lastError: Error?
        for attempt in 1...maxProposalAttempts {
            do {
                try Task.checkCancellation()
                if attempt > 1 {
                    mutateGhostwriteProgress(binding: expectedBinding) {
                        $0.detailMessage = "拟定计划重试 \(attempt)/\(maxProposalAttempts)…"
                    }
                    try? await Task.sleep(for: .milliseconds(400 * attempt))
                }
                let plan = try await workspace.proposeAndConfirmNextChapterPlan(
                    projectID: expectedBinding.projectID,
                    branchID: expectedBinding.branchID,
                    nextChapterOrdinal: ordinal,
                    previousPlanSummary: previousSummary
                )
                _ = await refreshDurable(binding: binding, token: bindingToken)
                if isAutoProposalForUserConfirmation {
                    // 新批首章：计划已拟定并落盘，暂停等用户确认后再连写。
                    pauseGhostwritePipeline(
                        binding: expectedBinding,
                        reason: .planProposedForNewBatch,
                        detail: nil,
                        candidateID: ghostwriteProgressStorage?.candidateID
                    )
                    return nil
                }
                mutateGhostwriteProgress(binding: expectedBinding) {
                    $0.chapterPlanDigest = plan.contentDigest
                    $0.phase = .writing
                    $0.detailMessage = nil
                }
                return plan
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as NovelStructuredModelExecutionFailure
                where failure.failure.code == "cancelled" {
                throw CancellationError()
            } catch let failure as NovelStructuredModelExecutionFailure
                where failure.failure.isRetryable && attempt < maxProposalAttempts {
                lastError = failure
                continue
            } catch {
                lastError = error
                // 非 retryable 或最后一次：退出循环
                if attempt >= maxProposalAttempts { break }
                // 未知错误也允许再试一次
                continue
            }
        }
        pauseGhostwritePipeline(
            binding: expectedBinding,
            reason: .planProposalFailed,
            detail: lastError.map(describe) ?? "自动拟定下一章计划失败。",
            candidateID: ghostwriteProgressStorage?.candidateID
        )
        return nil
    }

    func finishGhostwriteBatch(
        binding expectedBinding: NovelSessionBinding,
        candidateID: NovelCandidateID?
    ) {
        let target = ghostwriteProgressStorage?.targetChapterCount
            ?? NovelGhostwriteBatch.minChapterCount
        let completed = ghostwriteProgressStorage?.completedChapterCount ?? 0
        let highlightCount = ghostwriteRecentHighlightCount(for: expectedBinding)
        let reason: NovelGhostwritePauseReason = target > 1 ? .batchCompleted : .chapterCompleted
        var detail: String
        if target > 1 {
            detail = "本批 \(completed) 章已收录并同步。"
        } else {
            detail = "本章已收录并同步。"
        }
        if highlightCount > 0 {
            detail += " 已记入 \(highlightCount) 条近期要点，方便下一章少复读。"
        }
        if target == 1 {
            detail += " 请先定好下一章计划再继续。"
        } else {
            detail += " 下一批请先确认首章计划。"
        }
        mutateGhostwriteProgress(binding: expectedBinding) {
            $0.phase = .waitingUser
            $0.pauseReason = reason
            $0.detailMessage = detail
            $0.candidateID = candidateID ?? $0.candidateID
            $0.chapterPlanDigest = nil
        }
    }

    func stopOwnedGhostwriteRun(
        binding expectedBinding: NovelSessionBinding,
        reason: NovelRunInterruptionReason
    ) async {
        let runID = ghostwriteOwnedRunID ?? (isGhostwriteStartingRun ? activeRunID : nil)
        guard let runID,
              binding == expectedBinding else { return }
        let durableRun = workspace.projectSnapshot?.activeRuns.first {
            $0.id == runID && $0.branchID == expectedBinding.branchID
        }
        if let durableRun, durableRun.status != .running {
            await clearTransientTailAfterDurableProjection(
                runID: runID,
                token: bindingToken
            )
            return
        }
        guard durableRun?.status == .running || activeRunID == runID else { return }
        _ = await interruptBoundRun(reason: reason, runID: runID)
    }

    private func canReuseGhostwriteCandidate(
        _ candidate: NovelCandidateRecord,
        plan: NovelChapterPlanRecord
    ) -> Bool {
        guard let document = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot?.branch else {
            return false
        }
        let sourceMessage = document.sessions
            .first(where: { $0.id == candidate.sessionID })?
            .messages.first(where: { $0.id == candidate.sourceMessageID })
        if candidate.baseCheckpointID != branch.headCheckpointID ||
            candidate.baseHeadRevision != branch.headRevision {
            guard let checkpoint = document.checkpoints.first(where: {
                $0.id == branch.headCheckpointID
            }), document.appliedOperations.contains(where: {
                $0.operationID == checkpoint.operationID && $0.kind == .workspacePlot
            }) else {
                return false
            }
        }
        return NovelGhostwriteCandidateOwnership.canReuseForAutomaticCollect(
            candidate,
            plan: plan,
            branchHeadCheckpointID: branch.headCheckpointID,
            branchHeadRevision: branch.headRevision,
            checkpoints: document.checkpoints,
            sourceMessage: sourceMessage,
            superseded: ghostwriteProgressStorage?.supersededCandidateIDs ?? [],
            alreadyCollected: ghostwriteProgressStorage?.autoCollectedCandidateIDs ?? []
        )
    }

    private func obtainGhostwriteCandidate(
        plan: NovelChapterPlanRecord,
        expectedBinding: NovelSessionBinding
    ) async throws -> NovelCandidateID {
        // 质量失败 / 自动改写中：必须产新稿，禁止复用已作废或当前失败候选。
        let mustRewrite: Bool = {
            // 章内自愈在途：heal 置 phase=.writing 且清 pauseReason。
            if ghostwriteProgressStorage?.pauseReason == nil,
               ghostwriteProgressStorage?.lastFailureReceipt != nil,
               (ghostwriteProgressStorage?.qualityAttemptIndex ?? 0) > 0,
               ghostwriteProgressStorage?.phase == .writing {
                return true
            }
            // 续跑：跟 progress 同一条规则（含「基建失败但回执是验收不过」）。
            // 审计未完整 requiresRewrite=false，仍会复用同一篇。
            return ghostwriteProgressStorage?.mustRewriteCandidateOnResume == true
        }()
        if !mustRewrite,
           let ownedID = ghostwriteProgressStorage?.candidateID,
           let owned = candidate(id: ownedID),
           canReuseGhostwriteCandidate(owned, plan: plan) {
            return ownedID
        }
        if !mustRewrite,
           let recovered = candidates(kind: .prose)
            .filter({ canReuseGhostwriteCandidate($0, plan: plan) })
            .max(by: { $0.createdAt < $1.createdAt }) {
            mutateGhostwriteProgress(binding: expectedBinding) {
                $0.candidateID = recovered.id
            }
            return recovered.id
        }
        let healReceipt = ghostwriteProgressStorage?.lastFailureReceipt
        let revisionBrief = ghostwriteProgressStorage?.revisionBriefOverride
        let isHealRewrite = healReceipt != nil
            || revisionBrief != nil
            || (ghostwriteProgressStorage?.qualityAttemptIndex ?? 0) > 0
            || ghostwriteProgressStorage?.phase == .revising
        // 润修与自动自愈都钉住上一稿：确定性部分由宿主固化。
        let sourceDraft: String? = {
            guard let sourceID = healReceipt?.sourceCandidateID,
                  let body = candidate(id: sourceID)?.content else { return nil }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let userText = NovelGhostwriteProgress.writeUserText(
            receipt: healReceipt,
            revisionBrief: revisionBrief,
            sourceDraft: sourceDraft
        )
        mutateGhostwriteProgress(binding: expectedBinding) {
            $0.phase = revisionBrief == nil ? .writing : .revising
            $0.chapterPlanDigest = plan.contentDigest
            $0.candidateID = nil
            $0.pauseReason = nil
            $0.revisionBriefOverride = nil // 只消费一次
            if $0.detailMessage == nil || $0.qualityAttemptIndex == 0 {
                $0.detailMessage = revisionBrief == nil ? nil : "按审稿意见润修中…"
            }
        }
        let preexisting = Set(
            candidates(kind: .prose)
                .filter { $0.status == .available }
                .map(\.id)
        )
        isGhostwriteStartingRun = true
        let started = await start(NovelSessionRunDraft(
            kind: .prose,
            mode: .writeProse,
            granularity: .wholeChapter,
            userText: userText,
            sourceChapterVersionID: nil,
            askUserResponse: nil,
            injectionOverrides: .none,
            inputBudgetTokens: NovelGhostwriteBatch.writeInputBudgetTokens,
            ghostwritePlanID: plan.id,
            suppressRecentSessionMessages: isHealRewrite
        ))
        ghostwriteOwnedRunID = activeRunID
        isGhostwriteStartingRun = false
        try Task.checkCancellation()
        guard started else {
            throw NovelError.invalidInput(operationErrorMessage ?? "代笔写整章没有开始。")
        }
        guard let candidateID = try await awaitGhostwriteCandidate(
            plan: plan,
            preexistingIDs: preexisting,
            expectedBinding: expectedBinding
        ) else {
            throw NovelError.invalidInput(operationErrorMessage ?? "代笔没有产出完整候选。")
        }
        ghostwriteOwnedRunID = nil
        mutateGhostwriteProgress(binding: expectedBinding) {
            $0.candidateID = candidateID
        }
        try await requireWorktreeDraft(candidateID)
        return candidateID
    }

    /// Ghostwrite's unpublished chapter is the `drafts/*.md` file. JSON
    /// candidate is the ledger handle; missing draft on a worktree book
    /// means the chapter was not actually written onto the new path.
    private func requireWorktreeDraft(
        _ candidateID: NovelCandidateID
    ) async throws {
        try await workspace.materializeWorktreeDrafts()
        let hasWorktree = await workspace.worktreeManifestExists()
        guard hasWorktree else { return }
        let body = await workspace.worktreeDraftBody(candidateID: candidateID)
        let expected = candidate(id: candidateID)?.content
        guard NovelWorkspaceAuthority.draftBodiesMatch(body, expected) else {
            throw NovelError.invalidInput("代笔成稿没有落到 drafts/，无法进入核对。")
        }
    }

    private func awaitGhostwriteCandidate(
        plan: NovelChapterPlanRecord,
        preexistingIDs: Set<NovelCandidateID>,
        expectedBinding: NovelSessionBinding
    ) async throws -> NovelCandidateID? {
        let startedAt = Date()
        let expectedToken = bindingToken
        while true {
            try Task.checkCancellation()
            // The terminal consumer owns its drain and durable handoff. A polling
            // refresh here could retire its tail or erase its refresh failure.
            if !terminalAwaitingRefresh || consumerTask == nil {
                _ = await refreshDurable(
                    binding: expectedBinding,
                    token: expectedToken,
                    retireTerminalTail: consumerTask == nil
                )
            }
            try Task.checkCancellation()
            guard binding == expectedBinding,
                  bindingToken == expectedToken else { throw CancellationError() }
            let settled = activeRunID == nil && !isStarting
            let startupReady = settled && !terminalAwaitingRefresh
            // After leaving the page, preserve the existing start-gate/pause path.
            if (!consumerAttachmentDesired || startupReady),
               let candidate = candidates(kind: .prose).first(where: {
                $0.status == .available &&
                    NovelGhostwriteCandidateOwnership.belongs($0, to: plan) &&
                    !preexistingIDs.contains($0.id)
            }) {
                return candidate.id
            }
            if let interrupted = candidates(kind: .prose).first(where: {
                $0.status == .interrupted &&
                    NovelGhostwriteCandidateOwnership.belongs($0, to: plan) &&
                    !preexistingIDs.contains($0.id)
            }), activeRunID == nil, !isStarting {
                mutateGhostwriteProgress {
                    $0.candidateID = interrupted.id
                }
                throw NovelError.invalidInput("本章正文不完整。")
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            let settledForFailure = settled &&
                (!terminalAwaitingRefresh || refreshErrorMessage != nil)
            if (settledForFailure && elapsed > batchPolishSettleGrace) ||
                elapsed > batchPolishCandidateTimeout {
                await stopOwnedGhostwriteRun(binding: expectedBinding, reason: .user)
                return nil
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    func awaitGhostwriteStateSync(
        expectedBinding: NovelSessionBinding
    ) async -> Bool {
        // 不用「从进入起 240s」墙钟：多 chunk rebuild 本身就可能超过 4 分钟。
        // 有进展（chunk/activity/状态变化）就刷新；仅在空闲/失败且 kick 用尽，
        // 或长时间完全无进展时才判失败。
        let idleStallTimeout: TimeInterval = 240
        let inFlightStallTimeout: TimeInterval = 900
        var lastProgressAt = Date()
        var lastProgressSignature = ""
        var infraRetries = 0
        let maxInfra = NovelGhostwriteHeal.defaultMaxInfraRetries
        var lastKickAt: Date?
        while true {
            if Task.isCancelled { return false }
            _ = await refreshDurable(binding: binding, token: bindingToken)
            guard binding == expectedBinding else { return false }
            let branch = workspace.branchSnapshot?.branch
            let pending = branchPendingOperations
            if branch?.syncStatus == .synchronized, pending.isEmpty {
                mutateGhostwriteProgress(binding: expectedBinding) {
                    $0.infraRetryCount = 0
                    $0.detailMessage = nil
                }
                return true
            }

            let syncFailedMessage = workspace.automaticStateSyncFailureMessage(
                projectID: expectedBinding.projectID,
                branchID: expectedBinding.branchID
            )
            let activity = workspace.stateSyncActivity
            let isRunning = workspace.isStateSyncOperationRunning
            let pendingStatus = pending.first?.status
            let nextChunk = pending.first?.manualSyncProgress?.nextChunkIndex
            let completedChars = activity?.completedCharacters ?? -1
            let completedChunks = activity?.completedChunks ?? -1
            let progressSignature = [
                branch?.syncStatus.rawValue ?? "?",
                "\(pending.count)",
                pendingStatus?.rawValue ?? "-",
                "\(nextChunk.map(String.init) ?? "-")",
                "\(completedChunks)",
                "\(completedChars)",
                activity.map { "\($0.phase)" } ?? "none",
                isRunning ? "run" : "idle",
                syncFailedMessage ?? ""
            ].joined(separator: "|")
            if progressSignature != lastProgressSignature {
                lastProgressSignature = progressSignature
                lastProgressAt = Date()
                // chunk 前进视为真实进展，重置 kick 预算。
                if let nextChunk, nextChunk > 0 {
                    infraRetries = 0
                }
            }

            let workInFlight = isRunning
                || activity != nil
            let resumableManualSync = pending.count == 1
                && pending[0].kind == .manualSync
                && (pending[0].status == .pending || pending[0].status == .retryable)
            let idleNeedsSync = branch?.syncStatus == .needsSync
                && !workInFlight
            let stuckRetryable = pending.count == 1
                && pending[0].kind == .manualSync
                && pending[0].status == .retryable
                && !workInFlight
            let shouldKick = idleNeedsSync
                && (pending.isEmpty || resumableManualSync)
                && infraRetries < maxInfra
                && (lastKickAt.map { Date().timeIntervalSince($0) >= 1.5 } ?? true)

            if shouldKick {
                infraRetries += 1
                lastKickAt = Date()
                mutateGhostwriteProgress(binding: expectedBinding) {
                    $0.phase = .syncing
                    $0.infraRetryCount = infraRetries
                    $0.detailMessage = "剧情同步重试 \(infraRetries)/\(maxInfra)…"
                }
                workspace.retryStateSync(
                    projectID: expectedBinding.projectID,
                    branchID: expectedBinding.branchID
                )
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            let healExhausted = !workInFlight
                && (stuckRetryable || syncFailedMessage != nil)
                && Date().timeIntervalSince(lastProgressAt) > 2
            if healExhausted {
                return false
            }

            if idleNeedsSync,
               infraRetries >= maxInfra,
               Date().timeIntervalSince(lastProgressAt) > 3 {
                return false
            }

            let stallLimit = workInFlight ? inFlightStallTimeout : idleStallTimeout
            if Date().timeIntervalSince(lastProgressAt) > stallLimit {
                return false
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

}
