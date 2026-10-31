import Foundation
@preconcurrency import Shared

@MainActor
extension ChatToolRuntime {
    func novelDiscussionToolExecutors(
        projectContext: NovelProjectToolRunContext? = nil
    ) -> [String: any IOSToolExecutor] {
        var executors: [String: any IOSToolExecutor] = [
            "ask_user": IOSClosureToolExecutor { _, _, _ in
                .needsApproval("等待用户回答")
            }
        ]
        if let projectContext {
            let projectExecutor = IOSNovelProjectToolExecutor(
                projectContext: projectContext,
                creation: novelProjectCreation
            )
            for name in IOSNovelProjectToolExecutor.supportedToolNames {
                executors[name] = projectExecutor
            }
        }
        guard effectiveWebSearchEnabled else { return executors }
        for name in IOSSearchExecutor.supportedToolNames {
            executors[name] = IOSClosureToolExecutor { [weak self] toolName, arguments, isUserInitiated in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                switch self.searchToolPermission(isUserInitiated: isUserInitiated) {
                case .denied(let reason): return .denied(reason)
                case .needsApproval(let reason): return .needsApproval(reason)
                case .allow: break
                }
                let call = self.toolCall(name: toolName, input: arguments)
                return .filled(await self.dispatchSearchToolCall(call, isUserInitiated: isUserInitiated))
            }
        }
        return executors
    }

    func backgroundToolExecutors(
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        toolExposureBridge: IosToolExposureBridge? = nil,
        conversationId: KotlinUuid? = nil,
        /// Job-frozen display messages for generate_image pad-image enrich.
        /// Must be the snapshot that owns this tool call — not a live store read.
        messages: [UIMessage] = [],
        executionPolicy: IOSExecutionPolicySnapshot? = nil,
        dynamicToolSnapshot: IOSDynamicToolCatalogSnapshot? = nil
    ) -> [String: any IOSToolExecutor] {
        backgroundToolExecutorsWithCurrentPolicy(
            providerSetting: providerSetting,
            params: params,
            runId: runId,
            toolExposureBridge: toolExposureBridge,
            conversationId: conversationId,
            messages: messages,
            executionPolicy: executionPolicy,
            dynamicToolSnapshot: dynamicToolSnapshot
        )
    }

