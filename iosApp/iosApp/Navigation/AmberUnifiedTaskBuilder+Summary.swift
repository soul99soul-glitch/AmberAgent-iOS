import Foundation

extension AmberUnifiedTaskBuilder {
    private final class SummaryEntry {
        let value: AmberDeliverableSummary
        init(_ value: AmberDeliverableSummary) { self.value = value }
    }

    // Bottom-badge reads also build task cards. Their unchanged result text must
    // not be scanned again on every view update; status classification stays live.
    // NSCache serializes its accesses; entries contain immutable summary values.
    private final class SummaryCache: @unchecked Sendable {
        let values = NSCache<NSString, SummaryEntry>()
        init() {
            values.countLimit = 64
            values.totalCostLimit = 1_048_576
        }
    }
    private static let summaryCache = SummaryCache()

    /// Exact input value is the cache key, including decision markers at the tail.
    static func extractDeliverableSummary(from raw: String?) -> AmberDeliverableSummary {
        guard let raw else { return parseDeliverableSummary(from: nil) }
        let key = raw as NSString
        if let cached = summaryCache.values.object(forKey: key) { return cached.value }
        let summary = parseDeliverableSummary(from: raw)
        summaryCache.values.setObject(SummaryEntry(summary), forKey: key, cost: key.length * 2)
        return summary
    }

    private static func parseDeliverableSummary(from raw: String?) -> AmberDeliverableSummary {
        guard let raw else {
            return AmberDeliverableSummary(headline: nil, bullets: [], decisionPrompt: nil, needsDecision: false)
        }
        ChatRenderProbe.record("task-summary-parse")
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            return AmberDeliverableSummary(headline: nil, bullets: [], decisionPrompt: nil, needsDecision: false)
        }

        let overallNeedsDecision = containsDecisionMarker(trimmedRaw)
        var headline: String? = nil
        var explicitBullets: [String] = []
        var paragraphSentences: [String] = []
        var decisionPrompt: String? = nil
        var fallbackHeading: String? = nil
        var inCodeBlock = false

        for rawLine in trimmedRaw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock || line.isEmpty { continue }
            if isHorizontalRule(line) || isInternalHeaderLine(line) { continue }

            let isHeading = line.hasPrefix("#")
            let isBullet = isMarkdownBulletLine(line)
            let lineHasDecisionMarker = containsDecisionMarker(line)
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

    static func containsDecisionMarker(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let lower = text.lowercased()
        let markers = [
            "[待拍板]",
            "【待拍板】",
            "等待拍板",
            "等我拍板",
            "等你拍板",
            "待你拍板",
            "请拍板",
            "需要拍板",
            "需你拍板",
            "待拍板：",
            "待拍板:",
            "needs_decision",
            "[needs_decision]",
            "awaiting_decision",
            "[checkpoint]",
            "checkpoint:",
            "前序阶段完成",
            "前序阶段已完成",
            "前序步骤已完成",
            "阶段完成待确认"
        ]
        return markers.contains { lower.contains($0) }
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
