import SwiftUI
import Shared
import UIKit
import UniformTypeIdentifiers
import PhotosUI

enum ChatTopBarLayout {
    static let controlsHeight: CGFloat = 54
    static let toolbarButtonDiameter: CGFloat = 38
    /// 每侧保留 44pt 命中区和 12pt 间距，鼓动后的岛也不能进入按钮区域。
    static let islandSideGutter: CGFloat = 56
    static func availableIslandWidth(in width: CGFloat) -> CGFloat {
        min(islandMaxWidth, max(0, width - islandSideGutter * 2) / 1.06)
    }
    /// Design max width for the activity / mode capsule shell.
    static let islandMaxWidth: CGFloat = 268
    /// Max title text width inside the island (shell − horizontal pad − optional orb).
    static let islandTitleMaxWidth: CGFloat = 200
    /// 顶栏 `safeAreaBar` 在控件下方的透明延伸，驱动原生 soft edge 几何。
    /// 模拟器会把 soft edge 画满整段 bar（易显「模糊带偏长」）；真机 Liquid Glass 更短。
    /// 取小延伸：盖住按钮下沿即可，避免 Simulator 上大面积雾带。
    static let softEdgeExtension: CGFloat = 8
}

private enum ComposerPanel: String, Identifiable {
    case thinking
    case context

    var id: String { rawValue }
}

private struct ChatListSummarySnapshot: Equatable {
    var hasMessages = false
    var awaitingFirstAssistantChunk = false
    var lastAssistantHasOpenReasoning = false
    var firstUserTitleSeed: String?
    var activeToolStep: ChatToolStepModel?
    var failedToolStep: ChatToolStepModel?
    var webMountRecentUserTurnStartMillis: Int64?
    var browserTaskTitleCandidate: String?

    // 手写 == 只比较 UI 使用的字段。activeToolStep 的流式 tool output 不参与比较，
    // 避免每个 chunk 刷新根视图；稳定 id 保留给活动岛终态匹配。WebMount 摘要仅在
    // 卡片展示值或会话保留边界变化时触发更新。
    static func == (lhs: ChatListSummarySnapshot, rhs: ChatListSummarySnapshot) -> Bool {
        lhs.hasMessages == rhs.hasMessages &&
            lhs.awaitingFirstAssistantChunk == rhs.awaitingFirstAssistantChunk &&
            lhs.lastAssistantHasOpenReasoning == rhs.lastAssistantHasOpenReasoning &&
            lhs.firstUserTitleSeed == rhs.firstUserTitleSeed &&
            lhs.webMountRecentUserTurnStartMillis == rhs.webMountRecentUserTurnStartMillis &&
            lhs.browserTaskTitleCandidate == rhs.browserTaskTitleCandidate &&
            lhs.activeToolStep?.id == rhs.activeToolStep?.id &&
            lhs.activeToolStep?.title == rhs.activeToolStep?.title &&
            lhs.activeToolStep?.detail == rhs.activeToolStep?.detail &&
            lhs.activeToolStep?.state == rhs.activeToolStep?.state &&
            lhs.activeToolStep?.systemImage == rhs.activeToolStep?.systemImage &&
            lhs.activeToolStep?.visualKind == rhs.activeToolStep?.visualKind &&
            lhs.failedToolStep?.id == rhs.failedToolStep?.id
    }
}

