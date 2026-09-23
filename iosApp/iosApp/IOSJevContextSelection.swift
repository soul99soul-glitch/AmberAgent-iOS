import Foundation
import CryptoKit
@preconcurrency import Shared

// MARK: - Jev 上下文筛选（Phase 2）
//
// 契约（计划 Phase 2）：
// - 第一版只处理已完成、超过 8,000 字符的工具文本输出；系统/用户消息、权限、
//   工具参数、待执行调用、当前用户约束不筛。
// - 按完整段落/结构块切分（围栏代码块/表格不拆坏；无法安全分割整块保留），
//   每块携带 messageId、toolCallId、blockId 与真实来源。
// - 程序先标记必须保留：错误/审批、未知执行状态、分页 token、用户明确要求
//   全文；Jev 仅对剩余块评相关性，低分且无保留信号才隐藏。
// - 只改请求副本：隐藏块替换为省略标记 + 可调用恢复引用（用相同参数重新调用
//   原工具），不改变 tool call ID、结果对应关系、持久化历史与 canonical 原文。
// - 首次使用后按会话、toolCallId、输出 SHA-256 与策略版本固定；失败固定为全文。
// - 每轮重放已固定的所有历史输出，仅把新输出加入本轮评估。
// - 失败/超时/不确定 → 保留全文。压缩摘要来源始终是 canonical 原文。
// - 恢复路径：iOS 无 conversation_expand 执行器（已核实）；恢复 = 原工具重读
//   或 session_read。无安全重读路径的类型不启用隐藏（v1 只处理可重读的只读
//   检索类输出，写入类工具输出一律不筛）。

@MainActor
final class IOSJevContextSelectionService {

    struct RunIdentity: Sendable {
        var runId: String?
        var conversationId: String? = nil
    }

    struct Block: Equatable, Sendable {
        var index: Int
        var text: String
        var mustKeep: Bool
        var keepReason: String?
    }

    private struct ShadowProjectionCandidate: Sendable {
        var blocks: [Block]
        var outputToken: String?
        var outputMultiplicity: Int
    }

    private struct OutputCandidate {
        var messageIndex: Int
        var partIndex: Int
        var toolPart: UIMessagePart.Tool
        var blocks: [Block]
        var outputHash: String
        var outputCharacterCount: Int
    }

    private struct ProjectionKey: Hashable {
        var conversationId: String
        var toolCallId: String
        var outputHash: String
        var policyVersion: Int
    }

    private struct OutputGroup {
        var key: ProjectionKey
        var outputs: [OutputCandidate]
    }

    private struct HiddenOutputSource {
        var messageIndex: Int
        var toolCallId: String
        var toolName: String
        var inputHash: String
    }

    private enum ProjectionDecision {
        case keepFull
        case hide(Set<Int>)
    }

    private struct QuestionTarget {
        var block: Block
        var questionId: String
    }

    /// 可安全重读的只读检索类工具（写入/提交类与 MCP/http 通用调用一律不筛：
    /// 其副作用语义无法静态判定，重读引用可能诱导副作用重放）。
    /// search_web 同参重调是活网非确定性结果，"重读恢复原文"承诺不成立，v1 不筛。
    private static let rereadableToolPrefixes: Set<String> = [
        "workspace_file_read", "file_read", "workspace_artifact_read",
        "scrape_web", "wm_extract", "wm_observe",
        "session_read", "session_search",
        "workspace_file_search", "file_search", "workspace_file_list", "file_list",
    ]

    /// 用户明确要求全文的标记（出现即整轮不筛；中英文覆盖）。
    private static let fullTextDemandMarkers: [String] = [
        "全文", "逐字", "原文", "完整地", "完整的", "逐段", "不要省略", "不要删减",
        "verbatim", "full text", "word for word", "don't truncate", "do not truncate",
    ]

    private static let mergedBlockTargetCharacters = 1_800
    private static let mergedBlockMaximumCharacters = 2_000
    private static let inspectedExcerptCharacters = 1_000

    struct Dependencies {
        let coordinator: IOSJevDecisionCoordinator
        let settingsProvider: () -> IOSJevSettings
    }

    private let deps: Dependencies
    /// 已完成输出的稳定投影，App 重启后清空。当前会话仍在历史中的键不会淘汰；
    /// 容量只清理其它会话的旧键，因此长会话可以超过配置容量以维持逐轮固定。
    private var projectionDecisions: [ProjectionKey: ProjectionDecision] = [:]
    private var projectionDecisionOrder: [ProjectionKey] = []
    /// 同一轮相同输入只做一次 shadow 观测。
    private var shadowObservedByTurn: [String: String] = [:]

    init(deps: Dependencies) {
        self.deps = deps
    }

