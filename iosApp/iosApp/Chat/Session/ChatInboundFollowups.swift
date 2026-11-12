import Foundation
@preconcurrency import Shared

extension ChatViewModel {
    func queuedUserMessage(_ entry: IOSSteerQueueEntry, receipt: String, fallbackTargetRunId: String? = nil) -> UIMessage {
        let prompt = Self.promptText(userText: entry.text, selectedFilePreview: entry.selectedFile?.asSelectedDocument)
        let resolvedRunId = entry.targetRunId ?? fallbackTargetRunId ?? ""
        let metadata = ["chat_followup_state": receipt, "chat_followup_id": entry.id,
                        "chat_followup_run_id": resolvedRunId]
            .mapValues { Kotlinx_serialization_jsonJson.companion.parseToJsonElement(
                string: String(decoding: try! JSONEncoder().encode($0), as: UTF8.self)) }
        let message = makeUserMessage(prompt: prompt, images: entry.images.map {
            PendingChatImage(dataUrl: $0.dataUrl, previewData: $0.previewData)
        }, metadata: metadata)
        // An image-only follow-up still needs a text metadata carrier.
        let parts = message.parts.contains { $0 is UIMessagePart.Text } ? message.parts :
            [IosToolOutputJsonBridge.shared.textPart(text: "", metadata: metadata)] + message.parts
        return UIMessage(id: KotlinUuid.companion.parse(uuidString: entry.messageId), role: message.role,
                         parts: parts, annotations: message.annotations,
                         createdAt: message.createdAt, finishedAt: message.finishedAt,
                         modelId: message.modelId, usage: message.usage, translation: message.translation)
    }

    func projectQueuedEntry(_ entry: IOSSteerQueueEntry, receipt: String, state: ChatConversationRunState,
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
        projectQueuedEntry(entry, receipt: "not_applied", state: state)
        let draft = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = draft.isEmpty ? entry.text : draft + "\n" + entry.text
        pendingImages = entry.images.map { PendingChatImage(dataUrl: $0.dataUrl, previewData: $0.previewData) }
        pendingSelectedFilePreview = entry.selectedFile?.asSelectedDocument
        state.steerQueue.removeAll { $0.id == id }
        inboxIO.persistQueue(state.steerQueue, for: state.conversationId)
        Task { @MainActor [weak self] in _ = await self?.persistMessages(state: state) }
    }

    func recoverQueuedFollowups(state: ChatConversationRunState) {
        let run = runRegistry.current(for: state.conversationId)
        state.steerQueue.removeAll { entry in
            state.messages.contains { message in
                message.id.toHexDashString() == entry.messageId && message.parts.contains { part in
                    guard let text = part as? UIMessagePart.Text else { return false }
                    return IosToolOutputJsonBridge.shared.metadataString(part: text, key: "chat_followup_state") == "applied"
                }
            }
        }
        for index in state.steerQueue.indices {
            if let target = state.steerQueue[index].targetRunId,
               run.slot(forRunId: target)?.isActiveOrQueued != true {
                state.steerQueue[index].status = .cancelled
            }
            let entry = state.steerQueue[index]
            projectQueuedEntry(entry, receipt: entry.status == .cancelled ? "not_applied" : "queued", state: state)
        }
        inboxIO.persistQueue(state.steerQueue, for: state.conversationId)
    }

    func handleInboundControl(_ route: ChatInboundTurnTriage.Route, text: String) -> Bool {
        let targets = currentRun.orderedSlots.filter(\.isActiveOrQueued)
        guard let focused = focusedActiveTask else { return false }
        switch route {
        case .stop(let all):
            _ = appendUserMessage(text: text, images: [], persistsImmediately: false)
            let stopped = (all ? targets : [focused]).filter { cancelGeneration(runId: $0.runId) }
            messages.append(UIMessage.companion.assistant(prompt: stopped.isEmpty ? "任务已结束。" : "已停止\(all ? "全部任务" : "当前任务")。"))
        case .status:
            _ = appendUserMessage(text: text, images: [], persistsImmediately: false)
            let stage = focused.isQueuedForConcurrencySlot ? "等待本地执行槽位" :
                focused.activeToolTitle ?? focused.activityStage.title
            messages.append(UIMessage.companion.assistant(prompt: "当前进展：\(stage)。"))
        default: return false
        }
        bumpMessageRevision(reason: .userAppend)
        let state = currentRun.state
        Task { @MainActor [weak self] in _ = await self?.persistMessages(state: state) }
        return true
    }
}
