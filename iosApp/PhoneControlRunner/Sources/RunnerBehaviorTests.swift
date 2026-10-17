import CoreGraphics
import XCTest

// Keep regression assertions outside the long-running server's issue-suppression policy.
final class RunnerBehaviorTests: XCTestCase {
  func testClickRefusesMissingElementBeforeSendingAnyGesture() throws {
    let runner = RunnerTests()
    let request = HTTPRequest(method: "POST", path: "/element/missing/click", query: [:], headers: [:], body: Data())
    let response: HTTPResponse
    do { response = try XCTUnwrap(runner.routeWDA(request)) }
    catch { response = .from(error) }
    XCTAssertEqual(response.status, 404)
    XCTAssertEqual(response.headers["X-IPU-Dropped"], "1")
    XCTAssertTrue(runner.requestTiming.isEmpty)
  }

  func testClickRefusesEmptyFrameBeforeSendingAnyGesture() throws {
    let runner = RunnerTests()
    let node = UINode(raw: ["type": "XCUIElementTypeStaticText", "label": "Contact",
                            "rect": ["x": 0, "y": 0, "width": 0, "height": 0]], parent: nil, pid: 42)
    let elementID = runner.elements.register(node)
    let request = HTTPRequest(method: "POST", path: "/element/\(elementID)/click", query: [:], headers: [:], body: Data())
    let response: HTTPResponse
    do { response = try XCTUnwrap(runner.routeWDA(request)) }
    catch { response = .from(error) }
    XCTAssertEqual(response.status, 500)
    XCTAssertEqual(response.headers["X-IPU-Dropped"], "1")
    XCTAssertTrue(runner.requestTiming.isEmpty)
  }

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

  func testExpandedIslandCollapseMatchesOnlyTheFullWidthTopPill() throws {
    func node(_ type: String, _ label: String?, x: Int, y: Int, width: Int, height: Int,
              _ children: [[String: Any]] = []) -> [String: Any] {
      var raw: [String: Any] = ["type": type, "rect": ["x": x, "y": y, "width": width, "height": height],
                                "children": children]
      if let label { raw["label"] = label }
      return raw
    }
    func springBoard(_ children: [[String: Any]]) -> UINode {
      UINode(raw: node("XCUIElementTypeApplication", nil, x: 0, y: 0, width: 402, height: 874, children),
             parent: nil, pid: 1)
    }
    func title(y: Int) -> [String: Any] { node("XCUIElementTypeStaticText", "Amber", x: 78, y: y, width: 90, height: 24) }
    let screen = CGSize(width: 402, height: 874)

    // Hardware screenshot: the expanded island spans x 12...390, y 12...103.
    let expanded = springBoard([node("XCUIElementTypeOther", nil, x: 12, y: 12, width: 378, height: 91, [title(y: 30)])])
    let swipe = try XCTUnwrap(ExpandedIsland.collapseSwipe(springBoard: expanded, title: "Amber", screen: screen))
    XCTAssertEqual(swipe.from, CGPoint(x: 201, y: 57.5))
    XCTAssertEqual(swipe.to, CGPoint(x: 201, y: 4))

    let compact = springBoard([node("XCUIElementTypeOther", "Amber", x: 140, y: 11, width: 122, height: 37)])
    XCTAssertNil(ExpandedIsland.collapseSwipe(springBoard: compact, title: "Amber", screen: screen))
    let banner = springBoard([node("XCUIElementTypeOther", "Amber, 新消息", x: 8, y: 58, width: 386, height: 80)])
    XCTAssertNil(ExpandedIsland.collapseSwipe(springBoard: banner, title: "Amber", screen: screen))
    let iconLabel = springBoard([node("XCUIElementTypeOther", nil, x: 12, y: 12, width: 378, height: 91, [
      node("XCUIElementTypeIcon", "Amber", x: 20, y: 20, width: 64, height: 64, [title(y: 70)]),
    ])])
    XCTAssertNil(ExpandedIsland.collapseSwipe(springBoard: iconLabel, title: "Amber", screen: screen))
    let otherApp = springBoard([node("XCUIElementTypeOther", "音乐", x: 12, y: 12, width: 378, height: 91)])
    XCTAssertNil(ExpandedIsland.collapseSwipe(springBoard: otherApp, title: "Amber", screen: screen))
  }

