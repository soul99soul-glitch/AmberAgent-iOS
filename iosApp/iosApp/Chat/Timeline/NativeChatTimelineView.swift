import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine

/// Production Chat timeline. The native scroll driver owns normal bottom-follow;
/// SwiftUI takes over only after an explicit driver fallback.
struct NativeChatTimelineView: View {
    static let historyPageSize = 60
    var signal: ChatMessageUpdateSignal
    var configurationIssue: ChatConfigurationIssue?
    var isGenerationActive: Bool
    var isLoading: Bool
    var isRecognizingImages: Bool
    var contextCompactState: ChatContextCompactState
    var contextCompactBoundaries: [ChatContextCompactBoundary] = []
    var followGeneration: Bool
    var displaySetting: DisplaySetting
    var generativeUiSetting: GenerativeUiSetting
    var reasoningLevelLabel: String?
    var workspaceStore: IOSWorkspaceStore
    var scrollToBottomTrigger: Int
    var scrollToBottomSource: NativeTimelineBottomIntentSource
    var messageAnchor: ChatMessageAnchor?
    var currentConversationID: String?
    var messagesProvider: () -> [UIMessage]
    var variantInfoProvider: (Int) -> IOSConversationStore.VariantInfo?
    var onAction: (ChatListAction) -> Void
    var onViewportStateChange: (ChatViewportState) -> Void
    var onDismissKeyboard: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewportState = ChatViewportState()
    @State private var scrollPosition = ScrollPosition()
    @State private var lastScrollToBottomTrigger = 0
    @State private var streamedMessageIDs: Set<String> = []
    @State private var renderStateStore = ChatRenderStateStore()
    @State private var renderStateRevision: UInt64 = 0
    @State private var contentHashCache = ChatRowContentHashCache()
    @State private var projectionCache = NativeTimelineProjectionCache()
    @State private var scrollDriver = NativeTimelineScrollDriver()
    @State private var nativeUserScrollActive = false
    @State private var nativeTouchStartedWhileFollowing = false
    @State private var nativeDragPhaseOccurredDuringTouch = false
    @State private var nativeScrollFallbackReason: NativeTimelineScrollFallbackReason?
    @State private var nativeScrollFallbackShouldReplayBottom = false
    @State private var nativeScrollFallbackReplayToken: UInt64 = 0
    @State private var isNativeScrollSurfaceVisible = false
    @State private var nativeStreamingTailVisibility = ChatSwiftUIStreamingTailVisibilityState()
    @State private var consumedMessageAnchor: ChatMessageAnchor?
    @State private var scheduledMessageAnchor: ChatMessageAnchor?
    @State private var imageAccessibilityFocusToolCallID: String?
    @State private var highlightedMessageAnchor: ChatMessageAnchor?
    @State private var islandToolHighlight: ChatIslandToolHighlight?
    @State private var islandToolHighlightTask: Task<Void, Never>?
    @State private var historyStartIndex: Int?
    @State private var historyResetRevision: Int?
    @State private var historyRevealAnchor: HistoryRevealAnchor?
    @State private var historyBoundaryIDs: Set<String> = []
    @State private var laidOutHistoryFirstMessageID: String?
    @State private var expandedPhoneToolGroupIDs = ChatPhoneToolGroupExpansionStore.shared.expandedIDs
    @State private var phoneToolGroupToggleHandler = ChatPhoneToolGroupToggleHandler()

