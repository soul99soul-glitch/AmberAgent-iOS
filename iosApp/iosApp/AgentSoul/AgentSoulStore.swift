import Foundation
import Observation

/// Agent 化身主页的持久化模型（唯一全局化身 + 历史快照）。
///
/// 设计取舍：
/// - 只有一个「当前化身」，不做多化身并存，避免用户在多个自我之间失去主角感。
/// - 每次写入把旧版压入快照栈（最多 8 条），支持一键回退，而不是不可逆覆盖。
/// - `soulPrompt` 的正文仍由既有的 `agentRuntime.agentSoulMarkdown` 承载并注入
///   system prompt，本 store 只补上「称呼 / 签名 / 快照」这些主页需要的东西，
///   不另造第二条注入链路。

struct AgentSoulSnapshot: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
    var tagline: String
    var soulPrompt: String
    var savedAtMs: Int64
    var summary: String?

    var savedAt: Date { Date(timeIntervalSince1970: Double(savedAtMs) / 1000) }
}

enum AgentSoulSource: String, Codable, Equatable {
    case manual
    case conversation
}

@MainActor
@Observable
final class AgentSoulStore {
    static let shared = AgentSoulStore()

    static let defaultDisplayName = "Amber"
    static let maximumSnapshots = 8
    static let maximumNameLength = 32
    static let maximumTaglineLength = 120
    static let maximumSoulLength = 12_000

    private(set) var displayName: String
    private(set) var tagline: String
    private(set) var soulPrompt: String
    private(set) var updatedAtMs: Int64
    private(set) var source: AgentSoulSource
    private(set) var snapshots: [AgentSoulSnapshot]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notePoster: (String) -> Void
    /// 既有的设置库（非单例）。用于把 soul 正文写进 system prompt 注入通道。
    @ObservationIgnored private let settingsStore: IOSSharedSettingsStore?

    private enum Keys {
        static let displayName = "app.amber.ios.agentSoul.displayName"
        static let tagline = "app.amber.ios.agentSoul.tagline"
        static let soulPrompt = "app.amber.ios.agentSoul.soulPrompt"
        static let updatedAt = "app.amber.ios.agentSoul.updatedAt"
        static let source = "app.amber.ios.agentSoul.source"
        static let snapshots = "app.amber.ios.agentSoul.snapshots"
    }

    /// - Parameters:
    ///   - settingsStore: 既有的设置库；传入后 soul 变更会同步进 system prompt 注入通道。
    ///   - notePoster: 测试替身，用来替代真实设置库写入。
    init(
        userDefaults: UserDefaults = .standard,
        settingsStore: IOSSharedSettingsStore? = nil,
        notePoster: ((String) -> Void)? = nil
    ) {
        self.defaults = userDefaults
        self.settingsStore = settingsStore
        if let notePoster {
            self.notePoster = notePoster
        } else if let settingsStore {
            self.notePoster = { markdown in settingsStore.setAgentSoulMarkdown(markdown) }
        } else {
            self.notePoster = { _ in }
        }
        self.displayName = userDefaults.string(forKey: Keys.displayName) ?? Self.defaultDisplayName
        self.tagline = userDefaults.string(forKey: Keys.tagline) ?? ""
        self.soulPrompt = userDefaults.string(forKey: Keys.soulPrompt) ?? ""
        self.updatedAtMs = Int64(userDefaults.double(forKey: Keys.updatedAt) * 1000)
        self.source = AgentSoulSource(rawValue: userDefaults.string(forKey: Keys.source) ?? "") ?? .manual
        if let data = userDefaults.data(forKey: Keys.snapshots),
           let decoded = try? JSONDecoder().decode([AgentSoulSnapshot].self, from: data) {
            self.snapshots = decoded
        } else {
            self.snapshots = []
        }
        // 首次启动：把已存在的 soul markdown 认作当前正文，避免主页显示空。
        if self.soulPrompt.isEmpty,
           let legacy = settingsStore?.snapshot.agentRuntime.agentSoulMarkdown
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !legacy.isEmpty {
            self.soulPrompt = legacy
        }
    }

