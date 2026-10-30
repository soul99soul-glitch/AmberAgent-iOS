import Foundation
@preconcurrency import Shared

enum IOSSearchToolPermission: Equatable {
    static let capabilityId = "ios.network.search_tools"

    case allow
    case needsApproval(String)
    case denied(String)

    static func resolve(
        webSearchEnabled: Bool,
        policy: IOSAgentPermissionPolicy,
        globalAutoApprove: Bool,
        highRiskAutoApprove: Bool,
        isUserInitiated: Bool = false
    ) -> Self {
        guard webSearchEnabled else {
            return .denied("Web search is disabled in settings.")
        }
        guard policy != .disabled else {
            return .denied("Search and webpage access are disabled by AmberAgent policy.")
        }
        if isUserInitiated || policy == .autoApprove || policy == .autoApproveHighRisk
            || globalAutoApprove || highRiskAutoApprove {
            return .allow
        }
        return .needsApproval("网络搜索和网页读取会访问外部站点，需要你确认。")
    }
}

@MainActor
extension ChatToolRuntime {
    func searchToolPermission(isUserInitiated: Bool = false) -> IOSSearchToolPermission {
        let policy: IOSAgentPermissionPolicy
        if let snapshot = IOSExecutionPolicyContext.snapshot {
            policy = snapshot.capabilityPolicies[IOSSearchToolPermission.capabilityId]
                .flatMap(IOSAgentPermissionPolicy.init(rawValue:)) ?? .askEveryTime
        } else {
            policy = localToolExecutor?.permissionPolicy(capabilityId: IOSSearchToolPermission.capabilityId)
                ?? .askEveryTime
        }
        return IOSSearchToolPermission.resolve(
            webSearchEnabled: effectiveWebSearchEnabled,
            policy: policy,
            globalAutoApprove: effectiveGlobalAutoApproveEnabled,
            highRiskAutoApprove: effectiveHighRiskAutoApproveEnabled,
            isUserInitiated: isUserInitiated
        )
    }

    func executeSearchToolCall(_ pending: ChatPendingToolApproval) async -> ChatToolRuntimeResult {
        if case .needsApproval(let reason) = searchToolPermission(),
           let request = ChatToolApprovalRequestBuilder.search(
               for: pending.toolCall,
               reason: reason,
               settings: sharedSettings.snapshot
           ) {
            return .waitingForApproval(.search(request))
        }

        let output = await dispatchSearchToolOutput(pending.toolCall)
        return .completed(messagesByFinishingSearchToolCall(
            pending,
            output: output,
            conversationId: pending.conversationId
        ))
    }

