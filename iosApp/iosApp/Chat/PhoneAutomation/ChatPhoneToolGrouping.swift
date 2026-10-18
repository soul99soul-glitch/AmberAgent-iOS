import Foundation
import Shared

// MARK: - Phone automation step grouping (L1)

/// Something inside a phone-step group the user must see without expanding it.
/// Raw values order severity.
enum ChatPhoneToolGroupAttention: Int, Equatable {
    /// The latest step failed.
    case failed = 1
    /// A step's action may have run but its result was lost; the user must check the phone.
    case outcomeUnknown = 2
    /// A step is waiting for the user's approval.
    case approvalPending = 3
}

/// Projection of one run of consecutive phone-automation tool steps, rendered as
/// one collapsible row by its head message. Pure value: produced by
/// `ChatPhoneToolGrouping.annotate` from the L0 messages + expansion state.
struct ChatPhoneToolGroupSummary {
    /// UUID of the run's first phone message (even when it precedes the loaded
    /// window). Stable while the run grows and across history reveal; expansion key.
    let id: String
    let headMessageID: String
    let stepCount: Int
    let latestTool: UIMessagePart.Tool
    let attention: ChatPhoneToolGroupAttention?
    let attentionCount: Int
    /// The run is still being extended by the active generation.
    let isLive: Bool
    let startedAt: Date?
    /// nil while live.
    let finishedAt: Date?
    let isExpanded: Bool
    /// Content (height-affecting) signature of the collapsed/expanded header.
    let signature: Int

    var anchorID: String { "phone-tool-group-\(id)" }
}

/// Role of a timeline message entry inside a phone-step group.
///
/// Every member keeps its own `message-<id>` entry so render identity (L4), the
/// streaming tail paths and absolute indices are untouched while a run grows.
/// The head renders the group header (and, expanded, its own steps); the other
/// members render nothing while collapsed and their normal bubble when expanded.
enum ChatPhoneToolGroupRole: Equatable {
    case head(ChatPhoneToolGroupSummary)
    case member(groupID: String, isExpanded: Bool)

    var groupID: String {
        switch self {
        case let .head(summary): summary.id
        case let .member(groupID, _): groupID
        }
    }

    var headSummary: ChatPhoneToolGroupSummary? {
        if case let .head(summary) = self { return summary }
        return nil
    }

    var isCollapsedMember: Bool {
        if case let .member(_, isExpanded) = self { return !isExpanded }
        return false
    }

    var isExpandedMember: Bool {
        if case let .member(_, isExpanded) = self { return isExpanded }
        return false
    }

    var signature: Int {
        var hasher = Hasher()
        switch self {
        case let .head(summary):
            hasher.combine("head")
            hasher.combine(summary.signature)
        case let .member(groupID, isExpanded):
            hasher.combine("member")
            hasher.combine(groupID)
            hasher.combine(isExpanded)
        }
        return hasher.finalize()
    }

    /// Signature equality only: never compare the Kotlin tool payload (MBs of base64).
    static func == (lhs: ChatPhoneToolGroupRole, rhs: ChatPhoneToolGroupRole) -> Bool {
        lhs.signature == rhs.signature
    }
}

enum ChatPhoneToolGrouping {
    enum Membership: Equatable {
        /// Assistant message whose only visible content is phone tool steps (+ reasoning).
        case phone
        /// Reasoning-only / empty assistant message: extends an open run, never starts one.
        case neutral
        /// Anything the user must see as its own row: text, other tools, media, user turns.
        case breaking
    }

    static func isPhoneTool(_ name: String) -> Bool {
        IOSPhoneControlToolCatalog.isPhoneTool(name: name) || name.hasPrefix("phone_")
    }

    static func membership(of message: UIMessage) -> Membership {
        // Citations render under the message; a collapsed member would hide them.
        guard message.role == MessageRole.assistant, message.annotations.isEmpty else { return .breaking }
        var hasPhoneTool = false
        for part in message.parts {
            switch part {
            case let tool as UIMessagePart.Tool:
                guard isPhoneTool(tool.toolName) else { return .breaking }
                hasPhoneTool = true
            case is UIMessagePart.Reasoning:
                continue
            case let text as UIMessagePart.Text:
                if text.text.contains(where: { !$0.isWhitespace }) { return .breaking }
            default:
                return .breaking
            }
        }
        return hasPhoneTool ? .phone : .neutral
    }

