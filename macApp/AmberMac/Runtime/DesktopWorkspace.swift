import Foundation
import Observation
@preconcurrency import GatewayCore

enum DesktopWorkspaceSurface: Equatable, Sendable {
    case chat
    case taskBoard
    case pluginView(pluginID: String, viewID: String)
}

@MainActor @Observable
final class DesktopWorkspace {
    private(set) var conversations: [DesktopConversation] = [] {
        // Views outside the transcript only need membership; publishing it separately keeps a streaming chunk
        // (which rewrites `conversations`) from re-rendering the composer, toolbar and window chrome.
        didSet {
            let loaded = Set(conversations.map(\.id))
            if loaded != loadedConversationIDs { loadedConversationIDs = loaded }
            let nonEmpty = Set(conversations.lazy.filter { !$0.messages.isEmpty }.map(\.id))
            if nonEmpty != nonEmptyConversationIDs { nonEmptyConversationIDs = nonEmpty }
        }
    }
    /// Set by the transcript while the reader drags or flicks it. Snapshots then reach the UI ~4×/s instead of ~30×/s
    /// so scrolling keeps the main thread; drain() still delivers every event, and normal pace resumes on release.
    @ObservationIgnored var transcriptIsUserScrolling = false
    private(set) var loadedConversationIDs: Set<UUID> = []
    private(set) var nonEmptyConversationIDs: Set<UUID> = []
    var selectedID: UUID?
    var draft = ""
    /// Composer mode: plain chat, or send the draft to the model council, which reports back into this conversation.
    var composerMode = DesktopComposerMode.chat
    private(set) var composerRunID: UUID?
    var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    private(set) var summaries: [DesktopConversationSummary] = [] {
        // New default-workspace folders are named after the conversation.
        didSet { for summary in summaries { files.locations.noteTitle(summary.title, for: summary.id) } }
    }
    private(set) var sidebarResults: [DesktopConversationSearchResult] = []
    private(set) var isSearching = false
    private(set) var searchErrorMessage: String?
    private var loadingConversationIDs: Set<UUID> = []
    var errorMessage: String?
    private(set) var isGenerating = false
    private(set) var isStopping = false
    private(set) var isLoading = true
    private var attachmentLoadCounts: [UUID: Int] = [:]
    var isReadingAttachments: Bool { selectedID.map { (attachmentLoadCounts[$0] ?? 0) > 0 } ?? false }
    private(set) var isMutatingBranch = false
    private(set) var isManagingBackup = false
    private(set) var backupStatusMessage: String?
    private(set) var backupErrorMessage: String?
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    @ObservationIgnored private var backupDataTasks: [UUID: Task<Data, Error>] = [:]
    private(set) var pendingAttachments: [DesktopImportedDocument] = []
    private(set) var generationConversationID: UUID?
    private var instructionQueue: [DesktopQueuedInstruction] = []
    let settings: DesktopSettings
    let insights: DesktopConversationInsights
    let artifactShelf: DesktopArtifactShelf
    let files: DesktopWorkspaceFiles
    let agentTasks: DesktopAgentTasks
    let knowledge: DesktopKnowledgeStore
    let mcp: DesktopMCPManager
    let collaborations: DesktopCollaborations
    let recipes: DesktopRecipeRuns
    let webDAV: DesktopWebDAVManager
    let notifications: DesktopNotifications
    let storageUsageSources: [DesktopStorageUsage.Source]
    let imageGeneration: DesktopImageGeneration
    let speech: DesktopSpeechPlayer
    let searchSettings: DesktopSearchSettings
    let plugins: DesktopPluginStore
    /// DeepSeek 专属 `/boost` 的会话级开关。
    let boost: DesktopDeepSeekBoostStore
    let titles = DesktopTitleGeneration()
    /// Set by the live app; previews and tests run without one.
    var scheduler: DesktopScheduler?
    var scheduleTriggers: DesktopScheduleTriggers?
    var gateway: DesktopGateway?
    var gatewayReporter: DesktopGatewayReporter?
    var gatewayControl: DesktopGatewayControl?
    var boardWriter: DesktopBoardWriter?

    @ObservationIgnored private var registryCache: (modified: Date, sessions: [SessionRecord])?

    /// The gateway's sessions, re-read only when registry.json changed (the board and badge poll every few seconds).
    private func gatewaySessions() -> [SessionRecord] {
        let url = GatewayPaths.resolve().registry
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let registryCache, registryCache.modified == modified { return registryCache.sessions }
        let sessions = Array(RegistryStore(url: url).load().sessions.values)
        registryCache = (modified, sessions)
        return sessions
    }

    /// Queues titles for the gateway's untitled sessions (polled by the live app while the gateway is on).
    func writeBoardTitles() {
        guard gateway?.isEnabled == true else { return }
        boardWriter?.queueTitles(gatewaySessions())
    }

    /// The 「生成会话标题」 model and key for DesktopBoardWriter; nil when none resolves.
    func boardWriterRequest() -> (DesktopProviderConfiguration, String)? { try? requestConfiguration(.title) }

    /// The task board: scheduled tasks, their runs, and the gateway's Claude Code / Codex sessions.
    func boardItems(now: Date = Date()) -> [AmberControl.BoardItem] {
        guard let scheduler else { return [] }
        let live = scheduledRunTaskConversations.map { taskID, conversation in
            DesktopBoard.LiveRun(taskID: taskID, sessionKey: gatewayReporter?.sessionKey(forConversation: conversation),
                approval: agentTasks.records.first { $0.conversationID == conversation && $0.status == .waiting }?.approval,
                conversationID: conversation)
        }
        let sessions = gateway?.isEnabled == true ? gatewaySessions() : []
        return DesktopBoard.build(tasks: scheduler.tasks, live: live, paused: scheduler.isPaused, sessions: sessions, now: now)
    }
    /// Active main column surface: conversation transcript, task board, or an Obsidian-style plugin workspace view.
    var activeSurface: DesktopWorkspaceSurface = .chat
    /// The main window shows the task board instead of a conversation (sidebar 「任务」, menu bar, notifications).
    var showsTaskBoard: Bool {
        get { activeSurface == .taskBoard && plugins.isCoreEnabled(.taskBoard) }
        set {
            if newValue {
                guard plugins.isCoreEnabled(.taskBoard) else { return }
                activeSurface = .taskBoard
            } else {
                activeSurface = .chat
            }
        }
    }

    func openChatSurface() {
        activeSurface = .chat
    }

    func openPluginView(pluginID: String, viewID: String) {
        guard plugins.activeWorkspaceViews.contains(where: { $0.pluginID == pluginID && $0.viewID == viewID }) else { return }
        activeSurface = .pluginView(pluginID: pluginID, viewID: viewID)
    }

    private func reconcilePluginState() {
        recipes.store.registeredTools = plugins.activeRecipeRegisteredTools()
        switch activeSurface {
        case .chat:
            break
        case .taskBoard:
            if !plugins.isCoreEnabled(.taskBoard) { activeSurface = .chat }
        case .pluginView(let pluginID, let viewID):
            if !plugins.activeWorkspaceViews.contains(where: { $0.pluginID == pluginID && $0.viewID == viewID }) {
                activeSurface = .chat
            }
        }
        if !plugins.isCoreEnabled(.collaborations), composerMode != .chat {
            composerMode = .chat
        }
    }
    /// Items that need the user, for the sidebar badge; refreshed by the board and the sidebar poll.
    private(set) var boardNeedsYouCount = 0

    func refreshBoardBadge(from items: [AmberControl.BoardItem]? = nil) {
        boardNeedsYouCount = (items ?? boardItems()).filter { $0.column == .needsYou }.count
    }
    private(set) var savingCollaborationRuns: Set<UUID> = []
    private(set) var savedCollaborationRuns: Set<UUID> = []
    private(set) var collaborationSaveErrors: [UUID: String] = [:]
    @ObservationIgnored private var collaborationSaveTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var selectedFiles: [DesktopWorkspaceFile] = []
    private(set) var selectedFilesTruncated = false
    /// Bumped when a workspace folder choice changes, so views showing locations re-read them.
    private(set) var workspaceLocationVersion = 0
    private(set) var fileErrorMessage: String?
    private(set) var fileStatusMessage: String?
    private(set) var isLoadingFiles = false
    private(set) var filePreview: DesktopImportedDocument?
    private(set) var filePreviewErrorMessage: String?
    private(set) var isLoadingFilePreview = false
    @ObservationIgnored private var filesToken = UUID()
    @ObservationIgnored private var fileTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var filePreviewToken = UUID()
    @ObservationIgnored private var fileErrors: [UUID: String] = [:]
    @ObservationIgnored private var fileReadFailures: Set<UUID> = []

