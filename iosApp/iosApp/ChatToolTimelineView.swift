import SwiftUI
import UIKit
import Shared

/// 工具胶囊视觉族：驱动 Koboyo 实心图标；并行保留 SF `systemImage` 给顶栏活动岛。
enum ChatToolVisualKind: String, Equatable, CaseIterable {
    case search
    case web
    case webMount
    case webMountObserve
    case webMountCapture
    case workspaceRead
    case workspaceWrite
    case workspaceDelete
    case image
    case terminal
    case mcp
    case subagent
    case council
    case memory
    case apple
    case code
    case generic

    static func resolve(toolName: String) -> ChatToolVisualKind {
        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.contains("subagent_dispatch") { return .subagent }
        if IOSRemoteTerminalToolCatalog.supportedToolNames.contains(name) { return .terminal }
        if IOSAppleAgentToolCatalog.toolNames.contains(name) { return .apple }
        switch name {
        case "search_web": return .search
        case "scrape_web": return .web
        case "memory_tool": return .memory
        case "mcp_call": return .mcp
        case "model_council_run": return .council
        case "generate_image": return .image
        case "terminal_execute", "ios_shell_execute", "ish_handoff", "ios_ish_execute": return .terminal
        case "workspace_file_write": return .workspaceWrite
        case "workspace_artifact_delete": return .workspaceDelete
        case "workspace_file_read", "workspace_artifact_read": return .workspaceRead
        default:
            break
        }
        if name.hasPrefix("wm_") {
            switch name {
            case "wm_screenshot", "wm_visual_snapshot":
                return .webMountCapture
            case "wm_observe", "wm_extract", "wm_get":
                return .webMountObserve
            default:
                return .webMount
            }
        }
        if IOSWorkspaceToolCatalog.supportedToolNames.contains(name) {
            return .workspaceRead
        }
        let lower = name.lowercased()
        if lower.contains("search") { return .search }
        if lower.contains("code") || lower.contains("swift") { return .code }
        if lower.contains("read") || lower.contains("file") { return .workspaceRead }
        return .generic
    }

    /// 胶囊 leading：Koboyo 实心剪影。
    var koboyoMark: ChatKoboyoMark {
        switch self {
        case .search: .solidSearch
        case .web: .solidGlobe
        case .webMount: .solidMonitor
        case .webMountObserve: .solidEye
        case .webMountCapture: .solidCamera
        case .workspaceRead: .solidDocument
        case .workspaceWrite: .solidPen
        case .workspaceDelete: .solidWrench
        case .image: .solidImage
        case .terminal: .solidTerminal
        case .mcp: .solidPuzzle
        case .subagent: .solidUsers
        case .council: .solidPeopleGroup
        case .memory: .solidBrain
        case .apple: .solidDocument
        case .code: .solidCode
        case .generic: .solidWrench
        }
    }

    /// 顶栏活动岛 / Live Activity 继续用 SF。
    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .web: "globe"
        case .webMount, .webMountObserve, .webMountCapture: "globe.badge.chevron.backward"
        case .workspaceRead: "doc.text"
        case .workspaceWrite, .workspaceDelete: "folder"
        case .image: "photo.on.rectangle"
        case .terminal: "terminal"
        case .mcp: "puzzlepiece.extension"
        case .subagent: "person.2.fill"
        case .council: "person.3.sequence"
        case .memory: "brain.head.profile"
        case .apple: "iphone"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .generic: "wrench.and.screwdriver"
        }
    }

    var isImageTool: Bool { self == .image }

    var activeIslandTint: ChatActivityIslandTint {
        switch self {
        case .search, .web, .webMount, .webMountObserve, .webMountCapture:
            .cyan
        case .image:
            .green
        case .subagent, .council:
            .indigo
        case .memory, .apple:
            .amber
        default:
            .accent
        }
    }
}


enum ChatToolStepState: Equatable {
    case done
    case active
    case cancelled
    case failed

    var iconName: String {
        switch self {
        case .done:
            "checkmark"
        case .active:
            "circle.fill"
        case .cancelled:
            "minus"
        case .failed:
            "exclamationmark"
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .done, .cancelled, .failed:
            11
        case .active:
            7
        }
    }

    var color: Color {
        switch self {
        case .done:
            AmberTheme.accentGreen
        case .active:
            AmberTheme.accent
        case .cancelled:
            AmberTheme.muted
        case .failed:
            AmberTheme.accentRed
        }
    }

    var rowFill: Color {
        switch self {
        case .done:
            AmberTheme.accent.opacity(0.08)
        case .active:
            AmberTheme.accent.opacity(0.10)
        case .cancelled:
            AmberTheme.muted.opacity(0.08)
        case .failed:
            AmberTheme.accentRed.opacity(0.10)
        }
    }

    var iconFill: Color {
        switch self {
        case .done:
            AmberTheme.accentGreen.opacity(0.10)
        case .active:
            AmberTheme.accentTint
        case .cancelled:
            AmberTheme.muted.opacity(0.10)
        case .failed:
            AmberTheme.accentRed.opacity(0.10)
        }
    }

    var stroke: Color {
        switch self {
        case .done:
            AmberTheme.accent.opacity(0.16)
        case .active:
            AmberTheme.accent.opacity(0.20)
        case .cancelled:
            AmberTheme.muted.opacity(0.18)
        case .failed:
            AmberTheme.accentRed.opacity(0.22)
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .done: IOSAppLocalization.string("已完成", defaultValue: "已完成")
        case .active: IOSAppLocalization.string("进行中", defaultValue: "进行中")
        case .cancelled: IOSAppLocalization.string("已取消", defaultValue: "已取消")
        case .failed: IOSAppLocalization.string("执行失败", defaultValue: "执行失败")
        }
    }
}

struct ChatToolStepModel: Identifiable {
    let id: String
    /// 顶栏活动岛 / Live Activity 用的 SF Symbol（胶囊 leading 用 `koboyoMark`）。
    let systemImage: String
    let visualKind: ChatToolVisualKind
    let title: String
    let detail: String?
    let state: ChatToolStepState
    let isSubAgent: Bool
    /// Carried for subagent steps so the detail sheet can read the live prompt + streaming output.
    let tool: UIMessagePart.Tool?

