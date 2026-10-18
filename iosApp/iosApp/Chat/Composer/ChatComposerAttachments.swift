import Foundation
import CryptoKit
import Observation
import OSLog
import SwiftUI
@preconcurrency import Shared

extension ChatViewModel {

    /// OCR fallback: the user message (with its image) is shown in the chat immediately;
    /// a recognition indicator runs on the user side while the vision model reads each
    /// image, then the main model responds. On failure the message stays and an error shows.
    func startVisionFallbackAndSend(
        text: String, images: [PendingChatImage], metadata: [String: Kotlinx_serialization_jsonJsonElement]? = nil
    ) {
        let (digest, conversationId, userMessageId) = appendUserMessage(text: text, images: images, metadata: metadata)
        guard autoGenerateResponses else { return }
        let requestId = UUID()
        attachmentOperations.visionRequestId = requestId
        attachmentOperations.visionConversationId = conversationId
        isRecognizingImages = true
        visionRecognitionImageCount = images.count
        let snapshot = sharedSettings.snapshot
        attachmentOperations.visionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.performVisionRecognition(
                imageURLs: images.map(\.dataUrl),
                settings: snapshot,
                conversationId: conversationId
            )
            guard self.attachmentOperations.visionRequestId == requestId else { return }
            self.clearVisionRecognitionOperation()
            self.clearVisionRecognitionPendingPrompt()
            switch result {
            case .failure(let error):
                await self.applyVisionRecognitionFailure(
                    message: error.message,
                    conversationId: conversationId,
                    userMessageId: userMessageId
                )
            case .success(let texts):
                guard self.shouldApplyVisionRecognitionResult(
                    conversationId: conversationId,
                    userMessageId: userMessageId
                ) else { return }
                self.cacheVisionRecognitionTexts(texts)
                self.generateResponse(inputDigest: digest, conversationId: conversationId, phoneControlUserInitiated: true)
            }
        }
    }

    func cancelVisionRecognitionForConversationChange() {
        guard attachmentOperations.visionRequestId != nil else { return }
        let ownerConversationId = attachmentOperations.visionConversationId
        let ownerMessages = messages
        attachmentOperations.visionTask?.cancel()
        clearVisionRecognitionOperation()
        guard let ownerConversationId, let conversationStore else { return }
        let notice = Self.visionRecognitionFailureMessage(
            IOSAppLocalization.string(
                "图片识别已取消，请重新发送图片",
                defaultValue: "图片识别已取消，请重新发送图片"
            )
        )
        Task { @MainActor in
            _ = await conversationStore.saveBackgroundCompletion(
                baseMessages: ownerMessages,
                completedMessages: ownerMessages + [notice],
                to: ownerConversationId
            )
        }
    }

    func cancelVisionRecognition() {
        guard attachmentOperations.visionRequestId != nil else { return }
        attachmentOperations.visionTask?.cancel()
        clearVisionRecognitionOperation()
        clearVisionRecognitionPendingPrompt()
        selectedFileContextError = IOSAppLocalization.string(
            "图片识别已取消，请重新发送图片",
            defaultValue: "图片识别已取消，请重新发送图片"
        )
    }

    private func clearVisionRecognitionOperation() {
        attachmentOperations.visionTask = nil
        attachmentOperations.visionRequestId = nil
        attachmentOperations.visionConversationId = nil
        isRecognizingImages = false
        visionRecognitionImageCount = 0
    }

    func shouldApplyVisionRecognitionResult(
        conversationId: KotlinUuid?,
        userMessageId: String
    ) -> Bool {
        let sameConversation: Bool
        if let conversationId {
            sameConversation = currentConversationId.map { String(describing: $0) } == String(describing: conversationId)
        } else {
            sameConversation = currentConversationId == nil
        }
        guard sameConversation else { return false }
        guard currentConversationContainsMessage(id: userMessageId) else { return false }
        if let conversationId {
            return !isGenerationActive(conversationId: conversationId)
        }
        return !isGenerationActive
    }

    func applyVisionRecognitionFailure(
        message: String,
        conversationId: KotlinUuid?,
        userMessageId: String
    ) async {
        guard shouldApplyVisionRecognitionResult(conversationId: conversationId, userMessageId: userMessageId) else {
            if !isCurrentConversation(conversationId),
               let conversationId,
               let conversationStore,
               var ownerMessages = await conversationStore.messages(for: conversationId),
               ownerMessages.contains(where: {
                   ChatMessageProjector.messageId(for: $0) == userMessageId
               }) {
                ownerMessages.append(Self.visionRecognitionFailureMessage(message))
                _ = await conversationStore.save(messages: ownerMessages, to: conversationId)
            }
            return
        }
        selectedFileContextError = message
    }

    func isCurrentConversation(_ conversationId: KotlinUuid?) -> Bool {
        if let conversationId {
            return currentConversationId.map { String(describing: $0) } == String(describing: conversationId)
        }
        return currentConversationId == nil
    }

    private static func visionRecognitionFailureMessage(_ text: String) -> UIMessage {
        let seed = UIMessage.companion.assistant(prompt: "")
        return UIMessage(
            id: seed.id,
            role: seed.role,
            parts: [MessageKt.localGenerationErrorTextPart(text: text)],
            annotations: seed.annotations,
            createdAt: seed.createdAt,
            finishedAt: seed.finishedAt,
            modelId: seed.modelId,
            usage: seed.usage,
            translation: seed.translation
        )
    }

    func clearVisionRecognitionPendingPrompt() {
        if selectedFileContextError == Self.visionRecognitionPendingMessage {
            selectedFileContextError = nil
        }
    }

    private func currentConversationContainsMessage(id messageId: String) -> Bool {
        if messages.contains(where: { ChatMessageProjector.messageId(for: $0) == messageId }) {
            return true
        }
        guard let currentMessages = conversationStore?.currentConversation?.currentMessages else {
            return false
        }
        return currentMessages.contains(where: { ChatMessageProjector.messageId(for: $0) == messageId })
    }

    @discardableResult
    func rejectVisionRecognitionMutationIfNeeded() -> Bool {
        guard isRecognizingImages else { return false }
        selectedFileContextError = Self.visionRecognitionPendingMessage
        return true
    }

    struct VisionRecognitionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Calls the configured vision model once per image and returns the wrapped
    /// recognition text keyed by the image's `data:` URL (Android OcrTransformer parity).
    func performVisionRecognition(
        imageURLs: [String],
        settings snapshot: Settings,
        conversationId: KotlinUuid?
    ) async -> Result<[String: String], VisionRecognitionError> {
        var results: [String: String] = [:]
        for url in imageURLs {
            results[url] = cachedVisionRecognitionText(for: url)
        }
        let missingURLs = imageURLs.filter { results[$0] == nil }
        guard !missingURLs.isEmpty else { return .success(results) }
        guard let visionModel = snapshot.findModelById(uuid: snapshot.ocrModelId) else {
            return .failure(VisionRecognitionError(message: IOSAppLocalization.string(
                "请先在「默认模型 → 辅助任务」配置视觉识别模型",
                defaultValue: "请先在「默认模型 → 辅助任务」配置视觉识别模型"
            )))
        }
        guard let providerSetting = ChatProviderConfiguration.provider(
            for: visionModel,
            providers: snapshot.providers
        ), ChatProviderConfiguration.issue(for: visionModel, provider: providerSetting) == nil else {
            return .failure(VisionRecognitionError(message: IOSAppLocalization.string(
                "视觉识别模型的服务商不可用",
                defaultValue: "视觉识别模型的服务商不可用"
            )))
        }
        let prompt = OcrPromptKt.resolveVisionRecognitionPrompt(prompt: snapshot.ocrPrompt)
        let assistant = snapshot.getCurrentAssistant()
        let params = Self.makeAuxiliaryTextGenerationParams(
            model: visionModel,
            assistantHeaders: ChatProviderConfiguration.requestHeaders(
                for: providerSetting,
                assistant: assistant.customHeaders,
                model: visionModel.customHeaders,
                conversationId: conversationId?.toHexDashString()
            ),
            assistantBodies: assistant.customBodies
        )
        for url in missingURLs {
            if results[url] != nil { continue }
            let requestMessages = [
                UIMessage.companion.system(prompt: prompt),
                makeImageOnlyUserMessage(dataUrl: url)
            ]
            do {
                try Task.checkCancellation()
                let chunk = try await auxiliaryTextProvider.generateText(
                    providerSetting: providerSetting,
                    messages: requestMessages,
                    params: params
                )
                let text = chunk.choices.first?.message?.toText()
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else {
                    return .failure(VisionRecognitionError(message: IOSAppLocalization.string(
                        "视觉识别模型没有返回可用内容",
                        defaultValue: "视觉识别模型没有返回可用内容"
                    )))
                }
                results[url] = """
                <image_context>
                \(text)
                </image_context>
                * 以上 image_context 是对用户上传图片的视觉识别结果，不是用户的提问。
                * 若用户要根据这张附图做风格转换、改图或垫图生图，调用 generate_image 时必须设置 use_attached_image=true；宿主会注入原图像素，不要只根据文字描述重画。
                """
            } catch {
                return .failure(VisionRecognitionError(message: IOSAppLocalization.formatted(
                    "视觉识别失败：%@",
                    defaultValue: "视觉识别失败：%@",
                    arguments: [(error as NSError).localizedDescription]
                )))
            }
        }
        return .success(results)
    }

    private func makeImageOnlyUserMessage(dataUrl: String) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.user,
            parts: [UIMessagePart.Image(url: dataUrl, metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    /// Builds the user message: a plain text message when there are no images, or a
    /// multi-part message (text + `UIMessagePart.Image`) the KMP providers turn into
    /// real image blocks. Image URLs are self-contained `data:` URLs.
    func makeUserMessage(
        prompt: String, images: [PendingChatImage],
        metadata: [String: Kotlinx_serialization_jsonJsonElement]? = nil
    ) -> UIMessage {
        guard !images.isEmpty || metadata != nil else {
            return UIMessage.companion.user(prompt: prompt)
        }
        var parts: [UIMessagePart] = []
        if !prompt.isEmpty {
            parts.append(IosToolOutputJsonBridge.shared.textPart(text: prompt, metadata: metadata))
        }
        for image in images {
            parts.append(UIMessagePart.Image(url: image.dataUrl, metadata: nil))
        }
        return UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.user,
            parts: parts,
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    static func editedUserMessage(original: UIMessage, newText: String) -> UIMessage {
        var parts: [UIMessagePart] = []
        var didInsertText = false
        for part in original.parts {
            if part is UIMessagePart.Text {
                if !didInsertText {
                    parts.append(UIMessagePart.Text(text: newText, metadata: nil))
                    didInsertText = true
                }
                continue
            }
            parts.append(part)
        }
        if !didInsertText {
            parts.insert(UIMessagePart.Text(text: newText, metadata: nil), at: 0)
        }
        return UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.user,
            parts: parts,
            annotations: original.annotations,
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

#if DEBUG
    static func editedUserMessageForTesting(original: UIMessage, newText: String) -> UIMessage {
        editedUserMessage(original: original, newText: newText)
    }
#endif

    func attachSelectedFilePreviewToNextMessage(
        expectedConversationId: String? = nil,
        expectedFileScopeDigest: String? = nil
    ) async {
        guard expectedConversationId == nil || expectedConversationId == currentConversationId.map({
            String(describing: $0)
        }) else { return }
        guard !isAttachingSelectedFile else { return }
        guard let localToolExecutor else {
            selectedFileContextError = IOSAppLocalization.string(
                "Local iOS tool executor is unavailable.",
                defaultValue: "Local iOS tool executor is unavailable."
            )
            return
        }

        let request = localToolExecutor.requestForCurrentSelectedFile(isUserInitiated: true)
        guard expectedFileScopeDigest == nil || expectedFileScopeDigest == request.scopeDigest else {
            selectedFileContextError = "所选文件已更改，请重新选择要附加的文件。"
            return
        }

        let requestId = UUID()
        attachmentOperations.selectedFileRequestId = requestId
        isAttachingSelectedFile = true
        let activityRunId = "tool-\(requestId.uuidString)"
        startLiveActivity(
            runId: activityRunId,
            conversationId: currentConversationId,
            presentation: .readingSelectedFile,
            publishToWatch: false
        )
        defer {
            if attachmentOperations.selectedFileRequestId == requestId {
                isAttachingSelectedFile = false
                attachmentOperations.selectedFileRequestId = nil
            }
        }

        let output = await localToolExecutor.execute(request)
        guard attachmentOperations.selectedFileRequestId == requestId,
              expectedConversationId == nil || expectedConversationId == currentConversationId.map({
                  String(describing: $0)
              }) else { return }
        switch output {
        case .selectedFilePreview(let result):
            pendingSelectedFilePreview = result
            selectedFileContextError = nil
            await liveActivityController.end(
                runId: activityRunId,
                presentation: .selectedFileReadCompleted,
                dismissalDelay: 4
            )
        case .needsUserAction(let reason):
            selectedFileContextError = reason
            await liveActivityController.end(
                runId: activityRunId,
                presentation: .selectedFileReadFailed,
                dismissalDelay: 6
            )
        case .denied(let reason):
            selectedFileContextError = reason
            await liveActivityController.end(
                runId: activityRunId,
                presentation: .selectedFileReadFailed,
                dismissalDelay: 6
            )
        case .failed(let message):
            selectedFileContextError = message
            await liveActivityController.end(
                runId: activityRunId,
                presentation: .selectedFileReadFailed,
                dismissalDelay: 6
            )
        case .permissionsStatus:
            selectedFileContextError = IOSAppLocalization.string(
                "permissions_status cannot be attached to a chat message.",
                defaultValue: "permissions_status cannot be attached to a chat message."
            )
            await liveActivityController.end(
                runId: activityRunId,
                presentation: .selectedFileReadFailed,
                dismissalDelay: 6
            )
        case .webMountResult:
            selectedFileContextError = IOSAppLocalization.string(
                "WebMount tool output cannot be attached to a chat message.",
                defaultValue: "WebMount tool output cannot be attached to a chat message."
            )
            await liveActivityController.end(
                runId: activityRunId,
                presentation: .selectedFileReadFailed,
                dismissalDelay: 6
            )
        case .workspaceResult:
            selectedFileContextError = IOSAppLocalization.string(
                "Workspace tool output cannot be attached to a chat message.",
                defaultValue: "Workspace tool output cannot be attached to a chat message."
            )
            await liveActivityController.end(
                runId: activityRunId,
                presentation: .selectedFileReadFailed,
                dismissalDelay: 6
            )
        case .terminalResult, .ishExecuteResult, .ishHandoffResult:
            selectedFileContextError = IOSAppLocalization.string(
                "Terminal tool output cannot be attached to a chat message.",
                defaultValue: "Terminal tool output cannot be attached to a chat message."
            )
            await liveActivityController.end(
                runId: activityRunId,
                presentation: .selectedFileReadFailed,
                dismissalDelay: 6
            )
        }
    }

    func clearPendingSelectedFilePreview() {
        pendingSelectedFilePreview = nil
        selectedFileContextError = nil
    }

    // MARK: - Image attachments



    struct PendingChatImage: Identifiable, Equatable {
        let id = UUID()
        /// `data:<mime>;base64,...` — self-contained so it survives persistence and regeneration.
        let dataUrl: String
        /// Small JPEG bytes used only to render the composer thumbnail.
        let previewData: Data
    }

    enum ImageAttachmentState: Equatable {
        case none
        /// The current chat model accepts image input — send the image directly.
        case ready
        /// The current model is text-only but a vision model is configured — the image
        /// is recognized into text by the vision model first, then sent to the current model.
        case fallback
        case blocked(String)
    }

    private func cachedVisionRecognitionText(for dataUrl: String) -> String? {
        attachmentOperations.cachedVisionRecognitionText(for: dataUrl)
    }

    func cacheVisionRecognitionTexts(_ texts: [String: String]) {
        attachmentOperations.cacheVisionRecognitionTexts(texts)
    }

#if DEBUG
    static func visionRecognitionCacheKeyForTesting(_ dataUrl: String) -> String {
        ChatAttachmentOperationOwner.visionRecognitionCacheKey(for: dataUrl)
    }
#endif

    func addPendingImage(dataUrl: String, previewData: Data) {
        guard pendingImages.count < Self.maxImagesPerMessage else {
            selectedFileContextError = IOSAppLocalization.formatted(
                "一次最多发送 %lld 张图片",
                defaultValue: "一次最多发送 %lld 张图片",
                arguments: [Int64(Self.maxImagesPerMessage)]
            )
            return
        }
        pendingImages.append(PendingChatImage(dataUrl: dataUrl, previewData: previewData))
        selectedFileContextError = nil
    }

    func removePendingImage(_ id: PendingChatImage.ID) {
        pendingImages.removeAll { $0.id == id }
    }

    func clearPendingImages() {
        pendingImages.removeAll()
    }

    /// Mirrors Android `ImageAttachmentValidator`: the current model having image input
    /// means the image is ready to send; otherwise a configured vision model is required,
    /// and failing that the send is blocked with a prompt (never silently dropped).
    var imageAttachmentState: ImageAttachmentState {
        guard !pendingImages.isEmpty else { return .none }
        if pendingImages.count > Self.maxImagesPerMessage {
            return .blocked(IOSAppLocalization.formatted(
                "一次最多发送 %lld 张图片",
                defaultValue: "一次最多发送 %lld 张图片",
                arguments: [Int64(Self.maxImagesPerMessage)]
            ))
        }
        let snapshot = sharedSettings.snapshot
        guard let model = snapshot.getCurrentChatModel() else {
            return .blocked(IOSAppLocalization.string("请先选择模型", defaultValue: "请先选择模型"))
        }
        if Self.modelSupportsImageInput(model) { return .ready }
        // The user explicitly configured a vision model for this purpose — trust it
        // (capability metadata isn't reliably known for every model id), only requiring
        // that it resolves and has a usable provider.
        if let vision = snapshot.findModelById(uuid: snapshot.ocrModelId),
           let provider = ChatProviderConfiguration.provider(for: vision, providers: snapshot.providers),
           ChatProviderConfiguration.issue(for: vision, provider: provider) == nil {
            return .fallback
        }
        return .blocked(IOSAppLocalization.string(
            "当前模型不支持图片，请先在「默认模型 → 辅助任务」配置视觉识别模型",
            defaultValue: "当前模型不支持图片，请先在「默认模型 → 辅助任务」配置视觉识别模型"
        ))
    }

    static func modelSupportsImageInput(_ model: Model) -> Bool {
        let modalities = model.inputModalities.isEmpty
            ? (ModelRegistry.shared.MODEL_INPUT_MODALITIES.getData(modelId: model.modelId) as? [Modality] ?? [])
            : model.inputModalities
        return modalities.contains { $0.name == "IMAGE" }
    }

    // MARK: - 审批入口

}
