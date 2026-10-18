import CryptoKit
import Foundation

enum NovelAction: Equatable, Sendable {
    case createProject(NovelCreateProjectCommand)
    case renameProject(NovelRenameProjectCommand)
    case reviseMaterial(NovelReviseMaterialCommand)
    case deleteMaterial(NovelDeleteMaterialCommand)
    case setModelPolicy(NovelSetModelPolicyCommand)
    case resolveSettingProposal(NovelResolveSettingProposalCommand)
    case setBranchMaterialOverride(NovelSetBranchMaterialOverrideCommand)
    case setMainBranch(NovelSetMainBranchCommand)
    case setPolishPreference(NovelSetPolishPreferenceCommand)
    case setCollaborationMode(NovelSetCollaborationModeCommand)
    case setPauseGhostwriteOnBlockingContinuity(NovelSetPauseGhostwriteOnBlockingContinuityCommand)
    case upsertChapterPlan(NovelUpsertChapterPlanCommand)
    case clearChapterPlan(NovelClearChapterPlanCommand)
    case upsertUpcomingArc(NovelUpsertUpcomingArcCommand)
    case clearUpcomingArc(NovelClearUpcomingArcCommand)
    case forkBranch(NovelForkBranchCommand)
    case renameBranch(NovelRenameBranchCommand)
    case deleteBranch(NovelDeleteBranchCommand)
    case undoBranchHead(NovelUndoBranchHeadCommand)
    case archiveDiscussion(NovelArchiveDiscussionCommand)
    case clarifyCharacterIdentity(NovelClarifyCharacterIdentityCommand)
    case cloneCandidate(NovelCloneCandidateCommand)
    case adoptPolishCandidate(NovelAdoptPolishCandidateCommand)
    case abandonPolishTransaction(NovelAbandonPolishTransactionCommand)
    case restoreChapterVersion(NovelRestoreChapterVersionCommand)
    case discardChapter(NovelDiscardChapterCommand)
    case restoreChapter(NovelRestoreChapterCommand)
    case deleteChapterFromManuscript(NovelDeleteChapterFromManuscriptCommand)
    case cancelRun(NovelCancelRunCommand)
    case collectCandidate(NovelCollectCandidateCommand)
    case saveManualEdit(NovelSaveManualEditCommand)
    case syncManualEdits(NovelSyncManualEditsCommand)
    case retryPending(NovelRetryPendingCommand)
    case importProject(NovelImportProjectCommand)
    case restorePreviousProject(NovelRestorePreviousProjectCommand)
    case deleteProject(NovelDeleteProjectCommand)

    var projectID: NovelProjectID {
        switch self {
        case .createProject(let command): command.projectID
        case .renameProject(let command): command.projectID
        case .reviseMaterial(let command): command.projectID
        case .deleteMaterial(let command): command.projectID
        case .setModelPolicy(let command): command.projectID
        case .resolveSettingProposal(let command): command.projectID
        case .setBranchMaterialOverride(let command): command.projectID
        case .setMainBranch(let command): command.projectID
        case .setPolishPreference(let command): command.projectID
        case .setCollaborationMode(let command): command.projectID
        case .setPauseGhostwriteOnBlockingContinuity(let command): command.projectID
        case .upsertChapterPlan(let command): command.projectID
        case .clearChapterPlan(let command): command.projectID
        case .upsertUpcomingArc(let command): command.projectID
        case .clearUpcomingArc(let command): command.projectID
        case .forkBranch(let command): command.projectID
        case .renameBranch(let command): command.projectID
        case .deleteBranch(let command): command.projectID
        case .undoBranchHead(let command): command.projectID
        case .archiveDiscussion(let command): command.projectID
        case .clarifyCharacterIdentity(let command): command.projectID
        case .cloneCandidate(let command): command.projectID
        case .adoptPolishCandidate(let command): command.projectID
        case .abandonPolishTransaction(let command): command.projectID
        case .restoreChapterVersion(let command): command.projectID
        case .discardChapter(let command): command.projectID
        case .restoreChapter(let command): command.projectID
        case .deleteChapterFromManuscript(let command): command.projectID
        case .cancelRun(let command): command.projectID
        case .collectCandidate(let command): command.projectID
        case .saveManualEdit(let command): command.projectID
        case .syncManualEdits(let command): command.projectID
        case .retryPending(let command): command.projectID
        case .importProject(let command): command.projectID
        case .restorePreviousProject(let command): command.projectID
        case .deleteProject(let command): command.projectID
        }
    }

