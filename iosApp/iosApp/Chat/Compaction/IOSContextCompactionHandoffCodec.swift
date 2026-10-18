import Foundation
@preconcurrency import Shared

extension IOSContextCompactionCoordinator {
    static let defaultHandoffPrompt = """
    # Context Compaction Handoff

    Write a continuation handoff for another model that will resume the same conversation.

    Return valid JSON only. The JSON must include:
    - `schema_version`: 2
    - `timeline_summary`: 4-5 human-readable sentences in the user's language, written for the chat timeline
    - `handoff_markdown`: dense Markdown for the next model, with sections: Goal, Constraints, Progress, Decisions, Current State, Next Steps, Critical Context, Relevant Files
    - `covered_compact_ids`: the compact ids from the provided previous handoffs that this handoff carries forward

    The timeline summary is for humans. The handoff Markdown is for the model. Preserve concrete names, files, commands, errors, user preferences, approvals, rejected approaches, and unresolved decisions. Do not include raw tool logs unless they are needed to continue safely.
    """

    static func skipped(reason: String, messages: [UIMessage], modelContextWindowTokens: Int?) -> IOSCompactPlan {
        IOSCompactPlan(
            shouldCompact: false,
            reason: reason,
            estimatedTokens: estimateTokens(messages),
            contextWindowTokens: estimateContextWindow(modelContextWindowTokens),
            sourceStartIndex: 0,
            sourceEndIndex: -1,
            sourceMessageIds: []
        )
    }

    static func estimateAfterCompaction(
        messages: [UIMessage],
        activeCompacts: [IOSConversationCompact],
        plan: IOSCompactPlan,
        maxSummaryTokens: Int
    ) -> Int {
        guard plan.shouldCompact else { return plan.estimatedTokens }
        let existingIds = Set(messages.map(messageId))
        let completed = validCompletedCompacts(activeCompacts, existingMessageIds: existingIds)
        let carried = selectCompactsForInjection(activeCompacts: activeCompacts, existingMessageIds: existingIds)
        let carriedIds = transitiveCompactIds(carried)
        let remainingSummaryMessages = completed
            .filter { !carriedIds.contains($0.id) }
            .map { UIMessage.companion.system(prompt: injectionText($0)) }
        let coveredIds = Set(completed.flatMap(\.sourceMessageIds) + plan.sourceMessageIds)
        let recent = messages.filter { !coveredIds.contains(messageId($0)) }
        return estimateTokens(remainingSummaryMessages) + estimateTokens(recent) + max(maxSummaryTokens, 256)
    }

    static func transitiveCompactIds(_ compacts: [IOSConversationCompact]) -> Set<String> {
        let byId = Dictionary(uniqueKeysWithValues: compacts.map { ($0.id, $0) })
        var seen = Set<String>()
        func visit(_ id: String) {
            guard !seen.contains(id) else { return }
            seen.insert(id)
            guard let compact = byId[id],
                  let payload = payloadObject(compact.summary) else { return }
            stringList(payload["covered_compact_ids"]).forEach(visit)
        }
        compacts.forEach { visit($0.id) }
        return seen
    }

    static func transitiveCoveredIds(
        _ compact: IOSConversationCompact,
        byId: [String: IOSConversationCompact]
    ) -> Set<String> {
        var seen = Set<String>()
        func visit(_ id: String) {
            guard !seen.contains(id) else { return }
            seen.insert(id)
            guard let parent = byId[id],
                  let payload = payloadObject(parent.summary) else { return }
            stringList(payload["covered_compact_ids"]).forEach(visit)
        }
        payloadObject(compact.summary)
            .map { stringList($0["covered_compact_ids"]).forEach(visit) }
        return seen
    }

    static func estimatedChars(_ part: UIMessagePart) -> Int {
        ContextTokenEstimateMemo.shared.estimatedChars(part)
    }

    static func summaryLine(_ part: UIMessagePart) -> String {
        switch part {
        case let text as UIMessagePart.Text:
            // Message text is what the covered history is replaced with; keep it whole up
            // to a generous cap (the summarizer budget fit decides how many messages go in).
            return "text: \(text.text.takeMiddle(maxChars: maxCompressionTextChars))"
        case let reasoning as UIMessagePart.Reasoning:
            return "reasoning_marker: \(reasoning.reasoning.count) chars"
        case let tool as UIMessagePart.Tool:
            return "tool: \(tool.toolName) id=\(tool.toolCallId) executed=\(!tool.output.isEmpty) input=\(tool.input.takeMiddle(maxChars: 2_000)) output=\(summarizeToolOutput(tool.output))"
        case let image as UIMessagePart.Image:
            return "image: \(String(image.url.suffix(80)))"
        case let video as UIMessagePart.Video:
            return "video: \(String(video.url.suffix(80)))"
        case let audio as UIMessagePart.Audio:
            return "audio: \(String(audio.url.suffix(80)))"
        case let document as UIMessagePart.Document:
            return "document: \(document.fileName) mime=\(document.mime)"
        case let miniApp as UIMessagePart.MiniApp:
            return "mini_app: \(miniApp.title) id=\(miniApp.appId)"
        default:
            return String(describing: part)
        }
    }

