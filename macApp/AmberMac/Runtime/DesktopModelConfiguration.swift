import Foundation

enum DesktopReasoningLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, auto, low, medium, high, xhigh, max
    var id: String { rawValue }
    var isEnabled: Bool { self != .off }
    var title: String {
        switch self {
        case .off: "关闭"
        case .auto: "自动"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "超高"
        case .max: "最大"
        }
    }
}

/// Aligns composer and settings thinking-level options with KMP `ReasoningPolicy` and `ModelRegistry`.
///
/// Relationship with DeepSeek `/boost`: the two are orthogonal and neither overrides the other.
/// - The thinking level is the only source for request-body reasoning fields (OpenAI `reasoning_effort`,
///   Claude `thinking` / `output_config.effort`). It is stored per model and always passed through
///   `coercedLevel` against `supportedLevels` before sending.
/// - `/boost` is per conversation and only appends `DesktopDeepSeekBoost.prompt` as a system message
///   for DeepSeek models. It never raises, lowers, or resets the thinking level, and turning it off
///   leaves the chosen level untouched.
enum DesktopThinkingPolicy {
    static func supportedLevels(
        for model: DesktopModelConfiguration?,
        provider: DesktopProviderConfiguration?
    ) -> [DesktopReasoningLevel] {
        guard let model, model.enabled else { return [] }
        return supportedLevels(
            modelID: model.modelID,
            kind: provider?.kind ?? .openAI,
            providerName: provider?.name ?? "",
            baseURL: provider?.baseURL ?? "",
            authMode: provider?.authMode ?? .apiKey
        )
    }

    static func supportedLevels(
        modelID: String,
        kind: DesktopProviderKind,
        providerName: String = "",
        baseURL: String = "",
        authMode: DesktopProviderAuthMode = .apiKey
    ) -> [DesktopReasoningLevel] {
        let id = normalizedModelID(modelID)
        guard !id.isEmpty else { return [] }
        if host(of: baseURL) == "grok.com" { return [] }
        let routingKey = providerRoutingKey(kind: kind, name: providerName, baseURL: baseURL, authMode: authMode)

        if id.contains("claude") || kind == .claude {
            guard isClaudeReasoningModel(id) else { return [] }
            if isClaudeAlwaysThinking(id) {
                return [.off, .auto, .low, .medium, .high, .xhigh, .max]
            }
            if isClaudeOpus47(id) || isClaudeCurrentFull(id) {
                return [.off, .auto, .low, .medium, .high, .xhigh, .max]
            }
            if id.contains("4-5") || id.contains("4.5") {
                return [.off, .auto, .low, .medium, .high, .max]
            }
            if id.contains("sonnet") && (id.contains("4-6") || id.contains("4.6")) {
                return [.off, .auto, .low, .medium, .high]
            }
            return [.off, .auto, .low, .medium, .high, .xhigh]
        }

        if isKimiK3(id) { return [.off, .low, .high, .max] }
        if isKimiK27Code(id) { return [] }
        if id.contains("kimi") || id.contains("moonshot") || routingKey == "kimi" {
            return [.off, .auto]
        }

        if isGlm53(id) { return [.off, .low, .high, .max] }
        if isGlm52(id) { return [.off, .high, .max] }
        if isGlm5Effort(id) { return [.off, .low, .medium, .high, .xhigh] }
        if id.contains("glm") || id.contains("zhipu") || routingKey == "zhipu" {
            return [.off, .auto]
        }

        if isDeepSeekV4(id) { return [.off, .low, .high, .max] }
        if id.contains("deepseek") || routingKey == "deepseek" {
            return [.off, .auto]
        }

        if isQwen38Max(id) { return [.off, .low, .medium, .xhigh] }
        if id.contains("mimo") || routingKey == "mimo" { return [.off, .auto] }
        if isMiniMaxM2(id) { return [] }
        if isMiniMaxM3(id) || routingKey == "minimax" { return [.off, .auto] }
        if isQwenPlusBinary(id) { return [.off, .auto] }
        if isQwenReasoningModel(id) {
            return [.off, .auto, .low, .medium, .high, .xhigh]
        }

        if kind == .gemini || routingKey == "gemini" || id.contains("gemini") {
            return geminiLevels(id)
        }

        if isGrok46(id) || (routingKey == "xai" && id.contains("4.6")) {
            return [.off, .low, .medium, .high, .xhigh]
        }
        if isGrok45(id) || id.contains("grok-4") || id.contains("grok-3-mini") || (routingKey == "xai" && id.contains("grok")) {
            return [.off, .low, .medium, .high]
        }

        if isOpenAIReasoningModel(id) {
            return [.off, .low, .medium, .high, .xhigh, .max]
        }

        if id.contains("doubao-1-6") || id.contains("doubao-1.6")
            || id.contains("doubao-1-8") || id.contains("doubao-1.8")
            || id.contains("step-3") || id.contains("intern-s1") {
            return [.off, .auto]
        }

        return []
    }

