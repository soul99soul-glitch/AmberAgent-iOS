import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopComposer: View {
    @Bindable var workspace: DesktopWorkspace
    var focusRequest: Int = 0
    var onOpenCollaborations: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @FocusState private var inputFocused: Bool
    @State private var fileDropTargeted = false
    @State private var previewedAttachment: DesktopImportedDocument?
    @State private var queuePresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                if !workspace.selectedQueuedMessages.isEmpty {
                    queuedInstructions
                }
                if !workspace.pendingAttachments.isEmpty {
                    attachmentList
                }
                if !matchingSlashCommands.isEmpty {
                    slashCommandBar
                }
                TextField("", text: $workspace.draft, prompt: Text(placeholder).foregroundStyle(DesktopTheme.inkTertiary), axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundStyle(DesktopTheme.ink)
                    .lineSpacing(4)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($inputFocused)
                    .accessibilityIdentifier("message-input")
                    .onKeyPress(.return, phases: .down) { event in
                        // ⌘Return always sends (button shortcut). Here: the configured send key, otherwise a newline.
                        guard !event.modifiers.contains(.command),
                              let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                              !editor.hasMarkedText() else { return .ignored }
                        let shift = event.modifiers.contains(.shift)
                        let sends = switch workspace.settings.sendShortcut {
                        case .commandReturn: false
                        case .returnKey: !shift
                        case .shiftReturn: shift
                        }
                        if sends {
                            if workspace.isSelectedConversationGenerating { if workspace.canQueueInstruction { _ = workspace.queueInstruction() } }
                            else if !sendDisabled { submit() }
                            return .handled
                        }
                        editor.insertText("\n", replacementRange: editor.selectedRange())
                        return .handled
                    }
                    .onPasteCommand(of: [.image, .fileURL]) { _ in pasteAttachments() }
                HStack(spacing: 6) {
                    Button { DesktopFileActions.addAttachments(workspace) } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 13.5, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                    .disabled(workspace.isLoading || workspace.isLoadingSelectedConversation || workspace.selectedConversationUnavailable
                        || workspace.isGenerating || workspace.isMutatingBranch || workspace.isReadingAttachments)
                    .help("添加图片、PDF、文档或代码文件，也可拖入文件或粘贴图片")
                    .accessibilityLabel("添加附件")

                    DesktopToggleChip(
                        title: "工具",
                        symbol: "wrench.and.screwdriver",
                        isOn: workspace.agentTasks.toolsEnabled,
                        badge: (workspace.agentTasks.toolsEnabled && (workspace.agentTasks.autoApprove || workspace.agentTasks.autoApproveHighRisk))
                            ? (workspace.agentTasks.autoApproveHighRisk ? "全自动" : "自动批准")
                            : nil,
                        badgeColor: workspace.agentTasks.autoApproveHighRisk ? DesktopTheme.danger : DesktopTheme.accentInk
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { workspace.agentTasks.toolsEnabled.toggle() }
                    }
                    .disabled(workspace.isGenerating || workspace.isMutatingBranch)
                    .help("允许模型使用已接入的工具；需要确认的操作会先显示审批。")
                    .accessibilityLabel("工具")
                    .accessibilityValue(workspace.agentTasks.toolsEnabled ? "已开启" : "已关闭")

                    if workspace.plugins.isCoreEnabled(.collaborations) {
                        DesktopToggleChip(
                            title: "子代理",
                            symbol: "point.3.connected.trianglepath.dotted",
                            isOn: workspace.agentTasks.subagentsEnabled
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { workspace.agentTasks.subagentsEnabled.toggle() }
                        }
                        .disabled(workspace.isGenerating || workspace.isMutatingBranch)
                        .help("允许模型在对话中派发只读子代理（Explorer、Oracle 等）并行调研，结果回到本轮回答。")
                        .accessibilityLabel("子代理")
                        .accessibilityValue(workspace.agentTasks.subagentsEnabled ? "已开启" : "已关闭")

                        modeMenu
                    }
                    if workspace.isReadingAttachments {
                        ProgressView().controlSize(.mini)
                        Text("正在读取附件…")
                            .font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    inlineModelPicker
                    if workspace.isMutatingBranch {
                        ProgressView().controlSize(.small)
                        Text("正在保存…").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    } else if workspace.isSelectedConversationGenerating {
                        Button { workspace.queueInstruction() } label: {
                            Image(systemName: "text.badge.plus").font(.system(size: 14))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(DesktopQuietButtonStyle())
                        .disabled(!workspace.canQueueInstruction)
                        .help(workspace.pendingAttachments.isEmpty ? "\(shortcut.sendLabel) 加入队列 · 当前轮次结束后继续" : "生成中仅支持文本排队，请停止后发送附件")
                        .accessibilityLabel("加入队列")
                        .keyboardShortcut(.return, modifiers: .command)
                        Button { workspace.stop() } label: {
                            RoundedRectangle(cornerRadius: 2).fill(DesktopTheme.inkSecondary).frame(width: 10, height: 10)
                                .frame(width: 32, height: 32)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.hairlineStrong))
                        }
                        .buttonStyle(DesktopPressButtonStyle())
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .help("停止生成")
                        .accessibilityLabel("停止生成")
                        .keyboardShortcut(".", modifiers: .command)
                    } else if workspace.isGenerating {
                        Button {
                            if let owner = workspace.generationConversationID { workspace.select(owner) }
                        } label: {
                            Label("查看生成中的会话", systemImage: "arrow.turn.up.left")
                                .font(.system(size: 12))
                                .padding(.horizontal, 10).frame(height: 28)
                        }
                        .buttonStyle(DesktopQuietButtonStyle())
                        .help("另一个会话正在生成，返回该会话后可以停止")
                    } else {
                        Button { submit() } label: {
                            DesktopSendGlyph(enabled: !sendDisabled, glint: workspace.draft.trimmingCharacters(in: .whitespacesAndNewlines) == "琥珀")
                        }
                        .buttonStyle(DesktopPressButtonStyle())
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .disabled(sendDisabled)
                        .help(workspace.composerMode == .chat ? "发送消息 \(shortcut.sendLabel)" : "发起\(workspace.composerMode.title) \(shortcut.sendLabel)")
                        .accessibilityLabel(workspace.composerMode == .chat ? "发送消息" : "发起\(workspace.composerMode.title)")
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: workspace.isSelectedConversationGenerating)
            .desktopGlass(cornerRadius: 20, highlighted: fileDropTargeted || inputFocused)
            .animation(.easeOut(duration: 0.18), value: inputFocused)
            .animation(.easeOut(duration: 0.18), value: fileDropTargeted)
            .dropDestination(for: URL.self) { urls, _ in
                guard !workspace.isLoading, !workspace.isLoadingSelectedConversation,
                      !workspace.selectedConversationUnavailable, !workspace.isGenerating,
                      !workspace.isMutatingBranch, !workspace.isManagingBackup else { return false }
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                workspace.addAttachments(files)
                return true
            } isTargeted: { fileDropTargeted = $0 }
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    DesktopKeycap(text: "/")
                    Text("斜杠指令")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                    DesktopKeycap(text: "⌘K")
                    Text("命令面板")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    DesktopKeycap(text: shortcut.sendLabel)
                    Text(workspace.isSelectedConversationGenerating ? "加入队列" : "发送")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                    DesktopKeycap(text: shortcut.newlineLabel)
                    Text("换行")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: DesktopTheme.contentWidth)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        // The composer, not the sidebar search, owns first focus at launch.
        .onAppear { inputFocused = true }
        .onChange(of: focusRequest) { inputFocused = true }
        .onChange(of: workspace.selectedID) { inputFocused = true; queuePresented = false }
        .onChange(of: workspace.selectedQueuedMessages.isEmpty) { _, empty in if empty { queuePresented = false } }
        .sheet(item: $previewedAttachment) { document in
            DesktopAttachmentPreview(document: document)
        }
    }

    private var shortcut: DesktopSendShortcut { workspace.settings.sendShortcut }

    private var matchingSlashCommands: [DesktopPluginSlashCommandEntry] {
        let trimmed = workspace.draft.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), !trimmed.contains("\n") else { return [] }
        let query = trimmed.lowercased()
        return workspace.plugins.activeSlashCommands.filter { cmd in
            query == "/" || cmd.slash.lowercased().hasPrefix(query) || cmd.title.lowercased().contains(String(query.dropFirst()))
        }
    }

    private var slashCommandBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesktopTheme.accent)
                Text("插件斜杠指令")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                Spacer()
                Text("点击填入对话")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesktopTheme.inkTertiary)
            }
            .padding(.horizontal, 8)

            ForEach(matchingSlashCommands) { cmd in
                Button {
                    workspace.draft = cmd.promptTemplate
                    workspace.agentTasks.toolsEnabled = true
                    inputFocused = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: cmd.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.accent)
                            .frame(width: 18)
                        Text(cmd.slash)
                            .font(.system(size: 12, design: .monospaced).weight(.semibold))
                            .foregroundStyle(DesktopTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 4))
                        Text(cmd.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DesktopTheme.ink)
                            .lineLimit(1)
                        Spacer()
                        Text(cmd.pluginName)
                            .font(.system(size: 11))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(DesktopTheme.paperSide, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(DesktopTheme.hairline))
    }

    private var placeholder: String {
        switch workspace.composerMode {
        case .chat: "向 Amber 发送消息…"
        case .council: "写下要议会讨论的问题，主持人会安排席位…"
        }
    }

    private func submit() {
        if workspace.composerMode == .chat { workspace.send() } else { workspace.sendCollaboration() }
    }

    /// Chat / 模型议会 / 子代理 — chosen per send, right beside the tools switch.
    private var modeMenu: some View {
        Menu {
            ForEach(DesktopComposerMode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { workspace.composerMode = mode }
                } label: {
                    Label { Text(mode.title); Text(mode.detail) } icon: { Image(systemName: mode.symbol) }
                }
            }
            Divider()
            Button("协作详细设置…", systemImage: "slider.horizontal.3") { onOpenCollaborations() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: workspace.composerMode.symbol).font(.system(size: 11.5))
                Text(workspace.composerMode.title).font(.system(size: 12.5, weight: workspace.composerMode == .chat ? .regular : .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.65)
            }
            .foregroundStyle(workspace.composerMode == .chat ? DesktopTheme.inkSecondary : DesktopTheme.accentInk)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background {
                if workspace.composerMode != .chat {
                    DesktopTheme.glow(Capsule())
                } else {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [DesktopTheme.specularTop.opacity(0.75), DesktopTheme.paperDeep.opacity(0.78)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [DesktopTheme.specularTop, DesktopTheme.hairlineStrong],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.85
                            )
                        )
                }
            }
            .contentTransition(.opacity)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Borderless menu labels take the tint, not foregroundStyle; chat mode stays neutral.
        .tint(workspace.composerMode == .chat ? DesktopTheme.inkSecondary : DesktopTheme.accentInk)
        .disabled(workspace.isGenerating || workspace.isMutatingBranch || workspace.composerRunID != nil)
        .help("选择发送方式：普通对话或模型议会")
        .accessibilityLabel("发送方式")
        .accessibilityValue(workspace.composerMode.title)
    }

    /// Fitts's Law inline model selector right inside the composer cockpit, synchronized with the toolbar picker.
    private var inlineModelPicker: some View {
        Menu {
            Picker("服务商与模型", selection: Binding(
                get: { workspace.settings.selectedModelID },
                set: { if let id = $0 { workspace.settings.selectModel(id) } })) {
                if workspace.settings.selectedModelID == nil { Text("选择模型").tag(Optional<UUID>.none) }
                ForEach(workspace.settings.modelSelections) { model in
                    Text("\(model.providerName) · \(model.modelName)").tag(Optional(model.id))
                        .help(model.modelID)
                }
            }
            Divider()
            SettingsLink { Label("管理服务商…", systemImage: "slider.horizontal.3") }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 10.5))
                Text(workspace.settings.selectedProvider?.selectedModel?.displayName ?? "选择模型")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 132)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(DesktopTheme.inkTertiary)
            .padding(.horizontal, 8)
            .frame(height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(DesktopTheme.inkTertiary)
        .help("快速切换当前对话模型")
        .accessibilityLabel("输入框模型选择")
    }

    private var sendDisabled: Bool {
        workspace.isLoading || workspace.isLoadingSelectedConversation || workspace.selectedConversationUnavailable
            || workspace.isMutatingBranch || workspace.isReadingAttachments
            || (workspace.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && workspace.pendingAttachments.isEmpty)
    }

    private var attachmentList: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(workspace.pendingAttachments) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: workspace.pendingAttachments.map(\.id))
        }
        .scrollIndicators(.hidden)
    }

    private var queuedInstructions: some View {
        HStack(spacing: 8) {
            Button { queuePresented.toggle() } label: {
                HStack(spacing: 6) {
                    Label("排队消息 · \(workspace.selectedQueuedMessages.count)", systemImage: "text.line.first.and.arrowtriangle.forward")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(DesktopQuietButtonStyle())
            .help("查看队列、撤回消息或重试保存")
            Spacer()
            if workspace.selectedQueuedMessages.contains(where: { $0.status == .awaitingSave }) {
                Text("已提交，待保存").foregroundStyle(DesktopTheme.accent)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(DesktopTheme.inkSecondary)
        .padding(.horizontal, 10).frame(height: 28)
        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 6))
        .popover(isPresented: $queuePresented) { queueDetails }
    }

    private var queueDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("排队消息 · \(workspace.selectedQueuedMessages.count)").font(.headline)
                Spacer()
                Button("完成") { queuePresented = false }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(workspace.selectedQueuedMessages) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text(item.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            switch item.status {
                            case .delivering:
                                Text("提交中").foregroundStyle(.secondary)
                            case .awaitingSave:
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("已提交，待保存").foregroundStyle(.secondary)
                                    Button("重试保存") { workspace.retryQueuedMessageSave() }
                                        .buttonStyle(.borderless)
                                }
                            case .pending:
                                Button("撤回") { workspace.withdrawQueuedInstruction(item.id) }
                                    .buttonStyle(.borderless)
                                    .help("将这条消息恢复到草稿")
                            }
                        }
                        .padding(9)
                        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            if !workspace.isGenerating && workspace.selectedQueuedMessages.contains(where: { $0.status == .pending }) {
                HStack {
                    Text("队列已保留，可发送或撤回。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("发送队列") { workspace.sendQueuedInstructions() }
                        .disabled(workspace.isMutatingBranch || workspace.isManagingBackup)
                }
            }
        }
        .font(.callout)
        .padding(16).frame(width: 420, height: 320)
    }

    private func attachmentChip(_ attachment: DesktopImportedDocument) -> some View {
        HStack(spacing: 6) {
            Button { previewedAttachment = attachment } label: {
                HStack(spacing: 6) {
                    DesktopAttachmentThumbnail(document: attachment)
                    Text(attachment.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 240)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("预览附件 \(attachment.name)")
            Button { workspace.removeAttachment(attachment.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel("移除附件 \(attachment.name)")
        }
        .font(.system(size: 12))
        .foregroundStyle(DesktopTheme.inkSecondary)
        .padding(.leading, 8).padding(.trailing, 6)
        .frame(height: 28)
        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 6))
        .transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
        .help(attachment.name)
    }

    private func pasteAttachments() {
        guard !workspace.isLoading, !workspace.isLoadingSelectedConversation,
              !workspace.selectedConversationUnavailable, !workspace.isGenerating,
              !workspace.isMutatingBranch, !workspace.isManagingBackup else { return }
        let pasteboard = NSPasteboard.general
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL],
           !objects.isEmpty {
            workspace.addAttachments(objects.map { $0 as URL })
            return
        }
        let types: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "剪贴板图片.png"),
            (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "剪贴板图片.jpg"),
            (.tiff, "剪贴板图片.tiff"),
        ]
        for (type, name) in types {
            if let data = pasteboard.data(forType: type) {
                workspace.addImageAttachment(data: data, name: name)
                return
            }
        }
        for type in pasteboard.types ?? [] {
            guard let imageType = UTType(type.rawValue), imageType.conforms(to: .image),
                  let data = pasteboard.data(forType: type) else { continue }
            workspace.addImageAttachment(data: data, name: "剪贴板图片." + (imageType.preferredFilenameExtension ?? "png"))
            return
        }
    }
}
