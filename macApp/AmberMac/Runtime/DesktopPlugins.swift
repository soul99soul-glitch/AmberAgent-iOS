import CryptoKit
import Foundation
import JavaScriptCore
import Observation

// MARK: - Core Plugins (Obsidian-style built-in feature switches)

enum DesktopCorePlugin: String, Codable, CaseIterable, Identifiable, Sendable {
    case taskBoard = "task_board"
    case knowledge = "knowledge"
    case collaborations = "collaborations"
    case recipes = "recipes"
    case imageGeneration = "image_generation"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .taskBoard: "任务看板与定时任务"
        case .knowledge: "知识与长期记忆"
        case .collaborations: "多模型协作与议会"
        case .recipes: "Recipe 自动流程"
        case .imageGeneration: "图片生成工作台"
        }
    }

    var symbol: String {
        switch self {
        case .taskBoard: "clock"
        case .knowledge: "brain"
        case .collaborations: "person.3"
        case .recipes: "list.number"
        case .imageGeneration: "photo.badge.plus"
        }
    }

    var summary: String {
        switch self {
        case .taskBoard: "在侧栏与主工作区查看排定的定时任务、待批准项与 Claude Code / Codex 会话。"
        case .knowledge: "管理本地技能（SKILL.md）、长期记忆库与 SOUL.md 偏好设定。"
        case .collaborations: "在对话中派发只读子代理并行调研，或召开多模型议会辩论汇总。"
        case .recipes: "将多步工具调用固化为可复用的自动化 Recipe 流程。"
        case .imageGeneration: "调用已配置的图像模型生成图片并保存到当前会话工作区。"
        }
    }

    var governedToolNames: Set<String> {
        switch self {
        case .taskBoard: ["schedule_list", "schedule_create", "schedule_update"]
        case .knowledge: ["skills_list", "use_skill", "skill_enable", "skill_disable", "memory_tool"]
        case .collaborations: ["subagent_dispatch", "list_agents", "interrupt_agent", "model_council_run"]
        case .recipes, .imageGeneration: []
        }
    }
}

// MARK: - Extension Plugin Manifest (amber.plugin.v2, compatible with amber.plugin.v1)

struct DesktopPluginCapabilities: Codable, Equatable, Sendable {
    var networkDomains: [String]
    var workspaceReadPrefixes: [String]
    var workspaceWritePrefixes: [String]
    /// Host-native modules this plugin is implemented by (for example `calendar` = macOS EventKit).
    /// A JS sandbox cannot reach EventKit, so a plugin either declares the module and the host runs it,
    /// or it must read as declared-but-not-wired in the settings page. Never claim it silently.
    var hostModules: [String]

    init(networkDomains: [String] = [], workspaceReadPrefixes: [String] = [], workspaceWritePrefixes: [String] = [],
         hostModules: [String] = []) {
        self.networkDomains = networkDomains
        self.workspaceReadPrefixes = workspaceReadPrefixes
        self.workspaceWritePrefixes = workspaceWritePrefixes
        self.hostModules = hostModules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        networkDomains = try container.decodeIfPresent([String].self, forKey: .networkDomains) ?? []
        workspaceReadPrefixes = try container.decodeIfPresent([String].self, forKey: .workspaceReadPrefixes) ?? []
        workspaceWritePrefixes = try container.decodeIfPresent([String].self, forKey: .workspaceWritePrefixes) ?? []
        hostModules = try container.decodeIfPresent([String].self, forKey: .hostModules) ?? []
    }
}

/// Built-in plugins backed by macOS frameworks instead of the JS sandbox.
/// The manifest declares the module; this type decides whether the host actually implements it.
enum DesktopPluginHostModule: String, Sendable {
    /// `EKEventStore`: read, create, update and delete events in the user's own calendar.
    case calendar

    /// The only modules this build actually wires into a host implementation.
    static let implemented: Set<DesktopPluginHostModule> = [.calendar]

    var title: String {
        switch self {
        // The capability matrix gives each name an 84pt column; EventKit lives in the detail line instead.
        case .calendar: "本机日历"
        }
    }

    var wiredDetail: String {
        switch self {
        case .calendar: "经宿主原生 EventKit 读写本机日历；新增、修改与删除仍需你在 Mac 上批准。"
        }
    }

    func isWired(for plugin: DesktopInstalledPlugin) -> Bool {
        guard plugin.isBuiltIn, Self.implemented.contains(self) else { return false }
        switch self {
        case .calendar:
            return plugin.id == DesktopAppleScheduleTools.pluginID
        }
    }

    static let unwiredDetail = "声明了宿主模块，但当前版本没有对应实现。"
    static let thirdPartyRejectedDetail = "宿主模块仅供官方内置插件使用，第三方插件不接线。"
}

struct DesktopPluginSettingField: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case string, secret, boolean, integer }
    var id: String { key }
    let key: String
    let title: String
    let kind: Kind
    var placeholder: String = ""
    var defaultValue: String = ""
    var help: String? = nil
    var group: String = ""

    enum CodingKeys: String, CodingKey {
        case key, title, kind, placeholder, defaultValue, defaultValueSnake = "default_value", help, group
    }

    init(
        key: String,
        title: String,
        kind: Kind,
        placeholder: String = "",
        defaultValue: String = "",
        help: String? = nil,
        group: String = ""
    ) {
        self.key = key
        self.title = title
        self.kind = kind
        self.placeholder = placeholder
        self.defaultValue = defaultValue
        self.help = help
        self.group = group
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .string
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
            ?? (try container.decodeIfPresent(String.self, forKey: .defaultValueSnake))
            ?? ""
        help = try container.decodeIfPresent(String.self, forKey: .help)
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        if !placeholder.isEmpty { try container.encode(placeholder, forKey: .placeholder) }
        if !defaultValue.isEmpty { try container.encode(defaultValue, forKey: .defaultValue) }
        try container.encodeIfPresent(help, forKey: .help)
        if !group.isEmpty { try container.encode(group, forKey: .group) }
    }
}

struct DesktopPluginToolManifest: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    var effect: DesktopToolEffect = .pure
    var entry: String
    var parametersJSON: String

    enum CodingKeys: String, CodingKey {
        case name, description, effect, entry, script, parametersJSON = "parameters_json", inputSchema = "input_schema", inputs
    }

    init(name: String, description: String, effect: DesktopToolEffect = .pure, entry: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.effect = effect
        self.entry = entry
        self.parametersJSON = parametersJSON
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? name
        if let rawEffect = try container.decodeIfPresent(String.self, forKey: .effect) {
            if rawEffect == "readOnly" {
                effect = .pure
            } else if let parsed = DesktopToolEffect(rawValue: rawEffect) {
                effect = parsed
            } else {
                effect = .pure
            }
        } else {
            effect = .pure
        }
        if let explicitEntry = try container.decodeIfPresent(String.self, forKey: .entry) {
            entry = explicitEntry
        } else if let script = try container.decodeIfPresent(String.self, forKey: .script) {
            entry = script
        } else {
            entry = name
        }
        if let rawJSON = try container.decodeIfPresent(String.self, forKey: .parametersJSON) {
            parametersJSON = rawJSON
        } else if let schemaObj = try container.decodeIfPresent([String: DesktopRecipeJSONValue].self, forKey: .inputSchema) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            parametersJSON = String(decoding: try encoder.encode(schemaObj), as: UTF8.self)
        } else if let legacyInputs = try container.decodeIfPresent([String: String].self, forKey: .inputs) {
            let props = legacyInputs.mapValues { ["type": $0] }
            let schema: [String: Any] = [
                "type": "object",
                "properties": props,
                "required": Array(legacyInputs.keys).sorted(),
                "additionalProperties": false
            ]
            let data = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
            parametersJSON = String(decoding: data, as: UTF8.self)
        } else {
            parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(effect.rawValue, forKey: .effect)
        try container.encode(entry, forKey: .entry)
        try container.encode(parametersJSON, forKey: .parametersJSON)
    }
}

struct DesktopPluginInspectorCardManifest: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    var symbol: String = "rectangle.stack"
    var entry: String = "renderInspector"

    enum CodingKeys: String, CodingKey { case id, title, symbol, entry }

    init(id: String, title: String, symbol: String = "rectangle.stack", entry: String = "renderInspector") {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.entry = entry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "rectangle.stack"
        entry = try container.decodeIfPresent(String.self, forKey: .entry) ?? "renderInspector"
    }
}

struct DesktopPluginWorkspaceViewManifest: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    var symbol: String = "calendar"
    var subtitle: String = ""

    enum CodingKeys: String, CodingKey { case id, title, symbol, subtitle }

    init(id: String, title: String, symbol: String = "calendar", subtitle: String = "") {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "calendar"
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
    }
}

struct DesktopPluginCommandManifest: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let slash: String
    var symbol: String = "bolt"
    let promptTemplate: String

    enum CodingKeys: String, CodingKey {
        case id, title, slash, symbol, promptTemplate, promptTemplateSnake = "prompt_template"
    }

    init(id: String, title: String, slash: String, symbol: String = "bolt", promptTemplate: String) {
        self.id = id
        self.title = title
        self.slash = slash
        self.symbol = symbol
        self.promptTemplate = promptTemplate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        slash = try container.decode(String.self, forKey: .slash)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "bolt"
        promptTemplate = try container.decodeIfPresent(String.self, forKey: .promptTemplate)
            ?? (try container.decodeIfPresent(String.self, forKey: .promptTemplateSnake))
            ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(slash, forKey: .slash)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(promptTemplate, forKey: .promptTemplate)
    }
}

struct DesktopPluginUIManifest: Codable, Equatable, Sendable {
    var inspectorCards: [DesktopPluginInspectorCardManifest]
    var workspaceViews: [DesktopPluginWorkspaceViewManifest]
    var commands: [DesktopPluginCommandManifest]

    init(
        inspectorCards: [DesktopPluginInspectorCardManifest] = [],
        workspaceViews: [DesktopPluginWorkspaceViewManifest] = [],
        commands: [DesktopPluginCommandManifest] = []
    ) {
        self.inspectorCards = inspectorCards
        self.workspaceViews = workspaceViews
        self.commands = commands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inspectorCards = try container.decodeIfPresent([DesktopPluginInspectorCardManifest].self, forKey: .inspectorCards) ?? []
        workspaceViews = try container.decodeIfPresent([DesktopPluginWorkspaceViewManifest].self, forKey: .workspaceViews) ?? []
        commands = try container.decodeIfPresent([DesktopPluginCommandManifest].self, forKey: .commands) ?? []
    }
}

struct DesktopPluginManifest: Codable, Equatable, Identifiable, Sendable {
    static let schemaV2 = "amber.plugin.v2"
    static let schemaV1 = "amber.plugin.v1"

    var schema: String = DesktopPluginManifest.schemaV2
    let id: String
    let name: String
    let version: String
    let description: String
    var icon: String = "puzzlepiece.extension"
    var capabilities: DesktopPluginCapabilities = .init()
    var settingsSchema: [DesktopPluginSettingField] = []
    var tools: [DesktopPluginToolManifest] = []
    var ui: DesktopPluginUIManifest = .init()

    enum CodingKeys: String, CodingKey {
        case schema, id, name, version, description, icon, capabilities
        case settingsSchema = "settings_schema"
        case tools, ui
    }

    init(
        schema: String = DesktopPluginManifest.schemaV2,
        id: String,
        name: String,
        version: String,
        description: String,
        icon: String = "puzzlepiece.extension",
        capabilities: DesktopPluginCapabilities = .init(),
        settingsSchema: [DesktopPluginSettingField] = [],
        tools: [DesktopPluginToolManifest] = [],
        ui: DesktopPluginUIManifest = .init()
    ) {
        self.schema = schema
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.icon = icon
        self.capabilities = capabilities
        self.settingsSchema = settingsSchema
        self.tools = tools
        self.ui = ui
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? Self.schemaV2
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        description = try container.decode(String.self, forKey: .description)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "puzzlepiece.extension"
        capabilities = try container.decodeIfPresent(DesktopPluginCapabilities.self, forKey: .capabilities) ?? .init()
        settingsSchema = try container.decodeIfPresent([DesktopPluginSettingField].self, forKey: .settingsSchema) ?? []
        tools = try container.decodeIfPresent([DesktopPluginToolManifest].self, forKey: .tools) ?? []
        ui = try container.decodeIfPresent(DesktopPluginUIManifest.self, forKey: .ui) ?? .init()
    }

    func validated() throws {
        guard schema == Self.schemaV2 || schema == Self.schemaV1 else {
            throw DesktopRuntimeError.message("插件 schema 须为 amber.plugin.v2 或 amber.plugin.v1。")
        }
        guard Self.isValidIdentifier(id, minLength: 2) else {
            throw DesktopRuntimeError.message("插件 id 无效：\(id)（须为 2–32 位小写字母、数字或下划线）。")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopRuntimeError.message("插件 name、version 与 description 不能为空。")
        }
        var seenTools = Set<String>()
        for tool in tools {
            guard Self.isValidIdentifier(tool.name, minLength: 1), seenTools.insert(tool.name).inserted else {
                throw DesktopRuntimeError.message("插件工具名称无效或重复：\(tool.name)。")
            }
            guard let data = tool.parametersJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "object" else {
                throw DesktopRuntimeError.message("插件工具 \(tool.name) 的参数 Schema 须为 JSON object。")
            }
        }
        for domain in capabilities.networkDomains {
            let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":") else {
                throw DesktopRuntimeError.message("插件域名白名单格式无效：\(domain)。")
            }
        }
        for module in capabilities.hostModules where DesktopPluginHostModule(rawValue: module) == nil {
            throw DesktopRuntimeError.message("插件声明的宿主模块未知：\(module)。")
        }
    }

    static func isValidIdentifier(_ value: String, minLength: Int) -> Bool {
        guard value.count >= minLength && value.count <= 32 else { return false }
        return value.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) == value.startIndex..<value.endIndex
    }
}

// MARK: - Installed Plugin & Precomputed UI Projection Models

struct DesktopInstalledPlugin: Identifiable, Equatable, Sendable {
    var id: String { manifest.id }
    let manifest: DesktopPluginManifest
    let scriptSource: String
    var enabled: Bool
    let isBuiltIn: Bool
    var lastSyncStatus: String?

    func qualifiedToolName(_ toolName: String) -> String {
        "plugin__\(manifest.id)__\(toolName)"
    }
}

struct DesktopPluginEventItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var summary: String
    var startTime: String
    var endTime: String
    var location: String
    var attendees: [String]
    var notes: String
    var source: String

    var datePrefix: String {
        String(startTime.prefix(10))
    }

    var timeRangeText: String {
        let start = startTime.count >= 16 ? String(startTime.dropFirst(11).prefix(5)) : startTime
        let end = endTime.count >= 16 ? String(endTime.dropFirst(11).prefix(5)) : endTime
        return "\(start)–\(end)"
    }

    var preparationPrompt: String {
        var lines = [
            "请结合以下飞书日程帮我梳理会前准备要点与议程建议：",
            "- 主题：\(summary)",
            "- 时间：\(startTime) 至 \(endTime)"
        ]
        if !location.isEmpty { lines.append("- 地点/链接：\(location)") }
        if !attendees.isEmpty { lines.append("- 参会人：\(attendees.joined(separator: "、"))") }
        if !notes.isEmpty { lines.append("- 备注：\(notes)") }
        return lines.joined(separator: "\n")
    }
}

struct DesktopInspectorCardItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let badge: String
    let title: String
    let subtitle: String?
    let actionTitle: String?
    let prompt: String?
}

