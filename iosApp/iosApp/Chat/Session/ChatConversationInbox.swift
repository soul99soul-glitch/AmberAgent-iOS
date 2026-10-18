import Foundation
import CryptoKit
import Observation
import OSLog
import SwiftUI
@preconcurrency import Shared

extension ChatViewModel {

    func enqueueSteerMessage(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let selectedFile = pendingSelectedFilePreview
        guard !trimmed.isEmpty || !images.isEmpty || selectedFile != nil else { return false }
        guard isGenerationActive else { return false }
        ensureSteerQueueLoaded(state: currentRun.state)
        guard steerQueue.count < IOSSteerQueueStore.maxPendingUserMessages else { return false }
        currentRun.state.clearChildResultWait()
        steerQueue.append(IOSSteerQueueEntry(
            id: UUID().uuidString,
            text: trimmed,
            createdAt: Date(),
            images: images.map { IOSSteerQueueImage(dataUrl: $0.dataUrl, previewData: $0.previewData) },
            selectedFile: selectedFile.map(IOSSteerQueuedFile.init)
        ))
        persistSteerQueue()
        // P1-d: steer 入队即打断同会话的 wait_agent（信号在入队成功后发射；
        // wait_agent 事件后复查 mailbox 为空 → 返回 "Wait interrupted by new input."）。
        if let conversationId = currentConversationId {
            let center = inboxIO
            let hex = conversationId.toHexDashString()
            Task { @MainActor in
                await center.signal(conversationIdHex: hex)
            }
        }
        inputText = ""
        invalidateSuggestionRequest()
        chatSuggestions = []
        pendingSelectedFilePreview = nil
        clearPendingImages()
        selectedFileContextError = nil
        return true
    }

    /// 撤销一条排队消息；同步更新 sidecar（exactly once）。
    func removeSteerMessage(id: String) {
        guard steerQueue.contains(where: { $0.id == id }) else { return }
        steerQueue.removeAll { $0.id == id }
        persistSteerQueue()
    }

    /// 工具循环边界消费：出队全部排队消息 → 作为真实 user 消息上屏并按既有路径
    /// 持久化进会话，返回生成的消息供下一轮 upload 折入。队列为空或 run 不属于
    /// 当前会话时零操作（不同会话的队列不串）。
    @discardableResult
    func drainSteerQueue(conversationId: KotlinUuid?) -> [UIMessage] {
        guard isCurrentConversation(conversationId) else { return [] }
        return drainSteerQueue(state: currentRun.state)
    }

