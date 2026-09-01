import AppIntents
import Foundation

#if canImport(AlarmKit)
import AlarmKit
import SwiftUI
#endif

enum IOSAlarmAuthorization: String, Sendable {
    case notDetermined
    case denied
    case authorized
}

enum IOSAlarmKind: String, Codable, Sendable {
    case oneTime = "one_time"
    case weekly
    case timer
}

struct IOSAlarmScheduleInput: Equatable, Sendable {
    let title: String
    let kind: IOSAlarmKind
    let fireAt: Date?
    let weekdays: [String]
    let hour: Int?
    let minute: Int?
    let durationSeconds: TimeInterval?
}

struct IOSAlarmSystemSnapshot: Equatable, Sendable {
    let id: UUID
    let state: String
}

struct IOSAmberAlarmRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let kind: IOSAlarmKind
    let fireAt: Date?
    let weekdays: [String]
    let hour: Int?
    let minute: Int?
    let durationSeconds: TimeInterval?
    let createdAt: Date
    var state: String
}

@MainActor
protocol IOSAlarmManaging {
    var authorizationState: IOSAlarmAuthorization { get }
    func requestAuthorization() async throws -> IOSAlarmAuthorization
    func schedule(_ request: IOSAlarmScheduleInput, id: UUID) async throws -> IOSAlarmSystemSnapshot
    func alarmSnapshots() throws -> [IOSAlarmSystemSnapshot]
    func cancel(id: UUID) throws
}

