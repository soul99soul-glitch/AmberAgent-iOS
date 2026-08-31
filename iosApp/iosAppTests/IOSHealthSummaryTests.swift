import XCTest
@testable import iosApp

@MainActor
final class IOSHealthSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_134_400)

    func testLoadStopsAtExplicitPermissionDisclosure() async {
        let service = HealthSummaryServiceDouble(requirement: .shouldRequest)
        let model = makeModel(service)

        await model.load()

        XCTAssertEqual(model.state, .permissionRequired)
        XCTAssertEqual(service.loadCallCount, 0)
    }

    func testAuthorizationThenLoadsSevenDaySummary() async {
        let summary = makeSummary(counts: [1200, 3200, 0, 4800, 5100, 7600, 8200])
        let service = HealthSummaryServiceDouble(requirement: .shouldRequest, summary: summary)
        let model = makeModel(service)

        await model.requestAccess()

        XCTAssertEqual(service.requestCallCount, 1)
        XCTAssertEqual(service.loadCallCount, 1)
        XCTAssertEqual(model.state, .loaded(summary))
    }

    func testZeroStepQueryUsesHonestEmptyState() async {
        let summary = makeSummary(counts: Array(repeating: 0, count: 7))
        let service = HealthSummaryServiceDouble(requirement: .queryReady, summary: summary)
        let model = makeModel(service)

        await model.load()

        XCTAssertEqual(model.state, .empty(summary))
    }

    func testUnavailableDeviceDoesNotAttemptQuery() async {
        let service = HealthSummaryServiceDouble(requirement: .unavailable)
        let model = makeModel(service)

        await model.load()

        XCTAssertEqual(model.state, .unavailable)
        XCTAssertEqual(service.loadCallCount, 0)
    }

    func testUnconfiguredBuildDoesNotAttemptQuery() async {
        let service = HealthSummaryServiceDouble(requirement: .notConfigured)
        let model = makeModel(service)

        await model.load()

        XCTAssertEqual(model.state, .notConfigured)
        XCTAssertEqual(service.loadCallCount, 0)
    }

    func testTargetEntitlementMirrorSeparatesStableAndExperimentalBuilds() {
        let info: [String: Any] = [
            "AmberAgentConfiguredEntitlements": ["com.apple.developer.healthkit"],
            "AmberAgentExperimentalConfiguredEntitlements": []
        ]

        XCTAssertTrue(IOSHealthSummaryService.currentTargetHasHealthKitEntitlementMirror(
            bundleIdentifier: "app.amber.ios",
            infoDictionary: info
        ))
        XCTAssertFalse(IOSHealthSummaryService.currentTargetHasHealthKitEntitlementMirror(
            bundleIdentifier: "app.amber.ios.experimental-gpl",
            infoDictionary: info
        ))
    }

    func testQueryFailureIsVisibleToUser() async {
        let service = HealthSummaryServiceDouble(requirement: .queryReady)
        service.loadError = HealthSummaryTestError.queryFailed
        let model = makeModel(service)

        await model.load()

        XCTAssertEqual(model.state, .failed("query failed"))
    }

    private func makeModel(_ service: HealthSummaryServiceDouble) -> IOSHealthSummaryViewModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return IOSHealthSummaryViewModel(service: service, now: { self.now }, calendar: calendar)
    }

    private func makeSummary(counts: [Double]) -> IOSHealthStepSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        let days = counts.enumerated().map { index, count in
            IOSHealthDailySteps(
                date: calendar.date(byAdding: .day, value: index - 6, to: today)!,
                stepCount: count
            )
        }
        return IOSHealthStepSummary(days: days)
    }
}

@MainActor
private final class HealthSummaryServiceDouble: IOSHealthSummaryProviding {
    let requirement: IOSHealthAuthorizationRequirement
    var summary: IOSHealthStepSummary
    var loadError: Error?
    private(set) var requestCallCount = 0
    private(set) var loadCallCount = 0

    init(
        requirement: IOSHealthAuthorizationRequirement,
        summary: IOSHealthStepSummary = IOSHealthStepSummary(days: [])
    ) {
        self.requirement = requirement
        self.summary = summary
    }

    func authorizationRequirement() async throws -> IOSHealthAuthorizationRequirement {
        requirement
    }

    func requestAuthorization() async throws {
        requestCallCount += 1
    }

    func loadStepSummary(now: Date, calendar: Calendar) async throws -> IOSHealthStepSummary {
        loadCallCount += 1
        if let loadError { throw loadError }
        return summary
    }
}

private enum HealthSummaryTestError: LocalizedError {
    case queryFailed

    var errorDescription: String? { "query failed" }
}
