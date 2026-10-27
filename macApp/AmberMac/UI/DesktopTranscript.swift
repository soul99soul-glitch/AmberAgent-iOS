import AppKit
import SwiftUI

struct DesktopTranscriptFocus: Equatable {
    let id = UUID()
    let conversationID: UUID
    let messageID: UUID
}

struct DesktopTranscript: View {
    let conversation: DesktopConversation
    @Bindable var workspace: DesktopWorkspace
    let focusRequest: DesktopTranscriptFocus?
    @State private var editingMessage: MessageEditDraft?
    @State private var confirmation: MessageConfirmation?

    private var mutationsDisabled: Bool {
        workspace.isLoading || workspace.isGenerating || workspace.isMutatingBranch
    }

    private struct MessageEditDraft: Identifiable {
        let id: UUID
        let ownerID: UUID
        let text: String
        let followingCount: Int
    }

    private enum MessageConfirmation: Identifiable {
        case regenerate(UUID, ownerID: UUID, followingCount: Int)
        case delete(UUID, ownerID: UUID, variants: Int)

        var id: UUID {
            switch self { case .regenerate(let id, _, _), .delete(let id, _, _): id }
        }
    }
    @State private var followsBottom = true
    @State private var userScrolling = false
    @State private var nearBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    ForEach(conversation.messages) { message in
                        DesktopMessageRow(message: message, settings: workspace.settings, speech: workspace.speech, mutationsDisabled: mutationsDisabled,
                            onEdit: { editingMessage = MessageEditDraft(id: message.id, ownerID: conversation.id,
                                text: message.textForEditing, followingCount: followingCount(after: message.id)) },
                            onRegenerate: { requestRegeneration(message) },
                            onDelete: { confirmation = .delete(message.id, ownerID: conversation.id, variants: message.variantCount) },
                            onSelectVariant: { workspace.selectVariant(message.id, index: $0) })
                            .id(message.id)
                    }
                    if !mutationsDisabled, let last = conversation.messages.last, last.role == .assistant,
                       last.state == .cancelled || last.state == .failed {
                        Button("重新生成", systemImage: "arrow.clockwise") { workspace.retry() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("retry-generation")
                    }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }
                .frame(maxWidth: DesktopTheme.contentWidth)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 80
            } action: { _, value in
                nearBottom = value
                if userScrolling { followsBottom = value && workspace.settings.automaticallyFollowGeneration }
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating
                if phase == .interacting { followsBottom = false }
                if phase == .idle, nearBottom { followsBottom = workspace.settings.automaticallyFollowGeneration }
            }
            .onChange(of: conversation.messages.last?.text) {
                if followsBottom, workspace.settings.automaticallyFollowGeneration { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .onChange(of: conversation.messages.last?.reasoning) {
                if followsBottom, workspace.settings.automaticallyFollowGeneration { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .onChange(of: conversation.messages.count) {
                if followsBottom, workspace.settings.automaticallyFollowGeneration { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .onChange(of: conversation.id, initial: true) {
                if let focusRequest, focusRequest.conversationID == conversation.id {
                    followsBottom = false
                    proxy.scrollTo(focusRequest.messageID, anchor: .center)
                } else {
                    followsBottom = workspace.settings.automaticallyFollowGeneration
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
            .onChange(of: focusRequest) { _, request in
                guard let request, request.conversationID == conversation.id else { return }
                followsBottom = false
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(request.messageID, anchor: .center) }
            }
            .onChange(of: workspace.settings.automaticallyFollowGeneration) { _, enabled in
                followsBottom = enabled && nearBottom
            }
            .overlay(alignment: .bottomTrailing) {
                if !nearBottom {
                    Button {
                        followsBottom = workspace.settings.automaticallyFollowGeneration
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down").frame(width: 32, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                    .help("回到最新消息")
                    .accessibilityLabel("回到最新消息")
                    .padding(18)
                }
            }
        }
        .accessibilityIdentifier("conversation-transcript")
        .sheet(item: $editingMessage) { draft in
            DesktopMessageEditor(initialText: draft.text, followingCount: draft.followingCount,
                canSubmit: !mutationsDisabled && workspace.selectedID == draft.ownerID) { text in
                    guard workspace.selectedID == draft.ownerID else { return "请回到原会话后重试。" }
                    return await withCheckedContinuation { continuation in
                        workspace.editAndResend(draft.id, text: text) { succeeded in
                            continuation.resume(returning: succeeded ? nil
                                : workspace.conversationError(for: draft.ownerID) ?? "消息修改未保存，请检查配置与磁盘后重试。")
                        }
                    }
                }
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                if let confirmation {
                    switch confirmation {
                    case .regenerate(let id, let ownerID, _):
                        Button("移除后续消息并重新生成", role: .destructive) { workspace.regenerate(id) }
                            .disabled(mutationsDisabled || workspace.selectedID != ownerID)
                    case .delete(let id, let ownerID, _):
                        Button("删除消息", role: .destructive) { workspace.deleteMessage(id) }
                            .disabled(mutationsDisabled || workspace.selectedID != ownerID)
                    }
                }
                Button("取消", role: .cancel) { confirmation = nil }
            } message: {
                Text(confirmationDetail)
            }
    }

    private func followingCount(after messageID: UUID) -> Int {
        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return 0 }
        return conversation.messages.count - index - 1
    }

    private func requestRegeneration(_ message: DesktopMessage) {
        let count = followingCount(after: message.id)
        if count > 0 { confirmation = .regenerate(message.id, ownerID: conversation.id, followingCount: count) }
        else { workspace.regenerate(message.id) }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .regenerate: "重新生成这条回复？"
        case .delete: "删除这条消息？"
        case nil: ""
        }
    }

    private var confirmationDetail: String {
        switch confirmation {
        case .regenerate(_, _, let count):
            "这条回复之后的 \(count) 条消息将被移除。当前回复会保留为另一个版本。"
        case .delete(_, _, let variants):
            variants > 1 ? "这条消息的全部 \(variants) 个版本将被删除，其他消息会保留。" : "这条消息将被删除，其他消息会保留。"
        case nil: ""
        }
    }
}

private struct DesktopMessageRow: View {
    let message: DesktopMessage
    let settings: DesktopSettings
    let speech: DesktopSpeechPlayer
    let mutationsDisabled: Bool
    let onEdit: () -> Void
    let onRegenerate: () -> Void
    let onDelete: () -> Void
    let onSelectVariant: (Int) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var reasoningExpanded = false
    @State private var copied = false
    @State private var speechError: String?

    init(message: DesktopMessage, settings: DesktopSettings, speech: DesktopSpeechPlayer, mutationsDisabled: Bool,
         onEdit: @escaping () -> Void, onRegenerate: @escaping () -> Void,
         onDelete: @escaping () -> Void, onSelectVariant: @escaping (Int) -> Void) {
        self.message = message; self.settings = settings; self.speech = speech; self.mutationsDisabled = mutationsDisabled
        self.onEdit = onEdit; self.onRegenerate = onRegenerate; self.onDelete = onDelete
        self.onSelectVariant = onSelectVariant
        _reasoningExpanded = State(initialValue: settings.reasoningExpandedByDefault)
    }

    private var roleTitle: String {
        switch message.role {
        case .user: settings.userDisplayName
        case .assistant: settings.assistantDisplayName
        case .system: "系统"
        case .tool: "工具"
        }
    }

    private var roleSymbol: String {
        switch message.role {
        case .user: "person.crop.circle"
        case .assistant: "sparkle"
        case .system: "gearshape"
        case .tool: "wrench.and.screwdriver"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: roleSymbol)
                    .foregroundStyle(message.role == .user ? Color.secondary : DesktopTheme.accent)
                    .font(.system(size: 13, weight: .medium))
                Text(roleTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(roleTitle)
                if message.state == .streaming {
                    ProgressView().controlSize(.mini)
                    Text("正在生成").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !message.text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DesktopTheme.muted(scheme))
                    .help(copied ? "已复制" : "复制消息")
                    .accessibilityLabel("复制消息")
                }
                Menu {
                    messageActions
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(DesktopTheme.muted(scheme))
                .menuIndicator(.hidden)
                .fixedSize()
                .help(mutationsDisabled ? "生成或保存完成后可更改消息" : "消息操作")
                .accessibilityLabel("\(roleTitle)的消息操作")
            }
            if !message.reasoning.isEmpty {
                DisclosureGroup(isExpanded: $reasoningExpanded) {
                    Text(message.reasoning)
                        .font(settings.messageFontFamily.swiftUIFont(size: max(12, settings.messageFontSize - 2)))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                } label: {
                    Label("思考过程", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
                }
            }
            if message.role == .user, !message.text.isEmpty {
                Text(message.text)
                    .font(settings.messageFontFamily.swiftUIFont(size: settings.messageFontSize))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !message.text.isEmpty {
                DesktopMarkdown(text: message.text, fontFamily: settings.messageFontFamily, fontSize: settings.messageFontSize)
            } else if message.state == .streaming {
                Text("正在等待回复…").font(.callout).foregroundStyle(.secondary)
            }
            if !message.images.isEmpty {
                ForEach(Array(message.images.enumerated()), id: \.offset) { _, image in
                    DesktopMessageImageView(source: image)
                }
            }
            if message.unsupportedPartCount > 0 {
                Label("另有 \(message.unsupportedPartCount) 项内容暂未显示，原始数据已保留。", systemImage: "tray.full")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if message.variantCount > 1 {
                HStack(spacing: 6) {
                    Button { onSelectVariant(message.variantIndex - 1) } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 28)
                    }
                    .disabled(mutationsDisabled || message.variantIndex == 0)
                    .help("上一个版本，保留其他消息")
                    .accessibilityLabel("上一个消息版本")
                    Text("\(message.variantIndex + 1) / \(message.variantCount)")
                        .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("第 \(message.variantIndex + 1) 个版本，共 \(message.variantCount) 个")
                    Button { onSelectVariant(message.variantIndex + 1) } label: {
                        Image(systemName: "chevron.right").frame(width: 28, height: 28)
                    }
                    .disabled(mutationsDisabled || message.variantIndex + 1 >= message.variantCount)
                    .help("下一个版本，保留其他消息")
                    .accessibilityLabel("下一个消息版本")
                }
                .buttonStyle(.borderless)
            }
            if message.state == .cancelled || message.state == .failed {
                let hasContent = !message.text.isEmpty || !message.reasoning.isEmpty || !message.images.isEmpty || message.unsupportedPartCount > 0
                Label(message.state == .cancelled ? (hasContent ? "已停止，已保留生成内容" : "已停止，可重新生成") : "生成未完成，可重试", systemImage: message.state == .cancelled ? "stop.circle" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(message.role == .user ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? DesktopTheme.surface(scheme) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.leading, message.role == .user ? 40 : 0)
        .onChange(of: message.text) { copied = false }
        .contextMenu { messageActions }
        .alert("无法朗读", isPresented: Binding(get: { speechError != nil }, set: { if !$0 { speechError = nil } })) {
            Button("好", role: .cancel) { speechError = nil }
        } message: { Text(speechError ?? "") }
    }

    private var messageActions: some View {
        DesktopMessageActionItems(message: message, speech: speech, mutationsDisabled: mutationsDisabled,
            onEdit: onEdit, onRegenerate: onRegenerate, onDelete: onDelete,
            onSpeechError: { speechError = $0 })
    }
}
