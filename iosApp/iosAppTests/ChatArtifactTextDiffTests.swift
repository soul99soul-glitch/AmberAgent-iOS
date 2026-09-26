import XCTest
@testable import iosApp

final class ChatArtifactTextDiffTests: XCTestCase {
    func testShowsRemovedAndAddedLines() {
        let lines = ChatArtifactTextDiff.lines(previous: "标题\n旧值", current: "标题\n新值")

        XCTAssertEqual(lines, [
            .init(text: "− 旧值", kind: .removed),
            .init(text: "+ 新值", kind: .added)
        ])
    }

    func testReportsIdenticalContent() {
        XCTAssertEqual(
            ChatArtifactTextDiff.lines(previous: "相同\n内容", current: "相同\n内容"),
            [.init(text: "两版内容相同", kind: .unchanged)]
        )
    }

    func testOrdersChangesByTheirPositionAndStripsCarriageReturns() {
        let lines = ChatArtifactTextDiff.lines(
            previous: "开头\r\n旧一\r\n中间\r\n旧二\r\n结尾",
            current: "开头\r\n新一\r\n中间\r\n新二\r\n结尾"
        )

        XCTAssertEqual(lines, [
            .init(text: "− 旧一", kind: .removed),
            .init(text: "+ 新一", kind: .added),
            .init(text: "− 旧二", kind: .removed),
            .init(text: "+ 新二", kind: .added)
        ])
    }

    func testKeepsLaterReplacementAfterSeveralLeadingRemovals() {
        XCTAssertEqual(
            ChatArtifactTextDiff.lines(
                previous: "删除一\n删除二\n保留行\n旧值",
                current: "保留行\n新值"
            ),
            [
                .init(text: "− 删除一", kind: .removed),
                .init(text: "− 删除二", kind: .removed),
                .init(text: "− 旧值", kind: .removed),
                .init(text: "+ 新值", kind: .added)
            ]
        )
    }

    func testCapsEachSideAndDoesNotEmitAnEmptyRemovedLine() {
        XCTAssertEqual(
            ChatArtifactTextDiff.lines(previous: "", current: "新增", limit: 1),
            [.init(text: "+ 新增", kind: .added)]
        )
        XCTAssertEqual(
            ChatArtifactTextDiff.lines(previous: "\r", current: "新增"),
            [.init(text: "+ 新增", kind: .added)]
        )

        XCTAssertEqual(
            ChatArtifactTextDiff.lines(
                previous: "旧一\n旧二",
                current: "新一\n新二\n新三",
                limit: 1
            ),
            [
                .init(text: "− 旧一", kind: .removed),
                .init(text: "+ 新一", kind: .added),
                .init(text: "…另有 3 行差异", kind: .unchanged)
            ]
        )
    }
}
