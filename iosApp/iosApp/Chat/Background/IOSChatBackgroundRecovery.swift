@preconcurrency import BackgroundTasks
import Foundation
import OSLog
import UIKit
@preconcurrency import Shared

@MainActor
extension IOSChatBackgroundGenerationCoordinator {
    /// 冷启动时收口 App Switcher 强杀留下的后台 request。
    ///
    /// `BGContinuedProcessingTask` 被用户上划关闭时，系统不会调用应用的
    /// expiration handler；因此 payload 和 task map 会停在“running”。这个入口
    /// 只清理没有正在执行 handler 的持久化 request，不重新提交模型请求。调用方
    /// 应在普通 UI 冷启动完成后调用；实际已被系统唤起的 handler 会先登记到
    /// `activeBackgroundTasks`，从而保留给 `handle` 继续处理。重复调用是幂等的。
    func finalizeStalePersistedJobsIfNeeded(
        preservingOutcomeUnknownRunIds: Set<String> = []
    ) {
        let persisted = taskMap()
        guard !persisted.isEmpty else { return }

        IOSBackgroundLifecycleLog.record(
            "staleBackgroundSweep(pending=\(persisted.count))",
            detail: lifecycleSnapshotDetail
        )
        for (requestId, mappedRunId) in persisted {
            guard activeBackgroundTasks[requestId] == nil else {
                continue
            }
            if activeDetachedResponseTasks[requestId] != nil {
                continue
            }
            if backgroundInterruptedRequestIds.contains(requestId)
                || foregroundResumeInFlightRequestIds.contains(requestId)
                || automaticallyResumedRequestIds.contains(requestId) {
                continue
            }
            if let durableJob = job(for: requestId),
               durableJob.mode == .resumeResponse,
               durableJob.responseId != nil {
                continue
            }

            guard !staleSweepInFlightRequestIds.contains(requestId) else {
                continue
            }
            staleSweepInFlightRequestIds.insert(requestId)
            Task { @MainActor in
                defer { self.staleSweepInFlightRequestIds.remove(requestId) }
                await self.finalizeStalePersistedJob(
                    requestId: requestId,
                    mappedRunId: mappedRunId,
                    preservingOutcomeUnknownRunIds: preservingOutcomeUnknownRunIds
                )
            }
        }
    }

