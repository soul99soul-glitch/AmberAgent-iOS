import XCTest
import WebKit
import SwiftUI
@testable import iosApp

@MainActor
final class IOSWebMountRuntimeEvidenceTests: XCTestCase {
    func testSameURLReloadGetsNewDocumentAndSPAUrlWaitUsesBaseline() async throws {
        let runtime = try await fixture(html: "<button id='noop' type='button'>No-op</button><div id='state'>first</div>")
        let before = try await readyState(runtime)
        let beforeDocument = try XCTUnwrap(before["document_id"] as? String)
        let beforeURL = try XCTUnwrap(before["url"] as? String)

        runtime.webView?.loadHTMLString(
            "<button id='noop' type='button'>No-op</button><div id='state'>second</div>",
            baseURL: URL(string: "https://fixture.example/same")
        )
        let reloaded = try await waitUntil(runtime) { state in
            (state["document_id"] as? String) != beforeDocument
                && (state["text_length"] as? Int ?? 0) > 0
        }
        XCTAssertEqual(reloaded["url"] as? String, beforeURL)
        XCTAssertNotEqual(reloaded["document_id"] as? String, beforeDocument)
        let documentChanged = try await runtime.interact(method: "wait", selector: nil, text: nil, options: [
            "condition": "document_changed",
            "before_document_id": beforeDocument,
            "wait_ms": 1_000
        ])
        XCTAssertEqual(documentChanged["matched"] as? Bool, true)
        XCTAssertEqual(documentChanged["document_changed"] as? Bool, true)

        let spaBaseline = try await readyState(runtime)
        let spaURL = try XCTUnwrap(spaBaseline["url"] as? String)
        let spaURLRevision = try XCTUnwrap(spaBaseline["url_revision"] as? Int)
        _ = try await runtime.webView?.evaluateJavaScript("history.pushState({}, '', '#spa-next'); true")
        let changed = try await runtime.interact(method: "wait", selector: nil, text: nil, options: [
            "condition": "url_changed",
            "before_url": spaURL,
            "before_document_id": try XCTUnwrap(spaBaseline["document_id"] as? String),
            "before_url_revision": spaURLRevision,
            "wait_ms": 1_000
        ])
        XCTAssertEqual(changed["matched"] as? Bool, true, changed.description)
        XCTAssertEqual(changed["url_changed"] as? Bool, true)
        XCTAssertEqual(changed["page_changed"] as? Bool, true)
        XCTAssertEqual(changed["before_url"] as? String, spaURL)
        XCTAssertGreaterThan(changed["url_revision"] as? Int ?? spaURLRevision, spaURLRevision)
        XCTAssertEqual(changed["url"] as? String, spaURL)
    }

    func testNoOpClickDoesNotClaimDomChangeAndNewWindowIsRecorded() async throws {
        let runtime = try await fixture(html: """
            <button id="noop" type="button">No-op</button>
            <a id="new-window" target="_blank" href="https://fixture.example/other">Open</a>
            """)
        let before = try await readyState(runtime)
        let beforeObservation = try await runtime.observe(maxChars: 1_000, maxLinks: 10)
        let target = try XCTUnwrap((beforeObservation["interactive_elements"] as? [[String: Any]])?.first { $0["name"] as? String == "No-op" }?["ref"] as? String)
        let clicked = try await runtime.interact(method: "click", selector: target, text: nil, options: [
            "snapshot_id": beforeObservation["snapshot_id"] as? String ?? ""
        ])
        XCTAssertEqual(clicked["dispatched"] as? Bool, true)
        let afterClick = try await readyState(runtime)
        XCTAssertEqual(afterClick["dom_revision"] as? Int, before["dom_revision"] as? Int)

        let afterClickObservation = try await runtime.observe(maxChars: 1_000, maxLinks: 10)
        let link = try XCTUnwrap((afterClickObservation["interactive_elements"] as? [[String: Any]])?.first { $0["name"] as? String == "Open" }?["ref"] as? String)
        _ = try await runtime.interact(method: "click", selector: link, text: nil, options: [
            "snapshot_id": afterClickObservation["snapshot_id"] as? String ?? ""
        ])
        let event = try await waitUntil(runtime) { state in
            let diagnostics = state["navigation_diagnostics"] as? [String: Any]
            let events = diagnostics?["recent_events"] as? [[String: Any]]
            return events?.contains { $0["kind"] as? String == "new_window_request" && $0["decision"] as? String == "opened" } == true
        }
        let events = try XCTUnwrap((event["navigation_diagnostics"] as? [String: Any])?["recent_events"] as? [[String: Any]])
        XCTAssertTrue(events.contains { $0["kind"] as? String == "new_window_request" })
        XCTAssertEqual(runtime.snapshot.status, .ready)
        XCTAssertEqual(runtime.snapshot.currentURL, afterClick["url"] as? String)
    }

