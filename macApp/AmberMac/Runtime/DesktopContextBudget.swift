import Foundation

/// Deterministic request budget for the macOS chat path.
///
/// It only ever projects the request: stored history is never rewritten, and every cut happens at a user
/// turn so an assistant `tool_use` block and its `tool_result` reply are never separated.
enum DesktopContextBudget {
    /// One blocking trigger, matching iOS `IOSCompactPolicy`'s effective `forceRatio`.
    static let autoCompactionRatio = 0.85
    /// Headroom kept for the reply when the model has no explicit output cap.
    static let defaultOutputReserve = 8_192
    private static let minimumBudget = 1_024

    struct Fit: Equatable, Sendable {
        let messages: [DesktopMessage]
        let droppedCount: Int

        var trimmed: Bool { droppedCount > 0 }
    }

    /// Token estimate for a request; `extraText` carries the system prompt and the current draft.
    static func estimate<S: Sequence>(_ messages: S, extraText: String = "") -> Int where S.Element == DesktopMessage {
        messages.reduce(0) { $0 + ($1.estimatedTokens ?? textTokens($1.text + $1.reasoning)) + 4 } + textTokens(extraText)
    }

    /// The prompt budget for a model: its window minus the reply headroom it may use. The reserve never
    /// takes more than half the window, so a small window still leaves a usable prompt budget.
    static func promptBudget(for model: DesktopModelConfiguration?) -> Int? {
        guard let limit = model?.contextWindowTokens, limit > 0 else { return nil }
        let reserve = min(model?.maxOutputTokens ?? defaultOutputReserve, limit / 2)
        return max(minimumBudget, limit - reserve)
    }

    /// True when this conversation is close enough to the window that a summary should be produced
    /// before the next turn. Requires a model window; without one there is nothing to measure against.
    static func needsCompaction<S: Sequence>(_ messages: S, model: DesktopModelConfiguration?, extraText: String = "") -> Bool where S.Element == DesktopMessage {
        guard let limit = model?.contextWindowTokens, limit > 0 else { return false }
        return estimate(messages, extraText: extraText) >= Int(Double(limit) * autoCompactionRatio)
    }

    /// Oldest index a compaction may start from, so the summary keeps the tail verbatim and never
    /// splits a tool round trip. Mirrors the manual compaction rule (keep the last two user turns).
    static func compactionBoundary(_ messages: [DesktopMessage]) -> Int? {
        let userStarts = messages.indices.filter { messages[$0].role == .user }
        guard userStarts.count > 2 else { return nil }
        let boundary = userStarts[userStarts.count - 2]
        // The cut lands on a user turn; a tool call and its result always sit after it.
        return messages[boundary].role == .user ? boundary : nil
    }

    /// Drops the oldest turns until the request fits the budget.
    ///
    /// Two things are never trimmed: the leading run of system messages (the stable prefix and any compaction
    /// summary, which come first) and the newest user turn. Trimming therefore starts at the first user turn
    /// after that block, so a request always keeps its system rules. When even the remaining tail is too large
    /// there is nothing left to trim and the provider decides.
    static func fitting(_ messages: [DesktopMessage], model: DesktopModelConfiguration?,
                        extraText: String = "") -> Fit {
        guard let budget = promptBudget(for: model) else { return Fit(messages: messages, droppedCount: 0) }
        let userStarts = messages.indices.filter { messages[$0].role == .user }
        guard var start = userStarts.first, let lastUser = userStarts.last else {
            return Fit(messages: messages, droppedCount: 0)
        }
        var dropped = 0
        for candidate in userStarts where candidate > start {
            guard estimate(messages[start...], extraText: extraText) > budget else { break }
            guard candidate <= lastUser else { break }
            dropped += candidate - start
            start = candidate
        }
        guard dropped > 0 else { return Fit(messages: messages, droppedCount: 0) }
        // Everything before the first user turn is the pinned system block; it is kept verbatim.
        let pinned = messages[..<userStarts[0]]
        return Fit(messages: Array(pinned) + Array(messages[start...]), droppedCount: dropped)
    }

