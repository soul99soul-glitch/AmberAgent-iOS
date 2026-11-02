import Foundation

// MARK: - v3 View Slots & Manifest Extensions

enum DesktopPluginViewSlot: String, Codable, Equatable, CaseIterable, Sendable {
    case workspace = "workspace"
    case leftSidebar = "left_sidebar"
    case rightSidebar = "right_sidebar"
    case inspector = "inspector"
    case modal = "modal"
    case settings = "settings"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch raw {
        case "workspace", "main", "tab":
            self = .workspace
        case "left_sidebar", "leftSidebar", "sidebar_left":
            self = .leftSidebar
        case "right_sidebar", "rightSidebar", "sidebar_right":
            self = .rightSidebar
        case "inspector":
            self = .inspector
        case "modal", "dialog":
            self = .modal
        case "settings", "preferences":
            self = .settings
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "未知的插件视图槽位：\(raw)"
            )
        }
    }
}

struct DesktopPluginViewManifest: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    var slot: DesktopPluginViewSlot = .workspace
    var symbol: String = "rectangle.split.3x1"
    var subtitle: String = ""
    var entry: String = "index.html"
    var width: Double? = nil
    var height: Double? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, slot, symbol, subtitle, entry, html, width, height
    }

    init(
        id: String,
        title: String,
        slot: DesktopPluginViewSlot = .workspace,
        symbol: String = "rectangle.split.3x1",
        subtitle: String = "",
        entry: String = "index.html",
        width: Double? = nil,
        height: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.slot = slot
        self.symbol = symbol
        self.subtitle = subtitle
        self.entry = entry
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        slot = try container.decodeIfPresent(DesktopPluginViewSlot.self, forKey: .slot) ?? .workspace
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "rectangle.split.3x1"
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        if let explicitEntry = try container.decodeIfPresent(String.self, forKey: .entry), !explicitEntry.isEmpty {
            entry = explicitEntry
        } else if let html = try container.decodeIfPresent(String.self, forKey: .html), !html.isEmpty {
            entry = html
        } else {
            entry = "index.html"
        }
        width = try container.decodeIfPresent(Double.self, forKey: .width)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(slot, forKey: .slot)
        try container.encode(symbol, forKey: .symbol)
        if !subtitle.isEmpty { try container.encode(subtitle, forKey: .subtitle) }
        try container.encode(entry, forKey: .entry)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
    }
}

struct DesktopPluginCustomViewEntry: Equatable, Identifiable, Sendable {
    var id: String { "\(pluginID):\(viewID)" }
    let pluginID: String
    let pluginName: String
    let viewID: String
    let title: String
    let slot: DesktopPluginViewSlot
    let symbol: String
    let subtitle: String
    let entryPath: String
    let width: Double?
    let height: Double?
}

// MARK: - Bridge Error Codes

/// Stable error codes every rejected `amber.*` call carries to plugin JavaScript as `error.code`.
enum DesktopPluginBridgeErrorCode: String, CaseIterable, Sendable {
    case permissionDenied = "E_PERMISSION_DENIED"
    case invalidArgument = "E_INVALID_ARGUMENT"
    case notFound = "E_NOT_FOUND"
    case executionFailed = "E_EXECUTION_FAILED"

    /// Classifies a host error. Permission failures are checked first so an unapproved or undeclared capability is
    /// never reported as a generic failure.
    static func classify(_ error: Error) -> DesktopPluginBridgeErrorCode {
        let message = error.localizedDescription
        if message.contains("未声明权限") || message.contains("尚未获得用户批准") || message.contains("禁止调用")
            || message.contains("禁止发起") || message.contains("仅允许发起") || message.contains("禁止通过脚本") {
            return .permissionDenied
        }
        if message.contains("不存在") || message.contains("找不到") || message.contains("未找到") {
            return .notFound
        }
        if message.contains("未授权") || message.contains("无效") || message.contains("仅允许访问 HTTPS")
            || message.contains("需要") || message.contains("须为") || message.contains("未知的") || message.contains("..")
            || message.contains("符号链接") || message.contains("未声明配置项") || message.contains("绝对路径") {
            return .invalidArgument
        }
        return .executionFailed
    }
}

