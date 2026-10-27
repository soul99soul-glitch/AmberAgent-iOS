import Foundation
import CryptoKit
@preconcurrency import Shared

// Adapter only: the existing iOS engine owns every model/tool round.
@MainActor final class DesktopAgentProvider: DesktopTextProvider {
    private let text: DesktopKMPProvider
    private let tasks: DesktopAgentTasks
    private let files: DesktopWorkspaceFiles
    private let knowledge: DesktopKnowledgeStore
    private let mcp: DesktopMCPManager
    private let collaborations: DesktopCollaborations
    private let searchSettings: DesktopSearchSettings
    private var recipeExecutors: [UUID: DesktopAgentExecutor] = [:]

    init(text: DesktopKMPProvider, tasks: DesktopAgentTasks, files: DesktopWorkspaceFiles,
        knowledge: DesktopKnowledgeStore, mcp: DesktopMCPManager, collaborations: DesktopCollaborations,
        searchSettings: DesktopSearchSettings) {
        self.text = text; self.tasks = tasks; self.files = files; self.knowledge = knowledge; self.mcp = mcp
        self.collaborations = collaborations
        self.searchSettings = searchSettings
        collaborations.toolRunner = { [weak self] request, onSteps in
            guard let self else { throw DesktopRuntimeError.message("协作运行时已释放。") }
            return try self.runCollaborationMember(request, onSteps: onSteps)
        }
    }

    // Sub-agent members run the same engine with a frozen read-only registry and no approval pauses.
    private func runCollaborationMember(_ request: DesktopCollaborationToolRequest,
        onSteps: @escaping @MainActor @Sendable ([DesktopCollaborationOutput.Step]) -> Void) throws -> DesktopGeneration {
        guard let model = request.configuration.selectedModel else { throw DesktopRuntimeError.message("请先选择模型。") }
        let bridge = DesktopProviderBridge.shared
        let configuration = request.configuration
        let baseURL = configuration.authMode == .grokOAuth ? IOSGrokOAuthConstants.cliProxyBaseUrl : configuration.baseURL
        let provider = try bridge.configurationWithAuth(kind: configuration.kind.rawValue, id: configuration.id.uuidString,
            name: configuration.name, baseUrl: baseURL, apiKey: request.apiKey, authMode: configuration.authMode.rawValue)
        let declarations = DesktopToolRegistry.declarations.filter { request.toolNames.contains($0.name) } + [DesktopSubagentToolPolicy.reportDeclaration]
        let tools = try bridge.declarations(json: Self.schemaJSON(declarations))
        let exposure = IosToolExposureBridge(tools: tools)
        exposure.exposeToolNames(names: declarations.map(\.name))
        let skills = request.skillNames.compactMap { name in knowledge.skills.first { $0.name == name && $0.enabled } }
            .map { "已加载技能 \($0.name)：\n" + DesktopKnowledgeStore.skillBody($0.markdown) }
        let system = ([request.systemPrompt] + skills).joined(separator: "\n\n")
        let user = "目标：\n\(request.objective)\n\n可用工具：\(declarations.map(\.name).joined(separator: ", "))"
        let inputJSON = try DesktopJSON.encode([DesktopMessage(role: .system, text: system), DesktopMessage(role: .user, text: user)])
        let params = try bridge.paramsFromJSON(json: DesktopJSON.encode(model)).replacingTools(exposure.visibleTools())
        let executor = DesktopAgentExecutor(runID: UUID(), owner: request.ownerID, tasks: tasks, files: files, knowledge: knowledge,
            mcp: mcp, declarations: declarations, exposure: exposure, sourceMessageIDs: [], collaborations: collaborations,
            searchSettings: searchSettings)
        let report = DesktopSubagentReportExecutor()
        var registry = Dictionary(uniqueKeysWithValues: request.toolNames.map { ($0, executor as any IOSToolExecutor) })
        registry[DesktopSubagentToolPolicy.reportToolName] = report
        let engine = IOSAgentToolEngine(provider: DesktopEngineTransport(), executors: registry,
            configuration: .init(maxSteps: request.maxSteps, honorApprovalPause: false))
        let generation = DesktopGeneration(cancellationCompletesAsynchronously: true)
        let task = Task {
            // Built inside the task so the engine receives a disconnected message list.
            guard let input = try? DesktopProviderBridge.shared.messages(json: inputJSON) else {
                generation.yield(.failed("无法构造子代理请求。")); return
            }
            let result = await engine.run(providerSetting: provider, messages: input, params: params, onMessagesUpdated: { messages in
                let steps = Self.steps(messages)
                Task { @MainActor in onSteps(steps) }
            })
            onSteps(Self.steps(result.messages))
            if result.wasCancelled || Task.isCancelled { generation.yield(.cancelled); return }
            guard result.providerFailureMessage == nil, result.durabilityFailureMessage == nil, result.toolOutcomeUnknown == nil,
                  result.pendingApproval == nil, !result.guardStopped, !result.hitStepLimit else {
                generation.yield(.failed("子代理未能完成。")); return
            }
            let fallback = result.messages.last { $0.role == .assistant }?.parts
                .compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n") ?? ""
            generation.yield(.snapshot(text: report.captured ?? fallback, reasoning: ""))
            generation.yield(.complete)
        }
        generation.installCancellation { task.cancel() }
        return generation
    }

