import Foundation
import Shared

enum ChatTaskFailureKind: String, Equatable, Sendable {
    case outcomeUnknown
    case providerOrNetwork
    case permissionDenied
    case approvalRequired
    case validationOrMissingTarget
    case executionError

    var badgeText: String {
        switch self {
        case .outcomeUnknown:
            return IOSAppLocalization.string("结果待核查", defaultValue: "结果待核查")
        case .providerOrNetwork:
            return IOSAppLocalization.string("网络或模型异常", defaultValue: "网络或模型异常")
        case .permissionDenied:
            return IOSAppLocalization.string("权限受限", defaultValue: "权限受限")
        case .approvalRequired:
            return IOSAppLocalization.string("等待审批", defaultValue: "等待审批")
        case .validationOrMissingTarget:
            return IOSAppLocalization.string("参数或目标无效", defaultValue: "参数或目标无效")
        case .executionError:
            return IOSAppLocalization.string("执行出错", defaultValue: "执行出错")
        }
    }

    var defaultReason: String {
        switch self {
        case .outcomeUnknown:
            return IOSAppLocalization.string("应用中断导致操作结果未明，请先核查后再决定是否继续", defaultValue: "应用中断导致操作结果未明，请先核查后再决定是否继续")
        case .providerOrNetwork:
            return IOSAppLocalization.string("网络或上游服务暂时异常，可稍后查看详情或重试", defaultValue: "网络或上游服务暂时异常，可稍后查看详情或重试")
        case .permissionDenied:
            return IOSAppLocalization.string("缺少必要权限或操作被拒绝，请检查对应授权", defaultValue: "缺少必要权限或操作被拒绝，请检查对应授权")
        case .approvalRequired:
            return IOSAppLocalization.string("该步骤需要你明确确认审批后才会继续", defaultValue: "该步骤需要你明确确认审批后才会继续")
        case .validationOrMissingTarget:
            return IOSAppLocalization.string("目标不存在或传入参数未通过校验", defaultValue: "目标不存在或传入参数未通过校验")
        case .executionError:
            return IOSAppLocalization.string("工具执行返回错误，请查看详情定位原因", defaultValue: "工具执行返回错误，请查看详情定位原因")
        }
    }

    var actionLabel: String {
        switch self {
        case .outcomeUnknown:
            return IOSAppLocalization.string("核查结果", defaultValue: "核查结果")
        case .providerOrNetwork:
            return IOSAppLocalization.string("查看异常", defaultValue: "查看异常")
        case .permissionDenied:
            return IOSAppLocalization.string("查看权限", defaultValue: "查看权限")
        case .approvalRequired:
            return IOSAppLocalization.string("查看审批", defaultValue: "查看审批")
        case .validationOrMissingTarget:
            return IOSAppLocalization.string("检查目标", defaultValue: "检查目标")
        case .executionError:
            return IOSAppLocalization.string("查看详情", defaultValue: "查看详情")
        }
    }
}

struct ChatTaskFailureClassification: Equatable, Sendable {
    let kind: ChatTaskFailureKind
    let badgeText: String
    let localizedReason: String
    let actionLabel: String
}

