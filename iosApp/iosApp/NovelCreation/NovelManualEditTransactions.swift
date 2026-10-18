import Foundation

extension NovelFactTransactionReducer {
    static func saveManualEdit(
        _ command: NovelSaveManualEditCommand,
        payloadSHA256: String,
        in document: NovelProjectDocumentV1,
        now: Date = Date()
    ) throws -> NovelFactTransactionResult {
        try requireProject(command.projectID, in: document)
        try requirePayloadHash(payloadSHA256)
        if let outcome = try replayOutcome(
            context: command.context,
            kind: .saveManualEdit,
            payloadSHA256: payloadSHA256,
            in: document
        ) {
            return (document, outcome)
        }
        try requireUnusedOperation(command.context.operationID, in: document)
        let branchIndex = try requireBranch(command.branchID, in: document)
        let branch = document.branches[branchIndex]
        try requireContext(command.context, branch: branch, document: document)
        guard branch.lifecycle == .active else {
            throw NovelError.branchNotFound(command.branchID)
        }
        // Discussion field-write tools run inside a live discussion run. Block only
        // non-discussion active runs (prose/polish/regenerate/…), not the discussion
        // agent itself — otherwise chapter-title tools self-lock.
        if let activeRunID = branch.activeRunID {
            let activeKind = document.activeRuns.first(where: { $0.id == activeRunID })?.kind
            guard activeKind == .discussion else {
                throw NovelError.projectBusy(command.projectID)
            }
        }
        guard branch.workingRevision == command.expectedWorkingRevision else {
            throw NovelError.invalidInput(
                "The working manuscript changed before this edit was saved."
            )
        }
        guard !document.pendingOperations.contains(where: { $0.branchID == branch.id }) else {
            throw NovelError.projectBusy(command.projectID)
        }
        guard let selectionIndex = branch.workingChapterSelections.firstIndex(where: {
            $0.chapterID == command.chapterID
        }), let sourceVersion = document.chapterVersions.first(where: {
            $0.id == branch.workingChapterSelections[selectionIndex].versionID &&
                $0.chapterID == command.chapterID
        }) else {
            throw NovelError.invalidInput("The edited chapter is not in the working manuscript.")
        }
        guard document.chapterVersions.allSatisfy({ $0.id != command.versionID }),
              document.pendingOperations.allSatisfy({
                  $0.proposedChapterVersion?.id != command.versionID
              }) else {
            throw NovelError.immutableRecordConflict("chapter version \(command.versionID)")
        }
        let title = try normalizedRequired(command.title, field: "Chapter title")
        let content = normalizeLineEndings(command.content)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NovelError.invalidInput("Chapter content cannot be empty.")
        }
        guard title != sourceVersion.title || content != sourceVersion.content else {
            throw NovelError.invalidInput("The manual edit does not change the chapter.")
        }
        try requireNewFactCompatibilityID(command.factCompatibilityID, in: document)

