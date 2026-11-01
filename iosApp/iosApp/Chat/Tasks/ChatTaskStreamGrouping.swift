import Foundation
import Shared
import SwiftUI

// MARK: - Duet Task Stream Grouping & Rollup Model

enum ChatTaskRollupState: Equatable {
    case working(currentStepTitle: String)
    case approvalPending(count: Int)
    case needsAttention(failedCount: Int, totalCount: Int, failedToolTitle: String, reason: String?)
    case completed(stepCount: Int)
    case cancelled

    var isLive: Bool {
        if case .working = self { return true }
        return false
    }

    var isFailureOrNeedsUser: Bool {
        switch self {
        case .approvalPending, .needsAttention:
            return true
        case .working, .completed, .cancelled:
            return false
        }
    }

    var statusBadgeText: String {
        switch self {
        case .working:
            return IOSAppLocalization.string("进行中", defaultValue: "进行中")
        case .approvalPending(let count):
            return count > 1
                ? IOSAppLocalization.formatted("%ld 项待确认", defaultValue: "%ld 项待确认", arguments: [count])
                : IOSAppLocalization.string("待你确认", defaultValue: "待你确认")
        case .needsAttention(let failedCount, _, _, _):
            return failedCount > 1
                ? IOSAppLocalization.formatted("%ld 次失败 · 需处理", defaultValue: "%ld 次失败 · 需处理", arguments: [failedCount])
                : IOSAppLocalization.string("执行失败 · 需处理", defaultValue: "执行失败 · 需处理")
        case .completed(let count):
            return count > 1
                ? IOSAppLocalization.formatted("已完成 · %ld 步", defaultValue: "已完成 · %ld 步", arguments: [count])
                : IOSAppLocalization.string("已完成", defaultValue: "已完成")
        case .cancelled:
            return IOSAppLocalization.string("已取消", defaultValue: "已取消")
        }
    }

    @MainActor
    var tintColor: Color {
        switch self {
        case .working:
            return AmberTheme.accent
        case .approvalPending:
            return AmberTheme.accentAmber
        case .needsAttention:
            return AmberTheme.accentRed
        case .completed:
            return AmberTheme.accentGreen
        case .cancelled:
            return AmberTheme.muted
        }
    }

    var iconSystemName: String {
        switch self {
        case .working:
            return "rays"
        case .approvalPending:
            return "hand.raised.fill"
        case .needsAttention:
            return "exclamationmark.triangle.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .cancelled:
            return "minus.circle"
        }
    }
}

struct ChatTaskReasoningEntry: Identifiable, Equatable {
    let id: String
    let text: String
    let durationSeconds: Double?
    let isThinking: Bool
}

struct ChatTaskRunSegment: Identifiable {
    let id: String
    let messageID: String
    let taskId: String
    let agentDisplayName: String
    let subAgentIdentity: String?
    let headline: String
    let subtitle: String?
    let rollupState: ChatTaskRollupState
    let tools: [UIMessagePart.Tool]
    let steps: [ChatToolStepModel]
    let reasonings: [ChatTaskReasoningEntry]
    let mediaBearingTools: [UIMessagePart.Tool]
    let hidesCompletedStandaloneReasoning: Bool
    /// Scroll anchors for tools drawn by this row; empty means derive them from `messageID`.
    var toolAnchorIDs: [String] = []

    var hasTools: Bool { !tools.isEmpty }

    var inlineStatusBadgeText: String {
        if case .working = rollupState {
            let isCloudOrSubagent = tools.contains { tool in
                let name = tool.toolName.lowercased()
                return name.contains("subagent") || name.contains("cloud") || name.contains("background")
            }
            if isCloudOrSubagent {
                return IOSAppLocalization.string("云端运行中", defaultValue: "云端运行中")
            }
        }
        return rollupState.statusBadgeText
    }
}

enum ChatTaskMessageSegment: Identifiable {
    case text(id: String, partIndex: Int, part: UIMessagePart.Text)
    case taskGroup(ChatTaskRunSegment)
    case imageGallery(id: String, startIndex: Int, images: [UIMessagePart.Image])
    case video(id: String, partIndex: Int, part: UIMessagePart.Video)
    case miniApp(id: String, partIndex: Int, part: UIMessagePart.MiniApp)

