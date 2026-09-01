@preconcurrency import CoreLocation
import Foundation
import MapKit
import Observation
import SwiftUI
import WeatherKit

struct IOSWeatherDay: Identifiable, Equatable, Sendable {
    let date: Date
    let symbolName: String
    let condition: String
    let highCelsius: Double
    let lowCelsius: Double
    let precipitationChance: Double

    var id: Date { date }
}

struct IOSWeatherAttributionInfo: Equatable, Sendable {
    let serviceName: String
    let legalPageURL: URL
    let combinedMarkDarkURL: URL
    let combinedMarkLightURL: URL
    let legalText: String
}

struct IOSWeatherSnapshot: Equatable, Sendable {
    let locationName: String
    let temperatureCelsius: Double
    let apparentTemperatureCelsius: Double
    let humidity: Double
    let condition: String
    let symbolName: String
    let observedAt: Date
    let days: [IOSWeatherDay]
    let attribution: IOSWeatherAttributionInfo
}

@MainActor
protocol IOSWeatherProviding: AnyObject {
    func weather(namedLocation query: String) async throws -> IOSWeatherSnapshot
    func weatherAtCurrentLocation() async throws -> IOSWeatherSnapshot
}

enum IOSWeatherError: LocalizedError, Equatable {
    case notConfigured
    case emptyLocation
    case locationNotFound
    case locationPermissionDenied
    case locationUnavailable
    case locationRequestInProgress
    case invalidToolInput

    var errorDescription: String? {
        switch self {
        case .notConfigured: "此构建未配置 WeatherKit。"
        case .emptyLocation: "请输入城市或地点。"
        case .locationNotFound: "没有找到这个地点，请换一个更具体的名称。"
        case .locationPermissionDenied: "当前位置权限未开启。仍可直接搜索城市天气。"
        case .locationUnavailable: "暂时无法获取当前位置。"
        case .locationRequestInProgress: "正在获取当前位置，请稍候。"
        case .invalidToolInput: "天气工具参数无效：请提供 location，或将 use_current_location 设为 true。"
        }
    }
}

@MainActor
final class IOSCurrentLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var continuation: CheckedContinuation<CLLocation, Error>?

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func location() async throws -> CLLocation {
        guard continuation == nil else { throw IOSWeatherError.locationRequestInProgress }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                finish(.failure(IOSWeatherError.locationPermissionDenied))
            @unknown default:
                finish(.failure(IOSWeatherError.locationUnavailable))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(IOSWeatherError.locationPermissionDenied))
        case .notDetermined:
            break
        @unknown default:
            finish(.failure(IOSWeatherError.locationUnavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(.failure(IOSWeatherError.locationUnavailable))
            return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        manager.stopUpdatingLocation()
        continuation.resume(with: result)
    }
}

@MainActor
final class IOSWeatherService: IOSWeatherProviding {
    static let shared = IOSWeatherService()

    private let weatherService: WeatherService
    private let locationProvider: IOSCurrentLocationProvider
    private let isConfigured: Bool

    init(
        weatherService: WeatherService = .shared,
        locationProvider: IOSCurrentLocationProvider = IOSCurrentLocationProvider(),
        isConfigured: Bool? = nil
    ) {
        self.weatherService = weatherService
        self.locationProvider = locationProvider
        self.isConfigured = isConfigured ?? Self.currentTargetHasWeatherKitEntitlementMirror()
    }

