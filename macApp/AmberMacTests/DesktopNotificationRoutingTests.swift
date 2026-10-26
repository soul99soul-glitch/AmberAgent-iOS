import XCTest
@testable import AmberMac

@MainActor final class DesktopNotificationRoutingTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        func start(configuration: DesktopProviderConfiguration, apiKey: String,
            messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            throw DesktopRuntimeError.message("Notification routing must not start generation.")
        }
    }

    private final class LoadingStorage: DesktopConversationStorage {
        let values: [DesktopConversation]
        private var started = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var loadGate: CheckedContinuation<Void, Never>?

        init(_ values: [DesktopConversation]) { self.values = values }
        func loadAll() async throws -> [DesktopConversation] { values }
        func listSummaries() async throws -> [DesktopConversationSummary] {
            started = true
            startWaiter?.resume(); startWaiter = nil
            await withCheckedContinuation { loadGate = $0 }
            return DesktopConversationSummary.ordered(values.map(DesktopConversationSummary.init))
        }
        func save(_ conversation: DesktopConversation) async throws -> DesktopConversation { conversation }
        func delete(_ id: UUID) async throws {}
        func waitUntilStarted() async {
            if !started { await withCheckedContinuation { startWaiter = $0 } }
        }
        func release() { loadGate?.resume(); loadGate = nil }
    }

    private func documents() -> [DesktopConversation] {
        [DesktopConversation(title: "Recent", updatedAt: Date(timeIntervalSince1970: 20)),
         DesktopConversation(title: "Original owner", updatedAt: Date(timeIntervalSince1970: 10))]
    }

    private func workspace(_ values: [DesktopConversation], loading: LoadingStorage? = nil) -> DesktopWorkspace {
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.notification-routing.\(UUID())")!,
            credentials: DesktopMemoryCredentials())
        return DesktopWorkspace(settings: settings, storage: loading ?? DesktopMemoryConversationStorage(values),
            provider: Provider(), initialConversations: loading == nil ? values : nil)
    }

    func testTargetReceivedBeforeBindingOpensOriginalConversationOnce() async {
        let values = documents(), workspace = workspace(values), router = DesktopNotificationRouter()
        var opens = 0
        XCTAssertNil(router.receive(conversationID: values[1].id))
        XCTAssertEqual(workspace.selectedID, values[0].id)
        await router.bind(workspace: workspace) { opens += 1 }?.value
        XCTAssertEqual(workspace.selectedID, values[1].id)
        XCTAssertEqual(opens, 1)
        XCTAssertNil(router.bind(workspace: workspace) { opens += 1 })
        XCTAssertEqual(opens, 1)
    }

    func testTargetReceivedAfterBindingOpensOriginalConversation() async {
        let values = documents(), workspace = workspace(values), router = DesktopNotificationRouter()
        var opens = 0
        XCTAssertNil(router.bind(workspace: workspace) { opens += 1 })
        await router.receive(conversationID: values[1].id)?.value
        XCTAssertEqual(workspace.selectedID, values[1].id)
        XCTAssertEqual(opens, 1)
    }

    func testLatestTargetWinsWhileWorkspaceLoads() async {
        let values = documents(), storage = LoadingStorage(values), router = DesktopNotificationRouter()
        let workspace = workspace(values, loading: storage)
        var opens = 0
        router.bind(workspace: workspace) { opens += 1 }
        let previous = router.receive(conversationID: values[0].id)
        await storage.waitUntilStarted()
        let latest = router.receive(conversationID: values[1].id)
        XCTAssertTrue(workspace.isLoading)
        XCTAssertEqual(opens, 0)
        storage.release()
        await previous?.value
        await latest?.value
        XCTAssertFalse(workspace.isLoading)
        XCTAssertEqual(workspace.selectedID, values[1].id)
        XCTAssertEqual(opens, 1)
    }

    func testRebindingCannotLetOldLoadOpenThePreviousWorkspace() async {
        let values = documents(), storage = LoadingStorage(values), router = DesktopNotificationRouter()
        let previousWorkspace = workspace(values, loading: storage), currentWorkspace = workspace(values)
        var previousOpens = 0, currentOpens = 0
        router.bind(workspace: previousWorkspace) { previousOpens += 1 }
        let previous = router.receive(conversationID: values[1].id)
        await storage.waitUntilStarted()
        await router.bind(workspace: currentWorkspace) { currentOpens += 1 }?.value
        XCTAssertEqual(currentWorkspace.selectedID, values[1].id)
        storage.release()
        await previous?.value
        XCTAssertEqual(previousWorkspace.selectedID, values[0].id)
        XCTAssertEqual(previousOpens, 0)
        XCTAssertEqual(currentOpens, 1)
    }

    func testDeletedTargetOpensWindowAndPreservesCurrentConversation() async {
        let values = documents(), workspace = workspace(values), router = DesktopNotificationRouter()
        var opens = 0
        router.bind(workspace: workspace) { opens += 1 }
        await router.receive(conversationID: UUID())?.value
        XCTAssertEqual(workspace.selectedID, values[0].id)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(workspace.errorMessage, "通知对应的会话已删除，任务记录仍可在工作台查看。")
    }

    func testPreviouslyDeliveredTargetStillOpensWithNotificationsDisabled() async {
        let values = documents(), workspace = workspace(values), router = DesktopNotificationRouter()
        XCTAssertFalse(workspace.settings.notificationsEnabled)
        var opens = 0
        router.bind(workspace: workspace) { opens += 1 }
        await router.receive(conversationID: values[1].id)?.value
        XCTAssertEqual(workspace.selectedID, values[1].id)
        XCTAssertEqual(opens, 1)
        XCTAssertFalse(workspace.settings.notificationsEnabled)
    }
}
