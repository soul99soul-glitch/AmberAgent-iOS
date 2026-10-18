import XCTest
import UIKit
import WebKit
import Shared
@testable import iosApp

@MainActor
final class IOSWebMountWKRuntimeTests: IOSWebMountToolTestCase {
    func testWebMountInteractionAcceptsDeclaredArgumentAliases() async throws {
        let runtime = MockWebMountRuntime()
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime
        )

        _ = await controller.execute(
            toolName: "wm_scroll",
            input: ##"{"target":"#main","by_y":240}"##,
            isUserInitiated: true
        )
        XCTAssertEqual(runtime.lastInteraction?.method, "scroll")
        XCTAssertEqual(runtime.lastInteraction?.selector, "#main")
        XCTAssertEqual(runtime.lastInteraction?.options["dy"] as? Int, 240)

        let tapOutput = await controller.execute(
            toolName: "wm_tap",
            input: #"{"x":48,"y":96,"snapshot_id":"mock-document:0"}"#,
            isUserInitiated: true
        )
        let tap = try jsonObject(tapOutput)
        XCTAssertEqual(runtime.lastInteraction?.method, "tap")
        XCTAssertEqual(runtime.lastInteraction?.options["x"] as? Int, 48)
        XCTAssertEqual(runtime.lastInteraction?.options["y"] as? Int, 96)
        XCTAssertEqual(tap["status"] as? String, "dispatched_unverified")
        XCTAssertEqual(tap["verified"] as? Bool, false)
        XCTAssertEqual(tap["may_have_applied"] as? Bool, true)
        let tapReceipt = try XCTUnwrap(tap["action_receipt"] as? [String: Any])
        XCTAssertEqual(tapReceipt["outcome"] as? String, "ambiguous")
        XCTAssertEqual(tapReceipt["dispatched"] as? Bool, true)
        let tapDiff = try XCTUnwrap(tap["diff"] as? [String: Any])
        XCTAssertEqual(tapDiff["changed"] as? Bool, false)
        XCTAssertEqual(tapDiff["revision_changed"] as? Bool, true)

        _ = await controller.execute(
            toolName: "wm_keys",
            input: #"{"text":"Enter"}"#,
            isUserInitiated: true
        )
        XCTAssertEqual(runtime.lastInteraction?.method, "keys")
        XCTAssertEqual(runtime.lastInteraction?.text, "Enter")

        _ = await controller.execute(
            toolName: "wm_find",
            input: #"{"text":"sign in","max_results":3}"#,
            isUserInitiated: true
        )
        XCTAssertEqual(runtime.lastInteraction?.method, "find")
        XCTAssertEqual(runtime.lastInteraction?.text, "sign in")
        XCTAssertEqual(runtime.lastInteraction?.options["max_results"] as? Int, 3)

        _ = await controller.execute(
            toolName: "wm_wait",
            input: ##"{"condition":"selector","selector":"#ready","timeout_ms":1200}"##,
            isUserInitiated: true
        )
        XCTAssertEqual(runtime.lastInteraction?.method, "wait")
        XCTAssertEqual(runtime.lastInteraction?.options["condition"] as? String, "selector")
        XCTAssertEqual(runtime.lastInteraction?.options["wait_ms"] as? Int, 1200)

