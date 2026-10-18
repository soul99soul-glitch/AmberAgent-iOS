import Foundation

enum NovelOutcome: Codable, Equatable, Sendable {
    case projectCreated(projectID: NovelProjectID, branchID: NovelBranchID)
    case projectRenamed(projectID: NovelProjectID, revision: Int64)
    case materialRevised(
        projectID: NovelProjectID,
        materialID: NovelMaterialID,
        revisionID: NovelMaterialRevisionID,
        projectRevision: Int64,
        configRevision: Int64
    )
    case materialDeleted(
        projectID: NovelProjectID,
        materialID: NovelMaterialID,
        projectRevision: Int64,
        configRevision: Int64
    )
    case modelPolicyChanged(
        projectID: NovelProjectID,
        projectRevision: Int64,
        configRevision: Int64
    )
    case settingProposalAccepted(
        projectID: NovelProjectID,
        proposalID: NovelProposalID,
        materialID: NovelMaterialID,
        revisionID: NovelMaterialRevisionID,
        projectRevision: Int64,
        configRevision: Int64
    )
    case settingProposalRejected(
        projectID: NovelProjectID,
        proposalID: NovelProposalID,
        projectRevision: Int64,
        configRevision: Int64
    )
    case branchMaterialOverrideChanged(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        materialID: NovelMaterialID,
        revisionID: NovelMaterialRevisionID?,
        projectRevision: Int64,
        configRevision: Int64
    )
    case mainBranchChanged(projectID: NovelProjectID, branchID: NovelBranchID, revision: Int64)
    case polishPreferenceChanged(
        projectID: NovelProjectID,
        projectRevision: Int64,
        configRevision: Int64
    )
    case collaborationModeChanged(
        projectID: NovelProjectID,
        mode: NovelCollaborationMode,
        projectRevision: Int64,
        configRevision: Int64
    )
    case pauseGhostwriteOnBlockingContinuityChanged(
        projectID: NovelProjectID,
        enabled: Bool,
        projectRevision: Int64,
        configRevision: Int64
    )
    case chapterPlanUpserted(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        planID: NovelChapterPlanID,
        status: NovelChapterPlanStatus,
        contentDigest: String,
        projectRevision: Int64,
        configRevision: Int64
    )
    case chapterPlanCleared(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        projectRevision: Int64,
        configRevision: Int64
    )
    case upcomingArcUpserted(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        beatCount: Int,
        projectRevision: Int64,
        configRevision: Int64
    )
    case upcomingArcCleared(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        projectRevision: Int64,
        configRevision: Int64
    )
    case branchForked(
        projectID: NovelProjectID,
        sourceBranchID: NovelBranchID,
        branchID: NovelBranchID,
        checkpointID: NovelCheckpointID,
        revision: Int64
    )
    case branchRenamed(projectID: NovelProjectID, branchID: NovelBranchID, revision: Int64)
    case branchDeleted(projectID: NovelProjectID, branchID: NovelBranchID, revision: Int64)
    case branchHeadMoved(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        fromCheckpointID: NovelCheckpointID,
        toCheckpointID: NovelCheckpointID,
        headRevision: Int64,
        revision: Int64
    )
    case discussionArchived(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        archiveID: NovelMessageID,
        checkpointID: NovelCheckpointID,
        decisionRevisionIDs: [NovelMaterialRevisionID],
        projectRevision: Int64,
        configRevision: Int64
    )
    case characterIdentityClarified(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        mention: String,
        checkpointID: NovelCheckpointID,
        stateSnapshotID: NovelStateSnapshotID,
        revision: Int64
    )
    case candidateCloned(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        sourceCandidateID: NovelCandidateID,
        candidateID: NovelCandidateID,
        revision: Int64
    )
    case polishCandidateAdopted(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID,
        checkpointID: NovelCheckpointID,
        chapterVersionID: NovelChapterVersionID,
        revision: Int64
    )
    case polishCandidateRejected(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID,
        transactionID: NovelPendingOperationID,
        revision: Int64
    )
    case polishTransactionAbandoned(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID,
        transactionID: NovelPendingOperationID,
        revision: Int64
    )
    case chapterDiscardStateChanged(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        chapterID: NovelChapterID,
        isDiscarded: Bool,
        revision: Int64
    )
    case chapterRemovedFromManuscript(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        chapterID: NovelChapterID,
        workingRevision: Int64,
        revision: Int64
    )
    case chapterVersionRestored(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        checkpointID: NovelCheckpointID,
        chapterVersionID: NovelChapterVersionID,
        revision: Int64
    )
    case runStarted(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        runID: NovelRunID,
        receiptID: NovelReceiptID,
        revision: Int64
    )
    case runInterrupted(
        projectID: NovelProjectID,
        runID: NovelRunID,
        reason: NovelRunInterruptionReason,
        revision: Int64
    )
    case candidateCollected(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID,
        checkpointID: NovelCheckpointID,
        chapterVersionID: NovelChapterVersionID,
        revision: Int64
    )
    case manualEditSaved(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        chapterVersionID: NovelChapterVersionID,
        workingRevision: Int64,
        revision: Int64
    )
    case manualSyncCommitted(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        checkpointID: NovelCheckpointID,
        revision: Int64
    )
    case workspacePlotCommitted(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        checkpointID: NovelCheckpointID,
        revision: Int64
    )
    case projectImported(
        sourceProjectID: NovelProjectID,
        projectID: NovelProjectID,
        disposition: NovelProjectImportDisposition,
        interruptedRunCount: Int,
        revision: Int64
    )
    case previousProjectRestored(projectID: NovelProjectID, revision: Int64)
    case projectDeleted(projectID: NovelProjectID)
}

enum NovelSnapshotScope: Equatable, Sendable {
    case projects
    case project(NovelProjectID)
    case branch(projectID: NovelProjectID, branchID: NovelBranchID)
    case projectPackage(NovelProjectID)
    case workspace(NovelProjectID)
    case branchMarkdown(projectID: NovelProjectID, branchID: NovelBranchID)
    case injectionPreview(NovelInjectionPreviewRequest)
    case projectImportPreview(Data)
}

enum NovelSnapshot: Equatable, Sendable {
    case projects([NovelProjectSummary])
    case project(NovelProjectSnapshot)
    case branch(NovelBranchSnapshot)
    case package(NovelProjectPackageArtifact)
    case workspace(NovelWorkspaceExportArtifact)
    case markdown(NovelMarkdownExportArtifact)
    case injectionPreview(NovelInjectionPreviewSnapshot)
    case projectImportPreview(NovelProjectImportPreview)
}
