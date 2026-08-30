import Foundation

extension DefaultNovelCreation {
    func repairContinuity(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        report: NovelContinuityAuditReport,
        issueIDs: Set<String>?
    ) async throws -> NovelContinuityRepairReport {
        try await recoverGenerationStateIfNeeded(requiredProjectID: projectID)
        let loaded = try await loadCommittedProject(id: projectID)
        guard loaded.access == .readWrite else {
            throw NovelError.degradedReadOnly(projectID: projectID)
        }
        guard report.projectID == projectID, report.branchID == branchID else {
            throw NovelError.invalidInput("这份检查结果不属于当前分支，请先重新检查。")
        }
        guard let branch = loaded.document.branches.first(where: {
            $0.id == branchID && $0.lifecycle == .active
        }) else {
            throw NovelError.branchNotFound(branchID)
        }
        guard branch.activeRunID == nil else {
            throw NovelError.projectBusy(projectID)
        }
        let discarded = Set(
            loaded.document.chapters.filter { $0.discardedAt != nil }.map(\.id)
        )
        guard !report.isStale(against: branch, discardedChapterIDs: discarded) else {
            throw NovelError.invalidInput("正文在这次扫描之后又改过了，请先重新检查。")
        }

        let jobs = NovelContinuityRepairPlanner.jobs(
            from: report.issues,
            issueIDs: issueIDs
        )
        guard !jobs.isEmpty else {
            throw NovelError.invalidInput("没有可改写的冲突章节。矛盾的先文一侧不会被改动。")
        }

        let plannedIssueIDs = Set(jobs.flatMap { $0.issues.map(\.id) })
        let requestedIssues = issueIDs.map { ids in
            report.issues.filter { ids.contains($0.id) }
        } ?? report.issues
        var repairedIssueIDs: [String] = []
        var skippedIssueIDs = requestedIssues.map(\.id).filter { !plannedIssueIDs.contains($0) }
        var repairedChapterCount = 0
        var failedChapterCount = 0

        for job in jobs {
            try Task.checkCancellation()
            do {
                let outcome = try await repairOneChapter(
                    job,
                    projectID: projectID,
                    branchID: branchID
                )
                repairedIssueIDs.append(contentsOf: outcome.repairedIssueIDs)
                skippedIssueIDs.append(contentsOf: outcome.skippedIssueIDs)
                if outcome.didWrite { repairedChapterCount += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch let structured as NovelStructuredModelExecutionFailure
                where structured.failure.code == "cancelled" {
                throw structured
            } catch {
                failedChapterCount += 1
                skippedIssueIDs.append(contentsOf: job.issues.map(\.id))
            }
        }

        return NovelContinuityRepairReport(
            projectID: projectID,
            branchID: branchID,
            repairedIssueIDs: repairedIssueIDs,
            skippedIssueIDs: skippedIssueIDs,
            repairedChapterCount: repairedChapterCount,
            failedChapterCount: failedChapterCount
        )
    }
}

private extension DefaultNovelCreation {
    struct ChapterRepairOutcome {
        let repairedIssueIDs: [String]
        let skippedIssueIDs: [String]
        let didWrite: Bool
    }

    func repairOneChapter(
        _ job: NovelContinuityRepairJob,
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> ChapterRepairOutcome {
        let loaded = try await loadCommittedProject(id: projectID)
        guard let branch = loaded.document.branches.first(where: { $0.id == branchID }) else {
            throw NovelError.branchNotFound(branchID)
        }
        guard let version = currentVersion(
            for: job.chapterID,
            in: loaded.document,
            branch: branch
        ) else {
            return ChapterRepairOutcome(
                repairedIssueIDs: [],
                skippedIssueIDs: job.issues.map(\.id),
                didWrite: false
            )
        }

        let repair = try await runContinuityRepairWithRetry(
            job: job,
            chapterContent: version.content,
            document: loaded.document
        )
        let applied = NovelContinuityRepairPatchApplier.apply(
            repair.patches,
            to: version.content,
            allowedIssueIDs: Set(job.issues.map(\.id))
        )
        let skipped = job.issues.map(\.id).filter { !applied.appliedIssueIDs.contains($0) }
        guard !applied.appliedIssueIDs.isEmpty,
              applied.content != version.content else {
            return ChapterRepairOutcome(
                repairedIssueIDs: [],
                skippedIssueIDs: job.issues.map(\.id),
                didWrite: false
            )
        }

        let command = NovelSaveManualEditCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: loaded.document.project.revision,
                expectedConfigRevision: loaded.document.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: projectID,
            branchID: branchID,
            chapterID: job.chapterID,
            versionID: NovelChapterVersionID(),
            title: version.title,
            content: applied.content,
            factCompatibilityID: UUID(),
            expectedWorkingRevision: branch.workingRevision
        )
        _ = try await executeSaveManualEditWithPlot(command)
        publishMutation(projectID: projectID, operationID: command.context.operationID)
        return ChapterRepairOutcome(
            repairedIssueIDs: applied.appliedIssueIDs,
            skippedIssueIDs: skipped,
            didWrite: true
        )
    }

    func runContinuityRepairWithRetry(
        job: NovelContinuityRepairJob,
        chapterContent: String,
        document: NovelProjectDocumentV1
    ) async throws -> NovelContinuityRepairV1 {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await runContinuityRepair(
                    job: job,
                    chapterContent: chapterContent,
                    document: document
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < continuityAuditChunkMaxAttempts,
                      isRetryableContinuityChunkFailure(error) else {
                    throw error
                }
            }
        }
    }

    func runContinuityRepair(
        job: NovelContinuityRepairJob,
        chapterContent: String,
        document: NovelProjectDocumentV1
    ) async throws -> NovelContinuityRepairV1 {
        let executor = NovelStructuredModelExecutor(modelRunner: modelRunner)
        let request = NovelStructuredModelExecutionRequest(
            runID: NovelRunID(),
            modelPolicy: modelPolicy(for: .review, in: document),
            task: .continuityRepair(
                brief: NovelContinuityRepairPrompt.userMessage(
                    for: job,
                    chapterContent: chapterContent
                )
            )
        )
        let evidence = try await executor.executeWithEvidence(
            request,
            noOutputTimeout: factRequestTimeout
        )
        guard case .continuityRepair(let repair) = evidence.output else {
            throw NovelStructuredModelExecutionFailure(
                code: "invalid_structured_output",
                message: "剧情矛盾修复返回了错误的结构。",
                isRetryable: true
            )
        }
        return repair
    }

    func currentVersion(
        for chapterID: NovelChapterID,
        in document: NovelProjectDocumentV1,
        branch: NovelBranchRecord
    ) -> NovelChapterVersionRecord? {
        guard let selection = branch.workingChapterSelections.first(where: {
            $0.chapterID == chapterID
        }) else {
            return nil
        }
        return document.chapterVersions.first {
            $0.id == selection.versionID && $0.chapterID == chapterID
        }
    }
}
