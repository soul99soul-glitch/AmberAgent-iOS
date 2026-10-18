import Foundation
@preconcurrency import Shared

@MainActor
final class ChatPluginExecution {
    unowned let runtime: ChatToolRuntime
    private var preparedImports: [String: IOSPreparedPluginImport] = [:]
    private var preparedInvocations: [String: IOSPreparedPluginInvocation] = [:]

    init(runtime: ChatToolRuntime) { self.runtime = runtime }

    func storePreparedImport(_ value: IOSPreparedPluginImport, toolCallId: String) {
        preparedImports[toolCallId] = value
    }

    func takePreparedImport(toolCallId: String) -> IOSPreparedPluginImport? {
        preparedImports.removeValue(forKey: toolCallId)
    }

    func discardPreparedImport(toolCallId: String) {
        preparedImports.removeValue(forKey: toolCallId)
    }

    func takePreparedInvocation(toolCallId: String) -> IOSPreparedPluginInvocation? {
        preparedInvocations.removeValue(forKey: toolCallId)
    }

    func discardPreparedInvocation(toolCallId: String) {
        preparedInvocations.removeValue(forKey: toolCallId)
    }


    func executePluginToolCall(
        _ pending: ChatPendingToolApproval,
        descriptor: IOSDynamicRecipeToolDescriptor,
        bridge: IosToolExposureBridge?,
        argumentsJSON: String? = nil,
        candidateTest: IOSPluginTestContext? = nil
    ) async -> ChatToolRuntimeResult {
        let invocationArguments = argumentsJSON ?? pending.toolCall.input
        guard descriptor.pluginId != nil else {
            return .completed(runtime.messagesByFinishingToolCall(
                pending.toolCall,
                outputText: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: "动态工具缺少插件归属。",
                    status: "failed"
                ),
                in: pending.baseMessages
            ))
        }
        if let issue = pluginInputIssue(invocationArguments, matches: descriptor) {
            return .completed(runtime.messagesByFinishingToolCall(
                pending.toolCall,
                outputText: ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: issue,
                    status: "failed"
                ),
                in: pending.baseMessages
            ))
        }

        let autoApproved: Bool
        var argumentsPreview = runtime.recipeExecution.recipeArgumentsPreview(invocationArguments)
        if case .command(let source) = descriptor.implementation {
            do {
                if let reason = pluginCommandAvailabilityIssue(source) {
                    throw IOSPluginCommandError.unavailable(reason)
                }
                let invocation = try IOSPluginCommandBuilder.build(
                    source: source.source, manifest: source.manifest,
                    inputObject: ChatToolCallParsing.jsonObject(invocationArguments) ?? [:],
                    timeoutMs: descriptor.timeoutMs
                )
                autoApproved = runtime.isIshToolAutoApproved(
                    toolName: invocation.toolName, input: invocation.argumentsJSON,
                    runId: pending.runId, conversationId: pending.conversationId
                )
                argumentsPreview = runtime.recipeExecution.recipeArgumentsPreview(invocation.argumentsJSON)
            } catch {
                return .completed(runtime.messagesByFinishingToolCall(
                    pending.toolCall,
                    outputText: ChatToolOutputFormatter.toolFailureJSON(
                        toolName: pending.toolCall.toolName, reason: error.localizedDescription, status: "failed"
                    ),
                    in: pending.baseMessages
                ))
            }
        } else {
            autoApproved = pluginRequiresHighRiskApproval(descriptor)
                ? runtime.effectiveHighRiskAutoApproveEnabled
                : (runtime.effectiveGlobalAutoApproveEnabled || runtime.effectiveHighRiskAutoApproveEnabled)
        }
        if descriptor.effectClassRawValue != IOSToolEffectClass.pure.rawValue, !autoApproved {
            let capabilities = pluginInvocationCapabilities(descriptor)
            preparedInvocations[pending.toolCall.toolCallId] = IOSPreparedPluginInvocation(
                descriptor: descriptor,
                argumentsJSON: invocationArguments,
                candidateTest: candidateTest
            )
            let payload = PluginInvocationApprovalPayload(
                toolId: descriptor.toolId,
                handler: (candidateTest == nil ? "" : "试运行 · ") + pluginHandlerTitle(descriptor.implementation),
                argumentsPreview: argumentsPreview,
                effectClass: IOSToolEffectClass(rawValue: descriptor.effectClassRawValue) ?? .sideEffect,
                capabilities: capabilities
            )
            return .waitingForApproval(.recipe(
                RecipeToolApprovalRequestBuilder.pluginInvocationRequest(
                    for: pending.toolCall,
                    pluginId: descriptor.pluginId ?? descriptor.recipeName,
                    pluginVersion: descriptor.version,
                    payload: payload
                )
            ))
        }

        let output = await executePinnedPlugin(
            descriptor: descriptor,
            argumentsJSON: invocationArguments,
            context: pending,
            bridge: bridge,
            isUserInitiated: autoApproved,
            candidateTest: candidateTest
        )
        let messages = runtime.messagesByFinishingToolCall(
            pending.toolCall,
            outputText: output,
            in: pending.baseMessages
        )
        return Self.isPluginOutcomeUnknown(output)
            ? .outcomeUnknown(messages)
            : .completed(messages)
    }

    func executeBackgroundPlugin(
        descriptor: IOSDynamicRecipeToolDescriptor,
        argumentsJSON: String,
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        runId: String,
        conversationId: KotlinUuid?,
        bridge: IosToolExposureBridge?,
        executionPolicy: IOSExecutionPolicySnapshot?
    ) async -> IOSAgentToolOutcome {
        guard descriptor.isBackgroundEligible else {
            return .denied("该插件处理器未获后台只读执行许可。")
        }
        if let issue = pluginInputIssue(argumentsJSON, matches: descriptor) {
            return .filled(ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: issue,
                status: "failed"
            ))
        }
        let toolCall = UIMessagePart.Tool(
            toolCallId: "background-plugin-\(UUID().uuidString)",
            toolName: descriptor.toolId,
            input: argumentsJSON,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let context = ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: providerSetting,
            params: params,
            runId: runId,
            startedAt: Int64(Date().timeIntervalSince1970 * 1_000),
            inputDigest: chatInputDigest(for: argumentsJSON),
            conversationId: conversationId,
            baseMessages: [],
            executionPolicy: executionPolicy
        )
        switch descriptor.implementation {
        case .javascript, .command:
            return .denied("脚本和本地命令插件不在后台白名单中。")
        case .remote:
            let output = await executePinnedPlugin(
                descriptor: descriptor,
                argumentsJSON: argumentsJSON,
                context: context,
                bridge: bridge,
                isUserInitiated: false
            )
            let part = UIMessagePart.Text(text: output, metadata: nil)
            return Self.isPluginOutcomeUnknown(output) ? .outcomeUnknown([part]) : .filled(output)
        case .recipe(let manifest):
            let inputs: [String: IOSRecipeJSONValue]
            do {
                let decoded = try JSONDecoder().decode(
                    IOSRecipeJSONValue.self,
                    from: Data(argumentsJSON.utf8)
                )
                guard case .object(let object) = decoded else {
                    return .filled(ChatToolOutputFormatter.toolFailureJSON(
                        toolName: descriptor.toolId,
                        reason: "Recipe 插件参数必须是 JSON 对象。",
                        status: "failed"
                    ))
                }
                inputs = object
            } catch {
                return .filled(ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptor.toolId,
                    reason: "Recipe 插件参数无法解析。",
                    status: "failed"
                ))
            }
            let runner = IOSRecipeRunner(
                manifest: manifest,
                artifactId: descriptor.toolId,
                catalog: IOSDynamicToolRegistry.primitiveCatalogEntry,
                executePrimitive: { [weak self] tool, argsJSON in
                    guard let self else { throw CancellationError() }
                    switch await runtime.recipeExecution.executeRecipePrimitiveStep(
                        tool: tool,
                        argsJSON: argsJSON,
                        isUserInitiated: false,
                        context: context,
                        bridge: bridge
                    ) {
                    case .output(let text): return text
                    case .failure(let reason), .needsApproval(let reason):
                        throw IOSRecipeRunError.stepFailed(stepId: "", tool: tool, message: reason)
                    case .outcomeUnknown(let text):
                        throw IOSRecipePrimitiveOutcomeUnknownError(outputText: text)
                    }
                },
                ledger: runtime.ledger,
                runId: runId
            )
            let outcome = await runner.run(inputs: inputs)
            switch outcome {
            case .succeeded(let outputs, let completedSteps):
                let output = runtime.recipeExecution.recipeResultJSON(outputs: outputs, completedSteps: completedSteps)
                _ = runtime.pluginHealthStore.recordSuccess(
                    pluginId: descriptor.pluginId ?? descriptor.recipeName,
                    packageHash: descriptor.manifestHash
                )
                return .filled(output)
            case .failed(_, let error, _):
                let output = runner.structuredErrorJSON(for: outcome)
                    ?? ChatToolOutputFormatter.toolFailureJSON(
                        toolName: descriptor.toolId,
                        reason: "后台 Recipe 插件执行失败。",
                        status: "failed"
                    )
                let kind: IOSPluginDiagnosticKind?
                switch error {
                case .stepTimeout: kind = .timeout
                case .outputResolution: kind = .schema
                case .stepFailed: kind = .exception
                case .planInvalid, .inputInvalid, .argumentBinding: kind = nil
                }
                if let pluginId = descriptor.pluginId, let kind {
                    let transition = runtime.pluginHealthStore.recordFailure(
                        pluginId: pluginId,
                        packageHash: descriptor.manifestHash,
                        toolId: descriptor.toolId,
                        kind: kind,
                        detail: output
                    )
                    if transition.didQuarantine { _ = await runtime.recipeRegistry.refresh() }
                }
                return .filled(output)
            }
        }
    }

    func finishPluginInvocationApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        prepared: IOSPreparedPluginInvocation?,
        toolExposureBridge: IosToolExposureBridge?
    ) async -> [UIMessage] {
        runtime.recordToolApproval(
            capabilityId: "ios.agent.plugin_execution",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved plugin invocation." : "User denied plugin invocation.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        let output: String
        if !allow {
            output = ChatToolOutputFormatter.toolFailureJSON(
                toolName: pending.toolCall.toolName,
                reason: "用户拒绝执行插件工具。",
                denied: true
            )
        } else if let prepared,
                  pluginInputIssue(prepared.argumentsJSON ?? pending.toolCall.input, matches: prepared.descriptor) == nil {
            output = await executePinnedPlugin(
                descriptor: prepared.descriptor,
                argumentsJSON: prepared.argumentsJSON ?? pending.toolCall.input,
                context: pending,
                bridge: toolExposureBridge,
                isUserInitiated: true,
                candidateTest: prepared.candidateTest
            )
        } else {
            output = ChatToolOutputFormatter.toolFailureJSON(
                toolName: pending.toolCall.toolName,
                reason: "插件执行上下文已失效，请重新发起调用。",
                status: "failed"
            )
        }
        return runtime.messagesByFinishingToolCall(
            pending.toolCall,
            outputText: output,
            in: pending.baseMessages
        )
    }

    private func executePinnedPlugin(
        descriptor: IOSDynamicRecipeToolDescriptor,
        argumentsJSON: String,
        context: ChatPendingToolApproval,
        bridge: IosToolExposureBridge?,
        isUserInitiated: Bool,
        candidateTest: IOSPluginTestContext? = nil
    ) async -> String {
        let output = await executePinnedPluginBody(
            descriptor: descriptor,
            argumentsJSON: argumentsJSON,
            context: context,
            bridge: bridge,
            isUserInitiated: isUserInitiated
        )
        if let candidateTest { return candidateTest.resultJSON(output) }
        await recordPluginHealth(output: output, descriptor: descriptor)
        return output
    }

    private func executePinnedPluginBody(
        descriptor: IOSDynamicRecipeToolDescriptor,
        argumentsJSON: String,
        context: ChatPendingToolApproval,
        bridge: IosToolExposureBridge?,
        isUserInitiated: Bool
    ) async -> String {
        switch descriptor.implementation {
        case .recipe:
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: "Recipe 插件处理器进入了错误的执行路径。",
                status: "failed"
            )
        case .javascript(let source, let hostTools):
            guard let broker = descriptor.capabilityBroker else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptor.toolId,
                    reason: "插件能力 Broker 不可用。",
                    status: "failed"
                )
            }
            let hostCallState = IOSPluginHostCallState()
            let toolDescriptions = Dictionary(uniqueKeysWithValues: hostTools.map { ($0, "插件声明的主机工具") })
            let tools = IOSJsSandboxTools(
                availableToolNames: hostTools.sorted(),
                hostCall: { [weak self] tool, argsJSON in
                    guard let self else {
                        hostCallState.fail("插件运行时已释放。")
                        return nil
                    }
                    if let reason = broker.authorize(tool: tool, argumentsJSON: argsJSON) {
                        NSLog("[IOSPluginRuntime] capability denied plugin=\(broker.pluginId) tool=\(tool): \(reason)")
                        hostCallState.fail("主机工具 \(tool) 被能力代理拒绝：\(reason)")
                        return nil
                    }
                    hostCallState.markStarted()
                    switch await runtime.recipeExecution.executeRecipePrimitiveStep(
                        tool: tool,
                        argsJSON: argsJSON,
                        isUserInitiated: isUserInitiated,
                        context: context,
                        bridge: bridge
                    ) {
                    case .output(let text): return text
                    case .failure(let reason):
                        hostCallState.fail("主机工具 \(tool) 失败：\(reason)")
                        return nil
                    case .needsApproval(let reason):
                        hostCallState.fail("主机工具 \(tool) 仍需批准：\(reason)")
                        return nil
                    case .outcomeUnknown(let reason):
                        hostCallState.fail(
                            "主机工具 \(tool) 的结果未知：\(reason)",
                            mayHaveApplied: true
                        )
                        return nil
                    }
                },
                toolDescriptions: toolDescriptions
            )
            guard let inputLiteral = Self.javascriptStringLiteral(argumentsJSON) else {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptor.toolId,
                    reason: "插件参数无法安全注入脚本。",
                    status: "failed"
                )
            }
            let wrapped = """
            (function () {
              'use strict';
              const input = JSON.parse(\(inputLiteral));
              return (function (input) {
            \(source)
              })(input);
            })()
            """
            let result = await runtime.jsSandboxEngine.evaluate(
                code: wrapped,
                timeoutMs: descriptor.timeoutMs,
                maxOutputChars: descriptor.maxOutputChars,
                tools: tools,
                store: nil,
                restrictedPluginMode: true
            )
            let hostState = hostCallState.snapshot()
            if let failure = hostState.failure {
                return pluginHostFailurePayload(failure, descriptor: descriptor)
            }
            switch result {
            case .success(let raw, let logs):
                return pluginOutputPayload(
                    rawJSON: raw,
                    logs: logs,
                    descriptor: descriptor
                )
            case .failure(let message):
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptor.toolId,
                    reason: "插件脚本失败：\(message)",
                    status: "failed"
                )
            case .timedOut(let timeoutMs):
                if hostState.started,
                   descriptor.effectClassRawValue == IOSToolEffectClass.sideEffect.rawValue {
                    return pluginHostFailurePayload(
                        IOSPluginHostCallFailure(
                            reason: "插件脚本在主机操作开始后超时，结果无法确认。",
                            mayHaveApplied: true
                        ),
                        descriptor: descriptor
                    )
                }
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptor.toolId,
                    reason: "插件脚本在 \(timeoutMs) ms 后超时；本次结果已丢弃。",
                    status: "timeout"
                )
            }
        case .command(let source):
            do {
                if let reason = pluginCommandAvailabilityIssue(source) {
                    throw IOSPluginCommandError.unavailable(reason)
                }
                let invocation = try IOSPluginCommandBuilder.build(
                    source: source.source, manifest: source.manifest,
                    inputObject: ChatToolCallParsing.jsonObject(argumentsJSON) ?? [:],
                    timeoutMs: descriptor.timeoutMs
                )
                let call = UIMessagePart.Tool(
                    toolCallId: "plugin-command-\(UUID().uuidString)",
                    toolName: invocation.toolName, input: invocation.argumentsJSON,
                    output: [], approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil, metadata: nil
                )
                let output = await runtime.ishToolExecutionOutput(call, isUserInitiated: isUserInitiated)
                let text = ChatToolOutputFormatter.ishHandoffResultText(for: call, output: output)
                // Preserve stderr, exit status and unknown-after-action markers
                // so the author can diagnose failures without unsafe retries.
                if ChatToolCallParsing.jsonObject(text)?["ok"] as? Bool == false { return text }
                let raw = try IOSPluginCommandBuilder.parseOutput(text, outputType: descriptor.outputType)
                return pluginOutputPayload(rawJSON: raw, logs: [], descriptor: descriptor)
            } catch {
                return ChatToolOutputFormatter.toolFailureJSON(
                    toolName: descriptor.toolId, reason: error.localizedDescription, status: "failed"
                )
            }
        case .remote(let remote):
            return await executePluginRemote(
                remote,
                descriptor: descriptor,
                argumentsJSON: argumentsJSON
            )
        }
    }

    private func recordPluginHealth(
        output: String,
        descriptor: IOSDynamicRecipeToolDescriptor
    ) async {
        guard let pluginId = descriptor.pluginId,
              let object = ChatToolCallParsing.jsonObject(output) else { return }
        if object["ok"] as? Bool == true {
            _ = runtime.pluginHealthStore.recordSuccess(pluginId: pluginId, packageHash: descriptor.manifestHash)
            return
        }
        let status = object["status"] as? String ?? ""
        let errorCode = object["error_code"] as? String ?? ""
        let reason = (object["reason"] as? String) ?? (object["error"] as? String) ?? "插件运行失败。"
        let kind: IOSPluginDiagnosticKind?
        if status == "timeout" || status == "timed_out" || errorCode == "step_timeout" || reason.localizedCaseInsensitiveContains("超时") {
            kind = .timeout
        } else if errorCode == "output_resolution" || reason.contains("输出不符合") || reason.contains("输出超过") {
            kind = .schema
        } else if reason.contains("插件脚本失败") {
            kind = .exception
        } else if reason.contains("远端插件") {
            kind = .remote
        } else if case .command = descriptor.implementation,
                  status == "failed",
                  object["runtime"] as? String != nil {
            kind = .exception
        } else {
            kind = nil
        }
        guard let kind else { return }
        let transition = runtime.pluginHealthStore.recordFailure(
            pluginId: pluginId,
            packageHash: descriptor.manifestHash,
            toolId: descriptor.toolId,
            kind: kind,
            detail: reason
        )
        if transition.didQuarantine {
            NSLog("[IOSPluginRuntime] quarantined plugin=\(pluginId) hash=\(descriptor.manifestHash)")
            _ = await runtime.recipeRegistry.refresh()
        }
    }

    private func pluginRequiresHighRiskApproval(
        _ descriptor: IOSDynamicRecipeToolDescriptor
    ) -> Bool {
        switch descriptor.implementation {
        case .recipe:
            return false
        case .command:
            return true
        case .remote:
            return descriptor.effectClassRawValue == IOSToolEffectClass.sideEffect.rawValue
        case .javascript(_, let hostTools):
            return hostTools.contains { tool in
                IOSCapabilityRegistry.capability(forToolName: tool)?.risk == .high
            }
        }
    }

    private func pluginHostFailurePayload(
        _ failure: IOSPluginHostCallFailure,
        descriptor: IOSDynamicRecipeToolDescriptor
    ) -> String {
        IOSWorkspaceStore.json([
            "ok": false,
            "tool": descriptor.toolId,
            "status": failure.mayHaveApplied ? "outcome_unknown" : "failed",
            "reason": failure.reason,
            "may_have_applied": failure.mayHaveApplied,
            "retry_safe": !failure.mayHaveApplied,
        ])
    }

    private func executePluginRemote(
        _ remote: IOSPluginRemoteManifest,
        descriptor: IOSDynamicRecipeToolDescriptor,
        argumentsJSON: String
    ) async -> String {
        guard let arguments = ChatToolCallParsing.jsonObject(argumentsJSON) else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: "远端插件参数必须是 JSON 对象。",
                status: "failed"
            )
        }
        var requestMayHaveApplied = false
        do {
            let raw: String
            switch remote.kind {
            case .mcp:
                guard let server = remote.server, let tool = remote.tool else {
                    throw IOSPluginRuntimeError.invalidRemoteDefinition
                }
                guard runtime.isMcpNetworkAllowed() else {
                    return ChatToolOutputFormatter.toolFailureJSON(
                        toolName: descriptor.toolId,
                        reason: "MCP 当前未启用。",
                        status: "failed"
                    )
                }
                requestMayHaveApplied = descriptor.effectClassRawValue == IOSToolEffectClass.sideEffect.rawValue
                raw = try await runtime.mcpManager.callTool(
                    serverName: server,
                    toolName: tool,
                    arguments: arguments,
                    enabledOverride: runtime.isMcpNetworkAllowed()
                )
            case .openapi:
                guard let rawURL = remote.url, var components = URLComponents(string: rawURL) else {
                    throw IOSPluginRuntimeError.invalidRemoteDefinition
                }
                let method = remote.method ?? "GET"
                if method == "GET" || method == "HEAD" {
                    let additions = try arguments.keys.sorted().map { key -> URLQueryItem in
                        URLQueryItem(name: key, value: try Self.queryValue(arguments[key]))
                    }
                    components.queryItems = (components.queryItems ?? []) + additions
                }
                guard let url = components.url else { throw IOSPluginRuntimeError.invalidRemoteDefinition }
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.timeoutInterval = TimeInterval(descriptor.timeoutMs) / 1_000
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                if method != "GET" && method != "HEAD" {
                    let body = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
                    guard body.count <= IOSPluginLimits.maxFileBytes else {
                        throw IOSPluginRuntimeError.requestTooLarge
                    }
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = TimeInterval(descriptor.timeoutMs) / 1_000
                let validated = try IOSSearchExecutor.allowedPublicHTTPURL(from: url.absoluteString)
                guard let host = validated.host else { throw IOSPluginRuntimeError.invalidRemoteDefinition }
                let addresses = try await Task.detached(priority: .userInitiated) {
                    try IOSSearchExecutor.resolveIPAddresses(host)
                }.value
                guard !addresses.isEmpty, addresses.allSatisfy(IOSPublicURLPolicy.publicHostAllowed) else {
                    throw IOSSearchExecutorError.disallowedURL("plugin endpoint resolves to a non-public address")
                }
                let loader = IOSBoundedPublicURLSessionLoader(
                    configuration: configuration,
                    maximumResponseBytes: descriptor.maxOutputChars * 4,
                    requiresHTTPS: true,
                    resolveHost: IOSSearchExecutor.resolveIPAddresses,
                    allowedRedirectDomains: descriptor.capabilityBroker?.capabilities.networkDomains
                )
                requestMayHaveApplied = descriptor.effectClassRawValue == IOSToolEffectClass.sideEffect.rawValue
                let (http, data) = try await loader.load(request)
                guard (200..<300).contains(http.statusCode) else {
                    throw IOSPluginRuntimeError.httpStatus(http.statusCode)
                }
                raw = data.isEmpty ? "null" : (String(data: data, encoding: .utf8) ?? "")
            }
            return pluginOutputPayload(rawJSON: raw, logs: [], descriptor: descriptor)
        } catch {
            if requestMayHaveApplied, !Self.isMcpLocalPreflightFailure(error) {
                return pluginHostFailurePayload(
                    IOSPluginHostCallFailure(
                        reason: "远端插件请求发出后失败，服务端结果无法确认：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)",
                        mayHaveApplied: true
                    ),
                    descriptor: descriptor
                )
            }
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: "远端插件调用失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)",
                status: "failed"
            )
        }
    }

    private static func isMcpLocalPreflightFailure(_ error: Error) -> Bool {
        if error is IOSMcpManagerError { return true }
        guard let error = error as? IOSMcpClientError else { return false }
        switch error {
        case .invalidURL, .unsafeEndpoint, .serverNotFound, .serverDisabled,
             .toolNotFound, .toolDisabled, .notConnected:
            return true
        case .httpStatus, .mcpSessionExpired, .invalidResponse, .rpcError,
             .requestTimedOut, .unsupportedContent:
            return false
        }
    }

    private static func isPluginOutcomeUnknown(_ output: String) -> Bool {
        guard let object = ChatToolCallParsing.jsonObject(output) else { return false }
        return (object["status"] as? String == "outcome_unknown"
            || object["status"] as? String == "unknown_after_action")
            && object["may_have_applied"] as? Bool == true
    }

    func isPluginOutcomeUnknown(in messages: [UIMessage], toolCallId: String) -> Bool {
        for message in messages where message.role == MessageRole.assistant {
            for case let tool as UIMessagePart.Tool in message.parts
            where tool.toolCallId == toolCallId {
                for case let text as UIMessagePart.Text in tool.output
                where Self.isPluginOutcomeUnknown(text.text) {
                    return true
                }
            }
        }
        return false
    }

    private func pluginOutputPayload(
        rawJSON: String,
        logs: [String],
        descriptor: IOSDynamicRecipeToolDescriptor
    ) -> String {
        guard let data = rawJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let typedValue = try? JSONDecoder().decode(IOSRecipeJSONValue.self, from: data) else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: "插件输出不是合法 JSON。",
                status: "failed"
            )
        }
        let outputIssues = IOSPluginJSONSchema.legacyOutputSchema(from: descriptor.outputType).validateValue(typedValue)
            + (descriptor.outputSchema?.validateValue(typedValue) ?? [])
        if let issue = outputIssues.first {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: "插件输出不符合声明：\(issue)",
                status: "failed"
            )
        }
        let object: [String: Any] = ["ok": true, "result": value, "logs": logs]
        guard let payload = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: payload, encoding: .utf8),
              text.count <= descriptor.maxOutputChars else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: descriptor.toolId,
                reason: "插件输出超过 \(descriptor.maxOutputChars) 字符上限。",
                status: "failed"
            )
        }
        return text
    }

    private func pluginInputIssue(
        _ raw: String,
        matches descriptor: IOSDynamicRecipeToolDescriptor
    ) -> String? {
        guard let value = try? JSONDecoder().decode(IOSRecipeJSONValue.self, from: Data(raw.utf8)),
              case .object = value else { return "插件参数必须是合法的 JSON 对象。" }
        let schema = descriptor.inputSchema
            ?? IOSPluginJSONSchema.legacyInputSchema(from: descriptorInputTypes(descriptor))
        return schema.validateValue(value).first.map { "插件参数不符合声明：\($0)" }
    }

    private func descriptorInputTypes(_ descriptor: IOSDynamicRecipeToolDescriptor) -> [String: IOSRecipeInputType] {
        switch descriptor.implementation {
        case .recipe(let manifest): manifest.inputs
        case .javascript, .remote, .command:
            (try? JSONDecoder().decode(
                [String: IOSRecipeInputType].self,
                from: Data(descriptor.inputsJSON.utf8)
            )) ?? [:]
        }
    }

    private func pluginInvocationCapabilities(_ descriptor: IOSDynamicRecipeToolDescriptor) -> [String] {
        switch descriptor.implementation {
        case .recipe: []
        case .javascript(_, let hostTools): hostTools.sorted()
        case .command(let source): [source.manifest.runtime.permissionSummary, "入口：\(source.manifest.entry)"]
        case .remote(let remote):
            switch remote.kind {
            case .mcp: ["MCP \(remote.server ?? "?")/\(remote.tool ?? "?")"]
            case .openapi: ["\(remote.method ?? "GET") \(remote.url ?? "?")"]
            }
        }
    }

    private func pluginHandlerTitle(_ implementation: IOSPluginToolImplementation) -> String {
        switch implementation {
        case .recipe: "Recipe"
        case .javascript: "受限 JavaScript"
        case .command(let source): source.manifest.runtime.title
        case .remote(let remote): remote.kind == .mcp ? "MCP 适配" : "OpenAPI 适配"
        }
    }

    private static func javascriptStringLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func pluginCommandAvailabilityIssue(_ source: IOSPluginCommandSource) -> String? {
        if source.manifest.runtime == .amberShell, source.manifest.entry.hasSuffix(".py"),
           !IOSAmberShellEngine.supportedCommands.contains("python") {
            return "当前构建未包含 AmberShell Python，无法执行该 .py 插件入口。"
        }
        #if !ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
        if source.manifest.runtime == .ish {
            return "当前构建未包含嵌入 iSH；该插件需要 ExperimentalGPL 运行环境。"
        }
        #endif
        return nil
    }

    private static func queryValue(_ value: Any?) throws -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// One `recipe__<name>` call, resolved against the ROUND's pinned catalog
    /// snapshot (never the live store): the manifest for execution is the
    /// snapshot's immutable copy, so a promotion/rollback during the call
    /// cannot retarget it (§13.3). Steps run through the EXISTING per-tool
    /// execution paths (no duplicated tool implementations); a mutation step
    /// pauses the whole call at the existing approval machinery (invariant 11).
    func finishPluginImportApproval(
        pending: ChatPendingToolApproval,
        allow: Bool,
        prepared: IOSPreparedPluginImport?
    ) async -> [UIMessage] {
        runtime.recordToolApproval(
            capabilityId: "ios.agent.plugin_import",
            toolCall: pending.toolCall,
            action: allow ? .allowed : .denied,
            reason: allow ? "User approved plugin import." : "User denied plugin import.",
            runId: pending.runId,
            executionPolicy: pending.executionPolicy
        )
        let resultText: String
        if allow, let prepared {
            do {
                resultText = try await runtime.pluginToolService.applyPreparedPluginImport(prepared)
            } catch {
                resultText = ChatToolOutputFormatter.toolFailureJSON(
                    toolName: pending.toolCall.toolName,
                    reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    status: "failed"
                )
            }
        } else if allow {
            resultText = ChatToolOutputFormatter.toolFailureJSON(
                toolName: pending.toolCall.toolName,
                reason: "插件导入预览已失效，请重新预览。",
                status: "failed"
            )
        } else {
            resultText = "用户拒绝导入插件。"
        }
        return runtime.messagesByFinishingToolCall(
            pending.toolCall,
            outputText: resultText,
            in: pending.baseMessages
        )
    }

    /// Builds the production primitive executor: every step routes back to
    /// this runtime's EXISTING per-tool execution paths (workspace/search/
    /// iSH/webMount/memory/advanced/skill/discovery), never a duplicated
    /// implementation. `isUserInitiated: true` is the post-approval contract
    /// (the user already approved the step's card).
}
