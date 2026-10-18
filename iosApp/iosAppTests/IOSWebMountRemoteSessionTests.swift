import Foundation
import SwiftUI
import UIKit
import XCTest
import WebKit
@testable import iosApp

@MainActor
final class IOSWebMountRemoteSessionTests: IOSWebMountDesktopTestCase {
    func testRemoteTabMetadataKeepsLocalCurrentAndClosingRemoteDisconnectsOnlyRemote() async throws {
        let defaults = UserDefaults(suiteName: "IOSWebMountDesktopBackendTests-(UUID().uuidString)")!
        let localRuntime = DesktopControllerRuntimeFake(sessionId: "local-current")
        let remoteClient = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResult: stockPlaywrightPageState(url: "https://news.ycombinator.com/")
        )
        let desktopBackend = makeAdapter(remoteClient)
        let config = makeConfig()
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: defaults),
            settings: IOSWebMountSettings(userDefaults: defaults),
            cookieStore: DesktopTestCookieStore(),
            runtime: localRuntime,
            runtimeFactory: { DesktopControllerRuntimeFake(sessionId: "unused-local") },
            desktopBackend: desktopBackend,
            mcpServerProvider: { [config] in [config] },
            resolveHost: { _ in ["93.184.216.34"] }
        )
        controller.registry.setEnabled(id: "hackernews", enabled: true)

        let created = try jsonObject(await controller.execute(
            toolName: "wm_tab_new",
            input: #"{"backend":"playwright_mcp","mcp_server_name":"desktop-gateway","site_id":"hackernews"}"#,
            isUserInitiated: true
        ))
        let remoteSessionId = try XCTUnwrap(created["session_id"] as? String)
        let remoteSession = try XCTUnwrap(created["session"] as? [String: Any])

        XCTAssertEqual(created["current_session_id"] as? String, "local-current")
        XCTAssertEqual(remoteSession["backend"] as? String, "playwright_mcp")
        XCTAssertEqual(remoteSession["mcp_server_name"] as? String, "desktop-gateway")
        XCTAssertEqual(remoteSession["is_current"] as? Bool, false)
        XCTAssertEqual(controller.sessionStore.currentSessionId, "local-current")
        XCTAssertEqual(controller.sessionStore.record(sessionId: remoteSessionId)?.backend, .playwright_mcp)
        XCTAssertEqual(controller.sessionStore.record(sessionId: remoteSessionId)?.mcpServerName, "desktop-gateway")

        let reconnected = try jsonObject(await controller.reconnectDesktopSession(sessionId: remoteSessionId))
        XCTAssertEqual(reconnected["ok"] as? Bool, true)
        XCTAssertEqual(reconnected["session_id"] as? String, remoteSessionId)
        XCTAssertEqual(reconnected["backend"] as? String, "playwright_mcp")
        XCTAssertTrue(controller.sessionStore.record(sessionId: remoteSessionId)?.needsReopen == true)
        XCTAssertTrue(controller.sessionStore.record(sessionId: remoteSessionId)?.redactedURL.isEmpty == true)

        let explicitOpen = try jsonObject(await controller.execute(
            toolName: "wm_open",
            input: IOSWebMountController.json(["session_id": remoteSessionId]),
            isUserInitiated: true
        ))
        XCTAssertEqual(explicitOpen["ok"] as? Bool, true)
        XCTAssertEqual(explicitOpen["session_id"] as? String, remoteSessionId)
        XCTAssertFalse(controller.sessionStore.record(sessionId: remoteSessionId)?.needsReopen == true)
        XCTAssertEqual(remoteClient.calls.count, 1)

        let unlistedURL = "https://unlisted.amber.invalid/docs"
        let highRiskOpen = try jsonObject(await controller.execute(
            toolName: "wm_open",
            input: IOSWebMountController.json([
                "session_id": remoteSessionId,
                "url": unlistedURL
            ]),
            isUserInitiated: true,
            allowUnlistedHosts: true
        ))
        XCTAssertEqual(highRiskOpen["ok"] as? Bool, true)
        XCTAssertEqual(remoteClient.calls.last?.arguments["url"] as? String, unlistedURL)

        let callsBeforeBlockedOpen = remoteClient.calls.count
        let blockedOpen = try jsonObject(await controller.execute(
            toolName: "wm_open",
            input: IOSWebMountController.json([
                "session_id": remoteSessionId,
                "url": unlistedURL
            ]),
            isUserInitiated: true
        ))
        XCTAssertEqual(blockedOpen["ok"] as? Bool, false)
        XCTAssertEqual(blockedOpen["error_code"] as? String, "host_not_allowed")
        XCTAssertEqual(remoteClient.calls.count, callsBeforeBlockedOpen)

        let closed = try jsonObject(await controller.execute(
            toolName: "wm_tab_close",
            input: IOSWebMountController.json(["session_id": remoteSessionId]),
            isUserInitiated: true
        ))

        XCTAssertEqual(closed["closed_session_id"] as? String, remoteSessionId)
        XCTAssertEqual(closed["current_session_id"] as? String, "local-current")
        XCTAssertNil(controller.sessionStore.record(sessionId: remoteSessionId))
        XCTAssertGreaterThan(remoteClient.disconnectCallCount, 0)
        XCTAssertEqual(controller.sessionStore.currentSessionId, "local-current")
        XCTAssertTrue(controller.runtime === localRuntime)
        XCTAssertEqual(localRuntime.openCallCount, 0)
        XCTAssertEqual(localRuntime.stateCallCount, 0)
        XCTAssertEqual(localRuntime.interactCallCount, 0)
    }

    func testRemoteMutationUsesBoundedPostconditionAndReturnsVerifiedReceipt() async throws {
        let waitTool = IOSMcpTool(
            name: "browser_wait_for",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"text":{"type":"string"},"timeout_ms":{"type":"integer"}}}"#
        )
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools + [waitTool],
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_snapshot": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_click": #"{"ok":true,"contract_version":"webmount.semantic.v2","current_url":"https://news.ycombinator.com/"}"#
            ],
            callResultQueuesByTool: [
                "browser_wait_for": [
                    #"{"ok":true,"matched":false}"#,
                    #"{"ok":true,"matched":true}"#
                ]
            ]
        )
        let (controller, sessionId) = try await connectedRemoteController(client: client)
        let observed = try jsonObject(await controller.execute(
            toolName: "wm_observe",
            input: IOSWebMountController.json(["session_id": sessionId]),
            isUserInitiated: true
        ))
        let snapshot = try XCTUnwrap(observed["snapshot_id"] as? String)

        let clicked = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json([
                "session_id": sessionId,
                "target": "e7",
                "snapshot_id": snapshot,
                "postcondition": [
                    "condition": "text",
                    "value": "ready",
                    "timeout_ms": 700
                ]
            ]),
            isUserInitiated: true
        ))

        XCTAssertEqual(clicked["ok"] as? Bool, true)
        XCTAssertEqual(clicked["status"] as? String, "verified")
        XCTAssertEqual(clicked["verified"] as? Bool, true)
        XCTAssertEqual(clicked["may_have_applied"] as? Bool, false)
        let receipt = try XCTUnwrap(clicked["action_receipt"] as? [String: Any])
        XCTAssertEqual(receipt["verification_source"] as? String, "postcondition")
        XCTAssertEqual((receipt["precondition"] as? [String: Any])?["matched"] as? Bool, false)
        XCTAssertEqual((receipt["postcondition"] as? [String: Any])?["matched"] as? Bool, true)
        let waitCalls = client.calls.filter { $0.name == "browser_wait_for" }
        XCTAssertEqual(waitCalls.count, 2)
        XCTAssertEqual(waitCalls.first?.arguments["timeout_ms"] as? Int, 100)
        XCTAssertEqual(waitCalls.last?.arguments["timeout_ms"] as? Int, 700)
    }

    func testRemoteMutationUsesFreshStateToProveURLWhenActionOmitsIt() async throws {
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_snapshot": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_click": #"{"ok":true}"#
            ]
        )
        let (controller, sessionId) = try await connectedRemoteController(client: client)
        let observed = try jsonObject(await controller.execute(
            toolName: "wm_observe",
            input: IOSWebMountController.json(["session_id": sessionId]),
            isUserInitiated: true
        ))
        let snapshot = try XCTUnwrap(observed["snapshot_id"] as? String)

        let clicked = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json([
                "session_id": sessionId,
                "target": "e7",
                "snapshot_id": snapshot
            ]),
            isUserInitiated: true
        ))

        XCTAssertEqual(clicked["ok"] as? Bool, true)
        XCTAssertEqual(clicked["status"] as? String, "dispatched_unverified")
        XCTAssertNotEqual(controller.sessionStore.record(sessionId: sessionId)?.needsReopen, true)
        XCTAssertEqual(client.calls.filter { $0.name == "browser_snapshot" }.count, 3)
    }

    func testRemoteMutationDoesNotDispatchWhenPreconditionProbeIsUnstructured() async throws {
        let waitTool = IOSMcpTool(
            name: "browser_wait_for",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"text":{"type":"string"},"timeout_ms":{"type":"integer"}}}"#
        )
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools + [waitTool],
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_snapshot": stockPlaywrightPageState(url: "https://news.ycombinator.com/")
            ],
            callResultQueuesByTool: [
                "browser_wait_for": [#"{"ok":true}"#]
            ]
        )
        let (controller, sessionId) = try await connectedRemoteController(client: client)
        let observed = try jsonObject(await controller.execute(
            toolName: "wm_observe",
            input: IOSWebMountController.json(["session_id": sessionId]),
            isUserInitiated: true
        ))
        let snapshot = try XCTUnwrap(observed["snapshot_id"] as? String)

        let clicked = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json([
                "session_id": sessionId,
                "target": "e7",
                "snapshot_id": snapshot,
                "postcondition": [
                    "condition": "text",
                    "value": "ready",
                    "timeout_ms": 700
                ]
            ]),
            isUserInitiated: true
        ))

        XCTAssertEqual(clicked["status"] as? String, "rejected")
        XCTAssertEqual(clicked["error_code"] as? String, "postcondition_probe_failed")
        XCTAssertEqual(clicked["may_have_applied"] as? Bool, false)
        XCTAssertFalse(client.calls.contains { $0.name == "browser_click" })
    }

    func testDesktopCreationRequestBindsEnabledAnonymousSite() async throws {
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://news.ycombinator.com/")
            ]
        )
        let (controller, _) = try await connectedRemoteController(client: client)
        let site = try XCTUnwrap(controller.registry.site(id: "hackernews"))
        XCTAssertTrue(site.enabled)
        XCTAssertEqual(site.authKind, .anonymous)

        let creationRequest = WebMountDesktopBackendsView.creationArguments(
            backend: .playwright_mcp,
            serverName: "desktop-gateway",
            siteId: site.id
        )
        let result = try jsonObject(await controller.execute(
            toolName: "wm_tab_new",
            input: IOSWebMountController.json(creationRequest),
            isUserInitiated: true
        ))

        XCTAssertEqual(result["ok"] as? Bool, true, "Creation failed: \(result)")
        let sessionId = try XCTUnwrap(result["session_id"] as? String)
        XCTAssertEqual(controller.sessionStore.record(sessionId: sessionId)?.siteId, site.id)
    }

    func testRemoteMutationDoesNotDispatchWhenUserTakesControlDuringSnapshot() async throws {
        try await assertRemoteMutationDoesNotDispatchAfterSnapshotOwnershipLoss(userTakesControl: true)
    }

    func testRemoteMutationDoesNotDispatchWhenRunReleasesOwnershipDuringSnapshot() async throws {
        try await assertRemoteMutationDoesNotDispatchAfterSnapshotOwnershipLoss(userTakesControl: false)
    }

    private func assertRemoteMutationDoesNotDispatchAfterSnapshotOwnershipLoss(
        userTakesControl: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_snapshot": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_click": #"{"ok":true,"contract_version":"webmount.semantic.v2","current_url":"https://news.ycombinator.com/"}"#
            ]
        )
        let (controller, sessionId) = try await connectedRemoteController(client: client)
        let observed = try jsonObject(await controller.execute(
            toolName: "wm_observe",
            input: IOSWebMountController.json(["session_id": sessionId]),
            isUserInitiated: true
        ))
        let snapshot = try XCTUnwrap(observed["snapshot_id"] as? String)
        client.suspendedToolName = "browser_snapshot"
        defer { client.resumeCall() }
        let context = IOSWebMountExecutionContext(
            runId: "remote-snapshot-race-run",
            conversationId: "remote-snapshot-race-conversation"
        )
        let action = Task { @MainActor in
            await controller.execute(
                toolName: "wm_click",
                input: IOSWebMountController.json([
                    "session_id": sessionId,
                    "target": "e7",
                    "snapshot_id": snapshot
                ]),
                isUserInitiated: false,
                context: context
            )
        }
        for _ in 0..<1_000 where client.callContinuation == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(client.callContinuation, "Fresh snapshot must be in flight", file: file, line: line)
        XCTAssertEqual(
            controller.sessionStore.record(sessionId: sessionId)?.controlOwner,
            .agent,
            file: file,
            line: line
        )
        if userTakesControl {
            _ = try controller.sessionStore.acquireUserControl(sessionId: sessionId)
        } else {
            controller.releaseAgentOwnership(runId: context.runId)
        }
        client.resumeCall()

        let result = try jsonObject(await action.value)
        XCTAssertFalse(client.calls.contains { $0.name == "browser_click" }, file: file, line: line)
        XCTAssertEqual(result["status"] as? String, "rejected", file: file, line: line)
        XCTAssertEqual(result["error_code"] as? String, "control_unavailable", file: file, line: line)
        XCTAssertEqual(result["may_have_applied"] as? Bool, false, file: file, line: line)
        let expectedOwner: IOSWebMountControlOwner = userTakesControl ? .user : .none
        XCTAssertEqual(
            controller.sessionStore.record(sessionId: sessionId)?.controlOwner,
            expectedOwner,
            file: file,
            line: line
        )
    }

    func testRemoteMutationBecomesUnknownWhenUserTakesControlInFlight() async throws {
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_snapshot": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_click": #"{"ok":true,"contract_version":"webmount.semantic.v2","current_url":"https://news.ycombinator.com/"}"#
            ]
        )
        let (controller, sessionId) = try await connectedRemoteController(client: client)
        let observed = try jsonObject(await controller.execute(
            toolName: "wm_observe",
            input: IOSWebMountController.json(["session_id": sessionId]),
            isUserInitiated: true
        ))
        let snapshot = try XCTUnwrap(observed["snapshot_id"] as? String)
        client.suspendedToolName = "browser_click"
        let context = IOSWebMountExecutionContext(
            runId: "remote-race-run",
            conversationId: "remote-race-conversation"
        )

        let action = Task { @MainActor in
            await controller.execute(
                toolName: "wm_click",
                input: IOSWebMountController.json([
                    "session_id": sessionId,
                    "target": "e7",
                    "snapshot_id": snapshot
                ]),
                isUserInitiated: false,
                context: context
            )
        }
        while client.callContinuation == nil { await Task.yield() }
        _ = try controller.sessionStore.acquireUserControl(sessionId: sessionId)
        client.resumeCall()

        let result = try jsonObject(await action.value)
        XCTAssertEqual(result["status"] as? String, "unknown_after_action")
        XCTAssertEqual(result["error_code"] as? String, "unknown_after_action")
        XCTAssertEqual(result["may_have_applied"] as? Bool, true)
        XCTAssertEqual(result["verified"] as? Bool, false)
        XCTAssertEqual(controller.sessionStore.record(sessionId: sessionId)?.controlOwner, .user)
    }

    func testRemoteAgentMutationRejectsRawSelectorBeforeDispatch() async throws {
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_snapshot": stockPlaywrightPageState(url: "https://news.ycombinator.com/")
            ]
        )
        let (controller, sessionId) = try await connectedRemoteController(client: client)
        let callsBeforeAction = client.calls.count
        let context = IOSWebMountExecutionContext(
            runId: "remote-selector-run",
            conversationId: "remote-selector-conversation"
        )

        let clicked = try jsonObject(await controller.execute(
            toolName: "wm_click",
            input: IOSWebMountController.json([
                "session_id": sessionId,
                "selector": "#submit",
                "snapshot_id": "forged-snapshot"
            ]),
            isUserInitiated: false,
            context: context
        ))

        XCTAssertEqual(clicked["status"] as? String, "rejected")
        XCTAssertEqual(clicked["error_code"] as? String, "semantic_target_required")
        XCTAssertEqual(clicked["may_have_applied"] as? Bool, false)
        XCTAssertEqual(client.calls.count, callsBeforeAction)
    }

    func testRemoteOpenRechecksAgentOwnershipAfterHostResolution() async throws {
        let resolverGate = DesktopHostResolverGate()
        defer { resolverGate.resume() }
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://news.ycombinator.com/")
            ]
        )
        let (controller, sessionId) = try await connectedRemoteController(
            client: client,
            resolveHost: resolverGate.resolve
        )
        let navigateCallsBeforeAction = client.calls.filter { $0.name == "browser_navigate" }.count
        let context = IOSWebMountExecutionContext(
            runId: "remote-open-race-run",
            conversationId: "remote-open-race-conversation"
        )
        let action = Task { @MainActor in
            await controller.execute(
                toolName: "wm_open",
                input: IOSWebMountController.json([
                    "session_id": sessionId,
                    "url": "https://unlisted.example/newest"
                ]),
                isUserInitiated: false,
                context: context,
                allowUnlistedHosts: true
            )
        }
        for _ in 0..<1_000 where !resolverGate.hasStarted { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(resolverGate.hasStarted)
        _ = try controller.sessionStore.acquireUserControl(sessionId: sessionId)
        resolverGate.resume()

        let result = try jsonObject(await action.value)
        XCTAssertEqual(result["status"] as? String, "rejected")
        XCTAssertEqual(result["error_code"] as? String, "control_unavailable")
        XCTAssertEqual(result["may_have_applied"] as? Bool, false)
        XCTAssertEqual(
            client.calls.filter { $0.name == "browser_navigate" }.count,
            navigateCallsBeforeAction
        )
    }

    func testRemoteMutationRechecksOwnershipAfterURLValidation() async throws {
        let resolverGate = DesktopHostResolverGate()
        defer { resolverGate.resume() }
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_snapshot": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_click": #"{"ok":true,"current_url":"https://unlisted.example/"}"#
            ]
        )
        let (controller, sessionId) = try await connectedRemoteController(
            client: client,
            resolveHost: resolverGate.resolve
        )
        let observed = try jsonObject(await controller.execute(
            toolName: "wm_observe",
            input: IOSWebMountController.json(["session_id": sessionId]),
            isUserInitiated: true
        ))
        let snapshot = try XCTUnwrap(observed["snapshot_id"] as? String)
        let context = IOSWebMountExecutionContext(
            runId: "remote-url-race-run",
            conversationId: "remote-url-race-conversation"
        )
        let action = Task { @MainActor in
            await controller.execute(
                toolName: "wm_click",
                input: IOSWebMountController.json([
                    "session_id": sessionId,
                    "target": "e7",
                    "snapshot_id": snapshot
                ]),
                isUserInitiated: false,
                context: context,
                allowUnlistedHosts: true
            )
        }
        for _ in 0..<1_000 where !resolverGate.hasBlocked { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(resolverGate.hasBlocked)
        _ = try controller.sessionStore.acquireUserControl(sessionId: sessionId)
        resolverGate.resume()

        let result = try jsonObject(await action.value)
        XCTAssertEqual(result["status"] as? String, "unknown_after_action")
        XCTAssertEqual(result["may_have_applied"] as? Bool, true)
        XCTAssertEqual(result["verified"] as? Bool, false)
        XCTAssertTrue(client.calls.contains { $0.name == "browser_click" })
    }

}
