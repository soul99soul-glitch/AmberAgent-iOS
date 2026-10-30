import XCTest
@testable import AmberMac

private final class MockPluginHTTPTransport: DesktopPluginHTTPTransport, @unchecked Sendable {
    struct RecordedRequest: Sendable {
        let url: String
        let method: String
        let authorization: String?
        let body: String
    }

    private let lock = NSLock()
    private(set) var requests: [RecordedRequest] = []
    var handler: @Sendable (URLRequest) throws -> (Data, Int) = { _ in (Data("{}".utf8), 200) }

    func send(request: URLRequest) async throws -> (Data, Int) {
        let record = RecordedRequest(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "GET",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        )
        lock.withLock { requests.append(record) }
        return try handler(request)
    }
}

private struct NoopPluginTestProvider: DesktopTextProvider {
    func start(
        configuration: DesktopProviderConfiguration,
        apiKey: String,
        messages: [DesktopMessage],
        responseID: UUID
    ) throws -> DesktopGeneration {
        let gen = DesktopGeneration()
        gen.yield(.complete)
        return gen
    }
}

@MainActor
final class DesktopPluginTests: XCTestCase {
    private var tempDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var credentials: DesktopMemoryCredentials!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-plugin-tests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "amber.test.plugins.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        credentials = DesktopMemoryCredentials()
    }

    override func tearDown() async throws {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
    }

    private func fixedDate() -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        components.year = 2026
        components.month = 10
        components.day = 30
        components.hour = 9
        components.minute = 30
        return components.date!
    }

    func testBuiltInFeishuCalendarPluginSeedsEventsAndBuildsProjections() async throws {
        let now = fixedDate()
        let store = DesktopPluginStore(
            directory: tempDirectory,
            defaults: defaults,
            credentials: credentials,
            referenceDateProvider: { now }
        )

        XCTAssertEqual(store.plugins.map(\.id), ["feishu_calendar"])
        XCTAssertEqual(store.plugins.first?.manifest.name, "飞书")
        XCTAssertEqual(store.calendarEvents.count, 3)
        XCTAssertEqual(store.botActivities.count, 2)
        XCTAssertEqual(store.activeWorkspaceViews.count, 2)
        XCTAssertEqual(store.activeWorkspaceViews.map(\.title), ["飞书日历", "飞书机器人"])
        XCTAssertEqual(store.activeWorkspaceViews.first?.badgeCount, 2)
        XCTAssertEqual(
            store.activeSlashCommands.map(\.slash),
            ["/feishu-today", "/feishu-freebusy", "/feishu-meet", "/feishu-notify", "/feishu-chat", "/feishu-doc"]
        )
        XCTAssertEqual(store.inspectorSnapshots.count, 1)
        XCTAssertEqual(store.inspectorSnapshots.first?.title, "今日飞书日程")
        XCTAssertEqual(store.inspectorSnapshots.first?.items.count, 2)

        let listOutput = try await store.executeTool(
            qualifiedName: "plugin__feishu_calendar__list_events",
            argumentsJSON: #"{"date":"2026-10-30"}"#
        )
        let listJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listOutput.utf8)) as? [String: Any])
        XCTAssertEqual(listJSON["ok"] as? Bool, true)
        XCTAssertEqual(listJSON["count"] as? Int, 2)

        let freebusyOutput = try await store.executeTool(
            qualifiedName: "plugin__feishu_calendar__freebusy",
            argumentsJSON: #"{"date":"2026-10-30","duration_minutes":45}"#
        )
        let fbJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(freebusyOutput.utf8)) as? [String: Any])
        XCTAssertEqual(fbJSON["busy_count"] as? Int, 2)
        let freeSlots = try XCTUnwrap(fbJSON["free_slots"] as? [[String: Any]])
        XCTAssertFalse(freeSlots.isEmpty)

        let createOutput = try await store.executeTool(
            qualifiedName: "plugin__feishu_calendar__create_event",
            argumentsJSON: #"{"summary":"与飞书团队联调日历插件","start_time":"2026-10-30 16:00","end_time":"2026-10-30 17:00","location":"飞书视频会议","attendees":["张三","李四"]}"#
        )
        let createJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(createOutput.utf8)) as? [String: Any])
        XCTAssertEqual(createJSON["ok"] as? Bool, true)
        XCTAssertEqual(store.calendarEvents.count, 4)
        XCTAssertEqual(store.activeWorkspaceViews.first?.badgeCount, 3)
        XCTAssertEqual(store.inspectorSnapshots.first?.items.count, 3)

        // Verify Feishu Bot tools in local sandbox mode
        let botMsgOutput = try await store.executeTool(
            qualifiedName: "plugin__feishu_calendar__bot_send_message",
            argumentsJSON: #"{"title":"测试卡片","content":"今日构建通过"}"#
        )
        let botMsgJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(botMsgOutput.utf8)) as? [String: Any])
        XCTAssertEqual(botMsgJSON["ok"] as? Bool, true)
        XCTAssertEqual(store.botActivities.count, 3)
    }

    func testFeishuCalDAVSyncAndBotWebhookAndOpenAPI() async throws {
        let now = fixedDate()
        let transport = MockPluginHTTPTransport()
        transport.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("caldav.feishu.cn") && request.httpMethod == "REPORT" {
                let icsResponse = """
                BEGIN:VCALENDAR
                VERSION:2.0
                BEGIN:VEVENT
                UID:caldav_evt_101
                DTSTART:20261030T110000
                DTEND:20261030T120000
                SUMMARY:CalDAV 个人日历直连评审
                LOCATION:飞书会议室B
                DESCRIPTION:免企业管理员审批同步
                END:VEVENT
                END:VCALENDAR
                """
                return (Data(icsResponse.utf8), 207)
            }
            if url.contains("caldav.feishu.cn") && request.httpMethod == "PUT" {
                return (Data(), 201)
            }
            if url.contains("/open-apis/bot/v2/hook/") && request.httpMethod == "POST" {
                return (Data(#"{"StatusCode":0,"StatusMessage":"success"}"#.utf8), 200)
            }
            return (Data("{}".utf8), 404)
        }

        let store = DesktopPluginStore(
            directory: tempDirectory,
            defaults: defaults,
            credentials: credentials,
            httpTransport: transport,
            referenceDateProvider: { now }
        )

        try store.saveSettings(pluginID: "feishu_calendar", values: [
            "caldav_server": "https://caldav.feishu.cn",
            "caldav_username": "u_feishu_user",
            "caldav_password": "caldav_secret_password",
            "bot_webhook_url": "https://open.feishu.cn/open-apis/bot/v2/hook/test_hook_123",
            "bot_webhook_secret": "webhook_sign_key_abc"
        ])

        XCTAssertTrue(store.hasFeishuCalDAVCredentials)
        XCTAssertTrue(store.hasFeishuBotCredentials)
        XCTAssertEqual(store.feishuCalendarConnectionBadge, "CalDAV 直连")

        let syncStatus = try await store.syncFeishuCalendar()
        XCTAssertTrue(syncStatus.contains("CalDAV"))
        XCTAssertTrue(store.calendarEvents.contains { $0.id == "caldav_evt_101" && $0.summary == "CalDAV 个人日历直连评审" })
        XCTAssertEqual(transport.requests.first?.method, "REPORT")
        XCTAssertTrue(transport.requests.first?.authorization?.hasPrefix("Basic ") == true)

        let createdCalDAV = try await store.createCalendarEvent(
            summary: "CalDAV 写入日程",
            startTime: "2026-10-30 16:00",
            endTime: "2026-10-30 16:30"
        )
        XCTAssertEqual(createdCalDAV.source, "feishu")
        XCTAssertTrue(transport.requests.contains { $0.method == "PUT" && $0.body.contains("BEGIN:VEVENT") })

        let botSent = try await store.sendFeishuBotMessage(
            title: "版本发布通知",
            content: "v2.0 已通过全部测试"
        )
        XCTAssertEqual(botSent.channel, "webhook")
        let webhookReq = try XCTUnwrap(transport.requests.last)
        XCTAssertTrue(webhookReq.url.contains("/open-apis/bot/v2/hook/test_hook_123"))
        XCTAssertTrue(webhookReq.body.contains("\"sign\""))
    }

    func testFeishuRemoteSyncUsesKeychainCredentialsAndEnforcesDomainAllowlist() async throws {
        let now = fixedDate()
        let transport = MockPluginHTTPTransport()
        transport.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("tenant_access_token") {
                return (Data(#"{"code":0,"tenant_access_token":"t-feishu-token-999"}"#.utf8), 200)
            }
            if url.contains("/calendars/team_cal/events") && request.httpMethod == "GET" {
                let payload = """
                {"code":0,"data":{"items":[{"event_id":"feishu_remote_1","summary":"飞书云端架构同步会","description":"云端拉取","start_time":{"timestamp":"1793334000"},"end_time":{"timestamp":"1793337600"},"location":{"name":"飞书总部A座"}}]}}
                """
                return (Data(payload.utf8), 200)
            }
            if url.contains("/calendars/team_cal/events") && request.httpMethod == "POST" {
                return (Data(#"{"code":0,"data":{"event":{"event_id":"feishu_created_1"}}}"#.utf8), 200)
            }
            return (Data("{}".utf8), 404)
        }

        let store = DesktopPluginStore(
            directory: tempDirectory,
            defaults: defaults,
            credentials: credentials,
            httpTransport: transport,
            referenceDateProvider: { now }
        )

        try store.saveSettings(pluginID: "feishu_calendar", values: [
            "app_id": "cli_amber_001",
            "app_secret": "sec_top_secret_value",
            "default_calendar_id": "team_cal"
        ])

        // Secret must be in Keychain store, never in UserDefaults dictionary
        let rawDefaults = defaults.dictionary(forKey: "desktop.plugins.settings.v1.feishu_calendar") as? [String: String]
        XCTAssertEqual(rawDefaults?["app_id"], "cli_amber_001")
        XCTAssertNil(rawDefaults?["app_secret"])
        XCTAssertEqual(store.settingValue(pluginID: "feishu_calendar", key: "app_secret"), "sec_top_secret_value")

        let status = try await store.syncFeishuCalendar()
        XCTAssertTrue(status.contains("已同步飞书日历"))
        XCTAssertTrue(store.calendarEvents.contains { $0.id == "feishu_remote_1" && $0.summary == "飞书云端架构同步会" })
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.last?.authorization, "Bearer t-feishu-token-999")

        // Creating an event while remote credentials are active also dispatches POST to Feishu
        let created = try await store.createCalendarEvent(
            summary: "飞书立项会",
            startTime: "2026-10-30 17:00",
            endTime: "2026-10-30 17:30"
        )
        XCTAssertEqual(created.source, "feishu")

        // Unauthorized domain must be blocked by Capability Broker
        let feishuPlugin = try XCTUnwrap(store.plugins.first { $0.id == "feishu_calendar" })
        do {
            _ = try await store.performAuthorizedHTTP(plugin: feishuPlugin, urlString: "https://evil.example.com/exfiltrate")
            XCTFail("Expected domain allowlist rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未授权访问域名"))
        }
    }

    func testCorePluginsAndExtensionToolsFilterAgentDeclarationsAndEffects() throws {
        let store = DesktopPluginStore(
            directory: tempDirectory,
            defaults: defaults,
            credentials: credentials
        )

        let full = DesktopToolRegistry.agentDeclarations(
            toolsEnabled: true,
            subagentsEnabled: true,
            scheduling: true,
            pluginDeclarations: store.activeToolDeclarations,
            disabledCorePlugins: store.disabledCorePlugins
        )
        XCTAssertTrue(full.contains { $0.name == "plugin__feishu_calendar__list_events" && !$0.needsApproval })
        XCTAssertTrue(full.contains { $0.name == "plugin__feishu_calendar__create_event" && $0.needsApproval })
        XCTAssertTrue(full.contains { $0.name == "memory_tool" })
        XCTAssertTrue(full.contains { $0.name == "schedule_create" })

        store.setCoreEnabled(.knowledge, enabled: false)
        store.setCoreEnabled(.taskBoard, enabled: false)
        try store.setPluginEnabled("feishu_calendar", enabled: false)

        let filtered = DesktopToolRegistry.agentDeclarations(
            toolsEnabled: true,
            subagentsEnabled: true,
            scheduling: true,
            pluginDeclarations: store.activeToolDeclarations,
            disabledCorePlugins: store.disabledCorePlugins
        )
        XCTAssertFalse(filtered.contains { $0.name == "memory_tool" })
        XCTAssertFalse(filtered.contains { $0.name == "schedule_create" })
        XCTAssertFalse(filtered.contains { $0.name.hasPrefix("plugin__feishu_calendar__") })
        XCTAssertEqual(store.disabledCorePlugin(governing: "memory_tool"), .knowledge)
        XCTAssertEqual(store.disabledCorePlugin(governing: "schedule_create"), .taskBoard)
        XCTAssertFalse(store.activeRecipeRegisteredTools().contains("memory_tool"))
        XCTAssertTrue(store.inspectorSnapshots.isEmpty)
        XCTAssertTrue(store.activeWorkspaceViews.isEmpty)
    }

    func testCustomPluginImportExecutionAndRemoval() async throws {
        let pluginsRoot = tempDirectory.appendingPathComponent("installed", isDirectory: true)
        let store = DesktopPluginStore(
            directory: pluginsRoot,
            defaults: defaults,
            credentials: credentials
        )

        let pkgDir = tempDirectory.appendingPathComponent("staging_note_helper", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        let manifestJSON = """
        {
          "schema": "amber.plugin.v2",
          "id": "note_helper",
          "name": "会议纪要助手",
          "version": "1.0.0",
          "description": "统计纪要字数并附带前缀配置。",
          "settings_schema": [
            { "key": "prefix", "title": "纪要前缀", "kind": "string", "defaultValue": "【飞书纪要】" }
          ],
          "tools": [
            {
              "name": "format_note",
              "description": "格式化会议纪要",
              "effect": "pure",
              "entry": "formatNote",
              "input_schema": {
                "type": "object",
                "properties": { "text": { "type": "string" } },
                "required": ["text"],
                "additionalProperties": false
              }
            }
          ]
        }
        """
        let scriptJS = """
        function formatNote(input) {
            const p = amber.settings.get("prefix") || "";
            const count = Number(amber.storage.get("runs") || "0") + 1;
            amber.storage.set("runs", String(count));
            return { formatted: p + String(input.text || ""), run_count: count };
        }
        """
        try Data(manifestJSON.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        try Data(scriptJS.utf8).write(to: pkgDir.appendingPathComponent("main.js"))

        let importedID = try store.importPlugin(from: pkgDir)
        XCTAssertEqual(importedID, "note_helper")
        XCTAssertTrue(store.plugins.contains { $0.id == "note_helper" && $0.enabled })
        XCTAssertEqual(
            DesktopToolRegistry.effect(for: "plugin__note_helper__format_note", arguments: "{}"),
            .pure
        )

        let out1 = try await store.executeTool(
            qualifiedName: "plugin__note_helper__format_note",
            argumentsJSON: #"{"text":"确认明日上线"}"#
        )
        let obj1 = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out1.utf8)) as? [String: Any])
        XCTAssertEqual(obj1["formatted"] as? String, "【飞书纪要】确认明日上线")
        XCTAssertEqual(obj1["run_count"] as? Int, 1)

        let activity = DesktopToolActivity(DesktopToolCall(
            id: "1",
            name: "plugin__feishu_calendar__create_event",
            input: #"{"summary":"产品周会"}"#,
            output: "{}",
            status: .complete
        ))
        XCTAssertEqual(activity.title, "已创建飞书日程")
        XCTAssertEqual(activity.detail, "产品周会")

        try store.removePlugin(id: "note_helper")
        XCTAssertFalse(store.plugins.contains { $0.id == "note_helper" })
    }

    func testWorkspaceSurfaceSwitchingAndAutomaticResetWhenPluginDisabled() async throws {
        let now = fixedDate()
        let store = DesktopPluginStore(
            directory: tempDirectory,
            defaults: defaults,
            credentials: credentials,
            referenceDateProvider: { now }
        )
        let settings = DesktopSettings(
            defaults: UserDefaults(suiteName: "amber.test.settings.\(UUID().uuidString)")!,
            credentials: DesktopMemoryCredentials()
        )
        let conversation = DesktopConversation(title: "测试会话", messages: [])
        let workspace = DesktopWorkspace(
            settings: settings,
            storage: DesktopMemoryConversationStorage([conversation]),
            provider: NoopPluginTestProvider(),
            initialConversations: [conversation],
            plugins: store
        )

        XCTAssertEqual(workspace.activeSurface, DesktopWorkspaceSurface.chat)
        workspace.openPluginView(pluginID: "feishu_calendar", viewID: "calendar_board")
        XCTAssertEqual(
            workspace.activeSurface,
            DesktopWorkspaceSurface.pluginView(pluginID: "feishu_calendar", viewID: "calendar_board")
        )

        // Disabling the plugin must automatically return activeSurface to .chat
        try store.setPluginEnabled("feishu_calendar", enabled: false)
        XCTAssertEqual(workspace.activeSurface, DesktopWorkspaceSurface.chat)

        // Re-enable and verify tool card preview summary
        try store.setPluginEnabled("feishu_calendar", enabled: true)
        let preview = DesktopToolCallCard.pluginPreviewSummary(tool: DesktopToolCall(
            id: "t1",
            name: "plugin__feishu_calendar__create_event",
            input: "{}",
            output: #"{"ok":true,"event":{"summary":"架构评审","start_time":"2026-10-30 16:00","location":"飞书会议"}}"#,
            status: .complete
        ))
        XCTAssertEqual(preview?.text, "架构评审（2026-10-30 16:00 · 飞书会议）")
    }
}
