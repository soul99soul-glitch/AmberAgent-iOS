import Foundation
@preconcurrency import Shared

/// Tracks run-local Jev and phone progress without deciding run ownership.
@MainActor
final class ChatRunProgressPresentation {
    private enum PhoneProgressContent: Equatable {
        case text(String)
        case reasoning(String)
        case tool(String, String)
    }

    let runId: String
    let startedAt: Int64
    let displayBaseline: [UIMessage]
    private(set) var reportsPhoneWorkProgress: Bool
    private let backgroundExecution: BackgroundGenerationKeepAlive
    private let liveActivityController: AgentLiveActivityController
    private let conversationId: KotlinUuid?
    private let isCurrentRun: () -> Bool
    private var didReportFirstDeltaThisRound = false
    private var didRecordJevFirstDelta = false
    private var jevModelStepCount = 0
    private var lastJevToolOutcomeAssistantMessageId: String?
    private var lastPhoneProgressContent: [PhoneProgressContent] = []
    private var reportedPhoneToolResults: Set<String>

    init(
        runId: String,
        startedAt: Int64,
        displayBaseline: [UIMessage],
        reportsPhoneWorkProgress: Bool,
        initialMessages: [UIMessage],
        backgroundExecution: BackgroundGenerationKeepAlive,
        liveActivityController: AgentLiveActivityController,
        conversationId: KotlinUuid?,
        isCurrentRun: @escaping () -> Bool
    ) {
        self.runId = runId
        self.startedAt = startedAt
        self.displayBaseline = displayBaseline
        self.reportsPhoneWorkProgress = reportsPhoneWorkProgress
        self.backgroundExecution = backgroundExecution
        self.liveActivityController = liveActivityController
        self.conversationId = conversationId
        self.isCurrentRun = isCurrentRun
        self.reportedPhoneToolResults = Set(initialMessages.flatMap(\.parts).compactMap { part in
            guard let tool = part as? UIMessagePart.Tool, !tool.output.isEmpty else { return nil }
            return tool.toolCallId
        })
    }

    func activatePhoneProgress(_ enabled: Bool) {
        reportsPhoneWorkProgress = enabled
    }

    func recordModelStep() { jevModelStepCount += 1 }
    func beginModelRound() {
        lastPhoneProgressContent = []
        didReportFirstDeltaThisRound = false
    }
    func claimFirstJevDelta() -> Bool {
        guard !didRecordJevFirstDelta else { return false }
        didRecordJevFirstDelta = true
        return true
    }

    func beginKeepAlive(subtitle: String, onExpire: @escaping () -> Void) {
        backgroundExecution.begin(
            runId,
            // The system retains this title briefly after completion; the subtitle carries the phase.
            title: "Amber",
            subtitle: subtitle,
            onExpire: onExpire,
            onSystemTaskExpiration: onExpire
        )
        if reportsPhoneWorkProgress {
            backgroundExecution.updateProgress(runId, completed: 0, total: -1)
            backgroundExecution.enableLivenessHeartbeat(runId)
        }
    }

    func publishToolStarted(toolName: String, input: String) {
        backgroundExecution.updateProgress(
            runId,
            completed: reportsPhoneWorkProgress ? 0 : 3,
            total: reportsPhoneWorkProgress ? -1 : 4,
            subtitle: IOSAppLocalization.string("正在执行工具", defaultValue: "正在执行工具")
        )
        let presentation = AgentActivityPresentation.runningTool(toolName: toolName, input: input)
        publish(presentation, force: true)
    }

    func publishAssistantStage(_ stage: AgentActivityStage) {
        publish(.response(stage: stage), force: false)
    }

    func recordFirstJevDelta() {
        if claimFirstJevDelta() {
            let elapsed = max(0, Int64(Date().timeIntervalSince1970 * 1_000) - startedAt)
            IOSJevMetricsStore.appendRunNumbers(runId: runId, numbers: ["first_visible_delta_ms": Double(elapsed)])
        }
    }

    func recordFirstVisibleProgress() {
        guard !didReportFirstDeltaThisRound else { return }
        didReportFirstDeltaThisRound = true
        ChatPerfTrace.event("FirstDelta")
        backgroundExecution.updateProgress(
            runId,
            completed: reportsPhoneWorkProgress ? 0 : 2,
            total: reportsPhoneWorkProgress ? -1 : 4,
            subtitle: IOSAppLocalization.string("正在接收回复", defaultValue: "正在接收回复")
        )
    }