    @ObservationIgnored private let storage: any DesktopConversationStorage
    @ObservationIgnored let provider: any DesktopTextProvider
    @ObservationIgnored private var persistence: Task<Void, Never>?
    @ObservationIgnored private var generation: DesktopGeneration?
    @ObservationIgnored private var generationID: UUID?
    @ObservationIgnored private var assistantID: UUID?
    @ObservationIgnored private var generationPrefixIDs: [UUID] = []
    @ObservationIgnored private var generationUsesTools = false
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var queuedRequestTask: Task<Void, Never>?
    @ObservationIgnored private var queuedRequestToken: UUID?
    @ObservationIgnored private var lastCheckpoint = Date.distantPast
    @ObservationIgnored private var drafts: [UUID: String] = [:]
    @ObservationIgnored private var attachments: [UUID: [DesktopImportedDocument]] = [:]
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var attachmentTasks: [UUID: (owner: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var conversationErrors: [UUID: String] = [:]
    @ObservationIgnored private var autoCompaction = DesktopAutoCompactionPolicy()
    /// Request-time context notices (budget trimming) shown next to the context panel.
    private(set) var contextNotices: [UUID: String] = [:]
    /// Fingerprint of the last request's turn-invariant prefix per conversation: equal values mean a provider
    /// that supports prefix caching can reuse it.
    private(set) var contextPrefixFingerprints: [UUID: UInt64] = [:]
    @ObservationIgnored private var unsavedConversationIDs: Set<UUID> = []
    @ObservationIgnored private var unsavedMetadataIDs: Set<UUID> = []
    @ObservationIgnored private var branchMutationTask: Task<Void, Never>?
    @ObservationIgnored private var branchMutationOwner: UUID?
    @ObservationIgnored private var branchGenerationCancelled = false
    /// Conversations a scheduled task is writing into right now; the composer and branch edits stay off them.
    private(set) var scheduledRunConversationIDs: Set<UUID> = []
    /// Scheduled runs in flight: task id → the conversation it writes into (task board).
    private(set) var scheduledRunTaskConversations: [UUID: UUID] = [:]
    @ObservationIgnored private var scheduledGenerations: [UUID: DesktopGeneration] = [:]

    @ObservationIgnored private var conversationLoads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchToken = UUID()
    @ObservationIgnored private var storedSearchResults: [DesktopConversationSearchResult] = []

    private enum WriteKind { case messages, metadata }
    private static let saveFailureMessage = "会话保存失败，当前内容仍在窗口中。请导出备份并检查磁盘空间或文件权限。"

    init(settings: DesktopSettings, storage: any DesktopConversationStorage,
         provider: any DesktopTextProvider, initialConversations: [DesktopConversation]? = nil,
         insights: DesktopConversationInsights? = nil, files: DesktopWorkspaceFiles = DesktopWorkspaceFiles(),
         agentTasks: DesktopAgentTasks? = nil, knowledge: DesktopKnowledgeStore? = nil,
         mcp: DesktopMCPManager? = nil, collaborations: DesktopCollaborations? = nil, recipes: DesktopRecipeRuns? = nil,
         webDAV: DesktopWebDAVManager? = nil, notifications: DesktopNotifications? = nil,
         storageUsageSources: [DesktopStorageUsage.Source]? = nil,
         imageGeneration: DesktopImageGeneration? = nil, speech: DesktopSpeechPlayer? = nil,
         searchSettings: DesktopSearchSettings? = nil, artifactShelf: DesktopArtifactShelf? = nil,
         plugins: DesktopPluginStore? = nil, boost: DesktopDeepSeekBoostStore? = nil) {
        self.settings = settings
        self.insights = insights ?? DesktopConversationInsights()
        self.artifactShelf = artifactShelf ?? DesktopArtifactShelf()
        self.files = files
        self.agentTasks = agentTasks ?? DesktopAgentTasks()
        self.boost = boost ?? DesktopDeepSeekBoostStore()
        self.knowledge = knowledge ?? DesktopKnowledgeStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-preview-knowledge-" + UUID().uuidString, isDirectory: true))
        self.mcp = mcp ?? DesktopMCPManager(store: DesktopMCPStore(
            defaults: UserDefaults(suiteName: "amber.preview.mcp." + UUID().uuidString)!, credentials: DesktopMemoryCredentials()))
        self.collaborations = collaborations ?? DesktopCollaborations(settings: settings, provider: provider)
        self.plugins = plugins ?? DesktopPluginStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("amber-preview-plugins-" + UUID().uuidString, isDirectory: true),
            defaults: UserDefaults(suiteName: "amber.preview.plugins." + UUID().uuidString)!,
            credentials: DesktopMemoryCredentials()
        )
        let defaultRecipeStore = DesktopRecipeStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("amber-preview-recipes-" + UUID().uuidString),
            registeredTools: self.plugins.activeRecipeRegisteredTools()
        )
        if let recipes {
            self.recipes = recipes
        } else {
            #if !AMBER_MAC_PREVIEW && canImport(Shared)
            if let agentProvider = provider as? DesktopAgentProvider {
                self.recipes = DesktopRecipeRuns(store: defaultRecipeStore, tasks: self.agentTasks) {
                    try await agentProvider.performRecipeTool(runID: $0, owner: $1, name: $2, argumentsJSON: $3)
                }
            } else {
                self.recipes = DesktopRecipeRuns(store: defaultRecipeStore, tasks: self.agentTasks)
            }
            #else
            self.recipes = DesktopRecipeRuns(store: defaultRecipeStore, tasks: self.agentTasks)
            #endif
        }
        self.webDAV = webDAV ?? DesktopWebDAVManager(defaults: UserDefaults(suiteName: "amber.preview.webdav." + UUID().uuidString)!,
            credentials: DesktopMemoryCredentials())
        self.notifications = notifications ?? DesktopNotifications(settings: settings)
        self.imageGeneration = imageGeneration ?? DesktopImageGeneration(settings: settings, files: files)
        self.speech = speech ?? DesktopSpeechPlayer(settings: settings)
        self.searchSettings = searchSettings ?? DesktopSearchSettings(
            defaults: UserDefaults(suiteName: "amber.preview.search." + UUID().uuidString)!, credentials: DesktopMemoryCredentials())
        self.storageUsageSources = storageUsageSources ?? [
            .init(id: "conversations", title: "会话与辅助记录", directories: [], note: "会话保存在内存中，不计为磁盘文件。"),
            .init(id: "workspaces", title: "会话文件与成果", directories: nil, note: "界面预览的独立临时工作区未统计。"),
            .init(id: "knowledge", title: "知识资料与记忆", directories: [self.knowledge.directory]),
            .init(id: "tasks", title: "工具任务记录", directories: nil, note: "界面预览的任务记录未统计。"),
            .init(id: "collaborations", title: "协作记录", directories: nil, note: "界面预览的协作记录未统计。"),
            .init(id: "recipes", title: "Recipe", directories: [self.recipes.store.directory.appendingPathComponent("recipes")])
        ]
        self.storage = storage
        self.provider = provider
        self.plugins.onStateChanged = { [weak self] in
            self?.reconcilePluginState()
        }
        reconcilePluginState()
        if let initialConversations {
            conversations = initialConversations
            summaries = DesktopConversationSummary.ordered(initialConversations.map(DesktopConversationSummary.init))
            refreshSidebar()
            selectedID = initialConversations.first?.id
            isLoading = false
            if let selectedID { self.insights.load(selectedID); reloadFiles() }
        } else { loadingTask = Task { await load() } }
    }

