import CryptoKit
import Foundation
import OSLog

struct ChatSuggestionFeedbackEvent: Codable, Sendable {
    enum Kind: String, Codable { case shown, accepted, edited, submitted, ignored }
    let id: UUID
    let date: Date
    let presentationID: UUID
    let sourceDigest: String
    let modelID: String
    let kind: Kind
    var reason: String? = nil
    var exactMatch: Bool? = nil
    var changedCharacters: Int? = nil
    var suggestionCount: Int? = nil
    var candidateIndex: Int? = nil
}

/// The prediction and draft live only in memory. The local event log stores
/// counters/identities and edit size, never message, tool or prediction text.
struct ChatSuggestionFeedbackSession {
    private struct Exposure {
        let id = UUID()
        let source: ChatSuggestionSource
        let suggestions: [String]
        let modelID: String
        var shown = false
        var acceptedIndex: Int?
    }
    private var exposure: Exposure?

    mutating func prepare(source: ChatSuggestionSource, suggestions: [String], modelID: String) -> [ChatSuggestionFeedbackEvent] {
        let previous = dismiss(reason: "replaced")
        if !suggestions.isEmpty {
            exposure = Exposure(source: source, suggestions: suggestions, modelID: modelID)
        }
        return previous
    }

    mutating func shown() -> [ChatSuggestionFeedbackEvent] {
        guard var current = exposure, !current.shown else { return [] }
        current.shown = true
        exposure = current
        return [event(.shown, current)]
    }

    mutating func accept(_ text: String) -> [ChatSuggestionFeedbackEvent] {
        guard var current = exposure, let index = current.suggestions.firstIndex(of: text), current.acceptedIndex == nil else { return [] }
        var events = shown()
        current.shown = true
        current.acceptedIndex = index
        exposure = current
        events.append(event(.accepted, current))
        return events
    }

    mutating func submit(_ text: String) -> [ChatSuggestionFeedbackEvent] {
        guard let current = exposure, current.shown else { exposure = nil; return [] }
        exposure = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = current.acceptedIndex ?? current.suggestions.firstIndex(of: trimmed) ?? 0
        let original = Array(current.suggestions[index].trimmingCharacters(in: .whitespacesAndNewlines))
        let submitted = Array(trimmed)
        let same = original == submitted
        var prefix = 0
        while prefix < min(original.count, submitted.count), original[prefix] == submitted[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(original.count, submitted.count) - prefix,
              original[original.count - 1 - suffix] == submitted[submitted.count - 1 - suffix] { suffix += 1 }
        // Size of the changed span, not a claim of semantic similarity or a
        // Levenshtein distance. It also captures a manually typed exact match.
        let changed = max(original.count, submitted.count) - prefix - suffix
        var result = event(.submitted, current)
        result.candidateIndex = index
        result.exactMatch = same
        result.changedCharacters = changed
        var events: [ChatSuggestionFeedbackEvent] = []
        if current.acceptedIndex != nil, !same {
            var edited = event(.edited, current)
            edited.changedCharacters = changed
            events.append(edited)
        } else if current.acceptedIndex == nil {
            var ignored = event(.ignored, current)
            ignored.reason = "typed_own_message"
            events.append(ignored)
        }
        events.append(result)
        return events
    }

    mutating func dismiss(reason: String) -> [ChatSuggestionFeedbackEvent] {
        defer { exposure = nil }
        guard let current = exposure, current.shown else { return [] }
        var ignored = event(.ignored, current)
        ignored.reason = reason
        return [ignored]
    }

    private func event(_ kind: ChatSuggestionFeedbackEvent.Kind, _ current: Exposure) -> ChatSuggestionFeedbackEvent {
        let key = "\(current.source.host)|\(current.source.scope)|\(current.source.turn)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(id: UUID(), date: Date(), presentationID: current.id, sourceDigest: digest,
                     modelID: current.modelID, kind: kind, suggestionCount: current.suggestions.count,
                     candidateIndex: current.acceptedIndex)
    }
}

actor ChatSuggestionFeedbackStore {
    static let shared = ChatSuggestionFeedbackStore()
    private static let logger = Logger(subsystem: "app.amber.ios", category: "suggestion-feedback")
    private let url: URL
    private let capacity: Int

    init(url: URL = URL.applicationSupportDirectory.appendingPathComponent("SuggestionFeedback/events.json"), capacity: Int = 512) {
        self.url = url
        self.capacity = capacity
    }

    func append(_ events: [ChatSuggestionFeedbackEvent]) {
        guard !events.isEmpty else { return }
        do {
            var history: [ChatSuggestionFeedbackEvent] = []
            if FileManager.default.fileExists(atPath: url.path) {
                history = try JSONDecoder().decode([ChatSuggestionFeedbackEvent].self, from: Data(contentsOf: url))
            }
            history.append(contentsOf: events)
            let bounded = Array(history.suffix(capacity))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(bounded).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.logger.error("Could not save local suggestion feedback: \(error.localizedDescription, privacy: .public)")
        }
    }
}
