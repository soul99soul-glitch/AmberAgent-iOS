import Foundation
import Observation

/// Agent 形象人设的持久化模型（全局统一形象人设 + 历史快照 + C-SOUL-V1 云端同步）。
///
/// 设计取舍：
/// - 只有一个「当前形象人设」，不做多套并存，避免用户在多个自我之间失去主角感。
/// - 每次写入把旧版压入快照栈（最多 8 条），支持一键回退，而不是不可逆覆盖。
/// - `soulPrompt` 的正文仍由既有的 `agentRuntime.agentSoulMarkdown` 承载并注入
///   system prompt，本 store 只补上「称呼 / 签名 / 快照 / 修订号」这些需要的字段，
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

// MARK: - C-SOUL-V1 (`/v2/soul`) 跨端统一契约模型

struct CloudSoulHistoryItemPayload: Codable, Equatable, Sendable {
    var id: String
    var displayName: String
    var tagline: String
    var soulMarkdown: String
    var updatedAtMs: Int64
    var source: String
    var summary: String?

    init(
        id: String,
        displayName: String,
        tagline: String = "",
        soulMarkdown: String = "",
        updatedAtMs: Int64 = 0,
        source: String = "default",
        summary: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.tagline = tagline
        self.soulMarkdown = soulMarkdown
        self.updatedAtMs = updatedAtMs
        self.source = source
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, tagline, soulMarkdown, updatedAtMs, source, summary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? AgentSoulStore.defaultDisplayName
        tagline = try container.decodeIfPresent(String.self, forKey: .tagline) ?? ""
        soulMarkdown = try container.decodeIfPresent(String.self, forKey: .soulMarkdown) ?? ""
        updatedAtMs = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMs) ?? 0
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "default"
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
    }
}

struct CloudSoulSnapshotPayload: Codable, Equatable, Sendable {
    var revision: Int64
    var updatedAtMs: Int64
    var displayName: String
    var tagline: String
    var soulMarkdown: String
    var isDefault: Bool
    var source: String
    var history: [CloudSoulHistoryItemPayload]

    init(
        revision: Int64,
        updatedAtMs: Int64,
        displayName: String,
        tagline: String = "",
        soulMarkdown: String = "",
        isDefault: Bool = false,
        source: String = "default",
        history: [CloudSoulHistoryItemPayload] = []
    ) {
        self.revision = revision
        self.updatedAtMs = updatedAtMs
        self.displayName = displayName
        self.tagline = tagline
        self.soulMarkdown = soulMarkdown
        self.isDefault = isDefault
        self.source = source
        self.history = history
    }

    private enum CodingKeys: String, CodingKey {
        case revision, updatedAtMs, displayName, tagline, soulMarkdown, isDefault, source, history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        updatedAtMs = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMs) ?? 0
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? AgentSoulStore.defaultDisplayName
        tagline = try container.decodeIfPresent(String.self, forKey: .tagline) ?? ""
        soulMarkdown = try container.decodeIfPresent(String.self, forKey: .soulMarkdown) ?? ""
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "default"
        history = try container.decodeIfPresent([CloudSoulHistoryItemPayload].self, forKey: .history) ?? []
    }
}

struct CloudSoulPutRequestPayload: Codable, Equatable, Sendable {
    var displayName: String
    var tagline: String
    var soulMarkdown: String
    var isDefault: Bool
    var updatedAtMs: Int64
    var source: String
}

@MainActor
@Observable
final class AgentSoulStore {
    static let shared = AgentSoulStore()

    nonisolated static let defaultDisplayName = "Amber"
    nonisolated static let maximumSnapshots = 8
    nonisolated static let maximumNameLength = 32
    nonisolated static let maximumTaglineLength = 120
    nonisolated static let maximumSoulLength = 12_000

