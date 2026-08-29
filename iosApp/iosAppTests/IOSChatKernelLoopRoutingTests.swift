import XCTest
@preconcurrency import Shared
@testable import iosApp

/// P0-2:生产默认 kernel 前台路由钉测试。
///
/// 端到端经 VM 路由入口覆盖纯文本完成、search 审批(VM 入口批准)、
/// 取消(VM 入口)与 steer 折入工具边界。provider 是剧本化
///   generateText(引擎对非流式 provider 有回退);搜索走 noop 传输。
@MainActor
final class IOSChatKernelLoopRoutingTests: XCTestCase {

    private typealias F = IOSChatForegroundFixtures

    // MARK: - 剧本化 provider

    /// generateText 轮次剧本 + 可选首轮门控(取消/steer 场景的确定性阻塞点;
    /// 取消经协作式 checkCancellation/isCancelled 传播)。
    private final class RoutingScriptedProvider: IOSAgentTextProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var rounds: [MessageChunk]
        private(set) var uploads: [[UIMessage]] = []
        private var blocked: Bool
        private(set) var observedCancellation = false

        init(rounds: [MessageChunk], blockFirstCall: Bool = false) {
            self.rounds = rounds
            self.blocked = blockFirstCall
        }

        var callCount: Int { lock.withLock { uploads.count } }

        func release() {
            lock.withLock { blocked = false }
        }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            let round = lock.withLock { () -> MessageChunk in
                uploads.append(messages)
                return rounds.isEmpty
                    ? F.chunk(with: F.assistantText("stop"), finishReason: "stop")
                    : rounds.removeFirst()
            }
            while lock.withLock({ blocked }) {
                do {
                    try Task.checkCancellation()
                } catch {
                    lock.withLock { observedCancellation = true }
                    throw error
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            // release 与取消标记的竞态:取消标记是粘性的,循环正常退出时补记。
            if Task.isCancelled {
                lock.withLock { observedCancellation = true }
            }
            return round
        }
    }

