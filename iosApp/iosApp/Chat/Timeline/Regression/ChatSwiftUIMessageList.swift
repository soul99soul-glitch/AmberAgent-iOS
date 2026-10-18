import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine


/// `ChatSwiftUIMessageList` 的滚动/跟随运行时状态盒。
/// 字段只在事件回调(scroll phase / geometry / signal / task)中读写,渲染 body
/// 不读取任何字段——所以对盒内字段的写入不触发 SwiftUI 失效,滚动帧与流式
/// delta 不会互相放大 body 重求值成本。新增字段前必须确认 body 不依赖它。
@MainActor
private final class ChatSwiftUIListScrollRuntime {
    var lastScrollToBottomTrigger = 0
    var followMode: FollowMode = .idle
    /// onScrollPhaseChange:区分「用户拖拽/惯性」与「程序滚动」。
    var userScrollActive = false
    var followDebugTick = 0
    /// onScrollGeometryChange 提供的真实距底距离。
    var scrollVisibleRectMaxY: CGFloat?
    var latestScrollGeometry = ChatSwiftUIScrollGeometry(
        distanceToBottom: 0,
        visibleHeight: 1,
        contentHeight: 0
    )
    var hasMeasuredScrollGeometry = false
    var streamFollowTask: Task<Void, Never>?
    var measuredGrowthFollowTask: Task<Void, Never>?
    var measuredGrowthRevision: UInt = 0
    var lastUserScrollActivityAt = Date.distantPast
    var conversationScrollTask: Task<Void, Never>?
    var conversationScrollToken = 0
    var explicitBottomAnimationActive = false
    var explicitBottomAnimationToken = 0
    var explicitBottomSettleTask: Task<Void, Never>?
    var explicitBottomSettleLastLayoutChangeAt = Date.distantPast
    var explicitBottomTrace: ChatPerfTrace.Interval?
    var generationEndSettleTask: Task<Void, Never>?
    var generationEndSettleTrace: ChatPerfTrace.Interval?
    var generationEndSettleToken = 0
    var generationEndSettleLastGrowthAt = Date.distantPast
}

/// 每次 body 求值计算一次的行级设置签名(所有行共享,避免逐行反射)。
struct ChatRowSettingSignatures {
    let display: String
    let generative: String
}

/// Android-style clean chat timeline:
/// - one stable SwiftUI row per message during streaming;
/// - natural SwiftUI measurement, no ChatLayout estimated height/cache;
/// - no liveTail overlay, frozen markdown snapshot, or UIKit invalidation bridge.
struct ChatSwiftUIMessageList: View {
    var signal: ChatMessageUpdateSignal
    var configurationIssue: ChatConfigurationIssue?
    var isGenerationActive: Bool
    var isLoading: Bool
    var isRecognizingImages: Bool
    var contextCompactState: ChatContextCompactState
    var followGeneration: Bool
    var displaySetting: DisplaySetting
    var generativeUiSetting: GenerativeUiSetting
    var reasoningLevelLabel: String?
    var workspaceStore: IOSWorkspaceStore
    var scrollToBottomTrigger: Int
    var scrollToBottomSource: NativeTimelineBottomIntentSource
    var messagesProvider: () -> [UIMessage]
    var variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo?
    var onAction: (ChatListAction) -> Void
    var onViewportStateChange: (ChatViewportState) -> Void
    var onDismissKeyboard: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewportState = ChatViewportState()
    @State private var streamedMessageIDs: Set<String> = []
    @State private var swiftUIRenderStateStore = ChatRenderStateStore()
    @State private var swiftUIContentHashCache = ChatRowContentHashCache()
    @State private var streamingTailVisibility = ChatSwiftUIStreamingTailVisibilityState()
    @State private var explicitBottomForcesLiveTail = false
    /// iOS 18 ScrollPosition:替代 ScrollViewProxy,支持 scrollTo(edge:) + isPositionedByUser。
    @State private var scrollPosition = ScrollPosition()
    /// 滚动/跟随运行时状态。只被事件回调读写,渲染 body 不依赖其中任何字段,
    /// 因此放在引用盒子里而不是逐个 @State:滚动几何每帧更新、一次性 follow
    /// 任务和 settle token 递增都不应该把整个列表 body(timeline plan 重建
    /// + 可见行 digest)拖着一起重求值。这是流式期滑动历史掉帧的直接根因之一。
    @State private var runtime = ChatSwiftUIListScrollRuntime()

    var body: some View {
        let messages = messagesProvider()
        let timelinePlan = makeTimelinePlan(messages: messages)
        // 设置签名对所有行相同:每次 body 求值只反射一次,不随可见行数放大
        // (String(describing:) 走 Mirror,单次 ~25µs,逐行×2 会进热路径)。
        let rowSignatures = ChatRowSettingSignatures(
            display: String(describing: displaySetting),
            generative: String(describing: generativeUiSetting)
        )
        let renderedEntries = timelinePlan.entries.dropLast()
        let historicalEntries = renderedEntries.dropLast()
        let tailEntry = renderedEntries.last

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if messages.isEmpty {
                    emptyTimelineContent
                } else {
                    // Keep stable history lazy, but measure the only dynamically growing
                    // tail outside LazyVStack so its line-height changes stay exact.
                    if !historicalEntries.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(historicalEntries, id: \.id) { entry in
                                timelineEntryView(entry, signatures: rowSignatures)
                            }
                        }
                    }