    var selectedConversation: DesktopConversation? { conversations.first { $0.id == selectedID } }
    var selectedQueuedMessages: [DesktopQueuedInstruction] { instructionQueue.filter { $0.conversationID == selectedID } }
    var canQueueInstruction: Bool {
        isSelectedConversationGenerating && !isStopping && !isReadingAttachments && pendingAttachments.isEmpty
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var isSelectedConversationGenerating: Bool { isGenerating && generationConversationID == selectedID }
    var isLoadingSelectedConversation: Bool { selectedID.map { loadingConversationIDs.contains($0) } ?? false }
    var selectedConversationUnavailable: Bool { selectedID.map { !loadedConversationIDs.contains($0) } ?? false }
    var hasSelectedConversation: Bool { selectedID.map(loadedConversationIDs.contains) ?? false }
    var selectedConversationHasMessages: Bool { selectedID.map(nonEmptyConversationIDs.contains) ?? false }
    var selectedConversationTitle: String {
        selectedConversation?.title ?? summaries.first { $0.id == selectedID }?.title ?? "Amber"
    }
    /// DeepSeek 专属 `/boost` 只在当前会话选中 DeepSeek 模型时可用。
    var isBoostAvailable: Bool { selectedID != nil && DesktopDeepSeekBoost.isDeepSeek(settings.selectedProvider) }
    /// 已开启且当前确实是 DeepSeek：此时该会话的 system 末尾会带上专属提示词。
    var isBoostActive: Bool { isBoostAvailable && boost.isEnabled(selectedID) }

    func toggleBoost() {
        guard let selectedID else { return }
        boost.setEnabled(!boost.isEnabled(selectedID), for: selectedID)
    }

    /// 输入框里的 `/boost` 按回车只切换开关，不把这段文字当成用户消息发出去。
    @discardableResult
    func toggleBoostFromDraft() -> Bool {
        guard composerMode == .chat, isBoostAvailable,
              draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == DesktopDeepSeekBoost.slash else { return false }
        toggleBoost()
        draft = ""
        return true
    }

    private func load() async {
        do {
            summaries = DesktopConversationSummary.ordered(try await storage.listSummaries())
            refreshSidebar()
            selectedID = summaries.first?.id
            reloadFiles()
            if let selectedID { await loadConversation(selectedID)?.value }
            await persistence?.value
        } catch { errorMessage = "读取会话列表失败。原始文件已保留，请重试启动或检查文件权限。" }
        isLoading = false
    }

    @discardableResult
    private func loadConversation(_ id: UUID) -> Task<Void, Never>? {
        guard conversations.contains(where: { $0.id == id }) == false else { return nil }
        if let task = conversationLoads[id] { return task }
        guard summaries.contains(where: { $0.id == id }) else { return nil }
        loadingConversationIDs.insert(id)
        let task = Task {
            defer { loadingConversationIDs.remove(id); conversationLoads[id] = nil }
            do {
                guard var value = try await storage.load(id) else {
                    throw DesktopRuntimeError.message("找不到会话文件。")
                }
                guard let summary = summaries.first(where: { $0.id == id }),
                      !conversations.contains(where: { $0.id == id }) else { return }
                value.title = summary.title
                value.isPinned = summary.isPinned
                let recovered = value.messages.contains { $0.state == .streaming }
                for index in value.messages.indices where value.messages[index].state == .streaming {
                    value.messages[index].state = .cancelled
                }
                conversations.append(value)
                updateSummary(value)
                if !unsavedConversationIDs.contains(id), !unsavedMetadataIDs.contains(id) {
                    conversationErrors[id] = nil
                    if selectedID == id { errorMessage = nil }
                }
                insights.load(id)
                if recovered { persist(value) }
            } catch {
                guard summaries.contains(where: { $0.id == id }) else { return }
                recordError("读取会话失败。原始文件已保留，请重新读取或检查文件权限。", owner: id)
            }
        }
        conversationLoads[id] = task
        return task
    }

    func reloadSelectedConversation() {
        guard let selectedID else { return }
        loadConversation(selectedID)
    }

    func waitUntilSelectedConversationLoaded() async {
        guard let selectedID else { return }
        await conversationLoads[selectedID]?.value
    }

    private var normalizedSearch: String { searchText.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    func retrySearch() { scheduleSearch() }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchToken = UUID()
        let token = searchToken
        let query = normalizedSearch
        storedSearchResults = []
        searchErrorMessage = nil
        isSearching = !query.isEmpty
        refreshSidebar()
        guard !query.isEmpty else { searchTask = nil; return }
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let results = try await storage.search(query)
                guard searchToken == token else { return }
                storedSearchResults = results
            } catch is CancellationError { return }
            catch {
                guard searchToken == token else { return }
                searchErrorMessage = "搜索失败，请重试或检查会话文件权限。"
            }
            guard searchToken == token else { return }
            isSearching = false
            refreshSidebar()
        }
    }

    func waitUntilSearchComplete() async { await searchTask?.value }

    private func refreshSidebar() {
        let query = normalizedSearch
        if query.isEmpty { sidebarResults = summaries.map(\.presentation); return }
        let loadedIDs = Set(conversations.map(\.id))
        let metadata = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let titleMatches = summaries.compactMap { $0.titleMatch(query) }
        let titleIDs = Set(titleMatches.map(\.conversationID))
        let current = DesktopConversationPresentation.search(conversations, query: query).filter { !titleIDs.contains($0.conversationID) }
        let stored = storedSearchResults.compactMap { result -> DesktopConversationSearchResult? in
            guard !loadedIDs.contains(result.conversationID), !titleIDs.contains(result.conversationID),
                  result.kind == .message, let summary = metadata[result.conversationID] else { return nil }
            return DesktopConversationSearchResult(conversationID: summary.id, title: summary.title,
                messageID: result.messageID, snippet: result.snippet, matchRange: result.matchRange,
                kind: .message, updatedAt: summary.updatedAt, messageCount: summary.messageCount, isPinned: summary.isPinned)
        }
        sidebarResults = Array((titleMatches + current + stored).sorted {
            if $0.kind != $1.kind { return $0.kind == .title }
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt.timeIntervalSince($1.updatedAt) > 0 }
            return $0.conversationID.uuidString < $1.conversationID.uuidString
        }.prefix(200))
    }

    private func updateSummary(_ conversation: DesktopConversation) {
        let value = DesktopConversationSummary(conversation)
        if let index = summaries.firstIndex(where: { $0.id == value.id }) { summaries[index] = value }
        else { summaries.append(value) }
        summaries = DesktopConversationSummary.ordered(summaries)
        refreshSidebar()
    }

    func createConversation() {
        guard !isLoading else { return }
        activeSurface = .chat
        saveDraft()
        let conversation = DesktopConversation()
        conversations.insert(conversation, at: 0)
        selectedID = conversation.id
        reloadFiles()
        draft = ""
        pendingAttachments = []
        errorMessage = nil
        persist(conversation)
    }

    func select(_ id: UUID) {
        guard summaries.contains(where: { $0.id == id }) else { return }
        activeSurface = .chat
        if selectedID != id {
            saveDraft()
            selectedID = id
            draft = drafts[id] ?? ""
            pendingAttachments = attachments[id] ?? []
            errorMessage = conversationErrors[id]
            reloadFiles()
        }
        insights.load(id)
        loadConversation(id)
    }

    private func saveDraft() {
        guard let selectedID else { return }
        drafts[selectedID] = draft
        attachments[selectedID] = pendingAttachments
    }

    func send() {
        if let selectedID, scheduledRunConversationIDs.contains(selectedID) {
            errorMessage = "定时任务正在这条会话中运行，请等它结束后再发送。"; return
        }
        if isSelectedConversationGenerating { queueInstruction(); return }
        guard !isLoading, !isGenerating, !isMutatingBranch, !isManagingBackup, !selectedConversationUnavailable else { return }
        guard !isReadingAttachments else { errorMessage = "附件正在读取，请稍候再发送。"; return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        do {
            let request = try requestConfiguration()
            if selectedID == nil { createConversation() }
            guard let id = selectedID, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
            let message = try provider.userMessage(id: UUID(), text: text,
                attachments: pendingAttachments.map(DesktopMessageAttachment.init))
            conversations[index].messages.append(message)
            if conversations[index].messages.count == 1 {
                conversations[index].title = String((text.isEmpty ? pendingAttachments.first?.name ?? "附件对话" : text).prefix(60))
                persistMetadata(conversations[index])
            }
            draft = ""
            pendingAttachments = []
            drafts[id] = nil
            attachments[id] = nil
            startGeneration(conversationID: id, configuration: request.0, apiKey: request.1)
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func queueInstruction() -> Bool {
        guard let owner = selectedID, let runID = generationID, generationConversationID == owner,
              !isStopping, !selectedConversationUnavailable else { return false }
        guard pendingAttachments.isEmpty, !isReadingAttachments else {
            recordError("生成中仅支持排队文本。请保留附件，停止当前生成后再发送。", owner: owner)
            return false
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        instructionQueue.append(.init(id: UUID(), conversationID: owner, runID: runID, text: text))
        draft = ""
        drafts[owner] = nil
        return true
    }

    func withdrawQueuedInstruction(_ id: UUID) {
        guard let item = instructionQueue.first(where: { $0.id == id }), item.status == .pending,
              summaries.contains(where: { $0.id == item.conversationID }) else { return }
        let existing = item.conversationID == selectedID ? draft : drafts[item.conversationID] ?? ""
        let restored = [existing, item.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if item.conversationID == selectedID { draft = restored }
        drafts[item.conversationID] = restored
        instructionQueue.removeAll { $0.id == id }
    }

    func sendQueuedInstructions() {
        guard !isGenerating, !isLoading, !isMutatingBranch, !isManagingBackup,
              queuedRequestTask == nil, let value = selectedConversation else { return }
        let owner = value.id
        guard unsavedConversationIDs.contains(owner) else { startQueuedRequest(owner: owner, runID: nil); return }
        persist(value)
        let writer = persistence
        let token = UUID()
        queuedRequestToken = token
        queuedRequestTask = Task { [weak self] in
            await writer?.value
            guard let self, self.queuedRequestToken == token else { return }
            self.queuedRequestTask = nil
            self.queuedRequestToken = nil
            guard !Task.isCancelled else { return }
            self.startQueuedRequest(owner: owner, runID: nil)
        }
    }

    func retryQueuedMessageSave() {
        guard let value = selectedConversation,
              selectedQueuedMessages.contains(where: { $0.status == .awaitingSave }) else { return }
        persist(value)
    }

    private func drainQueuedInstructions(owner: UUID, token: UUID) -> [DesktopMessage] {
        guard generationID == token, generationConversationID == owner, generationUsesTools, !isStopping else { return [] }
        let pending = instructionQueue.filter { $0.conversationID == owner && $0.runID == token && $0.status == .pending }
        do {
            let messages = try pending.map { try provider.userMessage(id: $0.id, text: $0.text, attachments: []) }
            let ids = Set(pending.map(\.id))
            for index in instructionQueue.indices where ids.contains(instructionQueue[index].id) {
                instructionQueue[index].status = .delivering
            }
            return messages
        } catch { recordError("排队指令尚未提交。\(error.localizedDescription)", owner: owner); return [] }
    }

    private func startQueuedRequest(owner: UUID, runID: UUID?) {
        guard !isGenerating, !isMutatingBranch, !isManagingBackup,
              let index = conversations.firstIndex(where: { $0.id == owner }),
              !unsavedConversationIDs.contains(owner) else { return }
        let pending = instructionQueue.filter {
            $0.conversationID == owner && $0.status == .pending && (runID == nil || $0.runID == runID)
        }
        guard !pending.isEmpty else { return }
        do {
            let request = try requestConfiguration(conversationID: owner)
            let messages = try pending.map { try provider.userMessage(id: $0.id, text: $0.text, attachments: []) }
            let ids = Set(pending.map(\.id))
            for queueIndex in instructionQueue.indices where ids.contains(instructionQueue[queueIndex].id) {
                instructionQueue[queueIndex].status = .delivering
            }
            conversations[index].messages.append(contentsOf: messages)
            startGeneration(conversationID: owner, configuration: request.0, apiKey: request.1)
        } catch { recordError("排队指令尚未发送，已保留在队列中。\(error.localizedDescription)", owner: owner) }
    }

    @discardableResult
    func retry() -> Task<Void, Never>? {
        guard let last = selectedConversation?.messages.last, last.role == .assistant,
              last.state == .failed || last.state == .cancelled else { return nil }
        return regenerate(last.id)
    }

    @discardableResult
    func regenerate(_ messageID: UUID) -> Task<Void, Never>? {
        guard let conversation = selectedConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[index].role == .assistant else { return nil }
        guard conversation.messages.prefix(index).contains(where: { $0.role == .user }) else {
            recordError("这条回复之前没有用户消息，无法重新生成。", owner: conversation.id); return nil
        }
        do {
            let request = try requestConfiguration()
            return mutateBranch(messageID: messageID, request: request) { conversation, responseID in
                try await self.storage.regenerate(conversation, messageID: messageID, responseID: responseID)
            }
        } catch { recordError(error.localizedDescription, owner: selectedID); return nil }
    }

    @discardableResult
    func editAndResend(_ messageID: UUID, text: String,
        completion: (@MainActor (Bool) -> Void)? = nil) -> Task<Void, Never>? {
        guard let message = selectedConversation?.messages.first(where: { $0.id == messageID }), message.canEdit else {
            completion?(false); return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            recordError("消息内容不能为空。", owner: selectedID); completion?(false); return nil
        }
        do {
            let request = try requestConfiguration()
            return mutateBranch(messageID: messageID, request: request, completion: completion) { conversation, responseID in
                try await self.storage.editMessage(conversation, messageID: messageID,
                    textPartIndex: message.editableTextPartIndex ?? 0, text: text, responseID: responseID)
            }
        } catch { recordError(error.localizedDescription, owner: selectedID); completion?(false); return nil }
    }

    @discardableResult
    func deleteMessage(_ messageID: UUID) -> Task<Void, Never>? {
        mutateBranch(messageID: messageID) { conversation, _ in
            try await self.storage.deleteMessage(conversation, messageID: messageID)
        }
    }

    @discardableResult
    func selectVariant(_ messageID: UUID, index: Int) -> Task<Void, Never>? {
        guard let message = selectedConversation?.messages.first(where: { $0.id == messageID }),
              message.variantIDs.indices.contains(index), message.variantIDs[index] != message.id else { return nil }
        let variantID = message.variantIDs[index]
        return mutateBranch(messageID: messageID) { conversation, _ in
            try await self.storage.selectVariant(conversation, messageID: messageID, variantID: variantID)
        }
    }

    private func mutateBranch(messageID: UUID, request: (DesktopProviderConfiguration, String)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil,
        action: @escaping @MainActor (DesktopConversation, UUID) async throws -> DesktopConversation) -> Task<Void, Never>? {
        guard !isLoading, !isGenerating, !isMutatingBranch, !isManagingBackup, let owner = selectedID,
              !scheduledRunConversationIDs.contains(owner),
              selectedConversation?.messages.contains(where: { $0.id == messageID }) == true else {
            completion?(false); return nil
        }
        isMutatingBranch = true
        branchMutationOwner = owner
        branchGenerationCancelled = false
        let precedingWrites = persistence
        let responseID = UUID()
        let task = Task {
            var committed = false
            defer {
                isMutatingBranch = false; branchMutationOwner = nil
                completion?(committed)
            }
            await precedingWrites?.value
            do {
                guard !unsavedConversationIDs.contains(owner), !unsavedMetadataIDs.contains(owner) else {
                    throw DesktopRuntimeError.message("会话尚未保存成功，请导出备份并检查磁盘后重试。")
                }
                guard let original = conversations.first(where: { $0.id == owner }) else { return }
                let saved = try await action(original, responseID)
                guard let index = conversations.firstIndex(where: { $0.id == owner }) else { return }
                conversations[index].messages = saved.messages
                conversations[index].canonicalJSON = saved.canonicalJSON
                conversations[index].updatedAt = saved.updatedAt
                updateSummary(conversations[index])
                if !unsavedConversationIDs.contains(owner), !unsavedMetadataIDs.contains(owner) {
                    conversationErrors[owner] = nil
                    if selectedID == owner { errorMessage = nil }
                }
                committed = true
                if let request {
                    if branchGenerationCancelled {
                        conversations[index].messages[conversations[index].messages.count - 1].state = .cancelled
                        persist(conversations[index])
                    } else {
                        startGeneration(conversationID: owner, configuration: request.0, apiKey: request.1,
                            preparedResponseID: responseID)
                    }
                }
            } catch { recordError("消息更改未保存，原分支已保留。\(error.localizedDescription)", owner: owner) }
        }
        branchMutationTask = task
        return task
    }

    private func requestConfiguration(_ auxiliary: DesktopAuxiliaryModelTask? = nil,
        conversationID: UUID? = nil) throws -> (DesktopProviderConfiguration, String) {
        let configuration: DesktopProviderConfiguration?
        if let auxiliary { configuration = settings.configuration(for: auxiliary) }
        else {
            let owner = conversationID ?? selectedID
            let hasImages = conversations.first(where: { $0.id == owner })?.messages.contains(where: { !$0.images.isEmpty }) == true
                || (owner == selectedID && pendingAttachments.contains(where: { $0.kind == .image }))
            configuration = try DesktopAuxiliaryRouting.chatConfiguration(settings: settings, hasImages: hasImages)
        }
        guard let config = configuration else { throw DesktopRuntimeError.message("请先在设置中添加并选择服务商。") }
        return try validatedRequest(config)
    }

    private func validatedRequest(_ config: DesktopProviderConfiguration) throws -> (DesktopProviderConfiguration, String) {
        try DesktopSettings.validateEndpoint(config.baseURL)
        guard !config.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopRuntimeError.message("请先在服务商设置中填写 Model ID。")
        }
        let key = try settings.apiKey(for: config.id)
        if config.authMode == .apiKey, key.isEmpty, !config.baseURL.hasPrefix("http://") {
            throw DesktopRuntimeError.message("请先在服务商设置中填写 API Key。本机模型可留空。")
        }
        return (config, key)
    }

    @discardableResult
    func generateTitle(_ id: UUID) -> Task<Void, Never>? {
        guard !isManagingBackup, !isMutatingBranch, generationConversationID != id else {
            recordError("请先结束这条会话的生成或保存，再生成标题。", owner: id); return nil
        }
        guard let conversation = conversations.first(where: { $0.id == id }), !conversation.messages.isEmpty else {
            recordError("请先打开有消息的会话，再生成标题。", owner: nil); return nil
        }
        do {
            let request = try requestConfiguration(.title)
            if let previous = titles.errors[id], conversationErrors[id] == previous {
                conversationErrors[id] = nil
                if selectedID == id, errorMessage == previous { errorMessage = nil }
            }
            let task = titles.generate(conversation: conversation, configuration: request.0, apiKey: request.1, provider: provider) { [weak self] title in
                guard let self, !isManagingBackup, let current = conversations.first(where: { $0.id == id }),
                      current.title == conversation.title,
                      current.messages.map(\.id) == conversation.messages.map(\.id),
                      current.messages.map(\.text) == conversation.messages.map(\.text) else { return false }
                rename(id, title: title)
                return true
            }
            return Task { [weak self] in
                await task?.value
                if let error = self?.titles.errors[id] { self?.recordError(error, owner: id) }
            }
        } catch { recordError(error.localizedDescription, owner: id); return nil }
    }

    func requestInsight(_ kind: DesktopInsightKind) {
        guard !isLoading, !isGenerating, !isMutatingBranch, !isManagingBackup, let conversation = selectedConversation else { return }
        do {
            let task: DesktopAuxiliaryModelTask = kind == .compact ? .compaction : kind == .recap ? .recap : .suggestions
            let request = try requestConfiguration(task)
            let owner = conversation.id
            insights.generate(kind, conversation: conversation, configuration: request.0, apiKey: request.1,
                provider: provider, isCurrent: { [weak self] ids in
                    self?.conversations.first(where: { $0.id == owner })?.messages.map(\.id) == ids
                })
        } catch { recordError(error.localizedDescription, owner: conversation.id) }
    }

    private func startGeneration(conversationID: UUID, configuration: DesktopProviderConfiguration, apiKey: String,
        preparedResponseID: UUID? = nil) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var messages = conversations[index].messages
        let replyID: UUID
        if let preparedResponseID {
            guard let reply = messages.last, reply.id == preparedResponseID, reply.role == .assistant else { return }
            replyID = preparedResponseID
            messages.removeLast()
        } else {
            let reply = DesktopMessage(role: .assistant, text: "", state: .streaming)
            replyID = reply.id
            conversations[index].messages.append(reply)
            conversations[index].updatedAt = Date()
            persist(conversations[index])
        }
        let prefixIDs = messages.map(\.id)
        do { messages = try requestMessages(messages, conversationID: conversationID,
            configuration: configuration) }
        catch {
            conversations[index].messages[conversations[index].messages.count - 1].state = .failed
            persist(conversations[index])
            recordError("读取本地知识上下文失败。\(error.localizedDescription)", owner: conversationID)
            return
        }
        if !unsavedConversationIDs.contains(conversationID), !unsavedMetadataIDs.contains(conversationID) {
            if selectedID == conversationID { errorMessage = nil }
            conversationErrors[conversationID] = nil
        }
        let token = UUID()
        generationID = token
        assistantID = replyID
        generationPrefixIDs = prefixIDs
        generationUsesTools = agentTasks.toolsEnabled || agentTasks.subagentsEnabled
        generationConversationID = conversationID
        isGenerating = true
        isStopping = false
        lastCheckpoint = Date()
        do {
            let run = try provider.start(configuration: configuration, apiKey: apiKey,
                messages: messages, responseID: replyID, context: DesktopRunContext(
                    conversationID: conversationID, toolsEnabled: agentTasks.toolsEnabled, subagentsEnabled: agentTasks.subagentsEnabled,
                    toolRounds: settings.agentToolRoundLimit, runMinutes: settings.agentRunMinutes,
                    persistTurns: { [weak self] turns in
                        guard let self else { return false }
                        return await self.persistAgentTurns(turns, owner: conversationID, token: token)
                    }, drainSteer: { [weak self] in
                        self?.drainQueuedInstructions(owner: conversationID, token: token) ?? []
                    }, historySnapshot: { [weak self] in
                        guard let self, let conversation = self.conversations.first(where: { $0.id == conversationID }) else {
                            return ([], [])
                        }
                        let covered = self.insights.checkpoint(for: conversation)?.coveredMessageIDs ?? []
                        return (conversation.messages, Set(covered))
                    }))
            generation = run
            generationTask = Task { [weak self] in
                for await _ in run.signals {
                    guard let self, self.generationID == token else { return }
                    self.apply(run.drain())
                    // Coalesce token bursts into ~30 layout passes a second; drain() returns everything that arrived.
                    try? await Task.sleep(for: .milliseconds(self.transcriptIsUserScrolling ? 250 : 33))
                }
            }
        } catch {
            clearGeneration()
            conversations[index].messages[conversations[index].messages.count - 1].state = .failed
            persist(conversations[index])
            recordError("无法开始生成，请检查服务商设置后重试。", owner: conversationID)
        }
    }

    /// History as the model sees it: compaction applied, a turn-invariant system prefix, memories recalled
    /// for the newest user text right before it, then a deterministic budget fit.
    private func requestMessages(_ history: [DesktopMessage], conversationID: UUID,
                                 configuration: DesktopProviderConfiguration) throws -> [DesktopMessage] {
        let model = configuration.selectedModel
        let knowledgeEnabled = plugins.isCoreEnabled(.knowledge)
        let stableContext = knowledgeEnabled ? try knowledge.stableContext() : ""
        let memoryContext = knowledgeEnabled
            ? try knowledge.requestMemoryContext(query: history.last(where: { $0.role == .user })?.text ?? "")
            : ""
        let stableSystem = [settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines), stableContext,
                            workspaceContext(conversationID) ?? "",
                            DesktopDeepSeekBoost.systemSuffix(enabled: boost.isEnabled(conversationID), configuration: configuration)]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        // The budget has to measure the whole request, but trimming may only touch turns: fit the history first
        // and pass the prefix and recall as overhead, so the system block can never be dropped.
        let overhead = [stableSystem, memoryContext].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let fit = DesktopContextBudget.fitting(
            insights.prepare(messages: history, conversationID: conversationID), model: model, extraText: overhead)
        var messages = fit.messages
        if !stableSystem.isEmpty { messages.insert(DesktopMessage(role: .system, text: stableSystem), at: 0) }
        contextPrefixFingerprints[conversationID] = DesktopContextBudget.prefixFingerprint(messages)
        // Recalled memories follow the newest user text and travel as a user turn: the Claude path flattens
        // every system message into the top-level system prompt, so a `.system` recall would rewrite the
        // turn-invariant prefix and read as a system rule.
        if !memoryContext.isEmpty, let lastUser = messages.lastIndex(where: { $0.role == .user }) {
            messages.insert(DesktopMessage(role: .user, text: memoryContext), at: lastUser)
        }
        contextNotices[conversationID] = fit.trimmed
            ? "本轮已省略最早的 \(fit.droppedCount) 条消息以满足模型窗口；原消息仍完整保留在会话中。"
            : nil
        return messages
    }

    private func apply(_ events: [DesktopProviderEvent], checkpoint: Bool = true) {
        guard let conversationID = generationConversationID,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var terminal: DesktopMessageState?
        for event in events {
            switch event {
            case .snapshot(let text, let reasoning, let canonicalJSON, let unsupportedPartCount, let tools):
                guard let messageID = assistantID,
                      let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == messageID }) else { continue }
                if conversations[index].messages[messageIndex].text != text { conversations[index].messages[messageIndex].text = text }
                if conversations[index].messages[messageIndex].reasoning != reasoning { conversations[index].messages[messageIndex].reasoning = reasoning }
                conversations[index].messages[messageIndex].canonicalJSON = canonicalJSON
                conversations[index].messages[messageIndex].unsupportedPartCount = unsupportedPartCount
                if conversations[index].messages[messageIndex].tools != tools { conversations[index].messages[messageIndex].tools = tools }
            case .transcript(let turns):
                guard !turns.isEmpty else { continue }
                let prefix = Array(conversations[index].messages.prefix(generationPrefixIDs.count))
                guard prefix.map(\.id) == generationPrefixIDs else { continue }
                // Agent events contain only new turns; compacted request input never replaces stored history.
                let previous = conversations[index].messages.dropFirst(prefix.count)
                var incoming = turns
                if let first = previous.first(where: { $0.role == .assistant }), !first.variantIDs.isEmpty,
                   let reply = incoming.firstIndex(where: { $0.role == .assistant }), incoming[reply].variantIDs.isEmpty {
                    incoming[reply].variantIDs = first.variantIDs.map { $0 == first.id ? incoming[reply].id : $0 }
                }
                conversations[index].messages = prefix + incoming
                assistantID = turns.last?.role == .assistant ? turns.last?.id : nil
            case .complete: terminal = .complete
            case .cancelled: terminal = .cancelled
            case .failed(let message): terminal = .failed; recordError(message, owner: conversationID)
            }
        }
        if let terminal {
            if assistantID == nil, terminal != .complete, conversations[index].messages.last?.role == .user {
                let reply = DesktopMessage(role: .assistant, text: "", state: terminal)
                conversations[index].messages.append(reply)
                assistantID = reply.id
            }
            if let messageID = assistantID,
               let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == messageID }) {
                conversations[index].messages[messageIndex].state = terminal
            }
            conversations[index].updatedAt = Date()
            persist(conversations[index])
            let writer = persistence
            let completedToken = generationID
            let notify = !generationUsesTools && (terminal == .complete || terminal == .failed)
            let canonicalIDs = Set(conversations[index].messages.map(\.id))
            for queueIndex in instructionQueue.indices where instructionQueue[queueIndex].conversationID == conversationID
                && instructionQueue[queueIndex].runID == completedToken && !canonicalIDs.contains(instructionQueue[queueIndex].id) {
                instructionQueue[queueIndex].status = .pending
            }
            clearGeneration()
            if notify, let completedToken {
                Task {
                    await writer?.value
                    guard !unsavedConversationIDs.contains(conversationID),
                          conversations.contains(where: { $0.id == conversationID }) else { return }
                    _ = await notifications.notify(runID: completedToken, conversationID: conversationID,
                        outcome: terminal == .complete ? .completed : .failed)
                }
            }
            if terminal == .complete, let completedToken,
               instructionQueue.contains(where: { $0.conversationID == conversationID && $0.runID == completedToken && $0.status == .pending }) {
                let followupToken = UUID()
                queuedRequestToken = followupToken
                queuedRequestTask = Task { [weak self] in
                    await writer?.value
                    guard let self, self.queuedRequestToken == followupToken else { return }
                    self.queuedRequestTask = nil
                    self.queuedRequestToken = nil
                    guard !Task.isCancelled else { return }
                    self.startQueuedRequest(owner: conversationID, runID: completedToken)
                }
            }
            if selectedID == conversationID { reloadFiles() }
            // A finished turn is the only safe place to compact: tool round trips and pending approvals live
            // inside a run, so compacting there would split one. A stopped or failed turn also leaves the
            // history in a state the summary could bake in, so only a completed turn triggers a compaction.
            if terminal == .complete { scheduleAutomaticCompaction(owner: conversationID) }
        } else if checkpoint, Date().timeIntervalSince(lastCheckpoint) >= 1 {
            lastCheckpoint = Date()
            persist(conversations[index])
        }
    }

    /// Produces a summary once an idle conversation approaches the model window, so the next turn starts
    /// from a compacted history instead of relying on the budget fit. The user's manual control
    /// (「压缩上下文」/「恢复完整上下文」) keeps working exactly as before.
    private func scheduleAutomaticCompaction(owner: UUID) {
        guard !isGenerating, !isLoading, !isMutatingBranch, !isManagingBackup,
              !scheduledRunConversationIDs.contains(owner), !insights.activeOwners.contains(owner),
              // A conversation that is not durably saved must not start another model call on top of it.
              !unsavedConversationIDs.contains(owner), !unsavedMetadataIDs.contains(owner),
              !agentTasks.records.contains(where: { $0.conversationID == owner && $0.approval != nil }),
              let conversation = conversations.first(where: { $0.id == owner }),
              let boundary = DesktopContextBudget.compactionBoundary(conversation.messages),
              autoCompaction.mayCompact(owner) else { return }
        // Measure what the next request would actually send: after a compaction that is the summary plus the
        // uncovered tail, so the same stored history does not trigger a fresh full summary every turn.
        guard DesktopContextBudget.needsCompaction(
            insights.prepare(messages: conversation.messages, conversationID: owner),
            model: settings.selectedProvider?.selectedModel, extraText: settings.systemPrompt) else { return }
        // Nothing new to fold in: the existing summary already covers everything the boundary would.
        let covered = insights.value(.compact, for: conversation)?.sourceMessageIDs.count ?? 0
        guard boundary > covered else { return }
        do {
            let request = try requestConfiguration(.compaction)
            // Snapshot the checkpoint count *before* the attempt: "is there a summary?" is true forever once one
            // exists, which made a failed retry look successful and defeated the cooldown.
            let before = insights.checkpointCount(owner)
            insights.generate(.compact, conversation: conversation, configuration: request.0,
                apiKey: request.1, provider: provider) { [weak self] ids in
                self?.conversations.first(where: { $0.id == owner })?.messages.map(\.id) == ids
            }
            // A failed attempt cools down instead of firing again on every following turn.
            Task { [weak self] in
                await self?.insights.waitUntilIdle(owner)
                guard let self else { return }
                let after = self.insights.checkpointCount(owner)
                self.autoCompaction.record(owner,
                    succeeded: DesktopAutoCompactionOutcome(before: before, after: after).succeeded)
            }
        } catch {
            // No auxiliary model configured: the request budget still protects the next turn.
        }
    }

    private func persistAgentTurns(_ turns: [DesktopMessage], owner: UUID, token: UUID) async -> Bool {
        guard generationID == token, generationConversationID == owner,
              let current = conversations.first(where: { $0.id == owner }),
              current.messages.prefix(generationPrefixIDs.count).map(\.id) == generationPrefixIDs else { return false }
        apply([.transcript(turns)], checkpoint: false)
        guard let value = conversations.first(where: { $0.id == owner }) else { return false }
        persist(value)
        let writer = persistence
        await writer?.value
        return generationID == token && generationConversationID == owner
            && conversations.contains(where: { $0.id == owner }) && !unsavedConversationIDs.contains(owner)
    }

    func stop() {
        queuedRequestTask?.cancel()
        queuedRequestTask = nil
        queuedRequestToken = nil
        if isMutatingBranch { branchGenerationCancelled = true }
        guard let generation, !isStopping else { return }
        isStopping = true
        generation.cancel()
        apply(generation.drain())
    }

    private func clearGeneration() {
        generation = nil
        generationID = nil
        generationConversationID = nil
        generationPrefixIDs = []
        generationUsesTools = false
        assistantID = nil
        isGenerating = false
        isStopping = false
    }

    func delete(_ id: UUID) {
        guard branchMutationOwner != id else { recordError("正在保存消息更改，请稍候再删除会话。", owner: id); return }
        guard let summary = summaries.first(where: { $0.id == id }) else { return }
        if imageGeneration.ownerID == id { imageGeneration.cancel() }
        scheduledGenerations[id]?.cancel()
        if generationConversationID == id {
            stop()
            if generationConversationID == id {
                generationTask?.cancel()
                generationTask = nil
                clearGeneration()
            }
        }
        for item in attachmentTasks.values where item.owner == id { item.task.cancel() }
        titles.cancel(id)
        recipes.cancel(conversationID: id)
        collaborations.cancel(parentConversationID: id)
        let recoverable = conversations.first { $0.id == id }
        let savedDraft = selectedID == id ? draft : drafts[id]
        let savedAttachments = selectedID == id ? pendingAttachments : attachments[id]
        let savedQueue = instructionQueue.filter { $0.conversationID == id }
        summaries.removeAll { $0.id == id }
        conversations.removeAll { $0.id == id }
        drafts[id] = nil
        attachments[id] = nil
        instructionQueue.removeAll { $0.conversationID == id }
        refreshSidebar()
        if selectedID == id {
            selectedID = nil
            reloadFiles()
            draft = ""
            pendingAttachments = []
            errorMessage = nil
            if let next = summaries.first?.id { select(next) }
        }
        enqueue {
            do {
                try await self.storage.delete(id)
                self.unsavedConversationIDs.remove(id)
                self.unsavedMetadataIDs.remove(id)
                self.conversationErrors[id] = nil
                self.fileErrors[id] = nil
                self.fileReadFailures.remove(id)
                self.insights.remove(id)
                self.boost.forget(id)
                var cleanupFailed = !self.artifactShelf.removeConversation(id)
                do { try await self.files.removeConversation(id) }
                catch { cleanupFailed = true }
                if cleanupFailed {
                    self.recordError("会话已删除，但产物架或工作区文件清理失败，请检查文件夹权限。", owner: nil)
                }
            } catch {
                if let recoverable { self.conversations.append(recoverable) }
                self.summaries = DesktopConversationSummary.ordered(self.summaries + [summary])
                self.refreshSidebar()
                self.drafts[id] = savedDraft
                self.attachments[id] = savedAttachments
                self.instructionQueue.append(contentsOf: savedQueue)
                if self.selectedID == nil { self.select(id) }
                self.recordError("删除失败，会话已恢复。请检查磁盘或文件权限后重试。", owner: id)
            }
        }
    }

    func rename(_ id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = summaries.firstIndex(where: { $0.id == id }) else { return }
        summaries[index].title = title
        if let full = conversations.firstIndex(where: { $0.id == id }) { conversations[full].title = title }
        let renamed = summaries[index]
        if !normalizedSearch.isEmpty { scheduleSearch() } else { refreshSidebar() }
        persistMetadata(renamed)
    }

    func togglePin(_ id: UUID) {
        guard let index = summaries.firstIndex(where: { $0.id == id }) else { return }
        let value = !summaries[index].isPinned
        summaries[index].isPinned = value
        if let full = conversations.firstIndex(where: { $0.id == id }) { conversations[full].isPinned = value }
        let summary = summaries[index]
        summaries = DesktopConversationSummary.ordered(summaries)
        refreshSidebar()
        persistMetadata(summary)
    }

    private func persist(_ value: DesktopConversation) {
        updateSummary(value)
        enqueue(ownerID: value.id) {
            let saved = try await self.storage.save(value)
            guard let index = self.conversations.firstIndex(where: { $0.id == value.id }) else { return }
            // Keep first-match semantics from the old linear searches without paying O(N²)
            // when a long conversation is checkpointed during streaming.
            var previousByID: [UUID: DesktopMessage] = [:]
            previousByID.reserveCapacity(value.messages.count)
            for message in value.messages where previousByID[message.id] == nil {
                previousByID[message.id] = message
            }
            var savedByID: [UUID: DesktopMessage] = [:]
            savedByID.reserveCapacity(saved.messages.count)
            for message in saved.messages where savedByID[message.id] == nil {
                savedByID[message.id] = message
            }
            let durableIDs = Set(savedByID.keys)
            self.instructionQueue.removeAll { $0.conversationID == value.id && durableIDs.contains($0.id) }
            // The saved full document is the next base; newer visible messages remain owned by their run.
            self.conversations[index].canonicalJSON = saved.canonicalJSON
            for messageIndex in self.conversations[index].messages.indices {
                let current = self.conversations[index].messages[messageIndex]
                guard let previous = previousByID[current.id], current == previous,
                      let actual = savedByID[current.id] else { continue }
                self.conversations[index].messages[messageIndex].canonicalJSON = actual.canonicalJSON
                self.conversations[index].messages[messageIndex].unsupportedPartCount = actual.unsupportedPartCount
                self.conversations[index].messages[messageIndex].variantIDs = actual.variantIDs
                self.conversations[index].messages[messageIndex].editableTextPartIndex = actual.editableTextPartIndex
                self.conversations[index].messages[messageIndex].editableText = actual.editableText
                self.conversations[index].messages[messageIndex].estimatedTokens = actual.estimatedTokens
                self.conversations[index].messages[messageIndex].images = actual.images
                self.conversations[index].messages[messageIndex].tools = actual.tools
            }
        }
    }

    private func persistMetadata(_ value: DesktopConversation) {
        updateSummary(value)
        persistMetadata(DesktopConversationSummary(value))
    }

    private func persistMetadata(_ value: DesktopConversationSummary) {
        enqueue(ownerID: value.id, kind: .metadata) {
            try await self.storage.updateMetadata(value.id, title: value.title, isPinned: value.isPinned)
            if !self.normalizedSearch.isEmpty { self.scheduleSearch() }
        }
    }

    private func enqueue(ownerID: UUID? = nil, kind: WriteKind = .messages,
        _ action: @escaping @MainActor () async throws -> Void) {
        let previous = persistence
        persistence = Task { [weak self] in
            await previous?.value
            do {
                try await action()
                if let ownerID {
                    if kind == .metadata { self?.unsavedMetadataIDs.remove(ownerID) }
                    else { self?.unsavedConversationIDs.remove(ownerID) }
                    if let self, !unsavedConversationIDs.contains(ownerID), !unsavedMetadataIDs.contains(ownerID),
                       conversationErrors[ownerID] == Self.saveFailureMessage {
                        conversationErrors[ownerID] = nil
                        if selectedID == ownerID, errorMessage == Self.saveFailureMessage { errorMessage = nil }
                    }
                }
            } catch {
                if let ownerID {
                    if kind == .metadata { self?.unsavedMetadataIDs.insert(ownerID) }
                    else {
                        self?.unsavedConversationIDs.insert(ownerID)
                        if let self {
                            let submitted = Set(conversations.first(where: { $0.id == ownerID })?.messages.map(\.id) ?? [])
                            for index in instructionQueue.indices where instructionQueue[index].conversationID == ownerID
                                && submitted.contains(instructionQueue[index].id) {
                                instructionQueue[index].status = .awaitingSave
                            }
                        }
                    }
                }
                self?.recordError(Self.saveFailureMessage, owner: ownerID)
            }
        }
    }

    private func recordError(_ message: String, owner: UUID?) {
        if let owner { conversationErrors[owner] = message }
        if owner == nil || selectedID == owner { errorMessage = message }
    }

    func conversationError(for owner: UUID) -> String? { conversationErrors[owner] }

    // App termination awaits the same serialized writer used by stream checkpoints.
    func flush() async -> Bool {
        for task in Array(fileTasks.values) { await task.value }
        return await flushConversationWrites()
    }

    private func flushConversationWrites() async -> Bool {
        if isStopping { await generationTask?.value }
        await queuedRequestTask?.value
        for item in Array(attachmentTasks.values) { await item.task.value }
        for task in Array(collaborationSaveTasks.values) { await task.value }
        await branchMutationTask?.value
        await persistence?.value
        let pending = conversations.filter { unsavedConversationIDs.contains($0.id) }
        for conversation in pending { persist(conversation) }
        let metadata = summaries.filter { unsavedMetadataIDs.contains($0.id) }
        for summary in metadata { persistMetadata(summary) }
        await persistence?.value
        return unsavedConversationIDs.isEmpty && unsavedMetadataIDs.isEmpty
    }
    func waitUntilLoaded() async { await loadingTask?.value }

    @discardableResult
    func addAttachments(_ urls: [URL]) -> Task<Void, Never>? {
        importAttachments { 
            var documents: [DesktopImportedDocument] = []
            for url in urls { documents.append(try await DesktopDocumentImport.read(url)) }
            return documents
        }
    }

    @discardableResult
    func addImageAttachment(data: Data, name: String = "剪贴板图片.png") -> Task<Void, Never>? {
        importAttachments { [try await DesktopDocumentImport.readImageData(data, name: name)] }
    }

    private func importAttachments(_ read: @escaping @Sendable () async throws -> [DesktopImportedDocument]) -> Task<Void, Never>? {
        guard !isLoading, !selectedConversationUnavailable else { return nil }
        if selectedID == nil { createConversation() }
        guard let owner = selectedID else { return nil }
        let token = UUID()
        attachmentLoadCounts[owner, default: 0] += 1
        let task = Task {
            defer {
                attachmentLoadCounts[owner, default: 1] -= 1
                if attachmentLoadCounts[owner] == 0 { attachmentLoadCounts[owner] = nil }
                attachmentTasks[token] = nil
            }
            var copied = false
            do {
                let imported = try await read()
                guard summaries.contains(where: { $0.id == owner }) else { return }
                let beforeCopy = selectedID == owner ? pendingAttachments : attachments[owner] ?? []
                try validateAttachmentBudget(beforeCopy + imported)
                for document in imported {
                    try Task.checkCancellation()
                    if let source = document.sourceURL { _ = try await files.importFile(conversationID: owner, from: source); copied = true }
                    else if let url = document.image?.dataURL, let comma = url.firstIndex(of: ","),
                            let data = Data(base64Encoded: String(url[url.index(after: comma)...])) {
                        _ = try await files.importData(conversationID: owner, name: document.name, data: data)
                        copied = true
                    }
                }
                guard summaries.contains(where: { $0.id == owner }) else { return }
                let existing = selectedID == owner ? pendingAttachments : attachments[owner] ?? []
                let result = existing + imported
                try validateAttachmentBudget(result)
                if selectedID == owner { reloadFiles() }
                attachments[owner] = result
                if selectedID == owner { pendingAttachments = result }
            } catch is CancellationError { }
            catch {
                let message = error.localizedDescription + (copied ? " 已导入的文件仍保存在会话工作区中。" : "")
                recordError(message, owner: owner)
                if copied, selectedID == owner { reloadFiles() }
            }
        }
        attachmentTasks[token] = (owner, task)
        return task
    }

    private func validateAttachmentBudget(_ documents: [DesktopImportedDocument]) throws {
        guard documents.count <= 8,
              documents.reduce(0, { $0 + $1.byteCount }) <= 64 * 1_024 * 1_024,
              documents.reduce(0, { $0 + $1.text.utf8.count }) <= 2_000_000 else {
            throw DesktopRuntimeError.message("一次最多添加 8 个附件，文件总计不超过 64 MB，提取文字不超过 2 MB。")
        }
    }

    func addGeneratedImageAttachments(_ documents: [DesktopImportedDocument], to owner: UUID) throws {
        guard !isManagingBackup else { throw DesktopRuntimeError.message("备份或恢复进行中，请完成后再加入附件。") }
        guard summaries.contains(where: { $0.id == owner }) else {
            throw DesktopRuntimeError.message("原会话已删除，生成的图片未加入附件。")
        }
        let existing = selectedID == owner ? pendingAttachments : attachments[owner] ?? []
        var ids = Set(existing.map(\.id))
        let result = existing + documents.filter { ids.insert($0.id).inserted }
        try validateAttachmentBudget(result)
        attachments[owner] = result
        if selectedID == owner { pendingAttachments = result; reloadFiles() }
    }

    func generateImages(ownerID: UUID, prompt: String, aspectRatio: IOSImageAspectRatio = .square,
                        count: Int = 1, style: String = "") async throws -> [DesktopGeneratedImageArtifact] {
        guard plugins.isCoreEnabled(.imageGeneration) else {
            throw DesktopRuntimeError.message("图片生成核心插件已停用，请先在设置 → 插件中启用。")
        }
        guard !isManagingBackup else { throw DesktopRuntimeError.message("备份或恢复进行中，请完成后再生成图片。") }
        guard summaries.contains(where: { $0.id == ownerID }) else {
            throw DesktopRuntimeError.message("原会话已删除，无法开始生成图片。")
        }
        return try await imageGeneration.generate(ownerID: ownerID, prompt: prompt,
            aspectRatio: aspectRatio, count: count, style: style)
    }

    func retryGeneratedImageSaving(ownerID: UUID) async throws -> [DesktopGeneratedImageArtifact] {
        guard !isManagingBackup else { throw DesktopRuntimeError.message("备份或恢复进行中，请完成后再保存图片。") }
        guard summaries.contains(where: { $0.id == ownerID }) else {
            throw DesktopRuntimeError.message("原会话已删除，无法保存生成的图片。")
        }
        return try await imageGeneration.retrySaving(ownerID: ownerID)
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        if let selectedID { attachments[selectedID] = pendingAttachments }
    }

    @discardableResult
    func reloadFiles() -> Task<Void, Never>? {
        fileStatusMessage = nil
        filesToken = UUID()
        let token = filesToken
        filePreviewToken = UUID()
        filePreview = nil
        filePreviewErrorMessage = nil
        isLoadingFilePreview = false
        selectedFiles = []
        selectedFilesTruncated = false
        fileErrorMessage = nil
        guard let owner = selectedID else { isLoadingFiles = false; return nil }
        fileErrorMessage = fileErrors[owner]
        isLoadingFiles = true
        return Task {
            do {
                let listing = try await files.listing(conversationID: owner)
                guard selectedID == owner, filesToken == token else { return }
                selectedFiles = listing.files
                selectedFilesTruncated = listing.truncated
                if fileReadFailures.remove(owner) != nil { recordFileError(nil, owner: owner) }
            } catch {
                guard selectedID == owner, filesToken == token else { return }
                recordFileError("读取工作区文件失败。请重试或检查文件夹权限。", owner: owner, isRead: true)
            }
            guard selectedID == owner, filesToken == token else { return }
            isLoadingFiles = false
        }
    }

    // MARK: workspace folder

    /// Folder in use by the selected conversation, or nil when it will be created on first use.
    var selectedWorkspaceFolder: URL? {
        _ = workspaceLocationVersion
        return selectedID.flatMap(files.locations.existingDirectory(for:))
    }

    var selectedWorkspaceKind: DesktopWorkspaceLocations.Kind {
        _ = workspaceLocationVersion
        return selectedID.map(files.locations.kind(of:)) ?? .legacy
    }

    var defaultWorkspaceFolder: URL? {
        _ = workspaceLocationVersion
        return files.locations.defaultRoot
    }

    func setDefaultWorkspaceFolder(_ url: URL?) {
        do { try files.locations.setDefaultRoot(url) }
        catch { recordError(error.localizedDescription, owner: nil) }
        workspaceLocationVersion += 1
    }

    /// Point the selected conversation at an existing folder. Files already in its old workspace stay there.
    func openWorkspaceFolder(_ url: URL) {
        guard let owner = selectedID else { return }
        do {
            try files.locations.bindExternal(url, to: owner)
            recordFileError(nil, owner: owner)
        } catch { recordFileError(error.localizedDescription, owner: owner) }
        workspaceLocationVersion += 1
        reloadFiles()
    }

    func closeWorkspaceFolder() {
        guard let owner = selectedID else { return }
        do { try files.locations.releaseExternal(owner) }
        catch { recordFileError("无法恢复默认工作区：\(error.localizedDescription)", owner: owner) }
        workspaceLocationVersion += 1
        reloadFiles()
    }

    /// Creates the folder if it only existed as a plan, so it can be shown in Finder.
    func materializeWorkspaceFolder() -> URL? {
        guard let owner = selectedID else { return nil }
        defer { workspaceLocationVersion += 1 }
        do { return try files.locations.directory(for: owner, create: true).url }
        catch { recordFileError(error.localizedDescription, owner: owner); return nil }
    }

    /// Tells the model which folder its file tools and terminal act on, when that is a folder the user can see.
    private func workspaceContext(_ owner: UUID) -> String? {
        switch files.locations.kind(of: owner) {
        case .legacy: return nil
        case .managed, .external:
            guard let url = files.locations.existingDirectory(for: owner) else { return nil }
            return "当前会话的工作区文件夹是 \(url.path)。workspace_file_* 工具的相对路径和 terminal_exec 的工作目录都以它为准。"
        }
    }

    @discardableResult
    func importWorkspaceFiles(_ urls: [URL]) -> Task<Void, Never>? {
        guard let owner = selectedID else { return nil }
        return performFileTask { [self] in
            do {
                for url in urls {
                    guard summaries.contains(where: { $0.id == owner }) else { return }
                    _ = try await files.importFile(conversationID: owner, from: url)
                }
                recordFileError(nil, owner: owner)
                if selectedID == owner { reloadFiles() }
            } catch {
                recordFileError("导入工作区文件失败。已成功导入的文件仍保留在工作区中。", owner: owner)
            }
        }
    }

    @discardableResult
    func deleteWorkspaceFile(_ path: String) -> Task<Void, Never>? {
        guard let owner = selectedID else { return nil }
        return performFileTask { [self] in
            do {
                try await files.delete(conversationID: owner, path: path)
                recordFileError(nil, owner: owner)
                if selectedID == owner { reloadFiles() }
            } catch { recordFileError("删除文件失败，原文件已保留。", owner: owner) }
        }
    }

    @discardableResult
    func exportWorkspaceFile(_ path: String, to url: URL) -> Task<Void, Never>? {
        guard let owner = selectedID else { return nil }
        return performFileTask { [self] in
            do {
                try await files.copy(conversationID: owner, path: path, to: url)
                recordFileError(nil, owner: owner)
            } catch { recordFileError("导出文件失败，请检查目标文件夹权限。", owner: owner) }
        }
    }

    @discardableResult
    func importKnowledgeFromWorkspaceFile(_ path: String) -> Task<Void, Never>? {
        guard let owner = selectedID else { return nil }
        fileStatusMessage = nil
        return performFileTask { [self] in
            do {
                let url = try await files.temporaryURL(conversationID: owner, path: path)
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                switch url.lastPathComponent {
                case "SKILL.md":
                    let name = try knowledge.importSkill(from: url)
                    if selectedID == owner { fileStatusMessage = "技能“\(name)”已导入，尚未启用；请在知识设置中检查后启用。" }
                case "SOUL.md":
                    try knowledge.importSoul(from: url)
                    if selectedID == owner { fileStatusMessage = "SOUL 已导入并用于后续请求。" }
                default: throw DesktopRuntimeError.message("请选择 SKILL.md 或 SOUL.md。")
                }
                recordFileError(nil, owner: owner)
            } catch { recordFileError(error.localizedDescription, owner: owner) }
        }
    }

    private func recordFileError(_ message: String?, owner: UUID, isRead: Bool = false) {
        guard summaries.contains(where: { $0.id == owner }) else { return }
        fileErrors[owner] = message
        if isRead { fileReadFailures.insert(owner) } else { fileReadFailures.remove(owner) }
        if selectedID == owner { fileErrorMessage = message }
    }

    @discardableResult
    func previewWorkspaceFile(_ path: String) -> Task<Void, Never>? {
        guard let owner = selectedID else { return nil }
        filePreviewToken = UUID()
        let token = filePreviewToken
        filePreview = nil
        filePreviewErrorMessage = nil
        isLoadingFilePreview = true
        return Task {
            do {
                let url = try await files.temporaryURL(conversationID: owner, path: path)
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let value = try await DesktopDocumentImport.read(url)
                guard selectedID == owner, filePreviewToken == token else { return }
                filePreview = DesktopImportedDocument(id: value.id, name: value.name, sourceURL: nil,
                    kind: value.kind, byteCount: value.byteCount, text: value.text, image: value.image,
                    pageCount: value.pageCount, note: value.note)
            } catch {
                guard selectedID == owner, filePreviewToken == token else { return }
                filePreviewErrorMessage = error.localizedDescription
            }
            guard selectedID == owner, filePreviewToken == token else { return }
            isLoadingFilePreview = false
        }
    }

    @discardableResult
    func exportConversation(to url: URL) -> Task<Void, Never>? {
        guard let owner = selectedID, selectedConversation != nil else { errorMessage = "请先读取要导出的会话。"; return nil }
        guard branchMutationOwner != owner else { recordError("正在保存消息更改，请稍候再导出。", owner: owner); return nil }
        if generationConversationID == owner, let generation { apply(generation.drain()) }
        if let conversation = conversations.first(where: { $0.id == owner }) { persist(conversation) }
        return performFileTask { [self] in
            do {
                _ = await flushConversationWrites()
                guard let conversation = conversations.first(where: { $0.id == owner }) else {
                    throw DesktopRuntimeError.message("会话已删除，无法导出。")
                }
                let document = try await storage.exportDocument(conversation)
                try await Task.detached { try DesktopFileIO.export(document, to: url) }.value
            } catch { recordError("导出失败，请检查目标文件夹权限并重试。", owner: owner) }
        }
    }

    @discardableResult
    func exportReadableConversation(to url: URL, format: DesktopReadableExportFormat) -> Task<Void, Never>? {
        guard let owner = selectedID, selectedConversation != nil else { errorMessage = "请先读取要导出的会话。"; return nil }
        guard branchMutationOwner != owner else { recordError("正在保存消息更改，请稍候再导出。", owner: owner); return nil }
        if generationConversationID == owner, let generation { apply(generation.drain()) }
        if let value = conversations.first(where: { $0.id == owner }) { persist(value) }
        return performFileTask { [self] in
            do {
                _ = await flushConversationWrites()
                guard let value = conversations.first(where: { $0.id == owner }) else {
                    throw DesktopRuntimeError.message("会话已删除，无法导出。")
                }
                switch format {
                case .markdown: try await DesktopConversationExport.writeMarkdown(value, to: url)
                case .pdf: try await DesktopConversationExport.writePDF(value, to: url)
                }
            } catch { recordError("导出失败，请检查目标文件夹权限并重试。", owner: owner) }
        }
    }

    @discardableResult
    func exportMessage(_ messageID: UUID, to url: URL) -> Task<Void, Never>? {
        guard let conversation = selectedConversation,
              let message = conversation.messages.first(where: { $0.id == messageID }) else { return nil }
        return performFileTask { [self] in
            do { try await DesktopConversationExport.writeMarkdown(message, title: conversation.title, to: url) }
            catch { recordError("导出失败，请检查目标文件夹权限并重试。", owner: conversation.id) }
        }
    }

    @discardableResult
    func runRecipe(name: String, inputs: [String: DesktopRecipeJSONValue]) -> UUID? {
        guard plugins.isCoreEnabled(.recipes) else {
            errorMessage = "Recipe 核心插件已停用，请先在设置 → 插件中启用。"
            return nil
        }
        guard !isLoading, !isManagingBackup, !selectedConversationUnavailable, let owner = selectedID else {
            errorMessage = "请先选择并读取完整会话，再执行 Recipe。"
            return nil
        }
        return recipes.start(name: name, inputs: inputs, conversationID: owner)
    }

    @discardableResult
    /// Starts the composer's collaboration mode with the draft as the objective; the result is saved into the
    /// owner conversation when the run ends, exactly like「保存到会话」in the collaboration panel.
    func sendCollaboration() {
        guard plugins.isCoreEnabled(.collaborations) else {
            errorMessage = "多模型协作核心插件已停用，请先在设置 → 插件中启用。"
            return
        }
        guard let owner = selectedID, composerMode == .council else { return }
        let objective = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { return }
        do {
            let runID = try collaborations.startCouncil(parentConversationID: owner, objective: objective, seats: [])
            draft = ""
            composerRunID = runID
            Task {
                _ = await collaborations.waitUntilFinished(runID)
                if composerRunID == runID { composerRunID = nil }
                await saveCollaborationResult(runID: runID)?.value
            }
        } catch { recordError(error.localizedDescription, owner: owner) }
    }

    func saveCollaborationResult(runID: UUID) -> Task<Void, Never>? {
        guard !isManagingBackup else { collaborationSaveErrors[runID] = "请等待备份完成后再保存协作结果。"; return nil }
        guard let initial = collaborations.runs.first(where: { $0.id == runID }), initial.status.isTerminal else {
            collaborationSaveErrors[runID] = "协作任务尚未结束，请完成后再保存。"
            return nil
        }
        guard savingCollaborationRuns.insert(runID).inserted else { return collaborationSaveTasks[runID] }
        collaborationSaveErrors[runID] = nil
        let owner = initial.parentConversationID
        let task = Task {
            defer { savingCollaborationRuns.remove(runID); collaborationSaveTasks[runID] = nil }
            guard let run = await collaborations.waitUntilFinished(runID) else {
                collaborationSaveErrors[runID] = "找不到此协作任务。"; return
            }
            guard summaries.contains(where: { $0.id == owner }) else {
                collaborationSaveErrors[runID] = "原会话已删除，无法保存协作结果。"; return
            }
            await loadConversation(owner)?.value
            guard generationConversationID != owner, !isMutatingBranch, let conversation = conversations.first(where: { $0.id == owner }) else {
                collaborationSaveErrors[runID] = "请先完成原会话的读取或生成，再保存协作结果。"; return
            }
            if conversation.messages.contains(where: { $0.id == runID }) { savedCollaborationRuns.insert(runID); return }
            let body = run.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? run.outputs.filter { !$0.text.isEmpty }.map { "## \($0.name)\n\n\($0.text)" }.joined(separator: "\n\n") : run.finalText
            guard !body.isEmpty else { collaborationSaveErrors[runID] = "此任务没有可保存的结果。"; return }
            isMutatingBranch = true
            branchMutationOwner = owner
            let previous = persistence
            let write = Task {
                defer { isMutatingBranch = false; branchMutationOwner = nil }
                await previous?.value
                do {
                    guard !unsavedConversationIDs.contains(owner), !unsavedMetadataIDs.contains(owner),
                          var latest = conversations.first(where: { $0.id == owner }) else {
                        throw DesktopRuntimeError.message("原会话尚未保存成功，请检查磁盘后重试。")
                    }
                    let path = "outputs/collaboration-" + runID.uuidString.lowercased() + ".md"
                    let document = "# \(run.isCouncil ? "议会" : "子代理")协作结果\n\n任务：\(run.objective)\n\n" + body
                    _ = try await files.write(conversationID: owner, path: path, data: Data(document.utf8))
                    latest.messages.append(DesktopMessage(id: runID, role: .assistant,
                        text: document + "\n\n已保存到会话文件：`" + path + "`。"))
                    latest.updatedAt = Date()
                    let saved = try await storage.save(latest)
                    guard let index = conversations.firstIndex(where: { $0.id == owner }) else { return }
                    conversations[index].messages = saved.messages
                    conversations[index].canonicalJSON = saved.canonicalJSON
                    conversations[index].updatedAt = saved.updatedAt
                    updateSummary(conversations[index])
                    savedCollaborationRuns.insert(runID)
                    if !unsavedConversationIDs.contains(owner), !unsavedMetadataIDs.contains(owner) {
                        conversationErrors[owner] = nil
                        if selectedID == owner { errorMessage = nil }
                    }
                    if selectedID == owner { reloadFiles() }
                } catch {
                    let message = "保存协作结果失败：" + error.localizedDescription
                    collaborationSaveErrors[runID] = message
                    recordError(message, owner: owner)
                    if selectedID == owner { reloadFiles() }
                }
            }
            persistence = write
            branchMutationTask = write
            await write.value
        }
        collaborationSaveTasks[runID] = task
        return task
    }

    func makeBackupData(password: String?) async throws -> Data {
        guard beginBackup() else { throw DesktopRuntimeError.message(backupErrorMessage ?? "当前无法备份。") }
        let token = UUID()
        let operation = Task<Data, Error> {
            _ = await flush()
            try Task.checkCancellation()
            let value = try await backupCoordinator.snapshot(current: conversations)
            let encode = Task.detached { try DesktopBackup.encode(value, password: password) }
            return try await withTaskCancellationHandler { try await encode.value } onCancel: { encode.cancel() }
        }
        backupDataTasks[token] = operation
        defer { backupDataTasks[token] = nil; isManagingBackup = false }
        let data = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        // A completed snapshot may be cancelled before its caller resumes and starts a remote upload.
        guard !operation.isCancelled else { throw CancellationError() }
        try Task.checkCancellation()
        return data
    }

    @discardableResult
    func exportBackup(to url: URL, password: String?) -> Task<Void, Never>? {
        guard beginBackup() else { return nil }
        let task = Task {
            defer { isManagingBackup = false }
            do {
                _ = await flush()
                let value = try await backupCoordinator.snapshot(current: conversations)
                let encode = Task.detached { try DesktopBackup.encode(value, password: password) }
                let data = try await withTaskCancellationHandler { try await encode.value } onCancel: { encode.cancel() }
                try Task.checkCancellation()
                try await Task.detached { try DesktopFileIO.exportData(data, to: url) }.value
                backupStatusMessage = "备份已导出。" + ((password?.isEmpty ?? true) ? "此文件未加密，请妥善保存。" : "文件已使用密码加密。")
            } catch is CancellationError { backupStatusMessage = "备份已取消。" }
            catch { backupErrorMessage = "备份失败：" + error.localizedDescription }
        }
        backupTask = task
        return task
    }

    @discardableResult
    func importBackup(from url: URL, password: String?) -> Task<Void, Never>? {
        restoreBackup {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            try Task.checkCancellation()
            return try DesktopBackup.decode(Data(contentsOf: url), password: password)
        }
    }

    @discardableResult
    func importBackup(data: Data, password: String?) -> Task<Void, Never>? {
        restoreBackup { try DesktopBackup.decode(data, password: password) }
    }

    /// Imports conversations from an iOS `.amberbackup` as new copies; iOS settings and credentials are skipped.
    @discardableResult
    func importIOSBackup(from url: URL, password: String?) -> Task<Void, Never>? {
        restoreBackup(note: Self.iosBackupNote) {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            try Task.checkCancellation()
            return try DesktopIOSBackup.payload(Data(contentsOf: url), passphrase: password)
        }
    }

    @discardableResult
    func importIOSBackup(data: Data, password: String?) -> Task<Void, Never>? {
        restoreBackup(note: Self.iosBackupNote) { try DesktopIOSBackup.payload(data, passphrase: password) }
    }

    private static func iosBackupNote(_ restored: DesktopBackupRestoreResult) -> String {
        "已从 iOS 备份导入 \(restored.conversations.count) 个会话副本，现有内容已保留。iOS 的设置、服务商与凭证不会导入。"
    }

    private func restoreBackup(note: (@MainActor (DesktopBackupRestoreResult) -> String)? = nil,
                               _ read: @escaping @Sendable () throws -> DesktopBackupPayload) -> Task<Void, Never>? {
        guard beginBackup() else { return nil }
        let task = Task {
            defer { isManagingBackup = false }
            do {
                let operation = Task.detached { try read() }
                let value = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
                guard await flush() else { throw DesktopRuntimeError.message("现有会话尚未保存，请先导出会话备份并检查磁盘。") }
                let restored = try await backupCoordinator.restore(value)
                for conversation in restored.conversations {
                    conversations.append(conversation)
                    updateSummary(conversation)
                }
                if let id = restored.knowledgeConversationID ?? restored.conversations.first?.id { select(id) }
                backupStatusMessage = note?(restored) ?? restored.message
            } catch is CancellationError { backupStatusMessage = "恢复已取消，现有内容已保留。" }
            catch { backupErrorMessage = "恢复失败：" + error.localizedDescription }
        }
        backupTask = task
        return task
    }

    func cancelBackup() {
        backupTask?.cancel()
        for task in backupDataTasks.values { task.cancel() }
    }
    func waitUntilBackupFinished() async {
        await backupTask?.value
        for task in Array(backupDataTasks.values) { _ = try? await task.value }
    }

    private var backupCoordinator: DesktopBackupCoordinator {
        DesktopBackupCoordinator(storage: storage, files: files, insights: insights, settings: settings, knowledge: knowledge,
            artifactShelf: artifactShelf)
    }

    private func beginBackup() -> Bool {
        guard !isLoading, !isGenerating, !isMutatingBranch, !isManagingBackup, insights.activeOwners.isEmpty,
              !imageGeneration.isRunning, titles.activeOwners.isEmpty, !recipes.operations.contains(where: \.isRunning) else {
            backupErrorMessage = "请先结束生成或正在进行的会话更改，再执行备份或恢复。"
            return false
        }
        isManagingBackup = true
        backupErrorMessage = nil
        backupStatusMessage = nil
        return true
    }

    @discardableResult
    func importConversation(from url: URL) -> Task<Void, Never>? {
        guard !isLoading else { errorMessage = "正在读取会话，请稍候再导入。"; return nil }
        return performFileTask { [self] in
            do {
                let document = try await Task.detached { try DesktopFileIO.readConversationDocument(from: url) }.value
                var conversation = try await storage.normalizeImport(document)
                // Import creates a copy, so a file never overwrites a live conversation.
                conversation.id = UUID()
                for index in conversation.messages.indices {
                    if conversation.messages[index].state == .streaming { conversation.messages[index].state = .cancelled }
                }
                await persistence?.value
                let saved = try await storage.save(conversation)
                saveDraft()
                conversations.insert(saved, at: 0)
                updateSummary(saved)
                selectedID = saved.id
                showsTaskBoard = false
                reloadFiles()
                insights.load(saved.id)
                draft = ""
                pendingAttachments = []
            } catch { errorMessage = "导入失败。请选择 Amber 导出的完整会话 JSON；已有会话未更改。" }
        }
    }

    private func performFileTask(_ action: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let token = UUID()
        let task = Task {
            defer { fileTasks[token] = nil }
            await action()
        }
        fileTasks[token] = task
        return task
    }
}

