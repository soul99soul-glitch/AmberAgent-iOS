import Foundation

struct NovelManualRebuildChapter: Codable, Equatable, Sendable {
    let chapterID: NovelChapterID
    let versionID: NovelChapterVersionID
    let title: String
    let content: String
    let factCompatibilityID: UUID
}

struct NovelCollectionExtractionInput: Equatable, Sendable {
    let structuredRunID: NovelRunID
    let pending: NovelPendingOperationRecord
    let baseCheckpoint: NovelBranchCheckpointRecord
    let baseStateSnapshot: NovelStateSnapshotRecord
    let baseContext: String
    let manuscript: String
}

struct NovelManualRebuildInput: Equatable, Sendable {
    let structuredRunID: NovelRunID
    let pending: NovelPendingOperationRecord
    let rebuildBaseCheckpoint: NovelBranchCheckpointRecord
    let baseStateSnapshot: NovelStateSnapshotRecord
    let chapters: [NovelManualRebuildChapter]
    let sessionCursor: NovelSessionCursor
    let baseContext: String
    let manuscript: String
}

struct NovelFactTransactionReceiptArtifacts: Equatable, Sendable {
    let injectionReceipt: NovelInjectionReceiptRecord
    let generationReceipt: NovelGenerationReceiptRecord
}

typealias NovelPendingFactTransactionResult = (document: NovelProjectDocumentV1, pending: NovelPendingOperationRecord)
typealias NovelFactTransactionResult = (document: NovelProjectDocumentV1, outcome: NovelOutcome)

struct NovelValidatedFactTransactionResult: Sendable {
    let document: NovelProjectDocumentV1
    let outcome: NovelOutcome
    let transition: NovelValidatedProjectTransition?
}

/// Manual-sync may finish without a model call when the working manuscript is
/// already fully described by a compatible rebuild base (e.g. trailing chapter
/// delete only).
enum NovelManualSyncPreparation: Sendable {
    case needsModel(document: NovelProjectDocumentV1, pending: NovelPendingOperationRecord)
    case completed(document: NovelProjectDocumentV1, outcome: NovelOutcome)

    /// Test / call-site convenience: document after preparation.
    var document: NovelProjectDocumentV1 {
        switch self {
        case .needsModel(let document, _), .completed(let document, _):
            document
        }
    }

    /// Pending only when a model rebuild is still required.
    var pending: NovelPendingOperationRecord? {
        if case .needsModel(_, let pending) = self { return pending }
        return nil
    }
}

enum NovelFactTransactionReducer {
    static func replayOutcome(
        context: NovelMutationContext,
        kind: NovelOperationKind,
        payloadSHA256: String,
        in document: NovelProjectDocumentV1
    ) throws -> NovelOutcome? {
        try NovelReducer.replayOutcome(
            context: context,
            kind: kind,
            payloadSHA256: payloadSHA256,
            in: document
        )
    }

    static func prepareCollection(
        _ command: NovelCollectCandidateCommand,
        payloadSHA256: String,
        in document: NovelProjectDocumentV1,
        now: Date = Date()
    ) throws -> NovelPendingFactTransactionResult {
        try requireProject(command.projectID, in: document)
        try requirePayloadHash(payloadSHA256)
        if let existing = try matchingPending(
            id: command.pendingID,
            operationID: command.context.operationID,
            kind: .collection,
            payloadSHA256: payloadSHA256,
            in: document
        ) {
            return (document, existing)
        }
        guard let branch = document.branches.first(where: { $0.id == command.branchID }),
              branch.syncStatus == .synchronized else {
            throw NovelError.invalidInput("The working manuscript must be synchronized before starting legacy collection recovery.")
        }
        let pending = try makeCollectionPending(
            command,
            payloadSHA256: payloadSHA256,
            in: document,
            now: now
        )
        var next = document
        next.pendingOperations.append(pending)
        advanceProjectRevision(in: &next, now: now)
        try validateTransition(from: document, to: next)
        return (next, pending)
    }

    static func recoverPendingCollectionWithoutStateSync(
        _ command: NovelRetryPendingCommand,
        in document: NovelProjectDocumentV1,
        now: Date = Date()
    ) throws -> NovelFactTransactionResult {
        let pending = try requirePending(command.pendingID, kind: .collection, in: document)
        try validateRetry(command, for: pending, in: document)
        return try commitPreparedCollection(
            pending,
            retryCommand: command,
            in: document,
            now: now
        )
    }

    static func commitCollectionWithoutStateSync(
        _ command: NovelCollectCandidateCommand,
        payloadSHA256: String,
        in document: NovelProjectDocumentV1,
        now: Date = Date()
    ) throws -> NovelFactTransactionResult {
        try requireProject(command.projectID, in: document)
        try requirePayloadHash(payloadSHA256)
        let pending = try makeCollectionPending(
            command,
            payloadSHA256: payloadSHA256,
            in: document,
            now: now
        )
        return try commitPreparedCollection(
            pending,
            retryCommand: nil,
            in: document,
            now: now
        )
    }

    /// Contract v1.1 D-B: the collected chapter and the plot module it
    /// updates land in ONE atomic commit. The relinked plot snapshot is
    /// computed by the caller before this transaction and carried by the
    /// single `.collection` checkpoint — no follow-up pointer commit.
    static func commitCollectionWithPlot(
        _ command: NovelCollectCandidateCommand,
        payloadSHA256: String,
        moduleText: String?,
        summaryOverride: String?,
        in document: NovelProjectDocumentV1,
        now: Date = Date()
    ) throws -> NovelFactTransactionResult {
        try requireProject(command.projectID, in: document)
        try requirePayloadHash(payloadSHA256)
        guard let branch = document.branches.first(where: { $0.id == command.branchID }) else {
            throw NovelError.branchNotFound(command.branchID)
        }
        let chapterID: NovelChapterID
        switch command.target {
        case .createNextChapter(let id, _):
            chapterID = id
        case .replaceChapter(let id), .appendToChapter(let id):
            chapterID = id
        }
        let pending = try makeCollectionPending(
            command,
            payloadSHA256: payloadSHA256,
            in: document,
            now: now
        )
        let plotUpdate = CollectionPlotUpdate(
            chapterID: chapterID,
            snapshotID: command.stateSnapshotID,
            moduleText: moduleText,
            summaryOverride: summaryOverride,
            markLaterStale: !NovelWorkspaceLedger.isFastForwardCollect(
                command.target,
                branch: branch
            )
        )
        return try commitPreparedCollection(
            pending,
            retryCommand: nil,
            plotUpdate: plotUpdate,
            in: document,
            now: now
        )
    }

