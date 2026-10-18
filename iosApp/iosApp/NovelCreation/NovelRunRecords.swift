import Foundation

struct NovelGenerationReceiptRecord: Codable, Equatable, Sendable {
    let id: NovelReceiptID
    let runID: NovelRunID
    /// Effective transport provider UUID.
    let providerID: String
    /// Provider UUID that owns the selected model in project settings.
    let ownerProviderID: String
    let modelID: String
    let wireModelID: String
    let promptVersion: String
    let injectionReceiptID: NovelReceiptID
    let parameters: [String: String]
    let requestSHA256: String
    let createdAt: Date
    let factTransaction: NovelFactReceiptLink?

    init(
        id: NovelReceiptID,
        runID: NovelRunID,
        providerID: String,
        ownerProviderID: String? = nil,
        modelID: String,
        wireModelID: String? = nil,
        promptVersion: String,
        injectionReceiptID: NovelReceiptID,
        parameters: [String: String],
        requestSHA256: String,
        createdAt: Date,
        factTransaction: NovelFactReceiptLink? = nil
    ) {
        self.id = id
        self.runID = runID
        self.providerID = providerID
        self.ownerProviderID = ownerProviderID ?? providerID
        self.modelID = modelID
        self.wireModelID = wireModelID ?? modelID
        self.promptVersion = promptVersion
        self.injectionReceiptID = injectionReceiptID
        self.parameters = parameters
        self.requestSHA256 = requestSHA256
        self.createdAt = createdAt
        self.factTransaction = factTransaction
    }
}

struct NovelActiveRunRecord: Codable, Equatable, Sendable {
    let id: NovelRunID
    let operationID: NovelOperationID
    let requestPayloadSHA256: String
    let branchID: NovelBranchID
    let sessionID: NovelSessionID
    let kind: NovelRunKind
    let mode: NovelSessionMode
    let granularity: NovelGenerationGranularity?
    let userMessageID: NovelMessageID
    let messageID: NovelMessageID
    let candidateID: NovelCandidateID?
    let sourceChapterVersionID: NovelChapterVersionID?
    /// The unresolved surface name owned by a contextual character-proposal run.
    /// Nil for every legacy run kind and for documents written before this field existed.
    let contextualCharacterMention: String?
    let baseCheckpointID: NovelCheckpointID
    let baseHeadRevision: Int64
    var status: NovelRunStatus
    var partialContent: String
    let receiptID: NovelReceiptID
    let startedAt: Date
    var terminalAt: Date?
    var interruptionReason: NovelRunInterruptionReason?
    var terminalFailure: NovelFailure?
    /// Confirmed chapter-plan digest captured at run begin for whole-chapter prose.
    /// Bound onto the resulting candidate so collect can reject stale drafts.
    let chapterPlanDigest: String?
    /// Non-nil only when this run is owned by the ghostwrite pipeline.
    var ghostwritePlanID: NovelChapterPlanID? = nil
}

struct NovelRecoverySidecarV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let projectID: NovelProjectID
    let runID: NovelRunID
    let branchID: NovelBranchID
    let sessionID: NovelSessionID
    let messageID: NovelMessageID
    let baseProjectRevision: Int64
    let sequence: Int64
    let partialContent: String
    let partialSHA256: String
    let updatedAt: Date
    /// First-party OpenAI Responses cursor. Both values are either present
    /// together or absent; older sidecars decode as the non-resumable form.
    let responseID: String?
    let responseSequenceNumber: Int64?

    init(
        schemaVersion: Int,
        projectID: NovelProjectID,
        runID: NovelRunID,
        branchID: NovelBranchID,
        sessionID: NovelSessionID,
        messageID: NovelMessageID,
        baseProjectRevision: Int64,
        sequence: Int64,
        partialContent: String,
        partialSHA256: String,
        updatedAt: Date,
        responseID: String? = nil,
        responseSequenceNumber: Int64? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.runID = runID
        self.branchID = branchID
        self.sessionID = sessionID
        self.messageID = messageID
        self.baseProjectRevision = baseProjectRevision
        self.sequence = sequence
        self.partialContent = partialContent
        self.partialSHA256 = partialSHA256
        self.updatedAt = updatedAt
        self.responseID = responseID
        self.responseSequenceNumber = responseSequenceNumber
    }
}

struct NovelPendingOperationRecord: Codable, Equatable, Sendable {
    let id: NovelPendingOperationID
    let kind: NovelPendingOperationKind
    var status: NovelPendingOperationStatus
    let branchID: NovelBranchID
    let operationID: NovelOperationID
    let payloadSHA256: String
    let baseCheckpointID: NovelCheckpointID
    let baseHeadRevision: Int64
    let baseWorkingRevision: Int64
    let candidateID: NovelCandidateID?
    let collectionTarget: NovelCollectionTarget?
    let selectedText: String
    let proposedChapterVersion: NovelChapterVersionRecord?
    let proposedCheckpointID: NovelCheckpointID?
    let proposedStateSnapshotID: NovelStateSnapshotID?
    let rebuildBaseCheckpointID: NovelCheckpointID?
    let sessionCursor: NovelSessionCursor?
    var manualSyncProgress: NovelManualSyncProgress?
    let createdAt: Date
    var lastError: String?