    var context: NovelMutationContext {
        switch self {
        case .createProject(let command): command.context
        case .renameProject(let command): command.context
        case .reviseMaterial(let command): command.context
        case .deleteMaterial(let command): command.context
        case .setModelPolicy(let command): command.context
        case .resolveSettingProposal(let command): command.context
        case .setBranchMaterialOverride(let command): command.context
        case .setMainBranch(let command): command.context
        case .setPolishPreference(let command): command.context
        case .setCollaborationMode(let command): command.context
        case .setPauseGhostwriteOnBlockingContinuity(let command): command.context
        case .upsertChapterPlan(let command): command.context
        case .clearChapterPlan(let command): command.context
        case .upsertUpcomingArc(let command): command.context
        case .clearUpcomingArc(let command): command.context
        case .forkBranch(let command): command.context
        case .renameBranch(let command): command.context
        case .deleteBranch(let command): command.context
        case .undoBranchHead(let command): command.context
        case .archiveDiscussion(let command): command.context
        case .clarifyCharacterIdentity(let command): command.context
        case .cloneCandidate(let command): command.context
        case .adoptPolishCandidate(let command): command.context
        case .abandonPolishTransaction(let command): command.context
        case .restoreChapterVersion(let command): command.context
        case .discardChapter(let command): command.context
        case .restoreChapter(let command): command.context
        case .deleteChapterFromManuscript(let command): command.context
        case .cancelRun(let command): command.context
        case .collectCandidate(let command): command.context
        case .saveManualEdit(let command): command.context
        case .syncManualEdits(let command): command.context
        case .retryPending(let command): command.context
        case .importProject(let command): command.context
        case .restorePreviousProject(let command): command.context
        case .deleteProject(let command): command.context
        }
    }

    var operationKind: NovelOperationKind {
        switch self {
        case .createProject: .createProject
        case .renameProject: .renameProject
        case .reviseMaterial: .reviseMaterial
        case .deleteMaterial: .deleteMaterial
        case .setModelPolicy: .setModelPolicy
        case .resolveSettingProposal: .resolveSettingProposal
        case .setBranchMaterialOverride: .setBranchMaterialOverride
        case .setMainBranch: .setMainBranch
        case .setPolishPreference: .setPolishPreference
        case .setCollaborationMode: .setCollaborationMode
        case .setPauseGhostwriteOnBlockingContinuity: .setPauseGhostwriteOnBlockingContinuity
        case .upsertChapterPlan: .upsertChapterPlan
        case .clearChapterPlan: .clearChapterPlan
        case .upsertUpcomingArc: .upsertUpcomingArc
        case .clearUpcomingArc: .clearUpcomingArc
        case .forkBranch: .forkBranch
        case .renameBranch: .renameBranch
        case .deleteBranch: .deleteBranch
        case .undoBranchHead: .undoBranchHead
        case .archiveDiscussion: .archiveDiscussion
        case .clarifyCharacterIdentity: .clarifyCharacterIdentity
        case .cloneCandidate: .cloneCandidate
        case .adoptPolishCandidate: .adoptPolishCandidate
        case .abandonPolishTransaction: .abandonPolishTransaction
        case .restoreChapterVersion: .restoreChapterVersion
        case .discardChapter: .discardChapter
        case .restoreChapter: .restoreChapter
        case .deleteChapterFromManuscript: .deleteChapterFromManuscript
        case .cancelRun: .cancelRun
        case .collectCandidate: .collectCandidate
        case .saveManualEdit: .saveManualEdit
        case .syncManualEdits: .syncManualEdits
        case .retryPending: .retryPending
        case .importProject: .importProject
        case .restorePreviousProject: .restorePreviousProject
        case .deleteProject: .deleteProject
        }
    }

    var isProjectCreation: Bool {
        switch self {
        case .createProject, .importProject: true
        default: false
        }
    }

    var isRunCancellation: Bool {
        if case .cancelRun = self { return true }
        return false
    }

    var isProjectLifecycle: Bool {
        switch self {
        case .importProject, .restorePreviousProject, .deleteProject: true
        default: false
        }
    }

