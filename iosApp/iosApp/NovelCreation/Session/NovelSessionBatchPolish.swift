import Foundation

extension NovelSessionViewModel {
    // MARK: - 批量整章润色

    /// 发起批量整章润色:按 `chapterIDs` 顺序逐章「生成候选 → 采用(含漂移校验)」。
    /// 必须串行——一个项目同一时刻只能跑一个 run,且采用会推进分支 head 使其他已生成
    /// 候选作废,所以只能生成一章、采用一章、再下一章。通过漂移校验的章自动采用为新
    /// 版本;改了剧情的章自动跳过;失败章记录在案。任务句柄留在 ViewModel 上,关闭
    /// sheet 不中断,只有 `cancelBatchPolish()` 会停止。
    @discardableResult
    func startBatchPolish(chapterIDs: [NovelChapterID]) -> Bool {
        guard batchPolishTask == nil,
              let binding,
              !chapterIDs.isEmpty,
              canStartBatchPolish else {
            operationErrorMessage = batchPolishBlocker?.displayName
                ?? (chapterIDs.isEmpty ? "请至少选择一章。" : "批量润色暂时不能开始。")
            return false
        }
        operationErrorMessage = nil
        batchPolishProgressStorage = NovelBatchPolishProgress(
            binding: binding,
            total: chapterIDs.count,
            completed: 0,
            currentTitle: nil,
            phase: .running,
            results: [],
            startedAt: Date()
        )
        batchPolishTaskBinding = binding
        batchPolishCancellationReason = .user
        batchPolishTask = Task { @MainActor [weak self] in
            await self?.runBatchPolish(chapterIDs: chapterIDs, binding: binding)
            guard self?.batchPolishTaskBinding == binding else { return }
            self?.batchPolishTask = nil
            self?.batchPolishTaskBinding = nil
            self?.batchPolishOwnedRunID = nil
        }
        return true
    }

    func cancelBatchPolish() {
        guard batchPolishTask != nil else { return }
        batchPolishCancellationReason = .user
        batchPolishTask?.cancel()
    }

    func cancelBatchPolishForBindingChange(
        from expectedBinding: NovelSessionBinding?
    ) async {
        guard let expectedBinding else {
            batchPolishProgressStorage = nil
            return
        }
        if batchPolishTaskBinding == expectedBinding, let task = batchPolishTask {
            batchPolishCancellationReason = .routeExit
            task.cancel()
            await task.value
        }
        if batchPolishProgressStorage?.binding == expectedBinding {
            batchPolishProgressStorage = nil
        }
    }

    /// 报告态下「再润色一批」用:清空进度回到选择态。运行中不允许清。
    func clearBatchPolish() {
        guard batchPolishTask == nil,
              unresolvedBranchPolishTransactions.isEmpty else { return }
        batchPolishProgressStorage = nil
    }

    /// 报告态下「重试失败章节」:只重跑失败和未处理的章,跳过已成功和漂移跳过的。
    @discardableResult
    func retryFailedBatchPolish() -> Bool {
        guard batchPolishTask == nil,
              let progress = batchPolishProgress else { return false }
        let retryIDs = progress.results
            .filter { $0.outcome == .failed || $0.outcome == .cancelled }
            .map(\.chapterID)
        guard !retryIDs.isEmpty else { return false }
        return startBatchPolish(chapterIDs: retryIDs)
    }

