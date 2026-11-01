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
    case apiKey, codexOAuth, antigravityOAuth, grokOAuth
    case zhipuCodingPlan, kimiCodingPlan, mimoCodingPlan, minimaxTokenPlan

    var isPlan: Bool { [.zhipuCodingPlan, .kimiCodingPlan, .mimoCodingPlan, .minimaxTokenPlan].contains(self) }
    /// Plan endpoints are fixed by the vendor (mirrors KMP OpenAIAuthMode.fixedBaseUrl).
    var planBaseURL: String? {
        switch self {
        case .zhipuCodingPlan: "https://open.bigmodel.cn/api/coding/paas/v4"
        case .kimiCodingPlan: "https://api.kimi.com/coding/v1"
        case .mimoCodingPlan: "https://token-plan-cn.xiaomimimo.com/v1"
        case .minimaxTokenPlan: "https://api.minimaxi.com/v1"
        default: nil
        }
    }
}

struct DesktopProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var kind: DesktopProviderKind
    var baseURL: String
    var models: [DesktopModelConfiguration]
    var selectedModelID: UUID?
    var authMode: DesktopProviderAuthMode
    /// Claude only: send `cache_control` so a stable prefix can be reused. Off by default (cache writes are billed).
    var promptCaching = false

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
         authMode: DesktopProviderAuthMode = .apiKey, promptCaching: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.baseURL = baseURL
        self.models = models
        self.selectedModelID = selectedModelID ?? models.first(where: \.enabled)?.id
        self.authMode = authMode; self.promptCaching = promptCaching
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, modelID, models, selectedModelID, authMode, promptCaching
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
        promptCaching = try values.decodeIfPresent(Bool.self, forKey: .promptCaching) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name)
        try values.encode(kind, forKey: .kind); try values.encode(baseURL, forKey: .baseURL)
        try values.encode(models, forKey: .models); try values.encodeIfPresent(selectedModelID, forKey: .selectedModelID)
        try values.encode(authMode, forKey: .authMode)
        if promptCaching { try values.encode(true, forKey: .promptCaching) }
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
    var title: String? = nil
    var sourceURL: String? = nil

    init(url: String, name: String? = nil, title: String? = nil, sourceURL: String? = nil) {
        self.url = url
        self.name = name
        self.title = title
        self.sourceURL = sourceURL
    }

    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let parsed = URL(string: url), !parsed.lastPathComponent.isEmpty, parsed.lastPathComponent != "/" {
            return parsed.lastPathComponent
        }
        return "图片"
    }
}

struct DesktopVideoMedia: Codable, Equatable, Sendable {
    let url: String
    var title: String? = nil
    var posterURL: String? = nil
    var sourceURL: String? = nil

    init(url: String, title: String? = nil, posterURL: String? = nil, sourceURL: String? = nil) {
        self.url = url
        self.title = title
        self.posterURL = posterURL
        self.sourceURL = sourceURL
    }

    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let parsed = URL(string: url), !parsed.lastPathComponent.isEmpty, parsed.lastPathComponent != "/" {
            return parsed.lastPathComponent
        }
        return "视频"
    }
}

struct DesktopAudioMedia: Codable, Equatable, Sendable {
    let url: String
    var fileName: String = ""
    var title: String? = nil

    init(url: String, fileName: String = "", title: String? = nil) {
        self.url = url
        self.fileName = fileName
        self.title = title
    }

    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let trimmedFile = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFile.isEmpty { return trimmedFile }
        if let parsed = URL(string: url), !parsed.lastPathComponent.isEmpty, parsed.lastPathComponent != "/" {
            return parsed.lastPathComponent
        }
        return "音频"
    }
}

