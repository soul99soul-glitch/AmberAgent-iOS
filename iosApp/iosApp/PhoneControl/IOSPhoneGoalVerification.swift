import AmberPhoneControl
import Foundation

struct IOSPhoneGoalVerificationResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case satisfied, unmet, insufficient }

    let status: Status
    let reason: String
    let needsScreenshot: Bool

    enum CodingKeys: String, CodingKey {
        case status, reason
        case needsScreenshot = "needs_screenshot"
    }
}

enum IOSPhoneGoalVerification {
    static func evaluate(action: PhoneAction, expectation: IOSPhoneGoalExpectation,
                         before: PhoneObservation?, after: PhoneObservation) -> IOSPhoneGoalVerificationResult {
        if case .launch(let bundleID) = action {
            guard after.bundleID == bundleID else {
                return .init(status: .insufficient, reason: "launched_app_not_foreground", needsScreenshot: false)
            }
            // Launch intentionally changes the foreground App. An old App's tree
            // cannot provide before-evidence, especially for an absence condition.
            return evaluate(expectation: expectation, before: nil, after: after)
        }
        return evaluate(expectation: expectation, before: before, after: after)
    }

    static func hasMeaningfulChange(before: PhoneObservation, after: PhoneObservation) -> Bool {
        // Different collectors may expose different nodes for an unchanged screen.
        guard before.backend == after.backend else { return false }
        guard before.bundleID == after.bundleID, before.processID == after.processID,
              before.truncated == after.truncated, before.screenBounds == after.screenBounds,
              before.nodes.count == after.nodes.count else { return true }
        return zip(before.nodes, after.nodes).contains { lhs, rhs in
            lhs.depth != rhs.depth || lhs.type != rhs.type || lhs.identifier != rhs.identifier
                || lhs.label != rhs.label || lhs.value != rhs.value || lhs.rect != rhs.rect
                || lhs.enabled != rhs.enabled || lhs.focused != rhs.focused
        }
    }

    static func evaluate(expectation: IOSPhoneGoalExpectation, before: PhoneObservation?,
                         after: PhoneObservation) -> IOSPhoneGoalVerificationResult {
        func result(_ status: IOSPhoneGoalVerificationResult.Status, _ reason: String,
                    screenshot: Bool = false) -> IOSPhoneGoalVerificationResult {
            .init(status: status, reason: reason, needsScreenshot: screenshot)
        }
        guard (try? expectation.validate()) != nil else {
            return result(.insufficient, "invalid_expectation")
        }
        if let before {
            guard before.bundleID == after.bundleID, before.processID == after.processID else {
                return result(.insufficient, "foreground_app_changed")
            }
            guard before.observationID != after.observationID else {
                return result(.insufficient, "fresh_observation_required")
            }
            guard before.backend == after.backend else {
                return result(.insufficient, "observation_backend_changed", screenshot: true)
            }
        }
        guard let bounds = validScreenBounds(after) else {
            return result(.insufficient, "screen_bounds_unavailable", screenshot: true)
        }
        guard after.nodes.contains(where: { hasVisibleFrame($0, within: bounds) }) else {
            return result(.insufficient, "empty_tree", screenshot: true)
        }
        let matches = matchingNodes(target: expectation.target, in: after)
        guard matches.count <= 1 else {
            return result(.insufficient, "ambiguous_target", screenshot: true)
        }
        switch expectation.kind {
        case .visible:
            return matches.isEmpty
                ? result(after.truncated ? .insufficient : .unmet,
                         after.truncated ? "truncated_tree" : "target_not_visible", screenshot: true)
                : result(.satisfied, "target_visible")
        case .enabled:
            guard let node = matches.first else {
                return result(after.truncated ? .insufficient : .unmet,
                              after.truncated ? "truncated_tree" : "target_not_visible", screenshot: true)
            }
            return node.enabled ? result(.satisfied, "target_enabled") : result(.unmet, "target_disabled")
        case .absent:
            guard matches.isEmpty else { return result(.unmet, "target_still_visible") }
            guard !after.truncated else { return result(.insufficient, "truncated_tree", screenshot: true) }
            guard let before else { return result(.insufficient, "before_observation_required", screenshot: true) }
            guard validScreenBounds(before) != nil else {
                return result(.insufficient, "previous_screen_bounds_unavailable", screenshot: true)
            }
            guard before.screenBounds == after.screenBounds else {
                return result(.insufficient, "screen_bounds_changed", screenshot: true)
            }
            let previous = matchingNodes(target: expectation.target, in: before)
            guard previous.count == 1 else {
                return result(.insufficient, previous.isEmpty ? "target_not_previously_visible" : "ambiguous_previous_target",
                              screenshot: true)
            }
            guard let anchor = expectation.anchor,
                  matchingNodes(target: anchor, in: after).count == 1 else {
                return result(.insufficient, "visible_anchor_required", screenshot: true)
            }
            return result(.satisfied, "target_disappeared_with_visible_anchor")
        case .valueEquals:
            guard !after.truncated else { return result(.insufficient, "truncated_tree", screenshot: true) }
            guard let node = matches.first else { return result(.unmet, "input_not_visible", screenshot: true) }
            guard isTextInput(node) else { return result(.insufficient, "readable_text_input_required", screenshot: true) }
            guard let value = node.value else { return result(.insufficient, "input_value_unavailable", screenshot: true) }
            return value == expectation.value
                ? result(.satisfied, "input_value_matches")
                : result(.unmet, "input_value_differs")
        }
    }

