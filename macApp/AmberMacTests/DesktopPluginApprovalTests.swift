import XCTest
@preconcurrency import GatewayCore
@preconcurrency import GatewayTransport
@testable import AmberMac

/// Plugin tools that write to an external system must behave like every other high-risk action:
/// the ordinary auto-approval switch cannot run them, and a phone can only deny them.
@MainActor final class DesktopPluginApprovalTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-plugin-approval-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        DesktopToolRegistry.updatePluginEffects([:])
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Enabling the built-in Feishu plugin is what registers the real tool effects.
    private func pluginStore() -> DesktopPluginStore {
        DesktopPluginStore(directory: directory,
            defaults: UserDefaults(suiteName: "amber.plugin.approval.\(UUID().uuidString)")!,
            credentials: DesktopMemoryCredentials())
    }

    func testPluginExternalWritesAreHighRiskAndNetworkReadsAreNot() throws {
        // Even before DesktopPluginStore populates registeredPluginEffects, the static fallback must classify
        // built-in read tools accurately so they never trigger false high-risk approval prompts.
        DesktopToolRegistry.updatePluginEffects([:])
        for netRead in [
            "plugin__feishu_calendar__list_events",
            "plugin__feishu_calendar__freebusy",
            "plugin__feishu_calendar__bot_fetch_chat_history",
            "plugin__feishu_calendar__bot_read_doc"
        ] {
            XCTAssertEqual(DesktopToolRegistry.effect(for: netRead, arguments: "{}"), .networkRead, netRead)
            XCTAssertFalse(DesktopToolRegistry.isHighRisk(netRead), netRead)
        }
        for pureRead in [
            "plugin__apple_schedule__list_events",
            "plugin__apple_schedule__list_reminders",
            "plugin__watchtower__snapshot",
            "plugin__watchtower__status"
        ] {
            XCTAssertEqual(DesktopToolRegistry.effect(for: pureRead, arguments: "{}"), .pure, pureRead)
            XCTAssertFalse(DesktopToolRegistry.isHighRisk(pureRead), pureRead)
        }

        _ = pluginStore()
        XCTAssertTrue(DesktopToolRegistry.isHighRisk("plugin__feishu_calendar__create_event"))
        XCTAssertTrue(DesktopToolRegistry.isHighRisk("plugin__feishu_calendar__bot_send_message"))
        XCTAssertFalse(DesktopToolRegistry.isHighRisk("plugin__feishu_calendar__list_events"))
        XCTAssertFalse(DesktopToolRegistry.isHighRisk("plugin__feishu_calendar__freebusy"))
        // An unknown plugin tool has no declared effect: treat it as an external write, never as a safe read.
        XCTAssertTrue(DesktopToolRegistry.isHighRisk("plugin__unknown__whatever"))
    }

    func testOrdinaryAutoApprovalDoesNotCoverPluginExternalWrites() throws {
        _ = pluginStore()
        let ordinaryOnly = DesktopApprovalPolicy(autoApproveOrdinary: true, autoApproveHighRisk: false)
        XCTAssertFalse(ordinaryOnly.autoApproves("plugin__feishu_calendar__create_event"),
            "calendar writes reach an external system, so they stay behind 高风险自动批准")
        XCTAssertTrue(ordinaryOnly.autoApproves("plugin__feishu_calendar__list_events"))
        let everything = DesktopApprovalPolicy(autoApproveOrdinary: true, autoApproveHighRisk: true)
        XCTAssertTrue(everything.autoApproves("plugin__feishu_calendar__create_event"))
    }

    func testNotificationApproveIsRefusedForPluginExternalWrites() async throws {
        _ = pluginStore()
        let tasks = DesktopAgentTasks(defaults: UserDefaults(suiteName: "amber.plugin.notify.\(UUID().uuidString)")!)
        await tasks.waitUntilLoaded()
        let owner = UUID()
        tasks.unattendedConversations[owner] = "飞书会前准备"

        let write = try await tasks.begin(conversationID: owner, title: "x", cancel: {})
        try await tasks.requestApproval(runID: write, approval: DesktopToolApproval(id: "call-write",
            name: "plugin__feishu_calendar__create_event", arguments: "{}", reason: "创建日程"))
        let refused = await tasks.decideFromNotification(runID: write, toolID: "call-write", allow: true)
        XCTAssertFalse(refused, "只有 Mac 上核对后能批准外部写入")
        XCTAssertEqual(tasks.records.first { $0.id == write }?.status, .waiting)
        XCTAssertNil(tasks.decision(runID: write, toolID: "call-write"))

        let read = try await tasks.begin(conversationID: owner, title: "y", cancel: {})
        try await tasks.requestApproval(runID: read, approval: DesktopToolApproval(id: "call-read",
            name: "plugin__feishu_calendar__list_events", arguments: "{}", reason: "读取日程"))
        let decision = Task { await tasks.awaitDecision(runID: read, toolID: "call-read") }
        let allowed = await tasks.decideFromNotification(runID: read, toolID: "call-read", allow: true)
        XCTAssertTrue(allowed, "只读查询仍可在手机上批准")
        _ = await decision.value
    }

    func testPhoneApprovalIsRefusedForPluginExternalWrites() async throws {
        _ = pluginStore()
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("agc-plugin-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let paths = GatewayPaths(stateDir: dir)
        let tasks = DesktopAgentTasks(defaults: UserDefaults(suiteName: "amber.plugin.control.\(UUID().uuidString)")!)
        await tasks.waitUntilLoaded()
        let reporter = DesktopGatewayReporter(paths: paths, isEnabled: { true }, process: nil)
        let control = DesktopGatewayControl(paths: paths, tasks: tasks, reporter: reporter, scheduler: nil)
        let conversation = UUID()
        tasks.unattendedConversations[conversation] = "飞书会前准备"
        reporter.runStarted(runID: UUID(), conversationID: conversation, taskName: "飞书会前准备")

        var key: String?
        let deadline = Date().addingTimeInterval(2)
        while key == nil, Date() < deadline {
            Spool(dir: paths.spoolDir).drain { if $0.kind == .runStart { key = "amber:" + $0.sessionId } }
            if key == nil { try? await Task.sleep(for: .milliseconds(20)) }
        }
        let sessionKey = try XCTUnwrap(key)

        let write = try await tasks.begin(conversationID: conversation, title: "x", cancel: {})
        try await tasks.requestApproval(runID: write, approval: DesktopToolApproval(id: "call-write",
            name: "plugin__feishu_calendar__create_event", arguments: "{}", reason: "创建日程"))
        let refused = await control.handle(.init(action: .decide, sessionKey: sessionKey, toolCallId: "call-write", allow: true))
        XCTAssertEqual(refused.status, 403)
        XCTAssertEqual(tasks.records.first { $0.id == write }?.status, .waiting)

        let denied = await control.handle(.init(action: .decide, sessionKey: sessionKey, toolCallId: "call-write", allow: false))
        XCTAssertEqual(denied.status, 200, "拒绝始终允许")

        let read = try await tasks.begin(conversationID: conversation, title: "y", cancel: {})
        try await tasks.requestApproval(runID: read, approval: DesktopToolApproval(id: "call-read",
            name: "plugin__feishu_calendar__list_events", arguments: "{}", reason: "读取日程"))
        let decision = Task { await tasks.awaitDecision(runID: read, toolID: "call-read") }
        let approved = await control.handle(.init(action: .decide, sessionKey: sessionKey, toolCallId: "call-read", allow: true))
        XCTAssertEqual(approved.status, 200)
        _ = await decision.value
    }
}
