import Darwin
import XCTest
@testable import iosApp

@MainActor
final class IOSWatchActivityRecoveryPerformanceTests: XCTestCase {
    func testColdRecoveryScalingWithPersistedRecentWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var report: [String] = []
        var previousWallMilliseconds: Double?

        for count in [250, 500, 1_000, 2_000] {
            let root = fixture.root.appendingPathComponent("history-\(count)")
            let history = (0..<count).map { index in
                activity(
                    runID: String(format: "00000000-0000-4000-8000-%012d", index),
                    at: TimeInterval(index)
                )
            }
            let expected = Array(history.suffix(IOSWatchCompanionService.maxRecentActivities).reversed())
            let seed = IOSWatchCompanionService(baseDirectory: root, defaults: fixture.defaults)
            XCTAssertTrue(seed.restoreTerminalActivities(expected))
            let service = IOSWatchCompanionService(baseDirectory: root, defaults: fixture.defaults)
            XCTAssertEqual(service.recentActivities, expected)

            // Time only the production merge and its normal persistence. Data
            // creation, existing-window reload, and assertions stay outside.
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let restored = service.restoreTerminalActivities(history)
            let cpuNanoseconds = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart
            let wallNanoseconds = DispatchTime.now().uptimeNanoseconds - wallStart
            let wallMilliseconds = Double(wallNanoseconds) / 1_000_000
            let cpuMilliseconds = Double(cpuNanoseconds) / 1_000_000
            let ratio = previousWallMilliseconds.map { wallMilliseconds / $0 } ?? 0
            previousWallMilliseconds = wallMilliseconds

            XCTAssertTrue(restored)
            XCTAssertEqual(service.recentActivities, expected)
            XCTAssertEqual(service.recentActivities.count, 20)
            let reloaded = IOSWatchCompanionService(baseDirectory: root, defaults: fixture.defaults)
            XCTAssertEqual(reloaded.recentActivities, expected)

            let line = String(
                format: "WATCH_ACTIVITY_RECOVERY history=%d retained=%d wall_ms=%.3f main_cpu_ms=%.3f ratio_to_half=%.3f",
                count, service.recentActivities.count, wallMilliseconds, cpuMilliseconds, ratio
            )
            print(line)
            report.append(line)
        }

        // Keep raw measurements rather than a wall-time pass/fail threshold:
        // rerunning this unchanged test on the patch gives a comparable curve.
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "Watch activity cold recovery scaling"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLargeRecoveryPreservesTerminalOwnershipAndRecentWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let service = IOSWatchCompanionService(baseDirectory: fixture.root, defaults: fixture.defaults)
        let pendingSave = activity(runID: "saved", phase: "failed", at: 10_001)
        let cancelled = activity(runID: "cancelled", phase: "cancelled", at: 10_002)
        let alreadyCompleted = activity(runID: "completed", at: 10_003)
        XCTAssertTrue(service.restoreTerminalActivities([pendingSave, cancelled, alreadyCompleted]))

        var history = (0..<1_000).map { activity(runID: "history-\($0)", at: TimeInterval($0)) }
        let recoveredCompletion = activity(runID: "SAVED", at: 11_001, summary: "结果已保存")
        let newestDuplicate = activity(runID: "duplicate", at: 12_004, summary: "最新终态")
        history += [
            recoveredCompletion,
            activity(runID: "saved", phase: "failed", at: 12_001),
            activity(runID: "cancelled", at: 12_002),
            activity(runID: "completed", phase: "failed", at: 12_003),
            newestDuplicate,
            activity(runID: "DUPLICATE", at: 11_004, summary: "旧终态"),
            activity(runID: "still-running", phase: "running", at: 20_000),
            activity(runID: "needs-confirmation", phase: "outcome_unknown", at: 20_001)
        ]

        XCTAssertTrue(service.restoreTerminalActivities(history))
        XCTAssertEqual(service.recentActivities.count, 20)
        let byRun = Dictionary(uniqueKeysWithValues: service.recentActivities.map {
            ($0.runId!.lowercased(), $0)
        })
        XCTAssertEqual(byRun["saved"], recoveredCompletion)
        XCTAssertEqual(byRun["cancelled"], cancelled)
        XCTAssertEqual(byRun["completed"], alreadyCompleted)
        XCTAssertEqual(byRun["duplicate"], newestDuplicate)
        XCTAssertNil(byRun["still-running"])
        XCTAssertNil(byRun["needs-confirmation"])
        let expectedHistoricalIDs = Set((984..<1_000).map { "history-\($0)" })
        XCTAssertEqual(Set(byRun.keys.filter { $0.hasPrefix("history-") }), expectedHistoricalIDs)
        XCTAssertEqual(service.recentActivities.map(\.updatedAt), service.recentActivities.map(\.updatedAt).sorted(by: >))
        let reloaded = IOSWatchCompanionService(baseDirectory: fixture.root, defaults: fixture.defaults)
        XCTAssertEqual(reloaded.recentActivities, service.recentActivities)
    }

    private func activity(
        runID: String,
        phase: String = "completed",
        at timestamp: TimeInterval,
        summary: String = "任务已结束"
    ) -> WatchRecentActivity {
        WatchRecentActivity(
            id: "run:\(runID)",
            runId: runID,
            conversationId: "conversation-\(runID)",
            kind: "response",
            phase: phase,
            title: "任务 \(runID)",
            summary: summary,
            updatedAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suiteName: String

        func remove() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeFixture() throws -> Fixture {
        let id = UUID().uuidString
        let suiteName = "IOSWatchActivityRecoveryPerformanceTests.\(id)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        return Fixture(root: root, defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName: suiteName)
    }
}
