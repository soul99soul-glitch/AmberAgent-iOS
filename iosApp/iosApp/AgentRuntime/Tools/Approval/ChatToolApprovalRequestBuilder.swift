import Foundation
@preconcurrency import Shared

/// P0-b: flattened `mcp__{server}__{tool}` declarations from the current MCP
/// discovery directory, for ENABLED servers only. The caller (ChatViewModel)
/// appends the result to the run exposure bridge's input tools — the bridge
/// defers every `mcp__*` name behind tool_search, so MCP off / no discovered
/// tools yields zero change. Cross-server sanitized name collisions keep the
/// first occurrence (KMP `mcpExpandedToolDeclarations` dedups within a server).
@MainActor
func expandedMcpToolDeclarations(mcpManager: IOSMcpManager) -> [Tool] {
    let enabledServerNames = Set(mcpManager.servers.filter(\.enabled).map(\.name))
    var declarations: [Tool] = []
    var seenNames = Set<String>()
    for discovered in mcpManager.tools
        where enabledServerNames.contains(discovered.serverName) && discovered.tool.enabled {
        let spec = McpDiscoveredToolSpec(
            name: discovered.tool.name,
            description: discovered.tool.description,
            inputSchemaJson: discovered.tool.inputSchema
        )
        for tool in ToolKt.mcpExpandedToolDeclarations(serverName: discovered.serverName, discovered: [spec]) {
            guard seenNames.insert(tool.name).inserted else { continue }
            declarations.append(tool)
        }
    }
    return declarations
}

