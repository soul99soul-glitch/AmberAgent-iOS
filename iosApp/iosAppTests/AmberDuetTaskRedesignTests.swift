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

    func testUnknownToolOutcomeCacheTracksExactOutputSnapshot() {
        func tool(_ texts: [String]) -> UIMessagePart.Tool {
            UIMessagePart.Tool(toolCallId: "same-call", toolName: "search_web", input: "{}",
                output: texts.map { UIMessagePart.Text(text: $0, metadata: nil) },
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
        }
        func state(_ tool: UIMessagePart.Tool) -> ChatTaskRollupState {
            ChatTaskStreamGrouping.computeRollupState(tools: [tool], steps: [ChatToolStepModel(tool: tool)],
                                                     reasonings: [], isGeneratingTail: false)
        }
        let unknown = tool([#"{"status": "#, #""UNKNOWN"}"#])
        guard case .needsAttention = state(unknown) else { return XCTFail("split unknown output must stay visible") }
        guard case .needsAttention = state(unknown) else { return XCTFail("cached unknown output must stay visible") }
        XCTAssertEqual(state(tool([#"{"status":"completed"}"#])), .completed(stepCount: 1))
        XCTAssertEqual(state(tool([#"{"status":"unknown"}"#, #"{"status":"completed"}"#])),
                       .completed(stepCount: 1), "two separate JSON documents are not one joined JSON result")
    }

    func testToolStepCacheTracksSameCallStatusReplacements() {
        let cache = ChatTaskToolStepCache()
        let snapshots = [
            makeTool(id: "same-call", name: "terminal_execute"),
            makeTool(id: "same-call", name: "terminal_execute", outputJSON: #"{"ok":true,"status":"completed","stdout":"done"}"#),
            makeTool(id: "same-call", name: "terminal_execute", outputJSON: #"{"ok":false,"status":"failed","error":"denied"}"#)
        ]
        for tool in snapshots {
            cache.prepare(tools: [tool], languageKey: "test")
            let expected = ChatToolStepModel(tool: tool)
            for _ in 0..<2 {
                let actual = cache.step(for: tool)
                XCTAssertEqual(actual.state, expected.state)
                XCTAssertEqual(actual.title, expected.title)
                XCTAssertEqual(actual.detail, expected.detail)
            }
        }
    }

    func testTaskCountCacheMatchesFullProjectionAcrossStreamingAndBackfills() {
        let cache = ChatTaskCountCache()
        let failed = makeAssistantMessage(parts: [makeTool(
            id: "failed", name: "search_web", outputJSON: #"{"ok":false,"error":"unavailable"}"#
        )])
        let running = makeAssistantMessage(parts: [makeTool(id: "running", name: "search_web")], finished: false)
        var messages = [failed, UIMessage.companion.user(prompt: "继续"), running]

        func fullCounts(_ messages: [UIMessage], generating: Bool) -> ChatTaskCountCache.Counts {
            let lastID = messages.last.map(ChatMessageProjector.messageId(for:))
            var counts = ChatTaskCountCache.Counts()
            for message in messages where message.role == MessageRole.assistant {
                let id = ChatMessageProjector.messageId(for: message)
                let segments = ChatTaskStreamGrouping.segments(
                    for: message, messageID: id, isGeneratingTail: generating && id == lastID
                )
                for case .taskGroup(let group) in segments where group.hasTools {
                    if group.rollupState.isLive { counts.active += 1 }
                    if group.rollupState.isFailureOrNeedsUser { counts.needsAttention += 1 }
                }
            }
            return counts
        }

        func check(_ generating: Bool) {
            XCTAssertEqual(cache.counts(messages: messages, isGenerationActive: generating),
                           fullCounts(messages, generating: generating))
        }

        check(true)
        XCTAssertEqual(cache.counts(messages: messages, isGenerationActive: true),
                       ChatTaskCountCache.Counts(active: 1, needsAttention: 1))
        check(false)
        messages[0] = UIMessage(id: failed.id, role: failed.role, parts: [makeTool(
            id: "failed", name: "search_web", outputJSON: #"{"ok":true,"status":"completed"}"#
        )], annotations: [], createdAt: failed.createdAt, finishedAt: failed.finishedAt,
            modelId: nil, usage: nil, translation: nil)
        check(true)
        XCTAssertEqual(cache.counts(messages: messages, isGenerationActive: true).needsAttention, 0)
        messages.removeFirst()
        check(true)
        (running.parts[0] as? UIMessagePart.Tool)?.metadata = [:]
        check(true)

        let history = (0..<120).map { index in
            makeAssistantMessage(parts: (0..<4).map { toolIndex in
                makeTool(id: "\(index)-\(toolIndex)", name: "search_web",
                         outputJSON: #"{"ok":true,"status":"completed"}"#)
            })
        }
        let liveID = KotlinUuid.companion.random()
        let liveTool = makeTool(id: "live", name: "search_web")
        let createdAt = chatNowLocalDateTime()
        func frame(_ index: Int) -> [UIMessage] {
            history + [UIMessage(id: liveID, role: MessageRole.assistant,
                parts: [liveTool, UIMessagePart.Text(text: "回复 \(index)", metadata: nil)],
                annotations: [], createdAt: createdAt, finishedAt: nil, modelId: nil, usage: nil, translation: nil)]
        }
        let frames = (0..<20).map(frame)
        _ = fullCounts(frames[0], generating: true)
        let baselineStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let expected = frames.map { fullCounts($0, generating: true) }
        let baseline = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - baselineStart
        let warmedCache = ChatTaskCountCache()
        _ = warmedCache.counts(messages: frames[0], isGenerationActive: true)
        let cachedStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let actual = frames.map { warmedCache.counts(messages: $0, isGenerationActive: true) }
        let cached = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cachedStart
        XCTAssertEqual(actual, expected)
        print("[PERF-TASK-COUNTS] history=120 tools=480 updates=20 full=\(Double(baseline) / 1_000_000)ms cached=\(Double(cached) / 1_000_000)ms")
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
        XCTAssertEqual(group.inlineStatusBadgeText, "云端运行中")
        XCTAssertEqual(group.headline, "训一个只看变化的视频小模型")
        XCTAssertFalse(group.rollupState.isFailureOrNeedsUser, "Working inline card defaults to single-line without failure callout")
    }

    func testBackgroundHandoffPreservesRequestIdAndDraftAcrossUncertainRetries() {
        var state = ChatComposerLocalState()
        let failedTask = AmberUnifiedTaskItem(
            id: "ssh-fail-1",
            title: "配置 SSH 跳板机与目标机",
            subtitle: "私钥校验未通过 · 本机",
            category: .needsAttention,
            statusBadgeText: "4 次失败",
            actionTitle: "补充密钥",
            hubId: "hub-amber-core",
            underlyingSegment: nil,
            cloudTaskId: nil
        )

        state.enterBackgroundHandoffMode(followupTask: failedTask)
        XCTAssertTrue(state.isBackgroundHandoffMode)
        XCTAssertEqual(state.handoffFollowupTask?.id, "ssh-fail-1")

        let prompt = "帮忙并行核对岚山竹林路线，并把视频闪烁检测模型挂到云端跑"
        let firstReqId = state.prepareHandoffRequestId(
            for: prompt,
            target: .cloud,
            hubId: "hub-kyoto-trip",
            followupTaskId: failedTask.id
        )

        state.markHandoffSubmissionFailed("云端网络抖动，结果未确认")
        XCTAssertTrue(state.handoffNeedsRetry)
        XCTAssertTrue(state.isBackgroundHandoffMode)

        // Retrying the exact same prompt/target/hub/followup must reuse the same requestId
        let retryReqId = state.prepareHandoffRequestId(
            for: prompt,
            target: .cloud,
            hubId: "hub-kyoto-trip",
            followupTaskId: failedTask.id
        )
        XCTAssertEqual(firstReqId, retryReqId, "Uncertain retry must preserve requestId to prevent duplicate jobs")

        // Changing the prompt generates a new requestId
        let changedReqId = state.prepareHandoffRequestId(
            for: prompt + "（加上夜间样本）",
            target: .cloud,
            hubId: "hub-kyoto-trip",
            followupTaskId: failedTask.id
        )
        XCTAssertNotEqual(firstReqId, changedReqId)

        state.completeHandoffSubmission()
        XCTAssertFalse(state.isBackgroundHandoffMode)
        XCTAssertFalse(state.handoffNeedsRetry)
        XCTAssertNil(state.activeHandoffRequestId)
    }

    private static func applyPreviewFixtures(to store: AmberHubStore) {
        let previewHubs: [AmberHubItem] = [
            AmberHubItem(
                id: "hub-kyoto-trip",
                title: "京都旅行",
                thesis: "步行路线与伴手礼清单",
                template: .general,
                memoryPolicy: .sharedWithGlobal,
                pinnedSupertags: ["#京都", "#步行路线"],
                memoryCountHint: 12,
                statusSummaryOverride: "12 条记忆 · 2 项任务"
            ),
            AmberHubItem(
                id: "hub-amber-core",
                title: "机房视觉检测",
                thesis: "四端架构与云端任务协同",
                template: .coding,
                memoryPolicy: .sharedWithGlobal,
                pinnedSupertags: ["#Amber", "#iOS"],
                documentCountHint: 3,
                statusSummaryOverride: "3 份资料 · 1 项云端运行中"
            ),
            AmberHubItem(
                id: "hub-novel-ash-city",
                title: "小说 · 雾港手记",
                thesis: "世界观设定与章节大纲",
                template: .novel,
                memoryPolicy: .hubIsolated,
                pinnedSupertags: ["#小说", "#设定"],
                documentCountHint: 4,
                statusSummaryOverride: "独立记忆 · 第 4 章草稿"
            )
        ]
        let previewCollections: [AmberSmartCollectionItem] = [
            AmberSmartCollectionItem(
                id: "sc-ssh-ops",
                title: "SSH 运维",
                primaryTag: "#ops/ssh",
                itemCount: 4,
                conversationIds: [],
                memoryCount: 6,
                digest: "跳板机与私钥配置",
                template: .coding,
                promotionSuggested: true
            ),
            AmberSmartCollectionItem(
                id: "sc-camera-compare",
                title: "摄影器材对比",
                primaryTag: "#gear/camera",
                itemCount: 3,
                conversationIds: [],
                memoryCount: 4,
                digest: "轻便定焦镜头选型",
                template: .general,
                promotionSuggested: false
            )
        ]
        store.replaceForPreview(
            hubs: previewHubs,
            activeHubId: "hub-kyoto-trip",
            collections: previewCollections
        )
    }

    func testHubStoreSmartCollectionPromotionAndUnifiedTaskGrouping() throws {
        let suite = "AmberHubStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }

        // Production store starts empty with zero fabricated hubs or collections
        let hubStore = AmberHubStore(defaults: defaults)
        XCTAssertTrue(hubStore.hubs.isEmpty, "Production AmberHubStore must start empty without fake data")
        XCTAssertTrue(hubStore.smartCollections.isEmpty, "Production AmberHubStore must start empty without fake collections")
        XCTAssertNil(hubStore.activeHub)
        XCTAssertNil(hubStore.smartCollectionsSummaryText)

        // Apply preview fixtures explicitly for testing promotion & grouping
        Self.applyPreviewFixtures(to: hubStore)
        XCTAssertEqual(hubStore.hubs.count, 3)
        XCTAssertEqual(hubStore.smartCollections.count, 2)
        XCTAssertEqual(hubStore.activeHub?.title, "京都旅行")
        XCTAssertEqual(hubStore.smartCollectionsSummaryText, "SSH 运维 (4) 等 2 项")

        // Promote a Smart Collection to a formal Hub
        let promoted = try XCTUnwrap(hubStore.promoteSmartCollectionToHub("sc-ssh-ops", memoryPolicy: .hubIsolated))
        XCTAssertEqual(promoted.title, "SSH 运维")
        XCTAssertEqual(promoted.memoryPolicy, .hubIsolated)
        XCTAssertEqual(hubStore.hubs.count, 4)
        XCTAssertEqual(hubStore.smartCollections.count, 1)

        // Build unified tasks grouped by goal/status (needsAttention, running, recent)
        let failOutput = #"{"ok":false,"status":"failed","error":"私钥校验未通过"}"#
        let doneOutput = #"{"ok":true,"status":"completed","summary":"完成"}"#
        let failMsg = makeAssistantMessage(parts: [
            makeTool(id: "ssh-1", name: "ssh_profile_create", outputJSON: failOutput),
            makeTool(id: "ssh-2", name: "ssh_profile_create", outputJSON: failOutput),
            makeTool(id: "ssh-3", name: "ssh_profile_create", outputJSON: failOutput),
            makeTool(id: "ssh-4", name: "ssh_profile_create", outputJSON: failOutput)
        ])
        let runningMsg = makeAssistantMessage(parts: [
            makeTool(id: "train-1", name: "subagent_dispatch", input: #"{"prompt":"训练视频闪烁检测模型"}"#, outputJSON: nil)
        ], finished: false)
        let doneMsg = makeAssistantMessage(parts: [
            makeTool(id: "check-1", name: "terminal_execute", input: #"{"command":"echo ok"}"#, outputJSON: doneOutput)
        ])

        let segs = [
            ChatTaskStreamGrouping.segments(for: failMsg, messageID: "m1", isGeneratingTail: false),
            ChatTaskStreamGrouping.segments(for: runningMsg, messageID: "m2", isGeneratingTail: true),
            ChatTaskStreamGrouping.segments(for: doneMsg, messageID: "m3", isGeneratingTail: false)
        ].flatMap { $0 }.compactMap { seg -> ChatTaskRunSegment? in
            if case .taskGroup(let g) = seg { return g }
            return nil
        }

        let tasksStore = IOSAdvancedTaskStore(userDefaults: defaults)
        let subAgentStore = IOSSubAgentActivityStore(
            tasks: tasksStore,
            defaults: defaults,
            launchedAt: Date(),
            loadRuns: { [] }
        )
        let grouped = AmberUnifiedTaskBuilder.buildTasks(
            conversationSegments: segs,
            gateway: MacGatewayStore.shared,
            subAgentStore: subAgentStore,
            hubStore: hubStore
        )
        XCTAssertEqual(grouped.needsAttention.count, 1)
        XCTAssertEqual(grouped.needsAttention.first?.statusBadgeText, "4 次失败")
        XCTAssertEqual(grouped.needsAttention.first?.actionTitle, "补充密钥")
        XCTAssertEqual(grouped.running.count, 1)
        XCTAssertEqual(grouped.running.first?.title, "训练视频闪烁检测模型")
        XCTAssertEqual(grouped.recent.count, 1)
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
        settings.apiKey = "sk-duet-preview"
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
        let parityDir = URL(
            fileURLWithPath: "/Users/arquiel/.synara/userdata/project-context/0f3f2134-3ef9-4137-8b75-6d1496ff94d1/library/design/ios-redesign-visual-parity",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: parityDir, withIntermediateDirectories: true)

        if let warmEditorial = AmberArquielThemePresets.all.first(where: { $0.id == "arquiel-warm-editorial" }) {
            try? AmberThemeRuntime.shared.apply(warmEditorial)
        }

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
            width: CGFloat = 393,
            height: CGFloat = 832,
            dimStatusBar: Bool = false,
            @ViewBuilder content: () -> V
        ) async throws {
            window.overrideUserInterfaceStyle = style
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            let root = ZStack(alignment: .top) {
                content()
                    .environment(center)
                    .environment(conversations)
                    .environment(router)
                    .environment(\.locale, Locale(identifier: "zh_Hans"))
                    .environment(\.dynamicTypeSize, .large)

                HStack {
                    Text("14:05")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AmberTheme.foreground.opacity(dimStatusBar ? 0.38 : 1.0))
                    Spacer()
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(dimStatusBar ? 0.55 : 0.88))
                        .frame(width: 96, height: 25)
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "wifi")
                        Image(systemName: "battery.100")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AmberTheme.foreground.opacity(dimStatusBar ? 0.38 : 1.0))
                }
                .padding(.horizontal, 26)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
            let host = UIHostingController(rootView: root)
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            host.additionalSafeAreaInsets = UIEdgeInsets(
                top: 43 - window.safeAreaInsets.top,
                left: 0,
                bottom: -window.safeAreaInsets.bottom,
                right: 0
            )
            try await Task.sleep(for: .milliseconds(550))
            window.layoutIfNeeded()
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 2.0
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: fmt).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let pngData = try XCTUnwrap(image.pngData())
            let fileURL = outDir.appendingPathComponent("\(name).png")
            try pngData.write(to: fileURL, options: .atomic)
            try? pngData.write(to: parityDir.appendingPathComponent("\(name).png"), options: .atomic)
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

        // 4. Canonical Argon 01–04 Screens + Theme Compatibility Captures
        UserDefaults.standard.set(1.0, forKey: IOSDisplayPreferenceKeys.fontScale)
        UserDefaults.standard.set(IOSChatFont.default.rawValue, forKey: IOSDisplayPreferenceKeys.chatFont)
        let failSSHMsg = makeAssistantMessage(parts: [
            makeTool(id: "ssh-a1", name: "ssh_profile_create", input: #"{"name":"JumpHost"}"#, outputJSON: failOutput),
            makeTool(id: "ssh-a2", name: "ssh_profile_create", input: #"{"name":"JumpHost"}"#, outputJSON: failOutput),
            makeTool(id: "ssh-a3", name: "ssh_profile_create", input: #"{"name":"TargetProd"}"#, outputJSON: failOutput),
            makeTool(id: "ssh-a4", name: "ssh_profile_create", input: #"{"name":"TargetProd"}"#, outputJSON: failOutput)
        ])
        let doneRouteMsg = makeAssistantMessage(parts: [
            makeTool(id: "route-done-1", name: "web_search", input: #"{"query":"京都大德寺步行路线"}"#, outputJSON: doneOutput)
        ])
        let timeoutRouteMsg = makeAssistantMessage(parts: [
            makeTool(id: "route-timeout-1", name: "web_search", input: #"{"query":"岚山小火车实时余票"}"#, outputJSON: #"{"ok":true,"status":"completed","timedOut":true}"#)
        ])
        let argonChatMessages: [UIMessage] = [
            UIMessage.companion.user(prompt: "帮我后台跑机房视频闪烁检测模型；同时聊聊大德寺下午怎么逛最清静。"),
            makeAssistantMessage(parts: [
                makeTool(
                    id: "cloud-video-1",
                    name: "subagent_dispatch",
                    input: #"{"name":"CloudTrainer","prompt":"训练视频闪烁检测模型"}"#,
                    outputJSON: nil
                ),
                UIMessagePart.Text(
                    text: """
                    模型训练已交由云端后台推进。大德寺下午慢走建议只挑两座塔头：

                    - 14:00 龙源院与高桐院：看最小巧壶庭「东滴壶」与枫竹参道。
                    - 15:30 出东门今宫神社茶屋尝烤麻薯，顺路逛紫野器皿小店。
                    """,
                    metadata: nil
                )
            ], finished: false)
        ]
        await viewModel.startNewConversation()
        let argonId = try XCTUnwrap(conversations.currentConversation?.id)
        _ = await conversations.save(messages: argonChatMessages, to: argonId)
        await conversations.renameConversation(id: argonId, title: "京都旅行")
        Self.applyPreviewFixtures(to: AmberHubStore.shared)
        defer {
            AmberHubStore.shared.replaceForPreview(hubs: [], activeHubId: nil, collections: [])
        }
        AmberHubStore.shared.selectHub("hub-kyoto-trip")
        viewModel.reloadFromStore(reason: .conversationSwitch)
        viewModel.inputText = ""

        // Screen 01: Main Chat (Single-line inline task + breathing whitespace)
        try await capture("ios-argon-01-main-chat-sim") {
            NavigationStack {
                ChatView(settingsStore: settings, sharedSettings: sharedSettings, viewModel: viewModel, activityStore: activityStore)
            }
        }
        try await capture("ios-argon-01-main-chat-dark-sim", style: .dark) {
            NavigationStack {
                ChatView(settingsStore: settings, sharedSettings: sharedSettings, viewModel: viewModel, activityStore: activityStore)
            }
        }

        // Theme compatibility capture: Takram Moss
        let runtime = AmberThemeRuntime.shared
        let savedTheme = AmberThemePackTransfer.document(from: runtime)
        if let mossPreset = AmberArquielThemePresets.all.first(where: { $0.id == "arquiel-takram-moss" }) {
            try? runtime.apply(mossPreset)
            try await capture("ios-argon-01-main-chat-takram-moss-sim") {
                NavigationStack {
                    ChatView(settingsStore: settings, sharedSettings: sharedSettings, viewModel: viewModel, activityStore: activityStore)
                }
            }
            try? runtime.apply(savedTheme)
        }

        // Screen 02: Tasks Panel (Collapsed composer + Goal/Status grouped tasks + Collapsed history)
        await viewModel.startNewConversation()
        let tasksConvId = try XCTUnwrap(conversations.currentConversation?.id)
        _ = await conversations.save(messages: [failSSHMsg, doneRouteMsg, timeoutRouteMsg] + argonChatMessages, to: tasksConvId)
        await conversations.renameConversation(id: tasksConvId, title: "京都旅行")
        viewModel.reloadFromStore(reason: .conversationSwitch)
        var tasksTabState = ChatComposerLocalState()
        tasksTabState.activeDuetTab = .tasks
        try await capture("ios-argon-02-tasks-sheet-sim", dimStatusBar: true) {
            NavigationStack {
                ChatView(
                    settingsStore: settings,
                    sharedSettings: sharedSettings,
                    viewModel: viewModel,
                    activityStore: activityStore,
                    initialComposerState: tasksTabState
                )
            }
        }

        // Screen 03: Hubs Panel (Collapsed composer + Iconless typography + Smart Collections bar)
        var hubsTabState = ChatComposerLocalState()
        hubsTabState.activeDuetTab = .hubs
        try await capture("ios-argon-03-hubs-sheet-sim", dimStatusBar: true) {
            NavigationStack {
                ChatView(
                    settingsStore: settings,
                    sharedSettings: sharedSettings,
                    viewModel: viewModel,
                    activityStore: activityStore,
                    initialComposerState: hubsTabState
                )
            }
        }

        // Screen 04: Background Handoff (In-place morphed "交办 ↗" + "● 云端 · 京都旅行 ⌄")
        await conversations.selectConversation(id: argonId)
        viewModel.reloadFromStore(reason: .conversationSwitch)
        viewModel.inputText = "盯一下 11.16 岚山小火车余票"
        var handoffState = ChatComposerLocalState()
        handoffState.enterBackgroundHandoffMode()
        try await capture("ios-argon-04-background-handoff-sim") {
            NavigationStack {
                ChatView(
                    settingsStore: settings,
                    sharedSettings: sharedSettings,
                    viewModel: viewModel,
                    activityStore: activityStore,
                    initialComposerState: handoffState
                )
            }
        }
    }

    @MainActor
    func testArquielThemePresetsAndPersonalAgentPersonaMedallion() throws {
        let presets = AmberArquielThemePresets.all
        XCTAssertEqual(presets.count, 6)
        let runtime = AmberThemeRuntime.shared
        let snapshot = AmberThemePackTransfer.document(from: runtime)
        defer {
            try? runtime.apply(snapshot)
        }

        for preset in presets {
            XCTAssertNoThrow(try AmberThemePackTransfer.validate(preset), "Preset \(preset.id) must pass validation")
            XCTAssertNoThrow(try runtime.apply(preset), "Preset \(preset.id) must apply cleanly")
            XCTAssertTrue(preset.matches(runtime: runtime), "Preset \(preset.id) must match runtime after apply")
        }

        for mood in [AmberAgentPersonaMood.idle, .working, .alert] {
            let medallion = AmberAgentPersonaMedallionView(mood: mood, diameter: 54)
            XCTAssertEqual(medallion.mood, mood)
        }
    }

    @MainActor
    func testAmberPersonaStoreAndMuseReferenceImageBinding() throws {
        let suite = "AmberPersonaStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = AmberPersonaStore(defaults: defaults, storageDirectory: tempDir)
        XCTAssertEqual(store.selectedPreset, .amberFox)
        XCTAssertTrue(store.autoBindReferenceInImageGen)
        XCTAssertNil(store.primaryReferenceDataURL())

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let sampleImage = renderer.image { ctx in
            UIColor(red: 0.78, green: 0.36, blue: 0.14, alpha: 1.0).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let sampleData = try XCTUnwrap(sampleImage.pngData())
        store.addReferenceImage(from: sampleData, label: "三视图设定")
        XCTAssertEqual(store.references.count, 1)

        let refDataURL = try XCTUnwrap(store.primaryReferenceDataURL())
        XCTAssertTrue(refDataURL.hasPrefix("data:image/jpeg;base64,"))

        let enriched = try ChatImageGenerationReference.enrichToolInput(
            #"{"prompt":"琥珀灵狐在京都鸭川散步"}"#,
            messages: [],
            personaReferenceURL: refDataURL
        ).get()
        XCTAssertTrue(enriched.contains("source_image_url"), "Expected generate_image input to bind persona reference URL")
    }

    @MainActor
    func testComposerInputHitTestFocusAndTypingRegression() async throws {
        let suite = "AmberComposerHitTest.\(UUID().uuidString)"
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
        settings.apiKey = "sk-test"
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let viewModel = ChatViewModel(settingsStore: settings, sharedSettings: sharedSettings)
        viewModel.conversationStore = conversations
        await viewModel.startNewConversation()
        viewModel.inputText = ""

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

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
        }

        let root = NavigationStack {
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

        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()

        func findTextView(in view: UIView) -> UITextView? {
            if let tv = view as? UITextView { return tv }
            for sub in view.subviews {
                if let found = findTextView(in: sub) { return found }
            }
            return nil
        }

        let textView = try XCTUnwrap(findTextView(in: host.view), "Composer UITextView must be mounted")
        XCTAssertTrue(textView.isEditable, "Composer UITextView must be editable in empty conversation")

        let centerInWindow = textView.convert(CGPoint(x: textView.bounds.midX, y: textView.bounds.midY), to: window)
        let hitView = window.hitTest(centerInWindow, with: nil)
        XCTAssertTrue(
            hitView === textView || (hitView?.isDescendant(of: textView) == true),
            "Tapping composer center (\(centerInWindow)) must hit UITextView, but hit: \(String(describing: hitView))"
        )

        _ = textView.becomeFirstResponder()
        textView.insertText("测试主对话输入\n第二行")
        XCTAssertEqual(viewModel.inputText, "测试主对话输入\n第二行")

        // Verify existing conversation with messages also keeps UITextView hit-testable and editable
        if let convId = conversations.currentConversation?.id {
            _ = await conversations.save(
                messages: [UIMessage.companion.user(prompt: "已有历史消息")],
                to: convId
            )
            viewModel.reloadFromStore(reason: .conversationSwitch)
            try await Task.sleep(for: .milliseconds(200))
            window.layoutIfNeeded()
        }

        let centerAfterMessages = textView.convert(CGPoint(x: textView.bounds.midX, y: textView.bounds.midY), to: window)
        let hitAfterMessages = window.hitTest(centerAfterMessages, with: nil)
        XCTAssertTrue(
            hitAfterMessages === textView || (hitAfterMessages?.isDescendant(of: textView) == true),
            "Tapping composer center in existing conversation must hit UITextView, but hit: \(String(describing: hitAfterMessages))"
        )
        textView.insertText("，继续追加")
        XCTAssertEqual(viewModel.inputText, "测试主对话输入\n第二行，继续追加")
    }
}
