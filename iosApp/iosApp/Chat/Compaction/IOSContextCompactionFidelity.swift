import Foundation
@preconcurrency import Shared

/// 压缩交接的机械保真闸门：宿主从源消息提取 12 类高价值实体，
/// 模型产出的 handoff 必须逐字保留；缺任何一项就当次摘要不可用，
/// 走既有的“重试一次 → 降级为预算裁剪”语义。
enum IOSHandoffEntityKind: String, CaseIterable, Sendable {
    case file
    case command
    case error
    case exitCode = "exit_code"
    case date
    case number
    case url
    case commit
    case constraint
    case approval
    case rejected
    case decision

    /// S5: 硬校验仅用于结构化锚点（路径、命令、退出码、日期、数字、URL、commit ID）；
    /// 自然语言句子（constraint/approval/rejected/decision/error）走软校验，避免因同义改写拒绝可用摘要。
    var isHardAnchor: Bool {
        switch self {
        case .file, .command, .exitCode, .date, .number, .url, .commit:
            return true
        case .error, .constraint, .approval, .rejected, .decision:
            return false
        }
    }
}

struct IOSHandoffEntity: Equatable, Sendable {
    let kind: IOSHandoffEntityKind
    let value: String

    var normalizedValue: String {
        IOSContextCompactionFidelity.normalize(value)
    }

    var payload: [String: String] {
        ["kind": kind.rawValue, "value": value]
    }
}

enum IOSContextCompactionFidelity {
    /// 单次摘要最多校验的实体数；超过时按提取顺序截断，避免把闸门变成全文比对。
    static let maxEntities = 24
    /// 同一类最多保留的数量。
    static let maxPerKind = 4
    /// 扫描单条消息 / 全部源文本的字符上限。
    private static let maxScannedCharsPerMessage = 24_000
    private static let maxScannedCharsTotal = 240_000
    /// 太短的值（如 `a.c`）容易误命中，不作为实体。
    private static let minimumValueLength = 3

    // MARK: - Extraction

    static func extract(from messages: [UIMessage]) -> [IOSHandoffEntity] {
        var buckets: [IOSHandoffEntityKind: [IOSHandoffEntity]] = [:]
        var scanned = 0
        var seen = Set<String>()

        func add(_ kind: IOSHandoffEntityKind, _ raw: String) {
            let limit: Int
            switch kind {
            case .error: limit = 160
            case .file, .url: limit = 200
            case .exitCode, .date, .number, .commit: limit = 48
            case .constraint, .approval, .rejected, .decision: limit = 80
            case .command: limit = 160
            }
            let redactedRaw = redactCredentials(raw)
            let value = String(cleanValue(redactedRaw).prefix(limit))
            guard value.count >= minimumValueLength,
                  value.uppercased() != redactionMask,
                  scanned <= maxScannedCharsTotal else { return }
            let key = kind.rawValue + "\u{0}" + normalize(value)
            guard seen.insert(key).inserted else { return }
            guard buckets[kind, default: []].count < maxPerKind else { return }
            buckets[kind, default: []].append(IOSHandoffEntity(kind: kind, value: value))
        }

        for message in messages {
            for part in message.parts {
                if let text = part as? UIMessagePart.Text {
                    let rawSlice = String(text.text.prefix(maxScannedCharsPerMessage))
                    let slice = redactCredentials(rawSlice)
                    scanned += slice.count
                    extractFromText(slice, isUser: message.role == MessageRole.user, add: add)
                } else if let tool = part as? UIMessagePart.Tool {
                    let rawInput = String(tool.input.prefix(maxScannedCharsPerMessage))
                    let catalogInput = (jsonObject(rawInput) != nil || IOSProviderConfigToolCatalog.toolNames.contains(tool.toolName))
                        ? IOSProviderConfigToolCatalog.redactedArgumentsJSON(rawInput)
                        : rawInput
                    let input = redactCredentials(catalogInput)
                    scanned += input.count
                    extractFromToolInput(tool.toolName, input, add: add)
                    let output = tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n")
                    let outputSlice = redactCredentials(String(output.prefix(maxScannedCharsPerMessage)))
                    scanned += outputSlice.count
                    extractFromText(outputSlice, isUser: false, add: add)
                }
            }
            if scanned > maxScannedCharsTotal { break }
        }
        // Round-robin by kind: one verbose message must not take every slot and
        // drop whole classes (e.g. constraints/approvals) from the gate.
        var result: [IOSHandoffEntity] = []
        var depth = 0
        while result.count < maxEntities {
            var added = false
            for kind in IOSHandoffEntityKind.allCases {
                guard depth < (buckets[kind]?.count ?? 0) else { continue }
                result.append(buckets[kind]![depth])
                added = true
                if result.count == maxEntities { break }
            }
            guard added else { break }
            depth += 1
        }
        return result
    }

