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

    // MARK: - Private helpers

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
