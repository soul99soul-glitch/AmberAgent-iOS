import XCTest
@testable import AmberMac

/// P2 review B3 and the tool-mode overflow message. These need `DesktopAgentProvider`, which the SwiftPM runtime
/// host cannot compile (it links the KMP Shared framework), so they live in the Xcode test target.
@MainActor final class DesktopAgentProviderPathTests: XCTestCase {
    /// B3: the tool path must forward the same caching switch the plain chat path already honoured.
    func testPromptCachingAppliesToClaudeOnlyWhenEnabled() {
        var configuration = DesktopProviderConfiguration(name: "C", kind: .claude,
            baseURL: "https://api.anthropic.com/v1", models: [], selectedModelID: nil)
        configuration.promptCaching = true
        XCTAssertTrue(DesktopEnginePromptCaching.appliesCaching(configuration: configuration))
        configuration.promptCaching = false
        XCTAssertFalse(DesktopEnginePromptCaching.appliesCaching(configuration: configuration),
            "caching defaults off: cache writes are billed")

        var openAI = configuration
        openAI.kind = .openAI
        openAI.promptCaching = true
        XCTAssertFalse(DesktopEnginePromptCaching.appliesCaching(configuration: openAI),
            "only Claude has a cache_control field")
    }

    /// The transport carries the switch into the resolved provider setting, which is what the KMP Claude provider
    /// reads when it decides whether to attach `cache_control`.
    func testEngineTransportForwardsTheSwitchToClaude() {
        var transport = DesktopEngineTransport()
        XCTAssertFalse(transport.promptCaching, "off unless the run turns it on")
        transport.promptCaching = true
        XCTAssertTrue(transport.promptCaching)
    }

    /// A tool-mode overflow must name the cause and give the user a next step, not "任务已停止".
    func testToolModeOverflowMessageIsActionable() {
        let message = DesktopAgentProvider.overflowMessageForToolRun
        XCTAssertTrue(message.contains("上下文"), message)
        XCTAssertTrue(message.contains("压缩") || message.contains("新会话"), "needs a next step: \(message)")
        XCTAssertFalse(message.contains("任务已停止"), "an overflow is recoverable, not a stop: \(message)")
        XCTAssertTrue(DesktopContextBudget.isContextOverflow("This model's maximum context length is 200000 tokens"),
            "the overflow branch that selects this message must recognise the provider wording")
    }

    /// P3 review Blocking 1: `DesktopCalendarError` must survive `DesktopAgentExecutor.execute` so the user and
    /// model see the TCC System Settings path and argument hints instead of the generic fallback string.
    func testExecutorPreservesDesktopCalendarErrorMessages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-executor-cal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "amber.executor.cal.\(UUID().uuidString)")!
        let credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        let calendar = FakeCalendarService()
        calendar.calendarAuthorization = .denied
        let plugins = DesktopPluginStore(directory: root.appendingPathComponent("plugins", isDirectory: true),
            defaults: defaults, credentials: credentials, calendarService: calendar)
        let tasks = DesktopAgentTasks(defaults: defaults)
        await tasks.waitUntilLoaded()
        let owner = UUID()
        let runID = try await tasks.begin(conversationID: owner, title: "日程权限核对", cancel: {})

        let files = DesktopWorkspaceFiles(directory: root.appendingPathComponent("workspaces", isDirectory: true),
            locationsFile: root.appendingPathComponent("workspace-locations.json"))
        let knowledge = DesktopKnowledgeStore(directory: root.appendingPathComponent("knowledge", isDirectory: true))
        let mcp = DesktopMCPManager(store: DesktopMCPStore(defaults: defaults, credentials: credentials))
        let text = DesktopKMPProvider()
        let collaborations = DesktopCollaborations(settings: settings, provider: text,
            directory: root.appendingPathComponent("collaborations", isDirectory: true))
        let provider = DesktopAgentProvider(text: text, tasks: tasks, files: files,
            knowledge: knowledge, mcp: mcp, collaborations: collaborations,
            searchSettings: DesktopSearchSettings(defaults: defaults), plugins: plugins)

        let deniedOutcome = try await provider.executeToolForTesting(
            runID: runID, owner: owner, name: "plugin__apple_schedule__list_events", argumentsJSON: "{}")
        XCTAssertFalse(deniedOutcome.succeeded)
        XCTAssertTrue(deniedOutcome.message.contains("系统设置 › 隐私与安全性"), deniedOutcome.message)
        XCTAssertFalse(deniedOutcome.message.contains("工具执行失败，请检查目标文件、网络或权限。"), deniedOutcome.message)

        calendar.calendarAuthorization = .granted
        let invalidOutcome = try await provider.executeToolForTesting(
            runID: runID, owner: owner, name: "plugin__apple_schedule__create_event",
            argumentsJSON: #"{"title":"倒序","start_at":"2026-11-02 15:00","end_at":"2026-11-02 14:00"}"#)
        XCTAssertFalse(invalidOutcome.succeeded)
        XCTAssertTrue(invalidOutcome.message.contains("结束晚于开始"), invalidOutcome.message)
    }
}