    private func backgroundToolExecutorsWithCurrentPolicy(
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        toolExposureBridge: IosToolExposureBridge?,
        conversationId: KotlinUuid?,
        messages: [UIMessage],
        executionPolicy: IOSExecutionPolicySnapshot?,
        dynamicToolSnapshot: IOSDynamicToolCatalogSnapshot?
    ) -> [String: any IOSToolExecutor] {
        var executors: [String: any IOSToolExecutor] = [:]
        let availableToolNames = Set(params.tools.map(\.name))
        for name in IOSShortcutAuthoringToolCatalog.toolNames where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor { _, arguments, _ in
                .filled(await IOSShortcutAuthoringToolExecutor.execute(input: arguments))
            }
        }
        let phoneExecutor = IOSPhoneControlToolExecutor(runID: runId)
        for name in IOSPhoneControlToolCatalog.toolNames where availableToolNames.contains(name) {
            executors[name] = phoneExecutor
        }
        for name in IOSWakeToolCatalog.toolNames where availableToolNames.contains(name) {
            executors[name] = IOSToolCallClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] tool in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                return .filled(await IOSWakeToolExecutor.execute(
                    tool: tool,
                    runID: runId,
                    conversationID: conversationId?.toHexDashString(),
                    messages: messages,
                    scheduler: self.wakeScheduler
                ))
            }
        }
        // Jev 自动批准复核：后台没有审批卡，收紧后各执行器按原逻辑返回"需回到 App 确认"。
        let recentUserTexts = messages.filter { $0.role == MessageRole.user }.suffix(3).map { $0.toText() }
        let tighten: @MainActor (String, String) async -> Bool = { [weak self] name, arguments in
            guard let self else { return false }
            return await self.shouldTightenAutoApproval(
                toolCall: self.toolCall(name: name, input: arguments),
                recentUserTexts: recentUserTexts,
                runId: runId,
                conversationId: conversationId,
                toolExposureBridge: toolExposureBridge
            )
        }

        // P0-a: tool_search is a local discovery call, safe in background. The
        // background job owns its own bridge instance (rebuilt from the handoff
        // declarations with exposure reset — the foreground's expanded hits are
        // not transferred). IOSAgentToolEngine re-derives params from the same
        // bridge after every batch (Fix C), so hits expanded inside a
        // background round become callable on the next background round.
        if availableToolNames.contains("tool_search") {
            executors["tool_search"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, arguments, _ in
                guard let bridge = toolExposureBridge else {
                    return .failed("tool_search is unavailable in this run.")
                }
                // Jev Phase 1：后台与前台共用语义发现服务（off 零网络）。
                let output = await IOSJevToolDiscoveryService.execute(
                    argumentsJson: arguments,
                    selectedTaskText: messages.reversed().first(where: { $0.role == MessageRole.user })?.toText() ?? "",
                    bridge: bridge,
                    identity: IOSJevToolDiscoveryService.RunIdentity(
                        runId: runId,
                        turnBudgetKey: IOSJevToolDiscoveryService.turnBudgetKey(runId: runId)
                    )
                )
                return .filled(output)
            }
        }
        // M5: tools_list 与 tool_search 同属本地目录调用（discovery 引导引用它）——
        // 后台安全，注册为桥的本地执行（返回全目录 {name, description} 清单）。
        if availableToolNames.contains("tools_list") {
            executors["tools_list"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, _, _ in
                guard let bridge = toolExposureBridge else {
                    return .failed("tools_list is unavailable in this run.")
                }
                return .filled(bridge.executeToolsList())
            }
        }

        // Dynamic plugins are background-capable only when the exact
        // process-local snapshot opted in and the handler is declarative or
        // remote read-only. Restricted JS, side effects, Shell/Python/iSH and
        // cold-restored name-only payloads never enter this table.
        for descriptor in dynamicToolSnapshot?.backgroundEligibleDescriptors ?? []
        where availableToolNames.contains(descriptor.toolId) {
            executors[descriptor.toolId] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] _, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                return await self.pluginExecution.executeBackgroundPlugin(
                    descriptor: descriptor,
                    argumentsJSON: arguments,
                    providerSetting: providerSetting,
                    params: params,
                    runId: runId,
                    conversationId: conversationId,
                    bridge: toolExposureBridge,
                    executionPolicy: executionPolicy
                )
            }
        }

        for name in IOSSearchExecutor.supportedToolNames where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                switch self.searchToolPermission() {
                case .denied(let reason): return .denied(reason)
                case .needsApproval:
                    return .denied("后台生成期间需要回到 App 确认网络搜索或网页读取。")
                case .allow: break
                }
                let result = await self.dispatchSearchToolOutput(self.toolCall(name: toolName, input: arguments))
                // P2-a: 后台 run 标记到 run 锚定会话（conversationId 由 job 传入），
                // 不得标到前台当前会话。
                self.markMemoryPollutionIfNeeded(
                    toolName: toolName,
                    outputText: result.text,
                    conversationId: conversationId
                )
                return .filledParts(result.parts)
            }
        }

        if localToolExecutor != nil {
            for name in IOSWorkspaceToolCatalog.supportedToolNames where availableToolNames.contains(name) {
                executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy, tighten: tighten) { [weak self] toolName, arguments, _ in
                    guard let self else { return .failed("Chat runtime is unavailable.") }
                    let toolCall = self.toolCall(name: toolName, input: arguments)
                    let output = await self.workspaceToolExecutionOutput(toolCall, isUserInitiated: false)
                    if case .needsUserAction(let reason) = output {
                        return .denied("后台生成期间需要回到 App 确认 Workspace 操作：\(reason)")
                    }
                    return .filled(ChatToolOutputFormatter.workspaceResultText(for: toolCall, output: output))
                }
            }

            for name in IOSAgentTerminalToolCatalog.supportedToolNames
            where availableToolNames.contains(name) {
                executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy, tighten: tighten) { [weak self] toolName, arguments, _ in
                    guard let self else { return .failed("Chat runtime is unavailable.") }
                    let toolCall = self.toolCall(name: toolName, input: arguments)
                    let output = await self.ishToolExecutionOutput(
                        toolCall,
                        isUserInitiated: self.isIshAutoApproved(
                            toolName: toolName,
                            input: arguments,
                            runId: runId,
                            conversationId: conversationId
                        )
                    )
                    if case .needsUserAction(let reason) = output {
                        return .denied("后台生成期间需要回到 App 确认终端操作：\(reason)")
                    }
                    return .filled(ChatToolOutputFormatter.ishHandoffResultText(for: toolCall, output: output))
                }
            }
        }

        if isWebMountRuntimeEnabled {
            for name in IOSWebMountToolCatalog.supportedToolNames.union(IOSWebMountToolCatalog.unsupportedToolNames)
            where availableToolNames.contains(name) {
                executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy, tighten: tighten) { [weak self] toolName, arguments, _ in
                    guard let self else { return .failed("Chat runtime is unavailable.") }
                    let toolCall = self.toolCall(name: toolName, input: arguments)
                    let output = await self.webMountToolExecutionOutput(
                        toolCall,
                        isUserInitiated: false,
                        runId: runId,
                        conversationId: conversationId
                    )
                    if case .needsUserAction(let reason) = output {
                        return .denied("后台生成期间需要回到 App 确认 WebMount 操作：\(reason)")
                    }
                    let resultText = ChatToolOutputFormatter.webMountResultText(for: toolCall, output: output)
                    if output.isWebMountOutcomeUnknown {
                        return .outcomeUnknown([UIMessagePart.Text(text: resultText, metadata: nil)])
                    }
                    return .filled(resultText)
                }
            }
        }

        if availableToolNames.contains("memory_tool") {
            executors["memory_tool"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] _, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                let policy = self.memoryToolWritePolicy(input: arguments, isUserInitiated: false)
                if case .needsUserAction(let reason) = policy {
                    return .denied("后台生成期间需要回到 App 确认记忆写入：\(reason)")
                }
                return .filled(self.dispatchMemoryToolCall(self.toolCall(name: "memory_tool", input: arguments), writePolicy: policy))
            }
        }

        if availableToolNames.contains("generate_image") {
            let enrichMessages = messages
            executors["generate_image"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] _, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                return .filledParts(
                    await self.dispatchImageToolCall(
                        self.toolCall(name: "generate_image", input: arguments),
                        messages: enrichMessages
                    )
                )
            }
        }

        // Advanced tools in background. The foreground approval UI cannot surface
        // during a BGContinuedProcessingTask, so:
        //  - subagent_dispatch: orchestration may run when enabled. The worker is
        //    read-only and every nested tool keeps its own permission boundary.
        //  - mcp_call: high-risk (external/remote), mirrors the foreground gate —
        //    only runs when the high-risk auto-approve switch is on, otherwise
        //    denied so the user returns to the app to confirm.
        //  - model_council_run: DENIED in background. A council run is a long,
        //    multi-seat/multi-round streaming sequence (many sequential HTTP calls,
        //    potentially tens of minutes) that occupies a single executor step. The
        //    BGTask expirationHandler cannot interrupt an in-flight streamText, so a
        //    background council would overrun the BGTask window and be force-killed,
        //    leaving an incomplete run. It also drives the council-room @Observable
        //    UI, which has no subscriber in background. Revert to foreground.
        if availableToolNames.contains("subagent_dispatch") {
            executors["subagent_dispatch"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                let toolCall = self.toolCall(name: toolName, input: arguments)
                guard self.isAdvancedToolEnabled(toolName) else {
                    return .failed("\(toolName) 未开启。请先在设置中启用对应能力。")
                }
                let result = await self.dispatchAdvancedToolCall(
                    toolCall,
                    providerSetting: providerSetting,
                    params: params,
                    runId: runId,
                    conversationId: conversationId
                )
                return .filled(result)
            }
        }

        if availableToolNames.contains("model_council_run") {
            executors["model_council_run"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, _, _ in
                .denied("模型委员会运行时间较长且依赖前台房间界面，请回到 App 内执行。")
            }
        }

        if availableToolNames.contains(IOSWeatherToolCatalog.toolName) {
            executors[IOSWeatherToolCatalog.toolName] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, arguments, _ in
                guard !IOSWeatherToolExecutor.requestsCurrentLocation(input: arguments) else {
                    return .denied("后台生成期间不能申请当前位置，请回到 App 内使用天气工具。")
                }
                return .filled(await IOSWeatherToolExecutor.execute(input: arguments))
            }
        }
        if availableToolNames.contains(IOSAppleAgentToolCatalog.workoutPlanPreview) {
            executors[IOSAppleAgentToolCatalog.workoutPlanPreview] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { name, arguments, _ in
                .filled(await IOSWorkoutAgentToolExecutor.execute(toolName: name, input: arguments))
            }
        }
        for name in IOSAppleAgentToolCatalog.approvalRequiredToolNames
        where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, _, _ in
                .denied("Apple 健康、日历、提醒事项、通知与闹钟工具需要回到 App 前台确认。")
            }
        }
        for name in IOSAppleAgentToolCatalog.pickerToolNames
        where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, _, _ in
                .denied("个人资料选取需要回到 App 前台使用系统选择器。")
            }
        }
        // ask_user is a foreground HITL node. Background cannot present the card or
        // Watch decision, so deny with an explicit return-to-app reason instead of
        // leaving the tool unregistered (engine would otherwise error-fill and continue).
        if availableToolNames.contains("ask_user") {
            executors["ask_user"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { _, _, _ in
                .denied("后台生成期间需要回到 App 回答问题。")
            }
        }

        if availableToolNames.contains("mcp_call") {
            executors["mcp_call"] = IOSClosureToolExecutor(executionPolicy: executionPolicy, tighten: tighten) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                // High-risk gate mirrors the foreground path (executeAdvancedToolCall):
                // MCP may touch external services, so only auto-run when the high-risk
                // auto-approve switch is on. Otherwise deny so the user returns to confirm.
                guard self.effectiveHighRiskAutoApproveEnabled else {
                    return .denied("后台生成期间需要回到 App 确认 MCP 工具。")
                }
                guard self.isAdvancedToolEnabled(toolName) else {
                    return .failed("\(toolName) 未开启。请先在设置中启用对应能力。")
                }
                let result = await self.dispatchMcpToolOutput(self.toolCall(name: toolName, input: arguments))
                // P2-a: 后台 run 标记到 run 锚定会话。
                self.markMemoryPollutionIfNeeded(
                    toolName: toolName,
                    outputText: result.text,
                    conversationId: conversationId
                )
                return .filledParts(result.parts)
            }
        }

        // P0-b: flattened `mcp__*` tools mirror the mcp_call background gate
        // (high-risk auto-approve required; same dispatch path). Only names
        // visible in the current round's params are registered.
        for tool in params.tools where ToolKt.isExpandedMcpToolName(name: tool.name) {
            let expandedName = tool.name
            executors[expandedName] = IOSClosureToolExecutor(executionPolicy: executionPolicy, tighten: tighten) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                guard self.effectiveHighRiskAutoApproveEnabled else {
                    return .denied("后台生成期间需要回到 App 确认 MCP 工具。")
                }
                guard self.isAdvancedToolEnabled(toolName) else {
                    return .failed("\(toolName) 未开启。请先在设置中启用对应能力。")
                }
                let result = await self.dispatchMcpToolOutput(self.toolCall(name: toolName, input: arguments))
                // P2-a: 后台 run 标记到 run 锚定会话。
                self.markMemoryPollutionIfNeeded(
                    toolName: toolName,
                    outputText: result.text,
                    conversationId: conversationId
                )
                return .filledParts(result.parts)
            }
        }

        let skillMcpNames = IOSSkillToolCatalog.toolNames
            .union(IOSMcpManagementToolCatalog.toolNames)
            .union([IOSSoulToolCatalog.toolName])
        for name in skillMcpNames where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy, tighten: tighten) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                if Self.isHostPublishTool(toolName) {
                    return await self.backgroundHostPublishOutcome(
                        toolName: toolName,
                        arguments: arguments
                    )
                }
                let mutating = IOSSkillToolCatalog.mutatingToolNames.contains(toolName)
                    || IOSMcpManagementToolCatalog.mutatingToolNames.contains(toolName)
                let highRisk = IOSMcpManagementToolCatalog.highRiskToolNames.contains(toolName)
                let autoApproved = highRisk
                    ? self.effectiveHighRiskAutoApproveEnabled
                    : self.effectiveGlobalAutoApproveEnabled
                        || self.effectiveHighRiskAutoApproveEnabled
                if mutating, !autoApproved {
                    return .denied("后台生成期间需要回到 App 确认 \(toolName)。")
                }
                if IOSMcpManagementToolCatalog.toolNames.contains(toolName),
                   !self.isAdvancedToolEnabled(toolName) {
                    return .failed("\(toolName) 未开启。请先在设置中启用 MCP。")
                }
                let result = await self.dispatchAdvancedToolCall(
                    self.toolCall(name: toolName, input: arguments),
                    providerSetting: providerSetting,
                    params: params,
                    runId: runId,
                    conversationId: conversationId
                )
                return .filled(result)
            }
        }

        // Recipe 管理工具可在后台读取；写操作只有对应自动批准策略已开启时
        // 执行。独立 recipe__* 仍不进入后台目录；显式声明且只读的
        // plugin__* 工具已在上方按固定目录快照注册。
        for name in IOSRecipeToolCatalog.toolNames where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy, tighten: tighten) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                if Self.isHostPublishTool(toolName) {
                    return await self.backgroundHostPublishOutcome(
                        toolName: toolName,
                        arguments: arguments
                    )
                }
                let mutating = IOSRecipeToolCatalog.mutatingToolNames.contains(toolName)
                let highRisk = IOSRecipeToolCatalog.highRiskToolNames.contains(toolName)
                let autoApproved = highRisk
                    ? self.effectiveHighRiskAutoApproveEnabled
                    : self.effectiveGlobalAutoApproveEnabled || self.effectiveHighRiskAutoApproveEnabled
                if mutating, !autoApproved {
                    return .denied("后台生成期间需要回到 App 确认 \(toolName)。")
                }
                let result = await self.dispatchAdvancedToolCall(
                    self.toolCall(name: toolName, input: arguments),
                    providerSetting: providerSetting,
                    params: params,
                    runId: runId,
                    conversationId: conversationId
                )
                return .filled(result)
            }
        }

        // P1-c/P1-d: 线程编排工具后台注册——子线程在后台引擎里同样可 spawn 孙线程 /
        // list / interrupt / 收发消息 / wait（深度与并发上限由服务内检查兜底）。
        // 与 mcp 先例同：只注册当前轮 params 可见的名字。conversationId = 本 job
        // 的 run 锚定会话（由后台协调器传入），生成中切会话不串到当前会话。
        for name in ["spawn_agent", "list_agents", "interrupt_agent", "send_message", "followup_task", "wait_agent"]
            where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                guard let service = self.orchestrationToolService else {
                    return .failed("线程编排工具当前不可用。")
                }
                let result = await service.execute(
                    toolName: toolName,
                    arguments: arguments,
                    providerSetting: providerSetting,
                    params: params,
                    runId: runId,
                    conversationId: conversationId,
                    // M3: 传 run 的桥——子 run 的 fullToolNames 取全目录而非当轮
                    // 可见子集（闭包捕获的是本 job 的桥实例，全 run 不变）。
                    toolExposureBridge: toolExposureBridge,
                    executionPolicy: IOSExecutionPolicyContext.snapshot
                )
                return .filled(result)
            }
        }

        // 跨会话读取（session_search/session_read）：本地只读、无审批，前后台
        // 同注册（照 tool_search 先例）。只注册当前轮 params 可见的名字。
        for name in ["session_search", "session_read", "history_search", "history_fetch"] where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                return .filled(await self.dispatchSessionReadToolCall(
                    self.toolCall(name: toolName, input: arguments),
                    conversationId: conversationId
                ))
            }
        }

        // runtime_status：本地运行时自省（Jev 模式/凭据存在性/门控/目录计数），
        // 无网络无副作用——前后台同注册（照 session_read 先例）。
        if availableToolNames.contains("runtime_status") {
            executors["runtime_status"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                return .filled(self.dispatchRuntimeStatusToolCall(
                    self.toolCall(name: toolName, input: arguments),
                    toolExposureBridge: toolExposureBridge
                ))
            }
        }

        // Provider/model 配置：后台仅 status（纯读）；写工具拒绝（审批卡只在前台）。
        for name in IOSProviderConfigToolCatalog.toolNames where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                if !IOSProviderConfigToolCatalog.backgroundAllowedToolNames.contains(toolName) {
                    return .denied("provider 配置写入仅前台可用，请回到 App 确认后再试。")
                }
                let result = await self.providerConfigToolService.execute(
                    toolName: toolName,
                    argumentsJSON: arguments
                )
                return .filled(result)
            }
        }

        // Theme pack: background only status (pure read); import needs the try-on card.
        for name in IOSThemePackToolCatalog.toolNames where availableToolNames.contains(name) {
            executors[name] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                if !IOSThemePackToolCatalog.backgroundAllowedToolNames.contains(toolName) {
                    return .denied("主题试穿仅前台可用，请回到 App 确认后再试。")
                }
                let result = self.themePackToolService.execute(
                    toolName: toolName,
                    argumentsJSON: arguments
                )
                return .filled(result)
            }
        }

        // P3-a: exec 求值——后台 run 也能跑（每次求值独立队列/context，与
        // 前台生命周期无关）。只注册当前轮 params 可见的名字；开关关时声明侧
        // 零痕迹（params 不会含 exec），此处双重门控避免陈旧轮次执行。
        // P3-b: 后台 run 没有协调器级嵌套 runner（账本与审批卡都归前台
        // 协调器），所以 tools 对象按当轮可见集注入白名单、但每个嵌套调用都
        // 报 "tool not available in exec"——诚实拒绝而不是静默缺失。
        // P3-c: 后台 run 同样按会话注册 cell（conversationId 由 job 传入），
        // 前台 yield 的 cell 后台可以 wait，反之亦然——注册表跨 run/前后台共享。
        if availableToolNames.contains("exec") {
            // store 分支可见性：写入按真实 toolCallId 标记来源，可见集取 job 冻结
            // 的分支消息（本轮写入经 runId 始终可见），所以用携带 tool 的执行器。
            executors["exec"] = IOSToolCallClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] tool in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                guard self.effectiveExecJavaScriptEnabled else {
                    return .failed("exec 未开启。请先在设置中启用 JavaScript 执行工具。")
                }
                let whitelist = ChatToolRuntime.execNestedToolWhitelist(
                    visibleToolNames: availableToolNames
                )
                let nestedTools = IOSJsSandboxTools(
                    availableToolNames: whitelist.sorted(),
                    hostCall: { _, _ in nil },
                    // P3-d: 后台同样注入 ALL_TOOLS 发现元数据——描述来自同一轮
                    // params.tools 声明（与白名单同源）。嵌套调用仍诚实拒绝
                    // （hostCall nil → "tool not available in exec"），但脚本可以
                    // 用 ALL_TOOLS 发现工具名，避免在后续轮次猜名字。
                    toolDescriptions: Self.execToolDescriptions(
                        from: params.tools,
                        whitelist: whitelist
                    ),
                    toolSchemas: Self.execToolSchemas(from: params.tools, whitelist: whitelist)
                )
                return .filled(await self.dispatchExecToolCall(
                    tool,
                    nestedTools: nestedTools,
                    conversationId: conversationId,
                    storeScope: Self.execStoreScope(toolCall: tool, runId: runId, branchMessages: messages)
                ))
            }
        }
        // P3-c: wait 与 exec 同开关同池——后台 run 可 wait 本会话的 cell。
        if availableToolNames.contains("wait") {
            executors["wait"] = IOSClosureToolExecutor(executionPolicy: executionPolicy) { [weak self] toolName, arguments, _ in
                guard let self else { return .failed("Chat runtime is unavailable.") }
                guard self.effectiveExecJavaScriptEnabled else {
                    return .failed("wait 未开启。请先在设置中启用 JavaScript 执行工具。")
                }
                return .filled(await self.dispatchWaitToolCall(
                    self.toolCall(name: toolName, input: arguments),
                    conversationId: conversationId
                ))
            }
        }

        return executors
    }

    // MARK: - P0-2 B2: 前台内核执行器适配

    /// 审批卡暂存盒:引擎执行器回调(nonisolated 上下文)命中 `.waitingForApproval`
    /// 时按 toolCallId 登记 prompt;`ChatRunKernelAdapter` 在引擎返回
    /// `pendingApproval` 后取出、走 bindings 发布。审批请求类型未标 Sendable,
    /// 照 `IOSMailboxDrainResult` 先例用锁 + @unchecked Sendable 跨边界。
    final class IOSForegroundApprovalPromptBox: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String: ChatToolApprovalPrompt] = [:]

        func put(_ toolCallId: String, _ prompt: ChatToolApprovalPrompt) {
            lock.withLock { prompts[toolCallId] = prompt }
        }

        func take(_ toolCallId: String) -> ChatToolApprovalPrompt? {
            lock.withLock { prompts.removeValue(forKey: toolCallId) }
        }
    }

    /// 工具名 → 前台 kind 分类。与 `nextPendingToolCall` 的逐类扫描同源
    /// (各名字集互斥,单名分类与扫描序无关);实例级闸门保持一致:
    /// workspace/ish 需 localToolExecutor,webMount 需运行时开关,exec/wait
    /// 需 execJavaScriptEnabled。全部集合之外的名字返回 nil(= CGC 的
    /// 「未知名」档位,由调用方决定硬失败,不在此伪装成 advanced)。
    func pendingKindForForegroundTool(
        named name: String,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) -> ChatPendingToolKind? {
        if ["tool_search", "tools_list"].contains(name) { return .toolSearch }
        if IOSSearchExecutor.supportedToolNames.contains(name) { return .search }
        if localToolExecutor != nil {
            if IOSWorkspaceToolCatalog.supportedToolNames.contains(name) { return .workspace }
            if IOSAgentTerminalToolCatalog.supportedToolNames.contains(name) { return .ish }
        }
        if isWebMountRuntimeEnabled {
            let webMountNames = IOSWebMountToolCatalog.supportedToolNames
                .union(IOSWebMountToolCatalog.unsupportedToolNames)
            if webMountNames.contains(name) { return .webMount }
        }
        if name == "memory_tool" { return .memory }
        if name == "generate_image" { return .image }
        if name == "ask_user" { return .askUser }
        if ["session_search", "session_read", "history_search", "history_fetch"].contains(name) { return .sessionRead }
        if name == "runtime_status" { return .runtimeStatus }
        var advancedNames: Set<String> = Set([
            "mcp_call", "subagent_dispatch", "model_council_run",
            IOSSoulToolCatalog.toolName,
            "spawn_agent", "list_agents", "interrupt_agent",
            "send_message", "followup_task", "wait_agent",
        ])
        .union(IOSAppleAgentToolCatalog.toolNames)
        .union(IOSWakeToolCatalog.toolNames)
        .union(IOSShortcutAuthoringToolCatalog.toolNames)
        .union(IOSSkillToolCatalog.toolNames)
        .union(IOSMcpManagementToolCatalog.toolNames)
        .union(IOSProviderConfigToolCatalog.toolNames)
        .union(IOSThemePackToolCatalog.toolNames)
        .union(IOSRecipeToolCatalog.toolNames)
        .union(IOSPluginToolCatalog.toolNames)
        if IOSDynamicToolRegistry.isDynamicWorkflowToolName(name) { return .advanced }
        if executionPolicy?.execJavaScriptEnabled ?? effectiveExecJavaScriptEnabled {
            advancedNames.formUnion(["exec", "wait"])
        }
        if advancedNames.contains(name) || name.hasPrefix("mcp__") { return .advanced }
        return nil
    }

    /// 前台策略的内核执行器表:与 `backgroundToolExecutors` 同构,但走
    /// `execute(...)` 前台分发(kind 分发、审批卡、记忆污染置位全部沿用),
    /// `isUserInitiated` 由调用点语义决定。审批命中时 prompt 登记进
    /// `approvalPromptBox`(引擎的 `.needsApproval` 只有 reason 字符串,
    /// 审批卡对象经盒子交接),引擎随后以 `pendingApproval` 暂停,由
    /// `ChatRunKernelAdapter` 决定批准/拒绝并调用对应 finish*Approval。
    ///
    /// - parameter baseMessagesProvider: 执行器被引擎调用时取当前 run 的
    ///   工作消息,充当 `ChatPendingToolApproval.baseMessages`(回填锚点)。
    ///   适配器必须返回引擎当轮 working 的最新值。
    func foregroundToolExecutors(  // swiftlint:disable:this function_parameter_count
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        startedAt: Int64,
        inputDigest: String,
        conversationId: KotlinUuid?,
        toolExposureBridge: IosToolExposureBridge?,
        baseMessagesProvider: @escaping @MainActor @Sendable () -> [UIMessage],
        approvalPromptBox: IOSForegroundApprovalPromptBox,
        nestedToolRunner: IosExecNestedToolRunner? = nil,
        nestedOutcomeUnknownProvider: (@MainActor () -> IOSToolOutcomeUnknownSignal?)? = nil,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot? = nil,
        executionPolicy: IOSExecutionPolicySnapshot? = nil,
        phoneControl: IOSPhoneControlController? = nil
    ) -> [String: any IOSToolExecutor] {
        var executors: [String: any IOSToolExecutor] = [:]
        for tool in params.tools {
            let name = tool.name
            if IOSPhoneControlToolCatalog.isPhoneTool(name: name) {
                executors[name] = IOSPhoneControlToolExecutor(runID: runId, controller: phoneControl ?? .shared)
                continue
            }
            let kind = pendingKindForForegroundTool(named: name, executionPolicy: executionPolicy)
            guard let kind else { continue }
            executors[name] = IOSForegroundKernelToolExecutor(
                runtime: self,
                kind: kind,
                providerSetting: providerSetting,
                params: params,
                runId: runId,
                startedAt: startedAt,
                inputDigest: inputDigest,
                conversationId: conversationId,
                toolExposureBridge: toolExposureBridge,
                baseMessagesProvider: baseMessagesProvider,
                approvalPromptBox: approvalPromptBox,
                nestedToolRunner: nestedToolRunner,
                nestedOutcomeUnknownProvider: nestedOutcomeUnknownProvider,
                recipeCatalogSnapshot: recipeCatalogSnapshot,
                executionPolicy: executionPolicy
            )
        }
        return executors
    }

}