    init(
        id: NovelPendingOperationID,
        kind: NovelPendingOperationKind,
        status: NovelPendingOperationStatus,
        branchID: NovelBranchID,
        operationID: NovelOperationID,
        payloadSHA256: String,
        baseCheckpointID: NovelCheckpointID,
        baseHeadRevision: Int64,
        baseWorkingRevision: Int64 = 0,
        candidateID: NovelCandidateID?,
        collectionTarget: NovelCollectionTarget?,
        selectedText: String,
        proposedChapterVersion: NovelChapterVersionRecord?,
        proposedCheckpointID: NovelCheckpointID? = nil,
        proposedStateSnapshotID: NovelStateSnapshotID? = nil,
        rebuildBaseCheckpointID: NovelCheckpointID? = nil,
        sessionCursor: NovelSessionCursor? = nil,
        manualSyncProgress: NovelManualSyncProgress? = nil,
        createdAt: Date,
        lastError: String?
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.branchID = branchID
        self.operationID = operationID
        self.payloadSHA256 = payloadSHA256
        self.baseCheckpointID = baseCheckpointID
        self.baseHeadRevision = baseHeadRevision
        self.baseWorkingRevision = baseWorkingRevision
        self.candidateID = candidateID
        self.collectionTarget = collectionTarget
        self.selectedText = selectedText
        self.proposedChapterVersion = proposedChapterVersion
        self.proposedCheckpointID = proposedCheckpointID
        self.proposedStateSnapshotID = proposedStateSnapshotID
        self.rebuildBaseCheckpointID = rebuildBaseCheckpointID
        self.sessionCursor = sessionCursor
        self.manualSyncProgress = manualSyncProgress
        self.createdAt = createdAt
        self.lastError = lastError
    }

    var blocksProseGeneration: Bool {
        kind != .manualSync || status != .retryable
    }
}

enum NovelSettingProposalOrigin: Codable, Equatable, Sendable {
    case derivedState
    case quickStart(runID: NovelRunID, suggestedKind: NovelMaterialKind)
    case contextualCharacter(
        runID: NovelRunID,
        sourceMention: String,
        suggestedKind: NovelMaterialKind
    )
}

struct NovelSettingProposalRecord: Codable, Equatable, Sendable {
    let id: NovelProposalID
    let branchID: NovelBranchID
    let title: String
    let content: String
    let createdAt: Date
    var isResolved: Bool
    var supersededByRunID: NovelRunID?
    let origin: NovelSettingProposalOrigin?
    let suggestedCharacterAliases: [String]?

    init(
        id: NovelProposalID,
        branchID: NovelBranchID,
        title: String,
        content: String,
        createdAt: Date,
        isResolved: Bool,
        supersededByRunID: NovelRunID? = nil,
        origin: NovelSettingProposalOrigin? = nil,
        suggestedCharacterAliases: [String]? = nil
    ) {
        self.id = id
        self.branchID = branchID
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.isResolved = isResolved
        self.supersededByRunID = supersededByRunID
        self.origin = origin
        self.suggestedCharacterAliases = suggestedCharacterAliases
    }
}

/// Opaque workspace content that iOS does not interpret but must preserve
/// across import/export round trips. Novel workspace core contract v1.1 §3.6:
/// unknown frontmatter fields and unknown files pass through, never dropped
/// (Android node extensions such as `status`/`relations`/foreshadowing would
/// otherwise be lost on an Android→iOS→Android round trip).
struct NovelWorkspacePassthroughRecord: Codable, Equatable, Sendable {
    /// Raw frontmatter lines kept verbatim, keyed by the anchor id used at
    /// export time: bare entity ids for materials/chapters/proposals, and
    /// role-prefixed ids for files that share an entity (e.g.
    /// `project:<id>`, `branch:<id>`, `upcoming:<id>`, `plot-current:<id>`).
    var frontmatterExtensions: [String: [String]]
    /// Tree-relative path → raw file contents for files iOS has no semantic
    /// mapping for (foreshadowing nodes, unknown directories, drafts, …).
    var opaqueFiles: [String: String]

    static let empty = NovelWorkspacePassthroughRecord(
        frontmatterExtensions: [:],
        opaqueFiles: [:]
    )

    var isEmpty: Bool {
        frontmatterExtensions.isEmpty && opaqueFiles.isEmpty
    }
}

enum NovelOperationKind: String, Codable, Sendable {
    case createProject
    case renameProject
    case reviseMaterial
    case deleteMaterial
    case setModelPolicy
    case resolveSettingProposal
    case setBranchMaterialOverride
    case setMainBranch
    case setPolishPreference
    case setCollaborationMode
    case setPauseGhostwriteOnBlockingContinuity
    case upsertChapterPlan
    case clearChapterPlan
    case upsertUpcomingArc
    case clearUpcomingArc
    case forkBranch
    case renameBranch
    case deleteBranch
    case undoBranchHead
    case archiveDiscussion
    case clarifyCharacterIdentity
    case cloneCandidate
    case adoptPolishCandidate
    case abandonPolishTransaction
    case restoreChapterVersion
    case discardChapter
    case restoreChapter
    case deleteChapterFromManuscript
    case startRun
    case cancelRun
    case collectCandidate
    case saveManualEdit
    case syncManualEdits
    case workspacePlot
    case retryPending
    case importProject
    case restorePreviousProject
    case deleteProject
}

struct NovelAppliedOperationRecord: Codable, Equatable, Sendable {
    let operationID: NovelOperationID
    let kind: NovelOperationKind
    let payloadSHA256: String
    let outcome: NovelOutcome
    let appliedProjectRevision: Int64
    let appliedAt: Date
}
