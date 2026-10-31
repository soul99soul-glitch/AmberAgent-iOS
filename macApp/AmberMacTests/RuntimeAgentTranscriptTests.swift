import XCTest
@testable import AmberMac

@MainActor final class RuntimeAgentTranscriptTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        var runs: [DesktopGeneration] = []
        var messages: [[DesktopMessage]] = []
        var responseIDs: [UUID] = []
        var contexts: [DesktopRunContext?] = []
        var asynchronousCancellation = false
        private func begin(_ input: [DesktopMessage], responseID: UUID, context: DesktopRunContext?) -> DesktopGeneration {
            let run = DesktopGeneration(cancellationCompletesAsynchronously: asynchronousCancellation)
            runs.append(run); messages.append(input); responseIDs.append(responseID); contexts.append(context)
            return run
        }
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            begin(messages, responseID: responseID, context: nil)
        }
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID, context: DesktopRunContext) throws -> DesktopGeneration {
            begin(messages, responseID: responseID, context: context)
        }
    }
    private func setup(_ conversation: DesktopConversation, toolsEnabled: Bool = true,
        subagentsEnabled: Bool = false) throws -> (DesktopWorkspace, Provider, DesktopMemoryConversationStorage) {
        let defaults = UserDefaults(suiteName: "amber.agent-transcript.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var config = settings.selectedProvider!
        config.modelID = "test-model"
        try settings.saveProvider(config, apiKey: "test-key")
        let provider = Provider()
        let storage = DesktopMemoryConversationStorage([conversation])
        let tasks = DesktopAgentTasks(defaults: defaults)
        tasks.toolsEnabled = toolsEnabled
        tasks.subagentsEnabled = subagentsEnabled
        return (DesktopWorkspace(settings: settings, storage: storage, provider: provider,
            initialConversations: [conversation], agentTasks: tasks), provider, storage)
    }

    func testMultipleToolTurnsReplaceOnlyRunSuffixAndTerminalTargetsLastAssistant() async throws {
        let original = DesktopConversation(messages: [DesktopMessage(role: .user, text: "old"), DesktopMessage(role: .assistant, text: "old answer")])
        let (workspace, provider, storage) = try setup(original)
        workspace.draft = "read file"
        workspace.send()
        let prefix = try XCTUnwrap(workspace.selectedConversation).messages.dropLast()
        XCTAssertEqual(provider.contexts[0]?.conversationID, original.id)
        XCTAssertEqual(provider.contexts[0]?.toolsEnabled, true)
        let toolTurn = DesktopMessage(id: provider.responseIDs[0], role: .assistant, text: "reading", canonicalJSON: "tool-call-payload")
        let final = DesktopMessage(role: .assistant, text: "file result", state: .streaming, canonicalJSON: "final-payload")
        provider.runs[0].yield(.transcript([toolTurn, final]))
        provider.runs[0].yield(.complete)
        workspace.stop()
        _ = await workspace.flush()
        let saved = try XCTUnwrap(storage.values.first)
        XCTAssertEqual(Array(saved.messages.prefix(prefix.count)), Array(prefix))
        XCTAssertEqual(saved.messages.suffix(2).map(\.id), [toolTurn.id, final.id])
        XCTAssertEqual(saved.messages.last?.state, .complete)
        XCTAssertEqual(saved.messages.last?.canonicalJSON, "final-payload")
        XCTAssertFalse(workspace.isGenerating)
    }

    func testSubagentOnlyGenerationKeepsOrdinaryToolsOffButEnablesEngine() async throws {
        let original = DesktopConversation(messages: [DesktopMessage(role: .user, text: "old")])
        let (workspace, provider, _) = try setup(original, toolsEnabled: false, subagentsEnabled: true)
        workspace.draft = "dispatch a read-only sub-agent"
        workspace.send()

        let context = try XCTUnwrap(provider.contexts.first ?? nil)
        XCTAssertFalse(context.toolsEnabled)
        XCTAssertTrue(context.subagentsEnabled)
        XCTAssertTrue(context.engineEnabled)

        workspace.stop()
        _ = await workspace.flush()
    }

    func testStopDrainsAcceptedTranscriptAndRejectsLateReplacement() async throws {
        let original = DesktopConversation(messages: [DesktopMessage(role: .user, text: "original")])
        let (workspace, provider, storage) = try setup(original)
        workspace.draft = "tools"
        workspace.send()
        let accepted = DesktopMessage(role: .assistant, text: "accepted final part", state: .streaming)
        provider.runs[0].yield(.transcript([accepted]))
        workspace.stop()
        provider.runs[0].yield(.transcript([DesktopMessage(role: .assistant, text: "late")]))
        _ = await workspace.flush()
        XCTAssertEqual(storage.values.first?.messages.last?.id, accepted.id)
        XCTAssertEqual(storage.values.first?.messages.last?.state, .cancelled)
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.text, "accepted final part")
        XCTAssertFalse(workspace.isGenerating)
    }

    func testAsyncStopWaitsForFinalCanonicalTranscriptBeforeFlush() async throws {
        let original = DesktopConversation(messages: [DesktopMessage(role: .user, text: "old")])
        let (workspace, provider, storage) = try setup(original)
        provider.asynchronousCancellation = true
        workspace.draft = "tools"
        workspace.send()
        workspace.stop()
        XCTAssertTrue(workspace.isStopping)
        XCTAssertTrue(workspace.isGenerating)
        let final = DesktopMessage(id: provider.responseIDs[0], role: .assistant,
            text: "accepted after cancellation request", state: .streaming, canonicalJSON: "final-accepted-parts")
        provider.runs[0].yield(.transcript([final]))
        provider.runs[0].yield(.cancelled)
        _ = await workspace.flush()
        XCTAssertFalse(workspace.isGenerating)
        XCTAssertFalse(workspace.isStopping)
        XCTAssertEqual(storage.values.first?.messages.last?.canonicalJSON, "final-accepted-parts")
        XCTAssertEqual(storage.values.first?.messages.last?.state, .cancelled)
    }

    func testDeletingAsynchronouslyStoppingOwnerDoesNotBlockNextConversation() async throws {
        let original = DesktopConversation()
        let (workspace, provider, storage) = try setup(original)
        provider.asynchronousCancellation = true
        workspace.draft = "tools"
        workspace.send()
        workspace.delete(original.id)
        provider.runs[0].yield(.transcript([DesktopMessage(role: .assistant, text: "late")]))
        provider.runs[0].yield(.cancelled)
        _ = await workspace.flush()
        XCTAssertFalse(workspace.isGenerating)
        XCTAssertFalse(workspace.isStopping)
        XCTAssertTrue(workspace.conversations.isEmpty)
        XCTAssertTrue(storage.values.isEmpty)
        workspace.createConversation()
        XCTAssertNotEqual(workspace.selectedID, original.id)
    }

    func testAgentProjectionOnlyMarksTrailingAssistantAsStreaming() {
        for role in [DesktopMessageRole.user, .assistant, .system, .tool] {
            XCTAssertEqual(DesktopMessageState.agentProjection(role: role, isLast: true),
                role == .assistant ? .streaming : .complete)
            XCTAssertEqual(DesktopMessageState.agentProjection(role: role, isLast: false), .complete)
        }
    }

    func testCancellingAfterDurableSteerKeepsCompletedTurnAndRetryableReply() async throws {
        let original = DesktopConversation()
        let (workspace, provider, storage) = try setup(original)
        provider.asynchronousCancellation = true
        workspace.draft = "first tool request"; workspace.send()
        workspace.draft = "accepted follow-up"; workspace.send()
        let context = try XCTUnwrap(provider.contexts.first ?? nil)
        let leased = await context.drainSteer?()
        let queuedUser = try XCTUnwrap(leased?.first)
        let priorAssistant = DesktopMessage(id: provider.responseIDs[0], role: .assistant, text: "completed tool turn")
        var projected = [priorAssistant, queuedUser]
        for index in projected.indices {
            projected[index].state = .agentProjection(role: projected[index].role, isLast: index == projected.count - 1)
        }
        let acknowledged = await context.persistTurns?(projected)
        XCTAssertEqual(acknowledged, true)
        XCTAssertTrue(workspace.selectedQueuedMessages.isEmpty)

        workspace.stop()
        provider.runs[0].yield(.transcript(projected))
        provider.runs[0].yield(.cancelled)
        let flushed = await workspace.flush()
        XCTAssertTrue(flushed)
        let saved = try XCTUnwrap(storage.values.first)
        XCTAssertEqual(saved.messages.first(where: { $0.id == priorAssistant.id })?.state, .complete)
        XCTAssertEqual(saved.messages.first(where: { $0.id == queuedUser.id })?.state, .complete)
        let reply = try XCTUnwrap(saved.messages.last)
        XCTAssertEqual(reply.role, .assistant)
        XCTAssertEqual(reply.state, .cancelled)
        XCTAssertTrue(reply.text.isEmpty)
        XCTAssertNotEqual(reply.id, priorAssistant.id)

        let retry = try XCTUnwrap(workspace.retry())
        await retry.value
        XCTAssertEqual(provider.messages.count, 2)
        XCTAssertEqual(provider.messages[1].filter { $0.id == queuedUser.id }.count, 1)
        XCTAssertEqual(provider.messages[1].first(where: { $0.id == priorAssistant.id })?.text, priorAssistant.text)
        provider.runs[1].yield(.cancelled)
        _ = await workspace.flush()
    }

    func testKnowledgeContextIsInjectedAndUnreadableStorePreventsProviderCall() async throws {
        let original = DesktopConversation()
        let (workspace, provider, _) = try setup(original)
        try workspace.knowledge.saveSoul("Use concise Chinese answers.")
        workspace.draft = "hello"
        workspace.send()
        XCTAssertTrue(provider.messages[0].first?.text.contains("Use concise Chinese answers.") == true)
        workspace.stop()
        let memoryDirectory = workspace.knowledge.directory.appendingPathComponent("memories", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: memoryDirectory.appendingPathComponent("memories.json"))
        XCTAssertThrowsError(try workspace.knowledge.reload())
        workspace.draft = "must not omit knowledge silently"
        workspace.send()
        XCTAssertEqual(provider.runs.count, 1)
        XCTAssertTrue(workspace.errorMessage?.contains("读取本地知识上下文失败") == true)
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.state, .failed)
        _ = await workspace.flush()
    }

    func testCompactedInputNeverReplacesCanonicalHistoryDuringToolTurns() async throws {
        let original = DesktopConversation(messages: (0..<8).map {
            DesktopMessage(role: $0.isMultiple(of: 2) ? .user : .assistant,
                text: "turn \($0) " + String(repeating: "long original history ", count: 50))
        })
        let (workspace, provider, _) = try setup(original)
        workspace.requestInsight(.compact)
        while provider.runs.isEmpty { await Task.yield() }
        XCTAssertNil(provider.contexts[0])
        provider.runs[0].yield(.snapshot(text: "Retained goals.", reasoning: ""))
        provider.runs[0].yield(.complete)
        await workspace.insights.waitUntilIdle(original.id)
        workspace.draft = "continue tools"
        workspace.send()
        XCTAssertLessThan(provider.messages[1].count, original.messages.count)
        // v2 handoffs travel as a user turn, so the Claude path cannot flatten them into the system prompt.
        XCTAssertEqual(provider.messages[1].first?.role, .user)
        let final = DesktopMessage(id: provider.responseIDs[1], role: .assistant, text: "new final")
        provider.runs[1].yield(.transcript([final]))
        provider.runs[1].yield(.complete)
        workspace.stop()
        XCTAssertEqual(Array(workspace.selectedConversation!.messages.prefix(original.messages.count)), original.messages)
        XCTAssertEqual(workspace.selectedConversation?.messages.count, original.messages.count + 2)
        _ = await workspace.flush()
    }
}
