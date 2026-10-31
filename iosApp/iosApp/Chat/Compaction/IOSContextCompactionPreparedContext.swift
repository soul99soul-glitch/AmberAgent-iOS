import Foundation
@preconcurrency import Shared

extension IOSContextCompactionCoordinator {
    /// 标注历史空洞。
    /// retainedToolCallIds：Jev 压缩保留判定需保留原文的结果，只跳过清空（超长仍截成预览）。
    static func editPreparedContext(
        messages: [UIMessage],
        keepRecentMessages: Int,
        retainedToolCallIds: Set<String> = []
    ) -> (messages: [UIMessage], removedToolResults: Int) {
        let trimmed = editMessageTools(messages: messages, keepRecentMessages: keepRecentMessages) { trimToolResult($0) }
        let cleared = editMessageTools(messages: trimmed, keepRecentMessages: keepRecentMessages) {
            retainedToolCallIds.contains($0.toolCallId) ? $0 : clearToolResult($0)
        }
        var removedToolResults = 0
        for (original, edited) in zip(messages, cleared) {
            for (originalPart, editedPart) in zip(original.parts, edited.parts) {
                if originalPart is UIMessagePart.Tool,
                   editedPart is UIMessagePart.Tool,
                   originalPart != editedPart {
                    removedToolResults += 1
                }
            }
        }
        return (cleared, removedToolResults)
    }

