import XCTest
@testable import iosApp

/// EventKit 工具的审批分类与参数入口。需要系统日历权限的调用留给真机/模拟器手工验证；
/// 这里覆盖不需要权限的前置分支，避免分类或 JSON 入口被无意改坏。
@MainActor
final class IOSEventKitToolWiringTests: XCTestCase {

    func testEveryEventKitToolRequiresApproval() {
        XCTAssertEqual(
            IOSAppleAgentToolCatalog.approvalRequiredToolNames.intersection(IOSAppleAgentToolCatalog.eventKitToolNames),
            IOSAppleAgentToolCatalog.eventKitToolNames
        )
    }

    func testOnlyMutatingEventKitToolsAreClassifiedAsMutating() {
        let mutating = IOSAppleAgentToolCatalog.mutatingToolNames
        XCTAssertFalse(mutating.contains(IOSAppleAgentToolCatalog.calendarEventsList))
        XCTAssertFalse(mutating.contains(IOSAppleAgentToolCatalog.remindersList))
        for name in [
            IOSAppleAgentToolCatalog.calendarEventCreate,
            IOSAppleAgentToolCatalog.calendarEventUpdate,
            IOSAppleAgentToolCatalog.calendarEventDelete,
            IOSAppleAgentToolCatalog.reminderCreate,
            IOSAppleAgentToolCatalog.reminderUpdate,
            IOSAppleAgentToolCatalog.reminderDelete,
            IOSAppleAgentToolCatalog.reminderComplete
        ] {
            XCTAssertTrue(mutating.contains(name), "\(name) 会修改用户数据")
        }
    }

    func testNonObjectJSONFailsBeforeEventKitIsOpened() async throws {
        for input in ["not json", "[]", "\"text\""] {
            let output = await IOSEventKitAgentToolExecutor.execute(
                toolName: IOSAppleAgentToolCatalog.calendarEventsList,
                input: input
            )
            let payload = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            )
            XCTAssertEqual(payload["ok"] as? Bool, false)
            XCTAssertEqual(payload["tool"] as? String, IOSAppleAgentToolCatalog.calendarEventsList)
            XCTAssertEqual(payload["reason"] as? String, "参数不是有效的 JSON 对象。")
        }
    }

    func testUnknownToolDoesNotOpenEventKit() async throws {
        let output = await IOSEventKitAgentToolExecutor.execute(toolName: "calendar_events_archive", input: "{}")
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["tool"] as? String, "calendar_events_archive")
        XCTAssertEqual(payload["reason"] as? String, "未知 Apple 工具。")
    }

    func testConflictDetectionReportsOnlyTimedOverlapsExcludingSelf() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ id: String, _ startHour: Double, _ endHour: Double, allDay: Bool = false) -> IOSCalendarConflictCandidate {
            IOSCalendarConflictCandidate(
                id: id,
                title: id,
                start: base.addingTimeInterval(startHour * 3_600),
                end: base.addingTimeInterval(endHour * 3_600),
                allDay: allDay
            )
        }
        let candidates = [
            item("late-overlap", 1.5, 3),
            item("self", 1, 2),
            item("all-day", 0, 24, allDay: true),
            item("touching-before", 0, 1),
            item("touching-after", 2, 3),
            item("early-overlap", 0.5, 1.25)
        ]
        let conflicts = IOSCalendarConflictCandidate.overlapping(
            candidates,
            start: base.addingTimeInterval(3_600),
            end: base.addingTimeInterval(7_200),
            excluding: "self"
        )
        XCTAssertEqual(conflicts.map(\.id), ["early-overlap", "late-overlap"])

        let many = (0..<8).map { item("m\($0)", 1, 2) }
        XCTAssertEqual(
            IOSCalendarConflictCandidate.overlapping(many, start: base.addingTimeInterval(3_600), end: base.addingTimeInterval(7_200), excluding: nil).count,
            IOSCalendarConflictCandidate.maxReported
        )

        let withCanceledAndFree = [
            IOSCalendarConflictCandidate(
                id: "canceled",
                title: "Canceled",
                start: base.addingTimeInterval(3_600),
                end: base.addingTimeInterval(7_200),
                allDay: false,
                isCanceled: true
            ),
            IOSCalendarConflictCandidate(
                id: "free",
                title: "Free",
                start: base.addingTimeInterval(3_600),
                end: base.addingTimeInterval(7_200),
                allDay: false,
                isFreeAvailability: true
            ),
            IOSCalendarConflictCandidate(
                id: "busy",
                title: "Busy",
                start: base.addingTimeInterval(3_600),
                end: base.addingTimeInterval(7_200),
                allDay: false
            ),
        ]
        XCTAssertEqual(
            IOSCalendarConflictCandidate.overlapping(
                withCanceledAndFree,
                start: base.addingTimeInterval(3_600),
                end: base.addingTimeInterval(7_200),
                excluding: nil
            ).map(\.id),
            ["busy"]
        )
        XCTAssertTrue(
            IOSCalendarConflictCandidate.overlapping(
                withCanceledAndFree,
                start: base,
                end: base.addingTimeInterval(IOSCalendarConflictCandidate.maxConflictSpan + 3_600),
                excluding: nil
            ).isEmpty,
            "超过最大冲突跨度窗口时应跳过冲突扫描"
        )
    }
}
