import AmberPhoneControl
import Foundation

/// Waits for a completed action's visible effect. Only observations are repeated.
@MainActor
enum IOSPhoneActionVerification {
    struct Dependencies {
        var observe: () async throws -> PhoneObservation
        var isCurrent: () -> Bool
        var reportWaiting: () async -> Void
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(300)) }
    }

    struct Result {
        let observation: PhoneObservation
        let verification: IOSPhoneGoalVerificationResult
        let observations: Int
    }

    static func check(action: PhoneAction, expectation: IOSPhoneGoalExpectation,
                      before: PhoneObservation?, dependencies: Dependencies) async throws -> Result {
        let started = dependencies.now()
        var first: PhoneObservation?
        for index in 1...4 {
            try Task.checkCancellation()
            guard dependencies.isCurrent() else { throw CancellationError() }
            let after = try await dependencies.observe()
            try Task.checkCancellation()
            guard dependencies.isCurrent() else { throw CancellationError() }
            if let first, after.bundleID != first.bundleID || after.processID != first.processID {
                return Result(observation: after, verification: .init(
                    status: .insufficient, reason: "foreground_app_changed", needsScreenshot: false), observations: index)
            }
            if let first, after.backend != first.backend || after.screenBounds != first.screenBounds {
                return Result(observation: after, verification: .init(
                    status: .insufficient, reason: "observation_context_changed", needsScreenshot: true), observations: index)
            }
            if first == nil { first = after }
            let checked = IOSPhoneGoalVerification.evaluate(
                action: action, expectation: expectation, before: before, after: after)
            // Incomplete/ambiguous evidence needs replanning, not extra polling.
            guard checked.status == .unmet, index < 4,
                  dependencies.now() - started < 2 else {
                return Result(observation: after, verification: checked, observations: index)
            }
            await dependencies.reportWaiting()
            try Task.checkCancellation()
            guard dependencies.isCurrent() else { throw CancellationError() }
            try await dependencies.wait()
            try Task.checkCancellation()
            guard dependencies.isCurrent() else { throw CancellationError() }
            if dependencies.now() - started >= 2 {
                return Result(observation: after, verification: checked, observations: index)
            }
        }
        preconditionFailure("The bounded observation loop always returns.")
    }
}
