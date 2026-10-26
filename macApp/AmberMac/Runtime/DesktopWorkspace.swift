import Foundation
import Observation

@MainActor @Observable
final class DesktopWorkspace {
    private(set) var conversations: [DesktopConversation] = []
    var selectedID: UUID?
    var draft = ""
    var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    private(set) var summaries: [DesktopConversationSummary] = []
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
    let titles = DesktopTitleGeneration()
    private(set) var savingCollaborationRuns: Set<UUID> = []
    private(set) var savedCollaborationRuns: Set<UUID> = []
    private(set) var collaborationSaveErrors: [UUID: String] = [:]
    @ObservationIgnored private var collaborationSaveTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var selectedFiles: [DesktopWorkspaceFile] = []
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
    @ObservationIgnored private let provider: any DesktopTextProvider
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
    @ObservationIgnored private var unsavedConversationIDs: Set<UUID> = []
    @ObservationIgnored private var unsavedMetadataIDs: Set<UUID> = []
    @ObservationIgnored private var branchMutationTask: Task<Void, Never>?
    @ObservationIgnored private var branchMutationOwner: UUID?
    @ObservationIgnored private var branchGenerationCancelled = false

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
         searchSettings: DesktopSearchSettings? = nil, artifactShelf: DesktopArtifactShelf? = nil) {
        self.settings = settings
        self.insights = insights ?? DesktopConversationInsights()
        self.artifactShelf = artifactShelf ?? DesktopArtifactShelf()
        self.files = files
        self.agentTasks = agentTasks ?? DesktopAgentTasks()
        self.knowledge = knowledge ?? DesktopKnowledgeStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-preview-knowledge-" + UUID().uuidString, isDirectory: true))
        self.mcp = mcp ?? DesktopMCPManager(store: DesktopMCPStore(
            defaults: UserDefaults(suiteName: "amber.preview.mcp." + UUID().uuidString)!, credentials: DesktopMemoryCredentials()))
        self.collaborations = collaborations ?? DesktopCollaborations(settings: settings, provider: provider)
        self.recipes = recipes ?? DesktopRecipeRuns(store: DesktopRecipeStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("amber-preview-recipes-" + UUID().uuidString),
            registeredTools: Set(DesktopToolRegistry.declarations.map(\.name) + DesktopMCPManager.declarations.map(\.name) +
                ["skills_list", "use_skill", "skill_enable", "skill_disable", "memory_tool"])), tasks: self.agentTasks)
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
    var selectedConversationUnavailable: Bool { selectedID != nil && selectedConversation == nil }
    var selectedConversationTitle: String {
        selectedConversation?.title ?? summaries.first { $0.id == selectedID }?.title ?? "Amber"
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
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
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
        let localContext: String
        do { localContext = try knowledge.requestContext(query: messages.last(where: { $0.role == .user })?.text ?? "") }
        catch {
            conversations[index].messages[conversations[index].messages.count - 1].state = .failed
            persist(conversations[index])
            recordError("读取本地知识上下文失败。\(error.localizedDescription)", owner: conversationID)
            return
        }
        messages = insights.prepare(messages: messages, conversationID: conversationID)
        let system = [settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines), localContext]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !system.isEmpty { messages.insert(DesktopMessage(role: .system, text: system), at: 0) }
        if !unsavedConversationIDs.contains(conversationID), !unsavedMetadataIDs.contains(conversationID) {
            if selectedID == conversationID { errorMessage = nil }
            conversationErrors[conversationID] = nil
        }
        let token = UUID()
        generationID = token
        assistantID = replyID
        generationPrefixIDs = prefixIDs
        generationUsesTools = agentTasks.toolsEnabled
        generationConversationID = conversationID
        isGenerating = true
        isStopping = false
        lastCheckpoint = Date()
        do {
            let run = try provider.start(configuration: configuration, apiKey: apiKey,
                messages: messages, responseID: replyID, context: DesktopRunContext(
                    conversationID: conversationID, toolsEnabled: generationUsesTools,
                    persistTurns: { [weak self] turns in
                        guard let self else { return false }
                        return await self.persistAgentTurns(turns, owner: conversationID, token: token)
                    }, drainSteer: { [weak self] in
                        self?.drainQueuedInstructions(owner: conversationID, token: token) ?? []
                    }))
            generation = run
            generationTask = Task { [weak self] in
                for await _ in run.signals {
                    guard let self, self.generationID == token else { return }
                    self.apply(run.drain())
                }
            }
        } catch {
            clearGeneration()
            conversations[index].messages[conversations[index].messages.count - 1].state = .failed
            persist(conversations[index])
            recordError("无法开始生成，请检查服务商设置后重试。", owner: conversationID)
        }
    }

    private func apply(_ events: [DesktopProviderEvent], checkpoint: Bool = true) {
        guard let conversationID = generationConversationID,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var terminal: DesktopMessageState?
        for event in events {
            switch event {
            case .snapshot(let text, let reasoning, let canonicalJSON, let unsupportedPartCount):
                guard let messageID = assistantID,
                      let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == messageID }) else { continue }
                if conversations[index].messages[messageIndex].text != text { conversations[index].messages[messageIndex].text = text }
                if conversations[index].messages[messageIndex].reasoning != reasoning { conversations[index].messages[messageIndex].reasoning = reasoning }
                conversations[index].messages[messageIndex].canonicalJSON = canonicalJSON
                conversations[index].messages[messageIndex].unsupportedPartCount = unsupportedPartCount
            case .transcript(let turns):
                guard !turns.isEmpty else { continue }
                let prefix = Array(conversations[index].messages.prefix(generationPrefixIDs.count))
                guard prefix.map(\.id) == generationPrefixIDs else { continue }
                // Agent events contain only new turns; compacted request input never replaces stored history.
                conversations[index].messages = prefix + turns
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
        } else if checkpoint, Date().timeIntervalSince(lastCheckpoint) >= 1 {
            lastCheckpoint = Date()
            persist(conversations[index])
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
                self.artifactShelf.removeConversation(id)
                do { try await self.files.removeConversation(id) }
                catch { self.recordError("会话已删除，但工作区文件清理失败，请检查文件夹权限。", owner: nil) }
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
            let durableIDs = Set(saved.messages.map(\.id))
            self.instructionQueue.removeAll { $0.conversationID == value.id && durableIDs.contains($0.id) }
            // The saved full document is the next base; newer visible messages remain owned by their run.
            self.conversations[index].canonicalJSON = saved.canonicalJSON
            for messageIndex in self.conversations[index].messages.indices {
                let current = self.conversations[index].messages[messageIndex]
                guard let previous = value.messages.first(where: { $0.id == current.id }), current == previous,
                      let actual = saved.messages.first(where: { $0.id == current.id }) else { continue }
                self.conversations[index].messages[messageIndex].canonicalJSON = actual.canonicalJSON
                self.conversations[index].messages[messageIndex].unsupportedPartCount = actual.unsupportedPartCount
                self.conversations[index].messages[messageIndex].variantIDs = actual.variantIDs
                self.conversations[index].messages[messageIndex].editableTextPartIndex = actual.editableTextPartIndex
                self.conversations[index].messages[messageIndex].editableText = actual.editableText
                self.conversations[index].messages[messageIndex].estimatedTokens = actual.estimatedTokens
                self.conversations[index].messages[messageIndex].images = actual.images
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
        fileErrorMessage = nil
        guard let owner = selectedID else { isLoadingFiles = false; return nil }
        fileErrorMessage = fileErrors[owner]
        isLoadingFiles = true
        return Task {
            do {
                let entries = try await files.list(conversationID: owner)
                guard selectedID == owner, filesToken == token else { return }
                selectedFiles = entries
                if fileReadFailures.remove(owner) != nil { recordFileError(nil, owner: owner) }
            } catch {
                guard selectedID == owner, filesToken == token else { return }
                recordFileError("读取工作区文件失败。请重试或检查文件夹权限。", owner: owner, isRead: true)
            }
            guard selectedID == owner, filesToken == token else { return }
            isLoadingFiles = false
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
                let data = try await files.read(conversationID: owner, path: path)
                try await Task.detached { try DesktopFileIO.exportData(data, to: url) }.value
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
        guard let owner = selectedID else { errorMessage = "请先选择要导出的会话。"; return nil }
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
        guard !isLoading, !isManagingBackup, !selectedConversationUnavailable, let owner = selectedID else {
            errorMessage = "请先选择并读取完整会话，再执行 Recipe。"
            return nil
        }
        return recipes.start(name: name, inputs: inputs, conversationID: owner)
    }

    @discardableResult
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
