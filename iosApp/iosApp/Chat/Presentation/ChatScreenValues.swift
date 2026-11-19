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
    var lastMessageIsAssistant = false
    var messageIDsBeforeLatestUser: Set<String> = []

    mutating func updateTimelineAnchors(from messages: [UIMessage]) {
        lastMessageID = messages.last.map(ChatMessageProjector.messageId(for:))
        lastMessageIsAssistant = messages.last?.role == MessageRole.assistant
        let lastUserIndex = messages.lastIndex {
            $0.role == MessageRole.user && ChatMessageProjector.isConversationMessage($0)
        } ?? messages.startIndex
        messageIDsBeforeLatestUser = Set(messages[..<lastUserIndex].map(ChatMessageProjector.messageId(for:)))
    }

    func timelineActivityAnchor(rawAnchor: String, hasAssistant: Bool, isTargetedFollowup: Bool) -> (messageID: String, hasAssistant: Bool) {
        if !isTargetedFollowup, messageIDsBeforeLatestUser.contains(rawAnchor), let lastMessageID {
            return (lastMessageID, lastMessageIsAssistant)
        }
        return (rawAnchor, hasAssistant)
    }

    /// 当前会话的回顾分支标识（依赖 `conversation.messageNodes` 的 variant 选择，
    /// 不依赖消息内容），随会话切换 / 分支变化刷新。
    var recapBranchID = ""
    var inChatActiveTaskCount = 0
    var inChatNeedsAttentionCount = 0

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
            lhs.lastMessageIsAssistant == rhs.lastMessageIsAssistant &&
            lhs.messageIDsBeforeLatestUser == rhs.messageIDsBeforeLatestUser &&
            lhs.recapBranchID == rhs.recapBranchID &&
            lhs.inChatActiveTaskCount == rhs.inChatActiveTaskCount &&
            lhs.inChatNeedsAttentionCount == rhs.inChatNeedsAttentionCount &&
            lhs.activeToolStep?.id == rhs.activeToolStep?.id &&
            lhs.activeToolStep?.title == rhs.activeToolStep?.title &&
            lhs.activeToolStep?.detail == rhs.activeToolStep?.detail &&
            lhs.activeToolStep?.state == rhs.activeToolStep?.state &&
            lhs.activeToolStep?.systemImage == rhs.activeToolStep?.systemImage &&
            lhs.activeToolStep?.visualKind == rhs.activeToolStep?.visualKind &&
            lhs.failedToolStep?.id == rhs.failedToolStep?.id
    }
}

/// Keeps the counts and grouped task segments used by the chat chrome independent of repeated body evaluations.
@MainActor
final class ChatTaskCountCache {
    struct Counts: Equatable {
        var active = 0
        var needsAttention = 0
    }

    private struct Entry {
        let identity: ChatMessageContentIdentity
        let isGeneratingTail: Bool
        let counts: Counts
        let taskGroups: [ChatTaskRunSegment]
    }

    private var entries: [String: Entry] = [:]
    private(set) var latestTaskSegments: [ChatTaskRunSegment] = []

    func counts(messages: [UIMessage], isGenerationActive: Bool) -> Counts {
        refresh(messages: messages, isGenerationActive: isGenerationActive).counts
    }

    func taskSegments(messages: [UIMessage], isGenerationActive: Bool) -> [ChatTaskRunSegment] {
        refresh(messages: messages, isGenerationActive: isGenerationActive).segments
    }

    private func refresh(messages: [UIMessage], isGenerationActive: Bool) -> (counts: Counts, segments: [ChatTaskRunSegment]) {
        let lastID = messages.last.map(ChatMessageProjector.messageId(for:))
        var retainedIDs: Set<String> = []
        var total = Counts()
        var collectedGroups: [ChatTaskRunSegment] = []
        for message in messages where message.role == MessageRole.assistant {
            let id = ChatMessageProjector.messageId(for: message)
            retainedIDs.insert(id)
            let isTail = isGenerationActive && id == lastID
            let entry: Entry
            if let cached = entries[id], cached.isGeneratingTail == isTail,
               cached.identity.matches(message) {
                entry = cached
            } else {
                var next = Counts()
                var groups: [ChatTaskRunSegment] = []
                if message.parts.contains(where: { $0 is UIMessagePart.Tool }) {
                    let segments = ChatTaskStreamGrouping.segments(
                        for: message, messageID: id, isGeneratingTail: isTail
                    )
                    for case .taskGroup(let group) in segments where group.hasTools {
                        groups.append(group)
                        if group.rollupState.isLive { next.active += 1 }
                        if group.rollupState.isFailureOrNeedsUser { next.needsAttention += 1 }
                    }
                }
                entry = Entry(
                    identity: ChatMessageContentIdentity(message),
                    isGeneratingTail: isTail,
                    counts: next,
                    taskGroups: groups
                )
                entries[id] = entry
            }
            total.active += entry.counts.active
            total.needsAttention += entry.counts.needsAttention
            if !entry.taskGroups.isEmpty {
                collectedGroups.append(contentsOf: entry.taskGroups)
            }
        }
        if entries.count != retainedIDs.count {
            entries = entries.filter { retainedIDs.contains($0.key) }
        }
        let reversed = Array(collectedGroups.reversed())
        latestTaskSegments = reversed
        return (total, reversed)
    }
}