    var koboyoMark: ChatKoboyoMark { visualKind.koboyoMark }

    init(
        id: String = UUID().uuidString,
        visualKind: ChatToolVisualKind,
        title: String,
        detail: String? = nil,
        state: ChatToolStepState,
        isSubAgent: Bool = false,
        tool: UIMessagePart.Tool? = nil
    ) {
        self.id = id
        self.visualKind = visualKind
        self.systemImage = visualKind.systemImage
        self.title = title
        self.detail = detail
        self.state = state
        self.isSubAgent = isSubAgent
        self.tool = tool
    }

    init(tool: UIMessagePart.Tool) {
        let stableID = Self.stableID(for: tool)
        let kind = ChatToolVisualKind.resolve(toolName: tool.toolName)
        // `.contains` (不是 `==`):流式合并偶发把工具名拼成 "subagent_dispatchsubagent_dispatch",
        // 用包含匹配才不会漏判、掉进裸名回退。
        if tool.toolName.contains("subagent_dispatch") {
            let executed = !tool.output.isEmpty
            let failureReason = ChatToolOutputFormatter.failureReason(from: tool.output)
            self.init(
                id: stableID,
                visualKind: .subagent,
                title: Self.subAgentTitle(from: tool.input),
                detail: failureReason ?? Self.subAgentDetail(from: tool.input),
                state: Self.state(executed: executed, failureReason: failureReason),
                isSubAgent: true,
                tool: tool
            )
            return
        }

        if tool.toolName == "search_web" {
            let query = Self.searchQuery(from: tool.input)
            let executed = !tool.output.isEmpty
            let failureReason = ChatToolOutputFormatter.failureReason(from: tool.output)
            self.init(
                id: stableID,
                visualKind: .search,
                // 状态动词在生命周期内恒定（"搜索 <query>"，进行中/完成由尾部转圈/对勾表达，
                // 与 friendlyToolTitle 同款约定）：若随 executed 换词（正在搜索→已搜索），
                // 胶囊理想宽在 toolCallStarted/toolResultAppended 间跳变——执行期间撑宽、
                // 完成缩回（本轮真机 bug）。
                title: Self.combinedLine(Self.localized("搜索"), query),
                detail: executed ? (failureReason ?? Self.searchResultSummary(from: tool.output)) : query.map {
                    IOSAppLocalization.formatted(
                        "关键词：%@",
                        defaultValue: "关键词：%@",
                        arguments: [$0]
                    )
                },
                state: Self.state(executed: executed, failureReason: failureReason)
            )
            return
        }

        if tool.toolName == "scrape_web" {
            let url = Self.scrapeURL(from: tool.input)
            let executed = !tool.output.isEmpty
            let failureReason = ChatToolOutputFormatter.failureReason(from: tool.output)
            self.init(
                id: stableID,
                visualKind: .web,
                title: Self.combinedLine(
                    executed ? Self.localized("已读取网页") : Self.localized("正在读取网页"),
                    url
                ),
                detail: executed ? (failureReason ?? Self.searchResultSummary(from: tool.output)) : url.map {
                    IOSAppLocalization.formatted(
                        "链接：%@",
                        defaultValue: "链接：%@",
                        arguments: [$0]
                    )
                },
                state: Self.state(executed: executed, failureReason: failureReason)
            )
            return
        }

        if tool.toolName == "memory_tool" {
            let executed = !tool.output.isEmpty
            let failureReason = ChatToolOutputFormatter.failureReason(from: tool.output)
            self.init(
                id: stableID,
                visualKind: .memory,
                title: executed ? Self.localized("已更新核心记忆") : Self.localized("正在更新核心记忆"),
                detail: failureReason,
                state: Self.state(executed: executed, failureReason: failureReason)
            )
            return
        }

        if tool.toolName == "mcp_call" {
            let executed = !tool.output.isEmpty
            let failureReason = ChatToolOutputFormatter.failureReason(from: tool.output)
            self.init(
                id: stableID,
                visualKind: .mcp,
                title: Self.combinedLine(
                    executed ? Self.localized("已调用 MCP") : Self.localized("正在调用 MCP"),
                    Self.mcpName(from: tool.input)
                ),
                detail: failureReason,
                state: Self.state(executed: executed, failureReason: failureReason)
            )
            return
        }

        if tool.toolName == "model_council_run" {
            let executed = !tool.output.isEmpty
            let failureReason = ChatToolOutputFormatter.failureReason(from: tool.output)
            self.init(
                id: stableID,
                visualKind: .council,
                title: executed
                    ? (failureReason == nil ? Self.localized("模型议会已完成") : Self.localized("模型议会失败"))
                    : Self.localized("模型议会进行中"),
                detail: failureReason,
                state: Self.state(executed: executed, failureReason: failureReason)
            )
            return
        }

        if tool.toolName == "generate_image" {
            let prompt = Self.imagePrompt(from: tool.input)
            let imageCount = tool.output.compactMap { $0 as? UIMessagePart.Image }.count
            let executed = !tool.output.isEmpty
            if executed && imageCount == 0 {
                self.init(
                    id: stableID,
                    visualKind: .image,
                    title: Self.combinedLine(Self.localized("图片生成失败"), prompt),
                    detail: ChatToolOutputFormatter.imageFailureReason(from: tool.output)
                        ?? Self.localized("没有返回图片"),
                    state: .failed
                )
                return
            }
            self.init(
                id: stableID,
                visualKind: .image,
                title: Self.combinedLine(
                    executed ? Self.localized("图片已生成") : Self.localized("正在生成图片"),
                    prompt
                ),
                detail: executed
                    ? IOSAppLocalization.formatted(
                        "%ld 张图片",
                        defaultValue: "%ld 张图片",
                        arguments: [imageCount]
                    )
                    : prompt.map {
                        IOSAppLocalization.formatted(
                            "提示词：%@",
                            defaultValue: "提示词：%@",
                            arguments: [$0]
                        )
                    },
                state: executed ? .done : .active
            )
            return
        }

        if tool.toolName == "ish_handoff" {
            let executed = !tool.output.isEmpty
            let failed = executed && Self.ishToolResultIndicatesFailure(tool.output)
            self.init(
                id: stableID,
                visualKind: .terminal,
                title: failed
                    ? Self.localized("iSH 交接失败")
                    : (executed ? Self.localized("iSH 交接已准备") : Self.localized("准备 iSH 交接")),
                detail: executed ? Self.ishHandoffResultSummary(from: tool.output) : Self.ishHandoffInputSummary(from: tool.input),
                state: failed ? .failed : (executed ? .done : .active)
            )
            return
        }

        if tool.toolName == "ios_ish_execute" {
            let executed = !tool.output.isEmpty
            let object = Self.firstJSONObject(in: tool.output)
            let status = object?["status"] as? String
            let failed = executed && Self.ishToolResultIndicatesFailure(tool.output)
            let launchedJob = object?["background"] as? Bool == true
                && status == IOSTerminalJobStatus.running.rawValue
            let title = status == IOSTerminalJobStatus.cancelled.rawValue
                ? Self.localized("内置 iSH 已取消")
                : (failed
                    ? Self.localized("内置 iSH 执行失败")
                    : (launchedJob
                        ? Self.localized("内置 iSH 作业已启动")
                        : (executed ? Self.localized("内置 iSH 已执行") : Self.localized("准备执行内置 iSH"))))
            self.init(
                id: stableID,
                visualKind: .terminal,
                title: title,
                detail: executed ? Self.ishExecuteResultSummary(from: tool.output) : Self.ishHandoffInputSummary(from: tool.input),
                state: Self.terminalState(status: status, executed: executed, failed: failed)
            )
            return
        }

        if tool.toolName == "terminal_execute" {
            let executed = !tool.output.isEmpty
            let failed = executed && Self.ishToolResultIndicatesFailure(tool.output)
            let status = Self.firstJSONObject(in: tool.output)?["status"] as? String
            let title: String
            switch status?.lowercased() {
            case IOSTerminalJobStatus.timedOut.rawValue:
                title = Self.localized("Remote SSH 已超时")
            case IOSTerminalJobStatus.cancelled.rawValue:
                title = Self.localized("Remote SSH 已取消")
            default:
                title = failed
                    ? Self.localized("Remote SSH 执行失败")
                    : (executed ? Self.localized("Remote SSH 已执行") : Self.localized("准备执行 Remote SSH"))
            }
            self.init(
                id: stableID,
                visualKind: .terminal,
                title: title,
                detail: executed ? Self.ishExecuteResultSummary(from: tool.output) : Self.ishHandoffInputSummary(from: tool.input),
                state: Self.terminalState(status: status, executed: executed, failed: failed)
            )
            return
        }

        if tool.toolName == IOSAmberShellToolCatalog.executeToolName {
            let executed = !tool.output.isEmpty
            let failed = executed && Self.ishToolResultIndicatesFailure(tool.output)
            let status = Self.firstJSONObject(in: tool.output)?["status"] as? String
            let title: String
            switch status?.lowercased() {
            case IOSTerminalJobStatus.timedOut.rawValue:
                title = Self.localized("AmberShell 已超时")
            case IOSTerminalJobStatus.cancelled.rawValue:
                title = Self.localized("AmberShell 已取消")
            default:
                title = failed
                    ? Self.localized("AmberShell 执行失败")
                    : (executed ? Self.localized("AmberShell 已执行") : Self.localized("准备执行 AmberShell"))
            }
            self.init(
                id: stableID,
                visualKind: .terminal,
                title: title,
                detail: executed ? Self.ishExecuteResultSummary(from: tool.output) : Self.ishHandoffInputSummary(from: tool.input),
                state: Self.terminalState(status: status, executed: executed, failed: failed)
            )
            return
        }

        if IOSRemoteTerminalToolCatalog.jobToolNames.contains(tool.toolName) {
            let executed = !tool.output.isEmpty
            let object = Self.firstJSONObject(in: tool.output)
            let status = object?["status"] as? String
            let runtime = object?["runtime"] as? String
            let runtimeTitle: String
            if runtime == IOSTerminalRuntimeKind.ishExperimental.rawValue {
                runtimeTitle = Self.localized("内置 iSH")
            } else if runtime == IOSTerminalRuntimeKind.remoteSSH.rawValue
                        || tool.toolName == IOSRemoteTerminalToolCatalog.jobStartToolName {
                runtimeTitle = "Remote SSH"
            } else {
                runtimeTitle = Self.localized("终端")
            }
            let failed = executed && Self.ishToolResultIndicatesFailure(tool.output)
            let action: String
            switch tool.toolName {
            case IOSRemoteTerminalToolCatalog.jobStartToolName:
                action = status == IOSTerminalJobStatus.running.rawValue
                    ? Self.localized("Remote SSH 作业已启动")
                    : Self.localized("启动 Remote SSH 作业")
            case IOSRemoteTerminalToolCatalog.jobStopToolName:
                action = IOSAppLocalization.formatted(
                    "停止 %@ 作业",
                    defaultValue: "停止 %@ 作业",
                    arguments: [runtimeTitle]
                )
            case IOSRemoteTerminalToolCatalog.jobWaitToolName:
                action = IOSAppLocalization.formatted(
                    "等待 %@ 作业",
                    defaultValue: "等待 %@ 作业",
                    arguments: [runtimeTitle]
                )
            default:
                action = IOSAppLocalization.formatted(
                    "读取 %@ 作业",
                    defaultValue: "读取 %@ 作业",
                    arguments: [runtimeTitle]
                )
            }
            let statusTitle: String?
            switch status {
            case IOSTerminalJobStatus.completed.rawValue: statusTitle = Self.localized("已完成")
            case IOSTerminalJobStatus.cancelled.rawValue: statusTitle = Self.localized("已取消")
            case IOSTerminalJobStatus.timedOut.rawValue: statusTitle = Self.localized("已超时")
            case IOSTerminalJobStatus.interrupted.rawValue: statusTitle = Self.localized("已中断")
            case IOSTerminalJobStatus.failed.rawValue: statusTitle = Self.localized("失败")
            default: statusTitle = nil
            }
            self.init(
                id: stableID,
                visualKind: .terminal,
                title: statusTitle.map {
                    IOSAppLocalization.formatted(
                        "%@ · %@",
                        defaultValue: "%@ · %@",
                        arguments: [action, $0]
                    )
                } ?? action,
                detail: executed ? Self.ishExecuteResultSummary(from: tool.output) : Self.ishHandoffInputSummary(from: tool.input),
                state: Self.terminalState(status: status, executed: executed, failed: failed)
            )
            return
        }

        if tool.toolName.hasPrefix("wm_") {
            let executed = !tool.output.isEmpty
            let failureReason = ChatToolOutputFormatter.failureReason(from: tool.output)
                .map(IOSWebMountRedactor.redactedText)
            let uncertainReason = Self.webMountUncertainReason(from: tool.output)
            let outcomeReason = failureReason ?? uncertainReason
            self.init(
                id: stableID,
                visualKind: kind,
                title: Self.combinedLine(
                    executed ? Self.webMountCompletedTitle(for: tool) : Self.webMountPendingTitle(for: tool.toolName),
                    Self.webMountInputSummary(for: tool.toolName, from: tool.input)
                ),
                detail: executed ? (outcomeReason ?? Self.webMountResultSummary(from: tool.output)) : nil,
                state: Self.state(executed: executed, failureReason: outcomeReason)
            )
            return
        }

        if IOSWorkspaceToolCatalog.supportedToolNames.contains(tool.toolName) {
            let executed = !tool.output.isEmpty
            let failureReason = ChatToolOutputFormatter.failureReason(from: tool.output)
            self.init(
                id: stableID,
                visualKind: kind,
                title: Self.combinedLine(
                    executed ? Self.workspaceCompletedTitle(for: tool.toolName) : Self.workspacePendingTitle(for: tool.toolName),
                    Self.workspaceInputSummary(from: tool.input)
                ),
                detail: executed ? (failureReason ?? Self.workspaceResultSummary(from: tool.output)) : Self.workspaceInputSummary(from: tool.input),
                state: Self.state(executed: executed, failureReason: failureReason)
            )
            return
        }

        let executed = !tool.output.isEmpty
        let failureReason = ChatToolOutputFormatter.failureReason(from: tool.output)
        let detailInput: String?
        if IOSProviderConfigToolCatalog.toolNames.contains(tool.toolName) {
            // Never surface raw api_key material on the tool capsule.
            detailInput = tool.input.isEmpty
                ? nil
                : IOSProviderConfigToolCatalog.redactedApprovalPreview(argumentsJSON: tool.input)
        } else {
            detailInput = tool.input.isEmpty ? nil : tool.input
        }
        self.init(
            id: stableID,
            visualKind: kind,
            title: Self.friendlyToolTitle(tool.toolName, executed: executed),
            detail: failureReason ?? detailInput,
            state: Self.state(executed: executed, failureReason: failureReason)
        )
    }

