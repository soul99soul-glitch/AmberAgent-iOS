import XCTest
@testable import AmberMac

@MainActor final class DesktopNotificationTests: XCTestCase {
    private final class Delivery: DesktopNotificationDelivery {
        var grant = true
        var authorized = true
        var failDelivery = false
        var requests = 0
        var checks = 0
        var sent: [(identifier: String, title: String, body: String, userInfo: [String: String])] = []
        func requestAuthorization() async throws -> Bool { requests += 1; return grant }
        func isAuthorized() async -> Bool { checks += 1; await Task.yield(); return authorized }
        func send(identifier: String, title: String, body: String, userInfo: [String: String]) async throws {
            if failDelivery { throw DesktopRuntimeError.message("system failure raw") }
            sent.append((identifier, title, body, userInfo))
        }
    }
    private func settings(_ defaults: UserDefaults? = nil) -> DesktopSettings {
        DesktopSettings(defaults: defaults ?? UserDefaults(suiteName: "amber.notifications.tests.\(UUID())")!, credentials: DesktopMemoryCredentials())
    }

    func testDefaultOffDoesNotRequestAuthorizationOrDeliver() async {
        let settings = settings(), delivery = Delivery()
        let service = DesktopNotifications(settings: settings, delivery: delivery)
        XCTAssertFalse(settings.notificationsEnabled)
        let sent = await service.notify(runID: UUID(), conversationID: UUID(), outcome: .completed)
        XCTAssertFalse(sent)
        XCTAssertEqual(delivery.requests, 0)
        XCTAssertEqual(delivery.checks, 0)
        XCTAssertTrue(delivery.sent.isEmpty)
    }

    func testExplicitEnableRequestsAuthorizationAndPreferenceRestores() async {
        let defaults = UserDefaults(suiteName: "amber.notifications.tests.\(UUID())")!
        let settings = settings(defaults), delivery = Delivery()
        let service = DesktopNotifications(settings: settings, delivery: delivery)
        await service.setEnabled(true)
        XCTAssertEqual(delivery.requests, 1)
        XCTAssertTrue(settings.notificationsEnabled)
        XCTAssertTrue(self.settings(defaults).notificationsEnabled)
        await service.setEnabled(false)
        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertEqual(delivery.requests, 1)
    }

    func testDeniedPermissionLeavesPreferenceOffAndShowsState() async {
        let settings = settings(), delivery = Delivery()
        delivery.grant = false
        let service = DesktopNotifications(settings: settings, delivery: delivery)
        await service.setEnabled(true)
        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertNotNil(service.authorizationMessage)
        XCTAssertFalse(service.isRequestingAuthorization)
    }

    func testConcurrentDuplicateRunOnlyNotifiesOriginalOwnerOnce() async {
        let settings = settings(), delivery = Delivery()
        settings.notificationsEnabled = true
        let service = DesktopNotifications(settings: settings, delivery: delivery)
        let runID = UUID(), owner = UUID()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask { _ = await service.notify(runID: runID, conversationID: owner, outcome: .completed) }
            }
        }
        XCTAssertEqual(delivery.sent.count, 1)
        XCTAssertEqual(delivery.sent.first?.identifier, "amber.run." + runID.uuidString.lowercased())
        XCTAssertEqual(delivery.sent.first?.userInfo["conversationID"], owner.uuidString.lowercased())
        XCTAssertEqual(delivery.sent.first?.userInfo["runID"], runID.uuidString.lowercased())
        XCTAssertEqual(delivery.requests, 0)
    }

    func testDeliveryFailureKeepsTaskOutputOutOfNotificationAndDoesNotChangePreference() async {
        let settings = settings(), delivery = Delivery()
        settings.notificationsEnabled = true; delivery.failDelivery = true
        let service = DesktopNotifications(settings: settings, delivery: delivery)
        let sent = await service.notify(runID: UUID(), conversationID: UUID(), outcome: .failed)
        XCTAssertFalse(sent)
        XCTAssertTrue(settings.notificationsEnabled)
        XCTAssertFalse(service.lastDeliveryError?.contains("raw") ?? true)
        XCTAssertEqual(delivery.requests, 0)
    }

    func testRevokedSystemAuthorizationNeverPromptsOnTaskCompletion() async {
        let settings = settings(), delivery = Delivery()
        settings.notificationsEnabled = true; delivery.authorized = false
        let service = DesktopNotifications(settings: settings, delivery: delivery)
        let sent = await service.notify(runID: UUID(), conversationID: UUID(), outcome: .completed)
        XCTAssertFalse(sent)
        XCTAssertTrue(delivery.sent.isEmpty)
        XCTAssertEqual(delivery.requests, 0)
        XCTAssertNotNil(service.authorizationMessage)
    }
}
