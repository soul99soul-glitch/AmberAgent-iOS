import XCTest
import UIKit
import WebKit
import Shared
@testable import iosApp

@MainActor
final class IOSWebMountVisualApprovalTests: IOSWebMountToolTestCase {
    func testWebMountObserveSnapshotAndScreenshotAreRedacted() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let runtime = try XCTUnwrap(controller.runtime as? MockWebMountRuntime)
        controller.registry.setEnabled(id: "github", enabled: true)
        _ = await controller.execute(
            toolName: "wm_open",
            input: #"{"site_id":"github","url":"https://github.com/login?token=secret"}"#,
            isUserInitiated: true
        )

        let observe = await controller.execute(toolName: "wm_observe", input: "{}", isUserInitiated: true)
        XCTAssertTrue(observe.contains("Hello from mock"))
        XCTAssertFalse(observe.contains("token=secret"))
        XCTAssertEqual(runtime.observeCallCount, 1)
        let observation = try jsonObject(observe)
        XCTAssertEqual(observation["untrusted_page_content"] as? Bool, true)
        XCTAssertEqual(observation["observation_consistency"] as? String, "unknown")

        let visual = await controller.execute(toolName: "wm_visual_snapshot", input: "{}", isUserInitiated: true)
        XCTAssertTrue(visual.contains("visual_candidates"))
        XCTAssertFalse(visual.contains("token=secret"))

        let blockedScreenshot = try jsonObject(await controller.execute(toolName: "wm_screenshot", input: "{}", isUserInitiated: false))
        XCTAssertEqual(blockedScreenshot["needs_user_action"] as? Bool, true)

