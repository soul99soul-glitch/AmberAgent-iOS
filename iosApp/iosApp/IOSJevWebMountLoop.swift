import Foundation
@preconcurrency import Shared

// MARK: - Jev 网页有界快速循环（Phase 3）
//
// 契约（计划 Phase 3.4）：
// - 主模型显式调用才进入循环；输入带 session、目标、允许操作范围与完成条件；
//   运行时预算不能被输入调大（默认 6 次动作决策 / 15 秒 / 3 次无进展，且服从
//   run 总预算——由协调器账本兜底）。
// - 每轮观察当前页面，只用本次快照中合法的元素与操作；快照 revision 失效就
//   重新观察，不猜 selector/坐标/复用旧目标。
// - 动作白名单（v1）：观察/读取/滚动、选择筛选项/展开/导航链接、输入/修改
//   草稿值、提交只读搜索。发送消息/发布/改记录/一般提交、删除/支付/登录/
//   验证码 → 一律交回主模型（handback），不进快速循环。
// - 文本值由主模型提供（随 goal 输入），缺值/复杂表达 → handback；Jev 不生成
//   任意字符串。
// - 每个实际副作用动作经注入的 executor（内层审批/账本由现有 WebMount 执行链
//   负责）；一次外层允许不能替代内层每步权限。
// - 未知执行结果保持 outcome_unknown，禁止自动重放同一潜在副作用动作。
// - Jev 的 DONE 只是候选终态：完成必须由完成检查（页面/业务状态）核验。
// - v1 交付边界：本服务以 dry-run/shadow 语义运行（决策轨迹）；动作执行仅在
//   active 且注入真实 executor 后发生，启用依赖真实凭据与验收。

@MainActor
final class IOSJevWebMountLoopService {

    // MARK: Input / observation types

    struct LoopInput {
        var sessionId: String
        var goal: String
        /// 主模型提供的草稿值（type_draft 用）；缺值时该类动作 handback。
        var draftValue: String?
        /// 主模型声明的允许范围（动作名集合）；只能小于白名单，不能放大。
        var allowedActions: Set<String>
        /// 主模型给的可选更小预算；nil = 默认。
        var maxActionDecisions: Int?
        var maxSeconds: Int?
        var maxNoProgress: Int?
    }

    struct PageElement: Equatable {
        var id: String
        var role: String
        var label: String
    }

    struct PageObservation: Equatable {
        var snapshotId: String
        var revision: Int
        var url: String
        var elements: [PageElement]
    }

    enum ActionKind: String, Equatable {
        case scroll = "scroll"
        case select = "select"
        case clickNav = "click_nav"
        case typeDraft = "type_draft"
        case submitReadonlySearch = "submit_readonly_search"
    }

    /// v1 动作白名单：读取/导航/草稿/只读搜索。之外的动作一律 handback。
    static let actionWhitelist: Set<String> = [
        ActionKind.scroll.rawValue,
        ActionKind.select.rawValue,
        ActionKind.clickNav.rawValue,
        ActionKind.typeDraft.rawValue,
        ActionKind.submitReadonlySearch.rawValue,
    ]

    struct PlannedAction {
        var kind: ActionKind
        var elementId: String?
        var value: String?
        /// 决策所依据的快照 revision：执行端口据此重验，防 decide→execute
        /// 窗口内页面变化导致旧目标被执行。
        var snapshotRevision: Int = 0
    }

    // MARK: Outcome

    enum LoopOutcome: Equatable {
        case completed(steps: [String], finalObservation: PageObservation?)
        case handback(reason: String, steps: [String], latestObservation: PageObservation?)
        case needsUserAction(reason: String, steps: [String])
        case cancelled(steps: [String])
        case outcomeUnknown(action: String, steps: [String])
    }

    // MARK: Injected ports（真实接线在 ChatToolRuntime 的 WebMount 执行链；测试用 fake）

    typealias Observer = (_ sessionId: String) async -> PageObservation?
    typealias Executor = (_ sessionId: String, _ action: PlannedAction) async -> ExecutorResult