    struct CollectionPlotUpdate {
        let chapterID: NovelChapterID
        let snapshotID: NovelStateSnapshotID
        let moduleText: String?
        let summaryOverride: String?
        let markLaterStale: Bool
    }

    /// Ghostwrite's accepted candidate path: collect the selected prose and
    /// its state delta while consuming the exact confirmed plan that produced
    /// the candidate. The pending record is an in-memory transaction input;
    /// it is never appended to the returned document.
    static func commitGhostwriteAdjudication(
        _ command: NovelCollectCandidateCommand,
        payloadSHA256: String,
        planID: NovelChapterPlanID,
        planDigest: String,
        nextPlanID: NovelChapterPlanID? = nil,
        nextPlan: NovelChapterPlanProposalV1? = nil,
        delta: NovelStateDeltaV1,
        artifacts: NovelFactTransactionReceiptArtifacts,
        in document: NovelProjectDocumentV1,
        now: Date = Date()
    ) throws -> NovelFactTransactionResult {
        try requireProject(command.projectID, in: document)
        try requirePayloadHash(payloadSHA256)
        guard command.source == .systemAutoCollect else {
            throw NovelError.invalidInput(
                "Ghostwrite adjudication must use the system collection source."
            )
        }
        guard document.branches.contains(where: { $0.id == command.branchID }) else {
            throw NovelError.branchNotFound(command.branchID)
        }
        guard let plan = document.confirmedChapterPlan(for: command.branchID),
              plan.id == planID,
              plan.contentDigest == planDigest else {
            throw NovelError.invalidInput(
                "The current confirmed chapter plan does not match the adjudication."
            )
        }
        guard let candidate = document.candidates.first(where: {
            $0.id == command.candidateID && $0.branchID == command.branchID
        }),
        candidate.ghostwritePlanID == plan.id,
        candidate.chapterPlanDigest == plan.contentDigest else {
            throw NovelError.invalidInput(
                "The candidate does not match the current confirmed chapter plan."
            )
        }
        guard (nextPlanID == nil) == (nextPlan == nil) else {
            throw NovelError.invalidInput(
                "The replacement chapter plan is incomplete."
            )
        }
        let replacementPlan = try nextPlan.map { proposal in
            guard let nextPlanID, nextPlanID != plan.id else {
                throw NovelError.invalidInput(
                    "The next chapter plan must use a new identity."
                )
            }
            return try confirmedChapterPlan(
                id: nextPlanID,
                branchID: command.branchID,
                proposal: proposal,
                now: now
            )
        }
        let pending = try makeCollectionPending(
            command,
            payloadSHA256: payloadSHA256,
            in: document,
            now: now
        )
        return try commitStateDeltaCollection(
            pending: pending,
            validatedDelta: try validate(delta),
            retryCommand: nil,
            artifacts: artifacts,
            in: document,
            now: now,
            acceptEmptyFacts: false,
            consumeChapterPlanID: plan.id,
            replacementChapterPlan: replacementPlan
        )
    }

    private static func commitPreparedCollection(
        _ pending: NovelPendingOperationRecord,
        retryCommand: NovelRetryPendingCommand?,
        plotUpdate: CollectionPlotUpdate? = nil,
        in document: NovelProjectDocumentV1,
        now: Date
    ) throws -> NovelFactTransactionResult {
        var next = document
        let branchIndex = try requireBranch(pending.branchID, in: next)
        let branch = next.branches[branchIndex]
        try requirePendingGuards(
            pending,
            branch: branch,
            projectID: document.project.id
        )
        guard let candidateIndex = next.candidates.firstIndex(where: {
            $0.id == pending.candidateID
        }), let proposedVersion = pending.proposedChapterVersion,
        let checkpointID = pending.proposedCheckpointID,
        let target = pending.collectionTarget,
        let sessionCursor = pending.sessionCursor else {
            throw NovelError.invalidInput("The prepared collection is incomplete.")
        }
        let candidate = next.candidates[candidateIndex]
        guard let sessionIndex = next.sessions.firstIndex(where: {
            $0.id == candidate.sessionID && $0.branchID == branch.id
        }) else {
            throw NovelError.invalidInput("The prepared collection lost its owning Session.")
        }
        let baseCheckpoint = try checkpoint(pending.baseCheckpointID, in: next)
        var chapterSelections = branch.workingChapterSelections
        var chapterToAdd: NovelChapterRecord?
        switch target {
        case .appendToChapter(let chapterID), .replaceChapter(let chapterID):
            guard let index = chapterSelections.firstIndex(where: { $0.chapterID == chapterID }),
                  proposedVersion.chapterID == chapterID else {
                throw NovelError.invalidInput("The collection append target is stale.")
            }
            chapterSelections[index] = NovelChapterSelection(
                chapterID: chapterID,
                versionID: proposedVersion.id
            )
        case .createNextChapter(let chapterID, _):
            guard proposedVersion.chapterID == chapterID,
                  !next.chapters.contains(where: { $0.id == chapterID }) else {
                throw NovelError.immutableRecordConflict("chapter \(chapterID)")
            }
            chapterToAdd = NovelChapterRecord(id: chapterID, createdAt: now)
            chapterSelections.append(NovelChapterSelection(
                chapterID: chapterID,
                versionID: proposedVersion.id
            ))
        }

        let finalRevision = document.project.revision + 1
        let outcome = NovelOutcome.candidateCollected(
            projectID: document.project.id,
            branchID: branch.id,
            candidateID: candidate.id,
            checkpointID: checkpointID,
            chapterVersionID: proposedVersion.id,
            revision: finalRevision
        )

        if let chapterToAdd { next.chapters.append(chapterToAdd) }
        next.chapterVersions.append(proposedVersion)

        var snapshotID = baseCheckpoint.stateSnapshotID
        if let plotUpdate {
            let plotSnapshot = try NovelWorkspaceLedger.updatedPlotSnapshot(
                id: plotUpdate.snapshotID,
                replacing: baseCheckpoint.stateSnapshotID,
                workingSelections: chapterSelections,
                updatedChapterID: plotUpdate.chapterID,
                updatedTitle: proposedVersion.title,
                updatedContent: proposedVersion.content,
                moduleText: plotUpdate.moduleText,
                summaryOverride: plotUpdate.summaryOverride,
                markLaterStale: plotUpdate.markLaterStale,
                in: next,
                now: now
            )
            next.stateSnapshots.append(plotSnapshot)
            snapshotID = plotSnapshot.id
        }

        let checkpoint = NovelBranchCheckpointRecord(
            id: checkpointID,
            kind: .collection,
            createdOnBranchID: branch.id,
            parentCheckpointID: pending.baseCheckpointID,
            chapterSelections: chapterSelections,
            stateSnapshotID: snapshotID,
            sessionCursor: sessionCursor,
            branchOverrideRevisionIDs: branch.overrideRevisionIDs,
            sourceCandidateID: candidate.id,
            baseHeadRevision: pending.baseHeadRevision,
            operationID: pending.operationID,
            createdAt: now
        )

        try appendLedger(
            pending: pending,
            outcome: outcome,
            retryCommand: retryCommand,
            appliedRevision: finalRevision,
            to: &next,
            now: now
        )
        let currentOperationIDs = Set([
            pending.operationID,
            retryCommand?.context.operationID
        ].compactMap { $0 })
        for attempt in next.factAttempts where
            attempt.pendingID == pending.id &&
            !currentOperationIDs.contains(attempt.attemptOperationID) &&
            !next.appliedOperations.contains(where: {
                $0.operationID == attempt.attemptOperationID
            }) {
            next.appliedOperations.append(NovelAppliedOperationRecord(
                operationID: attempt.attemptOperationID,
                kind: .retryPending,
                payloadSHA256: attempt.attemptPayloadSHA256,
                outcome: outcome,
                appliedProjectRevision: finalRevision,
                appliedAt: now
            ))
        }
        next.candidates[candidateIndex].status = .collected
        next.candidates[candidateIndex].collectedCheckpointID = checkpoint.id
        next.sessions[sessionIndex].revision += 1
        try NovelReducer.appendCheckpoint(
            checkpoint,
            to: &next,
            expectedHeadRevision: pending.baseHeadRevision,
            now: now
        )
        next.branches[branchIndex].syncStatus = plotUpdate == nil ? .needsSync : .synchronized
        next.pendingOperations.removeAll { $0.id == pending.id }
        advanceProjectRevision(in: &next, now: now)
        guard next.project.revision == finalRevision else {
            throw NovelError.invalidInput("Collection revision accounting failed.")
        }
        try validateTransition(from: document, to: next)
        return (next, outcome)
    }

