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
}
