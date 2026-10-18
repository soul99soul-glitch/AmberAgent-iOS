import Foundation

struct NovelSessionPresentationBuffer {
    let runID: NovelRunID
    let messageID: NovelMessageID
    let bindingToken: UUID
    // Normalizing the display target must retain fence context for the next delta.
    private(set) var rawContent: String
    private var cursor: NovelSessionPresentationPacer.Cursor

    var targetContent: String { cursor.targetContent }
    var targetCharacterCount: Int { cursor.targetCharacterCount }
    var displayedCharacterCount: Int { cursor.displayedCharacterCount }

    init(
        runID: NovelRunID,
        messageID: NovelMessageID,
        bindingToken: UUID,
        baseContent: String = "",
        rawContent: String? = nil
    ) {
        self.runID = runID
        self.messageID = messageID
        self.bindingToken = bindingToken
        self.rawContent = rawContent ?? baseContent
        cursor = NovelSessionPresentationPacer.Cursor(
            displayedContent: baseContent,
            targetContent: baseContent
        )
    }

    mutating func append(_ text: String) {
        rawContent.append(text)
        cursor.appendTarget(text)
    }

    mutating func replace(with text: String) {
        rawContent = text
        cursor.replaceTarget(text)
    }

    mutating func replacePresentationTarget(with text: String) {
        cursor.replaceTarget(text)
    }

    mutating func step(
        mode: NovelSessionPresentationPacer.Mode = .streaming,
        fixedTerminalAdvance: Int? = nil
    ) -> NovelSessionPresentationPacer.Step {
        cursor.step(mode: mode, fixedTerminalAdvance: fixedTerminalAdvance)
    }

    func matches(
        runID: NovelRunID,
        messageID: NovelMessageID,
        bindingToken: UUID
    ) -> Bool {
        self.runID == runID &&
            self.messageID == messageID &&
            self.bindingToken == bindingToken
    }
}

/// Pure presentation drain for novel streaming.
///
/// The per-tick advance policy comes from `StreamPresentationPacingPolicy`;
/// this type only adapts it to the novel session's single-String shape.
/// Terminal drain uses the shared continuous whoosh curve (fixed advance
/// anchor + dynamic tick interval), not the live streaming 36-char cap.
enum NovelSessionPresentationPacer {
    enum Mode {
        case streaming
        case terminalDrain
    }

    static var minimumTextAdvance: Int { StreamPresentationPacingPolicy.minimumTextAdvance }
    static var maximumTextAdvance: Int { StreamPresentationPacingPolicy.maximumTextAdvance }
    static var preferredDrainTicks: Int { StreamPresentationPacingPolicy.preferredDrainTicks }

    struct Step: Equatable {
        let content: String
        let isCaughtUp: Bool
    }

    /// Holds the character counts and the next target index across 48ms ticks.
    /// Appends only count the new chunk and a possible joining grapheme at the
    /// boundary; replacement output is re-anchored once on its next step.
    struct Cursor {
        private(set) var targetContent: String
        private(set) var displayedContent: String
        private(set) var targetCharacterCount: Int
        private(set) var displayedCharacterCount: Int
        private var displayedTargetIndex: String.Index
        private var alignedWithTarget: Bool
        private var sharedPrefixCharacterCount: Int
        private var needsReanchor = false

        var backlogCount: Int {
            max(0, targetCharacterCount - displayedCharacterCount)
        }

        var terminalDrainStartBacklog: Int {
            alignedWithTarget ? backlogCount : targetCharacterCount
        }

        init(displayedContent: String, targetContent: String) {
            self.targetContent = targetContent
            self.displayedContent = displayedContent
            targetCharacterCount = targetContent.count
            displayedCharacterCount = displayedContent.count
            if targetContent.hasPrefix(displayedContent) {
                alignedWithTarget = true
                sharedPrefixCharacterCount = displayedCharacterCount
                displayedTargetIndex = targetContent.index(
                    targetContent.startIndex,
                    offsetBy: displayedCharacterCount
                )
            } else {
                alignedWithTarget = false
                sharedPrefixCharacterCount = displayedContent.commonPrefix(
                    with: targetContent
                ).count
                displayedTargetIndex = targetContent.index(
                    targetContent.startIndex,
                    offsetBy: sharedPrefixCharacterCount
                )
            }
        }

        mutating func appendTarget(_ text: String) {
            guard !text.isEmpty else { return }
            let appendedCharacterCount: Int
            if let lastCharacter = targetContent.last {
                // Appending can merge the old final grapheme with the new first
                // scalar (combining marks, emoji modifiers, and joiner chains).
                appendedCharacterCount = (String(lastCharacter) + text).count - 1
            } else {
                appendedCharacterCount = text.count
            }
            targetContent.append(text)
            targetCharacterCount += appendedCharacterCount
            if appendedCharacterCount != text.count {
                // The old end index may now sit inside a newly formed grapheme.
                alignedWithTarget = false
                needsReanchor = true
            }
        }

        mutating func replaceTarget(_ text: String) {
            guard targetContent != text else { return }
            targetContent = text
            targetCharacterCount = text.count
            alignedWithTarget = false
            needsReanchor = true
        }

