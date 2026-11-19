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

// MARK: - Continuous automation process screenshot batch grouping (L1)

struct ChatAutomationScreenshotBatchSummary: Equatable {
    let id: String
    let headMessageID: String
    let items: [ChatMediaItem]
    let isExpanded: Bool
    let signature: Int

    var toggleID: String { "automation-shots-\(id)" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.signature == rhs.signature
    }
}

enum ChatAutomationScreenshotGroupRole: Equatable {
    case head(ChatAutomationScreenshotBatchSummary)
    case member(groupID: String)

    var headSummary: ChatAutomationScreenshotBatchSummary? {
        if case let .head(summary) = self { return summary }
        return nil
    }

    var isCollapsedMember: Bool {
        if case .member = self { return true }
        return false
    }

    var signature: Int {
        var hasher = Hasher()
        switch self {
        case let .head(summary):
            hasher.combine("shot-head")
            hasher.combine(summary.signature)
        case let .member(groupID):
            hasher.combine("shot-member")
            hasher.combine(groupID)
        }
        return hasher.finalize()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.signature == rhs.signature
    }
}

enum ChatAutomationScreenshotGrouping {
    enum Membership {
        case screenshots([ChatMediaItem])
        case neutral
        case breaking

        var isBreaking: Bool {
            if case .breaking = self { return true }
            return false
        }
    }

    static func isAutomationToolName(_ rawName: String) -> Bool {
        let lower = rawName.lowercased()
        if lower == "generate_image" || lower == "search_web" || lower == "scrape_web" { return false }
        if ChatPhoneToolGrouping.isPhoneTool(rawName) { return true }
        if lower.hasPrefix("wm_") || lower.hasPrefix("browser_") || lower.hasPrefix("desktop_") || lower.hasPrefix("device_") {
            return true
        }
        if rawName == "mcp_call" || ToolKt.isExpandedMcpToolName(name: rawName) {
            return lower.contains("screenshot") || lower.contains("browser") || lower.contains("device")
        }
        return false
    }

    static func isAutomationScreenshotTool(_ tool: UIMessagePart.Tool, allowDiskLookup: Bool = true) -> Bool {
        guard isAutomationToolName(tool.toolName) else { return false }
        guard !tool.output.contains(where: { $0 is UIMessagePart.Video }) else { return false }
        for part in tool.output {
            if IosToolOutputJsonBridge.shared.metadataString(part: part, key: "app.amber.media.origin") == "search" {
                return false
            }
        }
        return !screenshotItems(for: tool, messageID: "probe", allowDiskLookup: allowDiskLookup).isEmpty
    }

    static func defaultSourceLabel(for toolName: String) -> String {
        let lower = toolName.lowercased()
        if lower == "phone_observe" { return "手机界面观察" }
        if lower == "phone_run_goal" || lower == "phone_run_flow" { return "手机连续操作核验" }
        if lower.hasPrefix("phone_") { return "手机操作截图" }
        if lower == "wm_visual_read" { return "网页视觉核验" }
        if lower == "wm_screenshot" { return "网页视口截图" }
        if lower.hasPrefix("wm_") || lower.hasPrefix("browser_") || lower.hasPrefix("desktop_") {
            return "页面过程截图"
        }
        return "自动化过程截图"
    }

