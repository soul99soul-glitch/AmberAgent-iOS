import AmberPhoneControl
import Foundation
@preconcurrency import Shared

/// Foreground and background engines use the same run-scoped controller.
/// Authorization and launcher ownership stay outside the model's arguments.
@MainActor
final class IOSPhoneControlToolExecutor: IOSToolExecutor {
    private let runID: String
    private let controller: IOSPhoneControlController
    private let reportActivity: @MainActor (AgentPhoneControlActivityPhase) async -> Void
    private let jev: IOSJevPhoneControlService

    init(runID: String, controller: IOSPhoneControlController = .shared,
         jev: IOSJevPhoneControlService = .shared,
         reportActivity: (@MainActor (AgentPhoneControlActivityPhase) async -> Void)? = nil) {
        self.runID = runID
        self.controller = controller
        self.jev = jev
        self.reportActivity = reportActivity ?? { phase in
            await AgentLiveActivityController.shared.updatePhoneControl(runID: runID, phase: phase)
        }
    }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        let request: Request
        do {
            request = try Self.request(name: name, arguments: arguments)
        } catch {
            await reportActivity(.failed)
            return .failed(Self.json([
                "outcome": "not_sent", "retry_safe": true,
                "code": "invalid_arguments", "message": error.localizedDescription,
            ]))
        }

