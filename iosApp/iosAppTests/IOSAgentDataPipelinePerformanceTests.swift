import Foundation
import Observation
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSAgentDataPipelinePerformanceTests: XCTestCase {
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }
    }

    private func trackMutations(on store: MacGatewayStore, counter: AtomicCounter) {
        withObservationTracking {
            _ = store.cloudDialogueTransportState
            _ = store.isReachable
            _ = store.cloudDialogueEvents
            _ = store.cloudDialogueCursor
        } onChange: {
            counter.increment()
        }
    }

    func testIdleCloudDialoguePollSkipsNoChangeObservableBroadcasts() async throws {
        let suite = "IOSAgentDataPipelinePerformanceTests.IdlePoll.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        actor MockTransport {
            var shouldFailUnreachable = false
            func setUnreachable(_ value: Bool) { shouldFailUnreachable = value }

            func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
                if shouldFailUnreachable {
                    throw MacGatewayError.unreachable
                }
                let json = #"{"items":[],"nextCursor":0}"#
                return (
                    Data(json.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        }

        let transport = MockTransport()
        let store = MacGatewayStore(defaults: defaults)
        let client = MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            token: "test",
            transport: { request, _ in try await transport.handle(request) }
        )
        store.configureForTesting(
            connection: MacGatewayConnection(
                gatewayId: "gw-perf",
                name: "Cloud",
                addrs: ["cloud.example"],
                port: 443,
                fingerprint: "fp",
                deviceId: "dev-perf"
            ),
            client: client
        )

        // First healthy poll sets transport state + reachability once.
        _ = try await store.pollCloudDialogueEvents().get()
        XCTAssertEqual(store.cloudDialogueTransportState, .healthy)
        XCTAssertEqual(store.isReachable, true)

        let healthyChanges = AtomicCounter()
        for _ in 0..<5 {
            trackMutations(on: store, counter: healthyChanges)
            _ = try await store.pollCloudDialogueEvents().get()
        }
        XCTAssertEqual(healthyChanges.value, 0, "Idle 1Hz empty poll must not fire @Observable mutations when state is unchanged")

        // First unreachable failure transitions state once; subsequent identical unreachable polls must be silent.
        await transport.setUnreachable(true)
        _ = await store.pollCloudDialogueEvents()
        XCTAssertEqual(store.isReachable, false)

        let offlineChanges = AtomicCounter()
        for _ in 0..<4 {
            trackMutations(on: store, counter: offlineChanges)
            _ = await store.pollCloudDialogueEvents()
        }
        XCTAssertEqual(offlineChanges.value, 0, "Repeated identical unreachable polls must not fire @Observable mutations")
    }

    func testDuplicateCloudDialoguePageSkipsPersistenceAndAsyncPersistRedactsOffMain() async throws {
        let suite = "IOSAgentDataPipelinePerformanceTests.DupPersist.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let samplePage = MacGatewayCloudDialogueEventsPage(
            items: [
                MacGatewayCloudDialogueEvent(
                    seq: 1,
                    id: "evt-1",
                    kind: .userMessage,
                    role: "user",
                    text: "检查线上状态",
                    topicId: "topic-1",
                    workItemId: nil,
                    outcome: nil,
                    soulRevision: nil
                ),
                MacGatewayCloudDialogueEvent(
                    seq: 2,
                    id: "evt-2",
                    kind: .assistantReply,
                    role: "assistant",
                    text: "[Amber host: child run ended]\n{\"structured_summary\":{\"conclusion\":\"已完成诊断\"}} token=sk-live-secret1234567890",
                    topicId: "topic-1",
                    workItemId: "work:1",
                    outcome: .completed,
                    soulRevision: nil
                )
            ],
            nextCursor: 2,
            soulRevision: nil
        )

        let store = MacGatewayStore(defaults: defaults)
        let client = MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            token: "test",
            transport: { request, _ in
                let data = try JSONEncoder().encode(samplePage)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        store.configureForTesting(
            connection: MacGatewayConnection(
                gatewayId: "gw-dup",
                name: "Cloud",
                addrs: ["cloud.example"],
                port: 443,
                fingerprint: "fp",
                deviceId: "dev-dup"
            ),
            client: client
        )

        // First poll ingests events and updates cursor.
        _ = try await store.pollCloudDialogueEvents().get()
        XCTAssertEqual(store.cloudDialogueCursor, 2)
        XCTAssertNotNil(defaults.data(forKey: MacGatewayStore.cloudDialogueStateKey))

        // Clear persisted key and verify duplicate poll with same items/cursor neither invalidates @Observable nor rewrites disk.
        defaults.removeObject(forKey: MacGatewayStore.cloudDialogueStateKey)
        let duplicateChanges = AtomicCounter()
        trackMutations(on: store, counter: duplicateChanges)
        let didMutate = store.ingestCloudDialogueEventsPage(samplePage, requestedAfter: 0)
        XCTAssertFalse(didMutate)
        XCTAssertEqual(duplicateChanges.value, 0)
        XCTAssertNil(defaults.data(forKey: MacGatewayStore.cloudDialogueStateKey))

        _ = try await store.pollCloudDialogueEvents().get()
        XCTAssertNil(defaults.data(forKey: MacGatewayStore.cloudDialogueStateKey),
                     "Poll receiving only previously ingested events must not re-encode or rewrite persisted state")

        // Verify async persistence still performs subagent envelope sanitization and credential redaction on persistenceQueue.
        store.persistCloudDialogueState(forceAsync: true)
        MacGatewayStore.persistenceQueue.sync {}
        let persistedData = try XCTUnwrap(defaults.data(forKey: MacGatewayStore.cloudDialogueStateKey))
        let persisted = try JSONDecoder().decode(MacGatewayCloudDialoguePersistedEnvelope.self, from: persistedData)
        let replyText = try XCTUnwrap(persisted.events.last?.text)
        XCTAssertFalse(replyText.contains("sk-live-secret1234567890"))
        XCTAssertFalse(replyText.contains("[Amber host: child run ended]"))
    }

    func testFitMessagesToTokenBudgetMatchesReferenceSemantics() throws {
        func makeMessage(role: MessageRole, parts: [UIMessagePart]) -> UIMessage {
            UIMessage(
                id: KotlinUuid.companion.random(),
                role: role,
                parts: parts,
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: chatNowLocalDateTime(),
                modelId: nil,
                usage: nil,
                translation: nil
            )
        }

        func referenceFit(_ messages: [UIMessage], maxTokens: Int) -> [UIMessage] {
            let originalCount = messages.count
            guard maxTokens > 0, !messages.isEmpty else {
                return IOSContextCompactionCoordinator.appendingTruncationNotice(
                    to: Array(messages.suffix(1)),
                    originalCount: originalCount,
                    maxTokens: maxTokens
                )
            }
            guard IOSContextCompactionCoordinator.estimateTokens(messages) > maxTokens else {
                return messages
            }
            let systemMessages = messages.filter { $0.role == MessageRole.system }
            let tail = messages.filter { $0.role != MessageRole.system }
            var selected: [UIMessage] = []
            for message in tail.reversed() {
                selected.insert(message, at: 0)
                if IOSContextCompactionCoordinator.estimateTokens(systemMessages + selected) > maxTokens {
                    selected.removeFirst()
                    if selected.isEmpty {
                        selected.insert(
                            IOSContextCompactionCoordinator.messageFittedToTokenBudget(
                                message,
                                systemMessages: systemMessages,
                                maxTokens: maxTokens
                            ),
                            at: 0
                        )
                    }
                    break
                }
            }
            var result = systemMessages + selected
            guard IOSContextCompactionCoordinator.estimateTokens(result) > maxTokens else {
                return IOSContextCompactionCoordinator.appendingTruncationNotice(
                    to: result,
                    originalCount: originalCount,
                    maxTokens: maxTokens
                )
            }
            result = IOSContextCompactionCoordinator.trimmingCompactHandoffSystemMessages(in: result, maxTokens: maxTokens)
            return IOSContextCompactionCoordinator.appendingTruncationNotice(
                to: result,
                originalCount: originalCount,
                maxTokens: maxTokens
            )
        }

        var messages: [UIMessage] = [
            UIMessage.companion.system(prompt: "System instruction header"),
            UIMessage.companion.system(prompt: "[Conversation compact handoff: v1]\n\n" + String(repeating: "h", count: 400))
        ]
        for index in 0..<240 {
            let role: MessageRole = (index % 2 == 0) ? .user : .assistant
            messages.append(makeMessage(role: role, parts: [
                UIMessagePart.Text(text: "Turn \(index): " + String(repeating: "abc", count: 25), metadata: nil)
            ]))
        }

        for budget in [120, 450, 1_500, 10_000] {
            let actual = IOSContextCompactionCoordinator.fitMessagesToTokenBudget(messages, maxTokens: budget)
            let expected = referenceFit(messages, maxTokens: budget)
            XCTAssertEqual(actual.map(\.role), expected.map(\.role), "Role mismatch for budget \(budget)")
            XCTAssertEqual(actual.map { $0.toText() }, expected.map { $0.toText() }, "Text mismatch for budget \(budget)")
            // Dynamic truncation notice gets a fresh random UUID, so verify non-notice message IDs verbatim.
            let hasNotice = actual.count > 0 && actual.last?.role == .system && actual.last?.toText().hasPrefix("Context note:") == true
            let prefixCount = hasNotice ? actual.count - 1 : actual.count
            XCTAssertEqual(
                Array(actual.prefix(prefixCount)).map(\.id),
                Array(expected.prefix(prefixCount)).map(\.id),
                "Preserved message IDs must match identically for budget \(budget)"
            )
        }

        // Single giant tool output fallback still truncates down into budget.
        let giantTool = UIMessagePart.Tool(
            toolCallId: "call-giant",
            toolName: "read_file",
            input: "{}",
            output: [UIMessagePart.Text(text: String(repeating: "z", count: 20_000), metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let giantMessages = [
            UIMessage.companion.system(prompt: "sys"),
            makeMessage(role: .assistant, parts: [giantTool])
        ]
        let actualGiant = IOSContextCompactionCoordinator.fitMessagesToTokenBudget(giantMessages, maxTokens: 300)
        let expectedGiant = referenceFit(giantMessages, maxTokens: 300)
        XCTAssertEqual(actualGiant.map { $0.toText() }, expectedGiant.map { $0.toText() })
    }

    func testDurableResponseAccumulatorDefersHistoryConcatenationAndSkipsReplayBridgeSnapshots() {
        let model = Model(
            modelId: "gpt-5.4",
            displayName: "gpt-5.4",
            id: KotlinUuid.companion.random(),
            type: .chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let displayMessages = (0..<120).map { idx in
            UIMessage.companion.user(prompt: "History message \(idx)")
        }
        let snapshot = IOSChatBackgroundMessagesSnapshot(displayMessages)
        let first = IOSChatDurableResponseAccumulator(
            displayMessages: displayMessages,
            model: model,
            messagesSnapshot: snapshot
        )

        var seq: Int64 = 1
        for chunkIdx in 0..<40 {
            let delta = UIMessage(
                id: KotlinUuid.companion.random(),
                role: .assistant,
                parts: [UIMessagePart.Text(text: "d\(chunkIdx) ", metadata: nil)],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
            first.append(IOSChatForegroundFixtures.streamChunk(delta: delta, finishReason: ""))
            first.recordCheckpoint(sequenceNumber: seq)
            seq += 1
        }
        // Additional non-chunk SSE lifecycle checkpoints must reuse cached generated suffix.
        for _ in 0..<20 {
            first.recordCheckpoint(sequenceNumber: seq)
            seq += 1
        }

        XCTAssertEqual(snapshot.materializationCountForTesting, 0,
                       "Streaming checkpoints must not eagerly allocate/concatenate displayMessages + suffix until read")
        XCTAssertEqual(first.bridgeSnapshotCountForTesting, 40,
                       "Non-chunk checkpoints must not re-bridge MessageStreamAccumulator.snapshot()")

        let uncheckpointed = UIMessage(
            id: KotlinUuid.companion.random(),
            role: .assistant,
            parts: [UIMessagePart.Text(text: "[UNCHECKPOINTED]", metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
        first.append(IOSChatForegroundFixtures.streamChunk(delta: uncheckpointed, finishReason: ""))

        let publishedBeforeCheckpoint = snapshot.messages
        XCTAssertEqual(snapshot.materializationCountForTesting, 1)
        XCTAssertEqual(publishedBeforeCheckpoint.count, 121)
        XCTAssertFalse(publishedBeforeCheckpoint.last?.toText().contains("[UNCHECKPOINTED]") == true)

        first.recordCheckpoint(sequenceNumber: seq) // seq == 61
        XCTAssertTrue(snapshot.messages.last?.toText().contains("[UNCHECKPOINTED]") == true)

        // Reconnect replay from sequenceNumber 1..30 (< 61) must skip KMP snapshot bridging completely
        // and preserve the fuller prior snapshot.
        let retry = IOSChatDurableResponseAccumulator(
            displayMessages: displayMessages,
            model: model,
            messagesSnapshot: snapshot
        )
        for replaySeq in Int64(1)...Int64(30) {
            let delta = UIMessage(
                id: KotlinUuid.companion.random(),
                role: .assistant,
                parts: [UIMessagePart.Text(text: "r\(replaySeq) ", metadata: nil)],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
            retry.append(IOSChatForegroundFixtures.streamChunk(delta: delta, finishReason: ""))
            retry.recordCheckpoint(sequenceNumber: replaySeq)
        }
        XCTAssertEqual(retry.bridgeSnapshotCountForTesting, 0,
                       "Reconnect replay events earlier than published durableResponseSequenceNumber must skip accumulator.snapshot()")
        XCTAssertTrue(snapshot.messages.last?.toText().contains("[UNCHECKPOINTED]") == true)
    }
}
