import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSSearchPermissionTests: XCTestCase {
    override func setUp() async throws {
        IOSFreeSearchAggregator.resetCooldowns()
    }

    func testDisabledSearchBlocksForegroundBackgroundAndExplicitApprovalWithoutRequests() async throws {
        let fixture = try SearchPermissionFixture()
        defer { fixture.close() }
        let policy = fixture.policy(.disabled, globalAutoApprove: true, highRiskAutoApprove: true)
        let foreground = try fixture.foregroundExecutor(policy: policy)

        let foregroundOutcome = await Self.execute(Invocation(executor: foreground.executor, tool: fixture.call))
        guard case .filledParts(let deniedParts) = foregroundOutcome else {
            return XCTFail("A disabled foreground search must finish with a policy denial, got \(foregroundOutcome)")
        }
        XCTAssertNotNil(ChatToolOutputFormatter.failureReason(from: deniedParts))
        XCTAssertNil(foreground.prompts.take(fixture.call.toolCallId))

        let background = try fixture.backgroundExecutor(policy: policy)
        let backgroundOutcome = await Self.execute(Invocation(executor: background, tool: fixture.call))
        guard case .denied = backgroundOutcome else {
            return XCTFail("A disabled background search must be denied, got \(backgroundOutcome)")
        }

        let approved = await fixture.runtime.finishSearchApproval(pending: fixture.pending(policy: policy), allow: true)
        let approvedCall = try XCTUnwrap(approved.last?.parts.first as? UIMessagePart.Tool)
        XCTAssertNotNil(ChatToolOutputFormatter.failureReason(from: approvedCall.output),
                        "Explicit approval cannot override a disabled capability")

        let scrape = fixture.makeCall(name: "scrape_web", input: #"{"url":"https://example.com/page"}"#)
        let scrapeOutput = await IOSExecutionPolicyContext.$snapshot.withValue(policy) {
            await fixture.runtime.dispatchSearchToolOutput(scrape, isUserInitiated: true)
        }
        XCTAssertNotNil(ChatToolOutputFormatter.failureReason(from: scrapeOutput.parts))
        XCTAssertTrue(fixture.transport.requests.isEmpty)
    }

    func testCapabilityAutoApprovalExecutesForegroundAndBackgroundWithGlobalApprovalOff() async throws {
        let fixture = try SearchPermissionFixture()
        defer { fixture.close() }
        let policy = fixture.policy(.autoApprove)
        let foreground = try fixture.foregroundExecutor(policy: policy)

        let foregroundOutcome = await Self.execute(Invocation(executor: foreground.executor, tool: fixture.call))
        assertSearchResult(foregroundOutcome)
        XCTAssertNil(foreground.prompts.take(fixture.call.toolCallId))
        let afterForeground = fixture.transport.requests.count
        XCTAssertGreaterThan(afterForeground, 0)

        let background = try fixture.backgroundExecutor(policy: policy)
        let backgroundOutcome = await Self.execute(Invocation(executor: background, tool: fixture.call))
        assertSearchResult(backgroundOutcome)
        XCTAssertGreaterThan(fixture.transport.requests.count, afterForeground)
    }

    func testAskPolicyDoesNotRequestUntilTheSearchApprovalIsAccepted() async throws {
        let fixture = try SearchPermissionFixture()
        defer { fixture.close() }
        let policy = fixture.policy(.askEveryTime)
        let foreground = try fixture.foregroundExecutor(policy: policy)

        let waiting = await Self.execute(Invocation(executor: foreground.executor, tool: fixture.call))
        guard case .needsApproval = waiting else {
            return XCTFail("The foreground search must wait for approval, got \(waiting)")
        }
        XCTAssertNotNil(foreground.prompts.take(fixture.call.toolCallId))
        let background = try fixture.backgroundExecutor(policy: policy)
        let backgroundOutcome = await Self.execute(Invocation(executor: background, tool: fixture.call))
        guard case .denied = backgroundOutcome else {
            return XCTFail("Background execution cannot display the required search approval, got \(backgroundOutcome)")
        }
        XCTAssertTrue(fixture.transport.requests.isEmpty)

        let completed = await fixture.runtime.finishSearchApproval(pending: fixture.pending(policy: policy), allow: true)
        let completedCall = try XCTUnwrap(completed.last?.parts.first as? UIMessagePart.Tool)
        XCTAssertNil(ChatToolOutputFormatter.failureReason(from: completedCall.output))
        XCTAssertTrue(completedCall.output.compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined().contains(SearchPermissionTransport.resultTitle))
        XCTAssertFalse(fixture.transport.requests.isEmpty)
    }

    func testFrozenRunPolicyWinsOverLaterLivePermissionAndSearchSwitchChanges() async throws {
        let fixture = try SearchPermissionFixture()
        defer { fixture.close() }
        let frozenAllowed = fixture.policy(.autoApprove)
        fixture.permissions.setPolicy(.disabled, for: fixture.searchCapability)
        fixture.sharedSettings.setEnableWebSearch(false)

        let allowedOutput = await IOSExecutionPolicyContext.$snapshot.withValue(frozenAllowed) {
            await fixture.runtime.dispatchSearchToolOutput(fixture.call)
        }
        XCTAssertNil(ChatToolOutputFormatter.failureReason(from: allowedOutput.parts))
        XCTAssertTrue(allowedOutput.text.contains(SearchPermissionTransport.resultTitle))
        XCTAssertFalse(fixture.transport.requests.isEmpty)
        guard case .denied = fixture.runtime.searchToolPermission() else {
            return XCTFail("Calls outside the run must observe the live disabled policy")
        }

        let frozenDenied = fixture.policy(.disabled)
        fixture.permissions.setPolicy(.autoApprove, for: fixture.searchCapability)
        fixture.sharedSettings.setEnableWebSearch(true)
        let requestsBeforeDeniedCall = fixture.transport.requests.count
        let deniedOutput = await IOSExecutionPolicyContext.$snapshot.withValue(frozenDenied) {
            await fixture.runtime.dispatchSearchToolOutput(fixture.call)
        }
        XCTAssertNotNil(ChatToolOutputFormatter.failureReason(from: deniedOutput.parts))
        XCTAssertEqual(fixture.transport.requests.count, requestsBeforeDeniedCall)
        XCTAssertEqual(fixture.runtime.searchToolPermission(), .allow,
                       "The live automatic policy remains distinct from the frozen denied run")
    }

    func testNovelSearchExecutorsRespectTheirCapturedSearchPermission() async throws {
        let fixture = try SearchPermissionFixture()
        defer { fixture.close() }
        for policy in [IOSAgentPermissionPolicy.askEveryTime, .disabled, .autoApprove] {
            let executors = IOSExecutionPolicyContext.$snapshot.withValue(fixture.policy(policy)) {
                fixture.runtime.novelDiscussionToolExecutors()
            }
            let executor = try XCTUnwrap(executors["search_web"])
            let outcome = await Self.execute(Invocation(executor: executor, tool: fixture.call))
            switch (policy, outcome) {
            case (.askEveryTime, .needsApproval), (.disabled, .denied):
                XCTAssertTrue(fixture.transport.requests.isEmpty)
            case (.autoApprove, .filled(let text)):
                XCTAssertTrue(text.contains(SearchPermissionTransport.resultTitle))
                XCTAssertFalse(fixture.transport.requests.isEmpty)
            default:
                XCTFail("Unexpected Novel search outcome for \(policy): \(outcome)")
            }
        }
    }

    private func assertSearchResult(
        _ outcome: IOSAgentToolOutcome, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .filledParts(let parts) = outcome else {
            return XCTFail("Expected successful structured search output, got \(outcome)", file: file, line: line)
        }
        XCTAssertNil(ChatToolOutputFormatter.failureReason(from: parts), file: file, line: line)
        XCTAssertTrue(parts.compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined().contains(SearchPermissionTransport.resultTitle), file: file, line: line)
    }

    // The engine calls non-Sendable KMP tool parts through its nonisolated executor interface.
    private struct Invocation: @unchecked Sendable {
        let executor: any IOSToolExecutor
        let tool: UIMessagePart.Tool
    }

    private nonisolated static func execute(_ invocation: Invocation) async -> IOSAgentToolOutcome {
        await invocation.executor.execute(tool: invocation.tool, isUserInitiated: false)
    }
}

@MainActor
private final class SearchPermissionFixture {
    private typealias F = IOSChatForegroundFixtures
    private let suite: String
    private let defaults: UserDefaults
    private let workspaceDirectory: URL
    let permissions: IOSPermissionStore
    let searchCapability: IOSPlatformCapability
    let sharedSettings: IOSSharedSettingsStore
    let runtime: ChatToolRuntime
    let transport: SearchPermissionTransport
    let call: UIMessagePart.Tool
    private let provider = F.makeProviderSetting()
    private let params = F.makeParams(toolNames: ["search_web"])

    init() throws {
        let suite = "SearchPermission.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspaceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let permissions = IOSPermissionStore(userDefaults: defaults, taskStore: nil)
        let searchCapability = try XCTUnwrap(IOSCapabilityRegistry.capabilities.first {
            $0.id == IOSSearchToolPermission.capabilityId
        })
        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: defaults, loadCredential: { _ in nil },
            storeCredential: { _, _ in true }, deleteCredential: { _ in true }
        )
        sharedSettings.setEnableWebSearch(true)
        sharedSettings.setSearchGoogleWebViewFallbackEnabled(false)
        let settings = SettingsStore(userDefaults: defaults, apiKeyStore: SearchPermissionEmptyKeyStore())
        let executor = IOSLocalToolExecutor(
            permissionStore: permissions,
            documentStore: DocumentAccessStore(),
            workspaceStore: IOSWorkspaceStore(baseDirectory: workspaceDirectory)
        )
        let transport = SearchPermissionTransport()
        let runtime = ChatToolRuntime(
            settingsStore: settings, sharedSettings: sharedSettings, localToolExecutor: executor,
            searchTransport: transport,
            mcpManager: IOSMcpManager(sharedSettings: sharedSettings, configStore: IOSMcpConfigStore(userDefaults: defaults))
        )
        self.suite = suite
        self.defaults = defaults
        self.workspaceDirectory = workspaceDirectory
        self.permissions = permissions
        self.searchCapability = searchCapability
        self.sharedSettings = sharedSettings
        self.transport = transport
        self.runtime = runtime
        call = Self.call(name: "search_web", input: #"{"query":"权限检查","max_results":1}"#)
    }

    func close() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: workspaceDirectory)
    }

    func policy(
        _ policy: IOSAgentPermissionPolicy,
        globalAutoApprove: Bool = false,
        highRiskAutoApprove: Bool = false
    ) -> IOSExecutionPolicySnapshot {
        IOSExecutionPolicySnapshot(
            capabilityPolicies: [IOSSearchToolPermission.capabilityId: policy.rawValue],
            globalAutoApproveEnabled: globalAutoApprove, highRiskAutoApproveEnabled: highRiskAutoApprove,
            execJavaScriptEnabled: false, webSearchEnabled: true
        )
    }

    func foregroundExecutor(policy: IOSExecutionPolicySnapshot) throws
        -> (executor: any IOSToolExecutor, prompts: ChatToolRuntime.IOSForegroundApprovalPromptBox) {
        let prompts = ChatToolRuntime.IOSForegroundApprovalPromptBox()
        let messages = pending(policy: policy).baseMessages
        let executors = runtime.foregroundToolExecutors(
            providerSetting: provider, params: params, runId: "search-permission-foreground",
            startedAt: 1, inputDigest: "search-permission", conversationId: nil,
            toolExposureBridge: nil, baseMessagesProvider: { messages },
            approvalPromptBox: prompts, executionPolicy: policy
        )
        return (try XCTUnwrap(executors["search_web"]), prompts)
    }

    func backgroundExecutor(policy: IOSExecutionPolicySnapshot) throws -> any IOSToolExecutor {
        try XCTUnwrap(runtime.backgroundToolExecutors(
            providerSetting: provider, params: params, runId: "search-permission-background",
            executionPolicy: policy
        )["search_web"])
    }

    func pending(policy: IOSExecutionPolicySnapshot) -> ChatPendingToolApproval {
        ChatPendingToolApproval(
            toolCall: call, providerSetting: provider, params: params, runId: "search-permission-approval",
            startedAt: 1, inputDigest: "search-permission", conversationId: nil,
            baseMessages: [F.userMessage("搜索资料"), F.assistantMessage(parts: [call])],
            executionPolicy: policy
        )
    }

    func makeCall(name: String, input: String) -> UIMessagePart.Tool {
        Self.call(name: name, input: input)
    }

    private static func call(name: String, input: String) -> UIMessagePart.Tool {
        UIMessagePart.Tool(
            toolCallId: "search-permission-\(UUID().uuidString)", toolName: name, input: input,
            output: [], approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
        )
    }
}

@MainActor
private final class SearchPermissionTransport: IOSSearchHTTPTransport {
    static let resultTitle = "Permission Fixture Result"
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        requests.append(request)
        let html = request.url?.host == "www.bing.com" ? """
        <ol id="b_results"><li class="b_algo"><h2><a href="https://example.com/permission">\(Self.resultTitle)</a></h2><p>Permission fixture snippet.</p></li></ol>
        """ : ""
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        ))
        return (response, Data(html.utf8))
    }
}

private struct SearchPermissionEmptyKeyStore: SettingsAPIKeyStore {
    func loadApiKey() -> String? { nil }
    func saveApiKey(_ key: String) -> Bool { true }
}
