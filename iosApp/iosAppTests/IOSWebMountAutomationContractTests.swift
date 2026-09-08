import XCTest
import WebKit
@testable import iosApp

@MainActor
final class IOSWebMountAutomationContractTests: XCTestCase {
    private let context = IOSWebMountExecutionContext(runId: "fixture-run", conversationId: "fixture-chat")

    func testTargetAliasesConflictAndSnapshotSessionBinding() async throws {
        let (controller, runtime) = try await fixture()
        for alias in [nil, "", "same"] as [String?] {
            let observation = try await observe(controller, runtime)
            let ref = try target("Next", in: observation)
            var args = bound(runtime, observation, ref)
            if let alias { args["selector"] = alias == "same" ? ref : alias }
            let result = try await call(controller, "wm_click", args)
            XCTAssertEqual(result["dispatched"] as? Bool, true, IOSWebMountController.json(result))
        }
        var observation = try await observe(controller, runtime)
        let ref = try target("Next", in: observation)
        var conflict = bound(runtime, observation, ref)
        conflict["selector"] = try target("Other", in: observation)
        let rejected = try await call(controller, "wm_click", conflict)
        XCTAssertEqual(rejected["error_code"] as? String, "conflicting_target_arguments")
        XCTAssertEqual(rejected["dispatched"] as? Bool, false)
        let clicks = try await runtime.webView!.evaluateJavaScript("window.clicks") as? Int
        XCTAssertEqual(clicks, 3)

        let old = bound(runtime, observation, ref)
        _ = try await runtime.webView!.evaluateJavaScript("document.getElementById('result').textContent='changed'")
        let stale = try await call(controller, "wm_click", old)
        XCTAssertEqual(stale["error_code"] as? String, "stale_snapshot")
        XCTAssertEqual(stale["dispatched"] as? Bool, false)

        let (otherController, otherRuntime) = try await fixture()
        let otherObservation = try await observe(otherController, otherRuntime)
        let crossSession = try await call(otherController, "wm_click", bound(otherRuntime, otherObservation, ref))
        XCTAssertEqual(crossSession["error_code"] as? String, "stale_ref")
        XCTAssertEqual(crossSession["dispatched"] as? Bool, false)

        _ = try await runtime.webView!.evaluateJavaScript("document.getElementById('next').remove()")
        observation = try await observe(controller, runtime)
        let detached = try await call(controller, "wm_click", bound(runtime, observation, ref))
        XCTAssertEqual(detached["error_code"] as? String, "stale_ref")
        XCTAssertEqual(detached["dispatched"] as? Bool, false)
    }

    func testWrongWaitReturnsActualObservationAndDoesNotRepeatAction() async throws {
        let (controller, runtime) = try await fixture()
        var observation = try await observe(controller, runtime)
        var args = bound(runtime, observation, try target("Next", in: observation))
        args["postcondition"] = ["condition": "text", "value": "搜索结果", "timeout_ms": 100]
        let result = try await call(controller, "wm_click", args)
        XCTAssertEqual(result["error_code"] as? String, "postcondition_not_met")
        XCTAssertEqual(result["dispatched"] as? Bool, true)
        XCTAssertEqual(result["page_changed"] as? Bool, true)
        XCTAssertEqual(result["goal_verified"] as? Bool, false)
        let final = try XCTUnwrap(result["final_observation"] as? [String: Any])
        XCTAssertTrue((final["visible_text"] as? String)?.contains("相关内容 500 个") == true)
        XCTAssertEqual((result["retry"] as? [String: Any])?["automatic_retry_allowed"] as? Bool, false)
        let clicks = try await runtime.webView!.evaluateJavaScript("window.clicks") as? Int
        XCTAssertEqual(clicks, 1)

        observation = try await observe(controller, runtime)
        args = bound(runtime, observation, try target("Other", in: observation))
        args["postcondition"] = ["condition": "ready_state", "value": "complete", "timeout_ms": 100]
        let ready = try await call(controller, "wm_click", args)
        XCTAssertEqual(ready["error_code"] as? String, "postcondition_preexisting")
        XCTAssertEqual(ready["goal_verified"] as? Bool, false)

        let wait = try await call(controller, "wm_wait", [
            "session_id": runtime.snapshot.sessionId, "condition": "ready_state", "ready_state": "complete"
        ])
        XCTAssertEqual(wait["readiness_met"] as? Bool, true)
        XCTAssertEqual(wait["goal_verified"] as? Bool, false)

        observation = try await observe(controller, runtime)
        args = bound(runtime, observation, try target("Next", in: observation))
        args["postcondition"] = ["condition": "text", "value": "相关内容 500 个", "require_page_change": true, "timeout_ms": 500]
        let verified = try await call(controller, "wm_click", args)
        XCTAssertEqual(verified["goal_verified"] as? Bool, true, IOSWebMountController.json(verified))
        XCTAssertEqual(verified["page_changed"] as? Bool, true)
    }

