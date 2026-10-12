import AmberPhoneControl
import Foundation

/// One tool invocation owns this loop. The engine's existing side-effect ledger owns
/// interruption/recovery; a partly executed loop is never resumed or replayed here.
@MainActor
final class IOSPhoneGoalLoop {
    struct Dependencies {
        var observe: () async throws -> PhoneObservation
        var act: (PhoneAction) async -> PhoneActionResult
        var choose: (String, PhoneObservation, [IOSJevPhoneControlService.Candidate], [String]) async -> IOSJevPhoneControlService.Selection
        var advise: (String, IOSPhoneGoalExpectation, PhoneObservation?, PhoneObservation, IOSPhoneGoalVerificationResult) async -> IOSJevPhoneControlService.Advice
        var mode: () -> IOSJevMode
        var isCurrent: () -> Bool
        var reportActivity: (AgentPhoneControlActivityPhase) async -> Void
        var configurationRevision: () -> Int = { 0 }
        var now: () -> Date = { Date() }
        var waitForUI: () async throws -> Void = { try await Task.sleep(for: .milliseconds(400)) }
    }

    enum ReasonCode: String, Codable, Sendable {
        case completed
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

        enum CodingKeys: String, CodingKey {
            case observeMs = "observe_ms", chooseMs = "choose_ms"
            case actMs = "act_ms", adviseMs = "advise_ms"
            case selectionCalls = "selection_calls", reviewCalls = "review_calls"
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
    }

    struct Candidate {
        var id: String
        var spec: IOSPhoneGoalActionSpec
        var action: PhoneAction

        var decisionCandidate: IOSJevPhoneControlService.Candidate {
            let data = try! JSONEncoder().encode(spec)
            return .init(id: id, description: String(decoding: data, as: UTF8.self))
        }
    }

    private let deps: Dependencies
    init(deps: Dependencies) { self.deps = deps }

