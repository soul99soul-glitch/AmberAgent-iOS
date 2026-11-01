import AppKit
import Foundation
import Observation
@preconcurrency import GatewayCore

extension DesktopWorkspace {
    func apply(_ events: [DesktopProviderEvent], checkpoint: Bool = true) {
        let target = selectedID.flatMap({ activeGenerations[$0] != nil ? $0 : nil }) ?? generationConversationID
        guard let conversationID = target else { return }
        apply(events, for: conversationID, checkpoint: checkpoint)
    }

    func apply(_ events: [DesktopProviderEvent], for conversationID: UUID, token: UUID? = nil, checkpoint: Bool = true) {
        guard var active = activeGenerations[conversationID],
              token == nil || active.token == token,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var terminal: DesktopMessageState?
        for event in events {
            switch event {
            case .snapshot(let text, let reasoning, let canonicalJSON, let unsupportedPartCount, let tools):
                guard let messageID = active.assistantID,
                      let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == messageID }) else { continue }
                if conversations[index].messages[messageIndex].text != text { conversations[index].messages[messageIndex].text = text }
                if conversations[index].messages[messageIndex].reasoning != reasoning { conversations[index].messages[messageIndex].reasoning = reasoning }
                conversations[index].messages[messageIndex].canonicalJSON = canonicalJSON
                conversations[index].messages[messageIndex].unsupportedPartCount = unsupportedPartCount
                if conversations[index].messages[messageIndex].tools != tools { conversations[index].messages[messageIndex].tools = tools }
            case .transcript(let turns):
                guard !turns.isEmpty else { continue }
                let prefix = Array(conversations[index].messages.prefix(active.prefixIDs.count))
                guard prefix.map(\.id) == active.prefixIDs else { continue }
                // Agent events contain only new turns; compacted request input never replaces stored history.
                let previous = conversations[index].messages.dropFirst(prefix.count)
                var incoming = turns
                if let first = previous.first(where: { $0.role == .assistant }), !first.variantIDs.isEmpty,
                   let reply = incoming.firstIndex(where: { $0.role == .assistant }), incoming[reply].variantIDs.isEmpty {
                    incoming[reply].variantIDs = first.variantIDs.map { $0 == first.id ? incoming[reply].id : $0 }
                }
                conversations[index].messages = prefix + incoming
                active.assistantID = turns.last?.role == .assistant ? turns.last?.id : nil
            case .complete: terminal = .complete
            case .cancelled: terminal = .cancelled
            case .failed(let message): terminal = .failed; recordError(message, owner: conversationID)
            }
        }
        activeGenerations[conversationID] = active
        if let terminal {
            if active.assistantID == nil, terminal != .complete, conversations[index].messages.last?.role == .user {
                let reply = DesktopMessage(role: .assistant, text: "", state: terminal)
                conversations[index].messages.append(reply)
                active.assistantID = reply.id
            }
            if let messageID = active.assistantID,
               let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == messageID }) {
                conversations[index].messages[messageIndex].state = terminal
            }
            conversations[index].updatedAt = Date()
            persist(conversations[index])
            let writer = persistence
            let completedToken = active.token
            let notify = !active.usesTools && (terminal == .complete || terminal == .failed)
            let canonicalIDs = Set(conversations[index].messages.map(\.id))
            for queueIndex in instructionQueue.indices where instructionQueue[queueIndex].conversationID == conversationID
                && instructionQueue[queueIndex].runID == completedToken && !canonicalIDs.contains(instructionQueue[queueIndex].id) {
                instructionQueue[queueIndex].status = .pending
            }
            clearGeneration(for: conversationID)
            if notify {
                Task {
                    await writer?.value
                    guard !unsavedConversationIDs.contains(conversationID),
                          conversations.contains(where: { $0.id == conversationID }) else { return }
                    _ = await notifications.notify(runID: completedToken, conversationID: conversationID,
                        outcome: terminal == .complete ? .completed : .failed)
                }
            }
            if terminal == .complete,
               instructionQueue.contains(where: { $0.conversationID == conversationID && $0.runID == completedToken && $0.status == .pending }) {
                let followupToken = UUID()
                let task = Task { [weak self] in
                    await writer?.value
                    guard let self, self.queuedRequestTasks[conversationID]?.token == followupToken else { return }
                    self.queuedRequestTasks[conversationID] = nil
                    guard !Task.isCancelled else { return }
                    self.startQueuedRequest(owner: conversationID, runID: completedToken)
                }
                queuedRequestTasks[conversationID] = (followupToken, task)
            }
            if selectedID == conversationID { reloadFiles() }
            // A finished turn is the only safe place to compact: tool round trips and pending approvals live
            // inside a run, so compacting there would split one. A stopped or failed turn also leaves the
            // history in a state the summary could bake in, so only a completed turn triggers a compaction.
            if terminal == .complete { scheduleAutomaticCompaction(owner: conversationID) }
        } else if checkpoint, Date().timeIntervalSince(active.lastCheckpoint) >= 1 {
            active.lastCheckpoint = Date()
            activeGenerations[conversationID] = active
            persist(conversations[index])
        }
    }

    /// Produces a summary once an idle conversation approaches the model window, so the next turn starts
    /// from a compacted history instead of relying on the budget fit. The user's manual control
    /// (「压缩上下文」/「恢复完整上下文」) keeps working exactly as before.
    func scheduleAutomaticCompaction(owner: UUID) {
        guard !generatingConversationIDs.contains(owner), !isLoading, !mutatingBranchConversationIDs.contains(owner),
              !isManagingBackup, !scheduledRunConversationIDs.contains(owner), !insights.activeOwners.contains(owner),
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
        guard let active = activeGenerations[owner], active.token == token,
              let current = conversations.first(where: { $0.id == owner }),
              current.messages.prefix(active.prefixIDs.count).map(\.id) == active.prefixIDs else { return false }
        apply([.transcript(turns)], for: owner, token: token, checkpoint: false)
        guard let value = conversations.first(where: { $0.id == owner }) else { return false }
        persist(value)
        let writer = persistence
        await writer?.value
        return activeGenerations[owner]?.token == token
            && conversations.contains(where: { $0.id == owner }) && !unsavedConversationIDs.contains(owner)
    }

    func stop(_ conversationID: UUID? = nil) {
        let target: UUID?
        if let conversationID {
            target = conversationID
        } else if let selectedID,
                  generatingConversationIDs.contains(selectedID) || mutatingBranchConversationIDs.contains(selectedID)
                    || queuedRequestTasks[selectedID] != nil {
            target = selectedID
        } else {
            target = generationConversationID ?? mutatingBranchConversationIDs.first ?? queuedRequestTasks.keys.first
        }
        guard let owner = target else { return }
        queuedRequestTasks[owner]?.task.cancel()
        queuedRequestTasks[owner] = nil
        if mutatingBranchConversationIDs.contains(owner) { branchGenerationCancelled.insert(owner) }
        guard let active = activeGenerations[owner], !stoppingConversationIDs.contains(owner) else { return }
        stoppingConversationIDs.insert(owner)
        active.run.cancel()
        apply(active.run.drain(), for: owner, token: active.token)
    }

    func stopAll() {
        for owner in Array(queuedRequestTasks.keys) {
            queuedRequestTasks[owner]?.task.cancel()
            queuedRequestTasks[owner] = nil
        }
        for owner in mutatingBranchConversationIDs { branchGenerationCancelled.insert(owner) }
        for owner in Array(activeGenerations.keys) { stop(owner) }
    }

    func clearGeneration(for conversationID: UUID? = nil) {
        guard let owner = conversationID ?? generationConversationID else { return }
        activeGenerations[owner] = nil
        generatingConversationIDs.remove(owner)
        stoppingConversationIDs.remove(owner)
        generationOrder.removeAll { $0 == owner }
    }

    func delete(_ id: UUID) {
        guard !mutatingBranchConversationIDs.contains(id) else {
            recordError("正在保存消息更改，请稍候再删除会话。", owner: id); return
        }
        guard let summary = summaries.first(where: { $0.id == id }) else { return }
        if imageGeneration.ownerID == id { imageGeneration.cancel() }
        scheduledGenerations[id]?.cancel()
        queuedRequestTasks[id]?.task.cancel()
        queuedRequestTasks[id] = nil
        if generatingConversationIDs.contains(id) {
            stop(id)
            if let active = activeGenerations[id] {
                active.task?.cancel()
                clearGeneration(for: id)
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
        attachmentDraftAnchors[id] = nil
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
                self.conversations[index].messages[messageIndex].videos = actual.videos
                self.conversations[index].messages[messageIndex].audios = actual.audios
                self.conversations[index].messages[messageIndex].tools = actual.tools
                self.conversations[index].messages[messageIndex].parts = actual.parts
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
        for owner in Array(stoppingConversationIDs) {
            await activeGenerations[owner]?.task?.value
        }
        for entry in Array(queuedRequestTasks.values) { await entry.task.value }
        for item in Array(attachmentTasks.values) { await item.task.value }
        for task in Array(collaborationSaveTasks.values) { await task.value }
        for task in Array(branchMutationTasks.values) { await task.value }
        await persistence?.value
        let pending = conversations.filter { unsavedConversationIDs.contains($0.id) }
        for conversation in pending { persist(conversation) }
        let metadata = summaries.filter { unsavedMetadataIDs.contains($0.id) }
        for summary in metadata { persistMetadata(summary) }
        await persistence?.value
        return unsavedConversationIDs.isEmpty && unsavedMetadataIDs.isEmpty
    }
    func waitUntilLoaded() async { await loadingTask?.value }

    var canAcceptAttachments: Bool {
        !isLoading && !isLoadingSelectedConversation && !selectedConversationUnavailable
            && !isSelectedConversationGenerating && !isSelectedConversationMutatingBranch && !isManagingBackup
    }

    /// Handles ⌘V / Paste from the given pasteboard when it carries file URLs or image data.
    /// Returns `true` when the pasteboard contained an attachment payload (even if rejected due to current state),
    /// or `false` when it only carries plain text so the text editor can paste normally.
    @discardableResult
    func pasteFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let urls = DesktopPasteboardImport.fileURLs(from: pasteboard)
        if !urls.isEmpty {
            guard canAcceptAttachments else {
                if isSelectedConversationGenerating { recordError("请等待当前回复结束或停止后再粘贴文件。", owner: selectedID) }
                return true
            }
            addAttachments(urls)
            return true
        }
        if let image = DesktopPasteboardImport.imagePayload(from: pasteboard) {
            guard canAcceptAttachments else {
                if isSelectedConversationGenerating { recordError("请等待当前回复结束或停止后再粘贴图片。", owner: selectedID) }
                return true
            }
            addImageAttachment(data: image.data, name: image.name)
            return true
        }
        return false
    }

    @discardableResult
    func dropFiles(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, canAcceptAttachments else { return false }
        addAttachments(files)
        return true
    }

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
        let anchorDraft = selectedID == owner ? draft : (drafts[owner] ?? "")
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
                for document in imported where document.kind == .image {
                    attachmentDraftAnchors[owner, default: [:]][document.id] = anchorDraft
                }
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
        if let selectedID {
            attachments[selectedID] = pendingAttachments
            attachmentDraftAnchors[selectedID]?[id] = nil
        }
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
