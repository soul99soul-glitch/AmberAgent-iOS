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
                    Text("Amber 只读取步数并在本页临时展示，不会写入健康数据，也不会保存到同步备份或发送给模型。")
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