/// Display projection of one tool call; the canonical part stays in `canonicalJSON`.
struct DesktopToolCall: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case running, pending, complete, denied }
    let id: String
    let name: String
    var input = ""
    var output = ""
    var status: Status = .complete
    var images: [DesktopMessageImage] = []
    var videos: [DesktopVideoMedia] = []
    var audios: [DesktopAudioMedia] = []

    init(id: String, name: String, input: String = "", output: String = "", status: Status = .complete,
         images: [DesktopMessageImage] = [], videos: [DesktopVideoMedia] = [], audios: [DesktopAudioMedia] = []) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.status = status
        self.images = images
        self.videos = videos
        self.audios = audios
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, input, output, status, images, videos, audios
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        input = try container.decodeIfPresent(String.self, forKey: .input) ?? ""
        output = try container.decodeIfPresent(String.self, forKey: .output) ?? ""
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .complete
        images = try container.decodeIfPresent([DesktopMessageImage].self, forKey: .images) ?? []
        videos = try container.decodeIfPresent([DesktopVideoMedia].self, forKey: .videos) ?? []
        audios = try container.decodeIfPresent([DesktopAudioMedia].self, forKey: .audios) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(input, forKey: .input)
        try container.encode(output, forKey: .output)
        try container.encode(status, forKey: .status)
        if !images.isEmpty { try container.encode(images, forKey: .images) }
        if !videos.isEmpty { try container.encode(videos, forKey: .videos) }
        if !audios.isEmpty { try container.encode(audios, forKey: .audios) }
    }
}

struct DesktopMessageContentPart: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text, reasoning, image, video, audio, tool
    }
    var kind: Kind
    var text: String? = nil
    var image: DesktopMessageImage? = nil
    var video: DesktopVideoMedia? = nil
    var audio: DesktopAudioMedia? = nil
    var tool: DesktopToolCall? = nil

    static func text(_ value: String) -> Self { Self(kind: .text, text: value) }
    static func reasoning(_ value: String) -> Self { Self(kind: .reasoning, text: value) }
    static func image(_ value: DesktopMessageImage) -> Self { Self(kind: .image, image: value) }
    static func video(_ value: DesktopVideoMedia) -> Self { Self(kind: .video, video: value) }
    static func audio(_ value: DesktopAudioMedia) -> Self { Self(kind: .audio, audio: value) }
    static func tool(_ value: DesktopToolCall) -> Self { Self(kind: .tool, tool: value) }
}

enum DesktopMessageDisplayBlock: Equatable, Sendable {
    case text(String)
    case images([DesktopMessageImage])
    case video(DesktopVideoMedia)
    case audio(DesktopAudioMedia)
    case tool(DesktopToolCall)
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
    var videos: [DesktopVideoMedia] = []
    var audios: [DesktopAudioMedia] = []
    var tools: [DesktopToolCall] = []
    var parts: [DesktopMessageContentPart] = []

    var variantIndex: Int { variantIDs.firstIndex(of: id) ?? 0 }
    var variantCount: Int { max(1, variantIDs.count) }
    var canEdit: Bool { role == .user && (editableTextPartIndex != nil || canonicalJSON == nil) }
    var textForEditing: String { editableText ?? text }

