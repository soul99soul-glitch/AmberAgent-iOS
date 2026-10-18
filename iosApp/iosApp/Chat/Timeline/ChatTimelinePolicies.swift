import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine

enum ChatListAction {
    case regenerate(messageId: String)
    case requestEdit(messageId: String, currentText: String)
    case edit(messageId: String, newText: String)
    case delete(messageId: String)
    case selectVariant(messageId: String, variantIndex: Int)
    case generativeWidget(prompt: String)
    case modifyGeneratedImage(urlString: String, prompt: String, aspectRatio: String)
    case openMiniApp(appId: String)
    case openMiniApps
    case openSubagentConversation(id: String)
    case primaryConfiguration
    case modelDefaults
}

enum NativeChatTimelineSessionIdentity {
    static func viewID(conversationId: KotlinUuid?) -> String {
        guard let conversationId else { return "native-timeline:no-conversation" }
        return "native-timeline:\(String(describing: conversationId))"
    }
}

enum NativeStaticTimelineViewportPolicy {
    static func state(
        distanceToBottom: CGFloat,
        visibleHeight: CGFloat,
        contentHeight: CGFloat,
        hasMessages: Bool,
        userInteracting: Bool = false,
        driverPausedForUser: Bool = false
    ) -> ChatViewportState {
        let isScrollable = contentHeight > visibleHeight + ChatLayout.bottomStickThreshold
        let liveRenderingThreshold = max(
            ChatLayout.liveRenderingLODMinDistance,
            visibleHeight * ChatLayout.liveRenderingLODScreenFactor
        )
        var state = ChatViewportState()
        state.isAtBottom = distanceToBottom <= ChatLayout.bottomStickThreshold
        state.isContentScrollable = isScrollable
        state.liveRenderingFarFromBottom = distanceToBottom > liveRenderingThreshold
        state.showScrollToBottom = hasMessages && isScrollable && !state.isAtBottom
        state.userDragging = userInteracting
        state.followPaused = driverPausedForUser || (userInteracting && !state.isAtBottom)
        return state
    }
}

enum NativeTimelineStreamingTailUpdatePolicy {
    static func shouldUpdate(
        messageID: String,
        isFarFromBottom: Bool,
        visibility: ChatSwiftUIStreamingTailVisibilityState
    ) -> Bool {
        !isFarFromBottom ||
            (visibility.messageID == messageID && visibility.isVisible == true)
    }
}

enum NativeStaticTimelineRendererMemory {
    static func nextStreamedMessageIDs(
        previous: Set<String>,
        event: ChatEvent,
        messages: [UIMessage]
    ) -> Set<String> {
        switch event {
        case .conversationLoaded, .conversationSwitched, .branchChanged:
            return []
        default:
            // Empty renderer memory needs no full-history ID scan. This is the
            // normal cold-history path, including body updates while browsing.
            var retained = previous.isEmpty ? previous : previous.intersection(
                Set(messages.map(ChatMessageProjector.messageId(for:)))
            )
            if event.remembersStreamingRenderer,
               let lastAssistant = messages.last(where: { $0.role == MessageRole.assistant }) {
                retained.insert(ChatMessageProjector.messageId(for: lastAssistant))
            }
            return retained
        }
    }
}

enum NativeTimelineMessageAnchorPolicy {
    static func targetEntryID(
        request: ChatMessageAnchor?,
        consumed: ChatMessageAnchor?,
        currentConversationID: String?,
        availableMessageIDs: Set<String>,
        availableImageToolCallIDsByMessageID: [String: Set<String>] = [:],
        availableToolCallIDsByMessageID: [String: Set<String>]? = nil
    ) -> String? {
        guard let request,
              request != consumed,
              request.conversationID == currentConversationID,
              availableMessageIDs.contains(request.messageID) else {
            return nil
        }
        if let toolCallID = request.toolCallID {
            let isImageTool = availableImageToolCallIDsByMessageID[request.messageID]?.contains(toolCallID) == true
            if isImageTool {
                return ChatImageGenerationAnchorTarget.id(messageID: request.messageID, toolCallID: toolCallID)
            }
            guard let availableToolCallIDsByMessageID,
                  availableToolCallIDsByMessageID[request.messageID]?.contains(toolCallID) == true else {
                return nil
            }
            return ChatToolCallAnchorTarget.id(messageID: request.messageID, toolCallID: toolCallID)
        }
        return ChatTimelinePlanner.messageEntryIDPrefix + request.messageID
    }

    static func canSchedule(
        nativeDriverActive: Bool,
        fallbackActive: Bool
    ) -> Bool {
        nativeDriverActive || fallbackActive
    }
}

private struct ChatUserMessageInsertionModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.88 : 1, anchor: .bottomTrailing)
            .offset(x: active ? 22 : 0, y: active ? 30 : 0)
    }
}

struct ChatSwiftUIStreamingTailVisibilityModifier: ViewModifier {
    let active: Bool
    var assumeVisible: Bool = false
    let onVisibilityChanged: (Bool) -> Void

    func body(content: Content) -> some View {
        content
                .onGeometryChange(for: Bool?.self) { proxy in
                    guard active else { return nil }
                    if assumeVisible { return true }
                    guard let viewportBounds = proxy.bounds(of: .scrollView) else { return nil }
                    return proxy.frame(in: .local).intersects(viewportBounds)
                } action: { isVisible in
                    guard let isVisible else { return }
                    onVisibilityChanged(isVisible)
                }
                .onDisappear {
                    if active { onVisibilityChanged(false) }
                }
    }
}

extension AnyTransition {
    static var chatUserMessageSend: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: ChatUserMessageInsertionModifier(active: true),
                identity: ChatUserMessageInsertionModifier(active: false)
            ),
            removal: .opacity
        )
    }
}