    func weather(namedLocation query: String) async throws -> IOSWeatherSnapshot {
        try ensureConfigured()
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IOSWeatherError.emptyLocation }
        guard clean.count <= 80 else { throw IOSWeatherError.locationNotFound }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = clean
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw IOSWeatherError.locationNotFound }
        let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await snapshot(
            location: item.location,
            locationName: name?.isEmpty == false ? name! : clean
        )
    }

    func weatherAtCurrentLocation() async throws -> IOSWeatherSnapshot {
        try ensureConfigured()
        let location = try await locationProvider.location()
        return try await snapshot(location: location, locationName: "当前位置")
    }

    private func ensureConfigured() throws {
        guard isConfigured else { throw IOSWeatherError.notConfigured }
    }

    private func snapshot(location: CLLocation, locationName: String) async throws -> IOSWeatherSnapshot {
        async let weather = weatherService.weather(for: location, including: .current, .daily)
        async let attribution = weatherService.attribution
        let ((current, daily), attributionValue) = try await (weather, attribution)
        return IOSWeatherSnapshot(
            locationName: locationName,
            temperatureCelsius: current.temperature.converted(to: .celsius).value,
            apparentTemperatureCelsius: current.apparentTemperature.converted(to: .celsius).value,
            humidity: current.humidity,
            condition: current.condition.description,
            symbolName: current.symbolName,
            observedAt: current.date,
            days: daily.forecast.prefix(5).map { day in
                IOSWeatherDay(
                    date: day.date,
                    symbolName: day.symbolName,
                    condition: day.condition.description,
                    highCelsius: day.highTemperature.converted(to: .celsius).value,
                    lowCelsius: day.lowTemperature.converted(to: .celsius).value,
                    precipitationChance: day.precipitationChance
                )
            },
            attribution: IOSWeatherAttributionInfo(
                serviceName: attributionValue.serviceName,
                legalPageURL: attributionValue.legalPageURL,
                combinedMarkDarkURL: attributionValue.combinedMarkDarkURL,
                combinedMarkLightURL: attributionValue.combinedMarkLightURL,
                legalText: attributionValue.legalAttributionText
            )
        )
    }

    static func currentTargetHasWeatherKitEntitlementMirror(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> Bool {
        let key = bundleIdentifier?.hasSuffix(".experimental-gpl") == true
            ? "AmberAgentExperimentalConfiguredEntitlements"
            : "AmberAgentConfiguredEntitlements"
        let configured = infoDictionary?[key] as? [String] ?? []
        return configured.contains("com.apple.developer.weatherkit")
    }
}

