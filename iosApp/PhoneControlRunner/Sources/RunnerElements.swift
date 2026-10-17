// Element lookup for the WDA-compatible routes: an in-memory tree built from the private AX
// snapshot (the same read /source serves), WDA's locator strategies evaluated against it, and an
// id -> element registry. Finding elements this way costs one tree read instead of an XCUI query
// resolution per call, and it sees exactly what /source shows.

import CoreGraphics
import Foundation

/// One accessibility node. `attributes` holds the WDA /source keys (no children); `axElement` is
/// the live XCAccessibilityElement, used to re-snapshot just this element later.
final class UINode {
  let attributes: [String: Any]
  let axElement: AnyObject?
  private(set) var children: [UINode] = []
  private(set) weak var parent: UINode?
  let pid: Int32

  init(raw: [String: Any], parent: UINode?, pid: Int32) {
    var attributes = raw
    attributes.removeValue(forKey: "children")
    let element = attributes.removeValue(forKey: IPURNodeAXElementKey)
    self.attributes = attributes
    self.axElement = element as AnyObject?
    self.parent = parent
    self.pid = pid
    children = (raw["children"] as? [[String: Any]] ?? []).map { UINode(raw: $0, parent: self, pid: pid) }
  }

  var type: String { attributes["type"] as? String ?? "XCUIElementTypeOther" }
  var label: String? { nonEmpty(attributes["label"]) }
  var identifier: String? { nonEmpty(attributes["rawIdentifier"]) }
  var name: String? { identifier ?? label }
  var value: String? { attributes["value"] as? String }
  var placeholder: String? { nonEmpty(attributes["placeholderValue"]) }
  var isEnabled: Bool { attributes["isEnabled"] as? String != "0" }
  var isFocused: Bool { attributes["isFocused"] as? String == "1" }

  var rect: CGRect {
    let r = attributes["rect"] as? [String: Any] ?? [:]
    func v(_ key: String) -> CGFloat { CGFloat((r[key] as? NSNumber)?.doubleValue ?? 0) }
    return CGRect(x: v("x"), y: v("y"), width: v("width"), height: v("height"))
  }

  var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

  /// WDA has no cheap visibility either way; the runner answers geometrically: a non-empty frame
  /// that intersects the screen.
  func isVisible(screen: CGSize) -> Bool {
    let frame = rect
    guard frame.width > 0, frame.height > 0 else { return false }
    return frame.intersects(CGRect(origin: .zero, size: screen))
  }

  /// Every node below this one, in document (pre-) order.
  func descendants() -> [UINode] {
    var out: [UINode] = []
    func walk(_ node: UINode) {
      for child in node.children {
        out.append(child)
        walk(child)
      }
    }
    walk(self)
    return out
  }

  /// The object NSPredicate locators are evaluated against: WDA's predicate attribute names
  /// (and their wd*/is* aliases) mapped onto this node.
  func predicateObject(screen: CGSize) -> NSDictionary {
    let visible = isVisible(screen: screen)
    let frame = rect
    let rectDictionary: [String: Any] = [
      "x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height,
    ]
    var object: [String: Any] = [
      "type": type, "wdType": type, "elementType": RunnerElementTypes.rawValue(of: type),
      "enabled": isEnabled, "isEnabled": isEnabled, "wdEnabled": isEnabled,
      "visible": visible, "isVisible": visible, "wdVisible": visible,
      "accessible": true, "isAccessible": true, "wdAccessible": true,
      "focused": isFocused, "hasFocus": isFocused, "isFocused": isFocused, "wdFocused": isFocused,
      "selected": false, "isSelected": false, "wdSelected": false,
      "rect": rectDictionary, "wdRect": rectDictionary, "frame": rectDictionary,
      "hittable": visible, "isHittable": visible, "wdHittable": visible,
    ]
    if let name { object["name"] = name; object["wdName"] = name }
    if let label { object["label"] = label; object["wdLabel"] = label }
    if let value { object["value"] = value; object["wdValue"] = value }
    if let identifier { object["identifier"] = identifier; object["rawIdentifier"] = identifier }
    if let placeholder { object["placeholderValue"] = placeholder; object["wdPlaceholderValue"] = placeholder }
    object["title"] = ""
    return object as NSDictionary
  }

  private func nonEmpty(_ value: Any?) -> String? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return string
  }
}

