import XCTest
import WebKit
import CryptoKit
@preconcurrency import Shared
@testable import iosApp

/// Shared runtime, approval, and persistence harness for recipe integration suites.
@MainActor
class IOSRecipeIntegrationTestCase: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
    }

    // MARK: - Fixtures

    /// XCTUnwrap cannot take `await` in its autoclosure; this wrapper keeps
    /// `unwrapSnapshot(await registry.refresh())` readable at call sites.
    func unwrapSnapshot(
        _ value: IOSDynamicToolCatalogSnapshot?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> IOSDynamicToolCatalogSnapshot {
        try XCTUnwrap(value, file: file, line: line)
    }

    func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-recipe-integration-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    func makeStore(root: URL) -> IOSRecipeFileStore {
        IOSRecipeFileStore(baseDirectory: root)
    }

    func makeRegistry(store: IOSRecipeFileStore) -> IOSDynamicToolRegistry {
        IOSDynamicToolRegistry(baseDirectory: store.recipesDirectory.deletingLastPathComponent())
    }

    func makeDatabase(root: URL) -> (db: AgentRuntimeDatabase, dao: AgentRuntimeDao) {
        // The temp directory MUST exist before Room creates the DB file.
        let path = root.appendingPathComponent("agent_runtime.db").path
        let db = IosDatabaseFactory.shared.createDatabase(atFilePath: path)
        return (db, db.agentRuntimeDao())
    }

    func seedDurableRun(_ runId: String, dao: AgentRuntimeDao) async throws {
        let started = try await IOSDurableRunStore(dao: dao).startChatRun(
            runId: runId,
            startedAt: 1,
            inputDigest: "recipe-integration-test",
            conversationId: "recipe-integration-test"
        )
        XCTAssertTrue(started)
    }

    func makeRuntime(
        root: URL,
        ledger: IOSAgentRunLedgering,
        localToolExecutor: IOSLocalToolExecutor? = nil,
        workspaceStore: IOSWorkspaceStore? = nil,
        recipeRegistry: IOSDynamicToolRegistry? = nil
    ) -> ChatToolRuntime {
        let defaults = UserDefaults(suiteName: "recipe-runtime-\(UUID().uuidString)")!
        return ChatToolRuntime(
            settingsStore: SettingsStore(userDefaults: defaults),
            sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
            localToolExecutor: localToolExecutor,
            searchTransport: RecipeNoopSearchTransport(),
            mcpManager: IOSMcpManager(
                sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
                configStore: .shared
            ),
            workspaceStore: workspaceStore ?? .shared,
            ledger: ledger,
            recipeStoreBaseDirectory: root,
            recipeRegistry: recipeRegistry
        )
    }

    func makeWorkspaceStore(root: URL) -> IOSWorkspaceStore {
        IOSWorkspaceStore(baseDirectory: root.appendingPathComponent("ws", isDirectory: true))
    }

    func makeWorkspaceExecutor(
        root: URL
    ) -> (executor: IOSLocalToolExecutor, workspace: IOSWorkspaceStore, permissionStore: IOSPermissionStore) {
        let workspace = makeWorkspaceStore(root: root)
        let permissionStore = IOSPermissionStore(
            userDefaults: UserDefaults(suiteName: "recipe-perm-\(UUID().uuidString)")!
        )
        let executor = IOSLocalToolExecutor(
            permissionStore: permissionStore,
            documentStore: DocumentAccessStore(),
            workspaceStore: workspace
        )
        return (executor, workspace, permissionStore)
    }

    func makeRecipeToolCall(name: String, input: String) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: "tc-\(name)-\(UUID().uuidString)",
            toolName: name,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    func pendingContext(
        for toolCall: UIMessagePart.Tool,
        runId: String,
        conversationId: KotlinUuid? = nil,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) -> ChatPendingToolApproval {
        ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: makeProviderSetting(),
            params: makeParams(tools: []),
            runId: runId,
            startedAt: 1,
            inputDigest: "digest",
            conversationId: conversationId,
            baseMessages: [makeAssistantMessage(parts: [toolCall])],
            executionPolicy: executionPolicy ?? manualApprovalPolicy
        )
    }

    func resolveRecipeApproval(
        runtime: ChatToolRuntime,
        ledger: IOSAgentRunLedgering,
        request: RecipeToolApprovalRequest,
        decision: ChatKernelApprovalDecision,
        toolCall: UIMessagePart.Tool,
        runId: String,
        toolExposureBridge: IosToolExposureBridge? = nil,
        executionPolicy: IOSExecutionPolicySnapshot? = nil,
        callbacks: ChatRunKernelAdapter.Callbacks = .init()
    ) async -> ChatRunKernelAdapter.ApprovalResolution {
        let pending = pendingContext(
            for: toolCall,
            runId: runId,
            executionPolicy: executionPolicy
        )
        var candidates = ChatRunKernelAdapter.PreparedApprovalCandidates()
        var directRuntimeApprovalEffect: IOSToolEffectClass?
        switch request.payload {
        case .recipeImport:
            if request.isPluginImport {
                candidates.pluginImport = runtime.takePreparedPluginImportForApproval(toolCallId: toolCall.toolCallId)
                directRuntimeApprovalEffect = .sideEffect
            } else {
                candidates.recipeImport = runtime.takePreparedRecipeImportForApproval(toolCallId: toolCall.toolCallId)
            }
        case .pluginInvocation(let payload):
            candidates.pluginInvocation = runtime.takePreparedPluginInvocationForApproval(
                toolCallId: toolCall.toolCallId
            )
            directRuntimeApprovalEffect = payload.effectClass
        case .step:
            candidates.recipeExecution = runtime.takePreparedRecipeExecution(
                toolCallId: toolCall.toolCallId
            )
            directRuntimeApprovalEffect = .sideEffect
        }
        // Production executeBatch has already closed its Started attempt as
        // paused_for_approval. These tests enter through ChatToolRuntime
        // directly, so seed the same durable state before resolving.
        let existing = await ledger.toolTransactions(runId: runId)?
            .contains { $0.toolCallId == toolCall.toolCallId } == true
        if let effectClass = directRuntimeApprovalEffect, !existing {
            let argsDigest = chatInputDigest(for: toolCall.input)
            _ = await ledger.recordToolCallPrepared(
                runId: runId,
                toolCallId: toolCall.toolCallId,
                toolName: toolCall.toolName,
                argsDigest: argsDigest,
                effectClass: effectClass
            )
            _ = await ledger.recordToolCallStarted(
                runId: runId,
                toolCallId: toolCall.toolCallId,
                toolName: toolCall.toolName,
                argsDigest: argsDigest,
                effectClass: effectClass
            )
            _ = await ledger.recordToolCallFinished(
                runId: runId,
                toolCallId: toolCall.toolCallId,
                outcome: "paused_for_approval"
            )
        }
        let bridge = toolExposureBridge ?? IosToolExposureBridge(tools: fullIosDeclarations())
        let adapter = ChatRunKernelAdapter(runtime: runtime, ledger: ledger, callbacks: callbacks)
        let runRequest = ChatRunKernelAdapter.RunRequest(
            provider: RecipeUnusedProvider(),
            providerSetting: pending.providerSetting,
            params: pending.params,
            runId: runId,
            startedAt: pending.startedAt,
            inputDigest: pending.inputDigest,
            conversationId: pending.conversationId,
            initialMessages: pending.baseMessages,
            toolExposureBridge: bridge,
            maxToolResumeCount: 1,
            drainSteer: nil,
            mailboxDrain: nil,
            citationTracker: nil,
            prepareUploadMessages: nil,
            nestedToolRunner: nil,
            approvalDecider: { _ in nil }
        )
        return await adapter.resolveApproval(
            prompt: .recipe(request),
            decision: decision,
            pending: pending,
            candidates: candidates,
            request: runRequest
        )
    }

    func executeRecipeCall(
        runtime: ChatToolRuntime,
        toolCall: UIMessagePart.Tool,
        snapshot: IOSDynamicToolCatalogSnapshot?,
        bridge: IosToolExposureBridge?,
        runId: String,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) async -> ChatToolRuntimeResult {
        let pending = pendingContext(
            for: toolCall,
            runId: runId,
            executionPolicy: executionPolicy ?? manualApprovalPolicy
        )
        return await runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: toolCall),
            context: pending,
            toolExposureBridge: bridge,
            recipeCatalogSnapshot: snapshot
        )
    }

    var manualApprovalPolicy: IOSExecutionPolicySnapshot {
        IOSExecutionPolicySnapshot(
            capabilityPolicies: [:],
            globalAutoApproveEnabled: false,
            highRiskAutoApproveEnabled: false,
            execJavaScriptEnabled: false,
            webSearchEnabled: true,
            mcpEnabled: true
        )
    }

    @discardableResult
    func apply(store: IOSRecipeFileStore, json: Data) throws -> String {
        let prep = try store.prepareRecipe(recipeJSON: json)
        let receipt = try store.applyRecipe(
            name: prep.candidate.name,
            recipeJSON: json,
            expectedBaseHash: prep.base?.hash,
            expectedCandidateHash: prep.candidate.hash
        )
        return receipt.promotedHash
    }

    func seedWorkspaceRecipe(
        workspace: IOSWorkspaceStore,
        json: Data,
        workspacePath: String = "/workspace/recipes/catalog_probe/recipe.json"
    ) async throws {
        let content = String(data: json, encoding: .utf8) ?? "{}"
        let input = String(data: try JSONSerialization.data(
            withJSONObject: [
                "path": workspacePath,
                "content": content,
                "overwrite": true,
            ] as [String: Any]
        ), encoding: .utf8) ?? "{}"
        let result = await workspace.executeTool(toolName: "workspace_file_write", input: input)
        XCTAssertTrue(result.contains(#""ok":true"#), result)
    }

    func makeProviderSetting() -> ProviderSetting.OpenAI {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "recipe-test",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
    }

    func makeParams(tools: [Tool]) -> TextGenerationParams {
        let model = Model(
            modelId: "test-model",
            displayName: "test-model",
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
        return TextGenerationParams(
            model: model,
            temperature: KotlinFloat(value: 0.7),
            topP: nil,
            maxTokens: nil,
            tools: tools,
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
    }

    func makeMessage(role: MessageRole, parts: [UIMessagePart]) -> UIMessage {
        let now = Kotlinx_datetimeLocalDateTime(
            year: 2026, month: 8, day: 12, hour: 0, minute: 0, second: 0, nanosecond: 0
        )
        return UIMessage(
            id: KotlinUuid.companion.random(),
            role: role,
            parts: parts,
            annotations: [],
            createdAt: now,
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    func userMessage(_ text: String) -> UIMessage {
        makeMessage(role: MessageRole.user, parts: [UIMessagePart.Text(text: text, metadata: nil)])
    }

    func assistantText(_ text: String) -> UIMessage {
        makeMessage(role: MessageRole.assistant, parts: [UIMessagePart.Text(text: text, metadata: nil)])
    }

    func makeAssistantMessage(parts: [UIMessagePart]) -> UIMessage {
        makeMessage(role: MessageRole.assistant, parts: parts)
    }

    func toolCallMessage(toolCallId: String, toolName: String, input: String) -> UIMessage {
        makeMessage(
            role: MessageRole.assistant,
            parts: [UIMessagePart.Tool(
                toolCallId: toolCallId,
                toolName: toolName,
                input: input,
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )]
        )
    }

    func fullIosDeclarations() -> [Tool] {
        let names =
            IOSWorkspaceToolCatalog.supportedToolNames
            .union(IOSAgentTerminalToolCatalog.supportedToolNames)
            .union(IOSWebMountToolCatalog.supportedToolNames)
            .union(IOSSkillToolCatalog.toolNames)
            .union(IOSRecipeToolCatalog.toolNames)
            .union(IOSPluginToolCatalog.toolNames)
            .union(IOSMcpManagementToolCatalog.toolNames)
            .union([
                "search_web", "scrape_web", "memory_tool", "generate_image",
                "mcp_call", "subagent_dispatch", "model_council_run", "ask_user",
                "spawn_agent", "list_agents", "interrupt_agent", "send_message",
                "followup_task", "wait_agent", "session_search", "session_read",
                "exec", "wait", "tools_list", "subagent_report",
                "permissions_status", "file_read_selected",
            ])
        return ToolKt.iosToolDeclarations(names: Array(names).sorted())
    }

    func jsonData(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    func parse(_ text: String) throws -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func toolOutputText(in messages: [UIMessage], toolCallId: String) -> String? {
        for message in messages {
            for part in message.parts {
                guard let tool = part as? UIMessagePart.Tool, tool.toolCallId == toolCallId else { continue }
                let text = tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }

    func toolSearchHitNames(_ output: String) -> [String] {
        guard let object = try? parse(output),
              let tools = object["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { $0["name"] as? String }
    }

    func searchHit(_ output: String, name: String) -> [String: Any]? {
        guard let object = try? parse(output),
              let tools = object["tools"] as? [[String: Any]] else { return nil }
        return tools.first { ($0["name"] as? String) == name }
    }

    func parsedPayload(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func checkpointFileCount(_ directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? 0
    }

    /// The `approval_denied` event is written fire-and-forget by the runtime
    /// (same tier as Finished); poll briefly until it lands.
    func waitForApprovalDenied(runId: String, dao: AgentRuntimeDao) async -> [LedgerRowSnapshot] {
        for _ in 0..<40 {
            let rows = await ledgerRows(runId: runId, dao: dao)
            if rows.contains(where: { $0.type == IOSAgentRunLedger.approvalDeniedEventType }) {
                return rows
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await ledgerRows(runId: runId, dao: dao)
    }

    func ledgerRows(runId: String, dao: AgentRuntimeDao) async -> [LedgerRowSnapshot] {
        await withCheckedContinuation { continuation in
            dao.listEventsForRun(id: runId) { result, error in
                guard error == nil, let result else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: result.map {
                    LedgerRowSnapshot(type: $0.type, seq: $0.seq, payload: $0.payload)
                })
            }
        }
    }

    func directorySnapshot(_ root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) else {
            return []
        }
        var entries: [String] = []
        while let item = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
            let kind = isDirectory.boolValue ? "dir" : "file"
            entries.append("\(kind):\(item.lastPathComponent)")
        }
        return entries.sorted()
    }
}