    private func runBatchPolish(
        chapterIDs: [NovelChapterID],
        binding expectedBinding: NovelSessionBinding
    ) async {
        let expectedToken = bindingToken
        var results: [NovelBatchPolishChapterResult] = []
        do {
            for (index, chapterID) in chapterIDs.enumerated() {
                try Task.checkCancellation()
                // 章间主动让快照追上 durable:清掉上一章可能残留的 terminalAwaitingRefresh,
                // 保证本章 start 的 canStart 门禁不被卡。refreshDurable 幂等且不 rebind/detach。
                _ = await refreshDurable(binding: expectedBinding, token: expectedToken)
                try Task.checkCancellation()
                guard binding == expectedBinding,
                      bindingToken == expectedToken,
                      workspace.selectedProjectID == expectedBinding.projectID,
                      workspace.selectedBranchID == expectedBinding.branchID else {
                    throw CancellationError()
                }
                // 采用中间章会标记后续剧情记录过期。释放采用操作锁后，workspace
                // 会自动接受它们；等这项既有任务落定，再尝试下一章的正式生成。
                _ = await workspace.stalePlotAutoSyncTask?.value
                try Task.checkCancellation()
                guard binding == expectedBinding,
                      bindingToken == expectedToken,
                      workspace.selectedProjectID == expectedBinding.projectID,
                      workspace.selectedBranchID == expectedBinding.branchID else {
                    throw CancellationError()
                }
                let title = batchPolishTitle(for: chapterID, ordinal: index + 1)
                mutateBatchProgress(binding: expectedBinding) {
                    $0.completed = index
                    $0.currentTitle = title
                }
                let result = try await polishOneChapter(chapterID: chapterID, title: title)
                batchPolishOwnedRunID = nil
                results.append(result)
                try Task.checkCancellation()
                mutateBatchProgress(binding: expectedBinding) {
                    $0.completed = index + 1
                    $0.results = results
                }
                if !unresolvedBranchPolishTransactions.isEmpty {
                    results.append(contentsOf: unhandledBatchResults(
                        chapterIDs: chapterIDs,
                        handled: results,
                        outcome: .cancelled,
                        message: "前一章的润色检查需要先处理。"
                    ))
                    mutateBatchProgress(binding: expectedBinding) {
                        $0.completed = index + 1
                        $0.currentTitle = nil
                        $0.phase = .done
                        $0.results = results
                    }
                    return
                }
            }
            mutateBatchProgress(binding: expectedBinding) {
                $0.completed = chapterIDs.count
                $0.currentTitle = nil
                $0.phase = .done
                $0.results = results
            }
        } catch is CancellationError {
            await stopOwnedBatchPolishRun(
                binding: expectedBinding,
                reason: batchPolishCancellationReason
            )
            batchPolishOwnedRunID = nil
            // 用户按了停止:已采用的保留,未轮到的标 cancelled,不弹错误。
            results.append(contentsOf: unhandledBatchResults(
                chapterIDs: chapterIDs,
                handled: results,
                outcome: .cancelled,
                message: nil
            ))
            mutateBatchProgress(binding: expectedBinding) {
                $0.currentTitle = nil
                $0.phase = .cancelled
                $0.results = results
            }
        } catch {
            batchPolishOwnedRunID = nil
            // 意料外的错误:剩余章记 failed 收口,保留已完成的结果。
            results.append(contentsOf: unhandledBatchResults(
                chapterIDs: chapterIDs,
                handled: results,
                outcome: .failed,
                message: describe(error)
            ))
            mutateBatchProgress(binding: expectedBinding) {
                $0.currentTitle = nil
                $0.phase = .done
                $0.results = results
            }
        }
    }

