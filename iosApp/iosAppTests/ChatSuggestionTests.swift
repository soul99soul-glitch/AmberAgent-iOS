import Foundation
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatSuggestionTests: XCTestCase {
    private let source = ChatSuggestionSource(host: "local", scope: "conversation", turn: "reply")

    func testContextRetainsEarlierConstraintsToolResultsAndPendingWorkWithoutReasoning() throws {
        var messages = [UIMessage.companion.user(prompt: "按方案做，先别提交代码")]
        for index in 0..<10 {
            messages.append(.companion.assistant(prompt: "步骤 \(index) 完成"))
            messages.append(.companion.user(prompt: "继续第 \(index + 1) 步"))
        }
        let tool = UIMessagePart.Tool(toolCallId: "test", toolName: "workspace_file_write", input: "private-tool-argument",
            output: [UIMessagePart.Text(text: "设计稿已保存，测试仍待运行", metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
        let instant = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0)
        let seed = UIMessage.companion.assistant(prompt: "实现已完成，下一步验证。")
        messages.append(UIMessage(id: seed.id, role: .assistant, parts: [
            tool, UIMessagePart.Reasoning(reasoning: "raw-reasoning-must-not-leak", createdAt: instant, finishedAt: instant, metadata: nil)
        ] + seed.parts, annotations: [], createdAt: seed.createdAt, finishedAt: seed.finishedAt,
            modelId: nil, usage: nil, translation: nil))
        let context = try XCTUnwrap(ChatSuggestionContext.local(messages: messages, conversationID: "conversation",
            summary: "计划：完成界面后验证", waitingForChild: true))
        XCTAssertTrue(context.content.contains("先别提交代码"), "不能只保留最后8条而丢掉任务约束")
        XCTAssertTrue(context.content.contains("设计稿已保存，测试仍待运行"))
        XCTAssertTrue(context.content.contains("计划：完成界面后验证"))
        XCTAssertTrue(context.content.contains("still running"))
        XCTAssertFalse(context.content.contains("raw-reasoning"))
        XCTAssertFalse(context.content.contains("private-tool-argument"))
    }

    func testOversizedTurnKeepsRequestAndFinalResultWithinBudget() {
        let context = ChatSuggestionContext(source: source, entries: [
            .init(role: "User", text: "保留我的草稿" + String(repeating: "a", count: 5_000)),
            .init(role: "Assistant", text: String(repeating: "b", count: 5_000) + "实际结果：已保留草稿")
        ], budget: 600)
        XCTAssertLessThanOrEqual(context.content.count, 600)
        XCTAssertTrue(context.content.contains("保留我的草稿"))
        XCTAssertTrue(context.content.contains("实际结果：已保留草稿"))
    }

    func testWeakOrAmbiguousPredictionsProduceNoChip() {
        let context = ChatSuggestionContext(source: source, entries: [
            .init(role: "User", text: "把单元测试跑一下"),
            .init(role: "Assistant", text: "测试已通过，覆盖了取消路径。")
        ])
        for raw in ["", "[NO_SUGGESTION]", "好的", "继续", "我可以帮你运行更多测试", "把单元测试跑一下", "```json\n{}\n```"] {
            XCTAssertTrue(ChatSuggestionFilter.candidates(from: raw, context: context).isEmpty, raw)
        }
        XCTAssertEqual(ChatSuggestionFilter.candidates(from: "把本轮修改列给我看看，先别提交", context: context),
                       ["把本轮修改列给我看看，先别提交"])
    }

    func testAlternativesKeepOrderRemoveDuplicatesAndStopAtThree() {
        let context = ChatSuggestionContext(source: source, entries: [
            .init(role: "User", text: "给我几个可行方案"),
            .init(role: "Assistant", text: "可以先修输入，或者先调样式，也可以暂缓修改。")
        ])
        let raw = "好的\n1. 先修输入\n2. 先修输入！\n3. 先调样式\n4. 暂缓修改\n5. 再给个方案"
        XCTAssertEqual(ChatSuggestionFilter.candidates(from: raw, context: context), ["先修输入", "先调样式", "暂缓修改"])
        XCTAssertEqual(ChatSuggestionFilter.candidates(from: "先修输入\n先调样式", context: context), ["先修输入", "先调样式"])
        XCTAssertTrue(ChatSuggestionFilter.candidates(from: "[NO_SUGGESTION]\n先修输入", context: context).isEmpty)
    }

    func testCloudTriggerIgnoresProgressReplayAndOlderReplies() {
        let store = MacGatewayStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.updateCloudSuggestionTrigger(event(2, "reply", .assistantReply, "已找到原因"))
        store.updateCloudSuggestionTrigger(event(3, "progress", .processEvent, "正在修复"))
        XCTAssertEqual(store.cloudSuggestionReplyID, "reply")
        store.updateCloudSuggestionTrigger(event(4, "user", .userMessage, "先别修"))
        store.updateCloudSuggestionTrigger(event(2, "reply", .assistantReply, "已找到原因"))
        XCTAssertNil(store.cloudSuggestionReplyID)
        store.updateCloudSuggestionTrigger(event(5, "failed", .taskResult, "失败", outcome: .failed))
        XCTAssertNil(store.cloudSuggestionReplyID)
    }

    func testPredictionUsesConfiguredProviderAndDoesNotRegenerateSameReply() async throws {
        let provider = PredictionProvider()
        let vm = ChatViewModel(settingsStore: SettingsStore(), sharedSettings: settings(),
                              autoGenerateResponses: false, auxiliaryTextProvider: provider)
        vm.messages = [.companion.user(prompt: "先实现，不要推送"), .companion.assistant(prompt: "实现已完成，测试已通过。")]
        vm.generateChatSuggestions(state: vm.currentRun.state)
        try await waitUntil { !vm.chatSuggestions.isEmpty }
        XCTAssertEqual(vm.chatSuggestions, ["把本轮修改列给我看看，先别提交"])
        XCTAssertTrue(provider.prompt.contains("不要推送"))
        XCTAssertTrue(provider.prompt.contains("Default to one prediction"))
        XCTAssertEqual(provider.calls, 1)
        vm.generateChatSuggestions(state: vm.currentRun.state)
        XCTAssertEqual(provider.calls, 1)
        vm.suggestionDidAppear()
        vm.fillInputFromSuggestion(vm.chatSuggestions[0])
        XCTAssertTrue(vm.chatSuggestions.isEmpty)
        XCTAssertEqual(vm.messages.count, 2, "选择建议只填草稿，不发送")
    }

    func testMultiplePredictionsReachComposerAndSecondChoiceOnlyFillsDraft() async throws {
        let provider = PredictionProvider(response: "先修输入\n先调样式\n暂缓修改")
        let vm = ChatViewModel(settingsStore: SettingsStore(), sharedSettings: settings(),
                              autoGenerateResponses: false, auxiliaryTextProvider: provider)
        vm.messages = [.companion.user(prompt: "比较这几个方案"),
                       .companion.assistant(prompt: "可以先修输入、先调样式或暂缓修改。")]
        vm.generateChatSuggestions(state: vm.currentRun.state)
        try await waitUntil { !vm.chatSuggestions.isEmpty }
        XCTAssertEqual(vm.chatSuggestions, ["先修输入", "先调样式", "暂缓修改"])
        vm.fillInputFromSuggestion(vm.chatSuggestions[1])
        XCTAssertEqual(vm.inputText, "先调样式")
        XCTAssertTrue(vm.chatSuggestions.isEmpty)
        XCTAssertEqual(vm.messages.count, 2)
    }

    func testSwitchingHostRejectsInFlightLocalPrediction() async throws {
        let provider = BlockingVisionProvider()
        let vm = ChatViewModel(settingsStore: SettingsStore(), sharedSettings: settings(),
                              autoGenerateResponses: false, auxiliaryTextProvider: provider)
        vm.messages = [.companion.user(prompt: "找出原因"), .companion.assistant(prompt: "原因已确认。")]
        vm.generateChatSuggestions(state: vm.currentRun.state)
        try await waitUntil { provider.hasStarted }
        vm.setSuggestionHost("cloud:other")
        provider.finish(text: "按这个原因修一下")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(vm.chatSuggestions.isEmpty)
        XCTAssertTrue(vm.inputText.isEmpty)
    }

    func testCloudReplyGeneratesFromCloudTranscriptAndUserEventInvalidatesIt() async throws {
        let provider = PredictionProvider()
        let vm = ChatViewModel(settingsStore: SettingsStore(), sharedSettings: settings(),
                              autoGenerateResponses: false, auxiliaryTextProvider: provider)
        let store = MacGatewayStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let client = MacGatewayClient(addrs: ["example.test"], port: 443, fingerprint: "test", token: "fixture",
            transport: { _, _ in throw URLError(.notConnectedToInternet) })
        store.configureForTesting(connection: .init(gatewayId: "test", name: "Cloud", addrs: ["example.test"],
            port: 443, fingerprint: "test", deviceId: "test"), client: client)
        store.isCloudMainDialogueSelected = true
        let user = event(1, "user", .userMessage, "云端检查磁盘，不要清理")
        let reply = event(2, "reply", .assistantReply, "磁盘空间已核对。")
        store.ingestCloudDialogueEventsPage(.init(items: [user, reply], nextCursor: 2, soulRevision: nil), requestedAfter: 0)
        vm.setSuggestionHost(store.suggestionHostKey)
        vm.refreshCloudSuggestions(gateway: store)
        try await waitUntil { !vm.chatSuggestions.isEmpty }
        XCTAssertTrue(provider.prompt.contains("不要清理"))
        vm.refreshCloudSuggestions(gateway: store)
        XCTAssertEqual(provider.calls, 1)
        store.updateCloudSuggestionTrigger(event(3, "new-user", .userMessage, "暂停"))
        vm.refreshCloudSuggestions(gateway: store)
        XCTAssertTrue(vm.chatSuggestions.isEmpty)
    }

    func testFeedbackTracksDisplayAcceptanceEditingAndIgnoreWithoutPersistingText() async throws {
        var tracker = ChatSuggestionFeedbackSession()
        XCTAssertTrue(tracker.prepare(source: source, suggestions: ["先运行测试"], modelID: "model").isEmpty)
        let shown = tracker.shown()
        XCTAssertEqual(shown.map(\.kind), [.shown])
        XCTAssertTrue(tracker.shown().isEmpty)
        let accepted = tracker.accept("先运行测试")
        XCTAssertEqual(accepted.map(\.kind), [.accepted])
        let submitted = tracker.submit("先运行定点测试")
        XCTAssertEqual(submitted.map(\.kind), [.edited, .submitted])
        XCTAssertEqual(submitted.last?.exactMatch, false)
        XCTAssertGreaterThan(submitted.last?.changedCharacters ?? 0, 0)
        _ = tracker.prepare(source: source, suggestions: ["先运行测试"], modelID: "model")
        _ = tracker.shown()
        XCTAssertEqual(tracker.dismiss(reason: "host_changed").first?.kind, .ignored)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.json")
        let store = ChatSuggestionFeedbackStore(url: url, capacity: 3)
        await store.append(shown + accepted + submitted)
        let data = try Data(contentsOf: url)
        let records = try JSONDecoder().decode([ChatSuggestionFeedbackEvent].self, from: data)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.last?.kind, .submitted)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("先运行"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("conversation"))
    }

    func testFeedbackComparesEditsAgainstTheChosenAlternative() {
        var tracker = ChatSuggestionFeedbackSession()
        _ = tracker.prepare(source: source, suggestions: ["先修输入", "先调样式", "暂缓修改"], modelID: "model")
        XCTAssertEqual(tracker.shown().first?.suggestionCount, 3)
        let accepted = tracker.accept("暂缓修改")
        XCTAssertEqual(accepted.first?.kind, .accepted)
        XCTAssertEqual(accepted.first?.candidateIndex, 2)
        let submitted = tracker.submit("暂缓修改，先讨论")
        XCTAssertEqual(submitted.map(\.kind), [.edited, .submitted])
        XCTAssertTrue(submitted.allSatisfy { $0.candidateIndex == 2 })
        XCTAssertEqual(submitted.last?.changedCharacters, 4)
    }

    private func event(_ seq: Int64, _ id: String, _ kind: MacGatewayCloudDialogueEventKind,
                       _ text: String, outcome: MacGatewayCloudDialogueOutcome? = nil) -> MacGatewayCloudDialogueEvent {
        .init(seq: seq, id: id, kind: kind, role: kind == .userMessage ? "user" : "assistant", text: text,
              topicId: "topic", workItemId: nil, outcome: outcome, soulRevision: nil)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("prediction did not settle")
    }

    private func settings() -> IOSSharedSettingsStore {
        let model = Model(modelId: "prediction-fixture", displayName: "Prediction Fixture", id: KotlinUuid.companion.random(),
            type: .chat, customHeaders: [], customBodies: [], inputModalities: [], outputModalities: [], abilities: [],
            tools: Set<BuiltInTools>(), contextWindowTokens: nil, providerOverwrite: nil)
        let provider = ProviderSetting.OpenAI(id: KotlinUuid.companion.random(), enabled: true, name: "Fixture", models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""), builtIn: false,
            descriptionText: nil, shortDescriptionText: nil, apiKey: "synthetic-key", baseUrl: "https://example.test/v1",
            chatCompletionsPath: "/chat/completions", useResponseApi: false, authMode: .apiKey, brand: .generic)
        let store = IOSSharedSettingsStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        _ = store.addProvider(provider)
        store.setCurrentChatModelId(model.id.description())
        store.setCurrentAssistantChatModelId(model.id.description())
        return store
    }
}

private final class PredictionProvider: IOSAgentTextProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let response: String
    private var received: [String] = []
    init(response: String = "把本轮修改列给我看看，先别提交") { self.response = response }
    var calls: Int { lock.withLock { received.count } }
    var prompt: String { lock.withLock { received.last ?? "" } }
    func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
        lock.withLock { received.append(messages.map { $0.toText() }.joined()) }
        return IOSChatForegroundFixtures.chunk(with: IOSChatForegroundFixtures.assistantText(response))
    }
}
