import SwiftUI
import UIKit
import os // TEMP-DIAG

private let novelLoopLog = os.Logger(subsystem: "app.amber.ios", category: "novel-loop") // TEMP-DIAG

struct NovelGhostwriteRevisionRequest: Identifiable {
    let id = UUID()
    let recommendedBrief: String
    let detail: String?
    let strategies: [NovelGhostwriteRevisionStrategy]
}

enum NovelComposerIntent: String, CaseIterable, Identifiable {
    case discuss
    case continueProse
    case wholeChapter

    var id: String { rawValue }

    static let discussionOptions: [NovelComposerIntent] = [.discuss]
    static let proseOptions: [NovelComposerIntent] = [.continueProse, .wholeChapter]

    var title: String {
        switch self {
        case .discuss:
            IOSAppLocalization.string("讨论", defaultValue: "讨论")
        case .continueProse:
            IOSAppLocalization.string("写一段", defaultValue: "写一段")
        case .wholeChapter:
            IOSAppLocalization.string("写整章", defaultValue: "写整章")
        }
    }

    init(mode: NovelSessionMode, granularity: NovelGenerationGranularity) {
        if mode == .discussPlan {
            self = .discuss
        } else {
            self = granularity == .wholeChapter ? .wholeChapter : .continueProse
        }
    }

    var requestValues: (mode: NovelSessionMode, granularity: NovelGenerationGranularity) {
        switch self {
        case .discuss: (.discussPlan, .wholeChapter)
        case .continueProse: (.writeProse, .continuation)
        case .wholeChapter: (.writeProse, .wholeChapter)
        }
    }
}

enum NovelComposerIntentPreference {
    private static let keyPrefix = "novel.composerIntent."

    static func resolve(
        stored: NovelComposerIntent?,
        collaborationMode: NovelCollaborationMode,
        hasConfirmedChapterPlan: Bool,
        branchNeedsSync: Bool = false
    ) -> NovelComposerIntent {
        let intent = stored ?? .discuss
        // 正文生成仍被 needsSync 门禁拦住；讨论规划可以继续，所以输入框切到讨论，
        // 不要把「写一段/写整章」偏好写盘。
        if branchNeedsSync, intent != .discuss {
            return .discuss
        }
        if collaborationMode == .ghostwrite,
           !hasConfirmedChapterPlan,
           intent == .wholeChapter {
            return .discuss
        }
        return intent
    }

    static func stored(
        for projectID: NovelProjectID,
        defaults: UserDefaults
    ) -> NovelComposerIntent? {
        defaults.string(forKey: key(for: projectID)).flatMap(NovelComposerIntent.init(rawValue:))
    }

    static func store(
        _ intent: NovelComposerIntent,
        for projectID: NovelProjectID,
        defaults: UserDefaults
    ) {
        defaults.set(intent.rawValue, forKey: key(for: projectID))
    }

    private static func key(for projectID: NovelProjectID) -> String {
        keyPrefix + projectID.rawValue.uuidString
    }
}

enum NovelSessionBottomProximityPolicy {
    static func isNearBottom(distanceToBottom: CGFloat) -> Bool {
        distanceToBottom <= ChatLayout.nearBottomResumeThreshold
    }
}

enum NovelSessionStreamingTailFreezePolicy {
    /// Freeze defers off-screen Markdown work. Completion does not make an
    /// off-screen row visible; the real visibility callback (or bottom follow)
    /// releases the snapshot when the user can actually see the terminal row.
    static func shouldHoldFrozenSnapshot(
        isFollowingBottom: Bool,
        isTerminalPresenting _: Bool,
        renderPolicyWouldSuspend: Bool
    ) -> Bool {
        !isFollowingBottom && renderPolicyWouldSuspend
    }
}

/// 流式尾部可见性的单一所有者：`streamingTailVisibility` 只有一个槽位，只接受
/// 当前所有者（有活跃尾部时是它，否则是仍在跟踪的那一行）的上报。
enum NovelSessionStreamingTailVisibilityOwnership {
    static func accepts(
        reportingMessageID: String,
        activeTailMessageID: String?,
        trackedMessageID: String?
    ) -> Bool {
        guard let owner = activeTailMessageID ?? trackedMessageID else { return false }
        return reportingMessageID == owner
    }
}

enum NovelSessionScrollGeometryPolicy {
    /// - isFollowingBottom: 仍处跟随底意图（未拖离）。讨论结束后人物问答卡等晚到的
    ///   底部插入若走 static，会先推离底部再被 viewportChanged 硬拽，造成跳变。
    static func events(
        previousContentHeight: CGFloat,
        currentContentHeight: CGFloat,
        userDragging: Bool,
        isLiveTail: Bool,
        isSettlingTerminal: Bool,
        isFollowingBottom: Bool = false,
        previousIsAtBottom: Bool,
        currentIsAtBottom: Bool
    ) -> [NovelSessionBottomFollowEvent] {
        if currentContentHeight - previousContentHeight > 0.5 {
            guard !userDragging else { return [] }
            if isLiveTail {
                return [.measuredStreamGrowth(isAtBottom: currentIsAtBottom)]
            }
            if isSettlingTerminal {
                return [.measuredTerminalGrowth(isAtBottom: currentIsAtBottom)]
            }
            // 仅当此前贴底时，跟随底意图下的晚到高度（问答卡）才继续贴底。
            // 勿在「略离底」时每帧 measuredStreamGrowth，否则会和布局互踢导致卡死。
            if isFollowingBottom, previousIsAtBottom {
                return [.measuredStreamGrowth(isAtBottom: currentIsAtBottom)]
            }
            guard previousIsAtBottom != currentIsAtBottom else { return [] }
            return [.staticContentGrowth(isAtBottom: currentIsAtBottom)]
        }
        guard previousIsAtBottom != currentIsAtBottom else { return [] }
        return [.viewportChanged(isAtBottom: currentIsAtBottom)]
    }
}

struct NovelSessionView: View {
    let workspace: NovelCreationViewModel
    let viewModel: NovelSessionViewModel
    let sharedSettings: any IOSSettingsSnapshotSource

    @Binding var inputText: String
    @Binding var injectionOverrides: NovelInjectionOverrides
    @Binding var inputBudgetTokens: Int
    let composerInputController: ComposerInputController