  private func axNode(_ type: String, _ label: String?, _ rect: [Int], _ children: [[String: Any]] = []) -> [String: Any] {
    var raw: [String: Any] = ["type": "XCUIElementType" + type, "children": children,
                              "rect": ["x": rect[0], "y": rect[1], "width": rect[2], "height": rect[3]]]
    if let label { raw["label"] = label }
    return raw
  }

  func testOcclusionRefusesOnlyOnPositiveEvidence() throws {
    let screen = CGSize(width: 402, height: 874)
    // Hardware, 小米办公: the chat's "发送" under the group settings page.
    let send = UINode(raw: axNode("Other", "发送", [317, 229, 80, 46], [axNode("StaticText", "发送", [317, 242, 80, 19])]),
                      parent: nil, pid: 7)
    let settingsRow = UINode(raw: axNode("Cell", "群成员", [16, 200, 370, 98]), parent: nil, pid: 7)
    XCTAssertNotNil(Occlusion.blocker(target: send, hit: settingsRow, hitIsOtherApp: false, screen: screen))

    let ownLabel = UINode(raw: axNode("StaticText", "发送", [317, 242, 80, 19]), parent: nil, pid: 7)
    XCTAssertNil(Occlusion.blocker(target: send, hit: ownLabel, hitIsOtherApp: false, screen: screen),
                 "a hit inside the target reaches it")
    // The hit test answers the accessible cell around a label: an ancestor, however large.
    let row = UINode(raw: axNode("Cell", "张三", [16, 300, 370, 60], [axNode("StaticText", "张三", [72, 310, 80, 19])]),
                     parent: nil, pid: 7)
    let name = try XCTUnwrap(row.children.first)
    let rowHit = UINode(raw: axNode("Cell", "张三", [16, 300, 370, 60]), parent: nil, pid: 7)
    XCTAssertNil(Occlusion.blocker(target: name, ancestors: [row], hit: rowHit, hitIsOtherApp: false, screen: screen))
    XCTAssertNotNil(Occlusion.blocker(target: name, hit: rowHit, hitIsOtherApp: false, screen: screen),
                    "without the ancestor chain the large row is not evidence of reaching the label")
    // Web content answers from WebContent: not another app, judged by geometry.
    XCTAssertNil(Occlusion.blocker(target: send, hit: ownLabel, hitIsOtherApp: false, screen: screen))
    XCTAssertNotNil(Occlusion.blocker(target: send, hit: settingsRow, hitIsOtherApp: true, screen: screen),
                    "SpringBoard or another app on top")
    let canvas = UINode(raw: axNode("Other", nil, [0, 0, 402, 874]), parent: nil, pid: 7)
    XCTAssertNil(Occlusion.blocker(target: send, hit: canvas, hitIsOtherApp: false, screen: screen),
                 "unlabeled container: no evidence")
    let watermark = UINode(raw: axNode("Other", "李晨 3791", [0, 0, 402, 874]), parent: nil, pid: 7)
    XCTAssertNil(Occlusion.blocker(target: send, hit: watermark, hitIsOtherApp: false, screen: screen),
                 "a labeled full-screen layer is everywhere: no evidence")
    let empty = UINode(raw: axNode("Other", "x", [0, 0, 0, 0]), parent: nil, pid: 7)
    XCTAssertNil(Occlusion.blocker(target: send, hit: empty, hitIsOtherApp: false, screen: screen),
                 "an unreadable hit lets the tap through")
  }

