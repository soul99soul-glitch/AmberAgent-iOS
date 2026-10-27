import Foundation

enum DesktopProviderEvent: Sendable {
    case snapshot(text: String, reasoning: String, canonicalJSON: String? = nil, unsupportedPartCount: Int = 0)
    case transcript([DesktopMessage])
    case complete
    case failed(String)
    case cancelled
}

// The queue owns accepted events until the main actor claims them, including at Stop.
final class DesktopGeneration: @unchecked Sendable {
    let signals: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var pending: [DesktopProviderEvent] = []
    private var terminal = false
    private var cancellationRequested = false
    private let cancellationCompletesAsynchronously: Bool
    private var cancellation: (@Sendable () -> Void)?
    private var cancellationFlush: (@Sendable () -> Void)?

    init(cancellationCompletesAsynchronously: Bool = false) {
        self.cancellationCompletesAsynchronously = cancellationCompletesAsynchronously
        // One pending wake-up is enough: drain() always takes every queued event.
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = stream.stream
        signal = stream.continuation
    }

    func installCancellation(_ action: @escaping @Sendable () -> Void,
                             flushBeforeCancellation: (@Sendable () -> Void)? = nil) {
        lock.lock()
        if !terminal {
            cancellation = action
            cancellationFlush = flushBeforeCancellation
        }
        let didFinish = terminal
        lock.unlock()
        if didFinish { action() }
    }

    func yield(_ event: DesktopProviderEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return }
        let accepted: DesktopProviderEvent
        if cancellationRequested {
            switch event {
            case .complete, .failed: accepted = .cancelled
            default: accepted = event
            }
        } else { accepted = event }
        pending.append(accepted)
        switch accepted {
        case .snapshot, .transcript: break
        case .complete, .failed, .cancelled:
            terminal = true
            cancellation = nil
            cancellationFlush = nil
        }
        signal.yield(())
        if terminal { signal.finish() }
    }

    func drain() -> [DesktopProviderEvent] {
        lock.lock()
        defer { lock.unlock() }
        let result = pending
        pending.removeAll(keepingCapacity: true)
        return result
    }

    func cancel() {
        lock.lock()
        guard !terminal, !cancellationRequested else { lock.unlock(); return }
        cancellationRequested = true
        let action = cancellation
        let flush = cancellationFlush
        cancellation = nil
        cancellationFlush = nil
        lock.unlock()
        flush?()
        if !cancellationCompletesAsynchronously { yield(.cancelled) }
        action?()
    }
}

@MainActor protocol DesktopTextProvider {
    func userMessage(id: UUID, text: String, attachments: [DesktopMessageAttachment]) throws -> DesktopMessage
    func start(configuration: DesktopProviderConfiguration, apiKey: String,
        messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration
    func start(configuration: DesktopProviderConfiguration, apiKey: String,
        messages: [DesktopMessage], responseID: UUID, context: DesktopRunContext) throws -> DesktopGeneration
}

struct DesktopRunContext: Sendable {
    let conversationID: UUID
    let toolsEnabled: Bool
    let subagentsEnabled: Bool
    var engineEnabled: Bool { toolsEnabled || subagentsEnabled }
    /// nil = the global auto-approve switches; scheduled/unattended runs pass their own.
    let approvalPolicy: DesktopApprovalPolicy?
    let persistTurns: (@MainActor @Sendable ([DesktopMessage]) async -> Bool)?
    let drainSteer: (@MainActor @Sendable () async -> [DesktopMessage])?

    init(conversationID: UUID, toolsEnabled: Bool, subagentsEnabled: Bool = false, approvalPolicy: DesktopApprovalPolicy? = nil,
        persistTurns: (@MainActor @Sendable ([DesktopMessage]) async -> Bool)? = nil,
        drainSteer: (@MainActor @Sendable () async -> [DesktopMessage])? = nil) {
        self.conversationID = conversationID; self.toolsEnabled = toolsEnabled
        self.subagentsEnabled = subagentsEnabled; self.approvalPolicy = approvalPolicy; self.persistTurns = persistTurns
        self.drainSteer = drainSteer
    }
}

extension DesktopTextProvider {
    func start(configuration: DesktopProviderConfiguration, apiKey: String,
        messages: [DesktopMessage], responseID: UUID, context: DesktopRunContext) throws -> DesktopGeneration {
        try start(configuration: configuration, apiKey: apiKey, messages: messages, responseID: responseID)
    }
}

