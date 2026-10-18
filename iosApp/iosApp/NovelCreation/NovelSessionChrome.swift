import SwiftUI

struct NovelSessionChrome: View {
    let workspace: NovelCreationViewModel
    let viewModel: NovelSessionViewModel
    let recovery: NovelSessionQuickStartRecovery?
    let syncBannerText: String
    @Binding var pendingRecoveryAbandonTransactionIDs: [NovelPendingOperationID]
    @Binding var recoveryAbandonTask: Task<Void, Never>?
    @Binding var ghostwriteRevisionRequest: NovelGhostwriteRevisionRequest?

    @ViewBuilder
    var body: some View {
        if let transaction = viewModel.unresolvedBranchPolishTransactions.first {
            polishRecoveryBanner(transaction)
        }

        if let projectID = workspace.selectedProjectID,
           let branchID = workspace.selectedBranchID,
           let activity = workspace.stateSyncActivity,
           activity.projectID == projectID,
           activity.branchID == branchID {
            stateSyncProgressBanner(activity)
        } else if let projectID = workspace.selectedProjectID,
                  let branchID = workspace.selectedBranchID,
                  workspace.canCancelAutomaticStateSync(
                      projectID: projectID,
                      branchID: branchID
                  ) ||
                  workspace.isStateSyncStopping(
                      projectID: projectID,
                      branchID: branchID
                  ) {
            // Preparing / stopping before activity is published, or after Stop
            // while teardown finishes — keep Stop reachable and block explained.
            stateSyncLightweightBanner(projectID: projectID, branchID: branchID)
        } else if let projectID = workspace.selectedProjectID,
                  let branchID = workspace.selectedBranchID,
                  let failure = workspace.stateSyncRecoveryMessage(
                      projectID: projectID,
                      branchID: branchID
                  ) {
            automaticStateSyncFailureBanner(
                failure,
                projectID: projectID,
                branchID: branchID
            )
        } else if !viewModel.retryableBranchPendingOperations.isEmpty && !viewModel.isBusy {
            synchronizationBanner
        }

        if let recovery {
            quickStartRecoveryBanner(recovery)
        }

        if let error = viewModel.errorMessage,
           error != viewModel.ghostwriteContinueBlockerMessage {
            errorBanner(error)
        }

        // 代笔状态条：中断/失败后主界面也能直接「继续」，不必打开管理面板。
        if let ghostwrite = viewModel.ghostwriteProgress {
            ghostwriteStatusBar(ghostwrite)
        }

    }

    private var synchronizationBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(AmberTheme.accentAmber)

