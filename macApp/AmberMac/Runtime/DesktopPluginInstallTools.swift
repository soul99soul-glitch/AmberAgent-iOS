import Foundation

struct DesktopPreparedPluginInstall: Equatable, Sendable {
    enum InstallKind: Equatable, Sendable {
        case fresh
        case upgrade(previousVersion: String)
        case overwrite(previousVersion: String)

        var actionCode: String {
            switch self {
            case .fresh: "install"
            case .upgrade: "upgrade"
            case .overwrite: "overwrite"
            }
        }

        var actionLabel: String {
            switch self {
            case .fresh: "新增安装"
            case .upgrade: "升级安装"
            case .overwrite: "覆盖安装"
            }
        }

        var previousVersion: String? {
            switch self {
            case .fresh: nil
            case .upgrade(let v), .overwrite(let v): v
            }
        }
    }

    let sourceURL: URL
    let manifest: DesktopPluginManifest
    let installKind: InstallKind
    let versionComparison: String?
    let approvalReason: String
}


@MainActor
extension DesktopPluginStore {
    func resolveWorkspacePluginSource(path rawPath: String, workspaceDirectory: URL? = nil) throws -> URL {
        let rootDirectory = workspaceDirectory ?? self.workspaceDirectory
        var trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\"),
              !trimmed.contains("\0"),
              !trimmed.contains("//") else {
            throw DesktopRuntimeError.message("工作区插件路径无效或包含越界访问：\(rawPath)")
        }
        if trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DesktopRuntimeError.message("工作区插件路径无效或包含越界访问：\(rawPath)")
        }

        let fm = FileManager.default
        if let kind = try? fm.attributesOfItem(atPath: rootDirectory.path)[.type],
           kind as? FileAttributeType == .typeSymbolicLink {
            throw DesktopRuntimeError.message("工作区路径不能包含符号链接。")
        }
        let standardizedRoot = rootDirectory.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(rootDirectory.lastPathComponent, isDirectory: true)

        var current = standardizedRoot
        for component in components {
            current.appendPathComponent(String(component))
            if let kind = try? fm.attributesOfItem(atPath: current.path)[.type],
               kind as? FileAttributeType == .typeSymbolicLink {
                throw DesktopRuntimeError.message("工作区插件路径不能包含符号链接：\(rawPath)")
            }
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: current.path, isDirectory: &isDir) else {
            throw DesktopRuntimeError.message("工作区中找不到插件路径：\(rawPath)")
        }
        let resolvedCurrent = current.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedCurrent.path.hasPrefix(standardizedRoot.path + "/") else {
            throw DesktopRuntimeError.message("插件路径越出了当前会话工作区：\(rawPath)")
        }

        let manifestURL: URL
        let scriptURL: URL
        if isDir.boolValue {
            if let entries = try? fm.contentsOfDirectory(atPath: current.path) {
                for entry in entries {
                    let entryURL = current.appendingPathComponent(entry)
                    if let kind = try? fm.attributesOfItem(atPath: entryURL.path)[.type],
                       kind as? FileAttributeType == .typeSymbolicLink {
                        throw DesktopRuntimeError.message("工作区插件目录不能包含符号链接：\(entry)")
                    }
                }
            }
            manifestURL = current.appendingPathComponent("plugin.json")
            scriptURL = current.appendingPathComponent("main.js")
        } else {
            guard current.lastPathComponent == "plugin.json" else {
                throw DesktopRuntimeError.message("插件安装路径须为插件目录或 plugin.json：\(rawPath)")
            }
            manifestURL = current
            scriptURL = current.deletingLastPathComponent().appendingPathComponent("main.js")
        }