struct DesktopInspectorCardSnapshot: Equatable, Identifiable, Sendable {
    var id: String { "\(pluginID).\(cardID)" }
    let pluginID: String
    let pluginName: String
    let cardID: String
    let title: String
    let symbol: String
    let statusBadge: String?
    let items: [DesktopInspectorCardItem]
    let emptyMessage: String
    let footerActionTitle: String?
    let opensWorkspaceViewID: String?
}

struct DesktopPluginWorkspaceViewEntry: Equatable, Identifiable, Sendable {
    var id: String { "\(pluginID):\(viewID)" }
    let pluginID: String
    let pluginName: String
    let viewID: String
    let title: String
    let symbol: String
    let subtitle: String
    let badgeCount: Int
}

struct DesktopPluginSlashCommandEntry: Equatable, Identifiable, Sendable {
    var id: String { "\(pluginID):\(commandID)" }
    let pluginID: String
    let pluginName: String
    let commandID: String
    let title: String
    let slash: String
    let symbol: String
    let promptTemplate: String
}

struct DesktopPluginFreeSlot: Equatable, Identifiable, Sendable {
    var id: String { "\(start)-\(end)" }
    let start: String
    let end: String
    let minutes: Int
}

struct DesktopPluginBotActivityItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: String // "card", "message", "doc_read", "doc_create", "chat_history"
    var title: String
    var summary: String
    var channel: String // "webhook", "openapi", "local"
    var target: String
    var timestamp: String
    var documentURL: String?

    var kindLabel: String {
        switch kind {
        case "card": "消息卡片"
        case "message": "机器人消息"
        case "doc_read": "读取云文档"
        case "doc_create": "创建云文档"
        case "chat_history": "群聊纪要"
        default: "机器人动态"
        }
    }

    var symbol: String {
        switch kind {
        case "card", "message": "paperplane"
        case "doc_read", "doc_create": "doc.text"
        case "chat_history": "bubble.left.and.bubble.right"
        default: "bolt.horizontal"
        }
    }

    var followUpPrompt: String {
        switch kind {
        case "doc_read", "doc_create":
            return "请基于以下飞书云文档内容帮我提炼核心结论与行动项：\n标题：\(title)\n内容摘要：\(summary)"
        case "chat_history":
            return "请根据以下飞书群聊记录整理结构化会议纪要与待办清单：\n群聊：\(title)\n聊天记录：\n\(summary)"
        default:
            return "请帮我优化或跟进这条飞书机器人通知内容：\n标题：\(title)\n正文：\(summary)"
        }
    }
}

// MARK: - Controlled HTTP Transport for Plugins

protocol DesktopPluginHTTPTransport: Sendable {
    func send(request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionPluginHTTPTransport: DesktopPluginHTTPTransport {
    func send(request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return (data, status)
    }
}

// MARK: - DesktopPluginStore

@MainActor @Observable
final class DesktopPluginStore {
    private static let disabledCoreKey = "desktop.plugins.disabledCore.v1"
    private static let disabledPluginsKey = "desktop.plugins.disabledExtensions.v1"
    private static let settingsPrefix = "desktop.plugins.settings.v1."

    private(set) var disabledCorePlugins: Set<DesktopCorePlugin> = []
    private(set) var plugins: [DesktopInstalledPlugin] = []
    private(set) var calendarEvents: [DesktopPluginEventItem] = []
    private(set) var botActivities: [DesktopPluginBotActivityItem] = []
    private(set) var inspectorSnapshots: [DesktopInspectorCardSnapshot] = []
    private(set) var activeWorkspaceViews: [DesktopPluginWorkspaceViewEntry] = []
    private(set) var activeSlashCommands: [DesktopPluginSlashCommandEntry] = []
    private(set) var activeToolDeclarations: [DesktopToolDeclaration] = []
    private(set) var todayFreeSlots: [DesktopPluginFreeSlot] = []
    private(set) var todayDateString: String = ""
    private(set) var tomorrowDateString: String = ""
    private(set) var hasFeishuCalDAVCredentials: Bool = false
    private(set) var hasFeishuBotCredentials: Bool = false
    private(set) var hasFeishuRemoteCredentials: Bool = false
    private(set) var loadError: String?
    private(set) var isSyncingPluginID: String?

    @ObservationIgnored let directory: URL
    @ObservationIgnored var workspaceDirectory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any DesktopCredentialStore
    @ObservationIgnored private let httpTransport: any DesktopPluginHTTPTransport
    @ObservationIgnored let calendarService: any DesktopCalendarService
    @ObservationIgnored private let referenceDateProvider: @Sendable () -> Date
    @ObservationIgnored private var settingsCache: [String: [String: String]] = [:]
    @ObservationIgnored private var inFlightIdempotencyWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored var onStateChanged: (() -> Void)?

    nonisolated static let injectedSandboxAPIs: Set<String> = [
        "amber.settings.get",
        "amber.storage.get",
        "amber.storage.set",
        "amber.http.fetch",
        "amber.workspace.read",
        "amber.workspace.write"
    ]

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Amber/plugins", isDirectory: true)
    }

    init(
        directory: URL = DesktopPluginStore.defaultDirectory,
        workspaceDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        credentials: any DesktopCredentialStore = DesktopKeychain(service: "app.amber.macos.plugins.credentials"),
        httpTransport: any DesktopPluginHTTPTransport = URLSessionPluginHTTPTransport(),
        calendarService: (any DesktopCalendarService)? = nil,
        referenceDateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.workspaceDirectory = workspaceDirectory
            ?? directory.deletingLastPathComponent().appendingPathComponent("workspace", isDirectory: true)
        self.defaults = defaults
        self.credentials = credentials
        self.httpTransport = httpTransport
        // The real EventKit store is only created when the host calendar plugin actually runs a tool.
        self.calendarService = calendarService ?? DesktopEventKitCalendarService()
        self.referenceDateProvider = referenceDateProvider

        if let rawCore = defaults.stringArray(forKey: Self.disabledCoreKey) {
            disabledCorePlugins = Set(rawCore.compactMap(DesktopCorePlugin.init(rawValue:)))
        }
        reload()
    }

    // MARK: Core Plugin Management

    func isCoreEnabled(_ plugin: DesktopCorePlugin) -> Bool {
        !disabledCorePlugins.contains(plugin)
    }

    func setCoreEnabled(_ plugin: DesktopCorePlugin, enabled: Bool) {
        var next = disabledCorePlugins
        if enabled { next.remove(plugin) } else { next.insert(plugin) }
        guard next != disabledCorePlugins else { return }
        disabledCorePlugins = next
        defaults.set(Array(next.map(\.rawValue)).sorted(), forKey: Self.disabledCoreKey)
        onStateChanged?()
    }

    func activeRecipeRegisteredTools() -> Set<String> {
        var names = Set((DesktopToolRegistry.declarations + DesktopMCPManager.declarations + activeToolDeclarations).map(\.name))
        if isCoreEnabled(.knowledge) {
            names.formUnion(DesktopToolRegistry.knowledgeDeclarations.map(\.name))
        }
        return names
    }

    func disabledCorePlugin(governing toolName: String) -> DesktopCorePlugin? {
        for core in disabledCorePlugins where core.governedToolNames.contains(toolName) {
            return core
        }
        return nil
    }

    // MARK: Extension Plugin Lifecycle

    func reload() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let disabledIDs = Set(defaults.stringArray(forKey: Self.disabledPluginsKey) ?? [])
            let builtInFeishu = Self.makeBuiltInFeishuPlugin(enabled: !disabledIDs.contains("feishu_calendar"))
            let builtInApple = Self.makeBuiltInAppleSchedulePlugin(enabled: !disabledIDs.contains(DesktopAppleScheduleTools.pluginID))
            let builtInWatchtower = DesktopWatchtower.makeBuiltInPlugin(enabled: !disabledIDs.contains(DesktopWatchtower.pluginID))
            var loaded: [DesktopInstalledPlugin] = [builtInFeishu, builtInApple, builtInWatchtower]

            let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for folder in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = folder.lastPathComponent
                let isBuiltInID = name == "feishu_calendar" || name == DesktopAppleScheduleTools.pluginID
                    || name == DesktopWatchtower.pluginID
                guard !name.hasPrefix("."), !isBuiltInID else { continue }
                let manifestURL = folder.appendingPathComponent("plugin.json")
                guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
                let data = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(DesktopPluginManifest.self, from: data)
                try manifest.validated()
                guard manifest.capabilities.hostModules.isEmpty else {
                    throw DesktopRuntimeError.message("hostModules 仅供官方内置插件使用，第三方插件不能声明宿主模块。")
                }
                guard manifest.id == name else {
                    throw DesktopRuntimeError.message("插件目录名 \(name) 与 plugin.json id \(manifest.id) 不一致。")
                }
                let scriptURL = folder.appendingPathComponent("main.js")
                let script = FileManager.default.fileExists(atPath: scriptURL.path)
                    ? try String(contentsOf: scriptURL, encoding: .utf8)
                    : ""
                loaded.append(DesktopInstalledPlugin(
                    manifest: manifest,
                    scriptSource: script,
                    enabled: !disabledIDs.contains(manifest.id),
                    isBuiltIn: false,
                    lastSyncStatus: nil
                ))
            }

