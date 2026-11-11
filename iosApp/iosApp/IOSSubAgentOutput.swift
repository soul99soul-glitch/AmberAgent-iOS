import Foundation
@preconcurrency import Shared

struct IOSSubAgentOutputStep: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let detail: String?
    let status: IOSAdvancedTaskStatus
}

struct IOSSubAgentOutputSnapshot: Codable, Equatable, Sendable {
    let summary: String
    let steps: [IOSSubAgentOutputStep]
    let isFinal: Bool
}

struct IOSSubAgentStructuredDigest: Codable, Equatable, Sendable {
    let conclusion: String
    let keyPoints: [String]
    let needsUserDecision: Bool
    let decisionPrompt: String?
    let deliverableHint: String?
    let checkpointPolicy: String?

    init(
        conclusion: String,
        keyPoints: [String] = [],
        needsUserDecision: Bool = false,
        decisionPrompt: String? = nil,
        deliverableHint: String? = nil,
        checkpointPolicy: String? = nil
    ) {
        self.conclusion = conclusion
        self.keyPoints = keyPoints
        self.needsUserDecision = needsUserDecision
        self.decisionPrompt = decisionPrompt
        self.deliverableHint = deliverableHint
        self.checkpointPolicy = checkpointPolicy
    }

    var formattedSummary: String {
        var lines: [String] = ["核心结论：\(conclusion)"]
        if let deliverableHint = deliverableHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !deliverableHint.isEmpty {
            lines.append("交付物：\(deliverableHint)")
        }
        if !keyPoints.isEmpty {
            lines.append("关键产出要点：")
            for point in keyPoints {
                lines.append("• \(point)")
            }
        }
        if needsUserDecision {
            if let prompt = decisionPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty,
               prompt != conclusion {
                lines.append("下一步拍板：需用户拍板（\(prompt)）")
            } else {
                lines.append("下一步拍板：需用户拍板确认下一步方向")
            }
        } else {
            lines.append("下一步拍板：无需额外拍板")
        }
        return lines.joined(separator: "\n")
    }

    func toMetadataDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "conclusion": conclusion,
            "key_points": keyPoints,
            "needs_user_decision": needsUserDecision,
            "formatted_summary": formattedSummary,
        ]
        if let decisionPrompt, !decisionPrompt.isEmpty {
            dict["decision_prompt"] = decisionPrompt
        }
        if let deliverableHint, !deliverableHint.isEmpty {
            dict["deliverable_hint"] = deliverableHint
        }
        if let checkpointPolicy, !checkpointPolicy.isEmpty {
            dict["checkpoint_policy"] = checkpointPolicy
        }
        return dict
    }
}

enum IOSSubAgentOutputProjection {
    static let progressReportingInstruction = "When the task permits progress updates, publish one or two concise sentences of verified work and useful findings in ordinary assistant text at meaningful checkpoints. Report completed work or a concrete blocker; do not expose private reasoning, invent progress, or narrate every tool call."
    static let maxSummaryLength = 1_000
    static let maxStepDetailLength = 100
    static let maxSteps = 4
    static let eventType = "subagent_public_output"

    static func snapshot(
        messages: [UIMessage],
        isFinal: Bool,
        fallbackSummary: String? = nil
    ) -> IOSSubAgentOutputSnapshot? {
        let steps = recentToolSteps(in: messages)
        let assistantText = messages
            .filter { $0.role == MessageRole.assistant }
            .flatMap(\.parts)
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .last
        let summary = summaryFromStoredResult(assistantText ?? fallbackSummary ?? "") ?? ""
        guard !summary.isEmpty || !steps.isEmpty else { return nil }
        return IOSSubAgentOutputSnapshot(summary: summary, steps: steps, isFinal: isFinal)
    }

    static func generatedMessages(
        finalMessages: [UIMessage],
        displayMessages: [UIMessage]
    ) -> [UIMessage] {
        guard finalMessages.count >= displayMessages.count else { return [] }
        return Array(finalMessages.dropFirst(displayMessages.count))
    }

    static func snapshot(
        task: IOSAdvancedTaskRecord,
        liveText: String? = nil
    ) -> IOSSubAgentOutputSnapshot? {
        let isFinal = task.status.isTerminal
        let summary: String?
        if isFinal {
            summary = summaryFromStoredResult(task.resultSummary) ??
                summaryFromStoredResult(task.error)
        } else {
            summary = summaryFromStoredResult(liveText ?? "")
        }
        guard let summary, !summary.isEmpty else {
            return isFinal
                ? IOSSubAgentOutputSnapshot(summary: "", steps: [], isFinal: true)
                : nil
        }
        return IOSSubAgentOutputSnapshot(summary: summary, steps: [], isFinal: isFinal)
    }

