import Foundation
@preconcurrency import Shared

@MainActor
extension ChatToolRuntime {

    /// P3-b: names that are NEVER injectable as nested `tools` functions —
    /// `exec` itself (self-call guard), the thread-orchestration tools
    /// (aligned with codex "collaboration tools cannot be called from exec"),
    /// the discovery tool, and `ask_user` (its HITL card cannot be re-entered
    /// from inside an evaluation). Single source for the engine's function
    /// injection AND the coordinator's nested-runner classification.
    static let execNestedToolExclusions: Set<String> = Set([
        "exec", "spawn_agent", "list_agents", "interrupt_agent",
        "send_message", "followup_task", "wait_agent", "tool_search", "ask_user",
        // Nested exec only sees a synthetic assistant message — pad-image enrich
        // cannot resolve user attachments, and image gen is a paid side effect.
        "generate_image",
        "theme_pack_import",
    ]).union(IOSRemoteTerminalToolCatalog.jobToolNames)
        .union(IOSPhoneControlToolCatalog.toolNames)

    /// P3-b: whitelist for one evaluation's `tools` object = the current
    /// round's visible tool set minus the exec exclusions. Same source for
    /// the engine's function injection and the coordinator's nested-runner
    /// classification, so the two can never disagree.
    static func execNestedToolWhitelist(visibleToolNames: Set<String>) -> Set<String> {
        visibleToolNames.subtracting(execNestedToolExclusions)
    }

    /// P3-d: ALL_TOOLS discovery descriptions for the whitelisted names, taken
    /// from the same round's `[Tool]` declarations (the same objects that made
    /// the whitelist visible). Names outside the whitelist are ignored; a
    /// declared-but-descriptionless tool falls back to an empty string and the
    /// engine still installs its name-only ALL_TOOLS entry.
    static func execToolDescriptions(from tools: [Tool], whitelist: Set<String>) -> [String: String] {
        var descriptions: [String: String] = [:]
        for tool in tools where whitelist.contains(tool.name) {
            descriptions[tool.name] = tool.description_
        }
        return descriptions
    }

    /// `ALL_TOOLS[i].parameters`: each whitelisted declaration's input schema
    /// as JSON Schema text (KMP serializes it with the providers' serializer).
    /// Tools without a schema are omitted (the engine reports `null`).
    static func execToolSchemas(from tools: [Tool], whitelist: Set<String>) -> [String: String] {
        var schemas: [String: String] = [:]
        for tool in tools where whitelist.contains(tool.name) {
            if let json = tool.parametersJsonSchema() {
                schemas[tool.name] = json
            }
        }
        return schemas
    }

    /// store/load branch scope for one exec call: its own toolCallId, its run,
    /// and every tool call id on the branch the run works on. An empty branch
    /// snapshot means "unknown" (every version visible), never "nothing".
    static func execStoreScope(
        toolCall: UIMessagePart.Tool,
        runId: String,
        branchMessages: [UIMessage]
    ) -> IOSJsStoreScope {
        let visible: Set<String>? = branchMessages.isEmpty ? nil : Set(
            branchMessages.flatMap { message in
                message.parts.compactMap { ($0 as? UIMessagePart.Tool)?.toolCallId }
            }
        )
        return IOSJsStoreScope(
            sourceToolCallId: toolCall.toolCallId,
            runId: runId,
            visibleToolCallIds: visible
        )
    }

    /// P3-b: builds the sandbox bridge from the run's exposure bridge and the
    /// coordinator-provided nested runner. Nil when there is no runner or no
    /// bridge (the evaluation then runs without a `tools` object, exactly like
    /// P3-a).
    static func execNestedToolsBridge(
        toolExposureBridge: IosToolExposureBridge?,
        nestedToolRunner: IosExecNestedToolRunner?
    ) -> IOSJsSandboxTools? {
        guard let toolExposureBridge, let nestedToolRunner else { return nil }
        let visible = toolExposureBridge.visibleTools()
        let whitelist = execNestedToolWhitelist(
            visibleToolNames: Set(visible.map(\.name))
        )
        guard !whitelist.isEmpty else { return nil }
        return IOSJsSandboxTools(
            availableToolNames: whitelist.sorted(),
            hostCall: { name, arguments in
                await nestedToolRunner(name, arguments)
            },
            // P3-d: ALL_TOOLS 与白名单同一来源（同轮可见工具集），描述直接来自
            // 可见声明的 KMP description。
            toolDescriptions: execToolDescriptions(from: visible, whitelist: whitelist),
            toolSchemas: execToolSchemas(from: visible, whitelist: whitelist)
        )
    }

