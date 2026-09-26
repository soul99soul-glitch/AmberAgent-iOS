import SwiftUI
@preconcurrency import Shared

/// Child transcript route: loading a child never replaces the main chat's
/// selected conversation or takes ownership of its foreground/background run.
struct SubAgentConversationView: View {
    let conversationId: String
    let sharedSettings: IOSSharedSettingsStore
    let workspaceStore: IOSWorkspaceStore
    let chatViewModel: ChatViewModel?

    @Environment(IOSConversationStore.self) private var conversationStore
    @Environment(ConversationActivityCenter.self) private var conversationActivityCenter: ConversationActivityCenter?
    @Environment(RouterPath.self) private var router
    @State private var messages: [UIMessage] = []
    @State private var signal = ChatMessageUpdateSignal()
    @State private var isLoading = true
    @State private var isVisible = false
    @State private var loadError: String?
    @State private var retryRevision = 0
    @State private var actionError: IOSUserVisibleError?
    @State private var viewport = ChatViewportState()
    @State private var bottomTrigger = 0
    @State private var followupText = ""
    @State private var isSubmittingFollowup = false
    @State private var followupStatus: String?
    @State private var followupInputHeight: CGFloat = 40
    @State private var followupFieldFocused = false
    @State private var followupInputController = ComposerInputController()

    init(
        conversationId: String,
        sharedSettings: IOSSharedSettingsStore,
        workspaceStore: IOSWorkspaceStore,
        chatViewModel: ChatViewModel? = nil
    ) {
        self.conversationId = conversationId
        self.sharedSettings = sharedSettings
        self.workspaceStore = workspaceStore
        self.chatViewModel = chatViewModel
    }

    private var summary: ConversationSummary? {
        conversationStore.allSummaries.first {
            $0.id.toHexDashString().caseInsensitiveCompare(conversationId) == .orderedSame
        }
    }