    static let childResultExcerptMarker = "[Amber host: child result excerpt]"
    static let childRunEndedMarker = "[Amber host: child run ended]"
    static let emptyRunPlaceholder = "[run ended without assistant output]"

    /// Extracts user-facing readable Markdown/summary at the subagent result protocol boundary.
    /// Keeps internal host envelopes (`[Amber host: child result excerpt]`, `[Amber host: child run ended]`,
    /// `session_read` UUIDs/offsets, `run_ended` flags, and raw JSON) out of user-visible chat text,
    /// while preserving original newlines and Markdown structure.
    /// Never falls back to raw JSON when parsing fails or when readable fields are absent.
    static func extractUserFacingResult(from raw: String) -> String? {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty, working != emptyRunPlaceholder else { return nil }

        // 1. Strip `[mailbox KIND from SENDER]\n` transport header if present.
        if working.hasPrefix("[mailbox "),
           let newlineIdx = working.firstIndex(of: "\n") {
            let headerLine = working[..<newlineIdx]
            if headerLine.hasSuffix("]") {
                working = String(working[working.index(after: newlineIdx)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !working.isEmpty, working != emptyRunPlaceholder else { return nil }

        // 2. Split known `[Amber host: ...]` trailer if present.
        var trailerDict: [String: Any]? = nil
        var matchedMarker: String? = nil
        if let split = splitHostMarker(in: working) {
            matchedMarker = split.marker
            working = split.bodyPrefix
            trailerDict = parseHostTrailerJSON(from: split.trailerBody)
        }

        // 3. Unpack `[Structured Digest]` / `[Raw Output]` framing if present in `working`.
        working = unpackStructuredDigestSections(in: working)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if working == emptyRunPlaceholder {
            working = ""
        }

        // 4. Protocol JSON is not Markdown merely because both may start with `[`. Malformed
        // object envelopes still fail closed; links and bracket labels remain readable prose.
        if isJSONResultPayload(working) {
            if let extractedFromWorking = extractReadableSummaryFromJSONString(working) {
                return extractedFromWorking
            }
            // Malformed JSON or JSON lacking readable fields: try trailer's structured_summary if any,
            // and never fall back to raw JSON.
            if let trailerDict, let extractedFromTrailer = extractReadableSummary(from: trailerDict) {
                return extractedFromTrailer
            }
            return nil
        }

        // 5. If `working` is empty (e.g. payload was only `[Amber host: child result excerpt]\n{...}`),
        // extract from the parsed trailer dictionary.
        if working.isEmpty {
            if let trailerDict, let extractedFromTrailer = extractReadableSummary(from: trailerDict) {
                return extractedFromTrailer
            }
            return nil
        }

        // Guard against unparsed host marker lines leaking if malformed.
        if working.hasPrefix("[Amber host:") {
            if let trailerDict, let extractedFromTrailer = extractReadableSummary(from: trailerDict) {
                return extractedFromTrailer
            }
            return nil
        }

        // 6. When the payload was a truncated `[Amber host: child result excerpt]`, ensure the
        // structured summary (conclusion / deliverable_hint / formatted_summary) is preserved
        // even if `working` only holds a truncated excerpt slice.
        if matchedMarker == childResultExcerptMarker,
           let trailerDict,
           let extractedFromTrailer = extractReadableSummary(from: trailerDict),
           !working.contains(extractedFromTrailer) {
            let conclusionLine = ((trailerDict["structured_summary"] as? [String: Any])?["conclusion"] as? String)
                ?? (trailerDict["conclusion"] as? String)
            if let conclusionLine, !conclusionLine.isEmpty, working.hasPrefix(conclusionLine) {
                return working
            }
            return extractedFromTrailer + "\n\n" + working
        }

        return working
    }

    static func isKnownSubAgentResultEnvelope(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(childResultExcerptMarker)
            || trimmed.contains(childRunEndedMarker)
            || trimmed.hasPrefix("[Structured Digest]")
            || trimmed == emptyRunPlaceholder {
            return true
        }
        if trimmed.hasPrefix("{") || (trimmed.hasPrefix("[") && !hasLeadingMarkdownLink(trimmed)) {
            return trimmed.contains("\"structured_summary\"")
                || trimmed.contains("\"formatted_summary\"")
                || trimmed.contains("\"session_read\"")
                || trimmed.contains("\"run_ended\"")
        }
        return false
    }

    static func sanitizeAssistantDisplayTextIfEnvelope(_ text: String) -> String {
        guard isKnownSubAgentResultEnvelope(text) else { return text }
        return extractUserFacingResult(from: text) ?? ""
    }

    /// Non-decoding fallback for previews or a renderer that has not received its first event.
    static func unpreparedDisplayTexts(in message: UIMessage) -> [Int: String] {
        var texts: [Int: String] = [:]
        for (index, part) in message.parts.enumerated() {
            guard let text = part as? UIMessagePart.Text else { continue }
            if message.role == MessageRole.assistant && ChatTaskCommentaryCoalescer.isOrdinaryWaitingText(text.text) {
                texts[index] = ""
                continue
            }
            let base = IosMailboxMessageBridge.shared.displayText(part: text)
            let isFinal = IosToolOutputJsonBridge.shared.metadataString(part: text, key: "kind") == "FINAL_ANSWER"
            texts[index] = isFinal || isKnownSubAgentResultEnvelope(base) ? "" : base
        }
        return texts
    }

    /// Immutable display snapshot prepared by the existing message-event owner before publication.
    /// Raw message parts stay untouched for persistence and model uploads.
    static func displayTexts(in message: UIMessage) -> [Int: String] {
        var texts: [Int: String] = [:]
        for (index, part) in message.parts.enumerated() {
            guard let text = part as? UIMessagePart.Text else { continue }
            texts[index] = message.role == MessageRole.assistant
                ? (ChatTaskCommentaryCoalescer.isOrdinaryWaitingText(text.text) ? "" : sanitizeAssistantDisplayTextIfEnvelope(text.text))
                : userFacingMailboxDisplayText(part: text)
        }
        return texts
    }

    static func userFacingMailboxDisplayText(part: UIMessagePart.Text) -> String {
        let base = IosMailboxMessageBridge.shared.displayText(part: part)
        let kind = IosToolOutputJsonBridge.shared.metadataString(part: part, key: "kind")
        if kind == "FINAL_ANSWER" || isKnownSubAgentResultEnvelope(base) {
            return extractUserFacingResult(from: base) ?? ""
        }
        return base
    }

    private static func splitHostMarker(in text: String) -> (marker: String, bodyPrefix: String, trailerBody: String)? {
        let markers = [childResultExcerptMarker, childRunEndedMarker]
        var earliestRange: Range<String.Index>? = nil
        var matchedMarker: String? = nil

        for marker in markers {
            if text.hasPrefix(marker) {
                let range = text.startIndex..<text.index(text.startIndex, offsetBy: marker.count)
                if earliestRange == nil || range.lowerBound < earliestRange!.lowerBound {
                    earliestRange = range
                    matchedMarker = marker
                }
            } else if let range = text.range(of: "\n" + marker) {
                let markerStart = text.index(after: range.lowerBound)
                let markerRange = markerStart..<range.upperBound
                if earliestRange == nil || markerRange.lowerBound < earliestRange!.lowerBound {
                    earliestRange = markerRange
                    matchedMarker = marker
                }
            }
        }

        guard let range = earliestRange, let marker = matchedMarker else { return nil }
        let prefix = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (marker, prefix, suffix)
    }

    private static func parseHostTrailerJSON(from trailerBody: String) -> [String: Any]? {
        let trimmed = trailerBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Try first line if it is a single-line JSON object (standard `IOSWorkspaceStore.json` output).
        if let firstLine = trimmed.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines),
           firstLine.hasPrefix("{"),
           let data = firstLine.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        // Also support pretty-printed or multi-line JSON objects preceding any trailing English note.
        if let jsonSlice = extractLeadingBalancedJSONObject(in: trimmed),
           let data = jsonSlice.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return nil
    }

    private static func extractLeadingBalancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...idx])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private static func unpackStructuredDigestSections(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[Structured Digest]") else { return text }
        let afterHeader = String(trimmed.dropFirst("[Structured Digest]".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawRange = afterHeader.range(of: "\n[Raw Output]\n") ?? afterHeader.range(of: "\n[Raw Output]") {
            let digestPart = String(afterHeader[..<rawRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawPart = String(afterHeader[rawRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawPart.isEmpty, rawPart != emptyRunPlaceholder {
                if isJSONResultPayload(rawPart) {
                    if let extracted = extractReadableSummaryFromJSONString(rawPart) {
                        return extracted
                    }
                    return digestPart
                }
                return rawPart
            }
            return digestPart
        }
        return afterHeader
    }

    private static func isJSONResultPayload(_ text: String) -> Bool {
        if text.hasPrefix("{") { return true }
        guard text.hasPrefix("[") else { return false }
        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) is [Any] {
            return true
        }
        // A Markdown link label may itself contain JSON or nested brackets.
        // Check its complete link framing before treating a partial array as protocol JSON.
        if hasLeadingMarkdownLink(text) { return false }
        let firstItem = text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return firstItem.hasPrefix("{") || firstItem.hasPrefix("[")
    }

    private static func hasLeadingMarkdownLink(_ text: String) -> Bool {
        var depth = 0
        var escaped = false
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            cursor = text.index(after: cursor)
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        guard depth == 0, cursor < text.endIndex else { return false }
        let opening = text[cursor]
        guard opening == "(" || opening == "[" else { return false }
        let closing: Character = opening == "(" ? ")" : "]"
        depth = 1
        cursor = text.index(after: cursor)
        while cursor < text.endIndex {
            let character = text[cursor]
            cursor = text.index(after: cursor)
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == opening { depth += 1 }
            if character == closing {
                depth -= 1
                if depth == 0 { return true }
            }
        }
        return false
    }

    private static func extractReadableSummaryFromJSONString(_ jsonString: String) -> String? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return extractReadableSummary(from: object)
    }

    static func extractReadableSummary(from object: [String: Any]) -> String? {
        if let nested = object["structured_summary"] as? [String: Any],
           let nestedSummary = extractReadableSummary(from: nested) {
            return nestedSummary
        }

        if let formatted = (object["formatted_summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !formatted.isEmpty {
            return normalizeLiteralNewlines(formatted)
        }

        let primaryCandidateKeys = ["conclusion", "summary", "result", "markdown", "content", "text"]
        var primaryText: String? = nil
        for key in primaryCandidateKeys {
            if let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                primaryText = normalizeLiteralNewlines(value)
                break
            }
        }

        let deliverableHint = (object["deliverable_hint"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var keyPointLines: [String] = []
        if let arr = (object["key_points"] as? [Any]) ?? (object["findings"] as? [Any]) {
            keyPointLines = arr.compactMap { $0 as? String }
                .map { normalizeLiteralNewlines($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else if let str = (object["key_points"] as? String) ?? (object["findings"] as? String) {
            keyPointLines = normalizeLiteralNewlines(str)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        let needsDecision = (object["needs_user_decision"] as? Bool) == true
        let decisionPrompt = ((object["decision_prompt"] as? String) ?? (object["next_step"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard primaryText != nil || !keyPointLines.isEmpty || (needsDecision && decisionPrompt?.isEmpty == false) else {
            return nil
        }

        var sections: [String] = []
        if let primaryText, !primaryText.isEmpty {
            sections.append(primaryText)
        }
        if let deliverableHint, !deliverableHint.isEmpty,
           !(primaryText?.contains(deliverableHint) == true) {
            sections.append("交付物：\(deliverableHint)")
        }
        if !keyPointLines.isEmpty {
            if sections.isEmpty {
                sections.append(keyPointLines.joined(separator: "\n"))
            } else {
                var bulletBlock = ["关键产出要点："]
                for point in keyPointLines {
                    if point.hasPrefix("•") || point.hasPrefix("-") || point.hasPrefix("*") {
                        bulletBlock.append(point)
                    } else {
                        bulletBlock.append("• \(point)")
                    }
                }
                sections.append(bulletBlock.joined(separator: "\n"))
            }
        }
        if needsDecision {
            if let decisionPrompt, !decisionPrompt.isEmpty, decisionPrompt != primaryText {
                sections.append("需用户拍板：\(decisionPrompt)")
            } else {
                sections.append("需用户拍板确认下一步")
            }
        }

        let joined = sections.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func normalizeLiteralNewlines(_ text: String) -> String {
        guard text.contains("\\n") else { return text }
        return text.replacingOccurrences(of: "\\n", with: "\n")
    }

    static func summaryFromStoredResult(_ raw: String) -> String? {
        guard let extracted = extractUserFacingResult(from: raw) else {
            return nil
        }
        return bounded(extracted, limit: maxSummaryLength)
    }

    /// Activity display and text selection share this public snapshot, including legacy archives.
    static func displaySnapshot(_ snapshot: IOSSubAgentOutputSnapshot) -> IOSSubAgentOutputSnapshot {
        IOSSubAgentOutputSnapshot(
            summary: summaryFromStoredResult(snapshot.summary) ?? "",
            steps: snapshot.steps,
            isFinal: snapshot.isFinal
        )
    }

    static func structuredDigest(
        from raw: String,
        deliverableHint: String? = nil,
        checkpointPolicy: String? = nil
    ) -> IOSSubAgentStructuredDigest? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "[run ended without assistant output]" else {
            return nil
        }
        let normalizedHint = deliverableHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveHint = (normalizedHint?.isEmpty == false) ? normalizedHint : nil
        let normalizedPolicy = IOSOrchestrationCheckpointPolicy(rawPolicy: checkpointPolicy)?.rawValue
            ?? checkpointPolicy?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePolicy = (normalizedPolicy?.isEmpty == false) ? normalizedPolicy : nil
        let policyRequiresDecision = IOSOrchestrationCheckpointPolicy(rawPolicy: effectivePolicy) == .pauseForDecision

        if let data = trimmed.data(using: .utf8),
           let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let object = (rawObject["structured_summary"] as? [String: Any]) ?? rawObject
            let conclusionRaw = (object["conclusion"] as? String)
                ?? (object["summary"] as? String)
                ?? (object["formatted_summary"] as? String)?.components(separatedBy: .newlines).first
                ?? ""
            let conclusion = cleanLine(conclusionRaw)
            var keyPoints: [String] = []
            if let arr = (object["key_points"] as? [Any]) ?? (object["findings"] as? [Any]) {
                keyPoints = arr.compactMap { $0 as? String }.map(cleanLine).filter { !$0.isEmpty }
            } else if let str = (object["key_points"] as? String) ?? (object["findings"] as? String) {
                keyPoints = str.components(separatedBy: .newlines).map(cleanLine).filter { !$0.isEmpty }
            } else if let formatted = object["formatted_summary"] as? String {
                keyPoints = normalizeLiteralNewlines(formatted)
                    .components(separatedBy: .newlines)
                    .compactMap(extractBulletText(from:))
            }
            guard !conclusion.isEmpty || !keyPoints.isEmpty else { return nil }
            let resolvedConclusion = conclusion.isEmpty ? keyPoints.removeFirst() : conclusion
            let explicitDecision = (object["needs_user_decision"] as? Bool) ?? (object["needs_decision"] as? Bool)
            let decisionPrompt = cleanLine(
                (object["decision_prompt"] as? String) ?? (object["next_step"] as? String) ?? ""
            )
            let inferredDecision = decisionSignal(in: trimmed)
            let needsDecision = explicitDecision ?? (policyRequiresDecision || inferredDecision.needsDecision)
            return IOSSubAgentStructuredDigest(
                conclusion: String(resolvedConclusion.prefix(240)),
                keyPoints: Array(keyPoints.prefix(4)).map { String($0.prefix(160)) },
                needsUserDecision: needsDecision,
                decisionPrompt: decisionPrompt.isEmpty ? inferredDecision.prompt : decisionPrompt,
                deliverableHint: effectiveHint ?? (object["deliverable_hint"] as? String) ?? (rawObject["deliverable_hint"] as? String),
                checkpointPolicy: effectivePolicy ?? (object["checkpoint_policy"] as? String) ?? (rawObject["checkpoint_policy"] as? String)
            )
        }
        if isKnownSubAgentResultEnvelope(trimmed) {
            guard let extracted = extractUserFacingResult(from: trimmed),
                  extracted != trimmed else {
                return nil
            }
            return structuredDigest(
                from: extracted,
                deliverableHint: deliverableHint,
                checkpointPolicy: checkpointPolicy
            )
        }
        if isJSONResultPayload(trimmed) {
            return nil
        }

        let lines = stripCodeFences(from: trimmed)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isNoiseLogLine($0) }
        guard !lines.isEmpty else { return nil }

        var paragraphLines: [String] = []
        var bulletLines: [String] = []
        for line in lines {
            if let bullet = extractBulletText(from: line) {
                bulletLines.append(bullet)
            } else {
                let cleaned = cleanLine(line)
                if !cleaned.isEmpty, !isSectionHeaderOnly(cleaned) {
                    paragraphLines.append(cleaned)
                }
            }
        }

        let conclusionSource = paragraphLines.first ?? bulletLines.first ?? cleanLine(lines[0])
        guard !conclusionSource.isEmpty else { return nil }
        let conclusion = String(firstConciseStatement(from: conclusionSource, maxChars: 240))

        var keyPoints: [String] = []
        for item in bulletLines where item != conclusion {
            let concise = firstConciseStatement(from: item, maxChars: 160)
            if !concise.isEmpty, !keyPoints.contains(concise) {
                keyPoints.append(concise)
            }
            if keyPoints.count >= 4 { break }
        }
        if keyPoints.isEmpty, paragraphLines.count > 1 {
            for item in paragraphLines.dropFirst() where item != conclusion {
                let concise = firstConciseStatement(from: item, maxChars: 160)
                if !concise.isEmpty, !keyPoints.contains(concise) {
                    keyPoints.append(concise)
                }
                if keyPoints.count >= 4 { break }
            }
        }

        let decisionSignal = decisionSignal(in: trimmed)
        let needsDecision = policyRequiresDecision || decisionSignal.needsDecision
        return IOSSubAgentStructuredDigest(
            conclusion: conclusion,
            keyPoints: keyPoints,
            needsUserDecision: needsDecision,
            decisionPrompt: decisionSignal.prompt,
            deliverableHint: effectiveHint,
            checkpointPolicy: effectivePolicy
        )
    }

    static func structuredResultSummary(
        from raw: String,
        deliverableHint: String? = nil,
        checkpointPolicy: String? = nil
    ) -> String? {
        guard let digest = structuredDigest(
            from: raw,
            deliverableHint: deliverableHint,
            checkpointPolicy: checkpointPolicy
        ) else {
            return summaryFromStoredResult(raw)
        }
        return bounded(digest.formattedSummary, limit: maxSummaryLength)
    }

    @MainActor
    @discardableResult
    static func syncTaskResultSummary(
        in taskStore: IOSAdvancedTaskStore,
        childThreadId: String? = nil,
        runId: String? = nil,
        taskId: String? = nil,
        rawText: String,
        deliverableHint: String? = nil,
        checkpointPolicy: String? = nil,
        status: IOSAdvancedTaskStatus? = nil
    ) -> IOSAdvancedTaskRecord? {
        guard let formatted = structuredResultSummary(
            from: rawText,
            deliverableHint: deliverableHint,
            checkpointPolicy: checkpointPolicy
        ) else {
            return nil
        }
        let targetRecord = taskStore.tasks.first { record in
            if let taskId, record.id == taskId { return true }
            if let childThreadId {
                if record.id == childThreadId || record.metadata["child_thread_id"] == childThreadId {
                    return true
                }
            }
            if let runId {
                if record.id == runId || record.metadata["run_id"] == runId || record.metadata["execution_id"] == runId {
                    return true
                }
            }
            return false
        }
        guard let targetRecord else { return nil }
        var extraMetadata: [String: String] = [:]
        if let digest = structuredDigest(from: rawText, deliverableHint: deliverableHint, checkpointPolicy: checkpointPolicy) {
            extraMetadata["needs_user_decision"] = digest.needsUserDecision ? "true" : "false"
            if let hint = digest.deliverableHint { extraMetadata["deliverable_hint"] = hint }
            if let policy = digest.checkpointPolicy { extraMetadata["checkpoint_policy"] = policy }
        }
        return taskStore.updateTask(
            id: targetRecord.id,
            status: status,
            resultSummary: formatted,
            metadata: extraMetadata.isEmpty ? nil : extraMetadata
        )
    }

    static func linesOutsideCodeFences(_ text: String) -> [String] {
        var fence: (marker: Character, length: Int)?
        var visible: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let length = trimmed.prefix(while: { $0 == marker }).count
                if length >= 3 {
                    if let current = fence {
                        if marker == current.marker, length >= current.length,
                           trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty {
                            fence = nil
                        }
                    } else {
                        fence = (marker, length)
                    }
                    continue
                }
            }
            if fence == nil { visible.append(line) }
        }
        return visible
    }

    private static func stripCodeFences(from text: String) -> String {
        linesOutsideCodeFences(text).joined(separator: "\n")
    }

    private static func isNoiseLogLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("[tool") || lower.hasPrefix("tool_call:") || lower.hasPrefix("step ")
            || line == "---" || line == "***"
    }

    private static func isSectionHeaderOnly(_ line: String) -> Bool {
        let normalized = line.replacingOccurrences(of: "：", with: ":").trimmingCharacters(in: .whitespaces)
        return ["核心结论", "核心结论:", "结论", "结论:", "关键要点", "关键要点:", "关键产出要点", "关键产出要点:", "总结", "总结:"].contains(normalized)
    }

    private static func extractBulletText(from line: String) -> String? {
        let prefixes = ["- ", "* ", "• ", "· "]
        for prefix in prefixes where line.hasPrefix(prefix) {
            let body = cleanLine(String(line.dropFirst(prefix.count)))
            return body.isEmpty ? nil : body
        }
        if let range = line.range(of: #"^\d+[\.\、\)]\s*"#, options: .regularExpression) {
            let body = cleanLine(String(line[range.upperBound...]))
            return body.isEmpty ? nil : body
        }
        return nil
    }

    private static func cleanLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") || text.hasPrefix(">") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        for prefix in ["核心结论：", "核心结论:", "结论：", "结论:", "总结：", "总结:"] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    private static func firstConciseStatement(from text: String, maxChars: Int) -> String {
        let cleaned = cleanLine(text)
        guard cleaned.count > maxChars else { return cleaned }
        return String(cleaned.prefix(maxChars))
    }

    static func decisionSignal(in text: String) -> (needsDecision: Bool, prompt: String?) {
        let markers = [
            "[待拍板]", "【待拍板】", "等待拍板", "等我拍板", "等你拍板", "待你拍板",
            "请拍板", "需要拍板", "需你拍板", "需用户拍板", "待拍板：", "待拍板:",
            "[needs_decision]", "needs_decision:", "awaiting_decision", "[checkpoint]", "checkpoint:",
            "阶段完成待确认", "需要你拍板", "需要您拍板", "待您拍板", "待你确认", "待您确认",
            "请确认下一步", "需要你决定", "需要您决定", "请选择下一步", "是否继续深入", "pause_for_decision"
        ]
        for rawLine in linesOutsideCodeFences(text) {
            let line = extractBulletText(from: rawLine) ?? cleanLine(rawLine)
            let lower = line.replacingOccurrences(of: "`", with: "").lowercased()
            guard let marker = markers.first(where: lower.hasPrefix) else { continue }
            let remainder = lower.dropFirst(marker.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ：:·-—\t"))
            if ["无需", "无须", "不需要", "不用", "不必", "不再"].contains(where: remainder.hasPrefix) { continue }
            if ["needs_decision:", "awaiting_decision", "checkpoint:"].contains(marker),
               ["false", "false.", "false。", "0"].contains(remainder) { continue }
            return (true, String(line.prefix(140)))
        }
        return (false, nil)
    }

    private static func recentToolSteps(in messages: [UIMessage]) -> [IOSSubAgentOutputStep] {
        var seen = Set<String>()
        let tools = messages
            .filter { $0.role == MessageRole.assistant }
            .flatMap(\.parts)
            .compactMap { $0 as? UIMessagePart.Tool }
            .filter { tool in
                tool.toolCallId.isEmpty || seen.insert(tool.toolCallId).inserted
            }
        return tools.suffix(maxSteps).enumerated().map { index, tool in
            let executed = !tool.output.isEmpty
            let failure = ChatToolOutputFormatter.failureReason(from: tool.output)
            let status: IOSAdvancedTaskStatus
            if !executed {
                status = tool.approvalState is ToolApprovalState.Pending ? .approvalRequired : .running
            } else if outputStatus(in: tool.output) == "cancelled" {
                status = .cancelled
            } else if outputStatus(in: tool.output) == "interrupted" {
                status = .interrupted
            } else if failure != nil {
                status = .failed
            } else {
                status = .completed
            }
            let title = ChatToolStepModel.friendlyToolTitle(tool.toolName, executed: executed)
            let detail = safeDetail(for: tool)
            return IOSSubAgentOutputStep(
                id: tool.toolCallId.isEmpty ? "tool-\(index)" : tool.toolCallId,
                title: title,
                detail: detail,
                status: status
            )
        }
    }

    private static func safeDetail(for tool: UIMessagePart.Tool) -> String? {
        let name = tool.toolName
        guard !tool.output.isEmpty else { return nil }
        if let failure = ChatToolOutputFormatter.failureReason(from: tool.output) {
            return bounded(failure, limit: maxStepDetailLength)
        }
        // Subagent/task inputs are intentionally not copied into the detail;
        // the report/assistant text is the public output for those calls.
        if name == "subagent_dispatch" || name == "subagent_report"
            || name == "spawn_agent" || name == "followup_task" {
            return nil
        }
        let allowed = name == "search_web"
            || name == "scrape_web"
            || name == "file_read_selected"
            || name == "permissions_status"
            || name == "runtime_status"
            || name == "tools_list"
            || name.hasPrefix("workspace_")
            || name.hasPrefix("wm_")
        guard allowed else { return nil }
        let model = ChatToolStepModel(tool: tool)
        return bounded(model.detail, limit: maxStepDetailLength)
    }

    private static func outputStatus(in output: [UIMessagePart]) -> String? {
        for text in output.compactMap({ ($0 as? UIMessagePart.Text)?.text }) {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = object["status"] as? String else { continue }
            return status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return nil
    }

    private static func bounded(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(limit))
    }
}

@MainActor
enum IOSSubAgentOutputLoader {
    static func load(
        activity: IOSSubAgentActivity,
        task: IOSAdvancedTaskRecord?
    ) async throws -> IOSSubAgentOutputSnapshot? {
        try await sourceSnapshot(activity: activity, task: task)
            .map(IOSSubAgentOutputProjection.displaySnapshot)
    }

    private static func sourceSnapshot(
        activity: IOSSubAgentActivity,
        task: IOSAdvancedTaskRecord?
    ) async throws -> IOSSubAgentOutputSnapshot? {
        if activity.id.hasPrefix("task:") {
            guard let task else { return nil }
            if task.status.isTerminal,
               let encoded = task.metadata["public_output"],
               let data = encoded.data(using: .utf8),
               let stored = try? JSONDecoder().decode(IOSSubAgentOutputSnapshot.self, from: data) {
                return stored
            }
            let executionId = task.metadata["execution_id"]
            let toolCallId = task.metadata["tool_call_id"]
            if !task.status.isTerminal,
               let toolCallId,
               let model = SubAgentLiveRegistry.shared.model(
                    forToolCallId: toolCallId,
                    executionId: executionId
               ) {
                return model.publicOutputSnapshot
                    ?? IOSSubAgentOutputProjection.snapshot(task: task, liveText: model.text)
            }
            return IOSSubAgentOutputProjection.snapshot(task: task)
        }

        guard activity.id.hasPrefix("run:") else { return nil }
        let runId = String(activity.id.dropFirst("run:".count))
        // The terminal archive may arrive while Live Activity teardown still
        // retains the old job. Prefer that final snapshot over its live copy.
        if activity.canDismiss, let final = try await IOSSubAgentOutputArchive.load(runId: runId) {
            return final
        }
        if let live = IOSChatBackgroundGenerationCoordinator.shared
            .subAgentPublicOutput(runId: runId) {
            return live
        }
        if activity.canDismiss { return nil }
        return try await IOSSubAgentOutputArchive.load(runId: runId)
    }
}

@MainActor
enum IOSSubAgentOutputArchive {
    private static let eventPrefix = "subagent-public-output:"
    private static let sharedDatabase = IosDatabaseFactory.shared.createDatabase()

    static func archive(
        runId: String,
        conversationId: KotlinUuid,
        snapshot: IOSSubAgentOutputSnapshot,
        database: AgentRuntimeDatabase? = nil
    ) async {
        let database = database ?? sharedDatabase
        let child = await withCheckedContinuation { continuation in
            database.threadEdgeDao().edgeFor(childThreadId: conversationId.toHexDashString()) { @Sendable edge, error in
                continuation.resume(returning: error == nil && edge != nil)
            }
        }
        guard child else { return }
        guard let data = try? JSONEncoder().encode(IOSSubAgentOutputProjection.displaySnapshot(snapshot)),
              let payload = String(data: data, encoding: .utf8) else { return }
        let event = AgentRunEvent(
            eventId: eventPrefix + runId,
            type: IOSSubAgentOutputProjection.eventType,
            payloadType: IOSSubAgentOutputProjection.eventType,
            payload: payload,
            payloadSchemaVersion: 1,
            isFinal: false,
            ts: Int64(Date().timeIntervalSince1970 * 1_000),
            turnId: nil,
            stepId: nil,
            toolCallId: nil
        )
        let store = RoomAgentEventStore(dao: database.agentRuntimeDao())
        let inserted = await withCheckedContinuation { continuation in
            store.appendRunEvent(runId: runId, event: event) { @Sendable value, error in
                continuation.resume(returning: error == nil && (value?.boolValue ?? false))
            }
        }
        if inserted {
            NotificationCenter.default.post(name: .amberSubAgentRunsDidChange, object: nil)
        }
    }

    static func load(runId: String, database: AgentRuntimeDatabase? = nil) async throws -> IOSSubAgentOutputSnapshot? {
        let database = database ?? sharedDatabase
        let payload: String? = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String?, Error>) in
            database.agentRuntimeDao().listEventsForRun(id: runId) { @Sendable rows, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: rows?.last(where: {
                    $0.type == IOSSubAgentOutputProjection.eventType
                })?.payload)
            }
        }
        guard let payload,
              let data = payload.data(using: .utf8) else { return nil }
        return IOSSubAgentOutputProjection.displaySnapshot(
            try JSONDecoder().decode(IOSSubAgentOutputSnapshot.self, from: data)
        )
    }
}
