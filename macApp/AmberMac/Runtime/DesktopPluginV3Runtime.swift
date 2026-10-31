import AppKit
import Foundation
import JavaScriptCore
import Observation
import WebKit

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

// MARK: - v3 Permission Descriptors & Install / Upgrade Consent

struct DesktopPluginPermissionDescriptor: Equatable, Identifiable, Sendable {
    var id: String { token }
    let token: String
    let title: String
    let summary: String
    let isHighRisk: Bool
    var isNewlyRequested: Bool = false
}

struct DesktopPluginInstallPlan: Equatable, Sendable {
    let manifest: DesktopPluginManifest
    let sourceURL: URL
    let isUpgrade: Bool
    let previousVersion: String?
    let permissions: [DesktopPluginPermissionDescriptor]
    let requiresUserApproval: Bool

    var newlyRequestedPermissions: [DesktopPluginPermissionDescriptor] {
        permissions.filter(\.isNewlyRequested)
    }

    var humanReadableSummaryLines: [String] {
        permissions.map { item in
            let riskTag = item.isHighRisk ? "【高风险】" : ""
            let newTag = item.isNewlyRequested && isUpgrade ? "（升级新增）" : ""
            return "\(riskTag)\(item.title)\(newTag)：\(item.summary)"
        }
    }
}

enum DesktopPluginPermissionCatalog {
    static let basePermissions: Set<String> = [
        "ui.views",
        "storage",
        "workspace.read",
        "workspace.write",
        "agent.tools",
        "commands",
        "events",
        "settings"
    ]

    static func validateToken(_ raw: String) throws {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw DesktopRuntimeError.message("插件权限声明不能为空字符串。")
        }
        if basePermissions.contains(token) { return }
        if token.hasPrefix("http:") {
            let domain = String(token.dropFirst("http:".count)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !domain.isEmpty, !domain.contains("/"), !domain.contains(":"), domain.contains(".") || domain == "localhost" else {
                throw DesktopRuntimeError.message("插件 HTTP 权限域名格式无效：\(raw)（示例：http:api.example.com）。")
            }
            return
        }
        if token.hasPrefix("workspace.read:") || token.hasPrefix("workspace.write:") {
            let parts = token.split(separator: ":", maxSplits: 1)
            let prefix = parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard !prefix.isEmpty, !prefix.hasPrefix("/"), !prefix.contains(".."), !prefix.contains("\\") else {
                throw DesktopRuntimeError.message("插件工作区权限前缀无效：\(raw)。")
            }
            return
        }
        throw DesktopRuntimeError.message("插件声明了未知权限：\(raw)。")
    }

    static func descriptor(for token: String, manifest: DesktopPluginManifest, isNewlyRequested: Bool = false) -> DesktopPluginPermissionDescriptor {
        if token == "ui.views" {
            return DesktopPluginPermissionDescriptor(
                token: token,
                title: "自定义界面视图",
                summary: "在主工作区、侧栏、检查器或模态弹窗中渲染插件自带的受控 WebView 界面（遵循宿主 CSP 策略，禁止访问本机任意文件）。",
                isHighRisk: false,
                isNewlyRequested: isNewlyRequested
            )
        }
        if token == "storage" {
            return DesktopPluginPermissionDescriptor(
                token: token,
                title: "插件私有存储",
                summary: "读写该插件专属的键值存储文件（storage.json），与其他插件和会话数据隔离。",
                isHighRisk: false,
                isNewlyRequested: isNewlyRequested
            )
        }
        if token == "workspace.read" || token.hasPrefix("workspace.read:") {
            let prefixes = manifest.capabilities.workspaceReadPrefixes
            let scopeText = prefixes.isEmpty ? "当前会话工作区" : "当前会话工作区子目录（\(prefixes.joined(separator: "、"))）"
            return DesktopPluginPermissionDescriptor(
                token: token,
                title: "读取工作区文件",
                summary: "读取与列出\(scopeText)内的文件并监听变更，禁止访问工作区以外的系统目录。",
                isHighRisk: false,
                isNewlyRequested: isNewlyRequested
            )
        }
        if token == "workspace.write" || token.hasPrefix("workspace.write:") {
            let prefixes = manifest.capabilities.workspaceWritePrefixes
            let scopeText = prefixes.isEmpty ? "当前会话工作区" : "当前会话工作区子目录（\(prefixes.joined(separator: "、"))）"
            return DesktopPluginPermissionDescriptor(
                token: token,
                title: "写入工作区文件",
                summary: "在\(scopeText)内创建或修改文件。智能体调用写文件工具时需在桌面端批准。",
                isHighRisk: true,
                isNewlyRequested: isNewlyRequested
            )
        }
        if token.hasPrefix("http:") {
            let domain = String(token.dropFirst("http:".count))
            return DesktopPluginPermissionDescriptor(
                token: token,
                title: "访问外部域名 \(domain)",
                summary: "允许向 https://\(domain)（及其子域名）发起受控 HTTPS 请求，超时限制为 20 秒。",
                isHighRisk: true,
                isNewlyRequested: isNewlyRequested
            )
        }
        if token == "agent.tools" {
            let hasWriteTools = manifest.tools.contains { $0.effect == .sideEffect || $0.effect == .idempotent }
                || manifest.permissions.contains("workspace.write")
                || manifest.permissions.contains(where: { $0.hasPrefix("workspace.write:") || $0.hasPrefix("http:") })
            return DesktopPluginPermissionDescriptor(
                token: token,
                title: "注册智能体工具与会话协同",
                summary: "向 Amber 注册插件工具、读取当前会话消息摘要或向输入框填入内容；写操作工具受高风险门禁保护。",
                isHighRisk: hasWriteTools,
                isNewlyRequested: isNewlyRequested
            )
        }
        if token == "commands" {
            return DesktopPluginPermissionDescriptor(
                token: token,
                title: "注册快捷命令",
                summary: "向底部输入框 / 斜杠菜单与 ⌘K 命令面板注册快捷指令。",
                isHighRisk: false,
                isNewlyRequested: isNewlyRequested
            )
        }
        if token == "events" {
            return DesktopPluginPermissionDescriptor(
                token: token,
                title: "监听宿主事件",
                summary: "订阅会话切换、消息到达、工作区文件变更与亮暗色主题变化通知。",
                isHighRisk: false,
                isNewlyRequested: isNewlyRequested
            )
        }
        if token == "settings" {
            return DesktopPluginPermissionDescriptor(
                token: token,
                title: "读写插件配置",
                summary: "读取与更新插件的非敏感配置项（密钥类字段始终加密保存在系统钥匙串中，不暴露给脚本）。",
                isHighRisk: false,
                isNewlyRequested: isNewlyRequested
            )
        }
        return DesktopPluginPermissionDescriptor(
            token: token,
            title: token,
            summary: "申请能力 \(token)。",
            isHighRisk: false,
            isNewlyRequested: isNewlyRequested
        )
    }

    static func canonicalPermissions(for manifest: DesktopPluginManifest) -> [String] {
        var ordered: [String] = []
        func appendUnique(_ token: String) {
            if !ordered.contains(token) { ordered.append(token) }
        }
        for raw in manifest.permissions {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { appendUnique(clean) }
        }
        for domain in manifest.capabilities.networkDomains {
            let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !clean.isEmpty { appendUnique("http:\(clean)") }
        }
        if !manifest.capabilities.workspaceReadPrefixes.isEmpty,
           !ordered.contains("workspace.read"),
           !ordered.contains(where: { $0.hasPrefix("workspace.read:") }) {
            appendUnique("workspace.read")
        }
        if !manifest.capabilities.workspaceWritePrefixes.isEmpty,
           !ordered.contains("workspace.write"),
           !ordered.contains(where: { $0.hasPrefix("workspace.write:") }) {
            appendUnique("workspace.write")
        }
        if !manifest.isV3 {
            appendUnique("storage")
            if !manifest.settingsSchema.isEmpty { appendUnique("settings") }
            if !manifest.tools.isEmpty { appendUnique("agent.tools") }
            if !manifest.ui.commands.isEmpty { appendUnique("commands") }
            if !manifest.ui.workspaceViews.isEmpty || !manifest.ui.inspectorCards.isEmpty {
                appendUnique("ui.views")
            }
        }
        return ordered
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

// MARK: - Persistent Background Plugin JS Runtime Host (v3 Lifecycle + Events + Dynamic Registration)

@MainActor
final class DesktopPluginRuntimeHost {
    let pluginID: String
    private(set) var context: JSContext?
    private weak var store: DesktopPluginStore?
    private(set) var isLoaded = false
    private(set) var onloadCount = 0
    private(set) var onunloadCount = 0
    private(set) var dynamicTools: [String: DesktopPluginDynamicTool] = [:]
    private(set) var dynamicCommands: [String: DesktopPluginCommandManifest] = [:]
    private(set) var dynamicViews: [String: DesktopPluginViewManifest] = [:]
    private(set) var eventListenerCounts: [String: Int] = [:]
    private(set) var watchedWorkspacePrefixes: Set<String> = []
    private var directoryWatcherSource: DispatchSourceFileSystemObject?
    private var directoryFileDescriptor: Int32 = -1
    private var workspaceWatcherSources: [String: DispatchSourceFileSystemObject] = [:]
    /// Effect of the tool currently executing in this runtime (nil outside tool execution).
    private(set) var currentToolEffect: DesktopToolEffect?
    /// Workspace the bridge resolves relative paths against.
    private(set) var currentWorkspaceDirectory: URL?

    init(pluginID: String, store: DesktopPluginStore) {
        self.pluginID = pluginID
        self.store = store
    }

    func start(plugin: DesktopInstalledPlugin, workspaceDirectory: URL) throws {
        stop()
        guard let ctx = JSContext() else {
            throw DesktopRuntimeError.message("无法创建插件 \(plugin.manifest.name) 的常驻 JavaScript 运行时。")
        }
        self.context = ctx
        currentWorkspaceDirectory = workspaceDirectory
        currentToolEffect = nil
        var loadException: String?
        ctx.exceptionHandler = { _, exception in
            loadException = exception?.toString() ?? "未知 JavaScript 异常"
        }

        installBridge(into: ctx, plugin: plugin)
        if !plugin.scriptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ctx.evaluateScript(plugin.scriptSource)
            if let loadException {
                self.context = nil
                throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 主脚本加载失败：\(loadException)")
            }
        }

        if let onloadFn = ctx.objectForKeyedSubscript("onload"), !onloadFn.isUndefined, !onloadFn.isNull {
            _ = onloadFn.call(withArguments: [])
            if let loadException {
                self.context = nil
                throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) onload 执行失败：\(loadException)")
            }
            onloadCount += 1
        }
        isLoaded = true
    }