    static func summarizeToolOutput(_ parts: [UIMessagePart], maxChars: Int = 8_000) -> String {
        let raw = parts.map { part -> String in
            if let text = part as? UIMessagePart.Text { return text.text }
            if let tool = part as? UIMessagePart.Tool {
                return "nested_tool:\(tool.toolName):\(summarizeToolOutput(tool.output, maxChars: maxChars / 2))"
            }
            return String(describing: part)
        }.joined(separator: "\n")
        return raw.takeMiddle(maxChars: maxChars)
    }

    static func editMessageTools(
        messages: [UIMessage],
        keepRecentMessages: Int,
        transform: (UIMessagePart.Tool) -> UIMessagePart.Tool
    ) -> [UIMessage] {
        messages.enumerated().map { index, message in
            guard index < messages.count - max(keepRecentMessages, 0),
                  !messageHasMultimodalPart(message) else { return message }
            var changed = false
            let parts = message.parts.map { part -> UIMessagePart in
                guard let tool = part as? UIMessagePart.Tool else { return part }
                let next = transform(tool)
                if next != tool { changed = true }
                return next
            }
            guard changed else { return message }
            return UIMessage(
                id: message.id,
                role: message.role,
                parts: parts,
                annotations: message.annotations,
                createdAt: message.createdAt,
                finishedAt: message.finishedAt,
                modelId: message.modelId,
                usage: message.usage,
                translation: message.translation
            )
        }
    }

    /// 被压缩处理过的工具输出原位留下的可见占位标记,让模型识别历史有空洞。
    static let compactedToolOutputMarker = "[tool output compacted]"

    static func trimToolResult(_ tool: UIMessagePart.Tool) -> UIMessagePart.Tool {
        guard canEditPreparedResult(tool) else { return tool }
        let outputChars = outputChars(tool.output)
        guard outputChars > 16_000 else { return tool }
        let preview = summarizeToolOutput(tool.output, maxChars: 8_000)
        return replacingToolOutput(tool, text: """
            \(compactedToolOutputMarker) — original result trimmed to a preview.
            \(jsonString([
                "status": "trimmed_tool_result",
                "tool_name": tool.toolName,
                "tool_call_id": tool.toolCallId,
                "original_output_chars": outputChars,
                "preview": preview
            ]))
            """)
    }

    static func clearToolResult(_ tool: UIMessagePart.Tool) -> UIMessagePart.Tool {
        guard canEditPreparedResult(tool),
              safeToClearPreparedResult(tool) else { return tool }
        let outputChars = outputChars(tool.output)
        guard outputChars > clearMinOutputChars else { return tool }
        return replacingToolOutput(tool, text: """
            \(compactedToolOutputMarker) — historical result removed from this prepared context.
            \(jsonString([
                "status": "cleared_tool_result",
                "tool_name": tool.toolName,
                "tool_call_id": tool.toolCallId,
                "input_chars": tool.input.count,
                "original_output_chars": outputChars,
                "reason": "Historical result was cleared from prepared context only. Original conversation storage is unchanged; call the tool again or expand history if exact output is needed."
            ]))
            """)
    }

    static func replacingToolOutput(_ tool: UIMessagePart.Tool, text: String) -> UIMessagePart.Tool {
        PromptTranscript.shared.doCopyTool(
            tool: tool,
            input: tool.input,
            output: [UIMessagePart.Text(text: text, metadata: nil)]
        )
    }

    static func canEditPreparedResult(_ tool: UIMessagePart.Tool) -> Bool {
        !tool.output.isEmpty &&
            !partsContainMultimodal(tool.output) &&
            !outputLooksFailedOrDenied(tool.output)
    }

    static func safeToClearPreparedResult(_ tool: UIMessagePart.Tool) -> Bool {
        clearableToolNames.contains(tool.toolName) ||
            tool.toolName.hasPrefix("conversation_") ||
            (tool.toolName.hasPrefix("session_") && !sensitiveSessionTools.contains(tool.toolName))
    }

    static let clearableToolNames: Set<String> = [
        "file_list",
        "file_read",
        "file_search",
        "tools_list",
        "tool_search",
        "tool_policy_explain",
        "conversation_context_status",
        "conversation_search",
        "conversation_expand",
        "runtime_status",
        "agent_runtime_status",
        "agent_task_list",
        "agent_task_read",
        "mcp_list"
    ]