    nonisolated private static func steps(_ messages: [UIMessage]) -> [DesktopCollaborationOutput.Step] {
        messages.filter { $0.role == .assistant }.flatMap(\.parts).compactMap { part -> DesktopCollaborationOutput.Step? in
            if let tool = part as? UIMessagePart.Tool {
                let output = tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n")
                return .init(tool: tool.toolName, arguments: String(tool.input.prefix(200)), result: String(output.prefix(300)))
            }
            guard let text = (part as? UIMessagePart.Text)?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return .init(text: String(text.prefix(600)))
        }
    }

    func userMessage(id: UUID, text: String, attachments: [DesktopMessageAttachment]) throws -> DesktopMessage {
        try self.text.userMessage(id: id, text: text, attachments: attachments)
    }

    func start(configuration: DesktopProviderConfiguration, apiKey: String,
        messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
        try text.start(configuration: configuration, apiKey: apiKey, messages: messages, responseID: responseID)
    }

    func start(configuration: DesktopProviderConfiguration, apiKey: String,
        messages: [DesktopMessage], responseID: UUID, context: DesktopRunContext) throws -> DesktopGeneration {
        guard context.engineEnabled else { return try start(configuration: configuration, apiKey: apiKey, messages: messages, responseID: responseID) }
        guard let persistTurns = context.persistTurns else { throw DesktopRuntimeError.message("工具任务必须关联可保存的会话。") }
        guard let model = configuration.selectedModel else { throw DesktopRuntimeError.message("请先选择模型。") }
        let bridge = DesktopProviderBridge.shared
        // Grok OAuth always targets the CLI proxy so IOSGrokWebProviderResolver recognizes it per request.
        let baseURL = configuration.authMode == .grokOAuth ? IOSGrokOAuthConstants.cliProxyBaseUrl : configuration.baseURL
        let provider = try bridge.configurationWithAuth(kind: configuration.kind.rawValue, id: configuration.id.uuidString,
            name: configuration.name, baseUrl: baseURL, apiKey: apiKey, authMode: configuration.authMode.rawValue)
        var input = try bridge.agentRequestHistory(messages: bridge.messages(json: DesktopJSON.encode(messages)))
        let declarations = DesktopToolRegistry.agentDeclarations(toolsEnabled: context.toolsEnabled,
            subagentsEnabled: context.subagentsEnabled)
        let tools = try bridge.declarations(json: Self.schemaJSON(declarations))
        let exposure = IosToolExposureBridge(tools: tools)
        let guidance = exposure.discoveryGuidance()
        if !guidance.isEmpty {
            input.insert(contentsOf: try bridge.messages(json: DesktopJSON.encode([DesktopMessage(role: .system, text: guidance)])), at: 0)
        }
        let params = try bridge.paramsFromJSON(json: DesktopJSON.encode(model)).replacingTools(exposure.visibleTools())
        let generation = DesktopGeneration(cancellationCompletesAsynchronously: true)
        let task = Task {
            var runID: UUID?
            do {
                try Task.checkCancellation()
                let id = try await tasks.begin(conversationID: context.conversationID,
                    title: messages.last(where: { $0.role == .user })?.text ?? "工具任务", cancel: { generation.cancel() })
                runID = id
                let executor = DesktopAgentExecutor(runID: id, owner: context.conversationID, tasks: tasks,
                    files: files, knowledge: knowledge, mcp: mcp, declarations: declarations, exposure: exposure,
                    sourceMessageIDs: messages.last(where: { $0.role == .user }).map { [$0.id.uuidString.lowercased()] } ?? [],
                    collaborations: collaborations, searchSettings: searchSettings, approvalPolicy: context.approvalPolicy)
                let sink = DesktopEngineTranscript(input: input, responseID: responseID, generation: generation)
                let ledger = DesktopEngineLedger(tasks: tasks, runID: id)
                let result = await self.resume(provider: provider, messages: input, params: params, exposure: exposure,
                    executor: executor, sink: sink, ledger: ledger, runID: id, budget: 8,
                    persistTurns: persistTurns, drainSteer: context.drainSteer)
                sink.update(result.messages)
                if result.toolOutcomeUnknown != nil || result.durabilityFailureMessage != nil {
                    await tasks.finish(id, status: .outcomeUnknown, error: "工具结果需要核对，请查看原会话和任务记录；不会自动重放。")
                    generation.yield(.failed("工具执行结果需要核对，已保留任务记录；请检查后继续。"))
                } else if result.wasCancelled || Task.isCancelled {
                    await tasks.finish(id, status: .cancelled)
                    generation.yield(.cancelled)
                } else if result.providerFailureMessage != nil || result.hitStepLimit || result.guardStopped || result.hitOutputLimit {
                    await tasks.finish(id, status: .failed, error: "任务已停止，请查看会话中保留的结果后继续。")
                    generation.yield(.failed("任务已停止，已收到的结果已保留。请检查模型设置或继续当前会话。"))
                } else {
                    await tasks.finish(id, status: .completed)
                    generation.yield(.complete)
                }
            } catch is CancellationError {
                if let runID { await tasks.finish(runID, status: .cancelled) }
                generation.yield(.cancelled)
            } catch {
                if let runID { await tasks.finish(runID, status: .failed, error: "无法启动或保存工具任务。") }
                generation.yield(.failed("无法启动或保存工具任务，请检查配置与存储权限后重试。"))
            }
        }
        generation.installCancellation { task.cancel() }
        return generation
    }

