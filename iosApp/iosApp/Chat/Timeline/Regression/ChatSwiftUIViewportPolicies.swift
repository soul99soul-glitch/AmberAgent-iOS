import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine

/// 底部跟随三态机(对齐 Android TimelineFollowMode)。
/// 核心契约(C1):用户主动上滑进入 pausedForUser 后,在用户【主动滑回底部】之前,
/// 任何流式 delta / 几何帧 / 手指抬起都不能恢复跟随 —— 避免"滑动被拽回底部"。
enum FollowMode: Equatable {
    /// 无生成,或内容未超一屏。不主动跟随。
    case idle
    /// 生成中 + 贴底跟随。delta 到来时发跟随 scroll。
    case followingBottom
    /// 用户主动上滑离开底部。【唯一恢复路径】:用户滑回底部(distance ≤ resumeThreshold)。
    case pausedForUser
}

enum ChatSwiftUINearBottomResumePolicy {
    static func shouldResume(
        followPaused: Bool,
        userScrollActive: Bool,
        userScrollJustEnded: Bool,
        distanceToBottom: CGFloat
    ) -> Bool {
        guard followPaused,
              userScrollActive || userScrollJustEnded else { return false }
        return distanceToBottom <= ChatLayout.nearBottomResumeThreshold
    }
}

struct ChatSwiftUIExplicitBottomPlan: Equatable {
    let viewportState: ChatViewportState
    let animated: Bool
}

enum ChatSwiftUIExplicitBottomPolicy {
    static func plan(
        current: ChatViewportState,
        source: NativeTimelineBottomIntentSource,
        distanceToBottom: CGFloat
    ) -> ChatSwiftUIExplicitBottomPlan {
        var next = current
        next.followPaused = false
        next.userDragging = false
        next.showScrollToBottom = false
        return ChatSwiftUIExplicitBottomPlan(
            viewportState: next,
            animated: source == .button && distanceToBottom > ChatLayout.bottomStickThreshold
        )
    }
}

enum ChatSwiftUIExplicitBottomLiveTailPolicy {
    static func shouldRelease(
        forceActive: Bool,
        messageID: String?,
        visibility: ChatSwiftUIStreamingTailVisibilityState,
        distanceToBottom: CGFloat
    ) -> Bool {
        forceActive &&
            messageID != nil &&
            visibility.messageID == messageID &&
            visibility.isVisible == true &&
            distanceToBottom <= ChatLayout.bottomStickThreshold
    }

    static func shouldCancelAtTerminal(forceActive: Bool, hasAssistantTail: Bool) -> Bool {
        forceActive && !hasAssistantTail
    }
}

enum ChatSwiftUIExplicitBottomLayoutPolicy {
    static func shouldReanchor(
        forceActive: Bool,
        explicitBottomAnimationActive: Bool,
        state: ChatViewportState,
        userScrollActive: Bool,
        previousContentHeight: CGFloat,
        currentContentHeight: CGFloat
    ) -> Bool {
        guard forceActive,
              !explicitBottomAnimationActive,
              !state.followPaused,
              !state.userDragging,
              !userScrollActive,
              state.isContentScrollable else { return false }
        return abs(currentContentHeight - previousContentHeight) > 0.5
    }
}

enum ChatSwiftUIConversationAnchorRetryDecision: Equatable {
    case abort
    case wait
    case attempt
}

enum ChatSwiftUIConversationAnchorRetryPolicy {
    static func decision(
        taskCancelled: Bool,
        tokenMatches: Bool,
        canRunNow: Bool,
        isAlreadyAnchored: Bool = false
    ) -> ChatSwiftUIConversationAnchorRetryDecision {
        guard !taskCancelled, tokenMatches else { return .abort }
        guard !isAlreadyAnchored else { return .abort }
        return canRunNow ? .attempt : .wait
    }
}

