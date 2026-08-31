import Foundation
import Testing
@testable import iosApp

@MainActor
private final class FakeWeatherService: IOSWeatherProviding {
    var namedResult: Result<IOSWeatherSnapshot, Error>
    var currentResult: Result<IOSWeatherSnapshot, Error>
    private(set) var namedQueries: [String] = []

    init(
        namedResult: Result<IOSWeatherSnapshot, Error>,
        currentResult: Result<IOSWeatherSnapshot, Error>? = nil
    ) {
        self.namedResult = namedResult
        self.currentResult = currentResult ?? namedResult
    }

    func weather(namedLocation query: String) async throws -> IOSWeatherSnapshot {
        namedQueries.append(query)
        return try namedResult.get()
    }

    func weatherAtCurrentLocation() async throws -> IOSWeatherSnapshot {
        try currentResult.get()
    }
}

@MainActor
private final class ControlledWeatherService: IOSWeatherProviding {
    private var continuation: CheckedContinuation<IOSWeatherSnapshot, Error>?

    func weather(namedLocation query: String) async throws -> IOSWeatherSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func weatherAtCurrentLocation() async throws -> IOSWeatherSnapshot {
        throw IOSWeatherError.locationUnavailable
    }

    func finishNamed(with snapshot: IOSWeatherSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

@Suite("WeatherKit surface")
@MainActor
struct IOSWeatherTests {
    @Test func entitlementMirrorSeparatesStableAndExperimentalTargets() {
        let info = [
            "AmberAgentConfiguredEntitlements": ["com.apple.developer.weatherkit"],
            "AmberAgentExperimentalConfiguredEntitlements": []
        ]
        #expect(IOSWeatherService.currentTargetHasWeatherKitEntitlementMirror(
            bundleIdentifier: "app.amber.ios",
            infoDictionary: info
        ))
        #expect(!IOSWeatherService.currentTargetHasWeatherKitEntitlementMirror(
            bundleIdentifier: "app.amber.ios.experimental-gpl",
            infoDictionary: info
        ))
    }

    @Test func namedLocationDoesNotUseCurrentLocationPath() async {
        let snapshot = Self.snapshot()
        let service = FakeWeatherService(
            namedResult: .success(snapshot),
            currentResult: .failure(IOSWeatherError.locationPermissionDenied)
        )
        let model = IOSWeatherViewModel(service: service)
        model.query = "上海"
        await model.search()
        #expect(model.state == .loaded(snapshot))
        #expect(service.namedQueries == ["上海"])
    }

    @Test func currentLocationDenialHasDedicatedUIState() async {
        let service = FakeWeatherService(
            namedResult: .success(Self.snapshot()),
            currentResult: .failure(IOSWeatherError.locationPermissionDenied)
        )
        let model = IOSWeatherViewModel(service: service)
        await model.loadCurrentLocation()
        #expect(model.state == .locationPermissionDenied)
    }

    @Test func emptySubmissionInvalidatesAnOlderInFlightQuery() async {
        let service = ControlledWeatherService()
        let model = IOSWeatherViewModel(service: service)
        model.query = "上海"
        let older = Task { await model.search() }
        await Task.yield()

        model.query = ""
        await model.search()
        service.finishNamed(with: Self.snapshot())
        await older.value

        #expect(model.state == .failed(IOSWeatherError.emptyLocation.localizedDescription))
    }

    @Test func toolRejectsAmbiguousInputAndReturnsBoundedForecast() async throws {
        let service = FakeWeatherService(namedResult: .success(Self.snapshot()))
        let invalid = await IOSWeatherToolExecutor.execute(
            input: #"{"location":"上海","use_current_location":true}"#,
            service: service
        )
        #expect(invalid.contains(#""ok":false"#))
        #expect(IOSWeatherToolExecutor.requestsCurrentLocation(
            input: #"{"use_current_location":true}"#
        ))

        let valid = await IOSWeatherToolExecutor.execute(
            input: #"{"location":"上海"}"#,
            service: service
        )
        let data = try #require(valid.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        #expect((object["forecast"] as? [[String: Any]])?.count == 1)
    }

    private static func snapshot() -> IOSWeatherSnapshot {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        return IOSWeatherSnapshot(
            locationName: "上海市",
            temperatureCelsius: 26,
            apparentTemperatureCelsius: 27,
            humidity: 0.6,
            condition: "晴",
            symbolName: "sun.max.fill",
            observedAt: date,
            days: [IOSWeatherDay(
                date: date,
                symbolName: "sun.max.fill",
                condition: "晴",
                highCelsius: 29,
                lowCelsius: 21,
                precipitationChance: 0.1
            )],
            attribution: IOSWeatherAttributionInfo(
                serviceName: "Apple Weather",
                legalPageURL: URL(string: "https://weather.apple.com/legal-attribution.html")!,
                combinedMarkDarkURL: URL(string: "https://example.com/dark.svg")!,
                combinedMarkLightURL: URL(string: "https://example.com/light.svg")!,
                legalText: "Weather data provided by Apple Weather"
            )
        )
    }
}
