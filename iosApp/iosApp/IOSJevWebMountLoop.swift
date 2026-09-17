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
        /// 语义未知（例如点击后页面状态无法确认）——禁止重放。
        case unknown
        case failed(reason: String)
        case denied(reason: String)
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
            guard let chosen = await chooseAction(
                input: input,
                observation: observation,
                candidates: candidates,
                settings: settings
            ) else {
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
        var candidates: [PlannedAction] = [PlannedAction(kind: .scroll, elementId: nil, value: nil)]
        let allowed = input.allowedActions.intersection(actionWhitelist)
        for element in observation.elements {
            // 控件角色契约：动作语义来自快照中已验证的控件类型，不凭按钮文案推断。
            let role = element.role.lowercased()
            if allowed.contains(ActionKind.clickNav.rawValue), role == "link" {
                candidates.append(PlannedAction(kind: .clickNav, elementId: element.id, value: nil))
            }
            if allowed.contains(ActionKind.select.rawValue),
               ["combobox", "listbox", "checkbox", "radio"].contains(role) {
                candidates.append(PlannedAction(kind: .select, elementId: element.id, value: nil))
            }
            if allowed.contains(ActionKind.typeDraft.rawValue), role == "textbox" {
                // 缺草稿值 → 该类动作不作为候选（交回主模型补值）。
                if let value = input.draftValue, !value.isEmpty {
                    candidates.append(PlannedAction(kind: .typeDraft, elementId: element.id, value: value))
                }
            }
            if allowed.contains(ActionKind.submitReadonlySearch.rawValue), role == "searchbox" {
                candidates.append(PlannedAction(kind: .submitReadonlySearch, elementId: element.id, value: input.draftValue))
            }
        }
        return candidates
    }

    // MARK: Choice

    private func chooseAction(
        input: LoopInput,
        observation: PageObservation,
        candidates: [PlannedAction],
        settings: IOSJevSettings
    ) async -> PlannedAction? {
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
            runId: nil,
            turnBudgetKey: "web-loop",
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
        case .skipped, .failed:
            return nil
        }
        guard let answer = decision.answers.first(where: { $0.id == "next_action" }),
              answer.type == "choice",
              let chosenLabel = answer.choice else {
            return nil
        }
        return bounded.first { Self.optionLabel($0) == chosenLabel }
    }

    static func optionLabel(_ action: PlannedAction) -> String {
        var label = action.kind.rawValue
        if let elementId = action.elementId { label += "@\(elementId)" }
        if action.kind == .typeDraft || action.kind == .submitReadonlySearch { label += "#v" }
        return label
    }
}
