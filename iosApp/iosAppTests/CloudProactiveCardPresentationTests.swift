import Foundation
import Testing
@testable import iosApp

@Suite("Cloud Proactive Card & Center Presentation", .serialized)
struct CloudProactiveCardPresentationTests {

    private actor MockProactiveServer {
        struct RecordedRequest: Sendable {
            var method: String
            var path: String
            var body: String?
        }

        var requests: [RecordedRequest] = []
        private var handler: @Sendable (String, String, String?) -> (Int, String)

        init(handler: @escaping @Sendable (String, String, String?) -> (Int, String)) {
            self.handler = handler
        }

        func handle(_ request: URLRequest) -> (Data, URLResponse) {
            let url = request.url ?? URL(string: "https://cloud.example/")!
            let method = request.httpMethod ?? "GET"
            let path = url.path
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            requests.append(RecordedRequest(method: method, path: path, body: body))
            let (status, json) = handler(method, path, body)
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(json.utf8), response)
        }
    }

    private func makeClient(server: MockProactiveServer) -> MacGatewayClient {
        MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            token: "paired-token-proactive-ui",
            transport: { request, _ in
                await server.handle(request)
            }
        )
    }

    // MARK: - 1. CloudProactiveCardPresentation

    @Test func presentationDegradesSafelyWhenMetaIsNil() {
        let event = MacGatewayCloudDialogueEvent(
            seq: 11,
            id: "proactive:wt_fallback_1",
            kind: .proactiveMessage,
            role: "assistant",
            text: "  云端推送了一条降级主动消息正文  ",
            topicId: "proactive:wt_fallback_1",
            proactive: nil
        )

        let model = CloudProactiveCardPresentation(event: event)
        #expect(model.hasMetadata == false)
        #expect(model.signalId == "wt_fallback_1")
        #expect(model.title == "主动提醒")
        #expect(model.sourceLabel == "主动提醒")
        #expect(model.bodyText == "云端推送了一条降级主动消息正文")
        #expect(model.isUrgent == false)
        #expect(model.urgentBadgeText == nil)
        #expect(model.isSilent == false)
        #expect(model.actions.isEmpty)
    }

    @Test func presentationDegradesEmptyTextAndInvalidEventIdSafely() {
        let event = MacGatewayCloudDialogueEvent(
            seq: 12,
            id: "evt-non-proactive-id",
            kind: .proactiveMessage,
            role: "assistant",
            text: "   \n  ",
            topicId: "topic-1",
            proactive: nil
        )

        let model = CloudProactiveCardPresentation(event: event)
        #expect(model.signalId == nil)
        #expect(model.bodyText == "暂无详细内容")
        #expect(model.actions.isEmpty)
    }

    @Test func presentationHighlightsUrgentAndFiltersActionSubsets() {
        let urgentEvent = MacGatewayCloudDialogueEvent(
            seq: 20,
            id: "proactive:wk_abc_1",
            kind: .proactiveMessage,
            role: "assistant",
            text: "你设置的提醒时间到了。",
            topicId: "proactive:wk_abc_1",
            proactive: MacGatewayCloudProactiveMeta(
                signalId: "wk_abc_1",
                topicKey: "wakeup:wk_abc",
                category: "CLOCK_CRON",
                title: "提交发版检查单",
                urgency: "urgent",
                silent: false,
                sourceLabel: "提醒",
                actions: ["act", "unknown_future_action", "mute", "act", "  SNOOZE "]
            )
        )

        let urgentModel = CloudProactiveCardPresentation(event: urgentEvent)
        #expect(urgentModel.hasMetadata == true)
        #expect(urgentModel.signalId == "wk_abc_1")
        #expect(urgentModel.sourceLabel == "提醒")
        #expect(urgentModel.title == "提交发版检查单")
        #expect(urgentModel.isUrgent == true)
        #expect(urgentModel.urgentBadgeText == "紧急")
        #expect(urgentModel.actions == [.act, .mute, .snooze])
        #expect(CloudProactiveCardAction.act.title == "让 Amber 处理")
        #expect(CloudProactiveCardAction.snooze.title == "1 小时后")
        #expect(CloudProactiveCardAction.mute.title == "减少此类")

        let emptyActionsEvent = MacGatewayCloudDialogueEvent(
            seq: 21,
            id: "proactive:brief_1",
            kind: .proactiveMessage,
            role: "assistant",
            text: "早安简报内容",
            topicId: "proactive:brief_1",
            proactive: MacGatewayCloudProactiveMeta(
                signalId: "brief_1",
                topicKey: "daily:pulse",
                category: "CLOCK_CRON",
                title: "每日晨报",
                urgency: "normal",
                silent: true,
                sourceLabel: "晨报",
                actions: []
            )
        )

        let emptyModel = CloudProactiveCardPresentation(event: emptyActionsEvent)
        #expect(emptyModel.isUrgent == false)
        #expect(emptyModel.urgentBadgeText == nil)
        #expect(emptyModel.isSilent == true)
        #expect(emptyModel.actions.isEmpty)

        let singleActionEvent = MacGatewayCloudDialogueEvent(
            seq: 22,
            id: "proactive:wt_2",
            kind: .proactiveMessage,
            role: "assistant",
            text: "页面出现变更",
            topicId: "proactive:wt_2",
            proactive: MacGatewayCloudProactiveMeta(
                signalId: "wt_2",
                topicKey: "watchtower:mon1",
                category: "EXTERNAL_SENSOR",
                title: "版本更新",
                urgency: "digest",
                sourceLabel: "",
                actions: ["snooze"]
            )
        )

        let singleModel = CloudProactiveCardPresentation(event: singleActionEvent)
        #expect(singleModel.isUrgent == false)
        #expect(singleModel.actions == [.snooze])
    }

    @Test func presentationMapsFallbackSourceLabelsByCategory() {
        let cases: [(String, String)] = [
            ("CLOCK_CRON", "定时提醒"),
            ("EXTERNAL_SENSOR", "外部监控"),
            ("EDGE_NODE_EVENT", "设备动态"),
            ("MEMORY_COMMITMENT", "承诺跟进"),
            ("TASK_LIFECYCLE", "任务动态"),
            ("UNKNOWN_FUTURE_CATEGORY", "主动提醒"),
            ("", "主动提醒"),
        ]

        for (category, expectedLabel) in cases {
            let event = MacGatewayCloudDialogueEvent(
                seq: 30,
                id: "proactive:sig_\(category.count)",
                kind: .proactiveMessage,
                role: "assistant",
                text: "测试正文",
                topicId: "proactive:sig_\(category.count)",
                proactive: MacGatewayCloudProactiveMeta(
                    signalId: "sig_\(category.count)",
                    topicKey: "topic:test",
                    category: category,
                    title: "标题",
                    sourceLabel: "   "
                )
            )
            let model = CloudProactiveCardPresentation(event: event)
            #expect(model.sourceLabel == expectedLabel)
        }
    }

    // MARK: - 2. CloudProactiveCenterPresentation

    @Test func centerSnapshotReflectsEmptyStatesQuotaAndDeviceContextHint() {
        let emptySummary = CloudProactiveSummary(
            monitors: [],
            webhooks: [],
            restraint: CloudProactiveRestraintSnapshot(
                quietHoursEnabled: true,
                quietHoursStart: "23:00",
                quietHoursEnd: "08:00",
                zoneId: "Asia/Shanghai",
                dailyMaxPushes: 0,
                pushesToday: 1,
                remainingToday: 0,
                mutedTopics: []
            ),
            recentRuns: [],
            wakeups: []
        )

        let snapOff = CloudProactiveCenterPresentation.makeSnapshot(
            summary: emptySummary,
            anyDeviceContextSharingEnabled: false
        )
        #expect(snapOff.isMonitorsEmpty == true)
        #expect(snapOff.isWebhooksEmpty == true)
        #expect(snapOff.isMutedTopicsEmpty == true)
        #expect(snapOff.isRecentRunsEmpty == true)
        #expect(snapOff.showsDeviceContextHint == true)
        #expect(snapOff.clampedDailyMaxPushes == 1)
        #expect(snapOff.quotaSummaryText.contains("1 / 1"))

        let snapOn = CloudProactiveCenterPresentation.makeSnapshot(
            summary: CloudProactiveSummary(
                monitors: [CloudProactiveMonitorRecord(id: "m1", title: "Release", url: "https://example.com")],
                webhooks: [CloudProactiveWebhookRecord(id: "w1", name: "CI")],
                restraint: CloudProactiveRestraintSnapshot(
                    dailyMaxPushes: 200,
                    pushesToday: 3,
                    remainingToday: 97,
                    mutedTopics: [CloudProactiveMutedTopic(topicKey: "watchtower:m1", untilEpochMs: 1_800_000_000_000)]
                ),
                recentRuns: [CloudProactiveRunHistoryEntry(id: "r1", title: "Run", outcome: "pushed")]
            ),
            anyDeviceContextSharingEnabled: true
        )
        #expect(snapOn.isMonitorsEmpty == false)
        #expect(snapOn.isWebhooksEmpty == false)
        #expect(snapOn.isMutedTopicsEmpty == false)
        #expect(snapOn.isRecentRunsEmpty == false)
        #expect(snapOn.showsDeviceContextHint == false)
        #expect(snapOn.clampedDailyMaxPushes == 100)
    }

    @Test func centerFormatsMutedTopicsAndQuietHoursDeterministically() {
        #expect(CloudProactiveCenterPresentation.formatTopicKey("watchtower:mon_1") == "网页监控 · mon_1")
        #expect(CloudProactiveCenterPresentation.formatTopicKey("webhook:ci_prod") == "Webhook · ci_prod")
        #expect(CloudProactiveCenterPresentation.formatTopicKey("prep:event:standup") == "会前准备 · standup")
        #expect(CloudProactiveCenterPresentation.formatTopicKey("wakeup:wk123") == "定时提醒 · wk123")
        #expect(CloudProactiveCenterPresentation.formatTopicKey("custom:raw_topic") == "custom:raw_topic")
        #expect(CloudProactiveCenterPresentation.formatTopicKey("  ") == "未命名话题")

        let utc = TimeZone(secondsFromGMT: 0)!
        let nowMs: Int64 = 1_700_000_000_000
        let futureMs: Int64 = 1_700_086_400_000 // 2023-11-15 22:13 UTC
        let activeLabel = CloudProactiveCenterPresentation.formatMutedUntil(futureMs, nowEpochMs: nowMs, timeZone: utc)
        #expect(activeLabel.hasPrefix("静音至 "))
        #expect(activeLabel.contains("11-15 22:13"))

        let expiredLabel = CloudProactiveCenterPresentation.formatMutedUntil(nowMs - 1_000, nowEpochMs: nowMs, timeZone: utc)
        #expect(expiredLabel == "静音已到期")

        let unknownLabel = CloudProactiveCenterPresentation.formatMutedUntil(0, nowEpochMs: nowMs, timeZone: utc)
        #expect(unknownLabel == "到期时间未知")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let parsed = CloudProactiveCenterPresentation.parseHourMinute("23:05", calendar: calendar)
        #expect(CloudProactiveCenterPresentation.formatHourMinute(parsed, calendar: calendar) == "23:05")
    }

    @Test func centerPreservesUnknownOutcomesSafelyAndMapsKnownOutcomes() {
        #expect(CloudProactiveCenterPresentation.outcomeDisplayText(for: "pushed") == "已推送")
        #expect(CloudProactiveCenterPresentation.outcomeDisplayText(for: "digest") == "已转入晨报")
        #expect(CloudProactiveCenterPresentation.outcomeDisplayText(for: "feedback_snooze") == "已推迟提醒")
        #expect(CloudProactiveCenterPresentation.outcomeDisplayText(for: "feedback_mute_topic") == "已静音话题")
        #expect(CloudProactiveCenterPresentation.outcomeDisplayText(for: "wakeup_expired") == "提醒已过期")
        #expect(CloudProactiveCenterPresentation.outcomeDisplayText(for: "") == "未知")

        // Unknown future server outcome must be preserved verbatim.
        #expect(CloudProactiveCenterPresentation.outcomeDisplayText(for: "future_server_outcome_v9") == "future_server_outcome_v9")
        #expect(CloudProactiveCenterPresentation.outcomeTone(for: "future_server_outcome_v9") == .neutral)
        #expect(CloudProactiveCenterPresentation.outcomeTone(for: "pushed") == .success)
        #expect(CloudProactiveCenterPresentation.outcomeTone(for: "wakeup_expired") == .warning)
    }

    @Test @MainActor func detailSheetLoadSignalDoesNotMutateTimelineAndCenterMutationsSyncState() async throws {
        let server = MockProactiveServer { method, path, _ in
            switch (method, path) {
            case ("GET", "/v2/proactive/signals/wt_remote_99"):
                return (
                    200,
                    #"""
                    {
                      "event": {
                        "seq": 88,
                        "id": "proactive:wt_remote_99",
                        "kind": "proactive_message",
                        "role": "assistant",
                        "text": "远端拉取的主动提醒详情",
                        "topicId": "proactive:wt_remote_99",
                        "proactive": {
                          "signalId": "wt_remote_99",
                          "topicKey": "watchtower:remote",
                          "category": "EXTERNAL_SENSOR",
                          "title": "远端详情",
                          "urgency": "urgent",
                          "actions": ["act", "snooze"]
                        }
                      }
                    }
                    """#
                )
            case ("GET", "/v2/proactive/summary"):
                return (
                    200,
                    #"""
                    {
                      "monitors": [
                        {
                          "id": "mon_1",
                          "title": "Release 监控",
                          "url": "https://example.com/releases",
                          "intervalMinutes": 30,
                          "enabled": true,
                          "lastOutcome": "future_monitor_outcome_x"
                        }
                      ],
                      "webhooks": [
                        {
                          "id": "wh_1",
                          "name": "部署告警",
                          "enabled": true,
                          "triggerCount": 4
                        }
                      ],
                      "restraint": {
                        "quietHoursEnabled": true,
                        "quietHoursStart": "23:00",
                        "quietHoursEnd": "08:00",
                        "dailyMaxPushes": 5,
                        "pushesToday": 2,
                        "remainingToday": 3,
                        "mutedTopics": [
                          { "topicKey": "watchtower:mon_1", "untilEpochMs": 1900000000000 }
                        ]
                      },
                      "recentRuns": [
                        {
                          "id": "run_1",
                          "topicKey": "watchtower:mon_1",
                          "title": "",
                          "outcome": "custom_unknown_outcome",
                          "summary": "自定义结果测试",
                          "timestampEpochMs": 1700000000000
                        }
                      ]
                    }
                    """#
                )
            case ("POST", "/v2/proactive/restraint/unmute"):
                return (
                    200,
                    #"""
                    {
                      "restraint": {
                        "quietHoursEnabled": true,
                        "quietHoursStart": "23:00",
                        "quietHoursEnd": "08:00",
                        "dailyMaxPushes": 5,
                        "pushesToday": 2,
                        "remainingToday": 3,
                        "mutedTopics": []
                      }
                    }
                    """#
                )
            default:
                return (404, #"{"error":"not_found"}"#)
            }
        }

        let suite = "CloudProactiveCenterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let gatewayStore = MacGatewayStore(defaults: defaults)
        let client = makeClient(server: server)
        let store = CloudProactiveStore(
            clientProvider: { client },
            localEventsProvider: { gatewayStore.cloudDialogueEvents },
            sendCloudMessageHandler: { _ in
                .success(
                    MacGatewayCloudDialogueReceipt(
                        eventId: "evt-1",
                        requestId: "req-1",
                        topicId: "topic-1",
                        workItemIds: [],
                        state: .received,
                        replayed: false
                    )
                )
            }
        )

        // Loading a remote signal must NOT insert anything into gatewayStore.cloudDialogueEvents.
        let loaded = await store.loadSignal("wt_remote_99")
        #expect(loaded?.id == "proactive:wt_remote_99")
        #expect(gatewayStore.cloudDialogueEvents.isEmpty)
        let loadedPresentation = CloudProactiveCardPresentation(event: try #require(loaded))
        #expect(loadedPresentation.isUrgent == true)
        #expect(loadedPresentation.actions == [.act, .snooze])

        // Refresh summary and verify center presentation mapping + unmute state update.
        await store.refreshSummary()
        let summary = try #require(store.summary)
        #expect(CloudProactiveCenterPresentation.monitorStatusText(for: summary.monitors[0]).contains("future_monitor_outcome_x"))
        #expect(CloudProactiveCenterPresentation.webhookStatusText(for: summary.webhooks[0]).contains("已触发 4 次"))
        #expect(CloudProactiveCenterPresentation.runDisplayTitle(for: summary.recentRuns[0]) == "网页监控 · mon_1")
        #expect(CloudProactiveCenterPresentation.outcomeDisplayText(for: summary.recentRuns[0].outcome) == "custom_unknown_outcome")

        await store.unmute(topicKey: "watchtower:mon_1")
        #expect(store.summary?.restraint.mutedTopics.isEmpty == true)
    }
}
