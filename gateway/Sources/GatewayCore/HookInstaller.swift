import Foundation

/// Idempotent merge of the gateway's hook groups into `~/.claude/settings.json` and `~/.codex/hooks.json`.
/// Both files share the `{"hooks": {Event: [group]}}` shape.
///
/// Codex keys hook trust by position (`hooks.json:stop:1:0`), so an existing gateway group is updated in
/// place and a new one is appended — inserting ahead of other groups would silently revoke their trust.
public enum HookInstaller {
    public static let marker = "_amber_gateway"
    public static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Notification", "Stop", "StopFailure", "SessionEnd"]
    public static let codexEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd"]
    /// Fires on every tool call, so it must never sit on the agent's critical path.
    static let asyncEvents: Set<String> = ["PostToolUse"]
    /// Seconds. The hook exits in milliseconds; Codex caps `SessionEnd` at 3.
    static let timeout = 2

    public static func group(command: String, async: Bool = false) -> [String: Any] {
        var hook: [String: Any] = ["type": "command", "command": command, "timeout": timeout]
        if async { hook["async"] = true }
        return [marker: true, "hooks": [hook]]
    }

    public static func installing(into root: [String: Any], events: [String], command: String) -> [String: Any] {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            let ours = group(command: command, async: asyncEvents.contains(event))
            var groups = hooks[event] as? [Any] ?? []
            if let index = groups.firstIndex(where: isOurs) {
                groups[index] = ours
                groups = groups.enumerated().filter { $0.offset == index || !isOurs($0.element) }.map(\.element)
            } else {
                groups.append(ours)
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    public static func removing(from root: [String: Any]) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let kept = groups.filter { !isOurs($0) }
            if kept.count == groups.count { continue }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks
        return root
    }

    static func isOurs(_ group: Any) -> Bool {
        (group as? [String: Any])?[marker] as? Bool == true
    }

    /// Applies `transform` to the JSON object at `url`. Writes (after a timestamped backup) only when the
    /// content actually changes. Returns the backup URL, or nil if nothing was written.
    @discardableResult
    public static func updateFile(
        at url: URL,
        now: Date = Date(),
        dryRun: Bool = false,
        transform: ([String: Any]) -> [String: Any]
    ) throws -> (changed: Bool, backup: URL?) {
        let fm = FileManager.default
        var original: [String: Any] = [:]
        let exists = fm.fileExists(atPath: url.path)
        if exists {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw InstallError.notAnObject(url.path)
                }
                original = object
            }
        }
        let updated = transform(original)
        guard !NSDictionary(dictionary: original).isEqual(to: updated) else { return (false, nil) }
        if dryRun { return (true, nil) }

        var backup: URL?
        if exists {
            let stamp = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
            var target = url.appendingPathExtension("amber-gateway-backup-\(stamp)")
            var n = 1
            while fm.fileExists(atPath: target.path) {
                target = url.appendingPathExtension("amber-gateway-backup-\(stamp)-\(n)")
                n += 1
            }
            try fm.copyItem(at: url, to: target)
            backup = target
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return (true, backup)
    }

    public enum InstallError: Error, CustomStringConvertible {
        case notAnObject(String)
        public var description: String {
            switch self {
            case .notAnObject(let path): "\(path) 不是 JSON 对象，拒绝修改"
            }
        }
    }
}
