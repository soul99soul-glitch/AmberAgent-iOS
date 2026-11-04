import Foundation

struct DesktopSkillToolScope: Sendable {
    private(set) var allowed: Set<String>?
    mutating func apply(_ names: [String]) {
        guard !names.isEmpty else { return }
        let incoming = Set(names)
        allowed = allowed.map { $0.intersection(incoming) } ?? incoming
    }
    func permits(_ name: String) -> Bool {
        if ["tool_search", "tools_list", "use_skill", "agent_soul_get", "agent_soul_update"].contains(name) { return true }
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
        searchWebDeclaration,
        scrapeWebDeclaration,
        exaContentsDeclaration,
        exaAnswerDeclaration,
        exaFindSimilarDeclaration,
        declaration("terminal_exec", "在当前会话工作区执行一条macOS shell命令；每次需要批准，返回真实退出码和输出。", properties: ["command": "string"], required: ["command"], approval: true),
        declaration("plugin_list", "列出已安装的插件、版本和启用状态；只读，免审批。", properties: [:]),
        declaration("plugin_install", "从当前会话工作区内的插件目录或 plugin.json 路径安装插件；高风险操作，需在 Mac 上批准，同名插件已存在时须设置 overwrite=true。",
            properties: ["path": "string", "overwrite": "boolean"], required: ["path"], approval: true),
        agentSoulGetDeclaration,
        agentSoulUpdateDeclaration,
    ]

    static let agentSoulGetDeclaration = DesktopToolDeclaration(
        name: "agent_soul_get",
        description: "读取当前全端共享的形象人设（名字/自称、一句话签名、角色性格与口吻 Markdown、版本号及最近 8 条历史快照）；只读，免审批。",
        parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
        needsApproval: false
    )

    static let agentSoulUpdateDeclaration = DesktopToolDeclaration(
        name: "agent_soul_update",
        description: "持久更新全端共享的形象人设（称呼 display_name、一句话签名 tagline、角色性格与口吻 soul_markdown，或传 reset_to_default=true 恢复默认 Amber）。底层诚实守则自动保留，自带 8 条历史快照可一键回退，免审批即时生效并与云端双向同步。",
        parametersJSON: #"{"type":"object","properties":{"display_name":{"type":"string","description":"新的名字或自称（最多 64 字）"},"displayName":{"type":"string","description":"display_name 的兼容别名"},"tagline":{"type":"string","description":"一句话签名（最多 200 字）"},"soul_markdown":{"type":"string","description":"角色性格、说话口吻与相处方式 Markdown"},"soulMarkdown":{"type":"string","description":"soul_markdown 的兼容别名"},"soulPrompt":{"type":"string","description":"soul_markdown 的兼容别名"},"reset_to_default":{"type":"boolean","description":"设为 true 时恢复默认 Amber 形象人设"},"resetToDefault":{"type":"boolean","description":"reset_to_default 的兼容别名"}},"additionalProperties":false}"#,
        needsApproval: false
    )