    static func screenshotItems(
        for tool: UIMessagePart.Tool,
        messageID: String,
        allowDiskLookup: Bool = true
    ) -> [ChatMediaItem] {
        guard isAutomationToolName(tool.toolName),
              !tool.output.contains(where: { $0 is UIMessagePart.Video }) else { return [] }
        let fallbackTitle = defaultSourceLabel(for: tool.toolName)
        if !allowDiskLookup {
            // Fast in-memory path safe for SwiftUI body: inspect only UIMessagePart.Image without JSON/disk I/O.
            let directImages = tool.output.compactMap { $0 as? UIMessagePart.Image }
            return directImages.enumerated().map { offset, image in
                let rawItem = ChatMediaItem.image(image, id: "\(messageID):\(tool.toolCallId):shot:\(offset)")
                let trimmedTitle = rawItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return ChatMediaItem(
                    id: rawItem.id,
                    url: rawItem.url,
                    title: trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle,
                    sourceURL: rawItem.sourceURL,
                    width: rawItem.width,
                    height: rawItem.height
                )
            }
        }
        let rawItems = ChatMediaItem.toolImages(tool.output)
        if !rawItems.isEmpty {
            return rawItems.enumerated().map { offset, item in
                let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return ChatMediaItem(
                    id: "\(messageID):\(tool.toolCallId):shot:\(offset)",
                    url: item.url,
                    title: trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle,
                    sourceURL: item.sourceURL,
                    width: item.width,
                    height: item.height
                )
            }
        }
        // WebMount wm_screenshot local file artifact fallback when saved on disk:
        if tool.toolName == "wm_screenshot" {
            let joined = tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n")
            if let data = joined.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let artifact = obj["artifact"] as? [String: Any],
               let localRef = artifact["local_ref"] as? String,
               localRef.hasPrefix("Workspace/WebMount/screenshots/") {
                let fileName = String(localRef.dropFirst("Workspace/WebMount/screenshots/".count))
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                if let fileURL = root?
                    .appendingPathComponent("AmberWorkspace", isDirectory: true)
                    .appendingPathComponent("WebMount", isDirectory: true)
                    .appendingPathComponent("screenshots", isDirectory: true)
                    .appendingPathComponent(fileName, isDirectory: false),
                   FileManager.default.fileExists(atPath: fileURL.path) {
                    let pageURL = ((obj["state"] as? [String: Any])?["url"] as? String)
                    return [
                        ChatMediaItem(
                            id: "\(messageID):\(tool.toolCallId):shot:0",
                            url: fileURL.absoluteString,
                            title: fallbackTitle,
                            sourceURL: pageURL,
                            width: (artifact["width"] as? NSNumber)?.doubleValue,
                            height: (artifact["height"] as? NSNumber)?.doubleValue
                        )
                    ]
                }
            }
        }
        return []
    }

    static func membership(of message: UIMessage, messageID: String? = nil) -> Membership {
        guard message.role == MessageRole.assistant, message.annotations.isEmpty else { return .breaking }
        guard !ChatMessageProjector.isSubAgentResult(message) else { return .breaking }
        let resolvedID = messageID ?? ChatMessageProjector.messageId(for: message)
        var collected: [ChatMediaItem] = []
        for part in message.parts {
            switch part {
            case let text as UIMessagePart.Text:
                if text.text.contains(where: { !$0.isWhitespace }) { return .breaking }
            case is UIMessagePart.Reasoning:
                continue
            case let tool as UIMessagePart.Tool:
                let shots = screenshotItems(for: tool, messageID: resolvedID)
                if !shots.isEmpty {
                    collected.append(contentsOf: shots)
                } else if ChatTaskStreamGrouping.isMediaBearing(tool) {
                    return .breaking
                }
            default:
                return .breaking
            }
        }
        return collected.isEmpty ? .neutral : .screenshots(collected)
    }