@MainActor
final class IOSAlarmMetadataStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "ios.alarmkit.amber-owned.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [IOSAmberAlarmRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([IOSAmberAlarmRecord].self, from: data) else {
            return []
        }
        return records
    }

    func save(_ records: [IOSAmberAlarmRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class IOSAlarmService {
    static let shared = IOSAlarmService(manager: IOSAlarmKitManager())

    private let manager: any IOSAlarmManaging
    private let store: IOSAlarmMetadataStore
    private let dateProvider: () -> Date

    init(
        manager: any IOSAlarmManaging,
        store: IOSAlarmMetadataStore = IOSAlarmMetadataStore(),
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.manager = manager
        self.store = store
        self.dateProvider = dateProvider
    }

    func schedule(_ input: IOSAlarmScheduleInput, now: Date? = nil) async throws -> IOSAmberAlarmRecord {
        let initialNow = now ?? dateProvider()
        var validated = try Self.validate(input, now: initialNow)
        let authorization: IOSAlarmAuthorization
        switch manager.authorizationState {
        case .notDetermined:
            authorization = try await manager.requestAuthorization()
        case .denied:
            authorization = .denied
        case .authorized:
            authorization = .authorized
        }
        guard authorization == .authorized else { throw IOSAlarmServiceError.authorizationDenied }

        let commitNow = now ?? dateProvider()
        validated = try Self.validate(validated, now: commitNow)
        let id = UUID()
        let system = try await manager.schedule(validated, id: id)
        let record = IOSAmberAlarmRecord(
            id: id,
            title: validated.title,
            kind: validated.kind,
            fireAt: validated.fireAt,
            weekdays: validated.weekdays,
            hour: validated.hour,
            minute: validated.minute,
            durationSeconds: validated.durationSeconds,
            createdAt: commitNow,
            state: system.state
        )
        var records = store.load().filter { $0.id != id }
        records.append(record)
        store.save(records)
        return record
    }

    func list() throws -> [IOSAmberAlarmRecord] {
        let systemByID = Dictionary(uniqueKeysWithValues: try manager.alarmSnapshots().map { ($0.id, $0) })
        let reconciled = store.load().compactMap { record -> IOSAmberAlarmRecord? in
            guard let system = systemByID[record.id] else { return nil }
            var current = record
            current.state = system.state
            return current
        }
        .sorted { $0.createdAt > $1.createdAt }
        store.save(reconciled)
        return reconciled
    }

    func cancel(id: UUID) throws -> IOSAmberAlarmRecord {
        let records = store.load()
        guard let record = records.first(where: { $0.id == id }) else {
            throw IOSAlarmServiceError.notFound
        }
        let activeIDs = Set(try manager.alarmSnapshots().map(\.id))
        guard activeIDs.contains(id) else {
            store.save(records.filter { $0.id != id })
            throw IOSAlarmServiceError.notFound
        }
        try manager.cancel(id: id)
        store.save(records.filter { $0.id != id })
        return record
    }

    func reconcileOnLaunch() {
        _ = try? list()
    }

    static func validate(_ input: IOSAlarmScheduleInput, now: Date) throws -> IOSAlarmScheduleInput {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80 else { throw IOSAlarmServiceError.invalidTitle }

        switch input.kind {
        case .oneTime:
            guard let fireAt = input.fireAt,
                  fireAt.timeIntervalSince(now) >= 5,
                  input.weekdays.isEmpty,
                  input.hour == nil,
                  input.minute == nil,
                  input.durationSeconds == nil else {
                throw IOSAlarmServiceError.invalidOneTime
            }
            return IOSAlarmScheduleInput(
                title: title, kind: .oneTime, fireAt: fireAt,
                weekdays: [], hour: nil, minute: nil, durationSeconds: nil
            )
        case .weekly:
            let validDays = Set(Self.weekdayOrder)
            let requestedDays = Set(input.weekdays.map { $0.lowercased() })
            guard !requestedDays.isEmpty,
                  requestedDays.allSatisfy(validDays.contains),
                  let hour = input.hour, (0...23).contains(hour),
                  let minute = input.minute, (0...59).contains(minute),
                  input.fireAt == nil,
                  input.durationSeconds == nil else {
                throw IOSAlarmServiceError.invalidWeekly
            }
            let days = Self.weekdayOrder.filter(requestedDays.contains)
            return IOSAlarmScheduleInput(
                title: title, kind: .weekly, fireAt: nil,
                weekdays: days, hour: hour, minute: minute, durationSeconds: nil
            )
        case .timer:
            guard let duration = input.durationSeconds,
                  (10...86_400).contains(duration),
                  input.fireAt == nil,
                  input.weekdays.isEmpty,
                  input.hour == nil,
                  input.minute == nil else {
                throw IOSAlarmServiceError.invalidTimer
            }
            return IOSAlarmScheduleInput(
                title: title, kind: .timer, fireAt: nil,
                weekdays: [], hour: nil, minute: nil, durationSeconds: duration
            )
        }
    }

    static let weekdayOrder = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"
    ]
}

enum IOSAlarmServiceError: LocalizedError, Equatable {
    case authorizationDenied
    case invalidTitle
    case invalidOneTime
    case invalidWeekly
    case invalidTimer
    case invalidIdentifier
    case invalidArguments
    case notFound
    case unavailable
    case capacityReached

    var errorDescription: String? {
        switch self {
        case .authorizationDenied: "未获得闹钟权限，请在系统设置中允许 Amber 使用闹钟。"
        case .invalidTitle: "闹钟标题不能为空且不能超过 80 个字符。"
        case .invalidOneTime: "一次性闹钟需要至少 5 秒后的 fire_at，且不能混用重复或计时器参数。"
        case .invalidWeekly: "每周闹钟需要有效的 weekdays、hour 与 minute，且不能混用其他时间参数。"
        case .invalidTimer: "计时器需要 10 到 86400 秒的 duration_seconds，且不能混用其他时间参数。"
        case .invalidIdentifier: "alarm_id 不是有效的 UUID。"
        case .invalidArguments: "闹钟参数不完整或包含未知字段。"
        case .notFound: "该 Amber 闹钟不存在、已响过或已被删除。"
        case .unavailable: "当前设备不可用 AlarmKit。"
        case .capacityReached: "系统闹钟数量已达上限，请先取消一个闹钟。"
        }
    }
}

#if canImport(AlarmKit)
struct IOSStopAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "停止 Amber 闹钟"
    static let openAppWhenRun = false

    @Parameter(title: "闹钟 ID")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else { throw IOSAlarmServiceError.invalidIdentifier }
        try AlarmManager.shared.stop(id: id)
        return .result()
    }
}

struct IOSOpenAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "打开 Amber 闹钟"
    static let openAppWhenRun = true

    @Parameter(title: "闹钟 ID")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        guard UUID(uuidString: alarmID) != nil else { throw IOSAlarmServiceError.invalidIdentifier }
        return .result()
    }
}

