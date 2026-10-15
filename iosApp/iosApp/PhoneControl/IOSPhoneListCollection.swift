import AmberPhoneControl
import Foundation

struct IOSPhoneListCollectionRequest: Codable, Equatable, Sendable {
    let container: IOSPhoneGoalTarget
    let direction: IOSPhoneGoalActionSpec.Direction
    let maxSwipes: Int
    let maxItems: Int

    enum CodingKeys: String, CodingKey {
        case container, direction
        case maxSwipes = "max_swipes"
        case maxItems = "max_items"
    }

    init(container: IOSPhoneGoalTarget, direction: IOSPhoneGoalActionSpec.Direction,
         maxSwipes: Int = 3, maxItems: Int = 50) {
        self.container = container
        self.direction = direction
        self.maxSwipes = maxSwipes
        self.maxItems = maxItems
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        container = try values.decode(IOSPhoneGoalTarget.self, forKey: .container)
        direction = try values.decode(IOSPhoneGoalActionSpec.Direction.self, forKey: .direction)
        maxSwipes = try values.decodeIfPresent(Int.self, forKey: .maxSwipes) ?? 3
        maxItems = try values.decodeIfPresent(Int.self, forKey: .maxItems) ?? 50
    }

    func validate() throws {
        try container.validate()
        guard direction == .up || direction == .down else {
            throw IOSPhoneGoalValidationError.invalid("List collection supports vertical up/down swipes.")
        }
        guard (0...8).contains(maxSwipes), (1...200).contains(maxItems) else {
            throw IOSPhoneGoalValidationError.invalid("max_swipes must be 0–8 and max_items must be 1–200.")
        }
    }
}

/// Collects readable rows from one container, in natural reading order. Only
/// adjacent page overlap with stable row identifiers is removed. Anonymous rows
/// remain as observed, including equal text that may represent distinct items.
@MainActor
final class IOSPhoneListCollection {
    struct Dependencies {
        var observe: () async throws -> PhoneObservation
        var act: (PhoneAction) async -> PhoneActionResult
        var isCurrent: () -> Bool
        var reportActivity: (AgentPhoneControlActivityPhase) async -> Void
        var observeAfterAction: (() async throws -> PhoneObservation)? = nil
        var now: () -> Date = { Date() }
    }

    struct Item: Encodable, Equatable, Sendable {
        let text: String
        let identifier: String?
    }

    struct Result {
        enum Status: String { case completed, handback, unknown }
        enum Coverage: String, Encodable { case observedScreensOnly = "observed_screens_only" }
        enum Deduplication: String, Encodable { case stableIdentityOnly = "stable_identity_only" }

        let status: Status
        let reason: String
        let items: [Item]
        let observation: PhoneObservation?
        let screenCount: Int
        let swipeCount: Int
        let coverage: Coverage
        let deduplication: Deduplication
        let reachedItemLimit: Bool
        let unknownProblem: PhoneControlProblem?
    }

    private struct Page {
        let items: [Item]
        let frames: [PhoneElementRect]
    }

    private let deps: Dependencies
    init(deps: Dependencies) { self.deps = deps }