// MARK: - Scheduled runs
// Headless: never reads or changes selectedID, draft, attachments or the composer's generation slot, so a
// scheduled task can run next to the user's own chat (the scheduler caps how many run at once).
extension DesktopWorkspace {
    func runScheduled(_ task: DesktopScheduledTask, scheduledFor: Date? = nil,
        clock: @escaping @MainActor () -> Date = Date.init,
        approvalPollInterval: Duration = .seconds(30)) async -> DesktopScheduleRunRecord {
        let startedAt = clock()
        var record = DesktopScheduleRunRecord(scheduledFor: scheduledFor, startedAt: startedAt, status: .running)
        func failed(_ message: String) -> DesktopScheduleRunRecord {
            record.status = .failed; record.error = message; record.finishedAt = clock(); return record
        }
        await waitUntilLoaded()
        if let error = task.validationError { return failed(error) }
        guard !isManagingBackup else { return failed("正在备份或恢复，本次未运行。") }

        let conversationID: UUID
        let isNew: Bool
        switch task.output {
        case .newConversation:
            var conversation = DesktopConversation()
            conversation.title = Self.scheduledTitle(task.name, at: startedAt)
            conversations.insert(conversation, at: 0)
            conversationID = conversation.id
            isNew = true
        case .appendTo(let id):
            guard summaries.contains(where: { $0.id == id }) else { return failed("结果会话已删除，请编辑任务重新选择。") }
            await loadConversation(id)?.value
            guard conversations.contains(where: { $0.id == id }) else { return failed("无法读取结果会话。") }
            guard generationConversationID != id, branchMutationOwner != id, !scheduledRunConversationIDs.contains(id) else {
                return failed("结果会话正在生成或保存，本次未运行。")
            }
            conversationID = id
            isNew = false
        }
        record.conversationID = conversationID
        scheduledRunConversationIDs.insert(conversationID)
        scheduledRunTaskConversations[task.id] = conversationID
        agentTasks.unattendedConversations[conversationID] = task.name
        gatewayReporter?.runStarted(runID: record.id, conversationID: conversationID, taskName: task.name)
        defer {
            scheduledRunConversationIDs.remove(conversationID); scheduledGenerations[conversationID] = nil
            scheduledRunTaskConversations[task.id] = nil
            agentTasks.unattendedConversations[conversationID] = nil
            gatewayReporter?.runFinished(conversationID: conversationID, succeeded: record.status == .completed,
                quiet: record.status == .completed && record.noteworthy == false)
        }

        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return failed("结果会话已删除。") }
        let request: (DesktopProviderConfiguration, String)
        let user: DesktopMessage
        do {
            let hasImages = conversations[index].messages.contains { !$0.images.isEmpty }
            let configuration: DesktopProviderConfiguration?
            if let modelID = task.modelID {
                configuration = settings.configuration(forModelID: modelID)
                guard configuration != nil else { throw DesktopRuntimeError.message("任务指定的模型已删除或停用，请编辑任务重新选择。") }
            } else { configuration = try DesktopAuxiliaryRouting.chatConfiguration(settings: settings, hasImages: hasImages) }
            guard let configuration else { throw DesktopRuntimeError.message("请先在设置中添加并选择服务商。") }
            request = try validatedRequest(configuration)
            user = try provider.userMessage(id: UUID(), text: task.prompt, attachments: [])
        } catch {
            if isNew { conversations.removeAll { $0.id == conversationID } }
            return failed(error.localizedDescription)
        }
        conversations[index].messages.append(user)
        let prefixIDs = conversations[index].messages.map(\.id)
        let history = conversations[index].messages
        let reply = DesktopMessage(role: .assistant, text: "", state: .streaming)
        conversations[index].messages.append(reply)
        conversations[index].updatedAt = clock()
        persist(conversations[index])
        if isNew { persistMetadata(conversations[index]) }