    static func clampWaitTimeoutMs(_ value: Int) -> Int {
        ChatJavaScriptTool.clampWaitTimeoutMs(value)
    }

    static func clampMaxOutputChars(_ value: Int) -> Int {
        ChatJavaScriptTool.clampMaxOutputChars(value)
    }

    func dispatchExecToolCall(
        _ toolCall: UIMessagePart.Tool,
        nestedTools: IOSJsSandboxTools? = nil,
        conversationId: KotlinUuid? = nil,
        storeScope: IOSJsStoreScope? = nil
    ) async -> String {
        await javaScriptTool.execute(
            toolCall, nestedTools: nestedTools,
            conversationId: conversationId, storeScope: storeScope
        )
    }

    func dispatchWaitToolCall(
        _ toolCall: UIMessagePart.Tool,
        conversationId: KotlinUuid?
    ) async -> String {
        await javaScriptTool.wait(toolCall, conversationId: conversationId)
    }
}

@MainActor
final class ChatJavaScriptTool {
    private let jsCellRegistry: IOSJsCellRegistry
    private let jsSandboxEngine: IOSJsSandboxEngine
    private let sharedSettings: IOSSharedSettingsStore

    init(
        jsCellRegistry: IOSJsCellRegistry,
        jsSandboxEngine: IOSJsSandboxEngine,
        sharedSettings: IOSSharedSettingsStore
    ) {
        self.jsCellRegistry = jsCellRegistry
        self.jsSandboxEngine = jsSandboxEngine
        self.sharedSettings = sharedSettings
    }

    static func clampWaitTimeoutMs(_ value: Int) -> Int {
        min(max(value, 1000), 60000)
    }

    /// P3-d: max_output_chars hard cap (declaration contract: [1, 100000],
    /// default 10000). The returned payload lands in the tool output and the
    /// ledger, so a model-supplied unbounded limit must not bypass truncation.
    static let maxOutputCharsHardCap = 100000

    static func clampMaxOutputChars(_ value: Int) -> Int {
        min(max(value, 1), maxOutputCharsHardCap)
    }