// MARK: - Dynamic Runtime State Models (Tools, Commands, UI Modals & Notices)

struct DesktopPluginDynamicTool: Equatable, Sendable {
    let pluginID: String
    let manifest: DesktopPluginToolManifest
    let writesWorkspace: Bool
    let sendsHTTP: Bool
}

struct DesktopPluginModalPresentation: Equatable, Identifiable, Sendable {
    var id: String { "\(pluginID):\(viewID)" }
    let pluginID: String
    let pluginName: String
    let viewID: String
    let title: String
    let entryPath: String
    let width: Double
    let height: Double
    let stateJSON: String
}

struct DesktopPluginNoticeBanner: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case info, success, warning, error
    }
    let id: UUID
    let pluginID: String
    let pluginName: String
    let message: String
    let kind: Kind
    let createdAt: Date
}

struct DesktopPluginConversationSnapshot: Codable, Equatable, Sendable {
    struct MessageItem: Codable, Equatable, Sendable {
        let id: String
        let role: String
        let content: String
    }
    let id: String
    let title: String
    let messageCount: Int
    let messages: [MessageItem]
}

// MARK: - Plugin Manifest Parsing & Validation (v1 / v2 / v3)

struct DesktopPluginManifest: Codable, Equatable, Identifiable, Sendable {
    static let schemaV3 = "amber.plugin.v3"
    static let schemaV2 = "amber.plugin.v2"
    static let schemaV1 = "amber.plugin.v1"

    var schema: String = DesktopPluginManifest.schemaV2
    var manifestVersion: Int? = nil
    let id: String
    let name: String
    let version: String
    let description: String
    var icon: String = "puzzlepiece.extension"
    var main: String = "main.js"
    var devReload: Bool = false
    var permissions: [String] = []
    var capabilities: DesktopPluginCapabilities = .init()
    var settingsSchema: [DesktopPluginSettingField] = []
    var tools: [DesktopPluginToolManifest] = []
    var ui: DesktopPluginUIManifest = .init()

    var isV3: Bool {
        schema == Self.schemaV3
            || manifestVersion == 3
            || (version.hasPrefix("3.") && (!permissions.isEmpty || !ui.views.isEmpty || devReload))
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case manifestVersion = "manifest_version"
        case apiVersion = "api_version"
        case id, name, version, description, icon, main
        case devReload = "dev_reload"
        case devReloadCamel = "devReload"
        case permissions, capabilities
        case settingsSchema = "settings_schema"
        case tools, ui
    }

