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

    @MainActor
    func testProactiveSignalDeepLinkRoutesToCloudDialogueRootSetsPendingSignalAndSendsOpenedFeedback() async {
        let suite = "proactive-w2-i2-paired-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let gatewayStore = MacGatewayStore(defaults: defaults)
        let connection = MacGatewayConnection(
            gatewayId: "cloud-gw-1",
            name: "Amber Cloud",
            addrs: ["127.0.0.1"],
            port: 8443,
            fingerprint: "fp-test",
            deviceId: "ios-dev-1",
            role: .cloud
        )
        let client = MacGatewayClient(
            addrs: ["127.0.0.1"],
            port: 8443,
            fingerprint: "fp-test",
            token: "tok-test",
            transport: { request, _ in
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://127.0.0.1:8443")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data(#"{"ok":true,"action":"opened","applied":true}"#.utf8), response)
            }
        )
        gatewayStore.configureForTesting(role: .cloud, connection: connection, client: client)

        let proactiveStore = CloudProactiveStore(gatewayStore: gatewayStore)
        let router = RouterPath()
        router.path = [.settings, .macGateway]
        XCTAssertFalse(router.isShowingChat)
        XCTAssertFalse(gatewayStore.isCloudMainDialogueSelected)

        var openedSignalIds: [String] = []
        func openNotification() async {
            await AppShell.routeProactiveSignal(
                signalId: "wt_route_01",
                router: router,
                gatewayStore: gatewayStore,
                proactiveStore: proactiveStore,
                sendOpenedFeedback: { id in
                    openedSignalIds.append(id)
                    return await proactiveStore.sendFeedback(signalId: id, action: .opened)
                }
            )?.value
        }
        await openNotification()
        await openNotification()

        XCTAssertTrue(router.path.isEmpty)
        XCTAssertTrue(router.isShowingChat)
        XCTAssertTrue(gatewayStore.isCloudMainDialogueSelected)
        XCTAssertEqual(proactiveStore.pendingSignalId, "wt_route_01")
        XCTAssertEqual(openedSignalIds, ["wt_route_01"])
        // Routing must not inject synthetic events into cloudDialogueEvents.
        XCTAssertTrue(gatewayStore.cloudDialogueEvents.isEmpty)
        proactiveStore.pendingSignalId = nil
        await openNotification()
        XCTAssertEqual(openedSignalIds, ["wt_route_01", "wt_route_01"])
    }

    @MainActor
    func testApprovalBoardForUnpairedCloudKeepsTheUserOffThePairedMacBoard() throws {
        let suite = "approval-board-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacGatewayStore(defaults: defaults)
        let mac = MacGatewayConnection(gatewayId: "gateway", name: "Mac", addrs: ["localhost"], port: 443,
                                       fingerprint: "fp", deviceId: "device", role: .mac)
        store.configureForTesting(role: .mac, connection: mac, client: MacGatewayClient(
            addrs: mac.addrs, port: mac.port, fingerprint: mac.fingerprint, token: "token"
        ))
        let router = RouterPath()
        AppShell.openGatewayBoard(role: .mac, router: router, gatewayStore: store)
        XCTAssertEqual(router.path, [.gatewayTasks(.mac)])
        AppShell.openGatewayBoard(role: .cloud, router: router, gatewayStore: store)
        XCTAssertEqual(router.path, [.settings, .macGateway])
        XCTAssertEqual(store.preferredMultiDeviceTab, .cloud)
        XCTAssertTrue(store.notice?.isError == true)
    }

    @MainActor
    func testProactiveSignalWithoutPairingShowsCloudPairingAndSkipsOpenedFeedback() async {
        let suite = "proactive-w2-i2-unpaired-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let gatewayStore = MacGatewayStore(defaults: defaults)
        let proactiveStore = CloudProactiveStore(gatewayStore: gatewayStore)
        let router = RouterPath()
        router.path = [.settings]

        let feedbackTask = AppShell.routeProactiveSignal(
            signalId: "wk_unpaired_02",
            router: router,
            gatewayStore: gatewayStore,
            proactiveStore: proactiveStore,
            sendOpenedFeedback: { _ in
                XCTFail("An unpaired signal must not be marked opened")
                return false
            }
        )
        await feedbackTask?.value

        XCTAssertEqual(router.path, [.settings, .macGateway])
        XCTAssertTrue(gatewayStore.notice?.isError == true)
        XCTAssertEqual(gatewayStore.preferredMultiDeviceTab, .cloud)
        XCTAssertFalse(gatewayStore.isCloudMainDialogueSelected)
        XCTAssertNil(proactiveStore.pendingSignalId)
    }
}
