import Observation
import SwiftUI

/// The provider owns terminal work; this owner only waits for the visible reply's reveal.
@MainActor @Observable
final class ChatCompletionFeedback {
    private(set) var runID: String?
    @ObservationIgnored private var isForegroundVisible = false
    @ObservationIgnored private var terminalReceived = false
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private var drainedParts: [Part: String] = [:]
    @ObservationIgnored private let trigger: () -> Void

    private struct Part: Hashable {
        let messageID: String
        let index: Int
    }

    private struct Pending {
        let messageID: String
        let textParts: [Int: String]
    }

    init(trigger: @escaping () -> Void = { AmberHaptics.triggerCompletion(.rigidImpact) }) {
        self.trigger = trigger
    }

    func begin(runID: String) {
        guard self.runID != runID else { return }
        self.runID = runID
        terminalReceived = false
        pending = nil
        drainedParts = [:]
    }

    func setForegroundVisible(_ visible: Bool) {
        isForegroundVisible = visible
        if !visible { pending = nil }
    }

    func complete(runID: String, messageID: String, textParts: [Int: String]) {
        guard self.runID == runID, !terminalReceived else { return }
        terminalReceived = true
        guard isForegroundVisible, !textParts.isEmpty else { return }
        pending = Pending(messageID: messageID, textParts: textParts)
        deliverIfDrained()
    }

    func finishWithoutFeedback(runID: String) {
        guard self.runID == runID else { return }
        terminalReceived = true
        pending = nil
    }

    func didDrain(runID: String, messageID: String, partIndex: Int, text: String) {
        guard self.runID == runID else { return }
        drainedParts[Part(messageID: messageID, index: partIndex)] = text
        deliverIfDrained()
    }

    private func deliverIfDrained() {
        guard isForegroundVisible, let pending,
              pending.textParts.allSatisfy({ index, text in
                  drainedParts[Part(messageID: pending.messageID, index: index)] == text
              }) else { return }
        self.pending = nil
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
