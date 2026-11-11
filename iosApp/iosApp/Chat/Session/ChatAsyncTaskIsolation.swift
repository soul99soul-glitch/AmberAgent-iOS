import Foundation
import SwiftUI
@preconcurrency import Shared

/// Targeted follow-up (`inputs`) explicitly bound to a specific local task (`runId`).
/// Aligns with the Cloud Dialogue v1 `work-items/{id}/inputs` lifecycle (`received` -> `consumed` | `cancelled`).
struct ChatLocalTaskFollowup: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case received
        case consumed
        case cancelled
    }

    let id: String
    let runId: String
    let text: String
    let createdAtMillis: Int64
    var status: Status

    var isShownAsExecuted: Bool {
        status == .consumed
    }
}

/// Per-task isolation slot within a conversation (`ChatConversationRun`).
/// Each task owns its own `ChatKernelRunHost`, baseline transcript, generated message IDs,
/// anchor position in `state.messages`, and targeted follow-up queue.
@MainActor
final class ChatAsyncTaskSlot {
    let slotId: String
    var runId: String
    let conversationId: KotlinUuid?
    let inputDigest: String
    let anchorUserMessageId: String?
    let phoneControlUserInitiated: Bool
    let providerSetting: ProviderSetting
    let params: TextGenerationParams
    let toolExposureBridge: IosToolExposureBridge?
    let recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?

    /// Conversation messages up to `anchorUserMessageId`, excluding in-flight outputs of other concurrent tasks.
    let baselineMessages: [UIMessage]
    let baselineMessageIds: Set<String>

    /// The task's isolated transcript (`baselineMessages + generatedMessages`), read/written by its `ChatKernelRunHost`.
    var currentTranscript: [UIMessage]

    /// Assistant turns (and any consumed targeted follow-up user messages) produced by this task.
    var generatedMessages: [UIMessage] = []
    var generatedMessageIds: Set<String> = []
    var lastSplicedTailIndex: Int?
    var lastSplicedTailID: String?
    /// Assistant message ID produced by the active model round (`nil` right after a new round begins).
    var currentRoundAssistantMessageId: String?
    var activityStage: AgentActivityStage = .preparing
    var activeToolName: String?
    var activeToolTitle: String?
    var plannedActivityStages: [String] = []
    var stagePlanStartedUptime: TimeInterval?
    var liveReasoningSummary: String?
    var reasoningSummaryUpdatedUptime: TimeInterval = 0
    var lastActivityUptime = ProcessInfo.processInfo.systemUptime
    /// 最近一次有意义且已同步给用户的实质进展时间（排除 token 心跳、重复工具轮询、内部日志与 UI 动画）。
    var lastUserVisibleProgressUptime = ProcessInfo.processInfo.systemUptime
    /// 当前无进展静默窗口内是否已发送过保活正文（同一静默窗口最多一条，出现新实质进展后重置）。
    var hasEmittedKeepaliveInCurrentSilenceWindow = false
    var lastSyncedVisibleStage: AgentActivityStage?
    var lastSyncedVisibleToolSignature: String?
    var lastSyncedVisibleProseSignature: Int?
    var explicitFailureOrStallReason: String?
    var keepaliveMonitorTask: Task<Void, Never>?
    var keepaliveMessages: [UIMessage] = []
    var commentaryCoalescer = ChatTaskCommentaryCoalescer()

    nonisolated static let keepaliveSilenceThresholdSeconds: TimeInterval = 60.0
    nonisolated static let keepaliveDefaultText = "当前步骤仍在处理中，暂时还没有新的结果，一有进展我会立即同步给你。"
    nonisolated static let messageRoleMetadataKey = "amber_message_role"
    nonisolated static let keepaliveMetadataValue = "keepalive"
    nonisolated static let commentaryMilestoneMetadataKey = "amber_commentary_milestone"

    func recordMeaningfulUserVisibleProgress(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !isTerminal else { return }
        lastUserVisibleProgressUptime = uptime
        hasEmittedKeepaliveInCurrentSilenceWindow = false
    }

    /// Placeholder message shown at this task's anchor position while waiting for a local concurrency slot.
    var queuedPlaceholderMessageId: String?
    var isQueuedForConcurrencySlot: Bool = false
    var isTerminal: Bool = false

    /// Follow-ups explicitly targeted at this task via `selectTaskForFollowup(runId:)`.
    var targetedFollowups: [ChatLocalTaskFollowup] = []

    var host: ChatKernelRunHost?

    var allOwnedMessageIds: Set<String> {
        var ids = generatedMessageIds
        if let queuedPlaceholderMessageId {
            ids.insert(queuedPlaceholderMessageId)
        }
        return ids
    }

    var isActiveOrQueued: Bool {
        if isTerminal { return false }
        if isQueuedForConcurrencySlot { return true }
        return host?.isRunning == true
    }

    init(
        slotId: String = UUID().uuidString.lowercased(),
        conversationId: KotlinUuid?,
        inputDigest: String,
        anchorUserMessageId: String?,
        phoneControlUserInitiated: Bool,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        toolExposureBridge: IosToolExposureBridge?,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?,
        baselineMessages: [UIMessage]
    ) {
        self.slotId = slotId
        self.runId = slotId
        self.conversationId = conversationId
        self.inputDigest = inputDigest
        self.anchorUserMessageId = anchorUserMessageId
        self.phoneControlUserInitiated = phoneControlUserInitiated
        self.providerSetting = providerSetting
        self.params = params
        self.toolExposureBridge = toolExposureBridge
        self.recipeCatalogSnapshot = recipeCatalogSnapshot
        self.baselineMessages = baselineMessages
        self.baselineMessageIds = Set(baselineMessages.map { ChatMessageProjector.messageId(for: $0) })
        self.currentTranscript = baselineMessages
    }
}

extension ChatViewModel {
    nonisolated static let queuedTaskPlaceholderText = "排队中，等待前序任务完成后自动开始…"

