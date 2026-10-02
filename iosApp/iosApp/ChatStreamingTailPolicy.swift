import SwiftUI

struct ChatSwiftUIStreamingTailVisibilityState: Equatable {
    var messageID: String?
    var isVisible: Bool?

    init(messageID: String? = nil, isVisible: Bool? = nil) {
        self.messageID = messageID
        self.isVisible = isVisible
    }
}

enum ChatSwiftUIStreamingTailRenderPolicy {
    static func shouldSuspend(
        isLastAssistant: Bool,
        hasEverStreamed: Bool,
        messageID: String,
        visibility: ChatSwiftUIStreamingTailVisibilityState
    ) -> Bool {
        isLastAssistant &&
            hasEverStreamed &&
            visibility.messageID == messageID &&
            visibility.isVisible == false
    }
}

/// Whether a scroll phase change is a real user drag that should pause
/// follow-to-bottom. Shared by the chat timeline and the Novel session list.
enum NativeTimelineUserDragPolicy {
    static func shouldBegin(
        phase: ScrollPhase,
        isUIKitUserInteracting: Bool
    ) -> Bool {
        switch phase {
        case .tracking:
            return true
        case .interacting:
            return isUIKitUserInteracting
        case .idle, .decelerating, .animating:
            return false
        @unknown default:
            return false
        }
    }
}