    var id: String {
        switch self {
        case .text(let id, _, _): return id
        case .taskGroup(let group): return group.id
        case .imageGallery(let id, _, _): return id
        case .video(let id, _, _): return id
        case .miniApp(let id, _, _): return id
        }
    }
}

enum ChatTaskStreamGrouping {
    /// Projects an assistant `UIMessage`'s parts into clean Duet-style segments:
    /// - Consecutive `Reasoning` and `Tool` parts collapse into a single `ChatTaskRunSegment`.
    /// - Unrecovered tool failures (e.g., 4x `ssh_profile_create` failures followed by `ssh_profile_list` success)
    ///   surface as `.needsAttention` so tool errors are never silently masked as success.
    /// - Standalone finished `Reasoning` pills before a completed text reply are hidden from the main stream,
    ///   while live in-progress thinking stays visible.
    @MainActor
    static func segments(
        for message: UIMessage,
        messageID: String,
        isGeneratingTail: Bool
    ) -> [ChatTaskMessageSegment] {
        let parts = message.parts
        guard !parts.isEmpty else { return [] }

        let hasNonEmptyText = parts.contains { part in
            guard let text = part as? UIMessagePart.Text else { return false }
            return text.text.contains { !$0.isWhitespace }
        }

        var result: [ChatTaskMessageSegment] = []
        var index = 0

        while index < parts.count {
            let part = parts[index]

            if let textPart = part as? UIMessagePart.Text {
                if !textPart.text.isEmpty {
                    result.append(.text(id: "\(messageID):text:\(index)", partIndex: index, part: textPart))
                }
                index += 1
                continue
            }

            if part is UIMessagePart.Reasoning || part is UIMessagePart.Tool {
                let runStart = index
                var runTools: [UIMessagePart.Tool] = []
                var runReasonings: [ChatTaskReasoningEntry] = []

                while index < parts.count {
                    let current = parts[index]
                    if let reasoning = current as? UIMessagePart.Reasoning {
                        if MessageBubbleView.shouldRenderReasoningCard(reasoning) {
                            let isLiveThinking = reasoning.finishedAt == nil && isGeneratingTail
                            let duration = Self.reasoningDuration(reasoning)
                            runReasonings.append(
                                ChatTaskReasoningEntry(
                                    id: "\(messageID):reasoning:\(index)",
                                    text: reasoning.reasoning,
                                    durationSeconds: duration,
                                    isThinking: isLiveThinking
                                )
                            )
                        }
                        index += 1
                    } else if let tool = current as? UIMessagePart.Tool {
                        runTools.append(tool)
                        index += 1
                    } else if let whitespaceText = current as? UIMessagePart.Text,
                              !whitespaceText.text.contains(where: { !$0.isWhitespace }) {
                        index += 1
                    } else {
                        break
                    }
                }

                if let segment = buildTaskSegment(
                    messageID: messageID,
                    runStart: runStart,
                    tools: runTools,
                    reasonings: runReasonings,
                    hasNonEmptyTextInMessage: hasNonEmptyText,
                    isGeneratingTail: isGeneratingTail
                ) {
                    result.append(.taskGroup(segment))
                }
                continue
            }

            if part is UIMessagePart.Image {
                let startIndex = index
                var images: [UIMessagePart.Image] = []
                while index < parts.count, let img = parts[index] as? UIMessagePart.Image {
                    images.append(img)
                    index += 1
                }
                result.append(.imageGallery(id: "\(messageID):images:\(startIndex)", startIndex: startIndex, images: images))
                continue
            }

            if let video = part as? UIMessagePart.Video {
                result.append(.video(id: "\(messageID):video:\(index)", partIndex: index, part: video))
                index += 1
                continue
            }

            if let miniApp = part as? UIMessagePart.MiniApp {
                result.append(.miniApp(id: "\(messageID):miniapp:\(index)", partIndex: index, part: miniApp))
                index += 1
                continue
            }

            index += 1
        }

        return result
    }

