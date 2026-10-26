import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopWorkspaceView: View {
    @Bindable var workspace: DesktopWorkspace
    let searchRequest: Int
    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchFocused: Bool
    @State private var renameID: UUID?
    @State private var renameTitle = ""
    @State private var deleteID: UUID?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var transcriptFocus: DesktopTranscriptFocus?
    @State private var insightsPresented = false
    @State private var filesPresented = false
    @State private var tasksPresented = false
    @State private var knowledgePresented = false
    @State private var backupPresented = false
    @State private var collaborationsPresented = false
    @State private var recipesPresented = false
    @State private var searchSettingsPresented = false
    @State private var imageGenerationOwner: ImageGenerationOwner?
    @State private var composerFocusRequest = 0

    private struct ImageGenerationOwner: Identifiable { let id: UUID }

    private var displayedConversations: [DesktopConversationSearchResult] {
        workspace.sidebarResults
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if workspace.isLoading {
                    ProgressView("正在读取会话…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if workspace.isLoadingSelectedConversation {
                    ProgressView("正在读取消息…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if workspace.selectedConversationUnavailable {
                    ContentUnavailableView {
                        Label("暂时无法读取会话", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text("原始数据已保留。请检查文件权限后重试。")
                    } actions: {
                        Button("重新读取") { workspace.reloadSelectedConversation() }
                    }
                } else if let conversation = workspace.selectedConversation, !conversation.messages.isEmpty {
                    DesktopTranscript(conversation: conversation, workspace: workspace, focusRequest: transcriptFocus)
                } else {
                    welcome
                }
                if let error = workspace.errorMessage {
                    errorBanner(error)
                }
                if let task = workspace.agentTasks.records.first(where: { $0.conversationID == workspace.selectedID && $0.approval != nil }) {
                    DesktopToolApprovalCard(task: task, tasks: workspace.agentTasks)
                        .frame(maxWidth: DesktopTheme.contentWidth)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }
                DesktopComposer(workspace: workspace, focusRequest: composerFocusRequest)
                    .disabled(workspace.isLoading || workspace.isLoadingSelectedConversation || workspace.selectedConversationUnavailable || workspace.isManagingBackup)
            }
            .background(DesktopTheme.background(scheme))
            .navigationTitle(workspace.selectedConversationTitle)
            .toolbar { toolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $filesPresented) { DesktopWorkspaceFilesView(workspace: workspace) }
        .sheet(isPresented: $tasksPresented) { DesktopAgentTasksView(workspace: workspace) }
        .sheet(isPresented: $backupPresented) { DesktopBackupView(workspace: workspace) }
        .sheet(isPresented: $collaborationsPresented) {
            DesktopCollaborationsView(workspace: workspace) { conversationID, messageID in
                transcriptFocus = DesktopTranscriptFocus(conversationID: conversationID, messageID: messageID)
                workspace.select(conversationID)
                collaborationsPresented = false
            }
        }
        .sheet(isPresented: $recipesPresented) { DesktopRecipesView(workspace: workspace) }
        .sheet(isPresented: $searchSettingsPresented) { DesktopSearchSettingsView(settings: workspace.searchSettings) }
        .sheet(item: $imageGenerationOwner) { owner in
            DesktopImageGenerationView(workspace: workspace, ownerID: owner.id)
        }
        .sheet(isPresented: $knowledgePresented) {
            DesktopKnowledgeView(store: workspace.knowledge, conversationIDs: Set(workspace.summaries.map(\.id))) { conversationID, messageID in
                transcriptFocus = messageID.map { DesktopTranscriptFocus(conversationID: conversationID, messageID: $0) }
                workspace.select(conversationID)
                knowledgePresented = false
            }
        }
        .onChange(of: searchRequest) {
            columnVisibility = .all
            searchFocused = true
        }
        .alert("重命名会话", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("会话名称", text: $renameTitle)
            Button("取消", role: .cancel) { renameID = nil }
            Button("保存") {
                if let id = renameID { workspace.rename(id, title: renameTitle) }
                renameID = nil
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("删除这个会话？", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }), titleVisibility: .visible) {
            Button("删除会话", role: .destructive) {
                if let id = deleteID { workspace.delete(id) }
                deleteID = nil
            }
            Button("取消", role: .cancel) { deleteID = nil }
        } message: {
            Text("会话及消息将从这台 Mac 移除。")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "sparkle").font(.system(size: 20, weight: .medium)).foregroundStyle(DesktopTheme.accent)
                Text("Amber").font(.system(size: 18, weight: .semibold)).tracking(-0.4)
                Spacer()
                Button { workspace.createConversation() } label: {
                    Image(systemName: "square.and.pencil").frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(workspace.isLoading || workspace.isManagingBackup)
                .help("新建会话 ⌘N")
                .accessibilityLabel("新建会话")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索会话", text: $workspace.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("conversation-search")
                if workspace.isSearching && !displayedConversations.isEmpty {
                    ProgressView().controlSize(.mini).help("正在搜索所有会话")
                }
                if !workspace.searchText.isEmpty {
                    Button { workspace.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("清空搜索")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(DesktopTheme.background(scheme).opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.border(scheme)))
            .padding(.horizontal, 14)

            if let error = workspace.searchErrorMessage {
                HStack(alignment: .top, spacing: 7) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("重试") { workspace.retrySearch() }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
            }

            List(selection: Binding(get: { workspace.selectedID }, set: { id in
                if let result = displayedConversations.first(where: { $0.id == id }) { selectResult(result) }
            })) {
                Section(workspace.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "会话" : "搜索结果") {
                    ForEach(displayedConversations) { conversation in
                        conversationRow(conversation)
                            .tag(conversation.id)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                            .simultaneousGesture(TapGesture().onEnded { selectResult(conversation) })
                            .contextMenu {
                                Button(conversation.isPinned ? "取消置顶" : "置顶", systemImage: conversation.isPinned ? "pin.slash" : "pin") {
                                    workspace.togglePin(conversation.id)
                                }
                                Button("重命名", systemImage: "pencil") {
                                    renameID = conversation.id
                                    renameTitle = conversation.title
                                }
                                if workspace.titles.activeOwners.contains(conversation.id) {
                                    Button("取消生成标题", systemImage: "stop") { workspace.titles.cancel(conversation.id) }
                                } else {
                                    Button("生成标题", systemImage: "sparkles") { generateTitle(for: conversation.id) }
                                        .disabled(workspace.isManagingBackup || workspace.isMutatingBranch
                                            || workspace.generationConversationID == conversation.id || conversation.messageCount == 0)
                                }
                                Divider()
                                Button("删除会话", systemImage: "trash", role: .destructive) { deleteID = conversation.id }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if displayedConversations.isEmpty {
                    if workspace.isSearching {
                        ProgressView("正在搜索…").controlSize(.small)
                    } else {
                        Text(workspace.searchText.isEmpty ? "从一条消息开始" : "没有匹配的会话")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
            }
            Divider().padding(.horizontal, 18)
            HStack(spacing: 12) {
                SettingsLink {
                    Label("设置", systemImage: "gearshape").frame(height: 30)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("设置 ⌘,")
                Menu("工作台") {
                    Button("会话文件", systemImage: "folder") { filesPresented = true }
                        .disabled(workspace.selectedID == nil)
                    Button("任务工作台", systemImage: "checklist") { tasksPresented = true }
                    Button("知识与偏好", systemImage: "brain") { knowledgePresented = true }
                    Button("多模型协作", systemImage: "person.3") { collaborationsPresented = true }
                        .disabled(workspace.selectedID == nil || workspace.selectedConversationUnavailable)
                    Button("Recipe 自动流程", systemImage: "list.number") { recipesPresented = true }
                    Button("图片生成", systemImage: "photo.badge.plus") {
                        if let owner = workspace.imageGeneration.isRunning ? workspace.imageGeneration.ownerID : workspace.selectedID {
                            imageGenerationOwner = ImageGenerationOwner(id: owner)
                        }
                    }
                    .disabled(workspace.selectedID == nil || workspace.selectedConversationUnavailable)
                    Button("联网搜索设置", systemImage: "globe") { searchSettingsPresented = true }
                    Divider()
                    Button("备份与恢复", systemImage: "externaldrive") { backupPresented = true }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("导入会话…", systemImage: "square.and.arrow.down") { DesktopFileActions.importConversation(workspace) }
                        .disabled(workspace.isLoading)
                    Menu("导出当前会话", systemImage: "square.and.arrow.up") { exportActions }
                        .disabled(workspace.selectedConversation == nil)
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("导入与导出")
            }
            .font(.system(size: 12))
            .tint(Color.primary)
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .background(DesktopTheme.sidebar(scheme))
    }

    private func selectResult(_ result: DesktopConversationSearchResult) {
        if let messageID = result.messageID {
            transcriptFocus = DesktopTranscriptFocus(conversationID: result.conversationID, messageID: messageID)
        } else {
            transcriptFocus = nil
        }
        workspace.select(result.conversationID)
    }

    private func generateTitle(for id: UUID) {
        workspace.select(id)
        Task {
            guard workspace.selectedID == id else { return }
            await workspace.waitUntilSelectedConversationLoaded()
            guard workspace.selectedID == id else { return }
            workspace.generateTitle(id)
        }
    }

    private func conversationRow(_ conversation: DesktopConversationSearchResult) -> some View {
        let selected = workspace.selectedID == conversation.id
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: conversation.isPinned ? "pin.fill" : "bubble.left")
                .font(.system(size: 12))
                .foregroundStyle(conversation.isPinned ? DesktopTheme.accent : DesktopTheme.muted(scheme))
                .frame(width: 16)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(conversation.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    highlightedSnippet(conversation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(conversation.updatedAt, format: .dateTime.month(.twoDigits).day(.twoDigits))
                        .font(.system(size: 11))
                        .foregroundStyle(DesktopTheme.muted(scheme))
                        .fixedSize()
                        .help(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Spacer(minLength: 0)
            if workspace.generationConversationID == conversation.id {
                ProgressView().controlSize(.mini).help("这个会话正在生成")
            } else if workspace.titles.activeOwners.contains(conversation.id) {
                ProgressView().controlSize(.mini).help("正在生成会话标题")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .help("\(conversation.title)\n\(conversation.messageCount) 条消息 · \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(conversation.messageCount) 条消息")
    }

    private func highlightedSnippet(_ result: DesktopConversationSearchResult) -> Text {
        guard let range = result.matchRange else { return Text(result.snippet) }
        return Text(String(result.snippet[..<range.lowerBound]))
            + Text(String(result.snippet[range])).bold()
            + Text(String(result.snippet[range.upperBound...]))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
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
                Text(workspace.settings.selectedProvider?.selectedModel?.displayName ?? "选择模型")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
            }
            .help(workspace.settings.selectedModelID == nil ? "在设置中添加服务商与模型"
                : workspace.settings.selectedProvider.map { "\($0.name) · \($0.modelID)" } ?? "在设置中添加服务商与模型")
            .accessibilityLabel("选择服务商与模型")
            Button { insightsPresented.toggle() } label: { Image(systemName: "text.bubble") }
                .disabled(workspace.selectedConversation == nil || workspace.isLoading)
                .help("上下文与回顾")
                .accessibilityLabel("上下文与回顾")
                .popover(isPresented: $insightsPresented, arrowEdge: .bottom) {
                    DesktopConversationInsightsView(workspace: workspace)
                }
            Button { filesPresented = true } label: { Image(systemName: "folder") }
                .disabled(workspace.selectedID == nil || workspace.isLoading)
                .help("此会话的文件与产物")
                .accessibilityLabel("会话文件")
            Button { tasksPresented = true } label: {
                Image(systemName: "checklist")
                    .overlay(alignment: .topTrailing) {
                        if workspace.agentTasks.records.contains(where: { $0.approval != nil }) {
                            Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 4, y: -3)
                        }
                    }
            }
            .help("工具任务与待确认操作")
            .accessibilityLabel("任务工作台")
        }
    }

    @ViewBuilder private var exportActions: some View {
        Button("完整会话 JSON…") { DesktopFileActions.exportConversation(workspace) }
        Divider()
        Button("Markdown…") { DesktopFileActions.exportReadableConversation(workspace, format: .markdown) }
        Button("PDF…") { DesktopFileActions.exportReadableConversation(workspace, format: .pdf) }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("让想法，向前一步。")
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.6)
                .multilineTextAlignment(.center)
            Text("从一个问题开始，慢慢理清重要的事。")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { welcomeSuggestions }
                VStack(spacing: 8) { welcomeSuggestions }
            }
            .padding(.top, 6)
            if workspace.settings.selectedProvider?.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                SettingsLink { Label("配置服务商", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.borderedProminent)
                    .tint(DesktopTheme.accent)
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var welcomeSuggestions: some View {
        welcomeSuggestion("梳理一个想法", prompt: "帮我梳理一个想法，先从目标与关键问题开始。", symbol: "lightbulb")
        welcomeSuggestion("分析一份资料", prompt: "帮我分析一份资料，提炼重点、依据与待确认的问题。", symbol: "doc.text.magnifyingglass")
        welcomeSuggestion("整理一段文字", prompt: "帮我整理一段文字，让逻辑更清晰、表达更准确。", symbol: "text.alignleft")
    }

    private func welcomeSuggestion(_ title: String, prompt: String, symbol: String) -> some View {
        Button {
            workspace.draft = prompt
            composerFocusRequest += 1
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(DesktopTheme.raised(scheme), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.border(scheme)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(workspace.isLoading || workspace.isManagingBackup)
        .help("将建议写入草稿，编辑后再发送")
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(error).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if !workspace.isGenerating, !workspace.isMutatingBranch, let last = workspace.selectedConversation?.messages.last,
               last.role == .assistant, last.state == .failed || last.state == .cancelled {
                Button("重试") { workspace.retry() }.buttonStyle(.borderless)
            }
            Button { workspace.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("关闭错误提示")
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: DesktopTheme.contentWidth)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }
}

enum DesktopFileActions {
    @MainActor static func importConversation(_ workspace: DesktopWorkspace) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 Amber 导出的 JSON 会话文件"
        if panel.runModal() == .OK, let url = panel.url { workspace.importConversation(from: url) }
    }

    @MainActor static func exportConversation(_ workspace: DesktopWorkspace) {
        guard let conversation = workspace.selectedConversation else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let name = conversation.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(String(name.prefix(80))).json"
        if panel.runModal() == .OK, let url = panel.url { workspace.exportConversation(to: url) }
    }

    @MainActor static func addAttachments(_ workspace: DesktopWorkspace) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf, .text, .json, .sourceCode, .rtf, .html]
            + ["doc", "docx", "pptx"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "添加图片、PDF、DOC/DOCX、RTF、PPTX、文本或代码文件"
        if panel.runModal() == .OK { workspace.addAttachments(panel.urls) }
    }

    @MainActor static func exportReadableConversation(_ workspace: DesktopWorkspace, format: DesktopReadableExportFormat) {
        guard let conversation = workspace.selectedConversation else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .pdf ? [.pdf] : [UTType(filenameExtension: "md") ?? .plainText]
        let name = conversation.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(String(name.prefix(80))).\(format.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            workspace.exportReadableConversation(to: url, format: format)
        }
    }
}