enum RunnerElementTypes {
  static let names: [String] = (0...82).map { IPURBridge.elementTypeName($0) }
  static let indexByName: [String: Int] = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })

  static func rawValue(of name: String) -> Int { indexByName[name] ?? 1 }

  /// Accepts "XCUIElementTypeButton" or the short "Button".
  static func normalize(_ name: String) -> String {
    name.hasPrefix("XCUIElementType") ? name : "XCUIElementType" + name
  }
}

// MARK: - Locators

enum Locator {
  /// Evaluates one WDA locator strategy below `root` (the root itself never matches).
  static func find(using: String, value: String, root: UINode, screen: CGSize) throws -> [UINode] {
    switch using {
    case "accessibility id", "id", "name":
      // WDA matches the element's name: its identifier when it has one, else its label. Matching
      // identifier-or-label on every node also returned labelled containers' children (iOS 26
      // SpringBoard: the "spotlight-pill" plus its "搜索" image and text), so lookups WDA
      // answered with one element came back ambiguous.
      return root.descendants().filter { $0.name == value }
    case "class name":
      let type = RunnerElementTypes.normalize(value)
      return root.descendants().filter { $0.type == type }
    case "predicate string":
      let predicate = try makePredicate(value)
      return try filter(root.descendants(), predicate, screen: screen)
    case "class chain":
      return try ClassChain(value).evaluate(root: root, screen: screen)
    case "link text", "partial link text":
      let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { throw RunnerError.invalidSelector("link text must be 'attribute=value'") }
      let partial = using == "partial link text"
      return root.descendants().filter { node in
        let candidate = node.predicateObject(screen: screen)[parts[0]] as? String ?? ""
        return partial ? candidate.contains(parts[1]) : candidate == parts[1]
      }
    default:
      throw RunnerError.invalidSelector("locator strategy '\(using)' is not supported by the native runner")
    }
  }

  static func makePredicate(_ format: String) throws -> NSPredicate {
    var predicate: NSPredicate?
    if let exception = IPURBridge.catchException({ predicate = NSPredicate(format: format) }) {
      throw RunnerError.invalidSelector("invalid predicate '\(format)': \(exception)")
    }
    guard let predicate else { throw RunnerError.invalidSelector("invalid predicate '\(format)'") }
    return predicate
  }

  static func filter(_ nodes: [UINode], _ predicate: NSPredicate, screen: CGSize) throws -> [UINode] {
    var matched: [UINode] = []
    let exception = IPURBridge.catchException {
      for node in nodes where predicate.evaluate(with: node.predicateObject(screen: screen)) {
        matched.append(node)
      }
    }
    if let exception {
      throw RunnerError.invalidSelector("predicate '\(predicate.predicateFormat)' failed: \(exception)")
    }
    return matched
  }
}

/// WDA's class chain locator: `/`-separated steps, each `**` (any depth) or a type / `*`, with
/// `[n]` (1-based, negative from the end), `` [`predicate`] `` and `[$predicate$]` (has a matching
/// descendant) filters. An index applies to everything the step matched so far, like the XCUI
/// query WDA builds.
struct ClassChain {
  struct Step {
    var anyDepth = false
    var type: String?  // nil = "*"
    var filters: [Filter] = []
  }

  enum Filter {
    case index(Int)
    case predicate(NSPredicate)
    case descendantPredicate(NSPredicate)
  }

  let steps: [Step]

  init(_ chain: String) throws {
    var steps: [Step] = []
    var pendingAnyDepth = false
    for raw in try Self.split(chain) {
      let token = raw.trimmingCharacters(in: .whitespaces)
      if token == "**" {
        pendingAnyDepth = true
        continue
      }
      var step = try Self.parseStep(token)
      step.anyDepth = pendingAnyDepth
      pendingAnyDepth = false
      steps.append(step)
    }
    if pendingAnyDepth { throw RunnerError.invalidSelector("class chain cannot end with '**'") }
    if steps.isEmpty { throw RunnerError.invalidSelector("empty class chain") }
    self.steps = steps
  }

