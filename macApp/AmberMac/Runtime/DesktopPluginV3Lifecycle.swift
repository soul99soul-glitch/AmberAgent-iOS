import Foundation
import JavaScriptCore

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

// MARK: - DesktopPluginStore Lifecycle, Hot Reload & Event Broadcasting

extension DesktopPluginStore {
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