    // MARK: - 具装

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "KernelLoopRouting-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeSharedSettings(
        defaults: UserDefaults,
        enableWebSearch: Bool = false
    ) -> IOSSharedSettingsStore {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Kernel Routing Test",
            apiKey: "sk-test",
            baseUrl: "https://example.test/v1",
            modelName: "Kernel Test Model",
            modelId: "gpt-kernel-test"
        )
        let added = sharedSettings.addProvider(provider)
        let chatModel = added.models.first { $0.type == ModelType.chat }!
        sharedSettings.setCurrentChatModelId(chatModel.id.description())
        if enableWebSearch {
            sharedSettings.restoreSnapshot(
                IosSettingsMutations.shared.setEnableWebSearch(
                    settings: sharedSettings.snapshot,
                    enabled: true
                )
            )
        }
        return sharedSettings
    }

    private func makeViewModel(
        defaults: UserDefaults,
        sharedSettings: IOSSharedSettingsStore,
        autoGenerateResponses: Bool = true,
        searchTransport: any IOSSearchHTTPTransport = IOSForegroundNoopSearchTransport()
    ) -> ChatViewModel {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernel-routing-\(UUID().uuidString).db")
            .path
        let db = IosDatabaseFactory.shared.createDatabase(atFilePath: dbPath)
        return ChatViewModel(
            settingsStore: SettingsStore(userDefaults: defaults, storageKey: "kernel-routing-settings"),
            sharedSettings: sharedSettings,
            searchTransport: searchTransport,
            autoGenerateResponses: autoGenerateResponses,
            agentRuntimeDao: db.agentRuntimeDao()
        )
    }

    private func waitForCondition(
        timeoutSeconds: Double = 10,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func toolRound(_ toolCallId: String, _ toolName: String, _ input: String) -> MessageChunk {
        F.chunk(with: F.assistantMessage(parts: [
            UIMessagePart.Tool(
                toolCallId: toolCallId,
                toolName: toolName,
                input: input,
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            ),
        ]), finishReason: "stop")
    }

    private func textRound(_ text: String) -> MessageChunk {
        F.chunk(with: F.assistantText(text), finishReason: "stop")
    }

    // MARK: - 端到端(生产默认路径,经 VM 路由入口)

    /// 纯文本:sendMessage → 内核 run → completed;回复上屏、加载态回落。
    /// 若误路由到 CGC,真实网络打 example.test 必失败——断言文本即钉住路由。
    func testKernelRouteTextRunEndToEnd() async {
        let defaults = makeIsolatedDefaults()
        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: makeSharedSettings(defaults: defaults)
        )
        let provider = RoutingScriptedProvider(rounds: [textRound("内核回复")])
        viewModel.kernelTextProviderOverrideForTesting = provider

        viewModel.inputText = "你好"
        XCTAssertTrue(viewModel.sendMessage())

        let done = await waitForCondition {
            !viewModel.isLoading && viewModel.messages.last?.toText() == "内核回复"
        }
        XCTAssertTrue(done, "内核 run 必须完成并上屏回复,messages=\(viewModel.messages.map { $0.toText() })")
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(viewModel.messages.first?.toText(), "你好")
    }

    /// search 审批:VM 的 approvePendingSearchTool 必须路由到 kernel Host
    /// (暂停 → 批准 → 执行 → 续跑第二轮 → completed)。
    func testKernelRouteSearchApprovalViaVMEntry() async {
        let defaults = makeIsolatedDefaults()
        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: makeSharedSettings(defaults: defaults, enableWebSearch: true)
        )
        let provider = RoutingScriptedProvider(rounds: [
            toolRound("tc-1", "search_web", #"{"query":"amber"}"#),
            textRound("搜索完成"),
        ])
        viewModel.kernelTextProviderOverrideForTesting = provider

        viewModel.inputText = "查一下"
        XCTAssertTrue(viewModel.sendMessage())

        let paused = await waitForCondition { viewModel.pendingSearchApproval != nil }
        let toolDump = viewModel.messages.flatMap(\.parts).compactMap { part -> String? in
            guard let tool = part as? UIMessagePart.Tool else { return nil }
            let output = tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: "|")
            return "\(tool.toolName)[\(tool.toolCallId)] output=\(output.prefix(160))"
        }.joined(separator: " ;; ")
        XCTAssertTrue(paused, "审批卡必须经共享 bindings 发布到 VM; tools=\(toolDump)")
        viewModel.approvePendingSearchTool()

        let done = await waitForCondition {
            !viewModel.isLoading && viewModel.messages.last?.toText() == "搜索完成"
        }
        XCTAssertTrue(done)
        XCTAssertEqual(provider.callCount, 2, "批准后必须续跑第二轮模型")
        XCTAssertNil(viewModel.pendingSearchApproval)
    }

    /// 取消:VM 的 cancelGeneration 必须路由到 kernel Host——在途 provider
    /// 协作式收到取消,加载态回落,不产生 assistant 气泡。
    func testKernelRouteCancelViaVMEntry() async {
        let defaults = makeIsolatedDefaults()
        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: makeSharedSettings(defaults: defaults)
        )
        let provider = RoutingScriptedProvider(
            rounds: [textRound("不应到达")],
            blockFirstCall: true
        )
        viewModel.kernelTextProviderOverrideForTesting = provider

        viewModel.inputText = "你好"
        XCTAssertTrue(viewModel.sendMessage())

        let inFlight = await waitForCondition { provider.callCount >= 1 }
        XCTAssertTrue(inFlight)
        viewModel.cancelGeneration()

        let done = await waitForCondition { !viewModel.isLoading }
        XCTAssertTrue(done)
        XCTAssertTrue(provider.observedCancellation, "取消必须经 VM 路由抵达内核在途调用")
        XCTAssertEqual(viewModel.messages.count, 1, "首轮未完成即取消,不得留下 assistant 气泡")
    }

    /// steer:kernel run 在途时 sendMessage 必须入队(isGenerationActive 的
    /// 驱动者感知本身就是被测点),并在工具循环边界折入下一轮 upload。
    /// tool_search 对真实桥执行,免审批免网络。
    func testKernelRouteSteerFoldsAtToolBoundary() async {
        let defaults = makeIsolatedDefaults()
        let viewModel = makeViewModel(
            defaults: defaults,
            sharedSettings: makeSharedSettings(defaults: defaults)
        )
        let provider = RoutingScriptedProvider(
            rounds: [
                toolRound("tc-1", "tool_search", #"{"query":"search"}"#),
                textRound("第二轮回答"),
            ],
            blockFirstCall: true
        )
        viewModel.kernelTextProviderOverrideForTesting = provider

        viewModel.inputText = "第一轮"
        XCTAssertTrue(viewModel.sendMessage())

        let inFlight = await waitForCondition { provider.callCount >= 1 }
        XCTAssertTrue(inFlight)
        viewModel.inputText = "插队指令"
        XCTAssertTrue(viewModel.sendMessage(), "kernel run 在途时发送必须落入 steer 队列")
        XCTAssertEqual(viewModel.steerQueue.map(\.text), ["插队指令"])
        provider.release()

        let done = await waitForCondition {
            !viewModel.isLoading && viewModel.messages.last?.toText() == "第二轮回答"
        }
        XCTAssertTrue(done)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertTrue(viewModel.steerQueue.isEmpty, "边界消费后队列必须清空")
        let secondUpload = provider.uploads.count > 1 ? provider.uploads[1] : []
        XCTAssertTrue(
            secondUpload.contains { $0.role == MessageRole.user && $0.toText().contains("插队指令") },
            "steer 消息必须在工具边界折入第二轮 upload"
        )
    }
}
