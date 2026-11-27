import Foundation
import Testing
@testable import iosApp

@Suite("Mac Gateway Cloud Proactive Layer", .serialized)
struct MacGatewayCloudProactiveTests {

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
            token: "paired-token-proactive",
            transport: { request, _ in
                await server.handle(request)
            }
        )
    }

    // MARK: - 1. Decoding & Forward Compatibility

    @Test func proactiveDialogueEventDecodesFullAndMinimalMetaWithDefaults() throws {
        let fullJSON = #"""
        {
          "seq": 42,
          "id": "proactive:wt_mon1_1700000000",
          "kind": "proactive_message",
          "role": "assistant",
          "text": "检测到新版本 v2.4.0 发布",
          "topicId": "proactive:wt_mon1_1700000000",
          "proactive": {
            "signalId": "wt_mon1_1700000000",
            "topicKey": "watchtower:mon1",
            "category": "EXTERNAL_SENSOR",
            "title": "Amber 发布新版本",
            "urgency": "urgent",
            "silent": true,
            "sourceLabel": "网页监控",
            "actions": ["act", "snooze"],
            "checkPrompt": "帮我核对 v2.4.0 变更清单",
            "wakeupId": "wk1234567890",
            "originSignalId": "wt_origin_1"
          }
        }
        """#
        let fullEvent = try JSONDecoder().decode(MacGatewayCloudDialogueEvent.self, from: Data(fullJSON.utf8))
        #expect(fullEvent.kind == .proactiveMessage)
        #expect(fullEvent.seq == 42)
        #expect(fullEvent.workItemId == nil)
        let fullMeta = try #require(fullEvent.proactive)
        #expect(fullMeta.signalId == "wt_mon1_1700000000")
        #expect(fullMeta.topicKey == "watchtower:mon1")
        #expect(fullMeta.category == "EXTERNAL_SENSOR")
        #expect(fullMeta.title == "Amber 发布新版本")
        #expect(fullMeta.urgency == "urgent")
        #expect(fullMeta.silent == true)
        #expect(fullMeta.sourceLabel == "网页监控")
        #expect(fullMeta.actions == ["act", "snooze"])
        #expect(fullMeta.checkPrompt == "帮我核对 v2.4.0 变更清单")
        #expect(fullMeta.wakeupId == "wk1234567890")
        #expect(fullMeta.originSignalId == "wt_origin_1")

        let minimalJSON = #"""
        {
          "seq": 43,
          "id": "proactive:brief_20261127",
          "kind": "proactive_message",
          "role": "assistant",
          "text": "早安，今天有 2 条待跟进提醒。",
          "topicId": "proactive:brief_20261127",
          "proactive": {
            "signalId": "brief_20261127",
            "topicKey": "daily:pulse",
            "category": "CLOCK_CRON",
            "title": "每日晨报"
          }
        }
        """#
        let minimalEvent = try JSONDecoder().decode(MacGatewayCloudDialogueEvent.self, from: Data(minimalJSON.utf8))
        #expect(minimalEvent.kind == .proactiveMessage)
        let minimalMeta = try #require(minimalEvent.proactive)
        #expect(minimalMeta.urgency == "normal")
        #expect(minimalMeta.silent == false)
        #expect(minimalMeta.sourceLabel == "")
        #expect(minimalMeta.actions == ["act", "snooze", "mute"])
        #expect(minimalMeta.checkPrompt == nil)
        #expect(minimalMeta.wakeupId == nil)
        #expect(minimalMeta.originSignalId == nil)

        let legacyEventJSON = #"""
        {
          "seq": 10,
          "id": "evt-legacy-1",
          "kind": "assistant_reply",
          "role": "assistant",
          "text": "普通回复",
          "topicId": "topic-legacy"
        }
        """#
        let legacyEvent = try JSONDecoder().decode(MacGatewayCloudDialogueEvent.self, from: Data(legacyEventJSON.utf8))
        #expect(legacyEvent.kind == .assistantReply)
        #expect(legacyEvent.proactive == nil)
    }

    @Test func summaryAndRunHistoryDecodeLegacyDefaultsAndPreserveUnknownOutcomes() throws {
        // Legacy summary payload missing wakeups, deliveryMode, pulseEnabled/pulseTime/commitmentExtractionEnabled/mutedTopics.
        let legacySummaryJSON = #"""
        {
          "monitors": [
            {
              "id": "mon_abc123",
              "title": "Release 监控",
              "url": "https://example.com/releases",
              "createdAtMs": 1700000000000,
              "nextRunAtMs": 1700000900000
            }
          ],
          "webhooks": [
            {
              "id": "wh_xyz789",
              "name": "CI 告警",
              "createdAtMs": 1700000000000
            }
          ],
          "restraint": {
            "quietHoursEnabled": true,
            "quietHoursStart": "23:00",
            "quietHoursEnd": "08:00",
            "zoneId": "Asia/Shanghai",
            "dailyMaxPushes": 5,
            "pushesToday": 2,
            "remainingToday": 3,
            "bufferedPulseCount": 1,
            "mutedTopicsCount": 0
          },
          "recentRuns": [
            {
              "id": "prun_1",
              "signalId": "wt_1",
              "category": "EXTERNAL_SENSOR",
              "topicKey": "watchtower:mon_abc123",
              "title": "Release 监控",
              "outcome": "feedback_mute_topic",
              "summary": "已静音",
              "timestampEpochMs": 1700000100000
            },
            {
              "id": "prun_2",
              "signalId": "wk_future_1",
              "category": "CLOCK_CRON",
              "topicKey": "wakeup:wk1",
              "title": "未知新结果",
              "outcome": "future_server_outcome_v9",
              "summary": "保留原始枚举串",
              "timestampEpochMs": 1700000200000
            }
          ]
        }
        """#

        let summary = try JSONDecoder().decode(CloudProactiveSummary.self, from: Data(legacySummaryJSON.utf8))
        #expect(summary.wakeups.isEmpty)
        #expect(summary.monitors.count == 1)
        #expect(summary.monitors[0].deliveryMode == "immediate")
        #expect(summary.monitors[0].intervalMinutes == 15)
        #expect(summary.monitors[0].enabled == true)
        #expect(summary.monitors[0].conditionPrompt == "")
        #expect(summary.webhooks.count == 1)
        #expect(summary.webhooks[0].enabled == true)
        #expect(summary.webhooks[0].triggerCount == 0)
        #expect(summary.restraint.pulseEnabled == true)
        #expect(summary.restraint.pulseTime == "08:30")
        #expect(summary.restraint.commitmentExtractionEnabled == true)
        #expect(summary.restraint.mutedTopics.isEmpty)
        #expect(summary.recentRuns.map(\.outcome) == ["feedback_mute_topic", "future_server_outcome_v9"])

        // Full summary payload with wakeups & mutedTopics & digest deliveryMode.
        let fullSummaryJSON = #"""
        {
          "monitors": [
            {
              "id": "mon_digest",
              "title": "Digest 源",
              "url": "https://github.com/org/repo/releases.atom",
              "intervalMinutes": 60,
              "enabled": false,
              "createdAtMs": 100,
              "nextRunAtMs": 200,
              "deliveryMode": "digest"
            }
          ],
          "webhooks": [],
          "restraint": {
            "quietHoursEnabled": false,
            "quietHoursStart": "22:30",
            "quietHoursEnd": "07:30",
            "zoneId": "UTC",
            "dailyMaxPushes": 8,
            "pushesToday": 1,
            "remainingToday": 7,
            "bufferedPulseCount": 2,
            "mutedTopicsCount": 1,
            "pulseEnabled": false,
            "pulseTime": "09:00",
            "commitmentExtractionEnabled": false,
            "mutedTopics": [{"topicKey": "watchtower:mon_digest", "untilEpochMs": 1700600000000}]
          },
          "recentRuns": [],
          "wakeups": [
            {
              "id": "wk1234567890",
              "kind": "commitment",
              "title": "回访合同进度",
              "triggerAtEpochMs": 1700500000000,
              "userRequested": true
            }
          ]
        }
        """#
        let fullSummary = try JSONDecoder().decode(CloudProactiveSummary.self, from: Data(fullSummaryJSON.utf8))
        #expect(fullSummary.monitors.first?.deliveryMode == "digest")
        #expect(fullSummary.restraint.pulseEnabled == false)
        #expect(fullSummary.restraint.pulseTime == "09:00")
        #expect(fullSummary.restraint.commitmentExtractionEnabled == false)
        #expect(fullSummary.restraint.mutedTopics == [
            CloudProactiveMutedTopic(topicKey: "watchtower:mon_digest", untilEpochMs: 1700600000000)
        ])
        #expect(fullSummary.wakeups.count == 1)
        #expect(fullSummary.wakeups[0].status == "pending")
        #expect(fullSummary.wakeups[0].detail == "")
        #expect(fullSummary.wakeups[0].userRequested == true)
    }

    // MARK: - 2. Dialogue Visibility & Causal Isolation

    @Test @MainActor func proactiveEventsAreVisibleWithoutPollutingAwaitingContinuationReceiptsOrSoulSync() async throws {
        let suite = "CloudProactiveIsolation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MacGatewayStore(defaults: defaults)
        let soulStore = AgentSoulStore(userDefaults: defaults)
        let initialSoulRevision = soulStore.lastSyncedRevision
        let initialDisplayName = soulStore.displayName
        store.boundSoulStore = soulStore

        let server = MockProactiveServer { _, _, _ in (200, "{}") }
        store.client = makeClient(server: server)

        // Stage an awaiting main message receipt on topic-turn-1.
        let receipt = MacGatewayCloudDialogueReceipt(
            eventId: "evt-user-1",
            requestId: "req-main-1",
            topicId: "topic-turn-1",
            workItemIds: [],
            state: .received,
            replayed: false
        )
        store.cloudDialogueReceipts[receipt.requestId] = receipt
        store.cloudDialogueSubmissions = [
            MacGatewayCloudDialoguePersistedSubmission(
                gatewayId: "gw-1",
                deviceId: "dev-1",
                kind: .mainMessage,
                requestId: receipt.requestId,
                workItemId: nil,
                text: "请帮我查一下部署状态",
                receipt: receipt,
                lastError: nil,
                updatedAt: Date()
            )
        ]

        let userEvent = MacGatewayCloudDialogueEvent(
            seq: 1,
            id: "evt-user-1",
            kind: .userMessage,
            role: "user",
            text: "请帮我查一下部署状态",
            topicId: "topic-turn-1"
        )
        let proactiveEvent = MacGatewayCloudDialogueEvent(
            seq: 2,
            id: "proactive:wt_1",
            kind: .proactiveMessage,
            role: "assistant",
            text: "你关注的页面发生了更新，我的名字叫测试不该触发 SoulSync。",
            topicId: "proactive:wt_1",
            soulRevision: 99,
            proactive: MacGatewayCloudProactiveMeta(
                signalId: "wt_1",
                topicKey: "watchtower:mon1",
                category: "EXTERNAL_SENSOR",
                title: "页面更新"
            )
        )
        // Defensive check: even a proactive event sharing the user's topicId must NOT settle awaiting or consume receipts.
        let sameTopicProactive = MacGatewayCloudDialogueEvent(
            seq: 3,
            id: "proactive:wt_2",
            kind: .proactiveMessage,
            role: "assistant",
            text: "另一条主动提醒",
            topicId: "topic-turn-1",
            soulRevision: 100,
            proactive: MacGatewayCloudProactiveMeta(
                signalId: "wt_2",
                topicKey: "watchtower:mon2",
                category: "EXTERNAL_SENSOR",
                title: "防御隔离"
            )
        )

        store.ingestCloudDialogueEventsPage(
            .init(items: [userEvent, proactiveEvent, sameTopicProactive], nextCursor: 3, soulRevision: nil),
            requestedAfter: 0
        )

        #expect(store.cloudDialogueVisibleEvents.map(\.id) == ["evt-user-1", "proactive:wt_1", "proactive:wt_2"])
        #expect(store.isAwaitingCloudMainReply == true, "Proactive messages must never clear awaiting main reply")
        #expect(store.cloudDialogueReceipts["req-main-1"]?.state == .received, "Proactive messages must never mark main receipts consumed")
        #expect(store.cloudDialogueSubmissions.first?.receipt?.state == .received)
        #expect(store.cloudDialogueProgressByWorkItem.isEmpty)
        #expect(store.cloudSuggestionReplyID == nil)
        #expect(proactiveEvent.isSuccessfulReplyCompletion == false)
        #expect(soulStore.lastSyncedRevision == initialSoulRevision)
        #expect(soulStore.displayName == initialDisplayName)
        #expect(await server.requests.isEmpty, "Proactive messages must never trigger /v2/soul sync requests")

        // Continuation grouping check: a proactive message interleaved between two assistant replies of the same topic
        // must neither become a continuation itself nor break the continuation of the second reply.
        let reply1 = MacGatewayCloudDialogueEvent(
            seq: 4,
            id: "evt-reply-1",
            kind: .assistantReply,
            role: "assistant",
            text: "第一段回复",
            topicId: "topic-turn-1"
        )
        let interleavedProactive = MacGatewayCloudDialogueEvent(
            seq: 5,
            id: "proactive:wt_3",
            kind: .proactiveMessage,
            role: "assistant",
            text: "插队的主动卡片",
            topicId: "proactive:wt_3",
            proactive: MacGatewayCloudProactiveMeta(
                signalId: "wt_3",
                topicKey: "watchtower:mon3",
                category: "EXTERNAL_SENSOR",
                title: "插队提醒"
            )
        )
        let reply2 = MacGatewayCloudDialogueEvent(
            seq: 6,
            id: "evt-reply-2",
            kind: .taskResult,
            role: "assistant",
            text: "第二段任务结果",
            topicId: "topic-turn-1",
            outcome: .completed
        )

        store.ingestCloudDialogueEventsPage(
            .init(items: [reply1, interleavedProactive, reply2], nextCursor: 6, soulRevision: nil),
            requestedAfter: 3,
            skipSoulSync: true
        )

        #expect(store.cloudDialogueContinuationEventIds == ["evt-reply-2"])
        #expect(!store.cloudDialogueContinuationEventIds.contains("proactive:wt_3"))
        #expect(store.isAwaitingCloudMainReply == false)
        #expect(store.cloudDialogueReceipts["req-main-1"]?.state == .consumed)
    }

    // MARK: - 3. Signal ID Validation & Client Wire Calls

    @Test func clientRejectsUnsafeSignalIdsBeforeNetworkAndValidatesWireEndpoints() async throws {
        let server = MockProactiveServer { method, path, _ in
            switch (method, path) {
            case ("GET", "/v2/proactive/signals/wt_valid-01"):
                return (200, #"""
                {
                  "event": {
                    "seq": 88,
                    "id": "proactive:wt_valid-01",
                    "kind": "proactive_message",
                    "role": "assistant",
                    "text": "远端信号正文",
                    "topicId": "proactive:wt_valid-01",
                    "proactive": {
                      "signalId": "wt_valid-01",
                      "topicKey": "watchtower:mon1",
                      "category": "EXTERNAL_SENSOR",
                      "title": "远端标题"
                    }
                  }
                }
                """#)
            case ("POST", "/v2/proactive/signals/wt_valid-01/feedback"):
                return (200, #"{"ok":true,"action":"snooze","applied":true,"wakeupId":"wk1122334455"}"#)
            default:
                return (404, #"{"error":"not_found"}"#)
            }
        }
        let client = makeClient(server: server)

        let invalidIds = [
            "",
            "../etc/passwd",
            "bad/slash",
            "bad space",
            "中文id",
            String(repeating: "a", count: 49)
        ]
        for badId in invalidIds {
            #expect(!MacGatewayClient.isValidProactiveSignalId(badId))
            await #expect(throws: MacGatewayError.self) {
                _ = try await client.fetchProactiveSignal(signalId: badId)
            }
            await #expect(throws: MacGatewayError.self) {
                _ = try await client.sendProactiveFeedback(signalId: badId, action: .dismiss)
            }
        }
        #expect(await server.requests.isEmpty, "Invalid signal IDs must be rejected locally before hitting transport")

        let maxLenValidId = String(repeating: "A", count: 48)
        #expect(MacGatewayClient.isValidProactiveSignalId(maxLenValidId))

        let event = try await client.fetchProactiveSignal(signalId: "wt_valid-01")
        #expect(event.id == "proactive:wt_valid-01")
        #expect(event.proactive?.signalId == "wt_valid-01")

        let feedbackResp = try await client.sendProactiveFeedback(
            signalId: "wt_valid-01",
            action: .snooze,
            snoozeMinutes: 60,
            muteHours: nil
        )
        #expect(feedbackResp.ok == true)
        #expect(feedbackResp.applied == true)
        #expect(feedbackResp.wakeupId == "wk1122334455")

        let recorded = await server.requests
        #expect(recorded.count == 2)
        #expect(recorded[1].method == "POST")
        #expect(recorded[1].path == "/v2/proactive/signals/wt_valid-01/feedback")
        let bodyData = try #require(recorded[1].body?.data(using: .utf8))
        let bodyObj = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(bodyObj["action"] as? String == "snooze")
        #expect(bodyObj["snoozeMinutes"] as? Int == 60)
        #expect(bodyObj["muteHours"] == nil)
    }

    // MARK: - 4. CloudProactiveStore Behavior

    @Test func buildActPromptPrefersCheckPromptAndTruncatesFallbackTo600Chars() {
        let withCheckPrompt = MacGatewayCloudDialogueEvent(
            seq: 1,
            id: "proactive:wk_1",
            kind: .proactiveMessage,
            role: "assistant",
            text: "这是一段正文",
            topicId: "proactive:wk_1",
            proactive: MacGatewayCloudProactiveMeta(
                signalId: "wk_1",
                topicKey: "wakeup:wk_1",
                category: "CLOCK_CRON",
                title: "定时回访",
                checkPrompt: "  请检查 PR #42 的 CI 结果并汇报  "
            )
        )
        #expect(CloudProactiveStore.buildActPrompt(for: withCheckPrompt) == "请检查 PR #42 的 CI 结果并汇报")

        let longBody = String(repeating: "测", count: 750)
        let withoutCheckPrompt = MacGatewayCloudDialogueEvent(
            seq: 2,
            id: "proactive:wt_2",
            kind: .proactiveMessage,
            role: "assistant",
            text: longBody,
            topicId: "proactive:wt_2",
            proactive: MacGatewayCloudProactiveMeta(
                signalId: "wt_2",
                topicKey: "watchtower:mon2",
                category: "EXTERNAL_SENSOR",
                title: "网页变更",
                checkPrompt: "   "
            )
        )
        let prompt = CloudProactiveStore.buildActPrompt(for: withoutCheckPrompt)
        let expectedPrefix = "关于这条主动提醒「网页变更」，请帮我处理：\n\n"
        #expect(prompt == expectedPrefix + String(repeating: "测", count: 600))
    }

    @Test @MainActor func loadSignalPrefersLocalDialogueEventsAndFallsBackToRemote() async throws {
        let server = MockProactiveServer { method, path, _ in
            if method == "GET", path == "/v2/proactive/signals/remote_sig_9" {
                return (200, #"""
                {
                  "event": {
                    "seq": 99,
                    "id": "proactive:remote_sig_9",
                    "kind": "proactive_message",
                    "role": "assistant",
                    "text": "来自远端接口的卡片详情",
                    "topicId": "proactive:remote_sig_9",
                    "proactive": {
                      "signalId": "remote_sig_9",
                      "topicKey": "webhook:wh_1",
                      "category": "EXTERNAL_SENSOR",
                      "title": "远端卡片"
                    }
                  }
                }
                """#)
            }
            return (404, #"{"error":"signal_not_found"}"#)
        }
        let client = makeClient(server: server)

        let localByMeta = MacGatewayCloudDialogueEvent(
            seq: 10,
            id: "evt-custom-local-1",
            kind: .proactiveMessage,
            role: "assistant",
            text: "本地命中（meta.signalId）",
            topicId: "proactive:local_sig_1",
            proactive: MacGatewayCloudProactiveMeta(
                signalId: "local_sig_1",
                topicKey: "watchtower:m1",
                category: "EXTERNAL_SENSOR",
                title: "本地卡片 1"
            )
        )
        let localById = MacGatewayCloudDialogueEvent(
            seq: 11,
            id: "proactive:local_sig_2",
            kind: .proactiveMessage,
            role: "assistant",
            text: "本地命中（event.id）",
            topicId: "proactive:local_sig_2"
        )

        let proactiveStore = CloudProactiveStore(
            clientProvider: { client },
            localEventsProvider: { [localByMeta, localById] }
        )

        let hit1 = await proactiveStore.loadSignal("local_sig_1")
        let hit2 = await proactiveStore.loadSignal("local_sig_2")
        #expect(hit1 == localByMeta)
        #expect(hit2 == localById)
        #expect(await server.requests.isEmpty, "Local hits must not issue remote GET requests")

        let remoteHit = await proactiveStore.loadSignal("remote_sig_9")
        #expect(remoteHit?.id == "proactive:remote_sig_9")
        #expect(remoteHit?.proactive?.title == "远端卡片")
        #expect(proactiveStore.lastError == nil)

        let missing = await proactiveStore.loadSignal("missing_sig_404")
        #expect(missing == nil)
        #expect(proactiveStore.lastError != nil)
    }

    @Test @MainActor func mismatchedSignalAndFeedbackReceiptsDoNotReportSuccess() async throws {
        let server = MockProactiveServer { method, _, _ in
            if method == "GET" {
                return (200, #"{"event":{"seq":1,"id":"proactive:other","kind":"proactive_message","role":"assistant","text":"","topicId":"proactive:other"}}"#)
            }
            return (200, #"{"ok":true,"action":"snooze","applied":false}"#)
        }
        let client = makeClient(server: server)
        let wrongKind = MacGatewayCloudDialogueEvent(
            seq: 1, id: "proactive:asked", kind: .assistantReply, role: "assistant", text: "", topicId: "turn"
        )
        let store = CloudProactiveStore(clientProvider: { client }, localEventsProvider: { [wrongKind] })
        let invalid = await store.loadSignal(" asked ")
        #expect(invalid == nil)
        #expect(await server.requests.isEmpty)
        let wrongSignal = await store.loadSignal("asked")
        #expect(wrongSignal == nil)
        #expect(store.lastError != nil)
        let wrongFeedback = await store.sendFeedback(signalId: "asked", action: .muteTopic)
        #expect(!wrongFeedback)
        let replay = await store.sendFeedback(signalId: "asked", action: .snooze)
        #expect(replay)
        #expect(store.lastError == nil)
    }

    @Test @MainActor func submittedActReportsFeedbackFailureAndRetryOnlyPostsFeedback() async throws {
        let server = MockProactiveServer { _, _, _ in (503, #"{"error":"feedback_unavailable"}"#) }
        let client = makeClient(server: server)
        var submitted = 0
        let store = CloudProactiveStore(
            clientProvider: { client },
            localEventsProvider: { [] },
            sendCloudMessageHandler: { _ in
                submitted += 1
                return .success(.init(eventId: "message", requestId: "req", topicId: "turn",
                                      workItemIds: [], state: .received, replayed: false))
            }
        )
        let event = MacGatewayCloudDialogueEvent(
            seq: 1, id: "proactive:sig1", kind: .proactiveMessage, role: "assistant", text: "提醒", topicId: "proactive:sig1"
        )
        let accepted = await store.act(on: event)
        #expect(accepted)
        #expect(store.lastError?.contains("feedback_unavailable") == true)
        let feedback = await store.sendFeedback(signalId: "sig1", action: .replied)
        #expect(!feedback)
        #expect(submitted == 1)
        #expect(await server.requests.map(\.path) == Array(repeating: "/v2/proactive/signals/sig1/feedback", count: 2))
    }

    @Test @MainActor func dismissingReplacedSheetKeepsNewSignalPending() {
        let store = CloudProactiveStore(clientProvider: { nil }, localEventsProvider: { [] })
        store.pendingSignalId = "second"
        store.dismissSignal("first")
        #expect(store.pendingSignalId == "second")
        store.dismissSignal("second")
        #expect(store.pendingSignalId == nil)
    }

    @Test @MainActor func proactiveCardsDoNotCreateWatchActivitiesOrHubTasks() throws {
        let suite = "CloudProactiveRemoteProjections-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gateway = MacGatewayStore(defaults: defaults)
        let soulStore = AgentSoulStore(userDefaults: defaults)
        gateway.boundSoulStore = soulStore
        gateway.configureForTesting(
            connection: .init(gatewayId: "test", name: "Cloud", addrs: ["cloud.example"], port: 443,
                              fingerprint: "fp", deviceId: "device"),
            client: makeClient(server: MockProactiveServer { _, _, _ in (404, "{}") })
        )
        let event = MacGatewayCloudDialogueEvent(
            seq: 1, id: "proactive:sig1", kind: .proactiveMessage, role: "assistant", text: "待回复的提醒", topicId: "proactive:sig1"
        )
        gateway.ingestCloudDialogueEventsPage(.init(items: [event], nextCursor: 1), requestedAfter: 0)
        #expect(gateway.cloudDialogueCursor == 1)
        #expect(gateway.cloudDialogueVisibleEvents == [event])
        let watch = MacGatewayWatchExecutionAdapter(store: gateway).currentProjection()
        #expect(watch.isPaired)
        #expect(watch.primaryTask == nil)
        #expect(watch.recentActivities.isEmpty)

        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let groups = AmberUnifiedTaskBuilder.buildTasks(
            gateway: gateway, subAgentStore: IOSSubAgentActivityStore(tasks: tasks, defaults: defaults),
            taskStore: tasks, wakeStore: IOSWakeTaskStore(fileURL: URL.temporaryDirectory.appending(path: suite)),
            hubStore: AmberHubStore(defaults: defaults)
        )
        #expect(groups.isEmpty)
    }

    @Test @MainActor func storeManagesSummaryFeedbackMonitorsWebhooksRestraintUnmuteAndAct() async throws {
        let server = MockProactiveServer { method, path, body in
            switch (method, path) {
            case ("GET", "/v2/proactive/summary"):
                return (200, #"""
                {
                  "monitors": [
                    {
                      "id": "mon_1",
                      "title": "价格监控",
                      "url": "https://example.com/price",
                      "enabled": true,
                      "createdAtMs": 1000,
                      "nextRunAtMs": 2000
                    }
                  ],
                  "webhooks": [
                    {
                      "id": "wh_1",
                      "name": "部署钩子",
                      "enabled": true,
                      "createdAtMs": 1000,
                      "triggerCount": 3
                    }
                  ],
                  "restraint": {
                    "quietHoursEnabled": true,
                    "quietHoursStart": "23:00",
                    "quietHoursEnd": "08:00",
                    "zoneId": "Asia/Shanghai",
                    "dailyMaxPushes": 5,
                    "pushesToday": 1,
                    "remainingToday": 4,
                    "bufferedPulseCount": 0,
                    "mutedTopicsCount": 1,
                    "pulseEnabled": true,
                    "pulseTime": "08:30",
                    "commitmentExtractionEnabled": true,
                    "mutedTopics": [{"topicKey": "watchtower:mon_1", "untilEpochMs": 9999999}]
                  },
                  "recentRuns": [],
                  "wakeups": []
                }
                """#)

            case ("PATCH", "/v2/proactive/monitors/mon_1"):
                return (200, #"""
                {
                  "monitor": {
                    "id": "mon_1",
                    "title": "价格监控",
                    "url": "https://example.com/price",
                    "enabled": false,
                    "createdAtMs": 1000,
                    "nextRunAtMs": 2000
                  }
                }
                """#)

            case ("DELETE", "/v2/proactive/monitors/mon_1"):
                return (200, #"{"deleted":true,"id":"mon_1"}"#)

            case ("PATCH", "/v2/proactive/webhooks/wh_1"):
                return (200, #"""
                {
                  "webhook": {
                    "id": "wh_1",
                    "name": "部署钩子",
                    "enabled": false,
                    "createdAtMs": 1000,
                    "triggerCount": 3
                  }
                }
                """#)

            case ("DELETE", "/v2/proactive/webhooks/wh_1"):
                return (200, #"{"deleted":true,"id":"wh_1"}"#)

            case ("PATCH", "/v2/proactive/restraint"):
                return (200, #"""
                {
                  "restraint": {
                    "quietHoursEnabled": false,
                    "quietHoursStart": "22:00",
                    "quietHoursEnd": "07:00",
                    "zoneId": "Asia/Shanghai",
                    "dailyMaxPushes": 8,
                    "pushesToday": 1,
                    "remainingToday": 7,
                    "bufferedPulseCount": 0,
                    "mutedTopicsCount": 1,
                    "pulseEnabled": false,
                    "pulseTime": "09:00",
                    "commitmentExtractionEnabled": false,
                    "mutedTopics": [{"topicKey": "watchtower:mon_1", "untilEpochMs": 9999999}]
                  }
                }
                """#)

            case ("POST", "/v2/proactive/restraint/unmute"):
                return (200, #"""
                {
                  "restraint": {
                    "quietHoursEnabled": false,
                    "quietHoursStart": "22:00",
                    "quietHoursEnd": "07:00",
                    "zoneId": "Asia/Shanghai",
                    "dailyMaxPushes": 8,
                    "pushesToday": 1,
                    "remainingToday": 7,
                    "bufferedPulseCount": 0,
                    "mutedTopicsCount": 0,
                    "pulseEnabled": false,
                    "pulseTime": "09:00",
                    "commitmentExtractionEnabled": false,
                    "mutedTopics": []
                  }
                }
                """#)

            case ("POST", "/v2/proactive/signals/sig_act_1/feedback"):
                let action = body?.contains("mute_topic") == true ? "mute_topic" : "replied"
                return (200, #"{"ok":true,"action":"\#(action)","applied":true}"#)

            default:
                return (404, #"{"error":"not_found"}"#)
            }
        }
        let client = makeClient(server: server)

        @MainActor
        final class SendHarness {
            var sentPrompts: [String] = []
            var shouldFailSend = false
        }
        let harness = SendHarness()
        let store = CloudProactiveStore(
            clientProvider: { client },
            localEventsProvider: { [] },
            sendCloudMessageHandler: { text in
                harness.sentPrompts.append(text)
                if harness.shouldFailSend {
                    return .failure(MacGatewayError.unreachable)
                }
                return .success(
                    MacGatewayCloudDialogueReceipt(
                        eventId: "evt-sent-1",
                        requestId: "req-act-1",
                        topicId: "topic-act-1",
                        workItemIds: [],
                        state: .received,
                        replayed: false
                    )
                )
            }
        )

        await store.refreshSummary()
        #expect(store.isLoading == false)
        #expect(store.lastError == nil)
        #expect(store.summary?.monitors.first?.enabled == true)
        #expect(store.summary?.restraint.mutedTopics.count == 1)

        await store.setMonitorEnabled(id: "mon_1", enabled: false)
        #expect(store.summary?.monitors.first?.enabled == false)

        await store.deleteMonitor(id: "mon_1")
        #expect(store.summary?.monitors.isEmpty == true)

        await store.setWebhookEnabled(id: "wh_1", enabled: false)
        #expect(store.summary?.webhooks.first?.enabled == false)

        await store.deleteWebhook(id: "wh_1")
        #expect(store.summary?.webhooks.isEmpty == true)

        await store.updateRestraint(
            CloudProactiveRestraintPatch(
                quietHoursEnabled: false,
                dailyMaxPushes: 8,
                pulseEnabled: false,
                pulseTime: "09:00",
                commitmentExtractionEnabled: false
            )
        )
        #expect(store.summary?.restraint.quietHoursEnabled == false)
        #expect(store.summary?.restraint.dailyMaxPushes == 8)
        #expect(store.summary?.restraint.pulseTime == "09:00")

        await store.unmute(topicKey: "watchtower:mon_1")
        #expect(store.summary?.restraint.mutedTopics.isEmpty == true)
        #expect(store.summary?.restraint.mutedTopicsCount == 0)

        let muted = await store.sendFeedback(signalId: "sig_act_1", action: .muteTopic)
        #expect(muted == true)

        let actEvent = MacGatewayCloudDialogueEvent(
            seq: 50,
            id: "proactive:sig_act_1",
            kind: .proactiveMessage,
            role: "assistant",
            text: "构建失败详情",
            topicId: "proactive:sig_act_1",
            proactive: MacGatewayCloudProactiveMeta(
                signalId: "sig_act_1",
                topicKey: "webhook:wh_1",
                category: "EXTERNAL_SENSOR",
                title: "CI 失败",
                checkPrompt: "帮我排查本次 CI 失败原因"
            )
        )
        let acted = await store.act(on: actEvent)
        #expect(acted == true)
        #expect(harness.sentPrompts == ["帮我排查本次 CI 失败原因"])

        let requests = await server.requests
        let sentRepliedFeedback = requests.contains { req in
            req.method == "POST"
                && req.path == "/v2/proactive/signals/sig_act_1/feedback"
                && (req.body?.contains("\"replied\"") ?? false)
        }
        #expect(sentRepliedFeedback)

        let sentRestraintPatch = requests.contains { req in
            req.method == "PATCH"
                && req.path == "/v2/proactive/restraint"
                && (req.body?.contains("\"pulseTime\":\"09:00\"") ?? false)
                && !(req.body?.contains("quietHoursStart") ?? true)
        }
        #expect(sentRestraintPatch)

        // Failure path: must report error and NOT send replied feedback.
        harness.shouldFailSend = true
        let countBeforeFailure = requests.count
        let failedAct = await store.act(on: actEvent)
        #expect(failedAct == false)
        #expect(store.lastError != nil)
        #expect(await server.requests.count == countBeforeFailure)

        // Unpaired store must record user-visible error instead of silent return.
        let unpairedStore = CloudProactiveStore(clientProvider: { nil }, localEventsProvider: { [] })
        let feedbackWhileUnpaired = await unpairedStore.sendFeedback(signalId: "sig_act_1", action: .opened)
        #expect(feedbackWhileUnpaired == false)
        #expect(unpairedStore.lastError != nil)
    }

    // MARK: - 5. Phase 2 (I4): Wakeup Cancel & Restraint Pulse/Commitment Patch

    @Test @MainActor func cancelWakeupSendsDeleteHandlesFailureAndRejectsInvalidIds() async throws {
        let server = MockProactiveServer { method, path, _ in
            switch (method, path) {
            case ("GET", "/v2/proactive/summary"):
                return (200, #"""
                {
                  "monitors": [],
                  "webhooks": [],
                  "restraint": {
                    "quietHoursEnabled": true,
                    "quietHoursStart": "23:00",
                    "quietHoursEnd": "08:00",
                    "dailyMaxPushes": 5,
                    "pushesToday": 0,
                    "remainingToday": 5,
                    "pulseEnabled": true,
                    "pulseTime": "08:30",
                    "commitmentExtractionEnabled": true,
                    "mutedTopics": []
                  },
                  "recentRuns": [],
                  "wakeups": [
                    {
                      "id": "wk_commit_01",
                      "kind": "commitment",
                      "title": "周五前回访方案",
                      "detail": "发邮件确认预算",
                      "triggerAtEpochMs": 1700500000000,
                      "userRequested": true,
                      "status": "pending"
                    },
                    {
                      "id": "wk_snooze_02",
                      "kind": "snooze",
                      "title": "稍后再看的卡片",
                      "triggerAtEpochMs": 1700503600000,
                      "userRequested": true,
                      "status": "pending"
                    }
                  ]
                }
                """#)
            case ("DELETE", "/v2/proactive/wakeups/wk_commit_01"):
                return (200, #"{"cancelled":true,"id":"wk_commit_01"}"#)
            case ("DELETE", "/v2/proactive/wakeups/wk_missing_404"):
                return (404, #"{"error":"wakeup_not_found"}"#)
            default:
                return (404, #"{"error":"not_found"}"#)
            }
        }
        let client = makeClient(server: server)
        let store = CloudProactiveStore(clientProvider: { client }, localEventsProvider: { [] })

        // Invalid wakeup IDs must be rejected locally before hitting transport.
        let invalidIds = [
            "",
            "   ",
            "../etc/passwd",
            "wk/slash",
            "wk space",
            "wk?x=1",
            "wk#frag",
            "中文id",
            String(repeating: "w", count: 65),
        ]
        for badId in invalidIds {
            #expect(!MacGatewayClient.isValidProactiveWakeupId(badId))
            await #expect(throws: MacGatewayError.self) {
                try await client.cancelProactiveWakeup(id: badId)
            }
            await store.cancelWakeup(id: badId)
            #expect(store.lastError != nil)
        }
        #expect(await server.requests.isEmpty, "Invalid wakeup IDs must never hit network")

        await store.refreshSummary()
        #expect(store.summary?.wakeups.count == 2)
        #expect(store.lastError == nil)

        // Successful cancellation removes only the cancelled wakeup and clears error.
        await store.cancelWakeup(id: "wk_commit_01")
        #expect(store.lastError == nil)
        #expect(store.summary?.wakeups.map(\.id) == ["wk_snooze_02"])

        // Server failure must record explicit error and keep remaining wakeups intact.
        await store.cancelWakeup(id: "wk_missing_404")
        #expect(store.lastError != nil)
        #expect(store.summary?.wakeups.map(\.id) == ["wk_snooze_02"])

        let recorded = await server.requests
        #expect(recorded.contains { $0.method == "DELETE" && $0.path == "/v2/proactive/wakeups/wk_commit_01" })
        #expect(recorded.contains { $0.method == "DELETE" && $0.path == "/v2/proactive/wakeups/wk_missing_404" })

        // Unpaired store must record error rather than returning silently.
        let unpaired = CloudProactiveStore(clientProvider: { nil }, localEventsProvider: { [] })
        await unpaired.cancelWakeup(id: "wk_commit_01")
        #expect(unpaired.lastError != nil)
    }

    @Test @MainActor func updateRestraintForwardsPulseAndCommitmentFieldsAccurately() async throws {
        let server = MockProactiveServer { method, path, body in
            switch (method, path) {
            case ("GET", "/v2/proactive/summary"):
                return (200, #"""
                {
                  "monitors": [],
                  "webhooks": [],
                  "restraint": {
                    "quietHoursEnabled": true,
                    "quietHoursStart": "23:00",
                    "quietHoursEnd": "08:00",
                    "dailyMaxPushes": 5,
                    "pushesToday": 0,
                    "remainingToday": 5,
                    "pulseEnabled": true,
                    "pulseTime": "08:30",
                    "commitmentExtractionEnabled": true,
                    "mutedTopics": []
                  },
                  "recentRuns": [],
                  "wakeups": []
                }
                """#)
            case ("PATCH", "/v2/proactive/restraint"):
                let pulseEnabled = body?.contains("\"pulseEnabled\":false") == true ? "false" : "true"
                let pulseTime = body?.contains("\"pulseTime\":\"07:45\"") == true ? "07:45" : "08:30"
                let commitEnabled = body?.contains("\"commitmentExtractionEnabled\":false") == true ? "false" : "true"
                return (200, #"""
                {
                  "restraint": {
                    "quietHoursEnabled": true,
                    "quietHoursStart": "23:00",
                    "quietHoursEnd": "08:00",
                    "dailyMaxPushes": 5,
                    "pushesToday": 0,
                    "remainingToday": 5,
                    "pulseEnabled": \#(pulseEnabled),
                    "pulseTime": "\#(pulseTime)",
                    "commitmentExtractionEnabled": \#(commitEnabled),
                    "mutedTopics": []
                  }
                }
                """#)
            default:
                return (404, #"{"error":"not_found"}"#)
            }
        }
        let client = makeClient(server: server)
        let store = CloudProactiveStore(clientProvider: { client }, localEventsProvider: { [] })
        await store.refreshSummary()

        await store.updateRestraint(
            CloudProactiveRestraintPatch(
                pulseEnabled: false,
                pulseTime: "07:45",
                commitmentExtractionEnabled: false
            )
        )
        #expect(store.lastError == nil)
        #expect(store.summary?.restraint.pulseEnabled == false)
        #expect(store.summary?.restraint.pulseTime == "07:45")
        #expect(store.summary?.restraint.commitmentExtractionEnabled == false)

        let patchReq = try #require(await server.requests.last(where: { $0.method == "PATCH" && $0.path == "/v2/proactive/restraint" }))
        let bodyData = try #require(patchReq.body?.data(using: .utf8))
        let bodyObj = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(bodyObj["pulseEnabled"] as? Bool == false)
        #expect(bodyObj["pulseTime"] as? String == "07:45")
        #expect(bodyObj["commitmentExtractionEnabled"] as? Bool == false)
        #expect(bodyObj["quietHoursEnabled"] == nil)
        #expect(bodyObj["dailyMaxPushes"] == nil)
    }

    // MARK: - 6. Phase 3 (I5): Monitor Delivery Mode & GitHub Release Template

    @Test @MainActor func setMonitorDeliveryModeValidatesModeAndPatchesMonitor() async throws {
        let server = MockProactiveServer { method, path, body in
            switch (method, path) {
            case ("GET", "/v2/proactive/summary"):
                return (200, #"""
                {
                  "monitors": [
                    {
                      "id": "mon_rel_1",
                      "title": "Swift Releases",
                      "url": "https://github.com/apple/swift/releases.atom",
                      "enabled": true,
                      "deliveryMode": "immediate"
                    }
                  ],
                  "webhooks": [],
                  "restraint": {
                    "quietHoursEnabled": true,
                    "quietHoursStart": "23:00",
                    "quietHoursEnd": "08:00",
                    "dailyMaxPushes": 5
                  },
                  "recentRuns": [],
                  "wakeups": []
                }
                """#)
            case ("PATCH", "/v2/proactive/monitors/mon_rel_1"):
                let nextMode = body?.contains("\"digest\"") == true ? "digest" : "immediate"
                return (200, #"""
                {
                  "monitor": {
                    "id": "mon_rel_1",
                    "title": "Swift Releases",
                    "url": "https://github.com/apple/swift/releases.atom",
                    "enabled": true,
                    "deliveryMode": "\#(nextMode)"
                  }
                }
                """#)
            default:
                return (404, #"{"error":"monitor_not_found"}"#)
            }
        }
        let client = makeClient(server: server)
        let store = CloudProactiveStore(clientProvider: { client }, localEventsProvider: { [] })

        // Illegal delivery modes must be rejected before hitting transport.
        for badMode in ["", "DIGEST", "silent", "digest ", "immediate\n", "email"] {
            #expect(!MacGatewayClient.isValidProactiveMonitorDeliveryMode(badMode))
            await #expect(throws: MacGatewayError.self) {
                _ = try await client.setProactiveMonitorDeliveryMode(id: "mon_rel_1", deliveryMode: badMode)
            }
            await store.setMonitorDeliveryMode(id: "mon_rel_1", mode: badMode)
            #expect(store.lastError != nil)
        }
        #expect(await server.requests.isEmpty, "Invalid deliveryMode must never hit transport")

        await store.refreshSummary()
        #expect(store.summary?.monitors.first?.deliveryMode == "immediate")

        await store.setMonitorDeliveryMode(id: "mon_rel_1", mode: "digest")
        #expect(store.lastError == nil)
        #expect(store.summary?.monitors.first?.deliveryMode == "digest")

        await store.setMonitorDeliveryMode(id: "mon_rel_1", mode: "immediate")
        #expect(store.lastError == nil)
        #expect(store.summary?.monitors.first?.deliveryMode == "immediate")

        let patchRequests = await server.requests.filter { $0.method == "PATCH" && $0.path == "/v2/proactive/monitors/mon_rel_1" }
        #expect(patchRequests.count == 2)
        let firstPatchObj = try #require(
            patchRequests[0].body.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        )
        #expect(firstPatchObj["deliveryMode"] as? String == "digest")
        let secondPatchObj = try #require(
            patchRequests[1].body.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        )
        #expect(secondPatchObj["deliveryMode"] as? String == "immediate")
    }

    @Test func buildGitHubReleaseFeedURLStrictlyEnforcesSecurityBoundaries() {
        let validCases: [(String, String)] = [
            ("owner/repo", "https://github.com/owner/repo/releases.atom"),
            ("  org-name/repo_1-2 \n", "https://github.com/org-name/repo_1-2/releases.atom"),
            ("dev_company/repo", "https://github.com/dev_company/repo/releases.atom"),
            ("apple/swift", "https://github.com/apple/swift/releases.atom"),
            ("my-org/.github", "https://github.com/my-org/.github/releases.atom"),
        ]
        for (slug, expected) in validCases {
            let url = MacGatewayClient.buildGitHubReleaseFeedURL(from: slug)
            #expect(url?.absoluteString == expected)
            #expect(url?.scheme == "https")
            #expect(url?.host == "github.com")
            #expect(CloudProactiveStore.buildGitHubReleaseFeedURL(from: slug)?.absoluteString == expected)
        }

        let invalidSlugs = [
            "",
            "   ",
            "http://evil.com/owner/repo",
            "https://github.com/owner/repo",
            "../etc/passwd",
            "../repo",
            "owner/..",
            "./repo",
            "owner/.",
            "a..b/repo",
            "org.name/repo",
            "-org/repo",
            "org-/repo",
            "my--org/repo",
            String(repeating: "a", count: 40) + "/repo",
            "owner/a..b",
            "a/b?x=1",
            "a/b#frag",
            "127.0.0.1/x",
            "10.0.0.1/repo",
            "169.254.169.254/latest",
            "0x7f.0.0.1/x",
            "a/b/c",
            "onlyowner",
            "/repo",
            "owner/",
            "owner name/repo",
            "owner/repo name",
            "owner%2Frepo/x",
            "owner/repo@v1",
        ]
        for badSlug in invalidSlugs {
            #expect(
                MacGatewayClient.buildGitHubReleaseFeedURL(from: badSlug) == nil,
                "Slug '\(badSlug)' must be rejected"
            )
        }
    }

    @Test @MainActor func addGitHubReleaseMonitorValidatesSlugPostsMonitorAndRefreshesSummary() async throws {
        let server = MockProactiveServer { method, path, body in
            switch (method, path) {
            case ("POST", "/v2/proactive/monitors"):
                let bodyObj = body.flatMap { $0.data(using: .utf8) }.flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                } ?? [:]
                let title = bodyObj["title"] as? String ?? ""
                let url = bodyObj["url"] as? String ?? ""
                let mode = bodyObj["deliveryMode"] as? String ?? "immediate"
                if url.contains("fail-org/fail-repo") {
                    return (500, #"{"error":"upstream_failed"}"#)
                }
                return (201, #"""
                {
                  "monitor": {
                    "id": "mon_gh_1",
                    "title": "\#(title)",
                    "url": "\#(url)",
                    "enabled": true,
                    "deliveryMode": "\#(mode)"
                  }
                }
                """#)
            case ("GET", "/v2/proactive/summary"):
                return (200, #"""
                {
                  "monitors": [
                    {
                      "id": "mon_gh_1",
                      "title": "org-name/repo_1-2 Releases",
                      "url": "https://github.com/org-name/repo_1-2/releases.atom",
                      "enabled": true,
                      "deliveryMode": "digest"
                    }
                  ],
                  "webhooks": [],
                  "restraint": {
                    "quietHoursEnabled": true,
                    "quietHoursStart": "23:00",
                    "quietHoursEnd": "08:00",
                    "dailyMaxPushes": 5
                  },
                  "recentRuns": [],
                  "wakeups": []
                }
                """#)
            default:
                return (404, #"{"error":"not_found"}"#)
            }
        }
        let client = makeClient(server: server)
        let store = CloudProactiveStore(clientProvider: { client }, localEventsProvider: { [] })

        // Invalid slug must fail locally with readable error and zero network calls.
        let rejected = await store.addGitHubReleaseMonitor(repoSlug: "127.0.0.1/x")
        #expect(rejected == false)
        #expect(store.lastError != nil)
        #expect(await server.requests.isEmpty)

        // Valid slug posts to /v2/proactive/monitors with default deliveryMode="digest" and refreshes summary.
        let created = await store.addGitHubReleaseMonitor(repoSlug: "  org-name/repo_1-2  ")
        #expect(created == true)
        #expect(store.lastError == nil)
        #expect(store.summary?.monitors.count == 1)
        #expect(store.summary?.monitors.first?.url == "https://github.com/org-name/repo_1-2/releases.atom")
        #expect(store.summary?.monitors.first?.deliveryMode == "digest")

        let requests = await server.requests
        let postReq = try #require(requests.first(where: { $0.method == "POST" && $0.path == "/v2/proactive/monitors" }))
        let postData = try #require(postReq.body?.data(using: .utf8))
        let postObj = try #require(JSONSerialization.jsonObject(with: postData) as? [String: Any])
        #expect(postObj["title"] as? String == "org-name/repo_1-2 Releases")
        #expect(postObj["url"] as? String == "https://github.com/org-name/repo_1-2/releases.atom")
        #expect(postObj["deliveryMode"] as? String == "digest")
        #expect(requests.contains { $0.method == "GET" && $0.path == "/v2/proactive/summary" })

        // Server failure must return false and record readable error.
        let failed = await store.addGitHubReleaseMonitor(repoSlug: "fail-org/fail-repo", deliveryMode: "immediate")
        #expect(failed == false)
        #expect(store.lastError != nil)

        // Presentation helpers for Phase 2 & 3 labels and pending wakeup sorting.
        #expect(CloudProactiveCenterPresentation.wakeupSourceLabel(for: "commitment") == "从对话记下")
        #expect(CloudProactiveCenterPresentation.wakeupSourceLabel(for: "snooze") == "稍后提醒")
        #expect(CloudProactiveCenterPresentation.wakeupSourceLabel(for: "agent") == "Amber 安排")
        #expect(CloudProactiveCenterPresentation.deliveryModeDisplayText(for: "digest") == "并入晨报")
        #expect(CloudProactiveCenterPresentation.deliveryModeDisplayText(for: "immediate") == "即时推送")

        let summaryForSort = CloudProactiveSummary(
            wakeups: [
                CloudProactiveWakeupRecord(id: "wk_late", kind: "agent", title: "晚点", triggerAtEpochMs: 2000, status: "pending"),
                CloudProactiveWakeupRecord(id: "wk_fired", kind: "snooze", title: "已触发", triggerAtEpochMs: 500, status: "fired"),
                CloudProactiveWakeupRecord(id: "wk_early", kind: "commitment", title: "早点", triggerAtEpochMs: 1000, status: "pending"),
            ]
        )
        #expect(CloudProactiveCenterPresentation.pendingWakeups(from: summaryForSort).map(\.id) == ["wk_early", "wk_late"])
    }
}
