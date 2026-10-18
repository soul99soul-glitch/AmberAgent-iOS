import XCTest
import WebKit
@testable import iosApp

@MainActor
final class IOSWebMountReloadDestinationTests: IOSWebMountToolTestCase {
    func testUserRefreshPreservesCurrentQueryAndFragment() async throws {
        let runtime = IOSWebMountWKRuntime(sessionId: "user-refresh-current-location")
        let webView = try XCTUnwrap(runtime.webView)
        defer { runtime.closeSession() }
        let registry = IOSWebMountRegistry(userDefaults: isolatedDefaults())
        let site = try registry.addCustomSite(
            displayName: "Refresh fixture",
            homepageURL: "https://fixture.example/search",
            needsLogin: false
        )
        registry.setEnabled(id: site.id, enabled: true)
        let controller = IOSWebMountController(
            registry: registry,
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime
        )
        let sessionID = runtime.snapshot.sessionId
        _ = try controller.sessionStore.acquireUserControl(sessionId: sessionID)
        webView.loadHTMLString(
            "<html><head><title>Refresh fixture</title></head><body>Ready</body></html>",
            baseURL: URL(string: site.homepageURL)
        )
        try await waitUntilReady(runtime)
        let rawURL = "https://fixture.example/search?q=PS5#results"
        _ = try await webView.evaluateJavaScript("history.replaceState({}, '', '/search?q=PS5#results'); true")
        XCTAssertEqual(webView.url?.absoluteString, rawURL)
        let displayURL = try XCTUnwrap(runtime.snapshot.currentURL)
        XCTAssertEqual(displayURL, "https://fixture.example/search")

        let requested = expectation(description: "User refresh navigation request")
        let probe = WebMountReloadNavigationProbe { requested.fulfill() }
        webView.navigationDelegate = probe
        defer { webView.navigationDelegate = runtime }
        let refreshed = controller.reloadForUser(sessionId: sessionID)
        XCTAssertEqual(refreshed.status, .loading)
        await fulfillment(of: [requested], timeout: 5)

        XCTAssertEqual(probe.requestedURL?.absoluteString, rawURL)
        XCTAssertEqual(probe.navigationType, .reload)
        XCTAssertEqual(controller.sessionStore.record(sessionId: sessionID)?.controlOwner, .user)
        XCTAssertTrue(runtime.userBrowsingEnabled)
        let publicSnapshot = IOSWebMountController.json(runtime.snapshot.dictionary(redactURLs: true))
        XCTAssertFalse(publicSnapshot.contains("q=PS5"))
        XCTAssertFalse(publicSnapshot.contains("#results"))
        let tabList = await controller.execute(toolName: "wm_tab_list", input: "{}", isUserInitiated: true)
        XCTAssertFalse(tabList.contains("q=PS5"))
        XCTAssertFalse(tabList.contains("#results"))
    }

    func testUserRefreshRejectsAgentControlWithoutDispatchingOrTakingOwnership() async throws {
        let runtime = IOSWebMountWKRuntime(sessionId: "agent-owned-refresh")
        let webView = try XCTUnwrap(runtime.webView)
        defer { runtime.closeSession() }
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime
        )
        webView.loadHTMLString("<html><body>Ready</body></html>", baseURL: URL(string: "https://fixture.example/search"))
        try await waitUntilReady(runtime)
        let sessionID = runtime.snapshot.sessionId
        _ = try controller.sessionStore.acquireAgentControl(
            sessionId: sessionID,
            runId: "active-agent-run",
            conversationId: "active-agent-conversation"
        )
        let requested = expectation(description: "Agent-owned page must not reload")
        requested.isInverted = true
        let probe = WebMountReloadNavigationProbe { requested.fulfill() }
        webView.navigationDelegate = probe
        defer { webView.navigationDelegate = runtime }

