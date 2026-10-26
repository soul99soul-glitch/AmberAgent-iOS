import Foundation

struct DesktopSkillToolScope: Sendable {
    private(set) var allowed: Set<String>?
    mutating func apply(_ names: [String]) {
        guard !names.isEmpty else { return }
        let incoming = Set(names)
        allowed = allowed.map { $0.intersection(incoming) } ?? incoming
    }
    func permits(_ name: String) -> Bool {
        if ["tool_search", "tools_list", "use_skill"].contains(name) { return true }
        return allowed?.contains(name) ?? true
    }
}

enum DesktopToolEffect: String, Sendable { case pure, networkRead, idempotent, sideEffect }

struct DesktopToolDeclaration: Codable, Equatable, Sendable {
    let name: String
    let description: String
    let parametersJSON: String
    let needsApproval: Bool
}

enum DesktopToolRegistry {
    static let declarations: [DesktopToolDeclaration] = [
        declaration("tools_list", "列出本次任务可发现的工具名称；使用tool_search后再调用相应工具。", properties: [:]),
        declaration("workspace_file_list", "列出当前会话工作区中的真实文件。", properties: [:]),
        declaration("workspace_file_read", "读取当前会话工作区中的UTF8文本文件。", properties: ["path": "string"], required: ["path"]),
        declaration("workspace_file_write", "把UTF8成果写入当前会话工作区；需要用户批准，覆盖已有文件须overwrite=true。", properties: ["path": "string", "content": "string", "overwrite": "boolean"], required: ["path", "content"], approval: true),
        declaration("workspace_artifact_delete", "删除当前会话工作区的文件，需要用户批准。", properties: ["path": "string"], required: ["path"], approval: true),
        declaration("search_web", "搜索公开网页，返回标题、网址和摘要。", properties: ["query": "string"], required: ["query"]),
        declaration("scrape_web", "读取一个公开HTTP/HTTPS网页的正文。", properties: ["url": "string"], required: ["url"]),
        declaration("terminal_exec", "在当前会话工作区执行一条macOS shell命令；每次需要批准，返回真实退出码和输出。", properties: ["command": "string"], required: ["command"], approval: true),
    ]

    static func effect(for name: String, arguments: String) -> DesktopToolEffect {
        switch name {
        case "tool_search", "tools_list", "workspace_file_list", "workspace_file_read", "skills_list", "use_skill", "mcp_list", "mcp_describe_tool", "list_agents": .pure
        case "search_web", "scrape_web": .networkRead
        case "memory_tool": memoryEffect(arguments)
        default: .sideEffect
        }
    }

    private static func memoryEffect(_ arguments: String) -> DesktopToolEffect {
        guard let data = arguments.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String else { return .sideEffect }
        switch action.lowercased() {
        case "list", "read", "search", "query", "status": return .pure
        case "edit", "update", "delete", "remove": return .idempotent
        default: return .sideEffect
        }
    }

    static func declaration(_ name: String, _ description: String, properties: [String: String], required: [String] = [], approval: Bool = false) -> DesktopToolDeclaration {
        let schema: [String: Any] = ["type": "object", "properties": properties.mapValues { ["type": $0] },
            "required": required, "additionalProperties": false]
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return DesktopToolDeclaration(name: name, description: description, parametersJSON: String(decoding: data, as: UTF8.self), needsApproval: approval)
    }
}

extension DesktopToolRegistry {
    static var collaborationDeclarations: [DesktopToolDeclaration] {
        [declaration("subagent_dispatch", "派发一个独立文本子任务并等待结果；role为explorer/historian/oracle/designer/writer/fixer，model_id可选已配置模型UUID。", properties: ["task": "string", "role": "string", "model_id": "string"], required: ["task"], approval: true),
         declaration("list_agents", "列出当前会话的协作任务与状态。", properties: [:]),
         declaration("interrupt_agent", "取消当前会话的指定协作run，需要用户批准。", properties: ["run_id": "string"], required: ["run_id"], approval: true),
         DesktopToolDeclaration(name: "model_council_run", description: "让2至6个席位分别讨论目标并由综合模型汇总结论，需要用户批准；model_id为可选已配置模型UUID。",
            parametersJSON: #"{"type":"object","properties":{"objective":{"type":"string"},"seats":{"type":"array","minItems":2,"maxItems":6,"items":{"type":"object","properties":{"name":{"type":"string"},"role_prompt":{"type":"string"},"model_id":{"type":"string"}},"required":["name","role_prompt"],"additionalProperties":false}},"synthesis_model_id":{"type":"string"}},"required":["objective","seats"],"additionalProperties":false}"#, needsApproval: true)]
    }

    static var knowledgeDeclarations: [DesktopToolDeclaration] {
        [DesktopToolRegistry.declaration("skills_list", "列出本地技能和启用状态。", properties: [:]),
         DesktopToolRegistry.declaration("use_skill", "读取已启用技能的SKILL.md指令；其中的工具建议不授予权限。", properties: ["name": "string"], required: ["name"]),
         DesktopToolRegistry.declaration("skill_enable", "启用已导入技能，需要用户批准。", properties: ["name": "string"], required: ["name"], approval: true),
         DesktopToolRegistry.declaration("skill_disable", "停用技能，需要用户批准。", properties: ["name": "string"], required: ["name"], approval: true),
         DesktopToolDeclaration(name: "memory_tool", description: "读取或维护长期记忆；写入需要用户批准，保存来源会话/消息。",
            parametersJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["list","read","search","query","create","edit","delete"]},"id":{"type":"integer"},"query":{"type":"string"},"content":{"type":"string"},"scope":{"type":"string"},"kind":{"type":"string"},"sourceConversationId":{"type":"string"},"sourceMessageIds":{"type":"array","items":{"type":"string"}}},"required":["action"],"additionalProperties":false}"#, needsApproval: true)]
    }

}
