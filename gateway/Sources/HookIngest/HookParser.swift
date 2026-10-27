import Foundation
import GatewayCore

/// Maps a raw hook stdin payload to a `GatewayEvent`. Only metadata is read: tool inputs and assistant messages
/// are never copied out. The one exception is a short excerpt of a submitted prompt, kept as the task's display
/// title on the phone (`GatewayEvent.summary`); push bodies never carry it.
public enum HookParser {
    public static let summaryLimit = 40
    public static let openingLimit = 400

    public static func parse(source: AgentKind, payload: Data, now: Date = Date()) -> GatewayEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let name = object["hook_event_name"] as? String,
              let sessionId = object["session_id"] as? String, !sessionId.isEmpty,
              let kind = kind(source: source, name: name, object: object)
        else { return nil }
        var event = GatewayEvent(
            agent: source,
            kind: kind,
            sessionId: sessionId,
            cwd: object["cwd"] as? String,
            timestamp: now,
            tool: object["tool_name"] as? String
        )
        if kind == .promptSubmit, let prompt = object["prompt"] as? String {
            event.summary = summary(prompt)
            if event.summary != nil { event.opening = excerpt(prompt, limit: openingLimit) }
        }
        return event
    }

    static func summary(_ prompt: String) -> String? {
        let collapsed = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Hosts inject machine turns as prompts (`<task-notification>…`, `<command-name>…`); they name nothing.
        guard !collapsed.isEmpty, !collapsed.hasPrefix("<") else { return nil }
        return excerpt(collapsed, limit: summaryLimit)
    }

    static func excerpt(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
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