        if let kind = try? fm.attributesOfItem(atPath: manifestURL.path)[.type],
           kind as? FileAttributeType == .typeSymbolicLink {
            throw DesktopRuntimeError.message("工作区插件文件不能是符号链接：plugin.json")
        }
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw DesktopRuntimeError.message("插件目录缺少 plugin.json。")
        }
        guard manifestURL.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(standardizedRoot.path + "/") else {
            throw DesktopRuntimeError.message("plugin.json 越出了当前会话工作区。")
        }

        if let attrs = try? fm.attributesOfItem(atPath: scriptURL.path) {
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw DesktopRuntimeError.message("工作区插件脚本不能是符号链接：main.js")
            }
            guard scriptURL.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(standardizedRoot.path + "/") else {
                throw DesktopRuntimeError.message("main.js 越出了当前会话工作区。")
            }
        }

        return isDir.boolValue ? current : current.deletingLastPathComponent()
    }

    func preparePluginInstall(argumentsJSON: String, workspaceDirectory: URL? = nil) throws -> DesktopPreparedPluginInstall {
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DesktopRuntimeError.message("plugin_install 参数须为合法 JSON 对象。")
        }
        let rawPath = ((args["path"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            throw DesktopRuntimeError.message("plugin_install 缺少必填参数 path。")
        }
        let overwrite = (args["overwrite"] as? Bool) == true
        let sourceURL = try resolveWorkspacePluginSource(path: rawPath, workspaceDirectory: workspaceDirectory)
        let plan = try inspectPluginPackage(at: sourceURL)
        let manifest = plan.manifest

        let installKind: DesktopPreparedPluginInstall.InstallKind
        let versionComparison: String?
        if let existing = plugins.first(where: { $0.id == manifest.id && !$0.isBuiltIn }) {
            let oldVersion = existing.manifest.version
            let newVersion = manifest.version
            let comparison = "v\(oldVersion) → v\(newVersion)"
            let isUpgrade = Self.compareVersions(newVersion, oldVersion) == .orderedDescending
            let kind: DesktopPreparedPluginInstall.InstallKind = isUpgrade
                ? .upgrade(previousVersion: oldVersion)
                : .overwrite(previousVersion: oldVersion)
            guard overwrite else {
                throw DesktopRuntimeError.message(
                    "同名插件「\(manifest.name)」（\(manifest.id)）已安装（\(kind.actionLabel)：\(comparison)）。不能静默覆盖，请核对版本差异后显式传入 overwrite=true。"
                )
            }
            installKind = kind
            versionComparison = comparison
        } else {
            installKind = .fresh
            versionComparison = nil
        }

        let approvalReason = Self.buildInstallApprovalReason(
            manifest: manifest,
            installKind: installKind,
            versionComparison: versionComparison,
            permissionSummary: manifest.isV3 ? plan.humanReadableSummaryLines : []
        )
        return DesktopPreparedPluginInstall(
            sourceURL: sourceURL,
            manifest: manifest,
            installKind: installKind,
            versionComparison: versionComparison,
            approvalReason: approvalReason
        )
    }

    func executePluginInstall(argumentsJSON: String, workspaceDirectory: URL? = nil) throws -> String {
        let prepared = try preparePluginInstall(argumentsJSON: argumentsJSON, workspaceDirectory: workspaceDirectory)
        let installedID = try importPlugin(from: prepared.sourceURL)
        let installed = plugins.first(where: { $0.id == installedID })
        let enabled = installed?.enabled ?? true
        let qualifiedTools = prepared.manifest.tools.map { tool in
            installed?.qualifiedToolName(tool.name) ?? "plugin__\(installedID)__\(tool.name)"
        }
        let summaryMessage: String
        if let comparison = prepared.versionComparison {
            summaryMessage = "已完成\(prepared.installKind.actionLabel)「\(prepared.manifest.name)」（\(installedID)，\(comparison)），当前状态：\(enabled ? "已启用" : "已停用")。"
        } else {
            summaryMessage = "已安装插件「\(prepared.manifest.name)」（\(installedID)，v\(prepared.manifest.version)），当前状态：\(enabled ? "已启用" : "已停用")。"
        }
        var payload: [String: Any] = [
            "ok": true,
            "id": installedID,
            "name": prepared.manifest.name,
            "version": prepared.manifest.version,
            "enabled": enabled,
            "action": prepared.installKind.actionCode,
            "action_label": prepared.installKind.actionLabel,
            "version_comparison": prepared.versionComparison ?? "v\(prepared.manifest.version)",
            "tools": qualifiedTools,
            "message": summaryMessage
        ]
        if let previousVersion = prepared.installKind.previousVersion {
            payload["previous_version"] = previousVersion
        }
        return try Self.encodeJSONObject(payload)
    }

    func executePluginList() throws -> String {
        let items: [[String: Any]] = plugins.map { plugin in
            let tools: [[String: Any]] = plugin.manifest.tools.map { tool in
                [
                    "name": tool.name,
                    "qualified_name": plugin.qualifiedToolName(tool.name),
                    "effect": tool.effect.rawValue
                ]
            }
            return [
                "id": plugin.id,
                "name": plugin.manifest.name,
                "version": plugin.manifest.version,
                "enabled": plugin.enabled,
                "is_built_in": plugin.isBuiltIn,
                "description": plugin.manifest.description,
                "schema": plugin.manifest.schema,
                "permissions": DesktopPluginPermissionCatalog.canonicalPermissions(for: plugin.manifest).sorted(),
                "approved_permissions": approvedPermissions(for: plugin.id).sorted(),
                "views": plugin.manifest.ui.views.map { ["id": $0.id, "title": $0.title, "slot": $0.slot.rawValue, "entry": $0.entry] },
                "tools": tools,
                "capabilities": [
                    "networkDomains": plugin.manifest.capabilities.networkDomains,
                    "workspaceReadPrefixes": plugin.manifest.capabilities.workspaceReadPrefixes,
                    "workspaceWritePrefixes": plugin.manifest.capabilities.workspaceWritePrefixes
                ]
            ]
        }
        return try Self.encodeJSONObject([
            "ok": true,
            "count": items.count,
            "enabled_count": plugins.filter(\.enabled).count,
            "plugins": items
        ])
    }

    nonisolated static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        let lhsParts = lhs.split(whereSeparator: { $0 == "." || $0 == "-" })
        let rhsParts = rhs.split(whereSeparator: { $0 == "." || $0 == "-" })
        let count = max(lhsParts.count, rhsParts.count)
        for index in 0..<count {
            let lPart = index < lhsParts.count ? String(lhsParts[index]) : "0"
            let rPart = index < rhsParts.count ? String(rhsParts[index]) : "0"
            if let lNum = Int(lPart), let rNum = Int(rPart) {
                if lNum != rNum {
                    return lNum < rNum ? .orderedAscending : .orderedDescending
                }
            } else if lPart != rPart {
                return lPart.localizedStandardCompare(rPart)
            }
        }
        return .orderedSame
    }

    nonisolated private static func buildInstallApprovalReason(
        manifest: DesktopPluginManifest,
        installKind: DesktopPreparedPluginInstall.InstallKind,
        versionComparison: String?,
        permissionSummary: [String]
    ) -> String {
        let header: String
        switch installKind {
        case .fresh:
            header = "即将安装插件「\(manifest.name)」（ID: \(manifest.id)，版本 v\(manifest.version)）"
        case .upgrade:
            header = "即将升级已有插件「\(manifest.name)」（ID: \(manifest.id)，版本 \(versionComparison ?? "v\(manifest.version)")）"
        case .overwrite:
            header = "即将覆盖已有插件「\(manifest.name)」（ID: \(manifest.id)，版本 \(versionComparison ?? "v\(manifest.version)")）"
        }

        let networkSummary: String
        if manifest.capabilities.networkDomains.isEmpty {
            networkSummary = "网络权限：无外部网络访问"
        } else {
            networkSummary = "网络权限：仅限访问 HTTPS 域名 \(manifest.capabilities.networkDomains.joined(separator: "、"))"
        }

        var workspaceParts: [String] = []
        if !manifest.capabilities.workspaceReadPrefixes.isEmpty {
            workspaceParts.append("读取工作区前缀 [\(manifest.capabilities.workspaceReadPrefixes.joined(separator: ", "))]")
        }
        if !manifest.capabilities.workspaceWritePrefixes.isEmpty {
            workspaceParts.append("写入工作区前缀 [\(manifest.capabilities.workspaceWritePrefixes.joined(separator: ", "))]")
        }
        let workspaceSummary = workspaceParts.isEmpty
            ? "工作区文件权限：无工作区文件读写权限"
            : "工作区文件权限：\(workspaceParts.joined(separator: "，"))"

        let toolsSummary: String
        if manifest.tools.isEmpty {
            toolsSummary = "注册工具：无"
        } else {
            let list = manifest.tools.map { "\($0.name)(\($0.effect.rawValue))" }.joined(separator: "、")
            toolsSummary = "注册工具：\(list)"
        }

        let v3Summary = permissionSummary.isEmpty ? "" : "v3 权限：" + permissionSummary.joined(separator: "；") + "；"
        return "\(header)。申请权限 — \(v3Summary) \(networkSummary)；\(workspaceSummary)；\(toolsSummary)。请在 Mac 上核对后批准或拒绝。"
    }

}
