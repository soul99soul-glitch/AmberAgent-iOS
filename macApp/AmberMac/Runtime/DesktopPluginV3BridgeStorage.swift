import Foundation

// MARK: - Bridge RPC: `storage` Namespace

extension DesktopPluginStore {
    func handleStorageBridgeCall(
        plugin: DesktopInstalledPlugin,
        method: String,
        args: [Any]
    ) throws -> String {
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
    }
}
