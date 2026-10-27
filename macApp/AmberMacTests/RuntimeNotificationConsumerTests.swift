import XCTest
@testable import AmberMac

@MainActor final class RuntimeNotificationConsumerTests: XCTestCase {
    private final class Delivery: DesktopNotificationDelivery {
        var values: [[String: String]] = []
        func requestAuthorization() async throws -> Bool { XCTFail("Completion never requests permission"); return true }
        func isAuthorized() async -> Bool { true }
        func send(identifier: String, title: String, body: String, userInfo: [String: String]) async throws { values.append(userInfo) }
    }
    private final class Provider: DesktopTextProvider {
        var runs: [DesktopGeneration] = []
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            let run = DesktopGeneration(); runs.append(run); return run
        }
    }
    private final class Storage: DesktopConversationStorage {
        var fail = false
        func loadAll() async throws -> [DesktopConversation] { [] }
        func save(_ value: DesktopConversation) async throws -> DesktopConversation {
            if fail { throw DesktopRuntimeError.message("disk failure") }
            return value
        }
        func updateMetadata(_ id: UUID, title: String?, isPinned: Bool?) async throws {}
        func delete(_ id: UUID) async throws {}
    }
    private func setup() throws -> (DesktopWorkspace, Provider, Storage, Delivery, UUID, UUID) {
        let defaults = UserDefaults(suiteName: "amber.notification-consumer.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var config = settings.selectedProvider!
        config.modelID = "test-model"
        try settings.saveProvider(config, apiKey: "test-key")
        settings.notificationsEnabled = true
        let provider = Provider(), storage = Storage(), delivery = Delivery()
        let first = DesktopConversation(), second = DesktopConversation()
        let tasks = DesktopAgentTasks(defaults: defaults)
        tasks.toolsEnabled = false
        let workspace = DesktopWorkspace(settings: settings, storage: storage, provider: provider, initialConversations: [first, second],
            agentTasks: tasks, notifications: DesktopNotifications(settings: settings, delivery: delivery))
        return (workspace, provider, storage, delivery, first.id, second.id)
    }
    private func wait(_ delivery: Delivery, count: Int) async {
        let deadline = Date().addingTimeInterval(2)
        while delivery.values.count < count, Date() < deadline { await Task.yield() }
    }

    func testPlainCompletionKeepsOriginalOwnerAndCapturedToolsMode() async throws {
        let (workspace, provider, _, delivery, first, second) = try setup()
        workspace.draft = "first request"
        workspace.send()
        workspace.select(second)
        workspace.agentTasks.toolsEnabled = true
        provider.runs[0].yield(.complete)
        workspace.stop()
        _ = await workspace.flush()
        await wait(delivery, count: 1)
        XCTAssertEqual(delivery.values.count, 1)
        XCTAssertEqual(delivery.values[0]["conversationID"], first.uuidString.lowercased())
        XCTAssertEqual(delivery.values[0]["outcome"], "completed")
        workspace.draft = "tool request"
        workspace.send()
        provider.runs[1].yield(.complete)
        workspace.stop()
        _ = await workspace.flush()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(delivery.values.count, 1)
    }

    func testCancellationAndPersistenceFailureDoNotSendCompletionNotice() async throws {
        let (workspace, provider, storage, delivery, _, _) = try setup()
        workspace.draft = "cancel"
        workspace.send()
        workspace.stop()
        _ = await workspace.flush()
        storage.fail = true
        workspace.draft = "save must fail"
        workspace.send()
        provider.runs[1].yield(.complete)
        workspace.stop()
        _ = await workspace.flush()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(delivery.values.isEmpty)
    }

    func testFailedProviderNotifiesFailedAfterResultIsDurable() async throws {
        let (workspace, provider, _, delivery, _, _) = try setup()
        workspace.draft = "request"
        workspace.send()
        provider.runs[0].yield(.failed("provider failure"))
        workspace.stop()
        _ = await workspace.flush()
        await wait(delivery, count: 1)
        XCTAssertEqual(delivery.values.first?["outcome"], "failed")
    }
}
