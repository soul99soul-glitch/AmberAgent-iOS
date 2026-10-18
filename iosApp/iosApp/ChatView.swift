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
    @State private var scrollToBottomTrigger = 0
    @State private var scrollToBottomSource: NativeTimelineBottomIntentSource = .button
    @State private var chatSize: CGSize = .zero
    @State var requestedMessageAnchor: ChatMessageAnchor?
    @State var islandPresentation: ChatIslandPresentation?
    @State var islandHoldToken = 0
    @State var composerInputController = ComposerInputController()
    @State var chatListSummary = ChatListSummarySnapshot()
    @State var artifactShelf = ChatArtifactShelfState()
    /// 产物架索引的正文图片与生成式 UI 解析缓存；引用类型，命中与淘汰不触发视图刷新。
    @State var artifactContentCache = ConversationArtifactContentCache()
    @State private var artifactShelfDismissRevision = 0
    @State private var dockTapRegions = ChatDockTapRegions()
    @State var artifactShelfStripHeight: CGFloat = 0
    @State private var messageEditDraft: ChatMessageEditDraft?
    @State private var pendingDeleteMessageId: String?
    @Environment(IOSConversationStore.self)  var conversationStore
    @Environment(ConversationActivityCenter.self) private var conversationActivityCenter
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
        webMountController: IOSWebMountController = .shared
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
    }

    private var chatContent: some View {
        ZStack {
            AmberThemePageBackground(surface: .app)
            messageList
                .safeAreaBar(edge: .top, spacing: 0) {
                    Color.clear
                        .frame(height: ChatTopBarLayout.controlsHeight + ChatTopBarLayout.softEdgeExtension + artifactShelfStripHeight)
                        .allowsHitTesting(false)
                }

            if let record = compactWebMountSession {
                VStack {
                    Spacer()
                    AgentBrowserTaskCompactBar(
                        record: record,
                        runSummary: viewModel.isGenerationActiveForCurrentConversation
                            ? chatListSummary.browserTaskTitleCandidate
                            : nil,
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
            if viewportState.showScrollToBottom && chatListSummary.hasMessages {
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

            // Tap-outside scrim for the attachment glass panel.
            if composerState.isAttachExpanded {
                Color.black.opacity(0.06)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.bouncy(duration: 0.38, extraBounce: 0.1)) {
                            composerState.isAttachExpanded = false
                        }
                    }
                    .transition(.opacity)
            }
            // 面板需要参与正文区域命中测试，不能挂在仅顶栏高度的 safeAreaBar 内。
            topBar.zIndex(20)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(width: proxy.size.width,
                   height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
        } action: { chatSize = $0 }
        .animation(browserTaskVisibilityAnimation, value: compactWebMountSession?.id)
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
                    composerState.subAgentActivityBarHeight = height
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $messageEditDraft) { draft in
            ChatMessageEditSheet(draft: draft) { messageId, newText in
                viewModel.editMessage(messageId: messageId, newText: newText)
                messageEditDraft = nil
            } onCancel: {
                messageEditDraft = nil
            }
        }
        .sheet(isPresented: $browserState.showWebMountDesktopBackends, onDismiss: {
            browserState.focusedRemoteWebMountSessionId = nil
        }) {
            WebMountDesktopBackendsView(
                controller: webMountController,
                focusedSessionId: browserState.focusedRemoteWebMountSessionId
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $attachmentPickerState.isCameraPresented) {
            CameraPicker { image in
                if let image { handleCameraImageSelection(image) }
                else { attachmentPickerState.cameraPickerConversationId = nil }
                attachmentPickerState.isCameraPresented = false
            }
            .ignoresSafeArea()
        }
    }

    var body: some View {
        GeometryReader { proxy in
            chatContent
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Measure the parent's proposal, before the bottom inset can grow to its ideal height.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if abs(composerState.approvalContainerHeight - height) > 0.5 { composerState.approvalContainerHeight = height }
        }
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
            // Observe taps alongside the existing controls/scroll views; do not
            // place a full-screen hit-test layer over the timeline.
            if dockTapRegions.isPanelOpen, !dockTapRegions.contains(tap.location) {
                artifactShelfDismissRevision &+= 1
            }
        })
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
        refreshChatListSummary(
            resetTitleSeed: signal.event == .conversationLoaded ||
                signal.event == .conversationSwitched ||
                signal.event == .branchChanged
        )
        // 后台内容若在本轮前台生成期间落盘,门控当时跳过且未消费;收尾时补查上屏。
        switch signal.event {
        case .generationCompleted, .generationFailed, .generationCancelled:
            handleBackgroundContentLanded()
        default:
            break
        }
    }

    private func handleComposerFocusStarted() {
        // Composer focus is a direct navigation intent: the user is preparing to type
        // at the tail. Do not depend on ChatListSummary here; during first session
        // entry that summary can lag behind the message list by one render pass.
        scrollToBottomSource = .composerFocus
        scrollToBottomTrigger &+= 1
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
    private func openSubAgentSourceConversation(_ sourceConversationId: String) async -> Bool {
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

    var topBar: some View {
        let generating = viewModel.isGenerationActive
        let recap = generating ? nil : currentRecap
        let recapLoading = !generating && (currentConversationIdString.map {
            conversationStore.recapGenerator.isLoading(for: $0)
        } ?? false)
        return ChatTopBarView(
            presentation: islandPresentation ?? .idle(topIslandState),
            conversationID: currentConversationIdString,
            hasMessages: chatListSummary.hasMessages,
            isGenerating: viewModel.isGenerationActive,
            notices: conversationActivityCenter.notices,
            shelfHeight: chatSize.height * 0.55,
            onBack: { router.goBack() },
            onIslandTap: handleIslandTap,
            onCancel: { viewModel.cancelGeneration() },
            onOpenConversation: openActivityConversation,
            onDismiss: { conversationActivityCenter.dismiss(conversationId: $0) },
            onNewConversation: { Task { await viewModel.startNewConversation() } },
            loadPreview: { id in
                guard let message = await conversationActivityCenter.lastMessage(conversationId: id) else { return nil }
                return message.toText().nilIfBlank
            },
            previewRevision: { id in
                conversationStore.allSummaries.first(where: { $0.id.toHexDashString() == id })
                    .map { String(describing: $0.updateAt) }
            },
            artifacts: artifactShelf.index,
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
            onRecapNextStep: fillRecapNextStep
        )
        .onAppear { syncIslandPresentation() }
        .onChange(of: topIslandState) { _, _ in syncIslandPresentation() }
    }

    private var pendingUserGateRequestID: String? {
        [viewModel.pendingAskUser?.id, viewModel.pendingMemoryApproval?.id,
         viewModel.pendingSearchApproval?.id, viewModel.pendingWebMountApproval?.id,
         viewModel.pendingWorkspaceApproval?.id, viewModel.pendingIshHandoffApproval?.id,
         viewModel.pendingMcpApproval?.id, viewModel.pendingCouncilApproval?.id,
         viewModel.pendingRecipeApproval?.id, viewModel.pendingToolOutcomeUnknown?.toolCallId]
            .compactMap { $0 }.first
    }

    private func handleIslandTap(_ presentation: ChatIslandPresentation) {
        guard let conversationID = currentConversationIdString else { return }
        switch ChatIslandNavigation.target(
            for: presentation, conversationID: conversationID, messages: viewModel.messages,
            pendingRequestID: pendingUserGateRequestID, requestToken: UUID()
        ) {
        case .none: break
        case .bottom:
            scrollToBottomSource = .button
            scrollToBottomTrigger &+= 1
        case .anchor(let anchor):
            requestedMessageAnchor = anchor
        case .pendingGate:
            guard viewModel.hasPendingUserGate else { return }
            dismissKeyboard()
            composerState.gateHighlightRequest = UUID()
        }
    }

    private func openActivityConversation(_ id: String) async -> Bool {
        let opened = await openSubAgentSourceConversation(id)
        conversationActivityCenter.didOpenConversation(
            id: id, succeeded: opened, isTranscript: opened && currentConversationIdString != id
        )
        if !opened && conversationStore.lastUserVisibleError == nil {
            conversationStore.publishUserVisibleError(IOSUserVisibleError(
                title: "无法打开对话", message: "该对话已不存在或暂时无法读取。", severity: .warning
            ))
        }
        return opened
    }

    var topIslandState: ChatActivityIslandState {
        // 等待用户永远最先：审批/问答暂停时，岛同步停下来等。
        if viewModel.hasPendingUserGate {
            return ChatActivityIslandState.activity(
                kind: .awaitingUser,
                title: IOSAppLocalization.string("等待确认", defaultValue: "等待确认"),
                detail: viewModel.pendingAskUser != nil
                    ? IOSAppLocalization.string("回答问题", defaultValue: "回答问题")
                    : (viewModel.pendingToolOutcomeUnknown != nil
                        ? IOSAppLocalization.string("确认操作结果", defaultValue: "确认操作结果")
                        : IOSAppLocalization.string("工具审批", defaultValue: "工具审批")),
                systemImage: "checkmark.circle",
                tint: .amber,
                toolID: pendingUserGateRequestID
            )
        }

        if viewModel.isBackgroundGenerationWaitingForForegroundResume {
            return ChatActivityIslandState.activity(
                kind: .waiting,
                title: IOSAppLocalization.string("正在恢复", defaultValue: "正在恢复"),
                detail: IOSAppLocalization.string(
                    "正在检查可安全恢复方式",
                    defaultValue: "正在检查可安全恢复方式"
                ),
                systemImage: "arrow.triangle.2.circlepath",
                tint: .amber
            )
        }

        if let step = chatListSummary.activeToolStep {
            return ChatActivityIslandState.activity(
                kind: step.visualKind.isImageTool ? .image : .tool,
                title: compactIslandText(step.title, limit: 18),
                detail: step.detail.map { compactIslandText($0, limit: 20) },
                systemImage: step.systemImage,
                tint: islandTint(for: step),
                toolID: step.id
            )
        }

        if viewModel.isRecognizingImages {
            return ChatActivityIslandState.activity(
                kind: .image,
                title: IOSAppLocalization.string("识别图片", defaultValue: "识别图片"),
                detail: viewModel.visionRecognitionImageCount > 1
                    ? IOSAppLocalization.formatted(
                        "共 %lld 张",
                        defaultValue: "共 %lld 张",
                        arguments: [Int64(viewModel.visionRecognitionImageCount)]
                    ) : nil,
                systemImage: "viewfinder",
                tint: .cyan
            )
        }

        if chatListSummary.awaitingFirstAssistantChunk {
            return ChatActivityIslandState.activity(
                kind: .waiting,
                title: IOSAppLocalization.string("正在连接", defaultValue: "正在连接"),
                detail: viewModel.islandModelDisplayName,
                systemImage: "sparkles",
                tint: .amber
            )
        }

        if viewModel.isGenerationActive {
            if chatListSummary.lastAssistantHasOpenReasoning {
                return ChatActivityIslandState.activity(
                    kind: .thinking,
                    title: IOSAppLocalization.string("正在思考", defaultValue: "正在思考"),
                    systemImage: "brain.head.profile",
                    tint: .amber
                )
            }
            return ChatActivityIslandState.activity(
                kind: .generating,
                title: IOSAppLocalization.string("正在生成回复", defaultValue: "正在生成回复"),
                systemImage: "text.bubble",
                tint: .accent
            )
        }

        return .conversationTitle(conversationTitleForIsland)
    }

    // MARK: - Message List

    private var messageList: some View {
        let _ = artifactPinHandler.action = pinArtifactSnippet
        return ChatTimelineSignalHost(viewModel: viewModel, onSignalChange: handleMessageUpdateSignal) { signal in
            NativeChatTimelineView(
                signal: signal,
                configurationIssue: configurationIssue,
                isGenerationActive: viewModel.isGenerationActive,
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
            .id(NativeChatTimelineSessionIdentity.viewID(conversationId: conversationStore.currentConversation?.id))
        }
    }

    var isStreamingFollowActive: Bool {
        viewModel.isGenerationActive || viewModel.isLoading
    }

    /// Forcefully dismiss the keyboard. Clears the SwiftUI focus binding and also resigns the
    /// UIKit first responder directly — the latter guarantees dismissal even if the focus
    /// binding alone does not take effect.
    func dismissKeyboard() {
        composerState.isInputFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private func applyCollectionViewportState(_ newState: ChatViewportState) {
        guard viewportState != newState else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            viewportState = newState
        }
    }

    private func handleChatListAction(_ action: ChatListAction) {
        switch action {
        case let .regenerate(messageId):
            viewModel.regenerate(messageId: messageId)
        case let .requestEdit(messageId, currentText):
            messageEditDraft = ChatMessageEditDraft(messageId: messageId, text: currentText)
        case let .edit(messageId, newText):
            viewModel.editMessage(messageId: messageId, newText: newText)
        case let .delete(messageId):
            pendingDeleteMessageId = messageId
        case let .selectVariant(messageId, variantIndex):
            viewModel.selectVariant(messageId: messageId, variantIndex: variantIndex)
        case let .generativeWidget(prompt):
            guard !viewModel.isGenerationActive else { return }
            viewModel.inputText = prompt
            viewportState.followPaused = false
            viewModel.sendMessage(startsGenerationAfterInsertion: true)
        case let .modifyGeneratedImage(urlString, prompt, aspectRatio):
            guard !viewModel.isGenerationActive else { return }
            viewportState.followPaused = false
            viewModel.modifyGeneratedImage(
                sourceImageURL: urlString,
                prompt: prompt,
                aspectRatio: aspectRatio
            )
        case let .openMiniApp(appId):
            router.navigate(to: .miniAppRunner(appId: appId))
        case .openMiniApps:
            router.navigate(to: .miniApps)
        case let .openSubagentConversation(id):
            router.navigate(to: .subAgentConversation(id: id))
        case .primaryConfiguration:
            openPrimaryConfigurationAction()
        case .modelDefaults:
            openModelDefaults()
        }
    }

    private func openPrimaryConfigurationAction() {
        switch configurationIssue {
        case .some(.missingModel):
            openModelDefaults()
        case .some(.missingAPIKey), .some(.invalidBaseURL), .some(.missingProvider),
             .some(.unsupportedProvider), .some(.codexNotSignedIn), .some(.grokNotSignedIn),
             .some(.geminiNotSignedIn), .some(.providerDisabled), .none:
            router.navigate(to: .providers)
        }
    }

    private func openModelDefaults() {
        router.navigate(to: .modelDefaults)
    }

    @discardableResult
    private func repairCurrentChatModelIfNeeded() -> Bool {
        sharedSettings.repairCurrentChatModelIfNeeded(settingsStore)
    }

    func popoverBinding(for panel: ComposerPanel) -> Binding<Bool> {
        Binding(
            get: { composerState.activeComposerPanel == panel },
            set: { isPresented in
                if isPresented {
                    composerState.activeComposerPanel = panel
                } else if composerState.activeComposerPanel == panel {
                    composerState.activeComposerPanel = nil
                }
            }
        )
    }
}