    private static func extractFromToolInput(
        _ toolName: String,
        _ input: String,
        add: (IOSHandoffEntityKind, String) -> Void
    ) {
        let commandToolNames: Set<String> = [
            "terminal_execute", "ios_shell_execute", "ios_ish_execute", "ish_handoff",
            // macOS / legacy names remain harmless if a shared transcript contains them.
            "terminal_exec", "shell_run", "run_command", "ish_execute", "terminal_run",
        ]
        guard commandToolNames.contains(toolName),
              let object = jsonObject(input) else { return }
        for key in ["command", "script", "cmd"] {
            if let value = object[key] as? String, !value.isEmpty {
                add(.command, String(value.prefix(160)))
            }
        }
    }

    private static func extractFromText(
        _ text: String,
        isUser: Bool,
        add: (IOSHandoffEntityKind, String) -> Void
    ) {
        for match in matches(#"(?i)(?<![\w/])[\w.@+-]+(?:/[\w.@+-]+)+\.[a-z0-9]{1,10}\b"#, in: text) where !match.contains("://") {
            add(.file, match)
        }
        for match in matches(#"(?i)https?://(?:(?:\[redacted\])|[^\s<>"')\]])+"#, in: text) {
            add(.url, match)
        }
        for match in matches(#"(?im)^.*\b(?:error|failed|failure|错误|失败)\b.*$"#, in: text) {
            add(.error, match)
        }
        for match in matches(#"(?i)\bexit(?:\s*code)?\s*[:=]?\s*\d{1,3}\b"#, in: text) {
            add(.exitCode, match)
        }
        for match in matches(#"\b\d{4}-\d{2}-\d{2}\b"#, in: text) {
            add(.date, match)
        }
        for match in matches(#"(?<!\d)\d+(?:\.\d+)?\s*(?:%|ms|分钟|秒钟|秒|小时|天|pt|dp|次|个|条)"#, in: text) {
            add(.number, match)
        }
        for match in matches(
            #"(?i)(?:commit|sha|提交|版本)\s*[:#]?\s*([0-9a-f]{7,40})\b"#,
            in: text,
            captureGroup: 1
        ) {
            add(.commit, match)
        }
        guard isUser else { return }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let rules: [(IOSHandoffEntityKind, [String])] = [
            (.constraint, ["必须", "禁止", "不得", "only", "must", "never"]),
            (.approval, ["批准", "允许", "同意", "approve"]),
            (.rejected, ["否决", "不要用", "别用", "放弃", "reject"]),
            (.decision, ["决定", "采用", "改为", "就按", "decided", "choose"]),
        ]
        for (kind, needles) in rules {
            for line in lines {
                let lower = line.lowercased()
                guard needles.contains(where: { lower.contains($0) }) else { continue }
                add(kind, String(line.prefix(80)))
            }
        }
    }

    // MARK: - Validation

    /// 返回 handoff 中缺失的实体（逐类独立判定，供 12 类 needle 计分）。
    static func missing(_ entities: [IOSHandoffEntity], in handoff: String) -> [IOSHandoffEntity] {
        guard !entities.isEmpty else { return [] }
        let haystack = normalize(handoff)
        return entities.filter { !haystack.contains($0.normalizedValue) }
    }

    /// S5: 硬闸门只拦截结构化锚点（路径、ID、URL、命令、数字、日期）；
    /// 自然语言句子（constraint/approval/rejected/decision/error）走软校验。
    static func missingHardAnchors(_ entities: [IOSHandoffEntity], in handoff: String) -> [IOSHandoffEntity] {
        guard !entities.isEmpty else { return [] }
        let haystack = normalize(handoff)
        return entities.filter { $0.kind.isHardAnchor && !haystack.contains($0.normalizedValue) }
    }

    /// S5: 自然语言句子的软校验（分词/关键词覆盖度 >= 50% 或全文包含即通过，不阻断摘要保存）。
    static func missingSoftEntities(_ entities: [IOSHandoffEntity], in handoff: String) -> [IOSHandoffEntity] {
        guard !entities.isEmpty else { return [] }
        let haystack = normalize(handoff)
        return entities.filter { entity in
            guard !entity.kind.isHardAnchor else { return false }
            return !softMatches(entity, normalizedHandoff: haystack)
        }
    }

    static func softMatches(_ entity: IOSHandoffEntity, normalizedHandoff haystack: String) -> Bool {
        let needle = entity.normalizedValue
        if haystack.contains(needle) { return true }
        let tokens = significantTokens(in: needle)
        guard !tokens.isEmpty else { return true }
        let matched = tokens.filter { haystack.contains($0) }.count
        return Double(matched) / Double(tokens.count) >= 0.5
    }

