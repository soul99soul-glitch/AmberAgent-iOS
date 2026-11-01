import XCTest
import SwiftUI
import UIKit
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class AmberDuetTaskRedesignTests: XCTestCase {

    private func makeReasoning(_ text: String, finished: Bool = true, seconds: Int64 = 5) -> UIMessagePart.Reasoning {
        let start = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 1_700_000_000_000)
        let end = finished
            ? KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 1_700_000_000_000 + seconds * 1_000)
            : nil
        return UIMessagePart.Reasoning(reasoning: text, createdAt: start, finishedAt: end, metadata: nil)
    }

    private func makeTool(
        id: String,
        name: String,
        input: String = "{}",
        outputJSON: String? = nil,
        approval: ToolApprovalState = ToolApprovalState.Auto.shared
    ) -> UIMessagePart.Tool {
        let outputs: [UIMessagePart] = outputJSON.map { [UIMessagePart.Text(text: $0, metadata: nil)] } ?? []
        return UIMessagePart.Tool(
            toolCallId: id,
            toolName: name,
            input: input,
            output: outputs,
            approvalState: approval,
            streamIndex: nil,
            metadata: nil
        )
    }

    private func makeAssistantMessage(parts: [UIMessagePart], finished: Bool = true) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: parts,
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: finished ? chatNowLocalDateTime() : nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    /// Regression test for `IMG_2604.PNG`:
    /// 4x `ssh_profile_create` failures interleaved with 4x `Reasoning` pills and followed by 1x `ssh_profile_list`
    /// success + assistant text must collapse into ONE `ChatTaskRunSegment` whose rollup is `.needsAttention`
    /// (never disguised as `.completed`).
    func testRepeatedSSHProfileFailuresFollowedByListSuccessSurfaceAsNeedsAttention() throws {
        let failOutput = #"{"ok":false,"status":"failed","error":"SSH 私钥格式校验未通过"}"#
        let listOutput = #"{"ok":true,"status":"completed","profiles":[]}"#
        let message = makeAssistantMessage(parts: [
            makeReasoning("分析跳板机与目标机参数", seconds: 5),
            makeTool(id: "ssh-1", name: "ssh_profile_create", input: #"{"name":"JumpHost"}"#, outputJSON: failOutput),
            makeReasoning("重试参数组合 2", seconds: 3),
            makeTool(id: "ssh-2", name: "ssh_profile_create", input: #"{"name":"JumpHost"}"#, outputJSON: failOutput),
            makeReasoning("重试参数组合 3", seconds: 6),
            makeTool(id: "ssh-3", name: "ssh_profile_create", input: #"{"name":"ProdServer"}"#, outputJSON: failOutput),
            makeReasoning("重试参数组合 4", seconds: 1),
            makeTool(id: "ssh-4", name: "ssh_profile_create", input: #"{"name":"ProdServer"}"#, outputJSON: failOutput),
            makeTool(id: "ssh-5", name: "ssh_profile_list", input: "{}", outputJSON: listOutput),
            UIMessagePart.Text(text: "我已经尝试为您配置两个 SSH Profile（跳板机与目标服务器），但新建操作均未生效，请点击上方任务卡片查看具体失败原因。", metadata: nil)
        ])

        let segments = ChatTaskStreamGrouping.segments(
            for: message,
            messageID: ChatMessageProjector.messageId(for: message),
            isGeneratingTail: false
        )

        XCTAssertEqual(segments.count, 2, "4x thinking + 5x tool calls collapse into 1 taskGroup segment + 1 text segment")
        guard case .taskGroup(let taskSegment) = segments[0] else {
            return XCTFail("Expected first segment to be .taskGroup")
        }
        XCTAssertEqual(taskSegment.tools.count, 5)
        XCTAssertEqual(taskSegment.reasonings.count, 4)

        guard case .needsAttention(let failedCount, let totalCount, let failedToolTitle, let reason) = taskSegment.rollupState else {
            return XCTFail("Expected .needsAttention rollup state, got \(taskSegment.rollupState)")
        }
        XCTAssertEqual(failedCount, 4, "All 4 unrecovered ssh_profile_create failures must be counted")
        XCTAssertEqual(totalCount, 5)
        XCTAssertTrue(failedToolTitle.contains("SSH"), "Failed tool title should identify SSH Profile: \(failedToolTitle)")
        XCTAssertNotNil(reason)
        XCTAssertTrue(taskSegment.rollupState.isFailureOrNeedsUser)
    }

    func testStandaloneCompletedReasoningBeforeTextIsHiddenFromDefaultStream() {
        let message = makeAssistantMessage(parts: [
            makeReasoning("内部思考 5 秒，不需要倾倒给用户", finished: true, seconds: 5),
            UIMessagePart.Text(text: "直接给你结论：我们可以先收敛主入口。", metadata: nil)
        ])

        let segments = ChatTaskStreamGrouping.segments(
            for: message,
            messageID: ChatMessageProjector.messageId(for: message),
            isGeneratingTail: false
        )

        XCTAssertEqual(segments.count, 1, "Completed standalone reasoning before text is hidden from default stream")
        if case .text(_, _, let textPart) = segments[0] {
            XCTAssertTrue(textPart.text.contains("直接给你结论"))
        } else {
            XCTFail("Expected only .text segment")
        }
    }

    func testLiveThinkingAndActiveToolSurfaceAsWorking() {
        let message = makeAssistantMessage(parts: [
            makeReasoning("正在规划训练流程", finished: false),
            makeTool(id: "work-1", name: "subagent_dispatch", input: #"{"name":"VideoTrainer","prompt":"训一个只看变化的视频小模型"}"#, outputJSON: nil)
        ], finished: false)

        let segments = ChatTaskStreamGrouping.segments(
            for: message,
            messageID: ChatMessageProjector.messageId(for: message),
            isGeneratingTail: true
        )

        XCTAssertEqual(segments.count, 1)
        guard case .taskGroup(let group) = segments[0] else {
            return XCTFail("Expected .taskGroup")
        }
        XCTAssertTrue(group.rollupState.isLive)
        XCTAssertEqual(group.rollupState.statusBadgeText, "进行中")
    }

    /// Renders and exports high-resolution PNG screenshots for the 3 required Duet states
    /// (Main Chat, Task Working with parallel composer, Task Completed / SSH Failure Rollup)
    /// across Light, Dark, and Narrow 375pt viewports.
    func testRenderDuetRedesignPreviewScreenshots() async throws {
        let suite = "AmberDuetPreviews.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let conversations = IOSConversationStore(baseDirectory: directory, subagentConversationIDsProvider: { [] })
        await conversations.bootstrap()

        let settings = SettingsStore(userDefaults: defaults)
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Amber Cloud", apiKey: "sk-duet-preview", baseUrl: "https://example.invalid/v1",
            modelName: "Claude Opus 4.7", modelId: "claude-opus-4-7"
        )
        let addedProvider = sharedSettings.addProvider(provider)
        let model = try XCTUnwrap(addedProvider.models.first { $0.type == ModelType.chat })
        sharedSettings.setCurrentChatModelId(model.id.toHexDashString())

        let viewModel = ChatViewModel(settingsStore: settings, sharedSettings: sharedSettings)
        viewModel.conversationStore = conversations

        let dao = IosDatabaseFactory.shared.createDatabase(
            atFilePath: directory.appendingPathComponent("runs.db").path
        ).agentRuntimeDao()
        let center = ConversationActivityCenter(conversationStore: conversations, dao: dao, startedAt: .distantPast)
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let activityStore = IOSSubAgentActivityStore(
            tasks: tasks,
            defaults: defaults,
            launchedAt: Date(),
            loadRuns: { [] }
        )
        let router = RouterPath()

        let outDir = URL(fileURLWithPath: "/tmp/amber-duet-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
        }

        func capture<V: View>(
            _ name: String,
            style: UIUserInterfaceStyle = .light,
            width: CGFloat = 402,
            height: CGFloat = 874,
            @ViewBuilder content: () -> V
        ) async throws {
            window.overrideUserInterfaceStyle = style
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            let root = content()
                .environment(center)
                .environment(conversations)
                .environment(router)
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .environment(\.dynamicTypeSize, .large)
            let host = UIHostingController(rootView: root)
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(550))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let fileURL = outDir.appendingPathComponent("\(name).png")
            try XCTUnwrap(image.pngData()).write(to: fileURL, options: .atomic)
            print("DUET_PREVIEW_SAVED \(fileURL.path)")
        }

        // 1A. Warm Empty State (fixing IMG_2603.PNG)
        let emptyId = try XCTUnwrap(conversations.currentConversation?.id)
        await conversations.renameConversation(id: emptyId, title: "Amber")
        viewModel.reloadFromStore(reason: .conversationSwitch)
        try await capture("duet-1-empty-main-chat-light") {
            NavigationStack {
                ChatView(settingsStore: settings, sharedSettings: sharedSettings, viewModel: viewModel, activityStore: activityStore)
            }
        }

        // 1B. State 1: Main Chat (主对话 — Duet Clean Conversation without Thinking/Tool Clutter)
        let mainChatMessages: [UIMessage] = [
            UIMessage.companion.user(prompt: "下周我要去京都出差四天，前两天在乌丸御池附近开会，后两天想找安静、适合步行的路线，顺便带点不落俗套的伴手礼。"),
            makeAssistantMessage(parts: [
                makeReasoning("用户去京都四天：前两天乌丸御池商务，后两天偏爱安静步行与质感伴手礼。", finished: true, seconds: 4),
                UIMessagePart.Text(
                    text: """
                    前两天住在乌丸御池很方便，步行就能去**新风馆**或**三条通**的老建筑街区透透气，傍晚适合去鸭川二条大桥附近散步。

                    后两天如果想避开人潮，推荐两条安静的步行线：
                    1. **哲学之道北段 → 法然院 → 真如堂**：林木幽静，青苔庭院极美，几乎没有旅行团。
                    2. **大德寺塔头群（高桐院 / 龙源院）→ 今宫神社**：枯山水尺度克制，出东门还能尝一串百年烤麻薯。

                    **伴手礼建议**：
                    - **一保堂茶铺（寺町本店）**：罐装玉露或玄米茶，包装素雅耐放。
                    - **鸠居堂**：线香与和纸便签，轻便有质感。
                    """,
                    metadata: nil
                )
            ])
        ]
        _ = await conversations.save(messages: mainChatMessages, to: emptyId)
        await conversations.renameConversation(id: emptyId, title: "京都四日步行与伴手礼")
        viewModel.reloadFromStore(reason: .conversationSwitch)
        try await capture("duet-1-main-chat-light") {
            NavigationStack {
                ChatView(settingsStore: settings, sharedSettings: sharedSettings, viewModel: viewModel, activityStore: activityStore)
            }
        }
        try await capture("duet-1-main-chat-dark", style: .dark) {
            NavigationStack {
                ChatView(settingsStore: settings, sharedSettings: sharedSettings, viewModel: viewModel, activityStore: activityStore)
            }
        }

        // 2. State 2: Task Working (任务进行中 + 用户可随时继续输入追加指令)
        let workingMessages: [UIMessage] = [
            UIMessage.companion.user(prompt: "帮我训一个“只看变化”的视频小模型，用来检测机房指示灯闪烁异常，同时我跟你聊聊数据集怎么洗。"),
            makeAssistantMessage(parts: [
                makeReasoning("先委派后台任务启动帧差/时序小模型训练管线，再回答数据集清洗方案。", finished: true, seconds: 3),
                makeTool(
                    id: "subagent-video-1",
                    name: "subagent_dispatch",
                    input: #"{"name":"VideoTrainer","prompt":"训一个“只看变化”的视频小模型"}"#,
                    outputJSON: nil
                ),
                UIMessagePart.Text(
                    text: """
                    我已经把**训一个“只看变化”的视频小模型**交由后台任务推进（正在准备帧差特征与时序轻量网络）。

                    任务运行期间我们可以直接聊数据清洗：
                    - **静止帧剔除**：机房监控 90% 以上时间无变化，先按帧间 L1 差分阈值滤掉静止片段，能省下约 85% 的训练开销。
                    - **光照抖动增广**：对相邻帧做轻微色温与曝光扰动，防止开关灯被误判为设备故障。
                    """,
                    metadata: nil
                )
            ], finished: false)
        ]
        _ = await conversations.save(messages: workingMessages, to: emptyId)
        await conversations.renameConversation(id: emptyId, title: "视频变化小模型与数据清洗")
        viewModel.reloadFromStore(reason: .conversationSwitch)
        viewModel.inputText = "顺便把反光噪点也加进负样本里"
        try await capture("duet-2-task-working-light") {
            NavigationStack {
                ChatView(settingsStore: settings, sharedSettings: sharedSettings, viewModel: viewModel, activityStore: activityStore)
            }
        }
        try await capture("duet-2-task-working-narrow375", width: 375, height: 812) {
            NavigationStack {
                ChatView(settingsStore: settings, sharedSettings: sharedSettings, viewModel: viewModel, activityStore: activityStore)
            }
        }

        // 3. State 3: Task Result & SSH Failure Rollup (任务结果与异常显式汇总 — 修复 IMG_2604.PNG)
        viewModel.inputText = ""
        let failOutput = #"{"ok":false,"status":"failed","error":"SSH 私钥格式校验未通过"}"#
        let listOutput = #"{"ok":true,"status":"completed","profiles":[]}"#
        let doneOutput = #"{"ok":true,"status":"completed","summary":"已生成跳板机与目标机配置模板"}"#
        let resultMessages: [UIMessage] = [
            UIMessage.companion.user(prompt: "帮我配置 SSH 跳板机与目标服务器 Profile，并生成连接自检清单。"),
            makeAssistantMessage(parts: [
                makeReasoning("尝试创建跳板机 SSH Profile", seconds: 5),
                makeTool(id: "ssh-1", name: "ssh_profile_create", input: #"{"name":"JumpHost"}"#, outputJSON: failOutput),
                makeReasoning("重试参数 2", seconds: 3),
                makeTool(id: "ssh-2", name: "ssh_profile_create", input: #"{"name":"JumpHost"}"#, outputJSON: failOutput),
                makeReasoning("重试参数 3", seconds: 6),
                makeTool(id: "ssh-3", name: "ssh_profile_create", input: #"{"name":"TargetProd"}"#, outputJSON: failOutput),
                makeReasoning("重试参数 4", seconds: 1),
                makeTool(id: "ssh-4", name: "ssh_profile_create", input: #"{"name":"TargetProd"}"#, outputJSON: failOutput),
                makeTool(id: "ssh-5", name: "ssh_profile_list", input: "{}", outputJSON: listOutput),
                UIMessagePart.Text(
                    text: """
                    我已经为您整理了跳板机（`JumpHost`）与目标服务器（`TargetProd`）的配置参数：

                    - **跳板机 (JumpHost)**：`jump.example.com:22`
                    - **目标服务器 (TargetProd)**：`10.0.14.88:22`（通过 `JumpHost` 转发）

                    > **需你处理**：上方任务卡显示 **新建 SSH Profile 连续 4 次失败**（SSH 私钥格式校验未通过），配置尚未写入系统钥匙串。轻点任务卡片可查看诊断详情或补充密钥后重试。
                    """,
                    metadata: nil
                )
            ]),
            UIMessage.companion.user(prompt: "先帮我跑一下跳板机连通性预检脚本。"),
            makeAssistantMessage(parts: [
                makeReasoning("执行连通性预检", seconds: 2),
                makeTool(id: "check-1", name: "terminal_execute", input: #"{"command":"nc -zv jump.example.com 22"}"#, outputJSON: doneOutput),
                UIMessagePart.Text(
                    text: "连通性预检已完成：`jump.example.com:22` 端口可达，握手指纹正常。",
                    metadata: nil
                )
            ])
        ]
        _ = await conversations.save(messages: resultMessages, to: emptyId)
        await conversations.renameConversation(id: emptyId, title: "SSH 跳板配置")
        viewModel.reloadFromStore(reason: .conversationSwitch)
        try await capture("duet-3-task-result-ssh-failure-light") {
            NavigationStack {
                ChatView(settingsStore: settings, sharedSettings: sharedSettings, viewModel: viewModel, activityStore: activityStore)
            }
        }
        try await capture("duet-3-task-result-ssh-failure-dark", style: .dark) {
            NavigationStack {
                ChatView(settingsStore: settings, sharedSettings: sharedSettings, viewModel: viewModel, activityStore: activityStore)
            }
        }
    }
}