    /// Whether a tail update can change any group: the tail joins/extends a run, or
    /// it previously belonged to one. Plain text streaming skips the regrouping pass.
    static func tailMayAffectGroups(tail: UIMessage, previousRole: ChatPhoneToolGroupRole?) -> Bool {
        previousRole != nil || membership(of: tail) != .breaking
    }

    static func digest(base: ChatRowDigest?, role: ChatPhoneToolGroupRole?) -> ChatRowDigest? {
        guard let base, let role else { return base }
        var hasher = Hasher()
        hasher.combine(base.layout)
        hasher.combine(role.signature)
        return ChatRowDigest(layout: String(hasher.finalize()), presentation: base.presentation)
    }

    /// Pure regrouping pass over message entries. Idempotent: recomputes every
    /// entry's role and folds the role signature into its digest from the entry's
    /// base (ungrouped) digest.
    ///
    /// `messages` is the full L0 snapshot (entries only cover the loaded history
    /// window): a run that started before the window keeps its true first message
    /// (group id), step count and start time, so revealing earlier history never
    /// re-keys or collapses an expanded group.
    static func annotate(
        _ entries: inout [NativeTimelineEntry],
        messages: [UIMessage],
        expandedGroupIDs: Set<String>,
        isGenerationActive: Bool
    ) {
        struct Run {
            /// First phone message of the whole run (may precede the window).
            var firstMessage: UIMessage?
            var memberIndices: [Int] = []
            var tools: [UIMessagePart.Tool] = []
        }
        var runs: [Run] = []
        var current: Run?
        func close() {
            if let run = current, !run.tools.isEmpty, run.firstMessage != nil { runs.append(run) }
            current = nil
        }
        // A run open at the window start continues from outside the window.
        if let windowStart = entries.first(where: { $0.kind == .message })?.index {
            current = prefixRun(messages: messages, before: windowStart).map {
                Run(firstMessage: $0.firstMessage, memberIndices: [], tools: $0.tools)
            }
        }
        for index in entries.indices {
            let entry = entries[index]
            guard entry.kind == .message else {
                // A compaction marker is visible between rows; top/bottom decorations
                // (configuration notice, pending, bottom anchor) are not between steps.
                if entry.kind == .contextMarker { close() }
                continue
            }
            guard let message = entry.message,
                  !entry.hasMultipleVariants,
                  !ChatMessageProjector.isSubAgentResult(message) else {
                close()
                continue
            }
            switch membership(of: message) {
            case .phone:
                if current == nil { current = Run(firstMessage: message) }
                current?.memberIndices.append(index)
                for part in message.parts {
                    if let tool = part as? UIMessagePart.Tool { current?.tools.append(tool) }
                }
            case .neutral:
                // Reasoning-only steps (e.g. thinking before the next phone action)
                // stay inside an open run; they never start one.
                current?.memberIndices.append(index)
            case .breaking:
                close()
            }
        }
        close()

        let language = ChatPhoneToolPresentation.currentLanguageKey()
        var roles = [ChatPhoneToolGroupRole?](repeating: nil, count: entries.count)
        for run in runs {
            // The head is the first loaded member that has a phone step (it draws the
            // header); leading reasoning-only members of a run continued from before
            // the window are ordinary members.
            guard let firstMessage = run.firstMessage,
                  let headIndex = run.memberIndices.first(where: { index in
                      entries[index].message.map { membership(of: $0) == .phone } ?? false
                  }),
                  let lastIndex = run.memberIndices.last,
                  let latestTool = run.tools.last,
                  let headMessageID = entries[headIndex].messageId else { continue }
            // Keyed on the run's first message UUID: provider toolCallIds (e.g. "call_0")
            // are not unique across conversations.
            let groupID = ChatMessageProjector.messageId(for: firstMessage)
            let isExpanded = expandedGroupIDs.contains(groupID)
            let summary = summary(
                id: groupID,
                headMessageID: headMessageID,
                firstMessage: firstMessage,
                lastEntry: entries[lastIndex],
                tools: run.tools,
                latestTool: latestTool,
                isExpanded: isExpanded,
                isGenerationActive: isGenerationActive,
                language: language
            )
            for memberIndex in run.memberIndices {
                roles[memberIndex] = memberIndex == headIndex
                    ? .head(summary)
                    : .member(groupID: groupID, isExpanded: isExpanded)
            }
        }

        for index in entries.indices where entries[index].kind == .message {
            let role = roles[index]
            guard entries[index].phoneToolGroup != role || entries[index].baseRenderDigest == nil else { continue }
            let base = entries[index].baseRenderDigest ?? entries[index].renderDigest
            entries[index].baseRenderDigest = base
            entries[index].phoneToolGroup = role
            entries[index].renderDigest = digest(base: base, role: role)
        }
    }