            settingsCache.removeAll()
            if plugins != loaded { plugins = loaded }
            loadCalendarEventsFromStorage()
            loadBotActivitiesFromStorage()
            rebuildProjections()
            if loadError != nil { loadError = nil }
        } catch {
            let message = "插件加载异常：\(error.localizedDescription)"
            if loadError != message { loadError = message }
            rebuildProjections()
        }
    }

    func setPluginEnabled(_ id: String, enabled: Bool) throws {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else {
            throw DesktopRuntimeError.message("找不到插件：\(id)。")
        }
        var disabledIDs = Set(defaults.stringArray(forKey: Self.disabledPluginsKey) ?? [])
        if enabled { disabledIDs.remove(id) } else { disabledIDs.insert(id) }
        defaults.set(Array(disabledIDs).sorted(), forKey: Self.disabledPluginsKey)
        var updated = plugins
        updated[index].enabled = enabled
        if plugins != updated { plugins = updated }
        rebuildProjections()
    }

    @discardableResult
    func importPlugin(from url: URL) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw DesktopRuntimeError.message("所选插件文件或目录不存在。")
        }

        let manifestData: Data
        let scriptSource: String
        if isDir.boolValue {
            let manifestURL = url.appendingPathComponent("plugin.json")
            guard fm.fileExists(atPath: manifestURL.path) else {
                throw DesktopRuntimeError.message("插件目录缺少 plugin.json。")
            }
            manifestData = try Data(contentsOf: manifestURL)
            let scriptURL = url.appendingPathComponent("main.js")
            scriptSource = fm.fileExists(atPath: scriptURL.path) ? try String(contentsOf: scriptURL, encoding: .utf8) : ""
        } else {
            manifestData = try Data(contentsOf: url)
            let siblingScript = url.deletingLastPathComponent().appendingPathComponent("main.js")
            scriptSource = fm.fileExists(atPath: siblingScript.path) ? (try? String(contentsOf: siblingScript, encoding: .utf8)) ?? "" : ""
        }

        guard manifestData.count <= 256 * 1024 else {
            throw DesktopRuntimeError.message("plugin.json 超过 256 KB 上限。")
        }
        let manifest = try JSONDecoder().decode(DesktopPluginManifest.self, from: manifestData)
        try manifest.validated()
        guard manifest.id != "feishu_calendar" else {
            throw DesktopRuntimeError.message("feishu_calendar 是内置插件 ID，请使用其他插件 ID。")
        }
        guard manifest.id != DesktopAppleScheduleTools.pluginID else {
            throw DesktopRuntimeError.message("apple_schedule 是内置插件 ID，请使用其他插件 ID。")
        }
        guard manifest.id != DesktopWatchtower.pluginID else {
            throw DesktopRuntimeError.message("watchtower 是内置插件 ID，请使用其他插件 ID。")
        }
        guard manifest.capabilities.hostModules.isEmpty else {
            throw DesktopRuntimeError.message("hostModules 仅供官方内置插件使用，第三方插件不能声明宿主模块。")
        }

        let targetFolder = directory.appendingPathComponent(manifest.id, isDirectory: true)
        try fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: targetFolder.appendingPathComponent("plugin.json"), options: .atomic)
        if !scriptSource.isEmpty {
            try Data(scriptSource.utf8).write(to: targetFolder.appendingPathComponent("main.js"), options: .atomic)
        }
        reload()
        return manifest.id
    }

    func removePlugin(id: String) throws {
        guard let plugin = plugins.first(where: { $0.id == id }) else {
            throw DesktopRuntimeError.message("找不到插件：\(id)。")
        }
        guard !plugin.isBuiltIn else {
            throw DesktopRuntimeError.message("内置插件不能删除，可通过开关停用。")
        }
        let targetFolder = directory.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: targetFolder.path) {
            try FileManager.default.removeItem(at: targetFolder)
        }
        for field in plugin.manifest.settingsSchema where field.kind == .secret {
            try? credentials.delete(id: secretKeyUUID(pluginID: id, key: field.key))
        }
        defaults.removeObject(forKey: Self.settingsPrefix + id)
        settingsCache.removeValue(forKey: id)
        reload()
    }

    // MARK: Plugin Settings & Keychain Secrets

    func settingValue(pluginID: String, key: String) -> String {
        guard let plugin = plugins.first(where: { $0.id == pluginID }),
              let field = plugin.manifest.settingsSchema.first(where: { $0.key == key }) else {
            return ""
        }
        if let cached = settingsCache[pluginID]?[key] {
            return cached
        }
        let resolved: String
        if field.kind == .secret {
            resolved = (try? credentials.load(id: secretKeyUUID(pluginID: pluginID, key: key))) ?? ""
        } else {
            let dict = defaults.dictionary(forKey: Self.settingsPrefix + pluginID) as? [String: String] ?? [:]
            resolved = dict[key] ?? field.defaultValue
        }
        settingsCache[pluginID, default: [:]][key] = resolved
        return resolved
    }

    func saveSettings(pluginID: String, values: [String: String]) throws {
        guard let plugin = plugins.first(where: { $0.id == pluginID }) else {
            throw DesktopRuntimeError.message("找不到插件：\(pluginID)。")
        }
        var nonSecrets: [String: String] = defaults.dictionary(forKey: Self.settingsPrefix + pluginID) as? [String: String] ?? [:]
        var cachedPluginSettings = settingsCache[pluginID] ?? [:]
        for field in plugin.manifest.settingsSchema {
            if field.kind == .secret {
                nonSecrets.removeValue(forKey: field.key)
            }
            guard let newValue = values[field.key] else { continue }
            if field.kind == .secret {
                let clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                try credentials.save(clean, id: secretKeyUUID(pluginID: pluginID, key: field.key))
                cachedPluginSettings[field.key] = clean
            } else {
                nonSecrets[field.key] = newValue
                cachedPluginSettings[field.key] = newValue
            }
        }
        defaults.set(nonSecrets, forKey: Self.settingsPrefix + pluginID)
        settingsCache[pluginID] = cachedPluginSettings
        rebuildProjections()
    }

    private func secretKeyUUID(pluginID: String, key: String) -> UUID {
        let digest = SHA256.hash(data: Data("amber.plugin.secret.\(pluginID).\(key)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }

    // MARK: Plugin KV Storage

    private func storageFileURL(pluginID: String) -> URL {
        directory.appendingPathComponent(pluginID, isDirectory: true).appendingPathComponent("storage.json")
    }

    func readPluginStorage(pluginID: String) -> [String: String] {
        let url = storageFileURL(pluginID: pluginID)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    func writePluginStorage(pluginID: String, storage: [String: String]) {
        let folder = directory.appendingPathComponent(pluginID, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(storage) {
            try? data.write(to: storageFileURL(pluginID: pluginID), options: .atomic)
        }
    }

    // MARK: Feishu Calendar (CalDAV + OpenAPI) & Feishu Bot Storage & Remote Sync

    var feishuCalendarConnectionBadge: String {
        if hasFeishuCalDAVCredentials {
            return "CalDAV 直连"
        }
        if computeHasFeishuOpenAPICredentials() {
            return "飞书开放平台"
        }
        return "本地演示模式"
    }

    var feishuBotConnectionBadge: String {
        let webhook = settingValue(pluginID: "feishu_calendar", key: "bot_webhook_url")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let openAPI = computeHasFeishuOpenAPICredentials()
        if !webhook.isEmpty && openAPI {
            return "Webhook + 应用机器人"
        }
        if !webhook.isEmpty {
            return "群 Webhook 已就绪"
        }
        if openAPI {
            return "应用机器人已就绪"
        }
        return "本地沙箱模式"
    }

    private func loadCalendarEventsFromStorage() {
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        if let rawEvents = storage["events"],
           let data = rawEvents.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([DesktopPluginEventItem].self, from: data) {
            let sorted = decoded.sorted { $0.startTime < $1.startTime }
            if calendarEvents != sorted { calendarEvents = sorted }
            return
        }
        let seeded = Self.defaultSeededEvents(now: referenceDateProvider())
        saveCalendarEventsToStorage(seeded, storage: &storage)
        if calendarEvents != seeded { calendarEvents = seeded }
    }

    private func saveCalendarEventsToStorage(_ events: [DesktopPluginEventItem], storage: inout [String: String]) {
        let sorted = events.sorted { $0.startTime < $1.startTime }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(sorted) {
            storage["events"] = String(decoding: data, as: UTF8.self)
            writePluginStorage(pluginID: "feishu_calendar", storage: storage)
        }
        if calendarEvents != sorted { calendarEvents = sorted }
    }

    private func loadBotActivitiesFromStorage() {
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        if let raw = storage["bot_activities"],
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([DesktopPluginBotActivityItem].self, from: data) {
            if botActivities != decoded { botActivities = decoded }
            return
        }
        let seeded = Self.defaultSeededBotActivities(now: referenceDateProvider())
        saveBotActivitiesToStorage(seeded, storage: &storage)
        if botActivities != seeded { botActivities = seeded }
    }

    private func saveBotActivitiesToStorage(_ items: [DesktopPluginBotActivityItem], storage: inout [String: String]) {
        let trimmed = Array(items.prefix(50))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(trimmed) {
            storage["bot_activities"] = String(decoding: data, as: UTF8.self)
            writePluginStorage(pluginID: "feishu_calendar", storage: storage)
        }
        if botActivities != trimmed { botActivities = trimmed }
    }

    func deleteBotActivity(id: String) {
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        let next = botActivities.filter { $0.id != id }
        guard next != botActivities else { return }
        saveBotActivitiesToStorage(next, storage: &storage)
        rebuildProjections()
    }

    @discardableResult
    func createCalendarEvent(
        summary: String,
        startTime: String,
        endTime: String,
        location: String = "飞书会议",
        attendees: [String] = [],
        notes: String = ""
    ) async throws -> DesktopPluginEventItem {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSummary.isEmpty else {
            throw DesktopRuntimeError.message("日程主题不能为空。")
        }
        let normalizedStart = Self.normalizeDateTimeString(startTime, fallbackDate: referenceDateProvider())
        let normalizedEnd = Self.normalizeDateTimeString(endTime, fallbackDate: referenceDateProvider())
        let eventUID = "evt_" + UUID().uuidString.prefix(8).lowercased()
        var source = "local"

        if let feishuPlugin = plugins.first(where: { $0.id == "feishu_calendar" }) {
            if computeHasFeishuCalDAVCredentials() {
                let server = resolvedCalDAVServerURL()
                let base = server.hasSuffix("/") ? String(server.dropLast()) : server
                let putURL = "\(base)/\(eventUID).ics"
                let icsPayload = Self.buildICalendarEvent(
                    uid: eventUID,
                    summary: cleanSummary,
                    startTime: normalizedStart,
                    endTime: normalizedEnd,
                    location: location,
                    notes: notes
                )
                _ = try await performAuthorizedHTTP(
                    plugin: feishuPlugin,
                    urlString: putURL,
                    method: "PUT",
                    headers: [
                        "Authorization": try resolveCalDAVBasicAuthHeader(),
                        "Content-Type": "text/calendar; charset=utf-8"
                    ],
                    body: Data(icsPayload.utf8)
                )
                source = "feishu"
            } else if computeHasFeishuOpenAPICredentials() {
                let token = try await resolveFeishuAccessToken(plugin: feishuPlugin)
                let calendarID = settingValue(pluginID: "feishu_calendar", key: "default_calendar_id")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let targetCalendar = calendarID.isEmpty ? "primary" : calendarID
                let encodedCal = targetCalendar.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "primary"
                let endpoint = "https://open.feishu.cn/open-apis/calendar/v4/calendars/\(encodedCal)/events"
                let body: [String: Any] = [
                    "summary": cleanSummary,
                    "description": notes,
                    "start_time": ["timestamp": String(Self.parseTimestamp(normalizedStart, fallback: referenceDateProvider()))],
                    "end_time": ["timestamp": String(Self.parseTimestamp(normalizedEnd, fallback: referenceDateProvider().addingTimeInterval(3600)))]
                ]
                let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                _ = try await performAuthorizedHTTP(
                    plugin: feishuPlugin,
                    urlString: endpoint,
                    method: "POST",
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Content-Type": "application/json; charset=utf-8"
                    ],
                    body: bodyData
                )
                source = "feishu"
            }
        }

        let item = DesktopPluginEventItem(
            id: eventUID,
            summary: cleanSummary,
            startTime: normalizedStart,
            endTime: normalizedEnd,
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            attendees: attendees,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source
        )
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        var current = calendarEvents
        current.append(item)
        saveCalendarEventsToStorage(current, storage: &storage)
        rebuildProjections()
        return item
    }

    func deleteCalendarEvent(id: String) {
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        let next = calendarEvents.filter { $0.id != id }
        guard next != calendarEvents else { return }
        saveCalendarEventsToStorage(next, storage: &storage)
        rebuildProjections()
    }

    private func computeHasFeishuCalDAVCredentials() -> Bool {
        let user = settingValue(pluginID: "feishu_calendar", key: "caldav_username")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = settingValue(pluginID: "feishu_calendar", key: "caldav_password")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !user.isEmpty && !pass.isEmpty
    }

    private func computeHasFeishuOpenAPICredentials() -> Bool {
        let pat = settingValue(pluginID: "feishu_calendar", key: "personal_access_token")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pat.isEmpty { return true }
        let appID = settingValue(pluginID: "feishu_calendar", key: "app_id")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = settingValue(pluginID: "feishu_calendar", key: "app_secret")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !appID.isEmpty && !appSecret.isEmpty
    }

    private func computeHasFeishuBotCredentials() -> Bool {
        let webhook = settingValue(pluginID: "feishu_calendar", key: "bot_webhook_url")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !webhook.isEmpty || computeHasFeishuOpenAPICredentials()
    }

    private func computeHasFeishuRemoteCredentials() -> Bool {
        computeHasFeishuCalDAVCredentials() || computeHasFeishuOpenAPICredentials()
    }

    private func resolvedCalDAVServerURL() -> String {
        let raw = settingValue(pluginID: "feishu_calendar", key: "caldav_server")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "https://caldav.feishu.cn" : raw
    }

    private func resolveCalDAVBasicAuthHeader() throws -> String {
        let user = settingValue(pluginID: "feishu_calendar", key: "caldav_username")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = settingValue(pluginID: "feishu_calendar", key: "caldav_password")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !pass.isEmpty else {
            throw DesktopRuntimeError.message("请先在设置 → 插件 → 飞书的「日历 (CalDAV)」中填写 CalDAV 用户名与密码。")
        }
        let encoded = Data("\(user):\(pass)".utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    /// Synchronizes events from Feishu CalDAV (`caldav.feishu.cn`) first, or falls back to Feishu OpenAPI (`open.feishu.cn`).
    @discardableResult
    func syncFeishuCalendar() async throws -> String {
        guard let pluginIndex = plugins.firstIndex(where: { $0.id == "feishu_calendar" }) else {
            throw DesktopRuntimeError.message("飞书插件未安装。")
        }
        let plugin = plugins[pluginIndex]
        guard hasFeishuRemoteCredentials else {
            let status = "本地演示模式（在插件设置中填入飞书 CalDAV 账号密码后即可直连同步个人日历）"
            updatePluginSyncStatus(id: "feishu_calendar", status: status)
            return status
        }
        isSyncingPluginID = "feishu_calendar"
        defer { isSyncingPluginID = nil }

        let remoteEvents: [DesktopPluginEventItem]
        let protocolLabel: String
        if computeHasFeishuCalDAVCredentials() {
            protocolLabel = "CalDAV"
            let endpoint = resolvedCalDAVServerURL()
            let reportXML = """
            <?xml version="1.0" encoding="utf-8" ?>
            <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
              <d:prop>
                <d:getetag/>
                <c:calendar-data/>
              </d:prop>
              <c:filter>
                <c:comp-filter name="VCALENDAR">
                  <c:comp-filter name="VEVENT"/>
                </c:comp-filter>
              </c:filter>
            </c:calendar-query>
            """
            let (data, _) = try await performAuthorizedHTTP(
                plugin: plugin,
                urlString: endpoint,
                method: "REPORT",
                headers: [
                    "Authorization": try resolveCalDAVBasicAuthHeader(),
                    "Depth": "1",
                    "Content-Type": "application/xml; charset=utf-8"
                ],
                body: Data(reportXML.utf8)
            )
            let parsedICS = Self.parseCalDAVEICSData(data: data, fallbackDate: referenceDateProvider())
            remoteEvents = parsedICS.isEmpty
                ? Self.parseFeishuEventsResponse(data: data, fallbackDate: referenceDateProvider())
                : parsedICS
        } else {
            protocolLabel = "OpenAPI"
            let token = try await resolveFeishuAccessToken(plugin: plugin)
            let calendarID = settingValue(pluginID: "feishu_calendar", key: "default_calendar_id")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let targetCalendar = calendarID.isEmpty ? "primary" : calendarID
            let encodedCal = targetCalendar.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "primary"
            let endpoint = "https://open.feishu.cn/open-apis/calendar/v4/calendars/\(encodedCal)/events"
            let (data, _) = try await performAuthorizedHTTP(
                plugin: plugin,
                urlString: endpoint,
                method: "GET",
                headers: ["Authorization": "Bearer \(token)"],
                body: nil
            )
            remoteEvents = Self.parseFeishuEventsResponse(data: data, fallbackDate: referenceDateProvider())
        }

        if !remoteEvents.isEmpty {
            var storage = readPluginStorage(pluginID: "feishu_calendar")
            let localOnly = calendarEvents.filter { $0.source == "local" }
            var mergedByID = Dictionary(uniqueKeysWithValues: localOnly.map { ($0.id, $0) })
            for remote in remoteEvents { mergedByID[remote.id] = remote }
            saveCalendarEventsToStorage(Array(mergedByID.values), storage: &storage)
            rebuildProjections()
        }
        let status = "已同步飞书日历 · \(protocolLabel)（共 \(calendarEvents.count) 项日程）"
        updatePluginSyncStatus(id: "feishu_calendar", status: status)
        return status
    }

    // MARK: Feishu Bot Actions (Webhook + OpenAPI Messages, Group History & Cloud Docs)

    @discardableResult
    func sendFeishuBotMessage(
        title: String = "",
        content: String,
        msgType: String = "interactive",
        receiveID: String = ""
    ) async throws -> DesktopPluginBotActivityItem {
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanContent.isEmpty else {
            throw DesktopRuntimeError.message("发送的飞书消息内容不能为空。")
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Amber 智能体通知"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTarget = receiveID.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultTarget = settingValue(pluginID: "feishu_calendar", key: "default_receive_id")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTarget = cleanTarget.isEmpty ? defaultTarget : cleanTarget
        let webhookURL = settingValue(pluginID: "feishu_calendar", key: "bot_webhook_url")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var channelUsed = "local"
        var targetLabel = resolvedTarget.isEmpty ? "飞书群机器人" : resolvedTarget

        if let plugin = plugins.first(where: { $0.id == "feishu_calendar" }) {
            if !webhookURL.isEmpty && cleanTarget.isEmpty {
                var bodyObj: [String: Any]
                if msgType == "text" {
                    bodyObj = [
                        "msg_type": "text",
                        "content": ["text": "\(cleanTitle)\n\(cleanContent)"]
                    ]
                } else {
                    bodyObj = [
                        "msg_type": "interactive",
                        "card": Self.buildFeishuInteractiveCard(title: cleanTitle, markdown: cleanContent)
                    ]
                }
                let secret = settingValue(pluginID: "feishu_calendar", key: "bot_webhook_secret")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !secret.isEmpty {
                    let ts = String(Int(referenceDateProvider().timeIntervalSince1970))
                    bodyObj["timestamp"] = ts
                    bodyObj["sign"] = Self.computeFeishuWebhookSign(timestamp: ts, secret: secret)
                }
                let bodyData = try JSONSerialization.data(withJSONObject: bodyObj, options: [.sortedKeys])
                _ = try await performAuthorizedHTTP(
                    plugin: plugin,
                    urlString: webhookURL,
                    method: "POST",
                    headers: ["Content-Type": "application/json; charset=utf-8"],
                    body: bodyData
                )
                channelUsed = "webhook"
                targetLabel = "群自定义机器人 Webhook"
            } else if computeHasFeishuOpenAPICredentials() {
                guard !resolvedTarget.isEmpty else {
                    throw DesktopRuntimeError.message("使用飞书应用机器人发送消息时，需提供 receive_id 或在插件设置中填写默认消息接收 ID（如 oc_xxx）。")
                }
                let token = try await resolveFeishuAccessToken(plugin: plugin)
                let idType = Self.inferFeishuReceiveIDType(resolvedTarget)
                let endpoint = "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=\(idType)"
                let contentJSON: String
                let resolvedMsgType: String
                if msgType == "text" {
                    resolvedMsgType = "text"
                    contentJSON = try Self.encodeJSONObject(["text": "\(cleanTitle)\n\(cleanContent)"])
                } else {
                    resolvedMsgType = "interactive"
                    contentJSON = try Self.encodeJSONObject(Self.buildFeishuInteractiveCard(title: cleanTitle, markdown: cleanContent))
                }
                let payload = try JSONSerialization.data(
                    withJSONObject: [
                        "receive_id": resolvedTarget,
                        "msg_type": resolvedMsgType,
                        "content": contentJSON
                    ],
                    options: [.sortedKeys]
                )
                _ = try await performAuthorizedHTTP(
                    plugin: plugin,
                    urlString: endpoint,
                    method: "POST",
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Content-Type": "application/json; charset=utf-8"
                    ],
                    body: payload
                )
                channelUsed = "openapi"
            }
        }

        let item = DesktopPluginBotActivityItem(
            id: "bot_" + UUID().uuidString.prefix(8).lowercased(),
            kind: msgType == "text" ? "message" : "card",
            title: cleanTitle,
            summary: cleanContent,
            channel: channelUsed,
            target: targetLabel,
            timestamp: Self.dateTimeFormatter.string(from: referenceDateProvider()),
            documentURL: nil
        )
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        var current = botActivities
        current.insert(item, at: 0)
        saveBotActivitiesToStorage(current, storage: &storage)
        rebuildProjections()
        return item
    }

    @discardableResult
    func fetchFeishuChatHistory(chatID: String = "", limit: Int = 15) async throws -> (messages: [[String: String]], activity: DesktopPluginBotActivityItem) {
        let defaultTarget = settingValue(pluginID: "feishu_calendar", key: "default_receive_id")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let targetChat = chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (defaultTarget.isEmpty ? "oc_product_core_group" : defaultTarget)
            : chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedLimit = max(1, min(50, limit))

        var messages: [[String: String]] = []
        var channelUsed = "local"

        if computeHasFeishuOpenAPICredentials(),
           let plugin = plugins.first(where: { $0.id == "feishu_calendar" }) {
            let token = try await resolveFeishuAccessToken(plugin: plugin)
            let encodedChat = targetChat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? targetChat
            let endpoint = "https://open.feishu.cn/open-apis/im/v1/messages?container_id_type=chat&container_id=\(encodedChat)&page_size=\(clampedLimit)"
            let (data, _) = try await performAuthorizedHTTP(
                plugin: plugin,
                urlString: endpoint,
                method: "GET",
                headers: ["Authorization": "Bearer \(token)"],
                body: nil
            )
            messages = Self.parseFeishuChatMessages(data: data)
            channelUsed = "openapi"
        }

        if messages.isEmpty {
            messages = [
                ["sender": "林夏", "time": "10:15", "text": "本周飞书插件准备拆成 CalDAV 日历和机器人两个模块，大家确认下接口边界。"],
                ["sender": "周航", "time": "10:18", "text": "赞成！个人日历直接走 CalDAV 免管理员审批，机器人专门负责群卡片推送和云文档读写。"],
                ["sender": "陈默", "time": "10:22", "text": "下午 14:30 评审会前把测试报告卡片推到群里。"]
            ]
        }

        let summaryLines = messages.prefix(6).map { msg in
            "[\(msg["time"] ?? "")] \(msg["sender"] ?? "成员")：\(msg["text"] ?? "")"
        }.joined(separator: "\n")

        let activity = DesktopPluginBotActivityItem(
            id: "bot_" + UUID().uuidString.prefix(8).lowercased(),
            kind: "chat_history",
            title: "飞书群聊记录 (\(targetChat))",
            summary: summaryLines,
            channel: channelUsed,
            target: targetChat,
            timestamp: Self.dateTimeFormatter.string(from: referenceDateProvider()),
            documentURL: nil
        )
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        var current = botActivities
        current.insert(activity, at: 0)
        saveBotActivitiesToStorage(current, storage: &storage)
        rebuildProjections()
        return (messages, activity)
    }

    @discardableResult
    func readFeishuDocument(documentInput: String) async throws -> (docID: String, title: String, content: String, activity: DesktopPluginBotActivityItem) {
        let docID = Self.extractFeishuDocumentID(from: documentInput)
        guard !docID.isEmpty else {
            throw DesktopRuntimeError.message("请提供有效的飞书云文档链接或 document_id。")
        }

        var docTitle = "飞书云文档 (\(docID))"
        var docContent = ""
        var channelUsed = "local"

        if computeHasFeishuOpenAPICredentials(),
           let plugin = plugins.first(where: { $0.id == "feishu_calendar" }) {
            let token = try await resolveFeishuAccessToken(plugin: plugin)
            let encodedID = docID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? docID
            let endpoint = "https://open.feishu.cn/open-apis/docx/v1/documents/\(encodedID)/raw_content"
            let (data, _) = try await performAuthorizedHTTP(
                plugin: plugin,
                urlString: endpoint,
                method: "GET",
                headers: ["Authorization": "Bearer \(token)"],
                body: nil
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = root["data"] as? [String: Any],
               let rawText = dataObj["content"] as? String {
                docContent = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let firstLine = docContent.split(separator: "\n").first, !firstLine.isEmpty {
                    docTitle = String(firstLine.prefix(48))
                }
            }
            channelUsed = "openapi"
        }

        if docContent.isEmpty {
            docTitle = "Amber 飞书套件技术方案 (\(docID))"
            docContent = """
            1. 日历模块：支持标准 CalDAV (https://caldav.feishu.cn) Basic Auth 直连，无需管理员审批即可同步个人日程。
            2. 机器人模块：支持群自定义 Webhook（含 HMAC-SHA256 签名校验）与企业自建应用 OpenAPI（收发消息、拉取群聊记录、读写飞书 Docx 云文档）。
            3. 工作流联动：支持将日程一键推送至飞书群卡片，或将飞书文档读取到当前对话进行总结。
            """
        }

        let docURL = documentInput.hasPrefix("https://") ? documentInput : "https://feishu.cn/docx/\(docID)"
        let activity = DesktopPluginBotActivityItem(
            id: "bot_" + UUID().uuidString.prefix(8).lowercased(),
            kind: "doc_read",
            title: docTitle,
            summary: docContent,
            channel: channelUsed,
            target: docID,
            timestamp: Self.dateTimeFormatter.string(from: referenceDateProvider()),
            documentURL: docURL
        )
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        var current = botActivities
        current.insert(activity, at: 0)
        saveBotActivitiesToStorage(current, storage: &storage)
        rebuildProjections()
        return (docID, docTitle, docContent, activity)
    }

    @discardableResult
    func createFeishuDocument(title: String, content: String = "", folderToken: String = "") async throws -> DesktopPluginBotActivityItem {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw DesktopRuntimeError.message("飞书云文档标题不能为空。")
        }
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var docID = "doxcn_" + UUID().uuidString.prefix(8).lowercased()
        var channelUsed = "local"

        if computeHasFeishuOpenAPICredentials(),
           let plugin = plugins.first(where: { $0.id == "feishu_calendar" }) {
            let token = try await resolveFeishuAccessToken(plugin: plugin)
            var bodyObj: [String: Any] = ["title": cleanTitle]
            let cleanFolder = folderToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanFolder.isEmpty {
                bodyObj["folder_token"] = cleanFolder
            }
            let bodyData = try JSONSerialization.data(withJSONObject: bodyObj, options: [.sortedKeys])
            let (data, _) = try await performAuthorizedHTTP(
                plugin: plugin,
                urlString: "https://open.feishu.cn/open-apis/docx/v1/documents",
                method: "POST",
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Content-Type": "application/json; charset=utf-8"
                ],
                body: bodyData
            )
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = root["data"] as? [String: Any],
               let docObj = dataObj["document"] as? [String: Any],
               let remoteID = docObj["document_id"] as? String,
               !remoteID.isEmpty {
                docID = remoteID
            }
            channelUsed = "openapi"
        }

        let docURL = "https://feishu.cn/docx/\(docID)"
        let item = DesktopPluginBotActivityItem(
            id: "bot_" + UUID().uuidString.prefix(8).lowercased(),
            kind: "doc_create",
            title: cleanTitle,
            summary: cleanContent.isEmpty ? "已创建飞书云文档（\(docID)）" : cleanContent,
            channel: channelUsed,
            target: docID,
            timestamp: Self.dateTimeFormatter.string(from: referenceDateProvider()),
            documentURL: docURL
        )
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        var current = botActivities
        current.insert(item, at: 0)
        saveBotActivitiesToStorage(current, storage: &storage)
        rebuildProjections()
        return item
    }

    private func updatePluginSyncStatus(id: String, status: String) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        var updated = plugins
        updated[index].lastSyncStatus = status
        if plugins != updated { plugins = updated }
    }

    private func resolveFeishuAccessToken(plugin: DesktopInstalledPlugin) async throws -> String {
        let pat = settingValue(pluginID: plugin.id, key: "personal_access_token")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pat.isEmpty { return pat }

        let appID = settingValue(pluginID: plugin.id, key: "app_id")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = settingValue(pluginID: plugin.id, key: "app_secret")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, !appSecret.isEmpty else {
            throw DesktopRuntimeError.message("请先在设置 → 插件 → 飞书中配置 App ID 与 App Secret，或个人访问令牌。")
        }

        let payload = try JSONSerialization.data(
            withJSONObject: ["app_id": appID, "app_secret": appSecret],
            options: [.sortedKeys]
        )
        let (data, _) = try await performAuthorizedHTTP(
            plugin: plugin,
            urlString: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
            method: "POST",
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: payload
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (json["tenant_access_token"] as? String) ?? (json["app_access_token"] as? String),
              !token.isEmpty else {
            throw DesktopRuntimeError.message("飞书鉴权响应未包含有效的 tenant_access_token，请核对 App ID 与 App Secret。")
        }
        return token
    }

    /// Enforces `capabilities.networkDomains` allowlist before dispatching any HTTP call.
    func performAuthorizedHTTP(
        plugin: DesktopInstalledPlugin,
        urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, Int) {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            throw DesktopRuntimeError.message("插件仅允许访问 HTTPS 地址：\(urlString)")
        }
        let allowedDomains = plugin.manifest.capabilities.networkDomains.map { $0.lowercased() }
        let permitted = allowedDomains.contains { allowed in
            host == allowed || host.hasSuffix("." + allowed)
        }
        guard permitted else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 未授权访问域名 \(host)（允许列表：\(allowedDomains.joined(separator: ", "))）。")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        let (data, status) = try await httpTransport.send(request: request)
        guard (200...299).contains(status) else {
            throw DesktopRuntimeError.message("外部服务 \(host) 返回 HTTP \(status)。")
        }
        return (data, status)
    }

    // MARK: Tool Dispatch (Agent Engine & Recipe Integration)

    nonisolated static func parseQualifiedToolName(_ name: String) -> (pluginID: String, toolName: String)? {
        guard name.hasPrefix("plugin__") else { return nil }
        let remainder = name.dropFirst("plugin__".count)
        guard let range = remainder.range(of: "__") else { return nil }
        let pluginID = String(remainder[..<range.lowerBound])
        let toolName = String(remainder[range.upperBound...])
        guard !pluginID.isEmpty, !toolName.isEmpty else { return nil }
        return (pluginID, toolName)
    }

    func toolEffect(for qualifiedName: String) -> DesktopToolEffect {
        guard let parsed = Self.parseQualifiedToolName(qualifiedName),
              let plugin = plugins.first(where: { $0.id == parsed.pluginID && $0.enabled }),
              let tool = plugin.manifest.tools.first(where: { $0.name == parsed.toolName }) else {
            return .sideEffect
        }
        return tool.effect
    }

    func executeTool(qualifiedName: String, argumentsJSON: String, workspaceDirectory: URL? = nil) async throws -> String {
        guard let parsed = Self.parseQualifiedToolName(qualifiedName) else {
            throw DesktopRuntimeError.message("无效的插件工具名称：\(qualifiedName)。")
        }
        guard let plugin = plugins.first(where: { $0.id == parsed.pluginID }) else {
            throw DesktopRuntimeError.message("插件 \(parsed.pluginID) 未安装。")
        }
        guard plugin.enabled else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 当前已停用，请先在设置 → 插件中启用。")
        }
        guard let tool = plugin.manifest.tools.first(where: { $0.name == parsed.toolName }) else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 不包含工具 \(parsed.toolName)。")
        }

        let argsData = argumentsJSON.data(using: .utf8) ?? Data("{}".utf8)
        let args = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]

        // Host-native calendar: no JavaScript can reach EventKit, so the host runs these tools itself.
        if plugin.id == DesktopAppleScheduleTools.pluginID {
            return try await DesktopAppleScheduleTools.perform(tool: tool.name, argumentsJSON: argumentsJSON,
                service: calendarService, now: referenceDateProvider())
        }

        // Built-in Feishu Suite (Calendar CalDAV + Bot Webhook/OpenAPI) handlers + JS execution
        if plugin.id == "feishu_calendar" {
            if hasFeishuRemoteCredentials && (tool.name == "list_events" || tool.name == "freebusy") {
                _ = try? await syncFeishuCalendar()
            }
            switch tool.name {
            case "create_event":
                return try await withIdempotencyLock(key: args["idempotency_key"] as? String) {
                    let isLocal = !hasFeishuRemoteCredentials
                    if let key = DesktopFeishuIdempotency.normalize(args["idempotency_key"] as? String),
                       let stored = DesktopFeishuIdempotency.read(key, isLocalDemo: isLocal, from: readPluginStorage(pluginID: "feishu_calendar")) {
                        return DesktopFeishuReplay.payload(from: stored, tool: "create_event")
                    }
                    let summary = (args["summary"] as? String) ?? ""
                    let startTime = (args["start_time"] as? String) ?? ""
                    let endTime = (args["end_time"] as? String) ?? ""
                    guard !summary.isEmpty, !startTime.isEmpty, !endTime.isEmpty else {
                        throw DesktopRuntimeError.message("create_event 需要提供非空的 summary、start_time 与 end_time。")
                    }
                    let location = (args["location"] as? String) ?? "飞书会议"
                    let attendees = (args["attendees"] as? [String]) ?? []
                    let notes = (args["notes"] as? String) ?? ""
                    let created = try await createCalendarEvent(
                        summary: summary,
                        startTime: startTime,
                        endTime: endTime,
                        location: location,
                        attendees: attendees,
                        notes: notes
                    )
                    let createOutput = try Self.encodeJSONObject([
                        "ok": true,
                        "plugin": "feishu_calendar",
                        "mode": created.source,
                        "event": [
                            "id": created.id,
                            "summary": created.summary,
                            "start_time": created.startTime,
                            "end_time": created.endTime,
                            "location": created.location,
                            "attendees": created.attendees,
                            "notes": created.notes,
                            "source": created.source
                        ],
                        "total_events": calendarEvents.count
                    ])
                    recordIdempotentWrite(
                        key: args["idempotency_key"] as? String,
                        result: createOutput,
                        target: created.id,
                        isLocalDemo: created.source == "local"
                    )
                    return createOutput
                }

            case "bot_send_message":
                return try await withIdempotencyLock(key: args["idempotency_key"] as? String) {
                    let receiveID = (args["receive_id"] as? String) ?? ""
                    let isLocal = !isFeishuBotMessageRemote(receiveID: receiveID)
                    if let key = DesktopFeishuIdempotency.normalize(args["idempotency_key"] as? String),
                       let stored = DesktopFeishuIdempotency.read(key, isLocalDemo: isLocal, from: readPluginStorage(pluginID: "feishu_calendar")) {
                        return DesktopFeishuReplay.payload(from: stored, tool: "bot_send_message")
                    }
                    let title = (args["title"] as? String) ?? "Amber 智能体通知"
                    let content = (args["content"] as? String) ?? ""
                    let msgType = (args["msg_type"] as? String) ?? "interactive"
                    let activity = try await sendFeishuBotMessage(
                        title: title,
                        content: content,
                        msgType: msgType,
                        receiveID: receiveID
                    )
                    let sendOutput = try Self.encodeJSONObject([
                        "ok": true,
                        "plugin": "feishu_calendar",
                        "channel": activity.channel,
                        "message_id": activity.id,
                        "title": activity.title,
                        "target": activity.target
                    ])
                    recordIdempotentWrite(
                        key: args["idempotency_key"] as? String,
                        result: sendOutput,
                        target: activity.target,
                        isLocalDemo: activity.channel == "local"
                    )
                    return sendOutput
                }

            case "bot_fetch_chat_history":
                let chatID = (args["chat_id"] as? String) ?? ""
                let limit = (args["limit"] as? Int) ?? 15
                let (messages, activity) = try await fetchFeishuChatHistory(chatID: chatID, limit: limit)
                return try Self.encodeJSONObject([
                    "ok": true,
                    "plugin": "feishu_calendar",
                    "channel": activity.channel,
                    "chat_id": activity.target,
                    "count": messages.count,
                    "messages": messages
                ])

            case "bot_read_doc":
                let docInput = (args["document"] as? String) ?? ""
                let (docID, title, content, activity) = try await readFeishuDocument(documentInput: docInput)
                return try Self.encodeJSONObject([
                    "ok": true,
                    "plugin": "feishu_calendar",
                    "channel": activity.channel,
                    "document_id": docID,
                    "title": title,
                    "content": content,
                    "url": activity.documentURL ?? ""
                ])

            case "bot_create_doc":
                return try await withIdempotencyLock(key: args["idempotency_key"] as? String) {
                    let isLocal = !computeHasFeishuOpenAPICredentials()
                    if let key = DesktopFeishuIdempotency.normalize(args["idempotency_key"] as? String),
                       let stored = DesktopFeishuIdempotency.read(key, isLocalDemo: isLocal, from: readPluginStorage(pluginID: "feishu_calendar")) {
                        return DesktopFeishuReplay.payload(from: stored, tool: tool.name)
                    }
                    let title = (args["title"] as? String) ?? ""
                    let content = (args["content"] as? String) ?? ""
                    let folderToken = (args["folder_token"] as? String) ?? ""
                    let activity = try await createFeishuDocument(title: title, content: content, folderToken: folderToken)
                    let docOutput = try Self.encodeJSONObject([
                        "ok": true,
                        "plugin": "feishu_calendar",
                        "channel": activity.channel,
                        "document_id": activity.target,
                        "title": activity.title,
                        "url": activity.documentURL ?? ""
                    ])
                    recordIdempotentWrite(
                        key: args["idempotency_key"] as? String,
                        result: docOutput,
                        target: activity.target,
                        isLocalDemo: activity.channel == "local"
                    )
                    return docOutput
                }

            default:
                break
            }
        }

        // The meeting closeout: one call that writes the minutes document and then the group receipt under
        // deterministic keys, so re-running the loop after a review cannot double-post either of them.
        if plugin.id == "feishu_calendar", tool.name == "meeting_closeout" {
            return try await feishuMeetingCloseout(arguments: args)
        }

        return try await evaluateJSTool(
            plugin: plugin,
            tool: tool,
            argumentsData: argsData,
            workspaceDirectory: workspaceDirectory
        )
    }

    /// Writes the minutes document and the group receipt for one meeting.
    /// Keys default to `meeting:<date>:<receive_id>:<title>:<minutes_digest>` so the same meeting loop is idempotent
    /// without the model having to invent a key; an explicit `idempotency_key` overrides both.
    private func feishuMeetingCloseout(arguments: [String: Any]) async throws -> String {
        let title = ((arguments["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = ((arguments["minutes"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !minutes.isEmpty else {
            throw DesktopRuntimeError.message("meeting_closeout 需要非空的 title 与 minutes。")
        }
        let day = Self.dateFormatter.string(from: referenceDateProvider())
        let rawReceiveID = ((arguments["receive_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultReceiveID = settingValue(pluginID: "feishu_calendar", key: "default_receive_id")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedReceiveID = rawReceiveID.isEmpty ? defaultReceiveID : rawReceiveID
        let receiveSegment = resolvedReceiveID.isEmpty ? "default" : String(resolvedReceiveID.prefix(24))
        let minutesDigest = DesktopFeishuIdempotency.shortDigest(minutes)
        let defaultBase = "meeting:\(day):\(receiveSegment):\(String(title.prefix(32))):\(minutesDigest)"
        let base = DesktopFeishuIdempotency.normalize(arguments["idempotency_key"] as? String) ?? defaultBase

        return try await withIdempotencyLock(key: base) {
            let docIsLocal = !computeHasFeishuOpenAPICredentials()
            var document: [String: Any]
            var documentReplayed = false
            if let stored = DesktopFeishuIdempotency.read(base + ":doc", isLocalDemo: docIsLocal,
                                                          from: readPluginStorage(pluginID: "feishu_calendar")) {
                documentReplayed = true
                document = (try? JSONSerialization.jsonObject(with: Data(stored.result.utf8)) as? [String: Any]) ?? [:]
            } else {
                let activity = try await createFeishuDocument(title: title, content: minutes)
                document = ["ok": true, "document_id": activity.target, "title": activity.title,
                            "url": activity.documentURL ?? "", "channel": activity.channel]
                recordIdempotentWrite(key: base + ":doc",
                    result: try Self.encodeJSONObject(document), target: activity.target,
                    isLocalDemo: activity.channel == "local")
            }

            // The receipt only ships once the document exists, so the group never gets a dead link.
            // Re-read storage after the document write so we never inspect a stale pre-await snapshot.
            let documentURL = (document["url"] as? String) ?? ""
            let receiptBody = ((arguments["receipt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "纪要已归档：\(title)\n\(documentURL.isEmpty ? "" : documentURL)"
            let receiptIsLocal = !isFeishuBotMessageRemote(receiveID: rawReceiveID)
            var receipt: [String: Any]
            var receiptReplayed = false
            if let stored = DesktopFeishuIdempotency.read(base + ":receipt", isLocalDemo: receiptIsLocal,
                                                          from: readPluginStorage(pluginID: "feishu_calendar")) {
                receiptReplayed = true
                receipt = (try? JSONSerialization.jsonObject(with: Data(stored.result.utf8)) as? [String: Any]) ?? [:]
            } else if arguments["send_receipt"] as? Bool == false {
                receipt = ["ok": true, "skipped": true]
            } else {
                let activity = try await sendFeishuBotMessage(title: "会后回执 · \(title)", content: receiptBody,
                    msgType: "interactive", receiveID: rawReceiveID)
                receipt = ["ok": true, "message_id": activity.id, "title": activity.title, "target": activity.target]
                recordIdempotentWrite(key: base + ":receipt",
                    result: try Self.encodeJSONObject(receipt), target: activity.target,
                    isLocalDemo: activity.channel == "local")
            }

            // Recipe bindings only read one level (`${step.x.output.field}`), so the two things a workflow needs are
            // also exposed flat. The nested objects stay for the transcript card.
            return try Self.encodeJSONObject([
                "ok": true,
                "plugin": "feishu_calendar",
                "idempotency_key": base,
                "document": document,
                "receipt": receipt,
                "document_id": document["document_id"] ?? "",
                "url": document["url"] ?? "",
                "message_id": receipt["message_id"] ?? "",
                "replayed": documentReplayed && receiptReplayed,
                "document_replayed": documentReplayed,
                "receipt_replayed": receiptReplayed
            ])
        }
    }

    private func isFeishuBotMessageRemote(receiveID: String) -> Bool {
        let cleanTarget = receiveID.trimmingCharacters(in: .whitespacesAndNewlines)
        let webhookURL = settingValue(pluginID: "feishu_calendar", key: "bot_webhook_url")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (!webhookURL.isEmpty && cleanTarget.isEmpty) || computeHasFeishuOpenAPICredentials()
    }

    private func withIdempotencyLock<T>(key rawKey: String?, operation: () async throws -> T) async rethrows -> T {
        guard let key = DesktopFeishuIdempotency.normalize(rawKey) else {
            return try await operation()
        }
        while inFlightIdempotencyWaiters[key] != nil {
            await withCheckedContinuation { continuation in
                inFlightIdempotencyWaiters[key, default: []].append(continuation)
            }
        }
        inFlightIdempotencyWaiters[key] = []
        defer {
            let waiters = inFlightIdempotencyWaiters.removeValue(forKey: key) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
        return try await operation()
    }

    /// Remembers a confirmed write under the caller's key so the same meeting loop cannot post twice.
    private func recordIdempotentWrite(key rawKey: String?, result: String, target: String, isLocalDemo: Bool = false) {
        guard let key = DesktopFeishuIdempotency.normalize(rawKey) else { return }
        var storage = readPluginStorage(pluginID: "feishu_calendar")
        DesktopFeishuIdempotency.write(.init(key: key, result: result, target: target,
            recordedAt: Self.dateTimeFormatter.string(from: referenceDateProvider())),
            isLocalDemo: isLocalDemo, into: &storage)
        writePluginStorage(pluginID: "feishu_calendar", storage: storage)
    }

    private final class SandboxHTTPBox: @unchecked Sendable {
        var result: Result<(Data, Int), Error>?
    }

    nonisolated static func resolveAuthorizedWorkspaceFileURL(
        rootDirectory: URL,
        relativePath: String,
        allowedPrefixes: [String],
        createParents: Bool
    ) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DesktopRuntimeError.message("工作区文件路径无效或包含越界访问：\(relativePath)")
        }

        let normalizedPath = components.joined(separator: "/")
        let normalizedPrefixes = allowedPrefixes.compactMap { raw -> String? in
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return clean.isEmpty ? nil : clean
        }
        let isAuthorized = normalizedPrefixes.contains { prefix in
            normalizedPath == prefix || normalizedPath.hasPrefix(prefix + "/")
        }
        guard isAuthorized else {
            throw DesktopRuntimeError.message("插件未授权访问工作区路径 \(normalizedPath)（允许前缀：\(allowedPrefixes.joined(separator: ", "))）。")
        }

        let manager = FileManager.default
        if let kind = try? manager.attributesOfItem(atPath: rootDirectory.path)[.type],
           kind as? FileAttributeType == .typeSymbolicLink {
            throw DesktopRuntimeError.message("工作区路径不能包含符号链接。")
        }
        let standardizedRoot = rootDirectory.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(rootDirectory.lastPathComponent, isDirectory: true)
        if createParents {
            try manager.createDirectory(at: standardizedRoot, withIntermediateDirectories: true)
        }

        var url = standardizedRoot
        for component in components {
            url.appendPathComponent(String(component))
            if let kind = try? manager.attributesOfItem(atPath: url.path)[.type],
               kind as? FileAttributeType == .typeSymbolicLink {
                throw DesktopRuntimeError.message("工作区路径不能包含符号链接：\(relativePath)")
            }
        }
        guard url.standardizedFileURL.path.hasPrefix(standardizedRoot.path + "/") else {
            throw DesktopRuntimeError.message("文件路径越出了当前会话工作区：\(relativePath)")
        }
        if createParents {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        return url
    }

    private func evaluateJSTool(
        plugin: DesktopInstalledPlugin,
        tool: DesktopPluginToolManifest,
        argumentsData: Data,
        workspaceDirectory: URL?
    ) async throws -> String {
        let initialStorage = readPluginStorage(pluginID: plugin.id)
        var settingsMap: [String: String] = [:]
        for field in plugin.manifest.settingsSchema where field.kind != .secret {
            settingsMap[field.key] = settingValue(pluginID: plugin.id, key: field.key)
        }
        settingsMap["today"] = Self.dateFormatter.string(from: referenceDateProvider())
        settingsMap["mode"] = (plugin.id == "feishu_calendar" && hasFeishuRemoteCredentials) ? "feishu" : "local"
        let frozenSettingsMap = settingsMap
        let transport = self.httpTransport
        let targetWorkspaceDir = workspaceDirectory ?? self.workspaceDirectory

        let (jsonString, updatedStorage, storageMutated) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(String, [String: String], Bool), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let context = JSContext() else {
                    continuation.resume(throwing: DesktopRuntimeError.message("无法初始化插件 JavaScript 沙箱。"))
                    return
                }
                var jsException: String?
                context.exceptionHandler = { _, exception in
                    jsException = exception?.toString() ?? "未知脚本错误"
                }

                var currentStorage = initialStorage
                var storageMutated = false
                let arguments = (try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any]) ?? [:]

                let getSettingBlock: @convention(block) (String) -> String = { key in
                    frozenSettingsMap[key] ?? ""
                }
                let getStorageBlock: @convention(block) (String) -> String = { key in
                    currentStorage[key] ?? ""
                }
                let setStorageBlock: @convention(block) (String, String) -> Void = { key, value in
                    currentStorage[key] = value
                    storageMutated = true
                }
                let httpFetchBlock: @convention(block) (String, String) -> String = { urlString, optionsJSON in
                    guard let url = URL(string: urlString),
                          url.scheme?.lowercased() == "https",
                          let host = url.host?.lowercased() else {
                        return "__AMBER_ERR__:插件仅允许访问 HTTPS 地址：\(urlString)"
                    }
                    let allowedDomains = plugin.manifest.capabilities.networkDomains.map { $0.lowercased() }
                    let permitted = allowedDomains.contains { allowed in
                        host == allowed || host.hasSuffix("." + allowed)
                    }
                    guard permitted else {
                        return "__AMBER_ERR__:插件 \(plugin.manifest.name) 未授权访问域名 \(host)（允许列表：\(allowedDomains.joined(separator: ", "))）。"
                    }

                    let optionsData = Data(optionsJSON.utf8)
                    let options = (try? JSONSerialization.jsonObject(with: optionsData) as? [String: Any]) ?? [:]
                    let method = ((options["method"] as? String) ?? "GET").uppercased()
                    var request = URLRequest(url: url)
                    request.httpMethod = method
                    request.timeoutInterval = 20
                    if let headers = options["headers"] as? [String: Any] {
                        for (k, v) in headers {
                            request.setValue(String(describing: v), forHTTPHeaderField: k)
                        }
                    }
                    if let bodyString = options["body"] as? String {
                        request.httpBody = Data(bodyString.utf8)
                    } else if let bodyObj = options["body"],
                              !(bodyObj is NSNull),
                              JSONSerialization.isValidJSONObject(bodyObj),
                              let data = try? JSONSerialization.data(withJSONObject: bodyObj) {
                        request.httpBody = data
                    }

                    let box = SandboxHTTPBox()
                    let semaphore = DispatchSemaphore(value: 0)
                    let capturedRequest = request
                    Task.detached {
                        do {
                            let response = try await transport.send(request: capturedRequest)
                            box.result = .success(response)
                        } catch {
                            box.result = .failure(error)
                        }
                        semaphore.signal()
                    }
                    if semaphore.wait(timeout: .now() + 22) == .timedOut {
                        return "__AMBER_ERR__:外部请求超时（20 秒）：\(host)"
                    }
                    switch box.result {
                    case .success(let (data, status)):
                        let bodyText = String(decoding: data, as: UTF8.self)
                        let parsedJSON = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
                        let payload: [String: Any] = [
                            "ok": (200...299).contains(status),
                            "status": status,
                            "body": bodyText,
                            "text": bodyText,
                            "json": parsedJSON
                        ]
                        if let encoded = try? DesktopPluginStore.encodeJSONObject(payload) {
                            return encoded
                        }
                        return #"{"ok":false,"status":500,"body":""}"#
                    case .failure(let error):
                        return "__AMBER_ERR__:\(error.localizedDescription)"
                    case .none:
                        return "__AMBER_ERR__:外部请求未返回结果：\(host)"
                    }
                }
                let workspaceReadBlock: @convention(block) (String) -> String = { relativePath in
                    do {
                        let url = try DesktopPluginStore.resolveAuthorizedWorkspaceFileURL(
                            rootDirectory: targetWorkspaceDir,
                            relativePath: relativePath,
                            allowedPrefixes: plugin.manifest.capabilities.workspaceReadPrefixes,
                            createParents: false
                        )
                        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                            return "__AMBER_ERR__:工作区文件不存在或不是普通文件：\(relativePath)"
                        }
                        let data = try Data(contentsOf: url)
                        guard let text = String(data: data, encoding: .utf8) else {
                            return "__AMBER_ERR__:工作区文件不是有效的 UTF-8 文本：\(relativePath)"
                        }
                        return text
                    } catch {
                        return "__AMBER_ERR__:\(error.localizedDescription)"
                    }
                }
                let workspaceWriteBlock: @convention(block) (String, String) -> String = { relativePath, content in
                    guard tool.effect == .sideEffect || tool.effect == .idempotent else {
                        return "__AMBER_ERR__:只读工具（\(tool.name)，effect=\(tool.effect.rawValue)）禁止调用 amber.workspace.write 写入工作区文件；请将工具 effect 声明为 sideEffect 或 idempotent。"
                    }
                    do {
                        let url = try DesktopPluginStore.resolveAuthorizedWorkspaceFileURL(
                            rootDirectory: targetWorkspaceDir,
                            relativePath: relativePath,
                            allowedPrefixes: plugin.manifest.capabilities.workspaceWritePrefixes,
                            createParents: true
                        )
                        try Data(content.utf8).write(to: url, options: .atomic)
                        return "ok"
                    } catch {
                        return "__AMBER_ERR__:\(error.localizedDescription)"
                    }
                }

                context.setObject(getSettingBlock, forKeyedSubscript: "__amberGetSetting" as NSString)
                context.setObject(getStorageBlock, forKeyedSubscript: "__amberGetStorage" as NSString)
                context.setObject(setStorageBlock, forKeyedSubscript: "__amberSetStorage" as NSString)
                context.setObject(httpFetchBlock, forKeyedSubscript: "__amberHttpFetch" as NSString)
                context.setObject(workspaceReadBlock, forKeyedSubscript: "__amberWorkspaceRead" as NSString)
                context.setObject(workspaceWriteBlock, forKeyedSubscript: "__amberWorkspaceWrite" as NSString)

                let bootstrap = """
                function __amberUnwrap(raw) {
                    if (typeof raw === 'string' && raw.indexOf('__AMBER_ERR__:') === 0) {
                        throw new Error(raw.slice('__AMBER_ERR__:'.length));
                    }
                    return raw;
                }
                const amber = Object.freeze({
                    settings: Object.freeze({
                        get: function(key) { return __amberGetSetting(String(key)); }
                    }),
                    storage: Object.freeze({
                        get: function(key) { return __amberGetStorage(String(key)); },
                        set: function(key, val) { __amberSetStorage(String(key), typeof val === 'string' ? val : JSON.stringify(val)); }
                    }),
                    http: Object.freeze({
                        fetch: function(url, options) {
                            const raw = __amberUnwrap(__amberHttpFetch(String(url), options == null ? '{}' : JSON.stringify(options)));
                            return JSON.parse(raw);
                        }
                    }),
                    workspace: Object.freeze({
                        read: function(path) {
                            return __amberUnwrap(__amberWorkspaceRead(String(path)));
                        },
                        write: function(path, content) {
                            __amberUnwrap(__amberWorkspaceWrite(String(path), typeof content === 'string' ? content : JSON.stringify(content)));
                            return true;
                        }
                    })
                });
                """
                context.evaluateScript(bootstrap)
                context.evaluateScript(plugin.scriptSource)
                if let jsException {
                    continuation.resume(throwing: DesktopRuntimeError.message("插件 \(plugin.manifest.name) 脚本加载失败：\(jsException)"))
                    return
                }

                guard let fn = context.objectForKeyedSubscript(tool.entry), !fn.isUndefined else {
                    continuation.resume(throwing: DesktopRuntimeError.message("插件 \(plugin.manifest.name) 缺少入口函数 \(tool.entry)。"))
                    return
                }
                guard let resultValue = fn.call(withArguments: [arguments]) else {
                    continuation.resume(throwing: DesktopRuntimeError.message("插件工具 \(tool.name) 未返回结果。"))
                    return
                }
                if let jsException {
                    continuation.resume(throwing: DesktopRuntimeError.message("插件工具 \(tool.name) 执行异常：\(jsException)"))
                    return
                }

                let serialized: String
                if let json = context.objectForKeyedSubscript("JSON")?
                    .objectForKeyedSubscript("stringify")?
                    .call(withArguments: [resultValue])?
                    .toString(),
                   json != "undefined" {
                    serialized = json
                } else {
                    serialized = resultValue.toString() ?? "{}"
                }
                continuation.resume(returning: (serialized, currentStorage, storageMutated))
            }
        }

        if storageMutated {
            writePluginStorage(pluginID: plugin.id, storage: updatedStorage)
            if plugin.id == "feishu_calendar" {
                loadCalendarEventsFromStorage()
                loadBotActivitiesFromStorage()
            }
            rebuildProjections()
        }

        return jsonString
    }

    private func evaluateInspectorCardSnapshot(
        plugin: DesktopInstalledPlugin,
        card: DesktopPluginInspectorCardManifest,
        today: String
    ) -> DesktopInspectorCardSnapshot {
        let defaultFooter = plugin.manifest.ui.workspaceViews.first.map { "打开\($0.title)…" }
        let defaultViewID = plugin.manifest.ui.workspaceViews.first?.id
        let fallback = DesktopInspectorCardSnapshot(
            pluginID: plugin.id,
            pluginName: plugin.manifest.name,
            cardID: card.id,
            title: card.title,
            symbol: card.symbol,
            statusBadge: "已启用",
            items: [],
            emptyMessage: "\(plugin.manifest.name) 已就绪。",
            footerActionTitle: defaultFooter,
            opensWorkspaceViewID: defaultViewID
        )

        let entryName = card.entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entryName.isEmpty,
              !plugin.scriptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let context = JSContext() else {
            return fallback
        }

        var hadException = false
        context.exceptionHandler = { _, _ in
            hadException = true
        }

        let currentStorage = readPluginStorage(pluginID: plugin.id)
        var settingsMap: [String: String] = [:]
        for field in plugin.manifest.settingsSchema where field.kind != .secret {
            settingsMap[field.key] = settingValue(pluginID: plugin.id, key: field.key)
        }
        settingsMap["today"] = today
        settingsMap["mode"] = "local"

        let getSettingBlock: @convention(block) (String) -> String = { key in
            settingsMap[key] ?? ""
        }
        let getStorageBlock: @convention(block) (String) -> String = { key in
            currentStorage[key] ?? ""
        }
        context.setObject(getSettingBlock, forKeyedSubscript: "__amberGetSetting" as NSString)
        context.setObject(getStorageBlock, forKeyedSubscript: "__amberGetStorage" as NSString)

        let bootstrap = """
        const amber = Object.freeze({
            settings: Object.freeze({
                get: function(key) { return __amberGetSetting(String(key)); }
            }),
            storage: Object.freeze({
                get: function(key) { return __amberGetStorage(String(key)); },
                set: function() {}
            })
        });
        """
        context.evaluateScript(bootstrap)
        context.evaluateScript(plugin.scriptSource)
        guard !hadException,
              let fn = context.objectForKeyedSubscript(entryName),
              !fn.isUndefined,
              let rawResult = fn.call(withArguments: []),
              !hadException,
              !rawResult.isUndefined,
              !rawResult.isNull else {
            return fallback
        }

        func parseItems(_ array: [[String: Any]]) -> [DesktopInspectorCardItem] {
            array.enumerated().compactMap { index, dict in
                let title = ((dict["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let id = ((dict["id"] as? String) ?? "item_\(index)").trimmingCharacters(in: .whitespacesAndNewlines)
                let badge = (dict["badge"] as? String) ?? ""
                let subtitle = dict["subtitle"] as? String
                let actionTitle = (dict["actionTitle"] as? String) ?? (dict["action_title"] as? String)
                let prompt = dict["prompt"] as? String
                return DesktopInspectorCardItem(
                    id: id.isEmpty ? "item_\(index)" : id,
                    badge: badge,
                    title: title,
                    subtitle: subtitle,
                    actionTitle: actionTitle,
                    prompt: prompt
                )
            }
        }

        if let dict = rawResult.toObject() as? [String: Any] {
            let rawItems = (dict["items"] as? [[String: Any]]) ?? []
            let items = parseItems(rawItems)
            let statusBadge = (dict["statusBadge"] as? String)
                ?? (dict["status_badge"] as? String)
                ?? (items.isEmpty ? "已启用" : "\(items.count)")
            let emptyMessage = (dict["emptyMessage"] as? String)
                ?? (dict["empty_message"] as? String)
                ?? "\(plugin.manifest.name) 已就绪。"
            let footerActionTitle = (dict["footerActionTitle"] as? String)
                ?? (dict["footer_action_title"] as? String)
                ?? defaultFooter
            let opensViewID = (dict["opensWorkspaceViewID"] as? String)
                ?? (dict["opens_workspace_view_id"] as? String)
                ?? defaultViewID
            return DesktopInspectorCardSnapshot(
                pluginID: plugin.id,
                pluginName: plugin.manifest.name,
                cardID: card.id,
                title: card.title,
                symbol: card.symbol,
                statusBadge: statusBadge,
                items: items,
                emptyMessage: emptyMessage,
                footerActionTitle: footerActionTitle,
                opensWorkspaceViewID: opensViewID
            )
        } else if let rawItems = rawResult.toObject() as? [[String: Any]] {
            let items = parseItems(rawItems)
            return DesktopInspectorCardSnapshot(
                pluginID: plugin.id,
                pluginName: plugin.manifest.name,
                cardID: card.id,
                title: card.title,
                symbol: card.symbol,
                statusBadge: items.isEmpty ? "已启用" : "\(items.count)",
                items: items,
                emptyMessage: "\(plugin.manifest.name) 已就绪。",
                footerActionTitle: defaultFooter,
                opensWorkspaceViewID: defaultViewID
            )
        }

        return fallback
    }

    // MARK: Precomputed Projections for Zero-IO SwiftUI Rendering

    func rebuildProjections() {
        let now = referenceDateProvider()
        let today = Self.dateFormatter.string(from: now)
        let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let tomorrow = Self.dateFormatter.string(from: tomorrowDate)
        if todayDateString != today { todayDateString = today }
        if tomorrowDateString != tomorrow { tomorrowDateString = tomorrow }

        var nextDeclarations: [DesktopToolDeclaration] = []
        var nextViews: [DesktopPluginWorkspaceViewEntry] = []
        var nextCommands: [DesktopPluginSlashCommandEntry] = []
        var nextCards: [DesktopInspectorCardSnapshot] = []

        var nextEffects: [String: DesktopToolEffect] = [:]
        for plugin in plugins where plugin.enabled {
            for tool in plugin.manifest.tools {
                let qName = plugin.qualifiedToolName(tool.name)
                nextEffects[qName] = tool.effect
                let needsApproval = tool.effect == .sideEffect || tool.effect == .idempotent
                nextDeclarations.append(DesktopToolDeclaration(
                    name: qName,
                    description: "[\(plugin.manifest.name)] \(tool.description)",
                    parametersJSON: tool.parametersJSON,
                    needsApproval: needsApproval
                ))
            }

            var pluginCards: [DesktopInspectorCardSnapshot] = []
            for card in plugin.manifest.ui.inspectorCards {
                if plugin.id == "feishu_calendar" {
                    let todayEvents = calendarEvents.filter { $0.datePrefix == today }
                    let displayEvents = todayEvents.isEmpty ? Array(calendarEvents.prefix(3)) : todayEvents
                    let items = displayEvents.map { event in
                        let subParts = [event.location, event.attendees.isEmpty ? nil : "\(event.attendees.count) 人参会"]
                            .compactMap { $0 }.filter { !$0.isEmpty }
                        return DesktopInspectorCardItem(
                            id: event.id,
                            badge: event.timeRangeText,
                            title: event.summary,
                            subtitle: subParts.isEmpty ? nil : subParts.joined(separator: " · "),
                            actionTitle: "准备",
                            prompt: event.preparationPrompt
                        )
                    }
                    let badgeText = todayEvents.isEmpty ? "\(calendarEvents.count)" : "\(todayEvents.count)"
                    pluginCards.append(DesktopInspectorCardSnapshot(
                        pluginID: plugin.id,
                        pluginName: plugin.manifest.name,
                        cardID: card.id,
                        title: card.title,
                        symbol: card.symbol,
                        statusBadge: badgeText,
                        items: items,
                        emptyMessage: "今日暂无飞书日程，可在日历视图新建或让 Amber 帮你安排。",
                        footerActionTitle: "打开飞书工作台",
                        opensWorkspaceViewID: plugin.manifest.ui.workspaceViews.first?.id
                    ))
                } else {
                    pluginCards.append(evaluateInspectorCardSnapshot(plugin: plugin, card: card, today: today))
                }
            }
            nextCards.append(contentsOf: pluginCards)

            let pluginStorage = plugin.id == "feishu_calendar" ? [:] : readPluginStorage(pluginID: plugin.id)
            let fallbackCardItemsCount = pluginCards.reduce(0) { $0 + $1.items.count }
            for view in plugin.manifest.ui.workspaceViews {
                let badge: Int
                if plugin.id == "feishu_calendar" {
                    if view.id == "bot_studio" {
                        badge = botActivities.count
                    } else {
                        badge = calendarEvents.filter { $0.datePrefix == today }.count
                    }
                } else if let explicit = Int(pluginStorage["badge:\(view.id)"] ?? pluginStorage["badge_count"] ?? "") {
                    badge = max(0, explicit)
                } else {
                    badge = fallbackCardItemsCount
                }
                nextViews.append(DesktopPluginWorkspaceViewEntry(
                    pluginID: plugin.id,
                    pluginName: plugin.manifest.name,
                    viewID: view.id,
                    title: view.title,
                    symbol: view.symbol,
                    subtitle: view.subtitle,
                    badgeCount: badge
                ))
            }

            for command in plugin.manifest.ui.commands {
                nextCommands.append(DesktopPluginSlashCommandEntry(
                    pluginID: plugin.id,
                    pluginName: plugin.manifest.name,
                    commandID: command.id,
                    title: command.title,
                    slash: command.slash,
                    symbol: command.symbol,
                    promptTemplate: command.promptTemplate
                ))
            }
        }

        DesktopToolRegistry.updatePluginEffects(nextEffects)
        let nextCalDAV = computeHasFeishuCalDAVCredentials()
        if hasFeishuCalDAVCredentials != nextCalDAV { hasFeishuCalDAVCredentials = nextCalDAV }
        let nextBot = computeHasFeishuBotCredentials()
        if hasFeishuBotCredentials != nextBot { hasFeishuBotCredentials = nextBot }
        let nextRemote = computeHasFeishuRemoteCredentials()
        if hasFeishuRemoteCredentials != nextRemote { hasFeishuRemoteCredentials = nextRemote }
        let nextFreeSlots = computeTodayFreeSlots(today: today)
        if todayFreeSlots != nextFreeSlots { todayFreeSlots = nextFreeSlots }

        var stateChanged = false
        if activeToolDeclarations != nextDeclarations {
            activeToolDeclarations = nextDeclarations
            stateChanged = true
        }
        if activeWorkspaceViews != nextViews {
            activeWorkspaceViews = nextViews
            stateChanged = true
        }
        if activeSlashCommands != nextCommands { activeSlashCommands = nextCommands }
        if inspectorSnapshots != nextCards { inspectorSnapshots = nextCards }
        if stateChanged { onStateChanged?() }
    }

    // MARK: Built-in Feishu Suite (Calendar CalDAV + Bot Webhook/OpenAPI) Helpers

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private func computeTodayFreeSlots(today: String) -> [DesktopPluginFreeSlot] {
        let startHour = max(0, min(23, Int(settingValue(pluginID: "feishu_calendar", key: "workday_start_hour")) ?? 9))
        let endHour = max(startHour + 1, min(24, Int(settingValue(pluginID: "feishu_calendar", key: "workday_end_hour")) ?? 18))
        let dayEvents = calendarEvents.filter { $0.datePrefix == today }
        let busyRanges: [(Int, Int)] = dayEvents.compactMap { ev in
            guard ev.startTime.count >= 16, ev.endTime.count >= 16 else { return nil }
            let sParts = String(ev.startTime.dropFirst(11).prefix(5)).split(separator: ":")
            let eParts = String(ev.endTime.dropFirst(11).prefix(5)).split(separator: ":")
            guard sParts.count == 2, eParts.count == 2,
                  let sh = Int(sParts[0]), let sm = Int(sParts[1]),
                  let eh = Int(eParts[0]), let em = Int(eParts[1]) else { return nil }
            let s = sh * 60 + sm
            let e = eh * 60 + em
            return e > s ? (s, e) : nil
        }.sorted { $0.0 < $1.0 }

        var slots: [DesktopPluginFreeSlot] = []
        var cursor = startHour * 60
        let dayEnd = endHour * 60
        for (bStart, bEnd) in busyRanges {
            if bStart - cursor >= 30 {
                slots.append(DesktopPluginFreeSlot(
                    start: String(format: "%02d:%02d", cursor / 60, cursor % 60),
                    end: String(format: "%02d:%02d", bStart / 60, bStart % 60),
                    minutes: bStart - cursor
                ))
            }
            if bEnd > cursor { cursor = bEnd }
        }
        if dayEnd - cursor >= 30 {
            slots.append(DesktopPluginFreeSlot(
                start: String(format: "%02d:%02d", cursor / 60, cursor % 60),
                end: String(format: "%02d:%02d", dayEnd / 60, dayEnd % 60),
                minutes: dayEnd - cursor
            ))
        }
        return slots
    }

    private static func normalizeDateTimeString(_ raw: String, fallbackDate: Date) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "T", with: " ")
        if trimmed.count >= 16 {
            return String(trimmed.prefix(16))
        }
        if trimmed.count == 5, trimmed.contains(":") {
            return "\(dateFormatter.string(from: fallbackDate)) \(trimmed)"
        }
        return trimmed
    }

    private static func parseTimestamp(_ raw: String, fallback: Date) -> Int {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "T", with: " ")
        if let date = dateTimeFormatter.date(from: String(normalized.prefix(16))) {
            return Int(date.timeIntervalSince1970)
        }
        return Int(fallback.timeIntervalSince1970)
    }

    /// Builds an RFC 5545 iCalendar payload for CalDAV `PUT` event creation.
    private static func buildICalendarEvent(
        uid: String,
        summary: String,
        startTime: String,
        endTime: String,
        location: String,
        notes: String
    ) -> String {
        func toICSDateTime(_ str: String) -> String {
            let digits = str.filter(\.isNumber)
            if digits.count >= 12 {
                return "\(digits.prefix(8))T\(digits.dropFirst(8).prefix(4))00"
            }
            return "20261030T090000"
        }
        let dtStart = toICSDateTime(startTime)
        let dtEnd = toICSDateTime(endTime)
        return [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Amber//Feishu CalDAV Client//CN",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "DTSTART:\(dtStart)",
            "DTEND:\(dtEnd)",
            "SUMMARY:\(summary)",
            "LOCATION:\(location)",
            "DESCRIPTION:\(notes)",
            "END:VEVENT",
            "END:VCALENDAR"
        ].joined(separator: "\r\n")
    }

    /// Parses CalDAV `REPORT` XML (`<c:calendar-data>`) or raw `.ics` `BEGIN:VEVENT ... END:VEVENT` blocks.
    static func parseCalDAVEICSData(data: Data, fallbackDate: Date) -> [DesktopPluginEventItem] {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("BEGIN:VEVENT") else {
            return []
        }
        let blocks = text.components(separatedBy: "BEGIN:VEVENT").dropFirst()
        var events: [DesktopPluginEventItem] = []

        for rawBlock in blocks {
            guard let endRange = rawBlock.range(of: "END:VEVENT") else { continue }
            let block = String(rawBlock[..<endRange.lowerBound])
                .replacingOccurrences(of: "\r\n ", with: "")
                .replacingOccurrences(of: "\n ", with: "")
            let lines = block.components(separatedBy: .newlines)

            var uid = ""
            var summary = ""
            var dtStart = ""
            var dtEnd = ""
            var location = "飞书日历 (CalDAV)"
            var notes = ""

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                let propPart = String(trimmed[..<colon]).uppercased()
                let valuePart = String(trimmed[trimmed.index(after: colon)...])
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\,", with: ",")
                let key = propPart.split(separator: ";").first.map(String.init) ?? propPart
                switch key {
                case "UID": uid = valuePart
                case "SUMMARY": summary = valuePart
                case "DTSTART": dtStart = parseICSTimestamp(valuePart, fallbackDate: fallbackDate)
                case "DTEND": dtEnd = parseICSTimestamp(valuePart, fallbackDate: fallbackDate)
                case "LOCATION": if !valuePart.isEmpty { location = valuePart }
                case "DESCRIPTION": notes = valuePart
                default: break
                }
            }
            guard !summary.isEmpty else { continue }
            let finalID = uid.isEmpty ? "caldav_" + UUID().uuidString.prefix(8).lowercased() : uid
            let startStr = dtStart.isEmpty ? "\(dateFormatter.string(from: fallbackDate)) 09:00" : dtStart
            let endStr = dtEnd.isEmpty ? "\(dateFormatter.string(from: fallbackDate)) 10:00" : dtEnd
            events.append(DesktopPluginEventItem(
                id: finalID,
                summary: summary,
                startTime: startStr,
                endTime: endStr,
                location: location,
                attendees: [],
                notes: notes,
                source: "feishu"
            ))
        }
        return events
    }

    private static func parseICSTimestamp(_ raw: String, fallbackDate: Date) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = Array(clean.filter(\.isNumber))
        guard digits.count >= 8 else {
            return "\(dateFormatter.string(from: fallbackDate)) 09:00"
        }
        let yyyy = String(digits[0..<4])
        let mm = String(digits[4..<6])
        let dd = String(digits[6..<8])
        if digits.count >= 12 {
            let hh = String(digits[8..<10])
            let min = String(digits[10..<12])
            if clean.hasSuffix("Z") {
                var comps = DateComponents()
                comps.calendar = Calendar(identifier: .gregorian)
                comps.timeZone = TimeZone(secondsFromGMT: 0)
                comps.year = Int(yyyy)
                comps.month = Int(mm)
                comps.day = Int(dd)
                comps.hour = Int(hh)
                comps.minute = Int(min)
                if let utcDate = comps.date {
                    return dateTimeFormatter.string(from: utcDate)
                }
            }
            return "\(yyyy)-\(mm)-\(dd) \(hh):\(min)"
        }
        return "\(yyyy)-\(mm)-\(dd) 09:00"
    }

    private static func parseFeishuEventsResponse(data: Data, fallbackDate: Date) -> [DesktopPluginEventItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let items = dataObj["items"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item -> DesktopPluginEventItem? in
            let id = (item["event_id"] as? String) ?? UUID().uuidString
            let summary = (item["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "飞书日程"
            guard !summary.isEmpty else { return nil }
            let description = (item["description"] as? String) ?? ""
            let startTS = ((item["start_time"] as? [String: Any])?["timestamp"] as? String).flatMap(Double.init)
            let endTS = ((item["end_time"] as? [String: Any])?["timestamp"] as? String).flatMap(Double.init)
            let startStr = startTS.map { dateTimeFormatter.string(from: Date(timeIntervalSince1970: $0)) }
                ?? "\(dateFormatter.string(from: fallbackDate)) 09:00"
            let endStr = endTS.map { dateTimeFormatter.string(from: Date(timeIntervalSince1970: $0)) }
                ?? "\(dateFormatter.string(from: fallbackDate)) 10:00"
            let location = ((item["location"] as? [String: Any])?["name"] as? String) ?? "飞书日历"
            return DesktopPluginEventItem(
                id: id,
                summary: summary,
                startTime: startStr,
                endTime: endStr,
                location: location,
                attendees: [],
                notes: description,
                source: "feishu"
            )
        }
    }

    /// Computes Feishu custom bot webhook HMAC-SHA256 signature (`timestamp + "\n" + secret` as key, empty msg).
    static func computeFeishuWebhookSign(timestamp: String, secret: String) -> String {
        let stringToSign = "\(timestamp)\n\(secret)"
        let key = SymmetricKey(data: Data(stringToSign.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(), using: key)
        return Data(mac).base64EncodedString()
    }

    private static func inferFeishuReceiveIDType(_ receiveID: String) -> String {
        if receiveID.hasPrefix("oc_") { return "chat_id" }
        if receiveID.hasPrefix("ou_") { return "open_id" }
        if receiveID.hasPrefix("on_") { return "union_id" }
        if receiveID.contains("@") { return "email" }
        return "chat_id"
    }

    private static func buildFeishuInteractiveCard(title: String, markdown: String) -> [String: Any] {
        [
            "config": ["wide_screen_mode": true],
            "header": [
                "template": "wathet",
                "title": ["tag": "plain_text", "content": title]
            ],
            "elements": [
                [
                    "tag": "markdown",
                    "content": markdown
                ]
            ]
        ]
    }

    private static func parseFeishuChatMessages(data: Data) -> [[String: String]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let items = dataObj["items"] as? [[String: Any]] else {
            return []
        }
        let timeOnlyFormatter = DateFormatter()
        timeOnlyFormatter.calendar = Calendar(identifier: .gregorian)
        timeOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeOnlyFormatter.dateFormat = "HH:mm"

        return items.compactMap { item -> [String: String]? in
            let sender = ((item["sender"] as? [String: Any])?["id"] as? String) ?? "飞书成员"
            let createTimeMs = (item["create_time"] as? String).flatMap(Double.init)
            let timeStr = createTimeMs.map { timeOnlyFormatter.string(from: Date(timeIntervalSince1970: $0 / 1000.0)) } ?? "近期"
            let rawContent = ((item["body"] as? [String: Any])?["content"] as? String) ?? ""
            var text = rawContent
            if let contentData = rawContent.data(using: .utf8),
               let contentObj = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
               let parsedText = contentObj["text"] as? String {
                text = parsedText
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ["sender": sender, "time": timeStr, "text": text]
        }
    }

    static func extractFeishuDocumentID(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), url.host != nil {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let idx = parts.firstIndex(where: { $0 == "docx" || $0 == "docs" || $0 == "wiki" }),
               idx + 1 < parts.count {
                return parts[idx + 1]
            }
            return parts.last ?? ""
        }
        return trimmed
    }

    static func defaultSeededEvents(now: Date) -> [DesktopPluginEventItem] {
        let today = dateFormatter.string(from: now)
        let tomorrow = dateFormatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400))
        return [
            DesktopPluginEventItem(
                id: "evt_feishu_01",
                summary: "产品周会 & 重点排期对齐",
                startTime: "\(today) 10:00",
                endTime: "\(today) 10:45",
                location: "飞书视频会议",
                attendees: ["林夏", "周航"],
                notes: "同步本周研发进度、确认核心功能验收标准。",
                source: "feishu"
            ),
            DesktopPluginEventItem(
                id: "evt_feishu_02",
                summary: "Amber 插件系统与 UI 评审",
                startTime: "\(today) 14:30",
                endTime: "\(today) 15:30",
                location: "3 号会议室",
                attendees: ["陈默", "苏晴"],
                notes: "评审 Obsidian 风格侧栏、右侧今日日程卡片与飞书工具闭环。",
                source: "feishu"
            ),
            DesktopPluginEventItem(
                id: "evt_feishu_03",
                summary: "桌面端体验走查与细节打磨",
                startTime: "\(tomorrow) 11:00",
                endTime: "\(tomorrow) 12:00",
                location: "飞书线上会议",
                attendees: ["设计组"],
                notes: "检查亮暗色对比度、边距对齐与命令面板快捷键。",
                source: "feishu"
            )
        ]
    }

    static func defaultSeededBotActivities(now: Date) -> [DesktopPluginBotActivityItem] {
        let today = dateFormatter.string(from: now)
        return [
            DesktopPluginBotActivityItem(
                id: "bot_seed_01",
                kind: "card",
                title: "今日飞书会议提醒卡片",
                summary: "已汇总今日 2 场重点会议（10:00 产品周会、14:30 插件系统与 UI 评审）并生成群通知卡片。",
                channel: "webhook",
                target: "产品研发核心群",
                timestamp: "\(today) 09:15",
                documentURL: nil
            ),
            DesktopPluginBotActivityItem(
                id: "bot_seed_02",
                kind: "doc_read",
                title: "Amber 飞书套件架构设计文档",
                summary: "日历模块采用 CalDAV 免审批直连同步个人日程；机器人模块支持群 Webhook 卡片推送、群聊历史纪要提取与飞书云文档读写。",
                channel: "openapi",
                target: "doxcn_amber_feishu_v2",
                timestamp: "\(today) 09:20",
                documentURL: "https://feishu.cn/docx/doxcn_amber_feishu_v2"
            )
        ]
    }

    static func makeBuiltInFeishuPlugin(enabled: Bool) -> DesktopInstalledPlugin {
        let manifest = DesktopPluginManifest(
            schema: DesktopPluginManifest.schemaV2,
            id: "feishu_calendar",
            name: "飞书",
            version: "2.0.0",
            description: "分为「飞书日历（CalDAV）」与「飞书机器人（Webhook / OpenAPI）」两大模块：支持个人 CalDAV 免审批同步日程，以及通过飞书机器人推送消息卡片、拉取群聊纪要、读写飞书云文档。",
            icon: "paperplane.circle",
            capabilities: DesktopPluginCapabilities(
                networkDomains: ["caldav.feishu.cn", "caldav.larksuite.com", "open.feishu.cn", "open.larksuite.com"],
                workspaceReadPrefixes: [],
                workspaceWritePrefixes: []
            ),
            settingsSchema: [
                // Group 1: Calendar (CalDAV)
                DesktopPluginSettingField(
                    key: "caldav_server",
                    title: "CalDAV 服务器地址",
                    kind: .string,
                    placeholder: "https://caldav.feishu.cn",
                    defaultValue: "https://caldav.feishu.cn",
                    help: "飞书客户端 → 设置 → 日历 → CalDAV 同步中的服务器地址。",
                    group: "calendar"
                ),
                DesktopPluginSettingField(
                    key: "caldav_username",
                    title: "CalDAV 用户名",
                    kind: .string,
                    placeholder: "u_xxxxxx",
                    defaultValue: "",
                    help: "在飞书设置中一键生成的个人 CalDAV 用户名，无需企业管理员审批。",
                    group: "calendar"
                ),
                DesktopPluginSettingField(
                    key: "caldav_password",
                    title: "CalDAV 密码",
                    kind: .secret,
                    placeholder: "安全保存在系统钥匙串中",
                    defaultValue: "",
                    help: "飞书 CalDAV 专用密码，用于同步与新建个人飞书日程。",
                    group: "calendar"
                ),
                DesktopPluginSettingField(
                    key: "workday_start_hour",
                    title: "工作时段开始（小时）",
                    kind: .integer,
                    placeholder: "9",
                    defaultValue: "9",
                    group: "calendar"
                ),
                DesktopPluginSettingField(
                    key: "workday_end_hour",
                    title: "工作时段结束（小时）",
                    kind: .integer,
                    placeholder: "18",
                    defaultValue: "18",
                    group: "calendar"
                ),
                DesktopPluginSettingField(
                    key: "default_calendar_id",
                    title: "备选日历 ID (OpenAPI)",
                    kind: .string,
                    placeholder: "primary",
                    defaultValue: "primary",
                    help: "未配置 CalDAV 时，若已配置机器人 App ID/Secret，可作为备选同步该日历 ID。",
                    group: "calendar"
                ),
                // Group 2: Feishu Bot (Webhook & OpenAPI)
                DesktopPluginSettingField(
                    key: "bot_webhook_url",
                    title: "群自定义机器人 Webhook",
                    kind: .string,
                    placeholder: "https://open.feishu.cn/open-apis/bot/v2/hook/...",
                    defaultValue: "",
                    help: "飞书群设置 → 群机器人 → 添加自定义机器人获取的 Webhook 地址，可一键向群内发通知卡片。",
                    group: "bot"
                ),
                DesktopPluginSettingField(
                    key: "bot_webhook_secret",
                    title: "Webhook 签名密钥 (可选)",
                    kind: .secret,
                    placeholder: "安全保存在系统钥匙串中",
                    defaultValue: "",
                    help: "若群自定义机器人启用了签名校验，填入密钥后将自动附带 HMAC-SHA256 签名。",
                    group: "bot"
                ),
                DesktopPluginSettingField(
                    key: "app_id",
                    title: "飞书应用机器人 App ID",
                    kind: .string,
                    placeholder: "cli_a1b2c3d4e5f6...",
                    defaultValue: "",
                    help: "飞书开放平台自建应用机器人的 App ID，支持收发消息、拉取群聊历史与读写云文档。",
                    group: "bot"
                ),
                DesktopPluginSettingField(
                    key: "app_secret",
                    title: "飞书应用机器人 App Secret",
                    kind: .secret,
                    placeholder: "安全保存在系统钥匙串中",
                    defaultValue: "",
                    help: "自建应用机器人的 App Secret，用于自动换取 tenant_access_token。",
                    group: "bot"
                ),
                DesktopPluginSettingField(
                    key: "default_receive_id",
                    title: "默认群聊 / 接收人 ID",
                    kind: .string,
                    placeholder: "oc_xxx (群 chat_id) 或 ou_xxx (open_id)",
                    defaultValue: "",
                    help: "应用机器人默认发送消息或拉取聊天记录的目标会话 ID。",
                    group: "bot"
                ),
                DesktopPluginSettingField(
                    key: "personal_access_token",
                    title: "个人访问令牌 (可选)",
                    kind: .secret,
                    placeholder: "u-...",
                    defaultValue: "",
                    help: "可选的 User Access Token，填入后可优先以个人授权调用飞书 OpenAPI。",
                    group: "bot"
                )
            ],
            tools: [
                DesktopPluginToolManifest(
                    name: "list_events",
                    description: "查询飞书日历中的日程列表（可按日期 yyyy-MM-dd 或关键词筛选）。",
                    effect: .networkRead,
                    entry: "listEvents",
                    parametersJSON: #"{"type":"object","properties":{"date":{"type":"string","description":"可选日期 yyyy-MM-dd，不填则返回全部近期日程"},"query":{"type":"string","description":"可选关键词过滤"}},"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "freebusy",
                    description: "查询指定日期（yyyy-MM-dd）的忙闲状态与可约会议的空闲时间段建议。",
                    effect: .networkRead,
                    entry: "freebusy",
                    parametersJSON: #"{"type":"object","properties":{"date":{"type":"string","description":"日期 yyyy-MM-dd"},"duration_minutes":{"type":"integer","description":"期望会议时长（分钟），默认 45"}},"required":["date"],"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "create_event",
                    description: "在飞书日历创建新的日程或会议邀约（通过 CalDAV 或开放平台同步，需要用户批准）。",
                    effect: .sideEffect,
                    entry: "createEvent",
                    parametersJSON: """
                    {"type":"object","properties":{\
                    "summary":{"type":"string","description":"会议或日程标题"},\
                    "start_time":{"type":"string","description":"开始时间 yyyy-MM-dd HH:mm"},\
                    "end_time":{"type":"string","description":"结束时间 yyyy-MM-dd HH:mm"},\
                    "location":{"type":"string","description":"会议地点或飞书会议链接"},\
                    "attendees":{"type":"array","items":{"type":"string"},"description":"参会人姓名列表"},\
                    "notes":{"type":"string","description":"会议议程或备注"},\
                    "idempotency_key":{"type":"string","description":"可选幂等键；同一键重复调用不会重复创建"}},\
                    "required":["summary","start_time","end_time"],"additionalProperties":false}
                    """
                ),
                DesktopPluginToolManifest(
                    name: "bot_send_message",
                    description: "通过飞书机器人（群 Webhook 或应用机器人）发送文本通知或富文本交互卡片到飞书群/个人。",
                    effect: .sideEffect,
                    entry: "botSendMessage",
                    parametersJSON: """
                    {"type":"object","properties":{\
                    "title":{"type":"string","description":"消息卡片标题"},\
                    "content":{"type":"string","description":"消息正文（支持 Markdown）"},\
                    "msg_type":{"type":"string","enum":["interactive","text"],"description":"默认 interactive"},\
                    "receive_id":{"type":"string","description":"chat_id (oc_xxx) 或 open_id (ou_xxx)，不填走 Webhook 或默认接收 ID"},\
                    "idempotency_key":{"type":"string","description":"可选幂等键；同一键重复调用不会重复发送"}},\
                    "required":["content"],"additionalProperties":false}
                    """
                ),
                DesktopPluginToolManifest(
                    name: "bot_fetch_chat_history",
                    description: "通过飞书机器人拉取指定飞书群聊（chat_id）的近期聊天记录，用于总结纪要或提取待办。",
                    effect: .networkRead,
                    entry: "botFetchChatHistory",
                    parametersJSON: #"{"type":"object","properties":{"chat_id":{"type":"string","description":"飞书群聊 chat_id (oc_xxx)，不填则使用默认群聊 ID"},"limit":{"type":"integer","description":"拉取条数，默认 15"}},"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "bot_read_doc",
                    description: "通过飞书机器人读取飞书云文档（Docx）的正文内容，支持传入飞书文档链接或 document_id。",
                    effect: .networkRead,
                    entry: "botReadDoc",
                    parametersJSON: #"{"type":"object","properties":{"document":{"type":"string","description":"飞书云文档链接（https://.../docx/...）或 document_id"}},"required":["document"],"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "bot_create_doc",
                    description: "通过飞书机器人在飞书云端创建一篇新的云文档（Docx），返回文档链接。",
                    effect: .sideEffect,
                    entry: "botCreateDoc",
                    parametersJSON: #"{"type":"object","properties":{"title":{"type":"string","description":"云文档标题"},"content":{"type":"string","description":"文档内容摘要或正文"},"folder_token":{"type":"string","description":"可选目标文件夹 Token"},"idempotency_key":{"type":"string","description":"可选幂等键；同一键重复调用不会重复创建"}},"required":["title"],"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "meeting_closeout",
                    description: "会后收口：把纪要建成飞书云文档再发群回执；同一个幂等键重复执行不会重复发。",
                    effect: .sideEffect,
                    entry: "meetingCloseout",
                    parametersJSON: """
                    {"type":"object","properties":{\
                    "title":{"type":"string","description":"会议标题，也用作云文档标题"},\
                    "minutes":{"type":"string","description":"已确认的纪要正文"},\
                    "receive_id":{"type":"string","description":"可选群 chat_id；默认用设置里的接收 ID"},\
                    "receipt":{"type":"string","description":"可选回执正文；默认是纪要已归档与链接"},\
                    "send_receipt":{"type":"boolean","description":"false 时只建文档不发回执"},\
                    "idempotency_key":{"type":"string","description":"可选幂等键；默认按日期与标题生成"}},\
                    "required":["title","minutes"],"additionalProperties":false}
                    """
                )
            ],
            ui: DesktopPluginUIManifest(
                inspectorCards: [
                    DesktopPluginInspectorCardManifest(
                        id: "today_agenda",
                        title: "今日飞书日程",
                        symbol: "calendar.badge.clock",
                        entry: "renderTodayInspector"
                    )
                ],
                workspaceViews: [
                    DesktopPluginWorkspaceViewManifest(
                        id: "calendar_board",
                        title: "飞书日历",
                        symbol: "calendar",
                        subtitle: "通过 CalDAV 直连同步个人飞书日历，查看排期忙闲或将会议一键推送至飞书群。"
                    ),
                    DesktopPluginWorkspaceViewManifest(
                        id: "bot_studio",
                        title: "飞书机器人",
                        symbol: "paperplane.circle",
                        subtitle: "通过飞书群 Webhook 或自建应用机器人发送消息卡片、拉取群聊纪要、读写飞书云文档。"
                    )
                ],
                commands: [
                    DesktopPluginCommandManifest(
                        id: "feishu_today",
                        title: "梳理今日飞书日程与会前准备",
                        slash: "/feishu-today",
                        symbol: "calendar",
                        promptTemplate: "请调用飞书日历工具读取我今天的日程安排，按时间顺序梳理每场会议需要准备的重点与待办事项。"
                    ),
                    DesktopPluginCommandManifest(
                        id: "feishu_freebusy",
                        title: "查询今日空闲时段",
                        slash: "/feishu-freebusy",
                        symbol: "clock.badge.checkmark",
                        promptTemplate: "请调用飞书日历工具查询我今天和明天的空闲时段，推荐适合安排 45 分钟评审会的时间窗口。"
                    ),
                    DesktopPluginCommandManifest(
                        id: "feishu_meet",
                        title: "在飞书日历预约会议",
                        slash: "/feishu-meet",
                        symbol: "calendar.badge.plus",
                        promptTemplate: "请帮我在飞书日历安排一场会议，先检查冲突再创建日程："
                    ),
                    DesktopPluginCommandManifest(
                        id: "feishu_notify",
                        title: "通过飞书机器人发送群通知卡片",
                        slash: "/feishu-notify",
                        symbol: "paperplane",
                        promptTemplate: "请将当前对话的核心结论整理成结构化要点，并调用飞书机器人工具（bot_send_message）发送一张飞书消息卡片到群里。"
                    ),
                    DesktopPluginCommandManifest(
                        id: "feishu_chat",
                        title: "拉取飞书群聊记录并生成纪要",
                        slash: "/feishu-chat",
                        symbol: "bubble.left.and.bubble.right",
                        promptTemplate: "请调用飞书机器人工具（bot_fetch_chat_history）拉取近期群聊记录，帮我提炼讨论结论、争议点与待办事项。"
                    ),
                    DesktopPluginCommandManifest(
                        id: "feishu_doc",
                        title: "读取或创建飞书云文档",
                        slash: "/feishu-doc",
                        symbol: "doc.text",
                        promptTemplate: "请调用飞书机器人云文档工具帮我读取或创建飞书文档："
                    )
                ]
            )
        )

        let script = """
        function _loadEvents() {
            const raw = amber.storage.get("events");
            if (!raw) return [];
            try { return JSON.parse(raw); } catch (e) { return []; }
        }

        function listEvents(input) {
            const events = _loadEvents();
            const targetDate = (input && input.date) ? String(input.date).trim() : "";
            const query = (input && input.query) ? String(input.query).trim().toLowerCase() : "";
            const filtered = events.filter(function(ev) {
                if (targetDate && String(ev.startTime || "").indexOf(targetDate) !== 0) return false;
                if (query) {
                    const haystack = [ev.summary, ev.location, ev.notes, (ev.attendees || []).join(" ")].join(" ").toLowerCase();
                    if (haystack.indexOf(query) === -1) return false;
                }
                return true;
            });
            return {
                ok: true,
                plugin: "feishu_calendar",
                mode: amber.settings.get("mode") || "local",
                calendar_id: amber.settings.get("default_calendar_id") || "primary",
                date: targetDate || "all",
                count: filtered.length,
                events: filtered
            };
        }

        function freebusy(input) {
            const date = (input && input.date) ? String(input.date).trim() : amber.settings.get("today");
            const duration = (input && input.duration_minutes) ? Number(input.duration_minutes) : 45;
            const startHour = Number(amber.settings.get("workday_start_hour") || "9");
            const endHour = Number(amber.settings.get("workday_end_hour") || "18");
            const dayEvents = _loadEvents().filter(function(ev) {
                return String(ev.startTime || "").indexOf(date) === 0;
            });

            function toMinutes(timeStr) {
                const part = String(timeStr).slice(11, 16);
                const pieces = part.split(":");
                if (pieces.length !== 2) return 0;
                return Number(pieces[0]) * 60 + Number(pieces[1]);
            }
            function toHHMM(mins) {
                const h = String(Math.floor(mins / 60)).padStart(2, "0");
                const m = String(mins % 60).padStart(2, "0");
                return h + ":" + m;
            }

            const busy = dayEvents.map(function(ev) {
                return { start: toMinutes(ev.startTime), end: toMinutes(ev.endTime), summary: ev.summary };
            }).sort(function(a, b) { return a.start - b.start; });

            const freeSlots = [];
            let cursor = startHour * 60;
            const dayEnd = endHour * 60;
            for (let i = 0; i < busy.length; i++) {
                if (busy[i].start - cursor >= duration) {
                    freeSlots.push({
                        start_time: date + " " + toHHMM(cursor),
                        end_time: date + " " + toHHMM(busy[i].start),
                        available_minutes: busy[i].start - cursor
                    });
                }
                if (busy[i].end > cursor) cursor = busy[i].end;
            }
            if (dayEnd - cursor >= duration) {
                freeSlots.push({
                    start_time: date + " " + toHHMM(cursor),
                    end_time: date + " " + toHHMM(dayEnd),
                    available_minutes: dayEnd - cursor
                });
            }

            return {
                ok: true,
                plugin: "feishu_calendar",
                date: date,
                busy_count: busy.length,
                busy_events: dayEvents.map(function(e) { return { summary: e.summary, start_time: e.startTime, end_time: e.endTime }; }),
                free_slots: freeSlots
            };
        }

        function createEvent(input) {
            const events = _loadEvents();
            const created = {
                id: "evt_" + Math.random().toString(36).slice(2, 10),
                summary: String(input.summary || "新日程"),
                startTime: String(input.start_time || ""),
                endTime: String(input.end_time || ""),
                location: String(input.location || "飞书会议"),
                attendees: Array.isArray(input.attendees) ? input.attendees : [],
                notes: String(input.notes || ""),
                source: amber.settings.get("mode") || "local"
            };
            events.push(created);
            amber.storage.set("events", events);
            return { ok: true, plugin: "feishu_calendar", event: created, total_events: events.length };
        }
        """

        return DesktopInstalledPlugin(
            manifest: manifest,
            scriptSource: script,
            enabled: enabled,
            isBuiltIn: true,
            lastSyncStatus: nil
        )
    }

    nonisolated private static func encodeJSONObject(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
