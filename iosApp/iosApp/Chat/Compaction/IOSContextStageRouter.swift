import Foundation
@preconcurrency import Shared

/// 阶段路由结果。默认继续当前会话；只有阶段完成且有验收证据才建议切会话。
enum IOSContextStageRoute: Equatable, Sendable {
    case continueCurrent
    case suggestNewConversation(completedStage: String, evidence: [String])
}

/// 阶段路由的输入。pending 字段是硬闸门：工具往返、待审批、未保存变更期间
/// 一律不得建议或自动切会话。
struct IOSContextStageInput: Equatable, Sendable {
    var pendingToolRoundTrip: Bool = false
    var pendingApproval: Bool = false
    var hasUnsavedChanges: Bool = false
    var completedStage: String?
    var acceptanceEvidence: [String] = []

    static func from(
        messages: [UIMessage],
        completedStage: String? = nil,
        acceptanceEvidence: [String] = [],
        hasUnsavedChanges: Bool = false
    ) -> IOSContextStageInput {
        let hasPendingTool = messages.contains { IOSContextCompactionCoordinator.messageHasPendingTool($0) }
        let hasPendingApproval = messages.contains { message in
            message.parts.contains { ($0 as? UIMessagePart.Tool)?.approvalState is ToolApprovalState.Pending }
        }
        return IOSContextStageInput(
            pendingToolRoundTrip: hasPendingTool,
            pendingApproval: hasPendingApproval,
            hasUnsavedChanges: hasUnsavedChanges,
            completedStage: completedStage,
            acceptanceEvidence: acceptanceEvidence
        )
    }
}

enum IOSContextStageRouter {
    /// iOS 没有自动切换会话的路径；这里只产出“建议”，由调用方决定是否展示。
    static func decide(_ input: IOSContextStageInput) -> IOSContextStageRoute {
        guard !input.pendingToolRoundTrip,
              !input.pendingApproval,
              !input.hasUnsavedChanges else {
            return .continueCurrent
        }
        let stage = input.completedStage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let evidence = input.acceptanceEvidence
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !stage.isEmpty, !evidence.isEmpty else { return .continueCurrent }
        return .suggestNewConversation(completedStage: stage, evidence: evidence)
    }
}
