import Foundation
import Combine
import Shared

/// Routes a plain text delta to the mounted live row before publishing structure.
/// All terminal/tool events still publish in order, including events coalesced by
/// SwiftUI. This owner itself is not observable; only structuralSignal is observed.
@MainActor
final class ChatTimelineUpdates {
    let signals = PassthroughSubject<ChatMessageUpdateSignal, Never>()
    private(set) var structuralMessages: [UIMessage] = []
    private(set) var latestSignal = ChatMessageUpdateSignal()
    private var sourceIdentities: [ChatMessageContentIdentity] = []
    private var tailMetadata: [ChatMessageContentIdentity.Metadata?] = []
    private var consumerOwner: UUID?
    private var consume: ((UIMessage, ChatMessageUpdateSignal) -> Bool)?

    func attach(owner: UUID, consume: @escaping (UIMessage, ChatMessageUpdateSignal) -> Bool) {
        consumerOwner = owner
        self.consume = consume
    }

    func detach(owner: UUID) {
        guard consumerOwner == owner else { return }
        consumerOwner = nil
        consume = nil
    }

    /// True means the caller must publish its structural signal. Raw signal
    /// consumers keep receiving every event even when the timeline stays quiet.
    @discardableResult
    func publish(_ signal: ChatMessageUpdateSignal, messages: [UIMessage]) -> Bool {
        latestSignal = signal
        defer { signals.send(signal) }
        if signal.event == .assistantStreamDelta,
           let tail = messages.last,
           canUpdateOnlyTail(messages), consume?(tail, signal) == true {
            sourceIdentities[sourceIdentities.count - 1] = ChatMessageContentIdentity(tail)
            tailMetadata = ChatMessageContentIdentity.metadata(in: tail.parts)
            return false
        }
        structuralMessages = messages
        sourceIdentities = messages.map { ChatMessageContentIdentity($0) }
        tailMetadata = messages.last.map { ChatMessageContentIdentity.metadata(in: $0.parts) } ?? []
        return true
    }

    private func canUpdateOnlyTail(_ messages: [UIMessage]) -> Bool {
        guard sourceIdentities.count == messages.count,
              let previous = sourceIdentities.last?.message, let current = messages.last,
              previous.id == current.id, current.role == .assistant,
              (previous.finishedAt == nil) == (current.finishedAt == nil),
              previous.parts.count == current.parts.count,
              previous.annotations == current.annotations,
              previous.modelId == current.modelId, previous.translation == current.translation,
              Self.hasBodyText(previous) == Self.hasBodyText(current),
              ChatMessageContentIdentity.sameMetadata(tailMetadata,
                  ChatMessageContentIdentity.metadata(in: current.parts)),
              zip(sourceIdentities.dropLast(), messages.dropLast()).allSatisfy({ $0.matches($1) })
        else { return false }
        return zip(previous.parts, current.parts).allSatisfy { old, new in
            if old is UIMessagePart.Text, new is UIMessagePart.Text { return true }
            if let old = old as? UIMessagePart.Reasoning, let new = new as? UIMessagePart.Reasoning {
                return (old.finishedAt == nil) == (new.finishedAt == nil)
            }
            return old === new
        }
    }

    private static func hasBodyText(_ message: UIMessage) -> Bool {
        message.parts.contains { ($0 as? UIMessagePart.Text)?.text.contains { !$0.isWhitespace } == true }
    }
}