    func canonicalPayloadSHA256() throws -> String {
        let payload: NovelCanonicalActionPayload
        switch self {
        case .createProject(let command):
            payload = .createProject(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                sessionID: command.sessionID,
                initialStateSnapshotID: command.initialStateSnapshotID,
                initialCheckpointID: command.initialCheckpointID,
                name: command.name,
                branchName: command.branchName,
                creationMode: command.creationMode,
                quickStartSeed: command.quickStartSeed
            ))
        case .renameProject(let command):
            payload = .renameProject(.init(projectID: command.projectID, name: command.name))
        case .reviseMaterial(let command):
            payload = .reviseMaterial(.init(
                projectID: command.projectID,
                materialID: command.materialID,
                revisionID: command.revisionID,
                kind: command.kind,
                title: command.title,
                content: command.content,
                tags: command.tags,
                injectionMode: command.injectionMode,
                aliases: command.aliases
            ))
        case .deleteMaterial(let command):
            payload = .deleteMaterial(.init(
                projectID: command.projectID,
                materialID: command.materialID
            ))
        case .setModelPolicy(let command):
            payload = .setModelPolicy(.init(
                projectID: command.projectID,
                purpose: command.purpose,
                policy: command.policy
            ))
        case .resolveSettingProposal(let command):
            payload = .resolveSettingProposal(.init(
                projectID: command.projectID,
                proposalID: command.proposalID,
                resolution: command.resolution
            ))
        case .setBranchMaterialOverride(let command):
            payload = .setBranchMaterialOverride(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                materialID: command.materialID,
                change: command.change
            ))
        case .setMainBranch(let command):
            payload = .setMainBranch(.init(
                projectID: command.projectID,
                branchID: command.branchID
            ))
        case .setPolishPreference(let command):
            payload = .setPolishPreference(.init(
                projectID: command.projectID,
                preference: command.preference
            ))
        case .setCollaborationMode(let command):
            payload = .setCollaborationMode(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                mode: command.mode
            ))
        case .setPauseGhostwriteOnBlockingContinuity(let command):
            payload = .setPauseGhostwriteOnBlockingContinuity(.init(
                projectID: command.projectID,
                enabled: command.enabled
            ))
        case .upsertChapterPlan(let command):
            payload = .upsertChapterPlan(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                planID: command.planID,
                status: command.status,
                outlinePlacement: command.outlinePlacement,
                goalAndConflict: command.goalAndConflict,
                mustHappen: command.mustHappen,
                mustNotHappen: command.mustNotHappen,
                endingHook: command.endingHook,
                visibleFacts: command.visibleFacts
            ))
        case .clearChapterPlan(let command):
            payload = .clearChapterPlan(.init(
                projectID: command.projectID,
                branchID: command.branchID
            ))
        case .upsertUpcomingArc(let command):
            payload = .upsertUpcomingArc(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                beats: command.beats
            ))
        case .clearUpcomingArc(let command):
            payload = .clearUpcomingArc(.init(
                projectID: command.projectID,
                branchID: command.branchID
            ))
        case .forkBranch(let command):
            payload = .forkBranch(.init(
                projectID: command.projectID,
                sourceBranchID: command.sourceBranchID,
                checkpointID: command.checkpointID,
                branchID: command.branchID,
                sessionID: command.sessionID,
                name: command.name
            ))
        case .renameBranch(let command):
            payload = .renameBranch(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                name: command.name
            ))
        case .deleteBranch(let command):
            payload = .deleteBranch(.init(
                projectID: command.projectID,
                branchID: command.branchID
            ))
        case .undoBranchHead(let command):
            payload = .undoBranchHead(.init(
                projectID: command.projectID,
                branchID: command.branchID
            ))
        case .archiveDiscussion(let command):
            payload = .archiveDiscussion(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                archiveID: command.archiveID,
                checkpointID: command.checkpointID,
                throughSequence: command.throughSequence,
                chapterID: command.chapterID,
                summary: command.summary,
                decisions: command.decisions
            ))
        case .clarifyCharacterIdentity(let command):
            payload = .clarifyCharacterIdentity(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                checkpointID: command.checkpointID,
                stateSnapshotID: command.stateSnapshotID,
                mention: command.mention,
                clarification: command.clarification
            ))
        case .cloneCandidate(let command):
            payload = .cloneCandidate(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                sourceCandidateID: command.sourceCandidateID,
                candidateID: command.candidateID
            ))
        case .adoptPolishCandidate(let command):
            payload = .adoptPolishCandidate(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                transactionID: command.transactionID,
                candidateID: command.candidateID,
                proposedChapterVersionID: command.proposedChapterVersionID,
                checkpointID: command.checkpointID
            ))
        case .discardChapter(let command):
            payload = .discardChapter(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                chapterID: command.chapterID
            ))
        case .restoreChapter(let command):
            payload = .restoreChapter(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                chapterID: command.chapterID
            ))
        case .deleteChapterFromManuscript(let command):
            payload = .deleteChapterFromManuscript(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                chapterID: command.chapterID,
                expectedWorkingRevision: command.expectedWorkingRevision
            ))
        case .abandonPolishTransaction(let command):
            payload = .abandonPolishTransaction(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                transactionID: command.transactionID
            ))
        case .restoreChapterVersion(let command):
            payload = .restoreChapterVersion(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                targetChapterVersionID: command.targetChapterVersionID,
                proposedChapterVersionID: command.proposedChapterVersionID,
                checkpointID: command.checkpointID
            ))
        case .cancelRun(let command):
            payload = .cancelRun(.init(
                projectID: command.projectID,
                runID: command.runID,
                reason: command.reason
            ))
        case .collectCandidate(let command):
            payload = .collectCandidate(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                pendingID: command.pendingID,
                candidateID: command.candidateID,
                selection: command.selection,
                target: command.target,
                proposedChapterVersionID: command.proposedChapterVersionID,
                checkpointID: command.checkpointID,
                stateSnapshotID: command.stateSnapshotID,
                factCompatibilityID: command.factCompatibilityID,
                source: command.source
            ))
        case .saveManualEdit(let command):
            payload = .saveManualEdit(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                chapterID: command.chapterID,
                versionID: command.versionID,
                title: command.title,
                content: command.content,
                factCompatibilityID: command.factCompatibilityID
            ))
        case .syncManualEdits(let command):
            payload = .syncManualEdits(.init(
                projectID: command.projectID,
                branchID: command.branchID,
                pendingID: command.pendingID,
                checkpointID: command.checkpointID,
                stateSnapshotID: command.stateSnapshotID
            ))
        case .retryPending(let command):
            payload = .retryPending(.init(
                projectID: command.projectID,
                pendingID: command.pendingID
            ))
        case .importProject(let command):
            let policy: NovelCanonicalActionPayload.ImportPolicy
            switch command.policy {
            case .reject:
                policy = .reject
            case .replace:
                policy = .replace
            case .keepBoth(let destinationProjectID):
                policy = .keepBoth(destinationProjectID: destinationProjectID)
            }
            payload = .importProject(.init(
                projectID: command.projectID,
                packageSHA256: NovelProjectPackageCodec.sha256(command.packageData),
                policy: policy
            ))
        case .restorePreviousProject(let command):
            payload = .restorePreviousProject(.init(projectID: command.projectID))
        case .deleteProject(let command):
            payload = .deleteProject(.init(projectID: command.projectID))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let payloadHash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return try NovelApprovalCommit.payloadSHA256(payloadHash, response: context.approvalResponse)
    }
}

