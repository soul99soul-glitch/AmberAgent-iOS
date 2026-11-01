import AppKit
import Foundation
import Observation
@preconcurrency import GatewayCore

extension DesktopWorkspace {
    // MARK: - Task-Level Active Generation & Supplement Targeting

    func activeTasks(in conversationID: UUID) -> [ActiveGeneration] {
        activeTaskOrder.compactMap { activeTasks[$0] }.filter { $0.conversationID == conversationID }
    }

    var selectedConversationActiveTasks: [ActiveGeneration] {
        selectedID.map(activeTasks(in:)) ?? []
    }

    func activeOwnedMessageGroups(in conversationID: UUID) -> [[UUID]] {
        activeTasks(in: conversationID).map(\.ownedMessageIDs).filter { !$0.isEmpty }
    }

    func activeTask(forMessageID messageID: UUID) -> ActiveGeneration? {
        for token in activeTaskOrder.reversed() {
            guard let task = activeTasks[token] else { continue }
            if task.assistantID == messageID
                || task.initialAssistantID == messageID
                || task.ownedMessageIDs.contains(messageID)
                || task.userMessageID == messageID {
                return task
            }
        }
        return nil
    }

    func isTaskGenerating(_ token: UUID) -> Bool {
        generatingTaskIDs.contains(token)
    }

    func isTaskStopping(_ token: UUID) -> Bool {
        stoppingTaskIDs.contains(token)
    }

    func isMessageStreamingInActiveTask(_ messageID: UUID) -> Bool {
        activeTask(forMessageID: messageID) != nil
    }

    var selectedSupplementRunID: UUID? {
        guard let selectedID, let runID = supplementTargets[selectedID],
              let active = activeTasks[runID], active.conversationID == selectedID,
              !stoppingTaskIDs.contains(runID) else {
            return nil
        }
        return runID
    }

    var selectedSupplementTask: ActiveGeneration? {
        selectedSupplementRunID.flatMap { activeTasks[$0] }
    }

    func selectSupplementTarget(_ runID: UUID?, in conversationID: UUID? = nil) {
        let owner = conversationID ?? runID.flatMap { activeTasks[$0]?.conversationID } ?? selectedID
        guard let owner else { return }
        if let runID, let task = activeTasks[runID], task.conversationID == owner, !stoppingTaskIDs.contains(runID) {
            supplementTargets[owner] = runID
        } else {
            supplementTargets[owner] = nil
        }
    }

    func toggleSupplementTarget(_ runID: UUID) {
        if selectedSupplementRunID == runID {
            selectSupplementTarget(nil)
        } else {
            selectSupplementTarget(runID)
        }
    }

    func canStartNewTaskImmediately(in conversationID: UUID) -> Bool {
        let perCap = max(1, maxConcurrentTasks)
        let totalCap = max(perCap, maxTotalConcurrentTasks)
        return activeTasks(in: conversationID).count < perCap && activeTasks.count < totalCap
    }

    var isSelectedConversationAtConcurrencyLimit: Bool {
        selectedID.map { !canStartNewTaskImmediately(in: $0) } ?? false
    }

    func syncConversationGenerationFlags(_ conversationID: UUID) {
        let tasks = activeTasks(in: conversationID)
        if tasks.isEmpty {
            generatingConversationIDs.remove(conversationID)
            stoppingConversationIDs.remove(conversationID)
            generationOrder.removeAll { $0 == conversationID }
            supplementTargets[conversationID] = nil
        } else {
            generatingConversationIDs.insert(conversationID)
            if !generationOrder.contains(conversationID) {
                generationOrder.append(conversationID)
            }
            if tasks.allSatisfy({ stoppingTaskIDs.contains($0.token) }) {
                stoppingConversationIDs.insert(conversationID)
            } else {
                stoppingConversationIDs.remove(conversationID)
            }
            if let target = supplementTargets[conversationID],
               activeTasks[target] == nil || stoppingTaskIDs.contains(target) {
                supplementTargets[conversationID] = nil
            }
        }
    }