        mutating func step(
            mode: Mode = .streaming,
            fixedTerminalAdvance: Int? = nil
        ) -> Step {
            if needsReanchor {
                sharedPrefixCharacterCount = displayedContent.commonPrefix(
                    with: targetContent
                ).count
                displayedTargetIndex = targetContent.index(
                    targetContent.startIndex,
                    offsetBy: sharedPrefixCharacterCount
                )
                alignedWithTarget = false
                needsReanchor = false
            }

            if alignedWithTarget, backlogCount == 0 {
                displayedCharacterCount = targetCharacterCount
                displayedContent = targetContent
                displayedTargetIndex = targetContent.endIndex
                return Step(content: targetContent, isCaughtUp: true)
            }

            let advanceBudget: (Int) -> Int = { backlog in
                switch mode {
                case .streaming:
                    return NovelSessionPresentationPacer.textAdvance(backlogCount: backlog)
                case .terminalDrain:
                    return StreamPresentationPacingPolicy.terminalTextAdvance(
                        backlogCount: backlog,
                        fixedAdvance: fixedTerminalAdvance
                    )
                }
            }

            let nextIndex: String.Index
            if alignedWithTarget {
                let advance = min(backlogCount, advanceBudget(backlogCount))
                nextIndex = targetContent.index(displayedTargetIndex, offsetBy: advance)
                displayedCharacterCount += advance
            } else {
                let backlog = max(0, targetCharacterCount - sharedPrefixCharacterCount)
                let advance = max(
                    advanceBudget(backlog),
                    NovelSessionPresentationPacer.minimumTextAdvance
                )
                let nextCount = min(targetCharacterCount, sharedPrefixCharacterCount + advance)
                nextIndex = targetContent.index(
                    displayedTargetIndex,
                    offsetBy: nextCount - sharedPrefixCharacterCount
                )
                displayedCharacterCount = nextCount
                alignedWithTarget = true
            }

            displayedTargetIndex = nextIndex
            displayedContent = String(targetContent[..<nextIndex])
            return Step(
                content: displayedContent,
                isCaughtUp: displayedCharacterCount == targetCharacterCount
            )
        }
    }

    static func textAdvance(backlogCount: Int) -> Int {
        StreamPresentationPacingPolicy.textAdvance(backlogCount: backlogCount)
    }

    static func terminalDrainAdvance(backlogCount: Int) -> Int {
        StreamPresentationPacingPolicy.terminalDrainAdvance(backlogCount: backlogCount)
    }

    static func terminalDrainDelayNanos(advance: Int) -> UInt64 {
        StreamPresentationPacingPolicy.terminalDrainDelayNanos(advance: advance)
    }

    /// Manuscript kinds strip accidental ``` fences in the presentation buffer so
    /// pacer + bubble share one string (no dual strip / height snap).
    static func presentationContent(_ text: String, runKind: NovelRunKind?) -> String {
        switch runKind {
        case .prose, .regenerate, .polish:
            return NovelPromptCatalog.normalizedStreamingCandidateProse(text)
        case .quickStart, .characterProposal, .discussion, nil:
            return text
        }
    }

    static func step(
        displayedContent: String,
        targetContent: String,
        mode: Mode = .streaming,
        fixedTerminalAdvance: Int? = nil
    ) -> Step {
        if displayedContent == targetContent {
            return Step(content: targetContent, isCaughtUp: true)
        }
        let advanceBudget: (Int) -> Int = { backlog in
            switch mode {
            case .streaming:
                return textAdvance(backlogCount: backlog)
            case .terminalDrain:
                return StreamPresentationPacingPolicy.terminalTextAdvance(
                    backlogCount: backlog,
                    fixedAdvance: fixedTerminalAdvance
                )
            }
        }
        if targetContent.hasPrefix(displayedContent) {
            let backlog = targetContent.count - displayedContent.count
            let advance = advanceBudget(backlog)
            let next = String(targetContent.prefix(displayedContent.count + advance))
            return Step(content: next, isCaughtUp: next == targetContent)
        }
        // Replacement / divergence: re-anchor on the longest common prefix and
        // pace toward the new target — never dump multi-k chars in one frame.
        let sharedCount = displayedContent.commonPrefix(with: targetContent).count
        let backlog = max(0, targetContent.count - sharedCount)
        let advance = max(advanceBudget(backlog), minimumTextAdvance)
        let nextCount = min(targetContent.count, sharedCount + advance)
        let next = String(targetContent.prefix(nextCount))
        return Step(content: next, isCaughtUp: next == targetContent)
    }

    /// Visible pacing base when terminal manuscript normalization may have
    /// stripped a streaming fence that the bubble already hid.
    static func terminalPacingBase(
        displayedContent: String,
        targetContent: String,
        runKind: NovelRunKind?
    ) -> String {
        let display = presentationContent(displayedContent, runKind: runKind)
        if targetContent.hasPrefix(display) { return display }
        return displayedContent
    }

    static func terminalStep(
        displayedContent: String,
        targetContent: String,
        runKind: NovelRunKind?,
        fixedTerminalAdvance: Int? = nil
    ) -> Step {
        let pacingBase = terminalPacingBase(
            displayedContent: displayedContent,
            targetContent: targetContent,
            runKind: runKind
        )
        return step(
            displayedContent: pacingBase,
            targetContent: targetContent,
            mode: .terminalDrain,
            fixedTerminalAdvance: fixedTerminalAdvance
        )
    }
}

