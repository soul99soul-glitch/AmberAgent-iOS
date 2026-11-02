import XCTest
@testable import AmberMac

final class DesktopToolActivityTests: XCTestCase {
    private func activity(_ name: String, _ input: String, _ status: DesktopToolCall.Status = .complete) -> DesktopToolActivity {
        DesktopToolActivity(DesktopToolCall(id: "1", name: name, input: input, status: status))
    }

    func testMemoryActionsDescribeReadAndWrite() {
        XCTAssertEqual(activity("memory_tool", #"{"action":"list"}"#, .running).title, "正在读取记忆")
        XCTAssertEqual(activity("memory_tool", #"{"action":"list"}"#).title, "已读取记忆")
        XCTAssertEqual(activity("memory_tool", #"{"action":"create","content":"x"}"#).title, "已写入记忆")
        XCTAssertEqual(activity("memory_tool", #"{"action":"edit","id":1}"#, .pending).title, "等待确认：更新记忆")
    }

    func testDetailsComeFromArguments() {
        let search = activity("search_web", #"{"query":"  swift   concurrency "}"#)
        XCTAssertEqual(search.summary, "已搜索网页 · swift concurrency")
        XCTAssertEqual(activity("scrape_web", #"{"url":"https://www.example.com/a"}"#).detail, "example.com")
        XCTAssertEqual(activity("workspace_file_read", #"{"path":"notes/plan.md"}"#).detail, "plan.md")
        XCTAssertEqual(activity("workspace_file_list", "{}").summary, "已查看工作区文件")
    }

    func testUnknownToolsAndBadInputFallBackToName() {
        let unknown = activity("custom_tool", "not json", .denied)
        XCTAssertEqual(unknown.title, "已拒绝：使用 custom_tool")
        XCTAssertNil(unknown.detail)
    }

    func testPluginListAndPluginInstallActivities() {
        let listRunning = activity("plugin_list", "{}", .running)
        XCTAssertEqual(listRunning.title, "正在查看已安装插件")
        XCTAssertEqual(listRunning.englishTitle, "Listing installed plugins")

        let listDone = activity("plugin_list", "{}", .complete)
        XCTAssertEqual(listDone.title, "已查看已安装插件")
        XCTAssertEqual(listDone.englishTitle, "Listed installed plugins")

        let installPending = activity("plugin_install", #"{"path":"plugins/note_helper"}"#, .pending)
        XCTAssertEqual(installPending.title, "等待确认：安装插件")
        XCTAssertEqual(installPending.englishTitle, "Awaiting approval: Installing plugin")
        XCTAssertEqual(installPending.detail, "note_helper")

        let installDone = activity("plugin_install", #"{"path":"note_helper/plugin.json"}"#, .complete)
        XCTAssertEqual(installDone.summary, "已安装插件 · plugin.json")
        XCTAssertEqual(installDone.englishSummary, "Installed plugin · plugin.json")
    }

    func testSingleLineTurnToolProgressUpdatesInPlaceAcrossSteps() throws {
        let step1Running = DesktopToolCall(id: "t1", name: "search_web", input: #"{"query":"swift actor"}"#, status: .running)
        let p1 = try XCTUnwrap(DesktopTurnToolProgress(tools: [step1Running], isStreaming: true, hasReplyText: false))
        XCTAssertEqual(p1.status, .running)
        XCTAssertEqual(p1.headline, "正在搜索网页 · swift actor")
        XCTAssertNil(p1.stepBadge)

        let step1Done = DesktopToolCall(id: "t1", name: "search_web", input: #"{"query":"swift actor"}"#, status: .complete)
        let step2Running = DesktopToolCall(id: "t2", name: "scrape_web", input: #"{"url":"https://developer.apple.com/swift"}"#, status: .running)
        let p2 = try XCTUnwrap(DesktopTurnToolProgress(tools: [step1Done, step2Running], isStreaming: true, hasReplyText: false))
        XCTAssertEqual(p2.status, .running)
        XCTAssertEqual(p2.headline, "正在读取网页 · developer.apple.com")
        XCTAssertEqual(p2.stepBadge, "第 2/2 步")

        let step2Done = DesktopToolCall(id: "t2", name: "scrape_web", input: #"{"url":"https://developer.apple.com/swift"}"#, status: .complete)
        let p3 = try XCTUnwrap(DesktopTurnToolProgress(tools: [step1Done, step2Done], isStreaming: true, hasReplyText: false))
        XCTAssertEqual(p3.status, .running)
        XCTAssertEqual(p3.headline, "正在整理回复 · 已读取网页 · developer.apple.com")
        XCTAssertEqual(p3.stepBadge, "已完成 2 步")

        let p4 = try XCTUnwrap(DesktopTurnToolProgress(tools: [step1Done, step2Done], isStreaming: false, hasReplyText: true))
        XCTAssertEqual(p4.status, .complete)
        XCTAssertEqual(p4.headline, "已完成 2 步操作 · 已读取网页 · developer.apple.com")
        XCTAssertEqual(p4.stepBadge, "2 步")
    }

    func testTranscriptTurnGroupingCoalescesMultiStepAssistantTurnsAndSeparatesConcurrentTasks() {
        let userA = DesktopMessage(role: .user, text: "查一下 Swift 6 并发")
        let round1A = DesktopMessage(
            role: .assistant,
            text: "",
            tools: [DesktopToolCall(id: "c1", name: "search_web", input: #"{"query":"swift 6"}"#, status: .complete)]
        )
        let round2A = DesktopMessage(
            role: .assistant,
            text: "已整理好结论",
            state: .streaming,
            tools: [DesktopToolCall(id: "c2", name: "scrape_web", input: #"{"url":"https://swift.org"}"#, status: .complete)]
        )
        let userB = DesktopMessage(role: .user, text: "顺便算一下 2+2")
        let replyB = DesktopMessage(role: .assistant, text: "等于 4", state: .complete)

        let projected = DesktopTranscriptTurnGrouping.projectRows(
            messages: [userA, round1A, round2A, userB, replyB],
            hidesToolCalls: false,
            activeOwnedGroups: [[round1A.id, round2A.id]]
        )
        XCTAssertEqual(projected.count, 4, "Multi-round assistant tool messages in Task A must coalesce into 1 row")
        XCTAssertEqual(projected[0].element.id, userA.id)
        XCTAssertEqual(projected[1].element.id, round1A.id, "Coalesced row stays anchored at the turn's first assistant ID")
        XCTAssertEqual(projected[1].element.tools.map(\.id), ["c1", "c2"])
        XCTAssertEqual(projected[1].element.text, "已整理好结论")
        XCTAssertEqual(projected[1].element.state, .streaming)
        XCTAssertEqual(projected[2].element.id, userB.id)
        XCTAssertEqual(projected[3].element.id, replyB.id)
    }
}
