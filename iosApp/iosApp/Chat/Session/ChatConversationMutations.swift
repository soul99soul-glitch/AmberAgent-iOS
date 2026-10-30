import Foundation
import CryptoKit
import Observation
import OSLog
import SwiftUI
@preconcurrency import Shared

extension ChatViewModel {
    private func rejectMessageMutationIfNeeded() -> Bool {
        guard let store = conversationStore, let id = currentConversationId,
              store.isMessageMutationInProgress(for: id) else { return false }
        configurationError = IOSConversationStore.messageMutationPendingMessage
        return true
    }

    /// - Parameter startsGenerationAfterInsertion: composer 发送传 true：生成在用户消息
    ///   入场动画落位后才启动（见 `DeferredGenerationStart`）。其他调用方需要同步拿到 run。
    @discardableResult
    func sendMessage(startsGenerationAfterInsertion: Bool = false) -> Bool {
        // 两处 composer 发送入口（ChatView.swift）都经过这里，且是同一事件帧内的
        // 第一行代码，用它做 tap-to-send 起点比按 startsGenerationAfterInsertion
        // 二次分支更简单，覆盖的非 composer 调用方（AppShell 全局发送）本就极少。
        ChatPerfTrace.event("SendTap")
        guard !rejectMessageMutationIfNeeded() else { return false }
        startDeferredGenerationNow()
        guard conversationStore?.isImportingConversationDocuments != true else {
            configurationError = "正在恢复会话，请等待完成后再发送。"
            return false
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let continuation: IOSIntelligentUISubmission?
        do { continuation = try intelligentUIContinuation(for: text) }
        catch {
            configurationError = error.localizedDescription
            return false
        }
        let prompt = continuation?.prompt(request: text) ?? text
        let metadata: [String: Kotlinx_serialization_jsonJsonElement]?
        do { metadata = try continuation?.metadata }
        catch {
            configurationError = error.localizedDescription
            return false
        }
        let hasImages = !pendingImages.isEmpty
        if let blockReason = composerSendBlockReason(for: text) {
            if case .configuration(let issue) = blockReason {
                configurationError = issue.message
            }
            return false
        }
        // 生成中：图/附件整包入队，OCR 在下一轮上传前统一补齐。
        // 仅硬拦超张数，避免无模型时误杀入队。
        if isGenerationActive {
            if hasImages, pendingImages.count > Self.maxImagesPerMessage {
                selectedFileContextError = IOSAppLocalization.formatted(
                    "一次最多发送 %lld 张图片",
                    defaultValue: "一次最多发送 %lld 张图片",
                    arguments: [Int64(Self.maxImagesPerMessage)]
                )
                return false
            }
            return enqueueSteerMessage(text: text)
        }
        // 空闲发送：按模型视觉能力判断（对齐安卓 ImageAttachmentValidator）：
        // ready→直接发；fallback→先用视觉模型识别成文字再发；blocked→拦下提示，绝不静默丢弃。
        if hasImages {
            switch imageAttachmentState {
            case .blocked(let reason):
                selectedFileContextError = reason
                return false
            case .fallback:
                configurationError = nil
                startVisionFallbackAndSend(text: prompt, images: pendingImages, metadata: metadata)
                return true
            case .ready, .none:
                break
            }
        }
        configurationError = nil
        sendUserMessage(
            text: prompt,
            images: pendingImages,
            metadata: metadata,
            startsGenerationAfterInsertion: startsGenerationAfterInsertion
        )
        return true
    }

    /// Only an exact, explicit reference attaches the user's latest card draft to ordinary chat.
    private func intelligentUIContinuation(for text: String) throws -> IOSIntelligentUISubmission? {
        let intent = text.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？"))
        guard ["按这个继续", "基于选择继续", "按当前选择继续"].contains(intent),
              let store = conversationStore, let conversationID = currentConversationId?.toHexDashString(),
              let source = store.intelligentUIStateStore.activeSource(for: conversationID) else { return nil }
        guard sharedSettings.snapshot.agentRuntime.generativeUi.enabled,
              sharedSettings.snapshot.agentRuntime.generativeUi.enableActions else {
            throw IOSIntelligentUIProtocolError(reason: "任务卡交互已关闭，请在设置中启用后继续。")
        }
        guard !isGenerationActive, !isLoading else { throw IOSIntelligentUIProtocolError(reason: "当前回复结束后可按任务卡选择继续。") }
        guard let message = messages.first(where: { $0.id.toHexDashString() == source.messageID }),
              message.role == .assistant, message.parts.indices.contains(source.textPartIndex),
              let textPart = message.parts[source.textPartIndex] as? UIMessagePart.Text,
              IosToolOutputJsonBridge.shared.metadataString(part: textPart, key: IOSIntelligentUITerminal.completedKey) == "completed" else {
            throw IOSIntelligentUIProtocolError(reason: "最近操作的任务卡不在当前分支或尚未完成，请重新选择当前方案。")
        }
        let definition = IOSIntelligentUIProtocol.parse(textPart.text, isStreaming: false).compactMap { segment -> IOSIntelligentUICardDefinition? in
            if case .card(let card) = segment, card.cardID == source.cardID { return card }
            return nil
        }.first
        guard let definition else { throw IOSIntelligentUIProtocolError(reason: "任务卡内容已变更，请重新选择。") }
        store.intelligentUIStateStore.register(source: source, definition: definition)
        let draft = store.intelligentUIStateStore.draft(for: source, definition: definition)
        return try IOSIntelligentUISubmission(source: source, definition: definition, draft: draft)
    }

    func refreshIntelligentUIReceipts(messages: [UIMessage], conversationID: String?) {
        guard let conversationID else { return }
        intelligentUIHost?.refreshReceipts(messages: messages, conversationID: conversationID)
    }

    /// Card input is independent of the composer and becomes runnable only after its user message is saved.
    func submitIntelligentUI(_ submission: IOSIntelligentUISubmission) async -> IOSIntelligentUISubmitResult {
        guard let store = conversationStore, let conversationID = currentConversationId,
              conversationID.toHexDashString() == submission.source.conversationID else {
            return .failure("任务卡不属于当前会话，请返回原会话后提交。")
        }
        guard !store.isMessageMutationInProgress(for: conversationID) else {
            return .failure(IOSConversationStore.messageMutationPendingMessage)
        }
        guard sharedSettings.snapshot.agentRuntime.generativeUi.enabled,
              sharedSettings.snapshot.agentRuntime.generativeUi.enableActions else {
            return .failure("任务卡交互已关闭，请在设置中启用后提交。")
        }
        guard !store.isImportingConversationDocuments else { return .failure("正在恢复会话，请等待完成后再提交。") }
        guard !intelligentUISubmissionsInFlight.contains(submission.source.conversationID) else {
            return .failure("这张任务卡正在提交。")
        }
        guard !isGenerationActive, !isLoading, retryMutationRunId == nil else { return .failure("当前回复结束后可提交。") }
        guard !currentConversationIsOrchestratedChild else { return .failure("此会话由父线程编排，暂不支持直接输入。") }
        guard !hasPendingUserGate else { return .failure("请先处理当前待确认的操作。") }
        if autoGenerateResponses, let issue = configurationIssue { return .failure(issue.message) }
        guard let sourceMessage = messages.first(where: { $0.id.toHexDashString() == submission.source.messageID }),
              sourceMessage.role == .assistant,
              sourceMessage.parts.indices.contains(submission.source.textPartIndex),
              let textPart = sourceMessage.parts[submission.source.textPartIndex] as? UIMessagePart.Text else {
            return .failure("任务卡来源已不在当前分支，请使用当前方案。")
        }
        guard IosToolOutputJsonBridge.shared.metadataString(part: textPart, key: IOSIntelligentUITerminal.completedKey) == "completed" else {
            return .failure("任务卡所在回复尚未成功完成，请重新生成后选择。")
        }
        let cards = IOSIntelligentUIProtocol.parse(textPart.text, isStreaming: false).compactMap { segment -> IOSIntelligentUICardDefinition? in
            if case .card(let definition) = segment { return definition }
            return nil
        }
        guard let definition = cards.first(where: { $0.cardID == submission.source.cardID }) else {
            return .failure("任务卡内容已变更，请重新选择。")
        }
        store.intelligentUIStateStore.register(source: submission.source, definition: definition)
        let draft = store.intelligentUIStateStore.draft(for: submission.source, definition: definition)
        guard submission.matches(draft) else { return .failure("任务卡选择已变更，请按当前选择重新提交。") }
        let metadata: [String: Kotlinx_serialization_jsonJsonElement]
        do {
            let expected = try IOSIntelligentUISubmission(source: submission.source, definition: definition, draft: draft)
            guard expected.goal == submission.goal, expected.question == submission.question,
                  expected.option == submission.option, expected.inputs == submission.inputs,
                  expected.taskKind == submission.taskKind, expected.studySummary == submission.studySummary,
                  submission.inputs.allSatisfy({ $0.value.count <= 2_000 }) else {
                return .failure("提交内容与当前任务卡选择不一致，请重新提交。")
            }
            metadata = try submission.metadata
        } catch { return .failure(error.localizedDescription) }
        refreshIntelligentUIReceipts(messages: messages, conversationID: submission.source.conversationID)
        guard intelligentUIHost?.receipts[submission.source]?.matches(draft) != true else {
            return .failure("此选择已经提交；修改后可以再提交。")
        }
        intelligentUISubmissionsInFlight.insert(submission.source.conversationID)
        defer { intelligentUISubmissionsInFlight.remove(submission.source.conversationID) }
        let run = currentRun
        let insertion = appendUserMessage(text: submission.prompt(), images: [], metadata: metadata,
                                          consumesComposer: false, persistsImmediately: false)
        let snapshot = run.state.messages
        let baseline = store.writeBaseline(for: conversationID)
        let saved = await persistMessagesSnapshot(snapshot, targetConversationId: conversationID,
                                                  pendingRegeneration: nil, store: store,
                                                  writeBaseline: baseline, state: run.state)
        guard saved else {
            run.state.messages.removeAll { $0.id.toHexDashString() == insertion.messageId }
            if currentRun === run { bumpMessageRevision(reason: .userAppend) }
            return .failure("任务卡选择未能保存，请重试。")
        }
        let durableMessages: [UIMessage]?
        if store.currentConversation?.id == conversationID {
            durableMessages = store.currentMessages
        } else {
            durableMessages = await store.messages(for: conversationID)
        }
        guard let durableMessages,
              durableMessages.contains(where: { message in
                  message.id.toHexDashString() == insertion.messageId && message.parts.contains { part in
                      guard let text = part as? UIMessagePart.Text,
                            let raw = IosToolOutputJsonBridge.shared.metadataString(part: text, key: IOSIntelligentUISubmission.metadataKey),
                            let persisted = try? JSONDecoder().decode(IOSIntelligentUISubmission.self, from: Data(raw.utf8)) else { return false }
                      return persisted.id == submission.id
                  }
              }) else { return .failure("任务卡提交已不在当前保存分支，请重新选择后提交。") }
        run.state.messages = durableMessages
        refreshIntelligentUIReceipts(messages: durableMessages, conversationID: submission.source.conversationID)
        guard let durableSource = durableMessages.first(where: { $0.id.toHexDashString() == submission.source.messageID }),
              durableSource.parts.indices.contains(submission.source.textPartIndex),
              let durableText = durableSource.parts[submission.source.textPartIndex] as? UIMessagePart.Text,
              durableText.text == textPart.text,
              IosToolOutputJsonBridge.shared.metadataString(part: durableText, key: IOSIntelligentUITerminal.completedKey) == "completed" else { return .saved }
        guard currentRun === run, currentConversationId == conversationID, autoGenerateResponses,
              !store.isImportingConversationDocuments, !isGenerationActive, !isLoading, !hasPendingUserGate,
              retryMutationRunId == nil, !currentConversationIsOrchestratedChild,
              configurationIssue == nil,
              sharedSettings.snapshot.agentRuntime.generativeUi.enabled,
              sharedSettings.snapshot.agentRuntime.generativeUi.enableActions else { return .saved }
        generateResponse(inputDigest: insertion.digest, conversationId: conversationID, phoneControlUserInitiated: true)
        return .started
    }

    /// Starts a Watch question through the same provider, tool and persistence
    /// pipeline as a normal text turn. Watch input is accepted only while the
    /// phone is idle, so an existing draft or run can never be commandeered.
    @discardableResult
    /// The reply-length request is appended after validation and stays visible.
    static func watchMessage(_ text: String, replyInstruction: String?) -> String {
        replyInstruction.map { "\(text)\n\n\($0)" } ?? text
    }

    func startWatchQuestion(
        text: String,
        conversationId requestedConversationId: String? = nil,
        replyInstruction: String? = nil
    ) async -> IOSWatchQuestionStartResult {
        startDeferredGenerationNow()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_000 else {
            return .failure("请输入 1–2000 个字符")
        }
        guard !isStartingWatchQuestion else {
            return .failure("已有一条 Watch 请求正在启动")
        }
        guard autoGenerateResponses else {
            return .failure("iPhone 当前未启用自动回答")
        }
        guard let store = conversationStore else {
            return .failure("iPhone 聊天状态不可用")
        }
        guard !hasActiveChatGeneration,
              inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pendingImages.isEmpty,
              pendingSelectedFilePreview == nil,
              !isAttachingSelectedFile,
              !isRecognizingImages,
              !hasPendingUserGate else {
            return .failure("iPhone 当前有未完成的任务、草稿或附件")
        }
        if let issue = configurationIssue {
            return .failure(issue.message)
        }

        isStartingWatchQuestion = true
        defer { isStartingWatchQuestion = false }

        let targetConversationId: KotlinUuid
        if let requestedConversationId {
            guard let summary = await store.appIntentSummaries(limit: nil).first(where: {
                $0.id.toHexDashString().caseInsensitiveCompare(requestedConversationId) == .orderedSame
            }) else {
                return .failure("找不到这条对话")
            }
            targetConversationId = summary.id
            guard await store.selectConversationIfAvailable(id: targetConversationId) else {
                return .failure("无法打开这条对话")
            }
            reloadFromStore(reason: .conversationSwitch)
        } else {
            guard await store.newConversation() else {
                return .failure("无法新建对话")
            }
            reloadFromStore(reason: .conversationSwitch)
            guard let createdConversationId = currentConversationId else {
                return .failure("无法确定新对话")
            }
            targetConversationId = createdConversationId
        }

        // Selection is asynchronous. Recheck the target and all gates before
        // handing the text to the established sendMessage path.
        guard currentConversationId?.toHexDashString().caseInsensitiveCompare(
            targetConversationId.toHexDashString()
        ) == .orderedSame,
              !hasActiveChatGeneration,
              inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pendingImages.isEmpty,
              pendingSelectedFilePreview == nil,
              !isAttachingSelectedFile,
              !isRecognizingImages,
              !hasPendingUserGate else {
            return .failure("iPhone 状态已改变，请稍后重试")
        }

        inputText = Self.watchMessage(trimmed, replyInstruction: replyInstruction)
        guard sendMessage() else {
            return .failure(configurationError ?? selectedFileContextError ?? "iPhone 无法发送这条消息")
        }
        guard let runId = kernelRunHost.currentRunId else {
            return .failure("iPhone 无法启动这条任务")
        }
        return IOSWatchQuestionStartResult(
            conversationId: targetConversationId.toHexDashString(),
            runId: runId,
            failureMessage: nil
        )
    }

    func modifyGeneratedImage(sourceImageURL: String, prompt: String, aspectRatio: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = sourceImageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rejectMessageMutationIfNeeded(), !rejectVisionRecognitionMutationIfNeeded() else { return }
        guard !trimmedPrompt.isEmpty, !trimmedSource.isEmpty else { return }
        guard !isGenerationActive else {
            selectedFileContextError = IOSAppLocalization.string(
                "请等当前回复结束后再修改图片",
                defaultValue: "请等当前回复结束后再修改图片"
            )
            return
        }

        configurationError = nil
        let input = Self.imageEditToolInput(
            prompt: trimmedPrompt,
            sourceImageURL: trimmedSource,
            aspectRatio: aspectRatio
        )
        let params = makeTextGenerationParams()
        kernelRunHost.runImageTool(
            input: input,
            conversationId: currentConversationId,
            modelDisplayName: params.model.displayName
        )
    }

    /// Appends the user message (keeping image parts for in-bubble display) and persists it.
    /// Returns the input digest + conversation id so the caller can start generation.
    @discardableResult
    func appendUserMessage(
        text: String,
        images: [PendingChatImage],
        metadata: [String: Kotlinx_serialization_jsonJsonElement]? = nil,
        consumesComposer: Bool = true,
        persistsImmediately: Bool = true
    ) -> (digest: String, conversationId: KotlinUuid?, messageId: String) {
        currentRun.state.clearChildResultWait()
        let prompt = Self.promptText(userText: text, selectedFilePreview: consumesComposer ? pendingSelectedFilePreview : nil)
        let digest = chatInputDigest(for: prompt.isEmpty ? "[image]" : prompt)
        let userMsg = makeUserMessage(prompt: prompt, images: images, metadata: metadata)
        pendingAssistantRegeneration = nil
        // iMessage 式上屏:仅把这条用户消息的插入放进动画事务,驱动消息行的入场 transition。
        // 批量加载/切换会话走 `messages = store.currentMessages`(不在事务内),不会逐条动画。
        withAnimation(.spring(Self.userMessageSendSpring)) {
            messages.append(userMsg)
            bumpMessageRevision(reason: .userAppend)
        }
        invalidateSuggestionRequest()
        chatSuggestions = []
        if consumesComposer {
            inputText = ""
            pendingSelectedFilePreview = nil
            clearPendingImages()
            selectedFileContextError = nil
        }
        let runConversationId = currentConversationId
        // 用户消息立即落盘：即使随后生成崩溃/被杀进程，用户输入也不会丢。
        if persistsImmediately {
            Task { @MainActor [weak self] in
                _ = await self?.persistMessages(conversationId: runConversationId)
            }
        }
        return (digest, runConversationId, ChatMessageProjector.messageId(for: userMsg))
    }

    /// Sends the user message and kicks off generation. For non-vision models the image
    /// parts are recognized and replaced in upload preparation before the request
    /// leaves for the provider.
    private func sendUserMessage(
        text: String,
        images: [PendingChatImage],
        metadata: [String: Kotlinx_serialization_jsonJsonElement]? = nil,
        startsGenerationAfterInsertion: Bool = false
    ) {
        guard startsGenerationAfterInsertion, autoGenerateResponses else {
            let (digest, conversationId, _) = appendUserMessage(text: text, images: images, metadata: metadata)
            guard autoGenerateResponses else { return }
            generateResponse(inputDigest: digest, conversationId: conversationId, phoneControlUserInitiated: true)
            return
        }
        let token = UUID()
        let (digest, conversationId, _) = appendUserMessage(text: text, images: images, metadata: metadata)
        deferredGenerationStart = DeferredGenerationStart(
            token: token,
            run: currentRun,
            inputDigest: digest,
            conversationId: conversationId
        )
        // 停止键与思考占位仍在发送当帧出现，只有启动工作后移。
        isLoading = true
        // 以入场弹簧的视觉时长为准，而非动画完成回调：懒加载列表里的新行在事务
        // 结算后才布局，回调会在动画开始前就触发。token 保证只启动一次。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.userMessageSendSpring.duration))
            self?.startDeferredGeneration(token: token)
        }
    }