    init(id: UUID = UUID(), role: DesktopMessageRole, text: String, reasoning: String = "",
         state: DesktopMessageState = .complete, canonicalJSON: String? = nil, unsupportedPartCount: Int = 0,
         variantIDs: [UUID] = [], editableTextPartIndex: Int? = nil, editableText: String? = nil,
         estimatedTokens: Int? = nil, images: [DesktopMessageImage] = [], videos: [DesktopVideoMedia] = [],
         audios: [DesktopAudioMedia] = [], tools: [DesktopToolCall] = [],
         parts: [DesktopMessageContentPart] = []) {
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
        self.videos = videos
        self.audios = audios
        self.tools = tools
        self.parts = parts
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, reasoning, state, canonicalJSON, unsupportedPartCount
        case variantIDs, editableTextPartIndex, editableText, estimatedTokens
        case images, videos, audios, tools, parts
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
        videos = try container.decodeIfPresent([DesktopVideoMedia].self, forKey: .videos) ?? []
        audios = try container.decodeIfPresent([DesktopAudioMedia].self, forKey: .audios) ?? []
        tools = try container.decodeIfPresent([DesktopToolCall].self, forKey: .tools) ?? []
        parts = try container.decodeIfPresent([DesktopMessageContentPart].self, forKey: .parts) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(reasoning, forKey: .reasoning)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(canonicalJSON, forKey: .canonicalJSON)
        try container.encode(unsupportedPartCount, forKey: .unsupportedPartCount)
        try container.encode(variantIDs, forKey: .variantIDs)
        try container.encodeIfPresent(editableTextPartIndex, forKey: .editableTextPartIndex)
        try container.encodeIfPresent(editableText, forKey: .editableText)
        try container.encodeIfPresent(estimatedTokens, forKey: .estimatedTokens)
        try container.encode(images, forKey: .images)
        if !videos.isEmpty { try container.encode(videos, forKey: .videos) }
        if !audios.isEmpty { try container.encode(audios, forKey: .audios) }
        try container.encode(tools, forKey: .tools)
        if !parts.isEmpty { try container.encode(parts, forKey: .parts) }
    }

    /// Ordered content parts preserving the exact sequence of text, images, media, and tools across
    /// streaming updates (`canonicalJSON`) and persistence reloads.
    var orderedContentParts: [DesktopMessageContentPart] {
        if let canonicalJSON,
           let parsed = Self.parseCanonicalParts(from: canonicalJSON, fallbackTools: tools),
           !parsed.isEmpty {
            let joinedText = parsed.compactMap { $0.kind == .text ? $0.text : nil }.joined()
            if joinedText == text || text.isEmpty {
                return parsed
            }
        }
        if !parts.isEmpty {
            let joinedText = parts.compactMap { $0.kind == .text ? $0.text : nil }.joined()
            if joinedText == text || text.isEmpty {
                return parts
            }
        }
        var fallback: [DesktopMessageContentPart] = []
        if !reasoning.isEmpty { fallback.append(.reasoning(reasoning)) }
        if !text.isEmpty { fallback.append(.text(text)) }
        for tool in tools { fallback.append(.tool(tool)) }
        for image in images { fallback.append(.image(image)) }
        for video in videos { fallback.append(.video(video)) }
        for audio in audios { fallback.append(.audio(audio)) }
        return fallback
    }

