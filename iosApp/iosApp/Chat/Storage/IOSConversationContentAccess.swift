import Foundation
@preconcurrency import Shared

struct IOSConversationSearchResult: Identifiable {
    enum Kind: String {
        case conversation
        case message

        var title: String {
            switch self {
            case .conversation: "会话"
            case .message: "消息"
            }
        }
    }

    let id: String
    let conversationId: KotlinUuid
    let kind: Kind
    let title: String
    let preview: String
    let highlight: String
    let updateAt: Int64
}

/// session_search 工具的聚合命中（每会话一条）。由 [IOSConversationStore.sessionSearchHits]
/// 从 [IOSConversationSearchResult] 派生：snippet 优先取消息命中预览（含关键词上下文），
/// messageCount 取会话摘要的真实消息数。
struct IOSSessionSearchHit {
    let conversationId: KotlinUuid
    let title: String
    let snippet: String
    let updatedAt: Int64
    let messageCount: Int32
}

extension IOSConversationStore {
    func currentConversationDeepReadSource(maxMessages: Int = 12) throws -> IOSDeepReadSource {
        let messages = currentMessages.suffix(max(maxMessages, 1)).compactMap { message -> String? in
            let text = message.toText().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(Self.boardRoleName(message.role)): \(String(text.prefix(1_200)))"
        }
        let title = currentConversation?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? currentConversation?.title ?? "当前会话"
            : "当前会话"
        return try IOSDeepReadSourceNormalizer.conversationSource(
            title: title,
            messages: messages
        )
    }

    @discardableResult
    func appendDeepReadResultToCurrentConversation(_ task: IOSDeepReadTask) async -> Bool {
        guard let conversation = currentConversation else { return false }
        let markdown = task.resultMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return false }

