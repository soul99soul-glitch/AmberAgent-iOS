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

enum DesktopToolEffect: String, Sendable {
    case pure, networkRead, idempotent, sideEffect
    static let readOnly: DesktopToolEffect = .pure
}

struct DesktopToolDeclaration: Codable, Equatable, Sendable {
    let name: String
    let description: String
    let parametersJSON: String
    let needsApproval: Bool
}

enum DesktopToolRegistry {
    private static let pluginEffectsLock = NSLock()
    private nonisolated(unsafe) static var registeredPluginEffects: [String: DesktopToolEffect] = [:]

    static func updatePluginEffects(_ effects: [String: DesktopToolEffect]) {
        pluginEffectsLock.withLock { registeredPluginEffects = effects }
    }

    static let declarations: [DesktopToolDeclaration] = [
        declaration("tools_list", "列出本次任务可发现的工具名称；使用tool_search后再调用相应工具。", properties: [:]),
        declaration("workspace_file_list", "列出当前会话工作区中的真实文件。", properties: [:]),
        declaration("workspace_file_read", "读取当前会话工作区中的UTF8文本文件。", properties: ["path": "string"], required: ["path"]),
        declaration("workspace_file_write", "把UTF8成果写入当前会话工作区；需要用户批准，覆盖已有文件须overwrite=true。", properties: ["path": "string", "content": "string", "overwrite": "boolean"], required: ["path", "content"], approval: true),
        declaration("workspace_artifact_delete", "删除当前会话工作区的文件，需要用户批准。", properties: ["path": "string"], required: ["path"], approval: true),
        declaration("search_web", "搜索公开网页，返回标题、网址和摘要。max_results 可选（1–50），默认使用设置里的结果数量。",
            properties: ["query": "string", "max_results": "integer"], required: ["query"]),
        declaration("scrape_web", "读取一个公开HTTP/HTTPS网页的正文。", properties: ["url": "string"], required: ["url"]),
        declaration("terminal_exec", "在当前会话工作区执行一条macOS shell命令；每次需要批准，返回真实退出码和输出。", properties: ["command": "string"], required: ["command"], approval: true),
    ]

    /// High risk = can reach outside the conversation workspace or destroy data (iOS「含任意公网网站、远程命令等」).
    /// Only「高风险自动批准」auto-runs these; ordinary writes/memory/agents fall under「全局自动批准」.
    /// Creating or changing a scheduled task makes Amber act later, unattended: always ask, whatever the policy says.
    static func alwaysAsks(_ name: String) -> Bool { name == "schedule_create" || name == "schedule_update" }

    static func isHighRisk(_ name: String) -> Bool {
        // A plugin tool writes into another system (calendar, bot, document), so it carries the same gate as
        // shell, deletion and MCP: the ordinary switch must not run it and a phone may only deny it. A plugin
        // tool with no declared effect is treated as a write, never as a safe read.
        if name.hasPrefix("plugin__") {
            let declared = effect(for: name, arguments: "{}")
            return declared == .sideEffect || declared == .idempotent
        }
        return name == "terminal_exec" || name == "workspace_artifact_delete" || name == "mcp_call_tool" || name == "interrupt_agent"
    }

