import XCTest
@testable import iosApp
import Shared

/// P0-2 B2: 前台内核执行器适配的单元测试。
///
/// 钉三件事:
/// 1. 审批命中时执行器返回 `.needsApproval` 并把审批卡登记进 prompt 盒
///   (按 toolCallId 键控);
/// 2. 免审批路径(auto-approve 或纯本地工具)真实执行,`.filledParts` 携带
///    回填后的 output parts。
/// 3. 未知工具不被注册。
@MainActor
final class IOSForegroundToolExecutorsTests: XCTestCase {

    private typealias F = IOSChatForegroundFixtures

    private func makeRuntime(
        searchTransport: any IOSSearchHTTPTransport = IOSForegroundNoopSearchTransport(),
        enableWebSearch: Bool = true
    ) -> (ChatToolRuntime, SettingsStore, IOSSharedSettingsStore) {
        let suite = "app.amber.ios.tests.foregroundexec.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settingsStore = SettingsStore(userDefaults: defaults, storageKey: "settings-\(UUID().uuidString)")
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        sharedSettings.setEnableWebSearch(enableWebSearch)
        let runtime = ChatToolRuntime(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: searchTransport,
            mcpManager: IOSMcpManager(sharedSettings: sharedSettings, configStore: .shared)
        )
        return (runtime, settingsStore, sharedSettings)
    }

