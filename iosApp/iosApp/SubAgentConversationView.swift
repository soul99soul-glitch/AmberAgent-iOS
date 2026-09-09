import SwiftUI
@preconcurrency import Shared

/// A transcript viewer only: loading a child never replaces the main chat's
/// selected conversation or takes ownership of its foreground/background run.
struct SubAgentConversationView: View {
    let conversationId: String
    let sharedSettings: IOSSharedSettingsStore
    let workspaceStore: IOSWorkspaceStore

    @Environment(IOSConversationStore.self) private var conversationStore
    @Environment(RouterPath.self) private var router
    @State private var messages: [UIMessage] = []
    @State private var signal = ChatMessageUpdateSignal()
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var retryRevision = 0
    @State private var actionError: IOSUserVisibleError?
    @State private var viewport = ChatViewportState()
    @State private var bottomTrigger = 0

    private var summary: ConversationSummary? {
        conversationStore.allSummaries.first {
            $0.id.toHexDashString().caseInsensitiveCompare(conversationId) == .orderedSame
        }
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
                    onDismissKeyboard: {}
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
                Text("此页仅供查看，任务和上下文由主代理派发。")
            }
            .font(.caption)
            .foregroundStyle(AmberTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AmberTheme.background)
        }
        .navigationTitle("子代理会话")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar(.visible, for: .navigationBar)
        .task(id: refreshKey) { await loadMessages() }
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
                title: "请在主会话继续", message: "这个页面用于查看编排记录，追加任务请交给主代理。", severity: .info
            )
        }
    }
}