    func performRecipeTool(runID: UUID, owner: UUID, name: String, argumentsJSON: String) async throws -> String {
        try Task.checkCancellation()
        let declarations = DesktopToolRegistry.declarations + DesktopToolRegistry.knowledgeDeclarations + DesktopMCPManager.declarations
        guard declarations.contains(where: { $0.name == name }), name != "tool_search" else {
            throw DesktopRuntimeError.message("Recipe引用了当前未注册的工具。")
        }
        let active = Set(tasks.records.filter { $0.status == .running || $0.status == .waiting }.map(\.id))
        recipeExecutors = recipeExecutors.filter { active.contains($0.key) }
        let executor: DesktopAgentExecutor
        if let existing = recipeExecutors[runID] {
            guard existing.owner == owner else { throw DesktopRuntimeError.message("Recipe任务归属不匹配。") }
            executor = existing
        } else {
            let tools = try DesktopProviderBridge.shared.declarations(json: Self.schemaJSON(declarations))
            let exposure = IosToolExposureBridge(tools: tools)
            executor = DesktopAgentExecutor(runID: runID, owner: owner, tasks: tasks, files: files,
                knowledge: knowledge, mcp: mcp, declarations: declarations, exposure: exposure, sourceMessageIDs: [],
                collaborations: collaborations, searchSettings: searchSettings)
            recipeExecutors[runID] = executor
        }
        // A manifest names an exact primitive. Keep one skill scope for all steps of this run.
        executor.exposure.exposeToolNames(names: [name])
        let message = try DesktopProviderBridge.shared.toolInvocation(callId: UUID().uuidString, name: name, arguments: argumentsJSON)
        guard let tool = message.parts.compactMap({ $0 as? UIMessagePart.Tool }).first else {
            throw DesktopRuntimeError.message("无法构造Recipe工具调用。")
        }
        let invocation = try DesktopJSON.decode([DesktopMessage].self,
            from: DesktopProviderBridge.shared.projectMessages(messages: [message])).first?.canonicalJSON
        let ledger = DesktopEngineLedger(tasks: tasks, runID: runID)
        let prepared = await ledger.recordToolCallPrepared(runId: runID.uuidString, toolCallId: tool.toolCallId,
            toolName: tool.toolName, argsDigest: chatInputDigest(for: tool.input),
            effectClass: DesktopToolRegistry.effectClass(for: name, arguments: tool.input))
        guard case .ready = prepared else { throw DesktopRuntimeError.message("Recipe工具调用无法保存或已经执行，未再次派发。") }
        let callID = tool.toolCallId
        let record = try await tasks.journal.change(runID) {
            guard let index = $0.transactions.firstIndex(where: { $0.id == callID }) else { throw DesktopRuntimeError.message("缺少Recipe工具记录。") }
            $0.transactions[index].canonicalInvocation = invocation
        }
        tasks.publish(record)
        return try await executeRecipeBatch(messages: [message], executor: executor,
            ledger: ledger, runID: runID, names: declarations.map(\.name))
    }