    /// Explicit task selection for follow-up (`inputs`). When `nil`, plain composer messages start a new question.
    var selectedFollowupRunId: String? {
        get { currentRun.state.selectedFollowupRunId }
        set { currentRun.state.selectedFollowupRunId = newValue }
    }

    func selectTaskForFollowup(runId: String?) {
        guard let runId, !runId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            currentRun.state.selectedFollowupRunId = nil
            return
        }
        currentRun.state.selectedFollowupRunId = runId
    }

    /// Active or queued task runIds in the current conversation, in creation order.
    var activeTaskRunIdsForCurrentConversation: [String] {
        _ = runActivityRevision
        return currentRun.orderedSlots
            .filter(\.isActiveOrQueued)
            .map(\.runId)
    }

    var focusedActiveTask: ChatAsyncTaskSlot? {
        _ = runActivityRevision
        let slots = currentRun.orderedSlots.filter(\.isActiveOrQueued)
        if let selected = selectedFollowupRunId,
           let slot = slots.first(where: { $0.runId == selected || $0.slotId == selected }) {
            return slot
        }
        return slots.last
    }

    var pendingDeferredGenerationAnchorId: String? {
        guard let pending = deferredGenerationStart, pending.run === currentRun else { return nil }
        return pending.anchorUserMessageId
    }

    /// Removes empty status stubs only after their owner has reached an explicit terminal state.
    /// Waiting for a first token, reasoning, and concurrency queuing are normal live states;
    /// status-line coalescing must not cancel those independent tasks.
    func retireEmptyStalledStatusSlotsBeforeContinuation(
        in run: ChatConversationRun,
        newSlotId: String
    ) {
        let selectedId = run.state.selectedFollowupRunId
        for oldSlot in run.orderedSlots where oldSlot.slotId != newSlotId && oldSlot.isTerminal {
            if let selectedId, (oldSlot.runId == selectedId || oldSlot.slotId == selectedId) {
                continue
            }
            let hasAnyVisibleProseOrTools = oldSlot.generatedMessages.contains { msg in
                if !msg.getTools().isEmpty { return true }
                return msg.parts.contains { part in
                    if let textPart = part as? UIMessagePart.Text {
                        let trimmed = textPart.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return !trimmed.isEmpty && trimmed != Self.queuedTaskPlaceholderText
                    }
                    return !(part is UIMessagePart.Reasoning)
                }
            }
            guard !hasAnyVisibleProseOrTools else { continue }
            cancelAndRetireSlot(oldSlot, in: run, removeAllGeneratedStubs: true)
        }
    }

    /// Cancels and retires any active/queued slots in `run` whose anchor message was removed by a
    /// branch mutation (`editMessage`, `regenerate`, `deleteMessage`, `selectVariant`).
    func retireOrphanedTaskSlotsAfterBranchChange(in run: ChatConversationRun) {
        let currentMessageIds = Set(run.state.messages.map(ChatMessageProjector.messageId(for:)))
        for slot in run.orderedSlots where !slot.isTerminal {
            if let anchorId = slot.anchorUserMessageId, !currentMessageIds.contains(anchorId) {
                cancelAndRetireSlot(slot, in: run, removeAllGeneratedStubs: true)
            }
        }
        refreshLiveTaskMessageIds(in: run)
    }

    private func cancelAndRetireSlot(
        _ slot: ChatAsyncTaskSlot,
        in run: ChatConversationRun,
        removeAllGeneratedStubs: Bool
    ) {
        slot.isTerminal = true
        slot.isQueuedForConcurrencySlot = false
        slot.keepaliveMonitorTask?.cancel()
        slot.keepaliveMonitorTask = nil
        slot.activeToolName = nil
        slot.activeToolTitle = nil
        slot.liveReasoningSummary = nil
        slot.currentRoundAssistantMessageId = nil
        runRegistry.removePendingTask(slotId: slot.slotId)
        if let placeholderId = slot.queuedPlaceholderMessageId {
            slot.queuedPlaceholderMessageId = nil
            run.state.messages.removeAll { ChatMessageProjector.messageId(for: $0) == placeholderId }
        }
        if removeAllGeneratedStubs {
            let statusOnlyIds = Set(
                slot.generatedMessages
                    .filter { NativeTimelineProjector.isGlobalStatusOnly($0) }
                    .map(ChatMessageProjector.messageId(for:))
            )
            if !statusOnlyIds.isEmpty {
                run.state.messages.removeAll { statusOnlyIds.contains(ChatMessageProjector.messageId(for: $0)) }
            }
        }
        cancelUnconsumedFollowups(for: slot, state: run.state)
        if let host = slot.host, host.isRunning {
            _ = host.cancel(runId: slot.runId)
        }
    }

    func isTaskActiveOrQueued(runId: String) -> Bool {
        for run in runRegistry.allRuns {
            if let slot = run.slot(forRunId: runId), slot.isActiveOrQueued {
                return true
            }
        }
        return false
    }

    func taskFollowups(forRunId runId: String, conversationId: KotlinUuid? = nil) -> [ChatLocalTaskFollowup] {
        let run = conversationId.flatMap { runRegistry.run(for: $0) } ?? currentRun
        if let slot = run.slot(forRunId: runId) {
            return slot.targetedFollowups
        }
        return run.state.followupsByRunId[runId] ?? []
    }

    /// Enqueues a follow-up message explicitly targeted at `runId`.
    /// Consumed at `runId`'s next reasoning boundary (`drainSteerQueue`).
    @discardableResult
    func enqueueTaskFollowup(
        runId: String,
        text: String,
        consumesComposer: Bool = true
    ) -> ChatLocalTaskFollowup? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let (run, slot) = runRegistry.findSlot(runId: runId),
              slot.isActiveOrQueued else {
            return nil
        }
        let followup = ChatLocalTaskFollowup(
            id: UUID().uuidString.lowercased(),
            runId: slot.runId,
            text: trimmed,
            createdAtMillis: Int64(Date().timeIntervalSince1970 * 1_000),
            status: .received
        )
        slot.targetedFollowups.append(followup)
        syncFollowupsToState(slot: slot, state: run.state)
        if consumesComposer {
            inputText = ""
            pendingSelectedFilePreview = nil
            clearPendingImages()
            selectedFileContextError = nil
            run.state.selectedFollowupRunId = nil
        }
        runActivityRevision &+= 1
        return followup
    }

    /// Drains `.received` follow-ups targeted at `slot` at its next reasoning boundary.
    func drainTaskSteerQueue(
        slot: ChatAsyncTaskSlot,
        state: ChatConversationRunState
    ) async -> [UIMessage] {
        var drainedMessages: [UIMessage] = []
        var didMutate = false
        for index in slot.targetedFollowups.indices {
            guard slot.targetedFollowups[index].status == .received else { continue }
            slot.targetedFollowups[index].status = .consumed
            didMutate = true
            let userMsg = makeUserMessage(
                prompt: slot.targetedFollowups[index].text,
                images: []
            )
            drainedMessages.append(userMsg)
        }
        if didMutate {
            syncFollowupsToState(slot: slot, state: state)
        }
        guard !drainedMessages.isEmpty else {
            // If no task-specific follow-ups exist and this is the only task in the conversation,
            // also drain any legacy conversation-level steerQueue entries.
            if runRegistry.current(for: state.conversationId).orderedSlots.filter(\.isActiveOrQueued).count <= 1,
               !state.steerQueue.isEmpty {
                return await drainSteerQueue(state: state)
            }
            return []
        }

        let updatedTranscript = slot.currentTranscript + drainedMessages
        spliceTaskTranscript(updatedTranscript, for: slot, into: state)
        if isCurrentConversation(state.conversationId) {
            bumpMessageRevision(reason: .userAppend)
        }
        let targetConversationId = state.conversationId
        Task { @MainActor [weak self] in
            _ = await self?.persistMessages(state: state)
            if let targetConversationId {
                _ = self?.targetConversationIdForTouch(targetConversationId)
            }
        }
        runActivityRevision &+= 1
        return drainedMessages
    }

    private func targetConversationIdForTouch(_ id: KotlinUuid) -> KotlinUuid { id }

    /// Marks any `.received` follow-ups on `slot` as `.cancelled` when the task is stopped before consuming them.
    func cancelUnconsumedFollowups(
        for slot: ChatAsyncTaskSlot,
        state: ChatConversationRunState
    ) {
        var didChange = false
        for index in slot.targetedFollowups.indices where slot.targetedFollowups[index].status == .received {
            slot.targetedFollowups[index].status = .cancelled
            didChange = true
        }
        if didChange {
            syncFollowupsToState(slot: slot, state: state)
        }
        if state.selectedFollowupRunId == slot.runId || state.selectedFollowupRunId == slot.slotId {
            state.selectedFollowupRunId = nil
        }
    }

    func syncFollowupsToState(
        slot: ChatAsyncTaskSlot,
        state: ChatConversationRunState
    ) {
        state.followupsByRunId[slot.runId] = slot.targetedFollowups
        if slot.slotId != slot.runId {
            state.followupsByRunId[slot.slotId] = slot.targetedFollowups
        }
    }

    // MARK: - Task-Isolated Transcript Splicing

    /// Builds the clean baseline transcript for a newly created task anchored at `anchorUserMessageId`,
    /// excluding in-flight generated messages or placeholders owned by other active/queued tasks in `run`.
    func buildTaskBaselineMessages(
        in run: ChatConversationRun,
        anchorUserMessageId: String?
    ) -> [UIMessage] {
        let otherLiveIds = run.orderedSlots
            .filter { !$0.isTerminal }
            .reduce(into: Set<String>()) { partial, slot in
                partial.formUnion(slot.allOwnedMessageIds)
            }
        let allMessages = run.state.messages
        let prefixSlice: ArraySlice<UIMessage>
        if let anchorUserMessageId,
           let anchorIndex = allMessages.firstIndex(where: {
               ChatMessageProjector.messageId(for: $0) == anchorUserMessageId
           }) {
            prefixSlice = allMessages[...anchorIndex]
        } else {
            prefixSlice = allMessages[...]
        }
        return prefixSlice.compactMap { message -> UIMessage? in
            guard !otherLiveIds.contains(ChatMessageProjector.messageId(for: message)) else { return nil }
            guard message.role == MessageRole.assistant else { return message }
            // This is a new task's upload snapshot. Keep the timeline and the
            // current task's subsequent tool rounds untouched.
            let visibleParts = message.parts.filter { part in
                if let text = part as? UIMessagePart.Text {
                    return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return part is UIMessagePart.Image || part is UIMessagePart.Video ||
                    part is UIMessagePart.Audio || part is UIMessagePart.Document
            }
            guard !visibleParts.isEmpty else { return nil }
            guard visibleParts.count != message.parts.count else { return message }
            return UIMessage(id: message.id, role: message.role, parts: visibleParts,
                             annotations: message.annotations, createdAt: message.createdAt,
                             finishedAt: message.finishedAt, modelId: message.modelId,
                             usage: message.usage, translation: message.translation)
        }
    }

    /// Splices `taskTranscript` (`slot.baselineMessages + newGenerated`) into `state.messages`
    /// right after `slot.anchorUserMessageId` (or at the slot's previous position), keeping other tasks'
    /// messages untouched in their own positions.
    func spliceTaskTranscript(
        _ taskTranscript: [UIMessage],
        for slot: ChatAsyncTaskSlot,
        into state: ChatConversationRunState
    ) {
        let rawGenerated = taskTranscript.filter { msg in
            !slot.baselineMessageIds.contains(ChatMessageProjector.messageId(for: msg))
        }
        let coalescedGenerated = slot.commentaryCoalescer.coalesce(messages: rawGenerated)
        var newGenerated = coalescedGenerated
        for keepalive in slot.keepaliveMessages {
            let keepaliveID = ChatMessageProjector.messageId(for: keepalive)
            if !newGenerated.contains(where: { ChatMessageProjector.messageId(for: $0) == keepaliveID }) {
                if let lastIdx = newGenerated.indices.last,
                   newGenerated[lastIdx].role == MessageRole.assistant,
                   newGenerated[lastIdx].getTools().isEmpty,
                   newGenerated[lastIdx].finishedAt != nil {
                    newGenerated.insert(keepalive, at: lastIdx)
                } else {
                    newGenerated.append(keepalive)
                }
            }
        }
        let previousProseSig = slot.lastSyncedVisibleProseSignature ??
            Self.visibleSyncedProseSignature(in: slot.generatedMessages)
        let latestProseSig = Self.visibleSyncedProseSignature(in: coalescedGenerated)
        slot.lastSyncedVisibleProseSignature = latestProseSig
        if let latestProseSig, latestProseSig != previousProseSig {
            slot.recordMeaningfulUserVisibleProgress()
        }
        let previousOwnedIds = slot.allOwnedMessageIds
        var combined = state.messages
        var firstRemovedIndex: Int?
        if !previousOwnedIds.isEmpty {
            var filtered: [UIMessage] = []
            filtered.reserveCapacity(combined.count)
            for (idx, msg) in combined.enumerated() {
                let id = ChatMessageProjector.messageId(for: msg)
                if previousOwnedIds.contains(id) {
                    if firstRemovedIndex == nil {
                        firstRemovedIndex = idx
                    }
                } else {
                    filtered.append(msg)
                }
            }
            combined = filtered
        }

        let insertionIndex: Int
        if let anchorId = slot.anchorUserMessageId,
           let anchorIdx = combined.firstIndex(where: {
               ChatMessageProjector.messageId(for: $0) == anchorId
           }) {
            insertionIndex = anchorIdx + 1
        } else if let firstRemovedIndex {
            insertionIndex = min(firstRemovedIndex, combined.count)
        } else {
            insertionIndex = combined.endIndex
        }

        if !newGenerated.isEmpty {
            combined.insert(contentsOf: newGenerated, at: insertionIndex)
        }

        if let tailAssistant = newGenerated.last(where: { $0.role == MessageRole.assistant }) {
            let tailAssistantID = ChatMessageProjector.messageId(for: tailAssistant)
            if !previousOwnedIds.contains(tailAssistantID) {
                slot.currentRoundAssistantMessageId = tailAssistantID
            }
        }
        slot.generatedMessages = newGenerated
        slot.generatedMessageIds = Set(newGenerated.map { ChatMessageProjector.messageId(for: $0) })
        slot.currentTranscript = slot.baselineMessages + newGenerated
        state.messages = combined
        slot.lastSplicedTailIndex = newGenerated.isEmpty ? nil : insertionIndex + newGenerated.count - 1
        slot.lastSplicedTailID = newGenerated.last.map(ChatMessageProjector.messageId(for:))
        refreshLiveTaskMessageIds(in: runRegistry.current(for: state.conversationId))
    }

    /// Only provisional stream snapshots enter this path; authoritative snapshots
    /// can change older messages and always use the full splice above.
    func spliceTaskProvisionalAssistant(
        _ message: UIMessage, for slot: ChatAsyncTaskSlot, into state: ChatConversationRunState
    ) {
        if let previous = slot.generatedMessages.last,
           previous.id == message.id, previous.role == message.role,
           slot.currentTranscript.last?.id == message.id {
            let index: Int?
            if let cached = slot.lastSplicedTailIndex, state.messages.indices.contains(cached),
               state.messages[cached].id == message.id {
                index = cached
            } else {
                index = state.messages.lastIndex(where: { $0.id == message.id })
            }
            if let index {
                // Compare only the replaced row: stream deltas must not rescan task history.
                let previousProseSig = Self.visibleSyncedProseSignature(in: [previous])
                if let latestProseSig = Self.visibleSyncedProseSignature(in: [message]),
                   latestProseSig != previousProseSig {
                    slot.recordMeaningfulUserVisibleProgress()
                }
                // The aggregate is rebuilt only when an authoritative transcript next arrives.
                slot.lastSyncedVisibleProseSignature = nil
                slot.currentTranscript[slot.currentTranscript.count - 1] = message
                slot.generatedMessages[slot.generatedMessages.count - 1] = message
                state.messages[index] = message
                slot.lastSplicedTailIndex = index
                if message.role == .assistant, slot.isActiveOrQueued, let id = slot.lastSplicedTailID,
                   !state.liveTaskTailMessageIds.contains(id) {
                    state.liveTaskTailMessageIds.insert(id)
                }
                return
            }
        }
        var transcript = slot.currentTranscript
        if transcript.last?.id == message.id {
            transcript[transcript.count - 1] = message
        } else if let index = transcript.firstIndex(where: { $0.id == message.id }) {
            transcript[index] = message
        } else {
            transcript.append(message)
        }
        spliceTaskTranscript(transcript, for: slot, into: state)
    }

    func refreshLiveTaskMessageIds(in run: ChatConversationRun) {
        var liveIds = Set<String>()
        var liveTailIds = Set<String>()
        for slot in run.orderedSlots where slot.isActiveOrQueued {
            liveIds.formUnion(slot.allOwnedMessageIds)
            if let tail = slot.generatedMessages.last(where: { $0.role == MessageRole.assistant }) {
                liveTailIds.insert(ChatMessageProjector.messageId(for: tail))
            }
        }
        if run.state.liveTaskMessageIds != liveIds { run.state.liveTaskMessageIds = liveIds }
        if run.state.liveTaskTailMessageIds != liveTailIds { run.state.liveTaskTailMessageIds = liveTailIds }
        let loading = run.hasActiveOrQueuedTask
        if run.state.isLoading != loading { run.state.isLoading = loading }
    }

    // MARK: - Local Concurrency Cap & Scheduling

    var activeForegroundLocalRunCount: Int {
        runRegistry.activeForegroundRunCount
    }

    @discardableResult
    func startOrEnqueueTaskSlot(
        _ slot: ChatAsyncTaskSlot,
        in run: ChatConversationRun
    ) -> String {
        retireEmptyStalledStatusSlotsBeforeContinuation(in: run, newSlotId: slot.slotId)
        run.registerSlot(slot)
        if runRegistry.activeForegroundRunCount < runRegistry.maxConcurrentLocalRuns {
            return launchTaskSlot(slot, in: run)
        } else {
            enqueueTaskSlotForConcurrency(slot, in: run)
            return slot.runId
        }
    }

    @discardableResult
    func launchTaskSlot(
        _ slot: ChatAsyncTaskSlot,
        in run: ChatConversationRun
    ) -> String {
        slot.isQueuedForConcurrencySlot = false
        if let placeholderId = slot.queuedPlaceholderMessageId {
            slot.queuedPlaceholderMessageId = nil
            run.state.messages.removeAll {
                ChatMessageProjector.messageId(for: $0) == placeholderId
            }
        }
        let host = makeKernelRunHost(state: run.state, taskSlot: slot)
        slot.host = host
        run.host = host
        run.state.generationConfiguration = (
            slot.providerSetting,
            slot.params,
            slot.recipeCatalogSnapshot
        )
        host.start(
            providerSetting: slot.providerSetting,
            params: slot.params,
            inputDigest: slot.inputDigest,
            conversationId: slot.conversationId,
            uploadMessages: slot.baselineMessages,
            toolExposureBridge: slot.toolExposureBridge,
            recipeCatalogSnapshot: slot.recipeCatalogSnapshot,
            phoneControlUserInitiated: slot.phoneControlUserInitiated
        )
        if let actualRunId = host.currentRunId, !actualRunId.isEmpty {
            run.rebindSlotRunId(slot: slot, newRunId: actualRunId)
            syncFollowupsToState(slot: slot, state: run.state)
        }
        slot.recordMeaningfulUserVisibleProgress()
        startKeepaliveMonitor(for: slot, in: run)
        refreshLiveTaskMessageIds(in: run)
        runActivityRevision &+= 1
        return slot.runId
    }

    private func enqueueTaskSlotForConcurrency(
        _ slot: ChatAsyncTaskSlot,
        in run: ChatConversationRun
    ) {
        slot.isQueuedForConcurrencySlot = true
        let placeholderMsg = UIMessage.companion.assistant(prompt: Self.queuedTaskPlaceholderText)
        let placeholderId = ChatMessageProjector.messageId(for: placeholderMsg)
        slot.queuedPlaceholderMessageId = placeholderId

        var combined = run.state.messages
        if let anchorId = slot.anchorUserMessageId,
           let anchorIdx = combined.firstIndex(where: {
               ChatMessageProjector.messageId(for: $0) == anchorId
           }) {
            combined.insert(placeholderMsg, at: anchorIdx + 1)
        } else {
            combined.append(placeholderMsg)
        }
        run.state.messages = combined
        let conversationKey = run.state.conversationId?.toHexDashString() ?? ""
        runRegistry.enqueuePendingTask(conversationKey: conversationKey, slotId: slot.slotId)
        refreshLiveTaskMessageIds(in: run)
        if isCurrentConversation(run.state.conversationId) {
            bumpMessageRevision(reason: .userAppend)
        }
        runActivityRevision &+= 1
    }

    func markTaskSlotTerminal(
        _ slot: ChatAsyncTaskSlot,
        in run: ChatConversationRun
    ) {
        slot.isQueuedForConcurrencySlot = false
        slot.isTerminal = true
        slot.keepaliveMonitorTask?.cancel()
        slot.keepaliveMonitorTask = nil
        slot.activeToolName = nil
        slot.activeToolTitle = nil
        slot.liveReasoningSummary = nil
        slot.currentRoundAssistantMessageId = nil
        runRegistry.removePendingTask(slotId: slot.slotId)
        if let placeholderId = slot.queuedPlaceholderMessageId {
            slot.queuedPlaceholderMessageId = nil
            run.state.messages.removeAll {
                ChatMessageProjector.messageId(for: $0) == placeholderId
            }
        }
        cancelUnconsumedFollowups(for: slot, state: run.state)
        refreshLiveTaskMessageIds(in: run)
        runActivityRevision &+= 1
        dequeueNextPendingTasksIfPossible()
    }

    func dequeueNextPendingTasksIfPossible() {
        while runRegistry.activeForegroundRunCount < runRegistry.maxConcurrentLocalRuns,
              let next = runRegistry.popNextPendingTask() {
            guard let run = runRegistry.run(forHex: next.conversationKey),
                  let slot = run.slot(forRunId: next.slotId),
                  !slot.isTerminal,
                  slot.isQueuedForConcurrencySlot else {
                continue
            }
            _ = launchTaskSlot(slot, in: run)
        }
    }

    // MARK: - Truthful System Suspension / Foreground Recovery

    /// Reconciles foreground task slots when returning from system suspension.
    /// Tasks that were neither handed off to `IOSChatBackgroundGenerationCoordinator` nor protected by
    /// an active background keep-alive lease are truthfully interrupted rather than pretending `isRunning == true`.
    @discardableResult
    func reconcileForegroundRunsAfterSystemSuspensionIfNeeded(
        hasValidKeepAliveLease: Bool = false
    ) -> [String] {
        guard !hasValidKeepAliveLease else { return [] }
        var interruptedRunIds: [String] = []
        for run in runRegistry.allRuns {
            let convId = run.state.conversationId
            let hasBackgroundJob = convId.map {
                IOSChatBackgroundGenerationCoordinator.shared.hasActiveJob(conversationId: $0)
                    || IOSChatBackgroundGenerationCoordinator.shared.isWaitingForForegroundResume(conversationId: $0)
            } ?? false
            if hasBackgroundJob { continue }

            for slot in run.orderedSlots where slot.isActiveOrQueued {
                // Approval waits retain their in-process continuation while the app is suspended.
                // Resume the same run after a decision, including any unconsumed follow-ups.
                if slot.host?.hasPendingToolApproval == true { continue }
                let runId = slot.runId
                cancelUnconsumedFollowups(for: slot, state: run.state)
                if slot.isQueuedForConcurrencySlot {
                    runRegistry.removePendingTask(slotId: slot.slotId)
                    slot.isQueuedForConcurrencySlot = false
                    if let placeholderId = slot.queuedPlaceholderMessageId {
                        slot.queuedPlaceholderMessageId = nil
                        run.state.messages.removeAll {
                            ChatMessageProjector.messageId(for: $0) == placeholderId
                        }
                    }
                    slot.isTerminal = true
                    interruptedRunIds.append(runId)
                } else if let host = slot.host, host.isRunning {
                    host.cancel(cause: .backgroundInterruption)
                    slot.isTerminal = true
                    interruptedRunIds.append(runId)
                }
            }
            if let legacyHost = run.host,
               legacyHost.isRunning,
               !legacyHost.hasPendingToolApproval,
               !run.orderedSlots.contains(where: { $0.host === legacyHost }) {
                if let runId = legacyHost.currentRunId {
                    interruptedRunIds.append(runId)
                }
                legacyHost.cancel(cause: .backgroundInterruption)
            }
            refreshLiveTaskMessageIds(in: run)
        }
        if !interruptedRunIds.isEmpty {
            runActivityRevision &+= 1
        }
        return interruptedRunIds
    }

    // MARK: - Commentary Coalescing & 60s Keepalive Policy

    private func startKeepaliveMonitor(for slot: ChatAsyncTaskSlot, in run: ChatConversationRun) {
        slot.keepaliveMonitorTask?.cancel()
        slot.keepaliveMonitorTask = Task { @MainActor [weak self, weak slot, weak run] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.0))
                guard !Task.isCancelled,
                      let self,
                      let slot,
                      let run,
                      !slot.isTerminal else { return }
                _ = self.evaluateTaskKeepaliveIfNeeded(for: slot, in: run.state)
            }
        }
    }

    /// Evaluates whether `slot` has been silent of meaningful user-visible progress for >= 60s
    /// and emits at most one honest keepalive message per silence window.
    /// Terminal, queued, awaiting-approval, or explicitly stalled/failed tasks never emit keepalive.
    @discardableResult
    func evaluateTaskKeepaliveIfNeeded(
        for slot: ChatAsyncTaskSlot,
        in state: ChatConversationRunState,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> UIMessage? {
        guard !slot.isTerminal,
              !slot.isQueuedForConcurrencySlot,
              slot.explicitFailureOrStallReason == nil,
              slot.activityStage != .failed,
              slot.activityStage != .cancelled,
              slot.activityStage != .completed,
              slot.activityStage != .waitingForConfirmation,
              slot.host?.hasPendingToolApproval != true,
              !slot.hasEmittedKeepaliveInCurrentSilenceWindow else {
            return nil
        }
        let elapsed = now - slot.lastUserVisibleProgressUptime
        guard elapsed >= ChatAsyncTaskSlot.keepaliveSilenceThresholdSeconds else {
            return nil
        }

        slot.hasEmittedKeepaliveInCurrentSilenceWindow = true
        let keepalivePart = UIMessagePart.Text(
            text: ChatAsyncTaskSlot.keepaliveDefaultText,
            metadata: nil
        )
        let keepaliveMsg = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [keepalivePart],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
        slot.keepaliveMessages.append(keepaliveMsg)
        spliceTaskTranscript(slot.currentTranscript, for: slot, into: state)
        if isCurrentConversation(state.conversationId) {
            bumpMessageRevision(reason: .toolResultAppended)
            runActivityRevision &+= 1
        }
        return keepaliveMsg
    }

    static func visibleSyncedProseSignature(in messages: [UIMessage]) -> Int? {
        var hasher = Hasher()
        var count = 0
        let isSegmented = IOSChatRenderPreferences.shared.isSegmentedReplyDelivery
        for msg in messages where msg.role == MessageRole.assistant {
            for part in msg.parts {
                guard let textPart = part as? UIMessagePart.Text else { continue }
                let raw = textPart.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw == ChatAsyncTaskSlot.keepaliveDefaultText {
                    continue
                }
                guard !raw.isEmpty else { continue }
                let isStreamingMsg = msg.finishedAt == nil
                let visibleSlice = (isSegmented && isStreamingMsg)
                    ? ChatSegmentedMarkdownCommitPolicy.committedPrefix(in: textPart.text, isStreaming: true)
                    : raw
                guard !visibleSlice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                hasher.combine(ChatMessageProjector.messageId(for: msg))
                hasher.combine(visibleSlice)
                count += 1
            }
        }
        return count > 0 ? hasher.finalize() : nil
    }
}