    private(set) var displayName: String
    private(set) var tagline: String
    private(set) var soulPrompt: String
    private(set) var updatedAtMs: Int64
    private(set) var source: AgentSoulSource
    private(set) var snapshots: [AgentSoulSnapshot]
    private(set) var lastSyncedRevision: Int64

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notePoster: (String) -> Void
    /// 既有的设置库（非单例）。用于把 soul 正文写进 system prompt 注入通道。
    @ObservationIgnored private let settingsStore: IOSSharedSettingsStore?
    /// 本地主动变更（UI 保存 / 回退 / 恢复默认 / 对话内工具自塑）时的上云回调。
    /// 注意：`applyCloudSoulSnapshot` 绝不触发此回调，严防拉取远端后再反向 PUT 形成死循环。
    @ObservationIgnored var localMutationHandler: ((AgentSoulStore, String) -> Void)?

    private enum Keys {
        static let displayName = "app.amber.ios.agentSoul.displayName"
        static let tagline = "app.amber.ios.agentSoul.tagline"
        static let soulPrompt = "app.amber.ios.agentSoul.soulPrompt"
        static let updatedAt = "app.amber.ios.agentSoul.updatedAt"
        static let source = "app.amber.ios.agentSoul.source"
        static let snapshots = "app.amber.ios.agentSoul.snapshots"
        static let lastSyncedRevision = "app.amber.ios.agentSoul.lastSyncedRevision"
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
        self.lastSyncedRevision = Int64(userDefaults.integer(forKey: Keys.lastSyncedRevision))
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

        lines.append("**当前形象人设（Soul）**")
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

    /// 常驻注入给模型的「形象人设（Soul）自塑与持久化」权责说明。
    /// 明确把「工程纪律底线（SOUL.md）」与「形象人设（人设 Soul）」解耦，
    /// 授权并要求模型在用户提出改人设/改称呼/写入 soul 时直接调用 `agent_soul_update`。
    nonisolated static let toolGuidanceSection: String = """
    **形象人设（人设 Soul）与工程底线分层规则（最高优先级）**
    - **底线与人设解耦**：`<agents_md>`（`SOUL.md`）中的“要证据、要回执、不瞎编、诚实执行工具”是你的底层工程纪律，永远保留；而你的外显「形象人设（Soul）」（称呼 `displayName`、一句话签名 `tagline`、性格口吻与相处方式 `soulPrompt`）存储在顶部「形象人设 · 人设 Soul」中，可随时按用户意愿更新，**修改形象人设绝不会破坏或扒掉你的工程底线**。
    - **直接调用 `agent_soul_update` 持久化**：当前会话已常驻挂载免审批工具 `agent_soul_get` 与 `agent_soul_update`。当用户在对话中要求更换人设、设定角色（如“弄一个逗逼靠谱的赵匡胤/赵大哥人设”）、修改你的称呼/签名/说话风格、或说“写入你的 soul / 改你的人设”时，你**必须立即直接调用 `agent_soul_update`**（传入 `displayName`、`tagline`、`soulPrompt` 及简短 `summary`）将新人设持久化写入形象人设。
    - **禁止拒绝与纠偏历史误判**：严禁回答“我没法改自己的 SOUL.md”、“需要你去改那份文件”或“只写进记忆里”。即使本会话早期消息中曾误称“无法修改 SOUL.md”，那也是旧回合未挂载工具时的过期说法——现在必须以本规则为准，直接调用 `agent_soul_update` 完成人设持久化更新，并立即按新称呼与新人设口吻回复用户。
    """

    /// 更新形象人设。旧版自动进快照栈（最多 8 条）。返回是否真的产生了变化。
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
        let cloudSource = (newSource == .conversation) ? "chat_self_update" : "ios_ui"
        localMutationHandler?(self, cloudSource)
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
        localMutationHandler?(self, "ios_ui")
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
        localMutationHandler?(self, "ios_ui")
        return true
    }

    // MARK: - C-SOUL-V1 云端双向同步 (`GET /v2/soul` & `PUT /v2/soul`)

    func makeCloudPutRequest(source cloudSource: String = "ios_ui") -> CloudSoulPutRequestPayload {
        CloudSoulPutRequestPayload(
            displayName: displayName,
            tagline: tagline,
            soulMarkdown: soulPrompt,
            isDefault: isDefault,
            updatedAtMs: updatedAtMs > 0 ? updatedAtMs : Self.nowMs(),
            source: cloudSource
        )
    }

