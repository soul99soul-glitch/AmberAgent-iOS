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

    func testEarlyFailureKeepsOnlyAnExistingLocalSessionId() async throws {
        let (controller, runtime) = try await fixture()
        let conflict = try await call(controller, "wm_click", [
            "session_id": runtime.snapshot.sessionId,
            "target": "wm:target-a",
            "selector": "wm:target-b"
        ])
        XCTAssertEqual(conflict["error_code"] as? String, "conflicting_target_arguments")
        XCTAssertEqual(conflict["session_id"] as? String, runtime.snapshot.sessionId)

        let missing = try await call(controller, "wm_state", ["session_id": "missing-local-session"])
        XCTAssertNil(missing["session_id"])
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

    func testUnrelatedDOMActivityDoesNotProveActionChangedPage() async throws {
        let (controller, runtime) = try await fixture()
        _ = try await runtime.webView?.evaluateJavaScript("document.getElementById('next').focus(); true")
        let observation = try await observe(controller, runtime)
        let result = try await call(controller, "wm_click", bound(runtime, observation, try target("Next", in: observation)))
        XCTAssertEqual(result["dispatched"] as? Bool, true)
        XCTAssertEqual(result["page_changed"] as? Bool, false)
        XCTAssertEqual(result["unattributed_page_activity"] as? Bool, true)
        XCTAssertEqual((result["action_receipt"] as? [String: Any])?["unattributed_page_activity"] as? Bool, true)
    }

    func testTargetRegionChangeIsAttributedToAction() async throws {
        let (controller, runtime) = try await fixture()
        _ = try await runtime.webView?.evaluateJavaScript("""
            const wrapper=document.createElement('div');
            document.getElementById('next').before(wrapper);
            wrapper.append(document.getElementById('next'), document.getElementById('result'));
            document.getElementById('next').focus(); true;
            """)
        let observation = try await observe(controller, runtime)
        let result = try await call(controller, "wm_click", bound(runtime, observation, try target("Next", in: observation)))
        XCTAssertEqual(result["page_changed"] as? Bool, true)
        XCTAssertEqual(result["unattributed_page_activity"] as? Bool, false)
    }

    func testFindAndWaitDoNotReusePreviousActionAttribution() async throws {
        let (controller, runtime) = try await fixture()
        let observation = try await observe(controller, runtime)
        let click = try await call(controller, "wm_click", bound(runtime, observation, try target("Next", in: observation)))
        XCTAssertEqual(click["page_changed"] as? Bool, true)

        let find = try await call(controller, "wm_find", ["session_id": runtime.snapshot.sessionId, "text": "Other"])
        XCTAssertEqual((find["action"] as? [String: Any])?["found"] as? Bool, true)
        XCTAssertEqual(find["page_changed"] as? Bool, false)

        let wait = try await call(controller, "wm_wait", [
            "session_id": runtime.snapshot.sessionId, "condition": "ready_state", "ready_state": "complete"
        ])
        XCTAssertEqual(wait["page_changed"] as? Bool, false)
    }

    func testLocatorSurvivesRefreshInsertionAndReorderButRejectsChangedStructure() async throws {
        let (controller, runtime) = try await fixture()
        let webView = try XCTUnwrap(runtime.webView)
        _ = try await webView.evaluateJavaScript("history.replaceState({}, '', '/fixture?q=private-query'); true")
        let observation = try await observe(controller, runtime)
        let clicked = try await call(controller, "wm_click", bound(runtime, observation, try target("Next", in: observation)))
        let locator = try XCTUnwrap((clicked["action_receipt"] as? [String: Any])?["locator"] as? [String: Any])
        XCTAssertEqual(locator["role"] as? String, "button")
        XCTAssertEqual((locator["attributes"] as? [String: Any])?["id"] as? String, "next")
        XCTAssertFalse((locator["url_pattern"] as? String ?? "").contains("?"))
        XCTAssertFalse(IOSWebMountController.json(locator).contains("private-query"))

        let oldDocumentId = (try await runtime.state())["document_id"] as? String
        webView.loadHTMLString("""
            <html><body><button id="next" type="button" onclick="window.clicks=(window.clicks||0)+1">Next</button>
            <button type="button">Other</button></body></html>
            """, baseURL: URL(string: "https://github.com/fixture"))
        for _ in 0..<100 {
            let state = try? await runtime.state()
            if state?["ready_state"] as? String == "complete", state?["document_id"] as? String != oldDocumentId { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let recovered = try await call(controller, "wm_find", ["session_id": runtime.snapshot.sessionId, "locator": locator])
        XCTAssertEqual(recovered["ok"] as? Bool, true, IOSWebMountController.json(recovered))
        _ = try await webView.evaluateJavaScript("document.body.innerHTML='<form aria-label=\"Search form\"><button type=\"button\">Other</button><button type=\"button\" onclick=\"window.clicks=(window.clicks||0)+1\">Next</button></form>'; true")
        // The original page has no landmark, so a real structural move into a form must fail.
        let changed = try await call(controller, "wm_find", ["session_id": runtime.snapshot.sessionId, "locator": locator])
        XCTAssertEqual(changed["error_code"] as? String, "locator_not_found")

        let refreshed = try await observe(controller, runtime)
        let newClick = try await call(controller, "wm_click", bound(runtime, refreshed, try target("Next", in: refreshed)))
        let formLocator = try XCTUnwrap((newClick["action_receipt"] as? [String: Any])?["locator"] as? [String: Any])
        XCTAssertNil((formLocator["attributes"] as? [String: Any])?["id"])
        _ = try await webView.evaluateJavaScript("document.querySelector('form').insertAdjacentHTML('afterbegin','<button type=\"button\">Inserted</button>'); document.querySelector('form').prepend(Array.from(document.querySelectorAll('form button')).find(x=>x.textContent==='Next')); true")
        let found = try await call(controller, "wm_find", ["session_id": runtime.snapshot.sessionId, "locator": formLocator])
        XCTAssertEqual(found["ok"] as? Bool, true, IOSWebMountController.json(found))
        let recoveredRef = try XCTUnwrap(((found["action"] as? [String: Any])?["matches"] as? [[String: Any]])?.first?["ref"] as? String)
        let stale = try await call(controller, "wm_click", bound(runtime, refreshed, recoveredRef))
        XCTAssertEqual(stale["error_code"] as? String, "stale_snapshot")
        let current = try await observe(controller, runtime)
        let acted = try await call(controller, "wm_click", bound(runtime, current, recoveredRef))
        XCTAssertEqual(acted["dispatched"] as? Bool, true)
    }

    func testLocatorAmbiguityAndSensitiveFieldsDoNotLeakValues() async throws {
        let (controller, runtime) = try await fixture()
        let webView = try XCTUnwrap(runtime.webView)
        _ = try await webView.evaluateJavaScript("document.body.innerHTML='<button type=\"button\">Same</button><button type=\"button\">Same</button><input id=\"react-a1b2c3d4e5f6\" aria-label=\"Query\" value=\"private-value\" type=\"search\">'; true")
        let observation = try await observe(controller, runtime)
        let sameRef = try target("Same", in: observation)
        let clicked = try await call(controller, "wm_click", bound(runtime, observation, sameRef))
        let locator = try XCTUnwrap((clicked["action_receipt"] as? [String: Any])?["locator"] as? [String: Any])
        let ambiguous = try await call(controller, "wm_find", ["session_id": runtime.snapshot.sessionId, "locator": locator])
        XCTAssertEqual(ambiguous["error_code"] as? String, "locator_ambiguous")
        XCTAssertEqual(((ambiguous["action"] as? [String: Any])?["candidates"] as? [[String: Any]])?.count, 2)

        let current = try await observe(controller, runtime)
        var args = bound(runtime, current, try target("Query", in: current))
        args["text"] = "new-private-value"
        let typed = try await call(controller, "wm_type", args)
        let typeLocator = try XCTUnwrap((typed["action_receipt"] as? [String: Any])?["locator"] as? [String: Any])
        let encoded = IOSWebMountController.json(typeLocator)
        XCTAssertNil((typeLocator["attributes"] as? [String: Any])?["id"])
        XCTAssertFalse(encoded.contains("private-value"))
        XCTAssertFalse(encoded.contains("new-private-value"))
    }

    func testLocatorUsesTableRowContextAfterReorderAndCountChange() async throws {
        let (controller, runtime) = try await fixture()
        let webView = try XCTUnwrap(runtime.webView)
        _ = try await webView.evaluateJavaScript("document.body.innerHTML='<table><tr><td>Alice</td><td><button onclick=\"window.aliceClicks=(window.aliceClicks||0)+1\">Reply 2</button></td></tr><tr><td>Bob</td><td><button onclick=\"window.bobClicks=(window.bobClicks||0)+1\">Reply 2</button></td></tr></table>'; true")
        let observation = try await observe(controller, runtime)
        let clicked = try await call(controller, "wm_click", bound(runtime, observation, try target("Reply 2", in: observation)))
        let locator = try XCTUnwrap((clicked["action_receipt"] as? [String: Any])?["locator"] as? [String: Any])
        XCTAssertEqual(locator["row_context"] as? String, "Alice")
        _ = try await webView.evaluateJavaScript("const table=document.querySelector('table'); table.prepend(table.rows[1]); table.rows[1].querySelector('button').textContent='Reply 3'; true")
        let found = try await call(controller, "wm_find", ["session_id": runtime.snapshot.sessionId, "locator": locator])
        XCTAssertEqual(found["ok"] as? Bool, true, IOSWebMountController.json(found))
        let ref = try XCTUnwrap(((found["action"] as? [String: Any])?["matches"] as? [[String: Any]])?.first?["ref"] as? String)
        let current = try await observe(controller, runtime)
        _ = try await call(controller, "wm_click", bound(runtime, current, ref))
        let aliceClicks = try await webView.evaluateJavaScript("window.aliceClicks") as? Int
        let bobClicks = try await webView.evaluateJavaScript("window.bobClicks")
        XCTAssertEqual(aliceClicks, 2)
        XCTAssertNil(bobClicks)
    }

    func testLocatorUsesListItemTitleAfterReorder() async throws {
        let (controller, runtime) = try await fixture()
        let webView = try XCTUnwrap(runtime.webView)
        _ = try await webView.evaluateJavaScript("document.body.innerHTML='<ul><li><span>Alice</span><button onclick=\"window.aliceLikes=(window.aliceLikes||0)+1\">Like</button></li><li><span>Bob</span><button onclick=\"window.bobLikes=(window.bobLikes||0)+1\">Like</button></li></ul>'; true")
        let observation = try await observe(controller, runtime)
        let clicked = try await call(controller, "wm_click", bound(runtime, observation, try target("Like", in: observation)))
        let locator = try XCTUnwrap((clicked["action_receipt"] as? [String: Any])?["locator"] as? [String: Any])
        XCTAssertEqual(locator["row_context"] as? String, "Alice")
        _ = try await webView.evaluateJavaScript("const list=document.querySelector('ul'); list.prepend(list.children[1]); true")
        let found = try await call(controller, "wm_find", ["session_id": runtime.snapshot.sessionId, "locator": locator])
        XCTAssertEqual(found["ok"] as? Bool, true, IOSWebMountController.json(found))
        let ref = try XCTUnwrap(((found["action"] as? [String: Any])?["matches"] as? [[String: Any]])?.first?["ref"] as? String)
        let current = try await observe(controller, runtime)
        _ = try await call(controller, "wm_click", bound(runtime, current, ref))
        let aliceLikes = try await webView.evaluateJavaScript("window.aliceLikes") as? Int
        let bobLikes = try await webView.evaluateJavaScript("window.bobLikes")
        XCTAssertEqual(aliceLikes, 2)
        XCTAssertNil(bobLikes)
    }

    func testLocatorKeepsIframeSeparateFromTopDocument() async throws {
        let (controller, runtime) = try await fixture()
        let webView = try XCTUnwrap(runtime.webView)
        _ = try await webView.evaluateJavaScript("document.body.innerHTML='<button>Reply</button><iframe style=\"width:240px;height:120px\" srcdoc=\"<button>Reply</button>\"></iframe>'; true")
        for _ in 0..<50 {
            if (try? await webView.evaluateJavaScript("!!document.querySelector('iframe').contentDocument?.querySelector('button')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let observation = try await observe(controller, runtime)
        let elements = try XCTUnwrap(observation["interactive_elements"] as? [[String: Any]])
        let iframeRef = try XCTUnwrap(elements.last { $0["name"] as? String == "Reply" }?["ref"] as? String)
        let clicked = try await call(controller, "wm_click", bound(runtime, observation, iframeRef))
        let locator = try XCTUnwrap((clicked["action_receipt"] as? [String: Any])?["locator"] as? [String: Any])
        XCTAssertEqual(locator["frame_document"] as? String, "about:srcdoc")
        let found = try await call(controller, "wm_find", ["session_id": runtime.snapshot.sessionId, "locator": locator])
        XCTAssertEqual(found["ok"] as? Bool, true, IOSWebMountController.json(found))
        XCTAssertEqual(((found["action"] as? [String: Any])?["matches"] as? [[String: Any]])?.count, 1)
    }

    func testActFindLocatorFeedsRefThroughExistingMutationGate() async throws {
        let (controller, runtime) = try await fixture()
        let observation = try await observe(controller, runtime)
        let clicked = try await call(controller, "wm_click", bound(runtime, observation, try target("Next", in: observation)))
        let locator = try XCTUnwrap((clicked["action_receipt"] as? [String: Any])?["locator"] as? [String: Any])
        let current = try await observe(controller, runtime)
        let acted = try await call(controller, "wm_act", [
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": current["snapshot_id"] ?? "",
            "steps": [["action": "find", "locator": locator], ["action": "click"]]
        ])
        let steps = try XCTUnwrap(acted["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 2, IOSWebMountController.json(acted))
        XCTAssertEqual(steps[0]["found"] as? Bool, true)
        XCTAssertEqual(steps[1]["dispatched"] as? Bool, true)
        let clicks = try await runtime.webView?.evaluateJavaScript("window.clicks") as? Int
        XCTAssertEqual(clicks, 2)
    }

    func testActRejectsStaleTopLevelSnapshotBeforeFindingLocator() async throws {
        let (controller, runtime) = try await fixture()
        let observation = try await observe(controller, runtime)
        let clicked = try await call(controller, "wm_click", bound(runtime, observation, try target("Next", in: observation)))
        let locator = try XCTUnwrap((clicked["action_receipt"] as? [String: Any])?["locator"] as? [String: Any])
        let result = try await call(controller, "wm_act", [
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": observation["snapshot_id"] ?? "",
            "steps": [["action": "find", "locator": locator], ["action": "click"]]
        ])
        XCTAssertEqual(result["error_code"] as? String, "stale_snapshot")
        XCTAssertEqual(result["requires_reobserve"] as? Bool, true)
        let clicks = try await runtime.webView?.evaluateJavaScript("window.clicks") as? Int
        XCTAssertEqual(clicks, 1)
    }

    func testApprovedAgentBatchStopsAtConsequentialStepAndKeepsPartialResult() async throws {
        let (controller, runtime) = try await fixture()
        let webView = try XCTUnwrap(runtime.webView)
        _ = try await webView.evaluateJavaScript("document.body.innerHTML='<button onclick=\"window.markCount=(window.markCount||0)+1\">Mark</button><button onclick=\"window.deleteCount=(window.deleteCount||0)+1\">Delete</button>'; true")
        let observation = try await observe(controller, runtime)
        let output = await controller.execute(toolName: "wm_act", input: IOSWebMountController.json([
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": observation["snapshot_id"] ?? "",
            "steps": [["action": "click", "target": try target("Mark", in: observation)],
                      ["action": "click", "target": try target("Delete", in: observation)]]
        ]), isUserInitiated: true, context: context)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(result["error_code"] as? String, "high_consequence_requires_approval")
        XCTAssertEqual(result["needs_user_action"] as? Bool, true)
        XCTAssertEqual(result["may_have_applied"] as? Bool, true)
        XCTAssertEqual(result["executed"] as? Int, 1)
        let markCount = try await webView.evaluateJavaScript("window.markCount") as? Int
        let deleteCount = try await webView.evaluateJavaScript("window.deleteCount")
        XCTAssertEqual(markCount, 1)
        XCTAssertNil(deleteCount)
    }

    func testTapAndSelectReceiptsCarryRefLocators() async throws {
        let (controller, runtime) = try await fixture()
        _ = try await runtime.webView?.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<select aria-label=\"Sort\"><option value=\"new\">New</option><option value=\"old\">Old</option></select>'); true")
        var observation = try await observe(controller, runtime)
        let tapped = try await call(controller, "wm_tap", bound(runtime, observation, try target("Other", in: observation)))
        XCTAssertEqual(((tapped["action_receipt"] as? [String: Any])?["locator"] as? [String: Any])?["name"] as? String, "Other")
        observation = try await observe(controller, runtime)
        var args = bound(runtime, observation, try target("Sort", in: observation))
        args["text"] = "old"
        let selected = try await call(controller, "wm_select", args)
        let locator = try XCTUnwrap((selected["action_receipt"] as? [String: Any])?["locator"] as? [String: Any])
        XCTAssertEqual(locator["role"] as? String, "combobox")
        XCTAssertFalse(IOSWebMountController.json(locator).contains("\"value\""))
    }

    func testLocatorRecoversTextFoundDivRef() async throws {
        let (controller, runtime) = try await fixture()
        let webView = try XCTUnwrap(runtime.webView)
        _ = try await webView.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<div onclick=\"window.divClicks=(window.divClicks||0)+1\">Plain target</div>'); true")
        let found = try await call(controller, "wm_find", ["session_id": runtime.snapshot.sessionId, "text": "Plain target"])
        let matches = try XCTUnwrap((found["action"] as? [String: Any])?["matches"] as? [[String: Any]])
        let ref = try XCTUnwrap(matches.first { $0["tag"] as? String == "div" }?["ref"] as? String)
        let observation = try await observe(controller, runtime)
        let clicked = try await call(controller, "wm_click", bound(runtime, observation, ref))
        let locator = try XCTUnwrap((clicked["action_receipt"] as? [String: Any])?["locator"] as? [String: Any])
        _ = try await webView.evaluateJavaScript("document.querySelector('div[onclick]').outerHTML='<div onclick=\"window.divClicks=(window.divClicks||0)+1\">Plain target</div>'; true")
        let recovered = try await call(controller, "wm_find", ["session_id": runtime.snapshot.sessionId, "locator": locator])
        XCTAssertEqual(recovered["ok"] as? Bool, true, IOSWebMountController.json(recovered))
    }

    func testReadToolsReportNavigationSinceLastAgentObservation() async throws {
        let (controller, runtime) = try await fixture()
        _ = try await observe(controller, runtime)
        for (path, tool) in [("/state", "wm_state"), ("/extract", "wm_extract"), ("/get", "wm_get")] {
            _ = try await runtime.webView?.evaluateJavaScript("history.pushState({}, '', '\(path)'); true")
            let result = try await call(controller, tool, ["session_id": runtime.snapshot.sessionId])
            XCTAssertEqual(result["page_drift"] as? Bool, true, tool)
            XCTAssertNotEqual(result["previous_url"] as? String, result["current_url"] as? String, tool)
        }
        let stable = try await call(controller, "wm_state", ["session_id": runtime.snapshot.sessionId])
        XCTAssertNil(stable["page_drift"])
        _ = try await runtime.webView?.evaluateJavaScript("history.pushState({}, '', '/get?private=changed'); true")
        let queryDrift = try await call(controller, "wm_state", ["session_id": runtime.snapshot.sessionId])
        XCTAssertEqual(queryDrift["page_drift"] as? Bool, true)
        XCTAssertEqual(queryDrift["previous_url"] as? String, queryDrift["current_url"] as? String)
    }

    func testGetWithEmptyTargetStillRecognizesSelectorRefForDrift() async throws {
        let (controller, runtime) = try await fixture()
        let observation = try await observe(controller, runtime)
        let ref = try target("Next", in: observation)
        _ = try await runtime.webView?.evaluateJavaScript("history.pushState({}, '', '/after-observation'); true")
        let result = try await call(controller, "wm_get", [
            "session_id": runtime.snapshot.sessionId, "target": "", "selector": ref
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertNil(result["page_drift"])
    }

    func testGroupedCredentialsAreHiddenFromExtractAndGet() async throws {
        let (labeled, wasRedacted) = IOSWebMountRedactor.redactedCredentialGroups("Recovery code 1: A1B2C3D4E5F6G7H8J9K0\nRecovery code 2: K9J8H7G6F5E4D3C2B1A0")
        XCTAssertTrue(wasRedacted)
        XCTAssertEqual(labeled, "[已隐去 2 行疑似凭据]")

        let digestPage = "SHA-256 checksums:\n b027d75b3fd90b47e91a2d8379309de1c804ad693d1d599fc6a32acecc13e917\n 4bb00f7e404979567ad5e04933abc24e03b49336123a6a419b58ac6bab773dbb"
        let (preservedDigests, digestsRedacted) = IOSWebMountRedactor.redactedCredentialGroups(digestPage)
        XCTAssertFalse(digestsRedacted)
        XCTAssertEqual(preservedDigests, digestPage)

        let labeledHashes = "API keys:\n\nb027d75b3fd90b47e91a2d8379309de1c804ad693d1d599fc6a32acecc13e917\n4bb00f7e404979567ad5e04933abc24e03b49336123a6a419b58ac6bab773dbb"
        let (hiddenLabeledHashes, labeledHashesRedacted) = IOSWebMountRedactor.redactedCredentialGroups(labeledHashes)
        XCTAssertTrue(labeledHashesRedacted)
        XCTAssertEqual(hiddenLabeledHashes, "API keys:\n\n[已隐去 2 行疑似凭据]")

        let ordinaryText = "https://example.com/a/very/long/path/without/a/credential\nhttps://downloads.example.org/releases/2026/builds/ios/arm64/archive.zip\nThis ordinary paragraph remains visible to the agent."
        let (preservedText, ordinaryTextRedacted) = IOSWebMountRedactor.redactedCredentialGroups(ordinaryText)
        XCTAssertFalse(ordinaryTextRedacted)
        XCTAssertEqual(preservedText, ordinaryText)

        let (controller, runtime) = try await fixture()
        _ = try await runtime.webView?.evaluateJavaScript("document.body.innerHTML='<pre>Recovery codes\\nA1B2C3D4E5F6G7H8J9K0\\nK9J8H7G6F5E4D3C2B1A0\\nPublic note</pre>'; true")
        let extract = try await call(controller, "wm_extract", ["session_id": runtime.snapshot.sessionId])
        XCTAssertEqual(extract["credential_redacted"] as? Bool, true)
        let extractedText = (extract["result"] as? [String: Any])?["text"] as? String ?? ""
        XCTAssertTrue(extractedText.contains("[已隐去 2 行疑似凭据]"))
        XCTAssertFalse(extractedText.contains("A1B2C3D4"))
        let get = try await call(controller, "wm_get", ["session_id": runtime.snapshot.sessionId])
        XCTAssertEqual(get["credential_redacted"] as? Bool, true)
        let getText = (get["result"] as? [String: Any])?["value"] as? String ?? ""
        XCTAssertTrue(getText.contains("[已隐去 2 行疑似凭据]"))
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
