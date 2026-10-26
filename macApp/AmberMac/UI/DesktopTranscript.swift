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
    var findRequest = 0
    @Environment(\.colorScheme) private var scheme
    @State private var editingMessage: MessageEditDraft?
    @State private var findPresented = false
    @State private var findQuery = ""
    @State private var find = DesktopConversationFind()
    @FocusState private var findFocused: Bool
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
            VStack(spacing: 0) {
            if findPresented { findBar }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(conversation.messages) { message in
                        DesktopMessageRow(message: message, conversationID: conversation.id, settings: workspace.settings,
                            speech: workspace.speech, shelf: workspace.artifactShelf, mutationsDisabled: mutationsDisabled,
                            highlighted: findPresented && find.currentMessageID == message.id,
                            onExport: { DesktopFileActions.exportMessage(workspace, messageID: message.id) },
                            onEdit: { editingMessage = MessageEditDraft(id: message.id, ownerID: conversation.id,
                                text: message.textForEditing, followingCount: followingCount(after: message.id)) },
                            onRegenerate: { requestRegeneration(message) },
                            onDelete: { confirmation = .delete(message.id, ownerID: conversation.id, variants: message.variantCount) },
                            onSelectVariant: { workspace.selectVariant(message.id, index: $0) })
                            .modifier(DesktopRiseIn(enabled: message.id == conversation.messages.last?.id
                                || message.id == conversation.messages.dropLast().last?.id))
                            .modifier(DesktopStreamingEdge(active: message.state == .streaming))
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
                .padding(.top, 32)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
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
                reveal(request.messageID, proxy: proxy)
            }
            .onChange(of: find.currentMessageID) { _, id in
                if findPresented, let id { reveal(id, proxy: proxy) }
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
        }
        .onChange(of: findRequest) {
            findPresented = true
            findFocused = true
        }
        .onChange(of: findQuery) { updateFind() }
        .onChange(of: conversation.messages) { if findPresented { updateFind() } }
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

    private var findBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("在会话中查找", text: $findQuery)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onKeyPress(keys: [.return]) { press in
                    find.step(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onExitCommand(perform: closeFind)
                .accessibilityIdentifier("conversation-find")
            if !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(find.label).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel(find.matches.isEmpty ? "没有匹配的消息" : "第 \(find.label) 条匹配消息")
            }
            Button { find.step(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(find.matches.isEmpty)
                .help("上一个 ⇧Return")
                .accessibilityLabel("上一个匹配")
            Button { find.step(1) } label: { Image(systemName: "chevron.down") }
                .disabled(find.matches.isEmpty)
                .help("下一个 Return")
                .accessibilityLabel("下一个匹配")
            Button(action: closeFind) { Image(systemName: "xmark.circle.fill") }
                .help("关闭查找 Esc")
                .accessibilityLabel("关闭查找")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DesktopTheme.raised(scheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.border(scheme)))
        .frame(maxWidth: DesktopTheme.contentWidth)
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private func updateFind() { find.update(findQuery, messages: conversation.messages) }

    private func closeFind() {
        findPresented = false
        findFocused = false
    }

    private func reveal(_ messageID: UUID, proxy: ScrollViewProxy) {
        followsBottom = false
        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(messageID, anchor: .center) }
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
    let conversationID: UUID
    let settings: DesktopSettings
    let speech: DesktopSpeechPlayer
    let shelf: DesktopArtifactShelf
    let mutationsDisabled: Bool
    let highlighted: Bool
    let onExport: () -> Void
    let onEdit: () -> Void
    let onRegenerate: () -> Void
    let onDelete: () -> Void
    let onSelectVariant: (Int) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var reasoningExpanded = false
    @State private var hovering = false
    @State private var copied = false
    @State private var speechError: String?
    @State private var shareAnchor = DesktopShareAnchor()

    init(message: DesktopMessage, conversationID: UUID, settings: DesktopSettings, speech: DesktopSpeechPlayer,
         shelf: DesktopArtifactShelf, mutationsDisabled: Bool, highlighted: Bool, onExport: @escaping () -> Void,
         onEdit: @escaping () -> Void, onRegenerate: @escaping () -> Void,
         onDelete: @escaping () -> Void, onSelectVariant: @escaping (Int) -> Void) {
        self.message = message; self.conversationID = conversationID; self.settings = settings; self.speech = speech
        self.shelf = shelf; self.mutationsDisabled = mutationsDisabled; self.highlighted = highlighted; self.onExport = onExport
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.role != .user {
                HStack(spacing: 8) {
                    Text(roleTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .lineLimit(1)
                        .help(roleTitle)
                    if message.state == .streaming {
                        DesktopPulse()
                        Text("正在生成").font(.system(size: 12)).foregroundStyle(DesktopTheme.accent)
                    }
                    Spacer()
                    actionButtons.opacity(hovering ? 1 : 0)
                }
                .frame(height: 24)
            }
            if !message.reasoning.isEmpty {
                DisclosureGroup(isExpanded: $reasoningExpanded) {
                    Text(message.reasoning)
                        .font(settings.messageFontFamily.swiftUIFont(size: max(12, settings.messageFontSize - 2)))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(DesktopTheme.hairlineStrong).frame(width: 1) }
                        .padding(.top, 8)
                } label: {
                    Text(message.state == .streaming && message.text.isEmpty ? "正在思考…" : "思考过程")
                        .font(.system(size: 13)).foregroundStyle(DesktopTheme.inkTertiary)
                }
            }
            if message.role == .user, !message.text.isEmpty {
                HStack(alignment: .bottom, spacing: 8) {
                    Spacer(minLength: 120)
                    actionButtons.opacity(hovering ? 1 : 0)
                    Text(message.text)
                        .font(settings.messageFontFamily.swiftUIFont(size: settings.messageFontSize + 1))
                        .foregroundStyle(DesktopTheme.ink)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(highlighted ? DesktopTheme.honey : DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: 520, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !message.text.isEmpty {
                DesktopMarkdown(text: message.text, fontFamily: settings.messageFontFamily, fontSize: settings.messageFontSize)
                    .environment(\.desktopCodePinning, codePinning)
            } else if message.state == .streaming {
                Text("正在等待回复…").font(.system(size: 14)).foregroundStyle(DesktopTheme.inkTertiary)
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
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .background(highlighted && message.role != .user ? DesktopTheme.honeySoft : .clear,
            in: RoundedRectangle(cornerRadius: 10).inset(by: -10))
        .animation(.easeOut(duration: 0.18), value: highlighted)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: message.text) { copied = false }
        .contextMenu { messageActions }
        .alert("无法朗读", isPresented: Binding(get: { speechError != nil }, set: { if !$0 { speechError = nil } })) {
            Button("好", role: .cancel) { speechError = nil }
        } message: { Text(speechError ?? "") }
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            if !message.text.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12)).frame(width: 24, height: 24)
                }
                .buttonStyle(DesktopQuietButtonStyle())
                .help(copied ? "已复制" : "复制消息")
                .accessibilityLabel("复制消息")
            }
            Menu {
                messageActions
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(DesktopTheme.inkTertiary)
            .menuIndicator(.hidden)
            .fixedSize()
            .background(DesktopShareAnchorView(anchor: shareAnchor))
            .help(mutationsDisabled ? "生成或保存完成后可更改消息" : "消息操作")
            .accessibilityLabel("\(roleTitle)的消息操作")
        }
    }

    private var pinnedMessage: DesktopPinnedSnippet? {
        shelf.pinnedSnippet(messageID: message.id, kind: .message, text: message.text, in: conversationID)
    }

    private var codePinning: DesktopCodePinning {
        DesktopCodePinning(
            isPinned: { shelf.pinnedSnippet(messageID: message.id, kind: .code, text: $0, in: conversationID) != nil },
            toggle: { code, language in
                if let pin = shelf.pinnedSnippet(messageID: message.id, kind: .code, text: code, in: conversationID) {
                    shelf.unpin(pin.id, in: conversationID)
                } else {
                    shelf.pin(messageID: message.id, kind: .code, text: code, codeLanguage: language, in: conversationID)
                }
            })
    }

    private var messageActions: some View {
        DesktopMessageActionItems(message: message, speech: speech, mutationsDisabled: mutationsDisabled,
            isPinned: pinnedMessage != nil,
            onTogglePin: {
                if let pin = pinnedMessage { shelf.unpin(pin.id, in: conversationID) }
                else { shelf.pin(messageID: message.id, kind: .message, text: message.text, in: conversationID) }
            },
            onExport: onExport,
            onShare: { shareAnchor.share(message.text) },
            onEdit: onEdit, onRegenerate: onRegenerate, onDelete: onDelete,
            onSpeechError: { speechError = $0 })
    }
}