    private func decision(for key: ProjectionKey) -> ProjectionDecision? {
        guard let value = projectionDecisions[key] else { return nil }
        if let index = projectionDecisionOrder.firstIndex(of: key) {
            projectionDecisionOrder.remove(at: index)
        }
        projectionDecisionOrder.append(key)
        return value
    }

    private func remember(_ decision: ProjectionDecision, for key: ProjectionKey, maxEntries: Int) {
        if let index = projectionDecisionOrder.firstIndex(of: key) {
            projectionDecisionOrder.remove(at: index)
        }
        projectionDecisions[key] = decision
        projectionDecisionOrder.append(key)
        trimInactiveConversationEntries(protectedConversationId: key.conversationId, maxEntries: maxEntries)
    }

    private func pruneProjectionDecisions(
        conversationId: String,
        retaining activeKeys: Set<ProjectionKey>,
        maxEntries: Int
    ) {
        let staleKeys = projectionDecisionOrder.filter {
            $0.conversationId == conversationId && !activeKeys.contains($0)
        }
        for key in staleKeys { projectionDecisions.removeValue(forKey: key) }
        projectionDecisionOrder.removeAll { staleKeys.contains($0) }
        trimInactiveConversationEntries(protectedConversationId: conversationId, maxEntries: maxEntries)
    }

    private func trimInactiveConversationEntries(protectedConversationId: String, maxEntries: Int) {
        let capacity = max(1, maxEntries)
        while projectionDecisionOrder.count > capacity,
              let index = projectionDecisionOrder.firstIndex(where: { $0.conversationId != protectedConversationId }) {
            let inactive = projectionDecisionOrder.remove(at: index)
            projectionDecisions.removeValue(forKey: inactive)
        }
    }

    static let shared = IOSJevContextSelectionService(deps: .init(
        coordinator: .shared,
        settingsProvider: { IOSSharedSettingsStore.loadPersistedJevSettings() }
    ))

    // MARK: Public entry（Host 每轮调用一次）

