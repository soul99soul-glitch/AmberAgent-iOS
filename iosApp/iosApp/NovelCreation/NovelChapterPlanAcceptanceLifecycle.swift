import Foundation

extension DefaultNovelCreation {
    /// Structured contract check for a whole-chapter prose candidate.
    /// Uses the project's review model policy (falls back to App default when unset).
    func acceptChapterPlan(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID
    ) async throws -> NovelChapterPlanAcceptanceV1 {
        try await recoverGenerationStateIfNeeded(requiredProjectID: projectID)
        let loaded = try await loadCommittedProject(id: projectID)
        guard loaded.access == .readWrite else {
            throw NovelError.degradedReadOnly(projectID: projectID)
        }
        guard let branch = loaded.document.branches.first(where: {
            $0.id == branchID && $0.lifecycle == .active
        }) else {
            throw NovelError.branchNotFound(branchID)
        }
        guard branch.activeRunID == nil else {
            throw NovelError.projectBusy(projectID)
        }
        guard let plan = loaded.document.confirmedChapterPlan(for: branch.id) else {
            throw NovelError.invalidInput("代笔验收需要已确认的本章计划。")
        }
        guard let candidate = loaded.document.candidates.first(where: {
            $0.id == candidateID &&
                $0.branchID == branch.id &&
                $0.kind == .prose
        }) else {
            throw NovelError.invalidInput("找不到要验收的正文候选。")
        }
        guard candidate.status == .available else {
            throw NovelError.invalidInput("只有完整可用的正文候选可以验收。")
        }
        guard let boundDigest = candidate.chapterPlanDigest,
              boundDigest == plan.contentDigest else {
            throw NovelError.invalidInput("这篇稿没有绑定当前确认的计划，无法自动验收。")
        }
        let trimmed = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !NovelParagraphParser.paragraphs(in: candidate.content).isEmpty else {
            throw NovelError.invalidInput("候选正文不完整，无法验收。")
        }
        let recentHighlights = loaded.document.stateSnapshots
            .first(where: { $0.id == branch.currentStateSnapshotID })?
            .injectionHighlightsText() ?? ""

        let executor = NovelStructuredModelExecutor(modelRunner: modelRunner)
        let preparation = try await executor.prepare(
            modelPolicy: modelPolicy(for: .review, in: loaded.document),
            taskKind: .chapterPlanAcceptance,
            requestedInputBudgetTokens: NovelStructuredModelExecutor
                .maximumInternalInputBudgetTokens
        )
        let request = NovelStructuredModelExecutionRequest(
            runID: NovelRunID(),
            modelPolicy: preparation.modelPolicy,
            task: .chapterPlanAcceptance(
                plan: plan.injectionText(),
                candidate: candidate.content,
                recentHighlights: recentHighlights
            )
        )
        let evidence = try await executor.executePrepared(
            try executor.prepareInvocation(request, preparation: preparation),
            noOutputTimeout: factRequestTimeout
        )
        guard case .chapterPlanAcceptance(let result) = evidence.output else {
            throw NovelStructuredModelExecutionFailure(
                code: "invalid_structured_output",
                message: "本章计划验收返回了错误的结构。",
                isRetryable: true
            )
        }
        return result
    }
}