    private static func localized(_ key: String) -> String {
        IOSAppLocalization.string(key, defaultValue: key)
    }

    private static func state(executed: Bool, failureReason: String?) -> ChatToolStepState {
        guard executed else { return .active }
        return failureReason == nil ? .done : .failed
    }

    private static func stableID(for tool: UIMessagePart.Tool) -> String {
        let callID = tool.toolCallId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !callID.isEmpty { return callID }
        let fallbackInput = tool.input.replacingOccurrences(of: "\n", with: " ")
        return "\(tool.toolName):\(String(fallbackInput.prefix(80)))"
    }

    /// 未单独映射的工具:给一个友好中文标签,不显示裸工具名。状态由胶囊上的对勾/转圈表示,不再加文字。
    private static func friendlyToolTitle(_ name: String, executed: Bool) -> String {
        let known: [String: String] = [
            "file_read_selected": Self.localized("读取选中文件"),
            "skills_list": Self.localized("列出技能"),
            "use_skill": Self.localized("加载技能"),
            "skill_validate": Self.localized("校验技能"),
            "skill_import": Self.localized("导入技能"),
            "soul_import": Self.localized("更新核心指令"),
            "skill_enable": Self.localized("启用技能"),
            "skill_disable": Self.localized("禁用技能"),
            "mcp_list": Self.localized("列出 MCP"),
            "mcp_test": Self.localized("测试 MCP"),
            "mcp_import_from_skill": Self.localized("从技能导入 MCP"),
            "recipe_import": Self.localized("导入 Recipe"),
            "permissions_status": Self.localized("查看权限状态"),
            "tool_search": Self.localized("查找工具"),
            "tools_list": Self.localized("列出可用工具"),
            "subagent_report": Self.localized("子智能体汇报"),
            "terminal_execute": Self.localized("Remote SSH 执行"),
            "ios_shell_execute": Self.localized("AmberShell 执行"),
            "ish_handoff": Self.localized("iSH 交接"),
            "health_summary_read": Self.localized("读取健康摘要"),
            "weather_read": Self.localized("读取天气"),
            "calendar_events_list": Self.localized("查看日历事件"),
            "calendar_event_create": Self.localized("新建日历事件"),
            "calendar_event_update": Self.localized("更新日历事件"),
            "calendar_event_delete": Self.localized("删除日历事件"),
            "reminders_list": Self.localized("查看提醒事项"),
            "reminder_create": Self.localized("新建提醒事项"),
            "reminder_update": Self.localized("更新提醒事项"),
            "reminder_delete": Self.localized("删除提醒事项"),
            "reminder_complete": Self.localized("完成提醒事项"),
            "notification_schedule": Self.localized("安排本地通知"),
            "notification_cancel": Self.localized("取消本地通知"),
            "workout_plan_preview": Self.localized("预览健身计划"),
            "workout_schedule": Self.localized("安排健身计划"),
            "workouts_scheduled_list": Self.localized("查看已安排训练"),
            "workout_scheduled_remove": Self.localized("移除健身计划"),
            "provider_config_status": Self.localized("查看模型配置"),
            "provider_config_apply": Self.localized("应用提供商配置"),
            "provider_refresh_models": Self.localized("刷新模型列表"),
            "settings_set_model_slot": Self.localized("设置默认模型"),
            "theme_pack_status": Self.localized("查看主题"),
            "theme_pack_import": Self.localized("试穿主题"),
        ]
        if let mapped = known[name] { return mapped }
        // 动态工具名同样受列宽预算约束（见 combinedLine 注释），完整名在详情 sheet。
        if name.hasPrefix("mcp__") {
            return "MCP " + widthCappedPrefix(name.replacingOccurrences(of: "mcp__", with: ""), units: 32)
        }
        return name.isEmpty
            ? Self.localized("工具调用")
            : IOSAppLocalization.formatted(
                "调用 %@",
                defaultValue: "调用 %@",
                arguments: [widthCappedPrefix(name, units: 32)]
            )
    }

