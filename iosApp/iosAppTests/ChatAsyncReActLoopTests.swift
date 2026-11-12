import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatAsyncReActLoopTests: XCTestCase {

    private final class ImmediateAuxiliaryProvider: IOSAgentTextProvider, @unchecked Sendable {
        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            IOSChatForegroundFixtures.chunk(with: nil)
        }
    }

    private final class ControlledStreamingProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var chunkHandler: (@Sendable (MessageChunk) -> Void)?
        private var completion: (@Sendable () -> Void)?
        private var starts = 0
        private var recordedMessages: [[UIMessage]] = []

        var ready: Bool { lock.withLock { chunkHandler != nil } }
        var callCount: Int { lock.withLock { starts } }
        var lastUploadedMessages: [UIMessage] { lock.withLock { recordedMessages.last ?? [] } }
        func generateText(providerSetting: ProviderSetting, messages: [UIMessage],
                          params: TextGenerationParams) async throws -> MessageChunk {
            IOSChatForegroundFixtures.chunk(with: nil)
        }
        func streamText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams,
                        onChunk: @escaping @Sendable (MessageChunk) -> Void,
                        onComplete: @escaping @Sendable () -> Void,
                        onError: @escaping @Sendable (KotlinThrowable) -> Void) -> Kotlinx_coroutines_coreJob? {
            lock.withLock {
                starts += 1
                recordedMessages.append(messages)
                chunkHandler = onChunk
                completion = onComplete
            }
            return nil
        }
        func send(_ message: UIMessage) {
            let chunk = MessageChunk(id: UUID().uuidString, model: "test-model",
                choices: [UIMessageChoice(index: 0, delta: message, message: nil, finishReason: nil)], usage: nil)
            lock.withLock { chunkHandler }?(chunk)
        }
        func finish() {
            let done = lock.withLock { () -> (@Sendable () -> Void)? in
                let done = completion
                completion = nil
                chunkHandler = nil
                return done
            }
            done?()
        }
    }

    private final class ScriptedAsyncLoopProvider: IOSAgentTextProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var gatedLabels: Set<String>
        private var toolRoundLabels: Set<String>
        private var callCounts: [String: Int] = [:]
        private var startedLabels: Set<String> = []
        private var uploadedPromptSnapshots: [String: [[String]]] = [:]

        init(gatedLabels: Set<String> = [], toolRoundLabels: Set<String> = []) {
            self.gatedLabels = gatedLabels
            self.toolRoundLabels = toolRoundLabels
        }

        func hasStarted(_ label: String) -> Bool {
            lock.withLock { startedLabels.contains(label) }
        }

        func callCount(for label: String) -> Int {
            lock.withLock { callCounts[label, default: 0] }
        }

        func uploadedPrompts(for label: String) -> [[String]] {
            lock.withLock { uploadedPromptSnapshots[label] ?? [] }
        }

        func release(_ label: String) {
            lock.withLock {
                _ = gatedLabels.remove(label)
            }
        }

        private func classifyLabel(from messages: [UIMessage]) -> String {
            let userTexts = messages
                .filter { $0.role == MessageRole.user }
                .map { $0.toText() }
            for text in userTexts.reversed() {
                if text.contains("TASK_C") { return "C" }
                if text.contains("TASK_B") { return "B" }
                if text.contains("TASK_A") { return "A" }
            }
            return "UNKNOWN"
        }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            let label = classifyLabel(from: messages)
            let userTexts = messages
                .filter { $0.role == MessageRole.user }
                .map { $0.toText() }
            let round = lock.withLock { () -> Int in
                startedLabels.insert(label)
                let next = callCounts[label, default: 0] + 1
                callCounts[label] = next
                uploadedPromptSnapshots[label, default: []].append(userTexts)
                return next
            }

            if round == 1, lock.withLock({ toolRoundLabels.contains(label) }) {
                while lock.withLock({ gatedLabels.contains("\(label)_ROUND1") }) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                return IOSChatForegroundFixtures.chunk(
                    with: IOSChatForegroundFixtures.assistantMessage(parts: [
                        UIMessagePart.Text(text: "\(label) working on step 1", metadata: nil),
                        UIMessagePart.Tool(
                            toolCallId: "tool-\(label)-1",
                            toolName: "tool_search",
                            input: #"{"query":"status","limit":3}"#,
                            output: [],
                            approvalState: ToolApprovalState.Auto.shared,
                            streamIndex: nil,
                            metadata: nil
                        )
                    ]),
                    finishReason: "tool_calls"
                )
            }

            while lock.withLock({ gatedLabels.contains(label) }) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            return IOSChatForegroundFixtures.chunk(
                with: IOSChatForegroundFixtures.assistantText("\(label) final reply")
            )
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ChatAsyncReActLoopTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSharedSettings(defaults: UserDefaults) -> IOSSharedSettingsStore {
        var credentials: [String: String] = [:]
        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { credentials[$0] },
            storeCredential: { credentials[$0] = $1; return true },
            deleteCredential: { credentials.removeValue(forKey: $0); return true }
        )
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Async loop test",
            apiKey: "sk-test",
            baseUrl: "https://example.test/v1",
            modelName: "Async loop model",
            modelId: "gpt-async-loop-test"
        )
        let added = sharedSettings.addProvider(provider)
        let chatModel = added.models.first { $0.type == ModelType.chat }!
        sharedSettings.setCurrentChatModelId(chatModel.id.description())
        return sharedSettings
    }

    private func makeStore() throws -> (IOSConversationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatAsyncReActLoopTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (IOSConversationStore(baseDirectory: directory), directory)
    }

    private func makeViewModel(
        defaults: UserDefaults,
        sharedSettings: IOSSharedSettingsStore,
        store: IOSConversationStore
    ) -> ChatViewModel {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("async-react-loop-\(UUID().uuidString).db")
            .path
        let db = IosDatabaseFactory.shared.createDatabase(atFilePath: dbPath)
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(
                userDefaults: defaults,
                storageKey: "async-react-loop-settings-\(UUID().uuidString)"
            ),
            sharedSettings: sharedSettings,
            searchTransport: IOSForegroundNoopSearchTransport(),
            autoGenerateResponses: true,
            auxiliaryTextProvider: ImmediateAuxiliaryProvider(),
            agentRuntimeDao: db.agentRuntimeDao()
        )
        viewModel.conversationStore = store
        return viewModel
    }

    private func waitForCondition(
        timeoutSeconds: Double = 10,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func testNewTaskBaselineStripsHistoryInternalsWithoutChangingTimeline() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeDefaults()
        let viewModel = makeViewModel(defaults: defaults, sharedSettings: makeSharedSettings(defaults: defaults), store: store)
        let run = ChatConversationRun(conversationId: nil)
        let oldUser = UIMessage.companion.user(prompt: "旧问题")
        let newUser = UIMessage.companion.user(prompt: "新问题")
        let now = chatNowLocalDateTime()
        let instant = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 1_700_000_000_000)
        let reasoning = UIMessagePart.Reasoning(reasoning: "历史推理", createdAt: instant, finishedAt: instant, metadata: nil)
        let tool = UIMessagePart.Tool(toolCallId: "old-tool", toolName: "search_web", input: "{\"secret\":true}",
            output: [UIMessagePart.Text(text: "历史工具结果", metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
        let mixed = UIMessage(id: KotlinUuid.companion.random(), role: MessageRole.assistant,
            parts: [UIMessagePart.Text(text: "历史可见回答", metadata: nil), reasoning, tool,
                    UIMessagePart.Image(url: "https://example.test/a.png", metadata: nil),
                    UIMessagePart.Text(text: "  ", metadata: nil)],
            annotations: [], createdAt: now, finishedAt: now, modelId: nil, usage: nil, translation: nil)
        let hidden = UIMessage(id: KotlinUuid.companion.random(), role: MessageRole.assistant,
            parts: [reasoning, tool], annotations: [], createdAt: now, finishedAt: now,
            modelId: nil, usage: nil, translation: nil)
        let live = IOSChatForegroundFixtures.assistantText("正在运行的其他任务")
        let liveSlot = ChatAsyncTaskSlot(conversationId: nil, inputDigest: "live", anchorUserMessageId: nil,
            phoneControlUserInitiated: false, providerSetting: IOSChatForegroundFixtures.makeProviderSetting(),
            params: IOSChatForegroundFixtures.makeParams(toolNames: []), toolExposureBridge: nil,
            recipeCatalogSnapshot: nil, baselineMessages: [])
        liveSlot.generatedMessages = [live]
        liveSlot.generatedMessageIds = [ChatMessageProjector.messageId(for: live)]
        liveSlot.isQueuedForConcurrencySlot = true
        run.registerSlot(liveSlot)
        run.state.messages = [oldUser, mixed, hidden, live, newUser]

        let baseline = viewModel.buildTaskBaselineMessages(in: run, anchorUserMessageId: ChatMessageProjector.messageId(for: newUser))
        XCTAssertEqual(baseline.map { ChatMessageProjector.messageId(for: $0) },
                       [oldUser, mixed, newUser].map { ChatMessageProjector.messageId(for: $0) })
        XCTAssertEqual(baseline[1].parts.count, 2)
        XCTAssertTrue(baseline[1].parts[0] is UIMessagePart.Text)
        XCTAssertTrue(baseline[1].parts[1] is UIMessagePart.Image)
        XCTAssertTrue(run.state.messages[1] === mixed)
        XCTAssertEqual(run.state.messages[1].parts.count, 5, "原始界面及历史不得被改写")
        XCTAssertEqual(run.state.messages.count, 5, "只清洗新任务上传基线")
    }

    func testActualStreamDrivesGlobalStatusAndPartialReply() async throws {
        let scripted = IOSAgentToolEngineTestCase.ParamsRecordingProvider([
            IOSChatForegroundFixtures.assistantText("他们交情深厚。<amber-continue>梳理二人的交往|分析共同经历|整理友谊细节</amber-continue>"),
            IOSChatForegroundFixtures.assistantText("他们相互支持，交往多年。")
        ])
        let directEngine = IOSAgentToolEngine(provider: scripted, executors: [:],
            configuration: .init(fastFirstReasoning: true, routerReasoningName: "OFF", workerReasoningName: "HIGH"))
        let directResult = await directEngine.run(providerSetting: IOSChatForegroundFixtures.makeProviderSetting(),
            messages: [UIMessage.companion.user(prompt: "他们关系如何？")],
            params: IOSChatForegroundFixtures.makeParams(toolNames: []).replacingReasoningLevel(.high))
        XCTAssertEqual(scripted.recordedParams.map(\.reasoningLevel), [.off, .high])
        XCTAssertEqual(directResult.messages.filter { $0.role == .assistant }.count, 2)
        XCTAssertFalse(directResult.messages.contains { $0.toText().contains("<amber-") || $0.toText().contains("本轮续答指令") })
        XCTAssertTrue(scripted.recordedMessages.last?.contains { $0.toText().contains("本轮续答指令") } ?? false)
        let simpleProvider = IOSAgentToolEngineTestCase.ParamsRecordingProvider([
            IOSChatForegroundFixtures.assistantText("你好。")
        ])
        let simpleEngine = IOSAgentToolEngine(provider: simpleProvider, executors: [:],
            configuration: .init(fastFirstReasoning: true, routerReasoningName: "LOW", workerReasoningName: "HIGH"))
        let simpleResult = await simpleEngine.run(providerSetting: IOSChatForegroundFixtures.makeProviderSetting(),
            messages: [UIMessage.companion.user(prompt: "你好")],
            params: IOSChatForegroundFixtures.makeParams(toolNames: []).replacingReasoningLevel(.high))
        XCTAssertEqual(simpleProvider.recordedParams.map(\.reasoningLevel), [.low], "不支持 off 时回退 low")
        XCTAssertEqual(simpleResult.messages.filter { $0.role == .assistant }.count, 1, "简单问题不强制二次调用")
        let split = IOSChatForegroundFixtures.assistantMessage(parts: [
            UIMessagePart.Text(text: "结论<amber-", metadata: nil),
            UIMessagePart.Text(text: "continue/>", metadata: nil)
        ])
        XCTAssertEqual(IOSAssistantContinuationMarker.filteredMessage(split, final: false).parts
            .compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(), "结论")
        let tagged = "<amber-continue>梳理二人的交往|分析共同经历|整理友谊细节</amber-continue>"
        let attributeTag = "<amber-continue stages=\"梳理两人交往|正在分析关系\"/>"
        for marker in [tagged, attributeTag, "<amber-continue/>"] {
            for length in 1...marker.count {
                XCTAssertEqual(IOSAssistantContinuationMarker.filteredText("结论" + String(marker.prefix(length)), final: false),
                               "结论", "完整或未闭合的控制标记及阶段都不能闪现在正文")
            }
        }
        let attribute = IOSChatForegroundFixtures.assistantText("结论<amber-continue stages=\"梳理两人交往|正在分析关系\"/>")
        XCTAssertTrue(IOSAssistantContinuationMarker.contains(in: attribute))
        XCTAssertEqual(IOSAssistantContinuationMarker.stages(in: attribute), ["正在梳理两人交往", "正在分析关系"])
        XCTAssertEqual(IOSAssistantContinuationMarker.filteredMessage(attribute, final: true).toText(), "结论")
        XCTAssertEqual(IOSAssistantContinuationMarker.filteredText("结论<amber-continue>未闭合阶段", final: true), "结论")
        XCTAssertEqual(ChatToolStepModel.activeProgressTitle(toolName: "search_web", input: #"{"query":"刘禹锡和柳宗元"}"#),
                       "正在查找「刘禹锡和柳宗元」")
        XCTAssertEqual(ChatToolStepModel.activeProgressTitle(toolName: "scrape_web", input: #"{"url":"https://example.com/article?token=secret"}"#),
                       "正在读取「example.com/article」")
        XCTAssertEqual(ChatToolStepModel.activeProgressTitle(toolName: "spawn_agent", input: #"{"task":"梳理两人交往"}"#),
                       "正在安排「梳理两人交往」")
        XCTAssertNil(ChatToolStepModel.activeProgressTitle(toolName: "search_web", input: #"{"query": "#))

        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()
        let defaults = makeDefaults()
        let settings = makeSharedSettings(defaults: defaults)
        let viewModel = makeViewModel(defaults: defaults, sharedSettings: settings, store: store)
        func updated(_ message: UIMessage, text: String) -> UIMessage {
            UIMessage(id: message.id, role: message.role, parts: [UIMessagePart.Text(text: text, metadata: nil)],
                      annotations: message.annotations, createdAt: message.createdAt, finishedAt: message.finishedAt,
                      modelId: message.modelId, usage: message.usage, translation: message.translation)
        }
        let aUser = UIMessage.companion.user(prompt: "A")
        let aFirst = IOSChatForegroundFixtures.assistantText("A 第一轮")
        let aTail = IOSChatForegroundFixtures.assistantText("A 流式尾部")
        let otherUser = UIMessage.companion.user(prompt: "B")
        let otherReply = IOSChatForegroundFixtures.assistantText("B 独立结果")
        let isolated = ChatConversationRunState(conversationId: nil)
        isolated.messages = [aUser]
        let isolatedSlot = ChatAsyncTaskSlot(conversationId: nil, inputDigest: "test",
            anchorUserMessageId: ChatMessageProjector.messageId(for: aUser), phoneControlUserInitiated: false,
            providerSetting: IOSChatForegroundFixtures.makeProviderSetting(),
            params: IOSChatForegroundFixtures.makeParams(toolNames: []), toolExposureBridge: nil,
            recipeCatalogSnapshot: nil, baselineMessages: [aUser])
        viewModel.spliceTaskTranscript([aUser, aFirst, aTail], for: isolatedSlot, into: isolated)
        isolated.messages.insert(otherUser, at: 0)
        isolated.messages.append(otherReply)
        let updatedTail = updated(aTail, text: "A 流式尾部更新")
        viewModel.spliceTaskProvisionalAssistant(updatedTail, for: isolatedSlot, into: isolated)
        XCTAssertTrue(isolated.messages.contains { $0 === otherReply })
        XCTAssertTrue(isolated.messages.contains { $0 === updatedTail })
        XCTAssertEqual(isolatedSlot.lastSplicedTailIndex, 3, "并发插入后必须重新定位缓存下标")
        let backfilled = updated(aFirst, text: "A 历史结果回填")
        viewModel.spliceTaskTranscript([aUser, backfilled, updatedTail], for: isolatedSlot, into: isolated)
        XCTAssertTrue(isolated.messages.contains { $0 === backfilled }, "权威快照必须保留非尾部回填")
        XCTAssertTrue(isolated.messages.contains { $0 === otherReply }, "并发任务消息不能被覆盖")

        let provider = ControlledStreamingProvider()
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()
        viewModel.inputText = "TASK_A: 流式回复"
        XCTAssertTrue(viewModel.sendMessage())
        XCTAssertFalse(viewModel.messages.contains { $0.role == MessageRole.assistant },
                       "模型输出之前不能伪造助手消息")
        let upload = viewModel.preparedUploadMessagesForTesting([UIMessage.companion.user(prompt: "查询新闻")])
        XCTAssertTrue(upload.contains { $0.role == MessageRole.system &&
            $0.toText().contains("要调用工具时在同轮调用") && $0.toText().contains("<amber-continue>阶段1|阶段2|阶段3</amber-continue>") },
                      "工具前的分段回复应由模型根据运行时指令生成")
        let providerReady = await waitForCondition { provider.ready }
        XCTAssertTrue(providerReady)
        XCTAssertTrue(viewModel.isGenerationActiveForCurrentConversation)

        let timestamp = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 1_700_000_000_000)
        let statusOnly = IOSChatForegroundFixtures.assistantMessage(parts: [
            UIMessagePart.Reasoning(reasoning: "分析", createdAt: timestamp, finishedAt: nil, metadata: nil)
        ])
        let visible = IOSChatForegroundFixtures.assistantText("可见回复")
        let projectionMessages = [aUser, statusOnly, visible]
        let projected = NativeTimelineProjector.build(messages: projectionMessages, event: .assistantStreamDelta,
                                                       isGenerationActive: true)
        XCTAssertTrue(projected.messageEntry(for: ChatMessageProjector.messageId(for: statusOnly))?.isGlobalStatusOnly == true)
        XCTAssertFalse(try XCTUnwrap(projected.messageEntry(for: ChatMessageProjector.messageId(for: visible))).isAssistantContinuation)
        let updatedVisible = updated(visible, text: "可见回复继续")
        let incremental = try XCTUnwrap(NativeTimelineProjector.replacingStreamingTail(
            in: projected, messages: [aUser, statusOnly, updatedVisible], event: .assistantStreamDelta,
            isGenerationActive: true, viewportState: ChatViewportState()))
        let visibleEntry = try XCTUnwrap(incremental.messageEntry(for: ChatMessageProjector.messageId(for: visible)))
        XCTAssertFalse(visibleEntry.isAssistantContinuation)
        XCTAssertFalse(visibleEntry.isGlobalStatusOnly)
        let projectionCache = NativeTimelineProjectionCache()
        let renderStore = ChatRenderStateStore()
        let visibleID = ChatMessageProjector.messageId(for: visible)
        let later = IOSChatForegroundFixtures.assistantText("后续回复")
        let laterUpdated = updated(later, text: "后续回复继续")
        let laterID = ChatMessageProjector.messageId(for: later)
        var requestedRows: [Int] = []
        func cachedProjection(_ messages: [UIMessage], event: ChatEvent, revision: Int) -> NativeTimelineProjection {
            requestedRows = []
            return projectionCache.projection(messages: messages, event: event, sourceRevision: revision,
                startIndex: 0, configurationIssue: nil, isGenerationActive: true, isLoading: false,
                isRecognizingImages: false, contextCompactState: .idle, contextCompactBoundaries: [],
                viewportState: ChatViewportState(), displaySettingSignature: 0, generativeUiSettingSignature: 0,
                renderStateRevision: 0, reasoningLevelLabel: nil, streamedMessageIDs: [laterID],
                renderStateStore: renderStore, variantInfoProvider: { requestedRows.append($0); return nil },
                contentHashProvider: { _, _ in 0 })
        }
        _ = cachedProjection([aUser, statusOnly, visible, later], event: .assistantStreamDelta, revision: 1)
        let cachedTail = cachedProjection([aUser, statusOnly, visible, laterUpdated], event: .assistantStreamDelta, revision: 2)
        XCTAssertEqual(requestedRows, [3], "隐藏状态后的历史续答应继续命中尾行投影缓存")
        XCTAssertFalse(try XCTUnwrap(cachedTail.messageEntry(for: visibleID)).isAssistantContinuation)
        let visibleFormerStatus = updated(statusOnly, text: "原状态变为正文")
        let backfillProjection = cachedProjection([aUser, visibleFormerStatus, visible, laterUpdated], event: .toolResultAppended, revision: 3)
        XCTAssertTrue(try XCTUnwrap(backfillProjection.messageEntry(for: visibleID)).isAssistantContinuation,
                      "历史状态变为正文时须重新计算后续标题")
        let plain = IOSChatForegroundFixtures.assistantText("普通流式正文")
        XCTAssertTrue(IOSAssistantContinuationMarker.filteredMessage(plain, final: false) === plain)
        provider.send(IOSChatForegroundFixtures.assistantMessage(parts: [
            UIMessagePart.Reasoning(reasoning: "正在分析", createdAt: timestamp, finishedAt: nil, metadata: nil)
        ]))
        let thinking = await waitForCondition { viewModel.focusedActiveTask?.activityStage == .thinking }
        XCTAssertTrue(thinking)
        let view = ChatView(settingsStore: viewModel.settingsStore, sharedSettings: settings, viewModel: viewModel)
        XCTAssertEqual(view.timelineActivityState.kind, .thinking)

        provider.send(IOSChatForegroundFixtures.assistantText("他们交情深厚。<amber-con"))
        let replyVisible = await waitForCondition {
            viewModel.focusedActiveTask?.activityStage == .generating &&
                viewModel.messages.contains { $0.toText().contains("他们交情深厚") }
        }
        XCTAssertTrue(replyVisible)
        XCTAssertEqual(view.timelineActivityState.kind, .generating)
        XCTAssertFalse(viewModel.messages.contains { $0.toText().contains("<amber") })
        provider.send(IOSChatForegroundFixtures.assistantText("tinue>梳理二人的交往|分析共同经历|整理友谊细节"))
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(viewModel.messages.contains { $0.toText().contains("<amber") || $0.toText().contains("梳理二人") })
        provider.send(IOSChatForegroundFixtures.assistantText("</amber-continue>"))
        provider.finish()
        let workerStarted = await waitForCondition { provider.callCount == 2 && provider.ready }
        XCTAssertTrue(workerStarted)
        let firstAnswer = try XCTUnwrap(viewModel.messages.first { $0.role == .assistant && $0.toText().contains("他们交情深厚") })
        let status = try XCTUnwrap(view.currentTimelineActivity)
        XCTAssertEqual(status.anchorMessageID, ChatMessageProjector.messageId(for: firstAnswer))
        XCTAssertTrue(status.hasAssistant)
        XCTAssertEqual(status.presentation.title, "正在思考")
        let slot = try XCTUnwrap(viewModel.focusedActiveTask)
        XCTAssertEqual(slot.plannedActivityStages, ["正在梳理二人的交往", "正在分析共同经历", "正在整理友谊细节"])
        let planStart = try XCTUnwrap(slot.stagePlanStartedUptime)
        XCTAssertEqual(ChatTimelineActivity.thoughtTitle(stages: slot.plannedActivityStages, start: planStart, summary: nil, at: planStart), "正在思考")
        XCTAssertEqual(ChatTimelineActivity.thoughtTitle(stages: slot.plannedActivityStages, start: planStart, summary: nil, at: planStart + 1.81), "正在思考 · 梳理二人的交往")
        XCTAssertEqual(ChatTimelineActivity.thoughtTitle(stages: slot.plannedActivityStages, start: planStart, summary: nil, at: planStart + 3.61), "正在思考 · 分析共同经历")
        XCTAssertEqual(ChatTimelineActivity.thoughtTitle(stages: slot.plannedActivityStages, start: planStart, summary: nil, at: planStart + 30), "正在思考 · 整理友谊细节")
        provider.send(IOSChatForegroundFixtures.assistantText("他们多年相互支持。"))
        let detailVisible = await waitForCondition {
            viewModel.messages.filter { $0.role == .assistant }.count >= 2 &&
                viewModel.messages.contains { $0.toText().contains("他们多年相互支持") }
        }
        XCTAssertTrue(detailVisible)
        slot.lastActivityUptime = ProcessInfo.processInfo.systemUptime - 31
        let waitingView = ChatView(settingsStore: viewModel.settingsStore, sharedSettings: settings, viewModel: viewModel)
        XCTAssertEqual(waitingView.currentTimelineActivity?.resolvedPresentation(at: ProcessInfo.processInfo.systemUptime).title, "等待响应")

        provider.finish()
        let finished = await waitForCondition { !viewModel.isGenerationActive }
        XCTAssertTrue(finished)
        XCTAssertTrue(viewModel.messages.contains { $0.toText().contains("他们多年相互支持") })
        XCTAssertFalse(viewModel.messages.contains { $0.toText().contains("<amber-") })
    }

    func testIndependentQuestionsPreserveFirstTokenWaitAndQueuedTasksAtSendEntry() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()
        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let provider = ScriptedAsyncLoopProvider(gatedLabels: ["A", "B"])
        defer { provider.release("A"); provider.release("B") }
        let viewModel = makeViewModel(defaults: defaults, sharedSettings: sharedSettings, store: store)
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.runRegistry.maxConcurrentLocalRuns = 1
        viewModel.reloadFromStore()

        viewModel.inputText = "TASK_A: Synthetic first-token wait"
        XCTAssertTrue(viewModel.sendMessage())
        let startedA = await waitForCondition { provider.hasStarted("A") }
        XCTAssertTrue(startedA)
        let slotA = try XCTUnwrap(viewModel.currentRun.orderedSlots.first)
        XCTAssertTrue(slotA.generatedMessages.allSatisfy { $0.toText().isEmpty && $0.getTools().isEmpty })

        viewModel.inputText = "独立问题：TASK_B: Synthetic queued question"
        XCTAssertTrue(viewModel.sendMessage())
        let queuedB = await waitForCondition { viewModel.currentRun.orderedSlots.count == 2 }
        XCTAssertTrue(queuedB)
        let slotB = try XCTUnwrap(viewModel.currentRun.orderedSlots.last)
        XCTAssertFalse(slotA.isTerminal, "An independent question must not cancel A before its first token")
        XCTAssertTrue(slotB.isQueuedForConcurrencySlot)

        viewModel.inputText = "新任务：TASK_C: Synthetic independent question"
        XCTAssertTrue(viewModel.sendMessage())
        let queuedC = await waitForCondition { viewModel.currentRun.orderedSlots.count == 3 }
        XCTAssertTrue(queuedC)
        XCTAssertFalse(slotA.isTerminal)
        XCTAssertFalse(slotB.isTerminal, "A queued task is not a stalled task")
        XCTAssertTrue(slotB.isQueuedForConcurrencySlot)
        XCTAssertFalse(provider.hasStarted("B"))
        provider.release("A")
        let startedB = await waitForCondition { provider.hasStarted("B") }
        XCTAssertTrue(startedB)
        XCTAssertTrue(viewModel.messages.contains { $0.toText() == "A final reply" })
        provider.release("B")
        let done = await waitForCondition { !viewModel.isGenerationActive }
        XCTAssertTrue(done)
        for label in ["A", "B", "C"] {
            XCTAssertTrue(viewModel.messages.contains { $0.toText() == "\(label) final reply" })
        }
    }

    func testPlainMessageDuringRunningTaskStartsNewIndependentQuestionAndPreservesPositions() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let provider = ScriptedAsyncLoopProvider(
            gatedLabels: ["A"],
            toolRoundLabels: ["A"]
        )
        let viewModel = makeViewModel(defaults: defaults, sharedSettings: sharedSettings, store: store)
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        // 1. Start Task A in the conversation; it finishes tool round 1 and waits in round 2.
        viewModel.inputText = "TASK_A: 整理研究报告"
        XCTAssertTrue(viewModel.sendMessage())
        let aEnteredRound2 = await waitForCondition { provider.callCount(for: "A") >= 2 }
        XCTAssertTrue(aEnteredRound2)
        XCTAssertTrue(viewModel.isGenerationActive)
        XCTAssertNil(viewModel.composerSendBlockReason(for: "独立问题：TASK_B: 顺便回答一个独立问题"))

        // 2. While Task A is still running, send an explicitly independent question B without selecting Task A.
        viewModel.inputText = "独立问题：TASK_B: 顺便回答一个独立问题"
        XCTAssertTrue(viewModel.sendMessage())

        // 3. Task B immediately runs and finishes without waiting for Task A.
        let bFinished = await waitForCondition {
            viewModel.messages.contains { $0.toText().contains("B final reply") }
        }
        XCTAssertTrue(bFinished)
        XCTAssertTrue(viewModel.isGenerationActive, "Task A should still be running while B has already replied")

        // Verify Task B's uploaded context did NOT include Task A's in-flight assistant messages.
        let bPrompts = provider.uploadedPrompts(for: "B").first ?? []
        XCTAssertTrue(bPrompts.contains { $0.contains("TASK_B") })

        // 4. Release Task A and verify A's final answer lands at A's position (before B's user message),
        // while B's reply stays after B's user message.
        provider.release("A")
        let allDone = await waitForCondition { !viewModel.isGenerationActive }
        XCTAssertTrue(allDone)

        let texts = viewModel.messages.map { $0.toText() }
        let idxUserA = try XCTUnwrap(texts.firstIndex { $0.contains("TASK_A") })
        let idxProgressA = try XCTUnwrap(texts.firstIndex { $0.contains("A working on step 1") })
        let idxReplyA = try XCTUnwrap(texts.firstIndex { $0.contains("A final reply") })
        let idxUserB = try XCTUnwrap(texts.firstIndex { $0.contains("TASK_B") })
        let idxReplyB = try XCTUnwrap(texts.firstIndex { $0.contains("B final reply") })
        XCTAssertTrue(idxUserA < idxProgressA && idxProgressA < idxReplyA,
                      "模型中途内容与最终回复分别归位")

        XCTAssertLessThan(idxUserA, idxReplyA, "Task A's reply must follow user message A")
        XCTAssertLessThan(idxReplyA, idxUserB, "Task A's reply must stay in A's slot before user message B")
        XCTAssertLessThan(idxUserB, idxReplyB, "Task B's reply must follow user message B")
    }

    func testExplicitTaskSelectionConsumesFollowupAtReasoningBoundaryAndStopIsolatesTask() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let provider = ScriptedAsyncLoopProvider(
            gatedLabels: ["A_ROUND1", "B"],
            toolRoundLabels: ["A"]
        )
        let viewModel = makeViewModel(defaults: defaults, sharedSettings: sharedSettings, store: store)
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        // Start Task A (held in round 1 before tool result boundary) and Task B (held in round 1).
        viewModel.inputText = "TASK_A: 深度检索"
        XCTAssertTrue(viewModel.sendMessage())
        let aStarted = await waitForCondition { provider.hasStarted("A") }
        XCTAssertTrue(aStarted)
        let runIdA = try XCTUnwrap(viewModel.activeTaskRunIdsForCurrentConversation.first)

        viewModel.inputText = "独立问题：TASK_B: 独立长任务"
        XCTAssertTrue(viewModel.sendMessage())
        let bStarted = await waitForCondition { provider.hasStarted("B") }
        XCTAssertTrue(bStarted)
        let activeIds = viewModel.activeTaskRunIdsForCurrentConversation
        XCTAssertEqual(activeIds.count, 2)
        let runIdB = try XCTUnwrap(activeIds.first { $0 != runIdA })

        // Explicitly select Task A for follow-up (`inputs`).
        viewModel.selectTaskForFollowup(runId: runIdA)
        viewModel.inputText = "补充A：只看最近24小时"
        XCTAssertTrue(viewModel.sendMessage())

        let initialFollowupsA = viewModel.taskFollowups(forRunId: runIdA)
        XCTAssertEqual(initialFollowupsA.count, 1)
        XCTAssertEqual(initialFollowupsA.first?.status, .received)
        XCTAssertFalse(initialFollowupsA.first?.isShownAsExecuted ?? true)

        // Also enqueue a follow-up on Task B, then stop Task B before it can consume the follow-up.
        viewModel.selectTaskForFollowup(runId: runIdB)
        viewModel.inputText = "补充B：未消费前就被停止"
        XCTAssertTrue(viewModel.sendMessage())
        XCTAssertEqual(viewModel.taskFollowups(forRunId: runIdB).first?.status, .received)

        // Stop ONLY Task B: Task B stops and its unconsumed follow-up becomes `.cancelled` (`isShownAsExecuted == false`),
        // while Task A continues!
        XCTAssertTrue(viewModel.cancelGeneration(runId: runIdB))
        let followupsBAfterCancel = viewModel.taskFollowups(forRunId: runIdB)
        XCTAssertEqual(followupsBAfterCancel.first?.status, .cancelled)
        XCTAssertFalse(followupsBAfterCancel.first?.isShownAsExecuted ?? true)
        XCTAssertTrue(viewModel.isTaskActiveOrQueued(runId: runIdA), "Stopping B must not stop A")

        // Now release Task A's round 1 -> tool executes -> at reasoning boundary before round 2,
        // Task A drains its targeted follow-up (`received` -> `consumed`) and finishes!
        provider.release("A_ROUND1")
        let aCompleted = await waitForCondition {
            !viewModel.isTaskActiveOrQueued(runId: runIdA)
        }
        XCTAssertTrue(aCompleted)

        let finalFollowupsA = viewModel.taskFollowups(forRunId: runIdA)
        XCTAssertEqual(finalFollowupsA.first?.status, .consumed)
        XCTAssertTrue(finalFollowupsA.first?.isShownAsExecuted ?? false)
        let round2PromptsA = try XCTUnwrap(provider.uploadedPrompts(for: "A").last)
        XCTAssertTrue(round2PromptsA.contains { $0.contains("补充A：只看最近24小时") })
    }

    func testConcurrencyCapQueuesThirdTaskWithVisiblePlaceholderAndSystemSuspensionInterruptsTruthfully() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let provider = ScriptedAsyncLoopProvider(gatedLabels: ["A", "B", "C"])
        let viewModel = makeViewModel(defaults: defaults, sharedSettings: sharedSettings, store: store)
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        // Start Task A and Task B (filling maxConcurrentLocalRuns = 2).
        viewModel.inputText = "TASK_A"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.inputText = "新任务：TASK_B"
        XCTAssertTrue(viewModel.sendMessage())
        let bothStarted = await waitForCondition {
            provider.hasStarted("A") && provider.hasStarted("B")
        }
        XCTAssertTrue(bothStarted)
        XCTAssertEqual(viewModel.activeForegroundLocalRunCount, 2)

        // Send Task C while 2 local runs are active -> C queues with visible status placeholder.
        viewModel.inputText = "新任务：TASK_C"
        XCTAssertTrue(viewModel.sendMessage())
        XCTAssertFalse(provider.hasStarted("C"), "Task C should be queued while 2 local runs are active")
        XCTAssertTrue(
            viewModel.messages.contains { $0.toText().contains(ChatViewModel.queuedTaskPlaceholderText) },
            "Queued task must display visible queued placeholder"
        )

        // Release Task A -> Task C automatically dequeues, removes placeholder, and starts!
        provider.release("A")
        let cStarted = await waitForCondition { provider.hasStarted("C") }
        XCTAssertTrue(cStarted)
        XCTAssertFalse(
            viewModel.messages.contains { $0.toText().contains(ChatViewModel.queuedTaskPlaceholderText) },
            "Queued placeholder must be removed once Task C starts"
        )

        // Simulate returning to foreground after system suspension without keep-alive lease:
        // running tasks B and C are truthfully interrupted instead of pretending to still be running.
        let interruptedIds = viewModel.reconcileForegroundRunsAfterSystemSuspensionIfNeeded(
            hasValidKeepAliveLease: false
        )
        XCTAssertEqual(interruptedIds.count, 2)
        let settled = await waitForCondition { !viewModel.isGenerationActive }
        XCTAssertTrue(settled)
    }

    func testUpfrontToolAcknowledgmentFormsSeparateBubblesAndKeepsProgressRowVisibleBetweenRounds() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let soulStore = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        let provider = ControlledStreamingProvider()
        let viewModel = makeViewModel(defaults: defaults, sharedSettings: sharedSettings, store: store)
        viewModel.agentSoulStore = soulStore
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        XCTAssertEqual(ChatToolStepModel.friendlyToolTitle("agent_soul_get", executed: true), "查看角色设定")
        XCTAssertEqual(ChatToolStepModel.friendlyToolTitle("agent_soul_update", executed: true), "更新角色设定")
        XCTAssertEqual(ChatToolStepModel.activeProgressTitle(toolName: "agent_soul_update", input: "{}"), "正在更新角色设定")
        XCTAssertEqual(ChatToolStepModel.runningActivityTitle("查看日历事件"), "正在查看日历事件")

        let upload = viewModel.preparedUploadMessagesForTesting([
            UIMessage.companion.user(prompt: "把你自己改成燕云十六声里的赵大哥")
        ])
        let guidanceText = upload
            .filter { $0.role == MessageRole.system }
            .map { $0.toText() }
            .joined(separator: "\n")
        XCTAssertTrue(guidanceText.contains("首轮发出 tool_calls 的同时，必须先输出简短自然的一句口语回应"))
        XCTAssertTrue(guidanceText.contains("严禁复读用户原话"))
        XCTAssertTrue(guidanceText.contains("无需调用工具的闲聊"))

        viewModel.inputText = "把你自己改成燕云十六声里的赵大哥"
        XCTAssertTrue(viewModel.sendMessage())
        let round1Ready = await waitForCondition { provider.callCount == 1 && provider.ready }
        XCTAssertTrue(round1Ready)

        // Round 1 streams Bubble 1 upfront colloquial acknowledgment.
        provider.send(IOSChatForegroundFixtures.assistantText("得令，这就给你拾掇一身赵大哥的行头！"))
        let ackStreaming = await waitForCondition {
            viewModel.focusedActiveTask?.activityStage == .generating &&
                viewModel.messages.contains { $0.role == .assistant && $0.toText().contains("拾掇一身赵大哥的行头") }
        }
        XCTAssertTrue(ackStreaming)

        let view = ChatView(settingsStore: viewModel.settingsStore, sharedSettings: sharedSettings, viewModel: viewModel)
        let streamingAckProj = NativeTimelineProjector.build(
            messages: viewModel.messages,
            event: .assistantStreamDelta,
            isGenerationActive: true
        )
        let ackMessage = try XCTUnwrap(viewModel.messages.first { $0.role == .assistant })
        let ackID = ChatMessageProjector.messageId(for: ackMessage)
        let streamingAckEntry = try XCTUnwrap(streamingAckProj.messageEntry(for: ackID))
        let streamingActivity = try XCTUnwrap(view.currentTimelineActivity)
        XCTAssertEqual(streamingActivity.presentation.kind, .generating)
        XCTAssertFalse(
            streamingActivity.shouldDisplayBelow(streamingAckEntry),
            "当前轮气泡正在吐字时不应在下方垫进度行"
        )

        // Emit agent_soul_update tool call in the same Round 1 turn.
        let soulToolCall = UIMessagePart.Tool(
            toolCallId: "call-soul-1",
            toolName: "agent_soul_update",
            input: #"{"displayName":"赵大哥","tagline":"燕云十六声热心老哥","soulPrompt":"豪爽重情义的北方老哥，开口亲切接地气。","summary":"赵大哥人设"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        provider.send(IOSChatForegroundFixtures.assistantMessage(parts: [soulToolCall]))

        // Verify that while a tool is running below Bubble 1, the progress row IS displayed beneath Bubble 1.
        let toolRunningActivity = ChatTimelineActivity(
            anchorMessageID: ackID,
            hasAssistant: true,
            presentation: .activity(kind: .tool, title: "正在更新角色设定", systemImage: "wrench.and.screwdriver", tint: .amber),
            tool: soulToolCall,
            taskSlot: viewModel.focusedActiveTask,
            plannedStages: [],
            stagePlanStartedUptime: nil,
            liveReasoningSummary: nil,
            tracksTaskLiveness: true,
            showsThought: false
        )
        XCTAssertTrue(
            toolRunningActivity.shouldDisplayBelow(streamingAckEntry),
            "Bubble 1 正文落定后执行工具期间，下方必须继续显示单行动态进度条"
        )

        provider.finish()

        // Tool executes on isolated soulStore and enters Round 2.
        let round2Ready = await waitForCondition { provider.callCount == 2 && provider.ready }
        XCTAssertTrue(round2Ready)
        XCTAssertEqual(soulStore.displayName, "赵大哥")

        // Round 2 system prompt immediately carries the newly updated 赵大哥 Soul persona!
        let round2SystemPrompt = provider.lastUploadedMessages
            .filter { $0.role == MessageRole.system }
            .map { $0.toText() }
            .joined(separator: "\n")
        XCTAssertTrue(round2SystemPrompt.contains("赵大哥"))
        XCTAssertTrue(round2SystemPrompt.contains("豪爽重情义的北方老哥"))

        // Before Bubble 2 emits visible body text, progress row ("正在思考") must remain visible below Bubble 1!
        let round2ThinkingProj = NativeTimelineProjector.build(
            messages: viewModel.messages,
            event: .toolResultAppended,
            isGenerationActive: true
        )
        let settledAckEntry = try XCTUnwrap(round2ThinkingProj.messageEntry(for: ackID))
        let round2ThinkingActivity = try XCTUnwrap(view.currentTimelineActivity)
        XCTAssertEqual(round2ThinkingActivity.anchorMessageID, ackID)
        XCTAssertEqual(round2ThinkingActivity.presentation.title, "正在思考")
        XCTAssertTrue(
            round2ThinkingActivity.shouldDisplayBelow(settledAckEntry),
            "次轮思考期间尚未产出新气泡正文时，Bubble 1 下方必须保持进度条可见"
        )

        // Composer remains non-blocking while background ReAct loop runs.
        XCTAssertNil(viewModel.composerSendBlockReason(for: "顺便问一句"))

        // Round 2 streams Bubble 2 final reply as an independent assistant message.
        provider.send(IOSChatForegroundFixtures.assistantText("哈哈，兄弟！以后有啥事尽管招呼你赵大哥！"))
        let bubble2Streaming = await waitForCondition {
            viewModel.messages.filter { $0.role == .assistant }.count == 2 &&
                viewModel.messages.contains { $0.toText().contains("尽管招呼你赵大哥") }
        }
        XCTAssertTrue(bubble2Streaming)

        let assistantBubbles = viewModel.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantBubbles.count, 2, "首轮接话与工具后的正式结果必须落成两个独立助手气泡")
        let bubble2ID = ChatMessageProjector.messageId(for: assistantBubbles[1])
        XCTAssertNotEqual(ackID, bubble2ID)

        let bubble2Proj = NativeTimelineProjector.build(
            messages: viewModel.messages,
            event: .assistantStreamDelta,
            isGenerationActive: true
        )
        let bubble2Entry = try XCTUnwrap(bubble2Proj.messageEntry(for: bubble2ID))
        XCTAssertTrue(bubble2Entry.isAssistantContinuation)
        let bubble2Activity = try XCTUnwrap(view.currentTimelineActivity)
        XCTAssertEqual(bubble2Activity.anchorMessageID, bubble2ID)
        XCTAssertFalse(
            bubble2Activity.shouldDisplayBelow(bubble2Entry),
            "Bubble 2 开始流式吐出正文后，进度行应立即原位让位给 Bubble 2"
        )

        // Also verify 3-round projection with an intermediate tool-only round keeps continuation consistent.
        let hiddenToolOnly = IOSChatForegroundFixtures.assistantMessage(parts: [soulToolCall])
        let threeRoundProj = NativeTimelineProjector.build(
            messages: [UIMessage.companion.user(prompt: "hi"), assistantBubbles[0], hiddenToolOnly, assistantBubbles[1]],
            event: .assistantStreamDelta,
            isGenerationActive: true
        )
        XCTAssertFalse(try XCTUnwrap(threeRoundProj.messageEntry(for: ackID)).isAssistantContinuation)
        XCTAssertTrue(try XCTUnwrap(threeRoundProj.messageEntry(for: ChatMessageProjector.messageId(for: hiddenToolOnly))).isAssistantContinuation)
        XCTAssertTrue(try XCTUnwrap(threeRoundProj.messageEntry(for: bubble2ID)).isAssistantContinuation)

        provider.finish()
        let completed = await waitForCondition { !viewModel.isGenerationActive }
        XCTAssertTrue(completed)
        XCTAssertNil(view.currentTimelineActivity)
    }

    func testCommentaryCoalescesSameStageFragmentsPreservesPublishedProseAndSplitsOnMilestone() throws {
        let userPrompt = UIMessage.companion.user(prompt: "帮我检查项目配置并核对线上状态")
        let coalescer = ChatTaskCommentaryCoalescer()

        func makeAssistant(text: String, toolName: String? = nil, toolId: String = "call-1") -> UIMessage {
            var parts: [UIMessagePart] = []
            if !text.isEmpty {
                parts.append(UIMessagePart.Text(text: text, metadata: nil))
            }
            if let toolName {
                parts.append(
                    UIMessagePart.Tool(
                        toolCallId: toolId,
                        toolName: toolName,
                        input: "{}",
                        output: [],
                        approvalState: ToolApprovalState.Auto.shared,
                        streamIndex: nil,
                        metadata: nil
                    )
                )
            }
            return IOSChatForegroundFixtures.assistantMessage(parts: parts)
        }

        // 1. 首轮先接话 + 调工具 (workspace_read -> workspace 阶段)：保留首条自然回应 Bubble 1
        let ackBubble = makeAssistant(text: "好的，我先帮你读取本地配置文件。", toolName: "workspace_read", toolId: "c-1")
        let ackBubbleID = ChatMessageProjector.messageId(for: ackBubble)

        // 2. Round 2 同阶段重复陪聊（零信息增量）：应被抑制正文，只保留隐藏 tool 调用，不新增重复正文气泡
        let dupBubble = makeAssistant(text: "好的，我先帮你读取本地配置文件。", toolName: "workspace_read", toolId: "c-2")
        let dupBubbleID = ChatMessageProjector.messageId(for: dupBubble)

        // 3. Round 3 & Round 4 同阶段（仍是 workspace 阶段）两段碎片化中途说明：合并成该阶段的一条完整想法，不每步新建气泡
        let frag1 = makeAssistant(text: "主配置文件已读完，发现端口映射有改动。", toolName: "workspace_read", toolId: "c-3")
        let frag1ID = ChatMessageProjector.messageId(for: frag1)
        let frag2 = makeAssistant(text: "顺便把备份配置也比对了一下，两边一致。", toolName: "workspace_list", toolId: "c-4")
        let frag2ID = ChatMessageProjector.messageId(for: frag2)

        // 4. Round 5 切换到新阶段（search_web -> web_research 阶段）：关键阶段切换产出新的独立说明气泡
        let stage2Bubble = makeAssistant(text: "本地配置核对完毕，现在切到线上接口核查实时状态。", toolName: "search_web", toolId: "c-5")
        let stage2ID = ChatMessageProjector.messageId(for: stage2Bubble)

        // 5. Round 6 最终答复（无 tool_calls）：独立成最终结果气泡，所有前序已上屏正文气泡完整保留
        let finalBubble = makeAssistant(text: "全部核查完成：本地与线上配置均正常，无需额外修复。")
        let finalID = ChatMessageProjector.messageId(for: finalBubble)

        let rawMessages: [UIMessage] = [
            userPrompt,
            ackBubble,
            dupBubble,
            frag1,
            frag2,
            stage2Bubble,
            makeAssistant(text: "Synthetic web follow-up detail", toolName: "search_web", toolId: "c-6"),
            finalBubble
        ]
        let coalesced = coalescer.coalesce(messages: rawMessages)
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeDefaults()
        let viewModel = makeViewModel(defaults: defaults, sharedSettings: makeSharedSettings(defaults: defaults), store: store)
        let state = viewModel.currentRun.state
        state.messages = [userPrompt]
        let slot = ChatAsyncTaskSlot(
            conversationId: state.conversationId, inputDigest: "synthetic-stage-regression",
            anchorUserMessageId: ChatMessageProjector.messageId(for: userPrompt), phoneControlUserInitiated: false,
            providerSetting: IOSChatForegroundFixtures.makeProviderSetting(),
            params: IOSChatForegroundFixtures.makeParams(toolNames: []), toolExposureBridge: nil,
            recipeCatalogSnapshot: nil, baselineMessages: [userPrompt]
        )
        viewModel.spliceTaskTranscript(rawMessages, for: slot, into: state)
        let expectedStage = "本地配置核对完毕，现在切到线上接口核查实时状态。\n\nSynthetic web follow-up detail"
        XCTAssertEqual(slot.currentTranscript.first { $0.id == stage2Bubble.id }?.toText().trimmingCharacters(in: .whitespacesAndNewlines), expectedStage)
        XCTAssertEqual(state.messages.first { $0.id == stage2Bubble.id }?.toText().trimmingCharacters(in: .whitespacesAndNewlines), expectedStage)
        viewModel.spliceTaskTranscript(slot.currentTranscript, for: slot, into: state)
        XCTAssertEqual(slot.currentTranscript.first { $0.id == stage2Bubble.id }?.toText().trimmingCharacters(in: .whitespacesAndNewlines), expectedStage)

        // 验证首轮自然回应气泡完整保留，未被后续状态或阶段说明覆盖
        let ackAfter = coalesced.first { ChatMessageProjector.messageId(for: $0) == ackBubbleID }
        XCTAssertEqual(ackAfter?.toText().trimmingCharacters(in: .whitespacesAndNewlines), "好的，我先帮你读取本地配置文件。")

        // 验证同阶段重复陪聊被剥离正文但保留工具调用
        let dupAfter = coalesced.first { ChatMessageProjector.messageId(for: $0) == dupBubbleID }
        XCTAssertEqual(dupAfter?.toText().trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(dupAfter?.getTools().count, 1, "去重陪聊正文时不得丢失本轮工具调用")

        // 验证同阶段两段碎片说明收敛进同一个阶段说明气泡（frag1），frag2 转为仅保留工具调用的状态消息
        let frag1After = coalesced.first { ChatMessageProjector.messageId(for: $0) == frag1ID }
        XCTAssertEqual(
            frag1After?.toText().trimmingCharacters(in: .whitespacesAndNewlines),
            "主配置文件已读完，发现端口映射有改动。\n\n顺便把备份配置也比对了一下，两边一致。",
            "同阶段碎片化说明应收敛进同一阶段说明气泡"
        )
        let frag2After = coalesced.first { ChatMessageProjector.messageId(for: $0) == frag2ID }
        XCTAssertEqual(frag2After?.toText().trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(frag2After?.getTools().count, 1)

        // 验证阶段切换（workspace -> web_research）与最终答复各自独立成泡
        let stage2After = coalesced.first { ChatMessageProjector.messageId(for: $0) == stage2ID }
        XCTAssertEqual(stage2After?.toText().trimmingCharacters(in: .whitespacesAndNewlines), "本地配置核对完毕，现在切到线上接口核查实时状态。\n\nSynthetic web follow-up detail")
        let finalAfter = coalesced.first { ChatMessageProjector.messageId(for: $0) == finalID }
        XCTAssertEqual(finalAfter?.toText().trimmingCharacters(in: .whitespacesAndNewlines), "全部核查完成：本地与线上配置均正常，无需额外修复。")

        let visibleProseBubbles = coalesced.filter {
            $0.role == MessageRole.assistant && !$0.toText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        XCTAssertEqual(
            visibleProseBubbles.count,
            4,
            "最终时间线应包含：1 首轮接话 + 1 本地阶段合并说明 + 1 线上阶段切换说明 + 1 最终答复"
        )
    }

    func testSameIDProvisionalVisibleGrowthResetsKeepaliveButDuplicateBlankAndReasoningDoNot() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeDefaults()
        let viewModel = makeViewModel(defaults: defaults, sharedSettings: makeSharedSettings(defaults: defaults), store: store)
        let state = viewModel.currentRun.state
        let user = UIMessage.companion.user(prompt: "核查进展")
        state.messages = [user]
        let slot = ChatAsyncTaskSlot(conversationId: state.conversationId, inputDigest: "visible-growth",
            anchorUserMessageId: ChatMessageProjector.messageId(for: user), phoneControlUserInitiated: false,
            providerSetting: IOSChatForegroundFixtures.makeProviderSetting(),
            params: IOSChatForegroundFixtures.makeParams(toolNames: []), toolExposureBridge: nil,
            recipeCatalogSnapshot: nil, baselineMessages: [user])
        viewModel.currentRun.registerSlot(slot)
        let bindings = viewModel.makeGenerationBindings(state: state, taskSlot: slot)
        let first = IOSChatForegroundFixtures.assistantText("已完成 A。\n\n")
        func snapshot(_ text: String, reasoning: String? = nil) -> UIMessage {
            var parts: [UIMessagePart] = [UIMessagePart.Text(text: text, metadata: nil)]
            if let reasoning {
                parts.append(UIMessagePart.Reasoning(reasoning: reasoning, createdAt: KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0), finishedAt: nil, metadata: nil))
            }
            return UIMessage(id: first.id, role: first.role, parts: parts, annotations: first.annotations,
                createdAt: first.createdAt, finishedAt: nil, modelId: first.modelId, usage: first.usage, translation: first.translation)
        }
        XCTAssertTrue(bindings.setProvisionalAssistant(snapshot("已完成 A。\n\n")))
        let growth = snapshot("已完成 A。\n\n已完成 B。\n\n")
        slot.lastUserVisibleProgressUptime = 1
        slot.hasEmittedKeepaliveInCurrentSilenceWindow = true
        XCTAssertTrue(bindings.setProvisionalAssistant(growth))
        XCTAssertGreaterThan(slot.lastUserVisibleProgressUptime, 1, "同 ID 可见正文增长必须刷新保活时钟")
        XCTAssertFalse(slot.hasEmittedKeepaliveInCurrentSilenceWindow)

        slot.lastUserVisibleProgressUptime = 2
        slot.hasEmittedKeepaliveInCurrentSilenceWindow = true
        XCTAssertTrue(bindings.setProvisionalAssistant(growth))
        XCTAssertTrue(bindings.setProvisionalAssistant(snapshot(growth.toText(), reasoning: "内部推理继续增长")))
        XCTAssertEqual(slot.lastUserVisibleProgressUptime, 2, "重复正文和 reasoning 不算新进展")
        XCTAssertTrue(slot.hasEmittedKeepaliveInCurrentSilenceWindow)
        bindings.setMessages([user, snapshot(growth.toText(), reasoning: "相同正文权威快照")])
        XCTAssertEqual(slot.lastUserVisibleProgressUptime, 2, "快路径后重复的权威快照也不能刷新时钟")

        XCTAssertTrue(bindings.setProvisionalAssistant(snapshot("   \n")))
        XCTAssertEqual(slot.lastUserVisibleProgressUptime, 2, "空白正文不得刷新时钟")
        XCTAssertTrue(slot.hasEmittedKeepaliveInCurrentSilenceWindow)
        XCTAssertEqual(state.messages.last?.toText().trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testKeepaliveFiresOnceAfter60sSilenceResetsOnMeaningfulProgressAndStopsOnTerminalOrFailure() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeDefaults()
        let viewModel = makeViewModel(defaults: defaults, sharedSettings: makeSharedSettings(defaults: defaults), store: store)

        let t0: TimeInterval = 1_000.0
        let userMsg = UIMessage.companion.user(prompt: "执行耗时分析任务")
        let userID = ChatMessageProjector.messageId(for: userMsg)
        let ackMsg = IOSChatForegroundFixtures.assistantText("收到，我先开始分析。")
        let state = viewModel.currentRun.state
        state.messages = [userMsg, ackMsg]

        let slot = ChatAsyncTaskSlot(
            slotId: "task-keepalive-1",
            conversationId: state.conversationId,
            inputDigest: "keepalive-digest",
            anchorUserMessageId: userID,
            phoneControlUserInitiated: false,
            providerSetting: IOSChatForegroundFixtures.makeProviderSetting(),
            params: IOSChatForegroundFixtures.makeParams(toolNames: []),
            toolExposureBridge: nil,
            recipeCatalogSnapshot: nil,
            baselineMessages: [userMsg]
        )
        slot.generatedMessages = [ackMsg]
        slot.generatedMessageIds = [ChatMessageProjector.messageId(for: ackMsg)]
        slot.currentTranscript = [userMsg, ackMsg]
        slot.recordMeaningfulUserVisibleProgress(at: t0)
        viewModel.currentRun.registerSlot(slot)

        // 1. 30s 内部活跃心跳（lastActivityUptime）与轮询工具不得刷新用户可见进展时钟（lastUserVisibleProgressUptime），且未满 60s 不发保活
        slot.lastActivityUptime = t0 + 30.0
        XCTAssertEqual(slot.lastUserVisibleProgressUptime, t0, "内部流心跳不得刷新用户可见进展时钟")
        XCTAssertNil(
            viewModel.evaluateTaskKeepaliveIfNeeded(for: slot, in: state, now: t0 + 59.0),
            "未满 60 秒静默窗口不得触发保活正文"
        )

        // 2. 满 60s 无用户可见进展：触发且仅触发 1 条坦诚保活正文气泡，不编造百分比或假完成
        let firstKeepalive = viewModel.evaluateTaskKeepaliveIfNeeded(for: slot, in: state, now: t0 + 60.5)
        XCTAssertNotNil(firstKeepalive, "超过 60 秒无用户可见进展时应发送一条保活说明")
        XCTAssertEqual(firstKeepalive?.toText(), ChatAsyncTaskSlot.keepaliveDefaultText)
        let keepaliveBubblesAfterFirst = state.messages.filter {
            $0.role == MessageRole.assistant && $0.toText() == ChatAsyncTaskSlot.keepaliveDefaultText
        }
        XCTAssertEqual(keepaliveBubblesAfterFirst.count, 1)

        // 3. 同一静默窗口内（90s、130s）绝不重复刷屏
        XCTAssertNil(
            viewModel.evaluateTaskKeepaliveIfNeeded(for: slot, in: state, now: t0 + 90.0),
            "同一静默窗口最多只允许 1 条保活正文"
        )
        XCTAssertNil(
            viewModel.evaluateTaskKeepaliveIfNeeded(for: slot, in: state, now: t0 + 130.0),
            "未发生新的真实进展前不得发送第二条保活正文"
        )
        XCTAssertEqual(
            state.messages.filter { $0.role == MessageRole.assistant && $0.toText() == ChatAsyncTaskSlot.keepaliveDefaultText }.count,
            1
        )

        // 4. 发生真实用户可见进展（140s）后重置窗口：195s（距新进展 55s）不触发，201s（距新进展 61s）允许新窗口触发一次
        slot.recordMeaningfulUserVisibleProgress(at: t0 + 140.0)
        XCTAssertFalse(slot.hasEmittedKeepaliveInCurrentSilenceWindow)
        XCTAssertNil(
            viewModel.evaluateTaskKeepaliveIfNeeded(for: slot, in: state, now: t0 + 195.0)
        )
        let secondKeepalive = viewModel.evaluateTaskKeepaliveIfNeeded(for: slot, in: state, now: t0 + 201.0)
        XCTAssertNotNil(secondKeepalive, "新进展重置静默窗口后再次超过 60 秒可触发新一轮保活")
        XCTAssertEqual(
            state.messages.filter { $0.role == MessageRole.assistant && $0.toText() == ChatAsyncTaskSlot.keepaliveDefaultText }.count,
            2
        )

        // 5. 审批等待、工具失败或终态时：立即抑制保活，不覆盖错误或完成态
        slot.recordMeaningfulUserVisibleProgress(at: t0 + 210.0)
        slot.activityStage = .waitingForConfirmation
        XCTAssertNil(
            viewModel.evaluateTaskKeepaliveIfNeeded(for: slot, in: state, now: t0 + 280.0),
            "等待用户确认/审批期间不得发送通用保活说明"
        )
        slot.activityStage = .runningTool
        slot.explicitFailureOrStallReason = "tool_failed"
        XCTAssertNil(
            viewModel.evaluateTaskKeepaliveIfNeeded(for: slot, in: state, now: t0 + 280.0),
            "已发生明确失败或阻断时应展示阻断，不得发通用保活掩盖"
        )
        slot.explicitFailureOrStallReason = nil
        slot.isTerminal = true
        slot.activityStage = .completed
        XCTAssertNil(
            viewModel.evaluateTaskKeepaliveIfNeeded(for: slot, in: state, now: t0 + 360.0),
            "任务完成后不得再触发任何保活说明"
        )
    }

    func testSingleLineStatusMergesAcrossContinuationStagesIgnoresStaleOutOfOrderEventsAndCleansUpOnTerminalOrSwitch() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let viewModel = makeViewModel(defaults: defaults, sharedSettings: sharedSettings, store: store)
        let run = viewModel.currentRun
        let state = run.state

        let timestamp = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 1_700_000_000_000)
        let u1 = UIMessage.companion.user(prompt: "请并行核查各模块的编译耗时与缓存命中率")
        let u1ID = ChatMessageProjector.messageId(for: u1)
        let thinkingStub1 = IOSChatForegroundFixtures.assistantMessage(parts: [
            UIMessagePart.Reasoning(reasoning: "正在规划检索方向", createdAt: timestamp, finishedAt: nil, metadata: nil)
        ])
        let thinkingStub1ID = ChatMessageProjector.messageId(for: thinkingStub1)
        state.messages = [u1, thinkingStub1]

        // 1. 合成 Slot 1：尚无正文的 queued/thinking 任务仍是合法运行态。
        let slot1 = ChatAsyncTaskSlot(
            slotId: "slot-stalled-1",
            conversationId: state.conversationId,
            inputDigest: "digest-1",
            anchorUserMessageId: u1ID,
            phoneControlUserInitiated: false,
            providerSetting: IOSChatForegroundFixtures.makeProviderSetting(),
            params: IOSChatForegroundFixtures.makeParams(toolNames: []),
            toolExposureBridge: nil,
            recipeCatalogSnapshot: nil,
            baselineMessages: [u1]
        )
        slot1.isQueuedForConcurrencySlot = true
        slot1.activityStage = .thinking
        slot1.generatedMessages = [thinkingStub1]
        slot1.generatedMessageIds = [thinkingStub1ID]
        slot1.currentTranscript = [u1, thinkingStub1]
        run.registerSlot(slot1)
        let slot1Bindings = viewModel.makeGenerationBindings(state: state, taskSlot: slot1)

        // 2. 新独立任务不能退休 live Slot 1；只有显式终态后才清理其纯状态占位。
        let u2 = UIMessage.companion.user(prompt: "继续执行并同步当前阶段状态")
        let u2ID = ChatMessageProjector.messageId(for: u2)
        state.messages.append(u2)
        let slot2 = ChatAsyncTaskSlot(
            slotId: "slot-active-2",
            conversationId: state.conversationId,
            inputDigest: "digest-2",
            anchorUserMessageId: u2ID,
            phoneControlUserInitiated: false,
            providerSetting: IOSChatForegroundFixtures.makeProviderSetting(),
            params: IOSChatForegroundFixtures.makeParams(toolNames: []),
            toolExposureBridge: nil,
            recipeCatalogSnapshot: nil,
            baselineMessages: [u1, u2]
        )
        slot2.isQueuedForConcurrencySlot = true
        viewModel.retireEmptyStalledStatusSlotsBeforeContinuation(in: run, newSlotId: slot2.slotId)
        XCTAssertFalse(slot1.isTerminal)
        viewModel.markTaskSlotTerminal(slot1, in: run)
        viewModel.retireEmptyStalledStatusSlotsBeforeContinuation(in: run, newSlotId: slot2.slotId)
        run.registerSlot(slot2)
        viewModel.refreshLiveTaskMessageIds(in: run)

        XCTAssertTrue(slot1.isTerminal, "显式终态后的空状态占位可清理")
        XCTAssertFalse(
            state.messages.contains { ChatMessageProjector.messageId(for: $0) == thinkingStub1ID },
            "旧轮次的纯状态占位必须移除，不得在 U2 上方残留『正在思考』"
        )

        // 3. 乱序旧事件验证：已收口的 Slot 1 迟到触发 setProvisionalAssistant / setMessages / recordTaskToolActivity 必须被全部拒绝
        let lateGhostStub = IOSChatForegroundFixtures.assistantMessage(parts: [
            UIMessagePart.Reasoning(reasoning: "迟到的旧思考", createdAt: timestamp, finishedAt: nil, metadata: nil)
        ])
        XCTAssertFalse(slot1Bindings.setProvisionalAssistant(lateGhostStub))
        slot1Bindings.setMessages([u1, lateGhostStub])
        slot1Bindings.recordTaskActivity(.thinking)
        slot1Bindings.recordTaskToolActivity("search_web", #"{"query":"旧查询"}"#)
        XCTAssertFalse(
            state.messages.contains { ChatMessageProjector.messageId(for: $0) == ChatMessageProjector.messageId(for: lateGhostStub) },
            "终态/已收口槽位的乱序迟到回调绝不能重新把旧状态插回时间线"
        )

        // 4. 快速连续阶段变化与 commentary 正文气泡保护：
        //    Slot 2 先产出首轮说明气泡，再快速连续切换 preparing -> thinking -> runningTool(1) -> runningTool(2) -> 终态
        slot2.isQueuedForConcurrencySlot = false
        let slot2Bindings = viewModel.makeGenerationBindings(state: state, taskSlot: slot2)
        let commentaryBubble = IOSChatForegroundFixtures.assistantMessage(parts: [
            UIMessagePart.Text(text: "好的，现在立即并行启动子模块核查任务。", metadata: nil),
            UIMessagePart.Tool(
                toolCallId: "spawn-1",
                toolName: "spawn_agent",
                input: #"{"task":"核查模块 A"}"#,
                output: [UIMessagePart.Text(text: #"{"ok":true}"#, metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
        ])
        let commentaryID = ChatMessageProjector.messageId(for: commentaryBubble)
        slot2Bindings.setMessages([u1, u2, commentaryBubble])

        slot2Bindings.recordTaskActivity(.preparing)
        slot2Bindings.recordTaskActivity(.thinking)
        slot2Bindings.recordTaskToolActivity("spawn_agent", #"{"task":"核查模块 A"}"#)
        XCTAssertEqual(slot2.activityStage, .runningTool)
        XCTAssertEqual(slot2.activeToolTitle, "正在安排「核查模块 A」")

        slot2Bindings.recordTaskToolActivity("spawn_agent", #"{"task":"核查模块 B"}"#)
        XCTAssertEqual(slot2.activityStage, .runningTool)
        XCTAssertEqual(slot2.activeToolTitle, "正在安排「核查模块 B」")

        let finalReply = IOSChatForegroundFixtures.assistantText("所有子模块核查任务已派发完毕，正在汇总结果。")
        let finalReplyID = ChatMessageProjector.messageId(for: finalReply)
        slot2Bindings.setMessages([u1, u2, commentaryBubble, finalReply])
        viewModel.markTaskSlotTerminal(slot2, in: run)

        XCTAssertTrue(slot2.isTerminal)
        XCTAssertNil(slot2.activeToolName)
        XCTAssertNil(slot2.activeToolTitle)
        XCTAssertNil(slot2.currentRoundAssistantMessageId)
        XCTAssertTrue(
            state.messages.contains { ChatMessageProjector.messageId(for: $0) == commentaryID },
            "需要持久保留的 commentary 正文气泡在阶段切换与终态收口后必须完整保留"
        )
        XCTAssertTrue(
            state.messages.contains { ChatMessageProjector.messageId(for: $0) == finalReplyID }
        )

        // 5. 云端单行状态：首拍无 workItemId 的 topic 占位并入后续 workItemId，且拒绝乱序旧 seq 事件
        let gateway = MacGatewayStore()
        gateway.ingestCloudDialogueEventsPage(
            MacGatewayCloudDialogueEventsPage(
                items: [
                    MacGatewayCloudDialogueEvent(
                        seq: 10,
                        id: "ce-10",
                        kind: .processEvent,
                        role: "assistant",
                        text: "正在准备任务…",
                        topicId: "topic-merge",
                        workItemId: nil,
                        outcome: nil,
                        soulRevision: nil
                    ),
                    MacGatewayCloudDialogueEvent(
                        seq: 11,
                        id: "ce-11",
                        kind: .processEvent,
                        role: "assistant",
                        text: "正在分析构建依赖…",
                        topicId: "topic-merge",
                        workItemId: "work-merge-1",
                        outcome: nil,
                        soulRevision: nil
                    )
                ],
                nextCursor: 11,
                soulRevision: nil
            ),
            requestedAfter: 0
        )
        XCTAssertNil(
            gateway.cloudDialogueProgressByWorkItem["topic:topic-merge"],
            "首拍 topic 级临时状态必须并入后续分配了 workItemId 的单行状态，不得残留两条"
        )
        XCTAssertEqual(gateway.cloudDialogueProgressByWorkItem.count, 1)
        XCTAssertEqual(gateway.cloudDialogueProgressByWorkItem["work-merge-1"]?.statusLine, "正在分析构建依赖…")
        XCTAssertEqual(gateway.cloudDialogueProgressByWorkItem["work-merge-1"]?.processEventCount, 2)

        // 模拟乱序到达的旧 seq 事件（seq: 9 < lastEventSeq: 11）不得覆盖最新状态
        var outOfOrder = gateway.cloudDialogueProgressByWorkItem["work-merge-1"]!
        let staleEvent = MacGatewayCloudDialogueEvent(
            seq: 9,
            id: "ce-9-stale",
            kind: .processEvent,
            role: "assistant",
            text: "过期的旧阶段状态",
            topicId: "topic-merge",
            workItemId: "work-merge-1",
            outcome: nil,
            soulRevision: nil
        )
        gateway.ingestCloudDialogueEventsPage(
            MacGatewayCloudDialogueEventsPage(items: [staleEvent], nextCursor: 11, soulRevision: nil),
            requestedAfter: 8
        )
        outOfOrder = gateway.cloudDialogueProgressByWorkItem["work-merge-1"]!
        XCTAssertEqual(outOfOrder.statusLine, "正在分析构建依赖…", "乱序旧事件不得覆盖已推进的新阶段状态")
    }

    func testZeroInformationWaitingBubblesStayInSingleLineStatusAcrossLocalAndCloudWhilePreservingFindingsAndFailures() throws {
        // 1. Local ReAct / Phone & Web automation loop:
        let userMsg = UIMessage.companion.user(prompt: "帮我完成当前页面的词块组句并核对结果")
        func assistantRound(text: String, toolName: String? = nil, callId: String, outputJSON: String = #"{"ok":true}"#) -> UIMessage {
            var parts: [UIMessagePart] = []
            if !text.isEmpty {
                parts.append(UIMessagePart.Text(text: text, metadata: nil))
            }
            if let toolName {
                parts.append(
                    UIMessagePart.Tool(
                        toolCallId: callId,
                        toolName: toolName,
                        input: "{}",
                        output: [UIMessagePart.Text(text: outputJSON, metadata: nil)],
                        approvalState: ToolApprovalState.Auto.shared,
                        streamIndex: nil,
                        metadata: nil
                    )
                )
            }
            return IOSChatForegroundFixtures.assistantMessage(parts: parts)
        }

        let r1Ack = assistantRound(text: "好的，我先读取当前题面并开始组句。", toolName: "phone_observe", callId: "p-1")
        let r2Wait = assistantRound(text: "正在处理，请稍候…", toolName: "phone_run_goal", callId: "p-2")
        let r3WaitVariant = assistantRound(text: "仍在继续操作中，请稍等。", toolName: "phone_run_goal", callId: "p-3")
        let r4StageWait = assistantRound(text: "请稍候，正在继续下一步…", toolName: "wm_run_goal", callId: "p-4")
        let r5Finding = assistantRound(text: "检测到弹窗提示词块顺序异常，已重新核对题干。", toolName: "phone_observe", callId: "p-5")
        let r6Final = assistantRound(text: "已完成全部词块选择并通过检查。", callId: "p-6")

        let coalescer = ChatTaskCommentaryCoalescer()
        let coalesced = coalescer.coalesce(messages: [userMsg, r1Ack, r2Wait, r3WaitVariant, r4StageWait, r5Finding, r6Final])

        let visibleLocalBubbles = coalesced.filter {
            $0.role == MessageRole.assistant && !$0.toText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        XCTAssertEqual(
            visibleLocalBubbles.map { $0.toText().trimmingCharacters(in: .whitespacesAndNewlines) },
            [
                "好的，我先读取当前题面并开始组句。",
                "检测到弹窗提示词块顺序异常，已重新核对题干。",
                "已完成全部词块选择并通过检查。"
            ],
            "Zero-information waiting phrases must be stripped to status-only updates instead of spawning or bloating prose bubbles"
        )
        // Tools on suppressed waiting rounds must remain intact for single-line status projection:
        for suppressedID in [r2Wait, r3WaitVariant, r4StageWait].map(ChatMessageProjector.messageId(for:)) {
            let msg = try XCTUnwrap(coalesced.first { ChatMessageProjector.messageId(for: $0) == suppressedID })
            XCTAssertEqual(msg.getTools().count, 1)
            XCTAssertTrue(NativeTimelineProjector.isGlobalStatusOnly(msg), "Suppressed waiting round must project as global status-only")
        }

        // 2. Cloud Main Dialogue stream:
        let gateway = MacGatewayStore()
        gateway.ingestCloudDialogueEventsPage(
            MacGatewayCloudDialogueEventsPage(
                items: [
                    MacGatewayCloudDialogueEvent(seq: 1, id: "u-1", kind: .userMessage, role: "user", text: "检查并执行连续步骤", topicId: "t-lownoise", workItemId: nil, outcome: nil, soulRevision: nil),
                    MacGatewayCloudDialogueEvent(seq: 2, id: "ack:1", kind: .assistantReply, role: "assistant", text: "收到，我来处理…", topicId: "t-lownoise", workItemId: nil, outcome: nil, soulRevision: nil),
                    MacGatewayCloudDialogueEvent(seq: 3, id: "pe-1", kind: .processEvent, role: "assistant", text: "正在读取页面控件…", topicId: "t-lownoise", workItemId: "w-1", outcome: nil, soulRevision: nil),
                    MacGatewayCloudDialogueEvent(seq: 4, id: "wait-1", kind: .assistantReply, role: "assistant", text: "正在处理，请稍候。", topicId: "t-lownoise", workItemId: "w-1", outcome: nil, soulRevision: nil),
                    MacGatewayCloudDialogueEvent(seq: 5, id: "wait-2", kind: .assistantReply, role: "assistant", text: "仍在处理中，请稍等…", topicId: "t-lownoise", workItemId: "w-1", outcome: nil, soulRevision: nil),
                    MacGatewayCloudDialogueEvent(seq: 6, id: "prog-1", kind: .assistantReply, role: "assistant", text: "已完成前 4 个步骤核验，准备最终收口。", topicId: "t-lownoise", workItemId: "w-1", outcome: nil, soulRevision: nil),
                    MacGatewayCloudDialogueEvent(seq: 7, id: "res-1", kind: .taskResult, role: "assistant", text: "全部步骤核验通过。", topicId: "t-lownoise", workItemId: "w-1", outcome: .completed, soulRevision: nil)
                ],
                nextCursor: 7,
                soulRevision: nil
            ),
            requestedAfter: 0
        )

        let cloudAssistantTexts = gateway.cloudDialogueVisibleEvents
            .filter { $0.kind == .assistantReply || $0.kind == .taskResult }
            .map(\.text)
        XCTAssertEqual(
            cloudAssistantTexts,
            [
                "收到，我来处理…",
                "已完成前 4 个步骤核验，准备最终收口。",
                "全部步骤核验通过。"
            ],
            "Duplicate/variant zero-info waiting replies in cloud dialogue must update in-place progress instead of adding prose bubbles"
        )
    }

    func testQueuedTaskExcludesPlaceholderFromDiskSurvivesSwitchAndPreservesAssistantRegenerateVariant() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let provider = ScriptedAsyncLoopProvider(gatedLabels: ["A", "B"])
        let viewModel = makeViewModel(defaults: defaults, sharedSettings: sharedSettings, store: store)
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        // 1. Seed conversation C with one completed user+assistant pair for branch regeneration later.
        let convC = try XCTUnwrap(store.currentConversation?.id)
        viewModel.inputText = "TASK_C seed"
        XCTAssertTrue(viewModel.sendMessage())
        let cSeeded = await waitForCondition {
            !viewModel.isLoading && viewModel.messages.last?.toText() == "C final reply"
        }
        XCTAssertTrue(cSeeded)
        let seededC = await waitForCondition {
            store.currentConversation?.messageNodes.count == 2
        }
        XCTAssertTrue(seededC)

        // 2. Occupy both foreground concurrency slots (maxConcurrentLocalRuns == 2) in convA and convB.
        XCTAssertTrue(viewModel.prepareForConversationChange())
        let createdA = await store.startNewConversationReusingEmpty()
        XCTAssertTrue(createdA)
        let convA = try XCTUnwrap(store.currentConversation?.id)
        viewModel.reloadFromStore()
        viewModel.inputText = "TASK_A hold"
        XCTAssertTrue(viewModel.sendMessage())
        let aStarted = await waitForCondition { provider.hasStarted("A") }
        XCTAssertTrue(aStarted)

        XCTAssertTrue(viewModel.prepareForConversationChange())
        let createdB = await store.startNewConversationReusingEmpty()
        XCTAssertTrue(createdB)
        let convB = try XCTUnwrap(store.currentConversation?.id)
        viewModel.reloadFromStore()
        viewModel.inputText = "TASK_B hold"
        XCTAssertTrue(viewModel.sendMessage())
        let bStarted = await waitForCondition { provider.hasStarted("B") }
        XCTAssertTrue(bStarted)
        XCTAssertEqual(viewModel.activeForegroundLocalRunCount, 2)

        // 3. Send in convD while slots are full -> task queues with synthetic placeholder.
        XCTAssertTrue(viewModel.prepareForConversationChange())
        let createdD = await store.startNewConversationReusingEmpty()
        XCTAssertTrue(createdD)
        let convD = try XCTUnwrap(store.currentConversation?.id)
        viewModel.reloadFromStore()
        viewModel.inputText = "TASK_C queued in D"
        XCTAssertTrue(viewModel.sendMessage())
        XCTAssertTrue(viewModel.messages.contains { $0.toText() == ChatViewModel.queuedTaskPlaceholderText })

        let dUserSaved = await waitForCondition {
            store.currentMessages.contains { $0.toText().contains("TASK_C queued in D") }
        }
        XCTAssertTrue(dUserSaved)
        try await Task.sleep(nanoseconds: 80_000_000)

        let rawDiskMessagesD = await store.messages(for: convD)
        let diskMessagesD = try XCTUnwrap(rawDiskMessagesD)
        XCTAssertFalse(
            diskMessagesD.contains { $0.toText() == ChatViewModel.queuedTaskPlaceholderText },
            "queued synthetic placeholder must never be persisted to disk"
        )

        // Switching away and returning via reloadFromStore must preserve the queued placeholder in memory.
        XCTAssertTrue(viewModel.prepareForConversationChange(to: convA))
        await store.selectConversation(id: convA)
        viewModel.reloadFromStore()
        XCTAssertTrue(viewModel.prepareForConversationChange(to: convD))
        await store.selectConversation(id: convD)
        viewModel.reloadFromStore()
        XCTAssertTrue(
            viewModel.messages.contains { $0.toText() == ChatViewModel.queuedTaskPlaceholderText },
            "reloadFromStore must preserve in-memory queued task state when host is not yet running"
        )

        // Cancel convD's queued task so convC's regeneration will be next in queue.
        viewModel.cancelGeneration()
        XCTAssertFalse(viewModel.isLoading)

        // 4. Switch to convC and regenerate assistant reply (index 1) while A & B still hold all slots.
        XCTAssertTrue(viewModel.prepareForConversationChange(to: convC))
        await store.selectConversation(id: convC)
        viewModel.reloadFromStore()
        let convCSnapshot = try XCTUnwrap(store.currentConversation)
        XCTAssertEqual(convCSnapshot.messageNodes.count, 2)

        let didQueueRegenerate = await viewModel.regenerateImmediately(
            atMessageIndex: 1,
            conversation: convCSnapshot,
            state: viewModel.currentRun.state
        )
        XCTAssertTrue(didQueueRegenerate, "assistant regeneration queued for concurrency must report didStart == true")
        XCTAssertNotNil(
            viewModel.currentRun.state.pendingAssistantRegeneration,
            "queued assistant regeneration must retain pendingAssistantRegeneration until completion"
        )

        provider.release("A")
        let regenFinished = await waitForCondition {
            !viewModel.isLoading && store.variantInfo(forMessageIndex: 1)?.variantCount == 2
        }
        XCTAssertTrue(regenFinished, "dequeued assistant regeneration must append a second variant instead of a linear message")
        XCTAssertEqual(store.currentConversation?.messageNodes.count, 2)

        provider.release("B")
        let allSettled = await waitForCondition { viewModel.activeForegroundLocalRunCount == 0 }
        XCTAssertTrue(allSettled)
    }
}