    var body: some View {
        let _ = phoneToolGroupToggleHandler.action = togglePhoneToolGroup
        let messages = messagesProvider()
        let startIndex = resolvedHistoryStartIndex(messages: messages)
        let nativeScrollDriverDesired = isNativeScrollDriverDesired
        let displaySettingSignature = String(describing: displaySetting)
        let generativeUiSettingSignature = String(describing: generativeUiSetting)
        let effectiveStreamedMessageIDs = effectiveStreamedMessageIDsForRender(
            event: signal.event,
            messages: messages
        )
        let renderViewportState = {
            var state = viewportState
            // Keep the eager timeline's existing Markdown tree while history is visible;
            // pause model publications instead of replacing that tree.
            state.liveRenderingFarFromBottom = false
            return state
        }()
        let projection = projectionCache.projection(
            messages: messages,
            event: signal.event,
            sourceRevision: signal.revision,
            startIndex: startIndex,
            configurationIssue: configurationIssue,
            isGenerationActive: isGenerationActive,
            isLoading: isLoading,
            isRecognizingImages: isRecognizingImages,
            contextCompactState: contextCompactState,
            contextCompactBoundaries: contextCompactBoundaries,
            viewportState: renderViewportState,
            displaySettingSignature: displaySettingSignature,
            generativeUiSettingSignature: generativeUiSettingSignature,
            renderStateRevision: renderStateRevision,
            reasoningLevelLabel: reasoningLevelLabel,
            streamedMessageIDs: effectiveStreamedMessageIDs,
            renderStateStore: renderStateStore,
            variantInfoProvider: variantInfoProvider,
            expandedPhoneToolGroupIDs: expandedPhoneToolGroupIDs
        ) { [contentHashCache] row, isStreamingLayout in
            isStreamingLayout
                ? contentHashCache.streamingTailLayoutToken(for: row)
                : contentHashCache.contentHash(for: row)
        }
        let firstHistoryEntryID = projection.entries.first(where: { $0.kind == .message })?.id
        ScrollViewReader { historyScrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if startIndex > 0 {
                        Button("加载更早的消息") {
                            loadEarlierMessages()
                        }
                        .font(.footnote)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(historyRevealAnchor != nil)
                        .accessibilityIdentifier("chat-load-earlier")
                    }
                    // Only materialize the loaded history window. Its eager height model
                    // keeps the existing live-tail and bottom-follow geometry stable.
                    ForEach(projection.entries) { entry in
                        let isHistoryBoundary = entry.id == firstHistoryEntryID || historyBoundaryIDs.contains(entry.id)
                        // Collapsed phone-step members occupy no space; the group head is the row.
                        let topSpacing: CGFloat = entry.id == projection.entries.first?.id ||
                            entry.phoneToolGroup?.isCollapsedMember == true ? 0 : (
                            entry.isAssistantContinuation ? ChatLayout.assistantPartSpacing : 14
                        )
                        if isHistoryBoundary {
                            Color.clear
                                .frame(height: 0)
                                .id("history-boundary-" + entry.id)
                                .accessibilityHidden(true)
                                .onGeometryChange(for: CGFloat?.self) { proxy in
                                    guard let viewport = proxy.bounds(of: .scrollView),
                                          viewport.height > 0 else { return nil }
                                    return -viewport.minY / viewport.height
                                } action: { previous, current in
                                    guard entry.id == firstHistoryEntryID else { return }
                                    // Only an upward crossing into the viewport reveals a page.
                                    // Initial layout, bottom entry and the prepend itself don't.
                                    guard let previous, let current,
                                          previous < 0, current >= 0,
                                          !(historyResetRevision != signal.revision &&
                                            (signal.event == .conversationLoaded || signal.event == .conversationSwitched ||
                                             signal.event == .branchChanged)),
                                          messageAnchor == nil || messageAnchor == consumedMessageAnchor else { return }
                                    loadEarlierMessages(position: UnitPoint(x: 0.5, y: current))
                                }
                                .padding(.top, topSpacing)
                        }
                        entryView(
                            entry,
                            displaySettingSignature: displaySettingSignature,
                            generativeUiSettingSignature: generativeUiSettingSignature
                        )
                        .padding(.top, isHistoryBoundary ? 0 : topSpacing)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .environment(\.chatPhoneToolGroupToggle, phoneToolGroupToggleHandler)
                .scrollTargetLayout()
                .onGeometryChange(for: String?.self) { _ in
                    projection.entries.first(where: { $0.kind == .message })?.messageId
                } action: { firstMessageID in
                    laidOutHistoryFirstMessageID = firstMessageID
                    restoreHistoryRevealAnchorIfReady(using: historyScrollProxy)
                    scrollToMessageAnchorIfAvailable()
                }
                .background {
                    if nativeScrollDriverDesired {
                        NativeTimelineScrollViewResolver(
                            onResolve: { scrollView in
                                handleNativeScrollViewResolved(scrollView)
                            },
                            onMetricsChanged: {
                                guard isNativeScrollDriverActive else { return }
                                scrollDriver.handleLayoutMetricsChanged()
                            }
                        )
                    }
                }
            }
            .modifier(ChatSizeChangesPinModifier(
                enabled: followGeneration && !isNativeScrollDriverDesired
            ))
            .nativeTimelineScrollPosition($scrollPosition)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollIndicators(.hidden)
            .overlay(alignment: .top) {
                if projection.entries.contains(where: { $0.kind == .emptyState }) {
                    // The welcome decoration has no message to follow when the composer grows.
                    ViewThatFits(in: .vertical) {
                        ChatEmptyState()
                        Color.clear
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    onDismissKeyboard()
                }
            )
            .onScrollPhaseChange { _, phase in
                guard isNativeScrollDriverActive else {
                    handleNativeFallbackScrollPhase(phase)
                    return
                }
                switch phase {
                case .tracking, .interacting:
                    guard Self.shouldBeginNativeUserDrag(
                        phase: phase,
                        isUIKitUserInteracting: scrollDriver.isUIKitUserInteracting
                    ) else { return }
                    if !nativeUserScrollActive {
                        // 新触摸开始：重置「本次触摸内是否出现过拖拽」。只在此处
                        // 重置（interacting 会在一次拖拽中反复触发，不能在分支里
                        // 无条件清零），否则首次真实拖拽后轻点恢复永久失效。
                        nativeDragPhaseOccurredDuringTouch = false
                    }
                    if phase == .interacting {
                        // SwiftUI 把「移动已开始的主动拖拽」归入 interacting；
                        // tracking 只是手指落下。轻点（tracking→idle）与拖拽
                        // （tracking→interacting→…→idle）由此区分。
                        nativeDragPhaseOccurredDuringTouch = true
                    }
                    nativeUserScrollActive = true
                    nativeTouchStartedWhileFollowing = scrollDriver.isFollowingBottomOrKeyboardFocus
                    onDismissKeyboard()
                    scrollDriver.submit(.userDragBegan)
                case .idle:
                    let endedUserScroll = nativeUserScrollActive
                    nativeUserScrollActive = false
                    // 轻点（从未进入拖拽相位）不该终止跟随：按下期间快速增长可能把
                    // 距底推过恢复阈值，但用户从未表达离开意图——恢复原跟随语义。
                    let accidentalTapRestore = endedUserScroll && followGeneration && Self
                        .shouldRestoreFollowAfterAccidentalTap(
                            wasFollowingAtTouchDown: nativeTouchStartedWhileFollowing,
                            dragPhaseOccurred: nativeDragPhaseOccurredDuringTouch,
                            generationActive: isGenerationActive || isLoading
                        )
                    if accidentalTapRestore {
                        scrollDriver.submit(.userDragEnded(isAtBottom: true))
                        resumeNativeBottomFollowAfterUserReturn()
                    } else if endedUserScroll {
                        let returnedToBottom = NativeTimelineScrollReturnPolicy.returnedToBottom(
                            liveDistanceToBottom: scrollDriver.distanceToBottomNow(),
                            cachedNearBottom: viewportState.isAtBottom,
                            threshold: ChatLayout.nearBottomResumeThreshold
                        )
                        scrollDriver.submit(.userDragEnded(isAtBottom: returnedToBottom))
                        if returnedToBottom {
                            resumeNativeBottomFollowAfterUserReturn()
                        }
                    }
                case .animating:
                    break
                case .decelerating:
                    // 甩向底部的惯性不等静止再判定：快速生成时底部在跑，静止时
                    // 往往已移出恢复窗口（用户被迫甩第二次）。释放瞬间用 pan 速度
                    // 预测落点，命中容差即磁吸接管。Reduce Motion 下不插入程序
                    // 缓动：让自然减速走完，由 .idle 相位的 returnedToBottom 判定
                    // 收口（该路径无动画）。
                    if !reduceMotion {
                        scrollDriver.attemptMagneticBottomSnapAfterDragRelease()
                    }
                @unknown default:
                    break
                }
            }
            .onScrollGeometryChange(for: ChatSwiftUIScrollGeometry.self) { geo in
                ChatSwiftUIScrollGeometry(
                    distanceToBottom: max(0, geo.contentSize.height - geo.visibleRect.maxY),
                    visibleHeight: max(1, geo.visibleRect.height),
                    contentHeight: geo.contentSize.height,
                    topInset: geo.contentInsets.top,
                    bottomInset: geo.contentInsets.bottom
                )
            } action: { previousGeometry, geometry in
                if isNativeScrollDriverActive && (
                    previousGeometry.visibleHeight != geometry.visibleHeight ||
                    previousGeometry.topInset != geometry.topInset ||
                    previousGeometry.bottomInset != geometry.bottomInset
                ) {
                    scrollDriver.handleLayoutMetricsChanged()
                }
                let wasAtBottom = viewportState.isAtBottom
                let messages = messagesProvider()
                let rawViewportState = NativeStaticTimelineViewportPolicy.state(
                    distanceToBottom: geometry.distanceToBottom,
                    visibleHeight: geometry.visibleHeight,
                    contentHeight: geometry.contentHeight,
                    hasMessages: !messages.isEmpty,
                    userInteracting: nativeUserScrollActive,
                    driverPausedForUser: isNativeScrollDriverActive && scrollDriver.isPausedForUser
                )
                let nextViewportState = rawViewportState
                publishViewportState(nextViewportState)
                unfreezeVisibleLiveTailIfNeeded(messages: messages, viewportState: nextViewportState)
                resumeNativeBottomFollowFromGeometryIfNeeded(
                    geometry: geometry,
                    viewportState: nextViewportState,
                    messages: messages
                )
                reanchorAfterViewportShrinkIfNeeded(
                    previous: previousGeometry,
                    current: geometry,
                    wasAtBottom: wasAtBottom
                )
            }
            .onAppear {
                isNativeScrollSurfaceVisible = true
                historyStartIndex = startIndex
                historyResetRevision = signal.revision
                // 重新进入页面时清除上一次的 fallback 粘连，给原生滚动 driver 一次重试机会。
                nativeScrollFallbackReason = nil
                updateRendererMemory(event: signal.event, messages: messages)
                consumeExternalScrollToBottomTriggerIfNeeded()
                scrollToMessageAnchorIfAvailable()
            }
            .task(id: highlightedMessageAnchor) {
                guard highlightedMessageAnchor != nil else { return }
                do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
                highlightedMessageAnchor = nil
            }
            .onDisappear {
                highlightedMessageAnchor = nil
                isNativeScrollSurfaceVisible = false
                historyRevealAnchor = nil
                nativeUserScrollActive = false
                scrollDriver.invalidate()
                islandToolHighlightTask?.cancel()
                islandToolHighlightTask = nil
                islandToolHighlight = nil
            }
            .onChange(of: followGeneration) { _, enabled in
                scrollDriver.setAutomaticFollowEnabled(enabled)
            }
            .onChange(of: signal) { _, newSignal in
                if newSignal.event == .conversationLoaded || newSignal.event == .conversationSwitched ||
                    newSignal.event == .branchChanged {
                    historyRevealAnchor = nil
                    historyBoundaryIDs.removeAll()
                    historyStartIndex = max(0, messagesProvider().count - Self.historyPageSize)
                    historyResetRevision = newSignal.revision
                }
                updateRendererMemory(event: newSignal.event, messages: messagesProvider())
                submitNativeScrollIntent(for: newSignal.event, lagAllowance: newSignal.lagAllowance)
                scrollToMessageAnchorIfAvailable()
            }
            .onChange(of: messageAnchor) { _, _ in
                scrollToMessageAnchorIfAvailable()
            }
            .onChange(of: expandedPhoneToolGroupIDs) { _, _ in
                // A pending anchor into a just-expanded phone-step group can now land.
                scrollToMessageAnchorIfAvailable()
            }
            .onChange(of: scrollToBottomTrigger) { _, trigger in
                consumeExternalScrollToBottomTriggerIfNeeded(trigger)
            }
            .onChange(of: nativeScrollFallbackReason) { _, reason in
                guard reason != nil else { return }
                if scheduledMessageAnchor != nil {
                    nativeScrollFallbackShouldReplayBottom = false
                    return
                }
                if scrollToMessageAnchorIfAvailable() {
                    nativeScrollFallbackShouldReplayBottom = false
                    return
                }
                guard nativeScrollFallbackShouldReplayBottom else { return }
                let replayToken = nativeScrollFallbackReplayToken
                nativeScrollFallbackShouldReplayBottom = false
                Task { @MainActor in
                    await Task.yield()
                    guard replayToken == nativeScrollFallbackReplayToken,
                          !nativeUserScrollActive else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        scrollPosition.scrollTo(id: ChatLayout.bottomAnchorID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var isNativeScrollDriverActive: Bool {
        isNativeScrollDriverDesired && scrollDriver.isAttached
    }

    private func resolvedHistoryStartIndex(messages: [UIMessage]) -> Int {
        let tailStart = max(0, messages.count - Self.historyPageSize)
        // body evaluates the new messages before onChange commits the reset. Never
        // render the previous window (often 0 from the empty page) for that first frame.
        if historyResetRevision != signal.revision,
           signal.event == .conversationLoaded || signal.event == .conversationSwitched ||
            signal.event == .branchChanged {
            return tailStart
        }
        return min(historyStartIndex ?? tailStart, tailStart)
    }

    private func loadEarlierMessages(position: UnitPoint = .top) {
        let messages = messagesProvider()
        let startIndex = resolvedHistoryStartIndex(messages: messages)
        guard startIndex > 0, historyRevealAnchor == nil else { return }
        guard let firstVisible = messages.dropFirst(startIndex).first(where: ChatMessageProjector.isVisibleInTimeline) else {
            historyStartIndex = max(0, startIndex - Self.historyPageSize)
            return
        }
        let anchorID = "message-\(ChatMessageProjector.messageId(for: firstVisible))"
        historyBoundaryIDs.insert(anchorID)
        historyRevealAnchor = HistoryRevealAnchor(
            id: "history-boundary-" + anchorID,
            position: position
        )
        scrollDriver.submit(.userDragBegan)
        nativeScrollFallbackReplayToken &+= 1
        nativeScrollFallbackShouldReplayBottom = false
        var paused = viewportState
        paused.isAtBottom = false
        paused.followPaused = true
        paused.showScrollToBottom = true
        publishViewportState(paused)
        historyStartIndex = max(0, startIndex - Self.historyPageSize)
    }

    private var isHistoryWindowLaidOut: Bool {
        let messages = messagesProvider()
        let startIndex = resolvedHistoryStartIndex(messages: messages)
        guard let firstVisible = messages.dropFirst(startIndex).first(where: ChatMessageProjector.isVisibleInTimeline) else {
            return false
        }
        return laidOutHistoryFirstMessageID == ChatMessageProjector.messageId(for: firstVisible)
    }

    private func restoreHistoryRevealAnchorIfReady(using proxy: ScrollViewProxy) {
        guard isNativeScrollSurfaceVisible, isHistoryWindowLaidOut,
              let anchor = historyRevealAnchor else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(anchor.id, anchor: anchor.position)
        }
        historyRevealAnchor = nil
    }

    static func shouldBeginNativeUserDrag(
        phase: ScrollPhase,
        isUIKitUserInteracting: Bool
    ) -> Bool {
        NativeTimelineUserDragPolicy.shouldBegin(
            phase: phase,
            isUIKitUserInteracting: isUIKitUserInteracting
        )
    }

    /// 轻点误伤恢复：触碰（.tracking）即暂停跟随防打架是有意的所有权设计，
    /// 但「按下→从未拖拽→抬起」是误触——按下期间的快速增长可能把距底推过
    /// 恢复阈值，静止判定会漏恢复。仅当按下时确在跟随、期间无拖拽相位、
    /// 生成仍在进行时恢复跟随。
    static func shouldRestoreFollowAfterAccidentalTap(
        wasFollowingAtTouchDown: Bool,
        dragPhaseOccurred: Bool,
        generationActive: Bool
    ) -> Bool {
        wasFollowingAtTouchDown && !dragPhaseOccurred && generationActive
    }

    private var isNativeScrollDriverDesired: Bool {
        nativeScrollFallbackReason == nil &&
            isNativeScrollSurfaceVisible
    }

    private func handleNativeScrollViewResolved(_ scrollView: UIScrollView) {
        guard isNativeScrollDriverDesired else { return }
        scrollDriver.setAutomaticFollowEnabled(followGeneration)
        scrollDriver.onFallback = { reason, shouldReplayBottom in
            handleNativeScrollFallback(reason, shouldReplayBottom: shouldReplayBottom)
        }
        let didAttach = scrollDriver.attach(scrollView)
        guard didAttach, scrollDriver.isAttached else { return }
        if scrollToMessageAnchorIfAvailable() {
            return
        }
        if nativeUserScrollActive || viewportState.followPaused {
            scrollDriver.submit(.userDragBegan)
        } else {
            scrollDriver.submit(.explicitBottom(source: .button, animated: false, keyboardToken: nil))
            if followGeneration, shouldSettleNativeScrollAfterAttach {
                scrollDriver.submit(.generationTerminated)
            }
        }
    }

    @discardableResult
    private func scrollToMessageAnchorIfAvailable() -> Bool {
        guard let request = messageAnchor,
              scheduledMessageAnchor != request,
              consumedMessageAnchor != request else {
            return false
        }
        let messages = messagesProvider()
        let availableMessageIDs = Set(messages.map(ChatMessageProjector.messageId(for:)))
        let availableImageToolCallIDsByMessageID = Self.imageToolCallIDsByMessageID(in: messages)
        let availableToolCallIDsByMessageID = Self.toolCallIDsByMessageID(in: messages)
        guard let targetID = NativeTimelineMessageAnchorPolicy.targetEntryID(
                request: request,
                consumed: consumedMessageAnchor,
                currentConversationID: currentConversationID,
                availableMessageIDs: availableMessageIDs,
                availableImageToolCallIDsByMessageID: availableImageToolCallIDsByMessageID,
                availableToolCallIDsByMessageID: availableToolCallIDsByMessageID
              ),
              NativeTimelineMessageAnchorPolicy.canSchedule(
                nativeDriverActive: isNativeScrollDriverActive,
                fallbackActive: nativeScrollFallbackReason != nil
              ) else {
            return false
        }
        if expandPhoneToolGroupForAnchorIfNeeded(targetID) {
            return true
        }

        historyRevealAnchor = nil
        if let index = messages.firstIndex(where: {
            ChatMessageProjector.messageId(for: $0) == request.messageID
        }) {
            historyStartIndex = min(resolvedHistoryStartIndex(messages: messages), index)
        }
        if isNativeScrollDriverActive {
            scrollDriver.submit(.userDragBegan)
        } else {
            nativeScrollFallbackReplayToken &+= 1
            nativeScrollFallbackShouldReplayBottom = false
            var paused = viewportState
            paused.followPaused = true
            paused.showScrollToBottom = true
            publishViewportState(paused)
        }
        // The target must belong to the window that has actually completed layout.
        // A task yield alone does not establish that after revealing older messages.
        guard isHistoryWindowLaidOut else { return true }
        scheduledMessageAnchor = request
        Task { @MainActor in
            await Task.yield()
            let currentMessages = messagesProvider()
            guard NativeTimelineMessageAnchorPolicy.targetEntryID(
                request: request,
                consumed: consumedMessageAnchor,
                currentConversationID: currentConversationID,
                availableMessageIDs: Set(currentMessages.map(ChatMessageProjector.messageId(for:))),
                availableImageToolCallIDsByMessageID: Self.imageToolCallIDsByMessageID(in: currentMessages),
                availableToolCallIDsByMessageID: Self.toolCallIDsByMessageID(in: currentMessages)
            ) == targetID else {
                scheduledMessageAnchor = nil
                return
            }
            if reduceMotion {
                scrollPosition.scrollTo(id: targetID, anchor: .center)
                await Task.yield()
                completeMessageAnchorScroll(request: request, targetID: targetID)
            } else {
                withAnimation(.easeOut(duration: 0.24), completionCriteria: .logicallyComplete) {
                    scrollPosition.scrollTo(id: targetID, anchor: .center)
                } completion: {
                    completeMessageAnchorScroll(request: request, targetID: targetID)
                }
            }
        }
        return true
    }

    private func completeMessageAnchorScroll(
        request: ChatMessageAnchor,
        targetID: String
    ) {
        let currentMessages = messagesProvider()
        let imageToolCallIDsByMessageID = Self.imageToolCallIDsByMessageID(in: currentMessages)
        let toolCallIDsByMessageID = Self.toolCallIDsByMessageID(in: currentMessages)
        guard scheduledMessageAnchor == request,
              NativeTimelineMessageAnchorPolicy.targetEntryID(
                request: request,
                consumed: consumedMessageAnchor,
                currentConversationID: currentConversationID,
                availableMessageIDs: Set(currentMessages.map(ChatMessageProjector.messageId(for:))),
                availableImageToolCallIDsByMessageID: imageToolCallIDsByMessageID,
                availableToolCallIDsByMessageID: toolCallIDsByMessageID
              ) == targetID else {
            scheduledMessageAnchor = nil
            return
        }
        if let toolCallID = request.toolCallID {
            imageAccessibilityFocusToolCallID = nil
            if imageToolCallIDsByMessageID[request.messageID]?.contains(toolCallID) == true {
                imageAccessibilityFocusToolCallID = toolCallID
                if UIAccessibility.isVoiceOverRunning,
                   let announcement = Self.imageAnchorAnnouncement(
                    messageID: request.messageID,
                    toolCallID: toolCallID,
                    messages: currentMessages
                   ) {
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
            }
            showIslandToolHighlight(
                messageID: request.messageID,
                toolCallID: toolCallID,
                requestToken: request.requestToken
            )
        }
        if request.toolCallID == nil, request.requestToken != nil {
            highlightedMessageAnchor = request
        }
        ChatImageGenerationResumeConsumption.markViewedIfCompleted(
            anchor: request,
            messages: currentMessages,
            isGenerationActive: isGenerationActive
        )
        consumedMessageAnchor = request
        scheduledMessageAnchor = nil
    }

    private func showIslandToolHighlight(messageID: String, toolCallID: String, requestToken: UUID?) {
        let highlight = ChatIslandToolHighlight(
            messageID: messageID,
            toolCallID: toolCallID,
            requestToken: requestToken ?? UUID()
        )
        islandToolHighlightTask?.cancel()
        islandToolHighlight = highlight
        islandToolHighlightTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, islandToolHighlight == highlight else { return }
            islandToolHighlight = nil
            islandToolHighlightTask = nil
        }
    }

    private static func imageToolCallIDsByMessageID(in messages: [UIMessage]) -> [String: Set<String>] {
        messages.reduce(into: [:]) { result, message in
            let imageToolCallIDs = Set<String>(message.parts.compactMap { part in
                guard let tool = part as? UIMessagePart.Tool,
                      tool.toolName == "generate_image" else { return nil }
                return tool.toolCallId
            })
            guard !imageToolCallIDs.isEmpty else { return }
            result[ChatMessageProjector.messageId(for: message)] = imageToolCallIDs
        }
    }

    private static func toolCallIDsByMessageID(in messages: [UIMessage]) -> [String: Set<String>] {
        messages.reduce(into: [:]) { result, message in
            let toolCallIDs = Set(message.parts.compactMap { part in
                (part as? UIMessagePart.Tool)?.toolCallId
            })
            guard !toolCallIDs.isEmpty else { return }
            result[ChatMessageProjector.messageId(for: message)] = toolCallIDs
        }
    }

    private static func imageAnchorAnnouncement(
        messageID: String,
        toolCallID: String,
        messages: [UIMessage]
    ) -> String? {
        guard let message = messages.first(where: {
            ChatMessageProjector.messageId(for: $0) == messageID
        }),
              let tool = message.parts.compactMap({ $0 as? UIMessagePart.Tool }).first(where: {
                  $0.toolName == "generate_image" && $0.toolCallId == toolCallID
              }) else {
            return nil
        }
        if tool.output.contains(where: { $0 is UIMessagePart.Image }) {
            return IOSAppLocalization.string(
                "已定位到生成图片",
                defaultValue: "已定位到生成图片"
            )
        }
        return tool.output.isEmpty
            ? IOSAppLocalization.string(
                "已定位到正在生成的图片",
                defaultValue: "已定位到正在生成的图片"
            )
            : IOSAppLocalization.string(
                "已定位到图片生成失败结果",
                defaultValue: "已定位到图片生成失败结果"
            )
    }

    private var shouldSettleNativeScrollAfterAttach: Bool {
        if !isGenerationActive && !isLoading {
            return true
        }
        switch signal.event {
        case .generationCompleted, .generationFailed, .generationCancelled,
             .generationHandedOffToBackground:
            return true
        case .userMessageAppended, .assistantStreamDelta, .assistantStreamClosed,
             .toolCallStarted, .toolResultAppended, .awaitingToolApproval,
             .conversationLoaded, .conversationSwitched, .branchChanged, .settingsRefreshed:
            return false
        }
    }

    @ViewBuilder
    private func entryView(
        _ entry: NativeTimelineEntry,
        displaySettingSignature: String,
        generativeUiSettingSignature: String
    ) -> some View {
        switch entry.kind {
        case .emptyState:
            EmptyView()
        case .configurationIssue(let compact):
            if let configurationIssue {
                ChatConfigurationNoticeCard(
                    issue: configurationIssue,
                    compact: compact,
                    onPrimary: { onAction(.primaryConfiguration) },
                    onModelDefaults: { onAction(.modelDefaults) }
                )
            }
        case .message:
            if entry.phoneToolGroup?.isCollapsedMember == true, let messageId = entry.messageId {
                // Collapsed phone-step member: its head row renders the group. Keep the
                // entry identity and tail-visibility bookkeeping, build no bubble.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0)
                    .frame(height: 0)
                    .id(entry.id)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    .modifier(
                        ChatSwiftUIStreamingTailVisibilityModifier(
                            active: entry.isLastMessage &&
                                entry.role == MessageRole.assistant &&
                                entry.hasEverStreamed,
                            assumeVisible: !viewportState.liveRenderingFarFromBottom,
                            onVisibilityChanged: { isVisible in
                                updateNativeStreamingTailVisibility(
                                    messageID: messageId,
                                    isVisible: isVisible
                                )
                            }
                        )
                    )
            } else if let message = entry.message,
               let index = entry.index,
               let messageId = entry.messageId {
                let model = nativeMessageRenderModel(
                    entry: entry,
                    message: message,
                    index: index,
                    messageId: messageId
                )
                NativeTimelineMessageBubble(
                    entryID: entry.id,
                    renderDigest: entry.renderDigest,
                    model: model,
                    displaySetting: displaySetting,
                    generativeUiSetting: generativeUiSetting,
                    displaySettingSignature: displaySettingSignature,
                    generativeUiSettingSignature: generativeUiSettingSignature,
                    reasoningLevelLabel: reasoningLevelLabel,
                    imageAccessibilityFocusToolCallID: consumedMessageAnchor?.messageID == messageId
                        ? imageAccessibilityFocusToolCallID : nil,
                    onAction: onAction
                )
                .equatable()
                .environment(
                    \.chatIslandToolHighlight,
                    islandToolHighlight?.messageID == messageId ? islandToolHighlight : nil
                )
                .environment(
                    \.chatMessageAnchorHighlighted,
                    highlightedMessageAnchor?.conversationID == currentConversationID &&
                        highlightedMessageAnchor?.messageID == messageId
                )
                .padding(.leading, entry.phoneToolGroup?.isExpandedMember == true
                    ? ChatPhoneToolGroupHeader.expandedStepIndent : 0)
                .saturation(entry.isCompactedHistory ? 0 : 1)
                .opacity(entry.isCompactedHistory && entry.role != MessageRole.user ? 0.7 : 1)
                .environment(workspaceStore)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    maxWidth: .infinity,
                    alignment: entry.role == MessageRole.user ? .topTrailing : .topLeading
                )
                .id(entry.id)
                .transition(userMessageInsertionTransition(for: entry))
                .zIndex(entry.canAnimateInsertion ? 1 : 0)
                .modifier(
                    ChatSwiftUIStreamingTailVisibilityModifier(
                        active: entry.isLastMessage &&
                            entry.role == MessageRole.assistant &&
                            entry.hasEverStreamed,
                        assumeVisible: !viewportState.liveRenderingFarFromBottom,
                        onVisibilityChanged: { isVisible in
                            updateNativeStreamingTailVisibility(
                                messageID: messageId,
                                isVisible: isVisible
                            )
                        }
                    )
                )
                .onAppear {
                    if entry.hasEverStreamed { markRenderVisible(messageId) }
                }
                .onDisappear {
                    guard entry.hasEverStreamed, !entry.isLastMessage else { return }
                    renderStateStore.freeze(
                        messageID: messageId,
                        latestText: message.singleNonEmptyTextPart
                    )
                }
            }
        case .pendingAssistant:
            ChatAssistantPendingResponseView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .chatLiveEntrance(key: "pending:\(entry.id)", isLive: true)
        case .visionRecognition:
            VisionRecognitionIndicator()
        case .contextMarker:
            ContextCompactTimelineMarker(state: entry.compactState ?? contextCompactState)
        case .bottomAnchor:
            Color.clear
                .frame(height: ChatLayout.bottomRestGap)
                .id(ChatLayout.bottomAnchorID)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func nativeMessageRenderModel(
        entry: NativeTimelineEntry,
        message: UIMessage,
        index: Int,
        messageId: String
    ) -> ChatListMessageRenderModel {
        let row = ChatMessageRowModel(
            rowId: messageId,
            messageId: messageId,
            message: message,
            role: entry.role ?? message.role,
            parts: message.parts,
            index: index,
            isLast: entry.isLastMessage,
            isStreaming: entry.isStreaming,
            hasEverStreamed: entry.renderHasEverStreamed,
            canAnimateInsertion: entry.canAnimateInsertion,
            isAssistantContinuation: entry.isAssistantContinuation
        )
        let renderState = entry.renderState ?? renderStateStore.stateForRow(
            row,
            isLiveRenderingFarFromBottom: viewportState.liveRenderingFarFromBottom
        )
        let liveTailModel = nativeLiveTailModelIfNeeded(row: row, renderState: renderState)
        return ChatListMessageRenderModel(
            row: row,
            variantInfo: variantInfoProvider(index),
            renderState: renderState,
            isGenerationActive: isGenerationActive,
            renderIdentity: ChatListSnapshotBuilder.renderIdentityForRow(row, renderState: renderState),
            liveTailModel: liveTailModel,
            phoneToolGroup: entry.phoneToolGroup?.headSummary
        )
    }

    /// Presentation state: expanding a phone-step group changes its rows' content
    /// signature exactly once. No animation: the scroll arbiter owns geometry.
    private func togglePhoneToolGroup(_ groupID: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let expanded = !expandedPhoneToolGroupIDs.contains(groupID)
            ChatPhoneToolGroupExpansionStore.shared.setExpanded(expanded, groupID: groupID)
            expandedPhoneToolGroupIDs = ChatPhoneToolGroupExpansionStore.shared.expandedIDs
        }
    }

    /// An anchor into a collapsed phone-step group first expands that group
    /// (presentation toggle, one content-signature change); the anchor request is
    /// retried once the expanded rows exist (`onChange(of: expandedPhoneToolGroupIDs)`).
    /// Returns true while the expansion is pending.
    private func expandPhoneToolGroupForAnchorIfNeeded(_ targetID: String) -> Bool {
        guard targetID.hasPrefix("tool-call-"),
              let groupID = projectionCache.collapsedPhoneToolGroupIDsByAnchor()[targetID],
              !expandedPhoneToolGroupIDs.contains(groupID) else { return false }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            ChatPhoneToolGroupExpansionStore.shared.setExpanded(true, groupID: groupID)
            expandedPhoneToolGroupIDs = ChatPhoneToolGroupExpansionStore.shared.expandedIDs
        }
        return true
    }

    private func nativeLiveTailModelIfNeeded(
        row: ChatMessageRowModel,
        renderState: ChatRenderState
    ) -> ChatLiveTailModel? {
        // Keep the same hosted subtree after a send turns the old tail into
        // history. Historical rendering consumes the row snapshot below.
        if let existing = renderStateStore.existingLiveTailModel(messageID: row.messageId) {
            return existing
        }
        guard renderState.liveRenderingEnabled else { return nil }
        return renderStateStore.liveTailModel(
            for: row,
            renderState: renderState,
            isGenerationActive: isGenerationActive
        )
    }

    private func userMessageInsertionTransition(for entry: NativeTimelineEntry) -> AnyTransition {
        if let message = entry.message, ChatMessageProjector.isSubAgentResult(message) {
            return reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8))
        }
        guard !reduceMotion,
              entry.canAnimateInsertion,
              entry.role == MessageRole.user else { return .identity }
        return .chatUserMessageSend
    }

    private func updateRendererMemory(event: ChatEvent, messages: [UIMessage]) {
        if event == .conversationLoaded || event == .conversationSwitched || event == .branchChanged {
            renderStateStore.removeAll()
            contentHashCache.removeAll()
            projectionCache.reset()
            nativeStreamingTailVisibility = ChatSwiftUIStreamingTailVisibilityState()
        }
        if event == .assistantStreamDelta,
           let last = messages.last(where: ChatMessageProjector.isConversationMessage),
           last.role == MessageRole.assistant {
            streamedMessageIDs.insert(ChatMessageProjector.messageId(for: last))
        } else {
            let currentIDs = Set(messages.map(ChatMessageProjector.messageId(for:)))
            streamedMessageIDs = NativeStaticTimelineRendererMemory.nextStreamedMessageIDs(
                previous: streamedMessageIDs,
                event: event,
                messages: messages
            )
            renderStateStore.retain(ids: currentIDs)
            contentHashCache.retain(ids: currentIDs)
        }
        unfreezeVisibleLiveTailIfNeeded(messages: messages, viewportState: viewportState)
    }

    private func effectiveStreamedMessageIDsForRender(event: ChatEvent, messages: [UIMessage]) -> Set<String> {
        if event == .assistantStreamDelta,
           let last = messages.last(where: ChatMessageProjector.isConversationMessage),
           last.role == MessageRole.assistant {
            var next = streamedMessageIDs
            next.insert(ChatMessageProjector.messageId(for: last))
            return next
        }
        return NativeStaticTimelineRendererMemory.nextStreamedMessageIDs(
            previous: streamedMessageIDs,
            event: event,
            messages: messages
        )
    }

    private func isNativeMeasuredNearBottom(_ geometry: ChatSwiftUIScrollGeometry) -> Bool {
        geometry.distanceToBottom <= max(ChatLayout.bottomStickThreshold, NativeTimelineScrollCore.resumeEpsilon)
    }

    private func unfreezeVisibleLiveTailIfNeeded(messages: [UIMessage], viewportState: ChatViewportState) {
        guard let lastAssistantID = latestAssistantMessageID(messages: messages) else { return }
        guard NativeTimelineStreamingTailUpdatePolicy.shouldUpdate(
            messageID: lastAssistantID,
            isFarFromBottom: viewportState.liveRenderingFarFromBottom,
            visibility: nativeStreamingTailVisibility
        ) else { return }
        markRenderVisible(lastAssistantID)
        var liveViewportState = viewportState
        // A tail row can intersect the viewport even when its bottom is far away
        // (for example, the user is reading the top of a very long response).
        // Keep LOD for off-screen rows, but let this visible row consume deltas.
        liveViewportState.liveRenderingFarFromBottom = false
        updateNativeLiveTailModelIfNeeded(messages: messages, viewportState: liveViewportState)
    }

    private func updateNativeStreamingTailVisibility(messageID: String, isVisible: Bool) {
        if isVisible {
            let next = ChatSwiftUIStreamingTailVisibilityState(messageID: messageID, isVisible: true)
            guard next != nativeStreamingTailVisibility else { return }
            nativeStreamingTailVisibility = next
            unfreezeVisibleLiveTailIfNeeded(
                messages: messagesProvider(),
                viewportState: viewportState
            )
        } else if nativeStreamingTailVisibility.messageID == messageID {
            guard nativeStreamingTailVisibility.isVisible != false else { return }
            nativeStreamingTailVisibility.isVisible = false
        }
    }

    private func markRenderVisible(_ messageID: String) {
        if renderStateStore.markVisible(messageID) {
            renderStateRevision &+= 1
        }
    }

    private func latestAssistantMessageID(messages: [UIMessage]) -> String? {
        guard let lastAssistant = messages.last(where: { $0.role == MessageRole.assistant }) else {
            return nil
        }
        return ChatMessageProjector.messageId(for: lastAssistant)
    }

    private func updateNativeLiveTailModelIfNeeded(messages: [UIMessage], viewportState: ChatViewportState) {
        guard let indexedMessage = messages.enumerated().last(where: { $0.element.role == MessageRole.assistant })
        else { return }
        let message = indexedMessage.element
        let messageID = ChatMessageProjector.messageId(for: message)
        let isLast = indexedMessage.offset == messages.lastIndex(where: ChatMessageProjector.isVisibleInTimeline)
        let isStreaming = signal.event == .assistantStreamDelta && isLast
        let row = ChatMessageRowModel(
            rowId: messageID,
            messageId: messageID,
            message: message,
            role: message.role,
            parts: message.parts,
            index: indexedMessage.offset,
            isLast: isLast,
            isStreaming: isStreaming,
            hasEverStreamed: isStreaming || streamedMessageIDs.contains(messageID),
            canAnimateInsertion: false,
            isAssistantContinuation: ChatMessageProjector.isAssistantContinuation(at: indexedMessage.offset, in: messages)
        )
        let renderState = renderStateStore.stateForRow(
            row,
            isLiveRenderingFarFromBottom: viewportState.liveRenderingFarFromBottom
        )
        guard renderState.liveRenderingEnabled else { return }
        let liveTailModel = renderStateStore.liveTailModel(
            for: row,
            renderState: renderState,
            isGenerationActive: isGenerationActive
        )
        liveTailModel?.update(
            message: row.message,
            isGenerationActive: isGenerationActive,
            renderState: renderState,
            sourceRevision: signal.revision
        )
    }

    private func resumeNativeBottomFollowFromGeometryIfNeeded(
        geometry: ChatSwiftUIScrollGeometry,
        viewportState: ChatViewportState,
        messages: [UIMessage]
    ) {
        guard followGeneration,
              isNativeScrollDriverActive,
              !nativeUserScrollActive,
              isGenerationActive || isLoading,
              isNativeMeasuredNearBottom(geometry),
              scrollDriver.isPausedForUser || viewportState.followPaused || viewportState.liveRenderingFarFromBottom
        else { return }
        scrollDriver.submit(.userDragEnded(isAtBottom: true))
        unfreezeVisibleLiveTailIfNeeded(messages: messages, viewportState: viewportState)
        scrollDriver.submit(.streamContentGrew())
    }

    private func resumeNativeBottomFollowAfterUserReturn() {
        guard followGeneration else { return }
        let messages = messagesProvider()
        var next = viewportState
        next.followPaused = false
        next.userDragging = false
        next.isAtBottom = true
        next.liveRenderingFarFromBottom = false
        next.showScrollToBottom = false
        publishViewportState(next)
        unfreezeVisibleLiveTailIfNeeded(messages: messages, viewportState: next)
        if isGenerationActive || isLoading {
            scrollDriver.submit(.streamContentGrew())
        }
    }

    private func reanchorAfterViewportShrinkIfNeeded(
        previous: ChatSwiftUIScrollGeometry,
        current: ChatSwiftUIScrollGeometry,
        wasAtBottom: Bool
    ) {
        guard wasAtBottom,
              previous.visibleHeight - current.visibleHeight > 2,
              current.contentHeight > current.visibleHeight + ChatLayout.bottomStickThreshold else { return }
        guard !isNativeScrollDriverActive else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            scrollPosition.scrollTo(id: ChatLayout.bottomAnchorID, anchor: .bottom)
        }
    }

    private func consumeExternalScrollToBottomTriggerIfNeeded(_ trigger: Int? = nil) {
        let currentTrigger = trigger ?? scrollToBottomTrigger
        guard currentTrigger != lastScrollToBottomTrigger else { return }
        lastScrollToBottomTrigger = currentTrigger
        var next = viewportState
        next.followPaused = false
        next.userDragging = false
        next.isAtBottom = true
        next.liveRenderingFarFromBottom = false
        next.showScrollToBottom = false
        publishViewportState(next)
        unfreezeVisibleLiveTailIfNeeded(messages: messagesProvider(), viewportState: next)
        guard !isNativeScrollDriverActive else {
            scrollDriver.submit(
                .explicitBottom(
                    source: scrollToBottomSource,
                    animated: scrollToBottomSource != .composerFocus,
                    keyboardToken: UInt64(currentTrigger)
                )
            )
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            scrollPosition.scrollTo(id: ChatLayout.bottomAnchorID, anchor: .bottom)
        }
    }

    private func submitNativeScrollIntent(for event: ChatEvent, lagAllowance: CGFloat = 1) {
        guard isNativeScrollDriverActive else {
            submitNativeSwiftUIFallbackScrollIntent(for: event)
            return
        }
        switch event {
        case .conversationLoaded, .conversationSwitched:
            scrollDriver.submit(.conversationReset)
            scrollDriver.submit(.explicitBottom(source: .button, animated: false, keyboardToken: nil))
        case .branchChanged:
            scrollDriver.submit(.conversationReset)
        case .userMessageAppended:
            scrollDriver.submit(.explicitBottom(source: .button, animated: false, keyboardToken: nil))
        case .assistantStreamDelta:
            guard followGeneration else { return }
            scrollDriver.submit(.streamContentGrew(lagAllowance: lagAllowance))
        case .assistantStreamClosed, .toolCallStarted, .toolResultAppended,
             .awaitingToolApproval:
            if followGeneration,
               viewportState.isAtBottom || scrollDriver.isFollowingBottomOrKeyboardFocus || scrollDriver.isAtBottomNow() {
                scrollDriver.submit(.streamContentGrew())
            }
        case .generationCompleted, .generationFailed, .generationCancelled,
             .generationHandedOffToBackground:
            guard followGeneration else { return }
            scrollDriver.submit(.generationTerminated)
        case .settingsRefreshed:
            break
        }
    }

    private func publishViewportState(_ next: ChatViewportState) {
        guard next != viewportState else { return }
        viewportState = next
        onViewportStateChange(next)
    }

    private func handleNativeScrollFallback(
        _ reason: NativeTimelineScrollFallbackReason,
        shouldReplayBottom: Bool
    ) {
        guard nativeScrollFallbackReason == nil else { return }
        nativeScrollFallbackReplayToken &+= 1
        nativeScrollFallbackShouldReplayBottom = shouldReplayBottom
        nativeScrollFallbackReason = reason
        NativeTimelineScrollDiagnostics.logFallbackActivated(reason: reason)
    }

    private func handleNativeFallbackScrollPhase(_ phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting:
            nativeScrollFallbackReplayToken &+= 1
            nativeUserScrollActive = true
            onDismissKeyboard()
        case .idle:
            nativeUserScrollActive = false
        case .animating, .decelerating:
            break
        @unknown default:
            break
        }
    }

