import AmberPhoneControl
import Foundation

/// One tool invocation owns this loop. The engine's existing side-effect ledger owns
/// interruption/recovery; a partly executed loop is never resumed or replayed here.
///
/// Hard lines that no recovery path relaxes: Jev only selects among locally built
/// candidates (it never supplies refs, coordinates or text); final commits are withheld
/// for the main model; an unknown receipt stops the loop; only the requested App's
/// process is ever acted on. Everything else deviating from the plan is recovered inside
/// the call (fresh observation, wait, new candidates) until progress stalls repeatedly.
@MainActor
final class IOSPhoneGoalLoop {
    /// Total wall-clock budget for one invocation. A background liveness heartbeat keeps
    /// the run alive this long; in-flight runner requests keep their own timeouts.
    nonisolated static let timeBudgetSeconds: TimeInterval = 180
    /// Consecutive rounds without a screen change (unchanged after an action, read-only
    /// waits, retried decisions) before the loop hands back.
    nonisolated static let noProgressLimit = 3
    /// Jev accepts at most 64 options including its three reserved ones.
    nonisolated static let defaultCandidateLimit = 61

    struct Dependencies {
        var observe: () async throws -> PhoneObservation
        var act: (PhoneAction, String?, PhoneElementRect?, Bool) async -> PhoneActionResult
        var choose: (String, PhoneObservation, [IOSJevPhoneControlService.Candidate], [String], IOSPhoneGoalExpectation?) async -> IOSJevPhoneControlService.Selection
        var advise: (String, IOSPhoneGoalExpectation, PhoneObservation?, PhoneObservation, IOSPhoneGoalVerificationResult) async -> IOSJevPhoneControlService.Advice
        var mode: () -> IOSJevMode
        var isCurrent: () -> Bool
        var reportActivity: (AgentPhoneControlActivityPhase) async -> Void
        var configurationRevision: () -> Int = { 0 }
        var now: () -> Date = { Date() }
        var waitForUI: () async throws -> Void = { try await Task.sleep(for: .milliseconds(400)) }
        var waitForStability: () async throws -> PhoneScreenStability = {
            throw IOSPhoneGoalValidationError.invalid("Screen stability is unavailable.")
        }
        var observeAfterAction: (() async throws -> PhoneObservation)? = nil
        /// Upper bound for locally generated candidates (policy.maxCandidates minus reserved options).
        var candidateLimit: () -> Int = { IOSPhoneGoalLoop.defaultCandidateLimit }
    }

    enum ReasonCode: String, Codable, Sendable {
        case completed
        case completionAlreadySatisfied = "completion_already_satisfied"
        case invalidRequest = "invalid_request"
        case taskStopped = "task_stopped"
        case configurationChanged = "configuration_changed"
        case timeBudgetExhausted = "time_budget_exhausted"
        case modeOff = "mode_off"
        case shadowMode = "shadow_mode"
        case foregroundAppChanged = "foreground_app_changed"
        case stepBudgetExhausted = "step_budget_exhausted"
        case treeTruncated = "tree_truncated"
        case actionsExhausted = "actions_exhausted"
        case noExecutableCandidates = "no_executable_candidates"
        case decisionHandback = "decision_handback"
        case screenshotRequired = "screenshot_required"
        case waitBudgetExhausted = "wait_budget_exhausted"
        case invalidDecision = "invalid_decision"
        case actionOutcomeUnknown = "action_outcome_unknown"
        case actionNotSent = "action_not_sent"
        case verificationHandback = "verification_handback"
        case screenUnchanged = "screen_unchanged"
        case iterationBudgetExhausted = "iteration_budget_exhausted"
        case observationInterrupted = "observation_interrupted"
        case pageChanged = "page_changed"
        case unexpectedAlert = "unexpected_alert"
        case ambiguousTarget = "ambiguous_target"
        case stepExpectationUnmet = "step_expectation_unmet"
        case screenNotStable = "screen_not_stable"
        /// The only remaining way forward is a withheld final commit (send, publish, pay,
        /// delete, sign in, permission grant). The main model performs it explicitly.
        case finalCommitRequired = "final_commit_required"
        /// Jev could not be consulted (off, out of scope, unconfigured, paused, out of budget).
        case jevUnavailable = "jev_unavailable"
        /// The Jev request failed (size, timeout, transport, HTTP, invalid response).
        case jevFailed = "jev_failed"
    }

    struct CandidateDiagnostic: Codable, Equatable, Sendable {
        enum ReasonCode: String, Codable, Sendable {
            case eligible
            case treeTruncated = "tree_truncated"
            case alreadyExecuted = "already_executed"
            case targetNotVisible = "target_not_visible"
            /// Several matches. In-loop resolution offers each match to Jev with context.
            case targetAmbiguous = "target_ambiguous"
            case disabled
            case referenceUnavailable = "reference_unavailable"
            case screenBoundsUnavailable = "screen_bounds_unavailable"
            case unsupported
            case inputValueUnavailable = "input_value_unavailable"
            case inputNotEmpty = "input_not_empty"
        }
        let id: String
        let reasonCode: ReasonCode

        enum CodingKeys: String, CodingKey {
            case id
            case reasonCode = "reason_code"
        }
    }

    struct Metrics: Codable, Equatable, Sendable {
        var observeMs: Double = 0
        var chooseMs: Double = 0
        var actMs: Double = 0
        var adviseMs: Double = 0
        var waitMs: Double = 0
        var totalMs: Double = 0
        // Service invocations, including local/shadow decisions; not outbound HTTP counts.
        var selectionCalls = 0
        var reviewCalls = 0
        var settleMs: Double = 0
        var settleCalls = 0
        var localActions = 0
        /// Rounds recovered in-call (re-read, wait, regenerated candidates) instead of handing back.
        var recoveries = 0

        enum CodingKeys: String, CodingKey {
            case observeMs = "observe_ms", chooseMs = "choose_ms"
            case actMs = "act_ms", adviseMs = "advise_ms"
            case waitMs = "wait_ms", totalMs = "total_ms"
            case selectionCalls = "selection_calls", reviewCalls = "review_calls"
            case settleMs = "settle_ms", settleCalls = "settle_calls", localActions = "local_actions"
            case recoveries
        }
    }

    struct Result {
        enum Status: String { case completed, handback, unknown }
        var status: Status
        var reason: String
        var reasonCode: ReasonCode
        var candidateDiagnostics: [CandidateDiagnostic]
        var metrics: Metrics
        var steps: [String]
        var observation: PhoneObservation?
        var verification: IOSPhoneGoalVerificationResult?
        var needsScreenshot = false
        var unknownProblem: PhoneControlProblem?
        var verifiedStepCount = 0
        var stepVerification: IOSPhoneGoalVerificationResult?
        /// Names of visible final-commit controls the loop deliberately did not offer to Jev.
        var withheldFinalActions: [String] = []
        /// Set when ordered steps deviated from the screen and the loop continued in goal mode.
        var continuedFrom: ReasonCode?
        /// Underlying Jev reason (e.g. request_too_large, timeout) when Jev was the cause.
        var jevReason: String?
    }

    struct Candidate {
        var id: String
        var spec: IOSPhoneGoalActionSpec
        var action: PhoneAction
        var decisionDescription: String? = nil
        /// Listed action this candidate realizes; duplicate matches of one spec share it.
        var specID: String? = nil
        /// Never executed without a Jev decision, even when it is the only candidate.
        var requiresDecision = false
        /// Ref-independent identity used to avoid repeating an ineffective action.
        var fingerprint = ""
        var receiptName: String? = nil
        /// Acted-on node in the observation this candidate was generated from.
        var nodeIndex: Int? = nil

        var decisionCandidate: IOSJevPhoneControlService.Candidate {
            let description: String
            if let decisionDescription {
                description = decisionDescription
            } else {
                let data = try! JSONEncoder().encode(spec)
                description = String(decoding: data, as: UTF8.self)
            }
            return .init(id: id, description: description, nodeIndex: nodeIndex)
        }

        var stepDescription: String {
            decisionDescription ?? id
        }
    }

    struct LiveCandidateSet {
        var candidates: [Candidate]
        var withheld: [String]
    }