    private static func makeCollectionPending(
        _ command: NovelCollectCandidateCommand,
        payloadSHA256: String,
        in document: NovelProjectDocumentV1,
        now: Date
    ) throws -> NovelPendingOperationRecord {
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
        guard !document.pendingOperations.contains(where: { $0.branchID == branch.id }) else {
            throw NovelError.projectBusy(command.projectID)
        }
        // Contract v1.1 D-D: collecting NEW forward content is gated while
        // later chapters' plot modules are unresolved after a middle-chapter
        // edit. Replacing an already-stale chapter IS one of the sanctioned
        // resolutions, so it stays open.
        if NovelWorkspaceLedger.hasUnresolvedChapterPlots(
            branchID: command.branchID,
            in: document
        ) {
            let replacesStaleChapter: Bool
            if case .replaceChapter(let chapterID) = command.target {
                replacesStaleChapter = document.stateSnapshots
                    .first { $0.id == branch.currentStateSnapshotID }?
                    .chapterPlots
                    .contains { $0.chapterID == chapterID && $0.stale } == true
            } else {
                replacesStaleChapter = false
            }
            guard replacesStaleChapter else {
                throw NovelError.invalidInput(
                    NovelWorkspaceLedger.unresolvedPlotGateMessage
                )
            }
        }
        guard let candidate = document.candidates.first(where: {
            $0.id == command.candidateID
        }) else {
            throw NovelError.invalidInput("The prose candidate was not found.")
        }
        guard candidate.branchID == branch.id,
              candidate.sessionID == branch.sessionID,
              candidate.kind == .prose,
              candidate.status == .available || candidate.status == .interrupted,
              candidate.collectedCheckpointID == nil else {
            throw NovelError.invalidInput("The candidate is not collectable prose for this branch.")
        }
        if let boundDigest = candidate.chapterPlanDigest {
            let currentDigest = document.confirmedChapterPlan(for: branch.id)?.contentDigest
            guard currentDigest == boundDigest else {
                throw NovelError.invalidInput(
                    "The candidate no longer matches the confirmed chapter plan."
                )
            }
        } else if command.source == .systemAutoCollect {
            throw NovelError.invalidInput(
                "Automatic collection requires a candidate bound to a confirmed chapter plan."
            )
        }
        guard NovelCandidateSemantics.collectionBaseMatches(
            candidate,
            targetCheckpointID: branch.headCheckpointID,
            targetHeadRevision: branch.headRevision,
            in: document
        ) else {
            throw NovelError.staleBranchHeadRevision(
                expected: candidate.baseHeadRevision,
                actual: branch.headRevision
            )
        }
        guard let rootCandidateID = NovelCandidateSemantics.rootCandidateID(
            for: candidate,
            in: document.candidates
        ),
              let session = document.sessions.first(where: { $0.id == branch.sessionID }),
              let sourceMessage = session.messages.first(where: {
                  $0.id == candidate.sourceMessageID && $0.candidateID == rootCandidateID
              }) else {
            throw NovelError.invalidInput("The candidate source message is unavailable.")
        }

        let selectedText = try NovelParagraphParser.selectedText(
            for: command.selection,
            in: candidate.content
        )
        try requireReservedIDs(
            chapterVersionID: command.proposedChapterVersionID,
            checkpointID: command.checkpointID,
            stateSnapshotID: command.stateSnapshotID,
            pendingID: command.pendingID,
            in: document
        )
        try requireNewFactCompatibilityID(command.factCompatibilityID, in: document)

        let proposedVersion: NovelChapterVersionRecord
        switch command.target {
        case .appendToChapter(let chapterID):
            guard let selection = branch.workingChapterSelections.first(where: {
                $0.chapterID == chapterID
            }), let baseVersion = document.chapterVersions.first(where: {
                $0.id == selection.versionID && $0.chapterID == chapterID
            }) else {
                throw NovelError.invalidInput("The append target is not in the current manuscript.")
            }
            proposedVersion = NovelChapterVersionRecord(
                id: command.proposedChapterVersionID,
                chapterID: chapterID,
                kind: .collected,
                title: baseVersion.title,
                content: NovelChapterText.appending(selectedText, to: baseVersion.content),
                factCompatibilityID: command.factCompatibilityID,
                sourceChapterVersionID: baseVersion.id,
                sourceCandidateID: candidate.id,
                createdAt: now,
                operationID: command.context.operationID
            )
        case .replaceChapter(let chapterID):
            guard let selection = branch.workingChapterSelections.first(where: {
                $0.chapterID == chapterID
            }), let baseVersion = document.chapterVersions.first(where: {
                $0.id == selection.versionID && $0.chapterID == chapterID
            }) else {
                throw NovelError.invalidInput("The replace target is not in the current manuscript.")
            }
            // 替换只能落到**这个候选自己重写的那一章**。此前该约束只存在于
            // 收录面板,任何绕过 UI 的调用方都能拿一段无关正文整章覆盖。
            guard let sourceVersionID = candidate.sourceChapterVersionID,
                  sourceVersionID == selection.versionID else {
                throw NovelError.invalidInput("The rewritten chapter changed after this candidate was generated.")
            }
            proposedVersion = NovelChapterVersionRecord(
                id: command.proposedChapterVersionID,
                chapterID: chapterID,
                kind: .collected,
                title: baseVersion.title,
                content: selectedText,
                factCompatibilityID: command.factCompatibilityID,
                sourceChapterVersionID: baseVersion.id,
                sourceCandidateID: candidate.id,
                createdAt: now,
                operationID: command.context.operationID
            )
        case .createNextChapter(let chapterID, let title):
            let normalizedTitle = try normalizedRequired(title, field: "Chapter title")
            guard normalizedTitle == title else {
                throw NovelError.invalidInput("Chapter title must not contain surrounding whitespace.")
            }
            guard !document.chapters.contains(where: { $0.id == chapterID }),
                  !document.pendingOperations.contains(where: {
                      if case .createNextChapter(let pendingChapterID, _) = $0.collectionTarget {
                          return pendingChapterID == chapterID
                      }
                      return false
                  }) else {
                throw NovelError.immutableRecordConflict("chapter \(chapterID)")
            }
            proposedVersion = NovelChapterVersionRecord(
                id: command.proposedChapterVersionID,
                chapterID: chapterID,
                kind: .collected,
                title: title,
                content: selectedText,
                factCompatibilityID: command.factCompatibilityID,
                sourceChapterVersionID: nil,
                sourceCandidateID: candidate.id,
                createdAt: now,
                operationID: command.context.operationID
            )
        }

        return NovelPendingOperationRecord(
            id: command.pendingID,
            kind: .collection,
            status: .pending,
            branchID: branch.id,
            operationID: command.context.operationID,
            payloadSHA256: payloadSHA256,
            baseCheckpointID: branch.headCheckpointID,
            baseHeadRevision: branch.headRevision,
            baseWorkingRevision: branch.workingRevision,
            candidateID: candidate.id,
            collectionTarget: command.target,
            selectedText: selectedText,
            proposedChapterVersion: proposedVersion,
            proposedCheckpointID: command.checkpointID,
            proposedStateSnapshotID: command.stateSnapshotID,
            rebuildBaseCheckpointID: nil,
            sessionCursor: .through(sequence: sourceMessage.sequence),
            createdAt: now,
            lastError: nil
        )
    }