    private func publish(_ presentation: AgentActivityPresentation, force: Bool) {
        WatchTaskCoordinator.shared.publish(
            runId: runId,
            conversationId: conversationId?.toHexDashString(),
            presentation: presentation
        )
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentRun() else { return }
            await self.liveActivityController.update(
                runId: self.runId, presentation: presentation, force: force
            )
        }
    }

    func recordJevRunCompletion(messages: [UIMessage]) {
        var numbers: [String: Double] = ["model_steps": Double(jevModelStepCount)]
        let generated = messages.filter { message in
            message.role == MessageRole.assistant
                && (ChatContextSnapshot.epochMillis(from: message.createdAt) ?? 0) >= startedAt
        }
        let inputTokens = generated.compactMap(\.usage).reduce(0) { $0 + Int($1.promptTokens) }
        let cachedTokens = generated.compactMap(\.usage).reduce(0) { $0 + Int($1.cachedTokens) }
        if inputTokens > 0 {
            numbers["cache_hit_ratio"] = Double(cachedTokens) / Double(inputTokens)
        }
        IOSJevMetricsStore.appendRunNumbers(runId: runId, numbers: numbers)
    }

    func recordJevNextModelStepIfNeeded(_ messages: [UIMessage]) {
        let baselineIds = Set(displayBaseline.map { $0.id.toHexDashString() })
        guard let assistant = messages.reversed().first(where: { message in
                  message.role == MessageRole.assistant
                      && !baselineIds.contains(message.id.toHexDashString())
                      && (ChatContextSnapshot.epochMillis(from: message.createdAt) ?? 0) >= startedAt
              }) else { return }
        let messageId = assistant.id.toHexDashString()
        guard lastJevToolOutcomeAssistantMessageId != messageId else { return }
        let calledToolNames = Set(assistant.parts.compactMap { ($0 as? UIMessagePart.Tool)?.toolName })
        guard !calledToolNames.isEmpty else { return }
        lastJevToolOutcomeAssistantMessageId = messageId
        IOSJevToolDiscoveryMetricsTracker.recordNextModelStep(
            runId: runId,
            calledToolNames: calledToolNames
        )
    }

    func finishJevToolDiscoveryStep(
        messages: [UIMessage],
        terminalStatus: AgentRunStatus
    ) {
        let baselineIds = Set(displayBaseline.map { $0.id.toHexDashString() })
        if terminalStatus == .completed,
           let assistant = messages.reversed().first(where: { message in
               message.role == MessageRole.assistant
                   && !baselineIds.contains(message.id.toHexDashString())
                   && (ChatContextSnapshot.epochMillis(from: message.createdAt) ?? 0) >= startedAt
           }) {
            let messageId = assistant.id.toHexDashString()
            if lastJevToolOutcomeAssistantMessageId != messageId {
                lastJevToolOutcomeAssistantMessageId = messageId
                let calledToolNames = Set(assistant.parts.compactMap { ($0 as? UIMessagePart.Tool)?.toolName })
                IOSJevToolDiscoveryMetricsTracker.recordNextModelStep(
                    runId: runId,
                    calledToolNames: calledToolNames
                )
            }
        }
        IOSJevToolDiscoveryMetricsTracker.discardPending(runId: runId)
    }

    func recordPhoneModelProgress(_ message: UIMessage) {
        let content: [PhoneProgressContent] = message.parts.compactMap { part in
            if let text = part as? UIMessagePart.Text, !text.text.isEmpty {
                return .text(text.text)
            }
            if let reasoning = part as? UIMessagePart.Reasoning, !reasoning.reasoning.isEmpty {
                return .reasoning(reasoning.reasoning)
            }
            if let tool = part as? UIMessagePart.Tool, !tool.input.isEmpty {
                return .tool(tool.toolCallId, tool.input)
            }
            return nil
        }
        // A replayed snapshot or a metadata-only chunk is not additional work.
        guard !content.isEmpty, content != lastPhoneProgressContent else { return }
        lastPhoneProgressContent = content
        backgroundExecution.advanceProgress(runId)
    }

    func recordPhoneToolResultProgress(_ messages: [UIMessage]) {
        let completed = Set(messages.flatMap(\.parts).compactMap { part -> String? in
            guard let tool = part as? UIMessagePart.Tool, !tool.output.isEmpty else { return nil }
            return tool.toolCallId
        })
        let newResults = completed.subtracting(reportedPhoneToolResults)
        reportedPhoneToolResults.formUnion(completed)
        guard !newResults.isEmpty else { return }
        backgroundExecution.advanceProgress(runId, by: Int64(newResults.count))
    }

}
