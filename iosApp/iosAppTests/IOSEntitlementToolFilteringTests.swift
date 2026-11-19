import XCTest
import Shared
@testable import iosApp

final class IOSEntitlementToolFilteringTests: XCTestCase {
    func testStandardBundleAllowsEntitledAppleToolsAndExperimentalHidesUnentitledOnes() {
        let infoPlist = Bundle.main.infoDictionary ?? [:]

        XCTAssertTrue(IOSSystemPermissionCoordinator.isModelToolEntitled(
            IOSHealthAgentToolCatalog.toolName,
            bundleIdentifier: "app.amber.ios",
            infoDictionary: infoPlist
        ))
        XCTAssertTrue(IOSSystemPermissionCoordinator.isModelToolEntitled(
            IOSWeatherToolCatalog.toolName,
            bundleIdentifier: "app.amber.ios",
            infoDictionary: infoPlist
        ))
        XCTAssertTrue(IOSSystemPermissionCoordinator.isModelToolEntitled(
            IOSAppleAgentToolCatalog.journalingSuggestionPick,
            bundleIdentifier: "app.amber.ios",
            infoDictionary: infoPlist
        ))

        XCTAssertFalse(IOSSystemPermissionCoordinator.isModelToolEntitled(
            IOSHealthAgentToolCatalog.toolName,
            bundleIdentifier: "app.amber.ios.experimental-gpl",
            infoDictionary: infoPlist
        ))
        XCTAssertFalse(IOSSystemPermissionCoordinator.isModelToolEntitled(
            IOSWeatherToolCatalog.toolName,
            bundleIdentifier: "app.amber.ios.experimental-gpl",
            infoDictionary: infoPlist
        ))
        XCTAssertFalse(IOSSystemPermissionCoordinator.isModelToolEntitled(
            IOSAppleAgentToolCatalog.journalingSuggestionPick,
            bundleIdentifier: "app.amber.ios.experimental-gpl",
            infoDictionary: infoPlist
        ))

        XCTAssertTrue(IOSSystemPermissionCoordinator.isModelToolEntitled(
            IOSAppleAgentToolCatalog.calendarEventsList,
            bundleIdentifier: "app.amber.ios.experimental-gpl",
            infoDictionary: infoPlist
        ))
        XCTAssertTrue(IOSSystemPermissionCoordinator.isModelToolEntitled(
            IOSAppleAgentToolCatalog.remindersList,
            bundleIdentifier: "app.amber.ios.experimental-gpl",
            infoDictionary: infoPlist
        ))
    }

    @MainActor
    func testGenerationBuilderHidesEntitlementMissingToolsFromModelCatalog() {
        let suiteName = "entitlement-filter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(
                userDefaults: defaults,
                storageKey: "entitlement-filter-settings"
            ),
            autoGenerateResponses: false
        )
        let infoPlist = Bundle.main.infoDictionary ?? [:]

        let experimentalTools = Set(viewModel.enabledModelToolNames(
            IOSAppleAgentToolCatalog.toolNames,
            bundleIdentifier: "app.amber.ios.experimental-gpl",
            infoDictionary: infoPlist
        ))
        XCTAssertFalse(experimentalTools.contains(IOSHealthAgentToolCatalog.toolName))
        XCTAssertFalse(experimentalTools.contains(IOSWeatherToolCatalog.toolName))
        XCTAssertFalse(experimentalTools.contains(IOSAppleAgentToolCatalog.journalingSuggestionPick))
        XCTAssertTrue(experimentalTools.contains(IOSAppleAgentToolCatalog.calendarEventsList))
    }

    func testExperimentalProjectYmlWatchAppGroupMatchesExperimentalBundleVariable() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectYml = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(
            projectYml.contains("AMBER_WATCH_APP_GROUP_IDENTIFIER: \"group.$(AMBER_EXPERIMENTAL_BUNDLE_IDENTIFIER).watchkit\""),
            "Watch App Group must derive from AMBER_EXPERIMENTAL_BUNDLE_IDENTIFIER"
        )
    }
}