    /// 用户消息入场弹簧；生成启动也以它的视觉时长为界，二者不会脱节。


    /// 生成启动（参数与工具目录组装、Kernel、后台保活、记忆召回）在主线程上要
    /// 同步跑上百毫秒；与发送放在同一事件里会挡住用户气泡上屏并打断入场动画。
    /// composer 发送因此等入场动画落位再启动；需要 run 已存在的入口先补启动。

    private func startDeferredGeneration(token: UUID) {
        guard let pending = deferredGenerationStart, pending.token == token else { return }
        deferredGenerationStart = nil
        guard currentRun === pending.run else {
            // 动画期间已离开该会话：当前消息与配置不再属于它，不能代为启动。
            pending.run.state.isLoading = false
            NSLog("[ChatViewModel] deferred generation dropped after conversation switch")
            return
        }
        generateResponse(inputDigest: pending.inputDigest, conversationId: pending.conversationId, phoneControlUserInitiated: true)
    }

    /// 需要 run 已存在的入口（再次发送、停止、新建会话、Watch 提问）先立即启动。
    private func startDeferredGenerationNow() {
        guard let token = deferredGenerationStart?.token else { return }
        startDeferredGeneration(token: token)
    }

    // MARK: - Steer 队列（P1-a）

    /// 生成激活期间把 composer 内容入队（文本 / 图 / 选中文件）；队列满返回 false。
    /// 与 appendUserMessage 的输入收尾一致：清空输入框、建议与附件预览。
    @discardableResult
    func approvePendingMemoryTool() {
        kernelRunHost.approvePendingMemoryTool()
    }