    static func collectionExtractionInput(
        pendingID: NovelPendingOperationID,
        in document: NovelProjectDocumentV1
    ) throws -> NovelCollectionExtractionInput {
        let pending = try requirePending(pendingID, kind: .collection, in: document)
        let baseCheckpoint = try checkpoint(pending.baseCheckpointID, in: document)
        let baseState = try stateSnapshot(baseCheckpoint.stateSnapshotID, in: document)
        return NovelCollectionExtractionInput(
            structuredRunID: NovelRunID(pending.id.rawValue),
            pending: pending,
            baseCheckpoint: baseCheckpoint,
            baseStateSnapshot: baseState,
            baseContext: try stateContext(baseState, branchID: pending.branchID, in: document),
            manuscript: pending.selectedText
        )
    }

    static func finalizeCollection(
        pendingID: NovelPendingOperationID,
        delta: NovelStateDeltaV1,
        retryCommand: NovelRetryPendingCommand? = nil,
        artifacts: NovelFactTransactionReceiptArtifacts,
        in document: NovelProjectDocumentV1,
        now: Date = Date(),
        acceptEmptyFacts: Bool = false
    ) throws -> NovelFactTransactionResult {
        let validatedDelta = try validate(delta)
        let pending = try requirePending(pendingID, kind: .collection, in: document)
        try validateRetry(retryCommand, for: pending, in: document)
        return try commitStateDeltaCollection(
            pending: pending,
            validatedDelta: validatedDelta,
            retryCommand: retryCommand,
            artifacts: artifacts,
            in: document,
            now: now,
            acceptEmptyFacts: acceptEmptyFacts,
            consumeChapterPlanID: nil,
            replacementChapterPlan: nil
        )
    }

