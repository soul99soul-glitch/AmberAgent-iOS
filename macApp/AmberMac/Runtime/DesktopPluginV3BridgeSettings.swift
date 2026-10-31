import Foundation

// MARK: - Bridge RPC: `settings` Namespace

extension DesktopPluginStore {
    func handleSettingsBridgeCall(
        plugin: DesktopInstalledPlugin,
        method: String,
        args: [Any]
    ) throws -> String {
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
    }
}