enum ChatTaskFailureClassifier {
    private static let snakeCaseRegex = try? NSRegularExpression(pattern: #"^[a-z0-9]+(_[a-z0-9]+)+$"#)

    static func classify(
        tool: UIMessagePart.Tool?,
        step: ChatToolStepModel?,
        fallbackReason: String? = nil
    ) -> ChatTaskFailureClassification {
        let rawTexts = (tool?.output ?? []).compactMap { ($0 as? UIMessagePart.Text)?.text }
        let joinedText = rawTexts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonObject = firstJSONObject(in: rawTexts)

        // 1. Structured fields FIRST.
        let kind: ChatTaskFailureKind
        if let structured = classifyFromStructuredFields(tool: tool, json: jsonObject) {
            kind = structured
        } else {
            // 2. Text fallback SECOND.
            let candidateText = [
                extractStructuredText(from: jsonObject),
                step?.detail,
                fallbackReason,
                joinedText,
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
            kind = classifyFromTextFallback(candidateText)
        }

        let extractedReason = sanitizedHumanReason(
            structuredText: extractStructuredText(from: jsonObject),
            stepDetail: step?.detail,
            fallbackReason: fallbackReason,
            rawText: joinedText,
            kind: kind
        )

        return ChatTaskFailureClassification(
            kind: kind,
            badgeText: kind.badgeText,
            localizedReason: extractedReason,
            actionLabel: kind.actionLabel
        )
    }

    private static func classifyFromStructuredFields(
        tool: UIMessagePart.Tool?,
        json: [String: Any]?
    ) -> ChatTaskFailureKind? {
        if let tool, ChatTaskStreamGrouping.hasUnknownOutcome(tool) {
            return .outcomeUnknown
        }
        if let approvalState = tool?.approvalState {
            if approvalState is ToolApprovalState.Pending {
                return .approvalRequired
            }
            if approvalState is ToolApprovalState.Denied {
                return .permissionDenied
            }
        }
        guard let json else { return nil }

        if let outcome = (json["outcome"] as? String)?.lowercased() {
            if outcome == "unknown" || outcome == "outcome_unknown" || outcome == "interrupted" {
                return .outcomeUnknown
            }
            if outcome == "denied" {
                return .permissionDenied
            }
        }
        if (json["denied"] as? Bool) == true {
            return .permissionDenied
        }

        let codeFields = ["reason_code", "error_code", "code", "status"]
        for field in codeFields {
            if let rawCode = (json[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !rawCode.isEmpty {
                if let mapped = mapStructuredCode(rawCode) {
                    return mapped
                }
            }
        }

        for statusField in ["http_status", "httpStatus", "status_code"] {
            if let statusCode = json[statusField] as? Int {
                switch statusCode {
                case 401, 403:
                    return .permissionDenied
                case 400, 404, 422:
                    return .validationOrMissingTarget
                case 408, 429, 500...599:
                    return .providerOrNetwork
                default:
                    break
                }
            }
        }
        return nil
    }

    private static func mapStructuredCode(_ code: String) -> ChatTaskFailureKind? {
        switch code {
        case "process_interrupted", "outcome_unknown", "user_requested_recheck":
            return .outcomeUnknown
        case "permission_denied", "unauthorized", "forbidden", "missing_permission", "entitlement_missing", "unavailable_entitlement":
            return .permissionDenied
        case "approval_required", "replan_required", "awaiting_approval":
            return .approvalRequired
        case "invalid_arguments", "missing_target", "not_found", "validation_failed", "path_not_found", "enoent":
            return .validationOrMissingTarget
        case "network_error", "timeout", "timed_out", "rate_limited", "upstream_error", "provider_error", "service_unavailable":
            return .providerOrNetwork
        default:
            return nil
        }
    }

    private static func classifyFromTextFallback(_ text: String) -> ChatTaskFailureKind {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return .executionError }

        if lower.contains("结果未知") || lower.contains("user_requested_recheck") || lower.contains("outcome unknown") {
            return .outcomeUnknown
        }
        if lower.contains("permission") || lower.contains("unauthorized") || lower.contains("forbidden")
            || lower.contains("denied") || lower.contains("权限") || lower.contains("授权") || lower.contains("entitlement") {
            return .permissionDenied
        }
        if lower.contains("approval") || lower.contains("审批") || lower.contains("等待确认") {
            return .approvalRequired
        }
        if lower.contains("timeout") || lower.contains("timed out") || lower.contains("network")
            || lower.contains("connection") || lower.contains("429") || lower.contains("502")
            || lower.contains("503") || lower.contains("504") || lower.contains("rate limit")
            || lower.contains("超时") || lower.contains("网络") {
            return .providerOrNetwork
        }
        if lower.contains("not found") || lower.contains("no such file") || lower.contains("invalid argument")
            || lower.contains("missing target") || lower.contains("不存在") || lower.contains("参数") || lower.contains("路径无效") {
            return .validationOrMissingTarget
        }
        return .executionError
    }

    private static func firstJSONObject(in rawTexts: [String]) -> [String: Any]? {
        for raw in rawTexts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return object
        }
        return nil
    }

    private static func extractStructuredText(from json: [String: Any]?) -> String? {
        guard let json else { return nil }
        for key in ["reason", "error", "message", "detail", "stderr"] {
            if let value = json[key] as? String {
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    return clean
                }
            }
        }
        return nil
    }

    static func sanitizeHumanText(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("{") else {
            return nil
        }
        if let regex = snakeCaseRegex {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if regex.firstMatch(in: trimmed, range: range) != nil {
                return mapStructuredCode(trimmed.lowercased())?.defaultReason
            }
        }
        return String(trimmed.prefix(88))
    }

    private static func sanitizedHumanReason(
        structuredText: String?,
        stepDetail: String?,
        fallbackReason: String?,
        rawText: String,
        kind: ChatTaskFailureKind
    ) -> String {
        for candidate in [structuredText, stepDetail, fallbackReason] {
            if let clean = sanitizeHumanText(candidate) {
                return clean
            }
        }
        let firstLine = rawText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        if let clean = sanitizeHumanText(firstLine) {
            return clean
        }
        return kind.defaultReason
    }
}
