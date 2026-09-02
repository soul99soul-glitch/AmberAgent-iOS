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

    func testHealthAgentToolReturnsBoundedSummaryAfterExplicitAuthorization() async throws {
        let service = HealthAgentSummaryServiceDouble(summary: IOSHealthAgentSummary(
            days: [IOSHealthAgentDailySummary(
                date: now,
                steps: 8_200,
                activeEnergyKilocalories: 430,
                exerciseMinutes: 35,
                sleepHours: 7.5
            )],
            workouts: []
        ))

        let output = await IOSHealthAgentToolExecutor.execute(
            input: #"{"days":7,"include_workouts":false,"display_title":"分析健康摘要"}"#,
            service: service
        )
        let data = try XCTUnwrap(output.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual((object["days"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(service.authorizationCallCount, 1)
        XCTAssertEqual(service.requestedDays, 7)
        XCTAssertFalse(service.requestedWorkouts)
    }

    func testHealthAgentToolRejectsUnknownArgumentsBeforeRequestingHealthAccess() async {
        let service = HealthAgentSummaryServiceDouble(summary: IOSHealthAgentSummary(days: [], workouts: []))

        let output = await IOSHealthAgentToolExecutor.execute(
            input: #"{"days":7,"raw_samples":true}"#,
            service: service
        )

        XCTAssertTrue(output.contains(#""ok":false"#))
        XCTAssertEqual(service.authorizationCallCount, 0)
    }

    func testHealthAgentToolRejectsWrongTypesBeforeRequestingHealthAccess() async {
        let service = HealthAgentSummaryServiceDouble(summary: IOSHealthAgentSummary(days: [], workouts: []))

        for input in [
            #"{"days":"1","include_workouts":"false"}"#,
            #"{"days":7,"include_workouts":1}"#,
        ] {
            let output = await IOSHealthAgentToolExecutor.execute(input: input, service: service)
            XCTAssertTrue(output.contains(#""ok":false"#))
        }

        XCTAssertEqual(service.authorizationCallCount, 0)
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
private final class HealthAgentSummaryServiceDouble: IOSHealthAgentSummaryProviding {
    let summary: IOSHealthAgentSummary
    private(set) var authorizationCallCount = 0
    private(set) var requestedDays = 0
    private(set) var requestedWorkouts = false

    init(summary: IOSHealthAgentSummary) {
        self.summary = summary
    }

    func requestAuthorization() async throws {
        authorizationCallCount += 1
    }

    func loadSummary(
        days: Int,
        includeWorkouts: Bool,
        now: Date,
        calendar: Calendar
    ) async throws -> IOSHealthAgentSummary {
        requestedDays = days
        requestedWorkouts = includeWorkouts
        return summary
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
