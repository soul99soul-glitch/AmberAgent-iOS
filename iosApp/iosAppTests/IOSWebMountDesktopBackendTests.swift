import Foundation
import XCTest
import WebKit
@testable import iosApp

@MainActor
final class IOSWebMountDesktopBackendTests: XCTestCase {
    private let desktopTools = [
        IOSMcpTool(name: "browser_navigate", description: nil),
        IOSMcpTool(name: "browser_navigate_back", description: nil),
        IOSMcpTool(name: "browser_snapshot", description: nil),
        IOSMcpTool(
            name: "browser_find",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"text":{"type":"string"},"regex":{"type":"string"}}}"#
        ),
        IOSMcpTool(
            name: "browser_click",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"ref":{"type":"string"},"element":{"type":"string"}}}"#
        ),
        IOSMcpTool(
            name: "browser_type",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"ref":{"type":"string"},"element":{"type":"string"},"text":{"type":"string"},"submit":{"type":"boolean"},"slowly":{"type":"boolean"}}}"#
        ),
        IOSMcpTool(
            name: "browser_press_key",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"key":{"type":"string"}}}"#
        ),
        IOSMcpTool(
            name: "browser_select_option",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"ref":{"type":"string"},"element":{"type":"string"},"values":{"type":"array"}}}"#
        ),
        IOSMcpTool(
            name: "browser_wait_for",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"time":{"type":"number"},"text":{"type":"string"},"textGone":{"type":"string"}}}"#
        )
    ]
    private let stockPlaywrightTools = [
        IOSMcpTool(
            name: "browser_navigate",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"url":{"type":"string"}}}"#
        ),
        IOSMcpTool(name: "browser_snapshot", description: nil),
        IOSMcpTool(
            name: "browser_find",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"text":{"type":"string"},"regex":{"type":"string"}}}"#
        ),
        IOSMcpTool(
            name: "browser_click",
            description: nil,
            inputSchema: #"{"type":"object","properties":{"element":{"type":"string"},"target":{"type":"string"}}}"#
        )
    ]

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
        XCTAssertEqual(client.calls.map(\.name), ["browser_navigate", "browser_find", "browser_click"])
        XCTAssertEqual(client.calls.last?.arguments["target"] as? String, "e7")
        XCTAssertNil(client.calls.last?.arguments["ref"])
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
        XCTAssertEqual(client.calls[1].name, "browser_click")
        XCTAssertEqual(client.calls[1].arguments["ref"] as? String, "wm:continue")
        XCTAssertNil(client.calls[1].arguments["target"])
        XCTAssertNil(client.calls[1].arguments["element"])

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
        XCTAssertEqual(client.calls[3].name, "browser_type")
        XCTAssertEqual(client.calls[3].arguments["ref"] as? String, "wm:email")
        XCTAssertNil(client.calls[3].arguments["target"])
        XCTAssertNil(client.calls[3].arguments["element"])
        XCTAssertEqual(client.calls[3].arguments["text"] as? String, "person@example.com")

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
        XCTAssertTrue(adapter.capabilities(logicalSessionId: "get-session").allSatisfy { $0.remoteToolName.hasPrefix("wm_") })
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
        XCTAssertEqual(client.calls.count, callsBeforeApproval + 1)
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
            mcpServerProvider: { [config] in [config] }
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

    private func makeConfig(
        name: String = "desktop-gateway",
        tools: [IOSMcpTool] = []
    ) -> IOSMcpServerConfig {
        .streamableHTTP(
            name: name,
            url: "https://desktop.example/mcp",
            tools: tools
        )
    }

    private func stockPlaywrightPageState(url: String) -> String {
        """
        ### Page state
          - Page URL: https://untrusted.example/indented
        - Page URL: \(url)
        - Page Title: Example
        - Page Snapshot:
        ```yaml
        - main [ref=e2]:
          - textbox "Email" [ref=e5]
          - button "Continue" [ref=e7]
          - text: "- Page URL: https://untrusted.example/"
        ```
        """
    }

    private func makeAdapter(_ client: DesktopMcpClientFake) -> IOSWebMountDesktopBackendAdapter {
        IOSWebMountDesktopBackendAdapter(clientFactory: { client })
    }

    private func connect(
        _ adapter: IOSWebMountDesktopBackendAdapter,
        sessionId: String
    ) async throws {
        try await adapter.connect(
            logicalSessionId: sessionId,
            backend: .playwright_mcp,
            config: makeConfig()
        )
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
private final class DesktopMcpClientFake: IOSMcpClienting {
    struct Call {
        let name: String
        let arguments: [String: Any]
    }

    let tools: [IOSMcpTool]
    let callError: Error?
    let callResult: String?
    private(set) var connectedConfigs: [IOSMcpServerConfig] = []
    private(set) var listToolsCallCount = 0
    private(set) var calls: [Call] = []
    private(set) var disconnectCallCount = 0

    init(tools: [IOSMcpTool], callError: Error? = nil, callResult: String? = nil) {
        self.tools = tools
        self.callError = callError
        self.callResult = callResult
    }

    func connect(config: IOSMcpServerConfig) async throws -> Bool {
        connectedConfigs.append(config)
        return true
    }

    func listTools() async throws -> [IOSMcpTool] {
        listToolsCallCount += 1
        return tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        calls.append(Call(name: name, arguments: arguments))
        if let callError { throw callError }
        if let callResult { return callResult }
        if name == "browser_find", let text = arguments["text"] as? String {
            let node: [String: Any]
            switch text {
            case "Email":
                node = [
                    "ref": "wm:email",
                    "role": "textbox",
                    "name": "Email",
                    "input_type": "email",
                    "tag": "input"
                ]
            case "Focused Email":
                node = [
                    "ref": "wm:focused-email",
                    "role": "textbox",
                    "name": "Email",
                    "input_type": "email",
                    "tag": "input",
                    "focused": true
                ]
            case "Password":
                node = [
                    "ref": "wm:password-field",
                    "role": "textbox",
                    "name": "Password",
                    "input_type": "password",
                    "tag": "input"
                ]
            case "OTP":
                node = [
                    "ref": "wm:otp",
                    "role": "textbox",
                    "name": "otp",
                    "input_type": "text",
                    "tag": "input",
                    "focused": true
                ]
            case "Continue":
                node = ["ref": "wm:continue", "role": "button", "name": "Continue", "tag": "button"]
            case "Visible":
                node = [
                    "ref": "wm:visible",
                    "role": "button",
                    "name": "Visible",
                    "tag": "button",
                    "visible": true
                ]
            case "Hidden":
                node = [
                    "ref": "wm:hidden",
                    "role": "textbox",
                    "name": "Hidden",
                    "input_type": "text",
                    "tag": "input",
                    "visible": false
                ]
            case "Opaque":
                node = ["ref": "wm:opaque"]
            default:
                node = ["ref": "wm:button", "role": "button", "name": text, "tag": "button"]
            }
            let object: [String: Any] = ["ok": true, "matches": [node]]
            let data = try XCTUnwrap(JSONSerialization.data(withJSONObject: object, options: []))
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }
        return #"{"ok":true,"page":"desktop"}"#
    }

    func disconnect() {
        disconnectCallCount += 1
    }
}

@MainActor
private final class DesktopControllerRuntimeFake: IOSWebMountRuntimeServicing {
    var snapshot: IOSWebMountRuntimeSnapshot
    var webView: WKWebView? { nil }
    private(set) var openCallCount = 0
    private(set) var stateCallCount = 0
    private(set) var interactCallCount = 0

    init(sessionId: String) {
        snapshot = .idle(sessionId: sessionId)
    }

    func open(_ url: URL, timeoutMillis: UInt64) async -> IOSWebMountRuntimeSnapshot {
        openCallCount += 1
        return snapshot
    }

    func state() async throws -> [String: Any] {
        stateCallCount += 1
        return [:]
    }

    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any] { [:] }

    func get(
        selector: String?,
        target: String?,
        kind: String,
        attrName: String?,
        maxChars: Int
    ) async throws -> [String: Any] { [:] }

    func interact(
        method: String,
        selector: String?,
        text: String?,
        options: [String: Any]
    ) async throws -> [String: Any] {
        interactCallCount += 1
        return ["ok": true]
    }

    func screenshot() async throws -> IOSWebMountScreenshotCapture {
        IOSWebMountScreenshotCapture(data: Data(), width: 0, height: 0, format: "png")
    }

    func back() async -> IOSWebMountRuntimeSnapshot { snapshot }
    func forward() async -> IOSWebMountRuntimeSnapshot { snapshot }
}

@MainActor
private final class DesktopTestCookieStore: IOSWebMountCookieStoreProtocol {
    func summary(for site: IOSWebMountSite) async -> IOSWebMountCookieSummary {
        IOSWebMountCookieSummary(
            siteId: site.id,
            cookieCount: 0,
            cookieNames: [],
            domains: [],
            hasLoginCookie: nil,
            redacted: true
        )
    }

    func clearSession(for site: IOSWebMountSite) async -> IOSWebMountCookieClearResult {
        IOSWebMountCookieClearResult(siteId: site.id, deletedCookieCount: 0, clearedWebsiteDataRecords: 0)
    }
}