        let run: DesktopGeneration
        do {
            let messages = try requestMessages(history, conversationID: conversationID,
                configuration: request.0)
            run = try provider.start(configuration: request.0, apiKey: request.1, messages: messages, responseID: reply.id,
                context: DesktopRunContext(conversationID: conversationID, toolsEnabled: task.toolsEnabled,
                    subagentsEnabled: task.subagentsEnabled, approvalPolicy: task.approval.policy,
                    persistTurns: { [weak self] turns in
                        await self?.persistScheduledTurns(turns, owner: conversationID, prefixIDs: prefixIDs) ?? false
                    }, historySnapshot: { [weak self] in
                        // An unattended run reads the same transcript as a chat run; without this the
                        // history tools answered "没有可检索的历史记录" while the session was right there.
                        guard let self, let conversation = self.conversations.first(where: { $0.id == conversationID }) else {
                            return ([], [])
                        }
                        let covered = self.insights.checkpoint(for: conversation)?.coveredMessageIDs ?? []
                        return (conversation.messages, Set(covered))
                    }))
        } catch {
            finishScheduledReply(owner: conversationID, replyID: reply.id, state: .failed)
            await persistence?.value
            return failed("无法开始运行：\(error.localizedDescription)")
        }
        scheduledGenerations[conversationID] = run

