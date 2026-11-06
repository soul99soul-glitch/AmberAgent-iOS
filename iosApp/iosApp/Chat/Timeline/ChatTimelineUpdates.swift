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
    private var tailHasBodyText = false
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
        #if DEBUG
        if ChatRenderProbe.enabled {
            ChatRenderProbe.record("timeline-publish:\(signal.event)")
        }
        #endif
        latestSignal = signal
        defer { signals.send(signal) }
        if signal.event == .assistantStreamDelta {
            guard let tail = messages.last else {
                ChatRenderProbe.record("tail-fastpath:fail-no-tail")
                structuralMessages = messages
                sourceIdentities = messages.map { ChatMessageContentIdentity($0) }
                tailHasBodyText = messages.last.map(Self.hasBodyText) ?? false
                return true
            }
            guard let previousTailIdentity = sourceIdentities.last else {
                ChatRenderProbe.record("tail-fastpath:fail-no-prev-identity")
                structuralMessages = messages
                sourceIdentities = messages.map { ChatMessageContentIdentity($0) }
                tailHasBodyText = messages.last.map(Self.hasBodyText) ?? false
                return true
            }
            if canUpdateOnlyTail(messages, previousTailIdentity: previousTailIdentity),
               consume?(tail, signal) == true {
                sourceIdentities[sourceIdentities.count - 1] = ChatMessageContentIdentity(
                    reusingMetadataFrom: previousTailIdentity,
                    message: tail
                )
                return false
            }
        }
        structuralMessages = messages
        sourceIdentities = messages.map { ChatMessageContentIdentity($0) }
        tailHasBodyText = messages.last.map(Self.hasBodyText) ?? false
        return true
    }

    private func canUpdateOnlyTail(
        _ messages: [UIMessage],
        previousTailIdentity: ChatMessageContentIdentity
    ) -> Bool {
        let previous = previousTailIdentity.message
        guard sourceIdentities.count == messages.count else {
            ChatRenderProbe.record("tail-fastpath:fail-count")
            return false
        }
        guard let current = messages.last else {
            ChatRenderProbe.record("tail-fastpath:fail-no-current")
            return false
        }
        guard previous.id == current.id else {
            ChatRenderProbe.record("tail-fastpath:fail-id")
            return false
        }
        guard current.role == .assistant else {
            ChatRenderProbe.record("tail-fastpath:fail-role")
            return false
        }
        guard (previous.finishedAt == nil) == (current.finishedAt == nil) else {
            ChatRenderProbe.record("tail-fastpath:fail-finishedAt")
            return false
        }
        guard previous.parts.count == current.parts.count else {
            ChatRenderProbe.record("tail-fastpath:fail-parts-count")
            return false
        }
        guard previous.annotations == current.annotations else {
            ChatRenderProbe.record("tail-fastpath:fail-annotations")
            return false
        }
        guard previous.modelId == current.modelId, previous.translation == current.translation else {
            ChatRenderProbe.record("tail-fastpath:fail-model-or-translation")
            return false
        }
        guard tailHasBodyText == Self.hasBodyText(current) else {
            ChatRenderProbe.record("tail-fastpath:fail-tailHasBodyText")
            return false
        }
        guard previousTailIdentity.hasSameMetadata(as: current.parts) else {
            ChatRenderProbe.record("tail-fastpath:fail-metadata")
            return false
        }
        guard zip(sourceIdentities.dropLast(), messages.dropLast()).allSatisfy({ $0.matches($1) }) else {
            ChatRenderProbe.record("tail-fastpath:fail-history-match")
            return false
        }
        let partsMatch = zip(previous.parts, current.parts).allSatisfy { old, new in
            if old is UIMessagePart.Text, new is UIMessagePart.Text { return true }
            if let old = old as? UIMessagePart.Reasoning, let new = new as? UIMessagePart.Reasoning {
                return (old.finishedAt == nil) == (new.finishedAt == nil)
            }
            return old === new
        }
        guard partsMatch else {
            ChatRenderProbe.record("tail-fastpath:fail-parts-identity")
            return false
        }
        ChatRenderProbe.record("tail-fastpath:hit")
        return true
    }

    private static func hasBodyText(_ message: UIMessage) -> Bool {
        message.parts.contains { ($0 as? UIMessagePart.Text)?.text.contains { !$0.isWhitespace } == true }
    }
}