    private static func significantTokens(in text: String) -> [String] {
        let rawTokens = matches(#"[a-z0-9_./:-]{2,}|[\p{Han}]{2,}"#, in: text)
        return rawTokens.filter { $0 != "[redacted]" && $0 != "redacted" }
    }

    /// 注入到压缩 prompt 的硬性要求清单。
    static func promptLines(_ entities: [IOSHandoffEntity]) -> String {
        guard !entities.isEmpty else { return "" }
        let sanitized = entities.map {
            IOSHandoffEntity(kind: $0.kind, value: redactCredentials($0.value))
        }
        let lines = sanitized.map { "- \($0.kind.rawValue): \($0.value)" }
        return """
        must_not_lose (host-extracted facts; every value below must appear verbatim in handoff_markdown):
        \(lines.joined(separator: "\n"))
        """
    }

    /// 存入 compact payload 的 must_not_lose 数组（落盘前强制脱敏）。
    static func payload(_ entities: [IOSHandoffEntity]) -> [[String: String]] {
        entities.map {
            ["kind": $0.kind.rawValue, "value": redactCredentials($0.value)]
        }
    }

    static func normalize(_ value: String) -> String {
        let redacted = canonicalizeRedactionMasks(in: redactCredentials(value))
        return redacted
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Credential Redaction (B1 & B4)

    static let redactionMask = "[REDACTED]"

    /// 统一凭据脱敏：覆盖私钥块、Bearer、sk- 等常见前缀、URL 敏感参数与 userinfo、
    /// 以及 api_key/token/secret/password 赋值。
    static func redactCredentials(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var output = text

        // 1. PEM / OpenSSH 私钥块（含完整块与被截断的未闭合块）
        output = replacingRegex(
            #"(?is)-----BEGIN [A-Z0-9 _-]*PRIVATE KEY-----.*?-----END [A-Z0-9 _-]*PRIVATE KEY-----"#,
            in: output,
            with: redactionMask
        )
        output = replacingRegex(
            #"(?is)-----BEGIN [A-Z0-9 _-]*PRIVATE KEY-----[\s\S]*$"#,
            in: output,
            with: redactionMask
        )

        // 2. URL 中的 basic-auth user:password@host 与敏感 query/fragment 参数
        output = replacingRegex(
            #"(?i)(https?://[^/\s:@]+:)(?!\[REDACTED\])([^@\s/]+)(@)"#,
            in: output,
            with: "$1\(redactionMask)$3"
        )
        output = replacingRegex(
            #"(?i)([?&;#](?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|id[_-]?token|client[_-]?secret|token|secret|password|passwd|pwd|key|sig|signature)=)(?!\[REDACTED\])([^&#\s"'<>)\]]+)"#,
            in: output,
            with: "$1\(redactionMask)"
        )

        // 3. Authorization: Bearer <token>
        output = replacingRegex(
            #"(?i)(\bBearer\s+)(?!\[REDACTED\])[A-Za-z0-9._~+/=-]{6,}"#,
            in: output,
            with: "$1\(redactionMask)"
        )

        // 4. sk- 及常见平台密钥前缀 / JWT
        output = replacingRegex(
            #"\bsk-[A-Za-z0-9_\-]{8,}"#,
            in: output,
            with: redactionMask
        )
        output = replacingRegex(
            #"\b(?:gh[pousr]_[A-Za-z0-9]{12,}|glpat-[A-Za-z0-9_\-]{12,}|xox[abprs]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{20,}|eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,})"#,
            in: output,
            with: redactionMask
        )

        // 5. api_key / token / secret / password 赋值（JSON、YAML、env、shell、header）与 CLI 参数
        output = replacingRegex(
            #"(?i)(["']?\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|id[_-]?token|client[_-]?secret|secret[_-]?key|private[_-]?key|token|secret|password|passwd|passphrase)\b["']?\s*[:=]\s*["']?)(?!\[REDACTED\]|\*{4}|\(clear\)|\(redacted\))([^"'\s,;}\]\n]+)"#,
            in: output,
            with: "$1\(redactionMask)"
        )
        output = replacingRegex(
            #"(?i)(--(?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password|passwd|passphrase)\s+["']?)(?!\[REDACTED\])([^"'\s,;}\]\n]+)"#,
            in: output,
            with: "$1\(redactionMask)"
        )

        return output
    }

    private static func canonicalizeRedactionMasks(in text: String) -> String {
        var result = text
        result = replacingRegex(
            #"(?i)(?:\[redacted\]|<redacted>|\(redacted\)|«已脱敏»|\*{3,}[A-Za-z0-9_-]*)"#,
            in: result,
            with: "[redacted]"
        )
        return result
    }

    private static func replacingRegex(
        _ pattern: String,
        in text: String,
        with template: String
    ) -> String {
        guard let regex = RegexCache.shared.regex(pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    // MARK: - Helpers

    private static func cleanValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadRedactedSuffix = value.uppercased().hasSuffix(redactionMask)
        let hadRedactedPrefix = value.uppercased().hasPrefix(redactionMask)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "*`_#>[](){}。，,;；"))
        if hadRedactedSuffix && value.uppercased().hasSuffix("[REDACTED") {
            value += "]"
        }
        if hadRedactedPrefix && value.uppercased().hasPrefix("REDACTED]") {
            value = "[" + value
        }
        return value
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func matches(
        _ pattern: String,
        in text: String,
        captureGroup: Int = 0
    ) -> [String] {
        guard let regex = RegexCache.shared.regex(pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            .compactMap { match in
                let range = match.range(at: captureGroup)
                guard range.location != NSNotFound else { return nil }
                return source.substring(with: range)
            }
    }
}


/// 压缩保真提取每次请求会扫描最多 240k 字符；正则只编译一次。
private final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private let lock = NSLock()
    private var cache: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pattern] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache[pattern] = compiled
        return compiled
    }
}
