import Foundation

// MARK: - Bridge RPC: `agent` Namespace

extension DesktopPluginStore {
    func handleAgentBridgeCall(
        plugin: DesktopInstalledPlugin,
        runtimeHost: DesktopPluginRuntimeHost?,
        method: String,
        args: [Any]
    ) throws -> String {
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
    }
}