private struct ChatMessageEditSheet: View {
    let messageId: String
    let onSubmit: (String, String) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(
        draft: ChatMessageEditDraft,
        onSubmit: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.messageId = draft.messageId
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self._text = State(initialValue: draft.text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .padding(8)
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(16)
                .navigationTitle("编辑消息")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("发送") {
                            onSubmit(messageId, text)
                        }
                        .disabled(trimmedText.isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
        .presentationBackground(.regularMaterial)
        .presentationCornerRadius(30)
        .presentationContentInteraction(.resizes)
        .scrollDismissesKeyboard(.interactively)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ChatMessageEditDraft: Identifiable {
    let messageId: String
    var text: String

    var id: String { messageId }
}

@MainActor
private struct ChatContextControl: View {
    let viewModel: ChatViewModel
    @Binding var isPresented: Bool
    let jevSummaryRunId: String?
    let onOpen: () -> Void

    var body: some View {
        let snapshot = viewModel.contextSnapshot
        ContextRingButton(
            snapshot: snapshot,
            compactState: viewModel.contextCompactState,
            action: onOpen
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ComposerContextPanel(
                snapshot: snapshot,
                jevRunSummary: jevSummaryRunId.map { IOSJevMetricsStore.runSummary(runId: $0) }
            )
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct ChatTimelineSignalHost<Content: View>: View {
    let viewModel: ChatViewModel
    let onSignalChange: (ChatMessageUpdateSignal) -> Void
    let content: (ChatMessageUpdateSignal) -> Content

    init(
        viewModel: ChatViewModel,
        onSignalChange: @escaping (ChatMessageUpdateSignal) -> Void,
        @ViewBuilder content: @escaping (ChatMessageUpdateSignal) -> Content
    ) {
        self.viewModel = viewModel
        self.onSignalChange = onSignalChange
        self.content = content
    }

    var body: some View {
        let signal = viewModel.messageUpdateSignal
        content(signal)
            .onChange(of: signal, perform: onSignalChange)
    }
}

struct ChatView: View {

    let settingsStore: SettingsStore
    let sharedSettings: IOSSharedSettingsStore
    let documentStore: DocumentAccessStore?
    let workspaceStore: IOSWorkspaceStore
    let activityStore: IOSSubAgentActivityStore
    let initialMessageAnchor: ChatMessageAnchor?
    @State private var viewModel: ChatViewModel
    @State private var activeComposerPanel: ComposerPanel?
    @State private var observedJevSummaryRunIds: [String: String] = [:]
    @State private var isModelSheetPresented = false
    @State private var isImportingSelectedFile = false
    @State private var isAttachExpanded = false
    @State private var isCameraPresented = false
    @State private var cameraPickerConversationId: String?
    @State private var imageAttachmentTask: Task<Void, Never>?
    @State private var isPhotoPickerPresented = false
    @State private var showWebMountDesktopBackends = false
    @State private var focusedRemoteWebMountSessionId: String?
    @State private var collapsedWebMountSessionId: String?
    @State private var expandedWebMountSessionId: String?
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var personalContextPicker = IOSPersonalContextPickerCoordinator.shared
    @State private var personalContextPhotoItems: [PhotosPickerItem] = []
    @State private var personalContextPhotoLoadID: UUID?
    @State private var fileImporterConversationId: String?
    @State private var isProcessingSelectedFile = false
    @State private var photoPickerConversationId: String?
    @State private var isInputFocused = false
    @Environment(RouterPath.self) private var router
    @AppStorage(IOSDisplayPreferenceKeys.followGeneration) private var followGeneration = true
    @State private var viewportState = ChatViewportState()
    @State private var scrollToBottomTrigger = 0
    @State private var scrollToBottomSource: NativeTimelineBottomIntentSource = .button
    @State private var chatSize: CGSize = .zero
    @State private var requestedMessageAnchor: ChatMessageAnchor?
    @State private var gateHighlightRequest: UUID?
    @State private var islandPresentation: ChatIslandPresentation?
    @State private var islandHoldToken = 0
    @State private var composerInputHeight: CGFloat = 40
    @State private var composerBarHeight: CGFloat = 0
    @State private var isSubAgentBarVisible = false
    @State private var composerInputController = ComposerInputController()
    @State private var chatListSummary = ChatListSummarySnapshot()
    @State private var artifactShelf = ChatArtifactShelfState()
    @State private var artifactShelfDismissRevision = 0
    @State private var artifactShelfStripHeight: CGFloat = 0
    @State private var messageEditDraft: ChatMessageEditDraft?
    @State private var pendingDeleteMessageId: String?
    @Environment(IOSConversationStore.self) private var conversationStore
    @Environment(ConversationActivityCenter.self) private var conversationActivityCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(
        settingsStore: SettingsStore,
        sharedSettings: IOSSharedSettingsStore = IOSSharedSettingsStore(),
        localToolExecutor: IOSLocalToolExecutor? = nil,
        documentStore: DocumentAccessStore? = nil,
        workspaceStore: IOSWorkspaceStore = .shared,
        viewModel: ChatViewModel? = nil,
        initialMessageAnchor: ChatMessageAnchor? = nil,
        activityStore: IOSSubAgentActivityStore = .shared
    ) {
        self.settingsStore = settingsStore
        self.sharedSettings = sharedSettings
        self.documentStore = documentStore
        self.workspaceStore = workspaceStore
        self.activityStore = activityStore
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
                .simultaneousGesture(TapGesture().onEnded { artifactShelfDismissRevision &+= 1 })

            if let record = compactWebMountSession {
                VStack {
                    Spacer()
                    AgentBrowserTaskCompactBar(
                        record: record,
                        runSummary: viewModel.isGenerationActiveForCurrentConversation
                            ? chatListSummary.browserTaskTitleCandidate
                            : nil,
                        onExpand: {
                            collapsedWebMountSessionId = nil
                            expandedWebMountSessionId = record.id
                        }
                    )
                    .padding(.horizontal, ChatLayout.contentHorizontalInset)
                    .padding(.bottom, max(10, composerBarHeight + 8))
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
            if isAttachExpanded {
                Color.black.opacity(0.06)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.bouncy(duration: 0.38, extraBounce: 0.1)) {
                            isAttachExpanded = false
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
            expandedWebMountSessionId = nil
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
                    isInputFocused: isInputFocused,
                    activityStore: activityStore,
                    onOpenSource: { sourceConversationId in
                        await openSubAgentSourceConversation(sourceConversationId)
                    }
                )
                .onGeometryChange(for: Bool.self) { $0.size.height > 0 } action: { visible in
                    isSubAgentBarVisible = visible
                }

                // 不再强制 light:原生 `.glassEffect` 本就按系统外观渲染(深色模式下渲染为深色玻璃),
                // 若把内容强制成 light,前景图标/文字会按浅色调色板解析成深灰,贴在深色玻璃上发暗。
                // 让 composer 跟随真实外观(与顶栏一致),图标与玻璃明暗才匹配。
                inputBar
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: ChatComposerHeightPreferenceKey.self, value: proxy.size.height)
                        }
                    }
            }
        }
        .onPreferenceChange(ChatComposerHeightPreferenceKey.self) { height in
            guard abs(composerBarHeight - height) > 0.5 else { return }
            composerBarHeight = height
        }
        .sheet(isPresented: $isModelSheetPresented) {
            ComposerModelSheet(sharedSettings: sharedSettings, currentModel: composerCurrentModelSelection) { model in
                sharedSettings.setCurrentAssistantChatModelId(model.id)
                sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
                viewModel.reasoningLevel = sharedSettings.currentAssistantReasoningLevel()
                viewModel.bumpMessageRevision(reason: .settingsRefresh)
                isModelSheetPresented = false
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
        .sheet(isPresented: $showWebMountDesktopBackends, onDismiss: {
            focusedRemoteWebMountSessionId = nil
        }) {
            WebMountDesktopBackendsView(
                controller: .shared,
                focusedSessionId: focusedRemoteWebMountSessionId
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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
            maxSelectionCount: ChatViewModel.maxImagesPerMessage,
            matching: .images
        )
        .onChange(of: photoPickerItems) { _, items in
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
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker { image in
                if let image { handleCameraImageSelection(image) }
                else { cameraPickerConversationId = nil }
                isCameraPresented = false
            }
            .ignoresSafeArea()
        }
    }

    var body: some View {
        chatContent
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
        .onChange(of: isInputFocused) { wasFocused, isFocused in
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

    private func handleSelectedFileImport(_ result: Result<[URL], Error>) {
        let selectionConversationId = fileImporterConversationId
        fileImporterConversationId = nil
        guard selectionConversationId == currentConversationIdString else { return }
        guard let documentStore else {
            viewModel.selectedFileContextError = IOSAppLocalization.string(
                "文件选择器未连接。",
                defaultValue: "文件选择器未连接。"
            )
            return
        }

        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                let message = IOSAppLocalization.string("没有选择文件。", defaultValue: "没有选择文件。")
                documentStore.recordSelectionError(message)
                viewModel.selectedFileContextError = message
                return
            }
            // A selected-file grant is singleton state. Keep this whole path
            // (grant -> Workspace copy -> preview attach) exclusive so a
            // second picker result cannot replace the grant mid-import.
            guard !isProcessingSelectedFile else { return }
            isProcessingSelectedFile = true
            let selectedGrant = documentStore.registerPickedFile(url)
            Task { @MainActor in
                defer { isProcessingSelectedFile = false }
                var workspaceImportError: String?
                do {
                    _ = try await workspaceStore.importFile(url: url, source: "chat_picker")
                } catch {
                    workspaceImportError = error.localizedDescription
                }
                guard selectionConversationId == currentConversationIdString else { return }
                await viewModel.attachSelectedFilePreviewToNextMessage(
                    expectedConversationId: selectionConversationId,
                    expectedFileScopeDigest: selectedGrant.scopeDigest
                )
                if let workspaceImportError, viewModel.selectedFileContextError == nil {
                    viewModel.selectedFileContextError = IOSAppLocalization.formatted(
                        "已附加到本条消息，但未保存到 Workspace：%@",
                        defaultValue: "已附加到本条消息，但未保存到 Workspace：%@",
                        arguments: [workspaceImportError]
                    )
                }
            }
        case .failure(let error):
            let message = IOSAppLocalization.formatted(
                "文件选择失败：%@",
                defaultValue: "文件选择失败：%@",
                arguments: [error.localizedDescription]
            )
            documentStore.recordSelectionError(message)
            viewModel.selectedFileContextError = message
        }
    }

    // MARK: - Attachment panel actions

    private func presentFileImporter() {
        guard !isProcessingSelectedFile else {
            viewModel.selectedFileContextError = "正在读取已选文件，请完成后再选择。"
            return
        }
        let selectionConversationId = currentConversationIdString
        if documentStore != nil {
            fileImporterConversationId = selectionConversationId
            isImportingSelectedFile = true
        } else {
            Task {
                await viewModel.attachSelectedFilePreviewToNextMessage(
                    expectedConversationId: selectionConversationId
                )
            }
        }
    }

    private func presentPhotosPicker() {
        photoPickerConversationId = currentConversationIdString
        isPhotoPickerPresented = true
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            viewModel.selectedFileContextError = IOSAppLocalization.string(
                "此设备不支持相机。",
                defaultValue: "此设备不支持相机。"
            )
            return
        }
        cameraPickerConversationId = currentConversationIdString
        isCameraPresented = true
    }

    private func handlePhotoPickerSelection(_ items: [PhotosPickerItem]) {
        let selectionConversationId = photoPickerConversationId
        photoPickerConversationId = nil
        guard !items.isEmpty else { return }
        let previousTask = imageAttachmentTask
        let task = Task { @MainActor in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            guard selectionConversationId == currentConversationIdString else {
                photoPickerItems = []
                return
            }
            var failedImageCount = 0
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
                guard selectionConversationId == currentConversationIdString else {
                    photoPickerItems = []
                    return
                }
                guard let encoded else {
                    failedImageCount += 1
                    continue
                }
                viewModel.addPendingImage(dataUrl: encoded.dataUrl, previewData: encoded.previewData)
            }
            photoPickerItems = []
            guard selectionConversationId == currentConversationIdString else { return }
            if failedImageCount > 0 {
                viewModel.selectedFileContextError = IOSAppLocalization.formatted(
                    "有 %lld 张图片处理失败。",
                    defaultValue: "有 %lld 张图片处理失败。",
                    arguments: [Int64(failedImageCount)]
                )
            }
        }
        imageAttachmentTask = task
    }

    private var currentConversationIdString: String? {
        viewModel.currentConversationId?.toHexDashString()
    }

    private var jevSummaryRunId: String? {
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

    private var activeWebMountSession: IOSWebMountSessionRecord? {
        guard let conversationId = currentConversationIdString else { return nil }
        let recentUserTurnStartMillis = chatListSummary.webMountRecentUserTurnStartMillis
        return IOSWebMountController.shared.sessionStore.records
            .filter { record in
                Self.webMountSessionIsRetained(
                    record,
                    conversationId: conversationId,
                    recentUserTurnStartMillis: recentUserTurnStartMillis
                ) &&
                    webMountSessionIsOpenable(record)
            }
            .max { $0.lastActivityMillis < $1.lastActivityMillis }
    }

    /// Card retention follows the same user-turn boundary as tool exposure.
    /// Agent rounds and retries update activity inside this window without
    /// creating another user message, so they do not consume a turn.
    static func webMountRecentUserTurnStartMillis(from messages: [UIMessage]) -> Int64? {
        messages.reversed()
            .filter { $0.role == MessageRole.user }
            // recentToolsForExposure scans assistant messages until it sees
            // the sixth user message. Use that same boundary so the session
            // used by the previous turn remains visible for all five next
            // user turns.
            .prefix(6)
            .last
            .flatMap { ChatContextSnapshot.epochMillis(from: $0.createdAt) }
    }

    static func webMountSessionIsRetained(
        _ record: IOSWebMountSessionRecord,
        conversationId: String,
        recentUserTurnStartMillis: Int64?
    ) -> Bool {
        guard record.ownerConversationId == conversationId, !record.cardHidden else { return false }
        return record.ownerRunId?.nilIfBlank != nil ||
            record.controlOwner == .user ||
            (recentUserTurnStartMillis.map { record.lastActivityMillis >= $0 } ?? false)
    }

    private var displayedWebMountSession: IOSWebMountSessionRecord? {
        guard let record = activeWebMountSession,
              viewModel.pendingWebMountApproval?.sessionId != record.id else { return nil }
        return record
    }

    private var compactWebMountSession: IOSWebMountSessionRecord? {
        guard !isAttachExpanded,
              let record = displayedWebMountSession,
              webMountSessionIsCompact(record) else { return nil }
        return record
    }

    private func webMountSessionIsCompact(_ record: IOSWebMountSessionRecord) -> Bool {
        collapsedWebMountSessionId == record.id ||
            (record.ownerRunId?.nilIfBlank == nil && record.controlOwner != .user && expandedWebMountSessionId != record.id)
    }

    private static func browserTaskTitleCandidate(messages: [UIMessage]) -> String? {
        guard let message = messages.last(where: ChatMessageProjector.isConversationMessage),
              message.role == MessageRole.assistant,
              let tool = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .last(where: { $0.toolName.hasPrefix("wm_") }) else { return nil }
        return ChatToolStepModel(tool: tool).title.nilIfBlank
    }

    private var scrollToBottomBottomPadding: CGFloat {
        max(10, composerBarHeight + 10 + (compactWebMountSession == nil ? 0 : 52))
    }

    private func webMountSessionIsOpenable(_ record: IOSWebMountSessionRecord) -> Bool {
        record.backend != .local ||
            WebMountSiteRoute(watching: record, registry: IOSWebMountController.shared.registry) != nil
    }

    private func webMountSessionAction(sessionId: String?) -> (() -> Void)? {
        guard let sessionId = sessionId?.nilIfBlank,
              let record = IOSWebMountController.shared.sessionStore.record(sessionId: sessionId) else {
            return nil
        }
        if !webMountSessionIsOpenable(record) {
            return nil
        }
        return { openWebMountSession(sessionId: sessionId) }
    }

    private func openWebMountSession(sessionId: String) {
        let controller = IOSWebMountController.shared
        guard let record = controller.sessionStore.record(sessionId: sessionId) else { return }
        if record.needsReopen {
            guard controller.sessionStore.reopen(sessionId: sessionId) != nil else {
                conversationStore.publishUserVisibleError(IOSUserVisibleError(
                    title: IOSAppLocalization.string(
                        "浏览器任务无法重新打开",
                        defaultValue: "浏览器任务无法重新打开"
                    ),
                    message: IOSAppLocalization.string(
                        "此会话已回收，当前无法创建新的页面；请先关闭其他浏览器会话后重试。",
                        defaultValue: "此会话已回收，当前无法创建新的页面；请先关闭其他浏览器会话后重试。"
                    ),
                    severity: .warning
                ))
                return
            }
        }
        controller.sessionStore.showCard(sessionId: sessionId)
        collapsedWebMountSessionId = nil
        expandedWebMountSessionId = sessionId
        if record.backend == .local {
            guard let route = WebMountSiteRoute(watching: record, registry: controller.registry) else { return }
            router.navigate(to: .webMountSite(site: route))
        } else {
            focusedRemoteWebMountSessionId = record.id
            Task { @MainActor in
                showWebMountDesktopBackends = true
            }
        }
    }

    private func handleCameraImageSelection(_ image: UIImage) {
        let selectionConversationId = cameraPickerConversationId
        cameraPickerConversationId = nil
        let previousTask = imageAttachmentTask
        let task = Task { @MainActor in
            await previousTask?.value
            guard !Task.isCancelled,
                  selectionConversationId == currentConversationIdString else { return }
            let encoded = await ChatImageEncoder.encodeOffMain(image)
            guard selectionConversationId == currentConversationIdString else { return }
            guard let encoded else {
                viewModel.selectedFileContextError = IOSAppLocalization.string(
                    "图片处理失败。",
                    defaultValue: "图片处理失败。"
                )
                return
            }
            viewModel.addPendingImage(dataUrl: encoded.dataUrl, previewData: encoded.previewData)
        }
        imageAttachmentTask = task
    }

    private var attachmentGlassPanel: some View {
        ComposerAttachmentGlassPanel(
            onCamera: presentCamera,
            onPhotos: presentPhotosPicker,
            onFiles: presentFileImporter,
            onDismiss: { isAttachExpanded = false }
        )
    }

    private var chatImageAttachmentStatus: ComposerAttachmentStatus? {
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

    private var topBar: some View {
        ChatTopBarView(
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
                ChatArtifactPinning.visibleSnippets(conversationStore.artifactStore.snippets(for: $0), messages: viewModel.messages)
            } ?? [],
            adoptedVersions: currentConversationIdString.map { conversationStore.artifactStore.adoptedVersions(for: $0) } ?? [:],
            conversationTitle: conversationStore.currentConversation?.title ?? "对话成果",
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
            onShelfStripHeightChange: { artifactShelfStripHeight = $0 }
        )
        .onAppear { syncIslandPresentation() }
        .onChange(of: topIslandState) { _, _ in syncIslandPresentation() }
    }

    private func updateArtifactShelf(_ action: (IOSConversationArtifactStore, String) throws -> Void) {
        guard let id = currentConversationIdString else { return }
        do {
            try action(conversationStore.artifactStore, id)
        } catch {
            showArtifactError(error.localizedDescription)
        }
    }

    private func pinArtifactSnippet(messageID: String, text: String, kind: ChatArtifactPinKind, codeLanguage: String?) {
        guard let snippet = ChatArtifactPinning.snippet(
            messageID: messageID, text: text, kind: kind, codeLanguage: codeLanguage, messages: viewModel.messages
        ) else {
            showArtifactError("原消息已不在当前分支中。")
            return
        }
        updateArtifactShelf { store, id in
            try store.pin(snippet, for: id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func continueFromArtifact(_ action: ChatArtifactContinuation) async -> Bool {
        guard !hasPendingComposerGate, !viewModel.currentConversationIsOrchestratedChild else {
            showArtifactError("当前对话暂不可输入，请先完成待处理操作。")
            return false
        }
        if let text = composerInputController.currentText() { viewModel.inputText = text }
        do {
            // 图片达到上限时由既有输入区错误提示说明，面板照常关闭以露出提示。
            try await ChatArtifactComposerSupport.apply(action, to: viewModel)
            isInputFocused = true
            return true
        } catch {
            showArtifactError(error.localizedDescription)
            return false
        }
    }

    private func showArtifactError(_ message: String) {
        conversationStore.publishUserVisibleError(IOSUserVisibleError(
            title: "产物架", message: message, severity: .error
        ))
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
            gateHighlightRequest = UUID()
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

    private var topIslandState: ChatActivityIslandState {
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

    private func refreshArtifactShelf(reason: ChatMessageUpdateReason) {
        let isReload = reason == .initialLoad || reason == .conversationSwitch || reason == .branchChange
        artifactShelf.update(
            ConversationArtifactIndex.make(from: viewModel.messages),
            conversationID: currentConversationIdString,
            isForegroundRunning: scenePhase == .active && viewModel.artifactUpdateWasRunning,
            allowArrival: !isReload
        )
    }

    private func refreshChatListSummary(resetTitleSeed: Bool = false) {
        let messages = viewModel.messages
        var next = chatListSummary
        next.hasMessages = !messages.isEmpty
        next.awaitingFirstAssistantChunk = isStreamingFollowActive && messages.last(where: ChatMessageProjector.isConversationMessage)?.role == MessageRole.user
        next.activeToolStep = activeToolStepForIsland(messages: messages)
        next.failedToolStep = failedToolStepForIsland(messages: messages)
        next.lastAssistantHasOpenReasoning = lastAssistantHasOpenReasoning(messages: messages)
        next.webMountRecentUserTurnStartMillis = Self.webMountRecentUserTurnStartMillis(from: messages)
        next.browserTaskTitleCandidate = Self.browserTaskTitleCandidate(messages: messages)
        if resetTitleSeed || next.firstUserTitleSeed == nil {
            next.firstUserTitleSeed = messages.first(where: { $0.role == MessageRole.user })?
                .toText()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if next != chatListSummary {
            chatListSummary = next
        }
    }

    private func activeToolStepForIsland(messages: [UIMessage]) -> ChatToolStepModel? {
        for message in messages.suffix(3).reversed() {
            let tools = message.parts.compactMap { $0 as? UIMessagePart.Tool }
            if let active = tools.reversed().first(where: { $0.output.isEmpty }) {
                return ChatToolStepModel(tool: active)
            }
        }
        return nil
    }

    /// 最近一个失败的工具（suffix(3) 窗口内）：输出含失败原因时才构造模型，
    /// 仅供岛在 active→idle 边缘匹配 terminalHold，不参与渲染。
    private func failedToolStepForIsland(messages: [UIMessage]) -> ChatToolStepModel? {
        for message in messages.suffix(3).reversed() {
            let tools = message.parts.compactMap { $0 as? UIMessagePart.Tool }
            if let failed = tools.reversed().first(where: {
                ChatToolOutputFormatter.analysis(for: $0).failureReason != nil
            }) {
                return ChatToolStepModel(tool: failed)
            }
        }
        return nil
    }

    /// 活动岛呈现的唯一入口：topIslandState 变化 → presentation（含 settle/terminalHold）。
    private func syncIslandPresentation() {
        let now = ProcessInfo.processInfo.systemUptime
        let previous = islandPresentation ?? .idle(topIslandState)
        let next = ChatIslandPresentationReducer.stateChanged(
            prev: previous,
            next: topIslandState,
            failedToolID: chatListSummary.failedToolStep?.id,
            now: now,
            reduceMotion: reduceMotion
        )
        guard next != previous else { return }
        islandPresentation = next
        guard let deadline = next.holdDeadline else { return }
        islandHoldToken &+= 1
        let token = islandHoldToken
        Task {
            try? await Task.sleep(for: .seconds(max(0, deadline - now)))
            guard !Task.isCancelled, token == islandHoldToken else { return }
            islandPresentation = ChatIslandPresentationReducer.timeout(
                prev: islandPresentation ?? .idle(topIslandState),
                now: ProcessInfo.processInfo.systemUptime
            )
        }
    }

    private func lastAssistantHasOpenReasoning(messages: [UIMessage]) -> Bool {
        guard let last = messages.last(where: ChatMessageProjector.isConversationMessage), last.role == MessageRole.assistant else { return false }
        return last.parts.contains { part in
            guard let reasoning = part as? UIMessagePart.Reasoning else { return false }
            return reasoning.finishedAt == nil
        }
    }

    private var conversationTitleForIsland: String {
        _ = conversationStore.currentRevision
        let storedTitle = conversationStore.currentConversation?.title
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !storedTitle.isEmpty {
            return storedTitle.replacingOccurrences(of: "\n", with: " ")
        }
        if let firstUserText = chatListSummary.firstUserTitleSeed,
           !firstUserText.isEmpty {
            return firstUserText.replacingOccurrences(of: "\n", with: " ")
        }
        return "Amber"
    }

    private func compactIslandText(_ raw: String, limit: Int) -> String {
        ChatActivityIslandMapping.compactText(raw, limit: limit)
    }

    private func islandTint(for step: ChatToolStepModel) -> ChatActivityIslandTint {
        switch step.state {
        case .failed:
            return .red
        case .done:
            return .green
        case .cancelled:
            return .neutral
        case .active:
            return step.visualKind.activeIslandTint
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ChatTimelineSignalHost(viewModel: viewModel, onSignalChange: handleMessageUpdateSignal) { signal in
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
            .environment(\.chatArtifactPinAction, pinArtifactSnippet)
            .id(NativeChatTimelineSessionIdentity.viewID(conversationId: conversationStore.currentConversation?.id))
        }
    }

    private var isStreamingFollowActive: Bool {
        viewModel.isGenerationActive || viewModel.isLoading
    }

    /// Forcefully dismiss the keyboard. Clears the SwiftUI focus binding and also resigns the
    /// UIKit first responder directly — the latter guarantees dismissal even if the focus
    /// binding alone does not take effect.
    private func dismissKeyboard() {
        isInputFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    // MARK: - Input Bar

    private var pendingUserGateCards: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let descriptor = viewModel.pendingToolOutcomeUnknown {
                ToolOutcomeUnknownCard(
                    descriptor: descriptor,
                    onDidApply: {
                        Task { await viewModel.reconcilePendingToolOutcome(didApply: true) }
                    },
                    onDidNotApply: {
                        Task { await viewModel.reconcilePendingToolOutcome(didApply: false) }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 增强 Phase E：审批分诊标签行——异步补充,缺失时审批卡与原样一致。
            if let triage = viewModel.jevApprovalTriage {
                JevApprovalTriageChips(triage: triage)
                    .transition(.opacity)
            }

            if let request = viewModel.pendingMemoryApproval {
                MemoryToolApprovalCard(
                    request: request,
                    onApprove: {
                        viewModel.approvePendingMemoryTool()
                    },
                    onDeny: {
                        viewModel.denyPendingMemoryTool()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = viewModel.pendingSearchApproval {
                SearchToolApprovalCard(
                    request: request,
                    onApprove: {
                        viewModel.approvePendingSearchTool()
                    },
                    onDeny: {
                        viewModel.denyPendingSearchTool()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = viewModel.pendingWebMountApproval {
                WebMountToolApprovalCard(
                    request: request,
                    onOpenSession: webMountSessionAction(sessionId: request.sessionId),
                    onApprove: {
                        viewModel.approvePendingWebMountTool(requestId: request.id)
                    },
                    onDeny: {
                        viewModel.denyPendingWebMountTool(requestId: request.id)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = viewModel.pendingWorkspaceApproval {
                WorkspaceToolApprovalCard(
                    request: request,
                    onApprove: {
                        viewModel.approvePendingWorkspaceTool()
                    },
                    onDeny: {
                        viewModel.denyPendingWorkspaceTool()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Group {
                if let request = viewModel.pendingIshHandoffApproval {
                    IshHandoffToolApprovalCard(
                        request: request,
                        onApprove: { scope in
                            viewModel.approvePendingIshHandoffTool(
                                requestId: request.id,
                                requestRunId: request.runId,
                                scope: scope
                            )
                        },
                        onDeny: {
                            viewModel.denyPendingIshHandoffTool(
                                requestId: request.id,
                                requestRunId: request.runId
                            )
                        }
                    )
                    .id(request.presentationId)
                    .transition(ishApprovalTransition)
                    .zIndex(2)
                }
            }
            .animation(
                ishApprovalVisibilityAnimation,
                value: viewModel.pendingIshHandoffApproval?.presentationId
            )

            if let request = viewModel.pendingMcpApproval {
                McpToolApprovalCard(
                    request: request,
                    onApprove: {
                        viewModel.approvePendingMcpTool(requestId: request.id)
                    },
                    onDeny: {
                        viewModel.denyPendingMcpTool(requestId: request.id)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = viewModel.pendingRecipeApproval {
                RecipeToolApprovalCard(
                    request: request,
                    onApprove: {
                        viewModel.approvePendingRecipeTool(requestId: request.id)
                    },
                    onDeny: {
                        viewModel.denyPendingRecipeTool(requestId: request.id)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = viewModel.pendingCouncilApproval {
                CouncilToolApprovalCard(
                    request: request,
                    onApprove: {
                        viewModel.approvePendingCouncilTool()
                    },
                    onDeny: {
                        viewModel.denyPendingCouncilTool()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let request = viewModel.pendingAskUser {
                ChatAskUserCard(
                    request: request,
                    onAnswer: { answer in
                        viewModel.answerPendingAskUser(answer)
                    },
                    onSkip: {
                        viewModel.skipPendingAskUser()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

        }
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge)
                .stroke(AmberTheme.accentAmber.opacity(gateHighlightRequest == nil ? 0 : 0.85), lineWidth: 2)
                .allowsHitTesting(false)
        }
        .task(id: gateHighlightRequest) {
            guard gateHighlightRequest != nil else { return }
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { gateHighlightRequest = nil }
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.hasPendingUserGate { pendingUserGateCards }

            if let record = displayedWebMountSession,
               !webMountSessionIsCompact(record) {
                AgentBrowserTaskCard(
                    record: record,
                    onCollapse: {
                        collapsedWebMountSessionId = record.id
                        expandedWebMountSessionId = nil
                    },
                    onHide: {
                        IOSWebMountController.shared.sessionStore.hideCard(sessionId: record.id)
                        collapsedWebMountSessionId = nil
                        expandedWebMountSessionId = nil
                    }
                ) {
                    openWebMountSession(sessionId: record.id)
                }
                .id(record.id)
                .transition(browserTaskTransition)
            }

            if !viewModel.pendingImages.isEmpty {
                ComposerPendingImageStrip(
                    items: viewModel.pendingImages.map {
                        .init(id: $0.id, previewData: $0.previewData)
                    },
                    onRemove: { viewModel.removePendingImage($0) },
                    status: chatImageAttachmentStatus
                )
            }

            if let preview = viewModel.pendingSelectedFilePreview {
                ComposerPendingFileCard(
                    fileName: preview.fileName,
                    byteSummary: preview.byteSummary,
                    isTruncated: preview.isTruncated,
                    footnote: IOSAppLocalization.string(
                        "发送后，已解析文本会保存进此会话上下文。",
                        defaultValue: "发送后，已解析文本会保存进此会话上下文。"
                    ),
                    onRemove: { viewModel.clearPendingSelectedFilePreview() }
                )
            }

            if let error = viewModel.selectedFileContextError {
                ComposerAttachmentStatusLabel(status: .error(error))
            }

            if viewModel.currentConversationIsOrchestratedChild,
               let message = ChatComposerSendBlockReason.orchestratedThread.userVisibleMessage {
                ComposerAttachmentStatusLabel(
                    status: .muted(message, systemImage: "arrow.triangle.branch")
                )
            }

            if let error = viewModel.configurationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentAmber)
                    .lineLimit(3)
            }

            if isAttachExpanded {
                attachmentGlassPanel
                    .transition(.scale(scale: 0.75, anchor: .bottomLeading).combined(with: .opacity))
            }

            if !viewModel.chatSuggestions.isEmpty, !viewModel.isGenerationActive {
                ChatSuggestionStrip(suggestions: viewModel.chatSuggestions) { suggestion in
                    viewModel.fillInputFromSuggestion(suggestion)
                    isInputFocused = true
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            VStack(spacing: 8) {
                    // P1-a: 排队条与整行 dock 同宽（右缘对齐发送键），空队列零占位。
                    if !viewModel.steerQueue.isEmpty {
                        ChatSteerQueueStrip(
                            entries: viewModel.steerQueue,
                            onRemove: { viewModel.removeSteerMessage(id: $0) }
                        )
                    }

                    // Apple Music dock：左侧输入胶囊 + 右侧发送键；底对齐。
                    HStack(alignment: .bottom, spacing: 8) {
                        HStack(alignment: .center, spacing: 6) {
                            ComposerAttachToggleButton(
                                isExpanded: isAttachExpanded,
                                isBusy: viewModel.isAttachingSelectedFile,
                                // 生成中允许加附件以便入队；识图中/审批中/读文件中仍禁用。
                                isDisabled: viewModel.isRecognizingImages
                                    || viewModel.isAttachingSelectedFile
                                    || hasPendingComposerGate
                                    || viewModel.currentConversationIsOrchestratedChild
                            ) {
                                withAnimation(.bouncy(duration: 0.42, extraBounce: 0.14)) {
                                    isAttachExpanded.toggle()
                                }
                            }

                            ZStack(alignment: .leading) {
                                ComposerInputTextView(
                                    text: $viewModel.inputText,
                                    height: $composerInputHeight,
                                    isFocused: inputFocusBinding,
                                    isEnabled: !hasPendingComposerGate
                                        && !viewModel.currentConversationIsOrchestratedChild,
                                    sendOnEnter: sharedSettings.displaySetting.sendOnEnter,
                                    controller: composerInputController,
                                    onSubmit: sendComposerMessage
                                )
                                .frame(height: composerInputHeight)

                                if viewModel.inputText.isEmpty {
                                    Text(inputPlaceholder)
                                        .font(.body)
                                        .foregroundStyle(AmberTheme.muted2)
                                        .allowsHitTesting(false)
                                }
                            }
                            .frame(minHeight: 40)
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 18)
                        .padding(.vertical, 5)
                        .composerDockGlass(cornerRadius: 27)

                        ComposerDockSendButton(
                            isLoading: isComposerStopMode,
                            sendEnabled: sendEnabled,
                            diameter: 54,
                            onSend: sendComposerMessage,
                            onStop: {
                                if viewModel.isRecognizingImages {
                                    viewModel.cancelVisionRecognition()
                                } else {
                                    viewModel.cancelGeneration()
                                }
                            }
                        )
                    }

                    if showsComposerMeta {
                        HStack {
                            Button {
                                openComposerModelSheet()
                            } label: {
                                Text(composerModelLabel)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.foreground2)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                                    .composerDockGlass(cornerRadius: 15)
                            }
                            .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.96, haptic: .selection))
                            .frame(minHeight: 44)
                            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .accessibilityLabel("切换模型，当前 \(composerModelLabel)")

                            Spacer()

                            HStack(spacing: 8) {
                                ComposerIconButton(
                                    koboyo: .solidThoughtCloud,
                                    accessibilityLabel: "设置思考等级",
                                    size: 34,
                                    symbolSize: 15
                                ) {
                                    toggleComposerPanel(.thinking)
                                }
                                .accessibilityValue(reasoningAccessibilityValue)
                                .popover(isPresented: popoverBinding(for: .thinking), arrowEdge: .bottom) {
                                    ComposerThinkingPanel(
                                        selectedOption: selectedReasoningBinding,
                                        options: availableReasoningOptions,
                                        isAvailable: reasoningIsAvailable
                                    ) { _ in activeComposerPanel = nil }
                                    .presentationCompactAdaptation(.popover)
                                }

                                ChatContextControl(
                                    viewModel: viewModel,
                                    isPresented: popoverBinding(for: .context),
                                    jevSummaryRunId: jevSummaryRunId,
                                    onOpen: { toggleComposerPanel(.context) }
                                )
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.top, 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
            }
        }
        .padding(.horizontal, ChatLayout.contentHorizontalInset)
        .padding(.top, isSubAgentBarVisible ? 4 : 8)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: showsComposerMeta)
        // 完成瞬间建议条插入会让 composer 长高一截：旧实现里转场动画只管建议条
        // 自己，时间轴可用高度一帧被吃掉 → 底部锚定内容跳一下。给建议条显隐加
        // 布局动画，高度连续变化，滚动层逐帧重锚，内容平滑上移。
        .animation(.easeOut(duration: 0.2), value: viewModel.chatSuggestions.isEmpty)
        .animation(browserTaskVisibilityAnimation, value: displayedWebMountSession?.id)
    }

    private var browserTaskTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 12))
                .combined(with: .scale(scale: 0.98, anchor: .bottom)),
            removal: .opacity
                .combined(with: .offset(y: 6))
                .combined(with: .scale(scale: 0.99, anchor: .bottom))
        )
    }

    private var browserTaskVisibilityAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
    }

    private var ishApprovalTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 10))
                .combined(with: .scale(scale: 0.985, anchor: .bottom)),
            removal: .opacity
                .combined(with: .offset(y: 4))
                .combined(with: .scale(scale: 0.995, anchor: .bottom))
        )
    }

    private var ishApprovalVisibilityAnimation: Animation? {
        if reduceMotion { return .easeOut(duration: 0.12) }
        if viewModel.pendingIshHandoffApproval == nil {
            return .easeIn(duration: 0.16)
        }
        return .timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
    }

    private var sendEnabled: Bool {
        sendEnabled(for: viewModel.inputText)
    }

    private func sendEnabled(for text: String) -> Bool {
        _ = sharedSettings.revision
        return viewModel.composerSendBlockReason(for: text) == nil
    }

    private func sendComposerMessage() {
        let committedText = composerInputController.committedText() ?? viewModel.inputText
        if committedText != viewModel.inputText {
            viewModel.inputText = committedText
        }
        guard sendEnabled(for: committedText) else { return }
        viewportState.followPaused = false
        viewModel.sendMessage()
    }

    private func openComposerModelSheet() {
        activeComposerPanel = nil
        if let currentText = composerInputController.currentText(),
           currentText != viewModel.inputText {
            viewModel.inputText = currentText
        }
        isModelSheetPresented = true
        Task { @MainActor in
            await Task.yield()
            dismissKeyboard()
        }
    }

    private var configurationIssue: ChatConfigurationIssue? {
        _ = sharedSettings.revision
        return viewModel.configurationIssue
    }

    private var inputPlaceholder: String {
        let key: String = switch configurationIssue {
        case .some(.missingAPIKey):
            "先添加 API Key"
        case .some(.invalidBaseURL):
            "先修正服务商地址"
        case .some(.missingModel):
            "先选择模型"
        case .some(.missingProvider):
            "先配置服务商"
        case .some(.unsupportedProvider):
            "先切换服务商"
        case .some(.codexNotSignedIn):
            "先登录 Codex"
        case .some(.grokNotSignedIn):
            "先登录 Grok"
        case .some(.geminiNotSignedIn):
            "先登录 Antigravity"
        case .some(.providerDisabled):
            "先启用服务商"
        case .none:
            "发消息给 Amber..."
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }

    private var hasPendingToolApproval: Bool {
        viewModel.pendingMemoryApproval != nil ||
            viewModel.pendingSearchApproval != nil ||
            viewModel.pendingWebMountApproval != nil ||
            viewModel.pendingWorkspaceApproval != nil ||
            viewModel.pendingIshHandoffApproval != nil ||
            viewModel.pendingMcpApproval != nil ||
            viewModel.pendingCouncilApproval != nil ||
            viewModel.pendingAskUser != nil ||
            viewModel.pendingRecipeApproval != nil
    }

    private var hasPendingComposerGate: Bool {
        hasPendingToolApproval || viewModel.pendingToolOutcomeUnknown != nil
    }

    private var isCurrentConversationRunActive: Bool {
        viewModel.isGenerationActiveForCurrentConversation ||
            hasPendingToolApproval ||
            viewModel.isLoading
    }

    /// P1-a: 生成中且有可入队内容（文本/图/文件）时，发送键翻转为「发送（加入队列）」；
    /// 无内容时保持「停止」。run 激活但发送被拦截（队列满）时保持停止键。
    private var isComposerStopMode: Bool {
        Self.composerSendButtonIsStopMode(
            isRunActive: isCurrentConversationRunActive,
            isRecognizingImages: viewModel.isRecognizingImages,
            hasSendableContent: hasComposerSendableContent,
            sendEnabled: sendEnabled
        )
    }

    static func composerSendButtonIsStopMode(
        isRunActive: Bool,
        isRecognizingImages: Bool,
        hasSendableContent: Bool,
        sendEnabled: Bool
    ) -> Bool {
        guard isRunActive || isRecognizingImages else { return false }
        if isRecognizingImages { return true }
        return !hasSendableContent || !sendEnabled
    }

    private var hasComposerSendableContent: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !viewModel.pendingImages.isEmpty
            || viewModel.pendingSelectedFilePreview != nil
    }

    private var showsComposerMeta: Bool {
        isInputFocused ||
            activeComposerPanel != nil ||
            isModelSheetPresented ||
            configurationIssue != nil
    }

    private var composerModelLabel: String {
        let modelId = composerCurrentModelID
        return modelId.isEmpty ? "未选择模型" : modelId
    }

    private var composerCurrentModelID: String {
        let modelId = sharedSettings.snapshot.getCurrentChatModel()?.modelId ?? settingsStore.modelId
        return modelId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var composerCurrentModelSelection: String {
        _ = sharedSettings.revision
        return sharedSettings.snapshot.getCurrentChatModel()?.id.description() ?? composerCurrentModelID
    }

    private var selectedReasoningOption: ComposerReasoningOption {
        _ = sharedSettings.revision
        return ComposerReasoningOption(reasoningLevel: sharedSettings.currentAssistantReasoningLevel())
    }

    private var availableReasoningOptions: [ComposerReasoningOption] {
        _ = sharedSettings.revision
        let options = sharedSettings.currentAssistantReasoningLevels().map(ComposerReasoningOption.init)
        var seen = Set<ComposerReasoningOption>()
        let unique = options.filter { seen.insert($0).inserted }
        return unique.isEmpty ? [.off] : unique
    }

    private var reasoningIsAvailable: Bool {
        availableReasoningOptions.contains { $0 != .off }
    }

    // Reasoning effort shown on the thinking pill (e.g. "Auto"); nil when reasoning is off.
    private var composerReasoningLabel: String? {
        let option = selectedReasoningOption
        guard option != .off else { return nil }
        return option.title
    }

    private var selectedReasoningBinding: Binding<ComposerReasoningOption> {
        Binding(
            get: { selectedReasoningOption },
            set: { option in
                sharedSettings.updateCurrentAssistantReasoningLevel(option.reasoningLevel)
                viewModel.reasoningLevel = sharedSettings.currentAssistantReasoningLevel()
            }
        )
    }

    private var inputFocusBinding: Binding<Bool> {
        Binding(
            get: { isInputFocused },
            set: { isInputFocused = $0 }
        )
    }

    private var reasoningAccessibilityValue: String {
        reasoningIsAvailable
            ? selectedReasoningOption.title
            : IOSAppLocalization.string(
                "当前模型未标记 Reasoning",
                defaultValue: "当前模型未标记 Reasoning"
            )
    }

    private func toggleComposerPanel(_ panel: ComposerPanel) {
        activeComposerPanel = activeComposerPanel == panel ? nil : panel
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
            viewModel.sendMessage()
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

    private func popoverBinding(for panel: ComposerPanel) -> Binding<Bool> {
        Binding(
            get: { activeComposerPanel == panel },
            set: { isPresented in
                if isPresented {
                    activeComposerPanel = panel
                } else if activeComposerPanel == panel {
                    activeComposerPanel = nil
                }
            }
        )
    }
}
