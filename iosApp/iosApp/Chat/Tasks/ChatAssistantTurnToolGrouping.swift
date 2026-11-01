import Foundation
import Shared

// MARK: - One progress line per assistant turn (L1 projection)

/// Every tool of one assistant turn, whichever messages they arrived in. The
/// head message renders this as the turn's single in-place progress line.
struct ChatAssistantTurnProgress {
    /// UUID of the turn's first tool message (even before the loaded window).
    let id: String
    let headMessageID: String
    /// All assistant messages of the turn, in order; tools and reasoning are read at render time.
    let messages: [UIMessage]
    let tools: [UIMessagePart.Tool]
    let anchorIDs: [String]
    /// The turn is still being extended by the active generation.
    let isLive: Bool
    /// Live, every tool has been called, and reply text is arriving after the last one.
    let isComposingReply: Bool
    let signature: Int
}

enum ChatAssistantTurnRole: Equatable {
    case head(ChatAssistantTurnProgress)
    /// `isCollapsed`: nothing of its own to show. Otherwise it keeps its text and
    /// media but never draws a task row of its own.
    case member(groupID: String, isCollapsed: Bool, hasVisibleText: Bool)

    var progress: ChatAssistantTurnProgress? {
        if case let .head(progress) = self { return progress }
        return nil
    }

    var isCollapsedMember: Bool {
        if case let .member(_, isCollapsed, _) = self { return isCollapsed }
        return false
    }

    var signature: Int {
        var hasher = Hasher()
        switch self {
        case let .head(progress):
            hasher.combine("turn-head")
            hasher.combine(progress.signature)
        case let .member(groupID, isCollapsed, hasVisibleText):
            hasher.combine("turn-member")
            hasher.combine(groupID)
            hasher.combine(isCollapsed)
            hasher.combine(hasVisibleText)
        }
        return hasher.finalize()
    }

    /// Signature equality only: never compare Kotlin tool payloads.
    static func == (lhs: ChatAssistantTurnRole, rhs: ChatAssistantTurnRole) -> Bool {
        lhs.signature == rhs.signature
    }
}

enum ChatAssistantTurnToolGrouping {
    private struct Turn {
        var prefixMessages: [UIMessage] = []
        var memberIndices: [Int] = []
    }

    /// Pure pass over message entries; roles align with `entries`. Turns made only
    /// of phone steps stay with `ChatPhoneToolGrouping`, which already draws one row.
    static func roles(
        entries: [NativeTimelineEntry],
        messages: [UIMessage],
        isGenerationActive: Bool
    ) -> [ChatAssistantTurnRole?] {
        var roles = [ChatAssistantTurnRole?](repeating: nil, count: entries.count)
        var current: Turn?
        func close() {
            if let turn = current {
                assign(turn, entries: entries, isGenerationActive: isGenerationActive, into: &roles)
            }
            current = nil
        }
        if let windowStart = entries.first(where: { $0.kind == .message })?.index {
            let prefix = prefixMessages(messages: messages, before: windowStart)
            if !prefix.isEmpty { current = Turn(prefixMessages: prefix) }
        }
        for index in entries.indices {
            let entry = entries[index]
            guard entry.kind == .message else {
                if entry.kind == .contextMarker { close() }
                continue
            }
            guard let message = entry.message,
                  message.role == MessageRole.assistant,
                  !entry.hasMultipleVariants,
                  !ChatMessageProjector.isSubAgentResult(message) else {
                close()
                continue
            }
            if current == nil { current = Turn() }
            current?.memberIndices.append(index)
        }
        close()
        return roles
    }

    /// Whether a tail update can change any turn. Plain reply text only matters the
    /// moment it first appears, so text streaming skips the regrouping pass.
    static func tailMayAffectTurns(tail: UIMessage, previousRole: ChatAssistantTurnRole?) -> Bool {
        if tail.parts.contains(where: { $0 is UIMessagePart.Tool || $0 is UIMessagePart.Reasoning }) {
            return true
        }
        guard case let .member(_, _, hasVisibleText) = previousRole else {
            return previousRole != nil
        }
        return !hasVisibleText && containsVisibleText(tail)
    }

