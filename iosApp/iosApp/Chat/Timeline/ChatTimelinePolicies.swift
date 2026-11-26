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
    case openToolDetail(tool: UIMessagePart.Tool)
    case primaryConfiguration
    case modelDefaults
}

enum NativeChatTimelineSessionIdentity {
    static func viewID(conversationId: KotlinUuid?) -> String {
        guard let conversationId else { return "native-timeline:no-conversation" }
        return "native-timeline:\(String(describing: conversationId))"
    }
}

struct ChatTurnStage {
    let anchorMessageID: String
    var anchorTopY: CGFloat
    // The send revision identifies the push while it owns the bottom animation.
    var pushingRevision: Int?
    static let coordinateSpace = "chat-turn-stage"
    static let pushSettleDelay: Duration = .milliseconds(350)
}

@MainActor
final class ChatTurnStageMetrics {
    // Measuring the natural stack must not invalidate the timeline during streaming.
    var naturalStackHeight: CGFloat = 0
}

enum ChatTurnStagePolicy {
    static let contentTopPadding: CGFloat = 12
    static let contentBottomPadding: CGFloat = 10

    static func floorHeight(anchorTopY: CGFloat, visibleHeight: CGFloat, topClearance: CGFloat) -> CGFloat {
        max(0, anchorTopY + visibleHeight - topClearance - contentTopPadding - contentBottomPadding)
    }

    static func provisionalAnchorTop(naturalStackHeight: CGFloat) -> CGFloat {
        max(0, naturalStackHeight - ChatLayout.bottomRestGap)
    }

    static func shouldActivate(event: ChatEvent, lastUserMessageID: String?, currentAnchorID: String?,
                               wasArmed: Bool, isGenerationActive: Bool, nativeDriverActive: Bool) -> Bool {
        event == .userMessageAppended && nativeDriverActive && !isGenerationActive &&
            wasArmed && lastUserMessageID != nil && lastUserMessageID != currentAnchorID
    }

    static func resets(on event: ChatEvent) -> Bool {
        event == .conversationLoaded || event == .conversationSwitched || event == .branchChanged
    }
}

struct ChatTurnStageFloor: View {
    let anchorTopY: CGFloat?
    let topClearance: CGFloat

    var body: some View {
        Color.clear
            .containerRelativeFrame(.vertical, alignment: .top) { visible, _ in
                guard let anchorTopY else { return 0 }
                return ChatTurnStagePolicy.floorHeight(anchorTopY: anchorTopY,
                                                       visibleHeight: visible, topClearance: topClearance)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
            // Empty renderer memory needs no full-history ID scan. When non-empty,
            // streamed IDs almost always live near the tail, so scanning backward
            // finds all retained IDs in O(|previous|) without bridging every old UUID.
            var retained: Set<String> = []
            if !previous.isEmpty {
                retained.reserveCapacity(previous.count)
                for message in messages.reversed() {
                    let id = ChatMessageProjector.messageId(for: message)
                    if previous.contains(id) {
                        retained.insert(id)
                        if retained.count == previous.count { break }
                    }
                }
            }
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

/// 按「跟随生成」偏好开关 `.sizeChanges` 底锚,与小说创作统一。
/// 行锚定位置(用户上滑浏览历史)不会被它拽走(探针已实证)。
struct ChatSizeChangesPinModifier: ViewModifier {
    let preservesScrollIdentity: Bool
    let enabled: Bool

    func body(content: Content) -> some View {
        if preservesScrollIdentity {
            // Normal viewport changes keep the mounted scroll view. Explicit
            // message navigation retains its existing anchor-resolution path.
            content.defaultScrollAnchor(enabled ? .bottom : nil, for: .sizeChanges)
        } else if enabled {
            content.defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            content
        }
    }
}
