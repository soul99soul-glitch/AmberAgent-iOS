import XCTest
import SwiftUI
import Shared
@testable import iosApp

/// One assistant turn draws one progress line, whichever messages its tools arrive in.
@MainActor
final class ChatAssistantTurnProgressTests: ChatNativeTimelineReplayTestCase {
    private let doneJSON = #"{"ok":true,"status":"completed"}"#

    private func tool(
        _ id: String, _ name: String, result: String? = nil,
        approval: ToolApprovalState = ToolApprovalState.Auto.shared
    ) -> UIMessagePart.Tool {
        UIMessagePart.Tool(toolCallId: id, toolName: name, input: "{}",
            output: result.map { [UIMessagePart.Text(text: $0, metadata: nil)] } ?? [],
            approvalState: approval, streamIndex: nil, metadata: nil)
    }

    private func text(_ value: String) -> UIMessagePart.Text { UIMessagePart.Text(text: value, metadata: nil) }

    private func reasoning(_ value: String, finished: Bool = false) -> UIMessagePart.Reasoning {
        let start = KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 1_700_000_000_000)
        let end = finished
            ? KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: 1_700_000_003_000)
            : nil
        return UIMessagePart.Reasoning(reasoning: value, createdAt: start, finishedAt: end, metadata: nil)
    }

    private func assistant(_ parts: [UIMessagePart], id: KotlinUuid = KotlinUuid.companion.random()) -> UIMessage {
        UIMessage(id: id, role: MessageRole.assistant, parts: parts, annotations: [],
            createdAt: chatNowLocalDateTime(), finishedAt: nil, modelId: nil, usage: nil, translation: nil)
    }

    private func entries(_ messages: [UIMessage], generating: Bool) -> [NativeTimelineEntry] {
        NativeTimelineProjector.build(messages: messages, event: .toolResultAppended, isGenerationActive: generating)
            .entries.filter { $0.kind == .message }
    }

    /// The single line this projection draws; fails if the turn draws zero or several.
    private func line(_ messages: [UIMessage], generating: Bool) throws -> ChatTaskRunSegment {
        let heads = entries(messages, generating: generating).compactMap { $0.assistantTurn?.progress }
        XCTAssertEqual(heads.count, 1)
        return ChatTaskStreamGrouping.turnSegment(for: try XCTUnwrap(heads.first))
    }

    /// Text + tool first, then tool-only messages, then the reply: the real shape of a daily-news run.
    private func newsRun() -> [[UIMessage]] {
        let user = UIMessage.companion.user(prompt: "帮我做今天的游戏新闻日报")
        let m1 = KotlinUuid.companion.random(), m2 = KotlinUuid.companion.random()
        let m3 = KotlinUuid.companion.random(), m4 = KotlinUuid.companion.random()
        let intro = text("好的，我先搜集今天的游戏新闻。")
        let first = assistant([intro, tool("call_0", "search_web", result: doneJSON)], id: m1)
        let second = assistant([tool("call_0", "workspace_file_list", result: doneJSON)], id: m2)
        return [
            [user, assistant([intro, tool("call_0", "search_web")], id: m1)],
            [user, first, assistant([tool("call_0", "workspace_file_list")], id: m2)],
            [user, first, second, assistant([tool("call_1", "scrape_web")], id: m3)],
            [user, first, second, assistant([tool("call_1", "scrape_web", result: doneJSON)], id: m3),
             assistant([text("# 今日游戏新闻日报\n\n三条要闻已整理完毕。")], id: m4)]
        ]
    }

    func testMultiMessageRunKeepsOneLineThatFollowsRealSteps() throws {
        let frames = newsRun()
        var headIDs: Set<String> = []
        var lines: [String] = []
        for frame in frames {
            let segment = try line(frame, generating: true)
            XCTAssertTrue(segment.rollupState.isLive)
            XCTAssertFalse(segment.headline.contains("_"), segment.headline)
            headIDs.insert(segment.id)
            lines.append(segment.headline)
        }
        XCTAssertEqual(headIDs.count, 1, "the line keeps one identity while the run grows")
        XCTAssertEqual(Set(lines).count, lines.count, "each real step changes the text: \(lines)")
        XCTAssertEqual(lines.first, "正在搜索网页…")
        XCTAssertEqual(lines.last, "正在整理回复…")

        let toolOnly = entries(frames[2], generating: true)
        XCTAssertEqual(toolOnly[2].assistantTurn?.isCollapsedMember, true)
        XCTAssertEqual(toolOnly[3].assistantTurn?.isCollapsedMember, true)
    }

    func testFinishedAndReopenedRunStaysCompactAndKeepsReplyAndHistory() throws {
        let messages = try XCTUnwrap(newsRun().last)
        let segment = try line(messages, generating: false)
        XCTAssertEqual(segment.headline, "已执行 3 步")
        XCTAssertEqual(segment.tools.count, 3, "execution detail stays available")
        let rows = entries(messages, generating: false)
        XCTAssertEqual(rows[3].assistantTurn?.isCollapsedMember, true)
        XCTAssertEqual(rows[4].assistantTurn?.isCollapsedMember, false, "the reply stays visible")
    }

    func testRunCutByLoadedWindowStillDrawsOneLineWithAllSteps() throws {
        let messages = try XCTUnwrap(newsRun().last)
        let projection = NativeTimelineProjector.build(
            messages: messages, event: .toolResultAppended, isGenerationActive: false, startIndex: 2
        )
        let heads = projection.entries.compactMap { $0.assistantTurn?.progress }
        XCTAssertEqual(heads.count, 1)
        XCTAssertEqual(heads.first?.tools.count, 3)
    }

    func testApprovalFailureAndInterruptionSurfaceTheirRealState() throws {
        let user = UIMessage.companion.user(prompt: "go")
        let done = assistant([tool("a", "search_web", result: doneJSON)])

        let pending = try line([user, done, assistant([
            tool("b", "scrape_web", approval: ToolApprovalState.Pending.shared)
        ])], generating: true)
        XCTAssertEqual(pending.rollupState, .approvalPending(count: 1))

        let failed = try line([user, done, assistant([
            tool("b", "scrape_web", result: #"{"ok":false,"status":"failed","error":"站点拒绝访问"}"#)
        ]), assistant([text("没能读到。")])], generating: false)
        guard case .needsAttention = failed.rollupState else {
            return XCTFail("failure must survive a final reply: \(failed.rollupState)")
        }
        XCTAssertEqual(failed.subtitle, "站点拒绝访问")

        let interrupted = try line([user, done, assistant([tool("b", "scrape_web")])], generating: false)
        XCTAssertEqual(interrupted.rollupState, .cancelled)
    }

    func testMediaToolsAndPhoneOnlyTurnsAreNotSwallowed() throws {
        let user = UIMessage.companion.user(prompt: "go")
        let rows = entries([
            user,
            assistant([tool("a", "search_web", result: doneJSON)]),
            assistant([tool("b", "generate_image")])
        ], generating: true)
        XCTAssertEqual(rows[2].assistantTurn?.isCollapsedMember, false, "image placeholder stays on screen")

        let phoneRows = entries([user, assistant([tool("p", "phone_act")])], generating: true)
        XCTAssertNil(phoneRows[1].assistantTurn)
        XCTAssertNotNil(phoneRows[1].phoneToolGroup?.headSummary)
    }

    func testTurnMixingPhoneAndOtherToolsDrawsOneLine() throws {
        let segment = try line([
            UIMessage.companion.user(prompt: "go"),
            assistant([tool("p", "phone_act", result: doneJSON)]),
            assistant([tool("w", "search_web", result: doneJSON)]),
            assistant([tool("q", "phone_observe", result: doneJSON)])
        ], generating: false)
        XCTAssertEqual(segment.tools.count, 3)
    }

    func testOnlyThinkingWithoutReplyShowsSingleThinkingLineAndSettlesOnReplyOrStop() throws {
        let user = UIMessage.companion.user(prompt: "按一下能回弹就熟了对吧")
        let m1 = KotlinUuid.companion.random()
        let rawReasoning = reasoning(
            "The user asks: pressing and it springs back means cooked, right? I should be honest: spring-back is a rough indicator, not a reliable doneness test for raw meat filling."
        )

        // 1. Live thinking without reply text -> single "正在思考" progress line, no English body or duration subtitle
        let liveThinkingSegment = try line([user, assistant([rawReasoning], id: m1)], generating: true)
        XCTAssertTrue(liveThinkingSegment.rollupState.isLive)
        XCTAssertEqual(liveThinkingSegment.headline, "正在思考")
        XCTAssertNil(liveThinkingSegment.subtitle)
        XCTAssertTrue(liveThinkingSegment.tools.isEmpty)

        // 2. Once visible reply text arrives (without tools), the thinking progress line disappears cleanly
        let replyText = text("只靠“按一下能回弹”判断生肉包熟没熟不够稳妥——回弹主要说明外皮面筋定型了，不能保证中间肉馅已经熟透。")
        let withReplyMessages = [user, assistant([rawReasoning, replyText], id: m1)]
        let liveReplyEntries = entries(withReplyMessages, generating: true)
        XCTAssertEqual(liveReplyEntries.compactMap { $0.assistantTurn?.progress }.count, 0)
        let settledReplyEntries = entries(withReplyMessages, generating: false)
        XCTAssertEqual(settledReplyEntries.compactMap { $0.assistantTurn?.progress }.count, 0)
        let replySegments = ChatTaskStreamGrouping.segments(
            for: withReplyMessages[1],
            messageID: m1.toHexDashString(),
            isGeneratingTail: true
        )
        XCTAssertEqual(replySegments.count, 1, "Only the final reply text segment remains once reply text arrives")
        if case .text(_, _, let part) = replySegments[0] {
            XCTAssertTrue(part.text.contains("不能保证中间肉馅已经熟透"))
        } else {
            XCTFail("Expected .text segment")
        }

        // 3. Stopped/cancelled while only thinking (no reply text and no tools) -> settles to "已停止"
        let stoppedSegment = try line([user, assistant([rawReasoning], id: m1)], generating: false)
        XCTAssertFalse(stoppedSegment.rollupState.isLive)
        XCTAssertEqual(stoppedSegment.rollupState, .cancelled)
        XCTAssertEqual(stoppedSegment.headline, "已停止")
        XCTAssertNil(stoppedSegment.subtitle)
    }

    func testThinkingToToolToThinkingToReplyInPlaceTransitionWithoutDuplicateLines() throws {
        let user = UIMessage.companion.user(prompt: "按一下能回弹就熟了对吧")
        let m1 = KotlinUuid.companion.random()
        let m2 = KotlinUuid.companion.random()
        let thought1 = reasoning("The user asks whether spring-back means raw meat buns are cooked.")
        let thought2 = reasoning("Now synthesize the food-safety timing and internal temperature guidance.")
        let finalReply = text("只靠“按一下能回弹”判断肉包熟没熟不够稳妥：外皮回弹只代表面皮定型，最稳妥是水开后中大火蒸够 12–15 分钟。")

        let frames: [[UIMessage]] = [
            // Frame 1: Thinking only
            [user, assistant([thought1], id: m1)],
            // Frame 2: Thinking -> Tool executing
            [user, assistant([thought1, tool("call_0", "search_web")], id: m1)],
            // Frame 3: Thinking -> Tool finished -> Thinking again in message 2
            [
                user,
                assistant([thought1, tool("call_0", "search_web", result: doneJSON)], id: m1),
                assistant([thought2], id: m2)
            ],
            // Frame 4: Thinking -> Tool -> Thinking -> Streaming reply in message 2
            [
                user,
                assistant([thought1, tool("call_0", "search_web", result: doneJSON)], id: m1),
                assistant([thought2, finalReply], id: m2)
            ]
        ]

        var headIDs: Set<String> = []
        var headlines: [String] = []
        for frame in frames {
            let seg = try line(frame, generating: true)
            XCTAssertTrue(seg.rollupState.isLive)
            headIDs.insert(seg.id)
            headlines.append(seg.headline)
        }

        XCTAssertEqual(headIDs.count, 1, "All 4 stages share the exact same single progress line identity")
        XCTAssertEqual(
            headlines,
            ["正在思考", "正在搜索网页…", "正在思考", "正在整理回复…"]
        )

        // Verify Frame 3 collapses message 2 (no duplicate thinking line)
        let frame3Rows = entries(frames[2], generating: true)
        XCTAssertEqual(frame3Rows[2].assistantTurn?.isCollapsedMember, true)

        // Verify Frame 4 & settled completion keep message 2 visible with full reply text and 1 settled progress line
        let settled = try line(frames[3], generating: false)
        XCTAssertFalse(settled.rollupState.isLive)
        XCTAssertEqual(settled.headline, "已执行 1 步")
        let settledRows = entries(frames[3], generating: false)
        XCTAssertEqual(settledRows[2].assistantTurn?.isCollapsedMember, false)
    }

    func testRenderThinkingToToolToThinkingToReplyTimelineSnapshots() async throws {
        let archiveDir = URL(
            fileURLWithPath: "/Users/arquiel/.synara/userdata/project-context/0f3f2134-3ef9-4137-8b75-6d1496ff94d1/library/snapshots/ios-thinking-single-line-progress",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let priorUser = UIMessage.companion.user(prompt: "肉包上锅蒸怎么判断熟没熟？")
        let priorAssistant = assistant([
            text("肉包上锅蒸是对的，水开后再计时：\n• 冷藏的蒸 10–12 分钟，冷冻的直接 14–15 分钟\n• 蒸完关火焖 2 分钟再开盖，皮不会塌")
        ])
        let followupUser = UIMessage.companion.user(prompt: "按一下能回弹就熟了对吧")
        let m1 = KotlinUuid.companion.random()
        let m2 = KotlinUuid.companion.random()
        let rawReasoning1 = reasoning(
            "The user asks: pressing and it springs back means cooked, right? I should be honest: spring-back is a rough indicator, not a reliable doneness test for raw meat filling."
        )
        let rawReasoning2 = reasoning(
            "Combine steam timing and core meat doneness indicators into a concise practical answer."
        )
        let finalReply = text(
            "只靠「按一下能回弹」还不够稳妥——回弹主要说明外皮面筋已经定型，但中间的生肉馅未必熟透。\n\n更稳的判断方式：\n• **看水开后计时**：中大火蒸够 12 分钟（冷冻 15 分钟）\n• **看底部与气味**：包子底面干爽不粘垫布，闻得到浓郁肉香而非生面味"
        )

        let frame1ThinkingOnly: [UIMessage] = [
            priorUser,
            priorAssistant,
            followupUser,
            assistant([rawReasoning1], id: m1)
        ]
        let frame2ToolRunning: [UIMessage] = [
            priorUser,
            priorAssistant,
            followupUser,
            assistant([rawReasoning1, tool("call_0", "search_web")], id: m1)
        ]
        let frame3SecondThinking: [UIMessage] = [
            priorUser,
            priorAssistant,
            followupUser,
            assistant([rawReasoning1, tool("call_0", "search_web", result: doneJSON)], id: m1),
            assistant([rawReasoning2], id: m2)
        ]
        let frame4FinalReply: [UIMessage] = [
            priorUser,
            priorAssistant,
            followupUser,
            assistant([rawReasoning1, finalReply], id: m1)
        ]

        let fixture = makeFixture { model in
            model.isGenerationActive = true
            model.messages = frame1ThinkingOnly
            model.currentConversationID = "thinking-progress-replay"
        }
        let model = fixture.model
        defer { fixture.tearDown() }

        func captureToArchive(_ name: String) async throws {
            try await Task.sleep(nanoseconds: 350_000_000)
            fixture.host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
            }
            let png = try XCTUnwrap(image.pngData())
            try png.write(to: archiveDir.appendingPathComponent(name), options: .atomic)
        }

        // Snapshot 1: Only thinking ("正在思考" single line, no pink reasoning box or capsule)
        model.messages = frame1ThinkingOnly
        model.send(.toolResultAppended)
        try await captureToArchive("01-thinking-only-single-line.png")

        // Snapshot 2: Thinking -> Tool ("正在搜索网页…")
        model.messages = frame2ToolRunning
        model.send(.toolResultAppended)
        try await captureToArchive("02-thinking-to-tool-transition.png")

        // Snapshot 3: Tool -> Second Thinking ("正在思考", no duplicate lines)
        model.messages = frame3SecondThinking
        model.send(.toolResultAppended)
        try await captureToArchive("03-tool-to-second-thinking-transition.png")

        // Snapshot 4: Settled into final reply text (thinking line disappears cleanly on pure thinking->reply)
        model.isGenerationActive = false
        model.messages = frame4FinalReply
        model.send(.generationCompleted)
        try await captureToArchive("04-thinking-settled-into-final-reply.png")
    }

    /// Mounted in the real timeline: every frame goes through the production signal path.
    func testRenderLiveRunFrames() async throws {
        let frames = newsRun()
        let fixture = makeFixture { model in
            model.isGenerationActive = true
            model.messages = frames[0]
            model.currentConversationID = "progress-replay"
        }
        let model = fixture.model
        defer { fixture.tearDown() }
        for (index, frame) in frames.enumerated() {
            model.messages = frame
            model.send(.toolResultAppended)
            try await Task.sleep(nanoseconds: 500_000_000)
            save(fixture, name: "progress-frame-\(index + 1)")
        }
        model.isGenerationActive = false
        model.send(.generationCompleted)
        try await Task.sleep(nanoseconds: 500_000_000)
        save(fixture, name: "progress-frame-5-finished")
    }

    private func save(_ fixture: Fixture, name: String) {
        fixture.host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
            fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ios-progress-single-line/\(name).png"))
    }
}
