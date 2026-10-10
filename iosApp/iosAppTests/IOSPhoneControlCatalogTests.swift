import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSPhoneControlCatalogTests: XCTestCase {
    func testForegroundCatalogIncludesVisiblePhoneToolsOnlyForGrantedUserTurn() async throws {
        let suite = "PhoneCatalog-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = IOSPhoneControlController(defaults: defaults, credentials: CatalogPairingStore())
        await controller.refreshPreparation()
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(userDefaults: defaults, storageKey: "phone-catalog-settings"),
            sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
            autoGenerateResponses: false,
            phoneControl: controller
        )
        let ungranted = viewModel.textGenerationParamsForTesting(includePhoneControlTools: true)
        var bridge = try XCTUnwrap(viewModel.toolExposureBridgeForTesting())
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: Set(bridge.fullToolDeclarations().map(\.name))))
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: Set(ungranted.tools.map(\.name))))

        controller.enabled = true
        controller.selectedBundleIDs = ["app.example.target"]
        try controller.authorizeNextTask(durationSeconds: 300)
        let granted = viewModel.textGenerationParamsForTesting(includePhoneControlTools: true)
        bridge = try XCTUnwrap(viewModel.toolExposureBridgeForTesting())
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isSubset(of: Set(bridge.fullToolDeclarations().map(\.name))))
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isSubset(of: Set(granted.tools.map(\.name))))

        let automatic = viewModel.textGenerationParamsForTesting()
        bridge = try XCTUnwrap(viewModel.toolExposureBridgeForTesting())
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: Set(bridge.fullToolDeclarations().map(\.name))))
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: Set(automatic.tools.map(\.name))))
        XCTAssertTrue(controller.hasPendingAuthorization, "Automatic assembly must not consume the authorization window")
        controller.discardPendingAuthorization()
        let revoked = viewModel.textGenerationParamsForTesting(includePhoneControlTools: true)
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: Set(revoked.tools.map(\.name))))
    }

    func testBackgroundRebuildKeepsFrozenPhoneSchemaAndDoesNotAddNewGrantTools() {
        let frozenNames = ["runtime_status", "phone_observe", "phone_act"]
        let declarations = IOSPhoneControlToolCatalog.declarations.filter { frozenNames.contains($0.name) }
        let bridge = IOSChatBackgroundGenerationCoordinator.makeBackgroundToolExposureBridge(
            fullToolNames: frozenNames,
            handoffVisibleTools: declarations,
            additionalDeclarations: declarations
        )
        XCTAssertEqual(Set(bridge.fullToolDeclarations().map(\.name)), Set(frozenNames).union(["tool_search"]))
        let action = bridge.fullToolDeclarations().first { $0.name == "phone_act" }
        XCTAssertTrue(action?.parametersJsonSchema()?.contains("bundle_id") == true)
        XCTAssertTrue(action?.parametersJsonSchema()?.contains("swipe") == true)

        let ungranted = IOSChatBackgroundGenerationCoordinator.makeBackgroundToolExposureBridge(
            fullToolNames: ["runtime_status"],
            handoffVisibleTools: []
        )
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: Set(ungranted.fullToolDeclarations().map(\.name))))
    }

    func testObservationIsReadOnlyAndActionsStayOutOfNestedReplayPaths() {
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("phone_status", input: "{}"), .pure)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("phone_observe", input: "{}"), .pure)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("phone_act", input: "{}"), .sideEffect)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("phone_stop", input: "{}"), .sideEffect)
        XCTAssertTrue(ChatToolRuntime.execNestedToolWhitelist(visibleToolNames: IOSPhoneControlToolCatalog.toolNames).isEmpty)
    }
}

private actor CatalogPairingStore: IOSPhoneControlCredentialStoring {
    func loadPairing() -> Data? { Data([1]) }
    func savePairing(_ data: Data) { }
    func deletePairing() { }
}