    func testTypeVerifiesValueAndGetHonorsEmptySelectorAndSnapshot() async throws {
        let (controller, runtime) = try await fixture()
        var observation = try await observe(controller, runtime)
        let ref = try target("Query", in: observation)
        var args = bound(runtime, observation, ref)
        args["selector"] = ""
        args["text"] = "PS5"
        let typed = try await call(controller, "wm_type", args)
        XCTAssertEqual(typed["dispatched"] as? Bool, true)
        XCTAssertEqual(typed["goal_verified"] as? Bool, true)
        observation = try await observe(controller, runtime)
        args = bound(runtime, observation, ref)
        args["selector"] = ""
        args["kind"] = "value"
        let read = try await call(controller, "wm_get", args)
        XCTAssertEqual((read["result"] as? [String: Any])?["value"] as? String, "PS5")
        args["snapshot_id"] = "expired"
        let stale = try await call(controller, "wm_get", args)
        XCTAssertEqual(stale["error_code"] as? String, "stale_snapshot")
    }

    private func fixture() async throws -> (IOSWebMountController, IOSWebMountWKRuntime) {
        let runtime = IOSWebMountWKRuntime(sessionId: UUID().uuidString)
        let webView = try XCTUnwrap(runtime.webView)
        webView.loadHTMLString("""
            <!doctype html><html><body>
            <button id="next" type="button" onclick="window.clicks++;document.getElementById('result').textContent='结果: 找到 PS5 相关内容 500 个 '+window.clicks">Next</button>
            <button type="button">Other</button><input aria-label="Query" type="search">
            <div id="result">idle</div><script>window.clicks=0;</script>
            </body></html>
            """, baseURL: URL(string: "https://github.com/fixture"))
        var ready = false
        for _ in 0..<100 {
            if let state = try? await runtime.state(), state["ready_state"] as? String == "complete",
               (state["text_length"] as? Int ?? 0) > 0 { ready = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(ready, "Local WKWebView fixture did not load")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "webmount-contract-\(UUID().uuidString)"))
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: defaults),
            settings: IOSWebMountSettings(userDefaults: defaults), runtime: runtime
        )
        return (controller, runtime)
    }

    private func observe(_ controller: IOSWebMountController, _ runtime: IOSWebMountWKRuntime) async throws -> [String: Any] {
        try await call(controller, "wm_observe", ["session_id": runtime.snapshot.sessionId])
    }

    private func target(_ name: String, in observation: [String: Any]) throws -> String {
        let elements = try XCTUnwrap(observation["interactive_elements"] as? [[String: Any]])
        return try XCTUnwrap(elements.first { $0["name"] as? String == name }?["ref"] as? String)
    }

    private func bound(_ runtime: IOSWebMountWKRuntime, _ observation: [String: Any], _ ref: String) -> [String: Any] {
        ["session_id": runtime.snapshot.sessionId, "snapshot_id": observation["snapshot_id"] ?? "", "target": ref]
    }

    private func call(_ controller: IOSWebMountController, _ tool: String, _ args: [String: Any]) async throws -> [String: Any] {
        let output = await controller.execute(toolName: tool, input: IOSWebMountController.json(args), isUserInitiated: false, context: context)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}