extension NovelCreateProjectCommand {
    func canonicalPayloadSHA256() throws -> String {
        try NovelAction.createProject(self).canonicalPayloadSHA256()
    }
}

extension NovelCollectCandidateCommand {
    func canonicalPayloadSHA256() throws -> String {
        try NovelAction.collectCandidate(self).canonicalPayloadSHA256()
    }
}

extension NovelSaveManualEditCommand {
    func canonicalPayloadSHA256() throws -> String {
        try NovelAction.saveManualEdit(self).canonicalPayloadSHA256()
    }
}

extension NovelSyncManualEditsCommand {
    func canonicalPayloadSHA256() throws -> String {
        try NovelAction.syncManualEdits(self).canonicalPayloadSHA256()
    }
}

extension NovelRetryPendingCommand {
    func canonicalPayloadSHA256() throws -> String {
        try NovelAction.retryPending(self).canonicalPayloadSHA256()
    }
}

private enum NovelCanonicalActionPayload: Codable {
    struct CreateProject: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let sessionID: NovelSessionID
        let initialStateSnapshotID: NovelStateSnapshotID
        let initialCheckpointID: NovelCheckpointID
        let name: String
        let branchName: String
        let creationMode: NovelProjectCreationMode
        let quickStartSeed: NovelQuickStartSeed?
    }

    struct RenameProject: Codable {
        let projectID: NovelProjectID
        let name: String
    }

    struct ReviseMaterial: Codable {
        let projectID: NovelProjectID
        let materialID: NovelMaterialID
        let revisionID: NovelMaterialRevisionID
        let kind: NovelMaterialKind
        let title: String
        let content: String
        let tags: [String]
        let injectionMode: NovelInjectionMode
        let aliases: [String]
    }

    struct DeleteMaterial: Codable {
        let projectID: NovelProjectID
        let materialID: NovelMaterialID
    }

    struct SetModelPolicy: Codable {
        let projectID: NovelProjectID
        let purpose: NovelModelRole
        let policy: NovelProjectModelPolicy
    }

    struct ResolveSettingProposal: Codable {
        let projectID: NovelProjectID
        let proposalID: NovelProposalID
        let resolution: NovelSettingProposalResolution
    }

    struct SetBranchMaterialOverride: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let materialID: NovelMaterialID
        let change: NovelBranchMaterialOverrideChange
    }

    struct SetMainBranch: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
    }

    struct SetPolishPreference: Codable {
        let projectID: NovelProjectID
        let preference: String
    }

    struct SetCollaborationMode: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let mode: NovelCollaborationMode
    }

    struct SetPauseGhostwriteOnBlockingContinuity: Codable {
        let projectID: NovelProjectID
        let enabled: Bool
    }

    struct UpsertChapterPlan: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let planID: NovelChapterPlanID
        let status: NovelChapterPlanStatus
        let outlinePlacement: String
        let goalAndConflict: String
        let mustHappen: [String]
        let mustNotHappen: [String]
        let endingHook: String
        let visibleFacts: [String]
    }

    struct ClearChapterPlan: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
    }

    struct UpsertUpcomingArc: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let beats: [String]
    }

    struct ClearUpcomingArc: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
    }

    struct ForkBranch: Codable {
        let projectID: NovelProjectID
        let sourceBranchID: NovelBranchID
        let checkpointID: NovelCheckpointID
        let branchID: NovelBranchID
        let sessionID: NovelSessionID
        let name: String
    }

    struct RenameBranch: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let name: String
    }

    struct DeleteBranch: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
    }

    struct UndoBranchHead: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
    }

    struct ArchiveDiscussion: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let archiveID: NovelMessageID
        let checkpointID: NovelCheckpointID
        let throughSequence: Int64
        let chapterID: NovelChapterID?
        let summary: String
        let decisions: [NovelConfirmedDiscussionDecision]
    }

    struct ClarifyCharacterIdentity: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let checkpointID: NovelCheckpointID
        let stateSnapshotID: NovelStateSnapshotID
        let mention: String
        let clarification: String
    }

    struct CloneCandidate: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let sourceCandidateID: NovelCandidateID
        let candidateID: NovelCandidateID
    }

    struct AdoptPolishCandidate: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let transactionID: NovelPendingOperationID
        let candidateID: NovelCandidateID
        let proposedChapterVersionID: NovelChapterVersionID
        let checkpointID: NovelCheckpointID
    }

    struct AbandonPolishTransaction: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let transactionID: NovelPendingOperationID
    }

    struct ChapterDiscardScope: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let chapterID: NovelChapterID
    }

    struct DeleteChapterFromManuscript: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let chapterID: NovelChapterID
        let expectedWorkingRevision: Int64
    }

    struct RestoreChapterVersion: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let targetChapterVersionID: NovelChapterVersionID
        let proposedChapterVersionID: NovelChapterVersionID
        let checkpointID: NovelCheckpointID
    }

    struct CancelRun: Codable {
        let projectID: NovelProjectID
        let runID: NovelRunID
        let reason: NovelRunInterruptionReason
    }

    struct CollectCandidate: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let pendingID: NovelPendingOperationID
        let candidateID: NovelCandidateID
        let selection: NovelParagraphSelection
        let target: NovelCollectionTarget
        let proposedChapterVersionID: NovelChapterVersionID
        let checkpointID: NovelCheckpointID
        let stateSnapshotID: NovelStateSnapshotID
        let factCompatibilityID: UUID
        let source: NovelCollectionSource

        init(
            projectID: NovelProjectID,
            branchID: NovelBranchID,
            pendingID: NovelPendingOperationID,
            candidateID: NovelCandidateID,
            selection: NovelParagraphSelection,
            target: NovelCollectionTarget,
            proposedChapterVersionID: NovelChapterVersionID,
            checkpointID: NovelCheckpointID,
            stateSnapshotID: NovelStateSnapshotID,
            factCompatibilityID: UUID,
            source: NovelCollectionSource = .user
        ) {
            self.projectID = projectID
            self.branchID = branchID
            self.pendingID = pendingID
            self.candidateID = candidateID
            self.selection = selection
            self.target = target
            self.proposedChapterVersionID = proposedChapterVersionID
            self.checkpointID = checkpointID
            self.stateSnapshotID = stateSnapshotID
            self.factCompatibilityID = factCompatibilityID
            self.source = source
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            projectID = try values.decode(NovelProjectID.self, forKey: .projectID)
            branchID = try values.decode(NovelBranchID.self, forKey: .branchID)
            pendingID = try values.decode(NovelPendingOperationID.self, forKey: .pendingID)
            candidateID = try values.decode(NovelCandidateID.self, forKey: .candidateID)
            selection = try values.decode(NovelParagraphSelection.self, forKey: .selection)
            target = try values.decode(NovelCollectionTarget.self, forKey: .target)
            proposedChapterVersionID = try values.decode(
                NovelChapterVersionID.self,
                forKey: .proposedChapterVersionID
            )
            checkpointID = try values.decode(NovelCheckpointID.self, forKey: .checkpointID)
            stateSnapshotID = try values.decode(NovelStateSnapshotID.self, forKey: .stateSnapshotID)
            factCompatibilityID = try values.decode(UUID.self, forKey: .factCompatibilityID)
            source = try values.decodeIfPresent(NovelCollectionSource.self, forKey: .source) ?? .user
        }
    }

    struct SaveManualEdit: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let chapterID: NovelChapterID
        let versionID: NovelChapterVersionID
        let title: String
        let content: String
        let factCompatibilityID: UUID
    }

    struct SyncManualEdits: Codable {
        let projectID: NovelProjectID
        let branchID: NovelBranchID
        let pendingID: NovelPendingOperationID
        let checkpointID: NovelCheckpointID
        let stateSnapshotID: NovelStateSnapshotID
    }

    struct RetryPending: Codable {
        let projectID: NovelProjectID
        let pendingID: NovelPendingOperationID
    }

    struct ImportProject: Codable {
        let projectID: NovelProjectID
        let packageSHA256: String
        let policy: ImportPolicy
    }

    enum ImportPolicy: Codable {
        case reject
        case replace
        case keepBoth(destinationProjectID: NovelProjectID)
    }

    struct DeleteProject: Codable {
        let projectID: NovelProjectID
    }

    struct RestorePreviousProject: Codable {
        let projectID: NovelProjectID
    }

    case createProject(CreateProject)
    case renameProject(RenameProject)
    case reviseMaterial(ReviseMaterial)
    case deleteMaterial(DeleteMaterial)
    case setModelPolicy(SetModelPolicy)
    case resolveSettingProposal(ResolveSettingProposal)
    case setBranchMaterialOverride(SetBranchMaterialOverride)
    case setMainBranch(SetMainBranch)
    case setPolishPreference(SetPolishPreference)
    case setCollaborationMode(SetCollaborationMode)
    case setPauseGhostwriteOnBlockingContinuity(SetPauseGhostwriteOnBlockingContinuity)
    case upsertChapterPlan(UpsertChapterPlan)
    case clearChapterPlan(ClearChapterPlan)
    case upsertUpcomingArc(UpsertUpcomingArc)
    case clearUpcomingArc(ClearUpcomingArc)
    case forkBranch(ForkBranch)
    case renameBranch(RenameBranch)
    case deleteBranch(DeleteBranch)
    case undoBranchHead(UndoBranchHead)
    case archiveDiscussion(ArchiveDiscussion)
    case clarifyCharacterIdentity(ClarifyCharacterIdentity)
    case cloneCandidate(CloneCandidate)
    case adoptPolishCandidate(AdoptPolishCandidate)
    case abandonPolishTransaction(AbandonPolishTransaction)
    case restoreChapterVersion(RestoreChapterVersion)
    case discardChapter(ChapterDiscardScope)
    case restoreChapter(ChapterDiscardScope)
    case deleteChapterFromManuscript(DeleteChapterFromManuscript)
    case cancelRun(CancelRun)
    case collectCandidate(CollectCandidate)
    case saveManualEdit(SaveManualEdit)
    case syncManualEdits(SyncManualEdits)
    case retryPending(RetryPending)
    case importProject(ImportProject)
    case restorePreviousProject(RestorePreviousProject)
    case deleteProject(DeleteProject)
}
