import Foundation
@preconcurrency import Shared

extension ChatViewModel {
    func queuedUserMessage(_ entry: IOSSteerQueueEntry, receipt: String?, fallbackTargetRunId: String? = nil) -> UIMessage {
        let prompt = Self.promptText(userText: entry.text, selectedFilePreview: entry.selectedFile?.asSelectedDocument)
        let resolvedRunId = entry.targetRunId ?? fallbackTargetRunId ?? ""
        let metadata = receipt.map { receipt in ["chat_followup_state": receipt, "chat_followup_id": entry.id,
                        "chat_followup_run_id": resolvedRunId]
            .mapValues { Kotlinx_serialization_jsonJson.companion.parseToJsonElement(
                string: String(decoding: try! JSONEncoder().encode($0), as: UTF8.self)) } }
        let message = makeUserMessage(prompt: prompt, images: entry.images.map {
            PendingChatImage(dataUrl: $0.dataUrl, previewData: $0.previewData)
        }, metadata: metadata)
        // An image-only follow-up still needs a text metadata carrier.
        let parts = metadata == nil || message.parts.contains { $0 is UIMessagePart.Text } ? message.parts :
            [IosToolOutputJsonBridge.shared.textPart(text: "", metadata: metadata)] + message.parts
        return UIMessage(id: KotlinUuid.companion.parse(uuidString: entry.messageId), role: message.role,
                         parts: parts, annotations: message.annotations,
                         createdAt: message.createdAt, finishedAt: message.finishedAt,
                         modelId: message.modelId, usage: message.usage, translation: message.translation)
    }

    func projectQueuedEntry(_ entry: IOSSteerQueueEntry, receipt: String?, state: ChatConversationRunState,
                            reason: ChatMessageUpdateReason = .toolResultAppended) {
        let existingIndex = state.messages.firstIndex { $0.id.toHexDashString() == entry.messageId }
        let existingRunId = existingIndex.flatMap { idx -> String? in
            guard let part = state.messages[idx].parts.compactMap({ $0 as? UIMessagePart.Text }).first,
                  let runId = IosToolOutputJsonBridge.shared.metadataString(part: part, key: "chat_followup_run_id"),
                  !runId.isEmpty else { return nil }
            return runId
        }
        let message = queuedUserMessage(entry, receipt: receipt, fallbackTargetRunId: existingRunId)
        if let index = existingIndex {
            let old = state.messages[index]
            state.messages[index] = UIMessage(id: old.id, role: old.role, parts: message.parts,
                annotations: old.annotations, createdAt: old.createdAt, finishedAt: old.finishedAt,
                modelId: old.modelId, usage: old.usage, translation: old.translation)
        } else {
            state.messages.append(message)
        }
        if isCurrentConversation(state.conversationId) { bumpMessageRevision(reason: reason) }
    }

    /// Retains attachments until explicit refill; refilling never discards an existing draft.
    func restoreSteerMessageToComposer(id: String) {
        let state = currentRun.state
        guard let entry = state.steerQueue.first(where: { $0.id == id }) else { return }
        guard pendingImages.isEmpty, pendingSelectedFilePreview == nil else {
            selectedFileContextError = "请先发送或移除输入框中的附件，再回填这条消息。"
            return
        }
        entry.targetRunId.flatMap(currentRun.slot(forRunId:))?.discardPersonaFollowup(entry.id)
        projectQueuedEntry(entry, receipt: "not_applied", state: state)
        let draft = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = draft.isEmpty ? entry.text : draft + "\n" + entry.text
        pendingImages = entry.images.map { PendingChatImage(dataUrl: $0.dataUrl, previewData: $0.previewData) }
        pendingSelectedFilePreview = entry.selectedFile?.asSelectedDocument
        state.steerQueue.removeAll { $0.id == id }
        inboxIO.persistQueue(state.steerQueue, for: state.conversationId)
        Task { @MainActor [weak self] in _ = await self?.persistMessages(state: state) }
    }