    func stop() {
        stopWatchers()
        if let ctx = context, isLoaded {
            if let onunloadFn = ctx.objectForKeyedSubscript("onunload"), !onunloadFn.isUndefined, !onunloadFn.isNull {
                _ = onunloadFn.call(withArguments: [])
                onunloadCount += 1
            }
        }
        context = nil
        isLoaded = false
        dynamicTools.removeAll()
        dynamicCommands.removeAll()
        dynamicViews.removeAll()
        eventListenerCounts.removeAll()
        watchedWorkspacePrefixes.removeAll()
    }

    func stopWatchers() {
        directoryWatcherSource?.cancel()
        directoryWatcherSource = nil
        if directoryFileDescriptor >= 0 {
            close(directoryFileDescriptor)
            directoryFileDescriptor = -1
        }
        workspaceWatcherSources.values.forEach { $0.cancel() }
        workspaceWatcherSources.removeAll()
    }

    func startDirectoryHotReloadWatcher(folderURL: URL, onModified: @escaping @MainActor () -> Void) {
        directoryWatcherSource?.cancel()
        if directoryFileDescriptor >= 0 {
            close(directoryFileDescriptor)
            directoryFileDescriptor = -1
        }
        let fd = open(folderURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryFileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler {
            Task { @MainActor in
                onModified()
            }
        }
        source.resume()
        directoryWatcherSource = source
    }

    func emitEvent(name: String, payload: [String: Any]) {
        guard let ctx = context, isLoaded else { return }
        guard let emitFn = ctx.objectForKeyedSubscript("__amberEmitEvent"), !emitFn.isUndefined else { return }
        _ = emitFn.call(withArguments: [name, payload])
    }

    func invokeTool(
        plugin: DesktopInstalledPlugin,
        tool: DesktopPluginToolManifest,
        arguments: [String: Any],
        workspaceDirectory: URL
    ) async throws -> String {
        if !isLoaded || context == nil {
            try start(plugin: plugin, workspaceDirectory: workspaceDirectory)
        }
        guard let ctx = context else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 运行时未就绪。")
        }

        var toolException: String?
        ctx.exceptionHandler = { _, exception in
            toolException = exception?.toString() ?? "未知工具脚本异常"
        }

        // The bridge reads the effect guard and workspace from these properties on every call, so a read-only
        // tool cannot write while it runs, and later event handlers or onload code are not stuck with its guard.
        let previousEffect = currentToolEffect
        let previousWorkspace = currentWorkspaceDirectory
        currentToolEffect = tool.effect
        currentWorkspaceDirectory = workspaceDirectory
        defer {
            currentToolEffect = previousEffect
            currentWorkspaceDirectory = previousWorkspace
        }

        let resultValue: JSValue?
        if let registryExec = ctx.objectForKeyedSubscript("__amberInvokeRegisteredTool"),
           !registryExec.isUndefined,
           let hasDynamic = ctx.objectForKeyedSubscript("__amberHasRegisteredTool")?.call(withArguments: [tool.name]),
           hasDynamic.toBool() {
            resultValue = registryExec.call(withArguments: [tool.name, arguments])
        } else {
            guard let fn = ctx.objectForKeyedSubscript(tool.entry), !fn.isUndefined, !fn.isNull else {
                throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 缺少入口函数 \(tool.entry)。")
            }
            resultValue = fn.call(withArguments: [arguments])
        }

        if let toolException {
            throw DesktopRuntimeError.message("插件工具 \(tool.name) 执行异常：\(toolException)")
        }
        guard let unwrapped = resultValue else {
            throw DesktopRuntimeError.message("插件工具 \(tool.name) 未返回结果。")
        }

        let resolvedJSON = try await resolveJSValueToJSON(unwrapped, in: ctx, toolName: tool.name)
        if let toolException {
            throw DesktopRuntimeError.message("插件工具 \(tool.name) 执行异常：\(toolException)")
        }
        return resolvedJSON
    }

    private static func stringifyJSValue(_ value: JSValue, in ctx: JSContext) -> String {
        if let json = ctx.objectForKeyedSubscript("JSON")?
            .objectForKeyedSubscript("stringify")?
            .call(withArguments: [value])?
            .toString(),
           json != "undefined" {
            return json
        }
        return value.toString() ?? "{}"
    }

    private func resolveJSValueToJSON(_ value: JSValue, in ctx: JSContext, toolName: String) async throws -> String {
        guard value.isObject,
              let thenFn = value.forProperty("then"),
              !thenFn.isUndefined,
              !thenFn.isNull else {
            return Self.stringifyJSValue(value, in: ctx)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var settled = false
            let onFulfilled: @convention(block) (JSValue) -> Void = { resolved in
                guard !settled else { return }
                settled = true
                let serialized = Self.stringifyJSValue(resolved, in: ctx)
                continuation.resume(returning: serialized)
            }
            let onRejected: @convention(block) (JSValue) -> Void = { reason in
                guard !settled else { return }
                settled = true
                let msg = reason.toString() ?? "Promise rejected"
                continuation.resume(throwing: DesktopRuntimeError.message("插件工具 \(toolName) 执行异常：\(msg)"))
            }
            _ = value.invokeMethod("then", withArguments: [
                unsafeBitCast(onFulfilled, to: AnyObject.self),
                unsafeBitCast(onRejected, to: AnyObject.self)
            ])
        }
    }

    private func installBridge(into ctx: JSContext, plugin: DesktopInstalledPlugin) {
        guard let store else { return }
        let pluginID = plugin.id
        let fallbackWorkspace = currentWorkspaceDirectory ?? store.workspaceDirectory

        let dispatchSyncBlock: @convention(block) (String, String, String) -> String = { [weak store, weak self] namespace, method, argsJSON in
            guard let store else { return "__AMBER_ERR__:插件宿主已释放。" }
            let argsData = Data(argsJSON.utf8)
            let args = (try? JSONSerialization.jsonObject(with: argsData) as? [Any]) ?? []
            do {
                let output = try store.performSynchronousBridgeCall(
                    pluginID: pluginID,
                    runtimeHost: self,
                    namespace: namespace,
                    method: method,
                    args: args,
                    workspaceDirectory: self?.currentWorkspaceDirectory ?? fallbackWorkspace,
                    activeToolEffect: self?.currentToolEffect
                )
                return output
            } catch {
                let code = DesktopPluginBridgeErrorCode.classify(error).rawValue
                return "__AMBER_ERR__:\(code):\(error.localizedDescription)"
            }
        }

        ctx.setObject(dispatchSyncBlock, forKeyedSubscript: "__amberDispatchSync" as NSString)

        let bootstrap = DesktopPluginWebViewBridgeScript.backgroundContextBootstrapJS(isV3: plugin.manifest.isV3)
        ctx.evaluateScript(bootstrap)
    }

    func registerDynamicTool(_ tool: DesktopPluginDynamicTool) {
        dynamicTools[tool.manifest.name] = tool
    }

    func registerDynamicCommand(_ command: DesktopPluginCommandManifest) {
        dynamicCommands[command.id] = command
    }

    func registerDynamicView(_ view: DesktopPluginViewManifest) {
        dynamicViews[view.id] = view
    }

    func recordEventSubscription(event: String, delta: Int) {
        let current = eventListenerCounts[event] ?? 0
        eventListenerCounts[event] = max(0, current + delta)
    }