    static func makeSummary(
        id: String,
        headMessageID: String,
        items: [ChatMediaItem],
        expandedGroupIDs: Set<String>
    ) -> ChatAutomationScreenshotBatchSummary {
        let toggleID = "automation-shots-\(id)"
        let isExpanded = expandedGroupIDs.contains(toggleID)
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(headMessageID)
        hasher.combine(items.count)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.url.count)
            hasher.combine(String(item.url.suffix(24)))
            hasher.combine(item.title)
            hasher.combine(item.sourceURL)
        }
        hasher.combine(isExpanded)
        return ChatAutomationScreenshotBatchSummary(
            id: id,
            headMessageID: headMessageID,
            items: items,
            isExpanded: isExpanded,
            signature: hasher.finalize()
        )
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
    static func tailMayAffectGroups(
        tail: UIMessage,
        previousRole: ChatPhoneToolGroupRole?,
        previousTurnRole: ChatAssistantTurnRole? = nil,
        previousScreenshotRole: ChatAutomationScreenshotGroupRole? = nil
    ) -> Bool {
        previousRole != nil || previousScreenshotRole != nil || membership(of: tail) != .breaking ||
            !ChatAutomationScreenshotGrouping.membership(of: tail).isBreaking ||
            ChatAssistantTurnToolGrouping.tailMayAffectTurns(tail: tail, previousRole: previousTurnRole)
    }

    static func digest(
        base: ChatRowDigest?,
        role: ChatPhoneToolGroupRole?,
        turnRole: ChatAssistantTurnRole? = nil,
        screenshotRole: ChatAutomationScreenshotGroupRole? = nil
    ) -> ChatRowDigest? {
        guard let base, role != nil || turnRole != nil || screenshotRole != nil else { return base }
        var hasher = Hasher()
        hasher.combine(base.layout)
        hasher.combine(role?.signature)
        hasher.combine(turnRole?.signature)
        hasher.combine(screenshotRole?.signature)
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
        isGenerationActive: Bool,
        fromEntryIndex: Int = 0,
        factsByObjectID: [ObjectIdentifier: NativeTimelineMessageFacts]? = nil
    ) {
        let startEntryIndex = max(0, min(fromEntryIndex, entries.count))
        func resolvedFacts(for message: UIMessage) -> NativeTimelineMessageFacts? {
            factsByObjectID?[ObjectIdentifier(message)]
        }

        struct Run {
            /// First phone message of the whole run (may precede the window).
            var firstMessage: UIMessage?
            var firstMessageID: String?
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
        if startEntryIndex == 0,
           let windowStart = entries.first(where: { $0.kind == .message })?.index {
            current = prefixRun(
                messages: messages,
                before: windowStart,
                factsByObjectID: factsByObjectID
            ).map {
                Run(
                    firstMessage: $0.firstMessage,
                    firstMessageID: resolvedFacts(for: $0.firstMessage)?.messageId,
                    memberIndices: [],
                    tools: $0.tools
                )
            }
        }
        for index in startEntryIndex ..< entries.count {
            let entry = entries[index]
            guard entry.kind == .message else {
                // A compaction marker is visible between rows; top/bottom decorations
                // (configuration notice, pending, bottom anchor) are not between steps.
                if entry.kind == .contextMarker { close() }
                continue
            }
            guard let message = entry.message, !entry.hasMultipleVariants else {
                close()
                continue
            }
            if let facts = resolvedFacts(for: message) {
                guard !facts.isSubAgentResult else {
                    close()
                    continue
                }
                switch facts.phoneMembership {
                case .phone:
                    if current == nil {
                        current = Run(firstMessage: message, firstMessageID: facts.messageId)
                    }
                    current?.memberIndices.append(index)
                    current?.tools.append(contentsOf: facts.phoneTools)
                case .neutral:
                    current?.memberIndices.append(index)
                case .breaking:
                    close()
                }
            } else {
                guard !ChatMessageProjector.isSubAgentResult(message) else {
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
                      guard let message = entries[index].message else { return false }
                      if let facts = resolvedFacts(for: message) {
                          return facts.phoneMembership == .phone
                      }
                      return membership(of: message) == .phone
                  }),
                  let lastIndex = run.memberIndices.last,
                  let latestTool = run.tools.last,
                  let headMessageID = entries[headIndex].messageId else { continue }
            // Keyed on the run's first message UUID: provider toolCallIds (e.g. "call_0")
            // are not unique across conversations.
            let groupID = run.firstMessageID ?? ChatMessageProjector.messageId(for: firstMessage)
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

        // A turn with any non-phone tool draws one line for all of its tools, phone steps included.
        let turnRoles = ChatAssistantTurnToolGrouping.roles(
            entries: entries,
            messages: messages,
            isGenerationActive: isGenerationActive,
            fromEntryIndex: startEntryIndex,
            factsByObjectID: factsByObjectID
        )
        let screenshotRoles = screenshotBatchRoles(
            entries: entries,
            messages: messages,
            expandedGroupIDs: expandedGroupIDs,
            fromEntryIndex: startEntryIndex,
            factsByObjectID: factsByObjectID
        )
        for index in startEntryIndex ..< entries.count where entries[index].kind == .message {
            let turnRole = turnRoles[index]
            let role = turnRole == nil ? roles[index] : nil
            let screenshotRole = screenshotRoles[index]
            guard entries[index].phoneToolGroup != role ||
                entries[index].assistantTurn != turnRole ||
                entries[index].automationScreenshotGroup != screenshotRole ||
                entries[index].baseRenderDigest == nil else { continue }
            let base = entries[index].baseRenderDigest ?? entries[index].renderDigest
            entries[index].baseRenderDigest = base
            entries[index].phoneToolGroup = role
            entries[index].assistantTurn = turnRole
            entries[index].automationScreenshotGroup = screenshotRole
            entries[index].renderDigest = digest(
                base: base,
                role: role,
                turnRole: turnRole,
                screenshotRole: screenshotRole
            )
        }
    }

    private static func screenshotBatchRoles(
        entries: [NativeTimelineEntry],
        messages: [UIMessage],
        expandedGroupIDs: Set<String>,
        fromEntryIndex: Int,
        factsByObjectID: [ObjectIdentifier: NativeTimelineMessageFacts]?
    ) -> [ChatAutomationScreenshotGroupRole?] {
        struct ShotRun {
            var firstMessageID: String?
            var headEntryIndex: Int?
            var memberIndices: [Int] = []
            var items: [ChatMediaItem] = []
        }
        var runs: [ShotRun] = []
        var current: ShotRun?
        func close() {
            if let run = current, !run.items.isEmpty, run.headEntryIndex != nil, run.firstMessageID != nil {
                runs.append(run)
            }
            current = nil
        }

        if fromEntryIndex == 0,
           let windowStart = entries.first(where: { $0.kind == .message })?.index {
            if let prefix = prefixScreenshotRun(messages: messages, before: windowStart, factsByObjectID: factsByObjectID) {
                current = ShotRun(firstMessageID: prefix.firstMessageID, headEntryIndex: nil, memberIndices: [], items: prefix.items)
            }
        }

        for index in fromEntryIndex ..< entries.count {
            let entry = entries[index]
            guard entry.kind == .message else {
                if entry.kind == .contextMarker { close() }
                continue
            }
            guard let message = entry.message, !entry.hasMultipleVariants else {
                close()
                continue
            }
            let messageID = entry.messageId ?? factsByObjectID?[ObjectIdentifier(message)]?.messageId ?? ChatMessageProjector.messageId(for: message)
            switch ChatAutomationScreenshotGrouping.membership(of: message, messageID: messageID) {
            case .screenshots(let shots):
                if current == nil {
                    current = ShotRun(firstMessageID: messageID, headEntryIndex: index, memberIndices: [index], items: shots)
                } else {
                    if current?.headEntryIndex == nil { current?.headEntryIndex = index }
                    current?.memberIndices.append(index)
                    current?.items.append(contentsOf: shots)
                }
            case .neutral:
                continue
            case .breaking:
                close()
            }
        }
        close()

        var roles = [ChatAutomationScreenshotGroupRole?](repeating: nil, count: entries.count)
        for run in runs {
            guard let groupID = run.firstMessageID,
                  let headIndex = run.headEntryIndex,
                  let headMessageID = entries[headIndex].messageId else { continue }
            let summary = ChatAutomationScreenshotGrouping.makeSummary(
                id: groupID,
                headMessageID: headMessageID,
                items: run.items,
                expandedGroupIDs: expandedGroupIDs
            )
            for memberIndex in run.memberIndices {
                roles[memberIndex] = memberIndex == headIndex
                    ? .head(summary)
                    : .member(groupID: groupID)
            }
        }
        return roles
    }

    private static func prefixScreenshotRun(
        messages: [UIMessage],
        before index: Int,
        factsByObjectID: [ObjectIdentifier: NativeTimelineMessageFacts]?
    ) -> (firstMessageID: String, items: [ChatMediaItem])? {
        var firstMessageID: String?
        var reversedBatches: [[ChatMediaItem]] = []
        var cursor = min(index, messages.count) - 1
        while cursor >= 0 {
            let message = messages[cursor]
            cursor -= 1
            let isVisible = factsByObjectID?[ObjectIdentifier(message)]?.isVisibleInTimeline
                ?? ChatMessageProjector.isVisibleInTimeline(message)
            guard isVisible else { continue }
            let msgID = factsByObjectID?[ObjectIdentifier(message)]?.messageId ?? ChatMessageProjector.messageId(for: message)
            switch ChatAutomationScreenshotGrouping.membership(of: message, messageID: msgID) {
            case .breaking:
                cursor = -1
            case .neutral:
                continue
            case .screenshots(let shots):
                firstMessageID = msgID
                reversedBatches.append(shots)
            }
        }
        guard let firstMessageID, !reversedBatches.isEmpty else { return nil }
        return (firstMessageID, reversedBatches.reversed().flatMap { $0 })
    }

    /// The part of a run that lies before the loaded window, scanning backward
    /// from `index - 1` until a breaking message. Hidden (non-timeline) messages
    /// are transparent, as they are for assistant continuation.
    static func prefixRun(
        messages: [UIMessage],
        before index: Int,
        factsByObjectID: [ObjectIdentifier: NativeTimelineMessageFacts]? = nil
    ) -> (firstMessage: UIMessage, tools: [UIMessagePart.Tool])? {
        var firstMessage: UIMessage?
        var reversedTools: [UIMessagePart.Tool] = []
        var cursor = min(index, messages.count) - 1
        while cursor >= 0 {
            let message = messages[cursor]
            cursor -= 1
            if let facts = factsByObjectID?[ObjectIdentifier(message)] {
                guard facts.isVisibleInTimeline else { continue }
                guard !facts.isSubAgentResult else { break }
                switch facts.phoneMembership {
                case .breaking:
                    cursor = -1
                case .neutral:
                    continue
                case .phone:
                    firstMessage = message
                    reversedTools.append(contentsOf: facts.phoneTools.reversed())
                }
            } else {
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
