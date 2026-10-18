import Foundation

struct NovelChapterRecord: Codable, Equatable, Sendable {
    let id: NovelChapterID
    let createdAt: Date
    /// 非 nil 表示该章已被标记废弃:不参与生成上下文与剧情状态推导,但保留在
    /// 存档里、可以恢复。用可选字段而不是真删,是因为章节版本之间有
    /// `factCompatibilityID` 事实链(见 `NovelCompatibilityLineageValidator`),
    /// 真删中间一章会断链并让后续章节的剧情状态失去依据。
    /// 老存档缺这个键:合成 Codable 对可选属性走 decodeIfPresent,可平滑读入。
    var discardedAt: Date?
}

struct NovelChapterVersionRecord: Codable, Equatable, Sendable {
    let id: NovelChapterVersionID
    let chapterID: NovelChapterID
    let kind: NovelChapterVersionKind
    let title: String
    let content: String
    let factCompatibilityID: UUID
    let sourceChapterVersionID: NovelChapterVersionID?
    let sourceCandidateID: NovelCandidateID?
    let createdAt: Date
    let operationID: NovelOperationID

    init(
        id: NovelChapterVersionID,
        chapterID: NovelChapterID,
        kind: NovelChapterVersionKind,
        title: String,
        content: String,
        factCompatibilityID: UUID,
        sourceChapterVersionID: NovelChapterVersionID? = nil,
        sourceCandidateID: NovelCandidateID?,
        createdAt: Date,
        operationID: NovelOperationID
    ) {
        self.id = id
        self.chapterID = chapterID
        self.kind = kind
        self.title = title
        self.content = content
        self.factCompatibilityID = factCompatibilityID
        self.sourceChapterVersionID = sourceChapterVersionID
        self.sourceCandidateID = sourceCandidateID
        self.createdAt = createdAt
        self.operationID = operationID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case chapterID
        case kind
        case title
        case content
        case factCompatibilityID
        case sourceChapterVersionID
        case sourceCandidateID
        case createdAt
        case operationID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(NovelChapterVersionID.self, forKey: .id)
        chapterID = try values.decode(NovelChapterID.self, forKey: .chapterID)
        kind = try values.decode(NovelChapterVersionKind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        content = try values.decode(String.self, forKey: .content)
        factCompatibilityID = try values.decode(UUID.self, forKey: .factCompatibilityID)
        sourceChapterVersionID = try values.decodeIfPresent(
            NovelChapterVersionID.self,
            forKey: .sourceChapterVersionID
        )
        sourceCandidateID = try values.decodeIfPresent(
            NovelCandidateID.self,
            forKey: .sourceCandidateID
        )
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        operationID = try values.decode(NovelOperationID.self, forKey: .operationID)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(chapterID, forKey: .chapterID)
        try values.encode(kind, forKey: .kind)
        try values.encode(title, forKey: .title)
        try values.encode(content, forKey: .content)
        try values.encode(factCompatibilityID, forKey: .factCompatibilityID)
        try values.encodeIfPresent(sourceChapterVersionID, forKey: .sourceChapterVersionID)
        try values.encodeIfPresent(sourceCandidateID, forKey: .sourceCandidateID)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(operationID, forKey: .operationID)
    }
}

struct NovelChapterSelection: Codable, Equatable, Hashable, Sendable {
    let chapterID: NovelChapterID
    let versionID: NovelChapterVersionID
}

enum NovelChapterText {
    static func appending(_ addition: String, to existing: String) -> String {
        guard !existing.isEmpty else { return addition }
        guard !addition.isEmpty else { return existing }
        return existing + "\n\n" + addition
    }
}

struct NovelStoryEventRecord: Codable, Equatable, Sendable {
    let id: NovelEventID
    let sequence: Int64
    let kind: String
    let summary: String
    let entityReferences: [String]
    let createdAt: Date
}

struct NovelChapterPlotModule: Codable, Equatable, Sendable {
    var chapterID: NovelChapterID
    var text: String
    /// Later chapters after an earlier-chapter edit. Text is kept; injection must
    /// treat it as a stale pointer, not a current commit.
    var stale: Bool

    init(chapterID: NovelChapterID, text: String, stale: Bool = false) {
        self.chapterID = chapterID
        self.text = text
        self.stale = stale
    }

    private enum CodingKeys: String, CodingKey {
        case chapterID
        case text
        case stale
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapterID = try container.decode(NovelChapterID.self, forKey: .chapterID)
        text = try container.decode(String.self, forKey: .text)
        stale = try container.decodeIfPresent(Bool.self, forKey: .stale) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chapterID, forKey: .chapterID)
        try container.encode(text, forKey: .text)
        if stale {
            try container.encode(true, forKey: .stale)
        }
    }
}

struct NovelStateSnapshotRecord: Codable, Equatable, Sendable {
    /// Cap for cross-chapter anti-repeat highlights carried on each snapshot.
    static let maxRecentWrittenHighlights = 24
    /// Cap each highlight line so injection stays beat-sized, not a second manuscript.
    static let maxHighlightCharacterCount = 160

    let id: NovelStateSnapshotID
    let eventIDs: [NovelEventID]
    let summary: String
    let branchOutline: String
    let unresolvedEntityNames: [String]
    let characterIdentityClarifications: [NovelCharacterIdentityClarificationRecord]
    let settingProposalIDs: [NovelProposalID]
    /// Bounded beat list derived from recent story-event summaries for anti-repeat injection.
    let recentWrittenHighlights: [String]
    /// Per-chapter plot exports. `current.md` is the host-linked fold of these modules.
    let chapterPlots: [NovelChapterPlotModule]
    let createdAt: Date

