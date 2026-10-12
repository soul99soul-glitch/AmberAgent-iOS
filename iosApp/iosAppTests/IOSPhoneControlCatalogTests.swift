import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSPhoneControlCatalogTests: XCTestCase {
    func testForegroundCatalogIncludesPhoneToolsForEnabledUserTurnWithoutPreparation() async throws {
        let suite = "PhoneCatalog-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = IOSPhoneControlController(defaults: defaults, credentials: CatalogPairingStore())
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
        XCTAssertTrue(controller.selectedBundleIDs.isEmpty)
        XCTAssertFalse(controller.hasPreparedPairing)
        let granted = viewModel.textGenerationParamsForTesting(includePhoneControlTools: true)
        bridge = try XCTUnwrap(viewModel.toolExposureBridgeForTesting())
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isSubset(of: Set(bridge.fullToolDeclarations().map(\.name))))
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isSubset(of: Set(granted.tools.map(\.name))))
        XCTAssertTrue(granted.tools.contains { $0.name == "phone_run_goal" },
                      "Jev 手机目标工具必须通过真实前台目录暴露")
        let goal = try XCTUnwrap(bridge.fullToolDeclarations().first { $0.name == "phone_run_goal" })
        try assertGoalSchema(goal)

        let automatic = viewModel.textGenerationParamsForTesting()
        bridge = try XCTUnwrap(viewModel.toolExposureBridgeForTesting())
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: Set(bridge.fullToolDeclarations().map(\.name))))
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: Set(automatic.tools.map(\.name))))
        XCTAssertTrue(controller.enabled, "Automatic assembly must not change the persisted switch")
        XCTAssertNil(controller.ownerRunID, "Catalog assembly must not claim a control run")
        controller.enabled = false
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
        XCTAssertTrue(action?.parametersJsonSchema()?.contains("tap_point") == true)
        XCTAssertTrue(action?.parametersJsonSchema()?.contains("swipe_point") == true)
        XCTAssertTrue(action?.parametersJsonSchema()?.contains("end_x") == true)
        XCTAssertTrue(action?.parametersJsonSchema()?.contains("end_y") == true)
        XCTAssertTrue(action?.parametersJsonSchema()?.contains("observation_id") == true)
        XCTAssertTrue(action?.parametersJsonSchema()?.contains("expectation") == true)
        XCTAssertFalse(bridge.fullToolDeclarations().contains { $0.name == "phone_run_goal" })

        let oldRunWithNewCatalog = IOSChatBackgroundGenerationCoordinator.makeBackgroundToolExposureBridge(
            fullToolNames: frozenNames,
            handoffVisibleTools: declarations,
            additionalDeclarations: IOSPhoneControlToolCatalog.declarations.filter { frozenNames.contains($0.name) }
        )
        XCTAssertFalse(oldRunWithNewCatalog.fullToolDeclarations().contains { $0.name == "phone_run_goal" },
                       "新版本的完整目录不能给冻结的旧run追加手机目标工具")

        let ungranted = IOSChatBackgroundGenerationCoordinator.makeBackgroundToolExposureBridge(
            fullToolNames: ["runtime_status"],
            handoffVisibleTools: []
        )
        XCTAssertTrue(IOSPhoneControlToolCatalog.toolNames.isDisjoint(with: Set(ungranted.fullToolDeclarations().map(\.name))))
    }

    func testBackgroundRebuildPreservesNewGoalToolAndItsCompletionSchema() throws {
        let goal = try XCTUnwrap(IOSPhoneControlToolCatalog.declarations.first { $0.name == "phone_run_goal" })
        let frozenNames = ["runtime_status", "phone_observe", "phone_run_goal"]
        let bridge = IOSChatBackgroundGenerationCoordinator.makeBackgroundToolExposureBridge(
            fullToolNames: frozenNames,
            handoffVisibleTools: [goal],
            additionalDeclarations: IOSPhoneControlToolCatalog.declarations.filter { frozenNames.contains($0.name) }
        )
        let restored = try XCTUnwrap(bridge.fullToolDeclarations().first { $0.name == "phone_run_goal" })
        XCTAssertEqual(restored.parametersJsonSchema(), goal.parametersJsonSchema())
        try assertGoalSchema(restored)
        XCTAssertFalse(bridge.fullToolDeclarations().contains { $0.name == "phone_act" })
    }

    func testObservationIsReadOnlyAndActionsStayOutOfNestedReplayPaths() {
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("phone_status", input: "{}"), .pure)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("phone_observe", input: "{}"), .pure)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("phone_apps", input: "{}"), .pure)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("phone_add_app", input: "{}"), .sideEffect)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("phone_act", input: "{}"), .sideEffect)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("phone_run_goal", input: "{}"), .sideEffect)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("phone_scroll_until", input: "{}"), .sideEffect)
        XCTAssertEqual(IOSToolEffectClassMapping.forToolName("phone_stop", input: "{}"), .sideEffect)
        XCTAssertTrue(ChatToolRuntime.execNestedToolWhitelist(visibleToolNames: IOSPhoneControlToolCatalog.toolNames).isEmpty)
    }

    func testScrollSearchIsPreservedByFrozenBackgroundCatalog() throws {
        let tool = try XCTUnwrap(IOSPhoneControlToolCatalog.declarations.first { $0.name == "phone_scroll_until" })
        let bridge = IOSChatBackgroundGenerationCoordinator.makeBackgroundToolExposureBridge(
            fullToolNames: [tool.name], handoffVisibleTools: [tool], additionalDeclarations: [tool])
        let restored = try XCTUnwrap(bridge.fullToolDeclarations().first { $0.name == tool.name })
        XCTAssertEqual(restored.parametersJsonSchema(), tool.parametersJsonSchema())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(tool.parametersJsonSchema()).utf8)) as? [String: Any])
        XCTAssertEqual(Set(object["required"] as? [String] ?? []), ["target", "container", "direction"])
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
    }

    private func assertGoalSchema(_ tool: Tool, file: StaticString = #filePath, line: UInt = #line) throws {
        let schema = try XCTUnwrap(tool.parametersJsonSchema(), file: file, line: line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any], file: file, line: line)
        let properties = try XCTUnwrap(object["properties"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(Set(object["required"] as? [String] ?? []), ["goal", "bundle_id", "actions", "completion"], file: file, line: line)
        XCTAssertEqual(object["additionalProperties"] as? Bool, false, file: file, line: line)
        let completion = try XCTUnwrap(properties["completion"] as? [String: Any], file: file, line: line)
        let completionProperties = try XCTUnwrap(completion["properties"] as? [String: Any], file: file, line: line)
        let kind = try XCTUnwrap(completionProperties["kind"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(Set(kind["enum"] as? [String] ?? []), ["visible", "absent", "value_equals"], file: file, line: line)
        XCTAssertNotNil(completionProperties["anchor"], file: file, line: line)
        let actions = try XCTUnwrap(properties["actions"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(actions["maxItems"] as? Int, 12, file: file, line: line)
        let item = try XCTUnwrap(actions["items"] as? [String: Any], file: file, line: line)
        let actionProperties = try XCTUnwrap(item["properties"] as? [String: Any], file: file, line: line)
        let action = try XCTUnwrap(actionProperties["action"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(Set(action["enum"] as? [String] ?? []), ["tap", "type", "swipe"], file: file, line: line)
        XCTAssertNil(actionProperties["ref"], file: file, line: line)
        XCTAssertNil(actionProperties["x"], file: file, line: line)
        XCTAssertNil(actionProperties["bundle_id"], file: file, line: line)
    }
}

private actor CatalogPairingStore: IOSPhoneControlCredentialStoring {
    func loadPairing() -> Data? { nil }
    func savePairing(_ data: Data) { }
    func deletePairing() { }
}