        // Unanswered approvals fail the run once the task's timeout passes.
        let timeout = TimeInterval(task.approval.approvalTimeoutHours * 3600)
        let watchdog = Task { [weak self] () -> Bool in
            while !Task.isCancelled {
                try? await Task.sleep(for: approvalPollInterval)
                guard let self, !Task.isCancelled else { return false }
                if let waiting = self.agentTasks.records.first(where: {
                    $0.conversationID == conversationID && $0.status == .waiting
                        && $0.createdAt.timeIntervalSince(startedAt.addingTimeInterval(-1)) >= 0
                }), clock().timeIntervalSince(waiting.updatedAt) >= timeout {
                    self.agentTasks.cancel(waiting.id)
                    run.cancel()
                    return true
                }
            }
            return false
        }
        let outcome = await withTaskCancellationHandler {
            await consumeScheduled(run, owner: conversationID, prefixIDs: prefixIDs, replyID: reply.id)
        } onCancel: { run.cancel() }
        watchdog.cancel()
        let timedOut = await watchdog.value
        await persistence?.value

        let agentRun = agentTasks.records.first { $0.conversationID == conversationID
            && $0.createdAt.timeIntervalSince(startedAt.addingTimeInterval(-1)) >= 0 }
        record.agentRunID = agentRun?.id
        record.autoApprovedTools = agentRun?.transactions.filter { $0.autoApproved == true }.map(\.name) ?? []
        record.finishedAt = clock()
        if timedOut {
            record.status = .failed
            record.error = "审批等待超过 \(task.approval.approvalTimeoutHours) 小时未处理，本次运行记为失败。"
        } else if outcome.state == .complete {
            record.status = .completed
        } else {
            record.status = .failed
            record.error = outcome.state == .cancelled ? "运行已取消。" : outcome.error ?? "运行未完成。"
        }
        if unsavedConversationIDs.contains(conversationID) || !conversations.contains(where: { $0.id == conversationID }) {
            record.status = .failed
            record.error = record.error ?? "运行结果未能保存，请检查磁盘空间或文件权限。"
        }
        // The conversation is done: hand it back to the user before the (slow) summary call. The board keeps showing
        // the run until it returns.
        scheduledRunConversationIDs.remove(conversationID); scheduledGenerations[conversationID] = nil
        // A watchtower run that found nothing new stays quiet on the board and in Notification Center: that is the
        // whole point of a page watcher, and it overrides the title model's judgement because it is factual.
        if record.status == .completed,
           let reply = conversations.first(where: { $0.id == conversationID })?.messages.last(where: { $0.role == .assistant }),
           let quiet = DesktopWatchtower.quietVerdict(tools: reply.tools) {
            record.noteworthy = !quiet
            if quiet { record.summary = record.summary ?? "网页无变化" }
        }
        // Failed runs notify anyway; a completed one gets a line and a noteworthy flag (B6 reads it).
        if record.status == .completed, let boardWriter,
           let reply = conversations.first(where: { $0.id == conversationID })?.messages.last(where: { $0.role == .assistant })?.text,
           let result = await boardWriter.summarize(reply) {
            record.summary = result.summary
            // The watcher's own verdict wins: a quiet page must not be turned into noise by the summary model.
            record.noteworthy = record.noteworthy ?? result.noteworthy
        }
        return record
    }

    /// Stops every scheduled run (quit, pause all). Each run records itself as cancelled.
    func cancelScheduledRuns() {
        for run in scheduledGenerations.values { run.cancel() }
    }

    static func scheduledTitle(_ name: String, at date: Date) -> String {
        "⏱ \(name) · " + date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute())
    }

    private func consumeScheduled(_ run: DesktopGeneration, owner: UUID, prefixIDs: [UUID],
        replyID: UUID) async -> (state: DesktopMessageState, error: String?) {
        var assistantID: UUID? = replyID
        var lastCheckpoint = Date()
        var result: (state: DesktopMessageState, error: String?)?
        func apply(_ events: [DesktopProviderEvent]) {
            guard result == nil else { return }
            for event in events {
                guard let index = conversations.firstIndex(where: { $0.id == owner }) else { result = (.failed, "结果会话已删除。"); return }
                switch event {
                case .snapshot(let text, let reasoning, let canonicalJSON, let unsupportedPartCount, let tools):
                    guard let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == assistantID }) else { continue }
                    conversations[index].messages[messageIndex].text = text
                    conversations[index].messages[messageIndex].reasoning = reasoning
                    conversations[index].messages[messageIndex].canonicalJSON = canonicalJSON
                    conversations[index].messages[messageIndex].unsupportedPartCount = unsupportedPartCount
                    conversations[index].messages[messageIndex].tools = tools
                if conversations[index].messages[messageIndex].tools != tools { conversations[index].messages[messageIndex].tools = tools }
                case .transcript(let turns):
                    guard !turns.isEmpty, replaceScheduledSuffix(turns, owner: owner, prefixIDs: prefixIDs) else { continue }
                    assistantID = turns.last?.role == .assistant ? turns.last?.id : nil
                case .complete: result = (.complete, nil)
                case .cancelled: result = (.cancelled, nil)
                case .failed(let message): result = (.failed, message); recordError(message, owner: owner)
                }
                if result != nil { break }
            }
            if let result {
                if assistantID == nil, result.state != .complete,
                   conversations.first(where: { $0.id == owner })?.messages.last?.role == .user {
                    let reply = DesktopMessage(role: .assistant, text: "", state: result.state)
                    if let index = conversations.firstIndex(where: { $0.id == owner }) { conversations[index].messages.append(reply) }
                    assistantID = reply.id
                }
                finishScheduledReply(owner: owner, replyID: assistantID, state: result.state)
            } else if Date().timeIntervalSince(lastCheckpoint) >= 1,
                      let value = conversations.first(where: { $0.id == owner }) {
                lastCheckpoint = Date()
                persist(value)
            }
        }
        for await _ in run.signals {
            apply(run.drain())
            if result != nil { break }
        }
        apply(run.drain())
        if let result { return result }
        finishScheduledReply(owner: owner, replyID: assistantID, state: .failed)
        return (.failed, "运行意外结束。")
    }

    @discardableResult
    private func replaceScheduledSuffix(_ turns: [DesktopMessage], owner: UUID, prefixIDs: [UUID]) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == owner }) else { return false }
        let prefix = Array(conversations[index].messages.prefix(prefixIDs.count))
        guard prefix.map(\.id) == prefixIDs else { return false }
        conversations[index].messages = prefix + turns
        return true
    }

    private func finishScheduledReply(owner: UUID, replyID: UUID?, state: DesktopMessageState) {
        guard let index = conversations.firstIndex(where: { $0.id == owner }) else { return }
        if let replyID, let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == replyID }) {
            conversations[index].messages[messageIndex].state = state
        }
        conversations[index].updatedAt = Date()
        persist(conversations[index])
    }

    private func persistScheduledTurns(_ turns: [DesktopMessage], owner: UUID, prefixIDs: [UUID]) async -> Bool {
        guard scheduledRunConversationIDs.contains(owner), replaceScheduledSuffix(turns, owner: owner, prefixIDs: prefixIDs),
              let value = conversations.first(where: { $0.id == owner }) else { return false }
        persist(value)
        let writer = persistence
        await writer?.value
        return scheduledRunConversationIDs.contains(owner) && conversations.contains(where: { $0.id == owner })
            && !unsavedConversationIDs.contains(owner)
    }
}

private enum DesktopFileIO {
    static func export(_ document: String, to url: URL) throws {
        try exportData(Data(document.utf8), to: url)
    }

    static func exportData(_ data: Data, to url: URL) throws {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
    }

    static func readConversationDocument(from url: URL) throws -> String {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
