import Foundation
@preconcurrency import Shared

/// 前台 Kernel 的可见投影边界。只负责消息、流式气泡和审批卡，不拥有
/// provider、工具执行、持久化或 run 生命周期。
@MainActor
final class ChatKernelProjection {
    private let bindings: ChatGenerationBindings
    private var provisionalAssistant: UIMessage?

    init(bindings: ChatGenerationBindings) {
        self.bindings = bindings
    }

    func publishAuthoritativeMessages(_ messages: [UIMessage]) {
        provisionalAssistant = nil
        bindings.setMessages(messages)
        bindings.bumpMessageRevision(.toolResultAppended, 1)
    }

    func publishClosedAssistantMessages(_ messages: [UIMessage]) {
        provisionalAssistant = nil
        bindings.setMessages(messages)
        bindings.bumpMessageRevision(.assistantStreamClosed, 1)
    }

    func publishProvisionalAssistant(_ message: UIMessage) {
        provisionalAssistant = message
        var messages = bindings.getMessages()
        if messages.last?.id == message.id {
            messages[messages.count - 1] = message
        } else if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        bindings.setMessages(messages)
        bindings.bumpMessageRevision(.streamDelta, 1)
    }

    /// 权威快照、换轮和终态都先丢弃 provisional，避免迟到节流快照覆盖终态。
    func discardProvisionalAssistant() {
        provisionalAssistant = nil
    }

    func publishApproval(_ prompt: ChatToolApprovalPrompt) {
        switch prompt {
        case .memory(let request): bindings.setPendingMemoryApproval(request)
        case .search(let request): bindings.setPendingSearchApproval(request)
        case .webMount(let request): bindings.setPendingWebMountApproval(request)
        case .workspace(let request): bindings.setPendingWorkspaceApproval(request)
        case .ish(let request): bindings.setPendingIshHandoffApproval(request)
        case .mcp(let request): bindings.setPendingMcpApproval(request)
        case .recipe(let request): bindings.setPendingRecipeApproval(request)
        case .council(let request): bindings.setPendingCouncilApproval(request)
        case .askUser(let request): bindings.setPendingAskUser(request)
        }
    }

    func clearApproval(_ prompt: ChatToolApprovalPrompt) {
        switch prompt {
        case .memory: bindings.setPendingMemoryApproval(nil)
        case .search: bindings.setPendingSearchApproval(nil)
        case .webMount: bindings.setPendingWebMountApproval(nil)
        case .workspace: bindings.setPendingWorkspaceApproval(nil)
        case .ish: bindings.setPendingIshHandoffApproval(nil)
        case .mcp: bindings.setPendingMcpApproval(nil)
        case .recipe: bindings.setPendingRecipeApproval(nil)
        case .council: bindings.setPendingCouncilApproval(nil)
        case .askUser: bindings.setPendingAskUser(nil)
        }
    }

    func clearAllApprovals() {
        bindings.setPendingMemoryApproval(nil)
        bindings.setPendingSearchApproval(nil)
        bindings.setPendingWebMountApproval(nil)
        bindings.setPendingWorkspaceApproval(nil)
        bindings.setPendingIshHandoffApproval(nil)
        bindings.setPendingMcpApproval(nil)
        bindings.setPendingRecipeApproval(nil)
        bindings.setPendingCouncilApproval(nil)
        bindings.setPendingAskUser(nil)
    }
}
