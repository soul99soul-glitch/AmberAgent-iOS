import Foundation
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
// - 同一输出与任务版本只判断一次（内容哈希缓存 + marker 幂等）。
// - 失败/超时/不确定 → 保留全文。压缩摘要来源始终是 canonical 原文。
// - 恢复路径：iOS 无 conversation_expand 执行器（已核实）；恢复 = 原工具重读
//   或 session_read。无安全重读路径的类型不启用隐藏（v1 只处理可重读的只读
//   检索类输出，写入类工具输出一律不筛）。

@MainActor
final class IOSJevContextSelectionService {

    struct RunIdentity: Sendable {
        var runId: String?
    }

    struct Block: Equatable {
        var index: Int
        var text: String
        var mustKeep: Bool
        var keepReason: String?
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

    /// 分页/续取 token 的保守信号（出现则该块必须保留；含 JSON 形态）。
    private static let continuationTokenMarkers: [String] = [
        "next_offset", "next_page", "nextpage", "page_token", "pagetoken",
        "continuation", "cursor", "has_more", "next_token",
    ]

    struct Dependencies {
        let coordinator: IOSJevDecisionCoordinator
        let settingsProvider: () -> IOSJevSettings
    }

    private let deps: Dependencies
    /// shadow 已观测记录：(turnBudgetKey, 投影输入哈希)。turnBudgetKey 即 runId。
    private var shadowObservedByTurn: [String: String] = [:]

    init(deps: Dependencies) {
        self.deps = deps
    }

    static let shared = IOSJevContextSelectionService(deps: .init(
        coordinator: .shared,
        settingsProvider: { IOSSharedSettingsStore.loadPersistedJevSettings() }
    ))

    // MARK: Public entry（Host 每轮调用一次）

    /// 返回筛选投影后的请求副本。off / shadow / 失败 / 无候选 → 原样返回。
    func projectedMessages(
        _ messages: [UIMessage],
        identity: RunIdentity
    ) async -> [UIMessage] {
        let settings = deps.settingsProvider()
        let mode = settings.effectiveMode(for: .contextSelection)
        guard mode != .off else { return messages }

        let taskText = messages.reversed().first { $0.role == MessageRole.user }?.toText() ?? ""
        // 用户明确要求全文：本轮全部跳过（shadow 也不外发——没有判断必要）。
        let userDemandsFullText = Self.fullTextDemandMarkers.contains { taskText.localizedCaseInsensitiveContains($0) }
        if userDemandsFullText { return messages }

        guard let (targetMessageIndex, toolPart, blocks) = candidateBlocks(
            in: messages,
            taskText: taskText
        ) else { return messages }

        let requiredScopes: Set<IOSJevDataScope> = [.selectedTaskText, .toolOutput]
        guard settings.canSend(useCase: .contextSelection, required: requiredScopes) else { return messages }

        // 与工具发现同一契约锁：每块一题、总题数 ≤ maxQuestions（客户端对超题数
        // 是硬拒绝）。超出上限的块不参评——缺题 = 不确定 = 保留，方向保守。
        let evalCap = min(settings.policy.maxCandidates, settings.policy.maxQuestions)
        let candidates = Array(blocks.filter { !$0.mustKeep }.prefix(evalCap))
        guard !candidates.isEmpty else { return messages }

        let state = Self.stateText(taskText: taskText, blocks: candidates)
        let questions = candidates.map { block in
            IOSJevQuestion.score(
                id: "b\(block.index)",
                levels: Self.relevanceLevels,
                instructions: "评估该内容块对当前任务的相关性。只判断块内文本是否可能包含完成任务所需的信息。"
            )
        }
        let context = IOSJevRunContext(
            runId: identity.runId,
            turnBudgetKey: identity.runId ?? "run",
            inputHash: IOSJevToolDiscoveryService.stableHash(state)
        )

        // shadow：只观测，不改请求。同一轮内同内容不重复发起。
        if mode == .shadow {
            let turnKey = identity.runId ?? "run"
            if let observed = shadowObservedByTurn[turnKey], observed == context.inputHash {
                return messages
            }
            shadowObservedByTurn[turnKey] = context.inputHash
            if shadowObservedByTurn.count > 16 {
                shadowObservedByTurn.removeAll(keepingCapacity: true)
            }
            let coordinator = deps.coordinator
            Task(priority: .utility) {
                _ = await coordinator.decide(
                    useCase: .contextSelection,
                    requiredScopes: requiredScopes,
                    state: state,
                    questions: questions,
                    context: context,
                    cacheKey: "context_shadow"
                )
            }
            return messages
        }

        // active：应用判断。
        let outcome = await deps.coordinator.decide(
            useCase: .contextSelection,
            requiredScopes: requiredScopes,
            state: state,
            questions: questions,
            context: context,
            cacheKey: "context_active"
        )
        guard case .applied(let decision) = outcome else { return messages }

        let hidden = Self.hiddenBlockIndices(
            candidates: candidates,
            decision: decision,
            minScore: settings.policy.contextSelectionMinScore,
            minConfidence: settings.policy.contextSelectionMinConfidence
        )
        guard !hidden.isEmpty else { return messages }

        return Self.projecting(
            messages: messages,
            messageIndex: targetMessageIndex,
            toolPart: toolPart,
            hiddenIndices: Set(hidden)
        )
    }

    // MARK: Candidate discovery

