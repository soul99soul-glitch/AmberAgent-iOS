import XCTest
@testable import AmberDeepRead

final class DeepReadDesignTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    func testNewsroomStageFollowsRuntimeProgressLabels() {
        XCTAssertEqual(DeepReadNewsroomStage.from(label: nil), .interview)
        XCTAssertEqual(DeepReadNewsroomStage.from(label: "正在搜索补充来源"), .interview)
        XCTAssertEqual(DeepReadNewsroomStage.from(label: "正在抓取网页正文 3/8"), .collate)
        XCTAssertEqual(DeepReadNewsroomStage.from(label: "正在生成深度阅读"), .write)
        XCTAssertEqual(DeepReadNewsroomStage.from(label: "正在生成背景"), .write)
        // The last chapter's callback arrives after it is written: the draft is ready for press.
        XCTAssertEqual(DeepReadNewsroomStage.from(label: "正在生成扩展阅读"), .press)
    }

    func testNightReadingWindow() {
        XCTAssertTrue(DeepReadMoment.isNight(date(2026, 10, 3, hour: 23), calendar: calendar))
        XCTAssertTrue(DeepReadMoment.isNight(date(2026, 10, 3, hour: 4), calendar: calendar))
        XCTAssertFalse(DeepReadMoment.isNight(date(2026, 10, 3, hour: 5), calendar: calendar))
        XCTAssertFalse(DeepReadMoment.isNight(date(2026, 10, 3, hour: 21), calendar: calendar))
    }

    func testFestivalsUseSolarAndLunarCalendars() {
        XCTAssertEqual(DeepReadMoment.festival(on: date(2026, 10, 3), calendar: calendar)?.name, "国庆 · 慢慢读")
        XCTAssertEqual(DeepReadMoment.festival(on: date(2026, 4, 23), calendar: calendar)?.name, "世界读书日")
        // 2026 Spring Festival is Feb 17; Mid-Autumn is Sep 25.
        XCTAssertEqual(DeepReadMoment.festival(on: date(2026, 2, 17), calendar: calendar)?.name, "新春 · 开卷有益")
        XCTAssertEqual(DeepReadMoment.festival(on: date(2026, 9, 25), calendar: calendar)?.name, "中秋 · 月下读")
        XCTAssertNil(DeepReadMoment.festival(on: date(2026, 10, 9), calendar: calendar))
    }

    func testMilestonesOnlyAtFirstTenthHundredth() {
        XCTAssertEqual(DeepReadMoment.milestone(completedCount: 1), "首篇")
        XCTAssertEqual(DeepReadMoment.milestone(completedCount: 10), "十篇")
        XCTAssertEqual(DeepReadMoment.milestone(completedCount: 100), "百篇")
        XCTAssertNil(DeepReadMoment.milestone(completedCount: 2))
    }

    func testPressSealSkipsErrorsAndOnlyCountsFirstDrafts() {
        // Cancel/failure of a retry restores the old article as succeeded; that is not a fresh print.
        XCTAssertNil(DeepReadMoment.pressSeal(finishedWithError: true, wasFirstDraft: false, completedCount: 3))
        XCTAssertEqual(DeepReadMoment.pressSeal(finishedWithError: false, wasFirstDraft: true, completedCount: 10)?.inscription, "十篇")
        // A failed first attempt retried to success is still the first draft.
        XCTAssertEqual(DeepReadMoment.pressSeal(finishedWithError: false, wasFirstDraft: true, completedCount: 1)?.inscription, "首篇")
        // Completing missing chapters of an existing article never claims a milestone.
        XCTAssertEqual(DeepReadMoment.pressSeal(finishedWithError: false, wasFirstDraft: false, completedCount: 10)?.inscription, "付印")
    }

    func testSolarFestivalsIgnoreNonGregorianUserCalendar() {
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = calendar.timeZone
        XCTAssertEqual(DeepReadMoment.festival(on: date(2026, 4, 23), calendar: hebrew)?.name, "世界读书日")
    }
}
