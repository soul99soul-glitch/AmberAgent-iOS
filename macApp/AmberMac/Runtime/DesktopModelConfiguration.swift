import Foundation

enum DesktopReasoningLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, auto, low, medium, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "关闭"
        case .auto: "自动"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        }
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