        let version = NovelChapterVersionRecord(
            id: command.versionID,
            chapterID: command.chapterID,
            kind: .manualEdit,
            title: title,
            content: content,
            factCompatibilityID: command.factCompatibilityID,
            sourceChapterVersionID: sourceVersion.id,
            sourceCandidateID: nil,
            createdAt: now,
            operationID: command.context.operationID
        )
        let finalRevision = document.project.revision + 1
        let finalWorkingRevision = branch.workingRevision + 1
        let outcome = NovelOutcome.manualEditSaved(
            projectID: document.project.id,
            branchID: branch.id,
            chapterVersionID: version.id,
            workingRevision: finalWorkingRevision,
            revision: finalRevision
        )
        var next = document
        next.chapterVersions.append(version)
        next.branches[branchIndex].workingChapterSelections[selectionIndex] = NovelChapterSelection(
            chapterID: command.chapterID,
            versionID: version.id
        )
        next.branches[branchIndex].workingRevision = finalWorkingRevision
        next.branches[branchIndex].syncStatus = .needsSync
        next.branches[branchIndex].updatedAt = now
        next.appliedOperations.append(NovelAppliedOperationRecord(
            operationID: command.context.operationID,
            kind: .saveManualEdit,
            payloadSHA256: payloadSHA256,
            outcome: outcome,
            appliedProjectRevision: finalRevision,
            appliedAt: now
        ))
        try NovelApprovalCommit.append(
            command.context.approvalResponse,
            branchID: command.branchID,
            to: &next,
            now: now
        )
        advanceProjectRevision(in: &next, now: now)
        try validateTransition(from: document, to: next)
        return (next, outcome)
    }

    /// Contract v1.1 D-B: the manual edit and the plot module it triggers
    /// commit as ONE mutation (single revision step, single `.manualSync`
    /// checkpoint carrying both the new version and the relinked snapshot).
    /// `moduleText`/`summaryOverride` are precomputed by the lifecycle
    /// (model draft) before this transaction runs.
    static func saveManualEditWithPlot(
        _ command: NovelSaveManualEditCommand,
        payloadSHA256: String,
        moduleText: String?,
        summaryOverride: String?,
        in document: NovelProjectDocumentV1,
        now: Date = Date()
    ) throws -> NovelValidatedFactTransactionResult {
        try requireProject(command.projectID, in: document)
        try requirePayloadHash(payloadSHA256)
        if let outcome = try replayOutcome(
            context: command.context,
            kind: .saveManualEdit,
            payloadSHA256: payloadSHA256,
            in: document
        ) {
            return NovelValidatedFactTransactionResult(
                document: document,
                outcome: outcome,
                transition: nil
            )
        }
        try requireUnusedOperation(command.context.operationID, in: document)
        let branchIndex = try requireBranch(command.branchID, in: document)
        let branch = document.branches[branchIndex]
        try requireContext(command.context, branch: branch, document: document)
        guard branch.lifecycle == .active else {
            throw NovelError.branchNotFound(command.branchID)
        }
        // Discussion field-write tools run inside a live discussion run. Block only
        // non-discussion active runs (prose/polish/regenerate/…), not the discussion
        // agent itself — otherwise chapter-title tools self-lock.
        if let activeRunID = branch.activeRunID {
            let activeKind = document.activeRuns.first(where: { $0.id == activeRunID })?.kind
            guard activeKind == .discussion else {
                throw NovelError.projectBusy(command.projectID)
            }
        }
        guard branch.workingRevision == command.expectedWorkingRevision else {
            throw NovelError.invalidInput(
                "The working manuscript changed before this edit was saved."
            )
        }
        guard !document.pendingOperations.contains(where: { $0.branchID == branch.id }) else {
            throw NovelError.projectBusy(command.projectID)
        }
        guard let selectionIndex = branch.workingChapterSelections.firstIndex(where: {
            $0.chapterID == command.chapterID
        }), let sourceVersion = document.chapterVersions.first(where: {
            $0.id == branch.workingChapterSelections[selectionIndex].versionID &&
                $0.chapterID == command.chapterID
        }) else {
            throw NovelError.invalidInput("The edited chapter is not in the working manuscript.")
        }
        guard document.chapterVersions.allSatisfy({ $0.id != command.versionID }),
              document.pendingOperations.allSatisfy({
                  $0.proposedChapterVersion?.id != command.versionID
              }) else {
            throw NovelError.immutableRecordConflict("chapter version \(command.versionID)")
        }
        let title = try normalizedRequired(command.title, field: "Chapter title")
        let content = normalizeLineEndings(command.content)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NovelError.invalidInput("Chapter content cannot be empty.")
        }
        guard title != sourceVersion.title || content != sourceVersion.content else {
            throw NovelError.invalidInput("The manual edit does not change the chapter.")
        }
        try requireNewFactCompatibilityID(command.factCompatibilityID, in: document)

        let version = NovelChapterVersionRecord(
            id: command.versionID,
            chapterID: command.chapterID,
            kind: .manualEdit,
            title: title,
            content: content,
            factCompatibilityID: command.factCompatibilityID,
            sourceChapterVersionID: sourceVersion.id,
            sourceCandidateID: nil,
            createdAt: now,
            operationID: command.context.operationID
        )
        var next = document
        next.chapterVersions.append(version)
        next.branches[branchIndex].workingChapterSelections[selectionIndex] = NovelChapterSelection(
            chapterID: command.chapterID,
            versionID: version.id
        )
        next.branches[branchIndex].workingRevision = branch.workingRevision + 1
        next.branches[branchIndex].updatedAt = now

        let plotSnapshot = try NovelWorkspaceLedger.updatedPlotSnapshot(
            id: NovelStateSnapshotID(),
            replacing: branch.currentStateSnapshotID,
            workingSelections: next.branches[branchIndex].workingChapterSelections,
            updatedChapterID: command.chapterID,
            updatedTitle: title,
            updatedContent: content,
            moduleText: moduleText,
            summaryOverride: summaryOverride,
            markLaterStale: !NovelWorkspaceLedger.isFastForward(
                branch: branch,
                chapterID: command.chapterID
            ),
            in: next,
            now: now
        )
        next.stateSnapshots.append(plotSnapshot)

        let finalRevision = document.project.revision + 1
        let outcome = NovelOutcome.manualEditSaved(
            projectID: document.project.id,
            branchID: branch.id,
            chapterVersionID: version.id,
            workingRevision: next.branches[branchIndex].workingRevision,
            revision: finalRevision
        )
        try NovelApprovalCommit.append(
            command.context.approvalResponse,
            branchID: command.branchID,
            to: &next,
            now: now
        )
        let session = next.sessions.first { $0.id == branch.sessionID }
        let cursor: NovelSessionCursor = session?.messages.last.map {
            .through(sequence: $0.sequence)
        } ?? .empty
        try NovelReducer.appendCheckpoint(
            NovelBranchCheckpointRecord(
                id: NovelCheckpointID(),
                kind: .manualSync,
                createdOnBranchID: branch.id,
                parentCheckpointID: branch.headCheckpointID,
                chapterSelections: next.branches[branchIndex].workingChapterSelections,
                stateSnapshotID: plotSnapshot.id,
                sessionCursor: cursor,
                branchOverrideRevisionIDs: branch.overrideRevisionIDs,
                sourceCandidateID: nil,
                baseHeadRevision: branch.headRevision,
                operationID: command.context.operationID,
                createdAt: now
            ),
            to: &next,
            expectedHeadRevision: branch.headRevision,
            advancesWorkingRevision: false,
            now: now
        )
        next.appliedOperations.append(NovelAppliedOperationRecord(
            operationID: command.context.operationID,
            kind: .saveManualEdit,
            payloadSHA256: payloadSHA256,
            outcome: outcome,
            appliedProjectRevision: finalRevision,
            appliedAt: now
        ))
        advanceProjectRevision(in: &next, now: now)
        let transition = try NovelDocumentValidator.validateTransitionFromValidatedCurrent(
            from: document,
            to: next
        )
        return NovelValidatedFactTransactionResult(
            document: next,
            outcome: outcome,
            transition: transition
        )
    }

    static func prepareManualSync(
        _ command: NovelSyncManualEditsCommand,
        payloadSHA256: String,
        in document: NovelProjectDocumentV1,
        now: Date = Date()
    ) throws -> NovelManualSyncPreparation {
        try requireProject(command.projectID, in: document)
        try requirePayloadHash(payloadSHA256)
        if let existing = try matchingPending(
            id: command.pendingID,
            operationID: command.context.operationID,
            kind: .manualSync,
            payloadSHA256: payloadSHA256,
            in: document
        ) {
            return .needsModel(document: document, pending: existing)
        }
        try requireUnusedOperation(command.context.operationID, in: document)
        let branchIndex = try requireBranch(command.branchID, in: document)
        let branch = document.branches[branchIndex]
        try requireContext(command.context, branch: branch, document: document)
        guard branch.lifecycle == .active else {
            throw NovelError.branchNotFound(command.branchID)
        }
        guard branch.activeRunID == nil else {
            throw NovelError.projectBusy(command.projectID)
        }
        guard branch.syncStatus == .needsSync else {
            throw NovelError.invalidInput("The branch has no manual edits to synchronize.")
        }
        guard branch.workingRevision == command.expectedWorkingRevision else {
            throw NovelError.invalidInput(
                "The working manuscript changed before synchronization started."
            )
        }
        guard !document.pendingOperations.contains(where: { $0.branchID == branch.id }) else {
            throw NovelError.projectBusy(command.projectID)
        }
        try requireReservedIDs(
            chapterVersionID: nil,
            checkpointID: command.checkpointID,
            stateSnapshotID: command.stateSnapshotID,
            pendingID: command.pendingID,
            in: document
        )
        let head = try checkpoint(branch.headCheckpointID, in: document)
        let workingSelections = branch.workingChapterSelections
        // Working may diverge from head by version edits AND by structural change
        // (deleteFromManuscript removes a chapter from working while head still lists it).
        // The old equal-chapterID-list guard made every post-delete sync fail instantly.
        try validateWorkingManuscriptEvolution(
            from: head.chapterSelections,
            to: workingSelections
        )
        let stateBase = try staleStateBaseCheckpoint(
            from: head,
            in: document
        )
        let affectedIndex = firstChangedChapterIndex(
            from: stateBase.chapterSelections,
            to: workingSelections
        )
        guard let affectedIndex else {
            // needsSync but working already matches the state base: nothing to rebuild.
            throw NovelError.invalidInput(
                "当前没有需要同步的正文改动。若仍提示待同步，请点「重新载入」后再试。"
            )
        }
        // Pivot chapter for rebuild-base search:
        // - version edit / insertion: index falls inside working
        // - trailing deletion: index equals working.count (extra chapters only on base)
        let pivotChapterID: NovelChapterID
        if affectedIndex < workingSelections.count {
            pivotChapterID = workingSelections[affectedIndex].chapterID
        } else if affectedIndex < stateBase.chapterSelections.count {
            pivotChapterID = stateBase.chapterSelections[affectedIndex].chapterID
        } else {
            throw NovelError.invalidInput(
                "无法定位需要同步的章节改动，请点「重新载入」后再试。"
            )
        }
        let candidateBase = try rebuildBaseCheckpoint(
            before: pivotChapterID,
            headCheckpointID: head.id,
            in: document
        )
        let rebuildBase = try latestCompatibleRebuildBase(
            atOrBefore: candidateBase,
            workingSelections: workingSelections,
            in: document
        )
        let suffixStart = firstChangedChapterIndex(
            from: rebuildBase.chapterSelections,
            to: workingSelections
        ) ?? rebuildBase.chapterSelections.count
        guard suffixStart < workingSelections.count else {
            // Trailing-only structural removal whose content is already described by
            // rebuildBase: promote working to synchronized without a model call.
            return try commitStructuralManualSync(
                command,
                payloadSHA256: payloadSHA256,
                rebuildBase: rebuildBase,
                in: document,
                now: now
            )
        }
        var chapters: [NovelManualRebuildChapter] = []
        for selection in branch.workingChapterSelections[suffixStart...] {
            guard let version = document.chapterVersions.first(where: {
                $0.id == selection.versionID && $0.chapterID == selection.chapterID
            }) else {
                throw NovelError.invalidInput("The working manuscript contains a missing chapter version.")
            }
            chapters.append(NovelManualRebuildChapter(
                chapterID: selection.chapterID,
                versionID: version.id,
                title: version.title,
                content: version.content,
                factCompatibilityID: version.factCompatibilityID
            ))
        }
        let durablePayload = try encodeManualPayload(chapters)
        guard let session = document.sessions.first(where: { $0.id == branch.sessionID }) else {
            throw NovelError.sessionNotFound(branch.sessionID)
        }
        let cursor: NovelSessionCursor = session.messages.last.map {
            .through(sequence: $0.sequence)
        } ?? .empty
        let pending = NovelPendingOperationRecord(
            id: command.pendingID,
            kind: .manualSync,
            status: .pending,
            branchID: branch.id,
            operationID: command.context.operationID,
            payloadSHA256: payloadSHA256,
            baseCheckpointID: head.id,
            baseHeadRevision: branch.headRevision,
            baseWorkingRevision: branch.workingRevision,
            candidateID: nil,
            collectionTarget: nil,
            selectedText: durablePayload,
            proposedChapterVersion: nil,
            proposedCheckpointID: command.checkpointID,
            proposedStateSnapshotID: command.stateSnapshotID,
            rebuildBaseCheckpointID: rebuildBase.id,
            sessionCursor: cursor,
            createdAt: now,
            lastError: nil
        )
        var next = document
        next.pendingOperations.append(pending)
        advanceProjectRevision(in: &next, now: now)
        try validateTransition(from: document, to: next)
        return .needsModel(document: next, pending: pending)
    }

    /// Working manuscript is already fully covered by `rebuildBase` (same chapter
    /// versions). Typical case: a chapter was removed from the working list while
    /// earlier content is unchanged — no model call is required to clear needsSync.
    private static func commitStructuralManualSync(
        _ command: NovelSyncManualEditsCommand,
        payloadSHA256: String,
        rebuildBase: NovelBranchCheckpointRecord,
        in document: NovelProjectDocumentV1,
        now: Date
    ) throws -> NovelManualSyncPreparation {
        let branchIndex = try requireBranch(command.branchID, in: document)
        let branch = document.branches[branchIndex]
        guard rebuildBase.chapterSelections == branch.workingChapterSelections else {
            throw NovelError.invalidInput(
                "剧情同步需要重新分析正文，但未能切出有效片段。请点「重新载入」后再试。"
            )
        }
        let baseState = try stateSnapshot(rebuildBase.stateSnapshotID, in: document)
        guard let session = document.sessions.first(where: { $0.id == branch.sessionID }) else {
            throw NovelError.sessionNotFound(branch.sessionID)
        }
        let cursor: NovelSessionCursor = session.messages.last.map {
            .through(sequence: $0.sequence)
        } ?? .empty
        let snapshotID = command.stateSnapshotID
        let checkpointID = command.checkpointID
        let liveSelections = NovelWorkspaceLedger.liveWorkingSelections(branch: branch, in: document)
        let chapterPlots = NovelWorkspaceLedger.alignedModules(
            existing: baseState.chapterPlots,
            working: liveSelections,
            seeds: NovelWorkspaceLedger.seedTexts(working: liveSelections, in: document)
        )
        let newSnapshot = NovelStateSnapshotRecord(
            id: snapshotID,
            eventIDs: baseState.eventIDs,
            summary: baseState.summary,
            branchOutline: baseState.branchOutline,
            unresolvedEntityNames: baseState.unresolvedEntityNames,
            createdAt: now,
            settingProposalIDs: baseState.settingProposalIDs,
            characterIdentityClarifications: baseState.characterIdentityClarifications,
            recentWrittenHighlights: baseState.recentWrittenHighlights,
            chapterPlots: chapterPlots
        )
        let finalRevision = document.project.revision + 1
        let outcome = NovelOutcome.manualSyncCommitted(
            projectID: document.project.id,
            branchID: branch.id,
            checkpointID: checkpointID,
            revision: finalRevision
        )
        let checkpoint = NovelBranchCheckpointRecord(
            id: checkpointID,
            kind: .manualSync,
            createdOnBranchID: branch.id,
            parentCheckpointID: branch.headCheckpointID,
            chapterSelections: branch.workingChapterSelections,
            stateSnapshotID: snapshotID,
            sessionCursor: cursor,
            branchOverrideRevisionIDs: branch.overrideRevisionIDs,
            sourceCandidateID: nil,
            baseHeadRevision: branch.headRevision,
            operationID: command.context.operationID,
            createdAt: now
        )
        var next = document
        next.stateSnapshots.append(newSnapshot)
        next.appliedOperations.append(NovelAppliedOperationRecord(
            operationID: command.context.operationID,
            kind: .syncManualEdits,
            payloadSHA256: payloadSHA256,
            outcome: outcome,
            appliedProjectRevision: finalRevision,
            appliedAt: now
        ))
        try NovelReducer.appendCheckpoint(
            checkpoint,
            to: &next,
            expectedHeadRevision: branch.headRevision,
            advancesWorkingRevision: false,
            now: now
        )
        advanceProjectRevision(in: &next, now: now)
        guard next.project.revision == finalRevision else {
            throw NovelError.invalidInput("Manual synchronization revision accounting failed.")
        }
        try NovelDocumentValidator.validateTransition(from: document, to: next)
        return .completed(document: next, outcome: outcome)
    }

    static func manualRebuildInput(
        pendingID: NovelPendingOperationID,
        in document: NovelProjectDocumentV1
    ) throws -> NovelManualRebuildInput {
        let pending = try requirePending(pendingID, kind: .manualSync, in: document)
        guard let rebuildBaseCheckpointID = pending.rebuildBaseCheckpointID,
              let sessionCursor = pending.sessionCursor else {
            throw NovelError.invalidInput("The manual synchronization pending payload is incomplete.")
        }
        let rebuildBase = try checkpoint(rebuildBaseCheckpointID, in: document)
        let baseState = try stateSnapshot(rebuildBase.stateSnapshotID, in: document)
        let chapters = try decodeManualPayload(pending.selectedText)
        try validateManualPayload(chapters, pending: pending, in: document)
        let manuscript = manualRebuildManuscript(chapters)
        return NovelManualRebuildInput(
            structuredRunID: NovelRunID(pending.id.rawValue),
            pending: pending,
            rebuildBaseCheckpoint: rebuildBase,
            baseStateSnapshot: baseState,
            chapters: chapters,
            sessionCursor: sessionCursor,
            baseContext: try stateContext(baseState, branchID: pending.branchID, in: document),
            manuscript: manuscript
        )
    }

    static func validateRetryCommand(
        _ command: NovelRetryPendingCommand,
        in document: NovelProjectDocumentV1
    ) throws -> NovelPendingOperationRecord {
        guard let pending = document.pendingOperations.first(where: {
            $0.id == command.pendingID
        }) else {
            throw NovelError.invalidInput("The pending fact transaction was not found.")
        }
        let payloadSHA256 = try command.canonicalPayloadSHA256()
        if let attempt = document.factAttempts.first(where: {
            $0.attemptOperationID == command.context.operationID
        }) {
            let expectedKind: NovelFactReceiptKind = pending.kind == .collection
                ? .stateDelta
                : .manualRebuild
            guard command.projectID == document.project.id,
                  attempt.pendingID == pending.id,
                  attempt.ownerOperationID == pending.operationID,
                  attempt.attemptPayloadSHA256 == payloadSHA256,
                  attempt.branchID == pending.branchID,
                  attempt.kind == expectedKind else {
                throw NovelError.idempotencyConflict(command.context.operationID)
            }
            return pending
        }
        try validateRetry(command, for: pending, in: document)
        return pending
    }

    static func finalizeManualSync(
        pendingID: NovelPendingOperationID,
        rebuild: NovelStateRebuildV1,
        retryCommand: NovelRetryPendingCommand? = nil,
        validatedAttempt: NovelFactTransactionAttempt? = nil,
        artifacts: NovelFactTransactionReceiptArtifacts? = nil,
        in document: NovelProjectDocumentV1,
        now: Date = Date()
    ) throws -> NovelFactTransactionResult {
        let pending = try requirePending(pendingID, kind: .manualSync, in: document)
        let attempt: NovelFactTransactionAttempt
        if let validatedAttempt {
            guard retryCommand == nil else {
                throw NovelError.invalidInput("Manual sync received two retry ownership proofs.")
            }
            try validateDurableAttempt(validatedAttempt, for: pending, in: document)
            attempt = validatedAttempt
        } else {
            try validateRetry(retryCommand, for: pending, in: document)
            attempt = try NovelFactTransactionAttempt(
                pending: pending,
                retryCommand: retryCommand
            )
        }
        let branchIndex = try requireBranch(pending.branchID, in: document)
        let branch = document.branches[branchIndex]
        try requirePendingGuards(
            pending,
            branch: branch,
            projectID: document.project.id
        )
        guard branch.syncStatus == .needsSync else {
            throw NovelError.invalidInput("The branch no longer requires manual synchronization.")
        }
        let input = try manualRebuildInput(pendingID: pendingID, in: document)
        if let progress = pending.manualSyncProgress {
            guard NovelManualSyncProgressReducer.isComplete(
                progress,
                manuscript: input.manuscript
            ), progress.accumulatedRebuild == rebuild,
            artifacts == nil else {
                throw NovelError.invalidInput("Manual synchronization progress is not ready to finalize.")
            }
        } else if artifacts == nil {
            throw NovelError.invalidInput("Manual synchronization has no completed model evidence.")
        }
        // Host-accepted empty rebuilds may keep a blank project's empty
        // summary/outline. Model-schema `validate` rejects those empty
        // strings, but they are legal durable snapshot values. Mapped
        // last-chapter deltas may also keep an empty outline when the
        // model omitted `branchOutlinePatch`.
        let validatedRebuild = skipsRebuildModelSchema(
            rebuild,
            summary: input.baseStateSnapshot.summary,
            outline: input.baseStateSnapshot.branchOutline
        ) ? rebuild : try validate(rebuild)
        try validateStateFacts(
            validatedRebuild,
            evidenceSource: input.manuscript,
            branch: branch,
            baseState: input.baseStateSnapshot,
            in: document
        )
        guard let checkpointID = pending.proposedCheckpointID,
              let snapshotID = pending.proposedStateSnapshotID else {
            throw NovelError.invalidInput("The manual synchronization reserved IDs are missing.")
        }
        let eventDrafts: [StoryEventDraft]
        if let progress = pending.manualSyncProgress {
            eventDrafts = try storyEventDrafts(
                progress,
                manuscript: input.manuscript
            )
        } else {
            eventDrafts = try storyEventDrafts(
                validatedRebuild,
                evidenceSource: input.manuscript
            )
        }
        let newEvents = try storyEvents(
            eventDrafts,
            namespace: pending.operationID,
            baseState: input.baseStateSnapshot,
            in: document,
            now: now
        )
        let proposals = try settingProposals(
            validatedRebuild.settingProposals,
            namespace: pending.operationID,
            branchID: branch.id,
            in: document,
            now: now
        )
        let liveSelections = NovelWorkspaceLedger.liveWorkingSelections(branch: branch, in: document)
        let rebuiltChapterIDs = Set(input.chapters.map(\.chapterID))
        // Keep author-curated plots before the rebuilt suffix; refreshed chapters
        // use their current text and must not inherit an old stale marker.
        let chapterPlots = NovelWorkspaceLedger.alignedModules(
            existing: input.baseStateSnapshot.chapterPlots.filter {
                !rebuiltChapterIDs.contains($0.chapterID)
            },
            working: liveSelections,
            seeds: NovelWorkspaceLedger.seedTexts(working: liveSelections, in: document)
        )
        let newSnapshot = NovelStateSnapshotRecord(
            id: snapshotID,
            eventIDs: input.baseStateSnapshot.eventIDs + newEvents.map(\.id),
            summary: validatedRebuild.stateSummary,
            branchOutline: validatedRebuild.branchOutline,
            unresolvedEntityNames: validatedRebuild.unresolvedEntityNames,
            createdAt: now,
            settingProposalIDs: input.baseStateSnapshot.settingProposalIDs + proposals.map(\.id),
            characterIdentityClarifications: input.baseStateSnapshot.characterIdentityClarifications,
            recentWrittenHighlights: NovelStateSnapshotRecord.mergedHighlights(
                prior: input.baseStateSnapshot.recentWrittenHighlights,
                newEventSummaries: newEvents.map(\.summary)
            ),
            chapterPlots: chapterPlots
        )
        let finalRevision = document.project.revision + 1
        let outcome = NovelOutcome.manualSyncCommitted(
            projectID: document.project.id,
            branchID: branch.id,
            checkpointID: checkpointID,
            revision: finalRevision
        )
        let checkpoint = NovelBranchCheckpointRecord(
            id: checkpointID,
            kind: .manualSync,
            createdOnBranchID: branch.id,
            parentCheckpointID: pending.baseCheckpointID,
            chapterSelections: branch.workingChapterSelections,
            stateSnapshotID: snapshotID,
            sessionCursor: input.sessionCursor,
            branchOverrideRevisionIDs: branch.overrideRevisionIDs,
            sourceCandidateID: nil,
            baseHeadRevision: pending.baseHeadRevision,
            operationID: pending.operationID,
            createdAt: now
        )

        var next = document
        next.events.append(contentsOf: newEvents)
        next.stateSnapshots.append(newSnapshot)
        next.settingProposals.append(contentsOf: proposals)
        if validatedAttempt != nil {
            try appendLedger(
                pending: pending,
                outcome: outcome,
                attempt: attempt,
                appliedRevision: finalRevision,
                to: &next,
                now: now
            )
        } else {
            try appendLedger(
                pending: pending,
                outcome: outcome,
                retryCommand: retryCommand,
                appliedRevision: finalRevision,
                to: &next,
                now: now
            )
        }
        if let artifacts {
            try appendFactReceipts(
                artifacts,
                pending: pending,
                retryCommand: retryCommand,
                kind: .manualRebuild,
                to: &next
            )
        }
        try NovelReducer.appendCheckpoint(
            checkpoint,
            to: &next,
            expectedHeadRevision: pending.baseHeadRevision,
            advancesWorkingRevision: false,
            now: now
        )
        next.pendingOperations.removeAll { $0.id == pending.id }
        advanceProjectRevision(in: &next, now: now)
        guard next.project.revision == finalRevision else {
            throw NovelError.invalidInput("Manual synchronization revision accounting failed.")
        }
        try validateTransition(from: document, to: next)
        return (next, outcome)
    }

    private struct ManualPayload: Codable {
        let schemaVersion: Int
        let chapters: [NovelManualRebuildChapter]
    }

    private static func rebuildBaseCheckpoint(
        before chapterID: NovelChapterID,
        headCheckpointID: NovelCheckpointID,
        in document: NovelProjectDocumentV1
    ) throws -> NovelBranchCheckpointRecord {
        var reversed: [NovelBranchCheckpointRecord] = []
        var visited: Set<NovelCheckpointID> = []
        var current: NovelBranchCheckpointRecord? = try checkpoint(headCheckpointID, in: document)
        while let node = current {
            guard visited.insert(node.id).inserted else {
                throw NovelError.invalidInput("The checkpoint lineage contains a cycle.")
            }
            reversed.append(node)
            current = try node.parentCheckpointID.map { try checkpoint($0, in: document) }
        }
        let lineage = reversed.reversed()
        guard let introduction = lineage.first(where: {
            $0.chapterSelections.contains(where: { $0.chapterID == chapterID })
        }) else {
            throw NovelError.invalidInput("The edited chapter has no checkpoint introduction.")
        }
        if let parentID = introduction.parentCheckpointID {
            return try checkpoint(parentID, in: document)
        }
        return introduction
    }

    /// 重建基线必须满足一条不变量：它的 stateSnapshot 恰好是**为它自己那份 chapterSelections
    /// 重建出来的**。只有 `.initial`(空选集空状态)和 `.manualSync`(状态由本次重建产出)满足。
    ///
    /// 其余 kind 都是把 `branch.currentStateSnapshotID` 原样继承下来的：`.collection`
    /// 尤其危险,它的选集比快照多一章。一旦被选作基线,suffix 按选集算就会跳过那些
    /// 「在选集里、但不在快照里」的章节 —— 它们既不在基线状态里,也不在待重抽的正文里,
    /// 事实凭空蒸发。见 NovelChapterReplacementStateTests
    /// .testReplacingChapterKeepsEarlierFactsWhenCollectionsSkippedSync。
    private static func latestCompatibleRebuildBase(
        atOrBefore checkpoint: NovelBranchCheckpointRecord,
        workingSelections: [NovelChapterSelection],
        in document: NovelProjectDocumentV1
    ) throws -> NovelBranchCheckpointRecord {
        var current: NovelBranchCheckpointRecord? = checkpoint
        var visited: Set<NovelCheckpointID> = []
        while let candidate = current {
            guard visited.insert(candidate.id).inserted else {
                throw NovelError.invalidInput("The checkpoint lineage contains a cycle.")
            }
            if candidate.stateSnapshotDescribesOwnSelections,
               candidate.chapterSelections.count <= workingSelections.count,
               zip(candidate.chapterSelections, workingSelections).allSatisfy({
                   $0.chapterID == $1.chapterID && $0.versionID == $1.versionID
               }) {
                return candidate
            }
            current = try candidate.parentCheckpointID.map {
                try self.checkpoint($0, in: document)
            }
        }
        throw NovelError.invalidInput("No valid rebuild base exists for the working manuscript.")
    }

    private static func staleStateBaseCheckpoint(
        from head: NovelBranchCheckpointRecord,
        in document: NovelProjectDocumentV1
    ) throws -> NovelBranchCheckpointRecord {
        var current = head
        var visited: Set<NovelCheckpointID> = []
        while current.kind == .collection,
              let parentID = current.parentCheckpointID {
            guard visited.insert(current.id).inserted else {
                throw NovelError.invalidInput("The checkpoint lineage contains a cycle.")
            }
            let parent = try checkpoint(parentID, in: document)
            guard parent.stateSnapshotID == current.stateSnapshotID else { break }
            current = parent
        }
        return current
    }

    private static func firstChangedChapterIndex(
        from base: [NovelChapterSelection],
        to current: [NovelChapterSelection]
    ) -> Int? {
        let sharedCount = min(base.count, current.count)
        if let changed = (0..<sharedCount).first(where: { base[$0] != current[$0] }) {
            return changed
        }
        return base.count == current.count ? nil : sharedCount
    }

    /// Accept version edits, order-preserving deletes (including middle), and trailing
    /// appends. Reject reorder / duplicate chapter IDs.
    private static func validateWorkingManuscriptEvolution(
        from head: [NovelChapterSelection],
        to working: [NovelChapterSelection]
    ) throws {
        let headIDs = head.map(\.chapterID)
        let workingIDs = working.map(\.chapterID)
        guard Set(workingIDs).count == workingIDs.count else {
            throw NovelError.invalidInput(
                "工作稿章节列表重复，无法同步。请点「重新载入」后再试。"
            )
        }
        if headIDs == workingIDs { return }
        // Any deletes (end or middle) that keep relative order of remaining chapters.
        if isOrderPreservingSubsequence(workingIDs, of: headIDs) { return }
        // Trailing append(s) of brand-new chapters after the previous head list.
        if workingIDs.starts(with: headIDs) { return }
        // Deletes + trailing appends: a prefix of working is a subsequence of head,
        // then only brand-new chapter IDs follow.
        let keptCount = orderPreservingSubsequenceLength(workingIDs, of: headIDs)
        if keptCount > 0, keptCount < workingIDs.count {
            let newTail = Array(workingIDs[keptCount...])
            let headSet = Set(headIDs)
            if newTail.allSatisfy({ !headSet.contains($0) }) {
                return
            }
        }
        throw NovelError.invalidInput(
            "工作稿章节顺序与存档不一致，无法同步。请点「重新载入」后再试。"
        )
    }

    /// Whether `needle` appears in order inside `haystack` (not necessarily contiguous).
    private static func isOrderPreservingSubsequence(
        _ needle: [NovelChapterID],
        of haystack: [NovelChapterID]
    ) -> Bool {
        orderPreservingSubsequenceLength(needle, of: haystack) == needle.count
    }

    /// How many leading elements of `needle` form an order-preserving subsequence of
    /// `haystack`.
    private static func orderPreservingSubsequenceLength(
        _ needle: [NovelChapterID],
        of haystack: [NovelChapterID]
    ) -> Int {
        var i = 0
        for id in haystack {
            if i < needle.count, needle[i] == id {
                i += 1
            }
        }
        return i
    }

    private static func encodeManualPayload(
        _ chapters: [NovelManualRebuildChapter]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ManualPayload(schemaVersion: 1, chapters: chapters))
        guard let value = String(data: data, encoding: .utf8) else {
            throw NovelError.invalidInput("The manual synchronization payload is not UTF-8.")
        }
        return value
    }

    static func decodeManualPayload(
        _ value: String
    ) throws -> [NovelManualRebuildChapter] {
        do {
            let payload = try JSONDecoder().decode(ManualPayload.self, from: Data(value.utf8))
            guard payload.schemaVersion == 1, !payload.chapters.isEmpty else {
                throw NovelError.invalidInput("The manual synchronization payload is invalid.")
            }
            return payload.chapters
        } catch let error as NovelError {
            throw error
        } catch {
            throw NovelError.invalidInput("The manual synchronization payload is unreadable: \(error)")
        }
    }

    static func manualRebuildManuscript(_ chapters: [NovelManualRebuildChapter]) -> String {
        chapters.map {
            "# \($0.title)\n\n\($0.content)"
        }.joined(separator: "\n\n")
    }

    static func validateManualPayload(
        _ chapters: [NovelManualRebuildChapter],
        pending: NovelPendingOperationRecord,
        in document: NovelProjectDocumentV1
    ) throws {
        guard Set(chapters.map(\.chapterID)).count == chapters.count,
              Set(chapters.map(\.versionID)).count == chapters.count else {
            throw NovelError.invalidInput("The manual synchronization suffix repeats a chapter.")
        }
        let branchIndex = try requireBranch(pending.branchID, in: document)
        let working = document.branches[branchIndex].workingChapterSelections
        guard let rebuildBaseID = pending.rebuildBaseCheckpointID else {
            throw NovelError.invalidInput("The durable manual synchronization rebuild base is missing.")
        }
        let rebuildBase = try checkpoint(rebuildBaseID, in: document)
        let suffixSelections = chapters.map {
            NovelChapterSelection(chapterID: $0.chapterID, versionID: $0.versionID)
        }
        guard rebuildBase.chapterSelections + suffixSelections == working else {
            throw NovelError.invalidInput("The durable manual synchronization suffix is stale.")
        }
        for chapter in chapters {
            guard document.chapterVersions.contains(where: {
                $0.id == chapter.versionID &&
                    $0.chapterID == chapter.chapterID &&
                    $0.title == chapter.title &&
                    $0.content == chapter.content &&
                    $0.factCompatibilityID == chapter.factCompatibilityID
            }) else {
                throw NovelError.invalidInput("A durable manual synchronization chapter changed.")
            }
        }
    }

    private static func normalizeLineEndings(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

}

private extension NovelBranchCheckpointRecord {
    /// 这个检查点的 stateSnapshot 是否恰好描述它自己那份 chapterSelections。
    ///
    /// `.initial` 是空选集配空状态;`.manualSync` 的快照由该次重建产出,覆盖
    /// 「基线 + suffix」= 自身选集;`.identityClarification` 不改变正文选集，只在
    /// 同一份派生状态上追加作者裁决。其余 kind 都只是把分支当前快照原样带下来，
    /// 快照落后于选集,不能用作重建基线。
    var stateSnapshotDescribesOwnSelections: Bool {
        switch kind {
        case .initial, .manualSync, .identityClarification:
            true
        case .collection, .discussionArchive, .polish, .restore:
            false
        }
    }
}
