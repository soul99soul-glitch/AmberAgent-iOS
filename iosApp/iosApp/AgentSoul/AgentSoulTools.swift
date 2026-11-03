import Foundation

/// `agent_soul_get` / `agent_soul_update` 的工具目录。
enum AgentSoulToolCatalog {
    static let getToolName = "agent_soul_get"
    static let updateToolName = "agent_soul_update"

    static let toolNames: Set<String> = [getToolName, updateToolName]
    /// 读工具免审批；更新工具按产品决定免审批直通，便于对话中自然演进人设。
    static let mutatingToolNames: Set<String> = [updateToolName]
}

/// 对话内自塑人设的执行器。
///
/// 产品取舍：`agent_soul_update` 刻意**不**走高风险审批——用户会在对话里直接说
/// 「你给自己写个赵大哥人设吧」，此时弹一次审批会把体验打断。代价是写操作无确认，
/// 因此每次更新都会把旧版压入快照栈，可一键回退。
@MainActor
struct AgentSoulToolService {
    let store: AgentSoulStore

    func execute(toolName: String, arguments: String) -> String {
        let args = ChatToolCallParsing.jsonObject(arguments) ?? [:]
        switch toolName {
        case AgentSoulToolCatalog.getToolName:
            return soulJSON()
        case AgentSoulToolCatalog.updateToolName:
            return update(args)
        default:
            return Self.errorJSON("unknown_tool", "未知的 soul 工具：\(toolName)")
        }
    }

    private func soulJSON() -> String {
        let payload: [String: Any] = [
            "status": "ok",
            "displayName": store.displayName,
            "tagline": store.tagline,
            "soulPrompt": store.soulPrompt,
            "updatedAtMs": store.updatedAtMs,
            "source": store.source.rawValue,
            "isDefault": store.isDefault,
            "snapshotCount": store.snapshots.count,
            "snapshotDigest": store.snapshotDigest,
        ]
        return Self.jsonString(payload)
    }

    private func update(_ args: [String: Any]) -> String {
        let displayName = (args["displayName"] as? String) ?? ""
        let tagline = args["tagline"] as? String
        let soulPrompt = (args["soulPrompt"] as? String) ?? ""
        let summary = args["summary"] as? String

        // 允许只传 soulPrompt：称呼回退到当前值，避免调用方漏参把名字清空。
        let resolvedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? store.displayName
            : displayName

        guard soulPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || resolvedName != store.displayName
            || (tagline?.isEmpty == false) else {
            return Self.errorJSON("empty_update", "soulPrompt 与 displayName 不能同时为空。")
        }

        let changed = store.update(
            displayName: resolvedName,
            tagline: tagline ?? store.tagline,
            soulPrompt: soulPrompt.isEmpty ? store.soulPrompt : soulPrompt,
            summary: summary,
            source: .conversation
        )

        let payload: [String: Any] = [
            "status": "ok",
            "changed": changed,
            "displayName": store.displayName,
            "tagline": store.tagline,
            "soulPrompt": store.soulPrompt,
            "snapshotCount": store.snapshots.count,
        ]
        return Self.jsonString(payload)
    }

    // MARK: - JSON

    private static func errorJSON(_ code: String, _ message: String) -> String {
        jsonString(["status": "error", "error_code": code, "message": message])
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            return #"{"status":"error","error_code":"encoding_failed"}"#
        }
        return text
    }
}