    /// Close legacy receipt metadata once its target can no longer consume the input.
    @discardableResult
    func clearResidualQueuedReceipts(
        in state: ChatConversationRunState,
        targetRunIds: Set<String?>? = nil
    ) -> Bool {
        var didUpdate = false
        let notAppliedValue = Kotlinx_serialization_jsonJson.companion.parseToJsonElement(string: "\"not_applied\"")
        for msgIndex in state.messages.indices {
            let message = state.messages[msgIndex]
            guard message.role == MessageRole.user else { continue }
            var replacedParts = message.parts
            var messageChanged = false
            for partIndex in replacedParts.indices {
                guard let textPart = replacedParts[partIndex] as? UIMessagePart.Text,
                      IosToolOutputJsonBridge.shared.metadataString(part: textPart, key: "chat_followup_state") == "queued" else {
                    continue
                }
                if let targetRunIds {
                    let runId = IosToolOutputJsonBridge.shared.metadataString(part: textPart, key: "chat_followup_run_id")
                    guard targetRunIds.contains(runId == "" ? nil : runId) else { continue }
                }
                var metadata = textPart.metadata ?? [:]
                metadata["chat_followup_state"] = notAppliedValue
                replacedParts[partIndex] = IosToolOutputJsonBridge.shared.textPart(
                    text: textPart.text,
                    metadata: metadata
                )
                messageChanged = true
            }
            guard messageChanged else { continue }
            state.messages[msgIndex] = UIMessage(
                id: message.id, role: message.role, parts: replacedParts,
                annotations: message.annotations, createdAt: message.createdAt,
                finishedAt: message.finishedAt, modelId: message.modelId,
                usage: message.usage, translation: message.translation
            )
            didUpdate = true
        }
        guard didUpdate else { return false }
        if isCurrentConversation(state.conversationId) {
            bumpMessageRevision(reason: .toolResultAppended)
        }
        if state.pendingAssistantRegeneration == nil {
            Task { @MainActor [weak self] in
                _ = await self?.persistMessages(state: state)
            }
        }
        return true
    }

    func recoverQueuedFollowups(state: ChatConversationRunState) {
        let run = runRegistry.current(for: state.conversationId)
        state.steerQueue.removeAll { entry in
            state.messages.contains { message in
                message.id.toHexDashString() == entry.messageId && (entry.status == .consumed || message.parts.contains { part in
                    guard let text = part as? UIMessagePart.Text else { return false }
                    return IosToolOutputJsonBridge.shared.metadataString(part: text, key: "chat_followup_state") == "applied"
                })
            }
        }
        for index in state.steerQueue.indices {
            let entry = state.steerQueue[index]
            let abandonedTriage = entry.status == .routing && !state.routingEntryIds.contains(entry.id)
            let targetEnded = entry.targetRunId.map {
                run.slot(forRunId: $0)?.isActiveOrQueued != true &&
                    IOSChatBackgroundGenerationCoordinator.shared.interjectionSignal(runId: $0) == nil
            } ?? false
            if abandonedTriage || targetEnded || entry.status == .consumed { state.steerQueue[index].status = .cancelled }
            let receipt: String? = switch state.steerQueue[index].status {
            case .cancelled: "not_applied"
            case .received: "queued"
            case .routing, .consumed: nil
            }
            projectQueuedEntry(entry, receipt: receipt, state: state)
        }
        inboxIO.persistQueue(state.steerQueue, for: state.conversationId)
    }

}

extension ChatViewModel {
    func sendLiveInterjection(text: String) -> Bool {
        let run = currentRun
        let state = run.state
        let background = IOSChatBackgroundGenerationCoordinator.shared
        let slot = focusedActiveTask
        let target = slot?.runId ?? state.conversationId.flatMap(background.activeRunId(conversationId:))
        let backgroundJob = target.flatMap(background.interjectionJob(runId:))
        let backgroundProgress = backgroundJob?.state?.interjectionProgress
        let stage = backgroundProgress?.stage ?? slot?.activityStage
        let transcript = backgroundJob?.job.messagesSnapshot.messages ?? slot?.currentTranscript ?? []
        let lastTool = transcript.last(where: { !$0.getTools().isEmpty })?.getTools().last
        let original = backgroundJob?.job.runDisplayBaseline ?? slot?.baselineMessages ?? []
        let elapsed = backgroundJob.map { snapshot in
            let last = backgroundProgress?.updatedAt ?? Date(timeIntervalSince1970: Double(snapshot.job.startedAt) / 1000)
            return max(0, Int(-last.timeIntervalSinceNow))
        } ?? slot.map { max(0, Int(ProcessInfo.processInfo.systemUptime - $0.lastUserVisibleProgressUptime)) }
        let backgroundReasoning = backgroundJob?.job.messagesSnapshot.lastMessage?.parts
            .compactMap { ($0 as? UIMessagePart.Reasoning)?.reasoning }.last
        let activeTool = slot?.activeToolTitle ?? lastTool.flatMap { $0.output.isEmpty ? ChatToolStepModel(tool: $0).title : nil }
        let hasActiveTool = activeTool != nil || stage == .runningTool
        let context = ChatInboundTurnTriage(
            text: text, attachments: !pendingImages.isEmpty || pendingSelectedFilePreview != nil,
            originalRequest: original.last(where: { $0.role == .user })?.toText() ?? "",
            stage: slot?.isQueuedForConcurrencySlot == true ? "等待执行槽位" : stage?.title ?? "处理中",
            stageName: stage?.rawValue ?? "processing",
            tool: activeTool,
            reasoning: slot?.liveReasoningSummary ?? backgroundReasoning, elapsed: elapsed,
            recentNote: slot?.explicitFailureOrStallReason ?? lastTool?.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.last
                ?? slot?.keepaliveMessages.last?.toText()
        )
        if !hasActiveTool, context.explicitRoute == nil {
            return enqueueSteerMessage(text: text, targetRunId: target, routing: false)
        }
        let stopTargets = Set(run.orderedSlots.filter(\.isActiveOrQueued).map(\.runId))
            .union(background.runIds(for: state.conversationId))
        guard enqueueSteerMessage(text: text, targetRunId: target, routing: true),
              let entry = state.steerQueue.last else { return false }

        func apply(_ decision: ChatInboundTurnTriage.Decision) {
            applyLiveInterjection(decision, entry: entry, in: run, stopTargets: stopTargets)
        }

        if context.explicitRoute != nil {
            apply(context.fallback)
        } else if let model = resolveAuxModel(sharedSettings.snapshot.suggestionModelId) {
            state.routingEntryIds.insert(entry.id)
            let previous = state.routingTail
            state.routingTail = Task { @MainActor in
                let decision = await context.resolve {
                    await self.runAuxModel(model: model, prompt: context.prompt, conversationId: state.conversationId,
                                           maxTokens: KotlinInt(value: 160))
                }
                await previous?.value
                apply(decision)
                if state.routingEntryIds.isEmpty { state.routingTail = nil }
            }
        } else {
            apply(context.fallback)
        }
        return true
    }

