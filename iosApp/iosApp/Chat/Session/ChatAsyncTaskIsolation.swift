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
    var activityStage: AgentActivityStage = .preparing
    var activeToolName: String?
    var activeToolTitle: String?
    var plannedActivityStages: [String] = []
    var stagePlanStartedUptime: TimeInterval?
    var liveReasoningSummary: String?
    var reasoningSummaryUpdatedUptime: TimeInterval = 0
    var lastActivityUptime = ProcessInfo.processInfo.systemUptime

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
        let newGenerated = taskTranscript.filter { msg in
            !slot.baselineMessageIds.contains(ChatMessageProjector.messageId(for: msg))
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
}
