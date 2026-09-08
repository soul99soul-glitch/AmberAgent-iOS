import XCTest
@testable import iosApp

@MainActor
private final class WatchNotificationCenter: IOSLocalNotificationCenter {
    var requests: [IOSLocalNotificationRequest] = []
    var removed: [String] = []
    var beforeAuthorization: (() async -> Void)?
    func authorization() async -> IOSLocalNotificationAuthorization {
        await beforeAuthorization?()
        return .allowed
    }
    func requestAuthorization() async throws -> Bool { true }
    func add(_ request: IOSLocalNotificationRequest) async throws { requests.append(request) }
    func pendingRequestIdentifiers() async -> [String] { requests.map(\.identifier) }
    func removePendingRequests(identifiers: [String]) { removed += identifiers }
}

@MainActor
final class WatchNotificationTests: XCTestCase {
    func testConcurrentRefreshesScheduleOneAttentionNotification() async throws {
        let suite = "WatchNotificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = WatchNotificationCenter()
        center.beforeAuthorization = { await Task.yield() }
        let service = IOSLocalNotificationService(
            center: center, completionNotificationsEnabled: { true }, watchNotificationDefaults: defaults
        )
        let snapshot = waitingSnapshot()
        let first = Task { @MainActor in
            try await service.scheduleWatchAttention(snapshot: snapshot, isStillCurrent: { true })
        }
        let second = Task { @MainActor in
            try await service.scheduleWatchAttention(snapshot: snapshot, isStillCurrent: { true })
        }
        try await first.value
        try await second.value
        XCTAssertEqual(center.requests.count, 1)
    }

    func testAttentionNotificationIsPrivateDeduplicatedAndCancelledWhenResolved() async throws {
        let suite = "WatchNotificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = WatchNotificationCenter()
        let service = IOSLocalNotificationService(
            center: center, completionNotificationsEnabled: { true }, watchNotificationDefaults: defaults
        )
        var snapshot = waitingSnapshot()
        try await service.scheduleWatchAttention(snapshot: snapshot, isStillCurrent: { true })
        try await service.scheduleWatchAttention(snapshot: snapshot, isStillCurrent: { true })
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertFalse(center.requests[0].body.contains("private question"))
        XCTAssertTrue(center.requests[0].deepLink.absoluteString.contains("conversation"))
        snapshot.phase = "completed"
        snapshot.decision = nil
        try await service.scheduleWatchAttention(snapshot: snapshot, isStillCurrent: { true })
        XCTAssertEqual(center.removed, [center.requests[0].identifier])
        let restarted = IOSLocalNotificationService(
            center: center, completionNotificationsEnabled: { true }, watchNotificationDefaults: defaults
        )
        try await restarted.scheduleWatchAttention(snapshot: waitingSnapshot(), isStillCurrent: { true })
        XCTAssertEqual(center.requests.count, 1)
    }

    func testRestartCancelsPreviouslyQueuedAttentionWhenTaskResolves() async throws {
        let suite = "WatchNotificationRestart.\\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = WatchNotificationCenter()
        let first = IOSLocalNotificationService(center: center,
            completionNotificationsEnabled: { true }, watchNotificationDefaults: defaults)
        try await first.scheduleWatchAttention(snapshot: waitingSnapshot(), isStillCurrent: { true })
        let identifier = try XCTUnwrap(center.requests.first?.identifier)
        let restarted = IOSLocalNotificationService(center: center,
            completionNotificationsEnabled: { true }, watchNotificationDefaults: defaults)
        var completed = waitingSnapshot()
        completed.phase = "completed"
        completed.decision = nil
        try await restarted.scheduleWatchAttention(snapshot: completed, isStillCurrent: { true })
        XCTAssertTrue(center.removed.contains(identifier))
    }

    func testDisabledOrStaleAttentionNeverSchedules() async throws {
        let center = WatchNotificationCenter()
        let disabled = IOSLocalNotificationService(
            center: center, completionNotificationsEnabled: { false }, watchNotificationDefaults: nil
        )
        try await disabled.scheduleWatchAttention(snapshot: waitingSnapshot(), isStillCurrent: { true })
        let enabled = IOSLocalNotificationService(
            center: center, completionNotificationsEnabled: { true }, watchNotificationDefaults: nil
        )
        try await enabled.scheduleWatchAttention(snapshot: waitingSnapshot(), isStillCurrent: { false })
        XCTAssertTrue(center.requests.isEmpty)
    }

    func testCancelledNotificationDoesNotReturnAfterPreferenceIsEnabledAgain() async throws {
        let center = WatchNotificationCenter()
        var enabled = true
        let service = IOSLocalNotificationService(
            center: center, completionNotificationsEnabled: { enabled }, watchNotificationDefaults: nil
        )
        center.beforeAuthorization = { [weak service] in
            enabled = false
            await service?.cancelTaskCompletionNotifications()
            enabled = true
        }
        try await service.scheduleWatchAttention(snapshot: waitingSnapshot(), isStillCurrent: { true })
        XCTAssertTrue(center.requests.isEmpty)
    }

    private func waitingSnapshot() -> WatchTaskSnapshot {
        var snapshot = WatchTaskSnapshot.idle
        snapshot.runId = "run-1"
        snapshot.conversationId = "d48cbcac-b0c3-4b93-9e68-4235ecdd52a9"
        snapshot.phase = "waitingForUser"
        snapshot.updatedAt = Date()
        snapshot.decision = WatchDecision(
            id: "decision-1", type: .askUser, title: "private question", body: "private question",
            options: [], riskLevel: .low, allowsVoice: true
        )
        return snapshot
    }
}