struct ChatMessageEditSheet: View {
    static let horizontalOuterPadding: CGFloat = 16
    static let topOuterPadding: CGFloat = 12
    static let bottomOuterPadding: CGFloat = 16
    static let editorHorizontalInnerPadding: CGFloat = 10
    static let editorVerticalInnerPadding: CGFloat = 6
    static let defaultMaxEditorHeight: CGFloat = 320
    private static let navigationHeaderHeight: CGFloat = 56

    let messageId: String
    private let initialDraftText: String
    let onSubmit: (String, String) -> Void
    let onCancel: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var text: String
    @State private var containerWidth: CGFloat = 393

    init(
        draft: ChatMessageEditDraft,
        onSubmit: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.messageId = draft.messageId
        self.initialDraftText = draft.text
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self._text = State(initialValue: draft.text)
    }

    static func editorHeight(
        for text: String,
        availableWidth: CGFloat = 393,
        dynamicTypeSize: DynamicTypeSize = .large,
        maxEditorHeight: CGFloat = defaultMaxEditorHeight
    ) -> CGFloat {
        let category = UIContentSizeCategory(dynamicTypeSize)
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let lineHeight = ceil(font.lineHeight)
        let minHeight = max(84, ceil(lineHeight * 3.0 + 24))
        let effectiveMaxHeight = max(minHeight + lineHeight * 2, maxEditorHeight)

        let textTrackWidth = max(
            120,
            availableWidth - (horizontalOuterPadding * 2) - (editorHorizontalInnerPadding * 2) - 10
        )
        let sample = text.isEmpty ? " " : (text.hasSuffix("\n") ? text + " " : text)
        let measured = (sample as NSString).boundingRect(
            with: CGSize(width: textTrackWidth, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
        let paddedHeight = ceil(measured + (editorVerticalInnerPadding * 2) + 16)
        return min(max(paddedHeight, minHeight), effectiveMaxHeight)
    }

    static func preferredSheetHeight(
        for text: String,
        availableWidth: CGFloat = 393,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> CGFloat {
        let editorH = editorHeight(
            for: text,
            availableWidth: availableWidth,
            dynamicTypeSize: dynamicTypeSize
        )
        let total = navigationHeaderHeight + topOuterPadding + editorH + bottomOuterPadding + 8
        return min(max(ceil(total), 184), 440)
    }

    static func presentationDetents(
        for text: String,
        availableWidth: CGFloat = 393,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> Set<PresentationDetent> {
        let fitted = preferredSheetHeight(
            for: text,
            availableWidth: availableWidth,
            dynamicTypeSize: dynamicTypeSize
        )
        return [.height(fitted), .medium, .large]
    }

    private var currentEditorHeight: CGFloat {
        Self.editorHeight(
            for: text,
            availableWidth: containerWidth,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $text)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, Self.editorHorizontalInnerPadding)
                    .padding(.vertical, Self.editorVerticalInnerPadding)
                    .frame(height: currentEditorHeight, alignment: .top)
                    .background(
                        AmberTheme.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AmberTheme.borderSoft, lineWidth: 0.8)
                    }
                    .accessibilityIdentifier("chat.messageEdit.editor")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.horizontalOuterPadding)
            .padding(.top, Self.topOuterPadding)
            .padding(.bottom, Self.bottomOuterPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                if newWidth > 0, abs(newWidth - containerWidth) > 0.5 {
                    containerWidth = newWidth
                }
            }
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
        .onChange(of: initialDraftText) { _, newValue in
            if text != newValue {
                text = newValue
            }
        }
        .presentationDetents(
            Self.presentationDetents(
                for: text,
                availableWidth: containerWidth,
                dynamicTypeSize: dynamicTypeSize
            )
        )
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
        let signal = viewModel.timelineStructuralSignal
        content(signal)
            .onReceive(viewModel.timelineUpdates.signals, perform: onSignalChange)
    }
}

