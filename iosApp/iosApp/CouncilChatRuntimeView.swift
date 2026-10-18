import SwiftUI
import Observation
import PhotosUI
import SwiftStreamingMarkdown
import UIKit
import UniformTypeIdentifiers
@preconcurrency import Shared

struct CouncilTranscriptScrollGeometry: Equatable {
    let contentHeight: CGFloat
    let visibleHeight: CGFloat
    let isNearBottom: Bool
    let isAtBottom: Bool
}

enum CouncilTranscriptFollowPolicy {
    static let bottomAnchorID = "council-transcript-bottom-anchor"
    static let liveGrowthAnimationDuration = 0.08
    private static let minimumMeasuredGrowth: CGFloat = 0.5

    static func shouldResumeFollowing(distanceToBottom: CGFloat) -> Bool {
        distanceToBottom <= ChatLayout.nearBottomResumeThreshold
    }

    /// Council is bounded and serial: only one row speaks at a time. `followPaused`
    /// owns scrolling only and does not prove that row is outside the viewport, so
    /// it must not freeze visible Markdown or force a later catch-up replacement.
    static let liveRenderingEnabled = true

    static func shouldFollowMeasuredGrowth(
        previousContentHeight: CGFloat,
        currentContentHeight: CGFloat,
        followEnabled: Bool,
        followPaused: Bool,
        userDragging: Bool,
        alreadyAtBottom: Bool
    ) -> Bool {
        followEnabled &&
            !followPaused &&
            !userDragging &&
            !alreadyAtBottom &&
            currentContentHeight > previousContentHeight + minimumMeasuredGrowth
    }

    static func shouldFollowViewportShrink(
        previousVisibleHeight: CGFloat,
        currentVisibleHeight: CGFloat,
        followEnabled: Bool,
        followPaused: Bool,
        userDragging: Bool,
        alreadyAtBottom: Bool
    ) -> Bool {
        followEnabled &&
            !followPaused &&
            !userDragging &&
            !alreadyAtBottom &&
            currentVisibleHeight < previousVisibleHeight - minimumMeasuredGrowth
    }
}

private struct CouncilModeCapsuleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Match ChatToolbarIconButton: a light glass pad + Liquid Glass.
            // Full AmberTheme.glass (warm paper @ ~72%) reads as a yellow blob
            // on cream transcript; opacity 0.16 keeps the chip neutral/opaque.
            content
                .background(AmberTheme.glass.opacity(0.16), in: Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Keeps the mode capsule centered until the right-side controls need its space.
private struct CouncilHeaderLayout: Layout {
    private let controlGap: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(
            width: proposal.width ?? sizes.reduce(0) { $0 + $1.width } + controlGap * 2,
            height: sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let left = sizes[0]
        let capsule = sizes[1]
        let right = sizes[2]
        let earliestCenter = bounds.minX + left.width + controlGap + capsule.width / 2
        let latestCenter = bounds.maxX - right.width - controlGap - capsule.width / 2
        let capsuleCenter = min(max(bounds.midX, earliestCenter), latestCenter)

        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: capsuleCenter, y: bounds.maxY), anchor: .bottom, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.maxY), anchor: .bottomTrailing, proposal: .unspecified)
    }
}