        let outcome: IOSAgentToolOutcome
        if request == .status || request == .stop {
            outcome = await perform(request)
        } else {
            outcome = await performWithHandoff(request)
        }
        let completion = Self.completionActivity(request: request, outcome: outcome)
        // Cancellation after dispatch must not hide an unknown action outcome.
        await reportActivity(completion == .outcomeUnknown ? completion : (Task.isCancelled ? .stopped : completion))
        return outcome
    }

    private func performWithHandoff(_ request: Request) async -> IOSAgentToolOutcome {
        let lease: IOSPhoneControlToolLease
        do { lease = try controller.beginPhoneTool(runID: runID) }
        catch { return .denied(Self.denial(error)) }
        do {
            if try controller.requiresFreshObservation(lease) {
                controller.endPhoneTool(lease)
                return await returnAfterHumanControl(lease, prior: nil)
            }
        } catch {
            controller.endPhoneTool(lease)
            return .denied(Self.denial(error))
        }

        let outcome = await perform(request)
        let unknown: Bool
        if case .outcomeUnknown = outcome { unknown = true } else { unknown = false }
        controller.endPhoneTool(lease, outcomeUnknown: unknown)
        // Unknown belongs to the durable engine ledger. Never wait or read over it.
        guard !unknown else { return outcome }
        guard controller.ownerRunID == runID,
              (try? controller.requiresFreshObservation(lease)) == true else { return outcome }
        return await returnAfterHumanControl(lease, prior: outcome)
    }

    /// The old request has ended. A resumed tool returns new evidence to the model;
    /// it never continues an interrupted action list or uses the old coordinates.
    private func returnAfterHumanControl(_ lease: IOSPhoneControlToolLease,
                                        prior: IOSAgentToolOutcome?) async -> IOSAgentToolOutcome {
        var fields: [String: Any] = [
            "status": "handback", "reason_code": "human_intervened", "retry_safe": false,
            "message": "用户已接手操作；原请求已结束，不重放原动作或步骤。请根据新的界面重新规划。",
        ]
        if let prior { fields["prior_tool_receipt"] = Self.receipt(prior) }
        else { fields["outcome"] = "not_sent" }
        do {
            while true {
                let generation = try await controller.waitForAutomationResume(lease)
                try Task.checkCancellation()
                let runner: PhoneRunnerClient
                switch await prepareRunner() {
                case .outcome(let failure):
                    fields["fresh_observation_available"] = false
                    fields["resume_error"] = Self.receipt(failure)
                    return .replanRequired([UIMessagePart.Text(text: Self.json(fields), metadata: nil)])
                case .ready(let ready): runner = ready
                }
                await reportActivity(.observing)
                let observation: PhoneObservation
                do {
                    observation = try await runner.observe(maxNodes: 1_000, includeScreenSize: true)
                    try Task.checkCancellation()
                } catch {
                    if !(error is CancellationError), !Task.isCancelled {
                        controller.failResumeObservation(lease, generation: generation, message: error.localizedDescription)
                    }
                    throw error
                }
                // Another pause during the read must be acknowledged separately.
                guard try controller.consumeFreshObservation(lease, generation: generation) else { continue }
                fields["fresh_observation_available"] = true
                return .replanRequired([
                    UIMessagePart.Text(text: Self.json(fields), metadata: nil),
                    UIMessagePart.Text(text: observation.compactText, metadata: nil),
                ])
            }
        } catch {
            fields["fresh_observation_available"] = false
            fields["resume_error"] = error.localizedDescription
            return .replanRequired([UIMessagePart.Text(text: Self.json(fields), metadata: nil)])
        }
    }

    private static func receipt(_ outcome: IOSAgentToolOutcome) -> [String: Any] {
        switch outcome {
        case .filled(let text): ["kind": "filled", "result": text]
        case .filledParts(let parts), .replanRequired(let parts):
            // First part holds the receipt/steps. Old screenshots and refs are not
            // carried forward as actionable evidence after human intervention.
            ["kind": "filled", "result": (parts.first as? UIMessagePart.Text)?.text ?? ""]
        case .failed(let text): ["kind": "failed", "result": text]
        case .denied(let text): ["kind": "denied", "result": text]
        case .needsApproval(let text): ["kind": "needs_approval", "result": text]
        case .durabilityFailure(let text): ["kind": "durability_failure", "result": text]
        case .outcomeUnknown: ["kind": "unknown"]
        }
    }

    private func dispatch(_ action: PhoneAction, runner: PhoneRunnerClient) async -> PhoneActionResult {
        guard !Task.isCancelled, controller.canDispatchAction(runID: runID) else {
            return .unsent(.init(.stopped, "自动操作已暂停或停止；本次动作未发送。"))
        }
        return await runner.act(action)
    }

    private func perform(_ request: Request) async -> IOSAgentToolOutcome {
        guard !Task.isCancelled else { return Self.applicationFailure(CancellationError()) }
        switch request {
        case .status:
            await reportActivity(.checkingStatus)
            // Status is useful after stop as well; it never starts a session.
            return .filled(controller.statusText(runID: runID))
        case .stop:
            await reportActivity(.stopping)
            guard let stopped = await controller.stop(runID: runID) else {
                return .denied(Self.json([
                    "outcome": "not_sent", "retry_safe": false,
                    "code": "run_not_authorized", "message": "该 run 已不拥有手机控制会话。",
                ]))
            }
            if let failure = stopped.cleanupFailure {
                return .failed(Self.json([
                    "outcome": "stopped", "cleanup_complete": false, "retry_safe": false,
                    "code": "phone_control_cleanup_failed",
                    "message": failure,
                ]))
            }
            return .filled(Self.json([
                "outcome": "stopped", "cleanup_complete": true, "retry_safe": true,
                "message": "当前 run 已停止接受手机控制动作；已发送的动作不能撤销。",
            ]))
        case .apps(let query, let offset, let limit):
            await reportActivity(.listingApps)
            do {
                let all = try await controller.loadInstalledApplications(runID: runID)
                let matches = all.filter { app in
                    query.isEmpty || app.name.localizedCaseInsensitiveContains(query)
                        || app.bundleID.localizedCaseInsensitiveContains(query)
                }
                let start = min(offset, matches.count)
                let page = matches.dropFirst(start).prefix(limit)
                return .filled(Self.json([
                    "applications": page.map { app -> [String: Any] in
                        var value: [String: Any] = [
                            "name": app.name, "bundle_id": app.bundleID,
                            "selected": controller.selectedBundleIDs.contains(app.bundleID),
                        ]
                        if let isSystem = app.isSystem { value["is_system"] = isSystem }
                        return value
                    },
                    "total": matches.count, "offset": offset,
                    "has_more": start + page.count < matches.count,
                    "message": "本机开发服务返回的应用名称和 ID；名称可能是英文。这里只查询应用，不启动目标 App 或控制 runner。",
                ]))
            } catch {
                return Self.applicationFailure(error)
            }
        case .addApp(let bundleID):
            await reportActivity(.addingApp)
            do {
                let app = try await controller.addInstalledApplication(bundleID: bundleID, runID: runID)
                return .filled(Self.json([
                    "name": app.name, "bundle_id": app.bundleID, "selected": true,
                    "outcome": "completed", "retry_safe": true,
                    "message": "应用已加入允许控制列表，并可在当前任务使用；尚未打开应用或执行界面动作。",
                ]))
            } catch {
                return Self.applicationFailure(error)
            }
        case .observe(let maxNodes, let includeScreenshot):
            switch await prepareRunner() {
            case .outcome(let outcome):
                return outcome
            case .ready(let runner):
                do {
                    await reportActivity(.observing)
                    try Task.checkCancellation()
                    let observation = try await runner.observe(maxNodes: maxNodes, includeScreenSize: true)
                    var parts: [UIMessagePart] = [UIMessagePart.Text(text: observation.compactText, metadata: nil)]
                    if includeScreenshot {
                        let screenshot = try await runner.screenshotObservation()
                        parts.append(UIMessagePart.Text(text: Self.json([
                            "screenshot_observation_id": screenshot.observationID,
                            "screen_width_points": screenshot.width,
                            "screen_height_points": screenshot.height,
                            "tap_point_coordinates": "x/y 为整张截图上的位置比例，左上角是 (0,0)，中心是 (0.5,0.5)，范围 0 <= x,y < 1。只用于图中明确可见但没有可用 ref 的目标；使用本次 screenshot_observation_id 作为 observation_id，不能直接传图片像素。",
                        ]), metadata: nil))
                        parts.append(Self.imagePart(screenshot.data))
                    }
                    return .filledParts(parts)
                } catch {
                    return Self.readFailure(error)
                }
            }
        case .act(let action):
            switch await prepareRunner() {
            case .outcome(let outcome):
                return outcome
            case .ready(let runner):
                await reportActivity(Self.actionActivity(action))
                guard !Task.isCancelled else { return Self.applicationFailure(CancellationError()) }
                return Self.actionOutcome(await dispatch(action, runner: runner))
            }
        case .verifiedAct(let action, let expectation):
            switch await prepareRunner() {
            case .outcome(let outcome): return outcome
            case .ready(let runner):
                let before = await runner.latestObservation
                await reportActivity(Self.actionActivity(action))
                guard !Task.isCancelled else { return Self.applicationFailure(CancellationError()) }
                let receipt = await dispatch(action, runner: runner)
                guard receipt == .completed else { return Self.actionOutcome(receipt) }
                return await verifyCompletedAction(action, expectation: expectation, before: before, runner: runner)
            }
        case .scrollUntil(let request):
            switch await prepareRunner() {
            case .outcome(let outcome): return outcome
            case .ready(let runner):
                let search = IOSPhoneScrollSearch(deps: .init(
                    observe: { try await runner.observe(maxNodes: 1_000, includeScreenSize: true) },
                    act: { await self.dispatch($0, runner: runner) },
                    isCurrent: { [controller, runID] in controller.canDispatchAction(runID: runID) },
                    reportActivity: reportActivity))
                let result = await search.run(request)
                var fields: [String: Any] = [
                    "status": result.status.rawValue, "reason": result.reason,
                    "outcome": result.status == .unknown ? "unknown" : (result.swipeCount == 0 ? "not_sent" : "completed"),
                    "target_visible": result.status == .completed, "swipe_count": result.swipeCount,
                    "retry_safe": result.swipeCount == 0 && result.status != .unknown,
                ]
                if let problem = result.unknownProblem { fields["code"] = problem.kind.rawValue }
                if result.status == .unknown {
                    return .outcomeUnknown([UIMessagePart.Text(text: Self.json(fields), metadata: nil)])
                }
                return await observationResult(fields: fields, observation: result.observation,
                                               needsScreenshot: false, runner: runner)
            }
        case .runGoal(let request):
            guard Self.phoneActionMode() != .off else {
                return .filled(Self.json([
                    "status": "handback", "outcome": "not_sent", "retry_safe": true,
                    "reason_code": "mode_off",
                    "reason": "Jev 手机快速操作未启用或数据范围未开放；可继续使用 phone_observe / phone_act。",
                ]))
            }
            switch await prepareRunner() {
            case .outcome(let outcome): return outcome
            case .ready(let runner):
                let loop = IOSPhoneGoalLoop(deps: .init(
                    observe: { try await runner.observe(maxNodes: 1_000, includeScreenSize: true) },
                    act: { await self.dispatch($0, runner: runner) },
                    choose: { [jev, runID] goal, observation, candidates, recent in
                        await jev.chooseAction(goal: goal, observation: observation, candidates: candidates,
                                               recentSteps: recent, runID: runID)
                    },
                    advise: { [jev, runID] goal, expectation, before, after, verification in
                        await jev.adviseAfterAction(goal: goal, expectation: expectation, before: before,
                                                   after: after, verification: verification, runID: runID)
                    },
                    mode: { Self.phoneActionMode() },
                    isCurrent: { [controller, runID] in controller.canDispatchAction(runID: runID) },
                    reportActivity: reportActivity,
                    configurationRevision: { IOSSharedSettingsStore.loadPersistedJevSettings().revision }
                ))
                let result = await loop.run(request)
                var fields: [String: Any] = [
                    "status": result.status.rawValue,
                    "outcome": result.status == .unknown ? "unknown" : (result.steps.isEmpty ? "not_sent" : "completed"),
                    "goal_satisfied": result.status == .completed,
                    "reason": result.reason, "steps": result.steps,
                    "reason_code": result.reasonCode.rawValue,
                    "candidate_diagnostics": Self.object(result.candidateDiagnostics),
                    "metrics": Self.object(result.metrics),
                    "retry_safe": result.steps.isEmpty && result.status != .unknown,
                ]
                if let verification = result.verification { fields["verification"] = Self.object(verification) }
                if let problem = result.unknownProblem { fields["code"] = problem.kind.rawValue }
                if result.status == .unknown {
                    return .outcomeUnknown([UIMessagePart.Text(text: Self.json(fields), metadata: nil)])
                }
                return await observationResult(fields: fields, observation: result.observation,
                                               needsScreenshot: result.needsScreenshot, runner: runner)
            }
        }
    }

    private func verifyCompletedAction(_ action: PhoneAction, expectation: IOSPhoneGoalExpectation, before: PhoneObservation?,
                                       runner: PhoneRunnerClient) async -> IOSAgentToolOutcome {
        var fields: [String: Any] = ["outcome": "completed", "retry_safe": false,
                                    "message": "动作已收到执行回执；业务效果以 verification 为准，不重放该动作。"]
        guard !Task.isCancelled, controller.ownerRunID == runID else {
            fields["verification"] = ["status": "insufficient", "reason": "run_stopped_after_action"]
            return .filled(Self.json(fields))
        }
        await reportActivity(.verifying)
        do {
            let result = try await IOSPhoneActionVerification.check(
                action: action, expectation: expectation, before: before, dependencies: .init(
                    observe: { try await runner.observe(maxNodes: 1_000, includeScreenSize: true) },
                    isCurrent: { self.controller.canDispatchAction(runID: self.runID) },
                    reportWaiting: { await self.reportActivity(.waitingForUI) }))
            let after = result.observation
            let checked = result.verification
            fields["verification"] = Self.object(checked)
            fields["verification_observations"] = result.observations
            guard !Task.isCancelled, controller.ownerRunID == runID else {
                fields["verification"] = ["status": "insufficient", "reason": "run_stopped_during_verification"]
                return .filled(Self.json(fields))
            }
            let advice = await jev.adviseAfterAction(
                goal: "核验本次动作的指定界面条件", expectation: expectation,
                before: before, after: after, verification: checked, runID: runID)
            fields["next_step"] = advice.rawValue
            return await observationResult(fields: fields, observation: after,
                                           needsScreenshot: checked.needsScreenshot || advice == .needsScreenshot, runner: runner)
        } catch {
            // Observation failing after an acknowledged action does not undo it.
            fields["verification"] = ["status": "insufficient", "reason": error.localizedDescription]
            return .filled(Self.json(fields))
        }
    }

    private func observationResult(fields: [String: Any], observation: PhoneObservation?,
                                   needsScreenshot: Bool, runner: PhoneRunnerClient) async -> IOSAgentToolOutcome {
        var parts: [UIMessagePart] = [UIMessagePart.Text(text: Self.json(fields), metadata: nil)]
        if let observation { parts.append(UIMessagePart.Text(text: observation.compactText, metadata: nil)) }
        if needsScreenshot, observation != nil, !Task.isCancelled, controller.ownerRunID == runID {
            do {
                let screenshot = try await runner.screenshotObservation()
                parts.append(UIMessagePart.Text(text: Self.json([
                    "screenshot_observation_id": screenshot.observationID,
                    "screen_width_points": screenshot.width, "screen_height_points": screenshot.height,
                    "message": "已附新截图交由主模型定位；坐标为整张图的 0 到 1 比例，不可重放之前的动作。",
                ]), metadata: nil))
                parts.append(Self.imagePart(screenshot.data))
            } catch {
                parts.append(UIMessagePart.Text(text: Self.json([
                    "screenshot_available": false, "reason": error.localizedDescription,
                ]), metadata: nil))
            }
        }
        return .filledParts(parts)
    }

    private static func object<T: Encodable>(_ value: T) -> Any {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private static func phoneActionMode() -> IOSJevMode {
        let settings = IOSSharedSettingsStore.loadPersistedJevSettings()
        return settings.canSend(useCase: .phoneActions, required: [.selectedTaskText, .phoneContent])
            ? settings.effectiveMode(for: .phoneActions) : .off
    }

    private func prepareRunner() async -> RunnerPreparation {
        guard controller.ownerRunID == runID else {
            return .outcome(.denied(Self.denial(IOSPhoneControlError.unauthorized)))
        }
        do {
            if controller.phase != .ready { await reportActivity(.connecting) }
            try Task.checkCancellation()
            _ = try await controller.start(runID: runID)
        } catch {
            // Controller.start revokes the matching owner on startup failure; await the
            // minimum cleanup needed before releasing the slot to a later run.
            await controller.stop(runID: runID)
            return .outcome(.failed(Self.startFailure(error)))
        }
        do {
            return .ready(try controller.runner(runID: runID))
        } catch {
            return .outcome(.denied(Self.denial(error)))
        }
    }

    static func actionActivity(_ action: PhoneAction) -> AgentPhoneControlActivityPhase {
        switch action {
        case .launch: .openingApp
        case .tap, .tapPoint: .tapping
        case .type, .clear: .typing
        case .swipe, .swipePoint: .swiping
        case .home: .failed // The phone tool schema does not expose Home.
        }
    }

    static func completionActivity(request: Request, outcome: IOSAgentToolOutcome) -> AgentPhoneControlActivityPhase {
        switch outcome {
        case .filled, .filledParts, .replanRequired: request == .stop ? .stopped : .waitingForModel
        case .outcomeUnknown: .outcomeUnknown
        case .failed, .denied, .durabilityFailure, .needsApproval: .failed
        }
    }

    // Internal seams keep tests focused on argument and engine-result contracts.
    enum Request: Equatable {
        case status
        case apps(query: String, offset: Int, limit: Int)
        case addApp(bundleID: String)
        case observe(maxNodes: Int, includeScreenshot: Bool)
        case act(PhoneAction)
        case verifiedAct(PhoneAction, IOSPhoneGoalExpectation)
        case runGoal(IOSPhoneGoalRequest)
        case scrollUntil(IOSPhoneScrollSearchRequest)
        case stop
    }

    static func request(name: String, arguments: String) throws -> Request {
        guard let data = arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InvalidArguments("参数必须是 JSON 对象。")
        }
        switch name {
        case "phone_status", "phone_stop":
            guard object.isEmpty else { throw InvalidArguments("\(name) 不接受参数。") }
            return name == "phone_status" ? .status : .stop
        case "phone_apps":
            guard Set(object.keys).isSubset(of: ["query", "offset", "limit"]) else {
                throw InvalidArguments("phone_apps 只接受 query、offset 和 limit。")
            }
            let input = try JSONDecoder().decode(ApplicationsArguments.self, from: data)
            let offset = input.offset ?? 0
            let limit = input.limit ?? 50
            guard offset >= 0, (1...100).contains(limit) else {
                throw InvalidArguments("offset 必须大于等于 0；limit 必须是 1 到 100 的整数。")
            }
            return .apps(query: (input.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines), offset: offset, limit: limit)
        case "phone_add_app":
            guard Set(object.keys) == ["bundle_id"] else {
                throw InvalidArguments("phone_add_app 需要且只接受 bundle_id。")
            }
            let input = try JSONDecoder().decode(AddApplicationArguments.self, from: data)
            guard IOSPhoneControlController.validBundleID(input.bundleID) else {
                throw InvalidArguments("bundle_id 必须使用 phone_apps 返回的准确 ID。")
            }
            return .addApp(bundleID: input.bundleID)
        case "phone_observe":
            guard Set(object.keys).isSubset(of: ["max_nodes", "include_screenshot"]) else {
                throw InvalidArguments("phone_observe 只接受 max_nodes 和 include_screenshot。")
            }
            let input = try JSONDecoder().decode(ObserveArguments.self, from: data)
            let maximum = input.maxNodes ?? 500
            guard (1...2000).contains(maximum) else {
                throw InvalidArguments("max_nodes 必须是 1 到 2000 的整数。")
            }
            return .observe(maxNodes: maximum, includeScreenshot: input.includeScreenshot ?? false)
        case "phone_scroll_until":
            guard Set(object.keys).isSubset(of: ["target", "container", "direction", "max_swipes"]) else {
                throw InvalidArguments("phone_scroll_until 包含未知参数。")
            }
            try validateTargetObject(object["target"])
            try validateTargetObject(object["container"])
            let request = try JSONDecoder().decode(IOSPhoneScrollSearchRequest.self, from: data)
            try request.validate()
            return .scrollUntil(request)
        case "phone_run_goal":
            guard Set(object.keys).isSubset(of: ["goal", "bundle_id", "actions", "completion", "max_steps"]) else {
                throw InvalidArguments("phone_run_goal 包含未知参数。")
            }
            try validateExpectationObject(object["completion"])
            guard let actions = object["actions"] as? [[String: Any]] else { throw InvalidArguments("actions 必须是动作数组。") }
            for action in actions {
                guard Set(action.keys).isSubset(of: ["action", "target", "text", "direction"]) else {
                    throw InvalidArguments("候选动作包含未知参数。")
                }
                try validateTargetObject(action["target"])
            }
            let request = try JSONDecoder().decode(IOSPhoneGoalRequest.self, from: data)
            try request.validate()
            guard IOSPhoneControlController.validBundleID(request.bundleID) else { throw InvalidArguments("bundle_id 无效。") }
            return .runGoal(request)
        case "phone_act":
            if object.keys.contains("expectation") { try validateExpectationObject(object["expectation"]) }
            let input = try JSONDecoder().decode(ActionArguments.self, from: data)
            let keys: Set<String>
            let action: PhoneAction
            switch input.action {
            case "launch":
                keys = ["action", "bundle_id"]
                action = .launch(bundleID: try required(input.bundleID, "bundle_id"))
            case "tap":
                keys = ["action", "ref"]
                action = .tap(ref: try required(input.ref, "ref"))
            case "tap_point":
                keys = ["action", "observation_id", "x", "y"]
                guard let x = input.x, let y = input.y,
                      x.isFinite, y.isFinite, (0..<1).contains(x), (0..<1).contains(y) else {
                    throw InvalidArguments("tap_point 的 x/y 必须是整张最新截图上的位置比例，范围 0 <= x,y < 1，不是像素坐标。")
                }
                action = .tapPoint(observationID: try required(input.observationID, "observation_id"), x: x, y: y)
            case "swipe_point":
                keys = ["action", "observation_id", "x", "y", "end_x", "end_y"]
                guard let x = input.x, let y = input.y, let endX = input.endX, let endY = input.endY,
                      [x, y, endX, endY].allSatisfy({ $0.isFinite && (0..<1).contains($0) }),
                      x != endX || y != endY else {
                    throw InvalidArguments("swipe_point 需要最新截图上不同的起点 x/y 和终点 end_x/end_y，范围均为 0 <= 值 < 1，不是像素坐标。")
                }
                action = .swipePoint(observationID: try required(input.observationID, "observation_id"),
                                     startX: x, startY: y, endX: endX, endY: endY)
            case "type":
                keys = ["action", "ref", "text"]
                action = .type(ref: try required(input.ref, "ref"), text: try required(input.text, "text"))
            case "clear":
                keys = ["action", "ref"]
                action = .clear(ref: try required(input.ref, "ref"))
            case "swipe":
                keys = ["action", "ref", "direction"]
                guard let direction = input.direction.flatMap(PhoneSwipeDirection.init(rawValue:)) else {
                    throw InvalidArguments("direction 必须是 up、down、left 或 right。")
                }
                action = .swipe(ref: try required(input.ref, "ref"), direction: direction)
            default:
                throw InvalidArguments("action 必须是 launch、tap、tap_point、type、clear、swipe 或 swipe_point。")
            }
            guard Set(object.keys).isSubset(of: keys.union(["expectation"])) else {
                throw InvalidArguments("\(input.action) 包含不适用的参数。")
            }
            if let expectation = input.expectation {
                try validateExpectationObject(object["expectation"])
                try expectation.validate()
                return .verifiedAct(action, expectation)
            }
            return .act(action)
        default:
            throw InvalidArguments("未知的手机控制工具：\(name)。")
        }
    }

    private static func validateExpectationObject(_ value: Any?) throws {
        guard let object = value as? [String: Any],
              Set(object.keys).isSubset(of: ["kind", "target", "value", "anchor"]) else {
            throw InvalidArguments("验收条件需包含 kind 和 target；仅支持 value、anchor 可选参数。")
        }
        try validateTargetObject(object["target"])
        if let anchor = object["anchor"] { try validateTargetObject(anchor) }
    }

    private static func validateTargetObject(_ value: Any?) throws {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: ["label", "identifier", "type"]) else {
            throw InvalidArguments("目标仅接受精确 label、identifier 和元素 type。")
        }
    }

    static func imagePart(_ png: Data) -> UIMessagePart.Image {
        UIMessagePart.Image(url: "data:image/png;base64,\(png.base64EncodedString())", metadata: nil)
    }

    static func actionOutcome(_ result: PhoneActionResult) -> IOSAgentToolOutcome {
        switch result {
        case .completed:
            return .filled(json([
                "outcome": "completed", "retry_safe": false,
                "message": "控制 runner 已返回执行回执。请重新 phone_observe 验证业务效果，不要重放同一动作。界面未变化不证明控制连接失效；截图点击请对照新截图核对目标中心与刚才的位置。",
            ]))
        case .unsent(let problem):
            let text = json(problemFields(problem, outcome: "not_sent", retrySafe: problem.kind != .previousOutcomeUnknown))
            return isDenied(problem) ? .denied(text) : .failed(text)
        case .unknown(let problem):
            let text = json(problemFields(problem, outcome: "unknown", retrySafe: false))
            return .outcomeUnknown([UIMessagePart.Text(text: text, metadata: nil)])
        }
    }

    private static func startFailure(_ error: Error) -> String {
        json([
            "outcome": "not_sent", "retry_safe": false,
            "code": "phone_control_start_failed",
            "message": "本机手机控制会话启动失败；本次未发送任何手机动作。",
            "detail": error.localizedDescription,
        ])
    }

    private enum RunnerPreparation {
        case ready(PhoneRunnerClient)
        case outcome(IOSAgentToolOutcome)
    }

    private static func readFailure(_ error: Error) -> IOSAgentToolOutcome {
        if let problem = error as? PhoneControlProblem {
            let text = json(problemFields(problem, outcome: "not_sent", retrySafe: true))
            return isDenied(problem) ? .denied(text) : .failed(text)
        }
        return .failed(json([
            "outcome": "not_sent", "retry_safe": true,
            "code": "observation_failed", "message": error.localizedDescription,
        ]))
    }

    private static func applicationFailure(_ error: Error) -> IOSAgentToolOutcome {
        if let error = error as? IOSPhoneControlError, case .unauthorized = error {
            return .denied(denial(error))
        }
        if let problem = error as? PhoneControlProblem {
            let result = json(problemFields(problem, outcome: "not_sent", retrySafe: !isDenied(problem)))
            return isDenied(problem) ? .denied(result) : .failed(result)
        }
        return .failed(json([
            "outcome": "not_sent", "retry_safe": false,
            "code": "phone_app_catalog_failed", "message": error.localizedDescription,
        ]))
    }

    private static func isDenied(_ problem: PhoneControlProblem) -> Bool {
        problem.kind == .appOutOfScope || problem.kind == .stopped
            || problem.kind == .previousOutcomeUnknown
    }

    private static func problemFields(_ problem: PhoneControlProblem, outcome: String, retrySafe: Bool) -> [String: Any] {
        var fields: [String: Any] = [
            "outcome": outcome, "retry_safe": retrySafe,
            "code": problem.kind.rawValue, "message": problem.message,
            "dropped_before_execution": problem.wasDroppedBeforeExecution,
        ]
        if let status = problem.statusCode { fields["http_status"] = status }
        if let code = problem.runnerCode { fields["runner_code"] = code }
        return fields
    }

    private static func denial(_ error: Error) -> String {
        json([
            "outcome": "not_sent", "retry_safe": false,
            "code": "run_not_authorized", "message": error.localizedDescription,
        ])
    }

    private static func required(_ value: String?, _ name: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw InvalidArguments("\(name) 是必填的非空字符串。")
        }
        return value
    }

    private static func json(_ value: [String: Any]) -> String {
        // All result fields are primitives, so serialization cannot fail.
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private struct ApplicationsArguments: Decodable {
        let query: String?
        let offset: Int?
        let limit: Int?
    }

    private struct AddApplicationArguments: Decodable {
        let bundleID: String
        enum CodingKeys: String, CodingKey { case bundleID = "bundle_id" }
    }

    private struct ObserveArguments: Decodable {
        let maxNodes: Int?
        let includeScreenshot: Bool?
        enum CodingKeys: String, CodingKey {
            case maxNodes = "max_nodes", includeScreenshot = "include_screenshot"
        }
    }

    private struct ActionArguments: Decodable {
        let action: String
        let bundleID: String?
        let ref: String?
        let text: String?
        let direction: String?
        let observationID: String?
        let x: Double?
        let y: Double?
        let endX: Double?
        let endY: Double?
        let expectation: IOSPhoneGoalExpectation?
        enum CodingKeys: String, CodingKey {
            case action, bundleID = "bundle_id", ref, text, direction
            case observationID = "observation_id", x, y
            case endX = "end_x", endY = "end_y", expectation
        }
    }

    private struct InvalidArguments: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
