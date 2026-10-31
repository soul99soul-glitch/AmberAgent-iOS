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
    /// The one writer of the transcript offset while following (iOS「仲裁者」): see DesktopScrollFollower.
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var follower = DesktopScrollFollower()
    /// Rows far outside the viewport render as fixed-height placeholders using their last exact measurement, so a
    /// streaming snapshot only lays out the rows near the reader (lazy-stack estimates would make the bottom jump).
    @State private var rowHeights = DesktopRowHeights()
    @State private var reasoningExpansion = DesktopReasoningExpansion()
    @State private var liveRows: DesktopLiveRows?
    @State private var layoutWidth = 0
    @State private var visibleRect = CGRect.zero

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
            if findPresented { findBar }
            ScrollView {
                DesktopTranscriptStack(eager: windowed) {
                    ForEach(visibleRows, id: \.element.rowIdentity) { index, message in
                        let following = conversation.messages.count - index - 1
                        let highlighted = findPresented && find.currentMessageID == message.id
                        let layout = rowLayout(message)
                        // A streaming reply out of the window keeps its last height until the reader comes back
                        // (growth below the viewport is invisible), so history reading costs no per-chunk layout.
                        // Lazy stacks virtualize themselves; image rows reload (and change height) when remounted.
                        if windowed, message.images.isEmpty, !highlighted, !(liveRows?.contains(index) ?? true),
                           let height = message.state == .streaming ? rowHeights.anyHeight(message.rowIdentity)
                            : (rowHeights.height(message.rowIdentity, layout: layout) ?? rowHeights.anyHeight(message.rowIdentity)) {
                            Color.clear.frame(maxWidth: .infinity).frame(height: height)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.contentSpace)) } action: {
                                    rowHeights.place(message.rowIdentity, $0)
                                }
                                .id(message.rowIdentity)
                        } else {
                        DesktopMessageRow(message: message, conversationID: conversation.id, settings: workspace.settings,
                            speech: workspace.speech, shelf: workspace.artifactShelf, reasoningExpansion: reasoningExpansion,
                            mutationsDisabled: mutationsDisabled, highlighted: highlighted, followingCount: following,
                            onExport: { DesktopFileActions.exportMessage(workspace, messageID: message.id) },
                            onEdit: { editingMessage = MessageEditDraft(id: message.id, ownerID: conversation.id,
                                text: message.textForEditing, followingCount: following) },
                            onRegenerate: { requestRegeneration(message, followingCount: following) },
                            onDelete: { confirmation = .delete(message.id, ownerID: conversation.id, variants: message.variantCount) },
                            onSelectVariant: { workspace.selectVariant(message.id, index: $0) })
                            // Each snapshot rebuilds these closures; without this every history row re-renders per chunk.
                            .equatable()
                            .modifier(DesktopRiseIn(enabled: message.id == conversation.messages.last?.id
                                && message.state == .streaming && message.text.isEmpty))
                            .modifier(DesktopStreamingEdge(active: message.state == .streaming))
                            .onGeometryChange(for: DesktopRowHeights.Measurement.self) {
                                .init(layout: layout, frame: $0.frame(in: .named(Self.contentSpace)))
                            } action: {
                                // A height change moves every row below it: the window must follow the real layout.
                                if rowHeights.record(message.rowIdentity, $0) { repickLiveRows() }
                            }
                            .id(message.rowIdentity)
                        }
                    }
                    if !mutationsDisabled, let last = conversation.messages.last, last.role == .assistant,
                       last.state == .cancelled || last.state == .failed {
                        Button("重新生成", systemImage: "arrow.clockwise") { workspace.retry() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("retry-generation")
                    }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }
                .coordinateSpace(.named(Self.contentSpace))
                .frame(maxWidth: DesktopTheme.contentWidth)
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
                // Streaming text growth is not an animatable event for the list; only explicit withAnimation moves rows.
                .transaction(value: conversation.messages.last?.text) { $0.animation = nil }
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Growth never moves what the reader sees; the follower alone glides the view down.
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .onScrollGeometryChange(for: DesktopScrollFollower.Geometry.self) { geometry in
                .init(offset: geometry.contentOffset.y, bottom: max(0, geometry.contentSize.height - geometry.containerSize.height))
            } action: { _, value in
                nearBottom = value.bottom - value.offset < 80
                if userScrolling { followsBottom = nearBottom && workspace.settings.automaticallyFollowGeneration }
                follower.update(target: value.bottom, actual: value.offset,
                    following: followsBottom && workspace.settings.automaticallyFollowGeneration && !userScrolling,
                    streaming: workspace.isSelectedConversationGenerating) { position.scrollTo(y: $0) }
            }
            .onScrollGeometryChange(for: DesktopLiveRows.Viewport.self) { geometry in
                .init(visible: geometry.visibleRect,
                      width: DesktopLiveRows.contentWidth(forContainerWidth: geometry.containerSize.width,
                                                          maxWidth: DesktopTheme.contentWidth))
            } action: { _, viewport in
                visibleRect = viewport.visible
                if layoutWidth != viewport.width {
                    layoutWidth = viewport.width
                    repickLiveRows()
                    return
                }
                updateLiveRows(viewport.visible)
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating
                workspace.transcriptIsUserScrolling = userScrolling
                if phase == .interacting { followsBottom = false; follower.stop() }
                if phase == .idle, nearBottom { followsBottom = workspace.settings.automaticallyFollowGeneration }
            }
            .onChange(of: conversation.messages.count) {
                // Row indices shifted: the window must be re-picked now, not on the next scroll.
                repickLiveRows()
                if followsBottom, workspace.settings.automaticallyFollowGeneration {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                }
            }
            .onChange(of: conversation.id, initial: true) {
                rowHeights = DesktopRowHeights()
                liveRows = nil
                if let focusRequest, focusRequest.conversationID == conversation.id {
                    followsBottom = false
                    proxy.scrollTo(rowID(for: focusRequest.messageID), anchor: .center)
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
                        // Render everything for the jump: a placeholder streaming reply would end the scroll mid-reply.
                        liveRows = nil
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                            .frame(width: 32, height: 32)
                            .background(DesktopTheme.card, in: Circle())
                            .overlay(Circle().strokeBorder(DesktopTheme.hairlineStrong))
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    }
                    .buttonStyle(DesktopPressButtonStyle())
                    .help("回到最新消息")
                    .accessibilityLabel("回到最新消息")
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
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
        .onDisappear { workspace.transcriptIsUserScrolling = false }
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
            Image(systemName: "magnifyingglass").foregroundStyle(DesktopTheme.inkTertiary)
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
                Text(find.label).monospacedDigit().foregroundStyle(DesktopTheme.inkTertiary)
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
        .font(.system(size: 13))
        .foregroundStyle(DesktopTheme.inkSecondary)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(DesktopTheme.field, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(findFocused ? DesktopTheme.accent : DesktopTheme.hairlineStrong))
        .animation(.easeOut(duration: 0.15), value: findFocused)
        .frame(maxWidth: DesktopTheme.contentWidth)
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private func rowLayout(_ message: DesktopMessage) -> DesktopRowHeights.Layout {
        let settings = workspace.settings
        return .init(message: message, width: layoutWidth, fontFamily: settings.messageFontFamily, fontSize: settings.messageFontSize,
            reasoningExpanded: reasoningExpansion[message.id], autoExpandThinking: settings.autoExpandThinking,
            reasoningExpandedByDefault: settings.reasoningExpandedByDefault, hidesToolCalls: settings.hidesToolCalls,
            expandedTools: message.tools.filter { reasoningExpansion[tool: message.id, $0.id] }.map(\.id))
    }

    /// Rows keep their index in `conversation.messages`; with tool calls hidden, a finished turn that only called
    /// tools has nothing left to show and is skipped.
    private var visibleRows: [(offset: Int, element: DesktopMessage)] {
        let rows = Array(conversation.messages.enumerated())
        guard workspace.settings.hidesToolCalls else { return rows }
        return rows.filter { !$0.element.isToolOnly || $0.element.state == .streaming }
    }

    /// Re-picks the live rows only once the viewport nears the edge of the current window, so scrolling within it
    /// never re-evaluates the transcript.
    private func updateLiveRows(_ visible: CGRect) {
        guard windowed else { if liveRows != nil { liveRows = nil }; return }
        if let liveRows, liveRows.covers(visible) { return }
        let next = DesktopLiveRows(visible: visible, rowIDs: conversation.messages.map(\.rowIdentity), heights: rowHeights)
        if next != liveRows { liveRows = next }
    }

    private func repickLiveRows() {
        guard windowed, visibleRect.height > 0 else { return }
        let next = DesktopLiveRows(visible: visibleRect, rowIDs: conversation.messages.map(\.rowIdentity), heights: rowHeights)
        if next != liveRows { liveRows = next }
    }

    /// Normal conversations use the eager stack (exact heights, stable bottom) plus windowing; long ones stay lazy.
    private var windowed: Bool { conversation.messages.count <= 120 }
    private static let contentSpace = "desktop-transcript-content"

    private func updateFind() { find.update(findQuery, messages: conversation.messages) }

    private func closeFind() {
        findPresented = false
        findFocused = false
    }

    private func rowID(for messageID: UUID) -> UUID {
        conversation.messages.first { $0.id == messageID }?.rowIdentity ?? messageID
    }

    private func reveal(_ messageID: UUID, proxy: ScrollViewProxy) {
        followsBottom = false
        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(rowID(for: messageID), anchor: .center) }
    }

    private func requestRegeneration(_ message: DesktopMessage, followingCount count: Int) {
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

/// Equatable over the values the row renders and its actions read; the closures are rebuilt from the same values,
/// so a row whose inputs are unchanged keeps its previous closures. Observable settings/shelf/speech track themselves.
private struct DesktopMessageRow: View, Equatable {
    let message: DesktopMessage
    let conversationID: UUID
    let settings: DesktopSettings
    let speech: DesktopSpeechPlayer
    let shelf: DesktopArtifactShelf
    let reasoningExpansion: DesktopReasoningExpansion
    let mutationsDisabled: Bool
    let highlighted: Bool
    let followingCount: Int
    let onExport: () -> Void
    let onEdit: () -> Void
    let onRegenerate: () -> Void
    let onDelete: () -> Void
    let onSelectVariant: (Int) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var menuOpen = false
    @State private var copied = false
    @State private var speechError: String?
    @State private var shareAnchor = DesktopShareAnchor()

    init(message: DesktopMessage, conversationID: UUID, settings: DesktopSettings, speech: DesktopSpeechPlayer,
         shelf: DesktopArtifactShelf, reasoningExpansion: DesktopReasoningExpansion,
         mutationsDisabled: Bool, highlighted: Bool, followingCount: Int, onExport: @escaping () -> Void,
         onEdit: @escaping () -> Void, onRegenerate: @escaping () -> Void,
         onDelete: @escaping () -> Void, onSelectVariant: @escaping (Int) -> Void) {
        self.message = message; self.conversationID = conversationID; self.settings = settings; self.speech = speech
        self.shelf = shelf; self.reasoningExpansion = reasoningExpansion
        self.mutationsDisabled = mutationsDisabled; self.highlighted = highlighted
        self.followingCount = followingCount; self.onExport = onExport
        self.onEdit = onEdit; self.onRegenerate = onRegenerate; self.onDelete = onDelete
        self.onSelectVariant = onSelectVariant
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.message == rhs.message && lhs.conversationID == rhs.conversationID
                && lhs.mutationsDisabled == rhs.mutationsDisabled && lhs.highlighted == rhs.highlighted
                && lhs.followingCount == rhs.followingCount
                && lhs.settings === rhs.settings && lhs.speech === rhs.speech && lhs.shelf === rhs.shelf
                && lhs.reasoningExpansion === rhs.reasoningExpansion
        }
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
        VStack(alignment: .leading, spacing: 12) {
            if message.role != .user {
                HStack(spacing: 7) {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [DesktopTheme.accent, DesktopTheme.honeyEdge],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: 8
                            )
                        )
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(roleTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(DesktopTheme.ink)
                        .lineLimit(1)
                        .help(roleTitle)
                    if message.state == .streaming {
                        HStack(spacing: 5) {
                            DesktopPulse()
                            Text("正在生成")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(DesktopTheme.inkSecondary)
                                .modifier(DesktopSoftShimmer(active: true))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(DesktopTheme.paperDeep, in: Capsule())
                    }
                    Spacer()
                    actionButtons.opacity(hovering || menuOpen ? 1 : 0).allowsHitTesting(hovering || menuOpen)
                }
                .frame(height: 24)
            }
            if !message.reasoning.isEmpty {
                DesktopReasoningCard(reasoning: message.reasoning,
                    thinking: message.state == .streaming && message.text.isEmpty,
                    streaming: message.state == .streaming,
                    autoExpand: settings.autoExpandThinking, defaultExpanded: settings.reasoningExpandedByDefault,
                    font: settings.messageFontFamily.swiftUIFont(size: max(12, settings.messageFontSize - 2)),
                    expanded: Binding(get: { reasoningExpansion[message.id] }, set: { reasoningExpansion[message.id] = $0 }))
            }
            if message.role == .user, !message.text.isEmpty {
                HStack(alignment: .bottom, spacing: 8) {
                    Spacer(minLength: 100)
                    actionButtons.opacity(hovering || menuOpen ? 1 : 0).allowsHitTesting(hovering || menuOpen)
                    Text(message.text)
                        .font(settings.messageFontFamily.swiftUIFont(size: settings.messageFontSize + 0.5))
                        .foregroundStyle(DesktopTheme.ink)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .desktopGlass(cornerRadius: 18, tinted: true, highlighted: highlighted)
                        .frame(maxWidth: 520, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !message.text.isEmpty {
                DesktopMarkdown(text: message.text, fontFamily: settings.messageFontFamily, fontSize: settings.messageFontSize,
                    streaming: message.state == .streaming)
                    .environment(\.desktopCodePinning, codePinning)
            }
            if !message.tools.isEmpty, !settings.hidesToolCalls {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(message.tools) { tool in
                        DesktopToolCallCard(tool: tool, expanded: Binding(
                            get: { reasoningExpansion[tool: message.id, tool.id] },
                            set: { reasoningExpansion[tool: message.id, tool.id] = $0 }))
                    }
                }
            }
            if message.text.isEmpty, message.state == .streaming, message.role != .user,
               message.tools.isEmpty || settings.hidesToolCalls {
                Text(message.tools.isEmpty ? "正在等待回复…" : "正在使用工具…")
                    .font(.system(size: 14))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .modifier(DesktopSoftShimmer(active: true))
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
                        .monospacedDigit().font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                        .contentTransition(.numericText())
                        .accessibilityLabel("第 \(message.variantIndex + 1) 个版本，共 \(message.variantCount) 个")
                    Button { onSelectVariant(message.variantIndex + 1) } label: {
                        Image(systemName: "chevron.right").frame(width: 28, height: 28)
                    }
                    .disabled(mutationsDisabled || message.variantIndex + 1 >= message.variantCount)
                    .help("下一个版本，保留其他消息")
                    .accessibilityLabel("下一个消息版本")
                }
                .buttonStyle(.borderless)
                .frame(height: 28)
            }
            if message.state == .cancelled || message.state == .failed {
                let hasContent = !message.text.isEmpty || !message.reasoning.isEmpty || !message.images.isEmpty || message.unsupportedPartCount > 0
                    || !message.tools.isEmpty
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
                        .contentTransition(.symbolEffect(.replace.downUp))
                        .foregroundStyle(copied ? DesktopTheme.accent : DesktopTheme.inkTertiary)
                }
                .buttonStyle(DesktopQuietButtonStyle())
                .help(copied ? "已复制" : "复制消息")
                .accessibilityLabel("复制消息")
            }
            Menu {
                messageActions
                    .onAppear { menuOpen = true }
                    .onDisappear { menuOpen = false }
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

/// Lazy stacks estimate unseen rows and correct later, which shows up as the content height briefly jumping while
/// streaming. Normal conversations are laid out eagerly (exact heights, stable bottom); very long ones stay lazy.
private struct DesktopTranscriptStack<Content: View>: View {
    let eager: Bool
    @ViewBuilder let content: Content
    var body: some View {
        if eager { VStack(alignment: .leading, spacing: 32) { content } }
        else { LazyVStack(alignment: .leading, spacing: 32) { content } }
    }
}

extension DesktopMessage {
    /// Only tool calls: nothing else would render once tool cards are hidden.
    var isToolOnly: Bool {
        !tools.isEmpty && text.isEmpty && reasoning.isEmpty && images.isEmpty && unsupportedPartCount == 0
    }

    /// A regenerated reply is a new message ID but the same slot (same variant group): keep its row, so the
    /// version switcher and surrounding layout never get torn down and re-inserted mid-stream.
    var rowIdentity: UUID { variantIDs.first ?? id }
}

/// Per-message thinking-card choice (nil = follow settings), kept outside the row so placeholders don't reset it.
@MainActor @Observable final class DesktopReasoningExpansion {
    private var values: [UUID: Bool] = [:]
    private var tools: Set<String> = []
    subscript(id: UUID) -> Bool? {
        get { values[id] }
        set { values[id] = newValue }
    }
    /// Tool cards start folded; only opened ones are remembered.
    subscript(tool messageID: UUID, toolID: String) -> Bool {
        get { tools.contains("\(messageID)/\(toolID)") }
        set { if newValue { tools.insert("\(messageID)/\(toolID)") } else { tools.remove("\(messageID)/\(toolID)") } }
    }
}

/// Last exact height of each row, valid only for the inputs it was measured with. Reference type held in @State:
/// recording a measurement must not invalidate the transcript (that would turn layout into a feedback loop).
@MainActor final class DesktopRowHeights {
    struct Layout: Equatable {
        let message: DesktopMessage
        let width: Int
        let fontFamily: DesktopMessageFontFamily
        let fontSize: Double
        let reasoningExpanded: Bool?
        let autoExpandThinking: Bool
        let reasoningExpandedByDefault: Bool
        let hidesToolCalls: Bool
        let expandedTools: [String]
    }

    struct Measurement: Equatable {
        let layout: Layout
        /// In the transcript content's own coordinate space, so scrolling never changes it.
        let frame: CGRect
    }

    private var values: [UUID: Measurement] = [:]
    private var frames: [UUID: CGRect] = [:]

    /// Returns true when the row's height changed, i.e. everything below it moved.
    @discardableResult
    func record(_ rowID: UUID, _ measurement: Measurement) -> Bool {
        guard measurement.frame.height > 0 else { return false }
        let previous = values[rowID]?.frame.height
        values[rowID] = measurement
        frames[rowID] = measurement.frame
        return previous.map { abs($0 - measurement.frame.height) > 0.5 } ?? true
    }

    /// Placeholders keep reporting where they are, so positions stay real after rows above them change.
    func place(_ rowID: UUID, _ frame: CGRect) { frames[rowID] = frame }

    func height(_ rowID: UUID, layout: Layout) -> CGFloat? {
        guard let value = values[rowID], value.layout == layout else { return nil }
        return value.frame.height
    }

    /// Last height regardless of inputs (a streaming reply out of view keeps it until the reader returns).
    func anyHeight(_ rowID: UUID) -> CGFloat? { values[rowID]?.frame.height }

    func frame(_ rowID: UUID) -> CGRect? { frames[rowID] }
}

/// The rows rendered for real: every row whose measured frame lies within 1.5 viewports of what the reader sees,
/// plus any row not laid out yet. The window is re-picked when the viewport nears its edge or a row's height changes.
struct DesktopLiveRows: Equatable {
    struct Viewport: Equatable {
        let visible: CGRect
        let width: Int
    }

    /// Clamps scroll-container width to the centered transcript column width so outer chrome changes (such as
    /// toggling the sidebar or inspector when the column is already at `maxWidth`) do not invalidate row heights.
    static func contentWidth(forContainerWidth containerWidth: CGFloat,
                             maxWidth: CGFloat = DesktopTheme.contentWidth,
                             horizontalPadding: CGFloat = 48) -> Int {
        Int(min(max(0, containerWidth - horizontalPadding), maxWidth).rounded())
    }

    /// The scroll view's content starts with the transcript's 32pt top padding.
    private static let topInset: CGFloat = 32
    private let window: ClosedRange<CGFloat>
    private let rows: Set<Int>

    @MainActor init(visible: CGRect, rowIDs: [UUID], heights: DesktopRowHeights) {
        let margin = max(visible.height, 1) * 1.5
        window = (visible.minY - margin)...(visible.maxY + margin)
        var rows = Set<Int>()
        for (index, id) in rowIDs.enumerated() {
            guard let frame = heights.frame(id) else { rows.insert(index); continue }
            let top = frame.minY + Self.topInset, bottom = frame.maxY + Self.topInset
            if bottom >= window.lowerBound, top <= window.upperBound { rows.insert(index) }
        }
        self.rows = rows
    }

    func contains(_ index: Int) -> Bool { rows.contains(index) }

    func covers(_ visible: CGRect) -> Bool {
        let slack = visible.height * 0.5
        return visible.minY - slack >= window.lowerBound && visible.maxY + slack <= window.upperBound
    }
}