    private static func assign(
        _ turn: Turn,
        entries: [NativeTimelineEntry],
        isGenerationActive: Bool,
        into roles: inout [ChatAssistantTurnRole?]
    ) {
        let loaded = turn.memberIndices.compactMap { index in entries[index].message.map { (index, $0) } }
        let turnMessages = turn.prefixMessages + loaded.map(\.1)
        let tools = turnMessages.flatMap(toolParts)
        guard !tools.isEmpty,
              !tools.allSatisfy({ ChatPhoneToolGrouping.isPhoneTool($0.toolName) }),
              let firstToolMessage = turnMessages.first(where: { !toolParts($0).isEmpty }),
              let head = loaded.first(where: { !toolParts($0.1).isEmpty }),
              let headMessageID = entries[head.0].messageId else { return }

        let groupID = ChatMessageProjector.messageId(for: firstToolMessage)
        let isLive = isGenerationActive && (loaded.last.map { entries[$0.0].isLastMessage } ?? false)
        let isComposingReply = isLive && endsWithReplyText(turnMessages)
        let anchorIDs = turnMessages.flatMap { message -> [String] in
            let messageID = ChatMessageProjector.messageId(for: message)
            return toolParts(message).map {
                ChatToolCallAnchorTarget.id(messageID: messageID, toolCallID: $0.toolCallId)
            }
        }

        var hasher = Hasher()
        hasher.combine(groupID)
        hasher.combine(headMessageID)
        for tool in tools {
            hasher.combine(tool.toolCallId)
            hasher.combine(tool.toolName)
            hasher.combine(tool.output.count)
            ChatPartSignature.combineApproval(tool.approvalState, into: &hasher)
        }
        for part in tools.last?.output ?? [] {
            ChatPartSignature.combine(part, exactText: false, into: &hasher)
        }
        hasher.combine(isLive)
        hasher.combine(isComposingReply)

        let progress = ChatAssistantTurnProgress(
            id: groupID,
            headMessageID: headMessageID,
            messages: turnMessages,
            tools: tools,
            anchorIDs: anchorIDs,
            isLive: isLive,
            isComposingReply: isComposingReply,
            signature: hasher.finalize()
        )
        for (index, message) in loaded {
            roles[index] = index == head.0
                ? .head(progress)
                : .member(
                    groupID: groupID,
                    isCollapsed: isCollapsible(message),
                    hasVisibleText: containsVisibleText(message)
                )
        }
    }

    /// Earlier assistant messages of the turn cut off by the loaded window.
    private static func prefixMessages(messages: [UIMessage], before index: Int) -> [UIMessage] {
        var reversed: [UIMessage] = []
        var cursor = min(index, messages.count) - 1
        while cursor >= 0 {
            let message = messages[cursor]
            cursor -= 1
            guard ChatMessageProjector.isVisibleInTimeline(message) else { continue }
            guard message.role == MessageRole.assistant,
                  !ChatMessageProjector.isSubAgentResult(message) else { break }
            reversed.append(message)
        }
        return reversed.reversed()
    }

    private static func toolParts(_ message: UIMessage) -> [UIMessagePart.Tool] {
        message.parts.compactMap { $0 as? UIMessagePart.Tool }
    }

    private static func containsVisibleText(_ message: UIMessage) -> Bool {
        message.parts.contains { part in
            (part as? UIMessagePart.Text)?.text.contains(where: { !$0.isWhitespace }) == true
        }
    }

    /// Only tools and reasoning: the head line already stands for this message.
    /// Citations, media and any other part keep the message on screen.
    private static func isCollapsible(_ message: UIMessage) -> Bool {
        guard message.annotations.isEmpty else { return false }
        return message.parts.allSatisfy { part in
            if let tool = part as? UIMessagePart.Tool {
                return !ChatTaskStreamGrouping.isMediaBearing(tool)
            }
            if let text = part as? UIMessagePart.Text {
                return !text.text.contains(where: { !$0.isWhitespace })
            }
            return part is UIMessagePart.Reasoning
        }
    }

    private static func endsWithReplyText(_ messages: [UIMessage]) -> Bool {
        for message in messages.reversed() {
            for part in message.parts.reversed() {
                if part is UIMessagePart.Tool { return false }
                if let text = part as? UIMessagePart.Text,
                   text.text.contains(where: { !$0.isWhitespace }) {
                    return true
                }
            }
        }
        return false
    }
}