    private static func commitStateDeltaCollection(
        pending: NovelPendingOperationRecord,
        validatedDelta: NovelStateDeltaV1,
        retryCommand: NovelRetryPendingCommand?,
        artifacts: NovelFactTransactionReceiptArtifacts,
        in document: NovelProjectDocumentV1,
        now: Date,
        acceptEmptyFacts: Bool,
        consumeChapterPlanID: NovelChapterPlanID?,
        replacementChapterPlan: NovelChapterPlanRecord?
    ) throws -> NovelFactTransactionResult {
        var validatedDelta = validatedDelta
        let branchIndex = try requireBranch(pending.branchID, in: document)
        let branch = document.branches[branchIndex]
        try requirePendingGuards(
            pending,
            branch: branch,
            projectID: document.project.id
        )
        guard branch.syncStatus == .synchronized else {
            throw NovelError.invalidInput("Manual edits must be synchronized before collecting prose.")
        }
        guard let candidateIndex = document.candidates.firstIndex(where: {
            $0.id == pending.candidateID
        }) else {
            throw NovelError.invalidInput("The pending collection lost its candidate.")
        }
        let candidate = document.candidates[candidateIndex]
        guard let sessionIndex = document.sessions.firstIndex(where: {
            $0.id == candidate.sessionID && $0.branchID == branch.id
        }) else {
            throw NovelError.invalidInput("The pending collection lost its owning Session.")
        }
        guard candidate.status == .available || candidate.status == .interrupted,
              candidate.collectedCheckpointID == nil,
              NovelCandidateSemantics.collectionBaseMatches(
                  candidate,
                  targetCheckpointID: pending.baseCheckpointID,
                  targetHeadRevision: pending.baseHeadRevision,
                  in: document
              ) else {
            throw NovelError.invalidInput("The pending collection candidate is stale.")
        }
        guard let proposedVersion = pending.proposedChapterVersion,
              let checkpointID = pending.proposedCheckpointID,
              let snapshotID = pending.proposedStateSnapshotID,
              let target = pending.collectionTarget,
              let sessionCursor = pending.sessionCursor else {
            throw NovelError.invalidInput("The pending collection is incomplete.")
        }
        let baseCheckpoint = try checkpoint(pending.baseCheckpointID, in: document)
        let baseState = try stateSnapshot(baseCheckpoint.stateSnapshotID, in: document)
        validatedDelta = try sanitizedCollectionDelta(
            in: validatedDelta,
            evidenceSource: pending.selectedText,
            branch: branch,
            baseState: baseState,
            document: document,
            acceptEmptyFacts: acceptEmptyFacts
        )
        try validateStateFacts(
            validatedDelta,
            evidenceSource: pending.selectedText,
            branch: branch,
            baseState: baseState,
            in: document
        )
        let newEvents = try storyEvents(
            storyEventDrafts(
                validatedDelta,
                evidenceSource: pending.selectedText
            ),
            namespace: pending.operationID,
            baseState: baseState,
            in: document,
            now: now
        )
        let proposals = try settingProposals(
            validatedDelta.settingProposals,
            namespace: pending.operationID,
            branchID: branch.id,
            in: document,
            now: now
        )
        var chapterSelections = branch.workingChapterSelections
        var chapterToAdd: NovelChapterRecord?
        switch target {
        case .appendToChapter(let chapterID), .replaceChapter(let chapterID):
            guard let index = chapterSelections.firstIndex(where: { $0.chapterID == chapterID }),
                  proposedVersion.chapterID == chapterID else {
                throw NovelError.invalidInput("The pending append target is stale.")
            }
            chapterSelections[index] = NovelChapterSelection(
                chapterID: chapterID,
                versionID: proposedVersion.id
            )
        case .createNextChapter(let chapterID, _):
            guard proposedVersion.chapterID == chapterID,
                  !document.chapters.contains(where: { $0.id == chapterID }) else {
                throw NovelError.immutableRecordConflict("chapter \(chapterID)")
            }
            chapterToAdd = NovelChapterRecord(id: chapterID, createdAt: now)
            chapterSelections.append(NovelChapterSelection(
                chapterID: chapterID,
                versionID: proposedVersion.id
            ))
        }

        let liveSelections = chapterSelections.filter { selection in
            document.chapters.first { $0.id == selection.chapterID }?.discardedAt == nil
        }
        let chapterPlots = NovelWorkspaceLedger.relinkChapterPlots(
            existing: baseState.chapterPlots,
            working: liveSelections,
            seeds: NovelWorkspaceLedger.seedTexts(working: liveSelections, in: document),
            updatedChapterID: proposedVersion.chapterID,
            updatedText: NovelWorkspaceLedger.excerpt(
                title: proposedVersion.title,
                content: proposedVersion.content
            ),
            markLaterStale: !NovelWorkspaceLedger.isFastForwardCollect(target, branch: branch)
        )
        let newSnapshot = NovelStateSnapshotRecord(
            id: snapshotID,
            eventIDs: baseState.eventIDs + newEvents.map(\.id),
            summary: validatedDelta.stateSummary,
            branchOutline: validatedDelta.branchOutlinePatch ?? baseState.branchOutline,
            unresolvedEntityNames: validatedDelta.unresolvedEntityNames,
            createdAt: now,
            settingProposalIDs: baseState.settingProposalIDs + proposals.map(\.id),
            characterIdentityClarifications: baseState.characterIdentityClarifications,
            recentWrittenHighlights: NovelStateSnapshotRecord.mergedHighlights(
                prior: baseState.recentWrittenHighlights,
                newEventSummaries: newEvents.map(\.summary)
            ),
            chapterPlots: chapterPlots
        )

        let finalRevision = document.project.revision + 1
        let outcome = NovelOutcome.candidateCollected(
            projectID: document.project.id,
            branchID: branch.id,
            candidateID: candidate.id,
            checkpointID: checkpointID,
            chapterVersionID: proposedVersion.id,
            revision: finalRevision
        )
        let checkpoint = NovelBranchCheckpointRecord(
            id: checkpointID,
            kind: .collection,
            createdOnBranchID: branch.id,
            parentCheckpointID: pending.baseCheckpointID,
            chapterSelections: chapterSelections,
            stateSnapshotID: newSnapshot.id,
            sessionCursor: sessionCursor,
            branchOverrideRevisionIDs: branch.overrideRevisionIDs,
            sourceCandidateID: candidate.id,
            baseHeadRevision: pending.baseHeadRevision,
            operationID: pending.operationID,
            createdAt: now
        )

        var next = document
        if let chapterToAdd { next.chapters.append(chapterToAdd) }
        next.chapterVersions.append(proposedVersion)
        next.events.append(contentsOf: newEvents)
        next.stateSnapshots.append(newSnapshot)
        next.settingProposals.append(contentsOf: proposals)
        try appendLedger(
            pending: pending,
            outcome: outcome,
            retryCommand: retryCommand,
            appliedRevision: finalRevision,
            to: &next,
            now: now
        )
        try appendFactReceipts(
            artifacts,
            pending: pending,
            retryCommand: retryCommand,
            kind: .stateDelta,
            to: &next
        )
        next.candidates[candidateIndex].status = .collected
        next.candidates[candidateIndex].collectedCheckpointID = checkpoint.id
        next.sessions[sessionIndex].revision += 1
        try NovelReducer.appendCheckpoint(
            checkpoint,
            to: &next,
            expectedHeadRevision: pending.baseHeadRevision,
            now: now
        )
        next.pendingOperations.removeAll { $0.id == pending.id }
        if let consumeChapterPlanID {
            guard next.chapterPlans.contains(where: {
                $0.branchID == branch.id && $0.id == consumeChapterPlanID
            }) else {
                throw NovelError.invalidInput("The confirmed chapter plan changed before collection.")
            }
            next.chapterPlans.removeAll {
                $0.branchID == branch.id && $0.id == consumeChapterPlanID
            }
            if let replacementChapterPlan {
                guard replacementChapterPlan.branchID == branch.id,
                      replacementChapterPlan.id != consumeChapterPlanID,
                      replacementChapterPlan.isConfirmed,
                      !next.chapterPlans.contains(where: { $0.branchID == branch.id }) else {
                    throw NovelError.invalidInput("The next chapter plan is invalid.")
                }
                next.chapterPlans.append(replacementChapterPlan)
            }
            next.project.configRevision += 1
        } else if replacementChapterPlan != nil {
            throw NovelError.invalidInput(
                "A replacement chapter plan requires consuming the current plan."
            )
        }
        advanceProjectRevision(in: &next, now: now)
        guard next.project.revision == finalRevision else {
            throw NovelError.invalidInput("Collection revision accounting failed.")
        }
        if consumeChapterPlanID == nil {
            try validateTransition(from: document, to: next)
        } else {
            // The ephemeral pending is not part of the caller's persisted
            // document. Include it only as the transition witness so the
            // existing receipt lifecycle validator can verify this atomic
            // finalization without making the pending Codable/durable.
            var validationBase = document
            validationBase.pendingOperations.append(pending)
            try validateTransition(from: validationBase, to: next)
        }
        return (next, outcome)
    }

