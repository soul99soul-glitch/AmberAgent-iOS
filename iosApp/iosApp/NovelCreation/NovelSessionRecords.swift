import Foundation

struct NovelMaterialRevisionRecord: Codable, Equatable, Sendable {
    let id: NovelMaterialRevisionID
    let materialID: NovelMaterialID
    let revision: Int64
    let title: String
    let content: String
    let tags: [String]
    let injectionMode: NovelInjectionMode
    let createdAt: Date
    let operationID: NovelOperationID
}

struct NovelForkOrigin: Codable, Equatable, Sendable {
    let parentBranchID: NovelBranchID
    let checkpointID: NovelCheckpointID
}

struct NovelCharacterIdentityClarificationRecord: Codable, Equatable, Sendable {
    let mention: String
    let clarification: String
    let operationID: NovelOperationID
    let createdAt: Date
}

struct NovelBranchRecord: Codable, Equatable, Sendable {
    let id: NovelBranchID
    var name: String
    let sessionID: NovelSessionID
    let createdAt: Date
    var updatedAt: Date
    var forkOrigin: NovelForkOrigin?
    var headCheckpointID: NovelCheckpointID
    var currentStateSnapshotID: NovelStateSnapshotID
    var headRevision: Int64
    var workingRevision: Int64
    var syncStatus: NovelBranchSyncStatus
    var lifecycle: NovelBranchLifecycle
    var overrideRevisionIDs: [NovelMaterialRevisionID]
    var workingChapterSelections: [NovelChapterSelection]
    var activeRunID: NovelRunID?
}

struct NovelDiscussionArchiveRecord: Codable, Equatable, Sendable {
    let id: NovelMessageID
    let checkpointID: NovelCheckpointID
    let throughSequence: Int64
    let messageCount: Int
    let chapterID: NovelChapterID?
    let summary: String
    let createdAt: Date
}

struct NovelSessionRecord: Codable, Equatable, Sendable {
    let id: NovelSessionID
    let branchID: NovelBranchID
    var revision: Int64
    var messages: [NovelSessionMessageRecord]
    var archiveCursor: NovelSessionCursor? = nil
    var discussionArchives: [NovelDiscussionArchiveRecord]? = nil
}

struct NovelSessionMessageRecord: Codable, Equatable, Sendable {
    let id: NovelMessageID
    let sequence: Int64
    let role: NovelSessionRole
    let mode: NovelSessionMode
    let kind: NovelSessionMessageKind
    let content: String
    let createdAt: Date
    let runID: NovelRunID?
    let candidateID: NovelCandidateID?
    let interaction: NovelSessionInteraction?

    init(
        id: NovelMessageID,
        sequence: Int64,
        role: NovelSessionRole,
        mode: NovelSessionMode,
        kind: NovelSessionMessageKind,
        content: String,
        createdAt: Date,
        runID: NovelRunID?,
        candidateID: NovelCandidateID?,
        interaction: NovelSessionInteraction? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.role = role
        self.mode = mode
        self.kind = kind
        self.content = content
        self.createdAt = createdAt
        self.runID = runID
        self.candidateID = candidateID
        self.interaction = interaction
    }
}

struct NovelCandidateRecord: Codable, Equatable, Sendable {
    let id: NovelCandidateID
    let kind: NovelCandidateKind
    let branchID: NovelBranchID
    let sessionID: NovelSessionID
    let sourceMessageID: NovelMessageID
    let baseCheckpointID: NovelCheckpointID
    let baseHeadRevision: Int64
    var status: NovelCandidateStatus
    let content: String
    let sourceChapterVersionID: NovelChapterVersionID?
    let clonedFromCandidateID: NovelCandidateID?
    var collectedCheckpointID: NovelCheckpointID?
    /// Digest of the confirmed chapter plan bound when this prose candidate was generated.
    /// Nil for legacy candidates and non-prose kinds. Collect rejects a mismatch.
    let chapterPlanDigest: String?
    /// Set only for candidates produced by the ghostwrite pipeline.
    let ghostwritePlanID: NovelChapterPlanID?
    /// The source run may be pruned at quiet rest; collection still needs its original intent.
    let generationGranularity: NovelGenerationGranularity?
    let createdAt: Date

    init(
        id: NovelCandidateID,
        kind: NovelCandidateKind,
        branchID: NovelBranchID,
        sessionID: NovelSessionID,
        sourceMessageID: NovelMessageID,
        baseCheckpointID: NovelCheckpointID,
        baseHeadRevision: Int64,
        status: NovelCandidateStatus,
        content: String,
        sourceChapterVersionID: NovelChapterVersionID?,
        clonedFromCandidateID: NovelCandidateID? = nil,
        collectedCheckpointID: NovelCheckpointID?,
        chapterPlanDigest: String? = nil,
        ghostwritePlanID: NovelChapterPlanID? = nil,
        generationGranularity: NovelGenerationGranularity? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.branchID = branchID
        self.sessionID = sessionID
        self.sourceMessageID = sourceMessageID
        self.baseCheckpointID = baseCheckpointID
        self.baseHeadRevision = baseHeadRevision
        self.status = status
        self.content = content
        self.sourceChapterVersionID = sourceChapterVersionID
        self.clonedFromCandidateID = clonedFromCandidateID
        self.collectedCheckpointID = collectedCheckpointID
        self.chapterPlanDigest = chapterPlanDigest
        self.ghostwritePlanID = ghostwritePlanID
        self.generationGranularity = generationGranularity
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case branchID
        case sessionID
        case sourceMessageID
        case baseCheckpointID
        case baseHeadRevision
        case status
        case content
        case sourceChapterVersionID
        case clonedFromCandidateID
        case collectedCheckpointID
        case chapterPlanDigest
        case ghostwritePlanID
        case generationGranularity
        case createdAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(NovelCandidateID.self, forKey: .id)
        kind = try values.decode(NovelCandidateKind.self, forKey: .kind)
        branchID = try values.decode(NovelBranchID.self, forKey: .branchID)
        sessionID = try values.decode(NovelSessionID.self, forKey: .sessionID)
        sourceMessageID = try values.decode(NovelMessageID.self, forKey: .sourceMessageID)
        baseCheckpointID = try values.decode(NovelCheckpointID.self, forKey: .baseCheckpointID)
        baseHeadRevision = try values.decode(Int64.self, forKey: .baseHeadRevision)
        status = try values.decode(NovelCandidateStatus.self, forKey: .status)
        content = try values.decode(String.self, forKey: .content)
        sourceChapterVersionID = try values.decodeIfPresent(
            NovelChapterVersionID.self,
            forKey: .sourceChapterVersionID
        )
        clonedFromCandidateID = try values.decodeIfPresent(
            NovelCandidateID.self,
            forKey: .clonedFromCandidateID
        )
        collectedCheckpointID = try values.decodeIfPresent(
            NovelCheckpointID.self,
            forKey: .collectedCheckpointID
        )
        chapterPlanDigest = try values.decodeIfPresent(String.self, forKey: .chapterPlanDigest)
        ghostwritePlanID = try values.decodeIfPresent(NovelChapterPlanID.self, forKey: .ghostwritePlanID)
        generationGranularity = try values.decodeIfPresent(
            NovelGenerationGranularity.self,
            forKey: .generationGranularity
        )
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}
