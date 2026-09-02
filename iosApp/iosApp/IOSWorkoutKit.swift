import Foundation

#if canImport(WorkoutKit)
import HealthKit
@preconcurrency import WorkoutKit
#endif

enum IOSWorkoutAuthorization: String, Sendable {
    case notDetermined
    case denied
    case authorized
}

enum IOSWorkoutPlanKind: String, Codable, Sendable {
    case goal
    case pacer
    case intervals
}

enum IOSWorkoutActivity: String, Codable, Sendable {
    case running
    case walking
    case cycling
    case hiking
}

enum IOSWorkoutLocation: String, Codable, Sendable {
    case indoor
    case outdoor
}

enum IOSWorkoutGoalType: String, Codable, Sendable {
    case time
    case distance
}

struct IOSWorkoutPlanDefinition: Codable, Equatable, Sendable {
    let title: String
    let kind: IOSWorkoutPlanKind
    let activity: IOSWorkoutActivity
    let location: IOSWorkoutLocation
    let goalType: IOSWorkoutGoalType?
    let goalValue: Double?
    let distanceKilometers: Double?
    let durationMinutes: Double?
    let workSeconds: Double?
    let recoverySeconds: Double?
    let repetitions: Int?
    let warmupMinutes: Double?
    let cooldownMinutes: Double?
}

struct IOSWorkoutPlanPreview: Equatable, Sendable {
    let definition: IOSWorkoutPlanDefinition
    let lines: [String]
    let estimatedDurationMinutes: Double?
}

struct IOSWorkoutSystemSnapshot: Equatable, Sendable {
    let id: UUID
    let scheduledAt: Date
}

struct IOSAmberWorkoutRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let definition: IOSWorkoutPlanDefinition
    let scheduledAt: Date
    let createdAt: Date
}

@MainActor
protocol IOSWorkoutManaging {
    var isSupported: Bool { get }
    var maximumScheduledWorkoutCount: Int { get }
    func authorizationState() async -> IOSWorkoutAuthorization
    func requestAuthorization() async -> IOSWorkoutAuthorization
    func scheduledWorkouts() async -> [IOSWorkoutSystemSnapshot]
    func schedule(_ definition: IOSWorkoutPlanDefinition, id: UUID, at date: Date) async throws
    func remove(id: UUID) async -> Bool
}

@MainActor
final class IOSWorkoutMetadataStore {
    nonisolated static let defaultKey = "ios.workoutkit.amber-owned.v1"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = IOSWorkoutMetadataStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [IOSAmberWorkoutRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([IOSAmberWorkoutRecord].self, from: data) else {
            return []
        }
        return records
    }