    private static func confirmedChapterPlan(
        id: NovelChapterPlanID,
        branchID: NovelBranchID,
        proposal: NovelChapterPlanProposalV1,
        now: Date
    ) throws -> NovelChapterPlanRecord {
        let outlinePlacement = proposal.outlinePlacement.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let goalAndConflict = proposal.goalAndConflict.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let endingHook = proposal.endingHook.trimmingCharacters(in: .whitespacesAndNewlines)
        let mustHappen = NovelChapterPlanRecord.normalizedLines(proposal.mustHappen)
        let mustNotHappen = NovelChapterPlanRecord.normalizedLines(proposal.mustNotHappen)
        let visibleFacts = NovelChapterPlanRecord.normalizedLines(proposal.visibleFacts)
        guard proposal.schemaVersion == NovelChapterPlanProposalV1.currentSchemaVersion,
              outlinePlacement.count <= 500,
              !goalAndConflict.isEmpty,
              goalAndConflict.count <= 8_000,
              endingHook.count <= 4_000,
              !mustHappen.isEmpty,
              mustHappen.count <= 32,
              mustNotHappen.count <= 32,
              visibleFacts.count <= 32 else {
            throw NovelError.invalidInput("The next chapter plan is invalid.")
        }
        var record = NovelChapterPlanRecord(
            id: id,
            branchID: branchID,
            status: .confirmed,
            outlinePlacement: outlinePlacement,
            goalAndConflict: goalAndConflict,
            mustHappen: mustHappen,
            mustNotHappen: mustNotHappen,
            endingHook: endingHook,
            visibleFacts: visibleFacts,
            contentDigest: "",
            updatedAt: now,
            confirmedAt: now
        )
        record.contentDigest = NovelChapterPlanRecord.digest(
            forCanonicalPayload: record.canonicalDigestPayload()
        )
        return record
    }

    static func markRetryable(
        pendingID: NovelPendingOperationID,
        message: String,
        in document: NovelProjectDocumentV1,
        now: Date = Date()
    ) throws -> NovelProjectDocumentV1 {
        let normalizedMessage = try normalizedRequired(message, field: "Retry failure")
        guard let index = document.pendingOperations.firstIndex(where: {
            $0.id == pendingID
        }) else {
            throw NovelError.invalidInput("The pending operation was not found.")
        }
        if document.pendingOperations[index].status == .retryable,
           document.pendingOperations[index].lastError == normalizedMessage {
            return document
        }
        var next = document
        next.pendingOperations[index].status = .retryable
        next.pendingOperations[index].lastError = normalizedMessage
        advanceProjectRevision(in: &next, now: now)
        try validateTransition(from: document, to: next)
        return next
    }

    private struct StateContextPayload: Codable {
        let summary: String
        let branchOutline: String
        let unresolvedEntityNames: [String]
        let characterIdentityClarifications: [NovelCharacterIdentityClarificationRecord]
        let events: [NovelStoryEventRecord]
    }

    static func matchingPending(
        id: NovelPendingOperationID,
        operationID: NovelOperationID,
        kind: NovelPendingOperationKind,
        payloadSHA256: String,
        in document: NovelProjectDocumentV1
    ) throws -> NovelPendingOperationRecord? {
        let byID = document.pendingOperations.first(where: { $0.id == id })
        let byOperation = document.pendingOperations.first(where: {
            $0.operationID == operationID
        })
        guard byID != nil || byOperation != nil else { return nil }
        guard let existing = byID,
              existing == byOperation,
              existing.operationID == operationID,
              existing.kind == kind,
              existing.payloadSHA256 == payloadSHA256 else {
            throw NovelError.idempotencyConflict(operationID)
        }
        return existing
    }

    static func requireUnusedOperation(
        _ operationID: NovelOperationID,
        in document: NovelProjectDocumentV1
    ) throws {
        if document.appliedOperations.contains(where: { $0.operationID == operationID }) ||
            document.factAttempts.contains(where: { $0.attemptOperationID == operationID }) ||
            document.pendingOperations.contains(where: { $0.operationID == operationID }) ||
            document.polishTransactions.contains(where: { $0.operationID == operationID }) {
            throw NovelError.idempotencyConflict(operationID)
        }
    }

    static func requireProject(
        _ projectID: NovelProjectID,
        in document: NovelProjectDocumentV1
    ) throws {
        guard projectID == document.project.id else {
            throw NovelError.projectNotFound(projectID)
        }
    }

    static func requireBranch(
        _ branchID: NovelBranchID,
        in document: NovelProjectDocumentV1
    ) throws -> Int {
        guard let index = document.branches.firstIndex(where: { $0.id == branchID }) else {
            throw NovelError.branchNotFound(branchID)
        }
        return index
    }

    static func requireContext(
        _ context: NovelMutationContext,
        branch: NovelBranchRecord,
        document: NovelProjectDocumentV1
    ) throws {
        guard let expectedProject = context.expectedProjectRevision else {
            throw NovelError.invalidInput("Expected project revision is missing.")
        }
        guard expectedProject == document.project.revision else {
            throw NovelError.staleProjectRevision(
                expected: expectedProject,
                actual: document.project.revision
            )
        }
        if let expectedConfig = context.expectedConfigRevision,
           expectedConfig != document.project.configRevision {
            throw NovelError.staleConfigRevision(
                expected: expectedConfig,
                actual: document.project.configRevision
            )
        }
        guard let expectedHead = context.expectedBranchHeadRevision else {
            throw NovelError.invalidInput("Expected branch head revision is missing.")
        }
        guard expectedHead == branch.headRevision else {
            throw NovelError.staleBranchHeadRevision(
                expected: expectedHead,
                actual: branch.headRevision
            )
        }
    }