    var isDefault: Bool {
        displayName == Self.defaultDisplayName
            && tagline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && soulPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 注入 system prompt 的正文：称呼 + 签名 + 完整灵魂设定。
    var systemPromptSection: String {
        var lines: [String] = []
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let signature = tagline.trimmingCharacters(in: .whitespacesAndNewlines)
        let soul = soulPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // 默认形态（称呼 Amber、无签名、无正文）不得注入任何内容，
        // 否则每轮都往 system prompt 塞一段空壳说明。
        guard !signature.isEmpty || !soul.isEmpty || name != Self.defaultDisplayName else { return "" }

        lines.append("**当前角色化身（Soul）**")
        if !name.isEmpty, name != Self.defaultDisplayName {
            lines.append("- 你在本对话中的称呼是「\(name)」。以这个名字自然地指代自己。")
        }
        if !signature.isEmpty {
            lines.append("- 一句话气质：\(signature)")
        }
        if !soul.isEmpty {
            lines.append("")
            lines.append("- 角色性格、语气与相处方式：")
            lines.append(soul)
        }
        lines.append("")
        lines.append("保持以上称呼、性格与口吻自然交流；同时完整保留既有的工具调用、后台任务与安全边界能力，")
        lines.append("不因角色扮演而拒绝本应执行的工具操作。")
        return lines.joined(separator: "\n")
    }

    /// 更新化身。旧版自动进快照栈（最多 8 条）。返回是否真的产生了变化。
    @discardableResult
    func update(
        displayName newName: String,
        tagline newTagline: String?,
        soulPrompt newSoul: String,
        summary: String? = nil,
        source newSource: AgentSoulSource = .conversation
    ) -> Bool {
        let name = Self.clamp(newName, limit: Self.maximumNameLength)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let taglineValue = Self.clamp(newTagline ?? "", limit: Self.maximumTaglineLength)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let soul = Self.clamp(newSoul, limit: Self.maximumSoulLength)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedName = name.isEmpty ? Self.defaultDisplayName : name
        guard resolvedName != displayName || taglineValue != tagline || soul != soulPrompt else {
            return false
        }

        pushSnapshot(summary: summary)
        displayName = resolvedName
        tagline = taglineValue
        soulPrompt = soul
        updatedAtMs = Self.nowMs()
        source = newSource
        persist()
        publishSystemPrompt()
        return true
    }

    /// 一键回退到某个快照（同样把当前版本压栈，回退也可再回退）。
    @discardableResult
    func restore(snapshotID: String) -> Bool {
        guard let snapshot = snapshots.first(where: { $0.id == snapshotID }) else { return false }
        pushSnapshot(summary: "回退前自动保存")
        displayName = snapshot.displayName
        tagline = snapshot.tagline
        soulPrompt = snapshot.soulPrompt
        updatedAtMs = Self.nowMs()
        source = .manual
        persist()
        publishSystemPrompt()
        return true
    }

    /// 恢复默认 Amber：清空称呼/签名/设定，并保留一次可回退的快照。
    @discardableResult
    func resetToDefault() -> Bool {
        guard !isDefault else { return false }
        pushSnapshot(summary: "恢复默认前自动保存")
        displayName = Self.defaultDisplayName
        tagline = ""
        soulPrompt = ""
        updatedAtMs = Self.nowMs()
        source = .manual
        persist()
        publishSystemPrompt()
        return true
    }

    // MARK: - 快照

    private func pushSnapshot(summary: String?) {
        let current = AgentSoulSnapshot(
            id: UUID().uuidString,
            displayName: displayName,
            tagline: tagline,
            soulPrompt: soulPrompt,
            savedAtMs: updatedAtMs > 0 ? updatedAtMs : Self.nowMs(),
            summary: summary
        )
        // 未初始化的空白不值得占一档，否则首次设置会先存一条空气。
        // 注意：只要用户此前设过称呼/签名/正文，哪怕正文为空也要留档，
        // 否则「先改名、再写正文」会把改名那一步从历史里抹掉。
        guard current.soulPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || current.displayName != Self.defaultDisplayName
            || !current.tagline.isEmpty else { return }
        snapshots.insert(current, at: 0)
        if snapshots.count > Self.maximumSnapshots {
            snapshots = Array(snapshots.prefix(Self.maximumSnapshots))
        }
    }

    /// 供「灵感」生成等只读场景使用的摘要文本。
    var snapshotDigest: String {
        guard !snapshots.isEmpty else { return "（无历史快照）" }
        return snapshots.prefix(3).enumerated().map { index, snapshot in
            let label = snapshot.summary?.isEmpty == false ? snapshot.summary! : "历史版本"
            return "\(index + 1). \(snapshot.displayName) · \(label)"
        }.joined(separator: "\n")
    }

    // MARK: - 持久化

    private func persist() {
        defaults.set(displayName, forKey: Keys.displayName)
        defaults.set(tagline, forKey: Keys.tagline)
        defaults.set(soulPrompt, forKey: Keys.soulPrompt)
        defaults.set(Double(updatedAtMs) / 1000, forKey: Keys.updatedAt)
        defaults.set(source.rawValue, forKey: Keys.source)
        if let data = try? JSONEncoder().encode(snapshots) {
            defaults.set(data, forKey: Keys.snapshots)
        }
    }

    private func publishSystemPrompt() {
        notePoster(soulPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func clamp(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }
}
