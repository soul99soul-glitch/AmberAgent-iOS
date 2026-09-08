import Foundation
import Observation
@preconcurrency import Shared

private func subAgentJSON(_ object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return String(describing: object)
    }
    return text
}

struct IOSSubAgentRoleDescriptor: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let systemPrompt: String
    let routing: String
    let toolAllowlist: [String]
    let maxTurns: Int
    let timeoutSeconds: Int
    let outputBudgetChars: Int
    /// Browser actions are opt-in per role. The parent WebMount permission
    /// gate remains the final authority at execution time.
    let allowsBrowserAutomation: Bool
}

enum IOSSubAgentRoleCatalog {
    static let builtIns: [IOSSubAgentRoleDescriptor] = [
        .init(
            id: "explorer",
            name: "Explorer",
            summary: "跨多源快速并行侦察，速度优先。",
            systemPrompt: "快速侦察范围、列出证据和未知数，优先用只读来源。",
            routing: "范围广、不确定、需要先摸清有哪些信息时调用。",
            toolAllowlist: [
                "tools_list", "search_web", "scrape_web", "file_read_selected", "permissions_status",
                "workspace_file_read", "workspace_file_list", "workspace_file_search", "workspace_artifact_read",
                "wm_stations", "wm_state", "wm_extract", "wm_get", "wm_find", "wm_wait", "wm_back", "wm_forward"
            ],
            maxTurns: 4,
            timeoutSeconds: 300,
            outputBudgetChars: 12_000,
            allowsBrowserAutomation: false
        ),
        .init(
            id: "historian",
            name: "Historian",
            summary: "历史会话搜索、主题挖掘、跨分片综合。",
            systemPrompt: "聚合历史上下文，明确哪些结论来自过往记录。",
            routing: "需要回忆过去对话、决策或跨会话主题时调用。",
            toolAllowlist: ["tools_list", "permissions_status"],
            maxTurns: 4,
            timeoutSeconds: 300,
            outputBudgetChars: 12_000,
            allowsBrowserAutomation: false
        ),
        .init(
            id: "oracle",
            name: "Oracle",
            summary: "架构取舍、风险复议、提交前评审。",
            systemPrompt: "进行高判断力复议，重点给出风险、反例和取舍。",
            routing: "长期影响大的决定、高风险重构、提交前二次复议时调用。",
            toolAllowlist: ["tools_list", "file_read_selected", "permissions_status", "workspace_file_read", "workspace_file_search", "workspace_artifact_read"],
            maxTurns: 4,
            timeoutSeconds: 300,
            outputBudgetChars: 12_000,
            allowsBrowserAutomation: false
        ),
        .init(
            id: "designer",
            name: "Designer",
            summary: "视觉产出规格、版式、配色和信息密度审查。",
            systemPrompt: "从视觉质量、信息层级和移动端可用性评审输出。",
            routing: "生成或评审视觉产物，并且在意版式和信息密度时调用。",
            toolAllowlist: ["tools_list", "file_read_selected", "workspace_file_read", "workspace_artifact_read"],
            maxTurns: 3,
            timeoutSeconds: 240,
            outputBudgetChars: 8_000,
            allowsBrowserAutomation: false
        ),
        .init(
            id: "writer",
            name: "Writer",
            summary: "中文写作、文案润色、故事与风格改写。",
            systemPrompt: "以中文表达质量为第一目标，保留事实边界。",
            routing: "中文写作、润色、邮件、文案或故事表达时调用。",
            toolAllowlist: ["tools_list", "file_read_selected", "workspace_file_read", "workspace_artifact_read"],
            maxTurns: 3,
            timeoutSeconds: 240,
            outputBudgetChars: 8_000,
            allowsBrowserAutomation: false
        ),
        .init(
            id: "fixer",
            name: "Fixer",
            summary: "边界清晰的机械执行：翻译、格式转换、抽取。",
            systemPrompt: "完成边界清晰的机械任务，不扩大范围。",
            routing: "翻译、格式化、抽取、命名等明确任务时调用。",
            toolAllowlist: ["tools_list"],
            maxTurns: 2,
            timeoutSeconds: 180,
            outputBudgetChars: 6_000,
            allowsBrowserAutomation: false
        ),
        .init(
            id: "browser",
            name: "Browser",
            summary: "使用 WebMount、Moli 或已连接的浏览器 MCP 浏览网页，读取页面并按语义目标完成可验证的交互。",
            systemPrompt: """
                你是浏览器自动化子代理。优先使用已连接的 Moli、WebMount 或浏览器 MCP 工具。

                先观察当前页面，再使用稳定的语义目标（target 或 ref）完成导航、点击、输入、滚动或选择。每个动作后重新观察并核对结果。

                只在当前任务明确要求时操作，不读取 cookie、token、原始 HTML 或隐私凭证。遇到权限、人工接管或页面状态不确定时，如实报告并停止。
                """.trimmingCharacters(in: .whitespacesAndNewlines),
            routing: "需要在 WebMount、Moli 或浏览器 MCP 中打开网页、观察页面或完成受约束的浏览器操作时调用。",
            toolAllowlist: [
                "tools_list", "search_web", "scrape_web",
                "wm_stations", "wm_tab_list", "wm_open", "wm_state", "wm_observe",
                "wm_extract", "wm_get", "wm_visual_snapshot", "wm_back", "wm_forward",
                "wm_click", "wm_tap", "wm_type", "wm_keys", "wm_scroll", "wm_select",
                "wm_find", "wm_wait"
            ],
            maxTurns: 8,
            timeoutSeconds: 600,
            outputBudgetChars: 12_000,
            allowsBrowserAutomation: true
        )
    ]

