import Foundation

/// What a tool call is doing, in words: "正在读取记忆", "已搜索网页 · swift concurrency". The raw tool name stays
/// available in the card's details; unknown tools fall back to it.
struct DesktopToolActivity: Equatable {
    let title: String
    let detail: String?

    private static let detailLimit = 48

    var summary: String { detail.map { "\(title) · \($0)" } ?? title }

    init(_ tool: DesktopToolCall) {
        let arguments = Self.arguments(tool.input)
        func string(_ keys: String...) -> String? {
            keys.lazy.compactMap { (arguments[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        let action: (running: String, done: String)
        var detail: String?
        switch tool.name {
        case "memory_tool":
            action = Self.memoryAction(string("action"))
            detail = string("query")
        case "search_web":
            action = ("正在搜索网页", "已搜索网页"); detail = string("query")
        case "scrape_web":
            action = ("正在读取网页", "已读取网页"); detail = string("url").map(Self.host)
        case "workspace_file_list":
            action = ("正在查看工作区文件", "已查看工作区文件")
        case "workspace_file_read":
            action = ("正在读取文件", "已读取文件"); detail = string("path").map(Self.fileName)
        case "workspace_file_write":
            action = ("正在写入文件", "已写入文件"); detail = string("path").map(Self.fileName)
        case "workspace_artifact_delete":
            action = ("正在删除文件", "已删除文件"); detail = string("path").map(Self.fileName)
        case "terminal_exec":
            action = ("正在运行命令", "已运行命令"); detail = string("command")
        case "tool_search", "tools_list":
            action = ("正在查找可用工具", "已查找可用工具"); detail = string("query")
        case "skills_list":
            action = ("正在查看技能", "已查看技能")
        case "use_skill":
            action = ("正在读取技能", "已读取技能"); detail = string("name")
        case "skill_enable":
            action = ("正在启用技能", "已启用技能"); detail = string("name")
        case "skill_disable":
            action = ("正在停用技能", "已停用技能"); detail = string("name")
        case "mcp_list":
            action = ("正在查看 MCP 服务", "已查看 MCP 服务")
        case "mcp_describe_tool":
            action = ("正在读取 MCP 工具说明", "已读取 MCP 工具说明"); detail = string("name")
        case "mcp_call_tool":
            action = ("正在调用 MCP 工具", "已调用 MCP 工具"); detail = string("name")
        case "subagent_dispatch":
            action = ("正在派出子代理", "已派出子代理"); detail = string("role", "task")
        case "list_agents":
            action = ("正在查看协作任务", "已查看协作任务")
        case "interrupt_agent":
            action = ("正在取消协作任务", "已取消协作任务")
        case "model_council_run":
            action = ("正在召开议会", "已召开议会"); detail = string("objective")
        case "schedule_list":
            action = ("正在查看定时任务", "已查看定时任务")
        case "schedule_create":
            action = ("正在创建定时任务", "已创建定时任务"); detail = string("name")
        case "schedule_update":
            action = ("正在修改定时任务", "已修改定时任务"); detail = string("name")
        case "plugin__feishu_calendar__list_events":
            action = ("正在查询飞书日历", "已查询飞书日历"); detail = string("date", "query")
        case "plugin__feishu_calendar__freebusy":
            action = ("正在查询飞书忙闲时段", "已查询飞书忙闲时段"); detail = string("date")
        case "plugin__feishu_calendar__create_event":
            action = ("正在创建飞书日程", "已创建飞书日程"); detail = string("summary", "start_time")
        case "plugin__feishu_calendar__bot_send_message":
            action = ("正在通过飞书机器人发送通知", "已通过飞书机器人发送通知"); detail = string("title", "content")
        case "plugin__feishu_calendar__bot_fetch_chat_history":
            action = ("正在拉取飞书群聊记录", "已拉取飞书群聊记录"); detail = string("chat_id")
        case "plugin__feishu_calendar__bot_read_doc":
            action = ("正在读取飞书云文档", "已读取飞书云文档"); detail = string("document")
        case "plugin__feishu_calendar__bot_create_doc":
            action = ("正在创建飞书云文档", "已创建飞书云文档"); detail = string("title")
        default:
            if let parsed = DesktopPluginStore.parseQualifiedToolName(tool.name) {
                action = ("正在调用插件 \(parsed.pluginID) · \(parsed.toolName)", "已调用插件 \(parsed.pluginID) · \(parsed.toolName)")
                detail = string("summary", "query", "date", "name", "title")
            } else {
                action = ("正在使用 \(tool.name)", "已使用 \(tool.name)")
            }
        }
        switch tool.status {
        case .running: title = action.running
        case .complete: title = action.done
        case .pending: title = "等待确认：" + Self.stripRunning(action.running)
        case .denied: title = "已拒绝：" + Self.stripRunning(action.running)
        }
        self.detail = detail.flatMap(Self.clipped)
    }

    private static func memoryAction(_ action: String?) -> (running: String, done: String) {
        switch action?.lowercased() {
        case "list", "read": ("正在读取记忆", "已读取记忆")
        case "search", "query": ("正在搜索记忆", "已搜索记忆")
        case "create": ("正在写入记忆", "已写入记忆")
        case "edit": ("正在更新记忆", "已更新记忆")
        case "delete": ("正在删除记忆", "已删除记忆")
        default: ("正在使用记忆", "已使用记忆")
        }
    }

    private static func stripRunning(_ value: String) -> String {
        value.hasPrefix("正在") ? String(value.dropFirst(2)) : value
    }

    private static func arguments(_ input: String) -> [String: Any] {
        guard input.utf8.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any] else { return [:] }
        return object
    }

    private static func host(_ value: String) -> String {
        guard let host = URL(string: value)?.host() else { return value }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func fileName(_ value: String) -> String { (value as NSString).lastPathComponent }

    private static func clipped(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > detailLimit ? String(collapsed.prefix(detailLimit - 1)) + "…" : collapsed
    }
}