    private struct Carry {
        var started: Date
        var configurationRevision: Int
        var steps: [String]
        var metrics: Metrics
        var current: PhoneObservation
        var beforeAction: PhoneObservation?
        var initial: PhoneObservation
        var actionCount: Int
        var verifiedStepCount: Int
        var stepVerification: IOSPhoneGoalVerificationResult?
        var reason: ReasonCode
        /// Controls whose dispatched action left the screen unchanged; never offered again.
        var ineffective: Set<String> = []
    }

    private let deps: Dependencies
    init(deps: Dependencies) { self.deps = deps }

    func run(_ request: IOSPhoneGoalRequest) async -> Result {
        if let sequence = request.steps { return await runSequence(request, sequence: sequence) }
        return await runGoal(request, carry: nil)
    }

    // MARK: Goal mode

    /// Listed actions (legacy root `actions`) or live candidates; also the continuation
    /// of ordered steps once the screen leaves the plan (`carry`).
    private func runGoal(_ request: IOSPhoneGoalRequest, carry: Carry?) async -> Result {
        let started = carry?.started ?? deps.now()
        let listed = !request.usesLiveCandidates && carry == nil
        // Live rounds act on refs generated from one tree; geometry must stay put.
        let strictGeometry = !listed
        // A settings change ends this invocation, including across read-only waits.
        let configurationRevision = carry?.configurationRevision ?? deps.configurationRevision()
        var steps = carry?.steps ?? []
        var current = carry?.current
        var beforeAction = carry?.beforeAction
        var initial = carry?.initial
        var verification: IOSPhoneGoalVerificationResult?
        var executed = Set<String>()
        var metrics = carry?.metrics ?? Metrics()
        var actionCount = carry?.actionCount ?? 0
        var noProgress = 0
        var ineffective = carry?.ineffective ?? []
        var withheld: [String] = []

        func result(_ status: Result.Status, _ reason: String, code: ReasonCode, screenshot: Bool = false,
                    unknown: PhoneControlProblem? = nil) -> Result {
            metrics.totalMs = max(0, deps.now().timeIntervalSince(started) * 1_000)
            let diagnostics = current.map { observation -> [CandidateDiagnostic] in
                guard listed, !Self.hasAlert(observation) else { return [] }
                return Self.resolveCandidates(request.actions, in: observation, excluding: executed).diagnostics
            } ?? []
            var value = Result(status: status, reason: reason, reasonCode: code,
                               candidateDiagnostics: diagnostics, metrics: metrics, steps: steps, observation: current,
                               verification: verification, needsScreenshot: screenshot, unknownProblem: unknown)
            value.withheldFinalActions = withheld
            value.continuedFrom = carry?.reason
            value.verifiedStepCount = carry?.verifiedStepCount ?? 0
            value.stepVerification = carry?.stepVerification
            return value
        }
        func stopCode() -> ReasonCode? {
            guard !Task.isCancelled && deps.isCurrent() else { return .taskStopped }
            guard deps.configurationRevision() == configurationRevision else { return .configurationChanged }
            return deps.now().timeIntervalSince(started) >= Self.timeBudgetSeconds ? .timeBudgetExhausted : nil
        }
        func canContinue() -> Bool { stopCode() == nil }
        func inactiveCode() -> ReasonCode { deps.mode() == .off ? .modeOff : .shadowMode }
        func observe(afterAction: Bool = false) async throws -> PhoneObservation {
            let began = deps.now()
            defer { metrics.observeMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            if afterAction, let settled = deps.observeAfterAction { return try await settled() }
            return try await deps.observe()
        }
        func sameContext(_ observation: PhoneObservation) -> Bool {
            guard let initial else { return false }
            return observation.bundleID == request.bundleID && observation.processID == initial.processID
                && (!strictGeometry || (observation.backend == initial.backend
                                        && observation.screenBounds == initial.screenBounds))
        }
        func verify(_ observation: PhoneObservation, before: PhoneObservation?) -> IOSPhoneGoalVerificationResult {
            if Self.hasAlert(observation) {
                return .init(status: .insufficient, reason: "unexpected_alert", needsScreenshot: true)
            }
            return IOSPhoneGoalVerification.evaluate(expectation: request.completion, before: before, after: observation)
        }
        func waitForUI() async throws {
            let began = deps.now()
            defer { metrics.waitMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            try await deps.waitForUI()
        }
        func choose(_ observation: PhoneObservation, _ candidates: [Candidate]) async -> IOSJevPhoneControlService.Selection {
            metrics.selectionCalls += 1
            let began = deps.now()
            defer { metrics.chooseMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            return await deps.choose(request.goal, observation, candidates.map(\.decisionCandidate), steps,
                                     request.completion)
        }
        func act(_ action: PhoneAction) async -> PhoneActionResult {
            let began = deps.now()
            defer { metrics.actMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            return await deps.act(action, nil, nil, true)
        }
        /// One read-only recovery round. Returns false when the task stopped meanwhile.
        func reread(waiting: Bool) async throws -> Bool {
            metrics.recoveries += 1
            let previous = current
            if waiting {
                await deps.reportActivity(.waitingForUI)
                try await waitForUI()
                guard canContinue() else { return false }
            }
            current = nil
            let fresh = try await observe()
            current = fresh
            if let previous, IOSPhoneGoalVerification.hasMeaningfulChange(before: previous, after: fresh) {
                noProgress = 0
                ineffective.removeAll()
            }
            return true
        }

        do {
            if carry == nil {
                try request.validate()
                guard canContinue() else { return result(.handback, "控制任务已停止。", code: stopCode() ?? .taskStopped) }
                guard deps.mode() != .off else { return result(.handback, "手机快速操作未启用；请使用原有 phone 工具。", code: .modeOff) }
                await deps.reportActivity(.observing)
                current = try await observe()
                initial = current
            }

            // Rounds without an action are bounded by the no-progress counter; rounds whose
            // screen keeps changing (loading) are bounded here and by the time budget.
            let roundLimit = request.maxSteps * 3 + Self.noProgressLimit * 2
            for _ in 0..<roundLimit {
                guard canContinue(), let observation = current else {
                    return result(.handback, "控制任务已停止或已达到 180 秒预算；不得重放已执行步骤。", code: stopCode() ?? .taskStopped)
                }
                guard sameContext(observation) else {
                    return result(.handback, "前台 App 与目标不一致；请主模型重新观察和规划。", code: .foregroundAppChanged)
                }
                await deps.reportActivity(.verifying)
                verification = verify(observation, before: beforeAction)
                if verification?.status == .satisfied {
                    if listed, steps.isEmpty {
                        var handback = result(.handback,
                            "完成条件已在动作前满足，尚未派发任何动作。请改为动作后的结果条件，或用 steps 给出每步验收。",
                            code: .completionAlreadySatisfied)
                        handback.verification = nil
                        handback.candidateDiagnostics = []
                        return handback
                    }
                    return result(.completed, "最新界面满足指定的验收条件。", code: .completed)
                }
                guard actionCount < request.maxSteps else {
                    return result(.handback, "已达到动作数量上限；请根据最新观察继续规划。", code: .stepBudgetExhausted)
                }
                let hasAlert = Self.hasAlert(observation)
                let usableTree = verification?.reason != "empty_tree"
                    && IOSPhoneGoalVerification.validScreenBounds(observation) != nil

                var candidates: [Candidate] = []
                var fromListedActions = false
                withheld = []
                if usableTree {
                    if listed, !hasAlert {
                        candidates = Self.resolveCandidates(request.actions, in: observation, excluding: executed,
                                                            expandAmbiguous: true).candidates
                        fromListedActions = !candidates.isEmpty
                    }
                    if candidates.isEmpty {
                        let live = Self.liveCandidateSet(in: observation, limit: deps.candidateLimit(),
                                                         excluding: ineffective)
                        candidates = live.candidates
                        withheld = live.withheld
                        // Off-plan candidates never run without a decision.
                        if !request.usesLiveCandidates {
                            for index in candidates.indices { candidates[index].requiresDecision = true }
                        }
                    }
                }

                if candidates.isEmpty && !hasAlert {
                    if !withheld.isEmpty {
                        return result(.handback,
                            "下一步只剩最终提交类控件（\(withheld.prefix(5).joined(separator: "、"))），交回主模型确认后用 phone_act 执行。",
                            code: .finalCommitRequired)
                    }
                    let code: ReasonCode
                    let message: String
                    if !usableTree {
                        code = .noExecutableCandidates
                        message = "界面树为空或缺少屏幕尺寸，不能安全推导可点击目标"
                    } else if !ineffective.isEmpty {
                        code = .screenUnchanged
                        message = "已尝试的动作没有使界面变化，且没有其它可选控件；不要重复点击"
                    } else {
                        code = listed && executed.count == request.actions.count ? .actionsExhausted : .noExecutableCandidates
                        message = "当前界面没有可执行的候选动作"
                    }
                    // Shadow never waits its way into a second screen.
                    guard deps.mode() == .active else { return result(.handback, message + "；交回主模型。", code: code, screenshot: true) }
                    noProgress += 1
                    guard noProgress < Self.noProgressLimit else {
                        return result(.handback, message + "；多次重读后仍无进展，交回主模型。", code: code, screenshot: true)
                    }
                    guard try await reread(waiting: true) else {
                        return result(.handback, "等待界面期间控制任务已停止。", code: stopCode() ?? .taskStopped)
                    }
                    continue
                }

                let selectLocally = deps.mode() == .active && candidates.count == 1
                    && !candidates[0].requiresDecision && withheld.isEmpty
                let selection: IOSJevPhoneControlService.Selection
                if selectLocally {
                    selection = .action(candidates[0].id)
                } else {
                    await deps.reportActivity(.deciding)
                    selection = await choose(observation, candidates)
                }
                guard canContinue() else { return result(.handback, "等待判断期间控制任务已停止或设置已变更。", code: stopCode() ?? .taskStopped) }
                // Shadow may inspect this one observation but must never wait/act its
                // way into a second screen. A setting change also closes execution.
                guard deps.mode() == .active else {
                    return result(.handback, "当前为观察模式或快速操作已关闭，未执行候选动作。", code: inactiveCode())
                }
                switch selection {
                case .handback(let reason):
                    if IOSJevPhoneControlService.isRetryableHandback(reason), noProgress + 1 < Self.noProgressLimit {
                        noProgress += 1
                        guard try await reread(waiting: true) else {
                            return result(.handback, "等待界面期间控制任务已停止。", code: stopCode() ?? .taskStopped)
                        }
                        continue
                    }
                    let withheldNote = withheld.isEmpty ? ""
                        : "本屏另有未自动执行的最终提交控件：\(withheld.prefix(5).joined(separator: "、"))。"
                    // A Jev failure is reported as such; it never turns into "final commit required".
                    if let code = Self.jevReasonCode(reason) {
                        var handback = result(.handback, Self.jevMessage(reason, code: code) + withheldNote, code: code,
                                              screenshot: IOSJevPhoneControlService.isRetryableHandback(reason))
                        handback.jevReason = reason
                        return handback
                    }
                    if !withheld.isEmpty {
                        return result(.handback,
                            "Jev 判断其余候选都不能推进目标（\(reason)）；本屏保留给主模型的最终提交控件：\(withheld.prefix(5).joined(separator: "、"))。",
                            code: .finalCommitRequired)
                    }
                    return result(.handback, reason, code: hasAlert ? .unexpectedAlert : .decisionHandback,
                                  screenshot: hasAlert || IOSJevPhoneControlService.isRetryableHandback(reason))
                case .needsScreenshot, .wait:
                    noProgress += 1
                    guard noProgress < Self.noProgressLimit else {
                        return selection == .wait
                            ? result(.handback, "多次等待后界面仍未变化，交回主模型。", code: .waitBudgetExhausted, screenshot: true)
                            : result(.handback, "界面文字不足以判断下一步，需要截图交给主模型定位。", code: .screenshotRequired, screenshot: true)
                    }
                    guard try await reread(waiting: true) else {
                        return result(.handback, "等待界面期间控制任务已停止。", code: stopCode() ?? .taskStopped)
                    }
                    continue
                case .action(let id):
                    guard let candidate = candidates.first(where: { $0.id == id }) else {
                        return result(.handback, "判断未选择当前界面的合法候选。", code: .invalidDecision)
                    }
                    await deps.reportActivity(IOSPhoneControlToolExecutor.actionActivity(candidate.action))
                    guard canContinue(), deps.mode() == .active else {
                        return result(.handback, "派发前控制任务或快速操作设置已变更。", code: stopCode() ?? inactiveCode())
                    }
                    let receipt = await act(candidate.action)
                    let receiptText = fromListedActions
                        ? candidate.id
                        : "\(Self.verb(for: candidate.action)) \(candidate.receiptName ?? candidate.stepDescription)"
                    switch receipt {
                    case .unknown(let problem):
                        // Do not observe again: the caller must preserve the typed
                        // outcomeUnknown all the way into the durable engine ledger.
                        steps.append("\(receiptText): unknown")
                        current = nil
                        return result(.unknown, problem.message, code: .actionOutcomeUnknown, unknown: problem)
                    case .unsent(let problem):
                        current = nil // act consumes the snapshot even when refused.
                        // Nothing was dispatched; a stale or busy screen is re-read, never replayed blindly.
                        if Self.isRecoverable(problem), noProgress + 1 < Self.noProgressLimit, canContinue() {
                            noProgress += 1
                            metrics.recoveries += 1
                            current = try await observe()
                            continue
                        }
                        return result(.handback, "动作未发送：\(problem.message)", code: .actionNotSent)
                    case .completed:
                        actionCount += 1
                        if selectLocally { metrics.localActions += 1 }
                        steps.append(fromListedActions ? "\(receiptText): completed" : receiptText)
                        if let specID = candidate.specID { executed.insert(specID) }
                    }
                    beforeAction = observation
                    current = nil
                    guard canContinue() else { return result(.handback, "动作已有回执，任务停止前未能核验效果。", code: stopCode() ?? .taskStopped) }
                    await deps.reportActivity(.verifying)
                    let after = try await observe(afterAction: true)
                    current = after
                    guard canContinue(), sameContext(after), after.processID == observation.processID else {
                        return result(.handback, "动作后任务状态或前台 App 已变化，不能确认效果。", code: stopCode() ?? .foregroundAppChanged)
                    }
                    let checked = verify(after, before: observation)
                    verification = checked
                    if checked.status == .satisfied {
                        return result(.completed, "最新界面满足指定的验收条件。", code: .completed)
                    }
                    guard IOSPhoneGoalVerification.hasMeaningfulChange(before: observation, after: after) else {
                        // Never repeat the same ineffective action on this screen; let the
                        // next round choose something else or wait.
                        ineffective.insert(candidate.fingerprint)
                        if !fromListedActions, let last = steps.indices.last { steps[last] += " (screen unchanged)" }
                        noProgress += 1
                        guard noProgress < Self.noProgressLimit else {
                            return result(.handback, "界面多次未显示有效变化；不要重复点击，交回主模型核对。",
                                          code: .screenUnchanged, screenshot: true)
                        }
                        continue
                    }
                    noProgress = 0
                    ineffective.removeAll()
                    // An unmet final condition is normal between actions. The next
                    // selection sees fresh evidence and the remaining candidates.
                }
            }
            return result(.handback, "已达到局部判断次数上限。", code: .iterationBudgetExhausted)
        } catch {
            current = nil
            return result(.handback, "观察或验证中断：\(error.localizedDescription)。已执行步骤不得重放。", code: error is IOSPhoneGoalValidationError ? .invalidRequest : (stopCode() ?? .observationInterrupted))
        }
    }

    // MARK: Ordered steps

    private func runSequence(_ request: IOSPhoneGoalRequest, sequence: [IOSPhoneSequenceStep]) async -> Result {
        let started = deps.now()
        let revision = deps.configurationRevision()
        var current: PhoneObservation?
        var initial: PhoneObservation?
        var receipts: [String] = []
        var actionCount = 0
        var verifiedSteps = 0
        var stepVerification: IOSPhoneGoalVerificationResult?
        var diagnostics: [CandidateDiagnostic] = []
        var metrics = Metrics()
        var pageAnchors: [(target: IOSPhoneGoalTarget, node: PhoneObservationNode)] = []
        var goalVerification: IOSPhoneGoalVerificationResult?

        func stopCode() -> ReasonCode? {
            guard !Task.isCancelled, deps.isCurrent() else { return .taskStopped }
            guard deps.configurationRevision() == revision else { return .configurationChanged }
            guard deps.mode() != .off else { return .modeOff }
            return deps.now().timeIntervalSince(started) >= Self.timeBudgetSeconds ? .timeBudgetExhausted : nil
        }
        func result(_ code: ReasonCode, _ message: String, screenshot: Bool = false,
                    unknown: PhoneControlProblem? = nil) -> Result {
            metrics.totalMs = max(0, deps.now().timeIntervalSince(started) * 1_000)
            return Result(status: unknown != nil ? .unknown : (code == .completed ? .completed : .handback),
                reason: message, reasonCode: code, candidateDiagnostics: current == nil ? [] : diagnostics,
                metrics: metrics, steps: receipts, observation: current, verification: goalVerification,
                needsScreenshot: screenshot, unknownProblem: unknown,
                verifiedStepCount: verifiedSteps, stepVerification: stepVerification)
        }
        func observe() async throws -> PhoneObservation {
            diagnostics = []
            let began = deps.now()
            defer { metrics.observeMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            return try await deps.observe()
        }
        func waitForUI() async throws {
            let began = deps.now()
            defer { metrics.waitMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            try await deps.waitForUI()
        }
        func contextChanged(_ observation: PhoneObservation) -> Bool {
            observation.bundleID != request.bundleID || observation.processID != initial?.processID
                || observation.backend != initial?.backend || observation.screenBounds != initial?.screenBounds
        }
        func pageAnchorRegion(for target: IOSPhoneGoalTarget,
                              in observation: PhoneObservation) -> PhoneElementRect? {
            guard let region = target.region, let bounds = observation.screenBounds else { return nil }
            return .init(x: bounds.x + region.x * bounds.width,
                          y: bounds.y + region.y * bounds.height,
                          width: region.width * bounds.width,
                          height: region.height * bounds.height)
        }
        func advise(_ step: IOSPhoneSequenceStep, before: PhoneObservation?, after: PhoneObservation,
                    verification: IOSPhoneGoalVerificationResult) async -> IOSJevPhoneControlService.Advice {
            let began = deps.now()
            metrics.reviewCalls += 1
            defer { metrics.adviseMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            return await deps.advise(request.goal, step.expectation, before, after, verification)
        }
        /// The screen left the plan: continue toward the same goal and completion with
        /// candidates generated from the fresh observation instead of handing back.
        func continueLive(_ code: ReasonCode, _ message: String, screenshot: Bool = false,
                          ineffective: Set<String> = []) async -> Result {
            guard deps.mode() == .active, stopCode() == nil, let observation = current, let initial,
                  !contextChanged(observation) else { return result(code, message, screenshot: screenshot) }
            guard actionCount < request.maxSteps else { return result(.stepBudgetExhausted, "已达到动作上限，未执行后续步骤。") }
            metrics.recoveries += 1
            return await runGoal(request, carry: .init(
                started: started, configurationRevision: revision, steps: receipts, metrics: metrics,
                current: observation,
                beforeAction: observation.observationID == initial.observationID ? nil : initial,
                initial: initial, actionCount: actionCount, verifiedStepCount: verifiedSteps,
                stepVerification: stepVerification, reason: code, ineffective: ineffective))
        }
        do {
            try request.validate()
            if let code = stopCode() { return result(code, "连续操作未启动：任务或 Jev 快速操作不可用。") }
            await deps.reportActivity(.observing)
            current = try await observe()
            initial = current
            for (index, step) in sequence.enumerated() {
                stepVerification = nil
                diagnostics = []
                guard actionCount < request.maxSteps else { return result(.stepBudgetExhausted, "已达到动作上限，未执行后续步骤。") }
                var waited = false
                var unsentRetried = false
                var dispatched: (candidate: Candidate, before: PhoneObservation)?
                // Only read-only waits and unsent refusals may revisit a step; an
                // accepted action is never replayed.
                stepLoop: while dispatched == nil {
                    var selected: Candidate?
                    var pageAnchorRef: String?
                    var local = false
                    while selected == nil {
                        if let code = stopCode() { return result(code, "连续操作已停止，保留已派发步骤。") }
                        guard let observation = current, !contextChanged(observation) else {
                            return result(.foregroundAppChanged, "App、进程或屏幕上下文变化，停止后续步骤。")
                        }
                        guard !observation.truncated else {
                            return await continueLive(.treeTruncated, "界面树不完整，不能确认页面与唯一目标。", screenshot: true)
                        }
                        let anchors = IOSPhoneGoalVerification.matchingNodes(target: step.pageAnchor, in: observation)
                        guard anchors.count == 1, let anchor = anchors.first else {
                            return await continueLive(.pageChanged, "当前页面或题目锚点已变化，停止后续步骤。", screenshot: true)
                        }
                        if let prior = pageAnchors.first(where: { $0.target == step.pageAnchor })?.node {
                            guard prior.label == anchor.label, prior.value == anchor.value, prior.type == anchor.type else {
                                return await continueLive(.pageChanged, "页面锚点的内容已变化，停止后续步骤。", screenshot: true)
                            }
                        } else {
                            pageAnchors.append((step.pageAnchor, anchor))
                        }
                        pageAnchorRef = anchor.ref
                        let resolved = Self.resolveCandidates(step.actions, in: observation, excluding: [],
                                                              expandAmbiguous: true)
                        diagnostics = resolved.diagnostics
                        let alert = Self.hasAlert(observation)
                        if alert || resolved.candidates.isEmpty {
                            let code: ReasonCode = alert ? .unexpectedAlert : .noExecutableCandidates
                            let checked = IOSPhoneGoalVerificationResult(status: .insufficient, reason: code.rawValue, needsScreenshot: true)
                            let advice = await advise(step, before: nil, after: observation, verification: checked)
                            if let stopped = stopCode() { return result(stopped, "异常判断期间任务已停止。") }
                            guard deps.mode() == .active else { return result(.shadowMode, "只观测当前界面，不等待或执行动作。") }
                            guard advice == .wait, !waited else {
                                return await continueLive(code, "出现弹窗或缺少可执行目标，交回主模型。", screenshot: true)
                            }
                            waited = true
                            await deps.reportActivity(.waitingForUI)
                            try await waitForUI()
                            if let stopped = stopCode() { return result(stopped, "等待期间任务已停止。") }
                            current = nil
                            current = try await observe()
                            continue
                        }
                        if resolved.candidates.count == 1, !resolved.candidates[0].requiresDecision, deps.mode() == .active {
                            selected = resolved.candidates[0]
                            local = true
                        } else {
                            await deps.reportActivity(.deciding)
                            let began = deps.now()
                            metrics.selectionCalls += 1
                            let choice = await deps.choose(request.goal, observation,
                                resolved.candidates.map(\.decisionCandidate), receipts, step.expectation)
                            metrics.chooseMs += max(0, deps.now().timeIntervalSince(began) * 1_000)
                            if let code = stopCode() { return result(code, "动作选择期间任务已停止。") }
                            guard deps.mode() == .active else { return result(.shadowMode, "Jev 已观测当前候选，未执行动作。") }
                            let ambiguous = resolved.candidates.contains { $0.requiresDecision }
                            switch choice {
                            case .action(let id):
                                guard let candidate = resolved.candidates.first(where: { $0.id == id }) else {
                                    return result(.invalidDecision, "Jev 未选择当前步骤的合法候选。")
                                }
                                selected = candidate
                            case .wait:
                                guard !waited else {
                                    return await continueLive(.waitBudgetExhausted, "本步骤等待后仍无法决定，交回主模型。")
                                }
                                waited = true
                                await deps.reportActivity(.waitingForUI)
                                try await waitForUI()
                                if let code = stopCode() { return result(code, "等待期间任务已停止。") }
                                current = nil
                                current = try await observe()
                            case .needsScreenshot:
                                return await continueLive(.screenshotRequired, "Jev 需要主模型看图决定。", screenshot: true)
                            case .handback(let reason):
                                if IOSJevPhoneControlService.isRetryableHandback(reason), !waited {
                                    waited = true
                                    await deps.reportActivity(.waitingForUI)
                                    try await waitForUI()
                                    if let code = stopCode() { return result(code, "等待期间任务已停止。") }
                                    current = nil
                                    current = try await observe()
                                    continue
                                }
                                // Continuing in goal mode would ask the same failing Jev again.
                                if let code = Self.jevReasonCode(reason) {
                                    var handback = result(code, Self.jevMessage(reason, code: code),
                                                          screenshot: IOSJevPhoneControlService.isRetryableHandback(reason))
                                    handback.jevReason = reason
                                    return handback
                                }
                                return await continueLive(ambiguous ? .ambiguousTarget : .decisionHandback,
                                                          ambiguous ? "目标有多个匹配，Jev 未能确定：\(reason)" : reason,
                                                          screenshot: ambiguous)
                            }
                        }
                    }
                    guard let candidate = selected, let before = current, let pageAnchorRef else {
                        return result(.invalidDecision, "没有有效的本步动作与观察。")
                    }
                    await deps.reportActivity(IOSPhoneControlToolExecutor.actionActivity(candidate.action))
                    if let code = stopCode() { return result(code, "动作派发前任务已停止。") }
                    guard deps.mode() == .active else { return result(.shadowMode, "只观测模式不执行动作。") }
                    let began = deps.now()
                    current = nil
                    let anchorRegion = pageAnchorRegion(for: step.pageAnchor, in: before)
                    let receipt = await deps.act(candidate.action, pageAnchorRef, anchorRegion, false)
                    metrics.actMs += max(0, deps.now().timeIntervalSince(began) * 1_000)
                    let receiptID = "s\(index)/\(candidate.id)"
                    switch receipt {
                    case .unknown(let problem):
                        receipts.append("\(receiptID): unknown")
                        return result(.actionOutcomeUnknown, problem.message, unknown: problem)
                    case .unsent(let problem):
                        guard Self.isRecoverable(problem), !unsentRetried, stopCode() == nil else {
                            return result(.actionNotSent, "动作未发送：\(problem.message)")
                        }
                        // Nothing was dispatched: re-read and resolve this step again.
                        unsentRetried = true
                        metrics.recoveries += 1
                        current = try await observe()
                        continue stepLoop
                    case .completed:
                        receipts.append("\(receiptID): completed")
                        actionCount += 1
                        if local { metrics.localActions += 1 }
                        dispatched = (candidate, before)
                    }
                }
                guard let dispatched else { return result(.invalidDecision, "没有有效的本步动作。") }
                let (candidate, before) = dispatched
                if let code = stopCode() { return result(code, "动作已有回执，任务停止前尚未核验。") }
                var stability: PhoneScreenStability?
                func settle() async throws -> PhoneScreenStability {
                    await deps.reportActivity(.waitingForUI)
                    let began = deps.now()
                    metrics.settleCalls += 1
                    defer { metrics.settleMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
                    return try await deps.waitForStability()
                }
                if step.waitForStability {
                    stability = try await settle()
                    // An animating or blank frame gets one more settle before it counts as no progress.
                    if let first = stability, !first.stable || first.blank == true, stopCode() == nil {
                        metrics.recoveries += 1
                        stability = try await settle()
                    }
                }
                if let code = stopCode() { return result(code, "等待界面期间任务已停止。") }
                await deps.reportActivity(.verifying)
                current = try await observe()
                guard let after = current, !contextChanged(after) else {
                    return result(.foregroundAppChanged, "动作后 App 或屏幕上下文变化，停止序列。")
                }
                if let code = stopCode() { return result(code, "读取动作结果期间任务已停止。") }
                if let stability, !stability.stable || stability.blank == true {
                    return result(.screenNotStable, "两次等待后画面仍未稳定，保留新观察并停止后续步骤。", screenshot: true)
                }
                func check(_ observation: PhoneObservation) -> IOSPhoneGoalVerificationResult {
                    Self.hasAlert(observation)
                        ? .init(status: .insufficient, reason: "unexpected_alert", needsScreenshot: true)
                        : IOSPhoneGoalVerification.evaluate(action: candidate.action, expectation: step.expectation,
                                                            before: before, after: observation)
                }
                var checked = check(after)
                stepVerification = checked
                if checked.status != .satisfied {
                    var advice = await advise(step, before: before, after: after, verification: checked)
                    if let code = stopCode() { return result(code, "效果判断期间任务已停止。") }
                    var rereads = 0
                    while checked.status != .satisfied, advice == .wait || advice == .needsScreenshot,
                          rereads < 2, deps.mode() == .active {
                        rereads += 1
                        metrics.recoveries += 1
                        await deps.reportActivity(.waitingForUI)
                        try await waitForUI()
                        if let code = stopCode() { return result(code, "等待期间任务已停止。") }
                        current = nil
                        let refreshed = try await observe()
                        current = refreshed
                        if let code = stopCode() { return result(code, "重新观察期间任务已停止。") }
                        guard !contextChanged(refreshed) else { return result(.foregroundAppChanged, "等待后 App 或屏幕上下文变化。") }
                        checked = check(refreshed)
                        stepVerification = checked
                        if checked.status != .satisfied, rereads < 2 {
                            advice = await advise(step, before: before, after: refreshed, verification: checked)
                            if let code = stopCode() { return result(code, "效果判断期间任务已停止。") }
                        }
                    }
                    if checked.status != .satisfied {
                        // Progress without proof may move on only on a visibly changed
                        // screen; the next step's page anchor still has to match.
                        if advice == .continueTask, deps.mode() == .active, let latest = current,
                           IOSPhoneGoalVerification.hasMeaningfulChange(before: before, after: latest) {
                            continue
                        }
                        let unchanged = current.map { !IOSPhoneGoalVerification.hasMeaningfulChange(before: before, after: $0) } ?? false
                        return await continueLive(.stepExpectationUnmet, "本步效果尚未确认；后续步骤未执行，已派发动作不得重放。",
                                                  screenshot: checked.needsScreenshot || advice == .needsScreenshot,
                                                  ineffective: unchanged ? [candidate.fingerprint] : [])
                    }
                }
                verifiedSteps += 1
                // The post-action observation is also the next step's input; never read it twice.
            }
            guard let after = current else { return result(.observationInterrupted, "缺少最终界面。") }
            let goal = IOSPhoneGoalVerification.evaluate(expectation: request.completion, before: initial, after: after)
            goalVerification = goal
            return goal.status == .satisfied
                ? result(.completed, "全部步骤及整体目标均已通过新界面核验。")
                : await continueLive(.verificationHandback, "各步骤已执行并核验，但整体目标尚未确认。", screenshot: goal.needsScreenshot)
        } catch {
            current = nil
            return result(error is IOSPhoneGoalValidationError ? .invalidRequest : (stopCode() ?? .observationInterrupted),
                          "连续操作中断：\(error.localizedDescription)。已派发动作不得重放。")
        }
    }

    // MARK: Candidates

    static func candidates(_ actions: [IOSPhoneGoalActionSpec], in observation: PhoneObservation,
                           excluding executed: Set<String> = []) -> [Candidate] {
        resolveCandidates(actions, in: observation, excluding: executed).candidates
    }

    static func liveCandidates(in observation: PhoneObservation, limit: Int = defaultCandidateLimit,
                               excluding ineffective: Set<String> = []) -> [Candidate] {
        liveCandidateSet(in: observation, limit: limit, excluding: ineffective).candidates
    }

    /// Every visible, enabled, named control with a fresh ref, the main scroll areas and
    /// in-App alert buttons, deduplicated, described with position/context and capped.
    /// Final commits are withheld (reported by name, never offered).
    static func liveCandidateSet(in observation: PhoneObservation, limit: Int = defaultCandidateLimit,
                                 excluding ineffective: Set<String> = []) -> LiveCandidateSet {
        guard let bounds = IOSPhoneGoalVerification.validScreenBounds(observation), limit > 0 else {
            return .init(candidates: [], withheld: [])
        }
        if hasAlert(observation) {
            return alertCandidates(in: observation, limit: limit, excluding: ineffective)
        }
        let context = ScreenContext(observation, bounds: bounds)
        var withheld: [String] = []
        let indexed = observation.nodes.enumerated().filter { _, node in
            liveTapTypes.contains(node.type) && node.enabled && node.ref?.isEmpty == false
                && IOSPhoneGoalVerification.hasVisibleFrame(node, within: bounds)
                && displayName(node) != nil
        }
        var seen = Set<String>()
        var taps: [(candidate: Candidate, index: Int, priority: Int)] = []
        for (node, index) in IOSPhoneGoalVerification.collapseLabelChildMatches(indexed, in: observation) {
            let fingerprint = tapFingerprint(node)
            guard seen.insert(fingerprint).inserted, let name = displayName(node) else { continue }
            if isFinalCommit(node, screen: bounds) {
                withheld.append(name)
                continue
            }
            guard !ineffective.contains(fingerprint), let ref = node.ref else { continue }
            let spec = IOSPhoneGoalActionSpec(action: .tap, target: .init(label: node.label, identifier: node.identifier,
                                                                            type: node.type))
            let names = nameDescription(node)
            taps.append((Candidate(id: "n\(index)", spec: spec, action: .tap(ref: ref),
                                   decisionDescription: "tap \(names) \(context.describe(index))",
                                   requiresDecision: observation.truncated, fingerprint: fingerprint,
                                   receiptName: names, nodeIndex: index),
                         index, tapPriority(node.type)))
        }
        annotateSameNames(&taps, in: observation)

        let screenArea = bounds.width * bounds.height
        let scrollAreas = observation.nodes.enumerated().filter { _, node in
            scrollTypes.contains(node.type) && node.enabled && node.ref?.isEmpty == false
                && IOSPhoneGoalVerification.hasVisibleFrame(node, within: bounds)
                && node.rect.width * node.rect.height >= 0.15 * screenArea
        }
        var seenScrollRects = Set<String>()
        var swipes: [(candidate: Candidate, index: Int, priority: Int)] = []
        for (index, node) in scrollAreas.sorted(by: { $0.element.rect.width * $0.element.rect.height
                                                      > $1.element.rect.width * $1.element.rect.height }) {
            guard swipes.count < 4, seenScrollRects.insert(rectKey(node.rect)).inserted, let ref = node.ref else { continue }
            let name = displayName(node)
            for direction in [PhoneSwipeDirection.up, .down] {
                let fingerprint = "swipe|\(direction.rawValue)|\(node.type)|\(name ?? "")|\(rectKey(node.rect))"
                guard !ineffective.contains(fingerprint) else { continue }
                let reveals = direction == .up ? "reveals content further down" : "reveals content further up"
                let spec = IOSPhoneGoalActionSpec(action: .swipe, target: .init(label: name ?? "scroll area", type: node.type),
                                                  direction: direction == .up ? .up : .down)
                let names = nameDescription(node)
                swipes.append((Candidate(id: "s\(index)\(direction == .up ? "u" : "d")", spec: spec,
                                         action: .swipe(ref: ref, direction: direction),
                                         decisionDescription: "swipe \(direction.rawValue) (finger moves \(direction.rawValue); \(reveals)) on \(names) \(context.describe(index))",
                                         requiresDecision: true, fingerprint: fingerprint,
                                         receiptName: "\(direction.rawValue) on \(names)", nodeIndex: index),
                               index, 1))
            }
        }

        var all = taps + swipes
        if all.count > limit {
            // Keep the most control-like entries; ties keep reading order.
            let kept = Set(all.enumerated().sorted { lhs, rhs in
                lhs.element.priority != rhs.element.priority
                    ? lhs.element.priority < rhs.element.priority : lhs.offset < rhs.offset
            }.prefix(limit).map(\.offset))
            all = all.enumerated().filter { kept.contains($0.offset) }.map(\.element)
        }
        return .init(candidates: all.map(\.candidate), withheld: withheld)
    }

    /// In-App alert buttons replace the covered page. Permission prompts are never offered.
    private static func alertCandidates(in observation: PhoneObservation, limit: Int,
                                        excluding ineffective: Set<String>) -> LiveCandidateSet {
        guard observation.alertActionsSupported else { return .init(candidates: [], withheld: []) }
        var candidates: [Candidate] = []
        var withheld: [String] = []
        for (alertIndex, alert) in observation.alerts.enumerated() {
            if isPermissionPrompt(alert) {
                withheld += alert.buttons.map(\.name)
                continue
            }
            // "Delete this draft?" + "OK": the confirm button commits even with a generic name.
            let confirmsCommit = describesFinalCommit(alert.text)
            for (buttonIndex, button) in alert.buttons.enumerated() {
                guard let ref = button.ref, !ref.isEmpty else { continue }
                if isFinalCommit(button.name) || (confirmsCommit && !isDismissal(button.name)) {
                    withheld.append(button.name)
                    continue
                }
                let fingerprint = "alert|\(alert.text)|\(button.name)"
                guard !ineffective.contains(fingerprint), candidates.count < limit else { continue }
                let name = short(button.name, 80)
                candidates.append(Candidate(
                    id: "alert\(alertIndex).\(buttonIndex)",
                    spec: .init(action: .tap, target: .init(label: button.name.isEmpty ? "alert button" : button.name)),
                    action: .tapAlert(ref: ref),
                    decisionDescription: "tap alert button \"\(name)\" in alert \"\(short(alert.text, 160))\"",
                    requiresDecision: true, fingerprint: fingerprint, receiptName: "alert button \(name)"))
            }
        }
        return .init(candidates: candidates, withheld: withheld)
    }

    private static func resolveCandidates(_ actions: [IOSPhoneGoalActionSpec], in observation: PhoneObservation,
                                          excluding executed: Set<String>,
                                          expandAmbiguous: Bool = false) -> (candidates: [Candidate], diagnostics: [CandidateDiagnostic]) {
        var diagnostics: [CandidateDiagnostic] = []
        // Mirror the verifier's geometry gate: unavailable geometry is not evidence of absence.
        let bounds = IOSPhoneGoalVerification.validScreenBounds(observation)
        let context = bounds.map { ScreenContext(observation, bounds: $0) }
        var candidates: [Candidate] = []
        for (index, spec) in actions.enumerated() {
            let id = "a\(index)"
            func reject(_ code: CandidateDiagnostic.ReasonCode) {
                diagnostics.append(.init(id: id, reasonCode: code))
            }
            guard !executed.contains(id) else { reject(.alreadyExecuted); continue }
            // A partial tree cannot establish that a label occurs exactly once.
            guard !observation.truncated else { reject(.treeTruncated); continue }
            guard let context else { reject(.screenBoundsUnavailable); continue }
            let matches = IOSPhoneGoalVerification.matchingNodeIndices(target: spec.target, in: observation)
            guard !matches.isEmpty else { reject(.targetNotVisible); continue }
            // A tappable container and its visible text child can share the same
            // label. Resolve the action's supported roles before declaring ambiguity.
            let actionableMatches = matches.filter { supports(spec.action, $0.node) }
            guard !actionableMatches.isEmpty else { reject(.unsupported); continue }
            if actionableMatches.count == 1, let match = actionableMatches.first {
                switch resolveAction(for: spec, node: match.node) {
                case .rejected(let code): reject(code)
                case .action(let action):
                    diagnostics.append(.init(id: id, reasonCode: .eligible))
                    candidates.append(Candidate(id: id, spec: spec, action: action, specID: id,
                                                fingerprint: tapFingerprint(match.node), nodeIndex: match.index))
                }
                continue
            }
            reject(.targetAmbiguous)
            // Real duplicates (e.g. a word in both the answer area and the word bank) are
            // offered one by one with their position and context; Jev must pick.
            guard expandAmbiguous else { continue }
            let specText = String(decoding: try! JSONEncoder().encode(spec), as: UTF8.self)
            let ordered = actionableMatches.sorted { readingOrder($0.node, $1.node) }
            for (rank, match) in ordered.enumerated() {
                guard case .action(let action) = resolveAction(for: spec, node: match.node) else { continue }
                candidates.append(Candidate(
                    id: "\(id).\(rank + 1)", spec: spec, action: action,
                    decisionDescription: "\(specText) | match \(rank + 1) of \(ordered.count) in reading order: \(nameDescription(match.node)) \(context.describe(match.index))",
                    specID: id, requiresDecision: true, fingerprint: tapFingerprint(match.node),
                    nodeIndex: match.index))
            }
        }
        return (candidates, diagnostics)
    }

    private enum ActionResolution {
        case action(PhoneAction)
        case rejected(CandidateDiagnostic.ReasonCode)
    }

    private static func supports(_ action: IOSPhoneGoalActionSpec.Action, _ node: PhoneObservationNode) -> Bool {
        switch action {
        case .tap: listedTapTypes.contains(node.type)
        case .type: IOSPhoneGoalVerification.isTextInput(node)
        case .swipe: scrollTypes.contains(node.type)
        }
    }

    private static func resolveAction(for spec: IOSPhoneGoalActionSpec,
                               node: PhoneObservationNode) -> ActionResolution {
        guard node.enabled else { return .rejected(.disabled) }
        guard let ref = node.ref, !ref.isEmpty else { return .rejected(.referenceUnavailable) }
        switch spec.action {
        case .tap:
            return .action(.tap(ref: ref))
        case .type:
            guard IOSPhoneGoalVerification.isTextInput(node), let text = spec.text else { return .rejected(.unsupported) }
            guard let value = node.value else { return .rejected(.inputValueUnavailable) }
            guard value.isEmpty else { return .rejected(.inputNotEmpty) }
            return .action(.type(ref: ref, text: text))
        case .swipe:
            guard scrollTypes.contains(node.type), let direction = spec.direction,
                  let mapped = PhoneSwipeDirection(rawValue: direction.rawValue) else { return .rejected(.unsupported) }
            return .action(.swipe(ref: ref, direction: mapped))
        }
    }

    // MARK: Safety classification

    /// Whether tapping this observed control would commit something irreversible or on the
    /// user's behalf. Only button-like controls qualify: Button, Link, MenuItem and keyboard
    /// Key. Icon/text buttons exposed as Other, Image or StaticText qualify only with a short
    /// label (<= 6 characters) on a small frame. Cells, text views, switches, tabs and list
    /// rows (message previews, notifications) are navigation and are never withheld.
    static func isFinalCommit(_ node: PhoneObservationNode, screen bounds: PhoneElementRect?) -> Bool {
        switch node.type {
        case "XCUIElementTypeButton", "XCUIElementTypeLink", "XCUIElementTypeMenuItem", "XCUIElementTypeKey":
            break
        case "XCUIElementTypeOther", "XCUIElementTypeImage", "XCUIElementTypeStaticText":
            let label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let maxWidth = max(120, (bounds?.width ?? 0) * 0.4)
            guard label.count <= 6, node.rect.width <= maxWidth, node.rect.height <= 100 else { return false }
        default:
            return false
        }
        return isFinalCommit(node.label) || isFinalCommit(node.identifier)
    }

    private static let commitPhrasesCJK = [
        "发送", "发布", "支付", "付款", "购买", "下单", "提交订单", "删除", "登录", "登入", "授权", "允许",
        "送信", "購入", "削除", "ログイン", "投稿", "許可", "支払",
    ]
    private static let commitWords: Set<String> = [
        "send", "post", "publish", "pay", "purchase", "buy", "checkout", "delete",
        "login", "logon", "signin", "allow", "authorize", "subscribe",
    ]
    private static let commitPhrasesLatin = [
        "sign in", "log in", "sign up", "place order", "pay now", "buy now",
        "confirm payment", "confirm purchase", "confirm order", "confirm delete",
    ]

    /// Phrase-style match on a short control label or identifier: the label is the commit
    /// phrase, or the phrase plus a short modifier ("立即支付", "确认删除", "删除好友",
    /// "Send", "Post", "deleteButton", "Log in with Apple"). Phrases inside longer text
    /// ("授权操作通知", notification or message previews) are content, not commits.
    static func isFinalCommit(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        func letterCount<S: Sequence>(_ characters: S) -> Int where S.Element == Character {
            characters.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
        }
        if text.contains(where: isCJK) {
            // At most 8 CJK/kana letters; at most 2 modifier letters around the phrase.
            guard letterCount(text) <= 8 else { return false }
            return commitPhrasesCJK.contains { phrase in
                text == phrase
                    || (text.hasPrefix(phrase) && letterCount(text.dropFirst(phrase.count)) <= 2)
                    || (text.hasSuffix(phrase) && letterCount(text.dropLast(phrase.count)) <= 2)
            }
        }
        var tokens: [String] = []
        var token = ""
        for character in text {
            if character.isLetter {
                if character.isUppercase, let last = token.last, last.isLowercase {
                    tokens.append(token.lowercased())
                    token = ""
                }
                token.append(character)
            } else if !token.isEmpty {
                tokens.append(token.lowercased())
                token = ""
            }
        }
        if !token.isEmpty { tokens.append(token.lowercased()) }
        // Short labels only (<= 4 words); the commit verb leads ("Send", "Delete account").
        guard let first = tokens.first, tokens.count <= 4 else { return false }
        if commitWords.contains(first) { return true }
        // "Confirm & Pay", "Confirm Send": a confirming modifier followed by the commit verb.
        if ["confirm", "complete"].contains(first), let last = tokens.last, commitWords.contains(last) { return true }
        let joined = tokens.joined(separator: " ")
        return commitPhrasesLatin.contains { joined == $0 || joined.hasPrefix($0 + " ") || joined.hasSuffix(" " + $0) }
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(scalar) || (0x3400...0x4DBF).contains(scalar)
            || (0x3040...0x30FF).contains(scalar) || (0xAC00...0xD7AF).contains(scalar)
            || (0xF900...0xFAFF).contains(scalar)
    }

    /// Jev failures and unavailability get their own codes; a declined decision returns nil.
    static func jevReasonCode(_ reason: String) -> ReasonCode? {
        switch IOSJevPhoneControlService.handbackKind(reason) {
        case .declined: nil
        case .unavailable: .jevUnavailable
        case .failed: .jevFailed
        }
    }

    static func jevMessage(_ reason: String, code: ReasonCode) -> String {
        code == .jevUnavailable
            ? "Jev 当前不可用（\(reason)），未执行候选动作；请主模型根据最新观察用 phone_act 继续。"
            : "Jev 判断请求失败（\(reason)），未执行候选动作；请主模型根据最新观察用 phone_act 继续。"
    }

    /// System permission prompts are never answered by the loop, in either direction.
    static func isPermissionPrompt(_ alert: PhoneObservedAlert) -> Bool {
        let text = alert.text.lowercased()
        if ["would like to", "wants to", "would like permission", "access your", "想要访问", "想访问",
            "要访问", "想给你发送通知", "允许“", "使用你的"].contains(where: { text.contains($0) }) { return true }
        return alert.buttons.contains { button in
            let name = button.name.lowercased()
            return name.contains("allow") || name.contains("允许") || name.contains("許可")
        }
    }

    static func describesFinalCommit(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["delete", "remove", "send", "publish", "post ", "pay", "purchase", "buy", "sign in", "log in",
                "删除", "移除", "发送", "发布", "支付", "付款", "购买", "登录", "退出登录"].contains { lower.contains($0) }
    }

    static func isDismissal(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["cancel", "not now", "close", "dismiss", "keep", "no", "取消", "暂不", "以后", "关闭", "不了", "保留"]
            .contains { lower == $0 || lower.hasPrefix($0 + " ") }
    }

    static func isRecoverable(_ problem: PhoneControlProblem) -> Bool {
        [.staleObservation, .busy, .elementNotFound, .ambiguousElement].contains(problem.kind)
    }

    static func hasAlert(_ observation: PhoneObservation) -> Bool {
        !observation.alerts.isEmpty || observation.nodes.contains { $0.type == "XCUIElementTypeAlert" }
    }

    // MARK: Descriptions

    private static let liveTapTypes: Set<String> = [
        "XCUIElementTypeButton", "XCUIElementTypeLink", "XCUIElementTypeCell", "XCUIElementTypeTabBarItem",
        "XCUIElementTypeTab", "XCUIElementTypeSwitch", "XCUIElementTypeToggle", "XCUIElementTypeMenuItem",
        "XCUIElementTypeOther", "XCUIElementTypeStaticText",
    ]
    private static let listedTapTypes: Set<String> = [
        "XCUIElementTypeButton", "XCUIElementTypeLink", "XCUIElementTypeCell", "XCUIElementTypeTabBarItem",
        "XCUIElementTypeTextField", "XCUIElementTypeSearchField", "XCUIElementTypeTextView",
        "XCUIElementTypeOther", "XCUIElementTypeStaticText", "XCUIElementTypeSwitch", "XCUIElementTypeToggle",
    ]
    private static let scrollTypes: Set<String> = [
        "XCUIElementTypeScrollView", "XCUIElementTypeTable", "XCUIElementTypeCollectionView",
    ]

    private static func tapPriority(_ type: String) -> Int {
        switch type {
        case "XCUIElementTypeOther": 2
        case "XCUIElementTypeStaticText": 3
        default: 0
        }
    }

    private static func displayName(_ node: PhoneObservationNode) -> String? {
        [node.label, node.identifier].lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func nameDescription(_ node: PhoneObservationNode) -> String {
        var parts: [String] = []
        if let label = node.label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("label=\(short(label, 80))")
        }
        if let identifier = node.identifier, !identifier.isEmpty { parts.append("identifier=\(short(identifier, 60))") }
        if let value = node.value, !value.isEmpty, value != node.label { parts.append("value=\(short(value, 60))") }
        parts.append("type=\(shortType(node.type))")
        parts.append("rect=[\(rectKey(node.rect))]")
        if node.focused { parts.append("focused") }
        return parts.joined(separator: " ")
    }

    private static func annotateSameNames(_ entries: inout [(candidate: Candidate, index: Int, priority: Int)],
                                          in observation: PhoneObservation) {
        let groups = Dictionary(grouping: entries.indices) { displayName(observation.nodes[entries[$0].index]) ?? "" }
        for (_, members) in groups where members.count > 1 {
            let ordered = members.sorted { readingOrder(observation.nodes[entries[$0].index], observation.nodes[entries[$1].index]) }
            for (rank, member) in ordered.enumerated() {
                entries[member].candidate.decisionDescription?
                    .append(" same_name=\(rank + 1)_of_\(ordered.count)_in_reading_order")
            }
        }
    }

    private static func readingOrder(_ lhs: PhoneObservationNode, _ rhs: PhoneObservationNode) -> Bool {
        let lhsRow = (lhs.rect.y / 8).rounded(.down), rhsRow = (rhs.rect.y / 8).rounded(.down)
        return lhsRow != rhsRow ? lhsRow < rhsRow : lhs.rect.x < rhs.rect.x
    }

    private static func verb(for action: PhoneAction) -> String {
        switch action {
        case .swipe: "swiped"
        case .tapAlert: "tapped"
        case .type: "typed into"
        default: "tapped"
        }
    }

    nonisolated fileprivate static func short(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    nonisolated fileprivate static func shortType(_ type: String) -> String {
        type.hasPrefix("XCUIElementType") ? String(type.dropFirst("XCUIElementType".count)) : type
    }

    /// Same identity for listed and live candidates, so a listed action that left the
    /// screen unchanged is not offered again by the off-plan fallback.
    private static func tapFingerprint(_ node: PhoneObservationNode) -> String {
        "tap|\(node.type)|\(node.label ?? "")|\(node.identifier ?? "")|\(rectKey(node.rect))"
    }

    private static func rectKey(_ rect: PhoneElementRect) -> String {
        [rect.x, rect.y, rect.width, rect.height].map { value in
            value.isFinite ? String(Int(value.rounded())) : "?"
        }.joined(separator: ",")
    }

    /// Positional and structural context for one node, so Jev can tell same-name
    /// controls apart (screen region, enclosing containers, neighbouring text).
    struct ScreenContext {
        let observation: PhoneObservation
        let bounds: PhoneElementRect
        private let parents: [Int?]

        private static let notableContainers: Set<String> = [
            "XCUIElementTypeNavigationBar", "XCUIElementTypeTabBar", "XCUIElementTypeToolbar",
            "XCUIElementTypeTable", "XCUIElementTypeCollectionView", "XCUIElementTypeScrollView",
            "XCUIElementTypeCell", "XCUIElementTypeSheet", "XCUIElementTypeSegmentedControl",
            "XCUIElementTypeWebView",
        ]

        init(_ observation: PhoneObservation, bounds: PhoneElementRect) {
            self.observation = observation
            self.bounds = bounds
            var stack: [Int] = []
            var parents: [Int?] = []
            parents.reserveCapacity(observation.nodes.count)
            for (index, node) in observation.nodes.enumerated() {
                while let last = stack.last, observation.nodes[last].depth >= node.depth { stack.removeLast() }
                parents.append(stack.last)
                stack.append(index)
            }
            self.parents = parents
        }

        func describe(_ index: Int) -> String {
            let nodes = observation.nodes
            guard nodes.indices.contains(index) else { return "" }
            let node = nodes[index]
            let cx = min(1, max(0, (node.rect.x + node.rect.width / 2 - bounds.x) / bounds.width))
            let cy = min(1, max(0, (node.rect.y + node.rect.height / 2 - bounds.y) / bounds.height))
            let vertical = cy < 1.0 / 3 ? "top" : (cy < 2.0 / 3 ? "middle" : "bottom")
            let horizontal = cx < 1.0 / 3 ? "left" : (cx < 2.0 / 3 ? "center" : "right")
            var parts = ["position=\(vertical)-\(horizontal)",
                         "center=(\(String(format: "%.2f", cx)),\(String(format: "%.2f", cy)))"]
            var containers: [String] = []
            var ancestors = Set<Int>()
            var cursor = parents[index]
            while let parent = cursor {
                ancestors.insert(parent)
                if containers.count < 2, let name = containerName(nodes[parent], excluding: node.label) {
                    containers.append(name)
                }
                cursor = parents[parent]
            }
            if !containers.isEmpty { parts.append("in=[\(containers.reversed().joined(separator: " > "))]") }
            if let before = neighbour(of: index, forward: false, ancestors: ancestors) {
                parts.append("text_before=\"\(before)\"")
            }
            if let after = neighbour(of: index, forward: true, ancestors: ancestors) {
                parts.append("text_after=\"\(after)\"")
            }
            return parts.joined(separator: " ")
        }

        private func containerName(_ node: PhoneObservationNode, excluding label: String?) -> String? {
            guard !["XCUIElementTypeApplication", "XCUIElementTypeWindow"].contains(node.type) else { return nil }
            let name = [node.identifier, node.label].lazy.compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != label }
            guard Self.notableContainers.contains(node.type) || name != nil else { return nil }
            return IOSPhoneGoalLoop.shortType(node.type) + (name.map { " '\(IOSPhoneGoalLoop.short($0, 32))'" } ?? "")
        }

        private func neighbour(of index: Int, forward: Bool, ancestors: Set<Int>) -> String? {
            let nodes = observation.nodes
            let node = nodes[index]
            var cursor = index + (forward ? 1 : -1)
            if forward {
                // Skip the node's own subtree.
                while cursor < nodes.count, nodes[cursor].depth > node.depth { cursor += 1 }
            }
            var scanned = 0
            while nodes.indices.contains(cursor), scanned < 40 {
                scanned += 1
                let other = nodes[cursor]
                if !ancestors.contains(cursor), let label = other.label,
                   !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label != node.label,
                   IOSPhoneGoalVerification.hasVisibleFrame(other, within: bounds) {
                    return IOSPhoneGoalLoop.short(label, 40)
                }
                cursor += forward ? 1 : -1
            }
            return nil
        }
    }
}