    func denyPendingMemoryTool() {
        kernelRunHost.denyPendingMemoryTool()
    }

    func approvePendingSearchTool() {
        kernelRunHost.approvePendingSearchTool()
    }

    func denyPendingSearchTool() {
        kernelRunHost.denyPendingSearchTool()
    }

    func approvePendingWebMountTool(requestId: String) {
        kernelRunHost.approvePendingWebMountTool(requestId: requestId)
    }

    func denyPendingWebMountTool(requestId: String) {
        kernelRunHost.denyPendingWebMountTool(requestId: requestId)
    }

    func approvePendingWorkspaceTool() {
        kernelRunHost.approvePendingWorkspaceTool()
    }

    func denyPendingWorkspaceTool() {
        kernelRunHost.denyPendingWorkspaceTool()
    }

    func approvePendingIshHandoffTool(
        requestId: String,
        requestRunId: String?,
        scope: IshToolApprovalScope = .once
    ) {
        kernelRunHost.approvePendingIshHandoffTool(
            requestId: requestId,
            requestRunId: requestRunId,
            scope: scope
        )
    }

    func denyPendingIshHandoffTool(requestId: String, requestRunId: String?) {
        kernelRunHost.denyPendingIshHandoffTool(
            requestId: requestId,
            requestRunId: requestRunId
        )
    }