    let onOpenModel: () -> Void
    let onOpenCollection: (NovelCandidateID) -> Void
    let onOpenManualRewrite: (NovelCandidateID) -> Void
    let onFork: (NovelCheckpointID) -> Void
    let onOpenSettingProposals: (NovelSettingProposalRoute) -> Void
    let onAcceptSettingProposal: (NovelSettingProposalRecord) -> Void
    let onArchiveDiscussion: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage(IOSDisplayPreferenceKeys.followGeneration) private var followGeneration = true
    @State private var scrollPosition = ScrollPosition()
    @State private var followState = NovelSessionBottomFollowState()
    @State private var latestAtBottom = true
    @State private var latestNearBottom = true
    @State private var userDragging = false
    @State private var terminalSettleTask: Task<Void, Never>?
    @State private var explicitBottomAnimationTask: Task<Void, Never>?
    @State private var explicitBottomFollowPending = false
    @State private var scrollDriver = NativeTimelineScrollDriver()
    @State private var nativeScrollFallbackReason: NativeTimelineScrollFallbackReason?
    @State private var isNativeScrollSurfaceVisible = false
    @State private var composerInputHeight: CGFloat = 40
    @State private var composerBarHeight: CGFloat = 0
    @State private var isInputFocused = false
    @State private var isContextPanelPresented = false
    @State private var ghostwriteRevisionRequest: NovelGhostwriteRevisionRequest?
    @State private var pendingRecoveryAbandonTransactionIDs: [NovelPendingOperationID] = []
    @State private var recoveryAbandonTask: Task<Void, Never>?
    @State private var pendingUndo: NovelPendingCommittedUndo?
    /// Start with cold-open window; staged open expands to steady after first layout.
    @State private var historyWindowLimit = NovelSessionHistoryWindowPolicy.coldOpenLimit
    @State private var expandedArchiveIDs: Set<NovelMessageID> = []
    @State private var streamingTailVisibility = ChatSwiftUIStreamingTailVisibilityState()
    @State private var suspendedStreamingTailRow: NovelSessionRowModel?
    /// Message IDs that streamed during this session presentation. Keeps the
    /// incremental markdown renderer sticky after tail retire (avoids complete-time
    /// height flash). Cleared on session identity change. History always still
    /// renders markdown — this only chooses live vs cold markdown path.
    @State private var streamedMessageIDs: Set<String> = []
    var body: some View {
        let _ = Self._logChanges() // TEMP-DIAG
        NovelSessionTranscriptScope(
            workspace: workspace,
            viewModel: viewModel,
            expandedArchiveIDs: expandedArchiveIDs,
            onInitialRows: presentInitialRowsIfNeeded,
            onSignalChange: handleListSignalChange
        ) { listModel, listSignal in
            ZStack {
                AmberThemePageBackground(surface: .app)
                if viewModel.loadStage < .coreTranscript {
                    ProgressView("正在打开会话…")
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                } else {
                    transcript(listModel: listModel, listSignal: listSignal)

                    if followState.showsBottomButton, !(listModel?.isEmpty ?? true) {
                        VStack {
                            Spacer()
                            ChatScrollToBottomButton {
                                releaseSuspendedStreamingTail()
                                dispatchFollowEvent(.explicitBottomRequested)
                            }
                            .padding(.bottom, max(10, composerBarHeight + 10))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                        .zIndex(10)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if viewModel.isStopping || NovelSessionComposerPolicy.showsGenerationStatus(
                    isRunning: viewModel.isRunning,
                    isTerminalPresenting: viewModel.isTerminalPresenting,
                    activeRunKind: viewModel.activeRunKind,
                    hasGhostwriteProgress: viewModel.ghostwriteProgress != nil
                ) {
                    generationStatusStrip
                        // Fixed caption slot: avoid safeArea height collapse when
                        // the strip appears/disappears around stream start/finish.
                        .frame(minHeight: 28, alignment: .leading)
                }
                // Composer is usable after core; avoid building it during idle bind.
                if viewModel.loadStage >= .coreTranscript {
                    composer()
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ChatComposerHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
        }
        .onPreferenceChange(ChatComposerHeightPreferenceKey.self) { height in
            guard abs(composerBarHeight - height) > 0.5 else { return }
            composerBarHeight = height
        }
        .onAppear {
            isNativeScrollSurfaceVisible = true
            // 重新进入页面时清除上一次的 fallback 粘连，给原生滚动 driver 一次重试机会。
            nativeScrollFallbackReason = nil
        }
        .task(id: bindingTaskID) {
            await runStagedSessionOpen()
        }
        .onDisappear {
            if let committed = composerInputController.committedText(),
               committed != inputText {
                inputText = committed
            }
            isNativeScrollSurfaceVisible = false
            terminalSettleTask?.cancel()
            cancelExplicitBottomAnimation()
            scrollDriver.invalidate()
            viewModel.setTailPresentationSuspended(false)
        }
        .onChange(of: holdsFrozenStreamingTail, initial: true) { _, frozen in
            viewModel.setTailPresentationSuspended(frozen)
        }
        .onChange(of: followGeneration) { _, enabled in
            scrollDriver.setAutomaticFollowEnabled(enabled)
        }
        .sheet(item: $ghostwriteRevisionRequest) { request in
            NovelGhostwriteRevisionSheet(
                recommendedBrief: request.recommendedBrief,
                detail: request.detail,
                strategies: request.strategies,
                onCancel: { ghostwriteRevisionRequest = nil },
                onStart: { brief in
                    let started = viewModel.startGhostwriteRevision(brief: brief)
                    if started {
                        ghostwriteRevisionRequest = nil
                    }
                    return started
                }
            )
        }
        .confirmationDialog(
            pendingUndo?.kind == .polish ? "撤销这次润色？" : "撤销这次收录？",
            isPresented: Binding(
                get: { pendingUndo != nil },
                set: { if !$0 { pendingUndo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingUndo?.kind == .polish ? "撤销润色" : "撤销收录", role: .destructive) {
                let request = pendingUndo
                pendingUndo = nil
                Task { @MainActor in
                    guard let request else { return }
                    _ = await viewModel.undoCommittedChange(
                        checkpointID: request.checkpointID,
                        kind: request.kind
                    )
                }
            }
            Button("取消", role: .cancel) { pendingUndo = nil }
        } message: {
            Text("正文、剧情状态和相关资料会一起回到上一个存档点，不会删除历史记录。")
        }
    }

    private func transcript(
        listModel: NovelSessionListModel?,
        listSignal: NovelSessionListSignal
    ) -> some View {
        let historicalRows = listModel?.historicalRows ?? []
        let activeRunRows = listModel?.activeRunRows ?? []
        let historyStartIndex = NovelSessionHistoryWindowPolicy.startIndex(
            totalCount: historicalRows.count,
            limit: historyWindowLimit
        )
        let visibleHistoricalRows = historicalRows.dropFirst(historyStartIndex)
        let hiddenHistoryCount = historyStartIndex
        let languageCode = IOSAppLanguagePreference.selected().resolvedLanguage().rawValue
        let rowAskUserBlocker = askUserBlocker
        let rowRuntimeActionBlocker = NovelSessionComposerPolicy.runtimeActionBlocker(
            requiresReload: workspace.requiresReload,
            hasRefreshError: viewModel.hasRefreshError,
            isBusy: viewModel.isBusy
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if listModel?.isEmpty ?? true {
                    Text("新的创作对话")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 56)
                } else {
                    if hiddenHistoryCount > 0 {
                        Button {
                            revealEarlierHistory(
                                totalCount: historicalRows.count,
                                preserving: visibleHistoricalRows.first?.id
                            )
                        } label: {
                            Label(
                                "更早的创作记录（\(hiddenHistoryCount)）",
                                systemImage: "clock.arrow.circlepath"
                            )
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(AmberTheme.muted)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Windowed history is already bounded (`historyWindowLimit`).
                    // Keep it eager so multi-thousand-pt chapter bubbles are not
                    // unloaded by LazyVStack estimates (mid-list blank gaps +
                    // scroll jumps). Cold history stays behind "更早的创作记录".
                    if !visibleHistoricalRows.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(visibleHistoricalRows) { row in
                                transcriptRow(
                                    row,
                                    activeTailID: listModel?.activeTailID,
                                    languageCode: languageCode,
                                    askUserBlocker: rowAskUserBlocker,
                                    runtimeActionBlocker: rowRuntimeActionBlocker
                                )
                            }
                        }
                    }

                    // Active run stays in a sibling eager stack. The list model
                    // pins the just-finished run here after the tail retires, so
                    // complete does not reparent the same id into history.
                    // Do not merge the two ForEach: one VStack remeasures every
                    // historical chapter on each stream tick (155s main-thread
                    // hang / cpu_resource on 赵大来了-scale).
                    if !activeRunRows.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(activeRunRows) { row in
                                transcriptRow(
                                    row,
                                    activeTailID: listModel?.activeTailID,
                                    languageCode: languageCode,
                                    askUserBlocker: rowAskUserBlocker,
                                    runtimeActionBlocker: rowRuntimeActionBlocker
                                )
                            }
                        }
                    }
                }

                // Outside empty/non-empty: unresolved mentions can exist before any messages.
                if viewModel.loadStage >= .secondaryChrome {
                    identityCardsSection
                }

                Color.clear
                    .frame(height: ChatLayout.bottomRestGap)
                    .id(Self.bottomAnchorID)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, ChatLayout.contentHorizontalInset)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .scrollTargetLayout()
            .background {
                if isNativeScrollDriverDesired {
                    NativeTimelineScrollViewResolver(
                        onResolve: handleNativeScrollViewResolved,
                        onMetricsChanged: {
                            guard isNativeScrollDriverActive else { return }
                            scrollDriver.handleLayoutMetricsChanged()
                        }
                    )
                }
            }
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // 2026-07-26 撤锚:`.defaultScrollAnchor(.bottom, for: .sizeChanges)` 曾被当作
        // 流式底部锚点的唯一所有者,依据是早期合成探针的「逐帧零欠账」——
        // 但那套探针用 Color.frame(height:) 代理流式气泡,只覆盖 SwiftUI
        // 单次干净布局 pass,从未测过生产 ChatAssistantMarkdownView → vendor
        // ParagraphUIView(UITextView 增量 TextKit 布局 + 异步 invalidateIntrinsicContentSize)
        // 的真实异步增量路径。真机录屏(15fps 逐帧对齐)在小说「写整章」实测到连续
        // 三次 −391/−398/−385px 的结构性跳变,与标准 Chat 撤锚前实测的 893pt 底部
        // 欠账同源(见 ChatCollectionMessageList.swift:1510 附近注释)。现在撤掉这枚
        // 锚,把增长所有权交回下方 onScrollGeometryChange 的 measured-geometry 回调
        // (唯一写者,经 NovelSessionBottomFollowPolicy.reduce 的 .measuredStreamGrowth
        // 分支发出无动画的 .followBottom(animated: false))。
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissKeyboard()
            }
        )
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting:
                if isNativeScrollDriverActive {
                    guard NativeTimelineUserDragPolicy.shouldBegin(
                        phase: phase,
                        isUIKitUserInteracting: scrollDriver.isUIKitUserInteracting
                    ) else { return }
                }
                guard !userDragging else { return }
                userDragging = true
                dismissKeyboard()
                if isNativeScrollDriverActive {
                    scrollDriver.submit(.userDragBegan)
                }
                dispatchFollowEvent(.userDragBegan(isAtBottom: latestAtBottom))
            case .idle:
                guard userDragging else { return }
                userDragging = false
                let returnedToBottom = NativeTimelineScrollReturnPolicy.returnedToBottom(
                    liveDistanceToBottom: isNativeScrollDriverActive
                        ? scrollDriver.distanceToBottomNow()
                        : nil,
                    cachedNearBottom: latestNearBottom,
                    threshold: ChatLayout.nearBottomResumeThreshold
                )
                if isNativeScrollDriverActive {
                    scrollDriver.submit(.userDragEnded(isAtBottom: returnedToBottom))
                }
                if returnedToBottom {
                    releaseSuspendedStreamingTail()
                }
                dispatchFollowEvent(.userDragEnded(isAtBottom: returnedToBottom))
            case .animating, .decelerating:
                break
            @unknown default:
                break
            }
        }
        .onScrollGeometryChange(for: NovelSessionScrollGeometrySignal.self) { geometry in
            let distanceToBottom = geometry.contentSize.height - geometry.visibleRect.maxY
            return NovelSessionScrollGeometrySignal(
                contentHeight: geometry.contentSize.height,
                isAtBottom: distanceToBottom <= ChatLayout.bottomStickThreshold,
                isNearBottom: NovelSessionBottomProximityPolicy.isNearBottom(
                    distanceToBottom: distanceToBottom
                )
            )
        } action: { oldValue, newValue in
            if latestAtBottom != newValue.isAtBottom {
                latestAtBottom = newValue.isAtBottom
            }
            if latestNearBottom != newValue.isNearBottom {
                latestNearBottom = newValue.isNearBottom
            }
            let followEvents = NovelSessionScrollGeometryPolicy.events(
                previousContentHeight: oldValue.contentHeight,
                currentContentHeight: newValue.contentHeight,
                userDragging: userDragging,
                isLiveTail: isLiveTailPhase(listSignal.activeTailPhase),
                isSettlingTerminal: isSettlingTerminal,
                isFollowingBottom: isFollowingBottom,
                previousIsAtBottom: oldValue.isAtBottom,
                currentIsAtBottom: newValue.isAtBottom
            )
            for event in followEvents {
                dispatchFollowEvent(event)
            }
            // 近底被动恢复跟随：仅流式尾 / 终态收口。不要在普通 followingBottom
            // 下每帧 streamContentGrew（布局未完全贴底时会死循环，主线程卡死）。
            // 排空期必须携带当前 allowance：默认 1 会把同一拍先发的收紧值
            // 逐拍打回，τ_eff 恒为 τ（滞后 40–96pt 带内最明显）。
            if isNativeScrollDriverActive, !userDragging,
               !scrollDriver.isUIKitUserInteracting,
               isLiveTailPhase(listSignal.activeTailPhase) || isSettlingTerminal,
               newValue.isNearBottom, !newValue.isAtBottom {
                scrollDriver.submit(.streamContentGrew(
                    lagAllowance: viewModel.latestTailLagAllowance
                ))
            }
        }
        .transaction(value: listSignal.activeTailDigest) { transaction in
            if isLiveTailPhase(listSignal.activeTailPhase) {
                transaction.animation = nil
            }
        }
    }

