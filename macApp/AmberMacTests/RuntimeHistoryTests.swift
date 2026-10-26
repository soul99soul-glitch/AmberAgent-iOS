import XCTest
@testable import AmberMac

@MainActor final class RuntimeHistoryTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        var requestCount = 0
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            requestCount += 1
            return DesktopGeneration()
        }
    }
    private final class Storage: DesktopConversationStorage {
        var values: [DesktopConversation]
        var loadAllCount = 0
        var reads: [UUID] = []
        var searchQueries: [String] = []
        var heldQueries: Set<String> = []
        var searchGates: [String: CheckedContinuation<Void, Never>] = [:]
        var heldIDs: Set<UUID> = []
        var readGates: [UUID: CheckedContinuation<Void, Never>] = [:]
        var failRead = false
        var failMetadata = false
        var failDelete = false
        init(_ values: [DesktopConversation]) { self.values = values }
        func loadAll() async throws -> [DesktopConversation] { loadAllCount += 1; return values }
        func listSummaries() async throws -> [DesktopConversationSummary] {
            DesktopConversationSummary.ordered(values.map { value in
                var summary = DesktopConversationSummary(value); summary.preview = nil; return summary
            })
        }
        func load(_ id: UUID) async throws -> DesktopConversation? {
            reads.append(id)
            let captured = values.first { $0.id == id }
            if heldIDs.contains(id) { await withCheckedContinuation { readGates[id] = $0 } }
            if failRead { throw DesktopRuntimeError.message("read failure") }
            return captured
        }
        func search(_ query: String) async throws -> [DesktopConversationSearchResult] {
            searchQueries.append(query)
            let captured = DesktopConversationPresentation.search(values, query: query)
            if heldQueries.contains(query) { await withCheckedContinuation { searchGates[query] = $0 } }
            return captured
        }
        func save(_ value: DesktopConversation) async throws -> DesktopConversation {
            values.removeAll { $0.id == value.id }; values.append(value); return value
        }
        func updateMetadata(_ id: UUID, title: String?, isPinned: Bool?) async throws {
            if failMetadata { throw DesktopRuntimeError.message("metadata failure") }
            guard let index = values.firstIndex(where: { $0.id == id }) else { return }
            if let title { values[index].title = title }; if let isPinned { values[index].isPinned = isPinned }
        }
        func delete(_ id: UUID) async throws {
            if failDelete { throw DesktopRuntimeError.message("delete failure") }
            values.removeAll { $0.id == id }
        }
    }
    private func setup(_ values: [DesktopConversation]) -> (DesktopWorkspace, Storage, Provider) {
        let defaults = UserDefaults(suiteName: "amber.history.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        let storage = Storage(values)
        let provider = Provider()
        return (DesktopWorkspace(settings: settings, storage: storage, provider: provider), storage, provider)
    }
    private func documents() -> [DesktopConversation] {
        [DesktopConversation(title: "Recent", updatedAt: Date(timeIntervalSince1970: 20),
            messages: [DesktopMessage(role: .user, text: "recent body")]),
         DesktopConversation(title: "Archive", updatedAt: Date(timeIntervalSince1970: 10),
            messages: [DesktopMessage(role: .user, text: "hidden lighthouse body")])]
    }

    func testStartupReadsSummaryAndOnlySelectedDocument() async {
        let values = documents()
        let (workspace, storage, _) = setup(values)
        await workspace.waitUntilLoaded()
        XCTAssertEqual(storage.loadAllCount, 0)
        XCTAssertEqual(storage.reads, [values[0].id])
        XCTAssertEqual(workspace.summaries.count, 2)
        XCTAssertEqual(workspace.conversations.map(\.id), [values[0].id])
        XCTAssertEqual(workspace.sidebarResults.last?.snippet, "点击读取完整对话")
        workspace.select(values[1].id)
        await workspace.waitUntilSelectedConversationLoaded()
        XCTAssertEqual(workspace.selectedConversation?.messages.first?.text, "hidden lighthouse body")
        XCTAssertEqual(storage.reads, values.map(\.id))
    }

    func testSearchFindsUnloadedBodyAndLiveCacheOverridesStoredTitle() async {
        let values = documents()
        let (workspace, storage, _) = setup(values)
        await workspace.waitUntilLoaded()
        workspace.searchText = "lighthouse"
        await workspace.waitUntilSearchComplete()
        XCTAssertEqual(storage.searchQueries, ["lighthouse"])
        XCTAssertEqual(workspace.sidebarResults.first?.conversationID, values[1].id)
        XCTAssertEqual(workspace.sidebarResults.first?.messageID, values[1].messages[0].id)
        XCTAssertEqual(storage.reads.count, 1)
        workspace.rename(values[0].id, title: "lighthouse current title")
        XCTAssertEqual(workspace.sidebarResults.first?.conversationID, values[0].id)
        XCTAssertEqual(workspace.sidebarResults.first?.kind, .title)
        _ = await workspace.flush()
    }

    func testLateSearchCannotReplaceCurrentQueryOrClearedResults() async {
        let values = documents()
        let (workspace, storage, _) = setup(values)
        await workspace.waitUntilLoaded()
        storage.heldQueries.insert("lighthouse")
        workspace.searchText = "lighthouse"
        while storage.searchGates["lighthouse"] == nil { await Task.yield() }
        workspace.searchText = "recent"
        await workspace.waitUntilSearchComplete()
        XCTAssertEqual(workspace.sidebarResults.map(\.conversationID), [values[0].id])
        storage.searchGates.removeValue(forKey: "lighthouse")?.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(workspace.sidebarResults.map(\.conversationID), [values[0].id])
        workspace.searchText = ""
        XCTAssertFalse(workspace.isSearching)
        XCTAssertEqual(workspace.sidebarResults.count, 2)
    }

    func testPendingReadCannotSendOrResurrectDeletedConversation() async {
        let values = documents()
        let (workspace, storage, provider) = setup(values)
        await workspace.waitUntilLoaded()
        storage.heldIDs.insert(values[1].id)
        workspace.select(values[1].id)
        while storage.readGates[values[1].id] == nil { await Task.yield() }
        XCTAssertTrue(workspace.isLoadingSelectedConversation)
        XCTAssertTrue(workspace.selectedConversationUnavailable)
        XCTAssertNil(workspace.selectedConversation)
        workspace.draft = "must stay draft"
        workspace.send()
        XCTAssertEqual(provider.requestCount, 0)
        workspace.delete(values[1].id)
        _ = await workspace.flush()
        storage.readGates.removeValue(forKey: values[1].id)?.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(workspace.summaries.contains { $0.id == values[1].id })
        XCTAssertFalse(workspace.conversations.contains { $0.id == values[1].id })
        XCTAssertEqual(workspace.selectedID, values[0].id)
    }

    func testUnloadedMetadataFailureRetriesWithoutLoadingBody() async {
        let values = documents()
        let (workspace, storage, _) = setup(values)
        await workspace.waitUntilLoaded()
        storage.failMetadata = true
        workspace.rename(values[1].id, title: "Manual archive")
        workspace.togglePin(values[1].id)
        let firstFlush = await workspace.flush()
        XCTAssertFalse(firstFlush)
        XCTAssertEqual(storage.reads, [values[0].id])
        storage.failMetadata = false
        let secondFlush = await workspace.flush()
        XCTAssertTrue(secondFlush)
        XCTAssertEqual(storage.values.first { $0.id == values[1].id }?.title, "Manual archive")
        XCTAssertEqual(storage.values.first { $0.id == values[1].id }?.isPinned, true)
        workspace.select(values[1].id)
        await workspace.waitUntilSelectedConversationLoaded()
        XCTAssertEqual(workspace.selectedConversation?.title, "Manual archive")
        XCTAssertEqual(workspace.selectedConversation?.isPinned, true)
    }

    func testFailedReadRetainsSummaryAndCanReload() async {
        let values = documents()
        let (workspace, storage, _) = setup(values)
        await workspace.waitUntilLoaded()
        storage.failRead = true
        workspace.select(values[1].id)
        await workspace.waitUntilSelectedConversationLoaded()
        XCTAssertTrue(workspace.selectedConversationUnavailable)
        XCTAssertFalse(workspace.isLoadingSelectedConversation)
        XCTAssertNotNil(workspace.errorMessage)
        XCTAssertEqual(workspace.selectedConversationTitle, "Archive")
        storage.failRead = false
        workspace.reloadSelectedConversation()
        await workspace.waitUntilSelectedConversationLoaded()
        XCTAssertEqual(workspace.selectedConversation?.id, values[1].id)
        XCTAssertNil(workspace.errorMessage)
    }

    func testInterruptedStreamingIsRecoveredOnlyWhenDocumentOpens() async {
        var values = documents()
        values[1].messages.append(DesktopMessage(role: .assistant, text: "partial", state: .streaming))
        let (workspace, storage, _) = setup(values)
        await workspace.waitUntilLoaded()
        XCTAssertEqual(storage.values[1].messages.last?.state, .streaming)
        workspace.select(values[1].id)
        await workspace.waitUntilSelectedConversationLoaded()
        _ = await workspace.flush()
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.state, .cancelled)
        XCTAssertEqual(storage.values.first { $0.id == values[1].id }?.messages.last?.state, .cancelled)
    }
}
