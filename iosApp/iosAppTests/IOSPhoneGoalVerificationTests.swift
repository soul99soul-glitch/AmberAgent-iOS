import AmberPhoneControl
import Foundation
import XCTest
@testable import iosApp

final class IOSPhoneGoalVerificationTests: XCTestCase {
    private let popup = IOSPhoneGoalTarget(identifier: "promotion")
    private let home = IOSPhoneGoalTarget(label: "首页")

    func testLaunchVerifiesOnlyTheRequestedAppWithoutReusingAnotherAppsTree() {
        let before = observation([node(identifier: "promotion")], id: "before", app: "app.old")
        let after = observation([node(label: "首页")], app: "app.target")
        let visible = IOSPhoneGoalExpectation(kind: .visible, target: home)
        XCTAssertEqual(IOSPhoneGoalVerification.evaluate(action: .launch(bundleID: "app.target"),
            expectation: visible, before: before, after: after).status, .satisfied)
        XCTAssertEqual(IOSPhoneGoalVerification.evaluate(action: .launch(bundleID: "app.other"),
            expectation: visible, before: before, after: after).reason, "launched_app_not_foreground")
        XCTAssertEqual(IOSPhoneGoalVerification.evaluate(action: .tap(ref: "before:1"),
            expectation: visible, before: before, after: after).reason, "foreground_app_changed")
        let absent = IOSPhoneGoalExpectation(kind: .absent, target: popup, anchor: home)
        XCTAssertEqual(IOSPhoneGoalVerification.evaluate(action: .launch(bundleID: "app.target"),
            expectation: absent, before: before, after: after).reason, "before_observation_required")
    }

    func testOffscreenTargetIsNotVisibleAndRootFrameCannotSubstituteForScreenGeometry() {
        let target = IOSPhoneGoalTarget(label: "搜索结果")
        let expected = IOSPhoneGoalExpectation(kind: .visible, target: target)
        let offscreen = node(label: "搜索结果", y: 1800)
        let after = observation([node(label: "首页"), offscreen])
        XCTAssertEqual(evaluate(expected, after: after).status, .unmet)
        XCTAssertTrue(IOSPhoneGoalVerification.matchingNodes(target: target, in: after).isEmpty)
        let withoutBounds = observation([node(label: "搜索结果")], bounds: nil)
        XCTAssertEqual(evaluate(expected, after: withoutBounds).reason, "screen_bounds_unavailable")
        XCTAssertTrue(IOSPhoneGoalVerification.matchingNodes(target: target, in: withoutBounds).isEmpty)
        let smallRoot = node(depth: 0, type: "XCUIElementTypeApplication", width: 402)
        XCTAssertEqual(evaluate(expected, after: observation([smallRoot, node(label: "搜索结果", y: 600)])).status, .satisfied)
    }

    func testDifferentBackendOrScreenGeometryCannotProveTargetDisappearance() {
        let expected = IOSPhoneGoalExpectation(kind: .absent, target: popup, anchor: home)
        let before = observation([node(identifier: "promotion")], id: "before", backend: "private-ax")
        let fallback = observation([node(label: "首页")], backend: "xctest")
        XCTAssertEqual(evaluate(expected, before: before, after: fallback).reason, "observation_backend_changed")
        XCTAssertFalse(IOSPhoneGoalVerification.hasMeaningfulChange(before: before, after: fallback))
        let after = observation([node(label: "首页")], backend: "private-ax",
                                bounds: .init(x: 0, y: 0, width: 874, height: 402))
        XCTAssertEqual(evaluate(expected, before: before, after: after).reason, "screen_bounds_changed")
        let unboundedBefore = observation([node(identifier: "promotion")], id: "before", bounds: nil)
        XCTAssertEqual(evaluate(expected, before: unboundedBefore, after: observation([node(label: "首页")])).reason,
                       "previous_screen_bounds_unavailable")
    }

    func testMeaningfulChangeIgnoresObservationAndReferenceIDsButTracksUIState() {
        let original = node(label: "搜索")
        let reread = PhoneObservationNode(ref: "new-ref", depth: original.depth, type: original.type,
                                          identifier: original.identifier, label: original.label, value: original.value,
                                          rect: original.rect, enabled: original.enabled, focused: original.focused)
        let before = observation([original], id: "before")
        XCTAssertFalse(IOSPhoneGoalVerification.hasMeaningfulChange(before: before, after: observation([reread])))
        XCTAssertTrue(IOSPhoneGoalVerification.hasMeaningfulChange(before: before, after: observation([node(label: "搜索结果")])))
        XCTAssertTrue(IOSPhoneGoalVerification.hasMeaningfulChange(before: before, after: observation([node(label: "搜索", enabled: false)])))
        XCTAssertTrue(IOSPhoneGoalVerification.hasMeaningfulChange(before: before, after: observation([reread], truncated: true)))
    }