extension DefaultNovelCreation {
    func adjudicateAndCollectGhostwriteChapter(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID,
        prepareNextPlan: Bool
    ) async throws -> NovelGhostwriteChapterAdjudicationResult {
        try await recoverGenerationStateIfNeeded(requiredProjectID: projectID)
        let loaded = try await loadCommittedProject(id: projectID)
        guard loaded.access == .readWrite else {
            throw NovelError.degradedReadOnly(projectID: projectID)
        }
        guard let branch = loaded.document.branches.first(where: {
            $0.id == branchID && $0.lifecycle == .active
        }) else {
            throw NovelError.branchNotFound(branchID)
        }
        guard branch.activeRunID == nil,
              branch.syncStatus == .synchronized else {
            throw NovelError.projectBusy(projectID)
        }
        guard let plan = loaded.document.confirmedChapterPlan(for: branch.id) else {
            throw NovelError.invalidInput("联合审查需要已确认的本章计划。")
        }
        guard let candidate = loaded.document.candidates.first(where: {
            $0.id == candidateID &&
                $0.branchID == branch.id &&
                $0.kind == .prose
        }) else {
            throw NovelError.invalidInput("找不到要联合审查的正文候选。")
        }
        guard candidate.status == .available,
              candidate.collectedCheckpointID == nil else {
            throw NovelError.invalidInput("只有完整可用且尚未收录的正文候选可以联合审查。")
        }
        guard candidate.ghostwritePlanID == plan.id,
              candidate.chapterPlanDigest == plan.contentDigest else {
            throw NovelError.invalidInput("这篇稿没有绑定当前确认的计划，无法联合审查。")
        }
        let paragraphs = NovelParagraphParser.paragraphs(in: candidate.content)
        guard !paragraphs.isEmpty else {
            throw NovelError.invalidInput("候选正文为空，无法联合审查。")
        }

        let chapterID = NovelChapterID()
        let title = plan.outlinePlacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = NovelCollectCandidateCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: loaded.document.project.revision,
                expectedConfigRevision: loaded.document.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: projectID,
            branchID: branchID,
            pendingID: NovelPendingOperationID(),
            candidateID: candidateID,
            selection: NovelParagraphSelection(
                paragraphIDs: paragraphs.map(\.id),
                editedText: nil
            ),
            target: .createNextChapter(
                chapterID: chapterID,
                title: title.isEmpty ? "未命名章节" : title
            ),
            proposedChapterVersionID: NovelChapterVersionID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            factCompatibilityID: UUID(),
            source: .systemAutoCollect
        )
        let payloadSHA256 = try command.canonicalPayloadSHA256()
        let pending = try NovelFactTransactionReducer.prepareCollection(
            command,
            payloadSHA256: payloadSHA256,
            in: loaded.document,
            now: now()
        ).pending

        let discardedChapterIDs = Set(
            loaded.document.chapters.filter { $0.discardedAt != nil }.map(\.id)
        )
        let recent = NovelContinuityAuditScope.priorManuscriptChapters(
            try NovelContinuityAuditScope.manuscriptChapters(
                branch: branch,
                discardedChapterIDs: discardedChapterIDs,
                document: loaded.document
            ),
            maxPrior: NovelGhostwriteContinuityGate.nearScopePriorChapterCount
        )

