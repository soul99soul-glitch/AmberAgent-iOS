import XCTest
@testable import iosApp

final class NovelInkSealStampTests: XCTestCase {
    private let newChapter = NovelCollectionTarget.createNextChapter(chapterID: NovelChapterID(), title: "第 3 章")
    private let append = NovelCollectionTarget.appendToChapter(NovelChapterID())

    func testNewChapterGetsChapterSeal() {
        let stamp = NovelInkSealStamp.after(collecting: newChapter, previousTotal: 4_000, newTotal: 7_000, nextChapterOrdinal: 3)
        XCTAssertEqual(stamp, NovelInkSealStamp(glyphs: "成章", caption: "第 3 章已收入正文"))
    }

    func testRevisionWithoutMilestoneStampsNothing() {
        XCTAssertNil(NovelInkSealStamp.after(collecting: append, previousTotal: 4_000, newTotal: 7_000, nextChapterOrdinal: 3))
    }

    func testCrossingMilestoneOverridesChapterSeal() {
        let stamp = NovelInkSealStamp.after(collecting: newChapter, previousTotal: 9_500, newTotal: 12_000, nextChapterOrdinal: 3)
        XCTAssertEqual(stamp?.glyphs, "万字")
        XCTAssertEqual(stamp?.caption, "全书突破 1 万字")
    }

    func testFiftyThousandIsTheWritingMonthFinishLine() {
        let stamp = NovelInkSealStamp.after(collecting: append, previousTotal: 49_000, newTotal: 50_000, nextChapterOrdinal: 9)
        XCTAssertEqual(stamp?.glyphs, "五万")
        XCTAssertEqual(stamp?.caption, "全书突破 5 万字，写作月的终点线")
    }

    func testJumpingSeveralMilestonesShowsTheHighest() {
        let stamp = NovelInkSealStamp.after(collecting: append, previousTotal: 0, newTotal: 120_000, nextChapterOrdinal: 1)
        XCTAssertEqual(stamp?.glyphs, "十万")
    }

    func testStayingAboveAMilestoneDoesNotRepeatIt() {
        XCTAssertNil(NovelInkSealStamp.after(collecting: append, previousTotal: 10_000, newTotal: 11_000, nextChapterOrdinal: 3))
    }
}
