import Foundation
import SwiftUI
import UIKit
import XCTest
import WebKit
@testable import iosApp

@MainActor
final class IOSWebMountSemanticTargetTests: IOSWebMountDesktopTestCase {
    func testRemoteMutationRefreshRejectsNewlyDisabledTargetBeforeDispatch() async throws {
        let enabled = #"{"contract_version":"webmount.semantic.v2","document_id":"doc-disabled","interactive_elements":[{"ref":"continue","role":"button","name":"Continue","tag":"button","visible":true,"actionable":true,"disabled":false}]}"#
        let disabled = #"{"contract_version":"webmount.semantic.v2","document_id":"doc-disabled","interactive_elements":[{"ref":"continue","role":"button","name":"Continue","tag":"button","visible":true,"actionable":false,"disabled":true}]}"#
        let client = DesktopMcpClientFake(
            tools: desktopTools,
            callResultQueuesByTool: ["browser_snapshot": [enabled, disabled]]
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "disabled-target")

        let observed = try jsonObject(await adapter.execute(
            toolName: "wm_observe",
            arguments: [:],
            logicalSessionId: "disabled-target"
        ))
        let snapshot = try XCTUnwrap(observed["snapshot_id"] as? String)
        let clicked = try jsonObject(await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "continue", "snapshot_id": snapshot],
            logicalSessionId: "disabled-target"
        ))

        XCTAssertEqual(clicked["status"] as? String, "requires_human")
        XCTAssertEqual(clicked["handoff_reason"] as? String, "target_not_actionable")
        XCTAssertFalse(client.calls.contains { $0.name == "browser_click" })
        XCTAssertEqual(client.calls.filter { $0.name == "browser_snapshot" }.count, 2)
    }

    func testRemoteMutationRejectsSelectorSmuggledAsSemanticTarget() async throws {
        let snapshotResult = ##"{"contract_version":"webmount.semantic.v2","document_id":"doc-selector","interactive_elements":[{"ref":"e7","selector":"#submit","role":"button","name":"Continue","tag":"button","visible":true,"actionable":true}]}"##
        let client = DesktopMcpClientFake(tools: desktopTools, callResult: snapshotResult)
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "selector-provenance")

        let observed = try jsonObject(await adapter.execute(
            toolName: "wm_observe",
            arguments: [:],
            logicalSessionId: "selector-provenance"
        ))
        let snapshot = try XCTUnwrap(observed["snapshot_id"] as? String)
        let clicked = try jsonObject(await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "#submit", "snapshot_id": snapshot],
            logicalSessionId: "selector-provenance"
        ))

        XCTAssertEqual(clicked["error_code"] as? String, "stale_snapshot")
        XCTAssertFalse(client.calls.contains { $0.name == "browser_click" })
    }

    func testTargetWinsWhenSelectorIsEmptyOrEquivalentAndConflictsAreRejected() async throws {
        let targetClick = IOSMcpTool(
            name: "browser_click",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"target":{"type":"string"}}}"#
        )
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools.filter { $0.name != "browser_click" } + [targetClick],
            callResult: stockPlaywrightPageState(url: "https://example.com/docs")
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "target-selector-precedence")

        let observed = try jsonObject(await adapter.execute(
            toolName: "wm_observe",
            arguments: [:],
            logicalSessionId: "target-selector-precedence"
        ))
        let firstSnapshot = try XCTUnwrap(observed["snapshot_id"] as? String)
        let equivalent = try jsonObject(await adapter.execute(
            toolName: "wm_click",
            arguments: [
                "target": "e7",
                "selector": "e7",
                "snapshot_id": firstSnapshot
            ],
            logicalSessionId: "target-selector-precedence"
        ))
        XCTAssertEqual(equivalent["ok"] as? Bool, true)
        XCTAssertEqual(client.calls.last?.arguments["target"] as? String, "e7")
        XCTAssertNil(client.calls.last?.arguments["selector"])

        let afterEquivalent = try jsonObject(await adapter.execute(
            toolName: "wm_observe",
            arguments: [:],
            logicalSessionId: "target-selector-precedence"
        ))
        let secondSnapshot = try XCTUnwrap(afterEquivalent["snapshot_id"] as? String)
        let emptySelector = try jsonObject(await adapter.execute(
            toolName: "wm_click",
            arguments: [
                "target": "e7",
                "selector": "   ",
                "snapshot_id": secondSnapshot
            ],
            logicalSessionId: "target-selector-precedence"
        ))
        XCTAssertEqual(emptySelector["ok"] as? Bool, true)
        XCTAssertEqual(client.calls.last?.arguments["target"] as? String, "e7")
        XCTAssertNil(client.calls.last?.arguments["selector"])

        let afterEmpty = try jsonObject(await adapter.execute(
            toolName: "wm_observe",
            arguments: [:],
            logicalSessionId: "target-selector-precedence"
        ))
        let thirdSnapshot = try XCTUnwrap(afterEmpty["snapshot_id"] as? String)
        let callCountBeforeConflict = client.calls.count
        let conflict = try jsonObject(await adapter.execute(
            toolName: "wm_click",
            arguments: [
                "target": "e7",
                "selector": "#other",
                "snapshot_id": thirdSnapshot
            ],
            logicalSessionId: "target-selector-precedence"
        ))
        XCTAssertEqual(conflict["error_code"] as? String, "invalid_arguments")
        XCTAssertEqual(client.calls.count, callCountBeforeConflict)
    }

    func testSelectorOnlyGatewayIsUnavailableForAgentTargetMapping() async throws {
        let selectorClick = IOSMcpTool(
            name: "browser_click",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"selector":{"type":"string"}}}"#
        )
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools.filter { $0.name != "browser_click" } + [selectorClick],
            callResult: stockPlaywrightPageState(url: "https://example.com/docs")
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "selector-only-gateway")

        let capability = adapter.capabilities(logicalSessionId: "selector-only-gateway")
            .first(where: { $0.amberToolName == "wm_click" })
        XCTAssertEqual(capability?.available, false)

        let observed = try jsonObject(await adapter.execute(
            toolName: "wm_observe",
            arguments: [:],
            logicalSessionId: "selector-only-gateway"
        ))
        let snapshot = try XCTUnwrap(observed["snapshot_id"] as? String)
        let clicked = try jsonObject(await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "e7", "snapshot_id": snapshot],
            logicalSessionId: "selector-only-gateway"
        ))
        XCTAssertEqual(clicked["error_code"] as? String, "mapping_unsupported")
        XCTAssertFalse(client.calls.contains { $0.name == "browser_click" })
    }

    func testRemoteMutationRejectsSameRefOnDifferentDocument() async throws {
        let pageA = #"{"contract_version":"webmount.semantic.v2","document_id":"doc-a","interactive_elements":[{"ref":"e7","role":"button","name":"Continue","tag":"button","visible":true,"actionable":true}]}"#
        let pageB = #"{"contract_version":"webmount.semantic.v2","document_id":"doc-b","interactive_elements":[{"ref":"e7","role":"button","name":"Continue","tag":"button","visible":true,"actionable":true}]}"#
        let client = DesktopMcpClientFake(
            tools: desktopTools,
            callResultQueuesByTool: ["browser_snapshot": [pageA, pageB]]
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "document-identity")

        let observed = try jsonObject(await adapter.execute(
            toolName: "wm_observe",
            arguments: [:],
            logicalSessionId: "document-identity"
        ))
        let snapshot = try XCTUnwrap(observed["snapshot_id"] as? String)
        let clicked = try jsonObject(await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "e7", "snapshot_id": snapshot],
            logicalSessionId: "document-identity"
        ))

        XCTAssertEqual(clicked["error_code"] as? String, "stale_snapshot")
        XCTAssertFalse(client.calls.contains { $0.name == "browser_click" })
    }

    func testRemoteNavigationCurrentURLIsTypedAndNestedURLIsNotTrusted() async throws {
        let client = DesktopMcpClientFake(
            tools: desktopTools,
            callResult: #"{"ok":true,"current_url":"https://example.com/docs","page":{"url":"https://untrusted.example/"}}"#
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "url-session")

        let output = await adapter.execute(
            toolName: "wm_open",
            arguments: ["url": "https://example.com/docs"],
            logicalSessionId: "url-session"
        )
        let object = try jsonObject(output)
        XCTAssertEqual(object["current_url"] as? String, "https://example.com/docs")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let page = try XCTUnwrap(result["page"] as? [String: Any])
        XCTAssertNil(page["url"])
        let capabilities = try XCTUnwrap(object["capabilities"] as? [String])
        XCTAssertTrue(capabilities.allSatisfy { $0.hasPrefix("wm_") })
    }

    func testDesktopHighConsequenceRequiresSnapshotBoundApprovalBeforeDispatch() async throws {
        let client = DesktopMcpClientFake(tools: desktopTools)
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "consequence-session")

        let find = await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "Pay now"],
            logicalSessionId: "consequence-session"
        )
        let snapshot = try XCTUnwrap(try jsonObject(find)["snapshot_id"] as? String)
        let callsBeforeApproval = client.calls.count
        let input: [String: Any] = ["target": "wm:button", "snapshot_id": snapshot]

        let blocked = await adapter.execute(
            toolName: "wm_click",
            arguments: input,
            logicalSessionId: "consequence-session"
        )
        let blockedObject = try jsonObject(blocked)
        XCTAssertEqual(blockedObject["needs_user_action"] as? Bool, true)
        XCTAssertEqual(blockedObject["snapshot_id"] as? String, snapshot)
        XCTAssertEqual(client.calls.count, callsBeforeApproval)

        let approved = await adapter.execute(
            toolName: "wm_click",
            arguments: input,
            logicalSessionId: "consequence-session",
            approvedHighConsequence: true
        )
        XCTAssertEqual(try jsonObject(approved)["ok"] as? Bool, true)
        XCTAssertEqual(client.calls.count, callsBeforeApproval + 2)
        XCTAssertEqual(client.calls.last?.name, "browser_click")
    }

    func testConfiguredDisabledBrowserToolIsRejectedBeforeDispatch() async throws {
        let client = DesktopMcpClientFake(tools: desktopTools)
        let adapter = makeAdapter(client)
        let config = makeConfig(tools: [
            IOSMcpTool(name: "browser_navigate", description: nil),
            IOSMcpTool(name: "browser_snapshot", description: nil),
            IOSMcpTool(name: "browser_click", description: nil, enabled: false)
        ])
        try await adapter.connect(
            logicalSessionId: "disabled-session",
            backend: .playwright_mcp,
            config: config
        )

        let output = await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "wm:button", "snapshot_id": "remote_snapshot"],
            logicalSessionId: "disabled-session"
        )
        let object = try jsonObject(output)

        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error_code"] as? String, "desktop_gateway_tool_missing")
        XCTAssertEqual(object["may_have_applied"] as? Bool, false)
        XCTAssertTrue(client.calls.isEmpty)
    }

    func testUnsupportedMappingsDoNotReuseSnapshotOrSelectorForAnotherTool() async throws {
        let client = DesktopMcpClientFake(tools: desktopTools)
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "unsupported-session")

        let selectorFind = await adapter.execute(
            toolName: "wm_find",
            arguments: ["selector": "#email"],
            logicalSessionId: "unsupported-session"
        )
        XCTAssertEqual(try jsonObject(selectorFind)["error_code"] as? String, "mapping_unsupported")

        let get = await adapter.execute(
            toolName: "wm_get",
            arguments: ["target": "wm:email", "kind": "text"],
            logicalSessionId: "unsupported-session"
        )
        XCTAssertEqual(try jsonObject(get)["error_code"] as? String, "mapping_unsupported")

        for mode in ["readable", "interactive"] {
            let extract = await adapter.execute(
                toolName: "wm_extract",
                arguments: ["mode": mode],
                logicalSessionId: "unsupported-session"
            )
            XCTAssertEqual(try jsonObject(extract)["error_code"] as? String, "mapping_unsupported")
        }

        let wait = await adapter.execute(
            toolName: "wm_wait",
            arguments: ["condition": "selector", "selector": "#email"],
            logicalSessionId: "unsupported-session"
        )
        XCTAssertEqual(try jsonObject(wait)["error_code"] as? String, "mapping_unsupported")

        let forward = await adapter.execute(
            toolName: "wm_forward",
            arguments: [:],
            logicalSessionId: "unsupported-session"
        )
        XCTAssertEqual(try jsonObject(forward)["error_code"] as? String, "mapping_unsupported")
        XCTAssertTrue(client.calls.isEmpty)

        let capabilities = adapter.capabilities(logicalSessionId: "unsupported-session")
        XCTAssertFalse(capabilities.first(where: { $0.amberToolName == "wm_get" })?.available ?? true)
        XCTAssertFalse(capabilities.first(where: { $0.amberToolName == "wm_extract" })?.available ?? true)
        XCTAssertFalse(capabilities.first(where: { $0.amberToolName == "wm_forward" })?.available ?? true)
    }

    func testMutatingRpcAndSessionErrorsAreUnknownOnlyAfterDispatch() async throws {
        let rpcClient = DesktopMcpClientFake(
            tools: desktopTools,
            callError: IOSMcpClientError.rpcError("target rejected")
        )
        let rpcAdapter = makeAdapter(rpcClient)
        try await connect(rpcAdapter, sessionId: "rpc-session")
        let rpcOutput = try jsonObject(await rpcAdapter.execute(
            toolName: "wm_open",
            arguments: ["url": "https://example.com"],
            logicalSessionId: "rpc-session"
        ))
        XCTAssertEqual(rpcOutput["status"] as? String, "unknown_after_action")
        XCTAssertEqual(rpcOutput["error_code"] as? String, "unknown_after_action")
        XCTAssertEqual(rpcOutput["may_have_applied"] as? Bool, true)
        XCTAssertEqual(rpcClient.calls.count, 1)

        let expiredClient = DesktopMcpClientFake(
            tools: desktopTools,
            callError: IOSMcpClientError.mcpSessionExpired
        )
        let expiredAdapter = makeAdapter(expiredClient)
        try await connect(expiredAdapter, sessionId: "expired-session")
        let expiredOutput = try jsonObject(await expiredAdapter.execute(
            toolName: "wm_open",
            arguments: ["url": "https://example.com"],
            logicalSessionId: "expired-session"
        ))
        XCTAssertEqual(expiredOutput["error_code"] as? String, "mcp_session_expired")
        XCTAssertEqual(expiredOutput["status"] as? String, "failed")
        XCTAssertEqual(expiredOutput["may_have_applied"] as? Bool, false)
        XCTAssertEqual(expiredAdapter.status(logicalSessionId: "expired-session"), .needsReopen)
        XCTAssertEqual(expiredClient.calls.count, 1)

        let timeoutClient = DesktopMcpClientFake(
            tools: desktopTools,
            callError: IOSMcpClientError.requestTimedOut("transport timeout")
        )
        let timeoutAdapter = makeAdapter(timeoutClient)
        try await connect(timeoutAdapter, sessionId: "timeout-session")
        let timeoutOutput = try jsonObject(await timeoutAdapter.execute(
            toolName: "wm_open",
            arguments: ["url": "https://example.com"],
            logicalSessionId: "timeout-session"
        ))
        XCTAssertEqual(timeoutOutput["status"] as? String, "unknown_after_action")
        XCTAssertEqual(timeoutOutput["error_code"] as? String, "unknown_after_action")
        XCTAssertEqual(timeoutOutput["may_have_applied"] as? Bool, true)
        XCTAssertEqual(timeoutClient.calls.count, 1)

        let isErrorClient = DesktopMcpClientFake(
            tools: desktopTools,
            callResult: #"{"isError":true,"message":"target rejected"}"#
        )
        let isErrorAdapter = makeAdapter(isErrorClient)
        try await connect(isErrorAdapter, sessionId: "is-error-session")
        let isErrorOutput = try jsonObject(await isErrorAdapter.execute(
            toolName: "wm_open",
            arguments: ["url": "https://example.com"],
            logicalSessionId: "is-error-session"
        ))
        XCTAssertEqual(isErrorOutput["status"] as? String, "unknown_after_action")
        XCTAssertEqual(isErrorOutput["error_code"] as? String, "unknown_after_action")
        XCTAssertEqual(isErrorOutput["may_have_applied"] as? Bool, true)

        let jsonRPCErrorClient = DesktopMcpClientFake(
            tools: desktopTools,
            callResult: #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"target rejected"}}"#
        )
        let jsonRPCErrorAdapter = makeAdapter(jsonRPCErrorClient)
        try await connect(jsonRPCErrorAdapter, sessionId: "jsonrpc-error-session")
        let jsonRPCOutput = try jsonObject(await jsonRPCErrorAdapter.execute(
            toolName: "wm_open",
            arguments: ["url": "https://example.com"],
            logicalSessionId: "jsonrpc-error-session"
        ))
        XCTAssertEqual(jsonRPCOutput["status"] as? String, "unknown_after_action")
        XCTAssertEqual(jsonRPCOutput["may_have_applied"] as? Bool, true)
    }

    func testRemoteTypedUnknownMutationIsPreservedAndRequiresReopen() async throws {
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_snapshot": stockPlaywrightPageState(url: "https://news.ycombinator.com/"),
                "browser_click": #"{"ok":true,"status":"unknown_after_action","may_have_applied":true}"#
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

        XCTAssertEqual(clicked["ok"] as? Bool, false)
        XCTAssertEqual(clicked["status"] as? String, "unknown_after_action")
        XCTAssertEqual(clicked["may_have_applied"] as? Bool, true)
        XCTAssertEqual(clicked["verified"] as? Bool, false)
        XCTAssertEqual(clicked["needs_reopen"] as? Bool, true)
        XCTAssertEqual(controller.sessionStore.record(sessionId: sessionId)?.needsReopen, true)
    }

    func testRemoteMutationRejectsReusedRefWhenFreshSnapshotIdentityChanges() async throws {
        let original = stockPlaywrightPageState(url: "https://example.com/docs")
        let changed = original.replacingOccurrences(of: "button \"Continue\" [ref=e7]", with: "button \"Delete\" [ref=e7]")
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResultQueuesByTool: ["browser_snapshot": [original, changed]]
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "identity-drift-session")
        let observed = try jsonObject(await adapter.execute(
            toolName: "wm_observe",
            arguments: [:],
            logicalSessionId: "identity-drift-session"
        ))
        let snapshot = try XCTUnwrap(observed["snapshot_id"] as? String)

        let clicked = try jsonObject(await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "e7", "snapshot_id": snapshot],
            logicalSessionId: "identity-drift-session"
        ))

        XCTAssertEqual(clicked["error_code"] as? String, "stale_snapshot")
        XCTAssertEqual(clicked["may_have_applied"] as? Bool, false)
        XCTAssertFalse(client.calls.contains { $0.name == "browser_click" })
    }

    func testStaleSnapshotRejectsMutatingCallWithoutDispatch() async throws {
        let client = DesktopMcpClientFake(tools: desktopTools)
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "snapshot-session")

        let observed = await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "Continue"],
            logicalSessionId: "snapshot-session"
        )
        let currentSnapshot = try XCTUnwrap(try jsonObject(observed)["snapshot_id"] as? String)
        let stale = await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "wm:continue", "snapshot_id": "stale-(currentSnapshot)"],
            logicalSessionId: "snapshot-session"
        )
        let object = try jsonObject(stale)

        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error_code"] as? String, "stale_snapshot")
        XCTAssertEqual(object["may_have_applied"] as? Bool, false)
        XCTAssertEqual(client.calls.map(\.name), ["browser_find"])
    }

}
