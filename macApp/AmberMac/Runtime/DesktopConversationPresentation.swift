import Foundation

enum DesktopConversationMatchKind: Sendable { case recent, title, message }

struct DesktopConversationSearchResult: Identifiable, Equatable, Sendable {
    var id: UUID { conversationID }
    let conversationID: UUID
    let title: String
    let messageID: UUID?
    let snippet: String
    let matchRange: Range<String.Index>?
    let kind: DesktopConversationMatchKind
    let updatedAt: Date
    let messageCount: Int
    let isPinned: Bool
}

enum DesktopConversationPresentation {
    static func cleanSummary(_ text: String, limit: Int = 90) -> String {
        let value = plainText(text)
        guard limit > 0 else { return "" }
        return value.count > limit ? String(value.prefix(limit - 1)) + "…" : value
    }

    static func summary(for conversation: DesktopConversation, limit: Int = 90) -> String {
        guard limit > 0 else { return "" }
        for message in conversation.messages.reversed() where message.role != .system {
            let text = cleanSummary(message.text, limit: limit)
            if !text.isEmpty { return text }
        }
        return "还没有消息"
    }

    static func search(_ conversations: [DesktopConversation], query: String,
                       snippetLimit: Int = 120) -> [DesktopConversationSearchResult] {
        let query = collapseWhitespace(query)
        let results = conversations.compactMap { conversation -> DesktopConversationSearchResult? in
            let visible = conversation.messages.filter { $0.role != .system }
            let title = plainText(conversation.title)
            let kind: DesktopConversationMatchKind
            let messageID: UUID?
            let snippet: String
            let matchRange: Range<String.Index>?
            if query.isEmpty {
                kind = .recent
                messageID = nil
                snippet = summary(for: conversation, limit: snippetLimit)
                matchRange = nil
            } else if let range = title.range(of: query, options: .caseInsensitive) {
                kind = .title
                messageID = nil
                (snippet, matchRange) = excerpt(title, around: range, limit: snippetLimit)
            } else {
                guard let match = visible.reversed().lazy.compactMap({ message -> (DesktopMessage, String, Range<String.Index>)? in
                    let text = plainText(message.text)
                    guard let range = text.range(of: query, options: .caseInsensitive) else { return nil }
                    return (message, text, range)
                }).first else { return nil }
                kind = .message
                messageID = match.0.id
                (snippet, matchRange) = excerpt(match.1, around: match.2, limit: snippetLimit)
            }
            return DesktopConversationSearchResult(conversationID: conversation.id, title: conversation.title,
                messageID: messageID, snippet: snippet, matchRange: matchRange, kind: kind,
                updatedAt: conversation.updatedAt, messageCount: conversation.messages.count, isPinned: conversation.isPinned)
        }
        return results.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .title }
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.conversationID.uuidString < rhs.conversationID.uuidString
        }
    }

    static func excerpt(_ text: String, around match: Range<String.Index>, limit: Int)
        -> (String, Range<String.Index>?) {
        guard limit > 0 else { return ("", nil) }
        if text.count <= limit { return (text, match) }
        let budget = limit > 2 ? limit - 2 : limit
        var start = text.index(match.lowerBound, offsetBy: -(budget / 3), limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: budget, limitedBy: text.endIndex) ?? text.endIndex
        if end == text.endIndex { start = text.index(end, offsetBy: -budget, limitedBy: text.startIndex) ?? text.startIndex }
        let prefix = limit > 2 && start > text.startIndex ? "…" : ""
        let suffix = limit > 2 && end < text.endIndex ? "…" : ""
        let snippet = prefix + text[start..<end] + suffix
        let lower = max(start, match.lowerBound)
        let upper = min(end, match.upperBound)
        guard lower < upper else { return (snippet, nil) }
        let lowerOffset = prefix.count + text.distance(from: start, to: lower)
        let upperOffset = prefix.count + text.distance(from: start, to: upper)
        return (snippet, snippet.index(snippet.startIndex, offsetBy: lowerOffset)..<snippet.index(snippet.startIndex, offsetBy: upperOffset))
    }

    static func plainText(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var parts: [String] = []
        var fence: (Character, Int)?
        var inTable = false
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let marker = line.first
            let fenceLength = marker.map { value in line.prefix { $0 == value }.count } ?? 0
            if let active = fence {
                if marker == active.0, fenceLength >= active.1,
                   line.dropFirst(fenceLength).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                } else { parts.append(line) }
                continue
            }
            if (marker == "`" || marker == "~"), fenceLength >= 3 {
                fence = (marker!, fenceLength)
                inTable = false
                continue
            }
            if isTableSeparator(line) { continue }
            if ["---", "***", "___"].contains(line) { continue }
            if line.range(of: #"^\[[^\]]+\]:\s+"#, options: .regularExpression) != nil { continue }
            var value = line
                .replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^(?:>\s*)+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            if line.contains("|"), inTable || (index + 1 < lines.count && isTableSeparator(lines[index + 1])) {
                value = DesktopMarkdownParser.tableCells(value).joined(separator: " ")
                inTable = true
            } else { inTable = false }
            value = value
                .replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\[([^\]]+)\]\[[^\]]*\]"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"(\*\*|__|~~)(.*?)\1"#, with: "$2", options: .regularExpression)
                .replacingOccurrences(of: #"(?<!\w)[*_]([^*_]+)[*_](?!\w)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!>|])"#, with: "$1", options: .regularExpression)
            parts.append(value)
        }
        return collapseWhitespace(parts.joined(separator: " "))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return !cells.isEmpty && cells.allSatisfy {
            let value = $0.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