    func run(_ request: IOSPhoneGoalRequest) async -> Result {
        let started = deps.now()
        // A settings change ends this invocation, including across read-only waits.
        let configurationRevision = deps.configurationRevision()
        var steps: [String] = []
        var current: PhoneObservation?
        var beforeAction: PhoneObservation?
        var verification: IOSPhoneGoalVerificationResult?
        var executed = Set<String>()
        var hasWaited = false
        var metrics = Metrics()

        func result(_ status: Result.Status, _ reason: String, code: ReasonCode, screenshot: Bool = false,
                    unknown: PhoneControlProblem? = nil) -> Result {
            let diagnostics = current.map {
                Self.resolveCandidates(request.actions, in: $0, excluding: executed).diagnostics
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
        func choose(_ observation: PhoneObservation, _ candidates: [Candidate]) async -> IOSJevPhoneControlService.Selection {
            metrics.selectionCalls += 1
            let began = deps.now()
            defer { metrics.chooseMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            return await deps.choose(request.goal, observation, candidates.map(\.decisionCandidate), steps)
        }
        func act(_ action: PhoneAction) async -> PhoneActionResult {
            let began = deps.now()
            defer { metrics.actMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            return await deps.act(action)
        }
        func advise(_ before: PhoneObservation, _ after: PhoneObservation,
                    _ checked: IOSPhoneGoalVerificationResult) async -> IOSJevPhoneControlService.Advice {
            metrics.reviewCalls += 1
            let began = deps.now()
            defer { metrics.adviseMs += max(0, deps.now().timeIntervalSince(began) * 1_000) }
            return await deps.advise(request.goal, request.completion, before, after, checked)
        }
        do {
            try request.validate()
            guard canContinue() else { return result(.handback, "控制任务已停止。", code: stopCode() ?? .taskStopped) }
            guard deps.mode() != .off else { return result(.handback, "手机快速操作未启用；请使用原有 phone 工具。", code: .modeOff) }
            await deps.reportActivity(.observing)
            current = try await observe()
            let initialPID = current?.processID

            // The extra iterations permit one read-only loading wait. Action count is
            // checked independently so waiting cannot increase the requested budget.
            for _ in 0..<(request.maxSteps + 2) {
                guard canContinue(), let observation = current else {
                    return result(.handback, "控制任务已停止或已达到 60 秒预算；不得重放已执行步骤。", code: stopCode() ?? .taskStopped)
                }
                guard observation.bundleID == request.bundleID, observation.processID == initialPID else {
                    return result(.handback, "前台 App 与目标不一致；请主模型重新观察和规划。", code: .foregroundAppChanged)
                }
                await deps.reportActivity(.verifying)
                verification = IOSPhoneGoalVerification.evaluate(
                    expectation: request.completion, before: beforeAction, after: observation)
                if verification?.status == .satisfied {
                    return result(.completed, "最新界面满足指定的验收条件。", code: .completed)
                }
                guard steps.count < request.maxSteps else {
                    return result(.handback, "已达到动作数量上限；请根据最新观察继续规划。", code: .stepBudgetExhausted)
                }
                let candidates = Self.candidates(request.actions, in: observation, excluding: executed)
                guard !candidates.isEmpty else {
                    let code: ReasonCode = observation.truncated ? .treeTruncated
                        : (executed.count == request.actions.count ? .actionsExhausted : .noExecutableCandidates)
                    return result(.handback, "当前界面没有能唯一定位的剩余动作；交回主模型。", code: code,
                                  screenshot: verification?.needsScreenshot == true || Self.lacksUsefulControls(observation))
                }
                await deps.reportActivity(.deciding)
                let selection = await choose(observation, candidates)
                guard canContinue() else { return result(.handback, "等待判断期间控制任务已停止或设置已变更。", code: stopCode() ?? .taskStopped) }
                // Shadow may inspect this one observation but must never wait/act its
                // way into a second screen. A setting change also closes execution.
                guard deps.mode() == .active else {
                    return result(.handback, "当前为观察模式或快速操作已关闭，未执行候选动作。", code: deps.mode() == .off ? .modeOff : .shadowMode)
                }
                switch selection {
                case .handback(let reason): return result(.handback, reason, code: .decisionHandback)
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
                    let receipt = await act(candidate.action)
                    switch receipt {
                    case .unknown(let problem):
                        // Do not observe again: the caller must preserve the typed
                        // outcomeUnknown all the way into the durable engine ledger.
                        steps.append("\(candidate.id): unknown")
                        current = nil
                        return result(.unknown, problem.message, code: .actionOutcomeUnknown, unknown: problem)
                    case .unsent(let problem):
                        current = nil // act consumes the snapshot even when refused.
                        return result(.handback, "动作未发送：\(problem.message)", code: .actionNotSent)
                    case .completed:
                        steps.append("\(candidate.id): completed")
                        executed.insert(candidate.id)
                    }
                    beforeAction = observation
                    current = nil
                    guard canContinue() else { return result(.handback, "动作已有回执，任务停止前未能核验效果。", code: stopCode() ?? .taskStopped) }
                    await deps.reportActivity(.verifying)
                    let after = try await observe()
                    current = after
                    guard canContinue(), after.bundleID == request.bundleID,
                          after.processID == observation.processID else {
                        return result(.handback, "动作后任务状态或前台 App 已变化，不能确认效果。", code: stopCode() ?? .foregroundAppChanged)
                    }
                    let checked = IOSPhoneGoalVerification.evaluate(
                        expectation: request.completion, before: observation, after: after)
                    verification = checked
                    if checked.status == .satisfied {
                        return result(.completed, "最新界面满足指定的验收条件。", code: .completed)
                    }
                    let advice = await advise(observation, after, checked)
                    guard canContinue() else { return result(.handback, "效果判断期间任务已停止。", code: stopCode() ?? .taskStopped) }
                    switch advice {
                    case .needsScreenshot:
                        return result(.handback, "动作已有回执，需要截图核对效果。", code: .screenshotRequired, screenshot: true)
                    case .handback:
                        return result(.handback, "动作已有回执，但当前证据不足以继续；交回主模型。", code: .verificationHandback)
                    case .wait:
                        guard !hasWaited else { return result(.handback, "界面等待已用尽，交回主模型核对。", code: .waitBudgetExhausted) }
                        hasWaited = true
                        await deps.reportActivity(.waitingForUI)
                        try await deps.waitForUI()
                        guard canContinue() else { return result(.handback, "等待界面期间控制任务已停止。", code: stopCode() ?? .taskStopped) }
                        current = try await observe()
                    case .continueTask:
                        guard IOSPhoneGoalVerification.hasMeaningfulChange(before: observation, after: after) else {
                            return result(.handback, "界面未显示有效变化；不要重复点击，交回主模型核对。", code: .screenUnchanged, screenshot: true)
                        }
                    }
                }
            }
            return result(.handback, "已达到局部判断次数上限。", code: .iterationBudgetExhausted)
        } catch {
            current = nil
            return result(.handback, "观察或验证中断：\(error.localizedDescription)。已执行步骤不得重放。", code: error is IOSPhoneGoalValidationError ? .invalidRequest : (stopCode() ?? .observationInterrupted))
        }
    }

    static func candidates(_ actions: [IOSPhoneGoalActionSpec], in observation: PhoneObservation,
                           excluding executed: Set<String> = []) -> [Candidate] {
        resolveCandidates(actions, in: observation, excluding: executed).candidates
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
            guard matches.count == 1, let node = matches.first else { return reject(.targetAmbiguous) }
            guard node.enabled else { return reject(.disabled) }
            guard let ref = node.ref, !ref.isEmpty else { return reject(.referenceUnavailable) }
            let action: PhoneAction
            switch spec.action {
            case .tap:
                let roles: Set<String> = ["XCUIElementTypeButton", "XCUIElementTypeLink", "XCUIElementTypeCell",
                                          "XCUIElementTypeTabBarItem", "XCUIElementTypeTextField",
                                          "XCUIElementTypeSearchField", "XCUIElementTypeTextView"]
                guard roles.contains(node.type) else { return reject(.unsupported) }
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
