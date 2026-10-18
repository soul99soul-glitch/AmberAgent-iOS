import Foundation
@preconcurrency import Shared

@MainActor
extension ChatToolRuntime {
    func pendingSessionReadToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        let sessionToolNames: Set<String> = ["session_search", "session_read"]
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    sessionToolNames.contains($0.toolName)
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    /// runtime_status 的待执行检测。只识别可见且 output 为空的调用
    /// （照 pendingSessionReadToolCall 模式）。
    func pendingRuntimeStatusToolCall(
        in messages: [UIMessage],
        availableToolNames: Set<String>
    ) -> UIMessagePart.Tool? {
        for message in messages.reversed() where message.role == MessageRole.assistant {
            if let toolCall = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .first(where: {
                    $0.toolName == "runtime_status"
                        && availableToolNames.contains($0.toolName)
                        && $0.output.isEmpty
                }) {
                return toolCall
            }
        }
        return nil
    }

    /// session_search / session_read 执行入口：本地只读，无审批、无网络。
    func executeSessionReadToolCall(_ pending: ChatPendingToolApproval) async -> ChatToolRuntimeResult {
        let resultText = await dispatchSessionReadToolCall(pending.toolCall)
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        ))
    }

    func dispatchSessionReadToolCall(_ toolCall: UIMessagePart.Tool) async -> String {
        if toolCall.toolName == "runtime_status" {
            return dispatchRuntimeStatusToolCall(toolCall, toolExposureBridge: nil)
        }
        return await sessionReadTool.dispatch(toolCall)
    }
}

@MainActor
final class ChatSessionReadTool {
    private let conversationStoreProvider: (() -> IOSConversationStore?)?

    init(conversationStoreProvider: (() -> IOSConversationStore?)?) {
        self.conversationStoreProvider = conversationStoreProvider
    }

    // MARK: - 跨会话读取（session_search / session_read）执行体

    // 契约常量与 KMP 声明默认值/上限同源（session_search limit [1,20] 默认 8；
    // session_read max_messages [1,50] 默认 20）。
    static let sessionSearchDefaultLimit = 8
    static let sessionSearchMaxLimit = 20
    static let sessionReadDefaultMaxMessages = 20
    static let sessionReadMaxMessages = 50
    /// 单条消息投影文本截断上限（字符）。
    static let sessionReadMessageTextLimit = 2_000
    /// 总输出截断上限（消息投影合计，JSON 编码前）。
    static let sessionReadTotalOutputLimit = 12_000
    /// 单条全文分页的默认字符数与请求上限。分页结果还会按实际 JSON
    /// 序列化长度再收窄，避免下面的工具输出收口改写 text 而跳过游标。
    static let sessionReadPageDefaultMaxChars = 2_000
    static let sessionReadPageMaxChars = 8_000

