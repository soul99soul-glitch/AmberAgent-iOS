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
                HStack(spacing: 10) {
                    Button { DesktopFileActions.addAttachments(workspace) } label: {
                        Image(systemName: "paperclip").frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(workspace.isLoading || workspace.isLoadingSelectedConversation || workspace.selectedConversationUnavailable
                        || workspace.isGenerating || workspace.isMutatingBranch || workspace.isReadingAttachments)
                    .help("添加图片、PDF、文档或代码文件，也可拖入文件或粘贴图片")
                    .accessibilityLabel("添加附件")
                    Toggle(isOn: Binding(get: { workspace.agentTasks.toolsEnabled }, set: { workspace.agentTasks.toolsEnabled = $0 })) {
                        Label("工具", systemImage: "wrench.and.screwdriver")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(workspace.agentTasks.toolsEnabled ? DesktopTheme.accentWash(scheme) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesktopTheme.border(scheme)))
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .foregroundStyle(workspace.agentTasks.toolsEnabled ? DesktopTheme.accent : .secondary)
                    .disabled(workspace.isGenerating || workspace.isMutatingBranch)
                    .help("允许模型使用已接入的工具；需要确认的操作会先显示审批。")
                    if workspace.isReadingAttachments {
                        ProgressView().controlSize(.mini)
                        Text("正在读取附件…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if workspace.isMutatingBranch {
                        ProgressView().controlSize(.small)
                        Text("正在保存…").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if workspace.isSelectedConversationGenerating {
                        Button { workspace.queueInstruction() } label: {
                            Image(systemName: "text.badge.plus")
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!workspace.canQueueInstruction)
                        .help(workspace.pendingAttachments.isEmpty ? "加入队列 ⌘Return · 当前轮次结束后继续" : "生成中仅支持文本排队，请停止后发送附件")
                        .accessibilityLabel("加入队列")
                        .keyboardShortcut(.return, modifiers: .command)
                        Button { workspace.stop() } label: {
                            Image(systemName: "stop.fill")
                                .foregroundStyle(.primary)
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                        .help("停止生成")
                        .accessibilityLabel("停止生成")
                        .keyboardShortcut(".", modifiers: .command)
                    } else if workspace.isGenerating {
                        Button {
                            if let owner = workspace.generationConversationID { workspace.select(owner) }
                        } label: {
                            Label("查看生成中的会话", systemImage: "arrow.turn.up.left")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .help("另一个会话正在生成，返回该会话后可以停止")
                    } else {
                        Button { workspace.send() } label: {
                            Image(systemName: "arrow.up")
                                .fontWeight(.semibold)
                                .foregroundStyle(sendDisabled ? Color.secondary : (scheme == .dark ? DesktopTheme.background(.dark) : .white))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesktopTheme.accent)
                        .disabled(sendDisabled)
                        .help("发送消息 ⌘Return")
                        .accessibilityLabel("发送消息")
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
            .padding(12)
            .background(DesktopTheme.raised(scheme), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(fileDropTargeted ? DesktopTheme.accent : DesktopTheme.border(scheme)))
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
                .font(.system(size: 11))
                .foregroundStyle(DesktopTheme.muted(scheme))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: DesktopTheme.contentWidth)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 14)
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
                Text("已提交，待保存").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
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
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.05), in: Capsule())
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