        let executor = NovelStructuredModelExecutor(modelRunner: modelRunner)
        let preparation = try await executor.prepare(
            modelPolicy: modelPolicy(for: .review, in: loaded.document),
            taskKind: .chapterAdjudication,
            requestedInputBudgetTokens: NovelStructuredModelExecutor
                .maximumInternalInputBudgetTokens
        )
        let totalInputBudget = preparation.effectiveInputBudgetTokens
        // 当前章的合同、状态和候选正文是联合审查的必选输入。近章正文与下一章
        // 计划仍保留，但只能使用必选输入装入后剩余的额度，不能反过来挡住收录。
        let externalContextReserve = (!recent.isEmpty || prepareNextPlan)
            ? min(12_000, max(0, totalInputBudget - 12_000))
            : 0
        let injectionPlan: NovelInjectionPlan
        do {
            injectionPlan = try NovelInjectionPlanner.plan(
                document: loaded.document,
                request: NovelInjectionPlanningRequest(
                    branchID: branchID,
                    promptKind: .chapterAdjudicationV1,
                    userText: candidate.content,
                    sessionCursorLimit: .empty,
                    includeUnsynchronizedStateWarning: false,
                    optionalPackingLimitTokens: totalInputBudget - externalContextReserve,
                    budget: NovelInjectionBudget(
                        maxEstimatedInputTokens: totalInputBudget,
                        chapterTailCharacterLimit: NovelInjectionBudget.standard
                            .chapterTailCharacterLimit,
                        maximumRecentSessionMessages: 0
                    )
                )
            )
        } catch {
            throw mapInjectionError(error)
        }
        let remainingContextBudget = max(
            0,
            totalInputBudget - injectionPlan.estimatedInputTokens
        )
        let priorBudget = min(12_000, remainingContextBudget)
        let boundedPrior = NovelGhostwriteAdjudicationContext.boundedPriorChapters(
            recent,
            maximumTokens: priorBudget
        )
        let priorManuscript = boundedPrior.map(\.manuscriptBlock)
            .joined(separator: "\n\n")
        let priorTokens = NovelContinuityAuditPlanner.estimatedTokens(priorManuscript)
        let nextPlanBudget = max(0, remainingContextBudget - priorTokens)
        let nextPlanContext = prepareNextPlan
            ? NovelGhostwriteAdjudicationContext.nextPlanContext(
                document: loaded.document,
                branch: branch,
                currentPlan: plan,
                maximumTokens: nextPlanBudget
            )
            : ""
        let invocation = try executor.prepareInvocation(
            NovelStructuredModelExecutionRequest(
                runID: NovelRunID(),
                modelPolicy: preparation.modelPolicy,
                task: .chapterAdjudication(
                    context: injectionPlan.contextText,
                    priorManuscript: priorManuscript,
                    candidate: candidate.content,
                    prepareNextPlan: prepareNextPlan,
                    nextPlanContext: nextPlanContext
                )
            ),
            preparation: preparation
        )
        let evidence = try await executor.executePrepared(
            invocation,
            noOutputTimeout: factRequestTimeout
        )
        guard case .chapterAdjudication(let adjudication) = evidence.output else {
            throw NovelStructuredModelExecutionFailure(
                code: "invalid_structured_output",
                message: "联合审查返回了错误的结构。",
                isRetryable: true
            )
        }

        let candidateChapter = NovelContinuityAuditChapter(
            chapterID: chapterID,
            ordinal: branch.workingChapterSelections.count + 1,
            title: title.isEmpty ? "未命名章节" : title,
            content: candidate.content
        )
        let mapped = NovelContinuityAuditMapper.map(
            adjudication.continuity,
            chunkIndex: 0,
            chapters: boundedPrior + [candidateChapter]
        )
        let candidateBlocking = mapped.issues.filter { issue in
            issue.severity == .blocking && issue.references.contains {
                $0.chapterID == candidateChapter.chapterID
            }
        }
        let blockingIssues = candidateBlocking
        let hasPlanViolation = !adjudication.acceptance.missingMustHappen.isEmpty ||
            !adjudication.acceptance.forbiddenViolations.isEmpty
        guard !hasPlanViolation, blockingIssues.isEmpty else {
            return NovelGhostwriteChapterAdjudicationResult(
                adjudication: adjudication,
                blockingContinuityIssues: blockingIssues,
                droppedContinuityIssueCount: mapped.droppedCount,
                collectionOutcome: nil
            )
        }

        let artifacts = try makeGhostwriteAdjudicationReceipts(
            projectID: projectID,
            branchID: branchID,
            pending: pending,
            plan: injectionPlan,
            invocation: invocation,
            requestedInputBudgetTokens: preparation.requestedInputBudgetTokens,
            createdAt: now()
        )
        let beforeCommit = try await reloadGhostwriteAdjudicationDocument(
            projectID: projectID
        )
        let committed = try NovelFactTransactionReducer.commitGhostwriteAdjudication(
            command,
            payloadSHA256: payloadSHA256,
            planID: plan.id,
            planDigest: plan.contentDigest,
            nextPlanID: prepareNextPlan && adjudication.nextPlan != nil
                ? NovelChapterPlanID()
                : nil,
            nextPlan: prepareNextPlan ? adjudication.nextPlan : nil,
            delta: adjudication.stateDelta,
            artifacts: artifacts,
            in: beforeCommit.document,
            now: now()
        )
        _ = try await commitGhostwriteAdjudicationDocument(
            committed.document,
            replacing: beforeCommit
        )
        publishMutation(
            projectID: projectID,
            operationID: command.context.operationID
        )
        return NovelGhostwriteChapterAdjudicationResult(
            adjudication: adjudication,
            blockingContinuityIssues: [],
            droppedContinuityIssueCount: mapped.droppedCount,
            collectionOutcome: committed.outcome
        )
    }
}

