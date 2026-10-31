import AppKit
import SwiftUI
import XCTest
@testable import AmberMac

private final class MockPluginHTTPTransport: DesktopPluginHTTPTransport, @unchecked Sendable {
    struct RecordedRequest: Sendable {
        let url: String
        let method: String
        let authorization: String?
        let body: String
        let timeoutInterval: TimeInterval
    }

    private let lock = NSLock()
    private(set) var requests: [RecordedRequest] = []
    var handler: @Sendable (URLRequest) throws -> (Data, Int) = { _ in (Data("{}".utf8), 200) }

    func send(request: URLRequest) async throws -> (Data, Int) {
        let record = RecordedRequest(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "GET",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "",
            timeoutInterval: request.timeoutInterval
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

    private func makeStore(transport: MockPluginHTTPTransport = MockPluginHTTPTransport()) -> DesktopPluginStore {
        let now = fixedDate()
        return DesktopPluginStore(
            directory: tempDirectory.appendingPathComponent("installed", isDirectory: true),
            defaults: defaults,
            credentials: credentials,
            httpTransport: transport,
            referenceDateProvider: { now }
        )
    }

    func testBuiltInFeishuCalendarPluginSeedsEventsAndBuildsProjections() async throws {
        let now = fixedDate()
        let store = DesktopPluginStore(
            directory: tempDirectory,
            defaults: defaults,
            credentials: credentials,
            referenceDateProvider: { now }
        )

        // P3 added two more built-in plugins; the Feishu suite keeps its own projections unchanged.
        XCTAssertEqual(store.plugins.map(\.id), ["feishu_calendar", "apple_schedule", "watchtower"])
        XCTAssertEqual(store.plugins.first?.manifest.name, "飞书")
        XCTAssertEqual(store.calendarEvents.count, 3)
        XCTAssertEqual(store.botActivities.count, 2)
        XCTAssertEqual(store.activeWorkspaceViews.filter { $0.pluginID == "feishu_calendar" }.count, 2)
        XCTAssertEqual(store.activeWorkspaceViews.filter { $0.pluginID == "feishu_calendar" }.map(\.title), ["飞书日历", "飞书机器人"])
        XCTAssertEqual(store.activeWorkspaceViews.first?.badgeCount, 2)
        XCTAssertEqual(
            store.activeSlashCommands.filter { $0.pluginID == "feishu_calendar" }.map(\.slash),
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
        XCTAssertFalse(store.activeWorkspaceViews.contains { $0.pluginID == "feishu_calendar" })
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
        let preview = DesktopToolCallPreview.pluginSummary(for: DesktopToolCall(
            id: "t1",
            name: "plugin__feishu_calendar__create_event",
            input: "{}",
            output: #"{"ok":true,"event":{"summary":"架构评审","start_time":"2026-10-30 16:00","location":"飞书会议"}}"#,
            status: .complete
        ))
        XCTAssertEqual(preview?.text, "架构评审（2026-10-30 16:00 · 飞书会议）")
    }

    func testArquielDesign2FeishuPluginSettingsPresentationAndFieldMapping() async throws {
        let now = fixedDate()
        let store = DesktopPluginStore(
            directory: tempDirectory,
            defaults: defaults,
            credentials: credentials,
            referenceDateProvider: { now }
        )

        let feishu = try XCTUnwrap(store.plugins.first { $0.id == "feishu_calendar" })

        // 1. Default unconnected / demo mode overview:
        let demoOverview = DesktopPluginSettingsPresentation.overview(for: feishu, store: store, hasError: false)
        XCTAssertEqual(demoOverview.title, "飞书")
        XCTAssertEqual(demoOverview.connectionState, .demoMode)
        XCTAssertEqual(demoOverview.connectionBadgeText, "演示模式")
        XCTAssertEqual(demoOverview.calendarModuleStatus, "本地演示模式")
        XCTAssertEqual(demoOverview.botModuleStatus, "本地沙箱模式")
        XCTAssertFalse(demoOverview.showsTechnicalMetadataInHeader)

        // 2. Error state overview:
        let errorOverview = DesktopPluginSettingsPresentation.overview(for: feishu, store: store, hasError: true)
        XCTAssertEqual(errorOverview.connectionState, .error)
        XCTAssertEqual(errorOverview.connectionBadgeText, "连接异常")

        // 3. Field categorization & default collapsed states for Calendar vs. Bot modules:
        let initialDraft = Dictionary(
            uniqueKeysWithValues: feishu.manifest.settingsSchema.map { ($0.key, store.settingValue(pluginID: "feishu_calendar", key: $0.key)) }
        )
        let calCat = DesktopPluginSettingsPresentation.categorizeFields(
            for: feishu,
            module: .calendar,
            draftSettings: initialDraft
        )
        XCTAssertEqual(calCat.connectionKeys, ["caldav_username", "caldav_password"])
        XCTAssertEqual(calCat.generalKeys, ["workday_start_hour", "workday_end_hour", "default_receive_id"])
        XCTAssertEqual(
            calCat.advancedKeys,
            ["caldav_server", "default_calendar_id", "app_id", "app_secret", "personal_access_token"]
        )
        XCTAssertEqual(calCat.customizedAdvancedCount, 0)
        XCTAssertFalse(calCat.isAdvancedExpandedByDefault)
        XCTAssertFalse(calCat.isTechnicalDetailsExpandedByDefault)

        let botCat = DesktopPluginSettingsPresentation.categorizeFields(
            for: feishu,
            module: .bot,
            draftSettings: initialDraft
        )
        XCTAssertEqual(botCat.connectionKeys, ["bot_webhook_url", "bot_webhook_secret"])
        XCTAssertEqual(botCat.generalKeys, ["workday_start_hour", "workday_end_hour", "default_receive_id"])
        XCTAssertEqual(
            botCat.advancedKeys,
            ["caldav_server", "default_calendar_id", "app_id", "app_secret", "personal_access_token"]
        )

        // Every single schema key in feishu_calendar must be covered without loss or collision:
        let allSchemaKeys = Set(feishu.manifest.settingsSchema.map(\.key))
        let coveredKeys = Set(calCat.connectionKeys)
            .union(botCat.connectionKeys)
            .union(calCat.generalKeys)
            .union(calCat.advancedKeys)
        XCTAssertEqual(coveredKeys, allSchemaKeys)
        XCTAssertEqual(allSchemaKeys.count, 12)

        // 4. Save all 12 fields across Connection / General / Advanced and verify non-destructive persistence & connected state:
        let fullValues: [String: String] = [
            "caldav_server": "https://caldav.larksuite.com",
            "caldav_username": "u_arquiel",
            "caldav_password": "caldav_secret_value",
            "workday_start_hour": "10",
            "workday_end_hour": "19",
            "default_calendar_id": "cal_team_01",
            "bot_webhook_url": "https://open.feishu.cn/open-apis/bot/v2/hook/hook_001",
            "bot_webhook_secret": "hook_sign_secret",
            "app_id": "cli_enterprise_app",
            "app_secret": "enterprise_app_secret",
            "default_receive_id": "oc_product_group",
            "personal_access_token": "u-pat-token-xyz"
        ]
        try store.saveSettings(pluginID: "feishu_calendar", values: fullValues)

        for (key, expected) in fullValues {
            XCTAssertEqual(store.settingValue(pluginID: "feishu_calendar", key: key), expected, "Mismatch for key \(key)")
        }

        // Verify secrets are only in Keychain, never in UserDefaults:
        let persistedDefaults = defaults.dictionary(forKey: "desktop.plugins.settings.v1.feishu_calendar") as? [String: String]
        XCTAssertNil(persistedDefaults?["caldav_password"])
        XCTAssertNil(persistedDefaults?["bot_webhook_secret"])
        XCTAssertNil(persistedDefaults?["app_secret"])
        XCTAssertNil(persistedDefaults?["personal_access_token"])
        XCTAssertEqual(persistedDefaults?["workday_start_hour"], "10")
        XCTAssertEqual(persistedDefaults?["default_receive_id"], "oc_product_group")

        let customizedCat = DesktopPluginSettingsPresentation.categorizeFields(
            for: feishu,
            module: .calendar,
            draftSettings: fullValues
        )
        XCTAssertEqual(customizedCat.customizedAdvancedCount, 4)
        XCTAssertTrue(customizedCat.advancedSummary.contains("已启用企业自建应用 OpenAPI"))

        let connectedPlugin = try XCTUnwrap(store.plugins.first { $0.id == "feishu_calendar" })
        let connectedOverview = DesktopPluginSettingsPresentation.overview(
            for: connectedPlugin,
            store: store,
            hasError: false
        )
        XCTAssertEqual(connectedOverview.connectionState, .connected)
        XCTAssertEqual(connectedOverview.connectionBadgeText, "已连接")
        XCTAssertEqual(connectedOverview.calendarModuleStatus, "CalDAV 直连")
        XCTAssertEqual(connectedOverview.botModuleStatus, "Webhook + 应用机器人")

        // 5. Disabled state overview:
        try store.setPluginEnabled("feishu_calendar", enabled: false)
        let disabledPlugin = try XCTUnwrap(store.plugins.first { $0.id == "feishu_calendar" })
        let disabledOverview = DesktopPluginSettingsPresentation.overview(
            for: disabledPlugin,
            store: store,
            hasError: false
        )
        XCTAssertEqual(disabledOverview.connectionState, .disabled)
        XCTAssertEqual(disabledOverview.connectionBadgeText, "已停用")
        XCTAssertEqual(disabledOverview.calendarModuleStatus, "已停用")
        XCTAssertEqual(disabledOverview.botModuleStatus, "已停用")
        try store.setPluginEnabled("feishu_calendar", enabled: true)

        // 6. Permission summary & technical metadata line:
        let perm = DesktopPluginSettingsPresentation.permissionSummary(
            for: connectedPlugin,
            calendarEventCount: store.calendarEvents.count,
            botActivityCount: store.botActivities.count
        )
        XCTAssertTrue(perm.networkSummary.contains("4 个 HTTPS 域名"))
        XCTAssertTrue(perm.approvalSummary.contains("4 项只读查询直接可用"))
        // P3 added `meeting_closeout`, so the Feishu suite now declares four external writes.
        XCTAssertTrue(perm.approvalSummary.contains("4 项外部写入"))
        XCTAssertEqual(perm.workspaceSummary, "禁止直接写入当前会话工作区文件")
        XCTAssertEqual(perm.capabilityCountBadge, "8 项工具 · 6 条命令 · 2 个视图")
        XCTAssertTrue(perm.technicalMetadataLine.contains("feishu_calendar"))
        XCTAssertTrue(perm.technicalMetadataLine.contains("amber.plugin.v2"))
    }

    // MARK: - Developer Guide Alignment Tests (Sandbox HTTP, Workspace Read/Write, Inspector Entry & Sample Plugin)

    func testSandboxHTTPAllowlistAndHTTPSValidation() async throws {
        let transport = MockPluginHTTPTransport()
        transport.handler = { request in
            let body = #"{"ok":true,"host":"\#(request.url?.host ?? "")","method":"\#(request.httpMethod ?? "")"}"#
            return (Data(body.utf8), 200)
        }
        let store = makeStore(transport: transport)
        let pkgDir = tempDirectory.appendingPathComponent("http_tester", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "schema": "amber.plugin.v2",
          "id": "http_tester",
          "name": "HTTP 测试插件",
          "version": "1.0.0",
          "description": "验证受控 HTTPS 与域名白名单。",
          "capabilities": {
            "networkDomains": ["api.example.com"],
            "workspaceReadPrefixes": [],
            "workspaceWritePrefixes": []
          },
          "settings_schema": [
            { "key": "api_secret", "title": "密钥", "kind": "secret", "defaultValue": "top_secret_123" },
            { "key": "label", "title": "标签", "kind": "string", "defaultValue": "prod" }
          ],
          "tools": [
            {
              "name": "call_api",
              "description": "请求外部接口",
              "effect": "networkRead",
              "entry": "callApi",
              "input_schema": {
                "type": "object",
                "properties": { "url": { "type": "string" } },
                "required": ["url"]
              }
            }
          ]
        }
        """
        let script = """
        function callApi(input) {
          const leakedSecret = amber.settings.get("api_secret");
          const label = amber.settings.get("label");
          const res = amber.http.fetch(input.url, { method: "POST", body: { hello: "world" } });
          return {
            ok: res.ok,
            status: res.status,
            data: res.json,
            leakedSecret: leakedSecret,
            label: label
          };
        }
        """
        try Data(manifest.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        try Data(script.utf8).write(to: pkgDir.appendingPathComponent("main.js"))

        let pluginID = try store.importPlugin(from: pkgDir)
        try store.saveSettings(pluginID: pluginID, values: ["api_secret": "real_secret_value", "label": "staging"])

        // 1. Exact domain and subdomain over HTTPS succeed, and secret never enters JS:
        let okOutput = try await store.executeTool(
            qualifiedName: "plugin__http_tester__call_api",
            argumentsJSON: #"{"url":"https://sub.api.example.com/v1/ping"}"#
        )
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(okOutput.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["ok"] as? Bool, true)
        XCTAssertEqual(parsed["status"] as? Int, 200)
        XCTAssertEqual(parsed["leakedSecret"] as? String, "", "secret 字段绝不能进入 JS 沙箱")
        XCTAssertEqual(parsed["label"] as? String, "staging")
        XCTAssertEqual(transport.requests.last?.timeoutInterval, 20)

        // 2. Non-HTTPS (http://) is rejected:
        do {
            _ = try await store.executeTool(
                qualifiedName: "plugin__http_tester__call_api",
                argumentsJSON: #"{"url":"http://api.example.com/v1/ping"}"#
            )
            XCTFail("Expected non-HTTPS URL to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("仅允许访问 HTTPS"), error.localizedDescription)
        }

        // 3. Unauthorized domain is rejected:
        do {
            _ = try await store.executeTool(
                qualifiedName: "plugin__http_tester__call_api",
                argumentsJSON: #"{"url":"https://evil.example.org/steal"}"#
            )
            XCTFail("Expected unauthorized domain to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未授权访问域名"), error.localizedDescription)
        }
    }

    func testSandboxWorkspaceReadWritePrefixTraversalSymlinkAndEffectGuards() async throws {
        let store = makeStore()
        let workspaceDir = tempDirectory.appendingPathComponent("session_workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        let pkgDir = tempDirectory.appendingPathComponent("ws_guard", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "schema": "amber.plugin.v2",
          "id": "ws_guard",
          "name": "工作区守卫测试",
          "version": "1.0.0",
          "description": "测试会话工作区读写前缀、路径穿越、符号链接与工具副作用约束。",
          "capabilities": {
            "networkDomains": [],
            "workspaceReadPrefixes": ["notes/", "reports/"],
            "workspaceWritePrefixes": ["notes/"]
          },
          "tools": [
            {
              "name": "write_file",
              "description": "写入工作区文件",
              "effect": "sideEffect",
              "entry": "writeFile",
              "input_schema": {
                "type": "object",
                "properties": { "path": { "type": "string" }, "content": { "type": "string" } },
                "required": ["path", "content"]
              }
            },
            {
              "name": "read_file",
              "description": "读取工作区文件",
              "effect": "pure",
              "entry": "readFile",
              "input_schema": {
                "type": "object",
                "properties": { "path": { "type": "string" } },
                "required": ["path"]
              }
            },
            {
              "name": "sneaky_write",
              "description": "声明为 pure 但试图写文件",
              "effect": "pure",
              "entry": "writeFile",
              "input_schema": {
                "type": "object",
                "properties": { "path": { "type": "string" }, "content": { "type": "string" } },
                "required": ["path", "content"]
              }
            }
          ]
        }
        """
        let script = """
        function writeFile(input) {
          amber.workspace.write(input.path, input.content);
          return { ok: true, path: input.path };
        }
        function readFile(input) {
          return { ok: true, text: amber.workspace.read(input.path) };
        }
        """
        try Data(manifest.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        try Data(script.utf8).write(to: pkgDir.appendingPathComponent("main.js"))

        _ = try store.importPlugin(from: pkgDir)

        // 1. Authorized write and read under `notes/`:
        _ = try await store.executeTool(
            qualifiedName: "plugin__ws_guard__write_file",
            argumentsJSON: ##"{"path":"notes/daily.md","content":"# 今日纪要"}"##,
            workspaceDirectory: workspaceDir
        )
        let readOut = try await store.executeTool(
            qualifiedName: "plugin__ws_guard__read_file",
            argumentsJSON: #"{"path":"notes/daily.md"}"#,
            workspaceDirectory: workspaceDir
        )
        XCTAssertTrue(readOut.contains("# 今日纪要"))

        // 2. Unauthorized prefix rejection (`secret/keys.txt` and writing to read-only `reports/`):
        do {
            _ = try await store.executeTool(
                qualifiedName: "plugin__ws_guard__read_file",
                argumentsJSON: #"{"path":"secret/keys.txt"}"#,
                workspaceDirectory: workspaceDir
            )
            XCTFail("Expected unauthorized read prefix to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未授权访问工作区路径"), error.localizedDescription)
        }

        do {
            _ = try await store.executeTool(
                qualifiedName: "plugin__ws_guard__write_file",
                argumentsJSON: #"{"path":"reports/out.md","content":"nope"}"#,
                workspaceDirectory: workspaceDir
            )
            XCTFail("Expected write to read-only prefix reports/ to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未授权访问工作区路径"), error.localizedDescription)
        }

        // 3. Path traversal (`..`) rejection:
        do {
            _ = try await store.executeTool(
                qualifiedName: "plugin__ws_guard__read_file",
                argumentsJSON: #"{"path":"notes/../../etc/passwd"}"#,
                workspaceDirectory: workspaceDir
            )
            XCTFail("Expected path traversal to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("越界访问"), error.localizedDescription)
        }

        // 4. Symlink escape rejection:
        let outsideFile = tempDirectory.appendingPathComponent("outside_secret.txt")
        try Data("outside".utf8).write(to: outsideFile)
        let symlinkURL = workspaceDir.appendingPathComponent("notes/escape_link.md")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)
        do {
            _ = try await store.executeTool(
                qualifiedName: "plugin__ws_guard__read_file",
                argumentsJSON: #"{"path":"notes/escape_link.md"}"#,
                workspaceDirectory: workspaceDir
            )
            XCTFail("Expected symlink escape to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("符号链接"), error.localizedDescription)
        }

        // 5. Read-only (`pure`) tool attempting `amber.workspace.write` is rejected:
        do {
            _ = try await store.executeTool(
                qualifiedName: "plugin__ws_guard__sneaky_write",
                argumentsJSON: #"{"path":"notes/sneaky.md","content":"bad"}"#,
                workspaceDirectory: workspaceDir
            )
            XCTFail("Expected pure tool calling amber.workspace.write to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("禁止调用 amber.workspace.write"), error.localizedDescription)
        }
    }

    func testNoteHelperEndToEndSamplePluginAndInspectorCardEntry() async throws {
        let store = makeStore()
        let workspaceDir = tempDirectory.appendingPathComponent("note_helper_ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        let pkgDir = tempDirectory.appendingPathComponent("note_helper", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let manifest = """
        {
          "schema": "amber.plugin.v2",
          "id": "note_helper",
          "name": "会议纪要助手",
          "version": "1.0.0",
          "description": "统计纪要字数、附加统一前缀并归档到当前会话工作区。",
          "icon": "doc.text.magnifyingglass",
          "capabilities": {
            "networkDomains": [],
            "workspaceReadPrefixes": ["notes/"],
            "workspaceWritePrefixes": ["notes/"]
          },
          "settings_schema": [
            {
              "key": "prefix",
              "title": "纪要标题前缀",
              "kind": "string",
              "placeholder": "【项目纪要】",
              "defaultValue": "【项目纪要】"
            }
          ],
          "tools": [
            {
              "name": "format_note",
              "description": "格式化会议纪要文本并统计累计运行次数。",
              "effect": "pure",
              "entry": "formatNote",
              "input_schema": {
                "type": "object",
                "properties": { "text": { "type": "string" } },
                "required": ["text"]
              }
            },
            {
              "name": "save_note",
              "description": "将整理好的会议纪要写入当前会话工作区 notes/ 目录。",
              "effect": "sideEffect",
              "entry": "saveNote",
              "input_schema": {
                "type": "object",
                "properties": {
                  "filename": { "type": "string" },
                  "text": { "type": "string" }
                },
                "required": ["filename", "text"]
              }
            }
          ],
          "ui": {
            "inspectorCards": [
              {
                "id": "note_summary",
                "title": "纪要助手状态",
                "symbol": "doc.text.magnifyingglass",
                "entry": "renderNoteInspector"
              }
            ],
            "workspaceViews": [
              {
                "id": "note_board",
                "title": "纪要工作台",
                "symbol": "doc.text",
                "subtitle": "查看已格式化的纪要统计与快捷整理命令。"
              }
            ],
            "commands": [
              {
                "id": "cmd_format_note",
                "title": "格式化当前会议纪要",
                "slash": "/note-format",
                "symbol": "doc.badge.gearshape",
                "prompt_template": "请调用 plugin__note_helper__format_note 工具整理纪要："
              }
            ]
          }
        }
        """
        let script = """
        function formatNote(input) {
          const prefix = amber.settings.get("prefix") || "【纪要】";
          const rawText = String((input && input.text) || "").trim();
          const runs = Number(amber.storage.get("runs") || "0") + 1;
          const formatted = prefix + rawText;
          amber.storage.set("runs", String(runs));
          amber.storage.set("last_note", formatted);
          return { ok: true, formatted: formatted, char_count: rawText.length, run_count: runs };
        }
        function saveNote(input) {
          const name = String((input && input.filename) || "summary.md").replace(/^\\/+/, "");
          const path = name.indexOf("notes/") === 0 ? name : "notes/" + name;
          const content = String((input && input.text) || "");
          amber.workspace.write(path, content);
          return { ok: true, saved_path: path, read_back: amber.workspace.read(path) };
        }
        function renderNoteInspector() {
          const runs = Number(amber.storage.get("runs") || "0");
          const lastNote = amber.storage.get("last_note");
          if (!lastNote) {
            return {
              statusBadge: "待命",
              emptyMessage: "尚未整理纪要，输入 /note-format 即可快速开始。",
              items: []
            };
          }
          return {
            statusBadge: "已处理 " + runs + " 次",
            emptyMessage: "暂无纪要记录",
            items: [
              {
                id: "latest_note",
                badge: "最近纪要",
                title: lastNote,
                subtitle: "累计执行 " + runs + " 次",
                actionTitle: "继续润色",
                prompt: "请基于以下纪要继续提炼行动项：\\n" + lastNote
              }
            ]
          };
        }
        """
        try Data(manifest.utf8).write(to: pkgDir.appendingPathComponent("plugin.json"))
        try Data(script.utf8).write(to: pkgDir.appendingPathComponent("main.js"))

        let importedID = try store.importPlugin(from: pkgDir)
        XCTAssertEqual(importedID, "note_helper")

        // Initial projection before running tool:
        let initialCard = try XCTUnwrap(store.inspectorSnapshots.first { $0.pluginID == "note_helper" })
        XCTAssertEqual(initialCard.statusBadge, "待命")
        XCTAssertTrue(initialCard.items.isEmpty)
        XCTAssertEqual(initialCard.emptyMessage, "尚未整理纪要，输入 /note-format 即可快速开始。")

        // Run `format_note` tool -> updates storage and triggers `rebuildProjections()`:
        let formatOutput = try await store.executeTool(
            qualifiedName: "plugin__note_helper__format_note",
            argumentsJSON: #"{"text":"确认周五发布 macOS 插件 v2"}"#,
            workspaceDirectory: workspaceDir
        )
        XCTAssertTrue(formatOutput.contains("【项目纪要】确认周五发布 macOS 插件 v2"))

        // Verify inspector card snapshot updated from `renderNoteInspector` entry:
        let updatedCard = try XCTUnwrap(store.inspectorSnapshots.first { $0.pluginID == "note_helper" })
        XCTAssertEqual(updatedCard.statusBadge, "已处理 1 次")
        XCTAssertEqual(updatedCard.items.count, 1)
        XCTAssertEqual(updatedCard.items.first?.title, "【项目纪要】确认周五发布 macOS 插件 v2")
        XCTAssertEqual(updatedCard.items.first?.actionTitle, "继续润色")

        // Verify workspaceView badgeCount reflects card items count (1):
        let viewEntry = try XCTUnwrap(store.activeWorkspaceViews.first { $0.pluginID == "note_helper" })
        XCTAssertEqual(viewEntry.badgeCount, 1)

        // Run `save_note` tool -> writes to `notes/weekly.md` and reads back:
        let saveOutput = try await store.executeTool(
            qualifiedName: "plugin__note_helper__save_note",
            argumentsJSON: #"{"filename":"weekly.md","text":"【项目纪要】确认周五发布 macOS 插件 v2"}"#,
            workspaceDirectory: workspaceDir
        )
        XCTAssertTrue(saveOutput.contains("notes/weekly.md"))
        let savedOnDisk = try String(contentsOf: workspaceDir.appendingPathComponent("notes/weekly.md"), encoding: .utf8)
        XCTAssertEqual(savedOnDisk, "【项目纪要】确认周五发布 macOS 插件 v2")
    }
}
