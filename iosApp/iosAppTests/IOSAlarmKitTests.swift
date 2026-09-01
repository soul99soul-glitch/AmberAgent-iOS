import Foundation
import Testing
@testable import iosApp

@Suite("AlarmKit service")
@MainActor
struct IOSAlarmKitTests {
    @Test func schedulePersistsOnlyAfterSystemCommit() async throws {
        let manager = FakeAlarmManager(authorization: .notDetermined)
        manager.requestedAuthorization = .authorized
        let (service, store) = makeService(manager: manager)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let record = try await service.schedule(
            IOSAlarmScheduleInput(
                title: "  起床  ", kind: .oneTime,
                fireAt: now.addingTimeInterval(60), weekdays: [],
                hour: nil, minute: nil, durationSeconds: nil
            ),
            now: now
        )

        #expect(manager.didRequestAuthorization)
        #expect(manager.scheduledInputs.count == 1)
        #expect(record.title == "起床")
        #expect(store.load() == [record])
    }

    @Test func denialAndInvalidSchedulesAreExplicit() async {
        let denied = FakeAlarmManager(authorization: .denied)
        let (service, _) = makeService(manager: denied)
        let timer = IOSAlarmScheduleInput(
            title: "计时", kind: .timer, fireAt: nil, weekdays: [],
            hour: nil, minute: nil, durationSeconds: 60
        )
        await #expect(throws: IOSAlarmServiceError.authorizationDenied) {
            _ = try await service.schedule(timer)
        }
        #expect(throws: IOSAlarmServiceError.invalidWeekly) {
            _ = try IOSAlarmService.validate(
                IOSAlarmScheduleInput(
                    title: "训练", kind: .weekly, fireAt: nil,
                    weekdays: ["funday"], hour: 8, minute: 0, durationSeconds: nil
                ),
                now: Date()
            )
        }
    }

    @Test func validWeeklyScheduleCommitsCanonicalDays() async throws {
        let manager = FakeAlarmManager(authorization: .authorized)
        let (service, store) = makeService(manager: manager)
        let record = try await service.schedule(
            IOSAlarmScheduleInput(
                title: "训练", kind: .weekly, fireAt: nil,
                weekdays: ["Friday", "monday", "friday"], hour: 8, minute: 30,
                durationSeconds: nil
            )
        )

        #expect(manager.scheduledInputs.first?.weekdays == ["monday", "friday"])
        #expect(store.load() == [record])
    }

    @Test func oneTimeScheduleIsRevalidatedAfterAuthorization() async {
        let manager = FakeAlarmManager(authorization: .notDetermined)
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        manager.onRequestAuthorization = { clock = clock.addingTimeInterval(3) }
        let (service, store) = makeService(manager: manager, dateProvider: { clock })
        let input = IOSAlarmScheduleInput(
            title: "马上响", kind: .oneTime,
            fireAt: clock.addingTimeInterval(6), weekdays: [],
            hour: nil, minute: nil, durationSeconds: nil
        )

        await #expect(throws: IOSAlarmServiceError.invalidOneTime) {
            _ = try await service.schedule(input)
        }
        #expect(manager.scheduledInputs.isEmpty)
        #expect(store.load().isEmpty)
    }

    @Test func failedSystemCommitDoesNotPersistMetadata() async {
        let manager = FakeAlarmManager(authorization: .authorized)
        manager.scheduleError = IOSAlarmServiceError.capacityReached
        let (service, store) = makeService(manager: manager)

        await #expect(throws: IOSAlarmServiceError.capacityReached) {
            _ = try await service.schedule(timer(title: "茶", seconds: 30))
        }
        #expect(store.load().isEmpty)
    }

    @Test func listReconcilesAlreadyFiredAndCancelUsesIdentifier() async throws {
        let manager = FakeAlarmManager(authorization: .authorized)
        let (service, store) = makeService(manager: manager)
        let first = try await service.schedule(timer(title: "茶", seconds: 30))
        let second = try await service.schedule(timer(title: "烤箱", seconds: 60))
        manager.snapshots.removeAll { $0.id == first.id }

        #expect(try service.list().map(\.id) == [second.id])
        #expect(store.load().map(\.id) == [second.id])
        let cancelled = try service.cancel(id: second.id)
        #expect(cancelled.id == second.id)
        #expect(manager.cancelledIDs == [second.id])
        #expect(store.load().isEmpty)
        #expect(throws: IOSAlarmServiceError.notFound) { try service.cancel(id: first.id) }
    }

    @Test func approvalCopyDistinguishesAlarmFromNotification() {
        let request = McpToolApprovalRequest(
            id: "1",
            serverName: "iPhone",
            toolName: IOSAppleAgentToolCatalog.alarmSchedule,
            argumentsPreview: #"{"title":"起床","kind":"one_time"}"#,
            reason: "会响铃"
        )
        #expect(request.title == "确认系统闹钟操作")
        #expect(request.displayToolName.contains("会响铃"))
        #expect(request.systemImage == "alarm")
    }

    @Test func malformedConflictingFieldsFailClosed() async {
        let malformed = [
            #"{"title":"茶","kind":"timer","duration_seconds":30,"fire_at":123}"#,
            #"{"title":"起床","kind":"one_time","fire_at":"2035-01-01T00:00:00Z","weekdays":123}"#,
            #"{"title":"训练","kind":"weekly","weekdays":["monday"],"hour":true,"minute":0}"#,
        ]

        for input in malformed {
            let result = await IOSAlarmAgentToolExecutor.execute(
                toolName: IOSAppleAgentToolCatalog.alarmSchedule,
                input: input
            )
            #expect(result.contains("闹钟参数不完整或包含未知字段"))
        }
    }

    private func timer(title: String, seconds: TimeInterval) -> IOSAlarmScheduleInput {
        IOSAlarmScheduleInput(
            title: title, kind: .timer, fireAt: nil, weekdays: [],
            hour: nil, minute: nil, durationSeconds: seconds
        )
    }

    private func makeService(
        manager: FakeAlarmManager,
        dateProvider: @escaping () -> Date = Date.init
    ) -> (IOSAlarmService, IOSAlarmMetadataStore) {
        let suite = "IOSAlarmKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = IOSAlarmMetadataStore(defaults: defaults, key: "alarms")
        return (IOSAlarmService(manager: manager, store: store, dateProvider: dateProvider), store)
    }
}