    /// 返回筛选投影后的请求副本。off / shadow / 无稳定会话 ID → 原样返回。
    func projectedMessages(
        _ messages: [UIMessage],
        identity: RunIdentity
    ) async -> [UIMessage] {
        let settings = deps.settingsProvider()
        let mode = settings.effectiveMode(for: .contextSelection)
        guard mode != .off else {
            recordProjectionSummary(
                hiddenCharacters: 0, hiddenBlocks: 0, originalCharacters: 0,
                rereadAfterHideCount: 0, identity: identity, settings: settings
            )
            return messages
        }
        guard let conversationId = identity.conversationId, !conversationId.isEmpty else { return messages }

        let taskText = messages.reversed().first { $0.role == MessageRole.user }?.toText() ?? ""
        // 用户明确要求全文：本轮全部跳过（shadow 也不外发——没有判断必要）。
        let userDemandsFullText = Self.fullTextDemandMarkers.contains { taskText.localizedCaseInsensitiveContains($0) }
        if userDemandsFullText { return messages }

        let outputs = candidateOutputs(in: messages)
        let activeKeys = Set(outputs.map { output in
            ProjectionKey(
                conversationId: conversationId,
                toolCallId: output.toolPart.toolCallId,
                outputHash: output.outputHash,
                policyVersion: settings.policy.policyVersion
            )
        })
        pruneProjectionDecisions(
            conversationId: conversationId,
            retaining: activeKeys,
            maxEntries: settings.policy.cacheMaxEntries
        )
        guard !outputs.isEmpty else {
            recordProjectionSummary(
                hiddenCharacters: 0, hiddenBlocks: 0, originalCharacters: 0,
                rereadAfterHideCount: 0, identity: identity, settings: settings
            )
            return messages
        }

        let requiredScopes: Set<IOSJevDataScope> = [.selectedTaskText, .toolOutput]
        guard settings.canSend(useCase: .contextSelection, required: requiredScopes) else { return messages }

        // 只把本次入口前已经固定为隐藏的输出作为归因来源。这样当同一历史快照
        // 首次得到隐藏决策时，不会把此前已经发生的同参调用倒算成“隐藏后重读”。
        let rereadAfterHideCount = countRereadsAfterHide(
            in: messages,
            outputs: outputs,
            conversationId: conversationId,
            policyVersion: settings.policy.policyVersion
        )

        var projectedMessages = messages
        var hiddenCharacters = 0
        var hiddenBlocks = 0
        var groups: [OutputGroup] = []
        var groupIndices: [ProjectionKey: Int] = [:]

        for output in outputs {
            let key = ProjectionKey(
                conversationId: conversationId,
                toolCallId: output.toolPart.toolCallId,
                outputHash: output.outputHash,
                policyVersion: settings.policy.policyVersion
            )
            if let index = groupIndices[key] {
                groups[index].outputs.append(output)
                continue
            }
            groupIndices[key] = groups.count
            groups.append(OutputGroup(key: key, outputs: [output]))
        }

        var undecided: [OutputGroup] = []
        for group in groups {
            guard mode == .active, let stored = decision(for: group.key) else {
                undecided.append(group)
                continue
            }
            if case .hide(let indices) = stored, !indices.isEmpty {
                for output in group.outputs {
                    hiddenCharacters += output.blocks.filter { indices.contains($0.index) }.reduce(0) { $0 + $1.text.count }
                    hiddenBlocks += output.blocks.filter { indices.contains($0.index) }.count
                    projectedMessages = Self.projecting(
                        messages: projectedMessages,
                        messageIndex: output.messageIndex,
                        partIndex: output.partIndex,
                        toolPart: output.toolPart,
                        hiddenIndices: indices
                    )
                }
            }
        }

        if mode == .active {
            let retainedCount = projectionDecisions.keys.filter { $0.conversationId == conversationId }.count
            let availableSlots = max(0, max(1, settings.policy.cacheMaxEntries) - retainedCount)
            if undecided.count > availableSlots {
                let overflow = undecided.dropFirst(availableSlots)
                undecided = Array(undecided.prefix(availableSlots))
                // 不再给超容量的新输出发起判断，但保存全文决策，避免下一轮重试。
                for group in overflow {
                    remember(.keepFull, for: group.key, maxEntries: settings.policy.cacheMaxEntries)
                }
            }
        }

        guard !undecided.isEmpty else {
            recordProjectionSummary(
                hiddenCharacters: hiddenCharacters,
                hiddenBlocks: hiddenBlocks,
                originalCharacters: outputs.reduce(0) { $0 + $1.outputCharacterCount },
                rereadAfterHideCount: rereadAfterHideCount,
                identity: identity,
                settings: settings
            )
            return projectedMessages
        }

        // maxCandidates 限制本地状态规模；协调器会把超过单请求 maxQuestions 的题拆成并行请求。
        let targets = Self.questionTargets(
            outputs: undecided.map { $0.outputs[0] },
            questionLimit: settings.policy.maxCandidates,
            maxStateBytes: settings.policy.maxStateBytes,
            taskText: taskText
        )

        guard !targets.isEmpty else {
            if mode == .active {
                for item in undecided { remember(.keepFull, for: item.key, maxEntries: settings.policy.cacheMaxEntries) }
                recordProjectionSummary(
                    hiddenCharacters: hiddenCharacters,
                    hiddenBlocks: hiddenBlocks,
                    originalCharacters: outputs.reduce(0) { $0 + $1.outputCharacterCount },
                    rereadAfterHideCount: rereadAfterHideCount,
                    identity: identity,
                    settings: settings
                )
            }
            return projectedMessages
        }

        let state = Self.stateText(taskText: taskText, targets: targets)
        let questions = targets.map { target in
            IOSJevQuestion.score(
                id: target.questionId,
                levels: Self.relevanceLevels,
                instructions: "评估该内容块对当前任务的相关性。只判断块内文本是否可能包含完成任务所需的信息。"
            )
        }
        let context = IOSJevRunContext(
            runId: identity.runId,
            turnBudgetKey: identity.runId ?? conversationId,
            inputHash: IOSJevToolDiscoveryService.stableHash(state)
        )

        if mode == .shadow {
            // 当前调用不会实际隐藏输出；如本 run 曾有 active 投影摘要，先清除实际值。
            // hypothetical 结果由 coordinator 的 shadow decision 数字单独记录。
            recordProjectionSummary(
                hiddenCharacters: 0, hiddenBlocks: 0, originalCharacters: 0,
                rereadAfterHideCount: 0, identity: identity, settings: settings
            )
            let turnKey = identity.runId ?? conversationId
            if let observed = shadowObservedByTurn[turnKey], observed == context.inputHash {
                return messages
            }
            shadowObservedByTurn[turnKey] = context.inputHash
            if shadowObservedByTurn.count > 16 {
                shadowObservedByTurn.removeAll(keepingCapacity: true)
            }
            let coordinator = deps.coordinator
            let shadowCandidates = undecided.map { item in
                let representative = item.outputs[0]
                return ShadowProjectionCandidate(
                    blocks: representative.blocks.filter { !$0.mustKeep },
                    outputToken: undecided.count > 1 ? Self.outputQuestionToken(representative) : nil,
                    outputMultiplicity: item.outputs.count
                )
            }
            let originalCharacters = outputs.reduce(0) { $0 + $1.outputCharacterCount }
            let minimumScore = settings.policy.contextSelectionMinScore
            let minimumConfidence = settings.policy.contextSelectionMinConfidence
            let metricNumbersProvider: @Sendable (IOSJevDecision) -> [String: Double]? = { decision in
                var hiddenCharacters = 0
                for candidate in shadowCandidates {
                    let hiddenIndices = Set(Self.hiddenBlockIndices(
                        candidates: candidate.blocks,
                        decision: decision,
                        outputToken: candidate.outputToken,
                        minScore: minimumScore,
                        minConfidence: minimumConfidence
                    ))
                    let outputHiddenCharacters = candidate.blocks
                        .filter { hiddenIndices.contains($0.index) }
                        .reduce(0) { $0 + $1.text.count }
                    hiddenCharacters += outputHiddenCharacters * candidate.outputMultiplicity
                }
                return [
                    "shadow_hidden_characters": Double(hiddenCharacters),
                    "shadow_original_characters": Double(originalCharacters),
                ]
            }
            Task(priority: .utility) {
                _ = await coordinator.decide(
                    useCase: .contextSelection,
                    requiredScopes: requiredScopes,
                    state: state,
                    questions: questions,
                    context: context,
                    cacheKey: "context_shadow",
                    waitBudgetMs: settings.policy.t2WaitBudgetMs,
                    expectedSettingsRevision: settings.revision,
                    metricNumbersProvider: metricNumbersProvider
                )
            }
            return messages
        }

        let outcome = await deps.coordinator.decide(
            useCase: .contextSelection,
            requiredScopes: requiredScopes,
            state: state,
            questions: questions,
            context: context,
            cacheKey: "context_active",
            waitBudgetMs: settings.policy.t2WaitBudgetMs
        )

        guard case .applied(let decision) = outcome else {
            for item in undecided { remember(.keepFull, for: item.key, maxEntries: settings.policy.cacheMaxEntries) }
            recordProjectionSummary(
                hiddenCharacters: hiddenCharacters,
                hiddenBlocks: hiddenBlocks,
                originalCharacters: outputs.reduce(0) { $0 + $1.outputCharacterCount },
                rereadAfterHideCount: rereadAfterHideCount,
                identity: identity,
                settings: settings
            )
            return projectedMessages
        }

        for item in undecided {
            let representative = item.outputs[0]
            let candidates = representative.blocks.filter { !$0.mustKeep }
            let hidden = Set(Self.hiddenBlockIndices(
                candidates: candidates,
                decision: decision,
                outputToken: undecided.count > 1 ? Self.outputQuestionToken(representative) : nil,
                minScore: settings.policy.contextSelectionMinScore,
                minConfidence: settings.policy.contextSelectionMinConfidence
            ))
            let stored: ProjectionDecision = hidden.isEmpty ? .keepFull : .hide(hidden)
            remember(stored, for: item.key, maxEntries: settings.policy.cacheMaxEntries)
            if !hidden.isEmpty {
                for output in item.outputs {
                    hiddenCharacters += output.blocks.filter { hidden.contains($0.index) }.reduce(0) { $0 + $1.text.count }
                    hiddenBlocks += output.blocks.filter { hidden.contains($0.index) }.count
                    projectedMessages = Self.projecting(
                        messages: projectedMessages,
                        messageIndex: output.messageIndex,
                        partIndex: output.partIndex,
                        toolPart: output.toolPart,
                        hiddenIndices: hidden
                    )
                }
            }
        }
        recordProjectionSummary(
            hiddenCharacters: hiddenCharacters,
            hiddenBlocks: hiddenBlocks,
            originalCharacters: outputs.reduce(0) { $0 + $1.outputCharacterCount },
            rereadAfterHideCount: rereadAfterHideCount,
            identity: identity,
            settings: settings
        )
        return projectedMessages
    }

