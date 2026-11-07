import SwiftUI
import Shared
import UIKit
import UniformTypeIdentifiers
import PhotosUI

struct ChatView: View {

    let settingsStore: SettingsStore
    let sharedSettings: IOSSharedSettingsStore
    let documentStore: DocumentAccessStore?
    let workspaceStore: IOSWorkspaceStore
    let activityStore: IOSSubAgentActivityStore
    let webMountController: IOSWebMountController
    let initialMessageAnchor: ChatMessageAnchor?
    @State var viewModel: ChatViewModel
    @State var browserState = ChatBrowserLocalState()
    @State var attachmentPickerState = ChatAttachmentPickerState()
    @State var composerState = ChatComposerLocalState()
    @State private var observedJevSummaryRunIds: [String: String] = [:]
    @State private var personalContextPicker = IOSPersonalContextPickerCoordinator.shared
    @State private var personalContextPhotoItems: [PhotosPickerItem] = []
    @State private var personalContextPhotoLoadID: UUID?
    @State private var artifactPinHandler = ChatArtifactPinHandler()
    @Environment(RouterPath.self)  var router
    @AppStorage(IOSDisplayPreferenceKeys.followGeneration) private var followGeneration = true
    @State var viewportState = ChatViewportState()
    @State var scrollToBottomTrigger = 0
    /// iPhone Duo 外屏右侧竖条是否承载了返回 / 新对话等操作。
    @State var sideRailActive = false
    @State var scrollToBottomSource: NativeTimelineBottomIntentSource = .button
    @State var chatSize: CGSize = .zero
    @State var requestedMessageAnchor: ChatMessageAnchor?
    @State var islandPresentation: ChatIslandPresentation?
    @State var islandHoldToken = 0
    @State var composerInputController = ComposerInputController()
    @State var chatListSummary = ChatListSummarySnapshot()
    @State var taskCountCache = ChatTaskCountCache()
    @State var artifactShelf = ChatArtifactShelfState()
    /// 产物架索引的正文图片与生成式 UI 解析缓存；引用类型，命中与淘汰不触发视图刷新。
    @State var artifactContentCache = ConversationArtifactContentCache()
    @State var artifactShelfDismissRevision = 0
    @State var failureNoticeToken = 0
    @State var showsTaskFailure = false
    @State var failureMessageID: String?
    @State var dockTapRegions = ChatDockTapRegions()
    @State var artifactShelfStripHeight: CGFloat = 0
    @State var messageEditDraft: ChatMessageEditDraft?
    @State var pendingDeleteMessageId: String?
    @State var isPresentingDuetTasks = false
    @State var isPresentingDuetWorkspace = false
    @State var isPresentingPersonaStudio = false
    @State var isPresentingEmbodimentHome = false
    @State var isPresentingCloudGatewaySettings = false
    @State var duetSelectedToolTarget: ToolDetailTarget?
    @Environment(IOSConversationStore.self)  var conversationStore
    @Environment(ConversationActivityCenter.self) var conversationActivityCenter
    @Environment(\.accessibilityReduceMotion)  var reduceMotion
    @Environment(\.scenePhase)  var scenePhase

    init(
        settingsStore: SettingsStore,
        sharedSettings: IOSSharedSettingsStore = IOSSharedSettingsStore(),
        localToolExecutor: IOSLocalToolExecutor? = nil,
        documentStore: DocumentAccessStore? = nil,
        workspaceStore: IOSWorkspaceStore = .shared,
        viewModel: ChatViewModel? = nil,
        initialMessageAnchor: ChatMessageAnchor? = nil,
        activityStore: IOSSubAgentActivityStore = .shared,
        webMountController: IOSWebMountController = .shared,
        initialComposerState: ChatComposerLocalState = ChatComposerLocalState()
    ) {
        self.settingsStore = settingsStore
        self.sharedSettings = sharedSettings
        self.documentStore = documentStore
        self.workspaceStore = workspaceStore
        self.activityStore = activityStore
        self.webMountController = webMountController
        self.initialMessageAnchor = initialMessageAnchor
        let resolvedViewModel = viewModel ?? ChatViewModel(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            localToolExecutor: localToolExecutor
        )
        self._viewModel = State(
            initialValue: resolvedViewModel
        )
        self._composerState = State(initialValue: initialComposerState)
    }

    private var isCloudHostActive: Bool {
        MacGatewayStore.shared.connection != nil && MacGatewayStore.shared.isCloudMainDialogueSelected
    }

