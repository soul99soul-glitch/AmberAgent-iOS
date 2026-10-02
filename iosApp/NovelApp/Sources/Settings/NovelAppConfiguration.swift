import Foundation

enum NovelModelProtocol: String, Codable, CaseIterable, Identifiable {
    case openAI, claude, gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "OpenAI 兼容"
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .claude: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        }
    }
}

/// One model under a service. `id` is stable so per-purpose model policies
/// keep pointing at the same model after the service is edited.
struct NovelModelEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var modelID = ""
    var supportsReasoning = false
    var contextWindowTokens: Int?
}

struct NovelModelService: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var protocolType = NovelModelProtocol.openAI
    /// Empty means the protocol's official endpoint.
    var baseURL = ""
    var useResponsesAPI = false
    var enabled = true
    var models: [NovelModelEntry] = []
    /// Hydrated from Keychain; never encoded into UserDefaults.
    var apiKey = ""

    enum CodingKeys: String, CodingKey {
        case id, name, protocolType, baseURL, useResponsesAPI, enabled, models
    }

    var resolvedBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? protocolType.defaultBaseURL : trimmed
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? protocolType.title : trimmed
    }
}

/// Search services the shared `IOSSearchExecutor` can run.
enum NovelSearchKind: String, Codable, CaseIterable, Identifiable {
    case freeAggregate = "bing_local"
    case tavily, exa, zhipu, brave, serper, serpapi, jina

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeAggregate: "免费多引擎聚合"
        case .tavily: "Tavily"
        case .exa: "Exa"
        case .zhipu: "智谱"
        case .brave: "Brave"
        case .serper: "Serper"
        case .serpapi: "SerpAPI"
        case .jina: "Jina"
        }
    }

    var needsAPIKey: Bool { self != .freeAggregate }
}

struct NovelSearchService: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind = NovelSearchKind.freeAggregate
    /// Hydrated from Keychain; never encoded into UserDefaults.
    var apiKey = ""

    enum CodingKeys: String, CodingKey { case id, kind }
}