    static func coercedLevel(
        _ level: DesktopReasoningLevel,
        supported: [DesktopReasoningLevel]
    ) -> DesktopReasoningLevel {
        guard !supported.isEmpty else { return .off }
        if supported.contains(level) { return level }
        if level == .off { return supported.first ?? .off }
        if level == .auto {
            for candidate in [DesktopReasoningLevel.medium, .high, .low] where supported.contains(candidate) {
                return candidate
            }
            return supported.first { $0 != .off } ?? .off
        }
        if level == .xhigh || level == .max {
            if supported.contains(.max) { return .max }
            if supported.contains(.xhigh) { return .xhigh }
            if supported.contains(.high) { return .high }
        }
        if level == .medium, supported.contains(.high) { return .high }
        if level.isEnabled, supported.contains(.auto) { return .auto }
        return supported.first { $0 != .off } ?? .off
    }

    static func editorLevels(
        for model: DesktopModelConfiguration,
        kind: DesktopProviderKind,
        providerName: String = "",
        baseURL: String = "",
        authMode: DesktopProviderAuthMode = .apiKey
    ) -> [DesktopReasoningLevel] {
        let supported = supportedLevels(
            modelID: model.modelID,
            kind: kind,
            providerName: providerName,
            baseURL: baseURL,
            authMode: authMode
        )
        if supported.isEmpty { return DesktopReasoningLevel.allCases }
        if supported.contains(model.reasoning) { return supported }
        var result: [DesktopReasoningLevel] = [.off]
        for item in supported where !result.contains(item) { result.append(item) }
        if !result.contains(model.reasoning) { result.append(model.reasoning) }
        return result
    }

