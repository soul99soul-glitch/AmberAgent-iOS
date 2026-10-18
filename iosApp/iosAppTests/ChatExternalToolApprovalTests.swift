import XCTest
import WebKit
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatExternalToolApprovalTests: ChatViewModelContextTestCase {

    func testSearchToolApprovalRequestAndDenyOutput() async throws {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        sharedSettings.setEnableWebSearch(true)
        sharedSettings.addSearchProvider(name: "Bing", serviceType: "bing_local")
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            autoGenerateResponses: false
        )
        let input = #"{"query":"swift concurrency","max_results":2}"#

        let request = try XCTUnwrap(viewModel.searchApprovalRequestForTesting(
            toolName: "search_web",
            input: input
        ))
        XCTAssertEqual(request.title, "执行网络搜索")
        XCTAssertEqual(request.target, "swift concurrency")
        XCTAssertEqual(request.providerName, IOSFreeSearchAggregator.providerName)
        XCTAssertEqual(request.providerType, "bing_local")

        let deniedOutput = await viewModel.searchToolApprovalOutputForTesting(
            toolName: "search_web",
            input: input,
            allow: false
        )
        let deniedPayload = try jsonObject(deniedOutput)
        XCTAssertEqual(deniedPayload["ok"] as? Bool, false)
        XCTAssertEqual(deniedPayload["tool"] as? String, "search_web")
        XCTAssertEqual(deniedPayload["denied"] as? Bool, true)
        XCTAssertEqual(deniedPayload["policy"] as? String, "user_denied")
    }

    func testSearchApprovalAllowExecutesWithMockTransport() async throws {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        sharedSettings.setEnableWebSearch(true)
        sharedSettings.addSearchProvider(name: "Bing", serviceType: "bing_local")
        sharedSettings.setSearchGoogleWebViewFallbackEnabled(false)
        IOSFreeSearchAggregator.resetCooldowns()
        let transport = ChatSearchTransport(responses: [], hostResponses: [
            "www.bing.com": .html("""
            <html><body>
            <ol id="b_results">
              <li class="b_algo">
                <h2><a href="https://example.com/bing">Bing Result</a></h2>
                <p>Bing snippet from chat approval.</p>
              </li>
            </ol>
            </body></html>
            """)
        ])
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            searchTransport: transport,
            autoGenerateResponses: false
        )

        let output = await viewModel.searchToolApprovalOutputForTesting(
            toolName: "search_web",
            input: #"{"query":"amber agent","max_results":1}"#,
            allow: true
        )

        XCTAssertTrue(transport.requests.contains { $0.url?.host == "www.bing.com" })
        XCTAssertTrue(output.contains("来源：\(IOSFreeSearchAggregator.providerName)"))
        XCTAssertTrue(output.contains("Bing snippet from chat approval."))
    }

    func testCancellingSearchDoesNotStartFallbackRequest() async throws {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        sharedSettings.setEnableWebSearch(true)
        sharedSettings.addSearchProvider(name: "Bing", serviceType: "bing_local")
        sharedSettings.setSearchBuiltinDuckDuckGoEnabled(true)
        let transport = CancellingChatSearchTransport()
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            searchTransport: transport,
            autoGenerateResponses: false
        )
        let searchTask = Task { @MainActor in
            await viewModel.searchToolApprovalOutputForTesting(
                toolName: "search_web",
                input: #"{"query":"amber agent","max_results":1}"#,
                allow: true
            )
        }

        await transport.waitUntilRequestStarted()
        searchTask.cancel()
        let output = await searchTask.value

        // 免费聚合一轮会并发请求多个引擎；取消后不得再发起第二轮（备用搜索会重复请求同一主机）。
        let hosts = transport.requests.compactMap { $0.url?.host }
        XCTAssertEqual(hosts.count, Set(hosts).count, "取消不应被当作失败后继续发起备用搜索")
        let payload = try jsonObject(output)
        XCTAssertEqual(payload["reason"] as? String, "User cancelled.")
        XCTAssertEqual(payload["cancelled"] as? Bool, true)
    }

    func testSearchToolOutputReportsDisabledGateWithoutNetwork() async throws {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        sharedSettings.setEnableWebSearch(false)
        let transport = ChatSearchTransport(responses: [])
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            searchTransport: transport,
            autoGenerateResponses: false
        )

        let output = await viewModel.searchToolApprovalOutputForTesting(
            toolName: "search_web",
            input: #"{"query":"amber agent"}"#,
            allow: true
        )
        let payload = try jsonObject(output)

        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["tool"] as? String, "search_web")
        XCTAssertTrue((payload["reason"] as? String)?.contains("disabled") == true)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testWebMountClearSessionApprovalRequiresForegroundAndCanExecute() async throws {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        let settings = IOSWebMountSettings(userDefaults: defaults)
        settings.globalEnabled = true
        let cookieStore = ChatWebMountCookieStore()
        let controller = IOSWebMountController(
            registry: registry,
            settings: settings,
            cookieStore: cookieStore,
            runtime: ChatWebMountRuntime()
        )
        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: DocumentAccessStore(),
            webMountController: controller
        )
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        sharedSettings.setCapabilityGate(.webMount, enabled: true)
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: executor,
            autoGenerateResponses: false
        )
        let input = #"{"site_id":"github"}"#

        let maybeRequest = await viewModel.webMountApprovalRequestForTesting(
            toolName: "wm_clear_session",
            input: input
        )
        let request = try XCTUnwrap(maybeRequest)
        XCTAssertEqual(request.toolName, "wm_clear_session")
        XCTAssertEqual(request.title, "清除 WebMount Session")
        XCTAssertEqual(request.siteId, "github")
        XCTAssertEqual(request.host, "github.com")

        let pendingOutput = await viewModel.webMountToolOutputForTesting(toolName: "wm_clear_session", input: input)
        let pendingPayload = try jsonObject(pendingOutput)
        XCTAssertEqual(pendingPayload["ok"] as? Bool, false)
        XCTAssertEqual(pendingPayload["needs_user_action"] as? Bool, true)
        XCTAssertTrue(cookieStore.clearedSiteIds.isEmpty)

        let deniedOutput = await viewModel.webMountToolApprovalOutputForTesting(
            toolName: "wm_clear_session",
            input: input,
            allow: false
        )
        let deniedPayload = try jsonObject(deniedOutput)
        XCTAssertEqual(deniedPayload["ok"] as? Bool, false)
        XCTAssertEqual(deniedPayload["denied"] as? Bool, true)
        XCTAssertEqual(deniedPayload["policy"] as? String, "user_denied")
        XCTAssertTrue(cookieStore.clearedSiteIds.isEmpty)

        let approvedOutput = await viewModel.webMountToolApprovalOutputForTesting(
            toolName: "wm_clear_session",
            input: input,
            allow: true
        )
        let approvedPayload = try jsonObject(approvedOutput)
        XCTAssertEqual(approvedPayload["ok"] as? Bool, true)
        XCTAssertEqual(approvedPayload["site_id"] as? String, "github")
        XCTAssertEqual(cookieStore.clearedSiteIds, ["github"])
    }

    func testWebMountOpenApprovalRequestAndTimelineRedactsInput() async throws {
        let defaults = isolatedDefaults()
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        registry.setEnabled(id: "github", enabled: true)
        let controller = IOSWebMountController(
            registry: registry,
            settings: IOSWebMountSettings(userDefaults: defaults),
            runtime: ChatWebMountRuntime()
        )
        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: DocumentAccessStore(),
            webMountController: controller
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: executor,
            autoGenerateResponses: false
        )
        let input = #"{"site_id":"github","url":"https://github.com/login?token=secret"}"#

        let approvalRequest = await viewModel.webMountApprovalRequestForTesting(
            toolName: "wm_open",
            input: input
        )
        let request = try XCTUnwrap(approvalRequest)
        XCTAssertEqual(request.toolName, "wm_open")
        XCTAssertEqual(request.siteId, "github")
        XCTAssertEqual(request.host, "github.com")
        let preview = try XCTUnwrap(executor.webMountApprovalPreview(toolName: "wm_open", input: input))
        XCTAssertEqual(request.backend, preview.backend)
        XCTAssertEqual(request.mcpServerName, preview.mcpServerName)
        XCTAssertEqual(request.redactedURL, preview.redactedURL)
        XCTAssertEqual(request.snapshotId, preview.snapshotId)
        XCTAssertEqual(request.target, preview.target)
        XCTAssertEqual(request.action, preview.action)
        XCTAssertEqual(request.consequence, preview.consequence)
        XCTAssertEqual(request.screenshotRetentionWarning, preview.screenshotRetentionWarning)
        XCTAssertFalse(request.requiresHumanHandoff)
        XCTAssertFalse(request.redactedURL.contains("secret"))

        let pendingOutput = await viewModel.webMountToolOutputForTesting(toolName: "wm_open", input: input)
        let pendingPayload = try jsonObject(pendingOutput)
        XCTAssertEqual(pendingPayload["needs_user_action"] as? Bool, true)

        let toolCall = UIMessagePart.Tool(
            toolCallId: "wm-open",
            toolName: "wm_open",
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let handoffRequest = ChatToolApprovalRequestBuilder.webMount(
            for: toolCall,
            reason: "human_handoff: Complete the sensitive step in local WebMount.",
            localToolExecutor: executor
        )
        XCTAssertEqual(handoffRequest?.requiresHumanHandoff, true)
        let step = ChatToolStepModel(tool: toolCall)
        XCTAssertFalse(step.title.contains("token=secret"))
        let detail = try XCTUnwrap(step.detail)
        XCTAssertFalse(detail.contains("token=secret"))
        XCTAssertTrue(detail.contains("https://github.com/login"))
    }

    func testWebMountDirectToolExecutionHelperIsAvailableAfterUserAction() async throws {
        let defaults = isolatedDefaults()
        let settings = IOSWebMountSettings(userDefaults: defaults)
        settings.globalEnabled = false
        let cookieStore = ChatWebMountCookieStore()
        let controller = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: defaults),
            settings: settings,
            cookieStore: cookieStore,
            runtime: ChatWebMountRuntime()
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: IOSLocalToolExecutor(
                permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
                documentStore: DocumentAccessStore(),
                webMountController: controller
            ),
            autoGenerateResponses: false
        )

        let output = await viewModel.webMountToolOutputForTesting(
            toolName: "wm_clear_session",
            input: #"{"site_id":"github"}"#,
            isUserInitiated: true
        )
        let payload = try jsonObject(output)

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["site_id"] as? String, "github")
        XCTAssertEqual(cookieStore.clearedSiteIds, ["github"])
    }

    func testAdvancedToolDeclarationsFollowParityRules() throws {
        // bf53f8e 起子代理派发改由 spawn_agent 一组编排函数承担（非常驻，经 tool_search
        // 暴露），旧 subagent_dispatch 不再声明；历史里的旧调用仍需可恢复（见下方恢复断言）。
        let declaredToolNames = ["model_council_run"]
        let resumableToolNames = ["subagent_dispatch", "model_council_run"]

        let defaultViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            localToolExecutor: IOSLocalToolExecutor(
                permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
                documentStore: DocumentAccessStore()
            ),
            autoGenerateResponses: false
        )
        let defaultNames = Set(defaultViewModel.currentToolDeclarationNames())
        XCTAssertTrue(defaultNames.contains("mcp_call"), "mcp_call should be declared by default")
        for toolName in declaredToolNames {
            XCTAssertTrue(defaultNames.contains(toolName), "\(toolName) should be declared by default")
        }
        XCTAssertFalse(defaultNames.contains("subagent_dispatch"), "legacy subagent_dispatch must not be declared")
        let spawnPayload = defaultViewModel.toolExposureBridgeForTesting()?
            .executeToolSearch(argumentsJson: #"{"query":"spawn_agent","limit":1}"#) ?? ""
        XCTAssertTrue(spawnPayload.contains("spawn_agent"), "spawn_agent must stay reachable through tool_search")
        // P0-a: WebMount tools are deferred behind tool_search in the default
        // (>40 tools) config — tool_search itself is the resident discovery tool.
        XCTAssertTrue(defaultNames.contains("tool_search"), "tool_search should be declared by default")
        XCTAssertTrue(defaultNames.isDisjoint(with: IOSWebMountToolCatalog.supportedToolNames))

        let webMountDefaults = isolatedDefaults()
        let webMountSettings = IOSWebMountSettings(userDefaults: webMountDefaults)
        let webMountExecutor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: DocumentAccessStore(),
            webMountController: IOSWebMountController(
                registry: IOSWebMountRegistry(userDefaults: webMountDefaults),
                settings: webMountSettings,
                runtime: ChatWebMountRuntime()
            )
        )
        let webMountEnabledSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let webMountViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: webMountEnabledSettings,
            localToolExecutor: webMountExecutor,
            autoGenerateResponses: false
        )
        let webMountEnabledNames = Set(webMountViewModel.currentToolDeclarationNames())
        XCTAssertTrue(webMountEnabledNames.isDisjoint(with: IOSWebMountToolCatalog.supportedToolNames))
        // WebMount is still reachable: tool_search returns wm tools as expanded.
        let webMountPayload = webMountViewModel.toolExposureBridgeForTesting()?
            .executeToolSearch(argumentsJson: #"{"query":"wm_tab_list","limit":1}"#) ?? ""
        XCTAssertTrue(webMountPayload.contains("wm_tab_list"))

        let enabledViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            autoGenerateResponses: false
        )
        let enabledNames = Set(enabledViewModel.currentToolDeclarationNames())
        XCTAssertTrue(enabledNames.contains("mcp_call"), "mcp_call should stay declared without a capability gate")
        for toolName in declaredToolNames {
            XCTAssertTrue(enabledNames.contains(toolName), "\(toolName) should stay declared without a capability gate")
        }

        for toolName in ["mcp_call"] + resumableToolNames {
            let toolCall = UIMessagePart.Tool(
                toolCallId: "call-\(toolName)",
                toolName: toolName,
                input: #"{"objective":"check resume"}"#,
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
            let assistantSeed = UIMessage.companion.assistant(prompt: "")
            let assistant = UIMessage(
                id: assistantSeed.id,
                role: assistantSeed.role,
                parts: [toolCall],
                annotations: assistantSeed.annotations,
                createdAt: assistantSeed.createdAt,
                finishedAt: assistantSeed.finishedAt,
                modelId: assistantSeed.modelId,
                usage: assistantSeed.usage,
                translation: assistantSeed.translation
            )

            let resumed = enabledViewModel.finishedToolCallMessagesForTesting(
                toolCall,
                outputText: "tool result for \(toolName)",
                in: [UIMessage.companion.user(prompt: "run tool"), assistant]
            )
            let finishedTool = try XCTUnwrap(resumed.flatMap { $0.parts }.compactMap { $0 as? UIMessagePart.Tool }.first)
            let outputText = finishedTool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()

            XCTAssertEqual(finishedTool.toolName, toolName)
            XCTAssertEqual(outputText, "tool result for \(toolName)")
        }
    }

    func testFinishedAdvancedToolCallMessagesMatchExactCallId() throws {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            autoGenerateResponses: false
        )
        let subAgentCall = UIMessagePart.Tool(
            toolCallId: "advanced-subagent",
            toolName: "subagent_dispatch",
            input: #"{"objective":"audit runtime","role_id":"explorer"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let councilCall = UIMessagePart.Tool(
            toolCallId: "advanced-council",
            toolName: "model_council_run",
            input: #"{"objective":"decide fallback","mode":"parallel"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let seed = UIMessage.companion.assistant(prompt: "")
        let assistant = UIMessage(
            id: seed.id,
            role: seed.role,
            parts: [subAgentCall, councilCall],
            annotations: seed.annotations,
            createdAt: seed.createdAt,
            finishedAt: seed.finishedAt,
            modelId: seed.modelId,
            usage: seed.usage,
            translation: seed.translation
        )

        let resumed = viewModel.finishedToolCallMessagesForTesting(
            councilCall,
            outputText: "council conclusion",
            in: [UIMessage.companion.user(prompt: "run advanced tools"), assistant]
        )
        let tools = resumed.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }
        let subAgentOutput = try XCTUnwrap(tools.first { $0.toolCallId == "advanced-subagent" }).output
        let councilOutput = try XCTUnwrap(tools.first { $0.toolCallId == "advanced-council" }).output
        let councilText = councilOutput.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()

        XCTAssertTrue(subAgentOutput.isEmpty)
        XCTAssertEqual(councilText, "council conclusion")
    }

    func testFailingPendingToolCallsFillsAllUnfinishedOutputs() throws {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        let searchCall = UIMessagePart.Tool(
            toolCallId: "pending-search",
            toolName: "search_web",
            input: #"{"query":"swift concurrency"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let imageCall = UIMessagePart.Tool(
            toolCallId: "pending-image",
            toolName: "generate_image",
            input: #"{"prompt":"amber icon"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let seed = UIMessage.companion.assistant(prompt: "")
        let assistant = UIMessage(
            id: seed.id,
            role: seed.role,
            parts: [searchCall, imageCall],
            annotations: seed.annotations,
            createdAt: seed.createdAt,
            finishedAt: seed.finishedAt,
            modelId: seed.modelId,
            usage: seed.usage,
            translation: seed.translation
        )

        let failed = viewModel.failingPendingToolCallMessagesForTesting(
            outputText: "tool loop exhausted",
            in: [UIMessage.companion.user(prompt: "run tools"), assistant]
        )
        let tools = failed.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }
        let searchOutput = try XCTUnwrap(tools.first { $0.toolCallId == "pending-search" }).output
        let imageOutput = try XCTUnwrap(tools.first { $0.toolCallId == "pending-image" }).output

        XCTAssertEqual(searchOutput.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(), "tool loop exhausted")
        XCTAssertEqual(imageOutput.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(), "tool loop exhausted")
    }

    func testCompletedToolBatchStillDetectsAnUnavailableUnresolvedCall() throws {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: ChatSearchTransport(responses: []),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )
        let completedSearch = UIMessagePart.Tool(
            toolCallId: "completed-search",
            toolName: "search_web",
            input: #"{"query":"swift concurrency"}"#,
            output: [UIMessagePart.Text(text: "result", metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let unavailableImage = UIMessagePart.Tool(
            toolCallId: "unavailable-image",
            toolName: "generate_image",
            input: #"{"prompt":"amber icon"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let seed = UIMessage.companion.assistant(prompt: "")
        let assistant = UIMessage(
            id: seed.id,
            role: seed.role,
            parts: [completedSearch, unavailableImage],
            annotations: seed.annotations,
            createdAt: seed.createdAt,
            finishedAt: seed.finishedAt,
            modelId: seed.modelId,
            usage: seed.usage,
            translation: seed.translation
        )
        let messages = [UIMessage.companion.user(prompt: "run tools"), assistant]

        XCTAssertNil(runtime.nextPendingToolCall(
            in: messages,
            availableToolNames: ["search_web"]
        ))
        XCTAssertTrue(runtime.hasUnresolvedToolCall(in: messages))

        let failed = runtime.messagesByFailingPendingToolCalls(
            in: messages,
            outputText: "tool unavailable"
        )
        let failedImage = try XCTUnwrap(
            failed.flatMap(\.parts)
                .compactMap { $0 as? UIMessagePart.Tool }
                .first { $0.toolCallId == "unavailable-image" }
        )
        XCTAssertEqual(
            failedImage.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(),
            "tool unavailable"
        )
    }
}
