import Foundation
import Observation
import UIKit

struct NovelContinuityAuditFailure: Equatable, Sendable {
    let target: NovelAutomaticStateSyncTarget
    let message: String
}

extension NovelCreationViewModel {
    /// 发起前的预估:扫几章、切几块。块数就是这次要发多少个模型请求,给用户一个
    /// 「这一趟要花多少」的交代。不消耗模型调用。
    func planContinuityAudit() async -> NovelContinuityAuditPlan? {
        guard let projectID = selectedProjectID, let branchID = selectedBranchID else {
            return nil
        }
        let target = NovelAutomaticStateSyncTarget(projectID: projectID, branchID: branchID)
        guard !Task.isCancelled else { return nil }
        let ownerID = UUID()
        guard acquireOperation(ownerID: ownerID) else {
            // 抢不到锁不能静默返回:用户看到的就是「点了没反应」。
            continuityAuditFailureStorage = NovelContinuityAuditFailure(
                target: target,
                message: "有别的操作正在进行，请稍后再试。"
            )
            return nil
        }
        defer { releaseOperation(ownerID: ownerID) }
        do {
            try Task.checkCancellation()
            let plan = try await creation.planContinuityAudit(
                projectID: projectID,
                branchID: branchID
            )
            try Task.checkCancellation()
            continuityAuditPlanStorage = plan
            if continuityAuditFailureStorage?.target == target {
                continuityAuditFailureStorage = nil
            }
            errorMessage = nil
            return plan
        } catch is CancellationError {
            if continuityAuditFailureStorage?.target == target {
                continuityAuditFailureStorage = nil
            }
            return nil
        } catch {
            continuityAuditFailureStorage = NovelContinuityAuditFailure(
                target: target,
                message: errorDescription(error)
            )
            return nil
        }
    }

    func startContinuityAuditPlanning() {
        guard continuityAuditTask == nil else { return }
        continuityAuditPlanStorage = nil
        isPlanningContinuity = true
        continuityAuditTask = Task { @MainActor [weak self] in
            _ = await self?.planContinuityAudit()
            self?.isPlanningContinuity = false
            self?.continuityAuditTask = nil
        }
    }

    /// 界面用这个入口发起扫描:任务句柄留在 ViewModel 里,「停止扫描」才有东西可取消。
    func startContinuityAudit() {
        guard continuityAuditTask == nil else { return }
        continuityAuditPlanStorage = nil
        continuityAuditTask = Task { @MainActor [weak self] in
            await self?.auditContinuity()
            self?.continuityAuditTask = nil
        }
    }

    func startContinuityRepair(issueIDs: Set<String>? = nil) {
        guard continuityAuditTask == nil else { return }
        continuityAuditTask = Task { @MainActor [weak self] in
            await self?.repairContinuity(issueIDs: issueIDs)
            self?.continuityAuditTask = nil
        }
    }

    func cancelContinuityAudit() {
        continuityAuditTask?.cancel()
    }

    func auditContinuity() async {
        guard let projectID = selectedProjectID, let branchID = selectedBranchID else { return }
        let target = NovelAutomaticStateSyncTarget(projectID: projectID, branchID: branchID)
        let ownerID = UUID()
        guard acquireOperation(ownerID: ownerID) else {
            continuityAuditFailureStorage = NovelContinuityAuditFailure(
                target: target,
                message: "有别的操作正在进行，请稍后再试。"
            )
            return
        }
        isAuditingContinuity = true
        beginContinuityBackgroundLease(
            ownerID: ownerID,
            target: target
        )
        defer {
            isAuditingContinuity = false
            if continuityAuditExpirationOwnerID == ownerID {
                continuityAuditExpirationOwnerID = nil
            }
            BackgroundGenerationKeepAlive.shared.end(
                novelContinuityBackgroundLeaseID(for: ownerID)
            )
            releaseOperation(ownerID: ownerID)
        }
        do {
            let audit = try await creation.auditContinuity(
                projectID: projectID,
                branchID: branchID
            )
            try Task.checkCancellation()
            continuityAuditReport = audit
            continuityRepairReport = nil
            if continuityAuditFailureStorage?.target == target {
                continuityAuditFailureStorage = nil
            }
            errorMessage = nil
        } catch is CancellationError {
            if continuityAuditExpirationOwnerID == ownerID {
                continuityAuditFailureStorage = NovelContinuityAuditFailure(
                    target: target,
                    message: "后台执行时间已结束，请重新检查。"
                )
            } else if continuityAuditFailureStorage?.target == target {
                // 用户自己按的停止,不是故障,不必弹错误。
                continuityAuditFailureStorage = nil
            }
        } catch {
            if continuityAuditExpirationOwnerID == ownerID {
                continuityAuditFailureStorage = NovelContinuityAuditFailure(
                    target: target,
                    message: "后台执行时间已结束，请重新检查。"
                )
            } else if Task.isCancelled {
                if continuityAuditFailureStorage?.target == target {
                    continuityAuditFailureStorage = nil
                }
            } else {
                continuityAuditFailureStorage = NovelContinuityAuditFailure(
                    target: target,
                    message: errorDescription(error)
                )
            }
        }
    }

