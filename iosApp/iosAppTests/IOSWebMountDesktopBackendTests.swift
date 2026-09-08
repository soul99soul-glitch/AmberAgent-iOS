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

    private func connectedRemoteController(
        client: DesktopMcpClientFake,
        resolveHost: @escaping IOSWebMountHostResolver = { _ in ["93.184.216.34"] }
    ) async throws -> (IOSWebMountController, String) {
        let defaults = UserDefaults(suiteName: "IOSWebMountDesktopBackendTests-\(UUID().uuidString)")!
        let config = makeConfig()
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: defaults),
            settings: IOSWebMountSettings(userDefaults: defaults),
            cookieStore: DesktopTestCookieStore(),
            runtime: DesktopControllerRuntimeFake(sessionId: "local-for-remote"),
            runtimeFactory: { DesktopControllerRuntimeFake(sessionId: "unused-local") },
            desktopBackend: makeAdapter(client),
            mcpServerProvider: { [config] in [config] },
            resolveHost: resolveHost
        )
        controller.registry.setEnabled(id: "hackernews", enabled: true)
        let created = try jsonObject(await controller.execute(
            toolName: "wm_tab_new",
            input: #"{"backend":"playwright_mcp","mcp_server_name":"desktop-gateway","site_id":"hackernews"}"#,
            isUserInitiated: true
        ))
        let sessionId = try XCTUnwrap(created["session_id"] as? String)
        let opened = try jsonObject(await controller.execute(
            toolName: "wm_open",
            input: IOSWebMountController.json(["session_id": sessionId]),
            isUserInitiated: true
        ))
        XCTAssertEqual(opened["ok"] as? Bool, true)
        return (controller, sessionId)
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

private final class DesktopHostResolverGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let blockOnCall: Int
    private var callCount = 0
    private var started = false
    private var blocked = false

    init(blockOnCall: Int = 1) {
        self.blockOnCall = blockOnCall
    }

    var hasStarted: Bool {
        lock.withLock { started }
    }

    var hasBlocked: Bool {
        lock.withLock { blocked }
    }

    func resolve(_ host: String) throws -> [String] {
        let blocks = lock.withLock { () -> Bool in
            started = true
            callCount += 1
            if callCount == blockOnCall {
                blocked = true
                return true
            }
            return false
        }
        if blocks { semaphore.wait() }
        return ["93.184.216.34"]
    }

    func resume() {
        semaphore.signal()
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
    var callResultsByTool: [String: String]
    var callResultQueuesByTool: [String: [String]]
    var suspendedToolName: String?
    private(set) var connectedConfigs: [IOSMcpServerConfig] = []
    private(set) var listToolsCallCount = 0
    private(set) var calls: [Call] = []
    private(set) var disconnectCallCount = 0
    private(set) var callContinuation: CheckedContinuation<Void, Never>?
    private var lastSemanticResult: String?

    init(
        tools: [IOSMcpTool],
        callError: Error? = nil,
        callResult: String? = nil,
        callResultsByTool: [String: String] = [:],
        callResultQueuesByTool: [String: [String]] = [:]
    ) {
        self.tools = tools
        self.callError = callError
        self.callResult = callResult
        self.callResultsByTool = callResultsByTool
        self.callResultQueuesByTool = callResultQueuesByTool
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
        if suspendedToolName == name {
            await withCheckedContinuation { continuation in
                callContinuation = continuation
            }
        }
        if let callError { throw callError }
        if var queue = callResultQueuesByTool[name], !queue.isEmpty {
            let next = queue.removeFirst()
            callResultQueuesByTool[name] = queue
            return next
        }
        if let result = callResultsByTool[name] { return result }
        if let callResult { return callResult }
        if name == "browser_snapshot", let lastSemanticResult {
            return lastSemanticResult
        }
        if name == "browser_find", let text = arguments["text"] as? String {
            let node: [String: Any]
            switch text {
            case "Email":
                node = [
                    "ref": "wm:email",
                    "role": "textbox",
                    "name": "Email",
                    "input_type": "email",
                    "tag": "input",
                    "visible": true
                ]
            case "Focused Email":
                node = [
                    "ref": "wm:focused-email",
                    "role": "textbox",
                    "name": "Email",
                    "input_type": "email",
                    "tag": "input",
                    "visible": true,
                    "focused": true
                ]
            case "Password":
                node = [
                    "ref": "wm:password-field",
                    "role": "textbox",
                    "name": "Password",
                    "input_type": "password",
                    "tag": "input",
                    "visible": true
                ]
            case "OTP":
                node = [
                    "ref": "wm:otp",
                    "role": "textbox",
                    "name": "otp",
                    "input_type": "text",
                    "tag": "input",
                    "visible": true,
                    "focused": true
                ]
            case "Continue":
                node = ["ref": "wm:continue", "role": "button", "name": "Continue", "tag": "button", "visible": true]
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
                node = ["ref": "wm:button", "role": "button", "name": text, "tag": "button", "visible": true]
            }
            let object: [String: Any] = [
                "ok": true,
                "contract_version": "webmount.semantic.v2",
                "document_id": "fake-document",
                "matches": [node]
            ]
            let data = try XCTUnwrap(JSONSerialization.data(withJSONObject: object, options: []))
            let result = try XCTUnwrap(String(data: data, encoding: .utf8))
            lastSemanticResult = result
            return result
        }
        return #"{"ok":true,"page":"desktop"}"#
    }

    func resumeCall() {
        callContinuation?.resume()
        callContinuation = nil
        suspendedToolName = nil
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
