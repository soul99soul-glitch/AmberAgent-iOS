import SwiftUI
import XCTest
@preconcurrency import Shared
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

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let parentID = try XCTUnwrap(store.currentConversation?.id)
        let childID = KotlinUuid.companion.random()
        store.registerSubagentConversation(id: childID)
        let saved = await store.saveForkedConversation(Conversation.companion.ofId(
            id: childID, assistantId: AssistantKt.DEFAULT_ASSISTANT_ID,
            messages: [], newConversation: false
        ))
        XCTAssertTrue(saved)
        let wroteMessages = await store.save(messages: [
                IosMailboxMessageBridge.shared.makeMessage(authorThreadId: "/root", type: "NEW_TASK", payload: "请继续检查网页，并把关键结论发回主会话。"),
                UIMessage.companion.assistant(prompt: "已收到补充上下文，正在继续整理结果。")
            ], to: childID, ifUnchangedSince: store.writeBaseline(for: childID))
        XCTAssertTrue(wroteMessages)
        try await capture(SubAgentConversationView(
            conversationId: childID.toHexDashString(), sharedSettings: settings,
            workspaceStore: IOSWorkspaceStore(baseDirectory: directory)
        ).environment(store), name: "subagent-hidden-conversation")
        try await capture(SubAgentConversationView(
            conversationId: childID.toHexDashString(), sharedSettings: settings,
            workspaceStore: IOSWorkspaceStore(baseDirectory: directory)
        ).environment(store), name: "subagent-hidden-conversation-large", type: .accessibility1)
        let viewModel = ChatViewModel(settingsStore: SettingsStore(), autoGenerateResponses: false)
        try await capture(ConversationStorageView(sharedSettings: settings)
            .environment(store).environment(viewModel), name: "subagent-storage-entry")
        XCTAssertEqual(store.currentConversation?.id, parentID)
        XCTAssertFalse(store.summaries.contains { $0.id == childID })
        let result = try JSONSerialization.data(withJSONObject: [
            "ok": true, "child_thread_id": childID.toHexDashString(),
            "agent_path": "/root/browser", "status": "started"
        ])
        let tool = UIMessagePart.Tool(
            toolCallId: UUID().uuidString, toolName: "spawn_agent", input: "{\"task_name\":\"browser\",\"message\":\"请继续检查网页，并整理关键结论。\"}",
            output: [UIMessagePart.Text(text: String(decoding: result, as: UTF8.self), metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
        )
        try await capture(ChatToolDetailSheet(tool: tool, onOpenSubagentConversation: { _ in }), name: "subagent-tool-conversation-link")
        try await capture(ChatToolDetailSheet(tool: tool, onOpenSubagentConversation: { _ in }), name: "subagent-tool-conversation-link-large", type: .accessibility1)

    }
}
