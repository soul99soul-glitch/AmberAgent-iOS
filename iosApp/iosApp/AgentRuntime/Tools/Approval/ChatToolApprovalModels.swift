import Foundation
@preconcurrency import Shared

struct MemoryToolApprovalRequest: Identifiable, Equatable {
    let id: String
    let action: String
    let scope: String?
    let kind: String?
    let contentPreview: String?
    let targetId: Int?
    let expectedUpdatedAt: Int64?
    let reason: String

    var title: String {
        switch action {
        case "create", "add", "write":
            "保存记忆"
        case "edit", "update":
            "更新记忆"
        case "delete", "remove":
            "删除记忆"
        default:
            "修改记忆"
        }
    }
}

struct WebMountToolApprovalRequest: Identifiable, Equatable {
    let id: String
    let toolName: String
    let siteId: String
    let siteName: String
    let host: String
    let backend: String
    let mcpServerName: String?
    let redactedURL: String
    let snapshotId: String?
    let target: String?
    let action: String
    let consequence: String
    let screenshotRetentionWarning: String?
    let siteMemoryChanges: [String]?
    let siteMemoryBaseline: String?
    let requiresHumanHandoff: Bool
    let reason: String
    let sessionId: String?
    let runId: String?

    var title: String {
        if requiresHumanHandoff {
            return "在本地 WebMount 完成后继续"
        }
        switch toolName {
        case "wm_clear_session":
            return "清除 WebMount Session"
        case "wm_site_memory":
            return "确认站点记忆变更"
        default:
            return "执行 WebMount 前台动作"
        }
    }
}

struct WorkspaceToolApprovalRequest: Identifiable, Equatable {
    let id: String
    let toolName: String
    let action: String
    let target: String
    let isWrite: Bool
    let reason: String

    var title: String {
        isWrite ? "修改 Workspace" : "读取 Workspace"
    }
}

struct SearchToolApprovalRequest: Identifiable, Equatable {
    let id: String
    let toolName: String
    let target: String
    let providerName: String
    let providerType: String
    let reason: String

    var title: String {
        switch toolName {
        case "scrape_web":
            "读取网页"
        default:
            "执行网络搜索"
        }
    }
}

enum McpSkillImportMutationKind: String, Codable, Equatable {
    case new
    case update
}

enum McpSkillImportFileChangeKind: String, Codable, Equatable {
    case added
    case modified
    case removed
}

struct McpSkillImportFileChange: Identifiable, Codable, Equatable {
    let path: String
    let kind: McpSkillImportFileChangeKind
    let beforeText: String?
    let afterText: String?

    var id: String { path }

    init(
        path: String,
        kind: McpSkillImportFileChangeKind,
        beforeText: String? = nil,
        afterText: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.beforeText = beforeText
        self.afterText = afterText
    }
}

struct McpSkillImportPreview: Codable, Equatable {
    let skillName: String
    let mutationKind: McpSkillImportMutationKind
    let baseHash: String?
    let candidateHash: String
    let beforeSummary: String
    let afterSummary: String
    let changedFiles: [McpSkillImportFileChange]
    let containsMcpConfig: Bool

    init(
        skillName: String,
        mutationKind: McpSkillImportMutationKind,
        baseHash: String? = nil,
        candidateHash: String,
        beforeSummary: String,
        afterSummary: String,
        changedFiles: [McpSkillImportFileChange] = [],
        containsMcpConfig: Bool = false
    ) {
        self.skillName = skillName
        self.mutationKind = mutationKind
        self.baseHash = baseHash
        self.candidateHash = candidateHash
        self.beforeSummary = beforeSummary
        self.afterSummary = afterSummary
        self.changedFiles = changedFiles
        self.containsMcpConfig = containsMcpConfig
    }
}

struct SoulImportPreview: Codable, Equatable {
    let baseHash: String
    let candidateHash: String
    let changedLineCount: Int
    let diffPreview: String
    let afterSummary: String
}

struct McpImportServerPreview: Codable, Equatable, Identifiable {
    let name: String
    let transport: String
    let origin: String
    let headerNames: [String]
    let enabled: Bool

    var id: String { name }
}