    func testInputObservationReturnsShortSafeValueAndRedactsSensitiveValue() async throws {
        let runtime = try await fixture(html: """
            <label for="query">Query</label><input id="query" value="abcdefghijklmnopqrstuvwxyz">
            <label for="password">Password</label><input id="password" type="password" value="secret-token">
            <input id="long" value="abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz">
            """)
        let observation = try await runtime.observe(maxChars: 2_000, maxLinks: 10)
        let nodes = try XCTUnwrap(observation["interactive_elements"] as? [[String: Any]])
        let query = try XCTUnwrap(nodes.first { $0["name"] as? String == "Query" })
        XCTAssertEqual(query["current_value"] as? String, "abcdefghijklmnopqrstuvwxyz")
        XCTAssertEqual(query["value_redacted"] as? Bool, false)
        XCTAssertEqual(query["truncated"] as? Bool, false)
        let password = try XCTUnwrap(nodes.first { $0["name"] as? String == "Password" })
        XCTAssertEqual(password["current_value"] as? String, "")
        XCTAssertEqual(password["value_redacted"] as? Bool, true)

        let safe = try await runtime.get(selector: "#long", target: nil, kind: "value", attrName: nil, maxChars: 8)
        XCTAssertEqual(safe["truncated"] as? Bool, true)
        XCTAssertEqual(safe["value_redacted"] as? Bool, false)
        XCTAssertEqual(safe["returned_length"] as? Int, 8)
        let denied = try await runtime.get(selector: "#password", target: nil, kind: "value", attrName: nil, maxChars: 100)
        XCTAssertEqual(denied["error_code"] as? String, "sensitive_value_denied")
        XCTAssertEqual(denied["value_redacted"] as? Bool, true)
        XCTAssertNil(denied["value"])
    }

    func testLoginPopupPreservesOpenerAndCookieStoreAndClosesWithoutReplacingParent() async throws {
        let runtime = try await fixture(html: "<p>Parent</p>")
        let parent = try XCTUnwrap(runtime.webView)
        let originalURL = parent.url
        let opened = try await parent.evaluateJavaScript("window.loginPopup = window.open('about:blank'); !!window.loginPopup")
        XCTAssertEqual(opened as? Bool, true)
        let popup = try XCTUnwrap(runtime.popupWebViews.last)
        XCTAssertTrue(popup.configuration.websiteDataStore === parent.configuration.websiteDataStore)
        let hasOpener = try await popup.evaluateJavaScript("!!window.opener")
        XCTAssertEqual(hasOpener as? Bool, true)
        _ = try await popup.evaluateJavaScript("window.opener.document.body.dataset.loginResult = 'done'; true")
        let loginResult = try await parent.evaluateJavaScript("document.body.dataset.loginResult")
        XCTAssertEqual(loginResult as? String, "done")
        _ = try await popup.evaluateJavaScript("window.close(); true")
        _ = try await waitUntil(runtime) { _ in runtime.popupWebViews.isEmpty }
        XCTAssertEqual(parent.url, originalURL)
        XCTAssertEqual(runtime.snapshot.status, .ready)
    }

    func testPopupPrivateRedirectIsDeniedWithoutFailingParent() async throws {
        let runtime = try await fixture(html: "<p>Parent</p>")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let settings = IOSWebMountSettings(userDefaults: defaults)
        runtime.setNavigationPolicy(IOSWebMountURLPolicy(settings: settings, allowUnlistedHosts: true), site: nil)
        let parent = try XCTUnwrap(runtime.webView)
        _ = try await parent.evaluateJavaScript("window.open('about:blank'); true")
        let popup = try XCTUnwrap(runtime.popupWebViews.last)
        popup.load(URLRequest(url: URL(string: "http://127.0.0.1/private")!))
        _ = try await waitUntil(runtime) { _ in runtime.browserNotice != nil }
        XCTAssertFalse(popup.url?.host == "127.0.0.1")
        XCTAssertEqual(runtime.snapshot.status, .ready)
        runtime.closePopup(popup)
    }

