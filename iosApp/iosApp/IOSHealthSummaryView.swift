import Foundation
import SwiftUI
import UIKit

#if canImport(HealthKit)
import HealthKit
#endif

struct IOSHealthDailySteps: Identifiable, Equatable {
    let date: Date
    let stepCount: Double

    var id: Date { date }
}

struct IOSHealthStepSummary: Equatable {
    let days: [IOSHealthDailySteps]

    var todayStepCount: Double { days.last?.stepCount ?? 0 }
    var hasData: Bool { days.contains { $0.stepCount > 0 } }
}

enum IOSHealthAuthorizationRequirement: Equatable {
    case notConfigured
    case unavailable
    case shouldRequest
    case queryReady
}

@MainActor
protocol IOSHealthSummaryProviding: AnyObject {
    func authorizationRequirement() async throws -> IOSHealthAuthorizationRequirement
    func requestAuthorization() async throws
    func loadStepSummary(now: Date, calendar: Calendar) async throws -> IOSHealthStepSummary
}

@MainActor
final class IOSHealthSummaryService: IOSHealthSummaryProviding {
    private let isConfigured: Bool

    #if canImport(HealthKit)
    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore(), isConfigured: Bool? = nil) {
        self.store = store
        self.isConfigured = isConfigured ?? Self.currentTargetHasHealthKitEntitlementMirror()
    }
    #else
    init(isConfigured: Bool? = nil) {
        self.isConfigured = isConfigured ?? Self.currentTargetHasHealthKitEntitlementMirror()
    }
    #endif

    func authorizationRequirement() async throws -> IOSHealthAuthorizationRequirement {
        guard isConfigured else { return .notConfigured }
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable(), let stepType else {
            return .unavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: [], read: [stepType]) { status, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                switch status {
                case .shouldRequest:
                    continuation.resume(returning: .shouldRequest)
                case .unnecessary, .unknown:
                    continuation.resume(returning: .queryReady)
                @unknown default:
                    continuation.resume(returning: .queryReady)
                }
            }
        }
        #else
        return .unavailable
        #endif
    }

    func requestAuthorization() async throws {
        guard isConfigured else { throw IOSHealthSummaryError.notConfigured }
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable(), let stepType else {
            throw IOSHealthSummaryError.unavailable
        }
        try await store.requestAuthorization(toShare: [], read: [stepType])
        #else
        throw IOSHealthSummaryError.unavailable
        #endif
    }

    func loadStepSummary(now: Date = Date(), calendar: Calendar = .current) async throws -> IOSHealthStepSummary {
        guard isConfigured else { throw IOSHealthSummaryError.notConfigured }
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable(), let stepType else {
            throw IOSHealthSummaryError.unavailable
        }

        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else {
            throw IOSHealthSummaryError.invalidDateRange
        }

        let totals: [Date: Double] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: start,
                end: end,
                options: [.strictStartDate]
            )
            let query = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: [.cumulativeSum],
                anchorDate: today,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let collection else {
                    continuation.resume(returning: [:])
                    return
                }

                var result: [Date: Double] = [:]
                collection.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let day = calendar.startOfDay(for: statistics.startDate)
                    guard day < end else { return }
                    result[day] = statistics.sumQuantity()?.doubleValue(for: .count()) ?? 0
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }

        let days = (-6 ... 0).compactMap { offset -> IOSHealthDailySteps? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return IOSHealthDailySteps(date: date, stepCount: totals[date] ?? 0)
        }
        return IOSHealthStepSummary(days: days)
        #else
        throw IOSHealthSummaryError.unavailable
        #endif
    }

    #if canImport(HealthKit)
    private var stepType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .stepCount)
    }
    #endif

    static func currentTargetHasHealthKitEntitlementMirror(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> Bool {
        let key = bundleIdentifier?.hasSuffix(".experimental-gpl") == true
            ? "AmberAgentExperimentalConfiguredEntitlements"
            : "AmberAgentConfiguredEntitlements"
        let configured = infoDictionary?[key] as? [String] ?? []
        return configured.contains("com.apple.developer.healthkit")
    }
}

struct IOSHealthAgentDailySummary: Equatable {
    let date: Date
    let steps: Double
    let activeEnergyKilocalories: Double
    let exerciseMinutes: Double
    let sleepHours: Double
}

