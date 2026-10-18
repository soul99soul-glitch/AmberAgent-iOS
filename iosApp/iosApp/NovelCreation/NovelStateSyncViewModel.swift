import Foundation
import Observation
import UIKit

struct NovelStateSyncActivity: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case analyzing
    }

    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let pendingID: NovelPendingOperationID
    let phase: Phase
    let startedAt: Date
    let requestStartedAt: Date?
    let completedCharacters: Int
    let totalCharacters: Int?
    let completedChunks: Int

    var completionFraction: Double? {
        guard let totalCharacters, totalCharacters > 0 else { return nil }
        return min(1, max(0, Double(completedCharacters) / Double(totalCharacters)))
    }

    /// Percent bar only after at least one durable chunk lands — first long model
    /// call would otherwise sit at 0% and look stuck.
    var displayedCompletionFraction: Double? {
        guard completedCharacters > 0 else { return nil }
        return completionFraction
    }

    var displayedPercent: Int? {
        displayedCompletionFraction.map { Int(($0 * 100).rounded(.down)) }
    }

    var statusTitle: String {
        switch phase {
        case .preparing:
            IOSAppLocalization.string("正在准备剧情状态", defaultValue: "正在准备剧情状态")
        case .analyzing:
            IOSAppLocalization.string("正在同步剧情状态", defaultValue: "正在同步剧情状态")
        }
    }

    /// Preferred-cap estimate so banners do not imply "segment 1 forever" on long books.
    var estimatedTotalSegments: Int? {
        guard let totalCharacters, totalCharacters > 0 else { return nil }
        return NovelManualSyncChunker.estimatedSegmentCount(
            manuscriptCharacterCount: totalCharacters
        )
    }

    var segmentedRebuildHint: String? {
        guard let estimatedTotalSegments, estimatedTotalSegments > 1 else { return nil }
        return IOSAppLocalization.string(
            "分段读取正文并更新剧情状态，大项目会较久。",
            defaultValue: "分段读取正文并更新剧情状态，大项目会较久。"
        )
    }

    /// Secondary copy for banners: chunk, word count, elapsed — always concrete
    /// even before the first durable percent is available.
    /// `streamedCharacters` 是当前段已流式到达的字数（>0 时替换「完成后才更新」的静态提示）。
    func progressDetail(elapsedSeconds: Int, streamedCharacters: Int = 0) -> String {
        let elapsed = max(0, elapsedSeconds)
        let streamedDetail = streamedCharacters > 0 ? " · 本段已生成 \(streamedCharacters) 字" : nil
        switch phase {
        case .preparing:
            return "已等待 \(elapsed) 秒 · 正在准备请求"
        case .analyzing:
            let currentSegment = completedChunks + 1
            if let percent = displayedPercent {
                let chunkDetail = completedChunks > 0
                    ? " · 已完成 \(completedChunks) 段"
                    : ""
                if let estimated = estimatedTotalSegments, estimated > 1 {
                    return "正文已处理 \(percent)%\(chunkDetail) / 约 \(estimated) 段 · 已等待 \(elapsed) 秒"
                        + (streamedDetail ?? "")
                }
                return "正文已处理 \(percent)%\(chunkDetail) · 已等待 \(elapsed) 秒"
                    + (streamedDetail ?? "")
            }
            if let totalCharacters, totalCharacters > 0 {
                if let estimated = estimatedTotalSegments, estimated > 1 {
                    let streamed = streamedDetail ?? " · 本段完成后才会更新进度"
                    if completedChunks > 0 {
                        return "正文共 \(totalCharacters) 字 · 约 \(estimated) 段 · 已完成 \(completedChunks) 段 · 正在处理第 \(currentSegment) 段 · 已等待 \(elapsed) 秒" + streamed
                    }
                    return "正文共 \(totalCharacters) 字 · 约 \(estimated) 段 · 正在处理第 \(currentSegment) 段 · 已等待 \(elapsed) 秒" + streamed
                }
                // Single preferred segment: avoid "第 1 段" which sounds stuck forever.
                return "正文共 \(totalCharacters) 字 · 全文分析中 · 已等待 \(elapsed) 秒"
                    + (streamedDetail ?? " · 模型返回后才会更新进度")
            }
            return "正在分析第 \(currentSegment) 段 · 已等待 \(elapsed) 秒" + (streamedDetail ?? "")
        }
    }

    static func preparing(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        pendingID: NovelPendingOperationID,
        startedAt: Date
    ) -> NovelStateSyncActivity {
        NovelStateSyncActivity(
            projectID: projectID,
            branchID: branchID,
            pendingID: pendingID,
            phase: .preparing,
            startedAt: startedAt,
            requestStartedAt: nil,
            completedCharacters: 0,
            totalCharacters: nil,
            completedChunks: 0
        )
    }

    static func project(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        pending: NovelPendingOperationRecord,
        snapshot: NovelProjectSnapshot,
        attemptOperationID: NovelOperationID,
        startedAt: Date
    ) -> NovelStateSyncActivity? {
        guard pending.kind == .manualSync,
              let chapters = try? NovelFactTransactionReducer.decodeManualPayload(
                  pending.selectedText
              ) else { return nil }
        let manuscript = NovelFactTransactionReducer.manualRebuildManuscript(chapters)
        let progress = pending.manualSyncProgress
        let requestStartedAt = snapshot.generationReceipts
            .filter {
                $0.factTransaction?.pendingID == pending.id &&
                    $0.factTransaction?.attemptOperationID == attemptOperationID
            }
            .max(by: { $0.createdAt < $1.createdAt })?
            .createdAt
        return NovelStateSyncActivity(
            projectID: projectID,
            branchID: branchID,
            pendingID: pending.id,
            phase: .analyzing,
            startedAt: startedAt,
            requestStartedAt: requestStartedAt,
            completedCharacters: min(progress?.consumedCharacterCount ?? 0, manuscript.count),
            totalCharacters: manuscript.count,
            completedChunks: progress?.completedChunks.count ?? 0
        )
    }
}



