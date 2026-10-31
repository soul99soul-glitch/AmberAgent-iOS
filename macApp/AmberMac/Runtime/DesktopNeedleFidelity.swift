import Foundation

/// The twelve kinds of detail a compaction must not lose, mirroring the plan's needle baseline.
enum DesktopNeedleClass: String, CaseIterable, Sendable {
    case errorText, exitCode, path, commit, number, rejection, approval, date, modelID, testName, stackFrame, verbatimQuote

    /// Classes whose loss makes a checkpoint unsafe: the model cannot re-derive them from a paraphrase.
    var isCritical: Bool {
        switch self {
        case .errorText, .exitCode, .path, .commit, .rejection, .approval: true
        default: false
        }
    }

    /// Classes a checkpoint is rejected for losing.
    ///
    /// Only classes the host can verify exactly *and* whose real-world count stays small belong here. A real
    /// tool-heavy session carries dozens of paths, numbers and dates, and no compliant handoff repeats them all —
    /// gating those rejected every checkpoint. They are still scored in the report, just not used as a veto.
    var isHardGated: Bool {
        switch self {
        case .errorText, .exitCode, .commit, .approval, .rejection: true
        case .path, .number, .date, .modelID, .testName, .stackFrame, .verbatimQuote: false
        }
    }
}

struct DesktopNeedle: Hashable, Sendable {
    let kind: DesktopNeedleClass
    let value: String
}

/// Counts how much of each needle class survives a summary, so a lossy checkpoint can be rejected and the
/// per-class table can be reported instead of assumed.
enum DesktopNeedleFidelity {
    struct Count: Equatable, Sendable {
        var kept = 0
        var total = 0
    }

    struct Report: Equatable, Sendable {
        /// kept / total per class; a class with no needles in the source is absent.
        var counts: [DesktopNeedleClass: Count] = [:]

        func kept(_ kind: DesktopNeedleClass) -> Int { counts[kind]?.kept ?? 0 }
        func total(_ kind: DesktopNeedleClass) -> Int { counts[kind]?.total ?? 0 }
        func rate(_ kind: DesktopNeedleClass) -> Double? {
            guard let count = counts[kind], count.total > 0 else { return nil }
            return Double(count.kept) / Double(count.total)
        }
        /// Classes whose retention dropped below the baseline.
        func regressed(below baseline: Report) -> [DesktopNeedleClass] {
            baseline.counts.compactMap { kind, value in
                guard value.total > 0, (rate(kind) ?? 0) < (baseline.rate(kind) ?? 0) else { return nil }
                return kind
            }.sorted { $0.rawValue < $1.rawValue }
        }
    }

    private static let patterns: [(DesktopNeedleClass, String)] = [
        // `exit code`, `exit_code`, `exit-code`, `ExitCode:` and 退出码 all mean the same thing.
        (.exitCode, #"(?i)(?:exit[\s_-]*code|退出码)\D{0,3}(\d+)"#),
        (.path, #"(/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)+)"#),
        // A bare hex run is not a commit: request ids, call ids and file digests are 12–40 hex chars too. Require a
        // commit word next to it so the class stays exact.
        (.commit, #"(?i)(?:commit|提交|revision|rev)\D{0,6}\b([0-9a-f]{7,40})\b|\b([0-9a-f]{7,40})\b\s*(?:提交|commit)"#),
        (.date, #"(\d{4}-\d{2}-\d{2}|\d{4}年\d{1,2}月\d{1,2}日)"#),
        (.modelID, #"\b((?:claude|gpt|gemini|deepseek|qwen|glm|kimi|mimo|minimax)[\w.\-]*)"#),
        (.testName, #"\b([A-Z][A-Za-z0-9]{2,}Tests?\b|\w+Tests\.\w+|test[A-Z]\w+)"#),
        (.stackFrame, #"(?m)^\s*at\s+([\w.$/\-]+)\("#),
        (.number, #"\b(\d{3,})\b"#),
    ]

    static func needles(in text: String) -> Set<DesktopNeedle> {
        guard !text.isEmpty else { return [] }
        var found: Set<DesktopNeedle> = []
        // Error lines and approval wording are captured as the distinctive phrase after the marker, so a
        // summary that keeps the fact in its own sentence still counts as retaining it.
        for (kind, pattern) in [
            (DesktopNeedleClass.errorText, #"(?i)(?:error|exception|报错|错误)[:：]?\s*([^\n；。]{4,80})"#),
            (.rejection, #"(?:拒绝|不同意|不允许|declined|rejected)[:：]?\s*([^\n；。]{3,60})"#),
            (.approval, #"(?:批准|同意|允许|approved)[:：]?\s*([^\n；。]{3,60})"#),
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let value = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { found.insert(DesktopNeedle(kind: kind, value: value)) }
            }
        }
        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                // Patterns with an alternation carry the value in whichever group matched.
                let group = (1..<match.numberOfRanges).first { match.range(at: $0).location != NSNotFound } ?? 1
                guard let range = Range(match.range(at: group), in: text) else { continue }
                let raw = String(text[range])
                found.insert(DesktopNeedle(kind: kind, value: kind == .commit ? raw.lowercased() : raw))
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"[「“\"]([\u4e00-\u9fff][^」”\"]{5,60})[」”\"]"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                found.insert(DesktopNeedle(kind: .verbatimQuote, value: String(text[range])))
            }
        }
        return found
    }

    /// A needle survives when the handoff still contains its distinctive value, wherever it moved to.
    private static func retained(_ needle: DesktopNeedle, in handoffText: String) -> Bool {
        handoffText.range(of: needle.value, options: .caseInsensitive) != nil
    }

    static func report(handoff: String, source: String) -> Report {
        var counts: [DesktopNeedleClass: Count] = [:]
        for needle in needles(in: source) {
            var entry = counts[needle.kind] ?? Count()
            entry.total += 1
            if retained(needle, in: handoff) { entry.kept += 1 }
            counts[needle.kind] = entry
        }
        return Report(counts: counts)
    }

    /// Needles a handoff dropped from the hard-gated classes; a non-empty result rejects the checkpoint.
    /// Everything else is reported by `report(handoff:source:)` and scored, never used as a veto.
    static func missingCritical(handoff: String, source: String) -> [DesktopNeedle] {
        needles(in: source)
            .filter { $0.kind.isHardGated && !retained($0, in: handoff) }
            .sorted { $0.kind.rawValue < $1.kind.rawValue || ($0.kind == $1.kind && $0.value < $1.value) }
    }
}
