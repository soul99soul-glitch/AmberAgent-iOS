import Foundation
import Testing
@testable import iosApp

@Suite("WorkoutKit planning")
@MainActor
struct IOSWorkoutKitTests {
    @Test func previewShowsUnitsDurationAndNoMedicalClaim() throws {
        let service = makeService(manager: FakeWorkoutManager()).service
        let preview = try service.preview(intervals())

        #expect(preview.lines.contains("重复：6 组"))
        #expect(preview.lines.contains("每组：训练 60 秒 · 恢复 30 秒"))
        #expect(preview.lines.contains("预计时长：19 分钟"))
        #expect(preview.estimatedDurationMinutes == 19)
    }

    @Test func malformedOrUnboundedIntervalsFailClosed() throws {
        var plan = intervals()
        plan = IOSWorkoutPlanDefinition(
            title: plan.title, kind: plan.kind, activity: plan.activity, location: plan.location,
            goalType: nil, goalValue: nil, distanceKilometers: nil, durationMinutes: nil,
            workSeconds: 60, recoverySeconds: 30, repetitions: 21,
            warmupMinutes: 5, cooldownMinutes: 5
        )

        #expect(throws: IOSWorkoutServiceError.invalidIntervals) {
            _ = try IOSWorkoutService.validate(plan)
        }
        #expect(throws: IOSWorkoutServiceError.invalidPacer) {
            _ = try IOSWorkoutService.validate(
                IOSWorkoutPlanDefinition(
                    title: "骑行配速", kind: .pacer, activity: .cycling, location: .outdoor,
                    goalType: nil, goalValue: nil, distanceKilometers: 10, durationMinutes: 30,
                    workSeconds: nil, recoverySeconds: nil, repetitions: nil,
                    warmupMinutes: nil, cooldownMinutes: nil
                )
            )
        }
    }

    @Test func unsupportedAuthorizationAndCapacityAreExplicit() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        let unsupported = FakeWorkoutManager()
        unsupported.isSupported = false
        await #expect(throws: IOSWorkoutServiceError.unsupportedDevice) {
            _ = try await makeService(manager: unsupported, now: now).service.schedule(
                goal(), at: now.addingTimeInterval(3_600)
            )
        }

        let denied = FakeWorkoutManager()
        denied.authorization = .denied
        await #expect(throws: IOSWorkoutServiceError.authorizationDenied) {
            _ = try await makeService(manager: denied, now: now).service.schedule(
                goal(), at: now.addingTimeInterval(3_600)
            )
        }

        let full = FakeWorkoutManager()
        full.maximumScheduledWorkoutCount = 1
        full.snapshots = [IOSWorkoutSystemSnapshot(id: UUID(), scheduledAt: now.addingTimeInterval(7_200))]
        await #expect(throws: IOSWorkoutServiceError.capacityReached) {
            _ = try await makeService(manager: full, now: now).service.schedule(
                goal(), at: now.addingTimeInterval(3_600)
            )
        }
    }

    @Test func scheduleRevalidatesAfterAuthorizationAndPersistsOnlyConfirmedCommit() async {
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        let manager = FakeWorkoutManager()
        manager.authorization = .notDetermined
        manager.requestedAuthorization = .authorized
        manager.onRequestAuthorization = { clock = clock.addingTimeInterval(61) }
        let pair = makeService(manager: manager, dateProvider: { clock })

        await #expect(throws: IOSWorkoutServiceError.invalidScheduleDate) {
            _ = try await pair.service.schedule(goal(), at: clock.addingTimeInterval(90))
        }
        #expect(pair.store.load().isEmpty)

        manager.authorization = .authorized
        manager.scheduleShouldCommit = false
        await #expect(throws: IOSWorkoutServiceError.commitFailed) {
            _ = try await pair.service.schedule(goal(), at: clock.addingTimeInterval(3_600))
        }
        #expect(pair.store.load().isEmpty)
    }

    @Test func cancellingInFlightScheduleRollsBackCommittedWorkout() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let manager = FakeWorkoutManager()
        manager.blocksSchedule = true
        let pair = makeService(manager: manager, now: now)

        let task = Task {
            try await pair.service.schedule(goal(), at: now.addingTimeInterval(3_600))
        }
        while manager.scheduleContinuation == nil { await Task.yield() }
        task.cancel()
        manager.resumeSchedule()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(manager.removedIDs.count == 1)
        #expect(manager.snapshots.isEmpty)
        #expect(pair.store.load().isEmpty)
    }

    @Test func scheduleListAndRemoveUseStableAmberIdentifier() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let manager = FakeWorkoutManager()
        let pair = makeService(manager: manager, now: now)

        let first = try await pair.service.schedule(goal(), at: now.addingTimeInterval(3_600))
        let second = try await pair.service.schedule(intervals(), at: now.addingTimeInterval(7_200))
        manager.snapshots.removeAll { $0.id == first.id }

        #expect(try await pair.service.list().map(\.id) == [second.id])
        #expect(pair.store.load().map(\.id) == [second.id])
        let removed = try await pair.service.remove(id: second.id)
        #expect(removed.id == second.id)
        #expect(manager.removedIDs == [second.id])
        #expect(pair.store.load().isEmpty)
    }

    @Test func unavailableSchedulerDoesNotEraseAmberMetadata() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let manager = FakeWorkoutManager()
        let pair = makeService(manager: manager, now: now)
        let record = try await pair.service.schedule(goal(), at: now.addingTimeInterval(3_600))

        manager.isSupported = false
        await #expect(throws: IOSWorkoutServiceError.unsupportedDevice) {
            _ = try await pair.service.list()
        }
        #expect(pair.store.load().map(\.id) == [record.id])
    }

    @Test func approvalPreviewIsCompactAndLegible() {
        let preview = IOSWorkoutAgentToolExecutor.approvalPreview(arguments: [
            "display_title": "安排健身计划",
            "title": "下班跑",
            "kind": "pacer",
            "activity": "running",
            "location": "outdoor",
            "distance_km": 5,
            "duration_minutes": 30,
            "schedule_at": "2033-05-01T10:00:00Z",
        ])
        #expect(preview.contains("计划：下班跑"))
        #expect(preview.contains("距离：5 公里"))
        #expect(preview.contains("用时：30 分钟"))
        #expect(preview.contains("安排："))
    }

    @Test func hugeIntegerInputReturnsStructuredFailureInsteadOfTrapping() async {
        let result = await IOSWorkoutAgentToolExecutor.execute(
            toolName: IOSAppleAgentToolCatalog.workoutPlanPreview,
            input: #"{"title":"间歇","kind":"intervals","activity":"running","work_seconds":60,"recovery_seconds":30,"repetitions":1e300}"#
        )
        #expect(result.contains("参数不完整"))
    }

    private func goal() -> IOSWorkoutPlanDefinition {
        IOSWorkoutPlanDefinition(
            title: "午间走路", kind: .goal, activity: .walking, location: .outdoor,
            goalType: .time, goalValue: 30, distanceKilometers: nil, durationMinutes: nil,
            workSeconds: nil, recoverySeconds: nil, repetitions: nil,
            warmupMinutes: nil, cooldownMinutes: nil
        )
    }

    private func intervals() -> IOSWorkoutPlanDefinition {
        IOSWorkoutPlanDefinition(
            title: "跑步间歇", kind: .intervals, activity: .running, location: .outdoor,
            goalType: nil, goalValue: nil, distanceKilometers: nil, durationMinutes: nil,
            workSeconds: 60, recoverySeconds: 30, repetitions: 6,
            warmupMinutes: 5, cooldownMinutes: 5
        )
    }

    private func makeService(
        manager: FakeWorkoutManager,
        now: Date = Date(),
        dateProvider: (() -> Date)? = nil
    ) -> (service: IOSWorkoutService, store: IOSWorkoutMetadataStore) {
        let defaults = UserDefaults(suiteName: "IOSWorkoutKitTests.\(UUID().uuidString)")!
        let store = IOSWorkoutMetadataStore(defaults: defaults, key: "workouts")
        return (
            IOSWorkoutService(manager: manager, store: store, dateProvider: dateProvider ?? { now }),
            store
        )
    }
}

