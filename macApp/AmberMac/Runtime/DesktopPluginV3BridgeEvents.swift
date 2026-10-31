import Foundation

// MARK: - Bridge RPC: `events` Namespace

extension DesktopPluginStore {
    func handleEventsBridgeCall(
        plugin: DesktopInstalledPlugin,
        runtimeHost: DesktopPluginRuntimeHost?,
        method: String,
        args: [Any]
    ) throws -> String {
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
    }
}
