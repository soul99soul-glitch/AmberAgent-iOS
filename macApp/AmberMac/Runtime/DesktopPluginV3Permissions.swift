import Foundation

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
            let scopedPrefix = token.hasPrefix("workspace.read:")
                ? String(token.dropFirst("workspace.read:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let prefixes = !scopedPrefix.isEmpty ? [scopedPrefix] : manifest.capabilities.workspaceReadPrefixes
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
            let scopedPrefix = token.hasPrefix("workspace.write:")
                ? String(token.dropFirst("workspace.write:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let prefixes = !scopedPrefix.isEmpty ? [scopedPrefix] : manifest.capabilities.workspaceWritePrefixes
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

// MARK: - DesktopPluginStore Permission Inspection & Consent

extension DesktopPluginStore {
    static let approvedPermissionsPrefix = "desktop.plugins.approvedPermissions.v3."

    func approvedPermissions(for pluginID: String) -> Set<String> {
        if let stored = defaults.stringArray(forKey: Self.approvedPermissionsPrefix + pluginID) {
            return Set(stored)
        }
        if let plugin = plugins.first(where: { $0.id == pluginID }),
           plugin.isBuiltIn || !plugin.manifest.isV3 {
            return Set(DesktopPluginPermissionCatalog.canonicalPermissions(for: plugin.manifest))
        }
        return []
    }

    func canStartV3Runtime(for plugin: DesktopInstalledPlugin) -> Bool {
        guard plugin.manifest.isV3, !plugin.isBuiltIn else { return true }
        let canonical = DesktopPluginPermissionCatalog.canonicalPermissions(for: plugin.manifest)
        return canonical.isEmpty || !approvedPermissions(for: plugin.id).isEmpty
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
        if let plugin = plugins.first(where: { $0.id == pluginID }),
           !canStartV3Runtime(for: plugin),
           let host = runtimeHosts[pluginID] {
            host.stop()
        }
        rebuildProjections()
    }

    func inspectPluginPackage(at url: URL) throws -> DesktopPluginInstallPlan {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let (manifest, _, _) = try Self.loadAndValidateImportSource(from: url)
        let sourceDirectory = url.lastPathComponent == "plugin.json" ? url.deletingLastPathComponent() : url

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
            sourceURL: sourceDirectory,
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
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard plugin.manifest.isV3 else { return explicit }
        let declared = Set(DesktopPluginPermissionCatalog.canonicalPermissions(for: plugin.manifest))
        let active = declared.intersection(approvedPermissions(for: plugin.id))
        if active.contains("workspace.read") {
            return explicit.isEmpty ? ["*"] : explicit
        }
        let scoped = active.compactMap { token -> String? in
            guard token.hasPrefix("workspace.read:") else { return nil }
            let prefix = String(token.dropFirst("workspace.read:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return prefix.isEmpty ? nil : prefix
        }.sorted()
        guard !explicit.isEmpty else { return scoped }
        return scoped.filter { candidate in
            let cleanCandidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return explicit.contains { allowed in
                let cleanAllowed = allowed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return cleanAllowed == "*" || cleanCandidate == cleanAllowed || cleanCandidate.hasPrefix(cleanAllowed + "/")
            }
        }
    }

    func effectiveWorkspaceWritePrefixes(for plugin: DesktopInstalledPlugin) -> [String] {
        guard hasPermission(plugin: plugin, permission: "workspace.write") else { return [] }
        let explicit = plugin.manifest.capabilities.workspaceWritePrefixes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard plugin.manifest.isV3 else { return explicit }
        let declared = Set(DesktopPluginPermissionCatalog.canonicalPermissions(for: plugin.manifest))
        let active = declared.intersection(approvedPermissions(for: plugin.id))
        if active.contains("workspace.write") {
            return explicit.isEmpty ? ["*"] : explicit
        }
        let scoped = active.compactMap { token -> String? in
            guard token.hasPrefix("workspace.write:") else { return nil }
            let prefix = String(token.dropFirst("workspace.write:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return prefix.isEmpty ? nil : prefix
        }.sorted()
        guard !explicit.isEmpty else { return scoped }
        return scoped.filter { candidate in
            let cleanCandidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return explicit.contains { allowed in
                let cleanAllowed = allowed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return cleanAllowed == "*" || cleanCandidate == cleanAllowed || cleanCandidate.hasPrefix(cleanAllowed + "/")
            }
        }
    }
}