    static func requirePending(
        _ pendingID: NovelPendingOperationID,
        kind: NovelPendingOperationKind,
        in document: NovelProjectDocumentV1
    ) throws -> NovelPendingOperationRecord {
        guard let pending = document.pendingOperations.first(where: {
            $0.id == pendingID && $0.kind == kind
        }) else {
            throw NovelError.invalidInput("The pending fact transaction was not found.")
        }
        return pending
    }

    static func requirePendingGuards(
        _ pending: NovelPendingOperationRecord,
        branch: NovelBranchRecord,
        projectID: NovelProjectID
    ) throws {
        guard branch.lifecycle == .active else {
            throw NovelError.branchNotFound(branch.id)
        }
        guard branch.activeRunID == nil else {
            throw NovelError.projectBusy(projectID)
        }
        guard branch.headCheckpointID == pending.baseCheckpointID,
              branch.headRevision == pending.baseHeadRevision else {
            throw NovelError.staleBranchHeadRevision(
                expected: pending.baseHeadRevision,
                actual: branch.headRevision
            )
        }
        guard branch.workingRevision == pending.baseWorkingRevision else {
            throw NovelError.invalidInput(
                "The working manuscript changed while fact synchronization was pending."
            )
        }
    }

    static func requirePayloadHash(_ payloadSHA256: String) throws {
        guard NovelDocumentValidator.isSHA256(payloadSHA256) else {
            throw NovelError.invalidInput("The fact transaction payload hash is invalid.")
        }
    }

    static func requireReservedIDs(
        chapterVersionID: NovelChapterVersionID?,
        checkpointID: NovelCheckpointID,
        stateSnapshotID: NovelStateSnapshotID,
        pendingID: NovelPendingOperationID,
        in document: NovelProjectDocumentV1
    ) throws {
        let completedPendingIDs = Set(document.injectionReceipts.compactMap {
            $0.factTransaction?.pendingID
        })
        guard document.pendingOperations.allSatisfy({ $0.id != pendingID }),
              !completedPendingIDs.contains(pendingID) else {
            throw NovelError.immutableRecordConflict("pending operation \(pendingID)")
        }
        if let chapterVersionID {
            guard document.chapterVersions.allSatisfy({ $0.id != chapterVersionID }),
                  document.pendingOperations.allSatisfy({
                      $0.proposedChapterVersion?.id != chapterVersionID
                  }) else {
                throw NovelError.immutableRecordConflict("chapter version \(chapterVersionID)")
            }
        }
        guard document.checkpoints.allSatisfy({ $0.id != checkpointID }),
              document.pendingOperations.allSatisfy({
                  $0.proposedCheckpointID != checkpointID
              }) else {
            throw NovelError.immutableRecordConflict("checkpoint \(checkpointID)")
        }
        guard document.stateSnapshots.allSatisfy({ $0.id != stateSnapshotID }),
              document.pendingOperations.allSatisfy({
                  $0.proposedStateSnapshotID != stateSnapshotID
              }) else {
            throw NovelError.immutableRecordConflict("state snapshot \(stateSnapshotID)")
        }
    }

    static func requireNewFactCompatibilityID(
        _ id: UUID,
        in document: NovelProjectDocumentV1
    ) throws {
        guard id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
              document.chapterVersions.allSatisfy({ $0.factCompatibilityID != id }),
              document.pendingOperations.allSatisfy({
                  $0.proposedChapterVersion?.factCompatibilityID != id
              }) else {
            throw NovelError.invalidInput("A fact compatibility ID must identify a new fact lineage.")
        }
    }

    static func validateRetry(
        _ command: NovelRetryPendingCommand?,
        for pending: NovelPendingOperationRecord,
        in document: NovelProjectDocumentV1
    ) throws {
        switch (pending.status, command) {
        case (.pending, nil):
            return
        case (.pending, .some(let command)), (.retryable, .some(let command)):
            guard command.projectID == document.project.id,
                  command.pendingID == pending.id,
                  command.context.operationID != pending.operationID else {
                throw NovelError.invalidInput("The retry command does not match its pending operation.")
            }
            let hash = try command.canonicalPayloadSHA256()
            try requirePayloadHash(hash)
            let expectedKind: NovelFactReceiptKind = pending.kind == .collection
                ? .stateDelta
                : .manualRebuild
            if let attempt = document.factAttempts.first(where: {
                $0.attemptOperationID == command.context.operationID
            }) {
                guard attempt.pendingID == pending.id,
                      attempt.ownerOperationID == pending.operationID,
                      attempt.attemptPayloadSHA256 == hash,
                      attempt.branchID == pending.branchID,
                      attempt.kind == expectedKind else {
                    throw NovelError.idempotencyConflict(command.context.operationID)
                }
                return
            }
            try requireUnusedOperation(command.context.operationID, in: document)
            guard let expectedProject = command.context.expectedProjectRevision else {
                throw NovelError.invalidInput("Expected project revision is missing for retry.")
            }
            guard expectedProject == document.project.revision else {
                throw NovelError.staleProjectRevision(
                    expected: expectedProject,
                    actual: document.project.revision
                )
            }
            if let expectedConfig = command.context.expectedConfigRevision,
               expectedConfig != document.project.configRevision {
                throw NovelError.staleConfigRevision(
                    expected: expectedConfig,
                    actual: document.project.configRevision
                )
            }
            let branchIndex = try requireBranch(pending.branchID, in: document)
            if let expectedHead = command.context.expectedBranchHeadRevision,
               expectedHead != document.branches[branchIndex].headRevision {
                throw NovelError.staleBranchHeadRevision(
                    expected: expectedHead,
                    actual: document.branches[branchIndex].headRevision
                )
            }
        case (.retryable, nil):
            throw NovelError.invalidInput("Retry ownership does not match the pending status.")
        }
    }

    static func validateDurableAttempt(
        _ attempt: NovelFactTransactionAttempt,
        for pending: NovelPendingOperationRecord,
        in document: NovelProjectDocumentV1
    ) throws {
        if attempt.operationID == pending.operationID {
            guard attempt.payloadSHA256 == pending.payloadSHA256 else {
                throw NovelError.idempotencyConflict(attempt.operationID)
            }
            return
        }
        guard document.factAttempts.contains(where: {
            $0.pendingID == pending.id &&
                $0.ownerOperationID == pending.operationID &&
                $0.attemptOperationID == attempt.operationID &&
                $0.attemptPayloadSHA256 == attempt.payloadSHA256 &&
                $0.branchID == pending.branchID &&
                $0.kind == .manualRebuild
        }) else {
            throw NovelError.invalidInput("The retry attempt has no durable manual-sync progress.")
        }
    }

