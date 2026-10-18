import SwiftUI
import Shared
import UIKit
import UniformTypeIdentifiers
import PhotosUI

struct SiteMemoryApprovalLayoutSignal: Equatable {
    let requestID: String?
    let availableHeight: CGFloat
    let minimumHeight: CGFloat
}

enum ComposerPanel: String, Identifiable {
    case thinking
    case context

    var id: String { rawValue }
}

struct ChatListSummarySnapshot: Equatable {
    var hasMessages = false
    var awaitingFirstAssistantChunk = false
    var lastAssistantHasOpenReasoning = false
    var firstUserTitleSeed: String?
    var activeToolStep: ChatToolStepModel?
    var failedToolStep: ChatToolStepModel?
    var webMountRecentUserTurnStartMillis: Int64?
    var browserTaskTitleCandidate: String?
    /// 当前分支的消息 ID：产物架据此过滤可见收藏。流式追加不改变集合，
    /// 因而不会让根视图随每个 chunk 重算。
    var messageIDs: Set<String> = []
    /// 符合回顾口径（`ChatMessageProjector.isConversationMessage`）的 user 消息数，
    /// 与 `ConversationRecapLogic.eligible` 判据一致，供 topBar 免读 `viewModel.messages`。
    var userMessageCount = 0
    /// 最后一条消息的稳定 id，与 `ConversationRecapLogic.isStale` 判据一致。
    var lastMessageID: String?
    /// 当前会话的回顾分支标识（依赖 `conversation.messageNodes` 的 variant 选择，
    /// 不依赖消息内容），随会话切换 / 分支变化刷新。
    var recapBranchID = ""

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
            lhs.messageIDs == rhs.messageIDs &&
            lhs.userMessageCount == rhs.userMessageCount &&
            lhs.lastMessageID == rhs.lastMessageID &&
            lhs.recapBranchID == rhs.recapBranchID &&
            lhs.activeToolStep?.id == rhs.activeToolStep?.id &&
            lhs.activeToolStep?.title == rhs.activeToolStep?.title &&
            lhs.activeToolStep?.detail == rhs.activeToolStep?.detail &&
            lhs.activeToolStep?.state == rhs.activeToolStep?.state &&
            lhs.activeToolStep?.systemImage == rhs.activeToolStep?.systemImage &&
            lhs.activeToolStep?.visualKind == rhs.activeToolStep?.visualKind &&
            lhs.failedToolStep?.id == rhs.failedToolStep?.id
    }
}

struct ChatMessageEditSheet: View {
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

struct ChatMessageEditDraft: Identifiable {
    let messageId: String
    var text: String

    var id: String { messageId }
}

@MainActor
struct ChatContextControl: View {
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

struct ChatTimelineSignalHost<Content: View>: View {
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

