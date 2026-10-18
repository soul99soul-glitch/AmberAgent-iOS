import CryptoKit
import Foundation

struct NovelValidatedProjectTransition: Sendable {
    let current: NovelProjectDocumentV1
    let document: NovelProjectDocumentV1

    fileprivate init(
        current: NovelProjectDocumentV1,
        document: NovelProjectDocumentV1
    ) {
        self.current = current
        self.document = document
    }
}

enum NovelDocumentValidator {
    static func validate(_ document: NovelProjectDocumentV1) throws {
        guard document.schemaVersion == NovelProjectDocumentV1.currentSchemaVersion else {
            throw NovelError.unsupportedSchema(document.schemaVersion)
        }

        var issues: [String] = []
        NovelDocumentRecordValidation.validateProject(document, issues: &issues)
        NovelDocumentRecordValidation.validateMaterials(document, issues: &issues)
        NovelDocumentRecordValidation.validateSessionsAndBranches(document, issues: &issues)
        NovelDocumentRecordValidation.validateChaptersAndState(document, issues: &issues)
        NovelDocumentRecordValidation.validateSettingProposals(document, issues: &issues)
        NovelCompatibilityLineageValidator.validate(document, issues: &issues)
        NovelDocumentCheckpointValidation.validateCheckpoints(document, issues: &issues)
        NovelDocumentCheckpointValidation.validateCandidates(document, issues: &issues)
        NovelDocumentCheckpointValidation.validateRunsAndPendingOperations(document, issues: &issues)
        NovelPolishDocumentValidator.validate(document, issues: &issues)
        NovelGenerationDocumentValidator.validate(document, issues: &issues)
        NovelOperationLedgerValidation.validateOperationLedger(document, issues: &issues)
        for path in document.workspacePassthrough.opaqueFiles.keys
        where !NovelWorkspaceBackup.isValidRelativePath(path) {
            issues.append("Workspace file path must be relative and stay inside the workspace.")
        }

        if !issues.isEmpty {
            throw NovelError.invalidDocument(Array(Set(issues)).sorted())
        }
    }

