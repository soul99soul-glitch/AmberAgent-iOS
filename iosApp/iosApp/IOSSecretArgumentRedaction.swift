import Foundation
@preconcurrency import Shared

/// Secret-argument redaction shared by the chat runtime, the reusable tool
/// engine and the Novel target.
///
/// Deliberately dependency-free: only Foundation plus the `Shared` model types
/// (`UIMessage`, `UIMessagePart`, `PromptTranscript`), so it compiles into both
/// `iosApp` and `AmberNovel` without dragging in catalog types that exist only
/// in the main app. Tool names are plain string constants owned here.
///
/// Contract: a tool result, a persisted tool call, a re-uploaded transcript and
/// an approval preview must never contain a password or private key. The live
/// in-memory call keeps its original arguments so an approved write still has
/// them; everything that is published, checkpointed or shown is redacted first.
enum IOSSecretArgumentRedaction {
    /// Marker written in place of a credential. Chosen to be obviously not a
    /// credential so an accidental write fails closed instead of storing it.
    static let replacement = "[redacted]"

    /// Tools whose arguments may carry a password, private key, passphrase,
    /// or perform high-risk local SSH key/profile mutations.
    static let credentialToolNames: Set<String> = [
        "ssh_profile_create",
        "ssh_profile_update",
        "ssh_profile_delete",
        "ssh_key_generate",
        "ssh_key_import",
        "ssh_key_delete",
    ]

    static let secretArgumentKeys: Set<String> = ["password", "private_key", "passphrase"]

    static let placeholderLiterals: Set<String> = [
        "[redacted]",
        "<redacted>",
        "***",
        "••••",
        "(empty)",
    ]

    static func carriesCredential(_ toolName: String) -> Bool {
        credentialToolNames.contains(toolName)
    }

    /// Rejects any redaction placeholder literal (`[redacted]`, `<redacted>`,
    /// `***`, `••••`, `(empty)`) so a model or a cold-restored approval snapshot
    /// can never write a placeholder into Keychain as a real secret.
    static func isRedactionPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if placeholderLiterals.contains(lower) || placeholderLiterals.contains(trimmed) {
            return true
        }
        if lower.contains("[redacted]") || lower.contains("<redacted>") {
            return true
        }
        return false
    }

    /// Returns true when any secret argument in `argumentsJSON` is a redaction placeholder.
    static func containsRedactedSecretArgument(_ argumentsJSON: String) -> Bool {
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        for key in secretArgumentKeys {
            if let raw = args[key] as? String, !raw.isEmpty, isRedactionPlaceholder(raw) {
                return true
            }
        }
        return false
    }

    /// Replaces credential arguments with a status marker while keeping valid
    /// JSON. Returns the input unchanged when no credential argument is present.
    static func redactedArgumentsJSON(_ argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              var args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "{}"
        }
        var changed = false
        for key in secretArgumentKeys where args.keys.contains(key) {
            let raw = (args[key] as? String) ?? ""
            args[key] = raw.isEmpty ? "(empty)" : replacement
            changed = true
        }
        guard changed else { return argumentsJSON }
        guard let redacted = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
              let text = String(data: redacted, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Redacts every credential-carrying tool call in a message list. Used
    /// before an assistant turn is published or checkpointed, so a plaintext
    /// password never lands in a durable continuation snapshot or in the UI
    /// store while the call is still waiting for approval.
    static func redactingSecrets(in messages: [UIMessage]) -> [UIMessage] {
        messages.map(redactingSecrets(in:))
    }

    static func redactingSecrets(in message: UIMessage) -> UIMessage {
        var changed = false
        let parts = message.parts.map { part -> UIMessagePart in
            guard let tool = part as? UIMessagePart.Tool,
                  carriesCredential(tool.toolName) else {
                return part
            }
            let redacted = redactedArgumentsJSON(tool.input)
            guard redacted != tool.input else { return part }
            changed = true
            return PromptTranscript.shared.doCopyTool(
                tool: tool,
                input: redacted,
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