@MainActor
final class IOSAlarmKitManager: IOSAlarmManaging {
    var authorizationState: IOSAlarmAuthorization {
        Self.mapAuthorization(AlarmManager.shared.authorizationState)
    }

    func requestAuthorization() async throws -> IOSAlarmAuthorization {
        Self.mapAuthorization(try await AlarmManager.shared.requestAuthorization())
    }

    func schedule(_ request: IOSAlarmScheduleInput, id: UUID) async throws -> IOSAlarmSystemSnapshot {
        let stopButton = AlarmButton(
            text: LocalizedStringResource(stringLiteral: IOSAlarmCopy.stopButton),
            textColor: .white,
            systemImageName: "stop.fill"
        )
        let openButton = AlarmButton(
            text: LocalizedStringResource(stringLiteral: IOSAlarmCopy.openButton),
            textColor: .white,
            systemImageName: "arrow.up.forward.app"
        )
        let presentation = AlarmPresentation(
            alert: .init(
                title: LocalizedStringResource(stringLiteral: request.title),
                stopButton: stopButton,
                secondaryButton: openButton,
                secondaryButtonBehavior: .custom
            ),
            countdown: .init(title: LocalizedStringResource(stringLiteral: request.title))
        )
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: IOSAmberAlarmMetadata(title: request.title),
            tintColor: .orange
        )
        let stopIntent = IOSStopAlarmIntent(alarmID: id.uuidString)
        let secondaryIntent = IOSOpenAlarmIntent(alarmID: id.uuidString)
        let configuration: AlarmManager.AlarmConfiguration<IOSAmberAlarmMetadata>
        switch request.kind {
        case .oneTime:
            configuration = .alarm(
                schedule: .fixed(request.fireAt!),
                attributes: attributes,
                stopIntent: stopIntent,
                secondaryIntent: secondaryIntent
            )
        case .weekly:
            let weekdays = request.weekdays.compactMap(Self.weekday)
            let time = Alarm.Schedule.Relative.Time(hour: request.hour!, minute: request.minute!)
            configuration = .alarm(
                schedule: .relative(.init(time: time, repeats: .weekly(weekdays))),
                attributes: attributes,
                stopIntent: stopIntent,
                secondaryIntent: secondaryIntent
            )
        case .timer:
            configuration = .timer(
                duration: request.durationSeconds!,
                attributes: attributes,
                stopIntent: stopIntent,
                secondaryIntent: secondaryIntent
            )
        }

