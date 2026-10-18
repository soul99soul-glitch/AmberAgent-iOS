@preconcurrency import BackgroundTasks
import Foundation
import OSLog
import UIKit
@preconcurrency import Shared

/// A run belongs to the coordinator, not to a scheduler callback. New runs
/// execute immediately under KeepAlive; persisted legacy .chat requests may
/// still arrive with a system task and use the same completion path.
final class IOSChatBackgroundExecution: @unchecked Sendable {
    let identifier: String
    let progress: Progress
    let systemTask: BGContinuedProcessingTask?
    private let keepAlive: BackgroundGenerationKeepAlive
    private let leaseId: String

    @MainActor var expirationHandler: (() -> Void)? {
        didSet { systemTask?.expirationHandler = expirationHandler }
    }

    init(identifier: String, systemTask: BGContinuedProcessingTask? = nil,
         keepAlive: BackgroundGenerationKeepAlive, leaseId: String) {
        self.identifier = identifier
        self.systemTask = systemTask
        self.progress = systemTask?.progress ?? Progress(totalUnitCount: 4)
        self.keepAlive = keepAlive
        self.leaseId = leaseId
    }

    @MainActor func updateTitle(_ title: String, subtitle: String) {
        systemTask?.updateTitle(title, subtitle: subtitle)
        keepAlive.updateProgress(leaseId, completed: progress.completedUnitCount,
                                total: progress.totalUnitCount, subtitle: subtitle)
    }

    @MainActor func advancePhoneWorkProgress(by units: Int64) {
        if systemTask != nil {
            progress.completedUnitCount += units
        }
        // Local continuation can reuse a lease that already reported work.
        keepAlive.advanceProgress(leaseId, by: units)
    }

    func setTaskCompleted(success: Bool) {
        systemTask?.setTaskCompleted(success: success)
    }
}

final class IOSChatBackgroundRunState: @unchecked Sendable {
    enum TerminalOwner: Equatable {
        case completion
        case expiration
        case cancellation
    }

    enum ExpirationClaim: Equatable {
        case persistFailure
        case terminateInFlightSave
        case rejected
    }

    private let lock = NSLock()
    private var terminalOwner: TerminalOwner?
    private var terminalFinalized = false
    private var systemTaskCompletionClaimed = false
    private var operationTask: Task<IOSAgentToolEngineResult, Never>?
    private var expiredOperationTask: Task<IOSAgentToolEngineResult, Never>?
    private var speedClock = ChatGenerationSpeedClock()
    private var presentationStage: AgentActivityStage = .preparing
    private var lastProgressRefreshAt: Date?
    private var phoneProgressText = ""
    private var phoneProgressReasoning = ""
    private var reportedPhoneToolResults: Set<String> = []

    var isExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalOwner == .expiration || terminalOwner == .cancellation
    }

    var allowsRunningPresentation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalOwner == nil && !terminalFinalized
    }

    func expireAndReserveTerminal(requireUnclaimed: Bool = false) -> ExpirationClaim {
        let task: Task<IOSAgentToolEngineResult, Never>?
        lock.lock()
        guard (!requireUnclaimed || terminalOwner == nil),
              terminalOwner != .expiration,
              terminalOwner != .cancellation,
              !terminalFinalized else {
            lock.unlock()
            return .rejected
        }
        let claim: ExpirationClaim = terminalOwner == nil
            ? .persistFailure
            : .terminateInFlightSave
        terminalOwner = .expiration
        task = operationTask
        operationTask = nil
        expiredOperationTask = task
        lock.unlock()
        task?.cancel()
        return claim
    }

    func waitForExpiredOperationExit() async {
        let task = lock.withLock { expiredOperationTask }
        _ = await task?.value
        lock.withLock {
            expiredOperationTask = nil
        }
    }

    func cancelAndReserveTerminal() -> Bool {
        let task: Task<IOSAgentToolEngineResult, Never>?
        lock.lock()
        guard terminalOwner == nil, !terminalFinalized else {
            lock.unlock()
            return false
        }
        terminalOwner = .cancellation
        task = operationTask
        operationTask = nil
        expiredOperationTask = task
        lock.unlock()
        task?.cancel()
        return true
    }

    func resetGenerationRound() {
        lock.lock()
        speedClock.resetRound()
        presentationStage = .preparing
        phoneProgressText = ""
        phoneProgressReasoning = ""
        lock.unlock()
    }

    func claimPhoneContentProgress(_ content: String, reasoning: Bool = false) -> Bool {
        guard !content.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard terminalOwner == nil, !terminalFinalized else { return false }
        if reasoning {
            guard content != phoneProgressReasoning else { return false }
            phoneProgressReasoning = content
        } else {
            guard content != phoneProgressText else { return false }
            phoneProgressText = content
        }
        return true
    }

    func claimPhoneToolResultProgress(in messages: [UIMessage]) -> Int64 {
        let completed = Set(messages.flatMap(\.parts).compactMap { part -> String? in
            guard let tool = part as? UIMessagePart.Tool, !tool.output.isEmpty else { return nil }
            return tool.toolCallId
        })
        lock.lock()
        defer { lock.unlock() }
        guard terminalOwner == nil, !terminalFinalized else { return 0 }
        let count = completed.subtracting(reportedPhoneToolResults).count
        reportedPhoneToolResults.formUnion(completed)
        return Int64(count)
    }

    func nextPresentationStage(_ candidate: AgentActivityStage) -> AgentActivityStage? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = AgentActivityResponseStagePolicy.nextPublishedStage(
            current: presentationStage,
            candidate: candidate
        ) else {
            return nil
        }
        presentationStage = next
        return next
    }

    func shouldPublishPresentationStage(_ stage: AgentActivityStage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalOwner == nil
            && !terminalFinalized
            && presentationStage == stage
    }

    /// 返回 true 表示该给 Live Activity 续期了（锁内节流，逐 chunk 调用也只放行一次/间隔）。
    @discardableResult
    func noteVisibleDelta(at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        speedClock.noteVisibleDelta(at: date)
        if let lastProgressRefreshAt,
           date.timeIntervalSince(lastProgressRefreshAt) < AgentActivityLifecyclePolicy.progressRefreshInterval {
            return false
        }
        lastProgressRefreshAt = date
        return true
    }

    func generationDuration() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return speedClock.duration()
    }

    func installOperationTask(_ task: Task<IOSAgentToolEngineResult, Never>) {
        lock.lock()
        let shouldCancel = terminalOwner == .expiration || terminalOwner == .cancellation
        if !shouldCancel {
            operationTask = task
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func clearOperationTask() {
        lock.lock()
        operationTask = nil
        lock.unlock()
    }

    func reserveTerminal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard terminalOwner == nil, !terminalFinalized else { return false }
        terminalOwner = .completion
        operationTask = nil
        return true
    }

    func finalizeTerminal(as owner: TerminalOwner = .completion) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard terminalOwner == owner, !terminalFinalized else { return false }
        terminalFinalized = true
        return true
    }

    func terminalWasFinalized(by owner: TerminalOwner) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalOwner == owner && terminalFinalized
    }

    func terminalIsOwned(by owner: TerminalOwner) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalOwner == owner
    }

    func claimSystemTaskCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !systemTaskCompletionClaimed else { return false }
        systemTaskCompletionClaimed = true
        return true
    }
}

final class IOSChatBackgroundAssistantTextSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var latestText = ""

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return latestText
    }

    func replace(with text: String) {
        lock.lock()
        latestText = text
        lock.unlock()
    }
}

final class IOSChatBackgroundMessagesSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var latestMessages: [UIMessage]
    private var durableResponseSequenceNumber: Int64?

    init(_ messages: [UIMessage]) {
        latestMessages = messages
    }

    var messages: [UIMessage] {
        lock.lock()
        defer { lock.unlock() }
        return latestMessages
    }

    func replace(with messages: [UIMessage]) {
        lock.lock()
        latestMessages = messages
        lock.unlock()
    }

    func publishDurableResponseCheckpoint(with messages: [UIMessage], sequenceNumber: Int64) {
        lock.lock()
        defer { lock.unlock() }
        // Reconnect replays from event zero. Keep the previous connection's
        // complete snapshot until this replay has caught up to its event.
        if let durableResponseSequenceNumber, sequenceNumber < durableResponseSequenceNumber { return }
        latestMessages = messages
        durableResponseSequenceNumber = sequenceNumber
    }
}

final class IOSChatDurableResponseAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let displayMessages: [UIMessage]
    private let messagesSnapshot: IOSChatBackgroundMessagesSnapshot
    private let seedId: KotlinUuid
    private let accumulator: MessageStreamAccumulator

    init(displayMessages: [UIMessage], model: Model, messagesSnapshot: IOSChatBackgroundMessagesSnapshot) {
        self.displayMessages = displayMessages
        self.messagesSnapshot = messagesSnapshot
        let seedId = KotlinUuid.companion.random()
        self.seedId = seedId
        // Resume 从 response 事件 0 重新投影。不能用历史最后一条 assistant
        // 初始化 accumulator，否则新 response 会拼进上一轮气泡。
        let seed = UIMessage(
            id: seedId,
            role: MessageRole.user,
            parts: [UIMessagePart.Text(text: "", metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
        accumulator = MessageStreamAccumulator(initialMessages: [seed], model: model)
    }

    func append(_ chunk: MessageChunk) {
        lock.lock()
        defer { lock.unlock() }
        accumulator.append(chunk: chunk)
    }

    func recordCheckpoint(sequenceNumber: Int64) {
        lock.lock()
        defer { lock.unlock() }
        // The transport checkpoints after delivering every chunk for this event.
        messagesSnapshot.publishDurableResponseCheckpoint(
            with: combinedMessages(), sequenceNumber: sequenceNumber
        )
    }

    var messages: [UIMessage] {
        lock.lock()
        defer { lock.unlock() }
        return combinedMessages()
    }

    private func combinedMessages() -> [UIMessage] {
        displayMessages + accumulator.snapshot().filter { $0.id != seedId }
    }
}

final class IOSChatDurableResumeCompletion: @unchecked Sendable {
    enum Outcome {
        case completed
        case disconnected(String)
        case failed(String)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var pendingOutcome: Outcome?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Outcome, Never>) {
        lock.lock()
        if let pendingOutcome {
            self.pendingOutcome = nil
            lock.unlock()
            continuation.resume(returning: pendingOutcome)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ outcome: Outcome) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: outcome)
        } else {
            pendingOutcome = outcome
            lock.unlock()
        }
    }
}

