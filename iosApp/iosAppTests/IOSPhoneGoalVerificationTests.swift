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

    func testMatchingNodesCollapsesOnlyAContainedSameLabelTextChild() {
        let target = IOSPhoneGoalTarget(label: "继续")
        let parent = node(identifier: "continue", label: "继续", depth: 1, type: "XCUIElementTypeButton", x: 20, width: 180, y: 20, height: 80)
        let child = node(identifier: "continue-label", label: "继续", depth: 2, type: "XCUIElementTypeStaticText", x: 40, width: 120, y: 40, height: 32)
        let sibling = node(identifier: "other-continue", label: "继续", depth: 1, type: "XCUIElementTypeOther", x: 240, width: 120, y: 20, height: 44)

        let matches: [PhoneObservationNode] = IOSPhoneGoalVerification.matchingNodes(
            target: target, in: observation([parent, child, sibling]))

        XCTAssertEqual(matches.map(\.identifier), ["continue", "other-continue"])
    }

    func testExplicitTypeKeepsTheRequestedTextChildPrecise() {
        let target = IOSPhoneGoalTarget(label: "继续", type: "XCUIElementTypeStaticText")
        let parent = node(identifier: "continue", label: "继续", depth: 1, type: "XCUIElementTypeButton", x: 20, width: 180, y: 20, height: 80)
        let child = node(identifier: "continue-label", label: "继续", depth: 2, type: "XCUIElementTypeStaticText", x: 40, width: 120, y: 40, height: 32)

        let matches: [PhoneObservationNode] = IOSPhoneGoalVerification.matchingNodes(
            target: target, in: observation([parent, child]))
        XCTAssertEqual(matches.map(\.identifier), ["continue-label"])
    }

    func testRegionVerifiesSameLabelAfterItMovesFromSourceToTargetArea() {
        let sourceRegion = IOSPhoneGoalRegion(x: 0, y: 0.60, width: 1, height: 0.30)
        let targetRegion = IOSPhoneGoalRegion(x: 0, y: 0.35, width: 1, height: 0.25)
        let source = IOSPhoneGoalTarget(label: "go", type: "XCUIElementTypeStaticText", region: sourceRegion)
        let target = IOSPhoneGoalTarget(label: "go", type: "XCUIElementTypeStaticText", region: targetRegion)
        let before = observation([node(label: "go", type: "XCUIElementTypeStaticText", y: 626)], id: "before")
        let after = observation([node(label: "go", type: "XCUIElementTypeStaticText", y: 399)])

        XCTAssertTrue(IOSPhoneGoalVerification.matchingNodes(target: source, in: before).count == 1)
        XCTAssertTrue(IOSPhoneGoalVerification.matchingNodes(target: source, in: after).isEmpty)
        XCTAssertTrue(IOSPhoneGoalVerification.matchingNodes(target: target, in: after).count == 1)

        let moved = IOSPhoneGoalExpectation(kind: .absent, target: source, anchor: target)
        XCTAssertEqual(evaluate(moved, before: before, after: after).status, .satisfied)
    }

    func testRegionDoesNotPassWhenSameLabelStaysInSourceArea() {
        let targetRegion = IOSPhoneGoalRegion(x: 0, y: 0.35, width: 1, height: 0.25)
        let target = IOSPhoneGoalTarget(label: "go", type: "XCUIElementTypeStaticText", region: targetRegion)
        let after = observation([node(label: "go", type: "XCUIElementTypeStaticText", y: 626)])

        XCTAssertEqual(evaluate(.init(kind: .visible, target: target), after: after).status, .unmet)
    }

    func testRegionSelectsOneOfDuplicateLabels() {
        let targetRegion = IOSPhoneGoalRegion(x: 0, y: 0.35, width: 1, height: 0.25)
        let target = IOSPhoneGoalTarget(label: "go", type: "XCUIElementTypeStaticText", region: targetRegion)
        let after = observation([
            node(label: "go", type: "XCUIElementTypeStaticText", y: 626),
            node(label: "go", type: "XCUIElementTypeStaticText", y: 399),
        ])

        XCTAssertEqual(IOSPhoneGoalVerification.matchingNodes(target: target, in: after).count, 1)
        XCTAssertEqual(evaluate(.init(kind: .visible, target: target), after: after).status, .satisfied)
    }

    func testTargetRegionRejectsNonFiniteOrOutOfBoundsRectangles() {
        let invalid = [
            IOSPhoneGoalRegion(x: -0.01, y: 0, width: 0.2, height: 0.2),
            IOSPhoneGoalRegion(x: 0, y: 0, width: 0, height: 0.2),
            IOSPhoneGoalRegion(x: 0.9, y: 0, width: 0.2, height: 0.2),
            IOSPhoneGoalRegion(x: 0, y: 0, width: 0.2, height: .infinity),
        ]

        for region in invalid {
            XCTAssertThrowsError(try IOSPhoneGoalTarget(label: "go", region: region).validate())
        }
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

    func testEnabledRequiresOneVisibleEnabledTargetWhileVisibleKeepsItsMeaning() {
        let target = IOSPhoneGoalTarget(identifier: "check")
        let expected = IOSPhoneGoalExpectation(kind: .enabled, target: target)
        let disabled = node(identifier: "check", enabled: false)
        let before = observation([disabled], id: "before")
        let disabledAfter = observation([disabled])
        XCTAssertEqual(evaluate(.init(kind: .visible, target: target), before: before, after: disabledAfter).status,
                       .satisfied)
        let unmet = evaluate(expected, before: before, after: disabledAfter)
        XCTAssertEqual(unmet.status, .unmet)
        XCTAssertEqual(unmet.reason, "target_disabled")
        XCTAssertEqual(evaluate(expected, before: before, after: observation([node(identifier: "check")])).status,
                       .satisfied)
        XCTAssertEqual(evaluate(expected, before: before, after: before).reason, "fresh_observation_required")
        let ambiguous = observation([node(identifier: "check"), disabled])
        XCTAssertEqual(evaluate(expected, after: ambiguous).reason, "ambiguous_target")
        XCTAssertEqual(evaluate(expected, after: observation([node(identifier: "check", y: 1_000),
                                                              node(label: "题目")])).status, .unmet)
        XCTAssertEqual(evaluate(expected, after: observation([node(label: "题目")], truncated: true)).reason,
                       "truncated_tree")
    }

    func testEnabledExpectationDecodesAndRejectsValueOrAnchor() throws {
        let json = #"{"kind":"enabled","target":{"identifier":"check"}}"#
        let expectation = try JSONDecoder().decode(IOSPhoneGoalExpectation.self, from: Data(json.utf8))
        XCTAssertEqual(expectation.kind, .enabled)
        XCTAssertNoThrow(try expectation.validate())
        XCTAssertThrowsError(try IOSPhoneGoalExpectation(kind: .enabled, target: home, value: "").validate())
        XCTAssertThrowsError(try IOSPhoneGoalExpectation(kind: .enabled, target: home, anchor: popup).validate())
    }

    func testEnabledRegionUsesTheControlStateInsteadOfItsEnabledLabelChild() {
        let target = IOSPhoneGoalTarget(label: "Check", region: .init(x: 0, y: 0, width: 0.5, height: 0.2))
        let expectation = IOSPhoneGoalExpectation(kind: .enabled, target: target)
        let child = node(identifier: "check-label", label: "Check", depth: 2,
                         type: "XCUIElementTypeStaticText", x: 40, width: 80, y: 40, height: 32)
        let outside = node(identifier: "other-check", label: "Check", x: 240, width: 120, y: 20, height: 44)
        for enabled in [false, true] {
            let control = node(identifier: "check", label: "Check", enabled: enabled,
                               x: 20, width: 120, y: 20, height: 80)
            let screen = observation([control, child, outside])

            XCTAssertEqual(evaluate(.init(kind: .visible, target: target), after: screen).status, .satisfied)
            XCTAssertEqual(evaluate(expectation, after: screen).status, enabled ? .satisfied : .unmet)
        }
    }

    func testRequestDefaultsAndRejectsInvalidActionCombinationsAndBounds() throws {
        let json = #"{"goal":"打开搜索","bundle_id":"app.test","actions":[{"action":"tap","target":{"label":"搜索"}}],"completion":{"kind":"visible","target":{"label":"搜索结果"}}}"#
        let request = try JSONDecoder().decode(IOSPhoneGoalRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.maxSteps, 15)
        XCTAssertNoThrow(try request.validate())
        XCTAssertThrowsError(try IOSPhoneGoalRequest(goal: request.goal, bundleID: request.bundleID,
                                                    actions: request.actions, completion: request.completion, maxSteps: 31).validate())
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
                      x: Double = 0, width: Double = 44, y: Double = 0,
                      height: Double = 44) -> PhoneObservationNode {
        .init(ref: "ref", depth: depth, type: type, identifier: identifier, label: label, value: value,
              rect: .init(x: x, y: y, width: width, height: height), enabled: enabled, focused: false)
    }
}