/// Balances intermediate assistant commentary bubbles across multi-round ReAct tool execution:
/// 1. Preserves the first substantive acknowledgment; ordinary waiting stays status-only;
/// 2. Preserves all status-only (`isGlobalStatusOnly`) tool/reasoning messages so the single-line
///    progress bar updates in place without ever replacing published prose bubbles;
/// 3. Within the same tool stage/domain (with no tool failure/blocker, no user decision/approval,
///    and no explicit `<amber-commentary milestone="...">` signal), suppresses zero-information-gain
///    duplicate remarks and coalesces fragmented intermediate remarks into that stage's single
///    commentary bubble instead of spawning a new bubble on every tool call;
/// 4. Creates a new intermediate commentary bubble when a real stage change, discovery, direction
///    change, blocker, or user decision occurs, and preserves the final answer bubble intact.
struct ChatTaskCommentaryCoalescer {
    private static let commentaryTagRegex = try! NSRegularExpression(
        pattern: #"<amber-commentary(?:\s+milestone\s*=\s*["']([^"']+)["'])?\s*>(.*?)</amber-commentary>"#,
        options: [.dotMatchesLineSeparators]
    )

    static func normalizedFingerprint(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let zeroInfoWaitingClauses: Set<String> = [
        "收到", "好的", "好", "明白", "我来处理", "我正在处理",
        "正在处理", "仍在处理", "还在处理", "正在处理中", "仍在处理中", "还在处理中",
        "继续处理", "继续处理中", "正在继续", "正在继续处理", "仍在继续处理", "还在继续处理",
        "正在操作", "正在操作中", "仍在操作中", "还在操作中", "继续操作", "继续操作中",
        "正在继续操作", "仍在继续操作", "仍在继续操作中", "还在继续操作", "还在继续操作中",
        "继续下一步", "继续下一步操作", "正在继续下一步", "正在进行下一步",
        "正在执行", "正在执行中", "仍在执行中", "还在执行中",
        "请稍候", "请稍等", "稍候", "稍等", "稍等一下", "稍候片刻", "请稍等一下", "请稍候片刻",
        "马上就好", "马上好", "一会就好", "让我继续", "我继续处理", "仍在继续", "还在继续",
        "still working", "processing", "please wait", "working on it", "hold on", "one moment",
        "continuing", "continuing next step"
    ]

    private static let substantiveSignalKeywords: [String] = [
        "?", "？", "失败", "错误", "异常", "阻断", "超时", "无法", "发现", "检测到",
        "已完成", "完成", "找到", "结果", "确认", "授权", "允许", "注意",
        "failed", "error", "blocked", "found", "completed", "warning"
    ]

    /// True only when `raw` consists exclusively of generic waiting/continuation boilerplate
    /// with zero task-specific nouns, numbers, findings, blockers, or questions.
    static func isZeroInformationWaitingText(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 48 else { return false }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
            return false
        }
        let lower = trimmed.lowercased()
        if substantiveSignalKeywords.contains(where: { lower.contains($0) }) {
            return false
        }
        let separators = CharacterSet(charactersIn: "，,；;。.！!…~\n\r\t")
        let clauses = lower
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clauses.isEmpty else { return false }
        return clauses.allSatisfy { zeroInfoWaitingClauses.contains($0) }
    }

