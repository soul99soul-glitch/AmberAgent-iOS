import XCTest
@testable import AmberMac

final class DesktopScheduleTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func date(_ text: String, _ zone: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private let shanghai = "Asia/Shanghai"
    private let newYork = "America/New_York"

    // MARK: five rules

    func testOnceFiresOnlyBeforeItsTime() {
        let at = date("2026-11-02 09:00", shanghai)
        let rule = DesktopSchedule.once(at)
        XCTAssertEqual(rule.nextFire(after: date("2026-11-01 12:00", shanghai), calendar: calendar(shanghai)), at)
        XCTAssertNil(rule.nextFire(after: at, calendar: calendar(shanghai)))
    }

    func testDailyRollsToTomorrowAfterTheSlot() {
        let cal = calendar(shanghai)
        let rule = DesktopSchedule.daily(hour: 9, minute: 0)
        XCTAssertEqual(rule.nextFire(after: date("2026-10-27 08:59", shanghai), calendar: cal), date("2026-10-27 09:00", shanghai))
        XCTAssertEqual(rule.nextFire(after: date("2026-10-27 09:00", shanghai), calendar: cal), date("2026-10-28 09:00", shanghai))
    }

    func testWeekdaysSkipsTheWeekend() {
        let cal = calendar(shanghai)
        let rule = DesktopSchedule.weekdays(hour: 9, minute: 30)
        // 2026-10-30 is a Friday.
        XCTAssertEqual(rule.nextFire(after: date("2026-10-30 10:00", shanghai), calendar: cal), date("2026-11-02 09:30", shanghai))
        XCTAssertEqual(rule.nextFire(after: date("2026-10-27 07:00", shanghai), calendar: cal), date("2026-10-27 09:30", shanghai))
    }

    func testWeeklyPicksTheNearestListedDay() {
        let cal = calendar(shanghai)
        // Sunday (1) and Wednesday (4).
        let rule = DesktopSchedule.weekly(days: [1, 4], hour: 20, minute: 0)
        // Tuesday 2026-10-27 → Wednesday 10-28.
        XCTAssertEqual(rule.nextFire(after: date("2026-10-27 21:00", shanghai), calendar: cal), date("2026-10-28 20:00", shanghai))
        // Wednesday after the slot → Sunday 11-01.
        XCTAssertEqual(rule.nextFire(after: date("2026-10-28 20:00", shanghai), calendar: cal), date("2026-11-01 20:00", shanghai))
    }

    func testIntervalCountsFromAnchor() {
        let anchor = date("2026-10-27 09:00", shanghai)
        let rule = DesktopSchedule.interval(minutes: 15, anchor: anchor)
        let cal = calendar(shanghai)
        XCTAssertEqual(rule.nextFire(after: date("2026-10-27 08:00", shanghai), calendar: cal), anchor)
        XCTAssertEqual(rule.nextFire(after: anchor, calendar: cal), date("2026-10-27 09:15", shanghai))
        XCTAssertEqual(rule.nextFire(after: date("2026-10-27 09:31", shanghai), calendar: cal), date("2026-10-27 09:45", shanghai))
    }

    func testValidationRejectsBadRules() {
        XCTAssertNotNil(DesktopSchedule.interval(minutes: 5, anchor: Date()).validationError)
        XCTAssertNotNil(DesktopSchedule.weekly(days: [], hour: 9, minute: 0).validationError)
        XCTAssertNotNil(DesktopSchedule.weekly(days: [8], hour: 9, minute: 0).validationError)
        XCTAssertNotNil(DesktopSchedule.daily(hour: 24, minute: 0).validationError)
        XCTAssertNil(DesktopSchedule.daily(hour: 23, minute: 59).validationError)
        XCTAssertNil(DesktopSchedule.daily(hour: 24, minute: 0).nextFire(after: Date(), calendar: calendar(shanghai)))
        var task = DesktopScheduledTask(name: " ", prompt: "x", schedule: .daily(hour: 9, minute: 0))
        XCTAssertNotNil(task.validationError)
        task.name = "汇总"
        XCTAssertNil(task.validationError)
    }

    // MARK: DST

    func testDailyKeepsLocalTimeAcrossSpringForward() {
        let cal = calendar(newYork)
        // US DST starts 2026-03-08 02:00.
        let rule = DesktopSchedule.daily(hour: 9, minute: 0)
        let before = rule.nextFire(after: date("2026-03-07 09:00", newYork), calendar: cal)!
        XCTAssertEqual(before, date("2026-03-08 09:00", newYork))
        XCTAssertEqual(before.timeIntervalSince(date("2026-03-07 09:00", newYork)), 23 * 3600)
    }

    func testNonexistentTimeOnSpringForwardFiresOnceThatDay() {
        let cal = calendar(newYork)
        let rule = DesktopSchedule.daily(hour: 2, minute: 30)
        let fire = rule.nextFire(after: date("2026-03-07 03:00", newYork), calendar: cal)!
        XCTAssertEqual(cal.component(.day, from: fire), 8)
        XCTAssertEqual(cal.component(.hour, from: fire), 3)
        let next = rule.nextFire(after: fire, calendar: cal)!
        XCTAssertEqual(next, date("2026-03-09 02:30", newYork))
    }

    func testRepeatedTimeOnFallBackFiresOnce() {
        let cal = calendar(newYork)
        // US DST ends 2026-11-01 02:00 → 01:00; 01:30 happens twice.
        let rule = DesktopSchedule.daily(hour: 1, minute: 30)
        let first = rule.nextFire(after: date("2026-10-31 23:00", newYork), calendar: cal)!
        XCTAssertEqual(cal.component(.day, from: first), 1)
        let second = rule.nextFire(after: first, calendar: cal)!
        XCTAssertEqual(cal.component(.day, from: second), 2)
        XCTAssertEqual(cal.component(.hour, from: second), 1)
        XCTAssertEqual(cal.component(.minute, from: second), 30)
    }

    func testIntervalIsAbsoluteAcrossDST() {
        let anchor = date("2026-11-01 00:00", newYork)
        let rule = DesktopSchedule.interval(minutes: 60, anchor: anchor)
        let next = rule.nextFire(after: anchor.addingTimeInterval(3 * 3600 - 1), calendar: calendar(newYork))!
        XCTAssertEqual(next.timeIntervalSince(anchor), 3 * 3600)
    }

    // MARK: time-zone change

    func testTimeZoneChangeMovesWallClockRules() {
        var task = DesktopScheduledTask(name: "汇总", prompt: "x", schedule: .daily(hour: 9, minute: 0))
        let now = date("2026-10-27 06:00", shanghai)
        task.nextRunAt = DesktopSchedulePlanner.initialNextRun(task, now: now, calendar: calendar(shanghai))
        XCTAssertEqual(task.nextRunAt, date("2026-10-27 09:00", shanghai))
        // Flew to New York: 06:00 Shanghai is 18:00 the previous day in New York.
        let moved = DesktopSchedulePlanner.recompute(task, now: now, calendar: calendar(newYork))
        XCTAssertEqual(moved, date("2026-10-27 09:00", newYork))
    }

    func testTimeZoneChangeKeepsAlreadyDueSlotAndAbsoluteRules() {
        let now = date("2026-10-27 10:00", shanghai)
        var due = DesktopScheduledTask(name: "a", prompt: "x", schedule: .daily(hour: 9, minute: 0))
        due.nextRunAt = date("2026-10-27 09:00", shanghai)
        XCTAssertEqual(DesktopSchedulePlanner.recompute(due, now: now, calendar: calendar(newYork)), due.nextRunAt)
        let at = date("2026-10-28 09:00", shanghai)
        var once = DesktopScheduledTask(name: "b", prompt: "x", schedule: .once(at))
        once.nextRunAt = at
        XCTAssertEqual(DesktopSchedulePlanner.recompute(once, now: now, calendar: calendar(newYork)), at)
        var disabled = once
        disabled.enabled = false
        XCTAssertNil(DesktopSchedulePlanner.recompute(disabled, now: now, calendar: calendar(newYork)))
    }

    // MARK: missed runs

    func testManyMissedSlotsProduceOneRun() {
        let cal = calendar(shanghai)
        var task = DesktopScheduledTask(name: "a", prompt: "x", schedule: .interval(minutes: 15, anchor: date("2026-10-27 09:00", shanghai)))
        task.nextRunAt = date("2026-10-27 09:15", shanghai)
        // Asleep for three hours: twelve slots missed.
        let wake = date("2026-10-27 12:07", shanghai)
        guard case .run(let scheduledFor, let next) = DesktopSchedulePlanner.decide(task, now: wake, calendar: cal) else {
            return XCTFail("expected a catch-up run")
        }
        XCTAssertEqual(scheduledFor, date("2026-10-27 09:15", shanghai))
        XCTAssertEqual(next, date("2026-10-27 12:15", shanghai))
        task.nextRunAt = next
        XCTAssertEqual(DesktopSchedulePlanner.decide(task, now: wake, calendar: cal), .wait(next))
    }

    func testSkipPolicyDropsMissedSlotButRunsOnTimeOnes() {
        let cal = calendar(shanghai)
        var task = DesktopScheduledTask(name: "a", prompt: "x", schedule: .daily(hour: 9, minute: 0))
        task.missedRun = .skip
        task.nextRunAt = date("2026-10-27 09:00", shanghai)
        XCTAssertEqual(DesktopSchedulePlanner.decide(task, now: date("2026-10-27 09:01", shanghai), calendar: cal),
            .run(scheduledFor: date("2026-10-27 09:00", shanghai), nextRunAt: date("2026-10-28 09:00", shanghai)))
        XCTAssertEqual(DesktopSchedulePlanner.decide(task, now: date("2026-10-29 08:00", shanghai), calendar: cal),
            .skip(missed: date("2026-10-27 09:00", shanghai), nextRunAt: date("2026-10-29 09:00", shanghai)))
    }

    func testMissedOnceRunsOnceThenStops() {
        let cal = calendar(shanghai)
        let at = date("2026-10-27 09:00", shanghai)
        var task = DesktopScheduledTask(name: "a", prompt: "x", schedule: .once(at))
        task.nextRunAt = at
        XCTAssertEqual(DesktopSchedulePlanner.decide(task, now: date("2026-10-28 09:00", shanghai), calendar: cal),
            .run(scheduledFor: at, nextRunAt: nil))
        task.nextRunAt = nil
        XCTAssertEqual(DesktopSchedulePlanner.decide(task, now: date("2026-10-28 09:00", shanghai), calendar: cal), .wait(nil))
    }

    func testDisabledTaskNeverRuns() {
        var task = DesktopScheduledTask(name: "a", prompt: "x", schedule: .daily(hour: 9, minute: 0))
        task.nextRunAt = Date.distantPast
        task.enabled = false
        XCTAssertEqual(DesktopSchedulePlanner.decide(task, now: Date(), calendar: calendar(shanghai)), .wait(nil))
        XCTAssertNil(DesktopSchedulePlanner.initialNextRun(task, now: Date(), calendar: calendar(shanghai)))
    }

    // MARK: store

    func testStoreRoundTripsAndKeepsUnreadableFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amber-schedule-tests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = DesktopScheduleStore(directory: directory)
        var task = DesktopScheduledTask(name: "每日汇总", prompt: "汇总新文件", schedule: .weekly(days: [2, 4], hour: 9, minute: 0))
        task.approval.allowedTools = ["workspace_list"]
        task.output = .appendTo(UUID())
        task.lastRun = DesktopScheduleRunRecord(startedAt: Date(timeIntervalSince1970: 100), status: .completed)
        try await store.save(task)
        let broken = directory.appendingPathComponent("broken.json")
        try Data("{".utf8).write(to: broken)

        let reopened = try await DesktopScheduleStore(directory: directory).load()
        XCTAssertEqual(reopened.tasks, [task])
        XCTAssertEqual(reopened.unreadable, ["broken.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
        let text = try String(contentsOf: directory.appendingPathComponent(task.id.uuidString + ".json"), encoding: .utf8)
        XCTAssertTrue(text.contains("amber.schedule.v1"))

        try await store.delete(task.id)
        let after = try await DesktopScheduleStore(directory: directory).load()
        XCTAssertTrue(after.tasks.isEmpty)
    }

    func testUnattendedApprovalMapsToPolicyAndDefaultsOff() {
        var approval = DesktopUnattendedApproval()
        XCTAssertFalse(approval.policy.autoApproves("workspace_list"))
        approval.autoApproveOrdinary = true
        approval.allowedTools = ["workspace_list"]
        XCTAssertTrue(approval.policy.autoApproves("workspace_list"))
        XCTAssertFalse(approval.policy.autoApproves("workspace_write"))
    }
}
