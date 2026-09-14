import BackgroundTasks
import UIKit
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSChatBackgroundExecutionTests: XCTestCase {
    @MainActor private final class Audio: BackgroundAudioKeepAliveControlling {
        var isActive = false
        func start() { isActive = true }
        func stop() { isActive = false }
    }

    @MainActor private final class Assertions {
        let audio = Audio()
        var expirations: [() -> Void] = []
        var submissions: [String] = []

        func keepAlive(audioEnabled: Bool, foreground: Bool = true) -> BackgroundGenerationKeepAlive {
            BackgroundGenerationKeepAlive(
                beginBackgroundTask: { [self] _, expire in
                    expirations.append(expire)
                    return UIBackgroundTaskIdentifier(rawValue: expirations.count)
                },
                endBackgroundTask: { _ in },
                submitTaskRequest: { [self] in submissions.append($0.identifier) },
                cancelTaskRequest: { _ in },
                registerLaunchHandler: { _, _ in true },
                isApplicationForeground: { foreground },
                audioKeepAlive: audio,
                isAudioKeepAliveEnabled: { audioEnabled }
            )
        }
    }

    private actor Provider: IOSAgentTextProvider {
        var started = Set<String>()
        var released = Set<String>()
        var callCount = 0
        var resumedWithToolResult = false
        var resumedWithSystemPrompt = false
        let emitTool: Bool
        init(emitTool: Bool = false) { self.emitTool = emitTool }
        func release(_ modelId: String) { released.insert(modelId) }
        func hasStarted(_ modelId: String) -> Bool { started.contains(modelId) }

        private func beginRequest(_ modelId: String, hasToolResult: Bool, hasSystemPrompt: Bool) -> Bool {
            started.insert(modelId)
            callCount += 1
            if callCount >= 3 {
                resumedWithToolResult = hasToolResult
                resumedWithSystemPrompt = hasSystemPrompt
            }
            return emitTool && callCount == 1
        }
        private func isReleased(_ modelId: String) -> Bool { released.contains(modelId) }

        nonisolated func generateText(providerSetting: ProviderSetting, messages: [UIMessage],
                          params: TextGenerationParams) async throws -> MessageChunk {
            let modelId = params.model.modelId
            let hasToolResult = messages.flatMap(\.parts).contains {
                    guard let tool = $0 as? UIMessagePart.Tool else { return false }
                    return tool.toolCallId == "probe-list" && !tool.output.isEmpty
                }
            let hasSystemPrompt = messages.contains {
                    $0.role == .system && $0.parts.contains { ($0 as? UIMessagePart.Text)?.text == "Keep the child system context." }
                }
            let toolTurn = await beginRequest(modelId, hasToolResult: hasToolResult, hasSystemPrompt: hasSystemPrompt)
            if !toolTurn {
                while !(await isReleased(modelId)) { try await Task.sleep(for: .milliseconds(10)) }
            }
            let parts: [UIMessagePart] = toolTurn
                ? [UIMessagePart.Tool(toolCallId: "probe-list", toolName: "tools_list", input: "{}",
                    output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)]
                : [UIMessagePart.Text(text: "finished \(modelId)", metadata: nil)]
            return MessageChunk(
                id: UUID().uuidString, model: modelId,
                choices: [UIMessageChoice(index: 0, delta: nil,
                    message: UIMessage(id: KotlinUuid.companion.random(), role: .assistant,
                        parts: parts,
                        annotations: [], createdAt: Kotlinx_datetimeLocalDateTime(
                            year: 2026, month: 9, day: 15, hour: 0, minute: 0, second: 0, nanosecond: 0),
                        finishedAt: nil, modelId: nil, usage: nil, translation: nil),
                    finishReason: toolTurn ? "tool_calls" : "stop")], usage: nil
            )
        }
    }

    private struct Run {
        let handoff: IOSChatBackgroundHandoff
        let store: IOSConversationStore
        let runtime: ChatToolRuntime
        let directory: URL
    }

    private func makeRun(timeoutSeconds: TimeInterval = 60) async throws -> Run {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("background-run-\(id)")
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let model = Model(modelId: id, displayName: id, id: KotlinUuid.companion.random(),
            type: .chat, customHeaders: [], customBodies: [], inputModalities: [], outputModalities: [],
            abilities: [], tools: Set<BuiltInTools>(), contextWindowTokens: nil, providerOverwrite: nil)
        let setting = ProviderSetting.OpenAI(id: KotlinUuid.companion.random(), enabled: true,
            name: "Background test", models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false, descriptionText: nil, shortDescriptionText: nil, apiKey: "test",
            baseUrl: "https://example.test", chatCompletionsPath: "/chat/completions",
            useResponseApi: false, authMode: .apiKey, brand: .generic)
        let settings = IOSSharedSettingsStore(userDefaults: UserDefaults(suiteName: "background-test-\(id)")!)
        let runtime = ChatToolRuntime(settingsStore: SettingsStore(), sharedSettings: settings,
            localToolExecutor: nil, searchTransport: SearchTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] }))
        let systemMessage = UIMessage(id: KotlinUuid.companion.random(), role: .system,
            parts: [UIMessagePart.Text(text: "Keep the child system context.", metadata: nil)],
            annotations: [], createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026, month: 9, day: 15, hour: 0, minute: 0, second: 0, nanosecond: 0),
            finishedAt: nil, modelId: nil, usage: nil, translation: nil)
        let handoff = IOSChatBackgroundHandoff(runId: id,
            startedAt: Int64(Date().timeIntervalSince1970 * 1000), inputDigest: id,
            conversationId: conversationId, providerId: setting.id.toHexDashString(), providerSetting: setting,
            params: TextGenerationParams(model: model, temperature: nil, topP: nil, maxTokens: nil,
                tools: ToolKt.iosToolDeclarations(names: ["tools_list"]), reasoningLevel: .off, customHeaders: [], customBody: []),
            uploadMessages: [systemMessage], displayMessages: [], mode: .continueModel,
            generativeUiRequirement: .none, generativeUiFallbackAttempted: false,
            fullToolNames: ["tools_list", "workspace_file_read"], subAgentTimeoutSeconds: timeoutSeconds)
        let recorded = try await IOSDurableRunStore().startChatRun(runId: id,
            startedAt: handoff.startedAt, inputDigest: id, conversationId: conversationId.toHexDashString())
        XCTAssertTrue(recorded)
        return Run(handoff: handoff, store: store, runtime: runtime, directory: directory)
    }

    private struct SearchTransport: IOSSearchHTTPTransport {
        func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            throw URLError(.unsupportedURL)
        }
    }

    private func start(_ run: Run, on coordinator: IOSChatBackgroundGenerationCoordinator) {
        XCTAssertTrue(coordinator.start(handoff: run.handoff, conversationStore: run.store,
            toolRuntime: run.runtime, liveActivityController: .shared))
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while try await !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let satisfied = try await condition()
        XCTAssertTrue(satisfied)
    }

    func testAudioOwnedChildrenSurviveShortWindowAndKeepIndependentCancellation() async throws {
        let assertions = Assertions()
        let keepAlive = assertions.keepAlive(audioEnabled: true)
        let provider = Provider()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: keepAlive, provider: provider)
        let first = try await makeRun()
        let second = try await makeRun()
        defer {
            coordinator.cancelJobs(conversationId: first.handoff.conversationId)
            coordinator.cancelJobs(conversationId: second.handoff.conversationId)
            try? FileManager.default.removeItem(at: first.directory)
            try? FileManager.default.removeItem(at: second.directory)
        }
        start(first, on: coordinator)
        start(second, on: coordinator)
        try await waitUntil { await provider.hasStarted(second.handoff.params.model.modelId) }
        XCTAssertTrue(assertions.submissions.isEmpty, "Audio-owned children must not create a second scheduler owner")
        assertions.expirations.forEach { $0() }
        XCTAssertEqual(coordinator.activeJobCount, 2)
        XCTAssertEqual(coordinator.activeSubAgentJobCount, 2)
        XCTAssertEqual(keepAlive.activeLeaseIds.count, 2)
        XCTAssertTrue(coordinator.cancelJob(runId: first.handoff.runId))
        try await waitUntil { coordinator.activeJobCount == 1 }
        XCTAssertTrue(assertions.audio.isActive, "Cancelling one child must retain the other child's audio lease")
        assertions.expirations.first?() // Stale callback cannot cancel the remaining run.
        await provider.release(second.handoff.params.model.modelId)
        try await waitUntil { coordinator.activeJobCount == 0 }
        let snapshot = try await IOSDurableRunStore().snapshot(runId: second.handoff.runId)
        XCTAssertEqual(snapshot?.status, .completed)
        XCTAssertFalse(assertions.audio.isActive)
        let messages = await second.store.messages(for: second.handoff.conversationId)
        XCTAssertTrue(messages?.flatMap(\.parts).contains {
            ($0 as? UIMessagePart.Text)?.text == "finished \(second.handoff.params.model.modelId)"
        } == true)
    }

    func testQueuedSystemAssertionDoesNotDelayStartingChildOrFailItAtUIKitExpiration() async throws {
        let assertions = Assertions()
        let keepAlive = assertions.keepAlive(audioEnabled: false)
        let provider = Provider()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: keepAlive, provider: provider)
        let run = try await makeRun()
        defer {
            coordinator.cancelJobs(conversationId: run.handoff.conversationId)
            try? FileManager.default.removeItem(at: run.directory)
        }
        start(run, on: coordinator)
        try await waitUntil { await provider.hasStarted(run.handoff.params.model.modelId) }
        XCTAssertEqual(assertions.submissions.count, 1)
        XCTAssertTrue(assertions.submissions[0].contains(".keepalive."))
        assertions.expirations.first?()
        XCTAssertEqual(coordinator.activeJobCount, 1)
        await provider.release(run.handoff.params.model.modelId)
        try await waitUntil { coordinator.activeJobCount == 0 }
        let snapshot = try await IOSDurableRunStore().snapshot(runId: run.handoff.runId)
        XCTAssertEqual(snapshot?.status, .completed)
        XCTAssertTrue(keepAlive.activeLeaseIds.isEmpty)
    }

    func testForegroundRecoveryKeepsCompletedToolRoundAndChildSystemContext() async throws {
        let assertions = Assertions()
        let keepAlive = assertions.keepAlive(audioEnabled: false, foreground: false)
        let provider = Provider(emitTool: true)
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: keepAlive, provider: provider)
        let run = try await makeRun()
        defer {
            coordinator.cancelJobs(conversationId: run.handoff.conversationId)
            try? FileManager.default.removeItem(at: run.directory)
        }
        start(run, on: coordinator)
        try await waitUntil { await provider.callCount == 2 }
        assertions.expirations.first?()
        try await waitUntil { await provider.callCount == 3 }
        let keptToolResult = await provider.resumedWithToolResult
        let keptSystem = await provider.resumedWithSystemPrompt
        XCTAssertTrue(keptToolResult)
        XCTAssertTrue(keptSystem)
        await provider.release(run.handoff.params.model.modelId)
        try await waitUntil { coordinator.activeJobCount == 0 }
        let messages = await run.store.messages(for: run.handoff.conversationId)
        let tools = messages?.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool } ?? []
        XCTAssertEqual(tools.filter { $0.toolCallId == "probe-list" && !$0.output.isEmpty }.count, 1)
        XCTAssertFalse(messages?.contains { $0.role == .system } == true)
        let snapshot = try await IOSDurableRunStore().snapshot(runId: run.handoff.runId)
        XCTAssertEqual(snapshot?.status, .completed)
    }

    func testForegroundRecoveryDoesNotReplayAnUnresolvedSideEffect() async throws {
        let assertions = Assertions()
        let keepAlive = assertions.keepAlive(audioEnabled: false, foreground: false)
        let provider = Provider()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: keepAlive, provider: provider)
        let run = try await makeRun()
        defer {
            coordinator.discardDurableResponse(runId: run.handoff.runId)
            try? FileManager.default.removeItem(at: run.directory)
        }
        start(run, on: coordinator)
        try await waitUntil { await provider.callCount == 1 }
        let started = await IOSAgentRunLedger().recordToolCallStarted(runId: run.handoff.runId,
            toolCallId: "pending-write", toolName: "workspace_file_write",
            argsDigest: "pending-write", effectClass: .sideEffect)
        XCTAssertTrue(started)
        assertions.expirations.first?()
        try await waitUntil {
            try await IOSDurableRunStore().snapshot(runId: run.handoff.runId)?.status == .outcomeUnknown
        }
        let calls = await provider.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(coordinator.activeJobCount, 0)
    }

    func testSubAgentTimeoutStopsProviderAndPersistsAnExplicitFailure() async throws {
        let assertions = Assertions()
        let keepAlive = assertions.keepAlive(audioEnabled: true)
        let provider = Provider()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: keepAlive, provider: provider)
        let run = try await makeRun(timeoutSeconds: 1)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        start(run, on: coordinator)
        try await waitUntil { await provider.callCount == 1 }
        try await waitUntil { coordinator.activeJobCount == 0 }
        let snapshot = try await IOSDurableRunStore().snapshot(runId: run.handoff.runId)
        XCTAssertEqual(snapshot?.status, .failed)
        let messages = await run.store.messages(for: run.handoff.conversationId)
        XCTAssertTrue(messages?.contains { $0.toText().contains("运行时限") } == true)
        XCTAssertTrue(keepAlive.activeLeaseIds.isEmpty)
    }

    func testExplicitCancellationRetainsUnknownSideEffectGate() async throws {
        let assertions = Assertions()
        let keepAlive = assertions.keepAlive(audioEnabled: true)
        let provider = Provider()
        let coordinator = IOSChatBackgroundGenerationCoordinator(keepAlive: keepAlive, provider: provider)
        let run = try await makeRun()
        defer { try? FileManager.default.removeItem(at: run.directory) }
        start(run, on: coordinator)
        try await waitUntil { await provider.callCount == 1 }
        let started = await IOSAgentRunLedger().recordToolCallStarted(runId: run.handoff.runId,
            toolCallId: "cancelled-write", toolName: "workspace_file_write",
            argsDigest: "cancelled-write", effectClass: .sideEffect)
        XCTAssertTrue(started)
        XCTAssertTrue(coordinator.cancelJob(runId: run.handoff.runId))
        try await waitUntil { coordinator.activeJobCount == 0 }
        let snapshot = try await IOSDurableRunStore().snapshot(runId: run.handoff.runId)
        XCTAssertEqual(snapshot?.status, .outcomeUnknown)
        XCTAssertTrue(keepAlive.activeLeaseIds.isEmpty)
    }
}