    enum ExecutorResult {
        case applied(newRevision: Int)
        /// 快照已失效（决策后页面变化）——循环回到顶部重新观察，不计失败。
        case stale
        /// 语义未知（例如点击后页面状态无法确认）——禁止重放。
        case unknown
        case failed(reason: String)
        case denied(reason: String)
    }

    // MARK: Tool-entry binding helpers（wm_run_goal 分支使用；纯函数便于单测）

    /// 从 wm_run_goal 工具入参解析 LoopInput。allowed_actions 缺省 = 全白名单；
    /// 出现时只能收窄（越界名直接丢弃，不报错、不放大）。
    static func loopInput(fromArguments object: [String: Any]) -> LoopInput? {
        guard let sessionId = (object["session_id"] as? String)?.nilIfBlank,
              let goal = (object["goal"] as? String)?.nilIfBlank else { return nil }
        let rawAllowed = ((object["allowed_actions"] as? [String]) ?? []).compactMap { $0.nilIfBlank }
        let allowed = rawAllowed.isEmpty ? actionWhitelist : Set(rawAllowed).intersection(actionWhitelist)
        func boundedCount(_ key: String) -> Int? {
            (object[key] as? NSNumber).flatMap { Int($0.doubleValue) }
        }
        return LoopInput(
            sessionId: sessionId,
            goal: goal,
            draftValue: (object["draft_value"] as? String)?.nilIfBlank,
            allowedActions: allowed,
            maxActionDecisions: boundedCount("max_action_decisions"),
            maxSeconds: boundedCount("max_seconds"),
            maxNoProgress: boundedCount("max_no_progress")
        )
    }

    /// 完成核验：completion_text 出现在 URL 或任一可见元素 label 中。缺省标记
    /// 永不完成 → 循环只能以预算/handback 边界退出（安全侧）。
    static func isComplete(marker: String, observation: PageObservation) -> Bool {
        let needle = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        if observation.url.localizedCaseInsensitiveContains(needle) { return true }
        return observation.elements.contains { $0.label.localizedCaseInsensitiveContains(needle) }
    }

    /// wm_observe 输出 JSON → PageObservation。缺 snapshot_id 视为观察失败。
    static func observation(fromObservePayload object: [String: Any]) -> PageObservation? {
        guard let snapshotId = (object["snapshot_id"] as? String)?.nilIfBlank else { return nil }
        let revision = (object["page_revision"] as? NSNumber).flatMap { Int($0.doubleValue) } ?? 0
        let page = object["page"] as? [String: Any]
        let url = ((page?["url"] as? String) ?? (object["url"] as? String)) ?? ""
        let nodes = object["interactive_elements"] as? [[String: Any]] ?? []
        let elements = nodes.compactMap { node -> PageElement? in
            guard let ref = (node["ref"] as? String)?.nilIfBlank else { return nil }
            return PageElement(
                id: ref,
                role: (node["role"] as? String) ?? "",
                label: ((node["text"] as? String) ?? (node["name"] as? String)) ?? ""
            )
        }
        return PageObservation(snapshotId: snapshotId, revision: revision, url: url, elements: elements)
    }