    private static func normalizedModelID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    private static func host(of baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), let host = components.host {
            return host.lowercased()
        }
        let afterScheme = trimmed.components(separatedBy: "://").last ?? trimmed
        let authority = afterScheme.components(separatedBy: "/").first ?? afterScheme
        let withoutPort = authority.components(separatedBy: ":").first ?? authority
        return withoutPort.lowercased()
    }

    private static func providerRoutingKey(
        kind: DesktopProviderKind,
        name: String,
        baseURL: String,
        authMode: DesktopProviderAuthMode
    ) -> String {
        switch kind {
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .openAI, .responses:
            switch authMode {
            case .zhipuCodingPlan: return "zhipu"
            case .kimiCodingPlan: return "kimi"
            case .mimoCodingPlan: return "mimo"
            case .minimaxTokenPlan: return "minimax"
            case .grokOAuth: return "xai"
            case .codexOAuth: return "openai"
            case .apiKey, .antigravityOAuth: break
            }
            let endpoint = "\(baseURL) \(name)".lowercased()
            let parsedHost = host(of: baseURL)
            if endpoint.contains("deepseek") { return "deepseek" }
            if endpoint.contains("moonshot") || endpoint.contains("kimi") { return "kimi" }
            if endpoint.contains("bigmodel") || endpoint.contains("zhipu") { return "zhipu" }
            if endpoint.contains("xiaomimimo") || endpoint.contains("mimo") { return "mimo" }
            if endpoint.contains("minimax") { return "minimax" }
            if parsedHost == "api.x.ai" || parsedHost == "cli-chat-proxy.grok.com"
                || name.caseInsensitiveCompare("xai") == .orderedSame
                || name.caseInsensitiveCompare("x.ai") == .orderedSame { return "xai" }
            if parsedHost == "api.openai.com" || name.caseInsensitiveCompare("openai") == .orderedSame { return "openai" }
            return ""
        }
    }

    private static func isClaudeReasoningModel(_ id: String) -> Bool {
        if isClaudeAlwaysThinking(id) || isClaudeOpus47(id) || isClaudeCurrentFull(id) { return true }
        if id.contains("3-7") || id.contains("3.7") { return true }
        return id.range(of: #"(?:^|[-/])claude-(?:(?:opus|sonnet|haiku)-)?[45](?:$|[-.])"#, options: .regularExpression) != nil
            || id.range(of: #"(?:^|[-/])(?:opus|sonnet|haiku)-[45](?:$|[-.])"#, options: .regularExpression) != nil
    }

    private static func isClaudeAlwaysThinking(_ id: String) -> Bool {
        id.contains("fable") || id.contains("mythos") || id.contains("opus-5-5") || id.contains("opus-5.5")
    }

    private static func isClaudeOpus47(_ id: String) -> Bool {
        id.contains("opus") && (id.contains("4-7") || id.contains("4.7"))
    }

    private static func isClaudeCurrentFull(_ id: String) -> Bool {
        if id.contains("opus-5") || id.contains("sonnet-5") || id.contains("haiku-5") { return true }
        return id.contains("opus") && (id.contains("4-8") || id.contains("4.8"))
    }

    private static func isKimiK3(_ id: String) -> Bool {
        id.contains("kimi-k3") || id.hasSuffix("/k3") || id.contains("kimi/k3")
    }

    private static func isKimiK27Code(_ id: String) -> Bool {
        id.contains("k2.7-code") || id.contains("k2-7-code")
    }

    private static func isGlm53(_ id: String) -> Bool {
        id.contains("glm-5.3") || id.contains("glm-5-3")
    }

    private static func isGlm52(_ id: String) -> Bool {
        id.contains("glm-5.2") || id.contains("glm-5-2")
    }

    private static func isGlm5Effort(_ id: String) -> Bool {
        if isGlm53(id) || isGlm52(id) { return false }
        if id.contains("glm-5.1") || id.contains("glm-5-1") { return true }
        return id.range(of: #"(^|[^0-9])glm-5([^0-9.]|$)"#, options: .regularExpression) != nil
    }

    private static func isDeepSeekV4(_ id: String) -> Bool {
        id == "deepseek-flash" || (id.contains("deepseek") && (id.contains("v4") || id.contains("-4-")))
    }

    private static func isQwen38Max(_ id: String) -> Bool {
        id.contains("qwen") && id.contains("max") && (id.contains("3.8") || id.contains("3-8"))
    }

    private static func isMiniMaxM3(_ id: String) -> Bool {
        (id.contains("minimax") || id.contains("mini-max"))
            && id.range(of: #"(^|[^0-9])m3([^0-9]|$)"#, options: .regularExpression) != nil
    }

    private static func isMiniMaxM2(_ id: String) -> Bool {
        (id.contains("minimax") || id.contains("mini-max"))
            && id.range(of: #"(^|[^0-9])m2([^0-9]|$)"#, options: .regularExpression) != nil
    }

    private static func isQwenPlusBinary(_ id: String) -> Bool {
        guard id.contains("qwen"), id.contains("plus") else { return false }
        return id.range(of: #"(^|[^0-9])3[._-]?[56]([^0-9]|$)"#, options: .regularExpression) != nil
    }

    private static func isQwenReasoningModel(_ id: String) -> Bool {
        guard id.contains("qwen"), !id.contains("coder"), !id.contains("qwen-mt") else { return false }
        if id.contains("qwen3") || id.contains("qwen-3") { return true }
        return id.contains("qwen-plus") || id.contains("qwen-flash") || id.contains("qwen-turbo")
    }

    private static func geminiLevels(_ id: String) -> [DesktopReasoningLevel] {
        if id.contains("nano-banana") || id.contains("2.0-flash") || id.contains("2-0-flash")
            || id.contains("gemini-1") || id.contains("2.5-flash-image") || id.contains("3-pro-image") {
            return []
        }
        guard id.contains("2.5") || id.contains("2-5") || id.contains("gemini-3") || id.contains("3.")
            || id.contains("3-") || id == "gemini-flash-latest" || id == "gemini-pro-latest" else {
            return []
        }
        if id.contains("3.1") && id.contains("flash-lite") && id.contains("image") {
            return [.off, .auto, .high]
        }
        if id.contains("gemini-3-pro") && !id.contains("3.1") {
            return [.off, .auto, .low, .high]
        }
        return [.off, .auto, .low, .medium, .high]
    }

    private static func isGrok46(_ id: String) -> Bool {
        id.contains("grok-4.6") || id.contains("grok-4-6")
    }

    private static func isGrok45(_ id: String) -> Bool {
        id.contains("grok-4.5") || id.contains("grok-4-5")
    }

    private static func isOpenAIReasoningModel(_ id: String) -> Bool {
        if id.contains("gpt-5-chat") || id.contains("gpt-5.3") || id.contains("gpt-5-3") { return false }
        if id.contains("gpt-5") || id.contains("gpt-6") || id.contains("codex") || id.contains("gpt-oss") {
            return true
        }
        return id.range(of: #"(?:^|[-/])o\d+(?:$|[-.])"#, options: .regularExpression) != nil
    }
}

struct DesktopModelConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var modelID: String
    var name = ""
    var enabled = true
    var contextWindowTokens: Int?
    var temperature: Double?
    var maxOutputTokens: Int?
    var reasoning: DesktopReasoningLevel = .off
    var customHeaders: [String: String] = [:]
    var customBody: String?
    var supportsVision: Bool?

    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? modelID : name }

    func validated(for kind: DesktopProviderKind) throws -> DesktopModelConfiguration {
        var value = self
        value.modelID = value.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.modelID.isEmpty else { throw DesktopRuntimeError.message("请填写每个模型的 Model ID。") }
        if let contextWindowTokens, contextWindowTokens <= 0 || contextWindowTokens > Int(Int32.max) {
            throw DesktopRuntimeError.message("上下文窗口须为正整数。")
        }
        if let maxOutputTokens, maxOutputTokens <= 0 || maxOutputTokens > Int(Int32.max) {
            throw DesktopRuntimeError.message("最大输出须为正整数。")
        }
        if let temperature, !temperature.isFinite || temperature < 0 || temperature > (kind == .claude ? 1 : 2) {
            throw DesktopRuntimeError.message(kind == .claude ? "Claude 的 temperature 须为 0–1。" : "temperature 须为 0–2。")
        }
        let headerCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for (name, text) in customHeaders {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(headerCharacters.contains),
                  text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
                throw DesktopRuntimeError.message("请求头名称须为有效 HTTP 字段名，值不能包含换行或控制字符。")
            }
        }
        if let body = customBody?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            guard let data = body.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw DesktopRuntimeError.message("自定义请求体须为 JSON 对象。")
            }
            value.customBody = body
        } else { value.customBody = nil }
        return value
    }
}

extension DesktopModelConfiguration {
    private enum CodingKeys: String, CodingKey {
        case id, modelID, name, enabled, contextWindowTokens, temperature, maxOutputTokens, reasoning
        case customHeaders, customBody, supportsVision
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        modelID = try values.decode(String.self, forKey: .modelID)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        contextWindowTokens = try values.decodeIfPresent(Int.self, forKey: .contextWindowTokens)
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature)
        maxOutputTokens = try values.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        reasoning = try values.decodeIfPresent(DesktopReasoningLevel.self, forKey: .reasoning) ?? .off
        customHeaders = try values.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        customBody = try values.decodeIfPresent(String.self, forKey: .customBody)
        supportsVision = try values.decodeIfPresent(Bool.self, forKey: .supportsVision)
    }
}

struct DesktopModelSelection: Identifiable, Equatable, Sendable {
    let id: UUID
    let providerID: UUID
    let providerName: String
    let modelName: String
    let modelID: String
}

enum DesktopAuxiliaryModelTask: String, CaseIterable, Identifiable, Sendable {
    case recap, suggestions, compaction, vision, title, imageGeneration
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recap: "会话回顾"
        case .suggestions: "下一步建议"
        case .compaction: "上下文压缩"
        case .vision: "图片理解回退"
        case .title: "生成会话标题"
        case .imageGeneration: "图片生成"
        }
    }
}