        do {
            return Self.snapshot(try await AlarmManager.shared.schedule(id: id, configuration: configuration))
        } catch AlarmManager.AlarmError.maximumLimitReached {
            throw IOSAlarmServiceError.capacityReached
        }
    }

    func alarmSnapshots() throws -> [IOSAlarmSystemSnapshot] {
        try AlarmManager.shared.alarms.map(Self.snapshot)
    }

    func cancel(id: UUID) throws {
        try AlarmManager.shared.cancel(id: id)
    }

    private static func mapAuthorization(_ state: AlarmManager.AuthorizationState) -> IOSAlarmAuthorization {
        switch state {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

    private static func snapshot(_ alarm: Alarm) -> IOSAlarmSystemSnapshot {
        let state: String = switch alarm.state {
        case .scheduled: "scheduled"
        case .countdown: "countdown"
        case .paused: "paused"
        case .alerting: "alerting"
        @unknown default: "unknown"
        }
        return IOSAlarmSystemSnapshot(id: alarm.id, state: state)
    }

    private static func weekday(_ value: String) -> Locale.Weekday? {
        switch value {
        case "sunday": .sunday
        case "monday": .monday
        case "tuesday": .tuesday
        case "wednesday": .wednesday
        case "thursday": .thursday
        case "friday": .friday
        case "saturday": .saturday
        default: nil
        }
    }
}
#else
@MainActor
final class IOSAlarmKitManager: IOSAlarmManaging {
    var authorizationState: IOSAlarmAuthorization { .denied }
    func requestAuthorization() async throws -> IOSAlarmAuthorization { throw IOSAlarmServiceError.unavailable }
    func schedule(_ request: IOSAlarmScheduleInput, id: UUID) async throws -> IOSAlarmSystemSnapshot { throw IOSAlarmServiceError.unavailable }
    func alarmSnapshots() throws -> [IOSAlarmSystemSnapshot] { throw IOSAlarmServiceError.unavailable }
    func cancel(id: UUID) throws { throw IOSAlarmServiceError.unavailable }
}
#endif

@MainActor
enum IOSAlarmAgentToolExecutor {
    static func execute(toolName: String, input: String) async -> String {
        guard var arguments = object(input) else { return failure(toolName, IOSAlarmServiceError.invalidArguments) }
        arguments.removeValue(forKey: "display_title")
        do {
            switch toolName {
            case IOSAppleAgentToolCatalog.alarmSchedule:
                guard Set(arguments.keys).isSubset(of: [
                    "title", "kind", "fire_at", "weekdays", "hour", "minute", "duration_seconds"
                ]),
                let title = arguments["title"] as? String,
                let kindValue = arguments["kind"] as? String,
                let kind = IOSAlarmKind(rawValue: kindValue),
                Self.hasValidOptionalTypes(arguments) else {
                    throw IOSAlarmServiceError.invalidArguments
                }
                let fireAt: Date?
                if let raw = arguments["fire_at"] as? String {
                    guard let parsed = Self.parseDate(raw) else { throw IOSAlarmServiceError.invalidOneTime }
                    fireAt = parsed
                } else {
                    fireAt = nil
                }
                let input = IOSAlarmScheduleInput(
                    title: title,
                    kind: kind,
                    fireAt: fireAt,
                    weekdays: arguments["weekdays"] as? [String] ?? [],
                    hour: Self.jsonInteger(arguments["hour"]),
                    minute: Self.jsonInteger(arguments["minute"]),
                    durationSeconds: (arguments["duration_seconds"] as? NSNumber)?.doubleValue
                )
                let record = try await IOSAlarmService.shared.schedule(input)
                return json(["ok": true, "tool": toolName, "alarm": payload(record)])
            case IOSAppleAgentToolCatalog.alarmsList:
                guard arguments.isEmpty else { throw IOSAlarmServiceError.invalidArguments }
                return json([
                    "ok": true,
                    "tool": toolName,
                    "alarms": try IOSAlarmService.shared.list().map(payload)
                ])
            case IOSAppleAgentToolCatalog.alarmCancel:
                guard Set(arguments.keys) == ["alarm_id"],
                      let rawID = arguments["alarm_id"] as? String,
                      let id = UUID(uuidString: rawID) else {
                    throw IOSAlarmServiceError.invalidIdentifier
                }
                let record = try IOSAlarmService.shared.cancel(id: id)
                return json([
                    "ok": true,
                    "tool": toolName,
                    "alarm_id": record.id.uuidString,
                    "cancelled": true
                ])
            default:
                throw IOSAlarmServiceError.invalidArguments
            }
        } catch {
            return failure(toolName, error)
        }
    }

    private static func object(_ input: String) -> [String: Any]? {
        guard let data = input.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func hasValidOptionalTypes(_ arguments: [String: Any]) -> Bool {
        if let value = arguments["fire_at"], !(value is String) { return false }
        if let value = arguments["weekdays"], !(value is [String]) { return false }
        if let value = arguments["hour"], Self.jsonInteger(value) == nil { return false }
        if let value = arguments["minute"], Self.jsonInteger(value) == nil { return false }
        if let value = arguments["duration_seconds"] {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        }
        return true
    }

    private static func jsonInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func payload(_ record: IOSAmberAlarmRecord) -> [String: Any] {
        var value: [String: Any] = [
            "alarm_id": record.id.uuidString,
            "title": record.title,
            "kind": record.kind.rawValue,
            "state": record.state,
            "created_at": ISO8601DateFormatter().string(from: record.createdAt)
        ]
        if let fireAt = record.fireAt { value["fire_at"] = ISO8601DateFormatter().string(from: fireAt) }
        if !record.weekdays.isEmpty { value["weekdays"] = record.weekdays }
        if let hour = record.hour { value["hour"] = hour }
        if let minute = record.minute { value["minute"] = minute }
        if let duration = record.durationSeconds { value["duration_seconds"] = duration }
        return value
    }

    private static func failure(_ toolName: String, _ error: Error) -> String {
        json([
            "ok": false,
            "tool": toolName,
            "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        ])
    }

    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"无法编码闹钟结果。"}"#
        }
        return string
    }
}
