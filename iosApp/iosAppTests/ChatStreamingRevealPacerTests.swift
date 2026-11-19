import Combine
@preconcurrency import Shared
import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class ChatStreamingRevealPacerTests: XCTestCase {
    private final class Stream: ObservableObject {
        @Published var text: String
        @Published var isStreaming = true
        @Published var reduceMotion = false

        init(text: String) {
            self.text = text
        }
    }

    private struct Fixture: View {
        @ObservedObject var stream: Stream

        var body: some View {
            ChatStreamingRevealPacer(
                text: stream.text,
                isStreaming: stream.isStreaming,
                reduceMotion: stream.reduceMotion
            ) { revealedText in
                ChatAssistantMarkdownView(
                    markdown: revealedText,
                    isStreaming: stream.isStreaming,
                    hasEverStreamed: true
                )
            }
            .frame(width: 361)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    func testTextAppendedAfterTableKeepsPacingThroughStreamCompletion() async throws {
        let table = """
        | 方案 | 说明 |
        | --- | --- |
        | A | 表格已经显示 |
        """
        let stream = Stream(text: table)
        let host = UIHostingController(rootView: Fixture(stream: stream))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        try await waitUntil(host: host) { self.tableScrollView(in: host.view) != nil }

        // A real provider may send a whole paragraph in one delta after its table.
        // The terminal event must drain this same paragraph at the original rate.
        let tail = "收尾正文：" + String(repeating: "表后正文继续按原速逐字显示，不能整段跳出。", count: 20) + "全文结束标记"
        stream.text = table + "\n\n" + tail
        try await pump(host: host, milliseconds: 300)

        let receivingText = paragraphText(in: host.view)
        XCTAssertTrue(receivingText.contains("收尾正文："), "表后普通正文必须开始显示")
        XCTAssertFalse(receivingText.contains("全文结束标记"), "检测到表格不能让后续正文绕过逐字节奏")

        stream.isStreaming = false
        try await pump(host: host, milliseconds: 200)
        let drainingText = paragraphText(in: host.view)
        XCTAssertGreaterThan(drainingText.count, receivingText.count, "网络流结束后继续按原节奏排空")
        XCTAssertFalse(drainingText.contains("全文结束标记"), "终态不能一次性刷出尚未显示的正文")

        try await waitUntil(host: host) { self.paragraphText(in: host.view).contains("全文结束标记") }
        XCTAssertEqual(paragraphText(in: host.view), tail, "收尾必须完整保留普通正文")
    }

    func testFinalSnapshotTextAfterTableDrainsAndRespectsReduceMotion() async throws {
        let introduction = "已经显示的介绍正文应保持稳定。"
        let table = """
        | 方案 | 说明 |
        | --- | --- |
        | A | 表格已经显示 |
        """
        let stream = Stream(text: introduction + "\n\n" + table)
        let host = UIHostingController(rootView: Fixture(stream: stream))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitUntil(host: host) { self.tableScrollView(in: host.view) != nil }

        let tail = "最终快照正文：" + String(repeating: "最终快照新增的尾文也需要逐字排空。", count: 20) + "最终快照结尾"
        stream.text += "\n\n" + tail
        stream.isStreaming = false
        try await pump(host: host, milliseconds: 300)

        let drainingText = paragraphText(in: host.view)
        XCTAssertTrue(drainingText.hasPrefix(introduction), "切换分块 pacing 不得重播稳定介绍正文")
        XCTAssertTrue(drainingText.contains("最终快照正文："))
        XCTAssertFalse(drainingText.contains("最终快照结尾"), "最终快照新出现的 text block 也必须排空")

        stream.reduceMotion = true
        try await pump(host: host, milliseconds: 150)
        XCTAssertEqual(paragraphText(in: host.view), introduction + tail, "减弱动画应立即给出完整内容")
    }

    func testFirstStreamingChunkContainingTableAndLongTailPacesTheTail() async throws {
        let table = """
        | 方案 | 说明 |
        | --- | --- |
        | A | 首个 chunk 即包含完整表格 |
        """
        let tail = "首块正文：" + String(repeating: "首个大块里的表后正文也必须逐字显示。", count: 20) + "首块结尾标记"
        let stream = Stream(text: table + "\n\n" + tail)
        let host = UIHostingController(rootView: Fixture(stream: stream))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await pump(host: host, milliseconds: 300)

        let receivingText = paragraphText(in: host.view)
        XCTAssertTrue(receivingText.contains("首块正文："))
        XCTAssertFalse(receivingText.contains("首块结尾标记"), "首快照中的 tail 不能误判成已经显示的正文")
    }

    func testPlainStreamingProseUsesDirectAppendInsteadOfPerTickMarkdownReparse() async throws {
        let initialPrefix = "直接追加验证："
        let prose = initialPrefix + String(repeating: "这是一段连续纯文本流式输出，期间没有任何块级或行内语法切换。", count: 6) + "收尾完成"
        let stream = Stream(text: initialPrefix)
        let host = UIHostingController(rootView: Fixture(stream: stream))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            ChatRenderProbe.enabled = false
            ChatRenderProbe.reset()
            window.isHidden = true
            window.rootViewController = nil
        }

        host.view.layoutIfNeeded()
        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        stream.text = prose
        try await pump(host: host, milliseconds: 480)
        stream.isStreaming = false
        try await waitUntil(host: host) { self.paragraphText(in: host.view).contains("收尾完成") }
        let counts = ChatRenderProbe.counts
        ChatRenderProbe.enabled = false

        XCTAssertEqual(paragraphText(in: host.view), prose)
        let ticks = counts["pacer-tick"]?.values.reduce(0, +) ?? 0
        let directAppends = counts["pacer-direct-append"]?.values.reduce(0, +) ?? 0
        let mdSchedules = counts["md-schedule"]?.values.reduce(0, +) ?? 0
        XCTAssertGreaterThan(ticks, 20)
        XCTAssertGreaterThan(directAppends, ticks / 2, "纯文本吐字应主要由直接追加承载")
        XCTAssertLessThanOrEqual(mdSchedules, ticks / 3, "纯文本吐字仅在折行或收尾时同步前缀，不应每拍触发 Markdown 重解析（实际 md-schedule=\(mdSchedules), ticks=\(ticks)）")
    }

    func testDirectAppendReparsesInlineStrongAndParagraphBoundariesCleanly() async throws {
        let markdown = "前导纯文本连续吐字后遇到**加粗重点**继续纯文本。\n\n第二段继续平滑显示直到结尾标记。"
        let stream = Stream(text: markdown)
        let host = UIHostingController(rootView: Fixture(stream: stream))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        try await pump(host: host, milliseconds: 240)
        stream.isStreaming = false
        try await waitUntil(host: host) { self.paragraphText(in: host.view).contains("结尾标记。") }

        let expectedVisible = "前导纯文本连续吐字后遇到加粗重点继续纯文本。\n第二段继续平滑显示直到结尾标记。"
        XCTAssertEqual(paragraphText(in: host.view), expectedVisible)
    }

    func testReplyDeliveryModeDefaultsToLiveStreamingAndPersistsSegmentedSetting() {
        let defaults = UserDefaults.standard
        let key = IOSDisplayPreferenceKeys.replyDeliveryMode
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            IOSChatRenderPreferences.shared.syncFromDefaults(defaults)
        }

        defaults.removeObject(forKey: key)
        IOSChatRenderPreferences.shared.syncFromDefaults(defaults)
        XCTAssertEqual(IOSChatReplyDeliveryMode.default, .liveStreaming)
        XCTAssertEqual(IOSChatRenderPreferences.shared.replyDeliveryMode, IOSChatReplyDeliveryMode.liveStreaming.rawValue)
        XCTAssertFalse(IOSChatRenderPreferences.shared.isSegmentedReplyDelivery, "默认必须保持实时流式")

        defaults.set(IOSChatReplyDeliveryMode.segmentedBlocks.rawValue, forKey: key)
        IOSChatRenderPreferences.shared.syncFromDefaults(defaults)
        XCTAssertEqual(defaults.string(forKey: key), IOSChatReplyDeliveryMode.segmentedBlocks.rawValue)
        XCTAssertEqual(IOSChatRenderPreferences.shared.replyDeliveryMode, IOSChatReplyDeliveryMode.segmentedBlocks.rawValue)
        XCTAssertTrue(IOSChatRenderPreferences.shared.isSegmentedReplyDelivery, "切换分段呈现后必须持久化并同步到渲染偏好")
    }

    func testSegmentedCommitPolicyHoldsIncompleteParagraphsLongParagraphsAndCodeBlocksUntilBoundaryAndFlushesAtEnd() {
        // 1. 未完成句与单换行未完成段落不提交
        XCTAssertEqual(
            ChatSegmentedMarkdownCommitPolicy.committedPrefix(in: "这是一句还在生成中的话", isStreaming: true),
            ""
        )
        XCTAssertEqual(
            ChatSegmentedMarkdownCommitPolicy.committedPrefix(in: "第一行文字\n第二行仍在同一段落中未结束", isStreaming: true),
            ""
        )

        // 2. 完整段落按原文在空行边界提交，未完成尾段暂存
        let twoParagraphsWithPartialTail = "第一段完整内容。\n\n第二段完整内容。\n\n第三段还在生成中"
        XCTAssertEqual(
            ChatSegmentedMarkdownCommitPolicy.committedPrefix(in: twoParagraphsWithPartialTail, isStreaming: true),
            "第一段完整内容。\n\n第二段完整内容。"
        )

        // 3. 长段落不硬切：即使远超软目标字数，未到自然段落边界前绝不从中间截断
        let longParagraph = String(repeating: "长段落不设硬字数切割必须等待自然结构边界完成后一次性完整显示。", count: 12)
        XCTAssertGreaterThan(longParagraph.count, 300)
        XCTAssertEqual(
            ChatSegmentedMarkdownCommitPolicy.committedPrefix(
                in: "导语段落。\n\n" + longParagraph,
                isStreaming: true
            ),
            "导语段落。"
        )
        XCTAssertEqual(
            ChatSegmentedMarkdownCommitPolicy.committedPrefix(
                in: "导语段落。\n\n" + longParagraph + "\n\n尾段半截",
                isStreaming: true
            ),
            "导语段落。\n\n" + longParagraph
        )

        // 4. 代码块不碎：围栏代码块内部即使有空行也绝不中途提交，闭合围栏换行后一次提交
        let openCodeBlock = """
        说明段落。

        ```swift
        func compute() -> Int {

            let a = 1

            return a + 2
        }
        """
        XCTAssertEqual(
            ChatSegmentedMarkdownCommitPolicy.committedPrefix(in: openCodeBlock, isStreaming: true),
            "说明段落。"
        )

        let closedCodeBlockWithTail = openCodeBlock + "\n```\n\n收尾段落还未写完"
        let expectedClosedCode = openCodeBlock + "\n```"
        XCTAssertEqual(
            ChatSegmentedMarkdownCommitPolicy.committedPrefix(in: closedCodeBlockWithTail, isStreaming: true),
            expectedClosedCode
        )

        // 5. 结束 flush：流式结束时排空全部剩余缓冲，最终文本与源完全一致
        XCTAssertEqual(
            ChatSegmentedMarkdownCommitPolicy.committedPrefix(in: closedCodeBlockWithTail, isStreaming: false),
            closedCodeBlockWithTail
        )
    }

    func testSegmentedDeliveryModeCommitsCompletedParagraphsAndFlushesFinalTextInView() async throws {
        let defaults = UserDefaults.standard
        let key = IOSDisplayPreferenceKeys.replyDeliveryMode
        let previous = defaults.object(forKey: key)
        defaults.set(IOSChatReplyDeliveryMode.segmentedBlocks.rawValue, forKey: key)
        IOSChatRenderPreferences.shared.syncFromDefaults(defaults)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            IOSChatRenderPreferences.shared.syncFromDefaults(defaults)
        }

        let stream = Stream(text: "第一段未完成前缀")
        let host = UIHostingController(rootView: Fixture(stream: stream))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        try await pump(host: host, milliseconds: 120)
        XCTAssertEqual(paragraphText(in: host.view), "", "分段呈现下未完成首段不得提前上屏")

        stream.text = "第一段完整落定。\n\n第二段正在生成但尚未闭合"
        try await waitUntil(host: host) { self.paragraphText(in: host.view).contains("第一段完整落定。") }
        XCTAssertEqual(paragraphText(in: host.view), "第一段完整落定。", "仅已完成段落上屏，未闭合尾段保持缓冲")

        let finalSource = "第一段完整落定。\n\n第二段正在生成但尚未闭合，现已收尾完成。"
        stream.text = finalSource
        stream.isStreaming = false
        try await waitUntil(host: host) { self.paragraphText(in: host.view).contains("现已收尾完成。") }
        XCTAssertEqual(
            paragraphText(in: host.view),
            "第一段完整落定。第二段正在生成但尚未闭合，现已收尾完成。",
            "结束 flush 后两段完整正文必须全部上屏且与源内容一致"
        )
    }

    func testSegmentedBubbleStaysHiddenUntilFirstRenderableBlockIsReadyAndSubsequentBlocksNeverFlashEmpty() async throws {
        let defaults = UserDefaults.standard
        let key = IOSDisplayPreferenceKeys.replyDeliveryMode
        let previous = defaults.object(forKey: key)
        defaults.set(IOSChatReplyDeliveryMode.segmentedBlocks.rawValue, forKey: key)
        IOSChatRenderPreferences.shared.syncFromDefaults(defaults)
        ChatSegmentedBubbleReadiness.shared.resetAllForTesting()
        ChatSegmentedBubbleReadiness.prewarmGateForTesting = nil
        defer {
            ChatSegmentedBubbleReadiness.prewarmGateForTesting = nil
            ChatSegmentedBubbleReadiness.shared.resetAllForTesting()
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            IOSChatRenderPreferences.shared.syncFromDefaults(defaults)
        }

        let userMsg = UIMessage.companion.user(prompt: "请分段回答")
        let initialAssistant = IOSChatForegroundFixtures.assistantText("第一段还在生成未闭合")
        let messageID = ChatMessageProjector.messageId(for: initialAssistant)

        // 1. 首段未闭合前：readiness 为 false，气泡标记为 awaitingSegmentedFirstBlock，单行进度行继续保留
        XCTAssertFalse(ChatSegmentedBubbleReadiness.shared.isReady(messageID: messageID))
        let initialProj = NativeTimelineProjector.build(
            messages: [userMsg, initialAssistant],
            event: .assistantStreamDelta,
            isGenerationActive: true
        )
        let initialEntry = try XCTUnwrap(initialProj.messageEntry(for: messageID))
        XCTAssertTrue(initialEntry.isAwaitingSegmentedFirstBlock, "首段完成 Markdown 排版前必须处于等待首块就绪状态")

        let slot = ChatAsyncTaskSlot(
            conversationId: nil,
            inputDigest: "seg-1",
            anchorUserMessageId: ChatMessageProjector.messageId(for: userMsg),
            phoneControlUserInitiated: false,
            providerSetting: IOSChatForegroundFixtures.makeProviderSetting(),
            params: IOSChatForegroundFixtures.makeParams(toolNames: []),
            toolExposureBridge: nil,
            recipeCatalogSnapshot: nil,
            baselineMessages: [userMsg]
        )
        slot.currentRoundAssistantMessageId = messageID
        let activity = ChatTimelineActivity(
            anchorMessageID: messageID,
            hasAssistant: true,
            presentation: .activity(kind: .generating, title: "正在回复", systemImage: "sparkles", tint: .amber),
            tool: nil,
            taskSlot: slot,
            plannedStages: [],
            stagePlanStartedUptime: nil,
            liveReasoningSummary: nil,
            tracksTaskLiveness: false,
            showsThought: false
        )
        XCTAssertTrue(
            activity.shouldDisplayBelow(initialEntry),
            "首段块尚未解析就绪前，单行任务状态行必须继续保留，不能提前消失留下空白"
        )

        // 2. 挂载真实视图，使用 prewarmGate 卡住首段异步 Markdown 解析，验证 `\n\n` 刚到达但尚未完成排版时绝不抢跑露空气泡
        let gateBox = SegmentedGateBox()
        ChatSegmentedBubbleReadiness.prewarmGateForTesting = {
            await gateBox.wait()
        }

        let stream = Stream(text: "第一段还在生成未闭合")
        let bubbleHost = UIHostingController(
            rootView: MessageBubbleView(
                message: initialAssistant,
                isGenerating: true,
                isChatGenerationActive: true,
                isLastMessage: true,
                hasEverStreamed: true
            )
            .frame(width: 345, alignment: .leading)
            .ignoresSafeArea()
        )
        bubbleHost.safeAreaRegions = []
        let host = UIHostingController(
            rootView: Fixture(stream: stream)
                .environment(\.markdownLayoutInvalidationID, messageID)
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        let bubbleWindow = UIWindow(windowScene: scene)
        bubbleWindow.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        bubbleWindow.rootViewController = bubbleHost
        bubbleWindow.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            bubbleWindow.isHidden = true
            bubbleWindow.rootViewController = nil
        }

        try await pump(host: host, milliseconds: 80)
        bubbleHost.view.layoutIfNeeded()
        let waitingBubbleFittingHeight = bubbleHost.sizeThatFits(in: CGSize(width: 345, height: 1_200)).height
        XCTAssertEqual(waitingBubbleFittingHeight, 0, accuracy: 0.5, "首段块尚未解析就绪前，MessageBubbleView 容器布局高度必须保持为 0（不抢跑露空气泡或裸标题）")
        XCTAssertFalse(ChatSegmentedBubbleReadiness.shared.isReady(messageID: messageID))
        XCTAssertEqual(paragraphText(in: host.view), "")

        // `\n\n` 到达，但异步解析被 gate 挂起：此时 readiness 仍为 false，状态行仍保留，空气泡绝不提前入场
        stream.text = "第一段完整内容。\n\n第二段半截"
        try await pump(host: host, milliseconds: 80)
        bubbleHost.view.layoutIfNeeded()
        XCTAssertEqual(
            bubbleHost.sizeThatFits(in: CGSize(width: 345, height: 1_200)).height,
            0,
            accuracy: 0.5,
            "仅原始文本到达 `\\n\\n` 但 RenderableDocument 尚未解析完成时，MessageBubbleView 高度仍必须为 0"
        )
        XCTAssertFalse(
            ChatSegmentedBubbleReadiness.shared.isReady(messageID: messageID),
            "仅原始文本到达 `\\n\\n` 但 RenderableDocument 尚未解析完成时，气泡不得提前标记为就绪"
        )
        XCTAssertTrue(initialEntry.isAwaitingSegmentedFirstBlock)
        XCTAssertTrue(activity.shouldDisplayBelow(initialEntry))
        XCTAssertEqual(paragraphText(in: host.view), "")

        // 3. 放行首段解析：readiness 与首段已排版正文在同一帧就绪，状态行同步退场
        await gateBox.open()
        ChatSegmentedBubbleReadiness.prewarmGateForTesting = nil
        try await waitUntil(host: host) {
            ChatSegmentedBubbleReadiness.shared.isReady(messageID: messageID)
        }
        host.view.layoutIfNeeded()
        bubbleHost.view.layoutIfNeeded()
        XCTAssertGreaterThan(
            bubbleHost.sizeThatFits(in: CGSize(width: 345, height: 1_200)).height,
            18,
            "首段块就绪同一帧，MessageBubbleView 容器与 ChatAgentName 同步展开为真实高度"
        )
        XCTAssertEqual(
            paragraphText(in: host.view),
            "第一段完整内容。",
            "气泡就绪的同一帧必须已经持有首段已排版正文，不得经过空气泡再闪出文字"
        )
        XCTAssertFalse(initialEntry.isAwaitingSegmentedFirstBlock)
        XCTAssertFalse(
            activity.shouldDisplayBelow(initialEntry),
            "首段正文与气泡同帧就绪后，单行进度行应立即退场"
        )

        // 4. 后续块预热：第二段 `\n\n` 到达且解析挂起期间，第一段已显示正文持续保留，绝不闪空或退回未排版原文
        let secondGate = SegmentedGateBox()
        ChatSegmentedBubbleReadiness.prewarmGateForTesting = {
            await secondGate.wait()
        }
        stream.text = "第一段完整内容。\n\n第二段完整内容。\n\n第三段半截"
        try await pump(host: host, milliseconds: 80)
        XCTAssertEqual(
            paragraphText(in: host.view),
            "第一段完整内容。",
            "后续分段后台预热排版期间，已上屏的前序段落必须稳定保持，不得闪烁或插入空块"
        )
        await secondGate.open()
        ChatSegmentedBubbleReadiness.prewarmGateForTesting = nil
        try await waitUntil(host: host) {
            self.paragraphText(in: host.view).contains("第二段完整内容。")
        }
        XCTAssertEqual(paragraphText(in: host.view), "第一段完整内容。第二段完整内容。")
    }

    func testLiveStreamingBubbleBottomEdgeStaysAnchoredDuringContinuousHeightGrowthRespectsUserScrollPauseAndSettlesCleanly() async throws {
        let defaults = UserDefaults.standard
        let key = IOSDisplayPreferenceKeys.replyDeliveryMode
        let previous = defaults.object(forKey: key)
        defaults.set(IOSChatReplyDeliveryMode.liveStreaming.rawValue, forKey: key)
        IOSChatRenderPreferences.shared.syncFromDefaults(defaults)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            IOSChatRenderPreferences.shared.syncFromDefaults(defaults)
        }

        let growth = ChatTimelineGrowth()
        let scrollDriver = NativeTimelineScrollDriver()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 393, height: 600))
        let contentContainer = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 650))
        scrollView.addSubview(contentContainer)
        scrollView.contentSize = CGSize(width: 393, height: 650)
        scrollView.contentOffset = CGPoint(x: 0, y: 50)

        let stream = Stream(text: "第一段初始内容，建立可滚动底部基线。")
        let host = UIHostingController(
            rootView: Fixture(stream: stream)
                .environment(\.chatTimelineGrowth, growth)
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.addSubview(scrollView)
        defer {
            scrollDriver.invalidate()
            scrollView.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }

        growth.attachPresentationLayer(contentContainer.layer)
        growth.setEnabled(true)
        XCTAssertTrue(scrollDriver.attach(scrollView))
        scrollDriver.setAutomaticFollowEnabled(true)
        scrollDriver.setLayoutBottomPinEnabled(true)
        scrollDriver.submit(.explicitBottom(source: .button, animated: false, keyboardToken: nil))

        let bottomGap: CGFloat = 22
        try await waitUntil(host: host) {
            self.paragraphText(in: host.view).contains("建立可滚动底部基线")
        }
        var lastBubbleHeight = host.sizeThatFits(in: CGSize(width: 357, height: 10_000)).height
        let baseHistoryHeight: CGFloat = 580
        scrollView.contentSize = CGSize(width: 393, height: baseHistoryHeight + lastBubbleHeight + bottomGap)
        scrollDriver.syncBottomLockDuringLayoutIfNeeded()

        growth.onContentGrew = { [weak scrollDriver] _ in
            scrollDriver?.syncBottomLockDuringLayoutIfNeeded()
        }

        let initialBubbleBottomInViewport = (scrollView.contentSize.height - bottomGap) - scrollView.contentOffset.y
        XCTAssertEqual(initialBubbleBottomInViewport, 600 - bottomGap, accuracy: 0.5, "初始状态下活动气泡底边与输入框保持固定 22pt 间距")

        // 1. 连续多步流式增长（折行 + 跨段）：验证不产生向下图层位移（transform.m42 == 0），且气泡底边始终稳定钉在 600 - 22 = 578pt
        let steps = [
            "第一段初始内容，建立可滚动底部基线。继续补充第一段后续长句，触发多行折行与高度递增。",
            "第一段初始内容，建立可滚动底部基线。继续补充第一段后续长句，触发多行折行与高度递增。\n\n第二段新增架构说明：在流式更新期间保持底部留白恒定，所有新增行高在同一布局周期内转化为内容向上推进。",
            "第一段初始内容，建立可滚动底部基线。继续补充第一段后续长句，触发多行折行与高度递增。\n\n第二段新增架构说明：在流式更新期间保持底部留白恒定，所有新增行高在同一布局周期内转化为内容向上推进。同时避免对滚动容器附加向下的位移补间。",
            "第一段初始内容，建立可滚动底部基线。继续补充第一段后续长句，触发多行折行与高度递增。\n\n第二段新增架构说明：在流式更新期间保持底部留白恒定，所有新增行高在同一布局周期内转化为内容向上推进。同时避免对滚动容器附加向下的位移补间。\n\n第三段补充说明：核对手动上滑暂停与流式结束收口时的视口稳定性。"
        ]

        var cumulativeText = steps[0]
        for stepText in steps {
            cumulativeText = stepText
            stream.text = stepText
            try await pump(host: host, milliseconds: 96)
            let newBubbleHeight = host.sizeThatFits(in: CGSize(width: 357, height: 10_000)).height
            if newBubbleHeight > lastBubbleHeight {
                let delta = newBubbleHeight - lastBubbleHeight
                lastBubbleHeight = newBubbleHeight
                scrollView.contentSize = CGSize(width: 393, height: baseHistoryHeight + newBubbleHeight + bottomGap)
                growth.contentGrew(by: delta)
            }
            let layerTranslationY = contentContainer.layer.presentation()?.transform.m42 ?? contentContainer.layer.transform.m42
            XCTAssertEqual(
                layerTranslationY,
                0,
                accuracy: 0.01,
                "内容增长时不得对滚动容器施加向下的 transform.translation.y 把气泡底边推进输入框"
            )
            let bubbleBottomInViewport = (scrollView.contentSize.height - bottomGap) - scrollView.contentOffset.y
            XCTAssertEqual(
                bubbleBottomInViewport,
                600 - bottomGap,
                accuracy: 0.5,
                "跟随底部期间，每次行高/段高增长都必须在同一布局 pass 同步上推 offset，保持气泡底边间距恒定"
            )
            XCTAssertEqual(scrollDriver.distanceToBottomNow() ?? -1, 0, accuracy: 0.5)
        }

        // 2. 用户手动上滑离开底部：暂停自动跟随，后续流式增长不得强拉用户回到底部
        let manualPinnedOffsetY = max(0, scrollView.contentOffset.y - 160)
        scrollView.contentOffset.y = manualPinnedOffsetY
        scrollDriver.setLayoutBottomPinEnabled(false)
        growth.setEnabled(false)
        scrollDriver.submit(.userDragBegan)

        let pausedStepText = cumulativeText + "\n\n第四段在用户上滑阅读历史期间继续生成，不应把视口强行拉回底部。"
        stream.text = pausedStepText
        try await pump(host: host, milliseconds: 96)
        let pausedBubbleHeight = host.sizeThatFits(in: CGSize(width: 357, height: 10_000)).height
        scrollView.contentSize = CGSize(width: 393, height: baseHistoryHeight + pausedBubbleHeight + bottomGap)
        scrollDriver.handleLayoutMetricsChanged()
        XCTAssertEqual(
            scrollView.contentOffset.y,
            manualPinnedOffsetY,
            accuracy: 0.5,
            "用户手动上滑离开底部后，流式增长不得强迫视口跳回底部"
        )

        // 3. 用户回到底部 + Reduce Motion + 流式结束：底边间距依然稳定且正文完整不丢失
        stream.reduceMotion = true
        scrollDriver.setLayoutBottomPinEnabled(true)
        scrollDriver.submit(.userDragEnded(isAtBottom: true))
        scrollDriver.syncBottomLockDuringLayoutIfNeeded()
        stream.isStreaming = false
        scrollDriver.submit(.generationTerminated)
        try await waitUntil(host: host) {
            self.paragraphText(in: host.view).contains("第四段在用户上滑阅读历史期间继续生成")
        }
        let finalBubbleHeight = host.sizeThatFits(in: CGSize(width: 357, height: 10_000)).height
        scrollView.contentSize = CGSize(width: 393, height: baseHistoryHeight + finalBubbleHeight + bottomGap)
        scrollDriver.syncBottomLockDuringLayoutIfNeeded()
        let finalBubbleBottomInViewport = (scrollView.contentSize.height - bottomGap) - scrollView.contentOffset.y
        XCTAssertEqual(finalBubbleBottomInViewport, 600 - bottomGap, accuracy: 0.5)
        XCTAssertTrue(paragraphText(in: host.view).contains("核对手动上滑暂停与流式结束收口时的视口稳定性"))
        XCTAssertTrue(paragraphText(in: host.view).contains("第四段在用户上滑阅读历史期间继续生成"))
    }

    private func paragraphText(in view: UIView) -> String {
        if let textView = view as? UITextView {
            return textView.text ?? ""
        }
        return view.subviews.map { paragraphText(in: $0) }.joined()
    }

    private func tableScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, !(scrollView is UITextView) {
            return scrollView
        }
        return view.subviews.lazy.compactMap { self.tableScrollView(in: $0) }.first
    }

    private func pump(host: UIViewController, milliseconds: Int) async throws {
        for _ in 0..<max(1, milliseconds / 16) {
            try await Task.sleep(for: .milliseconds(16))
            host.view.layoutIfNeeded()
        }
    }

    private func waitUntil(host: UIViewController, condition: () -> Bool) async throws {
        for _ in 0..<250 {
            host.view.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTFail("流式渲染未在 4 秒内到达预期状态")
    }
}

private actor SegmentedGateBox {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
