import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSPhoneControlCatalogTests: XCTestCase {
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