    static func isOrdinaryWaitingText(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == ChatAsyncTaskSlot.keepaliveDefaultText ||
            isZeroInformationWaitingText(text)
    }

    func coalesce(messages: [UIMessage]) -> [UIMessage] {

        var result: [UIMessage] = []
        result.reserveCapacity(messages.count)

        var hasSeenUpfrontAck = false
        var activeStageDomain: String?
        var activeStageCommentaryIndex: Int?
        var activeStagePublishedTexts: [String] = []
        var activeStageIncludesUpfrontAck = false
        var previousRoundHadBlockerOrFailure = false

        for message in messages {
            guard message.role == MessageRole.assistant else {
                result.append(message)
                activeStageDomain = nil
                activeStageCommentaryIndex = nil
                activeStagePublishedTexts.removeAll()
                activeStageIncludesUpfrontAck = false
                previousRoundHadBlockerOrFailure = false
                continue
            }

            if Self.isKeepaliveMessage(message) {
                result.append(message)
                continue
            }

            let tools = message.getTools()
            let (cleanedMessage, explicitMilestone) = Self.extractCommentaryMilestoneAndClean(message)
            let prose = Self.visibleProseText(in: cleanedMessage)
            let hasProse = !prose.isEmpty

            if explicitMilestone == nil && Self.isOrdinaryWaitingText(prose) &&
                !Self.requiresDecisionOrDelegation(tools: tools) {
                result.append(Self.removingTextParts(from: cleanedMessage))
                continue
            }

            // Final answer or pure prose round (no tool calls): always preserve as its own bubble.
            if tools.isEmpty {
                result.append(cleanedMessage)
                if hasProse {
                    activeStageDomain = nil
                    activeStageCommentaryIndex = nil
                    activeStagePublishedTexts.removeAll()
                    activeStageIncludesUpfrontAck = false
                }
                continue
            }

            // Tool-calling round:
            let stageDomain = Self.toolStageDomain(for: tools)
            let currentNeedsUserDecisionOrDelegation = Self.requiresDecisionOrDelegation(tools: tools)
            let currentRoundHasBlocker = Self.hasToolFailureOrBlocker(in: tools)
            defer {
                previousRoundHadBlockerOrFailure = currentRoundHasBlocker
            }

            // Status-only tool round (no prose): keep as-is so single-line progress updates in place.
            guard hasProse else {
                if activeStageDomain == nil {
                    activeStageDomain = stageDomain
                }
                result.append(cleanedMessage)
                continue
            }

            // First upfront acknowledgment with tool call: always preserve!
            if !hasSeenUpfrontAck {
                hasSeenUpfrontAck = true
                activeStageDomain = stageDomain
                activeStageCommentaryIndex = nil
                activeStagePublishedTexts = [prose]
                activeStageIncludesUpfrontAck = true
                result.append(cleanedMessage)
                continue
            }

            let stageChanged = activeStageDomain != nil && activeStageDomain != stageDomain
            let hasExplicitOrUrgentSignal = explicitMilestone != nil ||
                previousRoundHadBlockerOrFailure ||
                currentNeedsUserDecisionOrDelegation

            let isMeaningfulMilestone = hasExplicitOrUrgentSignal || stageChanged

            if isMeaningfulMilestone {
                activeStageDomain = stageDomain
                activeStagePublishedTexts = [prose]
                activeStageIncludesUpfrontAck = false
                activeStageCommentaryIndex = result.endIndex
                result.append(cleanedMessage)
                continue
            }

            // Same stage, no milestone/blocker/decision:
            activeStageDomain = stageDomain
            if activeStagePublishedTexts.contains(prose) {
                // Zero information gain: strip the duplicate text part and keep only the tool/reasoning parts.
                result.append(Self.removingTextParts(from: cleanedMessage))
                continue
            }

            activeStagePublishedTexts.append(prose)
            if let existingIdx = activeStageCommentaryIndex, result.indices.contains(existingIdx) {
                // Coalesce fragmented same-stage commentary into the existing stage commentary bubble,
                // and keep this round's tool call in a status-only message for the single-line progress bar.
                let mergedProse = activeStagePublishedTexts.dropFirst(activeStageIncludesUpfrontAck ? 1 : 0)
                    .joined(separator: "\n\n")
                result[existingIdx] = Self.replacingTextParts(in: result[existingIdx], with: mergedProse)
                result.append(Self.removingTextParts(from: cleanedMessage))
            } else {
                // First intermediate commentary fragment in the initial stage after upfront ack:
                activeStageCommentaryIndex = result.endIndex
                result.append(cleanedMessage)
            }
        }

        return result
    }