    private func finalizeStalePersistedJob(
        requestId: String,
        mappedRunId: String,
        preservingOutcomeUnknownRunIds: Set<String>
    ) async {
        guard activeBackgroundTasks[requestId] == nil,
              activeDetachedResponseTasks[requestId] == nil else {
            return
        }
        if let durableJob = activeJobs[requestId],
           durableJob.mode == .resumeResponse,
           durableJob.responseId != nil {
            return
        }

        let durableRun: IOSDurableRunStore.Snapshot?
        do {
            durableRun = try await runStore.snapshot(runId: mappedRunId)
        } catch {
            guard activeBackgroundTasks[requestId] == nil,
                  activeDetachedResponseTasks[requestId] == nil,
                  !backgroundInterruptedRequestIds.contains(requestId),
                  !foregroundResumeInFlightRequestIds.contains(requestId),
                  !automaticallyResumedRequestIds.contains(requestId) else { return }
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestId)
            releaseRuntimeOwnership(requestId: requestId)
            return
        }
        let hasPreservedOutcomeUnknown = preservingOutcomeUnknownRunIds.contains(mappedRunId)
        let hasOutcomeUnknownEvidence: Bool?
        if hasPreservedOutcomeUnknown {
            hasOutcomeUnknownEvidence = true
        } else {
            hasOutcomeUnknownEvidence = await hasOutcomeUnknownRecoveryEvidence(run: durableRun)
        }
        guard activeBackgroundTasks[requestId] == nil,
              activeDetachedResponseTasks[requestId] == nil,
              !backgroundInterruptedRequestIds.contains(requestId),
              !foregroundResumeInFlightRequestIds.contains(requestId),
              !automaticallyResumedRequestIds.contains(requestId) else {
            return
        }
        guard let hasOutcomeUnknownEvidence else {
            // 无法读取 durable evidence 时撤掉失效系统 request，但保留
            // task-map/payload，等待下一次冷启动重试，不能合成普通失败。
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestId)
            releaseRuntimeOwnership(requestId: requestId)
            return
        }
        if hasOutcomeUnknownEvidence {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestId)
            // 保留 durable run/ledger 给下一轮冷启动对账，只摘除已失效的
            // request owner，避免把不确定副作用改写成普通失败或再次重放。
            finish(runId: mappedRunId, requestId: requestId)
            return
        }
        if let durableRun, durableRun.status.isTerminal, durableRun.finishedAt != nil {
            // Startup recovery may already have persisted an interrupted terminal.
            // Its old checkpoint must not append another failure or replace that terminal.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestId)
            await IOSPhoneControlController.shared.stop(runID: mappedRunId)
            let controller = dependencies?.liveActivityController ?? .shared
            _ = controller.adoptExistingActivity(runId: mappedRunId)
            let presentation: AgentActivityPresentation
            switch durableRun.status {
            case .completed: presentation = .completed()
            case .cancelled: presentation = .cancelled()
            default: presentation = .failed()
            }
            await controller.end(runId: mappedRunId, presentation: presentation)
            IOSBackgroundLifecycleLog.record(
                "staleBackgroundTerminalPreserved",
                detail: "run=\(mappedRunId) status=\(durableRun.status.wireName)"
            )
            finish(runId: mappedRunId, requestId: requestId)
            return
        }
        // `.queue`/遗留 request 不会因应用被杀而自行消失；先撤掉它，防止
        // 扫尾后系统又唤起一张已经被标记停止的后台卡。
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestId)

        guard let job = job(for: requestId) else {
            // 当前无法水合 payload 时先尝试收口 agent_run；只有 durable
            // 终态成功后才删除 map。CAS/存储失败保留它供下次冷启动重试。
            let controller = dependencies?.liveActivityController ?? .shared
            _ = controller.adoptExistingActivity(runId: mappedRunId)
            guard await markRunInterrupted(
                runId: mappedRunId,
                reason: "app_terminated"
            ) else {
                releaseRuntimeOwnership(requestId: requestId)
                return
            }
            await controller.end(runId: mappedRunId, presentation: .failed())
            finish(requestId: requestId)
            return
        }

        // 没有可重放的 cursor；把 handoff 快照收口为一次明确的可重试
        // 失败；durable 终态成功后才摘除 request owner。
        _ = await persistExpirationFailure(
            job: job,
            requestId: requestId,
            rawMessage: IOSAppLocalization.string(
                "后台生成已停止，可以重试。",
                defaultValue: "后台生成已停止，可以重试。"
            ),
            partialAssistantText: nil
        )
    }

    private func hasOutcomeUnknownRecoveryEvidence(run snapshot: IOSDurableRunStore.Snapshot?) async -> Bool? {
        guard let snapshot else {
            return false
        }
        let runStatus = snapshot.status
        if runStatus == .outcomeUnknown {
            return true
        }
        guard runStatus == .running || runStatus == .recoveryPending else {
            return false
        }
        guard let transactionStates = await toolLedger.toolTransactions(runId: snapshot.runId)?.map(\.state) else {
            return nil
        }
        return Self.preservesOutcomeUnknownStaleRecovery(
            runStatus: runStatus,
            transactionStates: transactionStates
        )
    }

    static func preservesOutcomeUnknownStaleRecovery(
        runStatus: AgentRunStatus?,
        transactionStates: [IOSToolTransactionState]?
    ) -> Bool {
        if runStatus == .outcomeUnknown {
            return true
        }
        guard runStatus == .running || runStatus == .recoveryPending else {
            return false
        }
        // nil means the ledger lookup failed; fail closed so a possible
        // side-effect attempt is not rewritten as an ordinary stale failure.
        guard let transactionStates else { return true }
        return transactionStates.contains(.outcomeUnknown)
    }

    func resumeRecoverableJob(
        job: IOSChatBackgroundRuntimeJob,
        requestId: String
    ) async {
        guard backgroundInterruptedRequestIds.contains(requestId),
              activeJobs[requestId]?.runId == job.runId,
              let expiredRunState = activeRunStates[requestId] else {
            return
        }
        await expiredRunState.waitForExpiredOperationExit()
        await IOSPhoneControlController.shared.stop(runID: job.runId)
        guard backgroundInterruptedRequestIds.contains(requestId),
              activeJobs[requestId]?.runId == job.runId else {
            return
        }

        if job.mode != .continueModel {
            guard Self.canAutomaticallyResumeOrdinaryJob(
                mode: job.mode,
                hasDeclaredTools: false
            ) else {
                // Reconcile the current transaction ledger and legacy tool events
                // before converting this to an explicit retry. A started side
                // effect must remain outcome-unknown, never ordinary failed.
                guard await reconcileDetachedResponseLedgerBeforeResume(
                    job: job,
                    requestId: requestId
                ) else {
                    return
                }
                guard backgroundInterruptedRequestIds.contains(requestId),
                      activeJobs[requestId]?.runId == job.runId else {
                    return
                }
                _ = await persistExpirationFailure(
                    job: job,
                    requestId: requestId,
                    rawMessage: IOSAppLocalization.string(
                        "后台任务包含不能安全自动重放的操作，请回到会话重试。",
                        defaultValue: "后台任务包含不能安全自动重放的操作，请回到会话重试。"
                    ),
                    partialAssistantText: nil
                )
                return
            }
        }

        let resumableJob: IOSChatBackgroundRuntimeJob
        if job.mode == .continueModel {
            guard let prepared = await prepareOrdinaryJobForResume(
                job: job,
                requestId: requestId
            ) else {
                return
            }
            resumableJob = prepared
        } else {
            resumableJob = job
        }

        guard UIApplication.shared.applicationState == .active else { return }
        do {
            guard let snapshot = try await runStore.snapshot(runId: job.runId),
                  snapshot.status == .recoveryPending else {
                return
            }
        } catch {
            return
        }
        guard backgroundInterruptedRequestIds.contains(requestId),
              activeJobs[requestId]?.runId == job.runId,
              UIApplication.shared.applicationState == .active else {
            return
        }
        do {
            guard try await runStore.transition(
                runId: job.runId,
                expected: .recoveryPending,
                to: .running
            ) else {
                return
            }
        } catch {
            return
        }
        guard backgroundInterruptedRequestIds.contains(requestId),
              foregroundResumeInFlightRequestIds.contains(requestId),
              activeJobs[requestId]?.runId == job.runId else {
            return
        }

        backgroundInterruptedRequestIds.remove(requestId)
        activeRunStates.removeValue(forKey: requestId)

        automaticallyResumedRequestIds.insert(requestId)
        startLocalExecution(
            requestId: requestId,
            subtitle: resumableJob.params.model.displayName
        )
        publishStateEvent(for: resumableJob)
        IOSBackgroundLifecycleLog.record(
            "bgTaskAutoResubmitted(run=\(resumableJob.runId.prefix(8)))",
            detail: lifecycleSnapshotDetail
        )
    }

    static func canAutomaticallyResumeOrdinaryJob(
        mode: IOSChatBackgroundHandoffMode,
        hasDeclaredTools _: Bool
    ) -> Bool {
        // Tool declarations describe the available surface, not an execution
        // boundary. The ledger gate below decides whether this particular run
        // has a side effect that cannot be replayed safely.
        mode == .continueModel
    }

}