struct McpImportPreview: Codable, Equatable {
    let skillName: String
    let digest: String
    let servers: [McpImportServerPreview]
}

struct McpToolApprovalRequest: Identifiable, Equatable {
    let id: String
    let serverName: String
    let toolName: String
    let argumentsPreview: String
    let reason: String
    let skillImportPreview: McpSkillImportPreview?
    let soulImportPreview: SoulImportPreview?
    let mcpImportPreview: McpImportPreview?
    let themePackPreview: AmberThemePackDocument?

    init(
        id: String,
        serverName: String,
        toolName: String,
        argumentsPreview: String,
        reason: String,
        skillImportPreview: McpSkillImportPreview? = nil,
        soulImportPreview: SoulImportPreview? = nil,
        mcpImportPreview: McpImportPreview? = nil,
        themePackPreview: AmberThemePackDocument? = nil
    ) {
        self.id = id
        self.serverName = serverName
        self.toolName = toolName
        self.argumentsPreview = argumentsPreview
        self.reason = reason
        self.skillImportPreview = skillImportPreview
        self.soulImportPreview = soulImportPreview
        self.mcpImportPreview = mcpImportPreview
        self.themePackPreview = themePackPreview
    }

    var title: String {
        if serverName == "iPhone" {
            switch toolName {
            case let name where name.hasPrefix("calendar_"): "确认日历操作"
            case let name where name.hasPrefix("reminder_"): "确认提醒事项操作"
            case let name where name.hasPrefix("notification_"): "确认通知操作"
            case let name where name.hasPrefix("alarm_") || name == "alarms_list": IOSAlarmCopy.approvalTitle
            case let name where name.hasPrefix("workout_") || name == "workouts_scheduled_list": "确认健身计划操作"
            case let name where name.hasPrefix("health_"): "确认健康数据读取"
            case let name where name.hasPrefix("weather_"): "确认天气读取"
            default: "确认 iPhone 操作"
            }
        } else if toolName == "soul_import" {
            "更新核心指令"
        } else if toolName == "skill_import" {
            "导入技能"
        } else if toolName == "mcp_import_from_skill" {
            "导入 MCP"
        } else if toolName == "theme_pack_import" {
            "试穿主题"
        } else if IOSSSHProfileToolCatalog.mutatingToolNames.contains(toolName) {
            toolName == IOSSSHProfileToolCatalog.deleteToolName ? "删除 SSH Profile" : "确认 SSH Profile 变更"
        } else if IOSSSHKeyToolCatalog.mutatingToolNames.contains(toolName) {
            toolName == IOSSSHKeyToolCatalog.deleteToolName ? "删除 SSH 密钥" : "确认 SSH 密钥操作"
        } else if toolName.hasPrefix("skill_") || toolName == "mcp_test" {
            "确认扩展操作"
        } else {
            "执行 MCP 工具"
        }
    }

    var isAppleCapability: Bool { serverName == "iPhone" }

    var isDestructiveAppleAction: Bool {
        isAppleCapability && (
            toolName.hasSuffix("_delete")
                || toolName.hasSuffix("_cancel")
                || toolName.hasSuffix("_remove")
        )
    }

    /// SSH profile / key writes use the local server chip like provider/theme tools,
    /// but a delete is destructive chrome (red, trash glyph).
    var isDestructiveLocalMutation: Bool {
        !isAppleCapability && (
            toolName == IOSSSHProfileToolCatalog.deleteToolName
                || toolName == IOSSSHKeyToolCatalog.deleteToolName
        )
    }

    /// 高风险本地写：不能在锁屏 Live Activity / 灵动岛 / 手表上批准。
    /// 与 `IOSSSHProfileToolCatalog.highRiskToolNames` 及破坏性 Apple 动作同源，
    /// 但用纯字符串集合表达，避免审批模型反向依赖工具目录类型。
    var isHighRiskLocalMutation: Bool {
        !isAppleCapability && IOSSecretArgumentRedaction.carriesCredential(toolName)
    }

    var displayToolName: String {
        Self.displayName(for: toolName)
    }

