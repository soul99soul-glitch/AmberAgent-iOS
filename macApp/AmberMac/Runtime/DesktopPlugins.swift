import CryptoKit
import Foundation
import JavaScriptCore
import Observation


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
    var entryPath: String? = nil

    var isCustomWebView: Bool {
        !(entryPath ?? "").isEmpty
    }
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
    static let disabledCoreKey = "desktop.plugins.disabledCore.v1"
    static let disabledPluginsKey = "desktop.plugins.disabledExtensions.v1"
    static let settingsPrefix = "desktop.plugins.settings.v1."

    var disabledCorePlugins: Set<DesktopCorePlugin> = []
    var plugins: [DesktopInstalledPlugin] = []
    var calendarEvents: [DesktopPluginEventItem] = []
    var botActivities: [DesktopPluginBotActivityItem] = []
    var inspectorSnapshots: [DesktopInspectorCardSnapshot] = []
    var activeWorkspaceViews: [DesktopPluginWorkspaceViewEntry] = []
    var activeCustomViews: [DesktopPluginCustomViewEntry] = []
    var activeSlashCommands: [DesktopPluginSlashCommandEntry] = []
    var activeToolDeclarations: [DesktopToolDeclaration] = []
    var todayFreeSlots: [DesktopPluginFreeSlot] = []
    var todayDateString: String = ""
    var tomorrowDateString: String = ""
    var hasFeishuCalDAVCredentials: Bool = false
    var hasFeishuBotCredentials: Bool = false
    var hasFeishuRemoteCredentials: Bool = false
    var loadError: String?
    var isSyncingPluginID: String?
    var activeModal: DesktopPluginModalPresentation?
    var latestNotice: DesktopPluginNoticeBanner?
    var lastInsertedComposerText: String?
    var pluginReloadRevisions: [String: Int] = [:]
    var isDarkThemeActive: Bool = false

    @ObservationIgnored let directory: URL
    @ObservationIgnored var workspaceDirectory: URL
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let credentials: any DesktopCredentialStore
    @ObservationIgnored let httpTransport: any DesktopPluginHTTPTransport
    @ObservationIgnored let calendarService: any DesktopCalendarService
    @ObservationIgnored let referenceDateProvider: @Sendable () -> Date
    @ObservationIgnored var settingsCache: [String: [String: String]] = [:]
    @ObservationIgnored var inFlightIdempotencyWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored var runtimeHosts: [String: DesktopPluginRuntimeHost] = [:]
    @ObservationIgnored var webViewCoordinators: [String: DesktopPluginWebViewCoordinator] = [:]
    @ObservationIgnored var conversationSnapshotProvider: (() -> DesktopPluginConversationSnapshot)?
    @ObservationIgnored var onInsertToComposerRequest: ((String) -> Void)?
    @ObservationIgnored var onOpenPluginViewRequest: ((String, String) -> Void)?
    @ObservationIgnored var onConfirmRequest: ((String, String) async -> Bool)?
    @ObservationIgnored var onStateChanged: (() -> Void)?

    nonisolated static let injectedSandboxAPIs: Set<String> = [
        "amber.settings.get",
        "amber.settings.set",
        "amber.settings.getAll",
        "amber.storage.get",
        "amber.storage.set",
        "amber.storage.remove",
        "amber.storage.keys",
        "amber.storage.all",
        "amber.http.fetch",
        "amber.workspace.read",
        "amber.workspace.write",
        "amber.workspace.list",
        "amber.workspace.watch",
        "amber.commands.register",
        "amber.commands.list",
        "amber.events.on",
        "amber.events.off",
        "amber.events.emit",
        "amber.ui.notice",
        "amber.ui.confirm",
        "amber.ui.openView",
        "amber.ui.openModal",
        "amber.ui.closeModal",
        "amber.agent.registerTool",
        "amber.agent.getConversation",
        "amber.agent.insertToComposer"
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
                let scriptURL = folder.appendingPathComponent(manifest.main)
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

            let loadedIDs = Set(loaded.map(\.id))
            for (hostID, host) in runtimeHosts where !loadedIDs.contains(hostID) {
                host.stop()
                runtimeHosts.removeValue(forKey: hostID)
            }

            settingsCache.removeAll()
            if plugins != loaded { plugins = loaded }
            loadCalendarEventsFromStorage()
            loadBotActivitiesFromStorage()

            for plugin in plugins where !plugin.isBuiltIn {
                if plugin.enabled && plugin.manifest.isV3 {
                    let host = runtimeHosts[plugin.id] ?? DesktopPluginRuntimeHost(pluginID: plugin.id, store: self)
                    runtimeHosts[plugin.id] = host
                    try? host.start(plugin: plugin, workspaceDirectory: workspaceDirectory)
                    if plugin.manifest.devReload {
                        let folder = directory.appendingPathComponent(plugin.id, isDirectory: true)
                        host.startDirectoryHotReloadWatcher(folderURL: folder) { [weak self] in
                            try? self?.reloadPlugin(id: plugin.id)
                        }
                    }
                } else if let host = runtimeHosts[plugin.id] {
                    host.stop()
                }
            }

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
        let plugin = updated[index]
        if !plugin.isBuiltIn && plugin.manifest.isV3 {
            if enabled {
                let host = runtimeHosts[id] ?? DesktopPluginRuntimeHost(pluginID: id, store: self)
                runtimeHosts[id] = host
                try? host.start(plugin: plugin, workspaceDirectory: workspaceDirectory)
            } else if let host = runtimeHosts[id] {
                host.stop()
            }
        }
        rebuildProjections()
    }

    @discardableResult
    func importPlugin(from url: URL, approvePermissions: Bool = true) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw DesktopRuntimeError.message("所选插件文件或目录不存在。")
        }

        let manifestData: Data
        let scriptSource: String
        let packageRootURL: URL?
        if isDir.boolValue {
            let manifestURL = url.appendingPathComponent("plugin.json")
            guard fm.fileExists(atPath: manifestURL.path) else {
                throw DesktopRuntimeError.message("插件目录缺少 plugin.json。")
            }
            manifestData = try Data(contentsOf: manifestURL)
            packageRootURL = url
            scriptSource = ""
        } else {
            manifestData = try Data(contentsOf: url)
            packageRootURL = nil
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

        if let packageRootURL,
           packageRootURL.standardizedFileURL.path != targetFolder.standardizedFileURL.path {
            try Self.copyPluginPackageContents(from: packageRootURL, to: targetFolder)
        } else if !scriptSource.isEmpty {
            try Data(scriptSource.utf8).write(to: targetFolder.appendingPathComponent(manifest.main), options: .atomic)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: targetFolder.appendingPathComponent("plugin.json"), options: .atomic)

        if approvePermissions {
            let canonical = DesktopPluginPermissionCatalog.canonicalPermissions(for: manifest)
            defaults.set(canonical.sorted(), forKey: Self.approvedPermissionsPrefix + manifest.id)
        } else {
            defaults.set([String](), forKey: Self.approvedPermissionsPrefix + manifest.id)
        }

        reload()
        return manifest.id
    }

    static func copyPluginPackageContents(from sourceDir: URL, to targetDir: URL) throws {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            let name = item.lastPathComponent
            if name == "storage.json" && fm.fileExists(atPath: targetDir.appendingPathComponent(name).path) {
                continue
            }
            let dest = targetDir.appendingPathComponent(name, isDirectory: values?.isDirectory == true)
            if values?.isDirectory == true {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                try copyPluginPackageContents(from: item, to: dest)
            } else {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: item, to: dest)
            }
        }
    }

    func removePlugin(id: String) throws {
        guard let plugin = plugins.first(where: { $0.id == id }) else {
            throw DesktopRuntimeError.message("找不到插件：\(id)。")
        }
        guard !plugin.isBuiltIn else {
            throw DesktopRuntimeError.message("内置插件不能删除，可通过开关停用。")
        }
        if let host = runtimeHosts.removeValue(forKey: id) {
            host.stop()
        }
        let targetFolder = directory.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: targetFolder.path) {
            try FileManager.default.removeItem(at: targetFolder)
        }
        for field in plugin.manifest.settingsSchema where field.kind == .secret {
            try? credentials.delete(id: secretKeyUUID(pluginID: id, key: field.key))
        }
        defaults.removeObject(forKey: Self.settingsPrefix + id)
        defaults.removeObject(forKey: Self.approvedPermissionsPrefix + id)
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

    func secretKeyUUID(pluginID: String, key: String) -> UUID {
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

    func storageFileURL(pluginID: String) -> URL {
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


    func evaluateInspectorCardSnapshot(
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
        var nextCustomViews: [DesktopPluginCustomViewEntry] = []
        var nextCommands: [DesktopPluginSlashCommandEntry] = []
        var nextCards: [DesktopInspectorCardSnapshot] = []

        var nextEffects: [String: DesktopToolEffect] = [:]
        for plugin in plugins where plugin.enabled {
            let canRegisterTools = !plugin.manifest.isV3 || hasPermission(plugin: plugin, permission: "agent.tools")
            if canRegisterTools {
                var combinedTools: [DesktopPluginToolManifest] = plugin.manifest.tools
                if let host = runtimeHosts[plugin.id] {
                    for dynamic in host.dynamicTools.values.sorted(by: { $0.manifest.name < $1.manifest.name }) {
                        if let existingIdx = combinedTools.firstIndex(where: { $0.name == dynamic.manifest.name }) {
                            combinedTools[existingIdx] = dynamic.manifest
                        } else {
                            combinedTools.append(dynamic.manifest)
                        }
                    }
                }
                for tool in combinedTools {
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
                    badgeCount: badge,
                    entryPath: view.entry
                ))
            }

            let canRenderCustomViews = !plugin.manifest.isV3 || hasPermission(plugin: plugin, permission: "ui.views")
            if canRenderCustomViews {
                var allCustomViews = plugin.manifest.ui.views
                if let host = runtimeHosts[plugin.id] {
                    for dv in host.dynamicViews.values.sorted(by: { $0.id < $1.id }) {
                        if !allCustomViews.contains(where: { $0.id == dv.id }) {
                            allCustomViews.append(dv)
                        }
                    }
                }
                for customView in allCustomViews {
                    nextCustomViews.append(DesktopPluginCustomViewEntry(
                        pluginID: plugin.id,
                        pluginName: plugin.manifest.name,
                        viewID: customView.id,
                        title: customView.title,
                        slot: customView.slot,
                        symbol: customView.symbol,
                        subtitle: customView.subtitle,
                        entryPath: customView.entry,
                        width: customView.width,
                        height: customView.height
                    ))
                    if customView.slot == .workspace,
                       !nextViews.contains(where: { $0.pluginID == plugin.id && $0.viewID == customView.id }) {
                        let badge = Int(pluginStorage["badge:\(customView.id)"] ?? pluginStorage["badge_count"] ?? "") ?? fallbackCardItemsCount
                        nextViews.append(DesktopPluginWorkspaceViewEntry(
                            pluginID: plugin.id,
                            pluginName: plugin.manifest.name,
                            viewID: customView.id,
                            title: customView.title,
                            symbol: customView.symbol,
                            subtitle: customView.subtitle,
                            badgeCount: max(0, badge),
                            entryPath: customView.entry
                        ))
                    }
                }
            }

            let canRegisterCommands = !plugin.manifest.isV3 || hasPermission(plugin: plugin, permission: "commands")
            if canRegisterCommands {
                var allCommands = plugin.manifest.ui.commands
                if let host = runtimeHosts[plugin.id] {
                    for dc in host.dynamicCommands.values.sorted(by: { $0.id < $1.id }) {
                        if let idx = allCommands.firstIndex(where: { $0.id == dc.id }) {
                            allCommands[idx] = dc
                        } else {
                            allCommands.append(dc)
                        }
                    }
                }
                for command in allCommands {
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
        if activeCustomViews != nextCustomViews {
            activeCustomViews = nextCustomViews
            stateChanged = true
        }
        if activeSlashCommands != nextCommands { activeSlashCommands = nextCommands }
        if inspectorSnapshots != nextCards { inspectorSnapshots = nextCards }
        if stateChanged { onStateChanged?() }
    }

}
