import Darwin
import SwiftUI
import UIKit
import XCTest
@preconcurrency import Shared
@testable import iosApp

/// 2026-11-12 Swarm 性能审查可复现前后对比基准（零真实 API Key / 零真机隐私依赖）。
/// 在优化前（04402ec7）与优化后以完全相同的输入 fixture 运行，打印 `[SWARM-PERF]` 指标并校验功能无损。
@MainActor
final class AmberSwarmPerfVerificationTests: ChatNativeTimelineReplayTestCase {

    private static func threadCPUNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    // MARK: - 1. 流式 MiniApp 探测（每 delta 边界外调用 2 次）

    func testSwarmPerf_1_mightContainMiniAppStreamingScan() {
        XCTAssertTrue(IOSMiniAppChatMessageFactory.mightContainMiniApp(
            #"{"title":"Demo","description":"Card","html":"<div>ok</div>"}"#
        ))
        XCTAssertTrue(IOSMiniAppChatMessageFactory.mightContainMiniApp("Prefix\n<!DOCTYPE HTML>\n<body>hi</body>"))
        XCTAssertTrue(IOSMiniAppChatMessageFactory.mightContainMiniApp("```html\n<HTML lang=\"zh\"></html>\n```"))
        XCTAssertFalse(IOSMiniAppChatMessageFactory.mightContainMiniApp("普通中文 Markdown 回复，讨论 title 与 html 概念但不含标签"))

        let chunk = """
        ### 流式性能剖析与主线程预算
        在 120Hz ProMotion 屏幕上，单帧主线程预算约为 **8.33ms**。当长文本回复持续增长到 20KB 以上时，\
        任何落在 `ChatStreamingGraphBoundary` 外部的 $O(L)$ 全量小写拷贝或离屏元数据桥接都会线性吞噬帧预算。\n\n
        """
        var deltas: [String] = []
        var text = String(repeating: chunk, count: 8)
        for step in 0..<60 {
            text += "第 \(step) 段增量：保持视觉动画、Liquid Glass 与排版密度完全不变，仅消除冗余分配。\n"
            deltas.append(text)
        }

        // Warmup
        for sample in deltas {
            XCTAssertFalse(IOSMiniAppChatMessageFactory.mightContainMiniApp(sample))
        }

        let rounds = 10
        var falseCount = 0
        let start = Self.threadCPUNanos()
        for _ in 0..<rounds {
            for sample in deltas {
                // MessageBubbleView 在单次流式 delta 中分别于 live streaming gate 与 partAnimationKey 调用两次
                if !IOSMiniAppChatMessageFactory.mightContainMiniApp(sample) { falseCount += 1 }
                if !IOSMiniAppChatMessageFactory.mightContainMiniApp(sample) { falseCount += 1 }
            }
        }
        let elapsedNs = Self.threadCPUNanos() - start
        XCTAssertEqual(falseCount, rounds * deltas.count * 2)

        let totalMs = Double(elapsedNs) / 1_000_000.0
        let perDeltaPairUs = (Double(elapsedNs) / 1_000.0) / Double(rounds * deltas.count)
        print(String(
            format: "[SWARM-PERF] miniAppScan calls=%d maxUTF8=%d totalCpuMs=%.3f perDeltaPairUs=%.2f",
            rounds * deltas.count * 2,
            deltas.last?.utf8.count ?? 0,
            totalMs,
            perDeltaPairUs
        ))
    }

    // MARK: - 2. 分页长历史（含 KMP Tool Metadata）下的流式尾块更新

