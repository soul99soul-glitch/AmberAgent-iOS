import AmberPhoneControl
import Foundation

/// One tool invocation owns this loop. The engine's existing side-effect ledger owns
/// interruption/recovery; a partly executed loop is never resumed or replayed here.
@MainActor
final class IOSPhoneGoalLoop {
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
    }

    struct CandidateDiagnostic: Codable, Equatable, Sendable {
        enum ReasonCode: String, Codable, Sendable {
            case eligible
            case treeTruncated = "tree_truncated"
            case alreadyExecuted = "already_executed"
            case targetNotVisible = "target_not_visible"
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
        // Service invocations, including local/shadow decisions; not outbound HTTP counts.
        var selectionCalls = 0
        var reviewCalls = 0
        var settleMs: Double = 0
        var settleCalls = 0
        var localActions = 0

        enum CodingKeys: String, CodingKey {
            case observeMs = "observe_ms", chooseMs = "choose_ms"
            case actMs = "act_ms", adviseMs = "advise_ms"
            case selectionCalls = "selection_calls", reviewCalls = "review_calls"
            case settleMs = "settle_ms", settleCalls = "settle_calls", localActions = "local_actions"
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
    }

    struct Candidate {
        var id: String
        var spec: IOSPhoneGoalActionSpec
        var action: PhoneAction
        var decisionDescription: String? = nil

        var decisionCandidate: IOSJevPhoneControlService.Candidate {
            let description: String
            if let decisionDescription {
                description = decisionDescription
            } else {
                let data = try! JSONEncoder().encode(spec)
                description = String(decoding: data, as: UTF8.self)
            }
            return .init(id: id, description: description)
        }

        var stepDescription: String {
            decisionDescription ?? id
        }
    }

    private let deps: Dependencies
    init(deps: Dependencies) { self.deps = deps }

    func run(_ request: IOSPhoneGoalRequest) async -> Result {
        if let sequence = request.steps { return await runSequence(request, sequence: sequence) }
        let started = deps.now()
        let liveCandidates = request.usesLiveCandidates
        // A settings change ends this invocation, including across read-only waits.
        let configurationRevision = deps.configurationRevision()
        var steps: [String] = []
        var current: PhoneObservation?
        var beforeAction: PhoneObservation?
        var verification: IOSPhoneGoalVerificationResult?
        var executed = Set<String>()
        var hasWaited = false
        var metrics = Metrics()
        var initialBackend: String?
        var initialScreenBounds: PhoneElementRect?

        func result(_ status: Result.Status, _ reason: String, code: ReasonCode, screenshot: Bool = false,
                    unknown: PhoneControlProblem? = nil) -> Result {
            let diagnostics = current.map { observation -> [CandidateDiagnostic] in
                guard !liveCandidates,
                      !observation.nodes.contains(where: { $0.type == "XCUIElementTypeAlert" }) else { return [] }
                return Self.resolveCandidates(request.actions, in: observation, excluding: executed).diagnostics
            } ?? []
            return Result(status: status, reason: reason, reasonCode: code,
                          candidateDiagnostics: diagnostics, metrics: metrics, steps: steps, observation: current,
                          verification: verification, needsScreenshot: screenshot, unknownProblem: unknown)
        }
        func stopCode() -> ReasonCode? {
            guard !Task.isCancelled && deps.isCurrent() else { return .taskStopped }
            guard deps.configurationRevision() == configurationRevision else { return .configurationChanged }
            return deps.now().timeIntervalSince(started) >= 60 ? .timeBudgetExhausted : nil
        }
        func canContinue() -> Bool { stopCode() == nil }
        func observe() async throws -> PhoneObservation {
            let began = deps.now()
            defer { metrics.observeMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            return try await deps.observe()
        }
        func verify(_ observation: PhoneObservation, before: PhoneObservation?) -> IOSPhoneGoalVerificationResult {
            if observation.nodes.contains(where: { $0.type == "XCUIElementTypeAlert" }) {
                return .init(status: .insufficient, reason: "unexpected_alert", needsScreenshot: true)
            }
            return IOSPhoneGoalVerification.evaluate(expectation: request.completion, before: before, after: observation)
        }
        func choose(_ observation: PhoneObservation, _ candidates: [Candidate]) async -> IOSJevPhoneControlService.Selection {
            metrics.selectionCalls += 1
            let began = deps.now()
            defer { metrics.chooseMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            return await deps.choose(request.goal, observation, candidates.map(\.decisionCandidate), steps,
                                     request.completion)
        }
        func act(_ action: PhoneAction, pageAnchorRef: String? = nil,
                 pageAnchorRegion: PhoneElementRect? = nil,
                 requireUnchangedObservation: Bool = false) async -> PhoneActionResult {
            let began = deps.now()
            defer { metrics.actMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            return await deps.act(action, pageAnchorRef, pageAnchorRegion, requireUnchangedObservation)
        }
        do {
            try request.validate()
            guard canContinue() else { return result(.handback, "控制任务已停止。", code: stopCode() ?? .taskStopped) }
            guard deps.mode() != .off else { return result(.handback, "手机快速操作未启用；请使用原有 phone 工具。", code: .modeOff) }
            await deps.reportActivity(.observing)
            current = try await observe()
            let initialPID = current?.processID
            initialBackend = current?.backend
            initialScreenBounds = current?.screenBounds

            // The extra iterations permit one read-only loading wait. Action count is
            // checked independently so waiting cannot increase the requested budget.
            for _ in 0..<(request.maxSteps + 2) {
                guard canContinue(), let observation = current else {
                    return result(.handback, "控制任务已停止或已达到 60 秒预算；不得重放已执行步骤。", code: stopCode() ?? .taskStopped)
                }
                guard observation.bundleID == request.bundleID, observation.processID == initialPID,
                      !liveCandidates || (observation.backend == initialBackend
                                          && observation.screenBounds == initialScreenBounds) else {
                    return result(.handback, "前台 App 与目标不一致；请主模型重新观察和规划。", code: .foregroundAppChanged)
                }
                await deps.reportActivity(.verifying)
                verification = verify(observation, before: beforeAction)
                if verification?.status == .satisfied {
                    if !liveCandidates, steps.isEmpty {
                        var handback = result(.handback,
                            "完成条件已在动作前满足，尚未派发任何动作。请改为动作后的结果条件，或用 steps 给出每步验收。",
                            code: .completionAlreadySatisfied)
                        handback.verification = nil
                        handback.candidateDiagnostics = []
                        return handback
                    }
                    return result(.completed, "最新界面满足指定的验收条件。", code: .completed)
                }
                guard steps.count < request.maxSteps else {
                    return result(.handback, "已达到动作数量上限；请根据最新观察继续规划。", code: .stepBudgetExhausted)
                }
                if observation.truncated {
                    return result(.handback, "界面树不完整，不能安全推导可点击目标；交回主模型。",
                                  code: .treeTruncated, screenshot: true)
                }
                let hasAlert = observation.nodes.contains(where: { $0.type == "XCUIElementTypeAlert" })
                if verification?.reason == "empty_tree" {
                    return result(.handback, "界面树为空，不能安全推导可点击目标；交回主模型。",
                                  code: .noExecutableCandidates, screenshot: true)
                }
                if IOSPhoneGoalVerification.validScreenBounds(observation) == nil {
                    return result(.handback, "屏幕尺寸证据缺失，不能安全推导可点击目标；交回主模型。",
                                  code: .noExecutableCandidates, screenshot: true)
                }
                let candidates = hasAlert ? [] : (liveCandidates
                    ? Self.liveCandidates(in: observation)
                    : Self.candidates(request.actions, in: observation, excluding: executed))
                guard liveCandidates || hasAlert || !candidates.isEmpty else {
                    let code: ReasonCode = executed.count == request.actions.count
                        ? .actionsExhausted : .noExecutableCandidates
                    return result(.handback, "当前界面没有能唯一定位的剩余动作；交回主模型。", code: code,
                                  screenshot: verification?.needsScreenshot == true || Self.lacksUsefulControls(observation))
                }
                let selectLocally = candidates.count == 1 && deps.mode() == .active
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
                    return result(.handback, "当前为观察模式或快速操作已关闭，未执行候选动作。", code: deps.mode() == .off ? .modeOff : .shadowMode)
                }
                switch selection {
                case .handback(let reason):
                    return result(.handback, reason, code: hasAlert ? .unexpectedAlert : .decisionHandback,
                                  screenshot: hasAlert)
                case .needsScreenshot: return result(.handback, "需要截图交给主模型定位。", code: .screenshotRequired, screenshot: true)
                case .wait:
                    guard !hasWaited else { return result(.handback, "等待后仍不能确定下一步，交回主模型。", code: .waitBudgetExhausted) }
                    hasWaited = true
                    await deps.reportActivity(.waitingForUI)
                    try await deps.waitForUI()
                    guard canContinue() else { return result(.handback, "等待界面期间控制任务已停止。", code: stopCode() ?? .taskStopped) }
                    current = try await observe()
                    continue
                case .action(let id):
                    guard let candidate = candidates.first(where: { $0.id == id }) else {
                        return result(.handback, "判断未选择当前界面的合法候选。", code: .invalidDecision)
                    }
                    await deps.reportActivity(IOSPhoneControlToolExecutor.actionActivity(candidate.action))
                    guard canContinue(), deps.mode() == .active else {
                        return result(.handback, "派发前控制任务或快速操作设置已变更。", code: stopCode() ?? (deps.mode() == .off ? .modeOff : .shadowMode))
                    }
                    let receipt = await act(candidate.action, requireUnchangedObservation: true)
                    switch receipt {
                    case .unknown(let problem):
                        // Do not observe again: the caller must preserve the typed
                        // outcomeUnknown all the way into the durable engine ledger.
                        steps.append(liveCandidates
                            ? "tapped \(candidate.stepDescription): unknown"
                            : "\(candidate.id): unknown")
                        current = nil
                        return result(.unknown, problem.message, code: .actionOutcomeUnknown, unknown: problem)
                    case .unsent(let problem):
                        current = nil // act consumes the snapshot even when refused.
                        return result(.handback, "动作未发送：\(problem.message)", code: .actionNotSent)
                    case .completed:
                        if selectLocally { metrics.localActions += 1 }
                        if liveCandidates {
                            steps.append("tapped \(candidate.stepDescription)")
                        } else {
                            steps.append("\(candidate.id): completed")
                            executed.insert(candidate.id)
                        }
                    }
                    beforeAction = observation
                    current = nil
                    guard canContinue() else { return result(.handback, "动作已有回执，任务停止前未能核验效果。", code: stopCode() ?? .taskStopped) }
                    await deps.reportActivity(.verifying)
                    let after = try await observe()
                    current = after
                    guard canContinue(), after.bundleID == request.bundleID,
                          after.processID == observation.processID,
                          !liveCandidates || (after.backend == observation.backend
                                              && after.screenBounds == observation.screenBounds) else {
                        return result(.handback, "动作后任务状态或前台 App 已变化，不能确认效果。", code: stopCode() ?? .foregroundAppChanged)
                    }
                    let checked = verify(after, before: observation)
                    verification = checked
                    if checked.status == .satisfied {
                        return result(.completed, "最新界面满足指定的验收条件。", code: .completed)
                    }
                    guard IOSPhoneGoalVerification.hasMeaningfulChange(before: observation, after: after) else {
                        return result(.handback, "界面未显示有效变化；不要重复点击，交回主模型核对。",
                                      code: .screenUnchanged, screenshot: true)
                    }
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

    private func runSequence(_ request: IOSPhoneGoalRequest, sequence: [IOSPhoneSequenceStep]) async -> Result {
        let started = deps.now()
        let revision = deps.configurationRevision()
        var current: PhoneObservation?
        var initial: PhoneObservation?
        var receipts: [String] = []
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
            return deps.now().timeIntervalSince(started) >= 60 ? .timeBudgetExhausted : nil
        }
        func result(_ code: ReasonCode, _ message: String, screenshot: Bool = false,
                    unknown: PhoneControlProblem? = nil) -> Result {
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
        func contextChanged(_ observation: PhoneObservation) -> Bool {
            observation.bundleID != request.bundleID || observation.processID != initial?.processID
                || observation.backend != initial?.backend || observation.screenBounds != initial?.screenBounds
        }
        func hasAlert(_ observation: PhoneObservation) -> Bool {
            observation.nodes.contains { $0.type == "XCUIElementTypeAlert" }
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
        do {
            try request.validate()
            if let code = stopCode() { return result(code, "连续操作未启动：任务或 Jev 快速操作不可用。") }
            await deps.reportActivity(.observing)
            current = try await observe()
            initial = current
            for (index, step) in sequence.enumerated() {
                stepVerification = nil
                diagnostics = []
                guard index < request.maxSteps else { return result(.stepBudgetExhausted, "已达到动作上限，未执行后续步骤。") }
                var waited = false
                var selected: Candidate?
                var pageAnchorRef: String?
                // Only read-only waits may revisit a step; an accepted action is never replayed.
                while selected == nil {
                    if let code = stopCode() { return result(code, "连续操作已停止，保留已派发步骤。") }
                    guard let observation = current, !contextChanged(observation) else {
                        return result(.foregroundAppChanged, "App、进程或屏幕上下文变化，停止后续步骤。")
                    }
                    guard !observation.truncated else { return result(.treeTruncated, "界面树不完整，不能确认页面与唯一目标。", screenshot: true) }
                    let anchors = IOSPhoneGoalVerification.matchingNodes(target: step.pageAnchor, in: observation)
                    guard anchors.count == 1, let anchor = anchors.first else {
                        return result(.pageChanged, "当前页面或题目锚点已变化，停止后续步骤。", screenshot: true)
                    }
                    if let prior = pageAnchors.first(where: { $0.target == step.pageAnchor })?.node {
                        guard prior.label == anchor.label, prior.value == anchor.value, prior.type == anchor.type else {
                            return result(.pageChanged, "页面锚点的内容已变化，停止后续步骤。", screenshot: true)
                        }
                    } else {
                        pageAnchors.append((step.pageAnchor, anchor))
                    }
                    pageAnchorRef = anchor.ref
                    let resolved = Self.resolveCandidates(step.actions, in: observation, excluding: [])
                    diagnostics = resolved.diagnostics
                    guard !diagnostics.contains(where: { $0.reasonCode == .targetAmbiguous }) else {
                        return result(.ambiguousTarget, "目标有多个匹配，不能继续点击。", screenshot: true)
                    }
                    if hasAlert(observation) || resolved.candidates.isEmpty {
                        let code: ReasonCode = hasAlert(observation) ? .unexpectedAlert : .noExecutableCandidates
                        let checked = IOSPhoneGoalVerificationResult(status: .insufficient, reason: code.rawValue, needsScreenshot: true)
                        let advice = await advise(step, before: nil, after: observation, verification: checked)
                        if let stopped = stopCode() { return result(stopped, "异常判断期间任务已停止。") }
                        guard deps.mode() == .active else { return result(.shadowMode, "只观测当前界面，不等待或执行动作。") }
                        guard advice == .wait, !waited else {
                            return result(code, "出现弹窗或缺少可执行目标，交回主模型。", screenshot: true)
                        }
                        waited = true
                        await deps.reportActivity(.waitingForUI)
                        try await deps.waitForUI()
                        if let stopped = stopCode() { return result(stopped, "等待期间任务已停止。") }
                        current = nil
                        current = try await observe()
                        continue
                    }
                    if resolved.candidates.count == 1, deps.mode() == .active {
                        selected = resolved.candidates[0]
                    } else {
                        await deps.reportActivity(.deciding)
                        let began = deps.now()
                        metrics.selectionCalls += 1
                        let choice = await deps.choose(request.goal, observation,
                            resolved.candidates.map(\.decisionCandidate), receipts, step.expectation)
                        metrics.chooseMs += max(0, deps.now().timeIntervalSince(began) * 1_000)
                        if let code = stopCode() { return result(code, "动作选择期间任务已停止。") }
                        guard deps.mode() == .active else { return result(.shadowMode, "Jev 已观测当前候选，未执行动作。") }
                        switch choice {
                        case .action(let id):
                            guard let candidate = resolved.candidates.first(where: { $0.id == id }) else {
                                return result(.invalidDecision, "Jev 未选择当前步骤的合法候选。")
                            }
                            selected = candidate
                        case .wait:
                            guard !waited else { return result(.waitBudgetExhausted, "本步骤等待后仍无法决定，交回主模型。") }
                            waited = true
                            await deps.reportActivity(.waitingForUI)
                            try await deps.waitForUI()
                            if let code = stopCode() { return result(code, "等待期间任务已停止。") }
                            current = nil
                            current = try await observe()
                        case .needsScreenshot: return result(.screenshotRequired, "Jev 需要主模型看图决定。", screenshot: true)
                        case .handback(let reason): return result(.decisionHandback, reason)
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
                case .unsent(let problem): return result(.actionNotSent, "动作未发送：\(problem.message)")
                case .completed:
                    receipts.append("\(receiptID): completed")
                    if diagnostics.filter({ $0.reasonCode == .eligible }).count == 1 { metrics.localActions += 1 }
                }
                if let code = stopCode() { return result(code, "动作已有回执，任务停止前尚未核验。") }
                var stability: PhoneScreenStability?
                if step.waitForStability {
                    await deps.reportActivity(.waitingForUI)
                    let began = deps.now()
                    metrics.settleCalls += 1
                    do { stability = try await deps.waitForStability() }
                    catch {
                        metrics.settleMs += max(0, deps.now().timeIntervalSince(began) * 1_000)
                        throw error
                    }
                    metrics.settleMs += max(0, deps.now().timeIntervalSince(began) * 1_000)
                }
                if let code = stopCode() { return result(code, "等待界面期间任务已停止。") }
                await deps.reportActivity(.verifying)
                current = try await observe()
                guard let after = current, !contextChanged(after) else {
                    return result(.foregroundAppChanged, "动作后 App 或屏幕上下文变化，停止序列。")
                }
                if let code = stopCode() { return result(code, "读取动作结果期间任务已停止。") }
                if let stability, !stability.stable || stability.blank {
                    return result(.screenNotStable, "画面稳定性未确认，保留新观察并停止后续步骤。", screenshot: true)
                }
                var checked = IOSPhoneGoalVerification.evaluate(action: candidate.action,
                    expectation: step.expectation, before: before, after: after)
                if hasAlert(after) { checked = .init(status: .insufficient, reason: "unexpected_alert", needsScreenshot: true) }
                stepVerification = checked
                if checked.status != .satisfied {
                    let advice = await advise(step, before: before, after: after, verification: checked)
                    if let code = stopCode() { return result(code, "效果判断期间任务已停止。") }
                    if advice == .wait, !waited {
                        await deps.reportActivity(.waitingForUI)
                        try await deps.waitForUI()
                        if let code = stopCode() { return result(code, "等待期间任务已停止。") }
                        current = nil
                        let refreshed = try await observe()
                        current = refreshed
                        if let code = stopCode() { return result(code, "重新观察期间任务已停止。") }
                        guard !contextChanged(refreshed) else { return result(.foregroundAppChanged, "等待后 App 或屏幕上下文变化。") }
                        checked = IOSPhoneGoalVerification.evaluate(action: candidate.action,
                            expectation: step.expectation, before: before, after: refreshed)
                        if hasAlert(refreshed) { checked = .init(status: .insufficient, reason: "unexpected_alert", needsScreenshot: true) }
                        stepVerification = checked
                    }
                    guard checked.status == .satisfied else {
                        return result(.stepExpectationUnmet, "本步效果尚未确认；后续步骤未执行，已派发动作不得重放。",
                                      screenshot: checked.needsScreenshot || advice == .needsScreenshot)
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
                : result(.verificationHandback, "各步骤已执行并核验，但整体目标尚未确认。", screenshot: goal.needsScreenshot)
        } catch {
            current = nil
            return result(error is IOSPhoneGoalValidationError ? .invalidRequest : (stopCode() ?? .observationInterrupted),
                          "连续操作中断：\(error.localizedDescription)。已派发动作不得重放。")
        }
    }

    static func candidates(_ actions: [IOSPhoneGoalActionSpec], in observation: PhoneObservation,
                           excluding executed: Set<String> = []) -> [Candidate] {
        resolveCandidates(actions, in: observation, excluding: executed).candidates
    }

    static func liveCandidates(in observation: PhoneObservation) -> [Candidate] {
        guard !observation.truncated,
              let bounds = IOSPhoneGoalVerification.validScreenBounds(observation) else { return [] }
        let tapTypes: Set<String> = ["XCUIElementTypeButton", "XCUIElementTypeLink", "XCUIElementTypeCell",
                                     "XCUIElementTypeTabBarItem", "XCUIElementTypeOther",
                                     "XCUIElementTypeStaticText"]
        let indexed = observation.nodes.enumerated().filter { _, node in
            tapTypes.contains(node.type) && node.enabled && node.ref?.isEmpty == false
                && IOSPhoneGoalVerification.hasVisibleFrame(node, within: bounds)
                && [node.label, node.identifier].contains { value in
                    guard let value else { return false }
                    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        }
        let nodes = IOSPhoneGoalVerification.collapseLabelChildMatches(indexed, in: observation)
        return nodes.map { node, index in
            let target = IOSPhoneGoalTarget(label: node.label, identifier: node.identifier,
                                             type: node.type)
            let spec = IOSPhoneGoalActionSpec(action: .tap, target: target)
            let names = [node.label.map { "label=\($0)" }, node.identifier.map { "identifier=\($0)" }]
                .compactMap { $0 }
            let rect = "rect=[\(node.rect.x),\(node.rect.y),\(node.rect.width),\(node.rect.height)]"
            let description = "\(names.joined(separator: " ")) type=\(node.type) \(rect) ref=\(node.ref!)"
            return Candidate(id: "n\(index)", spec: spec, action: .tap(ref: node.ref!),
                             decisionDescription: description)
        }
    }

    private static func resolveCandidates(_ actions: [IOSPhoneGoalActionSpec], in observation: PhoneObservation,
                                          excluding executed: Set<String>) -> (candidates: [Candidate], diagnostics: [CandidateDiagnostic]) {
        var diagnostics: [CandidateDiagnostic] = []
        // Mirror the verifier's geometry gate: unavailable geometry is not evidence of absence.
        let hasValidBounds = observation.screenBounds.map { bounds in
            [bounds.x, bounds.y, bounds.width, bounds.height, bounds.x + bounds.width,
             bounds.y + bounds.height].allSatisfy(\.isFinite) && bounds.width > 0 && bounds.height > 0
        } ?? false
        let candidates: [Candidate] = actions.enumerated().compactMap { index, spec in
            let id = "a\(index)"
            func reject(_ code: CandidateDiagnostic.ReasonCode) -> Candidate? {
                diagnostics.append(.init(id: id, reasonCode: code))
                return nil
            }
            guard !executed.contains(id) else { return reject(.alreadyExecuted) }
            // A partial tree cannot establish that a label occurs exactly once.
            guard !observation.truncated else { return reject(.treeTruncated) }
            guard hasValidBounds else { return reject(.screenBoundsUnavailable) }
            let matches = IOSPhoneGoalVerification.matchingNodes(target: spec.target, in: observation)
            guard !matches.isEmpty else { return reject(.targetNotVisible) }
            // A tappable container and its visible text child can share the same
            // label. Resolve the action's supported roles before declaring ambiguity.
            let actionableMatches: [PhoneObservationNode]
            switch spec.action {
            case .tap:
                let roles: Set<String> = ["XCUIElementTypeButton", "XCUIElementTypeLink", "XCUIElementTypeCell",
                                          "XCUIElementTypeTabBarItem", "XCUIElementTypeTextField",
                                          "XCUIElementTypeSearchField", "XCUIElementTypeTextView",
                                          "XCUIElementTypeOther", "XCUIElementTypeStaticText"]
                actionableMatches = matches.filter { roles.contains($0.type) }
            case .type:
                actionableMatches = matches.filter { IOSPhoneGoalVerification.isTextInput($0) }
            case .swipe:
                let roles: Set<String> = ["XCUIElementTypeScrollView", "XCUIElementTypeTable", "XCUIElementTypeCollectionView"]
                actionableMatches = matches.filter { roles.contains($0.type) }
            }
            guard !actionableMatches.isEmpty else { return reject(.unsupported) }
            guard actionableMatches.count == 1, let node = actionableMatches.first else { return reject(.targetAmbiguous) }
            guard node.enabled else { return reject(.disabled) }
            guard let ref = node.ref, !ref.isEmpty else { return reject(.referenceUnavailable) }
            let action: PhoneAction
            switch spec.action {
            case .tap:
                action = .tap(ref: ref)
            case .type:
                guard IOSPhoneGoalVerification.isTextInput(node), let text = spec.text else { return reject(.unsupported) }
                guard let value = node.value else { return reject(.inputValueUnavailable) }
                guard value.isEmpty else { return reject(.inputNotEmpty) }
                action = .type(ref: ref, text: text)
            case .swipe:
                let roles: Set<String> = ["XCUIElementTypeScrollView", "XCUIElementTypeTable", "XCUIElementTypeCollectionView"]
                guard roles.contains(node.type), let direction = spec.direction,
                      let mapped = PhoneSwipeDirection(rawValue: direction.rawValue) else { return reject(.unsupported) }
                action = .swipe(ref: ref, direction: mapped)
            }
            diagnostics.append(.init(id: id, reasonCode: .eligible))
            return Candidate(id: id, spec: spec, action: action)
        }
        return (candidates, diagnostics)
    }

    private static func lacksUsefulControls(_ observation: PhoneObservation) -> Bool {
        !observation.nodes.contains { $0.ref != nil && $0.enabled && ($0.label?.isEmpty == false || $0.identifier?.isEmpty == false) }
    }
}
