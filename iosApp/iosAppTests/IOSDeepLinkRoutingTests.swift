import XCTest
@testable import iosApp

final class IOSDeepLinkRoutingTests: XCTestCase {
    func testCloudTaskDeepLinkRoundTripAndValidation() throws {
        let workItemId = "work:0123456789abcdef0123456789abcdef"
        let url = try XCTUnwrap(URL(string: "amber://cloud-task/\(workItemId)"))
        XCTAssertEqual(IOSAppDeepLink.parse(url), .cloudTask(workItemId: workItemId))
        XCTAssertEqual(
            IOSAppDeepLink.url(for: .cloudTask(workItemId: workItemId)),
            url
        )

        // Reject unsafe segments, query injection, and wrong schemes.
        XCTAssertNil(IOSAppDeepLink.parse(URL(string: "amber://cloud-task/a/b")!))
        XCTAssertNil(IOSAppDeepLink.parse(URL(string: "amber://cloud-task/work:123?prompt=evil")!))
        XCTAssertNil(IOSAppDeepLink.parse(URL(string: "https://cloud-task/work:123")!))
        XCTAssertNil(IOSAppDeepLink.parse(URL(string: "amber://cloud-task/")!))
    }

    @MainActor
    func testMacGatewayStoreBackfillsCloudTaskDetailByWorkItemId() async {
        let suite = "b3-ios-deeplink-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MacGatewayStore(defaults: defaults)
        let workItemId = "work:sched-backfill-001"
        let detail = MacGatewayCloudWorkDetail(
            workItem: MacGatewayCloudWorkItem(
                id: workItemId,
                agentId: "main",
                title: "晨间健康巡检",
                state: .completed,
                progress: "done",
                updatedAtMs: 1_700_000_050_000
            ),
            brief: "每日摘要定时任务",
            failure: nil,
            sessionArchived: true,
            resultMarkdown: "## 总结\n全部正常"
        )

        let record = store.upsertBackfilledCloudTask(detail)
        XCTAssertEqual(record.workItemId, workItemId)
        XCTAssertEqual(record.displayTitle, "晨间健康巡检")
        XCTAssertEqual(record.briefText, "每日摘要定时任务")
        XCTAssertEqual(record.detail?.resultMarkdown, "## 总结\n全部正常")
        XCTAssertEqual(store.cloudTasks.first(where: { $0.workItemId == workItemId })?.state, .completed)

        await store.openCloudTaskFromDeepLink(workItemId: workItemId)
        XCTAssertEqual(store.pendingCloudTaskWorkItemId, workItemId)
    }
}
