import Foundation
import Testing
import UserNotifications
@testable import iosApp

@MainActor
private final class FakeLocalNotificationCenter: IOSLocalNotificationCenter {
    var status: IOSLocalNotificationAuthorization
    var requestResult = true
    var requests: [IOSLocalNotificationRequest] = []
    var removed: [[String]] = []
    var pendingIdentifiers: [String] = []
    var deliveredIdentifiers: [String] = []
    var removedDelivered: [[String]] = []
    var blocksAdd = false
    var blocksSoundUpdate = false
    var completionSoundUpdates: [Bool] = []
    private(set) var addContinuation: CheckedContinuation<Void, Never>?
    private(set) var soundUpdateContinuation: CheckedContinuation<Void, Never>?

    init(status: IOSLocalNotificationAuthorization) { self.status = status }

    func authorization() async -> IOSLocalNotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool {
        if requestResult { status = .allowed }
        return requestResult
    }
    func add(_ request: IOSLocalNotificationRequest) async throws {
        requests.append(request)
        if !pendingIdentifiers.contains(request.identifier) { pendingIdentifiers.append(request.identifier) }
        if blocksAdd {
            await withCheckedContinuation { continuation in
                addContinuation = continuation
            }
        }
    }
    func pendingRequestIdentifiers() async -> [String] { pendingIdentifiers }
    func removePendingRequests(identifiers: [String]) {
        removed.append(identifiers)
        pendingIdentifiers.removeAll { identifiers.contains($0) }
    }
    func deliveredRequestIdentifiers() async -> [String] { deliveredIdentifiers }
    func removeDeliveredRequests(identifiers: [String]) { removedDelivered.append(identifiers) }
    func updateTaskCompletionSound(enabled: Bool) async throws {
        completionSoundUpdates.append(enabled)
        let targets = requests.indices.filter {
            requests[$0].identifier.hasPrefix("amber.task-complete.") &&
                pendingIdentifiers.contains(requests[$0].identifier) && requests[$0].playsSound != enabled
        }
        if blocksSoundUpdate {
            await withCheckedContinuation { soundUpdateContinuation = $0 }
        }
        for index in targets {
            requests[index].playsSound = enabled
            // UNUserNotificationCenter updates content by adding the request again.
            if !pendingIdentifiers.contains(requests[index].identifier) {
                pendingIdentifiers.append(requests[index].identifier)
            }
        }
    }

    func resumeSoundUpdate() {
        soundUpdateContinuation?.resume()
        soundUpdateContinuation = nil
    }

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

    @Test func completionSoundFollowsPreferenceWithoutSilencingOtherNotifications() async throws {
        let center = FakeLocalNotificationCenter(status: .allowed)
        var hapticEnabled = false
        let service = IOSLocalNotificationService(
            center: center, now: { now }, completionNotificationsEnabled: { true },
            completionHapticEnabled: { hapticEnabled }
        )
        _ = try await service.scheduleTaskCompletion(conversationID: "reply")
        #expect(center.requests.first?.playsSound == false)
        _ = try await service.scheduleManualReminder(title: "提醒", fireDate: now.addingTimeInterval(600))
        hapticEnabled = true
        try await service.refreshTaskCompletionSound()
        #expect(center.requests.first?.playsSound == true)
        hapticEnabled = false
        try await service.refreshTaskCompletionSound()
        #expect(center.requests.first?.playsSound == false)
        #expect(center.requests.last?.playsSound == true)
        #expect(center.requests.first?.userInfo[IOSTaskCompletionNotificationFeedback.markerKey] == "true")
    }

    @Test func completionSettingChangeDuringAddIsReconciledAfterCommit() async throws {
        let center = FakeLocalNotificationCenter(status: .allowed)
        center.blocksAdd = true
        var hapticEnabled = true
        let service = IOSLocalNotificationService(
            center: center, now: { now }, completionNotificationsEnabled: { true },
            completionHapticEnabled: { hapticEnabled }
        )
        let task = Task { try await service.scheduleTaskCompletion(conversationID: "reply") }
        while center.addContinuation == nil { await Task.yield() }
        #expect(center.requests.first?.playsSound == true)
        hapticEnabled = false
        center.resumeAdd()
        _ = try await task.value
        #expect(center.requests.first?.playsSound == false)
        #expect(center.completionSoundUpdates == [false])
    }

