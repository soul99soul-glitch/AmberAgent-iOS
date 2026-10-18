import Foundation

enum IOSAdvancedTaskKind: String, Codable, CaseIterable, Identifiable {
    case subAgent = "sub_agent"
    case modelCouncil = "model_council"
    case remoteCommand = "remote_command"
    case embeddedIsh = "embedded_ish"
    case toolApproval = "tool_approval"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subAgent: "SubAgent"
        case .modelCouncil: "模型议会"
        case .remoteCommand: "远程执行"
        case .embeddedIsh: "内置 iSH 作业"
        case .toolApproval: "工具审批"
        }
    }
}

enum IOSAdvancedTaskStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case queued
    case running
    case approvalRequired = "approval_required"
    case completed
    case failed
    case cancelled
    case timedOut = "timed_out"
    case interrupted

    var id: String { rawValue }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .timedOut, .interrupted:
            true
        case .queued, .running, .approvalRequired:
            false
        }
    }

    var title: String {
        switch self {
        case .queued: "排队中"
        case .running: "运行中"
        case .approvalRequired: "等待确认"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        case .timedOut: "已超时"
        case .interrupted: "已中断"
        }
    }
}

struct IOSAdvancedTaskRecord: Codable, Equatable, Identifiable {
    var id: String
    var kind: IOSAdvancedTaskKind
    var title: String
    var objective: String
    var status: IOSAdvancedTaskStatus
    var roleId: String?
    var toolScope: [String]
    var budgetSummary: String
    var connectionSummary: String
    var commandPreview: String
    var resultSummary: String
    var logTail: String
    var error: String
    var retryable: Bool
    var cancelCapability: Bool
    var sourceToolName: String
    var metadata: [String: String]
    var createdAt: Date
    var updatedAt: Date

    var canRetry: Bool {
        retryable && status.isTerminal
    }

    var compactSummary: String {
        if !resultSummary.isEmpty { return resultSummary }
        if !error.isEmpty { return error }
        if !logTail.isEmpty { return logTail }
        return objective
    }
}