    private static func isKeepaliveMessage(_ message: UIMessage) -> Bool {
        message.parts.contains { part in
            guard let textPart = part as? UIMessagePart.Text else { return false }
            if textPart.text.trimmingCharacters(in: .whitespacesAndNewlines) == ChatAsyncTaskSlot.keepaliveDefaultText {
                return true
            }
            return IosToolOutputJsonBridge.shared.metadataString(
                part: textPart,
                key: ChatAsyncTaskSlot.messageRoleMetadataKey
            ) == ChatAsyncTaskSlot.keepaliveMetadataValue
        }
    }

    private static func visibleProseText(in message: UIMessage) -> String {
        message.parts
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingCommentaryTags(in message: UIMessage) -> UIMessage {
        extractCommentaryMilestoneAndClean(message).0
    }

    private static func extractCommentaryMilestoneAndClean(_ message: UIMessage) -> (UIMessage, String?) {
        var foundMilestone: String?
        var changed = false
        let updatedParts: [UIMessagePart] = message.parts.map { part in
            guard let textPart = part as? UIMessagePart.Text else { return part }
            if let metaMilestone = IosToolOutputJsonBridge.shared.metadataString(
                part: textPart,
                key: ChatAsyncTaskSlot.commentaryMilestoneMetadataKey
            ), !metaMilestone.isEmpty {
                foundMilestone = foundMilestone ?? metaMilestone
            }
            let raw = textPart.text
            guard raw.contains("<amber-commentary") else { return part }
            let ns = raw as NSString
            let matches = commentaryTagRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return part }
            changed = true
            let mutable = NSMutableString(string: raw)
            for match in matches.reversed() {
                if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                    let kind = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !kind.isEmpty { foundMilestone = foundMilestone ?? kind }
                } else {
                    foundMilestone = foundMilestone ?? "milestone"
                }
                let inner = match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound
                    ? ns.substring(with: match.range(at: 2))
                    : ""
                mutable.replaceCharacters(in: match.range, with: inner)
            }
            return PromptTranscript.shared.doCopyText(part: textPart, text: mutable as String)
        }
        guard changed else { return (message, foundMilestone) }
        return (
            UIMessage(
                id: message.id,
                role: message.role,
                parts: updatedParts,
                annotations: message.annotations,
                createdAt: message.createdAt,
                finishedAt: message.finishedAt,
                modelId: message.modelId,
                usage: message.usage,
                translation: message.translation
            ),
            foundMilestone
        )
    }

    private static func removingTextParts(from message: UIMessage) -> UIMessage {
        let nonTextParts = message.parts.filter { !($0 is UIMessagePart.Text) }
        guard nonTextParts.count != message.parts.count else { return message }
        return UIMessage(
            id: message.id,
            role: message.role,
            parts: nonTextParts,
            annotations: message.annotations,
            createdAt: message.createdAt,
            finishedAt: message.finishedAt,
            modelId: message.modelId,
            usage: message.usage,
            translation: message.translation
        )
    }

    private static func replacingTextParts(in message: UIMessage, with mergedText: String) -> UIMessage {
        var didReplaceFirstText = false
        var updatedParts: [UIMessagePart] = []
        updatedParts.reserveCapacity(message.parts.count)
        for part in message.parts {
            if let textPart = part as? UIMessagePart.Text {
                if !didReplaceFirstText {
                    didReplaceFirstText = true
                    updatedParts.append(PromptTranscript.shared.doCopyText(part: textPart, text: mergedText))
                }
            } else {
                updatedParts.append(part)
            }
        }
        if !didReplaceFirstText {
            updatedParts.insert(UIMessagePart.Text(text: mergedText, metadata: nil), at: 0)
        }
        return UIMessage(
            id: message.id,
            role: message.role,
            parts: updatedParts,
            annotations: message.annotations,
            createdAt: message.createdAt,
            finishedAt: message.finishedAt,
            modelId: message.modelId,
            usage: message.usage,
            translation: message.translation
        )
    }

    private static func toolStageDomain(for tools: [UIMessagePart.Tool]) -> String {
        guard let first = tools.first?.toolName.lowercased() else { return "general" }
        if first.contains("search_web") || first.contains("scrape_web") || first.contains("web_") {
            return "web_research"
        }
        if first.contains("workspace_") || first.contains("file_") {
            return "workspace"
        }
        if first.contains("memory") || first.contains("wiki_") {
            return "memory"
        }
        if first.contains("spawn_agent") || first.contains("followup_task") || first.contains("wait_agent") || first.contains("list_agents") {
            return "orchestration"
        }
        if first.contains("phone_") || ChatPhoneToolGrouping.isPhoneTool(first) {
            return "phone"
        }
        if first.contains("exec") || first.contains("terminal") || first.contains("ssh") {
            return "terminal"
        }
        if first.contains("ask_user") {
            return "decision"
        }
        return first
    }

    private static func requiresDecisionOrDelegation(tools: [UIMessagePart.Tool]) -> Bool {
        tools.contains { tool in
            let name = tool.toolName.lowercased()
            if name == "ask_user" || name == "spawn_agent" { return true }
            if tool.approvalState is ToolApprovalState.Pending { return true }
            return false
        }
    }

    private static func hasToolFailureOrBlocker(in tools: [UIMessagePart.Tool]) -> Bool {
        for tool in tools {
            if tool.approvalState is ToolApprovalState.Denied { return true }
            let combinedOutput = tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
            if combinedOutput.contains("\"ok\":false") ||
               combinedOutput.contains("\"status\":\"failed\"") ||
               combinedOutput.contains("\"status\":\"blocked\"") ||
               combinedOutput.contains("\"isError\":true") ||
               combinedOutput.contains("[Tool Error]") {
                return true
            }
        }
        return false
    }
}