    /// Resolves a built-in role id. Returns nil for unknown ids instead of
    /// silently falling back to explorer, so callers can surface a structured
    /// error (G3).
    static func resolve(roleId: String?) -> IOSSubAgentRoleDescriptor? {
        let normalized = roleId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return builtIns.first { $0.id == normalized }
    }

    static let validRoleIds: [String] = builtIns.map(\.id).sorted()

    static func defaultToolNames(
        roleId: String,
        availableToolNames: [String],
        mcpServers: [IOSMcpServerConfig] = []
    ) -> [String] {
        guard let role = resolve(roleId: roleId) else { return [] }
        let available = Set(availableToolNames)
        var names = Set(role.toolAllowlist).intersection(available)
        if role.id == "browser" {
            for server in mcpServers where server.enabled {
                for tool in server.tools where tool.enabled
                    && ["browser_", "cdp_", "devtools_"].contains(where: tool.name.hasPrefix) {
                    let name = ToolKt.expandedMcpToolName(server: server.name, tool: tool.name)
                    if available.contains(name) { names.insert(name) }
                }
            }
        }
        return names.sorted()
    }
}

enum IOSSubAgentToolPolicy {
    static let readOnlyParentToolNames: Set<String> = [
        "search_web", "scrape_web",
        "file_read_selected", "permissions_status",
        "workspace_file_read", "workspace_file_list", "workspace_file_search", "workspace_artifact_read",
        "wm_stations", "wm_state", "wm_extract", "wm_get", "wm_find", "wm_wait", "wm_back", "wm_forward"
    ]

    static let deniedToolNames: Set<String> = [
        "workspace_file_write", "workspace_file_edit", "workspace_file_move", "workspace_artifact_delete",
        "wm_open", "wm_clear_session", "wm_click", "wm_tap", "wm_type", "wm_keys", "wm_scroll", "wm_select",
        "mcp_call", "memory_tool", "generate_image", "subagent_dispatch", "model_council_run"
    ]

