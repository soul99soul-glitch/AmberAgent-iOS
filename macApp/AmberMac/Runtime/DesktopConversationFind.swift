import Foundation

/// Messages whose visible text contains the query, case-insensitively, in transcript order.
struct DesktopConversationFind: Equatable {
    private(set) var matches: [UUID] = []
    private(set) var current: Int?

    var currentMessageID: UUID? { current.map { matches[$0] } }
    var label: String { matches.isEmpty ? "0/0" : "\((current ?? 0) + 1)/\(matches.count)" }

    static func matches(_ query: String, in messages: [DesktopMessage]) -> [UUID] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return messages.filter { $0.text.range(of: query, options: .caseInsensitive) != nil }.map(\.id)
    }

    /// Recomputes matches, keeping the current message selected when it still matches.
    mutating func update(_ query: String, messages: [DesktopMessage]) {
        let previous = currentMessageID
        matches = Self.matches(query, in: messages)
        current = matches.isEmpty ? nil : previous.flatMap { matches.firstIndex(of: $0) } ?? 0
    }

    mutating func step(_ offset: Int) {
        guard !matches.isEmpty else { return }
        current = ((current ?? 0) + offset % matches.count + matches.count) % matches.count
    }
}