            Text(syncBannerText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.foreground2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let pending = viewModel.retryableBranchPendingOperations.first {
                Button("重试") {
                    Task { @MainActor in
                        await viewModel.retryPending(pending.id)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .disabled(
                    viewModel.isRunning || viewModel.isBusy || workspace.requiresReload ||
                        viewModel.access != .readWrite
                )
            }
        }
    }

    private func automaticStateSyncFailureBanner(
        _ message: String,
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                NovelPresentation.localizedCachedErrorMessage(message),
                systemImage: "exclamationmark.arrow.triangle.2.circlepath"
            )
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.foreground2)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试同步") {
                workspace.retryStateSync(
                    projectID: projectID,
                    branchID: branchID
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            // Same gate as workspace/reader: branch-scoped canRetry only.
            .disabled(
                !workspace.canRetryStateSync(projectID: projectID, branchID: branchID)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func polishRecoveryBanner(
        _ transaction: NovelPendingPolishTransactionRecord
    ) -> some View {
        let unresolvedTransactions = viewModel.unresolvedBranchPolishTransactions
        let unresolvedCount = unresolvedTransactions.count
        let blocker = NovelSessionComposerPolicy.polishTransactionBlocker(
            access: viewModel.access,
            requiresReload: workspace.requiresReload,
            isRunning: viewModel.isRunning,
            isBusy: viewModel.isPerformingAction || workspace.isPerforming
        )
        let retryBlocker = blocker ?? viewModel.polishTransactionSourceBlocker(transaction.id)
        let isRetrying = viewModel.polishRetryTransactionID == transaction.id
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AmberTheme.accentAmber)

            VStack(alignment: .leading, spacing: 2) {
                Text(unresolvedCount > 1
                    ? "还有 \(unresolvedCount) 项润色需要处理"
                    : "上次润色还需要处理")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground2)
                if isRetrying {
                    Text("正在检查剧情一致性…")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                } else {
                    Text(recoveryAbandonTask == nil
                        ? polishRecoveryDetail(transaction, blocker: retryBlocker)
                        : "正在放弃未完成的润色…")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isRetrying {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Button("停止") {
                        viewModel.cancelPolishRetry()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
            } else {
                Menu("处理") {
                    if transaction.status == .pending || transaction.status == .retryable {
                        Button("重试检查", systemImage: "arrow.clockwise") {
                            viewModel.startPolishRetry(transaction.id)
                        }
                        .disabled(retryBlocker != nil)
                    }
                    Button("放弃这次润色", systemImage: "xmark.circle", role: .destructive) {
                        pendingRecoveryAbandonTransactionIDs = [transaction.id]
                    }
                    if unresolvedCount > 1 {
                        Button(
                            "放弃全部 \(unresolvedCount) 项",
                            systemImage: "xmark.circle.fill",
                            role: .destructive
                        ) {
                            pendingRecoveryAbandonTransactionIDs = unresolvedTransactions.map(\.id)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(blocker != nil || recoveryAbandonTask != nil)
                .confirmationDialog(
                    pendingRecoveryAbandonTransactionIDs.count > 1
                        ? "放弃全部 \(pendingRecoveryAbandonTransactionIDs.count) 项润色？"
                        : "放弃这次润色？",
                    isPresented: recoveryAbandonConfirmationBinding,
                    titleVisibility: .visible
                ) {
                    Button(
                        pendingRecoveryAbandonTransactionIDs.count > 1 ? "全部放弃" : "放弃润色",
                        role: .destructive
                    ) {
                        let transactionIDs = pendingRecoveryAbandonTransactionIDs
                        pendingRecoveryAbandonTransactionIDs = []
                        abandonRecoveryTransactions(transactionIDs)
                    }
                    Button("取消", role: .cancel) {
                        pendingRecoveryAbandonTransactionIDs = []
                    }
                } message: {
                    Text("候选会保留在创作记录中，但不能再作为润色版采用。")
                }
            }
        }
    }

    private var recoveryAbandonConfirmationBinding: Binding<Bool> {
        Binding(
            get: { !pendingRecoveryAbandonTransactionIDs.isEmpty },
            set: { presented in
                if !presented { pendingRecoveryAbandonTransactionIDs = [] }
            }
        )
    }

    private func abandonRecoveryTransactions(
        _ transactionIDs: [NovelPendingOperationID]
    ) {
        guard !transactionIDs.isEmpty,
              recoveryAbandonTask == nil else { return }
        recoveryAbandonTask = Task { @MainActor in
            _ = await viewModel.abandonPolishTransactions(transactionIDs)
            recoveryAbandonTask = nil
        }
    }

    private func polishRecoveryDetail(
        _ transaction: NovelPendingPolishTransactionRecord,
        blocker: NovelSessionActionBlocker?
    ) -> String {
        if let blocker {
            return IOSAppLocalization.formatted(
                "当前不可处理：%@",
                defaultValue: "当前不可处理：%@",
                arguments: [
                    IOSAppLocalization.string(
                        blocker.displayName,
                        defaultValue: blocker.displayName
                    )
                ]
            )
        }
        if let message = transaction.lastFailure?.message.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !message.isEmpty {
            return message
        }
        return transaction.status == .blocked
            ? IOSAppLocalization.string(
                "这次润色已被阻止，可以放弃后继续创作。",
                defaultValue: "这次润色已被阻止，可以放弃后继续创作。"
            )
            : IOSAppLocalization.string(
                "剧情一致性检查未完成，可以重试或放弃。",
                defaultValue: "剧情一致性检查未完成，可以重试或放弃。"
            )
    }

    private func stateSyncLightweightBanner(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) -> some View {
        NovelStateSyncProgressBanner(
            title: workspace.stateSyncStatusTitle(projectID: projectID, branchID: branchID)
                ?? IOSAppLocalization.string(
                    "正在按正文更新剧情记录",
                    defaultValue: "正在按正文更新剧情记录"
                ),
            activity: nil,
            secondaryHint: workspace.isStateSyncStopping(
                projectID: projectID,
                branchID: branchID
            )
                ? IOSAppLocalization.string(
                    "正在停止，完成后可继续操作。",
                    defaultValue: "正在停止，完成后可继续操作。"
                )
                : IOSAppLocalization.string(
                    "正在准备同步请求…",
                    defaultValue: "正在准备同步请求…"
                ),
            canStop: workspace.canCancelAutomaticStateSync(
                projectID: projectID,
                branchID: branchID
            ),
            onStop: {
                workspace.cancelAutomaticStateSync(
                    projectID: projectID,
                    branchID: branchID
                )
            }
        )
    }

    private func stateSyncProgressBanner(_ activity: NovelStateSyncActivity) -> some View {
        NovelStateSyncProgressBanner(
            title: workspace.stateSyncStatusTitle(
                projectID: activity.projectID,
                branchID: activity.branchID
            ) ?? activity.statusTitle,
            activity: activity,
            canStop: workspace.canCancelAutomaticStateSync(
                projectID: activity.projectID,
                branchID: activity.branchID
            ),
            onStop: {
                workspace.cancelAutomaticStateSync(
                    projectID: activity.projectID,
                    branchID: activity.branchID
                )
            }
        )
    }

    private func errorBanner(_ message: String) -> some View {
        let displayedMessage = NovelPresentation.localizedCachedErrorMessage(message)
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(AmberTheme.accentAmber)
            Text(displayedMessage)
                .font(.footnote)
                .foregroundStyle(AmberTheme.foreground2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.isRetryingLastTerminal {
                Button {
                    // The retry owns this control until its durable start result is known.
                } label: {
                    ZStack {
                        Text("重试").opacity(0)
                        ProgressView().controlSize(.small)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(true)
                .accessibilityLabel("正在重新生成")
            } else if viewModel.hasRefreshError
                || NovelPresentation.shouldOfferReload(for: message)
                || displayedMessage.contains("重新载入")
                || displayedMessage.contains("刷新后") {
                Button("重新载入") {
                    Task { @MainActor in
                        _ = await viewModel.refresh()
                        viewModel.clearError()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            } else if viewModel.canRetryPendingTerminal {
                Button("重试保存") {
                    Task { @MainActor in await viewModel.retryPendingTerminal() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            } else if viewModel.canRetryLastTerminal {
                Button("重试") {
                    Task { @MainActor in _ = await viewModel.retryLastTerminal() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            } else {
                Button {
                    viewModel.clearError()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭错误提示")
            }
        }
    }

    /// 主界面代笔状态条：状态 + 详情 + 暂停/处理/继续。润修仍复用既有事务，
    /// 继续键沿用与面板一致的 `canStartGhostwriteChapter` 门。
    private func ghostwriteStatusBar(_ progress: NovelGhostwriteProgress) -> some View {
        let blocker: String? = {
            guard !viewModel.isGhostwriting,
                  progress.shouldContinueSameBatch,
                  !viewModel.canStartGhostwriteChapter else { return nil }
            return viewModel.ghostwriteContinueBlockerMessage
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(
                    systemName: viewModel.isGhostwriting
                        ? "pencil.and.scribble"
                        : (progress.pauseReason == .backgroundInterrupted ? "arrow.clockwise.circle" : "pause.circle")
                )
                    .font(.body)
                    .foregroundStyle(AmberTheme.accentAmber)
                    .frame(width: 22, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(progress.statusLabel)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = progress.detailMessage, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if viewModel.isGhostwriting {
                    Button("暂停") {
                        viewModel.pauseGhostwrite()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minWidth: 64, minHeight: 44)
                    .contentShape(Rectangle())
                } else if progress.shouldContinueSameBatch {
                    Button(ghostwriteStatusBarContinueTitle(progress)) {
                        if progress.pauseReason == .blockingContinuity {
                            presentContinuityRepairOptions(progress)
                        } else {
                            _ = viewModel.continueGhostwriteChapter()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(minWidth: 72, minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(!viewModel.canStartGhostwriteChapter)
                }
            }
            if let blocker {
                Text(blocker)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentRed)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private func ghostwriteStatusBarContinueTitle(_ progress: NovelGhostwriteProgress) -> String {
        switch progress.pauseReason {
        case .continuityAuditIncomplete:
            return IOSAppLocalization.string("再检查", defaultValue: "再检查")
        case .syncFailed:
            return IOSAppLocalization.string("继续同步", defaultValue: "继续同步")
        case .healBudgetExhausted:
            return IOSAppLocalization.string("继续", defaultValue: "继续")
        case .blockingContinuity:
            return IOSAppLocalization.string("处理硬伤", defaultValue: "处理硬伤")
        default:
            return progress.mustRewriteCandidateOnResume
                ? IOSAppLocalization.string("重写", defaultValue: "重写")
                : IOSAppLocalization.string("继续", defaultValue: "继续")
        }
    }

    private func presentContinuityRepairOptions(_ progress: NovelGhostwriteProgress) {
        let receipt = progress.lastFailureReceipt
        let recommendedBrief = receipt?.recommendedRevisionBrief()
            ?? progress.detailMessage
            ?? NovelGhostwritePauseReason.blockingContinuity.displayMessage
        let detail = receipt?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        ghostwriteRevisionRequest = NovelGhostwriteRevisionRequest(
            recommendedBrief: recommendedBrief,
            detail: detail?.isEmpty == false ? detail : progress.detailMessage,
            strategies: NovelGhostwriteRevisionStrategy.continuityOptions(
                recommendedBrief: recommendedBrief
            )
        )
    }

    private func quickStartRecoveryBanner(
        _ recovery: NovelSessionQuickStartRecovery
    ) -> some View {
        let displayedMessage = NovelPresentation.localizedCachedErrorMessage(recovery.message)
        return HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(AmberTheme.accentAmber)
            Text(displayedMessage)
                .font(.footnote)
                .foregroundStyle(AmberTheme.foreground2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(recovery.actionTitle) {
                Task { @MainActor in
                    switch recovery {
                    case .retry:
                        await workspace.startQuickStartSuggestions()
                    case .reload:
                        await workspace.reloadQuickStartProject()
                    case .retryPersistence(let runID, _):
                        await workspace.retryQuickStartPersistence(runID: runID)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .disabled(
                workspace.isPerforming ||
                    workspace.requiresReload ||
                    viewModel.isRunning ||
                    viewModel.isBusy ||
                    viewModel.access != .readWrite
            )
        }
    }

}

enum NovelSessionQuickStartRecovery {
    case retry(message: String)
    case reload(message: String)
    case retryPersistence(runID: NovelRunID, message: String)

    var message: String {
        switch self {
        case .retry(let message), .reload(let message), .retryPersistence(_, let message):
            return message
        }
    }

    var actionTitle: String {
        switch self {
        case .retry:
            IOSAppLocalization.string("重新生成", defaultValue: "重新生成")
        case .reload:
            IOSAppLocalization.string("重新载入", defaultValue: "重新载入")
        case .retryPersistence:
            IOSAppLocalization.string("重试保存", defaultValue: "重试保存")
        }
    }
}