        let interactionsBeforeInvalidPostcondition = runtime.interactionCallCount
        let invalidPostcondition = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json([
                "target": "css:button",
                "snapshot_id": "mock-document:\(runtime.pageRevision)",
                "postcondition": [
                    "condition": "ready_state",
                    "value": "loading"
                ]
            ]),
            isUserInitiated: true
        ))
        XCTAssertEqual(invalidPostcondition["error_code"] as? String, "invalid_postcondition")
        XCTAssertEqual(runtime.interactionCallCount, interactionsBeforeInvalidPostcondition)
    }

    func testWebMountPreexistingPostconditionCannotVerifyMutation() async throws {
        let runtime = MockWebMountRuntime(sessionId: "preexisting-postcondition")
        runtime.waitMatched = true
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime
        )

        let output = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json([
                "target": "css:button",
                "snapshot_id": "mock-document:0",
                "postcondition": [
                    "condition": "text",
                    "value": "already present",
                    "timeout_ms": 500
                ]
            ]),
            isUserInitiated: true
        ))

        XCTAssertEqual(output["ok"] as? Bool, false)
        XCTAssertEqual(output["status"] as? String, "ambiguous")
        XCTAssertEqual(output["error_code"] as? String, "postcondition_preexisting")
        XCTAssertEqual(output["may_have_applied"] as? Bool, true)
        XCTAssertEqual(output["verified"] as? Bool, false)
        let receipt = try XCTUnwrap(output["action_receipt"] as? [String: Any])
        XCTAssertEqual((receipt["precondition"] as? [String: Any])?["matched"] as? Bool, true)
    }

    func testWebMountWKRuntimeReportsDeniedSubframeDiagnosticsAndResets() async throws {
        let runtime = IOSWebMountWKRuntime(sessionId: "iframe-diagnostics")
        let webView = try XCTUnwrap(runtime.webView)
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        webView.loadHTMLString(
            """
            <!doctype html><html><body><main id="ready">parent ready</main></body></html>
            """,
            baseURL: URL(string: "https://github.com/")
        )

        var ready = false
        for _ in 0..<60 {
            if let state = try? await runtime.state(),
               state["ready_state"] as? String == "complete",
               (state["text_length"] as? Int ?? 0) > 0 {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(ready)

        let settings = IOSWebMountSettings(userDefaults: isolatedDefaults())
        let site = try XCTUnwrap(IOSWebMountSite.seeds().first { $0.id == "github" })
        let resolver: IOSWebMountHostResolver = { _ in ["10.0.0.8"] }
        let rejectingPolicy = IOSWebMountURLPolicy(
            settings: settings,
            allowUnlistedHosts: true
        )
        runtime.setNavigationPolicy(rejectingPolicy, site: site, resolveHost: resolver)

        _ = try await webView.evaluateJavaScript(
            """
            var frame = document.createElement('iframe');
            frame.id = 'blocked-frame';
            frame.src = 'https://blocked.example/login?token=secret';
            void document.body.appendChild(frame);
            """
        )

        var state: [String: Any] = [:]
        for _ in 0..<60 {
            if let candidate = try? await runtime.state(),
               let diagnostics = candidate["navigation_diagnostics"] as? [String: Any],
               (diagnostics["subframe_navigation_denied_count"] as? Int ?? 0) > 0 {
                state = candidate
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let stateDiagnostics = try XCTUnwrap(
            state["navigation_diagnostics"] as? [String: Any]
        )
        XCTAssertEqual(stateDiagnostics["subframe_navigation_denied_count"] as? Int, 1)
        let stateDenial = try XCTUnwrap(
            stateDiagnostics["last_subframe_navigation_denial"] as? [String: Any]
        )
        XCTAssertEqual(stateDenial["frame"] as? String, "subframe")
        XCTAssertEqual(stateDenial["decision"] as? String, "cancel")
        XCTAssertEqual(stateDenial["host"] as? String, "blocked.example")
        XCTAssertEqual(stateDenial["error_code"] as? String, "dns_non_public_address")
        XCTAssertTrue((stateDenial["reason"] as? String)?.contains("blocked.example") == true)
        XCTAssertFalse((stateDenial["url"] as? String)?.contains("token=secret") == true)
        XCTAssertNotEqual(runtime.snapshot.status, .failed)

        let observation = try await runtime.observe(maxChars: 2_000, maxLinks: 20)
        let observationDiagnostics = try XCTUnwrap(
            observation["navigation_diagnostics"] as? [String: Any]
        )
        XCTAssertEqual(observationDiagnostics["subframe_navigation_denied_count"] as? Int, 1)
        let observedPage = try XCTUnwrap(observation["page"] as? [String: Any])
        let pageDiagnostics = try XCTUnwrap(
            observedPage["navigation_diagnostics"] as? [String: Any]
        )
        XCTAssertEqual(pageDiagnostics["subframe_navigation_denied_count"] as? Int, 1)

        let allowlistedPolicy = IOSWebMountURLPolicy(settings: settings)
        runtime.setNavigationPolicy(allowlistedPolicy, site: site)
        let resetState = try await runtime.state()
        let resetDiagnostics = try XCTUnwrap(
            resetState["navigation_diagnostics"] as? [String: Any]
        )
        XCTAssertEqual(resetDiagnostics["subframe_navigation_denied_count"] as? Int, 0)
        XCTAssertNil(resetDiagnostics["last_subframe_navigation_denial"])
    }

    func testWebMountWKRuntimeStartsWithScreenViewportForDetachedAgentSession() async throws {
        let runtime = IOSWebMountWKRuntime(sessionId: "detached-viewport")
        let webView = try XCTUnwrap(runtime.webView)

        XCTAssertGreaterThan(webView.bounds.width, 0)
        XCTAssertGreaterThan(webView.bounds.height, 0)
        XCTAssertEqual(webView.bounds.size, UIScreen.main.bounds.size)

        webView.loadHTMLString(
            """
            <!doctype html>
            <html><head>
              <meta name="viewport" content="width=device-width, initial-scale=1">
            </head><body>viewport ready</body></html>
            """,
            baseURL: URL(string: "https://webmount.invalid/")
        )

        var readyState: [String: Any]?
        for _ in 0..<60 {
            if let state = try? await runtime.state(),
               state["ready_state"] as? String == "complete" {
                readyState = state
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let state = try XCTUnwrap(readyState)
        let viewport = try XCTUnwrap(state["viewport"] as? [String: Any])
        XCTAssertGreaterThan((viewport["width"] as? NSNumber)?.doubleValue ?? 0, 0)
        XCTAssertGreaterThan((viewport["height"] as? NSNumber)?.doubleValue ?? 0, 0)

        let customFrame = CGRect(x: 0, y: 0, width: 320, height: 480)
        webView.frame = customFrame
        webView.layoutIfNeeded()
        XCTAssertEqual(webView.frame.size, customFrame.size)
    }

    func testWebMountDecorativeSVGClickIsRejectedWithoutInterruptingInput() async throws {
        let runtime = IOSWebMountWKRuntime()
        let webView = try XCTUnwrap(runtime.webView)
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        webView.loadHTMLString("""
            <iframe id="drive" style="width:360px;height:300px" srcdoc="
                <input type='file' aria-label='上传'>
                <input type='search' hidden>
                <div><span>搜索云盘说明</span>
                <ui-autocomplete-token-field tabindex='0' aria-label='搜索云盘' onfocus=&quot;this.querySelector('input').hidden=false&quot;>
                    <svg width='24' height='24'><circle cx='12' cy='12' r='10'/></svg>
                    <input id='search' type='search' aria-label='搜索云盘' hidden>
                </ui-autocomplete-token-field>
                </div>
            "></iframe>
            """, baseURL: URL(string: "https://github.com/"))
        var readyObservation: [String: Any]?
        for _ in 0..<60 {
            let searchExists = ((try? await webView.evaluateJavaScript(
                "document.getElementById('drive').contentDocument.getElementById('search') !== null"
            )) as? Bool) == true
            if searchExists,
               let observed = try? await runtime.observe(maxChars: 8_000, maxLinks: 20),
               let candidates = observed["visual_candidates"] as? [[String: Any]],
               candidates.contains(where: {
                   $0["tag"] as? String == "svg" && ($0["ref"] as? String)?.isEmpty == false
               }),
               let elements = observed["interactive_elements"] as? [[String: Any]],
               elements.contains(where: {
                   $0["tag"] as? String == "ui-autocomplete-token-field"
                       && ($0["ref"] as? String)?.isEmpty == false
               }),
               let snapshotId = observed["snapshot_id"] as? String,
               !snapshotId.isEmpty {
                readyObservation = observed
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let observation = try XCTUnwrap(
            readyObservation,
            "WebMount iframe fixture did not expose its SVG, widget ref, and snapshot within the existing timeout"
        )
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime
        )
        let candidates = try XCTUnwrap(observation["visual_candidates"] as? [[String: Any]])
        let icon = try XCTUnwrap(candidates.first { $0["tag"] as? String == "svg" })
        let result = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json([
                "target": try XCTUnwrap(icon["ref"] as? String),
                "snapshot_id": try XCTUnwrap(observation["snapshot_id"] as? String)
            ]),
            isUserInitiated: false
        ))
        XCTAssertEqual(result["status"] as? String, "rejected", "Unexpected click result: \(result)")
        XCTAssertEqual(result["error_code"] as? String, "target_not_clickable")
        XCTAssertEqual(result["may_have_applied"] as? Bool, false)
        XCTAssertEqual(icon["single_click_supported"] as? Bool, false)

        let initialNodes = try XCTUnwrap(observation["interactive_elements"] as? [[String: Any]])
        let widgetRef = try XCTUnwrap(initialNodes.first { $0["tag"] as? String == "ui-autocomplete-token-field" }?["ref"] as? String)
        XCTAssertEqual(icon["interactive_target_ref"] as? String, widgetRef)
        XCTAssertEqual((result["action"] as? [String: Any])?["interactive_target_ref"] as? String, widgetRef)
        let upload = try XCTUnwrap(initialNodes.first { $0["name"] as? String == "上传" })
        XCTAssertEqual(upload["role"] as? String, "file")
        XCTAssertEqual(upload["typeable"] as? Bool, false)
        let foundWidget = try await runtime.interact(method: "find", selector: nil, text: "搜索云盘", options: ["max_results": 1])
        let widgetMatches = try XCTUnwrap(foundWidget["matches"] as? [[String: Any]])
        XCTAssertEqual(widgetMatches.first?["ref"] as? String, widgetRef)
        let focused = try await runtime.interact(method: "click", selector: widgetRef, text: nil,
            options: ["snapshot_id": try XCTUnwrap(foundWidget["snapshot_id"] as? String)])
        XCTAssertEqual(focused["focused"] as? Bool, true)

        // 测试用 WKWebView 不挂窗口：WebKit 只移动 activeElement、不派发 focus/focusin，
        // 由 wm_click 在确认无原生事件时补发（去掉补发时轮询 3 秒仍不可输入）。
        // 补发后页面处理器同步执行，这里轮询只是给 observe 的 DOM 快照留余量。
        var typeableObservation: [String: Any]?
        for _ in 0..<60 {
            if let observed = try? await runtime.observe(maxChars: 8_000, maxLinks: 20),
               let elements = observed["interactive_elements"] as? [[String: Any]],
               elements.contains(where: { $0["typeable"] as? Bool == true }) {
                typeableObservation = observed
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let refreshed = try XCTUnwrap(
            typeableObservation,
            "search input did not become typeable after focus within the existing timeout"
        )
        let nodes = try XCTUnwrap(refreshed["interactive_elements"] as? [[String: Any]])
        let inputRef = try XCTUnwrap(nodes.first { $0["typeable"] as? Bool == true }?["ref"] as? String)
        XCTAssertEqual(nodes.first?["ref"] as? String, inputRef)
        let foundInput = try await runtime.interact(method: "find", selector: "input[type='search']", text: nil, options: ["max_results": 1])
        let inputMatches = try XCTUnwrap(foundInput["matches"] as? [[String: Any]])
        XCTAssertEqual(inputMatches.first?["ref"] as? String, inputRef)
        let frames = try XCTUnwrap(refreshed["frames"] as? [[String: Any]])
        let frameId = try XCTUnwrap(frames.first { $0["parent_frame_id"] as? String == "root" }?["frame_id"] as? String)
        let scopedInput = try await runtime.interact(method: "find", selector: "frame:\(frameId):css:input[type='search']", text: nil, options: ["max_results": 1])
        XCTAssertEqual((scopedInput["matches"] as? [[String: Any]])?.first?["ref"] as? String, inputRef)
        let typed = try jsonObject(await controller.execute(
            toolName: "wm_type",
            input: IOSWebMountController.json([
                "target": inputRef,
                "snapshot_id": try XCTUnwrap(refreshed["snapshot_id"] as? String),
                "text": "Shadowrocket"
            ]),
            isUserInitiated: false
        ))
        XCTAssertEqual(typed["status"] as? String, "verified")
        let value = try await webView.evaluateJavaScript("document.getElementById('drive').contentDocument.getElementById('search').value") as? String
        XCTAssertEqual(value, "Shadowrocket")
    }

    func testWebMountWebContentTerminationFinishesPendingLoad() async throws {
        let runtime = IOSWebMountWKRuntime()
        let webView = try XCTUnwrap(runtime.webView)
        // Deliver the termination callback directly, without a real navigation
        // racing to complete the load first.
        webView.navigationDelegate = nil
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let load = Task { await runtime.open(url, timeoutMillis: 1_000) }
        while runtime.snapshot.status != .loading { await Task.yield() }
        runtime.webViewWebContentProcessDidTerminate(webView)
        let result = await load.value
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error, "Web content process terminated. Reopen the page before continuing.")
        XCTAssertEqual(runtime.snapshot.status, .failed)
    }

    func testWebMountSameOriginFrameReadActAndReload() async throws {
        let runtime = IOSWebMountWKRuntime()
        let webView = try XCTUnwrap(runtime.webView)
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        webView.loadHTMLString("""
            <html><body style="margin:0">
            <iframe id="drive" style="width:360px;height:600px;border:0" srcdoc="
                <label for='name'>File name</label><input id='name' value='old'>
                <button id='modules' onclick=&quot;document.getElementById('status').textContent='Modules opened'&quot; ondblclick=&quot;document.getElementById('status').textContent='Folder entered'&quot;>Modules</button>
                <div id='status'>Shadowrocket</div>
                <div style='height:1500px'></div><button id='bottom'>Script</button>
            "></iframe></body></html>
            """, baseURL: URL(string: "https://example.com/"))
        for _ in 0..<60 {
            if (try? await webView.evaluateJavaScript("document.getElementById('drive').contentDocument.readyState")) as? String == "complete" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let observation = try await runtime.observe(maxChars: 8_000, maxLinks: 20)
        XCTAssertTrue((observation["visible_text"] as? String ?? "").contains("Shadowrocket"))
        let nodes = try XCTUnwrap(observation["interactive_elements"] as? [[String: Any]])
        let buttonRef = try XCTUnwrap(nodes.first { $0["name"] as? String == "Modules" }?["ref"] as? String)
        let inputRef = try XCTUnwrap(nodes.first { $0["name"] as? String == "File name" }?["ref"] as? String)
        let find = try await runtime.interact(method: "find", selector: nil, text: "Modules", options: [:])
        XCTAssertEqual(find["found"] as? Bool, true)
        let click = try await runtime.interact(method: "click", selector: buttonRef, text: nil,
            options: ["snapshot_id": try XCTUnwrap(observation["snapshot_id"] as? String)])
        XCTAssertEqual(click["dispatched"] as? Bool, true)
        let status = try await webView.evaluateJavaScript("document.getElementById('drive').contentDocument.getElementById('status').textContent") as? String
        XCTAssertEqual(status, "Modules opened")
        let updated = try await runtime.observe(maxChars: 8_000, maxLinks: 20)
        let type = try await runtime.interact(method: "type", selector: inputRef, text: "edited", options: [
            "snapshot_id": try XCTUnwrap(updated["snapshot_id"] as? String)])
        XCTAssertEqual(type["verified"] as? Bool, true)
        let value = try await webView.evaluateJavaScript("document.getElementById('drive').contentDocument.getElementById('name').value") as? String
        XCTAssertEqual(value, "edited")
        _ = try await webView.evaluateJavaScript("window.clickDetails=[]; document.getElementById('drive').contentDocument.getElementById('modules').addEventListener('click', function(event){parent.clickDetails.push(event.detail)}); true")
        let beforeDoubleClick = try await runtime.observe(maxChars: 8_000, maxLinks: 20)
        _ = try await runtime.interact(method: "click", selector: buttonRef, text: nil, options: [
            "snapshot_id": try XCTUnwrap(beforeDoubleClick["snapshot_id"] as? String), "click_count": 2])
        let entered = try await webView.evaluateJavaScript("document.getElementById('drive').contentDocument.getElementById('status').textContent") as? String
        XCTAssertEqual(entered, "Folder entered")
        let clickDetails = try await webView.evaluateJavaScript("window.clickDetails") as? [Int]
        XCTAssertEqual(clickDetails, [1, 2], "Double-click consumers can use click.detail, not just dblclick")
        let beforeScroll = try await runtime.observe(maxChars: 8_000, maxLinks: 20)
        let candidates = try XCTUnwrap(beforeScroll["visual_candidates"] as? [[String: Any]])
        let frameRef = try XCTUnwrap(candidates.first { $0["tag"] as? String == "iframe" }?["ref"] as? String)
        _ = try await runtime.interact(method: "scroll", selector: frameRef, text: nil, options: [
            "snapshot_id": try XCTUnwrap(beforeScroll["snapshot_id"] as? String), "dy": 400])
        let scrolled = try await webView.evaluateJavaScript("document.getElementById('drive').contentWindow.scrollY") as? NSNumber
        XCTAssertGreaterThan(scrolled?.intValue ?? 0, 0)
        _ = try await webView.evaluateJavaScript("document.getElementById('drive').contentWindow.scrollTo(0,0); true")
        let beforeMutation = try await runtime.observe(maxChars: 8_000, maxLinks: 20)
        _ = try await webView.evaluateJavaScript("document.getElementById('drive').contentDocument.getElementById('status').textContent='changed'; true")
        let stale = try await runtime.interact(method: "click", selector: buttonRef, text: nil, options: [
            "snapshot_id": try XCTUnwrap(beforeMutation["snapshot_id"] as? String)])
        XCTAssertEqual(stale["error_code"] as? String, "stale_snapshot")
        _ = try await webView.evaluateJavaScript("document.getElementById('drive').srcdoc='<button>Replacement</button>'; true")
        for _ in 0..<60 {
            if (try? await webView.evaluateJavaScript("document.getElementById('drive').contentDocument.body.innerText")) as? String == "Replacement" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let reloaded = try await runtime.observe(maxChars: 8_000, maxLinks: 20)
        let oldRef = try await runtime.interact(method: "click", selector: buttonRef, text: nil, options: [
            "snapshot_id": try XCTUnwrap(reloaded["snapshot_id"] as? String)])
        XCTAssertEqual(oldRef["error_code"] as? String, "stale_ref")
    }

    func testWebMountFrameIsolationAndParentOcclusion() async throws {
        let runtime = IOSWebMountWKRuntime()
        let webView = try XCTUnwrap(runtime.webView)
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        webView.loadHTMLString("""
            <html><body style="margin:0">
            <iframe id="accessible" style="width:350px;height:250px" srcdoc="<button id='go'>Accessible</button><input id='editor' aria-label='Filename'>"></iframe>
            <iframe id="opaque" sandbox="allow-scripts" srcdoc="<button>Opaque secret</button>"></iframe>
            <iframe style="display:none" srcdoc="<button>Hidden frame text</button>"></iframe>
            <div id="overlay" style="position:fixed;inset:0;background:white;z-index:99"></div>
            </body></html>
            """, baseURL: URL(string: "https://example.com/"))
        for _ in 0..<60 {
            if (try? await webView.evaluateJavaScript("document.readyState===\"complete\" && document.getElementById(\"accessible\").contentDocument.body.innerText===\"Accessible\"")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let observation = try await runtime.observe(maxChars: 8_000, maxLinks: 20)
        let nodes = try XCTUnwrap(observation["interactive_elements"] as? [[String: Any]])
        XCTAssertFalse(nodes.contains { ($0["name"] as? String ?? "").contains("Opaque secret") })
        XCTAssertFalse(nodes.contains { ($0["name"] as? String ?? "").contains("Hidden frame text") })
        XCTAssertFalse((observation["visible_text"] as? String ?? "").contains("Hidden frame text"))
        let diagnostics = try XCTUnwrap(observation["frame_diagnostics"] as? [[String: Any]])
        XCTAssertTrue(diagnostics.contains { $0["error_code"] as? String == "cross_origin_frame" }, "\(observation)")
        let ref = try XCTUnwrap(nodes.first { $0["name"] as? String == "Accessible" }?["ref"] as? String)
        let click = try await runtime.interact(method: "click", selector: ref, text: nil, options: [
            "snapshot_id": try XCTUnwrap(observation["snapshot_id"] as? String)])
        XCTAssertEqual(click["error_code"] as? String, "target_occluded")
        let hiddenWait = try await runtime.interact(method: "wait", selector: nil, text: nil,
            options: ["condition": "text", "text": "Hidden frame text", "wait_ms": 100])
        XCTAssertEqual(hiddenWait["matched"] as? Bool, false, "Hidden iframe text must not verify an action")
        let opaqueRef = try XCTUnwrap(diagnostics.first { $0["error_code"] as? String == "cross_origin_frame" }?["frame_ref"] as? String)
        let fresh = try await runtime.observe(maxChars: 8_000, maxLinks: 20)
        let opaqueScroll = try await runtime.interact(method: "scroll", selector: opaqueRef, text: nil,
            options: ["snapshot_id": try XCTUnwrap(fresh["snapshot_id"] as? String), "dy": 100])
        XCTAssertEqual(opaqueScroll["error_code"] as? String, "cross_origin_frame")
        _ = try await webView.evaluateJavaScript("document.getElementById('overlay').remove(); document.getElementById('accessible').inert=true; true")
        let inert = try await runtime.observe(maxChars: 8_000, maxLinks: 20)
        let inertNodes = try XCTUnwrap(inert["interactive_elements"] as? [[String: Any]])
        let editor = try XCTUnwrap(inertNodes.first { $0["name"] as? String == "Filename" })
        XCTAssertEqual(editor["actionable"] as? Bool, false)
        let inertType = try await runtime.interact(method: "type", selector: try XCTUnwrap(editor["ref"] as? String), text: "must not write",
            options: ["snapshot_id": try XCTUnwrap(inert["snapshot_id"] as? String)])
        XCTAssertEqual(inertType["error_code"] as? String, "target_not_actionable")
    }

    func testWebMountWKRuntimeStableRefsKeysFindWaitAndStaleSnapshot() async throws {
        let runtime = IOSWebMountWKRuntime()
        let webView = try XCTUnwrap(runtime.webView)
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        webView.loadHTMLString(
            """
            <!doctype html><html><body>
              <script>window.__amberWebMountBridgeV1={document:document,documentId:"forged-page-world",revision:999};</script>
              <label for="field">Name</label><input id="field" value="A">
              <span id="editor-label">Notes</span><div id="editor" contenteditable="true" aria-labelledby="editor-label"></div>
              <span id="choice-label">Accept terms</span><input id="choice" type="checkbox" aria-labelledby="choice-label">
              <button id="inert-action" inert>Ignored action</button>
              <input id="hidden" type="hidden" value="opaque-token">
              <input id="password" type="password" value="">
              <input id="otp" name="otp" autocomplete="one-time-code" value="">
              <input id="card-number" autocomplete="cc-number" value="">
              <div id="hidden-secret" style="display:none">opaque-hidden-text</div>
              <div id="visible-shell" style="width:10px;height:10px"><span style="display:none">nested-hidden-text</span></div>
              <div style="opacity:0"><button id="transparent-secret">transparent-hidden-text</button></div>
              <a id="hidden-link" style="display:none" href="https://example.com/private">private-link</a>
              <button id="go" onclick="document.getElementById('status').textContent='clicked'">Go</button>
              <button id="pay" onclick="document.getElementById('status').textContent='paid'">Pay now</button>
              <form onsubmit="event.preventDefault();document.getElementById('status').textContent='submitted'">
                <button id="default-submit">Continue</button>
              </form>
              <form onsubmit="event.preventDefault();document.getElementById('status').textContent='otp-submitted'">
                <button id="verify-otp">Verify OTP</button>
              </form>
              <div id="status">idle</div>
            </body></html>
            """,
            baseURL: URL(string: "https://github.com/")
        )

        var ready = false
        for _ in 0..<60 {
            if let state = try? await runtime.state(),
               state["ready_state"] as? String == "complete",
               (state["text_length"] as? Int ?? 0) > 0 {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(ready)

        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: isolatedDefaults()),
            settings: IOSWebMountSettings(userDefaults: isolatedDefaults()),
            runtime: runtime
        )
        let observation = try jsonObject(await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: false))
        XCTAssertEqual(observation["ok"] as? Bool, true, "Unexpected observation payload: \(observation)")
        XCTAssertEqual(observation["observation_consistency"] as? String, "atomic")
        XCTAssertEqual(observation["untrusted_page_content"] as? Bool, true)
        let snapshotId = try XCTUnwrap(observation["snapshot_id"] as? String)
        let observedPage = try XCTUnwrap(observation["page"] as? [String: Any])
        XCTAssertEqual(observedPage["snapshot_id"] as? String, snapshotId)
        XCTAssertEqual(observedPage["page_revision"] as? Int, observation["page_revision"] as? Int)
        XCTAssertFalse(snapshotId.hasPrefix("forged-page-world:"))
        let pageWorldDocumentId = try await webView.evaluateJavaScript(
            "window.__amberWebMountBridgeV1.documentId"
        ) as? String
        XCTAssertEqual(pageWorldDocumentId, "forged-page-world")
        let elements = try XCTUnwrap(observation["interactive_elements"] as? [[String: Any]])
        let fieldRef = try XCTUnwrap(elements.first { ($0["tag"] as? String) == "input" }?["ref"] as? String)
        let checkboxRef = try XCTUnwrap(
            elements.first { ($0["selector"] as? String)?.contains("#choice") == true }?["ref"] as? String
        )
        XCTAssertEqual(elements.first { ($0["selector"] as? String)?.contains("#editor") == true }?["role"] as? String, "textbox")
        XCTAssertEqual(elements.first { ($0["selector"] as? String)?.contains("#editor") == true }?["name"] as? String, "Notes")
        XCTAssertEqual(elements.first { ($0["selector"] as? String)?.contains("#choice") == true }?["role"] as? String, "checkbox")
        XCTAssertEqual(elements.first { ($0["selector"] as? String)?.contains("#inert-action") == true }?["actionable"] as? Bool, false)
        XCTAssertFalse(elements.contains { ($0["selector"] as? String)?.contains("#hidden") == true })

        let hidden = try jsonObject(await controller.execute(
            toolName: "wm_get",
            input: ##"{"selector":"#hidden","kind":"value"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(hidden["ok"] as? Bool, false)
        XCTAssertFalse(IOSWebMountController.json(hidden).contains("opaque-token"))
        XCTAssertFalse(IOSWebMountController.json(observation).contains("private-link"))

        let hiddenFind = try jsonObject(await controller.execute(
            toolName: "wm_find",
            input: ##"{"selector":"#hidden-secret"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(hiddenFind["status"] as? String, "not_found")
        XCTAssertEqual(hiddenFind["verified"] as? Bool, false)
        XCTAssertFalse(IOSWebMountController.json(hiddenFind).contains("opaque-hidden-text"))

        let nestedHiddenText = try jsonObject(await controller.execute(
            toolName: "wm_get",
            input: ##"{"selector":"#visible-shell","kind":"text"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(nestedHiddenText["ok"] as? Bool, true)
        let nestedResult = try XCTUnwrap(nestedHiddenText["result"] as? [String: Any])
        XCTAssertEqual(nestedResult["value"] as? String, "")

        let transparentFind = try jsonObject(await controller.execute(
            toolName: "wm_find",
            input: ##"{"selector":"#transparent-secret"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(transparentFind["status"] as? String, "not_found")
        XCTAssertFalse(IOSWebMountController.json(transparentFind).contains("transparent-hidden-text"))

        let passwordWrite = try jsonObject(await controller.execute(
            toolName: "wm_type",
            input: ##"{"selector":"#password","text":"do-not-write"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(passwordWrite["ok"] as? Bool, false)
        XCTAssertEqual(passwordWrite["error_code"] as? String, "sensitive_field_requires_human")
        XCTAssertFalse(IOSWebMountController.json(passwordWrite).contains("do-not-write"))

        let otpWrite = try jsonObject(await controller.execute(
            toolName: "wm_type",
            input: ##"{"selector":"#otp","text":"123456"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(otpWrite["error_code"] as? String, "sensitive_field_requires_human")

        let otpRead = try jsonObject(await controller.execute(
            toolName: "wm_get",
            input: ##"{"selector":"#otp","kind":"value"}"##,
            isUserInitiated: false
        ))
        XCTAssertEqual(otpRead["ok"] as? Bool, false)

        let checkboxType = try jsonObject(await controller.execute(
            toolName: "wm_type",
            input: IOSWebMountController.json([
                "target": checkboxRef,
                "snapshot_id": snapshotId,
                "text": "not-applicable"
            ]),
            isUserInitiated: false
        ))
        XCTAssertEqual(checkboxType["ok"] as? Bool, false)
        XCTAssertEqual(checkboxType["error_code"] as? String, "target_not_typeable")

        let keysInput = IOSWebMountController.json([
            "target": fieldRef,
            "snapshot_id": snapshotId,
            "text": "Z"
        ])
        let keys = try jsonObject(await controller.execute(toolName: "wm_keys", input: keysInput, isUserInitiated: false))
        XCTAssertEqual(keys["ok"] as? Bool, true)
        XCTAssertEqual(keys["verified"] as? Bool, true)
        XCTAssertFalse(keysInput.contains("css:"))

        let value = try jsonObject(await controller.execute(
            toolName: "wm_get",
            input: IOSWebMountController.json(["target": fieldRef, "kind": "value"]),
            isUserInitiated: false
        ))
        let valueResult = try XCTUnwrap(value["result"] as? [String: Any])
        XCTAssertEqual(valueResult["value"] as? String, "AZ")

        let stale = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json(["target": fieldRef, "snapshot_id": snapshotId]),
            isUserInitiated: false
        ))
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error_code"] as? String, "stale_snapshot")

        let editorObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: false)
        )
        let editorSnapshot = try XCTUnwrap(editorObservation["snapshot_id"] as? String)
        let editorElements = try XCTUnwrap(editorObservation["interactive_elements"] as? [[String: Any]])
        let editorRef = try XCTUnwrap(
            editorElements.first { ($0["selector"] as? String)?.contains("#editor") == true }?["ref"] as? String
        )
        let editorType = try jsonObject(await controller.execute(
            toolName: "wm_type",
            input: IOSWebMountController.json([
                "target": editorRef,
                "snapshot_id": editorSnapshot,
                "text": "Hello editor",
                "postcondition": [
                    "condition": "text",
                    "value": "Hello editor",
                    "timeout_ms": 500
                ]
            ]),
            isUserInitiated: false
        ))
        XCTAssertEqual(editorType["status"] as? String, "verified")
        let editorValue = try jsonObject(await controller.execute(
            toolName: "wm_get",
            input: IOSWebMountController.json(["target": editorRef, "kind": "text"]),
            isUserInitiated: false
        ))
        XCTAssertEqual((editorValue["result"] as? [String: Any])?["value"] as? String, "Hello editor")

        let inertObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: false)
        )
        let inertSnapshot = try XCTUnwrap(inertObservation["snapshot_id"] as? String)
        let inertElements = try XCTUnwrap(inertObservation["interactive_elements"] as? [[String: Any]])
        let inertRef = try XCTUnwrap(
            inertElements.first { ($0["selector"] as? String)?.contains("#inert-action") == true }?["ref"] as? String
        )
        let inertClick = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json(["target": inertRef, "snapshot_id": inertSnapshot]),
            isUserInitiated: false
        ))
        XCTAssertEqual(inertClick["error_code"] as? String, "target_not_actionable")

        let found = try jsonObject(await controller.execute(
            toolName: "wm_find",
            input: #"{"text":"idle","max_results":2}"#,
            isUserInitiated: false
        ))
        XCTAssertEqual(found["ok"] as? Bool, true)
        let foundAction = try XCTUnwrap(found["action"] as? [String: Any])
        XCTAssertEqual(foundAction["found"] as? Bool, true)

        _ = try await webView.evaluateJavaScript(
            "setTimeout(function(){document.getElementById('status').textContent='ready';},80)"
        )
        let waited = try jsonObject(await controller.execute(
            toolName: "wm_wait",
            input: #"{"condition":"text","text":"ready","timeout_ms":1500}"#,
            isUserInitiated: false
        ))
        XCTAssertEqual(waited["ok"] as? Bool, true)
        let waitedAction = try XCTUnwrap(waited["action"] as? [String: Any])
        XCTAssertEqual(waitedAction["matched"] as? Bool, true)

        let timedOut = try jsonObject(await controller.execute(
            toolName: "wm_wait",
            input: #"{"condition":"text","text":"never-present","timeout_ms":100}"#,
            isUserInitiated: false
        ))
        XCTAssertEqual(timedOut["status"] as? String, "timed_out")
        let timeoutReceipt = try XCTUnwrap(timedOut["action_receipt"] as? [String: Any])
        XCTAssertEqual(timeoutReceipt["outcome"] as? String, "timed_out")

        let clickObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: false)
        )
        let clickSnapshot = try XCTUnwrap(clickObservation["snapshot_id"] as? String)
        let clickElements = try XCTUnwrap(clickObservation["interactive_elements"] as? [[String: Any]])
        let goRef = try XCTUnwrap(clickElements.first { ($0["name"] as? String) == "Go" }?["ref"] as? String)
        let verifiedClick = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json([
                "target": goRef,
                "snapshot_id": clickSnapshot,
                "postcondition": [
                    "condition": "text",
                    "value": "clicked",
                    "timeout_ms": 1_000
                ]
            ]),
            isUserInitiated: false
        ))
        XCTAssertEqual(verifiedClick["ok"] as? Bool, true)
        XCTAssertEqual(verifiedClick["status"] as? String, "verified")
        let clickReceipt = try XCTUnwrap(verifiedClick["action_receipt"] as? [String: Any])
        XCTAssertEqual(clickReceipt["outcome"] as? String, "verified")
        XCTAssertEqual(clickReceipt["verification_source"] as? String, "postcondition")
        let clickPostcondition = try XCTUnwrap(clickReceipt["postcondition"] as? [String: Any])
        XCTAssertEqual(clickPostcondition["matched"] as? Bool, true)

        let executor = makeExecutor(webMountController: controller)
        let submitObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: true)
        )
        let submitSnapshot = try XCTUnwrap(submitObservation["snapshot_id"] as? String)
        let submitElements = try XCTUnwrap(submitObservation["interactive_elements"] as? [[String: Any]])
        let submitRef = try XCTUnwrap(submitElements.first { ($0["name"] as? String) == "Continue" }?["ref"] as? String)
        let submitInput = IOSWebMountController.json([
            "session_id": runtime.snapshot.sessionId,
            "target": submitRef,
            "snapshot_id": submitSnapshot
        ])
        guard case .needsUserAction = await executor.execute(executor.executionRequest(
            toolName: "wm_click",
            operation: submitInput,
            isUserInitiated: false,
            runId: "submit-run",
            conversationId: "submit-conversation"
        )) else {
            return XCTFail("Expected default form button to require fresh approval")
        }
        let statusBeforeSubmit = try await webView.evaluateJavaScript(
            "document.getElementById('status').textContent"
        ) as? String
        XCTAssertNotEqual(statusBeforeSubmit, "submitted")
        guard case .webMountResult = await executor.execute(executor.executionRequest(
            toolName: "wm_click",
            operation: submitInput,
            isUserInitiated: true,
            runId: "submit-run",
            conversationId: "submit-conversation"
        )) else {
            return XCTFail("Expected approved default form submit")
        }
        let statusAfterSubmit = try await webView.evaluateJavaScript(
            "document.getElementById('status').textContent"
        ) as? String
        XCTAssertEqual(statusAfterSubmit, "submitted")

        let otpButtonObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: true)
        )
        let otpButtonSnapshot = try XCTUnwrap(otpButtonObservation["snapshot_id"] as? String)
        let otpButtonElements = try XCTUnwrap(otpButtonObservation["interactive_elements"] as? [[String: Any]])
        let otpButtonRef = try XCTUnwrap(otpButtonElements.first { ($0["name"] as? String) == "Verify OTP" }?["ref"] as? String)
        let otpButtonInput = IOSWebMountController.json([
            "session_id": runtime.snapshot.sessionId,
            "target": otpButtonRef,
            "snapshot_id": otpButtonSnapshot
        ])
        let otpButtonOutput = await executor.execute(executor.executionRequest(
            toolName: "wm_click",
            operation: otpButtonInput,
            isUserInitiated: false,
            runId: "submit-run",
            conversationId: "submit-conversation"
        ))
        guard case .needsUserAction(let otpButtonReason) = otpButtonOutput else {
            return XCTFail("Expected Verify OTP to require human handoff")
        }
        XCTAssertTrue(otpButtonReason.hasPrefix("human_handoff:"))
        let statusBeforeOTP = try await webView.evaluateJavaScript(
            "document.getElementById('status').textContent"
        ) as? String
        XCTAssertNotEqual(statusBeforeOTP, "otp-submitted")
        XCTAssertTrue(executor.completeWebMountHumanHandoff(
            toolName: "wm_click",
            input: otpButtonInput,
            runId: "submit-run"
        ))

        let payObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: true)
        )
        let paySnapshot = try XCTUnwrap(payObservation["snapshot_id"] as? String)
        let payElements = try XCTUnwrap(payObservation["interactive_elements"] as? [[String: Any]])
        let payRef = try XCTUnwrap(payElements.first { ($0["name"] as? String) == "Pay now" }?["ref"] as? String)
        let payInput = IOSWebMountController.json([
            "session_id": runtime.snapshot.sessionId,
            "target": payRef,
            "snapshot_id": paySnapshot
        ])
        let blockedPayOutput = await executor.execute(executor.executionRequest(
            toolName: "wm_click",
            operation: payInput,
            isUserInitiated: false,
            runId: "submit-run",
            conversationId: "submit-conversation"
        ))
        guard case .needsUserAction(let payReason) = blockedPayOutput else {
            return XCTFail("Expected snapshot-bound high-consequence approval")
        }
        XCTAssertTrue(payReason.contains("remote state"))
        let statusBeforeApproval = try await webView.evaluateJavaScript("document.getElementById('status').textContent") as? String
        XCTAssertNotEqual(statusBeforeApproval, "paid")

        let approvedPayOutput = await executor.execute(executor.executionRequest(
            toolName: "wm_click",
            operation: payInput,
            isUserInitiated: true,
            runId: "submit-run",
            conversationId: "submit-conversation"
        ))
        guard case .webMountResult(let approvedPayText) = approvedPayOutput else {
            return XCTFail("Expected approved WebMount result")
        }
        XCTAssertEqual(try jsonObject(approvedPayText)["ok"] as? Bool, true)
        let statusAfterApproval = try await webView.evaluateJavaScript("document.getElementById('status').textContent") as? String
        XCTAssertEqual(statusAfterApproval, "paid")

        let cardObservation = try jsonObject(
            await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: true)
        )
        let cardSnapshot = try XCTUnwrap(cardObservation["snapshot_id"] as? String)
        let cardElements = try XCTUnwrap(cardObservation["interactive_elements"] as? [[String: Any]])
        let cardRef = try XCTUnwrap(cardElements.first {
            ($0["selector"] as? String)?.contains("#card-number") == true
        }?["ref"] as? String)
        let cardInput = IOSWebMountController.json([
            "session_id": runtime.snapshot.sessionId,
            "target": cardRef,
            "snapshot_id": cardSnapshot,
            "text": "4111111111111111"
        ])
        let cardOutput = await executor.execute(executor.executionRequest(
            toolName: "wm_type",
            operation: cardInput,
            isUserInitiated: false,
            runId: "submit-run",
            conversationId: "submit-conversation"
        ))
        guard case .needsUserAction(let handoffReason) = cardOutput else {
            return XCTFail("Expected sensitive-field human handoff")
        }
        XCTAssertTrue(handoffReason.hasPrefix("human_handoff:"))
        XCTAssertTrue(executor.webMountHandoffIsPending(toolName: "wm_type", input: cardInput))
        XCTAssertTrue(
            executor.completeWebMountHumanHandoff(
                toolName: "wm_type",
                input: cardInput,
                runId: "submit-run"
            )
        )
        XCTAssertEqual(
            controller.sessionStore.record(sessionId: runtime.snapshot.sessionId)?.controlOwner,
            .agent
        )
        let cardValue = try await webView.evaluateJavaScript("document.getElementById('card-number').value") as? String
        XCTAssertEqual(cardValue, "")
        XCTAssertFalse(handoffReason.contains("4111111111111111"))
    }

}