    func repairContinuity(issueIDs: Set<String>? = nil) async {
        guard let projectID = selectedProjectID,
              let branchID = selectedBranchID,
              let report = continuityAudit else { return }
        let target = NovelAutomaticStateSyncTarget(projectID: projectID, branchID: branchID)
        let ownerID = UUID()
        guard acquireOperation(ownerID: ownerID) else {
            continuityAuditFailureStorage = NovelContinuityAuditFailure(
                target: target,
                message: "有别的操作正在进行，请稍后再试。"
            )
            return
        }
        isRepairingContinuity = true
        beginContinuityBackgroundLease(
            ownerID: ownerID,
            target: target,
            subtitle: IOSAppLocalization.string(
                "剧情矛盾修复",
                defaultValue: "剧情矛盾修复"
            )
        )
        defer {
            isRepairingContinuity = false
            if continuityAuditExpirationOwnerID == ownerID {
                continuityAuditExpirationOwnerID = nil
            }
            BackgroundGenerationKeepAlive.shared.end(
                novelContinuityBackgroundLeaseID(for: ownerID)
            )
            releaseOperation(ownerID: ownerID)
        }
        do {
            let repair = try await creation.repairContinuity(
                projectID: projectID,
                branchID: branchID,
                report: report,
                issueIDs: issueIDs
            )
            try Task.checkCancellation()
            continuityRepairReport = repair
            if continuityAuditFailureStorage?.target == target {
                continuityAuditFailureStorage = nil
            }
            errorMessage = nil
            _ = try? await reloadSelection(projectID: projectID, branchID: branchID)
        } catch is CancellationError {
            _ = try? await reloadSelection(projectID: projectID, branchID: branchID)
            if continuityAuditExpirationOwnerID == ownerID {
                continuityAuditFailureStorage = NovelContinuityAuditFailure(
                    target: target,
                    message: "后台执行时间已结束，请重新检查。"
                )
            } else if continuityAuditFailureStorage?.target == target {
                continuityAuditFailureStorage = nil
            }
        } catch {
            _ = try? await reloadSelection(projectID: projectID, branchID: branchID)
            if continuityAuditExpirationOwnerID == ownerID {
                continuityAuditFailureStorage = NovelContinuityAuditFailure(
                    target: target,
                    message: "后台执行时间已结束，请重新检查。"
                )
            } else if Task.isCancelled {
                if continuityAuditFailureStorage?.target == target {
                    continuityAuditFailureStorage = nil
                }
            } else {
                continuityAuditFailureStorage = NovelContinuityAuditFailure(
                    target: target,
                    message: errorDescription(error)
                )
            }
        }
    }

    func clearContinuityAudit() {
        continuityAuditReport = nil
        continuityAuditPlanStorage = nil
        continuityAuditFailureStorage = nil
        continuityRepairReport = nil
    }

    func clearContinuityAuditPlan() {
        continuityAuditPlanStorage = nil
    }

    private func beginContinuityBackgroundLease(
        ownerID: UUID,
        target: NovelAutomaticStateSyncTarget,
        subtitle: String = IOSAppLocalization.string(
            "剧情矛盾检查",
            defaultValue: "剧情矛盾检查"
        )
    ) {
        let leaseID = novelContinuityBackgroundLeaseID(for: ownerID)
        let expire: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.operationOwnerID == ownerID,
                      self.isAuditingContinuity || self.isRepairingContinuity else { return }
                self.continuityAuditExpirationOwnerID = ownerID
                self.continuityAuditFailureStorage = NovelContinuityAuditFailure(
                    target: target,
                    message: "后台执行时间已结束，请重新检查。"
                )
                self.continuityAuditTask?.cancel()
            }
        }
        BackgroundGenerationKeepAlive.shared.begin(
            leaseID,
            title: IOSAppLocalization.string(
                "Amber 小说创作中",
                defaultValue: "Amber 小说创作中"
            ),
            subtitle: subtitle,
            onExpire: expire,
            onSystemTaskExpiration: expire
        )
    }

}