enum ChatSwiftUIMeasuredGrowthFollowPolicy {
    static func shouldTrackGrowth(
        generationActive: Bool,
        endSettleActive: Bool,
        explicitBottomCatchUpActive: Bool,
        followEnabled: Bool,
        followMode: FollowMode,
        state: ChatViewportState,
        userScrollActive: Bool,
        previousContentHeight: CGFloat,
        currentContentHeight: CGFloat
    ) -> Bool {
        guard generationActive || endSettleActive || explicitBottomCatchUpActive,
              followEnabled,
              followMode == .followingBottom,
              !state.followPaused,
              !state.userDragging,
              !userScrollActive else { return false }
        return currentContentHeight - previousContentHeight > 0.5
    }

    static func shouldFollow(
        generationActive: Bool,
        endSettleActive: Bool,
        explicitBottomCatchUpActive: Bool,
        explicitBottomAnimationActive: Bool,
        followEnabled: Bool,
        followMode: FollowMode,
        state: ChatViewportState,
        userScrollActive: Bool,
        previousContentHeight: CGFloat,
        currentContentHeight: CGFloat,
        distanceToBottom: CGFloat
    ) -> Bool {
        guard !explicitBottomAnimationActive,
              shouldTrackGrowth(
            generationActive: generationActive,
            endSettleActive: endSettleActive,
            explicitBottomCatchUpActive: explicitBottomCatchUpActive,
            followEnabled: followEnabled,
            followMode: followMode,
            state: state,
            userScrollActive: userScrollActive,
            previousContentHeight: previousContentHeight,
            currentContentHeight: currentContentHeight
        ), state.isContentScrollable else { return false }
        return distanceToBottom > 1
    }
}

enum ChatSwiftUIBottomWritePolicy {
    static func canIssueImmediateWrite(explicitBottomAnimationActive: Bool) -> Bool {
        !explicitBottomAnimationActive
    }
}

enum ChatSwiftUIGenerationEndSettlePolicy {
    static let frameDurationNanoseconds: UInt64 = 16_666_667
    // 最长 live Markdown 节流为 0.32s；0.4s 静默窗口覆盖解析和随后一轮布局。
    static let quietFrames = 24
    static let maxFrames = 60

    static var quietDuration: TimeInterval {
        Double(quietFrames) / 60
    }

    static func shouldFinish(
        elapsedFrames: Int,
        quietElapsed: TimeInterval,
        explicitBottomAnimationActive: Bool
    ) -> Bool {
        if elapsedFrames >= maxFrames {
            return true
        }
        return !explicitBottomAnimationActive && quietElapsed >= quietDuration
    }
}

enum ChatSwiftUICleanListRenderPolicy {
    static func liveTailState(for row: ChatMessageRowModel) -> ChatRenderState? {
        guard row.isLast,
              row.role == MessageRole.assistant,
              row.isStreaming || row.hasEverStreamed else { return nil }
        return ChatRenderState(
            rendererMode: .streamingMarkdown,
            hasEverStreamed: true,
            liveRenderingEnabled: true,
            frozenMarkdownSnapshot: nil
        )
    }

    static func nonLiveTailState(for row: ChatMessageRowModel) -> ChatRenderState? {
        guard !row.isLast || row.role != MessageRole.assistant else { return nil }
        if row.hasEverStreamed {
            return ChatRenderState(
                rendererMode: .streamingMarkdown,
                hasEverStreamed: true,
                liveRenderingEnabled: true,
                frozenMarkdownSnapshot: nil
            )
        }
        return ChatRenderState(
            rendererMode: .staticMarkdown,
            hasEverStreamed: false,
            liveRenderingEnabled: true,
            frozenMarkdownSnapshot: nil
        )
    }
}

struct ChatSwiftUIScrollGeometry: Equatable {
    var distanceToBottom: CGFloat = 0
    var visibleHeight: CGFloat = 1
    var contentHeight: CGFloat = 0
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
}