struct CouncilChatRuntimeView: View {
    let settingsStore: SettingsStore
    let sharedSettings: IOSSharedSettingsStore
    let providerRegistry: ProviderRegistryStore?
    let permissionStore: IOSPermissionStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: CouncilChatViewModel
    @FocusState private var isComposerFocused: Bool
    // 底部跟随状态(与 Chat 页同款):`userDragging` 只在用户「主动拖动」时为真,
    // `followPaused` 也只在用户拖离底部时才置真——内容增长(流式/阶段衔接)导致的几何变化
    // 不会误暂停跟随。跟随本身遵循全局「跟随生成」偏好,与聊天页一致。
    @State private var userDragging = false
    @State private var followPaused = false
    @State private var transcriptNearBottom = true
    @State private var scrollPosition = ScrollPosition()
    @State private var measuredGrowthFollowTask: Task<Void, Never>?
    @State private var measuredGrowthFollowPending = false
    @State private var terminalSettleTask: Task<Void, Never>?
    @State private var scrollDriver = NativeTimelineScrollDriver()
    @State private var nativeScrollFallbackReason: NativeTimelineScrollFallbackReason?
    @State private var isNativeScrollSurfaceVisible = false
    @AppStorage(IOSDisplayPreferenceKeys.followGeneration) private var followGeneration = true
    @State private var isAttachExpanded = false
    @State private var isImportingSelectedFile = false
    @State private var isPhotoPickerPresented = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var photoPickerRoomGeneration: UInt64?
    @State private var isCameraPresented = false
    @State private var cameraRoomGeneration: UInt64?
    @State private var imageAttachmentTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore,
        sharedSettings: IOSSharedSettingsStore,
        providerRegistry: ProviderRegistryStore? = nil,
        permissionStore: IOSPermissionStore = IOSPermissionStore(),
        viewModel: CouncilChatViewModel? = nil
    ) {
        self.settingsStore = settingsStore
        self.sharedSettings = sharedSettings
        self.providerRegistry = providerRegistry
        self.permissionStore = permissionStore
        self._viewModel = State(initialValue: viewModel ?? CouncilChatViewModel(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            providerRegistry: providerRegistry,
            permissionStore: permissionStore
        ))
    }

    var body: some View {
        ZStack {
            AmberThemePageBackground(surface: .app)

            transcript

            if let archiveErrorMessage = viewModel.archiveErrorMessage {
                VStack(spacing: 0) {
                    Label(archiveErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(AmberTheme.surface)
                    Spacer()
                }
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                header
                // 透明延伸只扩大 safeAreaBar 几何，不画自定义材质；模糊走原生 soft edge。
                Color.clear
                    .frame(height: ChatTopBarLayout.softEdgeExtension)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            isNativeScrollSurfaceVisible = true
            // 重新进入页面时清除上一次的 fallback 粘连，给原生滚动 driver 一次重试机会；
            // 开关移除后已无手动恢复入口，否则一次 fallback 会让 driver 对该视图实例永久禁用。
            nativeScrollFallbackReason = nil
        }
        // 离开页面(返回/切走)时立即存一份当前 transcript,避免运行中退出导致刚流式出的内容
        // 在下次进入前丢失(运行任务仍会在后台跑完并再存一次,以更完整的为准)。
        .onDisappear {
            isNativeScrollSurfaceVisible = false
            cancelPendingMeasuredGrowthFollow()
            terminalSettleTask?.cancel()
            scrollDriver.invalidate()
            viewModel.runtimeDidDisappear()
            viewModel.persistTranscript()
        }
        .onChange(of: followGeneration) { _, enabled in
            scrollDriver.setAutomaticFollowEnabled(enabled)
        }
        .onChange(of: viewModel.isRunning) { _, running in
            if running {
                withAnimation(.easeOut(duration: 0.2)) { isAttachExpanded = false }
            }
        }
        .onChange(of: viewModel.isPreparingMaterials) { _, preparing in
            if preparing {
                withAnimation(.easeOut(duration: 0.2)) { isAttachExpanded = false }
            }
        }
        .onChange(of: viewModel.isReplay) { _, replay in
            if replay {
                withAnimation(.easeOut(duration: 0.2)) { isAttachExpanded = false }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .fileImporter(
            isPresented: $isImportingSelectedFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleSelectedFileImport(result)
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $photoPickerItems,
            maxSelectionCount: CouncilMaterialLimits.maxImages,
            matching: .images
        )
        .onChange(of: photoPickerItems) { _, items in
            handlePhotoPickerSelection(items)
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker { image in
                if let image, let generation = cameraRoomGeneration {
                    attachPickedImage(image, roomGeneration: generation)
                }
                cameraRoomGeneration = nil
                isCameraPresented = false
            }
            .ignoresSafeArea()
        }
        .sheet(item: $viewModel.activeSheet) { sheet in
            switch sheet {
            case .detail(let detail):
                CouncilDiscussionDetailSheet(detail: detail)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .members:
                CouncilMembersSheet(
                    selectedMode: Binding(
                        get: { viewModel.selectedMode },
                        set: { viewModel.selectedMode = $0 }
                    ),
                    participants: viewModel.participants,
                    currentModelId: viewModel.currentModelId,
                    stateProvider: { viewModel.state(for: $0) },
                    failedSpeakerIds: viewModel.failedSpeakerIds,
                    isRunning: viewModel.isRunning,
                    dynamicSeatGeneration: viewModel.roomSettingsStore.dynamicSeatGeneration,
                    restartAction: { viewModel.startFreshRoom() }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                // 固定 sheet 底色,避免拉伸到不同高度时系统在不同材质/灰阶间切换导致整体变色。
                .presentationBackground(AmberTheme.background)
            case .settings:
                CouncilRoomSettingsSheet(
                    roomSettingsStore: viewModel.roomSettingsStore,
                    sharedSettings: sharedSettings,
                    availableModelIds: viewModel.availableModelIds,
                    currentModelId: viewModel.currentModelId,
                    isReadOnly: viewModel.isRunning
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            case .history:
                CouncilHistorySheet(
                    tasks: IOSAdvancedTaskStore.shared.recent(kind: .modelCouncil, limit: 30)
                        .filter { CouncilRoomArchiveStore.shared.exists(taskId: $0.id) },
                    activeTaskId: viewModel.activeReplayTaskId,
                    onSelect: { taskId in viewModel.openArchive(taskId: taskId) }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AmberTheme.background)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        CouncilHeaderLayout {
            ChatToolbarIconButton(
                systemImage: "chevron.left",
                accessibilityLabel: IOSAppLocalization.string("返回", defaultValue: "返回"),
                size: ChatTopBarLayout.toolbarButtonDiameter,
                symbolSize: 18
            ) {
                dismiss()
            }

            modeCapsuleButton

            HStack(spacing: 12) {
                ChatToolbarIconButton(
                    systemImage: "clock.arrow.circlepath",
                    accessibilityLabel: IOSAppLocalization.string("历史议会", defaultValue: "历史议会"),
                    size: ChatTopBarLayout.toolbarButtonDiameter,
                    symbolSize: 16
                ) {
                    viewModel.showHistory()
                }
                .disabled(viewModel.isRunning)
                .accessibilityHint(viewModel.isRunning
                    ? IOSAppLocalization.string(
                        "讨论结束后可查看历史议会",
                        defaultValue: "讨论结束后可查看历史议会"
                    )
                    : "")

                ChatToolbarIconButton(
                    systemImage: "gearshape",
                    accessibilityLabel: IOSAppLocalization.string("议会设置", defaultValue: "议会设置"),
                    size: ChatTopBarLayout.toolbarButtonDiameter,
                    symbolSize: 16
                ) {
                    viewModel.showSettings()
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: ChatTopBarLayout.controlsHeight, alignment: .bottom)
    }

    private var modeCapsuleButton: some View {
        Button {
            viewModel.showMembers()
        } label: {
            // Hug on the label before glass so the capsule keeps its measured width.
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Text(viewModel.selectedMode.localizedTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted)
                }
                Text(IOSAppLocalization.formatted(
                    "%lld 位成员 · 第 %lld 轮",
                    defaultValue: "%lld 位成员 · 第 %lld 轮",
                    arguments: [
                        Int64(viewModel.participants.count),
                        Int64(viewModel.discussionRound)
                    ]
                ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .fixedSize(horizontal: true, vertical: false)
            .modifier(CouncilModeCapsuleGlass())
            .contentShape(Capsule())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.96, haptic: .lightImpact))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(IOSAppLocalization.formatted(
            "%@，%lld 位成员，第 %lld 轮",
            defaultValue: "%@，%lld 位成员，第 %lld 轮",
            arguments: [
                viewModel.selectedMode.localizedAccessibilityLabel,
                Int64(viewModel.participants.count),
                Int64(viewModel.discussionRound)
            ]
        ))
    }

    private var transcript: some View {
        ScrollView {
            CouncilTranscriptMessagesView(viewModel: viewModel) {
                // 新房间/历史重放不继承上一房间的“用户暂停跟随”状态。
                followPaused = false
                if isNativeScrollDriverActive {
                    scrollDriver.submit(.conversationReset)
                }
                scheduleTerminalBottomSettle(terminalRun: false)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, minHeight: 0)
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
        .modifier(CouncilSizeChangesPinModifier(
            enabled: followGeneration && !isNativeScrollDriverDesired
        ))
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollIndicators(.hidden)
        // 区分「用户主动拖动」与「程序/内容增长引起的滚动」:只有前者才允许改 followPaused。
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting:
                userDragging = true
                if isNativeScrollDriverActive {
                    scrollDriver.submit(.userDragBegan)
                }
                cancelPendingMeasuredGrowthFollow()
                terminalSettleTask?.cancel()
            case .idle:
                let endedUserDrag = userDragging
                userDragging = false
                if endedUserDrag {
                    let returnedToBottom = NativeTimelineScrollReturnPolicy.returnedToBottom(
                        liveDistanceToBottom: isNativeScrollDriverActive
                            ? scrollDriver.distanceToBottomNow()
                            : nil,
                        cachedNearBottom: transcriptNearBottom,
                        threshold: ChatLayout.nearBottomResumeThreshold
                    )
                    followPaused = !returnedToBottom
                    if isNativeScrollDriverActive {
                        scrollDriver.submit(.userDragEnded(isAtBottom: returnedToBottom))
                    }
                    if returnedToBottom, followGeneration {
                        scheduleMeasuredGrowthFollowToBottom()
                    }
                }
            case .animating, .decelerating:
                break
            @unknown default:
                break
            }
        }
        // 跟随真实内容高度而非 body 信号。流式 Markdown 会异步发布 renderable,
        // 其二次自撑高度没有新的文本回调；正向高度变化是唯一可靠的布局完成证据。
        .onScrollGeometryChange(for: CouncilTranscriptScrollGeometry.self) { geometry in
            let distanceToBottom = geometry.contentSize.height - geometry.visibleRect.maxY
            return CouncilTranscriptScrollGeometry(
                contentHeight: geometry.contentSize.height,
                visibleHeight: geometry.visibleRect.height,
                isNearBottom: CouncilTranscriptFollowPolicy.shouldResumeFollowing(
                    distanceToBottom: distanceToBottom
                ),
                isAtBottom: distanceToBottom <= 1
            )
        } action: { previous, current in
            transcriptNearBottom = current.isNearBottom
            if userDragging {
                followPaused = !current.isNearBottom
            }
            let shouldFollowMeasuredGrowth = CouncilTranscriptFollowPolicy.shouldFollowMeasuredGrowth(
                previousContentHeight: previous.contentHeight,
                currentContentHeight: current.contentHeight,
                followEnabled: followGeneration,
                followPaused: followPaused,
                userDragging: userDragging,
                alreadyAtBottom: current.isAtBottom
            )
            let shouldFollowViewportShrink = CouncilTranscriptFollowPolicy.shouldFollowViewportShrink(
                previousVisibleHeight: previous.visibleHeight,
                currentVisibleHeight: current.visibleHeight,
                followEnabled: followGeneration,
                followPaused: followPaused,
                userDragging: userDragging,
                alreadyAtBottom: current.isAtBottom
            )
            // sizeChanges pin owns live height growth alone. A residual scrollTo
            // snap fights the pin and produces continuous jump/flicker — same
            // anti-pattern as dual 0.08s chase. Viewport shrink / native driver
            // still need an explicit write.
            //
            // 实测增长分支：driver 未激活时由 sizeChanges pin 独占增长跟随
            // （pin 开启 = followGeneration && !isNativeScrollDriverDesired，与
            // 下方条件互补），不在此再发第二条 scrollTo 命令。旧条件
            // `!pinOwns || driverActive` 在 shouldFollowMeasuredGrowth（隐含
            // followGeneration）下恒等于 `isNativeScrollDriverDesired`——
            // 冗余分支已删，行为不变。
            if shouldFollowViewportShrink {
                scheduleMeasuredGrowthFollowToBottom()
            } else if shouldFollowMeasuredGrowth, isNativeScrollDriverDesired {
                scheduleMeasuredGrowthFollowToBottom()
            }
        }
        .onChange(of: viewModel.isRunning) { wasRunning, isRunning in
            if wasRunning, !isRunning {
                scheduleTerminalBottomSettle()
            }
        }
    }

    private func scheduleMeasuredGrowthFollowToBottom() {
        guard followGeneration, !followPaused, !userDragging else { return }
        if isNativeScrollDriverActive {
            // 跟随拍携带当前 lagAllowance：流式期为 1，终态排空期随剩余积压
            // 连续衰减（1→0），driver 据此收紧 τ_eff——完成瞬间钉底不再需要
            // 一次性清掉跟随滞后。排空期即使是被动/几何恢复提交也必须携带
            // 收紧值，否则默认 1 会把同拍先发的收紧逐拍打回（与 Chat/小说
            // 语义一致，Novel 侧同类 bug 已修）。
            scrollDriver.submit(.streamContentGrew(lagAllowance: viewModel.activeTailLagAllowance))
            return
        }
        // A 48ms text presentation flush can be followed by multiple asynchronous
        // Markdown height publications. Keep ownership for the full 80ms animation
        // so later geometry callbacks cannot restart it mid-flight.
        guard measuredGrowthFollowTask == nil else {
            measuredGrowthFollowPending = true
            return
        }
        measuredGrowthFollowPending = false
        measuredGrowthFollowTask = Task { @MainActor in
            defer {
                let shouldReplay = measuredGrowthFollowPending &&
                    followGeneration &&
                    !followPaused &&
                    !userDragging
                measuredGrowthFollowPending = false
                measuredGrowthFollowTask = nil
                if shouldReplay {
                    scheduleMeasuredGrowthFollowToBottom()
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  followGeneration,
                  !followPaused,
                  !userDragging else { return }
            guard !reduceMotion else {
                scrollToTranscriptBottom()
                return
            }
            withAnimation(.linear(duration: CouncilTranscriptFollowPolicy.liveGrowthAnimationDuration)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        CouncilTranscriptFollowPolicy.liveGrowthAnimationDuration * 1_000_000_000
                    )
                )
            } catch {
                return
            }
        }
    }

    private func cancelPendingMeasuredGrowthFollow() {
        measuredGrowthFollowPending = false
        measuredGrowthFollowTask?.cancel()
    }

    /// `terminalRun`：整轮结束（isRunning 翻转）走 driver 的 `.generationTerminated`
    /// （与 Chat/小说终态同构：逐帧钉底 + 静默交还 + idle 近底重锚）；新房间/历史
    /// 重放保持显式无动画锚底（Chat 的 conversationLoaded 同款语义）。
    private func scheduleTerminalBottomSettle(terminalRun: Bool = true) {
        cancelPendingMeasuredGrowthFollow()
        terminalSettleTask?.cancel()
        terminalSettleTask = Task { @MainActor in
            // Give the 96pt→26pt sentinel change and the terminal Markdown parse a
            // layout turn before the exact, non-animated bottom settle.
            await Task.yield()
            guard !Task.isCancelled,
                  followGeneration,
                  !followPaused,
                  !userDragging else { return }
            if isNativeScrollDriverActive {
                if terminalRun {
                    scrollDriver.submit(.generationTerminated)
                } else {
                    scrollDriver.submit(
                        .explicitBottom(source: .streamGrowth, animated: false, keyboardToken: nil)
                    )
                }
                return
            }
            scrollToTranscriptBottom()
        }
    }

    private func scrollToTranscriptBottom() {
        if isNativeScrollDriverActive {
            scrollDriver.submit(
                .explicitBottom(source: .streamGrowth, animated: false, keyboardToken: nil)
            )
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        transaction.animation = nil
        withTransaction(transaction) {
            scrollPosition.scrollTo(edge: .bottom)
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
        scrollView.topEdgeEffect.style = .soft
        scrollDriver.setAutomaticFollowEnabled(followGeneration)
        scrollDriver.onFallback = { reason, shouldReplayBottom in
            guard nativeScrollFallbackReason == nil else { return }
            nativeScrollFallbackReason = reason
            guard shouldReplayBottom, !userDragging else { return }
            scrollToTranscriptBottom()
        }
        let didAttach = scrollDriver.attach(scrollView)
        guard didAttach, scrollDriver.isAttached else { return }
        if userDragging || followPaused {
            scrollDriver.submit(.userDragBegan)
        } else {
            scrollDriver.submit(
                .explicitBottom(source: .button, animated: false, keyboardToken: nil)
            )
        }
    }

    // 输入条与 Chat 页保持完全一致:复用 Chat 的原生 Liquid Glass 组件
    // —— 左侧输入胶囊(`composerDockGlass`)+ 右侧分离的圆形发送键
    // (`ComposerDockSendButton`)。胶囊内左侧 `@` 键沿用 Chat 的「+」位,
    // 与 Chat 一致的原生输入胶囊 + 分离圆形发送键。去掉了原来无实际作用的 @ 键
    // （runner 并不解析 @host 提及）和此前黏连成一团的玻璃操作 chips。
    @ViewBuilder
    private var composer: some View {
        if viewModel.isReplay {
            replayBanner
        } else {
            liveComposer
        }
    }

    // 只读重放历史议会时的底部条:提示「只读」+ 一键开新议会(退出重放、清空房间)。
    private var replayBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AmberTheme.muted)
            Text(IOSAppLocalization.string("历史议会 · 只读", defaultValue: "历史议会 · 只读"))
                .font(.subheadline)
                .foregroundStyle(AmberTheme.muted)
            Spacer(minLength: 8)
            Button {
                viewModel.startFreshRoom()
            } label: {
                Text(IOSAppLocalization.string("开新议会", defaultValue: "开新议会"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(AmberTheme.accentTint, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background {
            LinearGradient(
                colors: [AmberTheme.background.opacity(0.78), AmberTheme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    /// 与 Chat 同构的输入区：pending 图/文件 → 错误 → 附件玻璃菜单 → dock。
    private var liveComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.pendingImages.isEmpty {
                ComposerPendingImageStrip(
                    items: viewModel.pendingImages.map {
                        .init(id: $0.id, previewData: $0.previewData)
                    },
                    onRemove: { viewModel.removePendingImage($0) },
                    status: councilImageAttachmentStatus
                )
            }

            ForEach(viewModel.pendingFiles) { file in
                ComposerPendingFileCard(
                    fileName: file.fileName,
                    byteSummary: Self.byteSummary(for: file),
                    isTruncated: file.isTruncated,
                    footnote: IOSAppLocalization.string(
                        "发送后，解析文本会注入议题完善与调研。",
                        defaultValue: "发送后，解析文本会注入议题完善与调研。"
                    ),
                    onRemove: { viewModel.removePendingFile(file.id) }
                )
            }

            if let error = viewModel.attachmentErrorMessage {
                ComposerAttachmentStatusLabel(status: .error(error))
            }

            if let error = viewModel.configurationErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentAmber)
                    .lineLimit(3)
            }

            if viewModel.isPreparingMaterials {
                ComposerAttachmentStatusLabel(
                    status: .preparing(viewModel.materialsPreparationStatus)
                )
            }

            if isAttachExpanded {
                ComposerAttachmentGlassPanel(
                    isDisabled: viewModel.isRunning || viewModel.isPreparingMaterials,
                    onCamera: presentCamera,
                    onPhotos: presentPhotoPicker,
                    onFiles: { isImportingSelectedFile = true },
                    onDismiss: { isAttachExpanded = false }
                )
                .transition(.scale(scale: 0.75, anchor: .bottomLeading).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    ComposerAttachToggleButton(
                        isExpanded: isAttachExpanded,
                        isBusy: viewModel.isPreparingMaterials,
                        isDisabled: viewModel.isRunning
                            || viewModel.isPreparingMaterials
                            || !viewModel.canAttachMaterials
                    ) {
                        withAnimation(.bouncy(duration: 0.42, extraBounce: 0.14)) {
                            isAttachExpanded.toggle()
                        }
                    }

                    TextField(viewModel.composerPlaceholder, text: $viewModel.inputText, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                        .frame(minHeight: 40)
                        .focused($isComposerFocused)
                        .disabled(viewModel.isRunning || viewModel.isPreparingMaterials)
                }
                .padding(.leading, 8)
                .padding(.trailing, 18)
                // 与 Chat 一致：附件 44 + 上下 5 → 外高 54，对齐发送键。
                .padding(.vertical, 5)
                .composerDockGlass(cornerRadius: 27)

                ComposerDockSendButton(
                    isLoading: viewModel.isRunning || viewModel.isPreparingMaterials,
                    sendEnabled: viewModel.canSend,
                    diameter: 54,
                    onSend: { viewModel.send() },
                    onStop: {
                        if viewModel.isPreparingMaterials {
                            viewModel.cancelMaterialsPreparation()
                        } else {
                            viewModel.cancelDiscussion()
                        }
                    }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background {
            LinearGradient(
                colors: [AmberTheme.background.opacity(0.78), AmberTheme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var councilImageAttachmentStatus: ComposerAttachmentStatus? {
        // Council always recognizes images into text (runner is text-only).
        guard !viewModel.pendingImages.isEmpty else { return nil }
        return .muted(
            IOSAppLocalization.string(
                "图片将先经视觉模型识别，再注入议题",
                defaultValue: "图片将先经视觉模型识别，再注入议题"
            ),
            systemImage: "wand.and.stars"
        )
    }

    private static func byteSummary(for file: CouncilPendingFile) -> String {
        file.totalBytes.formatted(
            .byteCount(style: .file)
                .locale(IOSAppLanguagePreference.selected().resolvedLocale())
        )
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            viewModel.attachmentErrorMessage = IOSAppLocalization.string(
                "此设备不支持相机。",
                defaultValue: "此设备不支持相机。"
            )
            return
        }
        cameraRoomGeneration = viewModel.attachmentRoomGeneration
        isCameraPresented = true
    }

    private func presentPhotoPicker() {
        photoPickerRoomGeneration = viewModel.attachmentRoomGeneration
        isPhotoPickerPresented = true
    }

    private func attachPickedImage(_ image: UIImage, roomGeneration: UInt64) {
        let previousTask = imageAttachmentTask
        let task = Task { @MainActor in
            await previousTask?.value
            guard !Task.isCancelled,
                  viewModel.attachmentRoomGeneration == roomGeneration else { return }
            let encoded = await ChatImageEncoder.encodeOffMain(image)
            guard viewModel.attachmentRoomGeneration == roomGeneration else { return }
            guard let encoded else {
                viewModel.attachmentErrorMessage = IOSAppLocalization.string(
                    "图片处理失败。",
                    defaultValue: "图片处理失败。"
                )
                return
            }
            viewModel.addPendingImage(dataUrl: encoded.dataUrl, previewData: encoded.previewData)
        }
        imageAttachmentTask = task
    }

    private func handlePhotoPickerSelection(_ items: [PhotosPickerItem]) {
        let roomGeneration = photoPickerRoomGeneration
        photoPickerRoomGeneration = nil
        guard !items.isEmpty, let roomGeneration else { return }
        let previousTask = imageAttachmentTask
        let task = Task { @MainActor in
            await previousTask?.value
            guard !Task.isCancelled,
                  viewModel.attachmentRoomGeneration == roomGeneration else { return }
            var failed = 0
            for item in items {
                let encoded: (dataUrl: String, previewData: Data)?
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        encoded = await ChatImageEncoder.decodeAndEncodeOffMain(data)
                    } else {
                        encoded = nil
                    }
                } catch {
                    encoded = nil
                }
                guard viewModel.attachmentRoomGeneration == roomGeneration else {
                    photoPickerItems = []
                    return
                }
                guard let encoded else {
                    failed += 1
                    continue
                }
                viewModel.addPendingImage(dataUrl: encoded.dataUrl, previewData: encoded.previewData)
            }
            photoPickerItems = []
            guard viewModel.attachmentRoomGeneration == roomGeneration else { return }
            if failed > 0 {
                viewModel.attachmentErrorMessage = IOSAppLocalization.formatted(
                    "有 %lld 张图片处理失败。",
                    defaultValue: "有 %lld 张图片处理失败。",
                    arguments: [Int64(failed)]
                )
            }
        }
        imageAttachmentTask = task
    }

    private func handleSelectedFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                viewModel.attachmentErrorMessage = IOSAppLocalization.string(
                    "没有选择文件。",
                    defaultValue: "没有选择文件。"
                )
                return
        }
        viewModel.attachPickedFile(url: url)
        case .failure(let error):
            viewModel.attachmentErrorMessage = IOSAppLocalization.formatted(
                "文件选择失败：%@",
                defaultValue: "文件选择失败：%@",
                arguments: [error.localizedDescription]
            )
        }
    }

}


/// 按语义开关与滚动所有权切换 `.sizeChanges` 底锚,与小说创作和标准 Chat 统一。
private struct CouncilSizeChangesPinModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            content
        }
    }
}


#Preview {
    NavigationStack {
        CouncilChatRuntimeView(settingsStore: SettingsStore(), sharedSettings: IOSSharedSettingsStore())
            .environment(RouterPath())
    }
}