    /// The part of a run that lies before the loaded window, scanning backward
    /// from `index - 1` until a breaking message. Hidden (non-timeline) messages
    /// are transparent, as they are for assistant continuation.
    static func prefixRun(
        messages: [UIMessage],
        before index: Int
    ) -> (firstMessage: UIMessage, tools: [UIMessagePart.Tool])? {
        var firstMessage: UIMessage?
        var reversedTools: [UIMessagePart.Tool] = []
        var cursor = min(index, messages.count) - 1
        while cursor >= 0 {
            let message = messages[cursor]
            cursor -= 1
            guard ChatMessageProjector.isVisibleInTimeline(message) else { continue }
            guard !ChatMessageProjector.isSubAgentResult(message) else { break }
            switch membership(of: message) {
            case .breaking:
                cursor = -1
            case .neutral:
                continue
            case .phone:
                firstMessage = message
                for part in message.parts.reversed() {
                    if let tool = part as? UIMessagePart.Tool { reversedTools.append(tool) }
                }
            }
        }
        guard let firstMessage, !reversedTools.isEmpty else { return nil }
        return (firstMessage, reversedTools.reversed())
    }

    private static func summary(
        id: String,
        headMessageID: String,
        firstMessage: UIMessage,
        lastEntry: NativeTimelineEntry,
        tools: [UIMessagePart.Tool],
        latestTool: UIMessagePart.Tool,
        isExpanded: Bool,
        isGenerationActive: Bool,
        language: String
    ) -> ChatPhoneToolGroupSummary {
        let isLive = isGenerationActive && lastEntry.isLastMessage

        // Never hide something the user must act on: approvals and unknown
        // outcomes anywhere in the run, and a failure of the current (latest) step.
        var attention: ChatPhoneToolGroupAttention?
        var attentionCount = 0
        func record(_ kind: ChatPhoneToolGroupAttention) {
            if attention == nil || kind.rawValue > attention!.rawValue {
                attention = kind
                attentionCount = 1
            } else if kind == attention {
                attentionCount += 1
            }
        }
        for (offset, tool) in tools.enumerated() {
            if tool.output.isEmpty {
                if tool.approvalState is ToolApprovalState.Pending { record(.approvalPending) }
                continue
            }
            let presentation = ChatPhoneToolPresentation.cached(
                toolName: tool.toolName,
                executed: true,
                analysis: ChatToolOutputFormatter.analysis(for: tool),
                language: language
            )
            if presentation.isOutcomeUnknown {
                record(.outcomeUnknown)
            } else if offset == tools.count - 1, presentation.state == .failed {
                record(.failed)
            }
        }

        let startedAt = ChatImageGenerationResumeProjection.date(from: firstMessage.createdAt)
        let finishedAt: Date? = isLive ? nil : lastEntry.message.flatMap { message in
            ChatImageGenerationResumeProjection.date(from: message.finishedAt ?? message.createdAt)
        }

        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(headMessageID)
        hasher.combine(tools.count)
        hasher.combine(latestTool.toolCallId)
        // Latest step status/output only: streaming tool arguments do not change the header.
        hasher.combine(latestTool.toolName)
        ChatPartSignature.combineApproval(latestTool.approvalState, into: &hasher)
        let output = latestTool.output
        hasher.combine(output.count)
        for part in output {
            ChatPartSignature.combine(part, exactText: false, into: &hasher)
        }
        hasher.combine(attention?.rawValue ?? 0)
        hasher.combine(attentionCount)
        hasher.combine(isLive)
        hasher.combine(startedAt.map { Int($0.timeIntervalSince1970) } ?? 0)
        hasher.combine(finishedAt.map { Int($0.timeIntervalSince1970) } ?? 0)
        hasher.combine(isExpanded)

        return ChatPhoneToolGroupSummary(
            id: id,
            headMessageID: headMessageID,
            stepCount: tools.count,
            latestTool: latestTool,
            attention: attention,
            attentionCount: attentionCount,
            isLive: isLive,
            startedAt: startedAt,
            finishedAt: finishedAt,
            isExpanded: isExpanded,
            signature: hasher.finalize()
        )
    }
}
