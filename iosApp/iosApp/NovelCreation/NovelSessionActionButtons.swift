import SwiftUI

private func localized(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}

struct NovelSessionActionButtons: View {
    let actions: [NovelSessionRowActionAvailability]
    let granularity: NovelGenerationGranularity?
    let retryingRunID: NovelRunID?
    let cloningCandidateID: NovelCandidateID?
    let undoingCheckpointID: NovelCheckpointID?
    let retryingPolishTransactionID: NovelPendingOperationID?
    let onCancelPolishRetry: () -> Void
    let onAction: (NovelSessionRowAction) -> Void

    @State private var pendingAbandonTransactionID: NovelPendingOperationID?

    var body: some View {
        ForEach(actions, id: \.action) { item in
            if item.action.isPrimary {
                actionButton(item)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            } else {
                actionButton(item)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ item: NovelSessionRowActionAvailability) -> some View {
        if case .retryPolish(let transactionID) = item.action,
           retryingPolishTransactionID == transactionID {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Button(localized("停止检查")) {
                    onCancelPolishRetry()
                }
                .frame(minHeight: 44)
            }
        } else if case .abandonPolish(let transactionID) = item.action {
            baseButton(item) {
                pendingAbandonTransactionID = transactionID
            }
            .confirmationDialog(
                localized("放弃这次润色？"),
                isPresented: Binding(
                    get: { pendingAbandonTransactionID == transactionID },
                    set: { presented in
                        if !presented { pendingAbandonTransactionID = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(localized("放弃润色"), role: .destructive) {
                    pendingAbandonTransactionID = nil
                    onAction(item.action)
                }
                Button(localized("取消"), role: .cancel) {
                    pendingAbandonTransactionID = nil
                }
            } message: {
                Text(localized("候选气泡会保留在创作记录中，但不能再作为润色版采用。"))
            }
        } else {
            baseButton(item) {
                onAction(item.action)
            }
        }
    }

    private func baseButton(
        _ item: NovelSessionRowActionAvailability,
        action: @escaping () -> Void
    ) -> some View {
        let isInFlight = isInFlight(item.action)
        return Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    Image(systemName: item.action.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .opacity(isInFlight ? 0 : 1)
                    if isInFlight {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 18, height: 18)
                Text(item.action.displayTitle(granularity: granularity))
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isInFlight ? inFlightTitle(for: item.action) : item.action.displayTitle(granularity: granularity))
        }
        .controlSize(.small)
        .disabled(!item.isEnabled || isInFlight)
        .accessibilityHint(item.blocker.map { localized($0.displayName) } ?? "")
    }

    private func isInFlight(_ action: NovelSessionRowAction) -> Bool {
        switch action {
        case .retryGeneration(let runID): retryingRunID == runID
        case .cloneCollectedProse(let candidateID): cloningCandidateID == candidateID
        case .undoCommittedChange(let checkpointID, _): undoingCheckpointID == checkpointID
        default: false
        }
    }

    private func inFlightTitle(for action: NovelSessionRowAction) -> String {
        switch action {
        case .retryGeneration: localized("正在重新生成")
        case .cloneCollectedProse: localized("正在再次收录")
        case .undoCommittedChange(_, let kind):
            localized(kind == .polish ? "正在撤销润色" : "正在撤销收录")
        default: action.displayTitle(granularity: granularity)
        }
    }
}

extension NovelSessionRowAction {
    var requiresMutation: Bool {
        if case .viewSettingProposals = self { return false }
        return true
    }

    func displayTitle(granularity: NovelGenerationGranularity?) -> String {
        switch self {
        case .collectProse:
            switch granularity {
            case .continuation: localized("收录到本章")
            case .wholeChapter: localized("作为新章收录")
            case nil: localized("收录正文")
            }
        case .adoptPolish: localized("采用润色版")
        case .retryGeneration: localized("重新生成")
        case .retryTerminalPersistence: localized("重试保存")
        case .retryPending: localized("继续收录")
        case .retryPolish: localized("重试检查")
        case .abandonPolish: localized("放弃润色")
        case .convertPolishToManualRewrite: localized("保存为剧情改写")
        case .cloneCollectedProse: localized("再次收录")
        case .forkFromCheckpoint: localized("从这里 Fork")
        case .viewSettingProposals: localized("查看并确认设定建议")
        case .undoCommittedChange(_, let kind):
            localized(kind == .polish ? "撤销润色" : "撤销收录")
        }
    }

    var systemImage: String {
        switch self {
        case .collectProse: "text.badge.checkmark"
        case .adoptPolish: "checkmark.seal"
        case .retryGeneration, .retryTerminalPersistence, .retryPending, .retryPolish:
            "arrow.clockwise"
        case .abandonPolish: "xmark.circle"
        case .convertPolishToManualRewrite: "square.and.pencil"
        case .cloneCollectedProse: "doc.on.doc"
        case .forkFromCheckpoint: "arrow.triangle.branch"
        case .viewSettingProposals: "books.vertical"
        case .undoCommittedChange: "arrow.uturn.backward"
        }
    }

    var isPrimary: Bool {
        switch self {
        case .collectProse, .adoptPolish, .viewSettingProposals: true
        default: false
        }
    }
}

extension NovelSessionActionBlocker {
    var displayName: String {
        switch self {
        case .projectReadOnly: "项目当前只读"
        case .reloadRequired: "请先重新载入项目"
        case .branchInactive: "分支已不可编辑"
        case .branchNeedsSync: "剧情状态同步未完成"
        case .chapterPlanRequired: "代笔写整章前，请先确认本章计划"
        case .ghostwriteReviewRequired: "代笔稿需通过审核后由代笔流程收录"
        case .ghostwriteRequirementsMissing: "代笔条件尚未满足"
        case .generationRunning: "请先停止当前生成"
        case .pendingOperation: "有正文操作正在处理"
        case .transactionInProgress: "操作正在处理"
        case .transactionBlocked: "操作已被阻止"
        case .staleCandidate: "当前剧情已变化，候选已过期"
        case .sourceChapterChanged: "源章节版本已经变化"
        case .failureNotRetryable: "该失败不能直接重试"
        }
    }
}
