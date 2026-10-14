import CoreGraphics
import XCTest

// Keep regression assertions outside the long-running server's issue-suppression policy.
final class RunnerBehaviorTests: XCTestCase {
  func testLongPressCannotFallBackToSingleTap() throws {
    func path(_ duration: Int) throws -> [[[String: Any]]] {
      try W3CActions.pointerPaths([
        ["type": "pointerMove", "x": 120, "y": 180],
        ["type": "pointerDown"], ["type": "pause", "duration": duration], ["type": "pointerUp"],
      ]) { _ in .zero }
    }
    XCTAssertEqual(W3CActions.singleTapFallbackPoint(try path(0)), CGPoint(x: 120, y: 180))
    for duration in [300, 750, 3000] {
      XCTAssertNil(W3CActions.singleTapFallbackPoint(try path(duration)), "A synthesized hold failure must not become a tap")
    }
  }

  func testGuardedAlertRequiresSameDialogAndOneExactButton() {
    let body: [String: Any] = ["expected_text": "允许访问？", "expected_pid": 42,
                               "expected_buttons": ["不允许", "允许"], "name": "允许"]
    XCTAssertEqual(AlertMatch.guardedButtonIndex(body: body, text: "允许访问？", pid: 42,
                                                buttons: ["不允许", "允许"]), 1)
    XCTAssertNil(AlertMatch.guardedButtonIndex(body: body, text: "允许通知？", pid: 42, buttons: ["不允许", "允许"]))
    XCTAssertNil(AlertMatch.guardedButtonIndex(body: body, text: "允许访问？", pid: 43, buttons: ["不允许", "允许"]))
    XCTAssertNil(AlertMatch.guardedButtonIndex(body: body, text: "允许访问？", pid: 42, buttons: ["允许", "不允许"]))
    let duplicate: [String: Any] = ["expected_text": "选择", "expected_pid": 42,
                                   "expected_buttons": ["允许", "允许"], "name": "允许"]
    XCTAssertNil(AlertMatch.guardedButtonIndex(body: duplicate, text: "选择", pid: 42, buttons: ["允许", "允许"]))
  }

}