@MainActor
@Observable
final class IOSWeatherViewModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded(IOSWeatherSnapshot)
        case notConfigured
        case locationPermissionDenied
        case failed(String)
    }

    var query = ""
    private(set) var state: State = .idle
    @ObservationIgnored private let service: any IOSWeatherProviding
    @ObservationIgnored private var activeRequestID: UUID?

    init(service: any IOSWeatherProviding = IOSWeatherService.shared) {
        self.service = service
    }

    func search() async {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            activeRequestID = nil
            state = .failed(IOSWeatherError.emptyLocation.localizedDescription)
            return
        }
        await load { try await service.weather(namedLocation: clean) }
    }

    func loadCurrentLocation() async {
        await load { try await service.weatherAtCurrentLocation() }
    }

    private func load(_ operation: () async throws -> IOSWeatherSnapshot) async {
        let requestID = UUID()
        activeRequestID = requestID
        state = .loading
        do {
            let snapshot = try await operation()
            guard activeRequestID == requestID else { return }
            state = .loaded(snapshot)
        } catch IOSWeatherError.notConfigured {
            guard activeRequestID == requestID else { return }
            state = .notConfigured
        } catch IOSWeatherError.locationPermissionDenied {
            guard activeRequestID == requestID else { return }
            state = .locationPermissionDenied
        } catch {
            guard activeRequestID == requestID else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

@MainActor
struct IOSWeatherView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: IOSWeatherViewModel

    init(model: IOSWeatherViewModel = IOSWeatherViewModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        searchSection
                        stateSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer()
            Text("天气")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var searchSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "地点")
            AmberFormGroup {
                VStack(spacing: 12) {
                    weatherSearchControls

                    Divider().overlay(AmberTheme.borderSoft)

                    Button {
                        Task { await model.loadCurrentLocation() }
                    } label: {
                        Label("使用当前位置", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(AmberTheme.accent)
                    .disabled(model.state == .loading)

                    Text("搜索城市不需要位置权限；只有点按“使用当前位置”才会向系统申请。")
                        .font(.caption)
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
    private var weatherSearchControls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                weatherSearchField
                Button("查询") { Task { await model.search() } }
                    .buttonStyle(.borderedProminent)
                    .tint(AmberTheme.accent)
                    .frame(maxWidth: .infinity)
                    .disabled(model.state == .loading)
            }
        } else {
            HStack(spacing: 10) {
                weatherSearchField
                Button("查询") { Task { await model.search() } }
                    .buttonStyle(.borderedProminent)
                    .tint(AmberTheme.accent)
                    .disabled(model.state == .loading)
            }
        }
    }

    private var weatherSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AmberTheme.muted)
            TextField("城市或地点", text: $model.query)
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .onSubmit { Task { await model.search() } }
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch model.state {
        case .idle:
            weatherStatus(title: "查询当地天气", message: "输入城市，或在需要时使用当前位置。", icon: "cloud.sun")
        case .loading:
            weatherStatus(title: "正在获取天气", message: "WeatherKit 正在读取最新预报。", icon: "cloud.sun") {
                ProgressView().tint(AmberTheme.accent)
            }
        case .notConfigured:
            weatherStatus(title: "此构建未启用 WeatherKit", message: "需要在稳定版 App ID 与签名配置中启用 WeatherKit。", icon: "cloud.slash")
        case .locationPermissionDenied:
            weatherStatus(title: "当前位置不可用", message: "可以继续搜索城市；如需当前位置，请在系统设置中允许 Amber 使用位置。", icon: "location.slash") {
                Button("打开 Amber 设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .tint(AmberTheme.accent)
            }
        case .failed(let message):
            weatherStatus(title: "无法获取天气", message: message, icon: "exclamationmark.triangle")
        case .loaded(let snapshot):
            weatherSnapshot(snapshot)
        }
    }

    private func weatherSnapshot(_ snapshot: IOSWeatherSnapshot) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "当前天气")
            AmberFormGroup {
                currentWeatherContent(snapshot)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }

            AmberSectionLabel(text: "未来 5 日")
            AmberFormGroup {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.days.enumerated()), id: \.element.id) { index, day in
                        weatherDayRow(day)
                        if index < snapshot.days.count - 1 {
                            Divider().overlay(AmberTheme.borderSoft).padding(.leading, 50)
                        }
                    }
                }
            }

            AmberSectionLabel(text: "数据来源")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        AsyncImage(url: colorScheme == .dark
                            ? snapshot.attribution.combinedMarkDarkURL
                            : snapshot.attribution.combinedMarkLightURL) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit()
                            } else {
                                Text(snapshot.attribution.serviceName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AmberTheme.foreground)
                            }
                        }
                        .frame(maxWidth: 130, minHeight: 28, maxHeight: 34, alignment: .leading)
                        .accessibilityLabel("\(snapshot.attribution.serviceName) 标志")

                        Spacer(minLength: 8)
                        Link("法律与归属", destination: snapshot.attribution.legalPageURL)
                            .font(.caption.weight(.semibold))
                    }
                    Text(snapshot.attribution.legalText)
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .accessibilityElement(children: .contain)
            }
        }
    }

    @ViewBuilder
    private func currentWeatherContent(_ snapshot: IOSWeatherSnapshot) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    currentWeatherIcon(snapshot)
                    currentWeatherPlace(snapshot)
                }
                currentWeatherMeasurements(snapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 16) {
                currentWeatherIcon(snapshot)
                currentWeatherPlace(snapshot)
                currentWeatherMeasurements(snapshot)
            }
        }
    }

    private func currentWeatherIcon(_ snapshot: IOSWeatherSnapshot) -> some View {
        Image(systemName: snapshot.symbolName)
            .font(.system(size: 42, weight: .medium))
            .symbolRenderingMode(.multicolor)
            .frame(width: 58, height: 58)
    }

    private func currentWeatherPlace(_ snapshot: IOSWeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.locationName)
                .font(.headline)
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(2)
            Text(snapshot.condition)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func currentWeatherMeasurements(_ snapshot: IOSWeatherSnapshot) -> some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
            Text("\(snapshot.temperatureCelsius, specifier: "%.0f")°")
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .foregroundStyle(AmberTheme.foreground)
            Text("体感 \(snapshot.apparentTemperatureCelsius, specifier: "%.0f")° · 湿度 \(snapshot.humidity * 100, specifier: "%.0f")%")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func weatherDayRow(_ day: IOSWeatherDay) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.subheadline.weight(.medium))
                    Image(systemName: day.symbolName)
                        .symbolRenderingMode(.multicolor)
                    Spacer(minLength: 8)
                    Text("\(day.lowCelsius, specifier: "%.0f")° / \(day.highCelsius, specifier: "%.0f")°")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(AmberTheme.foreground)
                        .fixedSize()
                }
                Text(day.condition)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            HStack(spacing: 12) {
                Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.subheadline.weight(.medium))
                    .frame(width: 44, alignment: .leading)
                Image(systemName: day.symbolName)
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 28)
                Text(day.condition)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(day.lowCelsius, specifier: "%.0f")° / \(day.highCelsius, specifier: "%.0f")°")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
            }
            .frame(minHeight: 48)
            .padding(.horizontal, 14)
        }
    }

    private func weatherStatus<Accessory: View>(
        title: String,
        message: String,
        icon: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "天气")
            AmberFormGroup {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.headline).foregroundStyle(AmberTheme.foreground)
                        Text(message).font(.subheadline).foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        accessory().padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }

    private func weatherStatus(title: String, message: String, icon: String) -> some View {
        weatherStatus(title: title, message: message, icon: icon) { EmptyView() }
    }
}

