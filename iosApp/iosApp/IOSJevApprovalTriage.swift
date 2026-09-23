import Foundation
import CoreFoundation

// MARK: - Jev 审批分诊标注（增强 Phase E）
//
// 契约（jev-enhancements-execution-plan Phase E，红线不可破）：
// - 只标注，永不自动批准/拒绝；不改变审批状态机、按钮与顺序。
// - 三道 Noul 是中性事实（只读/可逆/与任务相关），UI 措辞禁止
//   "安全/低风险"等诱导词——标注是分诊信息，不是授权建议。
// - 不阻塞审批链：卡片照常立即展示，标签异步补充；Jev 不可用时保留已知的
//   本地静态事实，其余事实为未知。
// - 参数只在工具元数据和当前任务文本范围同时允许时，按字段摘要外发；
//   凭据字段不外发。

/// 一次审批的三道中性事实判断。
struct IOSJevApprovalTriage: Equatable {
    enum TriState: String, Equatable {
        case yes, no, unknown
    }
    var requestId: String
    var readonly: TriState
    var reversible: TriState
    var goalAligned: TriState
}

@MainActor
final class IOSJevApprovalTriageService {

    struct StaticFacts {
        var readonly: IOSJevApprovalTriage.TriState?
        var reversible: IOSJevApprovalTriage.TriState?
        var mutates: Bool?
        var risk: String?

        static func workspace(isWrite: Bool) -> StaticFacts {
            StaticFacts(
                readonly: isWrite ? .no : .yes,
                reversible: isWrite ? .unknown : .yes,
                mutates: isWrite,
                risk: nil
            )
        }

        static func registeredTool(metadataJSON: String?) -> StaticFacts? {
            guard let metadataJSON,
                  let data = metadataJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mutates = object["mutates"] as? Bool else { return nil }
            let risk = object["risk"] as? String
            return StaticFacts(
                // mutates=false only proves no local state mutation; a read-like
                // tool may still transmit data externally (e.g. search_web).
                readonly: mutates ? .no : .unknown,
                reversible: .unknown,
                mutates: mutates,
                risk: risk
            )
        }
    }

    struct Dependencies {
        let coordinator: IOSJevDecisionCoordinator
        let settingsProvider: () -> IOSJevSettings
    }

    private let deps: Dependencies

    init(deps: Dependencies) {
        self.deps = deps
    }

    static let shared = IOSJevApprovalTriageService(deps: .init(
        coordinator: .shared,
        settingsProvider: { IOSSharedSettingsStore.loadPersistedJevSettings() }
    ))

    /// 三态分界：Noul ≥0.65 是 / ≤0.35 否 / 之间与缺题 = 未知。
    /// Noul 无 confidence 字段；0.65/0.35 是保守带，不是供应商默认值。
    static func band(_ probability: Double?) -> IOSJevApprovalTriage.TriState {
        guard let probability, probability.isFinite else { return .unknown }
        if probability >= 0.65 { return .yes }
        if probability <= 0.35 { return .no }
        return .unknown
    }

    /// Convert a JSON argument preview into a bounded field summary. Invalid
    /// or truncated JSON is omitted rather than sent as unstructured text.
    static func parameterSummary(fromJSON preview: String?) -> String? {
        guard let preview,
              let data = preview.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            return nil
        }