struct NovelAutomaticStateSyncTarget: Equatable, Hashable, Sendable {
    let projectID: NovelProjectID
    let branchID: NovelBranchID
}

struct NovelAutomaticStateSyncFailure: Equatable, Sendable {
    let target: NovelAutomaticStateSyncTarget
    let message: String
}

extension NovelCreationViewModel {
    func syncManualEdits() async {
        guard let project = projectSnapshot,
              let branch = branchSnapshot,
              branch.branch.syncStatus == .needsSync else { return }
        _ = await perform(.syncManualEdits(NovelSyncManualEditsCommand(
            context: mutationContext(
                projectRevision: project.project.revision,
                configRevision: project.project.configRevision,
                branchHeadRevision: branch.branch.headRevision
            ),
            projectID: project.project.id,
            branchID: branch.branch.id,
            pendingID: NovelPendingOperationID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            expectedWorkingRevision: branch.branch.workingRevision
        )))
    }

    func scheduleAutomaticStateSyncIfNeeded() {
        guard let project = projectSnapshot,
              let branch = branchSnapshot,
              branch.branch.syncStatus == .needsSync else { return }
        let branchPending = project.pendingOperations.filter {
            $0.branchID == branch.branch.id
        }
        let resumableManualSync = branchPending.count == 1 &&
            branchPending[0].kind == .manualSync &&
            (branchPending[0].status == .pending || branchPending[0].status == .retryable)
        guard branchPending.isEmpty || resumableManualSync else { return }
        scheduleAutomaticStateSync(
            projectID: project.project.id,
            branchID: branch.branch.id
        )
    }