struct IOSHealthAgentWorkoutSummary: Equatable {
    let activity: String
    let startedAt: Date
    let durationMinutes: Double
    let energyKilocalories: Double?
    let distanceKilometers: Double?
}

struct IOSHealthAgentSummary: Equatable {
    let days: [IOSHealthAgentDailySummary]
    let workouts: [IOSHealthAgentWorkoutSummary]
}

@MainActor
protocol IOSHealthAgentSummaryProviding: AnyObject {
    func requestAuthorization() async throws
    func loadSummary(days: Int, includeWorkouts: Bool, now: Date, calendar: Calendar) async throws -> IOSHealthAgentSummary
}

@MainActor
final class IOSHealthAgentSummaryService: IOSHealthAgentSummaryProviding {
    #if canImport(HealthKit)
    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }
    #else
    init() {}
    #endif

    func requestAuthorization() async throws {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else { throw IOSHealthSummaryError.unavailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
        #else
        throw IOSHealthSummaryError.unavailable
        #endif
    }

    func loadSummary(
        days: Int,
        includeWorkouts: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> IOSHealthAgentSummary {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else { throw IOSHealthSummaryError.unavailable }
        let boundedDays = min(max(days, 1), 30)
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(boundedDays - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else {
            throw IOSHealthSummaryError.invalidDateRange
        }

        async let steps = dailyQuantity(
            identifier: .stepCount,
            unit: .count(),
            start: start,
            end: end,
            anchor: today,
            calendar: calendar
        )
        async let energy = dailyQuantity(
            identifier: .activeEnergyBurned,
            unit: .kilocalorie(),
            start: start,
            end: end,
            anchor: today,
            calendar: calendar
        )
        async let exercise = dailyQuantity(
            identifier: .appleExerciseTime,
            unit: .minute(),
            start: start,
            end: end,
            anchor: today,
            calendar: calendar
        )
        async let sleep = dailySleepHours(start: start, end: end, calendar: calendar)
        async let workouts = includeWorkouts
            ? recentWorkouts(start: start, end: end, limit: 20)
            : []

        let (stepValues, energyValues, exerciseValues, sleepValues, workoutValues) = try await (
            steps, energy, exercise, sleep, workouts
        )
        let summaries = (0..<boundedDays).compactMap { index -> IOSHealthAgentDailySummary? in
            guard let date = calendar.date(byAdding: .day, value: index, to: start) else { return nil }
            let day = calendar.startOfDay(for: date)
            return IOSHealthAgentDailySummary(
                date: day,
                steps: stepValues[day] ?? 0,
                activeEnergyKilocalories: energyValues[day] ?? 0,
                exerciseMinutes: exerciseValues[day] ?? 0,
                sleepHours: sleepValues[day] ?? 0
            )
        }
        return IOSHealthAgentSummary(days: summaries, workouts: workoutValues)
        #else
        throw IOSHealthSummaryError.unavailable
        #endif
    }

    #if canImport(HealthKit)
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        [
            HKQuantityTypeIdentifier.stepCount,
            .activeEnergyBurned,
            .appleExerciseTime
        ].compactMap(HKQuantityType.quantityType(forIdentifier:)).forEach { types.insert($0) }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        return types
    }

    private func dailyQuantity(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date,
        anchor: Date,
        calendar: Calendar
    ) async throws -> [Date: Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [:] }
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: [.cumulativeSum],
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var values: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let day = calendar.startOfDay(for: statistics.startDate)
                    guard day < end else { return }
                    values[day] = statistics.sumQuantity()?.doubleValue(for: unit) ?? 0
                }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }

    private func dailySleepHours(
        start: Date,
        end: Date,
        calendar: Calendar
    ) async throws -> [Date: Double] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [:] }
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
                }
            }
            store.execute(query)
        }
        var hours: [Date: Double] = [:]
        for sample in samples {
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                  value != .inBed,
                  value != .awake else { continue }
            let day = calendar.startOfDay(for: sample.endDate)
            hours[day, default: 0] += sample.endDate.timeIntervalSince(sample.startDate) / 3_600
        }
        return hours
    }

    private func recentWorkouts(start: Date, end: Date, limit: Int) async throws -> [IOSHealthAgentWorkoutSummary] {
        let samples: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
                }
            }
            store.execute(query)
        }
        return samples.map { workout in
            IOSHealthAgentWorkoutSummary(
                activity: Self.activityName(workout.workoutActivityType),
                startedAt: workout.startDate,
                durationMinutes: workout.duration / 60,
                energyKilocalories: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                distanceKilometers: workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo))
            )
        }
    }

    private static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: "walking"
        case .running: "running"
        case .cycling: "cycling"
        case .swimming: "swimming"
        case .hiking: "hiking"
        case .traditionalStrengthTraining: "strength_training"
        case .functionalStrengthTraining: "functional_strength_training"
        case .yoga: "yoga"
        case .highIntensityIntervalTraining: "hiit"
        default: "workout_\(type.rawValue)"
        }
    }
    #endif
}