    /// 执行体：无 store 注入时结构化「不可用」；会话不存在给
    /// `{status:error, reason:"conversation not found"}`；非法 conversation_id
    /// 走 Foundation 预校验（M4 先例：K/N `Uuid.parse` 对非法串终止进程，
    /// 必须先用 `UUID(uuidString:)` 拦截）。
    func dispatch(_ toolCall: UIMessagePart.Tool) async -> String {
        guard let store = conversationStoreProvider?() else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "会话读取工具当前不可用。",
                status: "failed"
            )
        }
        switch toolCall.toolName {
        case "session_search":
            return await Self.executeSessionSearch(toolCall: toolCall, store: store)
        case "session_read":
            return await Self.executeSessionRead(toolCall: toolCall, store: store)
        default:
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "未知的会话工具。",
                status: "failed"
            )
        }
    }

    private static func executeSessionSearch(
        toolCall: UIMessagePart.Tool,
        store: IOSConversationStore
    ) async -> String {
        guard let args = ChatToolCallParsing.jsonObject(toolCall.input),
              let query = args["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "session_search 参数无效：需要非空 query。",
                status: "failed"
            )
        }
        let requestedLimit = (args["limit"] as? Int) ?? sessionSearchDefaultLimit
        let limit = min(max(requestedLimit, 1), sessionSearchMaxLimit)
        let hits = await store.sessionSearchHits(query: query, limit: limit)
        var payload: [String: Any] = [
            "ok": true,
            "tool": toolCall.toolName,
            "status": "ok",
            "query": query,
            "results": hits.map { hit -> [String: Any] in
                [
                    "conversation_id": hit.conversationId.toHexDashString(),
                    "title": hit.title,
                    "snippet": hit.snippet,
                    "updated_at": hit.updatedAt,
                    "message_count": hit.messageCount,
                ]
            },
        ]
        if hits.isEmpty {
            payload["hint"] = "没有找到匹配的会话，试试换一个关键词。"
        }
        return IOSWorkspaceStore.json(payload)
    }

    private static func executeSessionRead(
        toolCall: UIMessagePart.Tool,
        store: IOSConversationStore
    ) async -> String {
        guard let args = ChatToolCallParsing.jsonObject(toolCall.input),
              let rawId = args["conversation_id"] as? String else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "session_read 参数无效：需要 conversation_id。",
                status: "failed"
            )
        }
        // M4 先例：K/N 的 KotlinUuid.parse 对非法串在导出下终止进程（NSException）——
        // 先用 Foundation UUID(uuidString:) 正则级预校验拦截（并归一化小写）。
        let normalizedId = rawId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: normalizedId) != nil else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "conversation_id 不是合法的会话 id：\(rawId)。请用 session_search 获取 conversation_id。",
                status: "failed"
            )
        }
        let conversationId = KotlinUuid.companion.parse(uuidString: normalizedId)
        let requestedMax = (args["max_messages"] as? Int) ?? sessionReadDefaultMaxMessages
        let maxMessages = min(max(requestedMax, 1), sessionReadMaxMessages)

        // 当前会话优先走内存（P1-c loadConversationForOrchestration 同契约）。
        let conversation: Conversation?
        if store.currentConversation?.id == conversationId {
            conversation = store.currentConversation
        } else {
            conversation = try? await store.loadConversationForOrchestration(conversationId)
        }
        guard let conversation else {
            return IOSWorkspaceStore.json([
                "status": "error",
                "reason": "conversation not found",
            ])
        }
        let messages = Self.searchableMessages(of: conversation)

        // `message_id` selects a single persisted message for lossless paging.
        // It is deliberately matched as the stored string; unlike the
        // conversation id above, it must not pass through KotlinUuid.parse.
        if let rawMessageId = args["message_id"] {
            guard let requestedMessageId = (rawMessageId as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !requestedMessageId.isEmpty else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "session_read 参数无效：message_id 必须是非空字符串。",
                    status: "failed"
                )
            }

            let normalizedMessageId = requestedMessageId.lowercased()
            guard let message = messages.first(where: {
                Self.sessionMessageId($0).lowercased() == normalizedMessageId
            }) else {
                return IOSWorkspaceStore.json([
                    "ok": false,
                    "tool": toolCall.toolName,
                    "status": "error",
                    "error": "message_not_found",
                    "reason": "message not found",
                    "message_id": requestedMessageId,
                ])
            }

            let fullText = Self.projectMessageText(message)
            let totalChars = fullText.count
            let offset: Int
            if let rawOffset = args["offset"] {
                guard let value = rawOffset as? Int else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName,
                        reason: "session_read 参数无效：offset 必须是非负整数。",
                        status: "failed"
                    )
                }
                offset = value
            } else {
                offset = 0
            }
            guard offset >= 0, offset <= totalChars else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "session_read 参数无效：offset 必须在 0 到 \(totalChars) 之间。",
                    status: "failed"
                )
            }

            let maxChars: Int
            if let rawMaxChars = args["max_chars"] {
                guard let value = rawMaxChars as? Int, value > 0 else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName,
                        reason: "session_read 参数无效：max_chars 必须是正整数。",
                        status: "failed"
                    )
                }
                maxChars = min(value, sessionReadPageMaxChars)
            } else {
                maxChars = sessionReadPageDefaultMaxChars
            }

            return Self.projectSessionMessagePage(
                message: message,
                conversationId: conversation.id.toHexDashString(),
                fullText: fullText,
                offset: offset,
                maxChars: maxChars
            )
        }

        guard args["offset"] == nil, args["max_chars"] == nil else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "session_read 分页需要 message_id；请使用结果中的消息引用和 next_offset。",
                status: "failed"
            )
        }
        let rows = Self.projectLatestMessages(messages, maxMessages: maxMessages)
        return Self.boundedSessionReadJSON(
            conversationId: conversation.id.toHexDashString(),
            title: conversation.title,
            messageCount: messages.count,
            rows: rows
        )
    }

    /// 与 IOSConversationStore.searchableMessages 同源：分支节点优先，兜底 currentMessages。
    private static func searchableMessages(of conversation: Conversation) -> [UIMessage] {
        let nodeMessages = conversation.messageNodes.flatMap { node in
            node.messages
        }
        if !nodeMessages.isEmpty { return nodeMessages }
        return conversation.currentMessages
    }

    /// 最新 N 条消息的投影；总预算 [sessionReadTotalOutputLimit] 耗尽即停（截断
    /// 发生在 JSON 编码前，逐条前缀截断不截半条以上内容）。
    private static func projectLatestMessages(
        _ messages: [UIMessage],
        maxMessages: Int
    ) -> [[String: Any]] {
        let latest = messages.suffix(max(maxMessages, 1))
        var remainingBudget = sessionReadTotalOutputLimit
        var rows: [[String: Any]] = []
        for message in latest {
            let fullText = projectMessageText(message)
            let projected = String(fullText.prefix(min(sessionReadMessageTextLimit, remainingBudget)))
            guard !projected.isEmpty else { break }
            let truncated = projected.count < fullText.count
            rows.append([
                "message_id": sessionMessageId(message),
                "role": roleName(message.role),
                "text": projected,
                "total_chars": fullText.count,
                "truncated": truncated,
                "next_offset": truncated ? projected.count as Any : NSNull(),
            ])
            remainingBudget -= projected.count
        }
        return rows
    }

    /// 单条消息完整投影：Text parts 拼接、Tool parts 摘要为 `[tool: 名称 状态]` 一行。
    /// 默认读取和分页必须共用这份全文，保证分页 offset 与默认结果一致。
    private static func projectMessageText(_ message: UIMessage) -> String {
        message.parts.map { part -> String in
            if let textPart = part as? UIMessagePart.Text {
                return textPart.text
            }
            if let tool = part as? UIMessagePart.Tool {
                return toolPartSummary(tool)
            }
            return ""
        }.joined(separator: "\n")
    }

    private static func sessionMessageId(_ message: UIMessage) -> String {
        message.id.toHexDashString()
    }

    /// 分页结果的 JSON 也受统一工具输出 12k 收口约束。按实际序列化长度
    /// 二分可返回字符数，next_offset 始终对应真正返回的 text 尾部。
    private static func projectSessionMessagePage(
        message: UIMessage,
        conversationId: String,
        fullText: String,
        offset: Int,
        maxChars: Int
    ) -> String {
        let totalChars = fullText.count
        let requestedLength = min(maxChars, totalChars - offset)
        let messageId = sessionMessageId(message)
        let remainingText = fullText.dropFirst(offset)

        func serializedPage(length: Int) -> String {
            let text = String(remainingText.prefix(length))
            let reachedEnd = offset + length >= totalChars
            return IOSWorkspaceStore.json([
                "ok": true,
                "tool": "session_read",
                "status": "ok",
                "conversation_id": conversationId,
                "message_id": messageId,
                "role": roleName(message.role),
                "text": text,
                "offset": offset,
                "next_offset": reachedEnd ? NSNull() : (offset + length) as Any,
                "total_chars": totalChars,
                "truncated": !reachedEnd,
            ])
        }

        let hardLimit = IOSToolOutputLimits.maxOutputChars
        let requestedOutput = serializedPage(length: requestedLength)
        if requestedOutput.count <= hardLimit { return requestedOutput }
        // A page's fixed UUID/offset metadata plus one character fits the
        // budget. Search only when JSON escaping makes the requested page larger.
        var lower = 1
        var upper = requestedLength - 1
        var bestOutput = serializedPage(length: 1)
        while lower <= upper {
            let candidate = (lower + upper) / 2
            let output = serializedPage(length: candidate)
            if output.count <= hardLimit {
                bestOutput = output
                lower = candidate + 1
            } else {
                upper = candidate - 1
            }
        }

        return bestOutput
    }

    /// Default recent-message mode keeps its existing text and total budgets,
    /// then shrinks only text fields if metadata would push serialized JSON over
    /// the same 12k output cap. Metadata remains truthful after each shrink.
    private static func boundedSessionReadJSON(
        conversationId: String,
        title: String,
        messageCount: Int,
        rows: [[String: Any]]
    ) -> String {
        var workingRows = rows

        func serialized() -> String {
            IOSWorkspaceStore.json([
                "ok": true,
                "tool": "session_read",
                "status": "ok",
                "conversation_id": conversationId,
                "title": title,
                "message_count": messageCount,
                "messages": workingRows,
            ])
        }

        var output = serialized()
        while output.count > IOSToolOutputLimits.maxOutputChars {
            guard let index = workingRows.indices.max(by: {
                ((workingRows[$0]["text"] as? String)?.count ?? 0)
                    < ((workingRows[$1]["text"] as? String)?.count ?? 0)
            }),
            let text = workingRows[index]["text"] as? String,
            !text.isEmpty else {
                break
            }

            let keepCount = text.count == 1 ? 0 : text.count / 2
            workingRows[index]["text"] = String(text.prefix(keepCount))
            let totalChars = workingRows[index]["total_chars"] as? Int ?? text.count
            let truncated = keepCount < totalChars
            workingRows[index]["truncated"] = truncated
            workingRows[index]["next_offset"] = truncated ? keepCount as Any : NSNull()
            output = serialized()
        }
        return output
    }

    private static func toolPartSummary(_ tool: UIMessagePart.Tool) -> String {
        let status: String
        if tool.isExecuted {
            status = "completed"
        } else if tool.isPending {
            status = "pending"
        } else {
            status = "waiting"
        }
        return "[tool: \(tool.toolName) \(status)]"
    }

    private static func roleName(_ role: MessageRole) -> String {
        if role == MessageRole.user { return "user" }
        if role == MessageRole.assistant { return "assistant" }
        if role == MessageRole.system { return "system" }
        if role == MessageRole.tool { return "tool" }
        return String(describing: role).lowercased()
    }

    // MARK: - 运行时自省（runtime_status）执行体

    /// runtime_status 执行入口：本地只读自省，无审批、无网络、无副作用。
    /// 回答"我有什么能力/现在什么状态"——Jev 模式、凭据存在性（绝不回传
    /// Key 本体）、门控与目录计数；不触发任何 Jev 判断，不改设置/缓存/指标。
}
