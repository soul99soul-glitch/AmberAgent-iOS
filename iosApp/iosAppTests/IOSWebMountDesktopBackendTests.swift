import Foundation
import SwiftUI
import UIKit
import XCTest
import WebKit
@testable import iosApp

@MainActor
final class IOSWebMountDesktopBackendTests: IOSWebMountDesktopTestCase {
    func testDesktopFindRejectsLocatorWithoutCallingRemoteTool() async throws {
        let client = DesktopMcpClientFake(tools: desktopTools)
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "locator-session")
        let initialCalls = client.calls.count
        let cases: [[String: Any]] = [
            ["locator": ["role": "button"], "text": "Reply"],
            ["locator": ["role": "button"], "selector": "button"],
            ["locator": ["role": "button"]]
        ]
        for arguments in cases {
            let output = await adapter.execute(toolName: "wm_find", arguments: arguments, logicalSessionId: "locator-session")
            let object = try jsonObject(output)
            XCTAssertEqual(object["error_code"] as? String, "mapping_unsupported")
            XCTAssertEqual(client.calls.count, initialCalls)
        }
    }

    func testStreamableHTTPSConnectsListsToolsAndPreservesOpenProvenance() async throws {
        let client = DesktopMcpClientFake(tools: desktopTools)
        let adapter = makeAdapter(client)
        let config = makeConfig()

        try await adapter.connect(
            logicalSessionId: "desktop-session",
            backend: .playwright_mcp,
            config: config
        )

        XCTAssertEqual(config.transportKey, "streamable_http")
        XCTAssertEqual(URL(string: config.url)?.scheme, "https")
        XCTAssertEqual(client.connectedConfigs, [config])
        XCTAssertEqual(client.listToolsCallCount, 1)
        XCTAssertEqual(adapter.status(logicalSessionId: "desktop-session"), .connected)

        let output = await adapter.execute(
            toolName: "wm_open",
            arguments: ["url": "https://example.com/docs"],
            logicalSessionId: "desktop-session"
        )
        let object = try jsonObject(output)

        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["mapped_tool"] as? String, "wm_open")
        XCTAssertEqual(object["backend"] as? String, "playwright_mcp")
        XCTAssertEqual(object["mcp_server_name"] as? String, "desktop-gateway")
        XCTAssertEqual(object["session_id"] as? String, "desktop-session")
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.calls[0].name, "browser_navigate")
        XCTAssertEqual(client.calls[0].arguments["url"] as? String, "https://example.com/docs")
    }

    func testStockPlaywrightTextPageStateProvidesTrustedURLAndSemanticRefs() async throws {
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResult: stockPlaywrightPageState(url: "https://example.com/docs")
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "stock-playwright-session")

        let opened = try jsonObject(await adapter.execute(
            toolName: "wm_open",
            arguments: ["url": "https://example.com/docs"],
            logicalSessionId: "stock-playwright-session"
        ))
        XCTAssertEqual(opened["ok"] as? Bool, true)
        XCTAssertEqual(opened["current_url"] as? String, "https://example.com/docs")
        XCTAssertNotNil(opened["snapshot_id"] as? String)

        let found = try jsonObject(await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "Continue"],
            logicalSessionId: "stock-playwright-session"
        ))
        let snapshot = try XCTUnwrap(found["snapshot_id"] as? String)
        let clicked = try jsonObject(await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "e7", "snapshot_id": snapshot],
            logicalSessionId: "stock-playwright-session"
        ))
        XCTAssertEqual(clicked["ok"] as? Bool, true)
        XCTAssertNotEqual(clicked["snapshot_id"] as? String, snapshot)
        XCTAssertEqual(
            client.calls.map(\.name),
            ["browser_navigate", "browser_find", "browser_snapshot", "browser_click"]
        )
        XCTAssertEqual(client.calls.last?.arguments["target"] as? String, "e7")
        XCTAssertNil(client.calls.last?.arguments["ref"])
    }

    func testRemoteDoubleClickMapsClickCountWhenGatewayAdvertisesClickCount() async throws {
        let clickTool = IOSMcpTool(
            name: "browser_click",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"target":{"type":"string"},"click_count":{"type":"integer"}}}"#
        )
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools.filter { $0.name != "browser_click" } + [clickTool],
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://example.com/docs"),
                "browser_snapshot": stockPlaywrightPageState(url: "https://example.com/docs"),
                "browser_click": #"{"ok":true}"#
            ]
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "desktop-double-click-count")
        let opened = try jsonObject(await adapter.execute(
            toolName: "wm_open",
            arguments: ["url": "https://example.com/docs"],
            logicalSessionId: "desktop-double-click-count"
        ))
        let snapshot = try XCTUnwrap(opened["snapshot_id"] as? String)

        let clicked = try jsonObject(await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "e7", "snapshot_id": snapshot, "click_count": 2],
            logicalSessionId: "desktop-double-click-count"
        ))

        XCTAssertEqual(clicked["ok"] as? Bool, true)
        XCTAssertEqual(client.calls.last?.name, "browser_click")
        XCTAssertEqual(client.calls.last?.arguments["target"] as? String, "e7")
        XCTAssertEqual(client.calls.last?.arguments["click_count"] as? Int, 2)
    }

    func testRemoteDoubleClickMapsDoubleClickWhenGatewayAdvertisesDoubleClick() async throws {
        let clickTool = IOSMcpTool(
            name: "browser_click",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"target":{"type":"string"},"doubleClick":{"type":"boolean"}}}"#
        )
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools.filter { $0.name != "browser_click" } + [clickTool],
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://example.com/docs"),
                "browser_snapshot": stockPlaywrightPageState(url: "https://example.com/docs"),
                "browser_click": #"{"ok":true}"#
            ]
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "desktop-double-click-flag")
        let opened = try jsonObject(await adapter.execute(
            toolName: "wm_open",
            arguments: ["url": "https://example.com/docs"],
            logicalSessionId: "desktop-double-click-flag"
        ))
        let snapshot = try XCTUnwrap(opened["snapshot_id"] as? String)

        let clicked = try jsonObject(await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "e7", "snapshot_id": snapshot, "click_count": 2],
            logicalSessionId: "desktop-double-click-flag"
        ))

        XCTAssertEqual(clicked["ok"] as? Bool, true)
        XCTAssertEqual(client.calls.last?.name, "browser_click")
        XCTAssertEqual(client.calls.last?.arguments["target"] as? String, "e7")
        XCTAssertEqual(client.calls.last?.arguments["doubleClick"] as? Bool, true)
    }

    func testRemoteDoubleClickIsRejectedWithoutGatewaySupport() async throws {
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://example.com/docs"),
                "browser_snapshot": stockPlaywrightPageState(url: "https://example.com/docs")
            ]
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "desktop-double-click-unsupported")
        let opened = try jsonObject(await adapter.execute(
            toolName: "wm_open",
            arguments: ["url": "https://example.com/docs"],
            logicalSessionId: "desktop-double-click-unsupported"
        ))
        let snapshot = try XCTUnwrap(opened["snapshot_id"] as? String)

        let clicked = try jsonObject(await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "e7", "snapshot_id": snapshot, "click_count": 2],
            logicalSessionId: "desktop-double-click-unsupported"
        ))

        XCTAssertEqual(clicked["ok"] as? Bool, false)
        XCTAssertEqual(clicked["error_code"] as? String, "mapping_unsupported")
        XCTAssertFalse(client.calls.contains { $0.name == "browser_click" })
    }

    func testVersionedStructuredObserveNormalizesSemanticContract() async throws {
        let response = #"{"contract_version":"webmount.semantic.v2","document_id":"doc-1","page":{"url":"https://example.com/docs?token=secret","title":"Docs","ready_state":"complete"},"visible_text":"Welcome","interactive_elements":[{"ref":"button-1","role":"button","name":"Continue","tag":"button","visible":true}],"links":[{"href":"https://example.com/help?token=secret","text":"Help"}],"visual_candidates":[{"ref":"hero","tag":"img","alt":"Hero"}]}"#
        let client = DesktopMcpClientFake(tools: desktopTools, callResult: response)
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "structured-observe")

        let observed = try jsonObject(await adapter.execute(
            toolName: "wm_observe",
            arguments: [:],
            logicalSessionId: "structured-observe"
        ))

        XCTAssertEqual(observed["semantic_contract_version"] as? String, "webmount.semantic.v2")
        XCTAssertEqual(observed["source_contract_version"] as? String, "webmount.semantic.v2")
        XCTAssertEqual(observed["parse_quality"] as? String, "versioned_structured")
        XCTAssertEqual(observed["document_id"] as? String, "doc-1")
        XCTAssertEqual(observed["visible_text"] as? String, "Welcome")
        let page = try XCTUnwrap(observed["page"] as? [String: Any])
        XCTAssertEqual(page["url"] as? String, "https://example.com/docs")
        XCTAssertEqual(page["ready_state"] as? String, "complete")
        let elements = try XCTUnwrap(observed["interactive_elements"] as? [[String: Any]])
        XCTAssertEqual(elements.first?["ref"] as? String, "button-1")
        XCTAssertEqual(elements.first?["visible"] as? Bool, true)
        XCTAssertEqual((observed["links"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((observed["visual_candidates"] as? [[String: Any]])?.count, 1)
    }

    func testStockPlaywrightObserveExposesVisibleSemanticTargetsForGet() async throws {
        let getTool = IOSMcpTool(
            name: "browser_get",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"ref":{"type":"string"},"kind":{"type":"string"}}}"#
        )
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools + [getTool],
            callResult: stockPlaywrightPageState(url: "https://example.com/docs")
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "playwright-observe")

        let observed = try jsonObject(await adapter.execute(
            toolName: "wm_observe",
            arguments: [:],
            logicalSessionId: "playwright-observe"
        ))
        XCTAssertEqual(observed["parse_quality"] as? String, "playwright_accessibility")
        XCTAssertTrue((observed["visible_text"] as? String)?.contains("Continue") == true)
        let snapshot = try XCTUnwrap(observed["snapshot_id"] as? String)
        let elements = try XCTUnwrap(observed["interactive_elements"] as? [[String: Any]])
        XCTAssertEqual(elements.first(where: { $0["ref"] as? String == "e7" })?["visible"] as? Bool, true)

        let get = try jsonObject(await adapter.execute(
            toolName: "wm_get",
            arguments: ["target": "e7", "kind": "text", "snapshot_id": snapshot],
            logicalSessionId: "playwright-observe"
        ))
        XCTAssertEqual(get["ok"] as? Bool, true)
        XCTAssertEqual(client.calls.last?.name, "browser_get")
    }

    func testStructuredWaitRequiresExplicitMatchAndMapsBoundedTimeout() async throws {
        let waitTool = IOSMcpTool(
            name: "browser_wait_for",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"text":{"type":"string"},"timeout_ms":{"type":"integer"}}}"#
        )
        let tools = desktopTools.filter { $0.name != "browser_wait_for" } + [waitTool]
        let client = DesktopMcpClientFake(
            tools: tools,
            callResult: #"{"ok":true,"matched":false}"#
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "structured-wait")

        XCTAssertTrue(adapter.supportsVerifiedWait(
            arguments: ["condition": "text", "text": "ready", "timeout_ms": 900],
            logicalSessionId: "structured-wait"
        ))
        let waited = try jsonObject(await adapter.execute(
            toolName: "wm_wait",
            arguments: ["condition": "text", "text": "ready", "timeout_ms": 900],
            logicalSessionId: "structured-wait"
        ))
        XCTAssertEqual(waited["matched"] as? Bool, false)
        XCTAssertEqual(waited["match_explicit"] as? Bool, true)
        XCTAssertEqual(client.calls.last?.arguments["timeout_ms"] as? Int, 900)
    }

    func testRemoteWaitDefaultsToDomStableAndMapsExplicitFlag() async throws {
        let waitTool = IOSMcpTool(
            name: "browser_wait_for",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"dom_stable":{"type":"boolean"},"timeout_ms":{"type":"integer"}}}"#
        )
        let tools = desktopTools.filter { $0.name != "browser_wait_for" } + [waitTool]
        let client = DesktopMcpClientFake(
            tools: tools,
            callResult: #"{"ok":true,"matched":true}"#
        )
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "default-dom-stable-wait")

        let waited = try jsonObject(await adapter.execute(
            toolName: "wm_wait",
            arguments: [:],
            logicalSessionId: "default-dom-stable-wait"
        ))

        XCTAssertEqual(waited["matched"] as? Bool, true)
        XCTAssertEqual(waited["match_explicit"] as? Bool, true)
        XCTAssertEqual(client.calls.last?.name, "browser_wait_for")
        XCTAssertEqual(client.calls.last?.arguments["dom_stable"] as? Bool, true)
    }

    func testPlaywrightMappingsBlockRawBrowserCoordinateAndSensitiveDispatch() async throws {
        let client = DesktopMcpClientFake(tools: desktopTools)
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "mapping-session")

        let find = await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "Continue"],
            logicalSessionId: "mapping-session"
        )
        let firstSnapshot = try XCTUnwrap(try jsonObject(find)["snapshot_id"] as? String)
        XCTAssertEqual(client.calls[0].name, "browser_find")
        XCTAssertEqual(client.calls[0].arguments["text"] as? String, "Continue")

        _ = await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "wm:continue", "snapshot_id": firstSnapshot],
            logicalSessionId: "mapping-session"
        )
        XCTAssertEqual(client.calls.last?.name, "browser_click")
        XCTAssertEqual(client.calls.last?.arguments["ref"] as? String, "wm:continue")
        XCTAssertNil(client.calls.last?.arguments["target"])
        XCTAssertNil(client.calls.last?.arguments["element"])

        let secondFind = await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "Email"],
            logicalSessionId: "mapping-session"
        )
        let secondSnapshot = try XCTUnwrap(try jsonObject(secondFind)["snapshot_id"] as? String)
        _ = await adapter.execute(
            toolName: "wm_type",
            arguments: [
                "target": "wm:email",
                "text": "person@example.com",
                "snapshot_id": secondSnapshot
            ],
            logicalSessionId: "mapping-session"
        )
        XCTAssertEqual(client.calls.last?.name, "browser_type")
        XCTAssertEqual(client.calls.last?.arguments["ref"] as? String, "wm:email")
        XCTAssertNil(client.calls.last?.arguments["target"])
        XCTAssertNil(client.calls.last?.arguments["element"])
        XCTAssertEqual(client.calls.last?.arguments["text"] as? String, "person@example.com")

        let thirdFind = await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "Password"],
            logicalSessionId: "mapping-session"
        )
        let thirdSnapshot = try XCTUnwrap(try jsonObject(thirdFind)["snapshot_id"] as? String)
        let dispatchedBeforeBlockedInputs = client.calls.count

        let raw = await adapter.execute(
            toolName: "browser_click",
            arguments: ["target": "wm:button"],
            logicalSessionId: "mapping-session"
        )
        XCTAssertEqual(try jsonObject(raw)["error_code"] as? String, "unsafe_tool_blocked")

        let coordinate = await adapter.execute(
            toolName: "wm_tap",
            arguments: ["x": 10, "y": 20, "snapshot_id": thirdSnapshot],
            logicalSessionId: "mapping-session"
        )
        XCTAssertEqual(try jsonObject(coordinate)["error_code"] as? String, "mapping_unsupported")
        XCTAssertNil(try jsonObject(coordinate)["needs_user_action"])

        let sensitive = await adapter.execute(
            toolName: "wm_type",
            arguments: [
                "target": "wm:password-field",
                "text": "secret",
                "snapshot_id": thirdSnapshot
            ],
            logicalSessionId: "mapping-session"
        )
        XCTAssertEqual(try jsonObject(sensitive)["error_code"] as? String, "sensitive_field_requires_human")
        XCTAssertEqual(client.calls.count, dispatchedBeforeBlockedInputs)
    }

    func testRemoteInteractionsRequireFocusedOrCompleteSemanticTargets() async throws {
        let client = DesktopMcpClientFake(tools: desktopTools)
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "semantic-session")

        let focusedFind = await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "Focused Email"],
            logicalSessionId: "semantic-session"
        )
        let focusedSnapshot = try XCTUnwrap(try jsonObject(focusedFind)["snapshot_id"] as? String)
        let safeKeys = await adapter.execute(
            toolName: "wm_keys",
            arguments: ["key": "a", "snapshot_id": focusedSnapshot],
            logicalSessionId: "semantic-session"
        )
        XCTAssertEqual(try jsonObject(safeKeys)["ok"] as? Bool, true)
        XCTAssertEqual(client.calls.last?.name, "browser_press_key")

        let unfocusedFind = await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "Continue"],
            logicalSessionId: "semantic-session"
        )
        let unfocusedSnapshot = try XCTUnwrap(try jsonObject(unfocusedFind)["snapshot_id"] as? String)
        let callsBeforeUnfocused = client.calls.count
        let unfocusedKeys = await adapter.execute(
            toolName: "wm_keys",
            arguments: ["key": "a", "snapshot_id": unfocusedSnapshot],
            logicalSessionId: "semantic-session"
        )
        XCTAssertEqual(try jsonObject(unfocusedKeys)["status"] as? String, "requires_human")
        XCTAssertEqual(client.calls.count, callsBeforeUnfocused)

        let otpFind = await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "OTP"],
            logicalSessionId: "semantic-session"
        )
        let otpSnapshot = try XCTUnwrap(try jsonObject(otpFind)["snapshot_id"] as? String)
        let callsBeforeOTP = client.calls.count
        let otpKeys = await adapter.execute(
            toolName: "wm_keys",
            arguments: ["key": "1", "snapshot_id": otpSnapshot],
            logicalSessionId: "semantic-session"
        )
        XCTAssertEqual(try jsonObject(otpKeys)["status"] as? String, "requires_human")
        XCTAssertEqual(try jsonObject(otpKeys)["error_code"] as? String, "sensitive_field_requires_human")
        XCTAssertEqual(client.calls.count, callsBeforeOTP)

        let opaqueFind = await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "Opaque"],
            logicalSessionId: "semantic-session"
        )
        let opaqueSnapshot = try XCTUnwrap(try jsonObject(opaqueFind)["snapshot_id"] as? String)
        let callsBeforeOpaque = client.calls.count
        let opaqueClick = await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "wm:opaque", "snapshot_id": opaqueSnapshot],
            logicalSessionId: "semantic-session"
        )
        XCTAssertEqual(try jsonObject(opaqueClick)["status"] as? String, "requires_human")
        XCTAssertEqual(try jsonObject(opaqueClick)["error_code"] as? String, "sensitive_field_requires_human")
        XCTAssertEqual(client.calls.count, callsBeforeOpaque)
    }

    func testRemoteGetRequiresVisibleSemanticSnapshot() async throws {
        let getTool = IOSMcpTool(
            name: "browser_get",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"ref":{"type":"string"},"kind":{"type":"string"},"attr_name":{"type":"string"}}}"#
        )
        let client = DesktopMcpClientFake(tools: desktopTools + [getTool])
        let adapter = makeAdapter(client)
        try await connect(adapter, sessionId: "get-session")

        let visibleFind = await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "Visible"],
            logicalSessionId: "get-session"
        )
        let visibleSnapshot = try XCTUnwrap(try jsonObject(visibleFind)["snapshot_id"] as? String)
        let visibleGet = await adapter.execute(
            toolName: "wm_get",
            arguments: ["target": "wm:visible", "kind": "text", "snapshot_id": visibleSnapshot],
            logicalSessionId: "get-session"
        )
        let visibleObject = try jsonObject(visibleGet)
        XCTAssertEqual(visibleObject["ok"] as? Bool, true)
        XCTAssertEqual(visibleObject["mapped_tool"] as? String, "wm_get")
        let capabilities = try XCTUnwrap(visibleObject["capabilities"] as? [String])
        XCTAssertTrue(capabilities.allSatisfy { $0.hasPrefix("wm_") })
        let remoteToolsByAmberName = Dictionary(
            uniqueKeysWithValues: adapter.capabilities(logicalSessionId: "get-session").map {
                ($0.amberToolName, $0.remoteToolName)
            }
        )
        XCTAssertEqual(remoteToolsByAmberName, [
            "wm_back": "browser_navigate_back",
            "wm_click": "browser_click",
            "wm_extract": "browser_extract",
            "wm_find": "browser_find",
            "wm_forward": "browser_navigate_forward",
            "wm_get": "browser_get",
            "wm_keys": "browser_press_key",
            "wm_observe": "browser_snapshot",
            "wm_open": "browser_navigate",
            "wm_select": "browser_select_option",
            "wm_state": "browser_snapshot",
            "wm_tap": "browser_click",
            "wm_type": "browser_type",
            "wm_wait": "browser_wait_for"
        ])
        XCTAssertEqual(client.calls.last?.name, "browser_get")

        let hiddenFind = await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "Hidden"],
            logicalSessionId: "get-session"
        )
        let hiddenSnapshot = try XCTUnwrap(try jsonObject(hiddenFind)["snapshot_id"] as? String)
        let callsBeforeHidden = client.calls.count
        let hiddenGet = await adapter.execute(
            toolName: "wm_get",
            arguments: ["target": "wm:hidden", "kind": "value", "snapshot_id": hiddenSnapshot],
            logicalSessionId: "get-session"
        )
        let hiddenObject = try jsonObject(hiddenGet)
        XCTAssertEqual(hiddenObject["status"] as? String, "requires_human")
        XCTAssertEqual(hiddenObject["error_code"] as? String, "sensitive_field_requires_human")
        XCTAssertEqual(client.calls.count, callsBeforeHidden)

        let hiddenClick = await adapter.execute(
            toolName: "wm_click",
            arguments: ["target": "wm:hidden", "snapshot_id": hiddenSnapshot],
            logicalSessionId: "get-session"
        )
        XCTAssertEqual(try jsonObject(hiddenClick)["status"] as? String, "requires_human")
        XCTAssertEqual(client.calls.count, callsBeforeHidden)

        let attrValue = await adapter.execute(
            toolName: "wm_get",
            arguments: [
                "target": "wm:hidden",
                "kind": "attr",
                "attr_name": "value",
                "snapshot_id": hiddenSnapshot
            ],
            logicalSessionId: "get-session"
        )
        XCTAssertEqual(try jsonObject(attrValue)["error_code"] as? String, "mapping_unsupported")
        XCTAssertEqual(client.calls.count, callsBeforeHidden)
    }

}
