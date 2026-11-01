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
