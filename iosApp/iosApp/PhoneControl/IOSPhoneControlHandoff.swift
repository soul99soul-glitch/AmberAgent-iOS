import Foundation

/// This is the active owner's phone-control child state, not a new chat run state.
enum IOSPhoneControlHandoffState: String, Sendable, Equatable {
    case automated, pausing, paused, resuming

    var statusMessage: String {
        switch self {
        case .automated: "Amber 正在自动操作，可随时请求人工接手。"
        case .pausing: "正在暂停，等待在途操作回执；收到回执前请先不要操作。"
        case .paused: "已暂停自动操作，你可以操作手机；完成后点继续。"
        case .resuming: "等待 Amber 重新读取界面，再交给主模型重新规划。"
        }
    }
}

/// A late completion can only affect its original run and native session.
struct IOSPhoneControlToolLease: Sendable, Equatable {
    let runID: String
    let sessionID: UUID
    let operationID: UUID
    let takeoverGeneration: Int
}

enum IOSPhoneControlHandoffError: LocalizedError {
    case preparationCheck, operationInFlight, notPaused, outcomeUnknown

    var errorDescription: String? {
        switch self {
        case .preparationCheck: "自动化检查不支持人工接手；可以取消检查。"
        case .operationInFlight: "正在等待在途操作回执，请在暂停完成后继续。"
        case .notPaused: "当前手机控制任务尚未暂停。"
        case .outcomeUnknown: "上一动作结果未知，本轮不能继续操作，请停止后重新发起任务。"
        }
    }
}