    func addWorkspaceWatch(prefix: String, workspaceDirectory: URL, onChanged: @escaping @MainActor (String) -> Void) {
        watchedWorkspacePrefixes.insert(prefix)
        guard workspaceWatcherSources[prefix] == nil else { return }
        // Watch the prefix directory itself when it exists (DispatchSource is not recursive), else the workspace root.
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var target = workspaceDirectory
        if !trimmed.isEmpty {
            let candidate = workspaceDirectory.appendingPathComponent(trimmed, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                target = candidate
            }
        }
        try? FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        let fd = open(target.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler {
            Task { @MainActor in
                onChanged(prefix)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        workspaceWatcherSources[prefix] = source
    }
}

// MARK: - Amber Theme CSS Token Generator & WebView Client Bridge Bootstrap

enum DesktopPluginThemeCSS {
    static func tokenMap(isDark: Bool) -> [String: String] {
        if isDark {
            return [
                "--amber-paper": "#161512",
                "--amber-paper-side": "#1B1916",
                "--amber-paper-deep": "#22201C",
                "--amber-hover": "#282520",
                "--amber-card": "#1E1C18",
                "--amber-field": "#22201C",
                "--amber-ink": "#F0EDE6",
                "--amber-ink-secondary": "#C6C2B8",
                "--amber-ink-tertiary": "#9E998E",
                "--amber-hairline": "rgba(255, 248, 235, 0.08)",
                "--amber-hairline-strong": "rgba(255, 248, 235, 0.14)",
                "--amber-accent": "#DAA972",
                "--amber-accent-ink": "#ECCB9E",
                "--amber-honey": "rgba(213, 160, 100, 0.22)",
                "--amber-honey-soft": "rgba(213, 160, 100, 0.11)",
                "--amber-honey-edge": "rgba(218, 169, 114, 0.32)",
                "--amber-danger": "#E5736B",
                "--amber-success": "#68C78E",
                "--amber-bg-primary": "#161512",
                "--amber-bg-secondary": "#1B1916",
                "--amber-bg-card": "#1E1C18",
                "--amber-bg-elevated": "#22201C",
                "--amber-text-primary": "#F0EDE6",
                "--amber-text-secondary": "#C6C2B8",
                "--amber-text-muted": "#9E998E",
                "--amber-accent-soft": "rgba(213, 160, 100, 0.11)",
                "--amber-border": "rgba(255, 248, 235, 0.08)",
                "--amber-font-sans": "-apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif",
                "--amber-font-serif": "'Songti SC', 'STSong', serif",
                "--amber-font-mono": "ui-monospace, 'SF Mono', Menlo, monospace",
                "--amber-radius-sm": "6px",
                "--amber-radius-md": "10px",
                "--amber-radius-lg": "14px"
            ]
        } else {
            return [
                "--amber-paper": "#FAF8F3",
                "--amber-paper-side": "#F3F0E8",
                "--amber-paper-deep": "#EFECE3",
                "--amber-hover": "#EAE6DB",
                "--amber-card": "#FFFFFF",
                "--amber-field": "#FFFFFF",
                "--amber-ink": "#191815",
                "--amber-ink-secondary": "#45433D",
                "--amber-ink-tertiary": "#68645C",
                "--amber-hairline": "rgba(25, 24, 21, 0.085)",
                "--amber-hairline-strong": "rgba(25, 24, 21, 0.14)",
                "--amber-accent": "#A65E26",
                "--amber-accent-ink": "#784012",
                "--amber-honey": "rgba(222, 150, 72, 0.24)",
                "--amber-honey-soft": "rgba(222, 150, 72, 0.12)",
                "--amber-honey-edge": "rgba(166, 94, 38, 0.30)",
                "--amber-danger": "#B3261E",
                "--amber-success": "#2A7B4C",
                "--amber-bg-primary": "#FAF8F3",
                "--amber-bg-secondary": "#F3F0E8",
                "--amber-bg-card": "#FFFFFF",
                "--amber-bg-elevated": "#FFFFFF",
                "--amber-text-primary": "#191815",
                "--amber-text-secondary": "#45433D",
                "--amber-text-muted": "#68645C",
                "--amber-accent-soft": "rgba(222, 150, 72, 0.12)",
                "--amber-border": "rgba(25, 24, 21, 0.085)",
                "--amber-font-sans": "-apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif",
                "--amber-font-serif": "'Songti SC', 'STSong', serif",
                "--amber-font-mono": "ui-monospace, 'SF Mono', Menlo, monospace",
                "--amber-radius-sm": "6px",
                "--amber-radius-md": "10px",
                "--amber-radius-lg": "14px"
            ]
        }
    }

    static func stylesheet(isDark: Bool) -> String {
        let tokens = tokenMap(isDark: isDark)
            .sorted { $0.key < $1.key }
            .map { "  \($0.key): \($0.value);" }
            .joined(separator: "\n")
        return """
        :root, :root[data-theme="\(isDark ? "dark" : "light")"] {
          color-scheme: \(isDark ? "dark" : "light");
        \(tokens)
        }
        body {
          background-color: var(--amber-paper);
          color: var(--amber-ink);
          font-family: var(--amber-font-sans);
          margin: 0;
        }
        """
    }

    static func contentSecurityPolicy(allowedDomains: [String]) -> String {
        let cleanDomains = allowedDomains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let httpsOrigins = cleanDomains.flatMap { ["https://\($0)", "https://*.\($0)"] }.joined(separator: " ")
        let connectPart = httpsOrigins.isEmpty ? "'self' amber-plugin:" : "'self' amber-plugin: \(httpsOrigins)"
        let imgPart = httpsOrigins.isEmpty ? "'self' data: blob: amber-plugin:" : "'self' data: blob: amber-plugin: \(httpsOrigins)"
        return "default-src 'self' amber-plugin:; script-src 'self' 'unsafe-inline' amber-plugin:; style-src 'self' 'unsafe-inline' amber-plugin:; img-src \(imgPart); connect-src \(connectPart); font-src 'self' data: amber-plugin:; frame-src 'none'; object-src 'none'; base-uri 'self' amber-plugin:;"
    }
}

enum DesktopPluginWebViewBridgeScript {
    static func backgroundContextBootstrapJS(isV3: Bool) -> String {
        """
        function __amberUnwrap(raw) {
            if (typeof raw === 'string' && raw.indexOf('__AMBER_ERR__:') === 0) {
                const rest = raw.slice('__AMBER_ERR__:'.length);
                const match = /^(E_[A-Z_]+):([\\s\\S]*)$/.exec(rest);
                const err = new Error(match ? match[2] : rest);
                err.code = match ? match[1] : 'E_EXECUTION_FAILED';
                throw err;
            }
            return raw;
        }
        function __amberCall(ns, method, args) {
            const raw = __amberUnwrap(__amberDispatchSync(ns, method, JSON.stringify(args || [])));
            if (!raw || raw === '') return '';
            try { return JSON.parse(raw); } catch (e) { return raw; }
        }
        const __amberToolCallbacks = Object.create(null);
        const __amberCommandCallbacks = Object.create(null);
        const __amberEventListeners = Object.create(null);

        function __amberHasRegisteredTool(name) {
            return typeof __amberToolCallbacks[name] === 'function';
        }
        function __amberInvokeRegisteredTool(name, input) {
            const fn = __amberToolCallbacks[name];
            if (typeof fn !== 'function') throw new Error('未找到动态注册的工具函数：' + name);
            return fn(input);
        }
        function __amberEmitEvent(event, payload) {
            const list = __amberEventListeners[event] || [];
            for (let i = 0; i < list.length; i++) {
                try { list[i](payload); } catch (e) {}
            }
        }

        const amber = Object.freeze({
            settings: Object.freeze({
                get: function(key) { return __amberCall('settings', 'get', [String(key)]); },
                set: function(key, val) { return __amberCall('settings', 'set', [String(key), val]); },
                getAll: function() { return __amberCall('settings', 'getAll', []); }
            }),
            storage: Object.freeze({
                get: function(key) { return __amberCall('storage', 'get', [String(key)]); },
                set: function(key, val) { return __amberCall('storage', 'set', [String(key), typeof val === 'string' ? val : JSON.stringify(val)]); },
                remove: function(key) { return __amberCall('storage', 'remove', [String(key)]); },
                keys: function() { return __amberCall('storage', 'keys', []); },
                all: function() { return __amberCall('storage', 'all', []); }
            }),
            http: Object.freeze({
                fetch: function(url, options) {
                    return __amberCall('http', 'fetch', [String(url), options == null ? {} : options]);
                }
            }),
            workspace: Object.freeze({
                read: function(path) { return __amberCall('workspace', 'read', [String(path)]); },
                write: function(path, content) {
                    return __amberCall('workspace', 'write', [String(path), typeof content === 'string' ? content : JSON.stringify(content)]);
                },
                list: function(path) { return __amberCall('workspace', 'list', [path == null ? '' : String(path)]); },
                watch: function(prefix, callback) {
                    const p = prefix == null ? '' : String(prefix);
                    __amberCall('workspace', 'watch', [p]);
                    const listener = typeof callback === 'function' ? function(payload) {
                        const path = payload && typeof payload.path === 'string' ? payload.path : '';
                        if (!p || !path || path === p || path.indexOf(p.replace(/\\/+$/, '') + '/') === 0 || payload.prefix === p) {
                            callback(payload);
                        }
                    } : null;
                    if (listener) {
                        if (!__amberEventListeners['workspace:changed']) __amberEventListeners['workspace:changed'] = [];
                        __amberEventListeners['workspace:changed'].push(listener);
                    }
                    return function() {
                        if (!listener || !__amberEventListeners['workspace:changed']) return;
                        __amberEventListeners['workspace:changed'] = __amberEventListeners['workspace:changed'].filter(function(h) { return h !== listener; });
                    };
                }
            }),
            commands: Object.freeze({
                register: function(cmd) {
                    if (!cmd || !cmd.id) throw new Error('commands.register 需要提供 id');
                    if (typeof cmd.callback === 'function') {
                        __amberCommandCallbacks[cmd.id] = cmd.callback;
                    }
                    return __amberCall('commands', 'register', [cmd]);
                },
                list: function() { return __amberCall('commands', 'list', []); }
            }),
            events: Object.freeze({
                on: function(event, handler) {
                    const ev = String(event);
                    __amberCall('events', 'on', [ev]);
                    if (!__amberEventListeners[ev]) __amberEventListeners[ev] = [];
                    if (typeof handler === 'function') __amberEventListeners[ev].push(handler);
                    return function() { amber.events.off(ev, handler); };
                },
                off: function(event, handler) {
                    const ev = String(event);
                    __amberCall('events', 'off', [ev]);
                    if (!__amberEventListeners[ev]) return true;
                    __amberEventListeners[ev] = __amberEventListeners[ev].filter(function(h) { return h !== handler; });
                    return true;
                },
                emit: function(event, payload) {
                    // The host fans the event out to this runtime and every mounted view, so it is not delivered locally twice.
                    return __amberCall('events', 'emit', [String(event), payload == null ? {} : payload]);
                }
            }),
            ui: Object.freeze({
                notice: function(message, kind) { return __amberCall('ui', 'notice', [String(message), kind || 'info']); },
                confirm: function(options) { return __amberCall('ui', 'confirm', [options == null ? {} : options]); },
                openView: function(viewId, state) { return __amberCall('ui', 'openView', [String(viewId), state == null ? {} : state]); },
                openModal: function(viewId, options) { return __amberCall('ui', 'openModal', [String(viewId), options == null ? {} : options]); },
                closeModal: function() { return __amberCall('ui', 'closeModal', []); }
            }),
            agent: Object.freeze({
                registerTool: function(def) {
                    if (!def || !def.name) throw new Error('agent.registerTool 需要提供 name');
                    const run = typeof def.execute === 'function' ? def.execute : def.handler;
                    if (typeof run !== 'function') throw new Error('agent.registerTool 需要提供 execute(input) 函数');
                    __amberToolCallbacks[def.name] = run;
                    return __amberCall('agent', 'registerTool', [{
                        name: def.name,
                        description: def.description || def.name,
                        effect: def.effect || 'sideEffect',
                        entry: def.entry || def.name,
                        inputSchema: def.inputSchema || def.input_schema || { type: 'object', properties: {}, additionalProperties: false },
                        writesWorkspace: Boolean(def.writesWorkspace),
                        sendsHTTP: Boolean(def.sendsHTTP)
                    }]);
                },
                getConversation: function() { return __amberCall('agent', 'getConversation', []); },
                insertToComposer: function(text) { return __amberCall('agent', 'insertToComposer', [String(text)]); }
            })
        });
        globalThis.window = globalThis.window || globalThis;
        globalThis.window.amber = amber;
        """
    }

    static func webViewBootstrapJS(pluginID: String, viewID: String, isDark: Bool) -> String {
        let css = DesktopPluginThemeCSS.stylesheet(isDark: isDark)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
        return """
        (function() {
            const __pending = Object.create(null);
            const __listeners = Object.create(null);
            let __seq = 0;

            function applyTheme(theme, cssText) {
                if (document.documentElement) {
                    document.documentElement.dataset.theme = theme;
                }
                let styleEl = document.getElementById('amber-theme-tokens');
                if (!styleEl && document.head) {
                    styleEl = document.createElement('style');
                    styleEl.id = 'amber-theme-tokens';
                    document.head.prepend(styleEl);
                }
                if (styleEl && cssText) {
                    styleEl.textContent = cssText;
                }
            }

            document.addEventListener('DOMContentLoaded', function() {
                applyTheme('\(isDark ? "dark" : "light")', `\(css)`);
            });
            applyTheme('\(isDark ? "dark" : "light")', `\(css)`);

            window.__amberBridgeResolve = function(requestId, result) {
                const entry = __pending[requestId];
                if (!entry) return;
                delete __pending[requestId];
                entry.resolve(result);
            };
            window.__amberBridgeReject = function(requestId, errorMessage, code) {
                const entry = __pending[requestId];
                if (!entry) return;
                delete __pending[requestId];
                const err = new Error(String(errorMessage || 'Amber Bridge RPC Error'));
                err.code = code || 'E_EXECUTION_FAILED';
                entry.reject(err);
            };
            window.__amberBridgeEmit = function(event, payload) {
                if (event === 'theme:changed' && payload && payload.theme) {
                    applyTheme(payload.theme, payload.css || '');
                }
                const handlers = __listeners[event] || [];
                for (let i = 0; i < handlers.length; i++) {
                    try { handlers[i](payload); } catch (e) { console.error(e); }
                }
            };

            function rpc(namespace, method, args) {
                return new Promise(function(resolve, reject) {
                    const requestId = 'req_' + (++__seq);
                    __pending[requestId] = { resolve: resolve, reject: reject };
                    const payload = {
                        requestId: requestId,
                        pluginId: '\(pluginID)',
                        viewId: '\(viewID)',
                        namespace: namespace,
                        method: method,
                        args: Array.from(args || [])
                    };
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.amberBridge) {
                        window.webkit.messageHandlers.amberBridge.postMessage(payload);
                    } else {
                        delete __pending[requestId];
                        reject(new Error('amberBridge messageHandler 未挂载'));
                    }
                });
            }

            window.amber = Object.freeze({
                pluginId: '\(pluginID)',
                viewId: '\(viewID)',
                settings: Object.freeze({
                    get: function(key) { return rpc('settings', 'get', [String(key)]); },
                    set: function(key, val) { return rpc('settings', 'set', [String(key), val]); },
                    getAll: function() { return rpc('settings', 'getAll', []); }
                }),
                storage: Object.freeze({
                    get: function(key) { return rpc('storage', 'get', [String(key)]); },
                    set: function(key, val) { return rpc('storage', 'set', [String(key), typeof val === 'string' ? val : JSON.stringify(val)]); },
                    remove: function(key) { return rpc('storage', 'remove', [String(key)]); },
                    keys: function() { return rpc('storage', 'keys', []); },
                    all: function() { return rpc('storage', 'all', []); }
                }),
                http: Object.freeze({
                    fetch: function(url, options) { return rpc('http', 'fetch', [String(url), options == null ? {} : options]); }
                }),
                workspace: Object.freeze({
                    read: function(path) { return rpc('workspace', 'read', [String(path)]); },
                    write: function(path, content) {
                        return rpc('workspace', 'write', [String(path), typeof content === 'string' ? content : JSON.stringify(content)]);
                    },
                    list: function(path) { return rpc('workspace', 'list', [path == null ? '' : String(path)]); },
                    watch: function(prefix, callback) {
                        const p = prefix == null ? '' : String(prefix);
                        const listener = typeof callback === 'function' ? function(payload) {
                            const path = payload && typeof payload.path === 'string' ? payload.path : '';
                            if (!p || !path || path === p || path.indexOf(p.replace(/\\/+$/, '') + '/') === 0 || payload.prefix === p) {
                                callback(payload);
                            }
                        } : null;
                        return rpc('workspace', 'watch', [p]).then(function() {
                            if (listener) {
                                if (!__listeners['workspace:changed']) __listeners['workspace:changed'] = [];
                                __listeners['workspace:changed'].push(listener);
                            }
                            return function() {
                                if (!listener || !__listeners['workspace:changed']) return;
                                __listeners['workspace:changed'] = __listeners['workspace:changed'].filter(function(h) { return h !== listener; });
                            };
                        });
                    }
                }),
                commands: Object.freeze({
                    register: function(cmd) {
                        const c = cmd || {};
                        return rpc('commands', 'register', [{
                            id: c.id, title: c.title, slash: c.slash, symbol: c.symbol,
                            promptTemplate: c.promptTemplate || c.prompt_template || ''
                        }]);
                    },
                    list: function() { return rpc('commands', 'list', []); }
                }),
                events: Object.freeze({
                    on: function(event, handler) {
                        const ev = String(event);
                        return rpc('events', 'on', [ev]).then(function() {
                            if (!__listeners[ev]) __listeners[ev] = [];
                            if (typeof handler === 'function') __listeners[ev].push(handler);
                            return function() { window.amber.events.off(ev, handler); };
                        });
                    },
                    off: function(event, handler) {
                        const ev = String(event);
                        if (__listeners[ev]) {
                            __listeners[ev] = __listeners[ev].filter(function(h) { return h !== handler; });
                        }
                        return rpc('events', 'off', [ev]);
                    },
                    emit: function(event, payload) {
                        return rpc('events', 'emit', [String(event), payload == null ? {} : payload]);
                    }
                }),
                ui: Object.freeze({
                    notice: function(message, kind) { return rpc('ui', 'notice', [String(message), kind || 'info']); },
                    confirm: function(options) { return rpc('ui', 'confirm', [options == null ? {} : options]); },
                    openView: function(viewId, state) { return rpc('ui', 'openView', [String(viewId), state == null ? {} : state]); },
                    openModal: function(viewId, options) { return rpc('ui', 'openModal', [String(viewId), options == null ? {} : options]); },
                    closeModal: function() { return rpc('ui', 'closeModal', []); }
                }),
                agent: Object.freeze({
                    registerTool: function(def) {
                        const err = new Error('agent.registerTool 只能在后台主脚本（main.js）中调用：工具执行体必须常驻在插件运行时里。');
                        err.code = 'E_INVALID_ARGUMENT';
                        return Promise.reject(err);
                    },
                    getConversation: function() { return rpc('agent', 'getConversation', []); },
                    insertToComposer: function(text) { return rpc('agent', 'insertToComposer', [String(text)]); }
                })
            });
        })();
        """
    }
}

// MARK: - Custom URL Scheme Handler (`amber-plugin://<pluginID>/<path>`) & WebView Host

@MainActor
final class DesktopPluginURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "amber-plugin"
    private weak var store: DesktopPluginStore?

    init(store: DesktopPluginStore) {
        self.store = store
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let store,
              let url = urlSchemeTask.request.url,
              url.scheme?.lowercased() == Self.scheme,
              let pluginID = url.host?.lowercased() else {
            fail(task: urlSchemeTask, status: 400, message: "无效的插件资源地址")
            return
        }
        do {
            let (data, mimeType, headers) = try store.loadPluginStaticAsset(pluginID: pluginID, rawPath: url.path)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers.merging(["Content-Type": mimeType]) { $1 }
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            fail(task: urlSchemeTask, status: 403, message: error.localizedDescription)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func fail(task: any WKURLSchemeTask, status: Int, message: String) {
        let url = task.request.url ?? URL(string: "amber-plugin://invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain; charset=utf-8"]
        )!
        task.didReceive(response)
        task.didReceive(Data(message.utf8))
        task.didFinish()
    }
}

@MainActor
final class DesktopPluginWebViewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let pluginID: String
    let viewID: String
    private weak var store: DesktopPluginStore?
    weak var webView: WKWebView?

    init(pluginID: String, viewID: String, store: DesktopPluginStore) {
        self.pluginID = pluginID
        self.viewID = viewID
        self.store = store
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "amberBridge",
              let body = message.body as? [String: Any],
              let requestId = body["requestId"] as? String,
              let namespace = body["namespace"] as? String,
              let method = body["method"] as? String else {
            return
        }
        let args = (body["args"] as? [Any]) ?? []
        guard let store else { return }

        Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            do {
                let resultJSON = try await store.dispatchBridgeRPC(
                    pluginID: self.pluginID,
                    viewID: self.viewID,
                    namespace: namespace,
                    method: method,
                    args: args
                )
                let js = "window.__amberBridgeResolve(\(Self.jsQuoted(requestId)), \(resultJSON));"
                _ = try? await self.webView?.evaluateJavaScript(js)
            } catch {
                let code = DesktopPluginBridgeErrorCode.classify(error).rawValue
                let js = "window.__amberBridgeReject(\(Self.jsQuoted(requestId)), \(Self.jsQuoted(error.localizedDescription)), \(Self.jsQuoted(code)));"
                _ = try? await self.webView?.evaluateJavaScript(js)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" {
            decisionHandler(.allow)
            return
        }
        // Strictly allow only `amber-plugin://<pluginID>/...` inside the plugin WebView.
        // `file://`, `http://`, and arbitrary external `https://` top-level/iframe navigations are blocked.
        if scheme == DesktopPluginURLSchemeHandler.scheme,
           url.host?.lowercased() == pluginID.lowercased() {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    func pushEvent(name: String, payloadJSON: String) {
        let js = "if (window.__amberBridgeEmit) { window.__amberBridgeEmit(\(Self.jsQuoted(name)), \(payloadJSON)); }"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private static func jsQuoted(_ text: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [text]),
           let arr = String(data: data, encoding: .utf8),
           arr.count >= 2 {
            return String(arr.dropFirst().dropLast())
        }
        return "\"\""
    }
}

// MARK: - DesktopPluginStore v3 Extensions (Permissions, Bridge RPC, Lifecycle, Hot Reload & WebView Assets)

extension DesktopPluginStore {
    static let approvedPermissionsPrefix = "desktop.plugins.approvedPermissions.v3."

    // MARK: Permission Inspection & Consent

    func approvedPermissions(for pluginID: String) -> Set<String> {
        if let stored = defaults.stringArray(forKey: Self.approvedPermissionsPrefix + pluginID) {
            return Set(stored)
        }
        if let plugin = plugins.first(where: { $0.id == pluginID }) {
            return Set(DesktopPluginPermissionCatalog.canonicalPermissions(for: plugin.manifest))
        }
        return []
    }

    func approvePluginPermissions(pluginID: String, permissions: [String]) {
        let normalized = Array(Set(permissions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        defaults.set(normalized, forKey: Self.approvedPermissionsPrefix + pluginID)
        if let plugin = plugins.first(where: { $0.id == pluginID && $0.enabled && $0.manifest.isV3 && !$0.isBuiltIn }) {
            let host = runtimeHosts[pluginID] ?? DesktopPluginRuntimeHost(pluginID: pluginID, store: self)
            runtimeHosts[pluginID] = host
            if !host.isLoaded {
                try? host.start(plugin: plugin, workspaceDirectory: workspaceDirectory)
            }
        }
        rebuildProjections()
    }

    func revokePluginPermissions(pluginID: String) {
        defaults.set([String](), forKey: Self.approvedPermissionsPrefix + pluginID)
        rebuildProjections()
    }

    func inspectPluginPackage(at url: URL) throws -> DesktopPluginInstallPlan {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw DesktopRuntimeError.message("所选插件文件或目录不存在。")
        }

        let manifestURL = isDir.boolValue ? url.appendingPathComponent("plugin.json") : url
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw DesktopRuntimeError.message("插件目录缺少 plugin.json。")
        }
        let manifestData = try Data(contentsOf: manifestURL)
        guard manifestData.count <= 256 * 1024 else {
            throw DesktopRuntimeError.message("plugin.json 超过 256 KB 上限。")
        }
        let manifest = try JSONDecoder().decode(DesktopPluginManifest.self, from: manifestData)
        try manifest.validated()
        guard manifest.capabilities.hostModules.isEmpty else {
            throw DesktopRuntimeError.message("hostModules 仅供官方内置插件使用，第三方插件不能声明宿主模块。")
        }

        let existing = plugins.first { $0.id == manifest.id }
        let previouslyApproved = Set(defaults.stringArray(forKey: Self.approvedPermissionsPrefix + manifest.id) ?? [])
        let canonical = DesktopPluginPermissionCatalog.canonicalPermissions(for: manifest)
        let descriptors = canonical.map { token in
            DesktopPluginPermissionCatalog.descriptor(
                for: token,
                manifest: manifest,
                isNewlyRequested: !previouslyApproved.contains(token)
            )
        }
        let hasUnapproved = descriptors.contains { $0.isNewlyRequested }
        return DesktopPluginInstallPlan(
            manifest: manifest,
            sourceURL: isDir.boolValue ? url : url.deletingLastPathComponent(),
            isUpgrade: existing != nil,
            previousVersion: existing?.manifest.version,
            permissions: descriptors,
            requiresUserApproval: manifest.isV3 && (!descriptors.isEmpty && (existing == nil || hasUnapproved))
        )
    }

    func hasPermission(plugin: DesktopInstalledPlugin, permission: String) -> Bool {
        let cleanPerm = permission.trimmingCharacters(in: .whitespacesAndNewlines)
        if !plugin.manifest.isV3 {
            // v2 compatibility rules
            switch cleanPerm {
            case "storage", "settings", "commands", "agent.tools", "ui.views", "events":
                return true
            case "workspace.read":
                return !plugin.manifest.capabilities.workspaceReadPrefixes.isEmpty
            case "workspace.write":
                return !plugin.manifest.capabilities.workspaceWritePrefixes.isEmpty
            default:
                if cleanPerm.hasPrefix("http:") {
                    let host = String(cleanPerm.dropFirst("http:".count)).lowercased()
                    return plugin.manifest.capabilities.networkDomains.contains { allowed in
                        let domain = allowed.lowercased()
                        return host == domain || host.hasSuffix("." + domain)
                    }
                }
                return false
            }
        }

        let declared = Set(DesktopPluginPermissionCatalog.canonicalPermissions(for: plugin.manifest))
        let approved = approvedPermissions(for: plugin.id)
        let active = declared.intersection(approved)

        if cleanPerm == "workspace.read" {
            return active.contains("workspace.read") || active.contains(where: { $0.hasPrefix("workspace.read:") })
        }
        if cleanPerm == "workspace.write" {
            return active.contains("workspace.write") || active.contains(where: { $0.hasPrefix("workspace.write:") })
        }
        if cleanPerm.hasPrefix("http:") {
            let host = String(cleanPerm.dropFirst("http:".count)).lowercased()
            return active.contains { token in
                guard token.hasPrefix("http:") else { return false }
                let domain = String(token.dropFirst("http:".count)).lowercased()
                return host == domain || host.hasSuffix("." + domain)
            }
        }
        return active.contains(cleanPerm)
    }

    func requirePermission(plugin: DesktopInstalledPlugin, permission: String) throws {
        guard hasPermission(plugin: plugin, permission: permission) else {
            let declared = Set(DesktopPluginPermissionCatalog.canonicalPermissions(for: plugin.manifest))
            let isDeclared = declared.contains(permission)
                || (permission == "workspace.read" && declared.contains(where: { $0 == "workspace.read" || $0.hasPrefix("workspace.read:") }))
                || (permission == "workspace.write" && declared.contains(where: { $0 == "workspace.write" || $0.hasPrefix("workspace.write:") }))
                || (permission.hasPrefix("http:") && declared.contains(where: { token in
                    guard token.hasPrefix("http:") else { return false }
                    let domain = String(token.dropFirst("http:".count)).lowercased()
                    let host = String(permission.dropFirst("http:".count)).lowercased()
                    return host == domain || host.hasSuffix("." + domain)
                }))
            if !isDeclared {
                throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 未声明权限 \(permission)，调用被拒绝。")
            } else {
                throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 所申请的权限 \(permission) 尚未获得用户批准，调用被拒绝。")
            }
        }
    }

    func effectiveWorkspaceReadPrefixes(for plugin: DesktopInstalledPlugin) -> [String] {
        guard hasPermission(plugin: plugin, permission: "workspace.read") else { return [] }
        let explicit = plugin.manifest.capabilities.workspaceReadPrefixes
        if !explicit.isEmpty { return explicit }
        return plugin.manifest.isV3 ? ["*"] : []
    }

    func effectiveWorkspaceWritePrefixes(for plugin: DesktopInstalledPlugin) -> [String] {
        guard hasPermission(plugin: plugin, permission: "workspace.write") else { return [] }
        let explicit = plugin.manifest.capabilities.workspaceWritePrefixes
        if !explicit.isEmpty { return explicit }
        return plugin.manifest.isV3 ? ["*"] : []
    }

    // MARK: Workspace Directory Listing (`amber.workspace.list`)

    func listAuthorizedWorkspaceDirectory(
        plugin: DesktopInstalledPlugin,
        relativePath: String,
        workspaceDirectory: URL? = nil
    ) throws -> [[String: Any]] {
        try requirePermission(plugin: plugin, permission: "workspace.read")
        let allowedPrefixes = effectiveWorkspaceReadPrefixes(for: plugin)
        guard !allowedPrefixes.isEmpty else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 未授权读取工作区目录。")
        }

        let rootDir = workspaceDirectory ?? self.workspaceDirectory
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let targetDir: URL
        if trimmed.isEmpty || trimmed == "." {
            guard allowedPrefixes.contains("*") else {
                throw DesktopRuntimeError.message("插件未授权访问工作区根目录（允许前缀：\(allowedPrefixes.joined(separator: ", "))）。")
            }
            let manager = FileManager.default
            if let kind = try? manager.attributesOfItem(atPath: rootDir.path)[.type],
               kind as? FileAttributeType == .typeSymbolicLink {
                throw DesktopRuntimeError.message("工作区路径不能包含符号链接。")
            }
            targetDir = rootDir.standardizedFileURL.resolvingSymlinksInPath()
        } else {
            targetDir = try Self.resolveAuthorizedWorkspaceFileURL(
                rootDirectory: rootDir,
                relativePath: trimmed,
                allowedPrefixes: allowedPrefixes,
                createParents: false
            )
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetDir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let urls = (try? fm.contentsOfDirectory(
            at: targetDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let iso = ISO8601DateFormatter()
        var items: [[String: Any]] = []
        for itemURL in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            let name = itemURL.lastPathComponent
            let relPath = trimmed.isEmpty || trimmed == "." ? name : "\(trimmed)/\(name)"
            items.append([
                "name": name,
                "path": relPath,
                "isDirectory": values?.isDirectory ?? false,
                "size": values?.fileSize ?? 0,
                "modifiedAt": (values?.contentModificationDate).map { iso.string(from: $0) } ?? ""
            ])
        }
        return items
    }

    // MARK: Static Asset Loader for `amber-plugin://<pluginID>/<path>` with Strict CSP & Anti-Traversal Guard

    func loadPluginStaticAsset(pluginID: String, rawPath: String) throws -> (data: Data, mimeType: String, headers: [String: String]) {
        guard let plugin = plugins.first(where: { $0.id == pluginID }) else {
            throw DesktopRuntimeError.message("找不到插件：\(pluginID)。")
        }
        guard plugin.enabled else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 已停用。")
        }
        try requirePermission(plugin: plugin, permission: "ui.views")

        let cleanRelative = rawPath
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? rawPath
        let trimmed = cleanRelative.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let effectiveRelative = trimmed.isEmpty ? "index.html" : trimmed

        let pluginRoot = directory.appendingPathComponent(plugin.id, isDirectory: true)
        let fileURL = try Self.resolveAuthorizedWorkspaceFileURL(
            rootDirectory: pluginRoot,
            relativePath: effectiveRelative,
            allowedPrefixes: ["*"],
            createParents: false
        )
        guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw DesktopRuntimeError.message("插件静态资源不存在：\(effectiveRelative)")
        }

        var data = try Data(contentsOf: fileURL)
        let ext = fileURL.pathExtension.lowercased()
        let mimeType = Self.mimeType(forExtension: ext)
        let allowedDomains = plugin.manifest.capabilities.networkDomains.filter { domain in
            hasPermission(plugin: plugin, permission: "http:\(domain.lowercased())")
        }
        let csp = DesktopPluginThemeCSS.contentSecurityPolicy(allowedDomains: allowedDomains)

        if ext == "html" || ext == "htm", var html = String(data: data, encoding: .utf8) {
            let metaTag = #"<meta http-equiv="Content-Security-Policy" content="\#(csp)">"#
            let themeStyle = #"<style id="amber-theme-tokens">\#(DesktopPluginThemeCSS.stylesheet(isDark: isDarkThemeActive))</style>"#
            if let headRange = html.range(of: "<head>", options: .caseInsensitive) {
                html.insert(contentsOf: "\n\(metaTag)\n\(themeStyle)\n", at: headRange.upperBound)
            } else {
                html = "\(metaTag)\n\(themeStyle)\n" + html
            }
            data = Data(html.utf8)
        }

        return (
            data: data,
            mimeType: mimeType,
            headers: [
                "Content-Security-Policy": csp,
                "X-Content-Type-Options": "nosniff",
                "Cache-Control": "no-store"
            ]
        )
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "application/javascript; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        default: "application/octet-stream"
        }
    }

    // MARK: Unified Bridge RPC Dispatcher (WebView `window.amber.*` & Background Runtime `amber.*`)

    func dispatchBridgeRPC(
        pluginID: String,
        viewID: String = "",
        namespace: String,
        method: String,
        args: [Any],
        workspaceDirectory: URL? = nil
    ) async throws -> String {
        guard let plugin = plugins.first(where: { $0.id == pluginID }) else {
            throw DesktopRuntimeError.message("找不到插件：\(pluginID)。")
        }
        guard plugin.enabled else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 当前已停用。")
        }

        let targetWorkspace = workspaceDirectory ?? self.workspaceDirectory

        // Async HTTP fetch handling in RPC
        if namespace == "http" && method == "fetch" {
            let urlString = (args.first as? String) ?? ""
            guard let url = URL(string: urlString),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased() else {
                throw DesktopRuntimeError.message("插件仅允许访问 HTTPS 地址：\(urlString)")
            }
            try requirePermission(plugin: plugin, permission: "http:\(host)")
            let options = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
            let httpMethod = ((options["method"] as? String) ?? "GET").uppercased()
            var headers: [String: String] = [:]
            if let rawHeaders = options["headers"] as? [String: Any] {
                for (k, v) in rawHeaders { headers[k] = String(describing: v) }
            }
            var bodyData: Data? = nil
            if let bodyStr = options["body"] as? String {
                bodyData = Data(bodyStr.utf8)
            } else if let bodyObj = options["body"], !(bodyObj is NSNull), JSONSerialization.isValidJSONObject(bodyObj) {
                bodyData = try? JSONSerialization.data(withJSONObject: bodyObj)
            }
            let (data, status) = try await performAuthorizedHTTP(
                plugin: plugin,
                urlString: urlString,
                method: httpMethod,
                headers: headers,
                body: bodyData
            )
            let bodyText = String(decoding: data, as: UTF8.self)
            let parsedJSON = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
            return try Self.encodeAnyJSON([
                "ok": (200...299).contains(status),
                "status": status,
                "body": bodyText,
                "text": bodyText,
                "json": parsedJSON
            ])
        }

        if namespace == "ui" && method == "confirm" {
            try requirePermission(plugin: plugin, permission: "ui.views")
            let options = (args.first as? [String: Any]) ?? [:]
            let title = (options["title"] as? String) ?? "插件确认"
            let message = (options["message"] as? String) ?? ""
            if let handler = onConfirmRequest {
                let confirmed = await handler(title, message)
                return confirmed ? "true" : "false"
            }
            // No host dialog is attached (headless or tests): never treat silence as consent.
            return "false"
        }

        return try performSynchronousBridgeCall(
            pluginID: pluginID,
            runtimeHost: runtimeHosts[pluginID],
            namespace: namespace,
            method: method,
            args: args,
            workspaceDirectory: targetWorkspace,
            activeToolEffect: nil
        )
    }

    func performSynchronousBridgeCall(
        pluginID: String,
        runtimeHost: DesktopPluginRuntimeHost?,
        namespace: String,
        method: String,
        args: [Any],
        workspaceDirectory: URL,
        activeToolEffect: DesktopToolEffect?
    ) throws -> String {
        guard let plugin = plugins.first(where: { $0.id == pluginID }) else {
            throw DesktopRuntimeError.message("找不到插件：\(pluginID)。")
        }
        guard plugin.enabled else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 当前已停用。")
        }

        switch namespace {
        case "storage":
            try requirePermission(plugin: plugin, permission: "storage")
            var currentStorage = readPluginStorage(pluginID: plugin.id)
            switch method {
            case "get":
                let key = (args.first as? String) ?? ""
                return try Self.encodeAnyJSON(currentStorage[key] ?? "")
            case "set":
                let key = (args.first as? String) ?? ""
                let val: String
                if args.count > 1 {
                    if let str = args[1] as? String {
                        val = str
                    } else if JSONSerialization.isValidJSONObject(args[1]),
                              let data = try? JSONSerialization.data(withJSONObject: args[1], options: [.sortedKeys]) {
                        val = String(decoding: data, as: UTF8.self)
                    } else {
                        val = String(describing: args[1])
                    }
                } else {
                    val = ""
                }
                currentStorage[key] = val
                writePluginStorage(pluginID: plugin.id, storage: currentStorage)
                rebuildProjections()
                broadcastPluginEvent(pluginID: plugin.id, event: "storage:changed", payload: ["key": key, "value": val])
                return "true"
            case "remove":
                let key = (args.first as? String) ?? ""
                currentStorage.removeValue(forKey: key)
                writePluginStorage(pluginID: plugin.id, storage: currentStorage)
                rebuildProjections()
                broadcastPluginEvent(pluginID: plugin.id, event: "storage:changed", payload: ["key": key, "removed": true])
                return "true"
            case "keys":
                return try Self.encodeAnyJSON(Array(currentStorage.keys).sorted())
            case "all":
                return try Self.encodeAnyJSON(currentStorage)
            default:
                throw DesktopRuntimeError.message("未知的 storage 方法：\(method)")
            }

        case "settings":
            try requirePermission(plugin: plugin, permission: "settings")
            switch method {
            case "get":
                let key = (args.first as? String) ?? ""
                if key == "today" {
                    return try Self.encodeAnyJSON(todayDateString)
                }
                if key == "mode" {
                    let mode = (plugin.id == "feishu_calendar" && hasFeishuRemoteCredentials) ? "feishu" : "local"
                    return try Self.encodeAnyJSON(mode)
                }
                guard let field = plugin.manifest.settingsSchema.first(where: { $0.key == key }),
                      field.kind != .secret else {
                    return try Self.encodeAnyJSON("")
                }
                return try Self.encodeAnyJSON(settingValue(pluginID: plugin.id, key: key))
            case "set":
                let key = (args.first as? String) ?? ""
                let value = args.count > 1 ? String(describing: args[1]) : ""
                guard let field = plugin.manifest.settingsSchema.first(where: { $0.key == key }) else {
                    throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 未声明配置项：\(key)")
                }
                guard field.kind != .secret else {
                    throw DesktopRuntimeError.message("禁止通过脚本读写 secret 密钥配置项：\(key)")
                }
                var updated: [String: String] = [:]
                for item in plugin.manifest.settingsSchema where item.kind != .secret {
                    updated[item.key] = settingValue(pluginID: plugin.id, key: item.key)
                }
                updated[key] = value
                try saveSettings(pluginID: plugin.id, values: updated)
                broadcastPluginEvent(pluginID: plugin.id, event: "settings:changed", payload: ["key": key, "value": value])
                return "true"
            case "getAll":
                var all: [String: String] = [:]
                for field in plugin.manifest.settingsSchema where field.kind != .secret {
                    all[field.key] = settingValue(pluginID: plugin.id, key: field.key)
                }
                return try Self.encodeAnyJSON(all)
            default:
                throw DesktopRuntimeError.message("未知的 settings 方法：\(method)")
            }

        case "workspace":
            switch method {
            case "read":
                try requirePermission(plugin: plugin, permission: "workspace.read")
                let relativePath = (args.first as? String) ?? ""
                let url = try Self.resolveAuthorizedWorkspaceFileURL(
                    rootDirectory: workspaceDirectory,
                    relativePath: relativePath,
                    allowedPrefixes: effectiveWorkspaceReadPrefixes(for: plugin),
                    createParents: false
                )
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    throw DesktopRuntimeError.message("工作区文件不存在或不是普通文件：\(relativePath)")
                }
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw DesktopRuntimeError.message("工作区文件不是有效的 UTF-8 文本：\(relativePath)")
                }
                return try Self.encodeAnyJSON(text)

            case "write":
                if let effect = activeToolEffect, effect != .sideEffect && effect != .idempotent {
                    throw DesktopRuntimeError.message("只读工具（effect=\(effect.rawValue)）禁止调用 amber.workspace.write 写入工作区文件；请将工具 effect 声明为 sideEffect 或 idempotent。")
                }
                try requirePermission(plugin: plugin, permission: "workspace.write")
                let relativePath = (args.first as? String) ?? ""
                let content: String
                if args.count > 1 {
                    if let str = args[1] as? String {
                        content = str
                    } else if JSONSerialization.isValidJSONObject(args[1]),
                              let data = try? JSONSerialization.data(withJSONObject: args[1], options: [.prettyPrinted, .sortedKeys]) {
                        content = String(decoding: data, as: UTF8.self)
                    } else {
                        content = String(describing: args[1])
                    }
                } else {
                    content = ""
                }
                let url = try Self.resolveAuthorizedWorkspaceFileURL(
                    rootDirectory: workspaceDirectory,
                    relativePath: relativePath,
                    allowedPrefixes: effectiveWorkspaceWritePrefixes(for: plugin),
                    createParents: true
                )
                try Data(content.utf8).write(to: url, options: .atomic)
                broadcastPluginEvent(
                    pluginID: plugin.id,
                    event: "workspace:changed",
                    payload: ["path": relativePath, "event": "write"]
                )
                return "true"

            case "list":
                let relativePath = (args.first as? String) ?? ""
                let entries = try listAuthorizedWorkspaceDirectory(
                    plugin: plugin,
                    relativePath: relativePath,
                    workspaceDirectory: workspaceDirectory
                )
                return try Self.encodeAnyJSON(entries)

            case "watch":
                try requirePermission(plugin: plugin, permission: "workspace.read")
                let prefix = (args.first as? String) ?? ""
                let trimmedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                let readPrefixes = effectiveWorkspaceReadPrefixes(for: plugin)
                if trimmedPrefix.isEmpty {
                    guard readPrefixes.contains("*") else {
                        throw DesktopRuntimeError.message("插件未授权监听工作区根目录（允许前缀：\(readPrefixes.joined(separator: ", "))）。")
                    }
                } else {
                    _ = try Self.resolveAuthorizedWorkspaceFileURL(
                        rootDirectory: workspaceDirectory,
                        relativePath: trimmedPrefix,
                        allowedPrefixes: readPrefixes,
                        createParents: false
                    )
                }
                let host = runtimeHost ?? ensureRuntimeHost(for: plugin)
                host.addWorkspaceWatch(prefix: prefix, workspaceDirectory: workspaceDirectory) { [weak self] watchedPrefix in
                    self?.broadcastPluginEvent(
                        pluginID: plugin.id,
                        event: "workspace:changed",
                        payload: ["prefix": watchedPrefix, "event": "modified"]
                    )
                }
                return "true"

            default:
                throw DesktopRuntimeError.message("未知的 workspace 方法：\(method)")
            }

