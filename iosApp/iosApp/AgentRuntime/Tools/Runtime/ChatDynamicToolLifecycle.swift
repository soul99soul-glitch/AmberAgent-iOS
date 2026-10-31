import Foundation
@preconcurrency import Shared

@MainActor
extension ChatToolRuntime {
    func executeAdvancedToolCall(
        _ pending: ChatPendingToolApproval,
        nestedTools: IOSJsSandboxTools? = nil,
        toolExposureBridge: IosToolExposureBridge? = nil,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot? = nil
    ) async -> ChatToolRuntimeResult {
        await dynamicToolLifecycle.execute(
            pending, nestedTools: nestedTools,
            toolExposureBridge: toolExposureBridge,
            recipeCatalogSnapshot: recipeCatalogSnapshot
        )
    }
}

@MainActor
final class ChatDynamicToolLifecycle {
    unowned let runtime: ChatToolRuntime
    let sshArguments = IOSPendingSSHArguments()
    private var preparedSkillImportsForApproval: [String: IOSPreparedSkillImport] = [:]
    private var preparedSoulImportsForApproval: [String: IOSPreparedSoulImport] = [:]
    private var preparedMcpImportsForApproval: [String: IOSPreparedMcpImport] = [:]

    init(runtime: ChatToolRuntime) { self.runtime = runtime }

    func takePreparedSkillImport(toolCallId: String) -> IOSPreparedSkillImport? {
        preparedSkillImportsForApproval.removeValue(forKey: toolCallId)
    }

    func takePreparedSoulImport(toolCallId: String) -> IOSPreparedSoulImport? {
        preparedSoulImportsForApproval.removeValue(forKey: toolCallId)
    }

    func takePreparedMcpImport(toolCallId: String) -> IOSPreparedMcpImport? {
        preparedMcpImportsForApproval.removeValue(forKey: toolCallId)
    }

    func discardPreparedImports(toolCallId: String) {
        preparedSkillImportsForApproval.removeValue(forKey: toolCallId)
        preparedSoulImportsForApproval.removeValue(forKey: toolCallId)
        preparedMcpImportsForApproval.removeValue(forKey: toolCallId)
    }


    func execute(
        _ pending: ChatPendingToolApproval,
        nestedTools: IOSJsSandboxTools? = nil,
        toolExposureBridge: IosToolExposureBridge? = nil,
        recipeCatalogSnapshot: IOSDynamicToolCatalogSnapshot? = nil
    ) async -> ChatToolRuntimeResult {
        let toolName = pending.toolCall.toolName

        if IOSAppleAgentToolCatalog.pickerToolNames.contains(toolName) {
            guard runtime.isAdvancedToolEnabled(toolName) else {
                let output = IOSWorkspaceStore.json([
                    "ok": false,
                    "tool": toolName,
                    "status": "denied",
                    "denied": true,
                    "policy": "disabled",
                    "reason": "\(toolName) 未开启。请先在设置中启用对应能力。"
                ])
                return .completed(runtime.messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: output,
                    in: pending.baseMessages
                ))
            }
            let result = await IOSPersonalContextPickerCoordinator.shared.requestResult(
                toolName: toolName,
                input: pending.toolCall.input
            )
            return .completed(runtime.messagesByFinishingToolCall(
                pending.toolCall,
                outputParts: result.messageParts,
                in: pending.baseMessages
            ))
        }

        if IOSAppleAgentToolCatalog.approvalRequiredToolNames.contains(toolName),
           let request = ChatToolApprovalRequestBuilder.appleCapability(
               for: pending.toolCall,
               reason: runtime.recipeExecution.appleCapabilityApprovalReason(toolName: toolName)
           ) {
            return .waitingForApproval(.mcp(request))
        }

