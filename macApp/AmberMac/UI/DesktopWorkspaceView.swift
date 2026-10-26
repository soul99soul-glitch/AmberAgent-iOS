import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopWorkspaceView: View {
    @Bindable var workspace: DesktopWorkspace
    let searchRequest: Int
    var findRequest = 0
    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchFocused: Bool
    @State private var renameID: UUID?
    @State private var renameTitle = ""
    @State private var deleteID: UUID?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var transcriptFocus: DesktopTranscriptFocus?
    @State private var insightsPresented = false
    @State private var shelfPresented = false
    @State private var filesPresented = false
    @State private var tasksPresented = false
    @State private var knowledgePresented = false
    @State private var backupPresented = false
    @State private var collaborationsPresented = false
    @State private var recipesPresented = false
    @State private var searchSettingsPresented = false
    @State private var imageGenerationOwner: ImageGenerationOwner?
    @State private var composerFocusRequest = 0
    @State private var hoveredRow: UUID?
    @State private var markTaps = 0
    @Namespace private var sidebarNamespace

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
                    DesktopTranscript(conversation: conversation, workspace: workspace, focusRequest: transcriptFocus, findRequest: findRequest)
                        .id(conversation.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                } else {
                    welcome
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
                if let error = workspace.errorMessage {
                    errorBanner(error)
                }
                if let task = workspace.agentTasks.records.first(where: { $0.conversationID == workspace.selectedID && $0.approval != nil }) {
                    DesktopToolApprovalCard(task: task, tasks: workspace.agentTasks)
                        .id(task.approval?.id)
                        .frame(maxWidth: DesktopTheme.contentWidth)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }
                DesktopComposer(workspace: workspace, focusRequest: composerFocusRequest)
                    .disabled(workspace.isLoading || workspace.isLoadingSelectedConversation || workspace.selectedConversationUnavailable || workspace.isManagingBackup)
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: workspace.selectedID)
            .background(DesktopTheme.paper)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DesktopAmberMark(size: 18, taps: $markTaps)
                Text("Amber").font(DesktopTheme.serif(size: 17, weight: .semibold)).foregroundStyle(DesktopTheme.ink)
                Spacer()
                Button { workspace.createConversation() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 14)).frame(width: 28, height: 28)
                }
                .buttonStyle(DesktopQuietButtonStyle())
                .disabled(workspace.isLoading || workspace.isManagingBackup)
                .help("新建会话 ⌘N")
                .accessibilityLabel("新建会话")
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
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
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .accessibilityLabel("清空搜索")
                } else {
                    Text("⇧⌘F").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? DesktopTheme.honeyEdge : DesktopTheme.hairline))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

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

            List {
                ForEach(sidebarGroups, id: \.title) { group in
                Section {
                    ForEach(group.items) { conversation in
                        conversationRow(conversation)
                            .tag(conversation.id)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                            .onTapGesture { selectResult(conversation) }
                            .accessibilityAddTraits(workspace.selectedID == conversation.id ? [.isSelected, .isButton] : .isButton)
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
                } header: {
                    Text(group.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .padding(.leading, 22)
                }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 32)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { moveSelection(-1) }
            .onKeyPress(.downArrow) { moveSelection(1) }
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
            Rectangle().fill(DesktopTheme.hairline).frame(height: 1)
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
            .font(.system(size: 13))
            .tint(DesktopTheme.inkSecondary)
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(height: 52)
        }
        .background(DesktopTheme.paper)
    }

    private func moveSelection(_ step: Int) -> KeyPress.Result {
        let ordered = sidebarGroups.flatMap(\.items)
        guard !ordered.isEmpty else { return .ignored }
        let index = ordered.firstIndex { $0.id == workspace.selectedID }.map { $0 + step } ?? 0
        guard ordered.indices.contains(index) else { return .handled }
        selectResult(ordered[index])
        return .handled
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

    private var sidebarGroups: [(title: String, items: [DesktopConversationSearchResult])] {
        if !workspace.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [("搜索结果", displayedConversations)]
        }
        let calendar = Calendar.current
        let pinned = displayedConversations.filter(\.isPinned)
        let rest = displayedConversations.filter { !$0.isPinned }
        let today = rest.filter { calendar.isDateInToday($0.updatedAt) }
        let week = rest.filter { !calendar.isDateInToday($0.updatedAt) && $0.updatedAt > calendar.date(byAdding: .day, value: -7, to: .now)! }
        let older = rest.filter { $0.updatedAt <= calendar.date(byAdding: .day, value: -7, to: .now)! }
        return [("置顶", pinned), ("今天", today), ("本周", week), ("更早", older)].filter { !$0.1.isEmpty }
    }

    private func conversationRow(_ conversation: DesktopConversationSearchResult) -> some View {
        let selected = workspace.selectedID == conversation.id
        let generating = workspace.generationConversationID == conversation.id
        let searching = !workspace.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? DesktopTheme.ink : DesktopTheme.inkSecondary)
                    .lineLimit(1)
                if searching {
                    highlightedSnippet(conversation)
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if generating {
                DesktopPulse()
                    .help("这个会话正在生成")
            } else if workspace.agentTasks.records.contains(where: { $0.conversationID == conversation.id && $0.approval != nil }) {
                Text("待批准").font(.system(size: 12, weight: .medium)).foregroundStyle(DesktopTheme.accent)
            } else if workspace.titles.activeOwners.contains(conversation.id) {
                ProgressView().controlSize(.mini).help("正在生成会话标题")
            } else {
                Text(Self.sidebarTime(conversation.updatedAt))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .padding(.vertical, searching ? 6 : 0)
        .background {
            if selected {
                DesktopTheme.glow(RoundedRectangle(cornerRadius: 8))
                    .matchedGeometryEffect(id: "sidebar-glow", in: sidebarNamespace)
            } else if hoveredRow == conversation.id {
                RoundedRectangle(cornerRadius: 8).fill(DesktopTheme.hover)
            }
        }
        .onHover { hoveredRow = $0 ? conversation.id : (hoveredRow == conversation.id ? nil : hoveredRow) }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: selected)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help("\(conversation.title)\n\(conversation.messageCount) 条消息 · \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(conversation.messageCount) 条消息")
    }

    private static func sidebarTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month(.defaultDigits).day())
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
                    .font(.system(size: 13))
                    .foregroundStyle(DesktopTheme.inkSecondary)
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
            Button { shelfPresented.toggle() } label: { Image(systemName: "pin") }
                .disabled(workspace.selectedConversation == nil || workspace.isLoading)
                .help("产物架")
                .accessibilityLabel("产物架")
                .popover(isPresented: $shelfPresented, arrowEdge: .bottom) {
                    DesktopArtifactShelfView(workspace: workspace) { messageID in
                        guard let conversationID = workspace.selectedID else { return }
                        transcriptFocus = DesktopTranscriptFocus(conversationID: conversationID, messageID: messageID)
                        shelfPresented = false
                    }
                }
            Button { filesPresented = true } label: { Image(systemName: "folder") }
                .disabled(workspace.selectedID == nil || workspace.isLoading)
                .help("此会话的文件与产物")
                .accessibilityLabel("会话文件")
            Button { tasksPresented = true } label: {
                Image(systemName: "checklist")
                    .symbolEffect(.bounce, value: workspace.agentTasks.records.filter { $0.status == .completed }.count)
                    .overlay(alignment: .topTrailing) {
                        if workspace.agentTasks.records.contains(where: { $0.approval != nil }) {
                            DesktopPulse().offset(x: 4, y: -3)
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
        VStack(spacing: 0) {
            Spacer()
            DesktopAmberMark(size: 48, taps: $markTaps, breathes: true)
                .padding(.bottom, 24)
            Text(Self.greeting)
                .font(DesktopTheme.serif(size: 32, weight: .medium))
                .foregroundStyle(DesktopTheme.ink)
                .padding(.bottom, 8)
            Text("从一个问题开始，Amber 会在需要时读文件、查资料，并在动手前问你。")
                .font(.system(size: 14))
                .foregroundStyle(DesktopTheme.inkTertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 32)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], spacing: 0) {
                welcomeSuggestion("梳理一个想法", prompt: "帮我梳理一个想法，先从目标与关键问题开始。", symbol: "lightbulb", divider: true)
                welcomeSuggestion("分析一份资料", prompt: "帮我分析一份资料，提炼重点、依据与待确认的问题。", symbol: "doc.text.magnifyingglass", divider: true)
                welcomeSuggestion("整理一段文字", prompt: "帮我整理一段文字，让逻辑更清晰、表达更准确。", symbol: "text.alignleft", divider: false)
                welcomeSuggestion("查一查最新进展", prompt: "帮我联网查一查这个话题的最新进展，并给出来源。", symbol: "globe", divider: false)
            }
            .frame(maxWidth: DesktopTheme.contentWidth)
            if workspace.settings.selectedProvider?.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                SettingsLink { Label("配置服务商", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.borderedProminent)
                    .tint(DesktopTheme.accent)
                    .padding(.top, 24)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Easter egg: the greeting follows the hour (and keeps a night owl company).
    private static var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 0..<5: "夜深了，还在想什么？"
        case 5..<11: "早上好，今天想推进什么？"
        case 11..<14: "中午好，先把哪件事理清？"
        case 14..<18: "下午好，今天想推进什么？"
        default: "晚上好，慢慢来。"
        }
    }

    private func welcomeSuggestion(_ title: String, prompt: String, symbol: String, divider: Bool) -> some View {
        Button {
            workspace.draft = prompt
            composerFocusRequest += 1
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(DesktopTheme.inkTertiary).frame(width: 18)
                Text(title).font(.system(size: 14)).foregroundStyle(DesktopTheme.inkSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .overlay(alignment: .bottom) {
                if divider { Rectangle().fill(DesktopTheme.hairline).frame(height: 1).padding(.horizontal, 12) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DesktopQuietButtonStyle())
        .disabled(workspace.isLoading || workspace.isManagingBackup)
        .help("将建议写入草稿，编辑后再发送")
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(DesktopTheme.accent)
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
        .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.honeyEdge, lineWidth: 0.5))
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

    @MainActor static func exportMessage(_ workspace: DesktopWorkspace, messageID: UUID) {
        guard let conversation = workspace.selectedConversation else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let name = conversation.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(String(name.prefix(80))) · 消息.md"
        if panel.runModal() == .OK, let url = panel.url { workspace.exportMessage(messageID, to: url) }
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
