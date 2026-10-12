import AmberPhoneControl
import Foundation

struct IOSPhoneScrollSearchRequest: Codable, Equatable, Sendable {
    let target: IOSPhoneGoalTarget
    let container: IOSPhoneGoalTarget
    let direction: IOSPhoneGoalActionSpec.Direction
    let maxSwipes: Int

    enum CodingKeys: String, CodingKey {
        case target, container, direction
        case maxSwipes = "max_swipes"
    }

    init(target: IOSPhoneGoalTarget, container: IOSPhoneGoalTarget,
         direction: IOSPhoneGoalActionSpec.Direction, maxSwipes: Int = 3) {
        self.target = target
        self.container = container
        self.direction = direction
        self.maxSwipes = maxSwipes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decode(IOSPhoneGoalTarget.self, forKey: .target)
        container = try values.decode(IOSPhoneGoalTarget.self, forKey: .container)
        direction = try values.decode(IOSPhoneGoalActionSpec.Direction.self, forKey: .direction)
        maxSwipes = try values.decodeIfPresent(Int.self, forKey: .maxSwipes) ?? 3
    }

    func validate() throws {
        try target.validate()
        try container.validate()
        guard (1...8).contains(maxSwipes) else {
            throw IOSPhoneGoalValidationError.invalid("max_swipes must be 1–8.")
        }
    }
}

/// Searches only the requested visible scroll container. Each acknowledged swipe
/// consumes its observation; a subsequent swipe needs a changed, fresh tree.
@MainActor
final class IOSPhoneScrollSearch {
    struct Dependencies {
        var observe: () async throws -> PhoneObservation
        var act: (PhoneAction) async -> PhoneActionResult
        var isCurrent: () -> Bool
        var reportActivity: (AgentPhoneControlActivityPhase) async -> Void
        var now: () -> Date = { Date() }
    }

    struct Result {
        enum Status: String { case completed, handback, unknown }
        var status: Status
        var reason: String
        var observation: PhoneObservation?
        var swipeCount: Int
        var unknownProblem: PhoneControlProblem?
    }

    private let deps: Dependencies
    init(deps: Dependencies) { self.deps = deps }

    func run(_ request: IOSPhoneScrollSearchRequest) async -> Result {
        let started = deps.now()
        var current: PhoneObservation?
        var previous: PhoneObservation?
        var observedIDs = Set<String>()
        var swipeCount = 0

        func result(_ status: Result.Status, _ reason: String,
                    unknown: PhoneControlProblem? = nil) -> Result {
            .init(status: status, reason: reason, observation: current,
                  swipeCount: swipeCount, unknownProblem: unknown)
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
                current = try await deps.observe()
                if let reason = stopReason() { return result(.handback, reason) }
                guard let observation = current, !observation.observationID.isEmpty,
                      observedIDs.insert(observation.observationID).inserted else {
                    return result(.handback, "fresh_observation_required")
                }
                guard !observation.truncated else { return result(.handback, "truncated_tree") }
                let verified = IOSPhoneGoalVerification.evaluate(
                    expectation: .init(kind: .visible, target: request.target), before: previous, after: observation)
                switch verified.status {
                case .satisfied: return result(.completed, "target_visible")
                case .insufficient: return result(.handback, verified.reason)
                case .unmet: break
                }
                if let previous, !IOSPhoneGoalVerification.hasMeaningfulChange(before: previous, after: observation) {
                    return result(.handback, "screen_unchanged")
                }
                guard swipeCount < request.maxSwipes else { return result(.handback, "swipe_budget_exhausted") }
                let containers = IOSPhoneGoalVerification.matchingNodes(target: request.container, in: observation)
                guard containers.count <= 1 else { return result(.handback, "ambiguous_container") }
                guard let container = containers.first else { return result(.handback, "container_not_visible") }
                let roles: Set<String> = ["XCUIElementTypeScrollView", "XCUIElementTypeTable", "XCUIElementTypeCollectionView"]
                guard roles.contains(container.type), container.enabled,
                      let ref = container.ref, !ref.isEmpty else {
                    return result(.handback, "actionable_scroll_container_required")
                }
                guard let direction = PhoneSwipeDirection(rawValue: request.direction.rawValue) else {
                    return result(.handback, "invalid_swipe_direction")
                }
                await deps.reportActivity(.swiping)
                if let reason = stopReason() { return result(.handback, reason) }
                current = nil // act consumes this snapshot, including a refusal.
                switch await deps.act(.swipe(ref: ref, direction: direction)) {
                case .unknown(let problem):
                    swipeCount += 1
                    // Preserve uncertainty for the caller's ledger; never observe or replay.
                    return result(.unknown, problem.message, unknown: problem)
                case .unsent(let problem):
                    return result(.handback, "swipe_not_sent: \(problem.message)")
                case .completed:
                    swipeCount += 1
                    previous = observation
                }
            }
        } catch {
            current = nil
            return result(.handback, "scroll_search_interrupted: \(error.localizedDescription)")
        }
    }
}
