import SwiftUI
import Shared
import XCTest
@testable import iosApp

@MainActor
final class ChatTimelineReviewRegressionTests: ChatNativeTimelineReplayTestCase {
    func testReturnToBottomPreservesTheDirectionOfTheUsersDrag() {
        XCTAssertFalse(NativeTimelineScrollReturnPolicy.returnedToBottom(
            liveDistanceToBottom: 52, cachedNearBottom: true, threshold: 96, draggedAwayFromBottom: true),
            "从底部拖开52pt是在查看历史，不是回到底部")
        XCTAssertFalse(NativeTimelineScrollReturnPolicy.returnedToBottom(
            liveDistanceToBottom: 30, cachedNearBottom: true, threshold: 96, draggedAwayFromBottom: true),
            "几何回调也不能在48pt附近绕过用户的暂停")
        XCTAssertTrue(NativeTimelineScrollReturnPolicy.returnedToBottom(
            liveDistanceToBottom: 24, cachedNearBottom: false, threshold: 96, draggedAwayFromBottom: false),
            "从历史向底部返回时仍保留原来的恢复容差")
        XCTAssertTrue(NativeTimelineScrollReturnPolicy.returnedToBottom(
            liveDistanceToBottom: 0, cachedNearBottom: false, threshold: 96, draggedAwayFromBottom: true))
    }

