import Foundation
@preconcurrency import GatewayCore

// MARK: - Mac Local Dialogue Bridge (/v2/dialogue/* -> DesktopWorkspace + DesktopAgentTasks)

extension DesktopWorkspace {
    /// Connects a `DesktopMacDialogueCoordinator` to this workspace's local agent runtime.
    func attachMacDialogue(_ coordinator: DesktopMacDialogueCoordinator) {
        macDialogue = coordinator
        coordinator.onStartWorkItem = { [weak self, weak coordinator] item in
            guard let self, let coordinator else { return }
            self.startMacDialogueWorkItem(item, coordinator: coordinator)
        }
        coordinator.onFollowupAccepted = { [weak self, weak coordinator] workItemId in
            guard let self, let coordinator,
                  let id = coordinator.workItem(workItemId)?.localConversationID,
                  let conversation = self.conversations.first(where: { $0.id == id }),
                  let latest = coordinator.pendingFollowups(workItemId: workItemId).last else { return }
            self.dialoguePersonaStatus[id]?.refresh(soul: self.agentSoul, systemPrompt: self.settings.systemPrompt,
                                                   history: conversation.messages, latest: latest.text, isAddition: true)
        }
        coordinator.onStopWorkItem = { [weak self, weak coordinator] workItemId in
            guard let self, let coordinator else { return }
            self.stopMacDialogueWorkItem(workItemId, coordinator: coordinator)
        }
    }

    /// Mirrors unattended approval lifecycle transitions into the active Mac dialogue timeline.
    func handleDialogueApprovalUpdate(conversationID: UUID, approval: DesktopToolApproval?) {
        guard let coordinator = macDialogue,
              let workItemId = dialogueWorkItemByConversation[conversationID] else { return }
        if let approval {
            let meta = DesktopToolRegistry.approvalMetadata(for: approval.name, arguments: approval.arguments)
            let summary = meta.targetSummary ?? approval.name
            let text = meta.requiresLocalApproval
                ? "等待 Mac 本机批准高风险操作（\(meta.riskLevel.rawValue)）：\(summary)"
                : "等待审批（\(meta.riskLevel.rawValue)）：\(summary)"
            coordinator.appendProcessEvent(
                workItemId: workItemId,
                text: text,
                riskLevel: meta.riskLevel.rawValue,
                targetDevice: meta.targetDevice,
                targetSummary: meta.targetSummary,
                diffPreview: meta.diffPreview,
                requiresLocalApproval: meta.requiresLocalApproval
            )
        } else {
            coordinator.appendProcessEvent(workItemId: workItemId, text: "审批已处理，继续在 Mac 端执行…")
        }
    }

