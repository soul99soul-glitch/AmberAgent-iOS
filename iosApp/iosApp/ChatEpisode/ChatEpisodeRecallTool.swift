import Foundation
@preconcurrency import Shared

/// Resident, read-only, approval-free tool (`episode_recall`) allowing the main assistant
/// to inspect archived `Episode` transcripts in the current single-stream conversation on demand.
@MainActor
enum ChatEpisodeRecallTool {
    nonisolated static let name = ChatEpisodeConstants.recallToolName
    private static let defaultMaxChars = 6_000
    private static let hardMaxChars = 12_000

    nonisolated static var declaration: Tool {
        let schema = """
        {
          "type": "object",
          "properties": {
            "episode_id": {
              "type": "string",
              "description": "Exact Episode ID from the Recent Episodes Index (for example, 'ep_0012'). Pass this when resuming or checking a specific archived topic."
            },
            "query": {
              "type": "string",
              "description": "Keyword or phrase to search across archived Episodes in this conversation when episode_id is unknown or when filtering specific details."
            },
            "offset": {
              "type": "integer",
              "description": "Optional character offset (0-based) to paginate through a very long Episode transcript."
            },
            "max_chars": {
              "type": "integer",
              "description": "Maximum transcript characters to return (default 6000, max 12000)."
            }
          },
          "additionalProperties": false
        }
        """
        return IosToolExposureBridgeKt.createDynamicWorkflowToolDeclaration(
            toolId: name,
            version: "1",
            description: "Read-only recall of archived prior topic segments (Episodes) in the current single-stream conversation. Answer quick summary questions directly from Recent Episodes Index; call episode_recall with episode_id or query when exact prior dialogue, numbers, or verbatim context are needed.",
            inputsJson: schema,
            effectClass: "pure"
        )
    }

    @MainActor
    static func execute(
        arguments: String,
        currentConversationId: KotlinUuid?,
        conversationStore: IOSConversationStore?,
        episodeStore: ChatEpisodeStore = .shared
    ) async -> String {
        guard let currentConversationId else {
            return errorJSON(code: "missing_conversation", reason: "当前会话尚未就绪，无法读取归档话题。")
        }
        guard let conversationStore else {
            return errorJSON(code: "missing_store", reason: "会话存储不可用。")
        }

        let parsedArgs = parseArguments(arguments)
        let requestedId = parsedArgs.episodeId
        let query = parsedArgs.query
        let offset = max(0, parsedArgs.offset)
        let maxChars = min(max(400, parsedArgs.maxChars), hardMaxChars)

        let conversationKey = currentConversationId.toHexDashString()
        let episodes = episodeStore.episodes(for: conversationKey)
        guard !episodes.isEmpty else {
            return json([
                "ok": true,
                "tool": name,
                "episodes": [],
                "message": "当前对话尚无已归档的历史话题（所有内容均在当前活跃上下文中）。"
            ])
        }

        let messages: [UIMessage]
        if conversationStore.currentConversation?.id == currentConversationId {
            messages = conversationStore.currentMessages
        } else if let loaded = try? await conversationStore.loadConversationForOrchestration(currentConversationId) {
            messages = loaded.currentMessages
        } else {
            return errorJSON(code: "read_failed", reason: "无法加载当前对话的历史消息记录。")
        }

        // Case 1: Exact `episode_id` lookup.
        if !requestedId.isEmpty {
            guard let matched = episodeStore.episode(id: requestedId, in: conversationKey) else {
                let available = episodes.suffix(12).map { ep in
                    [
                        "episode_id": ep.id,
                        "time": ep.formattedTimestamp(),
                        "title": ep.title,
                        "summary": ep.summary
                    ]
                }
                return json([
                    "ok": false,
                    "tool": name,
                    "error": "episode_not_found",
                    "reason": "未找到编号为 \(requestedId) 的归档话题。",
                    "available_episodes": available
                ])
            }
            return buildEpisodeTranscriptResponse(
                episode: matched,
                allMessages: messages,
                queryFilter: query,
                offset: offset,
                maxChars: maxChars
            )
        }

        // Case 2: Keyword `query` across all archived Episodes in this conversation.
        if !query.isEmpty {
            return searchEpisodesByQuery(
                query: query,
                episodes: episodes,
                allMessages: messages,
                offset: offset,
                maxChars: maxChars
            )
        }

        // Case 3: Neither `episode_id` nor `query` provided — return the catalog of archived Episodes (up to latest 16).
        let catalog = episodes.suffix(16).reversed().map { ep -> [String: Any] in
            [
                "episode_id": ep.id,
                "time": ep.formattedTimestamp(),
                "turns": ep.turnCount,
                "title": ep.title,
                "summary": ep.summary
            ]
        }
        return json([
            "ok": true,
            "tool": name,
            "total_archived_episodes": episodes.count,
            "episodes": catalog,
            "hint": "传入 episode_id（如 ep_0001）可读取该段完整原始对话，或传入 query 按关键词跨段检索。"
        ])
    }

