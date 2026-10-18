import XCTest
import SwiftUI
import QuartzCore
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class ChatNativeTimelineReplayPerformanceTests: ChatNativeTimelineReplayTestCase {

    func testVisualConfigHashStableAcrossConfigInstances() {
        func build(animate: Bool) -> SwiftStreamingMarkdown.MarkdownRenderConfig {
            let bodyFonts = SwiftStreamingMarkdown.MarkdownRenderConfig.default.paragraphStyle.textFonts
            let paragraphStyle = SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownTextStyle(
                textFonts: bodyFonts,
                textColor: UIColor(AmberTheme.foreground)
            )
            let tableStyle = SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownTableTextStyle(
                textFonts: bodyFonts,
                headerTextColor: UIColor(AmberTheme.foreground),
                regularTextColor: UIColor(AmberTheme.foreground),
                headerBackgroundColor: UIColor(AmberTheme.surface2),
                borderColor: UIColor(AmberTheme.border),
                actionButtonColor: UIColor(AmberTheme.accent)
            )
            return SwiftStreamingMarkdown.MarkdownRenderConfig.default
                .withShouldAnimateText(value: animate)
                .withAnimatesAppendedTailAsUnit(value: animate)
                .withParagraphStyle(value: paragraphStyle)
                .withTableStyle(value: tableStyle)
        }
        let streaming = build(animate: true)
        let completed = build(animate: false)
        // 注：config 的原始 hashValue 跨实例不稳定（动态 UIColor 实例身份哈希，
        // 实测同主题三实例三值）——这正是 visualConfigHash 必须自行稳定哈希的原因。
        XCTAssertEqual(
            ChatStableStreamingMarkdownControllerTestSupport.visualConfigHash(for: streaming),
            ChatStableStreamingMarkdownControllerTestSupport.visualConfigHash(for: completed),
            "visualConfigHash 必须跨流式/完成两次 config 构建稳定（动态 UIColor 实例哈希漂移会打穿前缀缓存）"
        )
        // 真实视觉变化仍必须改变 visualConfigHash（字体/度量任一变化 → 不复用旧 renderable）。
        let differentSpacing = completed.withParagraphLineSpacing(value: 9)
        XCTAssertNotEqual(
            ChatStableStreamingMarkdownControllerTestSupport.visualConfigHash(for: completed),
            ChatStableStreamingMarkdownControllerTestSupport.visualConfigHash(for: differentSpacing),
            "真实排版变化必须反映在 visualConfigHash 上"
        )
    }

    func testReplayFixtureDecoderPreservesCadenceAndReset() throws {
        let jsonl = """
        {"meta":{"startedAt":0,"runId":"test"}}
        {"t":0,"d":"alpha"}
        {"t":30,"d":" beta"}
        {"t":45,"reset":"replacement"}
        """
        let frames = try ChatStreamReplayFixture.decodeJSONL(Data(jsonl.utf8))

        XCTAssertEqual(frames, [
            ChatStreamReplayFrame(elapsedMilliseconds: 0, cumulativeText: "alpha"),
            ChatStreamReplayFrame(elapsedMilliseconds: 30, cumulativeText: "alpha beta"),
            ChatStreamReplayFrame(elapsedMilliseconds: 45, cumulativeText: "replacement")
        ])
    }

    func testBundledPerformanceReplayFixturesArePortableAndMonotonic() throws {
        for fixtureName in ChatPerfReplayFixtureName.allCases {
            let frames = try ChatStreamReplayFixture.loadBundled(fixtureName)
            XCTAssertGreaterThan(frames.count, 20, "\(fixtureName.rawValue) must exercise repeated streaming updates")
            XCTAssertEqual(
                frames.map(\.elapsedMilliseconds),
                frames.map(\.elapsedMilliseconds).sorted(),
                "\(fixtureName.rawValue) timestamps must stay monotonic"
            )
            XCTAssertFalse(frames.last?.cumulativeText.isEmpty ?? true)
        }
    }

    func testToolDenseSessionUpdatesAndUserSendThroughNativeTimeline() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let assistantID = KotlinUuid.companion.random()
        let output = String(repeating: "remote command output ", count: 550)
        func tool(_ index: Int, status: String = "completed", revision: Int = 0) -> UIMessagePart.Tool {
            UIMessagePart.Tool(toolCallId: "ssh-\(index)", toolName: "terminal_execute", input: "{}",
                output: [UIMessagePart.Text(
                    text: "{\"ok\":true,\"status\":\"\(status)\",\"exit_code\":0,\"stdout\":\"\(revision) \(output)\"}", metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
        }
        let completedTools: [UIMessagePart] = (0..<40).map { tool($0) }
        func assistant(_ revision: Int, finished: Bool = false) -> UIMessage {
            UIMessage(id: assistantID, role: MessageRole.assistant,
                parts: completedTools + [tool(40, status: finished ? "completed" : "running", revision: revision),
                    UIMessagePart.Text(text: "连续正文开始。远端检查结果已经同步。", metadata: nil)],
                annotations: [], createdAt: chatNowLocalDateTime(),
                finishedAt: finished ? chatNowLocalDateTime() : nil, modelId: nil, usage: nil, translation: nil)
        }
        fixture.model.messages = longConversation(turns: 4) + [makeUserMessage("检查远端状态"), assistant(0)]
        fixture.model.isGenerationActive = true
        fixture.model.send(.toolCallStarted)
        XCTAssertTrue(pumpUntil(timeout: 5) { fixture.model.latestViewport.isAtBottom })
        pump(seconds: 0.3)
        let probe = DisplayLinkGapProbe()
        probe.start()
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for index in 1...12 {
            fixture.model.messages[fixture.model.messages.count - 1] = assistant(index)
            fixture.model.send(.toolResultAppended)
            pump(seconds: 0.05)
        }
        let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
        probe.stop()
        let metrics = "[PERF-TOOLS-NATIVE] tools=41 updates=12 CPU=\(cpuMs)ms per-update=\(cpuMs / 12)ms max-frame-gap=\((probe.gaps.max() ?? 0) * 1000)ms"
        print(metrics)
        let metricsAttachment = XCTAttachment(string: metrics)
        metricsAttachment.name = "native-tool-dense-metrics"
        metricsAttachment.lifetime = .keepAlways
        add(metricsAttachment)
        XCTAssertLessThan(cpuMs / 12, 200, "工具结果更新不能让主线程持续阻塞")
        fixture.model.messages[fixture.model.messages.count - 1] = assistant(12, finished: true)
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)
        XCTAssertTrue(pumpUntil(timeout: 4) { fixture.model.latestViewport.isAtBottom })
        XCTAssertTrue(pumpUntil(timeout: 3) {
            ScrollFrameProbe.streamingParagraph(in: fixture.host.view) != nil
        })
        let paragraph = try XCTUnwrap(ScrollFrameProbe.streamingParagraph(in: fixture.host.view))
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            fixture.model.messages.append(makeUserMessage("继续检查下一项"))
            fixture.model.send(.userAppend)
        }
        XCTAssertTrue(pumpUntil(timeout: 4) { fixture.model.latestViewport.isAtBottom })
        pump(seconds: 0.5)
        XCTAssertEqual(fixture.model.messages.last?.toText(), "继续检查下一项")
        XCTAssertTrue(ScrollFrameProbe.streamingParagraph(in: fixture.host.view) === paragraph,
            "工具密集助手消息变成历史后必须保留原 Markdown UIView，防止发送时重建闪烁")
        XCTAssertEqual(try XCTUnwrap(fixture.scrollView).contentOffset.x, 0, accuracy: 0.5)
        let image = UIGraphicsImageRenderer(size: fixture.host.view.bounds.size).image { _ in
            fixture.host.view.drawHierarchy(in: fixture.host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "native-tool-dense-user-send"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFixedGrowingTableFixtureReplaysThroughNativeTimeline() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 8)
        fixture.model.send(.initialLoad)
        pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom }

        fixture.model.messages.append(makeUserMessage("请回放固定长表格。"))
        fixture.model.isGenerationActive = true
        fixture.model.send(.userAppend)
        pump(seconds: 0.2)

        let frames = try ChatStreamReplayFixture.loadBundled(.growingTable)
        let assistantID = KotlinUuid.companion.random()
        for frame in frames {
            let message = makeAssistantMessage(
                id: assistantID,
                text: frame.cumulativeText,
                finished: false
            )
            if fixture.model.messages.last?.role == MessageRole.assistant {
                fixture.model.messages[fixture.model.messages.count - 1] = message
            } else {
                fixture.model.messages.append(message)
            }
            fixture.model.send(.streamDelta)
            pump(seconds: 0.015)
        }

        let finalText = try XCTUnwrap(frames.last?.cumulativeText)
        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: assistantID,
            text: finalText,
            finished: true
        )
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)

        let settledAtBottom = pumpUntil(timeout: 5.0) {
            fixture.model.latestViewport.isAtBottom
        }
        XCTAssertTrue(settledAtBottom, "fixed table replay must settle at the real bottom")
        XCTAssertTrue(finalText.contains("| 56 | final state"))
    }

    func testPerfGrowingTableStreamingKeepsDisplayLinkResponsive() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 12)
        fixture.model.send(.initialLoad)
        XCTAssertTrue(pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom })

        fixture.model.messages.append(makeUserMessage("请持续追加长表格。"))
        fixture.model.isGenerationActive = true
        fixture.model.send(.userAppend)

        var table = """
        | 序号 | 流式表格内容 | 状态 |
        | --- | --- | --- |

        """
        for index in 0..<80 {
            table += "| \(index) | 已稳定的长表格内容，用于验证追加行时主线程仍能及时提交可见帧 | stable |\n"
        }
        let assistantID = KotlinUuid.companion.random()
        fixture.model.messages.append(makeAssistantMessage(
            id: assistantID,
            text: table,
            finished: false
        ))
        fixture.model.send(.streamDelta)
        pump(seconds: 2.0)

        let probe = DisplayLinkGapProbe()
        probe.start()
        pump(seconds: 0.2)
        for index in 80..<92 {
            table += "| \(index) | 新追加的可见流式表格行，保留完整逐词动画和表格视觉 | live |\n"
            fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
                id: assistantID,
                text: table,
                finished: false
            )
            fixture.model.send(.streamDelta)
            pump(seconds: 0.08)
        }
        pump(seconds: 0.4)
        probe.stop()

        let gapMilliseconds = probe.gaps.dropFirst(2).map { $0 * 1_000 }.sorted()
        let maxGap = try XCTUnwrap(gapMilliseconds.last)
        let p95Index = min(
            gapMilliseconds.count - 1,
            Int((Double(gapMilliseconds.count) * 0.95).rounded(.up)) - 1
        )
        let p95Gap = gapMilliseconds[max(0, p95Index)]
        let over50ms = gapMilliseconds.filter { $0 > 50 }.count
        print(String(
            format: "[PERF-HITCH] growingTable samples=%d p95=%.2fms max=%.2fms over50ms=%d",
            gapMilliseconds.count,
            p95Gap,
            maxGap,
            over50ms
        ))

        XCTAssertLessThanOrEqual(
            p95Gap,
            40,
            "80 行长表格流式期间至少 95% 的可见帧间隔应显著低于旧实现的 50ms+，不能靠关闭动画换性能。"
        )
        XCTAssertLessThanOrEqual(
            maxGap,
            80,
            "长表格追加不能造成肉眼可见的连续主线程停顿。"
        )
    }

    func testLayerBackedTableEntranceDoesNotChangeLayoutWhenAnimationCompletes() async {
        var table = """
        | 序号 | 动画覆盖层布局验证 | 状态 |
        | --- | --- | --- |

        """
        for index in 0..<12 {
            table += "| \(index) | 最终 SwiftUI Text 始终负责布局，Core Animation 只负责渐进显现 | live |\n"
        }
        let config = SwiftStreamingMarkdown.MarkdownRenderConfig.default
            .withShouldAnimateText(value: true)
        let renderable = await SwiftStreamingMarkdown.MarkdownParserImpl()
            .parse(text: table, config: config)
        let host = UIHostingController(rootView: SwiftStreamingMarkdown.DocumentView(
            renderableDocument: renderable,
            config: config,
            usesLayerBackedTableAnimation: true
        )
        .frame(width: 353, alignment: .leading))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let heightDuringAnimation = host.sizeThatFits(
            in: CGSize(width: 353, height: CGFloat.greatestFiniteMagnitude)
        ).height
        pump(seconds: 0.5)
        let heightAfterAnimation = host.sizeThatFits(
            in: CGSize(width: 353, height: CGFloat.greatestFiniteMagnitude)
        ).height

        XCTAssertEqual(
            heightAfterAnimation,
            heightDuringAnimation,
            accuracy: 1,
            "动画覆盖层卸载时不应改变表格或聊天列表高度。"
        )
    }


}