// MARK: - P0-2 B2: 前台内核执行器

/// 前台工具面的引擎执行器:把引擎的 (tool) 调用桥进 `ChatToolRuntime.execute`
/// 的 kind 分发——审批卡、记忆污染置位、回填格式化全部沿用前台实现,不复制
/// dispatch 逻辑。命中审批时 prompt 登记进盒子(引擎的 `.needsApproval` 只有
/// reason 字符串),`ChatRunKernelAdapter` 后续从盒子取出发布。
///
/// 三参 legacy 入口不被引擎调用(引擎优先 `execute(tool:)`);返回诚实失败,
/// 防止绕过 toolCallId 键控语义的直连。
///
/// @unchecked Sendable:引擎从 nonisolated 上下文调 `execute(tool:)`,随即
/// hop 到 MainActor 的 `dispatch`——跨域发送 self 是这次 hop 本身;全部
/// 存储属性 init 后不可变,且只在 MainActor 上读取。
private final class IOSForegroundKernelToolExecutor: IOSToolExecutor, @unchecked Sendable {
    private weak var runtime: ChatToolRuntime?
    private let kind: ChatPendingToolKind
    private let providerSetting: ProviderSetting
    private let params: TextGenerationParams
    private let runId: String
    private let startedAt: Int64
    private let inputDigest: String
    private let conversationId: KotlinUuid?
    private let toolExposureBridge: IosToolExposureBridge?
    private let baseMessagesProvider: @MainActor @Sendable () -> [UIMessage]
    private let approvalPromptBox: ChatToolRuntime.IOSForegroundApprovalPromptBox
    private let nestedToolRunner: IosExecNestedToolRunner?
    private let nestedOutcomeUnknownProvider: (@MainActor () -> IOSToolOutcomeUnknownSignal?)?
    private let recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?
    private let executionPolicy: IOSExecutionPolicySnapshot?