    /// WebMount names exposed only to an explicitly selected browser-capable
    /// role. The executor still applies the normal WebMount policy, so a
    /// background run receives a denial when foreground approval or high-risk
    /// auto-approval is required.
    static let browserAutomationToolNames: Set<String> = [
        "wm_tab_list", "wm_open", "wm_state", "wm_observe", "wm_extract", "wm_get",
        "wm_visual_snapshot", "wm_back", "wm_forward", "wm_click", "wm_tap", "wm_type",
        "wm_keys", "wm_scroll", "wm_select", "wm_find", "wm_wait"
    ]

    static func isDenied(_ name: String) -> Bool {
        deniedToolNames.contains(name)
    }
}

/// iOS entry point for engine-based, multi-turn sub-agent execution.
@MainActor
@Observable
final class SubAgentRunner {
    @ObservationIgnored private let taskStore: IOSAdvancedTaskStore
    /// Each invocation owns its own provider task. A single optional task made
    /// concurrent background/foreground dispatches overwrite one another, so
    /// cancellation and `isRunning` could target the wrong run.
    @ObservationIgnored private var currentEngineRunTasks: [UUID: Task<IOSAgentToolEngineResult, Never>] = [:]
    @ObservationIgnored private var currentEngineRunOrder: [UUID] = []
    @ObservationIgnored private var currentEngineExecutionId: UUID?
    @ObservationIgnored private var activeEngineRunCount = 0

    var lastRunResult: String = "(未运行)"
    var isRunning: Bool = false
    var lastTask: IOSAdvancedTaskRecord?

    init(taskStore: IOSAdvancedTaskStore = .shared) {
        self.taskStore = taskStore
    }

    var recentTasks: [IOSAdvancedTaskRecord] {
        taskStore.recent(kind: .subAgent, limit: 5)
    }

#if DEBUG
    var hasActiveEngineRunForTesting: Bool {
        !currentEngineRunTasks.isEmpty
    }
#endif

    // MARK: - Engine-based multi-turn execution (Android GenerationSubAgentRunner parity)
    //
    // This path uses the reusable IOSAgentToolEngine to run a real multi-turn
    // loop with the allowed parent tools + subagent_report. The engine executes
    // each call, re-calls the model, and captures the structured report. Mirrors
    // Android's GenerationSubAgentRunner (maxTurns loop + subagent_report
    // capture + resultOrFallback). Real-model behavior is validated via manual
    // smoke; the loop mechanics are unit-tested with a scripted provider.

