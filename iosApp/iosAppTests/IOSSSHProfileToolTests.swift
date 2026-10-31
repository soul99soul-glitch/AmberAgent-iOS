import XCTest
@preconcurrency import Shared
@testable import iosApp

/// `ssh_profile_list/create/update/delete` agent tools.
///
/// Covered contract: schema shape, high-risk approval (ordinary auto-approve
/// must not pass, high-risk auto-approve must), list without credentials, full
/// create→update→delete chain with Keychain cleanup, argument rejection, and
/// redaction of credential arguments in persistence/preview.
@MainActor
final class IOSSSHProfileToolTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "IOSSSHProfileToolTests-\(UUID().uuidString)")!
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(userDefaults: isolatedDefaults(), storageKey: "ssh-profile-tools-\(UUID().uuidString)")
    }

    private func makeRuntime(_ store: SettingsStore) -> ChatToolRuntime {
        ChatToolRuntime(
            settingsStore: store,
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: nil,
            searchTransport: SSHProfileNoNetworkSearchTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
    }

    private func makeProviderSetting() -> ProviderSetting.OpenAI {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "ssh-profile-test",
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

    private func makeParams(toolName: String) -> TextGenerationParams {
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
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: ToolKt.iosToolDeclarations(names: [toolName]),
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
    }

    private func makeToolCall(name: String, input: String) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: "ssh-profile-\(UUID().uuidString)",
            toolName: name,
            input: input,
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

    private func makePending(
        toolCall: UIMessagePart.Tool,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) -> ChatPendingToolApproval {
        ChatPendingToolApproval(
            toolCall: toolCall,
            providerSetting: makeProviderSetting(),
            params: makeParams(toolName: toolCall.toolName),
            runId: "ssh-profile-run",
            startedAt: 1,
            inputDigest: "digest",
            conversationId: nil,
            baseMessages: [makeAssistantMessage(parts: [toolCall])],
            executionPolicy: executionPolicy
        )
    }

    private func policy(highRisk: Bool, global: Bool = false) -> IOSExecutionPolicySnapshot {
        IOSExecutionPolicySnapshot(
            capabilityPolicies: [:],
            globalAutoApproveEnabled: global,
            highRiskAutoApproveEnabled: highRisk,
            execJavaScriptEnabled: false,
            webSearchEnabled: false
        )
    }

    private func parseJSON(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("输出必须是可解析 JSON，实际: \(text.prefix(200))")
            return [:]
        }
        return object
    }

    private func toolOutputText(_ messages: [UIMessage]) -> String {
        messages
            .flatMap(\.parts)
            .compactMap { $0 as? UIMessagePart.Tool }
            .flatMap(\.output)
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined()
    }

    private func finishedTool(_ messages: [UIMessage]) -> UIMessagePart.Tool? {
        messages
            .flatMap(\.parts)
            .compactMap { $0 as? UIMessagePart.Tool }
            .first { !$0.output.isEmpty }
    }

    private func execute(
        toolName: String,
        argumentsJSON: String,
        store: SettingsStore
    ) -> String {
        IOSSSHProfileToolExecutor.execute(
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            settingsStore: store
        )
    }

    // MARK: - Layer 1: tool schema

    func testDeclarationsExposeTheDocumentedSchema() throws {
        let tools = ToolKt.iosToolDeclarations(names: [
            IOSSSHProfileToolCatalog.listToolName,
            IOSSSHProfileToolCatalog.createToolName,
            IOSSSHProfileToolCatalog.updateToolName,
            IOSSSHProfileToolCatalog.deleteToolName,
        ])
        XCTAssertEqual(tools.map(\.name), [
            IOSSSHProfileToolCatalog.listToolName,
            IOSSSHProfileToolCatalog.createToolName,
            IOSSSHProfileToolCatalog.updateToolName,
            IOSSSHProfileToolCatalog.deleteToolName,
        ])

        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let list = try XCTUnwrap(byName[IOSSSHProfileToolCatalog.listToolName])
        XCTAssertFalse(list.needsApproval, "list 只读，必须免审批")

        for name in IOSSSHProfileToolCatalog.mutatingToolNames {
            let tool = try XCTUnwrap(byName[name])
            XCTAssertTrue(tool.needsApproval, name)
            XCTAssertFalse(tool.allowsAutoApproval, "\(name) 必须拒绝普通自动批准")
        }

        let createJSON = try XCTUnwrap(try XCTUnwrap(byName[IOSSSHProfileToolCatalog.createToolName]).parametersJsonSchema())
        XCTAssertTrue(createJSON.contains("\"host\""), createJSON)
        XCTAssertTrue(createJSON.contains("\"username\""), createJSON)
        XCTAssertTrue(createJSON.contains("\"port\""), createJSON)
        XCTAssertTrue(createJSON.contains("\"password\""), createJSON)
        XCTAssertTrue(createJSON.contains("\"private_key\""), createJSON)

        let updateJSON = try XCTUnwrap(try XCTUnwrap(byName[IOSSSHProfileToolCatalog.updateToolName]).parametersJsonSchema())
        XCTAssertTrue(updateJSON.contains("\"profile_id\""), updateJSON)
        XCTAssertTrue(updateJSON.contains("\"auth_method\""), updateJSON)

        // A write tool's schema must not advertise the credential as returned.
        XCTAssertFalse(createJSON.lowercased().contains("\"secret\""))
    }

    // MARK: - Layer 2: approval boundary

    func testWriteToolsRequireApprovalAndOrdinaryAutoApproveDoesNotPass() async {
        let store = makeStore()
        let runtime = makeRuntime(store)
        let toolCall = makeToolCall(
            name: IOSSSHProfileToolCatalog.createToolName,
            input: #"{"host":"example.test","username":"amber","password":"hunter2"}"#
        )
        // Ordinary auto-approve (global switch on, high-risk off) must still ask.
        let result = await runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: toolCall),
            context: makePending(toolCall: toolCall, executionPolicy: policy(highRisk: false, global: true))
        )
        guard case .waitingForApproval(let prompt) = result else {
            return XCTFail("普通自动批准不得放行写工具，实际: \(result)")
        }
        guard case .mcp(let request) = prompt else {
            return XCTFail("期望 mcp 审批卡")
        }
        XCTAssertFalse(request.argumentsPreview.contains("hunter2"), "审批卡不得出现明文密码")
        XCTAssertFalse(request.reason.contains("hunter2"))
        XCTAssertTrue(store.sshProfiles.isEmpty, "未批准前不得写入")
    }

    func testWriteToolsRunWhenHighRiskAutoApproveIsOn() async {
        let store = makeStore()
        let runtime = makeRuntime(store)
        let toolCall = makeToolCall(
            name: IOSSSHProfileToolCatalog.createToolName,
            input: #"{"name":"auto","host":"auto.test","port":2222,"username":"amber","password":"auto-secret"}"#
        )
        let result = await runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: toolCall),
            context: makePending(toolCall: toolCall, executionPolicy: policy(highRisk: true))
        )
        guard case .completed(let messages) = result else {
            return XCTFail("高风险自动批准应直接执行，实际: \(result)")
        }
        let output = toolOutputText(messages)
        let payload = parseJSON(output)
        XCTAssertEqual(payload["ok"] as? Bool, true, output)
        XCTAssertFalse(output.contains("auto-secret"), "结果不得包含密码")
        XCTAssertEqual(store.sshProfiles.count, 1)
        XCTAssertEqual(store.sshProfiles.first?.host, "auto.test")

        // Persisted input keeps the profile but redacts the credential.
        let persistedInput = finishedTool(messages)?.input ?? ""
        XCTAssertFalse(persistedInput.contains("auto-secret"), "持久化入参必须脱敏")
        XCTAssertTrue(persistedInput.contains("auto.test"))

        try? store.deleteSSHProfile(id: store.sshProfiles.first?.id ?? "")
    }

    func testDeniedApprovalDoesNotWrite() async {
        let store = makeStore()
        let runtime = makeRuntime(store)
        let toolCall = makeToolCall(
            name: IOSSSHProfileToolCatalog.createToolName,
            input: #"{"host":"deny.test","username":"amber","password":"deny-secret"}"#
        )
        let pending = makePending(toolCall: toolCall, executionPolicy: policy(highRisk: false))
        _ = await runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: toolCall),
            context: pending
        )
        _ = await runtime.finishMcpApproval(pending: pending, allow: false)
        XCTAssertTrue(store.sshProfiles.isEmpty, "拒绝后不得写入")
    }

    // MARK: - Layer 3: storage (create → update → delete)

    func testCreateUpdateDeleteChainCleansKeychain() throws {
        let store = makeStore()
        let create = parseJSON(execute(
            toolName: IOSSSHProfileToolCatalog.createToolName,
            argumentsJSON: #"{"name":"prod","host":"prod.test","port":2200,"username":"deploy","password":"chain-secret"}"#,
            store: store
        ))
        XCTAssertEqual(create["ok"] as? Bool, true)
        let createdProfile = try XCTUnwrap(create["profile"] as? [String: Any])
        let profileId = try XCTUnwrap(createdProfile["id"] as? String)
        XCTAssertEqual(createdProfile["has_password"] as? Bool, true)
        XCTAssertEqual(createdProfile["has_private_key"] as? Bool, false)
        XCTAssertTrue(store.hasCredentialForSSHProfile(store.sshProfiles[0]))

        // Update keeps the credential when the endpoint does not change.
        let update = parseJSON(execute(
            toolName: IOSSSHProfileToolCatalog.updateToolName,
            argumentsJSON: #"{"profile_id":"\#(profileId)","name":"prod-renamed","port":2222}"#,
            store: store
        ))
        XCTAssertEqual(update["ok"] as? Bool, true)
        XCTAssertEqual(store.sshProfiles[0].name, "prod-renamed")
        XCTAssertEqual(store.sshProfiles[0].port, 2222)
        // Port changed without a credential: SettingsStore drops the stale pin
        // and the old credential, same as the settings editor.
        XCTAssertFalse(store.hasCredentialForSSHProfile(store.sshProfiles[0]))

        // Re-supply a credential, then delete and confirm the Keychain item is gone.
        let refreshed = parseJSON(execute(
            toolName: IOSSSHProfileToolCatalog.updateToolName,
            argumentsJSON: #"{"profile_id":"\#(profileId)","password":"chain-secret-2"}"#,
            store: store
        ))
        XCTAssertEqual((refreshed["profile"] as? [String: Any])?["has_password"] as? Bool, true)
        XCTAssertTrue(store.hasCredentialForSSHProfile(store.sshProfiles[0]))

        let deleted = parseJSON(execute(
            toolName: IOSSSHProfileToolCatalog.deleteToolName,
            argumentsJSON: #"{"profile_id":"\#(profileId)"}"#,
            store: store
        ))
        XCTAssertEqual(deleted["ok"] as? Bool, true)
        XCTAssertEqual(deleted["status"] as? String, "deleted")
        XCTAssertTrue(store.sshProfiles.isEmpty)
        XCTAssertNil(store.sshDefaultProfileId)
        XCTAssertFalse(store.hasCredentialForSSHProfile(IOSSSHProfile(id: profileId, name: "prod-renamed",
                                                                     host: "prod.test", port: 2222,
                                                                     username: "deploy")))
    }

    func testListReturnsProfilesWithoutCredentialMaterial() throws {
        let store = makeStore()
        var profile = IOSSSHProfile()
        profile.name = "listed"
        profile.host = "list.test"
        profile.port = 22
        profile.username = "amber"
        profile.authMethod = .password
        try store.upsertSSHProfile(profile, credential: .password("list-secret"))

        let output = execute(
            toolName: IOSSSHProfileToolCatalog.listToolName,
            argumentsJSON: "{}",
            store: store
        )
        XCTAssertFalse(output.contains("list-secret"), "list 不得返回密码")
        let payload = parseJSON(output)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["profile_count"] as? Int, 1)
        let entry = try XCTUnwrap((payload["profiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["id"] as? String, profile.id)
        XCTAssertEqual(entry["host"] as? String, "list.test")
        XCTAssertEqual(entry["username"] as? String, "amber")
        XCTAssertEqual(entry["has_password"] as? Bool, true)
        XCTAssertEqual(entry["has_private_key"] as? Bool, false)
        XCTAssertEqual(entry["is_default"] as? Bool, true)
        XCTAssertFalse(entry.keys.contains("password"))
        XCTAssertFalse(entry.keys.contains("secret"))

        try store.deleteSSHProfile(id: profile.id)
    }

    func testListIsReadOnlyAndUnapprovedThroughTheRuntime() async {
        let store = makeStore()
        let runtime = makeRuntime(store)
        let toolCall = makeToolCall(name: IOSSSHProfileToolCatalog.listToolName, input: "{}")
        let result = await runtime.execute(
            ChatPendingToolCall(kind: .advanced, toolCall: toolCall),
            context: makePending(toolCall: toolCall, executionPolicy: policy(highRisk: false))
        )
        guard case .completed(let messages) = result else {
            return XCTFail("list 必须免审批直接完成，实际: \(result)")
        }
        XCTAssertEqual(parseJSON(toolOutputText(messages))["ok"] as? Bool, true)
    }

    // MARK: - Layer 4: validation

    func testInvalidArgumentsAreRejectedWithoutWriting() {
        let store = makeStore()
        let cases: [(String, String)] = [
            (IOSSSHProfileToolCatalog.createToolName, #"{"username":"amber","password":"x"}"#),
            (IOSSSHProfileToolCatalog.createToolName, #"{"host":"h.test","password":"x"}"#),
            (IOSSSHProfileToolCatalog.createToolName, #"{"host":"h.test","username":"amber","port":0,"password":"x"}"#),
            (IOSSSHProfileToolCatalog.createToolName, #"{"host":"h.test","username":"amber","port":65536,"password":"x"}"#),
            (IOSSSHProfileToolCatalog.createToolName, #"{"host":"h.test","username":"amber","auth_method":"agent","password":"x"}"#),
            (IOSSSHProfileToolCatalog.createToolName, #"{"host":"h.test","username":"amber","password":"a","private_key":"b"}"#),
            (IOSSSHProfileToolCatalog.createToolName, #"{"host":"h.test","username":"amber","unexpected":"value","password":"x"}"#),
            (IOSSSHProfileToolCatalog.updateToolName, #"{"profile_id":"missing","name":"x"}"#),
            (IOSSSHProfileToolCatalog.deleteToolName, #"{}"#),
            (IOSSSHProfileToolCatalog.deleteToolName, #"{"profile_id":"missing"}"#),
        ]
        for (toolName, arguments) in cases {
            let output = execute(toolName: toolName, argumentsJSON: arguments, store: store)
            let payload = parseJSON(output)
            XCTAssertEqual(payload["ok"] as? Bool, false, "\(toolName) \(arguments) 应被拒绝：\(output)")
            XCTAssertEqual(store.sshProfiles.count, 0, "\(toolName) \(arguments) 不得写入")
        }
    }

    func testRedactionPlaceholderIsNeverWrittenAsACredential() throws {
        // A cold resume replays the durable approval snapshot, which carries the
        // redaction marker instead of the secret. Writing that marker would
        // silently store a useless credential, so it must fail closed.
        let store = makeStore()
        let marker = IOSSSHOutputRedactor.replacement
        let output = execute(
            toolName: IOSSSHProfileToolCatalog.createToolName,
            argumentsJSON: #"{"host":"placeholder.test","username":"amber","password":"\#(marker)"}"#,
            store: store
        )
        XCTAssertEqual(parseJSON(output)["ok"] as? Bool, false, output)
        XCTAssertTrue(store.sshProfiles.isEmpty, "占位符不得创建 Profile")

        let first = parseJSON(execute(
            toolName: IOSSSHProfileToolCatalog.createToolName,
            argumentsJSON: #"{"name":"real","host":"real.test","username":"amber","password":"real-secret"}"#,
            store: store
        ))
        XCTAssertEqual(first["ok"] as? Bool, true)
        let profileId = try XCTUnwrap((first["profile"] as? [String: Any])?["id"] as? String)
        let update = execute(
            toolName: IOSSSHProfileToolCatalog.updateToolName,
            argumentsJSON: #"{"profile_id":"\#(profileId)","private_key":"\#(marker)"}"#,
            store: store
        )
        XCTAssertEqual(parseJSON(update)["ok"] as? Bool, false, update)
        // The existing credential is untouched.
        XCTAssertTrue(store.hasCredentialForSSHProfile(store.sshProfiles[0]))
        for profile in store.sshProfiles {
            try? store.deleteSSHProfile(id: profile.id)
        }
    }

    func testDuplicateNameIsRejected() throws {
        let store = makeStore()
        let first = parseJSON(execute(
            toolName: IOSSSHProfileToolCatalog.createToolName,
            argumentsJSON: #"{"name":"dupe","host":"one.test","username":"amber","password":"x"}"#,
            store: store
        ))
        XCTAssertEqual(first["ok"] as? Bool, true)
        let second = execute(
            toolName: IOSSSHProfileToolCatalog.createToolName,
            argumentsJSON: #"{"name":"DUPE","host":"two.test","username":"amber","password":"y"}"#,
            store: store
        )
        XCTAssertEqual(parseJSON(second)["ok"] as? Bool, false, second)
        XCTAssertEqual(store.sshProfiles.count, 1)
        for profile in store.sshProfiles {
            try? store.deleteSSHProfile(id: profile.id)
        }
    }

    // MARK: - Layer 5: redaction

    func testCredentialArgumentsAreRedactedInPersistenceAndPreviews() {
        let original = #"{"host":"h.test","username":"amber","password":"super-secret","private_key":""}"#
        let redacted = IOSSSHProfileToolCatalog.redactedArgumentsJSON(original)
        XCTAssertFalse(redacted.contains("super-secret"))
        let args = parseJSON(redacted)
        XCTAssertEqual(args["host"] as? String, "h.test")
        XCTAssertEqual(args["password"] as? String, IOSSSHOutputRedactor.replacement)

        // Non-credential calls are returned untouched.
        let plain = #"{"profile_id":"abc"}"#
        XCTAssertEqual(IOSSSHProfileToolCatalog.redactedArgumentsJSON(plain), plain)

        let toolCall = makeToolCall(name: IOSSSHProfileToolCatalog.createToolName, input: original)
        let messages = IOSSSHProfileToolCatalog.redactedApprovalMessages([makeAssistantMessage(parts: [toolCall])])
        let persisted = messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }.first?.input ?? ""
        XCTAssertFalse(persisted.contains("super-secret"))
    }

    func testApprovalPreviewNamesTheProfileAndNeverEchoesTheSecret() throws {
        let store = makeStore()
        var profile = IOSSSHProfile()
        profile.name = "preview-target"
        profile.host = "preview.test"
        profile.port = 22
        profile.username = "amber"
        profile.authMethod = .password
        try store.upsertSSHProfile(profile, credential: .password("preview-secret"))

        let preview = IOSSSHProfileToolCatalog.approvalPreview(
            toolName: IOSSSHProfileToolCatalog.updateToolName,
            argumentsJSON: #"{"profile_id":"\#(profile.id)","host":"new.test","password":"preview-secret"}"#,
            store: store
        )
        XCTAssertTrue(preview.contains("preview-target"), preview)
        XCTAssertTrue(preview.contains("Host"), preview)
        XCTAssertTrue(preview.contains("将设置/更换密码") || preview.contains("密码"), preview)
        XCTAssertFalse(preview.contains("preview-secret"), preview)

        let deletePreview = IOSSSHProfileToolCatalog.approvalPreview(
            toolName: IOSSSHProfileToolCatalog.deleteToolName,
            argumentsJSON: #"{"profile_id":"\#(profile.id)"}"#,
            store: store
        )
        XCTAssertTrue(deletePreview.contains("preview-target"), deletePreview)
        XCTAssertTrue(deletePreview.contains("凭证"), deletePreview)

        try store.deleteSSHProfile(id: profile.id)
    }

    func testToolOutputNeverContainsCredentialMaterial() throws {
        let store = makeStore()
        let secret = "output-must-not-leak"
        let created = execute(
            toolName: IOSSSHProfileToolCatalog.createToolName,
            argumentsJSON: #"{"host":"leak.test","username":"amber","password":"\#(secret)"}"#,
            store: store
        )
        XCTAssertFalse(created.contains(secret))
        let updated = execute(
            toolName: IOSSSHProfileToolCatalog.updateToolName,
            argumentsJSON: #"{"profile_id":"\#(store.sshProfiles[0].id)","password":"\#(secret)-2"}"#,
            store: store
        )
        XCTAssertFalse(updated.contains(secret))
        let listed = execute(toolName: IOSSSHProfileToolCatalog.listToolName, argumentsJSON: "{}", store: store)
        XCTAssertFalse(listed.contains(secret))
        for profile in store.sshProfiles {
            try? store.deleteSSHProfile(id: profile.id)
        }
    }

    // MARK: - Review fixes: remote approval gate

    func testRemoteApprovalCannotApproveHighRiskWrites() {
        // 锁屏 Live Activity / 灵动岛 / 手表的「允许」不得批准 SSH profile 写。
        let writeRequest = McpToolApprovalRequest(
            id: "r1",
            serverName: "local",
            toolName: IOSSSHProfileToolCatalog.deleteToolName,
            argumentsPreview: "Profile：prod",
            reason: "删除 SSH Profile"
        )
        let prompt = ChatToolApprovalPrompt.mcp(writeRequest)
        XCTAssertFalse(ChatRunApprovalSession.allowsRemoteApproval(prompt))
        XCTAssertFalse(ChatRunApprovalSession.remoteApprovalAllowsResolve(prompt, allow: true))
        // 拒绝永远安全。
        XCTAssertTrue(ChatRunApprovalSession.remoteApprovalAllowsResolve(prompt, allow: false))
        // 不为它发布可点的活动卡。
        XCTAssertNil(ChatRunApprovalSession.activityApproval(for: prompt))
    }

    func testReadOnlyListStillExposesNoApprovalCardAtAll() {
        let listRequest = McpToolApprovalRequest(
            id: "r2",
            serverName: "local",
            toolName: IOSSSHProfileToolCatalog.listToolName,
            argumentsPreview: "{}",
            reason: "列出 SSH Profile"
        )
        let prompt = ChatToolApprovalPrompt.mcp(listRequest)
        XCTAssertTrue(ChatRunApprovalSession.allowsRemoteApproval(prompt))
    }

    func testAskUserNeverResolvesThroughApprovalPath() {
        let prompt = ChatToolApprovalPrompt.askUser(
            ChatAskUserRequest(id: "q1", question: "继续？", options: ["是", "否"])
        )
        XCTAssertFalse(ChatRunApprovalSession.allowsRemoteApproval(prompt))
        XCTAssertFalse(ChatRunApprovalSession.remoteApprovalAllowsResolve(prompt, allow: true))
        XCTAssertFalse(ChatRunApprovalSession.remoteApprovalAllowsResolve(prompt, allow: false))
        XCTAssertNil(ChatRunApprovalSession.activityApproval(for: prompt))
    }

    // MARK: - Review fixes: Jev auto-approval gate

    func testCredentialWritesBypassJevAndFollowTheHighRiskSwitchOnly() async {
        let store = makeStore()
        let runtime = makeRuntime(store)
        let writeCall = makeToolCall(
            name: IOSSSHProfileToolCatalog.createToolName,
            input: #"{"host":"h.test","username":"amber","password":"gate-secret"}"#
        )
        // 未开高风险自动批准：不送 Jev 复核（返回 false 即“无需收紧”）。
        let off = makePending(toolCall: writeCall, executionPolicy: policy(highRisk: false))
        let tightenedOff = await runtime.shouldTightenAutoApproval(
            toolCall: writeCall, recentUserTexts: ["建个 ssh"], runId: off.runId,
            conversationId: nil, toolExposureBridge: nil
        )
        XCTAssertFalse(tightenedOff, "未开高风险自动批准时不应送 Jev 复核")

        // 开了高风险自动批准：直接放行，也不送 Jev（否则 withoutAutoApprove 会反向拦住）。
        let on = makePending(toolCall: writeCall, executionPolicy: policy(highRisk: true))
        let tightenedOn = await runtime.shouldTightenAutoApproval(
            toolCall: writeCall, recentUserTexts: ["建个 ssh"], runId: on.runId,
            conversationId: nil, toolExposureBridge: nil
        )
        XCTAssertFalse(tightenedOn, "开了高风险自动批准时不得被 Jev 收紧")
    }

    func testReadOnlyListIsRereadableForJev() {
        XCTAssertTrue(IOSJevContextSelectionService.isRereadableTool(IOSSSHProfileToolCatalog.listToolName))
        for name in IOSSSHProfileToolCatalog.mutatingToolNames {
            XCTAssertFalse(IOSJevContextSelectionService.isRereadableTool(name), name)
        }
    }

    // MARK: - Review fixes: plaintext never enters the engine working set

    func testEngineRedactsCredentialsBeforePublishingOrCheckpointing() {
        let secret = "engine-must-not-persist-this"
        let toolCall = makeToolCall(
            name: IOSSSHProfileToolCatalog.createToolName,
            input: #"{"host":"h.test","username":"amber","password":"\#(secret)"}"#
        )
        let message = makeAssistantMessage(parts: [toolCall])
        let redacted = IOSSecretArgumentRedaction.redactingSecrets(in: message)
        let persisted = redacted.parts.compactMap { $0 as? UIMessagePart.Tool }.first?.input ?? ""
        XCTAssertFalse(persisted.contains(secret), "入列前必须脱敏")
        XCTAssertTrue(persisted.contains("h.test"))
        // 原始内存副本仍保留真实参数，供批准后的写入使用。
        XCTAssertTrue(toolCall.input.contains(secret))
    }

    // MARK: - Review fixes: classification and exclusion lists

    func testEffectClassAndExclusionLists() {
        XCTAssertEqual(
            IOSToolEffectClassMapping.forToolName(IOSSSHProfileToolCatalog.listToolName, input: "{}"),
            .pure
        )
        for name in IOSSSHProfileToolCatalog.mutatingToolNames {
            XCTAssertEqual(
                IOSToolEffectClassMapping.forToolName(name, input: "{}"),
                .sideEffect,
                name
            )
            XCTAssertTrue(
                ChatToolRuntime.execNestedToolExclusions.contains(name),
                "\(name) 不得作为 exec 嵌套工具"
            )
            XCTAssertTrue(
                ConversationMemoryPollutionPolicy.shouldMarkPolluted(toolName: name, outputText: #"{"ok":true}"#),
                "\(name) 成功写入后应标记会话已变更"
            )
        }
        XCTAssertFalse(
            ChatToolRuntime.execNestedToolExclusions.contains(IOSSSHProfileToolCatalog.listToolName),
            "只读 list 可以进 exec 白名单"
        )
    }

    // MARK: - Review fixes: update approval card wording

    func testUpdatePreviewNamesCredentialOnlyEdits() throws {
        let store = makeStore()
        var profile = IOSSSHProfile()
        profile.name = "card-target"
        profile.host = "card.test"
        profile.port = 22
        profile.username = "amber"
        profile.authMethod = .password
        try store.upsertSSHProfile(profile, credential: .password("old"))

        let passwordOnly = IOSSSHProfileToolCatalog.approvalPreview(
            toolName: IOSSSHProfileToolCatalog.updateToolName,
            argumentsJSON: #"{"profile_id":"\#(profile.id)","password":"new-secret"}"#,
            store: store
        )
        XCTAssertTrue(passwordOnly.contains("密码"), passwordOnly)
        XCTAssertFalse(passwordOnly.contains("改动字段：无"), "只改密码不能显示“无”")
        XCTAssertFalse(passwordOnly.contains("new-secret"), passwordOnly)

        let keyOnly = IOSSSHProfileToolCatalog.approvalPreview(
            toolName: IOSSSHProfileToolCatalog.updateToolName,
            argumentsJSON: #"{"profile_id":"\#(profile.id)","private_key":"KEY"}"#,
            store: store
        )
        XCTAssertTrue(keyOnly.contains("私钥"), keyOnly)
        XCTAssertFalse(keyOnly.contains("改动字段：无"), keyOnly)

        // 改连接目标但不给新凭证：必须提示旧凭证会被清除。
        let endpointChange = IOSSSHProfileToolCatalog.approvalPreview(
            toolName: IOSSSHProfileToolCatalog.updateToolName,
            argumentsJSON: #"{"profile_id":"\#(profile.id)","host":"new.test"}"#,
            store: store
        )
        XCTAssertTrue(endpointChange.contains("清除"), endpointChange)
        XCTAssertTrue(endpointChange.contains("Host"), endpointChange)

        // 显式清空也要说清楚。
        let cleared = IOSSSHProfileToolCatalog.approvalPreview(
            toolName: IOSSSHProfileToolCatalog.updateToolName,
            argumentsJSON: #"{"profile_id":"\#(profile.id)","password":""}"#,
            store: store
        )
        XCTAssertTrue(cleared.contains("清除"), cleared)

        try store.deleteSSHProfile(id: profile.id)
    }

    // MARK: - Layer 6: settings visibility + background boundary

    func testSettingsPageSeesAgentWrites() {
        let store = makeStore()
        let output = execute(
            toolName: IOSSSHProfileToolCatalog.createToolName,
            argumentsJSON: #"{"name":"visible","host":"vis.test","username":"amber","password":"x"}"#,
            store: store
        )
        XCTAssertEqual(parseJSON(output)["ok"] as? Bool, true)
        // The same store instance backs RuntimeEnvironmentView.
        XCTAssertEqual(store.sshProfiles.first?.displayName, "visible")
        XCTAssertEqual(store.defaultSSHProfile?.host, "vis.test")
        for profile in store.sshProfiles {
            try? store.deleteSSHProfile(id: profile.id)
        }
    }

    func testBackgroundExecutorAllowsListButDeniesWrites() async throws {
        let store = makeStore()
        let runtime = makeRuntime(store)
        let bridge = IosToolExposureBridge(tools: ToolKt.iosToolDeclarations(
            names: Array(IOSSSHProfileToolCatalog.toolNames).sorted()
        ), recipeSearchInfo: [:])
        let params = TextGenerationParams(
            model: Model(
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
            ),
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: bridge.visibleTools(),
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
        let executors = runtime.backgroundToolExecutors(
            providerSetting: makeProviderSetting(),
            params: params,
            runId: "ssh-bg-run",
            toolExposureBridge: bridge
        )
        for name in IOSSSHProfileToolCatalog.toolNames {
            let executor = try XCTUnwrap(executors[name], "后台必须注册 \(name) 以给出诚实拒绝")
            let outcome = await SSHProfileToolExecutorBox(executor).execute(name: name, arguments: "{}", isUserInitiated: false)
            if IOSSSHProfileToolCatalog.backgroundAllowedToolNames.contains(name) {
                guard case .filled = outcome else {
                    return XCTFail("\(name) 只读，后台应放行，实际 \(outcome)")
                }
            } else {
                guard case .denied = outcome else {
                    return XCTFail("\(name) 写操作后台必须拒绝，实际 \(outcome)")
                }
            }
        }
    }
}

private final class SSHProfileNoNetworkSearchTransport: IOSSearchHTTPTransport {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        throw URLError(.notConnectedToInternet)
    }
    func sendPublic(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (HTTPURLResponse, Data) {
        throw URLError(.notConnectedToInternet)
    }
}

private final class SSHProfileToolExecutorBox: @unchecked Sendable {
    private let base: any IOSToolExecutor
    init(_ base: any IOSToolExecutor) { self.base = base }
    func execute(name: String, arguments: String, isUserInitiated: Bool) async -> IOSAgentToolOutcome {
        await base.execute(name: name, arguments: arguments, isUserInitiated: isUserInitiated)
    }
}