    func testAbsenceRequiresPreviousPresenceAndNewCompleteAnchoredObservation() {
        let expectation = IOSPhoneGoalExpectation(kind: .absent, target: popup, anchor: home)
        let before = observation([node(identifier: "promotion"), node(label: "首页")], id: "before")
        let after = observation([node(label: "首页")])
        XCTAssertEqual(evaluate(expectation, before: before, after: after).status, .satisfied)
        XCTAssertEqual(evaluate(expectation, before: nil, after: after).status, .insufficient)
        XCTAssertEqual(evaluate(expectation, before: after, after: after).reason, "fresh_observation_required")
        XCTAssertEqual(evaluate(expectation, before: observation([node(label: "首页")], id: "before"),
                                after: after).reason, "target_not_previously_visible")
        XCTAssertEqual(evaluate(expectation, before: before,
                                after: observation([node(label: "首页")], truncated: true)).reason, "truncated_tree")
        XCTAssertEqual(evaluate(expectation, before: before,
                                after: observation([node(label: "其他页面")])).reason, "visible_anchor_required")
        XCTAssertEqual(evaluate(expectation, before: before,
                                after: observation([node(label: "首页"), node(label: "首页")])).reason,
                       "visible_anchor_required")
    }

    func testEmptyOrRootOnlyTreeCannotProvePopupDismissed() {
        let expectation = IOSPhoneGoalExpectation(kind: .absent, target: popup, anchor: home)
        let before = observation([node(identifier: "promotion")], id: "before")
        for nodes in [[], [node(label: "首页", depth: 0, type: "XCUIElementTypeApplication")]] {
            let result = evaluate(expectation, before: before, after: observation(nodes))
            XCTAssertEqual(result.status, .insufficient)
            XCTAssertTrue(result.needsScreenshot)
        }
    }

    func testRemainingPopupIsUnmetAndDuplicateTargetsAreInsufficient() {
        let expectation = IOSPhoneGoalExpectation(kind: .absent, target: popup, anchor: home)
        let before = observation([node(identifier: "promotion")], id: "before")
        XCTAssertEqual(evaluate(expectation, before: before,
                                after: observation([node(identifier: "promotion")])).status, .unmet)
        XCTAssertEqual(evaluate(expectation, before: before,
                                after: observation([node(identifier: "promotion"), node(identifier: "promotion")])).status,
                       .insufficient)
        XCTAssertEqual(evaluate(expectation,
                                before: observation([node(identifier: "promotion"), node(identifier: "promotion")], id: "before"),
                                after: observation([node(label: "首页")])).reason, "ambiguous_previous_target")
    }

    func testAppAndProcessChangesCannotProveCompletion() {
        let expected = IOSPhoneGoalExpectation(kind: .visible, target: home)
        let before = observation([node(label: "首页")], id: "before")
        for after in [observation([node(label: "首页")], app: "other.app"),
                      observation([node(label: "首页")], pid: 43)] {
            XCTAssertEqual(evaluate(expected, before: before, after: after).reason, "foreground_app_changed")
        }
    }

    func testExactTargetMatchingUsesAllFieldsAndDistinguishesVisibleFromExecutable() {
        let target = IOSPhoneGoalTarget(label: "关闭", identifier: "close", type: "XCUIElementTypeButton")
        let exact = node(identifier: "close", label: "关闭", enabled: false)
        let after = observation([
            exact, node(identifier: "close", label: "关闭弹窗"), node(identifier: "other", label: "关闭"),
            node(identifier: "close", label: "关闭", type: "XCUIElementTypeStaticText"),
            node(identifier: "close", label: "关闭", width: 0),
            node(identifier: "close", label: "关闭", width: .infinity),
        ])
        XCTAssertEqual(IOSPhoneGoalVerification.matchingNodes(target: target, in: after), [exact])
        XCTAssertTrue(IOSPhoneGoalVerification.matchingNodes(target: target, in: after, executable: true).isEmpty)
        XCTAssertEqual(evaluate(.init(kind: .visible, target: target), after: after).status, .satisfied)
    }