    static func effect(for name: String, arguments: String, pluginEffect: ((String) -> DesktopToolEffect)? = nil) -> DesktopToolEffect {
        if name.hasPrefix("plugin__") {
            if let pluginEffect { return pluginEffect(name) }
            if let registered = pluginEffectsLock.withLock({ registeredPluginEffects[name] }) {
                return registered
            }
            switch name {
            case "plugin__feishu_calendar__list_events",
                 "plugin__feishu_calendar__freebusy",
                 "plugin__feishu_calendar__bot_fetch_chat_history",
                 "plugin__feishu_calendar__bot_read_doc":
                return .networkRead
            case "plugin__apple_schedule__list_events",
                 "plugin__apple_schedule__list_reminders",
                 "plugin__watchtower__snapshot",
                 "plugin__watchtower__status":
                return .pure
            default:
                return .sideEffect
            }
        }
        switch name {
        case "tool_search", "tools_list", "workspace_file_list", "workspace_file_read", "skills_list", "use_skill",
             "mcp_list", "mcp_describe_tool", "list_agents", "schedule_list", "history_search", "history_fetch": return .pure
        case "search_web", "scrape_web": return .networkRead
        case "memory_tool": return memoryEffect(arguments)
        default: return .sideEffect
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
    static var collaborationDeclarations: [DesktopToolDeclaration] { collaborationDeclarations(subagents: true) }

    /// Returns the declarations for one chat run. Sub-agent-only mode gets the
    /// read-only dispatch controls, while council remains behind the ordinary
    /// tools switch (or both switches together).
    /// `scheduling`: the conversation may draft scheduled tasks. Off for scheduled runs themselves, so a task never
    /// creates or edits tasks.
    static func agentDeclarations(
        toolsEnabled: Bool,
        subagentsEnabled: Bool,
        scheduling: Bool = false,
        pluginDeclarations: [DesktopToolDeclaration] = [],
        disabledCorePlugins: Set<DesktopCorePlugin> = []
    ) -> [DesktopToolDeclaration] {
        let knowledgeAllowed = !disabledCorePlugins.contains(.knowledge)
        let collaborationsAllowed = !disabledCorePlugins.contains(.collaborations)
        let schedulesAllowed = scheduling && !disabledCorePlugins.contains(.taskBoard)
        if toolsEnabled {
            return declarations
                + (knowledgeAllowed ? knowledgeDeclarations : [])
                + (collaborationsAllowed ? collaborationDeclarations(subagents: subagentsEnabled) : [])
                + DesktopMCPManager.declarations
                + historyDeclarations
                + (schedulesAllowed ? scheduleDeclarations : [])
                + pluginDeclarations
        }
        guard subagentsEnabled, collaborationsAllowed else { return [] }
        let allowed = Set(["subagent_dispatch", "list_agents", "interrupt_agent"])
        return allCollaborationDeclarations.filter { allowed.contains($0.name) }
    }

    /// Read-only access to the stored transcript, including turns a summary folded away.
    static var historyDeclarations: [DesktopToolDeclaration] {
        [DesktopToolDeclaration(name: "history_search",
            description: "在完整会话记录中检索关键词（含已被上下文摘要覆盖的更早消息），返回消息 id、角色、片段与 stale 标记；只读。",
            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":12}},"required":["query"],"additionalProperties":false}"#,
            needsApproval: false),
         DesktopToolDeclaration(name: "history_fetch",
            description: "按消息 id 读取原始消息全文（最多 4000 字），标注该消息是否已被摘要覆盖；只读。",
            parametersJSON: #"{"type":"object","properties":{"message_id":{"type":"string"}},"required":["message_id"],"additionalProperties":false}"#,
            needsApproval: false)]
    }

    /// Council and run management stay available with tools; sub-agent dispatch only when its switch is on.
    static func collaborationDeclarations(subagents: Bool) -> [DesktopToolDeclaration] {
        allCollaborationDeclarations.filter { subagents || $0.name != "subagent_dispatch" }
    }

    private static var allCollaborationDeclarations: [DesktopToolDeclaration] {
        [DesktopToolDeclaration(name: "subagent_dispatch", description: "派发一个只读子代理（可用只读工具多轮执行）并等待结果；role为explorer/historian/oracle/designer/writer/fixer，model_id可选已配置模型UUID，skills可选已启用技能名。",
            parametersJSON: #"{"type":"object","properties":{"task":{"type":"string"},"role":{"type":"string"},"model_id":{"type":"string"},"skills":{"type":"array","items":{"type":"string"}}},"required":["task"],"additionalProperties":false}"#, needsApproval: true),
         declaration("list_agents", "列出当前会话的协作任务与状态。", properties: [:]),
         declaration("interrupt_agent", "取消当前会话的指定协作run，需要用户批准。", properties: ["run_id": "string"], required: ["run_id"], approval: true),
         DesktopToolDeclaration(name: "model_council_run", description: "让席位按轮次依次讨论目标（mode为free_chat自由讨论或debate辩论，rounds为1至5轮，默认2），主持人轮末点评并由综合模型汇总，需要用户批准；seats为空时由主持人规划2至5个席位；model_id为可选已配置模型UUID。",
            parametersJSON: #"{"type":"object","properties":{"objective":{"type":"string"},"seats":{"type":"array","maxItems":6,"items":{"type":"object","properties":{"name":{"type":"string"},"role_prompt":{"type":"string"},"model_id":{"type":"string"}},"required":["name","role_prompt"],"additionalProperties":false}},"synthesis_model_id":{"type":"string"},"mode":{"type":"string","enum":["free_chat","debate"]},"rounds":{"type":"integer","minimum":1,"maximum":5}},"required":["objective"],"additionalProperties":false}"#, needsApproval: true)]
    }

    /// Fields shared by create and update. Approval policy is deliberately not offered: tasks made in chat start
    /// with nothing auto-approved, and only the Mac UI changes that.
    private static let scheduleFields = #""name":{"type":"string"},"prompt":{"type":"string","description":"到点后发给模型的完整提示词"},"rule":{"type":"string","enum":["once","daily","weekdays","weekly","interval"]},"hour":{"type":"integer","minimum":0,"maximum":23},"minute":{"type":"integer","minimum":0,"maximum":59},"weekdays":{"type":"array","items":{"type":"integer","minimum":1,"maximum":7},"description":"每周规则的星期，1=周日…7=周六"},"interval_minutes":{"type":"integer","minimum":15,"maximum":10080},"at":{"type":"string","description":"仅一次规则的本地时间 yyyy-MM-dd HH:mm"},"use_tools":{"type":"boolean"}"#

    static var scheduleDeclarations: [DesktopToolDeclaration] {
        [declaration("schedule_list", "列出 Amber 的定时任务（名称、规则、是否启用、下次运行、上次结果）。", properties: [:]),
         DesktopToolDeclaration(name: "schedule_create",
            description: "起草一个定时任务，到点时 Amber 在新会话里运行 prompt。永远需要用户批准；新任务不会自动批准任何工具。",
            parametersJSON: #"{"type":"object","properties":{"# + scheduleFields + #"},"required":["name","prompt","rule"],"additionalProperties":false}"#, needsApproval: true),
         DesktopToolDeclaration(name: "schedule_update",
            description: "修改已有定时任务的名称、提示词、时间规则或启用状态（id 来自 schedule_list）。永远需要用户批准；不能修改审批设置。",
            parametersJSON: #"{"type":"object","properties":{"id":{"type":"string"},"enabled":{"type":"boolean"},"# + scheduleFields + #"},"required":["id"],"additionalProperties":false}"#, needsApproval: true)]
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