    /// Executes a SubAgent via the engine. Caller supplies the engine's tool
    /// executors (parent tools) so this stays decoupled from ChatViewModel.
    /// Returns the captured report JSON (or an honest fallback).
    func runViaEngine(
        objective: String,
        roleId: String = "explorer",
        requestedToolScope: [String] = [],
        customRoleName: String? = nil,
        customRoleLens: String? = nil,
        customRolePrompt: String? = nil,
        skillContext: String? = nil,
        savedRolePromptOverride: String? = nil,
        toolAllowlistOverride: [String]? = nil,
        maxTurnsOverride: Int? = nil,
        outputBudgetCharsOverride: Int? = nil,
        providerSetting: ProviderSetting,
        modelId: String,
        baseParams: TextGenerationParams? = nil,
        modelOverride: Model? = nil,
        temperatureOverride: Float? = nil,
        reasoningLevelOverride: ReasoningLevel? = nil,
        additionalToolDeclarations: [Tool] = [],
        parentToolExecutors: [String: any IOSToolExecutor],
        toolCallId: String = "",
        timeoutSeconds: TimeInterval? = nil,
        provider: any IOSAgentTextProvider = OpenAIKmpProviderAdapter()
    ) async -> String {
        let role = Self.resolveDispatchRole(
            roleId: roleId,
            customRoleName: customRoleName,
            customRoleLens: customRoleLens,
            customRolePrompt: customRolePrompt,
            savedRolePromptOverride: savedRolePromptOverride,
            toolAllowlistOverride: toolAllowlistOverride,
            maxTurnsOverride: maxTurnsOverride,
            outputBudgetCharsOverride: outputBudgetCharsOverride
        )
        guard let role else {
            return Self.json([
                "ok": false,
                "error": "Unknown sub-agent role_id: \(roleId).",
                "valid_role_ids": IOSSubAgentRoleCatalog.validRoleIds,
                "hint": "Omit role_id for the default role, or pass custom_role_prompt to define a one-off custom role."
            ])
        }
        let requested = requestedToolScope
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Browser actions are opt-in per role. A saved allowlist or the
        // built-in browser role can grant them, while Explorer and custom
        // read-only roles keep the old fail-before-provider behavior.
        let browserScopeEnabled = role.allowsBrowserAutomation
            || (role.id == "custom" && requested.contains(where: IOSSubAgentToolPolicy.browserAutomationToolNames.contains))
            || (toolAllowlistOverride?.contains(where: IOSSubAgentToolPolicy.browserAutomationToolNames.contains) == true)
        let deniedRequested = requested.filter { name in
            IOSSubAgentToolPolicy.isDenied(name)
                && !(browserScopeEnabled && IOSSubAgentToolPolicy.browserAutomationToolNames.contains(name))
        }
        if !deniedRequested.isEmpty {
            return Self.json([
                "ok": false,
                "denied": true,
                "reason": "SubAgent is a read-only worker: requested tool_scope includes tools it may never execute (write, destructive, nested-agent, or sensitive WebMount tools).",
                "requested_tools": deniedRequested,
                "removed_tools": deniedRequested,
                "hint": "Narrow tool_scope to read-only tools (for example search_web, workspace_file_read, wm_get) or omit tool_scope to use the role allowlist."
            ])
        }
        let scopedTools = requested.isEmpty
            ? role.toolAllowlist
            : requested.filter { role.toolAllowlist.contains($0) }
        // The parent runtime may inject exact expanded MCP names. A name is
        // executable only when its adapter is present in this invocation;
        // role settings alone never manufacture an executor.
        let hostProvidedToolNames = Set(parentToolExecutors.keys)
        let tools = Self.uniqueTools((["tools_list"] + scopedTools).filter { tool in
            tool == "tools_list"
                || IOSSubAgentToolPolicy.readOnlyParentToolNames.contains(tool)
                || (browserScopeEnabled && IOSSubAgentToolPolicy.browserAutomationToolNames.contains(tool))
                || hostProvidedToolNames.contains(tool)
        })
        let removedTools = requested.filter { !tools.contains($0) }

        let task = taskStore.startTask(
            kind: .subAgent,
            title: "\(role.name) · \(objective.prefix(36))",
            objective: objective,
            roleId: role.id,
            toolScope: tools,
            budgetSummary: "turns \(role.maxTurns) · timeout \(role.timeoutSeconds)s · output \(role.outputBudgetChars) chars (engine)",
            sourceToolName: "subagent_dispatch",
            metadata: [
                "provider_mode": "engine_real_provider",
                "role_name": role.name,
                "engine": "true"
            ]
        )
        lastTask = task
        activeEngineRunCount += 1
        isRunning = true
        defer {
            activeEngineRunCount = max(0, activeEngineRunCount - 1)
            isRunning = activeEngineRunCount > 0
        }

        // Build the report-capture executor + merge with parent tools. Only the
        // allowed tools get executors; others fall through to the engine's
        // "unregistered tool" honest-failure path.
        let reportCapture = SubAgentReportCaptureExecutor()
        let toolsList = SubAgentToolsListExecutor(tools: tools)
        var executors: [String: any IOSToolExecutor] = [
            SUBAGENT_REPORT_TOOL_NAME_swift: reportCapture,
            "tools_list": toolsList
        ]
        for name in tools {
            if name != "tools_list", let parent = parentToolExecutors[name] {
                executors[name] = parent
            }
        }

        // Build the prompt: role system prompt + objective + tool scope.
        var systemPromptSections = [role.systemPrompt]
        if let skillContext = skillContext?.trimmingCharacters(in: .whitespacesAndNewlines), !skillContext.isEmpty {
            systemPromptSections.append(skillContext)
        }
        systemPromptSections.append("""
        You are subagent \(role.name). Work toward the objective using only the allowed tools.
        When done, call `subagent_report` with a concise summary and findings.
        Do not ask the user follow-up questions.
        """)
        let systemPrompt = systemPromptSections.joined(separator: "\n\n")
        let userPrompt = """
        Objective:
        \(objective)

        Allowed tools: \(tools.joined(separator: ", "))
        """
        let messages = [
            UIMessage.companion.system(prompt: systemPrompt),
            UIMessage.companion.user(prompt: userPrompt)
        ]

        let fallbackModel = Model(
            modelId: modelId,
            displayName: modelId,
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let params = TextGenerationParams(
            model: modelOverride ?? baseParams?.model ?? fallbackModel,
            temperature: temperatureOverride.map { KotlinFloat(value: $0) } ?? baseParams?.temperature,
            topP: baseParams?.topP,
            // `outputBudgetChars` bounds the report returned to the parent; it
            // is not a per-provider-turn token limit. Coupling the two caused
            // reasoning models to hit finish_reason=length before they could
            // call subagent_report, and lowering the report budget made the
            // failure more likely. Preserve an explicit parent model limit,
            // otherwise let the provider use its normal output allowance.
            maxTokens: baseParams?.maxTokens,
            tools: Self.buildSubAgentToolDeclarations(
                names: [SUBAGENT_REPORT_TOOL_NAME_swift] + tools,
                additionalDeclarations: additionalToolDeclarations
            ),
            reasoningLevel: reasoningLevelOverride ?? baseParams?.reasoningLevel ?? .off,
            customHeaders: baseParams?.customHeaders ?? [],
            customBody: baseParams?.customBody ?? []
        )

        let engine = IOSAgentToolEngine(
            provider: provider,
            executors: executors,
            configuration: .init(maxSteps: role.maxTurns + 1, honorApprovalPause: false)
        )

        // Live stream: register a model keyed by the dispatch tool call so the
        // chat detail sheet can show the subagent generating token-by-token, then
        // feed the engine's accumulating assistant text into it.
        let liveModel = await MainActor.run { SubAgentLiveModel() }
        await MainActor.run { SubAgentLiveRegistry.shared.register(toolCallId: toolCallId, liveModel) }
        let execution = await runEngine(
            engine,
            providerSetting: providerSetting,
            messages: messages,
            params: params,
            timeoutSeconds: timeoutSeconds ?? TimeInterval(role.timeoutSeconds),
            liveModel: liveModel
        )
        await MainActor.run { liveModel.finish() }

        let result: IOSAgentToolEngineResult?
        let mappedStatus: IOSAdvancedTaskStatus
        let terminalError: String?
        switch execution {
        case .result(let value):
            result = value
            if value.wasCancelled {
                mappedStatus = .cancelled
                terminalError = nil
            } else if let providerFailure = value.providerFailureMessage {
                mappedStatus = .failed
                terminalError = providerFailure
            } else if value.guardStopped {
                // I-5: the engine detected the model repeating an identical
                // tool call and stopped the run. Must not fall through to
                // `.completed` — that would disguise a stuck loop as success.
                mappedStatus = .failed
                terminalError = "SubAgent stopped: the model repeated the same tool call with identical arguments."
            } else if value.hitStepLimit {
                mappedStatus = .failed
                terminalError = "SubAgent reached its maximum turn budget."
            } else {
                mappedStatus = .completed
                terminalError = nil
            }
        case .timedOut:
            result = nil
            mappedStatus = .timedOut
            terminalError = "SubAgent timed out after \(timeoutSeconds ?? TimeInterval(role.timeoutSeconds)) seconds."
        case .cancelled:
            result = nil
            mappedStatus = .cancelled
            terminalError = nil
        }

        let displayText = (result?.messages ?? [])
            .filter { $0.role == MessageRole.assistant }
            .flatMap { $0.parts }
            .compactMap { $0 as? UIMessagePart.Text }
            .map { $0.text }
            .joined(separator: "\n")

        let summary: String
        if let terminalError {
            summary = terminalError
        } else if mappedStatus == .cancelled {
            summary = "SubAgent was cancelled."
        } else if let report = reportCapture.captured {
            summary = report
        } else {
            // No structured report captured — fall back to the visible transcript
            // (Android resultOrFallback behavior).
            summary = displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "SubAgent completed without a report or visible output."
                : String(displayText.prefix(role.outputBudgetChars))
        }

        lastTask = taskStore.updateTask(
            id: task.id,
            status: mappedStatus,
            resultSummary: String(summary.prefix(1_000)),
            logTail: "role=\(role.id)\ntools=\(tools.joined(separator: ", "))\nsteps=\(result?.stepsExecuted ?? 0)\nreport_captured=\(reportCapture.captured != nil)",
            error: terminalError ?? "",
            retryable: mappedStatus != .completed,
            cancelCapability: false,
            metadata: [
                "steps_executed": "\(result?.stepsExecuted ?? 0)",
                "report_captured": "\(reportCapture.captured != nil)",
                "hit_step_limit": "\(result?.hitStepLimit ?? false)",
                "guard_stopped": "\(result?.guardStopped ?? false)",
                "was_cancelled": "\(result?.wasCancelled ?? (mappedStatus == .cancelled))"
            ]
        )
        lastRunResult = summary
        return Self.json([
            "ok": mappedStatus == .completed,
            "task_id": task.id,
            "kind": IOSAdvancedTaskKind.subAgent.rawValue,
            "role_id": role.id,
            "role_name": role.name,
            "status": mappedStatus.rawValue,
            "tool_scope": tools,
            "removed_tools": removedTools,
            "engine": true,
            "steps_executed": result?.stepsExecuted ?? 0,
            "report_captured": reportCapture.captured != nil,
            "summary": String(summary.prefix(2_000))
        ])
    }

    private enum EngineExecution {
        case result(IOSAgentToolEngineResult)
        case timedOut
        case cancelled
    }

    private func runEngine(
        _ engine: IOSAgentToolEngine,
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        timeoutSeconds: TimeInterval,
        liveModel: SubAgentLiveModel
    ) async -> EngineExecution {
        let timeoutState = SubAgentTimeoutState()
        let input = SubAgentEngineInput(
            engine: engine,
            providerSetting: providerSetting,
            messages: messages,
            params: params
        )
        let runTask = Task { @MainActor in
            await input.engine.run(
                providerSetting: input.providerSetting,
                messages: input.messages,
                params: input.params,
                onAssistantText: { text in
                    liveModel.ingest(text)
                }
            )
        }
        let executionId = UUID()
        currentEngineExecutionId = executionId
        currentEngineRunTasks[executionId] = runTask
        currentEngineRunOrder.append(executionId)
        defer {
            currentEngineRunTasks.removeValue(forKey: executionId)
            currentEngineRunOrder.removeAll { $0 == executionId }
            if currentEngineExecutionId == executionId {
                currentEngineExecutionId = currentEngineRunOrder.last
            }
        }
        let timeoutTask = Task { @MainActor in
            do {
                let nanoseconds = UInt64(max(0.001, timeoutSeconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            timeoutState.didTimeout = true
            runTask.cancel()
        }
        return await withTaskCancellationHandler {
            let result = await runTask.value
            timeoutTask.cancel()
            if timeoutState.didTimeout {
                return .timedOut
            }
            return result.wasCancelled ? .cancelled : .result(result)
        } onCancel: {
            runTask.cancel()
            timeoutTask.cancel()
        }
    }

    /// The KMP `subagent_report` tool name as visible in Swift.
    private var SUBAGENT_REPORT_TOOL_NAME_swift: String { "subagent_report" }

    /// Build tool declarations for a subagent the SAME way the main chat does:
    /// `search_web` / `scrape_web` need their dedicated factories (the generic
    /// `iosToolDeclarations` emits an incomplete schema the provider rejects with a
    /// 500). Everything else (workspace / wm_ / file_read / report / tools_list) goes
    /// through the generic declarations.
    private static func buildSubAgentToolDeclarations(
        names: [String],
        additionalDeclarations: [Tool] = []
    ) -> [Tool] {
        var declarations: [Tool] = []
        var genericNames: [String] = []
        for name in names {
            switch name {
            case "search_web": declarations.append(ToolKt.createSearchWebToolDeclaration())
            case "scrape_web": declarations.append(ToolKt.createScrapeWebToolDeclaration())
            default: genericNames.append(name)
            }
        }
        if !genericNames.isEmpty {
            declarations.append(contentsOf: ToolKt.iosToolDeclarations(names: genericNames))
        }
        let declaredNames = Set(declarations.map(\.name))
        declarations.append(contentsOf: additionalDeclarations.filter { !declaredNames.contains($0.name) })
        return declarations
    }

    private static func uniqueTools(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names where seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }

    /// Resolves the role for one dispatch: a one-off custom role when
    /// `customRolePrompt` is provided, otherwise a built-in role by id (nil for
    /// unknown ids, so callers surface a structured error instead of silently
    /// falling back). Budgets are clamped to the shared execution bounds —
    /// maxTurns 2-8 (custom roles default 4), output budget 4000-24000 chars
    /// (custom roles default 12000) — while built-in role seeds are preserved
    /// when no override is passed. Custom roles get the same read-only tool
    /// whitelist and denied set as built-ins (IOSSubAgentToolPolicy unchanged).
    private static func resolveDispatchRole(
        roleId: String?,
        customRoleName: String?,
        customRoleLens: String?,
        customRolePrompt: String?,
        savedRolePromptOverride: String?,
        toolAllowlistOverride: [String]?,
        maxTurnsOverride: Int?,
        outputBudgetCharsOverride: Int?
    ) -> IOSSubAgentRoleDescriptor? {
        let prompt = customRolePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base: IOSSubAgentRoleDescriptor
        if !prompt.isEmpty {
            let name = customRoleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lens = customRoleLens?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            base = IOSSubAgentRoleDescriptor(
                id: "custom",
                name: name.isEmpty ? "Custom Agent" : name,
                summary: lens.isEmpty ? "一次性自定义角色，按本次目标聚焦。" : lens,
                systemPrompt: prompt,
                routing: "模型按需组建的一次性专家；只使用只读工具。",
                toolAllowlist: Array(IOSSubAgentToolPolicy.readOnlyParentToolNames).sorted(),
                maxTurns: 4,
                timeoutSeconds: 300,
                outputBudgetChars: 12_000,
                allowsBrowserAutomation: false
            )
        } else if let resolved = IOSSubAgentRoleCatalog.resolve(roleId: roleId) {
            let savedPrompt = savedRolePromptOverride?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            base = IOSSubAgentRoleDescriptor(
                id: resolved.id,
                name: resolved.name,
                summary: resolved.summary,
                systemPrompt: savedPrompt.isEmpty ? resolved.systemPrompt : savedPrompt,
                routing: resolved.routing,
                toolAllowlist: resolved.toolAllowlist,
                maxTurns: resolved.maxTurns,
                timeoutSeconds: resolved.timeoutSeconds,
                outputBudgetChars: resolved.outputBudgetChars,
                allowsBrowserAutomation: resolved.allowsBrowserAutomation
            )
        } else {
            return nil
        }
        let effectiveToolAllowlist = toolAllowlistOverride?.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty } ?? base.toolAllowlist
        return IOSSubAgentRoleDescriptor(
            id: base.id,
            name: base.name,
            summary: base.summary,
            systemPrompt: base.systemPrompt,
            routing: base.routing,
            toolAllowlist: effectiveToolAllowlist,
            maxTurns: Self.clamp(maxTurnsOverride ?? base.maxTurns, lower: 2, upper: 8),
            timeoutSeconds: base.timeoutSeconds,
            outputBudgetChars: Self.clamp(outputBudgetCharsOverride ?? base.outputBudgetChars, lower: 4_000, upper: 24_000),
            allowsBrowserAutomation: base.allowsBrowserAutomation
        )
    }

    private static func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        Swift.min(Swift.max(value, lower), upper)
    }

    func cancelCurrentRun() {
        guard let executionId = currentEngineExecutionId,
              let currentEngineRunTask = currentEngineRunTasks[executionId] else {
            lastRunResult = "没有正在运行的 SubAgent"
            return
        }
        currentEngineRunTask.cancel()
        lastRunResult = "正在取消 SubAgent…"
    }

    static func json(_ object: [String: Any]) -> String {
        subAgentJSON(object)
    }
}

@MainActor
private final class SubAgentTimeoutState {
    var didTimeout = false
}

/// KMP message/config objects are immutable for one engine invocation but are
/// not imported as Swift `Sendable`. The child task owns this box for the run;
/// no field is read again by the parent while the engine is executing.
private final class SubAgentEngineInput: @unchecked Sendable {
    let engine: IOSAgentToolEngine
    let providerSetting: ProviderSetting
    let messages: [UIMessage]
    let params: TextGenerationParams

    init(
        engine: IOSAgentToolEngine,
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) {
        self.engine = engine
        self.providerSetting = providerSetting
        self.messages = messages
        self.params = params
    }
}

/// Engine executor for the `subagent_report` tool. Captures the model's
/// structured report payload (summary/findings/evidence/risks/...) so the
/// SubAgent runner can surface it as the tool result, mirroring Android's
/// KMP `SubAgentReportCapture`. The captured value is the raw arguments JSON.
final class SubAgentReportCaptureExecutor: IOSToolExecutor {
    /// The last `subagent_report` arguments the model emitted, or nil if it
    /// never called the tool (the runner falls back to visible text).
    private(set) var captured: String?

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed("subagent_report requires a non-empty summary or findings.")
        }
        captured = trimmed
        return .filled("{\"status\":\"ok\",\"message\":\"Structured subagent report recorded.\"}")
    }
}

