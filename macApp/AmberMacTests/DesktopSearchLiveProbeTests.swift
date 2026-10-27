import XCTest
@testable import AmberMac

/// Opt-in: runs the app's real search/scrape tools against the live network.
@MainActor final class DesktopSearchLiveProbeTests: XCTestCase {
    private func live() throws {
        guard ProcessInfo.processInfo.environment["AMBER_MAC_LIVE_MODEL"]?.isEmpty == false else { throw XCTSkip("live network probe") }
    }

    func testScrapeWebFetchesPublicPage() async throws {
        try live()
        let output = try await DesktopSearchRuntime.execute(name: "scrape_web", input: #"{"url":"https://example.com"}"#,
            settings: DesktopSearchSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: DesktopMemoryCredentials()))
        XCTAssertTrue(output.contains("Example Domain"), output)
    }

    func testFreeSearchReturnsResults() async throws {
        try live()
        let output = try await DesktopSearchRuntime.execute(name: "search_web", input: #"{"query":"Swift programming language"}"#,
            settings: DesktopSearchSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: DesktopMemoryCredentials()))
        XCTAssertTrue(output.lowercased().contains("swift"), output)
    }

    func testExecutorHonoursRequestsAboveTen() throws {
        XCTAssertEqual(try IOSSearchExecutor.searchRequest(from: #"{"query":"x","max_results":30}"#).maxResults, 30)
        XCTAssertEqual(try IOSSearchExecutor.searchRequest(from: #"{"query":"x","max_results":500}"#).maxResults, 50)
    }

}
