import Foundation

extension TaskState {
    public func label(_ reason: WaitReason? = nil, abnormal: Bool = false) -> String {
        switch self {
        case .running: "运行中"
        case .waiting: reason == .permission ? "等你确认" : "等你回复"
        case .stalled: "可能卡住了"
        case .completed: "已完成"
        case .stopped: abnormal ? "意外中断" : "已停止"
        }
    }
}

extension AgentKind {
    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .run: "任务"
        }
    }
}

/// Lock-screen text shared by every push channel. Metadata only (design doc section 2 hard constraint).
public enum PushContent {
    public static func render(_ intent: PushIntent, gatewayName: String) -> (title: String, body: String) {
        switch intent.kind {
        case .task:
            let agent = intent.agent?.displayName ?? "任务"
            return ("\(agent) · \(intent.subject)", intent.state?.label(intent.waitReason, abnormal: intent.abnormal) ?? "")
        case .health:
            return ("\(gatewayName) 健康提醒", intent.detail ?? intent.subject)
        case .sleep:
            return ("\(gatewayName) 即将睡眠", intent.detail ?? "")
        case .test:
            return ("\(gatewayName)", "测试推送：通道已连通")
        }
    }
}