    // MARK: - Transcript Assembly & Search

    private static func buildEpisodeTranscriptResponse(
        episode: ChatEpisodeRecord,
        allMessages: [UIMessage],
        queryFilter: String,
        offset: Int,
        maxChars: Int
    ) -> String {
        let slice = sliceMessages(for: episode, in: allMessages)
        let formattedLines = formatTranscriptLines(slice, queryFilter: queryFilter)
        let fullTranscript = formattedLines.joined(separator: "\n\n")
        let paginated = paginate(text: fullTranscript, offset: offset, maxChars: maxChars)

        var payload: [String: Any] = [
            "ok": true,
            "tool": name,
            "episode_id": episode.id,
            "time": episode.formattedTimestamp(),
            "turns": episode.turnCount,
            "title": episode.title,
            "summary": episode.summary,
            "message_count": slice.count,
            "offset": paginated.offset,
            "total_chars": paginated.totalChars,
            "has_more": paginated.hasMore,
            "transcript": paginated.slice
        ]
        if let nextOffset = paginated.nextOffset {
            payload["next_offset"] = nextOffset
        }
        return json(payload)
    }

    private static func searchEpisodesByQuery(
        query: String,
        episodes: [ChatEpisodeRecord],
        allMessages: [UIMessage],
        offset: Int,
        maxChars: Int
    ) -> String {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
        let effectiveTerms = terms.isEmpty ? [query.lowercased()] : terms

        struct ScoredMatch {
            let episode: ChatEpisodeRecord
            let score: Int
            let matchedMessages: [UIMessage]
        }

        var matches: [ScoredMatch] = []
        for episode in episodes.reversed() {
            let slice = sliceMessages(for: episode, in: allMessages)
            let headerHaystack = "\(episode.id) \(episode.title) \(episode.summary)".lowercased()
            var score = 0
            for term in effectiveTerms where headerHaystack.contains(term) {
                score += 4
            }
            var hitMessages: [UIMessage] = []
            for message in slice {
                let text = renderedMessageContent(message).lowercased()
                let termHits = effectiveTerms.filter { text.contains($0) }.count
                if termHits > 0 {
                    score += termHits * 2
                    hitMessages.append(message)
                }
            }
            if score > 0 {
                matches.append(ScoredMatch(
                    episode: episode,
                    score: score,
                    matchedMessages: hitMessages.isEmpty ? slice : hitMessages
                ))
            }
        }

        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.episode.ordinal > $1.episode.ordinal
        }

        guard let top = matches.first else {
            return json([
                "ok": true,
                "tool": name,
                "query": query,
                "matches": [],
                "message": "在归档话题中未检索到与「\(query)」匹配的记录。"
            ])
        }

        // If a single Episode clearly dominates or was matched, include its verbatim slice plus compact index of other matches.
        let topSlice = sliceMessages(for: top.episode, in: allMessages)
        let lines = formatTranscriptLines(topSlice, queryFilter: "")
        let paginated = paginate(text: lines.joined(separator: "\n\n"), offset: offset, maxChars: maxChars)
        let otherMatches = matches.dropFirst().prefix(5).map { item -> [String: Any] in
            [
                "episode_id": item.episode.id,
                "time": item.episode.formattedTimestamp(),
                "title": item.episode.title,
                "summary": item.episode.summary,
                "score": item.score
            ]
        }

