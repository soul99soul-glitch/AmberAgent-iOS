import Foundation

// MARK: - Bridge RPC: `ui` Namespace

extension DesktopPluginStore {
    func handleUIConfirmAsyncBridgeCall(
        plugin: DesktopInstalledPlugin,
        args: [Any]
    ) async throws -> String {
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

    func handleUIBridgeCall(
        plugin: DesktopInstalledPlugin,
        method: String,
        args: [Any]
    ) throws -> String {
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
    }

    func openPluginModal(plugin: DesktopInstalledPlugin, viewID: String, options: [String: Any]) throws -> String {
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
}
