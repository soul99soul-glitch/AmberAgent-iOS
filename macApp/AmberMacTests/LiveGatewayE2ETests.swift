import Foundation
import XCTest
@testable import AmberMac

/// Opt-in live end-to-end tests: the real production runtime (DesktopWorkspace + DesktopAgentProvider +
/// DesktopKMPProvider + DesktopKMPConversationStorage) against a real Anthropic-compatible gateway.
/// Skipped unless AMBER_MAC_LIVE_BASE_URL / AMBER_MAC_LIVE_API_KEY / AMBER_MAC_LIVE_MODEL are set.
@MainActor
final class LiveGatewayE2ETests: XCTestCase {
    private final class SilentDelivery: DesktopNotificationDelivery {
        func requestAuthorization() async throws -> Bool { false }
        func isAuthorized() async -> Bool { false }
        func send(identifier: String, title: String, body: String, userInfo: [String: String]) async throws {}
    }

    /// Everything that must survive a simulated relaunch.
    private struct Environment {
        let root: URL
        let defaults: UserDefaults
        let credentials: DesktopMemoryCredentials
    }

    private var environments: [(URL, String)] = []

    override func tearDown() async throws {
        for (root, suite) in environments {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        environments = []
    }

    private func liveValues() throws -> (baseURL: String, apiKey: String, model: String) {
        let env = ProcessInfo.processInfo.environment
        let values = ["AMBER_MAC_LIVE_BASE_URL", "AMBER_MAC_LIVE_API_KEY", "AMBER_MAC_LIVE_MODEL"].map { env[$0] ?? "" }
        guard values.allSatisfy({ !$0.isEmpty && !$0.contains("$(") }) else {
            throw XCTSkip("Set AMBER_MAC_LIVE_BASE_URL, AMBER_MAC_LIVE_API_KEY and AMBER_MAC_LIVE_MODEL to run live gateway tests.")
        }
        var base = values[0]
        while base.hasSuffix("/") { base.removeLast() }
        // Mirrors DesktopProviderKind.claude.defaultBaseURL ("https://api.anthropic.com/v1").
        if !base.hasSuffix("/v1") { base += "/v1" }
        return (base, values[1], values[2])
    }

    private var lastAgentProvider: DesktopAgentProvider?

    private func makeEnvironment(toolsEnabled: Bool = false) throws -> Environment {
        let live = try liveValues()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("amber-live-e2e-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "amber.live.e2e.\(UUID().uuidString)"
        environments.append((root, suite))
        let environment = Environment(root: root, defaults: UserDefaults(suiteName: suite)!, credentials: DesktopMemoryCredentials())
        let settings = DesktopSettings(defaults: environment.defaults, credentials: environment.credentials)
        let config = DesktopProviderConfiguration(name: "Live gateway", kind: .claude, baseURL: live.baseURL, modelID: live.model)
        for existing in settings.providers { try settings.deleteProvider(existing.id) }
        try settings.saveProvider(config, apiKey: live.apiKey)
        settings.selectedProviderID = config.id
        environment.defaults.set(toolsEnabled, forKey: "desktop.agent-tools-enabled")
        return environment
    }

    /// Same wiring as DesktopLiveWorkspace.swift, but on a temp root, suite defaults and in-memory credentials.
    private func makeWorkspace(_ environment: Environment) -> DesktopWorkspace {
        let directory = environment.root
        let defaults = environment.defaults
        let settings = DesktopSettings(defaults: defaults, credentials: environment.credentials)
        let notifications = DesktopNotifications(settings: settings, delivery: SilentDelivery())
        let files = DesktopWorkspaceFiles(directory: directory.appendingPathComponent("workspaces", isDirectory: true))
        let tasks = DesktopAgentTasks(directory: directory.appendingPathComponent("agent-runs", isDirectory: true),
            defaults: defaults, notifications: notifications)
        let knowledge = DesktopKnowledgeStore(directory: directory.appendingPathComponent("knowledge", isDirectory: true))
        let mcp = DesktopMCPManager(store: DesktopMCPStore(defaults: defaults, credentials: environment.credentials))
        let webDAV = DesktopWebDAVManager(defaults: defaults, credentials: environment.credentials)
        let searchSettings = DesktopSearchSettings(defaults: defaults, credentials: environment.credentials)
        let imageGeneration = DesktopImageGeneration(settings: settings, files: files, enabled: true)
        let text = DesktopKMPProvider()
        let collaborations = DesktopCollaborations(settings: settings, provider: text,
            directory: directory.appendingPathComponent("collaborations", isDirectory: true), notifications: notifications)
        let provider = DesktopAgentProvider(text: text, tasks: tasks, files: files, knowledge: knowledge, mcp: mcp,
            collaborations: collaborations, searchSettings: searchSettings)
        lastAgentProvider = provider
        let names = Set((DesktopToolRegistry.declarations + DesktopToolRegistry.knowledgeDeclarations + DesktopMCPManager.declarations).map(\.name))
        let recipes = DesktopRecipeRuns(store: DesktopRecipeStore(directory: directory, registeredTools: names), tasks: tasks) {
            try await provider.performRecipeTool(runID: $0, owner: $1, name: $2, argumentsJSON: $3)
        }
        return DesktopWorkspace(settings: settings,
            storage: DesktopKMPConversationStorage(directory: directory.appendingPathComponent("conversations", isDirectory: true)),
            provider: provider, insights: DesktopConversationInsights(directory: directory.appendingPathComponent("conversation-insights", isDirectory: true)),
            files: files, agentTasks: tasks, knowledge: knowledge, mcp: mcp, collaborations: collaborations, recipes: recipes, webDAV: webDAV,
            notifications: notifications, storageUsageSources: DesktopStorageUsage.sources(
                amberRoot: directory, knowledgeDirectory: knowledge.directory),
            imageGeneration: imageGeneration, searchSettings: searchSettings)
    }

    private func waitUntil(timeout: Duration = .seconds(120), _ description: String,
        _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for: \(description)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func failureContext(_ workspace: DesktopWorkspace) -> String {
        let last = workspace.selectedConversation?.messages.last
        return "error=\(workspace.errorMessage ?? "nil") lastRole=\(String(describing: last?.role)) state=\(String(describing: last?.state)) text=\(last?.text.prefix(300) ?? "")"
    }

    private func send(_ text: String, in workspace: DesktopWorkspace) async {
        await workspace.waitUntilLoaded()
        workspace.createConversation()
        workspace.draft = text
        workspace.send()
    }

    // 1. Real round-trip + persistence across a simulated relaunch.
    func testSendCompletesAndPersistsAcrossRelaunch() async throws {
        let environment = try makeEnvironment()
        let workspace = makeWorkspace(environment)
        await send("只回复两个字：你好", in: workspace)
        XCTAssertTrue(workspace.isGenerating, failureContext(workspace))
        try await waitUntil("generation finished") { !workspace.isGenerating }
        let flushed = await workspace.flush()
        XCTAssertTrue(flushed)
        let conversation = try XCTUnwrap(workspace.selectedConversation)
        XCTAssertEqual(conversation.messages.count, 2, failureContext(workspace))
        let reply = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(reply.role, .assistant)
        XCTAssertEqual(reply.state, .complete, failureContext(workspace))
        XCTAssertFalse(reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, failureContext(workspace))

        let relaunched = makeWorkspace(environment)
        await relaunched.waitUntilLoaded()
        relaunched.select(conversation.id)
        await relaunched.waitUntilSelectedConversationLoaded()
        let restored = try XCTUnwrap(relaunched.selectedConversation, relaunched.errorMessage ?? "conversation not restored")
        XCTAssertEqual(restored.messages.map(\.id), conversation.messages.map(\.id))
        XCTAssertEqual(restored.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(restored.messages.map(\.text), conversation.messages.map(\.text))
        XCTAssertEqual(restored.messages.last?.state, .complete)
    }

    // 2. Stop mid-stream keeps (and persists) the accepted partial text.
    func testStopKeepsAndPersistsPartialText() async throws {
        let environment = try makeEnvironment()
        let workspace = makeWorkspace(environment)
        await send("从1数到300，每个数字一行，不要省略，不要其它内容。", in: workspace)
        try await waitUntil("first streamed text") {
            !(workspace.selectedConversation?.messages.last?.text.isEmpty ?? true) || !workspace.isGenerating
        }
        XCTAssertTrue(workspace.isGenerating, "stream ended before stop could be exercised: \(failureContext(workspace))")
        workspace.stop()
        let stopFlushed = await workspace.flush()
        XCTAssertTrue(stopFlushed)
        try await waitUntil(timeout: .seconds(30), "stop settled") { !workspace.isGenerating }
        let flushed = await workspace.flush()
        XCTAssertTrue(flushed)
        let conversation = try XCTUnwrap(workspace.selectedConversation)
        let reply = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(reply.role, .assistant)
        XCTAssertEqual(reply.state, .cancelled, failureContext(workspace))
        XCTAssertFalse(reply.text.isEmpty)
        XCTAssertFalse(reply.text.hasSuffix("300"), "reply looks complete, stop had no effect")

        let relaunched = makeWorkspace(environment)
        await relaunched.waitUntilLoaded()
        relaunched.select(conversation.id)
        await relaunched.waitUntilSelectedConversationLoaded()
        let restored = try XCTUnwrap(relaunched.selectedConversation?.messages.last)
        XCTAssertEqual(restored.id, reply.id)
        XCTAssertEqual(restored.state, .cancelled)
        XCTAssertEqual(restored.text, reply.text)
    }

    // 3. Agent loop: the model calls workspace_file_write, the run pauses for approval, we approve through
    //    the real DesktopAgentTasks.decide API, the tool writes the file, and the run completes.
    func testAgentToolLoopWritesWorkspaceFileAfterApproval() async throws {
        let environment = try makeEnvironment(toolsEnabled: true)
        let workspace = makeWorkspace(environment)
        XCTAssertTrue(workspace.agentTasks.toolsEnabled)
        let expected = "amber-live-e2e-ok"
        await send("请调用 workspace_file_write 工具（如果它尚未暴露，先用 tool_search 搜索 workspace_file_write），"
            + "在当前会话工作区创建文件 hello.txt，内容严格为：\(expected)（不要换行，不要其它字符）。写完后用一句话告诉我完成了。",
            in: workspace)
        let owner = try XCTUnwrap(workspace.selectedID)
        var approvals: [DesktopToolApproval] = []
        let deadline = ContinuousClock.now + .seconds(180)
        while workspace.isGenerating, ContinuousClock.now < deadline {
            if let record = workspace.agentTasks.records.first(where: { $0.conversationID == owner && $0.approval != nil }),
               let approval = record.approval, !approvals.contains(where: { $0.id == approval.id }) {
                approvals.append(approval)
                workspace.agentTasks.decide(runID: record.id, allow: true)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(workspace.isGenerating, "agent run timed out: \(failureContext(workspace))")
        let flushed = await workspace.flush()
        XCTAssertTrue(flushed)
        let messages = try XCTUnwrap(workspace.selectedConversation?.messages)
        let toolNames = approvals.map(\.name)
        print("LiveGatewayE2E agent approvals=\(toolNames) messages=\(messages.map { "\($0.role):\($0.state):\($0.text.prefix(80))" })")
        guard toolNames.contains("workspace_file_write") else {
            XCTFail("Model never requested workspace_file_write (approvals: \(toolNames)). \(failureContext(workspace))")
            return
        }
        let data = try await workspace.files.read(conversationID: owner, path: "hello.txt")
        XCTAssertEqual(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines), expected)
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.state, .complete, failureContext(workspace))
        XCTAssertFalse(messages.last?.text.isEmpty ?? true)
        let record = try XCTUnwrap(workspace.agentTasks.records.first { $0.conversationID == owner })
        XCTAssertEqual(record.status, .completed, record.error ?? "")
    }

    func testSubagentSwitchLetsModelDispatchSubagentWithToolsOff() async throws {
        let environment = try makeEnvironment(toolsEnabled: false)
        environment.defaults.set(true, forKey: "desktop.agent-subagents-enabled")
        let workspace = makeWorkspace(environment)
        XCTAssertFalse(workspace.agentTasks.toolsEnabled)
        XCTAssertTrue(workspace.agentTasks.subagentsEnabled)
        await send("请调用 subagent_dispatch 工具（如果它尚未暴露，先用 tool_search 搜索 subagent_dispatch），"
            + "role 用 oracle，task 为：用一句话评价「把 MCP 子进程改为直接 spawn」的风险。拿到结果后用一句话总结给我。", in: workspace)
        let owner = try XCTUnwrap(workspace.selectedID)
        let deadline = ContinuousClock.now + .seconds(240)
        while workspace.isGenerating, ContinuousClock.now < deadline {
            if let record = workspace.agentTasks.records.first(where: { $0.conversationID == owner && $0.approval != nil }) {
                workspace.agentTasks.decide(runID: record.id, allow: true)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(workspace.isGenerating, "sub-agent run timed out: \(failureContext(workspace))")
        _ = await workspace.flush()
        let dispatched = workspace.collaborations.runs.contains { $0.parentConversationID == owner && !$0.isCouncil }
        print("LiveGatewayE2E subagent runs=\(workspace.collaborations.runs.map { "\($0.status):\($0.outputs.map(\.name))" })")
        XCTAssertTrue(dispatched, "model never dispatched a sub-agent. \(failureContext(workspace))")
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.state, .complete, failureContext(workspace))
    }


    func testHighRiskAutoApprovalRunsShellWithoutPrompt() async throws {
        let environment = try makeEnvironment(toolsEnabled: true)
        environment.defaults.set(true, forKey: "desktop.agent-auto-approve")
        environment.defaults.set(true, forKey: "desktop.agent-auto-approve-high-risk")
        let workspace = makeWorkspace(environment)
        await send("请调用 terminal_exec 工具（如果尚未暴露，先用 tool_search 搜索 terminal_exec）执行命令：echo amber-auto-ok"
            + "，然后把命令输出原样告诉我。", in: workspace)
        let owner = try XCTUnwrap(workspace.selectedID)
        var prompted = false
        let deadline = ContinuousClock.now + .seconds(180)
        while workspace.isGenerating, ContinuousClock.now < deadline {
            if workspace.agentTasks.records.contains(where: { $0.conversationID == owner && $0.approval != nil }) { prompted = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(prompted, "auto-approval still asked")
        while workspace.isGenerating, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        _ = await workspace.flush()
        let record = try XCTUnwrap(workspace.agentTasks.records.first { $0.conversationID == owner })
        XCTAssertTrue(record.transactions.contains { $0.name == "terminal_exec" && $0.state == "finished" }, failureContext(workspace))
        XCTAssertTrue(workspace.selectedConversation?.messages.last?.text.contains("amber-auto-ok") == true, failureContext(workspace))
    }


    /// Every tool the model can see, called once through the production executor (auto-approved), real network/process.
    func testEveryExposedToolActuallyRuns() async throws {
        let environment = try makeEnvironment(toolsEnabled: true)
        environment.defaults.set(true, forKey: "desktop.agent-auto-approve")
        environment.defaults.set(true, forKey: "desktop.agent-auto-approve-high-risk")
        let workspace = makeWorkspace(environment)
        await workspace.waitUntilLoaded()
        await workspace.agentTasks.waitUntilLoaded()
        workspace.createConversation()
        let owner = try XCTUnwrap(workspace.selectedID)
        let provider = try XCTUnwrap(lastAgentProvider)
        let runID = try await workspace.agentTasks.begin(conversationID: owner, title: "tool audit", cancel: {})
        let calls: [(String, String, String)] = [
            ("tools_list", "{}", "workspace_file_write"),
            ("workspace_file_write", #"{"path":"audit.txt","content":"audit-ok"}"#, "audit.txt"),
            ("workspace_file_list", "{}", "audit.txt"),
            ("workspace_file_read", #"{"path":"audit.txt"}"#, "audit-ok"),
            ("terminal_exec", #"{"command":"echo shell-ok && cat audit.txt"}"#, "shell-ok"),
            ("search_web", #"{"query":"Swift programming language"}"#, "swift"),
            ("scrape_web", #"{"url":"https://example.com"}"#, "Example Domain"),
            ("memory_tool", #"{"action":"create","content":"审计记忆：Amber 工具链"}"#, "审计记忆"),
            ("memory_tool", #"{"action":"search","query":"审计记忆"}"#, "审计记忆"),
            ("skills_list", "{}", "["),
            ("mcp_list", "{}", "["),
            ("workspace_artifact_delete", #"{"path":"audit.txt"}"#, "audit.txt"),
        ]
        var failures: [String] = []
        for (name, args, expect) in calls {
            do {
                let output = try await provider.performRecipeTool(runID: runID, owner: owner, name: name, argumentsJSON: args)
                if !output.lowercased().contains(expect.lowercased()) { failures.append("\(name): unexpected output \(output.prefix(240))") }
                print("ToolAudit \(name) OK \(output.prefix(120))")
            } catch { failures.append("\(name): \(error.localizedDescription)") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

}
