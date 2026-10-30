import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopWorkspaceFilesView: View {
    @Bindable var workspace: DesktopWorkspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewPresented = false
    @State private var deleting: DesktopWorkspaceFile?
    @State private var importingSoul: DesktopWorkspaceFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("会话工作区").font(DesktopTheme.serif(size: 22, weight: .semibold))
                    Text(workspace.selectedConversationTitle).font(.system(size: 13)).foregroundStyle(DesktopTheme.muted(colorScheme)).lineLimit(1)
                }
                Spacer()
                Button("添加文件…", systemImage: "plus") { importFiles() }
                    .buttonStyle(.desktopProminent)
                    .disabled(workspace.selectedID == nil)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            folderBar
            Text(workspace.selectedWorkspaceKind == .external
                 ? "文件工具和终端命令直接作用于这个文件夹；写入、删除和命令仍需你批准。删除会话不会动这个文件夹。"
                 : "此会话导入的文件与工具生成的产物保存在这里。添加到文件库不会直接发送给模型。")
                .font(.system(size: 13)).foregroundStyle(DesktopTheme.muted(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if let error = workspace.fileErrorMessage {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(DesktopTheme.accent)
                    Spacer()
                    Button("刷新文件列表") { workspace.reloadFiles() }
                }
            }
            if let status = workspace.fileStatusMessage {
                Label(status, systemImage: "checkmark.circle")
                    .font(.system(size: 13)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
            }
            List(workspace.selectedFiles) { file in
                HStack(spacing: 12) {
                    Image(systemName: symbol(for: file.name)).font(.system(size: 18)).foregroundStyle(DesktopTheme.muted(colorScheme)).frame(width: 25)
                    Button {
                        previewPresented = true
                        workspace.previewWorkspaceFile(file.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1).foregroundStyle(.primary)
                            Text(file.id).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("预览 \(file.id)")
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                        Text(file.modifiedAt, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                    }
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    Menu {
                        Button("导出文件…", systemImage: "square.and.arrow.up") { export(file) }
                        if file.name == "SKILL.md" {
                            Button("导入技能", systemImage: "sparkles") { workspace.importKnowledgeFromWorkspaceFile(file.id) }
                        } else if file.name == "SOUL.md" {
                            Button("设为 SOUL.md…", systemImage: "person.text.rectangle") { importingSoul = file }
                        }
                        Button("删除文件", systemImage: "trash", role: .destructive) { deleting = file }
                    } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("文件操作 \(file.name)")
                }
                .padding(.vertical, 7)
            }
            .listStyle(.inset)
            .listRowSeparatorTint(DesktopTheme.hairline)
            .scrollContentBackground(.hidden)
            .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
            .overlay(alignment: .bottom) {
                if workspace.selectedFilesTruncated {
                    Text("只显示前 \(DesktopWorkspaceFiles.listingLimit) 个文件；依赖和构建目录（如 node_modules、.git）已跳过。")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                        .padding(8).frame(maxWidth: .infinity).background(.bar)
                }
            }
            .overlay {
                if workspace.isLoadingFiles { ProgressView("正在读取文件…") }
                else if workspace.fileErrorMessage == nil && workspace.selectedFiles.isEmpty {
                    ContentUnavailableView("还没有文件", systemImage: "folder", description: Text("导入附件或让工具生成文件后，可在这里查看与导出。"))
                }
            }
        }
        .padding(24)
        .frame(width: 740, height: 560)
        .background(DesktopTheme.background(colorScheme))
        .tint(DesktopTheme.accent)
        .onAppear { workspace.reloadFiles() }
        .sheet(isPresented: $previewPresented) {
            if let document = workspace.filePreview {
                DesktopAttachmentPreview(document: document)
            } else {
                VStack(spacing: 18) {
                    if workspace.isLoadingFilePreview { ProgressView("正在读取文件…") }
                    else { Label(workspace.filePreviewErrorMessage ?? "文件暂时无法预览。", systemImage: "doc.badge.ellipsis").fixedSize(horizontal: false, vertical: true) }
                    Button("关闭") { previewPresented = false }.keyboardShortcut(.cancelAction)
                }
                .padding(24).frame(width: 440, height: 200)
            }
        }
        .confirmationDialog("删除这个工作区文件？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let deleting { Button("删除文件", role: .destructive) { workspace.deleteWorkspaceFile(deleting.id); self.deleting = nil } }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text(deleting.map { "\($0.name) 将从此会话的文件库移除。已发送消息中的内容会保留。" } ?? "") }
        .confirmationDialog("替换当前 SOUL.md？", isPresented: Binding(get: { importingSoul != nil }, set: { if !$0 { importingSoul = nil } }), titleVisibility: .visible) {
            Button("导入并替换") { if let importingSoul { workspace.importKnowledgeFromWorkspaceFile(importingSoul.id) }; importingSoul = nil }
            Button("取消", role: .cancel) { importingSoul = nil }
        } message: { Text("所选文件将用于后续请求的长期偏好。请先预览确认内容。") }
    }

    private var folderBar: some View {
        HStack(spacing: 10) {
            Image(systemName: workspace.selectedWorkspaceKind == .external ? "folder.fill" : "folder")
                .foregroundStyle(DesktopTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(folderTitle).font(.system(size: 13, weight: .medium))
                Text(workspace.selectedWorkspaceFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                     ?? "首次写入文件时在 \(workspace.defaultWorkspaceFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "默认工作区") 中创建")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if workspace.selectedWorkspaceKind != .legacy || workspace.selectedWorkspaceFolder != nil {
                Button("在访达中显示") {
                    if let url = workspace.materializeWorkspaceFolder() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            Menu {
                Button("打开文件夹…", systemImage: "folder.badge.plus") { openFolder() }
                if workspace.selectedWorkspaceKind == .external {
                    Button("改回默认工作区", systemImage: "arrow.uturn.backward") { workspace.closeWorkspaceFolder() }
                }
            } label: { Text("更换") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(workspace.selectedID == nil || workspace.isGenerating)
                .help(workspace.isGenerating ? "生成结束后再更换工作区" : "让这个会话使用你已有的文件夹")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
    }

    private var folderTitle: String {
        switch workspace.selectedWorkspaceKind {
        case .external: "已打开的文件夹"
        case .managed: "默认工作区中的会话文件夹"
        case .legacy: workspace.selectedWorkspaceFolder == nil ? "默认工作区中的会话文件夹" : "Amber 内部工作区"
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择这个会话的工作区文件夹。文件工具和终端命令会作用于其中的文件。"
        if panel.runModal() == .OK, let url = panel.url { workspace.openWorkspaceFolder(url) }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "导入到此会话的文件库"
        if panel.runModal() == .OK { workspace.importWorkspaceFiles(panel.urls) }
    }

    private func export(_ file: DesktopWorkspaceFile) {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: (file.name as NSString).pathExtension) { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = file.name
        if panel.runModal() == .OK, let url = panel.url { workspace.exportWorkspaceFile(file.id, to: url) }
    }

    private func symbol(for name: String) -> String {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        return "doc"
    }
}
