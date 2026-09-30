import Foundation
@preconcurrency import Shared

// MARK: - Jev 子任务意图路由 + 对齐回执（增强 Phase C）
//
// 契约（jev-enhancements-execution-plan Phase C）：
// - 只在 spawn 缺省角色定义时生效：显式 role_id/system_prompt/tool_scope 或
//   继承配置一律优先，Jev 建议永远不覆盖明确选择。
// - 候选 = 内置角色目录（IOSSubAgentRoleCatalog.builtIns）+ none 弃权项；
//   返回目录外 id 按弃权处理。
// - 对齐回执是一道 Noul（子任务与用户最新请求是否直接相关），仅用于标注：
//   判定偏离时不阻断 spawn，由调用方在工具结果里如实带出。Noul 无
//   confidence 字段，不伪造。
// - 不确定 / 失败 / 范围未允许 / 低置信 → 空建议，走现有 spawn 优先级。

@MainActor
final class IOSJevSubAgentIntentService {

    struct Dependencies {
        let coordinator: IOSJevDecisionCoordinator
        let settingsProvider: () -> IOSJevSettings
    }

    /// 一次 spawn 边界的意图判断结果。roleId 为空 = 无建议（弃权/失败/回退）。
    struct Suggestion: Equatable {
        var roleId: String?
        /// 对齐回执判定子任务偏离用户最新请求（仅标注，不阻断）。
        var alignmentDoubtful: Bool
    }

    /// 对齐 Noul 的判定分界：概率 < 0.5 视为偏离。0.5 是是非概率的自然分界，
    /// 不是供应商默认阈值；Noul 无 confidence，不做置信门。
    static let alignmentProbabilityFloor = 0.5

    static let batchPartId = "subagent_intent"

    /// 构造可并入 spawn 时机的角色 Choice 与对齐 Noul part。
    /// 模式和数据范围仍由 decideBatch 按用途独立判定。
    static func makeBatchPart(
        taskText: String,
        parentRequestText: String?,
        settings: IOSJevSettings,
        partId: String = batchPartId
    ) -> IOSJevBatchPart? {
        let roles = IOSSubAgentRoleCatalog.builtIns
        guard !roles.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("子任务：\(String(taskText.prefix(600)))")
        if let parentRequestText, !parentRequestText.isEmpty {
            lines.append("用户最新请求：\(String(parentRequestText.prefix(400)))")
        } else {
            lines.append("用户最新请求：（不可得）")
        }
        lines.append("可选角色：")
        for role in roles {
            lines.append("- \(role.id)（\(role.name)）：\(role.routing)")
        }
        let state = lines.joined(separator: "\n")

        var options: [String: String?] = ["none": "以上角色都不适合该子任务（弃权）"]
        for role in roles { options[role.id] = role.routing }
        let questions = [
            IOSJevQuestion.choice(
                id: "role_choice",
                options: options,
                instructions: "为该子任务选择最合适的内置角色。拿不准或都不合适时选择 none，不要勉强匹配。"
            ),
            IOSJevQuestion.noul(
                id: "aligned",
                instructions: "判断：该子任务直接服务于用户最新请求（是=true）。子任务明显偏离、扩大范围或与用户请求无关时为否。"
            ),
        ]
        let alignmentFloor = alignmentProbabilityFloor
        return IOSJevBatchPart(
            id: partId,
            useCase: .subagentIntent,
            requiredScopes: [.selectedTaskText, .toolMetadata],
            state: state,
            questions: questions,
            cacheKey: settings.effectiveMode(for: .subagentIntent) == .active
                ? "subagent_intent" : "subagent_intent_shadow",
            metricNumbersProvider: { decision in
                guard let probability = decision.answers.first(where: { $0.id == "aligned" })?.noul else { return nil }
                return ["alignment_doubtful": probability < alignmentFloor ? 1 : 0]
            },
            metricIdsProvider: { decision in
                guard let choice = decision.answers.first(where: { $0.id == "role_choice" })?.choice else { return nil }
                return ["suggested_role_id": choice]
            }
        )
    }