    @MainActor
    private static func buildTaskSegment(
        messageID: String,
        runStart: Int,
        tools: [UIMessagePart.Tool],
        reasonings: [ChatTaskReasoningEntry],
        hasNonEmptyTextInMessage: Bool,
        isGeneratingTail: Bool
    ) -> ChatTaskRunSegment? {
        // Standalone reasoning without any tools:
        if tools.isEmpty {
            guard !reasonings.isEmpty else { return nil }
            let anyLiveThinking = reasonings.contains(where: \.isThinking)
            // When the assistant has already produced its reply text (or finished thinking with text),
            // hide the "思考了 N 秒 · 最高" pill from the main conversation stream.
            if !anyLiveThinking && hasNonEmptyTextInMessage {
                return nil
            }
            let latestReasoning = reasonings.last!
            let preview = Self.firstLinePreview(latestReasoning.text)
            let rollup: ChatTaskRollupState = anyLiveThinking
                ? .working(currentStepTitle: preview ?? IOSAppLocalization.string("正在思考…", defaultValue: "正在思考…"))
                : .completed(stepCount: 1)
            return ChatTaskRunSegment(
                id: "\(messageID):task:\(runStart)",
                messageID: messageID,
                taskId: "\(messageID)-thinking-\(runStart)",
                agentDisplayName: "Amber",
                subAgentIdentity: nil,
                headline: anyLiveThinking
                    ? IOSAppLocalization.string("正在整理思路…", defaultValue: "正在整理思路…")
                    : IOSAppLocalization.string("已完成思考", defaultValue: "已完成思考"),
                subtitle: preview,
                rollupState: rollup,
                tools: [],
                steps: [],
                reasonings: reasonings,
                mediaBearingTools: [],
                hidesCompletedStandaloneReasoning: !anyLiveThinking
            )
        }

        let steps = tools.map { ChatToolStepModel(tool: $0) }
        let subAgentStep = steps.first { $0.subAgentPresentation != nil }
        let agentName: String
        let subAgentIdentity: String?
        if let presentation = subAgentStep?.subAgentPresentation {
            agentName = "@\(presentation.displayName)"
            subAgentIdentity = presentation.identity
        } else {
            agentName = "Amber"
            subAgentIdentity = nil
        }

        let taskId = subAgentStep?.subAgentPresentation?.threadID
            ?? tools.first?.toolCallId
            ?? "\(messageID)-\(runStart)"

        let rollup = computeRollupState(tools: tools, steps: steps, reasonings: reasonings, isGeneratingTail: isGeneratingTail)
        let (headline, subtitle) = computeHeadlineAndSubtitle(
            tools: tools,
            steps: steps,
            rollup: rollup,
            subAgentPresentation: subAgentStep?.subAgentPresentation
        )

        let mediaTools = tools.filter(isMediaBearing)

        return ChatTaskRunSegment(
            id: "\(messageID):task:\(runStart)",
            messageID: messageID,
            taskId: taskId,
            agentDisplayName: agentName,
            subAgentIdentity: subAgentIdentity,
            headline: headline,
            subtitle: subtitle,
            rollupState: rollup,
            tools: tools,
            steps: steps,
            reasonings: reasonings,
            mediaBearingTools: mediaTools,
            hidesCompletedStandaloneReasoning: false
        )
    }

    /// Tools that draw images/video in the conversation besides their task row.
    static func isMediaBearing(_ tool: UIMessagePart.Tool) -> Bool {
        if tool.toolName == "generate_image" { return true }
        if tool.output.contains(where: { $0 is UIMessagePart.Image || $0 is UIMessagePart.Video }) {
            return true
        }
        return !ChatMediaItem.toolImages(tool.output).isEmpty
    }