    func isShowingThemeTryOnApproval(_ approval: AmberThemeTryOnApproval) -> Bool {
        currentRun.host?.currentRunId == approval.runId
            && pendingMcpApproval?.id == approval.requestId
            && pendingMcpApproval?.toolName == "theme_pack_import"
    }

    @discardableResult
    func resolveThemeTryOnApproval(_ approval: AmberThemeTryOnApproval, allow: Bool) -> Bool {
        guard let run = runRegistry.allRuns.first(where: { $0.host?.currentRunId == approval.runId }),
              run.state.pendingMcpApproval?.id == approval.requestId,
              run.state.pendingMcpApproval?.toolName == "theme_pack_import",
              let host = run.host else { return false }
        return allow
            ? host.approvePendingMcpTool(requestId: approval.requestId)
            : host.denyPendingMcpTool(requestId: approval.requestId)
    }

    func approvePendingMcpTool(requestId: String) {
        kernelRunHost.approvePendingMcpTool(requestId: requestId)
    }

    func denyPendingMcpTool(requestId: String) {
        kernelRunHost.denyPendingMcpTool(requestId: requestId)
    }

    /// Wave B2: recipe 审批卡（mutation step / recipe_import）。
    func approvePendingRecipeTool(requestId: String) {
        kernelRunHost.approvePendingRecipeTool(requestId: requestId)
    }