    private func executeRecipeBatch(messages: sending [UIMessage], executor: DesktopAgentExecutor, ledger: DesktopEngineLedger,
        runID: UUID, names: [String]) async throws -> String {
        try Task.checkCancellation()
        let engine = IOSAgentToolEngine(provider: DesktopEngineTransport(),
            executors: Dictionary(uniqueKeysWithValues: names.map { ($0, executor as any IOSToolExecutor) }),
            ledger: ledger, ledgerRunId: runID.uuidString)
        let result = await engine.executePreExistingToolsOnly(messages: messages)
        if result.toolOutcomeUnknown != nil || result.durabilityFailureMessage != nil {
            throw DesktopRuntimeError.message("工具结果需要核对；Recipe已停止，不会自动重放。")
        }
        if let approval = result.pendingApproval {
            _ = await tasks.awaitDecision(runID: runID, toolID: approval.toolCallId)
            try Task.checkCancellation()
            return try await executeRecipeBatch(messages: result.messages, executor: executor, ledger: ledger, runID: runID, names: names)
        }
        guard let tool = result.messages.flatMap(\.parts).compactMap({ $0 as? UIMessagePart.Tool }).last,
              !tool.output.isEmpty else {
            try Task.checkCancellation()
            throw DesktopRuntimeError.message("工具未返回可确认的结果。")
        }
        return tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "\n")
    }

    private func resume(provider: ProviderSetting, messages: sending [UIMessage], params: TextGenerationParams,
        exposure: IosToolExposureBridge, executor: DesktopAgentExecutor, sink: DesktopEngineTranscript,
        ledger: DesktopEngineLedger, runID: UUID, budget: Int,
        persistTurns: @escaping @MainActor @Sendable ([DesktopMessage]) async -> Bool,
        drainSteer: (@MainActor @Sendable () async -> [DesktopMessage])?) async -> IOSAgentToolEngineResult {
        var registry = Dictionary(uniqueKeysWithValues: executor.declarations.map { ($0.name, executor as any IOSToolExecutor) })
        registry["tool_search"] = executor
        let engine = IOSAgentToolEngine(provider: DesktopEngineTransport(), executors: registry,
            configuration: .init(maxSteps: max(0, budget), honorApprovalPause: true), ledger: ledger, ledgerRunId: runID.uuidString)
        let result = await engine.run(providerSetting: provider, messages: messages, params: params,
            toolExposureBridge: exposure, drainSteer: {
                guard let drainSteer else { return [] }
                let turns = await drainSteer()
                guard !turns.isEmpty else { return [] }
                // The workspace retains leased entries until the next durable checkpoint acknowledges their IDs.
                return (try? DesktopProviderBridge.shared.messages(json: DesktopJSON.encode(turns))) ?? []
            }, prepareRequestMessages: { values in
                guard await sink.checkpoint(values, persist: persistTurns) else { throw DesktopRuntimeError.message("工具会话保存失败，后续执行已停止。") }
                return values
            }, onAssistantTurnCompleted: { await sink.checkpoint($0, persist: persistTurns) },
            onAssistantMessageSnapshot: { sink.provisional($0) }, onMessagesUpdated: { sink.update($0) })
        if let pending = result.pendingApproval, !Task.isCancelled {
            _ = await tasks.awaitDecision(runID: runID, toolID: pending.toolCallId)
            if !Task.isCancelled {
                ledger.advanceRound(by: result.stepsExecuted)
                // Resume the same pending batch through the engine. Completed calls replay their durable result.
                return await resume(provider: provider, messages: result.messages, params: params.replacingTools(exposure.visibleTools()),
                    exposure: exposure, executor: executor, sink: sink, ledger: ledger, runID: runID,
                    budget: max(0, budget - result.stepsExecuted), persistTurns: persistTurns, drainSteer: drainSteer)
            }
        }
        return result
    }

    private static func schemaJSON(_ declarations: [DesktopToolDeclaration]) throws -> String {
        let objects: [[String: Any]] = try declarations.map {
            ["name": $0.name, "description": $0.description, "needsApproval": $0.needsApproval,
             "parameters": try JSONSerialization.jsonObject(with: Data($0.parametersJSON.utf8))]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]), as: UTF8.self)
    }
}