    func testJavaScriptDialogsRequireUserResponseAndCancellationUnblocksPage() async throws {
        let runtime = try await fixture(html: "<p>Dialogs</p>")
        runtime.setUserBrowsingEnabled(true)
        runtime.setBrowserPresentationAvailable(true, hostID: UUID())
        let parent = try XCTUnwrap(runtime.webView)
        let confirm = Task { try await parent.evaluateJavaScript("confirm('Continue login?')") as? Bool }
        try await waitForPresentation { runtime.browserDialog?.kind == .confirm }
        XCTAssertEqual(runtime.browserDialog?.host, "fixture.example")
        runtime.resolveBrowserDialog("")
        let confirmed = try await confirm.value
        XCTAssertEqual(confirmed, true)
        let prompt = Task { try await parent.evaluateJavaScript("prompt('Code', 'default')") as? String }
        try await waitForPresentation { runtime.browserDialog?.kind == .prompt }
        runtime.cancelBrowserPresentation()
        let prompted = try await prompt.value
        XCTAssertNil(prompted)
        XCTAssertNil(runtime.browserDialog)
    }

    func testExistingWeiboStationMigratesLoginHostsWithoutRestoringDeletedSites() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var weibo = try XCTUnwrap(IOSWebMountSite.seeds().first { $0.id == "weibo" })
        weibo.enabled = true
        weibo.allowedHosts = ["m.weibo.cn", "custom.example"]
        let key = "app.amber.ios.webmount.sites.v1"
        defaults.set(try JSONEncoder().encode([weibo]), forKey: key)
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        let migrated = try XCTUnwrap(registry.site(id: "weibo"))
        XCTAssertEqual(registry.sites.count, 1)
        XCTAssertTrue(migrated.enabled)
        XCTAssertTrue(migrated.allowedHosts.contains("custom.example"))
        let policy = IOSWebMountURLPolicy(settings: IOSWebMountSettings(userDefaults: defaults))
        for url in ["https://passport.weibo.cn/signin/login", "https://passport.weibo.com/sso/signin", "https://login.sina.com.cn/sso/login.php"] {
            guard case .success = policy.validate(url, site: migrated) else { return XCTFail("Missing login host: \(url)") }
        }
        guard case .failure = policy.validate("https://unrelated.weibo.com/", site: migrated) else {
            return XCTFail("Login compatibility must not allow every subdomain")
        }
        XCTAssertEqual(IOSWebMountRegistry(userDefaults: defaults).sites, registry.sites)
        defaults.set(try JSONEncoder().encode([IOSWebMountSite]()), forKey: key)
        XCTAssertTrue(IOSWebMountRegistry(userDefaults: defaults).sites.isEmpty)
    }

    func testUserBrowsingAllowsUnknownPublicLoginHostsButDoesNotChangeAgentPolicy() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = IOSWebMountURLPolicy(settings: IOSWebMountSettings(userDefaults: defaults))
        let login = "https://accounts.new-provider.example/oauth/authorize"
        guard case .failure = policy.validate(login) else { return XCTFail("Agent policy unexpectedly expanded") }
        let humanPolicy = policy.allowingPublicUserNavigation()
        let publicResult = await humanPolicy.validateResolvedPublicHost(login, resolveHost: { _ in ["93.184.216.34"] })
        guard case .success = publicResult else { return XCTFail("Human login redirect should be allowed") }
        let privateResult = await humanPolicy.validateResolvedPublicHost(login, resolveHost: { _ in ["10.0.0.8"] })
        guard case .failure = privateResult else { return XCTFail("Human login must still reject private destinations") }
        guard case .failure = humanPolicy.validate("javascript:alert(1)") else { return XCTFail("Unsafe protocol allowed") }
        guard case .failure = policy.validate(login) else { return XCTFail("Human policy mutated Agent permissions") }
    }

    func testControlHandoffRevokesPublicBrowsingAndClosesLoginWindows() async throws {
        let runtime = try await fixture(html: "<p>Ownership</p>")
        let store = IOSWebMountSessionStore(initialRuntime: runtime)
        let sessionID = runtime.snapshot.sessionId
        _ = try store.acquireAgentControl(sessionId: sessionID, runId: "run", conversationId: "chat")
        XCTAssertFalse(runtime.userBrowsingEnabled)
        _ = try store.acquireUserControl(sessionId: sessionID)
        XCTAssertTrue(runtime.userBrowsingEnabled)
        XCTAssertThrowsError(try store.acquireAgentControl(sessionId: sessionID, runId: "run", conversationId: "chat"))
        _ = try await runtime.webView?.evaluateJavaScript("window.open('about:blank'); true")
        XCTAssertEqual(runtime.popupWebViews.count, 1)
        _ = try store.handBackToAgent(sessionId: sessionID)
        XCTAssertFalse(runtime.userBrowsingEnabled)
        XCTAssertTrue(runtime.popupWebViews.isEmpty)
        _ = try store.acquireUserControl(sessionId: sessionID)
        store.releaseAgentOwnership(runId: "run")
        XCTAssertTrue(runtime.userBrowsingEnabled, "Finishing the Agent run must not steal human control")
        _ = try store.handBackToAgent(sessionId: sessionID)
        XCTAssertFalse(runtime.userBrowsingEnabled, "Releasing human control without an Agent run also revokes it")
    }

    func testEmbeddedLocalLoginDocumentIsNotTreatedAsAnUnlistedNetworkHost() async throws {
        let runtime = try await fixture(html: "<p>Parent</p>")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        runtime.setNavigationPolicy(IOSWebMountURLPolicy(settings: IOSWebMountSettings(userDefaults: defaults),
                                                       extraAllowedHosts: ["fixture.example"]), site: nil)
        _ = try await runtime.webView?.evaluateJavaScript("""
            const frame = document.createElement('iframe');
            frame.id = 'login-frame';
            frame.srcdoc = '<button id="login">Login</button>';
            document.body.appendChild(frame); true;
            """)
        var loaded = false
        for _ in 0..<50 {
            loaded = (try? await runtime.webView?.evaluateJavaScript(
                "!!document.getElementById('login-frame').contentDocument?.getElementById('login')")) as? Bool ?? false
            if loaded { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(loaded)
        let state = try await runtime.state()
        XCTAssertEqual((state["navigation_diagnostics"] as? [String: Any])?["subframe_navigation_denied_count"] as? Int, 0)
    }

    func testAgentDialogReturnsWithoutHangingAndRequestsHumanControl() async throws {
        let runtime = try await fixture(html: "<p>Agent</p>")
        let response = try await runtime.webView?.evaluateJavaScript("confirm('Login?')") as? Bool
        XCTAssertEqual(response, false)
        XCTAssertNil(runtime.browserDialog)
        XCTAssertNotNil(runtime.browserNotice)
        let state = try await runtime.state()
        let events = (state["navigation_diagnostics"] as? [String: Any])?["recent_events"] as? [[String: Any]]
        XCTAssertTrue(events?.contains { $0["error_code"] as? String == "user_control_required" } == true)
    }

    func testClosingUnrelatedPopupDoesNotAnswerParentDialog() async throws {
        let runtime = try await fixture(html: "<p>Parent dialog</p>")
        runtime.setUserBrowsingEnabled(true)
        runtime.setBrowserPresentationAvailable(true, hostID: UUID())
        let parent = try XCTUnwrap(runtime.webView)
        _ = try await parent.evaluateJavaScript("window.open('about:blank'); true")
        let popup = try XCTUnwrap(runtime.popupWebViews.last)
        let response = Task { try await parent.evaluateJavaScript("confirm('Continue?')") as? Bool }
        try await waitForPresentation { runtime.browserDialog != nil }
        runtime.closePopup(popup)
        XCTAssertNotNil(runtime.browserDialog)
        runtime.resolveBrowserDialog("")
        let confirmed = try await response.value
        XCTAssertEqual(confirmed, true)
    }

    func testStaleDialogResponseCannotAnswerTheNextDialog() async throws {
        let runtime = try await fixture(html: "<p>Dialog identity</p>")
        runtime.setUserBrowsingEnabled(true)
        runtime.setBrowserPresentationAvailable(true, hostID: UUID())
        let webView = try XCTUnwrap(runtime.webView)
        let first = Task { try await webView.evaluateJavaScript("confirm('First?')") as? Bool }
        try await waitForPresentation { runtime.browserDialog != nil }
        let firstID = try XCTUnwrap(runtime.browserDialog?.id)
        runtime.resolveBrowserDialog(nil, dialogID: firstID)
        let firstValue = try await first.value
        XCTAssertEqual(firstValue, false)
        let second = Task { try await webView.evaluateJavaScript("confirm('Second?')") as? Bool }
        try await waitForPresentation { runtime.browserDialog != nil }
        let secondID = try XCTUnwrap(runtime.browserDialog?.id)
        runtime.resolveBrowserDialog("", dialogID: firstID)
        XCTAssertEqual(runtime.browserDialog?.id, secondID)
        runtime.resolveBrowserDialog("", dialogID: secondID)
        let secondValue = try await second.value
        XCTAssertEqual(secondValue, true)
    }

    func testLeavingLastVisibleHostCancelsDialogAndFuturePromptsDoNotHang() async throws {
        let runtime = try await fixture(html: "<p>Visible hosts</p>")
        runtime.setUserBrowsingEnabled(true)
        let parentHost = UUID(), sheetHost = UUID()
        runtime.setBrowserPresentationAvailable(true, hostID: parentHost)
        runtime.setBrowserPresentationAvailable(true, hostID: sheetHost)
        let webView = try XCTUnwrap(runtime.webView)
        let response = Task { try await webView.evaluateJavaScript("confirm('Visible?')") as? Bool }
        try await waitForPresentation { runtime.browserDialog != nil }
        runtime.setBrowserPresentationAvailable(false, hostID: parentHost)
        XCTAssertNotNil(runtime.browserDialog, "A visible sheet can still answer the dialog")
        runtime.setBrowserPresentationAvailable(false, hostID: sheetHost)
        let cancelled = try await response.value
        XCTAssertEqual(cancelled, false)
        let offscreen = try await webView.evaluateJavaScript("confirm('Offscreen?')") as? Bool
        XCTAssertEqual(offscreen, false)
        XCTAssertNil(runtime.browserDialog)
        XCTAssertTrue(runtime.userBrowsingEnabled, "Leaving the view must not grant control back to the Agent")
    }

    func testPopupTerminationCancelsOnlyItsDialogAndSessionCloseRevokesRuntime() async throws {
        let runtime = try await fixture(html: "<p>Termination</p>")
        let store = IOSWebMountSessionStore(initialRuntime: runtime)
        _ = try store.acquireUserControl(sessionId: runtime.snapshot.sessionId)
        runtime.setBrowserPresentationAvailable(true, hostID: UUID())
        _ = try await runtime.webView?.evaluateJavaScript("window.open('about:blank'); true")
        let popup = try XCTUnwrap(runtime.popupWebViews.last)
        let response = Task { try await popup.evaluateJavaScript("confirm('Continue?')") as? Bool }
        try await waitForPresentation { runtime.browserDialog != nil }
        runtime.webViewWebContentProcessDidTerminate(popup)
        let cancelled = try await response.value
        XCTAssertEqual(cancelled, false)
        XCTAssertNil(runtime.browserDialog)
        XCTAssertTrue(runtime.popupWebViews.isEmpty)
        _ = try store.close(sessionId: runtime.snapshot.sessionId)
        XCTAssertFalse(runtime.userBrowsingEnabled)
        let state = try await runtime.state()
        XCTAssertEqual(state["ok"] as? Bool, false)
        XCTAssertEqual(state["error_code"] as? String, "session_closed")
    }

    func testControllerReadToolsPreservePendingDialogFailure() async throws {
        let runtime = try await fixture(html: "<p>Dialog read</p>")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        let site = try registry.addCustomSite(displayName: "Fixture", homepageURL: "https://fixture.example/")
        registry.setEnabled(id: site.id, enabled: true)
        let controller = IOSWebMountController(registry: registry,
            settings: IOSWebMountSettings(userDefaults: defaults), runtime: runtime)
        controller.sessionStore.tag(sessionId: runtime.snapshot.sessionId, site: site)
        _ = try controller.sessionStore.acquireUserControl(sessionId: runtime.snapshot.sessionId)
        runtime.setBrowserPresentationAvailable(true, hostID: UUID())
        let response = Task { try await runtime.webView?.evaluateJavaScript("confirm('Read blocked?')") as? Bool }
        try await waitForPresentation { runtime.browserDialog != nil }
        for tool in ["wm_state", "wm_observe", "wm_extract", "wm_visual_snapshot"] {
            let output = await controller.execute(toolName: tool,
                input: IOSWebMountController.json(["session_id": runtime.snapshot.sessionId]), isUserInitiated: true)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            XCTAssertEqual(object["ok"] as? Bool, false, tool)
            XCTAssertEqual(object["error_code"] as? String, "user_dialog_pending", tool)
        }
        runtime.resolveBrowserDialog(nil)
        _ = try await response.value
    }

    func testNativeSnapshotTracksSPARouteWithoutFullNavigation() async throws {
        let runtime = try await fixture(html: "<p>SPA navigation</p>")
        let webView = try XCTUnwrap(runtime.webView)
        try await waitForPresentation { runtime.snapshot.status == .ready }
        _ = try await webView.evaluateJavaScript("history.pushState({}, '', '/next-page'); true")
        for _ in 0..<100 {
            if runtime.snapshot.currentURL?.hasSuffix("/next-page") == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(runtime.snapshot.currentURL?.hasSuffix("/next-page") == true,
            "snapshot=\(String(describing: runtime.snapshot.currentURL)), WebKit=\(String(describing: webView.url)), status=\(runtime.snapshot.status)")
        // loadHTMLString does not always create a back-list item on iOS 27.
        // Native controls must reflect WebKit rather than assume a history entry.
        XCTAssertEqual(runtime.snapshot.canGoBack, webView.canGoBack)
        // HTML fixtures have no reliable pre-existing back-list entry. Cover
        // both History API updates without depending on browser history setup.
        _ = try await webView.evaluateJavaScript("history.replaceState({}, '', '/replaced-page'); true")
        for _ in 0..<100 {
            if runtime.snapshot.currentURL?.hasSuffix("/replaced-page") == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(runtime.snapshot.currentURL?.hasSuffix("/replaced-page") == true,
            "snapshot=\(String(describing: runtime.snapshot.currentURL)), WebKit=\(String(describing: webView.url)), status=\(runtime.snapshot.status)")
        XCTAssertEqual(runtime.snapshot.canGoBack, webView.canGoBack)
        XCTAssertEqual(runtime.snapshot.canGoForward, webView.canGoForward)
    }

    func testDialogLayoutEvidenceForCompactViewportAndLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        for (name, size, typeSize) in [
            ("compact-dialog", CGSize(width: 320, height: 360), DynamicTypeSize.large),
            ("large-text-dialog", CGSize(width: 320, height: 568), DynamicTypeSize.accessibility3)
        ] {
            let dialog = IOSWebMountBrowserDialog(kind: .confirm,
                message: String(repeating: "请确认是否继续登录。该操作会返回原网页。", count: 20),
                host: "authentication.long-domain.example", defaultText: "")
            let host = UIHostingController(rootView: WebMountBrowserDialogOverlay(dialog: dialog) { _ in }
                .environment(\.dynamicTypeSize, typeSize))
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            try await Task.sleep(nanoseconds: 350_000_000)
            host.view.layoutIfNeeded()
            let fitted = host.sizeThatFits(in: size)
            XCTAssertLessThanOrEqual(fitted.width, size.width + 1)
            XCTAssertLessThanOrEqual(fitted.height, size.height + 1)
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func waitForPresentation(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Browser presentation did not arrive")
        throw NSError(domain: "IOSWebMountRuntimeEvidenceTests", code: 2)
    }

    private func fixture(html: String) async throws -> IOSWebMountWKRuntime {
        let runtime = IOSWebMountWKRuntime(sessionId: UUID().uuidString)
        let webView = try XCTUnwrap(runtime.webView)
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.example/same"))
        _ = try await waitUntil(runtime) { state in
            state["ready_state"] as? String == "complete" && (state["text_length"] as? Int ?? 0) > 0
        }
        return runtime
    }

    private func readyState(_ runtime: IOSWebMountWKRuntime) async throws -> [String: Any] {
        try await waitUntil(runtime) { $0["ready_state"] as? String == "complete" }
    }

    private func waitUntil(
        _ runtime: IOSWebMountWKRuntime,
        condition: ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        for _ in 0..<100 {
            if let state = try? await runtime.state(), condition(state) { return state }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("WKWebView fixture did not reach the expected state")
        throw NSError(domain: "IOSWebMountRuntimeEvidenceTests", code: 1)
    }
}