    /// LoopOutcome → wm_run_goal 工具输出 JSON（bounded）。
    static func outputText(for outcome: LoopOutcome, goal: String) -> String {
        var object: [String: Any] = ["goal": String(goal.prefix(200))]
        func boundedSteps(_ values: [String]) -> [String] { Array(values.prefix(12)) }
        switch outcome {
        case .completed(let steps, let observation):
            object["status"] = "completed"
            object["steps"] = boundedSteps(steps)
            if let observation {
                object["final_url"] = String(observation.url.prefix(300))
                object["snapshot_id"] = observation.snapshotId
            }
        case .handback(let reason, let steps, let observation):
            object["status"] = "handback"
            object["reason"] = reason
            object["steps"] = boundedSteps(steps)
            if let observation {
                object["latest_url"] = String(observation.url.prefix(300))
                object["snapshot_id"] = observation.snapshotId
                object["next_step_hint"] = "由主模型按现有 WebMount 工具流程继续，或向用户说明。"
            }
        case .needsUserAction(let reason, let steps):
            object["status"] = "needs_user_action"
            object["reason"] = reason
            object["steps"] = boundedSteps(steps)
        case .cancelled(let steps):
            object["status"] = "cancelled"
            object["steps"] = boundedSteps(steps)
        case .outcomeUnknown(let action, let steps):
            // 与 WebMount 既有语义对齐：未知结果禁止重放同一副作用动作。
            object["status"] = "unknown_after_action"
            object["may_have_applied"] = true
            object["action"] = action
            object["steps"] = boundedSteps(steps)
            object["next_step_hint"] = "不要重放该动作；先只读核验页面状态。"
        }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return #"{"status":"handback","reason":"循环输出序列化失败。"}"#
    }

    struct Dependencies {
        let coordinator: IOSJevDecisionCoordinator
        let settingsProvider: () -> IOSJevSettings
        var observe: Observer
        var execute: Executor
        /// 完成检查：由页面/业务状态核验（不是 Jev 的 DONE）。
        var isComplete: (_ sessionId: String, _ observation: PageObservation) -> Bool
    }

    private let deps: Dependencies

    init(deps: Dependencies) {
        self.deps = deps
    }

    // MARK: Loop

    struct Constants {
        static let defaultMaxActionDecisions = 6
        static let defaultMaxSeconds = 15
        static let defaultMaxNoProgress = 3
    }

