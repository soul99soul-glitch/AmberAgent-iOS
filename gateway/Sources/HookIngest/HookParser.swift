import Foundation
import GatewayCore

/// Maps a raw hook stdin payload to a `GatewayEvent`. Only metadata is read: prompts, tool inputs and
/// assistant messages in the payload are never copied out.
public enum HookParser {
    public static func parse(source: AgentKind, payload: Data, now: Date = Date()) -> GatewayEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let name = object["hook_event_name"] as? String,
              let sessionId = object["session_id"] as? String, !sessionId.isEmpty,
              let kind = kind(source: source, name: name, object: object)
        else { return nil }
        return GatewayEvent(
            agent: source,
            kind: kind,
            sessionId: sessionId,
            cwd: object["cwd"] as? String,
            timestamp: now,
            tool: object["tool_name"] as? String
        )
    }

    static func kind(source: AgentKind, name: String, object: [String: Any]) -> EventKind? {
        switch (source, name) {
        case (_, "SessionStart"): return .sessionStart
        case (_, "UserPromptSubmit"): return .promptSubmit
        case (_, "PermissionRequest"): return .permissionRequest
        case (_, "PostToolUse"): return .toolDone
        case (_, "Stop"): return .turnStop
        case (_, "SessionEnd"): return .sessionEnd
        case (.claude, "StopFailure"): return .turnFailure
        case (.codex, "Interrupt"): return .interrupt
        case (.claude, "Notification"):
            switch object["notification_type"] as? String {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog": return .permissionNotice
            case "idle_prompt", "agent_needs_input": return .idleNotice
            default: return nil
            }
        default:
            return nil
        }
    }
}