                    if let tailEntry {
                        timelineEntryView(tailEntry, signatures: rowSignatures)
                    }

                    if isRecognizingImages {
                        VisionRecognitionIndicator()
                    }

                    if contextCompactState.isVisible {
                        ContextCompactTimelineMarker(state: contextCompactState)
                    }
                }

                bottomAnchor
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        // iOS 18 scrollPosition + defaultScrollAnchor。动态消息行不登记为 scroll
        // targets；底部跟随只写物理 edge，避免动态行高度变化时重复解析目标。
        // initialOffset 负责长会话初始入场;alignment 负责内容不足一屏时自然顶排。
        // 流式增长由下方真实 geometry 回调唯一驱动。`.sizeChanges` 在长 UIKit
        // 文本段落的增量布局路径不会维持底锚，却会让回调误判已有别的写者。
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                onDismissKeyboard()
            }
        )
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting:
                onDismissKeyboard()
                cancelExplicitBottomAnimation()
                cancelPendingStreamFollow()
                cancelGenerationEndSettle()
                runtime.userScrollActive = true
                runtime.lastUserScrollActivityAt = Date()
                cancelPendingConversationScroll()
            case .decelerating:
                // Deceleration can also be produced by programmatic anchoring or system
                // layout compensation. Only continue a session that began with a real
                // user gesture; never let deceleration itself initiate pause.
                if runtime.userScrollActive {
                    runtime.lastUserScrollActivityAt = Date()
                }
            case .idle:
                let endedUserScroll = runtime.userScrollActive
                let endedExplicitBottomAnimation = runtime.explicitBottomAnimationActive
                if endedUserScroll {
                    runtime.lastUserScrollActivityAt = Date()
                }
                runtime.userScrollActive = false
                if endedUserScroll {
                    resumeFollowAfterUserScrollEndedIfNeeded()
                }
                if endedExplicitBottomAnimation {
                    completeExplicitBottomAnimationIfNeeded()
                }
            case .animating:
                // Programmatic ScrollPosition writes can report `.animating`; do not let
                // that phase masquerade as a fresh user gesture. If it follows a real user
                // session, close that session once and let the bottom-distance check decide.
                let endedUserScroll = runtime.userScrollActive
                if endedUserScroll {
                    runtime.lastUserScrollActivityAt = Date()
                    runtime.userScrollActive = false
                    resumeFollowAfterUserScrollEndedIfNeeded()
                }
            @unknown default:
                break
            }
        }
        .onScrollGeometryChange(for: ChatSwiftUIScrollGeometry.self) { geo in
            ChatSwiftUIScrollGeometry(
                distanceToBottom: max(0, geo.contentSize.height - geo.visibleRect.maxY),
                visibleHeight: max(1, geo.visibleRect.height),
                contentHeight: geo.contentSize.height
            )
        } action: { previousGeometry, geometry in
            runtime.hasMeasuredScrollGeometry = true
            runtime.latestScrollGeometry = geometry
            let distanceToBottom = geometry.distanceToBottom
            runtime.scrollVisibleRectMaxY = distanceToBottom
            if runtime.userScrollActive {
                runtime.lastUserScrollActivityAt = Date()
            }
            let messages = messagesProvider()
            let visibleHeight = geometry.visibleHeight
            let liveRenderingThreshold = max(
                ChatLayout.liveRenderingLODMinDistance,
                visibleHeight * ChatLayout.liveRenderingLODScreenFactor
            )
            let previousFollowMode = runtime.followMode
            var next = viewportState
            next.userDragging = runtime.userScrollActive
            let commands = ChatViewportReducer.reduceGeometry(
                ChatViewportGeometrySnapshot(
                    atBottom: distanceToBottom <= ChatLayout.bottomStickThreshold,
                    isContentScrollable: geometry.contentHeight > visibleHeight + ChatLayout.bottomStickThreshold,
                    liveRenderingFarFromBottom: distanceToBottom > liveRenderingThreshold,
                    userScrollActive: runtime.userScrollActive
                ),
                hasMessages: !messages.isEmpty,
                state: &next,
                environment: ChatViewportEnvironment(
                    followEnabled: followGeneration,
                    generationActive: isGenerationActive || isLoading
                )
            )
            if ChatSwiftUINearBottomResumePolicy.shouldResume(
                followPaused: next.followPaused,
                userScrollActive: runtime.userScrollActive,
                userScrollJustEnded: false,
                distanceToBottom: distanceToBottom
            ) {
                // 96pt 只表达「真实用户已回到底部附近」的恢复意图；物理
                // true-bottom 仍由 40pt geometry 判定，不能在这里伪造 isAtBottom。
                next.followPaused = false
                next.showScrollToBottom = false
                next.liveRenderingFarFromBottom = false
            }
            syncFollowMode(from: next)
            let reachedExplicitBottom = runtime.explicitBottomAnimationActive && next.isAtBottom
            if previousFollowMode != runtime.followMode {
                debugFollow(runtime.followMode == .pausedForUser ? "pause" : "resume", messages: messages)
            }
            let shouldFollowMeasuredGrowth = shouldFollowMeasuredContentGrowth(
                previous: previousGeometry,
                current: geometry,
                state: next
            )
            let didObserveMeasuredGrowth = shouldTrackMeasuredContentGrowth(
                previous: previousGeometry,
                current: geometry,
                state: next
            )
            let shouldReanchorExplicitBottomLayout = ChatSwiftUIExplicitBottomLayoutPolicy.shouldReanchor(
                forceActive: explicitBottomForcesLiveTail,
                explicitBottomAnimationActive: runtime.explicitBottomAnimationActive,
                state: next,
                userScrollActive: runtime.userScrollActive,
                previousContentHeight: previousGeometry.contentHeight,
                currentContentHeight: geometry.contentHeight
            )
            if shouldReanchorExplicitBottomLayout,
               runtime.explicitBottomSettleTask != nil {
                runtime.explicitBottomSettleLastLayoutChangeAt = Date()
            }
            let shouldReanchorViewportShrink = shouldReanchorAfterViewportShrink(
                previous: previousGeometry,
                current: geometry,
                state: next
            )
            publish(next)
            releaseExplicitBottomLiveTailIfSettled()
            if reachedExplicitBottom {
                completeExplicitBottomAnimationIfNeeded()
            }
            let didIssueFollow = executeViewportCommands(
                commands,
                state: next,
                event: signal.event,
                // Measured growth is the sole live-height writer.
                animateMeasuredGrowth: shouldFollowMeasuredGrowth
                    && !shouldReanchorExplicitBottomLayout
            )
            if didObserveMeasuredGrowth, runtime.generationEndSettleTask != nil {
                runtime.generationEndSettleLastGrowthAt = Date()
            }
            if shouldReanchorExplicitBottomLayout {
                if !didIssueFollow {
                    scrollToBottomIfScrollable()
                }
            } else if shouldFollowMeasuredGrowth {
                if !didIssueFollow {
                    followMeasuredStreamGrowthToBottom()
                }
            } else if shouldReanchorViewportShrink,
                      !didIssueFollow,
                      ChatSwiftUIBottomWritePolicy.canIssueImmediateWrite(
                        explicitBottomAnimationActive: runtime.explicitBottomAnimationActive
                      ) {
                if reduceMotion {
                    scrollToBottomAnchor()
                } else {
                    withAnimation(.easeOut(duration: 0.22)) {
                        scrollToBottomAnchor(disableAnimations: false)
                    }
                }
            }
        }
        .onAppear {
            debugFollow("appear", messages: messages)
            handleSignal(signal, messages: messages)
            consumeExternalScrollToBottomTriggerIfNeeded()
        }
        .onDisappear {
            cancelExplicitBottomAnimation()
            cancelPendingStreamFollow()
            cancelPendingConversationScroll()
            cancelGenerationEndSettle()
        }
        .onChange(of: signal) { _, newSignal in
            handleSignal(newSignal, messages: messagesProvider())
        }
        .onChange(of: scrollToBottomTrigger) { _, trigger in
            consumeExternalScrollToBottomTriggerIfNeeded(trigger)
        }
        .transaction(value: signal) { transaction in
            if signal.event == .assistantStreamDelta {
                transaction.animation = nil
            }
        }
    }

    @ViewBuilder
    private var emptyTimelineContent: some View {
        ChatEmptyState()
    }

    private var bottomAnchor: some View {
        Color.clear
            .frame(height: ChatLayout.bottomRestGap)
            .id(ChatLayout.bottomAnchorID)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func makeTimelinePlan(messages: [UIMessage]) -> ChatTimelinePlan {
        ChatPerfTrace.measure("TimelineProjection", count: { messages.count }) {
            ChatTimelinePlanner.build(
                messages: messages,
                event: signal.event,
                streamedMessageIDs: streamedMessageIDs,
                includePendingAssistant: (isGenerationActive || isLoading) && messages.last(where: ChatMessageProjector.isConversationMessage)?.role == MessageRole.user,
                // SwiftUI 列表路径不消费 renderToken,跳过逐行 token 计算。
                includeRenderTokens: false
            )
        }
    }

    @ViewBuilder
    private func timelineEntryView(
        _ entry: ChatTimelineEntry,
        signatures: ChatRowSettingSignatures
    ) -> some View {
        switch entry {
        case let .message(messageEntry):
            messageRow(messageEntry, signatures: signatures)
        case .pendingAssistant:
            ChatAssistantPendingResponseView()
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bottomAnchor:
            EmptyView()
        }
    }

    private func messageRow(
        _ entry: ChatTimelineMessageEntry,
        signatures: ChatRowSettingSignatures
    ) -> some View {
        let row = entry.rowModel
        let renderState = swiftUIRenderState(for: entry)
        let variantInfo = variantInfoProvider(row.index)
        let updatesSuspended = !explicitBottomForcesLiveTail && ChatSwiftUIStreamingTailRenderPolicy.shouldSuspend(
            isLastAssistant: row.isLast && row.role == MessageRole.assistant,
            hasEverStreamed: row.hasEverStreamed,
            messageID: row.messageId,
            visibility: streamingTailVisibility
        )
        let contentHash: Int
        if updatesSuspended {
            contentHash = swiftUIContentHashCache.suspendedStreamingTailLayoutToken(for: row)
        } else if row.isStreaming {
            contentHash = swiftUIContentHashCache.streamingTailLayoutToken(for: row)
        } else {
            contentHash = swiftUIContentHashCache.contentHash(for: row)
        }
        let digest = ChatRowDigests.digest(
            row: row,
            renderState: renderState,
            contentHash: contentHash,
            isGenerationActive: isGenerationActive,
            displaySettingSignature: signatures.display,
            generativeUiSettingSignature: signatures.generative,
            hasMultipleVariants: variantInfo?.hasMultipleVariants == true,
            reasoningLevelLabel: reasoningLevelLabel
        )
        let bubble = ChatSwiftUIMessageBubble(
            entryID: entry.id,
            renderDigest: digest,
            updatesSuspended: updatesSuspended,
            row: row,
            variantInfo: variantInfo,
            renderState: renderState,
            isGenerationActive: isGenerationActive,
            displaySetting: displaySetting,
            generativeUiSetting: generativeUiSetting,
            reasoningLevelLabel: reasoningLevelLabel,
            onAction: onAction
        )
        .equatable()
        .environment(workspaceStore)
        .fixedSize(horizontal: false, vertical: true)
        .frame(
            maxWidth: .infinity,
            alignment: row.role == MessageRole.user ? .topTrailing : .topLeading
        )
        .padding(.vertical, row.role == MessageRole.user ? ChatLayout.userMessageRowVerticalPadding : 0)
        .id(entry.id)
        .transition(userMessageInsertionTransition(for: row))
        .zIndex(row.canAnimateInsertion ? 1 : 0)

        return bubble.modifier(
            ChatSwiftUIStreamingTailVisibilityModifier(
                active: row.isLast && row.role == MessageRole.assistant,
                onVisibilityChanged: { isVisible in
                    updateStreamingTailVisibility(messageID: row.messageId, isVisible: isVisible)
                }
            )
        )
    }

    private func userMessageInsertionTransition(for row: ChatMessageRowModel) -> AnyTransition {
        if ChatMessageProjector.isSubAgentResult(row.message) {
            return reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8))
        }
        guard !reduceMotion,
              row.canAnimateInsertion,
              row.role == MessageRole.user else { return .identity }
        return .chatUserMessageSend
    }

    private func consumeExternalScrollToBottomTriggerIfNeeded(_ trigger: Int? = nil) {
        let currentTrigger = trigger ?? scrollToBottomTrigger
        guard currentTrigger != runtime.lastScrollToBottomTrigger else { return }
        runtime.lastScrollToBottomTrigger = currentTrigger
        cancelPendingConversationScroll()
        cancelPendingStreamFollow()
        cancelGenerationEndSettle()
        runtime.followMode = .followingBottom
        let plan = ChatSwiftUIExplicitBottomPolicy.plan(
            current: viewportState,
            source: scrollToBottomSource,
            distanceToBottom: currentBottomDistance
        )
        publish(plan.viewportState)
        syncFollowMode(from: plan.viewportState)
        if plan.animated {
            beginExplicitBottomTrace()
            explicitBottomForcesLiveTail = true
            beginExplicitBottomAnimation()
        } else {
            cancelExplicitBottomAnimation()
            beginExplicitBottomTrace()
            explicitBottomForcesLiveTail = true
            scrollToBottomAnchor()
        }
    }

    private func handleSignal(
        _ signal: ChatMessageUpdateSignal,
        messages: [UIMessage]
    ) {
        updateStreamedMessageIDs(event: signal.event, messages: messages)

        switch signal.event {
        case .conversationLoaded, .conversationSwitched:
            // 归位:重置跟随态 + 延迟滚到底(等消息布局实例化)。
            cancelPendingStreamFollow()
            cancelExplicitBottomAnimation()
            resetLatestGeometryForContentReplacement()
            cancelGenerationEndSettle()
            runtime.userScrollActive = false
            runtime.followMode = followGeneration ? .followingBottom : .idle
            publish(ChatViewportState())
            scheduleConversationBottomAnchor()
        case .branchChanged:
            // 编辑重发:先保持当前阅读锚,不要把截断后的用户消息强拉到底部;
            // 后续 assistant 内容真实增长时,由底部锚点跟随。
            cancelPendingConversationScroll()
            cancelGenerationEndSettle()
            runtime.followMode = followGeneration ? .followingBottom : .idle
            var next = viewportState
            next.followPaused = false
            next.userDragging = false
            next.isAtBottom = true
            next.isContentScrollable = false
            next.liveRenderingFarFromBottom = false
            next.showScrollToBottom = false
            resetLatestGeometryForContentReplacement()
            publish(next)
        case .userMessageAppended:
            // 用户刚发消息:意图明确是看回复,进入贴底跟随并锚到底部。
            // 第一屏内不滚动;超过一屏后由 stream follow 维持底部基线。
            cancelPendingConversationScroll()
            cancelGenerationEndSettle()
            runtime.followMode = followGeneration ? .followingBottom : .idle
            var next = viewportState
            next.followPaused = false
            next.userDragging = false
            next.showScrollToBottom = false
            publish(next)
            scrollToBottomIfScrollable()
        case .assistantStreamDelta:
            cancelGenerationEndSettle()
            runtime.followDebugTick &+= 1
            // delta 到来:若 idle 则转 following。pausedForUser 时【绝不】自动恢复(C1 契约)。
            if !followGeneration {
                runtime.followMode = .idle
            } else if runtime.followMode == .idle, isGenerationActive || isLoading {
                runtime.followMode = .followingBottom
            }
            if runtime.followDebugTick % 20 == 0 {
                debugFollow("delta", messages: messages)
            }
        case .generationCompleted, .generationFailed, .generationCancelled,
             .generationHandedOffToBackground:
            if ChatSwiftUIExplicitBottomLiveTailPolicy.shouldCancelAtTerminal(
                forceActive: explicitBottomForcesLiveTail,
                hasAssistantTail: messages.last(where: ChatMessageProjector.isConversationMessage)?.role == MessageRole.assistant
            ) {
                cancelExplicitBottomAnimation()
            }
            // 最终 Markdown 解析/思考块收起会晚于 terminal signal 落地。保留一个
            // 有界收敛窗口，期间只响应真实 contentHeight 增长，结束后再回 idle。
            if followGeneration, runtime.followMode == .followingBottom {
                scheduleGenerationEndSettle()
            } else {
                cancelGenerationEndSettle()
                runtime.followMode = .idle
            }
        case .assistantStreamClosed, .toolCallStarted, .toolResultAppended,
             .awaitingToolApproval:
            // 流式中途事件(工具调用等):跟随当前态。
            if followGeneration, runtime.followMode == .followingBottom {
                scheduleStreamBottomFollow()
            }
        case .settingsRefreshed:
            break
        }
    }

    private func scheduleConversationBottomAnchor() {
        cancelPendingConversationScroll()
        runtime.conversationScrollToken &+= 1
        let token = runtime.conversationScrollToken
        runtime.conversationScrollTask = Task { @MainActor in
            let delays: [UInt64] = [
                50_000_000,
                100_000_000,
                200_000_000,
                350_000_000
            ]
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                switch ChatSwiftUIConversationAnchorRetryPolicy.decision(
                    taskCancelled: Task.isCancelled,
                    tokenMatches: token == runtime.conversationScrollToken,
                    canRunNow: canRunConversationBottomAnchorRetry,
                    isAlreadyAnchored: runtime.hasMeasuredScrollGeometry && viewportState.isAtBottom
                ) {
                case .abort:
                    return
                case .wait:
                    continue
                case .attempt:
                    // Entry anchoring is also what bootstraps geometry. Do not require
                    // a prior scrollability sample before issuing the semantic edge write.
                    scrollToBottomAnchor()
                }
            }
            if token == runtime.conversationScrollToken {
                runtime.conversationScrollTask = nil
            }
        }
    }

    private func cancelPendingConversationScroll() {
        runtime.conversationScrollToken &+= 1
        runtime.conversationScrollTask?.cancel()
        runtime.conversationScrollTask = nil
    }

    private func beginExplicitBottomTrace() {
        if runtime.explicitBottomTrace != nil {
            ChatPerfTrace.event("BottomResumeCancelled")
            ChatPerfTrace.end(&runtime.explicitBottomTrace)
        }
        runtime.explicitBottomTrace = ChatPerfTrace.begin("BottomResume")
    }

    private func beginExplicitBottomAnimation() {
        cancelExplicitBottomSettle()
        runtime.explicitBottomAnimationToken &+= 1
        let token = runtime.explicitBottomAnimationToken
        runtime.explicitBottomAnimationActive = true
        guard !reduceMotion else {
            scrollToBottomAnchor()
            completeExplicitBottomAnimationIfNeeded()
            return
        }
        withAnimation(.easeOut(duration: 0.2), completionCriteria: .logicallyComplete) {
            scrollToBottomAnchor(disableAnimations: false)
        } completion: {
            guard token == runtime.explicitBottomAnimationToken else { return }
            completeExplicitBottomAnimationIfNeeded()
        }
    }

    private func completeExplicitBottomAnimationIfNeeded() {
        guard runtime.explicitBottomAnimationActive else { return }
        runtime.explicitBottomAnimationActive = false
        runtime.explicitBottomAnimationToken &+= 1
        if runtime.explicitBottomSettleTask != nil {
            runtime.explicitBottomSettleLastLayoutChangeAt = Date()
        }
        guard followGeneration else {
            runtime.followMode = .idle
            return
        }
        guard !runtime.userScrollActive, !viewportState.followPaused else { return }
        runtime.followMode = .followingBottom
        if isGenerationActive || isLoading {
            scheduleStreamBottomFollow()
        } else if explicitBottomForcesLiveTail {
            // The live tail may have published its real height while the explicit
            // animation owned scrolling. Re-issue the same semantic anchor once;
            // later height changes are handled by explicit-bottom settle ownership.
            scrollToBottomIfScrollable()
        } else {
            runtime.followMode = .idle
        }
    }

    private func cancelExplicitBottomAnimation() {
        cancelExplicitBottomSettle()
        explicitBottomForcesLiveTail = false
        if runtime.explicitBottomTrace != nil {
            ChatPerfTrace.event("BottomResumeCancelled")
            ChatPerfTrace.end(&runtime.explicitBottomTrace)
        }
        if runtime.explicitBottomAnimationActive {
            runtime.explicitBottomAnimationActive = false
            runtime.explicitBottomAnimationToken &+= 1
        }
    }

    private func updateStreamingTailVisibility(messageID: String, isVisible: Bool) {
        if isVisible {
            let next = ChatSwiftUIStreamingTailVisibilityState(messageID: messageID, isVisible: true)
            if next != streamingTailVisibility {
                streamingTailVisibility = next
            }
            releaseExplicitBottomLiveTailIfSettled()
        } else if streamingTailVisibility.messageID == messageID {
            guard streamingTailVisibility.isVisible != false else { return }
            streamingTailVisibility.isVisible = false
        }
    }

    private func releaseExplicitBottomLiveTailIfSettled() {
        guard explicitBottomForcesLiveTail else { return }
        let tailMessageID: String?
        if let last = messagesProvider().last, last.role == MessageRole.assistant {
            tailMessageID = ChatMessageProjector.messageId(for: last)
        } else {
            tailMessageID = nil
        }
        guard ChatSwiftUIExplicitBottomLiveTailPolicy.shouldRelease(
            forceActive: explicitBottomForcesLiveTail,
            messageID: tailMessageID,
            visibility: streamingTailVisibility,
            distanceToBottom: currentBottomDistance
        ) else { return }
        scheduleExplicitBottomSettle()
    }

    private func scheduleExplicitBottomSettle() {
        guard runtime.explicitBottomSettleTask == nil else { return }
        ChatPerfTrace.event("BottomTailVisible")
        runtime.explicitBottomSettleLastLayoutChangeAt = Date()
        runtime.explicitBottomSettleTask = Task { @MainActor in
            for elapsedFrames in 1...ChatSwiftUIGenerationEndSettlePolicy.maxFrames {
                do {
                    try await Task.sleep(
                        nanoseconds: ChatSwiftUIGenerationEndSettlePolicy.frameDurationNanoseconds
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled, explicitBottomForcesLiveTail else { return }
                let quietElapsed = Date().timeIntervalSince(
                    runtime.explicitBottomSettleLastLayoutChangeAt
                )
                guard ChatSwiftUIGenerationEndSettlePolicy.shouldFinish(
                    elapsedFrames: elapsedFrames,
                    quietElapsed: quietElapsed,
                    explicitBottomAnimationActive: runtime.explicitBottomAnimationActive
                ) else { continue }
                scrollToBottomIfScrollable()
                explicitBottomForcesLiveTail = false
                runtime.explicitBottomSettleTask = nil
                ChatPerfTrace.event("BottomResumeSettled")
                ChatPerfTrace.end(&runtime.explicitBottomTrace)
                if !(isGenerationActive || isLoading), runtime.generationEndSettleTask == nil {
                    runtime.followMode = .idle
                }
                return
            }
        }
    }

    private func cancelExplicitBottomSettle() {
        runtime.explicitBottomSettleTask?.cancel()
        runtime.explicitBottomSettleTask = nil
    }

    private var canRunConversationBottomAnchorRetry: Bool {
        ChatViewportPolicy.canRunConversationBottomAnchorRetry(
            userScrollActive: runtime.userScrollActive,
            followPaused: viewportState.followPaused
        )
    }

    private func scheduleStreamBottomFollow() {
        guard runtime.streamFollowTask == nil else { return }
        runtime.streamFollowTask = Task { @MainActor in
            defer {
                runtime.streamFollowTask = nil
            }
            do {
                // Let the current layout transaction settle before the one-shot semantic
                // catch-up, while keeping the single proven bottom-anchor positioning shape.
                try await Task.sleep(nanoseconds: 24_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  followGeneration,
                  runtime.followMode == .followingBottom,
                  !runtime.userScrollActive,
                  !runtime.explicitBottomAnimationActive,
                  runtime.generationEndSettleTask == nil,
                  streamFollowContentCanScroll else { return }
            scrollToBottomAnchor()
        }
    }

    private func cancelPendingStreamFollow() {
        runtime.streamFollowTask?.cancel()
        runtime.streamFollowTask = nil
        runtime.measuredGrowthFollowTask?.cancel()
        runtime.measuredGrowthFollowTask = nil
    }

    private func scrollToBottomIfScrollable(disableAnimations: Bool = true) {
        guard ChatSwiftUIBottomWritePolicy.canIssueImmediateWrite(
            explicitBottomAnimationActive: runtime.explicitBottomAnimationActive
        ), currentContentScrollable else { return }
        scrollToBottomAnchor(disableAnimations: disableAnimations)
    }

    private func followMeasuredStreamGrowthToBottom() {
        guard followGeneration,
              runtime.followMode == .followingBottom,
              !viewportState.followPaused,
              !viewportState.userDragging,
              !runtime.userScrollActive,
              !runtime.explicitBottomAnimationActive,
              currentContentScrollable else { return }
        runtime.measuredGrowthRevision &+= 1
        guard runtime.measuredGrowthFollowTask == nil else { return }

        let leadingRevision = runtime.measuredGrowthRevision
        // Follow the first real geometry change immediately. TextKit can publish more
        // changes in the same layout pass; one task drains only those newer revisions.
        runtime.measuredGrowthFollowTask = Task { @MainActor in
            defer { runtime.measuredGrowthFollowTask = nil }
            var drainedRevision = leadingRevision
            while !Task.isCancelled {
                await Task.yield()
                guard !Task.isCancelled,
                      followGeneration,
                      runtime.followMode == .followingBottom,
                      !viewportState.followPaused,
                      !viewportState.userDragging,
                      !runtime.userScrollActive,
                      !runtime.explicitBottomAnimationActive,
                      currentContentScrollable else { return }
                guard runtime.measuredGrowthRevision != drainedRevision else { return }
                drainedRevision = runtime.measuredGrowthRevision
                scrollToBottomAnchor()
            }
        }
        scrollToBottomAnchor()
    }

    private func scrollToBottomAnchor(disableAnimations: Bool = true) {
        guard disableAnimations else {
            scrollPosition.scrollTo(edge: .bottom)
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        transaction.animation = nil
        withTransaction(transaction) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private func liveMarkdownRenderingEnabled(for row: ChatMessageRowModel) -> Bool {
        guard row.isLast, row.role == MessageRole.assistant else { return true }
        return !viewportState.liveRenderingFarFromBottom
    }

    private func swiftUIRenderState(for entry: ChatTimelineMessageEntry) -> ChatRenderState {
        let row = entry.rowModel
        if let state = ChatSwiftUICleanListRenderPolicy.liveTailState(for: row) {
            return state
        }
        if let state = ChatSwiftUICleanListRenderPolicy.nonLiveTailState(for: row) {
            return state
        }
        return swiftUIRenderStateStore.stateForEntry(
            entry,
            isLiveRenderingFarFromBottom: viewportState.liveRenderingFarFromBottom
        )
    }

    private func updateStreamedMessageIDs(event: ChatEvent, messages: [UIMessage]) {
        // delta 热路径:chunk 不增删消息,只需登记尾行 id。全量 id 重建/求交是
        // O(消息数) 的 KMP 桥接,且无条件重写 @State 会让每个 chunk 都额外触发
        // 一轮 body 重求值(即使集合没变)。结构性事件才走完整清理分支。
        if event == .assistantStreamDelta {
            if event.remembersStreamingRenderer,
               let last = messages.last(where: ChatMessageProjector.isConversationMessage),
               last.role == MessageRole.assistant {
                let lastID = ChatMessageProjector.messageId(for: last)
                if !streamedMessageIDs.contains(lastID) {
                    streamedMessageIDs.insert(lastID)
                }
            }
            return
        }
        let currentIDs = Set(messages.map(ChatMessageProjector.messageId(for:)))
        switch event {
        case .conversationLoaded, .conversationSwitched, .branchChanged:
            streamedMessageIDs.removeAll()
            swiftUIRenderStateStore.removeAll()
            swiftUIContentHashCache.removeAll()
            streamingTailVisibility = ChatSwiftUIStreamingTailVisibilityState()
        default:
            if event.remembersStreamingRenderer,
               let last = messages.last(where: ChatMessageProjector.isConversationMessage),
               last.role == MessageRole.assistant {
                streamedMessageIDs.insert(ChatMessageProjector.messageId(for: last))
            }
        }
        let retained = streamedMessageIDs.intersection(currentIDs)
        if retained != streamedMessageIDs {
            streamedMessageIDs = retained
        }
        swiftUIRenderStateStore.retain(ids: currentIDs)
        swiftUIContentHashCache.retain(ids: currentIDs)
    }

    private var bottomFollowResumeThreshold: CGFloat {
        // 用户滑回底部附近(≤此阈值)才从 pausedForUser 恢复跟随。
        ChatLayout.nearBottomResumeThreshold
    }

    private var currentBottomDistance: CGFloat {
        runtime.scrollVisibleRectMaxY ?? .greatestFiniteMagnitude
    }

    private var streamFollowContentCanScroll: Bool {
        currentContentScrollable
    }

    private var currentContentScrollable: Bool {
        runtime.latestScrollGeometry.visibleHeight > 1 &&
            runtime.latestScrollGeometry.contentHeight > runtime.latestScrollGeometry.visibleHeight + ChatLayout.bottomStickThreshold
    }

    private func resetLatestGeometryForContentReplacement() {
        runtime.hasMeasuredScrollGeometry = false
        runtime.latestScrollGeometry = ChatSwiftUIScrollGeometry(
            distanceToBottom: 0,
            visibleHeight: max(1, runtime.latestScrollGeometry.visibleHeight),
            contentHeight: 0
        )
        runtime.scrollVisibleRectMaxY = 0
    }

    private func syncFollowMode(from state: ChatViewportState) {
        guard followGeneration else {
            runtime.followMode = .idle
            return
        }
        if state.followPaused {
            runtime.followMode = .pausedForUser
        } else if isGenerationActive || isLoading || runtime.followMode == .followingBottom {
            runtime.followMode = .followingBottom
        } else {
            runtime.followMode = .idle
        }
    }

    private func resumeFollowAfterUserScrollEndedIfNeeded() {
        let shouldResume = followGeneration && ChatSwiftUINearBottomResumePolicy.shouldResume(
            followPaused: viewportState.followPaused,
            userScrollActive: false,
            userScrollJustEnded: true,
            distanceToBottom: runtime.latestScrollGeometry.distanceToBottom
        )
        var next = viewportState
        next.userDragging = false
        if shouldResume {
            next.followPaused = false
            next.showScrollToBottom = false
            next.liveRenderingFarFromBottom = false
        }
        syncFollowMode(from: next)
        publish(next)
        guard followGeneration, !next.followPaused else { return }
        ChatPerfTrace.event("BottomResumeUser")
        if isGenerationActive || isLoading {
            scheduleStreamBottomFollow()
        }
    }

    private func shouldFollowMeasuredContentGrowth(
        previous: ChatSwiftUIScrollGeometry,
        current: ChatSwiftUIScrollGeometry,
        state: ChatViewportState
    ) -> Bool {
        ChatSwiftUIMeasuredGrowthFollowPolicy.shouldFollow(
            generationActive: isGenerationActive || isLoading,
            endSettleActive: runtime.generationEndSettleTask != nil,
            explicitBottomCatchUpActive: explicitBottomForcesLiveTail,
            explicitBottomAnimationActive: runtime.explicitBottomAnimationActive,
            followEnabled: followGeneration,
            followMode: runtime.followMode,
            state: state,
            userScrollActive: runtime.userScrollActive,
            previousContentHeight: previous.contentHeight,
            currentContentHeight: current.contentHeight,
            distanceToBottom: current.distanceToBottom
        )
    }

    private func shouldTrackMeasuredContentGrowth(
        previous: ChatSwiftUIScrollGeometry,
        current: ChatSwiftUIScrollGeometry,
        state: ChatViewportState
    ) -> Bool {
        ChatSwiftUIMeasuredGrowthFollowPolicy.shouldTrackGrowth(
            generationActive: isGenerationActive || isLoading,
            endSettleActive: runtime.generationEndSettleTask != nil,
            explicitBottomCatchUpActive: explicitBottomForcesLiveTail,
            followEnabled: followGeneration,
            followMode: runtime.followMode,
            state: state,
            userScrollActive: runtime.userScrollActive,
            previousContentHeight: previous.contentHeight,
            currentContentHeight: current.contentHeight
        )
    }

    private func scheduleGenerationEndSettle() {
        runtime.generationEndSettleTask?.cancel()
        ChatPerfTrace.end(&runtime.generationEndSettleTrace)
        runtime.generationEndSettleTrace = ChatPerfTrace.begin("TerminalSettle")
        runtime.generationEndSettleToken &+= 1
        let token = runtime.generationEndSettleToken
        runtime.generationEndSettleLastGrowthAt = Date()
        scrollToBottomIfScrollable()
        runtime.generationEndSettleTask = Task { @MainActor in
            for elapsedFrames in 1...ChatSwiftUIGenerationEndSettlePolicy.maxFrames {
                do {
                    try await Task.sleep(
                        nanoseconds: ChatSwiftUIGenerationEndSettlePolicy.frameDurationNanoseconds
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled, token == runtime.generationEndSettleToken else { return }
                let quietElapsed = Date().timeIntervalSince(runtime.generationEndSettleLastGrowthAt)
                guard ChatSwiftUIGenerationEndSettlePolicy.shouldFinish(
                    elapsedFrames: elapsedFrames,
                    quietElapsed: quietElapsed,
                    explicitBottomAnimationActive: runtime.explicitBottomAnimationActive
                ) else { continue }
                scrollToBottomIfScrollable()
                runtime.followMode = .idle
                runtime.generationEndSettleTask = nil
                ChatPerfTrace.end(&runtime.generationEndSettleTrace)
                return
            }
        }
    }

    private func cancelGenerationEndSettle() {
        guard runtime.generationEndSettleTask != nil else { return }
        ChatPerfTrace.event("TerminalSettleCancelled")
        runtime.generationEndSettleToken &+= 1
        runtime.generationEndSettleTask?.cancel()
        runtime.generationEndSettleTask = nil
        ChatPerfTrace.end(&runtime.generationEndSettleTrace)
    }

    private func shouldReanchorAfterViewportShrink(
        previous: ChatSwiftUIScrollGeometry,
        current: ChatSwiftUIScrollGeometry,
        state: ChatViewportState
    ) -> Bool {
        guard !state.followPaused,
              !state.userDragging,
              !runtime.userScrollActive else { return false }
        guard previous.visibleHeight > 1,
              current.visibleHeight > 1,
              previous.distanceToBottom <= ChatLayout.bottomStickThreshold else { return false }
        guard previous.visibleHeight - current.visibleHeight > 24 else { return false }
        guard current.contentHeight > current.visibleHeight + ChatLayout.bottomStickThreshold else { return false }
        return current.distanceToBottom > 1
    }

    @discardableResult
    private func executeViewportCommands(
        _ commands: [ChatViewportScrollCommand],
        state: ChatViewportState,
        event: ChatEvent,
        animateMeasuredGrowth: Bool
    ) -> Bool {
        guard !commands.isEmpty else { return false }
        var didIssueFollow = false
        for command in commands {
            switch command {
            case .none, .showBottomButton(_):
                break
            case .initialAnchor, .resetForConversationSwitch:
                scheduleConversationBottomAnchor()
            case let .followBottom(animated, _, _):
                guard !state.followPaused, !state.userDragging else { continue }
                guard ChatSwiftUIBottomWritePolicy.canIssueImmediateWrite(
                    explicitBottomAnimationActive: runtime.explicitBottomAnimationActive
                ) else {
                    didIssueFollow = true
                    continue
                }
                if animateMeasuredGrowth {
                    followMeasuredStreamGrowthToBottom()
                } else if animated && event == .assistantStreamDelta {
                    scheduleStreamBottomFollow()
                } else {
                    scrollToBottomAnchor(disableAnimations: !animated)
                }
                didIssueFollow = true
            }
        }
        return didIssueFollow
    }

    private func publish(_ next: ChatViewportState) {
        guard next != viewportState else { return }
        viewportState = next
        onViewportStateChange(next)
    }

    private func debugFollow(_ event: String, messages: [UIMessage]) {
        #if DEBUG
        print(
            "[AA-FOLLOW] \(event) messages=\(messages.count) active=\(isGenerationActive ? 1 : 0) " +
            "loading=\(isLoading ? 1 : 0) follow=\(followGeneration ? 1 : 0) " +
            "mode=\(runtime.followMode == .followingBottom ? "following" : runtime.followMode == .pausedForUser ? "paused" : "idle") " +
            "runtime.userScrollActive=\(runtime.userScrollActive ? 1 : 0) " +
            String(format: "distance=%.1f resume=%.1f", currentBottomDistance, bottomFollowResumeThreshold)
        )
        #endif
    }

}