    func executeWorkspaceToolCall(_ pending: ChatPendingToolApproval) async -> ChatToolRuntimeResult {
        let output = await workspaceToolExecutionOutput(pending.toolCall, isUserInitiated: false)
        if case .needsUserAction(let reason) = output,
           let request = ChatToolApprovalRequestBuilder.workspace(
               for: pending.toolCall,
               reason: reason,
               localToolExecutor: localToolExecutor
           ) {
            return .waitingForApproval(.workspace(request))
        }

        let resultText = ChatToolOutputFormatter.workspaceResultText(for: pending.toolCall, output: output)
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        ))
    }

    func executeIshToolCall(_ pending: ChatPendingToolApproval) async -> ChatToolRuntimeResult {
        let output = await ishToolExecutionOutput(
            pending.toolCall,
            isUserInitiated: isIshAutoApproved(
                toolName: pending.toolCall.toolName,
                input: pending.toolCall.input,
                runId: pending.runId,
                conversationId: pending.conversationId
            )
        )
        if case .needsUserAction(let reason) = output,
           let request = ChatToolApprovalRequestBuilder.ishHandoff(
               for: pending.toolCall,
               reason: reason,
               localToolExecutor: localToolExecutor,
               runId: pending.runId
           ) {
            return .waitingForApproval(.ish(request))
        }

        let resultText = ChatToolOutputFormatter.ishHandoffResultText(for: pending.toolCall, output: output)
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        ))
    }

    func executeWebMountToolCall(_ pending: ChatPendingToolApproval) async -> ChatToolRuntimeResult {
        let output = await webMountToolExecutionOutput(
            pending.toolCall,
            isUserInitiated: false,
            runId: pending.runId,
            conversationId: pending.conversationId
        )
        if case .needsUserAction(let reason) = output,
           let request = ChatToolApprovalRequestBuilder.webMount(
               for: pending.toolCall,
               reason: reason,
               localToolExecutor: localToolExecutor,
               runId: pending.runId
           ) {
            return .waitingForApproval(.webMount(request))
        }

        let resultText = ChatToolOutputFormatter.webMountResultText(for: pending.toolCall, output: output)
        let messages = messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
        return output.isWebMountOutcomeUnknown ? .outcomeUnknown(messages) : .completed(messages)
    }

    func executeMemoryToolCall(_ pending: ChatPendingToolApproval) -> ChatToolRuntimeResult {
        let writePolicy = memoryToolWritePolicy(input: pending.toolCall.input, isUserInitiated: false)
        if case .needsUserAction(let reason) = writePolicy,
           let request = ChatToolApprovalRequestBuilder.memory(for: pending.toolCall, reason: reason) {
            return .waitingForApproval(.memory(request))
        }

        let resultText = dispatchMemoryToolCall(pending.toolCall, writePolicy: writePolicy)
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        ))
    }

    func executeImageToolCall(_ pending: ChatPendingToolApproval) async -> ChatToolRuntimeResult {
        let resultParts = await dispatchImageToolCall(pending.toolCall, messages: pending.baseMessages)
        return .completed(messagesByFinishingToolCall(
            pending.toolCall,
            outputParts: resultParts,
            in: pending.baseMessages
        ))
    }

    static func mcpSkillImportPreview(
        from preview: IOSSkillImportPreview
    ) -> McpSkillImportPreview {
        let mutationKind: McpSkillImportMutationKind = switch preview.kind {
        case .new: .new
        case .update: .update
        }
        let changedFiles = preview.changedFiles.map { change in
            let kind: McpSkillImportFileChangeKind = switch change.kind {
            case .added: .added
            case .modified: .modified
            case .removed: .removed
            }
            return McpSkillImportFileChange(
                path: change.path,
                kind: kind,
                beforeText: change.beforeText,
                afterText: change.afterText
            )
        }
        return McpSkillImportPreview(
            skillName: preview.name,
            mutationKind: mutationKind,
            baseHash: preview.baseHash,
            candidateHash: preview.candidateHash,
            beforeSummary: preview.beforeSummary ?? "尚未安装",
            afterSummary: preview.afterSummary,
            changedFiles: changedFiles,
            containsMcpConfig: preview.containsMcpConfig
        )
    }

    func messagesByFinishingSearchToolCall(
        _ pending: ChatPendingToolApproval,
        output: IOSSearchToolOutput,
        conversationId: KotlinUuid?
    ) -> [UIMessage] {
        markMemoryPollutionIfNeeded(
            toolName: pending.toolCall.toolName,
            outputText: output.text,
            conversationId: conversationId
        )
        return messagesByFinishingToolCall(pending.toolCall, outputParts: output.parts, in: pending.baseMessages)
    }

    func dispatchSearchToolOutput(
        _ toolCall: UIMessagePart.Tool,
        isUserInitiated: Bool = false
    ) async -> IOSSearchToolOutput {
        switch searchToolPermission(isUserInitiated: isUserInitiated) {
        case .denied(let reason), .needsApproval(let reason):
            return IOSSearchToolOutput(text: ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: reason,
                denied: true
            ))
        case .allow:
            break
        }
        return await IOSSearchToolDispatch.dispatchOutput(
            toolCall,
            settings: sharedSettings.snapshot,
            webSearchEnabled: effectiveWebSearchEnabled,
            transport: searchTransport
        )
    }

    func dispatchSearchToolCall(
        _ toolCall: UIMessagePart.Tool,
        isUserInitiated: Bool = false
    ) async -> String {
        await dispatchSearchToolOutput(toolCall, isUserInitiated: isUserInitiated).text
    }

    func shouldExecuteSearchInBackground(toolName: String, arguments: String) -> Bool {
        searchToolPermission() == .allow
    }

    func workspaceToolExecutionOutput(
        _ toolCall: UIMessagePart.Tool,
        isUserInitiated: Bool,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) async -> IOSLocalToolExecutionOutput {
        guard let localToolExecutor else {
            return .failed("Local iOS tool executor is unavailable.")
        }
        return await localToolExecutor.execute(localToolExecutor.executionRequest(
            toolName: toolCall.toolName,
            operation: toolCall.input,
            isUserInitiated: isUserInitiated,
            executionPolicy: executionPolicy ?? IOSExecutionPolicyContext.snapshot
        ))
    }

    func ishToolExecutionOutput(
        _ toolCall: UIMessagePart.Tool,
        isUserInitiated: Bool,
        executionPolicy: IOSExecutionPolicySnapshot? = nil,
        approvalRequest: IshHandoffToolApprovalRequest? = nil
    ) async -> IOSLocalToolExecutionOutput {
        guard let localToolExecutor else {
            return .failed("Local iOS tool executor is unavailable.")
        }
        return await localToolExecutor.execute(localToolExecutor.executionRequest(
            toolName: toolCall.toolName,
            operation: toolCall.input,
            isUserInitiated: isUserInitiated,
            executionPolicy: executionPolicy ?? IOSExecutionPolicyContext.snapshot,
            approvedRemoteProfileId: approvalRequest?.remoteProfileId,
            approvedRemoteTargetDigest: approvalRequest?.remoteTargetDigest
        ))
    }

    func dispatchWebMountToolCall(_ toolCall: UIMessagePart.Tool) async -> String {
        let output = await webMountToolExecutionOutput(toolCall, isUserInitiated: false)
        return ChatToolOutputFormatter.webMountResultText(for: toolCall, output: output)
    }

    func isWebMountOutcomeUnknown(
        in messages: [UIMessage],
        toolCallId: String
    ) -> Bool {
        for message in messages where message.role == MessageRole.assistant {
            for case let tool as UIMessagePart.Tool in message.parts
            where tool.toolCallId == toolCallId {
                for case let text as UIMessagePart.Text in tool.output {
                    if isWebMountInterruptedOutcome(text.text) {
                        return true
                    }
                }
            }
        }
        return false
    }

    func webMountToolExecutionOutput(
        _ toolCall: UIMessagePart.Tool,
        isUserInitiated: Bool,
        executionPolicy: IOSExecutionPolicySnapshot? = nil,
        runId: String = "",
        conversationId: KotlinUuid? = nil
    ) async -> IOSLocalToolExecutionOutput {
        // Jev Phase 3：wm_run_goal 是本地编排工具（不是远端后端操作），
        // 先于后端映射分支；每个内层动作仍走下方既有 WebMount 执行链。
        if toolCall.toolName == "wm_run_goal" {
            return await runJevWebGoalLoopOutput(
                toolCall,
                isUserInitiated: isUserInitiated,
                runId: runId,
                conversationId: conversationId
            )
        }
        guard let localToolExecutor else {
            return .failed("Local iOS tool executor is unavailable.")
        }
        return await localToolExecutor.execute(localToolExecutor.executionRequest(
            toolName: toolCall.toolName,
            operation: toolCall.input,
            isUserInitiated: isUserInitiated,
            runId: runId,
            conversationId: conversationId?.toHexDashString() ?? "",
            executionPolicy: executionPolicy ?? IOSExecutionPolicyContext.snapshot
        ), visualRead: { [sharedSettings, conversationId] capture, question in
            try await IOSWebMountVisionReader().read(
                capture: capture,
                question: question,
                settings: sharedSettings.snapshot,
                conversationId: conversationId?.toHexDashString()
            )
        })
    }

    // MARK: - wm_run_goal（Jev Phase 3 有界网页快速循环）

    /// 工具入口绑定：循环的观察/执行都经既有 WebMount 工具路径，内层审批与
    /// 账本免费继承。off / 无 Key / 低置信 / 范围不允许时循环自身 handback，
    /// 不会触碰页面；只有 active（pinned 验收版本 + 全范围允许）才真正执行。
    func dispatchMemoryToolCall(
        _ toolCall: UIMessagePart.Tool,
        writePolicy: IOSMemoryToolWritePolicy
    ) -> String {
        IOSMemoryToolExecutor.execute(
            input: toolCall.input,
            runtime: sharedSettings.agentRuntime,
            writePolicy: writePolicy
        )
    }

    func memoryToolWritePolicy(input: String, isUserInitiated: Bool) -> IOSMemoryToolWritePolicy {
        localToolExecutor?.memoryToolWritePolicy(
            input: input,
            isUserInitiated: isUserInitiated,
            executionPolicy: IOSExecutionPolicyContext.snapshot
        ) ?? (IOSMemoryToolExecutor.requiresWriteApproval(input: input)
            ? .needsUserAction("Memory writes require foreground approval.")
            : .allow)
    }

    func dispatchImageToolCall(
        _ toolCall: UIMessagePart.Tool,
        messages: [UIMessage] = []
    ) async -> [UIMessagePart] {
        let settings = sharedSettings.snapshot
        if let model = settings.findModelById(uuid: settings.imageGenerationModelId),
           let provider = ChatProviderConfiguration.provider(for: model, providers: settings.providers),
           !provider.enabled {
            return [UIMessagePart.Text(
                text: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: "generate_image",
                    reason: "生图服务商已停用，请先启用或选择其他生图模型。"
                ),
                metadata: nil
            )]
        }
        let enrichedInput: String
        switch ChatImageGenerationReference.enrichToolInput(toolCall.input, messages: messages) {
        case .success(let input):
            enrichedInput = input
        case .failure(.attachedImageRequestedButMissing):
            return [UIMessagePart.Text(
                text: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: "generate_image",
                    reason: "当前消息没有可垫的附图。请先上传参考图，或改用文字描述重新生成。"
                ),
                metadata: nil
            )]
        }
        let resolvedToolCall = PromptTranscript.shared.doCopyTool(
            tool: toolCall,
            input: enrichedInput,
            output: toolCall.output
        )

        do {
            switch codexImageConfig() {
            case let .signedIn(codex, imageModelID, preferredRoutingModelID):
                let request = try IOSImageGenerationRepository.shared.toolRequest(
                    from: resolvedToolCall.input,
                    modelId: imageModelID
                )
                let record = try await IOSImageGenerationRepository.shared.generateViaCodex(
                    request: request,
                    providerId: codex,
                    preferredRoutingModelID: preferredRoutingModelID
                )
                var parts: [UIMessagePart] = record.files.map { file in
                    UIMessagePart.Image(
                        url: IOSImageGenerationRepository.chatImageURLString(filePath: file.path),
                        metadata: nil
                    )
                }
                parts.append(UIMessagePart.Text(text: IOSImageGenerationRepository.shared.toolResultJSON(record: record), metadata: nil))
                return parts
            case .notSignedIn:
                return [UIMessagePart.Text(
                    text: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: "generate_image",
                        reason: "请先在服务商设置里登录 Codex 后再生成或修改图片。"
                    ),
                    metadata: nil
                )]
            case .notSelected:
                break
            }
            guard let config = resolvedImageGenerationConfig() else {
                return [UIMessagePart.Text(
                    text: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: "generate_image",
                        reason: "请先在「默认模型 → 辅助任务」里设置生图模型。"
                    ),
                    metadata: nil
                )]
            }
            let request = try IOSImageGenerationRepository.shared.toolRequest(
                from: resolvedToolCall.input,
                modelId: config.modelId
            )
            if request.sourceImageURL != nil {
                return [UIMessagePart.Text(
                    text: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: "generate_image",
                        reason: "当前图片修改只支持 Codex 生图。"
                    ),
                    metadata: nil
                )]
            }
            let record = try await IOSImageGenerationRepository.shared.generate(
                request: request,
                apiKey: config.apiKey,
                baseURL: config.baseURL
            )
            var parts: [UIMessagePart] = record.files.map { file in
                UIMessagePart.Image(
                    url: IOSImageGenerationRepository.chatImageURLString(filePath: file.path),
                    metadata: nil
                )
            }
            parts.append(UIMessagePart.Text(text: IOSImageGenerationRepository.shared.toolResultJSON(record: record), metadata: nil))
            return parts
        } catch {
            return [
                UIMessagePart.Text(
                    text: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: "generate_image",
                        reason: error.localizedDescription
                    ),
                    metadata: nil
                )
            ]
        }
    }

    var isWebMountRuntimeEnabled: Bool {
        true
    }

    func isMcpCallTool(_ name: String) -> Bool {
        name == "mcp_call" || ToolKt.isExpandedMcpToolName(name: name)
    }

    func messagesByFinishingMcpToolCall(
        _ pending: ChatPendingToolApproval,
        output: IOSMcpToolOutput
    ) -> [UIMessage] {
        markMemoryPollutionIfNeeded(
            toolName: pending.toolCall.toolName,
            outputText: output.text,
            conversationId: pending.conversationId
        )
        return messagesByFinishingToolCall(pending.toolCall, outputParts: output.parts, in: pending.baseMessages)
    }

    func dispatchMcpToolOutput(_ toolCall: UIMessagePart.Tool) async -> IOSMcpToolOutput {
        let server: String
        let tool: String
        let arguments: [String: Any]
        if toolCall.toolName == "mcp_call" {
            guard let args = ChatToolCallParsing.jsonObject(toolCall.input),
                  let serverName = args["server"] as? String,
                  let toolName = args["tool"] as? String else {
                return IOSMcpToolOutput(text: "mcp_call 参数无效：需要 server 与 tool。")
            }
            server = serverName
            tool = toolName
            arguments = args["arguments"] as? [String: Any] ?? [:]
        } else {
            guard let target = resolvedMcpTarget(forExpandedName: toolCall.toolName) else {
                return IOSMcpToolOutput(text: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "MCP 工具已不可用：当前已启用的 server 中不存在该工具。请调用 mcp_list 检查可用的 MCP 工具。",
                    status: "failed"
                ))
            }
            guard let args = ChatToolCallParsing.jsonObject(toolCall.input) else {
                return IOSMcpToolOutput(text: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: toolCall.toolName,
                    reason: "MCP 工具参数无效：需要 JSON 对象。",
                    status: "failed"
                ))
            }
            server = target.server
            tool = target.tool
            arguments = args
        }
        do {
            return try await mcpManager.callToolOutput(
                serverName: server,
                toolName: tool,
                arguments: arguments,
                enabledOverride: isMcpNetworkAllowed()
            )
        } catch {
            return IOSMcpToolOutput(text: ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolCall.toolName,
                reason: "MCP 调用失败（server: \(server)，tool: \(tool)）：\(error.localizedDescription)",
                status: "failed"
            ))
        }
    }

    /// P0-b: resolve a flattened `mcp__{server}__{tool}` name back to the
    /// discovery directory (enabled servers only). Sanitization is not
    /// reversible, so this is the authoritative lookup for execution routing.
    func resolvedMcpTarget(forExpandedName name: String) -> (server: String, tool: String)? {
        let enabledServerNames = Set(mcpManager.servers.filter(\.enabled).map(\.name))
        for discovered in mcpManager.tools
            where enabledServerNames.contains(discovered.serverName) && discovered.tool.enabled {
            if ToolKt.expandedMcpToolName(server: discovered.serverName, tool: discovered.tool.name) == name {
                return (discovered.serverName, discovered.tool.name)
            }
        }
        return nil
    }

    /// P0-b: flattened MCP declarations over the CURRENT directory. The
    /// background job regenerates them so its exposure bridge catalog stays in
    /// parity with the foreground run — handoff payloads carry tool NAMES only,
    /// and dynamic `mcp__*` tools cannot be rebuilt from a name.
    func mcpExpandedDeclarations() -> [Tool] {
        expandedMcpToolDeclarations(mcpManager: mcpManager)
    }

    func isMcpNetworkAllowed() -> Bool {
        let masterEnabled = IOSExecutionPolicyContext.snapshot?.mcpEnabled
            ?? sharedSettings.isCapabilityGateEnabled(.mcp)
        return masterEnabled && isCapabilityPolicyEnabled("ios.mcp.tool_call")
    }

}