    /// 单章「生成候选 → 采用」。只在被取消时抛 `CancellationError`,其余失败都作为结果
    /// 返回让批量继续(同连续性审计「一块失败不作废其余块」)。
    private func polishOneChapter(
        chapterID: NovelChapterID,
        title: String
    ) async throws -> NovelBatchPolishChapterResult {
        guard let source = currentChapterVersions.first(where: { $0.chapterID == chapterID }) else {
            return NovelBatchPolishChapterResult(
                chapterID: chapterID, title: title, outcome: .failed,
                message: "当前分支没有这一章。"
            )
        }
        let preexisting = Set(
            availablePolishCandidates
                .filter { $0.sourceChapterVersionID == source.id }
                .map(\.id)
        )
        isBatchStartingRun = true
        let started = await startWholeChapterPolish(chapterID: chapterID)
        batchPolishOwnedRunID = activeRunID
        isBatchStartingRun = false
        // 停止也可能落在 run 启动握手内；`start` 会把取消收口成 false，若这里不
        // 重新检查，当前章会被误报为普通启动失败。
        try Task.checkCancellation()
        guard started else {
#if DEBUG
            print("[BatchPolish] start failed \(chapterID): \(batchPolishDiagnostic())")
#endif
            return NovelBatchPolishChapterResult(
                chapterID: chapterID, title: title, outcome: .failed,
                message: errorMessage ?? "润色没有开始,请稍后重试。"
            )
        }
        let candidateID: NovelCandidateID?
        do {
            candidateID = try await awaitPolishCandidate(
                sourceVersionID: source.id,
                preexistingIDs: preexisting
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return NovelBatchPolishChapterResult(
                chapterID: chapterID, title: title, outcome: .failed,
                message: describe(error)
            )
        }
        guard let candidateID else {
#if DEBUG
            print("[BatchPolish] no candidate \(chapterID): \(batchPolishDiagnostic())")
#endif
            return NovelBatchPolishChapterResult(
                chapterID: chapterID, title: title, outcome: .failed,
                message: errorMessage ?? "润色没有产出候选。"
            )
        }
        await adoptPolishCandidate(candidateID)
        let transaction = branchPolishTransactions.first(where: {
            $0.candidateID == candidateID
        })
        if Task.isCancelled {
            switch transaction?.status {
            case .completed, .incompatible:
                break
            case .pending, .retryable, .blocked, .abandoned, nil:
                operationErrorMessage = nil
                throw CancellationError()
            }
        }
        if let transaction {
            switch transaction.status {
            case .completed:
                return NovelBatchPolishChapterResult(
                    chapterID: chapterID, title: title, outcome: .adopted
                )
            case .incompatible:
                return NovelBatchPolishChapterResult(
                    chapterID: chapterID, title: title, outcome: .skippedDrift,
                    message: "润色改动了剧情事实,已跳过本章。"
                )
            case .blocked, .retryable, .pending, .abandoned:
                return NovelBatchPolishChapterResult(
                    chapterID: chapterID, title: title, outcome: .failed,
                    message: transaction.lastFailure?.message ?? "润色没有完成。"
                )
            }
        }
        return NovelBatchPolishChapterResult(
            chapterID: chapterID, title: title, outcome: .failed,
            message: errorMessage ?? "采用没有完成,请检查项目状态。"
        )
    }

    /// 等待某章的润色候选生成完成。以「出现新的可用候选」为成功主信号;run 落定后
    /// 宽限窗内仍无候选、或整体超时则判为失败(返回 nil)。
    private func awaitPolishCandidate(
        sourceVersionID: NovelChapterVersionID,
        preexistingIDs: Set<NovelCandidateID>
    ) async throws -> NovelCandidateID? {
        let startedAt = Date()
        while true {
            try Task.checkCancellation()
            // 主动让快照追上 durable 提交。真机上 .completed 事件可能先于候选落盘广播,
            // consume 的单次 refresh 读到的是旧快照(无候选、run 仍 running);若轮询只读不
            // refresh,就会一直读旧快照——既看不到候选,也无法在 run 真正结束后经
            // refreshDurable 的 retire 分支清掉 terminalAwaitingRefresh,进而卡住后续章节的
            // 启动门禁。refreshDurable 幂等、不 rebind、不 detach 正在跑的 consumer。
            _ = await refreshDurable(binding: binding, token: bindingToken)
            // 停止可能与上面的 durable refresh 竞速。refresh 本身不抛取消；若不在
            // await 后重新检查，刚被 stop 收口的当前章会被误记为“生成失败”，而不是
            // 用户明确停止后的“未处理”。
            try Task.checkCancellation()
            if let candidate = availablePolishCandidates.first(where: {
                $0.sourceChapterVersionID == sourceVersionID &&
                    !preexistingIDs.contains($0.id)
            }) {
                return candidate.id
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            // activeRunID 在 terminalAwaitingRefresh 窗口本就为 nil,故不再把
            // `!terminalAwaitingRefresh` 当落定条件——否则一旦终态 refreshDurable 失败
            // (terminalAwaitingRefresh 卡住、refreshErrorMessage 置位),settled 永远为
            // false,要白等到 900s 超时。改由宽限窗兜底:候选正常会在宽限窗内落盘并被上面的
            // 候选检查捕获,只有宽限窗内仍未出现才判失败。
            let settled = activeRunID == nil && !isStarting
            if (settled && elapsed > batchPolishSettleGrace) ||
                elapsed > batchPolishCandidateTimeout {
                // 硬超时但 run 仍在跑：停掉它，否则后续章节全被 canStart 的
                // !isRunning 门禁挡住，级联失败。
                if activeRunID != nil {
                    await stop(reason: .user)
                }
                return nil
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    private func unhandledBatchResults(
        chapterIDs: [NovelChapterID],
        handled: [NovelBatchPolishChapterResult],
        outcome: NovelBatchPolishChapterResult.Outcome,
        message: String?
    ) -> [NovelBatchPolishChapterResult] {
        let handledIDs = Set(handled.map(\.chapterID))
        return chapterIDs.enumerated().compactMap { index, chapterID in
            guard !handledIDs.contains(chapterID) else { return nil }
            return NovelBatchPolishChapterResult(
                chapterID: chapterID,
                title: batchPolishTitle(for: chapterID, ordinal: index + 1),
                outcome: outcome,
                message: message
            )
        }
    }

    private func mutateBatchProgress(
        binding expectedBinding: NovelSessionBinding? = nil,
        _ mutate: (inout NovelBatchPolishProgress) -> Void
    ) {
        guard var progress = batchPolishProgressStorage,
              progress.binding == (expectedBinding ?? binding) else { return }
        mutate(&progress)
        batchPolishProgressStorage = progress
    }

    private func stopOwnedBatchPolishRun(
        binding expectedBinding: NovelSessionBinding,
        reason: NovelRunInterruptionReason
    ) async {
        let runID = batchPolishOwnedRunID ?? (isBatchStartingRun ? activeRunID : nil)
        guard let runID,
              binding == expectedBinding,
              activeRunID == runID else { return }
        let durableRun = workspace.projectSnapshot?.activeRuns.first {
            $0.id == runID && $0.branchID == expectedBinding.branchID
        }
        if let durableRun, durableRun.status != .running {
            await clearTransientTailAfterDurableProjection(
                runID: runID,
                token: bindingToken
            )
            return
        }
        await stop(reason: reason)
    }

    func reconcileBatchPolishResult(
        transactionID: NovelPendingOperationID,
        chapterID: NovelChapterID?
    ) {
        guard let chapterID,
              let transaction = workspace.projectSnapshot?.polishTransactions.first(where: {
                  $0.id == transactionID
              }) else { return }
        mutateBatchProgress { progress in
            guard let index = progress.results.firstIndex(where: { $0.chapterID == chapterID }) else {
                return
            }
            switch transaction.status {
            case .completed:
                progress.results[index].outcome = .adopted
                progress.results[index].message = nil
            case .incompatible:
                progress.results[index].outcome = .skippedDrift
                progress.results[index].message = "润色改动了剧情事实,已跳过本章。"
            case .abandoned:
                progress.results[index].outcome = .failed
                progress.results[index].message = "已放弃未完成的润色检查，可重新润色本章。"
            case .pending, .retryable, .blocked:
                progress.results[index].outcome = .failed
                progress.results[index].message = transaction.lastFailure?.message ?? "润色检查仍未完成。"
            }
        }
    }

    private func batchPolishTitle(for chapterID: NovelChapterID, ordinal: Int) -> String {
        guard let version = currentChapterVersions.first(where: {
            $0.chapterID == chapterID
        }) else {
            return "第 \(ordinal) 章"
        }
        return NovelPresentation.chapterDisplayTitle(
            storedTitle: version.title,
            content: version.content,
            ordinal: ordinal
        )
    }

    /// 批量失败时附带的内部状态快照:真机上回写/门禁卡住时,兜底文案看不出真因,把当时的
    /// binding / 快照匹配 / refresh 错误 / activeRun 等带出来,便于据截图定位。
    private func batchPolishDiagnostic() -> String {
        [
            "binding=\(binding == nil ? "nil" : "ok")",
            "match=\(snapshotMatchesBinding)",
            "selProj=\(String(describing: workspace.selectedProjectID))",
            "bindProj=\(binding?.projectID.description ?? "-")",
            "tailAwait=\(terminalAwaitingRefresh)",
            "activeRun=\(activeRun.map { String(describing: $0.status) } ?? "-")",
            "refreshErr=\(refreshErrorMessage ?? "-")",
            "opErr=\(operationErrorMessage ?? "-")",
            "polishCands=\(availablePolishCandidates.count)",
            "wsPerform=\(workspace.isPerforming)",
        ].joined(separator: " ")
    }

}
