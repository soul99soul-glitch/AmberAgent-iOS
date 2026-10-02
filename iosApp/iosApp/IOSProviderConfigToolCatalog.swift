import Foundation
@preconcurrency import Shared

enum IOSProviderConfigToolCatalog {
    static let toolNames: Set<String> = [
        "provider_config_status",
        "provider_config_apply",
        "provider_config_create",
        "provider_refresh_models",
        "settings_set_model_slot",
    ]
    static let mutatingToolNames: Set<String> = [
        "provider_config_apply",
        "provider_config_create",
        "provider_refresh_models",
        "settings_set_model_slot",
    ]
    /// Writes that touch credentials or create providers need a foreground approval card.
    static let highRiskToolNames: Set<String> = [
        "provider_config_apply",
        "provider_config_create",
    ]
    static let backgroundAllowedToolNames: Set<String> = [
        "provider_config_status",
    ]

    /// Redact secrets in tool arguments while keeping valid JSON (for persistence
    /// and re-upload). Approval cards may further truncate via truncatedMcpArguments.
    static func redactedArgumentsJSON(_ argumentsJSON: String) -> String {
        var args = ChatToolCallParsing.jsonObject(argumentsJSON) ?? [:]
        if args.keys.contains("api_key") {
            if let raw = args["api_key"] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    args["api_key"] = "(clear)"
                } else if trimmed.count <= 4 {
                    args["api_key"] = "****"
                } else {
                    args["api_key"] = "****\(String(trimmed.suffix(4)))"
                }
            } else {
                args["api_key"] = "(redacted)"
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Approval snapshots are durable before the tool runs. Keep the live
    /// in-memory call intact for the approved write, but never persist or
    /// re-upload a plaintext provider key while waiting for that approval.
    static func redactedApprovalMessages(_ messages: [UIMessage]) -> [UIMessage] {
        messages.map { message in
            var changed = false
            let parts = message.parts.map { part -> UIMessagePart in
                guard let tool = part as? UIMessagePart.Tool,
                      highRiskToolNames.contains(tool.toolName) else {
                    return part
                }
                changed = true
                return PromptTranscript.shared.doCopyTool(
                    tool: tool,
                    input: redactedArgumentsJSON(tool.input),
                    output: tool.output
                )
            }
            guard changed else { return message }
            return UIMessage(
                id: message.id,
                role: message.role,
                parts: parts,
                annotations: message.annotations,
                createdAt: message.createdAt,
                finishedAt: message.finishedAt,
                modelId: message.modelId,
                usage: message.usage,
                translation: message.translation
            )
        }
    }

    /// Approval-card preview that never echoes raw API keys.
    static func redactedApprovalPreview(argumentsJSON: String) -> String {
        ChatToolCallParsing.truncatedMcpArguments(
            ChatToolCallParsing.jsonObject(redactedArgumentsJSON(argumentsJSON)) ?? [:]
        )
    }

    static func approvalReason(argumentsJSON: String) -> String {
        let args = ChatToolCallParsing.jsonObject(argumentsJSON) ?? [:]
        var parts: [String] = ["将写入本机 LLM 提供商配置，需要你确认。"]
        if let name = args["provider_name"] as? String, !name.isEmpty {
            parts.append("目标：\(name)")
        } else if let id = args["provider_id"] as? String, !id.isEmpty {
            parts.append("目标 id：\(String(id.prefix(8)))…")
        }
        if args.keys.contains("api_key") {
            let raw = (args["api_key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(raw.isEmpty ? "将清除 API Key。" : "将更新 API Key（仅显示尾号）。")
        }
        if let base = args["base_url"] as? String, !base.isEmpty {
            let host = URL(string: base)?.host ?? base
            parts.append("将改 endpoint host：\(host)")
        }
        return parts.joined(separator: " ")
    }
}