    /// The single row of a whole assistant turn. Its text follows real state only:
    /// the current step while live, then how the turn actually settled.
    @MainActor
    static func turnSegment(for progress: ChatAssistantTurnProgress) -> ChatTaskRunSegment {
        let tools = progress.tools
        let steps = tools.map { ChatToolStepModel(tool: $0) }
        var reasonings: [ChatTaskReasoningEntry] = []
        for message in progress.messages {
            let messageID = ChatMessageProjector.messageId(for: message)
            for (index, part) in message.parts.enumerated() {
                guard let reasoning = part as? UIMessagePart.Reasoning,
                      MessageBubbleView.shouldRenderReasoningCard(reasoning) else { continue }
                reasonings.append(ChatTaskReasoningEntry(
                    id: "\(messageID):reasoning:\(index)",
                    text: reasoning.reasoning,
                    durationSeconds: reasoningDuration(reasoning),
                    isThinking: false
                ))
            }
        }

        let currentStep = steps.last(where: { $0.state == .active }) ?? steps.last
        let currentLine = progress.isComposingReply
            ? IOSAppLocalization.string("正在整理回复…", defaultValue: "正在整理回复…")
            : currentStep.flatMap { progressLine(for: $0) }
                ?? IOSAppLocalization.string("正在处理…", defaultValue: "正在处理…")

        var rollup = computeRollupState(tools: tools, steps: steps, reasonings: [], isGeneratingTail: false)
        if progress.isLive {
            // A failed attempt mid-run may be retried; only approvals interrupt the live line.
            if case .approvalPending = rollup {} else { rollup = .working(currentStepTitle: currentLine) }
        } else if case .working = rollup {
            // The run ended with a step that never returned.
            rollup = .cancelled
        }

        let headline: String
        var subtitle: String?
        switch rollup {
        case .working(let line):
            headline = line
        case .approvalPending:
            headline = IOSAppLocalization.string("等你确认后继续", defaultValue: "等你确认后继续")
        case .needsAttention(_, _, let failedToolTitle, let reason):
            headline = IOSAppLocalization.formatted("%@未成功", defaultValue: "%@未成功", arguments: [failedToolTitle])
            subtitle = reason
        case .completed(let count):
            // Tools finishing is not the task succeeding, so the line never claims success.
            headline = IOSAppLocalization.formatted("已执行 %ld 步", defaultValue: "已执行 %ld 步", arguments: [count])
        case .cancelled:
            headline = IOSAppLocalization.string("已停止", defaultValue: "已停止")
        }

        return ChatTaskRunSegment(
            id: "turn:\(progress.id)",
            messageID: progress.headMessageID,
            taskId: progress.id,
            agentDisplayName: "Amber",
            subAgentIdentity: nil,
            headline: headline,
            subtitle: subtitle,
            rollupState: rollup,
            tools: tools,
            steps: steps,
            reasonings: reasonings,
            mediaBearingTools: [],
            hidesCompletedStandaloneReasoning: false,
            toolAnchorIDs: progress.anchorIDs
        )
    }

    /// Present-tense user-facing line for a step; never a raw internal tool name.
    static func progressLine(for step: ChatToolStepModel) -> String? {
        let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !title.contains("_"), !title.hasPrefix("调用 ") else { return nil }
        let action = title.hasPrefix("已") ? String(title.dropFirst()) : title
        if action.hasPrefix("正在") { return action.hasSuffix("…") ? action : action + "…" }
        let joiner = action.first?.isASCII == true ? " " : ""
        return "正在\(joiner)\(action)…"
    }