enum ChatToolApprovalRequestBuilder {
    static func search(
        for toolCall: UIMessagePart.Tool,
        reason: String,
        settings: Settings?
    ) -> SearchToolApprovalRequest? {
        let target: String
        switch toolCall.toolName {
        case "search_web":
            guard let request = try? IOSSearchExecutor.searchRequest(
                from: toolCall.input,
                defaultMaxResults: Int(settings?.searchCommonOptions.resultSize ?? 10)
            ) else {
                return nil
            }
            target = request.query
        case "scrape_web":
            guard let request = try? IOSSearchExecutor.scrapeRequest(from: toolCall.input) else {
                return nil
            }
            target = request.url.absoluteString
        default:
            return nil
        }

        let selection = IOSSearchExecutor.searchProviderSelection(settings: settings)
        return SearchToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            toolName: toolCall.toolName,
            target: ChatToolCallParsing.truncatedSearchTarget(target),
            providerName: toolCall.toolName == "scrape_web" ? "公开网页读取" : selection.providerName,
            providerType: toolCall.toolName == "scrape_web" ? "scrape_web" : selection.providerType,
            reason: reason
        )
    }

    @MainActor
    static func workspace(
        for toolCall: UIMessagePart.Tool,
        reason: String,
        localToolExecutor: IOSLocalToolExecutor?
    ) -> WorkspaceToolApprovalRequest? {
        guard let preview = localToolExecutor?.workspaceApprovalPreview(
            toolName: toolCall.toolName,
            input: toolCall.input
        ) else {
            return nil
        }
        return WorkspaceToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            toolName: preview.toolName,
            action: preview.action,
            target: preview.target,
            isWrite: preview.isWrite,
            reason: reason
        )
    }

    static func memory(
        for toolCall: UIMessagePart.Tool,
        reason: String
    ) -> MemoryToolApprovalRequest? {
        guard let preview = IOSMemoryToolExecutor.approvalPreview(input: toolCall.input) else {
            return nil
        }
        return MemoryToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            action: preview.action,
            scope: preview.scope,
            kind: preview.kind,
            contentPreview: preview.contentPreview,
            targetId: preview.targetId,
            expectedUpdatedAt: preview.expectedUpdatedAt,
            reason: reason
        )
    }

    @MainActor
    static func webMount(
        for toolCall: UIMessagePart.Tool,
        reason: String,
        localToolExecutor: IOSLocalToolExecutor?,
        runId: String? = nil
    ) -> WebMountToolApprovalRequest? {
        guard let preview = localToolExecutor?.webMountApprovalPreview(
            toolName: toolCall.toolName,
            input: toolCall.input
        ) else {
            return nil
        }
        return WebMountToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            toolName: preview.toolName,
            siteId: preview.siteId,
            siteName: preview.siteName,
            host: preview.host,
            backend: preview.backend,
            mcpServerName: preview.mcpServerName,
            redactedURL: preview.redactedURL,
            snapshotId: preview.snapshotId,
            target: preview.target,
            action: preview.action,
            consequence: preview.consequence,
            screenshotRetentionWarning: preview.screenshotRetentionWarning,
            siteMemoryChanges: preview.siteMemoryChanges,
            siteMemoryBaseline: preview.siteMemoryBaseline,
            requiresHumanHandoff: reason.hasPrefix("human_handoff:"),
            reason: reason,
            sessionId: preview.sessionId,
            runId: runId
        )
    }

    @MainActor
    static func ishHandoff(
        for toolCall: UIMessagePart.Tool,
        reason: String,
        localToolExecutor: IOSLocalToolExecutor? = nil,
        runId: String? = nil
    ) -> IshHandoffToolApprovalRequest? {
        if IOSRemoteTerminalToolCatalog.supportedToolNames.contains(toolCall.toolName)
            || IOSAmberShellToolCatalog.supportedToolNames.contains(toolCall.toolName) {
            guard let preview = localToolExecutor?.terminalApprovalPreview(
                toolName: toolCall.toolName,
                input: toolCall.input
            ) ?? (toolCall.toolName == IOSAmberShellToolCatalog.executeToolName
                ? IOSAmberShellExecuteExecutor.approvalPreview(input: toolCall.input)
                : IOSRemoteTerminalExecuteExecutor.approvalPreview(input: toolCall.input)) else {
                return nil
            }
            return IshHandoffToolApprovalRequest(
                id: ChatToolCallParsing.requestId(for: toolCall),
                mode: preview.mode,
                commandPreview: preview.commandPreview,
                filename: preview.filename,
                reason: reason,
                contextLines: preview.contextLines,
                remoteProfileId: preview.remoteProfileId,
                remoteTargetDigest: preview.remoteTargetDigest,
                runId: runId,
                allowsApprove: preview.allowsApprove,
                requiresForegroundApproval: preview.requiresForegroundApproval,
                remoteHostTrust: preview.remoteHostTrust
            )
        }
        if IOSEmbeddedIshToolCatalog.supportedToolNames.contains(toolCall.toolName) {
            guard let preview = IOSEmbeddedIshExecuteExecutor.approvalPreview(input: toolCall.input) else {
                return nil
            }
            return IshHandoffToolApprovalRequest(
                id: ChatToolCallParsing.requestId(for: toolCall),
                mode: preview.mode,
                commandPreview: preview.commandPreview,
                filename: preview.filename,
                reason: reason,
                contextLines: preview.contextLines,
                runId: runId
            )
        }
        guard let preview = IOSIshHandoffExecutor.approvalPreview(input: toolCall.input) else {
            return nil
        }
        return IshHandoffToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            mode: .handoff,
            commandPreview: preview.commandPreview,
            filename: preview.filename,
            reason: reason,
            runId: runId
        )
    }

    static func mcp(
        for toolCall: UIMessagePart.Tool,
        reason: String
    ) -> McpToolApprovalRequest? {
        guard let args = ChatToolCallParsing.jsonObject(toolCall.input),
              let server = args["server"] as? String,
              let tool = args["tool"] as? String else {
            return nil
        }
        return McpToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            serverName: server,
            toolName: tool,
            argumentsPreview: ChatToolCallParsing.truncatedMcpArguments(args["arguments"]),
            reason: reason
        )
    }

    /// P0-b: approval card for a flattened `mcp__{server}__{tool}` call. The
    /// input carries the tool's OWN arguments (no `{server, tool, arguments}`
    /// envelope), so the resolved directory target is passed in explicitly —
    /// same display shape and gate as `mcp_call`.
    static func expandedMcp(
        for toolCall: UIMessagePart.Tool,
        server: String,
        tool: String,
        reason: String
    ) -> McpToolApprovalRequest {
        McpToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            serverName: server,
            toolName: tool,
            argumentsPreview: ChatToolCallParsing.truncatedMcpArguments(ChatToolCallParsing.jsonObject(toolCall.input)),
            reason: reason
        )
    }

    static func extensionMutation(
        for toolCall: UIMessagePart.Tool,
        reason: String,
        skillImportPreview: McpSkillImportPreview? = nil,
        soulImportPreview: SoulImportPreview? = nil,
        mcpImportPreview: McpImportPreview? = nil
    ) -> McpToolApprovalRequest? {
        let args = ChatToolCallParsing.jsonObject(toolCall.input) ?? [:]
        let target = (args["name"] as? String)
            ?? (args["skill_name"] as? String)
            ?? (args["workspace_path"] as? String)
            ?? (args["server_id"] as? String)
            ?? toolCall.toolName
        let argumentsPreview: String
        if let preview = skillImportPreview {
            let action = preview.mutationKind == .new ? "新建" : "更新"
            let base = preview.baseHash.map { String($0.prefix(8)) } ?? "无"
            let candidate = String(preview.candidateHash.prefix(8))
            argumentsPreview = "\(action) \(preview.skillName) · \(preview.changedFiles.count) 个文件 · \(base)→\(candidate)"
        } else if let preview = soulImportPreview {
            argumentsPreview = "更新核心指令 · \(preview.changedLineCount) 行 · \(String(preview.baseHash.prefix(8)))→\(String(preview.candidateHash.prefix(8)))"
        } else if let preview = mcpImportPreview {
            argumentsPreview = "从 \(preview.skillName) 导入 \(preview.servers.count) 个 MCP 服务"
        } else {
            // Always pass a JSON object; bare String fails JSONSerialization.
            argumentsPreview = ChatToolCallParsing.truncatedMcpArguments(
                args.isEmpty ? ["target": target] : args
            )
        }
        return McpToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            serverName: "local",
            toolName: toolCall.toolName,
            argumentsPreview: argumentsPreview,
            reason: reason,
            skillImportPreview: skillImportPreview,
            soulImportPreview: soulImportPreview,
            mcpImportPreview: mcpImportPreview
        )
    }

    static func appleCapability(
        for toolCall: UIMessagePart.Tool,
        reason: String
    ) -> McpToolApprovalRequest? {
        let args = ChatToolCallParsing.jsonObject(toolCall.input) ?? [:]
        return McpToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            serverName: "iPhone",
            toolName: toolCall.toolName,
            argumentsPreview: appleArgumentsPreview(toolName: toolCall.toolName, arguments: args),
            reason: reason
        )
    }

    private static func appleArgumentsPreview(toolName: String, arguments: [String: Any]) -> String {
        if IOSAppleAgentToolCatalog.workoutToolNames.contains(toolName) {
            return IOSWorkoutAgentToolExecutor.approvalPreview(arguments: arguments)
        }
        if IOSAppleAgentToolCatalog.alarmToolNames.contains(toolName) {
            let labels: [(String, String)] = [
                ("title", IOSAlarmCopy.titleField),
                ("fire_at", IOSAlarmCopy.timeField),
                ("kind", IOSAlarmCopy.typeField),
                ("weekdays", IOSAlarmCopy.weekdaysField),
                ("hour", IOSAlarmCopy.hourField),
                ("minute", IOSAlarmCopy.minuteField),
                ("duration_seconds", IOSAlarmCopy.durationField),
                ("alarm_id", IOSAlarmCopy.identifierField)
            ]
            let lines = labels.compactMap { key, label -> String? in
                guard let value = arguments[key] else { return nil }
                let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return "\(label): \(String(text.prefix(160)))"
            }
            if !lines.isEmpty { return lines.joined(separator: "\n") }
            return arguments.isEmpty
                ? IOSAlarmCopy.noAdditionalParameters
                : ChatToolCallParsing.truncatedMcpArguments(arguments)
        }
        let labels: [(String, String)] = [
            ("title", "标题"),
            ("start_at", "开始"),
            ("end_at", "结束"),
            ("due_at", "到期"),
            ("fire_at", "时间"),
            ("kind", "类型"),
            ("weekdays", "星期"),
            ("hour", "小时"),
            ("minute", "分钟"),
            ("duration_seconds", "时长（秒）"),
            ("recurrence", "重复"),
            ("event_id", "事件 ID"),
            ("reminder_id", "提醒 ID"),
            ("alarm_id", "闹钟 ID")
        ]
        let lines = labels.compactMap { key, label -> String? in
            guard let value = arguments[key] else { return nil }
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(label)：\(String(text.prefix(160)))"
        }
        if !lines.isEmpty { return lines.joined(separator: "\n") }
        return arguments.isEmpty
            ? "无需额外参数"
            : ChatToolCallParsing.truncatedMcpArguments(arguments)
    }

    static func council(
        for toolCall: UIMessagePart.Tool,
        reason: String
    ) -> CouncilToolApprovalRequest? {
        let args = ChatToolCallParsing.jsonObject(toolCall.input)
        let objective = args?["objective"] as? String ?? toolCall.input
        return CouncilToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            objectivePreview: ChatToolCallParsing.truncatedSearchTarget(objective),
            maxSeats: args?["max_seats"] as? Int,
            reason: reason
        )
    }

    static func askUser(
        for toolCall: UIMessagePart.Tool
    ) -> ChatAskUserRequest? {
        guard toolCall.toolName == "ask_user" else { return nil }
        let args = ChatToolCallParsing.jsonObject(toolCall.input) ?? [:]
        let question = (args["question"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let options = (ChatToolCallParsing.stringArray(args["options"]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Deduplicate while preserving order.
        var seen = Set<String>()
        let uniqueOptions = options.filter { seen.insert($0).inserted }
        let resolvedQuestion: String
        if let question, !question.isEmpty {
            resolvedQuestion = question
        } else {
            let fallback = toolCall.input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallback.isEmpty else { return nil }
            resolvedQuestion = fallback
        }
        let clippedOptions = Array(uniqueOptions.prefix(6))
        return ChatAskUserRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            question: resolvedQuestion,
            options: clippedOptions
        )
    }
}