    private func submitNativeSwiftUIFallbackScrollIntent(for event: ChatEvent) {
        guard !isNativeScrollDriverActive else { return }
        switch event {
        case .conversationLoaded, .conversationSwitched:
            resetNativeSwiftUIFallbackViewportForConversationEntry()
            requestNativeSwiftUIFallbackBottom(animated: false)
        case .userMessageAppended:
            requestNativeSwiftUIFallbackBottom(animated: false)
        case .assistantStreamDelta:
            guard canRunStreamingSwiftUIFallback else { return }
            guard canRunNativeSwiftUIFallbackBottomFollow else { return }
            requestNativeSwiftUIFallbackBottom(animated: false)
        case .assistantStreamClosed, .toolCallStarted, .toolResultAppended,
             .awaitingToolApproval, .generationCompleted, .generationFailed,
             .generationCancelled, .generationHandedOffToBackground:
            guard canRunStreamingSwiftUIFallback else { return }
            guard canRunNativeSwiftUIFallbackBottomFollow else { return }
            requestNativeSwiftUIFallbackBottom(animated: false)
        case .branchChanged, .settingsRefreshed:
            break
        }
    }

    private var canRunStreamingSwiftUIFallback: Bool {
        !isNativeScrollDriverDesired || nativeScrollFallbackReason != nil
    }

