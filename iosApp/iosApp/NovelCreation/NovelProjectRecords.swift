import Foundation

struct NovelProjectRecord: Codable, Equatable, Sendable {
    let id: NovelProjectID
    var name: String
    let creationMode: NovelProjectCreationMode
    let quickStartSeed: NovelQuickStartSeed?
    let createdAt: Date
    var updatedAt: Date
    var revision: Int64
    var configRevision: Int64
    var mainBranchID: NovelBranchID
    var modelPolicy: NovelProjectModelPolicy
    var stateSyncModelPolicy: NovelProjectModelPolicy?
    var reviewModelPolicy: NovelProjectModelPolicy?
    var lastGenerationGranularity: NovelGenerationGranularity
    var polishPreference: String
    var collaborationMode: NovelCollaborationMode
    /// 代笔：连续性检查出现 blocking（界面「严重」）时暂停自动收录。默认开启。
    var pauseGhostwriteOnBlockingContinuity: Bool

    init(
        id: NovelProjectID,
        name: String,
        creationMode: NovelProjectCreationMode,
        quickStartSeed: NovelQuickStartSeed?,
        createdAt: Date,
        updatedAt: Date,
        revision: Int64,
        configRevision: Int64,
        mainBranchID: NovelBranchID,
        modelPolicy: NovelProjectModelPolicy,
        stateSyncModelPolicy: NovelProjectModelPolicy?,
        lastGenerationGranularity: NovelGenerationGranularity,
        polishPreference: String,
        collaborationMode: NovelCollaborationMode = .cocreation,
        pauseGhostwriteOnBlockingContinuity: Bool = true,
        reviewModelPolicy: NovelProjectModelPolicy? = nil
    ) {
        self.id = id
        self.name = name
        self.creationMode = creationMode
        self.quickStartSeed = quickStartSeed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.configRevision = configRevision
        self.mainBranchID = mainBranchID
        self.modelPolicy = modelPolicy
        self.stateSyncModelPolicy = stateSyncModelPolicy
        self.reviewModelPolicy = reviewModelPolicy
        self.lastGenerationGranularity = lastGenerationGranularity
        self.polishPreference = polishPreference
        self.collaborationMode = collaborationMode
        self.pauseGhostwriteOnBlockingContinuity = pauseGhostwriteOnBlockingContinuity
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case creationMode
        case quickStartSeed
        case createdAt
        case updatedAt
        case revision
        case configRevision
        case mainBranchID
        case modelPolicy
        case stateSyncModelPolicy
        case reviewModelPolicy
        case lastGenerationGranularity
        case polishPreference
        case collaborationMode
        case pauseGhostwriteOnBlockingContinuity
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(NovelProjectID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        creationMode = try values.decode(NovelProjectCreationMode.self, forKey: .creationMode)
        quickStartSeed = try values.decodeIfPresent(NovelQuickStartSeed.self, forKey: .quickStartSeed)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        revision = try values.decode(Int64.self, forKey: .revision)
        configRevision = try values.decode(Int64.self, forKey: .configRevision)
        mainBranchID = try values.decode(NovelBranchID.self, forKey: .mainBranchID)
        modelPolicy = try values.decode(NovelProjectModelPolicy.self, forKey: .modelPolicy)
        stateSyncModelPolicy = try values.decodeIfPresent(
            NovelProjectModelPolicy.self,
            forKey: .stateSyncModelPolicy
        )
        reviewModelPolicy = try values.decodeIfPresent(
            NovelProjectModelPolicy.self,
            forKey: .reviewModelPolicy
        )
        lastGenerationGranularity = try values.decode(
            NovelGenerationGranularity.self,
            forKey: .lastGenerationGranularity
        )
        polishPreference = try values.decode(String.self, forKey: .polishPreference)
        collaborationMode = try values.decodeIfPresent(
            NovelCollaborationMode.self,
            forKey: .collaborationMode
        ) ?? .cocreation
        pauseGhostwriteOnBlockingContinuity = try values.decodeIfPresent(
            Bool.self,
            forKey: .pauseGhostwriteOnBlockingContinuity
        ) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(creationMode, forKey: .creationMode)
        try values.encodeIfPresent(quickStartSeed, forKey: .quickStartSeed)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(revision, forKey: .revision)
        try values.encode(configRevision, forKey: .configRevision)
        try values.encode(mainBranchID, forKey: .mainBranchID)
        try values.encode(modelPolicy, forKey: .modelPolicy)
        try values.encodeIfPresent(stateSyncModelPolicy, forKey: .stateSyncModelPolicy)
        try values.encodeIfPresent(reviewModelPolicy, forKey: .reviewModelPolicy)
        try values.encode(lastGenerationGranularity, forKey: .lastGenerationGranularity)
        try values.encode(polishPreference, forKey: .polishPreference)
        try values.encode(collaborationMode, forKey: .collaborationMode)
        try values.encode(
            pauseGhostwriteOnBlockingContinuity,
            forKey: .pauseGhostwriteOnBlockingContinuity
        )
    }

    func configuredModelPolicy(for purpose: NovelModelRole) -> NovelProjectModelPolicy {
        switch purpose {
        case .creation: modelPolicy
        case .stateSync: stateSyncModelPolicy ?? .global
        case .review: reviewModelPolicy ?? .global
        }
    }
}

struct NovelMaterialRecord: Codable, Equatable, Sendable {
    let id: NovelMaterialID
    let kind: NovelMaterialKind
    var currentRevisionID: NovelMaterialRevisionID
    var revisionIDs: [NovelMaterialRevisionID]
    var isDeleted: Bool
    var aliases: [String]

    init(
        id: NovelMaterialID,
        kind: NovelMaterialKind,
        currentRevisionID: NovelMaterialRevisionID,
        revisionIDs: [NovelMaterialRevisionID],
        isDeleted: Bool = false,
        aliases: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.currentRevisionID = currentRevisionID
        self.revisionIDs = revisionIDs
        self.isDeleted = isDeleted
        self.aliases = NovelCharacterIdentityResolver.normalizedAliases(aliases)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case currentRevisionID
        case revisionIDs
        case isDeleted
        case aliases
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(NovelMaterialID.self, forKey: .id)
        kind = try values.decode(NovelMaterialKind.self, forKey: .kind)
        currentRevisionID = try values.decode(
            NovelMaterialRevisionID.self,
            forKey: .currentRevisionID
        )
        revisionIDs = try values.decode([NovelMaterialRevisionID].self, forKey: .revisionIDs)
        isDeleted = try values.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        aliases = NovelCharacterIdentityResolver.normalizedAliases(
            try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(currentRevisionID, forKey: .currentRevisionID)
        try values.encode(revisionIDs, forKey: .revisionIDs)
        try values.encode(isDeleted, forKey: .isDeleted)
        try values.encode(aliases, forKey: .aliases)
    }
}
