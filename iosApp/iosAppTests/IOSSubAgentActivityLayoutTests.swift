import XCTest
import SwiftUI
@preconcurrency import Shared
@testable import iosApp

/// Simulator evidence uses the production ChatView and native task store. All
/// seeded records live in a temporary suite; no provider or remote tool runs.
@MainActor
final class IOSSubAgentActivityLayoutTests: XCTestCase {
    func testExpandedTenAgentsFitContentAndRespectAvailableSpace() async throws {
        let suite = "SubAgentExpandedLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let activity = IOSSubAgentActivityStore(tasks: tasks, defaults: defaults, loadRuns: { [] })
        activity.autoDismissDelay = .never
        for name in ["lina", "alice", "anna", "miko", "chloe", "claire", "daniel", "david", "ella", "tess"] {
            tasks.startTask(kind: .subAgent, title: name, objective: "layout fixture", metadata: ["role_name": name])
        }
        await activity.refresh()
        XCTAssertEqual(activity.items.count, 10)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        func scrollViews(in view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        for (width, height, type, name) in [
            (CGFloat(393), CGFloat(852), DynamicTypeSize.large, "ten-agents-expanded"),
            (320, 568, .large, "ten-agents-expanded-small"),
            (320, 568, .accessibility3, "ten-agents-expanded-accessibility")
        ] {
            let content = AmberTheme.background
                .safeAreaBar(edge: .top, spacing: 0) {
                    Text("对话").frame(height: ChatTopBarLayout.controlsHeight + ChatTopBarLayout.softEdgeExtension)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        ChatSubAgentActivityBar(currentConversationId: nil, isInputFocused: false,
                            activityStore: activity, initiallyExpanded: true, onOpenSource: { _ in false })
                        Text("发消息给 Amber…")
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .background(AmberTheme.surface, in: Capsule())
                    }
                }
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .environment(\.dynamicTypeSize, type)
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            window.rootViewController = UIHostingController(rootView: content)
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(650))
            window.layoutIfNeeded()
            let scroll = try XCTUnwrap(scrollViews(in: window).first)
            XCTAssertGreaterThan(scroll.contentSize.height, 250, name)
            if !type.isAccessibilitySize {
                XCTAssertEqual(scroll.bounds.height, scroll.contentSize.height, accuracy: 1,
                    "\(name): 展开后应一次显示全部十张卡片")
            } else {
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height,
                    "辅助功能大字超出可用空间时仍能滚动查看全部任务")
            }
            // A tall ScrollView can extend under system chrome; UIKit keeps
            // its readable content below that chrome with adjusted insets.
            let viewport = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: window)
            XCTAssertGreaterThanOrEqual(viewport.minY,
                window.safeAreaInsets.top + ChatTopBarLayout.controlsHeight + ChatTopBarLayout.softEdgeExtension - 1, name)
            XCTAssertLessThanOrEqual(viewport.maxY, height - window.safeAreaInsets.bottom - 64 + 1, name)
            print("SUBAGENT_ACTIVITY_LAYOUT \(name) content=\(scroll.contentSize.height) viewport=\(viewport)")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
            try XCTUnwrap(image.pngData()).write(to: path)
            print("SUBAGENT_ACTIVITY_EVIDENCE \(path.path)")
        }
    }

    func testNativeSubAgentAvatarGallery() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        let names = ChatSubAgentPixelSpriteLibrary.spriteNames
        let content = ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 18) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    VStack(spacing: 8) {
                        ZStack {
                            ForEach(ChatSubAgentPixelSpriteLibrary.layers(
                                forSprite: index,
                                identity: "gallery:\(index)"
                            )) { layer in
                                HomePixelSitShape(bits: layer.bits)
                                    .fill(layer.color)
                            }
                        }
                        .frame(width: 52, height: 52)
                        .background(AmberTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(1)
                    }
                }
            }
            .padding(24)
        }
        .background(AmberTheme.background.ignoresSafeArea())
        .environment(\.locale, Locale(identifier: "zh_Hans"))
        .environment(\.dynamicTypeSize, .large)

        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "subagent-avatar-gallery-24"
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-avatar-gallery-24.png")
        try XCTUnwrap(image.pngData()).write(to: path)
        print("SUBAGENT_AVATAR_GALLERY_EVIDENCE \(path.path)")
    }

    func testNativeChatLayouts() async throws {
        let suite = "SubAgentLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let conversations = IOSConversationStore(baseDirectory: directory, subagentConversationIDsProvider: { [] })
        await conversations.bootstrap()
        let activityCenter = ConversationActivityCenter(
            conversationStore: conversations,
            dao: IosDatabaseFactory.shared.createDatabase(
                atFilePath: directory.appendingPathComponent("runs.db").path
            ).agentRuntimeDao()
        )
        let sourceA = try XCTUnwrap(conversations.currentConversation?.id)
        await conversations.renameConversation(id: sourceA, title: "接口核查 · 来源会话")
        await conversations.saveCurrent(messages: [UIMessage.companion.user(prompt: "请核对接口，并整理结果。")])
        _ = await conversations.newConversation()
        let sourceB = try XCTUnwrap(conversations.currentConversation?.id)
        await conversations.renameConversation(id: sourceB, title: "继续讨论界面")
        await conversations.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "切换会话后，我还想看到刚才的子代理。"),
            UIMessage.companion.assistant(prompt: Array(repeating:
                "任务仍由原来的会话持有。你可以在输入区上方查看状态，再打开来源会话。", count: 8).joined(separator: "\n\n"))
        ])

        let settings = SettingsStore(userDefaults: defaults)
        let shared = IOSSharedSettingsStore(userDefaults: defaults)
        let vm = ChatViewModel(settingsStore: settings, sharedSettings: shared)
        vm.conversationStore = conversations
        vm.reloadFromStore(reason: .conversationSwitch)
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let activity = IOSSubAgentActivityStore(tasks: tasks, defaults: defaults, launchedAt: Date(), loadRuns: { [] })
        activity.autoDismissDelay = .never
        let router = RouterPath()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        let first = tasks.startTask(kind: .subAgent, title: "接口核查", objective: "fixture private body",
            metadata: ["role_name": "接口核查", "source_conversation_id": sourceA.toHexDashString()])
        await activity.refresh()
        XCTAssertEqual(activity.items.count, 1)

        func show(width: CGFloat, type: DynamicTypeSize, height: CGFloat = 852, detail: IOSSubAgentActivity? = nil) {
            let content = NavigationStack {
                ChatView(settingsStore: settings, sharedSettings: shared, viewModel: vm, activityStore: activity)
            }
            .environment(activityCenter)
            .environment(conversations)
            .environment(router)
            .sheet(item: .constant(detail)) { selected in
                ChatSubAgentActivityDetailSheet(activity: selected, activityStore: activity, onOpenSource: { _ in false })
                    .environment(\.dynamicTypeSize, type)
                    .environment(\.locale, Locale(identifier: "zh_Hans"))
                    .presentationDetents([.large])
            }
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            .environment(\.dynamicTypeSize, type)
            window.rootViewController?.dismiss(animated: false)
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            window.rootViewController = UIHostingController(rootView: content)
            window.makeKeyAndVisible()
        }

        func capture(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(650))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
            try XCTUnwrap(image.pngData()).write(to: path)
            print("SUBAGENT_ACTIVITY_EVIDENCE \(path.path)")
        }

        show(width: 393, type: .large)
        try await capture("subagent-activity-single")
        activity.isEnabled = false
        try await capture("subagent-activity-disabled")
        XCTAssertEqual(activity.items.count, 1, "关闭显示仍保留真实任务")
        activity.isEnabled = true
        let names = ["检查存储生命周期和错误回传的长任务名称", "阅读文档", "复核权限", "整理结论", "检查取消", "核对超时", "恢复运行", "极短任务"]
        let states: [IOSAdvancedTaskStatus] = [.running, .queued, .approvalRequired, .completed, .cancelled, .timedOut, .interrupted, .failed]
        for (index, name) in names.enumerated() {
            let task = tasks.startTask(kind: .subAgent, title: name, objective: "fixture body must stay private",
                metadata: ["role_name": name, "source_conversation_id": index == 7 ? UUID().uuidString : sourceA.toHexDashString()])
            var metadata: [String: String] = [:]
            if index == 3 || index == 7 {
                let output = IOSSubAgentOutputSnapshot(
                    summary: index == 3
                        ? "已核对任务存储与会话切换路径。子代理结果回到各自来源会话；新一轮执行使用独立身份，上一轮的收起状态不会隐藏续跑任务。"
                        : "已完成接口字段核对。读取来源会话时发现该会话已不存在，因此停止后续检查，没有创建新会话或覆盖原有记录。",
                    steps: [
                        IOSSubAgentOutputStep(id: "fixture-read", title: "读取任务记录", detail: "核对来源会话与执行身份字段", status: .completed),
                        IOSSubAgentOutputStep(id: "fixture-check", title: "检查会话切换", detail: index == 3 ? "切换会话后任务仍然可见" : "来源会话已不存在", status: index == 3 ? .completed : .failed)
                    ],
                    isFinal: true
                )
                metadata["public_output"] = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
            }
            tasks.updateTask(id: task.id, status: states[index], metadata: metadata)
        }
        await activity.refresh()
        XCTAssertEqual(activity.items.count, 9)
        show(width: 320, type: .large)
        try await capture("subagent-activity-narrow")
        show(width: 393, type: .accessibility3)
        try await capture("subagent-activity-dynamic-type")
        show(width: scene.screen.bounds.width, type: .large, height: scene.screen.bounds.height)
        try await capture("subagent-activity-multiple")
        vm.chatSuggestions = ["直接打开原文逐条核实，出已确认版简报", "继续查看子代理结果"]
        try await capture("subagent-activity-with-suggestions")
        show(width: 320, type: .large)
        try await Task.sleep(for: .milliseconds(650))
        vm.chatSuggestions = ["直接打开原文逐条核实，出已确认版简报", "继续查看子代理结果"]
        try await capture("subagent-activity-with-suggestions-narrow")
        vm.chatSuggestions = []
        let completed = try XCTUnwrap(activity.items.first { $0.title == "整理结论" })
        show(width: scene.screen.bounds.width, type: .large, height: scene.screen.bounds.height, detail: completed)
        try await Task.sleep(for: .milliseconds(500))
        try await capture("subagent-output-detail")
        show(width: 320, type: .large, detail: completed)
        try await capture("subagent-output-detail-narrow")
        let compactTerminal = try XCTUnwrap(activity.items.first { $0.title == "检查取消" })
        show(width: 393, type: .accessibility3, detail: compactTerminal)
        try await capture("subagent-output-detail-dynamic-type")
        show(width: 320, type: .accessibility3, detail: completed)
        try await capture("subagent-output-short-summary-large-type")
        show(width: scene.screen.bounds.width, type: .large, height: scene.screen.bounds.height)

        // Opt-in live inspection of these same production views. The marker
        // is only consumed by the test bundle, never by the shipping app.
        if ProcessInfo.processInfo.environment["AMBER_CAPSULE_UI_HOLD"] == "1" {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-ui-finish")
            let keyboard = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-ui-keyboard")
            let hideKeyboard = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-ui-hide-keyboard")
            func editableTextView(in view: UIView) -> UITextView? {
                if let textView = view as? UITextView, textView.isEditable { return textView }
                return view.subviews.lazy.compactMap { editableTextView(in: $0) }.first
            }
            defer {
                try? FileManager.default.removeItem(at: keyboard)
                try? FileManager.default.removeItem(at: hideKeyboard)
            }
            try? FileManager.default.removeItem(at: marker)
            print("SUBAGENT_ACTIVITY_INTERACTIVE \(marker.path)")
            for _ in 0..<180 {
                if FileManager.default.fileExists(atPath: marker.path) { break }
                if FileManager.default.fileExists(atPath: keyboard.path) {
                    try FileManager.default.removeItem(at: keyboard)
                    XCTAssertTrue(try XCTUnwrap(editableTextView(in: window)).becomeFirstResponder())
                }
                if FileManager.default.fileExists(atPath: hideKeyboard.path) {
                    try FileManager.default.removeItem(at: hideKeyboard)
                    window.endEditing(true)
                }
                try await Task.sleep(for: .seconds(5))
            }
            try? FileManager.default.removeItem(at: marker)
        }
        activity.isEnabled = true
        // Selecting a different source does not change the app-owned list.
        let visibleCount = activity.items.count
        _ = await conversations.selectConversationIfAvailable(id: sourceA)
        await activity.refresh()
        XCTAssertEqual(activity.items.count, visibleCount)
        activity.dismissAllFinished()
        XCTAssertFalse(activity.items.contains(where: \.canDismiss))
        XCTAssertEqual(activity.items.count, 4)
        try await capture("subagent-activity-bulk-dismissed")
        tasks.updateTask(id: first.id, status: .completed)
        await activity.refresh()
        for task in tasks.tasks where !task.status.isTerminal {
            tasks.updateTask(id: task.id, status: .completed)
        }
        await activity.refresh()
        activity.dismissAllFinished()
        XCTAssertTrue(activity.items.isEmpty)
        try await capture("subagent-activity-empty")

        activity.autoDismissDelay = .after30Seconds
        for (width, type, name) in [
            (CGFloat(393), DynamicTypeSize.large, "subagent-activity-settings"),
            (CGFloat(320), DynamicTypeSize.accessibility3, "subagent-activity-settings-accessibility")
        ] {
            let content = NavigationStack {
                ScrollViewReader { proxy in
                    SubAgentsView(sharedSettings: shared, activityStore: activity)
                        .task {
                            if type.isAccessibilitySize {
                                try? await Task.sleep(for: .milliseconds(100))
                                proxy.scrollTo("subagents.activity", anchor: .top)
                            }
                        }
                }
            }
            .environment(router)
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            .environment(\.dynamicTypeSize, type)
            window.rootViewController?.dismiss(animated: false)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 852)
            window.rootViewController = UIHostingController(rootView: content)
            window.makeKeyAndVisible()
            try await capture(name)
            if ProcessInfo.processInfo.environment["AMBER_CAPSULE_SETTINGS_UI_HOLD"] == "1" {
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-finish")
                try? FileManager.default.removeItem(at: marker)
                print("SUBAGENT_SETTINGS_INTERACTIVE \(marker.path)")
                for _ in 0..<180 {
                    if FileManager.default.fileExists(atPath: marker.path) { break }
                    try await Task.sleep(for: .seconds(1))
                }
                try? FileManager.default.removeItem(at: marker)
                try await capture("\(name)-inspected")
            }
        }

        defaults.set(1.15, forKey: IOSDisplayPreferenceKeys.fontScale)
        let fontSettings = NavigationStack {
            DisplayFontSettingsView(sharedSettings: shared)
        }
        .defaultAppStorage(defaults)
        .environment(\.locale, Locale(identifier: "zh_Hans"))
        .environment(\.dynamicTypeSize, .large)
        window.rootViewController?.dismiss(animated: false)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 852)
        window.rootViewController = UIHostingController(rootView: fontSettings)
        window.makeKeyAndVisible()
        try await capture("display-font-reset-narrow")
    }
}
