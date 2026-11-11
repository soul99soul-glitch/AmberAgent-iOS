import Foundation
import CoreFoundation

extension AmberUnifiedTaskBuilder {
    // Bottom-badge reads also build task cards. Their unchanged result text must
    // not be scanned again on every view update; status classification stays live.
    // Unlike NSCache (which iOS purges on every background/scenePhase snapshot),
    // a bounded lock-protected ring keeps parsed summaries across scene transitions.
    private final class SummaryCache: @unchecked Sendable {
        private let lock = NSLock()
        private let capacity = 128
        private var entries: [String: AmberDeliverableSummary] = [:]
        private var order: [String] = []

        func value(for key: String) -> AmberDeliverableSummary? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func insert(_ summary: AmberDeliverableSummary, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if entries[key] == nil {
                if order.count >= capacity, let oldest = order.first {
                    order.removeFirst()
                    entries.removeValue(forKey: oldest)
                }
                order.append(key)
            }
            entries[key] = summary
        }
    }
    private static let summaryCache = SummaryCache()

    /// Exact input value is the cache key, including decision markers at the tail.
    static func extractDeliverableSummary(from raw: String?) -> AmberDeliverableSummary {
        guard let raw else { return parseDeliverableSummary(from: nil) }
        if let cached = summaryCache.value(for: raw) { return cached }
        let summary = parseDeliverableSummary(from: raw)
        summaryCache.insert(summary, for: raw)
        return summary
    }

    private static func parseDeliverableSummary(from raw: String?) -> AmberDeliverableSummary {
        guard let raw else {
            return AmberDeliverableSummary(headline: nil, bullets: [], decisionPrompt: nil, needsDecision: false)
        }
        ChatRenderProbe.record("task-summary-parse")
        let initialTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !initialTrimmed.isEmpty else {
            return AmberDeliverableSummary(headline: nil, bullets: [], decisionPrompt: nil, needsDecision: false)
        }
        guard let trimmedRaw = userFacingResultMarkdown(from: initialTrimmed) else {
            return AmberDeliverableSummary(headline: nil, bullets: [], decisionPrompt: nil, needsDecision: false)
        }
        let overallNeedsDecision = structuredDecision(in: initialTrimmed) ?? containsDecisionMarker(trimmedRaw)
        var headline: String? = nil
        var explicitBullets: [String] = []
        var paragraphSentences: [String] = []
        var decisionPrompt: String? = nil
        var fallbackHeading: String? = nil
        for rawLine in IOSSubAgentOutputProjection.linesOutsideCodeFences(trimmedRaw) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if isHorizontalRule(line) || isInternalHeaderLine(line) { continue }

            let isHeading = line.hasPrefix("#")
            let isBullet = isMarkdownBulletLine(line)
            let lineHasDecisionMarker = overallNeedsDecision && containsDecisionMarker(line)
            let cleaned = cleanMarkdownLine(line)
            guard !cleaned.isEmpty else { continue }

            if lineHasDecisionMarker {
                let strippedDecision = stripDecisionPrefix(from: cleaned)
                if !strippedDecision.isEmpty && !isGenericSectionHeading(strippedDecision) {
                    if decisionPrompt == nil {
                        decisionPrompt = truncateText(strippedDecision, limit: resultPreviewLimit)
                    }
                    continue
                }
            }

            if isHeading {
                if !isGenericSectionHeading(cleaned) && fallbackHeading == nil {
                    fallbackHeading = truncateText(cleaned, limit: resultPreviewLimit)
                }
                continue
            }

            if isBullet {
                let itemText = truncateText(cleaned, limit: resultPreviewLimit)
                if !itemText.isEmpty && !explicitBullets.contains(itemText) {
                    explicitBullets.append(itemText)
                }
                continue
            }

            if overallNeedsDecision && decisionPrompt == nil && (cleaned.hasSuffix("？") || cleaned.hasSuffix("?")) {
                decisionPrompt = truncateText(cleaned, limit: resultPreviewLimit)
                continue
            }

            if headline == nil {
                headline = truncateText(cleaned, limit: resultPreviewLimit)
            }
            for clause in splitIntoReadablePoints(cleaned) {
                let point = truncateText(clause, limit: resultPreviewLimit)
                if !point.isEmpty && !paragraphSentences.contains(point) {
                    paragraphSentences.append(point)
                }
            }
        }

        let resolvedHeadline = headline
            ?? explicitBullets.first
            ?? fallbackHeading
            ?? decisionPrompt

        var resolvedBullets: [String] = []
        if !explicitBullets.isEmpty {
            resolvedBullets = Array(explicitBullets.prefix(deliverableBulletLimit))
        } else if paragraphSentences.count > 1 {
            resolvedBullets = Array(paragraphSentences.prefix(deliverableBulletLimit))
        } else if let firstParagraph = paragraphSentences.first {
            resolvedBullets = [firstParagraph]
        } else if let resolvedHeadline {
            resolvedBullets = [resolvedHeadline]
        }