    func save(_ records: [IOSAmberWorkoutRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class IOSWorkoutService {
    static let shared = IOSWorkoutService(manager: IOSWorkoutKitManager())

    private let manager: any IOSWorkoutManaging
    private let store: IOSWorkoutMetadataStore
    private let dateProvider: () -> Date
    private var isScheduling = false

    init(
        manager: any IOSWorkoutManaging,
        store: IOSWorkoutMetadataStore = IOSWorkoutMetadataStore(),
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.manager = manager
        self.store = store
        self.dateProvider = dateProvider
    }

    func preview(_ input: IOSWorkoutPlanDefinition) throws -> IOSWorkoutPlanPreview {
        let definition = try Self.validate(input)
        return IOSWorkoutPlanPreview(
            definition: definition,
            lines: Self.summaryLines(for: definition),
            estimatedDurationMinutes: Self.estimatedDurationMinutes(for: definition)
        )
    }

    func schedule(_ input: IOSWorkoutPlanDefinition, at requestedDate: Date) async throws -> IOSAmberWorkoutRecord {
        let definition = try Self.validate(input)
        guard !isScheduling else { throw IOSWorkoutServiceError.busy }
        isScheduling = true
        defer { isScheduling = false }
        guard manager.isSupported else { throw IOSWorkoutServiceError.unsupportedDevice }
        try Self.validateScheduleDate(requestedDate, now: dateProvider())

        let authorization: IOSWorkoutAuthorization
        switch await manager.authorizationState() {
        case .notDetermined:
            authorization = await manager.requestAuthorization()
        case .denied:
            authorization = .denied
        case .authorized:
            authorization = .authorized
        }
        guard authorization == .authorized else { throw IOSWorkoutServiceError.authorizationDenied }
        try Task.checkCancellation()

        let commitNow = dateProvider()
        try Self.validateScheduleDate(requestedDate, now: commitNow)
        let before = await manager.scheduledWorkouts()
        try Task.checkCancellation()
        guard before.count < manager.maximumScheduledWorkoutCount else {
            throw IOSWorkoutServiceError.capacityReached
        }

        let id = UUID()
        let committed: IOSWorkoutSystemSnapshot
        do {
            try Task.checkCancellation()
            try await manager.schedule(definition, id: id, at: requestedDate)
            try Task.checkCancellation()
            let snapshots = await manager.scheduledWorkouts()
            try Task.checkCancellation()
            guard let snapshot = snapshots.first(where: { $0.id == id }) else {
                throw IOSWorkoutServiceError.commitFailed
            }
            committed = snapshot
        } catch is CancellationError {
            let rollback = Task { @MainActor in
                await manager.remove(id: id)
            }
            _ = await rollback.value
            throw CancellationError()
        }
        let record = IOSAmberWorkoutRecord(
            id: id,
            definition: definition,
            scheduledAt: committed.scheduledAt,
            createdAt: commitNow
        )
        var records = store.load().filter { $0.id != id }
        records.append(record)
        store.save(records)
        return record
    }

    func list() async throws -> [IOSAmberWorkoutRecord] {
        guard manager.isSupported else { throw IOSWorkoutServiceError.unsupportedDevice }
        guard await manager.authorizationState() == .authorized else {
            throw IOSWorkoutServiceError.authorizationDenied
        }
        let system = Dictionary(uniqueKeysWithValues: await manager.scheduledWorkouts().map { ($0.id, $0) })
        let reconciled = store.load().compactMap { record -> IOSAmberWorkoutRecord? in
            guard let snapshot = system[record.id] else { return nil }
            return IOSAmberWorkoutRecord(
                id: record.id,
                definition: record.definition,
                scheduledAt: snapshot.scheduledAt,
                createdAt: record.createdAt
            )
        }
        .sorted { $0.scheduledAt < $1.scheduledAt }
        store.save(reconciled)
        return reconciled
    }

    func remove(id: UUID) async throws -> IOSAmberWorkoutRecord {
        guard manager.isSupported else { throw IOSWorkoutServiceError.unsupportedDevice }
        guard await manager.authorizationState() == .authorized else {
            throw IOSWorkoutServiceError.authorizationDenied
        }
        let records = store.load()
        guard let record = records.first(where: { $0.id == id }) else {
            throw IOSWorkoutServiceError.notFound
        }
        guard await manager.remove(id: id) else {
            store.save(records.filter { $0.id != id })
            throw IOSWorkoutServiceError.notFound
        }
        store.save(records.filter { $0.id != id })
        return record
    }

    func reconcileOnLaunch() async {
        _ = try? await list()
    }

    nonisolated static func validate(_ input: IOSWorkoutPlanDefinition) throws -> IOSWorkoutPlanDefinition {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 60 else { throw IOSWorkoutServiceError.invalidTitle }
        guard !(input.activity == .hiking && input.location == .indoor) else {
            throw IOSWorkoutServiceError.unsupportedPlan
        }

        switch input.kind {
        case .goal:
            guard let goalType = input.goalType,
                  let goalValue = input.goalValue,
                  goalValue.isFinite,
                  input.distanceKilometers == nil,
                  input.durationMinutes == nil,
                  Self.intervalFieldsAreEmpty(input) else {
                throw IOSWorkoutServiceError.invalidGoal
            }
            switch goalType {
            case .time where !(1...600).contains(goalValue): throw IOSWorkoutServiceError.invalidGoal
            case .distance where !(0.1...200).contains(goalValue): throw IOSWorkoutServiceError.invalidGoal
            default: break
            }
        case .pacer:
            guard input.activity == .running || input.activity == .walking,
                  input.goalType == nil, input.goalValue == nil,
                  let distance = input.distanceKilometers, distance.isFinite, (0.1...200).contains(distance),
                  let duration = input.durationMinutes, duration.isFinite, (1...600).contains(duration),
                  Self.intervalFieldsAreEmpty(input) else {
                throw IOSWorkoutServiceError.invalidPacer
            }
        case .intervals:
            guard input.activity == .running || input.activity == .cycling,
                  input.goalType == nil, input.goalValue == nil,
                  input.distanceKilometers == nil, input.durationMinutes == nil,
                  let work = input.workSeconds, work.isFinite, (10...3_600).contains(work),
                  let recovery = input.recoverySeconds, recovery.isFinite, (10...3_600).contains(recovery),
                  let repetitions = input.repetitions, (1...20).contains(repetitions),
                  Self.validOptionalMinutes(input.warmupMinutes),
                  Self.validOptionalMinutes(input.cooldownMinutes) else {
                throw IOSWorkoutServiceError.invalidIntervals
            }
            let total = (input.warmupMinutes ?? 0) * 60
                + (input.cooldownMinutes ?? 0) * 60
                + Double(repetitions) * (work + recovery)
            guard total <= 8 * 60 * 60 else { throw IOSWorkoutServiceError.invalidIntervals }
        }

        return IOSWorkoutPlanDefinition(
            title: title,
            kind: input.kind,
            activity: input.activity,
            location: input.location,
            goalType: input.goalType,
            goalValue: input.goalValue,
            distanceKilometers: input.distanceKilometers,
            durationMinutes: input.durationMinutes,
            workSeconds: input.workSeconds,
            recoverySeconds: input.recoverySeconds,
            repetitions: input.repetitions,
            warmupMinutes: input.warmupMinutes,
            cooldownMinutes: input.cooldownMinutes
        )
    }

    nonisolated static func validateScheduleDate(_ date: Date, now: Date) throws {
        let interval = date.timeIntervalSince(now)
        guard interval >= 60, interval <= 366 * 24 * 60 * 60 else {
            throw IOSWorkoutServiceError.invalidScheduleDate
        }
    }

    nonisolated static func summaryLines(for definition: IOSWorkoutPlanDefinition) -> [String] {
        var lines = [
            "项目：\(activityLabel(definition.activity)) · \(locationLabel(definition.location))",
            "类型：\(kindLabel(definition.kind))"
        ]
        switch definition.kind {
        case .goal:
            if definition.goalType == .time, let value = definition.goalValue {
                lines.append("目标：\(format(value)) 分钟")
            } else if let value = definition.goalValue {
                lines.append("目标：\(format(value)) 公里")
            }
        case .pacer:
            lines.append("距离：\(format(definition.distanceKilometers ?? 0)) 公里")
            lines.append("用时：\(format(definition.durationMinutes ?? 0)) 分钟")
        case .intervals:
            lines.append("重复：\(definition.repetitions ?? 0) 组")
            lines.append("每组：训练 \(format(definition.workSeconds ?? 0)) 秒 · 恢复 \(format(definition.recoverySeconds ?? 0)) 秒")
            if let value = definition.warmupMinutes, value > 0 { lines.append("热身：\(format(value)) 分钟") }
            if let value = definition.cooldownMinutes, value > 0 { lines.append("放松：\(format(value)) 分钟") }
        }
        if let duration = estimatedDurationMinutes(for: definition) {
            lines.append("预计时长：\(format(duration)) 分钟")
        }
        return lines
    }

    nonisolated static func estimatedDurationMinutes(for definition: IOSWorkoutPlanDefinition) -> Double? {
        switch definition.kind {
        case .goal:
            return definition.goalType == .time ? definition.goalValue : nil
        case .pacer:
            return definition.durationMinutes
        case .intervals:
            guard let repetitions = definition.repetitions,
                  let work = definition.workSeconds,
                  let recovery = definition.recoverySeconds else { return nil }
            return (definition.warmupMinutes ?? 0)
                + (definition.cooldownMinutes ?? 0)
                + Double(repetitions) * (work + recovery) / 60
        }
    }

    nonisolated private static func intervalFieldsAreEmpty(_ input: IOSWorkoutPlanDefinition) -> Bool {
        input.workSeconds == nil && input.recoverySeconds == nil && input.repetitions == nil
            && input.warmupMinutes == nil && input.cooldownMinutes == nil
    }

    nonisolated private static func validOptionalMinutes(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && (0...120).contains(value)
    }

    nonisolated private static func activityLabel(_ activity: IOSWorkoutActivity) -> String {
        switch activity {
        case .running: "跑步"
        case .walking: "步行"
        case .cycling: "骑行"
        case .hiking: "徒步"
        }
    }

    nonisolated private static func locationLabel(_ location: IOSWorkoutLocation) -> String {
        location == .indoor ? "室内" : "户外"
    }

    nonisolated private static func kindLabel(_ kind: IOSWorkoutPlanKind) -> String {
        switch kind {
        case .goal: "单目标"
        case .pacer: "配速"
        case .intervals: "间歇"
        }
    }

    nonisolated private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

enum IOSWorkoutServiceError: LocalizedError, Equatable, Sendable {
    case authorizationDenied
    case unsupportedDevice
    case unsupportedPlan
    case invalidTitle
    case invalidGoal
    case invalidPacer
    case invalidIntervals
    case invalidScheduleDate
    case invalidIdentifier
    case invalidArguments
    case capacityReached
    case commitFailed
    case notFound
    case busy

    var errorDescription: String? {
        switch self {
        case .authorizationDenied: "未获得健身计划权限，请在系统设置中允许 Amber 安排训练。"
        case .unsupportedDevice: "当前设备未配对可用的 Apple Watch，或 Watch 上未安装体能训练 App。"
        case .unsupportedPlan: "WorkoutKit 不支持这个运动项目与位置组合。"
        case .invalidTitle: "计划名称不能为空且不能超过 60 个字符。"
        case .invalidGoal: "单目标计划需要 1–600 分钟或 0.1–200 公里的有效目标。"
        case .invalidPacer: "配速计划仅支持跑步或步行，并需要 0.1–200 公里与 1–600 分钟。"
        case .invalidIntervals: "间歇计划仅支持跑步或骑行；训练/恢复各 10–3600 秒、1–20 组，合计不超过 8 小时。"
        case .invalidScheduleDate: "安排时间必须在 1 分钟到 1 年之后。"
        case .invalidIdentifier: "workout_id 不是有效的 UUID。"
        case .invalidArguments: "健身计划参数不完整、类型错误或包含未知字段。"
        case .capacityReached: "WorkoutKit 的已安排训练数量已达上限，请先移除一个计划。"
        case .commitFailed: "WorkoutKit 未确认该计划已写入，因此 Amber 没有保存本地记录。"
        case .notFound: "该 Amber 健身计划不存在或已从体能训练 App 中移除。"
        case .busy: "已有一个健身计划正在提交，请稍后再试。"
        }
    }
}

#if canImport(WorkoutKit)
@MainActor
final class IOSWorkoutKitManager: IOSWorkoutManaging {
    var isSupported: Bool { WorkoutScheduler.isSupported }
    var maximumScheduledWorkoutCount: Int { WorkoutScheduler.maxAllowedScheduledWorkoutCount }

    func authorizationState() async -> IOSWorkoutAuthorization {
        Self.authorization(await WorkoutScheduler.shared.authorizationState)
    }

    func requestAuthorization() async -> IOSWorkoutAuthorization {
        Self.authorization(await WorkoutScheduler.shared.requestAuthorization())
    }

    func scheduledWorkouts() async -> [IOSWorkoutSystemSnapshot] {
        await WorkoutScheduler.shared.scheduledWorkouts.compactMap { scheduled in
            guard !scheduled.complete else { return nil }
            guard let date = Calendar.current.date(from: scheduled.date) else { return nil }
            return IOSWorkoutSystemSnapshot(id: scheduled.plan.id, scheduledAt: date)
        }
    }

    func schedule(_ definition: IOSWorkoutPlanDefinition, id: UUID, at date: Date) async throws {
        let plan = try Self.plan(definition, id: id)
        await WorkoutScheduler.shared.schedule(plan, at: Self.dateComponents(date))
    }

    func remove(id: UUID) async -> Bool {
        let current = await WorkoutScheduler.shared.scheduledWorkouts
        guard let scheduled = current.first(where: { $0.plan.id == id }) else {
            return false
        }
        await WorkoutScheduler.shared.remove(scheduled.plan, at: scheduled.date)
        let remaining = await WorkoutScheduler.shared.scheduledWorkouts
        return !remaining.contains { $0.plan.id == id }
    }

    private static func authorization(_ state: WorkoutScheduler.AuthorizationState) -> IOSWorkoutAuthorization {
        switch state {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .restricted, .denied: .denied
        @unknown default: .denied
        }
    }

    private static func plan(_ definition: IOSWorkoutPlanDefinition, id: UUID) throws -> WorkoutPlan {
        let activity = activity(definition.activity)
        let location = location(definition.location)
        switch definition.kind {
        case .goal:
            let goal: WorkoutGoal = definition.goalType == .time
                ? .time(definition.goalValue!, .minutes)
                : .distance(definition.goalValue!, .kilometers)
            guard SingleGoalWorkout.supportsActivity(activity),
                  SingleGoalWorkout.supportsGoal(goal, activity: activity, location: location) else {
                throw IOSWorkoutServiceError.unsupportedPlan
            }
            return WorkoutPlan(.goal(SingleGoalWorkout(activity: activity, location: location, goal: goal)), id: id)
        case .pacer:
            guard PacerWorkout.supportsActivity(activity) else { throw IOSWorkoutServiceError.unsupportedPlan }
            let workout = PacerWorkout(
                activity: activity,
                location: location,
                distance: Measurement(value: definition.distanceKilometers!, unit: .kilometers),
                time: Measurement(value: definition.durationMinutes!, unit: .minutes)
            )
            return WorkoutPlan(.pacer(workout), id: id)
        case .intervals:
            let workGoal = WorkoutGoal.time(definition.workSeconds!, .seconds)
            let recoveryGoal = WorkoutGoal.time(definition.recoverySeconds!, .seconds)
            guard CustomWorkout.supportsActivity(activity),
                  CustomWorkout.supportsGoal(workGoal, activity: activity, location: location),
                  CustomWorkout.supportsGoal(recoveryGoal, activity: activity, location: location) else {
                throw IOSWorkoutServiceError.unsupportedPlan
            }
            let warmup = definition.warmupMinutes.flatMap { $0 > 0 ? WorkoutStep(goal: .time($0, .minutes)) : nil }
            let cooldown = definition.cooldownMinutes.flatMap { $0 > 0 ? WorkoutStep(goal: .time($0, .minutes)) : nil }
            let block = IntervalBlock(
                steps: [
                    IntervalStep(.work, goal: workGoal),
                    IntervalStep(.recovery, goal: recoveryGoal),
                ],
                iterations: definition.repetitions!
            )
            let workout = CustomWorkout(
                activity: activity,
                location: location,
                displayName: definition.title,
                warmup: warmup,
                blocks: [block],
                cooldown: cooldown
            )
            return WorkoutPlan(.custom(workout), id: id)
        }
    }

    private static func activity(_ value: IOSWorkoutActivity) -> HKWorkoutActivityType {
        switch value {
        case .running: .running
        case .walking: .walking
        case .cycling: .cycling
        case .hiking: .hiking
        }
    }

    private static func location(_ value: IOSWorkoutLocation) -> HKWorkoutSessionLocationType {
        value == .indoor ? .indoor : .outdoor
    }

    private static func dateComponents(_ date: Date) -> DateComponents {
        Calendar.current.dateComponents(in: .current, from: date)
    }
}
#else
@MainActor
final class IOSWorkoutKitManager: IOSWorkoutManaging {
    var isSupported: Bool { false }
    var maximumScheduledWorkoutCount: Int { 0 }
    func authorizationState() async -> IOSWorkoutAuthorization { .denied }
    func requestAuthorization() async -> IOSWorkoutAuthorization { .denied }
    func scheduledWorkouts() async -> [IOSWorkoutSystemSnapshot] { [] }
    func schedule(_ definition: IOSWorkoutPlanDefinition, id: UUID, at date: Date) async throws {
        throw IOSWorkoutServiceError.unsupportedDevice
    }
    func remove(id: UUID) async -> Bool { false }
}
#endif

enum IOSWorkoutAgentToolExecutor {
    @MainActor
    static func execute(toolName: String, input: String) async -> String {
        guard var arguments = object(input) else { return failure(toolName, .invalidArguments) }
        arguments.removeValue(forKey: "display_title")
        do {
            switch toolName {
            case IOSAppleAgentToolCatalog.workoutPlanPreview:
                guard !arguments.keys.contains("schedule_at") else { throw IOSWorkoutServiceError.invalidArguments }
                let preview = try IOSWorkoutService.shared.preview(try definition(arguments))
                var payload: [String: Any] = [
                    "ok": true,
                    "tool": toolName,
                    "plan": planPayload(preview.definition),
                    "summary": preview.lines,
                    "note": "这是健身计划预览，不是医疗建议。"
                ]
                if let duration = preview.estimatedDurationMinutes {
                    payload["estimated_duration_minutes"] = duration
                }
                return json(payload)
            case IOSAppleAgentToolCatalog.workoutSchedule:
                guard let rawDate = arguments.removeValue(forKey: "schedule_at") as? String,
                      let date = parseDate(rawDate) else { throw IOSWorkoutServiceError.invalidScheduleDate }
                let record = try await IOSWorkoutService.shared.schedule(try definition(arguments), at: date)
                return json(["ok": true, "tool": toolName, "workout": recordPayload(record)])
            case IOSAppleAgentToolCatalog.scheduledWorkoutsList:
                guard arguments.isEmpty else { throw IOSWorkoutServiceError.invalidArguments }
                return json([
                    "ok": true,
                    "tool": toolName,
                    "workouts": try await IOSWorkoutService.shared.list().map(recordPayload)
                ])
            case IOSAppleAgentToolCatalog.scheduledWorkoutRemove:
                guard Set(arguments.keys) == ["workout_id"],
                      let rawID = arguments["workout_id"] as? String,
                      let id = UUID(uuidString: rawID) else {
                    throw IOSWorkoutServiceError.invalidIdentifier
                }
                _ = try await IOSWorkoutService.shared.remove(id: id)
                return json(["ok": true, "tool": toolName, "workout_id": id.uuidString, "removed": true])
            default:
                throw IOSWorkoutServiceError.invalidArguments
            }
        } catch let error as IOSWorkoutServiceError {
            return failure(toolName, error)
        } catch {
            return failure(toolName, .invalidArguments)
        }
    }

    static func approvalPreview(arguments: [String: Any]) -> String {
        let arguments = arguments.filter { $0.key != "display_title" }
        if let id = arguments["workout_id"] as? String {
            guard let uuid = UUID(uuidString: id), let record = storedRecord(id: uuid) else {
                return "计划 ID：\(id)\n本地没有找到这条 Amber 健身计划"
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return (["计划：\(record.definition.title)"]
                + IOSWorkoutService.summaryLines(for: record.definition)
                + ["安排：\(formatter.string(from: record.scheduledAt))", "计划 ID：\(id)"])
                .joined(separator: "\n")
        }
        if arguments.isEmpty {
            return "查看 Amber 已安排的健身计划"
        }
        guard let definition = try? definition(arguments.filter { $0.key != "schedule_at" }),
              let validated = try? IOSWorkoutService.validate(definition) else {
            return ChatToolCallParsing.truncatedMcpArguments(arguments)
        }
        var lines = ["计划：\(validated.title)"] + IOSWorkoutService.summaryLines(for: validated)
        if let value = arguments["schedule_at"] as? String, let date = parseDate(value) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lines.append("安排：\(formatter.string(from: date))")
        }
        return lines.joined(separator: "\n")
    }

    private static func definition(_ arguments: [String: Any]) throws -> IOSWorkoutPlanDefinition {
        let allowed: Set<String> = [
            "title", "kind", "activity", "location", "goal_type", "goal_value",
            "distance_km", "duration_minutes", "work_seconds", "recovery_seconds",
            "repetitions", "warmup_minutes", "cooldown_minutes"
        ]
        guard Set(arguments.keys).isSubset(of: allowed),
              let title = arguments["title"] as? String,
              let kindRaw = arguments["kind"] as? String,
              let kind = IOSWorkoutPlanKind(rawValue: kindRaw),
              let activityRaw = arguments["activity"] as? String,
              let activity = IOSWorkoutActivity(rawValue: activityRaw),
              optionalString(arguments["location"]) != .invalid,
              optionalString(arguments["goal_type"]) != .invalid,
              optionalNumber(arguments["goal_value"]) != .invalid,
              optionalNumber(arguments["distance_km"]) != .invalid,
              optionalNumber(arguments["duration_minutes"]) != .invalid,
              optionalNumber(arguments["work_seconds"]) != .invalid,
              optionalNumber(arguments["recovery_seconds"]) != .invalid,
              optionalInteger(arguments["repetitions"]) != .invalid,
              optionalNumber(arguments["warmup_minutes"]) != .invalid,
              optionalNumber(arguments["cooldown_minutes"]) != .invalid else {
            throw IOSWorkoutServiceError.invalidArguments
        }
        let location = (arguments["location"] as? String).flatMap(IOSWorkoutLocation.init(rawValue:)) ?? .outdoor
        guard arguments["location"] == nil || IOSWorkoutLocation(rawValue: arguments["location"] as! String) != nil else {
            throw IOSWorkoutServiceError.invalidArguments
        }
        let goalType = (arguments["goal_type"] as? String).flatMap(IOSWorkoutGoalType.init(rawValue:))
        guard arguments["goal_type"] == nil || goalType != nil else { throw IOSWorkoutServiceError.invalidArguments }
        return IOSWorkoutPlanDefinition(
            title: title,
            kind: kind,
            activity: activity,
            location: location,
            goalType: goalType,
            goalValue: number(arguments["goal_value"]),
            distanceKilometers: number(arguments["distance_km"]),
            durationMinutes: number(arguments["duration_minutes"]),
            workSeconds: number(arguments["work_seconds"]),
            recoverySeconds: number(arguments["recovery_seconds"]),
            repetitions: integer(arguments["repetitions"]),
            warmupMinutes: number(arguments["warmup_minutes"]),
            cooldownMinutes: number(arguments["cooldown_minutes"])
        )
    }

    private enum OptionalValue: Equatable { case missing, valid, invalid }

    private static func optionalString(_ value: Any?) -> OptionalValue {
        value == nil ? .missing : (value is String ? .valid : .invalid)
    }

    private static func optionalNumber(_ value: Any?) -> OptionalValue {
        value == nil ? .missing : (number(value) == nil ? .invalid : .valid)
    }

    private static func optionalInteger(_ value: Any?) -> OptionalValue {
        value == nil ? .missing : (integer(value) == nil ? .invalid : .valid)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value),
              number.rounded() == number,
              abs(number) <= 9_007_199_254_740_991 else { return nil }
        return Int(number)
    }

    private static func storedRecord(id: UUID) -> IOSAmberWorkoutRecord? {
        guard let data = UserDefaults.standard.data(forKey: IOSWorkoutMetadataStore.defaultKey),
              let records = try? JSONDecoder().decode([IOSAmberWorkoutRecord].self, from: data) else {
            return nil
        }
        return records.first { $0.id == id }
    }

    private static func object(_ input: String) -> [String: Any]? {
        guard let data = input.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func planPayload(_ definition: IOSWorkoutPlanDefinition) -> [String: Any] {
        var payload: [String: Any] = [
            "title": definition.title,
            "kind": definition.kind.rawValue,
            "activity": definition.activity.rawValue,
            "location": definition.location.rawValue,
        ]
        if let value = definition.goalType { payload["goal_type"] = value.rawValue }
        if let value = definition.goalValue { payload["goal_value"] = value }
        if let value = definition.distanceKilometers { payload["distance_km"] = value }
        if let value = definition.durationMinutes { payload["duration_minutes"] = value }
        if let value = definition.workSeconds { payload["work_seconds"] = value }
        if let value = definition.recoverySeconds { payload["recovery_seconds"] = value }
        if let value = definition.repetitions { payload["repetitions"] = value }
        if let value = definition.warmupMinutes { payload["warmup_minutes"] = value }
        if let value = definition.cooldownMinutes { payload["cooldown_minutes"] = value }
        return payload
    }

    private static func recordPayload(_ record: IOSAmberWorkoutRecord) -> [String: Any] {
        [
            "workout_id": record.id.uuidString,
            "scheduled_at": ISO8601DateFormatter().string(from: record.scheduledAt),
            "created_at": ISO8601DateFormatter().string(from: record.createdAt),
            "plan": planPayload(record.definition),
            "summary": IOSWorkoutService.summaryLines(for: record.definition),
        ]
    }

    private static func failure(_ toolName: String, _ error: IOSWorkoutServiceError) -> String {
        json(["ok": false, "tool": toolName, "error": error.localizedDescription])
    }

    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"无法编码健身计划结果。"}"#
        }
        return string
    }
}
