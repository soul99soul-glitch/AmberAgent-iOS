import Foundation
@preconcurrency import Shared

struct ChatSuggestionSource: Equatable, Sendable {
    let host: String
    let scope: String
    let turn: String
}

struct ChatSuggestionContext: Sendable {
    struct Entry: Sendable {
        let role: String
        let text: String
    }

    let source: ChatSuggestionSource
    let content: String
    let latestUserText: String
    let latestAssistantText: String

    // Budget by complete user turns rather than by an arbitrary number of messages:
    // a tool-heavy turn must not crowd its own request out of the prediction.
    init(source: ChatSuggestionSource, entries: [Entry], summary: String? = nil,
         pendingWork: [String] = [], budget: Int = 24_000) {
        let budget = max(128, budget)
        self.source = source
        latestUserText = entries.last(where: { $0.role == "User" })?.text ?? ""
        latestAssistantText = entries.last(where: { $0.role == "Assistant" })?.text ?? ""
        var turns: [[Entry]] = []
        for entry in entries {
            if entry.role == "User" || turns.isEmpty { turns.append([]) }
            turns[turns.count - 1].append(entry)
        }
        var header = ""
        if let summary, !summary.isEmpty {
            header += "Earlier context summary:\n\(summary.prefix(min(4_000, budget / 3)))\n\n"
        }
        if !pendingWork.isEmpty {
            header += "Work still in progress (do not restart it):\n\(pendingWork.prefix(8).joined(separator: "\n").prefix(budget / 6))\n\n"
        }
        var selected: [String] = []
        var remaining = max(0, budget - header.count)
        for turn in turns.reversed() {
            let block = turn.map { "\($0.role): \($0.text)" }.joined(separator: "\n\n")
            if block.count + 2 > remaining {
                if selected.isEmpty {
                    // Preserve both the request and the final result of an unusually large turn.
                    let essentials = turn.count > 9 ? Array(turn.prefix(1)) + Array(turn.suffix(8)) : turn
                    let perEntry = max(1, remaining / max(1, essentials.count) - 20)
                    selected.append(essentials.map { "\($0.role): \(Self.excerpt($0.text, limit: perEntry))" }
                        .joined(separator: "\n\n"))
                }
                break
            }
            selected.append(block)
            remaining -= block.count + 2
        }
        content = String((header + selected.reversed().joined(separator: "\n\n")).prefix(budget))
    }

    static func local(messages: [UIMessage], conversationID: String?, summary: String?,
                      waitingForChild: Bool) -> ChatSuggestionContext? {
        guard let last = messages.last, last.role == .assistant, !last.toText().isEmpty else { return nil }
        var entries: [Entry] = []
        var characters = 0
        for message in messages.reversed() {
            guard message.role == .user || message.role == .assistant else { continue }
            var text: [String] = []
            for part in message.parts {
                if let part = part as? UIMessagePart.Text {
                    text.append(excerpt(part.text, limit: 8_000))
                } else if let tool = part as? UIMessagePart.Tool {
                    let output = tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n")
                    if !output.isEmpty {
                        text.append("Tool result [\(tool.toolName)]: \(excerpt(output, limit: 2_000))")
                    } else {
                        text.append("Tool [\(tool.toolName)]: not completed")
                    }
                }
            }
            let value = text.joined(separator: "\n")
            if !value.isEmpty {
                entries.append(.init(role: message.role == .user ? "User" : "Assistant", text: value))
                characters += value.count
            }
            if characters >= 24_000, message.role == .user { break }
        }
        return .init(source: .init(host: "local", scope: conversationID ?? "draft", turn: String(describing: last.id)),
                     entries: Array(entries.reversed()), summary: summary,
                     pendingWork: waitingForChild ? ["A delegated task is still running; wait for its actual result."] : [])
    }

    static func cloud(events: [MacGatewayCloudDialogueEvent], host: String, replyID: String,
                      pendingWork: [String]) -> ChatSuggestionContext? {
        guard let reply = events.last(where: { $0.id == replyID }),
              reply.kind == .assistantReply || reply.kind == .taskResult,
              reply.outcome != .failed, reply.outcome != .cancelled,
              !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let entries = events.filter { $0.seq <= reply.seq }.compactMap { event -> Entry? in
            switch event.kind {
            case .userMessage, .followup: return .init(role: "User", text: excerpt(event.text, limit: 8_000))
            case .assistantReply, .taskResult: return .init(role: "Assistant", text: excerpt(event.text, limit: 8_000))
            default: return nil
            }
        }
        return .init(source: .init(host: host, scope: "main", turn: replyID), entries: entries, pendingWork: pendingWork)
    }

    static func excerpt(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let half = max(0, (limit - 24) / 2)
        return String(text.prefix(half)) + "\n[content omitted]\n" + String(text.suffix(half))
    }
}

enum ChatSuggestionFilter {
    static let maximumCount = 3

    static func candidates(from raw: String, context: ChatSuggestionContext) -> [String] {
        guard !raw.contains("```"), !raw.contains("[NO_SUGGESTION]") else { return [] }
        let lines = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen: Set<String> = []
        var result: [String] = []
        for line in lines {
            guard let text = candidate(from: line, context: context), seen.insert(normalize(text)).inserted else { continue }
            result.append(text)
            if result.count == maximumCount { break }
        }
        return result
    }

    private static func candidate(from line: String, context: ChatSuggestionContext) -> String? {
        let text = line.replacingOccurrences(of: #"^\s*(?:[-*•]|\d+[.)、])\s+"#,
                                                with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」"))
        let normalized = normalize(text)
        let generic: Set<String> = ["好", "好的", "继续", "继续吧", "谢谢", "ok", "okay", "yes", "goon"]
        guard !text.isEmpty, text.count <= 160, !generic.contains(normalized),
              normalized != "nosuggestion", normalized != "null", normalized != "none",
              normalized != normalize(context.latestUserText),
              normalized != normalize(context.latestAssistantText),
              !text.contains("```"), !text.contains("<content>"),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let assistantPrefixes = ["assistant:", "作为ai", "作为一个ai", "我来帮你", "我可以帮你", "以下是", "as an ai", "i can help you", "here are"]
        guard !assistantPrefixes.contains(where: { text.lowercased().hasPrefix($0) }) else { return nil }
        return text
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
