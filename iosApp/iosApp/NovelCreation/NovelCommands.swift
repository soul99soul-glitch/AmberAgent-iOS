import Foundation

struct NovelMutationContext: Codable, Equatable, Sendable {
    let operationID: NovelOperationID
    let expectedProjectRevision: Int64?
    let expectedConfigRevision: Int64?
    let expectedBranchHeadRevision: Int64?
    var approvalResponse: NovelAskUserResponse? = nil
}

struct NovelCreateProjectCommand: Equatable, Sendable {
    let context: NovelMutationContext
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

struct NovelRenameProjectCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let name: String
}

struct NovelReviseMaterialCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let materialID: NovelMaterialID
    let revisionID: NovelMaterialRevisionID
    let kind: NovelMaterialKind
    let title: String
    let content: String
    let tags: [String]
    let injectionMode: NovelInjectionMode
    let aliases: [String]

    init(
        context: NovelMutationContext,
        projectID: NovelProjectID,
        materialID: NovelMaterialID,
        revisionID: NovelMaterialRevisionID,
        kind: NovelMaterialKind,
        title: String,
        content: String,
        tags: [String],
        injectionMode: NovelInjectionMode,
        aliases: [String] = []
    ) {
        self.context = context
        self.projectID = projectID
        self.materialID = materialID
        self.revisionID = revisionID
        self.kind = kind
        self.title = title
        self.content = content
        self.tags = tags
        self.injectionMode = injectionMode
        self.aliases = aliases
    }
}

struct NovelDeleteMaterialCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let materialID: NovelMaterialID
}

struct NovelSetModelPolicyCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let purpose: NovelModelRole
    let policy: NovelProjectModelPolicy

    init(
        context: NovelMutationContext,
        projectID: NovelProjectID,
        purpose: NovelModelRole = .creation,
        policy: NovelProjectModelPolicy
    ) {
        self.context = context
        self.projectID = projectID
        self.purpose = purpose
        self.policy = policy
    }
}

enum NovelSettingProposalResolution: Codable, Equatable, Sendable {
    case accept(
        materialID: NovelMaterialID,
        revisionID: NovelMaterialRevisionID,
        kind: NovelMaterialKind,
        title: String,
        content: String,
        tags: [String],
        injectionMode: NovelInjectionMode,
        aliases: [String]
    )
    case reject
}

struct NovelResolveSettingProposalCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let proposalID: NovelProposalID
    let resolution: NovelSettingProposalResolution
}

enum NovelBranchMaterialOverrideChange: Codable, Equatable, Sendable {
    case inherit
    case useRevision(NovelMaterialRevisionID)
    case createRevision(
        revisionID: NovelMaterialRevisionID,
        title: String,
        content: String,
        tags: [String],
        injectionMode: NovelInjectionMode
    )
}

struct NovelSetBranchMaterialOverrideCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let materialID: NovelMaterialID
    let change: NovelBranchMaterialOverrideChange
}

struct NovelSetMainBranchCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
}

struct NovelSetPolishPreferenceCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let preference: String
}

struct NovelSetCollaborationModeCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let mode: NovelCollaborationMode
}

struct NovelSetPauseGhostwriteOnBlockingContinuityCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let enabled: Bool
}

struct NovelUpsertChapterPlanCommand: Equatable, Sendable {
    let context: NovelMutationContext
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

struct NovelClearChapterPlanCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
}

struct NovelUpsertUpcomingArcCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let beats: [String]
}

struct NovelClearUpcomingArcCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
}

struct NovelForkBranchCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let sourceBranchID: NovelBranchID
    let checkpointID: NovelCheckpointID
    let branchID: NovelBranchID
    let sessionID: NovelSessionID
    let name: String
}

struct NovelRenameBranchCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let name: String
}

struct NovelDeleteBranchCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
}

struct NovelUndoBranchHeadCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let expectedWorkingRevision: Int64
}

struct NovelConfirmedDiscussionDecision: Codable, Equatable, Sendable {
    let materialID: NovelMaterialID
    let revisionID: NovelMaterialRevisionID
    let topic: String
    let decision: String
    let relatedMaterialID: NovelMaterialID?
}

struct NovelArchiveDiscussionCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let archiveID: NovelMessageID
    let checkpointID: NovelCheckpointID
    let throughSequence: Int64
    let chapterID: NovelChapterID?
    let summary: String
    let decisions: [NovelConfirmedDiscussionDecision]
}

struct NovelClarifyCharacterIdentityCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let checkpointID: NovelCheckpointID
    let stateSnapshotID: NovelStateSnapshotID
    let mention: String
    let clarification: String
}

struct NovelCloneCandidateCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let sourceCandidateID: NovelCandidateID
    let candidateID: NovelCandidateID
}

struct NovelAdoptPolishCandidateCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let transactionID: NovelPendingOperationID
    let candidateID: NovelCandidateID
    let proposedChapterVersionID: NovelChapterVersionID
    let checkpointID: NovelCheckpointID
    let expectedWorkingRevision: Int64
}

struct NovelAbandonPolishTransactionCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let transactionID: NovelPendingOperationID
}

/// 标记废弃 / 恢复某一章。不删除任何记录:章节版本之间有事实兼容链,
/// 真删会断链。废弃后该章不参与生成上下文与剧情状态推导。
struct NovelDiscardChapterCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let chapterID: NovelChapterID
}

struct NovelRestoreChapterCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let chapterID: NovelChapterID
}

/// 从当前分支正文目录移除一章。不物理抹掉章节版本/检查点引用（历史可追溯），
/// 但工作稿不再包含该章；目录与生成上下文都会消失。同时确保章被标为废弃。
struct NovelDeleteChapterFromManuscriptCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let chapterID: NovelChapterID
    let expectedWorkingRevision: Int64
}

struct NovelRestoreChapterVersionCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let targetChapterVersionID: NovelChapterVersionID
    let proposedChapterVersionID: NovelChapterVersionID
    let checkpointID: NovelCheckpointID
    let expectedWorkingRevision: Int64
}

struct NovelCancelRunCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let runID: NovelRunID
    let reason: NovelRunInterruptionReason
}

enum NovelCollectionSource: String, Codable, Equatable, Sendable {
    case user
    case systemAutoCollect
}

struct NovelCollectCandidateCommand: Equatable, Sendable {
    let context: NovelMutationContext
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
    /// Who initiated collect. Defaults to `.user` for sheets; ghostwrite pipeline uses
    /// `.systemAutoCollect` and requires a matching chapter-plan digest.
    var source: NovelCollectionSource = .user
}

struct NovelSaveManualEditCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let chapterID: NovelChapterID
    let versionID: NovelChapterVersionID
    let title: String
    let content: String
    let factCompatibilityID: UUID
    let expectedWorkingRevision: Int64
}

struct NovelSyncManualEditsCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let pendingID: NovelPendingOperationID
    let checkpointID: NovelCheckpointID
    let stateSnapshotID: NovelStateSnapshotID
    let expectedWorkingRevision: Int64
    /// Call-site only. Not part of the durable payload hash.
    var preferStateDelta: Bool = false
}

struct NovelRetryPendingCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let pendingID: NovelPendingOperationID
}

struct NovelImportProjectCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
    let packageData: Data
    let policy: NovelProjectImportPolicy
}

struct NovelInjectionPreviewRequest: Equatable, Sendable {
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let kind: NovelRunKind
    let mode: NovelSessionMode
    let granularity: NovelGenerationGranularity?
    let userText: String
    let sourceChapterVersionID: NovelChapterVersionID?
    let injectionOverrides: NovelInjectionOverrides
    let inputBudgetTokens: Int
}

struct NovelInjectionPreviewSnapshot: Equatable, Sendable {
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let projectRevision: Int64
    let configRevision: Int64
    let branchHeadRevision: Int64
    let resolvedModel: NovelResolvedModel
    let parameters: NovelModelParameters
    let requestedInputBudgetTokens: Int
    let effectiveInputBudgetTokens: Int
    let plan: NovelInjectionPlan
}

struct NovelDeleteProjectCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
}

struct NovelRestorePreviousProjectCommand: Equatable, Sendable {
    let context: NovelMutationContext
    let projectID: NovelProjectID
}
