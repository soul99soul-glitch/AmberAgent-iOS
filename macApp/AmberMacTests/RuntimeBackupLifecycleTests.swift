import XCTest
@testable import AmberMac

@MainActor final class RuntimeBackupLifecycleTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration { DesktopGeneration() }
    }
    private final class Storage: DesktopConversationStorage {
        var values: [DesktopConversation]
        var gate: CheckedContinuation<Void, Never>?
        init(_ values: [DesktopConversation]) { self.values = values }
        func loadAll() async throws -> [DesktopConversation] { values }
        func listSummaries() async throws -> [DesktopConversationSummary] {
            await withCheckedContinuation { gate = $0 }
            return values.map(DesktopConversationSummary.init)
        }
        func save(_ value: DesktopConversation) async throws -> DesktopConversation { value }
        func delete(_ id: UUID) async throws {}
    }
    func testQuitCancellationReachesAcceptedSnapshotBeforeRemoteUpload() async throws {
        let conversation = DesktopConversation(title: "owner")
        let storage = Storage([conversation])
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.backup-lifecycle.\(UUID().uuidString)")!, credentials: DesktopMemoryCredentials())
        let workspace = DesktopWorkspace(settings: settings, storage: storage, provider: Provider(), initialConversations: [conversation])
        var uploaded = false
        let operation = Task {
            _ = try await workspace.makeBackupData(password: "password")
            uploaded = true
        }
        while storage.gate == nil { await Task.yield() }
        workspace.cancelBackup()
        storage.gate?.resume()
        await workspace.waitUntilBackupFinished()
        do { _ = try await operation.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(uploaded)
        XCTAssertFalse(workspace.isManagingBackup)
    }
}