enum IOSHealthAgentToolCatalog {
    static let toolName = "health_summary_read"
}

@MainActor
enum IOSHealthAgentToolExecutor {
    private struct Arguments: Decodable {
        let days: Int?
        let includeWorkouts: Bool?

        enum CodingKeys: String, CodingKey {
            case days
            case includeWorkouts = "include_workouts"
        }
    }

    static func execute(
        input: String,
        service: any IOSHealthAgentSummaryProviding = IOSHealthAgentSummaryService()
    ) async -> String {
        guard let data = input.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return failure("参数无效；只支持 days 与 include_workouts。")
        }
        object.removeValue(forKey: "display_title")
        guard
              Set(object.keys).isSubset(of: ["days", "include_workouts"]) else {
            return failure("参数无效；只支持 days 与 include_workouts。")
        }
        guard let arguments = try? JSONDecoder().decode(Arguments.self, from: data) else {
            return failure("参数类型无效；days 必须是整数，include_workouts 必须是布尔值。")
        }
        let days = min(max(arguments.days ?? 7, 1), 30)
        let includeWorkouts = arguments.includeWorkouts ?? true
        do {
            try await service.requestAuthorization()
            try Task.checkCancellation()
            let summary = try await service.loadSummary(
                days: days,
                includeWorkouts: includeWorkouts,
                now: Date(),
                calendar: .current
            )
            let formatter = ISO8601DateFormatter()
            return json([
                "ok": true,
                "tool": IOSHealthAgentToolCatalog.toolName,
                "privacy": "user_authorized_health_data",
                "days": summary.days.map { day in
                    [
                        "date": formatter.string(from: day.date),
                        "steps": Int(day.steps.rounded()),
                        "active_energy_kcal": day.activeEnergyKilocalories,
                        "exercise_minutes": day.exerciseMinutes,
                        "sleep_hours": day.sleepHours
                    ] as [String: Any]
                },
                "workouts": summary.workouts.map { workout in
                    var value: [String: Any] = [
                        "activity": workout.activity,
                        "started_at": formatter.string(from: workout.startedAt),
                        "duration_minutes": workout.durationMinutes
                    ]
                    workout.energyKilocalories.map { value["energy_kcal"] = $0 }
                    workout.distanceKilometers.map { value["distance_km"] = $0 }
                    return value
                }
            ])
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private static func failure(_ reason: String) -> String {
        json(["ok": false, "tool": IOSHealthAgentToolCatalog.toolName, "reason": reason])
    }

    private static func json(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return #"{"ok":false,"tool":"health_summary_read","reason":"无法编码健康摘要。"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum IOSHealthSummaryError: LocalizedError {
    case notConfigured
    case unavailable
    case invalidDateRange

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "此构建未配置 HealthKit。"
        case .unavailable:
            "当前设备无法使用健康数据。"
        case .invalidDateRange:
            "无法生成近 7 日的日期范围。"
        }
    }
}

@MainActor
@Observable
final class IOSHealthSummaryViewModel {
    enum State: Equatable {
        case loading
        case notConfigured
        case permissionRequired
        case unavailable
        case empty(IOSHealthStepSummary)
        case loaded(IOSHealthStepSummary)
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var isRequesting = false
    @ObservationIgnored private let service: any IOSHealthSummaryProviding
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar

    init(
        service: any IOSHealthSummaryProviding = IOSHealthSummaryService(),
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.service = service
        self.now = now
        self.calendar = calendar
    }