    static func computeRollupState(
        tools: [UIMessagePart.Tool],
        steps: [ChatToolStepModel],
        reasonings: [ChatTaskReasoningEntry],
        isGeneratingTail: Bool
    ) -> ChatTaskRollupState {
        // 1. Sensitive / user approval pending always takes top priority and is never hidden.
        let pendingApprovalCount = tools.filter { $0.approvalState is ToolApprovalState.Pending }.count
        if pendingApprovalCount > 0 {
            return .approvalPending(count: pendingApprovalCount)
        }

        // 2. Active in-flight step or live tail thinking.
        if let activeStep = steps.last(where: { $0.state == .active }) {
            return .working(currentStepTitle: activeStep.title)
        }
        if isGeneratingTail && reasonings.contains(where: \.isThinking) {
            let latestTitle = steps.last?.title ?? IOSAppLocalization.string("正在执行…", defaultValue: "正在执行…")
            return .working(currentStepTitle: latestTitle)
        }

        // 3. Unrecovered tool failures:
        // Group steps by toolName so a failed `ssh_profile_create` x4 is NOT masked by a later `ssh_profile_list` success.
        var lastStateByToolName: [String: ChatToolStepState] = [:]
        var failedCountByToolName: [String: Int] = [:]
        var firstFailedStepByToolName: [String: ChatToolStepModel] = [:]

        for (tool, step) in zip(tools, steps) {
            let key = tool.toolName
            lastStateByToolName[key] = step.state
            if step.state == .failed || Self.hasUnknownOutcome(tool) {
                failedCountByToolName[key, default: 0] += 1
                if firstFailedStepByToolName[key] == nil {
                    firstFailedStepByToolName[key] = step
                }
            }
        }

        var unrecoveredFailedCount = 0
        var primaryFailedStep: ChatToolStepModel?
        for (tool, step) in zip(tools, steps) {
            let key = tool.toolName
            let isUnrecovered = (lastStateByToolName[key] == .failed)
                || Self.hasUnknownOutcome(tool)
            if isUnrecovered, let count = failedCountByToolName[key], count > 0 {
                if primaryFailedStep == nil {
                    primaryFailedStep = firstFailedStepByToolName[key] ?? step
                }
            }
        }

        for (key, count) in failedCountByToolName {
            if lastStateByToolName[key] == .failed {
                unrecoveredFailedCount += count
            }
        }

        if unrecoveredFailedCount == 0,
           let unknownIndex = tools.firstIndex(where: { Self.hasUnknownOutcome($0) }) {
            unrecoveredFailedCount = 1
            primaryFailedStep = steps[unknownIndex]
        }

        if unrecoveredFailedCount > 0, let failedStep = primaryFailedStep {
            let reason = extractHumanReadableFailureReason(from: failedStep, tools: tools, steps: steps)
            return .needsAttention(
                failedCount: unrecoveredFailedCount,
                totalCount: steps.count,
                failedToolTitle: failedStep.title,
                reason: reason
            )
        }

        // 4. Cancelled if all steps were cancelled.
        if !steps.isEmpty && steps.allSatisfy({ $0.state == .cancelled }) {
            return .cancelled
        }

        // 5. Completed.
        return .completed(stepCount: steps.count)
    }

    private static func computeHeadlineAndSubtitle(
        tools: [UIMessagePart.Tool],
        steps: [ChatToolStepModel],
        rollup: ChatTaskRollupState,
        subAgentPresentation: ChatSubAgentCapsulePresentation?
    ) -> (headline: String, subtitle: String?) {
        if let dispatchedGoalTitle = extractDispatchedGoalTitle(from: tools) {
            switch rollup {
            case .needsAttention(_, _, _, let reason):
                return (dispatchedGoalTitle, reason)
            case .working(let currentStepTitle):
                return (dispatchedGoalTitle, currentStepTitle)
            default:
                return (dispatchedGoalTitle, nil)
            }
        }

        if let subAgentPresentation {
            let title = subAgentPresentation.workSummary ?? "@\(subAgentPresentation.displayName)"
            switch rollup {
            case .needsAttention(_, _, _, let reason):
                return (title, reason)
            case .working(let currentStepTitle):
                return (title, currentStepTitle)
            default:
                return (title, steps.count > 1 ? "\(steps.count) 项子代理操作" : nil)
            }
        }

        // Deduplicate tool titles in order of appearance
        var distinctTitles: [String] = []
        for step in steps {
            if !distinctTitles.contains(step.title) {
                distinctTitles.append(step.title)
            }
        }

        let rawPrimaryTitle = distinctTitles.first ?? IOSAppLocalization.string("任务执行", defaultValue: "任务执行")
        let primaryTitle: String
        if rawPrimaryTitle == "新建 SSH Profile",
           tools.contains(where: { $0.input.localizedCaseInsensitiveContains("jump") || $0.input.contains("跳板") }) {
            primaryTitle = "新建 SSH 跳板机 Profile"
        } else {
            primaryTitle = rawPrimaryTitle
        }
        let headline: String
        if distinctTitles.count == 1 {
            headline = primaryTitle
        } else if distinctTitles.count == 2 {
            headline = "\(distinctTitles[0]) · \(distinctTitles[1])"
        } else {
            headline = "\(primaryTitle) 等 \(distinctTitles.count) 项操作"
        }

        switch rollup {
        case .working(let currentStepTitle):
            let sub = steps.count > 1 ? "当前：\(currentStepTitle)（第 \(steps.count) 步）" : currentStepTitle
            return (headline, sub)
        case .approvalPending:
            let pendingTitle = steps.first(where: { $0.state == .active })?.title ?? primaryTitle
            return (headline, "等待确认：\(pendingTitle)")
        case .needsAttention(let failedCount, _, let failedToolTitle, let reason):
            if let reason, !reason.isEmpty {
                return (headline, "\(failedToolTitle) 失败（\(failedCount) 次）：\(reason)")
            }
            return (headline, "\(failedToolTitle) 连续 \(failedCount) 次未成功，请点击查看详情")
        case .completed(let stepCount):
            if let lastDetail = steps.last?.detail, !lastDetail.isEmpty {
                return (headline, lastDetail)
            }
            if stepCount > 1 {
                return (headline, "已完成 \(stepCount) 个执行步骤")
            }
            return (headline, nil)
        case .cancelled:
            return (headline, IOSAppLocalization.string("操作已取消", defaultValue: "操作已取消"))
        }
    }