    var appleConsequenceWarning: String? {
        guard isAppleCapability else { return nil }
        return switch toolName {
        case IOSAppleAgentToolCatalog.alarmSchedule:
            IOSAlarmCopy.scheduleWarning
        case IOSAppleAgentToolCatalog.alarmCancel:
            IOSAlarmCopy.cancelWarning
        case IOSAppleAgentToolCatalog.workoutSchedule:
            "批准后，这个计划会出现在 Apple Watch 的体能训练 App 中。"
        case IOSAppleAgentToolCatalog.scheduledWorkoutRemove:
            "批准后，这个 Amber 健身计划会从体能训练 App 中移除。"
        default:
            nil
        }
    }

    static func displayName(for toolName: String) -> String {
        let names = [
            "calendar_events_list": "查看日历事件",
            "calendar_event_create": "新建日历事件",
            "calendar_event_update": "更新日历事件",
            "calendar_event_delete": "删除日历事件",
            "reminders_list": "查看提醒事项",
            "reminder_create": "新建提醒事项",
            "reminder_update": "更新提醒事项",
            "reminder_delete": "删除提醒事项",
            "reminder_complete": "完成提醒事项",
            "notification_schedule": "安排本地通知",
            "notification_cancel": "取消本地通知",
            "alarm_schedule": IOSAlarmCopy.scheduleTool,
            "alarms_list": IOSAlarmCopy.listTool,
            "alarm_cancel": IOSAlarmCopy.cancelTool,
            "contacts_pick": "选择联系人",
            "photos_pick": "选择照片",
            "journaling_suggestion_pick": "选择日记建议",
            "workout_plan_preview": "预览健身计划",
            "workout_schedule": "安排健身计划",
            "workouts_scheduled_list": "查看已安排训练",
            "workout_scheduled_remove": "移除健身计划",
            "health_summary_read": "读取健康摘要",
            "weather_read": "读取天气",
            "ssh_profile_list": "查看 SSH Profile",
            "ssh_profile_create": "新建 SSH Profile",
            "ssh_profile_update": "修改 SSH Profile",
            "ssh_profile_delete": "删除 SSH Profile",
            "ssh_key_list": "查看 SSH 密钥",
            "ssh_key_generate": "生成 SSH 密钥",
            "ssh_key_import": "导入 SSH 密钥",
            "ssh_key_delete": "删除 SSH 密钥",
        ]
        return names[toolName] ?? toolName
    }

    var systemImage: String {
        if toolName.hasPrefix("calendar_") { return "calendar.badge.clock" }
        if toolName.hasPrefix("reminder_") { return "checklist" }
        if toolName.hasPrefix("notification_") { return "bell.badge" }
        if toolName.hasPrefix("alarm_") || toolName == "alarms_list" { return "alarm" }
        if toolName == IOSAppleAgentToolCatalog.contactsPick { return "person.crop.circle.badge.checkmark" }
        if toolName == IOSAppleAgentToolCatalog.photosPick { return "photo.on.rectangle.angled" }
        if toolName == IOSAppleAgentToolCatalog.journalingSuggestionPick { return "book.pages" }
        if IOSAppleAgentToolCatalog.workoutToolNames.contains(toolName) { return "figure.run" }
        if toolName.hasPrefix("health_") { return "heart.text.clipboard" }
        if toolName.hasPrefix("weather_") { return "cloud.sun" }
        if IOSSSHProfileToolCatalog.contains(toolName) {
            return toolName == IOSSSHProfileToolCatalog.deleteToolName ? "trash" : "server.rack"
        }
        if IOSSSHKeyToolCatalog.contains(toolName) {
            return toolName == IOSSSHKeyToolCatalog.deleteToolName ? "trash" : "key.fill"
        }
        return themePackPreview == nil ? "point.3.connected.trianglepath.dotted" : "swatchpalette"
    }
}

struct ChatAskUserRequest: Identifiable, Equatable {
    let id: String
    let question: String
    let options: [String]

    var title: String { "需要你的回答" }
}

struct CouncilToolApprovalRequest: Identifiable, Equatable {
    let id: String
    let objectivePreview: String
    let maxSeats: Int?
    let reason: String

    var title: String { "启动模型议会" }
    var capabilityId: String { "ios.agent.model_council_run" }
    var systemImage: String { "person.3.sequence" }
}

