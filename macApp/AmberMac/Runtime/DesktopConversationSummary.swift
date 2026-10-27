import Foundation

struct DesktopConversationSummary: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var isPinned: Bool
    var messageCount: Int
    var preview: String?

    init(id: UUID, title: String, updatedAt: Date, isPinned: Bool, messageCount: Int, preview: String? = nil) {
        self.id = id; self.title = title; self.updatedAt = updatedAt
        self.isPinned = isPinned; self.messageCount = messageCount; self.preview = preview
    }

    init(_ conversation: DesktopConversation) {
        self.init(id: conversation.id, title: conversation.title, updatedAt: conversation.updatedAt,
            isPinned: conversation.isPinned, messageCount: conversation.messages.count,
            preview: DesktopConversationPresentation.summary(for: conversation))
    }

    var presentation: DesktopConversationSearchResult {
        DesktopConversationSearchResult(conversationID: id, title: title, messageID: nil,
            snippet: preview ?? (messageCount == 0 ? "还没有消息" : "点击读取完整对话"), matchRange: nil,
            kind: .recent, updatedAt: updatedAt, messageCount: messageCount, isPinned: isPinned)
    }

    func titleMatch(_ query: String) -> DesktopConversationSearchResult? {
        let text = DesktopConversationPresentation.plainText(title)
        guard let range = text.range(of: query, options: .caseInsensitive) else { return nil }
        let (snippet, highlight) = DesktopConversationPresentation.excerpt(text, around: range, limit: 120)
        return DesktopConversationSearchResult(conversationID: id, title: title, messageID: nil,
            snippet: snippet, matchRange: highlight, kind: .title, updatedAt: updatedAt,
            messageCount: messageCount, isPinned: isPinned)
    }

    static func ordered(_ values: [DesktopConversationSummary]) -> [DesktopConversationSummary] {
        values.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

// A search hit is a text projection, never a partially populated full conversation.
struct DesktopStoredConversationSearchHit: Decodable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let isPinned: Bool
    let messageCount: Int
    let kind: String
    let messageID: UUID?
    let matchedText: String

    func presentation(query: String) -> DesktopConversationSearchResult {
        let text = DesktopConversationPresentation.plainText(matchedText)
        let snippet: String
        let highlight: Range<String.Index>?
        if let range = text.range(of: query, options: .caseInsensitive) {
            (snippet, highlight) = DesktopConversationPresentation.excerpt(text, around: range, limit: 120)
        } else {
            snippet = DesktopConversationPresentation.cleanSummary(text, limit: 120)
            highlight = nil
        }
        return DesktopConversationSearchResult(conversationID: id, title: title, messageID: messageID,
            snippet: snippet, matchRange: highlight, kind: kind == "title" ? .title : .message,
            updatedAt: updatedAt, messageCount: messageCount, isPinned: isPinned)
    }
}
