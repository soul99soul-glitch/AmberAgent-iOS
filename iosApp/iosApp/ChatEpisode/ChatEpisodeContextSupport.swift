import Foundation
@preconcurrency import Shared

/// Provides active Episode message slicing, deterministic high-density Episode digests,
/// and the token-bounded resident `Recent Episodes Index` (`<= 8` items, `<= 300` tokens).
@MainActor
enum ChatEpisodeContextSupport {

    /// Slices `messages` so that LLM upload / compaction / occupancy only sees `system` messages
    /// plus conversation messages strictly after the latest archived Episode boundary.
    /// Full historical `UIMessage` rows remain untouched in `IOSConversationStore` and `ChatViewModel.messages`.
    @MainActor
    static func activeEpisodeMessages(
        from messages: [UIMessage],
        conversationId: String?,
        store: ChatEpisodeStore = .shared
    ) -> [UIMessage] {
        guard let conversationId, !conversationId.isEmpty, !messages.isEmpty else {
            return messages
        }
        guard let anchorId = store.activeBoundaryMessageId(for: conversationId, in: messages),
              let anchorIndex = messages.lastIndex(where: {
                  $0.role != MessageRole.system && ChatMessageProjector.messageId(for: $0) == anchorId
              }) else {
            return messages
        }

        var filtered: [UIMessage] = []
        filtered.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            if message.role == MessageRole.system
                || IOSOrchestrationConfigurationCodec.isOrchestrationConfigurationMessage(message) {
                filtered.append(message)
            } else if index > anchorIndex {
                filtered.append(message)
            }
        }
        return filtered
    }

    /// Builds the resident `Recent Episodes Index` prompt section for the latest `<= 8` sealed Episodes,
    /// strictly enforcing `<= 300` estimated tokens.
    /// Orchestrated child worker threads receive `""` to preserve strict worker context isolation.
    @MainActor
    static func recentEpisodesPrompt(
        conversationId: String?,
        isOrchestratedChild: Bool = false,
        store: ChatEpisodeStore = .shared
    ) -> String {
        guard !isOrchestratedChild else { return "" }
        let allEpisodes = store.episodes(for: conversationId)
        guard !allEpisodes.isEmpty else { return "" }
        return formatRecentEpisodesPrompt(
            episodes: Array(allEpisodes.suffix(ChatEpisodeConstants.maxRecentEpisodesInIndex)),
            maxTokens: ChatEpisodeConstants.maxRecentEpisodesIndexTokens
        )
    }

    /// Pure formatter so unit tests can verify exact `<= 8` item selection and `<= 300` token budgeting deterministically.
    static func formatRecentEpisodesPrompt(
        episodes: [ChatEpisodeRecord],
        maxTokens: Int = ChatEpisodeConstants.maxRecentEpisodesIndexTokens
    ) -> String {
        let recent = Array(episodes.suffix(ChatEpisodeConstants.maxRecentEpisodesInIndex))
        guard !recent.isEmpty, maxTokens > 0 else { return "" }

        let header = "Recent Episodes Index (前序归档话题微目录；当前上下文仅装载新话题):"
        let footer = "可直接据此回答前序概要；若用户追问历史细节或要求接着某段继续，调用 `episode_recall`（传 `episode_id` 或 `query`）精确调阅原文。"

        // Try progressively tighter summary lengths first so all 8 recent episodes stay visible whenever possible.
        let candidateSummaryCaps = [56, 44, 34, 24, 16]
        for cap in candidateSummaryCaps {
            let lines = recent.map { $0.indexLine(maxSummaryChars: cap) }
            let candidate = ([header] + lines + [footer]).joined(separator: "\n")
            if estimatedTokens(for: candidate) <= maxTokens {
                return candidate
            }
        }

        // Fallback: drop oldest of the 8 at tightest cap until strictly within `maxTokens`.
        var trimmedRecent = recent
        while !trimmedRecent.isEmpty {
            let lines = trimmedRecent.map { $0.indexLine(maxSummaryChars: 16) }
            let candidate = ([header] + lines + [footer]).joined(separator: "\n")
            if estimatedTokens(for: candidate) <= maxTokens {
                return candidate
            }
            trimmedRecent.removeFirst()
        }
        return ""
    }

    /// Uses both KMP request token estimation and a conservative character/CJK token ceiling
    /// so the block never exceeds `300` tokens across OpenAI / Anthropic / Gemini tokenizers.
    @MainActor
    static func estimatedTokens(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let coordinatorTokens = IOSContextCompactionCoordinator.estimatedTokensForRequest(
            [UIMessage.companion.system(prompt: text)]
        )
        var cjkScalars = 0
        var asciiScalars = 0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x2E80 {
                cjkScalars += 1
            } else {
                asciiScalars += 1
            }
        }
        let conservativeTokenizerEstimate = Int(ceil(Double(cjkScalars) * 0.85 + Double(asciiScalars) * 0.28)) + 8
        return max(coordinatorTokens, conservativeTokenizerEstimate)
    }
}

