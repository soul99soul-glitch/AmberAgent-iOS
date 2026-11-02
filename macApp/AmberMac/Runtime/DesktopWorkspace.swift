import Foundation
#if canImport(AppKit)
import AppKit
#endif
import Observation
@preconcurrency import GatewayCore

enum DesktopWorkspaceSurface: Equatable, Sendable {
    case chat
    case taskBoard
    case pluginView(pluginID: String, viewID: String)
}

@MainActor @Observable
final class DesktopWorkspace {
    var conversations: [DesktopConversation] = [] {
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
    var loadedConversationIDs: Set<UUID> = []
    var nonEmptyConversationIDs: Set<UUID> = []
    var selectedID: UUID?
    var draft = ""
    /// Composer mode: plain chat, or send the draft to the model council, which reports back into this conversation.
    var composerMode = DesktopComposerMode.chat
    var composerRunID: UUID?
    var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    var summaries: [DesktopConversationSummary] = [] {
        // New default-workspace folders are named after the conversation.
        didSet { for summary in summaries { files.locations.noteTitle(summary.title, for: summary.id) } }
    }
    var sidebarResults: [DesktopConversationSearchResult] = []
    var isSearching = false
    var searchErrorMessage: String?
    var loadingConversationIDs: Set<UUID> = []
    var errorMessage: String?
    /// Active interactive chat generations by conversation ID (sorted by start order via `generationOrder`).
    static let defaultMaxConcurrentTasks = 2
    static let defaultMaxTotalConcurrentTasks = 4
    var maxConcurrentTasks: Int = DesktopWorkspace.defaultMaxConcurrentTasks
    var maxTotalConcurrentTasks: Int = DesktopWorkspace.defaultMaxTotalConcurrentTasks
    var generatingConversationIDs: Set<UUID> = []
    var stoppingConversationIDs: Set<UUID> = []
    var generatingTaskIDs: Set<UUID> = []
    var stoppingTaskIDs: Set<UUID> = []
    var supplementTargets: [UUID: UUID] = [:]
    @ObservationIgnored var generationOrder: [UUID] = []
    @ObservationIgnored var activeTaskOrder: [UUID] = []
    var isGenerating: Bool { !generatingConversationIDs.isEmpty }
    var isStopping: Bool {
        if let selectedID, stoppingConversationIDs.contains(selectedID) { return true }
        return !stoppingConversationIDs.isEmpty && selectedID == nil
    }
    var isSelectedConversationStopping: Bool { selectedID.map(stoppingConversationIDs.contains) ?? false }
    var isLoading = true
    var attachmentLoadCounts: [UUID: Int] = [:]
    var isReadingAttachments: Bool { selectedID.map { (attachmentLoadCounts[$0] ?? 0) > 0 } ?? false }
    var mutatingBranchConversationIDs: Set<UUID> = []
    var isMutatingBranch: Bool { !mutatingBranchConversationIDs.isEmpty }
    var isSelectedConversationMutatingBranch: Bool { selectedID.map(mutatingBranchConversationIDs.contains) ?? false }
    var isManagingBackup = false
    var backupStatusMessage: String?
    var backupErrorMessage: String?
    @ObservationIgnored var backupTask: Task<Void, Never>?
    @ObservationIgnored var backupDataTasks: [UUID: Task<Data, Error>] = [:]
    var pendingAttachments: [DesktopImportedDocument] = []
    var generationConversationID: UUID? {
        if let selectedID, generatingConversationIDs.contains(selectedID) { return selectedID }
        return generationOrder.last { generatingConversationIDs.contains($0) }
    }
    var instructionQueue: [DesktopQueuedInstruction] = []
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
    let intelligentUIStateStore: IOSIntelligentUIStateStore
    private(set) var intelligentUIHost: DesktopIntelligentUIHost!
    let titles = DesktopTitleGeneration()
    /// Set by the live app; previews and tests run without one.
    var scheduler: DesktopScheduler?
    var scheduleTriggers: DesktopScheduleTriggers?
    var gateway: DesktopGateway?
    var gatewayReporter: DesktopGatewayReporter?
    var gatewayControl: DesktopGatewayControl?
    var boardWriter: DesktopBoardWriter?
    /// Outbound pairing to a cloud amberd; a different slot from the local `gateway` server above.
    var cloudSelf: DesktopCloudSelfStore?

    @ObservationIgnored var registryCache: (modified: Date, sessions: [SessionRecord])?

    /// The gateway's sessions, re-read only when registry.json changed (the board and badge poll every few seconds).
    func gatewaySessions() -> [SessionRecord] {
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

    func reconcilePluginState() {
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
    var boardNeedsYouCount = 0

    func refreshBoardBadge(from items: [AmberControl.BoardItem]? = nil) {
        boardNeedsYouCount = (items ?? boardItems()).filter { $0.column == .needsYou }.count
    }
    var savingCollaborationRuns: Set<UUID> = []
    var savedCollaborationRuns: Set<UUID> = []
    var collaborationSaveErrors: [UUID: String] = [:]
    @ObservationIgnored var collaborationSaveTasks: [UUID: Task<Void, Never>] = [:]
    var selectedFiles: [DesktopWorkspaceFile] = []
    var selectedFilesTruncated = false
    /// Bumped when a workspace folder choice changes, so views showing locations re-read them.
    var workspaceLocationVersion = 0
    var fileErrorMessage: String?
    var fileStatusMessage: String?
    var isLoadingFiles = false
    var filePreview: DesktopImportedDocument?
    var filePreviewErrorMessage: String?
    var isLoadingFilePreview = false
    @ObservationIgnored var filesToken = UUID()
    @ObservationIgnored var fileTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var filePreviewToken = UUID()
    @ObservationIgnored var fileErrors: [UUID: String] = [:]
    @ObservationIgnored var fileReadFailures: Set<UUID> = []

    struct ActiveGeneration {
        let token: UUID
        let conversationID: UUID
        let title: String
        let userMessageID: UUID?
        let initialAssistantID: UUID
        let run: DesktopGeneration
        var assistantID: UUID?
        var prefixIDs: [UUID]
        var ownedMessageIDs: [UUID]
        let usesTools: Bool
        var task: Task<Void, Never>?
        var lastCheckpoint: Date
    }

    @ObservationIgnored let storage: any DesktopConversationStorage
    @ObservationIgnored let provider: any DesktopTextProvider
    @ObservationIgnored var persistence: Task<Void, Never>?
    @ObservationIgnored var activeTasks: [UUID: ActiveGeneration] = [:]
    var activeGenerations: [UUID: ActiveGeneration] {
        var result: [UUID: ActiveGeneration] = [:]
        for token in activeTaskOrder {
            if let task = activeTasks[token] {
                result[task.conversationID] = task
            }
        }
        return result
    }
    @ObservationIgnored var queuedRequestTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored var drafts: [UUID: String] = [:]
    @ObservationIgnored var attachments: [UUID: [DesktopImportedDocument]] = [:]
    @ObservationIgnored var attachmentDraftAnchors: [UUID: [UUID: String]] = [:]
    @ObservationIgnored var loadingTask: Task<Void, Never>?
    @ObservationIgnored var attachmentTasks: [UUID: (owner: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored var conversationErrors: [UUID: String] = [:]
    @ObservationIgnored var autoCompaction = DesktopAutoCompactionPolicy()
    /// Request-time context notices (budget trimming) shown next to the context panel.
    var contextNotices: [UUID: String] = [:]
    /// Fingerprint of the last request's turn-invariant prefix per conversation: equal values mean a provider
    /// that supports prefix caching can reuse it.
    var contextPrefixFingerprints: [UUID: UInt64] = [:]
    @ObservationIgnored var unsavedConversationIDs: Set<UUID> = []
    @ObservationIgnored var unsavedMetadataIDs: Set<UUID> = []
    @ObservationIgnored var branchMutationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var branchGenerationCancelled: Set<UUID> = []
    /// Conversations a scheduled task is writing into right now; the composer and branch edits stay off them.
    var scheduledRunConversationIDs: Set<UUID> = []
    /// Scheduled runs in flight: task id → the conversation it writes into (task board).
    var scheduledRunTaskConversations: [UUID: UUID] = [:]
    @ObservationIgnored var scheduledGenerations: [UUID: DesktopGeneration] = [:]

    @ObservationIgnored var conversationLoads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var searchToken = UUID()
    @ObservationIgnored var storedSearchResults: [DesktopConversationSearchResult] = []

    enum WriteKind { case messages, metadata }
    static let saveFailureMessage = "会话保存失败，当前内容仍在窗口中。请导出备份并检查磁盘空间或文件权限。"

    init(settings: DesktopSettings, storage: any DesktopConversationStorage,
         provider: any DesktopTextProvider, initialConversations: [DesktopConversation]? = nil,
         insights: DesktopConversationInsights? = nil, files: DesktopWorkspaceFiles = DesktopWorkspaceFiles(),
         agentTasks: DesktopAgentTasks? = nil, knowledge: DesktopKnowledgeStore? = nil,
         mcp: DesktopMCPManager? = nil, collaborations: DesktopCollaborations? = nil, recipes: DesktopRecipeRuns? = nil,
         webDAV: DesktopWebDAVManager? = nil, notifications: DesktopNotifications? = nil,
         storageUsageSources: [DesktopStorageUsage.Source]? = nil,
         imageGeneration: DesktopImageGeneration? = nil, speech: DesktopSpeechPlayer? = nil,
         searchSettings: DesktopSearchSettings? = nil, artifactShelf: DesktopArtifactShelf? = nil,
         plugins: DesktopPluginStore? = nil, boost: DesktopDeepSeekBoostStore? = nil,
         intelligentUIStateStore: IOSIntelligentUIStateStore? = nil,
         intelligentUIReceiptsFileURL: URL? = nil) {
        self.settings = settings
        self.insights = insights ?? DesktopConversationInsights()
        self.artifactShelf = artifactShelf ?? DesktopArtifactShelf()
        self.files = files
        self.agentTasks = agentTasks ?? DesktopAgentTasks()
        self.boost = boost ?? DesktopDeepSeekBoostStore()
        self.intelligentUIStateStore = intelligentUIStateStore ?? IOSIntelligentUIStateStore()
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
        self.intelligentUIHost = DesktopIntelligentUIHost(
            stateStore: self.intelligentUIStateStore,
            receiptsFileURL: intelligentUIReceiptsFileURL,
            submitAction: { [weak self] submission in
                guard let self else { return .failure("工作区已释放。") }
                return await self.submitIntelligentUI(submission)
            },
            insertDraftAction: { [weak self] submission in
                guard let self else { return .failure("工作区已释放。") }
                return self.insertIntelligentUIDraft(submission)
            }
        )
        self.plugins.onStateChanged = { [weak self] in
            self?.reconcilePluginState()
        }
        self.plugins.conversationSnapshotProvider = { [weak self] in
            guard let self, let conv = self.selectedConversation else {
                return DesktopPluginConversationSnapshot(id: "", title: "当前对话", messageCount: 0, messages: [])
            }
            let recent = conv.messages.suffix(20).map { msg in
                DesktopPluginConversationSnapshot.MessageItem(
                    id: msg.id.uuidString,
                    role: msg.role.rawValue,
                    content: msg.text
                )
            }
            return DesktopPluginConversationSnapshot(
                id: conv.id.uuidString,
                title: conv.title,
                messageCount: conv.messages.count,
                messages: recent
            )
        }
        self.plugins.onInsertToComposerRequest = { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.draft = trimmed
            } else {
                self.draft += "\n\n" + trimmed
            }
        }
        self.plugins.onOpenPluginViewRequest = { [weak self] pluginID, viewID in
            self?.openPluginView(pluginID: pluginID, viewID: viewID)
        }
        #if canImport(AppKit)
        if self.plugins.onConfirmRequest == nil {
            self.plugins.onConfirmRequest = { title, message in
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                alert.addButton(withTitle: "确定")
                alert.addButton(withTitle: "取消")
                return alert.runModal() == .alertFirstButtonReturn
            }
        }
        #endif
        reconcilePluginState()
        if let initialConversations {
            conversations = initialConversations
            summaries = DesktopConversationSummary.ordered(initialConversations.map(DesktopConversationSummary.init))
            refreshSidebar()
            selectedID = initialConversations.first?.id
            isLoading = false
            if let selectedID {
                self.insights.load(selectedID)
                self.refreshIntelligentUIReceipts(for: selectedID)
                reloadFiles()
            }
        } else { loadingTask = Task { await load() } }
    }

    var selectedConversation: DesktopConversation? { conversations.first { $0.id == selectedID } }
    var selectedQueuedMessages: [DesktopQueuedInstruction] { instructionQueue.filter { $0.conversationID == selectedID } }
    var canQueueInstruction: Bool {
        isSelectedConversationGenerating && !isSelectedConversationStopping && !isReadingAttachments && pendingAttachments.isEmpty
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var isSelectedConversationGenerating: Bool { selectedID.map(generatingConversationIDs.contains) ?? false }
    func isConversationGenerating(_ id: UUID) -> Bool { generatingConversationIDs.contains(id) }
    func isConversationMutatingBranch(_ id: UUID) -> Bool { mutatingBranchConversationIDs.contains(id) }
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

    var supportedThinkingLevels: [DesktopReasoningLevel] {
        settings.selectedModelSupportedReasoningLevels
    }

    var isThinkingLevelAvailable: Bool {
        !supportedThinkingLevels.isEmpty
    }

    var selectedThinkingLevel: DesktopReasoningLevel {
        settings.selectedModelReasoning
    }

    func setThinkingLevel(_ level: DesktopReasoningLevel) {
        settings.setSelectedModelReasoning(level)
    }

    func load() async {
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
    func loadConversation(_ id: UUID) -> Task<Void, Never>? {
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
                refreshIntelligentUIReceipts(for: id)
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

    var normalizedSearch: String { searchText.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    func retrySearch() { scheduleSearch() }

    func scheduleSearch() {
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

    func refreshSidebar() {
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

    func updateSummary(_ conversation: DesktopConversation) {
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
            let title = summaries.first(where: { $0.id == id })?.title ?? "对话"
            plugins.broadcastHostEvent("conversation:changed", payload: [
                "conversationId": id.uuidString,
                "title": title
            ])
        }
        insights.load(id)
        refreshIntelligentUIReceipts(for: id)
        loadConversation(id)
    }

    func saveDraft() {
        guard let selectedID else { return }
        drafts[selectedID] = draft
        attachments[selectedID] = pendingAttachments
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

    func mutateBranch(messageID: UUID, request: (DesktopProviderConfiguration, String)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil,
        action: @escaping @MainActor (DesktopConversation, UUID) async throws -> DesktopConversation) -> Task<Void, Never>? {
        guard !isLoading, !isSelectedConversationGenerating, !isSelectedConversationMutatingBranch,
              !isManagingBackup, let owner = selectedID, !scheduledRunConversationIDs.contains(owner),
              selectedConversation?.messages.contains(where: { $0.id == messageID }) == true else {
            completion?(false); return nil
        }
        mutatingBranchConversationIDs.insert(owner)
        branchGenerationCancelled.remove(owner)
        let precedingWrites = persistence
        let responseID = UUID()
        let task = Task {
            var committed = false
            defer {
                mutatingBranchConversationIDs.remove(owner)
                branchGenerationCancelled.remove(owner)
                branchMutationTasks[owner] = nil
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
                refreshIntelligentUIReceipts(for: owner)
                if !unsavedConversationIDs.contains(owner), !unsavedMetadataIDs.contains(owner) {
                    conversationErrors[owner] = nil
                    if selectedID == owner { errorMessage = nil }
                }
                committed = true
                if let request {
                    if branchGenerationCancelled.contains(owner) {
                        conversations[index].messages[conversations[index].messages.count - 1].state = .cancelled
                        persist(conversations[index])
                    } else {
                        startGeneration(conversationID: owner, configuration: request.0, apiKey: request.1,
                            preparedResponseID: responseID)
                    }
                }
            } catch { recordError("消息更改未保存，原分支已保留。\(error.localizedDescription)", owner: owner) }
        }
        branchMutationTasks[owner] = task
        return task
    }

    func requestConfiguration(_ auxiliary: DesktopAuxiliaryModelTask? = nil,
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

    func validatedRequest(_ config: DesktopProviderConfiguration) throws -> (DesktopProviderConfiguration, String) {
        try DesktopSettings.validateEndpoint(config.baseURL)
        guard !config.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopRuntimeError.message("请先在服务商设置中填写 Model ID。")
        }
        let key = try settings.apiKey(for: config.id)
        if config.authMode == .apiKey, key.isEmpty, !config.baseURL.hasPrefix("http://") {
            throw DesktopRuntimeError.message("请先在服务商设置中填写 API Key。本机模型可留空。")
        }
        var resolved = config
        if let model = resolved.selectedModel,
           let index = resolved.models.firstIndex(where: { $0.id == model.id }) {
            let supported = DesktopThinkingPolicy.supportedLevels(for: model, provider: resolved)
            resolved.models[index].reasoning = DesktopThinkingPolicy.coercedLevel(model.reasoning, supported: supported)
        }
        return (resolved, key)
    }

    @discardableResult
    func generateTitle(_ id: UUID) -> Task<Void, Never>? {
        guard !isManagingBackup, !mutatingBranchConversationIDs.contains(id), !generatingConversationIDs.contains(id) else {
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
        guard !isLoading, !isSelectedConversationGenerating, !isSelectedConversationMutatingBranch,
              !isManagingBackup, let conversation = selectedConversation else { return }
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

    /// History as the model sees it: compaction applied, a turn-invariant system prefix, memories recalled
    /// for the newest user text right before it, then a deterministic budget fit.
    func requestMessages(_ history: [DesktopMessage], conversationID: UUID,
                                 configuration: DesktopProviderConfiguration) throws -> [DesktopMessage] {
        let model = configuration.selectedModel
        let knowledgeEnabled = plugins.isCoreEnabled(.knowledge)
        let stableContext = knowledgeEnabled ? try knowledge.stableContext() : ""
        let memoryContext = knowledgeEnabled
            ? try knowledge.requestMemoryContext(query: history.last(where: { $0.role == .user })?.text ?? "")
            : ""
        let stableSystem = [settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines), stableContext,
                            workspaceContext(conversationID) ?? "",
                            DesktopIntelligentUIRequestPolicy.systemPrompt(enabled: settings.intelligentUIEnabled),
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

}