    /// The diagnostic drives a real Simulator pan from outside the test host.
    /// No contentOffset write stands in for the gesture being tested.
    func testFirstHistoryDragKeepsUserOwnership() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/StreamingPerfEvidence/first-history-drag")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("armed").path) else {
            throw XCTSkip("Opt-in real Simulator pan diagnostic")
        }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("armed"))
        let ready = folder.appendingPathComponent("ready.json")
        try? FileManager.default.removeItem(at: ready)
        let fixture = makeFixture { model in
            model.messages = longConversation(turns: 12)
            model.isGenerationActive = true
            model.send(.initialLoad)
        }
        defer { fixture.tearDown() }
        XCTAssertTrue(pumpUntil(timeout: 5) { fixture.model.latestViewport.isAtBottom })
        pump(seconds: 1)
        let scroll = try XCTUnwrap(fixture.scrollView)
        let start = scroll.contentOffset.y
        try JSONSerialization.data(withJSONObject: ["startOffset": start, "pid": getpid()])
            .write(to: ready)
        let historyStart = fixture.model.viewportHistory.count
        let touched = pumpUntil(timeout: 30) {
            fixture.model.viewportHistory.dropFirst(historyStart).contains { $0.userDragging }
        }
        XCTAssertTrue(touched, "A real Simulator gesture is required")
        guard touched else { return }
        pump(seconds: 2)
        let distance = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom - scroll.contentOffset.y
        try JSONSerialization.data(withJSONObject: [
            "startOffset": start, "endOffset": scroll.contentOffset.y,
            "distanceToBottom": distance, "followPaused": fixture.model.latestViewport.followPaused
        ], options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("result.json"))
        XCTAssertGreaterThan(distance, 20, "第一次查看历史的短拖动不能被拉回底部")
        XCTAssertTrue(fixture.model.latestViewport.followPaused)
    }

    func testIndependentTaskModeDoesNotRebuildUnrelatedHistory() throws {
        let history = longConversation(turns: 12)
        let historicalIDs = Set(history.dropLast().map { $0.id.toHexDashString() })
        let fixture = makeFixture { model in
            model.messages = history
            model.send(.initialLoad)
        }
        defer { fixture.tearDown(); ChatRenderProbe.enabled = false; ChatRenderProbe.reset() }
        XCTAssertTrue(pumpUntil(timeout: 4) { fixture.model.latestViewport.isAtBottom })
        pump(seconds: 0.4)
        ChatRenderProbe.enabled = true
        for independent in [true, false] {
            ChatRenderProbe.reset()
            fixture.model.usesIndependentTasks = independent
            pump(seconds: 0.3)
            let bodies = (ChatRenderProbe.counts["row"] ?? [:])
                .filter { historicalIDs.contains($0.key) }.values.reduce(0, +)
            XCTAssertEqual(bodies, 0, "任务进入/退出不能重建无关历史行")
            XCTAssertEqual(ChatRenderProbe.counts["chunk"]?["chunk-0"] ?? 0, 0,
                           "历史块必须在行判等之前隔离任务模式变化")
        }
    }

    func testGenerationStateStillReachesLiveRowsAndMediaModifyControls() throws {
        func assistant(_ parts: [UIMessagePart]) -> UIMessage {
            UIMessage(id: KotlinUuid.companion.random(), role: .assistant, parts: parts,
                      annotations: [], createdAt: chatNowLocalDateTime(), finishedAt: chatNowLocalDateTime(),
                      modelId: nil, usage: nil, translation: nil)
        }
        let prose = assistant([UIMessagePart.Text(text: "已完成的历史正文", metadata: nil)])
        let image = assistant([UIMessagePart.Tool(
            toolCallId: "image", toolName: "generate_image", input: "{}",
            output: [UIMessagePart.Image(url: "https://example.invalid/image.png", metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)])
        let miniApp = assistant([UIMessagePart.MiniApp(
            appId: "test", title: "应用", description: "测试", iconEmoji: "", category: "tool",
            permissions: [], htmlHash: "test", version: 1, metadata: nil)])
        let tail = makeAssistantMessage(id: KotlinUuid.companion.random(), text: "当前回复", finished: false)
        let projection = NativeTimelineProjector.build(
            messages: [prose, image, miniApp, makeUserMessage("继续"), tail],
            event: .toolResultAppended, isGenerationActive: true)
        func entry(_ message: UIMessage) throws -> NativeTimelineEntry {
            try XCTUnwrap(projection.messageEntry(for: message.id.toHexDashString()))
        }
        XCTAssertFalse(try entry(prose).observesGenerationState)
        XCTAssertTrue(try entry(image).observesGenerationState, "生成期间历史图片仍须禁用修改")
        XCTAssertTrue(try entry(miniApp).observesGenerationState, "小程序修改权限仍跟随生成状态")
        XCTAssertTrue(try entry(tail).observesGenerationState)
        var independent = try entry(prose)
        independent.isTaskLive = true
        XCTAssertTrue(independent.observesGenerationState, "非尾部的并发任务也必须保持实时")
    }

    func testCompletedProseDoesNotRebuildAtTaskStartOrFinish() throws {
        let history = longConversation(turns: 12)
        let historicalIDs = Set(history.dropLast().map { $0.id.toHexDashString() })
        let fixture = makeFixture { model in
            model.messages = history
            model.send(.initialLoad)
        }
        defer { fixture.tearDown(); ChatRenderProbe.enabled = false; ChatRenderProbe.reset() }
        XCTAssertTrue(pumpUntil(timeout: 4) { fixture.model.latestViewport.isAtBottom })
        pump(seconds: 0.4)
        func historicalBodies() -> Int {
            (ChatRenderProbe.counts["row"] ?? [:]).filter { historicalIDs.contains($0.key) }
                .values.reduce(0, +)
        }
        ChatRenderProbe.enabled = true
        ChatRenderProbe.reset()
        fixture.model.isGenerationActive = true
        fixture.model.messages.append(makeUserMessage("请继续调研"))
        fixture.model.send(.userAppend)
        pump(seconds: 0.4)
        XCTAssertEqual(historicalBodies(), 0,
                       "任务开始不应让无图片/小程序控制的已完成历史气泡刷新")

        fixture.model.messages.append(makeAssistantMessage(
            id: KotlinUuid.companion.random(), text: "本轮已完成", finished: true))
        fixture.model.send(.assistantStreamClosed)
        pump(seconds: 0.3)
        ChatRenderProbe.reset()
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)
        pump(seconds: 0.4)
        XCTAssertEqual(historicalBodies(), 0,
                       "终态收尾只应更新受生成状态影响的气泡")
        XCTAssertEqual(fixture.model.messages.count, history.count + 2)
        XCTAssertEqual(fixture.model.messages.last?.toText(), "本轮已完成")
    }

    @MainActor
    private final class PacerMount: ObservableObject {
        @Published var identity = 0
        @Published var height: CGFloat = 600
        let growth = ChatTimelineGrowth()
    }

    private struct PacerFixture: View {
        @ObservedObject var mount: PacerMount

        var body: some View {
            ChatStreamingRevealPacer(text: "正在继续生成", isStreaming: true, reduceMotion: false) { _ in
                Color.clear.frame(width: 300, height: mount.height)
            }
            .id(mount.identity)
            .environment(\.chatTimelineGrowth, mount.growth)
        }
    }

    func testStreamingPacerRemountRecordsHeightWithoutReplayingExistingContentGrowth() throws {
        let mount = PacerMount()
        mount.growth.setEnabled(true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: PacerFixture(mount: mount))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        pump(seconds: 0.2)
        XCTAssertEqual(mount.growth.totalGrowth, 0, "首次挂载只建立高度基准")
        mount.height += 22
        pump(seconds: 0.2)
        XCTAssertEqual(mount.growth.totalGrowth, 22, "挂载后的真实新增行仍平滑生长")
        mount.identity += 1
        pump(seconds: 0.2)
        XCTAssertEqual(mount.growth.totalGrowth, 22, "流式中切回页面不能把整条已有回复当增量")
        mount.height += 22
        pump(seconds: 0.2)
        XCTAssertEqual(mount.growth.totalGrowth, 44, "重新挂载后继续计算真实增量")

        // 手指刚碰屏进入 .tracking 调用 setEnabled(false) 时不得无动画把 totalGrowth 清零导致瞬跳
        mount.growth.setEnabled(false)
        XCTAssertEqual(mount.growth.totalGrowth, 44, ".tracking 暂停新增生长时必须保留已提交高度基准，避免画面瞬跳")
        mount.growth.reset()
        XCTAssertEqual(mount.growth.totalGrowth, 0, "仅在视图销毁 reset 时清零")
    }

    func testFirstShortReplyDoesNotTranslateTimelineUntilContentBecomesScrollable() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown(); ChatRenderProbe.enabled = false; ChatRenderProbe.reset() }
        fixture.model.messages = [makeUserMessage("请继续回答")]
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        pump(seconds: 0.3)
        let id = KotlinUuid.companion.random()
        fixture.model.messages.append(makeAssistantMessage(id: id, text: "第一行", finished: false))
        fixture.model.send(.streamDelta)
        pump(seconds: 0.4)
        XCTAssertFalse(fixture.model.latestViewport.isContentScrollable)
        let scrollView = try XCTUnwrap(fixture.scrollView)
        let originalHeight = scrollView.contentSize.height
        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        fixture.model.messages[1] = makeAssistantMessage(id: id, text: "第一行\n\n第二行\n\n第三行", finished: false)
        fixture.model.send(.streamDelta)
        pump(seconds: 0.5)
        XCTAssertGreaterThan(scrollView.contentSize.height, originalHeight)
        XCTAssertFalse(fixture.model.latestViewport.isContentScrollable)
        XCTAssertEqual(ChatRenderProbe.counts["growth-transform"]?["all"] ?? 0, 0,
                       "内容未满屏时换行不能推动整个列表")

        let longText = String(repeating: "继续生成的一行内容。\n\n", count: 60)
        fixture.model.messages[1] = makeAssistantMessage(id: id, text: longText, finished: false)
        fixture.model.send(.streamDelta)
        XCTAssertTrue(pumpUntil(timeout: 5) { fixture.model.latestViewport.isContentScrollable })
        ChatRenderProbe.reset()
        XCTAssertTrue(pumpUntil(timeout: 3) { (ChatRenderProbe.counts["growth-transform"]?["all"] ?? 0) > 0 },
                      "内容超过视口后仍需恢复平滑生长")
    }

    func testFrameDriverRequests120HzDuringStreamingAndInteractions() throws {
        let driver = NativeTimelineScrollDriver()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        scrollView.contentSize = CGSize(width: 390, height: 1_400)
        scrollView.contentOffset.y = 600
        driver.attach(scrollView)
        defer { driver.invalidate() }
        driver.submit(.streamContentGrew())
        scrollView.contentSize.height += 100
        driver.handleLayoutMetricsChanged()
        XCTAssertEqual(driver.frameDriverRateForTesting?.preferred, 120,
                       "流式贴底位移不能硬限到 60Hz")
        XCTAssertEqual(driver.frameDriverRateForTesting?.maximum, 120)

        driver.handleKeyboardWillChangeFrame(duration: 0.25, curveRaw: 7)
        XCTAssertEqual(driver.frameDriverRateForTesting?.preferred, 120,
                       "已有 display link 也必须立即恢复键盘动画帧率")
        driver.handleKeyboardWillChangeFrame(duration: 0, curveRaw: 7)
        XCTAssertEqual(driver.frameDriverRateForTesting?.preferred, 120)

        driver.submit(.explicitBottom(source: .button, animated: true, keyboardToken: nil))
        scrollView.contentSize.height += 100
        driver.handleLayoutMetricsChanged()
        XCTAssertEqual(driver.frameDriverRateForTesting?.preferred, 120, "主动回底动画不能限到 60Hz")
        driver.submit(.generationTerminated)
        XCTAssertEqual(driver.frameDriverRateForTesting?.preferred, 120, "终态收敛也不属于流式降帧范围")
        driver.submit(.userDragBegan)
        XCTAssertNil(driver.frameDriverRateForTesting, "用户接管滚动后停止自动跟随时钟")
    }

    func testLiveTailSingleTokenAndChunkHeightGrowthLayoutMeasurements() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown(); ChatRenderProbe.enabled = false; ChatRenderProbe.reset() }
        let history = longConversation(turns: 6)
        let historicalIDs = Set(history.map { $0.id.toHexDashString() })
        fixture.model.messages = history + [makeUserMessage("继续搜索并整理回复")]
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        pump(seconds: 2.0)

        let id = KotlinUuid.companion.random()
        let liveID = id.toHexDashString()
        let seed = "## 连续正文\n\n" + String(repeating: "这是当前回复。", count: 5)
        fixture.model.messages.append(makeAssistantMessage(id: id, text: seed, finished: false))
        fixture.model.send(.streamDelta)
        pump(seconds: 2.0)

        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: id, text: seed + "续", finished: false
        )
        fixture.model.send(.streamDelta)
        pump(seconds: 0.3)
        ChatRenderProbe.enabled = false

        let singleTokenMeasures = ChatRenderProbe.counts["layout-measure"] ?? [:]
        let singleTokenHistorical = singleTokenMeasures.filter { historicalIDs.contains($0.key) }.values.reduce(0, +)
        let singleTokenCurrent = singleTokenMeasures[liveID] ?? 0
        print("[FANOUT-PROBE] single-token historical=\(singleTokenHistorical) current=\(singleTokenCurrent) all=\(singleTokenMeasures)")
        XCTAssertEqual(singleTokenHistorical, 0, "单字流式更新不得触发历史行重测")
        XCTAssertLessThanOrEqual(singleTokenCurrent, 3, "同行单字追加与淡入帧不得反复打穿当前行布局缓存")

        pump(seconds: 0.5)
        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: id,
            text: seed + "续\n\n" + String(repeating: "换行后的连续回复。", count: 8),
            finished: false
        )
        fixture.model.send(.streamDelta)
        pump(seconds: 0.3)
        ChatRenderProbe.enabled = false

        let chunkMeasures = ChatRenderProbe.counts["layout-measure"] ?? [:]
        let chunkHistorical = chunkMeasures.filter { historicalIDs.contains($0.key) }.values.reduce(0, +)
        let chunkCurrent = chunkMeasures[liveID] ?? 0
        print("[FANOUT-PROBE] newline-chunk historical=\(chunkHistorical) current=\(chunkCurrent) all=\(chunkMeasures)")
        XCTAssertEqual(chunkHistorical, 0, "换行流式更新不得触发历史行重测")
    }

    private struct ShellPreferenceContainer: View {
        @ObservedObject var model: HarnessModel
        let displaySetting: DisplaySetting
        let generativeUiSetting: GenerativeUiSetting
        let workspaceStore: IOSWorkspaceStore
        let artifactPinHandler: ChatArtifactPinHandler
        let completionFeedback: ChatCompletionFeedback

        @AppStorage(IOSAppearancePreferenceKeys.mode) private var appearanceMode = IOSAppearanceMode.system.rawValue
        @AppStorage(IOSAppLanguagePreference.defaultsKey) private var appLanguage = IOSAppLanguage.system.rawValue
        @AppStorage(IOSDisplayPreferenceKeys.followGeneration) private var followGeneration = true

        private var selectedLanguage: IOSAppLanguage {
            IOSAppLanguage(storedValue: appLanguage)
        }

        var body: some View {
            let _ = appearanceMode
            let _ = artifactPinHandler.action = { _, _, _, _ in }
            NativeChatTimelineView(
                signal: model.signal,
                timelineUpdates: model.timelineUpdates,
                configurationIssue: nil,
                isGenerationActive: model.isGenerationActive,
                usesIndependentTasks: model.usesIndependentTasks,
                activity: model.activity,
                isLoading: false,
                isRecognizingImages: false,
                contextCompactState: .idle,
                followGeneration: followGeneration,
                displaySetting: displaySetting,
                generativeUiSetting: generativeUiSetting,
                reasoningLevelLabel: nil,
                workspaceStore: workspaceStore,
                scrollToBottomTrigger: model.scrollToBottomTrigger,
                scrollToBottomSource: .button,
                messageAnchor: model.messageAnchor,
                currentConversationID: model.currentConversationID,
                messagesProvider: { [weak model] in model?.messages ?? [] },
                variantInfoProvider: { _ in nil },
                onAction: { _ in },
                onViewportStateChange: { [weak model] state in model?.recordViewport(state) },
                onDismissKeyboard: {}
            )
            .environment(\.locale, selectedLanguage.resolvedLocale())
            .environment(\.chatArtifactPinAction, artifactPinHandler)
            .environment(\.chatCompletionFeedback, completionFeedback)
            .tint(AmberTheme.accent)
        }
    }

    func testUnrelatedUserDefaultsAndNewRunFeedbackKeepSettledHistoryIntactWhileRealPreferenceChangesStillApply() throws {
        let defaults = UserDefaults.standard
        let unrelatedKey = "app.amber.tests.unrelated.\(UUID().uuidString)"
        let subAgentDisplayKey = "amber.ios.subagent.activity.display"
        let managedKeys = [
            IOSDisplayPreferenceKeys.fontScale,
            IOSDisplayPreferenceKeys.chatFont,
            IOSDisplayPreferenceKeys.agentName,
            IOSDisplayPreferenceKeys.completionHaptic,
            IOSAppLanguagePreference.defaultsKey,
            subAgentDisplayKey,
        ]
        let savedDefaults = Dictionary(uniqueKeysWithValues: managedKeys.map { ($0, defaults.object(forKey: $0)) })
        let savedPaper = AmberThemeRuntime.shared.paper
        var hapticEvents: [AmberHapticEvent] = []
        AmberHaptics.onTriggerForTesting = { hapticEvents.append($0) }
        defer {
            AmberHaptics.onTriggerForTesting = nil
            defaults.removeObject(forKey: unrelatedKey)
            for (key, value) in savedDefaults {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            IOSChatRenderPreferences.shared.syncFromDefaults(defaults)
            if AmberThemeRuntime.shared.paper != savedPaper {
                AmberThemeRuntime.shared.apply(savedPaper)
            }
            ChatRenderProbe.enabled = false
            ChatRenderProbe.reset()
        }

        defaults.set(1.0, forKey: IOSDisplayPreferenceKeys.fontScale)
        defaults.set(IOSChatFont.default.rawValue, forKey: IOSDisplayPreferenceKeys.chatFont)
        defaults.set(true, forKey: IOSDisplayPreferenceKeys.agentName)
        defaults.set(true, forKey: IOSDisplayPreferenceKeys.completionHaptic)
        defaults.set(IOSAppLanguage.simplifiedChinese.rawValue, forKey: IOSAppLanguagePreference.defaultsKey)
        IOSChatRenderPreferences.shared.syncFromDefaults(defaults)

        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let workspaceStore = IOSWorkspaceStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("TimelinePrefIsolation-\(UUID().uuidString)", isDirectory: true)
        )
        let model = HarnessModel()
        let pinHandler = ChatArtifactPinHandler()
        let completionFeedback = ChatCompletionFeedback()
        completionFeedback.setForegroundVisible(true)
        model.completionFeedback = completionFeedback

        var history: [UIMessage] = []
        for turn in 0..<8 {
            history.append(makeUserMessage("用户提问 \(turn)：请检查历史行的布局缓存稳定性。"))
            let markdown = """
            ### 历史回复 \(turn)

            - 保持已完成历史行在无关 `UserDefaults.standard` 写入下零重建。
            - 保持 `ChatTimelineRowLayout` 缓存命中而不被集体清空。

            ```swift
            let index = \(turn)
            ```
            """
            history.append(makeAssistantMessage(text: markdown, finished: true))
        }
        history.append(makeUserMessage("附上指标对照表"))
        history.append(makeAssistantMessage(
            text: "## 对照表\n\n| 阶段 | 历史重测 |\n| --- | --- |\n| 修复前 | 9 |\n| 修复后 | 0 |\n",
            finished: true
        ))

        let historicalUserIDs = Set(history.filter { $0.role == .user }.map { $0.id.toHexDashString() })
        let historicalAssistantIDs = Set(history.filter { $0.role == .assistant }.map { $0.id.toHexDashString() })
        let historicalAllIDs = historicalUserIDs.union(historicalAssistantIDs)
        let nonTailHistoricalAllIDs = Set(history.dropLast().map { $0.id.toHexDashString() })
        let nonTailHistoricalAssistantIDs = Set(history.dropLast().filter { $0.role == .assistant }.map { $0.id.toHexDashString() })
        let initialMessageIDs = history.map { $0.id.toHexDashString() }

        model.messages = history
        model.send(.initialLoad)
        model.timelineUpdates.publish(model.signal, messages: model.messages)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: ShellPreferenceContainer(
            model: model,
            displaySetting: sharedSettings.displaySetting,
            generativeUiSetting: sharedSettings.snapshot.agentRuntime.generativeUi,
            workspaceStore: workspaceStore,
            artifactPinHandler: pinHandler,
            completionFeedback: completionFeedback
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        XCTAssertTrue(pumpUntil(timeout: 5) { model.latestViewport.isAtBottom })
        pump(seconds: 1.5)

        func historicalProbeCounts(
            allIDs: Set<String> = historicalAllIDs,
            assistantIDs: Set<String> = historicalAssistantIDs,
            after seconds: TimeInterval = 0.25,
            _ block: () -> Void
        ) -> (
            message: Int,
            markdown: Int,
            layoutInvalidate: Int,
            layoutMeasure: Int
        ) {
            ChatRenderProbe.reset()
            ChatRenderProbe.enabled = true
            block()
            pump(seconds: seconds)
            ChatRenderProbe.enabled = false
            func sum(_ key: String, ids: Set<String>) -> Int {
                guard let map = ChatRenderProbe.counts[key] else { return 0 }
                return map.filter { ids.contains($0.key) }.values.reduce(0, +)
            }
            return (
                message: sum("message", ids: allIDs),
                markdown: sum("markdown", ids: assistantIDs),
                layoutInvalidate: sum("layout-invalidate", ids: allIDs),
                layoutMeasure: sum("layout-measure", ids: allIDs)
            )
        }

        let unrelatedCounts = historicalProbeCounts {
            defaults.set("noise-\(UUID().uuidString)", forKey: unrelatedKey)
            for step in 0..<3 {
                defaults.set(Data("subagent-\(step)-\(UUID().uuidString)".utf8), forKey: subAgentDisplayKey)
            }
        }
        XCTAssertEqual(unrelatedCounts.message, 0, "无关 UserDefaults 写入不得重建历史 MessageBubbleView")
        XCTAssertEqual(unrelatedCounts.markdown, 0, "无关 UserDefaults 写入不得重建历史 ChatAssistantMarkdownView")
        XCTAssertEqual(unrelatedCounts.layoutInvalidate, 0, "无关 UserDefaults 写入不得清空历史 ChatTimelineRowLayout 缓存")
        XCTAssertEqual(unrelatedCounts.layoutMeasure, 0, "无关 UserDefaults 写入不得重测历史行高度")

        let sameValueCounts = historicalProbeCounts {
            defaults.set(1.0, forKey: IOSDisplayPreferenceKeys.fontScale)
            defaults.set(IOSChatFont.default.rawValue, forKey: IOSDisplayPreferenceKeys.chatFont)
            defaults.set(true, forKey: IOSDisplayPreferenceKeys.agentName)
            defaults.set(IOSAppLanguage.simplifiedChinese.rawValue, forKey: IOSAppLanguagePreference.defaultsKey)
        }
        XCTAssertEqual(sameValueCounts.message, 0, "同值偏好写回不得重建历史消息视图")
        XCTAssertEqual(sameValueCounts.markdown, 0, "同值偏好写回不得重建历史 Markdown 视图")
        XCTAssertEqual(sameValueCounts.layoutInvalidate, 0, "同值偏好写回不得清空历史行布局缓存")
        XCTAssertEqual(sameValueCounts.layoutMeasure, 0, "同值偏好写回不得重测历史行高度")

        let newRunCounts = historicalProbeCounts {
            completionFeedback.begin(runID: "run-next-turn")
        }
        XCTAssertEqual(newRunCounts.message, 0, "新回合 begin(runID:) 不得重建历史消息视图")
        XCTAssertEqual(newRunCounts.markdown, 0, "新回合 begin(runID:) 不得穿透重建历史 Markdown 视图")
        XCTAssertEqual(newRunCounts.layoutInvalidate, 0, "新回合 begin(runID:) 不得清空历史行布局缓存")
        XCTAssertEqual(newRunCounts.layoutMeasure, 0, "新回合 begin(runID:) 不得重测历史行高度")

        // 新回合真实流式生成与收尾排空：除原末尾行因 `isLastMessage: true -> false` 变更 1 次外，
        // 其余已完成历史行保持零重建与零重测，新回复正常触发完成触感并保持贴底。
        let liveTurnNonTailCounts = historicalProbeCounts(
            allIDs: nonTailHistoricalAllIDs,
            assistantIDs: nonTailHistoricalAssistantIDs,
            after: 0.1
        ) {
            model.isGenerationActive = true
            model.messages.append(makeUserMessage("新回合提问"))
            model.send(.userAppend)
            model.timelineUpdates.publish(model.signal, messages: model.messages)
            pump(seconds: 0.08)

            let replyID = KotlinUuid.companion.random()
            let finalText = "这是新回合回复正文，验证流式排空后完成触感照常触发。"
            model.messages.append(makeAssistantMessage(id: replyID, text: "这是新回合回复", finished: false))
            model.send(.streamDelta)
            model.timelineUpdates.publish(model.signal, messages: model.messages)
            pump(seconds: 0.08)

            model.messages[model.messages.count - 1] = makeAssistantMessage(id: replyID, text: finalText, finished: true)
            model.isGenerationActive = false
            model.send(.generationCompleted)
            model.timelineUpdates.publish(model.signal, messages: model.messages)
            completionFeedback.complete(
                runID: "run-next-turn",
                messageID: replyID.toHexDashString(),
                textParts: [0: finalText]
            )
        }
        let previousTailID = try XCTUnwrap(history.last?.id.toHexDashString())
        XCTAssertEqual(liveTurnNonTailCounts.message, 0, "新回合发送与流式回复期间不得重建非末尾历史消息视图")
        XCTAssertEqual(liveTurnNonTailCounts.markdown, 0, "新回合发送与流式回复期间不得重建非末尾历史 Markdown 视图")
        XCTAssertEqual(liveTurnNonTailCounts.layoutInvalidate, 0, "新回合发送与流式回复期间不得清空非末尾历史行布局缓存")
        XCTAssertEqual(liveTurnNonTailCounts.layoutMeasure, 0, "新回合发送与流式回复期间不得重测非末尾历史行高度")
        XCTAssertLessThanOrEqual(ChatRenderProbe.counts["layout-measure"]?[previousTailID] ?? 0, 1)
        XCTAssertTrue(pumpUntil(timeout: 3.0) { hapticEvents == [.rigidImpact] }, "新回合可见尾文排空后仍须触发一次完成触感")
        XCTAssertTrue(pumpUntil(timeout: 2.0) { model.latestViewport.isAtBottom }, "新回合完成后须保持贴底锚定")
        XCTAssertEqual(Array(model.messages.prefix(history.count).map { $0.id.toHexDashString() }), initialMessageIDs)

        // 真实设置变更：字号、字体、语言与主题更新仍须正常传播并刷新对应视图/测量。
        let fontScaleCounts = historicalProbeCounts {
            defaults.set(1.18, forKey: IOSDisplayPreferenceKeys.fontScale)
        }
        XCTAssertGreaterThanOrEqual(fontScaleCounts.markdown, historicalAssistantIDs.count, "真实字号变更必须刷新历史 Markdown 视图")
        XCTAssertGreaterThanOrEqual(fontScaleCounts.layoutMeasure, historicalAllIDs.count, "真实字号变更必须重新测量行高")

        let chatFontCounts = historicalProbeCounts {
            defaults.set(IOSChatFont.serif.rawValue, forKey: IOSDisplayPreferenceKeys.chatFont)
        }
        XCTAssertGreaterThanOrEqual(chatFontCounts.markdown, historicalAssistantIDs.count, "真实字体切换必须刷新历史 Markdown 视图")
        XCTAssertGreaterThanOrEqual(chatFontCounts.layoutMeasure, historicalAllIDs.count, "真实字体切换必须重新测量行高")

        let languageCounts = historicalProbeCounts {
            defaults.set(IOSAppLanguage.english.rawValue, forKey: IOSAppLanguagePreference.defaultsKey)
        }
        XCTAssertGreaterThanOrEqual(languageCounts.message, historicalAssistantIDs.count, "真实语言切换必须刷新历史 Assistant 消息视图")

        let nextPaper: AmberThemeRuntime.Paper = savedPaper == .paper ? .neutral : .paper
        AmberThemeRuntime.shared.apply(nextPaper)
        pump(seconds: 0.15)
        XCTAssertEqual(AmberThemeRuntime.shared.paper, nextPaper)
        XCTAssertTrue(pumpUntil(timeout: 2.0) { model.latestViewport.isAtBottom })
    }

    func testLivePerfBlackboxSceneTagsTimingsAnd120HzFrameBudgetSummary() throws {
        let wasEnabled = ChatRenderProbe.enabled
        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        defer {
            ChatRenderProbe.enabled = wasEnabled
            ChatRenderProbe.reset()
        }

        // 1. 120Hz CADisplayLink range & 8.33ms frame budget excess calculation.
        let rateRange = AmberLivePerfFlightRecorder.preferredFrameRateRange120Hz
        XCTAssertEqual(rateRange.minimum, 120)
        XCTAssertEqual(rateRange.maximum, 120)
        XCTAssertEqual(rateRange.preferred, 120)
        XCTAssertEqual(AmberLivePerfFlightRecorder.frameBudget120HzMs, 1000.0 / 120.0, accuracy: 0.0001)
        if let liveRange = AmberLivePerfFlightRecorder.shared.displayLinkRateRangeForTesting {
            XCTAssertEqual(liveRange.minimum, 120)
            XCTAssertEqual(liveRange.maximum, 120)
            XCTAssertEqual(liveRange.preferred, 120)
        }

        var budget = AmberLivePerfFlightRecorder.FrameBudgetMetrics()
        budget.record(dtMs: 8.20)
        XCTAssertEqual(budget.overBudgetMs, 0, accuracy: 0.001)
        XCTAssertEqual(budget.stalledMs, 0, accuracy: 0.001)
        XCTAssertEqual(budget.drop12, 0)

        budget.record(dtMs: 8.50) // sub-vblank wakeup jitter (< 12.5ms)
        XCTAssertEqual(budget.overBudgetMs, 8.50 - (1000.0 / 120.0), accuracy: 0.001)
        XCTAssertEqual(budget.stalledMs, 0, accuracy: 0.001)
        XCTAssertEqual(budget.drop12, 0)

        budget.record(dtMs: 16.67) // 1 missed 120Hz vblank
        XCTAssertEqual(budget.drop12, 1)
        XCTAssertEqual(budget.stalledMs, 16.67 - (1000.0 / 120.0), accuracy: 0.001)

        budget.record(dtMs: 299.0) // keyboard-scale freeze frame
        XCTAssertEqual(budget.drop12, 2)
        XCTAssertEqual(
            budget.stalledMs,
            (16.67 - (1000.0 / 120.0)) + (299.0 - (1000.0 / 120.0)),
            accuracy: 0.001
        )

        // 2. Scene tags persist across multi-frame transitions and auto-expire safely.
        var drained: [String: Int] = [:]
        ChatRenderProbe.beginScene("scroll", ttlSeconds: 0.25)
        let value = ChatRenderProbe.measureUs("us:scroll-geometry") { 42 }
        XCTAssertEqual(value, 42)

        ChatRenderProbe.drainFrameDeltas(into: &drained, nowWall: CACurrentMediaTime())
        XCTAssertEqual(drained["scene:scroll"], 1)
        XCTAssertGreaterThanOrEqual(drained["us:scroll-geometry"] ?? 0, 1)

        // Next frame without new instantaneous probes still carries active scene tag.
        ChatRenderProbe.drainFrameDeltas(into: &drained, nowWall: CACurrentMediaTime() + 0.05)
        XCTAssertEqual(drained, ["scene:scroll": 1])

        XCTAssertTrue(ChatRenderProbe.endScene("scroll", spanKey: "ms:scroll-span", cpuKey: "ms:scroll-cpu"))
        ChatRenderProbe.drainFrameDeltas(into: &drained, nowWall: CACurrentMediaTime())
        XCTAssertEqual(drained["scene:scroll"], 1)
        XCTAssertGreaterThanOrEqual(drained["ms:scroll-span"] ?? 0, 1)

        // Subsequent frame after endScene is clean.
        ChatRenderProbe.drainFrameDeltas(into: &drained, nowWall: CACurrentMediaTime())
        XCTAssertTrue(drained.isEmpty)

        // TTL expiry keeps the starting frame tagged, then clears activeScenes so subsequent frames never stick.
        ChatRenderProbe.beginScene("keyboard-show", ttlSeconds: 0.05)
        ChatRenderProbe.drainFrameDeltas(into: &drained, nowWall: CACurrentMediaTime() + 0.20)
        XCTAssertEqual(drained["scene:keyboard-show"], 1)
        ChatRenderProbe.drainFrameDeltas(into: &drained, nowWall: CACurrentMediaTime() + 0.21)
        XCTAssertNil(drained["scene:keyboard-show"])

        // 3. Panel switch probe captures direction, first commit, and transition settle.
        ChatPanelSwitchPerfProbe.didSwitch(from: "chat", to: "tasks")
        XCTAssertEqual(ChatRenderProbe.counts["panel-switch:start"]?["all"], 1)
        XCTAssertEqual(ChatRenderProbe.counts["panel:chat->tasks"]?["all"], 1)
        pump(seconds: 0.05)
        XCTAssertGreaterThanOrEqual(ChatRenderProbe.counts["ms:panel-first-commit"]?["all"] ?? 0, 1)
        XCTAssertTrue(pumpUntil(timeout: 1.0) {
            (ChatRenderProbe.counts["panel-switch:end"]?["all"] ?? 0) == 1
        })
        XCTAssertGreaterThanOrEqual(ChatRenderProbe.counts["ms:panel-switch-span"]?["all"] ?? 0, 1)
    }

    func testP1SendFrameAndStructuralAppendBenchmark() throws {
        let rich26BlockMarkdown: String = {
            var blocks: [String] = [
                "# 检索与性能核查汇总",
                "本轮针对真机长会话中的**发送帧同步投影**与**旧末尾气泡失效重排**做了逐层拆解，以下为完整结构化记录。"
            ]
            for section in 1...6 {
                blocks.append("## 第 \(section) 节：多轮工具链路与布局证据")
                blocks.append("在第 \(section) 轮核查中，主线程耗时主要集中在跨语言消息部件桥接、轮次分组重算以及旧尾行 `isLastMessage` 翻转引发的子树重评估。")
                blocks.append("""
                - 指标 A\(section)：历史消息数增长至 139 条时，未变更消息被重复扫描
                - 指标 B\(section)：旧末尾 Markdown 块缓存因行级摘要变化被整体清空
                - 指标 C\(section)：工具输出 JSON 与思考摘要在结构事件中重复桥接
                """)
                blocks.append("""
                | 阶段 | 采样帧 \(section) | 复杂度 | 目标上限 |
                |------|------------|--------|----------|
                | 投影构建 | 130ms | O(N) | O(Δ) |
                | 尾行切换 | 58ms | O(blocks) | O(1) |
                """)
            }
            return blocks.joined(separator: "\n\n")
        }()

        func makeToolStepMessage(step: Int) -> UIMessage {
            let payload = String(repeating: "search_snippet_\(step)_verified_evidence ", count: 36)
            let toolA = UIMessagePart.Tool(
                toolCallId: "bench-tool-\(step)-a",
                toolName: "web_search",
                input: "{\"query\":\"amber ios timeline perf \(step)\"}",
                output: [UIMessagePart.Text(text: "{\"ok\":true,\"results\":\"\(payload)\"}", metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
            let toolB = UIMessagePart.Tool(
                toolCallId: "bench-tool-\(step)-b",
                toolName: "read_page",
                input: "{\"index\":\(step)}",
                output: [UIMessagePart.Text(text: "{\"status\":\"completed\",\"content\":\"\(payload)\"}", metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
            let now = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: Int64(1_730_000_000_000 + step * 1_000))
            let reasoning = UIMessagePart.Reasoning(
                reasoning: "正在交叉比对第 \(step) 组检索摘要与上下文约束。",
                createdAt: now,
                finishedAt: now,
                metadata: [:]
            )
            return UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [reasoning, toolA, toolB],
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: chatNowLocalDateTime(),
                modelId: nil,
                usage: nil,
                translation: nil
            )
        }

        var initialMessages: [UIMessage] = []
        initialMessages.reserveCapacity(118)
        for turn in 0..<23 {
            initialMessages.append(makeUserMessage("第 \(turn + 1) 轮：请检索并整理关键性能证据与边界条件"))
            initialMessages.append(makeToolStepMessage(step: turn * 3))
            initialMessages.append(makeToolStepMessage(step: turn * 3 + 1))
            initialMessages.append(makeToolStepMessage(step: turn * 3 + 2))
            let replyText = turn == 22
                ? rich26BlockMarkdown
                : "### 第 \(turn + 1) 轮结论\n\n已完成检索与归档，共核对 3 组工具调用输出与引用来源。\n\n- 状态：通过\n- 备注：保留完整上下文锚点"
            initialMessages.append(makeAssistantMessage(text: replyText, finished: true))
        }
        initialMessages.append(makeUserMessage("补充核查：确认第 24 轮基线状态"))
        initialMessages.append(makeToolStepMessage(step: 99))
        initialMessages.append(makeAssistantMessage(text: rich26BlockMarkdown, finished: true))
        XCTAssertEqual(initialMessages.count, 118)

        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            for orphan in scene.windows where orphan.isHidden {
                orphan.rootViewController = nil
                orphan.windowScene = nil
            }
        }
        let fixture = makeFixture { model in
            model.messages = initialMessages
            model.isGenerationActive = false
        }
        defer {
            fixture.tearDown()
            fixture.window.windowScene = nil
            ChatRenderProbe.enabled = false
            ChatRenderProbe.reset()
        }

        fixture.model.send(.initialLoad)
        pump(seconds: 2.5)
        XCTAssertTrue(pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom })

        func progress(_ title: String, anchor: String, kind: ChatActivityIslandState.Kind = .tool) -> ChatTimelineActivity {
            ChatTimelineActivity(
                anchorMessageID: anchor,
                hasAssistant: true,
                presentation: .activity(kind: kind, title: title, systemImage: "magnifyingglass", tint: .amber),
                tool: nil,
                taskSlot: nil,
                plannedStages: [],
                stagePlanStartedUptime: nil,
                liveReasoningSummary: nil,
                tracksTaskLiveness: false,
                showsThought: false
            )
        }

        struct FrameSample {
            let label: String
            let syncCPUMs: Double
            let syncWallMs: Double
            let settleCPUMs: Double
            let settleWallMs: Double
            let oldTailMessageCount: Int
            let oldTailMarkdownCount: Int
            let oldTailLayoutInvalidateCount: Int
            let oldTailLayoutMeasureCount: Int
            let totals: [String: Int]
        }

        func measureStep(
            _ label: String,
            oldTailID: String,
            settleSeconds: TimeInterval,
            mutate: () -> Void
        ) -> FrameSample {
            ChatRenderProbe.reset()
            ChatRenderProbe.enabled = true
            let wallStart = ProcessInfo.processInfo.systemUptime
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            mutate()
            fixture.host.view.setNeedsLayout()
            fixture.host.view.layoutIfNeeded()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
            fixture.host.view.layoutIfNeeded()
            let syncCPUMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
            let syncWallMs = (ProcessInfo.processInfo.systemUptime - wallStart) * 1_000
            if settleSeconds > 0 {
                pump(seconds: settleSeconds)
            }
            let settleCPUMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
            let settleWallMs = (ProcessInfo.processInfo.systemUptime - wallStart) * 1_000
            ChatRenderProbe.enabled = false

            let counts = ChatRenderProbe.counts
            return FrameSample(
                label: label,
                syncCPUMs: syncCPUMs,
                syncWallMs: syncWallMs,
                settleCPUMs: settleCPUMs,
                settleWallMs: settleWallMs,
                oldTailMessageCount: counts["message"]?[oldTailID] ?? 0,
                oldTailMarkdownCount: counts["markdown"]?[oldTailID] ?? 0,
                oldTailLayoutInvalidateCount: counts["layout-invalidate"]?[oldTailID] ?? 0,
                oldTailLayoutMeasureCount: counts["layout-measure"]?[oldTailID] ?? 0,
                totals: counts.mapValues { $0.values.reduce(0, +) }
            )
        }

        let staticTailID = initialMessages[initialMessages.count - 1].id.toHexDashString()
        let send119User = makeUserMessage("第 25 轮提问：继续深挖发送帧同步投影与尾行隔离")
        let anchor119 = send119User.id.toHexDashString()
        let sendStaticSample = measureStep("user-send-119-static-tail", oldTailID: staticTailID, settleSeconds: 0.20) {
            fixture.model.isGenerationActive = true
            fixture.model.activity = progress("正在搜索网页", anchor: anchor119)
            fixture.model.messages.append(send119User)
            fixture.model.send(.userAppend)
        }

        var toolAppendSamples: [FrameSample] = []
        for offset in 0..<18 {
            let prevTailID = fixture.model.messages[fixture.model.messages.count - 1].id.toHexDashString()
            let stepMsg = makeToolStepMessage(step: 200 + offset)
            let sample = measureStep("tool-append-\(120 + offset)", oldTailID: prevTailID, settleSeconds: 0.05) {
                fixture.model.messages.append(stepMsg)
                fixture.model.activity = progress(offset.isMultiple(of: 2) ? "正在核对网页" : "正在思考", anchor: anchor119)
                fixture.model.send(.toolResultAppended)
            }
            toolAppendSamples.append(sample)
        }

        // 第 138 条消息：完整走真实流式生成 -> assistantStreamClosed -> generationCompleted -> 排空稳定
        let streamedReplyID = KotlinUuid.companion.random()
        let streamedTailID = streamedReplyID.toHexDashString()
        fixture.model.messages.append(makeAssistantMessage(id: streamedReplyID, text: "", finished: false))
        fixture.model.activity = progress("正在整理回复", anchor: anchor119, kind: .generating)
        let chars = Array(rich26BlockMarkdown)
        let strideStep = max(64, chars.count / 24)
        for end in stride(from: strideStep, through: chars.count + strideStep - 1, by: strideStep) {
            fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
                id: streamedReplyID,
                text: String(chars.prefix(min(end, chars.count))),
                finished: false
            )
            fixture.model.send(.streamDelta)
            pump(seconds: 0.02)
        }
        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: streamedReplyID,
            text: rich26BlockMarkdown,
            finished: true
        )
        fixture.model.send(.assistantStreamClosed)
        pump(seconds: 0.3)

        let completionSample = measureStep("generation-completed-138", oldTailID: streamedTailID, settleSeconds: 0.20) {
            fixture.model.isGenerationActive = false
            fixture.model.activity = nil
            fixture.model.send(.generationCompleted)
        }
        pump(seconds: 1.8)
        XCTAssertEqual(fixture.model.messages.count, 138)
        XCTAssertTrue(pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom })

        // 第 139 条消息（核心指标 user-send-139）：在刚完成流式生成的 26-block Markdown 尾行之后点击发送
        let send139User = makeUserMessage("第 26 轮提问：验证发送帧主线程耗时是否压到 50ms 以下且旧尾行 Markdown 零失效")
        let anchor139 = send139User.id.toHexDashString()
        let send139Sample = measureStep("user-send-139-streamed-tail", oldTailID: streamedTailID, settleSeconds: 0.20) {
            fixture.model.isGenerationActive = true
            fixture.model.activity = progress("正在搜索网页", anchor: anchor139)
            fixture.model.messages.append(send139User)
            fixture.model.send(.userAppend)
        }
        XCTAssertEqual(fixture.model.messages.count, 139)

        let toolSyncAvg = toolAppendSamples.map(\.syncCPUMs).reduce(0, +) / Double(toolAppendSamples.count)
        let toolSettleAvg = toolAppendSamples.map(\.settleCPUMs).reduce(0, +) / Double(toolAppendSamples.count)
        let toolSettleMax = toolAppendSamples.map(\.settleCPUMs).max() ?? 0

        print(String(
            format: "[P1-BENCH] %@ syncCPU=%.2fms syncWall=%.2fms settle200CPU=%.2fms settle200Wall=%.2fms oldTail(msg=%d,md=%d,layInv=%d,layMeas=%d) totals=%@",
            sendStaticSample.label,
            sendStaticSample.syncCPUMs,
            sendStaticSample.syncWallMs,
            sendStaticSample.settleCPUMs,
            sendStaticSample.settleWallMs,
            sendStaticSample.oldTailMessageCount,
            sendStaticSample.oldTailMarkdownCount,
            sendStaticSample.oldTailLayoutInvalidateCount,
            sendStaticSample.oldTailLayoutMeasureCount,
            String(describing: sendStaticSample.totals)
        ))
        print(String(
            format: "[P1-BENCH] tool-append(x%d) syncCPUAvg=%.2fms settle50CPUAvg=%.2fms settle50CPUMax=%.2fms",
            toolAppendSamples.count,
            toolSyncAvg,
            toolSettleAvg,
            toolSettleMax
        ))
        print(String(
            format: "[P1-BENCH] %@ syncCPU=%.2fms settle200CPU=%.2fms oldTail(msg=%d,md=%d,layInv=%d,layMeas=%d)",
            completionSample.label,
            completionSample.syncCPUMs,
            completionSample.settleCPUMs,
            completionSample.oldTailMessageCount,
            completionSample.oldTailMarkdownCount,
            completionSample.oldTailLayoutInvalidateCount,
            completionSample.oldTailLayoutMeasureCount
        ))
        print(String(
            format: "[P1-BENCH] %@ syncCPU=%.2fms syncWall=%.2fms settle200CPU=%.2fms settle200Wall=%.2fms oldTail(msg=%d,md=%d,layInv=%d,layMeas=%d) totals=%@",
            send139Sample.label,
            send139Sample.syncCPUMs,
            send139Sample.syncWallMs,
            send139Sample.settleCPUMs,
            send139Sample.settleWallMs,
            send139Sample.oldTailMessageCount,
            send139Sample.oldTailMarkdownCount,
            send139Sample.oldTailLayoutInvalidateCount,
            send139Sample.oldTailLayoutMeasureCount,
            String(describing: send139Sample.totals)
        ))

        XCTAssertLessThan(sendStaticSample.syncCPUMs, 50.0, "静态尾行发送帧同步主线程耗时必须低于 50ms")
        XCTAssertEqual(sendStaticSample.oldTailMessageCount, 0, "静态尾行退为历史行时不得重算 MessageBubble")
        XCTAssertEqual(sendStaticSample.oldTailMarkdownCount, 0, "静态尾行退为历史行时不得重建 Markdown")
        XCTAssertEqual(sendStaticSample.oldTailLayoutInvalidateCount, 0, "静态尾行退为历史行时不得触发布局失效")
        XCTAssertEqual(sendStaticSample.oldTailLayoutMeasureCount, 0, "静态尾行退为历史行时不得触发重新测量")

        XCTAssertLessThan(send139Sample.syncCPUMs, 50.0, "流式完结尾行发送帧同步主线程耗时必须低于 50ms")
        XCTAssertEqual(send139Sample.oldTailMessageCount, 0, "流式完结尾行退为历史行时不得重算 MessageBubble")
        XCTAssertEqual(send139Sample.oldTailMarkdownCount, 0, "流式完结尾行退为历史行时不得重建 Markdown")
        XCTAssertEqual(send139Sample.oldTailLayoutInvalidateCount, 0, "流式完结尾行退为历史行时不得触发布局失效")
        XCTAssertEqual(send139Sample.oldTailLayoutMeasureCount, 0, "流式完结尾行退为历史行时不得触发重新测量")
    }

    func testP1IncrementalProjectionMatchesFullBuildAndSkipsHistoricalBridging() {
        let cache = NativeTimelineProjectionCache()
        let fullHashes = ChatRowContentHashCache()
        let cachedHashes = ChatRowContentHashCache()
        let fullStore = ChatRenderStateStore()
        let cachedStore = ChatRenderStateStore()

        var messages: [UIMessage] = []
        for turn in 0..<24 {
            messages.append(makeUserMessage("历史提问 \(turn)"))
            let tool = UIMessagePart.Tool(
                toolCallId: "hist-tool-\(turn)",
                toolName: "search_web",
                input: #"{"q":"\#(turn)"}"#,
                output: [UIMessagePart.Text(text: "结果 \(turn)", metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
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
            messages.append(makeAssistantMessage(text: "历史回答 \(turn)", finished: true))
        }
        XCTAssertEqual(messages.count, 72)

        let windowStart = 12
        var revision = 0
        var streamed: Set<String> = []
        var requestedIndices: [Int] = []
        var previousFullProjection: NativeTimelineProjection?

        func verifyStep(_ event: ChatEvent, isGenerationActive: Bool, expectIncrementalFrom minIndex: Int?) {
            revision += 1
            requestedIndices = []
            let incremental = cache.projection(
                messages: messages,
                event: event,
                sourceRevision: revision,
                startIndex: windowStart,
                configurationIssue: nil,
                isGenerationActive: isGenerationActive,
                isLoading: false,
                isRecognizingImages: false,
                contextCompactState: .idle,
                contextCompactBoundaries: [],
                viewportState: ChatViewportState(),
                displaySettingSignature: 42,
                generativeUiSettingSignature: 7,
                renderStateRevision: 1,
                reasoningLevelLabel: "High",
                streamedMessageIDs: streamed,
                renderStateStore: cachedStore,
                variantInfoProvider: { index in
                    requestedIndices.append(index)
                    return nil
                },
                contentHashProvider: { row, streaming in
                    streaming ? cachedHashes.streamingTailLayoutToken(for: row) : cachedHashes.contentHash(for: row)
                }
            )
            let full = NativeTimelineProjector.build(
                messages: messages,
                event: event,
                isGenerationActive: isGenerationActive,
                viewportState: ChatViewportState(),
                displaySettingSignature: 42,
                generativeUiSettingSignature: 7,
                renderStateRevision: 1,
                reasoningLevelLabel: "High",
                streamedMessageIDs: streamed,
                renderStateStore: fullStore,
                variantInfoProvider: { _ in nil },
                contentHashProvider: { row, streaming in
                    streaming ? fullHashes.streamingTailLayoutToken(for: row) : fullHashes.contentHash(for: row)
                },
                startIndex: windowStart
            )
            if event == .assistantStreamDelta,
               let prevFull = previousFullProjection,
               let expectedFastTail = NativeTimelineProjector.replacingStreamingTail(
                   in: prevFull,
                   messages: messages,
                   event: event,
                   isGenerationActive: isGenerationActive,
                   viewportState: ChatViewportState(),
                   displaySettingSignature: 42,
                   generativeUiSettingSignature: 7,
                   renderStateRevision: 1,
                   reasoningLevelLabel: "High",
                   streamedMessageIDs: streamed,
                   renderStateStore: fullStore,
                   variantInfoProvider: { _ in nil },
                   contentHashProvider: { row, streaming in
                       streaming ? fullHashes.streamingTailLayoutToken(for: row) : fullHashes.contentHash(for: row)
                   }
               ) {
                XCTAssertEqual(incremental, expectedFastTail, "流式同尾 delta 必须与 replacingStreamingTail 快速路径完全一致")
                if let lastMsgIdx = incremental.entries.lastIndex(where: { $0.kind == .message }) {
                    XCTAssertEqual(Array(incremental.entries[..<lastMsgIdx]), Array(full.entries[..<lastMsgIdx]))
                    XCTAssertEqual(Array(incremental.entries[(lastMsgIdx + 1)...]), Array(full.entries[(lastMsgIdx + 1)...]))
                    XCTAssertEqual(incremental.entries[lastMsgIdx].assistantTurn, full.entries[lastMsgIdx].assistantTurn)
                    XCTAssertEqual(incremental.entries[lastMsgIdx].renderDigest, full.entries[lastMsgIdx].renderDigest)
                }
            } else {
                XCTAssertEqual(incremental, full, "事件 \(event) 下增量投影必须与全量投影逐字段完全一致")
            }
            previousFullProjection = full
            if let minIndex {
                XCTAssertTrue(
                    requestedIndices.allSatisfy { $0 >= minIndex },
                    "事件 \(event) 仅允许重投当前活跃轮次(>=\(minIndex))，实际请求索引: \(requestedIndices)"
                )
            }
        }

        // 1. 初始全量建立缓存（前轮 user 位于索引 69）
        verifyStep(.conversationLoaded, isGenerationActive: false, expectIncrementalFrom: nil)
        XCTAssertEqual(requestedIndices.count, 60)

        // 2. 用户发送新消息（索引 72）：旧尾行位于 71，分界点为索引 69 的 user 行
        let sendIndex = messages.count
        messages.append(makeUserMessage("增量投影验证提问"))
        verifyStep(.userMessageAppended, isGenerationActive: true, expectIncrementalFrom: 69)

        // 3. 连续追加工具消息（分界点推进到索引 72 的新 user 行）
        for step in 0..<3 {
            let tool = UIMessagePart.Tool(
                toolCallId: "inc-tool-\(step)",
                toolName: "terminal_execute",
                input: "{}",
                output: [UIMessagePart.Text(text: "ok-\(step)", metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
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
            verifyStep(.toolResultAppended, isGenerationActive: true, expectIncrementalFrom: sendIndex)
        }

        // 4. 流式回复首次挂载 -> delta -> 收口 -> 完成 -> 下一轮发送
        let replyID = KotlinUuid.companion.random()
        let replyHex = replyID.toHexDashString()
        streamed.insert(replyHex)
        messages.append(makeAssistantMessage(id: replyID, text: "首段流式内容", finished: false))
        verifyStep(.assistantStreamDelta, isGenerationActive: true, expectIncrementalFrom: sendIndex)

        messages[messages.count - 1] = makeAssistantMessage(id: replyID, text: "首段流式内容，继续补充正文。", finished: false)
        verifyStep(.assistantStreamDelta, isGenerationActive: true, expectIncrementalFrom: messages.count - 1)

        messages[messages.count - 1] = makeAssistantMessage(id: replyID, text: "首段流式内容，继续补充正文。", finished: true)
        verifyStep(.assistantStreamClosed, isGenerationActive: true, expectIncrementalFrom: sendIndex)

        verifyStep(.generationCompleted, isGenerationActive: false, expectIncrementalFrom: sendIndex)

        messages.append(makeUserMessage("下一轮继续提问"))
        verifyStep(.userMessageAppended, isGenerationActive: true, expectIncrementalFrom: sendIndex)
    }

    @MainActor
    private final class BubbleIsolationState: ObservableObject {
        @Published var isLastMessage = true
        @Published var liveRenderingEnabled = true
        @Published var isChatGenerationActive = false
    }

    private struct BubbleIsolationHarness: View {
        let message: UIMessage
        let workspaceStore: IOSWorkspaceStore
        @ObservedObject var state: BubbleIsolationState

        var body: some View {
            MessageBubbleView(
                message: message,
                messageIndex: 10,
                isAssistantContinuation: false,
                variantInfo: nil,
                displaySetting: nil,
                generativeUiSetting: nil,
                onRegenerate: {},
                onRequestEdit: { _ in },
                onEdit: { _ in },
                onDelete: {},
                onSelectVariant: { _ in },
                onGenerativeWidgetAction: { _ in },
                onModifyGeneratedImage: { _, _, _ in },
                onOpenMiniApp: { _ in },
                onOpenMiniApps: {},
                isGenerating: false,
                isChatGenerationActive: state.isChatGenerationActive,
                isLastMessage: state.isLastMessage,
                hasEverStreamed: true,
                liveMarkdownRenderingEnabled: state.liveRenderingEnabled,
                frozenMarkdownSnapshot: nil,
                reasoningLevelLabel: nil
            )
            .environment(workspaceStore)
        }
    }

    func testP1MessageBubbleViewIsolatesIsLastMessageTransitionFromMarkdownAndBody() throws {
        let message = makeAssistantMessage(
            text: "### 标题\n\n这里是一段包含 `inline code` 与列表的完整回复：\n\n- 第一项\n- 第二项",
            finished: true
        )
        let messageID = message.id.toHexDashString()
        let state = BubbleIsolationState()
        let workspaceStore = IOSWorkspaceStore()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: BubbleIsolationHarness(
            message: message,
            workspaceStore: workspaceStore,
            state: state
        ))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            ChatRenderProbe.enabled = false
            ChatRenderProbe.reset()
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
            previousWindow?.makeKey()
        }
        pump(seconds: 0.3)

        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        state.isLastMessage = false
        state.liveRenderingEnabled = false
        state.isChatGenerationActive = true
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        pump(seconds: 0.2)
        ChatRenderProbe.enabled = false

        XCTAssertEqual(ChatRenderProbe.counts["message"]?[messageID] ?? 0, 0,
                       "已完结气泡翻转 isLastMessage/liveRenderingEnabled 时不得重算正文子树")
        XCTAssertEqual(ChatRenderProbe.counts["markdown"]?[messageID] ?? 0, 0,
                       "已完结气泡翻转 isLastMessage/liveRenderingEnabled 时不得重建 Markdown")
    }
}
