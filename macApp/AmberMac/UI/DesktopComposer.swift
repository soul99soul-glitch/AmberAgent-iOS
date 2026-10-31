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
    @State private var pasteKeyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                if !workspace.selectedQueuedMessages.isEmpty {
                    queuedInstructions
                }
                if !workspace.pendingAttachments.isEmpty {
                    attachmentList
                }
                if !matchingSlashCommands.isEmpty || showsBoostSlashCommand {
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
                            if workspace.toggleBoostFromDraft() { inputFocused = true; return .handled }
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
                    if workspace.isBoostAvailable {
                        // 一个图标位：火焰代表「更强力、想得更深」，闪电留给以后的 fast mode。
                        DesktopIconToggle(symbol: "flame", isOn: workspace.isBoostActive) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { workspace.toggleBoost() }
                        }
                        .help(workspace.isBoostActive
                            ? "Boost：DeepSeek 深度思考模式（点击关闭）"
                            : "Boost：DeepSeek 深度思考模式（点击开启）")
                        .accessibilityLabel("Boost")
                        .accessibilityValue(workspace.isBoostActive ? "已开启" : "已关闭")
                    }
                    if workspace.isReadingAttachments {
                        ProgressView().controlSize(.mini)
                        Text("正在读取附件…")
                            .font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 2) {
                        if workspace.isThinkingLevelAvailable {
                            thinkingLevelMenu
                        }
                        inlineModelPicker
                    }
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
                workspace.dropFiles(urls)
            } isTargeted: { fileDropTargeted = $0 }
            HStack(spacing: 8) {
                Text("/ 斜杠指令 · ⌘K 命令面板")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(workspace.isSelectedConversationGenerating
                     ? (workspace.pendingAttachments.isEmpty ? "\(shortcut.sendLabel) 加入队列 · \(shortcut.newlineLabel) 换行" : "生成中仅支持文本排队 · 停止后可发送附件")
                     : "\(shortcut.sendLabel) 发送 · \(shortcut.newlineLabel) 换行")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: DesktopTheme.contentWidth)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        // The composer, not the sidebar search, owns first focus at launch.
        .onAppear {
            inputFocused = true
            installPasteKeyMonitor()
        }
        .onDisappear { removePasteKeyMonitor() }
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

    /// 内置 `/boost`：只有会话选中 DeepSeek 模型时才进入补全。
    private var showsBoostSlashCommand: Bool {
        let trimmed = workspace.draft.trimmingCharacters(in: .whitespaces)
        guard workspace.isBoostAvailable, trimmed.hasPrefix("/"), !trimmed.contains("\n") else { return false }
        let query = trimmed.lowercased()
        return query == "/" || DesktopDeepSeekBoost.slash.hasPrefix(query)
    }

    private var slashCommandBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesktopTheme.accent)
                Text(matchingSlashCommands.isEmpty ? "斜杠指令" : "插件斜杠指令")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                Spacer()
                Text(matchingSlashCommands.isEmpty ? "回车切换" : "点击填入对话")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesktopTheme.inkTertiary)
            }
            .padding(.horizontal, 8)

            if showsBoostSlashCommand { boostSlashRow }

            ForEach(matchingSlashCommands) { cmd in
                Button {
                    workspace.draft = cmd.promptTemplate
                    workspace.agentTasks.toolsEnabled = true
                    inputFocused = true
                } label: {
                    slashCommandRow(symbol: cmd.symbol, slash: cmd.slash, title: cmd.title,
                        trailing: cmd.pluginName, trailingAccent: false)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(DesktopTheme.paperSide, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(DesktopTheme.hairline))
    }

    private var boostSlashRow: some View {
        let enabled = workspace.boost.isEnabled(workspace.selectedID)
        return Button {
            workspace.toggleBoost()
            workspace.draft = ""
            inputFocused = true
        } label: {
            slashCommandRow(symbol: "flame", slash: DesktopDeepSeekBoost.slash,
                title: enabled ? "关闭 DeepSeek 专属提示词" : "开启 DeepSeek 专属提示词",
                trailing: enabled ? "已开启" : "DeepSeek 专属", trailingAccent: enabled)
        }
        .buttonStyle(.plain)
        .help("把固定的一段提示词追加到本会话 system 末尾，只对 DeepSeek 模型生效；再次输入 /boost 关闭。")
        .accessibilityLabel("DeepSeek Boost")
    }

    private func slashCommandRow(symbol: String, slash: String, title: String, trailing: String,
        trailingAccent: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(DesktopTheme.accent)
                .frame(width: 18)
            Text(slash)
                .font(.system(size: 12, design: .monospaced).weight(.semibold))
                .foregroundStyle(DesktopTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 4))
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DesktopTheme.ink)
                .lineLimit(1)
            Spacer()
            Text(trailing)
                .font(.system(size: 11))
                .foregroundStyle(trailingAccent ? DesktopTheme.accentInk : DesktopTheme.inkTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(DesktopTheme.paperDeep, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }

    private var placeholder: String {
        switch workspace.composerMode {
        case .chat: "向 Amber 发送消息…"
        case .council: "写下要议会讨论的问题，主持人会安排席位…"
        }
    }

    private func submit() {
        if workspace.toggleBoostFromDraft() { inputFocused = true; return }
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
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background {
                if workspace.composerMode != .chat {
                    DesktopTheme.glow(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
            // The former decorative `cpu` glyph is gone; clicking the model name is still the single entry
            // to switch models / manage providers. Text only: borderless menus hoist any Image to the
            // leading edge, which would sit between the thinking level and the model name.
            Text(workspace.settings.selectedProvider?.selectedModel?.displayName ?? "选择模型")
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 132)
                .foregroundStyle(DesktopTheme.inkTertiary)
                .padding(.leading, workspace.isThinkingLevelAvailable ? 2 : 8)
                .padding(.trailing, 8)
                .frame(height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(DesktopTheme.inkTertiary)
        .help(inlineModelHelpText)
        .accessibilityLabel("输入框模型选择")
    }

    private var inlineModelHelpText: String {
        if let provider = workspace.settings.selectedProvider,
           let model = provider.selectedModel {
            return "当前服务商与模型：\(provider.name) · \(model.displayName)（点击切换模型或管理服务商）"
        }
        return "快速切换当前对话模型"
    }

    /// Replaces the decorative `cpu` icon immediately to the left of the model name with a text-only thinking level selector.
    private var thinkingLevelMenu: some View {
        let active = workspace.selectedThinkingLevel.isEnabled
        return Menu {
            Picker("思考等级", selection: Binding(
                get: { workspace.selectedThinkingLevel },
                set: { workspace.setThinkingLevel($0) }
            )) {
                ForEach(workspace.supportedThinkingLevels) { level in
                    Text("\(level.rawValue)  ·  \(level.title)").tag(level)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(workspace.selectedThinkingLevel.rawValue)
                .font(.system(size: 12, weight: active ? .medium : .regular, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(active ? DesktopTheme.accentInk : DesktopTheme.inkTertiary)
                .padding(.leading, 6)
                .padding(.trailing, 2)
                .frame(height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(active ? DesktopTheme.accentInk : DesktopTheme.inkTertiary)
        .disabled(workspace.isGenerating || workspace.isMutatingBranch)
        .help(thinkingLevelHelpText)
        .accessibilityLabel("思考等级")
        .accessibilityValue(workspace.selectedThinkingLevel.rawValue)
    }

    private var thinkingLevelHelpText: String {
        let level = workspace.selectedThinkingLevel
        let options = workspace.supportedThinkingLevels.map(\.rawValue).joined(separator: " / ")
        let head = level.isEnabled
            ? "思考等级：\(level.rawValue)（\(level.title)）。模型回答前的推理深度，越高越慢、消耗越多。"
            : "思考等级：off（已关闭推理思考）。"
        return head + "当前模型可选：\(options)。点击切换；按模型分别记住。/boost 只追加提示词，不改变此等级。"
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
        _ = workspace.pasteFromPasteboard()
    }

    /// `NSTextView` (the field editor for `TextField`) intercepts `paste:` and either beeps when the pasteboard
    /// holds only an image or pastes the filename string when Finder copied a file. Intercepting ⌘V before
    /// `performKeyEquivalent` routes file URLs and images into the attachment pipeline while leaving plain text untouched.
    private func installPasteKeyMonitor() {
        guard pasteKeyMonitor == nil else { return }
        pasteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard DesktopPasteboardImport.isPasteShortcut(
                modifierFlags: event.modifierFlags,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                keyCode: event.keyCode
            ) else { return event }
            guard workspace.activeSurface == .chat else { return event }
            let firstResponder = NSApp.keyWindow?.firstResponder
            if let editor = firstResponder as? NSTextView {
                guard inputFocused, !editor.hasMarkedText() else { return event }
            }
            if workspace.pasteFromPasteboard() {
                inputFocused = true
                return nil
            }
            return event
        }
    }

    private func removePasteKeyMonitor() {
        if let monitor = pasteKeyMonitor {
            NSEvent.removeMonitor(monitor)
            pasteKeyMonitor = nil
        }
    }
}
