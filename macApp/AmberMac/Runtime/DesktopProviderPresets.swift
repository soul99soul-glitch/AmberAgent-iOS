import Foundation

/// Built-in providers (the iOS DEFAULT_PROVIDERS catalog plus the native Claude / Gemini / local entries).
/// Picking one fills protocol, address and plan options; the user only adds a key.
struct DesktopProviderPreset: Identifiable, Equatable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case international = "国际", domestic = "国内", local = "本地", custom = "自定义"
    }
    let id: String
    let name: String
    let group: Group
    let kind: DesktopProviderKind
    let baseURL: String
    let summary: String
    /// Coding / Token plan offered by this vendor, if any.
    var plan: DesktopProviderAuthMode?
    var planTitle = "编程套餐"
    var keyPlaceholder = "sk-…"
    var keyURL: URL?
    var needsKey = true
    var monogram: String { String(name.prefix(1)).uppercased() }

    static let all: [DesktopProviderPreset] = [
        .init(id: "openai", name: "OpenAI", group: .international, kind: .responses, baseURL: "https://api.openai.com/v1",
              summary: "GPT 系列；Responses 协议", keyURL: URL(string: "https://platform.openai.com/api-keys")),
        .init(id: "anthropic", name: "Anthropic", group: .international, kind: .claude, baseURL: "https://api.anthropic.com/v1",
              summary: "Claude 系列", keyPlaceholder: "sk-ant-…", keyURL: URL(string: "https://console.anthropic.com/settings/keys")),
        .init(id: "gemini", name: "Google Gemini", group: .international, kind: .gemini, baseURL: "https://generativelanguage.googleapis.com/v1beta",
              summary: "Gemini 系列", keyPlaceholder: "AIza…", keyURL: URL(string: "https://aistudio.google.com/apikey")),
        .init(id: "openrouter", name: "OpenRouter", group: .international, kind: .openAI, baseURL: "https://openrouter.ai/api/v1",
              summary: "一个 Key 调用多家模型", keyPlaceholder: "sk-or-…", keyURL: URL(string: "https://openrouter.ai/keys")),
        .init(id: "xai", name: "xAI", group: .international, kind: .responses, baseURL: "https://api.x.ai/v1",
              summary: "Grok 系列", keyPlaceholder: "xai-…", keyURL: URL(string: "https://console.x.ai")),
        .init(id: "deepseek", name: "DeepSeek", group: .domestic, kind: .openAI, baseURL: "https://api.deepseek.com/v1",
              summary: "DeepSeek V 系列与推理模型", keyURL: URL(string: "https://platform.deepseek.com/api_keys")),
        .init(id: "zhipu", name: "智谱 GLM", group: .domestic, kind: .openAI, baseURL: "https://open.bigmodel.cn/api/paas/v4",
              summary: "GLM 系列；支持 GLM Coding Plan", plan: .zhipuCodingPlan, planTitle: "GLM Coding Plan",
              keyPlaceholder: "智谱 API Key", keyURL: URL(string: "https://open.bigmodel.cn/usercenter/apikeys")),
        .init(id: "kimi", name: "月之暗面 Kimi", group: .domestic, kind: .openAI, baseURL: "https://api.moonshot.cn/v1",
              summary: "Kimi 系列；支持 Kimi Coding 套餐", plan: .kimiCodingPlan, planTitle: "Kimi Coding 套餐",
              keyURL: URL(string: "https://platform.moonshot.cn/console/api-keys")),
        .init(id: "minimax", name: "MiniMax", group: .domestic, kind: .openAI, baseURL: "https://api.minimaxi.com/v1",
              summary: "MiniMax M 系列；支持 Token Plan", plan: .minimaxTokenPlan, planTitle: "Token Plan",
              keyURL: URL(string: "https://platform.minimaxi.com/user-center/basic-information/interface-key")),
        .init(id: "mimo", name: "小米 MiMo", group: .domestic, kind: .openAI, baseURL: "https://api.xiaomimimo.com/v1",
              summary: "MiMo 系列；支持 Token Plan", plan: .mimoCodingPlan, planTitle: "Token Plan"),
        .init(id: "ollama", name: "Ollama", group: .local, kind: .openAI, baseURL: "http://localhost:11434/v1",
              summary: "本机模型，无需 Key", needsKey: false),
        .init(id: "lmstudio", name: "LM Studio", group: .local, kind: .openAI, baseURL: "http://localhost:1234/v1",
              summary: "本机模型，无需 Key", needsKey: false),
        .init(id: "custom", name: "自定义", group: .custom, kind: .openAI, baseURL: "",
              summary: "任意 OpenAI / Anthropic / Gemini 兼容接口"),
    ]

    /// The preset this saved provider came from, matched by plan or address.
    static func matching(_ provider: DesktopProviderConfiguration) -> DesktopProviderPreset? {
        if provider.authMode.isPlan { return all.first { $0.plan == provider.authMode } }
        let base = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return all.first { !$0.baseURL.isEmpty && $0.baseURL == base && $0.kind == provider.kind }
    }

    func configuration(plan usePlan: Bool) -> DesktopProviderConfiguration {
        let mode = usePlan ? (plan ?? .apiKey) : .apiKey
        return DesktopProviderConfiguration(name: usePlan && plan != nil ? "\(name) · \(planTitle)" : name, kind: kind,
            baseURL: mode.planBaseURL ?? baseURL, models: [], authMode: mode)
    }
}
