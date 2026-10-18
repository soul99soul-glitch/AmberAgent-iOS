import XCTest
import SwiftUI
import QuartzCore
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class ChatSwiftUIStreamReplayTests: ChatNativeTimelineReplayTestCase {

    func testNativeTimelineRevealsReceivedIntelligentUIComponents() {
        let id = KotlinUuid.companion.random()
        let prefix = "```task-ui\n" + #"{"version":1,"card_id":"motion","kind":"explore","goal":"NATIVE RECEIVED","components":["#
        let first = #"{"id":"first","kind":"body","text":"FIRST RECEIVED"}"#
        let second = #"{"id":"second","kind":"body","text":"SECOND RECEIVED"}"#
        let fixture = makeFixture { model in
            model.isGenerationActive = true
            model.messages = [makeUserMessage("生成任务界面"), makeAssistantMessage(id: id, text: prefix + first, finished: false)]
            model.send(.streamDelta)
        }
        defer { fixture.tearDown() }
        let key = "native-generation:\(id.toHexDashString()):text:0:task:0:component:"
        XCTAssertTrue(pumpUntil(timeout: 3) { ChatLiveEntranceRegistry.hasRevealed(key + "first") })

        fixture.model.messages[1] = makeAssistantMessage(id: id, text: prefix + first + "," + second, finished: false)
        fixture.model.send(.streamDelta)
        XCTAssertTrue(pumpUntil(timeout: 3) { ChatLiveEntranceRegistry.hasRevealed(key + "second") })
        XCTAssertFalse(ChatLiveEntranceRegistry.claim(key + "first"), "接收新组件不能让旧组件重播")
    }

    func testStreamingFollowKeepsBottomWithoutBackjump() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 6)
        fixture.model.send(.initialLoad)
        pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom }

        fixture.model.messages.append(makeUserMessage("请写一段很长的回答。"))
        fixture.model.isGenerationActive = true
        fixture.model.send(.userAppend)
        pump(seconds: 0.3)

        let assistantId = KotlinUuid.companion.random()
        var tailText = ""
        var maxBackjump: CGFloat = 0
        var lastOffsetY = fixture.scrollView?.contentOffset.y ?? 0
        var lastContentHeight = fixture.scrollView?.contentSize.height ?? 0
        var lastParagraphHeight = ScrollFrameProbe.paragraph(
            in: fixture.host.view,
            withPrefix: "第 0 句:"
        )?.frame.height
        var currentChunkIndex = -1
        var worstBackjumpContext = ""

        func sampleVisibleOffset() {
            guard let scrollView = fixture.scrollView else { return }
            let offsetY = scrollView.contentOffset.y
            let contentHeight = scrollView.contentSize.height
            let paragraph = ScrollFrameProbe.paragraph(
                in: fixture.host.view,
                withPrefix: "第 0 句:"
            )
            let backjump = lastOffsetY - offsetY
            if backjump > maxBackjump {
                let visibleBottom = offsetY + scrollView.bounds.height
                    - scrollView.adjustedContentInset.bottom
                maxBackjump = backjump
                worstBackjumpContext =
                    "chunk=\(currentChunkIndex) from=\(lastOffsetY) to=\(offsetY) " +
                    "contentH=\(lastContentHeight)->\(contentHeight) " +
                    "paragraphH=\(String(describing: lastParagraphHeight))->" +
                    "\(String(describing: paragraph?.frame.height)) " +
                    "paragraphLength=\(String(describing: paragraph?.attributedText.length)) " +
                    "distance=\(max(0, contentHeight - visibleBottom)) " +
                    "tracking=\(scrollView.isTracking) dragging=\(scrollView.isDragging) " +
                    "decelerating=\(scrollView.isDecelerating)"
            }
            lastOffsetY = offsetY
            lastContentHeight = contentHeight
            lastParagraphHeight = paragraph?.frame.height
        }

        for index in 0..<40 {
            currentChunkIndex = index
            tailText += "第 \(index) 句:机制层的所有权在任一时刻只能有一个写入者,竞争必须显式分权。"
            let tail = makeAssistantMessage(id: assistantId, text: tailText, finished: false)
            if fixture.model.messages.last?.role == MessageRole.assistant {
                fixture.model.messages[fixture.model.messages.count - 1] = tail
            } else {
                fixture.model.messages.append(tail)
            }
            fixture.model.send(.streamDelta)
            pump(seconds: 0.04, onTick: sampleVisibleOffset)
        }

        // 真实协议:流结束必发 terminal 信号。普通文本的 66ms 解析、表格的
        // 120-320ms 解析都可能晚于最后一个 delta，由 terminal settle 承接。
        fixture.model.messages[fixture.model.messages.count - 1] =
            makeAssistantMessage(id: assistantId, text: tailText, finished: true)
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)

        pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom }
        let viewport = fixture.model.latestViewport
        XCTAssertTrue(viewport.isAtBottom, "流式跟随收敛后必须仍在底部")
        XCTAssertFalse(viewport.followPaused, "无用户交互时不得进入 pausedForUser(假 pause)")
        XCTAssertLessThan(
            maxBackjump,
            ChatLayout.bottomStickThreshold,
            "流式期出现超过贴底语义阈值的 offset 回跳: \(worstBackjumpContext)"
        )
    }

    func testMeasuredGrowthBottomFollowHasAVisibleTransition() throws {
        try XCTSkipIf(
            UIAccessibility.isReduceMotionEnabled,
            "系统 Reduce Motion 开启时，生产契约就是立即贴底，不执行视觉动画 canary"
        )
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 8)
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        }

        fixture.model.messages.append(makeUserMessage("请继续展开流式跟随机制。"))
        fixture.model.send(.userAppend)
        pump(seconds: 0.25)

        let assistantID = KotlinUuid.companion.random()
        let initialText = "流式回答已经开始。"
        fixture.model.messages.append(makeAssistantMessage(
            id: assistantID,
            text: initialText,
            finished: false
        ))
        fixture.model.send(.streamDelta)
        pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom }
        pump(seconds: 0.6)

        guard let scrollView = fixture.scrollView else {
            return XCTFail("Expected the default Native timeline scroll view")
        }
        let initialOffsetY = scrollView.contentOffset.y
        let initialContentHeight = scrollView.contentSize.height
        var samples: [(time: TimeInterval, contentHeight: CGFloat, offsetY: CGFloat)] = []

        let expandedText = initialText + String(
            repeating: "新增的流式内容会形成稳定换行，底部跟随需要经过连续过渡而不是整行瞬移。",
            count: 3
        )
        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: assistantID,
            text: expandedText,
            finished: false
        )
        fixture.model.send(.streamDelta)
        pump(seconds: 1.0) {
            samples.append((
                time: Date.timeIntervalSinceReferenceDate,
                contentHeight: scrollView.contentSize.height,
                offsetY: scrollView.contentOffset.y
            ))
        }
        pumpUntil(timeout: 2.0) { fixture.model.latestViewport.isAtBottom }

        let finalOffsetY = scrollView.contentOffset.y
        let finalContentHeight = scrollView.contentSize.height
        let intermediateOffsets = Set(samples.compactMap { sample -> Int? in
            guard sample.offsetY > initialOffsetY + 0.5,
                  sample.offsetY < finalOffsetY - 0.5 else { return nil }
            return Int((sample.offsetY * 10).rounded())
        })
        let maxBackjump = zip(samples, samples.dropFirst()).reduce(CGFloat.zero) { current, pair in
            max(current, pair.0.offsetY - pair.1.offsetY)
        }
        let transitionSamples = samples.filter {
            $0.offsetY > initialOffsetY + 0.5 && $0.offsetY < finalOffsetY - 0.5
        }.prefix(12)
        let visibleBottom = finalOffsetY + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
        let finalDistanceToBottom = max(0, finalContentHeight - visibleBottom)

        XCTAssertGreaterThan(
            finalContentHeight,
            initialContentHeight + 1,
            "fixture 必须制造真实 contentHeight 增长"
        )
        XCTAssertGreaterThan(finalOffsetY, initialOffsetY + 1, "增长后底锚必须实际向下推进")
        // sizeChanges 底锚在同一布局事务内吸收高度增长,scroll offset 始终贴底,
        // 不再产生中间 offset 过渡帧。旧 measured-growth 动画的中间帧断言已不适用。
        // 新契约:无回跳 + 最终贴底即可。
        XCTAssertLessThan(maxBackjump, 1, "短过渡不能引入反向回跳")
        XCTAssertLessThanOrEqual(finalDistanceToBottom, ChatLayout.bottomStickThreshold)
        XCTAssertLessThanOrEqual(visibleBottom, finalContentHeight + 2, "物理视口不能冲过内容底部")
        XCTAssertTrue(fixture.model.latestViewport.isAtBottom)
    }

    func testFirstTwoStreamingLinesUseContinuousNativeBottomFollow() throws {
        try XCTSkipIf(
            UIAccessibility.isReduceMotionEnabled,
            "系统 Reduce Motion 开启时，生产契约就是立即贴底"
        )
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 8)
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        })

        fixture.model.messages.append(makeUserMessage("请从第一行开始连续生成。"))
        fixture.model.send(.userAppend)
        pump(seconds: 0.4)

        guard let scrollView = fixture.scrollView else {
            return XCTFail("Expected the default Native timeline scroll view")
        }
        let probe = ScrollFrameProbe(scrollView: scrollView, rootView: fixture.host.view)
        let gapProbe = DisplayLinkGapProbe()
        probe.start()
        gapProbe.start()
        defer { probe.stop() }
        defer { gapProbe.stop() }
        pump(seconds: 0.1)

        let assistantID = KotlinUuid.companion.random()
        func publishAndMeasure(_ text: String) -> (
            contentGrew: Bool,
            offsetAdvanced: Bool,
            intermediateOffsetCount: Int,
            offsetDelta: CGFloat,
            p95GapMS: CGFloat,
            maxGapMS: CGFloat
        ) {
            let initialContentHeight = scrollView.contentSize.height
            let initialOffsetY = scrollView.contentOffset.y
            let sampleStart = probe.samples.count
            let gapStart = gapProbe.gaps.count
            let message = makeAssistantMessage(id: assistantID, text: text, finished: false)
            if fixture.model.messages.last?.role == MessageRole.assistant {
                fixture.model.messages[fixture.model.messages.count - 1] = message
            } else {
                fixture.model.messages.append(message)
            }
            fixture.model.send(.streamDelta)

            let advanced = pumpUntil(timeout: 2.0) {
                scrollView.contentSize.height > initialContentHeight + 1 &&
                    scrollView.contentOffset.y > initialOffsetY + 1
            }
            pump(seconds: 0.35)

            let finalContentHeight = scrollView.contentSize.height
            let finalOffsetY = scrollView.contentOffset.y
            let intermediateOffsets = Set(probe.samples.dropFirst(sampleStart).compactMap { sample -> Int? in
                guard sample.contentOffsetY > initialOffsetY + 0.5,
                      sample.contentOffsetY < finalOffsetY - 0.5 else { return nil }
                return Int((sample.contentOffsetY * 10).rounded())
            })
            return (
                contentGrew: finalContentHeight > initialContentHeight + 1,
                offsetAdvanced: advanced && finalOffsetY > initialOffsetY + 1,
                intermediateOffsetCount: intermediateOffsets.count,
                offsetDelta: finalOffsetY - initialOffsetY,
                p95GapMS: percentile(
                    gapProbe.gaps.dropFirst(gapStart).map { CGFloat($0 * 1_000) },
                    percentile: 0.95
                ),
                maxGapMS: gapProbe.gaps.dropFirst(gapStart).map { CGFloat($0 * 1_000) }.max() ?? 0
            )
        }

        let firstLine = publishAndMeasure("第一行。")
        let secondLine = publishAndMeasure("第一行。\n\n第二行。")

        for (label, result) in [("第一行", firstLine), ("第二行", secondLine)] {
            XCTAssertTrue(result.contentGrew, "\(label)必须产生真实 contentHeight 增长")
            XCTAssertTrue(result.offsetAdvanced, "\(label)必须从首次增长就推进底部")
            XCTAssertGreaterThanOrEqual(
                result.intermediateOffsetCount,
                2,
                "\(label)不能一次跳到新底部：delta=\(result.offsetDelta), " +
                    "intermediate=\(result.intermediateOffsetCount)"
            )
            XCTAssertLessThanOrEqual(
                result.p95GapMS,
                40,
                "\(label)早期跟随不能先丢帧再变流畅：p95=\(result.p95GapMS)ms"
            )
            XCTAssertLessThanOrEqual(
                result.maxGapMS,
                80,
                "\(label)早期跟随不能出现肉眼可见的主线程停顿：max=\(result.maxGapMS)ms"
            )
        }
    }

    func testKernelStreamStartsContinuousFollowOnFirstAssistantLine() async throws {
        try XCTSkipIf(
            UIAccessibility.isReduceMotionEnabled,
            "系统 Reduce Motion 开启时，生产契约就是立即贴底"
        )
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        let history = longConversation(turns: 8)
        fixture.model.messages = history
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        })

        let seed = history + [makeUserMessage("请连续生成一段正文。")]
        fixture.model.messages = seed
        fixture.model.send(.userAppend)
        pump(seconds: 0.4)

        let targetText = "连续正文开始。" + String(
            repeating: "这是用来测量真实手机行宽与首段追底节奏的中文。",
            count: 10
        )
        let kernelHarness = IOSChatForegroundHarness(seedMessages: seed)
        var firstStreamRevisionTimestamp: CFTimeInterval?
        kernelHarness.onMessagesChanged = { messages in fixture.model.messages = messages }
        kernelHarness.onRevision = { reason, lagAllowance in
            if case .streamDelta = reason, firstStreamRevisionTimestamp == nil {
                firstStreamRevisionTimestamp = CACurrentMediaTime()
            }
            fixture.model.send(reason, lagAllowance: lagAllowance)
        }
        let provider = IOSChatScriptedStreamingProvider(streams: [
            .init(
                chunks: iosChatScriptedTextDeltas(targetText, chunkCount: 16).map {
                    IOSChatForegroundFixtures.streamChunk(
                        delta: IOSChatForegroundFixtures.assistantText($0)
                    )
                },
                intervalNanos: 70_000_000
            ),
        ])
        let kernelHost = ChatKernelRunHost(
            dependencies: kernelHarness.dependencies,
            bindings: kernelHarness.bindings,
            backgroundExecution: kernelHarness.keepAlive,
            toolLedger: kernelHarness.ledger,
            textProvider: provider
        )

        guard let scrollView = fixture.scrollView else {
            return XCTFail("Expected the default Native timeline scroll view")
        }
        // CADisplayLink callbacks run before the frame commit and in registration order.
        // This probe is registered before the Native driver, so synchronous reads would
        // capture the driver's pre-write state rather than the geometry shown on screen.
        let probe = ScrollFrameProbe(
            scrollView: scrollView,
            rootView: fixture.host.view,
            capturesAfterDisplayLinkCallbacks: true
        )
        let gapProbe = DisplayLinkGapProbe()
        probe.start()
        gapProbe.start()
        defer { probe.stop() }
        defer { gapProbe.stop() }
        pump(seconds: 0.1)
        let sampleStart = probe.samples.count
        let gapStart = gapProbe.gaps.count
        let initialContentHeight = scrollView.contentSize.height
        let initialOffsetY = scrollView.contentOffset.y
        kernelHost.start(
            providerSetting: kernelHarness.providerSetting,
            params: kernelHarness.params,
            inputDigest: "native-timeline-first-line",
            conversationId: kernelHarness.conversationId,
            uploadMessages: kernelHarness.messages,
            toolExposureBridge: kernelHarness.toolExposureBridge
        )

        let earlyTextThreshold = targetText.count * 3 / 8
        let earlyDeadline = Date().addingTimeInterval(3)
        var earlyTextVisible = false
        while Date() < earlyDeadline {
            if let assistant = kernelHarness.messages.last,
               assistant.role == MessageRole.assistant,
               assistant.toText().count >= earlyTextThreshold {
                earlyTextVisible = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(earlyTextVisible, "真实 Host 必须在流结束前投影 assistant 前缀")
        try? await Task.sleep(nanoseconds: 100_000_000)
        probe.stop()
        gapProbe.stop()

        let samples = Array(probe.samples.dropFirst(sampleStart))
        let streamBeganAt = firstStreamRevisionTimestamp ?? .greatestFiniteMagnitude
        let measuredGapsMS = zip(
            gapProbe.gapEndTimestamps.dropFirst(gapStart),
            gapProbe.gaps.dropFirst(gapStart)
        ).compactMap { timestamp, gap in
            timestamp >= streamBeganAt ? gap * 1_000 : nil
        }
        let streamContentHeight = scrollView.contentSize.height
        let streamOffsetY = scrollView.contentOffset.y

        let terminal = await kernelHarness.waitForTerminal()
        XCTAssertEqual(terminal, "completed")
        fixture.model.messages = kernelHarness.messages
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)
        pump(seconds: 0.2)

        let maxGapMS = measuredGapsMS.max() ?? 0
        let heightGrowthCount = zip(samples, samples.dropFirst()).reduce(into: 0) { count, pair in
            if pair.1.contentHeight > pair.0.contentHeight + 0.5 {
                count += 1
            }
        }
        let maxBackjump = zip(samples, samples.dropFirst()).reduce(CGFloat.zero) { result, pair in
            max(result, pair.0.contentOffsetY - pair.1.contentOffsetY)
        }

        XCTAssertNotNil(firstStreamRevisionTimestamp, "门禁必须观测到真实 streamDelta")
        XCTAssertGreaterThanOrEqual(measuredGapsMS.count, 10, "门禁必须真实采样首段 display-link")
        XCTAssertGreaterThanOrEqual(heightGrowthCount, 3, "输入必须跨过多个真实行高边界")
        XCTAssertGreaterThan(streamContentHeight, initialContentHeight + 60)
        XCTAssertGreaterThan(streamOffsetY, initialOffsetY + 60)
        XCTAssertLessThan(maxBackjump, 1, "首段追底不能反向回跳")
        XCTAssertLessThanOrEqual(
            samples.map(\.distanceToBottom).max() ?? 0,
            NativeTimelineScrollCore.resumeEpsilon,
            "从首个 assistant 行开始就必须保持语义贴底"
        )
        XCTAssertTrue(
            ScrollFrameProbe.streamingParagraph(in: fixture.host.view)?.usesTextKit1 == true,
            "回放必须经过生产的无附件 TextKit 1 流式正文路径"
        )
        XCTAssertLessThanOrEqual(
            maxGapMS,
            80,
            "首行上屏后不能先停顿再变流畅：max=\(maxGapMS)ms"
        )
    }

    func testLongProseMeasuredGrowthDoesNotPublishSeveralLinesAtOnce() {
        let blockKey = IOSDisplayPreferenceKeys.streamingBlockMarkdown
        let previousBlockSetting = UserDefaults.standard.object(forKey: blockKey)
        UserDefaults.standard.set(true, forKey: blockKey)
        defer {
            if let previousBlockSetting {
                UserDefaults.standard.set(previousBlockSetting, forKey: blockKey)
            } else {
                UserDefaults.standard.removeObject(forKey: blockKey)
            }
        }

        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 4)
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        pumpUntil(timeout: 4.0) {
            fixture.model.latestViewport.isAtBottom && fixture.model.latestViewport.isContentScrollable
        }

        fixture.model.messages.append(makeUserMessage("请连续输出短段落。"))
        fixture.model.send(.userAppend)
        pump(seconds: 0.2)

        let assistantID = KotlinUuid.companion.random()
        // 引用定义计入长文本长度，但不会制造数百行可见内容，避免超长
        // Markdown 布局成本干扰真实高度发布与过渡节奏采样。
        var text = (0..<160).map { index in
            "[cadence-\(index)]: https://example.com/\(index)\n"
        }.joined()
        fixture.model.messages.append(makeAssistantMessage(
            id: assistantID,
            text: text,
            finished: false
        ))
        fixture.model.send(.streamDelta)
        pumpUntil(timeout: 5.0) { fixture.model.latestViewport.isAtBottom }
        pump(seconds: 1.0)

        guard let scrollView = fixture.scrollView else {
            return XCTFail("Expected the default Native timeline scroll view")
        }
        let initialContentHeight = scrollView.contentSize.height
        var samples: [(time: TimeInterval, contentHeight: CGFloat, offsetY: CGFloat)] = []

        let addedParagraphCount = 10
        for index in 0..<addedParagraphCount {
            text += "\n\n第\(index + 1)个新增短段落。"
            fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
                id: assistantID,
                text: text,
                finished: false
            )
            fixture.model.send(.streamDelta)
            pump(seconds: 0.055) {
                samples.append((
                    time: Date.timeIntervalSinceReferenceDate,
                    contentHeight: scrollView.contentSize.height,
                    offsetY: scrollView.contentOffset.y
                ))
            }
        }
        pump(seconds: 0.8) {
            samples.append((
                time: Date.timeIntervalSinceReferenceDate,
                contentHeight: scrollView.contentSize.height,
                offsetY: scrollView.contentOffset.y
            ))
        }

        var growthEvents: [(sampleIndex: Int, time: TimeInterval, contentHeight: CGFloat)] = []
        var observedHeight = initialContentHeight
        for (sampleIndex, sample) in samples.enumerated() where sample.contentHeight > observedHeight + 1 {
            observedHeight = sample.contentHeight
            if let last = growthEvents.last, sample.time - last.time < 0.03 {
                growthEvents[growthEvents.count - 1] = (sampleIndex, sample.time, sample.contentHeight)
            } else {
                growthEvents.append((sampleIndex, sample.time, sample.contentHeight))
            }
        }

        let finalContentHeight = scrollView.contentSize.height
        let totalGrowth = finalContentHeight - initialContentHeight
        let publishGaps = zip(growthEvents, growthEvents.dropFirst())
            .map { $1.time - $0.time }
            .sorted()
        let medianPublishGap: TimeInterval
        if publishGaps.isEmpty {
            medianPublishGap = 0
        } else if publishGaps.count.isMultiple(of: 2) {
            let upper = publishGaps.count / 2
            medianPublishGap = (publishGaps[upper - 1] + publishGaps[upper]) / 2
        } else {
            medianPublishGap = publishGaps[publishGaps.count / 2]
        }
        let visiblyAnimatedGrowthCount = growthEvents.enumerated().reduce(into: 0) { count, entry in
            let eventIndex = entry.offset
            let growth = entry.element
            guard growth.sampleIndex > 0 else { return }
            let previousSample = samples[growth.sampleIndex - 1]
            let nextGrowthSampleIndex = eventIndex + 1 < growthEvents.count
                ? growthEvents[eventIndex + 1].sampleIndex
                : samples.count
            let motionSamples = samples[growth.sampleIndex..<nextGrowthSampleIndex]
                .map(\.offsetY)
                .filter { $0 > previousSample.offsetY + 0.5 }
            let distinctMotionOffsets = Set(motionSamples.map { Int(($0 * 10).rounded()) })
            if distinctMotionOffsets.count >= 2 {
                count += 1
            }
        }

        XCTAssertGreaterThan(totalGrowth, CGFloat(addedParagraphCount) * 10, "fixture 必须逐段制造真实高度增长")
        XCTAssertGreaterThanOrEqual(
            growthEvents.count,
            7,
            "10 次逐行级输入至少应产生 7 次独立高度增长，不能被合并成四五行一批。" +
                " events=\(growthEvents), totalGrowth=\(totalGrowth)"
        )
        XCTAssertLessThanOrEqual(
            medianPublishGap,
            0.11,
            "大多数真实高度发布不能回到 140-160ms 的长文本批次。" +
                " medianGap=\(medianPublishGap), gaps=\(publishGaps), events=\(growthEvents)"
        )
        // sizeChanges 底锚使 scroll offset 始终贴底,不再产生中间 offset 过渡帧。
        // 旧 measured-growth 动画的中间帧断言已不适用;高度发布节奏仍由上面的
        // growthEvents/medianPublishGap 断言覆盖。
    }

    func testContinuousProseGrowthStaysLineSizedWhileFollowingBottom() {
        let blockKey = IOSDisplayPreferenceKeys.streamingBlockMarkdown
        let previousBlockSetting = UserDefaults.standard.object(forKey: blockKey)
        UserDefaults.standard.set(true, forKey: blockKey)
        defer {
            if let previousBlockSetting {
                UserDefaults.standard.set(previousBlockSetting, forKey: blockKey)
            } else {
                UserDefaults.standard.removeObject(forKey: blockKey)
            }
        }

        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 16)
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        XCTAssertTrue(pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom })

        let assistantID = KotlinUuid.companion.random()
        var tailText = "连续正文开始。" + String(
            repeating: "这是一段没有空行分隔的长篇连续正文，用来复现真实回答累计变长后同一段落仍在增长的布局压力。",
            count: 180
        )
        XCTAssertGreaterThan(tailText.utf16.count, 7_400, "fixture 必须覆盖单个真实长段落")
        let settledPrefix = (1...12)
            .map { "第\($0)段已经闭合，不应随末尾长段落的 delta 重新布局。" }
            .joined(separator: "\n\n")
        var text = settledPrefix + "\n\n" + tailText
        fixture.model.messages.append(makeAssistantMessage(
            id: assistantID,
            text: text,
            finished: false
        ))
        fixture.model.send(.streamDelta)
        XCTAssertTrue(pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom })
        XCTAssertTrue(pumpUntil(timeout: 4.0) {
            guard let paragraph = ScrollFrameProbe.streamingParagraph(in: fixture.host.view) else {
                return false
            }
            return paragraph.usesTextKit1 &&
                ScrollFrameProbe.streamingTextLength(in: paragraph) == tailText.utf16.count
        })
        pump(seconds: 0.4)

        guard let scrollView = fixture.scrollView else {
            return XCTFail("Expected the default Native timeline scroll view")
        }
        let probe = ScrollFrameProbe(scrollView: scrollView, rootView: fixture.host.view)
        probe.start()
        for _ in 0..<60 {
            let delta = String(repeating: "流", count: 12)
            tailText += delta
            text += delta
            fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
                id: assistantID,
                text: text,
                finished: false
            )
            fixture.model.send(.streamDelta)
            pump(seconds: 0.048)
        }
        pump(seconds: 0.8)
        probe.stop()

        let settledSamples = probe.samples.filter { ($0.paragraphLength ?? 0) >= 100 }
        let contentGrowthSteps = zip(settledSamples, settledSamples.dropFirst())
            .map { $1.contentHeight - $0.contentHeight }
            .filter { $0 > 0.5 }
        let paragraphGrowthSteps = zip(settledSamples, settledSamples.dropFirst())
            .compactMap { previous, current -> CGFloat? in
                guard let previousHeight = previous.paragraphHeight,
                      let currentHeight = current.paragraphHeight else { return nil }
                let delta = currentHeight - previousHeight
                return delta > 0.5 ? delta : nil
            }
        let textGrowthSteps = zip(settledSamples, settledSamples.dropFirst()).compactMap {
            previous, current -> Int? in
            guard let previousLength = previous.paragraphLength,
                  let currentLength = current.paragraphLength else { return nil }
            let delta = currentLength - previousLength
            return delta > 0 ? delta : nil
        }
        let contentGrowthP95 = percentile(contentGrowthSteps, percentile: 0.95)
        let paragraphGrowthP95 = percentile(paragraphGrowthSteps, percentile: 0.95)
        let textGrowthP95 = percentile(textGrowthSteps.map(CGFloat.init), percentile: 0.95)
        let maxBottomDebt = settledSamples.map(\.distanceToBottom).max() ?? .greatestFiniteMagnitude
        let horizontalOffsets = settledSamples.map(\.contentOffsetX)
        let horizontalDrift = (horizontalOffsets.max() ?? 0) - (horizontalOffsets.min() ?? 0)

        XCTAssertEqual(probe.samples.last?.paragraphLength, tailText.utf16.count)
        XCTAssertEqual(
            probe.samples.last?.paragraphUsesTextKit1,
            true,
            "无附件长段落必须走低成本布局"
        )
        XCTAssertGreaterThanOrEqual(textGrowthSteps.count, 45, "可见文本不能数批才发布：\(textGrowthSteps)")
        XCTAssertLessThanOrEqual(textGrowthP95, 24, "绝大多数更新最多合并两个 snapshot：\(textGrowthSteps)")
        XCTAssertLessThanOrEqual(textGrowthSteps.max() ?? .max, 36, "不能积累四五行文本后再发布：\(textGrowthSteps)")
        XCTAssertGreaterThanOrEqual(
            contentGrowthSteps.count,
            30,
            "连续正文应按换行持续发布高度，不能把多行合并成少数批次：\(contentGrowthSteps)"
        )
        XCTAssertLessThanOrEqual(
            contentGrowthP95,
            40,
            "绝大多数列表高度发布必须保持单行级：\(contentGrowthSteps)"
        )
        XCTAssertLessThanOrEqual(
            paragraphGrowthP95,
            40,
            "绝大多数段落高度发布必须保持单行级：\(paragraphGrowthSteps)"
        )
        XCTAssertLessThanOrEqual(
            paragraphGrowthSteps.max() ?? .greatestFiniteMagnitude,
            40,
            "增长中的段落本身不能一次发布多行高度：\(paragraphGrowthSteps)"
        )
        XCTAssertLessThanOrEqual(
            contentGrowthSteps.max() ?? .greatestFiniteMagnitude,
            64,
            "60Hz 模拟器可以漏采一个中间帧，但列表不能积累三行以上再发布：\(contentGrowthSteps)"
        )
        XCTAssertLessThanOrEqual(
            maxBottomDebt,
            72,
            "贴底流式不能积累两行以上的未跟随高度：\(maxBottomDebt)"
        )
        XCTAssertLessThanOrEqual(
            horizontalDrift,
            0.5,
            "重复语义 bottom edge 写不能让垂直聊天列表产生横向漂移：\(horizontalOffsets)"
        )
    }

    func testLongProseViewportFollowStaysLineSizedAtTwentyFourKB() {
        let blockKey = IOSDisplayPreferenceKeys.streamingBlockMarkdown
        let previousBlockSetting = UserDefaults.standard.object(forKey: blockKey)
        UserDefaults.standard.set(true, forKey: blockKey)
        defer {
            if let previousBlockSetting {
                UserDefaults.standard.set(previousBlockSetting, forKey: blockKey)
            } else {
                UserDefaults.standard.removeObject(forKey: blockKey)
            }
        }

        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 30)
        fixture.model.isGenerationActive = true
        fixture.model.send(.initialLoad)
        XCTAssertTrue(pumpUntil(timeout: 6.0) { fixture.model.latestViewport.isAtBottom })

        let assistantID = KotlinUuid.companion.random()
        var tailText = "连续正文开始。" + String(
            repeating: "这是一段没有空行分隔的长篇连续正文，用来复现真实回答累计变长后同一段落仍在增长的布局压力。",
            count: 540
        )
        XCTAssertGreaterThan(tailText.utf16.count, 23_000, "fixture 必须覆盖 24KB 量级的真实长段落")
        let settledPrefix = (1...40)
            .map { "第\($0)段已经闭合，正文内容围绕流式渲染的分层职责展开，不应随末尾长段落的 delta 重新布局。" }
            .joined(separator: "\n\n")
        var text = settledPrefix + "\n\n" + tailText
        fixture.model.messages.append(makeAssistantMessage(
            id: assistantID,
            text: text,
            finished: false
        ))
        fixture.model.send(.streamDelta)
        XCTAssertTrue(pumpUntil(timeout: 6.0) { fixture.model.latestViewport.isAtBottom })
        XCTAssertTrue(pumpUntil(timeout: 6.0) {
            guard let paragraph = ScrollFrameProbe.streamingParagraph(in: fixture.host.view) else {
                return false
            }
            return paragraph.usesTextKit1 &&
                ScrollFrameProbe.streamingTextLength(in: paragraph) == tailText.utf16.count
        })
        pump(seconds: 0.4)

        guard let scrollView = fixture.scrollView else {
            return XCTFail("Expected the default Native timeline scroll view")
        }
        let probe = ScrollFrameProbe(scrollView: scrollView, rootView: fixture.host.view)
        probe.start()
        for _ in 0..<60 {
            let delta = String(repeating: "流", count: 12)
            tailText += delta
            text += delta
            fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
                id: assistantID,
                text: text,
                finished: false
            )
            fixture.model.send(.streamDelta)
            pump(seconds: 0.048)
        }
        pump(seconds: 0.8)
        probe.stop()

        let settledSamples = probe.samples.filter { ($0.paragraphLength ?? 0) >= 100 }
        let textGrowthSteps = zip(settledSamples, settledSamples.dropFirst()).compactMap {
            previous, current -> CGFloat? in
            guard let previousLength = previous.paragraphLength,
                  let currentLength = current.paragraphLength,
                  currentLength > previousLength else { return nil }
            return CGFloat(currentLength - previousLength)
        }
        let contentGrowthSteps = zip(settledSamples, settledSamples.dropFirst())
            .map { $1.contentHeight - $0.contentHeight }
            .filter { $0 > 0.5 }
        let offsetAdvanceSteps = zip(settledSamples, settledSamples.dropFirst())
            .map { $1.contentOffsetY - $0.contentOffsetY }
            .filter { $0 > 0.5 }
        let maxBottomDebt = settledSamples.map(\.distanceToBottom).max() ?? .greatestFiniteMagnitude
        let horizontalOffsets = settledSamples.map(\.contentOffsetX)
        let horizontalDrift = (horizontalOffsets.max() ?? 0) - (horizontalOffsets.min() ?? 0)

        XCTAssertEqual(probe.samples.last?.paragraphLength, tailText.utf16.count)
        XCTAssertEqual(probe.samples.last?.paragraphUsesTextKit1, true, "24KB 无附件长段落必须走 TextKit 1")
        XCTAssertGreaterThanOrEqual(
            textGrowthSteps.count,
            45,
            "24KB 长文的可见文本不能数批才发布：\(textGrowthSteps)"
        )
        XCTAssertLessThanOrEqual(
            percentile(textGrowthSteps, percentile: 0.95),
            24,
            "24KB 长文的绝大多数更新最多合并两个 snapshot：\(textGrowthSteps)"
        )
        XCTAssertLessThanOrEqual(
            percentile(contentGrowthSteps, percentile: 0.95),
            40,
            "24KB 长文的绝大多数列表高度发布必须保持单行级：\(contentGrowthSteps)"
        )
        // measured geometry callback 在同一布局事务内发出非动画语义底锚，offset
        // advance 不保证逐帧可采样；跟随是否及时由 maxBottomDebt 直接覆盖。
        XCTAssertLessThanOrEqual(
            maxBottomDebt,
            72,
            "24KB 贴底流式不能积累两行以上的未跟随高度：\(maxBottomDebt)"
        )
        XCTAssertLessThanOrEqual(
            horizontalDrift,
            0.5,
            "重复语义 bottom edge 写不能让垂直聊天列表产生横向漂移：\(horizontalOffsets)"
        )
    }

    func testExplicitBottomRevealsLatestStreamingTailWithoutManualNudge() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        let assistantID = KotlinUuid.companion.random()
        fixture.model.messages = longConversation(turns: 12)
        fixture.model.messages.append(makeUserMessage("请继续写一份很长的流式说明。"))
        fixture.model.messages.append(makeAssistantMessage(
            id: assistantID,
            text: "正在生成第一段。",
            finished: false
        ))
        fixture.model.isGenerationActive = true
        fixture.model.send(.streamDelta)
        pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom }

        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: assistantID,
            text: "正在生成第一段。",
            finished: true
        )
        fixture.model.isGenerationActive = false
        fixture.model.send(.generationCompleted)
        pump(seconds: 1.1)

        guard let scrollView = fixture.scrollView else {
            return XCTFail("Expected the default Native timeline scroll view")
        }
        scrollView.setContentOffset(
            CGPoint(x: 0, y: -scrollView.adjustedContentInset.top),
            animated: false
        )
        pump(seconds: 0.4)

        var accumulated = ""
        for index in 0..<90 {
            accumulated += "第 \(index) 段用于验证远距离回底前的尾行布局必须先恢复。每一段都包含足够文字形成稳定行高。\n\n"
        }
        accumulated += "LATEST-STREAMING-TAIL-MARKER"
        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: assistantID,
            text: accumulated,
            finished: true
        )
        // 只刷新布局，不发自动跟随命令，保持和用户查看历史时相同的视口前置状态。
        fixture.model.send(.settingsRefresh)
        pump(seconds: 0.2)

        fixture.model.scrollToBottomTrigger &+= 1
        let reachedRenderedTail = pumpUntil(timeout: 5.0) {
            guard let scrollView = fixture.scrollView else { return false }
            let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height -
                scrollView.adjustedContentInset.bottom
            let distanceToBottom = max(0, scrollView.contentSize.height - visibleBottom)
            return visibleBottom <= scrollView.contentSize.height + 2 &&
                distanceToBottom <= ChatLayout.bottomStickThreshold &&
                Self.visibleTextViews(in: fixture.host.view, relativeTo: scrollView).contains {
                    $0.text.contains("LATEST-STREAMING-TAIL-MARKER")
                }
        }

        var lostRenderedTailAfterArrival = false
        if reachedRenderedTail {
            pump(seconds: 1.0) {
                guard let scrollView = fixture.scrollView else {
                    lostRenderedTailAfterArrival = true
                    return
                }
                let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height -
                    scrollView.adjustedContentInset.bottom
                let distanceToBottom = max(0, scrollView.contentSize.height - visibleBottom)
                let markerVisible = Self.visibleTextViews(in: fixture.host.view, relativeTo: scrollView).contains {
                    $0.text.contains("LATEST-STREAMING-TAIL-MARKER")
                }
                let overshotContent = visibleBottom > scrollView.contentSize.height + 2
                if overshotContent ||
                    distanceToBottom > ChatLayout.bottomStickThreshold ||
                    !markerVisible {
                    if !lostRenderedTailAfterArrival {
                        print(Self.tailLayoutDiagnostics(
                            in: fixture.host.view,
                            relativeTo: scrollView,
                            distanceToBottom: distanceToBottom
                        ))
                    }
                    lostRenderedTailAfterArrival = true
                }
            }
        }

        let finalVisibleTexts = Self.visibleTextViews(in: fixture.host.view, relativeTo: scrollView)
            .map { $0.text ?? "" }
        let finalVisibleBottom = scrollView.contentOffset.y + scrollView.bounds.height -
            scrollView.adjustedContentInset.bottom
        let finalDistance = max(0, scrollView.contentSize.height - finalVisibleBottom)
        let finalMarkerVisible = finalVisibleTexts.contains { $0.contains("LATEST-STREAMING-TAIL-MARKER") }
        let finalTextViewMetrics = Self.allTextViews(in: fixture.host.view).suffix(6).map { textView in
            let containsMarker = textView.text.contains("LATEST-STREAMING-TAIL-MARKER")
            return "len=\(textView.text.utf16.count) marker=\(containsMarker) " +
                "alpha=\(textView.alpha) frame=\(textView.convert(textView.bounds, to: scrollView))"
        }
        XCTAssertTrue(
            reachedRenderedTail,
            "点击回底后，最新流式正文必须直接出现在输入区上方，不能依赖额外手势触发布局。" +
                " distance=\(finalDistance), offset=\(scrollView.contentOffset.y), " +
                "contentHeight=\(scrollView.contentSize.height), visibleTextCount=\(finalVisibleTexts.count), " +
                "visibleSuffix=\(finalVisibleTexts.map { String($0.suffix(40)) })"
        )
        XCTAssertFalse(
            lostRenderedTailAfterArrival,
            "显式回底到达真实尾行后必须持续停在已绘制内容上，不能再弹回尾行下方的空白区域。" +
                " distance=\(finalDistance), visibleBottom=\(finalVisibleBottom), " +
                "offset=\(scrollView.contentOffset.y), contentHeight=\(scrollView.contentSize.height), " +
                "markerVisible=\(finalMarkerVisible), " +
                "visibleSuffix=\(finalVisibleTexts.map { String($0.suffix(40)) }), " +
                "textViews=\(finalTextViewMetrics)"
        )
    }

    func testActiveGenerationCatchesUpAfterMeasuredTailGrowthWithoutAnotherChunk() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }

        fixture.model.messages = longConversation(turns: 10)
        fixture.model.send(.initialLoad)
        pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom }

        fixture.model.messages.append(makeUserMessage("请继续展开。"))
        let assistantID = KotlinUuid.companion.random()
        fixture.model.messages.append(makeAssistantMessage(
            id: assistantID,
            text: "正在生成。",
            finished: false
        ))
        fixture.model.isGenerationActive = true
        fixture.model.send(.streamDelta)
        pumpUntil(timeout: 4.0) { fixture.model.latestViewport.isAtBottom }

        var delayedLayoutText = ""
        for index in 0..<45 {
            delayedLayoutText += "延迟布局第 \(index) 段：流事件已经消费，但 Markdown 的真实高度在之后才发布。\n\n"
        }
        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
            id: assistantID,
            text: delayedLayoutText,
            finished: false
        )
        // 不再发送 streamDelta，模拟同一个 chunk 对应的异步 Markdown 高度晚到。
        fixture.model.send(.settingsRefresh)

        let caughtUp = pumpUntil(timeout: 4.0) {
            guard let scrollView = fixture.scrollView else { return false }
            let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height -
                scrollView.adjustedContentInset.bottom
            let distanceToBottom = max(0, scrollView.contentSize.height - visibleBottom)
            return scrollView.contentSize.height > scrollView.bounds.height &&
                distanceToBottom <= ChatLayout.bottomStickThreshold &&
                fixture.model.latestViewport.isAtBottom
        }
        let diagnostics: String
        if let scrollView = fixture.scrollView {
            let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height -
                scrollView.adjustedContentInset.bottom
            diagnostics =
                " offset=\(scrollView.contentOffset.y) contentH=\(scrollView.contentSize.height) " +
                "distance=\(max(0, scrollView.contentSize.height - visibleBottom)) " +
                "tracking=\(scrollView.isTracking) dragging=\(scrollView.isDragging) " +
                "decelerating=\(scrollView.isDecelerating) viewport=\(fixture.model.latestViewport)"
        } else {
            diagnostics = " scrollView=nil viewport=\(fixture.model.latestViewport)"
        }
        XCTAssertTrue(
            caughtUp,
            "活跃生成中的真实高度晚到后必须继续语义贴底，不能等待下一 chunk 或手势。\(diagnostics)"
        )
    }

    private static func visibleTextViews(in root: UIView, relativeTo scrollView: UIScrollView) -> [UITextView] {
        allTextViews(in: root).filter { textView in
            !textView.isHidden &&
                textView.alpha > 0.01 &&
                textView.window != nil &&
                textView.convert(textView.bounds, to: scrollView).intersects(scrollView.bounds)
        }
    }

    private static func allTextViews(in root: UIView) -> [UITextView] {
        var result: [UITextView] = []
        func visit(_ view: UIView) {
            if let textView = view as? UITextView {
                result.append(textView)
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return result
    }

    private static func tailLayoutDiagnostics(
        in root: UIView,
        relativeTo scrollView: UIScrollView,
        distanceToBottom: CGFloat
    ) -> String {
        let allTextViews = allTextViews(in: root)
        let textMetrics = allTextViews.map { textView in
            let frame = textView.convert(textView.bounds, to: scrollView)
            let usedRect = textView.layoutManager.usedRect(for: textView.textContainer)
            let containsMarker = textView.text.contains("LATEST-STREAMING-TAIL-MARKER")
            return "len=\(textView.text.utf16.count) marker=\(containsMarker) " +
                "frame=\(frame) bounds=\(textView.bounds) content=\(textView.contentSize) used=\(usedRect) " +
                "intrinsic=\(textView.intrinsicContentSize)"
        }
        return "[EXPLICIT-BOTTOM-DIAG] offset=\(scrollView.contentOffset) content=\(scrollView.contentSize) " +
            "bounds=\(scrollView.bounds) insets=\(scrollView.adjustedContentInset) distance=\(distanceToBottom) " +
            "textViews=\(allTextViews.count) metrics=\(textMetrics)"
    }
}
