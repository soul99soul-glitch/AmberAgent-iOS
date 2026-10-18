import Foundation
import Observation
@preconcurrency import Shared

struct IOSCouncilSeatDescriptor: Equatable, Identifiable {
    let id: String
    let name: String
    let role: String
    let modelLabel: String
}

enum IOSCouncilReasoningPreset: String, Codable, CaseIterable, Identifiable {
    case off
    case auto
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .auto: "Auto"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "X High"
        case .max: "Max"
        }
    }

    var reasoningLevel: ReasoningLevel {
        switch self {
        case .off: .off
        case .auto: .auto_
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .xhigh: .xhigh
        case .max: .max
        }
    }
}

struct IOSCouncilRoomSeatConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var rolePrompt: String
    var modelId: String
    var reasoning: IOSCouncilReasoningPreset
    var prompt: String
    var isDefault: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        rolePrompt: String,
        modelId: String,
        reasoning: IOSCouncilReasoningPreset = .off,
        prompt: String = "",
        isDefault: Bool = true
    ) {
        self.id = id
        self.name = name
        self.rolePrompt = rolePrompt
        self.modelId = modelId
        self.reasoning = reasoning
        self.prompt = prompt
        self.isDefault = isDefault
    }

    func normalized(currentModelId: String) -> IOSCouncilRoomSeatConfig {
        var copy = self
        copy.name = copy.name.trimmedOr("未命名席位")
        copy.rolePrompt = copy.rolePrompt.trimmedOr(copy.name)
        copy.modelId = copy.modelId.trimmedOr(currentModelId)
        copy.prompt = copy.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

/// 预制席位角色,供「添加席位」面板选择(Android lens 预设 + 几个常用扩展)。
/// modelId 留空 → 运行时由 resolveSeatModel 落到主持人的工作模型。
struct IOSCouncilSeatPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let rolePrompt: String
    let reasoning: IOSCouncilReasoningPreset

    static let all: [IOSCouncilSeatPreset] = [
        .init(id: "engineering", name: "工程", rolePrompt: "从工程可行性、实现复杂度、系统边界和维护成本审视议题。", reasoning: .medium),
        .init(id: "product", name: "产品", rolePrompt: "从用户价值、需求优先级、产品体验和上线取舍审视议题。", reasoning: .medium),
        .init(id: "marketing", name: "营销", rolePrompt: "从市场定位、增长渠道、传播路径和获客成本审视议题。", reasoning: .medium),
        .init(id: "pr", name: "公关", rolePrompt: "从品牌形象、舆论风险、对外口径和危机应对审视议题。", reasoning: .medium),
        .init(id: "design", name: "设计", rolePrompt: "从用户体验、交互流程、可用性和情感化设计审视议题。", reasoning: .medium),
        .init(id: "risk", name: "风险", rolePrompt: "从隐私、安全、成本、失败模式和误用风险审视议题。", reasoning: .high),
        .init(id: "opponent", name: "反方", rolePrompt: "主动提出反例、盲区和反对意见，压测方案是否成立。", reasoning: .high),
        .init(id: "data", name: "数据", rolePrompt: "从数据指标、度量口径、实验设计和因果推断审视议题。", reasoning: .medium),
        .init(id: "legal", name: "法务", rolePrompt: "从合规、法律风险、知识产权和监管要求审视议题。", reasoning: .high),
        .init(id: "finance", name: "财务", rolePrompt: "从成本结构、投入产出、现金流和商业模式审视议题。", reasoning: .medium),
    ]

    func asSeat() -> IOSCouncilRoomSeatConfig {
        IOSCouncilRoomSeatConfig(
            id: id, name: name, rolePrompt: rolePrompt,
            modelId: "", reasoning: reasoning, prompt: "", isDefault: true
        )
    }
}

struct IOSCouncilHostConfig: Codable, Equatable {
    var modelId: String
    var reasoning: IOSCouncilReasoningPreset
    var prompt: String