        let screenshot = try jsonObject(await controller.execute(toolName: "wm_screenshot", input: "{}", isUserInitiated: true))
        XCTAssertEqual(screenshot["ok"] as? Bool, true)
        let artifact = try XCTUnwrap(screenshot["artifact"] as? [String: Any])
        XCTAssertEqual(artifact["format"] as? String, "png")
        XCTAssertEqual(artifact["width"] as? Int, 390)
        XCTAssertEqual(artifact["height"] as? Int, 844)
        XCTAssertEqual(artifact["size_bytes"] as? Int, 4)
        XCTAssertFalse(IOSWebMountController.json(screenshot).contains("base64"))
    }

    func testWebMountVisualReadRequiresApprovalAndUsesRealCapture() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let executor = makeExecutor(webMountController: controller)
        var calls = 0
        let reader: IOSWebMountVisualReadHandler = { capture, question in
            calls += 1
            XCTAssertEqual(capture.width, 390)
            XCTAssertEqual(capture.height, 844)
            XCTAssertFalse(capture.data.isEmpty)
            XCTAssertEqual(question, "Is the login form visible?")
            return "The login form is visible."
        }
        let input = #"{"question":"Is the login form visible?"}"#
        let blocked = await executor.execute(
            executor.executionRequest(toolName: "wm_visual_read", operation: input, isUserInitiated: false),
            visualRead: reader
        )
        guard case .needsUserAction = blocked else { return XCTFail("Visual reading must request screenshot upload approval") }
        XCTAssertEqual(calls, 0)
        let approved = await executor.execute(
            executor.executionRequest(toolName: "wm_visual_read", operation: input, isUserInitiated: true),
            visualRead: reader
        )
        guard case .webMountResult(let text) = approved else { return XCTFail("Expected visual result") }
        let result = try jsonObject(text)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["analysis"] as? String, "The login form is visible.")
        XCTAssertEqual(result["verification_source"] as? String, "screenshot")
        XCTAssertEqual(result["observation_only"] as? Bool, true)
        XCTAssertEqual(result["snapshot_id"] as? String, "mock-document:0")
        XCTAssertFalse(text.contains("base64"))
        XCTAssertNil(result["artifact"])
        let preview = try XCTUnwrap(executor.webMountApprovalPreview(toolName: "wm_visual_read", input: input))
        XCTAssertTrue(preview.consequence.contains("发送"))
        XCTAssertTrue(preview.consequence.contains("视觉模型"))
    }

    func testWebMountVisualReadReturnsSafeRequestDiagnostics() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let text = await controller.execute(
            toolName: "wm_visual_read", input: "{}", isUserInitiated: true,
            visualRead: { _, _ in
                throw IOSWebMountVisionReader.RequestFailure(
                    error: IOSGeminiError.httpStatus(400, "apiKey=secret private response"),
                    model: "vision-model", provider: "Vision"
                )
            }
        )
        let result = try jsonObject(text)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error_code"] as? String, "vision_request_failed")
        let diagnostics = try XCTUnwrap(result["diagnostics"] as? [String: Any])
        XCTAssertEqual(diagnostics["http_status"] as? Int, 400)
        XCTAssertEqual(diagnostics["category"] as? String, "request_rejected")
        XCTAssertEqual(result["visual_verified"] as? Bool, false)
        XCTAssertEqual(result["dom_only"] as? Bool, true)
        XCTAssertEqual(result["automatic_retry_allowed"] as? Bool, false)
        XCTAssertEqual(diagnostics["model"] as? String, "vision-model")
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("private"))
    }

    func testWebMountVisualReadMarksResultsStaleAndReportsMissingReader() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let runtime = try XCTUnwrap(controller.runtime as? MockWebMountRuntime)
        let missing = try jsonObject(await controller.execute(toolName: "wm_visual_read", input: "{}", isUserInitiated: true))
        XCTAssertEqual(missing["error_code"] as? String, "vision_unavailable")
        XCTAssertEqual(missing["dom_only"] as? Bool, true)
        let stale = try jsonObject(await controller.execute(
            toolName: "wm_visual_read", input: "{}", isUserInitiated: true,
            visualRead: { _, _ in
                runtime.pageRevision += 1
                return "Analysis of the earlier page."
            }
        ))
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error_code"] as? String, "stale_visual_read")
        XCTAssertEqual(stale["requires_reobserve"] as? Bool, true)
        XCTAssertEqual(stale["snapshot_id"] as? String, "mock-document:0")
    }

    func testWebMountSiteAddRemoveSyncsAllowlistAndDoesNotClearCookies() async throws {
        let controller = makeWebMountController(globalEnabled: true, resolveHost: { _ in ["198.18.0.34"] })
        let cookieStore = try XCTUnwrap(controller.cookieStore as? MockWebMountCookieStore)

        let blockedAdd = try jsonObject(await controller.execute(
            toolName: "wm_site_add",
            input: #"{"display_name":"Example","homepage_url":"https://docs.example.com/a?token=secret"}"#,
            isUserInitiated: false
        ))
        XCTAssertEqual(blockedAdd["needs_user_action"] as? Bool, true)

        let added = try jsonObject(await controller.execute(
            toolName: "wm_site_add",
            input: #"{"display_name":"Example","homepage_url":"https://docs.example.com/a?token=secret","login_cookie_name":"sid"}"#,
            isUserInitiated: true
        ))
        XCTAssertEqual(added["ok"] as? Bool, true)
        let siteId = try XCTUnwrap(added["site_id"] as? String)
        XCTAssertEqual(added["enabled"] as? Bool, true)
        XCTAssertTrue(controller.settings.allowedHosts.contains("docs.example.com"))
        XCTAssertFalse(IOSWebMountController.json(added).contains("token=secret"))

        let sessionId = try XCTUnwrap(controller.sessionStore.records.first?.id)
        let executor = makeExecutor(webMountController: controller)
        let opened = await executor.execute(IOSLocalToolExecutionRequest(
            toolName: "wm_open",
            operation: IOSWebMountController.json(["session_id": sessionId, "site_id": siteId]),
            scopeDigest: "",
            payloadDigest: "",
            isUserInitiated: false,
            runId: "new-site-run",
            conversationId: "new-site-conversation",
            executionPolicy: IOSExecutionPolicySnapshot(
                capabilityPolicies: [:],
                globalAutoApproveEnabled: false,
                highRiskAutoApproveEnabled: true,
                execJavaScriptEnabled: false,
                webSearchEnabled: false
            )
        ))
        guard case .webMountResult(let openedText) = opened else {
            return XCTFail("Expected newly added station to open immediately, got \(opened)")
        }
        XCTAssertEqual(try jsonObject(openedText)["ok"] as? Bool, true)
        controller.releaseAgentOwnership(runId: "new-site-run")

        let removed = try jsonObject(await controller.execute(
            toolName: "wm_site_remove",
            input: IOSWebMountController.json(["site_id": siteId]),
            isUserInitiated: true
        ))
        XCTAssertEqual(removed["removed"] as? Bool, true)
        XCTAssertEqual(removed["cookies_cleared"] as? Bool, false)
        XCTAssertFalse(controller.settings.allowedHosts.contains("docs.example.com"))
        XCTAssertTrue(cookieStore.clearedSiteIds.isEmpty)
    }

    func testWebMountExecutorRequiresApprovalAndClearRequiresUserAction() async throws {
        let controller = makeWebMountController(globalEnabled: false)
        let executor = makeExecutor(webMountController: controller)
        let noAutoApprove = IOSExecutionPolicySnapshot(
            capabilityPolicies: [:],
            globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: false,
            execJavaScriptEnabled: false,
            webSearchEnabled: false
        )

        let stationsOutput = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "wm_stations",
                operation: "{}",
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false,
                executionPolicy: noAutoApprove
            )
        )
        guard case .needsUserAction(let stationsReason) = stationsOutput else {
            return XCTFail("Expected needsUserAction, got \(stationsOutput)")
        }
        XCTAssertTrue(stationsReason.contains("WebMount browser tools"))

        let clearOutput = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "wm_clear_session",
                operation: #"{"site_id":"github"}"#,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false,
                executionPolicy: noAutoApprove
            )
        )
        guard case .needsUserAction(let clearReason) = clearOutput else {
            return XCTFail("Expected needsUserAction, got \(clearOutput)")
        }
        XCTAssertTrue(clearReason.contains("Clearing WebMount cookies"))

        let screenshotOutput = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "wm_screenshot",
                operation: "{}",
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false,
                executionPolicy: noAutoApprove
            )
        )
        guard case .needsUserAction(let screenshotReason) = screenshotOutput else {
            return XCTFail("Expected needsUserAction, got \(screenshotOutput)")
        }
        XCTAssertTrue(screenshotReason.contains("wm_screenshot"))

        let siteAddOutput = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "wm_site_add",
                operation: #"{"display_name":"Example","homepage_url":"https://example.com"}"#,
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false,
                executionPolicy: noAutoApprove
            )
        )
        guard case .needsUserAction(let siteAddReason) = siteAddOutput else {
            return XCTFail("Expected needsUserAction, got \(siteAddOutput)")
        }
        XCTAssertTrue(siteAddReason.contains("wm_site_add"))
    }

    func testWebMountExecutorAllowsToolsAfterForegroundApproval() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let executor = makeExecutor(webMountController: controller)

        let output = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "wm_stations",
                operation: "{}",
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: true
            )
        )

        guard case .webMountResult(let text) = output else {
            return XCTFail("Expected WebMount result, got \(output)")
        }
        let object = try jsonObject(text)
        XCTAssertEqual(object["ok"] as? Bool, true)
    }

    func testWebMountHighRiskAutoApprovalCoversExplicitApprovalActions() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let executor = makeExecutor(webMountController: controller)
        let policy = IOSExecutionPolicySnapshot(
            capabilityPolicies: [:], globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: true, execJavaScriptEnabled: false, webSearchEnabled: false
        )
        var reads = 0
        let reader: IOSWebMountVisualReadHandler = { _, _ in
            reads += 1
            return "Visible page"
        }
        func execute(_ name: String, _ input: String) async throws -> [String: Any] {
            let output = await executor.execute(
                executor.executionRequest(
                    toolName: name, operation: input, isUserInitiated: false,
                    executionPolicy: policy
                ), visualRead: reader
            )
            guard case .webMountResult(let text) = output else {
                XCTFail("\(name) unexpectedly requested approval: \(output)")
                return [:]
            }
            return try jsonObject(text)
        }
        let added = try jsonObject(await controller.execute(toolName: "wm_site_add",
            input: #"{"display_name":"User configured","homepage_url":"https://example.com/"}"#,
            isUserInitiated: true))
        let siteId = try XCTUnwrap(added["site_id"] as? String)
        let originalSites = controller.registry.sites
        let originalHosts = controller.settings.allowedHosts
        for (name, input) in [
            ("wm_site_add", #"{"display_name":"Agent addition","homepage_url":"https://unlisted.example/"}"#),
            ("wm_site_remove", IOSWebMountController.json(["site_id": siteId]))
        ] {
            let output = await executor.execute(executor.executionRequest(
                toolName: name, operation: input, isUserInitiated: false, executionPolicy: policy))
            guard case .needsUserAction = output else {
                XCTFail("High-risk browsing must not authorize registry changes: \(output)")
                continue
            }
        }
        XCTAssertEqual(controller.registry.sites, originalSites)
        XCTAssertEqual(controller.settings.allowedHosts, originalHosts)
        for name in ["wm_screenshot", "wm_visual_read"] {
            let result = try await execute(name, "{}")
            XCTAssertEqual(result["ok"] as? Bool, true, name)
        }
        XCTAssertEqual(reads, 1)
        let sessionId = try XCTUnwrap(controller.sessionStore.records.first?.id)
        let runtime = try XCTUnwrap(controller.sessionStore.runtimeIfPresent(sessionId: sessionId) as? MockWebMountRuntime)
        _ = try await execute("wm_click", #"{"selector":"button"}"#)
        XCTAssertEqual(runtime.lastInteraction?.options["_amber_allow_high_consequence"] as? Bool, true)
        let preflight = await executor.webMountActionPreflight(
            toolName: "wm_click", input: #"{"selector":"button"}"#,
            runId: "", conversationId: "", executionPolicy: policy
        )
        XCTAssertNil(preflight)
        let persistent = try await execute("wm_tab_new", #"{"persistent":true}"#)
        XCTAssertNotEqual(persistent["needs_user_action"] as? Bool, true)
        let clear = try await execute("wm_clear_session", IOSWebMountController.json(["site_id": siteId]))
        XCTAssertNotEqual(clear["needs_user_action"] as? Bool, true)
        XCTAssertEqual((controller.cookieStore as? MockWebMountCookieStore)?.clearedSiteIds, [siteId])
        let removed = try jsonObject(await controller.execute(toolName: "wm_site_remove",
            input: IOSWebMountController.json(["site_id": siteId]), isUserInitiated: true))
        XCTAssertEqual(removed["removed"] as? Bool, true)

        let off = IOSExecutionPolicySnapshot(
            capabilityPolicies: [:], globalAutoApproveEnabled: true,
            highRiskAutoApproveEnabled: false, execJavaScriptEnabled: false, webSearchEnabled: false
        )
        for name in ["wm_screenshot", "wm_visual_read", "wm_site_add", "wm_site_remove", "wm_clear_session"] {
            let output = await executor.execute(executor.executionRequest(
                toolName: name, operation: "{}", isUserInitiated: false, executionPolicy: off
            ))
            guard case .needsUserAction = output else {
                XCTFail("\(name) must restore manual approval when high-risk approval is off")
                continue
            }
        }
    }

    func testWebMountExecutorRespectsDisabledPermissionPolicy() async throws {
        let defaults = isolatedDefaults()
        let permissionStore = IOSPermissionStore(userDefaults: defaults)
        let capability = try XCTUnwrap(
            IOSCapabilityRegistry.capabilities.first { $0.id == "ios.webmount.browser" }
        )
        permissionStore.setPolicy(.disabled, for: capability)
        let executor = makeExecutor(
            permissionStore: permissionStore,
            webMountController: makeWebMountController(globalEnabled: true)
        )

        let output = await executor.execute(
            IOSLocalToolExecutionRequest(
                toolName: "wm_stations",
                operation: "{}",
                scopeDigest: "",
                payloadDigest: "",
                isUserInitiated: false
            )
        )

        guard case .denied(let reason) = output else {
            return XCTFail("Expected denied, got \(output)")
        }
        XCTAssertTrue(reason.contains("Disabled"))
    }

    func testWebMountOpenRequiresRegisteredEnabledStation() async throws {
        let controller = makeWebMountController(globalEnabled: true)

        let missing = await controller.execute(
            toolName: "wm_open",
            input: #"{"url":"https://removed.example.com/path?token=secret"}"#,
            isUserInitiated: true
        )
        let missingObject = try jsonObject(missing)
        XCTAssertEqual(missingObject["denied"] as? Bool, true)
        XCTAssertFalse(missing.contains("token=secret"))

        let disabled = await controller.execute(
            toolName: "wm_open",
            input: #"{"site_id":"github"}"#,
            isUserInitiated: true
        )
        let disabledObject = try jsonObject(disabled)
        XCTAssertEqual(disabledObject["denied"] as? Bool, true)
        XCTAssertEqual(disabledObject["site_id"] as? String, "github")
    }

    func testWebMountHighRiskAutoApproveOpensUnlistedHostAndOffRestoresAllowlist() async throws {
        let controller = makeWebMountController(globalEnabled: true)
        let executor = makeExecutor(webMountController: controller)
        let sessionId = try XCTUnwrap(controller.sessionStore.records.first?.id)
        let url = "https://unlisted.amber.invalid/path"
        let originalHosts = controller.settings.allowedHosts
        let originalSites = controller.registry.sites

        let disabledOutput = await executor.execute(IOSLocalToolExecutionRequest(
            toolName: "wm_open",
            operation: IOSWebMountController.json([
                "session_id": sessionId,
                "url": "https://github.com/"
            ]),
            scopeDigest: "",
            payloadDigest: "",
            isUserInitiated: false,
            runId: "high-risk-run",
            conversationId: "high-risk-conversation",
            executionPolicy: IOSExecutionPolicySnapshot(
                capabilityPolicies: [:],
                globalAutoApproveEnabled: false,
                highRiskAutoApproveEnabled: true,
                execJavaScriptEnabled: false,
                webSearchEnabled: false
            )
        ))
        guard case .webMountResult(let disabledText) = disabledOutput else {
            return XCTFail("Expected disabled-site WebMount result, got \(disabledOutput)")
        }
        XCTAssertEqual(try jsonObject(disabledText)["denied"] as? Bool, true)

        let output = await executor.execute(IOSLocalToolExecutionRequest(
            toolName: "wm_open",
            operation: IOSWebMountController.json(["session_id": sessionId, "url": url]),
            scopeDigest: "",
            payloadDigest: "",
            isUserInitiated: false,
            runId: "high-risk-run",
            conversationId: "high-risk-conversation",
            executionPolicy: IOSExecutionPolicySnapshot(
                capabilityPolicies: [:],
                globalAutoApproveEnabled: false,
                highRiskAutoApproveEnabled: true,
                execJavaScriptEnabled: false,
                webSearchEnabled: false
            )
        ))

        guard case .webMountResult(let text) = output else {
            return XCTFail("Expected high-risk WebMount result, got \(output)")
        }
        XCTAssertEqual(try jsonObject(text)["ok"] as? Bool, true)
        let record = try XCTUnwrap(controller.sessionStore.record(sessionId: sessionId))
        XCTAssertNil(record.siteId)
        XCTAssertEqual(controller.settings.allowedHosts, originalHosts)
        XCTAssertEqual(controller.registry.sites, originalSites, "High-risk mode must bypass, not rewrite, the allowlist")
        XCTAssertEqual(record.redactedURL, url)
        XCTAssertNotNil(WebMountSiteRoute(watching: record, registry: controller.registry))

        controller.releaseAgentOwnership(runId: "high-risk-run")
        let blockedOutput = await executor.execute(IOSLocalToolExecutionRequest(
            toolName: "wm_state",
            operation: IOSWebMountController.json(["session_id": sessionId]),
            scopeDigest: "",
            payloadDigest: "",
            isUserInitiated: false,
            runId: "off-run",
            conversationId: "high-risk-conversation",
            executionPolicy: IOSExecutionPolicySnapshot(
                capabilityPolicies: [:],
                globalAutoApproveEnabled: true,
                highRiskAutoApproveEnabled: false,
                execJavaScriptEnabled: false,
                webSearchEnabled: false
            )
        ))
        guard case .webMountResult(let blockedText) = blockedOutput else {
            return XCTFail("Expected allowlist-restored WebMount result, got \(blockedOutput)")
        }
        let blocked = try jsonObject(blockedText)
        XCTAssertEqual(blocked["denied"] as? Bool, true)
        XCTAssertEqual(blocked["error_code"] as? String, "high_risk_auto_approve_required")
    }

    func testWebMountGetDeniesHtmlAndSensitiveValueSelectors() async throws {
        let controller = makeWebMountController(globalEnabled: true)

        let html = await controller.execute(
            toolName: "wm_get",
            input: #"{"selector":"body","kind":"html"}"#,
            isUserInitiated: true
        )
        let htmlObject = try jsonObject(html)
        XCTAssertEqual(htmlObject["denied"] as? Bool, true)

        let token = await controller.execute(
            toolName: "wm_get",
            input: #"{"selector":"input[name=csrf_token]","kind":"value"}"#,
            isUserInitiated: true
        )
        let tokenObject = try jsonObject(token)
        XCTAssertEqual(tokenObject["denied"] as? Bool, true)

        let valueAttribute = await controller.execute(
            toolName: "wm_get",
            input: #"{"selector":"input","kind":"attr","attr_name":"value"}"#,
            isUserInitiated: true
        )
        let valueAttributeObject = try jsonObject(valueAttribute)
        XCTAssertEqual(valueAttributeObject["denied"] as? Bool, true)
    }

    func testWebMountContentHandoffRedactsAndBuildsChatAndBoardPayloads() throws {
        let site = try XCTUnwrap(IOSWebMountSite.seeds(nowMillis: 1).first { $0.id == "github" })
        let snapshot = IOSWebMountRuntimeSnapshot(
            sessionId: "handoff",
            status: .ready,
            requestedURL: "https://github.com/login",
            currentURL: "https://github.com/settings",
            title: "Settings",
            estimatedProgress: 1,
            canGoBack: true,
            canGoForward: false,
            error: nil,
            updatedAtMillis: 2
        )

        let handoff = try XCTUnwrap(IOSWebMountContentHandoff.from(
            site: site,
            snapshot: snapshot,
            extraction: [
                "title": "Account",
                "url": "https://github.com/settings?token=secret",
                "text": "Profile link https://github.com/settings?token=secret Authorization: Bearer abcdef123456",
                "links": [
                    ["href": "https://github.com/settings?token=secret"]
                ]
            ]
        ))

        XCTAssertFalse(handoff.text.contains("token=secret"))
        XCTAssertFalse(handoff.chatPrompt.contains("abcdef123456"))
        XCTAssertEqual(handoff.boardSignal.sourceType, IOSBoardSignalSourceType.webmount)
        XCTAssertTrue(handoff.boardSignal.metadataJson.contains(#""redacted":true"#))
    }

}
