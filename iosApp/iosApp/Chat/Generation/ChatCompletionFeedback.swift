import Observation
import SwiftUI

/// The provider owns terminal work; this owner only waits for the visible reply's reveal.
@MainActor @Observable
final class ChatCompletionFeedback: Equatable {
    nonisolated static func == (lhs: ChatCompletionFeedback, rhs: ChatCompletionFeedback) -> Bool {
        lhs === rhs
    }
    private(set) var runID: String?
    private(set) var hasActiveOrDrainingRun = false
    @ObservationIgnored private(set) var isForegroundVisible = false
    @ObservationIgnored private var runs: [String: RunState] = [:]
    @ObservationIgnored private var messageRunIDs: [String: String] = [:]
    @ObservationIgnored private let trigger: () -> Void

    private struct Part: Hashable {
        let messageID: String
        let index: Int
    }

    private struct Pending {
        let messageID: String
        let textParts: [Int: String]
    }

    private struct RunState {
        var terminalReceived = false
        var pending: Pending?
        var drainedParts: [Part: String] = [:]
        var completionAnimations: [Part: () -> Void] = [:]
    }

    init(trigger: @escaping () -> Void = { AmberHaptics.triggerCompletion(.rigidImpact) }) {
        self.trigger = trigger
    }

    private func syncActiveOrDrainingState() {
        let next = runs.values.contains { !$0.terminalReceived || $0.pending != nil }
        if hasActiveOrDrainingRun != next {
            hasActiveOrDrainingRun = next
        }
    }

    /// Reads the latest `runID` without registering an `@Observable` access on the calling SwiftUI view,
    /// preventing `begin(runID:)` from invalidating settled historical reveal pacers.
    func untrackedCurrentRunID() -> String? {
        _runID
    }

    var drainingMessageIDs: Set<String> {
        Set(runs.values.compactMap { $0.pending?.messageID })
    }

    func runID(forMessageID messageID: String?) -> String? {
        guard let messageID,
              let mappedRunID = messageRunIDs[messageID],
              runs[mappedRunID]?.pending != nil else {
            return nil
        }
        return mappedRunID
    }

    func begin(runID: String) {
        guard self.runID != runID else { return }
        self.runID = runID
        runs[runID] = RunState()
        syncActiveOrDrainingState()
    }

    func setForegroundVisible(_ visible: Bool) {
        isForegroundVisible = visible
        if !visible {
            for key in runs.keys {
                runs[key]?.pending = nil
                runs[key]?.completionAnimations.removeAll()
            }
            syncActiveOrDrainingState()
        }
    }

    func complete(runID: String, messageID: String, textParts: [Int: String]) {
        guard var state = runs[runID], !state.terminalReceived else { return }
        state.terminalReceived = true
        messageRunIDs[messageID] = runID
        guard isForegroundVisible, !textParts.isEmpty else {
            state.completionAnimations.removeAll()
            runs[runID] = state
            syncActiveOrDrainingState()
            return
        }
        state.pending = Pending(messageID: messageID, textParts: textParts)
        runs[runID] = state
        deliverIfDrained(for: runID)
        syncActiveOrDrainingState()
    }

    func finishWithoutFeedback(runID: String) {
        guard var state = runs[runID] else { return }
        state.terminalReceived = true
        state.pending = nil
        state.completionAnimations.removeAll()
        runs[runID] = state
        syncActiveOrDrainingState()
    }

    func didDrain(runID: String, messageID: String, partIndex: Int, text: String,
                  onCompletion: (() -> Void)? = nil) {
        guard var state = runs[runID] else { return }
        let part = Part(messageID: messageID, index: partIndex)
        state.drainedParts[part] = text
        if !state.terminalReceived || state.pending != nil {
            state.completionAnimations[part] = onCompletion
        }
        runs[runID] = state
        deliverIfDrained(for: runID)
    }

    private func deliverIfDrained(for runID: String) {
        guard isForegroundVisible,
              var state = runs[runID],
              let pending = state.pending,
              pending.textParts.allSatisfy({ index, text in
                  state.drainedParts[Part(messageID: pending.messageID, index: index)] == text
              }) else { return }
        let animations = pending.textParts.keys.compactMap {
            state.completionAnimations[Part(messageID: pending.messageID, index: $0)]
        }
        state.pending = nil
        state.completionAnimations.removeAll()
        runs[runID] = state
        syncActiveOrDrainingState()
        animations.forEach { $0() }
        // Read the preference at delivery, including changes made while the tail drained.
        trigger()
    }
}

private struct ChatCompletionFeedbackKey: EnvironmentKey {
    static let defaultValue: ChatCompletionFeedback? = nil
}

extension EnvironmentValues {
    var chatCompletionFeedback: ChatCompletionFeedback? {
        get { self[ChatCompletionFeedbackKey.self] }
        set { self[ChatCompletionFeedbackKey.self] = newValue }
    }
}

struct ChatCompletionFeedbackVisibility: ViewModifier {
    let owner: ChatCompletionFeedback
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { owner.setForegroundVisible(isVisible) }
            .onChange(of: isVisible) { _, visible in owner.setForegroundVisible(visible) }
            .onDisappear { owner.setForegroundVisible(false) }
    }
}

/// A completion pulse changes only the reply's compositing opacity, never its measured size.
@MainActor @Observable
final class ChatReplyCompletionAnimation {
    private(set) var opacity = 1.0
    #if DEBUG
    static var onPhaseForTesting: ((Double) -> Void)?
    #endif

    func play(reduceMotion: Bool) {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.10)) { opacity = 0.72 }
        #if DEBUG
        Self.onPhaseForTesting?(opacity)
        #endif
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(.easeIn(duration: 0.18)) { opacity = 1 }
            #if DEBUG
            Self.onPhaseForTesting?(opacity)
            #endif
        }
    }
}