    func drainSteerQueue(state: ChatConversationRunState) -> [UIMessage] {
        ensureSteerQueueLoaded(state: state)
        guard !state.steerQueue.isEmpty else { return [] }
        let entries = state.steerQueue
        state.steerQueue = []
        inboxIO.persistQueue([], for: state.conversationId)
        let drained = entries.map { entry -> UIMessage in
            let prompt = Self.promptText(
                userText: entry.text,
                selectedFilePreview: entry.selectedFile?.asSelectedDocument
            )
            let images = entry.images.map {
                PendingChatImage(dataUrl: $0.dataUrl, previewData: $0.previewData)
            }
            return makeUserMessage(prompt: prompt, images: images)
        }
        // 与 appendUserMessage 同款上屏：真实 user 消息进 timeline（后续会话落盘
        // 与工具轮次持久化共用既有 persistMessages 路径）。
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            state.messages.append(contentsOf: drained)
            if isCurrentConversation(state.conversationId) { bumpMessageRevision(reason: .userAppend) }
        }
        if isCurrentConversation(state.conversationId) {
            invalidateSuggestionRequest()
            chatSuggestions = []
            selectedFileContextError = nil
        }
        Task { @MainActor [weak self] in
            _ = await self?.persistMessages(state: state)
        }
        return drained
    }

    /// run 终态：成功则出队头一条上屏并自动开下一轮；取消/失败则回填 composer。
    func handleSteerQueueAtRunTerminal(for conversationId: KotlinUuid?, autoContinue: Bool) {
        guard isCurrentConversation(conversationId) else { return }
        handleSteerQueueAtRunTerminal(state: currentRun.state, autoContinue: autoContinue)
    }

    func handleSteerQueueAtRunTerminal(state: ChatConversationRunState, autoContinue: Bool) {
        ensureSteerQueueLoaded(state: state)
        guard !state.steerQueue.isEmpty else { return }
        if autoContinue {
            sendNextSteerQueueEntry(state: state)
            return
        }
        restoreSteerQueueLeftoverToComposer(state: state)
    }

    /// 出队头一条 → 上屏 →（若开启自动生成）立刻开下一轮。剩余条目继续留在队列。
    private func sendNextSteerQueueEntry(state: ChatConversationRunState) {
        guard let entry = state.steerQueue.first else { return }
        state.steerQueue.removeFirst()
        inboxIO.persistQueue(state.steerQueue, for: state.conversationId)
        let images = entry.images.map {
            PendingChatImage(dataUrl: $0.dataUrl, previewData: $0.previewData)
        }
        let prompt = Self.promptText(
            userText: entry.text,
            selectedFilePreview: entry.selectedFile?.asSelectedDocument
        )
        let digest = chatInputDigest(for: prompt.isEmpty ? "[image]" : prompt)
        let userMsg = makeUserMessage(prompt: prompt, images: images)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            state.messages.append(userMsg)
            if isCurrentConversation(state.conversationId) { bumpMessageRevision(reason: .userAppend) }
        }
        if isCurrentConversation(state.conversationId) {
            invalidateSuggestionRequest()
            chatSuggestions = []
            selectedFileContextError = nil
        }
        Task { @MainActor [weak self] in
            _ = await self?.persistMessages(state: state)
        }
        guard autoGenerateResponses else { return }
        if isCurrentConversation(state.conversationId) {
            generateResponse(inputDigest: digest, conversationId: state.conversationId)
        } else if let configuration = state.generationConfiguration,
                  let conversationId = state.conversationId {
            host(for: conversationId)?.start(
                providerSetting: configuration.provider,
                params: configuration.params,
                inputDigest: digest,
                conversationId: conversationId,
                uploadMessages: state.messages,
                toolExposureBridge: state.toolExposureBridge,
                recipeCatalogSnapshot: configuration.dynamicSnapshot
            )
        }
    }

    /// 取消/失败终态：纯文本 leftover 拼回 composer；含附件条目留队防丢媒体。
    func restoreSteerQueueLeftoverToComposer(for conversationId: KotlinUuid?) {
        guard isCurrentConversation(conversationId) else { return }
        restoreSteerQueueLeftoverToComposer(state: currentRun.state)
    }

    func restoreSteerQueueLeftoverToComposer(state: ChatConversationRunState) {
        ensureSteerQueueLoaded(state: state)
        guard !state.steerQueue.isEmpty else { return }
        let textOnly = state.steerQueue.filter { !$0.hasAttachments }
        let withAttachments = state.steerQueue.filter(\.hasAttachments)
        state.steerQueue = withAttachments
        inboxIO.persistQueue(state.steerQueue, for: state.conversationId)
        guard !textOnly.isEmpty else { return }
        let joined = textOnly.map(\.text).joined(separator: "\n")
        let current = state.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.inputText = current.isEmpty ? joined : current + "\n" + joined
    }

    // MARK: - Mailbox 消费（P1-b）

    /// Owned by the visible chat's task. Re-subscribing when a run becomes
    /// idle also catches reports that arrived between yield and teardown.
    func observeIdleMailboxResults(conversationId: KotlinUuid?) async {
        guard let conversationId else { return }
        await orchestratedStatusRefreshTask?.value
        guard !Task.isCancelled, isCurrentConversation(conversationId),
              !isGenerationActive, !currentConversationIsOrchestratedChild else { return }
        let stream = await inboxIO.events(for: conversationId.toHexDashString())
        await previewIdleMailboxResults(conversationId: conversationId)
        for await _ in stream {
            guard !Task.isCancelled else { break }
            await previewIdleMailboxResults(conversationId: conversationId)
        }
    }



    func previewIdleMailboxResults(conversationId: KotlinUuid) async {
        guard !Task.isCancelled, isCurrentConversation(conversationId),
              !isGenerationActive, !currentConversationIsOrchestratedChild else { return }
        let state = currentRun.state
        guard let reports = try? await inboxIO.pendingResults(forConversationId: conversationId) else { return }
#if DEBUG
        await beforeIdleMailboxPreviewApplyForTesting?()
#endif
        // A run or conversation switch may happen while Room reads. Because
        // this was only a peek, declining the UI update leaves all mail intact.
        guard !Task.isCancelled, isCurrentConversation(conversationId),
              !isGenerationActive, !state.isOrchestratedChild else { return }
        _ = appendMailboxEnvelopes(reports, state: state)
    }

    /// Own the subscription at conversation scope, independent of the visible
    /// ChatView. Subscribe before peeking so completion during teardown is caught.
    /// Jev 完成校验：运行结束后异步判断，不影响终态处理。
    static func checkCompletionClaim(state: ChatConversationRunState, runId: String, messages: [UIMessage]) {
        state.jevCompletionNoticeMessageId = nil
        guard let finalId = messages.last?.id.description() else { return }
        Task { @MainActor in
            guard await IOSJevCompletionCheckService.shared.needsVerification(messages: messages, runKey: runId) else { return }
            state.jevCompletionNoticeMessageId = finalId
        }
    }

    func observeYieldedChildResults(state: ChatConversationRunState, runId: String) {
        guard state.waitingForChildRunId == runId, let id = state.conversationId else { return }
        state.childResultWakeTask?.cancel()
        let center = inboxIO
        state.childResultWakeTask = Task { @MainActor [weak self, weak state] in
            let events = await center.events(for: id.toHexDashString())
            var iterator = events.makeAsyncIterator()
            var retrySeconds = 1
            while !Task.isCancelled {
                do {
                    if try await self?.resumeYieldedRunIfReady(state: state, runId: runId) != false { return }
                    retrySeconds = 1
                    guard await iterator.next() != nil else { return }
                } catch {
                    // Protected files/Room can be temporarily unavailable. Keep
                    // ownership and retry without requiring another child signal.
                    guard !Task.isCancelled else { return }
                    NSLog("[AmberChat] Child-result resume deferred: %@", error.localizedDescription)
                    do { try await Task.sleep(for: .seconds(retrySeconds)) }
                    catch { return }
                    retrySeconds = min(30, retrySeconds * 2)
                }
            }
        }
    }

    /// A newer send/start/cancel clears ownership synchronously. Recheck after
    /// every read; previews never acknowledge mail, the resumed run does that.
    private func resumeYieldedRunIfReady(state: ChatConversationRunState?, runId: String) async throws -> Bool {
        guard let state, !Task.isCancelled, state.waitingForChildRunId == runId,
              let id = state.conversationId, let host = host(for: id),
              !isGenerationActive(conversationId: id) else { return true }
        let reports = try await inboxIO.pendingResults(forConversationId: id)
#if DEBUG
        try await beforeChildResultWakeApplyForTesting?()
#endif
        guard !Task.isCancelled, state.waitingForChildRunId == runId,
              !isGenerationActive(conversationId: id) else { return true }
        guard !reports.isEmpty else { return false }
        guard let store = conversationStore,
              try await store.loadConversationForOrchestration(id) != nil else {
            state.clearChildResultWait()
            return true
        }
        guard !Task.isCancelled, state.waitingForChildRunId == runId,
              !isGenerationActive(conversationId: id),
              let configuration = state.generationConfiguration else { return true }
        // Consume the permission before starting. All pending reports share one
        // run, and its normal mailbox boundary acknowledges them exactly once.
        state.waitingForChildRunId = nil
        state.childResultWakeTask = nil
        _ = appendMailboxEnvelopes(reports, state: state)
        host.start(
            providerSetting: configuration.provider,
            params: configuration.params,
            inputDigest: chatInputDigest(for: "child-results:\(runId)"),
            conversationId: id,
            uploadMessages: state.messages,
            toolExposureBridge: state.toolExposureBridge,
            recipeCatalogSnapshot: configuration.dynamicSnapshot
        )
        return true
    }

    /// 工具循环/新 run 首轮边界消费 mailbox：Room 事务 drain 未投递信封（exactly-once，
    /// 二次调用为空），按既有路径持久化进会话并供下一轮 upload 折入。
    /// 结果由 timeline 投影为独立代理卡片，不伪装成用户发送，也不改变草稿或附件提示。
    /// 未消费信封不回 composer，留在 Room 等下次 run。
    @discardableResult
    func drainMailbox(conversationId: KotlinUuid?) async -> [UIMessage] {
        guard isCurrentConversation(conversationId) else { return [] }
        return await drainMailbox(state: currentRun.state)
    }

    func drainMailbox(state: ChatConversationRunState) async -> [UIMessage] {
        let envelopes = await inboxIO.drainPending(forConversationId: state.conversationId)
        return appendMailboxEnvelopes(envelopes, state: state)
    }

    private func appendMailboxEnvelopes(
        _ envelopes: [IOSMailboxStore.EnvelopeSnapshot], state: ChatConversationRunState
    ) -> [UIMessage] {
        guard !envelopes.isEmpty else { return [] }
        let existingIDs = Set(state.messages.map { $0.id.toHexDashString().lowercased() })
        let drained = envelopes.map { envelope in
            amberMailboxMessage(
                envelopeId: envelope.id,
                authorThreadId: envelope.authorThreadId,
                type: envelope.type,
                payload: envelope.payload
            )
        }.filter {
            !existingIDs.contains($0.id.toHexDashString().lowercased())
        }
        guard !drained.isEmpty else { return [] }
        withAnimation(.smooth(duration: 0.3)) {
            state.messages.append(contentsOf: drained)
            if isCurrentConversation(state.conversationId) {
                // A mailbox update is not a user's send action and must not
                // resume following while the user reads history.
                bumpMessageRevision(reason: .toolResultAppended)
            }
        }
        Task { @MainActor [weak self] in
            _ = await self?.persistMessages(state: state)
        }
        return drained
    }

    private func persistSteerQueue() {
        inboxIO.persistQueue(steerQueue, for: currentConversationId)
    }

    private func ensureSteerQueueLoaded(state: ChatConversationRunState) {
        guard !state.steerQueueLoaded else { return }
        state.steerQueue = inboxIO.loadQueue(conversationId: state.conversationId)
        state.steerQueueLoaded = true
    }


}
