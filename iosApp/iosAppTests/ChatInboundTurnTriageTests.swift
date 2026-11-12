import XCTest
import UIKit
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatInboundTurnTriageTests: XCTestCase {

    private final class ImmediateAuxiliaryProvider: IOSAgentTextProvider, @unchecked Sendable {
        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            IOSChatForegroundFixtures.chunk(with: nil)
        }
    }

    private final class InspectableLoopProvider: IOSAgentTextProvider, @unchecked Sendable {
        struct RoundRecord {
            let roundIndex: Int
            let messages: [UIMessage]
        }

        private let lock = NSLock()
        private var gatedKeys: Set<String>
        private var toolRoundFirstCallKeys: Set<String>
        private var callCountsByKey: [String: Int] = [:]
        private var totalCallsCount: Int = 0
        private var roundRecordsByKey: [String: [RoundRecord]] = [:]

        init(gatedKeys: Set<String> = [], toolRoundFirstCallKeys: Set<String> = []) {
            self.gatedKeys = gatedKeys
            self.toolRoundFirstCallKeys = toolRoundFirstCallKeys
        }

        var totalCalls: Int {
            lock.withLock { totalCallsCount }
        }

        func callCount(for key: String) -> Int {
            lock.withLock { callCountsByKey[key, default: 0] }
        }

        func records(for key: String) -> [RoundRecord] {
            lock.withLock { roundRecordsByKey[key] ?? [] }
        }

        func release(_ key: String) {
            lock.withLock {
                _ = gatedKeys.remove(key)
            }
        }

        private func classifyKey(from messages: [UIMessage]) -> String {
            let userTexts = messages
                .filter { $0.role == MessageRole.user }
                .map { $0.toText() }
            // Earlier task anchors can remain in history; use the latest task request, ignoring ordinary supplements.
            for text in userTexts.reversed() {
                if text.contains("TASK_A") { return "A" }
                if text.contains("TASK_B") { return "B" }
                if text.contains("TASK_C") { return "C" }
            }
            return "OTHER"
        }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            let key = classifyKey(from: messages)
            let round = lock.withLock { () -> Int in
                totalCallsCount += 1
                let next = callCountsByKey[key, default: 0] + 1
                callCountsByKey[key] = next
                roundRecordsByKey[key, default: []].append(RoundRecord(roundIndex: next, messages: messages))
                return next
            }

            if round == 1, lock.withLock({ toolRoundFirstCallKeys.contains(key) }) {
                while lock.withLock({ gatedKeys.contains("\(key)_ROUND1") }) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                return IOSChatForegroundFixtures.chunk(
                    with: IOSChatForegroundFixtures.assistantMessage(parts: [
                        UIMessagePart.Text(text: "\(key) 第一阶段检索中", metadata: nil),
                        UIMessagePart.Tool(
                            toolCallId: "tool-\(key)-1",
                            toolName: "tool_search",
                            input: #"{"query":"status","limit":2}"#,
                            output: [],
                            approvalState: ToolApprovalState.Auto.shared,
                            streamIndex: nil,
                            metadata: nil
                        )
                    ]),
                    finishReason: "tool_calls"
                )
            }

            while lock.withLock({ gatedKeys.contains(key) }) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            return IOSChatForegroundFixtures.chunk(
                with: IOSChatForegroundFixtures.assistantText("\(key) 最终结论")
            )
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ChatInboundTurnTriageTests-\(UUID().uuidString)"
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
            name: "Inbound triage test",
            apiKey: "sk-test",
            baseUrl: "https://example.test/v1",
            modelName: "Inbound triage model",
            modelId: "gpt-4o"
        )
        let added = sharedSettings.addProvider(provider)
        let chatModel = added.models.first { $0.type == ModelType.chat }!
        _ = sharedSettings.upsertProviderChatModel(providerId: added.id.description(),
            modelUuid: chatModel.id.description(), modelId: chatModel.modelId, displayName: chatModel.displayName,
            contextWindowTokens: nil, modelType: .chat, inputModalities: [.text, .image], headers: [])
        sharedSettings.setCurrentChatModelId(chatModel.id.description())
        return sharedSettings
    }

    private func makeStore() throws -> (IOSConversationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatInboundTurnTriageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (IOSConversationStore(baseDirectory: directory), directory)
    }

    private func makeViewModel(
        defaults: UserDefaults,
        sharedSettings: IOSSharedSettingsStore,
        store: IOSConversationStore,
        steerQueueStore: IOSSteerQueueStore
    ) -> ChatViewModel {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbound-triage-\(UUID().uuidString).db")
            .path
        let db = IosDatabaseFactory.shared.createDatabase(atFilePath: dbPath)
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(
                userDefaults: defaults,
                storageKey: "inbound-triage-settings-\(UUID().uuidString)"
            ),
            sharedSettings: sharedSettings,
            searchTransport: IOSForegroundNoopSearchTransport(),
            autoGenerateResponses: true,
            auxiliaryTextProvider: ImmediateAuxiliaryProvider(),
            steerQueueStore: steerQueueStore,
            agentRuntimeDao: db.agentRuntimeDao()
        )
        viewModel.conversationStore = store
        return viewModel
    }

    private func makeSamplePendingImage() -> ChatViewModel.PendingChatImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let png = image.pngData()!
        return ChatViewModel.PendingChatImage(
            dataUrl: "data:image/png;base64,\(png.base64EncodedString())",
            previewData: png
        )
    }

    private func makeSampleSelectedFile(name: String, content: String) -> SelectedDocumentReadResult {
        SelectedDocumentReadResult(
            fileName: name,
            fileType: "text/plain",
            totalBytes: Int64(content.utf8.count),
            bytesRead: content.utf8.count,
            characterCount: content.count,
            preview: content,
            isTruncated: false,
            note: nil
        )
    }

    private func followupReceiptState(of message: UIMessage) -> String? {
        for part in message.parts {
            if let textPart = part as? UIMessagePart.Text,
               let state = IosToolOutputJsonBridge.shared.metadataString(
                   part: textPart,
                   key: "chat_followup_state"
               ) {
                return state
            }
        }
        return nil
    }

    private func waitForCondition(
        timeoutSeconds: Double = 8,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    // (a) 生成中询问进度不新开 LLM 任务，而是基于真实焦点任务状态直接作答
    func testStatusQueryDuringActiveGenerationProducesLocalSummaryWithoutNewLLMTask() async throws {
        let (store, directory) = try makeStore()
        let steerDir = directory.appendingPathComponent("steer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let provider = InspectableLoopProvider(gatedKeys: ["A"])
        defer { provider.release("A") }

        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: sharedSettings,
            store: store,
            steerQueueStore: IOSSteerQueueStore(directoryURL: steerDir)
        )
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        viewModel.inputText = "TASK_A: 整理季度财报对比"
        XCTAssertTrue(viewModel.sendMessage())
        let aStarted = await waitForCondition { provider.callCount(for: "A") == 1 }
        XCTAssertTrue(aStarted)

        let slot = try XCTUnwrap(viewModel.focusedActiveTask)
        slot.activeToolTitle = "正在检索财报原文"
        slot.activityStage = .runningTool

        viewModel.inputText = "现在进展到哪一步了？"
        XCTAssertTrue(viewModel.sendMessage())

        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(provider.totalCalls, 1, "纯状态查询不得触发第二次主模型调用")
        XCTAssertEqual(viewModel.currentRun.orderedSlots.count, 1, "纯状态查询不得新开并发槽位")
        XCTAssertTrue(
            viewModel.messages.contains {
                $0.role == MessageRole.assistant && $0.toText().contains("正在检索财报原文")
            },
            "状态回复必须反映 focusedActiveTask 的真实工具/阶段信息"
        )

        provider.release("A")
        let settled = await waitForCondition { !viewModel.isGenerationActive }
        XCTAssertTrue(settled)
    }

    // (b) 单槽位补充被原任务消费且不重复出现用户气泡，发送帧 queued -> 推理边界原地 applied
    func testSingleSlotSupplementSteersOriginalTaskWithoutDuplicateUserBubbles() async throws {
        let (store, directory) = try makeStore()
        let steerDir = directory.appendingPathComponent("steer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let provider = InspectableLoopProvider(
            gatedKeys: ["A_ROUND1", "A"],
            toolRoundFirstCallKeys: ["A"]
        )
        defer {
            provider.release("A_ROUND1")
            provider.release("A")
        }

        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: sharedSettings,
            store: store,
            steerQueueStore: IOSSteerQueueStore(directoryURL: steerDir)
        )
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        viewModel.inputText = "TASK_A: 汇总本周服务端告警"
        XCTAssertTrue(viewModel.sendMessage())
        let aStarted = await waitForCondition { provider.callCount(for: "A") == 1 }
        XCTAssertTrue(aStarted)

        // 不手动点选任务芯片，直接自然补充一句话
        let supplement = "顺便把输出整理成 Markdown 表格，只保留 P0 级别"
        viewModel.inputText = supplement
        XCTAssertTrue(viewModel.sendMessage())

        // 发送当帧立即在消息列表中看到唯一一条用户气泡，且回执状态为 queued
        let matchingOnSend = viewModel.messages.filter {
            $0.role == MessageRole.user && $0.toText().contains(supplement)
        }
        XCTAssertEqual(matchingOnSend.count, 1, "发送当帧应立即可见唯一一条补充气泡")
        let initialBubbleId = ChatMessageProjector.messageId(for: try XCTUnwrap(matchingOnSend.first))
        XCTAssertEqual(followupReceiptState(of: try XCTUnwrap(matchingOnSend.first)), "queued")
        XCTAssertEqual(viewModel.currentRun.orderedSlots.count, 1, "单槽位默认补充不应盲开第 2 个任务槽位")

        // 放行第一轮工具，到达第二轮推理边界时消费补充
        provider.release("A_ROUND1")
        let enteredRound2 = await waitForCondition { provider.callCount(for: "A") == 2 }
        XCTAssertTrue(enteredRound2)

        let matchingAfterApply = viewModel.messages.filter {
            $0.role == MessageRole.user && $0.toText().contains(supplement)
        }
        XCTAssertEqual(matchingAfterApply.count, 1, "补充被消费后不得产生重复用户气泡")
        let appliedBubble = try XCTUnwrap(matchingAfterApply.first)
        XCTAssertEqual(ChatMessageProjector.messageId(for: appliedBubble), initialBubbleId, "必须保持同一稳定 messageId 原地更新")
        XCTAssertEqual(followupReceiptState(of: appliedBubble), "applied")

        let round2Messages = try XCTUnwrap(provider.records(for: "A").last?.messages)
        XCTAssertTrue(
            round2Messages.contains { $0.role == MessageRole.user && $0.toText().contains(supplement) },
            "原任务第二轮推理请求必须收到该补充消息"
        )

        provider.release("A")
        let settled = await waitForCondition { !viewModel.isGenerationActive }
        XCTAssertTrue(settled)
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == MessageRole.user && $0.toText().contains(supplement) }.count,
            1
        )
    }

    // (c) 并发打满时发送停止指令不会排队等槽位，而是立即作用于活跃任务
    func testStopCommandDuringConcurrencySaturationCancelsActiveTaskImmediately() async throws {
        let (store, directory) = try makeStore()
        let steerDir = directory.appendingPathComponent("steer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let provider = InspectableLoopProvider(gatedKeys: ["A", "B"])
        defer {
            provider.release("A")
            provider.release("B")
        }

        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: sharedSettings,
            store: store,
            steerQueueStore: IOSSteerQueueStore(directoryURL: steerDir)
        )
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        viewModel.inputText = "TASK_A: 深度扫描日志"
        XCTAssertTrue(viewModel.sendMessage())
        let aStarted = await waitForCondition { provider.callCount(for: "A") == 1 }
        XCTAssertTrue(aStarted)

        viewModel.inputText = "独立问题：TASK_B 排查"
        XCTAssertTrue(viewModel.sendMessage())
        let bStarted = await waitForCondition { provider.callCount(for: "B") == 1 }
        XCTAssertTrue(bStarted)
        XCTAssertEqual(viewModel.activeTaskRunIdsForCurrentConversation.count, 2)

        // 并发槽位已满（2/2），自然语言发送“停一下”
        viewModel.inputText = "停一下"
        XCTAssertTrue(viewModel.sendMessage())

        let cancelledOne = await waitForCondition {
            viewModel.activeTaskRunIdsForCurrentConversation.count < 2
        }
        XCTAssertTrue(cancelledOne, "停止指令必须直接取消目标活跃槽位，绝不能作为第 3 个并发任务排队")
        XCTAssertEqual(viewModel.currentRun.orderedSlots.count, 2, "停止指令不得新增第 3 个任务槽位")
        XCTAssertEqual(provider.totalCalls, 2, "停止指令不得发起新的主模型请求")

        provider.release("A")
        provider.release("B")
        let settled = await waitForCondition { !viewModel.isGenerationActive }
        XCTAssertTrue(settled)
    }

    // (d) 定向补充携带图片与文件引用时完整保留并在推理边界送达原任务
    func testTargetedFollowupPreservesImageAndSelectedFileAttachments() async throws {
        let (store, directory) = try makeStore()
        let steerDir = directory.appendingPathComponent("steer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let provider = InspectableLoopProvider(
            gatedKeys: ["A_ROUND1"],
            toolRoundFirstCallKeys: ["A"]
        )
        defer { provider.release("A_ROUND1") }

        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: sharedSettings,
            store: store,
            steerQueueStore: IOSSteerQueueStore(directoryURL: steerDir)
        )
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        viewModel.inputText = "TASK_A: 分析延迟曲线"
        XCTAssertTrue(viewModel.sendMessage())
        let aStarted = await waitForCondition { provider.callCount(for: "A") == 1 }
        XCTAssertTrue(aStarted)
        let runIdA = try XCTUnwrap(viewModel.activeTaskRunIdsForCurrentConversation.first)

        viewModel.selectTaskForFollowup(runId: runIdA)
        viewModel.pendingImages = [makeSamplePendingImage()]
        viewModel.pendingSelectedFilePreview = makeSampleSelectedFile(
            name: "metrics.csv",
            content: "ts,latency\n1,42\n"
        )
        viewModel.inputText = "结合这张截图和该 CSV 再核对一次峰值"
        XCTAssertTrue(viewModel.sendMessage())

        provider.release("A_ROUND1")
        let finished = await waitForCondition { !viewModel.isGenerationActive }
        XCTAssertTrue(finished)

        let round2Messages = try XCTUnwrap(provider.records(for: "A").last?.messages)
        let deliveredFollowup = try XCTUnwrap(
            round2Messages.last { $0.role == MessageRole.user && $0.toText().contains("结合这张截图") }
        )
        XCTAssertTrue(
            deliveredFollowup.parts.contains { $0 is UIMessagePart.Image },
            "定向补充携带的图片不得丢失"
        )
        XCTAssertTrue(
            deliveredFollowup.toText().contains("metrics.csv"),
            "定向补充携带的 <amber-selected-file> 文件引用不得丢失"
        )
    }

    // (e) 任务在消费补充前取消时，已上屏补充原地转为 not_applied 且队列保留可恢复信息
    func testCancelledTaskMarksUnconsumedFollowupNotAppliedAndPreservesRecoverableEntry() async throws {
        let (store, directory) = try makeStore()
        let steerDir = directory.appendingPathComponent("steer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let provider = InspectableLoopProvider(
            gatedKeys: ["A_ROUND1"],
            toolRoundFirstCallKeys: ["A"]
        )
        defer { provider.release("A_ROUND1") }

        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: sharedSettings,
            store: store,
            steerQueueStore: IOSSteerQueueStore(directoryURL: steerDir)
        )
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        viewModel.inputText = "TASK_A: 撰写周报初稿"
        XCTAssertTrue(viewModel.sendMessage())
        let aStarted = await waitForCondition { provider.callCount(for: "A") == 1 }
        XCTAssertTrue(aStarted)
        let runIdA = try XCTUnwrap(viewModel.activeTaskRunIdsForCurrentConversation.first)

        viewModel.selectTaskForFollowup(runId: runIdA)
        viewModel.pendingImages = [makeSamplePendingImage()]
        viewModel.pendingSelectedFilePreview = makeSampleSelectedFile(
            name: "draft.md",
            content: "# Draft\n"
        )
        let unconsumedText = "补充：请加上下周风险清单"
        viewModel.inputText = unconsumedText
        XCTAssertTrue(viewModel.sendMessage())

        // 在第一轮尚未进入下一轮推理边界前直接取消任务
        XCTAssertTrue(viewModel.cancelGeneration(runId: runIdA))
        let settled = await waitForCondition { !viewModel.isGenerationActive }
        XCTAssertTrue(settled)

        let unappliedBubble = try XCTUnwrap(
            viewModel.messages.first { $0.role == MessageRole.user && $0.toText().contains(unconsumedText) },
            "取消前已接收的补充必须保留在时间线中并标记未生效，不能静默消失"
        )
        XCTAssertEqual(
            followupReceiptState(of: unappliedBubble),
            "not_applied",
            "未消费即取消的补充必须原地翻转为 not_applied"
        )
    }
    func testLiveMessageWritesSerializeAndPersistLatestConversationState() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()
        let defaults = makeDefaults()
        let viewModel = makeViewModel(defaults: defaults,
            sharedSettings: makeSharedSettings(defaults: defaults), store: store,
            steerQueueStore: IOSSteerQueueStore(directoryURL: directory.appendingPathComponent("queue")))
        viewModel.reloadFromStore()
        let state = viewModel.currentRun.state
        state.messages = [UIMessage.companion.user(prompt: "first")]
        let reserved = expectation(description: "first message write reserved")
        var release: CheckedContinuation<Void, Never>?
        store.afterPersistReservationForTesting = { _ in
            store.afterPersistReservationForTesting = nil
            reserved.fulfill()
            await withCheckedContinuation { release = $0 }
        }
        let first = Task { await viewModel.persistMessages(state: state) }
        await fulfillment(of: [reserved], timeout: 2)
        state.messages.append(UIMessage.companion.user(prompt: "second"))
        let second = Task { await viewModel.persistMessages(state: state) }
        await Task.yield()
        state.messages.append(UIMessage.companion.user(prompt: "third"))
        let third = Task { await viewModel.persistMessages(state: state) }
        await Task.yield()
        release?.resume()
        let firstSaved = await first.value
        let secondSaved = await second.value
        XCTAssertTrue(firstSaved)
        XCTAssertTrue(secondSaved)
        let thirdSaved = await third.value
        XCTAssertTrue(thirdSaved)
        let restarted = IOSConversationStore(baseDirectory: directory)
        await restarted.bootstrap()
        XCTAssertEqual(restarted.currentMessages.map { $0.toText() }, ["first", "second", "third"])
    }

    func testCancelledFollowupSurvivesReloadAndRefillsAllAttachments() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let queue = IOSSteerQueueStore(directoryURL: directory.appendingPathComponent("queue"))
        let image = makeSamplePendingImage()
        let entry = IOSSteerQueueEntry(id: "recover-followup", text: "核对附件", createdAt: Date(),
            images: [IOSSteerQueueImage(dataUrl: image.dataUrl, previewData: image.previewData)],
            selectedFile: IOSSteerQueuedFile(makeSampleSelectedFile(name: "metrics.csv", content: "ts,latency")),
            targetRunId: "ended-run")
        queue.persist([entry], for: id)
        let defaults = makeDefaults()
        let viewModel = makeViewModel(defaults: defaults,
            sharedSettings: makeSharedSettings(defaults: defaults), store: store, steerQueueStore: queue)
        viewModel.reloadFromStore()
        await viewModel.steerQueueLoadTask?.value
        XCTAssertEqual(viewModel.steerQueue.first?.status, .cancelled)
        XCTAssertEqual(followupReceiptState(of: try XCTUnwrap(viewModel.messages.first)), "not_applied")
        viewModel.restoreSteerMessageToComposer(id: entry.id)
        XCTAssertEqual(viewModel.inputText, entry.text)
        XCTAssertEqual(viewModel.pendingImages.first?.dataUrl, image.dataUrl)
        XCTAssertEqual(viewModel.pendingSelectedFilePreview?.fileName, "metrics.csv")
        XCTAssertTrue(queue.load(conversationId: id).isEmpty)
    }

    func testFollowupDuringFinalNonToolTurnAutoContinuesInsteadOfMarkingNotApplied() async throws {
        let (store, directory) = try makeStore()
        let steerDir = directory.appendingPathComponent("steer", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.bootstrap()

        let defaults = makeDefaults()
        let sharedSettings = makeSharedSettings(defaults: defaults)
        let provider = InspectableLoopProvider(gatedKeys: ["A", "B"])
        defer { provider.release("A"); provider.release("B") }

        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: sharedSettings,
            store: store,
            steerQueueStore: IOSSteerQueueStore(directoryURL: steerDir)
        )
        viewModel.kernelTextProviderOverrideForTesting = provider
        viewModel.reloadFromStore()

        viewModel.inputText = "TASK_A：生成无工具终态总结"
        XCTAssertTrue(viewModel.sendMessage())
        let startedA = await waitForCondition { provider.callCount(for: "A") == 1 }
        XCTAssertTrue(startedA)
        let runIdA = try XCTUnwrap(viewModel.focusedActiveTask?.runId)

        viewModel.inputText = "补充第一点：附上风险提示"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.inputText = "补充第二点：附上回滚步骤"
        XCTAssertTrue(viewModel.sendMessage())
        XCTAssertEqual(viewModel.steerQueue.count, 2)

        // 同时发起一个并行独立任务 B，验证 A 终态自动续答不会受并行任务干扰且回复锚定在 TASK_B 之前。
        viewModel.inputText = "独立问题：TASK_B：并行查询"
        XCTAssertTrue(viewModel.sendMessage())
        let startedB = await waitForCondition { provider.callCount(for: "B") == 1 }
        XCTAssertTrue(startedB)

        provider.release("A")
        let aContinued = await waitForCondition {
            viewModel.steerQueue.isEmpty && provider.callCount(for: "A") == 2
        }
        XCTAssertTrue(aContinued)

        provider.release("B")
        let allDone = await waitForCondition { !viewModel.isGenerationActive && viewModel.steerQueue.isEmpty }
        XCTAssertTrue(allDone)
        XCTAssertEqual(provider.callCount(for: "A"), 2)
        XCTAssertEqual(provider.callCount(for: "B"), 1)

        let followup1 = try XCTUnwrap(viewModel.messages.first { $0.toText().contains("补充第一点：附上风险提示") })
        let followup2 = try XCTUnwrap(viewModel.messages.first { $0.toText().contains("补充第二点：附上回滚步骤") })
        XCTAssertEqual(followupReceiptState(of: followup1), "applied")
        XCTAssertEqual(followupReceiptState(of: followup2), "applied")
        XCTAssertEqual(viewModel.taskFollowups(forRunId: runIdA).first?.status, .consumed)

        let recordsA = provider.records(for: "A")
        XCTAssertEqual(recordsA.count, 2)
        if recordsA.count == 2 {
            XCTAssertTrue(recordsA[1].messages.contains { $0.toText().contains("补充第一点：附上风险提示") })
            XCTAssertTrue(recordsA[1].messages.contains { $0.toText().contains("补充第二点：附上回滚步骤") })
            XCTAssertFalse(recordsA[1].messages.contains { $0.toText().contains("TASK_B") })
        }

        let rolesAndSnippets = viewModel.messages.map { "\($0.role.name.lowercased()):\($0.toText())" }
        XCTAssertEqual(rolesAndSnippets.count, 7)
        if rolesAndSnippets.count == 7 {
            XCTAssertTrue(rolesAndSnippets[0].contains("TASK_A"))
            XCTAssertEqual(rolesAndSnippets[1], "assistant:A 最终结论")
            XCTAssertTrue(rolesAndSnippets[2].contains("补充第一点：附上风险提示"))
            XCTAssertTrue(rolesAndSnippets[3].contains("补充第二点：附上回滚步骤"))
            XCTAssertEqual(rolesAndSnippets[4], "assistant:A 最终结论")
            XCTAssertTrue(rolesAndSnippets[5].contains("TASK_B"))
            XCTAssertEqual(rolesAndSnippets[6], "assistant:B 最终结论")
        }
    }

}