        return AmberDeliverableSummary(
            headline: resolvedHeadline,
            bullets: resolvedBullets,
            decisionPrompt: decisionPrompt,
            needsDecision: overallNeedsDecision
        )
    }

    /// The first real conclusion line of a stored result, or nil when there is nothing yet.
    static func resultPreview(from raw: String?) -> String? {
        extractDeliverableSummary(from: raw).headline
    }

    /// One projection for task previews, summaries and copy. Persisted output remains lossless.
    static func userFacingResultMarkdown(from raw: String?) -> String? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if IOSSubAgentOutputProjection.isKnownSubAgentResultEnvelope(text) {
            text = IOSSubAgentOutputProjection.extractUserFacingResult(from: text) ?? ""
        }
        // amberd owns this exact preamble. Do not strip similarly named fields in user reports.
        let lines = text.components(separatedBy: "\n")
        if lines.first?.hasPrefix("# Settlement Report · ") == true,
           let summary = lines.firstIndex(of: "## Summary"),
           lines[1..<summary].allSatisfy({ line in
               line.isEmpty || ["- TaskKey: ", "- Title: ", "- Outcome: "].contains(where: line.hasPrefix)
           }) {
            text = lines.dropFirst(summary + 1).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    static func needsDecision(metadata: [String: String], fallback: Bool) -> Bool {
        for key in ["needs_decision", "needs_user_decision"] {
            if let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                if value == "false" { return false }
                if value == "true" { return true }
            }
        }
        return ["decision_prompt", "checkpoint"].contains {
            metadata[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } || fallback
    }

    static func structuredDecision(in text: String?) -> Bool? {
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let facts = object["structured_summary"] as? [String: Any] ?? object
        for key in ["needs_decision", "needs_user_decision"] {
            if let value = facts[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue
            }
        }
        if let prompt = facts["decision_prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return nil
    }

    static func containsDecisionMarker(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        if let decision = structuredDecision(in: text) { return decision }
        return IOSSubAgentOutputProjection.decisionSignal(in: text).needsDecision
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        return stripped == "---" || stripped == "***" || stripped == "___"
    }

    private static func isInternalHeaderLine(_ line: String) -> Bool {
        let cleaned = line
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return cleaned.hasPrefix("settlement report")
            || cleaned == "subagent report"
            || cleaned == "task report"
            || cleaned.hasPrefix("[subagent")
            || cleaned.hasPrefix("<amber-")
    }

    private static func isGenericSectionHeading(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: CharacterSet(charactersIn: "：: \t"))
            .lowercased()
        let genericHeadings: Set<String> = [
            "核心结论", "结论", "结论摘要", "交付结论", "交付要点", "核心要点",
            "执行结果", "任务结果", "总结", "摘要", "待拍板", "等我拍板",
            "需要拍板", "下一步", "summary", "conclusion", "deliverables", "key findings"
        ]
        return genericHeadings.contains(normalized)
    }

    private static func isMarkdownBulletLine(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") || line.hasPrefix("+ ") {
            return true
        }
        guard let firstSpace = line.firstIndex(of: " ") else { return false }
        let prefix = line[..<firstSpace]
        guard prefix.hasSuffix(".") || prefix.hasSuffix(")") || prefix.hasSuffix("、") else {
            return false
        }
        let digits = prefix.dropLast()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    private static func cleanMarkdownLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") || text.hasPrefix(">") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("- [ ] ") || text.hasPrefix("- [x] ") || text.hasPrefix("- [X] ") {
            text = String(text.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("• ") || text.hasPrefix("+ ") {
            text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let firstSpace = text.firstIndex(of: " ") {
            let prefix = text[..<firstSpace]
            if (prefix.hasSuffix(".") || prefix.hasSuffix(")") || prefix.hasSuffix("、")),
               !prefix.dropLast().isEmpty,
               prefix.dropLast().allSatisfy(\.isNumber) {
                text = String(text[text.index(after: firstSpace)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        text = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private static func stripDecisionPrefix(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "[待拍板]", "【待拍板】", "[等我拍板]", "【等我拍板】",
            "[needs_decision]", "[NEEDS_DECISION]", "[checkpoint]", "[CHECKPOINT]",
            "待拍板：", "待拍板:", "等我拍板：", "等我拍板:", "等待拍板：", "等待拍板:",
            "请拍板：", "请拍板:", "需要拍板：", "需要拍板:", "需你拍板：", "需你拍板:",
            "needs_decision:", "NEEDS_DECISION:", "checkpoint:", "Checkpoint:"
        ]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where result.lowercased().hasPrefix(prefix.lowercased()) {
                result = String(result.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ：:·-—\t"))
                changed = true
            }
        }
        return result
    }

    private static func splitIntoReadablePoints(_ line: String) -> [String] {
        let clauses = line
            .split(whereSeparator: { $0 == "；" || $0 == ";" || $0 == "。" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return clauses.isEmpty ? [line] : clauses
    }

    private static func truncateText(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

}