    private func transcriptRow(
        _ row: NovelSessionRowModel,
        activeTailID: NovelMessageID?,
        languageCode: String,
        askUserBlocker: NovelSessionActionBlocker?,
        runtimeActionBlocker: NovelSessionActionBlocker?
    ) -> some View {
        let messageID = row.id.description
        let tracksStreamingTail = row.id == activeTailID ||
            streamingTailVisibility.messageID == messageID
        // Sticky for this presentation: still true after activeTailID clears on retire.
        let hasEverStreamed = tracksStreamingTail || streamedMessageIDs.contains(messageID)
        let updatesSuspended = NovelSessionStreamingTailFreezePolicy.shouldHoldFrozenSnapshot(
            isFollowingBottom: isFollowingBottom,
            isTerminalPresenting: viewModel.isTerminalPresenting,
            renderPolicyWouldSuspend: ChatSwiftUIStreamingTailRenderPolicy.shouldSuspend(
                isLastAssistant: tracksStreamingTail && row.role == .assistant,
                hasEverStreamed: hasEverStreamed,
                messageID: messageID,
                visibility: streamingTailVisibility
            )
        )
        let renderedRow = updatesSuspended && suspendedStreamingTailRow?.id == row.id
            ? suspendedStreamingTailRow ?? row
            : row

        return NovelSessionRowView(
            row: renderedRow,
            languageCode: languageCode,
            // Live tail + IDs that streamed this visit — not every assistant bubble.
            hasEverStreamed: hasEverStreamed,
            adoptingPolishCandidateID: viewModel.adoptingPolishCandidateID,
            retryingRunID: viewModel.retryingRunID,
            cloningCandidateID: viewModel.cloningCandidateID,
            undoingCheckpointID: viewModel.undoingCheckpointID,
            isStopping: viewModel.stoppingRunID == row.runID,
            isSubmittingChapterRevision: viewModel.answeringAskUserMessageID == row.id,
            askUserBlocker: askUserBlocker,
            runtimeActionBlocker: runtimeActionBlocker,
            polishRetryTransactionID: viewModel.polishRetryTransactionID,
            onAction: handleRowAction,
            onCancelPolishRetry: viewModel.cancelPolishRetry,
            onAnswerAskUser: handleAskUserAnswer,
            onToggleArchive: toggleArchive
        )
            .equatable()
            .fixedSize(horizontal: false, vertical: true)
            .id(row.id)
            .modifier(NovelSessionStreamingTailVisibilityModifier(
                active: tracksStreamingTail,
                onVisibilityChanged: { isVisible in
                    updateStreamingTailVisibility(
                        row: row,
                        isVisible: isVisible,
                        activeTailID: activeTailID
                    )
                }
            ))
    }