    func testSwarmPerf_2_paginatedTimelineTailStreamingWithToolHistory() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        let metaUpdates = [
            "step": "completed",
            "source": "phone_observe",
            "attempt": "1"
        ]
        var history: [UIMessage] = []
        history.reserveCapacity(180)
        for turn in 0..<90 {
            history.append(makeUserMessage("历史任务第 \(turn) 轮：检查页面状态并继续。"))
            let outputText = IosToolOutputJsonBridge.shared.mergeTextMetadata(
                part: UIMessagePart.Text(text: #"{"ok":true,"turn":\#(turn)}"#, metadata: nil),
                updates: metaUpdates
            )
            let toolPart = UIMessagePart.Tool(
                toolCallId: "hist-tool-\(turn)",
                toolName: "phone_observe",
                input: #"{"reason":"check_\#(turn)"}"#,
                output: [outputText],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
            let textPart = IosToolOutputJsonBridge.shared.mergeTextMetadata(
                part: UIMessagePart.Text(text: "已完成第 \(turn) 轮页面观测，状态正常。", metadata: nil),
                updates: metaUpdates
            )
            history.append(UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [toolPart, textPart],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: chatNowLocalDateTime(),
                modelId: nil,
                usage: nil,
                translation: nil
            ))
        }

        fixture.model.messages = history
        fixture.model.send(.initialLoad)
        pump(seconds: 1.2)

        fixture.model.messages.append(makeUserMessage("现在开始总结本轮诊断结论。"))
        fixture.model.isGenerationActive = true
        fixture.model.send(.userAppend)

        let streamID = KotlinUuid.companion.random()
        var liveText = "## 诊断总结\n\n正在流式输出当前结论："
        fixture.model.messages.append(makeAssistantMessage(id: streamID, text: liveText, finished: false))
        fixture.model.send(.streamDelta)
        pump(seconds: 0.6)
        XCTAssertTrue(pumpUntil(timeout: 3.0) { fixture.model.latestViewport.isAtBottom })

        ChatRenderProbe.enabled = true
        ChatRenderProbe.reset()
        defer {
            ChatRenderProbe.enabled = false
            ChatRenderProbe.reset()
        }

        let deltas = 40
        let start = Self.threadCPUNanos()
        for step in 0..<deltas {
            liveText += "第 \(step) 条增量保持底部跟随并验证离屏 KMP 元数据不再逐帧全量桥接。"
            fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
                id: streamID,
                text: liveText,
                finished: false
            )
            fixture.model.send(.streamDelta)
            fixture.window.layoutIfNeeded()
        }
        let elapsedNs = Self.threadCPUNanos() - start
        let totalMs = Double(elapsedNs) / 1_000_000.0
        let perDeltaMs = totalMs / Double(deltas)
        let fastpathHits = ChatRenderProbe.counts["tail-fastpath:hit"]?["all"] ?? 0
        print(String(
            format: "[SWARM-PERF] paginatedTailStream history=%d deltas=%d totalCpuMs=%.3f perDeltaMs=%.3f fastpathHits=%d",
            history.count,
            deltas,
            totalMs,
            perDeltaMs,
            fastpathHits
        ))
        XCTAssertEqual(fixture.model.messages.last?.toText(), liveText)
    }

    // MARK: - 3. 封存 Episode 后 ChatView 根视图流式隔离验证

    func testSwarmPerf_3_chatViewStreamingIsolationWithSealedEpisode() async throws {
        let suite = "SwarmPerfEpisode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let conversations = IOSConversationStore(baseDirectory: directory)
        await conversations.bootstrap()
        let convID = try XCTUnwrap(conversations.currentConversation?.id)
        let convKey = convID.toHexDashString()

        let dao = IosDatabaseFactory.shared.createDatabase(
            atFilePath: directory.appendingPathComponent("runs.db").path
        ).agentRuntimeDao()
        let center = ConversationActivityCenter(conversationStore: conversations, dao: dao, startedAt: .distantPast)
        let settings = SettingsStore(userDefaults: defaults)
        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { _ in "sk-test" },
            storeCredential: { _, _ in true },
            deleteCredential: { _ in true }
        )
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "PerfProvider",
            apiKey: "sk-test",
            baseUrl: "https://example.invalid/v1",
            modelName: "PerfModel",
            modelId: "gpt-4o"
        )
        let added = sharedSettings.addProvider(provider)
        if let model = added.models.first(where: { $0.type == ModelType.chat }) {
            sharedSettings.setCurrentChatModelId(model.id.toHexDashString())
        }

        let viewModel = ChatViewModel(
            settingsStore: settings,
            sharedSettings: sharedSettings,
            autoGenerateResponses: false
        )
        viewModel.conversationStore = conversations
        viewModel.reloadFromStore(reason: .initialLoad)

        // 先写入第一轮对话并封存一个 Episode（复现 `!episodes(for:).isEmpty` 真实路径）
        let u1 = UIMessage.companion.user(prompt: "第一阶段话题：整理昨天会议纪要")
        let a1 = UIMessage.companion.assistant(prompt: "已整理第一阶段会议纪要。")
        viewModel.messages = [u1, a1]
        _ = await conversations.saveCurrent(messages: viewModel.messages)
        await conversations.renameConversation(id: convID, title: "会议纪要与性能优化")
        XCTAssertTrue(viewModel.startNewEpisode(nowMillis: 1_700_000_100_000))
        XCTAssertEqual(ChatEpisodeStore.shared.episodes(for: convKey).count, 1)

        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let activityStore = IOSSubAgentActivityStore(tasks: tasks, defaults: defaults, launchedAt: Date(), loadRuns: { [] })
        let router = RouterPath()
        let workspaceStore = IOSWorkspaceStore(baseDirectory: directory.appendingPathComponent("ws", isDirectory: true))

        let rootView = NavigationStack {
            ChatView(
                settingsStore: settings,
                sharedSettings: sharedSettings,
                workspaceStore: workspaceStore,
                viewModel: viewModel,
                activityStore: activityStore
            )
        }
        .environment(center)
        .environment(conversations)
        .environment(router)

        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        }
        window.rootViewController = UIHostingController(rootView: rootView)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            ChatRenderProbe.enabled = false
            ChatRenderProbe.reset()
            window.isHidden = true
            window.rootViewController = nil
            ChatEpisodeStore.shared.remove(conversationIds: [convKey])
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        pump(seconds: 0.6)

        // 开启第二段话题并进入流式生成态
        let u2 = UIMessage.companion.user(prompt: "第二阶段话题：继续分析流式渲染隔离。")
        let streamID = KotlinUuid.companion.random()
        var streamText = "开始输出第二阶段分析："
        let a2 = makeAssistantMessage(id: streamID, text: streamText, finished: false)
        viewModel.messages = [u1, a1, u2, a2]
        viewModel.bumpMessageRevision(reason: .userAppend)
        pump(seconds: 0.3)
        viewModel.bumpMessageRevision(reason: .streamDelta)
        pump(seconds: 0.3)

        ChatRenderProbe.enabled = true
        ChatRenderProbe.reset()

        let deltas = 25
        let start = Self.threadCPUNanos()
        for step in 0..<deltas {
            streamText += "增量片段 \(step)：顶栏与底部胶囊不应重算。"
            viewModel.messages[viewModel.messages.count - 1] = makeAssistantMessage(
                id: streamID,
                text: streamText,
                finished: false
            )
            viewModel.bumpMessageRevision(reason: .streamDelta)
            pump(seconds: 0.02)
        }
        let elapsedNs = Self.threadCPUNanos() - start
        let cpuMs = Double(elapsedNs) / 1_000_000.0
        let chatBodies = ChatRenderProbe.counts["chat-view-body"]?["all"] ?? 0
        let topBarBodies = ChatRenderProbe.counts["top-bar-body"]?["all"] ?? 0
        let composerBodies = ChatRenderProbe.counts["composer-body"]?["all"] ?? 0
        let duetBodies = ChatRenderProbe.counts["duet-chrome-body"]?["all"] ?? 0

        print(String(
            format: "[SWARM-PERF] sealedEpisodeStream deltas=%d cpuMs=%.3f chatBodies=%d topBarBodies=%d composerBodies=%d duetBodies=%d",
            deltas,
            cpuMs,
            chatBodies,
            topBarBodies,
            composerBodies,
            duetBodies
        ))
    }

    // MARK: - 4. 3+1 底部胶囊与任务面板 120Hz 拖拽重算开销

    private final class ScrubDriver: ObservableObject {
        @Published var dragOffsetY: CGFloat = 0
    }

    private struct DuetScrubHarness: View {
        @ObservedObject var driver: ScrubDriver
        let gateway: MacGatewayStore
        let activity: IOSSubAgentActivityStore
        let hubStore: AmberHubStore

        var body: some View {
            VStack(spacing: 12) {
                AmberDuetTaskCenterCard(
                    gateway: gateway,
                    subAgentStore: activity,
                    hubStore: hubStore,
                    onOpenFullTaskBoard: {},
                    onOpenTask: { _ in },
                    onFollowupTask: { _ in }
                )
                .offset(y: driver.dragOffsetY)

                AmberDuetBottomSwitcher(
                    selectedTab: .tasks,
                    gateway: gateway,
                    subAgentStore: activity,
                    hubStore: hubStore,
                    onOpenTasks: {},
                    onOpenWorkspace: {}
                )
            }
            .frame(width: 393, height: 760)
        }
    }

    func testSwarmPerf_4_duetSwitcher120HzScrubTaskProjection() throws {
        let suite = "SwarmPerfDuet.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let gateway = MacGatewayStore(defaults: defaults)
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let activity = IOSSubAgentActivityStore(tasks: tasks, defaults: defaults, loadRuns: { [] })
        let hubStore = AmberHubStore(defaults: defaults)
        _ = hubStore.createHub(title: "iOS 性能工程", thesis: "流式与导航帧率治理")
        _ = hubStore.createHub(title: "多端设计对齐", thesis: "Arquiel Design Liquid Glass")

        var subItems: [IOSSubAgentActivity] = []
        for idx in 0..<6 {
            let record = tasks.startTask(
                id: "perf-sub-\(idx)",
                kind: .subAgent,
                title: "子代理巡检 \(idx)",
                objective: "核查模块 \(idx) 的主线程耗时与缓存命中"
            )
            if idx % 2 == 0 {
                _ = tasks.updateTask(
                    id: record.id,
                    status: .completed,
                    resultSummary: "# 巡检结论 \(idx)\n\n- **主线程预算达标**\n- **视觉表现无损**"
                )
            }
            if let latest = tasks.task(id: record.id),
               let item = IOSSubAgentActivityStore.activity(latest) {
                subItems.append(item)
            }
        }
        activity.reconcile(subItems)

        let now = Date()
        gateway.cloudTasks = (0..<6).map { idx in
            MacGatewayCloudTaskRecord(
                gatewayId: "gw-perf",
                deviceId: "dev-perf",
                request: .init(
                    requestId: "cloud-req-\(idx)",
                    text: "执行云端构建与回归检查 \(idx)",
                    title: "云端回归任务 \(idx)"
                ),
                createdAt: now.addingTimeInterval(Double(-idx * 60)),
                updatedAt: now
            )
        }

        let driver = ScrubDriver()
        let host = UIHostingController(
            rootView: DuetScrubHarness(
                driver: driver,
                gateway: gateway,
                activity: activity,
                hubStore: hubStore
            )
        )
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            ChatRenderProbe.enabled = false
            ChatRenderProbe.reset()
            window.isHidden = true
            window.rootViewController = nil
        }

        ChatRenderProbe.enabled = true
        ChatRenderProbe.reset()

        let frames = 120
        let start = Self.threadCPUNanos()
        for frame in 0..<frames {
            driver.dragOffsetY = CGFloat(frame % 48)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
        let elapsedNs = Self.threadCPUNanos() - start
        let cpuMs = Double(elapsedNs) / 1_000_000.0
        let builderCalls = ChatRenderProbe.counts["task-builder"]?["all"] ?? 0
        let duetBodies = ChatRenderProbe.counts["duet-chrome-body"]?["all"] ?? 0
        let panelBodies = ChatRenderProbe.counts["panel-tasks-body"]?["all"] ?? 0

        print(String(
            format: "[SWARM-PERF] duet120HzScrub frames=%d cpuMs=%.3f perFrameUs=%.1f builderCalls=%d panelBodies=%d duetBodies=%d",
            frames,
            cpuMs,
            (Double(elapsedNs) / 1_000.0) / Double(frames),
            builderCalls,
            panelBodies,
            duetBodies
        ))
    }

    // MARK: - 5. 多工具轮次 ConversationArtifactIndex + Shelf 增量刷新

    func testSwarmPerf_5_incrementalToolArtifactIndexRefresh() {
        var messages: [UIMessage] = [makeUserMessage("请整理多份参考网页与工作区文档。")]
        let filePayload = String(repeating: "SwiftUI Timeline & Liquid Glass Architecture Notes.\n", count: 80)
        for step in 0..<45 {
            let tool: UIMessagePart.Tool
            switch step % 3 {
            case 0:
                tool = UIMessagePart.Tool(
                    toolCallId: "write-\(step)",
                    toolName: "workspace_file_write",
                    input: #"{"path":"docs/note_\#(step % 6).md","content":\#(String(reflecting: filePayload))}"#,
                    output: [UIMessagePart.Text(
                        text: #"{"ok":true,"path":"/workspace/docs/note_\#(step % 6).md","size_bytes":\#(filePayload.utf8.count)}"#,
                        metadata: nil
                    )],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                )
            case 1:
                tool = UIMessagePart.Tool(
                    toolCallId: "scrape-\(step)",
                    toolName: "scrape_web",
                    input: #"{"url":"https://example.com/perf/\#(step)"}"#,
                    output: [UIMessagePart.Text(
                        text: #"{"status":"ok","url":"https://example.com/perf/\#(step)","title":"Perf Doc \#(step)","content":"Detailed benchmark findings for step \#(step)."}"#,
                        metadata: nil
                    )],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                )
            default:
                tool = UIMessagePart.Tool(
                    toolCallId: "wm-\(step)",
                    toolName: "wm_open",
                    input: #"{"session_id":"s-1"}"#,
                    output: [UIMessagePart.Text(
                        text: #"{"ok":true,"page":{"url":"https://example.com/mount/\#(step)","title":"Mounted \#(step)"},"visible_text":"Visible summary \#(step)"}"#,
                        metadata: nil
                    )],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                )
            }
            messages.append(UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [tool],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: chatNowLocalDateTime(),
                modelId: nil,
                usage: nil,
                translation: nil
            ))
        }

        let cache = ConversationArtifactContentCache()
        var shelf = ChatArtifactShelfState()
        let settings = IOSGenerativeWidgetSettings(IosSettingsDefaults.shared.defaultSeededSettings().agentRuntime.generativeUi)

        // 预热前 20 条
        let initialSlice = Array(messages.prefix(21))
        shelf.update(
            ConversationArtifactIndex.make(from: initialSlice, widgetSettings: settings, contentCache: cache),
            conversationID: "conv-perf",
            isForegroundRunning: true,
            allowArrival: false
        )

        let start = Self.threadCPUNanos()
        var lastCount = 0
        for end in 22...messages.count {
            let prefix = Array(messages.prefix(end))
            let index = ConversationArtifactIndex.make(from: prefix, widgetSettings: settings, contentCache: cache)
            shelf.update(index, conversationID: "conv-perf", isForegroundRunning: true, allowArrival: true)
            // 紧跟一次同内容复查（模拟流式/状态同步触发的无变化重刷）
            let repeated = ConversationArtifactIndex.make(from: prefix, widgetSettings: settings, contentCache: cache)
            shelf.update(repeated, conversationID: "conv-perf", isForegroundRunning: true, allowArrival: true)
            lastCount = repeated.count
        }
        let elapsedNs = Self.threadCPUNanos() - start
        let cpuMs = Double(elapsedNs) / 1_000_000.0
        XCTAssertGreaterThan(lastCount, 0)
        let fullVerify = ConversationArtifactIndex.make(from: messages, widgetSettings: settings)
        XCTAssertEqual(shelf.index.files.map(\.path), fullVerify.files.map(\.path))
        XCTAssertEqual(shelf.index.webPages.map(\.url), fullVerify.webPages.map(\.url))

        print(String(
            format: "[SWARM-PERF] artifactIncrementalRefresh steps=%d totalCalls=%d cpuMs=%.3f",
            messages.count - 21,
            (messages.count - 21) * 2,
            cpuMs
        ))
    }

    // MARK: - 6. 前台多步工具截图 Handoff Checkpoint 主线程持久化与无损恢复

    func testSwarmPerf_6_mainActorHandoffCheckpointPersistenceWithToolImages() async throws {
        let suite = "SwarmPerfHandoff.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()

        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { _ in "sk-test" },
            storeCredential: { _, _ in true },
            deleteCredential: { _ in true }
        )
        let openAI = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "HandoffPerf",
            apiKey: "sk-test",
            baseUrl: "https://example.invalid/v1",
            modelName: "PerfModel",
            modelId: "gpt-4o"
        )
        let added = sharedSettings.addProvider(openAI)
        let model = try XCTUnwrap(added.models.first(where: { $0.type == ModelType.chat }))
        let params = TextGenerationParams(
            model: model,
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )

        let coordinator = IOSChatBackgroundGenerationCoordinator.shared
        let requestId = "swarm-perf-handoff-\(UUID().uuidString)"
        defer {
            coordinator.removePayload(requestId: requestId)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        // 构造 8 张约 180KB 的内联 base64 工具截图（模拟真实手机自动化 / 浏览器多步观测）
        let base64Chunk = String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5", count: 3_800)
        var transcript: [UIMessage] = [makeUserMessage("执行多步页面巡检并保留截图记录。")]
        for step in 1...8 {
            let dataURL = "data:image/jpeg;base64,\(step)\(base64Chunk)"
            let tool = UIMessagePart.Tool(
                toolCallId: "obs-\(step)",
                toolName: "phone_observe",
                input: #"{"step":\#(step)}"#,
                output: [
                    UIMessagePart.Text(text: #"{"screenshot_observation_id":"obs-\#(step)"}"#, metadata: nil),
                    UIMessagePart.Image(url: dataURL, metadata: nil)
                ],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
            transcript.append(UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [tool],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: chatNowLocalDateTime(),
                modelId: nil,
                usage: nil,
                translation: nil
            ))
        }

        let convID = try XCTUnwrap(store.currentConversation?.id)
        let baseline = Array(transcript.prefix(7))
        let rounds = 6
        let start = Self.threadCPUNanos()
        for round in 1...rounds {
            var roundDisplay = transcript
            roundDisplay.append(makeAssistantMessage(text: "第 \(round) 轮前台检查点推进。", finished: false))
            let handoff = IOSChatBackgroundHandoff(
                runId: "run-perf",
                startedAt: 1_700_000_000_000,
                inputDigest: "digest-perf",
                conversationId: convID,
                providerId: added.id.toHexDashString(),
                providerSetting: added,
                params: params,
                uploadMessages: IOSToolImageRequestBudget.apply(roundDisplay),
                displayMessages: roundDisplay,
                mode: .resumeResponse,
                responseId: "resp-\(round)",
                responseSequenceNumber: Int64(round),
                generativeUiRequirement: .none,
                generativeUiFallbackAttempted: false,
                fullToolNames: ["phone_observe", "phone_act"],
                runDisplayBaseline: baseline
            )
            try coordinator.persist(handoff: handoff, requestId: requestId)
        }
        let elapsedNs = Self.threadCPUNanos() - start
        let cpuMs = Double(elapsedNs) / 1_000_000.0

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let jsonURL = appSupport
            .appendingPathComponent("ChatBackgroundJobs", isDirectory: true)
            .appendingPathComponent(IOSChatBackgroundJobFileNaming.sanitized(requestId))
            .appendingPathExtension("json")
        let jsonBytes = (try? Data(contentsOf: jsonURL).count) ?? -1

        // 校验恢复出来的 displayMessages / runDisplayBaseline 100% 字节级无损保留全部 8 张原始内联截图！
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(userDefaults: defaults),
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: IOSForegroundNoopSearchTransport(),
            mcpManager: IOSMcpManager(sharedSettings: sharedSettings, configStore: .shared)
        )
        var loaded: IOSChatBackgroundHandoff?
        coordinator.withDependenciesForTesting(
            conversationStore: store,
            toolRuntime: runtime,
            sharedSettings: sharedSettings
        ) {
            loaded = coordinator.loadHandoff(requestId: requestId)
        }
        let rehydrated = try XCTUnwrap(loaded)
        XCTAssertEqual(rehydrated.displayMessages.count, transcript.count + 1)
        XCTAssertEqual(rehydrated.runDisplayBaseline?.count, baseline.count)
        for step in 1...8 {
            let expectedURL = "data:image/jpeg;base64,\(step)\(base64Chunk)"
            let tool = try XCTUnwrap(rehydrated.displayMessages[step].parts.first as? UIMessagePart.Tool)
            let image = try XCTUnwrap(tool.output.last as? UIMessagePart.Image)
            XCTAssertEqual(image.url, expectedURL, "第 \(step) 步历史工具截图在 checkpoint 恢复后必须字节级无损")
        }

        print(String(
            format: "[SWARM-PERF] handoffCheckpointPersist rounds=%d cpuMs=%.3f perCheckpointMs=%.3f jsonBytes=%d",
            rounds,
            cpuMs,
            cpuMs / Double(rounds),
            jsonBytes
        ))
    }
}
