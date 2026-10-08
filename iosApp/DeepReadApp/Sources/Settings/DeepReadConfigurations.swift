import Foundation

enum DeepReadModelProtocol: String, Codable, CaseIterable, Identifiable {
    case openAI, claude
    var id: String { rawValue }
    var title: String { self == .openAI ? "OpenAI 兼容 API" : "Claude API" }
}

struct DeepReadModelConfiguration: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "OpenAI"
    var protocolType = DeepReadModelProtocol.openAI
    var baseURL = "https://api.openai.com/v1"
    var modelID = "gpt-4o-mini"
    var chatCompletionsPath = "/chat/completions"
    var useResponsesAPI = false
    var promptCaching = false
    var enabled = true
    var apiKey = ""

    // Credentials are hydrated from Keychain, never encoded into UserDefaults.
    enum CodingKeys: String, CodingKey {
        case id, name, protocolType, baseURL, modelID, chatCompletionsPath
        case useResponsesAPI, promptCaching, enabled
    }
}

enum DeepReadSearchKind: String, Codable, CaseIterable, Identifiable {
    case bingLocal = "bing_local", zhipu, tavily, exa, searxng, linkup, brave
    case serper, serpapi, metaso, ollama, perplexity, firecrawl, jina, bocha
    case amberAgent = "amber_agent", grok
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bingLocal: "免费多引擎聚合"
        case .amberAgent: "AmberAgent"
        case .zhipu: "智谱"
        case .searxng: "SearXNG"
        case .linkup: "LinkUp"
        case .serpapi: "SerpAPI"
        case .metaso: "秘塔"
        case .bocha: "博查"
        default: rawValue.capitalized
        }
    }
    var executable: Bool {
        [.bingLocal, .zhipu, .tavily, .exa, .brave, .serper, .serpapi, .jina].contains(self)
    }
}

struct DeepReadSearchConfiguration: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind = DeepReadSearchKind.bingLocal
    var enabled = true
    var apiKey = ""
    var fields: [String: String] = [:]
    var password = ""

    enum CodingKeys: String, CodingKey { case id, kind, enabled, fields }
}