    func startMacDialogueWorkItem(_ item: DesktopDialogueWorkItem, coordinator: DesktopMacDialogueCoordinator) {
        let workItemId = item.workItemId
        guard dialogueRunTasks[workItemId] == nil else { return }
        let task = Task { @MainActor [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            defer { self.dialogueRunTasks[workItemId] = nil }
            await self.executeMacDialogueWorkItem(item, coordinator: coordinator)
        }
        dialogueRunTasks[workItemId] = task
    }

    func stopMacDialogueWorkItem(_ workItemId: String, coordinator: DesktopMacDialogueCoordinator) {
        if let active = dialogueGenerations[workItemId] {
            for waiting in agentTasks.records where waiting.conversationID == active.conversationID && waiting.status == .waiting {
                agentTasks.cancel(waiting.id)
            }
            dialoguePersonaStatus[active.conversationID]?.clear()
            active.run.cancel()
        }
        if let task = dialogueRunTasks[workItemId], dialogueGenerations[workItemId] == nil {
            task.cancel()
        }
        // If no execution task is active yet (or already detached), settle immediately so clients never stall.
        if dialogueRunTasks[workItemId] == nil, dialogueGenerations[workItemId] == nil {
            coordinator.settle(workItemId: workItemId, outcome: "cancelled", text: "任务已停止。")
        }
    }

    private func resolveDialogueConversation(for item: DesktopDialogueWorkItem) -> (id: UUID, isNew: Bool) {
        let remoteKey = item.conversationId ?? item.topicId
        if let existingID = dialogueConversationByRemoteKey[remoteKey],
           summaries.contains(where: { $0.id == existingID }) || conversations.contains(where: { $0.id == existingID }) {
            if conversations.contains(where: { $0.id == existingID }),
               !generatingConversationIDs.contains(existingID),
               !mutatingBranchConversationIDs.contains(existingID),
               !scheduledRunConversationIDs.contains(existingID),
               !dialogueRunConversationIDs.contains(existingID) {
                return (existingID, false)
            }
        }
        var conversation = DesktopConversation()
        conversation.title = "📱 " + Self.shortTaskTitle(from: item.prompt)
        conversations.insert(conversation, at: 0)
        dialogueConversationByRemoteKey[remoteKey] = conversation.id
        return (conversation.id, true)
    }

    private func executeMacDialogueWorkItem(_ item: DesktopDialogueWorkItem, coordinator: DesktopMacDialogueCoordinator) async {
        let workItemId = item.workItemId
        await waitUntilLoaded()

        let remoteKey = item.conversationId ?? item.topicId
        if dialogueConversationByRemoteKey[remoteKey] == nil {
            dialogueConversationByRemoteKey[remoteKey] = coordinator.lastLocalConversationID(for: remoteKey)
        }
        if let id = dialogueConversationByRemoteKey[remoteKey] {
            await loadConversation(id)?.value
        }
        if Task.isCancelled || coordinator.isStoppingOrTerminal(workItemId) {
            coordinator.settle(workItemId: workItemId, outcome: "cancelled", text: "任务已停止。")
            return
        }
        if isManagingBackup {
            coordinator.settle(workItemId: workItemId, outcome: "failed", text: "Mac 端正在执行备份或恢复，本次委派未运行。")
            return
        }

        let resolved = resolveDialogueConversation(for: item)
        let conversationID = resolved.id
        let isNew = resolved.isNew
        let taskTitle = Self.shortTaskTitle(from: item.prompt)
        let runUUID = UUID()
        let startedAt = Date()

        dialogueRunConversationIDs.insert(conversationID)
        dialogueWorkItemByConversation[conversationID] = workItemId
        agentTasks.unattendedConversations[conversationID] = taskTitle
        gatewayReporter?.runStarted(
            runID: runUUID,
            conversationID: conversationID,
            taskName: taskTitle,
            parentRunId: item.parentRunId,
            workItemId: workItemId,
            remoteConversationId: item.conversationId
        )

        var succeeded = false
        defer {
            dialoguePersonaStatus.removeValue(forKey: conversationID)?.clear()
            dialogueGenerations[workItemId] = nil
            dialogueRunConversationIDs.remove(conversationID)
            dialogueWorkItemByConversation[conversationID] = nil
            agentTasks.unattendedConversations[conversationID] = nil
            gatewayReporter?.runFinished(conversationID: conversationID, succeeded: succeeded,
                                         cancelled: coordinator.workItem(workItemId)?.lifecycle == .cancelled)
        }

        guard coordinator.markRunStarted(
            workItemId: workItemId,
            localConversationID: conversationID,
            statusText: "Mac 端正在处理…"
        ) else {
            if isNew { conversations.removeAll { $0.id == conversationID } }
            coordinator.settle(workItemId: workItemId, outcome: "failed", text: "无法保存运行状态，任务未启动。")
            return
        }

        let request: (DesktopProviderConfiguration, String)
        do {
            request = try requestConfiguration(conversationID: conversationID)
        } catch {
            if isNew { conversations.removeAll { $0.id == conversationID } }
            let message = "Mac 端尚未配置可用模型：\(error.localizedDescription)"
            coordinator.settle(workItemId: workItemId, outcome: "failed", text: message)
            return
        }

        // Strict L1-L3 policy: remote delegated work never auto-approves high-risk (L3) operations.
        let policy = DesktopApprovalPolicy(autoApproveOrdinary: agentTasks.autoApprove, autoApproveHighRisk: false,
                                           allowedTools: DesktopToolRegistry.l2ReversibleWriteTools)
        var pendingTexts = [item.prompt]
        var continuationInputs: [DesktopDialogueInputRecord] = []
        var lastOutcome: (state: DesktopMessageState, error: String?) = (.complete, nil)
        var finalAssistantText = ""
        var outcomeUnknown = false
        var followupSaveFailed = false

        while !pendingTexts.isEmpty {
            if Task.isCancelled || coordinator.isStoppingOrTerminal(workItemId) {
                lastOutcome = (.cancelled, nil)
                break
            }
            guard let convIndex = conversations.firstIndex(where: { $0.id == conversationID }) else {
                lastOutcome = (.failed, "本地会话已删除。")
                break
            }
            do {
                for promptText in pendingTexts {
                    let userMsg = try provider.userMessage(id: UUID(), text: promptText, attachments: [])
                    conversations[convIndex].messages.append(userMsg)
                }
            } catch {
                lastOutcome = (.failed, "无法构造消息：\(error.localizedDescription)")
                break
            }
            pendingTexts = []

            let prefixIDs = conversations[convIndex].messages.map(\.id)
            let history = conversations[convIndex].messages
            let reply = DesktopMessage(role: .assistant, text: "", state: .streaming)
            conversations[convIndex].messages.append(reply)
            conversations[convIndex].updatedAt = Date()
            persist(conversations[convIndex])
            if isNew && conversations[convIndex].messages.count <= 2 {
                persistMetadata(conversations[convIndex])
            }

            let run: DesktopGeneration
            do {
                let messages = try requestMessages(history, conversationID: conversationID, configuration: request.0)
                run = try provider.start(
                    configuration: request.0,
                    apiKey: request.1,
                    messages: messages,
                    responseID: reply.id,
                    context: DesktopRunContext(
                        conversationID: conversationID,
                        toolsEnabled: agentTasks.toolsEnabled,
                        subagentsEnabled: agentTasks.subagentsEnabled,
                        approvalPolicy: policy,
                        toolRounds: settings.agentToolRoundLimit,
                        runMinutes: settings.agentRunMinutes,
                        persistTurns: { [weak self] turns in
                            await self?.persistDialogueTurns(turns, owner: conversationID, prefixIDs: prefixIDs) ?? false
                        },
                        drainSteer: { [weak self, weak coordinator] in
                            guard let self, let coordinator else { return [] }
                            return self.drainDialogueFollowupsForEngine(workItemId: workItemId, coordinator: coordinator)
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
            } catch {
                finishDialogueReply(owner: conversationID, replyID: reply.id, state: .failed)
                await persistence?.value
                lastOutcome = (.failed, "Mac 端无法开始执行：\(error.localizedDescription)")
                break
            }

            if !coordinator.consumeFollowups(continuationInputs) {
                followupSaveFailed = true
                run.cancel()
            }
            if let latest = history.last {
                let status = makePersonaStatus(configuration: request.0, apiKey: request.1)
                dialoguePersonaStatus[conversationID] = status
                status?.refresh(soul: agentSoul, systemPrompt: settings.systemPrompt, history: Array(history.dropLast()),
                                latest: latest.text, isAddition: !continuationInputs.isEmpty)
            }
            dialogueGenerations[workItemId] = (run, conversationID, startedAt)
            if Task.isCancelled || coordinator.isStoppingOrTerminal(workItemId) {
                run.cancel()
            }

            lastOutcome = await withTaskCancellationHandler {
                await consumeDialogueRun(
                    run,
                    workItemId: workItemId,
                    owner: conversationID,
                    prefixIDs: prefixIDs,
                    replyID: reply.id,
                    coordinator: coordinator
                )
            } onCancel: {
                run.cancel()
            }
            dialoguePersonaStatus.removeValue(forKey: conversationID)?.clear()
            outcomeUnknown = run.hasUnknownToolOutcome
            dialogueGenerations[workItemId] = nil
            await persistence?.value

            if let text = conversations.first(where: { $0.id == conversationID })?
                .messages.last(where: { $0.role == .assistant })?.text
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                finalAssistantText = text
            }

            guard lastOutcome.state == .complete, !Task.isCancelled, !coordinator.isStoppingOrTerminal(workItemId) else {
                break
            }
            // If follow-ups arrived while streaming a plain-text turn (or after the final tool round),
            // consume them truthfully and run a continuation turn.
            let remaining = coordinator.pendingFollowups(workItemId: workItemId)
            if !remaining.isEmpty {
                continuationInputs = remaining
                pendingTexts = remaining.map(\.text)
            }
        }

        let sources = gatewayReporter?.sources(forConversation: conversationID) ?? (refs: [], paths: [])
        if outcomeUnknown || followupSaveFailed {
            coordinator.settle(workItemId: workItemId, outcome: "failed",
                               text: outcomeUnknown ? "工具执行结果需要在 Mac 上核对。" : "补充指令未能保存，请核对本次执行。",
                               outcomeUnknown: true, sourceRefs: sources.refs, sourcePaths: sources.paths)
        } else if lastOutcome.state == .cancelled || coordinator.isStopping(workItemId) || Task.isCancelled {
            coordinator.settle(
                workItemId: workItemId,
                outcome: "cancelled",
                text: "任务已停止。",
                sourceRefs: sources.refs,
                sourcePaths: sources.paths
            )
        } else if lastOutcome.state == .complete {
            succeeded = true
            coordinator.settle(
                workItemId: workItemId,
                outcome: "completed",
                text: finalAssistantText.isEmpty ? "任务已完成。" : finalAssistantText,
                sourceRefs: sources.refs,
                sourcePaths: sources.paths
            )
        } else {
            let reason = lastOutcome.error ?? "Mac 端执行未完成。"
            coordinator.settle(
                workItemId: workItemId,
                outcome: "failed",
                text: reason,
                sourceRefs: sources.refs,
                sourcePaths: sources.paths
            )
        }
    }

    private func drainDialogueFollowupsForEngine(
        workItemId: String,
        coordinator: DesktopMacDialogueCoordinator
    ) -> [DesktopMessage] {
        let pending = coordinator.pendingFollowups(workItemId: workItemId)
        guard !pending.isEmpty else { return [] }
        var messages: [DesktopMessage] = []
        var consumed: [DesktopDialogueInputRecord] = []
        for input in pending {
            if let message = try? provider.userMessage(id: UUID(), text: input.text, attachments: []) {
                messages.append(message)
                consumed.append(input)
            }
        }
        if !consumed.isEmpty {
            guard coordinator.consumeFollowups(consumed) else { return [] }
            coordinator.appendProcessEvent(workItemId: workItemId, text: "已吸收新的补充要求，继续在 Mac 端执行…")
        }
        return messages
    }

    private func consumeDialogueRun(
        _ run: DesktopGeneration,
        workItemId: String,
        owner: UUID,
        prefixIDs: [UUID],
        replyID: UUID,
        coordinator: DesktopMacDialogueCoordinator
    ) async -> (state: DesktopMessageState, error: String?) {
        var assistantID: UUID? = replyID
        var lastCheckpoint = Date()
        var lastReportedTool: String?
        var reportedStreaming = false
        var result: (state: DesktopMessageState, error: String?)?

        func applyEvents(_ events: [DesktopProviderEvent]) {
            guard result == nil else { return }
            for event in events {
                guard let index = conversations.firstIndex(where: { $0.id == owner }) else {
                    result = (.failed, "本地会话已删除。")
                    return
                }
                switch event {
                case .snapshot(let text, let reasoning, let canonicalJSON, let unsupportedPartCount, let tools):
                    dialoguePersonaStatus[owner]?.received(text: text, tools: tools)
                    if let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == assistantID }) {
                        conversations[index].messages[messageIndex].text = text
                        conversations[index].messages[messageIndex].reasoning = reasoning
                        conversations[index].messages[messageIndex].canonicalJSON = canonicalJSON
                        conversations[index].messages[messageIndex].unsupportedPartCount = unsupportedPartCount
                        if conversations[index].messages[messageIndex].tools != tools {
                            conversations[index].messages[messageIndex].tools = tools
                        }
                    }
                    if let activeTool = tools.last?.name, !activeTool.isEmpty, activeTool != lastReportedTool {
                        lastReportedTool = activeTool
                        coordinator.appendProcessEvent(workItemId: workItemId, text: "Mac 端正在调用工具：\(activeTool)")
                    } else if !reportedStreaming, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        reportedStreaming = true
                        coordinator.appendProcessEvent(workItemId: workItemId, text: "Mac 端正在生成回复…")
                    }
                case .transcript(let turns):
                    guard !turns.isEmpty, replaceDialogueSuffix(turns, owner: owner, prefixIDs: prefixIDs) else { continue }
                    if let reply = turns.last(where: { $0.role == .assistant }) {
                        dialoguePersonaStatus[owner]?.received(text: reply.text, tools: reply.tools)
                    }
                    assistantID = turns.last?.role == .assistant ? turns.last?.id : nil
                    if let activeTool = turns.last?.tools.last?.name, !activeTool.isEmpty, activeTool != lastReportedTool {
                        lastReportedTool = activeTool
                        coordinator.appendProcessEvent(workItemId: workItemId, text: "Mac 端正在调用工具：\(activeTool)")
                    }
                case .complete:
                    result = (.complete, nil)
                case .cancelled:
                    result = (.cancelled, nil)
                case .failed(let message):
                    result = (.failed, message)
                    recordError(message, owner: owner)
                }
                if result != nil { break }
            }
            if let result {
                finishDialogueReply(owner: owner, replyID: assistantID, state: result.state)
            } else if Date().timeIntervalSince(lastCheckpoint) >= 1,
                      let value = conversations.first(where: { $0.id == owner }) {
                lastCheckpoint = Date()
                persist(value)
            }
        }

        for await _ in run.signals {
            applyEvents(run.drain())
            if result != nil { break }
        }
        applyEvents(run.drain())
        if let result { return result }
        finishDialogueReply(owner: owner, replyID: assistantID, state: .failed)
        return (.failed, "运行意外结束。")
    }