@MainActor
private final class FakeAlarmManager: IOSAlarmManaging {
    var authorizationState: IOSAlarmAuthorization
    var requestedAuthorization: IOSAlarmAuthorization = .authorized
    var didRequestAuthorization = false
    var onRequestAuthorization: (() -> Void)?
    var scheduleError: Error?
    var scheduledInputs: [IOSAlarmScheduleInput] = []
    var snapshots: [IOSAlarmSystemSnapshot] = []
    var cancelledIDs: [UUID] = []

    init(authorization: IOSAlarmAuthorization) {
        authorizationState = authorization
    }

    func requestAuthorization() async throws -> IOSAlarmAuthorization {
        didRequestAuthorization = true
        onRequestAuthorization?()
        authorizationState = requestedAuthorization
        return requestedAuthorization
    }

    func schedule(_ request: IOSAlarmScheduleInput, id: UUID) async throws -> IOSAlarmSystemSnapshot {
        if let scheduleError { throw scheduleError }
        scheduledInputs.append(request)
        let snapshot = IOSAlarmSystemSnapshot(id: id, state: request.kind == .timer ? "countdown" : "scheduled")
        snapshots.append(snapshot)
        return snapshot
    }

    func alarmSnapshots() throws -> [IOSAlarmSystemSnapshot] { snapshots }

    func cancel(id: UUID) throws {
        cancelledIDs.append(id)
        snapshots.removeAll { $0.id == id }
    }
}