    func testValueComparisonNeedsUniqueReadableInputAndMatchesExactly() {
        let input = IOSPhoneGoalTarget(identifier: "query")
        let expected = IOSPhoneGoalExpectation(kind: .valueEquals, target: input, value: "星巴克")
        let typed = node(identifier: "query", value: "星巴克", type: "XCUIElementTypeSearchField")
        XCTAssertEqual(evaluate(expected, after: observation([typed])).status, .satisfied)
        XCTAssertEqual(evaluate(expected, after: observation([node(identifier: "query", value: "星巴克 ",
                                                                  type: "XCUIElementTypeSearchField")])).status, .unmet)
        for type in ["XCUIElementTypeSecureTextField", "XCUIElementTypeStaticText", "XCUIElementTypeButton"] {
            XCTAssertEqual(evaluate(expected, after: observation([node(identifier: "query", value: "星巴克", type: type)])).status,
                           .insufficient)
        }
        XCTAssertEqual(evaluate(expected, after: observation([typed, typed])).status, .insufficient)
        XCTAssertEqual(evaluate(expected, after: observation([typed], truncated: true)).status, .insufficient)
        XCTAssertEqual(evaluate(expected, after: observation([node(identifier: "query", type: "XCUIElementTypeTextField")])).reason,
                       "input_value_unavailable")
        let empty = IOSPhoneGoalExpectation(kind: .valueEquals, target: input, value: "")
        XCTAssertEqual(evaluate(empty, after: observation([node(identifier: "query", value: "", type: "XCUIElementTypeTextView")])).status,
                       .satisfied)
    }

    func testRequestDefaultsAndRejectsInvalidActionCombinationsAndBounds() throws {
        let json = #"{"goal":"打开搜索","bundle_id":"app.test","actions":[{"action":"tap","target":{"label":"搜索"}}],"completion":{"kind":"visible","target":{"label":"搜索结果"}}}"#
        let request = try JSONDecoder().decode(IOSPhoneGoalRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.maxSteps, 6)
        XCTAssertNoThrow(try request.validate())
        XCTAssertThrowsError(try IOSPhoneGoalRequest(goal: request.goal, bundleID: request.bundleID,
                                                    actions: request.actions, completion: request.completion, maxSteps: 13).validate())
        XCTAssertThrowsError(try IOSPhoneGoalRequest(goal: request.goal, bundleID: request.bundleID,
                                                    actions: Array(repeating: request.actions[0], count: 13),
                                                    completion: request.completion).validate())
        XCTAssertThrowsError(try IOSPhoneGoalTarget(type: "XCUIElementTypeButton").validate())
        XCTAssertThrowsError(try IOSPhoneGoalTarget(label: " ").validate())
        XCTAssertThrowsError(try IOSPhoneGoalExpectation(kind: .absent, target: popup).validate())
        XCTAssertThrowsError(try IOSPhoneGoalExpectation(kind: .absent, target: home, anchor: home).validate())
        XCTAssertThrowsError(try IOSPhoneGoalExpectation(kind: .visible, target: home, value: "unexpected").validate())
        XCTAssertThrowsError(try IOSPhoneGoalActionSpec(action: .tap, target: home, text: "unexpected").validate())
        XCTAssertThrowsError(try IOSPhoneGoalActionSpec(action: .type, target: home).validate())
        XCTAssertThrowsError(try IOSPhoneGoalActionSpec(action: .swipe, target: home).validate())
        for action in ["launch", "home", "tap_point"] {
            XCTAssertThrowsError(try JSONDecoder().decode(IOSPhoneGoalRequest.self,
                                                         from: Data(json.replacingOccurrences(of: "\"tap\"", with: "\"\(action)\"").utf8)))
        }
    }

    private func evaluate(_ expectation: IOSPhoneGoalExpectation, before: PhoneObservation? = nil,
                          after: PhoneObservation) -> IOSPhoneGoalVerificationResult {
        IOSPhoneGoalVerification.evaluate(expectation: expectation, before: before, after: after)
    }

    private func observation(_ nodes: [PhoneObservationNode], id: String = "after", app: String = "app.test",
                             pid: Int = 42, truncated: Bool = false, backend: String = "test",
                             bounds: PhoneElementRect? = .init(x: 0, y: 0, width: 402, height: 874)) -> PhoneObservation {
        .init(observationID: id, bundleID: app, processID: pid, backend: backend,
              truncated: truncated, nodes: nodes, screenBounds: bounds)
    }

    private func node(identifier: String? = nil, label: String? = nil, value: String? = nil,
                      depth: Int = 1, type: String = "XCUIElementTypeButton", enabled: Bool = true,
                      width: Double = 44, y: Double = 0) -> PhoneObservationNode {
        .init(ref: "ref", depth: depth, type: type, identifier: identifier, label: label, value: value,
              rect: .init(x: 0, y: y, width: width, height: 44), enabled: enabled, focused: false)
    }
}
