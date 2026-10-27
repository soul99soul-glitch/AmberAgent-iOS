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
        workspace.draft = "follow up"; workspace.send()
        XCTAssertEqual(workspace.selectedQueuedMessages.map(\.text), ["follow up"])
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
        workspace.draft = "keep this"; workspace.send()
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
        workspace.draft = "retry separately"; workspace.send()
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
        workspace.draft = "already submitted"; workspace.send()
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
        workspace.draft = "next request"; workspace.send()
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
        let document = DesktopImportedDocument(id: UUID(), name: "note.txt", sourceURL: nil, kind: .text,
            byteCount: 4, text: "note", image: nil, pageCount: nil, note: nil)
        try workspace.addGeneratedImageAttachments([document], to: owner)
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
}