    func run(
        _ input: LoopInput,
        runId: String?
    ) async -> LoopOutcome {
        let loopTurnBudgetKey = IOSJevToolDiscoveryService.turnBudgetKey(runId: runId)
        let settings = deps.settingsProvider()
        let mode = settings.effectiveMode(for: .webActions)
        guard mode != .off else {
            return .handback(reason: "Jev 网页快速循环未启用。", steps: [], latestObservation: nil)
        }
        // v1：只有 active 才可能执行动作；shadow/dry-run 只产出决策轨迹。
        let mayExecute = (mode == .active)
        let requiredScopes: Set<IOSJevDataScope> = [.webContent, .selectedTaskText]
        guard settings.canSend(useCase: .webActions, required: requiredScopes) else {
            return .handback(reason: "数据范围未允许网页内容外发。", steps: [], latestObservation: nil)
        }

        var steps: [String] = []
        let maxDecisions = min(input.maxActionDecisions ?? Constants.defaultMaxActionDecisions, Constants.defaultMaxActionDecisions)
        let maxSeconds = min(input.maxSeconds ?? Constants.defaultMaxSeconds, Constants.defaultMaxSeconds)
        let maxNoProgress = min(input.maxNoProgress ?? Constants.defaultMaxNoProgress, Constants.defaultMaxNoProgress)
        let startedAt = Date()

        var noProgressCount = 0
        var lastUrl: String?

        while steps.count < maxDecisions {
            if Task.isCancelled {
                return .cancelled(steps: steps)
            }
            if Date().timeIntervalSince(startedAt) > TimeInterval(maxSeconds) {
                // 预算边界退出前仍做一次完成核验（最后一次动作可能已达成目标）。
                if let finalObservation = await deps.observe(input.sessionId),
                   deps.isComplete(input.sessionId, finalObservation) {
                    return .completed(steps: steps, finalObservation: finalObservation)
                }
                return .handback(reason: "快速循环时间预算（\(maxSeconds)s）耗尽。", steps: steps, latestObservation: nil)
            }

            // 每轮观察当前页面（快照失效就重观察；观察本身也计步）。
            guard let observation = await deps.observe(input.sessionId) else {
                return .handback(reason: "无法获取页面快照。", steps: steps, latestObservation: nil)
            }
            let urlChanged = lastUrl.map { $0 != observation.url } ?? false
            lastUrl = observation.url

            // 完成检查先于下一次决策：DONE 由页面/业务状态核验。
            if deps.isComplete(input.sessionId, observation) {
                return .completed(steps: steps, finalObservation: observation)
            }

            // 构建本轮合法动作候选（白名单 ∩ 输入允许 ∩ 快照元素存在）。
            let candidates = Self.legalActionCandidates(
                input: input,
                observation: observation,
                urlChanged: urlChanged
            )
            if candidates.isEmpty {
                return .handback(reason: "当前快照下没有白名单内的可行动作。", steps: steps, latestObservation: observation)
            }

            // Jev Choice：从候选中选一个（低置信 → handback）。
            let chosen: IOSJevWebMountLoopService.PlannedAction
            switch await chooseAction(
                input: input,
                observation: observation,
                candidates: candidates,
                settings: settings,
                turnBudgetKey: loopTurnBudgetKey
            ) {
            case .chose(let action):
                chosen = action
            case .cancelled:
                return .cancelled(steps: steps)
            case .indeterminate:
                return .handback(reason: "Jev 无法确定下一步动作（低置信/失败/不确定）。", steps: steps, latestObservation: observation)
            }

            if !mayExecute {
                // dry-run/shadow：只记录决策轨迹，不执行。
                steps.append("dry-run: \(chosen.kind.rawValue) \(chosen.elementId ?? "-")")
                continue
            }

            // 执行：内层审批/账本由现有 WebMount 执行链负责。
            let result = await deps.execute(input.sessionId, chosen)
            switch result {
            case .applied(let newRevision):
                steps.append("\(chosen.kind.rawValue) \(chosen.elementId ?? "-") @r\(newRevision)")
                // 无进展判定：revision 未变视为原地等待（同样计步/时间）。
                noProgressCount = newRevision == observation.revision ? noProgressCount + 1 : 0
            case .stale:
                // decide→execute 窗口内页面已变：不执行、不计步，回到顶部重观察。
                continue
            case .unknown:
                // 未知执行结果：保持 unknown，禁止重放同一动作。
                steps.append("unknown: \(chosen.kind.rawValue) \(chosen.elementId ?? "-")")
                return .outcomeUnknown(action: "\(chosen.kind.rawValue) \(chosen.elementId ?? "-")", steps: steps)
            case .failed(let reason):
                return .handback(reason: "动作失败：\(reason)", steps: steps, latestObservation: observation)
            case .denied(let reason):
                return .needsUserAction(reason: reason, steps: steps)
            }

            if noProgressCount >= maxNoProgress {
                return .handback(reason: "连续 \(noProgressCount) 次无进展。", steps: steps, latestObservation: observation)
            }
        }
        // 决策次数耗尽：最后一次动作可能已达成目标，做边界完成核验。
        if let finalObservation = await deps.observe(input.sessionId),
           deps.isComplete(input.sessionId, finalObservation) {
            return .completed(steps: steps, finalObservation: finalObservation)
        }
        return .handback(reason: "动作决策次数（\(maxDecisions)）耗尽。", steps: steps, latestObservation: nil)
    }

    // MARK: Legal action candidates