    private func makeToolCall(id: String, name: String, input: String = "{}") -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: id,
            toolName: name,
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
    }

    // MARK: - 1. 审批门:needsApproval + prompt 盒登记

    func testSearchExecutorGatesApprovalAndRegistersPrompt() async {
        UserDefaults.standard.set(false, forKey: "app.amber.ios.globalAutoApprove")
        defer { UserDefaults.standard.set(false, forKey: "app.amber.ios.globalAutoApprove") }
        let (runtime, _, _) = makeRuntime()
        let bridge = IosToolExposureBridge(
            tools: ToolKt.iosToolDeclarations(names: ["search_web"])
        )
        let box = ChatToolRuntime.IOSForegroundApprovalPromptBox()
        let baseMessages = [F.userMessage("搜一下")]
        let executors = runtime.foregroundToolExecutors(
            providerSetting: F.makeProviderSetting(),
            params: F.makeParams(toolNames: [], tools: bridge.visibleTools()),
            runId: "run-b2-approval",
            startedAt: 1,
            inputDigest: "digest",
            conversationId: nil,
            toolExposureBridge: bridge,
            baseMessagesProvider: { baseMessages },
            approvalPromptBox: box
        )

        let executor = try! XCTUnwrap(executors["search_web"], "可见集里的 search_web 必须注册执行器")
        let outcome = await Self.executeOffMainActor(UncheckedExecuteInput(
            executor: executor,
            tool: makeToolCall(id: "tc-1", name: "search_web", input: #"{"query":"amber"}"#)
        ))

        guard case .needsApproval = outcome else {
            return XCTFail("未开 auto-approve 时搜索必须暂停待审批,实际 \(outcome)")
        }
        guard case .search(let request) = box.take("tc-1") else {
            return XCTFail("审批卡必须按 toolCallId 登记进盒子")
        }
        XCTAssertEqual(request.toolName, "search_web")
    }

    // MARK: - 2. 免审批路径:真实执行并携带 output parts

    func testSearchExecutorExecutesWhenGlobalAutoApproveOn() async {
        UserDefaults.standard.set(true, forKey: "app.amber.ios.globalAutoApprove")
        defer { UserDefaults.standard.set(false, forKey: "app.amber.ios.globalAutoApprove") }
        let (runtime, _, _) = makeRuntime()
        let bridge = IosToolExposureBridge(
            tools: ToolKt.iosToolDeclarations(names: ["search_web"])
        )
        let box = ChatToolRuntime.IOSForegroundApprovalPromptBox()
        let toolCall = makeToolCall(id: "tc-9", name: "search_web", input: #"{"query":"amber"}"#)
        let baseMessages = [F.userMessage("搜一下"), F.assistantMessage(parts: [toolCall])]
        let executors = runtime.foregroundToolExecutors(
            providerSetting: F.makeProviderSetting(),
            params: F.makeParams(toolNames: [], tools: bridge.visibleTools()),
            runId: "run-b2-exec",
            startedAt: 1,
            inputDigest: "digest",
            conversationId: nil,
            toolExposureBridge: bridge,
            baseMessagesProvider: { baseMessages },
            approvalPromptBox: box
        )

        let outcome = await Self.executeOffMainActor(UncheckedExecuteInput(
            executor: executors["search_web"]!,
            tool: toolCall
        ))

        guard case .filledParts(let parts) = outcome else {
            return XCTFail("auto-approve 下搜索应真实执行,实际 \(outcome)")
        }
        let text = parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
        XCTAssertTrue(text.contains("Amber Result"), "noop 传输的最小结果页应进入 output,实际:\(text)")
        XCTAssertNil(box.take("tc-9"), "已执行的调用不得残留审批卡")
    }

    func testToolSearchExecutorRunsLocallyThroughBridge() async {
        let (runtime, _, _) = makeRuntime()
        let bridge = IosToolExposureBridge(
            tools: ToolKt.iosToolDeclarations(names: ["search_web"])
        )
        let box = ChatToolRuntime.IOSForegroundApprovalPromptBox()
        let toolCall = makeToolCall(id: "tc-2", name: "tool_search", input: #"{"query":"search"}"#)
        let executors = runtime.foregroundToolExecutors(
            providerSetting: F.makeProviderSetting(),
            params: F.makeParams(toolNames: [], tools: bridge.visibleTools()),
            runId: "run-b2-toolsearch",
            startedAt: 1,
            inputDigest: "digest",
            conversationId: nil,
            toolExposureBridge: bridge,
            baseMessagesProvider: { [F.userMessage("hi"), F.assistantMessage(parts: [toolCall])] },
            approvalPromptBox: box
        )

        let outcome = await Self.executeOffMainActor(UncheckedExecuteInput(
            executor: executors["tool_search"]!,
            tool: toolCall
        ))

        guard case .filledParts(let parts) = outcome else {
            return XCTFail("tool_search 是纯本地发现调用,必须直接执行,实际 \(outcome)")
        }
        let text = parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
        XCTAssertTrue(text.contains("expanded_tools"), "tool_search 输出应是发现载荷,实际:\(text)")
    }

    // MARK: - 3. 未知名不注册(引擎侧诚实的 no-executor 失败)

    func testUnknownToolNameIsNotRegistered() {
        let (runtime, _, _) = makeRuntime()
        let bridge = IosToolExposureBridge(
            tools: ToolKt.iosToolDeclarations(names: ["search_web"])
        )
        let executors = runtime.foregroundToolExecutors(
            providerSetting: F.makeProviderSetting(),
            params: F.makeParams(toolNames: [], tools: bridge.visibleTools()),
            runId: "run-b2-unknown",
            startedAt: 1,
            inputDigest: "digest",
            conversationId: nil,
            toolExposureBridge: bridge,
            baseMessagesProvider: { [F.userMessage("hi")] },
            approvalPromptBox: ChatToolRuntime.IOSForegroundApprovalPromptBox()
        )

        XCTAssertNil(executors["definitely_not_a_tool"])
        XCTAssertNotNil(executors["search_web"])
        XCTAssertNotNil(executors["tool_search"], "桥自动追加的发现工具必须有执行器")
    }

    // MARK: - 跨隔离调用辅助

    /// 执行器存在性值与 KMP 工具部件均非 Sendable;测试把所有权一次性交给
    /// 非隔离执行入口(生产侧由引擎在非隔离上下文调用,无需此盒)。
    private struct UncheckedExecuteInput: @unchecked Sendable {
        let executor: any IOSToolExecutor
        let tool: UIMessagePart.Tool
    }

    private nonisolated static func executeOffMainActor(
        _ input: UncheckedExecuteInput
    ) async -> IOSAgentToolOutcome {
        await input.executor.execute(tool: input.tool, isUserInitiated: false)
    }
}