    static func shortTaskTitle(from text: String, attachments: [DesktopImportedDocument] = []) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !collapsed.isEmpty {
            return collapsed.count > 28 ? String(collapsed.prefix(27)) + "…" : collapsed
        }
        if let first = attachments.first?.name, !first.isEmpty {
            return first
        }
        return "当前任务"
    }

    // MARK: - Send & Queue

    func send() {
        if let selectedID, scheduledRunConversationIDs.contains(selectedID) {
            errorMessage = "定时任务正在这条会话中运行，请等它结束后再发送。"; return
        }
        // Only when the user explicitly selects a running task does Send act as a supplement to that task.
        if let supplementTask = selectedSupplementTask {
            queueInstruction(for: supplementTask.token)
            return
        }
        guard !isLoading, !isSelectedConversationMutatingBranch,
              !isManagingBackup, !selectedConversationUnavailable else { return }
        guard !isReadingAttachments else { errorMessage = "附件正在读取，请稍候再发送。"; return }
        let rawDraft = draft
        let text = rawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentAttachments = pendingAttachments
        let currentAnchors = selectedID.flatMap { attachmentDraftAnchors[$0] } ?? [:]
        guard !text.isEmpty || !currentAttachments.isEmpty else { return }
        do {
            let request = try requestConfiguration()
            if selectedID == nil { createConversation() }
            guard let id = selectedID, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
            let continuation = (currentAttachments.isEmpty && !generatingConversationIDs.contains(id))
                ? try resolveIntelligentUIContinuation(for: text, conversationID: id)
                : nil
            let effectiveDraft = continuation?.prompt(request: text) ?? rawDraft
            let submission = DesktopMessageAttachment.composeSubmission(
                draft: effectiveDraft,
                documents: currentAttachments,
                anchors: currentAnchors
            )
            let taskTitle = Self.shortTaskTitle(from: text, attachments: currentAttachments)
            if !canStartNewTaskImmediately(in: id) {
                instructionQueue.append(
                    DesktopQueuedInstruction(
                        id: UUID(),
                        conversationID: id,
                        runID: UUID(),
                        kind: .newTask,
                        targetTitle: taskTitle,
                        text: submission.text,
                        attachments: submission.attachments,
                        status: .pending
                    )
                )
                draft = ""
                pendingAttachments = []
                drafts[id] = nil
                attachments[id] = nil
                attachmentDraftAnchors[id] = nil
                return
            }
            let message = try provider.userMessage(id: UUID(), text: submission.text, attachments: submission.attachments)
            conversations[index].messages.append(message)
            if let continuation {
                intelligentUIHost.recordReceipt(continuation, userMessageID: message.id)
            }
            if conversations[index].messages.count == 1 {
                conversations[index].title = String((text.isEmpty ? currentAttachments.first?.name ?? "附件对话" : text).prefix(60))
                persistMetadata(conversations[index])
            }
            draft = ""
            pendingAttachments = []
            drafts[id] = nil
            attachments[id] = nil
            attachmentDraftAnchors[id] = nil
            startGeneration(
                conversationID: id,
                configuration: request.0,
                apiKey: request.1,
                triggerUserMessageID: message.id,
                taskTitle: taskTitle
            )
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func queueInstruction(for runID: UUID? = nil) -> Bool {
        guard let owner = selectedID, !selectedConversationUnavailable else { return false }
        let resolvedRunID = runID
            ?? selectedSupplementRunID
            ?? activeTasks(in: owner).last(where: { !stoppingTaskIDs.contains($0.token) })?.token
        guard let targetRunID = resolvedRunID,
              let active = activeTasks[targetRunID],
              active.conversationID == owner,
              !stoppingTaskIDs.contains(targetRunID) else { return false }
        guard pendingAttachments.isEmpty, !isReadingAttachments else {
            recordError("生成中仅支持排队文本。请保留附件，停止当前生成后再发送。", owner: owner)
            return false
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        instructionQueue.append(
            DesktopQueuedInstruction(
                id: UUID(),
                conversationID: owner,
                runID: active.token,
                kind: .supplement,
                targetTitle: active.title,
                text: text,
                status: .pending
            )
        )
        draft = ""
        drafts[owner] = nil
        supplementTargets[owner] = nil
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
        guard !isLoading, !isSelectedConversationMutatingBranch, !isManagingBackup,
              let value = selectedConversation, queuedRequestTasks[value.id] == nil else { return }
        let owner = value.id
        guard canStartNewTaskImmediately(in: owner) else { return }
        guard unsavedConversationIDs.contains(owner) else { startQueuedRequest(owner: owner, runID: nil); return }
        persist(value)
        let writer = persistence
        let token = UUID()
        let task = Task { [weak self] in
            await writer?.value
            guard let self, self.queuedRequestTasks[owner]?.token == token else { return }
            self.queuedRequestTasks[owner] = nil
            guard !Task.isCancelled else { return }
            self.startQueuedRequest(owner: owner, runID: nil)
        }
        queuedRequestTasks[owner] = (token, task)
    }

    func retryQueuedMessageSave() {
        guard let value = selectedConversation,
              selectedQueuedMessages.contains(where: { $0.status == .awaitingSave }) else { return }
        persist(value)
    }

    func drainQueuedInstructions(owner: UUID, token: UUID) -> [DesktopMessage] {
        guard let active = activeTasks[token], active.conversationID == owner,
              active.usesTools, !stoppingTaskIDs.contains(token) else { return [] }
        let pending = instructionQueue.filter {
            $0.conversationID == owner && $0.kind == .supplement && $0.runID == token && $0.status == .pending
        }
        guard !pending.isEmpty else { return [] }
        do {
            let messages = try pending.map { try provider.userMessage(id: $0.id, text: $0.text, attachments: $0.attachments) }
            let ids = Set(pending.map(\.id))
            for index in instructionQueue.indices where ids.contains(instructionQueue[index].id) {
                instructionQueue[index].status = .delivering
            }
            return messages
        } catch { recordError("排队指令尚未提交。\(error.localizedDescription)", owner: owner); return [] }
    }

    func startQueuedRequest(owner: UUID, runID: UUID?) {
        guard !mutatingBranchConversationIDs.contains(owner), !isManagingBackup,
              !scheduledRunConversationIDs.contains(owner),
              let index = conversations.firstIndex(where: { $0.id == owner }),
              !unsavedConversationIDs.contains(owner),
              canStartNewTaskImmediately(in: owner) else { return }

        if let runID {
            let pendingSupplements = instructionQueue.filter {
                $0.conversationID == owner && $0.kind == .supplement && $0.runID == runID && $0.status == .pending
            }
            if !pendingSupplements.isEmpty {
                do {
                    let request = try requestConfiguration(conversationID: owner)
                    let messages = try pendingSupplements.map {
                        try provider.userMessage(id: $0.id, text: $0.text, attachments: $0.attachments)
                    }
                    let ids = Set(pendingSupplements.map(\.id))
                    for queueIndex in instructionQueue.indices where ids.contains(instructionQueue[queueIndex].id) {
                        instructionQueue[queueIndex].status = .delivering
                    }
                    conversations[index].messages.append(contentsOf: messages)
                    startGeneration(
                        conversationID: owner,
                        configuration: request.0,
                        apiKey: request.1,
                        triggerUserMessageID: messages.last?.id
                    )
                } catch {
                    recordError("排队指令尚未发送，已保留在队列中。\(error.localizedDescription)", owner: owner)
                }
                return
            }
        }

        // If there is a pending newTask in this conversation, start one per available concurrency slot.
        if instructionQueue.contains(where: { $0.conversationID == owner && $0.kind == .newTask && $0.status == .pending }) {
            startNextQueuedNewTasks(preferredOwner: owner)
            return
        }

        // Fallback: manual send of any remaining pending supplement items when the conversation is idle.
        guard !generatingConversationIDs.contains(owner) else { return }
        let pending = instructionQueue.filter {
            $0.conversationID == owner && $0.status == .pending && (runID == nil || $0.runID == runID)
        }
        guard !pending.isEmpty else { return }
        do {
            let request = try requestConfiguration(conversationID: owner)
            let messages = try pending.map { try provider.userMessage(id: $0.id, text: $0.text, attachments: $0.attachments) }
            let ids = Set(pending.map(\.id))
            for queueIndex in instructionQueue.indices where ids.contains(instructionQueue[queueIndex].id) {
                instructionQueue[queueIndex].status = .delivering
            }
            conversations[index].messages.append(contentsOf: messages)
            startGeneration(
                conversationID: owner,
                configuration: request.0,
                apiKey: request.1,
                triggerUserMessageID: messages.last?.id
            )
        } catch { recordError("排队指令尚未发送，已保留在队列中。\(error.localizedDescription)", owner: owner) }
    }

    func startNextQueuedNewTasks(preferredOwner: UUID? = nil) {
        guard !isLoading, !isManagingBackup else { return }
        while activeTasks.count < max(1, maxTotalConcurrentTasks) {
            let candidateIndex = instructionQueue.indices.first { idx in
                let item = instructionQueue[idx]
                guard item.kind == .newTask, item.status == .pending, item.conversationID == preferredOwner else { return false }
                return canStartQueuedNewTask(in: item.conversationID)
            } ?? instructionQueue.indices.first { idx in
                let item = instructionQueue[idx]
                guard item.kind == .newTask, item.status == .pending else { return false }
                return canStartQueuedNewTask(in: item.conversationID)
            }
            guard let queueIndex = candidateIndex else { break }
            let item = instructionQueue[queueIndex]
            let owner = item.conversationID
            guard let convIndex = conversations.firstIndex(where: { $0.id == owner }) else { break }
            do {
                let request = try requestConfiguration(conversationID: owner)
                let userMessage = try provider.userMessage(id: item.id, text: item.text, attachments: item.attachments)
                instructionQueue[queueIndex].status = .delivering
                conversations[convIndex].messages.append(userMessage)
                if conversations[convIndex].messages.count == 1 {
                    conversations[convIndex].title = String((item.targetTitle ?? item.text).prefix(60))
                    persistMetadata(conversations[convIndex])
                }
                startGeneration(
                    conversationID: owner,
                    configuration: request.0,
                    apiKey: request.1,
                    triggerUserMessageID: userMessage.id,
                    taskTitle: item.targetTitle
                )
            } catch {
                recordError("排队任务未能开始，已保留在队列中。\(error.localizedDescription)", owner: owner)
                break
            }
        }
    }

    private func canStartQueuedNewTask(in owner: UUID) -> Bool {
        !mutatingBranchConversationIDs.contains(owner)
            && !scheduledRunConversationIDs.contains(owner)
            && !unsavedConversationIDs.contains(owner)
            && conversations.contains(where: { $0.id == owner })
            && canStartNewTaskImmediately(in: owner)
    }

    // MARK: - Task Lifecycle, Streaming Apply & In-Place Slot Replacement

    func startGeneration(
        conversationID: UUID,
        configuration: DesktopProviderConfiguration,
        apiKey: String,
        preparedResponseID: UUID? = nil,
        triggerUserMessageID: UUID? = nil,
        taskTitle: String? = nil
    ) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let otherOwnedIDs = Set(activeTasks(in: conversationID).flatMap(\.ownedMessageIDs))
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
        let resolvedUserMessage = triggerUserMessageID.flatMap { targetID in
            messages.first(where: { $0.id == targetID })
        } ?? messages.last(where: { $0.role == .user })
        let resolvedTitle = taskTitle ?? Self.shortTaskTitle(from: resolvedUserMessage?.text ?? "")
        let prefixIDs = messages.map(\.id)
        // Exclude uncommitted in-flight assistant/tool messages owned by other concurrent tasks in this conversation
        // so this task's request history never contains an empty streaming assistant message or dangling tool call.
        var providerHistory = messages.filter { !otherOwnedIDs.contains($0.id) }
        do {
            providerHistory = try requestMessages(
                providerHistory,
                conversationID: conversationID,
                configuration: configuration
            )
        } catch {
            if let replyIndex = conversations[index].messages.firstIndex(where: { $0.id == replyID }) {
                conversations[index].messages[replyIndex].state = .failed
            }
            persist(conversations[index])
            recordError("读取本地知识上下文失败。\(error.localizedDescription)", owner: conversationID)
            return
        }
        if !unsavedConversationIDs.contains(conversationID), !unsavedMetadataIDs.contains(conversationID) {
            if selectedID == conversationID { errorMessage = nil }
            conversationErrors[conversationID] = nil
        }
        let token = UUID()
        let usesTools = agentTasks.toolsEnabled || agentTasks.subagentsEnabled
        generatingTaskIDs.insert(token)
        stoppingTaskIDs.remove(token)
        if !activeTaskOrder.contains(token) { activeTaskOrder.append(token) }
        generatingConversationIDs.insert(conversationID)
        stoppingConversationIDs.remove(conversationID)
        if !generationOrder.contains(conversationID) { generationOrder.append(conversationID) }
        do {
            let run = try provider.start(
                configuration: configuration,
                apiKey: apiKey,
                messages: providerHistory,
                responseID: replyID,
                context: DesktopRunContext(
                    conversationID: conversationID,
                    toolsEnabled: agentTasks.toolsEnabled,
                    subagentsEnabled: agentTasks.subagentsEnabled,
                    toolRounds: settings.agentToolRoundLimit,
                    runMinutes: settings.agentRunMinutes,
                    persistTurns: { [weak self] turns in
                        guard let self else { return false }
                        return await self.persistAgentTurns(turns, owner: conversationID, token: token)
                    },
                    drainSteer: { [weak self] in
                        self?.drainQueuedInstructions(owner: conversationID, token: token) ?? []
                    },
                    historySnapshot: { [weak self] in
                        guard let self, let conversation = self.conversations.first(where: { $0.id == conversationID }) else {
                            return ([], [])
                        }
                        let covered = self.insights.checkpoint(for: conversation)?.coveredMessageIDs ?? []
                        return (conversation.messages, Set(covered))
                    }
                )
            )
            var state = ActiveGeneration(
                token: token,
                conversationID: conversationID,
                title: resolvedTitle,
                userMessageID: resolvedUserMessage?.id,
                initialAssistantID: replyID,
                run: run,
                assistantID: replyID,
                prefixIDs: prefixIDs,
                ownedMessageIDs: [replyID],
                usesTools: usesTools,
                task: nil,
                lastCheckpoint: Date()
            )
            state.task = Task { [weak self] in
                for await _ in run.signals {
                    guard let self, self.activeTasks[token] != nil else { return }
                    self.apply(run.drain(), for: conversationID, token: token)
                    // Coalesce token bursts into ~30 layout passes a second; drain() returns everything that arrived.
                    try? await Task.sleep(for: .milliseconds(self.transcriptIsUserScrolling ? 250 : 33))
                }
            }
            activeTasks[token] = state
            syncConversationGenerationFlags(conversationID)
        } catch {
            clearTask(token: token, conversationID: conversationID)
            if let replyIndex = conversations[index].messages.firstIndex(where: { $0.id == replyID }) {
                conversations[index].messages[replyIndex].state = .failed
            }
            persist(conversations[index])
            recordError("无法开始生成，请检查服务商设置后重试。", owner: conversationID)
        }
    }

    func apply(_ events: [DesktopProviderEvent], checkpoint: Bool = true) {
        let target = selectedID.flatMap({ generatingConversationIDs.contains($0) ? $0 : nil }) ?? generationConversationID
        guard let conversationID = target else { return }
        apply(events, for: conversationID, checkpoint: checkpoint)
    }

    func apply(_ events: [DesktopProviderEvent], for conversationID: UUID, token: UUID? = nil, checkpoint: Bool = true) {
        let resolvedToken = token ?? activeTasks(in: conversationID).last?.token
        guard let resolvedToken,
              var active = activeTasks[resolvedToken],
              active.conversationID == conversationID,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var terminal: DesktopMessageState?
        for event in events {
            switch event {
            case .snapshot(let text, let reasoning, let canonicalJSON, let unsupportedPartCount, let tools):
                guard let messageID = active.assistantID ?? active.ownedMessageIDs.last,
                      let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == messageID }) else { continue }
                if conversations[index].messages[messageIndex].text != text {
                    conversations[index].messages[messageIndex].text = text
                }
                if conversations[index].messages[messageIndex].reasoning != reasoning {
                    conversations[index].messages[messageIndex].reasoning = reasoning
                }
                conversations[index].messages[messageIndex].canonicalJSON = canonicalJSON
                conversations[index].messages[messageIndex].unsupportedPartCount = unsupportedPartCount
                if conversations[index].messages[messageIndex].tools != tools {
                    conversations[index].messages[messageIndex].tools = tools
                }
            case .transcript(let turns):
                guard !turns.isEmpty else { continue }
                replaceTaskTurnsInPlace(turns, for: &active, in: &conversations[index].messages)
            case .complete:
                terminal = .complete
            case .cancelled:
                terminal = .cancelled
            case .failed(let message):
                terminal = .failed
                recordError(message, owner: conversationID)
            }
        }
        activeTasks[resolvedToken] = active
        if let terminal {
            let ownedSet = Set(active.ownedMessageIDs)
            if active.assistantID == nil, terminal != .complete {
                let reply = DesktopMessage(role: .assistant, text: "", state: terminal)
                if let lastOwnedIndex = conversations[index].messages.lastIndex(where: { ownedSet.contains($0.id) }) {
                    conversations[index].messages.insert(reply, at: lastOwnedIndex + 1)
                } else if let userID = active.userMessageID,
                          let userIndex = conversations[index].messages.firstIndex(where: { $0.id == userID }) {
                    conversations[index].messages.insert(reply, at: userIndex + 1)
                } else {
                    conversations[index].messages.append(reply)
                }
                active.ownedMessageIDs.append(reply.id)
                active.assistantID = reply.id
            }
            if let messageID = active.assistantID,
               let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == messageID }) {
                conversations[index].messages[messageIndex].state = terminal
            }
            for ownedID in active.ownedMessageIDs where ownedID != active.assistantID {
                if let msgIdx = conversations[index].messages.firstIndex(where: { $0.id == ownedID }),
                   conversations[index].messages[msgIdx].state == .streaming {
                    conversations[index].messages[msgIdx].state = terminal == .complete ? .complete : terminal
                }
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
            clearTask(token: completedToken, conversationID: conversationID)
            if notify {
                Task {
                    await writer?.value
                    guard !unsavedConversationIDs.contains(conversationID),
                          conversations.contains(where: { $0.id == conversationID }) else { return }
                    _ = await notifications.notify(
                        runID: completedToken,
                        conversationID: conversationID,
                        outcome: terminal == .complete ? .completed : .failed
                    )
                }
            }
            let hasPendingSupplement = terminal == .complete && instructionQueue.contains(where: {
                $0.conversationID == conversationID && $0.kind == .supplement && $0.runID == completedToken && $0.status == .pending
            })
            let hasPendingNewTask = instructionQueue.contains(where: {
                $0.kind == .newTask && $0.status == .pending
            })
            if hasPendingSupplement || hasPendingNewTask {
                let followupToken = UUID()
                let task = Task { [weak self] in
                    await writer?.value
                    guard let self, self.queuedRequestTasks[conversationID]?.token == followupToken else { return }
                    self.queuedRequestTasks[conversationID] = nil
                    guard !Task.isCancelled else { return }
                    if hasPendingSupplement {
                        self.startQueuedRequest(owner: conversationID, runID: completedToken)
                    }
                    if hasPendingNewTask {
                        self.startNextQueuedNewTasks(preferredOwner: conversationID)
                    }
                }
                queuedRequestTasks[conversationID] = (followupToken, task)
            }
            if selectedID == conversationID { reloadFiles() }
            if terminal == .complete && !generatingConversationIDs.contains(conversationID) {
                scheduleAutomaticCompaction(owner: conversationID)
            }
        } else if checkpoint, Date().timeIntervalSince(active.lastCheckpoint) >= 1 {
            active.lastCheckpoint = Date()
            activeTasks[resolvedToken] = active
            persist(conversations[index])
        }
    }

    private func replaceTaskTurnsInPlace(
        _ turns: [DesktopMessage],
        for active: inout ActiveGeneration,
        in messages: inout [DesktopMessage]
    ) {
        let ownedSet = Set(active.ownedMessageIDs)
        if let firstOwned = messages.firstIndex(where: { ownedSet.contains($0.id) }),
           let lastOwned = messages.lastIndex(where: { ownedSet.contains($0.id) }),
           firstOwned <= lastOwned {
            let previous = messages[firstOwned...lastOwned]
            var incoming = turns
            if let first = previous.first(where: { $0.role == .assistant }), !first.variantIDs.isEmpty,
               let reply = incoming.firstIndex(where: { $0.role == .assistant }), incoming[reply].variantIDs.isEmpty {
                incoming[reply].variantIDs = first.variantIDs.map { $0 == first.id ? incoming[reply].id : $0 }
            }
            messages.replaceSubrange(firstOwned...lastOwned, with: incoming)
            active.ownedMessageIDs = incoming.map(\.id)
            active.assistantID = incoming.last?.role == .assistant ? incoming.last?.id : nil
            return
        }
        let prefix = Array(messages.prefix(active.prefixIDs.count))
        guard prefix.map(\.id) == active.prefixIDs else { return }
        let previous = messages.dropFirst(prefix.count)
        var incoming = turns
        if let first = previous.first(where: { $0.role == .assistant }), !first.variantIDs.isEmpty,
           let reply = incoming.firstIndex(where: { $0.role == .assistant }), incoming[reply].variantIDs.isEmpty {
            incoming[reply].variantIDs = first.variantIDs.map { $0 == first.id ? incoming[reply].id : $0 }
        }
        messages = prefix + incoming
        active.ownedMessageIDs = incoming.map(\.id)
        active.assistantID = incoming.last?.role == .assistant ? incoming.last?.id : nil
    }

    func persistAgentTurns(_ turns: [DesktopMessage], owner: UUID, token: UUID) async -> Bool {
        guard let active = activeTasks[token], active.conversationID == owner,
              let current = conversations.first(where: { $0.id == owner }) else { return false }
        let ownedSet = Set(active.ownedMessageIDs)
        let hasOwnedSlot = current.messages.contains { ownedSet.contains($0.id) }
        let hasPrefixMatch = current.messages.prefix(active.prefixIDs.count).map(\.id) == active.prefixIDs
        guard hasOwnedSlot || hasPrefixMatch else { return false }
        apply([.transcript(turns)], for: owner, token: token, checkpoint: false)
        guard let value = conversations.first(where: { $0.id == owner }) else { return false }
        persist(value)
        let writer = persistence
        await writer?.value
        return activeTasks[token] != nil
            && conversations.contains(where: { $0.id == owner })
            && !unsavedConversationIDs.contains(owner)
    }

    /// Stops a single active task by its run token without affecting other tasks in the same conversation.
    func stopTask(_ token: UUID) {
        guard let active = activeTasks[token], !stoppingTaskIDs.contains(token) else { return }
        stoppingTaskIDs.insert(token)
        if supplementTargets[active.conversationID] == token {
            supplementTargets[active.conversationID] = nil
        }
        syncConversationGenerationFlags(active.conversationID)
        active.run.cancel()
        apply(active.run.drain(), for: active.conversationID, token: token)
    }

    /// Stops either a specific task (`id` is a task token or message ID owned by a task) or a conversation.
    func stop(_ id: UUID? = nil) {
        if let id {
            if activeTasks[id] != nil {
                stopTask(id)
                return
            }
            if let matchedTask = activeTask(forMessageID: id) {
                stopTask(matchedTask.token)
                return
            }
        }
        if id == nil, let supplementRunID = selectedSupplementRunID {
            stopTask(supplementRunID)
            return
        }
        let target: UUID?
        if let id {
            target = id
        } else if let selectedID,
                  generatingConversationIDs.contains(selectedID)
                    || mutatingBranchConversationIDs.contains(selectedID)
                    || queuedRequestTasks[selectedID] != nil {
            target = selectedID
        } else {
            target = generationConversationID ?? mutatingBranchConversationIDs.first ?? queuedRequestTasks.keys.first
        }
        guard let owner = target else { return }
        queuedRequestTasks[owner]?.task.cancel()
        queuedRequestTasks[owner] = nil
        if mutatingBranchConversationIDs.contains(owner) { branchGenerationCancelled.insert(owner) }
        let tasks = activeTasks(in: owner)
        for task in tasks where !stoppingTaskIDs.contains(task.token) {
            stopTask(task.token)
        }
    }

    func stopAll() {
        for owner in Array(queuedRequestTasks.keys) {
            queuedRequestTasks[owner]?.task.cancel()
            queuedRequestTasks[owner] = nil
        }
        for owner in mutatingBranchConversationIDs { branchGenerationCancelled.insert(owner) }
        for token in activeTaskOrder { stopTask(token) }
    }

    func clearTask(token: UUID, conversationID: UUID? = nil) {
        let owner = conversationID ?? activeTasks[token]?.conversationID
        activeTasks[token] = nil
        generatingTaskIDs.remove(token)
        stoppingTaskIDs.remove(token)
        activeTaskOrder.removeAll { $0 == token }
        if let owner {
            syncConversationGenerationFlags(owner)
        }
    }

    func clearGeneration(for conversationID: UUID? = nil) {
        guard let owner = conversationID ?? generationConversationID else { return }
        let tokens = activeTasks(in: owner).map(\.token)
        for token in tokens {
            activeTasks[token]?.task?.cancel()
            activeTasks[token] = nil
            generatingTaskIDs.remove(token)
            stoppingTaskIDs.remove(token)
            activeTaskOrder.removeAll { $0 == token }
        }
        syncConversationGenerationFlags(owner)
    }
}
