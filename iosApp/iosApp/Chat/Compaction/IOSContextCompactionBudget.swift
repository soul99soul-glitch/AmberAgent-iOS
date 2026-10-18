import Foundation
@preconcurrency import Shared

extension IOSContextCompactionCoordinator {
    static let defaultContextWindowTokens = Int(ChatContextSnapshot.defaultContextWindowTokens)
    static let maxTimelineSummaryChars = 1_200
    static let maxHandoffChars = 24_000
    static let maxCompressionTextChars = 48_000
    /// Share of the summarizer's window the summary request may use (the rest is output).
    static let compressionInputRatio = 0.75

    static func estimatePromptTokens(_ text: String) -> Int {
        text.weightedTokenChars / 4 + 1
    }

    static func estimateTokens(_ messages: [UIMessage]) -> Int {
        let chars = messages.reduce(0) { total, message in
            total + message.role.name.count + message.parts.reduce(0) { $0 + estimatedChars($1) }
        }
        return max(chars / 4, messages.count * 4)
    }

    static func nextTurnOccupancyTokens(
        messages: [UIMessage],
        activeCompacts: [IOSConversationCompact],
        draftText: String,
        extraWeightedChars: Int,
        systemOverheadText: String
    ) -> Int {
        // Same image budget as the request; memoized because the gauge re-renders on every
        // stream delta and keystroke, and reused objects keep the estimate memo hitting.
        let messages = IOSToolImageRequestBudget.memoizedApply(messages)
        let existingIds = Set(messages.map(messageId))
        let completed = validCompletedCompacts(activeCompacts, existingMessageIds: existingIds)
        let lastAssistant = messages.last { message in
            guard message.role == MessageRole.assistant, let usage = message.usage else {
                return false
            }
            return usage.promptTokens > 0 || usage.completionTokens > 0
        }
        let lastCompactAt = completed.map(\.createdAt).max()
        let usageIsFresh = lastAssistant.map { assistant in
            guard let lastCompactAt else { return true }
            guard let assistantMillis = ChatContextSnapshot.epochMillis(from: assistant.createdAt) else {
                return false
            }
            return assistantMillis >= lastCompactAt
        } ?? false

        let base: Int
        if usageIsFresh, let lastAssistant, let usage = lastAssistant.usage {
            let tail: [UIMessage]
            if let index = messages.lastIndex(where: { $0.id == lastAssistant.id }) {
                tail = Array(messages.suffix(from: index + 1))
            } else {
                tail = []
            }
            // Tool outputs arrive after this assistant's provider usage was measured.
            let newToolOutputChars = lastAssistant.parts.compactMap { $0 as? UIMessagePart.Tool }
                .flatMap(\.output).reduce(0) { $0 + estimatedChars($1) }
            base = Int(usage.promptTokens) + Int(usage.completionTokens) + newToolOutputChars / 4
                + (tail.isEmpty ? 0 : estimateTokens(tail))
        } else {
            base = estimatePreparedMessages(messages, activeCompacts: completed)
                + estimateDraftTokens(text: systemOverheadText, extraWeightedChars: 0)
        }
        return base + estimateDraftTokens(text: draftText, extraWeightedChars: extraWeightedChars)
    }

    static func estimatePreparedMessages(
        _ messages: [UIMessage],
        activeCompacts: [IOSConversationCompact]
    ) -> Int {
        let existingIds = Set(messages.map(messageId))
        let completed = validCompletedCompacts(activeCompacts, existingMessageIds: existingIds)
        guard !completed.isEmpty else { return estimateTokens(messages) }
        let selected = selectCompactsForInjection(
            activeCompacts: completed,
            existingMessageIds: existingIds
        )
        let summaries = selected.map { UIMessage.companion.system(prompt: injectionText($0)) }
        let covered = Set(completed.flatMap(\.sourceMessageIds))
        let recent = messages.filter { !covered.contains(messageId($0)) }
        return estimateTokens(summaries + recent)
    }