    static func legalActionCandidates(
        input: LoopInput,
        observation: PageObservation,
        urlChanged: Bool
    ) -> [PlannedAction] {
        // 基线观察权：滚动始终可用（只读、无目标语义）；allowedActions 只能
        // 再收窄目标类动作，不能放大白名单。
        var candidates: [PlannedAction] = [
            PlannedAction(kind: .scroll, elementId: nil, value: nil, snapshotRevision: observation.revision)
        ]
        let allowed = input.allowedActions.intersection(actionWhitelist)
        for element in observation.elements {
            // 控件角色契约：动作语义来自快照中已验证的控件类型，不凭按钮文案推断。
            let role = element.role.lowercased()
            if allowed.contains(ActionKind.clickNav.rawValue), role == "link" {
                candidates.append(PlannedAction(kind: .clickNav, elementId: element.id, value: nil, snapshotRevision: observation.revision))
            }
            if allowed.contains(ActionKind.select.rawValue),
               ["combobox", "listbox", "checkbox", "radio"].contains(role) {
                candidates.append(PlannedAction(kind: .select, elementId: element.id, value: nil, snapshotRevision: observation.revision))
            }
            if allowed.contains(ActionKind.typeDraft.rawValue), role == "textbox" {
                // 缺草稿值 → 该类动作不作为候选（交回主模型补值）。
                if let value = input.draftValue, !value.isEmpty {
                    candidates.append(PlannedAction(kind: .typeDraft, elementId: element.id, value: value, snapshotRevision: observation.revision))
                }
            }
            if allowed.contains(ActionKind.submitReadonlySearch.rawValue), role == "searchbox" {
                // 与 type_draft 口径一致：缺值不出候选（提交空查询无意义）。
                if let value = input.draftValue, !value.isEmpty {
                    candidates.append(PlannedAction(kind: .submitReadonlySearch, elementId: element.id, value: value, snapshotRevision: observation.revision))
                }
            }
        }
        return candidates
    }

    // MARK: Choice

    /// 决策结果：chose = 可执行；cancelled = 任务已取消（终态）；其余 = 不确定。
    enum ChooseOutcome {
        case chose(PlannedAction)
        case cancelled
        case indeterminate
    }

    private func chooseAction(
        input: LoopInput,
        observation: PageObservation,
        candidates: [PlannedAction],
        settings: IOSJevSettings,
        turnBudgetKey: String
    ) async -> ChooseOutcome {
        let bounded = candidates.prefix(64) // 单请求 ≤64 候选
        var lines: [String] = []
        lines.append("用户目标：\(String(input.goal.prefix(1_000)))")
        lines.append("页面 URL：\(observation.url)")
        lines.append("页面元素（元素 id）：")
        for element in observation.elements.prefix(30) {
            lines.append("- \(element.id) [\(element.role)] \(element.label)")
        }
        let state = lines.joined(separator: "\n")
        let questions = [IOSJevQuestion.choice(
            id: "next_action",
            options: Dictionary(
                bounded.map { candidate -> (String, String?) in
                    (Self.optionLabel(candidate), nil)
                },
                uniquingKeysWith: { first, _ in first }
            ),
            instructions: "选择下一步动作。只依据当前快照与目标；不确定时选择 scroll。禁止推断白名单之外的语义。"
        )]
        let context = IOSJevRunContext(
            runId: turnBudgetKey,
            turnBudgetKey: turnBudgetKey,
            inputHash: IOSJevToolDiscoveryService.stableHash(state + "|" + bounded.map(\.kind.rawValue).joined(separator: ","))
        )
        let outcome = await deps.coordinator.decide(
            useCase: .webActions,
            requiredScopes: [.webContent, .selectedTaskText],
            state: state,
            questions: questions,
            context: context,
            cacheKey: nil // 网页动作不缓存
        )
        // dry-run/shadow 的决策轨迹消费 observed 结果；执行仍由 mayExecute 把关。
        let decision: IOSJevDecision
        switch outcome {
        case .applied(let value), .observed(let value):
            decision = value
        case .skipped:
            return .indeterminate
        case .failed(let reason) where reason == "cancelled":
            return .cancelled
        case .failed:
            return .indeterminate
        }
        guard let answer = decision.answers.first(where: { $0.id == "next_action" }),
              answer.type == "choice",
              let chosenLabel = answer.choice,
              let chosen = bounded.first(where: { Self.optionLabel($0) == chosenLabel }) else {
            return .indeterminate
        }
        return .chose(chosen)
    }

    static func optionLabel(_ action: PlannedAction) -> String {
        var label = action.kind.rawValue
        if let elementId = action.elementId { label += "@\(elementId)" }
        if action.kind == .typeDraft || action.kind == .submitReadonlySearch { label += "#v" }
        return label
    }
}