    func denyPendingRecipeTool(requestId: String) {
        kernelRunHost.denyPendingRecipeTool(requestId: requestId)
    }

    func approvePendingCouncilTool() {
        kernelRunHost.approvePendingCouncilTool()
    }

    func denyPendingCouncilTool() {
        kernelRunHost.denyPendingCouncilTool()
    }

    @discardableResult
    func answerPendingAskUser(_ answer: String) -> Bool {
        kernelRunHost.answerPendingAskUser(answer)
    }

    @discardableResult
    func skipPendingAskUser() -> Bool {
        answerPendingAskUser("")
    }

    @discardableResult
    func resolvePendingToolApprovalFromWatch(
        runId: String,
        requestId: String,
        allow: Bool
    ) -> Bool {
        host(runId: runId)?.resolvePendingToolApprovalFromWatch(
            runId: runId,
            requestId: requestId,
            allow: allow
        ) ?? false
    }

    @discardableResult
    func submitWatchUserAnswer(
        runId: String,
        requestId: String,
        text: String
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return host(runId: runId)?.answerPendingAskUserFromWatch(
            runId: runId,
            requestId: requestId,
            answer: trimmed
        ) ?? false
    }

    func cancelGeneration() {
        startDeferredGenerationNow()
        currentRun.state.clearChildResultWait()
        // cancel() itself publishes the cancelled watch snapshot; do not clear first.
        if kernelRunHost.isRunning {
            kernelRunHost.cancel()
            return
        }
        guard let currentConversationId else { return }
        _ = IOSChatBackgroundGenerationCoordinator.shared.cancelActiveJob(
            conversationId: currentConversationId
        )
    }