    private func handleAskUserAnswer(
        _ messageID: NovelMessageID,
        _ answer: String
    ) {
        guard askUserBlocker == nil else { return }
        dismissKeyboard()
        Task { @MainActor in
            _ = await viewModel.answerAskUser(
                promptMessageID: messageID,
                answer: answer
            )
        }
    }

    private func composer() -> some View {
        NovelSessionComposerDock(
            chrome: NovelSessionChrome(
                workspace: workspace,
                viewModel: viewModel,
                recovery: quickStartRecovery(),
                syncBannerText: syncBannerText,
                pendingRecoveryAbandonTransactionIDs: $pendingRecoveryAbandonTransactionIDs,
                recoveryAbandonTask: $recoveryAbandonTask,
                ghostwriteRevisionRequest: $ghostwriteRevisionRequest
            ),
            inputText: $inputText,
            inputHeight: $composerInputHeight,
            isInputFocused: $isInputFocused,
            isContextPanelPresented: $isContextPanelPresented,
            placeholder: inputPlaceholder,
            isInputEnabled: viewModel.access == .readWrite && !viewModel.isRunning,
            sendOnEnter: sendOnEnter,
            canSend: viewModel.canSend,
            isRunning: viewModel.isRunning,
            isStopping: viewModel.isStopping,
            canStop: viewModel.canStop,
            injectionOverrides: injectionOverrides,
            meta: composerMetaValues,
            controller: composerInputController,
            reduceMotion: accessibilityReduceMotion,
            onSend: send,
            onStop: stop,
            onOpenModel: onOpenModel,
            onArchiveDiscussion: onArchiveDiscussion,
            onSetIntent: viewModel.setComposerIntent
        )
    }

