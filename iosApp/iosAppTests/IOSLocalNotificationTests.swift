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
    var blocksAdd = false
    private(set) var addContinuation: CheckedContinuation<Void, Never>?

    init(status: IOSLocalNotificationAuthorization) { self.status = status }

    func authorization() async -> IOSLocalNotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool {
        if requestResult { status = .allowed }
        return requestResult
    }
    func add(_ request: IOSLocalNotificationRequest) async throws {
        requests.append(request)
        if blocksAdd {
            await withCheckedContinuation { continuation in
                addContinuation = continuation
            }
        }
    }
    func pendingRequestIdentifiers() async -> [String] { pendingIdentifiers }
    func removePendingRequests(identifiers: [String]) { removed.append(identifiers) }

    func resumeAdd() {
        addContinuation?.resume()
        addContinuation = nil
    }
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

    @Test func agentNotificationToolSchedulesAndCancelsItsOwnStableRequest() async throws {
        let center = FakeLocalNotificationCenter(status: .allowed)
        let service = IOSLocalNotificationService(center: center, now: { now })
        let fireAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(600))

        let scheduled = await IOSNotificationAgentToolExecutor.execute(
            toolName: IOSAppleAgentToolCatalog.notificationSchedule,
            input: #"{"title":"喝水","body":"休息一下","fire_at":"\#(fireAt)","display_title":"安排喝水提醒"}"#,
            service: service
        )
        #expect(scheduled.contains(#""ok":true"#))
        #expect(center.requests.last?.identifier == IOSLocalNotificationService.agentReminderIdentifier)

        let cancelled = await IOSNotificationAgentToolExecutor.execute(
            toolName: IOSAppleAgentToolCatalog.notificationCancel,
            input: #"{"display_title":"取消喝水提醒"}"#,
            service: service
        )
        #expect(cancelled.contains(#""cancelled":true"#))
        #expect(center.removed.last == [IOSLocalNotificationService.agentReminderIdentifier])
    }

    @Test func cancellingInFlightAgentNotificationRemovesCommittedRequest() async {
        let center = FakeLocalNotificationCenter(status: .allowed)
        center.blocksAdd = true
        let service = IOSLocalNotificationService(center: center, now: { now })

        let task = Task {
            try await service.scheduleAgentNotification(
                title: "喝水",
                body: "休息一下",
                fireDate: now.addingTimeInterval(600)
            )
        }
        while center.addContinuation == nil { await Task.yield() }
        task.cancel()
        center.resumeAdd()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(center.removed.last == [IOSLocalNotificationService.agentReminderIdentifier])
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