final class SubAgentToolsListExecutor: IOSToolExecutor {
    private let tools: [String]

    init(tools: [String]) {
        self.tools = tools
    }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        let items = tools.map { tool in
            [
                "name": tool,
                "description": Self.description(for: tool)
            ]
        }
        return .filled(subAgentJSON([
            "ok": true,
            "tools": items
        ]))
    }

    private static func description(for tool: String) -> String {
        switch tool {
        case "tools_list": "List tools available in this sub-agent run."
        case "search_web": "Search the public web through configured iOS search providers."
        case "scrape_web": "Extract readable text from a public http/https URL."
        case "file_read_selected": "Read the user's currently selected foreground file preview."
        case "permissions_status": "Read iOS capability and permission status."
        case "workspace_file_read": "Read an imported Workspace file."
        case "workspace_file_list": "List imported Workspace files."
        case "workspace_file_search": "Search imported Workspace file previews."
        case "workspace_artifact_read": "Read a saved Workspace artifact."
        case "wm_stations": "List configured WebMount stations."
        case "wm_state": "Read current WebMount page state."
        case "wm_extract": "Extract readable or interactive WebMount page content."
        case "wm_get": "Read one safe WebMount element value/text/attribute."
        case "wm_find": "Find text or selector matches on the current WebMount page."
        case "wm_wait": "Wait briefly for WebMount page activity."
        case "wm_back": "Navigate WebMount backward."
        case "wm_forward": "Navigate WebMount forward."
        default: "Available iOS sub-agent tool."
        }
    }
}