        var response: [String: Any] = [
            "ok": true,
            "tool": name,
            "query": query,
            "matched_episode_id": top.episode.id,
            "time": top.episode.formattedTimestamp(),
            "title": top.episode.title,
            "summary": top.episode.summary,
            "offset": paginated.offset,
            "total_chars": paginated.totalChars,
            "has_more": paginated.hasMore,
            "transcript": paginated.slice,
            "other_matches": otherMatches
        ]
        if let nextOffset = paginated.nextOffset {
            response["next_offset"] = nextOffset
        }
        return json(response)
    }

    static func sliceMessages(for episode: ChatEpisodeRecord, in allMessages: [UIMessage]) -> [UIMessage] {
        let idSet = Set(episode.messageIds)
        let direct = allMessages.filter { idSet.contains(ChatMessageProjector.messageId(for: $0)) }
        if !direct.isEmpty {
            return direct
        }
        guard let startIdx = allMessages.firstIndex(where: { ChatMessageProjector.messageId(for: $0) == episode.startMessageId }),
              let endIdx = allMessages.lastIndex(where: { ChatMessageProjector.messageId(for: $0) == episode.endMessageId }),
              startIdx <= endIdx else {
            return []
        }
        return Array(allMessages[startIdx...endIdx]).filter { $0.role != MessageRole.system }
    }

    @MainActor
    private static func formatTranscriptLines(_ messages: [UIMessage], queryFilter: String) -> [String] {
        let trimmedFilter = queryFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var lines: [String] = []
        for message in messages {
            guard message.role != MessageRole.system,
                  !IOSOrchestrationConfigurationCodec.isOrchestrationConfigurationMessage(message) else {
                continue
            }
            let content = renderedMessageContent(message)
            guard !content.isEmpty else { continue }
            if !trimmedFilter.isEmpty && !content.lowercased().contains(trimmedFilter) {
                continue
            }
            let roleLabel: String
            if ChatMessageProjector.isSubAgentResult(message) {
                roleLabel = "subagent_result"
            } else if message.role == MessageRole.user {
                roleLabel = "user"
            } else {
                roleLabel = "assistant"
            }
            let stamp = String(
                format: "%02ld:%02ld",
                Int(message.createdAt.hour),
                Int(message.createdAt.minute)
            )
            lines.append("[\(roleLabel) \(stamp)] \(content)")
        }
        if lines.isEmpty && !trimmedFilter.isEmpty {
            // Fall back to unfiltered Episode messages if `queryFilter` was too narrow for exact substring.
            return formatTranscriptLines(messages, queryFilter: "")
        }
        return lines
    }

    @MainActor
    private static func renderedMessageContent(_ message: UIMessage) -> String {
        let raw: String
        if ChatMessageProjector.isSubAgentResult(message) {
            raw = ChatEpisodeTextNormalizer.mailboxBody(of: message) ?? message.toText()
        } else {
            var chunks: [String] = []
            for part in message.parts {
                if let text = part as? UIMessagePart.Text {
                    let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { chunks.append(trimmed) }
                } else if part is UIMessagePart.Image {
                    chunks.append("[图片附件]")
                } else if let doc = part as? UIMessagePart.Document {
                    chunks.append("[文档: \(doc.fileName)]")
                }
            }
            raw = chunks.joined(separator: "\n")
        }
        return IOSContextCompactionFidelity.redactCredentials(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func paginate(
        text: String,
        offset: Int,
        maxChars: Int
    ) -> (slice: String, offset: Int, totalChars: Int, hasMore: Bool, nextOffset: Int?) {
        let chars = Array(text)
        let total = chars.count
        let clampedOffset = min(max(0, offset), total)
        let end = min(total, clampedOffset + maxChars)
        let slice = clampedOffset < end ? String(chars[clampedOffset..<end]) : ""
        let hasMore = end < total
        return (slice, clampedOffset, total, hasMore, hasMore ? end : nil)
    }

    // MARK: - Argument Parsing & JSON Formatting

    private struct ParsedArgs {
        let episodeId: String
        let query: String
        let offset: Int
        let maxChars: Int
    }

    private static func parseArguments(_ raw: String) -> ParsedArgs {
        guard let obj = ChatToolCallParsing.jsonObject(raw) else {
            return ParsedArgs(episodeId: "", query: raw.trimmingCharacters(in: .whitespacesAndNewlines), offset: 0, maxChars: defaultMaxChars)
        }
        let episodeId = (obj["episode_id"] as? String ?? obj["id"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let query = (obj["query"] as? String ?? obj["keyword"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = (obj["offset"] as? NSNumber)?.intValue ?? 0
        let maxChars = (obj["max_chars"] as? NSNumber)?.intValue ?? defaultMaxChars
        return ParsedArgs(episodeId: episodeId, query: query, offset: offset, maxChars: maxChars)
    }

    private static func errorJSON(code: String, reason: String) -> String {
        json([
            "ok": false,
            "tool": name,
            "error": code,
            "reason": reason
        ])
    }

    private static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"tool\":\"episode_recall\",\"error\":\"encoding_failed\"}"
        }
        return encoded
    }
}
