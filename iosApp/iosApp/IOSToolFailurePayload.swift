import Foundation

/// Structured tool-failure output shared by the chat tool runtime and the
/// reusable agent tool engine.
enum IOSToolFailurePayload {
    nonisolated static func json(
        toolName: String,
        reason: String,
        denied: Bool = false,
        cancelled: Bool = false,
        status: String? = nil
    ) -> String {
        var payload: [String: Any] = [
            "ok": false,
            "tool": toolName,
            "reason": reason
        ]
        if let status {
            payload["status"] = status
        }
        if denied {
            payload["denied"] = true
            payload["policy"] = "user_denied"
        }
        if cancelled {
            payload["cancelled"] = true
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(toolName) failed: \(reason)"
        }
        return text
    }
}