  /// Splits on `/` outside backtick / dollar quoted predicates.
  private static func split(_ chain: String) throws -> [String] {
    var parts: [String] = []
    var current = ""
    var quote: Character?
    for character in chain {
      if let open = quote {
        current.append(character)
        if character == open { quote = nil }
        continue
      }
      if character == "`" || character == "$" {
        quote = character
        current.append(character)
      } else if character == "/" {
        parts.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    if quote != nil { throw RunnerError.invalidSelector("unterminated predicate in class chain") }
    parts.append(current)
    return parts.filter { !$0.isEmpty }
  }

  private static func parseStep(_ token: String) throws -> Step {
    var step = Step()
    let typeEnd = token.firstIndex(of: "[") ?? token.endIndex
    let typeName = String(token[..<typeEnd]).trimmingCharacters(in: .whitespaces)
    if typeName.isEmpty { throw RunnerError.invalidSelector("class chain step '\(token)' has no type") }
    step.type = typeName == "*" ? nil : RunnerElementTypes.normalize(typeName)
    var rest = Substring(token[typeEnd...])
    while !rest.isEmpty {
      guard rest.first == "[" else { throw RunnerError.invalidSelector("unexpected '\(rest)' in class chain") }
      rest = rest.dropFirst()
      if let quote = rest.first, quote == "`" || quote == "$" {
        // Doubled quote characters are literal ones, as in WDA.
        var body = ""
        var index = rest.index(after: rest.startIndex)
        var closed = false
        while index < rest.endIndex {
          let character = rest[index]
          if character == quote {
            let next = rest.index(after: index)
            if next < rest.endIndex, rest[next] == quote {
              body.append(quote)
              index = rest.index(after: next)
              continue
            }
            closed = true
            index = next
            break
          }
          body.append(character)
          index = rest.index(after: index)
        }
        guard closed, index < rest.endIndex, rest[index] == "]" else {
          throw RunnerError.invalidSelector("unterminated predicate in class chain step '\(token)'")
        }
        let predicate = try Locator.makePredicate(body)
        step.filters.append(quote == "`" ? .predicate(predicate) : .descendantPredicate(predicate))
        rest = rest[rest.index(after: index)...]
      } else {
        guard let close = rest.firstIndex(of: "]"), let number = Int(rest[..<close].trimmingCharacters(in: .whitespaces)),
              number != 0
        else {
          throw RunnerError.invalidSelector("bad index in class chain step '\(token)'")
        }
        step.filters.append(.index(number))
        rest = rest[rest.index(after: close)...]
      }
    }
    return step
  }

  func evaluate(root: UINode, screen: CGSize) throws -> [UINode] {
    var current: [UINode] = [root]
    for step in steps {
      var candidates: [UINode] = []
      var seen = Set<ObjectIdentifier>()
      for node in current {
        for candidate in (step.anyDepth ? node.descendants() : node.children) {
          if seen.insert(ObjectIdentifier(candidate)).inserted { candidates.append(candidate) }
        }
      }
      if let type = step.type { candidates = candidates.filter { $0.type == type } }
      for filter in step.filters {
        switch filter {
        case .index(let number):
          let index = number > 0 ? number - 1 : candidates.count + number
          candidates = candidates.indices.contains(index) ? [candidates[index]] : []
        case .predicate(let predicate):
          candidates = try Locator.filter(candidates, predicate, screen: screen)
        case .descendantPredicate(let predicate):
          candidates = try candidates.filter { !(try Locator.filter($0.descendants(), predicate, screen: screen)).isEmpty }
        }
      }
      current = candidates
      if current.isEmpty { break }
    }
    return current
  }
}

// MARK: - Registry

/// Element ids handed out by the find routes, WDA style. Entries keep the node they were found
/// as; reads re-snapshot the live element so rects and values are fresh. Each node retains its
/// whole tree (parents, AX elements), so entries are bounded by count and dropped by age when the
/// screen may have changed.
final class ElementRegistry {
  /// `root` holds the node's tree: `UINode.parent` is weak, and occlusion checks walk ancestors.
  private var entries: [String: (node: UINode, root: UINode, at: Date)] = [:]
  private var order: [String] = []
  let capacity: Int
  /// Ids older than this are dropped at the next screen-changing request. Callers use an id
  /// right after finding it; an old one points at a screen that is likely gone.
  static let maxAgeSeconds = 60.0

  init(capacity: Int = 1000) { self.capacity = capacity }

  var count: Int { entries.count }

  func register(_ node: UINode, now: Date = Date()) -> String {
    let id = UUID().uuidString
    var root = node
    while let parent = root.parent { root = parent }
    entries[id] = (node, root, now)
    order.append(id)
    if order.count > capacity {
      let drop = max(1, capacity / 4)
      for stale in order.prefix(drop) {
        entries.removeValue(forKey: stale)
        locators.removeValue(forKey: stale)
      }
      order.removeFirst(drop)
    }
    return id
  }

  func node(_ id: String) -> UINode? { entries[id]?.node }

  /// The WDA locator a top-level find used, kept so a click on an element a re-rendering list
  /// replaced can find the same element again (same predicate, same position) once.
  private var locators: [String: (using: String, value: String)] = [:]

  func setLocator(_ id: String, using: String, value: String) { locators[id] = (using, value) }

  func locator(_ id: String) -> (using: String, value: String)? {
    entries[id] == nil ? nil : locators[id]
  }

  /// Drops ids registered more than `maxAgeSeconds` before `now` (order is registration order).
  func prune(now: Date = Date()) {
    var cut = 0
    while cut < order.count, let entry = entries[order[cut]],
          now.timeIntervalSince(entry.at) > Self.maxAgeSeconds {
      entries.removeValue(forKey: order[cut])
      locators.removeValue(forKey: order[cut])
      cut += 1
    }
    if cut > 0 { order.removeFirst(cut) }
  }
}

/// Which processes an alert lookup has to look in. A system alert can sit in SpringBoard, in the
/// target being read, or in another active process: with a web sign-in sheet in front the target
/// is SafariViewService, while an alert can belong to the app underneath or to another view
/// service (hardware, 17 Pro Max: the `alert` action answered `no_alert` with an alert on screen,
/// because only SpringBoard and the sheet were searched).
enum AlertScan {
  /// SpringBoard first (system prompts), then the target, then every other active pid; no
  /// duplicates, no pid 0.
  static func candidatePIDs(springBoard: Int32?, target: Int32, active: [Int32]) -> [Int32] {
    var pids: [Int32] = []
    for pid in [springBoard ?? 0, target] + active where pid > 0 && !pids.contains(pid) {
      pids.append(pid)
    }
    return pids
  }

  /// The pids still to search after the target's own tree came back without an alert.
  static func othersThan(target: Int32, in candidates: [Int32]) -> [Int32] {
    candidates.filter { $0 != target }
  }

  /// Levels read when only looking for an alert: alerts sit a few levels under the window, while
  /// a full read of an app's content can be thousands of nodes.
  static let shallowDepth = 12

  /// The first alert in a tree read to `maxDepth` node levels, and whether the depth cap may have
  /// cut its subtree (a childless node on the deepest level can be one whose children the AX
  /// server withheld), in which case the caller reads the full depth.
  static func firstAlert(in root: [String: Any], maxDepth: Int) -> (alert: [String: Any], maybeCut: Bool)? {
    func find(_ node: [String: Any], _ depth: Int) -> (node: [String: Any], depth: Int)? {
      if node["type"] as? String == "XCUIElementTypeAlert" { return (node, depth) }
      for child in node["children"] as? [[String: Any]] ?? [] {
        if let found = find(child, depth + 1) { return found }
      }
      return nil
    }
    func reachesCap(_ node: [String: Any], _ depth: Int) -> Bool {
      let children = node["children"] as? [[String: Any]] ?? []
      if children.isEmpty { return depth >= maxDepth - 1 }
      return children.contains { reachesCap($0, depth + 1) }
    }
    guard let found = find(root, 0) else { return nil }
    return (found.node, reachesCap(found.node, found.depth))
  }
}

/// System view services that present another process's UI over the app: the in-app Safari sheet
/// (SFSafariViewController) and the web sign-in sheet (ASWebAuthenticationSession) both run in
/// SafariViewService. The app underneath only hosts a remote view, so neither its private-AX tree
/// nor its XCUI snapshot reaches the form (hardware, 17 Pro Max: GitHub's sign-in sheet showed only
/// the keyboard's toolbar buttons).
enum ViewService {
  static let bundleIDs = ["com.apple.SafariViewService"]

  /// The view service to read and drive instead of the foreground app, if one is presenting:
  /// the first listed service running in the foreground, unless it already is the foreground app.
  static func overlay(foregroundBundle: String?, isPresenting: (String) -> Bool) -> String? {
    bundleIDs.first { $0 != foregroundBundle && isPresenting($0) }
  }
}

// MARK: - Expanded Dynamic Island

/// Amber's continued-processing task is shown by iOS as an expanded Dynamic Island the moment
/// Amber goes to the background (hardware, iOS 26: a full-width "Amber / 正在生成回复" pill over
/// the top of the screen). It covers the target app's top bar, so the runner collapses it with an
/// upward swipe; the task keeps running in the compact island.
enum ExpandedIsland {
  static let defaultTitle = "Amber"

  /// The collapsing swipe, or nil when SpringBoard shows no expanded island titled `title`.
  /// The title node must sit inside a full-width pill hugging the top of the screen: the compact
  /// island, a notification banner and home-screen icons (or their labels) never qualify.
  static func collapseSwipe(springBoard: UINode, title: String, screen: CGSize) -> (from: CGPoint, to: CGPoint)? {
    guard screen.width > 0, !title.isEmpty else { return nil }
    let band = min(160, screen.height * 0.2)
    for node in springBoard.descendants()
    where (node.label?.hasPrefix(title) ?? false) || node.identifier == title {
      var pill: UINode?
      var current: UINode? = node
      while let candidate = current, candidate.type != "XCUIElementTypeIcon" {
        if isExpandedPill(candidate.rect, screen: screen, band: band) { pill = candidate }
        current = candidate.parent
      }
      // Reached an icon (or its label inside one): not an island.
      guard current == nil, let pill else { continue }
      let x = screen.width / 2
      return (CGPoint(x: x, y: max(pill.rect.midY, 30)), CGPoint(x: x, y: 4))
    }
    return nil
  }

  private static func isExpandedPill(_ rect: CGRect, screen: CGSize, band: CGFloat) -> Bool {
    rect.width >= screen.width * 0.8 && rect.width < screen.width && rect.minY < 30
      && rect.height >= 60 && rect.maxY <= band
  }
}

// MARK: - Occlusion

/// Whether the topmost element at a target's centre is the target. The private AX tree also
/// holds views covered by a pushed page (hardware, 小米办公: a group's settings page over its
/// chat kept the chat's input and "发送" in the tree), and a tap at a covered element's
/// centre lands on whatever is on top. Only positive evidence refuses: an unreadable hit, or
/// an unlabeled container that wraps the target (custom-drawn UIs), lets the tap through.
enum Occlusion {
  /// A description of the covering element, or nil when the tap would reach the target.
  /// `target` carries its fresh subtree; `ancestors` are the target's ancestors in the tree it
  /// was found in (the hit test usually answers the accessible cell, not the label inside it).
  /// `hitIsOtherApp` is true only for SpringBoard or another active app: web content and
  /// keyboards answer from helper processes and are judged like the app's own views.
  static func blocker(target: UINode, ancestors: [UINode] = [], hit: UINode, hitIsOtherApp: Bool,
                      screen: CGSize = .zero) -> String? {
    let hitRect = hit.rect
    guard hitRect.width > 0, hitRect.height > 0 else { return nil }
    if ([target] + target.descendants() + ancestors).contains(where: { sameElement($0, hit) }) { return nil }
    if hitIsOtherApp { return describe(hit) + " in another app" }
    // A labeled full-screen layer (a watermark) is everywhere; it is no evidence.
    if screen.width > 0, hitRect.width * hitRect.height >= screen.width * screen.height * 0.9 { return nil }
    let targetRect = target.rect
    if hitRect.insetBy(dx: -1, dy: -1).contains(targetRect) {
      // Wraps the target: its own container (a cell around a label), unless it is a large
      // labeled element of another page that happens to span it.
      if hit.label == nil && hit.identifier == nil { return nil }
      let targetArea = max(1, targetRect.width * targetRect.height)
      if hitRect.width * hitRect.height <= targetArea * 4 { return nil }
    }
    return describe(hit)
  }

  static func sameElement(_ a: UINode, _ b: UINode) -> Bool {
    // A registered ancestor's snapshot keeps its old frame after scrolling.
    if let aElement = a.axElement, let bElement = b.axElement, aElement.isEqual(bElement) { return true }
    return a.type == b.type && a.label == b.label && a.identifier == b.identifier
      && abs(a.rect.minX - b.rect.minX) <= 1 && abs(a.rect.minY - b.rect.minY) <= 1
      && abs(a.rect.width - b.rect.width) <= 1 && abs(a.rect.height - b.rect.height) <= 1
  }

  static func describe(_ node: UINode) -> String {
    let type = node.type.replacingOccurrences(of: "XCUIElementType", with: "")
    let r = node.rect
    let frame = "[\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))]"
    if let name = node.label ?? node.identifier { return "\(type) \"\(name)\" \(frame)" }
    return "\(type) \(frame)"
  }
}

/// Pages stacked in one tree (a pushed page over the one below, both still in the AX tree).
/// A page is a near-full-screen node with no near-full-screen descendant; when two or more
/// overlap, a few hit tests vote for the page on top and the others are marked covered.
enum CoveredPages {
  /// Child-index paths of the pages, in document order.
  static func pages(_ root: UINode, screen: CGSize) -> [[Int]] {
    guard screen.width > 0, screen.height > 0 else { return [] }
    func isPage(_ node: UINode) -> Bool {
      node.rect.width >= screen.width * 0.9 && node.rect.height >= screen.height * 0.5
    }
    var found: [[Int]] = []
    func walk(_ node: UINode, _ path: [Int]) -> Bool {
      var below = false
      for (index, child) in node.children.enumerated() where walk(child, path + [index]) { below = true }
      guard isPage(node) else { return below }
      if !below, !path.isEmpty { found.append(path) }
      return true
    }
    _ = walk(root, [])
    return found
  }

  static func node(_ root: UINode, at path: [Int]) -> UINode? {
    var node = root
    for index in path {
      guard index < node.children.count else { return nil }
      node = node.children[index]
    }
    return node
  }

  /// The branches to mark covered: for every page overlapping the voted top page by more than
  /// half, the subtree that splits off from the top page at their lowest common ancestor, so
  /// the hidden page's own nav bar and input bar (siblings of its scroll view) are included.
  /// `hits` are the elements found on top at the probe points; nil when no page wins.
  static func covered(_ root: UINode, pages: [[Int]], hits: [UINode]) -> (branches: [[Int]], top: CGRect)? {
    guard pages.count >= 2 else { return nil }
    var votes = [Int](repeating: 0, count: pages.count)
    for hit in hits {
      for (index, path) in pages.enumerated() {
        guard let page = node(root, at: path) else { continue }
        if ([page] + page.descendants()).contains(where: { Occlusion.sameElement($0, hit) }) {
          votes[index] += 1
          break
        }
      }
    }
    guard let best = votes.max(), best > 0, votes.filter({ $0 == best }).count == 1,
          let top = votes.firstIndex(of: best), let topRect = node(root, at: pages[top])?.rect
    else { return nil }
    let topPath = pages[top]
    var branches: [[Int]] = []
    for (index, path) in pages.enumerated() where index != top {
      guard let rect = node(root, at: path)?.rect else { continue }
      let overlap = rect.intersection(topRect)
      guard overlap.width * overlap.height > rect.width * rect.height / 2 else { continue }
      let shared = zip(path, topPath).prefix { $0 == $1 }.count
      guard shared < path.count else { continue }  // the top page lies inside it
      let branch = Array(path.prefix(shared + 1))
      if !branches.contains(branch) { branches.append(branch) }
    }
    return (branches, topRect)
  }

  /// Up to `limit` labeled, on-screen descendants of a candidate page whose centres are probed:
  /// a transparent full-screen overlay (a floating toolbar's container) answers its own
  /// controls and is not covered.
  /// Samples lie under the top page (`within`): a medium-detent sheet covers only part of the page.
  static func samples(_ page: UINode, within: CGRect, screen: CGSize, limit: Int = 2) -> [UINode] {
    Array(page.descendants().filter { node in
      (node.label != nil || node.identifier != nil) && node.rect.width > 0 && node.rect.height > 0
        && TapBounds.onScreen(node.center, screen) && within.contains(node.center)
    }.prefix(limit))
  }

  /// `raw` with `isCovered: "1"` on every node under each covered path.
  static func marking(_ raw: [String: Any], covered: [[Int]]) -> [String: Any] {
    func markAll(_ node: [String: Any]) -> [String: Any] {
      var node = node
      node["isCovered"] = "1"
      if let children = node["children"] as? [[String: Any]] { node["children"] = children.map(markAll) }
      return node
    }
    func apply(_ node: [String: Any], _ paths: [[Int]]) -> [String: Any] {
      if paths.contains(where: \.isEmpty) { return markAll(node) }
      guard var children = node["children"] as? [[String: Any]] else { return node }
      var node = node
      for index in Set(paths.map(\.first!)) where index < children.count {
        children[index] = apply(children[index], paths.filter { $0.first == index }.map { Array($0.dropFirst()) })
      }
      node["children"] = children
      return node
    }
    return covered.isEmpty ? raw : apply(raw, covered)
  }
}
