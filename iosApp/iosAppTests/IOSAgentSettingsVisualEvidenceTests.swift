import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class IOSAgentSettingsVisualEvidenceTests: XCTestCase {
    func testMcpAndSubAgentSettingsLayout() async throws {
        let suite = "AgentSettingsVisual.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("zh-Hans", forKey: IOSAppLanguagePreference.defaultsKey)
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let config = IOSMcpConfigStore(userDefaults: defaults)
        let server = IOSMcpServerConfig.streamableHTTP(
            name: "Moli", url: "https://browser.example.com/mcp", enabled: false,
            tools: [
                IOSMcpTool(name: "browser_navigate", description: "打开指定网页。", enabled: true),
                IOSMcpTool(name: "browser_snapshot", description: "读取当前页面的语义快照，获取可交互目标。", enabled: true),
                IOSMcpTool(name: "browser_click", description: "点击页面中的目标元素。", enabled: false)
            ]
        )
        config.add(server)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer {
            previous?.makeKey()
            defaults.removePersistentDomain(forName: suite)
        }
        func capture<V: View>(_ view: V, name: String, type: DynamicTypeSize = .large) async throws {
            let window = UIWindow(windowScene: scene)
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            let size = CGSize(width: 393, height: 852)
            let host = UIHostingController(rootView: NavigationStack { view }
                .environment(RouterPath())
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .environment(\.dynamicTypeSize, type)
                .defaultAppStorage(defaults))
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            window.overrideUserInterfaceStyle = .light
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
            try XCTUnwrap(image.pngData()).write(to: output)
            print("AGENT_SETTINGS_EVIDENCE \(output.path)")
        }
        try await capture(McpServersView(sharedSettings: settings, configStore: config), name: "mcp-servers")
        try await capture(McpAddView(configStore: config, editingServer: server, initialTab: .tools), name: "mcp-server-tools")
        try await capture(SubAgentsView(sharedSettings: settings), name: "subagents-settings")
        try await capture(SubAgentRoleView(sharedSettings: settings, name: "Browser", roleId: "browser"), name: "subagent-browser-config")
        try await capture(SubAgentsView(sharedSettings: settings), name: "subagents-settings-large", type: .accessibility1)
    }
}