    static let sensitiveSessionTools: Set<String> = ["session_read", "session_expand"]
}

extension IOSContextCompactionCoordinator {
    static func limitContext(_ messages: [UIMessage], size: Int) -> [UIMessage] {
        guard size > 0, messages.count > size else { return messages }
        let startIndex = messages.count - size
        var adjustedStartIndex = startIndex
        var visited = Set<Int>()
        var needsAdjustment = true

        while needsAdjustment && adjustedStartIndex > 0 {
            needsAdjustment = false
            guard !visited.contains(adjustedStartIndex) else { break }
            visited.insert(adjustedStartIndex)
            let current = messages[adjustedStartIndex]
            if messageHasExecutedTool(current) {
                for index in stride(from: adjustedStartIndex - 1, through: 0, by: -1) {
                    if messageHasPendingTool(messages[index]) {
                        adjustedStartIndex = index
                        needsAdjustment = true
                        break
                    }
                }
            }
            if messageHasPendingTool(current) {
                for index in stride(from: adjustedStartIndex - 1, through: 0, by: -1) {
                    if messages[index].role == MessageRole.user {
                        adjustedStartIndex = index
                        needsAdjustment = true
                        break
                    }
                }
            }
        }
        return Array(messages[adjustedStartIndex..<messages.count])
    }

    static func messageId(_ message: UIMessage) -> String {
        String(describing: message.id)
    }

    private static func messageHasExecutedTool(_ message: UIMessage) -> Bool {
        message.parts.contains { ($0 as? UIMessagePart.Tool)?.output.isEmpty == false }
    }

    static func messageHasPendingTool(_ message: UIMessage) -> Bool {
        message.parts.contains { ($0 as? UIMessagePart.Tool)?.output.isEmpty == true }
    }

    static func messageHasMultimodalPart(_ message: UIMessage) -> Bool {
        partsContainMultimodal(message.parts)
    }

    private static func partsContainMultimodal(_ parts: [UIMessagePart]) -> Bool {
        parts.contains { part in
            switch part {
            case is UIMessagePart.Image, is UIMessagePart.Video, is UIMessagePart.Audio, is UIMessagePart.Document:
                return true
            case let tool as UIMessagePart.Tool:
                return partsContainMultimodal(tool.output)
            default:
                return false
            }
        }
    }

    private static func outputLooksFailedOrDenied(_ parts: [UIMessagePart]) -> Bool {
        parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.contains { text in
            let lower = text.lowercased()
            return lower.contains("\"status\":\"failed\"") ||
                lower.contains("\"status\":\"denied\"") ||
                lower.contains("\"approval_required\"") ||
                lower.contains("\"error\"")
        }
    }

    static func outputChars(_ parts: [UIMessagePart]) -> Int {
        parts.reduce(0) { total, part in
            if let text = part as? UIMessagePart.Text { return total + text.text.count }
            if let reasoning = part as? UIMessagePart.Reasoning { return total + reasoning.reasoning.count }
            if let tool = part as? UIMessagePart.Tool { return total + tool.input.count + outputChars(tool.output) }
            return total + String(describing: part).count
        }
    }

    static func intValue(_ value: KotlinInt?) -> Int? {
        value.map { Int(truncating: $0) }
    }

    static func supportsTextGeneration(_ provider: ProviderSetting) -> Bool {
        provider is ProviderSetting.OpenAI || provider is ProviderSetting.Claude
    }

    static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

extension IOSContextCompactionCoordinator {
    static func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let jsonText = locateJSONObject(text),
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func payloadObject(_ summary: String) -> [String: Any]? {
        guard let object = parseJSONObject(summary) else { return nil }
        if object["timeline_summary"] != nil ||
            object["handoff_markdown"] != nil ||
            (object["schema_version"] as? Int) == 2 {
            return object
        }
        return nil
    }

    private static func locateJSONObject(_ text: String) -> String? {
        let characters = Array(text)
        guard let start = characters.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<characters.count {
            let char = characters[index]
            if escaped {
                escaped = false
                continue
            }
            if inString && char == "\\" {
                escaped = true
                continue
            }
            if char == "\"" {
                inString.toggle()
                continue
            }
            guard !inString else { continue }
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(characters[start...index])
                }
            }
        }
        return nil
    }

    static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value {
            return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func stringList(_ value: Any?) -> [String] {
        if let array = value as? [String] { return array }
        if let array = value as? [Any] { return array.compactMap { stringValue($0) } }
        return []
    }

    static func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func cleanHumanText(_ text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.hasPrefix("{") else { return nil }
        return cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func cleanMarkdown(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func coerceTimelineSummary(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return "Conversation history was compacted for continuation."
        }
        return String(cleaned.prefix(maxTimelineSummaryChars))
    }
}
