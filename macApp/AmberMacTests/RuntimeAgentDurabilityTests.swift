import XCTest
@testable import AmberMac

@MainActor final class RuntimeAgentDurabilityTests: XCTestCase {
    private final class Storage: DesktopConversationStorage {
        var values: [DesktopConversation]
        var failMessages = false
        var failMetadata = false
        var writes = 0
        init(_ values: [DesktopConversation]) { self.values = values }
        func loadAll() async throws -> [DesktopConversation] { values }
        func save(_ value: DesktopConversation) async throws -> DesktopConversation {
            writes += 1
            if failMessages { throw DesktopRuntimeError.message("message write failure") }
            values.removeAll { $0.id == value.id }; values.append(value); return value
        }
        func updateMetadata(_ id: UUID, title: String?, isPinned: Bool?) async throws {
            if failMetadata { throw DesktopRuntimeError.message("metadata write failure") }
        }
        func delete(_ id: UUID) async throws { values.removeAll { $0.id == id } }
    }
    private final class Provider: DesktopTextProvider {
        var context: DesktopRunContext?
        var responseID: UUID?
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration { DesktopGeneration() }
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID, context: DesktopRunContext) throws -> DesktopGeneration {
            self.context = context; self.responseID = responseID; return DesktopGeneration()
        }
    }
    private func setup() throws -> (DesktopWorkspace, Provider, Storage, UUID, UUID) {
        let defaults = UserDefaults(suiteName: "amber.agent-durability.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var config = settings.selectedProvider!
        config.modelID = "test-model"
        try settings.saveProvider(config, apiKey: "test-key")
        let first = DesktopConversation(title: "first"), second = DesktopConversation(title: "second")
        let storage = Storage([first, second]), provider = Provider()
        let workspace = DesktopWorkspace(settings: settings, storage: storage, provider: provider, initialConversations: [first, second])
        workspace.draft = "run tools"
        workspace.send()
        return (workspace, provider, storage, first.id, second.id)
    }

    func testMessageWriteFailureDoesNotAcknowledgeToolDispatch() async throws {
        let (workspace, provider, storage, owner, _) = try setup()
        storage.failMessages = true
        let persist = try XCTUnwrap(provider.context?.persistTurns)
        let turn = DesktopMessage(id: provider.responseID!, role: .assistant, text: "tool arguments", canonicalJSON: "tool-call-arguments")
        let acknowledged = await persist([turn])
        XCTAssertFalse(acknowledged)
        XCTAssertTrue(storage.values.first { $0.id == owner }?.messages.isEmpty == true)
        storage.failMessages = false
        let retry = await persist([turn])
        XCTAssertTrue(retry)
        XCTAssertEqual(storage.values.first { $0.id == owner }?.messages.last?.canonicalJSON, turn.canonicalJSON)
        workspace.stop()
        _ = await workspace.flush()
    }

    func testSelectedConversationChangesDoNotRedirectDurableCheckpointAndMetadataErrorDoesNotBlockAck() async throws {
        let (workspace, provider, storage, owner, other) = try setup()
        storage.failMetadata = true
        workspace.rename(owner, title: "manual title")
        let persist = try XCTUnwrap(provider.context?.persistTurns)
        let turn = DesktopMessage(id: provider.responseID!, role: .assistant, text: "durable tool arguments")
        workspace.select(other)
        let acknowledged = await persist([turn])
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(storage.values.first { $0.id == owner }?.messages.last?.text, turn.text)
        XCTAssertTrue(storage.values.first { $0.id == other }?.messages.isEmpty == true)
        XCTAssertNil(workspace.errorMessage)
        workspace.select(owner)
        XCTAssertNotNil(workspace.errorMessage)
        workspace.stop()
        storage.failMetadata = false
        _ = await workspace.flush()
        XCTAssertNil(workspace.errorMessage)
    }

    func testStoppedOrDeletedRunDoesNotAcknowledgeOrWriteLateTurn() async throws {
        let (workspace, provider, storage, owner, _) = try setup()
        let persist = try XCTUnwrap(provider.context?.persistTurns)
        workspace.delete(owner)
        _ = await workspace.flush()
        let writes = storage.writes
        let late = await persist([DesktopMessage(role: .assistant, text: "late tool")])
        XCTAssertFalse(late)
        XCTAssertEqual(storage.writes, writes)
        XCTAssertFalse(storage.values.contains { $0.id == owner })
        XCTAssertFalse(workspace.conversations.contains { $0.id == owner })
    }
}
