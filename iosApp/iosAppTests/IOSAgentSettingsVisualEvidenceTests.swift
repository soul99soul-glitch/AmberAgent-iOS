import SwiftUI
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSAgentSettingsVisualEvidenceTests: XCTestCase {
    func testMcpAndSubAgentSettingsLayout() async throws {
        let suite = "AgentSettingsVisual.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let languageKey = IOSAppLanguagePreference.defaultsKey
        let previousLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("zh-Hans", forKey: languageKey)
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
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: languageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: languageKey)
            }
        }
        func capture<V: View>(
            _ view: V,
            name: String,
            type: DynamicTypeSize = .large,
            size: CGSize = CGSize(width: 393, height: 852),
            locale: Locale = Locale(identifier: "zh_Hans")
        ) async throws {
            let window = UIWindow(windowScene: scene)
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            let host = UIHostingController(rootView: NavigationStack { view }
                .environment(RouterPath())
                .environment(\.locale, locale)
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
        try await capture(SubAgentConversationView(
            conversationId: childID.toHexDashString(), sharedSettings: settings,
            workspaceStore: IOSWorkspaceStore(baseDirectory: directory)
        ).environment(store), name: "subagent-conversation-narrow-large",
            type: .accessibility3, size: CGSize(width: 320, height: 640))
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
        let compactDetailTool = UIMessagePart.Tool(
            toolCallId: "visual-subagent-detail-compact",
            toolName: "spawn_agent",
            input: #"{"task_name":"test_alpha","message":"核对公开资料并整理关键结论。\n\n- 对比不同来源的说法\n- 标注仍需确认的信息\n- 用三条要点汇总结果"}"#,
            output: [UIMessagePart.Text(text: String(decoding: result, as: UTF8.self), metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        try await capture(
            ChatToolDetailSheet(tool: compactDetailTool, onOpenSubagentConversation: { _ in }),
            name: "subagent-detail-compact", size: CGSize(width: 393, height: 650)
        )
        let longDetailTask = String(repeating: "请核对公开资料、整理关键结论并保留证据。", count: 40)
        let longDetailInputData = try JSONSerialization.data(withJSONObject: [
            "task_name": "test_alpha",
            "message": longDetailTask
        ])
        let longDetailTool = UIMessagePart.Tool(
            toolCallId: "visual-subagent-detail",
            toolName: "spawn_agent",
            input: String(decoding: longDetailInputData, as: UTF8.self),
            output: [UIMessagePart.Text(
                text: String(decoding: result, as: UTF8.self),
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        try await capture(
            ChatToolDetailSheet(tool: longDetailTool, onOpenSubagentConversation: { _ in }),
            name: "subagent-detail-393",
            size: CGSize(width: 393, height: 760)
        )
        try await capture(
            ChatToolDetailSheet(tool: longDetailTool, onOpenSubagentConversation: { _ in }),
            name: "subagent-detail-320",
            size: CGSize(width: 320, height: 760)
        )
        try await capture(
            ChatToolDetailSheet(tool: longDetailTool, onOpenSubagentConversation: { _ in }),
            name: "subagent-detail-393-accessibility",
            type: .accessibility3,
            size: CGSize(width: 393, height: 900)
        )

        let activeSubagent = UIMessagePart.Tool(
            toolCallId: "visual-subagent-explorer",
            toolName: "subagent_dispatch",
            input: #"{"role_id":"explorer","objective":"搜索公开资料并整理关键证据"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let dynamicSubagent = UIMessagePart.Tool(
            toolCallId: "visual-subagent-writer",
            toolName: "subagent_dispatch",
            input: #"{"role_id":"copy_editor","custom_role_name":"写作编辑","objective":"整理结构并润色表达"}"#,
            output: [UIMessagePart.Text(
                text: #"{"ok":true,"role_id":"copy_editor","role_name":"写作编辑","status":"completed","summary":"已完成"}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let startedSubagent = UIMessagePart.Tool(
            toolCallId: "visual-subagent-browser",
            toolName: "spawn_agent",
            input: #"{"task_name":"browser","message":"观察页面并整理关键结论"}"#,
            output: [UIMessagePart.Text(
                text: #"{"ok":true,"task_name":"browser","agent_path":"/root/browser","child_thread_id":"visual-child-1","status":"started"}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let queuedFollowup = UIMessagePart.Tool(
            toolCallId: "visual-subagent-followup",
            toolName: "followup_task",
            input: #"{"target":"/root/browser","message":"补充核对登录状态"}"#,
            output: [UIMessagePart.Text(
                text: #"{"ok":true,"target":"/root/browser","recipient_thread_id":"visual-child-1","status":"queued"}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let subagentCapsules = ChatToolTimeline(
            steps: [
                ChatToolStepModel(tool: activeSubagent),
                ChatToolStepModel(tool: dynamicSubagent),
                ChatToolStepModel(tool: startedSubagent),
                ChatToolStepModel(tool: queuedFollowup)
            ],
            onTapStep: { _ in }
        )
        .padding(.horizontal, 24)
        try await capture(
            subagentCapsules,
            name: "subagent-capsules",
            size: CGSize(width: 393, height: 320)
        )
        try await capture(
            subagentCapsules,
            name: "subagent-capsules-large",
            type: .accessibility1,
            size: CGSize(width: 393, height: 440)
        )
        try await capture(
            subagentCapsules, name: "subagent-capsules-narrow",
            size: CGSize(width: 320, height: 320)
        )
        try await capture(
            subagentCapsules, name: "subagent-capsules-largest",
            type: .accessibility5, size: CGSize(width: 320, height: 650)
        )

        UserDefaults.standard.set("en", forKey: languageKey)
        let longNameTool = UIMessagePart.Tool(
            toolCallId: "visual-long-name", toolName: "spawn_agent",
            input: #"{"task_name":"international_sources_reviewer","message":"Review public sources and verify their dates"}"#,
            output: [UIMessagePart.Text(
                text: #"{"ok":true,"task_name":"international_sources_reviewer","status":"started"}"#,
                metadata: nil
            )], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
        )
        let englishCapsules = ChatToolTimeline(
            steps: [ChatToolStepModel(tool: activeSubagent), ChatToolStepModel(tool: longNameTool)],
            onTapStep: { _ in }
        ).padding(.horizontal, 24)
        try await capture(englishCapsules, name: "subagent-capsules-english-narrow",
            size: CGSize(width: 320, height: 280), locale: Locale(identifier: "en"))
        try await capture(englishCapsules, name: "subagent-capsules-english-large",
            type: .accessibility3, size: CGSize(width: 320, height: 440),
            locale: Locale(identifier: "en"))

    }
}
