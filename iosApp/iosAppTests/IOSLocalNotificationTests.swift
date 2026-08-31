import Foundation
import Testing
@testable import iosApp

@MainActor
private final class FakeLocalNotificationCenter: IOSLocalNotificationCenter {
    var status: IOSLocalNotificationAuthorization
    var requestResult = true
    var requests: [IOSLocalNotificationRequest] = []
    var removed: [[String]] = []
    var pendingIdentifiers: [String] = []

    init(status: IOSLocalNotificationAuthorization) { self.status = status }

    func authorization() async -> IOSLocalNotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool {
        if requestResult { status = .allowed }
        return requestResult
    }
    func add(_ request: IOSLocalNotificationRequest) async throws { requests.append(request) }
    func pendingRequestIdentifiers() async -> [String] { pendingIdentifiers }
    func removePendingRequests(identifiers: [String]) { removed.append(identifiers) }
}

@Suite("Local notifications")
@MainActor
struct IOSLocalNotificationTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func completionRequiresExistingAuthorization() async throws {
        let center = FakeLocalNotificationCenter(status: .denied)
        let service = IOSLocalNotificationService(
            center: center,
            now: { now },
            completionNotificationsEnabled: { true }
        )
        #expect(try await service.scheduleTaskCompletion(conversationID: "abc") == .notAuthorized)
        #expect(center.requests.isEmpty)
    }

    @Test func completionHasStableIdentifierAndConversationRoute() async throws {
        let center = FakeLocalNotificationCenter(status: .allowed)
        let service = IOSLocalNotificationService(
            center: center,
            now: { now },
            completionNotificationsEnabled: { true }
        )
        #expect(try await service.scheduleTaskCompletion(conversationID: "abc-123") == .scheduled(identifier: "amber.task-complete.abc-123"))
        let request = try #require(center.requests.first)
        #expect(IOSAppDeepLink.parse(request.deepLink) == .conversation(id: "abc-123"))
        #expect(request.fireDate == now.addingTimeInterval(1))
    }

    @Test func reminderValidatesDateAndReplacesPreviousRequest() async throws {
        let center = FakeLocalNotificationCenter(status: .allowed)
        let service = IOSLocalNotificationService(center: center, now: { now })
        #expect(try await service.scheduleManualReminder(title: "Soon", fireDate: now.addingTimeInterval(4)) == .invalidDate)
        #expect(try await service.scheduleManualReminder(title: "继续写作", fireDate: now.addingTimeInterval(600)) == .scheduled(identifier: IOSLocalNotificationService.manualReminderIdentifier))
        #expect(center.removed.last == [IOSLocalNotificationService.manualReminderIdentifier])
        service.cancelManualReminder()
        #expect(center.removed.count == 2)
    }

    @Test func disablingCompletionNotificationsRemovesOnlyPendingCompletionRequests() async {
        let center = FakeLocalNotificationCenter(status: .allowed)
        center.pendingIdentifiers = [
            "amber.task-complete.first",
            IOSLocalNotificationService.manualReminderIdentifier,
            "amber.task-complete.second"
        ]
        let service = IOSLocalNotificationService(center: center, now: { now })

        await service.cancelTaskCompletionNotifications()

        #expect(center.removed == [["amber.task-complete.first", "amber.task-complete.second"]])
    }

    @Test func deepLinkInboxBuffersNotificationUntilShellInstallsHandler() throws {
        let inbox = IOSDeepLinkInbox()
        let url = try #require(IOSAppDeepLink.url(for: .latestConversation))
        var received: [URL] = []

        inbox.submit(url)
        #expect(received.isEmpty)
        inbox.installHandler { received.append($0) }

        #expect(received == [url])
    }
}
