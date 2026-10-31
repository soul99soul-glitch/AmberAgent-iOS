import Foundation
@preconcurrency import Shared

@MainActor
extension ChatToolRuntime {
    func dispatchAdvancedToolCall(
        _ toolCall: UIMessagePart.Tool,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        conversationId: KotlinUuid? = nil,
        baseMessages: [UIMessage] = [],
        nestedTools: IOSJsSandboxTools? = nil,
        toolExposureBridge: IosToolExposureBridge? = nil,
        execStoreScope: IOSJsStoreScope? = nil
    ) async -> String {
        guard isAdvancedToolEnabled(toolCall.toolName) else {
            return IOSWorkspaceStore.json([
                "ok": false,
                "tool": toolCall.toolName,
                "status": "denied",
                "denied": true,
                "policy": "disabled",
                "reason": "\(toolCall.toolName) 未开启。请先在设置中启用对应能力。"
            ])
        }
        switch toolCall.toolName {
        case let name where IOSShortcutAuthoringToolCatalog.toolNames.contains(name):
            return await IOSShortcutAuthoringToolExecutor.execute(input: toolCall.input)
        case let name where IOSWakeToolCatalog.toolNames.contains(name):
            return await IOSWakeToolExecutor.execute(
                tool: toolCall,
                runID: runId,
                conversationID: conversationId?.toHexDashString(),
                messages: baseMessages,
                scheduler: wakeScheduler
            )
        case IOSWeatherToolCatalog.toolName:
            return await IOSWeatherToolExecutor.execute(input: toolCall.input)
        case IOSHealthAgentToolCatalog.toolName:
            return await IOSHealthAgentToolExecutor.execute(input: toolCall.input)
        case let name where IOSAppleAgentToolCatalog.eventKitToolNames.contains(name):
            return await IOSEventKitAgentToolExecutor.execute(toolName: name, input: toolCall.input)
        case let name where IOSAppleAgentToolCatalog.notificationToolNames.contains(name):
            return await IOSNotificationAgentToolExecutor.execute(toolName: name, input: toolCall.input)
        case let name where IOSAppleAgentToolCatalog.alarmToolNames.contains(name):
            return await IOSAlarmAgentToolExecutor.execute(toolName: name, input: toolCall.input)
        case let name where IOSAppleAgentToolCatalog.workoutToolNames.contains(name):
            return await IOSWorkoutAgentToolExecutor.execute(toolName: name, input: toolCall.input)
        case "subagent_dispatch":
            let args = ChatToolCallParsing.jsonObject(toolCall.input)
            let maxLegacySubAgents = min(10, max(1, sharedSettings.subAgentMaxConcurrentRuns))
            guard activeLegacySubAgentRuns < maxLegacySubAgents else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "并发运行数已达上限（\(maxLegacySubAgents) 个子代理）。",
                    status: "agent_limit_reached"
                )
            }
            activeLegacySubAgentRuns += 1
            defer { activeLegacySubAgentRuns -= 1 }
            let customRolePrompt = args?["custom_role_prompt"] as? String
            let isCustomRole = customRolePrompt?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            if !sharedSettings.allowsDynamicSubAgents, isCustomRole {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName, reason: "动态子代理开关已关闭，请使用已配置的内置角色。"
                )
            }
            let objective = args?["objective"] as? String ?? toolCall.input
            let roleId = args?["role_id"] as? String ?? args?["subagent_id"] as? String ?? "explorer"
            let scope = ChatToolCallParsing.stringArray(args?["tool_scope"])
                ?? ChatToolCallParsing.stringArray(args?["tools"])
                ?? []
            let settingsSnapshot = sharedSettings.snapshot
            let roleOverride = settingsSnapshot.agentRuntime.subAgent.overrides[roleId]
            let expandedMcpDeclarations = expandedMcpToolDeclarations(mcpManager: mcpManager)
            let expandedMcpNames = Set(expandedMcpDeclarations.map(\.name))
            let roleDefaultToolNames = IOSSubAgentRoleCatalog.defaultToolNames(
                roleId: roleId,
                availableToolNames: ToolKt.iosToolDeclarationNames() + expandedMcpDeclarations.map(\.name),
                mcpServers: mcpManager.servers
            )
            let requestedMcpNames = Set(scope.filter { expandedMcpNames.contains($0) })
            let allowedMcpNames: Set<String>
            if isCustomRole {
                // A one-off role gets MCP only when this invocation names the
                // currently enabled/discovered tool explicitly.
                allowedMcpNames = requestedMcpNames
            } else if let configuredToolNames = roleOverride?.toolAllowlist {
                // A saved built-in allowlist is the upper bound for task-level
                // scope; an explicit task scope cannot grant another MCP tool.
                allowedMcpNames = Set(configuredToolNames).intersection(expandedMcpNames)
            } else {
                allowedMcpNames = Set(roleDefaultToolNames).intersection(expandedMcpNames)
            }
            let mcpDeclarations = expandedMcpDeclarations.filter { allowedMcpNames.contains($0.name) }
            var effectiveToolAllowlistOverride = roleOverride?.toolAllowlist.map { Array($0) }
            if isCustomRole, !requestedMcpNames.isEmpty {
                effectiveToolAllowlistOverride = Array(
                    IOSSubAgentToolPolicy.readOnlyParentToolNames.union(requestedMcpNames)
                )
            } else if !isCustomRole, roleOverride?.toolAllowlist == nil, !allowedMcpNames.isEmpty {
                effectiveToolAllowlistOverride = roleDefaultToolNames
            }
            let skillContext: String?
            if let defaultSkillNames = roleOverride?.defaultSkillNames, !defaultSkillNames.isEmpty {
                do {
                    skillContext = try IOSSkillMcpToolService.loadEnabledSkillContext(
                        skillNames: defaultSkillNames,
                        enabledSkillNames: sharedSettings.currentAssistantEnabledSkillNames
                    )
                } catch {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName,
                        reason: "子代理默认技能不可用：\(error.localizedDescription)"
                    )
                }
            } else {
                skillContext = nil
            }
            let poolCandidates = subAgentModelPool.candidates(
                settings: settingsSnapshot,
                sharedSettings: sharedSettings
            )
            let explicitModelId = (args?["model_id"] as? String).flatMap { raw -> String? in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            let explicitReasoningRaw = (args?["reasoning_level"] as? String).flatMap { raw -> String? in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            let selectedPoolCandidate: IOSSubAgentModelPool.Candidate?
            if let explicitModelId {
                guard let parsed = Self.parseSubAgentModelUUID(explicitModelId),
                      let candidate = subAgentModelPool.candidate(
                        for: parsed.toHexDashString(),
                        from: poolCandidates
                      ) else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName,
                        reason: "显式 model_id 必须是当前用户模型池中的可用模型：\(explicitModelId)"
                    )
                }
                selectedPoolCandidate = candidate
            } else if roleOverride?.modelId == nil, !poolCandidates.isEmpty {
                selectedPoolCandidate = subAgentModelPool.select(
                    from: poolCandidates,
                    activeModelCounts: activeLegacyModelCounts,
                    activeProviderCounts: activeLegacyProviderCounts
                )
            } else if roleOverride?.modelId == nil,
                      settingsSnapshot.agentRuntime.subAgent.modelPool.isEmpty == false {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "模型池中的模型均已停用、移除或配置不可用。"
                )
            } else {
                selectedPoolCandidate = nil
            }
            let selectedModel = selectedPoolCandidate?.model
                ?? roleOverride?.modelId.flatMap { settingsSnapshot.findModelById(uuid: $0) }
            let selectedProvider = selectedPoolCandidate?.provider ?? selectedModel.flatMap {
                ChatProviderConfiguration.provider(for: $0, providers: settingsSnapshot.providers)
            }
            if roleOverride?.modelId != nil, selectedPoolCandidate == nil {
                guard let selectedModel else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName, reason: "子代理配置的模型已不存在，请重新选择模型。"
                    )
                }
                if let issue = ChatProviderConfiguration.issue(for: selectedModel, provider: selectedProvider) {
                    return ChatToolOutputFormatter.toolFailureJSON(toolName: toolCall.toolName, reason: issue.message)
                }
            }
            let effectiveReasoningOverride: ReasoningLevel?
            if let explicitReasoningRaw {
                guard let parsed = Self.reasoningLevel(named: explicitReasoningRaw) else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName,
                        reason: "reasoning_level 无效：\(explicitReasoningRaw)"
                    )
                }
                let reasoningModelId = selectedModel?.id.toHexDashString() ?? params.model.id.toHexDashString()
                let supported = sharedSettings.subAgentReasoningLevels(modelId: reasoningModelId)
                guard supported.contains(parsed) else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolCall.toolName,
                        reason: "模型不支持 reasoning_level=\(explicitReasoningRaw)。"
                    )
                }
                effectiveReasoningOverride = parsed
            } else if let selectedPoolCandidate {
                effectiveReasoningOverride = selectedPoolCandidate.configuredReasoning
                    .flatMap { selectedPoolCandidate.supportedReasoning.contains($0) ? $0 : nil }
                    ?? subAgentModelPool.defaultReasoning(for: selectedPoolCandidate)
            } else {
                effectiveReasoningOverride = roleOverride?.reasoningLevel
            }
            let runParams: TextGenerationParams
            if let selectedModel, let selectedProvider,
               selectedModel.id != params.model.id || effectiveReasoningOverride != nil {
                let assistant = settingsSnapshot.getCurrentAssistant()
                runParams = TextGenerationParams(
                    model: selectedModel,
                    temperature: params.temperature,
                    topP: params.topP,
                    maxTokens: params.maxTokens,
                    tools: params.tools,
                    reasoningLevel: effectiveReasoningOverride ?? params.reasoningLevel,
                    customHeaders: IOSProviderRequestHeaderStore.headers(for: selectedProvider.id.description())
                        + assistant.customHeaders + selectedModel.customHeaders,
                    customBody: assistant.customBodies + selectedModel.customBodies
                )
            } else {
                runParams = params
            }
            let modelReservation = selectedPoolCandidate.map { subAgentModelPool.reserve($0) }
            if let selectedPoolCandidate {
                activeLegacyModelCounts[selectedPoolCandidate.modelId, default: 0] += 1
                activeLegacyProviderCounts[selectedPoolCandidate.providerId, default: 0] += 1
            }
            defer {
                subAgentModelPool.release(modelReservation)
                if let selectedPoolCandidate {
                    decrementLegacyCount(&activeLegacyModelCounts, key: selectedPoolCandidate.modelId)
                    decrementLegacyCount(&activeLegacyProviderCounts, key: selectedPoolCandidate.providerId)
                }
            }
            let globalTimeoutSeconds = min(
                3_600,
                max(1, Double(settingsSnapshot.agentRuntime.subAgent.timeoutMs) / 1_000)
            )
            let roleTimeoutSeconds = roleOverride?.timeoutMsOverride.map {
                min(3_600, max(1, Double(truncating: $0) / 1_000))
            } ?? TimeInterval(IOSSubAgentRoleCatalog.resolve(roleId: roleId)?.timeoutSeconds ?? 300)
            let timeoutSeconds = min(globalTimeoutSeconds, roleTimeoutSeconds)
            return await subAgentRunner.runViaEngine(
                objective: objective,
                roleId: roleId,
                requestedToolScope: scope,
                customRoleName: args?["custom_role_name"] as? String,
                customRoleLens: args?["custom_role_lens"] as? String,
                customRolePrompt: customRolePrompt,
                skillContext: skillContext,
                savedRolePromptOverride: roleOverride?.systemPrompt,
                toolAllowlistOverride: effectiveToolAllowlistOverride,
                maxTurnsOverride: (args?["max_turns"] as? Int)
                    ?? roleOverride?.maxTurnsOverride.map { Int(truncating: $0) },
                outputBudgetCharsOverride: (args?["output_budget_chars"] as? Int)
                    ?? roleOverride?.outputBudgetOverride.map { Int(truncating: $0) },
                providerSetting: selectedProvider ?? providerSetting,
                modelId: selectedModel?.modelId ?? params.model.modelId,
                baseParams: runParams,
                modelOverride: selectedModel,
                temperatureOverride: roleOverride?.temperature.map { Float(truncating: $0) },
                reasoningLevelOverride: effectiveReasoningOverride,
                additionalToolDeclarations: mcpDeclarations,
                parentToolExecutors: subAgentParentToolExecutors(
                    runId: runId,
                    conversationId: conversationId?.description() ?? "",
                    additionalToolNames: Set(mcpDeclarations.map(\.name))
                ),
                toolCallId: toolCall.toolCallId,
                sourceConversationId: conversationId?.toHexDashString(),
                timeoutSeconds: timeoutSeconds
            )
        case "model_council_run":
            let args = ChatToolCallParsing.jsonObject(toolCall.input)
            let objective = args?["objective"] as? String ?? toolCall.input
            let maxSeats = args?["max_seats"] as? Int
            return await councilRunner.run(
                objective: objective,
                maxSeats: maxSeats,
                providerSetting: providerSetting,
                currentModel: params.model,
                baseParams: params,
                toolCallId: toolCall.toolCallId
            )
        case let name where isMcpCallTool(name):
            return await dispatchMcpToolOutput(toolCall).text
        case let name where IOSSkillToolCatalog.toolNames.contains(name)
            || IOSMcpManagementToolCatalog.toolNames.contains(name):
            return await skillMcpToolService.execute(
                toolName: name,
                arguments: toolCall.input,
                mcpEnabledOverride: isMcpNetworkAllowed()
            )
        case let name where IOSRecipeToolCatalog.toolNames.contains(name) && name != "recipe_import":
            return await recipeToolService.execute(toolName: name, arguments: toolCall.input)
        case let name where IOSPluginToolCatalog.toolNames.contains(name) && name != "plugin_import":
            return await pluginToolService.execute(toolName: name, arguments: toolCall.input)
        case "recipe_import":
            // Host-publish apply lives in executeAdvancedToolCall / background
            // host-publish; this dispatch table must not silently import.
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "Recipe 导入需要查看候选变更并显式批准。",
                status: "failed"
            )
        case "plugin_import":
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "插件导入需要查看候选能力并显式批准。",
                status: "failed"
            )
        case "spawn_agent", "list_agents", "interrupt_agent", "send_message", "followup_task", "wait_agent":
            // P1-c/P1-d: 线程编排工具走独立服务（会话 fork / edge / mailbox / 子 run
            // 启动与取消全部收口在服务内；未注入时诚实报错而非静默缺失）。
            // conversationId = run 锚定会话（前台由 pending/conversationId 透传，
            // 后台由 job 透传）——生成中切会话不会建错边或误拒。
            guard let orchestrationToolService else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "线程编排工具当前不可用。",
                    status: "failed"
                )
            }
            return await orchestrationToolService.execute(
                toolName: toolCall.toolName,
                arguments: toolCall.input,
                providerSetting: providerSetting,
                params: params,
                runId: runId,
                conversationId: conversationId,
                // M3: 子 run 的 fullToolNames 取 run 桥全目录（spawn/followup
                // 不被当轮可见子集截断）；nil 时服务回退 params.tools。
                toolExposureBridge: toolExposureBridge,
                executionPolicy: IOSExecutionPolicyContext.snapshot
            )
        case let name where IOSProviderConfigToolCatalog.toolNames.contains(name):
            return await providerConfigToolService.execute(
                toolName: name,
                argumentsJSON: toolCall.input
            )
        case let name where IOSThemePackToolCatalog.toolNames.contains(name):
            return themePackToolService.execute(
                toolName: name,
                argumentsJSON: toolCall.input
            )
        case let name where IOSSSHProfileToolCatalog.toolNames.contains(name):
            return IOSSSHProfileToolExecutor.execute(
                toolName: name,
                argumentsJSON: toolCall.input,
                settingsStore: settingsStore
            )
        case let name where IOSSSHKeyToolCatalog.toolNames.contains(name):
            return IOSSSHKeyToolExecutor.execute(
                toolName: name,
                argumentsJSON: toolCall.input,
                settingsStore: settingsStore
            )
        case "exec":
            guard effectiveExecJavaScriptEnabled else {
                return IOSWorkspaceStore.json([
                    "ok": false,
                    "tool": toolCall.toolName,
                    "status": "denied",
                    "denied": true,
                    "policy": "disabled",
                    "reason": "\(toolCall.toolName) 未开启。请先在设置中启用对应能力。"
                ])
            }
            // P3-b: exec 求值可带嵌套 tools 桥（白名单 + 宿主 runner 由
            // executeAdvancedToolCall 传入；nil = 纯求值，同 P3-a）。
            // P3-c: conversationId = 会话作用域键（cell 注册表 + store/load）。
            return await dispatchExecToolCall(
                toolCall,
                nestedTools: nestedTools,
                conversationId: conversationId,
                storeScope: execStoreScope
            )
        case "wait":
            guard effectiveExecJavaScriptEnabled else {
                return IOSWorkspaceStore.json([
                    "ok": false,
                    "tool": toolCall.toolName,
                    "status": "denied",
                    "denied": true,
                    "policy": "disabled",
                    "reason": "\(toolCall.toolName) 未开启。请先在设置中启用对应能力。"
                ])
            }
            // P3-c: 续取本会话的 exec cell（yield/wait/terminate 三路径）。
            return await dispatchWaitToolCall(toolCall, conversationId: conversationId)
        default:
            return "未知工具：\(toolCall.toolName)"
        }
    }

    /// P3-c: wait timeout clamp (declaration contract: [1000, 60000], default 10000).
    private func subAgentParentToolExecutors(
        runId: String,
        conversationId: String,
        additionalToolNames: Set<String> = []
    ) -> [String: any IOSToolExecutor] {
        // Browser-capable roles opt into this second set. The LocalToolExecutor
        // still applies the normal WebMount permission and session-binding
        // checks; registering the adapter only makes the selected names
        // executable when that parent gate allows them.
        let allowedNames = IOSSubAgentToolPolicy.readOnlyParentToolNames
            .union(IOSSubAgentToolPolicy.browserAutomationToolNames)
            .union(additionalToolNames)
        return Dictionary(uniqueKeysWithValues: allowedNames.map { name in
            (name, IOSClosureToolExecutor { [weak self] toolName, arguments, _ in
                guard let self else {
                    return .failed("Chat runtime is unavailable.")
                }
                return await self.executeSubAgentParentTool(
                    name: toolName,
                    arguments: arguments,
                    runId: runId,
                    conversationId: conversationId
                )
            } as any IOSToolExecutor)
        })
    }

    private func executeSubAgentParentTool(
        name: String,
        arguments: String,
        runId: String,
        conversationId: String
    ) async -> IOSAgentToolOutcome {
        guard IOSSubAgentToolPolicy.readOnlyParentToolNames.contains(name)
            || IOSSubAgentToolPolicy.browserAutomationToolNames.contains(name)
            || ToolKt.isExpandedMcpToolName(name: name) else {
            return .denied("SubAgent parent scope does not allow \(name).")
        }

        if IOSSearchExecutor.supportedToolNames.contains(name) {
            switch searchToolPermission() {
            case .denied(let reason): return .denied(reason)
            case .needsApproval(let reason): return .needsApproval(reason)
            case .allow: break
            }
            let output = await dispatchSearchToolCall(toolCall(name: name, input: arguments))
            recordSubAgentParentToolApproval(
                toolName: name,
                arguments: arguments,
                action: .allowed,
                runId: runId
            )
            return .filled(output)
        }

        // runtime_status：本地自省只读，不经 localToolExecutor（无 capability
        // 映射）；子代理 catalog 无桥上下文，传 nil 只省略目录计数。
        if name == "runtime_status" {
            return .filled(dispatchRuntimeStatusToolCall(
                toolCall(name: name, input: arguments),
                toolExposureBridge: nil
            ))
        }

        if ToolKt.isExpandedMcpToolName(name: name) {
            guard let target = resolvedMcpTarget(forExpandedName: name),
                  let mcpArguments = ChatToolCallParsing.jsonObject(arguments) else {
                return .failed("MCP tool \(name) is unavailable or its arguments are not a JSON object.")
            }
            guard let discovered = mcpManager.tools.first(where: {
                $0.serverName == target.server
                    && $0.tool.name == target.tool
            }) else {
                return .failed("MCP tool \(name) is no longer in the current discovery directory.")
            }
            // Read-only MCP tools can run under the parent network gate. A
            // tool without a read-only hint is treated as high-risk and can
            // run only when the same high-risk auto-approval already used by
            // foreground mcp_call is active.
            guard discovered.tool.readOnlyHint == true || effectiveHighRiskAutoApproveEnabled else {
                return .denied("MCP tool \(name) is not marked read-only; enable high-risk auto-approval or run it in the foreground.")
            }
            do {
                let output = try await mcpManager.callTool(
                    serverName: target.server,
                    toolName: target.tool,
                    arguments: mcpArguments,
                    enabledOverride: isMcpNetworkAllowed()
                )
                recordSubAgentParentToolApproval(
                    toolName: name,
                    arguments: arguments,
                    action: .allowed,
                    runId: runId
                )
                return .filled(output)
            } catch {
                recordSubAgentParentToolApproval(
                    toolName: name,
                    arguments: arguments,
                    action: .denied,
                    runId: runId
                )
                return .failed("MCP 调用失败（server: \(target.server)，tool: \(target.tool)）：\(error.localizedDescription)")
            }
        }

        guard let localToolExecutor else {
            return .failed("Local iOS tool executor is unavailable.")
        }

        let request = localToolExecutor.executionRequest(
            toolName: name,
            operation: arguments,
            isUserInitiated: name == "file_read_selected",
            runId: runId,
            conversationId: conversationId,
            executionPolicy: IOSExecutionPolicyContext.snapshot
        )
        let output = await localToolExecutor.execute(request)
        recordSubAgentParentToolApproval(
            toolName: name,
            arguments: arguments,
            action: output.isSuccessfulToolResult ? .allowed : .denied,
            runId: runId,
            request: request
        )
        return ChatToolOutputFormatter.subAgentOutcome(for: name, output: output)
    }

    private func recordSubAgentParentToolApproval(
        toolName: String,
        arguments: String,
        action: IOSToolApprovalAction,
        runId: String,
        request: IOSLocalToolExecutionRequest? = nil
    ) {
        guard let localToolExecutor,
              let capability = IOSCapabilityRegistry.capability(forToolName: toolName) else { return }
        let auditRequest = request ?? localToolExecutor.executionRequest(
            toolName: toolName,
            operation: arguments,
            isUserInitiated: false,
            runId: runId,
            executionPolicy: IOSExecutionPolicyContext.snapshot
        )
        localToolExecutor.recordApproval(
            capabilityId: capability.id,
            toolName: toolName,
            action: action,
            reason: "SubAgent read-only parent tool \(action == .allowed ? "executed" : "denied").",
            runId: runId,
            scopeDigest: auditRequest.scopeDigest,
            payloadDigest: auditRequest.payloadDigest,
            policyDigest: auditRequest.executionPolicy?.digest
        )
    }

    private static func parseSubAgentModelUUID(_ value: String) -> KotlinUuid? {
        let normalized = value.lowercased()
        guard UUID(uuidString: normalized) != nil else { return nil }
        return KotlinUuid.companion.parse(uuidString: normalized)
    }

    private static func reasoningLevel(named raw: String) -> ReasoningLevel? {
        switch raw.lowercased() {
        case "off": return .off
        case "auto": return .auto_
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        case "xhigh": return .xhigh
        case "max": return .max
        default: return nil
        }
    }

    private func decrementLegacyCount(_ values: inout [String: Int], key: String) {
        guard let count = values[key] else { return }
        if count <= 1 {
            values.removeValue(forKey: key)
        } else {
            values[key] = count - 1
        }
    }

    static func isHostPublishTool(_ toolName: String) -> Bool {
        toolName == IOSSoulToolCatalog.toolName
            || toolName == "skill_import"
            || toolName == "mcp_import_from_skill"
            || toolName == "recipe_import"
    }

    /// Soul / Skill / MCP / Recipe 导入：普通自动批准仍弹卡；高风险自动批准
    /// 走与前台相同的 prepare → CAS apply。Disabled MCP 仍由 apply 内复核拦下。
    func backgroundHostPublishOutcome(
        toolName: String,
        arguments: String
    ) async -> IOSAgentToolOutcome {
        guard effectiveHighRiskAutoApproveEnabled else {
            return .denied("后台生成期间需要回到 App 确认 \(toolName)。")
        }
        do {
            switch toolName {
            case IOSSoulToolCatalog.toolName:
                return .filled(try soulService.applyPreparedImport(try soulService.prepareImport()))
            case "skill_import":
                return .filled(try skillMcpToolService.applyPreparedSkillImport(
                    try skillMcpToolService.prepareSkillImport(arguments: arguments)
                ))
            case "mcp_import_from_skill":
                let prepared = try skillMcpToolService.prepareMcpImport(arguments: arguments)
                return .filled(await skillMcpToolService.applyPreparedMcpImport(prepared) { [weak self] in
                    self?.isMcpNetworkAllowed() ?? false
                })
            case "recipe_import":
                return .filled(try await recipeToolService.applyPreparedRecipeImport(
                    try recipeToolService.prepareRecipeImport(arguments: arguments)
                ))
            default:
                return .failed("未知发布工具：\(toolName)")
            }
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

}
