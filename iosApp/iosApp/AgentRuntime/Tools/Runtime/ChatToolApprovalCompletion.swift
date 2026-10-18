import Foundation
@preconcurrency import Shared

@MainActor
extension ChatToolRuntime {
    func userInitiatedImageToolCall(input: String) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: "image-\(UUID().uuidString)-\(chatInputDigest(for: input))",
            toolName: "generate_image",
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    func messagesByExecutingImageToolCall(
        _ toolCall: UIMessagePart.Tool,
        in messages: [UIMessage]
    ) async -> [UIMessage] {
        let resultParts = await dispatchImageToolCall(toolCall, messages: messages)
        return messagesByFinishingToolCall(
            toolCall,
            outputParts: resultParts,
            in: messages
        )
    }

    func finishMemoryApproval(
        pending: ChatPendingToolApproval,
        writePolicy: IOSMemoryToolWritePolicy,
        expectedUpdatedAt: Int64? = nil
    ) -> [UIMessage] {
        let allowed: Bool
        if case .allow = writePolicy {
            allowed = true
        } else {
            allowed = false
        }
        recordToolApproval(
            capabilityId: "ios.agent.memory_write",
            toolCall: pending.toolCall,
            action: allowed ? .allowed : .denied,
            reason: allowed ? "User approved memory write." : "User denied memory write.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )

        let resultText = IOSMemoryToolExecutor.execute(
            input: pending.toolCall.input,
            runtime: sharedSettings.agentRuntime,
            writePolicy: writePolicy,
            expectedUpdatedAt: expectedUpdatedAt
        )
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    func finishSearchApproval(
        pending: ChatPendingToolApproval,
        allow: Bool
    ) async -> [UIMessage] {
        recordToolApproval(
            capabilityId: "ios.network.search_tools",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved network search." : "User denied network search.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        let result = allow
            ? await dispatchSearchToolOutput(pending.toolCall)
            : IOSSearchToolOutput(text: ChatToolOutputFormatter.toolFailureJSON(
                toolName: pending.toolCall.toolName,
                reason: "User denied network search.",
                denied: true
            ))
        return messagesByFinishingSearchToolCall(
            pending,
            output: result,
            conversationId: allow ? pending.conversationId : nil
        )
    }

    func finishWebMountApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        approvalRequest: WebMountToolApprovalRequest
    ) async -> [UIMessage] {
        recordToolApproval(
            capabilityId: "ios.webmount.browser",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved WebMount foreground action." : "User denied WebMount foreground action.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy,
            conversationId: pending.conversationId
        )

        let resultText: String
        let currentPreview = localToolExecutor?.webMountApprovalPreview(
            toolName: pending.toolCall.toolName,
            input: pending.toolCall.input
        )
        let handoffContextMatches = allow
            && approvalRequest.requiresHumanHandoff
            && approvalRequest.sessionId?.nilIfBlank != nil
            && approvalRequest.sessionId?.nilIfBlank == currentPreview?.sessionId?.nilIfBlank
            && approvalRequest.runId?.nilIfBlank != nil
            && approvalRequest.runId?.nilIfBlank == pending.runId.nilIfBlank
        let humanHandoffCompleted = handoffContextMatches
            && approvalRequest.backend == "local"
            && localToolExecutor?.completeWebMountHumanHandoff(
                toolName: pending.toolCall.toolName,
                input: pending.toolCall.input,
                runId: pending.runId
            ) == true
        if allow, pending.toolCall.toolName == "wm_site_memory",
           (currentPreview?.host != approvalRequest.host
            || currentPreview?.siteMemoryBaseline != approvalRequest.siteMemoryBaseline
            || currentPreview?.siteMemoryChanges != approvalRequest.siteMemoryChanges) {
            resultText = IOSWebMountController.json([
                "ok": false, "tool": "wm_site_memory", "error_code": "stale_site_memory_proposal",
                "reason": "站点记忆已变化，请重新提出修改。"
            ])
        } else if allow, approvalRequest.requiresHumanHandoff, !handoffContextMatches {
            resultText = IOSWebMountController.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "status": "stale_handoff",
                "error_code": "stale_handoff",
                "requires_reobserve": true,
                "may_have_applied": false,
                "message": "The WebMount handoff context changed; re-observe before continuing."
            ])
        } else if allow, approvalRequest.requiresHumanHandoff, approvalRequest.backend != "local" {
            resultText = IOSWebMountController.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "status": "requires_human",
                "error_code": "local_privacy_session_required",
                "requires_human": true,
                "handoff": true,
                "may_have_applied": false,
                "message": "The sensitive desktop action remained blocked. Complete it in local WebMount, then re-observe."
            ])
        } else if humanHandoffCompleted {
            resultText = IOSWebMountController.json([
                "ok": true,
                "tool": pending.toolCall.toolName,
                "status": "human_handoff_completed",
                "handoff": true,
                "requires_reobserve": true,
                "message": "Foreground WebMount handoff completed; re-observe before continuing."
            ])
        } else if allow, approvalRequest.requiresHumanHandoff {
            resultText = IOSWebMountController.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "status": "stale_handoff",
                "error_code": "stale_handoff",
                "requires_reobserve": true,
                "may_have_applied": false,
                "message": "The local handoff is no longer active; re-observe before continuing."
            ])
        } else if allow {
            let output = await webMountToolExecutionOutput(
                pending.toolCall,
                isUserInitiated: true,
                executionPolicy: pending.executionPolicy,
                runId: pending.runId,
                conversationId: pending.conversationId
            )
            resultText = ChatToolOutputFormatter.webMountResultText(for: pending.toolCall, output: output)
        } else {
            resultText = IOSWebMountController.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "denied": true,
                "policy": "user_denied",
                "reason": "User denied WebMount foreground action."
            ])
        }
        var recordedResultText = resultText
        if let data = resultText.data(using: .utf8),
           var result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if result["session_id"] == nil, let sessionId = approvalRequest.sessionId?.nilIfBlank {
                result["session_id"] = sessionId
            }
            if result["target_label"] == nil, let target = approvalRequest.target?.nilIfBlank {
                result["target_label"] = target
            }
            recordedResultText = IOSWebMountController.json(result)
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: recordedResultText,
            in: pending.baseMessages
        )
    }

    func finishWorkspaceApproval(
        pending: ChatPendingToolApproval,
        allow: Bool
    ) async -> [UIMessage] {
        recordToolApproval(
            capabilityId: IOSCapabilityRegistry.capability(forToolName: pending.toolCall.toolName)?.id
                ?? "ios.workspace.files",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved Workspace tool access." : "User denied Workspace tool access.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        let resultText: String
        if allow {
            let output = await workspaceToolExecutionOutput(
                pending.toolCall,
                isUserInitiated: true,
                executionPolicy: pending.executionPolicy
            )
            resultText = ChatToolOutputFormatter.workspaceResultText(for: pending.toolCall, output: output)
        } else {
            resultText = IOSWorkspaceStore.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "denied": true,
                "policy": "user_denied",
                "reason": "User denied Workspace tool access."
            ])
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    func finishIshHandoffApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        approvalRequest: IshHandoffToolApprovalRequest? = nil
    ) async -> [UIMessage] {
        let capabilityId = approvalRequest?.capabilityId
            ?? IOSCapabilityRegistry.capability(forToolName: pending.toolCall.toolName)?.id
            ?? "ios.external.ish_handoff"
        let canReturnExecutionOutput = IOSRemoteTerminalToolCatalog.supportedToolNames.contains(pending.toolCall.toolName)
            || IOSAmberShellToolCatalog.supportedToolNames.contains(pending.toolCall.toolName)
            || IOSEmbeddedIshToolCatalog.supportedToolNames.contains(pending.toolCall.toolName)
        recordToolApproval(
            capabilityId: capabilityId,
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved terminal tool." : "User denied terminal tool.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )

        let resultText: String
        if allow {
            let output = await ishToolExecutionOutput(
                pending.toolCall,
                isUserInitiated: true,
                executionPolicy: pending.executionPolicy,
                approvalRequest: approvalRequest
            )
            resultText = ChatToolOutputFormatter.ishHandoffResultText(for: pending.toolCall, output: output)
        } else {
            resultText = IOSWorkspaceStore.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "denied": true,
                "policy": "user_denied",
                "reason": "User denied terminal tool.",
                "stdout_available": canReturnExecutionOutput,
                "stderr_available": canReturnExecutionOutput,
                "exit_code_available": false
            ])
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    func finishMcpApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        preparedSkillImport: IOSPreparedSkillImport? = nil,
        preparedSoulImport: IOSPreparedSoulImport? = nil,
        preparedMcpImport: IOSPreparedMcpImport? = nil
    ) async -> [UIMessage] {
        let audit: (capabilityId: String, actionName: String)
        if pending.toolCall.toolName == "mcp_call"
            || ToolKt.isExpandedMcpToolName(name: pending.toolCall.toolName)
            || pending.toolCall.toolName == "mcp_test"
            || pending.toolCall.toolName == "mcp_import_from_skill" {
            audit = ("ios.mcp.tool_call", "MCP tool call")
        } else if IOSMcpManagementToolCatalog.toolNames.contains(pending.toolCall.toolName) {
            audit = ("ios.mcp.management", "MCP management operation")
        } else if IOSProviderConfigToolCatalog.highRiskToolNames.contains(pending.toolCall.toolName) {
            audit = ("ios.settings.provider_config", "Provider configuration")
        } else if pending.toolCall.toolName == "theme_pack_import" {
            audit = ("ios.settings.theme_pack", "Theme pack try-on")
        } else if pending.toolCall.toolName == IOSSoulToolCatalog.toolName {
            audit = ("ios.skills.management", "Soul update")
        } else if IOSRecipeToolCatalog.toolNames.contains(pending.toolCall.toolName)
                    || IOSPluginToolCatalog.toolNames.contains(pending.toolCall.toolName) {
            audit = ("ios.recipes.management", "Recipe management operation")
        } else if IOSAppleAgentToolCatalog.toolNames.contains(pending.toolCall.toolName) {
            audit = (
                IOSCapabilityRegistry.capability(forToolName: pending.toolCall.toolName)?.id
                    ?? "ios.apple.agent_tools",
                "Apple device capability"
            )
        } else {
            audit = ("ios.skills.management", "local Skill operation")
        }
        recordToolApproval(
            capabilityId: audit.capabilityId,
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved \(audit.actionName)." : "User denied \(audit.actionName).",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )

        if allow, isMcpCallTool(pending.toolCall.toolName), isMcpNetworkAllowed() {
            let output = await dispatchMcpToolOutput(pending.toolCall)
            return messagesByFinishingMcpToolCall(pending, output: output)
        }

        let resultText: String
        if allow {
            if pending.toolCall.toolName == "skill_import" {
                if let preparedSkillImport {
                    do {
                        resultText = try skillMcpToolService.applyPreparedSkillImport(preparedSkillImport)
                    } catch {
                        resultText = ChatToolOutputFormatter.toolFailureJSON(
                            toolName: pending.toolCall.toolName,
                            reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                            status: "failed"
                        )
                    }
                } else {
                    // 冷启动或审批内存态丢失时 fail closed；绝不能退回普通
                    // dispatch（那会重新 preview，或让未来实现意外绕过本次审批）。
                    resultText = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: "Skill 导入预览已失效，请重新发起导入并确认最新变更。",
                        status: "failed"
                    )
                }
            } else if pending.toolCall.toolName == IOSSoulToolCatalog.toolName {
                if let preparedSoulImport {
                    do {
                        resultText = try soulService.applyPreparedImport(preparedSoulImport)
                    } catch {
                        resultText = ChatToolOutputFormatter.toolFailureJSON(
                            toolName: pending.toolCall.toolName,
                            reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                            status: "failed"
                        )
                    }
                } else {
                    resultText = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: "核心指令预览已失效，请重新发起导入并确认最新变更。",
                        status: "failed"
                    )
                }
            } else if pending.toolCall.toolName == "mcp_import_from_skill" {
                if !isMcpNetworkAllowed() {
                    resultText = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: "MCP 调用已关闭，未发起网络测试或写入。",
                        status: "denied"
                    )
                } else if let preparedMcpImport {
                    resultText = await skillMcpToolService.applyPreparedMcpImport(preparedMcpImport) { [weak self] in
                        self?.isMcpNetworkAllowed() ?? false
                    }
                } else {
                    resultText = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: "MCP 导入预览已失效，请重新发起导入并确认最新变更。",
                        status: "failed"
                    )
                }
            } else if pending.toolCall.toolName == "theme_pack_import" {
                do {
                    resultText = try themePackToolService.commitPreparedImport()
                } catch {
                    resultText = ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName,
                        reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        status: "failed"
                    )
                }
            } else if isMcpNetworkTool(pending.toolCall.toolName), !isMcpNetworkAllowed() {
                resultText = ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: "MCP 调用已关闭。",
                    status: "denied"
                )
            } else {
                resultText = await dispatchAdvancedToolCall(
                    pending.toolCall,
                    providerSetting: pending.providerSetting,
                    params: pending.params,
                    runId: pending.runId,
                    conversationId: pending.conversationId
                )
            }
        } else if pending.toolCall.toolName == "theme_pack_import" {
            themePackToolService.discardPreparedImport()
            resultText = ChatToolOutputFormatter.toolFailureJSON(
                toolName: pending.toolCall.toolName,
                reason: "用户还原了试穿，主题未保存。",
                denied: true,
                status: "denied"
            )
        } else {
            resultText = "用户拒绝执行 \(pending.toolCall.toolName)。"
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages,
            // 拒绝分支输出是纯文本（无 ok:false 可判定），显式只在 allow 时置位。
            conversationId: allow ? pending.conversationId : nil
        )
    }

    func finishCouncilApproval(
        pending: ChatPendingToolApproval,
        allow: Bool
    ) async -> [UIMessage] {
        recordToolApproval(
            capabilityId: "ios.agent.model_council_run",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow
                ? "User approved \(pending.toolCall.toolName)."
                : "User denied \(pending.toolCall.toolName).",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        let resultText: String
        if allow {
            resultText = await dispatchAdvancedToolCall(
                pending.toolCall,
                providerSetting: pending.providerSetting,
                params: pending.params,
                runId: pending.runId,
                conversationId: pending.conversationId
            )
        } else {
            resultText = IOSWorkspaceStore.json([
                "ok": false,
                "tool": pending.toolCall.toolName,
                "status": "denied",
                "denied": true,
                "policy": "user_denied",
                "reason": "用户拒绝启动模型议会。"
            ])
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    func finishAskUserAnswer(
        pending: ChatPendingToolApproval,
        answer: String
    ) -> [UIMessage] {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: Any]
        if trimmed.isEmpty {
            payload = [
                "denied": true,
                "reason": "User skipped ask_user."
            ]
        } else {
            payload = ["answer": trimmed]
        }
        let outputText: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            outputText = text
        } else if trimmed.isEmpty {
            outputText = #"{"denied":true,"reason":"User skipped ask_user."}"#
        } else {
            outputText = #"{"answer":"\#(trimmed)"}"#
        }
        return messagesByFinishingToolCall(
            pending.toolCall,
            outputText: outputText,
            in: pending.baseMessages
        )
    }

    func messagesByFinishingToolCall(
        _ targetToolCall: UIMessagePart.Tool,
        outputText: String,
        in messages: [UIMessage],
        conversationId: KotlinUuid? = nil
    ) -> [UIMessage] {
        // P2-a: 工具输出唯一收口——成功的外部上下文输出进会话时由 harness 置
        // POLLUTED（只升不降；失败输出不置位；置位失败只记日志，不阻塞工具结果）。
        // conversationId 只由 run 锚定会话传入（前台 pending / 后台 job），
        // 恢复/失败路径（nil）与 UI 当前会话天然隔离。
        markMemoryPollutionIfNeeded(
            toolName: targetToolCall.toolName,
            outputText: outputText,
            conversationId: conversationId
        )
        let outputPart = UIMessagePart.Text(text: outputText, metadata: nil)
        return messagesByFinishingToolCall(targetToolCall, outputParts: [outputPart], in: messages)
    }

    /// P2-a: 判定并触发记忆污染置位。只标「外部上下文」工具（web 搜索/网页读取/
    /// MCP 直调与 mcp__* 展开）且输出为成功（failureReason 与 toolFailureJSON 的
    /// ok:false/status 契约一致）；wm_* 待 URL 分类后纳入（P2.5）。幂等只升不降由
    /// 存储层保证，这里只负责「成功输出进会话」这一 harness 时机。
    func markMemoryPollutionIfNeeded(
        toolName: String,
        outputText: String,
        conversationId: KotlinUuid?
    ) {
        guard let conversationId,
              let marker = memoryPollutionMarker,
              ConversationMemoryPollutionPolicy.shouldMarkPolluted(toolName: toolName, outputText: outputText),
              ChatToolOutputFormatter.failureReason(from: [UIMessagePart.Text(text: outputText, metadata: nil)]) == nil
        else { return }
        marker(conversationId, toolName)
    }

    func messagesByFailingPendingToolCalls(
        in messages: [UIMessage],
        outputText: String
    ) -> [UIMessage] {
        var resolvedMessages = messages
        var resolvedKeys = Set<String>()

        while let toolCall = unresolvedToolCall(in: resolvedMessages) {
            let key = chatToolCallKey(toolCall)
            guard resolvedKeys.insert(key).inserted else { break }
            resolvedMessages = messagesByFinishingToolCall(
                toolCall,
                outputText: outputText,
                in: resolvedMessages
            )
        }

        return resolvedMessages
    }

    func messagesByFailingPendingToolCalls(
        in messages: [UIMessage],
        failureReason: String,
        denied: Bool = false
    ) -> [UIMessage] {
        var resolvedMessages = messages
        var resolvedKeys = Set<String>()

        while let toolCall = unresolvedToolCall(in: resolvedMessages) {
            let key = chatToolCallKey(toolCall)
            guard resolvedKeys.insert(key).inserted else { break }
            resolvedMessages = messagesByFinishingToolCall(
                toolCall,
                outputText: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: failureReason,
                    denied: denied
                ),
                in: resolvedMessages
            )
        }

        return resolvedMessages
    }

    /// P0-a Fix B: soft-fail a tool call whose name EXISTS in the run's full
    /// catalog but is NOT in the current round's visible set — the model
    /// called a real tool that was never exposed (deferred behind tool_search).
    /// Fills that part in place with a structured failure output telling the
    /// model to call `tool_search` first, so the run CONTINUES instead of
    /// hard-failing. Returns nil when nothing needs guidance: a visible tool is
    /// handled by the normal execution path, and a truly unknown name stays on
    /// the existing unresolved-tool hard-fail path (never mask a real bug).
    func messagesByGuidingUnexposedToolCalls(
        in messages: [UIMessage],
        fullCatalogNames: Set<String>,
        visibleToolNames: Set<String>
    ) -> (messages: [UIMessage], toolCallId: String)? {
        guard let toolCall = unresolvedToolCall(in: messages) else { return nil }
        guard fullCatalogNames.contains(toolCall.toolName),
              !visibleToolNames.contains(toolCall.toolName) else { return nil }
        let outputText = ChatToolOutputFormatter.toolFailureJSON(
            toolName: toolCall.toolName,
            reason: "该工具本轮未暴露，请先调用 tool_search 获取，下一步再执行",
            status: "failed"
        )
        return (
            messagesByFinishingToolCall(toolCall, outputText: outputText, in: messages),
            toolCall.toolCallId
        )
    }

