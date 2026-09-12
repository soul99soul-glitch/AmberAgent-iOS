import XCTest
@preconcurrency import Shared
@testable import iosApp

/// P1-b: mailbox 信封折入契约（基建参考 IOSSteerQueueTests）。
///
/// 契约：
/// 1. 工具循环边界折入：注入 2 信封 → 边界消费 → 下一轮 upload 含渲染文本（FIFO）、
///    会话持久化出 user 消息、Room 标记 delivered。
/// 2. 顺序：mailbox 信封在 steer 文本之前。
/// 3. 终态 leftover 不回 composer：留在 Room；下一次 run 首轮 `prepareAndStartStreaming`
///    头消费（同门控：补绘重试轮 displayMessagesOverride != nil 不消费）。
/// 4. 幂等：同一 run 重复边界不重复折入（drain 二次为空）。
@MainActor
final class IOSMailboxDeliveryTests: XCTestCase {

    private final class PlainTextProvider: IOSAgentTextProvider, @unchecked Sendable {
        private(set) var callCount = 0
        private(set) var recordedMessages: [[UIMessage]] = []

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            callCount += 1
            recordedMessages.append(messages)
            let text = callCount == 1 ? "第一轮回答" : "已消费追加任务"
            return MessageChunk(
                id: "chunk-\(callCount)",
                model: "test-model",
                choices: [UIMessageChoice(
                    index: 0,
                    delta: nil,
                    message: UIMessage.companion.assistant(prompt: text),
                    finishReason: "stop"
                )],
                usage: nil
            )
        }
    }

    private final class OneShotMailboxDrain: @unchecked Sendable {
        private let message: UIMessage
        private var delivered = false

        init(message: UIMessage) {
            self.message = message
        }

        func next() -> IOSMailboxDrainResult {
            guard !delivered else { return IOSMailboxDrainResult(values: []) }
            delivered = true
            return IOSMailboxDrainResult(values: [message])
        }
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "IOSMailboxDeliveryTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func makeTempDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeConversationStore(directory: URL) -> IOSConversationStore {
        IOSConversationStore(baseDirectory: directory)
    }

    /// 隔离 Room 库（临时文件路径，与生产 Documents/agent_runtime.db 无关）。
    private func makeMailboxDao(directory: URL) -> MailboxDao {
        let db = IosDatabaseFactory.shared.createDatabase(
            atFilePath: directory.appendingPathComponent("mailbox.db").path
        )
        return db.mailboxDao()
    }

    private func makeViewModel(
        conversationStore: IOSConversationStore,
        mailboxDao: MailboxDao,
        activityCenter: IOSMailboxActivityCenter? = nil
    ) -> ChatViewModel {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            autoGenerateResponses: false,
            mailboxStore: IOSMailboxStore(mailboxDao: mailboxDao),
            mailboxActivityCenter: activityCenter
        )
        viewModel.conversationStore = conversationStore
        viewModel.reloadFromStore()
        return viewModel
    }

    private func makeProviderSetting() -> ProviderSetting.OpenAI {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "mailbox-test",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
    }

    private func makeParams() -> TextGenerationParams {
        let model = Model(
            modelId: "mailbox-test-model",
            displayName: "mailbox-test-model",
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
        return TextGenerationParams(
            model: model,
            temperature: KotlinFloat(value: 0.7),
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
    }

    private func envelope(
        id: String,
        recipient: KotlinUuid,
        payload: String,
        createdAt: Int64,
        type: String = MailboxEnvelopeType.message.name
    ) -> MailboxEnvelopeEntity {
        MailboxEnvelopeEntity(
            id: id,
            authorThreadId: "/root/a",
            recipientThreadId: recipient.toHexDashString(),
            type: type,
            payload: payload,
            triggerTurn: false,
            parentTurnId: nil,
            createdAt: createdAt,
            deliveredAt: nil
        )
    }

    private func enqueue(_ dao: MailboxDao, _ envelope: MailboxEnvelopeEntity) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            dao.enqueue(envelope: envelope) { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }
    }

    private func pendingEnvelopeIds(_ dao: MailboxDao, recipient: KotlinUuid) async -> [String] {
        await withCheckedContinuation { cont in
            dao.pendingForRecipient(recipientId: recipient.toHexDashString()) { result, _ in
                // 回调内归约成 Sendable 字符串（Kotlin 实体非 Sendable，不外传）。
                cont.resume(returning: (result ?? []).map(\.id))
            }
        }
    }

    /// 轮询等待 drain 的异步会话落盘完成（drain 的 persist 走 fire-and-forget Task，
    /// 与 drainSteerQueue 同一模式）。
    private func pollPersistedUserTexts(
        store: IOSConversationStore,
        conversationId: KotlinUuid,
        minUserMessages: Int,
        timeout: TimeInterval = 5
    ) async throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String] = []
        while Date() < deadline {
            let messages = await store.messages(for: conversationId) ?? []
            last = messages.filter { $0.role == MessageRole.user }.map { $0.toText() }
            if last.count >= minUserMessages { return last }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return last
    }

    private func renderedText(_ payload: String) -> String {
        MailboxEnvelopeKt.renderMailboxEnvelopeToUserText(
            authorThreadId: "/root/a",
            type: MailboxEnvelopeType.message.name,
            payload: payload
        )
    }

    // MARK: - 1. 工具循环边界折入

    func testIdleReportPreviewKeepsInputAndLeavesDeliveryToNextRun() async throws {
        let base = makeTempDirectory("IdleReportPreview")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let dao = makeMailboxDao(directory: base)
        let vm = makeViewModel(conversationStore: store, mailboxDao: dao)
        vm.inputText = "用户尚未发送的消息"
        vm.selectedFileContextError = "保留附件提示"
        try await enqueue(dao, envelope(id: "preview-final", recipient: id, payload: "已收集网页内容", createdAt: 1, type: "FINAL_ANSWER"))
        try await enqueue(dao, envelope(id: "preview-task", recipient: id, payload: "待处理任务", createdAt: 2, type: "NEW_TASK"))

        await vm.previewIdleMailboxResults(conversationId: id)
        await vm.previewIdleMailboxResults(conversationId: id)
        XCTAssertEqual(vm.messages.filter(ChatMessageProjector.isSubAgentResult).count, 1)
        XCTAssertEqual(vm.inputText, "用户尚未发送的消息")
        XCTAssertEqual(vm.selectedFileContextError, "保留附件提示")
        XCTAssertFalse(vm.isGenerationActive)
        XCTAssertEqual(vm.messageUpdateSignal.reason, .toolResultAppended)
        let pending = await pendingEnvelopeIds(dao, recipient: id)
        XCTAssertEqual(pending, ["preview-final", "preview-task"], "预览不得抢先确认后台任务或结果投递")

        let seed = vm.messages
        let nextUpload = seed + (await vm.drainMailbox(conversationId: id))
        XCTAssertEqual(nextUpload.filter(ChatMessageProjector.isSubAgentResult).count, 1)
        XCTAssertTrue(nextUpload.contains { $0.toText().contains("待处理任务") })
        let remaining = await pendingEnvelopeIds(dao, recipient: id)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testIdlePreviewReadRacingUserRunDoesNotConsumeOrPublishMail() async throws {
        let base = makeTempDirectory("IdlePreviewRace")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let dao = makeMailboxDao(directory: base)
        let vm = makeViewModel(conversationStore: store, mailboxDao: dao)
        try await enqueue(dao, envelope(id: "race-final", recipient: id, payload: "完成报告", createdAt: 1, type: "FINAL_ANSWER"))
        vm.beforeIdleMailboxPreviewApplyForTesting = { [weak vm] in
            vm?.generationActiveOverrideForTesting = { _ in true }
        }
        await vm.previewIdleMailboxResults(conversationId: id)
        XCTAssertTrue(vm.messages.isEmpty)
        let pending = await pendingEnvelopeIds(dao, recipient: id)
        XCTAssertEqual(pending, ["race-final"])
        let head = await vm.drainMailbox(conversationId: id)
        XCTAssertEqual(head.filter(ChatMessageProjector.isSubAgentResult).count, 1)

        vm.generationActiveOverrideForTesting = nil
        try await enqueue(dao, envelope(id: "switch-final", recipient: id, payload: "旧会话结果", createdAt: 2, type: "FINAL_ANSWER"))
        vm.beforeIdleMailboxPreviewApplyForTesting = { [weak vm] in
            await store.newConversation()
            vm?.reloadFromStore()
        }
        await vm.previewIdleMailboxResults(conversationId: id)
        XCTAssertTrue(vm.messages.isEmpty, "切换会话时不得把旧会话结果投影到新会话")
        let oldPending = await pendingEnvelopeIds(dao, recipient: id)
        XCTAssertEqual(oldPending, ["switch-final"])
    }

    func testIdleObservationCatchesExistingAndNewReportsWithoutStartingRun() async throws {
        let base = makeTempDirectory("IdleObservation")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let dao = makeMailboxDao(directory: base)
        let center = IOSMailboxActivityCenter()
        let vm = makeViewModel(conversationStore: store, mailboxDao: dao, activityCenter: center)
        try await enqueue(dao, envelope(id: "before-idle", recipient: id, payload: "已有结果", createdAt: 1, type: "FINAL_ANSWER"))
        let observation = Task { await vm.observeIdleMailboxResults(conversationId: id) }
        defer { observation.cancel() }
        for _ in 0..<100 where vm.messages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(vm.messages.filter(ChatMessageProjector.isSubAgentResult).count, 1)
        try await enqueue(dao, envelope(id: "after-idle", recipient: id, payload: "新结果", createdAt: 2, type: "FINAL_ANSWER"))
        await center.signal(conversationIdHex: id.toHexDashString())
        for _ in 0..<100 where vm.messages.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(vm.messages.filter(ChatMessageProjector.isSubAgentResult).count, 2)
        XCTAssertFalse(vm.isGenerationActive)
        observation.cancel()
        await observation.value
    }

    func testYieldedParentWakesOnceWithAllReportsAndPreservesDraft() async throws {
        let base = makeTempDirectory("ParentWake")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let dao = makeMailboxDao(directory: base)
        let center = IOSMailboxActivityCenter()
        let vm = makeViewModel(conversationStore: store, mailboxDao: dao, activityCenter: center)
        let provider = PlainTextProvider()
        vm.kernelTextProviderOverrideForTesting = provider
        vm.inputText = "保留草稿"
        vm.selectedFileContextError = "保留附件提示"
        // Covers reports arriving before the terminal observer is registered.
        for index in 1...2 {
            try await enqueue(dao, envelope(id: "wake-\(index)", recipient: id,
                payload: "结果\(index)", createdAt: Int64(index), type: "FINAL_ANSWER"))
        }
        vm.beginChildResultWaitForTesting(runId: "waiting-run", provider: makeProviderSetting(), params: makeParams())
        for _ in 0..<500 where provider.callCount == 0 || vm.isGenerationActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(provider.recordedMessages.first?.filter(ChatMessageProjector.isSubAgentResult).count, 2)
        XCTAssertEqual(vm.inputText, "保留草稿")
        XCTAssertEqual(vm.selectedFileContextError, "保留附件提示")
        let pending = await pendingEnvelopeIds(dao, recipient: id)
        XCTAssertTrue(pending.isEmpty)
        await center.signal(conversationIdHex: id.toHexDashString())
        await vm.previewIdleMailboxResults(conversationId: id)
        XCTAssertEqual(provider.callCount, 1, "普通完成后重复通知不能再启动")
    }

    func testYieldedParentWakesOnLaterSignalEvenAfterConversationSwitch() async throws {
        let base = makeTempDirectory("ParentWakeSwitch")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let dao = makeMailboxDao(directory: base)
        let center = IOSMailboxActivityCenter()
        let vm = makeViewModel(conversationStore: store, mailboxDao: dao, activityCenter: center)
        let provider = PlainTextProvider()
        vm.kernelTextProviderOverrideForTesting = provider
        vm.beginChildResultWaitForTesting(runId: "waiting-old", provider: makeProviderSetting(), params: makeParams())
        await store.newConversation()
        vm.reloadFromStore()
        vm.inputText = "新会话草稿"
        try await enqueue(dao, envelope(id: "late-final", recipient: id, payload: "旧会话结果", createdAt: 1, type: "FINAL_ANSWER"))
        await center.signal(conversationIdHex: id.toHexDashString())
        for _ in 0..<500 where provider.callCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(vm.inputText, "新会话草稿")
        XCTAssertFalse(vm.messages.contains { $0.toText().contains("旧会话结果") })
        _ = try await pollPersistedUserTexts(store: store, conversationId: id, minUserMessages: 1)
        let oldMessages = await store.messages(for: id) ?? []
        XCTAssertTrue(oldMessages.contains { $0.toText().contains("旧会话结果") })
    }

    func testRejectedImageSendDoesNotRevokeWaitingParent() async throws {
        let base = makeTempDirectory("ParentWakeRejectedSend")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let dao = makeMailboxDao(directory: base)
        let vm = makeViewModel(conversationStore: store, mailboxDao: dao, activityCenter: IOSMailboxActivityCenter())
        let provider = PlainTextProvider()
        vm.kernelTextProviderOverrideForTesting = provider
        vm.pendingImages = (0...ChatViewModel.maxImagesPerMessage).map { _ in
            ChatViewModel.PendingChatImage(dataUrl: "data:image/png;base64,aaa", previewData: Data("preview".utf8))
        }
        vm.inputText = "尚未发出的消息"
        try await enqueue(dao, envelope(id: "blocked-send-final", recipient: id, payload: "完成结果", createdAt: 1, type: "FINAL_ANSWER"))
        vm.beginChildResultWaitForTesting(runId: "waiting-despite-rejected-send", provider: makeProviderSetting(), params: makeParams())
        XCTAssertFalse(vm.sendMessage())
        for _ in 0..<500 where provider.callCount == 0 || vm.isGenerationActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(provider.callCount, 1, "未发送成功的消息不得撤销等待")
        XCTAssertEqual(vm.inputText, "尚未发出的消息")
        XCTAssertEqual(vm.pendingImages.count, ChatViewModel.maxImagesPerMessage + 1)
    }

    func testTransientWakeReadFailureRetriesWithoutAnotherSignal() async throws {
        let base = makeTempDirectory("ParentWakeRetry")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let dao = makeMailboxDao(directory: base)
        let vm = makeViewModel(conversationStore: store, mailboxDao: dao, activityCenter: IOSMailboxActivityCenter())
        let provider = PlainTextProvider()
        vm.kernelTextProviderOverrideForTesting = provider
        try await enqueue(dao, envelope(id: "retry-final", recipient: id, payload: "保留结果", createdAt: 1, type: "FINAL_ANSWER"))
        var reads = 0
        vm.beforeChildResultWakeApplyForTesting = {
            reads += 1
            if reads == 1 { throw CocoaError(.fileReadNoPermission) }
        }
        vm.beginChildResultWaitForTesting(runId: "retry-wait", provider: makeProviderSetting(), params: makeParams())
        for _ in 0..<500 where provider.callCount == 0 || vm.isGenerationActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertTrue(provider.recordedMessages.first?.contains { $0.toText().contains("保留结果") } == true)
        let pending = await pendingEnvelopeIds(dao, recipient: id)
        XCTAssertTrue(pending.isEmpty)
    }

    func testNewInputOrCancelDuringRetryDelayPreventsStaleWake() async throws {
        for sendNewMessage in [true, false] {
            let base = makeTempDirectory("ParentWakeRetryCancelled")
            defer { try? FileManager.default.removeItem(at: base) }
            let store = makeConversationStore(directory: base)
            await store.newConversation()
            let id = try XCTUnwrap(store.currentConversation?.id)
            let dao = makeMailboxDao(directory: base)
            let vm = makeViewModel(conversationStore: store, mailboxDao: dao, activityCenter: IOSMailboxActivityCenter())
            let provider = PlainTextProvider()
            vm.kernelTextProviderOverrideForTesting = provider
            try await enqueue(dao, envelope(id: "cancel-retry", recipient: id, payload: "保留结果", createdAt: 1, type: "FINAL_ANSWER"))
            var reads = 0
            vm.beforeChildResultWakeApplyForTesting = {
                reads += 1
                throw CocoaError(.fileReadNoPermission)
            }
            vm.beginChildResultWaitForTesting(runId: "retry-old", provider: makeProviderSetting(), params: makeParams())
            for _ in 0..<100 where reads == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(reads, 1)
            if sendNewMessage {
                vm.inputText = "新问题"
                XCTAssertTrue(vm.sendMessage())
            } else {
                vm.cancelGeneration()
            }
            try await Task.sleep(for: .milliseconds(1100))
            XCTAssertEqual(reads, 1, "撤销等待必须取消退避计时")
            XCTAssertEqual(provider.callCount, 0)
            let pending = await pendingEnvelopeIds(dao, recipient: id)
            XCTAssertEqual(pending, ["cancel-retry"])
        }
    }

    func testNewUserSendOrCancelDuringWakeReadRevokesOldContinuation() async throws {
        for sendNewMessage in [true, false] {
            let base = makeTempDirectory("ParentWakeRace")
            defer { try? FileManager.default.removeItem(at: base) }
            let store = makeConversationStore(directory: base)
            await store.newConversation()
            let id = try XCTUnwrap(store.currentConversation?.id)
            let dao = makeMailboxDao(directory: base)
            let vm = makeViewModel(conversationStore: store, mailboxDao: dao)
            let provider = PlainTextProvider()
            vm.kernelTextProviderOverrideForTesting = provider
            try await enqueue(dao, envelope(id: "race-final", recipient: id, payload: "保留结果", createdAt: 1, type: "FINAL_ANSWER"))
            let checked = expectation(description: "wake read raced input")
            vm.beforeChildResultWakeApplyForTesting = { [weak vm] in
                if sendNewMessage {
                    vm?.inputText = "新问题"
                    XCTAssertEqual(vm?.sendMessage(), true)
                } else {
                    vm?.cancelGeneration()
                }
                checked.fulfill()
            }
            vm.beginChildResultWaitForTesting(runId: "superseded", provider: makeProviderSetting(), params: makeParams())
            await fulfillment(of: [checked], timeout: 5)
            // A read-only peek must leave delivery to the user's next run.
            let pending = await pendingEnvelopeIds(dao, recipient: id)
            XCTAssertEqual(pending, ["race-final"])
            XCTAssertEqual(provider.callCount, 0)
            XCTAssertFalse(vm.isGenerationActive)
        }
    }

    func testToolLoopBoundaryFoldsEnvelopesIntoNextRoundUploadAndDelivers() async throws {
        let base = makeTempDirectory("MailboxBoundary")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let dao = makeMailboxDao(directory: base)
        try await enqueue(dao, envelope(id: "mb-1", recipient: conversationId, payload: "信封一", createdAt: 100))
        try await enqueue(dao, envelope(id: "mb-2", recipient: conversationId, payload: "信封二", createdAt: 200))
        let viewModel = makeViewModel(conversationStore: store, mailboxDao: dao)

        // 模拟工具结果轮：continueAfterToolResult 边界消费。
        viewModel.inputText = "尚未发送的草稿"
        viewModel.selectedFileContextError = "保留附件提示"
        let baseMessages = [UIMessage.companion.assistant(prompt: "工具结果")]
        let nextRoundUpload = baseMessages + (await viewModel.drainMailbox(conversationId: conversationId))
        XCTAssertEqual(viewModel.inputText, "尚未发送的草稿")
        XCTAssertEqual(viewModel.selectedFileContextError, "保留附件提示")
        XCTAssertEqual(viewModel.messageUpdateSignal.reason, .toolResultAppended,
                       "内部投递不能伪装成用户发送并抢走滚动位置")
        XCTAssertTrue(ChatMessageProjector.rows(messages: viewModel.messages, event: .conversationLoaded).isEmpty)

        // 下一轮 upload 含渲染文本（FIFO 顺序，结构头格式）。
        let uploadUserTexts = nextRoundUpload
            .filter { $0.role == MessageRole.user }
            .map { $0.toText() }
        XCTAssertEqual(uploadUserTexts, [renderedText("信封一"), renderedText("信封二")])

        // 会话内存出现 user 节点。
        let memoryUserTexts = viewModel.messages
            .filter { $0.role == MessageRole.user }
            .map { $0.toText() }
        XCTAssertEqual(memoryUserTexts, [renderedText("信封一"), renderedText("信封二")])

        // Room 标记 delivered：再次 drain 为空。
        let remainingAfterDelivery = await pendingEnvelopeIds(dao, recipient: conversationId)
        XCTAssertTrue(remainingAfterDelivery.isEmpty)

        // 会话持久化出 user 消息节点（exactly once：drain 即落盘）。
        let persisted = try await pollPersistedUserTexts(
            store: store,
            conversationId: conversationId,
            minUserMessages: 2
        )
        XCTAssertEqual(persisted, [renderedText("信封一"), renderedText("信封二")])
    }

    // MARK: - 2. 顺序：mailbox 先于 steer

    func testMailboxEnvelopesFoldBeforeSteerTextsInUpload() async throws {
        let base = makeTempDirectory("MailboxOrdering")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let dao = makeMailboxDao(directory: base)
        try await enqueue(dao, envelope(id: "mb-1", recipient: conversationId, payload: "信封甲", createdAt: 100))
        try await enqueue(dao, envelope(id: "mb-2", recipient: conversationId, payload: "信封乙", createdAt: 200))
        let viewModel = makeViewModel(conversationStore: store, mailboxDao: dao)

        // 生成中排队一条 steer。
        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "steer 文本"
        XCTAssertTrue(viewModel.sendMessage())

        let baseMessages = [UIMessage.companion.assistant(prompt: "工具结果")]
        let nextRoundUpload = await viewModel.nextRoundMessagesAfterMailboxAndSteerConsumptionForTesting(
            baseMessages: baseMessages
        )
        let uploadUserTexts = nextRoundUpload
            .filter { $0.role == MessageRole.user }
            .map { $0.toText() }
        XCTAssertEqual(
            uploadUserTexts,
            [renderedText("信封甲"), renderedText("信封乙"), "steer 文本"],
            "mailbox 信封必须排在 steer 文本之前"
        )
    }

    // MARK: - 3. 终态 leftover 留在 Room；下一次 run 首轮头消费

    func testTerminalLeftoverStaysInRoomUntilNextRunHeadConsumesIt() async throws {
        let base = makeTempDirectory("MailboxTerminalLeftover")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let dao = makeMailboxDao(directory: base)
        try await enqueue(dao, envelope(id: "mb-late", recipient: conversationId, payload: "终态信封", createdAt: 100))
        let viewModel = makeViewModel(conversationStore: store, mailboxDao: dao)

        // 无工具边界的 run 终态：信封不回 composer（与 steer 不同），留在 Room。
        XCTAssertTrue(viewModel.inputText.isEmpty)
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == MessageRole.user }.count,
            0,
            "终态 leftover 不落成消息、不进 composer"
        )
        let pendingAtTerminal = await pendingEnvelopeIds(dao, recipient: conversationId)
        XCTAssertEqual(
            pendingAtTerminal,
            ["mb-late"],
            "未消费信封必须留在 Room 等下次 run"
        )

        // 下一次 run 首轮 prepareAndStartStreaming 头消费（displayMessagesOverride == nil）。
        let drained = await viewModel.drainMailboxAtNewRunHeadForTesting(
            conversationId: conversationId,
            displayMessagesOverride: nil
        )
        XCTAssertEqual(drained.map { $0.toText() }, [renderedText("终态信封")])
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == MessageRole.user }.map { $0.toText() },
            [renderedText("终态信封")]
        )
        let remainingAfterHeadConsumption = await pendingEnvelopeIds(dao, recipient: conversationId)
        XCTAssertTrue(remainingAfterHeadConsumption.isEmpty, "头消费后 Room 必须标记 delivered")
    }

    // MARK: - 4. 补绘重试轮不消费

    func testRedrawRoundDoesNotConsumeMailbox() async throws {
        let base = makeTempDirectory("MailboxRedraw")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let dao = makeMailboxDao(directory: base)
        try await enqueue(dao, envelope(id: "mb-draw", recipient: conversationId, payload: "补绘不该消费", createdAt: 100))
        let viewModel = makeViewModel(conversationStore: store, mailboxDao: dao)

        // displayMessagesOverride 非 nil = 补绘重试轮：展示基线是显式快照，不消费。
        let drained = await viewModel.drainMailboxAtNewRunHeadForTesting(
            conversationId: conversationId,
            displayMessagesOverride: [UIMessage.companion.assistant(prompt: "补绘基线")]
        )
        XCTAssertTrue(drained.isEmpty)
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == MessageRole.user }.count,
            0,
            "补绘轮不得把信封折入展示/落盘谱系"
        )
        let pendingAfterRedraw = await pendingEnvelopeIds(dao, recipient: conversationId)
        XCTAssertEqual(
            pendingAfterRedraw,
            ["mb-draw"],
            "补绘轮后信封必须原样留在 Room"
        )
    }

    // MARK: - 5. 幂等：同一 run 重复边界不重复折入

    func testRepeatedBoundaryDoesNotDoubleFoldEnvelopes() async throws {
        let base = makeTempDirectory("MailboxIdempotent")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let dao = makeMailboxDao(directory: base)
        try await enqueue(dao, envelope(id: "mb-i1", recipient: conversationId, payload: "幂等一", createdAt: 100))
        try await enqueue(dao, envelope(id: "mb-i2", recipient: conversationId, payload: "幂等二", createdAt: 200))
        let viewModel = makeViewModel(conversationStore: store, mailboxDao: dao)

        let baseMessages = [UIMessage.companion.assistant(prompt: "工具结果")]
        let firstRound = await viewModel.nextRoundMessagesAfterMailboxAndSteerConsumptionForTesting(
            baseMessages: baseMessages
        )
        XCTAssertEqual(
            firstRound.filter { $0.role == MessageRole.user }.map { $0.toText() },
            [renderedText("幂等一"), renderedText("幂等二")]
        )

        // 同一 run 第二次边界（如后续工具轮）：drain 二次为空，不重复折入。
        let secondRound = await viewModel.nextRoundMessagesAfterMailboxAndSteerConsumptionForTesting(
            baseMessages: baseMessages
        )
        XCTAssertEqual(
            secondRound.filter { $0.role == MessageRole.user }.count,
            0,
            "已投递信封不得再次折入"
        )
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == MessageRole.user }.count,
            2,
            "内存 user 消息恰好 2 条（不因重复边界翻倍）"
        )
    }

    // MARK: - 6. 纯文本终态也要给进行中的追加任务一个消费边界

    func testPlainTextTurnDrainsFollowupBeforeFinishing() async {
        let provider = PlainTextProvider()
        let mailbox = OneShotMailboxDrain(
            message: UIMessage.companion.user(prompt: "[mailbox NEW_TASK from /root]\n用户追加任务")
        )
        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: [:],
            configuration: .init(maxSteps: 3, honorApprovalPause: false)
        )

        let result = await engine.run(
            providerSetting: makeProviderSetting(),
            messages: [UIMessage.companion.user(prompt: "原始任务")],
            params: makeParams(),
            mailboxDrain: { mailbox.next() }
        )

        XCTAssertEqual(provider.callCount, 2, "纯文本首轮收到追加任务后必须再请求一轮")
        XCTAssertTrue(
            provider.recordedMessages[1].contains { $0.toText() == "[mailbox NEW_TASK from /root]\n用户追加任务" },
            "下一轮 provider upload 必须包含追加任务"
        )
        XCTAssertEqual(result.messages.last?.toText(), "已消费追加任务")
        XCTAssertFalse(result.hitStepLimit)
    }
}