    /// P3-c: one `exec` call with the cell lifecycle.
    ///
    /// Every evaluation registers a Running cell first (per-session
    /// concurrency cap of 4, enforced before any JS runs). On timeout the
    /// handle is NOT dropped: exec returns the codex wording
    /// "Script running with cell ID {cell_id}" and the evaluation keeps
    /// running on its own queue (abandon semantics); the completion listener
    /// delivers the eventual result to the registry so a later `wait` can
    /// retrieve it. Inline terminal (success/failure within the timeout) cells
    /// are consumed here — the model never saw a cell_id, so nothing can wait
    /// on them (read-once, zero residue).
    func execute(
        _ toolCall: UIMessagePart.Tool,
        nestedTools: IOSJsSandboxTools? = nil,
        conversationId: KotlinUuid? = nil,
        storeScope: IOSJsStoreScope? = nil
    ) async -> String {
        guard let args = ChatToolCallParsing.jsonObject(toolCall.input),
              let code = args["code"] as? String, !code.isEmpty else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "exec 参数无效：需要非空 code（JavaScript 源码）。"
            )
        }
        let timeoutMs = IOSJsSandboxEngine.clampTimeoutMs(
            (args["timeout_ms"] as? Int) ?? IOSJsSandboxEngine.defaultTimeoutMs
        )
        let maxOutputChars = Self.clampMaxOutputChars(
            (args["max_output_chars"] as? Int)
                ?? IOSJsSandboxEngine.defaultMaxOutputChars
        )
        let sessionKey = conversationId?.description() ?? "global"
        let cellId = UUID().uuidString

        let started = await jsCellRegistry.startCell(sessionKey: sessionKey, cellId: cellId)
        guard started == .started else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "exec 并发 cell 已达上限（每会话 \(IOSJsCellRegistry.maxRunningCellsPerSession) 个）。请先 wait 或 terminate 已有 cell。",
                status: "failed"
            )
        }

        // P3-c: session-scoped store/load bridge — shared by every cell of the
        // conversation, persisted by the registry (single writer).
        // 分支可见性：写入标记来源 exec 调用；读取只取当前分支可见的最新值。
        let storeBridge = IOSJsSandboxStore(
            load: { [registry = jsCellRegistry] key in
                await registry.loadValue(sessionKey: sessionKey, key: key, scope: storeScope)
            },
            store: { [registry = jsCellRegistry] key, value in
                switch await registry.storeValue(sessionKey: sessionKey, key: key, valueJSON: value, scope: storeScope) {
                case .stored:
                    return nil
                case .overLimit(let reason):
                    return reason
                }
            }
        )
        let result = await jsSandboxEngine.evaluate(
            code: code,
            timeoutMs: timeoutMs,
            maxOutputChars: maxOutputChars,
            tools: nestedTools,
            store: storeBridge,
            // 「脚本判断」用途生效为 active 时注入 jev（off/shadow 不注入）。
            jev: IOSExecJevBridge.makeBridge(
                runKey: storeScope?.runId ?? sessionKey,
                settings: sharedSettings.jevSettings
            ),
            completion: { [registry = jsCellRegistry] final in
                Task { @Sendable in
                    await registry.finishCell(
                        sessionKey: sessionKey,
                        cellId: cellId,
                        result: final,
                        maxOutputChars: maxOutputChars
                    )
                }
            }
        )
        switch result {
        case .success, .failure:
            // Inline terminal: exec's own payload carries the result/error;
            // consume the cell (nothing can reference it without a cell_id).
            await jsCellRegistry.removeCell(sessionKey: sessionKey, cellId: cellId)
            return IOSJsSandboxEngine.toolPayload(result, maxOutputChars: maxOutputChars)
        case .timedOut:
            // P3-c yield: the cell keeps running; the model continues it with
            // wait(cell_id). The evaluation's completion listener will deliver
            // the eventual result to the registry.
            return IOSWorkspaceStore.json([
                "status": "running",
                "cell_id": cellId,
                "output": "Script running with cell ID \(cellId)",
            ])
        }
    }

    /// P3-c: one `wait` call — the three paths:
    /// - cell missing → structured error (never silent).
    /// - `terminate: true` → mark Terminated (abandon semantics: JavaScriptCore
    ///   cannot force-kill the runaway script; it keeps burning CPU until it
    ///   ends by itself, and its result is discarded) and return the terminal.
    /// - otherwise block until the cell completes or the wait timeout elapses
    ///   (clamped [1000, 60000], default 10000); a still-running cell returns
    ///   its current running status so the model can wait again.
    /// Every wait is an ordinary tool call — it consumes one tool-resume
    /// budget slot via the existing maxToolResumeCount/maxSteps machinery, no
    /// separate budget mechanism.
    func wait(
        _ toolCall: UIMessagePart.Tool,
        conversationId: KotlinUuid?
    ) async -> String {
        guard let args = ChatToolCallParsing.jsonObject(toolCall.input),
              let cellId = args["cell_id"] as? String, !cellId.isEmpty else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "wait 参数无效：需要 cell_id（exec 超时 yield 返回的 cell ID）。"
            )
        }
        let timeoutMs = Self.clampWaitTimeoutMs(
            (args["timeout_ms"] as? Int) ?? IOSJsSandboxEngine.defaultTimeoutMs
        )
        let terminate = (args["terminate"] as? Bool) ?? false
        let sessionKey = conversationId?.description() ?? "global"
        let outcome = await jsCellRegistry.wait(
            cellId: cellId,
            sessionKey: sessionKey,
            timeoutMs: timeoutMs,
            terminate: terminate
        )
        switch outcome {
        case .notFound:
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "cell \(cellId) 不存在或已读取。exec 超时会返回 cell ID；同一 cell 的输出只可读取一次。",
                status: "failed"
            )
        case .stillRunning:
            return IOSWorkspaceStore.json([
                "status": "running",
                "cell_id": cellId,
                "output": "Script running with cell ID \(cellId)",
            ])
        case .cancelled:
            // M6: run 取消期间 wait 立即收口（不等超时）——结构化终态，不冒充
            // running/超时；cell 保持 Running 可再 wait。
            return IOSWorkspaceStore.json([
                "status": "cancelled",
                "cell_id": cellId,
            ])
        case .terminal(let record):
            var object: [String: Any] = [
                "status": record.status.rawValue,
                "output": record.output ?? NSNull(),
                "logs": record.logs,
            ]
            if let error = record.error {
                object["error"] = error
            }
            return IOSWorkspaceStore.json(object)
        }
    }

}
