import Foundation
import CryptoKit
import Observation
import OSLog
import SwiftUI
@preconcurrency import Shared

extension ChatViewModel {

    /// 从 store 的 currentConversation 灌入 messages（切换会话 / App 启动时调用）。
    /// 必须在主线程；调用方负责确保 store 已 bootstrap。
    /// 不变量:任何对 `messages` 的写入都必须紧跟一次本方法调用。
    /// chat 列表的 ChatCollectionUpdateKey 以 signal(revision+reason)判断是否重建快照,
    /// 漏掉 bump 会静默漏刷新(key 不变 → apply 被跳过 → 列表停在旧内容),无编译期提示。
    func bumpMessageRevision(reason: ChatMessageUpdateReason, lagAllowance: CGFloat = 1) {
        messageRevision &+= 1
        messageUpdateSignal = ChatMessageUpdateSignal(
            revision: messageRevision,
            reason: reason,
            lagAllowance: lagAllowance
        )
        // 独立保留产物刷新信号，避免工具结果与后续文字 chunk 合并上屏时丢失。
        switch reason {
        // 生成式 UI 修复重试直接发布定稿正文（.assistantStreamClosed），也要重建索引。
        case .initialLoad, .conversationSwitch, .branchChange, .toolResultAppended, .assistantStreamClosed:
            artifactUpdateWasRunning = (reason == .toolResultAppended || reason == .assistantStreamClosed)
                && isGenerationActiveForCurrentConversation
            artifactUpdateSignal = messageUpdateSignal
        default:
            break
        }
        // token usage 只在结构性事件后变化；streamDelta/toolDelta 不改 usage。
        switch reason {
        case .streamDelta, .toolDelta:
            break
        default:
            tokenRevision &+= 1
        }
    }

