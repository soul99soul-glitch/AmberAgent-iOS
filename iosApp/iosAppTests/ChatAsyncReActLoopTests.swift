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
        XCTAssertNil(viewModel.composerSendBlockReason(for: "TASK_B: 顺便回答一个独立问题"))

        // 2. While Task A is still running, send plain message B without selecting Task A.
        viewModel.inputText = "TASK_B: 顺便回答一个独立问题"
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

        viewModel.inputText = "TASK_B: 独立长任务"
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
        viewModel.inputText = "TASK_B"
        XCTAssertTrue(viewModel.sendMessage())
        let bothStarted = await waitForCondition {
            provider.hasStarted("A") && provider.hasStarted("B")
        }
        XCTAssertTrue(bothStarted)
        XCTAssertEqual(viewModel.activeForegroundLocalRunCount, 2)

        // Send Task C while 2 local runs are active -> C queues with visible status placeholder.
        viewModel.inputText = "TASK_C"
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
}