    private func quickStartRecovery() -> NovelSessionQuickStartRecovery? {
        guard workspace.projectSnapshot?.project.creationMode == .quickStart else { return nil }
        switch workspace.quickStartStatus {
        case .failed(let message):
            let hasDurableRetryOwner = workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.branchID == workspace.selectedBranchID &&
                    $0.kind == .quickStart &&
                    ($0.status == .failed || $0.status == .interrupted)
            }) == true
            return hasDurableRetryOwner ? nil : .retry(message: message)
        case .refreshFailed(let message):
            return .reload(message: message)
        case .persistenceBlocked(let runID, let message):
            let hasDurableRow = projectedListModel()?.rows.contains {
                $0.runID == runID
            } == true
            return hasDurableRow ? nil : .retryPersistence(runID: runID, message: message)
        case .idle, .starting, .generating, .awaitingUser:
            return nil
        }
    }

    private func projectedListModel() -> NovelSessionListModel? {
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot else { return nil }
        return viewModel.projectedListModel(
            project: project,
            branch: branch,
            expandedArchiveIDs: expandedArchiveIDs
        )
    }

    /// Sequenced open: bind+warm projection → tiny history → steady window → identity.
    /// Each step yields so SwiftUI can commit layout before the next cost spike.
    ///
    /// `bindingTaskID` also changes when a run starts/stops — do **not** tear the
    /// whole stage ladder down on those transitions (only on project/branch change,
    /// which `bindToCurrentSelection` already resets to `.idle` → `.coreTranscript`).
    @MainActor
    private func runStagedSessionOpen() async {
        let isFreshSessionOpen = viewModel.loadStage == .idle ||
            viewModel.binding?.projectID != workspace.selectedProjectID ||
            viewModel.binding?.branchID != workspace.selectedBranchID
        if isFreshSessionOpen {
            historyWindowLimit = NovelSessionHistoryWindowPolicy.coldOpenLimit
            expandedArchiveIDs.removeAll()
            streamedMessageIDs.removeAll()
        }

        await viewModel.bindToCurrentSelection(expandedArchiveIDs: expandedArchiveIDs)
        guard !Task.isCancelled else { return }
        // Failed bind stays .idle; wait for bindingTaskID to change when snapshot arrives.
        guard viewModel.binding != nil, viewModel.loadStage >= .coreTranscript else { return }

        if viewModel.loadStage < .steadyTranscript {
            await Task.yield()
            guard !Task.isCancelled else { return }
            // Expand window may insert rows above; pin first visible row when not
            // following bottom (bottom follow already absorbs growth).
            let anchorID = coldOpenHistoryAnchorID(listModel: projectedListModel())
            let pinHistoryAnchor = !isFollowingBottom && !isSettlingTerminal
            historyWindowLimit = NovelSessionHistoryWindowPolicy.limitAfterColdOpenSettles(
                currentLimit: historyWindowLimit
            )
            viewModel.advanceLoadStage(to: .steadyTranscript)
            if pinHistoryAnchor, let anchorID {
                await Task.yield()
                guard !Task.isCancelled else { return }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    scrollPosition.scrollTo(id: anchorID, anchor: .top)
                }
            }
        }

        // Climb remaining stages on every successful open task — covers cancel mid-ladder
        // when the task re-runs (same binding, stage still < secondary).
        if viewModel.loadStage < .secondaryChrome {
            await Task.yield()
            guard !Task.isCancelled else { return }
            viewModel.advanceLoadStage(to: .secondaryChrome)
        }
    }

    private var identityCardsSection: some View {
        NovelSessionIdentityCardsView(
            viewModel: viewModel,
            onAcceptSettingProposal: onAcceptSettingProposal
        )
    }

    private var bindingTaskID: String {
        let branchID = workspace.selectedBranchID
        // Flip nosnap→snap when load finishes so open re-runs after a failed early bind.
        // Do not key on revision — that would re-stage on every durable write.
        let hasSnapshot = workspace.projectSnapshot != nil && workspace.branchSnapshot != nil
        let phase: String
        if let running = workspace.projectSnapshot?.activeRuns.first(where: {
            $0.branchID == branchID && $0.status == .running
        }) {
            phase = "durable:\(running.id.description)"
        } else if let starting = workspace.quickStartStartingRun,
                  workspace.quickStartStartingProjectID == workspace.selectedProjectID,
                  starting.branchID == branchID {
            phase = "starting:\(starting.id.description)"
        } else {
            phase = "none"
        }
        return "\(workspace.selectedProjectID?.description ?? "none"):" +
            "\(branchID?.description ?? "none"):" +
            "\(hasSnapshot ? "snap" : "nosnap"):" +
            phase
    }

    private var currentCreationModelPolicy: NovelProjectModelPolicy {
        guard let project = workspace.projectSnapshot?.project else { return .global }
        let configured = project.configuredModelPolicy(for: .creation)
        if case .global = configured {
            return NovelCreationModelPreferences.shared.policy(for: .creation)
        }
        return configured
    }

    private var composerMetaValues: NovelSessionComposerMetaValues {
        _ = sharedSettings.revision
        let modelPolicy = currentCreationModelPolicy
        let modelLabel: String
        if workspace.projectSnapshot?.project == nil {
            modelLabel = IOSAppLocalization.string("选择模型", defaultValue: "选择模型")
        } else {
            modelLabel = NovelPresentation.modelDisplayName(
                for: modelPolicy,
                sharedSettings: sharedSettings
            )
        }
        let receipt = viewModel.latestContextReceipt
        let modelContext = NovelPresentation.creationModelContext(
            for: modelPolicy,
            sharedSettings: sharedSettings
        )
        let contextSnapshot = NovelSessionContextRing.snapshot(
            messageCount: viewModel.durableMessages.count,
            modelId: modelContext?.modelId ?? modelLabel,
            modelWindowTokens: modelContext?.contextWindowTokens,
            estimatedInjectionTokens: receipt?.estimatedInputTokens ?? 0,
            supportsReasoning: viewModel.transientTailChromeState.supportsReasoning
        )
        let needsSync = viewModel.needsSync
        let currentIntent = needsSync
            ? NovelComposerIntent.discuss
            : NovelComposerIntent(mode: viewModel.mode, granularity: viewModel.granularity)
        return NovelSessionComposerMetaValues(
            modelLabel: modelLabel,
            contextSnapshot: contextSnapshot,
            contextPanel: NovelInjectionPanelPresentation.project(receipt),
            currentIntent: currentIntent,
            needsSync: needsSync,
            hasArchivableDiscussion: viewModel.hasArchivableDiscussion,
            isBusy: viewModel.isBusy,
            controlsDisabled: viewModel.access != .readWrite ||
                workspace.requiresReload || viewModel.isRunning || viewModel.isBusy
        )
    }

    private var sendOnEnter: Bool {
        _ = sharedSettings.revision
        return sharedSettings.snapshot.displaySetting.sendOnEnter
    }

    private func sendEnabled(for text: String) -> Bool {
        NovelSessionComposerPolicy.canSubmit(canSend: viewModel.canSend, text: text)
    }

    private var askUserBlocker: NovelSessionActionBlocker? {
        NovelSessionComposerPolicy.askUserBlocker(
            access: viewModel.access,
            requiresReload: workspace.requiresReload || viewModel.hasRefreshError,
            isBusy: viewModel.isBusy || viewModel.isRunning
        )
    }

    private var inputPlaceholder: String {
        if viewModel.mode == .discussPlan {
            return IOSAppLocalization.string(
                "想聊哪段剧情、人物或设定？",
                defaultValue: "想聊哪段剧情、人物或设定？"
            )
        }
        if workspace.projectSnapshot?.project.collaborationMode == .ghostwrite,
           viewModel.granularity == .wholeChapter,
           let branchID = viewModel.binding?.branchID,
           workspace.projectSnapshot?.confirmedChapterPlan(for: branchID) == nil {
            return IOSAppLocalization.string(
                "代笔写整章前，请先在标题面板确认本章计划",
                defaultValue: "代笔写整章前，请先在标题面板确认本章计划"
            )
        }
        if viewModel.ghostwriteProgress?.shouldContinueSameBatch == true,
           viewModel.ghostwriteContinueBlockerMessage != nil {
            return viewModel.granularity == .wholeChapter
                ? IOSAppLocalization.string(
                    "描述下一章的目标或关键事件",
                    defaultValue: "描述下一章的目标或关键事件"
                )
                : IOSAppLocalization.string(
                    "描述接下来发生什么",
                    defaultValue: "描述接下来发生什么"
                )
        }
        if workspace.branchSnapshot?.currentState.hasStaleChapterPlots == true {
            return NovelWorkspaceLedger.unresolvedPlotGateMessage
        }
        if viewModel.needsSync {
            return IOSAppLocalization.string(
                "剧情还在同步，可以先讨论规划",
                defaultValue: "剧情还在同步，可以先讨论规划"
            )
        }
        return viewModel.granularity == .wholeChapter
            ? IOSAppLocalization.string(
                "描述下一章的目标或关键事件",
                defaultValue: "描述下一章的目标或关键事件"
            )
            : IOSAppLocalization.string(
                "描述接下来发生什么",
                defaultValue: "描述接下来发生什么"
            )
    }

    private var syncBannerText: String {
        if let pending = viewModel.retryableBranchPendingOperations.first {
            let failure = pending.lastError?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let failure, !failure.isEmpty {
                let reason = NovelPresentation.stateSyncFailureMessage(failure)
                if pending.kind == .manualSync {
                    return IOSAppLocalization.formatted(
                        "%@ 可继续讨论；写正文前请先重试同步。",
                        defaultValue: "%@ 可继续讨论；写正文前请先重试同步。",
                        arguments: [reason]
                    )
                }
                return reason
            }
            return pending.kind == .collection
                ? IOSAppLocalization.string(
                    "旧版收录的剧情状态同步未完成",
                    defaultValue: "旧版收录的剧情状态同步未完成"
                )
                : IOSAppLocalization.string(
                    "上次剧情同步未完成。可继续讨论；写正文前请先重试同步。",
                    defaultValue: "上次剧情同步未完成。可继续讨论；写正文前请先重试同步。"
                )
        }
        return IOSAppLocalization.string(
            "剧情状态同步尚未完成。可继续讨论；写正文前请先完成同步。",
            defaultValue: "剧情状态同步尚未完成。可继续讨论；写正文前请先完成同步。"
        )
    }

    private func send() {
        let committed = composerInputController.committedText() ?? inputText
        if committed != inputText {
            inputText = committed
        }
        guard sendEnabled(for: committed) else { return }
        guard !committed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let overrides = injectionOverrides
        let budget = inputBudgetTokens
        let draftOwner = workspace.selectedProjectID.flatMap { projectID in
            workspace.selectedBranchID.map {
                NovelComposerDraftOwner(projectID: projectID, branchID: $0)
            }
        }
        dismissKeyboard()
        // 气泡由 installTail 即时上屏；输入框同步清空，不等 durable start 落盘。
        // 启动失败时若用户尚未重新输入，则把原文放回，不静默丢稿。
        inputText = ""
        Task { @MainActor in
            let started = await viewModel.send(
                text: committed,
                injectionOverrides: overrides,
                inputBudgetTokens: budget
            )
            guard started else {
                if let draftOwner {
                    workspace.restoreComposerDraftAfterFailedSend(
                        NovelComposerDraft(
                            text: committed,
                            injectionOverrides: overrides,
                            inputBudgetTokens: budget
                        ),
                        owner: draftOwner
                    )
                }
                if workspace.selectedProjectID == draftOwner?.projectID,
                   workspace.selectedBranchID == draftOwner?.branchID,
                   inputText.isEmpty {
                    inputText = committed
                }
                return
            }
            injectionOverrides = .none
            inputBudgetTokens = 16_000
            if let draftOwner {
                workspace.saveComposerDraft(
                    .empty,
                    projectID: draftOwner.projectID,
                    branchID: draftOwner.branchID
                )
            }
        }
    }

    private func dismissKeyboard() {
        isInputFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private func stop() {
        Task { @MainActor in
            await viewModel.stop(reason: .user)
        }
    }

    private func handleRowAction(_ action: NovelSessionRowAction) {
        switch action {
        case .collectProse(let candidateID):
            onOpenCollection(candidateID)
        case .adoptPolish(let candidateID):
            Task { @MainActor in await viewModel.adoptPolishCandidate(candidateID) }
        case .retryGeneration(let runID):
            Task { @MainActor in _ = await viewModel.retryGeneration(runID: runID) }
        case .retryTerminalPersistence(let runID):
            guard viewModel.transientTail?.runID == runID else { return }
            Task { @MainActor in await viewModel.retryPendingTerminal() }
        case .retryPending(let pendingID):
            Task { @MainActor in await viewModel.retryPending(pendingID) }
        case .retryPolish(let transactionID):
            viewModel.startPolishRetry(transactionID)
        case .abandonPolish(let transactionID):
            Task { @MainActor in await viewModel.abandonPolishTransaction(transactionID) }
        case .convertPolishToManualRewrite(let candidateID, _):
            onOpenManualRewrite(candidateID)
        case .cloneCollectedProse(let candidateID):
            Task { @MainActor in
                guard let clonedID = await viewModel.cloneCollectedProse(candidateID) else { return }
                onOpenCollection(clonedID)
            }
        case .forkFromCheckpoint(let checkpointID):
            onFork(checkpointID)
        case .viewSettingProposals(let kind):
            onOpenSettingProposals(kind)
        case .undoCommittedChange(let checkpointID, let kind):
            pendingUndo = NovelPendingCommittedUndo(checkpointID: checkpointID, kind: kind)
        }
    }

    private func handleListSignalChange(
        from oldValue: NovelSessionListSignal,
        to newValue: NovelSessionListSignal
    ) {
        novelLoopLog.info("TEMP-DIAG signal tail=\(oldValue.activeTailID?.description.prefix(8) ?? "-", privacy: .public)->\(newValue.activeTailID?.description.prefix(8) ?? "-", privacy: .public) rows=\(oldValue.rowCount)->\(newValue.rowCount)") // TEMP-DIAG
        guard oldValue.sessionID == newValue.sessionID else {
            releaseSuspendedStreamingTail(resetIdentity: true)
            historyWindowLimit = NovelSessionHistoryWindowPolicy.coldOpenLimit
            expandedArchiveIDs.removeAll()
            streamedMessageIDs.removeAll()
            if isNativeScrollDriverActive {
                scrollDriver.submit(.conversationReset)
            }
            dispatchFollowEvent(.reset)
            dispatchFollowEvent(.initialRowsPresented(hasRows: newValue.rowCount > 0))
            return
        }
        if let activeTailID = newValue.activeTailID {
            if !streamedMessageIDs.contains(activeTailID.description) {
                streamedMessageIDs.insert(activeTailID.description)
            }
            if streamingTailVisibility.messageID != activeTailID.description {
                streamingTailVisibility = ChatSwiftUIStreamingTailVisibilityState(
                    messageID: activeTailID.description,
                    isVisible: nil
                )
                suspendedStreamingTailRow = nil
            }
        } else if oldValue.activeTailID != nil {
            // Keep an off-screen snapshot deferred across retirement. Its sticky
            // visibility identity releases it when the user scrolls to the row;
            // rows that were already live can drop the tracking identity now.
            if suspendedStreamingTailRow == nil {
                releaseSuspendedStreamingTail(resetIdentity: true)
            }
        }
        // 无条件吸收:贴底与否不改变「已渲染的行不得中途被窗口踢出」这条不变量。
        // 口径必须与 `startIndex` 一致——那里用的是 **historicalRows**。若用含活动
        // run 的 rowCount,run 开始时活动行会被算进吸收量,startIndex 反而净下降
        // (每轮 −activeRunRowCount),等于在视口上方插入旧历史。
        // 刚完成的 run 钉在活动栈,退役不增加 historical 行数;下一轮开始时旧
        // 钉住行才进入 historical,由这里的增量吸收,不要再叠一层
        // `limitAfterActiveRunReturnsToHistory`(会把同一批行算两次)。
        let nextHistoryWindowLimit = NovelSessionHistoryWindowPolicy.limitAfterRowsAppended(
            currentLimit: historyWindowLimit,
            previousRowCount: oldValue.rowCount - oldValue.activeRunRowCount,
            currentRowCount: newValue.rowCount - newValue.activeRunRowCount
        )
        if nextHistoryWindowLimit != historyWindowLimit {
            historyWindowLimit = nextHistoryWindowLimit
        }
        if oldValue.activeTailID == nil, newValue.activeTailID != nil {
            dispatchFollowEvent(.streamStarted)
        } else if oldValue.activeTailID == newValue.activeTailID,
                  newValue.activeTailID != nil,
                  oldValue.activeTailDigest != newValue.activeTailDigest {
            if isLiveTailPhase(oldValue.activeTailPhase),
               !isLiveTailPhase(newValue.activeTailPhase) {
                dispatchFollowEvent(.terminalReached)
            } else if isLiveTailPhase(newValue.activeTailPhase) {
                dispatchFollowEvent(.streamDelta)
            } else {
                dispatchFollowEvent(.terminalLayoutChanged)
            }
        } else if oldValue.activeTailID != nil, newValue.activeTailID == nil {
            dispatchFollowEvent(.terminalReached)
        } else if oldValue.rowCount != newValue.rowCount || oldValue.lastRowDigest != newValue.lastRowDigest {
            dispatchFollowEvent(.terminalLayoutChanged)
        }
    }

    private func presentInitialRowsIfNeeded(_ signal: NovelSessionListSignal) {
        guard signal.sessionID != nil,
              followState.mode == .awaitingInitialRows else { return }
        dispatchFollowEvent(.initialRowsPresented(hasRows: signal.rowCount > 0))
    }

    private func isLiveTailPhase(_ phase: NovelSessionTransientTailPhase?) -> Bool {
        phase == .waitingForFirstToken || phase == .streaming
    }

    private func revealEarlierHistory(
        totalCount: Int,
        preserving anchorID: NovelMessageID?
    ) {
        if isNativeScrollDriverActive {
            scrollDriver.submit(.userDragBegan)
        }
        dispatchFollowEvent(.userDragBegan(isAtBottom: false))
        historyWindowLimit = NovelSessionHistoryWindowPolicy.expandedLimit(
            currentLimit: historyWindowLimit,
            totalCount: totalCount
        )
        guard let anchorID else { return }
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                scrollPosition.scrollTo(id: anchorID, anchor: .top)
            }
        }
    }

    private func toggleArchive(_ archive: NovelDiscussionArchivePresentation) {
        if expandedArchiveIDs.contains(archive.id) {
            expandedArchiveIDs.remove(archive.id)
        } else {
            historyWindowLimit = NovelSessionHistoryWindowPolicy.limitAfterArchiveExpansion(
                currentLimit: historyWindowLimit,
                revealedRowCount: archive.revealedRowCount
            )
            expandedArchiveIDs.insert(archive.id)
        }
    }

    private func dispatchFollowEvent(_ event: NovelSessionBottomFollowEvent) {
        novelLoopLog.info("TEMP-DIAG follow event=\(String(describing: event), privacy: .public) mode=\(String(describing: followState.mode), privacy: .public)") // TEMP-DIAG
        switch event {
        case .reset, .userDragBegan:
            cancelExplicitBottomAnimation()
        default:
            break
        }
        let transition = NovelSessionBottomFollowPolicy.reduce(
            state: followState,
            event: event,
            followEnabled: followGeneration
        )
        if followState != transition.state {
            followState = transition.state
        }
        for command in transition.commands {
            executeFollowCommand(command)
        }
    }

    private func executeFollowCommand(_ command: NovelSessionBottomFollowCommand) {
        switch command {
        case .anchorBottom:
            if isNativeScrollDriverActive {
                scrollDriver.submit(
                    .explicitBottom(source: .button, animated: false, keyboardToken: nil)
                )
                return
            }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                scrollPosition.scrollTo(id: Self.bottomAnchorID, anchor: .bottom)
            }
        case .followBottom(let animated):
            if isNativeScrollDriverActive {
                if animated {
                    // 底部按钮回底：带动画的显式锚定。
                    scrollDriver.submit(
                        .explicitBottom(
                            source: .button,
                            animated: !accessibilityReduceMotion,
                            keyboardToken: nil
                        )
                    )
                } else {
                    // 流式增长：提交 streamContentGrew 让 driver 走 followingBottom
                    // + frame driver 连续追底（与 Chat 同构）。旧实现用一次性
                    // explicitBottom(.streamGrowth) snap，回调间隔内的增长欠账
                    // 无人追 → 滑不到底。streamContentGrew 在用户交互时由 driver
                    // 自动 paused，无需视图层守卫。终态排空期间携带 lagAllowance
                    //（随剩余积压连续衰减）：driver 收紧跟随时间常数，最后一拍
                    // 前视口已贴回底部，完成瞬间的钉底零跳变（与 Chat 同源）。
                    scrollDriver.submit(.streamContentGrew(
                        lagAllowance: viewModel.latestTailLagAllowance
                    ))
                }
                return
            }
            if animated {
                startExplicitBottomAnimation()
            } else if explicitBottomAnimationTask != nil {
                explicitBottomFollowPending = true
            } else {
                performLiveBottomFollow()
            }
        case .terminateGeneration:
            if isNativeScrollDriverActive {
                // 与 Chat 终态同构：driver 逐帧钉底 + 静默交还 + idle 近底重锚。
                scrollDriver.submit(.generationTerminated)
            } else {
                // driver 未激活（fallback 模式）：退回 followBottom snap。
                performLiveBottomFollow()
            }
        case .setBottomButton:
            break
        case .scheduleTerminalQuietSettle(let token, let delay):
            // Native driver 只收口 UIKit 滚动状态；这枚 token 定时器负责让
            // SwiftUI followState 退出 settlingTerminal，两个状态都必须闭环。
            terminalSettleTask?.cancel()
            terminalSettleTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                dispatchFollowEvent(.terminalQuietElapsed(token: token))
            }
        }
    }

    private func startExplicitBottomAnimation() {
        cancelExplicitBottomAnimation()
        guard !accessibilityReduceMotion else {
            scrollToBottomWithoutAnimation()
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            scrollPosition.scrollTo(id: Self.bottomAnchorID, anchor: .bottom)
        }
        explicitBottomAnimationTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(0.2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let shouldReplay = explicitBottomFollowPending &&
                followGeneration &&
                !userDragging
            explicitBottomFollowPending = false
            explicitBottomAnimationTask = nil
            if shouldReplay {
                performLiveBottomFollow()
            }
        }
    }

    private func cancelExplicitBottomAnimation() {
        explicitBottomFollowPending = false
        explicitBottomAnimationTask?.cancel()
        explicitBottomAnimationTask = nil
    }

    private func performLiveBottomFollow() {
        if isNativeScrollDriverActive {
            guard !userDragging, !scrollDriver.isUIKitUserInteracting else { return }
            scrollDriver.submit(
                .explicitBottom(source: .streamGrowth, animated: false, keyboardToken: nil)
            )
            return
        }
        scrollToBottomWithoutAnimation()
    }

    private func scrollToBottomWithoutAnimation() {
        if isNativeScrollDriverActive {
            scrollDriver.submit(
                .explicitBottom(source: .button, animated: false, keyboardToken: nil)
            )
            return
        }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            scrollPosition.scrollTo(id: Self.bottomAnchorID, anchor: .bottom)
        }
    }

    private var isNativeScrollDriverDesired: Bool {
        nativeScrollFallbackReason == nil &&
            isNativeScrollSurfaceVisible
    }

    private var isNativeScrollDriverActive: Bool {
        isNativeScrollDriverDesired && scrollDriver.isAttached
    }

    private func handleNativeScrollViewResolved(_ scrollView: UIScrollView) {
        guard isNativeScrollDriverDesired else { return }
        scrollDriver.setAutomaticFollowEnabled(followGeneration)
        scrollDriver.onFallback = { reason, shouldReplayBottom in
            guard nativeScrollFallbackReason == nil else { return }
            nativeScrollFallbackReason = reason
            guard shouldReplayBottom, !userDragging else { return }
            scrollToBottomWithoutAnimation()
        }
        let didAttach = scrollDriver.attach(scrollView)
        guard didAttach, scrollDriver.isAttached else { return }
        if userDragging || isBrowsingHistory {
            scrollDriver.submit(.userDragBegan)
        } else {
            scrollDriver.submit(
                .explicitBottom(source: .button, animated: false, keyboardToken: nil)
            )
        }
    }

    private var isBrowsingHistory: Bool {
        if case .browsingHistory = followState.mode {
            return true
        }
        return false
    }

    private var isFollowingBottom: Bool {
        if case .followingBottom = followState.mode {
            return true
        }
        return false
    }

    private var isSettlingTerminal: Bool {
        if case .settlingTerminal = followState.mode {
            return true
        }
        return false
    }

    private static let bottomAnchorID = "novel-session-bottom-anchor"

    private func updateStreamingTailVisibility(
        row: NovelSessionRowModel,
        isVisible: Bool,
        activeTailID: NovelMessageID?
    ) {
        let messageID = row.id.description
        // 单槽只认当前所有者：分支翻转引起的 onDisappear 误报与旧行上报不得抢占，
        // 否则两行交替写入会把整页拖进自激重算循环。
        guard NovelSessionStreamingTailVisibilityOwnership.accepts(
            reportingMessageID: messageID,
            activeTailMessageID: activeTailID?.description,
            trackedMessageID: streamingTailVisibility.messageID
        ) else { return }
        novelLoopLog.info("TEMP-DIAG vis row=\(messageID.prefix(8), privacy: .public) visible=\(isVisible) follow=\(String(describing: followState.mode), privacy: .public) suspended=\(suspendedStreamingTailRow != nil) prevID=\(streamingTailVisibility.messageID?.prefix(8) ?? "-", privacy: .public) prevVis=\(String(describing: streamingTailVisibility.isVisible), privacy: .public)") // TEMP-DIAG
        // Tall bubbles / onDisappear during identity churn report off-screen while
        // the user is still watching the bottom. Do not freeze in those cases.
        let treatAsVisible = isVisible || isFollowingBottom
        streamingTailVisibility = ChatSwiftUIStreamingTailVisibilityState(
            messageID: messageID,
            isVisible: treatAsVisible
        )
        if treatAsVisible {
            suspendedStreamingTailRow = nil
        } else if suspendedStreamingTailRow?.id != row.id {
            suspendedStreamingTailRow = row
        }
    }

    /// 视图正为不可见的流式尾部显示冻结快照：此时 VM 的逐拍发布不会带来可见变化。
    private var holdsFrozenStreamingTail: Bool {
        guard !isFollowingBottom,
              let messageID = streamingTailVisibility.messageID,
              streamingTailVisibility.isVisible == false,
              suspendedStreamingTailRow?.id.description == messageID else { return false }
        return true
    }

    private func releaseSuspendedStreamingTail(resetIdentity: Bool = false) {
        novelLoopLog.info("TEMP-DIAG release reset=\(resetIdentity)") // TEMP-DIAG
        suspendedStreamingTailRow = nil
        if resetIdentity {
            streamingTailVisibility = ChatSwiftUIStreamingTailVisibilityState()
        } else if let messageID = streamingTailVisibility.messageID {
            streamingTailVisibility = ChatSwiftUIStreamingTailVisibilityState(
                messageID: messageID,
                isVisible: nil
            )
        }
    }

    /// 文案必须区分「重写」与「续写/整章」:重新生成的候选默认收录方式是
    /// **替换原章**,若沿用整章文案会显示「收录后成为新章」,与实际行为相反。
    private var generationStatusText: String {
        // Same owner copy as bubble terminal chrome — do not invent a second story.
        if viewModel.isStopping {
            return IOSAppLocalization.string("正在停止…", defaultValue: "正在停止…")
        }
        if viewModel.isTerminalPresenting {
            return IOSAppLocalization.string("正在保存创作记录", defaultValue: "正在保存创作记录")
        }
        guard let kind = viewModel.activeRunKind else {
            return IOSAppLocalization.string("正在生成", defaultValue: "正在生成")
        }
        if kind == .regenerate {
            return IOSAppLocalization.string(
                "重写本章 · 收录后替换原文",
                defaultValue: "重写本章 · 收录后替换原文"
            )
        }
        if kind == .polish {
            return IOSAppLocalization.string(
                "正在润色本章 · 完成后检查剧情一致性",
                defaultValue: "正在润色本章 · 完成后检查剧情一致性"
            )
        }
        return viewModel.activeRunGranularity == .wholeChapter
            ? IOSAppLocalization.string(
                "完整章节 · 收录后成为新章",
                defaultValue: "完整章节 · 收录后成为新章"
            )
            : IOSAppLocalization.string(
                "正文片段 · 收录后进入本章",
                defaultValue: "正文片段 · 收录后进入本章"
            )
    }

    private var generationStatusIcon: String {
        if viewModel.isStopping { return "arrow.triangle.2.circlepath" }
        if viewModel.isTerminalPresenting {
            return "arrow.triangle.2.circlepath"
        }
        switch viewModel.activeRunKind {
        case .regenerate: return "arrow.triangle.2.circlepath"
        case .polish: return "wand.and.sparkles"
        default: return "doc.text"
        }
    }

    /// 生成中的候选状态条。原本挂在气泡里正文的正下方,正文每增长一次它就被
    /// 重新布局并被跟随逻辑推动,肉眼就是小幅上下抖动;移到输入框上方后它的
    /// 位置与正文增长解耦。只在生成中 / 终态呈现窗口出现。
    private var generationStatusStrip: some View {
        // 粒度必须取**活动 run 的记录值**,不能取 composer 的当前设置:
        // `start(_:)` 不回写 viewModel.granularity,重试一个失败的续写 run 时
        // composer 可能已被改成「整章」,导致提示与实际收录目标相反。
        Label(generationStatusText, systemImage: generationStatusIcon)
        .font(.caption)
        .foregroundStyle(AmberTheme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Match composer dock horizontal inset (16), not transcript content (22).
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    /// First visible historical row under the current cold-open window (for pin-on-expand).
    private func coldOpenHistoryAnchorID(listModel: NovelSessionListModel?) -> NovelMessageID? {
        guard let historicalRows = listModel?.historicalRows, !historicalRows.isEmpty else {
            return nil
        }
        let startIndex = NovelSessionHistoryWindowPolicy.startIndex(
            totalCount: historicalRows.count,
            limit: historyWindowLimit
        )
        return historicalRows.dropFirst(startIndex).first?.id
    }
}
