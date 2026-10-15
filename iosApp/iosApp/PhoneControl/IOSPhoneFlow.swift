import AmberPhoneControl
import Foundation

struct IOSPhoneFlowRequest: Codable, Equatable, Sendable {
    struct Step: Codable, Equatable, Sendable {
        let operation: IOSPhoneGoalActionSpec
        let expectation: IOSPhoneGoalExpectation
    }

    let goal: String
    let bundleID: String
    let steps: [Step]
    let completion: IOSPhoneGoalExpectation

    enum CodingKeys: String, CodingKey {
        case goal, steps, completion
        case bundleID = "bundle_id"
    }

    func validate() throws {
        try IOSPhoneGoalValidationError.requireText(goal, maximum: 1_000, field: "goal")
        try IOSPhoneGoalValidationError.requireText(bundleID, maximum: 255, field: "bundle_id")
        guard bundleID.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw IOSPhoneGoalValidationError.invalid("bundle_id cannot contain whitespace.")
        }
        guard (1...12).contains(steps.count) else {
            throw IOSPhoneGoalValidationError.invalid("A flow needs 1–12 ordered steps.")
        }
        for step in steps {
            try step.operation.validate()
            try step.expectation.validate()
        }
        try completion.validate()
    }
}

/// Executes the caller's explicit order. Fresh semantic targets and per-step
/// postconditions replace remote selection; an acknowledged action is never replayed.
@MainActor
final class IOSPhoneFlow {
    struct Dependencies {
        var observe: () async throws -> PhoneObservation
        var act: (PhoneAction) async -> PhoneActionResult
        var isCurrent: () -> Bool
        var reportActivity: (AgentPhoneControlActivityPhase) async -> Void
        var observeAfterAction: (() async throws -> PhoneObservation)? = nil
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(300)) }
    }

    struct StepReceipt: Encodable, Equatable, Sendable {
        let index: Int
        let outcome: String
        var verification: IOSPhoneGoalVerificationResult?
    }

    struct Metrics: Encodable, Equatable, Sendable {
        var totalMs: Double = 0
        var actionMs: Double = 0
        var observationMs: Double = 0
        var waitMs: Double = 0
        var actionCount = 0
        var observationCount = 0

        enum CodingKeys: String, CodingKey {
            case totalMs = "total_ms", actionMs = "action_ms"
            case observationMs = "observation_ms", waitMs = "wait_ms"
            case actionCount = "action_count", observationCount = "observation_count"
        }
    }

    struct Result {
        enum Status: String { case completed, handback, unknown }
        let status: Status
        let reason: String
        let steps: [StepReceipt]
        let observation: PhoneObservation?
        let needsScreenshot: Bool
        let unknownProblem: PhoneControlProblem?
        let metrics: Metrics
        let verification: IOSPhoneGoalVerificationResult?
    }

    private struct Interrupted: Error {
        let reason: String
        var needsScreenshot = false
    }

    private let deps: Dependencies
    init(deps: Dependencies) { self.deps = deps }

    func run(_ request: IOSPhoneFlowRequest) async -> Result {
        let started = deps.now()
        var current: PhoneObservation?
        var initial: PhoneObservation?
        var lastBefore: PhoneObservation?
        var seenObservations = Set<String>()
        var receipts: [StepReceipt] = []
        var metrics = Metrics()
        var verification: IOSPhoneGoalVerificationResult?

        func result(_ status: Result.Status, _ reason: String, screenshot: Bool = false,
                    unknown: PhoneControlProblem? = nil) -> Result {
            metrics.totalMs = max(0, (deps.now() - started) * 1_000)
            return .init(status: status, reason: reason, steps: receipts, observation: current,
                         needsScreenshot: screenshot, unknownProblem: unknown, metrics: metrics,
                         verification: verification)
        }
        func stopReason() -> String? {
            guard !Task.isCancelled, deps.isCurrent() else { return "task_stopped" }
            return deps.now() - started >= 60 ? "time_budget_exhausted" : nil
        }
        func checkCurrent() throws {
            if let reason = stopReason() { throw Interrupted(reason: reason) }
        }
        func observe(afterAction: Bool = false) async throws -> PhoneObservation {
            try checkCurrent()
            // Starting a read invalidates the previously actionable snapshot. A
            // failed read must not expose an old ref as the flow's current screen.
            current = nil
            let began = deps.now()
            metrics.observationCount += 1
            defer { metrics.observationMs += max(0, (deps.now() - began) * 1_000) }
            let observation: PhoneObservation
            if afterAction, let settled = deps.observeAfterAction {
                observation = try await settled()
            } else {
                observation = try await deps.observe()
            }
            try checkCurrent()
            guard !observation.observationID.isEmpty,
                  seenObservations.insert(observation.observationID).inserted else {
                throw Interrupted(reason: "fresh_observation_required")
            }
            guard observation.bundleID == request.bundleID, observation.processID > 0 else {
                throw Interrupted(reason: "foreground_app_changed")
            }
            if let initial {
                guard observation.processID == initial.processID else {
                    throw Interrupted(reason: "foreground_app_changed")
                }
                guard observation.backend == initial.backend else {
                    throw Interrupted(reason: "observation_backend_changed", needsScreenshot: true)
                }
                guard observation.screenBounds == initial.screenBounds else {
                    throw Interrupted(reason: "screen_bounds_changed", needsScreenshot: true)
                }
            } else {
                initial = observation
            }
            current = observation
            return observation
        }
        func act(_ action: PhoneAction) async -> PhoneActionResult {
            let began = deps.now()
            metrics.actionCount += 1
            defer { metrics.actionMs += max(0, (deps.now() - began) * 1_000) }
            return await deps.act(action)
        }
        func wait() async throws {
            let began = deps.now()
            defer { metrics.waitMs += max(0, (deps.now() - began) * 1_000) }
            try await deps.wait()
        }

        do {
            try request.validate()
            try checkCurrent()
            await deps.reportActivity(.observing)
            _ = try await observe()

            for (index, step) in request.steps.enumerated() {
                try checkCurrent()
                guard let before = current,
                      let candidate = IOSPhoneGoalLoop.candidates([step.operation], in: before).first else {
                    return result(.handback, "step_not_executable", screenshot: true)
                }
                await deps.reportActivity(IOSPhoneControlToolExecutor.actionActivity(candidate.action))
                try checkCurrent()
                current = nil
                switch await act(candidate.action) {
                case .unknown(let problem):
                    receipts.append(.init(index: index, outcome: "unknown"))
                    return result(.unknown, problem.message, unknown: problem)
                case .unsent(let problem):
                    receipts.append(.init(index: index, outcome: "unsent"))
                    return result(.handback, "action_not_sent: \(problem.message)")
                case .completed:
                    receipts.append(.init(index: index, outcome: "completed"))
                }
                lastBefore = before
                try checkCurrent()
                await deps.reportActivity(.verifying)
                var firstRead = true
                let checked = try await IOSPhoneActionVerification.check(
                    action: candidate.action, expectation: step.expectation, before: before,
                    dependencies: .init(
                        observe: {
                            let useSettled = firstRead
                            firstRead = false
                            return try await observe(afterAction: useSettled)
                        },
                        isCurrent: { stopReason() == nil },
                        reportWaiting: { await self.deps.reportActivity(.waitingForUI) },
                        now: deps.now,
                        wait: { try await wait() }
                    ))
                verification = checked.verification
                receipts[receipts.count - 1].verification = checked.verification
                try checkCurrent()
                guard checked.verification.status == .satisfied else {
                    return result(.handback, "step_verification_failed: \(checked.verification.reason)",
                                  screenshot: checked.verification.needsScreenshot)
                }
                // `current` is the verified new tree, including refs for the next
                // ordered step. No additional observation or Jev decision is needed.
            }

            try checkCurrent()
            guard let after = current else { return result(.handback, "fresh_observation_required") }
            verification = IOSPhoneGoalVerification.evaluate(
                expectation: request.completion, before: lastBefore, after: after)
            guard verification?.status == .satisfied else {
                return result(.handback, "completion_not_satisfied: \(verification?.reason ?? "evidence_unavailable")",
                              screenshot: verification?.needsScreenshot == true)
            }
            return result(.completed, "completed")
        } catch {
            current = nil
            if let interrupted = error as? Interrupted {
                return result(.handback, interrupted.reason, screenshot: interrupted.needsScreenshot)
            }
            if let reason = stopReason() { return result(.handback, reason) }
            return result(.handback, error is IOSPhoneGoalValidationError
                          ? "invalid_request: \(error.localizedDescription)"
                          : "observation_interrupted: \(error.localizedDescription)")
        }
    }
}
