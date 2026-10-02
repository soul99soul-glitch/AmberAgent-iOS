import XCTest
@testable import iosApp

final class NovelDesignLogicTests: XCTestCase {
    private func date(_ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func testLaunchMoodFollowsDateAndHour() {
        XCTAssertEqual(NovelLaunchMood.current(at: date(3, 14, 10), calendar: calendar), .standard)
        XCTAssertEqual(NovelLaunchMood.current(at: date(3, 14, 2), calendar: calendar), .lateNight)
        XCTAssertEqual(NovelLaunchMood.current(at: date(3, 14, 5), calendar: calendar), .standard)
        XCTAssertEqual(NovelLaunchMood.current(at: date(11, 20, 15), calendar: calendar), .novelWritingMonth)
        // New Year wins over the late-night hour.
        XCTAssertEqual(NovelLaunchMood.current(at: date(1, 1, 0), calendar: calendar), .newYear)
        // Late night wins inside November.
        XCTAssertEqual(NovelLaunchMood.current(at: date(11, 3, 1), calendar: calendar), .lateNight)
    }

    func testEveryMoodHasATagline() {
        for mood in [NovelLaunchMood.standard, .lateNight, .novelWritingMonth, .newYear] {
            XCTAssertFalse(mood.tagline.isEmpty)
        }
    }

    func testInkQuotesCycleWithoutGoingOutOfRange() {
        let count = NovelInkQuotes.all.count
        XCTAssertEqual(NovelInkQuotes.quote(forDiscovery: 0), NovelInkQuotes.all[0])
        XCTAssertEqual(NovelInkQuotes.quote(forDiscovery: count), NovelInkQuotes.all[0])
        XCTAssertEqual(NovelInkQuotes.quote(forDiscovery: count + 2), NovelInkQuotes.all[2])
    }
}
