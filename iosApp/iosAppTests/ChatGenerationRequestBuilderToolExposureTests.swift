import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatGenerationRequestBuilderToolExposureTests: XCTestCase {
    func testFirstRoundPassthroughCapsAtSixRespectsAvailableFilterAndUsesWeatherReadCatalogName() {
        let prompt = "查一下今天天气和温度，看看日历会议安排、提醒待办、健康步数、工作区文件和手机控制准备度"
        let user = UIMessage.companion.user(prompt: prompt)

        let fullCatalog: Set<String> = [
            IOSWeatherToolCatalog.toolName,
            IOSAppleAgentToolCatalog.calendarEventsList,
            IOSAppleAgentToolCatalog.calendarEventCreate,
            IOSAppleAgentToolCatalog.calendarEventUpdate,
            IOSAppleAgentToolCatalog.remindersList,
            IOSAppleAgentToolCatalog.reminderCreate,
            IOSAppleAgentToolCatalog.reminderComplete,
            IOSHealthAgentToolCatalog.toolName,
            IOSPhoneControlToolCatalog.preflightToolName,
            "workspace_list",
            "workspace_read"
        ]
        let selected = ChatViewModel.firstRoundPassthroughToolNames(
            for: [user],
            availableToolNames: fullCatalog
        )
        XCTAssertEqual(selected.count, 6)
        XCTAssertEqual(Set(selected).count, 6)
        XCTAssertTrue(selected.contains(IOSWeatherToolCatalog.toolName))
        XCTAssertTrue(selected.contains(IOSAppleAgentToolCatalog.calendarEventsList))

        // Filtered capability/entitlement catalog never leaks unavailable tools.
        let unentitledCatalog: Set<String> = [
            IOSAppleAgentToolCatalog.calendarEventsList,
            IOSPhoneControlToolCatalog.preflightToolName
        ]
        let weatherAndHealthOnly = UIMessage.companion.user(prompt: "查天气和健康步数，再看日程和手机控制")
        let filtered = ChatViewModel.firstRoundPassthroughToolNames(
            for: [weatherAndHealthOnly],
            availableToolNames: unentitledCatalog
        )
        XCTAssertEqual(filtered, [
            IOSAppleAgentToolCatalog.calendarEventsList,
            IOSPhoneControlToolCatalog.preflightToolName
        ])
        XCTAssertFalse(filtered.contains(IOSWeatherToolCatalog.toolName))
        XCTAssertFalse(filtered.contains(IOSHealthAgentToolCatalog.toolName))
    }

    func testRealRequestBuilderExposesMatchedToolsWithoutWeakeningApprovals() {
        let suiteName = "passthrough-builder-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(
                userDefaults: defaults,
                storageKey: "passthrough-builder-settings"
            ),
            autoGenerateResponses: false
        )
        let runState = ChatConversationRunState(conversationId: nil)
        runState.messages = [UIMessage.companion.user(prompt: "检查手机控制为什么不能用，并看看今天天气")]
        let params = viewModel.makeTextGenerationParams(
            includePhoneControlTools: false,
            state: runState
        )
        let exposedNames = Set(params.tools.map(\.name))

        // preflight is always declarable read-only and exposed by user intent on Round 0
        XCTAssertTrue(exposedNames.contains(IOSPhoneControlToolCatalog.preflightToolName))
        // Approvals remain strictly untouched
        XCTAssertTrue(IOSAppleAgentToolCatalog.approvalRequiredToolNames.contains(IOSAppleAgentToolCatalog.calendarEventCreate))
        XCTAssertFalse(IOSAppleAgentToolCatalog.approvalRequiredToolNames.contains(IOSWeatherToolCatalog.toolName))

        // Phone control deep link round-trip
        let parsed = IOSAppDeepLink.parse(URL(string: "amber://settings/phone-control")!)
        XCTAssertEqual(parsed, .phoneControl)
        XCTAssertEqual(IOSAppDeepLink.url(for: .phoneControl)?.absoluteString, "amber://settings/phone-control")
    }
}