    static func appendLedger(
        pending: NovelPendingOperationRecord,
        outcome: NovelOutcome,
        retryCommand: NovelRetryPendingCommand?,
        appliedRevision: Int64,
        to document: inout NovelProjectDocumentV1,
        now: Date
    ) throws {
        let originalKind: NovelOperationKind = pending.kind == .collection
            ? .collectCandidate
            : .syncManualEdits
        document.appliedOperations.append(NovelAppliedOperationRecord(
            operationID: pending.operationID,
            kind: originalKind,
            payloadSHA256: pending.payloadSHA256,
            outcome: outcome,
            appliedProjectRevision: appliedRevision,
            appliedAt: now
        ))
        if let retryCommand {
            document.appliedOperations.append(NovelAppliedOperationRecord(
                operationID: retryCommand.context.operationID,
                kind: .retryPending,
                payloadSHA256: try retryCommand.canonicalPayloadSHA256(),
                outcome: outcome,
                appliedProjectRevision: appliedRevision,
                appliedAt: now
            ))
        }
    }

    static func appendLedger(
        pending: NovelPendingOperationRecord,
        outcome: NovelOutcome,
        attempt: NovelFactTransactionAttempt,
        appliedRevision: Int64,
        to document: inout NovelProjectDocumentV1,
        now: Date
    ) throws {
        let originalKind: NovelOperationKind = pending.kind == .collection
            ? .collectCandidate
            : .syncManualEdits
        document.appliedOperations.append(NovelAppliedOperationRecord(
            operationID: pending.operationID,
            kind: originalKind,
            payloadSHA256: pending.payloadSHA256,
            outcome: outcome,
            appliedProjectRevision: appliedRevision,
            appliedAt: now
        ))
        guard attempt.operationID != pending.operationID else { return }
        document.appliedOperations.append(NovelAppliedOperationRecord(
            operationID: attempt.operationID,
            kind: .retryPending,
            payloadSHA256: attempt.payloadSHA256,
            outcome: outcome,
            appliedProjectRevision: appliedRevision,
            appliedAt: now
        ))
    }

    static func appendFactReceipts(
        _ artifacts: NovelFactTransactionReceiptArtifacts,
        pending: NovelPendingOperationRecord,
        retryCommand: NovelRetryPendingCommand?,
        kind: NovelFactReceiptKind,
        to document: inout NovelProjectDocumentV1
    ) throws {
        let injection = artifacts.injectionReceipt
        let generation = artifacts.generationReceipt
        let expectedLink = NovelFactReceiptLink(
            pendingID: pending.id,
            ownerOperationID: pending.operationID,
            attemptOperationID: retryCommand?.context.operationID ?? pending.operationID,
            attemptPayloadSHA256: try retryCommand?.canonicalPayloadSHA256() ??
                pending.payloadSHA256,
            kind: kind,
            chunkIndex: injection.factTransaction?.chunkIndex
        )
        guard injection.projectID == document.project.id,
              injection.branchID == pending.branchID,
              injection.runID == generation.runID,
              injection.factTransaction == expectedLink,
              generation.factTransaction == expectedLink,
              generation.injectionReceiptID == injection.id else {
            throw NovelError.invalidInput("Fact-model receipts do not match the pending attempt.")
        }

        let existingInjection = document.injectionReceipts.first(where: {
            $0.id == injection.id
        })
        let existingGeneration = document.generationReceipts.first(where: {
            $0.id == generation.id
        })
        if existingInjection != nil || existingGeneration != nil {
            guard existingInjection == injection,
                  existingGeneration == generation else {
                throw NovelError.immutableRecordConflict("fact-model receipt identity")
            }
            return
        }

        let existingReceiptIDs = Set(document.injectionReceipts.map(\.id))
            .union(document.generationReceipts.map(\.id))
        guard injection.id != generation.id,
              !existingReceiptIDs.contains(injection.id),
              !existingReceiptIDs.contains(generation.id),
              !document.injectionReceipts.contains(where: { $0.runID == injection.runID }),
              !document.generationReceipts.contains(where: { $0.runID == generation.runID }) else {
            throw NovelError.immutableRecordConflict("fact-model receipt identity")
        }

        document.injectionReceipts.append(injection)
        document.generationReceipts.append(generation)
    }

    static func advanceProjectRevision(
        in document: inout NovelProjectDocumentV1,
        now: Date
    ) {
        document.project.revision += 1
        document.project.updatedAt = now
    }

    static func checkpoint(
        _ id: NovelCheckpointID,
        in document: NovelProjectDocumentV1
    ) throws -> NovelBranchCheckpointRecord {
        guard let checkpoint = document.checkpoints.first(where: { $0.id == id }) else {
            throw NovelError.checkpointNotFound(id)
        }
        return checkpoint
    }

    static func stateSnapshot(
        _ id: NovelStateSnapshotID,
        in document: NovelProjectDocumentV1
    ) throws -> NovelStateSnapshotRecord {
        guard let snapshot = document.stateSnapshots.first(where: { $0.id == id }) else {
            throw NovelError.stateSnapshotNotFound(id)
        }
        return snapshot
    }

    static func stateContext(
        _ snapshot: NovelStateSnapshotRecord,
        branchID: NovelBranchID,
        in document: NovelProjectDocumentV1
    ) throws -> String {
        let branchIndex = try requireBranch(branchID, in: document)
        let snapshot = try effectiveStateSnapshot(
            snapshot,
            branch: document.branches[branchIndex],
            document: document
        )
        var events: [NovelStoryEventRecord] = []
        for eventID in snapshot.eventIDs {
            guard let event = document.events.first(where: { $0.id == eventID }) else {
                throw NovelError.invalidInput("The base state references a missing event.")
            }
            events.append(event)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(StateContextPayload(
            summary: snapshot.summary,
            branchOutline: snapshot.branchOutline,
            unresolvedEntityNames: snapshot.unresolvedEntityNames,
            characterIdentityClarifications: snapshot.characterIdentityClarifications,
            events: events
        ))
        guard let value = String(data: data, encoding: .utf8) else {
            throw NovelError.invalidInput("The state context is not UTF-8.")
        }
        return value
    }

    static func normalizedRequired(_ value: String, field: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw NovelError.invalidInput("\(field) cannot be empty.")
        }
        return normalized
    }

    static func validateTransition(
        from current: NovelProjectDocumentV1,
        to next: NovelProjectDocumentV1
    ) throws {
        try NovelDocumentValidator.validateTransition(from: current, to: next)
    }
}