struct DesktopEngineTransport: IOSAgentTextProvider, IOSAgentStreamingProvider {
    private let openAI = OpenAIKmpProvider()
    private let claude = ClaudeKmpProvider()

    func prepareRequest(providerSetting: ProviderSetting, params: TextGenerationParams) async throws -> (ProviderSetting, TextGenerationParams) {
        // Same identity rewrite chain as iOS ChatKernelRunHost: Codex, then Grok OAuth (token refresh + CLI proxy).
        let resolved = try await IOSGrokWebProviderResolver.resolved(try await IOSCodexProviderResolver.resolved(providerSetting))
        return (resolved, IOSGrokWebProviderResolver.augmentParamsForGrok(
            IOSCodexProviderResolver.augmentParamsForCodex(params, provider: resolved), provider: resolved))
    }

    func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
        let (provider, params) = try await prepareRequest(providerSetting: providerSetting, params: params)
        if let provider = provider as? ProviderSetting.OpenAI { return try await openAI.generateText(providerSetting: provider, messages: messages, params: params) }
        if let provider = provider as? ProviderSetting.Claude { return try await claude.generateText(providerSetting: provider, messages: messages, params: params) }
        throw DesktopRuntimeError.message("当前协议没有可用的模型调用路径。")
    }

    func streamText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams,
        onChunk: @escaping @Sendable (MessageChunk) -> Void, onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (KotlinThrowable) -> Void) -> Kotlinx_coroutines_coreJob? {
        if let provider = providerSetting as? ProviderSetting.OpenAI {
            return openAI.streamTextCancellable(providerSetting: provider, messages: messages, params: params,
                onChunk: onChunk, onComplete: onComplete, onError: onError)
        }
        if let provider = providerSetting as? ProviderSetting.Claude {
            return claude.streamTextCancellable(providerSetting: provider, messages: messages, params: params,
                onChunk: onChunk, onComplete: onComplete, onError: onError)
        }
        onError(KotlinThrowable(message: "当前协议没有可用的流式路径。"))
        return nil
    }
}

private final class DesktopSubagentReportExecutor: IOSToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var report: String?
    var captured: String? { lock.withLock { report } }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        guard let text = DesktopSubagentToolPolicy.reportText(arguments: arguments) else {
            return .failed("subagent_report 需要非空的 summary。")
        }
        lock.withLock { report = text }
        return .filled(#"{"status":"ok"}"#)
    }
}