private enum NovelGhostwriteAdjudicationContext {
    static func nextPlanContext(
        document: NovelProjectDocumentV1,
        branch: NovelBranchRecord,
        currentPlan: NovelChapterPlanRecord,
        maximumTokens: Int
    ) -> String {
        guard maximumTokens > 0 else { return "" }
        let currentOrdinal = branch.workingChapterSelections.count + 1
        let instruction = """
        PROJECTED STORY POSITION
        The candidate supplied separately is chapter \(currentOrdinal) if and only if it passes review.
        Propose chapter \(currentOrdinal + 1) from the candidate's ending and newly established facts.
        Do not repeat the current plan's must-happen beats.
        """
        let context = DefaultNovelCreation.chapterPlanProposalContext(
            document: document,
            branch: branch,
            nextChapterOrdinal: currentOrdinal + 1,
            previousPlanSummary: currentPlan.ghostwriteBatchSummary()
        )
        return boundedPrefix(
            instruction + "\n\n" + context,
            maximumTokens: maximumTokens
        )
    }

    static func boundedPriorChapters(
        _ chapters: [NovelContinuityAuditChapter],
        maximumTokens: Int
    ) -> [NovelContinuityAuditChapter] {
        guard maximumTokens > 0 else { return [] }
        var remaining = maximumTokens
        var reversed: [NovelContinuityAuditChapter] = []
        for chapter in chapters.reversed() {
            let tokens = NovelContinuityAuditPlanner.estimatedTokens(chapter.manuscriptBlock)
            if tokens <= remaining {
                reversed.append(chapter)
                remaining -= tokens
                continue
            }
            guard reversed.isEmpty else { break }
            let headerTokens = NovelContinuityAuditPlanner.estimatedTokens(
                "# Chapter \(chapter.ordinal): \(chapter.title)\n\n"
            )
            let contentLimit = max(0, remaining - headerTokens)
            guard contentLimit > 0 else { break }
            let content = boundedSuffix(chapter.content, maximumTokens: contentLimit)
            guard !content.isEmpty else { break }
            reversed.append(NovelContinuityAuditChapter(
                chapterID: chapter.chapterID,
                ordinal: chapter.ordinal,
                title: chapter.title,
                content: content
            ))
            break
        }
        return Array(reversed.reversed())
    }

    private static func boundedPrefix(_ text: String, maximumTokens: Int) -> String {
        bounded(text, maximumTokens: maximumTokens) { text, length in
            String(text.prefix(length))
        }
    }

    private static func boundedSuffix(_ text: String, maximumTokens: Int) -> String {
        bounded(text, maximumTokens: maximumTokens) { text, length in
            String(text.suffix(length))
        }
    }

    private static func bounded(
        _ text: String,
        maximumTokens: Int,
        slice: (String, Int) -> String
    ) -> String {
        guard maximumTokens > 0 else { return "" }
        guard NovelContinuityAuditPlanner.estimatedTokens(text) > maximumTokens else {
            return text
        }
        var lower = 0
        var upper = text.count
        while lower < upper {
            let midpoint = (lower + upper + 1) / 2
            if NovelContinuityAuditPlanner.estimatedTokens(slice(text, midpoint)) <= maximumTokens {
                lower = midpoint
            } else {
                upper = midpoint - 1
            }
        }
        return slice(text, lower)
    }
}