    /// Await the branch's state alignment. The driver uses a deterministic
    /// relink only when no chapter version changed; otherwise it resumes the
    /// durable model rebuild.
    func finishPlotRelinkIfNeeded() async {
        guard let project = projectSnapshot,
              let branch = branchSnapshot else { return }
        let branchPending = project.pendingOperations.filter {
            $0.branchID == branch.branch.id
        }
        let resumableManualSync = branchPending.count == 1 &&
            branchPending[0].kind == .manualSync &&
            (branchPending[0].status == .pending || branchPending[0].status == .retryable)
        guard branchPending.isEmpty || resumableManualSync else { return }
        guard branch.branch.syncStatus == .needsSync else { return }
        let target = NovelAutomaticStateSyncTarget(
            projectID: project.project.id,
            branchID: branch.branch.id
        )
        // This is reached from an explicit collect action. If the user stopped
        // an earlier automatic attempt, collecting authorizes this bounded relink.
        userSuppressedStateSyncTargets.remove(target)
        if let task = automaticStateSyncTask {
            if automaticStateSyncTarget != target {
                queuedAutomaticStateSyncTarget = target
            }
            await task.value
        }
        if automaticStateSyncTask == nil {
            automaticStateSyncTarget = nil
            startAutomaticStateSync(target)
        }
        if let task = automaticStateSyncTask, automaticStateSyncTarget == target {
            await task.value
        }
    }

    func scheduleAutomaticStateSync(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) {
        let target = NovelAutomaticStateSyncTarget(
            projectID: projectID,
            branchID: branchID
        )
        let ghostwriteLeaseID = novelGhostwriteBackgroundLeaseID(
            projectID: projectID,
            branchID: branchID
        )
        guard UIApplication.shared.applicationState != .background ||
                BackgroundGenerationKeepAlive.shared.holdsLease(ghostwriteLeaseID) else {
            return
        }
        guard !userSuppressedStateSyncTargets.contains(target) else { return }
        guard target != automaticStateSyncTarget,
              target != queuedAutomaticStateSyncTarget else { return }
        guard automaticStateSyncTask == nil else {
            queuedAutomaticStateSyncTarget = target
            return
        }
        // Recovery only: books still on `.needsSync` without a plot module
        // (import missing plot/, or a pre-relink edit). Collect / save /
        // ghostwrite auto-collect must not call this — they commit plot in
        // the same checkpoint. Load-path recovery uses
        // `scheduleAutomaticStateSyncIfNeeded` → per-chapter relink.
        startAutomaticStateSync(target)
    }

    func retryPending(_ pendingID: NovelPendingOperationID) async {
        if projectSnapshot?.pendingOperations.contains(where: {
            $0.id == pendingID && $0.kind == .manualSync
        }) == true {
            if let task = startManualStateSyncRetry(pendingID) {
                await task.value
            }
            return
        }
        guard let project = projectSnapshot else { return }
        _ = await perform(.retryPending(NovelRetryPendingCommand(
            context: mutationContext(projectRevision: project.project.revision),
            projectID: project.project.id,
            pendingID: pendingID
        )))
    }