        // Wave B2: `recipe__*` 通用前缀路由（§13.2.5 / §16.1）——镜像 mcp__*
        // 模式，单一路由不为每个 recipe 写分支。manifest 从「当前 round 的
        // registry snapshot」解析（in-flight pinning，不用 live store）；
        // snapshot 无此 recipe → 结构化错误（不崩、不静默）。mutation step
        // 走现有审批（invariant 11），在这里与 skill_import 同层拦截。
        if IOSDynamicToolRegistry.isDynamicWorkflowToolName(toolName) {
            guard let descriptor = recipeCatalogSnapshot?.recipeTools.first(where: { $0.toolId == toolName }) else {
                return .completed(runtime.messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: "此动态工具不在当前目录中；请先调用 tool_search 获取最新工具。",
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
            switch descriptor.implementation {
            case .recipe:
                return await runtime.recipeExecution.executeRecipeToolCall(
                    pending,
                    snapshot: recipeCatalogSnapshot,
                    bridge: toolExposureBridge
                )
            case .javascript, .remote, .command:
                return await runtime.pluginExecution.executePluginToolCall(
                    pending,
                    descriptor: descriptor,
                    bridge: toolExposureBridge
                )
            }
        }

        if toolName == IOSSoulToolCatalog.toolName {
            preparedSoulImportsForApproval.removeValue(forKey: pending.toolCall.toolCallId)
            do {
                let prepared = try runtime.soulService.prepareImport()
                guard let request = ChatToolApprovalRequestBuilder.extensionMutation(
                    for: pending.toolCall,
                    reason: "请核对 /workspace/SOUL.md 的核心指令变更；批准后会复核当前版本与候选 hash。",
                    soulImportPreview: SoulImportPreview(
                        baseHash: prepared.preview.baseHash,
                        candidateHash: prepared.preview.candidateHash,
                        changedLineCount: prepared.preview.changedLineCount,
                        diffPreview: prepared.preview.diffPreview,
                        afterSummary: prepared.preview.afterSummary
                    )
                ) else {
                    return .completed(runtime.messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: ChatToolOutputFormatter.toolFailureJSON(
                            toolName: toolName,
                            reason: "无法构造核心指令审批请求。",
                            status: "failed"
                        ),
                        in: pending.baseMessages
                    ))
                }
                if runtime.effectiveHighRiskAutoApproveEnabled {
                    let resultText = try runtime.soulService.applyPreparedImport(prepared)
                    return .completed(runtime.messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: resultText,
                        in: pending.baseMessages
                    ))
                }
                preparedSoulImportsForApproval[pending.toolCall.toolCallId] = prepared
                return .waitingForApproval(.mcp(request))
            } catch {
                return .completed(runtime.messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        if toolName == "mcp_import_from_skill" {
            preparedMcpImportsForApproval.removeValue(forKey: pending.toolCall.toolCallId)
            do {
                let prepared = try runtime.skillMcpToolService.prepareMcpImport(arguments: pending.toolCall.input)
                guard let request = ChatToolApprovalRequestBuilder.extensionMutation(
                    for: pending.toolCall,
                    reason: "请核对将导入的 MCP 服务；批准后会复核 digest、临时连通测试，再一次写入。",
                    mcpImportPreview: prepared.preview
                ) else {
                    return .completed(runtime.messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: ChatToolOutputFormatter.toolFailureJSON(
                            toolName: toolName,
                            reason: "无法构造 MCP 导入审批请求。",
                            status: "failed"
                        ),
                        in: pending.baseMessages
                    ))
                }
                if runtime.effectiveHighRiskAutoApproveEnabled {
                    let resultText = await runtime.skillMcpToolService.applyPreparedMcpImport(prepared) { [weak self] in
                        self?.runtime.isMcpNetworkAllowed() ?? false
                    }
                    return .completed(runtime.messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: resultText,
                        in: pending.baseMessages,
                        conversationId: pending.conversationId
                    ))
                }
                preparedMcpImportsForApproval[pending.toolCall.toolCallId] = prepared
                return .waitingForApproval(.mcp(request))
            } catch {
                return .completed(runtime.messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        // Provider 配置写入：高风险自动批准开启时沿用同一安全写入服务并跳过逐次审批。
        if IOSProviderConfigToolCatalog.highRiskToolNames.contains(toolName) {
            if runtime.effectiveHighRiskAutoApproveEnabled {
                let resultText = await runtime.providerConfigToolService.execute(
                    toolName: toolName,
                    argumentsJSON: pending.toolCall.input
                )
                return .completed(runtime.messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: resultText,
                    in: pending.baseMessages,
                    conversationId: pending.conversationId
                ))
            }
            let request = McpToolApprovalRequest(
                id: ChatToolCallParsing.requestId(for: pending.toolCall),
                serverName: "local",
                toolName: toolName,
                argumentsPreview: IOSProviderConfigToolCatalog.redactedApprovalPreview(
                    argumentsJSON: pending.toolCall.input
                ),
                reason: IOSProviderConfigToolCatalog.approvalReason(
                    argumentsJSON: pending.toolCall.input
                )
            )
            return .waitingForApproval(.mcp(request))
        }

        // SSH profile/key writes share one high-risk gate and one pending-secret lifetime.
        let isSSHKeyWrite = IOSSSHKeyToolCatalog.highRiskToolNames.contains(toolName)
        if isSSHKeyWrite || IOSSSHProfileToolCatalog.highRiskToolNames.contains(toolName) {
            if runtime.effectiveHighRiskAutoApproveEnabled {
                let resultText = isSSHKeyWrite
                    ? IOSSSHKeyToolExecutor.execute(toolName: toolName, argumentsJSON: pending.toolCall.input, settingsStore: runtime.settingsStore)
                    : IOSSSHProfileToolExecutor.execute(toolName: toolName, argumentsJSON: pending.toolCall.input, settingsStore: runtime.settingsStore)
                return .completed(runtime.messagesByFinishingToolCall(
                    pending.toolCall, outputText: resultText, in: pending.baseMessages,
                    conversationId: pending.conversationId
                ))
            }
            sshArguments.stage(runId: pending.runId, toolCallId: pending.toolCall.toolCallId, arguments: pending.toolCall.input)
            let preview = isSSHKeyWrite
                ? IOSSSHKeyToolCatalog.approvalPreview(toolName: toolName, argumentsJSON: pending.toolCall.input, store: runtime.settingsStore)
                : IOSSSHProfileToolCatalog.approvalPreview(toolName: toolName, argumentsJSON: pending.toolCall.input, store: runtime.settingsStore)
            let reason = isSSHKeyWrite
                ? IOSSSHKeyToolCatalog.approvalReason(toolName: toolName)
                : IOSSSHProfileToolCatalog.approvalReason(toolName: toolName)
            return .waitingForApproval(.mcp(McpToolApprovalRequest(
                id: ChatToolCallParsing.requestId(for: pending.toolCall), serverName: "local",
                toolName: toolName, argumentsPreview: preview, reason: reason
            )))
        }

        // Theme pack import: try-on immediately, always show 套用/还原 (never skip the card).
        if toolName == "theme_pack_import" {
            do {
                let document = try runtime.themePackToolService.prepareImport(
                    argumentsJSON: pending.toolCall.input,
                    approval: AmberThemeTryOnApproval(
                        runId: pending.runId,
                        requestId: ChatToolCallParsing.requestId(for: pending.toolCall)
                    )
                )
                let request = McpToolApprovalRequest(
                    id: ChatToolCallParsing.requestId(for: pending.toolCall),
                    serverName: "local",
                    toolName: toolName,
                    argumentsPreview: IOSThemePackToolCatalog.argumentsPreview(for: document),
                    reason: IOSThemePackToolCatalog.approvalReason(
                        displayName: document.displayName,
                        replacesInstalled: AmberThemePackLibrary.shared.contains(id: document.id)
                    ),
                    themePackPreview: document
                )
                return .waitingForApproval(.mcp(request))
            } catch {
                return .completed(runtime.messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        if runtime.isMcpNetworkTool(toolName), !runtime.isMcpNetworkAllowed() {
            return .completed(runtime.messagesByFinishingToolCall(
                pending.toolCall,
                outputText: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolName,
                    reason: "MCP 调用已关闭。",
                    status: "denied"
                ),
                in: pending.baseMessages
            ))
        }

        if toolName == "skill_import" {
            preparedSkillImportsForApproval.removeValue(forKey: pending.toolCall.toolCallId)
            do {
                let prepared = try runtime.skillMcpToolService.prepareSkillImport(
                    arguments: pending.toolCall.input
                )
                guard let request = ChatToolApprovalRequestBuilder.extensionMutation(
                    for: pending.toolCall,
                    reason: "请核对候选 Skill 的文件变更；批准后会复核 CAS 并原子替换技能包。",
                    skillImportPreview: ChatToolRuntime.mcpSkillImportPreview(from: prepared.preview)
                ) else {
                    return .completed(runtime.messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: ChatToolOutputFormatter.toolFailureJSON(
                            toolName: toolName,
                            reason: "无法构造 Skill 导入审批请求。",
                            status: "failed"
                        ),
                        in: pending.baseMessages
                    ))
                }
                if runtime.effectiveHighRiskAutoApproveEnabled {
                    let resultText = try runtime.skillMcpToolService.applyPreparedSkillImport(prepared)
                    return .completed(runtime.messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: resultText,
                        in: pending.baseMessages
                    ))
                }
                preparedSkillImportsForApproval[pending.toolCall.toolCallId] = prepared
                return .waitingForApproval(.mcp(request))
            } catch {
                return .completed(runtime.messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        if toolName == "recipe_import" {
            runtime.recipeExecution.discardPreparedImport(toolCallId: pending.toolCall.toolCallId)
            do {
                let prepared = try runtime.recipeToolService.prepareRecipeImport(
                    arguments: pending.toolCall.input
                )
                let request = RecipeToolApprovalRequestBuilder.importRequest(
                    for: pending.toolCall,
                    prepared: prepared
                )
                if runtime.effectiveHighRiskAutoApproveEnabled {
                    let resultText = try await runtime.recipeToolService.applyPreparedRecipeImport(prepared)
                    return .completed(runtime.messagesByFinishingToolCall(
                        pending.toolCall,
                        outputText: resultText,
                        in: pending.baseMessages
                    ))
                }
                runtime.recipeExecution.storePreparedImport(prepared, toolCallId: pending.toolCall.toolCallId)
                return .waitingForApproval(.recipe(request))
            } catch {
                return .completed(runtime.messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        if toolName == "plugin_test" {
            do {
                let test = try runtime.pluginToolService.preparePluginTest(arguments: pending.toolCall.input)
                if case .recipe = test.descriptor.implementation {
                    return await runtime.recipeExecution.executeRecipeToolCall(
                        pending, snapshot: nil, bridge: toolExposureBridge,
                        candidate: test.descriptor, argumentsJSON: test.argumentsJSON,
                        candidateTest: test.context
                    )
                }
                return await runtime.pluginExecution.executePluginToolCall(
                    pending, descriptor: test.descriptor, bridge: toolExposureBridge,
                    argumentsJSON: test.argumentsJSON, candidateTest: test.context
                )
            } catch {
                return .completed(runtime.messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName, reason: error.localizedDescription, status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        if toolName == "plugin_import" {
            runtime.pluginExecution.discardPreparedImport(toolCallId: pending.toolCall.toolCallId)
            do {
                let prepared = try runtime.pluginToolService.preparePluginImport(arguments: pending.toolCall.input)
                let request = RecipeToolApprovalRequestBuilder.pluginImportRequest(
                    for: pending.toolCall,
                    prepared: prepared
                )
                // Agent-authored packages are never self-approved, including
                // when high-risk auto approve is enabled.
                runtime.pluginExecution.storePreparedImport(prepared, toolCallId: pending.toolCall.toolCallId)
                return .waitingForApproval(.recipe(request))
            } catch {
                return .completed(runtime.messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        }

        let highRiskWorkflow = IOSRecipeToolCatalog.highRiskToolNames.contains(toolName)
            || IOSPluginToolCatalog.highRiskToolNames.contains(toolName)
        if highRiskWorkflow,
           !runtime.effectiveHighRiskAutoApproveEnabled,
           let request = ChatToolApprovalRequestBuilder.extensionMutation(
               for: pending.toolCall,
               reason: "该操作会替换或移除本机工作流包与回退版本，需要你确认。"
           ) {
            return .waitingForApproval(.mcp(request))
        }

        let mutatingWorkflow = IOSRecipeToolCatalog.mutatingToolNames.contains(toolName)
            || IOSPluginToolCatalog.mutatingToolNames.contains(toolName)
        if mutatingWorkflow,
           !runtime.effectiveGlobalAutoApproveEnabled,
           !runtime.effectiveHighRiskAutoApproveEnabled,
           let request = ChatToolApprovalRequestBuilder.extensionMutation(
               for: pending.toolCall,
               reason: "将修改本机工作流的启用状态，需要你确认。"
           ) {
            return .waitingForApproval(.mcp(request))
        }

        // MCP calls and MCP management can access remote services or import
        // connection configuration. Ordinary global auto-approve must not cross
        // this high-risk boundary.
        let highRiskMcp = toolName == "mcp_call"
            || ToolKt.isExpandedMcpToolName(name: toolName)
            || IOSMcpManagementToolCatalog.highRiskToolNames.contains(toolName)
        if highRiskMcp, !runtime.effectiveHighRiskAutoApproveEnabled {
            let request: McpToolApprovalRequest?
            if toolName == "mcp_call" {
                request = ChatToolApprovalRequestBuilder.mcp(
                    for: pending.toolCall,
                    reason: "MCP 工具可能访问外部服务或执行远端操作，需要你确认。"
                )
            } else if ToolKt.isExpandedMcpToolName(name: toolName),
                      let target = runtime.resolvedMcpTarget(forExpandedName: toolName) {
                // P0-b: flattened calls carry the tool's own arguments; the
                // approval card resolves server/tool from the directory —
                // same gate and resume path as mcp_call.
                request = ChatToolApprovalRequestBuilder.expandedMcp(
                    for: pending.toolCall,
                    server: target.server,
                    tool: target.tool,
                    reason: "MCP 工具可能访问外部服务或执行远端操作，需要你确认。"
                )
            } else {
                request = ChatToolApprovalRequestBuilder.extensionMutation(
                    for: pending.toolCall,
                    reason: "MCP 管理操作可能访问外部服务或写入连接配置，需要你确认。"
                )
            }
            if let request {
                return .waitingForApproval(.mcp(request))
            }
        }

        let mutatingSkill = IOSSkillToolCatalog.mutatingToolNames.contains(pending.toolCall.toolName)
        if mutatingSkill,
           !runtime.effectiveGlobalAutoApproveEnabled,
           !runtime.effectiveHighRiskAutoApproveEnabled,
           let request = ChatToolApprovalRequestBuilder.extensionMutation(
               for: pending.toolCall,
               reason: "将写入本机 Skill 或 MCP 配置，需要你确认。"
           ) {
            return .waitingForApproval(.mcp(request))
        }

        if pending.toolCall.toolName == "model_council_run",
           runtime.requiresCouncilApproval,
           let request = ChatToolApprovalRequestBuilder.council(
               for: pending.toolCall,
               reason: "模型议会会发起多次模型请求，需要你确认。"
           ) {
            return .waitingForApproval(.council(request))
        }

        if runtime.isMcpCallTool(toolName) {
            let output = await runtime.dispatchMcpToolOutput(pending.toolCall)
            return .completed(runtime.messagesByFinishingMcpToolCall(pending, output: output))
        }

        let resultText = await runtime.dispatchAdvancedToolCall(
            pending.toolCall,
            providerSetting: pending.providerSetting,
            params: pending.params,
            runId: pending.runId,
            conversationId: pending.conversationId,
            baseMessages: pending.baseMessages,
            nestedTools: nestedTools,
            toolExposureBridge: toolExposureBridge,
            // store 分支可见性：run 的 working 消息就是它所在分支（重新生成时
            // 已不含旧变体；压缩只作用于上传，不裁剪 working）。
            execStoreScope: toolName == "exec"
                ? ChatToolRuntime.execStoreScope(toolCall: pending.toolCall, runId: pending.runId, branchMessages: pending.baseMessages)
                : nil
        )
        return .completed(runtime.messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages,
            conversationId: pending.conversationId
        ))
    }

    // MARK: - Wave B2: `recipe__*` generic route (§13.2.5 / §16.1 / §10.3)

}
