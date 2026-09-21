import XCTest
@preconcurrency import Shared
@testable import iosApp

/// runtime_status：agent 运行时自省工具（Jev 模式/凭据存在性/门控/目录计数）。
/// 常驻首轮可见、本地只读、无网络、无审批——契约只允许布尔/枚举/计数/版本号，
/// 绝不回传 Key 本体或任何业务原文。
@MainActor
final class IOSRuntimeStatusToolTests: XCTestCase {

    /// runtime_status 不触发网络；transport 只记录请求（一旦触发即证明违约）。
    private final class RuntimeStatusCountingSearchTransport: IOSSearchHTTPTransport {
        private(set) var requests: [URLRequest] = []

        func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            requests.append(request)
            let http = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (http, Data())
        }
    }

    /// IOSToolExecutor 非 Sendable；后台 executor 跨 async 边界必须装箱
    /// （照 IOSSessionReadToolTests / IOSToolSearchExposureTests 同款模式）。
    private final class RuntimeStatusUncheckedToolExecutorBox: @unchecked Sendable {
        private let base: any IOSToolExecutor

        init(_ base: any IOSToolExecutor) {
            self.base = base
        }

        func execute(
            name: String,
            arguments: String,
            isUserInitiated: Bool
        ) async -> IOSAgentToolOutcome {
            await base.execute(
                name: name,
                arguments: arguments,
                isUserInitiated: isUserInitiated
            )
        }
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "IOSRuntimeStatusToolTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func localToolExecutor() -> IOSLocalToolExecutor {
        IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: DocumentAccessStore(),
            workspaceStore: IOSWorkspaceStore(
                baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            )
        )
    }

    private func makeRuntime(sharedSettings: IOSSharedSettingsStore) -> ChatToolRuntime {
        ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: RuntimeStatusCountingSearchTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
    }

    private func makeToolCall() -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: "runtime-status-\(UUID().uuidString)",
            toolName: "runtime_status",
            input: "{}",
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    private func makeAssistantMessage(parts: [UIMessagePart]) -> UIMessage {
        let seed = UIMessage.companion.assistant(prompt: "")
        return UIMessage(
            id: seed.id,
            role: seed.role,
            parts: parts,
            annotations: [],
            createdAt: seed.createdAt,
            finishedAt: seed.finishedAt,
            modelId: seed.modelId,
            usage: seed.usage,
            translation: seed.translation
        )
    }

    private func makeProviderSetting() -> ProviderSetting.OpenAI {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "runtime-status-test",
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

    private func makeParams(tools: [Tool] = []) -> TextGenerationParams {
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

    /// 生产路径的最小镜像：run 状态 + 工具调用 → execute → 取回输出文本。
    private func executeRuntimeStatus(
        runtime: ChatToolRuntime,
        toolCall: UIMessagePart.Tool,
        bridge: IosToolExposureBridge? = nil
    ) async -> String {
        let pending = ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "runtime-status-run",
            startedAt: 1,
            inputDigest: "digest",
            conversationId: nil,
            baseMessages: [makeAssistantMessage(parts: [toolCall])]
        )
        let result = await runtime.execute(
            ChatPendingToolCall(kind: .runtimeStatus, toolCall: toolCall),
            context: pending,
            toolExposureBridge: bridge
        )
        guard case .completed(let messages) = result else {
            XCTFail("runtime_status 必须走 completed 路径，实际: \(result)")
            return ""
        }
        return messages.flatMap { message in
            message.parts.compactMap { ($0 as? UIMessagePart.Tool)?.output }
        }.flatMap { $0 }.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
    }

    private func parseJSON(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("输出必须是可解析 JSON，实际: \(text.prefix(200))")
            return [:]
        }
        return object
    }

    private func jevObject(_ object: [String: Any]) -> [String: Any] {
        guard let jev = object["jev"] as? [String: Any] else {
            XCTFail("契约必须含 jev 段，实际键: \(object.keys.sorted())")
            return [:]
        }
        return jev
    }

    private func useCaseObject(_ object: [String: Any], _ key: String) -> [String: Any] {
        let useCases = jevObject(object)["use_cases"] as? [String: Any] ?? [:]
        guard let entry = useCases[key] as? [String: Any] else {
            XCTFail("use_cases 必须含 \(key)，实际键: \(useCases.keys.sorted())")
            return [:]
        }
        return entry
    }

    // MARK: - 声明与可见性

    func testRuntimeStatusIsDeclaredResidentInProductionCatalog() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: localToolExecutor(),
            autoGenerateResponses: false
        )
        let names = Set(viewModel.currentToolDeclarationNames())
        XCTAssertTrue(names.contains("runtime_status"), "runtime_status 必须进生产目录（常驻首轮可见）")

        let bridge = viewModel.toolExposureBridgeForTesting()
        XCTAssertEqual(bridge?.lazyModeEnabled(), true, "默认聊天声明 >40 工具 → lazy 模式")
        XCTAssertTrue(
            bridge?.visibleTools().map(\.name).contains("runtime_status") == true,
            "resident 工具首轮即可见，无需先 tool_search"
        )
    }

    // MARK: - 分类与执行契约

    func testPendingCallClassifiesAsRuntimeStatus() {
        let runtime = makeRuntime(sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()))
        let toolCall = makeToolCall()
        let assistant = makeAssistantMessage(parts: [toolCall])

        let pending = runtime.nextPendingToolCall(
            in: [UIMessage.companion.user(prompt: "hi"), assistant],
            availableToolNames: ["runtime_status"]
        )
        guard let pending else {
            return XCTFail("runtime_status 必须被分类为待执行工具调用")
        }
        guard case .runtimeStatus = pending.kind else {
            return XCTFail("runtime_status 必须路由为 runtimeStatus kind，实际: \(pending.kind)")
        }
    }

    func testExecuteReturnsContractJson() async {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let runtime = makeRuntime(sharedSettings: sharedSettings)
        let output = await executeRuntimeStatus(runtime: runtime, toolCall: makeToolCall())
        let object = parseJSON(output)

        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["tool"] as? String, "runtime_status")
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["platform"] as? String, "ios")

        let runtimeSection = object["runtime"] as? [String: Any] ?? [:]
        for key in ["search_enabled", "webmount_enabled", "memory_tool_enabled",
                    "local_tool_executor_available", "mcp_network_allowed",
                    "subagent_dispatch_enabled", "model_council_enabled"] {
            XCTAssertNotNil(runtimeSection[key], "runtime 段缺 \(key)")
        }

        let jev = jevObject(object)
        XCTAssertEqual(jev["role"] as? String, "internal_fast_judgment")
        XCTAssertEqual(jev["service"] as? String, "typesafe.systemone")
        XCTAssertEqual(jev["api_mode"] as? String, "systemone", "默认出站形态必须如实报 systemone")
        XCTAssertEqual(jev["model"] as? String, "jev-latest", "systemone 无 pinned 时模型为 jev-latest")
        XCTAssertEqual(jev["model_configured"] as? Bool, true)
        XCTAssertNotNil(jev["summary"], "jev 段必须自带可读说明，回答「jev 是什么」")
        XCTAssertNotNil(jev["coordinator"])
        XCTAssertNotNil(jev["budget"])
        XCTAssertNotNil(jev["metrics"])
    }

    // MARK: - Jev 状态如实上报

    func testDefaultJevStateReportsAllUseCasesOff() async {
        IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey)
        defer { IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey) }
        IOSJevDecisionCoordinator.shared.resetAuthState()

        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let runtime = makeRuntime(sharedSettings: sharedSettings)
        let object = parseJSON(await executeRuntimeStatus(runtime: runtime, toolCall: makeToolCall()))
        let jev = jevObject(object)

        XCTAssertEqual(jev["key_configured"] as? Bool, false, "无 Key 时必须如实报 false")
        for key in ["tool_discovery", "memory_recall", "context_selection", "model_routing", "web_actions", "subagent_intent"] {
            let entry = useCaseObject(object, key)
            XCTAssertEqual(entry["mode"] as? String, "off", "\(key) 默认 mode 必须 off")
            XCTAssertEqual(entry["effective_mode"] as? String, "off", "\(key) 默认 effective 必须 off")
            XCTAssertEqual(entry["available_now"] as? Bool, false, "\(key) 无 Key 时不可宣称可用")
        }
    }

    func testShadowModeAndAllowedScopesReflected() async {
        IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey)
        defer { IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey) }
        IOSJevDecisionCoordinator.shared.resetAuthState()

        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        var settings = sharedSettings.jevSettings
        settings.setMode(.shadow, for: .toolDiscovery)
        sharedSettings.updateJevSettings(settings)

        let runtime = makeRuntime(sharedSettings: sharedSettings)
        let entry = useCaseObject(
            parseJSON(await executeRuntimeStatus(runtime: runtime, toolCall: makeToolCall())),
            "tool_discovery"
        )
        XCTAssertEqual(entry["mode"] as? String, "shadow")
        XCTAssertEqual(entry["effective_mode"] as? String, "shadow")
        XCTAssertEqual(entry["can_send_scopes"] as? Bool, true, "默认范围集齐 → can_send")
        XCTAssertEqual(entry["available_now"] as? Bool, false, "无 Key 时 shadow 也不得出网")
    }

    func testActiveWithoutPinnedVersionReportsEffectiveShadow() async {
        IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey)
        defer { IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey) }

        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        var settings = sharedSettings.jevSettings
        settings.setMode(.active, for: .memoryRecall)
        sharedSettings.updateJevSettings(settings)

        let runtime = makeRuntime(sharedSettings: sharedSettings)
        var entry = useCaseObject(
            parseJSON(await executeRuntimeStatus(runtime: runtime, toolCall: makeToolCall())),
            "memory_recall"
        )
        XCTAssertEqual(entry["mode"] as? String, "active", "配置模式如实报 active")
        XCTAssertEqual(entry["effective_mode"] as? String, "shadow", "无验收固定版本时不得宣称真 active")

        // "jev-latest" 同样不算固定版本。
        settings = sharedSettings.jevSettings
        settings.pinnedModelVersion = "jev-latest"
        sharedSettings.updateJevSettings(settings)
        entry = useCaseObject(
            parseJSON(await executeRuntimeStatus(runtime: runtime, toolCall: makeToolCall())),
            "memory_recall"
        )
        XCTAssertEqual(entry["effective_mode"] as? String, "shadow")

        // 固定版本后 effective 才为 active（无 Key 仍 available_now=false）。
        settings = sharedSettings.jevSettings
        settings.pinnedModelVersion = "jev-2026.09"
        sharedSettings.updateJevSettings(settings)
        entry = useCaseObject(
            parseJSON(await executeRuntimeStatus(runtime: runtime, toolCall: makeToolCall())),
            "memory_recall"
        )
        XCTAssertEqual(entry["effective_mode"] as? String, "active")
        XCTAssertEqual(entry["available_now"] as? Bool, false)
    }

    func testKeyConfiguredReportedWithoutLeakingSecret() async {
        IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey)
        defer { IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey) }
        XCTAssertTrue(IOSCredentialSideTable.store(key: IOSCredentialSideTable.jevApiKey, value: "sk-runtime-secret-xyz"))
        IOSJevDecisionCoordinator.shared.resetAuthState()

        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        var settings = sharedSettings.jevSettings
        settings.pinnedModelVersion = "jev-2026.09"
        settings.setMode(.active, for: .modelRouting)
        sharedSettings.updateJevSettings(settings)

        let runtime = makeRuntime(sharedSettings: sharedSettings)
        let output = await executeRuntimeStatus(runtime: runtime, toolCall: makeToolCall())
        let object = parseJSON(output)
        let jev = jevObject(object)

        XCTAssertEqual(jev["key_configured"] as? Bool, true, "Key 存在性必须如实上报")
        XCTAssertFalse(output.contains("sk-runtime-secret-xyz"), "输出绝不允许包含 Key 本体")

        let entry = useCaseObject(object, "model_routing")
        XCTAssertEqual(entry["effective_mode"] as? String, "active")
        XCTAssertEqual(entry["available_now"] as? Bool, true, "Key+范围+固定版本+无暂停 → 真实可用")
    }

    /// vercel_gateway 模式：api_mode/service/model 如实切换；Key 未配置时
    /// available_now 仍 false（active + 模型已配 ≠ 可出站）。
    func testVercelModeReportedInStatus() async {
        IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey)
        defer { IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey) }

        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        var settings = sharedSettings.jevSettings
        settings.setAPIStyle(.vercelGateway)
        settings.setVercelModel("openai/gpt-4o")
        settings.setMode(.active, for: .toolDiscovery)
        sharedSettings.updateJevSettings(settings)

        let runtime = makeRuntime(sharedSettings: sharedSettings)
        let object = parseJSON(await executeRuntimeStatus(runtime: runtime, toolCall: makeToolCall()))
        let jev = jevObject(object)
        XCTAssertEqual(jev["api_mode"] as? String, "vercel_gateway")
        XCTAssertEqual(jev["service"] as? String, "vercel.ai_gateway")
        XCTAssertEqual(jev["model"] as? String, "openai/gpt-4o")
        XCTAssertEqual(jev["model_configured"] as? Bool, true)

        let entry = useCaseObject(object, "tool_discovery")
        XCTAssertEqual(entry["effective_mode"] as? String, "active")
        XCTAssertEqual(entry["available_now"] as? Bool, false, "无 Key 时不得宣称可用")
    }

    /// vercel_gateway + 空模型：effective 收 shadow、model_configured false，
    /// 状态说明提示填 slug（空模型只能经显式清空构造——选择形态自动填默认）。
    func testVercelEmptyModelReportedHonestly() async {
        IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey)
        defer { IOSCredentialSideTable.delete(key: IOSCredentialSideTable.jevApiKey) }

        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        var settings = sharedSettings.jevSettings
        settings.setAPIStyle(.vercelGateway)
        settings.setVercelModel("")
        settings.setMode(.active, for: .toolDiscovery)
        sharedSettings.updateJevSettings(settings)

        let runtime = makeRuntime(sharedSettings: sharedSettings)
        let object = parseJSON(await executeRuntimeStatus(runtime: runtime, toolCall: makeToolCall()))
        let jev = jevObject(object)
        XCTAssertEqual(jev["api_mode"] as? String, "vercel_gateway")
        XCTAssertEqual(jev["model_configured"] as? Bool, false)
        XCTAssertTrue(jev["model"] is NSNull, "未配置模型不得伪造 slug")
        XCTAssertNotNil(jev["model_version_note"], "必须提示填写模型 slug")

        let entry = useCaseObject(object, "tool_discovery")
        XCTAssertEqual(entry["effective_mode"] as? String, "shadow", "空模型 active 必须收 shadow")
        XCTAssertEqual(entry["available_now"] as? Bool, false)
    }

    // MARK: - 后台与子代理路径

    func testBackgroundExecutorReturnsSameContract() async throws {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let runtime = makeRuntime(sharedSettings: sharedSettings)
        let declarations = ToolKt.iosToolDeclarations(names: ["runtime_status"])
        let executors = runtime.backgroundToolExecutors(
            providerSetting: makeProviderSetting(),
            params: makeParams(tools: declarations),
            runId: "bg-runtime-status"
        )
        let executor = RuntimeStatusUncheckedToolExecutorBox(
            try XCTUnwrap(executors["runtime_status"], "后台必须注册 runtime_status 执行器")
        )
        let outcome = await executor.execute(
            name: "runtime_status",
            arguments: "{}",
            isUserInitiated: false
        )
        guard case .filled(let output) = outcome else {
            return XCTFail("后台 runtime_status 必须返回 filled，实际: \(outcome)")
        }
        let object = parseJSON(output)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["tool"] as? String, "runtime_status")
    }

    func testSubAgentReadOnlyPolicyAdmitsRuntimeStatus() {
        XCTAssertTrue(IOSSubAgentToolPolicy.readOnlyParentToolNames.contains("runtime_status"))
        for roleId in ["explorer", "historian", "oracle"] {
            let role = IOSSubAgentRoleCatalog.resolve(roleId: roleId)
            XCTAssertTrue(
                role?.toolAllowlist.contains("runtime_status") == true,
                "只读角色 \(roleId) 必须允许 runtime_status"
            )
        }
    }
}