    @discardableResult
    func startManualStateSyncRetry(
        _ pendingID: NovelPendingOperationID
    ) -> Task<Void, Never>? {
        if manualStateSyncPendingID == pendingID {
            return manualStateSyncTask
        }
        guard manualStateSyncTask == nil,
              automaticStateSyncTask == nil,
              let project = projectSnapshot,
              let pending = project.pendingOperations.first(where: {
                  $0.id == pendingID &&
                      $0.kind == .manualSync &&
                      $0.status == .retryable
              }),
              reloadNoticeProjectID != project.project.id else { return nil }
        let target = NovelAutomaticStateSyncTarget(
            projectID: project.project.id,
            branchID: pending.branchID
        )
        let ownerID = UUID()
        guard acquireOperation(ownerID: ownerID) else { return nil }

        // Explicit retry after a user Stop should lift suppress for this target.
        userSuppressedStateSyncTargets.remove(target)
        if automaticStateSyncFailure?.target == target {
            automaticStateSyncFailure = nil
            errorMessage = nil
        }
        manualStateSyncPendingID = pendingID
        manualStateSyncTarget = target
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.manualStateSyncPendingID == pendingID {
                    self.manualStateSyncTask = nil
                    self.manualStateSyncPendingID = nil
                    self.manualStateSyncTarget = nil
                }
                self.stateSyncStoppingTargets.remove(target)
            }
            if Task.isCancelled {
                self.releaseOperation(ownerID: ownerID)
            } else {
                _ = await self.perform(
                    .retryPending(NovelRetryPendingCommand(
                        context: self.mutationContext(
                            projectRevision: project.project.revision
                        ),
                        projectID: project.project.id,
                        pendingID: pendingID
                    )),
                    reportsError: false,
                    reservedOwnerID: ownerID
                )
            }
        }
        manualStateSyncTask = task
        return task
    }

    func stateSyncContext(
        for action: NovelAction
    ) -> (
        branchID: NovelBranchID,
        pendingID: NovelPendingOperationID,
        attemptOperationID: NovelOperationID
    )? {
        switch action {
        case .syncManualEdits(let command):
            return (command.branchID, command.pendingID, command.context.operationID)
        case .retryPending(let command):
            guard let pending = projectSnapshot?.pendingOperations.first(where: {
                $0.id == command.pendingID && $0.kind == .manualSync
            }) else { return nil }
            return (pending.branchID, command.pendingID, command.context.operationID)
        default:
            return nil
        }
    }

    func startStateSyncActivity(
        ownerID: UUID,
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        pendingID: NovelPendingOperationID,
        attemptOperationID: NovelOperationID
    ) {
        let sameTarget = stateSyncActivity?.projectID == projectID &&
            stateSyncActivity?.branchID == branchID
        let startedAt = sameTarget ? (stateSyncActivity?.startedAt ?? Date()) : Date()
        stateSyncActivityOwnerID = ownerID
        if !(sameTarget && stateSyncActivity?.phase == .analyzing) {
            stateSyncActivity = .preparing(
                projectID: projectID,
                branchID: branchID,
                pendingID: pendingID,
                startedAt: startedAt
            )
        }
        beginStateSyncBackgroundLease(
            ownerID: ownerID,
            projectID: projectID,
            branchID: branchID
        )
        stateSyncActivityTask?.cancel()
        stateSyncActivityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.stateSyncActivityOwnerID == ownerID {
                if let snapshot = try? await self.project(id: projectID),
                   let pending = snapshot.pendingOperations.first(where: { $0.id == pendingID }),
                   let activity = NovelStateSyncActivity.project(
                       projectID: projectID,
                       branchID: branchID,
                       pending: pending,
                       snapshot: snapshot,
                       attemptOperationID: attemptOperationID,
                       startedAt: startedAt
                   ), self.stateSyncActivityOwnerID == ownerID {
                    let streamedCharacters = NovelStateSyncStreamProgress.shared.count(
                        pendingID: pendingID
                    )
                    if self.stateSyncActivity != activity {
                        self.stateSyncActivity = activity
                    }
                    self.updateStateSyncBackgroundProgress(
                        ownerID: ownerID,
                        activity: activity,
                        streamedCharacters: streamedCharacters
                    )
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopStateSyncActivity(ownerID: UUID) {
        guard stateSyncActivityOwnerID == ownerID else { return }
        BackgroundGenerationKeepAlive.shared.end(
            novelStateSyncBackgroundLeaseID(for: ownerID)
        )
        stateSyncReportedWorkByOwnerID.removeValue(forKey: ownerID)
        stateSyncActivityTask?.cancel()
        stateSyncActivityTask = nil
        stateSyncActivityOwnerID = nil
        let keepVisible = automaticStateSyncKeepAlive &&
            stateSyncActivity.map { activity in
                automaticStateSyncPresentationTarget == NovelAutomaticStateSyncTarget(
                    projectID: activity.projectID,
                    branchID: activity.branchID
                )
            } == true
        if !keepVisible {
            stateSyncActivity = nil
        }
    }

    private func beginStateSyncBackgroundLease(
        ownerID: UUID,
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) {
        stateSyncReportedWorkByOwnerID[ownerID] = 0
        let ghostwriteLeaseID = novelGhostwriteBackgroundLeaseID(
            projectID: projectID,
            branchID: branchID
        )
        if BackgroundGenerationKeepAlive.shared.holdsLease(ghostwriteLeaseID) {
            BackgroundGenerationKeepAlive.shared.advanceProgress(
                ghostwriteLeaseID,
                by: 1,
                subtitle: IOSAppLocalization.string(
                    "代笔中 · 剧情同步",
                    defaultValue: "代笔中 · 剧情同步"
                )
            )
            return
        }

        let leaseID = novelStateSyncBackgroundLeaseID(for: ownerID)
        let expire: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.expireStateSyncBackgroundLease(
                    ownerID: ownerID,
                    projectID: projectID
                )
            }
        }
        BackgroundGenerationKeepAlive.shared.begin(
            leaseID,
            title: IOSAppLocalization.string(
                "Amber 小说创作中",
                defaultValue: "Amber 小说创作中"
            ),
            subtitle: IOSAppLocalization.string("剧情同步", defaultValue: "剧情同步"),
            onExpire: expire,
            onSystemTaskExpiration: expire
        )
        BackgroundGenerationKeepAlive.shared.updateProgress(
            leaseID,
            completed: 0,
            total: -1,
            subtitle: IOSAppLocalization.string("剧情同步", defaultValue: "剧情同步")
        )
    }

    private func updateStateSyncBackgroundProgress(
        ownerID: UUID,
        activity: NovelStateSyncActivity,
        streamedCharacters: Int
    ) {
        let reportedWork = Int64(
            max(0, activity.completedCharacters) + max(0, streamedCharacters)
        )
        let previousWork = stateSyncReportedWorkByOwnerID[ownerID] ?? 0
        let currentWork = max(previousWork, reportedWork)
        stateSyncReportedWorkByOwnerID[ownerID] = currentWork

        let leaseID = novelStateSyncBackgroundLeaseID(for: ownerID)
        if BackgroundGenerationKeepAlive.shared.holdsLease(leaseID) {
            BackgroundGenerationKeepAlive.shared.updateProgress(
                leaseID,
                completed: currentWork,
                subtitle: activity.statusTitle
            )
        }

        let ghostwriteLeaseID = novelGhostwriteBackgroundLeaseID(
            projectID: activity.projectID,
            branchID: activity.branchID
        )
        if BackgroundGenerationKeepAlive.shared.holdsLease(ghostwriteLeaseID) {
            BackgroundGenerationKeepAlive.shared.advanceProgress(
                ghostwriteLeaseID,
                by: currentWork - previousWork,
                subtitle: IOSAppLocalization.string(
                    "代笔中 · 剧情同步",
                    defaultValue: "代笔中 · 剧情同步"
                )
            )
        }
    }

    private func expireStateSyncBackgroundLease(
        ownerID: UUID,
        projectID: NovelProjectID
    ) async {
        guard stateSyncActivityOwnerID == ownerID else { return }
        stateSyncReportedWorkByOwnerID.removeValue(forKey: ownerID)
        queuedAutomaticStateSyncTarget = nil
        manualStateSyncTask?.cancel()
        automaticStateSyncTask?.cancel()
        await creation.cancelInFlightBackgroundMutations(projectID: projectID)
    }

    func startAutomaticStateSync(_ target: NovelAutomaticStateSyncTarget) {
        guard automaticStateSyncTask == nil else {
            queuedAutomaticStateSyncTarget = target
            return
        }
        guard !userSuppressedStateSyncTargets.contains(target) else { return }
        if let failure = automaticStateSyncFailure, failure.target == target {
            if errorMessage == failure.message {
                errorMessage = nil
            }
            automaticStateSyncFailure = nil
        }
        automaticStateSyncTarget = target
        automaticStateSyncPresentationTarget = target
        automaticStateSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let wasCancelled: Bool
            if Task.isCancelled || self.userSuppressedStateSyncTargets.contains(target) {
                wasCancelled = true
            } else {
                await self.runAutomaticStateSync(target)
                wasCancelled = Task.isCancelled ||
                    self.userSuppressedStateSyncTargets.contains(target)
            }
            if self.automaticStateSyncTarget == target {
                self.automaticStateSyncTarget = nil
            }
            if self.automaticStateSyncPresentationTarget == target {
                self.automaticStateSyncPresentationTarget = nil
            }
            if self.stateSyncActivityOwnerID == nil {
                self.stateSyncActivity = nil
            }
            self.automaticStateSyncTask = nil
            self.stateSyncStoppingTargets.remove(target)
            if wasCancelled {
                // Drop only the cancelled target from the queue; still start a
                // different queued branch so stop on A does not strand B.
                if self.queuedAutomaticStateSyncTarget == target {
                    self.queuedAutomaticStateSyncTarget = nil
                }
                if let queued = self.queuedAutomaticStateSyncTarget {
                    self.queuedAutomaticStateSyncTarget = nil
                    self.startAutomaticStateSync(queued)
                }
                return
            }
            if let queued = self.queuedAutomaticStateSyncTarget {
                self.queuedAutomaticStateSyncTarget = nil
                self.startAutomaticStateSync(queued)
            }
        }
    }

    private func runAutomaticStateSync(_ target: NovelAutomaticStateSyncTarget) async {
        automaticStateSyncKeepAlive = true
        defer { automaticStateSyncKeepAlive = false }
        // Let the saving caller finish its immediate refresh before the background
        // transaction begins reading the same branch.
        try? await Task.sleep(for: .milliseconds(250))
        var healAttempts = 0
        while !Task.isCancelled, !userSuppressedStateSyncTargets.contains(target) {
            let projectSnapshot: NovelProjectSnapshot
            let branchSnapshot: NovelBranchSnapshot
            do {
                projectSnapshot = try await project(id: target.projectID)
                branchSnapshot = try await branch(
                    projectID: target.projectID,
                    branchID: target.branchID
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      !userSuppressedStateSyncTargets.contains(target) else { return }
                healAttempts += 1
                if healAttempts < NovelGhostwriteHeal.defaultMaxInfraRetries {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                // Banner only — do not set errorMessage (that triggers the global
                // "无法完成操作" alert and makes Retry look like an instant failure popup).
                publishAutomaticStateSyncFailure(
                    target: target,
                    message: NovelPresentation.stateSyncFailureMessage(for: error)
                )
                return
            }
            if selectedProjectID == target.projectID,
               selectedBranchID == target.branchID {
                self.projectSnapshot = projectSnapshot
                self.refreshCheckoutSidecarFailure(for: target.projectID)
                self.branchSnapshot = branchSnapshot
            }
            guard branchSnapshot.branch.syncStatus == .needsSync else {
                userSuppressedStateSyncTargets.remove(target)
                return
            }
            let branchPending = projectSnapshot.pendingOperations.filter {
                $0.branchID == target.branchID
            }
            let resumableManualSync = branchPending.count == 1 &&
                branchPending[0].kind == .manualSync &&
                (branchPending[0].status == .pending || branchPending[0].status == .retryable)
            guard branchPending.isEmpty || resumableManualSync else {
                // Previously returned silently — retry looked broken with no new banner.
                let message: String
                if branchPending.contains(where: { $0.kind != .manualSync }) {
                    message = "当前还有未完成的正文操作，请先处理后再重试剧情同步。"
                } else if branchPending.count > 1 {
                    message = "当前有多个未完成的同步任务，请重新打开项目后再试。"
                } else {
                    message = "剧情同步任务状态异常，请重新打开项目后再试。"
                }
                publishAutomaticStateSyncFailure(target: target, message: message)
                return
            }
            if isPerforming || branchSnapshot.branch.activeRunID != nil {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            guard !Task.isCancelled,
                  !userSuppressedStateSyncTargets.contains(target) else { return }

            if branchPending.isEmpty,
               NovelWorkspaceLedger.canRelinkWithoutModel(
                   branch: branchSnapshot.branch,
                   checkpoints: projectSnapshot.checkpoints
               ) {
                do {
                    try await creation.applyWorkspacePlotRelink(
                        projectID: target.projectID,
                        branchID: target.branchID
                    )
                    if automaticStateSyncFailure?.target == target {
                        automaticStateSyncFailure = nil
                    }
                    continue
                } catch is CancellationError {
                    return
                } catch {
                    healAttempts += 1
                    if healAttempts < NovelGhostwriteHeal.defaultMaxInfraRetries {
                        try? await Task.sleep(for: .milliseconds(200))
                        continue
                    }
                    publishAutomaticStateSyncFailure(
                        target: target,
                        message: NovelPresentation.stateSyncFailureMessage(
                            "每章的剧情记录没能补齐。\(error.localizedDescription)"
                        )
                    )
                    return
                }
            }

            let ghostwriteLeaseID = novelGhostwriteBackgroundLeaseID(
                projectID: target.projectID,
                branchID: target.branchID
            )
            guard UIApplication.shared.applicationState != .background ||
                    BackgroundGenerationKeepAlive.shared.holdsLease(ghostwriteLeaseID) else {
                return
            }

            lastStateSyncOperationError = nil
            lastStateSyncOperationCause = nil
            let succeeded: Bool
            if let pending = branchPending.first {
                succeeded = await perform(.retryPending(NovelRetryPendingCommand(
                    context: mutationContext(
                        projectRevision: projectSnapshot.project.revision
                    ),
                    projectID: target.projectID,
                    pendingID: pending.id
                )), reportsError: false)
            } else {
                succeeded = await perform(.syncManualEdits(NovelSyncManualEditsCommand(
                    context: mutationContext(
                        projectRevision: projectSnapshot.project.revision,
                        configRevision: projectSnapshot.project.configRevision,
                        branchHeadRevision: branchSnapshot.branch.headRevision
                    ),
                    projectID: target.projectID,
                    branchID: target.branchID,
                    pendingID: NovelPendingOperationID(),
                    checkpointID: NovelCheckpointID(),
                    stateSnapshotID: NovelStateSnapshotID(),
                    expectedWorkingRevision: branchSnapshot.branch.workingRevision
                )), reportsError: false)
            }
            // Success after a concurrent Stop still means the branch is synced —
            // lift suppress so the next edit can auto-schedule again.
            if succeeded {
                userSuppressedStateSyncTargets.remove(target)
                lastStateSyncOperationCause = nil
                lastStateSyncOperationError = nil
                return
            }
            if Task.isCancelled || userSuppressedStateSyncTargets.contains(target) {
                return
            }
            if let failure = lastStateSyncOperationCause as? NovelStructuredModelExecutionFailure,
               failure.allowsOutputRepair {
                let pending = self.projectSnapshot?.pendingOperations.first(where: {
                    $0.branchID == target.branchID && $0.kind == .manualSync
                })
                let completedChunks = pending?.manualSyncProgress?.completedChunks.count ?? 0
                let raw = pending?.lastError
                    ?? lastStateSyncOperationError
                    ?? failure.failure.message
                publishAutomaticStateSyncFailure(
                    target: target,
                    message: NovelPresentation.stateSyncFailureMessage(
                        raw,
                        completedChunkCount: completedChunks
                    )
                )
                return
            }
            healAttempts += 1
            if healAttempts < NovelGhostwriteHeal.defaultMaxInfraRetries {
                // Same pending, next attempt sees lastError in the current chunk.
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            let pending = self.projectSnapshot?.pendingOperations.first(where: {
                $0.branchID == target.branchID && $0.kind == .manualSync
            })
            let completedChunks = pending?.manualSyncProgress?.completedChunks.count ?? 0
            let raw = pending?.lastError
                ?? lastStateSyncOperationError
                ?? "剧情同步没有完成，请点重试。大项目可能较久，请保持前台。"
            // If durable chunks exist, say so — retry continues from next segment,
            // it does not re-feed already completed manuscript.
            let message = NovelPresentation.stateSyncFailureMessage(
                raw,
                completedChunkCount: completedChunks
            )
            publishAutomaticStateSyncFailure(target: target, message: message)
            return
        }
    }

    /// Recoverable auto-sync failures stay on the status banner. Writing
    /// `errorMessage` would also fire `NovelCreationErrorAlertModifier`
    /// ("无法完成操作") on the workspace — the "retry instantly pops a dialog"
    /// bug users hit on the 正文 tab.
    func publishAutomaticStateSyncFailure(
        target: NovelAutomaticStateSyncTarget,
        message: String
    ) {
        automaticStateSyncFailure = NovelAutomaticStateSyncFailure(
            target: target,
            message: message
        )
        // If a previous unrelated error left a modal up with the same text, clear
        // it so only the banner remains as the recovery surface.
        if errorMessage == message {
            errorMessage = nil
        }
    }

}
