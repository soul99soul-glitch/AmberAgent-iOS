import XCTest
import SwiftUI
import UIKit
import Observation
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatTopBarLayoutTests: XCTestCase {
    func testIneligibleIslandTapShowsHintThenRestoresTitle() async throws {
        let original = ChatIslandPresentation.idle(.conversationTitle("两轮讨论"))
        let now = Date()
        var state = ChatTopBarArrivalState()
        _ = state.update(.init(conversationID: "hint-test", isAwaitingUser: false,
                               isGenerating: false, notices: []))
        XCTAssertEqual(state.islandPresentation(original), original)
        XCTAssertTrue(state.didTapIneligibleTitle(at: now))
        XCTAssertEqual(state.islandPresentation(original).displayedState.title, "再聊几轮就能回顾")
        state.expireRecapHint(at: now.addingTimeInterval(1.7))
        XCTAssertEqual(state.islandPresentation(original).displayedState.title, "再聊几轮就能回顾")

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.overrideUserInterfaceStyle = .light
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        let topBar = ChatTopBarView(
            presentation: original, conversationID: "hint-test", hasMessages: true,
            isGenerating: false, notices: [], shelfHeight: scene.screen.bounds.height * 0.55,
            onBack: {}, onIslandTap: { _ in }, onCancel: {}, onOpenConversation: { _ in true },
            onDismiss: { _ in }, onNewConversation: {}, loadPreview: { _ in nil },
            previewRevision: { _ in nil }, recapEligible: false, arrivalState: state
        )
        window.rootViewController = UIHostingController(rootView:
            ZStack(alignment: .top) {
                AmberTheme.background.ignoresSafeArea()
                Text("刚开始的讨论，也有回应。")
                    .foregroundStyle(AmberTheme.muted)
                    .padding(.top, ChatTopBarLayout.controlsHeight + 24)
                topBar
            }
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            .environment(\.dynamicTypeSize, .large)
        )
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "island-recap-hint"
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: "/tmp/amber-topbar", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("island-recap-hint.png"), options: .atomic)

        state.expireRecapHint(at: now.addingTimeInterval(1.8))
        XCTAssertEqual(state.islandPresentation(original), original)
        state.didTapIneligibleTitle(at: now)
        let arrivalNotice = notice("hint-notice", title: "报告", kind: .completed)
        _ = state.update(.init(conversationID: "hint-test", isAwaitingUser: false,
                               isGenerating: false, notices: [arrivalNotice]))
        XCTAssertNil(state.recapHintDeadline, "播报到达即取消提示")
        XCTAssertFalse(state.didTapIneligibleTitle(at: now), "播报期间不覆盖标题")
        _ = state.update(.init(conversationID: "hint-next", isAwaitingUser: false,
                               isGenerating: false, notices: []))
        state.didTapIneligibleTitle(at: now)
        _ = state.update(.init(conversationID: "hint-third", isAwaitingUser: false,
                               isGenerating: false, notices: []))
        XCTAssertNil(state.recapHintDeadline, "切换对话即取消提示")
    }

    func testTopBarLayoutsAndCaptureEvidence() async throws {
        let suite = "ChatTopBarLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let conversations = IOSConversationStore(baseDirectory: directory, subagentConversationIDsProvider: { [] })
        await conversations.bootstrap()
        let sourceA = try await seedConversation(
            conversations,
            title: "图片方案",
            messages: [askUserMessage(id: "question-a", question: "请确认采用哪种图片方案？")]
        )
        let createdB = await conversations.newConversation()
        XCTAssertTrue(createdB)
        let sourceB = try await seedConversation(
            conversations,
            title: "文件内容",
            messages: [askUserMessage(id: "question-b", question: "还要补充哪些内容？")]
        )
        let createdCurrent = await conversations.newConversation()
        XCTAssertTrue(createdCurrent)
        let currentConversation = try await seedConversation(
            conversations,
            title: "这是用于验证窄屏布局的较长对话标题",
            messages: [
                UIMessage.companion.user(prompt: "请把刚才的讨论整理好。"),
                UIMessage.companion.assistant(prompt: "我正在当前对话中整理这份内容。")
            ]
        )
        XCTAssertEqual(conversations.currentConversation?.id, currentConversation)

        let dao = IosDatabaseFactory.shared.createDatabase(
            atFilePath: directory.appendingPathComponent("runs.db").path
        ).agentRuntimeDao()
        let center = ConversationActivityCenter(conversationStore: conversations, dao: dao, startedAt: .distantPast)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let eventA = awaitingEvent(sourceA, runId: "layout-a", startedAt: now - 2_000, finishedAt: now)
        let eventB = awaitingEvent(sourceB, runId: "layout-b", startedAt: now - 1_000, finishedAt: now)

        let settings = SettingsStore(userDefaults: defaults)
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "顶栏截图", apiKey: "sk-topbar-fixture", baseUrl: "https://example.invalid/v1",
            modelName: "截图模型", modelId: "gpt-4o"
        )
        let addedProvider = sharedSettings.addProvider(provider)
        let model = try XCTUnwrap(addedProvider.models.first { $0.type == ModelType.chat })
        sharedSettings.setCurrentChatModelId(model.id.toHexDashString())
        let viewModel = ChatViewModel(settingsStore: settings, sharedSettings: sharedSettings)
        viewModel.conversationStore = conversations
        viewModel.reloadFromStore(reason: .conversationSwitch)
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let activityStore = IOSSubAgentActivityStore(
            tasks: tasks,
            defaults: defaults,
            launchedAt: Date(),
            loadRuns: { [] }
        )
        activityStore.autoDismissDelay = .never
        let router = RouterPath()

        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        func show<Content: View>(_ content: Content, width: CGFloat? = nil, height: CGFloat? = nil) {
            window.rootViewController?.dismiss(animated: false)
            let screenSize = scene.screen.bounds.size
            window.frame = CGRect(
                x: 0,
                y: 0,
                width: width ?? screenSize.width,
                height: height ?? screenSize.height
            )
            window.rootViewController = UIHostingController(rootView: content)
            window.makeKeyAndVisible()
        }

        func showChatView(width: CGFloat? = nil, height: CGFloat? = nil) {
            let content = NavigationStack {
                ChatView(
                    settingsStore: settings,
                    sharedSettings: sharedSettings,
                    viewModel: viewModel,
                    activityStore: activityStore
                )
            }
            .environment(center)
            .environment(conversations)
            .environment(router)
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            .environment(\.dynamicTypeSize, .large)
            show(content, width: width, height: height)
        }

        func showTopBarPreview(
            fixture: ChatTopBarLayoutFixture,
            panel: ChatTopBarPanel? = nil,
            width: CGFloat? = nil,
            height: CGFloat? = nil
        ) {
            let content = ChatTopBarLayoutPreview(
                fixture: fixture, panel: panel, shelfHeight: (height ?? scene.screen.bounds.height) * 0.55
            )
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            .environment(\.dynamicTypeSize, .large)
            show(content, width: width, height: height)
        }

        func capture(_ name: String, flashScrollIndicators: Bool = false) async {
            try? await Task.sleep(for: .milliseconds(900))
            window.layoutIfNeeded()
            if flashScrollIndicators {
                func flash(in view: UIView) {
                    (view as? UIScrollView)?.flashScrollIndicators()
                    view.subviews.forEach { flash(in: $0) }
                }
                flash(in: window)
                try? await Task.sleep(for: .milliseconds(100))
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let directory = URL(fileURLWithPath: "/tmp/amber-topbar", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("\(name).png")
            if let data = image.pngData() {
                try? data.write(to: path, options: [.atomic])
                if name == "topbar-satellite-multiple-expanded" {
                    try? data.write(to: directory.appendingPathComponent("dockpanel-notices.png"), options: [.atomic])
                }
            }
            print("CHAT_TOPBAR_EVIDENCE \(path.path)")
        }

        // 当前有消息、没有跨对话提醒时停靠位显示产物架。
        showChatView()
        await capture("topbar-shelf")

        await center.reconcile([eventA])
        XCTAssertEqual(center.notices.count, 1)
        showChatView()
        await capture("topbar-satellite-single")

        await center.reconcile([eventA, eventB])
        XCTAssertEqual(center.notices.count, 2)
        showChatView()
        await capture("topbar-satellite-multiple")

        // 空对话仍显示其它会话提醒；全部关闭后才隐藏。
        let createdEmpty = await conversations.newConversation()
        XCTAssertTrue(createdEmpty)
        let emptyConversation = try XCTUnwrap(conversations.currentConversation?.id)
        await conversations.renameConversation(id: emptyConversation, title: "空对话")
        viewModel.reloadFromStore(reason: .conversationSwitch)
        showChatView()
        await capture("topbar-empty-satellite")
        center.dismiss(conversationId: sourceA.toHexDashString())
        center.dismiss(conversationId: sourceB.toHexDashString())
        showChatView()
        await capture("topbar-empty-hidden")

        await conversations.selectConversation(id: currentConversation)
        viewModel.reloadFromStore(reason: .conversationSwitch)
        showChatView()
        await capture("topbar-shelf-current")
        showChatView(width: 375, height: 812)
        await capture("topbar-narrow375")

        let awaiting = notice("preview-awaiting", title: "图片方案", kind: .awaitingUser)
        let completed = notice("preview-completed", title: "报告整理", kind: .completed)
        let failed = notice("preview-failed", title: "文稿生成", kind: .failed)

        showTopBarPreview(fixture: ChatTopBarLayoutFixture(notices: []), panel: .shelf)
        await capture("topbar-shelf-empty-panel")

        let compactNotices = ChatTopBarLayoutFixture(notices: [awaiting, completed])
        showTopBarPreview(fixture: compactNotices, panel: .notices)
        await capture("topbar-satellite-multiple-expanded")
        XCTAssertGreaterThan(compactNotices.panelHeight, 100)
        XCTAssertLessThan(compactNotices.panelHeight, 300, "两条提醒应按内容收高")

        let manyNotices = (0...100).map { index in
            notice("badge-\(index)", title: "提醒 \(index)", kind: .completed)
        }
        showTopBarPreview(fixture: ChatTopBarLayoutFixture(notices: manyNotices), width: 375, height: 812)
        await capture("topbar-narrow375-satellite-99plus")
        let overflowingNotices = ChatTopBarLayoutFixture(notices: manyNotices)
        showTopBarPreview(fixture: overflowingNotices, panel: .notices, width: 375, height: 812)
        await capture("topbar-notices-overflow", flashScrollIndicators: true)
        XCTAssertLessThanOrEqual(overflowingNotices.panelHeight, 812 * 0.55 + 1)

        for (name, statusNotice) in [
            ("awaiting", awaiting),
            ("failed", failed),
            ("completed", completed)
        ] {
            let fixture = ChatTopBarLayoutFixture()
            showTopBarPreview(fixture: fixture, width: 375, height: 812)
            try await Task.sleep(for: .milliseconds(300))
            fixture.notices = [notice(
                "arrival-\(name)", title: "这是一条很长的跨对话任务标题，用来确认状态文字始终完整显示",
                kind: statusNotice.kind
            )]
            await capture("topbar-narrow375-arrival-\(name)")
        }

        if ProcessInfo.processInfo.environment["AMBER_TOPBAR_GESTURE_PROBE"] == "1" {
            var tapCount = 0
            var dismissCount = 0
            let probe = notice("swipe-probe", title: "上划验证任务", kind: .awaitingUser)
            let content = VStack {
                HStack {
                    Text("上划验证").font(.headline)
                    Spacer()
                    ChatTopBarTrailingDock(
                        state: .satellite(notice: probe, extraCount: 0),
                        onTap: { tapCount += 1 },
                        onDismiss: { _ in dismissCount += 1 },
                        onNewConversation: {},
                        loadPreview: { _ in "确认这条消息后继续。" }
                    )
                }
                .padding(18)
                Spacer()
            }
            .background(AmberTheme.background.ignoresSafeArea())
            show(content)
            await capture("topbar-swipe-probe")
            let deadline = Date().addingTimeInterval(30)
            while dismissCount == 0, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(dismissCount, 1)
            XCTAssertEqual(tapCount, 0, "上划关闭提醒不能同时触发 tap")
        }
    }

    private func notice(
        _ id: String,
        title: String,
        kind: ConversationActivityNotice.Kind
    ) -> ConversationActivityNotice {
        ConversationActivityNotice(
            conversationId: id,
            title: title,
            kind: kind,
            preview: "用于检查顶栏提醒预览与布局。",
            occurredAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func seedConversation(
        _ store: IOSConversationStore,
        title: String,
        messages: [UIMessage]
    ) async throws -> KotlinUuid {
        let id = try XCTUnwrap(store.currentConversation?.id)
        await store.renameConversation(id: id, title: title)
        let saved = await store.save(messages: messages, to: id)
        XCTAssertTrue(saved)
        return id
    }

    private func askUserMessage(id: String, question: String) throws -> UIMessage {
        let data = try JSONSerialization.data(withJSONObject: ["question": question])
        let input = try XCTUnwrap(String(data: data, encoding: .utf8))
        return IOSChatForegroundFixtures.assistantMessage(parts: [
            UIMessagePart.Tool(
                toolCallId: id,
                toolName: "ask_user",
                input: input,
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
        ])
    }

    private func awaitingEvent(
        _ id: KotlinUuid,
        runId: String,
        startedAt: Int64,
        finishedAt: Int64
    ) -> ConversationActivityCenter.RunEvent {
        ConversationActivityCenter.RunEvent(
            runId: runId,
            conversationId: id.toHexDashString(),
            status: "waiting_user",
            startedAt: startedAt,
            finishedAt: finishedAt,
            pendingToken: "tool_call:\(runId == "layout-a" ? "question-a" : "question-b")"
        )
    }

}

@MainActor
@Observable
private final class ChatTopBarLayoutFixture {
    @ObservationIgnored let tapRegions = ChatDockTapRegions()
    var panelHeight: CGFloat { tapRegions.panel.isNull ? 0 : tapRegions.panel.height }
    var notices: [ConversationActivityNotice]

    init(notices: [ConversationActivityNotice] = []) {
        self.notices = notices
    }
}

@MainActor
private struct ChatTopBarLayoutPreview: View {
    @Bindable var fixture: ChatTopBarLayoutFixture
    let panel: ChatTopBarPanel?
    let shelfHeight: CGFloat

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("当前对话")
                        .font(.title2.weight(.semibold))
                    Text("已经整理好讨论中的要点，接下来可以逐项确认。")
                        .font(.body)
                        .foregroundStyle(AmberTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .safeAreaBar(edge: .top, spacing: 0) {
                Color.clear
                    .frame(height: ChatTopBarLayout.controlsHeight + ChatTopBarLayout.softEdgeExtension)
                    .allowsHitTesting(false)
            }
            ChatTopBarView(
                presentation: .idle(.conversationTitle("当前对话")),
                conversationID: "topbar-layout-preview-current",
                hasMessages: true,
                isGenerating: false,
                notices: fixture.notices,
                shelfHeight: shelfHeight,
                onBack: {},
                onIslandTap: { _ in },
                onCancel: {},
                onOpenConversation: { _ in true },
                onDismiss: { id in fixture.notices.removeAll { $0.conversationId == id } },
                onNewConversation: {},
                loadPreview: { _ in nil },
                previewRevision: { _ in nil },
                tapRegions: fixture.tapRegions,
                panel: panel
            )
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