    private var canSubmitFollowup: Bool {
        !isSubmittingFollowup && !followupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var refreshKey: String {
        "\(conversationId)|\(summary?.updateAt.toEpochMilliseconds() ?? 0)|\(conversationStore.backgroundContentRevision)|\(retryRevision)"
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            if let loadError, messages.isEmpty {
                ContentUnavailableView {
                    Label("无法打开会话", systemImage: "bubble.left")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("重试") { retryRevision &+= 1 }
                        .disabled(isLoading)
                }
            } else if isLoading && messages.isEmpty {
                ProgressView("正在读取会话…")
            } else {
                NativeChatTimelineView(
                    signal: signal,
                    configurationIssue: nil,
                    isGenerationActive: false,
                    isLoading: false,
                    isRecognizingImages: false,
                    contextCompactState: .idle,
                    followGeneration: !viewport.followPaused,
                    displaySetting: sharedSettings.displaySetting,
                    generativeUiSetting: sharedSettings.agentRuntime.generativeUi,
                    reasoningLevelLabel: nil,
                    workspaceStore: workspaceStore,
                    scrollToBottomTrigger: bottomTrigger,
                    scrollToBottomSource: .button,
                    messageAnchor: nil,
                    currentConversationID: conversationId,
                    messagesProvider: { messages },
                    variantInfoProvider: { _ in nil },
                    onAction: handleAction,
                    onViewportStateChange: { viewport = $0 },
                    onDismissKeyboard: {
                        if let committedText = followupInputController.committedText() {
                            followupText = committedText
                        }
                        followupInputController.textView?.resignFirstResponder()
                        followupFieldFocused = false
                    }
                )
                .environment(\.chatMessageEditingAllowed, false)
                .overlay(alignment: .bottomTrailing) {
                    if viewport.showScrollToBottom {
                        Button { bottomTrigger &+= 1 } label: {
                            Image(systemName: "arrow.down").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("查看最新消息")
                        .padding(16)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let loadError, !messages.isEmpty {
                    HStack(alignment: .center, spacing: 12) {
                        Text(loadError).frame(maxWidth: .infinity, alignment: .leading)
                        Button("重试") { retryRevision &+= 1 }
                            .frame(minWidth: 44, minHeight: 44)
                            .disabled(isLoading)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        ComposerInputTextView(
                            text: $followupText,
                            height: $followupInputHeight,
                            isFocused: $followupFieldFocused,
                            isEnabled: !isSubmittingFollowup,
                            sendOnEnter: true,
                            controller: followupInputController,
                            onSubmit: submitFollowup
                        )
                        .frame(height: max(40, followupInputHeight))
                        .accessibilityLabel(
                            IOSAppLocalization.string(
                                "给子代理追加任务",
                                defaultValue: "给子代理追加任务"
                            )
                        )
                        if followupText.isEmpty {
                            Text("给子代理追加任务")
                                .font(.body)
                                .foregroundStyle(AmberTheme.muted)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.leading, 8)

                    Button(action: submitFollowup) {
                        ZStack {
                            Circle()
                                .fill(canSubmitFollowup || isSubmittingFollowup ? AmberTheme.accent : AmberTheme.surface2)
                            if isSubmittingFollowup {
                                ProgressView()
                                    .tint(AmberTheme.accentInk)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(canSubmitFollowup ? AmberTheme.accentInk : AmberTheme.muted)
                            }
                        }
                        .frame(width: 36, height: 36)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                    }
                    .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.94, haptic: .selection))
                    .accessibilityLabel(
                        IOSAppLocalization.string(
                            "给子代理追加任务",
                            defaultValue: "给子代理追加任务"
                        )
                    )
                    .disabled(!canSubmitFollowup)
                }
                .padding(6)
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(followupFieldFocused ? AmberTheme.accent.opacity(0.45) : AmberTheme.border, lineWidth: 1)
                }
                .animation(.easeInOut(duration: 0.16), value: followupFieldFocused)
                .animation(.easeInOut(duration: 0.16), value: canSubmitFollowup)
                if let followupStatus {
                    Text(followupStatus)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .padding(.horizontal, 14)
                }
                Text("追加任务会在子代理当前工作轮结束后继续执行。")
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
            .font(.caption)
            .foregroundStyle(AmberTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(AmberTheme.background)
            .overlay(alignment: .top) {
                Rectangle().fill(AmberTheme.borderSoft).frame(height: 0.5)
            }
        }
        .navigationTitle("子代理会话")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { isVisible = true }
        .task(id: refreshKey) { await loadMessages() }
        .onDisappear {
            isVisible = false
            conversationActivityCenter?.transcriptConversationDidDisappear(id: conversationId)
        }
        .alert(item: $actionError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("好")))
        }
    }

    @MainActor
    private func loadMessages() async {
        isLoading = true
        guard let uuid = UUID(uuidString: conversationId) else {
            loadError = "会话标识无效。"
            isLoading = false
            return
        }
        let id = KotlinUuid.companion.parse(uuidString: uuid.uuidString.lowercased())
        let loaded: [UIMessage]?
        do {
            loaded = try await conversationStore.loadConversationForOrchestration(id)?.currentMessages as? [UIMessage]
        } catch {
            guard !Task.isCancelled else { return }
            isLoading = false
            loadError = "读取会话失败：\(error.localizedDescription)"
            return
        }
        guard !Task.isCancelled else { return }
        isLoading = false
        guard let loaded else {
            loadError = "这段会话已被删除或暂时不可用。"
            return
        }
        if isVisible {
            conversationActivityCenter?.didOpenConversation(
                id: conversationId, succeeded: true, isTranscript: true
            )
        }
        loadError = nil
        let next = loaded.filter { $0.role != MessageRole.system }
        guard next != messages else { return }
        let initial = messages.isEmpty
        messages = next
        signal = ChatMessageUpdateSignal(revision: signal.revision + 1,
                                         reason: initial ? .initialLoad : .toolResultAppended)
    }

    private func handleAction(_ action: ChatListAction) {
        switch action {
        case .openMiniApp(let id): router.navigate(to: .miniAppRunner(appId: id))
        case .openMiniApps: router.navigate(to: .miniApps)
        case .openSubagentConversation(let id): router.navigate(to: .subAgentConversation(id: id))
        default:
            actionError = IOSUserVisibleError(
                title: "请在主会话继续", message: "这个操作请返回主会话完成。", severity: .info
            )
        }
    }

    private func submitFollowup() {
        guard !isSubmittingFollowup else { return }
        // Read the native text view before changing focus or disabling it so a
        // CJK marked-text composition is committed instead of losing its last
        // syllable from the SwiftUI binding.
        let committedDraft = followupInputController.committedText() ?? followupText
        let text = committedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let chatViewModel else {
            actionError = IOSUserVisibleError(
                title: "无法追加任务", message: "主代理运行时不可用，请返回会话后重试。", severity: .error
            )
            return
        }
        guard let uuid = UUID(uuidString: conversationId) else {
            actionError = IOSUserVisibleError(
                title: "无法追加任务", message: "子代理会话标识无效。", severity: .error
            )
            return
        }

        if followupText != committedDraft {
            followupText = committedDraft
        }
        followupFieldFocused = false
        isSubmittingFollowup = true
        followupStatus = nil
        Task { @MainActor in
            defer { isSubmittingFollowup = false }
            let childId = KotlinUuid.companion.parse(uuidString: uuid.uuidString.lowercased())
            let rawResult = await chatViewModel.appendTaskToSubAgent(
                conversationId: childId,
                message: text
            )
            let payload = rawResult.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            guard let payload, payload["ok"] as? Bool == true else {
                let reason = payload?["reason"] as? String
                    ?? "子代理没有接受这项追加任务，请重试。"
                actionError = IOSUserVisibleError(
                    title: "追加任务失败", message: reason, severity: .error
                )
                return
            }
            if followupText == committedDraft {
                followupText = ""
            }
            followupStatus = (payload["status"] as? String) == "queued"
                ? IOSAppLocalization.string(
                    "已加入队列，子代理会在当前工作轮结束后继续。",
                    defaultValue: "已加入队列，子代理会在当前工作轮结束后继续。"
                )
                : IOSAppLocalization.string(
                    "已启动追加任务。",
                    defaultValue: "已启动追加任务。"
                )
            await loadMessages()
        }
    }
}
