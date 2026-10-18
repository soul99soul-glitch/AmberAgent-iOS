import XCTest
import WebKit
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatComposerVisionContextTests: ChatViewModelContextTestCase {

    func testThemeGenerationPreservesDraftAndCanRetryAfterComposerIsCleared() {
        let viewModel = ChatViewModel(settingsStore: SettingsStore(), autoGenerateResponses: false)
        viewModel.inputText = "未发送的草稿"
        XCTAssertNotNil(viewModel.prepareForThemeGeneration())
        XCTAssertEqual(viewModel.inputText, "未发送的草稿")

        viewModel.inputText = ""
        let image = ChatViewModel.PendingChatImage(
            dataUrl: "data:image/png;base64,QUJD", previewData: Data("preview".utf8)
        )
        viewModel.pendingImages = [image]
        XCTAssertNotNil(viewModel.prepareForThemeGeneration())
        XCTAssertEqual(viewModel.pendingImages.first?.id, image.id)

        viewModel.pendingImages = []
        viewModel.isAttachingSelectedFile = true
        XCTAssertNotNil(viewModel.prepareForThemeGeneration())
        XCTAssertTrue(viewModel.isAttachingSelectedFile)
        viewModel.isAttachingSelectedFile = false
        viewModel.isRecognizingImages = true
        XCTAssertNotNil(viewModel.prepareForThemeGeneration())
        XCTAssertTrue(viewModel.isRecognizingImages)
        viewModel.isRecognizingImages = false
        XCTAssertNil(viewModel.prepareForThemeGeneration())
    }

    func testComposerAllowsImageOnlyDraft() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        viewModel.pendingImages = [
            ChatViewModel.PendingChatImage(
                dataUrl: "data:image/png;base64,QUJD",
                previewData: Data("preview".utf8)
            )
        ]

        XCTAssertNil(viewModel.composerSendBlockReason(for: "   "))
    }

    func testComposerBlocksSendWhileVisionRecognitionIsRunning() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        viewModel.inputText = "do not append yet"
        viewModel.isRecognizingImages = true

        XCTAssertEqual(viewModel.composerSendBlockReason(for: viewModel.inputText), .recognizingImages)

        viewModel.sendMessage()

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.inputText, "do not append yet")
    }

    func testSuggestionFillsDraftWithoutSendingAndRejectsLateSuggestions() {
        let viewModel = ChatViewModel(settingsStore: SettingsStore(), autoGenerateResponses: false)
        let token = viewModel.beginSuggestionRequestForTesting()
        viewModel.chatSuggestions = ["继续讲解", "给个例子"]
        viewModel.inputText = "旧草稿"

        viewModel.fillInputFromSuggestion("给个例子")

        XCTAssertEqual(viewModel.inputText, "给个例子")
        XCTAssertTrue(viewModel.chatSuggestions.isEmpty)
        XCTAssertTrue(viewModel.messages.isEmpty, "选择建议不应创建消息或自动发送")
        XCTAssertFalse(viewModel.isGenerationActive)
        viewModel.applySuggestionsForTesting(["迟到建议"], requestToken: token, conversationId: nil)
        XCTAssertTrue(viewModel.chatSuggestions.isEmpty)
        XCTAssertEqual(viewModel.inputText, "给个例子")
    }

    func testOlderSuggestionRequestCannotOverwriteNewerResult() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        let older = viewModel.beginSuggestionRequestForTesting()
        let newer = viewModel.beginSuggestionRequestForTesting()

        viewModel.applySuggestionsForTesting(
            ["stale suggestion"],
            requestToken: older,
            conversationId: nil
        )
        XCTAssertTrue(viewModel.chatSuggestions.isEmpty)

        viewModel.applySuggestionsForTesting(
            ["current suggestion"],
            requestToken: newer,
            conversationId: nil
        )
        XCTAssertEqual(viewModel.chatSuggestions, ["current suggestion"])
    }

    func testConversationChangeClearsUnsavedTextAndImages() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        viewModel.inputText = "draft from previous conversation"
        viewModel.configurationError = "previous conversation configuration error"
        viewModel.pendingImages = [
            ChatViewModel.PendingChatImage(
                dataUrl: "data:image/png;base64,QUJD",
                previewData: Data("preview".utf8)
            )
        ]

        XCTAssertTrue(viewModel.prepareForConversationChange(to: nil))

        XCTAssertTrue(viewModel.inputText.isEmpty)
        XCTAssertTrue(viewModel.pendingImages.isEmpty)
        XCTAssertNil(viewModel.configurationError)
    }

    func testStopCancelsRealVisionRecognitionAndRejectsLateResult() async throws {
        let provider = BlockingVisionProvider()
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: visionFallbackSettings(),
            autoGenerateResponses: true,
            auxiliaryTextProvider: provider
        )
        viewModel.inputText = "read this image"
        viewModel.addPendingImage(
            dataUrl: "data:image/png;base64,QUJD",
            previewData: Data("preview".utf8)
        )

        XCTAssertTrue(viewModel.sendMessage())
        for _ in 0..<100 where !provider.hasStarted {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(provider.hasStarted)
        XCTAssertTrue(viewModel.isRecognizingImages)

        viewModel.cancelVisionRecognition()

        XCTAssertTrue(provider.wasCancelled)
        XCTAssertFalse(viewModel.isRecognizingImages)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.selectedFileContextError, "图片识别已取消，请重新发送图片")
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(
            viewModel.messages[0].parts.compactMap { ($0 as? UIMessagePart.Image)?.url },
            ["data:image/png;base64,QUJD"]
        )

        provider.finish(text: "late OCR result")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.messages.count, 1)
    }

    func testSendWithoutPendingPreviewKeepsUserTextPlain() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        viewModel.inputText = "Hello"

        viewModel.sendMessage()

        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(textContent(of: viewModel.messages[0]), "Hello")
        XCTAssertNil(viewModel.pendingSelectedFilePreview)
    }

    func testSendMessageIsQueuedWhenBackgroundGenerationIsActiveForCurrentConversation() {
        // P1-a 契约：生成激活期间发送 = 入队（不直接上屏、文本清空、返回 true），
        // 在工具循环边界折入下一轮。旧契约"生成中拒绝发送"已被 steer 队列取代。
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "should queue while background generation is active"

        XCTAssertTrue(viewModel.sendMessage())

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.inputText, "")
        XCTAssertEqual(
            viewModel.steerQueue.map(\.text),
            ["should queue while background generation is active"]
        )
    }

    func testGenerateResponseIsRejectedWhenBackgroundGenerationIsActiveForCurrentConversation() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        viewModel.generationActiveOverrideForTesting = { _ in true }

        viewModel.generateResponseForTesting(inputDigest: "digest", conversationId: nil)

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.configurationError)
    }

    func testStaleCompactEventsAreRejectedAfterRunFinishes() {
        XCTAssertFalse(ChatContextCompactEventRouter.shouldApply(
            event: .completed(summary: "上下文已压缩。"),
            eventRunId: "run-a",
            currentRunId: nil
        ))
        XCTAssertFalse(ChatContextCompactEventRouter.shouldApply(
            event: .idle,
            eventRunId: "run-a",
            currentRunId: nil
        ))
        XCTAssertFalse(ChatContextCompactEventRouter.shouldApply(
            event: .compacting,
            eventRunId: "run-a",
            currentRunId: nil
        ))
        XCTAssertFalse(ChatContextCompactEventRouter.shouldApply(
            event: .completed(summary: "旧任务完成"),
            eventRunId: "run-a",
            currentRunId: "run-b"
        ))
        XCTAssertFalse(ChatContextCompactEventRouter.shouldApply(
            event: .failed(message: "旧任务失败"), eventRunId: "run-a", currentRunId: nil
        ))
        XCTAssertTrue(ChatContextCompactEventRouter.shouldApply(
            event: .completed(summary: "本次完成"), eventRunId: "run-a", currentRunId: "run-a"
        ))
    }

    func testEditingUserMessagePreservesImageParts() {
        let original = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.user,
            parts: [
                UIMessagePart.Text(text: "old caption", metadata: nil),
                UIMessagePart.Image(url: "data:image/png;base64,AAA", metadata: nil)
            ],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )

        let edited = ChatViewModel.editedUserMessageForTesting(original: original, newText: "new caption")

        XCTAssertEqual(
            edited.parts.compactMap { ($0 as? UIMessagePart.Text)?.text },
            ["new caption"]
        )
        XCTAssertEqual(
            edited.parts.compactMap { ($0 as? UIMessagePart.Image)?.url },
            ["data:image/png;base64,AAA"]
        )
    }

    func testVisionRecognitionCacheKeyUsesDigestInsteadOfDataUrl() {
        let dataUrl = "data:image/png;base64," + String(repeating: "QUJD", count: 512)

        let key = ChatViewModel.visionRecognitionCacheKeyForTesting(dataUrl)

        XCTAssertEqual(key, ChatViewModel.visionRecognitionCacheKeyForTesting(dataUrl))
        XCTAssertNotEqual(key, dataUrl)
        XCTAssertFalse(key.contains("QUJD"))
        XCTAssertEqual(key.count, "vision:".count + 32)
    }

    func testRegenerateRestoredImageRecognizesBeforeUpload() async throws {
        let vision = ImageUploadRecordingProvider()
        let chat = ImageUploadRecordingProvider()
        let (viewModel, store, directory) = try await makeImageUploadRun(vision: vision, chat: chat)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = "data:image/png;base64,QUJD"
        let original = IOSChatForegroundFixtures.makeMessage(role: .user, parts: [
            UIMessagePart.Text(text: "这是什么意思？", metadata: nil),
            UIMessagePart.Image(url: imageURL, metadata: nil)
        ])
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let saved = await store.save(messages: [original], to: conversationId)
        XCTAssertTrue(saved)
        viewModel.reloadFromStore()

        // The restored message has no recognition cache in this ViewModel.
        viewModel.regenerate(atMessageIndex: 0)
        try await waitForImageUpload { chat.lastUpload != nil && !viewModel.isGenerationActive }

        let upload = try XCTUnwrap(chat.lastUpload)
        XCTAssertEqual(vision.uploadedImageURLs, [imageURL])
        XCTAssertTrue(upload.contains { $0.toText().contains("<image_context>\nrecognized image") })
        XCTAssertFalse(upload.flatMap(\.parts).contains { $0 is UIMessagePart.Image })
        XCTAssertEqual(
            viewModel.messages.flatMap(\.parts).compactMap { ($0 as? UIMessagePart.Image)?.url },
            [imageURL]
        )
    }

    func testQueuedImageRecognizesBeforeAutomaticNextRun() async throws {
        let vision = ImageUploadRecordingProvider()
        let chat = ImageUploadRecordingProvider()
        let (viewModel, store, directory) = try await makeImageUploadRun(vision: vision, chat: chat)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = "data:image/png;base64,REVG"
        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.addPendingImage(dataUrl: imageURL, previewData: Data())
        viewModel.inputText = "再看这张图片"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.generationActiveOverrideForTesting = nil

        viewModel.handleSteerQueueAtRunTerminal(for: store.currentConversation?.id, autoContinue: true)
        try await waitForImageUpload { chat.lastUpload != nil && !viewModel.isGenerationActive }

        XCTAssertTrue(viewModel.steerQueue.isEmpty)
        XCTAssertEqual(vision.uploadedImageURLs, [imageURL])
        let upload = try XCTUnwrap(chat.lastUpload)
        XCTAssertTrue(upload.contains { $0.toText().contains("<image_context>\nrecognized image") })
        XCTAssertFalse(upload.contains { $0.toText().contains("[图片未能识别]") })
    }

    func testMissingRecognitionFailureStopsUploadAndPreservesImage() async throws {
        let vision = ImageUploadRecordingProvider(fails: true)
        let chat = ImageUploadRecordingProvider()
        let (viewModel, store, directory) = try await makeImageUploadRun(vision: vision, chat: chat)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = "data:image/png;base64,R0hJ"
        viewModel.messages = [IOSChatForegroundFixtures.makeMessage(role: .user, parts: [
            UIMessagePart.Image(url: imageURL, metadata: nil)
        ])]

        viewModel.generateResponseForTesting(inputDigest: "image retry", conversationId: store.currentConversation?.id)
        try await waitForImageUpload { !vision.uploadedImageURLs.isEmpty && !viewModel.isGenerationActive }

        XCTAssertNil(chat.lastUpload, "recognition failure must stop the main provider request")
        XCTAssertTrue(viewModel.messages.contains { $0.toText().contains("vision test failure") })
        XCTAssertEqual(
            viewModel.messages.flatMap(\.parts).compactMap { ($0 as? UIMessagePart.Image)?.url },
            [imageURL]
        )
    }

    func testPreparedUploadExcludesLocalGenerationErrorBubble() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        let errorMessage = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [MessageKt.localGenerationErrorTextPart(text: "local provider failure")],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )

        let prepared = viewModel.preparedUploadMessagesForTesting([
            UIMessage.companion.user(prompt: "retry after failure"),
            errorMessage,
        ])

        XCTAssertFalse(prepared.contains { $0.toText().contains("local provider failure") })
    }

    func testEmptyResponseNoticesAreExcludedFromUpload() {
        // 注入面审计 B11：空回复通知是本地终态文案，不应作为 assistant 历史上传。
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )

        let prepared = viewModel.preparedUploadMessagesForTesting([
            UIMessage.companion.user(prompt: "再问一次"),
            ChatGenerationSupport.emptyResponseNotice(),
        ])

        XCTAssertFalse(prepared.contains { $0.toText().contains("模型没有返回任何内容") })
        XCTAssertEqual(
            prepared.filter { $0.role == MessageRole.user }.map { $0.toText() },
            ["再问一次"]
        )
    }

    func testBranchMutationsAreRejectedWhileVisionRecognitionIsPending() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatViewModelVisionRecognitionBranchGuard-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.newConversation()
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "question"),
            UIMessage.companion.assistant(prompt: "answer")
        ])

        let viewModel = ChatViewModel(settingsStore: SettingsStore(), autoGenerateResponses: false)
        viewModel.conversationStore = store
        viewModel.reloadFromStore()
        viewModel.isRecognizingImages = true

        viewModel.editMessage(atMessageIndex: 0, newText: "edited question")
        viewModel.regenerate(atMessageIndex: 0)
        viewModel.deleteMessage(atMessageIndex: 1)
        viewModel.selectVariant(messageIndex: 1, variantIndex: 0)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.currentMessages.map { $0.toText() }, ["question", "answer"])
        XCTAssertEqual(viewModel.messages.map { $0.toText() }, ["question", "answer"])
        XCTAssertEqual(viewModel.selectedFileContextError, "图片识别中，请稍候")
    }

    func testVisionRecognitionResultSurvivesUnrelatedRevisionBumpWhenUserMessageStillExists() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        let userMessage = UIMessage.companion.user(prompt: "image question")
        viewModel.messages = [userMessage]
        let userMessageId = ChatMessageProjector.messageId(for: userMessage)

        XCTAssertTrue(viewModel.shouldApplyVisionRecognitionResultForTesting(
            conversationId: nil,
            userMessageId: userMessageId
        ))

        viewModel.messageRevision &+= 1

        XCTAssertTrue(viewModel.shouldApplyVisionRecognitionResultForTesting(
            conversationId: nil,
            userMessageId: userMessageId
        ))
    }

    func testVisionRecognitionResultIsRejectedAfterUserMessageDisappears() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        let userMessage = UIMessage.companion.user(prompt: "image question")
        let userMessageId = ChatMessageProjector.messageId(for: userMessage)
        viewModel.messages = []

        XCTAssertFalse(viewModel.shouldApplyVisionRecognitionResultForTesting(
            conversationId: nil,
            userMessageId: userMessageId
        ))
    }

    func testVisionRecognitionFailureIsIgnoredAfterConversationChanges() async {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        let userMessage = UIMessage.companion.user(prompt: "image question")
        let userMessageId = ChatMessageProjector.messageId(for: userMessage)
        viewModel.messages = []

        await viewModel.applyVisionRecognitionFailureForTesting(
            message: "OCR failed",
            conversationId: nil,
            userMessageId: userMessageId
        )

        XCTAssertNil(viewModel.selectedFileContextError)
    }

    func testVisionRecognitionFailureIsFlushedWhenOriginalConversationReturns() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatViewModelVisionFailureFlush-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let firstConversationId = try XCTUnwrap(store.currentConversation?.id)
        let userMessage = UIMessage.companion.user(prompt: "image question")
        await store.saveCurrent(messages: [userMessage])
        let userMessageId = ChatMessageProjector.messageId(for: userMessage)

        await store.newConversation()
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "other conversation")])

        let viewModel = ChatViewModel(settingsStore: SettingsStore(), autoGenerateResponses: false)
        viewModel.conversationStore = store
        viewModel.reloadFromStore()

        await viewModel.applyVisionRecognitionFailureForTesting(
            message: "OCR failed",
            conversationId: firstConversationId,
            userMessageId: userMessageId
        )
        XCTAssertNil(viewModel.selectedFileContextError)

        await store.selectConversation(id: firstConversationId)
        viewModel.reloadFromStore()

        XCTAssertTrue(store.currentMessages.last?.toText().contains("OCR failed") == true)
    }

    func testReloadClosesTerminalPendingToolWithoutActiveGeneration() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatTerminalPendingToolRecovery-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        await store.saveCurrent(messages: terminalPendingSearchMessages())
        let viewModel = ChatViewModel(settingsStore: SettingsStore(), autoGenerateResponses: false)
        viewModel.conversationStore = store

        viewModel.reloadFromStore()

        let recoveredTool = try XCTUnwrap(
            viewModel.messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first
        )
        let recoveredPayload = try jsonObject(
            recoveredTool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
        )
        XCTAssertEqual(recoveredPayload["cancelled"] as? Bool, true)
        XCTAssertEqual(
            recoveredPayload["reason"] as? String,
            IOSAppLocalization.string(
                "The previous generation ended before the tool call completed.",
                defaultValue: "The previous generation ended before the tool call completed."
            )
        )

        for _ in 0..<100 {
            let persistedTool = store.currentMessages
                .flatMap(\.parts)
                .compactMap { $0 as? UIMessagePart.Tool }
                .first
            if persistedTool?.output.isEmpty == false { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let persistedTool = try XCTUnwrap(
            store.currentMessages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first
        )
        XCTAssertFalse(persistedTool.output.isEmpty)
    }

    func testReloadKeepsTerminalPendingToolWhileGenerationOwnsConversation() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatActivePendingToolRecoveryGate-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        await store.saveCurrent(messages: terminalPendingSearchMessages())
        let viewModel = ChatViewModel(settingsStore: SettingsStore(), autoGenerateResponses: false)
        viewModel.conversationStore = store
        viewModel.generationActiveOverrideForTesting = { _ in true }

        viewModel.reloadFromStore()
        try await Task.sleep(nanoseconds: 20_000_000)

        let loadedTool = try XCTUnwrap(
            viewModel.messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first
        )
        let persistedTool = try XCTUnwrap(
            store.currentMessages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first
        )
        XCTAssertTrue(loadedTool.output.isEmpty)
        XCTAssertTrue(persistedTool.output.isEmpty)
    }

    func testVisionRecognitionSuccessClearsTransientPendingPrompt() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        let userMessage = UIMessage.companion.user(prompt: "image question")
        viewModel.messages = [userMessage]
        viewModel.selectedFileContextError = "图片识别中，请稍候"

        viewModel.applyVisionRecognitionSuccessForTesting(
            conversationId: nil,
            userMessageId: ChatMessageProjector.messageId(for: userMessage)
        )

        XCTAssertNil(viewModel.selectedFileContextError)
    }

    func testModifyGeneratedImageIsRejectedWhileVisionRecognitionIsPending() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        viewModel.isRecognizingImages = true

        viewModel.modifyGeneratedImage(
            sourceImageURL: "file:///tmp/source.png",
            prompt: "make it brighter",
            aspectRatio: "1:1"
        )

        XCTAssertEqual(viewModel.selectedFileContextError, "图片识别中，请稍候")
        XCTAssertFalse(viewModel.isLoading)
    }

    func testModifyGeneratedImageSurfacesErrorWhileGenerationActive() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        viewModel.generationActiveOverrideForTesting = { _ in true }

        viewModel.modifyGeneratedImage(
            sourceImageURL: "file:///tmp/source.png",
            prompt: "make it brighter",
            aspectRatio: "1:1"
        )

        XCTAssertEqual(viewModel.selectedFileContextError, "请等当前回复结束后再修改图片")
    }

    private func makeImageUploadRun(
        vision: any IOSAgentTextProvider,
        chat: any IOSAgentTextProvider
    ) async throws -> (ChatViewModel, IOSConversationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageUploadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = IOSConversationStore(baseDirectory: directory.appendingPathComponent("conversations"))
        await store.bootstrap()
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(userDefaults: isolatedDefaults()),
            sharedSettings: visionFallbackSettings(),
            auxiliaryTextProvider: vision,
            steerQueueStore: IOSSteerQueueStore(directoryURL: directory.appendingPathComponent("queue")),
            agentRuntimeDao: IosDatabaseFactory.shared.createDatabase(
                atFilePath: directory.appendingPathComponent("runtime.db").path
            ).agentRuntimeDao()
        )
        viewModel.kernelTextProviderOverrideForTesting = chat
        viewModel.conversationStore = store
        viewModel.reloadFromStore()
        return (viewModel, store, directory)
    }

    private func waitForImageUpload(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "image upload run did not reach its expected terminal state")
    }


    private func terminalPendingSearchMessages() -> [UIMessage] {
        let tool = UIMessagePart.Tool(
            toolCallId: "terminal-pending-search",
            toolName: "search_web",
            input: #"{"query":"amber"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let seed = UIMessage.companion.assistant(prompt: "")
        let assistant = UIMessage(
            id: seed.id,
            role: seed.role,
            parts: [tool],
            annotations: seed.annotations,
            createdAt: seed.createdAt,
            finishedAt: chatNowLocalDateTime(),
            modelId: seed.modelId,
            usage: seed.usage,
            translation: seed.translation
        )
        return [UIMessage.companion.user(prompt: "search"), assistant]
    }

    private func visionFallbackSettings() -> IOSSharedSettingsStore {
        let chatModel = Model(
            modelId: "text-only-test-model",
            displayName: "Text Only",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let visionModel = Model(
            modelId: "vision-test-model",
            displayName: "Vision",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "Vision Test Provider",
            models: [chatModel, visionModel],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "test-key",
            baseUrl: "https://example.com/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        let settings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        _ = settings.addProvider(provider)
        settings.setCurrentChatModelId(chatModel.id.description())
        settings.setCurrentAssistantChatModelId(chatModel.id.description())
        settings.setOcrModelId(visionModel.id.description())
        return settings
    }
}