private final class DesktopEngineTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private let inputCount: Int
    private let responseID: UUID
    private let generation: DesktopGeneration
    private var messages: [UIMessage]

    init(input: [UIMessage], responseID: UUID, generation: DesktopGeneration) {
        inputCount = input.count; messages = input; self.responseID = responseID; self.generation = generation
    }

    func update(_ messages: [UIMessage]) {
        lock.lock(); defer { lock.unlock() }
        self.messages = messages
        publish(messages)
    }

    func provisional(_ message: UIMessage) {
        lock.lock(); defer { lock.unlock() }
        let values = messages.last?.id == message.id ? Array(messages.dropLast()) + [message] : messages + [message]
        publish(values)
    }

    func checkpoint(_ values: [UIMessage], persist: @MainActor @Sendable ([DesktopMessage]) async -> Bool) async -> Bool {
        do {
            let turns = try projection(values)
            return turns.isEmpty ? true : await persist(turns)
        } catch { return false }
    }

    private func publish(_ values: [UIMessage]) {
        do {
            let projected = try projection(values)
            guard !projected.isEmpty else { return }
            generation.yield(.transcript(projected))
        } catch { generation.yield(.failed("工具消息无法读取，原始任务记录已保留。")) }
    }

    private func projection(_ values: [UIMessage]) throws -> [DesktopMessage] {
        let turns = Array(values.dropFirst(inputCount))
        var projected = try DesktopJSON.decode([DesktopMessage].self, from: DesktopProviderBridge.shared.projectMessages(messages: turns))
        if let index = turns.firstIndex(where: { $0.role == .assistant }) {
            let stable = try DesktopJSON.decode([DesktopMessage].self, from: DesktopProviderBridge.shared.snapshot(
                messages: [turns[index]], assistantId: responseID.uuidString))
            projected[index] = stable[0]
        }
        for index in projected.indices {
            projected[index].state = .agentProjection(role: projected[index].role, isLast: index == projected.count - 1)
        }
        return projected
    }
}

private final class DesktopAgentExecutor: IOSToolExecutor, @unchecked Sendable {
    let runID: UUID
    let owner: UUID
    let tasks: DesktopAgentTasks
    let files: DesktopWorkspaceFiles
    let knowledge: DesktopKnowledgeStore
    let mcp: DesktopMCPManager
    let declarations: [DesktopToolDeclaration]
    let exposure: IosToolExposureBridge
    let sourceMessageIDs: [String]
    let collaborations: DesktopCollaborations
    let searchSettings: DesktopSearchSettings
    private let scopeLock = NSLock()
    private var skillScope = DesktopSkillToolScope()
    let approvalPolicy: DesktopApprovalPolicy?