        let scalarFields = object.keys.sorted().compactMap { key -> (String, String)? in
            guard let value = object[key], let rendered = scalarSummary(value), !rendered.isEmpty else { return nil }
            return (key, rendered)
        }
        return parameterSummary(fields: Dictionary(scalarFields, uniquingKeysWith: { first, _ in first }))
    }

    static func parameterSummary(fields: [String: String]) -> String? {
        let summaries = fields.keys.sorted().compactMap { key -> String? in
            guard !isSensitiveField(key), let value = fields[key] else { return nil }
            let boundedValue = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !boundedValue.isEmpty else { return nil }
            return "\(String(key.prefix(48)))=\(boundedValue)"
        }
        guard !summaries.isEmpty else { return nil }
        return String(summaries.prefix(12).joined(separator: ", ").prefix(900))
    }

    private static func isSensitiveField(_ field: String) -> Bool {
        let normalized = field.lowercased().filter { $0.isLetter || $0.isNumber }
        return [
            "password", "passphrase", "passwd", "secret", "token", "credential", "authorization",
            "cookie", "apikey", "privatekey", "accesskey", "clientkey", "signingkey",
            "encryptionkey", "refreshtoken", "sessionid", "authentication", "signature",
            "nonce", "bearer",
        ].contains(where: normalized.contains) || normalized == "key"
    }

    private static func scalarSummary(_ value: Any) -> String? {
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return nil
    }

    /// 为一个待审批请求产出分诊标注。nil = 不标注（off/shadow/失败/跳过）。
    /// turnBudgetKey：调用方 runId，与其他用途共享 runId 单本轮次账。
    func triage(
        requestId: String,
        toolName: String,
        actionSummary: String,
        parameterSummary: String? = nil,
        staticFacts: StaticFacts? = nil,
        requiresParameterSummary: Bool = false,
        goalText: String?,
        turnBudgetKey: String
    ) async -> IOSJevApprovalTriage? {
        let settings = deps.settingsProvider()
        let mode = settings.effectiveMode(for: .approvalTriage)
        guard mode != .off else { return nil }
        let metadataAllowed = settings.canSend(useCase: .approvalTriage, required: [.toolMetadata])
        let taskTextAllowed = settings.canSend(useCase: .approvalTriage, required: [.selectedTaskText])
        let boundedParameterSummary = taskTextAllowed ? parameterSummary.map { String($0.prefix(900)) } : nil
        let action = taskTextAllowed
            ? String(actionSummary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            : ""
        let boundedGoal = taskTextAllowed ? goalText.map { String($0.prefix(400)) } : nil
        var lines: [String] = []
        if metadataAllowed { lines.append("待审批动作：\(toolName)") }
        if !action.isEmpty { lines.append("动作摘要：\(action)") }
        if let boundedParameterSummary { lines.append("参数摘要：\(boundedParameterSummary)") }
        if metadataAllowed, let staticFacts {
            var facts: [String] = []
            if let mutates = staticFacts.mutates { facts.append("mutates=\(mutates)") }
            if let risk = staticFacts.risk { facts.append("risk=\(risk)") }
            if !facts.isEmpty { lines.append("注册工具静态事实：\(facts.joined(separator: ", "))") }
        }
        if let boundedGoal { lines.append("用户最新请求：\(boundedGoal)") }
        let state = lines.joined(separator: "\n")

        func staticOnlyTriage() -> IOSJevApprovalTriage? {
            guard mode == .active else { return nil }
            let readonly = staticFacts?.readonly ?? .unknown
            let reversible = staticFacts?.reversible ?? .unknown
            guard readonly != .unknown || reversible != .unknown else { return nil }
            return IOSJevApprovalTriage(
                requestId: requestId,
                readonly: readonly,
                reversible: reversible,
                goalAligned: .unknown
            )
        }

        var questions: [IOSJevQuestion] = []
        let canQueryMetadata = metadataAllowed && taskTextAllowed
        let canJudgeMissingFacts = canQueryMetadata
            && (!requiresParameterSummary || boundedParameterSummary != nil)
        let readonlyIsUnknown = staticFacts?.readonly == nil || staticFacts?.readonly == .unknown
        let reversibleIsUnknown = staticFacts?.reversible == nil || staticFacts?.reversible == .unknown
        if readonlyIsUnknown, canJudgeMissingFacts {
            questions.append(IOSJevQuestion.noul(
                id: "readonly",
                instructions: "判断：依据待审批动作和参数摘要，该动作是否只读取/观察而不修改任何状态或对外发送内容（是=true）。信息不足时返回中间概率。"
            ))
        }
        if reversibleIsUnknown, canJudgeMissingFacts {
            questions.append(IOSJevQuestion.noul(
                id: "reversible",
                instructions: "判断：依据待审批动作和参数摘要，该动作的效果是否可以轻易撤销或恢复（是=true）。无法确认时返回中间概率。"
            ))
        }
        if let boundedGoal, !boundedGoal.isEmpty, canQueryMetadata,
           (!requiresParameterSummary || boundedParameterSummary != nil) {
            questions.append(IOSJevQuestion.noul(
                id: "goal_aligned",
                instructions: "判断：该动作是否直接服务于用户最新请求（是=true）。偏离、扩大范围、或信息不足为否/不确定。"
            ))
        }

        if questions.isEmpty {
            guard mode == .active else { return nil }
            let hasStaticFact = [staticFacts?.readonly, staticFacts?.reversible]
                .compactMap { $0 }
                .contains { $0 != .unknown }
            guard (metadataAllowed && taskTextAllowed) || hasStaticFact else { return nil }
            return IOSJevApprovalTriage(
                requestId: requestId,
                readonly: staticFacts?.readonly ?? .unknown,
                reversible: staticFacts?.reversible ?? .unknown,
                goalAligned: .unknown
            )
        }
        let context = IOSJevRunContext(
            runId: turnBudgetKey,
            turnBudgetKey: turnBudgetKey,
            inputHash: IOSJevToolDiscoveryService.stableHash(
                state + "|questions=" + questions.map(\.id).joined(separator: ",")
            )
        )
        let outcome = await deps.coordinator.decide(
            useCase: .approvalTriage,
            requiredScopes: [.toolMetadata, .selectedTaskText],
            state: state,
            questions: questions,
            context: context,
            // shadow/active 分键（全用途惯例）：shadow 观测不会被 active 命中应用。
            cacheKey: settings.effectiveMode(for: .approvalTriage) == .active
                ? "approval_triage" : "approval_triage_shadow"
        )
        guard case .applied(let decision) = outcome else { return staticOnlyTriage() }
        func answer(_ id: String) -> Double? {
            decision.answers.first { $0.id == id && $0.type == "noul" }?.noul
        }
        func resolved(_ fact: IOSJevApprovalTriage.TriState?, answer id: String) -> IOSJevApprovalTriage.TriState {
            guard let fact, fact != .unknown else { return Self.band(answer(id)) }
            return fact
        }
        return IOSJevApprovalTriage(
            requestId: requestId,
            readonly: resolved(staticFacts?.readonly, answer: "readonly"),
            reversible: resolved(staticFacts?.reversible, answer: "reversible"),
            goalAligned: Self.band(answer("goal_aligned"))
        )
    }
}