    private func applyLiveInterjection(_ decision: ChatInboundTurnTriage.Decision, entry: IOSSteerQueueEntry,
                                       in run: ChatConversationRun, stopTargets: Set<String>) {
        let state = run.state
        let background = IOSChatBackgroundGenerationCoordinator.shared
        let wasRouting = state.routingEntryIds.remove(entry.id) != nil
        guard let index = state.steerQueue.firstIndex(where: { $0.id == entry.id }),
              state.steerQueue[index].status == .routing || (wasRouting && state.steerQueue[index].status == .cancelled),
              state.messages.contains(where: { $0.id.toHexDashString() == entry.messageId }) else { return }
        let target = state.steerQueue[index].targetRunId
        let slot = target.flatMap(run.slot(forRunId:))
        var reply = decision.reply
        let cancelledSteer = decision.route == .steer && state.steerQueue[index].status == .cancelled
        if cancelledSteer || decision.route != .steer { slot?.discardPersonaFollowup(entry.id) }
        if cancelledSteer {
            reply = entry.text.unicodeScalars.allSatisfy(\.isASCII) ? "The task stopped before I could apply that change." : "任务已停止，这次补充已保留在对话里。"
        } else if decision.route == .steer {
            state.clearChildResultWait()
            state.steerQueue[index].status = .received
            projectQueuedEntry(state.steerQueue[index], receipt: "queued", state: state)
            reply = ""
        } else {
            state.steerQueue[index].status = .consumed
        }
        inboxIO.persistQueue(state.steerQueue, for: state.conversationId)
        if decision.route == .stop || decision.route == .stopAll {
            let targets = decision.route == .stopAll ? stopTargets : Set([target].compactMap { $0 })
            let stopped = targets.filter { cancelGeneration(runId: $0) }
            if stopped.isEmpty { reply = entry.text.unicodeScalars.allSatisfy(\.isASCII) ? "The task has ended." : "任务已经结束。" }
        }
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReply.isEmpty {
            let ack = UIMessage.companion.assistant(prompt: trimmedReply)
            if let user = state.messages.firstIndex(where: { $0.id.toHexDashString() == entry.messageId }) {
                state.messages.insert(ack, at: user + 1)
            }
            run.state.interjectionReplyIDs[entry.messageId] = ack.id.toHexDashString()
        }
        if isCurrentConversation(state.conversationId) { bumpMessageRevision(reason: .toolResultAppended) }
        switch decision.route {
        case .steer where !cancelledSteer:
            signalSteer(for: state.steerQueue[index], state: state)
            let handedOff = target.flatMap(background.interjectionSignal(runId:)) != nil
            if slot?.isActiveOrQueued != true, !handedOff, let target {
                handleSteerQueueAtRunTerminal(state: state, autoContinue: true, completedIds: [target])
            } else if target == nil, state.conversationId.map({ !isGenerationActive(conversationId: $0) }) == true {
                handleSteerQueueAtRunTerminal(state: state, autoContinue: true)
            }
        case .independent:
            startInterjectionTask(entry, in: run, digest: chatInputDigest(for: entry.text.isEmpty ? "[attachment]" : entry.text),
                                  phoneControlUserInitiated: true)
        default: break
        }
        Task { @MainActor in
            guard state.pendingAssistantRegeneration == nil, await self.persistMessages(state: state) else { return }
            if decision.route != .steer {
                state.steerQueue.removeAll { $0.id == entry.id }
                self.inboxIO.persistQueue(state.steerQueue, for: state.conversationId)
            }
        }
    }
}
