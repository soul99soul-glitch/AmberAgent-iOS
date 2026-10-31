import Foundation
import Observation
@preconcurrency import GatewayCore

extension DesktopWorkspace {
    func apply(_ events: [DesktopProviderEvent], checkpoint: Bool = true) {
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
    func scheduleAutomaticCompaction(owner: UUID) {
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

    func persistAgentTurns(_ turns: [DesktopMessage], owner: UUID, token: UUID) async -> Bool {
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

    func clearGeneration() {
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

    func persist(_ value: DesktopConversation) {
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

    func persistMetadata(_ value: DesktopConversation) {
        updateSummary(value)
        persistMetadata(DesktopConversationSummary(value))
    }

    func persistMetadata(_ value: DesktopConversationSummary) {
        enqueue(ownerID: value.id, kind: .metadata) {
            try await self.storage.updateMetadata(value.id, title: value.title, isPinned: value.isPinned)
            if !self.normalizedSearch.isEmpty { self.scheduleSearch() }
        }
    }

    func enqueue(ownerID: UUID? = nil, kind: WriteKind = .messages,
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

    func recordError(_ message: String, owner: UUID?) {
        if let owner { conversationErrors[owner] = message }
        if owner == nil || selectedID == owner { errorMessage = message }
    }

    func conversationError(for owner: UUID) -> String? { conversationErrors[owner] }

    // App termination awaits the same serialized writer used by stream checkpoints.
    func flush() async -> Bool {
        for task in Array(fileTasks.values) { await task.value }
        return await flushConversationWrites()
    }

    func flushConversationWrites() async -> Bool {
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

    func importAttachments(_ read: @escaping @Sendable () async throws -> [DesktopImportedDocument]) -> Task<Void, Never>? {
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

    func validateAttachmentBudget(_ documents: [DesktopImportedDocument]) throws {
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

}