    init(runID: UUID, owner: UUID, tasks: DesktopAgentTasks, files: DesktopWorkspaceFiles,
        knowledge: DesktopKnowledgeStore, mcp: DesktopMCPManager, declarations: [DesktopToolDeclaration],
        exposure: IosToolExposureBridge, sourceMessageIDs: [String], collaborations: DesktopCollaborations,
        searchSettings: DesktopSearchSettings, approvalPolicy: DesktopApprovalPolicy? = nil) {
        self.approvalPolicy = approvalPolicy
        self.runID = runID; self.owner = owner; self.tasks = tasks; self.files = files
        self.knowledge = knowledge; self.mcp = mcp; self.declarations = declarations
        self.exposure = exposure; self.sourceMessageIDs = sourceMessageIDs
        self.collaborations = collaborations
        self.searchSettings = searchSettings
    }

    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        .failed("工具调用缺少稳定的call ID，未执行。")
    }

    func execute(tool: UIMessagePart.Tool, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        guard !Task.isCancelled else { return .denied("任务已取消，工具未执行。") }
        guard scopeLock.withLock({ skillScope.permits(tool.toolName) }) else {
            return .denied("此工具不在本次已加载技能的allowed-tools范围内，尚未执行。")
        }
        let exposed = await MainActor.run { exposure.visibleTools().contains { $0.name == tool.toolName } }
        guard exposed else { return .failed("此工具尚未暴露，请先通过tool_search发现后再调用。") }
        let effect = DesktopToolRegistry.effect(for: tool.toolName, arguments: tool.input)
        let approval = effect == .sideEffect || effect == .idempotent
        let policy = approvalPolicy
        let autoApproved = approval ? await MainActor.run { tasks.autoApproves(tool.toolName, policy: policy) } : false
        if approval, !autoApproved {
            if let decision = await tasks.decision(runID: runID, toolID: tool.toolCallId) {
                if !decision { return .denied("用户拒绝了这一次工具调用。") }
            } else {
                do {
                    try await tasks.requestApproval(runID: runID, approval: DesktopToolApproval(id: tool.toolCallId,
                        name: tool.toolName, arguments: tool.input, reason: "请核对操作内容后允许一次或拒绝。"))
                    return .needsApproval("等待用户确认这一次操作。")
                } catch { return .durabilityFailure("无法保存工具审批，工具未执行。") }
            }
        }
        do {
            try Task.checkCancellation()
            let args = try JSONSerialization.jsonObject(with: Data(tool.input.utf8)) as? [String: Any] ?? [:]
            let output: String
            switch tool.toolName {
            case "tool_search": output = await MainActor.run { exposure.executeToolSearch(argumentsJson: tool.input) }
            case "tools_list": output = await MainActor.run { exposure.executeToolsList() }
            case "workspace_file_list":
                let values = try await files.list(conversationID: owner)
                output = try Self.json(values.map { ["path": $0.id, "bytes": $0.byteCount] as [String: Any] })
            case "workspace_file_read":
                let path = try Self.string("path", args)
                let result = try await files.readUTF8Prefix(conversationID: owner, path: path, maxCharacters: 48_000)
                output = try Self.json(["ok": true, "path": path, "content": result.text, "truncated": result.truncated])
            case "workspace_file_write":
                let path = try Self.string("path", args), text = try Self.string("content", args, allowEmpty: true)
                let value = try await files.write(conversationID: owner, path: path, data: Data(text.utf8), overwrite: args["overwrite"] as? Bool == true)
                output = try Self.json(["ok": true, "path": value.id, "bytes": value.byteCount])
            case "workspace_artifact_delete":
                let path = try Self.string("path", args)
                try await files.delete(conversationID: owner, path: path)
                output = try Self.json(["ok": true, "path": path])
            case "terminal_exec":
                let directory = try await files.commandDirectory(conversationID: owner)
                let result = try await DesktopCommandRunner.run(try Self.string("command", args), directory: directory)
                output = try Self.json(["ok": result.exitCode == 0 && !result.cancelled && !result.timedOut,
                    "output": result.output, "exit_code": result.exitCode, "truncated": result.truncated,
                    "timed_out": result.timedOut, "cancelled": result.cancelled])
            case "search_web", "scrape_web":
                output = try await DesktopSearchRuntime.execute(name: tool.toolName, input: tool.input, settings: searchSettings)
            case "skills_list", "use_skill", "skill_enable", "skill_disable", "memory_tool":
                var ownedArguments = args
                if tool.toolName == "memory_tool" {
                    if args["action"] as? String == "create" {
                        ownedArguments["sourceConversationId"] = owner.uuidString.lowercased()
                        ownedArguments["sourceMessageIds"] = sourceMessageIDs
                    } else if args["action"] as? String == "edit" {
                        ownedArguments["sourceConversationId"] = nil
                        ownedArguments["sourceMessageIds"] = nil
                    }
                }
                output = try await knowledge.executeTool(name: tool.toolName, argumentsJSON: Self.json(ownedArguments))
                if tool.toolName == "use_skill", let name = args["name"] as? String {
                    let allowed = await MainActor.run { knowledge.skills.first(where: { $0.name == name && $0.enabled })?.allowedTools ?? [] }
                    scopeLock.withLock { skillScope.apply(allowed) }
                }
            case "mcp_list", "mcp_describe_tool", "mcp_call_tool":
                output = try await mcp.perform(name: tool.toolName, argumentsJSON: tool.input)
                if tool.toolName == "mcp_call_tool" {
                    return .filledParts(try await MainActor.run {
                        guard let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
                            throw DesktopRuntimeError.message("MCP结果不是JSON对象。")
                        }
                        do { return try IOSMcpClient.toolOutput(result: object).parts }
                        catch { return [UIMessagePart.Text(text: output, metadata: nil)] }
                    })
                }
            case "subagent_dispatch", "model_council_run":
                let runID: UUID
                if tool.toolName == "subagent_dispatch" {
                    let roleName = args["role"] as? String ?? "explorer"
                    guard let role = DesktopCollaborationRole.builtIns.first(where: { $0.id == roleName }) else {
                        throw DesktopRuntimeError.message("子代理角色不存在。")
                    }
                    let member = DesktopCollaborationMember(name: role.name, rolePrompt: role.prompt, modelID: try Self.modelID(args["model_id"]),
                        roleID: role.id, skillNames: args["skills"] as? [String] ?? [])
                    runID = try await collaborations.startSubagents(parentConversationID: owner, objective: Self.string("task", args), members: [member])
                } else {
                    let rawSeats = args["seats"] as? [[String: Any]] ?? []
                    let seats = try rawSeats.map { DesktopCollaborationMember(name: try Self.string("name", $0),
                        rolePrompt: try Self.string("role_prompt", $0), modelID: try Self.modelID($0["model_id"])) }
                    let mode = try (args["mode"] as? String).map {
                        guard let mode = DesktopCouncilMode(rawValue: $0) else { throw DesktopRuntimeError.message("议会模式须为 free_chat 或 debate。") }
                        return mode
                    } ?? .freeChat
                    runID = try await collaborations.startCouncil(parentConversationID: owner, objective: Self.string("objective", args),
                        seats: seats, synthesisModelID: Self.modelID(args["synthesis_model_id"]), mode: mode, rounds: args["rounds"] as? Int ?? 2)
                }
                let result = await withTaskCancellationHandler {
                    await collaborations.waitUntilFinished(runID)
                } onCancel: { Task { @MainActor [collaborations] in collaborations.cancel(runID) } }
                guard let result else { throw DesktopRuntimeError.message("协作任务未返回记录。") }
                output = try DesktopJSON.encode(result)
            case "list_agents":
                let records = await MainActor.run { collaborations.runs.filter { $0.parentConversationID == owner } }
                output = try DesktopJSON.encode(records)
            case "interrupt_agent":
                guard let id = UUID(uuidString: try Self.string("run_id", args)),
                      await MainActor.run(body: { collaborations.runs.contains { $0.id == id && $0.parentConversationID == owner } }) else {
                    throw DesktopRuntimeError.message("找不到当前会话中的协作任务。")
                }
                await collaborations.cancel(id)
                output = try Self.json(["ok": true, "run_id": id.uuidString])
            default: return .failed("当前桌面工具目录没有此执行器。")
            }
            return .filled(output)
        } catch let error as DesktopMCPOutcomeUnknown {
            return .outcomeUnknown([UIMessagePart.Text(text: error.localizedDescription, metadata: nil)])
        } catch is CancellationError { return .denied("任务已取消。") }
        catch { return .failed(error is DesktopRuntimeError ? error.localizedDescription : "工具执行失败，请检查目标文件、网络或权限。") }
    }

    private static func string(_ key: String, _ arguments: [String: Any], allowEmpty: Bool = false) throws -> String {
        guard let value = arguments[key] as? String, allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopRuntimeError.message("工具参数 \(key) 缺失。")
        }
        return value
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func modelID(_ value: Any?) throws -> UUID? {
        guard let value else { return nil }
        guard let string = value as? String, let id = UUID(uuidString: string) else { throw DesktopRuntimeError.message("模型ID必须是已配置模型的UUID。") }
        return id
    }
}

extension DesktopToolRegistry {
    static func effectClass(for name: String, arguments: String) -> IOSToolEffectClass {
        switch effect(for: name, arguments: arguments) {
        case .pure: .pure
        case .networkRead: .networkRead
        case .idempotent: .idempotent
        case .sideEffect: .sideEffect
        }
    }
}

func chatInputDigest(for text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