    private static func scrapeURL(from input: String) -> String? {
        guard let args = subAgentArgs(from: input) else {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(48))
        }
        for key in ["url", "link", "target"] {
            if let value = args[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return Self.shortURL(value)
            }
        }
        if let urls = args["urls"] as? [Any], let first = urls.first as? String {
            return Self.shortURL(first)
        }
        return nil
    }

    /// 取域名 + 路径首段,去掉协议与 query,胶囊里更易读。
    private static func shortURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: trimmed), let host = comps.host {
            let firstPath = comps.path.split(separator: "/").first.map { "/\($0)" } ?? ""
            return host + firstPath
        }
        return String(trimmed.prefix(48))
    }

    private static func mcpName(from input: String) -> String? {
        guard let args = subAgentArgs(from: input) else { return nil }
        for key in ["tool", "tool_name", "name", "server"] {
            if let value = args[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func subAgentArgs(from input: String) -> [String: Any]? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func subAgentRole(from input: String) -> String? {
        let args = subAgentArgs(from: input)
        let role = (args?["role_id"] as? String) ?? (args?["subagent_id"] as? String)
        guard let role, !role.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return role
    }

    static func subAgentTask(from input: String) -> String? {
        guard let args = subAgentArgs(from: input) else {
            // 解析失败(含流式未完成的截断 JSON):是 JSON 形态就不回退原始串,避免把 `{"objective"...`
            // 塞进胶囊标题;纯文本任务才原样用。
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty || trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) ? nil : trimmed
        }
        // 顶层字符串键
        for key in ["task", "prompt", "instruction", "objective", "input", "query"] {
            if let value = args[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        // 嵌套 task.objective(Android custom_subagent 的 task 结构)
        if let task = args["task"] as? [String: Any] {
            for key in ["objective", "prompt", "instruction"] {
                if let value = task[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func subAgentTitle(from input: String) -> String {
        // 胶囊只显示「标签 + 简短目标」,不再把整段 prompt 原样塞进标题。完整目标/输出留给详情 sheet。
        let role = subAgentRole(from: input)
        let label = role.map {
            IOSAppLocalization.formatted(
                "子智能体 @%@",
                defaultValue: "子智能体 @%@",
                arguments: [$0]
            )
        } ?? Self.localized("派发子任务")
        let objective = subAgentTask(from: input).map {
            String($0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(16))
        }
        return combinedLine(label, objective)
    }

    private static func subAgentDetail(from input: String) -> String? {
        guard let task = subAgentTask(from: input) else { return nil }
        return String(task.replacingOccurrences(of: "\n", with: " ").prefix(80))
    }

    /// "<verb> <subject>" on one line; the subject (query / prompt / target / task) is folded in
    /// so the pill reads like the action, not just a status word. Trimmed and length-capped.
    ///
    /// 上限按聊天列宽预算倒推（footnote 字号下 verb≤6 字 + subject 14 字 + 图标/
    /// 状态/内边距 ≈ 330pt ≤ 361pt 列宽）：cell 自 sizing 用无界提案询问理想宽度时
    /// `lineLimit(1)` 不生效，超长 subject 会把胶囊理想宽撑过列宽——轻则列宽随
    /// toolCallStarted/完成换词跳变，重则整行居中裁切、文字顶到屏幕两端。
    /// 完整内容在详情 sheet，胶囊只是状态芯片。
    private static func combinedLine(_ verb: String, _ subject: String?) -> String {
        guard let subject else { return verb }
        let oneLine = subject.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !oneLine.isEmpty else { return verb }
        return IOSAppLocalization.formatted(
            "%@ %@",
            defaultValue: "%@ %@",
            arguments: [verb, widthCappedPrefix(oneLine, units: 28)]
        )
    }

    /// 搜索胶囊标题槽占位：与 `combinedLine("搜索", subject)` 同一截断预算，
    /// 让空参 / 截断 JSON / 短 query / 长 query 共用同一理想宽，尾部转圈与对勾不左右挪。
    static var searchTitleLayoutSentinel: String {
        combinedLine(localized("搜索"), String(repeating: "字", count: 20))
    }

    /// 按显示宽度预算截断（CJK 计 2、ASCII 计 1）：纯按 Character 数会让
    /// ASCII subject 过短（14 个英文字母 ≈ 98pt，远低于列宽预算，信息白白损失），
    /// CJK 与混合文本仍守在 361pt 列宽内。
    private static func widthCappedPrefix(_ text: String, units: Int) -> String {
        var used = 0
        var count = 0
        for character in text {
            used += character.isASCII ? 1 : 2
            if used > units { break }
            count += 1
        }
        return String(text.prefix(count))
    }

    private static func searchQuery(from input: String) -> String? {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return nil }
        if let data = trimmedInput.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let query = object["query"] as? String else { return nil }
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedQuery.isEmpty ? nil : trimmedQuery
        }
        // 解析失败（含流式未完成的截断 JSON）：不要把 `{"query"...` 回退进标题，
        // 否则胶囊先被 JSON 撑宽、参数闭合后再缩回真实 query。
        if trimmedInput.hasPrefix("{") || trimmedInput.hasPrefix("[") {
            return nil
        }
        return trimmedInput
    }

    private static func imagePrompt(from input: String) -> String? {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return nil }
        if let data = trimmedInput.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let prompt = object["prompt"] as? String {
            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedPrompt.isEmpty ? nil : String(trimmedPrompt.prefix(120))
        }
        return String(trimmedInput.prefix(120))
    }

    private static func searchResultSummary(from output: [UIMessagePart]) -> String? {
        let text = output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n")
        guard !text.isEmpty else { return Self.localized("已返回搜索结果") }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        return firstLine ?? Self.localized("已返回搜索结果")
    }

    private static func webMountPendingTitle(for toolName: String) -> String {
        switch toolName {
        case "wm_open": Self.localized("准备打开网页")
        case "wm_tab_list": Self.localized("准备读取网页标签页")
        case "wm_tab_new": Self.localized("准备新建网页标签页")
        case "wm_tab_close": Self.localized("准备关闭网页标签页")
        case "wm_observe": Self.localized("准备观察网页")
        case "wm_extract": Self.localized("准备提取网页")
        case "wm_get": Self.localized("准备读取网页节点")
        case "wm_visual_snapshot": Self.localized("准备读取视觉快照")
        case "wm_screenshot": Self.localized("准备截取网页视口")
        case "wm_state": Self.localized("准备读取网页状态")
        case "wm_back": Self.localized("准备后退")
        case "wm_forward": Self.localized("准备前进")
        case "wm_clear_session": Self.localized("准备清理 WebMount Session")
        case "wm_site_add": Self.localized("准备添加 WebMount 站点")
        case "wm_site_remove": Self.localized("准备移除 WebMount 站点")
        case "wm_stations": Self.localized("准备读取 WebMount 站点")
        case "wm_click": Self.localized("准备点击网页元素")
        case "wm_tap": Self.localized("准备点击网页")
        case "wm_type": Self.localized("准备输入网页字段")
        case "wm_keys": Self.localized("准备发送网页按键")
        case "wm_scroll": Self.localized("准备滚动网页")
        case "wm_select": Self.localized("准备选择网页选项")
        case "wm_find": Self.localized("准备查找网页内容")
        case "wm_wait": Self.localized("等待网页条件")
        default: toolName
        }
    }

    private static func webMountCompletedTitle(for tool: UIMessagePart.Tool) -> String {
        switch tool.toolName {
        case "wm_open": Self.localized("网页已打开")
        case "wm_tab_list": Self.localized("网页标签页已读取")
        case "wm_tab_new": Self.localized("网页标签页已新建")
        case "wm_tab_close": Self.localized("网页标签页已关闭")
        case "wm_observe": Self.localized("网页观察已完成")
        case "wm_extract": Self.localized("网页内容已提取")
        case "wm_get": Self.localized("网页节点已读取")
        case "wm_visual_snapshot": Self.localized("视觉快照已读取")
        case "wm_screenshot": Self.localized("网页视口截图已保存")
        case "wm_state": Self.localized("网页状态已读取")
        case "wm_back": Self.localized("WebMount 已后退")
        case "wm_forward": Self.localized("WebMount 已前进")
        case "wm_clear_session": Self.localized("WebMount Session 已处理")
        case "wm_site_add": Self.localized("WebMount 站点已添加")
        case "wm_site_remove": Self.localized("WebMount 站点已移除")
        case "wm_stations": Self.localized("WebMount 站点已读取")
        case "wm_click": Self.localized("网页元素已点击")
        case "wm_tap": Self.localized("网页已点击")
        case "wm_type": Self.localized("网页字段已输入")
        case "wm_keys": Self.localized("网页按键已发送")
        case "wm_scroll": Self.localized("网页已滚动")
        case "wm_select": Self.localized("网页选项已选择")
        case "wm_find": Self.localized("网页内容已查找")
        case "wm_wait": Self.localized("网页等待已完成")
        default: tool.toolName
        }
    }

    private static func webMountInputSummary(for toolName: String, from input: String) -> String? {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return nil }
        guard let data = trimmedInput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let redacted = IOSWebMountRedactor.redactedJSONObject(object) as? [String: Any] else {
            return nil
        }

        let keys: [String]
        switch toolName {
        case "wm_site_add":
            keys = ["display_name", "name", "site_id", "homepage_url", "url"]
        case "wm_site_remove":
            keys = ["site_id", "display_name", "name"]
        case "wm_open", "wm_tab_new":
            keys = ["url", "homepage_url", "site_id"]
        case "wm_tab_close", "wm_clear_session":
            keys = ["session_id", "site_id"]
        case "wm_click", "wm_tap", "wm_type", "wm_keys", "wm_scroll", "wm_select", "wm_find", "wm_wait", "wm_get":
            // Never surface typed text, key sequences or select values in a chat capsule.
            keys = ["target", "selector", "ref", "condition", "kind", "attr_name"]
        default:
            keys = ["session_id", "site_id"]
        }

        for key in keys {
            guard let value = redacted[key] as? String else { continue }
            let safeValue: String
            if key == "url" || key == "homepage_url" {
                safeValue = IOSWebMountRedactor.redactedURL(value) ?? "[redacted-url]"
            } else {
                safeValue = IOSWebMountRedactor.redactedText(value)
            }
            let trimmed = safeValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        return nil
    }

    private static func ishHandoffInputSummary(from input: String) -> String? {
        guard let args = subAgentArgs(from: input) else {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
        }
        if let filename = args["filename"] as? String, !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return filename
        }
        if let purpose = args["purpose"] as? String, !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return purpose
        }
        if let command = args["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(command.prefix(80))
        }
        if let script = args["script"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(script.prefix(80))
        }
        return nil
    }

    /// S5 (`IOSToolLoopGuard.proceedAndRemind`) appends a *separate* plain-text
    /// reminder Text part after the tool's real JSON output (see
    /// `appendingToolLoopReminder`), so joining every Text part with "\n" and
    /// parsing the combined string as one JSON object breaks the moment a
    /// reminder is present — the tool's own JSON is still valid on its own,
    /// but "json\nreminder sentence" as a whole is not, so every summary/
    /// failure-detection helper built on that join-then-parse pattern silently
    /// stopped recognizing a valid result (or a failure) once a reminder was
    /// attached. Parse each Text part independently instead and take the
    /// first one that decodes as a JSON object — behavior is unchanged for
    /// the common single-JSON-part case, and robust to "JSON + appended text".
    static func firstJSONObject(in parts: [UIMessagePart]) -> [String: Any]? {
        for text in parts.compactMap({ ($0 as? UIMessagePart.Text)?.text }) {
            guard let data = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            return object
        }
        return nil
    }

    private static func ishHandoffResultSummary(from output: [UIMessagePart]) -> String? {
        guard let object = firstJSONObject(in: output) else { return nil }
        if let ok = object["ok"] as? Bool, !ok {
            return (object["error"] as? String) ?? (object["reason"] as? String) ?? Self.localized("交接失败")
        }
        let copied = (object["copied_to_clipboard"] as? Bool) == true
            ? Self.localized("已复制")
            : Self.localized("未复制")
        let file = object["script_file_name"] as? String ?? "script.sh"
        return IOSAppLocalization.formatted(
            "%@ · %@ · 无输出回传",
            defaultValue: "%@ · %@ · 无输出回传",
            arguments: [copied, file]
        )
    }

    private static func ishExecuteResultSummary(from output: [UIMessagePart]) -> String? {
        guard let object = firstJSONObject(in: output) else { return nil }
        if let ok = object["ok"] as? Bool, !ok {
            return (object["error"] as? String)?.nilIfBlank
                ?? (object["stderr"] as? String)?.nilIfBlank
                ?? Self.localized("执行失败")
        }
        let status = (object["status"] as? String)?.lowercased()
        let stdout = (object["stdout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = (object["stderr"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == "queued" || status == IOSTerminalJobStatus.running.rawValue {
            if let stdout, !stdout.isEmpty {
                return IOSAppLocalization.formatted(
                    "运行中 · %@",
                    defaultValue: "运行中 · %@",
                    arguments: [String(stdout.prefix(80))]
                )
            }
            if let stderr, !stderr.isEmpty {
                return IOSAppLocalization.formatted(
                    "运行中 · stderr: %@",
                    defaultValue: "运行中 · stderr: %@",
                    arguments: [String(stderr.prefix(80))]
                )
            }
            return Self.localized("运行中")
        }
        let exitCode = object["exit_code"] as? Int
        if let stdout, !stdout.isEmpty {
            return exitCode.map {
                IOSAppLocalization.formatted(
                    "exit %ld · %@",
                    defaultValue: "exit %ld · %@",
                    arguments: [$0, String(stdout.prefix(80))]
                )
            }
                ?? String(stdout.prefix(80))
        }
        if let stderr, !stderr.isEmpty {
            return exitCode.map {
                IOSAppLocalization.formatted(
                    "exit %ld · stderr: %@",
                    defaultValue: "exit %ld · stderr: %@",
                    arguments: [$0, String(stderr.prefix(80))]
                )
            }
                ?? IOSAppLocalization.formatted(
                    "stderr: %@",
                    defaultValue: "stderr: %@",
                    arguments: [String(stderr.prefix(80))]
                )
        }
        return exitCode.map {
            IOSAppLocalization.formatted(
                "exit %ld · 无输出",
                defaultValue: "exit %ld · 无输出",
                arguments: [$0]
            )
        }
            ?? (status == IOSTerminalJobStatus.completed.rawValue
                ? Self.localized("已完成 · 无输出")
                : Self.localized("无输出"))
    }

    private static func terminalState(status: String?, executed: Bool, failed: Bool) -> ChatToolStepState {
        switch status?.lowercased() {
        case "queued", IOSTerminalJobStatus.running.rawValue:
            return .active
        case IOSTerminalJobStatus.completed.rawValue:
            return .done
        case IOSTerminalJobStatus.cancelled.rawValue:
            return .cancelled
        case IOSTerminalJobStatus.failed.rawValue,
             IOSTerminalJobStatus.timedOut.rawValue,
             IOSTerminalJobStatus.interrupted.rawValue:
            return .failed
        default:
            return failed ? .failed : (executed ? .done : .active)
        }
    }

    private static func ishToolResultIndicatesFailure(_ output: [UIMessagePart]) -> Bool {
        guard let object = firstJSONObject(in: output) else { return false }
        if let ok = object["ok"] as? Bool { return !ok }
        if let denied = object["denied"] as? Bool, denied { return true }
        if let status = object["status"] as? String {
            return ["failed", "error", "denied", "timed_out", "cancelled"].contains(status.lowercased())
        }
        if let exitCode = object["exit_code"] as? Int {
            return exitCode != 0
        }
        return false
    }

    private static func workspacePendingTitle(for toolName: String) -> String {
        switch toolName {
        case "workspace_file_read": Self.localized("准备读取 Workspace 文件")
        case "workspace_file_write": Self.localized("准备写入 Workspace 文件")
        case "workspace_artifact_read": Self.localized("准备读取 Artifact")
        case "workspace_artifact_delete": Self.localized("准备删除 Artifact")
        default: toolName
        }
    }

    private static func workspaceCompletedTitle(for toolName: String) -> String {
        switch toolName {
        case "workspace_file_read": Self.localized("Workspace 文件已读取")
        case "workspace_file_write": Self.localized("Workspace 文件已写入")
        case "workspace_artifact_read": Self.localized("Artifact 已读取")
        case "workspace_artifact_delete": Self.localized("Artifact 已删除")
        default: toolName
        }
    }

    private static func workspaceInputSummary(from input: String) -> String? {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return nil }
        if let data = trimmedInput.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(160))
        }
        return String(trimmedInput.prefix(160))
    }

    private static func workspaceResultSummary(from output: [UIMessagePart]) -> String? {
        let text = output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n")
        guard !text.isEmpty else { return Self.localized("已返回 Workspace 结果") }
        guard let object = firstJSONObject(in: output) else {
            return String(text.prefix(160))
        }
        if object["denied"] as? Bool == true {
            let reason = (object["reason"] as? String) ?? Self.localized("Workspace 权限限制")
            return IOSAppLocalization.formatted(
                "已拒绝：%@",
                defaultValue: "已拒绝：%@",
                arguments: [reason]
            )
        }
        if let path = object["path"] as? String {
            return path
        }
        if let title = object["title"] as? String {
            return title
        }
        if let error = object["error"] as? String {
            return IOSAppLocalization.formatted(
                "失败：%@",
                defaultValue: "失败：%@",
                arguments: [error]
            )
        }
        return Self.localized("已返回 Workspace 结果")
    }

    private static func webMountResultSummary(from output: [UIMessagePart]) -> String? {
        let text = output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n")
        guard !text.isEmpty else { return Self.localized("已返回 WebMount 结果") }
        guard let object = firstJSONObject(in: output) else {
            return Self.localized("已返回 WebMount 结果")
        }
        if object["denied"] as? Bool == true {
            let reason = IOSWebMountRedactor.redactedText(
                (object["reason"] as? String) ?? Self.localized("WebMount 权限限制")
            )
            return IOSAppLocalization.formatted(
                "已拒绝：%@",
                defaultValue: "已拒绝：%@",
                arguments: [reason]
            )
        }
        if object["unsupported"] as? Bool == true {
            let tool = (object["tool"] as? String) ?? Self.localized("WebMount 工具")
            return IOSAppLocalization.formatted(
                "iOS 暂不支持：%@",
                defaultValue: "iOS 暂不支持：%@",
                arguments: [tool]
            )
        }
        if let status = object["status"] as? String {
            let safeStatus = IOSWebMountRedactor.redactedText(status)
            let safeURL = IOSWebMountRedactor.redactedURL(object["url"] as? String)
            return [safeStatus.nilIfBlank, safeURL?.nilIfBlank].compactMap { $0 }.joined(separator: " · ")
        }
        if let artifact = object["artifact"] as? [String: Any],
           let artifactId = artifact["artifact_id"] as? String {
            let size = artifact["size_bytes"].map {
                IOSAppLocalization.formatted(
                    "%@ bytes",
                    defaultValue: "%@ bytes",
                    arguments: [String(describing: $0)]
                )
            }
            return [artifactId, size].compactMap { $0?.nilIfBlank }.joined(separator: " · ")
        }
        if let closed = object["closed_session_id"] as? String {
            return IOSAppLocalization.formatted(
                "已关闭 %@",
                defaultValue: "已关闭 %@",
                arguments: [closed]
            )
        }
        if let count = object["count"] as? Int {
            if object["sessions"] != nil {
                return IOSAppLocalization.formatted(
                    "%ld 个网页会话",
                    defaultValue: "%ld 个网页会话",
                    arguments: [count]
                )
            }
            return IOSAppLocalization.formatted(
                "%ld 个站点",
                defaultValue: "%ld 个站点",
                arguments: [count]
            )
        }
        if let sessionId = object["session_id"] as? String {
            return IOSAppLocalization.formatted(
                "会话：%@",
                defaultValue: "会话：%@",
                arguments: [sessionId]
            )
        }
        if let siteId = object["site_id"] as? String {
            return IOSAppLocalization.formatted(
                "站点：%@",
                defaultValue: "站点：%@",
                arguments: [siteId]
            )
        }
        return Self.localized("已返回 WebMount 结果")
    }

    private static func webMountUncertainReason(from output: [UIMessagePart]) -> String? {
        guard let object = firstJSONObject(in: output),
              object["may_have_applied"] as? Bool == true,
              let status = (object["status"] as? String)?.lowercased(),
              ["dispatched_unverified", "ambiguous", "unknown_after_action"].contains(status) else {
            return nil
        }
        return Self.localized("操作已发送，但结果尚未验证；请先重新观察页面。")
    }

}

