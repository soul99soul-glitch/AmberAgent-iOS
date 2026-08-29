import Foundation

/// Host 与 Engine hook 测试共用的有序事件日志。
enum IOSNormalizedRunEvent: Equatable {
    case runStarted
    case toolCallStarted(tool: String)
    case toolCallFinished(tool: String, outcome: String)
    case approvalRequested(kind: String)
    case approvalDenied(tool: String)
    /// run 迁移到 awaiting_permission,绑定到具体 toolCallId。
    case runAwaitingPermission(toolCallId: String)
    /// 审批后 CAS 回 running。
    case runResumed
    /// 终态:completed / failed / cancelled / interrupted。
    case runTerminal(status: String)

}

/// 共享有序事件日志:harness 的每个录制点(bindings、账本、脚本化派发)
/// 按真实发生顺序追加。顺序即事实——不需要跨表时间戳归并。
final class IOSRunEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [IOSNormalizedRunEvent] = []

    func append(_ event: IOSNormalizedRunEvent) {
        lock.withLock { entries.append(event) }
    }

    func snapshot() -> [IOSNormalizedRunEvent] {
        lock.withLock { entries }
    }

    /// 最后一个终态状态(无则 nil)——waitForTerminal 的轮询目标。
    func terminalStatus() -> String? {
        snapshot().compactMap { event -> String? in
            guard case .runTerminal(let status) = event else { return nil }
            return status
        }.last
    }
}