        let result = controller.reloadForUser(sessionId: sessionID)
        await fulfillment(of: [requested], timeout: 0.2)

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.error?.contains("接管") == true)
        XCTAssertNil(probe.requestedURL)
        XCTAssertEqual(runtime.snapshot.status, .ready)
        XCTAssertEqual(controller.sessionStore.record(sessionId: sessionID)?.controlOwner, .agent)
        XCTAssertEqual(controller.sessionStore.record(sessionId: sessionID)?.ownerRunId, "active-agent-run")
        XCTAssertFalse(runtime.userBrowsingEnabled)
    }

    func testUserRefreshWithoutAnOpenPageReturnsAnActionableFailure() throws {
        let runtime = IOSWebMountWKRuntime(sessionId: "unopened-refresh")
        defer { runtime.closeSession() }
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime
        )
        let sessionID = runtime.snapshot.sessionId
        _ = try controller.sessionStore.acquireUserControl(sessionId: sessionID)

        let result = controller.reloadForUser(sessionId: sessionID)

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.error?.contains("打开站点") == true)
        XCTAssertNil(result.currentURL)
        XCTAssertEqual(runtime.snapshot.status, .idle)
        XCTAssertEqual(controller.sessionStore.record(sessionId: sessionID)?.controlOwner, .user)
    }

    func testWKReloadPreservesCurrentQueryAndFragmentWhileSnapshotsStayRedacted() async throws {
        let runtime = IOSWebMountWKRuntime(sessionId: "reload-current-location")
        let webView = try XCTUnwrap(runtime.webView)
        defer { runtime.closeSession() }
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime
        )
        let sessionID = runtime.snapshot.sessionId
        _ = try controller.sessionStore.acquireUserControl(sessionId: sessionID)
        webView.loadHTMLString(
            "<html><head><title>Reload fixture</title></head><body>Ready</body></html>",
            baseURL: URL(string: "https://fixture.example/search")
        )
        try await waitUntilReady(runtime)
        let rawURL = "https://fixture.example/search?q=PS5#results"
        _ = try await webView.evaluateJavaScript("history.replaceState({}, '', '/search?q=PS5#results'); true")
        for _ in 0..<100 {
            if webView.url?.absoluteString == rawURL { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(webView.url?.absoluteString, rawURL)
        let stateBeforeReload = try await runtime.state()
        XCTAssertEqual(stateBeforeReload["url"] as? String, "https://fixture.example/search")
        XCTAssertEqual(runtime.snapshot.currentURL, "https://fixture.example/search")

        // The WK request is observed before any network access. This proves
        // the runtime already owns the full destination a refresh must use.
        let requested = expectation(description: "WKWebView reload request")
        let probe = WebMountReloadNavigationProbe { requested.fulfill() }
        webView.navigationDelegate = probe
        defer { webView.navigationDelegate = runtime }
        XCTAssertNotNil(webView.reload())
        await fulfillment(of: [requested], timeout: 5)

        XCTAssertEqual(probe.requestedURL?.absoluteString, rawURL)
        XCTAssertEqual(probe.navigationType, .reload)
        XCTAssertEqual(controller.sessionStore.record(sessionId: sessionID)?.controlOwner, .user)
        XCTAssertTrue(runtime.userBrowsingEnabled)
        let publicSnapshot = IOSWebMountController.json(runtime.snapshot.dictionary(redactURLs: true))
        XCTAssertFalse(publicSnapshot.contains("q=PS5"))
        XCTAssertFalse(publicSnapshot.contains("#results"))
        let tabList = await controller.execute(toolName: "wm_tab_list", input: "{}", isUserInitiated: true)
        XCTAssertFalse(tabList.contains("q=PS5"))
        XCTAssertFalse(tabList.contains("#results"))
    }

    private func waitUntilReady(_ runtime: IOSWebMountWKRuntime) async throws {
        for _ in 0..<100 {
            if runtime.snapshot.status == .ready,
               let state = try? await runtime.state(),
               state["ready_state"] as? String == "complete",
               (state["text_length"] as? Int ?? 0) > 0 {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("WK fixture did not become ready: \(runtime.snapshot)")
        throw NSError(domain: "WebMountReloadFixture", code: 1)
    }
}

@MainActor
private final class WebMountReloadNavigationProbe: NSObject, WKNavigationDelegate {
    private let onRequest: () -> Void
    private(set) var requestedURL: URL?
    private(set) var navigationType: WKNavigationType?

    init(onRequest: @escaping () -> Void) {
        self.onRequest = onRequest
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        requestedURL = navigationAction.request.url
        navigationType = navigationAction.navigationType
        decisionHandler(.cancel)
        onRequest()
    }
}