    init(
        runtime: ChatToolRuntime,
        kind: ChatPendingToolKind,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        startedAt: Int64,
        inputDigest: String,
        conversationId: KotlinUuid?,
        toolExposureBridge: IosToolExposureBridge?,
        baseMessagesProvider: @escaping @MainActor @Sendable () -> [UIMessage],
        approvalPromptBox: ChatToolRuntime.IOSForegroundApprovalPromptBox,
        nestedToolRunner: IosExecNestedToolRunner?,
        nestedOutcomeUnknownProvider: (@MainActor () -> IOSToolOutcomeUnknownSignal?)?,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot?,
        executionPolicy: IOSExecutionPolicySnapshot?
    ) {
        self.runtime = runtime
        self.kind = kind
        self.providerSetting = providerSetting
        self.params = params
        self.runId = runId
        self.startedAt = startedAt
        self.inputDigest = inputDigest
        self.conversationId = conversationId
        self.toolExposureBridge = toolExposureBridge
        self.baseMessagesProvider = baseMessagesProvider
        self.approvalPromptBox = approvalPromptBox
        self.nestedToolRunner = nestedToolRunner
        self.nestedOutcomeUnknownProvider = nestedOutcomeUnknownProvider
        self.recipeCatalogSnapshot = recipeCatalogSnapshot
        self.executionPolicy = executionPolicy
    }