    /// 只消费 active 结果；shadow、失败或不确定均走现有 spawn 优先级。
    static func suggestion(from outcome: IOSJevDecisionOutcome, settings: IOSJevSettings) -> Suggestion {
        guard case .applied(let decision) = outcome else {
            return Suggestion(roleId: nil, alignmentDoubtful: false)
        }

        var suggestedRoleId: String?
        if let roleAnswer = decision.answers.first(where: { $0.id == "role_choice" }),
           roleAnswer.type == "choice",
           let choice = roleAnswer.choice, choice != "none" {
            let confidenceOk: Bool
            if let floor = settings.policy.subagentIntentMinConfidence,
               let confidence = roleAnswer.confidence {
                confidenceOk = confidence >= floor
            } else {
                confidenceOk = true
            }
            if confidenceOk, IOSSubAgentRoleCatalog.resolve(roleId: choice) != nil {
                suggestedRoleId = choice
            }
        }
        var alignmentDoubtful = false
        if let alignmentAnswer = decision.answers.first(where: { $0.id == "aligned" }),
           alignmentAnswer.type == "noul",
           let probability = alignmentAnswer.noul, probability.isFinite {
            alignmentDoubtful = probability < Self.alignmentProbabilityFloor
        }
        return Suggestion(roleId: suggestedRoleId, alignmentDoubtful: alignmentDoubtful)
    }

    private let deps: Dependencies

    init(deps: Dependencies) {
        self.deps = deps
    }

    static let shared = IOSJevSubAgentIntentService(deps: .init(
        coordinator: .shared,
        settingsProvider: { IOSSharedSettingsStore.loadPersistedJevSettings() }
    ))

    /// 为一次 spawn 给出角色建议与对齐标注。空建议 = 调用方走现有优先级。
    /// turnBudgetKey：调用方 runId——与其他用途共享 runId 单本轮次账。
    /// shadow：协调器返回 observed，本服务不应用结果（空建议），指标照常记录。
    func suggest(
        taskText: String,
        parentRequestText: String?,
        turnBudgetKey: String
    ) async -> Suggestion {
        let settings = deps.settingsProvider()
        guard let part = Self.makeBatchPart(
            taskText: taskText,
            parentRequestText: parentRequestText,
            settings: settings
        ) else { return Suggestion(roleId: nil, alignmentDoubtful: false) }
        let context = IOSJevRunContext(
            runId: turnBudgetKey,
            turnBudgetKey: turnBudgetKey,
            inputHash: IOSJevToolDiscoveryService.stableHash(part.state)
        )
        let outcome = await deps.coordinator.decide(
            useCase: part.useCase,
            requiredScopes: part.requiredScopes,
            state: part.state,
            questions: part.questions,
            context: context,
            // shadow/active 分键（全用途惯例）：协调器缓存命中不重核 revision，
            // 分键保证 shadow 期观测永远不会在切 active 后被命中应用。
            cacheKey: part.cacheKey
        )
        return Self.suggestion(from: outcome, settings: settings)
    }
}

// MARK: - Jev 完成校验（v2 Phase 3）
//
// 事实先行：本轮（最后一条用户消息之后）成功写入过非文档类工作区文件，且最后
// 一次写入之后没有成功运行过测试/构建/检查类终端命令，才问 Jev 最终回复是否
// 宣称完成或已验证。命中时由界面提示用户，用户点"让助手验证"走正常发送；不自动
// 续跑。已知宽松：关键词按词匹配（如 `ls tests` 也算检查，偏向不提示）；exec
// 脚本内嵌套调用与后台运行不在事实范围内。

@MainActor
final class IOSJevCompletionCheckService {
    struct Dependencies {
        let coordinator: IOSJevDecisionCoordinator
        let settingsProvider: () -> IOSJevSettings
    }

    struct Facts: Equatable {
        var changedFiles: [String]
        var finalReply: String
    }

    nonisolated static let claimThreshold = 0.8
    nonisolated static let verificationPrompt = "请运行与刚才修改相关的测试、构建或检查来验证；如果当前环境无法运行，请说明哪些内容尚未验证。"
    nonisolated private static let writeToolNames: Set<String> = [
        "workspace_file_write", "workspace_file_edit", "workspace_file_move",
    ]
    /// 同步返回结果的终端命令（后台作业的"已启动"不代表检查通过）。
    nonisolated private static let commandToolNames: Set<String> = [
        "terminal_execute", IOSAmberShellToolCatalog.executeToolName,
    ]
    /// 只改这些文档类文件时不提示（没有可运行的检查）。
    nonisolated private static let documentExtensions: Set<String> = [
        "md", "markdown", "txt", "csv", "rtf", "docx", "pdf", "html",
    ]
    nonisolated private static let checkPattern = try! NSRegularExpression(
        pattern: #"\b(test|tests|pytest|jest|vitest|build|lint|check|typecheck|tsc|ctest)\b"#,
        options: [.caseInsensitive]
    )