struct ChatToolTimeline: View {
    let steps: [ChatToolStepModel]
    /// Tapping a step (used for subagent steps, which open a detail sheet). nil = not tappable.
    var onTapStep: ((ChatToolStepModel) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { step in
                let tappable = onTapStep != nil
                if tappable {
                    Button { onTapStep?(step) } label: { row(step, chevron: true) }
                        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.98, haptic: .selection))
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(IOSAppLocalization.formatted(
                            "%@，状态：%@",
                            defaultValue: "%@，状态：%@",
                            arguments: [step.title, step.state.accessibilityTitle]
                        ))
                } else {
                    row(step, chevron: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    // Cream capsule: colored tool icon (no backing square) + title (+ optional detail) + trailing
    // status (green check when done, spinner while active, ! on failure). Matches the requested
    // pill style shared with the reasoning card.
    @ViewBuilder
    private func row(_ step: ChatToolStepModel, chevron: Bool) -> some View {
        HStack(spacing: 7) {
            // Koboyo 实心剪影：与思考胶囊同系；进行中轻呼吸（不用 SF symbolEffect）。
            Group {
                if step.state == .active {
                    ChatKoboyoSpinningIcon(
                        mark: step.koboyoMark,
                        pointSize: 14,
                        tint: UIColor(step.state.color),
                        isActive: !reduceMotion
                    )
                } else {
                    ChatKoboyoIcon(step.koboyoMark, size: 14)
                        .foregroundStyle(step.state.color)
                }
            }
            .frame(width: 16, height: 16)

            titleLabel(for: step)

            trailingStatus(for: step.state)

            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Background first (hug the HStack), then cap at the column proposal so long
        // titles truncate without expanding ScrollView content width. Short titles
        // stay chip-sized and leading-aligned — do not use fixedSize(horizontal:false)
        // here or the capsule stretches to full column width.
        .background(step.state.rowFill, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(step.state.stroke, lineWidth: 0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Capsule(style: .continuous))
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.84), value: step.state)
    }

    /// 网页搜索的流式标题走固定槽，避免 query 尚未闭合时胶囊反复跳宽。
    /// `tool_search` 等仅借用搜索图标的工具仍按内容自适应，不预留空白。
    @ViewBuilder
    private func titleLabel(for step: ChatToolStepModel) -> some View {
        let label = Text(step.title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(AmberTheme.foreground2)
            .lineLimit(1)
            .truncationMode(.tail)
        let searchVerb = IOSAppLocalization.string("搜索", defaultValue: "搜索")
        if step.visualKind == .search,
           step.title == searchVerb || step.title.hasPrefix("\(searchVerb) ") {
            Text(ChatToolStepModel.searchTitleLayoutSentinel)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.clear)
                .accessibilityHidden(true)
                .overlay(alignment: .leading) {
                    label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(step.title)
        } else {
            label
        }
    }

    @ViewBuilder
    private func trailingStatus(for state: ChatToolStepState) -> some View {
        Group {
            switch state {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AmberTheme.accentGreen)
                    .contentTransition(.symbolEffect(.replace.downUp))
            case .active:
                ProgressView()
                    .controlSize(.mini)
                    .tint(AmberTheme.accent)
            case .cancelled:
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AmberTheme.muted)
                    .contentTransition(.symbolEffect(.replace.downUp))
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
        }
        // 状态指示器固定占位（转圈/对勾/叹号同槽居中）：胶囊宽度在
        // toolCallStarted → toolResultAppended 生命周期内不随状态图标尺寸变化。
        .frame(width: 18, height: 18)
    }
}