    func normalized(currentModelId: String) -> IOSCouncilHostConfig {
        IOSCouncilHostConfig(
            modelId: modelId.trimmedOr(currentModelId),
            reasoning: reasoning,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct IOSCouncilRoomLimits: Codable, Equatable {
    var maxSeats: Int
    var defaultRounds: Int
    var seatTimeoutSeconds: Int
    var outputBudgetCharacters: Int

    func normalized() -> IOSCouncilRoomLimits {
        IOSCouncilRoomLimits(
            maxSeats: min(max(maxSeats, 2), 8),
            // 总轮次限制 1-5 轮（所有成员发言一遍 = 一轮），避免无限辩论。
            // 下限放宽到 1：freeChat/debate 都允许单轮快速议会（parity 修复）。
            defaultRounds: min(max(defaultRounds, 1), 5),
            seatTimeoutSeconds: min(max(seatTimeoutSeconds, 15), 180),
            outputBudgetCharacters: min(max(outputBudgetCharacters, 2_000), 40_000)
        )
    }
}

struct IOSCouncilRoomSettings: Codable, Equatable {
    var host: IOSCouncilHostConfig
    var seats: [IOSCouncilRoomSeatConfig]
    var limits: IOSCouncilRoomLimits
    var legacySeatsImported: Bool

    static func defaults(currentModelId: String = "gpt-4o") -> IOSCouncilRoomSettings {
        IOSCouncilRoomSettings(
            host: IOSCouncilHostConfig(
                modelId: currentModelId,
                reasoning: .off,
                prompt: "你是 AmberAgent 模型议会主持人。先调研和完善议题，再组织席位顺序发言，最后给出清晰结论。"
            ),
            seats: [
                IOSCouncilRoomSeatConfig(
                    id: "engineering",
                    name: "工程",
                    rolePrompt: "从工程可行性、实现复杂度、系统边界和维护成本审视议题。",
                    modelId: currentModelId,
                    reasoning: .medium,
                    prompt: "",
                    isDefault: true
                ),
                IOSCouncilRoomSeatConfig(
                    id: "product",
                    name: "产品",
                    rolePrompt: "从用户价值、需求优先级、产品体验和上线取舍审视议题。",
                    modelId: currentModelId,
                    reasoning: .medium,
                    prompt: "",
                    isDefault: true
                ),
                IOSCouncilRoomSeatConfig(
                    id: "risk",
                    name: "风险",
                    rolePrompt: "从隐私、安全、成本、失败模式和误用风险审视议题。",
                    modelId: currentModelId,
                    reasoning: .high,
                    prompt: "",
                    isDefault: true
                ),
                IOSCouncilRoomSeatConfig(
                    id: "opponent",
                    name: "反方",
                    rolePrompt: "主动提出反例、盲区和反对意见，压测方案是否成立。",
                    modelId: currentModelId,
                    reasoning: .high,
                    prompt: "",
                    isDefault: false
                )
            ],
            limits: IOSCouncilRoomLimits(
                maxSeats: 4,
                defaultRounds: 2,
                seatTimeoutSeconds: 60,
                outputBudgetCharacters: 12_000
            ),
            legacySeatsImported: false
        )
    }

    func normalized(currentModelId: String) -> IOSCouncilRoomSettings {
        let normalizedLimits = limits.normalized()
        var seen = Set<String>()
        let normalizedSeats = seats.compactMap { seat -> IOSCouncilRoomSeatConfig? in
            let normalized = seat.normalized(currentModelId: currentModelId)
            guard !normalized.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard seen.insert(normalized.id).inserted else { return nil }
            return normalized
        }
        return IOSCouncilRoomSettings(
            host: host.normalized(currentModelId: currentModelId),
            seats: normalizedSeats,
            limits: normalizedLimits,
            legacySeatsImported: legacySeatsImported
        )
    }

    func defaultSeats(currentModelId: String) -> [IOSCouncilRoomSeatConfig] {
        let normalized = normalized(currentModelId: currentModelId)
        let defaults = normalized.seats.filter(\.isDefault)
        let selected = defaults.isEmpty ? normalized.seats : defaults
        return Array(selected.prefix(normalized.limits.maxSeats))
    }
}

@MainActor
@Observable
final class IOSCouncilRoomSettingsStore {
    static let shared = IOSCouncilRoomSettingsStore()

    var settings: IOSCouncilRoomSettings {
        didSet { persist() }
    }

    /// 主持人是否可按议题自由动态生成席位。开:自由组建;关:只能用下方已添加的席位。
    /// 单独存一个 UserDefaults 键(不塞进 Codable settings,避免给老数据加字段导致解码失败重置)。
    var dynamicSeatGeneration: Bool {
        didSet { userDefaults.set(dynamicSeatGeneration, forKey: Self.dynamicSeatKey) }
    }

    private static let dynamicSeatKey = "app.amber.ios.councilDynamicSeatGeneration.v1"

    /// 席位发言前是否联网查证一轮。独立 UserDefaults 键,默认关(用户显式开启才联网,
    /// 避免无谓的网络/成本);老数据无此键时按关起步。
    var seatWebSearch: Bool {
        didSet { userDefaults.set(seatWebSearch, forKey: Self.seatWebSearchKey) }
    }

    private static let seatWebSearchKey = "app.amber.ios.councilSeatWebSearch.v1"

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "app.amber.ios.councilRoomSettings.v1",
        currentModelId: String = "gpt-4o"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? decoder.decode(IOSCouncilRoomSettings.self, from: data) {
            self.settings = decoded.normalized(currentModelId: currentModelId)
        } else {
            self.settings = IOSCouncilRoomSettings.defaults(currentModelId: currentModelId)
        }
        // 默认开启动态生成(老用户/首次进入都按"自由组建"起步)。
        self.dynamicSeatGeneration = (userDefaults.object(forKey: Self.dynamicSeatKey) as? Bool) ?? true
        // 席位联网查证默认关:联网更慢更耗,需用户在设置里显式开启。
        self.seatWebSearch = (userDefaults.object(forKey: Self.seatWebSearchKey) as? Bool) ?? false
    }

    func bootstrapLegacySeatsIfNeeded(_ legacySeats: [[String: String]], currentModelId: String) {
        guard !settings.legacySeatsImported else { return }
        var merged = settings.normalized(currentModelId: currentModelId)
        let existing = Set(merged.seats.map { $0.name.lowercased() })
        for seat in legacySeats {
            guard let name = seat["name"]?.trimmedNilIfBlank else { continue }
            guard !existing.contains(name.lowercased()) else { continue }
            merged.seats.append(IOSCouncilRoomSeatConfig(
                name: name,
                rolePrompt: seat["role"]?.trimmedNilIfBlank ?? name,
                modelId: seat["modelId"]?.trimmedNilIfBlank ?? currentModelId,
                reasoning: .off,
                prompt: "",
                isDefault: true
            ))
        }
        merged.legacySeatsImported = true
        settings = merged
    }

    func updateHost(modelId: String? = nil, reasoning: IOSCouncilReasoningPreset? = nil, prompt: String? = nil) {
        var copy = settings
        if let modelId { copy.host.modelId = modelId }
        if let reasoning { copy.host.reasoning = reasoning }
        if let prompt { copy.host.prompt = prompt }
        settings = copy
    }

    func updateLimits(maxSeats: Int? = nil, defaultRounds: Int? = nil, seatTimeoutSeconds: Int? = nil, outputBudgetCharacters: Int? = nil) {
        var copy = settings
        if let maxSeats { copy.limits.maxSeats = maxSeats }
        if let defaultRounds { copy.limits.defaultRounds = defaultRounds }
        if let seatTimeoutSeconds { copy.limits.seatTimeoutSeconds = seatTimeoutSeconds }
        if let outputBudgetCharacters { copy.limits.outputBudgetCharacters = outputBudgetCharacters }
        settings = copy.normalized(currentModelId: copy.host.modelId)
    }

    func addOrUpdateSeat(_ seat: IOSCouncilRoomSeatConfig, currentModelId: String) {
        var copy = settings.normalized(currentModelId: currentModelId)
        let normalized = seat.normalized(currentModelId: currentModelId)
        if let index = copy.seats.firstIndex(where: { $0.id == normalized.id }) {
            copy.seats[index] = normalized
        } else {
            copy.seats.append(normalized)
        }
        settings = copy
    }

    func removeSeat(id: String) {
        var copy = settings
        copy.seats.removeAll { $0.id == id }
        settings = copy
    }

    func toggleDefaultSeat(id: String) {
        var copy = settings
        guard let index = copy.seats.firstIndex(where: { $0.id == id }) else { return }
        copy.seats[index].isDefault.toggle()
        settings = copy
    }

    func removeAllCustomSeats() {
        var copy = settings
        copy.seats.removeAll()
        settings = copy
    }

    private func persist() {
        if let data = try? encoder.encode(settings) {
            userDefaults.set(data, forKey: storageKey)
        }
    }
}


private extension String {
    func trimmedOr(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    var trimmedNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