    func run(_ request: IOSPhoneListCollectionRequest) async -> Result {
        let started = deps.now()
        var current: PhoneObservation?
        var previous: PhoneObservation?
        var previousPage: Page?
        var seenObservations = Set<String>()
        var items: [Item] = []
        var screens = 0
        var swipes = 0

        func result(_ status: Result.Status, _ reason: String,
                    unknown: PhoneControlProblem? = nil) -> Result {
            .init(status: status, reason: reason, items: items, observation: current,
                  screenCount: screens, swipeCount: swipes, coverage: .observedScreensOnly,
                  deduplication: .stableIdentityOnly,
                  reachedItemLimit: items.count >= request.maxItems, unknownProblem: unknown)
        }
        func stopReason() -> String? {
            guard !Task.isCancelled, deps.isCurrent() else { return "task_stopped" }
            return deps.now().timeIntervalSince(started) >= 60 ? "time_budget_exhausted" : nil
        }

        do {
            try request.validate()
            while true {
                if let reason = stopReason() { return result(.handback, reason) }
                await deps.reportActivity(previous == nil ? .observing : .verifying)
                if let reason = stopReason() { return result(.handback, reason) }
                if previous != nil, let observeAfterAction = deps.observeAfterAction {
                    current = try await observeAfterAction()
                } else {
                    current = try await deps.observe()
                }
                if let reason = stopReason() { return result(.handback, reason) }
                guard let observation = current, !observation.observationID.isEmpty,
                      seenObservations.insert(observation.observationID).inserted else {
                    return result(.handback, "fresh_observation_required")
                }
                screens += 1
                guard !observation.truncated else { return result(.handback, "truncated_tree") }
                guard !observation.bundleID.isEmpty, observation.processID > 0 else {
                    return result(.handback, "foreground_app_unavailable")
                }
                guard let bounds = Self.validBounds(observation.screenBounds) else {
                    return result(.handback, "screen_bounds_unavailable")
                }
                if let previous {
                    guard previous.bundleID == observation.bundleID, previous.processID == observation.processID else {
                        return result(.handback, "foreground_app_changed")
                    }
                    guard previous.backend == observation.backend else {
                        return result(.handback, "observation_backend_changed")
                    }
                    guard previous.screenBounds == observation.screenBounds else {
                        return result(.handback, "screen_bounds_changed")
                    }
                }
                let containers = IOSPhoneGoalVerification.matchingNodes(target: request.container, in: observation)
                guard containers.count <= 1 else { return result(.handback, "ambiguous_container") }
                guard let container = containers.first,
                      let index = observation.nodes.firstIndex(of: container) else {
                    return result(.handback, "container_not_visible")
                }
                guard ["XCUIElementTypeScrollView", "XCUIElementTypeTable", "XCUIElementTypeCollectionView"]
                    .contains(container.type) else {
                    return result(.handback, "scroll_container_required")
                }
                let page = Self.readPage(in: observation, containerIndex: index, bounds: bounds)
                guard !page.items.isEmpty else { return result(.handback, "readable_rows_required") }
                if let previousPage {
                    if previousPage.items == page.items, previousPage.frames == page.frames {
                        // A new tree/ref is not evidence that the list advanced or reached its end.
                        return result(.handback, "screen_unchanged")
                    }
                    let tail = request.direction == .up ? previousPage.items : page.items
                    let head = request.direction == .up ? page.items : previousPage.items
                    let overlap = Self.overlap(tail: tail, head: head)
                    guard !overlap.ambiguous else { return result(.handback, "ambiguous_overlap") }
                    if request.direction == .up {
                        items.append(contentsOf: page.items.dropFirst(overlap.count))
                        items = Array(items.prefix(request.maxItems))
                    } else {
                        items.insert(contentsOf: page.items.dropLast(overlap.count), at: 0)
                        // Keep the rows nearest the starting screen when collecting upward.
                        items = Array(items.suffix(request.maxItems))
                    }
                } else {
                    items = Array(page.items.prefix(request.maxItems))
                }
                if items.count >= request.maxItems { return result(.completed, "item_limit_reached") }
                if swipes >= request.maxSwipes { return result(.completed, "swipe_budget_exhausted") }
                guard container.enabled, let ref = container.ref, !ref.isEmpty else {
                    return result(.handback, "actionable_scroll_container_required")
                }
                await deps.reportActivity(.swiping)
                if let reason = stopReason() { return result(.handback, reason) }
                current = nil
                let direction: PhoneSwipeDirection = request.direction == .up ? .up : .down
                switch await deps.act(.swipe(ref: ref, direction: direction)) {
                case .unknown(let problem):
                    swipes += 1
                    return result(.unknown, problem.message, unknown: problem)
                case .unsent(let problem):
                    return result(.handback, "swipe_not_sent: \(problem.message)")
                case .completed:
                    swipes += 1
                    previous = observation
                    previousPage = page
                }
            }
        } catch {
            current = nil
            return result(.handback, "list_collection_interrupted: \(error.localizedDescription)")
        }
    }