#if DEBUG
    func finishedToolCallMessagesForTesting(
        _ targetToolCall: UIMessagePart.Tool,
        outputText: String,
        in messages: [UIMessage]
    ) -> [UIMessage] {
        messagesByFinishingToolCall(targetToolCall, outputText: outputText, in: messages)
    }

    func memoryToolOutputForTesting(input: String) -> String {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-memory-tool",
            toolName: "memory_tool",
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        return dispatchMemoryToolCall(
            toolCall,
            writePolicy: memoryToolWritePolicy(input: input, isUserInitiated: false)
        )
    }

    func memoryApprovalRequestForTesting(input: String) -> MemoryToolApprovalRequest? {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-memory-tool",
            toolName: "memory_tool",
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        guard case .needsUserAction(let reason) = memoryToolWritePolicy(input: input, isUserInitiated: false) else {
            return nil
        }
        return ChatToolApprovalRequestBuilder.memory(for: toolCall, reason: reason)
    }

    func memoryToolApprovalOutputForTesting(
        input: String,
        allow: Bool,
        expectedUpdatedAt: Int64? = nil
    ) -> String {
        IOSMemoryToolExecutor.execute(
            input: input,
            runtime: sharedSettings.agentRuntime,
            writePolicy: allow ? .allow : .deniedByUser("User denied memory write."),
            expectedUpdatedAt: expectedUpdatedAt
        )
    }

    func webMountToolOutputForTesting(
        toolName: String,
        input: String,
        isUserInitiated: Bool = false
    ) async -> String {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-webmount-tool",
            toolName: toolName,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        if !isUserInitiated {
            return await dispatchWebMountToolCall(toolCall)
        }
        let output = await webMountToolExecutionOutput(toolCall, isUserInitiated: isUserInitiated)
        return ChatToolOutputFormatter.webMountResultText(for: toolCall, output: output)
    }

    func webMountApprovalRequestForTesting(
        toolName: String,
        input: String
    ) async -> WebMountToolApprovalRequest? {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-webmount-tool",
            toolName: toolName,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let output = await webMountToolExecutionOutput(toolCall, isUserInitiated: false)
        guard case .needsUserAction(let reason) = output else { return nil }
        return ChatToolApprovalRequestBuilder.webMount(
            for: toolCall,
            reason: reason,
            localToolExecutor: localToolExecutor
        )
    }

    func webMountToolApprovalOutputForTesting(
        toolName: String,
        input: String,
        allow: Bool
    ) async -> String {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-webmount-tool",
            toolName: toolName,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        guard allow else {
            return IOSWebMountController.json([
                "ok": false,
                "tool": toolName,
                "denied": true,
                "policy": "user_denied",
                "reason": "User denied WebMount foreground action."
            ])
        }
        let output = await webMountToolExecutionOutput(toolCall, isUserInitiated: true)
        return ChatToolOutputFormatter.webMountResultText(for: toolCall, output: output)
    }

    func searchApprovalRequestForTesting(
        toolName: String,
        input: String
    ) -> SearchToolApprovalRequest? {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-search-tool",
            toolName: toolName,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        return ChatToolApprovalRequestBuilder.search(
            for: toolCall,
            reason: "Test approval",
            settings: sharedSettings.snapshot
        )
    }

    func searchToolApprovalOutputForTesting(
        toolName: String,
        input: String,
        allow: Bool
    ) async -> String {
        let toolCall = UIMessagePart.Tool(
            toolCallId: "test-search-tool",
            toolName: toolName,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        guard allow else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolName,
                reason: "User denied network search.",
                denied: true
            )
        }
        return await dispatchSearchToolCall(toolCall)
    }
#endif
}
