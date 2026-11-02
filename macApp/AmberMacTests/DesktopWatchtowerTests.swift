import XCTest
@testable import AmberMac

/// M3.3: watchtower keeps a snapshot, reports only real changes, and never opens a socket.
@MainActor final class DesktopWatchtowerTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watchtower-\(UUID().uuidString)", isDirectory: true)
        suiteName = "amber.watchtower.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        if let suiteName { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func store() -> DesktopPluginStore {
        DesktopPluginStore(directory: directory, defaults: UserDefaults(suiteName: suiteName)!,
            credentials: DesktopMemoryCredentials(), calendarService: FakeCalendarService())
    }

    private func snapshot(_ store: DesktopPluginStore, url: String, content: String) async throws -> [String: Any] {
        let output = try await store.executeTool(qualifiedName: "plugin__watchtower__snapshot",
            argumentsJSON: try DesktopAppleScheduleTools.json(["url": url, "content": content]))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    func testFirstCallEstablishesBaselineAndRepeatIsQuiet() async throws {
        let store = store()
        XCTAssertTrue(store.plugins.contains { $0.id == "watchtower" && $0.isBuiltIn })

        let first = try await snapshot(store, url: "https://news.example.com/feed", content: "标题一\n正文一")
        XCTAssertEqual(first["ok"] as? Bool, true)
        XCTAssertEqual(first["changed"] as? Bool, true)
        XCTAssertEqual(first["first_seen"] as? Bool, true)
        XCTAssertEqual(first["quiet"] as? Bool, false)

        // Same page again: no change, and the run must be able to stay silent.
        let repeatCall = try await snapshot(store, url: "https://news.example.com/feed", content: "标题一\n正文一")
        XCTAssertEqual(repeatCall["changed"] as? Bool, false)
        XCTAssertEqual(repeatCall["quiet"] as? Bool, true)
        XCTAssertEqual(repeatCall["first_seen"] as? Bool, false)
    }

    func testChangedPageReportsOnlyTheNewAndDroppedLines() async throws {
        let store = store()
        _ = try await snapshot(store, url: "https://news.example.com/feed", content: "旧标题\n保持不变的行")
        let changed = try await snapshot(store, url: "https://news.example.com/feed", content: "新标题\n保持不变的行")
        XCTAssertEqual(changed["changed"] as? Bool, true)
        XCTAssertEqual(changed["added"] as? [String], ["新标题"])
        XCTAssertEqual(changed["removed"] as? [String], ["旧标题"])
        XCTAssertEqual(changed["snapshots"] as? Int, 2)
    }

    /// Whitespace and blank lines are not news: a re-rendered page must not wake the user.
    func testWhitespaceOnlyChangesStayQuiet() async throws {
        let store = store()
        _ = try await snapshot(store, url: "https://example.com/a", content: "第一行\n第二行")
        let noisy = try await snapshot(store, url: "https://example.com/a", content: "  第一行  \n\n\n第二行\n")
        XCTAssertEqual(noisy["changed"] as? Bool, false)
    }

    func testStatusListsWatchedPagesAndRefreshesLastCheckedOnUnchangedPage() async throws {
        final class ClockBox: @unchecked Sendable {
            var now = Date(timeIntervalSince1970: 1_793_404_800) // 2026-10-31
        }
        let clock = ClockBox()
        let store = DesktopPluginStore(directory: directory, defaults: UserDefaults(suiteName: suiteName)!,
            credentials: DesktopMemoryCredentials(), calendarService: FakeCalendarService(),
            referenceDateProvider: { clock.now })
        _ = try await snapshot(store, url: "https://example.com/a", content: "a")
        _ = try await snapshot(store, url: "https://example.com/b", content: "b")

        // Advance to next day and re-check page a with identical content: last_checked must refresh.
        clock.now = clock.now.addingTimeInterval(86_400)
        let unchanged = try await snapshot(store, url: "https://example.com/a", content: "a")
        XCTAssertEqual(unchanged["changed"] as? Bool, false)
        let expectedToday = try XCTUnwrap(unchanged["checked_on"] as? String)

        let output = try await store.executeTool(qualifiedName: "plugin__watchtower__status", argumentsJSON: "{}")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["count"] as? Int, 2)
        let pages = try XCTUnwrap(object["pages"] as? [[String: Any]])
        XCTAssertEqual(Set(pages.compactMap { $0["url"] as? String }),
            ["https://example.com/a", "https://example.com/b"])
        let pageA = try XCTUnwrap(pages.first { ($0["url"] as? String) == "https://example.com/a" })
        XCTAssertEqual(pageA["last_checked"] as? String, expectedToday)
    }

    func testEmptyContentIsRejectedInsteadOfWipingTheBaseline() async throws {
        let store = store()
        _ = try await snapshot(store, url: "https://example.com/a", content: "真实内容")
        // A tool reports a refusal as ok=false (the convention Recipe and the transcript already read).
        let rejected = try await snapshot(store, url: "https://example.com/a", content: "   ")
        XCTAssertEqual(rejected["ok"] as? Bool, false)
        XCTAssertTrue((rejected["error"] as? String)?.contains("正文为空") == true)
        // The stored baseline is untouched, so the next real read still says "no change".
        let after = try await snapshot(store, url: "https://example.com/a", content: "真实内容")
        XCTAssertEqual(after["changed"] as? Bool, false)
    }

    /// The sandbox cannot reach the network, and the settings page has to say so rather than implying it can.
    func testPluginClaimsNoNetworkCapability() throws {
        let store = store()
        let plugin = try XCTUnwrap(store.plugins.first { $0.id == "watchtower" })
        XCTAssertTrue(plugin.manifest.capabilities.networkDomains.isEmpty)
        let rows = DesktopPluginSettingsPresentation.capabilityRows(for: plugin)
        XCTAssertEqual(rows.first { $0.id == "network" }?.state, .declaredNotWired)
        XCTAssertTrue(rows.first { $0.id == "network" }?.detail.contains("未声明域名") == true)
        // snapshot/status only compute and read its own storage: no approval card, no risk gate.
        XCTAssertFalse(DesktopToolRegistry.isHighRisk("plugin__watchtower__snapshot"))
        XCTAssertFalse(DesktopToolRegistry.isHighRisk("plugin__watchtower__status"))
    }

    func testRunWithNoChangeIsMarkedNotNoteworthy() {
        let quiet = DesktopToolCall(id: "1", name: "plugin__watchtower__snapshot", input: "{}",
            output: #"{"ok":true,"changed":false,"quiet":true}"#, status: .complete)
        XCTAssertEqual(DesktopWatchtower.quietVerdict(tools: [quiet]), true)

        let changed = DesktopToolCall(id: "2", name: "plugin__watchtower__snapshot", input: "{}",
            output: #"{"ok":true,"changed":true,"quiet":false}"#, status: .complete)
        XCTAssertEqual(DesktopWatchtower.quietVerdict(tools: [changed]), false)
        // Multiple snapshot calls: if any call saw a change, the run must not be silenced even if the last call was quiet.
        XCTAssertEqual(DesktopWatchtower.quietVerdict(tools: [changed, quiet]), false)
        XCTAssertEqual(DesktopWatchtower.quietVerdict(tools: [quiet, quiet]), true)

        // A failed snapshot (ok=false or status != .complete) must not silence the run.
        let refused = DesktopToolCall(id: "2b", name: "plugin__watchtower__snapshot", input: "{}",
            output: #"{"ok":false,"error":"正文为空"}"#, status: .complete)
        XCTAssertNil(DesktopWatchtower.quietVerdict(tools: [refused, quiet]))

        // No watchtower call at all: the run keeps its ordinary notification behaviour.
        XCTAssertNil(DesktopWatchtower.quietVerdict(tools: []))
        XCTAssertNil(DesktopWatchtower.quietVerdict(tools: [
            DesktopToolCall(id: "3", name: "search_web", input: "{}", output: "{}", status: .complete)]))
        // An unparsable payload must not silence a run.
        XCTAssertNil(DesktopWatchtower.quietVerdict(tools: [
            DesktopToolCall(id: "4", name: "plugin__watchtower__snapshot", input: "{}",
                output: "not json", status: .complete)]))
    }
}
