import Foundation
import UIKit
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSChatDetachedResponseTerminalTests: XCTestCase {
    @MainActor private final class Audio: BackgroundAudioKeepAliveControlling {
        var isActive = false
        var isStartingOrActive: Bool { isActive }
        func start() { isActive = true }
        func stop() { isActive = false }
    }

    private struct UnusedProvider: IOSAgentTextProvider {
        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            throw URLError(.unsupportedURL)
        }
    }

    private struct SearchTransport: IOSSearchHTTPTransport {
        func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            throw URLError(.unsupportedURL)
        }
    }

    private struct Fixture {
        let coordinator: IOSChatBackgroundGenerationCoordinator
        let job: IOSChatBackgroundRuntimeJob
        let requestId: String
        let directory: URL
        let defaultsSuiteName: String
    }

    private func makeFixture(
        saveMiniApp: (@MainActor ([UIMessage], KotlinUuid?) -> ChatMiniAppOutputApplication?)? = nil
    ) async throws -> Fixture {
        let runId = "detached-terminal-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(runId)
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let user = UIMessage.companion.user(prompt: "Create a small app")
        await store.saveCurrent(messages: [user])
        let model = Model(
            modelId: runId, displayName: runId, id: KotlinUuid.companion.random(),
            type: .chat, customHeaders: [], customBodies: [], inputModalities: [], outputModalities: [],
            abilities: [], tools: Set<BuiltInTools>(), contextWindowTokens: nil, providerOverwrite: nil
        )
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(), enabled: true, name: "Detached terminal test", models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false, descriptionText: nil, shortDescriptionText: nil, apiKey: "test",
            baseUrl: "https://api.openai.com/v1", chatCompletionsPath: "/chat/completions",
            useResponseApi: true, authMode: .apiKey, brand: .generic
        )
        let defaultsSuiteName = "detached-terminal-settings-\(runId)"
        let settings = IOSSharedSettingsStore(userDefaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName)))
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(), sharedSettings: settings, localToolExecutor: nil,
            searchTransport: SearchTransport(), mcpManager: IOSMcpManager(serverProvider: { [] })
        )
        let audio = Audio()
        let keepAlive = BackgroundGenerationKeepAlive(
            beginBackgroundTask: { _, _ in .invalid }, endBackgroundTask: { _ in },
            submitTaskRequest: { _ in }, cancelTaskRequest: { _ in },
            registerLaunchHandler: { _, _ in true }, isApplicationForeground: { true },
            audioKeepAlive: audio, isAudioKeepAliveEnabled: { false }
        )
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: keepAlive, provider: UnusedProvider())
        let activity = AgentLiveActivityController(
            fetchSystemSnapshot: { .init(enabled: false, activities: []) },
            requestSystemCard: { _, _, _, _, _ in nil }
        )
        // Durable resume snapshots use the display baseline. Keep upload longer
        // to catch accidental use of the ordinary engine's upload-prefix count.
        let system = message(role: .system, parts: [UIMessagePart.Text(text: "upload-only context", metadata: nil)])
        let handoff = IOSChatBackgroundHandoff(
            runId: runId, startedAt: Int64(Date().timeIntervalSince1970 * 1_000), inputDigest: runId,
            conversationId: conversationId, providerId: provider.id.toHexDashString(), providerSetting: provider,
            params: TextGenerationParams(
                model: model, temperature: nil, topP: nil, maxTokens: nil, tools: [],
                reasoningLevel: .off, customHeaders: [], customBody: []
            ),
            uploadMessages: [system, user], displayMessages: [user], mode: .resumeResponse,
            responseId: "response-\(runId)", generativeUiRequirement: .none,
            generativeUiFallbackAttempted: false, fullToolNames: []
        )
        let didStart = try await coordinator.runStore.startChatRun(
            runId: runId, startedAt: handoff.startedAt, inputDigest: runId,
            conversationId: conversationId.toHexDashString()
        )
        XCTAssertTrue(didStart)
        let job = coordinator.runtimeJob(
            handoff: handoff, conversationStore: store, toolRuntime: runtime,
            liveActivityController: activity, saveMiniAppIfPresent: saveMiniApp
        )
        let requestId = "detached-terminal-test.\(runId)"
        coordinator.activeJobs[requestId] = job
        return Fixture(
            coordinator: coordinator, job: job, requestId: requestId,
            directory: directory, defaultsSuiteName: defaultsSuiteName
        )
    }

    private func cleanUp(_ fixture: Fixture) {
        fixture.coordinator.finish(runId: fixture.job.runId, requestId: fixture.requestId)
        WatchTaskCoordinator.shared.clear(runId: fixture.job.runId)
        UserDefaults(suiteName: fixture.defaultsSuiteName)?.removePersistentDomain(forName: fixture.defaultsSuiteName)
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private func message(role: MessageRole = .assistant, parts: [UIMessagePart]) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(), role: role, parts: parts, annotations: [],
            createdAt: chatNowLocalDateTime(), finishedAt: nil, modelId: nil, usage: nil, translation: nil
        )
    }

    private func complete(_ fixture: Fixture, messages: [UIMessage]) async {
        let state = IOSChatBackgroundRunState()
        XCTAssertTrue(state.reserveTerminal())
        fixture.coordinator.activeRunStates[fixture.requestId] = state
        await fixture.coordinator.completeDetachedResponse(
            job: fixture.job, requestId: fixture.requestId, messages: messages, runState: state
        )
    }

    func testDetachedFailurePreservesPartialMessagePartsAndIdentity() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let instant = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0)
        let partial = message(parts: [
            UIMessagePart.Text(text: "Recovered partial response", metadata: nil),
            UIMessagePart.Reasoning(reasoning: "Recovered reasoning", createdAt: instant, finishedAt: nil, metadata: nil),
            UIMessagePart.Tool(
                toolCallId: "recovered-tool", toolName: "tools_list", input: "{}", output: [],
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )
        ])
        fixture.job.messagesSnapshot.replace(with: fixture.job.displayMessages + [partial])

        let didSave = await fixture.coordinator.persistExpirationFailure(
            job: fixture.job, requestId: fixture.requestId,
            rawMessage: "Detached connection failed", partialAssistantText: nil
        )

        XCTAssertTrue(didSave)
        let persisted = await fixture.job.conversationStore.messages(for: fixture.job.conversationId) ?? []
        let recovered = try XCTUnwrap(persisted.first { $0.id == partial.id })
        XCTAssertTrue(recovered.parts.contains { ($0 as? UIMessagePart.Text)?.text == "Recovered partial response" })
        XCTAssertTrue(recovered.parts.contains { ($0 as? UIMessagePart.Reasoning)?.reasoning == "Recovered reasoning" })
        let tool: UIMessagePart.Tool = try XCTUnwrap(
            recovered.parts.compactMap { $0 as? UIMessagePart.Tool }.first
        )
        XCTAssertEqual(tool.toolCallId, "recovered-tool")
        XCTAssertEqual(tool.toolName, "tools_list")
        XCTAssertEqual(tool.input, "{}")
        XCTAssertFalse(tool.output.isEmpty, "A preserved unfinished call must also receive the terminal failure")
        XCTAssertEqual(persisted.filter { $0.toText().contains("Detached connection failed") }.count, 1)
    }

    func testDetachedFailureBeforeFirstChunkDoesNotPersistUploadOnlyContext() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        _ = fixture.coordinator.makeDetachedResponseAccumulator(job: fixture.job)
        XCTAssertEqual(fixture.job.messagesSnapshot.messages, fixture.job.displayMessages)

        let didSave = await fixture.coordinator.persistExpirationFailure(
            job: fixture.job, requestId: fixture.requestId,
            rawMessage: "Disconnected before the first chunk", partialAssistantText: nil
        )

        XCTAssertTrue(didSave)
        let persisted = await fixture.job.conversationStore.messages(for: fixture.job.conversationId) ?? []
        XCTAssertEqual(persisted.map(\.role), [.user, .assistant])
        XCTAssertEqual(persisted.first?.id, fixture.job.displayMessages.first?.id)
        XCTAssertFalse(persisted.contains { $0.toText().contains("upload-only context") })
        XCTAssertTrue(persisted.last?.toText().contains("Disconnected before the first chunk") == true)
    }

    func testReconnectWithoutChunksPreservesPriorPartialForFailure() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let first = fixture.coordinator.makeDetachedResponseAccumulator(job: fixture.job)
        first.append(IOSChatForegroundFixtures.chunk(
            with: message(parts: [UIMessagePart.Text(text: "Partial before disconnect", metadata: nil)])
        ))
        first.recordCheckpoint(sequenceNumber: 8)
        let received = fixture.job.messagesSnapshot.messages
        let partialId = try XCTUnwrap(received.last?.id)

        let retry = fixture.coordinator.makeDetachedResponseAccumulator(job: fixture.job)
        XCTAssertEqual(retry.messages.map(\.id), fixture.job.displayMessages.map(\.id),
                       "Each transport replay must still start from its own clean accumulator")
        let didSave = await fixture.coordinator.persistExpirationFailure(
            job: fixture.job, requestId: fixture.requestId,
            rawMessage: "Retry disconnected without chunks", partialAssistantText: nil
        )
        XCTAssertTrue(didSave)
        let persisted = await fixture.job.conversationStore.messages(for: fixture.job.conversationId) ?? []
        XCTAssertTrue(persisted.contains { $0.id == partialId && $0.toText() == "Partial before disconnect" })
        XCTAssertEqual(persisted.filter { $0.toText().contains("Retry disconnected without chunks") }.count, 1)
    }

    func testShorterReplayPreservesEarlierPartsAndIdentityForFailure() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let first = fixture.coordinator.makeDetachedResponseAccumulator(job: fixture.job)
        let prefix = IOSChatForegroundFixtures.streamChunk(delta: message(parts: [
            UIMessagePart.Text(text: "AB", metadata: nil)
        ]))
        let suffix = IOSChatForegroundFixtures.streamChunk(delta: message(parts: [
            UIMessagePart.Text(text: "CDEF", metadata: nil),
            UIMessagePart.Reasoning(
                reasoning: "Reasoning before disconnect",
                createdAt: KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 0),
                finishedAt: nil, metadata: nil
            ),
            UIMessagePart.Tool(
                toolCallId: "replay-tool", toolName: "tools_list", input: "{}", output: [],
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )
        ]))
        first.append(prefix)
        first.recordCheckpoint(sequenceNumber: 1)
        first.append(suffix)
        first.recordCheckpoint(sequenceNumber: 5)
        let received = fixture.job.messagesSnapshot.messages
        let prior = try XCTUnwrap(received.last)

        let retry = fixture.coordinator.makeDetachedResponseAccumulator(job: fixture.job)
        retry.append(prefix)
        retry.recordCheckpoint(sequenceNumber: 1)
        XCTAssertEqual(fixture.job.messagesSnapshot.messages, received,
                       "Replaying a valid earlier event cannot replace a more complete partial")
        let didSave = await fixture.coordinator.persistExpirationFailure(
            job: fixture.job, requestId: fixture.requestId,
            rawMessage: "Disconnected while replaying prefix", partialAssistantText: nil
        )

        XCTAssertTrue(didSave)
        let persisted = await fixture.job.conversationStore.messages(for: fixture.job.conversationId) ?? []
        let saved = try XCTUnwrap(persisted.first { $0.id == prior.id })
        XCTAssertEqual(saved.parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(), "ABCDEF")
        XCTAssertEqual(saved.parts.compactMap { ($0 as? UIMessagePart.Reasoning)?.reasoning },
                       ["Reasoning before disconnect"])
        let tool: UIMessagePart.Tool = try XCTUnwrap(saved.parts.compactMap { $0 as? UIMessagePart.Tool }.first)
        XCTAssertEqual(tool.toolCallId, "replay-tool")
        XCTAssertEqual(tool.input, "{}")
        XCTAssertFalse(tool.output.isEmpty)
        XCTAssertFalse(persisted.contains { $0.toText().contains("upload-only context") })
    }

    func testLaterResumeWithoutChunksPreservesPublishedPartialForFailure() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let first = fixture.coordinator.makeDetachedResponseAccumulator(job: fixture.job)
        first.append(IOSChatForegroundFixtures.streamChunk(delta: message(parts: [
            UIMessagePart.Text(text: "Partial awaiting a later foreground resume", metadata: nil)
        ])))
        first.recordCheckpoint(sequenceNumber: 8)
        let received = fixture.job.messagesSnapshot.messages
        let partialId = try XCTUnwrap(received.last?.id)

        _ = fixture.coordinator.makeDetachedResponseAccumulator(job: fixture.job)
        XCTAssertEqual(fixture.job.messagesSnapshot.messages, received)
        let didSave = await fixture.coordinator.persistExpirationFailure(
            job: fixture.job, requestId: fixture.requestId,
            rawMessage: "Later resume disconnected before chunks", partialAssistantText: nil
        )

        XCTAssertTrue(didSave)
        let persisted = await fixture.job.conversationStore.messages(for: fixture.job.conversationId) ?? []
        XCTAssertTrue(persisted.contains {
            $0.id == partialId && $0.toText() == "Partial awaiting a later foreground resume"
        })
    }

    func testReplayPublishesAfterCatchingUpAndCompletionUsesCurrentAccumulator() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let first = fixture.coordinator.makeDetachedResponseAccumulator(job: fixture.job)
        let prefix = IOSChatForegroundFixtures.streamChunk(delta: message(parts: [
            UIMessagePart.Text(text: "AB", metadata: nil)
        ]))
        let suffix = IOSChatForegroundFixtures.streamChunk(delta: message(parts: [
            UIMessagePart.Text(text: "CDEF", metadata: nil)
        ]))
        first.append(prefix)
        first.recordCheckpoint(sequenceNumber: 1)
        first.append(suffix)
        first.recordCheckpoint(sequenceNumber: 5)
        let prior = fixture.job.messagesSnapshot.messages

        let retry = fixture.coordinator.makeDetachedResponseAccumulator(job: fixture.job)
        retry.append(prefix)
        retry.recordCheckpoint(sequenceNumber: 1)
        XCTAssertEqual(fixture.job.messagesSnapshot.messages, prior)
        retry.append(suffix)
        XCTAssertEqual(fixture.job.messagesSnapshot.messages, prior,
                       "Publish only after the checkpoint following all chunks for the event")
        retry.recordCheckpoint(sequenceNumber: 5)
        XCTAssertEqual(fixture.job.messagesSnapshot.messages, retry.messages)
        retry.append(IOSChatForegroundFixtures.streamChunk(delta: message(parts: [
            UIMessagePart.Text(text: "G", metadata: nil)
        ])))
        retry.recordCheckpoint(sequenceNumber: 6)
        XCTAssertEqual(fixture.job.messagesSnapshot.messages.last?.toText(), "ABCDEFG")

        await complete(fixture, messages: retry.messages)

        let persisted = await fixture.job.conversationStore.messages(for: fixture.job.conversationId) ?? []
        XCTAssertEqual(persisted.last?.id, retry.messages.last?.id)
        XCTAssertEqual(persisted.last?.toText(), "ABCDEFG")
        XCTAssertEqual(persisted.filter { $0.role == .assistant }.count, 1,
                       "Replay replaces its prior snapshot instead of concatenating two streams")
    }

    func testDetachedMiniAppApplicationFailureRecordsFailedRun() async throws {
        let fixture = try await makeFixture { messages, _ in
            ChatMiniAppOutputApplication(messages: messages, outcome: .failed)
        }
        defer { cleanUp(fixture) }
        let failure = message(parts: [UIMessagePart.Text(text: "MiniApp JSON could not be parsed", metadata: nil)])

        await complete(fixture, messages: fixture.job.displayMessages + [failure])

        let snapshot = try await fixture.coordinator.runStore.snapshot(runId: fixture.job.runId)
        XCTAssertEqual(snapshot?.status, .failed)
        let persisted = await fixture.job.conversationStore.messages(for: fixture.job.conversationId) ?? []
        XCTAssertTrue(persisted.contains { $0.id == failure.id && $0.toText().contains("MiniApp JSON could not be parsed") })
    }

    func testDetachedMiniAppSuccessSyncsWorkspaceAfterConversationSave() async throws {
        var syncCount = 0
        var commitCount = 0
        var rollbackCount = 0
        var storedAssistantAtSync: KotlinUuid?
        var storeAtSync: IOSConversationStore?
        let fixture = try await makeFixture { messages, _ in
            ChatMiniAppOutputApplication(
                messages: messages, outcome: .applied,
                commit: { commitCount += 1; return true },
                rollback: { rollbackCount += 1; return true },
                syncWorkspace: {
                    syncCount += 1
                    storedAssistantAtSync = storeAtSync?.currentConversation?.currentMessages.last?.id
                    return nil
                }
            )
        }
        defer { cleanUp(fixture) }
        storeAtSync = fixture.job.conversationStore
        let assistant = message(parts: [UIMessagePart.Text(text: "MiniApp applied", metadata: nil)])

        await complete(fixture, messages: fixture.job.displayMessages + [assistant])

        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(syncCount, 1)
        XCTAssertEqual(storedAssistantAtSync, assistant.id, "Workspace sync must follow conversation persistence")
        let snapshot = try await fixture.coordinator.runStore.snapshot(runId: fixture.job.runId)
        XCTAssertEqual(snapshot?.status, .completed)
    }

    func testDetachedMiniAppWorkspaceFailurePersistsReplacement() async throws {
        var syncCount = 0
        var expectedReplacement: UIMessage?
        let fixture = try await makeFixture { messages, _ in
            guard let assistant = messages.last else { return nil }
            let replacement = UIMessage(
                id: assistant.id, role: assistant.role,
                parts: [UIMessagePart.Text(text: "MiniApp applied; Workspace sync failed", metadata: nil)],
                annotations: assistant.annotations, createdAt: assistant.createdAt, finishedAt: assistant.finishedAt,
                modelId: assistant.modelId, usage: assistant.usage, translation: assistant.translation
            )
            expectedReplacement = replacement
            var replaced = messages
            replaced[replaced.count - 1] = replacement
            return ChatMiniAppOutputApplication(
                messages: messages, outcome: .applied,
                syncWorkspace: {
                    syncCount += 1
                    return ChatMiniAppWorkspaceSyncFailure(messages: replaced, replacementMessage: replacement)
                }
            )
        }
        defer { cleanUp(fixture) }
        let assistant = message(parts: [UIMessagePart.Text(text: "MiniApp applied", metadata: nil)])

        await complete(fixture, messages: fixture.job.displayMessages + [assistant])

        XCTAssertEqual(syncCount, 1)
        let replacement = try XCTUnwrap(expectedReplacement)
        let persisted = await fixture.job.conversationStore.messages(for: fixture.job.conversationId) ?? []
        let saved = try XCTUnwrap(persisted.first { $0.id == replacement.id })
        XCTAssertEqual(saved.toText(), replacement.toText())
        let snapshot = try await fixture.coordinator.runStore.snapshot(runId: fixture.job.runId)
        XCTAssertEqual(snapshot?.status, .completed, "Workspace sync failure does not undo an applied MiniApp")
    }

    func testDetachedMiniAppSaveFailureDoesNotSyncWorkspace() async throws {
        var syncCount = 0
        var commitCount = 0
        var rollbackCount = 0
        let fixture = try await makeFixture { messages, _ in
            ChatMiniAppOutputApplication(
                messages: messages, outcome: .applied,
                commit: { commitCount += 1; return true },
                rollback: { rollbackCount += 1; return true },
                syncWorkspace: { syncCount += 1; return nil }
            )
        }
        defer { cleanUp(fixture) }
        await fixture.job.conversationStore.deleteConversation(id: fixture.job.conversationId)
        let assistant = message(parts: [UIMessagePart.Text(text: "MiniApp applied", metadata: nil)])

        await complete(fixture, messages: fixture.job.displayMessages + [assistant])

        XCTAssertEqual(commitCount, 0)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertEqual(syncCount, 0)
        let snapshot = try await fixture.coordinator.runStore.snapshot(runId: fixture.job.runId)
        XCTAssertEqual(snapshot?.status, .recoveryPending)
        let persisted = await fixture.job.conversationStore.messages(for: fixture.job.conversationId)
        XCTAssertNil(persisted)
    }
}