    @Test func foregroundCompletionKeepsBannerAndLeavesRevealOwnerTheOnlyFeedbackSource() {
        #expect(IOSTaskCompletionNotificationFeedback.presentationOptions(
            identifier: "amber.task-complete.reply", userInfo: [:]
        ) == [.banner])
        #expect(IOSTaskCompletionNotificationFeedback.presentationOptions(
            identifier: IOSLocalNotificationService.manualReminderIdentifier, userInfo: [:]
        ) == [.banner, .sound])
        #expect(IOSTaskCompletionNotificationFeedback.presentationOptions(
            identifier: "amber.watch-attention.reply.decision", userInfo: [:]
        ) == [.banner, .sound])
    }

    @Test func cancellationWinsAgainstInFlightCompletionSoundUpdate() async throws {
        let center = FakeLocalNotificationCenter(status: .allowed)
        var hapticEnabled = true
        let service = IOSLocalNotificationService(
            center: center, now: { now }, completionNotificationsEnabled: { true },
            completionHapticEnabled: { hapticEnabled }
        )
        _ = try await service.scheduleTaskCompletion(conversationID: "reply")
        center.pendingIdentifiers.append(IOSLocalNotificationService.manualReminderIdentifier)
        hapticEnabled = false
        center.blocksSoundUpdate = true
        let update = Task { try await service.refreshTaskCompletionSound() }
        while center.soundUpdateContinuation == nil { await Task.yield() }
        await service.cancelTaskCompletionNotifications()
        center.resumeSoundUpdate()
        try await update.value
        #expect(center.pendingIdentifiers == [IOSLocalNotificationService.manualReminderIdentifier])
        #expect(center.removed.last == ["amber.task-complete.reply"])
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
        center.deliveredIdentifiers = [
            "amber.task-complete.first",
            IOSLocalNotificationService.manualReminderIdentifier
        ]
        let service = IOSLocalNotificationService(center: center, now: { now })

        await service.cancelTaskCompletionNotifications()

        #expect(center.removed == [["amber.task-complete.first", "amber.task-complete.second"]])
        #expect(center.removedDelivered == [["amber.task-complete.first"]])
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

    @Test func watchHandoffSurvivesHandlerInstallationUntilDestinationAcknowledges() throws {
        let suite = "WatchHandoff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try #require(IOSAppDeepLink.url(for: .conversation(id: "conversation-1")))
        let first = IOSDeepLinkInbox(defaults: defaults)
        var received: [URL] = []
        first.submit(url, persistUntilHandled: true)
        first.installHandler { received.append($0) }
        #expect(received == [url])

        // Installing a handler is not evidence that bootstrap/navigation finished.
        let restarted = IOSDeepLinkInbox(defaults: defaults)
        received = []
        restarted.installHandler { received.append($0) }
        #expect(received == [url])
        restarted.acknowledge(url)

        received = []
        IOSDeepLinkInbox(defaults: defaults).installHandler { received.append($0) }
        #expect(received.isEmpty)
    }

    @Test func watchHandoffWithLiveHandlerIsDurableAndDeliveredOnce() throws {
        let suite = "WatchHandoffLive.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try #require(IOSAppDeepLink.url(for: .conversation(id: "conversation-2")))
        let inbox = IOSDeepLinkInbox(defaults: defaults)
        var received: [URL] = []
        inbox.installHandler { received.append($0) }
        inbox.submit(url, persistUntilHandled: true)
        #expect(received == [url])
        received = []
        IOSDeepLinkInbox(defaults: defaults).installHandler { received.append($0) }
        #expect(received == [url])
    }
}
