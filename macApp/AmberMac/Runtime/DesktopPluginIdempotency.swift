import Foundation

/// Idempotency for the Feishu write tools (`bot_create_doc`, `bot_send_message`, `create_event`).
///
/// The meeting-closeout loop runs the same two writes after the same review. Re-running it must not post a second
/// copy into the group, so each write may carry a caller-chosen key: the first confirmed result is stored with the
/// key and any later call with that key returns the stored result instead of reaching Feishu again.
enum DesktopFeishuIdempotency {
    static let storagePrefix = "idem:"
    /// Bounded: keys are per meeting, so a few hundred is months of history and keeps storage.json small.
    static let limit = 200

    struct Stored: Codable, Equatable, Sendable {
        var key: String
        var result: String
        /// Where the write landed, so a replay can still show the link.
        var target: String
        var recordedAt: String
    }

    static func storageKey(for key: String, isLocalDemo: Bool = false) -> String {
        storagePrefix + (isLocalDemo ? "local:" : "") + key
    }

    static func read(_ key: String, isLocalDemo: Bool = false, from storage: [String: String]) -> Stored? {
        guard let raw = storage[storageKey(for: key, isLocalDemo: isLocalDemo)],
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static func write(_ entry: Stored, isLocalDemo: Bool = false, into storage: inout [String: String]) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        storage[storageKey(for: entry.key, isLocalDemo: isLocalDemo)] = String(decoding: data, as: UTF8.self)
        trim(&storage)
    }

    /// Drops the oldest entries once the cap is exceeded; `recordedAt` is a sortable `yyyy-MM-dd HH:mm` stamp.
    static func trim(_ storage: inout [String: String]) {
        let keys = storage.keys.filter { $0.hasPrefix(storagePrefix) }
        guard keys.count > limit else { return }
        func stamp(_ key: String) -> String {
            guard let raw = storage[key], let data = raw.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(Stored.self, from: data) else { return "" }
            return entry.recordedAt
        }
        for key in keys.sorted(by: { stamp($0) < stamp($1) }).prefix(keys.count - limit) {
            storage.removeValue(forKey: key)
        }
    }

    /// The model may pass any non-empty string; a whitespace-only or oversized value is rejected so a key cannot
    /// grow the storage file without bound.
    static func normalize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.count <= 128 else { return nil }
        return trimmed
    }

    /// Compact 8-hex-char FNV-1a digest used to distinguish different meeting minutes in default idempotency keys.
    static func shortDigest(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }
}

/// Answers a replayed call. Marks the payload so the transcript and the model both see that nothing was sent twice.
enum DesktopFeishuReplay {
    static func payload(from entry: DesktopFeishuIdempotency.Stored, tool: String) -> String {
        guard let data = entry.result.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return entry.result
        }
        object["replayed"] = true
        object["idempotent"] = true
        object["note"] = "同一个幂等键此前已执行过，本次没有再次\(tool == "bot_send_message" ? "发送消息" : "写入飞书")。"
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? entry.result
    }
}