enum IshToolApprovalMode: String, Equatable {
    case handoff
    case embeddedExecute
    case amberShell
    case remoteSSH
    case remoteJobStart
    case remoteJobStop
    case embeddedJobStart
    case embeddedJobStop
}

enum IshToolApprovalScope: Equatable {
    case once
    case session
    case global
}

struct IshHandoffToolApprovalRequest: Identifiable, Equatable {
    let id: String
    let mode: IshToolApprovalMode
    let commandPreview: String
    let filename: String
    let reason: String
    var contextLines: [String] = []
    var remoteProfileId: String? = nil
    var remoteTargetDigest: String? = nil
    var runId: String? = nil
    /// Whether the user can approve this card (false when a host key fingerprint changed,
    /// which requires manual replacement in Settings -> Remote Environment).
    var allowsApprove: Bool = true
    /// Whether approval is restricted to foreground UI only (e.g. first-time host key trust).
    var requiresForegroundApproval: Bool = false
    var remoteHostTrust: IOSSSHHostTrustProposal? = nil

    var capabilityId: String {
        switch mode {
        case .handoff:
            "ios.external.ish_handoff"
        case .embeddedExecute, .embeddedJobStart, .embeddedJobStop:
            "ios.embedded.ish_runtime"
        case .amberShell:
            "ios.local.ambershell"
        case .remoteSSH, .remoteJobStart, .remoteJobStop:
            "ios.remote.command"
        }
    }

    var presentationId: String {
        "\(runId ?? "unscoped")|\(capabilityId)|\(id)"
    }

    var title: String {
        switch mode {
        case .handoff: "交接到 iSH"
        case .embeddedExecute: "执行内置 iSH"
        case .amberShell:
            IOSAppLocalization.string("执行 AmberShell", defaultValue: "执行 AmberShell")
        case .remoteSSH: "执行 Remote SSH"
        case .remoteJobStart: "启动 Remote SSH 作业"
        case .remoteJobStop: "停止 Remote SSH 作业"
        case .embeddedJobStart: "启动内置 iSH 作业"
        case .embeddedJobStop: "停止内置 iSH 作业"
        }
    }

    var primaryChip: (systemImage: String, title: String) {
        switch mode {
        case .handoff: ("doc.on.clipboard", "复制到剪贴板")
        case .embeddedExecute: ("terminal", "本地执行")
        case .amberShell:
            ("terminal.fill", IOSAppLocalization.string("稳定版本地执行", defaultValue: "稳定版本地执行"))
        case .remoteSSH: ("desktopcomputer", "远程执行")
        case .remoteJobStart: ("play.fill", "启动作业")
        case .remoteJobStop: ("stop.fill", "停止作业")
        case .embeddedJobStart: ("play.fill", "异步启动")
        case .embeddedJobStop: ("stop.fill", "停止作业")
        }
    }

    var secondaryChip: (systemImage: String, title: String) {
        switch mode {
        case .handoff: ("hand.tap", "需手动粘贴")
        case .embeddedExecute: ("arrowshape.turn.up.left", "回传输出")
        case .amberShell:
            ("arrowshape.turn.up.left", IOSAppLocalization.string("回传输出", defaultValue: "回传输出"))
        case .remoteSSH: ("arrowshape.turn.up.left", "回传输出")
        case .remoteJobStart: ("number", "返回 Job ID")
        case .remoteJobStop: ("checkmark.circle", "幂等取消")
        case .embeddedJobStart: ("number", "返回 Job ID")
        case .embeddedJobStop: ("checkmark.circle", "幂等取消")
        }
    }

    var commandReviewAccessibilityHint: String {
        switch mode {
        case .handoff:
            "审批前检查将交接到外部 iSH 的完整命令"
        case .embeddedExecute, .embeddedJobStart, .embeddedJobStop:
            "审批前检查内置 iSH 的完整命令"
        case .amberShell:
            IOSAppLocalization.string(
                "审批前检查 AmberShell 的完整命令",
                defaultValue: "审批前检查 AmberShell 的完整命令"
            )
        case .remoteSSH, .remoteJobStart, .remoteJobStop:
            "审批前检查完整的 Remote SSH 命令"
        }
    }
}