    @discardableResult
    private func replaceDialogueSuffix(_ turns: [DesktopMessage], owner: UUID, prefixIDs: [UUID]) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == owner }) else { return false }
        let prefix = Array(conversations[index].messages.prefix(prefixIDs.count))
        guard prefix.map(\.id) == prefixIDs else { return false }
        conversations[index].messages = prefix + turns
        return true
    }

    private func finishDialogueReply(owner: UUID, replyID: UUID?, state: DesktopMessageState) {
        guard let index = conversations.firstIndex(where: { $0.id == owner }) else { return }
        if let replyID, let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == replyID }) {
            conversations[index].messages[messageIndex].state = state
        }
        conversations[index].updatedAt = Date()
        persist(conversations[index])
    }

    private func persistDialogueTurns(_ turns: [DesktopMessage], owner: UUID, prefixIDs: [UUID]) async -> Bool {
        guard dialogueRunConversationIDs.contains(owner), replaceDialogueSuffix(turns, owner: owner, prefixIDs: prefixIDs),
              let value = conversations.first(where: { $0.id == owner }) else { return false }
        persist(value)
        let writer = persistence
        await writer?.value
        return dialogueRunConversationIDs.contains(owner)
            && conversations.contains(where: { $0.id == owner })
            && !unsavedConversationIDs.contains(owner)
    }
}