        case "http":
            guard method == "fetch" else {
                throw DesktopRuntimeError.message("未知的 http 方法：\(method)")
            }
            let urlString = (args.first as? String) ?? ""
            guard let url = URL(string: urlString),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased() else {
                throw DesktopRuntimeError.message("插件仅允许访问 HTTPS 地址：\(urlString)")
            }
            try requirePermission(plugin: plugin, permission: "http:\(host)")
            let options = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
            let httpMethod = ((options["method"] as? String) ?? "GET").uppercased()
            if let effect = activeToolEffect, effect == .pure {
                throw DesktopRuntimeError.message("只读计算工具（effect=pure）禁止发起外部 HTTP 请求。")
            }
            if let effect = activeToolEffect, effect == .networkRead, httpMethod != "GET" && httpMethod != "HEAD" {
                throw DesktopRuntimeError.message("只读网络工具（effect=networkRead）仅允许发起 GET/HEAD 请求，禁止 \(httpMethod) 写操作。")
            }
            var request = URLRequest(url: url)
            request.httpMethod = httpMethod
            request.timeoutInterval = 20
            if let headers = options["headers"] as? [String: Any] {
                for (k, v) in headers { request.setValue(String(describing: v), forHTTPHeaderField: k) }
            }
            if let bodyString = options["body"] as? String {
                request.httpBody = Data(bodyString.utf8)
            } else if let bodyObj = options["body"],
                      !(bodyObj is NSNull),
                      JSONSerialization.isValidJSONObject(bodyObj),
                      let data = try? JSONSerialization.data(withJSONObject: bodyObj) {
                request.httpBody = data
            }
            return try performSynchronousHTTPRequest(request: request, host: host)