        var nextMessages = currentMessages
        let message = UIMessage.companion.assistant(
            prompt: """
            已保存深度阅读结果：\(task.title)

            \(markdown)
            """
        )
        nextMessages.append(message)
        await save(messages: nextMessages, to: conversation.id)
        return true
    }

    /// Global search over persisted conversation titles and message text.
    ///
    /// Read-only by design: it does not switch current conversation, bump revision,
    /// or mutate metadata. SearchView decides whether to open a result.
    func searchConversations(query rawQuery: String, limit: Int = 60) async -> [IOSConversationSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }

        let sourceSummaries = await visibleSummariesForListing()

        var results: [IOSConversationSearchResult] = []
        for summary in sourceSummaries {
            guard !Task.isCancelled else { return [] }
            let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新对话" : summary.title
            let updateAt = summary.updateAt.toEpochMilliseconds()

            if title.localizedCaseInsensitiveContains(query) {
                results.append(IOSConversationSearchResult(
                    id: "\(summary.id)-title",
                    conversationId: summary.id,
                    kind: .conversation,
                    title: title,
                    preview: "\(summary.messageCount) 条消息",
                    highlight: query,
                    updateAt: updateAt
                ))
                if results.count >= limit { break }
            }

            guard let conversation = try? await storage.loadConversation(id: summary.id) else { continue }
            guard !Task.isCancelled else { return [] }
            let messages = Self.searchableMessages(in: conversation)
            for (messageIndex, message) in messages.enumerated() {
                guard !Task.isCancelled else { return [] }
                let text = message.toText().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.localizedCaseInsensitiveContains(query) else { continue }
                results.append(IOSConversationSearchResult(
                    id: "\(summary.id)-message-\(messageIndex)",
                    conversationId: summary.id,
                    kind: .message,
                    title: title,
                    preview: Self.searchPreview(from: text, around: query),
                    highlight: query,
                    updateAt: updateAt
                ))
                if results.count >= limit { break }
            }
            if results.count >= limit { break }
        }
        return Task.isCancelled ? [] : results
    }

    /// session_search 工具用：把 [searchConversations] 的逐条命中聚合为每会话一条。
    /// 只读（不切当前会话、不 bump revision、不写盘）；snippet 优先取消息命中预览
    /// （含关键词上下文），标题命中兜底；messageCount 取会话摘要的真实消息数。
    func sessionSearchHits(query: String, limit: Int = 8) async -> [IOSSessionSearchHit] {
        let results = await searchConversations(query: query, limit: limit)
        guard !results.isEmpty else { return [] }

        let sourceSummaries = await visibleSummariesForListing()
        let countByConversation = Dictionary(
            sourceSummaries.map { ($0.id.toHexDashString(), $0.messageCount) },
            uniquingKeysWith: { first, _ in first }
        )

        var orderedKeys: [String] = []
        var byConversation: [String: (id: KotlinUuid, title: String, titleSnippet: String?, messageSnippet: String?, updatedAt: Int64)] = [:]
        for result in results {
            let key = result.conversationId.toHexDashString()
            if byConversation[key] == nil {
                orderedKeys.append(key)
                byConversation[key] = (result.conversationId, result.title, nil, nil, result.updateAt)
            }
            guard var entry = byConversation[key] else { continue }
            if result.kind == .message {
                if entry.messageSnippet == nil { entry.messageSnippet = result.preview }
            } else if entry.titleSnippet == nil {
                entry.titleSnippet = result.preview
            }
            entry.updatedAt = max(entry.updatedAt, result.updateAt)
            byConversation[key] = entry
        }

        var hits: [IOSSessionSearchHit] = []
        for key in orderedKeys {
            guard let entry = byConversation[key] else { continue }
            hits.append(IOSSessionSearchHit(
                conversationId: entry.id,
                title: entry.title,
                snippet: entry.messageSnippet ?? entry.titleSnippet ?? "",
                updatedAt: entry.updatedAt,
                messageCount: countByConversation[key] ?? 0
            ))
        }
        return hits
    }

    /// Read-only export for iOS Board chat-history collection.
    ///
    /// This does not switch `currentConversation`, bump `currentRevision`, mutate metadata,
    /// or write back to disk. It loads recent conversations by summary id and returns a
    /// compact tail window for the Board collector's local heuristics.
    func boardSignalCandidates(limit: Int = 30) async -> [IOSBoardConversationCandidate] {
        let sourceSummaries = await visibleSummariesForListing()

        var candidates: [IOSBoardConversationCandidate] = []
        for summary in sourceSummaries.prefix(max(limit, 0)) {
            guard let conversation = try? await storage.loadConversation(id: summary.id) else { continue }
            let title = conversation.title.isEmpty ? summary.title : conversation.title
            let tailNodes = Array(conversation.messageNodes.suffix(6))
            let tailTexts = tailNodes.flatMap { node in
                node.messages.compactMap { message -> String? in
                    let text = message.toText().trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return "\(Self.boardRoleName(message.role)): \(String(text.prefix(500)))"
                }
            }

            let fallbackTexts = conversation.currentMessages.compactMap { message -> String? in
                let text = message.toText().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return "\(Self.boardRoleName(message.role)): \(String(text.prefix(500)))"
            }

            candidates.append(IOSBoardConversationCandidate(
                id: String(describing: conversation.id),
                title: title.isEmpty ? "未命名对话" : title,
                updateAt: conversation.updateAt.toEpochMilliseconds(),
                nodeCount: conversation.messageNodes.count,
                tailTexts: tailTexts.isEmpty ? fallbackTexts : tailTexts
            ))
        }
        return candidates
    }

    // MARK: - Private helpers

    private static func boardRoleName(_ role: MessageRole) -> String {
        if role == MessageRole.user { return "user" }
        if role == MessageRole.assistant { return "assistant" }
        if role == MessageRole.system { return "system" }
        if role == MessageRole.tool { return "tool" }
        return String(describing: role).lowercased()
    }

    static func searchableMessages(in conversation: Conversation) -> [UIMessage] {
        let nodeMessages = conversation.messageNodes.flatMap { node in
            node.messages
        }
        if !nodeMessages.isEmpty {
            return nodeMessages
        }
        return conversation.currentMessages
    }

    private static func searchPreview(from text: String, around query: String, maxLength: Int = 96) -> String {
        let compact = text
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
        guard compact.count > maxLength else { return compact }

        guard let range = compact.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(compact.prefix(maxLength)) + "..."
        }

        let prefix = String(compact[..<range.lowerBound].suffix(28))
        let remainingLength = max(maxLength - prefix.count, 24)
        let suffix = String(compact[range.lowerBound...].prefix(remainingLength))
        let leading = compact.distance(from: compact.startIndex, to: range.lowerBound) > prefix.count ? "..." : ""
        let trailing = compact.distance(from: range.lowerBound, to: compact.endIndex) > suffix.count ? "..." : ""
        return leading + prefix + suffix + trailing
    }
}