    @discardableResult
    func cancelGeneration(runId: String) -> Bool {
        if host(runId: runId)?.cancel(runId: runId) == true {
            return true
        }
        return IOSChatBackgroundGenerationCoordinator.shared.cancelJob(runId: runId)
    }

    @discardableResult
    func handoffGenerationToBackgroundIfNeeded(honorKeepAliveLease: Bool = false) -> Bool {
        let hosts = runRegistry.allRuns.compactMap(\.host).filter(\.isRunning)
        var didHandoffAll = true
        for host in hosts {
            if !host.handoffCurrentGenerationToBackground(
                conversationStore: conversationStore,
                honorKeepAliveLease: honorKeepAliveLease
            ) {
                didHandoffAll = false
            }
        }
        return didHandoffAll
    }

    @discardableResult
    func prepareForConversationChange() -> Bool {
        prepareForConversationChange(to: nil)
    }

    /// The first user bubble is intentionally persisted asynchronously so it
    /// survives a process kill. If the user taps New Chat in that short window,
    /// the Store still sees an empty current document; force a new ID instead of
    /// reusing the conversation that already has a visible, unsaved message.
    @discardableResult
    func startNewConversation(commitIf: () -> Bool = { true }) async -> Bool {
        guard let store = conversationStore, commitIf() else { return false }
        startDeferredGenerationNow()
        guard !store.isImportingConversationDocuments else {
            store.publishUserVisibleError(IOSUserVisibleError(
                title: "暂时无法新建对话",
                message: "正在恢复会话，请等待完成后再试。",
                severity: .warning
            ))
            return false
        }
        let sourceConversationId = currentConversationId
        let mustCreateNewConversation = sourceConversationId == store.currentConversation?.id &&
            !messages.isEmpty && store.currentMessages.isEmpty
        guard prepareForConversationChange() else { return false }
        if mustCreateNewConversation {
            return await store.newConversation(commitIf: {
                commitIf() && self.currentConversationId == sourceConversationId
            })
        }
        return await store.startNewConversationReusingEmpty(commitIf: {
            commitIf() && self.currentConversationId == sourceConversationId
        })
    }

    // MARK: - Message branching actions (Android ChatService parity)
    //
    // These operate on the Conversation tree via IOSConversationStore. After
    // mutating the tree they re-sync `self.messages` (the flat currentMessages
    // projection) so the chat list reflects the new branch, then re-run
    // generation for regenerate. Mirrors Android ChatService.regenerateAtMessage
    // / editMessage.

    /// Regenerate the assistant reply that follows a given message index.
    /// - If the target is a USER message: drop everything after it and re-run
    ///   generation (Android's USER-regenerate path).
    /// - If the target is an ASSISTANT message: drop it + everything after, then
    ///   re-run from the preceding user turn (produces a fresh variant; the old
    ///   reply is replaced in this minimal implementation — full variant
    ///   retention is surfaced via selectVariant for nodes that already have
    ///   multiple siblings).
    func regenerate(atMessageIndex index: Int) {
        guard !rejectMessageMutationIfNeeded(), !rejectIntelligentUISubmissionMutationIfNeeded(), !rejectVisionRecognitionMutationIfNeeded(), !isGenerationActive,
              !currentConversationIsOrchestratedChild,
              let store = conversationStore,
              let conversation = store.currentConversation,
              index >= 0, index < conversation.messageNodes.count else {
            return
        }
        let state = currentRun.state
        Task { @MainActor [weak self] in
            _ = await self?.regenerateImmediately(
                atMessageIndex: index,
                conversation: conversation,
                state: state
            )
        }
    }