    static func estimateDraftTokens(text: String, extraWeightedChars: Int) -> Int {
        let weighted = text.weightedTokenChars + max(extraWeightedChars, 0)
        guard weighted > 0 else { return 0 }
        return max(weighted / 4, 1)
    }

    static func estimateContextWindow(_ modelContextWindowTokens: Int?) -> Int {
        guard let value = modelContextWindowTokens, value > 0 else {
            return defaultContextWindowTokens
        }
        return value
    }

    static func planCompaction(
        messages: [UIMessage],
        activeCompacts: [IOSConversationCompact],
        policy: IOSCompactPolicy,
        modelContextWindowTokens: Int?,
        extraTokenEstimate: Int
    ) -> IOSCompactPlan {
        guard policy.enabled, !messages.isEmpty else {
            return skipped(reason: "disabled", messages: messages, modelContextWindowTokens: modelContextWindowTokens)
        }
        let estimatedTokens = estimatePreparedMessages(messages, activeCompacts: activeCompacts) + max(extraTokenEstimate, 0)
        let contextWindow = estimateContextWindow(modelContextWindowTokens)
        let ratio = Double(estimatedTokens) / Double(contextWindow)
        guard ratio >= policy.precompactRatio else {
            return IOSCompactPlan(
                shouldCompact: false,
                reason: "below_threshold",
                estimatedTokens: estimatedTokens,
                contextWindowTokens: contextWindow,
                sourceStartIndex: 0,
                sourceEndIndex: -1,
                sourceMessageIds: []
            )
        }

        let keepCount = max(policy.keepRecentTurns * 2, 2)
        let sourceEnd = min(messages.count - 1 - keepCount, messages.count - 1)
        guard sourceEnd >= 1 else {
            return IOSCompactPlan(
                shouldCompact: false,
                reason: "not_enough_history",
                estimatedTokens: estimatedTokens,
                contextWindowTokens: contextWindow,
                sourceStartIndex: 0,
                sourceEndIndex: -1,
                sourceMessageIds: []
            )
        }

        // Coverage is by message id, not stored indices: deletions shift indices, and
        // any uncovered message before the kept tail (including holes left by an
        // invalidated compact) belongs in the next summary.
        let existingIds = Set(messages.map(messageId))
        let coveredIds = Set(validCompletedCompacts(activeCompacts, existingMessageIds: existingIds)
            .flatMap(\.sourceMessageIds))
        var sourceIndices = (0...sourceEnd).filter { !coveredIds.contains(messageId(messages[$0])) }
        // A still-pending tool call at the boundary belongs to the in-flight turn.
        while let last = sourceIndices.last, messageHasPendingTool(messages[last]) {
            sourceIndices.removeLast()
        }
        guard sourceIndices.count >= 2 else {
            return IOSCompactPlan(
                shouldCompact: false,
                reason: coveredIds.isEmpty ? "not_enough_new_history" : "already_compacted",
                estimatedTokens: estimatedTokens,
                contextWindowTokens: contextWindow,
                sourceStartIndex: 0,
                sourceEndIndex: -1,
                sourceMessageIds: []
            )
        }
        return IOSCompactPlan(
            shouldCompact: true,
            reason: ratio >= policy.forceRatio ? "force_threshold" : "precompact_threshold",
            estimatedTokens: estimatedTokens,
            contextWindowTokens: contextWindow,
            sourceStartIndex: sourceIndices[0],
            sourceEndIndex: sourceIndices[sourceIndices.count - 1],
            sourceMessageIds: sourceIndices.map { messageId(messages[$0]) }
        )
    }

