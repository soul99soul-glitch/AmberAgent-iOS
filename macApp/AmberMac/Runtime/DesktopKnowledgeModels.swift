import Foundation

struct DesktopSkill: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    let allowedTools: [String]
    let markdown: String
    let enabled: Bool
}

enum DesktopMemoryScope: String, Codable, CaseIterable, Sendable {
    case core, shortTerm = "short_term", longTerm = "long_term"
    var title: String { switch self { case .core: "核心"; case .shortTerm: "短期"; case .longTerm: "长期" } }
    var assistantID: String { switch self { case .core: "__global__"; case .shortTerm: "__short_term__"; case .longTerm: "__long_term__" } }
}

enum DesktopMemoryKind: String, Codable, CaseIterable, Sendable {
    case user, feedback, project, reference, routine, note, topic
    var title: String {
        switch self { case .user: "偏好"; case .feedback: "反馈"; case .project: "项目"; case .reference: "资料"; case .routine: "习惯"; case .note: "笔记"; case .topic: "主题" }
    }
}

// Field names and wire values match iOS PersistedMemoryRecord and KMP MemoryRecord.
struct DesktopMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    var id: Int = 0
    var content: String
    var scope: DesktopMemoryScope = .longTerm
    var kind: DesktopMemoryKind = .note
    var assistantId = "__long_term__"
    var sourceConversationId: String?
    var sourceMessageIds: [String] = []
    var supersedesIds: [Int] = []
    var expiresAt: Int64?
    var confidence: Double = 1
    var pinned = false
    var archived = false
    var createdAt: Int64 = 0
    var updatedAt: Int64 = 0
    var lastUsedAt: Int64?
    var topicTitle: String?
    var memberIds: [Int] = []
    var lastReinforcedAt: Int64?

    init(content: String, scope: DesktopMemoryScope = .longTerm, kind: DesktopMemoryKind = .note) {
        self.content = content
        self.scope = scope
        self.kind = kind
        assistantId = scope.assistantID
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, scope, kind, assistantId, sourceConversationId, sourceMessageIds, supersedesIds,
             expiresAt, confidence, pinned, archived, createdAt, updatedAt, lastUsedAt, topicTitle, memberIds, lastReinforcedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        scope = try c.decode(DesktopMemoryScope.self, forKey: .scope)
        kind = try c.decode(DesktopMemoryKind.self, forKey: .kind)
        assistantId = try c.decode(String.self, forKey: .assistantId)
        sourceConversationId = try c.decodeIfPresent(String.self, forKey: .sourceConversationId)
        sourceMessageIds = try c.decodeIfPresent([String].self, forKey: .sourceMessageIds) ?? []
        supersedesIds = try c.decodeIfPresent([Int].self, forKey: .supersedesIds) ?? []
        expiresAt = try c.decodeIfPresent(Int64.self, forKey: .expiresAt)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
        lastUsedAt = try c.decodeIfPresent(Int64.self, forKey: .lastUsedAt)
        topicTitle = try c.decodeIfPresent(String.self, forKey: .topicTitle)
        memberIds = try c.decodeIfPresent([Int].self, forKey: .memberIds) ?? []
        lastReinforcedAt = try c.decodeIfPresent(Int64.self, forKey: .lastReinforcedAt)
    }
}

struct DesktopMemoryRecall: Equatable, Sendable {
    let records: [DesktopMemoryRecord]
    let prompt: String
}