    private let deps: Dependencies

    init(deps: Dependencies) {
        self.deps = deps
    }

    static let shared = IOSJevCompletionCheckService(deps: .init(
        coordinator: .shared,
        settingsProvider: { IOSSharedSettingsStore.loadPersistedJevSettings() }
    ))

    /// 本轮改过文件且之后没有运行检查时返回事实；否则 nil（不外发）。
    nonisolated static func unverifiedChanges(in messages: [UIMessage]) -> Facts? {
        let start = (messages.lastIndex { $0.role == MessageRole.user }).map { $0 + 1 } ?? 0
        guard start < messages.count else { return nil }
        var changedFiles: [String] = []
        var checkedAfterLastWrite = false
        for message in messages[start...] {
            for part in message.parts {
                guard let tool = part as? UIMessagePart.Tool,
                      writeToolNames.contains(tool.toolName) || commandToolNames.contains(tool.toolName),
                      !tool.output.isEmpty else { continue }
                let analysis = ChatToolOutputAnalysis(output: tool.output)
                guard analysis.failureReason == nil else { continue }
                if writeToolNames.contains(tool.toolName) {
                    // 内容未变的编辑不算写入。
                    guard analysis.firstJSONObject?["changed"] as? Bool != false,
                          let path = analysis.firstJSONObject?["path"] as? String else { continue }
                    if !changedFiles.contains(path) { changedFiles.append(path) }
                    checkedAfterLastWrite = false
                } else if let input = (try? JSONSerialization.jsonObject(with: Data(tool.input.utf8))) as? [String: Any],
                          let command = input["command"] as? String,
                          checkPattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil {
                    checkedAfterLastWrite = true
                }
            }
        }
        guard !checkedAfterLastWrite,
              changedFiles.contains(where: { !documentExtensions.contains(($0 as NSString).pathExtension.lowercased()) })
        else { return nil }
        let finalReply = messages[start...].last { $0.role == MessageRole.assistant }?
            .parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !finalReply.isEmpty else { return nil }
        return Facts(changedFiles: changedFiles, finalReply: finalReply)
    }

    /// true = 需要提示用户验证。shadow 只在后台观测并返回 false。
    func needsVerification(messages: [UIMessage], runKey: String) async -> Bool {
        let settings = deps.settingsProvider()
        let mode = settings.effectiveMode(for: .completionCheck)
        let requiredScopes = IOSJevUseCase.completionCheck.defaultDataScopes
        guard mode != .off,
              settings.canSend(useCase: .completionCheck, required: requiredScopes),
              let facts = Self.unverifiedChanges(in: messages) else { return false }
        let state = [
            "本轮事实（本地判定）：修改了 \(facts.changedFiles.prefix(10).joined(separator: "、"))；修改之后没有运行任何测试、构建或检查命令。",
            "助手的最终回复：",
            String(facts.finalReply.prefix(2_000)),
        ].joined(separator: "\n")
        let questions = [
            IOSJevQuestion.noul(id: "claims_done", instructions: "判断：助手的最终回复是否宣称任务已经完成。"),
            IOSJevQuestion.noul(id: "claims_verified", instructions: "判断：助手的最终回复是否宣称已经验证、测试通过或确认可以正常运行。"),
        ]
        let context = IOSJevRunContext(
            runId: runKey,
            turnBudgetKey: runKey,
            inputHash: IOSJevToolDiscoveryService.stableHash(state)
        )
        let coordinator = deps.coordinator
        let decide: @MainActor () async -> IOSJevDecisionOutcome = {
            await coordinator.decide(
                useCase: .completionCheck,
                requiredScopes: requiredScopes,
                state: state,
                questions: questions,
                context: context,
                expectedSettingsRevision: settings.revision,
                metricNumbersProvider: { ["difference": Self.claimsUnverifiedCompletion($0) ? 1 : 0] }
            )
        }
        if mode == .shadow {
            Task { @MainActor in _ = await decide() }
            return false
        }
        guard case .applied(let decision) = await decide() else { return false }
        return Self.claimsUnverifiedCompletion(decision)
    }

    nonisolated static func claimsUnverifiedCompletion(_ decision: IOSJevDecision) -> Bool {
        ["claims_done", "claims_verified"].contains { id in
            (decision.answers.first { $0.id == id }?.noul ?? 0) >= claimThreshold
        }
    }
}