    private static func extractDispatchedGoalTitle(from tools: [UIMessagePart.Tool]) -> String? {
        for tool in tools {
            let name = tool.toolName.lowercased()
            guard name.contains("subagent") || name.contains("cloud") || name.contains("dispatch") else {
                continue
            }
            guard let data = tool.input.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            for key in ["title", "goal", "prompt", "task", "summary"] {
                if let raw = json[key] as? String {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return String(trimmed.prefix(44))
                    }
                }
            }
        }
        return nil
    }

    private static func extractHumanReadableFailureReason(
        from failedStep: ChatToolStepModel,
        tools: [UIMessagePart.Tool],
        steps: [ChatToolStepModel]
    ) -> String? {
        if let detail = failedStep.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty {
            return String(detail.prefix(88))
        }
        // Look up the matching tool's raw output for an error field
        for (tool, step) in zip(tools, steps) where step.id == failedStep.id {
            let rawText = tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n")
            if let extracted = extractErrorMessage(from: rawText) {
                return extracted
            }
        }
        return IOSAppLocalization.string("工具执行返回错误，结果未生效", defaultValue: "工具执行返回错误，结果未生效")
    }

    private static func extractErrorMessage(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "message", "reason", "detail", "stderr"] {
                if let value = json[key] as? String {
                    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        return String(clean.prefix(88))
                    }
                }
            }
        }
        let firstLine = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let firstLine, !firstLine.hasPrefix("{") else { return nil }
        return String(firstLine.prefix(88))
    }

    private static func firstLinePreview(_ text: String) -> String? {
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let line, !line.isEmpty else { return nil }
        return String(line.prefix(56))
    }

    private static func hasUnknownOutcome(_ tool: UIMessagePart.Tool) -> Bool {
        let rawText = tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n")
        guard !rawText.isEmpty,
              let data = rawText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let status = (json["status"] as? String)?.lowercased()
        let outcome = (json["outcome"] as? String)?.lowercased()
        return status == "unknown" || status == "outcome_unknown" || outcome == "unknown" || outcome == "outcome_unknown"
    }

    @MainActor
    private static func reasoningDuration(_ reasoning: UIMessagePart.Reasoning) -> Double? {
        guard let end = reasoning.finishedAt else { return nil }
        let start = MessageBubbleView.instantToDate(reasoning.createdAt)
        let endDate = MessageBubbleView.instantToDate(end)
        return max(0, endDate.timeIntervalSince(start))
    }
}