    func load() async {
        state = .loading
        do {
            switch try await service.authorizationRequirement() {
            case .notConfigured:
                state = .notConfigured
            case .unavailable:
                state = .unavailable
            case .shouldRequest:
                state = .permissionRequired
            case .queryReady:
                try await loadSummary()
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func requestAccess() async {
        guard !isRequesting else { return }
        isRequesting = true
        state = .loading
        defer { isRequesting = false }

        do {
            try await service.requestAuthorization()
            try await loadSummary()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func loadSummary() async throws {
        let summary = try await service.loadStepSummary(now: now(), calendar: calendar)
        state = summary.hasData ? .loaded(summary) : .empty(summary)
    }
}

@MainActor
struct IOSHealthSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: IOSHealthSummaryViewModel

    init(model: IOSHealthSummaryViewModel = IOSHealthSummaryViewModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        privacySection
                        stateSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.load() }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load() }
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer()
            Text("健康摘要")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var privacySection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "隐私")
            AmberFormGroup {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 28, height: 28)
                    Text("你可以在本页查看步数，也可以在对话中逐次批准 Agent 读取运动与睡眠摘要。含健康数据的会话不会进入 Amber 同步备份。")
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch model.state {
        case .loading:
            statusCard(title: "正在读取健康摘要", message: "步数只在本机查询。", systemImage: "heart.text.clipboard") {
                ProgressView().tint(AmberTheme.accent)
            }
        case .notConfigured:
            statusCard(title: "此构建未启用健康摘要", message: "HealthKit 只在已配置对应 Apple capability 的稳定版中提供。", systemImage: "heart.slash", action: nil)
        case .permissionRequired:
            statusCard(title: "连接 Apple 健康", message: "授权后可查看今天和近 7 日步数。", systemImage: "heart.text.clipboard") {
                Button("允许读取步数") {
                    Task { await model.requestAccess() }
                }
                .buttonStyle(.borderedProminent)
                .tint(AmberTheme.accent)
                .disabled(model.isRequesting)
            }
        case .unavailable:
            statusCard(title: "此设备不支持健康数据", message: "请在支持 Apple 健康的 iPhone 上使用。", systemImage: "heart.slash", action: nil)
        case .empty(let summary):
            summarySection(summary)
            statusCard(title: "暂时没有可读取的步数", message: "可能是近 7 日没有记录，或尚未允许 Amber 读取步数。可在“健康”App 的头像 → App → Amber 中检查授权。", systemImage: "figure.walk") {
                Button("打开 Amber 设置") { openSettings() }
                    .buttonStyle(.bordered)
                    .tint(AmberTheme.accent)
            }
        case .loaded(let summary):
            summarySection(summary)
        case .failed(let message):
            statusCard(title: "无法读取健康摘要", message: message, systemImage: "exclamationmark.triangle") {
                Button("重试") { Task { await model.load() } }
                    .buttonStyle(.bordered)
                    .tint(AmberTheme.accent)
            }
        }
    }

    private func summarySection(_ summary: IOSHealthStepSummary) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "步数")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("今天")
                            .font(.subheadline)
                            .foregroundStyle(AmberTheme.muted)
                        Text(summary.todayStepCount, format: .number.precision(.fractionLength(0)))
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(AmberTheme.foreground)
                            .contentTransition(.numericText())
                        Text("步")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    }
                    IOSHealthWeekChart(days: summary.days)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
    }

    private func statusCard<Action: View>(
        title: String,
        message: String,
        systemImage: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "状态")
            AmberFormGroup {
                VStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(AmberTheme.accent)
                    VStack(spacing: 5) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(AmberTheme.foreground)
                            .multilineTextAlignment(.center)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(AmberTheme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    action()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
            }
        }
    }

    private func statusCard(
        title: String,
        message: String,
        systemImage: String,
        action: (() -> Void)?
    ) -> some View {
        statusCard(title: title, message: message, systemImage: systemImage) {
            if let action {
                Button("继续", action: action)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct IOSHealthWeekChart: View {
    let days: [IOSHealthDailySteps]

    private var peak: Double {
        Swift.max(days.map(\.stepCount).max() ?? 0, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Capsule(style: .continuous)
                        .fill(AmberTheme.accent.gradient)
                        .frame(height: Swift.max(4, 68 * day.stepCount / peak))
                    Text(weekday(for: day.date))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AmberTheme.muted)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(weekday(for: day.date))，\(Int(day.stepCount.rounded())) 步")
            }
        }
        .frame(minHeight: 92)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("近 7 日步数")
    }

    private func weekday(for date: Date) -> String {
        date.formatted(
            .dateTime
                .weekday(.narrow)
                .locale(IOSAppLanguagePreference.selected().resolvedLocale())
        )
    }
}
