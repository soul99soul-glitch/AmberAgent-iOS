import Foundation

/// 长程工具任务的两个上限：模型↔工具往返轮数，以及整个任务的实际运行时长。
/// 轮数给"能跑多久"，时长给"最多跑多久"——长任务真正该被时间兜底，而不是被 8 轮掐断。
enum DesktopAgentRunLimits {
    static let roundOptions = [64, 128, 256, 512, 1024, 2048, 4096, 8192]
    static let defaultRounds = 2048
    static let minuteOptions = [30, 60, 120, 180, 300, 480, 720]
    static let defaultMinutes = 300

    static func clampedRounds(_ value: Int) -> Int {
        min(roundOptions.last ?? defaultRounds, max(roundOptions.first ?? defaultRounds, value))
    }

    static func clampedMinutes(_ value: Int) -> Int {
        min(minuteOptions.last ?? defaultMinutes, max(minuteOptions.first ?? defaultMinutes, value))
    }

    static func deadline(minutes: Int, from start: Date = Date()) -> Date {
        start.addingTimeInterval(TimeInterval(clampedMinutes(minutes)) * 60)
    }

    /// 单轮步数上限；审批暂停后按剩余轮数续跑，因此这里传的是整轮预算。
    static func rounds(_ override: Int?) -> Int {
        clampedRounds(override ?? defaultRounds)
    }
}

/// 工具任务结束的真实原因。以前四种终态共用一句「任务已停止」，用户无法判断是撞了轮数、
/// 输出上限、模型报错，还是被循环守卫拦下；现在各自说清楚。
enum DesktopAgentStopReason: Equatable {
    case roundLimit(Int)
    case loopGuard
    case outputLimit
    case providerFailure
    case timeLimit(minutes: Int)

    /// 输入框上方的横幅文案。
    var banner: String {
        switch self {
        case .roundLimit(let rounds):
            "已用满 \(rounds) 轮工具步数上限，任务已停止；已收到的结果已保留。可在设置 › 通用 › 工具任务里调高轮数。"
        case .loopGuard:
            "模型连续以相同参数重复调用同一工具，已停止本次任务；已收到的结果已保留。"
        case .outputLimit:
            "模型回复达到输出上限，已停止本次任务；已收到的结果已保留。"
        case .providerFailure:
            "模型请求失败，已停止本次任务；请检查网络、认证与模型配置后重试。"
        case .timeLimit(let minutes):
            "已达 \(minutes) 分钟的运行时长上限，任务已停止；已收到的结果已保留。"
        }
    }

    /// 任务记录里的短原因。
    var record: String {
        switch self {
        case .roundLimit(let rounds): "达到 \(rounds) 轮工具步数上限。"
        case .loopGuard: "重复同一工具调用被停止。"
        case .outputLimit: "模型回复达到输出上限。"
        case .providerFailure: "模型请求失败。"
        case .timeLimit(let minutes): "达到 \(minutes) 分钟运行时长上限。"
        }
    }
}
