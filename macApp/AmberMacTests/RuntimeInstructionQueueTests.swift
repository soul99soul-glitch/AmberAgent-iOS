import XCTest
@testable import AmberMac

@MainActor final class RuntimeInstructionQueueTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        var runs: [DesktopGeneration] = []
        var inputs: [[DesktopMessage]] = []
        var contexts: [DesktopRunContext] = []
        var responseIDs: [UUID] = []
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration { DesktopGeneration() }
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID, context: DesktopRunContext) throws -> DesktopGeneration {
            let run = DesktopGeneration()
            runs.append(run); inputs.append(messages); contexts.append(context); responseIDs.append(responseID)
            return run
        }
    }
    private final class Storage: DesktopConversationStorage {
        var values: [DesktopConversation]
        var failSave = false
        var failDelete = false
        init(_ values: [DesktopConversation]) { self.values = values }
        func loadAll() async throws -> [DesktopConversation] { values }
        func save(_ value: DesktopConversation) async throws -> DesktopConversation {
            if failSave { throw DesktopRuntimeError.message("disk full") }
            values.removeAll { $0.id == value.id }; values.append(value); return value
        }
        func updateMetadata(_ id: UUID, title: String?, isPinned: Bool?) async throws {}
        func delete(_ id: UUID) async throws {
            if failDelete { throw DesktopRuntimeError.message("delete failed") }
            values.removeAll { $0.id == id }
        }
    }
    private func setup(tools: Bool = false) throws -> (DesktopWorkspace, Provider, Storage, UUID, UUID) {
        let defaults = UserDefaults(suiteName: "amber.queue.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var config = settings.selectedProvider!
        config.modelID = "test-model"
        try settings.saveProvider(config, apiKey: "test-key")
        let first = DesktopConversation(title: "first"), second = DesktopConversation(title: "second")
        let storage = Storage([first, second]), provider = Provider()
        let tasks = DesktopAgentTasks(defaults: defaults); tasks.toolsEnabled = tools
        let workspace = DesktopWorkspace(settings: settings, storage: storage, provider: provider,
            initialConversations: [first, second], agentTasks: tasks)
        workspace.draft = "initial"; workspace.send()
        return (workspace, provider, storage, first.id, second.id)
    }

    func testTextQueueStartsNewRequestAfterCompletionForOriginalOwner() async throws {
        let (workspace, provider, storage, owner, other) = try setup()
        let tokenA = try XCTUnwrap(workspace.selectedConversationActiveTasks.first?.token)
        workspace.selectSupplementTarget(tokenA)
        workspace.draft = "follow up"; workspace.send()
        XCTAssertEqual(workspace.selectedQueuedMessages.map(\.text), ["follow up"])
        XCTAssertEqual(workspace.selectedQueuedMessages.map(\.kind), [.supplement])
        XCTAssertEqual(provider.runs.count, 1)
        let drained = await provider.contexts[0].drainSteer?()
        XCTAssertTrue(drained?.isEmpty == true)
        workspace.select(other)
        provider.runs[0].yield(.snapshot(text: "done", reasoning: "")); provider.runs[0].yield(.complete)
        for _ in 0..<200 where provider.runs.count < 2 { await Task.yield() }
        XCTAssertEqual(provider.runs.count, 2)
        XCTAssertEqual(workspace.selectedID, other)
        XCTAssertEqual(provider.contexts.last?.conversationID, owner)
        XCTAssertEqual(provider.inputs.last?.filter { $0.role == .user }.map(\.text), ["initial", "follow up"])
        provider.runs.last?.yield(.complete)
        _ = await workspace.flush()
        workspace.select(owner)
        XCTAssertTrue(workspace.selectedQueuedMessages.isEmpty)
        XCTAssertEqual(storage.values.first { $0.id == owner }?.messages.filter { $0.text == "follow up" }.count, 1)
        XCTAssertTrue(storage.values.first { $0.id == other }?.messages.isEmpty == true)
    }

    func testToolBoundaryLeasesOnceAndOnlyDurableCanonicalAckRemovesQueue() async throws {
        let (workspace, provider, storage, owner, _) = try setup(tools: true)
        let tokenA = try XCTUnwrap(workspace.selectedConversationActiveTasks.first?.token)
        workspace.selectSupplementTarget(tokenA)
        workspace.draft = "steer"; workspace.send()
        let drain = try XCTUnwrap(provider.contexts[0].drainSteer)
        let queued = await drain()
        XCTAssertEqual(queued.map(\.text), ["steer"])
        XCTAssertEqual(queued.first?.role, .user)
        XCTAssertEqual(workspace.selectedQueuedMessages.first?.status, .delivering)
        let nextDrain = await drain()
        XCTAssertTrue(nextDrain.isEmpty)
        let persist = try XCTUnwrap(provider.contexts[0].persistTurns)
        let turn = DesktopMessage(id: provider.responseIDs[0], role: .assistant, text: "tool complete")
        storage.failSave = true
        let failedAck = await persist([turn] + queued)
        XCTAssertFalse(failedAck)
        XCTAssertEqual(workspace.selectedQueuedMessages.count, 1)
        storage.failSave = false
        let savedAck = await persist([turn] + queued)
        XCTAssertTrue(savedAck)
        XCTAssertTrue(workspace.selectedQueuedMessages.isEmpty)
        XCTAssertEqual(storage.values.first { $0.id == owner }?.messages.last?.id, queued[0].id)
        workspace.stop(); _ = await workspace.flush()
    }

    func testStopPreservesPendingQueueAndWithdrawalAppendsToDraft() async throws {
        let (workspace, provider, _, _, _) = try setup(tools: true)
        workspace.draft = "keep this"; workspace.queueInstruction()
        let id = try XCTUnwrap(workspace.selectedQueuedMessages.first?.id)
        let drain = try XCTUnwrap(provider.contexts[0].drainSteer)
        workspace.stop()
        let nextDrain = await drain()
        XCTAssertTrue(nextDrain.isEmpty)
        XCTAssertEqual(workspace.selectedQueuedMessages.first?.status, .pending)
        workspace.draft = "new draft"
        workspace.withdrawQueuedInstruction(id)
        XCTAssertEqual(workspace.draft, "new draft\n\nkeep this")
        XCTAssertTrue(workspace.selectedQueuedMessages.isEmpty)
        _ = await workspace.flush()
    }

    func testFailedRunRetainsQueueForExplicitSendAndStaleRunCannotDrain() async throws {
        let (workspace, provider, _, _, _) = try setup(tools: true)
        workspace.draft = "retry separately"; workspace.queueInstruction()
        let oldDrain = try XCTUnwrap(provider.contexts[0].drainSteer)
        provider.runs[0].yield(.failed("offline"))
        for _ in 0..<100 where workspace.isGenerating { await Task.yield() }
        XCTAssertEqual(provider.runs.count, 1)
        XCTAssertEqual(workspace.selectedQueuedMessages.count, 1)
        _ = await workspace.flush()
        workspace.sendQueuedInstructions()
        XCTAssertEqual(provider.runs.count, 2)
        let stale = await oldDrain()
        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(provider.inputs[1].last?.text, "retry separately")
        workspace.stop(); _ = await workspace.flush()
    }

    func testSubmittedInstructionWriteFailureShowsAwaitingSaveWithoutResending() async throws {
        let (workspace, provider, storage, owner, _) = try setup(tools: true)
        workspace.draft = "already submitted"; workspace.queueInstruction()
        let drain = try XCTUnwrap(provider.contexts[0].drainSteer)
        let queued = await drain()
        let call = DesktopMessage(id: provider.responseIDs[0], role: .assistant, text: "tool result")
        let final = DesktopMessage(role: .assistant, text: "done")
        storage.failSave = true
        provider.runs[0].yield(.transcript([call] + queued + [final])); provider.runs[0].yield(.complete)
        for _ in 0..<200 where workspace.isGenerating || workspace.selectedQueuedMessages.first?.status != .awaitingSave { await Task.yield() }
        XCTAssertEqual(workspace.selectedQueuedMessages.first?.status, .awaitingSave)
        workspace.sendQueuedInstructions()
        XCTAssertEqual(provider.runs.count, 1)
        storage.failSave = false
        workspace.retryQueuedMessageSave()
        _ = await workspace.flush()
        XCTAssertTrue(workspace.selectedQueuedMessages.isEmpty)
        XCTAssertEqual(storage.values.first { $0.id == owner }?.messages.filter { $0.id == queued[0].id }.count, 1)
    }

    func testExplicitSendRetriesOriginalResponseSaveBeforeSendingPendingQueueOnce() async throws {
        let (workspace, provider, storage, owner, _) = try setup()
        workspace.draft = "next request"; workspace.queueInstruction()
        storage.failSave = true
        provider.runs[0].yield(.snapshot(text: "completed but not saved", reasoning: "")); provider.runs[0].yield(.complete)
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(provider.runs.count, 1)
        XCTAssertEqual(workspace.selectedQueuedMessages.first?.status, .pending)
        storage.failSave = false
        workspace.sendQueuedInstructions()
        workspace.sendQueuedInstructions()
        for _ in 0..<200 where provider.runs.count < 2 { await Task.yield() }
        XCTAssertEqual(provider.runs.count, 2)
        XCTAssertEqual(provider.inputs[1].filter { $0.text == "next request" }.count, 1)
        XCTAssertTrue(storage.values.first { $0.id == owner }?.messages.contains { $0.text == "completed but not saved" } == true)
        provider.runs[1].yield(.complete)
        _ = await workspace.flush()
        XCTAssertTrue(workspace.selectedQueuedMessages.isEmpty)
    }

    func testDeleteFailureRestoresQueueAndAttachmentQueueRejectionKeepsDraft() async throws {
        let (workspace, provider, storage, owner, _) = try setup()
        let tokenA = try XCTUnwrap(workspace.selectedConversationActiveTasks.first?.token)
        let document = DesktopImportedDocument(id: UUID(), name: "note.txt", sourceURL: nil, kind: .text,
            byteCount: 4, text: "note", image: nil, pageCount: nil, note: nil)
        try workspace.addGeneratedImageAttachments([document], to: owner)
        workspace.selectSupplementTarget(tokenA)
        workspace.draft = "attachment draft"
        workspace.send()
        XCTAssertEqual(workspace.draft, "attachment draft")
        XCTAssertEqual(workspace.pendingAttachments.count, 1)
        XCTAssertTrue(workspace.selectedQueuedMessages.isEmpty)
        XCTAssertTrue(workspace.errorMessage?.contains("仅支持排队文本") == true)
        workspace.removeAttachment(document.id)
        workspace.send()
        storage.failDelete = true
        workspace.delete(owner); _ = await workspace.flush()
        workspace.select(owner)
        XCTAssertEqual(workspace.selectedQueuedMessages.map(\.text), ["attachment draft"])
        let drained = await provider.contexts[0].drainSteer?()
        XCTAssertTrue(drained?.isEmpty == true)
    }

    func testSameConversationConcurrentSendAnswersImmediatelyAndKeepsEachTaskInItsOwnSlot() async throws {
        let (workspace, provider, storage, owner, _) = try setup(tools: true)
        let tasksAfterA = workspace.selectedConversationActiveTasks
        XCTAssertEqual(tasksAfterA.count, 1)
        let tokenA = tasksAfterA[0].token
        let replyAID = provider.responseIDs[0]

        // 1. While Task A is still running, sending a normal message B starts Task B immediately without waiting for A.
        workspace.draft = "second independent question B"
        workspace.send()
        XCTAssertEqual(provider.runs.count, 2, "Normal message B must start immediately while A is running")
        XCTAssertTrue(workspace.selectedQueuedMessages.isEmpty, "Normal message B must not be trapped in supplement queue")
        XCTAssertEqual(workspace.selectedConversationActiveTasks.count, 2)
        let replyBID = provider.responseIDs[1]
        XCTAssertEqual(provider.inputs[1].filter { $0.role == .user }.map(\.text), ["initial", "second independent question B"])
        XCTAssertFalse(provider.inputs[1].contains(where: { $0.id == replyAID }),
            "Task B request history must exclude Task A's uncommitted in-flight assistant placeholder")

        // 2. Task B finishes first while Task A is still running tools.
        provider.runs[1].yield(.snapshot(text: "Answer B ready first", reasoning: ""))
        provider.runs[1].yield(.complete)
        workspace.apply(provider.runs[1].drain(), for: owner, token: workspace.selectedConversationActiveTasks[1].token)
        XCTAssertEqual(workspace.selectedConversationActiveTasks.map(\.token), [tokenA])
        XCTAssertTrue(workspace.isSelectedConversationGenerating, "Conversation remains generating while Task A is still active")

        // 3. User explicitly selects Task A to supplement; Task A consumes it at its next reasoning boundary.
        workspace.selectSupplementTarget(tokenA)
        workspace.draft = "extra constraint for A"
        workspace.send()
        XCTAssertNil(workspace.selectedSupplementRunID, "Supplement selection resets after submitting supplement")
        XCTAssertEqual(workspace.selectedQueuedMessages.count, 1)
        XCTAssertEqual(workspace.selectedQueuedMessages.first?.kind, .supplement)
        XCTAssertEqual(workspace.selectedQueuedMessages.first?.runID, tokenA)

        let drainedByB = await provider.contexts[1].drainSteer?() ?? []
        XCTAssertTrue(drainedByB.isEmpty, "Task B must never consume Task A's supplement")
        let drainedByA = await provider.contexts[0].drainSteer?() ?? []
        XCTAssertEqual(drainedByA.map(\.text), ["extra constraint for A"])

        // 4. Task A emits multi-turn transcript (tool call + steered user + final answer A) and completes.
        //    Task A's turns must stay in Task A's position BEFORE Task B's user and assistant messages!
        let toolTurnA = DesktopMessage(
            id: replyAID,
            role: .assistant,
            text: "",
            tools: [DesktopToolCall(id: "call-1", name: "search_web", input: #"{"query":"swift"}"#, output: "ok", status: .complete)]
        )
        let finalA = DesktopMessage(role: .assistant, text: "Answer A with supplement", state: .streaming)
        provider.runs[0].yield(.transcript([toolTurnA] + drainedByA + [finalA]))
        provider.runs[0].yield(.complete)
        workspace.apply(provider.runs[0].drain(), for: owner, token: tokenA)
        _ = await workspace.flush()

        XCTAssertFalse(workspace.isGenerating)
        let finalMessages = try XCTUnwrap(workspace.selectedConversation?.messages)
        XCTAssertEqual(
            finalMessages.map(\.text),
            ["initial", "", "extra constraint for A", "Answer A with supplement", "second independent question B", "Answer B ready first"]
        )
        XCTAssertEqual(finalMessages.first(where: { $0.id == finalA.id })?.state, .complete)
        XCTAssertEqual(finalMessages.first(where: { $0.id == replyBID })?.state, .complete)
        let savedMessages = try XCTUnwrap(storage.values.first(where: { $0.id == owner })?.messages)
        XCTAssertEqual(savedMessages.map(\.id), finalMessages.map(\.id))
    }

    func testStoppingTaskAOnlyStopsTaskBContinuesAndConcurrencyLimitQueuesTaskC() async throws {
        let (workspace, provider, storage, owner, _) = try setup(tools: true)
        workspace.maxConcurrentTasks = 2
        let tokenA = try XCTUnwrap(workspace.selectedConversationActiveTasks.first?.token)
        let replyAID = provider.responseIDs[0]

        // Start Task B concurrently (reaches maxConcurrentTasks = 2).
        workspace.draft = "task B"
        workspace.send()
        XCTAssertEqual(provider.runs.count, 2)
        let tokenB = try XCTUnwrap(workspace.selectedConversationActiveTasks.last?.token)
        let replyBID = provider.responseIDs[1]
        XCTAssertTrue(workspace.isSelectedConversationAtConcurrencyLimit)

        // Sending Task C while A and B are both running queues C as .newTask with pending status.
        workspace.draft = "task C queued by concurrency cap"
        workspace.send()
        XCTAssertEqual(provider.runs.count, 2, "Task C must wait in queue when concurrency limit is reached")
        XCTAssertEqual(workspace.selectedQueuedMessages.count, 1)
        XCTAssertEqual(workspace.selectedQueuedMessages.first?.kind, .newTask)
        XCTAssertEqual(workspace.selectedQueuedMessages.first?.status, .pending)
        XCTAssertEqual(workspace.selectedQueuedMessages.first?.text, "task C queued by concurrency cap")

        // Stopping Task A ONLY stops Task A; Task B keeps running, and freed slot auto-starts Task C!
        provider.runs[0].yield(.snapshot(text: "partial A", reasoning: ""))
        workspace.stop(tokenA)
        _ = await workspace.flush()

        for _ in 0..<200 where provider.runs.count < 3 { await Task.yield() }
        XCTAssertEqual(provider.runs.count, 3, "Freeing Task A's slot must automatically dequeue and start Task C")
        let tokenC = try XCTUnwrap(workspace.selectedConversationActiveTasks.last?.token)
        XCTAssertEqual(Set(workspace.selectedConversationActiveTasks.map(\.token)), Set([tokenB, tokenC]))

        let msgA = try XCTUnwrap(workspace.selectedConversation?.messages.first(where: { $0.id == replyAID }))
        XCTAssertEqual(msgA.state, .cancelled)
        XCTAssertEqual(msgA.text, "partial A")

        let msgBWhileRunning = try XCTUnwrap(workspace.selectedConversation?.messages.first(where: { $0.id == replyBID }))
        XCTAssertEqual(msgBWhileRunning.state, .streaming, "Stopping A must not cancel B")

        provider.runs[1].yield(.snapshot(text: "completed B", reasoning: ""))
        provider.runs[1].yield(.complete)
        workspace.apply(provider.runs[1].drain(), for: owner, token: tokenB)

        provider.runs[2].yield(.snapshot(text: "completed C", reasoning: ""))
        provider.runs[2].yield(.complete)
        workspace.apply(provider.runs[2].drain(), for: owner, token: tokenC)
        _ = await workspace.flush()

        XCTAssertFalse(workspace.isGenerating)
        XCTAssertTrue(workspace.selectedQueuedMessages.isEmpty)
        let saved = try XCTUnwrap(storage.values.first(where: { $0.id == owner }))
        XCTAssertEqual(
            saved.messages.map { "\($0.role.rawValue):\($0.text):\($0.state.rawValue)" },
            [
                "user:initial:complete",
                "assistant:partial A:cancelled",
                "user:task B:complete",
                "assistant:completed B:complete",
                "user:task C queued by concurrency cap:complete",
                "assistant:completed C:complete",
            ]
        )
    }
}