    static func planForceCompaction(
        messages: [UIMessage],
        activeCompacts: [IOSConversationCompact],
        policy: IOSCompactPolicy,
        modelContextWindowTokens: Int?
    ) -> IOSCompactPlan {
        var turns: [Int] = []
        var current = max(policy.keepRecentTurns, 1)
        while current > 1 {
            turns.append(current)
            current = max(current / 2, 1)
        }
        turns.append(1)
        turns = Array(NSOrderedSet(array: turns).array as? [Int] ?? turns)

        let contextWindow = estimateContextWindow(modelContextWindowTokens)
        let targetTokens = max(Int(Double(contextWindow) * policy.forceRatio), 1)
        var deepestPlan: IOSCompactPlan?
        var lastPlan: IOSCompactPlan?

        for keepRecentTurns in turns {
            let attemptPolicy = IOSCompactPolicy(
                enabled: true,
                notifyOnly: policy.notifyOnly,
                precompactRatio: 0,
                forceRatio: .greatestFiniteMagnitude,
                keepRecentTurns: keepRecentTurns,
                maxSummaryTokens: policy.maxSummaryTokens
            )
            let plan = planCompaction(
                messages: messages,
                activeCompacts: activeCompacts,
                policy: attemptPolicy,
                modelContextWindowTokens: modelContextWindowTokens,
                extraTokenEstimate: 0
            )
            lastPlan = plan
            if plan.shouldCompact {
                deepestPlan = plan
                if estimateAfterCompaction(
                    messages: messages,
                    activeCompacts: activeCompacts,
                    plan: plan,
                    maxSummaryTokens: policy.maxSummaryTokens
                ) <= targetTokens {
                    return IOSCompactPlan(
                        shouldCompact: true,
                        reason: "force_threshold",
                        estimatedTokens: plan.estimatedTokens,
                        contextWindowTokens: plan.contextWindowTokens,
                        sourceStartIndex: plan.sourceStartIndex,
                        sourceEndIndex: plan.sourceEndIndex,
                        sourceMessageIds: plan.sourceMessageIds
                    )
                }
            }
        }
        return deepestPlan.map {
            IOSCompactPlan(
                shouldCompact: $0.shouldCompact,
                reason: "force_threshold",
                estimatedTokens: $0.estimatedTokens,
                contextWindowTokens: $0.contextWindowTokens,
                sourceStartIndex: $0.sourceStartIndex,
                sourceEndIndex: $0.sourceEndIndex,
                sourceMessageIds: $0.sourceMessageIds
            )
        } ?? lastPlan ?? skipped(
            reason: "not_enough_history",
            messages: messages,
            modelContextWindowTokens: modelContextWindowTokens
        )
    }

    static func prepareMessagesWithCompacts(
        messages: [UIMessage],
        activeCompacts: [IOSConversationCompact],
        policy: IOSCompactPolicy,
        contextMessageSize: Int,
        removedToolResults: Int = 0
    ) -> [UIMessage] {
        guard policy.enabled, !activeCompacts.isEmpty else {
            return limitContext(messages, size: contextMessageSize)
        }
        let existingIds = Set(messages.map(messageId))
        let completed = validCompletedCompacts(activeCompacts, existingMessageIds: existingIds)
        guard !completed.isEmpty else {
            return limitContext(messages, size: contextMessageSize)
        }

        let selected = selectCompactsForInjection(activeCompacts: activeCompacts, existingMessageIds: existingIds)
        let summaries = selected.enumerated().map { index, compact in
            UIMessage.companion.system(prompt: injectionText(
                compact,
                removedToolResults: index == selected.count - 1 ? removedToolResults : 0
            ))
        }
        let coveredIds = Set(completed.flatMap(\.sourceMessageIds))
        let recentMessages = messages.filter { !coveredIds.contains(messageId($0)) }
        // Uncovered messages are the only copy of that history in the request; only an
        // explicit user limit may cut them here. Token pressure is handled by the budget
        // fit, which leaves a visible truncation notice.
        return summaries + limitContext(recentMessages, size: contextMessageSize)
    }