    static let searchWebDeclaration = DesktopToolDeclaration(
        name: "search_web",
        description: "搜索公开网页（支持多源顺序兜底/并发及 Exa 原生神经检索），返回标题、网址、摘要/高光/正文与图片。支持 Exa 原生参数：type（auto/lite/deep-lite/deep）、category（company/publication/news/personal site/financial report/people）、include_domains/exclude_domains、start_published_date/end_published_date、highlights/include_full_text/include_summary、max_age_hours、subpages、include_images/image_links，以及 execution_mode（sequential/parallel）和 sources。",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"搜索查询词"},"max_results":{"type":"integer","minimum":1,"maximum":50,"description":"返回结果数量（1–50），默认使用搜索设置"},"type":{"type":"string","enum":["auto","lite","deep-lite","deep","fast","instant","deep-reasoning"],"description":"Exa 检索模式：auto（默认）、lite（极速缓存）、deep-lite（轻量深度研究）、deep（多步深度研究）"},"category":{"type":"string","enum":["company","publication","news","personal site","financial report","people","research paper"],"description":"Exa 内容类别过滤"},"include_domains":{"type":"array","items":{"type":"string"},"description":"仅在这些域名内搜索"},"exclude_domains":{"type":"array","items":{"type":"string"},"description":"排除这些域名"},"start_published_date":{"type":"string","description":"起始发布时间（ISO 8601，如 2026-01-01T00:00:00.000Z）"},"end_published_date":{"type":"string","description":"截止发布时间（ISO 8601）"},"include_text":{"type":"array","items":{"type":"string"},"description":"网页正文必须包含的短语"},"exclude_text":{"type":"array","items":{"type":"string"},"description":"网页正文不能包含的短语"},"additional_queries":{"type":"array","items":{"type":"string"},"description":"Exa deep/deep-lite 模式的补充并行查询词"},"highlights":{"type":"boolean","description":"是否返回关键句高光摘录"},"highlights_query":{"type":"string","description":"高光摘录的定向问题或关键词"},"include_full_text":{"type":"boolean","description":"是否返回网页正文全文"},"text_max_characters":{"type":"integer","description":"单篇网页正文最大字符数"},"include_summary":{"type":"boolean","description":"是否返回 AI 生成的网页摘要"},"summary_query":{"type":"string","description":"网页摘要的定向关注点"},"max_age_hours":{"type":"integer","description":"内容新鲜度上限（小时）：0 为总是实时抓取，-1 为仅用缓存"},"subpages":{"type":"integer","minimum":0,"maximum":10,"description":"深入抓取的子页面数量"},"subpage_target":{"type":"array","items":{"type":"string"},"description":"子页面优先匹配的关键词"},"include_images":{"type":"boolean","description":"是否提取并返回网页图片链接与描述"},"image_links":{"type":"integer","minimum":0,"maximum":10,"description":"每条结果提取的附加图片链接数量"},"user_location":{"type":"string","description":"两位国家代码（如 US、CN）"},"moderation":{"type":"boolean","description":"是否开启内容安全过滤"},"execution_mode":{"type":"string","enum":["sequential","parallel"],"description":"多搜索源执行策略：sequential（顺序兜底）或 parallel（多源并发）"},"sources":{"type":"array","items":{"type":"string"},"description":"指定本次使用的已启用搜索源（如 [\"exa\",\"tavily\",\"free\"]）"},"exa_endpoint":{"type":"string","enum":["search","contents","answer","find_similar"],"description":"可选：直接指定 Exa 端点"}},"required":["query"],"additionalProperties":false}"#,
        needsApproval: false
    )

    static let scrapeWebDeclaration = DesktopToolDeclaration(
        name: "scrape_web",
        description: "读取一个公开HTTP/HTTPS网页的正文与头图。",
        parametersJSON: #"{"type":"object","properties":{"url":{"type":"string","description":"公开网页地址"},"max_chars":{"type":"integer","minimum":1000,"maximum":40000,"description":"返回正文最大字符数"}},"required":["url"],"additionalProperties":false}"#,
        needsApproval: false
    )

    static let exaContentsDeclaration = DesktopToolDeclaration(
        name: "exa_contents",
        description: "使用 Exa /contents 批量提取一个或多个公开 URL 的清洁全文、关键高光、AI 摘要、子页面与图片链接；只读，免审批。",
        parametersJSON: #"{"type":"object","properties":{"urls":{"type":"array","items":{"type":"string"},"description":"要提取内容的公开网页 URL 列表"},"url":{"type":"string","description":"单个公开网页 URL（与 urls 二选一）"},"highlights":{"type":"boolean","description":"是否返回高光摘录"},"highlights_query":{"type":"string","description":"高光摘录的定向查询词"},"include_full_text":{"type":"boolean","description":"是否返回网页全文（默认 true）"},"text_max_characters":{"type":"integer","description":"单篇全文最大字符数"},"include_summary":{"type":"boolean","description":"是否返回 AI 网页摘要"},"summary_query":{"type":"string","description":"摘要关注的问题"},"max_age_hours":{"type":"integer","description":"内容新鲜度上限（小时）：0 为实时抓取，-1 为仅用缓存"},"subpages":{"type":"integer","minimum":0,"maximum":10,"description":"抓取子页面数量"},"subpage_target":{"type":"array","items":{"type":"string"},"description":"子页面目标关键词"},"include_images":{"type":"boolean","description":"是否提取页面图片链接"},"image_links":{"type":"integer","minimum":0,"maximum":10,"description":"每个页面提取的图片数量"}},"required":["urls"],"additionalProperties":false}"#,
        needsApproval: false
    )

    static let exaAnswerDeclaration = DesktopToolDeclaration(
        name: "exa_answer",
        description: "使用 Exa /answer 进行带网页引用的检索问答，返回综合回答、引用来源及关联图片；只读，免审批。",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"需要检索并回答的问题"},"model":{"type":"string","enum":["exa","exa-pro"],"description":"Exa Answer 模型"},"include_full_text":{"type":"boolean","description":"是否在引用中附带原文内容"},"system_prompt":{"type":"string","description":"回答风格或格式要求"},"user_location":{"type":"string","description":"两位国家代码（如 US、CN）"}},"required":["query"],"additionalProperties":false}"#,
        needsApproval: false
    )

    static let exaFindSimilarDeclaration = DesktopToolDeclaration(
        name: "exa_find_similar",
        description: "使用 Exa /findSimilar 查找与指定 URL 语义相似的公开网页，支持域名/时间/分类过滤与正文提取；只读，免审批。",
        parametersJSON: #"{"type":"object","properties":{"url":{"type":"string","description":"参考网页 URL"},"max_results":{"type":"integer","minimum":1,"maximum":50,"description":"返回结果数量（1–50）"},"category":{"type":"string","enum":["company","publication","news","personal site","financial report","people","research paper"],"description":"类别过滤"},"include_domains":{"type":"array","items":{"type":"string"},"description":"仅在这些域名内查找"},"exclude_domains":{"type":"array","items":{"type":"string"},"description":"排除这些域名"},"start_published_date":{"type":"string","description":"起始发布时间（ISO 8601）"},"end_published_date":{"type":"string","description":"截止发布时间（ISO 8601）"},"exclude_source_domain":{"type":"boolean","description":"是否排除参考 URL 自身所在域名"},"highlights":{"type":"boolean","description":"是否返回高光摘录"},"include_full_text":{"type":"boolean","description":"是否返回网页全文"},"include_summary":{"type":"boolean","description":"是否返回 AI 摘要"},"include_images":{"type":"boolean","description":"是否提取图片链接"}},"required":["url"],"additionalProperties":false}"#,
        needsApproval: false
    )

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
        return name == "terminal_exec" || name == "workspace_artifact_delete" || name == "mcp_call_tool"
            || name == "interrupt_agent" || name == "plugin_install"
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
             "mcp_list", "mcp_describe_tool", "list_agents", "schedule_list", "history_search", "history_fetch",
             "plugin_list", "agent_soul_get": return .pure
        case "agent_soul_update": return .idempotent
        case "search_web", "scrape_web", "exa_search", "exa_contents", "exa_answer", "exa_find_similar": return .networkRead
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