    @discardableResult
    func regenerateImmediately(
        atMessageIndex index: Int,
        conversation: Conversation,
        state: ChatConversationRunState
    ) async -> Bool {
        guard let store = conversationStore,
              index >= 0, index < conversation.messageNodes.count else {
            return false
        }

        let conversationId = conversation.id
        let targetNode = conversation.messageNodes[index]
        if targetNode.role == MessageRole.user {
            let needsTruncation = index + 1 < conversation.messageNodes.count
            let didTruncate = await store.truncateAfter(
                messageIndex: index,
                conversationId: conversationId
            )
            guard !needsTruncation || didTruncate,
                  applyPersistedBranchIfCurrent(
                      conversationId: conversationId,
                      state: state,
                      store: store
                  ) else {
                return false
            }
            state.pendingAssistantRegeneration = nil
            let digest = chatInputDigest(for: regenerateDigestSeed())
            generateResponse(inputDigest: digest, conversationId: conversationId, phoneControlUserInitiated: true)
        } else {
            // A regenerated assistant reply has no immediate storage mutation.
            // Do not start an invisible run after a user switched to another chat.
            guard isCurrentConversation(conversationId) else { return false }
            // Keep the original assistant node; the new answer is appended as a variant.
            let nodes = Array(conversation.messageNodes.prefix(index))
            guard let precedingUser = nodes.lastIndex(where: { $0.role == MessageRole.user }) else {
                return false
            }
            let uploadMessages = Array(conversation.currentMessages.prefix(precedingUser + 1))
            state.pendingAssistantRegeneration = PendingAssistantRegeneration(
                conversationId: conversation.id,
                targetMessageIndex: index,
                generatedMessageIndex: uploadMessages.count
            )
            state.messages = uploadMessages
            bumpMessageRevision(reason: .branchChange)
            let digest = chatInputDigest(for: regenerateDigestSeed())
            generateResponse(inputDigest: digest, conversationId: conversation.id, phoneControlUserInitiated: true)
        }
        let didStart = host(for: conversationId)?.isRunning == true
        if !didStart {
            state.pendingAssistantRegeneration = nil
            if targetNode.role != MessageRole.user,
               isCurrentConversation(conversationId) {
                state.messages = conversation.currentMessages
                bumpMessageRevision(reason: .branchChange)
            }
        }
        return didStart
    }

    /// Edit a user message in place and re-run generation from it. The edited
    /// text replaces the selected variant; the conversation is truncated after
    /// the edited user turn (Android's editMessage = append-variant + re-run).
    func editMessage(atMessageIndex index: Int, newText: String) {
        guard !rejectMessageMutationIfNeeded(), !rejectIntelligentUISubmissionMutationIfNeeded(), !rejectVisionRecognitionMutationIfNeeded(), !isGenerationActive,
              !currentConversationIsOrchestratedChild else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let store = conversationStore,
              let conversation = store.currentConversation,
              index >= 0, index < conversation.messageNodes.count else { return }

        let node = conversation.messageNodes[index]
        guard node.role == MessageRole.user else { return }

        let original = store.currentMessages.indices.contains(index)
            ? store.currentMessages[index]
            : node.messages[Int(node.selectIndex)]
        let edited = Self.editedUserMessage(original: original, newText: trimmed)
        let conversationId = conversation.id
        let state = currentRun.state
        Task { @MainActor [weak self] in
            guard let self else { return }
            let saved = await store.appendVariantAndTruncateAfter(
                messageIndex: index,
                message: edited,
                conversationId: conversationId
            )
            guard saved,
                  self.applyPersistedBranchIfCurrent(
                      conversationId: conversationId,
                      state: state,
                      store: store
                  ) else { return }
            state.pendingAssistantRegeneration = nil
            let digest = chatInputDigest(for: trimmed)
            self.generateResponse(inputDigest: digest, conversationId: conversationId, phoneControlUserInitiated: true)
        }
    }