    func reloadFromStore(reason: ChatMessageUpdateReason = .initialLoad) {
        guard let store = conversationStore else { return }
        invalidateSuggestionRequest()
        let selectedRun = currentRun
        // Keep live deltas and approval continuations when returning to an active run.
        if selectedRun.host?.isRunning != true {
            let storedMessages = store.currentMessages
            messages = messagesByTerminatingStaleSearches(in: storedMessages, store: store) ?? storedMessages
            // 历史消息的 token 估算在后台预热，发送时的请求准备只剩查表。
            nonisolated(unsafe) let loadedMessages = messages
            Task.detached(priority: .utility) {
                ContextTokenEstimateMemo.shared.warm(loadedMessages)
            }
            contextCompactState = .idle
            let state = selectedRun.state
            state.steerQueueLoaded = false
            state.steerQueueRevision &+= 1
            let revision = state.steerQueueRevision
            if let conversationId = state.conversationId?.toHexDashString() {
                let queueIO = inboxIO
                steerQueueLoadTask = Task { @MainActor [weak self] in
                    let loaded = await queueIO.loadQueueOffMain(conversationId: conversationId)
                    guard let self, state.steerQueueRevision == revision else { return }
                    state.steerQueue = loaded
                    state.steerQueueLoaded = true
                }
            } else {
                state.steerQueue = []
                state.steerQueueLoaded = true
                steerQueueLoadTask = nil
            }
        }
        runRegistry.retainActive(keeping: selectedRun)
        refreshIntelligentUIReceipts(messages: messages, conversationID: store.currentConversation?.id.toHexDashString())
        refreshContextCompactBoundaries()
        // P1-a: 队列随会话切换重灌（冷启动恢复：只进队列 UI，不自动发送）。
        bumpMessageRevision(reason: reason)
        chatSuggestions = []
        // P1-e: 会话切换时异步刷新子线程只读缓存（Room 一次查询；composer 判定
        // 在切换后立即生效）。
        orchestratedStatusRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshCurrentConversationOrchestratedStatus()
        }
    }

    func refreshContextCompactBoundaries() {
        contextCompactBoundaries = IOSContextCompactionCoordinator.shared.timelineBoundaries(
            conversationId: currentConversationId, messages: messages
        )
    }

    private func messagesByTerminatingStaleSearches(
        in storedMessages: [UIMessage],
        store: IOSConversationStore
    ) -> [UIMessage]? {
        guard let conversationId = store.currentConversation?.id,
              !isGenerationActive(conversationId: conversationId) else {
            return nil
        }
        let pendingSearches = storedMessages.flatMap { message -> [UIMessagePart.Tool] in
            guard message.role == MessageRole.assistant, message.finishedAt != nil else { return [] }
            return message.parts.compactMap { $0 as? UIMessagePart.Tool }.filter {
                IOSSearchExecutor.supportedToolNames.contains($0.toolName) && $0.output.isEmpty
            }
        }
        guard !pendingSearches.isEmpty else { return nil }

        let runtime = ChatToolRuntime(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            localToolExecutor: localToolExecutor,
            searchTransport: searchTransport,
            mcpManager: mcpManager
        )
        let recoveredMessages = pendingSearches.reduce(storedMessages) { messages, toolCall in
            runtime.messagesByFinishingToolCall(
                toolCall,
                outputText: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: IOSAppLocalization.string(
                        "The previous generation ended before the tool call completed.",
                        defaultValue: "The previous generation ended before the tool call completed."
                    ),
                    cancelled: true
                ),
                in: messages
            )
        }
        let writeBaseline = store.writeBaseline(for: conversationId)
        Task { @MainActor [weak self, weak store] in
            guard let self, let store,
                  !self.isGenerationActive(conversationId: conversationId) else { return }
            _ = await store.save(
                messages: recoveredMessages,
                to: conversationId,
                ifUnchangedSince: writeBaseline
            )
        }
        return recoveredMessages
    }

    func terminateRecoveredPendingApprovals(
        _ descriptors: [IOSPendingApprovalRecoveryDescriptor]
    ) async {
        guard let conversationStore, !descriptors.isEmpty else { return }
        let runtime = ChatToolRuntime(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            localToolExecutor: localToolExecutor,
            searchTransport: searchTransport,
            mcpManager: mcpManager
        )
        var didUpdateCurrentConversation = false

        for descriptor in descriptors {
            guard let conversationId = conversationStore.summaries.first(where: {
                $0.id.toHexDashString() == descriptor.conversationId
            })?.id else {
                await IOSRunRecovery.completePendingApprovalRecovery(
                    runId: descriptor.runId,
                    runStore: runStore
                )
                continue
            }
            guard let storedMessages = await conversationStore.messages(for: conversationId) else {
                continue
            }

            // W3 state-machine check (docs/IOS_AGENT_HARDENING_PLAN_2026-07-29.md
            // §W3, invariant I-3): approving a tool never flips `agent_run.status`
            // back to "running" — `executeApprovedAsyncTool` records the ledger's
            // Started/Finished pair for the real execution but never calls
            // `recordRun`, so a crash during the post-approval execution leaves
            // the run stuck at status "awaiting_permission", indistinguishable at
            // the AgentRunEntity level from "user never tapped approve". Only the
            // tool-call ledger tells the two apart: a genuinely-still-pending call
            // has exactly one Started→Finished(paused_for_approval) pair; an
            // approved-then-crashed call has a SECOND Started after that with no
            // Finished. Consult it before assuming "cancelled" is the honest story
            // — a side-effect tool that was actually approved and mid-execution
            // must land as "outcome unknown", never a plain cancellation.
            //
            // F1 fix: this MUST run unconditionally, before any short-circuit on
            // `descriptor`'s own tool call. A single run can have the descriptor's
            // tc-1 (already approved, output present) followed by a second call
            // tc-2 the model issued right after — if tc-2 died mid-execution, it
            // has a dangling ledger Started with no Finished, but its tool part's
            // `output` is also empty, so it looks exactly like "never approved".
            // Skipping this plan step (as the old `guard pendingTool ... else
            // continue` did whenever tc-1 no longer had empty output) would leave
            // tc-2 unmarked forever: this run is excluded from AppShell's
            // interrupted-run sweep once `completePendingApprovalRecovery` below
            // marks it "interrupted", so tc-2 would silently re-fire (a real
            // sideEffect re-run) the next time the user resumes this chat —
            // violating I-3. Apply the FULL actions map (every toolCallId this
            // run's ledger has an opinion on), not just descriptor.toolCallId.
            guard let ledgerActions = await IOSRunRecovery.planToolCallRecovery(
                runId: descriptor.runId,
                messages: storedMessages,
                dao: agentRuntimeDao
            ) else {
                continue
            }
            let unknownToolCallIds = ledgerActions.actions.compactMap { toolCallId, action -> String? in
                action == .markUnknown ? toolCallId : nil
            }
            var recoveredMessages = IOSToolCallRecoveryApplier.apply(ledgerActions, to: storedMessages)
            var didMutateRecovered = !ledgerActions.isEmpty

            // descriptor's own tool call: only fall back to the plain "App
            // restarted while waiting for confirmation" cancellation notice if
            // it's still sitting with empty output AND the ledger sweep above
            // had no opinion on it (i.e. genuinely never approved — unchanged
            // S2 behavior). If the ledger already produced an action for it,
            // the loop above already wrote its (possibly "outcome unknown")
            // resolution and this branch must not overwrite that with a plain
            // cancellation.
            let descriptorToolStillPending = storedMessages
                .flatMap(\.parts)
                .compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: { $0.toolCallId == descriptor.toolCallId && $0.output.isEmpty })
            if let descriptorToolStillPending, ledgerActions[descriptor.toolCallId] == nil {
                let failure = ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptorToolStillPending.toolName,
                    reason: IOSAppLocalization.string(
                        "App restarted while waiting for confirmation.",
                        defaultValue: "App restarted while waiting for confirmation."
                    ),
                    cancelled: true
                )
                recoveredMessages = runtime.messagesByFinishingToolCall(
                    descriptorToolStillPending,
                    outputText: failure,
                    in: recoveredMessages
                )
                let noticeSeed = UIMessage.companion.assistant(prompt: "")
                recoveredMessages.append(UIMessage(
                    id: noticeSeed.id,
                    role: noticeSeed.role,
                    parts: [MessageKt.localGenerationErrorTextPart(text: IOSAppLocalization.string(
                        "待确认操作因 App 重启已终止，请重新生成。",
                        defaultValue: "待确认操作因 App 重启已终止，请重新生成。"
                    ))],
                    annotations: noticeSeed.annotations,
                    createdAt: noticeSeed.createdAt,
                    finishedAt: noticeSeed.finishedAt,
                    modelId: noticeSeed.modelId,
                    usage: noticeSeed.usage,
                    translation: noticeSeed.translation
                ))
                didMutateRecovered = true
            }

            if didMutateRecovered {
                guard await conversationStore.save(messages: recoveredMessages, to: conversationId) else {
                    continue
                }
                await IOSRunRecovery.finalizeToolCallRecovery(
                    runId: descriptor.runId,
                    plan: ledgerActions,
                    dao: agentRuntimeDao
                )
                if !unknownToolCallIds.isEmpty {
                    _ = try? await runStore.transitionFromAnyActive(
                        runId: descriptor.runId,
                        to: .outcomeUnknown,
                        detail: "tool_outcome_unknown"
                    )
                    for toolCallId in unknownToolCallIds.sorted() {
                        guard let toolName = recoveredMessages
                            .flatMap(\.parts)
                            .compactMap({ $0 as? UIMessagePart.Tool })
                            .first(where: { $0.toolCallId == toolCallId })?.toolName
                            ?? ledgerActions.toolNames[toolCallId] else { continue }
                        let unknown = IOSToolOutcomeUnknownDescriptor(
                            runId: descriptor.runId,
                            conversationId: descriptor.conversationId,
                            toolCallId: toolCallId,
                            toolName: toolName
                        )
                        if !toolOutcomeUnknownDescriptors.contains(unknown) {
                            toolOutcomeUnknownDescriptors.append(unknown)
                        }
                    }
                }
                didUpdateCurrentConversation = didUpdateCurrentConversation || currentConversationId == conversationId
            }
            if unknownToolCallIds.isEmpty {
                await IOSRunRecovery.completePendingApprovalRecovery(
                    runId: descriptor.runId,
                    runStore: runStore
                )
            }
        }

        if didUpdateCurrentConversation {
            reloadFromStore(reason: .branchChange)
        }
    }

    /// W3 (§ crash-recovery UX): for interrupted runs that were never
    /// awaiting approval (the ordinary "died mid tool HTTP call / mid plain
    /// generation" case), read each run's ledger and apply the resulting
    /// per-toolCallId recovery action to that run's conversation. Mirrors
    /// `terminateRecoveredPendingApprovals`'s conversation-lookup/save
    /// pattern; a run whose conversation can no longer be found (deleted by
    /// the user in the meantime) is skipped silently, same convention as
    /// that method.
    func applyToolCallLedgerRecovery(
        forInterruptedRuns pairs: [(runId: String, conversationId: String)]
    ) async -> IOSToolCallRecoverySweepResult {
        guard let conversationStore, !pairs.isEmpty else { return IOSToolCallRecoverySweepResult() }
        var didUpdateCurrentConversation = false
        var result = IOSToolCallRecoverySweepResult()
        var discoveredUnknowns: [IOSToolOutcomeUnknownDescriptor] = []

        for pair in pairs {
            guard let conversationId = conversationStore.summaries.first(where: {
                $0.id.toHexDashString() == pair.conversationId
            })?.id else {
                print("[AmberChat] W3 recovery: conversation \(pair.conversationId) for run \(pair.runId) not found, skipping (may have been deleted).")
                // A deleted conversation has no pending tool node left to replay.
                result.reconciledRunIds.insert(pair.runId)
                continue
            }
            guard let storedMessages = await conversationStore.messages(for: conversationId) else { continue }
            guard let actions = await IOSRunRecovery.planToolCallRecovery(
                runId: pair.runId,
                messages: storedMessages,
                dao: agentRuntimeDao
            ) else { continue }
            guard !actions.isEmpty else {
                result.reconciledRunIds.insert(pair.runId)
                continue
            }

            let unknownToolCallIds = actions.actions.compactMap { toolCallId, action -> String? in
                action == .markUnknown ? toolCallId : nil
            }

            let recoveredMessages = IOSToolCallRecoveryApplier.apply(actions, to: storedMessages)
            guard await conversationStore.save(messages: recoveredMessages, to: conversationId) else { continue }
            await IOSRunRecovery.finalizeToolCallRecovery(
                runId: pair.runId,
                plan: actions,
                dao: agentRuntimeDao
            )
            if unknownToolCallIds.isEmpty {
                result.reconciledRunIds.insert(pair.runId)
            } else {
                _ = try? await runStore.transitionFromAnyActive(
                    runId: pair.runId,
                    to: .outcomeUnknown,
                    detail: "tool_outcome_unknown"
                )
                result.outcomeUnknownRunIds.insert(pair.runId)
                for toolCallId in unknownToolCallIds.sorted() {
                    guard let toolName = recoveredMessages
                        .flatMap(\.parts)
                        .compactMap({ $0 as? UIMessagePart.Tool })
                        .first(where: { $0.toolCallId == toolCallId })?.toolName
                        ?? actions.toolNames[toolCallId] else { continue }
                    discoveredUnknowns.append(IOSToolOutcomeUnknownDescriptor(
                        runId: pair.runId,
                        conversationId: pair.conversationId,
                        toolCallId: toolCallId,
                        toolName: toolName
                    ))
                }
            }
            didUpdateCurrentConversation = didUpdateCurrentConversation || currentConversationId == conversationId
        }

        for descriptor in discoveredUnknowns where !toolOutcomeUnknownDescriptors.contains(descriptor) {
            toolOutcomeUnknownDescriptors.append(descriptor)
        }
        if let descriptor = discoveredUnknowns.sorted(by: {
            if $0.runId == $1.runId { return $0.toolCallId < $1.toolCallId }
            return $0.runId < $1.runId
        }).first {
            // W3 is the authoritative discovery point after a cold launch;
            // keep the Watch projection in sync even when no live producer
            // was present to publish the original unknown result.
            _ = WatchTaskCoordinator.shared.publishOutcomeUnknown(descriptor)
        }

        if didUpdateCurrentConversation {
            reloadFromStore(reason: .branchChange)
        }
        return result
    }

    func reconcilePendingToolOutcome(didApply: Bool) async {
        guard let descriptor = pendingToolOutcomeUnknown,
              let conversationStore,
              let conversationId = conversationStore.summaries.first(where: {
                  $0.id.toHexDashString() == descriptor.conversationId
              })?.id,
              let storedMessages = await conversationStore.messages(for: conversationId) else { return }
        let reconciledMessages = IOSToolCallRecoveryApplier.applyOutcomeUnknownReconciliation(
            toolCallId: descriptor.toolCallId,
            didApply: didApply,
            to: storedMessages
        )
        guard await conversationStore.save(messages: reconciledMessages, to: conversationId) else { return }
        guard await IOSRunRecovery.reconcileOutcomeUnknown(
            runId: descriptor.runId,
            toolCallId: descriptor.toolCallId,
            didApply: didApply,
            dao: agentRuntimeDao,
            runStore: runStore
        ) else { return }
        toolOutcomeUnknownDescriptors.removeAll { $0 == descriptor }
        let hasRemainingUnknown = toolOutcomeUnknownDescriptors.contains {
            $0.runId == descriptor.runId && $0.conversationId == descriptor.conversationId
        }
        _ = WatchTaskCoordinator.shared.publishOutcomeUnknownReconciled(
            runId: descriptor.runId,
            conversationId: descriptor.conversationId,
            toolCallId: descriptor.toolCallId,
            hasRemainingUnknown: hasRemainingUnknown,
            didApply: didApply
        )
        if currentConversationId == conversationId {
            reloadFromStore(reason: .branchChange)
        }
    }

    /// 把当前 messages 落盘（节流：只在流式结束/取消/切换时调，不在每个 chunk 调）。
}
