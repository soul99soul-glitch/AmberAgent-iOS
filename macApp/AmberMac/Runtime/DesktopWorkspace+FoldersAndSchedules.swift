import Foundation
#if canImport(AppKit)
import AppKit
#endif
import Observation
@preconcurrency import GatewayCore

extension DesktopWorkspace {
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
    func workspaceContext(_ owner: UUID) -> String? {
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

    func recordFileError(_ message: String?, owner: UUID, isRead: Bool = false) {
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
        guard !mutatingBranchConversationIDs.contains(owner) else { recordError("正在保存消息更改，请稍候再导出。", owner: owner); return nil }
        for active in activeTasks(in: owner) { apply(active.run.drain(), for: owner, token: active.token) }
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
        guard !mutatingBranchConversationIDs.contains(owner) else { recordError("正在保存消息更改，请稍候再导出。", owner: owner); return nil }
        for active in activeTasks(in: owner) { apply(active.run.drain(), for: owner, token: active.token) }
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
            guard !generatingConversationIDs.contains(owner), !mutatingBranchConversationIDs.contains(owner),
                  let conversation = conversations.first(where: { $0.id == owner }) else {
                collaborationSaveErrors[runID] = "请先完成原会话的读取或生成，再保存协作结果。"; return
            }
            if conversation.messages.contains(where: { $0.id == runID }) { savedCollaborationRuns.insert(runID); return }
            let body = run.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? run.outputs.filter { !$0.text.isEmpty }.map { "## \($0.name)\n\n\($0.text)" }.joined(separator: "\n\n") : run.finalText
            guard !body.isEmpty else { collaborationSaveErrors[runID] = "此任务没有可保存的结果。"; return }
            mutatingBranchConversationIDs.insert(owner)
            let previous = persistence
            let write = Task {
                defer {
                    mutatingBranchConversationIDs.remove(owner)
                    branchMutationTasks[owner] = nil
                }
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
            branchMutationTasks[owner] = write
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

    static func iosBackupNote(_ restored: DesktopBackupRestoreResult) -> String {
        "已从 iOS 备份导入 \(restored.conversations.count) 个会话副本，现有内容已保留。iOS 的设置、服务商与凭证不会导入。"
    }

    func restoreBackup(note: (@MainActor (DesktopBackupRestoreResult) -> String)? = nil,
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

    var backupCoordinator: DesktopBackupCoordinator {
        DesktopBackupCoordinator(storage: storage, files: files, insights: insights, settings: settings, knowledge: knowledge,
            artifactShelf: artifactShelf)
    }

    func beginBackup() -> Bool {
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

    func performFileTask(_ action: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
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
            guard !generatingConversationIDs.contains(id), !mutatingBranchConversationIDs.contains(id),
                  !scheduledRunConversationIDs.contains(id) else {
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

    func consumeScheduled(_ run: DesktopGeneration, owner: UUID, prefixIDs: [UUID],
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
    func replaceScheduledSuffix(_ turns: [DesktopMessage], owner: UUID, prefixIDs: [UUID]) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == owner }) else { return false }
        let prefix = Array(conversations[index].messages.prefix(prefixIDs.count))
        guard prefix.map(\.id) == prefixIDs else { return false }
        conversations[index].messages = prefix + turns
        return true
    }

    func finishScheduledReply(owner: UUID, replyID: UUID?, state: DesktopMessageState) {
        guard let index = conversations.firstIndex(where: { $0.id == owner }) else { return }
        if let replyID, let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == replyID }) {
            conversations[index].messages[messageIndex].state = state
        }
        conversations[index].updatedAt = Date()
        persist(conversations[index])
    }

    func persistScheduledTurns(_ turns: [DesktopMessage], owner: UUID, prefixIDs: [UUID]) async -> Bool {
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