    /// Delete a single message (and its node). No generation.
    func deleteMessage(atMessageIndex index: Int) {
        guard !rejectMessageMutationIfNeeded(), !rejectIntelligentUISubmissionMutationIfNeeded(), !rejectVisionRecognitionMutationIfNeeded(), !isGenerationActive,
              !currentConversationIsOrchestratedChild,
              let store = conversationStore,
              let conversation = store.currentConversation,
              index >= 0, index < conversation.messageNodes.count else { return }
        let conversationId = conversation.id
        let state = currentRun.state
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deleted = await store.deleteMessage(
                messageIndex: index,
                conversationId: conversationId
            )
            guard deleted else { return }
            _ = self.applyPersistedBranchIfCurrent(
                conversationId: conversationId,
                state: state,
                store: store
            )
        }
    }

    /// Switch the visible variant of a node (no generation).
    func selectVariant(messageIndex: Int, variantIndex: Int) {
        guard !rejectMessageMutationIfNeeded(), !rejectIntelligentUISubmissionMutationIfNeeded(), !rejectVisionRecognitionMutationIfNeeded(), !isGenerationActive,
              !currentConversationIsOrchestratedChild,
              let store = conversationStore,
              let conversation = store.currentConversation,
              messageIndex >= 0, messageIndex < conversation.messageNodes.count else { return }
        let conversationId = conversation.id
        let state = currentRun.state
        Task { @MainActor [weak self] in
            guard let self else { return }
            let selected = await store.selectVariant(
                messageIndex: messageIndex,
                variantIndex: variantIndex,
                conversationId: conversationId
            )
            guard selected else { return }
            _ = self.applyPersistedBranchIfCurrent(
                conversationId: conversationId,
                state: state,
                store: store
            )
        }
    }

    /// Branch persistence may complete after the user has selected another
    /// conversation. Keep that write in its owner document, but never replace
    /// the visible timeline or start generation for the newly selected chat.
    @discardableResult
    private func applyPersistedBranchIfCurrent(
        conversationId: KotlinUuid,
        state: ChatConversationRunState,
        store: IOSConversationStore
    ) -> Bool {
        guard state.conversationId == conversationId,
              isCurrentConversation(conversationId),
              store.currentConversation?.id == conversationId else {
            return false
        }
        state.messages = store.currentMessages
        refreshIntelligentUIReceipts(messages: state.messages, conversationID: conversationId.toHexDashString())
        bumpMessageRevision(reason: .branchChange)
        return true
    }

    /// Variant info for the UI (to render `< n/m >` when a node has siblings).
    func variantInfo(atMessageIndex index: Int) -> IOSConversationStore.VariantInfo? {
        conversationStore?.variantInfo(forMessageIndex: index)
    }

    func messageIndex(forMessageId messageId: String) -> Int? {
        messages.firstIndex { ChatMessageProjector.messageId(for: $0) == messageId }
    }

    func regenerate(messageId: String) {
        guard let index = messageIndex(forMessageId: messageId) else { return }
        regenerate(atMessageIndex: index)
    }

    func editMessage(messageId: String, newText: String) {
        guard let index = messageIndex(forMessageId: messageId) else { return }
        editMessage(atMessageIndex: index, newText: newText)
    }

    func deleteMessage(messageId: String) {
        guard let index = messageIndex(forMessageId: messageId) else { return }
        deleteMessage(atMessageIndex: index)
    }

    func selectVariant(messageId: String, variantIndex: Int) {
        guard let index = messageIndex(forMessageId: messageId) else { return }
        selectVariant(messageIndex: index, variantIndex: variantIndex)
    }

#if DEBUG
    func generateResponseForTesting(inputDigest: String, conversationId: KotlinUuid?) {
        generateResponse(inputDigest: inputDigest, conversationId: conversationId)
    }

    /// 工具循环边界的 VM 队列语义：mailbox 先于 steer。
    func nextRoundMessagesAfterMailboxAndSteerConsumptionForTesting(
        baseMessages: [UIMessage]
    ) async -> [UIMessage] {
        let mailboxMessages = await drainMailbox(conversationId: currentConversationId)
        let steerMessages = await drainSteerQueue(conversationId: currentConversationId)
        return baseMessages + mailboxMessages + steerMessages
    }

    func drainMailboxAtNewRunHeadForTesting(
        conversationId: KotlinUuid?,
        displayMessagesOverride: [UIMessage]?
    ) async -> [UIMessage] {
        guard displayMessagesOverride == nil else { return [] }
        return await drainMailbox(conversationId: conversationId)
    }

    func shouldApplyVisionRecognitionResultForTesting(
        conversationId: KotlinUuid?,
        userMessageId: String
    ) -> Bool {
        shouldApplyVisionRecognitionResult(conversationId: conversationId, userMessageId: userMessageId)
    }

    func applyVisionRecognitionFailureForTesting(
        message: String,
        conversationId: KotlinUuid?,
        userMessageId: String
    ) async {
        await applyVisionRecognitionFailure(
            message: message,
            conversationId: conversationId,
            userMessageId: userMessageId
        )
    }

    func applyVisionRecognitionSuccessForTesting(
        conversationId: KotlinUuid?,
        userMessageId: String
    ) {
        guard shouldApplyVisionRecognitionResult(conversationId: conversationId, userMessageId: userMessageId) else { return }
        clearVisionRecognitionPendingPrompt()
    }
#endif

    private func regenerateDigestSeed() -> String {
        messages.last(where: { $0.role == MessageRole.user })?.toText() ?? ""
    }

    // MARK: - Private

}