    private var canRunNativeSwiftUIFallbackBottomFollow: Bool {
        viewportState.isAtBottom &&
            !viewportState.followPaused &&
            !nativeUserScrollActive
    }

    private func requestNativeSwiftUIFallbackBottom(animated: Bool) {
        guard !nativeUserScrollActive else { return }
        if animated {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(id: ChatLayout.bottomAnchorID, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollPosition.scrollTo(id: ChatLayout.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func resetNativeSwiftUIFallbackViewportForConversationEntry() {
        nativeScrollFallbackReplayToken &+= 1
        nativeUserScrollActive = false
        var next = viewportState
        next.followPaused = false
        next.userDragging = false
        next.isAtBottom = true
        next.liveRenderingFarFromBottom = false
        next.showScrollToBottom = false
        publishViewportState(next)
    }
}

private struct ChatConfigurationNoticeCard: View {
    let issue: ChatConfigurationIssue
    let compact: Bool
    let onPrimary: () -> Void
    let onModelDefaults: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: localized(issue.title))
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .foregroundStyle(AmberTheme.foreground)
                Text(verbatim: localized(issue.message))
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(localized(primaryTitle), action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(AmberTheme.accent)

                if issue != .missingModel {
                    Button("选择模型", action: onModelDefaults)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AmberTheme.surface.opacity(0.92),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var primaryTitle: String {
        switch issue {
        case .missingAPIKey: "添加 API Key"
        case .invalidBaseURL: "修正服务商"
        case .missingModel: "选择模型"
        case .missingProvider: "配置服务商"
        case .providerDisabled: "启用服务商"
        case .unsupportedProvider: "切换服务商"
        case .codexNotSignedIn: "登录 Codex"
        case .grokNotSignedIn: "登录 Grok"
        case .geminiNotSignedIn: "登录 Antigravity"
        }
    }

    private func localized(_ key: String) -> String {
        IOSAppLocalization.string(key, defaultValue: key)
    }
}

private struct HistoryRevealAnchor {
    let id: String
    let position: UnitPoint
}

private extension View {
    func nativeTimelineScrollPosition(
        _ position: Binding<ScrollPosition>
    ) -> some View {
        self
            .scrollPosition(position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
    }
}

private enum ChatListSnapshotBuilder {

    static func renderIdentityForRow(_ row: ChatMessageRowModel, renderState: ChatRenderState) -> String {
        row.messageId
    }
}

/// 按「跟随生成」偏好开关 `.sizeChanges` 底锚,与小说创作统一。
/// 行锚定位置(用户上滑浏览历史)不会被它拽走(探针已实证)。
private struct ChatSizeChangesPinModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            content
        }
    }
}