    /// Stable fingerprint of the turn-invariant part of a request: the system block plus the earliest turns
    /// that never change. Equal fingerprints mean a provider that supports prefix caching can reuse it.
    static func prefixFingerprint(_ messages: [DesktopMessage]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ bytes: some Sequence<UInt8>) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        // Only the text, never the message id: every turn builds a fresh UUID, so mixing ids made the fingerprint
        // change on every request and no provider prefix cache could ever hit.
        for message in messages.prefix(while: { $0.role == .system }) {
            mix(String(describing: message.role).utf8)
            mix([0x1f]) // field separator so "ab"+"c" and "a"+"bc" differ
            mix(message.text.utf8)
        }
        return hash
    }

    /// Providers report a context overflow with different wording; recognise the ones Amber can act on.
    static func isContextOverflow(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return ["context length", "context_length", "maximum context", "context window",
                "too many tokens", "prompt is too long", "exceeds the maximum", "input is too long",
                "tokens exceed", "context size"].contains { lowered.contains($0) }
    }

    private static func textTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        // Same CJK weighting as the iOS compaction estimator; this is not a tokenizer.
        let weighted = text.unicodeScalars.reduce(0) { total, scalar in
            let cjk = (0x3400...0x9FFF).contains(scalar.value)
                || (0x20000...0x2FA1F).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
            return total + (cjk ? 4 : 1)
        }
        return max((weighted + 3) / 4, 1)
    }
}

/// Provider-reported token usage for one finished message, read from the canonical payload the KMP
/// provider wrote. `cachedTokens` is only meaningful when the provider reports prompt caching at all.
struct DesktopTokenUsage: Equatable, Sendable {
    var promptTokens: Int
    var cachedTokens: Int

    var cacheHitRatio: Double? {
        guard promptTokens > 0, cachedTokens > 0 else { return nil }
        return min(1, Double(cachedTokens) / Double(promptTokens))
    }

    static func decode(_ message: DesktopMessage?) -> DesktopTokenUsage? {
        guard let json = message?.canonicalJSON,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else { return nil }
        let prompt = usage["promptTokens"] as? Int ?? 0
        guard prompt > 0 else { return nil }
        return DesktopTokenUsage(promptTokens: prompt, cachedTokens: usage["cachedTokens"] as? Int ?? 0)
    }

    /// The newest finished assistant reply that carries usage, newest first.
    static func latest(in messages: [DesktopMessage]) -> DesktopTokenUsage? {
        for message in messages.reversed() where message.role == .assistant {
            if let usage = decode(message) { return usage }
        }
        return nil
    }
}

/// Decides when an idle, over-budget conversation is summarised again.
///
/// Kept separate from the workspace so the agent loop can change independently, and so the cooldown rule is
/// testable without a provider: a failed attempt must not be retried on every following turn.
struct DesktopAutoCompactionPolicy {
    /// How long a failed attempt waits before it may try again.
    var cooldown: TimeInterval = 90
    private var retryAfter: [UUID: Date] = [:]

    func mayCompact(_ owner: UUID, now: Date = Date()) -> Bool {
        guard let deadline = retryAfter[owner] else { return true }
        // Compare as an interval rather than with `Date.>=`: the operator symbol resolves to a missing
        // Foundation symbol on this Xcode 27 SDK/runtime pairing and traps with EXC_BAD_ACCESS.
        return now.timeIntervalSince(deadline) >= 0
    }

    mutating func record(_ owner: UUID, succeeded: Bool, now: Date = Date()) {
        if succeeded { retryAfter[owner] = nil }
        else { retryAfter[owner] = now.addingTimeInterval(cooldown) }
    }

    mutating func forget(_ owner: UUID) { retryAfter[owner] = nil }
}
