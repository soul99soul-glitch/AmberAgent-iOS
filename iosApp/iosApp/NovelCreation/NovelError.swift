import Foundation

enum NovelError: Error, Equatable, Sendable {
    case invalidInput(String)
    case projectNotFound(NovelProjectID)
    case projectAlreadyExists(NovelProjectID)
    case branchNotFound(NovelBranchID)
    case sessionNotFound(NovelSessionID)
    case stateSnapshotNotFound(NovelStateSnapshotID)
    case checkpointNotFound(NovelCheckpointID)
    case runNotFound(NovelRunID)
    case staleProjectRevision(expected: Int64, actual: Int64)
    case staleConfigRevision(expected: Int64, actual: Int64)
    case staleBranchHeadRevision(expected: Int64, actual: Int64)
    case idempotencyConflict(NovelOperationID)
    case immutableRecordConflict(String)
    case invalidDocument([String])
    case corruptedProject(projectID: NovelProjectID, details: String)
    case degradedReadOnly(projectID: NovelProjectID)
    case repositoryFailure(String)
    case storageUnavailable(String)
    case storageIndeterminate(NovelProjectID)
    case invalidRecovery(String)
    case invalidPackage(String)
    case packageTooLarge(maximumBytes: Int)
    case packageChecksumMismatch
    case injectionBudgetExceeded(
        required: Int,
        limit: Int,
        items: [NovelInjectionBudgetItem]
    )
    case modelUnavailable(String)
    case generationUnavailable
    case unsupportedSchema(Int)
    case projectBusy(NovelProjectID)
}

extension NovelError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidInput(let detail):
            // Prefer humanized pipeline copy; never drop the associated detail.
            NovelPresentation.operationErrorMessage(NovelError.invalidInput(detail))
        case .projectNotFound: "找不到这个小说项目。"
        case .projectAlreadyExists: "这个小说项目已经存在。"
        case .branchNotFound: "找不到这个剧情分支。"
        case .sessionNotFound: "找不到这次创作会话。"
        case .stateSnapshotNotFound: "找不到对应的剧情状态。"
        case .checkpointNotFound: "找不到对应的存档点。"
        case .runNotFound: "找不到这次生成记录。"
        case .staleProjectRevision: "项目已发生变化，请刷新后重试。"
        case .staleConfigRevision: "项目设置已发生变化，请刷新后重试。"
        case .staleBranchHeadRevision: "当前分支已发生变化，请刷新后重试。"
        case .idempotencyConflict: "检测到重复但内容不同的操作，请刷新后重试。"
        case .immutableRecordConflict: "历史记录与当前数据冲突，请重新载入项目。"
        case .invalidDocument: "项目数据不完整或不一致，暂时无法继续编辑。"
        case .corruptedProject: "项目文件已损坏，请尝试恢复上一个有效版本。"
        case .degradedReadOnly: "项目已从上一个有效版本恢复，目前只能阅读。"
        case .repositoryFailure: "项目保存失败，请稍后重试。"
        case .storageUnavailable: "暂时无法访问项目存储。"
        case .storageIndeterminate: "无法确认项目是否已保存，请重新载入后再继续。"
        case .invalidRecovery: "项目恢复数据无效。"
        case .invalidPackage: "项目包无效或不完整。"
        case .packageTooLarge(let maximumBytes):
            "项目包超过大小限制（最多 \(maximumBytes) 字节）。"
        case .packageChecksumMismatch: "项目包校验失败，文件可能不完整。"
        case .injectionBudgetExceeded(let required, let limit, _):
            "所需上下文约为 \(required)，超过当前长度限制 \(limit)。"
        case .modelUnavailable: "项目模型当前不可用，请在“设定 > 更多”中重新选择。"
        case .generationUnavailable: "小说生成功能当前不可用。"
        case .unsupportedSchema(let version): "暂不支持版本 \(version) 的小说项目。"
        case .projectBusy: "项目正在处理其他操作。请先停止生成，或稍后再试。"
        }
    }
}