    private static func parseCanonicalParts(from jsonString: String, fallbackTools: [DesktopToolCall]) -> [DesktopMessageContentPart]? {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawParts = root["parts"] as? [[String: Any]] else {
            return nil
        }
        var toolsByID: [String: DesktopToolCall] = [:]
        for tool in fallbackTools where toolsByID[tool.id] == nil {
            toolsByID[tool.id] = tool
        }
        var result: [DesktopMessageContentPart] = []
        for part in rawParts {
            guard let type = part["type"] as? String else { continue }
            let metadata = part["metadata"] as? [String: Any]
            switch type {
            case "text":
                if let textValue = part["text"] as? String, !textValue.isEmpty {
                    result.append(.text(textValue))
                }
                for image in parseSearchMetadataImages(metadata) {
                    result.append(.image(image))
                }
            case "reasoning":
                if let reasoningValue = part["reasoning"] as? String, !reasoningValue.isEmpty {
                    result.append(.reasoning(reasoningValue))
                }
            case "image":
                if let url = part["url"] as? String, !url.isEmpty {
                    result.append(.image(DesktopMessageImage(
                        url: url,
                        name: metadataString(metadata, "fileName"),
                        title: metadataString(metadata, "app.amber.media.title"),
                        sourceURL: metadataString(metadata, "app.amber.media.sourceURL")
                    )))
                }
            case "video":
                if let url = part["url"] as? String, !url.isEmpty {
                    result.append(.video(DesktopVideoMedia(
                        url: url,
                        title: metadataString(metadata, "app.amber.media.title") ?? metadataString(metadata, "fileName"),
                        posterURL: metadataString(metadata, "app.amber.media.posterURL"),
                        sourceURL: metadataString(metadata, "app.amber.media.sourceURL")
                    )))
                }
            case "audio":
                if let url = part["url"] as? String, !url.isEmpty {
                    let fileName = (part["fileName"] as? String) ?? ""
                    result.append(.audio(DesktopAudioMedia(
                        url: url,
                        fileName: fileName,
                        title: metadataString(metadata, "app.amber.media.title") ?? (fileName.isEmpty ? nil : fileName)
                    )))
                }
            case "tool":
                let callID = (part["toolCallId"] as? String) ?? ""
                if let existing = toolsByID[callID] {
                    result.append(.tool(existing))
                } else {
                    let toolName = (part["toolName"] as? String) ?? ""
                    let input = (part["input"] as? String) ?? ""
                    let rawOutputs = (part["output"] as? [[String: Any]]) ?? []
                    var outputLines: [String] = []
                    var toolImages: [DesktopMessageImage] = []
                    var toolVideos: [DesktopVideoMedia] = []
                    var toolAudios: [DesktopAudioMedia] = []
                    for out in rawOutputs {
                        let outType = (out["type"] as? String) ?? ""
                        let outMeta = out["metadata"] as? [String: Any]
                        switch outType {
                        case "text":
                            if let t = out["text"] as? String { outputLines.append(t) }
                            toolImages.append(contentsOf: parseSearchMetadataImages(outMeta))
                        case "image":
                            outputLines.append("[图片]")
                            if let url = out["url"] as? String, !url.isEmpty {
                                toolImages.append(DesktopMessageImage(
                                    url: url,
                                    name: metadataString(outMeta, "fileName"),
                                    title: metadataString(outMeta, "app.amber.media.title"),
                                    sourceURL: metadataString(outMeta, "app.amber.media.sourceURL")
                                ))
                            }
                        case "video":
                            outputLines.append("[附件]")
                            if let url = out["url"] as? String, !url.isEmpty {
                                toolVideos.append(DesktopVideoMedia(
                                    url: url,
                                    title: metadataString(outMeta, "app.amber.media.title"),
                                    posterURL: metadataString(outMeta, "app.amber.media.posterURL"),
                                    sourceURL: metadataString(outMeta, "app.amber.media.sourceURL")
                                ))
                            }
                        case "audio":
                            outputLines.append("[附件]")
                            if let url = out["url"] as? String, !url.isEmpty {
                                let fn = (out["fileName"] as? String) ?? ""
                                toolAudios.append(DesktopAudioMedia(
                                    url: url,
                                    fileName: fn,
                                    title: metadataString(outMeta, "app.amber.media.title")
                                ))
                            }
                        default:
                            outputLines.append("[附件]")
                        }
                    }
                    result.append(.tool(DesktopToolCall(
                        id: callID,
                        name: toolName,
                        input: input,
                        output: outputLines.joined(separator: "\n"),
                        status: rawOutputs.isEmpty ? .running : .complete,
                        images: toolImages,
                        videos: toolVideos,
                        audios: toolAudios
                    )))
                }
            default:
                break
            }
        }
        return result
    }

    private static func metadataString(_ metadata: [String: Any]?, _ key: String) -> String? {
        guard let raw = metadata?[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseSearchMetadataImages(_ metadata: [String: Any]?) -> [DesktopMessageImage] {
        guard let raw = metadataString(metadata, "app.amber.media.images"),
              let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { item in
            guard let url = metadataString(item, "url") else { return nil }
            return DesktopMessageImage(
                url: url,
                name: metadataString(item, "name") ?? metadataString(item, "alt"),
                title: metadataString(item, "title") ?? metadataString(item, "alt"),
                sourceURL: metadataString(item, "sourceURL")
            )
        }
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
