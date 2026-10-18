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
        if name.contains("subagent_dispatch") || name == "spawn_agent" || name == "followup_task" {
            return .subagent
        }
        if IOSRemoteTerminalToolCatalog.supportedToolNames.contains(name) { return .terminal }
        if IOSAppleAgentToolCatalog.toolNames.contains(name) { return .apple }
        if IOSPhoneControlToolCatalog.isPhoneTool(name: name) { return .apple }
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

