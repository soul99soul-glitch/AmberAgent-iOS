import Foundation

/// One transcript hit. `stale` means an active summary already replaced this turn: the original wording is
/// still readable, but the model should treat the summary as the current view and fetch here for exact facts.
struct DesktopHistoryHit: Equatable, Sendable {
    let messageID: UUID
    let index: Int
    let role: String
    let snippet: String
    let stale: Bool
}

/// Search and fetch over the stored conversation, including the turns a compaction folded away.
enum DesktopHistoryTools {
    static let maxResults = 12
    static let maxSnippetCharacters = 240
    static let maxFetchCharacters = 4_000

    /// One hit per message, even when several fields match: a deduplicated list is what the model can act on.
    static func search(query: String, in messages: [DesktopMessage], covered: Set<UUID>,
                       limit: Int = 8) -> [DesktopHistoryHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let capped = min(max(1, limit), maxResults)
        var hits: [DesktopHistoryHit] = []
        for (index, message) in messages.enumerated() {
            let text = [message.text, message.reasoning].filter { !$0.isEmpty }.joined(separator: "\n")
            var snippet: String?
            if let range = text.lowercased().range(of: needle) {
                snippet = Self.snippet(text, around: range)
            } else if let tool = message.tools.first(where: { Self.toolMatches($0, needle: needle) }) {
                // A tool round trip keeps the exact error, exit code and output in the projection, not in the
                // message text; searching only `input` lost the half of the value that matters most.
                snippet = Self.snippet(Self.toolBlob(tool, needle: needle))
            }
            guard let snippet else { continue }
            hits.append(DesktopHistoryHit(messageID: message.id, index: index, role: message.role.rawValue,
                snippet: DesktopHistoryRedaction.redact(snippet), stale: covered.contains(message.id)))
            if hits.count == capped { break }
        }
        return hits
    }

    private static func toolMatches(_ tool: DesktopToolCall, needle: String) -> Bool {
        [tool.name, tool.input, tool.output, tool.status.rawValue]
            .contains { $0.lowercased().contains(needle) }
    }

    /// Name, arguments and output together: the caller wants the whole round trip, and the searched field is
    /// already inside the snippet so the match is visible.
    private static func toolBlob(_ tool: DesktopToolCall, needle: String) -> String {
        let head = "\(tool.name) [\(tool.status.rawValue)]"
        let fields = [tool.input, tool.output].filter { !$0.isEmpty }
        // Put the field that actually matched first, so a long output cannot push the hit out of the window.
        let ordered = fields.sorted {
            $0.lowercased().contains(needle) && !$1.lowercased().contains(needle)
        }
        return ([head] + ordered).joined(separator: "\n")
    }

    static func fetch(_ messageID: UUID, in messages: [DesktopMessage], covered: Set<UUID>) throws -> [String: Any] {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            throw DesktopRuntimeError.message("这条消息不在当前会话记录中；请用 history_search 重新定位。")
        }
        let message = messages[index]
        let text = [message.text, message.reasoning].filter { !$0.isEmpty }.joined(separator: "\n")
        // A pasted key or token in an old turn must not come back verbatim into the model context; every other
        // tool output goes through the same redactor.
        let safe = DesktopHistoryRedaction.redact(text)
        return [
            "ok": true,
            "message_id": message.id.uuidString.lowercased(),
            "role": message.role.rawValue,
            "index": index,
            "stale": covered.contains(message.id),
            "text": String(safe.prefix(maxFetchCharacters)),
            "truncated": safe.count > maxFetchCharacters,
            "redacted": safe != text,
        ]
    }

    static func hitsJSON(_ hits: [DesktopHistoryHit]) throws -> String {
        let payload: [[String: Any]] = hits.map { hit in
            ["message_id": hit.messageID.uuidString.lowercased(), "index": hit.index,
             "role": hit.role, "snippet": hit.snippet, "stale": hit.stale]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func snippet(_ text: String, around range: Range<String.Index>? = nil) -> String {
        let limit = maxSnippetCharacters
        guard text.count > limit else { return text }
        let center = range.map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
        let start = max(0, min(text.count - limit, center - limit / 3))
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(lower, offsetBy: min(limit, text.count - start))
        return (start > 0 ? "…" : "") + String(text[lower..<upper]) + (upper < text.endIndex ? "…" : "")
    }
}


/// A `history_fetch` can return text the user pasted or a tool printed, which may contain a live key.
/// `IOSCredentialRedactor` masks values by their *key* in a settings tree; free text needs value-shaped patterns,
/// so both run here: JSON payloads go through the shared redactor, and inline tokens are masked by shape.
enum DesktopHistoryRedaction {
    static let mask = "«已脱敏»"

    /// Well-known token shapes. Deliberately narrow: a false positive only costs readability, but a miss hands a
    /// live credential to the model and then to the provider.
    private static let patterns: [String] = [
        // Anthropic / OpenAI-style keys, including sk-ant-api03-…
        #"\bsk-[A-Za-z0-9_\-]{16,}"#,
        // Bearer tokens in a header dump.
        #"(?i)\bBearer\s+[A-Za-z0-9._\-]{12,}"#,
        // GitHub / GitLab / Slack / generic provider prefixes with a long opaque tail.
        #"\b(?:gh[pousr]_[A-Za-z0-9]{16,}|glpat-[A-Za-z0-9_\-]{16,}|xox[abprs]-[A-Za-z0-9\-]{10,})"#,
        // AWS access key ids and Google API keys.
        #"\b(?:AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{30,})"#,
        // JWT: three base64url segments.
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        // `api_key=…` / `token: …` style assignments, keeping the label for context.
        #"(?i)\b(api[_\- ]?key|access[_\- ]?token|secret[_\- ]?key|password)\b\s*[:=]\s*["'"]?([A-Za-z0-9._\-/+=]{12,})"#,
    ]

    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            // Replace from the back so earlier ranges stay valid.
            for match in regex.matches(in: result, range: range).reversed() {
                let target = match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound
                    ? match.range(at: 2) : match.range
                guard let swiftRange = Range(target, in: result) else { continue }
                result.replaceSubrange(swiftRange, with: mask)
            }
        }
        return result
    }

    /// Rejects redacted placeholders (`<redacted>`, `[REDACTED]`, `***`, `••••`, `«已脱敏»`) so a model or UI copy
    /// never overwrites a real credential in Keychain.
    static func isPlaceholderCredential(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        if lowered == "<redacted>" || lowered == "[redacted]" || lowered == "redacted" || trimmed == mask {
            return true
        }
        if trimmed.count >= 3 && trimmed.allSatisfy({ $0 == "*" || $0 == "•" || $0 == "·" }) {
            return true
        }
        return false
    }
}
