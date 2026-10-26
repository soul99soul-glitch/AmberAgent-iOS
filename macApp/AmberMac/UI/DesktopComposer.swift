import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopComposer: View {
    @Bindable var workspace: DesktopWorkspace
    var focusRequest: Int = 0
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
                TextField("向 Amber 发送消息…", text: $workspace.draft, axis: .vertical)
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
                        guard !event.modifiers.contains(.command),
                              let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                              !editor.hasMarkedText() else { return .ignored }
                        editor.insertText("\n", replacementRange: editor.selectedRange())
                        return .handled
                    }
                    .onPasteCommand(of: [.image, .fileURL]) { _ in pasteAttachments() }
                HStack(spacing: 4) {
                    Button { DesktopFileActions.addAttachments(workspace) } label: {
                        Image(systemName: "paperclip").font(.system(size: 14)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                    .disabled(workspace.isLoading || workspace.isLoadingSelectedConversation || workspace.selectedConversationUnavailable
                        || workspace.isGenerating || workspace.isMutatingBranch || workspace.isReadingAttachments)
                    .help("添加图片、PDF、文档或代码文件，也可拖入文件或粘贴图片")
                    .accessibilityLabel("添加附件")
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { workspace.agentTasks.toolsEnabled.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Text("工具").font(.system(size: 13))
                            DesktopSwitch(isOn: workspace.agentTasks.toolsEnabled)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                    }
                    .buttonStyle(DesktopQuietButtonStyle())
                    .disabled(workspace.isGenerating || workspace.isMutatingBranch)
                    .help("允许模型使用已接入的工具；需要确认的操作会先显示审批。")
                    .accessibilityLabel("工具")
                    .accessibilityValue(workspace.agentTasks.toolsEnabled ? "已开启" : "已关闭")
                    if workspace.isReadingAttachments {
                        ProgressView().controlSize(.mini)
                        Text("正在读取附件…")
                            .font(.system(size: 12))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
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
                        .help(workspace.pendingAttachments.isEmpty ? "加入队列 ⌘Return · 当前轮次结束后继续" : "生成中仅支持文本排队，请停止后发送附件")
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
                        Button { workspace.send() } label: {
                            DesktopSendGlyph(enabled: !sendDisabled)
                        }
                        .buttonStyle(DesktopPressButtonStyle())
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .disabled(sendDisabled)
                        .help("发送消息 ⌘Return")
                        .accessibilityLabel("发送消息")
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
            .padding(8)
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: workspace.isSelectedConversationGenerating)
            .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(fileDropTargeted || inputFocused ? DesktopTheme.accent : DesktopTheme.hairlineStrong,
                    lineWidth: fileDropTargeted ? 1.5 : 1))
            .background(RoundedRectangle(cornerRadius: 12).inset(by: -4)
                .fill(inputFocused || fileDropTargeted ? DesktopTheme.honeySoft : .clear))
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
            Text(workspace.isSelectedConversationGenerating
                 ? (workspace.pendingAttachments.isEmpty ? "⌘Return 加入队列 · Return 换行" : "生成中仅支持文本排队 · 停止后可发送附件")
                 : "⌘Return 发送 · Return 换行")
                .font(.system(size: 12))
                .foregroundStyle(DesktopTheme.inkTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 4)
        }
        .frame(maxWidth: DesktopTheme.contentWidth)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .onChange(of: focusRequest) { inputFocused = true }
        .onChange(of: workspace.selectedID) { inputFocused = true; queuePresented = false }
        .onChange(of: workspace.selectedQueuedMessages.isEmpty) { _, empty in if empty { queuePresented = false } }
        .sheet(item: $previewedAttachment) { document in
            DesktopAttachmentPreview(document: document)
        }
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
            .buttonStyle(.plain)
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
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
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
                    Text(attachment.name).lineLimit(1).frame(maxWidth: 180)
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