    private var chatContent: some View {
        return ZStack {
            AmberThemePageBackground(surface: .app)
            ChatDialogueHostContent(isCloudSelected: isCloudHostActive) {
                messageList
                    .safeAreaBar(edge: .top, spacing: 0) {
                        Color.clear
                            .frame(height: ChatTopBarLayout.controlsHeight + ChatTopBarLayout.softEdgeExtension + artifactShelfStripHeight)
                            .allowsHitTesting(false)
                    }
                    .opacity(composerState.activeDuetTab == .chat ? 1 : 0)
                    .allowsHitTesting(composerState.activeDuetTab == .chat)
            } cloud: {
                AmberInlineCloudMainDialogueView(
                    store: MacGatewayStore.shared,
                    topInset: ChatTopBarLayout.controlsHeight + ChatTopBarLayout.softEdgeExtension + artifactShelfStripHeight,
                    isInputFocused: composerState.isInputFocused,
                    onOpenPairingSettings: { isPresentingCloudGatewaySettings = true },
                    onDismissKeyboard: dismissKeyboard
                )
                .opacity(composerState.activeDuetTab == .chat ? 1 : 0)
                .allowsHitTesting(composerState.activeDuetTab == .chat)
            }

            // 冷启动：会话历史还没读上来时先顶上与最终页同构的中性骨架，
            // 不先闪欢迎空态再被真实消息替换。顶栏与输入区照常渲染，
            // 因此骨架消失时不会发生布局跳动。
            if awaitsConversationBootstrap {
                ChatStartupSkeleton()
                    .zIndex(10)
                    .accessibilityHidden(true)
            }

            if let record = compactWebMountSession {
                VStack {
                    Spacer()
                    AgentBrowserTaskCompactBar(
                        record: record,
                        runSummary: viewModel.isGenerationActiveForCurrentConversation
                            ? chatListSummary.browserTaskTitleCandidate
                            : nil,
                        showsOnlyShortcut: true,
                        onExpand: {
                            browserState.collapsedWebMountSessionId = nil
                            browserState.expandedWebMountSessionId = record.id
                        }
                    )
                    .padding(.horizontal, ChatLayout.contentHorizontalInset)
                    // The bottom inset already reserves the composer and activity bar.
                    .padding(.bottom, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(browserTaskTransition)
                .zIndex(9)
            }

            // 视觉浮层,不参与 bottom safe-area inset 布局。否则按钮显隐会改变
            // ScrollView 的可视区域,和系统顶部/底部 rubber-band 回弹互相拉扯。
            if viewportState.showScrollToBottom && chatListSummary.hasMessages && !sideRailActive {
                VStack {
                    Spacer()
                    ChatScrollToBottomButton {
                        scrollToBottomSource = .button
                        scrollToBottomTrigger &+= 1
                    }
                    .padding(.bottom, scrollToBottomBottomPadding)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .zIndex(10)
            }

            // Tap-outside scrim for the attachment glass panel or inline Argon panels (Tasks / Hubs).
            if composerState.isAttachExpanded || composerState.activeDuetTab != .chat {
                (composerState.activeDuetTab != .chat ? AmberTheme.surface : Color.black.opacity(0.06))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if composerState.activeDuetTab != .chat {
                            withAnimation(.snappy(duration: 0.22)) {
                                composerState.activeDuetTab = .chat
                            }
                        } else {
                            withAnimation(.bouncy(duration: 0.38, extraBounce: 0.1)) {
                                composerState.isAttachExpanded = false
                            }
                        }
                    }
                    .transition(.opacity)
            }
            // 面板需要参与正文区域命中测试，不能挂在仅顶栏高度的 safeAreaBar 内。
            topBar
                .zIndex(20)
        }
        .onGeometryChange(for: ChatGeometrySample.self) { proxy in
            ChatGeometrySample(
                size: CGSize(
                    width: proxy.size.width,
                    height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
                ),
                safeAreaTop: proxy.safeAreaInsets.top
            )
        } action: { sample in
            if ChatSheetDismissSmoothnessPolicy.shouldAcceptChatGeometryUpdate(
                currentSize: chatSize,
                proposedSize: sample.size,
                safeAreaTop: sample.safeAreaTop,
                isModalSheetPresented: isAnyModalSheetPresented
            ) {
                chatSize = sample.size
            }
        }
        .animation(browserTaskVisibilityAnimation, value: compactWebMountSession?.id)
        .onChange(of: composerState.activeDuetTab) { oldTab, newTab in
            ChatPanelSwitchPerfProbe.didSwitch(from: oldTab.rawValue, to: newTab.rawValue)
        }
        .onChange(of: displayedWebMountSession?.ownerRunId) { _, _ in
            browserState.expandedWebMountSessionId = nil
        }
        // Composer pinned to the bottom safe area via `.safeAreaInset` (NOT `.safeAreaBar`).
        // safeAreaBar added an adaptive Liquid Glass bar, but it caused two problems: (a) it
        // flipped to its dark variant over the terracotta backdrop, and (b) its under-bar
        // scrolling content overlapped the composer, so the expanding model / thinking / context
        // controls were clipped and the keyboard-dismiss tap could resign the field's focus the
        // moment it gained it — hiding those controls. safeAreaInset keeps the composer correctly
        // sized on its own crisp surfaces and does not overlap the scroll content.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                ChatSubAgentActivityBar(
                    currentConversationId: currentConversationIdString,
                    isInputFocused: composerState.isInputFocused,
                    activityStore: activityStore,
                    onOpenSource: { sourceConversationId in
                        await openSubAgentSourceConversation(sourceConversationId)
                    }
                )
                .frame(height: collapsesComposerForSiteMemoryApproval ? 0 : nil, alignment: .top)
                .clipped()
                .opacity(collapsesComposerForSiteMemoryApproval ? 0 : 1)
                .allowsHitTesting(!collapsesComposerForSiteMemoryApproval)
                .accessibilityHidden(collapsesComposerForSiteMemoryApproval)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if abs(composerState.subAgentActivityBarHeight - height) > 0.5 {
                        composerState.subAgentActivityBarHeight = height
                    }
                    let visible = height > 0
                    if composerState.isSubAgentBarVisible != visible { composerState.isSubAgentBarVisible = visible }
                }

                // 不再强制 light:原生 `.glassEffect` 本就按系统外观渲染(深色模式下渲染为深色玻璃),
                // 若把内容强制成 light,前景图标/文字会按浅色调色板解析成深灰,贴在深色玻璃上发暗。
                // 让 composer 跟随真实外观(与顶栏一致),图标与玻璃明暗才匹配。
                inputBar
            }
        }
        .onChange(of: viewModel.pendingWebMountApproval?.id) { _, id in
            if composerState.collapsedSiteMemoryComposerRequestId != nil {
                composerState.collapsedSiteMemoryComposerRequestId = viewModel.pendingWebMountApproval?.siteMemoryChanges == nil ? nil : id
            }
        }
        .task(id: siteMemoryApprovalLayoutSignal) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            collapseSiteMemoryComposerIfNeeded()
        }
        .sheet(isPresented: $composerState.isModelSheetPresented) {
            ComposerModelSheet(sharedSettings: sharedSettings, currentModel: composerCurrentModelSelection) { model in
                sharedSettings.setCurrentAssistantChatModelId(model.id)
                sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
                viewModel.reasoningLevel = sharedSettings.currentAssistantReasoningLevel()
                viewModel.bumpMessageRevision(reason: .settingsRefresh)
                composerState.isModelSheetPresented = false
            }
            .amberFloatingSheet(detents: [.medium, .large])
        }
        .sheet(item: $messageEditDraft) { draft in
            ChatMessageEditSheet(draft: draft) { messageId, newText in
                viewModel.editMessage(messageId: messageId, newText: newText)
                messageEditDraft = nil
            } onCancel: {
                messageEditDraft = nil
            }
            .amberFloatingSheet(detents: [.large])
        }
        .sheet(isPresented: $browserState.showWebMountDesktopBackends, onDismiss: {
            browserState.focusedRemoteWebMountSessionId = nil
        }) {
            WebMountDesktopBackendsView(
                controller: webMountController,
                focusedSessionId: browserState.focusedRemoteWebMountSessionId
            )
            .amberFloatingSheet(detents: [.large])
        }
        .fileImporter(
            isPresented: $attachmentPickerState.isImportingSelectedFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleSelectedFileImport(result)
        }
        .photosPicker(
            isPresented: $attachmentPickerState.isPhotoPickerPresented,
            selection: $attachmentPickerState.photoPickerItems,
            maxSelectionCount: ChatViewModel.maxImagesPerMessage,
            matching: .images
        )
        .onChange(of: attachmentPickerState.photoPickerItems) { _, items in
            handlePhotoPickerSelection(items)
        }
        .sheet(isPresented: personalContactPickerPresented) {
            IOSContactPickerView(
                onSelect: { personalContextPicker.receiveContacts($0) },
                onCancel: { personalContextPicker.cancelActiveRequest() }
            )
            .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: personalPhotoPickerPresented,
            selection: $personalContextPhotoItems,
            maxSelectionCount: personalContextPicker.activeRequest?.maxSelectionCount ?? 4,
            matching: .images
        )
        .onChange(of: personalContextPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            let loadID = UUID()
            personalContextPhotoLoadID = loadID
            Task { @MainActor in
                await personalContextPicker.receivePhotos(items)
                if personalContextPhotoLoadID == loadID {
                    personalContextPhotoItems = []
                    personalContextPhotoLoadID = nil
                }
            }
        }
        .iosPersonalContextJournalingPicker(
            isPresented: personalJournalingPickerPresented,
            coordinator: personalContextPicker
        )
        .overlay {
            if personalContextPicker.activeRequest != nil,
               personalContextPicker.isLoading,
               personalContextPicker.preview == nil {
                ZStack {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在准备你选择的内容…")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(AmberTheme.foreground)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在准备你选择的内容")
            }
        }
        .sheet(item: personalContextPreviewBinding) { preview in
            IOSPersonalContextHandoffSheet(
                preview: preview,
                isLoading: personalContextPicker.isLoading,
                onCancel: { personalContextPicker.cancelActiveRequest() },
                onConfirm: { personalContextPicker.confirmHandoff() }
            )
            .amberFloatingSheet(detents: [.medium, .large])
        }
        .fullScreenCover(isPresented: $attachmentPickerState.isCameraPresented) {
            CameraPicker { image in
                if let image { handleCameraImageSelection(image) }
                else { attachmentPickerState.cameraPickerConversationId = nil }
                attachmentPickerState.isCameraPresented = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isPresentingDuetTasks) {
            AmberDuetTaskCenterSheet(
                gateway: MacGatewayStore.shared,
                subAgentStore: activityStore,
                onOpenFullTaskBoard: { router.navigate(to: .macTasks) },
                onOpenTask: { task in openUnifiedTask(task) }
            )
            .amberFloatingSheet(detents: [.medium, .large])
        }
        .sheet(isPresented: $isPresentingDuetWorkspace) {
            AmberDuetWorkspaceDrawerSheet(
                conversationStore: conversationStore,
                gateway: MacGatewayStore.shared,
                onSelectConversation: { id in
                    Task { _ = await openSubAgentSourceConversation(id.toHexDashString()) }
                },
                onNewConversation: {
                    startNewChatTopic()
                },
                onOpenAllHistory: {
                    // 旧首页已从「根」降为「会话管理」页：从抽屉里显式 push，
                    // 不再依赖「back 到根就是首页」这种隐含关系。
                    router.navigate(to: .home)
                },
                onNavigate: { destination in
                    router.navigate(to: destination)
                }
            )
            .amberFloatingSheet(detents: AmberDuetWorkspaceDrawerSheet.preferredPresentationDetents)
        }
        .sheet(isPresented: $isPresentingEmbodimentHome) {
            // 顶部形象点击 → 形象人设（人设/记忆/灵感）；「更换形象」二级进原有配置页。
            AgentEmbodimentHomeSheet(
                sharedSettings: sharedSettings,
                onStartConversation: { prompt in
                    viewModel.inputText = prompt
                    Task { await viewModel.sendMessage() }
                }
            )
            .amberFloatingSheet(detents: [.large])
        }
        .sheet(isPresented: $isPresentingPersonaStudio) {
            AmberPersonaStudioSheet(
                sharedSettings: sharedSettings
            )
            .amberFloatingSheet(detents: [.large])
        }
        .sheet(isPresented: $isPresentingCloudGatewaySettings) {
            NavigationStack {
                MacGatewaySettingsView()
            }
            .amberFloatingSheet(detents: [.large])
        }
        .onChange(of: router.path) { _, newPath in
            if !newPath.isEmpty && isPresentingCloudGatewaySettings {
                isPresentingCloudGatewaySettings = false
            }
        }
        .sheet(item: $duetSelectedToolTarget) { target in
            ChatToolDetailSheet(
                tool: target.initialTool,
                live: target.initialTool.toolName.contains("subagent_dispatch")
                    ? SubAgentLiveRegistry.shared.model(forToolCallId: target.toolCallId)
                    : nil,
                onOpenSubagentConversation: { threadId in
                    router.navigate(to: .subAgentConversation(id: threadId))
                }
            )
            .amberFloatingSheet(detents: [.medium, .large])
        }
    }

    var isAnyModalSheetPresented: Bool {
        isAnyFloatingSheetPresented
    }

    private var isAnyFloatingSheetPresented: Bool {
        composerState.isModelSheetPresented
            || messageEditDraft != nil
            || browserState.showWebMountDesktopBackends
            || personalContextPreviewBinding.wrappedValue != nil
            || isPresentingDuetTasks
            || isPresentingDuetWorkspace
            || isPresentingEmbodimentHome
            || isPresentingPersonaStudio
            || isPresentingCloudGatewaySettings
            || duetSelectedToolTarget != nil
    }

    var body: some View {
        let _ = ChatRenderProbe.record("chat-view-body")
        chatContent
            .environment(\.amberIsUnderlyingSheetPresented, isAnyFloatingSheetPresented)
        // Measure the parent's proposal, before the bottom inset can grow to its ideal height.
        .onGeometryChange(for: ChatGeometrySample.self) { proxy in
            ChatGeometrySample(size: proxy.size, safeAreaTop: proxy.safeAreaInsets.top)
        } action: { sample in
            if ChatSheetDismissSmoothnessPolicy.shouldAcceptApprovalContainerHeightUpdate(
                currentHeight: composerState.approvalContainerHeight,
                proposedHeight: sample.size.height,
                safeAreaTop: sample.safeAreaTop,
                isModalSheetPresented: isAnyModalSheetPresented
            ) {
                composerState.approvalContainerHeight = sample.size.height
            }
        }
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
            // Observe taps alongside the existing controls/scroll views; do not
            // place a full-screen hit-test layer over the timeline.
            if dockTapRegions.isPanelOpen, !dockTapRegions.contains(tap.location) {
                artifactShelfDismissRevision &+= 1
            }
        })
        .amberSideRail(isActive: $sideRailActive, top: sideRailTopItems, bottom: sideRailBottomItems)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear {
            personalContextPicker.cancelActiveRequest()
        }
        .alert(item: userVisibleErrorBinding) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("好")) { conversationStore.clearUserVisibleError() }
            )
        }
        .confirmationDialog(
            "删除这条消息？",
            isPresented: pendingDeleteMessageBinding,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let id = pendingDeleteMessageId {
                    viewModel.deleteMessage(messageId: id)
                }
                pendingDeleteMessageId = nil
            }
            Button("取消", role: .cancel) { pendingDeleteMessageId = nil }
        } message: {
            Text("删除后不可恢复。")
        }
        .onAppear {
            handleChatAppear()
            rememberJevSummaryRun(viewModel.currentConversationRunId)
        }
        .task(id: "\(currentConversationIdString ?? ""): \(viewModel.isGenerationActive)") {
            await viewModel.observeIdleMailboxResults(conversationId: viewModel.currentConversationId)
        }
        // 仅观察 store 的「切会话」修订号——它只在真正切到另一个会话时 +1，
        // 不受同会话落盘（生成中 tool start/result/complete）影响。
        // 这样落盘不再触发重灌历史 + 重建 ScrollView，消除抖动和「上滑看历史被甩回锚点」。
        // 消息内容同步由 generation 链路的 setMessages 负责，不靠这里。
        .onChange(of: conversationStore.conversationSwitchedRevision) { _, _ in
            handleConversationSwitch()
        }
        .onChange(of: viewModel.currentConversationRunId) { _, runId in
            rememberJevSummaryRun(runId)
        }
        .onChange(of: conversationStore.backgroundContentRevision) { _, _ in
            handleBackgroundContentLanded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .amberChatBackgroundJobDidTerminate)) { notification in
            guard let event = notification.object as? IOSChatBackgroundJobTerminalEvent else { return }
            handleBackgroundJobTerminated(event)
        }
        .onReceive(NotificationCenter.default.publisher(for: .amberChatBackgroundJobStateDidChange)) { notification in
            guard let event = notification.object as? IOSChatBackgroundJobStateEvent,
                  event.conversationId == currentConversationIdString else { return }
            syncIslandPresentation()
        }
        .onChange(of: composerState.isInputFocused) { wasFocused, isFocused in
            guard !wasFocused, isFocused else { return }
            handleComposerFocusStarted()
        }
        .onChange(of: viewModel.artifactUpdateSignal, initial: true) { _, signal in
            refreshArtifactShelf(reason: signal.reason)
        }
        .onChange(of: sharedSettings.revision) { _, _ in
            handleSharedSettingsRevisionChange()
        }
        .onChange(of: viewModel.isGenerationActive) { _, _ in
            refreshChatListSummary()
            syncIslandPresentation()
        }
        .onChange(of: viewModel.runActivityRevision) { _, _ in
            refreshChatListSummary()
            syncIslandPresentation()
        }
        .onChange(of: viewModel.selectedFollowupRunId) { _, _ in
            refreshChatListSummary()
            syncIslandPresentation()
        }
        .onChange(of: scenePhase) { _, _ in
            syncIslandPresentation()
        }
    }

    private var personalContactPickerPresented: Binding<Bool> {
        Binding(
            get: {
                personalContextPicker.activeRequest?.kind == .contacts &&
                    personalContextPicker.preview == nil
            },
            set: { presented in
                if !presented,
                   personalContextPicker.activeRequest?.kind == .contacts,
                   personalContextPicker.preview == nil {
                    personalContextPicker.cancelActiveRequest()
                }
            }
        )
    }

    private var personalPhotoPickerPresented: Binding<Bool> {
        Binding(
            get: {
                personalContextPicker.activeRequest?.kind == .photos &&
                    personalContextPicker.preview == nil &&
                    !personalContextPicker.isLoading
            },
            set: { presented in
                if !presented,
                   personalContextPicker.activeRequest?.kind == .photos,
                   personalContextPicker.preview == nil,
                   !personalContextPicker.isLoading,
                   personalContextPhotoItems.isEmpty {
                    personalContextPicker.cancelActiveRequest()
                }
            }
        )
    }

    private var personalJournalingPickerPresented: Binding<Bool> {
        Binding(
            get: {
                personalContextPicker.activeRequest?.kind == .journaling &&
                    personalContextPicker.preview == nil &&
                    !personalContextPicker.isLoading
            },
            set: { presented in
                if !presented,
                   personalContextPicker.activeRequest?.kind == .journaling,
                   personalContextPicker.preview == nil,
                   !personalContextPicker.isLoading {
                    personalContextPicker.cancelActiveRequest()
                }
            }
        )
    }

    private var personalContextPreviewBinding: Binding<IOSPersonalContextPreview?> {
        Binding(
            get: { personalContextPicker.preview },
            set: { preview in
                if preview == nil,
                   personalContextPicker.preview != nil {
                    personalContextPicker.cancelActiveRequest()
                }
            }
        )
    }

    private func handleChatAppear() {
        // 绑定 store（@Environment 在 init 里不可用，故在 onAppear 注入）。
        viewModel.conversationStore = conversationStore
        viewportState = ChatViewportState()
        viewModel.reloadFromStore(reason: .initialLoad)
        refreshChatListSummary(resetTitleSeed: true)
        repairCurrentChatModelIfNeeded()
        if let handoff = IOSWebMountContentHandoffStore.shared.consumeChatHandoff() {
            viewModel.inputText = handoff.chatPrompt
            viewModel.selectedFileContextError = nil
        }
    }

    private func handleConversationSwitch() {
        requestedMessageAnchor = nil
        islandHoldToken &+= 1
        islandPresentation = nil
        viewModel.reloadFromStore(reason: .conversationSwitch)
        refreshChatListSummary(resetTitleSeed: true)
    }

    private func handleBackgroundJobTerminated(_ event: IOSChatBackgroundJobTerminalEvent) {
        guard let currentConversationId = currentConversationIdString,
              event.conversationId == currentConversationId else { return }
        handleBackgroundContentLanded(forceReload: true)
    }

    /// 后台生成/工具回填落盘后的定向上屏:三重门控,绝不打扰进行中的前台流式,
    /// 也绝不因别的会话的后台完成而重灌当前会话。
    private func handleBackgroundContentLanded(forceReload: Bool = false) {
        guard let currentId = conversationStore.currentConversation?.id else { return }
        let idString = String(describing: currentId)
        let hasPendingContent = conversationStore.pendingBackgroundContentConversationIds.contains(idString)
        guard hasPendingContent || forceReload else { return }
        // 前台生成中不动 messages,也**不消费**——收尾事件会带着未消费的 pending 再进来。
        guard !viewModel.isGenerationActive, !viewModel.isLoading else { return }
        if hasPendingContent {
            conversationStore.consumeBackgroundContentNotification(for: idString)
        }
        // .branchChange:语义=消息树被外部改写;affectsViewport=false 不发滚动命令;
        // 且会清 contentHashCache——后台工具回填正是「同 id 原地变更」路径,必须清。
        viewModel.reloadFromStore(reason: .branchChange)
        refreshChatListSummary(resetTitleSeed: false)
    }

    private func handleMessageUpdateSignal(_ signal: ChatMessageUpdateSignal) {
        if signal.event == .assistantStreamDelta {
            refreshStreamingChatListSummary()
        } else {
            refreshChatListSummary(
                resetTitleSeed: signal.event == .conversationLoaded ||
                    signal.event == .conversationSwitched ||
                    signal.event == .branchChanged
            )
        }
        // 后台内容若在本轮前台生成期间落盘,门控当时跳过且未消费;收尾时补查上屏。
        switch signal.event {
        case .generationFailed:
            failureNoticeToken &+= 1
            let token = failureNoticeToken
            showsTaskFailure = true
            failureMessageID = viewModel.messages.last(where: ChatViewModel.isLocalGenerationError)
                .map(ChatMessageProjector.messageId(for:))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, failureNoticeToken == token else { return }
                showsTaskFailure = false
            }
            handleBackgroundContentLanded()
        case .generationCompleted, .generationCancelled:
            handleBackgroundContentLanded()
        case .conversationLoaded, .conversationSwitched, .branchChanged, .userMessageAppended:
            failureNoticeToken &+= 1
            showsTaskFailure = false
            failureMessageID = nil
        default:
            break
        }
        if signal.event != .assistantStreamDelta { syncIslandPresentation() }
    }

    private func handleComposerFocusStarted() {
        guard Self.shouldFollowBottomOnComposerFocus(viewportState: viewportState) else { return }
        scrollToBottomSource = .composerFocus
        scrollToBottomTrigger &+= 1
    }

    static func shouldFollowBottomOnComposerFocus(viewportState: ChatViewportState) -> Bool {
        viewportState.isAtBottom && !viewportState.followPaused
    }

    private func handleSharedSettingsRevisionChange() {
        repairCurrentChatModelIfNeeded()
        viewModel.bumpMessageRevision(reason: .settingsRefresh)
        // 关闭/开启生成式 UI 后，产物架与气泡同步增减 HTML 条目。
        refreshArtifactShelf(reason: .settingsRefresh)
    }

    private var userVisibleErrorBinding: Binding<IOSUserVisibleError?> {
        Binding(
            get: { conversationStore.lastUserVisibleError },
            set: { newValue in
                if newValue == nil {
                    conversationStore.clearUserVisibleError()
                }
            }
        )
    }

    private var pendingDeleteMessageBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteMessageId != nil },
            set: { if !$0 { pendingDeleteMessageId = nil } }
        )
    }

    var currentConversationIdString: String? {
        viewModel.currentConversationId?.toHexDashString()
    }

    var jevSummaryRunId: String? {
        if let currentRunId = viewModel.currentConversationRunId { return currentRunId }
        guard let conversationId = currentConversationIdString else { return nil }
        return observedJevSummaryRunIds[conversationId]
    }

    private func rememberJevSummaryRun(_ runId: String?) {
        guard let runId, let conversationId = currentConversationIdString else { return }
        observedJevSummaryRunIds[conversationId] = runId
    }

    @MainActor
    func openSubAgentSourceConversation(_ sourceConversationId: String) async -> Bool {
        guard let uuid = UUID(uuidString: sourceConversationId) else { return false }
        let conversationId = KotlinUuid.companion.parse(
            uuidString: uuid.uuidString.lowercased()
        )
        guard let summary = conversationStore.allSummaries.first(where: {
            $0.id.toHexDashString().caseInsensitiveCompare(sourceConversationId) == .orderedSame
        }) else {
            return false
        }
        if conversationStore.currentConversation?.id == summary.id {
            return true
        }
        let selectionRevision = conversationStore.conversationSwitchedRevision

        // Child transcripts are not promoted into the main chat selection. Load
        // once to prove the target still exists, then route to the read-only
        // child transcript just like the app-level conversation deep link.
        let isChildConversation = !conversationStore.summaries.contains(where: {
            $0.id == summary.id
        })
        guard (try? await conversationStore.loadConversationForOrchestration(conversationId)) != nil,
              !Task.isCancelled,
              conversationStore.conversationSwitchedRevision == selectionRevision else {
            return false
        }
        if isChildConversation {
            router.navigate(to: .subAgentConversation(id: summary.id.toHexDashString()))
            return true
        }

        guard viewModel.prepareForConversationChange(to: conversationId) else { return false }
        if conversationStore.currentConversation?.id != conversationId {
            guard await conversationStore.selectConversationIfAvailable(
                id: conversationId,
                commitIf: {
                    !Task.isCancelled &&
                    conversationStore.conversationSwitchedRevision == selectionRevision
                }
            ) else {
                return false
            }
        }
        return !Task.isCancelled && conversationStore.currentConversation?.id == conversationId
    }

    var attachmentGlassPanel: some View {
        ComposerAttachmentGlassPanel(
            onCamera: presentCamera,
            onPhotos: presentPhotosPicker,
            onFiles: presentFileImporter,
            onDismiss: { composerState.isAttachExpanded = false }
        )
    }

    var chatImageAttachmentStatus: ComposerAttachmentStatus? {
        switch viewModel.imageAttachmentState {
        case .blocked(let message):
            return .warning(message)
        case .fallback:
            return .muted(
                IOSAppLocalization.string(
                    "当前模型不支持图片，将先用视觉模型识别后再发送",
                    defaultValue: "当前模型不支持图片，将先用视觉模型识别后再发送"
                ),
                systemImage: "wand.and.stars"
            )
        case .ready, .none:
            return nil
        }
    }

    private var sideRailTopItems: [AmberSideRailItem] {
        [
            AmberSideRailItem(id: "back", systemImage: hasSidebarAtRoot ? "sidebar.left" : "line.3.horizontal",
                              accessibilityLabel: hasSidebarAtRoot ? "显示会话列表" : "空间与历史") {
                handleBackTap()
            },
            AmberSideRailItem(id: "new-chat", systemImage: "square.and.pencil", accessibilityLabel: "新建聊天") {
                Task { await viewModel.startNewConversation() }
            },
        ]
    }

    /// 竖条底部放拇指最常用的一个动作：生成中可停止，否则在离开底部时回到最新。
    private var sideRailBottomItems: [AmberSideRailItem] {
        if viewModel.isGenerationActive {
            return [AmberSideRailItem(id: "stop", systemImage: "stop.fill", accessibilityLabel: "停止生成",
                                      prominent: true) { viewModel.cancelGeneration() }]
        }
        guard viewportState.showScrollToBottom, chatListSummary.hasMessages else { return [] }
        return [AmberSideRailItem(id: "scroll-bottom", systemImage: "arrow.down", accessibilityLabel: "回到最新") {
            scrollToBottomSource = .button
            scrollToBottomTrigger &+= 1
        }]
    }

    /// 双栏详情栏根：聊天页没有上一页可返回，返回键改为收放会话侧栏。
    private var hasSidebarAtRoot: Bool { router.showsSidebarControl && router.path.isEmpty }

    /// 启动引导尚未走完（历史未读上来）且当前无可见内容：用骨架占位。
    /// 一旦 `isBootstrapped` 为真（成功或失败都算结束）就立即让位给真实时线。
    private var awaitsConversationBootstrap: Bool {
        !conversationStore.isBootstrapped
            && !viewModel.isLoading
            && viewModel.messages.isEmpty
    }

    /// 顶栏 / 外屏竖条的返回键共用同一套语义，避免两处各自推断根在哪。
    private func handleBackTap() {
        if hasSidebarAtRoot {
            router.goBack()
        } else {
            isPresentingDuetWorkspace = true
        }
    }

    /// 单流陪伴对话中的「✦ 新话题」入口：将前序活跃轮次就地封存为一个 Episode 并插入轻量分割线，
    /// 不清空历史滚屏；仅当尚无会话实体时才初始化新会话。
    func startNewChatTopic() {
        guard conversationStore.currentConversation != nil else {
            Task { await viewModel.startNewConversation() }
            return
        }
        if viewModel.startNewEpisode() {
            viewportState.followPaused = false
            scrollToBottomSource = .button
            scrollToBottomTrigger &+= 1
        }
    }

    var topBar: some View {
        let generating = viewModel.isGenerationActive || viewModel.completionFeedback.hasActiveOrDrainingRun
        let currentIslandState = topIslandState
        let recap = generating ? nil : currentRecap
        let recapLoading = !generating && (currentConversationIdString.map {
            conversationStore.recapGenerator.isLoading(for: $0)
        } ?? false)
        return ChatTopBarView(
            presentation: islandPresentation ?? .idle(currentIslandState),
            conversationID: currentConversationIdString,
            hasMessages: chatListSummary.hasMessages,
            isGenerating: generating,
            notices: conversationActivityCenter.notices,
            shelfHeight: chatSize.height * 0.55,
            onBack: handleBackTap,
            onIslandTap: handleIslandTap,
            onCancel: { viewModel.cancelGeneration() },
            onOpenConversation: openActivityConversation,
            onDismiss: { conversationActivityCenter.dismiss(conversationId: $0) },
            onNewConversation: startNewChatTopic,
            loadPreview: { id in
                guard let message = await conversationActivityCenter.lastMessage(conversationId: id) else { return nil }
                return message.toText().nilIfBlank
            },
            previewRevision: { id in
                conversationStore.allSummaries.first(where: { $0.id.toHexDashString() == id })
                    .map { String(describing: $0.updateAt) }
            },
            artifacts: artifactShelf.index,
            backSystemImage: hasSidebarAtRoot ? "sidebar.left" : "line.3.horizontal",
            backAccessibilityLabel: hasSidebarAtRoot
                ? (router.showsSidebar ? "隐藏会话列表" : "显示会话列表")
                : "空间与历史",
            showsBackButton: !sideRailActive,
            snippets: currentConversationIdString.map {
                ChatArtifactPinning.visibleSnippets(conversationStore.artifactStore.snippets(for: $0), messageIDs: chatListSummary.messageIDs)
            } ?? [],
            adoptedVersions: currentConversationIdString.map { conversationStore.artifactStore.adoptedVersions(for: $0) } ?? [:],
            conversationTitle: conversationStore.currentConversation?.title ?? "对话成果",
            onExportConversation: exportConversation,
            onLocateSnippet: { snippet in
                guard let id = currentConversationIdString,
                      let anchor = ChatArtifactPinning.anchor(
                        for: snippet, conversationID: id, messages: viewModel.messages
                      ) else {
                    showArtifactError("收藏的原消息不在当前分支中，无法定位。")
                    return false
                }
                requestedMessageAnchor = anchor
                return true
            },
            onUnpinSnippet: { snippetID in
                updateArtifactShelf { store, id in try store.unpin(snippetID: snippetID, for: id) }
            },
            onAdoptVersion: { path, versionID in
                updateArtifactShelf { store, id in try store.adopt(versionID: versionID, path: path, for: id) }
            },
            onContinueArtifact: continueFromArtifact,
            generativeUiSetting: sharedSettings.agentRuntime.generativeUi,
            onOpenMiniApp: { router.navigate(to: .miniAppRunner(appId: $0)) },
            artifactArrival: artifactShelf.arrival,
            onLocateArtifact: { source in
                guard let conversationID = currentConversationIdString,
                      let anchor = ConversationArtifactIndex.anchor(
                        for: source, conversationID: conversationID,
                        messages: viewModel.messages, requestToken: UUID()
                      ) else { return false }
                requestedMessageAnchor = anchor
                return true
            },
            dismissShelfRevision: artifactShelfDismissRevision,
            onShelfStripHeightChange: { artifactShelfStripHeight = $0 },
            tapRegions: dockTapRegions,
            recapEligible: !generating && ConversationRecapLogic.eligible(userMessageCount: chatListSummary.userMessageCount),
            recap: recap,
            recapLoading: recapLoading,
            recapFailure: generating ? nil : currentConversationIdString.flatMap { conversationStore.recapGenerator.error(for: $0) },
            recapStale: recap.map {
                ConversationRecapLogic.isStale(
                    recap: $0,
                    messageIDs: chatListSummary.messageIDs,
                    lastMessageID: chatListSummary.lastMessageID,
                    branchID: chatListSummary.recapBranchID
                )
            } ?? false,
            onOpenRecap: {
                if recap == nil, !recapLoading {
                    requestRecap()
                }
            },
            onRefreshRecap: requestRecap,
            onLocateRecapNode: locateRecapNode,
            onRecapNextStep: fillRecapNextStep,
            backgroundRunningCount: viewModel.activeTaskRunIdsForCurrentConversation.count,
            isModalSheetPresented: isAnyModalSheetPresented,
            onAvatarTap: {
                isPresentingEmbodimentHome = true
            }
        )
        .onAppear { syncIslandPresentation() }
        .onChange(of: topIslandState) { _, _ in syncIslandPresentation() }
    }

    // MARK: - Message List

    private var messageList: some View {
        let _ = artifactPinHandler.action = pinArtifactSnippet
        return ChatTimelineSignalHost(viewModel: viewModel, onSignalChange: handleMessageUpdateSignal) { signal in
            let timelineActivity = currentTimelineActivity
            NativeChatTimelineView(
                signal: signal,
                timelineUpdates: viewModel.timelineUpdates,
                configurationIssue: configurationIssue,
                isGenerationActive: viewModel.isGenerationActive,
                liveTaskTailIDs: viewModel.currentRun.state.liveTaskTailMessageIds,
                usesIndependentTasks: !viewModel.activeTaskRunIdsForCurrentConversation.isEmpty,
                activity: timelineActivity,
                isLoading: viewModel.isLoading,
                isRecognizingImages: viewModel.isRecognizingImages,
                contextCompactState: viewModel.contextCompactState,
                contextCompactBoundaries: viewModel.contextCompactBoundaries,
                followGeneration: followGeneration,
                displaySetting: sharedSettings.displaySetting,
                generativeUiSetting: sharedSettings.agentRuntime.generativeUi,
                reasoningLevelLabel: composerReasoningLabel,
                workspaceStore: workspaceStore,
                scrollToBottomTrigger: scrollToBottomTrigger,
                scrollToBottomSource: scrollToBottomSource,
                messageAnchor: requestedMessageAnchor ?? initialMessageAnchor,
                currentConversationID: currentConversationIdString,
                messagesProvider: { viewModel.messages },
                variantInfoProvider: { index in viewModel.variantInfo(atMessageIndex: index) },
                onAction: handleChatListAction,
                onViewportStateChange: applyCollectionViewportState,
                onDismissKeyboard: dismissKeyboard
            )
            .environment(\.intelligentUIHost, viewModel.intelligentUIHost)
            .environment(\.intelligentUIConversationID, currentConversationIdString)
            .environment(\.intelligentUIBusy, viewModel.isGenerationActive || viewModel.isLoading || viewModel.isIntelligentUISubmissionInFlight)
            .environment(\.chatMessageEditingAllowed, !viewModel.isIntelligentUISubmissionInFlight)
            .environment(\.chatArtifactPinAction, artifactPinHandler)
            .environment(\.chatCompletionFeedback, viewModel.completionFeedback)
            .modifier(ChatCompletionFeedbackVisibility(
                owner: viewModel.completionFeedback,
                isVisible: scenePhase == .active && composerState.activeDuetTab == .chat && !isCloudHostActive
            ))
            .id(NativeChatTimelineSessionIdentity.viewID(conversationId: conversationStore.currentConversation?.id))
        }
    }
}


private struct ChatGeometrySample: Equatable {
    let size: CGSize
    let safeAreaTop: CGFloat
}