    private static func readPage(in observation: PhoneObservation, containerIndex: Int,
                                 bounds: PhoneElementRect) -> Page {
        let nodes = observation.nodes
        let container = nodes[containerIndex]
        let start = containerIndex + 1
        let end = nodes[start...].firstIndex(where: { $0.depth <= container.depth }) ?? nodes.endIndex
        let descendants = start..<end
        let cells = descendants.filter { nodes[$0].type == "XCUIElementTypeCell" }
        // SwiftUI ScrollViews can expose rows directly without Cell wrappers.
        let candidates = cells.isEmpty
            ? descendants.filter { nodes[$0].depth == container.depth + 1
                && nodes[$0].type != "XCUIElementTypeScrollBar" }
            : cells
        var rows: [(Item, PhoneElementRect)] = []
        var consumedEnd = start
        for index in candidates where index >= consumedEnd {
            let node = nodes[index]
            let rowEnd = nodes[(index + 1)..<end].firstIndex(where: { $0.depth <= node.depth }) ?? end
            consumedEnd = rowEnd
            guard visible(node.rect, within: bounds), visible(node.rect, within: container.rect) else { continue }
            var childText: [String] = []
            for descendant in nodes[(index + 1)..<rowEnd]
                where visible(descendant.rect, within: bounds) && visible(descendant.rect, within: container.rect) {
                childText.append(contentsOf: readableText(descendant))
            }
            // Cell labels can repeat their child text. Equal text from separate
            // children (for example quantity and price columns) remains separate.
            let text = readableText(node).filter { !childText.contains($0) } + childText
            guard !text.isEmpty else { continue }
            let identifier = node.identifier.flatMap { $0.isEmpty ? nil : $0 }
            rows.append((Item(text: text.joined(separator: "\n"), identifier: identifier), node.rect))
        }
        // AX traversal is normally ordered; frame order also handles grouped trees.
        rows.sort { lhs, rhs in
            lhs.1.y == rhs.1.y ? lhs.1.x < rhs.1.x : lhs.1.y < rhs.1.y
        }
        return Page(items: rows.map(\.0), frames: rows.map(\.1))
    }

    private static func readableText(_ node: PhoneObservationNode) -> [String] {
        let label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = node.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [label, value == label ? nil : value].compactMap { $0 }.filter { !$0.isEmpty }
    }

    private static func overlap(tail: [Item], head: [Item]) -> (count: Int, ambiguous: Bool) {
        let candidates = (1...min(tail.count, head.count)).filter { length in
            zip(tail.suffix(length), head.prefix(length)).allSatisfy { lhs, rhs in
                lhs.identifier?.isEmpty == false && lhs.identifier == rhs.identifier && lhs.text == rhs.text
            }
        }
        guard let count = candidates.first else { return (0, false) }
        guard candidates.count == 1 else { return (0, true) }
        // A reused accessibility identifier is not a stable row identity.
        guard tail.suffix(count).allSatisfy({ item in
            tail.filter { $0.identifier == item.identifier }.count == 1
                && head.filter { $0.identifier == item.identifier }.count == 1
        }) else { return (0, true) }
        return (count, false)
    }

    private static func validBounds(_ value: PhoneElementRect?) -> PhoneElementRect? {
        guard let value,
              [value.x, value.y, value.width, value.height, value.x + value.width, value.y + value.height]
                .allSatisfy(\.isFinite), value.width > 0, value.height > 0 else { return nil }
        return value
    }

    private static func visible(_ frame: PhoneElementRect, within bounds: PhoneElementRect) -> Bool {
        [frame.x, frame.y, frame.width, frame.height, frame.x + frame.width, frame.y + frame.height]
            .allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
            && frame.x < bounds.x + bounds.width && frame.y < bounds.y + bounds.height
            && frame.x + frame.width > bounds.x && frame.y + frame.height > bounds.y
    }
}