    static func fitMessagesToTokenBudget(_ messages: [UIMessage], maxTokens: Int) -> [UIMessage] {
        let originalCount = messages.count
        guard maxTokens > 0, !messages.isEmpty else {
            return appendingTruncationNotice(
                to: Array(messages.suffix(1)),
                originalCount: originalCount,
                maxTokens: maxTokens
            )
        }
        guard estimateTokens(messages) > maxTokens else { return messages }

        let systemMessages = messages.filter { $0.role == MessageRole.system }
        let tail = messages.filter { $0.role != MessageRole.system }
        var selected: [UIMessage] = []
        for message in tail.reversed() {
            selected.insert(message, at: 0)
            let candidate = systemMessages + selected
            if estimateTokens(candidate) > maxTokens {
                selected.removeFirst()
                if selected.isEmpty {
                    // 唯一候选超预算：不再整条硬保（那会撑爆 assertFitsRequest 让
                    // 请求必败）——先就地截断其工具输出到预算内；无可截工具输出
                    // （纯文本巨消息）才保留旧行为（宁超窗不丢消息）。
                    selected.insert(
                        messageFittedToTokenBudget(message, systemMessages: systemMessages, maxTokens: maxTokens),
                        at: 0
                    )
                }
                break
            }
        }
        var result = systemMessages + selected
        guard estimateTokens(result) > maxTokens else {
            return appendingTruncationNotice(to: result, originalCount: originalCount, maxTokens: maxTokens)
        }

        result = trimmingCompactHandoffSystemMessages(in: result, maxTokens: maxTokens)
        guard estimateTokens(result) > maxTokens else {
            return appendingTruncationNotice(to: result, originalCount: originalCount, maxTokens: maxTokens)
        }

        let compactIndexes = result.indices.filter { isCompactHandoffSystemMessage(result[$0]) }
        if compactIndexes.count > 1 {
            let newestCompactIndex = compactIndexes.last
            result = result.enumerated().compactMap { index, message in
                if isCompactHandoffSystemMessage(message), index != newestCompactIndex {
                    return nil
                }
                return message
            }
        }
        return appendingTruncationNotice(to: result, originalCount: originalCount, maxTokens: maxTokens)
    }

    /// 截尾兜底：唯一候选消息超预算时,先就地截断其工具输出到预算内(单条输出
    /// 逐级压小 + 截断标记),让已持久化的巨量工具输出在请求时被救活;无可截的
    /// 纯文本巨消息返回原样(旧行为:宁超窗不丢消息)。
    static func messageFittedToTokenBudget(
        _ message: UIMessage,
        systemMessages: [UIMessage],
        maxTokens: Int
    ) -> UIMessage {
        if estimateTokens(systemMessages + [message]) <= maxTokens { return message }
        var fitted = message
        var fit = false
        for limit in [12_000, 8_000, 6_000, 4_000, 3_000, 2_000, 1_500, 1_000, 800, 600, 400, 200] {
            fitted = truncatingToolOutputs(in: message, maxCharsPerOutput: limit)
            if estimateTokens(systemMessages + [fitted]) <= maxTokens {
                fit = true
                break
            }
        }
        return fit ? fitted : message
    }

    /// 就地截断消息中所有工具输出的文本部分。复用收口上限语义:JSON 形态保形
    /// 截断、已带压缩标记的输出不二次截断、多模态输出不动。
    static func truncatingToolOutputs(in message: UIMessage, maxCharsPerOutput: Int) -> UIMessage {
        let parts = message.parts.map { part -> UIMessagePart in
            guard let tool = part as? UIMessagePart.Tool, !tool.output.isEmpty else { return part }
            let capped = ChatToolOutputFormatter.cappedToolOutputParts(tool.output, maxChars: maxCharsPerOutput)
            guard capped != tool.output else { return part }
            return PromptTranscript.shared.doCopyTool(
                tool: tool,
                input: tool.input,
                output: capped
            )
        }
        return UIMessage(
            id: message.id,
            role: message.role,
            parts: parts,
            annotations: message.annotations,
            createdAt: message.createdAt,
            finishedAt: message.finishedAt,
            modelId: message.modelId,
            usage: message.usage,
            translation: message.translation
        )
    }