    /// Geometry excludes offscreen nodes and nodes covered by a pushed page; it cannot
    /// establish other occlusion or hittability.
    /// The runner still resolves an actionable ref immediately before acting.
    static func matchingNodes(target: IOSPhoneGoalTarget, in observation: PhoneObservation,
                              executable: Bool = false) -> [PhoneObservationNode] {
        matchingNodeIndices(target: target, in: observation, executable: executable).map(\.node)
    }

    /// Same matching as `matchingNodes`, keeping each match's tree index for context descriptions.
    static func matchingNodeIndices(target: IOSPhoneGoalTarget, in observation: PhoneObservation,
                                    executable: Bool = false) -> [(node: PhoneObservationNode, index: Int)] {
        guard (try? target.validate()) != nil, let bounds = validScreenBounds(observation) else { return [] }
        let matches = observation.nodes.enumerated().filter { _, node in
            hasVisibleFrame(node, within: bounds)
                && (target.label == nil || node.label == target.label)
                && (target.identifier == nil || node.identifier == target.identifier)
                && (target.type == nil || node.type == target.type)
                && center(of: node, within: bounds, fallsInside: target.region)
                && (!executable || (node.enabled && node.ref?.isEmpty == false))
        }
        // A control often exposes its label both on the control and on a nested
        // StaticText. Keep the control match, while preserving same-label
        // controls in other branches or positions as real ambiguity.
        guard target.type == nil else { return matches.map { (node: $0.element, index: $0.offset) } }
        return collapseLabelChildMatches(matches, in: observation)
    }

    /// Removes only a named StaticText that is a DFS descendant of a matching
    /// named control whose frame contains it. The depth stack checks active
    /// ancestry only, keeping sibling matches distinct without rescanning the tree.
    static func collapseLabelChildMatches(
        _ matches: [(offset: Int, element: PhoneObservationNode)],
        in observation: PhoneObservation
    ) -> [(node: PhoneObservationNode, index: Int)] {
        let matchingIndices = Set(matches.map { $0.offset })
        var ancestors: [Int] = []
        var childIndices = Set<Int>()
        for (index, node) in observation.nodes.enumerated() {
            while let last = ancestors.last, observation.nodes[last].depth >= node.depth {
                ancestors.removeLast()
            }
            if matchingIndices.contains(index), node.type == "XCUIElementTypeStaticText",
               let label = node.label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               ancestors.contains(where: { parentIndex in
                   let parent = observation.nodes[parentIndex]
                   return matchingIndices.contains(parentIndex) && parent.type != "XCUIElementTypeStaticText"
                       && parent.label == label && rectContains(parent.rect, node.rect)
               }) {
                childIndices.insert(index)
            }
            ancestors.append(index)
        }

        return matches.compactMap { match in
            childIndices.contains(match.offset) ? nil : (node: match.element, index: match.offset)
        }
    }

    static func isTextInput(_ node: PhoneObservationNode) -> Bool {
        ["XCUIElementTypeTextField", "XCUIElementTypeTextView", "XCUIElementTypeSearchField"].contains(node.type)
    }

    static func validScreenBounds(_ observation: PhoneObservation) -> PhoneElementRect? {
        guard let bounds = observation.screenBounds,
              [bounds.x, bounds.y, bounds.width, bounds.height, bounds.x + bounds.width,
               bounds.y + bounds.height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    static func hasVisibleFrame(_ node: PhoneObservationNode, within bounds: PhoneElementRect) -> Bool {
        let frame = node.rect
        return node.depth > 0 && !node.covered && [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
            && frame.x < bounds.x + bounds.width && frame.y < bounds.y + bounds.height
            && frame.x + frame.width > bounds.x && frame.y + frame.height > bounds.y
    }

    private static func rectContains(_ parent: PhoneElementRect, _ child: PhoneElementRect) -> Bool {
        parent.x <= child.x && parent.y <= child.y
            && parent.x + parent.width >= child.x + child.width
            && parent.y + parent.height >= child.y + child.height
    }

    private static func center(of node: PhoneObservationNode, within bounds: PhoneElementRect,
                              fallsInside region: IOSPhoneGoalRegion?) -> Bool {
        guard let region else { return true }
        let frame = node.rect
        let x = (frame.x + frame.width / 2 - bounds.x) / bounds.width
        let y = (frame.y + frame.height / 2 - bounds.y) / bounds.height
        return x >= region.x && x <= region.x + region.width
            && y >= region.y && y <= region.y + region.height
    }
}