    private func recordProjectionSummary(
        hiddenCharacters: Int,
        hiddenBlocks: Int,
        originalCharacters: Int,
        rereadAfterHideCount: Int,
        identity: RunIdentity,
        settings: IOSJevSettings
    ) {
        let clearsPreviousSnapshot = hiddenCharacters == 0
        guard !clearsPreviousSnapshot || hasT2ProjectionSummary(runId: identity.runId) else { return }
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: Date(),
            useCase: .contextSelection,
            mode: .active,
            modelVersion: settings.activeModelVersion,
            // 数值摘要不计作一次 Jev 决策或请求。
            outcome: "summary",
            latencyMs: 0,
            requestBytes: 0,
            responseBytes: 0,
            inputTokens: nil,
            outputTokens: nil,
            reason: nil,
            suggestedTop1: nil,
            keywordTop1: nil,
            topConfidence: nil,
            topScore: nil,
            runId: identity.runId,
            waitPhase: "T2",
            waitedMs: nil,
            numbers: [
                "hidden_characters": Double(clearsPreviousSnapshot ? 0 : hiddenCharacters),
                "original_characters": Double(clearsPreviousSnapshot ? 0 : originalCharacters),
                "hidden_blocks": Double(clearsPreviousSnapshot ? 0 : hiddenBlocks),
                "reread_after_hide_count": Double(clearsPreviousSnapshot ? 0 : rereadAfterHideCount),
            ],
            ids: nil
        ))
    }

    private func hasT2ProjectionSummary(runId: String?) -> Bool {
        guard let runId, !runId.isEmpty else { return false }
        return IOSJevMetricsStore.load().contains { record in
            record.runId == runId
                && record.useCase == .contextSelection
                && record.outcome == "summary"
                && record.waitPhase == "T2"
                && record.numbers?["hidden_characters"] != nil
        }
    }

    /// 只统计已完成的工具输出：同一个 canonical toolCallId 会在后续上传中反复出现，
    /// 因而必须是来源输出之后的新 ID，且工具名和 JSON 参数完全一致。
    private func countRereadsAfterHide(
        in messages: [UIMessage],
        outputs: [OutputCandidate],
        conversationId: String,
        policyVersion: Int
    ) -> Int {
        let hiddenSources = outputs.compactMap { output -> HiddenOutputSource? in
            let key = ProjectionKey(
                conversationId: conversationId,
                toolCallId: output.toolPart.toolCallId,
                outputHash: output.outputHash,
                policyVersion: policyVersion
            )
            guard let decision = projectionDecisions[key],
                  case .hide(let indices) = decision,
                  !indices.isEmpty,
                  let inputHash = Self.canonicalToolInputHash(output.toolPart.input) else {
                return nil
            }
            return HiddenOutputSource(
                messageIndex: output.messageIndex,
                toolCallId: output.toolPart.toolCallId,
                toolName: output.toolPart.toolName,
                inputHash: inputHash
            )
        }
        guard !hiddenSources.isEmpty else { return 0 }

        var rereadToolCallIds: Set<String> = []
        for messageIndex in messages.indices {
            let message = messages[messageIndex]
            guard message.role == MessageRole.tool else { continue }
            for part in message.parts {
                guard let tool = part as? UIMessagePart.Tool,
                      tool.isExecuted,
                      Self.isRereadableTool(tool.toolName),
                      let inputHash = Self.canonicalToolInputHash(tool.input) else {
                    continue
                }
                let followsHiddenOutput = hiddenSources.contains { source in
                    messageIndex > source.messageIndex
                        && tool.toolCallId != source.toolCallId
                        && tool.toolName == source.toolName
                        && inputHash == source.inputHash
                }
                if followsHiddenOutput {
                    rereadToolCallIds.insert(tool.toolCallId)
                }
            }
        }
        return rereadToolCallIds.count
    }

    /// 参数只在本地比较，metrics 仅存投影结果的数值。要求合法 JSON 对象，避免
    /// 因空值、损坏输入或任意字符串碰巧相同而把调用归为同参重读。
    private static func canonicalToolInputHash(_ input: String) -> String? {
        guard let data = input.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              value is [String: Any],
              let canonical = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: canonical, encoding: .utf8) else {
            return nil
        }
        return contentHash(text)
    }

    // MARK: Candidate discovery

    /// 返回历史中所有可筛的超长已完成工具输出。
    private func candidateOutputs(in messages: [UIMessage], minOutputChars: Int = 8_000) -> [OutputCandidate] {
        var outputs: [OutputCandidate] = []
        for messageIndex in messages.indices {
            let message = messages[messageIndex]
            guard message.role == MessageRole.tool else { continue }
            for partIndex in message.parts.indices {
                guard let tool = message.parts[partIndex] as? UIMessagePart.Tool else { continue }
                guard tool.isExecuted, !tool.output.isEmpty, Self.isRereadableTool(tool.toolName) else { continue }
                let textParts = tool.output.compactMap { $0 as? UIMessagePart.Text }
                guard textParts.count == 1, let onlyText = textParts.first else { continue }
                let text = onlyText.text
                guard text.count > minOutputChars, !Self.containsOmissionMarker(text) else { continue }
                let segments = Self.splitBlocks(text)
                guard segments.count > 1 else { continue }
                let blocks = segments.map { segment in
                    let (mustKeep, reason) = Self.mustKeepSignal(toolName: tool.toolName, text: segment.text)
                    return Block(index: segment.index, text: segment.text, mustKeep: mustKeep, keepReason: reason)
                }
                outputs.append(OutputCandidate(
                    messageIndex: messageIndex,
                    partIndex: partIndex,
                    toolPart: tool,
                    blocks: blocks,
                    outputHash: Self.contentHash(text),
                    outputCharacterCount: text.count
                ))
            }
        }
        return outputs
    }

    /// 保留给离线测试使用，生产入口会遍历全部输出。
    func candidateBlocks(
        in messages: [UIMessage],
        taskText: String,
        minOutputChars: Int = 8_000
    ) -> (messageIndex: Int, toolPart: UIMessagePart.Tool, blocks: [Block])? {
        guard let output = candidateOutputs(in: messages, minOutputChars: minOutputChars).first else { return nil }
        return (output.messageIndex, output.toolPart, output.blocks)
    }

    static func isRereadableTool(_ name: String) -> Bool {
        rereadableToolPrefixes.contains(name)
    }

    // MARK: Splitting（结构块不拆坏）

    /// 相邻段落合并到约 1,800 字；围栏代码块和 Markdown 表格作为完整结构块保留。
    /// 超长段落或结构块不拆分。range 覆盖原文中的块内容，投影时块间空白原样保留。
    static func splitBlocks(_ text: String) -> [(index: Int, text: String, range: Range<String.Index>)] {
        struct Line {
            var start: String.Index
            var end: String.Index
            var content: String
        }
        struct Segment {
            var text: String
            var range: Range<String.Index>
            var isAtomic: Bool
        }

        var lines: [Line] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let end = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
            lines.append(Line(start: cursor, end: end, content: String(text[cursor..<end])))
            guard end < text.endIndex else { break }
            cursor = text.index(after: end)
        }

        func trimmedLine(_ index: Int) -> String {
            lines[index].content.trimmingCharacters(in: .whitespaces)
        }
        func isFence(_ index: Int) -> Bool {
            trimmedLine(index).hasPrefix("```")
        }
        func isTableStart(_ index: Int) -> Bool {
            guard index + 1 < lines.count else { return false }
            let header = trimmedLine(index)
            let separator = trimmedLine(index + 1)
            guard header.contains("|"), separator.contains("|") else { return false }
            let cells = separator.filter { $0 == "-" || $0 == ":" || $0 == "|" || $0.isWhitespace }
            return cells.count == separator.count && separator.contains("-")
        }

        func makeSegment(from first: Int, through last: Int, atomic: Bool) -> Segment? {
            guard first <= last else { return nil }
            let range = lines[first].start..<lines[last].end
            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return Segment(text: value, range: range, isAtomic: atomic)
        }

        var segments: [Segment] = []
        var index = 0
        while index < lines.count {
            if trimmedLine(index).isEmpty {
                index += 1
                continue
            }

            if isFence(index) {
                let start = index
                index += 1
                while index < lines.count {
                    let closesFence = isFence(index)
                    index += 1
                    if closesFence { break }
                }
                if let segment = makeSegment(from: start, through: index - 1, atomic: true) {
                    segments.append(segment)
                }
                continue
            }

            if isTableStart(index) {
                let start = index
                index += 2
                while index < lines.count,
                      !trimmedLine(index).isEmpty,
                      trimmedLine(index).contains("|") {
                    index += 1
                }
                if let segment = makeSegment(from: start, through: index - 1, atomic: true) {
                    segments.append(segment)
                }
                continue
            }

            let start = index
            index += 1
            while index < lines.count,
                  !trimmedLine(index).isEmpty,
                  !isFence(index),
                  !isTableStart(index) {
                index += 1
            }
            if let segment = makeSegment(from: start, through: index - 1, atomic: false) {
                segments.append(segment)
            }
        }

        var merged: [Segment] = []
        var pending: Segment?
        func flushPending() {
            if let pending { merged.append(pending) }
            pending = nil
        }

        for segment in segments {
            if segment.isAtomic {
                flushPending()
                merged.append(segment)
                continue
            }
            guard let current = pending else {
                pending = segment
                continue
            }
            let combinedRange = current.range.lowerBound..<segment.range.upperBound
            let combinedText = String(text[combinedRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldJoin = current.text.count < mergedBlockTargetCharacters
                && combinedText.count <= mergedBlockMaximumCharacters
            if shouldJoin {
                pending = Segment(text: combinedText, range: combinedRange, isAtomic: false)
            } else {
                flushPending()
                pending = segment
            }
        }
        flushPending()

        return merged.enumerated().map { (index: $0.offset, text: $0.element.text, range: $0.element.range) }
    }

    // MARK: Must-keep signals

    static func mustKeepSignal(toolName: String, text: String) -> (Bool, String?) {
        // 只识别有明确结构的失败和状态字段，以及行首日志标记；普通正文里的
        // todo / cursor / error 等词不再阻止筛选。
        if matches(#"(?i)\"(?:ok|success)\"\s*:\s*false\b"#, in: text)
            || matches(#"(?i)\"iserror\"\s*:\s*true\b"#, in: text)
            || matches(#"(?i)\"status\"\s*:\s*\"(?:error|failed)\""#, in: text)
            || matches(#"(?im)^\s*(?:ERROR|FATAL)\s*:"#, in: text)
            || matches(#"(?im)^\s*Traceback(?:\s|\(|:)"#, in: text)
            || matches(#"(?im)^\s*失败[：:]"#, in: text) {
            return (true, "error_output")
        }

        if matches(#"(?i)\"status\"\s*:\s*\"unknown_after_action\""#, in: text)
            || matches(#"(?i)\"may_have_applied\"\s*:\s*true\b"#, in: text) {
            return (true, "unknown_execution_state")
        }

        if matches(#"(?i)\"needs_approval\"\s*:\s*true\b"#, in: text)
            || matches(#"(?im)^\s*(?:需要确认|需要审批)"#, in: text) {
            return (true, "approval")
        }

        if matches(#"(?im)^\s*TODO\s*:"#, in: text)
            || matches(#"(?im)^\s*(?:待办|未完成)\s*[：:]"#, in: text) {
            return (true, "unresolved_todo")
        }

        if matches(#"(?i)\"has_more\"\s*:\s*true\b"#, in: text)
            || matches(#"(?i)\"(?:next_offset|next_page|next_cursor|page_token|continuation_token|next_token)\"\s*:"#, in: text)
            || matches(#"(?im)^\s*(?:next_offset|next_page|next_cursor|page_token|continuation_token|next_token)\s*[:=]\s*\S+"#, in: text) {
            return (true, "continuation_token")
        }
        return (false, nil)
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Jev decision application

    /// 只有低分块被隐藏；缺题/无效/低置信/不确定一律保留（缺失不等于 0 分）。
    nonisolated static func hiddenBlockIndices(
        candidates: [Block],
        decision: IOSJevDecision,
        outputToken: String? = nil,
        minScore: Double,
        minConfidence: Double? = nil
    ) -> [Int] {
        var scores: [Int: Double] = [:]
        var confidences: [Int: Double] = [:]
        let answerPrefix = outputToken.map { "\($0)_b" } ?? "b"
        for answer in decision.answers where answer.type == "score" {
            guard answer.id.hasPrefix(answerPrefix), let index = Int(answer.id.dropFirst(answerPrefix.count)),
                  let score = answer.score else { continue }
            scores[index] = score
            if let confidence = answer.confidence { confidences[index] = confidence }
        }
        return candidates
            .filter { block in
                // 缺题（无评分）= 不确定 → 保留。
                guard let score = scores[block.index] else { return false }
                // 低置信 = 不确定 → 保留；置信缺失不门控。
                if let minConfidence, let confidence = confidences[block.index], confidence < minConfidence { return false }
                return score < minScore
            }
            .map(\.index)
    }

    // MARK: Projection（只改请求副本）

    static func omissionMarker(toolCallId: String, toolName: String, blockIndex: Int) -> String {
        "[AmberAgent 上下文筛选：本块与当前任务相关性低，已省略。来源 toolCallId=\(toolCallId) 工具=\(toolName) 块=\(blockIndex)。如需该部分原文，请用相同参数重新调用该工具。]"
    }

    static func containsOmissionMarker(_ text: String) -> Bool {
        // 完整形状匹配，降低合法文本误判为"已投影"的概率（方向保守：宁可重判）。
        text.contains("[AmberAgent 上下文筛选：") && text.contains("重新调用该工具。]")
    }

    static func projecting(
        messages: [UIMessage],
        messageIndex: Int,
        partIndex: Int? = nil,
        toolPart: UIMessagePart.Tool,
        hiddenIndices: Set<Int>
    ) -> [UIMessage] {
        var newParts: [UIMessagePart] = []
        for part in toolPart.output {
            if let text = part as? UIMessagePart.Text {
                // 只动隐藏块：整块区间替换为省略标记；保留块与块间空白逐字保留
                // 原文，tool call ID 与对应关系不变。
                let original = text.text
                var projected = ""
                var cursor = original.startIndex
                for block in splitBlocks(original) {
                    projected += original[cursor..<block.range.lowerBound]
                    if hiddenIndices.contains(block.index) {
                        projected += omissionMarker(toolCallId: toolPart.toolCallId, toolName: toolPart.toolName, blockIndex: block.index)
                    } else {
                        projected += original[block.range]
                    }
                    cursor = block.range.upperBound
                }
                projected += original[cursor..<original.endIndex]
                newParts.append(UIMessagePart.Text(text: projected, metadata: text.metadata))
            } else {
                newParts.append(part)
            }
        }
        let projectedTool = UIMessagePart.Tool(
            toolCallId: toolPart.toolCallId,
            toolName: toolPart.toolName,
            input: toolPart.input,
            output: newParts,
            approvalState: toolPart.approvalState,
            streamIndex: toolPart.streamIndex,
            metadata: toolPart.metadata
        )
        var updated = messages
        let message = messages[messageIndex]
        var parts = message.parts
        let matchingIndex = partIndex.flatMap { index in
            parts.indices.contains(index) ? index : nil
        } ?? parts.firstIndex(where: { ($0 as? UIMessagePart.Tool)?.toolCallId == toolPart.toolCallId })
        if let idx = matchingIndex {
            parts[idx] = projectedTool
        }
        updated[messageIndex] = UIMessage(
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
        return updated
    }

    // MARK: Request building

    private static let relevanceLevels = [
        "0 = 与当前任务无关",
        "1 = 边缘相关，几乎不影响回答",
        "2 = 相关，包含可能需要的信息",
        "3 = 直接包含完成任务所需的信息",
    ]

    private static func questionTargets(
        outputs: [OutputCandidate],
        questionLimit: Int,
        maxStateBytes: Int,
        taskText: String
    ) -> [QuestionTarget] {
        let eligible = outputs.map { $0.blocks.filter { !$0.mustKeep } }
        let availableCount = eligible.reduce(0) { $0 + $1.count }
        let limit = min(max(0, questionLimit), availableCount)
        guard limit > 0 else { return [] }

        for candidateLimit in stride(from: limit, through: 1, by: -1) {
            let quotas = allocateQuestionQuotas(blockCounts: eligible.map(\.count), totalLimit: candidateLimit)
            var targets: [QuestionTarget] = []
            for (outputIndex, blocks) in eligible.enumerated() {
                let quota = min(quotas[outputIndex], blocks.count)
                guard quota > 0 else { continue }
                let token = outputQuestionToken(outputs[outputIndex])
                for blockIndex in distributedIndices(count: blocks.count, limit: quota) {
                    let block = blocks[blockIndex]
                    targets.append(QuestionTarget(
                        block: block,
                        questionId: outputs.count > 1 ? "\(token)_b\(block.index)" : "b\(block.index)"
                    ))
                }
            }
            guard !targets.isEmpty else { continue }
            let state = stateText(taskText: taskText, targets: targets)
            if state.utf8.count <= maxStateBytes { return targets }
        }
        return []
    }

    private static func allocateQuestionQuotas(blockCounts: [Int], totalLimit: Int) -> [Int] {
        var quotas = Array(repeating: 0, count: blockCounts.count)
        guard totalLimit > 0 else { return quotas }
        let activeOutputs = blockCounts.indices.filter { blockCounts[$0] > 0 }
        guard !activeOutputs.isEmpty else { return quotas }

        if activeOutputs.count > totalLimit {
            for selectedIndex in distributedIndices(count: activeOutputs.count, limit: totalLimit) {
                quotas[activeOutputs[selectedIndex]] = 1
            }
            return quotas
        }

        for index in activeOutputs { quotas[index] = 1 }
        var remaining = totalLimit - activeOutputs.count
        while remaining > 0 {
            var advanced = false
            for index in activeOutputs where quotas[index] < blockCounts[index] {
                quotas[index] += 1
                remaining -= 1
                advanced = true
                if remaining == 0 { break }
            }
            if !advanced { break }
        }
        return quotas
    }

    private static func distributedIndices(count: Int, limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        guard limit < count else { return Array(0..<count) }
        guard limit > 1 else { return [count - 1] }
        return (0..<limit).map { offset in
            Int((Double(offset) * Double(count - 1) / Double(limit - 1)).rounded())
        }
    }

    private static func outputQuestionToken(_ output: OutputCandidate) -> String {
        "o" + contentHash(output.toolPart.toolCallId) + "_" + output.outputHash
    }

    private static func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func stateText(taskText: String, blocks: [Block]) -> String {
        var lines = ["当前任务文本：\(String(taskText.prefix(2_000)))", "内容块（id = b<块序号>）："]
        for block in blocks {
            lines.append("- b\(block.index): \(inspectionExcerpt(block.text))")
        }
        return lines.joined(separator: "\n")
    }

    private static func stateText(taskText: String, targets: [QuestionTarget]) -> String {
        var lines = ["当前任务文本：\(String(taskText.prefix(2_000)))", "待评估的工具输出块："]
        for target in targets {
            lines.append("- \(target.questionId)：\(inspectionExcerpt(target.block.text))")
        }
        return lines.joined(separator: "\n")
    }

    private static func inspectionExcerpt(_ text: String) -> String {
        let compact = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard compact.count > inspectedExcerptCharacters else { return String(compact) }
        let headCount = inspectedExcerptCharacters / 2
        let tailCount = inspectedExcerptCharacters - headCount
        return String(compact.prefix(headCount)) + " … " + String(compact.suffix(tailCount))
    }
}