    /// 截尾不能静默:若 `fitMessagesToTokenBudget` 实际丢弃了消息,在注入侧追加一条
    /// system 说明,让模型知道历史有空洞。受 `maxTokens` 预算约束——预算极端紧张时
    /// 宁可不加注记也不能让请求超窗失败。
    static func appendingTruncationNotice(
        to fitted: [UIMessage],
        originalCount: Int,
        maxTokens: Int
    ) -> [UIMessage] {
        let droppedCount = originalCount - fitted.count
        guard droppedCount > 0 else { return fitted }
        let notice = UIMessage.companion.system(prompt: truncationNoticeText(droppedMessages: droppedCount))
        let withNotice = fitted + [notice]
        guard estimateTokens(withNotice) <= maxTokens else { return fitted }
        return withNotice
    }

    static func truncationNoticeText(droppedMessages: Int) -> String {
        "Context note: \(droppedMessages) older message(s) were omitted from this request to fit the model's token budget. If you need their content, re-run the relevant tool or expand history; the original conversation storage is unchanged."
    }

    static func requestOverheadTokens(
        params: TextGenerationParams,
        promptOverheadTokens: Int = 0
    ) -> Int {
        let toolChars = params.tools.reduce(0) { total, tool in
            total +
                tool.name.count +
                tool.description_.count +
                String(describing: tool.parameters()).count
        }
        let headerChars = params.customHeaders.reduce(0) { total, header in
            total + header.name.count + header.value.count
        }
        let bodyChars = params.customBody.reduce(0) { total, body in
            total + body.key.count + String(describing: body.value).count
        }
        return (toolChars + headerChars + bodyChars) / 4 + max(promptOverheadTokens, 0)
    }

    static func assertFitsRequest(
        messages: [UIMessage],
        overheadTokens: Int,
        forceBudget: Int
    ) throws {
        let estimate = estimateTokens(messages) + max(overheadTokens, 0)
        guard estimate <= forceBudget else {
            throw NSError(
                domain: "AmberAgent.ContextCompaction",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "上下文压缩后仍超过模型窗口预算（估算 \(estimate) / \(forceBudget) tokens）。请减少历史、关闭部分工具或换更大上下文模型。"
                ]
            )
        }
    }

    static func trimmingCompactHandoffSystemMessages(in messages: [UIMessage], maxTokens: Int) -> [UIMessage] {
        var result = messages
        for maxChars in [12_000, 6_000, 3_000, 1_500, 800] {
            result = result.map { message in
                guard isCompactHandoffSystemMessage(message),
                      let text = systemText(message),
                      text.count > maxChars else {
                    return message
                }
                return UIMessage.companion.system(prompt: compactHandoffText(text, maxChars: maxChars))
            }
            if estimateTokens(result) <= maxTokens {
                return result
            }
        }
        return result
    }

    static func isCompactHandoffSystemMessage(_ message: UIMessage) -> Bool {
        guard message.role == MessageRole.system,
              let text = systemText(message) else { return false }
        return text.hasPrefix("[Conversation compact handoff:")
    }

    static func systemText(_ message: UIMessage) -> String? {
        let text = message.parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    static func compactHandoffText(_ text: String, maxChars: Int) -> String {
        let split = text.range(of: "\n\n")
        let header = split.map { String(text[..<$0.lowerBound]) } ?? ""
        let bodyStart = split.map(\.upperBound) ?? text.startIndex
        let body = String(text[bodyStart...])
        let trimmedBody = body.takeMiddle(maxChars: max(maxChars, 200))
        if header.isEmpty {
            return trimmedBody
        }
        return "\(header)\n\n\(trimmedBody)"
    }

    /// 发送前静默裁剪/清空旧消息工具结果的入口。返回处理后的消息,以及被改动过的
    /// 工具结果条数(trim 或 clear 任一生效都算,不重复计数),供 handoff 注入如实
}
