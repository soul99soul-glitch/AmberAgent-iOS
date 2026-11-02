import Foundation

// MARK: - Bridge RPC: `commands` Namespace

extension DesktopPluginStore {
    func handleCommandsBridgeCall(
        plugin: DesktopInstalledPlugin,
        runtimeHost: DesktopPluginRuntimeHost?,
        method: String,
        args: [Any]
    ) throws -> String {
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
    }
}