        case "commands":
            try requirePermission(plugin: plugin, permission: "commands")
            switch method {
            case "register":
                guard let dict = args.first as? [String: Any] else {
                    throw DesktopRuntimeError.message("commands.register 参数须为对象。")
                }
                let id = ((dict["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let title = ((dict["title"] as? String) ?? id).trimmingCharacters(in: .whitespacesAndNewlines)
                let rawSlash = ((dict["slash"] as? String) ?? "/\(id)").trimmingCharacters(in: .whitespacesAndNewlines)
                let slash = rawSlash.hasPrefix("/") ? rawSlash : "/\(rawSlash)"
                let symbol = (dict["symbol"] as? String) ?? "bolt"
                let promptTemplate = (dict["promptTemplate"] as? String) ?? (dict["prompt_template"] as? String) ?? ""
                guard !id.isEmpty, !title.isEmpty else {
                    throw DesktopRuntimeError.message("commands.register 需要非空的 id 与 title。")
                }
                let cmd = DesktopPluginCommandManifest(
                    id: id,
                    title: title,
                    slash: slash,
                    symbol: symbol,
                    promptTemplate: promptTemplate
                )
                let host = runtimeHost ?? ensureRuntimeHost(for: plugin)
                host.registerDynamicCommand(cmd)
                rebuildProjections()
                return try Self.encodeAnyJSON(["ok": true, "id": id, "slash": slash])

            case "list":
                let cmds = activeSlashCommands.filter { $0.pluginID == plugin.id }.map {
                    ["id": $0.commandID, "title": $0.title, "slash": $0.slash, "symbol": $0.symbol]
                }
                return try Self.encodeAnyJSON(cmds)

            default:
                throw DesktopRuntimeError.message("未知的 commands 方法：\(method)")
            }

        case "events":
            try requirePermission(plugin: plugin, permission: "events")
            let host = runtimeHost ?? ensureRuntimeHost(for: plugin)
            switch method {
            case "on":
                let eventName = (args.first as? String) ?? ""
                host.recordEventSubscription(event: eventName, delta: 1)
                return "true"
            case "off":
                let eventName = (args.first as? String) ?? ""
                host.recordEventSubscription(event: eventName, delta: -1)
                return "true"
            case "emit":
                let eventName = (args.first as? String) ?? ""
                let payload = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
                broadcastPluginEvent(pluginID: plugin.id, event: eventName, payload: payload)
                return "true"
            default:
                throw DesktopRuntimeError.message("未知的 events 方法：\(method)")
            }

        case "ui":
            // Every ui.* call needs the declared and approved `ui.views` permission; undeclared capabilities are refused.
            try requirePermission(plugin: plugin, permission: "ui.views")
            switch method {
            case "notice":
                let message = (args.first as? String) ?? ""
                let rawKind = (args.count > 1 ? args[1] as? String : nil) ?? "info"
                let kind = DesktopPluginNoticeBanner.Kind(rawValue: rawKind) ?? .info
                let banner = DesktopPluginNoticeBanner(
                    id: UUID(),
                    pluginID: plugin.id,
                    pluginName: plugin.manifest.name,
                    message: message,
                    kind: kind,
                    createdAt: referenceDateProvider()
                )
                latestNotice = banner
                return try Self.encodeAnyJSON(["ok": true])

            case "confirm":
                throw DesktopRuntimeError.message("ui.confirm 需要等待用户点击，只能在插件视图（WebView）中 await 调用；后台主脚本请改用视图或 ui.notice。")

            case "openView":
                try requirePermission(plugin: plugin, permission: "ui.views")
                let viewID = (args.first as? String) ?? ""
                guard !viewID.isEmpty else {
                    throw DesktopRuntimeError.message("ui.openView 需要提供非空的 viewId。")
                }
                if let custom = activeCustomViews.first(where: { $0.pluginID == plugin.id && $0.viewID == viewID }),
                   custom.slot == .modal {
                    return try openPluginModal(plugin: plugin, viewID: viewID, options: (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:])
                }
                onOpenPluginViewRequest?(plugin.id, viewID)
                return try Self.encodeAnyJSON(["ok": true, "pluginId": plugin.id, "viewId": viewID])

            case "openModal":
                try requirePermission(plugin: plugin, permission: "ui.views")
                // Accepts openModal(viewId, options) and openModal({ viewId, ...options }).
                var options = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
                var viewID = (args.first as? String) ?? ""
                if let dict = args.first as? [String: Any] {
                    options = dict.merging(options) { _, new in new }
                    viewID = (dict["viewId"] as? String) ?? (dict["viewID"] as? String) ?? ""
                }
                return try openPluginModal(plugin: plugin, viewID: viewID, options: options)

            case "closeModal":
                if activeModal?.pluginID == plugin.id {
                    activeModal = nil
                }
                return try Self.encodeAnyJSON(["ok": true])

            default:
                throw DesktopRuntimeError.message("未知的 ui 方法：\(method)")
            }

        case "agent":
            try requirePermission(plugin: plugin, permission: "agent.tools")
            switch method {
            case "registerTool":
                guard let dict = args.first as? [String: Any] else {
                    throw DesktopRuntimeError.message("agent.registerTool 参数须为对象。")
                }
                let name = ((dict["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard DesktopPluginManifest.isValidIdentifier(name, minLength: 1) else {
                    throw DesktopRuntimeError.message("插件动态工具名称无效：\(name)")
                }
                let description = ((dict["description"] as? String) ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
                let entry = ((dict["entry"] as? String) ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
                let writesWorkspace = (dict["writesWorkspace"] as? Bool) ?? false
                let sendsHTTP = (dict["sendsHTTP"] as? Bool) ?? false
                let rawEffect = (dict["effect"] as? String) ?? "sideEffect"
                let declaredEffect: DesktopToolEffect
                if writesWorkspace || sendsHTTP {
                    declaredEffect = .sideEffect
                } else if rawEffect == "pure" || rawEffect == "readOnly" {
                    declaredEffect = .pure
                } else if rawEffect == "networkRead" {
                    declaredEffect = .networkRead
                } else if rawEffect == "idempotent" {
                    declaredEffect = .idempotent
                } else {
                    declaredEffect = .sideEffect
                }

                let schemaJSON: String
                if let schemaObj = (dict["inputSchema"] as? [String: Any]) ?? (dict["input_schema"] as? [String: Any]),
                   JSONSerialization.isValidJSONObject(schemaObj),
                   let data = try? JSONSerialization.data(withJSONObject: schemaObj, options: [.sortedKeys]) {
                    schemaJSON = String(decoding: data, as: UTF8.self)
                } else {
                    schemaJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
                }

                let toolManifest = DesktopPluginToolManifest(
                    name: name,
                    description: description,
                    effect: declaredEffect,
                    entry: entry,
                    parametersJSON: schemaJSON
                )
                let dynamicTool = DesktopPluginDynamicTool(
                    pluginID: plugin.id,
                    manifest: toolManifest,
                    writesWorkspace: writesWorkspace,
                    sendsHTTP: sendsHTTP
                )
                let host = runtimeHost ?? ensureRuntimeHost(for: plugin)
                host.registerDynamicTool(dynamicTool)
                rebuildProjections()
                return try Self.encodeAnyJSON([
                    "ok": true,
                    "qualifiedName": plugin.qualifiedToolName(name),
                    "highRisk": declaredEffect == .sideEffect || declaredEffect == .idempotent
                ])

            case "getConversation":
                let snapshot = conversationSnapshotProvider?()
                    ?? DesktopPluginConversationSnapshot(id: "", title: "当前对话", messageCount: 0, messages: [])
                let data = try JSONEncoder().encode(snapshot)
                return String(decoding: data, as: UTF8.self)

            case "insertToComposer":
                let text = (args.first as? String) ?? ""
                lastInsertedComposerText = text
                onInsertToComposerRequest?(text)
                return try Self.encodeAnyJSON(["ok": true, "insertedLength": text.count])

            default:
                throw DesktopRuntimeError.message("未知的 agent 方法：\(method)")
            }

        default:
            throw DesktopRuntimeError.message("未知的插件桥命名空间：\(namespace)")
        }
    }

    private func openPluginModal(plugin: DesktopInstalledPlugin, viewID: String, options: [String: Any]) throws -> String {
        let custom = activeCustomViews.first { $0.pluginID == plugin.id && $0.viewID == viewID }
        let title = (options["title"] as? String) ?? custom?.title ?? plugin.manifest.name
        let entry = (options["entry"] as? String) ?? custom?.entryPath ?? "index.html"
        let width = (options["width"] as? Double) ?? custom?.width ?? 560
        let height = (options["height"] as? Double) ?? custom?.height ?? 440
        let stateData = (try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])) ?? Data("{}".utf8)
        activeModal = DesktopPluginModalPresentation(
            pluginID: plugin.id,
            pluginName: plugin.manifest.name,
            viewID: viewID.isEmpty ? "modal" : viewID,
            title: title,
            entryPath: entry,
            width: width,
            height: height,
            stateJSON: String(decoding: stateData, as: UTF8.self)
        )
        return try Self.encodeAnyJSON(["ok": true, "viewId": viewID])
    }

    // MARK: Lifecycle, Hot Reload & Event Broadcasting

    @discardableResult
    func ensureRuntimeHost(for plugin: DesktopInstalledPlugin) -> DesktopPluginRuntimeHost {
        if let existing = runtimeHosts[plugin.id] {
            if !existing.isLoaded {
                try? existing.start(plugin: plugin, workspaceDirectory: workspaceDirectory)
            }
            return existing
        }
        let host = DesktopPluginRuntimeHost(pluginID: plugin.id, store: self)
        runtimeHosts[plugin.id] = host
        try? host.start(plugin: plugin, workspaceDirectory: workspaceDirectory)
        if plugin.manifest.devReload && !plugin.isBuiltIn {
            let folder = directory.appendingPathComponent(plugin.id, isDirectory: true)
            host.startDirectoryHotReloadWatcher(folderURL: folder) { [weak self] in
                try? self?.reloadPlugin(id: plugin.id)
            }
        }
        return host
    }

    func reloadPlugin(id: String) throws {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else {
            throw DesktopRuntimeError.message("找不到插件：\(id)。")
        }
        let existing = plugins[index]
        guard !existing.isBuiltIn else {
            rebuildProjections()
            return
        }
        if let host = runtimeHosts[id] {
            host.stop()
        }
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        let manifestURL = folder.appendingPathComponent("plugin.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw DesktopRuntimeError.message("插件目录缺少 plugin.json：\(id)")
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(DesktopPluginManifest.self, from: data)
        try manifest.validated()
        let scriptURL = folder.appendingPathComponent(manifest.main)
        let script = FileManager.default.fileExists(atPath: scriptURL.path)
            ? try String(contentsOf: scriptURL, encoding: .utf8)
            : ""
        let updatedPlugin = DesktopInstalledPlugin(
            manifest: manifest,
            scriptSource: script,
            enabled: existing.enabled,
            isBuiltIn: false,
            lastSyncStatus: existing.lastSyncStatus
        )
        var nextPlugins = plugins
        nextPlugins[index] = updatedPlugin
        plugins = nextPlugins
        pluginReloadRevisions[id, default: 0] += 1

        if updatedPlugin.enabled && updatedPlugin.manifest.isV3 {
            let host = runtimeHosts[id] ?? DesktopPluginRuntimeHost(pluginID: id, store: self)
            runtimeHosts[id] = host
            try host.start(plugin: updatedPlugin, workspaceDirectory: workspaceDirectory)
            if updatedPlugin.manifest.devReload {
                host.startDirectoryHotReloadWatcher(folderURL: folder) { [weak self] in
                    try? self?.reloadPlugin(id: id)
                }
            }
        }
        rebuildProjections()
    }

    func registerWebViewCoordinator(_ coordinator: DesktopPluginWebViewCoordinator) {
        let key = "\(coordinator.pluginID):\(coordinator.viewID)"
        webViewCoordinators[key] = coordinator
    }

    func unregisterWebViewCoordinator(pluginID: String, viewID: String) {
        let key = "\(pluginID):\(viewID)"
        webViewCoordinators.removeValue(forKey: key)
    }

    func broadcastPluginEvent(pluginID: String, event: String, payload: [String: Any]) {
        guard let plugin = plugins.first(where: { $0.id == pluginID && $0.enabled }) else { return }
        if plugin.manifest.isV3, event != "theme:changed", !hasPermission(plugin: plugin, permission: "events") {
            // workspace.watch callbacks ride on workspace:changed and only need workspace.read.
            let isWatchDelivery = event == "workspace:changed" && hasPermission(plugin: plugin, permission: "workspace.read")
            if !isWatchDelivery { return }
        }
        runtimeHosts[pluginID]?.emitEvent(name: event, payload: payload)
        let payloadJSON = (try? Self.encodeAnyJSON(payload)) ?? "{}"
        for (key, coordinator) in webViewCoordinators where key.hasPrefix("\(pluginID):") {
            coordinator.pushEvent(name: event, payloadJSON: payloadJSON)
        }
    }

    func broadcastHostEvent(_ event: String, payload: [String: Any]) {
        if event == "theme:changed", let isDark = payload["isDark"] as? Bool {
            isDarkThemeActive = isDark
        }
        for plugin in plugins where plugin.enabled {
            var enriched = payload
            if event == "theme:changed" {
                enriched["theme"] = isDarkThemeActive ? "dark" : "light"
                enriched["css"] = DesktopPluginThemeCSS.stylesheet(isDark: isDarkThemeActive)
            }
            broadcastPluginEvent(pluginID: plugin.id, event: event, payload: enriched)
        }
    }

    nonisolated static func encodeAnyJSON(_ value: Any) throws -> String {
        if let str = value as? String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(str)
            return String(decoding: data, as: UTF8.self)
        }
        if let boolVal = value as? Bool {
            return boolVal ? "true" : "false"
        }
        if let intVal = value as? Int {
            return String(intVal)
        }
        if let doubleVal = value as? Double {
            return String(doubleVal)
        }
        if JSONSerialization.isValidJSONObject(value) {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        let fallback = try JSONEncoder().encode(String(describing: value))
        return String(decoding: fallback, as: UTF8.self)
    }
}