    /// 应用来自远端 `GET /v2/soul` 或 `PUT /v2/soul` 的权威快照。
    /// - 重要：本方法带有同步来源守卫，绝不会触发 `localMutationHandler`，防止反向触发 `PUT /v2/soul` 死循环。
    /// - 若远端返回 `revision == 0` 且本地已有非默认自定义人设，自动触发一次 `localMutationHandler` 将本地人设上云初始化。
    @discardableResult
    func applyCloudSoulSnapshot(_ remote: CloudSoulSnapshotPayload) -> Bool {
        if remote.revision == 0 {
            if !isDefault, !soulPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let bootstrapSource = (source == .conversation) ? "chat_self_update" : "ios_ui"
                localMutationHandler?(self, bootstrapSource)
            }
            return false
        }

        let rawName = Self.clamp(remote.displayName, limit: Self.maximumNameLength)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (remote.isDefault || rawName.isEmpty) ? Self.defaultDisplayName : rawName
        let resolvedTagline = remote.isDefault
            ? ""
            : Self.clamp(remote.tagline, limit: Self.maximumTaglineLength)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSoul = remote.isDefault
            ? ""
            : Self.clamp(remote.soulMarkdown, limit: Self.maximumSoulLength)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSource: AgentSoulSource = (remote.source == "chat_self_update" || remote.source == "conversation")
            ? .conversation
            : .manual

        let contentChanged = resolvedName != displayName
            || resolvedTagline != tagline
            || resolvedSoul != soulPrompt

        var snapshotsChanged = false
        if !remote.history.isEmpty {
            let mappedSnapshots = remote.history.prefix(Self.maximumSnapshots).map { item in
                let histName = item.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                return AgentSoulSnapshot(
                    id: item.id,
                    displayName: histName.isEmpty ? Self.defaultDisplayName : histName,
                    tagline: item.tagline,
                    soulPrompt: item.soulMarkdown,
                    savedAtMs: item.updatedAtMs > 0 ? item.updatedAtMs : Self.nowMs(),
                    summary: Self.summaryLabel(forCloudSource: item.source, customSummary: item.summary)
                )
            }
            if mappedSnapshots != snapshots {
                snapshots = mappedSnapshots
                snapshotsChanged = true
            }
        } else if contentChanged {
            pushSnapshot(summary: "云端同步前自动保存")
            snapshotsChanged = true
        }

        if displayName != resolvedName { displayName = resolvedName }
        if tagline != resolvedTagline { tagline = resolvedTagline }
        if soulPrompt != resolvedSoul { soulPrompt = resolvedSoul }
        let resolvedUpdatedAtMs = remote.updatedAtMs > 0 ? remote.updatedAtMs : Self.nowMs()
        if contentChanged || (remote.updatedAtMs > 0 && updatedAtMs != remote.updatedAtMs) {
            updatedAtMs = resolvedUpdatedAtMs
        }
        if source != resolvedSource { source = resolvedSource }
        let revisionChanged = remote.revision > lastSyncedRevision
        if revisionChanged {
            lastSyncedRevision = remote.revision
        }
        if contentChanged || snapshotsChanged || revisionChanged {
            persist()
        }
        if contentChanged {
            publishSystemPrompt()
        }
        return contentChanged || revisionChanged
    }

    private static func summaryLabel(forCloudSource cloudSource: String, customSummary: String?) -> String {
        if let customSummary, !customSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customSummary
        }
        switch cloudSource {
        case "chat_self_update", "conversation":
            return "来自对话自塑"
        case "mac_ui":
            return "来自 Mac 端设定"
        case "ios_ui", "manual":
            return "来自手动编辑"
        case "default":
            return "默认版本"
        default:
            return "历史版本"
        }
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
        defaults.set(Int(lastSyncedRevision), forKey: Keys.lastSyncedRevision)
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