/// Deterministic high-density fallback summarizer used synchronously at seal time (zero latency for the next turn)
/// and retained if background model refinement is offline or unconfigured.
enum ChatEpisodeSummarizer {
    struct Digest: Equatable, Sendable {
        let title: String
        let summary: String
    }

    static func buildDeterministicDigest(from messages: [UIMessage]) -> Digest {
        let userTexts = messages
            .filter { $0.role == MessageRole.user && !ChatMessageProjector.isSubAgentResult($0) }
            .map { cleanedMessageText($0) }
            .filter { !$0.isEmpty }

        let assistantTexts = messages
            .filter {
                $0.role == MessageRole.assistant || ChatMessageProjector.isSubAgentResult($0)
            }
            .map { cleanedMessageText($0) }
            .filter { !$0.isEmpty }

        let firstUser = userTexts.first ?? ""
        let lastUser = userTexts.count > 1 ? (userTexts.last ?? "") : ""
        let lastAssistant = assistantTexts.last ?? ""

        let title = deriveTitle(from: firstUser.isEmpty ? lastAssistant : firstUser)
        let salientFacts = extractSalientNumbersAndEntities(from: userTexts + assistantTexts)
        let conclusion = deriveConclusionSnippet(lastAssistant: lastAssistant, lastUser: lastUser, firstUser: firstUser)

        var summaryParts: [String] = []
        if !conclusion.isEmpty {
            summaryParts.append(conclusion)
        }
        for token in salientFacts where !summaryParts.joined(separator: "，").contains(token) {
            summaryParts.append(token)
            if summaryParts.count >= 3 { break }
        }
        let rawSummary = summaryParts.joined(separator: "；")
        let finalSummary = ChatEpisodeTextNormalizer.singleLine(
            rawSummary.isEmpty ? title : rawSummary,
            maxChars: ChatEpisodeConstants.defaultIndexSummaryMaxChars
        )
        return Digest(
            title: title.isEmpty ? "归档话题" : title,
            summary: finalSummary.isEmpty ? "前序对话重点已归档" : finalSummary
        )
    }

    private static func cleanedMessageText(_ message: UIMessage) -> String {
        let text: String
        if ChatMessageProjector.isSubAgentResult(message) {
            text = ChatEpisodeTextNormalizer.mailboxBody(of: message) ?? message.toText()
        } else {
            text = message.parts
                .compactMap { ($0 as? UIMessagePart.Text)?.text }
                .joined(separator: " ")
        }
        let stripped = text
            .replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[#*>`~_\[\]]+"#, with: "", options: .regularExpression)
        return ChatEpisodeTextNormalizer.singleLine(stripped, maxChars: 240)
    }

    private static func deriveTitle(from raw: String) -> String {
        guard !raw.isEmpty else { return "归档话题" }
        let strippedPrefix = raw.replacingOccurrences(
            of: #"^(请问|帮我|麻烦你|麻烦|我想问一下|我想了解|关于|来看看|看一下|分析一下|聊聊)\s*"#,
            with: "",
            options: .regularExpression
        )
        let firstClause = strippedPrefix
            .components(separatedBy: CharacterSet(charactersIn: "。！？!?；;\n，,：:"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? strippedPrefix
        return ChatEpisodeTextNormalizer.singleLine(firstClause, maxChars: ChatEpisodeConstants.maxTitleChars)
    }

    private static func deriveConclusionSnippet(lastAssistant: String, lastUser: String, firstUser: String) -> String {
        let source = !lastAssistant.isEmpty ? lastAssistant : (!lastUser.isEmpty ? lastUser : firstUser)
        guard !source.isEmpty else { return "" }
        let sentences = source
            .components(separatedBy: CharacterSet(charactersIn: "。！？!?\n；;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }

        // Prefer sentences with numbers, conclusions, or action markers.
        let priorityMarkers = ["结论", "建议", "总计", "预算", "每月", "/月", "元", "$", "%", "待办", "下一步", "决定", "确认", "方案"]
        if let hit = sentences.first(where: { sentence in
            priorityMarkers.contains(where: { sentence.contains($0) })
                || sentence.range(of: #"\d"#, options: .regularExpression) != nil
        }) {
            return ChatEpisodeTextNormalizer.singleLine(hit, maxChars: 44)
        }
        return ChatEpisodeTextNormalizer.singleLine(sentences.first ?? source, maxChars: 44)
    }

    private static func extractSalientNumbersAndEntities(from texts: [String]) -> [String] {
        let combined = texts.joined(separator: " ")
        guard !combined.isEmpty else { return [] }
        let pattern = #"(?:[$¥€£]\s?\d[\d,.]*|\d[\d,.]*\s?(?:元|万|亿|美元|刀|/月|每月|%|天|小时|周|个月|年|条|份|ms|GB|MB))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(combined.startIndex..<combined.endIndex, in: combined)
        var results: [String] = []
        for match in regex.matches(in: combined, range: nsRange) {
            guard let range = Range(match.range, in: combined) else { continue }
            let token = String(combined[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty, !results.contains(token) {
                results.append(token)
            }
            if results.count >= 3 { break }
        }
        return results
    }
}
