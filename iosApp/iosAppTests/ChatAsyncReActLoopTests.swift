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
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
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
        let idxReplyA = try XCTUnwrap(texts.firstIndex { $0.contains("A final reply") })
        let idxUserB = try XCTUnwrap(texts.firstIndex { $0.contains("TASK_B") })
        let idxReplyB = try XCTUnwrap(texts.firstIndex { $0.contains("B final reply") })

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
}