  func testOcclusionRecognizesTheRegisteredAncestorAfterScrolling() throws {
    var registeredRow = axNode("Cell", "张三", [16, 1100, 370, 60], [
      axNode("StaticText", "张三", [72, 1110, 80, 19]),
    ])
    registeredRow[IPURNodeAXElementKey] = NSString(string: "row-identity")
    let root = UINode(raw: registeredRow, parent: nil, pid: 7)
    let registry = ElementRegistry()
    let id = registry.register(try XCTUnwrap(root.children.first))
    let ancestors = RunnerTests.ancestors(of: try XCTUnwrap(registry.node(id)))
    let target = UINode(raw: axNode("StaticText", "张三", [72, 310, 80, 19]), parent: nil, pid: 7)
    var currentRow = axNode("Cell", "张三", [16, 300, 370, 60])
    currentRow[IPURNodeAXElementKey] = NSString(string: "row-identity")
    let hit = UINode(raw: currentRow, parent: nil, pid: 7)
    let screen = CGSize(width: 402, height: 874)

    XCTAssertNil(Occlusion.blocker(target: target, ancestors: ancestors, hit: hit,
                                  hitIsOtherApp: false, screen: screen),
                 "the same AX ancestor remains reachable after its frame changes")

    currentRow[IPURNodeAXElementKey] = NSString(string: "covering-row-identity")
    let coveringRow = UINode(raw: currentRow, parent: nil, pid: 7)
    XCTAssertNotNil(Occlusion.blocker(target: target, ancestors: ancestors, hit: coveringRow,
                                     hitIsOtherApp: false, screen: screen),
                    "a different row still blocks the label despite matching text and frame")
  }

  func testCoveredPagesMarksThePageUnderThePushedOne() throws {
    // The hidden chat page: its scroll view is the near-full-screen node; the input bar with
    // "发送" is a sibling, so the whole branch below the navigation container must be marked.
    let chat = axNode("Other", nil, [0, 0, 402, 874], [
      axNode("Table", nil, [0, 100, 402, 640], [axNode("Cell", "李晨: 你好", [0, 120, 402, 60])]),
      axNode("Other", nil, [0, 740, 402, 134], [
        axNode("TextView", nil, [16, 758, 337, 22]), axNode("Button", "发送", [350, 752, 44, 34]),
      ]),
    ])
    let settings = axNode("Other", nil, [0, 0, 402, 874], [
      axNode("Table", nil, [0, 100, 402, 774], [axNode("Cell", "群成员", [16, 200, 370, 98])]),
    ])
    let raw = axNode("Application", "小米办公Pro", [0, 0, 402, 874], [axNode("Window", nil, [0, 0, 402, 874], [chat, settings])])
    let root = UINode(raw: raw, parent: nil, pid: 7)
    let screen = CGSize(width: 402, height: 874)
    let pages = CoveredPages.pages(root, screen: screen)
    XCTAssertEqual(pages, [[0, 0, 0], [0, 1, 0]])

    let hit = UINode(raw: axNode("Cell", "群成员", [16, 200, 370, 98]), parent: nil, pid: 7)
    let covered = try XCTUnwrap(CoveredPages.covered(root, pages: pages, hits: [hit, hit]))
    XCTAssertEqual(covered.branches, [[0, 0]], "the branch splitting off below the shared container")
    let marked = UINode(raw: CoveredPages.marking(raw, covered: covered.branches), parent: nil, pid: 7)
    let coveredLabels = marked.descendants().filter { $0.attributes["isCovered"] as? String == "1" }.compactMap(\.label)
    XCTAssertEqual(coveredLabels, ["李晨: 你好", "发送"], "the hidden page's input bar is covered too")
    XCTAssertFalse(marked.descendants().contains { $0.label == "群成员" && $0.attributes["isCovered"] != nil })

    let chatPage = try XCTUnwrap(CoveredPages.node(root, at: [0, 0]))
    XCTAssertEqual(CoveredPages.samples(chatPage, within: covered.top, screen: screen).compactMap(\.label),
                   ["李晨: 你好", "发送"])
    XCTAssertTrue(CoveredPages.samples(chatPage, within: CGRect(x: 0, y: 500, width: 402, height: 200), screen: screen).isEmpty,
                  "samples come from under the top page only")

    XCTAssertNil(CoveredPages.covered(root, pages: pages, hits: []), "no probe evidence, nothing marked")
    let chatHit = UINode(raw: axNode("Cell", "李晨: 你好", [0, 120, 402, 60]), parent: nil, pid: 7)
    XCTAssertNil(CoveredPages.covered(root, pages: pages, hits: [hit, chatHit]), "a tie marks nothing")
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
