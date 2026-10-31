import Foundation

// MARK: - Bridge RPC: `workspace` Namespace

extension DesktopPluginStore {
    func handleWorkspaceBridgeCall(
        plugin: DesktopInstalledPlugin,
        runtimeHost: DesktopPluginRuntimeHost?,
        method: String,
        args: [Any],
        workspaceDirectory: URL,
        activeToolEffect: DesktopToolEffect?
    ) throws -> String {
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
    }

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
}
