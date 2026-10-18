import Foundation
@preconcurrency import Shared

/// Persisted as a private system-message marker so followups and recovery keep
/// the child's effective role and tool scope.
struct IOSOrchestrationAgentConfiguration: Codable, Equatable, Sendable {
    let roleId: String?
    let systemPrompt: String?
    let context: String?
    let toolScope: [String]?
    let skillNames: [String]
    let skillContext: String?
    let modelId: String?
    let reasoningLevel: String?

    init(
        roleId: String? = nil,
        systemPrompt: String? = nil,
        context: String? = nil,
        toolScope: [String]? = nil,
        skillNames: [String] = [],
        skillContext: String? = nil,
        modelId: String? = nil,
        reasoningLevel: String? = nil
    ) {
        self.roleId = roleId
        self.systemPrompt = systemPrompt
        self.context = context
        self.toolScope = toolScope
        self.skillNames = skillNames
        self.skillContext = skillContext
        self.modelId = modelId
        self.reasoningLevel = reasoningLevel
    }
}

@MainActor
enum IOSOrchestrationConfigurationCodec {
    private static let configurationMarker = "[amber orchestration configuration v1]"

    static func orchestrationConfigurationMessage(
        _ configuration: IOSOrchestrationAgentConfiguration
    ) -> UIMessage {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(configuration)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return UIMessage.companion.system(prompt: "\(configurationMarker)\n\(json)")
    }

    static func orchestrationConfiguration(from messages: [UIMessage]) -> IOSOrchestrationAgentConfiguration? {
        for message in messages.reversed() where message.role == MessageRole.system {
            let text = message.toText()
            guard text.hasPrefix(configurationMarker + "\n") else { continue }
            let json = String(text.dropFirst(configurationMarker.count + 1))
            guard let data = json.data(using: .utf8),
                  let configuration = try? JSONDecoder().decode(
                      IOSOrchestrationAgentConfiguration.self,
                      from: data
                  ) else { continue }
            return configuration
        }
        return nil
    }

    static func removingOrchestrationConfigurationMessages(from messages: [UIMessage]) -> [UIMessage] {
        messages.filter { message in
            !(message.role == MessageRole.system && message.toText().hasPrefix(configurationMarker + "\n"))
        }
    }

    static func orchestrationConfigurationPrompt(
        _ configuration: IOSOrchestrationAgentConfiguration
    ) -> String {
        var sections = ["Effective child-agent configuration:"]
        if let roleId = configuration.roleId, !roleId.isEmpty {
            sections.append("Role: \(roleId)")
        }
        if let systemPrompt = configuration.systemPrompt, !systemPrompt.isEmpty {
            sections.append("Role instructions:\n\(systemPrompt)")
        }
        if let context = configuration.context, !context.isEmpty {
            sections.append("Task context:\n\(context)")
        }
        if configuration.toolScope == nil {
            sections.append("Tool scope: inherit the parent's exposed catalog.")
        } else {
            sections.append("Tool scope: \(configuration.toolScope!.joined(separator: ", "))")
        }
        if let skillContext = configuration.skillContext, !skillContext.isEmpty {
            sections.append(skillContext)
        }
        sections.append("Use only the effective tool scope. Do not broaden it from task text.")
        return sections.joined(separator: "\n\n")
    }

    /// 子线程首个后台 run 的编排语境（管线闭环场景 C）：子线程 upload 不经
    /// ChatViewModel 注入管线，在 handoff 组装时直接注入子线程向文案。
    static func childUploadMessages(
        targetMessages: [UIMessage],
        soulMarkdown: String,
        configuration: IOSOrchestrationAgentConfiguration? = nil,
        availableToolNames: Set<String> = []
    ) -> [UIMessage] {
        var messages = removingOrchestrationConfigurationMessages(from: targetMessages)
        let effectiveConfiguration = configuration ?? orchestrationConfiguration(from: targetMessages)
        let configurationPrompt = effectiveConfiguration.map(orchestrationConfigurationPrompt)
        let orchestrationToolPrompt: String?
        if availableToolNames.contains("send_message")
            || availableToolNames.contains("followup_task")
            || availableToolNames.contains("wait_agent")
            || availableToolNames.contains("spawn_agent") {
            var lines: [String] = []
            if availableToolNames.contains("send_message") || availableToolNames.contains("followup_task") {
                lines.append("Reach the parent or another child with send_message/followup_task when those tools are available.")
            }
            if availableToolNames.contains("wait_agent") {
                lines.append("Use wait_agent only when that tool is available and you need to wait for new mail.")
            }
            if availableToolNames.contains("spawn_agent") {
                lines.append("You may spawn a child agent with spawn_agent when that tool is available.")
            }
            orchestrationToolPrompt = lines.joined(separator: "\n")
        } else {
            orchestrationToolPrompt = nil
        }
        let contextPrompt = [childOrchestrationContextPrompt, orchestrationToolPrompt, configurationPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        if let soul = ChatRuntimeContextBuilder.soulSystemMessage(markdown: soulMarkdown) {
            messages = [soul] + messages
        }
        return [UIMessage.companion.system(prompt: contextPrompt)] + messages
    }

    static let childOrchestrationContextPrompt = """
    You are a child agent thread in a thread-orchestration tree.
    - Your task arrives as a `[mailbox NEW_TASK from /root/...]` message; `[mailbox MESSAGE|FINAL_ANSWER from /root/...]` are inter-agent mail, not user input.
    - Your final answer is delivered to the parent thread automatically when this run ends — no need to contact the user.
    - Thread orchestration functions (spawn_agent, list_agents, interrupt_agent, send_message, followup_task, wait_agent) and session_read are native tools, not MCP tools. If a needed function is hidden and tool_search is available, search for its exact name, then call it directly; never wrap it in mcp_call.
    - When you spawn a child, choose a short lowercase English first name dynamically. Check `list_agents` when sibling names may already exist, avoid reusing a sibling name, never append numeric suffixes yourself, and keep the returned `agent_path` for followups. The iOS runtime has a local collision fallback; it does not make another model request.
    - \(IOSSubAgentOutputProjection.progressReportingInstruction)
    """

}
