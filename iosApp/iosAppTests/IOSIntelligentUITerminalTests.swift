import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSIntelligentUITerminalTests: XCTestCase {
    private typealias F = IOSChatForegroundFixtures

    private var cardText: String {
        "```task-ui\n\(IOSIntelligentUIProtocol.exampleJSON)\n```"
    }

    private final class CardProvider: IOSAgentTextProvider, @unchecked Sendable {
        let response: String
        init(response: String) { self.response = response }

        func generateText(
            providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams
        ) async throws -> MessageChunk {
            F.chunk(with: F.assistantText(response))
        }
    }

    private final class PendingCardProvider: IOSAgentTextProvider, IOSAgentStreamingProvider, @unchecked Sendable {
        let response: String
        private let lock = NSLock()
        private var completion: (@Sendable () -> Void)?
        init(response: String) { self.response = response }

        func generateText(
            providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams
        ) async throws -> MessageChunk { F.chunk(with: F.assistantText(response)) }

        func streamText(
            providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams,
            onChunk: @escaping @Sendable (MessageChunk) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (KotlinThrowable) -> Void
        ) -> Kotlinx_coroutines_coreJob? {
            lock.withLock { completion = onComplete }
            onChunk(F.streamChunk(delta: F.assistantText(response), finishReason: ""))
            return nil
        }

        func release() { lock.withLock { completion }?() }
    }

    func testSuccessfulHostPersistsCompletedCardStampWithRunIdentity() async throws {
        weak var observedHarness: IOSChatForegroundHarness?
        var savedCard: UIMessagePart.Text?
        let harness = IOSChatForegroundHarness(persistMessages: { _ in
            if let text = observedHarness?.messages.last?.parts.first as? UIMessagePart.Text,
               text.metadata?[IOSIntelligentUITerminal.completedKey]?.jsonPrimitiveOrNull?.content == "completed" {
                savedCard = text
            }
            return true
        })
        observedHarness = harness
        let host = makeHost(harness: harness)
        start(host, harness: harness)

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, "completed")
        let saved = try XCTUnwrap(savedCard, "The durable snapshot must contain the terminal marker")
        XCTAssertEqual(saved.metadata?[IOSIntelligentUITerminal.runIDKey]?.jsonPrimitiveOrNull?.content, harness.capturedRunId)
        XCTAssertEqual(cardPart(in: harness.messages)?.metadata?[IOSIntelligentUITerminal.completedKey]?.jsonPrimitiveOrNull?.content, "completed")
    }

    func testFailedFinalPersistenceRemovesOptimisticStampFromMemory() async {
        weak var observedHarness: IOSChatForegroundHarness?
        var attemptedCompletedSave = false
        let harness = IOSChatForegroundHarness(persistMessages: { _ in
            if let text = observedHarness?.messages.last?.parts.first as? UIMessagePart.Text,
               text.metadata?[IOSIntelligentUITerminal.completedKey]?.jsonPrimitiveOrNull?.content == "completed" {
                attemptedCompletedSave = true
                return false
            }
            return true
        })
        observedHarness = harness
        let host = makeHost(harness: harness)
        start(host, harness: harness)

        let terminal = await harness.waitForTerminal()
        XCTAssertEqual(terminal, AgentRunStatus.recoveryPending.wireName)
        XCTAssertTrue(attemptedCompletedSave)
        XCTAssertNil(cardPart(in: harness.messages)?.metadata?[IOSIntelligentUITerminal.completedKey])
        XCTAssertNil(cardPart(in: harness.messages)?.metadata?[IOSIntelligentUITerminal.runIDKey])
    }

    func testCompletionDoesNotEnableHistoricalUserOrErrorCards() {
        let historical = F.assistantText(cardText)
        let user = F.userMessage(cardText)
        let failed = F.assistantMessage(parts: [MessageKt.localGenerationErrorTextPart(text: cardText)])
        let ordinary = F.assistantText("普通回复")
        let newCard = F.assistantText(cardText)
        let stamped = IOSIntelligentUITerminal.markCompleted(
            [historical, user, failed, ordinary, newCard], baseline: [historical], runID: "new-run"
        )
        for message in stamped.dropLast() {
            let text = message.parts.first as? UIMessagePart.Text
            XCTAssertNil(text?.metadata?[IOSIntelligentUITerminal.completedKey])
        }
        let accepted = stamped.last?.parts.first as? UIMessagePart.Text
        XCTAssertEqual(accepted?.metadata?[IOSIntelligentUITerminal.completedKey]?.jsonPrimitiveOrNull?.content, "completed")
        XCTAssertEqual(accepted?.metadata?[IOSIntelligentUITerminal.runIDKey]?.jsonPrimitiveOrNull?.content, "new-run")
        XCTAssertEqual(stamped.map(\.id), [historical, user, failed, ordinary, newCard].map(\.id))
    }

    func testAdvancedCheckpointBaselineKeepsSameRunCardEligibleWithoutPrematureCompletion() {
        let historical = F.assistantText(cardText)
        let newCard = F.assistantText(cardText)
        let checkpoint = IOSIntelligentUITerminal.markSourcesPending(
            [historical, newCard], baseline: [historical], runID: "continuing-run"
        )
        let pending = checkpoint.last?.parts.first as? UIMessagePart.Text
        XCTAssertEqual(pending?.metadata?[IOSIntelligentUITerminal.runIDKey]?.jsonPrimitiveOrNull?.content, "continuing-run")
        XCTAssertNil(pending?.metadata?[IOSIntelligentUITerminal.completedKey])

        let completed = IOSIntelligentUITerminal.markCompleted(checkpoint, baseline: checkpoint, runID: "continuing-run")
        let completedCard = completed.last?.parts.first as? UIMessagePart.Text
        XCTAssertEqual(completedCard?.metadata?[IOSIntelligentUITerminal.completedKey]?.jsonPrimitiveOrNull?.content, "completed")
        XCTAssertNil((completed.first?.parts.first as? UIMessagePart.Text)?.metadata?[IOSIntelligentUITerminal.completedKey])
        XCTAssertEqual(IOSIntelligentUITerminal.markCompleted(checkpoint, baseline: checkpoint, runID: "another-run"), checkpoint)
        XCTAssertEqual(IOSIntelligentUITerminal.markSourcesPending(checkpoint, baseline: checkpoint, runID: "another-run"), checkpoint)
    }

    func testForegroundHandoffLabelsPartialCardSourceWithoutEnablingIt() async throws {
        let harness = IOSChatForegroundHarness()
        let provider = PendingCardProvider(response: cardText)
        defer { provider.release() }
        let host = ChatKernelRunHost(
            dependencies: harness.dependencies, bindings: harness.bindings,
            backgroundExecution: harness.keepAlive, toolLedger: harness.ledger, textProvider: provider
        )
        var capturedHandoff: IOSChatBackgroundHandoff?
        host.backgroundStartOverrideForTesting = { handoff, _ in capturedHandoff = handoff; return true }
        start(host, harness: harness)
        let deadline = Date().addingTimeInterval(3)
        while cardPart(in: harness.messages) == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(cardPart(in: harness.messages))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaskUIHandoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        XCTAssertTrue(host.handoffCurrentGenerationToBackground(conversationStore: store))
        let handoff = try XCTUnwrap(capturedHandoff)
        let partial = try XCTUnwrap(cardPart(in: handoff.displayMessages))
        XCTAssertEqual(partial.metadata?[IOSIntelligentUITerminal.runIDKey]?.jsonPrimitiveOrNull?.content, handoff.runId)
        XCTAssertNil(partial.metadata?[IOSIntelligentUITerminal.completedKey])
        let final = IOSIntelligentUITerminal.markCompleted(
            handoff.displayMessages, baseline: handoff.displayMessages, runID: handoff.runId
        )
        XCTAssertEqual(cardPart(in: final)?.metadata?[IOSIntelligentUITerminal.completedKey]?.jsonPrimitiveOrNull?.content, "completed")
    }

    private func makeHost(harness: IOSChatForegroundHarness) -> ChatKernelRunHost {
        ChatKernelRunHost(
            dependencies: harness.dependencies, bindings: harness.bindings,
            backgroundExecution: harness.keepAlive, toolLedger: harness.ledger,
            textProvider: CardProvider(response: cardText)
        )
    }

    private func start(_ host: ChatKernelRunHost, harness: IOSChatForegroundHarness) {
        host.start(
            providerSetting: harness.providerSetting, params: harness.params,
            inputDigest: "intelligent-ui-terminal", conversationId: harness.conversationId,
            uploadMessages: harness.messages, toolExposureBridge: harness.toolExposureBridge
        )
    }

    private func cardPart(in messages: [UIMessage]) -> UIMessagePart.Text? {
        messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Text }
            .last { $0.text.contains("```task-ui") }
    }
}
