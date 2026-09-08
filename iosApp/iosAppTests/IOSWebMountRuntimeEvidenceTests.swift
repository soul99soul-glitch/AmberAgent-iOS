import XCTest
import WebKit
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
            return events?.contains { $0["kind"] as? String == "new_window_request" && $0["error_code"] as? String == "new_window_unsupported" } == true
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