    init(
        schema: String = DesktopPluginManifest.schemaV2,
        manifestVersion: Int? = nil,
        id: String,
        name: String,
        version: String,
        description: String,
        icon: String = "puzzlepiece.extension",
        main: String = "main.js",
        devReload: Bool = false,
        permissions: [String] = [],
        capabilities: DesktopPluginCapabilities = .init(),
        settingsSchema: [DesktopPluginSettingField] = [],
        tools: [DesktopPluginToolManifest] = [],
        ui: DesktopPluginUIManifest = .init()
    ) {
        self.schema = schema
        self.manifestVersion = manifestVersion
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.icon = icon
        self.main = main
        self.devReload = devReload
        self.permissions = permissions
        self.capabilities = capabilities
        self.settingsSchema = settingsSchema
        self.tools = tools
        self.ui = ui
        mergePermissionsIntoCapabilities()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedManifestVer = try container.decodeIfPresent(Int.self, forKey: .manifestVersion)
            ?? (try container.decodeIfPresent(Int.self, forKey: .apiVersion))
        manifestVersion = decodedManifestVer
        if let explicitSchema = try container.decodeIfPresent(String.self, forKey: .schema) {
            schema = explicitSchema
        } else if decodedManifestVer == 3 {
            schema = Self.schemaV3
        } else {
            schema = Self.schemaV2
        }
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        description = try container.decode(String.self, forKey: .description)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "puzzlepiece.extension"
        main = try container.decodeIfPresent(String.self, forKey: .main) ?? "main.js"
        devReload = try container.decodeIfPresent(Bool.self, forKey: .devReload)
            ?? (try container.decodeIfPresent(Bool.self, forKey: .devReloadCamel))
            ?? false
        permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
        capabilities = try container.decodeIfPresent(DesktopPluginCapabilities.self, forKey: .capabilities) ?? .init()
        settingsSchema = try container.decodeIfPresent([DesktopPluginSettingField].self, forKey: .settingsSchema) ?? []
        tools = try container.decodeIfPresent([DesktopPluginToolManifest].self, forKey: .tools) ?? []
        ui = try container.decodeIfPresent(DesktopPluginUIManifest.self, forKey: .ui) ?? .init()
        mergePermissionsIntoCapabilities()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encodeIfPresent(manifestVersion, forKey: .manifestVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(description, forKey: .description)
        try container.encode(icon, forKey: .icon)
        if main != "main.js" { try container.encode(main, forKey: .main) }
        if devReload { try container.encode(devReload, forKey: .devReload) }
        if !permissions.isEmpty { try container.encode(permissions, forKey: .permissions) }
        try container.encode(capabilities, forKey: .capabilities)
        if !settingsSchema.isEmpty { try container.encode(settingsSchema, forKey: .settingsSchema) }
        if !tools.isEmpty { try container.encode(tools, forKey: .tools) }
        try container.encode(ui, forKey: .ui)
    }

    private mutating func mergePermissionsIntoCapabilities() {
        for raw in permissions {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("http:") {
                let domain = String(token.dropFirst("http:".count)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !domain.isEmpty && !capabilities.networkDomains.contains(where: { $0.lowercased() == domain }) {
                    capabilities.networkDomains.append(domain)
                }
            } else if token.hasPrefix("workspace.read:") {
                let prefix = String(token.dropFirst("workspace.read:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty && !capabilities.workspaceReadPrefixes.contains(prefix) {
                    capabilities.workspaceReadPrefixes.append(prefix)
                }
            } else if token.hasPrefix("workspace.write:") {
                let prefix = String(token.dropFirst("workspace.write:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty && !capabilities.workspaceWritePrefixes.contains(prefix) {
                    capabilities.workspaceWritePrefixes.append(prefix)
                }
            }
        }
    }

    func validated() throws {
        guard schema == Self.schemaV3 || schema == Self.schemaV2 || schema == Self.schemaV1 else {
            throw DesktopRuntimeError.message("插件 schema 须为 amber.plugin.v3、amber.plugin.v2 或 amber.plugin.v1。")
        }
        guard Self.isValidPluginID(id, minLength: 2) else {
            throw DesktopRuntimeError.message("插件 id 无效：\(id)（须为 2–32 位小写字母、数字、下划线或连字符）。")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopRuntimeError.message("插件 name、version 与 description 不能为空。")
        }
        guard Self.isValidRelativeAssetPath(main) else {
            throw DesktopRuntimeError.message("插件入口脚本路径无效：\(main)。")
        }
        for perm in permissions {
            try DesktopPluginPermissionCatalog.validateToken(perm)
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
        var seenViews = Set<String>()
        for view in ui.views {
            guard Self.isValidPluginID(view.id, minLength: 1), seenViews.insert(view.id).inserted else {
                throw DesktopRuntimeError.message("插件视图 ID 无效或重复：\(view.id)。")
            }
            guard !view.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DesktopRuntimeError.message("插件视图 \(view.id) 的标题不能为空。")
            }
            guard Self.isValidRelativeAssetPath(view.entry) else {
                throw DesktopRuntimeError.message("插件视图 \(view.id) 的入口资源路径无效：\(view.entry)。")
            }
        }
        for wv in ui.workspaceViews {
            if let entry = wv.entry, !entry.isEmpty {
                guard Self.isValidRelativeAssetPath(entry) else {
                    throw DesktopRuntimeError.message("插件工作区视图 \(wv.id) 的入口资源路径无效：\(entry)。")
                }
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

    static func isValidPluginID(_ value: String, minLength: Int) -> Bool {
        guard value.count >= minLength && value.count <= 32 else { return false }
        return value.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) == value.startIndex..<value.endIndex
    }

    static func isValidRelativeAssetPath(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(":"),
              !trimmed.contains("\0") else {
            return false
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
