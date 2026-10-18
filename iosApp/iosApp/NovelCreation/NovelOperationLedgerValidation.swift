import Foundation

enum NovelOperationLedgerValidation {
    static func validateOperationLedger(
        _ document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        let createOperations = document.appliedOperations.filter { $0.kind == .createProject }
        if createOperations.count != 1 || document.appliedOperations.first?.kind != .createProject {
            issues.append("Operation ledger must begin with exactly one project creation.")
        }
        for pair in zip(document.appliedOperations, document.appliedOperations.dropFirst())
        where pair.0.appliedProjectRevision > pair.1.appliedProjectRevision {
            issues.append("Operation ledger revisions are not monotonic.")
        }
        for operation in document.appliedOperations {
            if !NovelDocumentValidator.isSHA256(operation.payloadSHA256) {
                issues.append("Operation \(operation.operationID) has an invalid payload hash.")
            }
            if operation.appliedProjectRevision < 1 ||
                operation.appliedProjectRevision > document.project.revision {
                issues.append("Operation \(operation.operationID) has an invalid applied revision.")
            }
            if operation.outcome.projectID != document.project.id {
                issues.append("Operation \(operation.operationID) outcome belongs to another project.")
            }
            switch (operation.kind, operation.outcome) {
            case let (.createProject, .projectCreated(projectID, branchID)):
                if projectID != document.project.id ||
                    operation.appliedProjectRevision != 1 ||
                    !document.branches.contains(where: { $0.id == branchID }) {
                    issues.append("Project creation operation \(operation.operationID) has invalid outcome data.")
                }
            case let (.renameProject, .projectRenamed(_, revision)):
                if revision != operation.appliedProjectRevision {
                    issues.append("Project rename operation \(operation.operationID) has an invalid revision.")
                }
            case let (
                .reviseMaterial,
                .materialRevised(_, materialID, revisionID, projectRevision, configRevision)
            ):
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision ||
                    !document.materialRevisions.contains(where: {
                        $0.id == revisionID &&
                            $0.materialID == materialID &&
                            $0.operationID == operation.operationID
                    }) {
                    issues.append("Material operation \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .deleteMaterial,
                .materialDeleted(_, materialID, projectRevision, configRevision)
            ):
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision ||
                    !document.materials.contains(where: {
                        $0.id == materialID && $0.isDeleted
                    }) {
                    issues.append("Material deletion \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .setModelPolicy,
                .modelPolicyChanged(_, projectRevision, configRevision)
            ):
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision {
                    issues.append("Model-policy operation \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .resolveSettingProposal,
                .settingProposalAccepted(
                    _, proposalID, materialID, revisionID, projectRevision, configRevision
                )
            ):
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision ||
                    !document.settingProposals.contains(where: {
                        $0.id == proposalID && $0.isResolved
                    }) ||
                    !document.materialRevisions.contains(where: {
                        $0.id == revisionID &&
                            $0.materialID == materialID &&
                            $0.operationID == operation.operationID
                    }) {
                    issues.append("Proposal acceptance \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .resolveSettingProposal,
                .settingProposalRejected(_, proposalID, projectRevision, configRevision)
            ):
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision ||
                    !document.settingProposals.contains(where: {
                        $0.id == proposalID && $0.isResolved
                    }) {
                    issues.append("Proposal rejection \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .setBranchMaterialOverride,
                .branchMaterialOverrideChanged(
                    _, branchID, materialID, revisionID, projectRevision, configRevision
                )
            ):
                let selectedRevision = revisionID.flatMap { selectedID in
                    document.materialRevisions.first(where: {
                        $0.id == selectedID && $0.materialID == materialID
                    })
                }
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision ||
                    !document.branches.contains(where: { $0.id == branchID }) ||
                    (revisionID != nil && selectedRevision == nil) {
                    issues.append("Branch override \(operation.operationID) has invalid outcome data.")
                }
            case let (.setMainBranch, .mainBranchChanged(_, branchID, revision)):
                if revision != operation.appliedProjectRevision ||
                    !document.branches.contains(where: { $0.id == branchID }) {
                    issues.append("Main-branch operation \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .setPolishPreference,
                .polishPreferenceChanged(_, projectRevision, configRevision)
            ):
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision {
                    issues.append(
                        "Polish-preference operation \(operation.operationID) has invalid outcome data."
                    )
                }
            case let (
                .setCollaborationMode,
                .collaborationModeChanged(_, _, projectRevision, configRevision)
            ):
                // Mode is mutable; older ledger rows must not assert against the current mode.
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision {
                    issues.append(
                        "Collaboration-mode operation \(operation.operationID) has invalid outcome data."
                    )
                }
            case let (
                .setPauseGhostwriteOnBlockingContinuity,
                .pauseGhostwriteOnBlockingContinuityChanged(_, _, projectRevision, configRevision)
            ):
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision {
                    issues.append(
                        "Ghostwrite continuity-pause operation \(operation.operationID) has invalid outcome data."
                    )
                }
            case let (
                .upsertChapterPlan,
                .chapterPlanUpserted(
                    _, branchID, _, _, contentDigest, projectRevision, configRevision
                )
            ):
                // Plans are mutable replace-in-place, so older upsert outcomes are historical
                // ledger rows and need not equal the current plan status/digest.
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision ||
                    !document.branches.contains(where: { $0.id == branchID }) ||
                    contentDigest.count != 64 {
                    issues.append(
                        "Chapter-plan upsert \(operation.operationID) has invalid outcome data."
                    )
                }
            case let (
                .clearChapterPlan,
                .chapterPlanCleared(_, branchID, projectRevision, configRevision)
            ):
                // Clear is historical; a later upsert may recreate a plan on the same branch.
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision ||
                    !document.branches.contains(where: { $0.id == branchID }) {
                    issues.append(
                        "Chapter-plan clear \(operation.operationID) has invalid outcome data."
                    )
                }
            case let (
                .upsertUpcomingArc,
                .upcomingArcUpserted(_, branchID, beatCount, projectRevision, configRevision)
            ):
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision ||
                    beatCount < 1 ||
                    !document.branches.contains(where: { $0.id == branchID }) {
                    issues.append(
                        "Upcoming-arc upsert \(operation.operationID) has invalid outcome data."
                    )
                }
            case let (
                .clearUpcomingArc,
                .upcomingArcCleared(_, branchID, projectRevision, configRevision)
            ):
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision ||
                    !document.branches.contains(where: { $0.id == branchID }) {
                    issues.append(
                        "Upcoming-arc clear \(operation.operationID) has invalid outcome data."
                    )
                }
            case let (
                .clarifyCharacterIdentity,
                .characterIdentityClarified(
                    _, branchID, mention, checkpointID, stateSnapshotID, revision
                )
            ):
                let checkpoint = document.checkpoints.first(where: {
                    $0.id == checkpointID &&
                        $0.createdOnBranchID == branchID &&
                        $0.kind == .identityClarification &&
                        $0.stateSnapshotID == stateSnapshotID &&
                        $0.operationID == operation.operationID
                })
                let clarification = document.stateSnapshots
                    .first(where: { $0.id == stateSnapshotID })?
                    .characterIdentityClarifications
                    .first(where: { $0.operationID == operation.operationID })
                if revision != operation.appliedProjectRevision ||
                    checkpoint == nil || clarification?.mention != mention {
                    issues.append(
                        "Character identity clarification \(operation.operationID) has invalid outcome data."
                    )
                }
            case let (
                .forkBranch,
                .branchForked(_, sourceBranchID, branchID, checkpointID, revision)
            ):
                if revision != operation.appliedProjectRevision ||
                    !document.branches.contains(where: {
                        $0.id == branchID &&
                            $0.forkOrigin == NovelForkOrigin(
                                parentBranchID: sourceBranchID,
                                checkpointID: checkpointID
                            )
                    }) {
                    issues.append("Fork operation \(operation.operationID) has invalid outcome data.")
                }
            case let (.renameBranch, .branchRenamed(_, branchID, revision)):
                if revision != operation.appliedProjectRevision ||
                    !document.branches.contains(where: { $0.id == branchID }) {
                    issues.append("Branch rename operation \(operation.operationID) has invalid outcome data.")
                }
            case let (.deleteBranch, .branchDeleted(_, branchID, revision)):
                if revision != operation.appliedProjectRevision ||
                    !document.branches.contains(where: {
                        $0.id == branchID && $0.lifecycle == .deleted
                    }) {
                    issues.append("Branch deletion operation \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .undoBranchHead,
                .branchHeadMoved(
                    _, branchID, fromCheckpointID, toCheckpointID, headRevision, revision
                )
            ):
                let from = document.checkpoints.first(where: { $0.id == fromCheckpointID })
                let branch = document.branches.first(where: { $0.id == branchID })
                let directParent = from.flatMap { checkpoint in
                    checkpoint.parentCheckpointID.flatMap { parentID in
                        document.checkpoints.first(where: { $0.id == parentID })
                    }
                }
                let expectedTarget = from.flatMap { checkpoint in
                    branch.flatMap {
                        NovelBranchSemantics.undoTarget(
                            for: checkpoint,
                            branch: $0,
                            checkpoints: document.checkpoints
                        )
                    }
                }
                let validTargetIDs = Set([directParent?.id, expectedTarget?.id].compactMap { $0 })
                if revision != operation.appliedProjectRevision ||
                    !validTargetIDs.contains(toCheckpointID) ||
                    (branch?.headRevision ?? -1) < headRevision {
                    issues.append("Branch undo operation \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .archiveDiscussion,
                .discussionArchived(
                    _, branchID, archiveID, checkpointID, decisionRevisionIDs,
                    projectRevision, configRevision
                )
            ):
                let archiveExists = document.sessions.contains { session in
                    session.branchID == branchID &&
                        (session.discussionArchives ?? []).contains {
                            $0.id == archiveID && $0.checkpointID == checkpointID
                        }
                }
                let decisionsExist = decisionRevisionIDs.allSatisfy { revisionID in
                    guard let revision = document.materialRevisions.first(where: {
                        $0.id == revisionID && $0.operationID == operation.operationID
                    }) else { return false }
                    return document.materials.contains {
                        $0.id == revision.materialID && $0.kind == .decisionLog
                    }
                }
                if projectRevision != operation.appliedProjectRevision ||
                    configRevision < 1 ||
                    configRevision > document.project.configRevision ||
                    decisionRevisionIDs.isEmpty ||
                    !archiveExists ||
                    !decisionsExist ||
                    !document.checkpoints.contains(where: {
                        $0.id == checkpointID &&
                            $0.kind == .discussionArchive &&
                            $0.createdOnBranchID == branchID &&
                            $0.operationID == operation.operationID
                    }) {
                    issues.append("Discussion archive \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .cloneCandidate,
                .candidateCloned(_, branchID, sourceCandidateID, candidateID, revision)
            ):
                if revision != operation.appliedProjectRevision ||
                    !document.candidates.contains(where: {
                        $0.id == candidateID &&
                            $0.branchID == branchID &&
                            $0.clonedFromCandidateID == sourceCandidateID
                    }) {
                    issues.append("Candidate clone operation \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .adoptPolishCandidate,
                .polishCandidateAdopted(
                    _, branchID, candidateID, checkpointID, chapterVersionID, revision
                )
            ):
                let transaction = document.polishTransactions.first(where: {
                    $0.operationID == operation.operationID &&
                        $0.candidateID == candidateID &&
                        $0.checkpointID == checkpointID &&
                        $0.proposedChapterVersionID == chapterVersionID &&
                        $0.status == .completed
                })
                if revision != operation.appliedProjectRevision ||
                    transaction?.branchID != branchID ||
                    !document.checkpoints.contains(where: {
                        $0.id == checkpointID &&
                            $0.kind == .polish &&
                            $0.operationID == operation.operationID
                    }) ||
                    !document.chapterVersions.contains(where: {
                        $0.id == chapterVersionID &&
                            $0.kind == .polish &&
                            $0.operationID == operation.operationID
                    }) {
                    issues.append("Polish adoption \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .adoptPolishCandidate,
                .polishCandidateRejected(_, branchID, candidateID, transactionID, revision)
            ):
                if revision != operation.appliedProjectRevision ||
                    !document.polishTransactions.contains(where: {
                        $0.id == transactionID &&
                            $0.operationID == operation.operationID &&
                            $0.branchID == branchID &&
                            $0.candidateID == candidateID &&
                            $0.status == .incompatible
                    }) {
                    issues.append("Polish rejection \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .abandonPolishTransaction,
                .polishTransactionAbandoned(
                    _, branchID, candidateID, transactionID, revision
                )
            ):
                if revision != operation.appliedProjectRevision ||
                    !document.polishTransactions.contains(where: {
                        $0.id == transactionID &&
                            $0.branchID == branchID &&
                            $0.candidateID == candidateID &&
                            $0.status == .abandoned
                    }) ||
                    !document.candidates.contains(where: {
                        $0.id == candidateID &&
                            $0.branchID == branchID &&
                            $0.status == .superseded
                    }) {
                    issues.append("Polish abandonment \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .restoreChapterVersion,
                .chapterVersionRestored(_, branchID, checkpointID, chapterVersionID, revision)
            ):
                if revision != operation.appliedProjectRevision ||
                    !document.checkpoints.contains(where: {
                        $0.id == checkpointID &&
                            $0.kind == .restore &&
                            $0.createdOnBranchID == branchID &&
                            $0.operationID == operation.operationID
                    }) ||
                    !document.chapterVersions.contains(where: {
                        $0.id == chapterVersionID &&
                            $0.kind == .restore &&
                            $0.operationID == operation.operationID
                    }) {
                    issues.append("Chapter restore \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .discardChapter,
                .chapterDiscardStateChanged(_, branchID, chapterID, isDiscarded, revision)
            ):
                if !isDiscarded ||
                    revision != operation.appliedProjectRevision ||
                    !document.branches.contains(where: { $0.id == branchID }) ||
                    !document.chapters.contains(where: { $0.id == chapterID }) {
                    issues.append("Chapter discard \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .restoreChapter,
                .chapterDiscardStateChanged(_, branchID, chapterID, isDiscarded, revision)
            ):
                if isDiscarded ||
                    revision != operation.appliedProjectRevision ||
                    !document.branches.contains(where: { $0.id == branchID }) ||
                    !document.chapters.contains(where: { $0.id == chapterID }) {
                    issues.append("Chapter restoration \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .deleteChapterFromManuscript,
                .chapterRemovedFromManuscript(
                    _, branchID, chapterID, workingRevision, revision
                )
            ):
                // A later undo may select the chapter again; historical deletion
                // does not require either permanent absence or a global discard.
                if revision != operation.appliedProjectRevision ||
                    workingRevision < 1 ||
                    !document.branches.contains(where: {
                        $0.id == branchID &&
                            $0.workingRevision >= workingRevision &&
                            ($0.workingRevision > workingRevision ||
                                !$0.workingChapterSelections.contains(where: {
                                    $0.chapterID == chapterID
                                }))
                    }) ||
                    !document.chapters.contains(where: { $0.id == chapterID }) {
                    issues.append(
                        "Chapter manuscript-delete \(operation.operationID) has invalid outcome data."
                    )
                }
            case let (.startRun, .runStarted(_, branchID, runID, receiptID, revision)):
                if revision != operation.appliedProjectRevision ||
                    !document.activeRuns.contains(where: {
                        $0.id == runID &&
                            $0.branchID == branchID &&
                            $0.receiptID == receiptID &&
                            $0.operationID == operation.operationID
                    }) {
                    issues.append("Run-start operation \(operation.operationID) has invalid outcome data.")
                }
            case let (.cancelRun, .runInterrupted(_, runID, reason, revision)):
                if revision != operation.appliedProjectRevision ||
                    !document.activeRuns.contains(where: {
                        $0.id == runID &&
                            $0.status == .interrupted &&
                            $0.interruptionReason == reason
                }) {
                    issues.append("Run-cancel operation \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .collectCandidate,
                .candidateCollected(_, branchID, candidateID, checkpointID, chapterVersionID, revision)
            ):
                validateCollectionOutcome(
                    operation: operation,
                    branchID: branchID,
                    candidateID: candidateID,
                    checkpointID: checkpointID,
                    chapterVersionID: chapterVersionID,
                    revision: revision,
                    requiresMatchingOperationID: true,
                    document: document,
                    issues: &issues
                )
            case let (
                .saveManualEdit,
                .manualEditSaved(_, branchID, chapterVersionID, workingRevision, revision)
            ):
                if revision != operation.appliedProjectRevision ||
                    workingRevision < 1 ||
                    !document.branches.contains(where: {
                        $0.id == branchID && $0.workingRevision >= workingRevision
                    }) ||
                    !document.chapterVersions.contains(where: {
                        $0.id == chapterVersionID &&
                            $0.kind == .manualEdit &&
                            $0.operationID == operation.operationID
                    }) {
                    issues.append("Manual-edit operation \(operation.operationID) has invalid outcome data.")
                }
            case let (
                .syncManualEdits,
                .manualSyncCommitted(_, branchID, checkpointID, revision)
            ):
                validateManualSyncOutcome(
                    operation: operation,
                    branchID: branchID,
                    checkpointID: checkpointID,
                    revision: revision,
                    requiresMatchingOperationID: true,
                    document: document,
                    issues: &issues
                )
            case let (
                .retryPending,
                .candidateCollected(_, branchID, candidateID, checkpointID, chapterVersionID, revision)
            ):
                validateCollectionOutcome(
                    operation: operation,
                    branchID: branchID,
                    candidateID: candidateID,
                    checkpointID: checkpointID,
                    chapterVersionID: chapterVersionID,
                    revision: revision,
                    requiresMatchingOperationID: false,
                    document: document,
                    issues: &issues
                )
            case let (
                .retryPending,
                .manualSyncCommitted(_, branchID, checkpointID, revision)
            ):
                validateManualSyncOutcome(
                    operation: operation,
                    branchID: branchID,
                    checkpointID: checkpointID,
                    revision: revision,
                    requiresMatchingOperationID: false,
                    document: document,
                    issues: &issues
                )
            case let (
                .workspacePlot,
                .workspacePlotCommitted(_, branchID, checkpointID, revision)
            ):
                validateManualSyncOutcome(
                    operation: operation,
                    branchID: branchID,
                    checkpointID: checkpointID,
                    revision: revision,
                    requiresMatchingOperationID: true,
                    document: document,
                    issues: &issues
                )
            default:
                issues.append("Operation \(operation.operationID) kind does not match its outcome.")
            }
        }
        validateBranchOperationOrder(document, issues: &issues)
        validateLatestBranchOverrides(document, issues: &issues)
    }

    private static func validateLatestBranchOverrides(
        _ document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        struct Key: Hashable {
            let branchID: NovelBranchID
            let materialID: NovelMaterialID
        }
        var latest: [Key: NovelMaterialRevisionID?] = [:]
        for operation in document.appliedOperations {
            guard operation.kind == .setBranchMaterialOverride,
                  case let .branchMaterialOverrideChanged(
                      _, branchID, materialID, revisionID, _, _
                  ) = operation.outcome else {
                continue
            }
            latest[Key(branchID: branchID, materialID: materialID)] = .some(revisionID)
        }
        for (key, expectedRevisionID) in latest {
            guard let branch = document.branches.first(where: { $0.id == key.branchID }) else {
                continue
            }
            let actual = branch.overrideRevisionIDs.filter { revisionID in
                document.materialRevisions.contains(where: {
                    $0.id == revisionID && $0.materialID == key.materialID
                })
            }
            let expected = expectedRevisionID.map { [$0] } ?? []
            if actual != expected {
                issues.append(
                    "Branch \(key.branchID) does not match its latest override operation for material \(key.materialID)."
                )
            }
        }
    }

    private static func validateBranchOperationOrder(
        _ document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        let operationIndex = Dictionary(
            document.appliedOperations.enumerated().map {
                ($0.element.operationID, $0.offset)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var createdCountByOperationID: [NovelOperationID: Int] = [:]
        for checkpoint in document.checkpoints where checkpoint.kind != .initial {
            createdCountByOperationID[checkpoint.operationID, default: 0] += 1
        }
        for operation in document.appliedOperations {
            if createdCountByOperationID[operation.operationID, default: 0] > 1 {
                issues.append("Operation \(operation.operationID) creates multiple checkpoints.")
            }
        }

        for branch in document.branches {
            guard let origin = branch.forkOrigin else { continue }
            let forkOwners = document.appliedOperations.enumerated().filter { _, operation in
                guard operation.kind == .forkBranch,
                      case let .branchForked(
                          _, sourceBranchID, branchID, checkpointID, _
                      ) = operation.outcome else {
                    return false
                }
                return sourceBranchID == origin.parentBranchID &&
                    branchID == branch.id &&
                    checkpointID == origin.checkpointID
            }
            guard let forkIndex = forkOwners.first?.offset else { continue }
            if let originCheckpoint = document.checkpoints.first(where: {
                $0.id == origin.checkpointID
            }), let originOwnerIndex = operationIndex[originCheckpoint.operationID],
               forkIndex <= originOwnerIndex {
                issues.append("Branch \(branch.id) forks before its origin checkpoint exists.")
            }
            if let parent = document.branches.first(where: { $0.id == origin.parentBranchID }),
               let parentOrigin = parent.forkOrigin {
                let parentForkIndex = document.appliedOperations.firstIndex { operation in
                    guard operation.kind == .forkBranch,
                          case let .branchForked(_, _, branchID, checkpointID, _) = operation.outcome else {
                        return false
                    }
                    return branchID == parent.id && checkpointID == parentOrigin.checkpointID
                }
                if let parentForkIndex, forkIndex <= parentForkIndex {
                    issues.append("Branch \(branch.id) forks before its parent branch exists.")
                }
            }
            let parentDeleteIndex = document.appliedOperations.firstIndex { operation in
                guard operation.kind == .deleteBranch,
                      case let .branchDeleted(_, branchID, _) = operation.outcome else {
                    return false
                }
                return branchID == origin.parentBranchID
            }
            if let parentDeleteIndex, forkIndex >= parentDeleteIndex {
                issues.append("Branch \(branch.id) forks after its parent was deleted.")
            }

            for (index, operation) in document.appliedOperations.enumerated()
            where operation.kind != .forkBranch && operation.outcome.targetBranchID == branch.id {
                if index <= forkIndex {
                    issues.append("Branch \(branch.id) has an operation before its fork operation.")
                }
            }

            for checkpoint in document.checkpoints where
                checkpoint.kind != .initial && checkpoint.createdOnBranchID == branch.id {
                if let ownerIndex = operationIndex[checkpoint.operationID], ownerIndex <= forkIndex {
                    issues.append("Branch \(branch.id) has a checkpoint before its fork operation.")
                }
            }
            for (index, operation) in document.appliedOperations.enumerated() {
                guard operation.kind == .undoBranchHead,
                      case let .branchHeadMoved(_, branchID, _, _, _, _) = operation.outcome,
                      branchID == branch.id else {
                    continue
                }
                if index <= forkIndex {
                    issues.append("Branch \(branch.id) has an undo before its fork operation.")
                }
            }
        }
    }

    private static func validateCollectionOutcome(
        operation: NovelAppliedOperationRecord,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID,
        checkpointID: NovelCheckpointID,
        chapterVersionID: NovelChapterVersionID,
        revision: Int64,
        requiresMatchingOperationID: Bool,
        document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        let checkpoint = document.checkpoints.first(where: { $0.id == checkpointID })
        let candidate = document.candidates.first(where: { $0.id == candidateID })
        let version = document.chapterVersions.first(where: { $0.id == chapterVersionID })
        let operationMatches = !requiresMatchingOperationID ||
            (checkpoint?.operationID == operation.operationID &&
                version?.operationID == operation.operationID)
        if revision != operation.appliedProjectRevision ||
            checkpoint?.kind != .collection ||
            checkpoint?.createdOnBranchID != branchID ||
            checkpoint?.sourceCandidateID != candidateID ||
            candidate?.collectedCheckpointID != checkpointID ||
            candidate?.status != .collected ||
            version?.sourceCandidateID != candidateID ||
            checkpoint?.chapterSelections.contains(where: {
                $0.chapterID == version?.chapterID && $0.versionID == chapterVersionID
            }) != true ||
            !operationMatches {
            issues.append("Collection operation \(operation.operationID) has invalid outcome data.")
        }
    }

    private static func validateManualSyncOutcome(
        operation: NovelAppliedOperationRecord,
        branchID: NovelBranchID,
        checkpointID: NovelCheckpointID,
        revision: Int64,
        requiresMatchingOperationID: Bool,
        document: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        let checkpoint = document.checkpoints.first(where: { $0.id == checkpointID })
        if revision != operation.appliedProjectRevision ||
            checkpoint?.kind != .manualSync ||
            checkpoint?.createdOnBranchID != branchID ||
            (requiresMatchingOperationID && checkpoint?.operationID != operation.operationID) {
            issues.append("Manual-sync operation \(operation.operationID) has invalid outcome data.")
        }
    }

}
