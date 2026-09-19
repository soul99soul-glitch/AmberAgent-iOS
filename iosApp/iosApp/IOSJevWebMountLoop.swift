import Foundation
@preconcurrency import Shared

// MARK: - Jev 网页有界快速循环（Phase 3）
//
// 契约（计划 Phase 3.4）：
// - 主模型显式调用才进入循环；输入带 session、目标、允许操作范围与完成条件；
//   运行时预算不能被输入调大（默认 100 次动作决策 / 600 秒 / 10 次无进展，
//   且服从 run 总预算——由协调器账本兜底）。
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
        /// 视口滚动位置（wm_observe page.scroll.y）：滚动类动作的进展判定
        /// 以状态指纹为准（revision 空转不算进展），也作为 Jev state 的
        /// "是否已到页底"信号。
        var scrollY: Int = 0
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
        /// 决策所依据的快照 id：wm_* 变更工具 required 绑定（stale_snapshot
        /// 拒绝拿旧快照猜目标）。由候选构建时随观察快照带出。
        var snapshotId: String = ""
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
        let scroll = (object["scroll"] as? [String: Any]) ?? (page?["scroll"] as? [String: Any])
        let scrollY = (scroll?["y"] as? NSNumber).flatMap { Int($0.doubleValue) } ?? 0
        return PageObservation(snapshotId: snapshotId, revision: revision, url: url, elements: elements, scrollY: scrollY)
    }

    /// 滚动进展指纹：滚动事件本身也 bump revision，所以 scroll 是否"有进展"
    /// 必须按页面状态判定——URL、滚动位置或可见元素集合任一变化才算；
    /// 底部空滚指纹不变 → 计入无进展，no-progress 上限才拦得住。
    static func progressFingerprint(_ observation: PageObservation) -> String {
        let ids = observation.elements.map(\.id).sorted().joined(separator: ",")
        return "\(observation.url)|\(observation.scrollY)|\(ids)"
    }

    /// LoopOutcome → wm_run_goal 工具输出 JSON（bounded）。effectiveMode 让主模型
    /// 直接区分 shadow 空转与 active 落地（配置 mode=active 不等于 effective_mode=active）。
    static func outputText(
        for outcome: LoopOutcome,
        goal: String,
        effectiveMode: IOSJevMode? = nil
    ) -> String {
        var object: [String: Any] = ["goal": String(goal.prefix(200))]
        if let effectiveMode {
            object["effective_mode"] = effectiveMode.rawValue
        }
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
        /// 真实自动化口径：单目标几十至上百步属正常负载；上限仍是防失控熔断。
        static let defaultMaxActionDecisions = 100
        static let defaultMaxSeconds = 600
        static let defaultMaxNoProgress = 10
        /// Choice 置信下限：低于则 handback，不执行猜测动作；置信缺失不门控。
        static let lowConfidenceThreshold = 0.5
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
        /// 上一次 scroll 动作的前置指纹：下一轮观察后据此判定"滚动是否带来
        /// 新内容"——空转滚动 revision 照样递增，不算进展。
        var pendingScrollFingerprint: String?
        /// 连续空转滚动计数：>0 时向 Jev state 注入"已到页底"提示。
        var scrollStallCount = 0

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

            // 上一轮 scroll 的进展核验：页面状态指纹没变 = 空转滚动，计无进展
            // （底部空滚也 bump revision，revision 比较会被骗过）。
            if let preScroll = pendingScrollFingerprint {
                pendingScrollFingerprint = nil
                if Self.progressFingerprint(observation) == preScroll {
                    noProgressCount += 1
                    scrollStallCount += 1
                } else {
                    noProgressCount = 0
                    scrollStallCount = 0
                }
            }

            // 完成检查先于下一次决策：DONE 由页面/业务状态核验。
            if deps.isComplete(input.sessionId, observation) {
                return .completed(steps: steps, finalObservation: observation)
            }

            if noProgressCount >= maxNoProgress {
                return .handback(reason: "连续 \(noProgressCount) 次无进展（滚动未带来新内容）。", steps: steps, latestObservation: observation)
            }

            // 构建本轮合法动作候选（白名单 ∩ 输入允许 ∩ 快照元素存在）。
            let candidates = Self.legalActionCandidates(
                input: input,
                observation: observation
            )
            if candidates.isEmpty {
                return .handback(reason: "当前快照下没有白名单内的可行动作。", steps: steps, latestObservation: observation)
            }

            // Jev Choice：从候选中选一个（低置信/失败/跳过 → handback）。
            let chosen: IOSJevWebMountLoopService.PlannedAction
            let choseApplicable: Bool
            switch await chooseAction(
                input: input,
                observation: observation,
                candidates: candidates,
                turnBudgetKey: loopTurnBudgetKey,
                scrollStalled: scrollStallCount > 0
            ) {
            case .chose(let action, let applicable):
                chosen = action
                choseApplicable = applicable
            case .cancelled:
                return .cancelled(steps: steps)
            case .indeterminate(let reason):
                return .handback(reason: "Jev 无法确定下一步动作（\(reason)）。", steps: steps, latestObservation: observation)
            }

            // 执行门双重校验：协调器 decide 时点的 mode（applicable）与当前
            // effectiveMode。中途降级/取消 pin 后，shadow 观测到的决策只记
            // dry-run 轨迹——「shadow 只观测不应用」不能被启动时的快照绕过。
            let mayExecuteNow = deps.settingsProvider().effectiveMode(for: .webActions) == .active
            if !mayExecuteNow || !choseApplicable {
                steps.append("dry-run: \(chosen.kind.rawValue) \(chosen.elementId ?? "-")")
                continue
            }

            // 执行：内层审批/账本由现有 WebMount 执行链负责。
            let result = await deps.execute(input.sessionId, chosen)
            switch result {
            case .applied(let newRevision):
                steps.append("\(chosen.kind.rawValue) \(chosen.elementId ?? "-") @r\(newRevision)")
                if chosen.kind == .scroll {
                    // 滚动事件本身也 bump revision：进展延到下一轮观察按
                    // 状态指纹判定，防止底部空滚被记成"有进展"烧穿预算。
                    pendingScrollFingerprint = Self.progressFingerprint(observation)
                } else {
                    pendingScrollFingerprint = nil
                    scrollStallCount = 0
                    // 非滚动动作：revision 未变视为原地等待（同样计步/时间）。
                    noProgressCount = newRevision == observation.revision ? noProgressCount + 1 : 0
                }
            case .stale:
                // decide→execute 窗口内页面已变：不执行、不计步，回到顶部重观察。
                // 计入无进展防页面热变时空转烧请求。
                noProgressCount += 1
                if noProgressCount >= maxNoProgress {
                    return .handback(reason: "快照连续失效（页面变化过快，\(noProgressCount) 次）。", steps: steps, latestObservation: observation)
                }
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
        observation: PageObservation
    ) -> [PlannedAction] {
        // 基线观察权：滚动始终可用（只读、无目标语义）；allowedActions 只能
        // 再收窄目标类动作，不能放大白名单。
        var candidates: [PlannedAction] = [
            PlannedAction(kind: .scroll, elementId: nil, value: nil, snapshotRevision: observation.revision, snapshotId: observation.snapshotId)
        ]
        let allowed = input.allowedActions.intersection(actionWhitelist)
        for element in observation.elements {
            // 控件角色契约：动作语义来自快照中已验证的控件类型，不凭按钮文案推断。
            let role = element.role.lowercased()
            if allowed.contains(ActionKind.clickNav.rawValue), role == "link" {
                candidates.append(PlannedAction(kind: .clickNav, elementId: element.id, value: nil, snapshotRevision: observation.revision, snapshotId: observation.snapshotId))
            }
            if allowed.contains(ActionKind.select.rawValue),
               ["combobox", "listbox", "checkbox", "radio"].contains(role) {
                candidates.append(PlannedAction(kind: .select, elementId: element.id, value: nil, snapshotRevision: observation.revision, snapshotId: observation.snapshotId))
            }
            if allowed.contains(ActionKind.typeDraft.rawValue), role == "textbox" {
                // 缺草稿值 → 该类动作不作为候选（交回主模型补值）。
                if let value = input.draftValue, !value.isEmpty {
                    candidates.append(PlannedAction(kind: .typeDraft, elementId: element.id, value: value, snapshotRevision: observation.revision, snapshotId: observation.snapshotId))
                }
            }
            if allowed.contains(ActionKind.submitReadonlySearch.rawValue), role == "searchbox" {
                // 与 type_draft 口径一致：缺值不出候选（提交空查询无意义）。
                if let value = input.draftValue, !value.isEmpty {
                    candidates.append(PlannedAction(kind: .submitReadonlySearch, elementId: element.id, value: value, snapshotRevision: observation.revision, snapshotId: observation.snapshotId))
                }
            }
        }
        return candidates
    }

    // MARK: Choice

    /// 决策结果：chose = 可执行；cancelled = 任务已取消（终态）；
    /// indeterminate = 不确定，reason 透传协调器码（skipped/failed/答案不可用/
    /// 低置信），handback 时暴露给主模型用于判断重试路径。
    enum ChooseOutcome {
        /// applicable = 协调器 decide 时点按 active 应用（applied）；
        /// shadow 观测结果（observed）带 false，只能进 dry-run 轨迹。
        case chose(PlannedAction, applicable: Bool)
        case cancelled
        case indeterminate(reason: String)
    }

    private func chooseAction(
        input: LoopInput,
        observation: PageObservation,
        candidates: [PlannedAction],
        turnBudgetKey: String,
        scrollStalled: Bool
    ) async -> ChooseOutcome {
        let bounded = candidates.prefix(64) // 单请求 ≤64 候选
        var lines: [String] = []
        lines.append("用户目标：\(String(input.goal.prefix(1_000)))")
        lines.append("页面 URL：\(String(observation.url.prefix(300)))")
        lines.append("页面滚动位置：y=\(observation.scrollY)")
        if scrollStalled {
            // 没有这条信号 Jev 无法知道滚动已无效，会在页底无限空滚。
            lines.append("提示：上一次滚动未带来新内容，页面疑似已到可滚动底部；若目标控件已在元素列表中，优先选对应动作，不要继续 scroll。")
        }
        lines.append("页面元素（元素 id）：")
        for element in observation.elements.prefix(30) {
            // label 来自页面文本不设上限：截断防整包超 maxRequestBytes。
            lines.append("- \(element.id) [\(element.role)] \(String(element.label.prefix(120)))")
        }
        let state = lines.joined(separator: "\n")
        let questions = [IOSJevQuestion.choice(
            id: "next_action",
            options: Dictionary(
                bounded.map { candidate -> (String, String?) in
                    (Self.optionLabel(candidate), Self.optionDescription(candidate, in: observation))
                },
                uniquingKeysWith: { first, _ in first }
            ),
            instructions: "选择下一步动作。只依据当前快照与目标；不确定时选择 scroll；若已到页面底部则优先选最符合目标的可见控件动作。禁止推断白名单之外的语义。"
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
        // dry-run/shadow 的决策轨迹消费 observed 结果；applied 标记随决策带出，
        // 由执行门判定是否可落地（见 run 循环内双重校验）。
        let decision: IOSJevDecision
        let applicable: Bool
        switch outcome {
        case .applied(let value):
            decision = value
            applicable = true
        case .observed(let value):
            decision = value
            applicable = false
        case .skipped(let reason):
            return .indeterminate(reason: "调用被跳过：\(reason)")
        case .failed(let reason) where reason == "cancelled":
            return .cancelled
        case .failed(let reason):
            return .indeterminate(reason: "调用失败：\(reason)")
        }
        guard let answer = decision.answers.first(where: { $0.id == "next_action" }),
              answer.type == "choice",
              let chosenLabel = answer.choice,
              let chosen = bounded.first(where: { Self.optionLabel($0) == chosenLabel }) else {
            return .indeterminate(reason: "返回答案缺失或不在候选内")
        }
        // 低置信门：有置信值且低于阈值时交回主模型，不执行猜测动作。
        if let confidence = answer.confidence,
           confidence < Constants.lowConfidenceThreshold {
            return .indeterminate(reason: "低置信 \(confidence)")
        }
        return .chose(chosen, applicable: applicable)
    }

    static func optionLabel(_ action: PlannedAction) -> String {
        var label = action.kind.rawValue
        if let elementId = action.elementId { label += "@\(elementId)" }
        if action.kind == .typeDraft || action.kind == .submitReadonlySearch { label += "#v" }
        return label
    }

    /// choice criteria 的 option→description。Vercel 契约按 option→描述字符串
    /// 下发（null 描述会被 Gateway 拒收），描述同时让 Jev 知道目标语义。
    static func optionDescription(_ action: PlannedAction, in observation: PageObservation) -> String {
        let elementLabel = action.elementId.flatMap { id in
            observation.elements.first(where: { $0.id == id })?.label
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
        // 截断与 state 行同口径：64 个候选 × 无上限 label 会把请求顶爆。
        let target = String(((elementLabel?.isEmpty == false ? elementLabel : nil) ?? action.elementId ?? "").prefix(120))
        switch action.kind {
        case .scroll: return "向下滚动页面，加载更多内容"
        case .clickNav: return "点击导航链接：\(target)"
        case .select: return "选择控件选项：\(target)"
        case .typeDraft: return "在输入框填入草稿文本：\(target)"
        case .submitReadonlySearch: return "提交只读搜索：\(target)"
        }
    }
}