enum IOSWeatherToolCatalog {
    static let toolName = "weather_read"
}

@MainActor
enum IOSWeatherToolExecutor {
    static func requestsCurrentLocation(input: String) -> Bool {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["use_current_location"] as? Bool == true
    }

    static func execute(
        input: String,
        service: any IOSWeatherProviding = IOSWeatherService.shared
    ) async -> String {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["location", "use_current_location", "display_title"]) else {
            return failure(IOSWeatherError.invalidToolInput.localizedDescription)
        }
        let location = (object["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = object["use_current_location"] as? Bool ?? false
        guard (current && location?.isEmpty != false) || (!current && location?.isEmpty == false) else {
            return failure(IOSWeatherError.invalidToolInput.localizedDescription)
        }
        do {
            let snapshot = current
                ? try await service.weatherAtCurrentLocation()
                : try await service.weather(namedLocation: location!)
            return json(snapshot)
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private static func json(_ snapshot: IOSWeatherSnapshot) -> String {
        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "ok": true,
            "tool": IOSWeatherToolCatalog.toolName,
            "location": snapshot.locationName,
            "temperature_celsius": snapshot.temperatureCelsius,
            "apparent_temperature_celsius": snapshot.apparentTemperatureCelsius,
            "humidity_percent": snapshot.humidity * 100,
            "condition": snapshot.condition,
            "observed_at": formatter.string(from: snapshot.observedAt),
            "forecast": snapshot.days.map { day in
                [
                    "date": formatter.string(from: day.date),
                    "condition": day.condition,
                    "high_celsius": day.highCelsius,
                    "low_celsius": day.lowCelsius,
                    "precipitation_chance_percent": day.precipitationChance * 100
                ] as [String: Any]
            },
            "attribution": [
                "service": snapshot.attribution.serviceName,
                "legal_url": snapshot.attribution.legalPageURL.absoluteString,
                "legal_text": snapshot.attribution.legalText
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return failure("无法编码天气结果。")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func failure(_ reason: String) -> String {
        let payload: [String: Any] = [
            "ok": false,
            "tool": IOSWeatherToolCatalog.toolName,
            "status": "failed",
            "reason": reason
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
