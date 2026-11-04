import Foundation

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
        case .knowledge: "管理本地技能（SKILL.md）、长期记忆库与形象人设设定。"
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
    var entry: String? = nil

    enum CodingKeys: String, CodingKey { case id, title, symbol, subtitle, entry, html }

    init(id: String, title: String, symbol: String = "calendar", subtitle: String = "", entry: String? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.entry = entry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "calendar"
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        entry = try container.decodeIfPresent(String.self, forKey: .entry)
            ?? (try container.decodeIfPresent(String.self, forKey: .html))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(symbol, forKey: .symbol)
        if !subtitle.isEmpty { try container.encode(subtitle, forKey: .subtitle) }
        try container.encodeIfPresent(entry, forKey: .entry)
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
    var views: [DesktopPluginViewManifest]

    enum CodingKeys: String, CodingKey {
        case inspectorCards, workspaceViews, commands, views
    }

    init(
        inspectorCards: [DesktopPluginInspectorCardManifest] = [],
        workspaceViews: [DesktopPluginWorkspaceViewManifest] = [],
        commands: [DesktopPluginCommandManifest] = [],
        views: [DesktopPluginViewManifest] = []
    ) {
        self.inspectorCards = inspectorCards
        self.workspaceViews = workspaceViews
        self.commands = commands
        self.views = views
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inspectorCards = try container.decodeIfPresent([DesktopPluginInspectorCardManifest].self, forKey: .inspectorCards) ?? []
        workspaceViews = try container.decodeIfPresent([DesktopPluginWorkspaceViewManifest].self, forKey: .workspaceViews) ?? []
        commands = try container.decodeIfPresent([DesktopPluginCommandManifest].self, forKey: .commands) ?? []
        views = try container.decodeIfPresent([DesktopPluginViewManifest].self, forKey: .views) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !inspectorCards.isEmpty { try container.encode(inspectorCards, forKey: .inspectorCards) }
        if !workspaceViews.isEmpty { try container.encode(workspaceViews, forKey: .workspaceViews) }
        if !commands.isEmpty { try container.encode(commands, forKey: .commands) }
        if !views.isEmpty { try container.encode(views, forKey: .views) }
    }
}