@MainActor
private final class FakeWorkoutManager: IOSWorkoutManaging {
    var isSupported = true
    var maximumScheduledWorkoutCount = 50
    var authorization: IOSWorkoutAuthorization = .authorized
    var requestedAuthorization: IOSWorkoutAuthorization = .authorized
    var onRequestAuthorization: (() -> Void)?
    var scheduleShouldCommit = true
    var snapshots: [IOSWorkoutSystemSnapshot] = []
    var removedIDs: [UUID] = []
    var blocksSchedule = false
    private(set) var scheduleContinuation: CheckedContinuation<Void, Never>?

    func authorizationState() async -> IOSWorkoutAuthorization { authorization }

    func requestAuthorization() async -> IOSWorkoutAuthorization {
        onRequestAuthorization?()
        authorization = requestedAuthorization
        return authorization
    }

    func scheduledWorkouts() async -> [IOSWorkoutSystemSnapshot] { snapshots }

    func schedule(_ definition: IOSWorkoutPlanDefinition, id: UUID, at date: Date) async throws {
        if scheduleShouldCommit {
            snapshots.append(IOSWorkoutSystemSnapshot(id: id, scheduledAt: date))
        }
        if blocksSchedule {
            await withCheckedContinuation { continuation in
                scheduleContinuation = continuation
            }
        }
    }

    func remove(id: UUID) async -> Bool {
        guard snapshots.contains(where: { $0.id == id }) else { return false }
        removedIDs.append(id)
        snapshots.removeAll { $0.id == id }
        return true
    }

    func resumeSchedule() {
        scheduleContinuation?.resume()
        scheduleContinuation = nil
    }
}