    static func buildCompressionInput(_ messages: [UIMessage]) -> String {
        messages.map { message in
            var lines = [
                "message_id: \(messageId(message))",
                "role: \(message.role.name.lowercased())"
            ]
            lines += message.parts.map(summaryLine)
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    static func buildCompressionPrompt(
        basePrompt: String,
        content: String,
        targetTokens: Int,
        additionalPrompt: String,
        coveredCompactIds: [String],
        previousCompactContext: String,
        mustNotLose: [IOSHandoffEntity] = []
    ) -> String {
        let coveredIds = coveredCompactIds.map { "\"\($0)\"" }.joined(separator: ", ")
        let fidelity = IOSContextCompactionFidelity.promptLines(mustNotLose)
        let structured = """
        Return valid JSON only. Required schema:
        {
          "schema_version": 2,
          "timeline_summary": "4-5 complete human-readable sentences in the user's language for the chat timeline.",
          "handoff_markdown": "Dense Markdown continuation handoff with sections: Goal, Constraints, Progress, Decisions, Current State, Next Steps, Critical Context, Relevant Files.",
          "covered_compact_ids": [\(coveredIds)]
        }
        Carry every previous handoff below forward; `covered_compact_ids` lists the ids whose content this handoff carries.
        Preserve concrete names, files, commands, errors, user preferences, rejected approaches, tool outcomes, and unresolved decisions.
        The timeline summary is for the human timeline; the handoff Markdown is what the next model will receive.

        \(fidelity)

        Agent-editable handoff instructions:
        \(defaultHandoffPrompt)

        Previous compact handoffs to carry forward:
        \(previousCompactContext.isEmpty ? "None." : previousCompactContext)
        """
        let additional = [structured, additionalPrompt].filter { !$0.isEmpty }.joined(separator: "\n\n")
        var template = basePrompt
        // A synced/custom prompt that lost a placeholder must still carry the schema and the source.
        if !template.contains("{additional_context}") { template += "\n\n{additional_context}" }
        if !template.contains("{content}") { template += "\n\n{content}" }
        return fillTemplate(template, values: [
            "content": content,
            "target_tokens": "\(targetTokens)",
            "additional_context": additional,
            "locale": Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier
        ])
    }

    /// Single pass over the template, so placeholder-looking text inside the
    /// conversation content or previous handoffs is never substituted again.
    static func fillTemplate(_ template: String, values: [String: String]) -> String {
        let pattern = "\\{(" + values.keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return template }
        let source = template as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += values[source.substring(with: match.range(at: 1))] ?? ""
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }

    /// Returns nil when the model output is not a usable handoff; callers must not save it.
    static func normalizedPayload(
        _ raw: String,
        sourceMessageIds: [String],
        offeredCompactIds: [String],
        createdAt: Int64,
        mustNotLose: [IOSHandoffEntity] = []
    ) -> String? {
        let object = parseJSONObject(raw)
        let rawHandoff: String
        let carriedCompactIds: [String]
        if let object {
            rawHandoff = cleanMarkdown(stringValue(object["handoff_markdown"]) ?? "")
            // Ancestors drop out of injection only when the model says it carried them forward.
            let claimed = Set(stringList(object["covered_compact_ids"]))
            carriedCompactIds = offeredCompactIds.filter(claimed.contains)
        } else {
            let text = cleanMarkdown(raw
                .replacingOccurrences(of: "```markdown", with: "")
                .replacingOccurrences(of: "```", with: ""))
            rawHandoff = text.hasPrefix("{") ? "" : text
            carriedCompactIds = []
        }
        let handoff = IOSContextCompactionFidelity.redactCredentials(rawHandoff)
        guard isUsableHandoff(handoff) else { return nil }
        let sanitizedMustNotLose = mustNotLose.map { entity in
            IOSHandoffEntity(
                kind: entity.kind,
                value: IOSContextCompactionFidelity.redactCredentials(entity.value)
            )
        }
        let cappedHandoff = String(handoff.prefix(maxHandoffChars))
        // I2.2 / S5: host-extracted hard anchors must survive verbatim after truncation;
        // soft natural-language entities are tracked without rejecting the handoff.
        guard IOSContextCompactionFidelity.missingHardAnchors(sanitizedMustNotLose, in: cappedHandoff).isEmpty else { return nil }
        _ = IOSContextCompactionFidelity.missingSoftEntities(sanitizedMustNotLose, in: cappedHandoff)
        let rawTimeline = coerceTimelineSummary(
            stringValue(object?["timeline_summary"])
                ?? stringValue(object?["display_summary"])
                ?? stringValue(object?["summary"])
                ?? String(cappedHandoff
                    .split(separator: "\n")
                    .filter { !$0.hasPrefix("#") }
                    .joined(separator: " ")
                    .prefix(280))
        )
        let timeline = IOSContextCompactionFidelity.redactCredentials(rawTimeline)
        return jsonString([
            "schema_version": 2,
            "timeline_summary": String(timeline.prefix(maxTimelineSummaryChars)),
            "handoff_markdown": cappedHandoff,
            "covered_compact_ids": Array(Set(carriedCompactIds)).sorted(),
            "must_not_lose": IOSContextCompactionFidelity.payload(sanitizedMustNotLose),
            "source_message_ids": Array(Set(sourceMessageIds)).sorted(),
            "created_at": createdAt
        ])
    }

    /// A handoff must be model-authored and structured: a refusal or "please retry"
    /// reply is short and names none of the required sections.
    static func isUsableHandoff(_ handoff: String) -> Bool {
        guard handoff.count >= 120 else { return false }
        let lower = handoff.lowercased()
        let sections = handoffSectionNames.filter { names in names.contains { lower.contains($0) } }
        return sections.count >= 2
    }

    static let handoffSectionNames: [[String]] = [
        ["goal", "目标"], ["constraints", "约束"], ["progress", "进展", "进度"], ["decisions", "决策", "决定"],
        ["current state", "当前状态"], ["next steps", "下一步"], ["critical context", "关键上下文"],
        ["relevant files", "相关文件"]
    ]

    static let compactionRetryPrompt = "Retry because the previous compaction was not a usable handoff. Return valid JSON only. `handoff_markdown` must contain the required sections with concrete facts from the source messages, and `timeline_summary` must contain 4-5 complete sentences."

    static func injectionText(_ compact: IOSConversationCompact, removedToolResults: Int = 0) -> String {
        injectionText(
            id: compact.id,
            summary: compact.summary,
            sourceMessageIds: compact.sourceMessageIds,
            removedToolResults: removedToolResults
        )
    }

    static func injectionText(id: String, summary: String, sourceMessageIds: [String], removedToolResults: Int = 0) -> String {
        let payload = payloadObject(summary)
        let rawHandoff = cleanMarkdown(stringValue(payload?["handoff_markdown"]) ?? timelineSummary(summary) ?? summary)
        let handoff = IOSContextCompactionFidelity.redactCredentials(rawHandoff)
        let covered = stringList(payload?["covered_compact_ids"])
        var lines = [
            "[Conversation compact handoff: \(id)]",
            "Source message ids: \(sourceMessageIds.joined(separator: ", "))"
        ]
        if !covered.isEmpty {
            lines.append("Covered compact ids: \(covered.joined(separator: ", "))")
        }
        if removedToolResults > 0 {
            lines.append(compactedToolResultsNote(removedToolResults))
        }
        lines.append("")
        lines.append(handoff)
        lines.append("")
        lines.append("Retrieval: the original messages behind this boundary are still stored and unmodified. Call history_search with a query, then history_fetch with the returned message_id, when exact earlier wording, commands, errors, paths or decisions are needed. Results with stale=true are outside the live context.")
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// handoff 注入中的事实说明:有多少条旧消息的工具结果被压缩处理过,模型如需原始
    /// 内容可以重新调用工具(workspace 文件、file search、web search 均可重取)。
    static func compactedToolResultsNote(_ count: Int) -> String {
        "Note: \(count) tool result(s) from older messages were removed or trimmed from this prepared context. If you need their exact original content, re-run the relevant tool — workspace files, file search, and web search can re-fetch it. The original conversation storage is unchanged."
    }

    static func timelineSummary(_ summary: String) -> String? {
        guard let payload = payloadObject(summary) else {
            return cleanHumanText(IOSContextCompactionFidelity.redactCredentials(summary))
        }
        return coerceTimelineSummary(
            IOSContextCompactionFidelity.redactCredentials(
                stringValue(payload["timeline_summary"])
                    ?? stringValue(payload["display_summary"])
                    ?? stringValue(payload["summary"])
                    ?? ""
            )
        )
    }

    static func selectCompactsForInjection(
        activeCompacts: [IOSConversationCompact],
        existingMessageIds: Set<String>
    ) -> [IOSConversationCompact] {
        let completed = validCompletedCompacts(activeCompacts, existingMessageIds: existingMessageIds)
        guard !completed.isEmpty else { return [] }
        guard let latestPayload = completed.reversed().first(where: { compact in
            guard let payload = payloadObject(compact.summary) else { return false }
            return !(stringValue(payload["handoff_markdown"]) ?? "").isEmpty
        }) else {
            return completed
        }
        let byId = Dictionary(uniqueKeysWithValues: completed.map { ($0.id, $0) })
        let covered = transitiveCoveredIds(latestPayload, byId: byId)
        return completed.filter { $0.id != latestPayload.id && !covered.contains($0.id) } + [latestPayload]
    }

    static func validCompletedCompacts(
        _ activeCompacts: [IOSConversationCompact],
        existingMessageIds: Set<String>
    ) -> [IOSConversationCompact] {
        let byId = Dictionary(activeCompacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var memo: [String: Bool] = [:]
        // A compact is only as valid as the handoffs it absorbed: once an ancestor's
        // source is deleted or replaced, a descendant would re-inject its stale facts.
        func isValid(_ compact: IOSConversationCompact, visiting: Set<String>) -> Bool {
            if let known = memo[compact.id] { return known }
            guard !visiting.contains(compact.id) else { return false }
            let ownValid = compact.status == "completed" &&
                !compact.sourceMessageIds.isEmpty &&
                compact.sourceMessageIds.allSatisfy(existingMessageIds.contains)
            let valid = ownValid && stringList(payloadObject(compact.summary)?["covered_compact_ids"]).allSatisfy { id in
                byId[id].map { isValid($0, visiting: visiting.union([compact.id])) } ?? true
            }
            memo[compact.id] = valid
            return valid
        }
        return activeCompacts
            .filter { isValid($0, visiting: []) }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