    static func validateRecovery(_ sidecar: NovelRecoverySidecarV1) throws {
        guard sidecar.schemaVersion == NovelRecoverySidecarV1.currentSchemaVersion else {
            throw NovelError.invalidRecovery("Unsupported schema version \(sidecar.schemaVersion).")
        }
        guard sidecar.sequence >= 0 else {
            throw NovelError.invalidRecovery("Sequence must be non-negative.")
        }
        guard sidecar.baseProjectRevision >= 1 else {
            throw NovelError.invalidRecovery("Base project revision must be positive.")
        }
        guard isSHA256(sidecar.partialSHA256) else {
            throw NovelError.invalidRecovery("Partial content hash is not SHA-256.")
        }
        guard sidecar.partialSHA256.lowercased() == sha256(sidecar.partialContent) else {
            throw NovelError.invalidRecovery("Partial content does not match its SHA-256 hash.")
        }
        switch (sidecar.responseID, sidecar.responseSequenceNumber) {
        case (nil, nil):
            break
        case (.some(let responseID), .some(let sequenceNumber)):
            guard !responseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NovelError.invalidRecovery("Response ID must not be empty.")
            }
            guard sequenceNumber >= 0 else {
                throw NovelError.invalidRecovery("Response sequence must be non-negative.")
            }
        default:
            throw NovelError.invalidRecovery("Response cursor is incomplete.")
        }
    }

    static func validateTransition(
        from current: NovelProjectDocumentV1,
        to next: NovelProjectDocumentV1
    ) throws {
        try validate(current)
        _ = try validateTransitionFromValidatedCurrent(from: current, to: next)
    }

    /// Validates a new revision when `current` came from a successful repository
    /// load or commit. The full next document and every transition invariant are
    /// still checked; only the redundant re-validation of the known-good base is
    /// skipped.
    static func validateTransitionFromValidatedCurrent(
        from current: NovelProjectDocumentV1,
        to next: NovelProjectDocumentV1
    ) throws -> NovelValidatedProjectTransition {
        try validate(next)

        var issues: [String] = []
        if next.project.id != current.project.id {
            issues.append("A project transition changed the project ID.")
        }
        if next.project.createdAt != current.project.createdAt ||
            next.project.creationMode != current.project.creationMode ||
            next.project.quickStartSeed != current.project.quickStartSeed {
            issues.append("A project transition rewrote immutable creation metadata.")
        }

        appendUnchangedPrefixIssue(
            current.materialRevisions,
            next.materialRevisions,
            label: "material revision",
            issues: &issues
        )
        validateChapterTransition(from: current, to: next, issues: &issues)
        appendUnchangedPrefixIssue(
            current.chapterVersions,
            next.chapterVersions,
            label: "chapter version",
            issues: &issues
        )
        appendUnchangedPrefixIssue(current.events, next.events, label: "story event", issues: &issues)
        appendUnchangedPrefixIssue(
            current.stateSnapshots,
            next.stateSnapshots,
            label: "state snapshot",
            issues: &issues
        )
        appendUnchangedPrefixIssue(
            current.checkpoints,
            next.checkpoints,
            label: "checkpoint",
            issues: &issues
        )
        appendUnchangedPrefixIssue(
            current.injectionReceipts,
            next.injectionReceipts,
            label: "injection receipt",
            issues: &issues
        )
        appendUnchangedPrefixIssue(
            current.generationReceipts,
            next.generationReceipts,
            label: "generation receipt",
            issues: &issues
        )
        appendUnchangedPrefixIssue(
            current.factAttempts,
            next.factAttempts,
            label: "fact attempt",
            issues: &issues
        )
        NovelPolishDocumentValidator.validateTransition(
            from: current,
            to: next,
            issues: &issues
        )
        appendUnchangedPrefixIssue(
            current.appliedOperations,
            next.appliedOperations,
            label: "applied operation",
            issues: &issues
        )

        validateMaterialTransition(from: current, to: next, issues: &issues)
        validateBranchTransition(from: current, to: next, issues: &issues)
        validateSessionTransition(from: current, to: next, issues: &issues)
        validateCandidateTransition(from: current, to: next, issues: &issues)
        validateSettingProposalTransition(from: current, to: next, issues: &issues)
        validatePendingOperationTransition(from: current, to: next, issues: &issues)
        validateFactAttemptTransition(from: current, to: next, issues: &issues)
        validateNewUndoTransitions(from: current, to: next, issues: &issues)
        NovelGenerationDocumentValidator.validateTransition(
            from: current,
            to: next,
            issues: &issues
        )

        if !issues.isEmpty {
            throw NovelError.invalidDocument(Array(Set(issues)).sorted())
        }
        return NovelValidatedProjectTransition(current: current, document: next)
    }

    private static func validateNewUndoTransitions(
        from current: NovelProjectDocumentV1,
        to next: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        for operation in next.appliedOperations.dropFirst(current.appliedOperations.count) {
            guard operation.kind == .undoBranchHead,
                  case let .branchHeadMoved(
                      _, branchID, fromCheckpointID, toCheckpointID, _, _
                  ) = operation.outcome,
                  let branch = current.branches.first(where: { $0.id == branchID }),
                  let from = current.checkpoints.first(where: { $0.id == fromCheckpointID }) else {
                continue
            }
            let expected = NovelBranchSemantics.undoTarget(
                for: from,
                branch: branch,
                checkpoints: current.checkpoints
            )
            if branch.headCheckpointID != fromCheckpointID || expected?.id != toCheckpointID {
                issues.append("A new branch undo did not use the current semantic target.")
            }
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.count == 64 && normalized.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func validateFactAttemptTransition(
        from current: NovelProjectDocumentV1,
        to next: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        guard current.factAttempts != next.factAttempts else { return }
        guard next.factAttempts.count == current.factAttempts.count + 1,
              Array(next.factAttempts.dropLast()) == current.factAttempts,
              let appended = next.factAttempts.last,
              let owner = current.pendingOperations.first(where: {
                  $0.id == appended.pendingID &&
                      $0.operationID == appended.ownerOperationID &&
                      $0.branchID == appended.branchID
              }) else {
            issues.append("A fact retry reservation did not append one matching attempt.")
            return
        }

        let expectedKind: NovelFactReceiptKind = owner.kind == .collection
            ? .stateDelta
            : .manualRebuild
        let expectedFirstChunk = owner.kind == .manualSync
            ? (owner.manualSyncProgress?.nextChunkIndex ?? 0)
            : nil
        if appended.attemptOperationID == owner.operationID ||
            appended.kind != expectedKind ||
            appended.firstChunkIndex != expectedFirstChunk {
            issues.append("A fact retry reservation does not match its pending owner.")
        }

        var expectedProject = current.project
        expectedProject.revision = next.project.revision
        expectedProject.updatedAt = next.project.updatedAt
        let isolated = next.schemaVersion == current.schemaVersion &&
            next.project == expectedProject &&
            next.project.revision == current.project.revision + 1 &&
            next.materials == current.materials &&
            next.materialRevisions == current.materialRevisions &&
            next.branches == current.branches &&
            next.sessions == current.sessions &&
            next.chapters == current.chapters &&
            next.chapterVersions == current.chapterVersions &&
            next.events == current.events &&
            next.stateSnapshots == current.stateSnapshots &&
            next.checkpoints == current.checkpoints &&
            next.candidates == current.candidates &&
            next.injectionReceipts == current.injectionReceipts &&
            next.generationReceipts == current.generationReceipts &&
            next.pendingOperations == current.pendingOperations &&
            next.activeRuns == current.activeRuns &&
            next.settingProposals == current.settingProposals &&
            next.appliedOperations == current.appliedOperations
        if !isolated {
            issues.append("A fact retry reservation was not an isolated atomic transition.")
        }
    }

    private static func appendUnchangedPrefixIssue<Element: Equatable>(
        _ current: [Element],
        _ next: [Element],
        label: String,
        issues: inout [String]
    ) {
        guard next.count >= current.count else {
            issues.append("A project transition removed an immutable \(label).")
            return
        }
        if !zip(current, next).allSatisfy({ $0 == $1 }) {
            issues.append("A project transition rewrote an immutable \(label).")
        }
    }

    private static func validateMaterialTransition(
        from current: NovelProjectDocumentV1,
        to next: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        for material in current.materials {
            guard let candidate = next.materials.first(where: { $0.id == material.id }) else {
                issues.append("A project transition removed material \(material.id).")
                continue
            }
            if candidate.kind != material.kind {
                issues.append("A project transition changed material \(material.id) kind.")
            }
            if candidate.revisionIDs.count < material.revisionIDs.count ||
                !zip(material.revisionIDs, candidate.revisionIDs).allSatisfy({ $0 == $1 }) {
                issues.append("A project transition rewrote material \(material.id) revision history.")
            }
            if material.isDeleted && !candidate.isDeleted {
                issues.append("A project transition reactivated deleted material \(material.id).")
            }
        }
    }

    private static func validateChapterTransition(
        from current: NovelProjectDocumentV1,
        to next: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        guard next.chapters.count >= current.chapters.count else {
            issues.append("A project transition removed an immutable chapter.")
            return
        }
        let appendedOperations = next.appliedOperations.dropFirst(current.appliedOperations.count)
        for (chapter, updated) in zip(current.chapters, next.chapters) {
            if chapter.id != updated.id || chapter.createdAt != updated.createdAt {
                issues.append("A project transition rewrote immutable chapter identity.")
                continue
            }
            guard chapter.discardedAt != updated.discardedAt else { continue }
            let wasDiscarded = chapter.discardedAt != nil
            let isDiscarded = updated.discardedAt != nil
            guard wasDiscarded != isDiscarded else {
                issues.append("A project transition rewrote a chapter discard timestamp.")
                continue
            }
            let owners = appendedOperations.filter { operation in
                if case let .chapterDiscardStateChanged(
                    _, _, chapterID, outcomeIsDiscarded, _
                ) = operation.outcome,
                   chapterID == chapter.id,
                   outcomeIsDiscarded == isDiscarded {
                    return operation.kind == (isDiscarded ? .discardChapter : .restoreChapter)
                }
                return false
            }
            if owners.count != 1 ||
                (isDiscarded && updated.discardedAt != owners.first?.appliedAt) {
                issues.append("A chapter discard-state change has no matching atomic operation.")
            }
        }
        for operation in appendedOperations {
            if case let .chapterDiscardStateChanged(
                _, _, chapterID, outcomeIsDiscarded, _
            ) = operation.outcome {
                let expectedKind: NovelOperationKind = outcomeIsDiscarded
                    ? .discardChapter
                    : .restoreChapter
                guard operation.kind == expectedKind,
                      let chapter = current.chapters.first(where: { $0.id == chapterID }),
                      let updated = next.chapters.first(where: { $0.id == chapterID }),
                      (chapter.discardedAt != nil) != (updated.discardedAt != nil),
                      (updated.discardedAt != nil) == outcomeIsDiscarded else {
                    issues.append("A chapter discard operation has no matching state transition.")
                    continue
                }
                continue
            }
            if case let .chapterRemovedFromManuscript(
                _, branchID, chapterID, workingRevision, _
            ) = operation.outcome {
                guard operation.kind == .deleteChapterFromManuscript,
                      let currentBranch = current.branches.first(where: { $0.id == branchID }),
                      let nextBranch = next.branches.first(where: { $0.id == branchID }),
                      current.chapters == next.chapters,
                      currentBranch.workingChapterSelections.contains(where: {
                          $0.chapterID == chapterID
                      }),
                      nextBranch.workingChapterSelections == currentBranch.workingChapterSelections.filter({
                          $0.chapterID != chapterID
                      }),
                      nextBranch.workingRevision == currentBranch.workingRevision + 1,
                      nextBranch.workingRevision == workingRevision,
                      nextBranch.syncStatus == .needsSync else {
                    issues.append(
                        "A chapter manuscript-delete operation has no matching state transition."
                    )
                    continue
                }
            }
        }
    }

    private static func validateBranchTransition(
        from current: NovelProjectDocumentV1,
        to next: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        for branch in current.branches {
            guard let candidate = next.branches.first(where: { $0.id == branch.id }) else {
                issues.append("A project transition removed branch \(branch.id).")
                continue
            }
            if candidate.sessionID != branch.sessionID ||
                candidate.createdAt != branch.createdAt ||
                candidate.forkOrigin != branch.forkOrigin {
                issues.append("A project transition rewrote branch \(branch.id) identity.")
            }
            if branch.lifecycle == .deleted && candidate.lifecycle != .deleted {
                issues.append("A project transition reactivated deleted branch \(branch.id).")
            }
            if candidate.headRevision < branch.headRevision ||
                candidate.workingRevision < branch.workingRevision {
                issues.append("A project transition moved branch \(branch.id) revisions backwards.")
            }
        }
    }

    private static func validateSessionTransition(
        from current: NovelProjectDocumentV1,
        to next: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        let newOperationKinds = next.appliedOperations
            .dropFirst(current.appliedOperations.count)
            .map(\.kind)
        for session in current.sessions {
            guard let candidate = next.sessions.first(where: { $0.id == session.id }) else {
                issues.append("A project transition removed Session \(session.id).")
                continue
            }
            if candidate.branchID != session.branchID {
                issues.append("A project transition changed Session \(session.id) ownership.")
            }
            if candidate.messages.count < session.messages.count ||
                !zip(session.messages, candidate.messages).allSatisfy({ $0 == $1 }) {
                issues.append("A project transition rewrote Session \(session.id) history.")
            }
            if candidate.revision < session.revision {
                issues.append("A project transition moved Session \(session.id) revision backwards.")
            }
            let currentArchives = session.discussionArchives ?? []
            let nextArchives = candidate.discussionArchives ?? []
            if nextArchives.count < currentArchives.count ||
                !zip(currentArchives, nextArchives).allSatisfy({ $0 == $1 }) {
                issues.append("A project transition rewrote Session \(session.id) archives.")
            } else if nextArchives != currentArchives,
                      !newOperationKinds.contains(.archiveDiscussion) {
                issues.append("A project transition appended a Session archive without an archive operation.")
            }
            if candidate.archiveCursor != session.archiveCursor,
               !newOperationKinds.contains(.archiveDiscussion),
               !newOperationKinds.contains(.undoBranchHead) {
                issues.append("A project transition moved a Session archive cursor without archive history.")
            }
        }
    }

    private static func validateCandidateTransition(
        from current: NovelProjectDocumentV1,
        to next: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        for candidate in current.candidates {
            guard let updated = next.candidates.first(where: { $0.id == candidate.id }) else {
                issues.append("A project transition removed candidate \(candidate.id).")
                continue
            }
            if updated.kind != candidate.kind ||
                updated.branchID != candidate.branchID ||
                updated.sessionID != candidate.sessionID ||
                updated.sourceMessageID != candidate.sourceMessageID ||
                updated.baseCheckpointID != candidate.baseCheckpointID ||
                updated.baseHeadRevision != candidate.baseHeadRevision ||
                updated.content != candidate.content ||
                updated.sourceChapterVersionID != candidate.sourceChapterVersionID ||
                updated.clonedFromCandidateID != candidate.clonedFromCandidateID ||
                updated.createdAt != candidate.createdAt {
                issues.append("A project transition rewrote candidate \(candidate.id) identity or content.")
            }
            if let collectedCheckpointID = candidate.collectedCheckpointID,
               updated.collectedCheckpointID != collectedCheckpointID {
                issues.append("A project transition rewrote candidate \(candidate.id) collection history.")
            }
            if !candidateStatusCanTransition(from: candidate.status, to: updated.status) {
                issues.append("A project transition moved candidate \(candidate.id) status backwards.")
            }
        }
    }

    private static func validateSettingProposalTransition(
        from current: NovelProjectDocumentV1,
        to next: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        let newlyCompletedQuickStartRunIDs: Set<NovelRunID> = Set(
            current.activeRuns.compactMap { run -> NovelRunID? in
                guard run.kind == .quickStart,
                      run.status == .running,
                      next.activeRuns.contains(where: {
                          $0.id == run.id && $0.kind == .quickStart && $0.status == .completed
                      }) else { return nil }
                return run.id
            }
        )
        for proposal in current.settingProposals {
            guard let updated = next.settingProposals.first(where: { $0.id == proposal.id }) else {
                issues.append("A project transition removed setting proposal \(proposal.id).")
                continue
            }
            if updated.branchID != proposal.branchID ||
                updated.title != proposal.title ||
                updated.content != proposal.content ||
                updated.createdAt != proposal.createdAt ||
                updated.origin != proposal.origin {
                issues.append("A project transition rewrote setting proposal \(proposal.id).")
            }
            if proposal.isResolved && !updated.isResolved {
                issues.append("A project transition reopened setting proposal \(proposal.id).")
            }
            if let supersedingRunID = proposal.supersededByRunID,
               updated.supersededByRunID != supersedingRunID {
                issues.append("A project transition rewrote the superseding run for proposal \(proposal.id).")
            }
            guard proposal.supersededByRunID == nil,
                  let supersedingRunID = updated.supersededByRunID else { continue }
            guard !proposal.isResolved,
                  case .some(.quickStart(let sourceRunID, _)) = proposal.origin,
                  newlyCompletedQuickStartRunIDs.contains(supersedingRunID),
                  next.activeRuns.contains(where: {
                      $0.id == supersedingRunID && $0.branchID == proposal.branchID
                  }) else {
                issues.append(
                    "A project transition superseded proposal \(proposal.id) without a newly completed quick-start run."
                )
                continue
            }
            let sourceRound = current.settingProposals.filter { candidate in
                guard candidate.branchID == proposal.branchID,
                      !candidate.isResolved,
                      candidate.supersededByRunID == nil,
                      case .some(.quickStart(let candidateRunID, _)) = candidate.origin else {
                    return false
                }
                return candidateRunID == sourceRunID
            }
            if sourceRound.contains(where: { candidate in
                next.settingProposals.first(where: { $0.id == candidate.id })?
                    .supersededByRunID != supersedingRunID
            }) {
                issues.append(
                    "A project transition partially superseded quick-start proposal round \(sourceRunID)."
                )
            }
        }

    }

    private static func validatePendingOperationTransition(
        from current: NovelProjectDocumentV1,
        to next: NovelProjectDocumentV1,
        issues: inout [String]
    ) {
        for pending in current.pendingOperations {
            guard let updated = next.pendingOperations.first(where: { $0.id == pending.id }) else {
                continue
            }
            if updated.kind != pending.kind ||
                updated.branchID != pending.branchID ||
                updated.operationID != pending.operationID ||
                updated.payloadSHA256 != pending.payloadSHA256 ||
                updated.baseCheckpointID != pending.baseCheckpointID ||
                updated.baseHeadRevision != pending.baseHeadRevision ||
                updated.baseWorkingRevision != pending.baseWorkingRevision ||
                updated.candidateID != pending.candidateID ||
                updated.collectionTarget != pending.collectionTarget ||
                updated.selectedText != pending.selectedText ||
                updated.proposedChapterVersion != pending.proposedChapterVersion ||
                updated.proposedCheckpointID != pending.proposedCheckpointID ||
                updated.proposedStateSnapshotID != pending.proposedStateSnapshotID ||
                updated.rebuildBaseCheckpointID != pending.rebuildBaseCheckpointID ||
                updated.sessionCursor != pending.sessionCursor ||
                updated.createdAt != pending.createdAt {
                issues.append("A project transition rewrote pending operation \(pending.id) payload.")
            }
            if pending.status == .retryable && updated.status == .pending {
                issues.append("A project transition moved retryable pending operation \(pending.id) backwards.")
            }
            NovelManualSyncProgressValidator.validateTransition(
                from: pending,
                to: updated,
                currentDocument: current,
                nextDocument: next,
                issues: &issues
            )
        }
    }

    private static func candidateStatusCanTransition(
        from current: NovelCandidateStatus,
        to next: NovelCandidateStatus
    ) -> Bool {
        if current == next { return true }
        return switch (current, next) {
        case (.available, .collected),
             (.available, .adopted),
             (.available, .interrupted),
             (.available, .superseded),
             (.interrupted, .collected),
             (.collected, .superseded),
             (.adopted, .superseded):
            true
        default:
            false
        }
    }

}

extension NovelOutcome {
    var projectID: NovelProjectID {
        switch self {
        case .projectCreated(let projectID, _): projectID
        case .projectRenamed(let projectID, _): projectID
        case .materialRevised(let projectID, _, _, _, _): projectID
        case .materialDeleted(let projectID, _, _, _): projectID
        case .modelPolicyChanged(let projectID, _, _): projectID
        case .settingProposalAccepted(let projectID, _, _, _, _, _): projectID
        case .settingProposalRejected(let projectID, _, _, _): projectID
        case .branchMaterialOverrideChanged(let projectID, _, _, _, _, _): projectID
        case .mainBranchChanged(let projectID, _, _): projectID
        case .polishPreferenceChanged(let projectID, _, _): projectID
        case .collaborationModeChanged(let projectID, _, _, _): projectID
        case .pauseGhostwriteOnBlockingContinuityChanged(let projectID, _, _, _): projectID
        case .chapterPlanUpserted(let projectID, _, _, _, _, _, _): projectID
        case .chapterPlanCleared(let projectID, _, _, _): projectID
        case .upcomingArcUpserted(let projectID, _, _, _, _): projectID
        case .upcomingArcCleared(let projectID, _, _, _): projectID
        case .characterIdentityClarified(let projectID, _, _, _, _, _): projectID
        case .branchForked(let projectID, _, _, _, _): projectID
        case .branchRenamed(let projectID, _, _): projectID
        case .branchDeleted(let projectID, _, _): projectID
        case .branchHeadMoved(let projectID, _, _, _, _, _): projectID
        case .discussionArchived(let projectID, _, _, _, _, _, _): projectID
        case .candidateCloned(let projectID, _, _, _, _): projectID
        case .polishCandidateAdopted(let projectID, _, _, _, _, _): projectID
        case .polishCandidateRejected(let projectID, _, _, _, _): projectID
        case .polishTransactionAbandoned(let projectID, _, _, _, _): projectID
        case .chapterVersionRestored(let projectID, _, _, _, _): projectID
        case .chapterDiscardStateChanged(let projectID, _, _, _, _): projectID
        case .chapterRemovedFromManuscript(let projectID, _, _, _, _): projectID
        case .runStarted(let projectID, _, _, _, _): projectID
        case .runInterrupted(let projectID, _, _, _): projectID
        case .candidateCollected(let projectID, _, _, _, _, _): projectID
        case .manualEditSaved(let projectID, _, _, _, _): projectID
        case .manualSyncCommitted(let projectID, _, _, _): projectID
        case .workspacePlotCommitted(let projectID, _, _, _): projectID
        case .projectImported(_, let projectID, _, _, _): projectID
        case .previousProjectRestored(let projectID, _): projectID
        case .projectDeleted(let projectID): projectID
        }
    }

    var targetBranchID: NovelBranchID? {
        switch self {
        case .projectCreated(_, let branchID),
             .mainBranchChanged(_, let branchID, _),
             .branchMaterialOverrideChanged(_, let branchID, _, _, _, _),
             .branchRenamed(_, let branchID, _),
             .branchDeleted(_, let branchID, _),
             .branchHeadMoved(_, let branchID, _, _, _, _),
             .chapterPlanUpserted(_, let branchID, _, _, _, _, _),
             .chapterPlanCleared(_, let branchID, _, _),
             .upcomingArcUpserted(_, let branchID, _, _, _),
             .upcomingArcCleared(_, let branchID, _, _),
             .characterIdentityClarified(_, let branchID, _, _, _, _),
             .discussionArchived(_, let branchID, _, _, _, _, _),
             .candidateCloned(_, let branchID, _, _, _),
             .chapterDiscardStateChanged(_, let branchID, _, _, _),
             .chapterRemovedFromManuscript(_, let branchID, _, _, _),
             .polishCandidateAdopted(_, let branchID, _, _, _, _),
             .polishCandidateRejected(_, let branchID, _, _, _),
             .polishTransactionAbandoned(_, let branchID, _, _, _),
             .chapterVersionRestored(_, let branchID, _, _, _),
             .runStarted(_, let branchID, _, _, _),
             .candidateCollected(_, let branchID, _, _, _, _),
             .manualEditSaved(_, let branchID, _, _, _),
             .manualSyncCommitted(_, let branchID, _, _),
             .workspacePlotCommitted(_, let branchID, _, _):
            branchID
        case .branchForked(_, _, let branchID, _, _):
            branchID
        case .projectRenamed,
             .materialRevised,
             .materialDeleted,
             .modelPolicyChanged,
             .settingProposalAccepted,
             .settingProposalRejected,
             .polishPreferenceChanged,
             .collaborationModeChanged,
             .pauseGhostwriteOnBlockingContinuityChanged,
             .runInterrupted,
             .projectImported,
             .previousProjectRestored,
             .projectDeleted:
            nil
        }
    }
}