    func execute(
        tool: UIMessagePart.Tool,
        isUserInitiated: Bool
    ) async -> IOSAgentToolOutcome {
        await dispatch(tool: tool)
    }

    func execute(
        name: String,
        arguments: String,
        isUserInitiated: Bool
    ) async -> IOSAgentToolOutcome {
        .failed("[engine] foreground kernel executor requires the tool-carrying execute(tool:) entry")
    }

    @MainActor
    private func dispatch(tool: UIMessagePart.Tool) async -> IOSAgentToolOutcome {
        guard let runtime else { return .failed("Chat runtime is unavailable.") }
        let context = ChatPendingToolApproval(
            toolCall: tool,
            providerSetting: providerSetting,
            params: params,
            runId: runId,
            startedAt: startedAt,
            inputDigest: inputDigest,
            conversationId: conversationId,
            baseMessages: baseMessagesProvider(),
            executionPolicy: executionPolicy
        )
        let result = await runtime.execute(
            ChatPendingToolCall(kind: kind, toolCall: tool),
            context: context,
            toolExposureBridge: toolExposureBridge,
            nestedToolRunner: nestedToolRunner,
            recipeCatalogSnapshot: recipeCatalogSnapshot
        )
        switch result {
        case .completed(let messages):
            // 引擎只认 output parts:从回填后的消息里按 toolCallId 提取。
            // 回填函数(messagesByFinishingToolCall)已把结构化结果写进
            // 该 part 的 output。
            for message in messages where message.role == MessageRole.assistant {
                for part in message.parts {
                    guard let toolPart = part as? UIMessagePart.Tool,
                          toolPart.toolCallId == tool.toolCallId else { continue }
                    guard !toolPart.output.isEmpty else {
                        return .failed("foreground tool produced no output")
                    }
                    if nestedOutcomeUnknownProvider?() != nil {
                        return .outcomeUnknown(toolPart.output)
                    }
                    return .filledParts(toolPart.output)
                }
            }
            return .failed("foreground tool output not found in completed messages")
        case .outcomeUnknown(let messages):
            for message in messages where message.role == MessageRole.assistant {
                for part in message.parts {
                    guard let toolPart = part as? UIMessagePart.Tool,
                          toolPart.toolCallId == tool.toolCallId else { continue }
                    return toolPart.output.isEmpty
                        ? .durabilityFailure("WebMount outcome-unknown output was not persisted in the transcript.")
                        : .outcomeUnknown(toolPart.output)
                }
            }
            return .durabilityFailure("WebMount outcome-unknown tool output was not found.")
        case .waitingForApproval(let prompt):
            approvalPromptBox.put(tool.toolCallId, prompt)
            return .needsApproval(prompt.toolTitle)
        case .durabilityFailure(let message):
            return .durabilityFailure(message)
        }
    }
}
