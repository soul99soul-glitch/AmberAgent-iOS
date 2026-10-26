import Foundation

enum DesktopProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case responses, claude, gemini
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "OpenAI 兼容"
        case .responses: "OpenAI Responses"
        case .claude: "Anthropic Claude"
        case .gemini: "Google Gemini"
        }
    }
    var defaultBaseURL: String {
        switch self {
        case .openAI, .responses: "https://api.openai.com/v1"
        case .claude: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        }
    }
}

enum DesktopProviderAuthMode: String, Codable, Sendable {
    case apiKey, codexOAuth, antigravityOAuth
}

struct DesktopProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var kind: DesktopProviderKind
    var baseURL: String
    var models: [DesktopModelConfiguration]
    var selectedModelID: UUID?
    var authMode: DesktopProviderAuthMode

    var selectedModel: DesktopModelConfiguration? {
        models.first { $0.id == selectedModelID && $0.enabled } ?? models.first { $0.enabled }
    }

    var modelID: String {
        get { selectedModel?.modelID ?? "" }
        set {
            if let index = models.firstIndex(where: { $0.id == selectedModel?.id }) { models[index].modelID = newValue }
            else {
                let model = DesktopModelConfiguration(modelID: newValue)
                models.append(model)
                selectedModelID = model.id
            }
        }
    }

    init(id: UUID = UUID(), name: String, kind: DesktopProviderKind, baseURL: String, modelID: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        let model = DesktopModelConfiguration(modelID: modelID)
        models = [model]
        selectedModelID = model.id
        authMode = .apiKey
    }

    init(id: UUID = UUID(), name: String, kind: DesktopProviderKind, baseURL: String,
         models: [DesktopModelConfiguration], selectedModelID: UUID? = nil,
         authMode: DesktopProviderAuthMode = .apiKey) {
        self.id = id; self.name = name; self.kind = kind; self.baseURL = baseURL
        self.models = models
        self.selectedModelID = selectedModelID ?? models.first(where: \.enabled)?.id
        self.authMode = authMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, modelID, models, selectedModelID, authMode
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(DesktopProviderKind.self, forKey: .kind)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        if let decoded = try values.decodeIfPresent([DesktopModelConfiguration].self, forKey: .models) {
            models = decoded
        } else {
            models = [DesktopModelConfiguration(modelID: try values.decodeIfPresent(String.self, forKey: .modelID) ?? "")]
        }
        selectedModelID = try values.decodeIfPresent(UUID.self, forKey: .selectedModelID) ?? models.first(where: \.enabled)?.id
        authMode = try values.decodeIfPresent(DesktopProviderAuthMode.self, forKey: .authMode) ?? .apiKey
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name)
        try values.encode(kind, forKey: .kind); try values.encode(baseURL, forKey: .baseURL)
        try values.encode(models, forKey: .models); try values.encodeIfPresent(selectedModelID, forKey: .selectedModelID)
        try values.encode(authMode, forKey: .authMode)
        try values.encode(modelID, forKey: .modelID)
    }
}

enum DesktopMessageRole: String, Codable, Sendable { case user, assistant, system, tool }
enum DesktopMessageState: String, Codable, Sendable {
    case complete, streaming, cancelled, failed

    static func agentProjection(role: DesktopMessageRole, isLast: Bool) -> Self {
        role == .assistant && isLast ? .streaming : .complete
    }
}

struct DesktopMessageImage: Codable, Equatable, Sendable {
    let url: String
    let name: String?
}

struct DesktopMessage: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var role: DesktopMessageRole
    var text: String
    var reasoning = ""
    var state: DesktopMessageState = .complete
    var canonicalJSON: String?
    var unsupportedPartCount = 0
    var variantIDs: [UUID] = []
    var editableTextPartIndex: Int?
    var editableText: String?
    var estimatedTokens: Int?
    var images: [DesktopMessageImage] = []

    var variantIndex: Int { variantIDs.firstIndex(of: id) ?? 0 }
    var variantCount: Int { max(1, variantIDs.count) }
    var canEdit: Bool { role == .user && (editableTextPartIndex != nil || canonicalJSON == nil) }
    var textForEditing: String { editableText ?? text }

    init(id: UUID = UUID(), role: DesktopMessageRole, text: String, reasoning: String = "",
         state: DesktopMessageState = .complete, canonicalJSON: String? = nil, unsupportedPartCount: Int = 0,
         variantIDs: [UUID] = [], editableTextPartIndex: Int? = nil, editableText: String? = nil,
         estimatedTokens: Int? = nil, images: [DesktopMessageImage] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.state = state
        self.canonicalJSON = canonicalJSON
        self.unsupportedPartCount = unsupportedPartCount
        self.variantIDs = variantIDs
        self.editableTextPartIndex = editableTextPartIndex
        self.editableText = editableText
        self.estimatedTokens = estimatedTokens
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, reasoning, state, canonicalJSON, unsupportedPartCount
        case variantIDs, editableTextPartIndex, editableText, estimatedTokens, images
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(DesktopMessageRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        state = try container.decodeIfPresent(DesktopMessageState.self, forKey: .state) ?? .complete
        canonicalJSON = try container.decodeIfPresent(String.self, forKey: .canonicalJSON)
        unsupportedPartCount = try container.decodeIfPresent(Int.self, forKey: .unsupportedPartCount) ?? 0
        variantIDs = try container.decodeIfPresent([UUID].self, forKey: .variantIDs) ?? []
        editableTextPartIndex = try container.decodeIfPresent(Int.self, forKey: .editableTextPartIndex)
        editableText = try container.decodeIfPresent(String.self, forKey: .editableText)
        estimatedTokens = try container.decodeIfPresent(Int.self, forKey: .estimatedTokens)
        images = try container.decodeIfPresent([DesktopMessageImage].self, forKey: .images) ?? []
    }
}

struct DesktopConversation: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title = "新对话"
    var updatedAt = Date()
    var messages: [DesktopMessage] = []
    var isPinned = false
    var canonicalJSON: String?
}

struct DesktopConversationExport: Codable {
    var format = "amber.mac.conversation.v1"
    var conversation: DesktopConversation
}

enum DesktopRuntimeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

enum DesktopJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(value.utf8))
    }
}