    init(
        id: NovelStateSnapshotID,
        eventIDs: [NovelEventID],
        summary: String,
        branchOutline: String,
        unresolvedEntityNames: [String],
        createdAt: Date,
        settingProposalIDs: [NovelProposalID] = [],
        characterIdentityClarifications: [NovelCharacterIdentityClarificationRecord] = [],
        recentWrittenHighlights: [String] = [],
        chapterPlots: [NovelChapterPlotModule] = []
    ) {
        self.id = id
        self.eventIDs = eventIDs
        self.summary = summary
        self.branchOutline = branchOutline
        self.unresolvedEntityNames = unresolvedEntityNames
        self.characterIdentityClarifications = characterIdentityClarifications
        self.settingProposalIDs = settingProposalIDs
        self.recentWrittenHighlights = Self.normalizedHighlights(recentWrittenHighlights)
        self.chapterPlots = chapterPlots
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case eventIDs
        case summary
        case branchOutline
        case unresolvedEntityNames
        case characterIdentityClarifications
        case settingProposalIDs
        case recentWrittenHighlights
        case chapterPlots
        case createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(NovelStateSnapshotID.self, forKey: .id)
        eventIDs = try container.decode([NovelEventID].self, forKey: .eventIDs)
        summary = try container.decode(String.self, forKey: .summary)
        branchOutline = try container.decode(String.self, forKey: .branchOutline)
        unresolvedEntityNames = try container.decode(
            [String].self,
            forKey: .unresolvedEntityNames
        )
        characterIdentityClarifications = try container.decodeIfPresent(
            [NovelCharacterIdentityClarificationRecord].self,
            forKey: .characterIdentityClarifications
        ) ?? []
        settingProposalIDs = try container.decodeIfPresent(
            [NovelProposalID].self,
            forKey: .settingProposalIDs
        ) ?? []
        recentWrittenHighlights = Self.normalizedHighlights(
            try container.decodeIfPresent([String].self, forKey: .recentWrittenHighlights) ?? []
        )
        chapterPlots = try container.decodeIfPresent(
            [NovelChapterPlotModule].self,
            forKey: .chapterPlots
        ) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(eventIDs, forKey: .eventIDs)
        try container.encode(summary, forKey: .summary)
        try container.encode(branchOutline, forKey: .branchOutline)
        try container.encode(unresolvedEntityNames, forKey: .unresolvedEntityNames)
        try container.encode(
            characterIdentityClarifications,
            forKey: .characterIdentityClarifications
        )
        try container.encode(settingProposalIDs, forKey: .settingProposalIDs)
        try container.encode(recentWrittenHighlights, forKey: .recentWrittenHighlights)
        if !chapterPlots.isEmpty {
            try container.encode(chapterPlots, forKey: .chapterPlots)
        }
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// Merge prior highlights with new event summaries; keep the newest capped window.
    static func mergedHighlights(
        prior: [String],
        newEventSummaries: [String]
    ) -> [String] {
        normalizedHighlights(prior + newEventSummaries)
    }

    static func normalizedHighlights(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let clipped: String
            if trimmed.count > maxHighlightCharacterCount {
                clipped = String(trimmed.prefix(maxHighlightCharacterCount))
            } else {
                clipped = trimmed
            }
            let key = clipped.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(clipped)
        }
        if result.count > maxRecentWrittenHighlights {
            return Array(result.suffix(maxRecentWrittenHighlights))
        }
        return result
    }

    func injectionHighlightsText() -> String {
        let source: [(text: String, stale: Bool)]
        if chapterPlots.isEmpty {
            source = recentWrittenHighlights.map { (text: $0, stale: false) }
        } else {
            source = chapterPlots
                .suffix(Self.maxRecentWrittenHighlights)
                .map { (text: $0.text, stale: $0.stale) }
        }
        return source.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return item.stale ? "- \(text)（后续可能过期）" : "- \(text)"
        }.joined(separator: "\n")
    }

    var hasStaleChapterPlots: Bool {
        chapterPlots.contains(where: \.stale)
    }
}

enum NovelSessionCursor: Codable, Equatable, Sendable {
    case empty
    case through(sequence: Int64)
}

struct NovelBranchCheckpointRecord: Codable, Equatable, Sendable {
    let id: NovelCheckpointID
    let kind: NovelCheckpointKind
    let createdOnBranchID: NovelBranchID
    let parentCheckpointID: NovelCheckpointID?
    let chapterSelections: [NovelChapterSelection]
    let stateSnapshotID: NovelStateSnapshotID
    let sessionCursor: NovelSessionCursor
    let branchOverrideRevisionIDs: [NovelMaterialRevisionID]
    let sourceCandidateID: NovelCandidateID?
    let baseHeadRevision: Int64
    let operationID: NovelOperationID
    let createdAt: Date
}

enum NovelFactReceiptKind: String, Codable, Equatable, Sendable {
    case stateDelta
    case manualRebuild
}

struct NovelFactReceiptLink: Codable, Equatable, Sendable {
    let pendingID: NovelPendingOperationID
    let ownerOperationID: NovelOperationID
    let attemptOperationID: NovelOperationID
    let attemptPayloadSHA256: String
    let kind: NovelFactReceiptKind
    let chunkIndex: Int?

    init(
        pendingID: NovelPendingOperationID,
        ownerOperationID: NovelOperationID,
        attemptOperationID: NovelOperationID,
        attemptPayloadSHA256: String,
        kind: NovelFactReceiptKind,
        chunkIndex: Int? = nil
    ) {
        self.pendingID = pendingID
        self.ownerOperationID = ownerOperationID
        self.attemptOperationID = attemptOperationID
        self.attemptPayloadSHA256 = attemptPayloadSHA256
        self.kind = kind
        self.chunkIndex = chunkIndex
    }
}
