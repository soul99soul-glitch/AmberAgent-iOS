import Foundation
import SwiftUI
import UIKit
import XCTest
import WebKit
@testable import iosApp

@MainActor
class IOSWebMountDesktopTestCase: XCTestCase {
    let desktopTools = [
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
    let stockPlaywrightTools = [
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

    func connectedRemoteController(
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

    func makeConfig(
        name: String = "desktop-gateway",
        tools: [IOSMcpTool] = []
    ) -> IOSMcpServerConfig {
        .streamableHTTP(
            name: name,
            url: "https://desktop.example/mcp",
            tools: tools
        )
    }

    func stockPlaywrightPageState(url: String) -> String {
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

    func makeAdapter(_ client: DesktopMcpClientFake) -> IOSWebMountDesktopBackendAdapter {
        IOSWebMountDesktopBackendAdapter(clientFactory: { client })
    }

    func connect(
        _ adapter: IOSWebMountDesktopBackendAdapter,
        sessionId: String
    ) async throws {
        try await adapter.connect(
            logicalSessionId: sessionId,
            backend: .playwright_mcp,
            config: makeConfig()
        )
    }

    func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