    /// 找出最新一个可筛的超长已完成工具输出并切块。
    func candidateBlocks(
        in messages: [UIMessage],
        taskText: String,
        minOutputChars: Int = 8_000
    ) -> (messageIndex: Int, toolPart: UIMessagePart.Tool, blocks: [Block])? {
        for messageIndex in messages.indices.reversed() {
            let message = messages[messageIndex]
            guard message.role == MessageRole.tool else { continue }
            for partIndex in message.parts.indices {
                guard let tool = message.parts[partIndex] as? UIMessagePart.Tool else { continue }
                guard tool.isExecuted, !tool.output.isEmpty else { continue } // 已完成
                guard Self.isRereadableTool(tool.toolName) else { continue }
                // 多 Text part（如追加的 loop-guard 提醒）索引无法与投影侧对齐，
                // v1 保守跳过。
                let textParts = tool.output.compactMap { $0 as? UIMessagePart.Text }
                guard textParts.count == 1, let onlyText = textParts.first else { continue }
                let text = onlyText.text
                guard text.count > minOutputChars else { continue }
                // 已投影过（含 marker）→ 幂等跳过。
                guard !Self.containsOmissionMarker(text) else { continue }
                let blocks = Self.splitBlocks(text)
                guard blocks.count > 1 else { continue } // 无法安全分割 → 原样保留
                let evaluated = blocks.map { index, text, _ in
                    let (mustKeep, reason) = Self.mustKeepSignal(toolName: tool.toolName, text: text)
                    return Block(index: index, text: text, mustKeep: mustKeep, keepReason: reason)
                }
                return (messageIndex, tool, evaluated)
            }
        }
        return nil
    }

    static func isRereadableTool(_ name: String) -> Bool {
        rereadableToolPrefixes.contains(name)
    }

    // MARK: Splitting（结构块不拆坏）

    /// 按空行切段落；围栏代码块（```...```）整块保留；超长段落不二次切割。
    /// text 为去首尾空白后的内容（评分/信号用），range 是该块在原文中的区间
    /// （含块内行间空白）——投影按 range 替换隐藏块，保留块逐字保留原文。
    static func splitBlocks(_ text: String) -> [(index: Int, text: String, range: Range<String.Index>)] {
        var blocks: [(text: String, range: Range<String.Index>)] = []
        var blockStart: String.Index?
        var blockEnd: String.Index?
        var inFence = false

        func flush() {
            defer {
                blockStart = nil
                blockEnd = nil
            }
            guard let start = blockStart, let end = blockEnd, end > start else { return }
            let raw = String(text[start..<end])
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            blocks.append((trimmed, start..<end))
        }

        var lineStart = text.startIndex
        while true {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let trimmed = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    if blockStart == nil { blockStart = lineStart }
                    blockEnd = lineEnd
                    flush()
                    inFence = false
                } else {
                    flush()
                    blockStart = lineStart
                    blockEnd = lineEnd
                    inFence = true
                }
            } else if !inFence && trimmed.isEmpty {
                flush()
            } else {
                if blockStart == nil { blockStart = lineStart }
                blockEnd = lineEnd
            }
            if lineEnd == text.endIndex { break }
            lineStart = text.index(after: lineEnd)
        }
        flush()
        return blocks.enumerated().map { (index: $0.offset, text: $0.element.text, range: $0.element.range) }
    }

    // MARK: Must-keep signals

    static func mustKeepSignal(toolName: String, text: String) -> (Bool, String?) {
        let lower = text.lowercased()
        // 错误/失败输出（覆盖常见 JSON 与文本形态，含 MCP isError 约定）。
        if lower.contains("\"ok\": false") || lower.contains("\"ok\":false")
            || lower.contains("\"status\": \"error\"") || lower.contains("\"status\":\"error\"")
            || lower.contains("\"iserror\": true") || lower.contains("\"iserror\":true")
            || lower.contains("\"success\": false") || lower.contains("\"success\":false")
            || lower.contains("error:") || lower.contains("traceback") || lower.contains("失败：") {
            return (true, "error_output")
        }
        // 未解决待办。
        if lower.contains("todo") || lower.contains("待办") || lower.contains("未完成") {
            return (true, "unresolved_todo")
        }
        // 未知执行状态（WebMount 等）。
        if lower.contains("unknown_after_action") || lower.contains("may_have_applied") {
            return (true, "unknown_execution_state")
        }
        // 审批/权限卡语义。
        if lower.contains("needs_approval") || lower.contains("需要确认") || lower.contains("需要审批") {
            return (true, "approval")
        }
        // 分页/续取 token。
        if continuationTokenMarkers.contains(where: { lower.contains($0) }) {
            return (true, "continuation_token")
        }
        return (false, nil)
    }

    // MARK: Jev decision application

    /// 只有低分块被隐藏；缺题/无效/低置信/不确定一律保留（缺失不等于 0 分）。
    static func hiddenBlockIndices(
        candidates: [Block],
        decision: IOSJevDecision,
        minScore: Double,
        minConfidence: Double? = nil
    ) -> [Int] {
        var scores: [Int: Double] = [:]
        var confidences: [Int: Double] = [:]
        for answer in decision.answers where answer.type == "score" {
            guard answer.id.hasPrefix("b"), let index = Int(answer.id.dropFirst()),
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
        if let idx = parts.firstIndex(where: { ($0 as? UIMessagePart.Tool)?.toolCallId == toolPart.toolCallId }) {
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

    static func stateText(taskText: String, blocks: [Block]) -> String {
        var lines: [String] = []
        lines.append("当前任务文本：\(String(taskText.prefix(2_000)))")
        lines.append("内容块（id = b<块序号>）：")
        for block in blocks {
            let excerpt = String(block.text.prefix(300)).replacingOccurrences(of: "\n", with: " ")
            lines.append("- b\(block.index): \(excerpt)")
        }
        return lines.joined(separator: "\n")
    }
}
