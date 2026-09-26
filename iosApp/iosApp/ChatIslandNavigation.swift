import SwiftUI
import Shared

@MainActor
enum ChatIslandNavigation {
    enum Target: Equatable {
        case none
        case bottom
        case anchor(ChatMessageAnchor)
        case pendingGate
    }

    static func target(
        for presentation: ChatIslandPresentation,
        conversationID: String,
        messages: [UIMessage],
        pendingRequestID: String?,
        requestToken: UUID? = nil
    ) -> Target {
        let state = presentation.displayedState
        switch state.kind {
        case .title:
            return .none
        case .waiting, .thinking, .generating:
            return .bottom
        case .awaitingUser:
            if let displayedRequestID = state.toolID,
               displayedRequestID != pendingRequestID {
                return .none
            }
            return .pendingGate
        case .tool, .image:
            guard let requestedToolID = state.toolID else { return .none }
            var targetMessage: UIMessage?
            var targetToolCallID: String?
            for message in messages.reversed() {
                for part in message.parts.reversed() {
                    guard let tool = part as? UIMessagePart.Tool,
                          tool.toolCallId.trimmingCharacters(in: .whitespacesAndNewlines) == requestedToolID else {
                        continue
                    }
                    targetMessage = message
                    targetToolCallID = tool.toolCallId
                    break
                }
                if targetMessage != nil { break }
            }
            guard let message = targetMessage,
                  let toolCallID = targetToolCallID else { return .none }
            return .anchor(ChatMessageAnchor(
                conversationID: conversationID,
                messageID: ChatMessageProjector.messageId(for: message),
                toolCallID: toolCallID,
                requestToken: requestToken
            ))
        }
    }
}

struct ChatIslandToolHighlight: Equatable {
    let messageID: String
    let toolCallID: String
    let requestToken: UUID
}

private struct ChatIslandToolHighlightEnvironmentKey: EnvironmentKey {
    static let defaultValue: ChatIslandToolHighlight? = nil
}

extension EnvironmentValues {
    var chatIslandToolHighlight: ChatIslandToolHighlight? {
        get { self[ChatIslandToolHighlightEnvironmentKey.self] }
        set { self[ChatIslandToolHighlightEnvironmentKey.self] = newValue }
    }
}

struct ChatIslandToolAnchorHighlightModifier: ViewModifier {
    let toolCallID: String?
    var cornerRadius: CGFloat? = nil

    @Environment(\.chatIslandToolHighlight) private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHighlighted: Bool {
        guard let toolCallID, let highlight else { return false }
        return highlight.toolCallID.trimmingCharacters(in: .whitespacesAndNewlines) ==
            toolCallID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isHighlighted {
                    Group {
                        if let cornerRadius {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(AmberTheme.accentAmber, lineWidth: 2)
                        } else {
                            Capsule(style: .continuous)
                                .stroke(AmberTheme.accentAmber, lineWidth: 2)
                        }
                    }
                    .shadow(color: AmberTheme.accentAmber.opacity(0.5), radius: 7)
                    .allowsHitTesting(false)
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: highlight?.requestToken
            )
    }
}

extension View {
    func chatIslandToolAnchorHighlight(
        toolCallID: String?,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        modifier(ChatIslandToolAnchorHighlightModifier(
            toolCallID: toolCallID,
            cornerRadius: cornerRadius
        ))
    }
}
