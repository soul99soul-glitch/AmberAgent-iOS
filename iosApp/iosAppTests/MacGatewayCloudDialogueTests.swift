import Foundation
import SwiftUI
import Testing
import UIKit
@testable import iosApp

@Suite("Mac Gateway Cloud Dialogue v1")
struct MacGatewayCloudDialogueTests {

    @Test @MainActor func standaloneResultNormalizesEveryDisplayConsumerAndPersistence() throws {
        let suite = "SyntheticCloudDisplay.Ingest.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacGatewayStore(defaults: defaults)
        let connection = MacGatewayConnection(gatewayId: "synthetic-gateway", name: "Synthetic", addrs: ["example.invalid"],
                                              port: 443, fingerprint: "synthetic-fingerprint", deviceId: "synthetic-device")
        let client = MacGatewayClient(addrs: ["example.invalid"], port: 443, fingerprint: "synthetic-fingerprint",
                                      token: "synthetic-test-token", transport: { _, _ in throw URLError(.unsupportedURL) })
        store.configureForTesting(connection: connection, client: client)
        let raw = #"{"structured_summary":{"conclusion":"Synthetic cloud result"},"run_ended":true,"session_read":{"offset":0}}"#
        let result = MacGatewayCloudDialogueEvent(seq: 1, id: "synthetic-result", kind: .taskResult, role: "assistant",
                                                  text: raw, topicId: "synthetic-topic", workItemId: "synthetic-work",
                                                  outcome: .completed, soulRevision: nil)
        let page = MacGatewayCloudDialogueEventsPage(items: [result], nextCursor: 1, soulRevision: nil)
        store.ingestCloudDialogueEventsPage(page, requestedAfter: 0)
        #expect(store.cloudDialogueVisibleEvents.first?.text == "Synthetic cloud result")
        #expect(store.cloudDialogueProgressByWorkItem["synthetic-work"]?.statusLine == "Synthetic cloud result")
        #expect(store.cloudDialogueProgressByWorkItem["synthetic-work"]?.displaySingleLine.contains("run_ended") == false)
        #expect(store.cloudDialogueCursor == 1)
        store.persistCloudDialogueState()
        let data = try #require(defaults.data(forKey: MacGatewayStore.cloudDialogueStateKey))
        let saved = try JSONDecoder().decode(MacGatewayCloudDialoguePersistedEnvelope.self, from: data)
        #expect(saved.events.first?.text == "Synthetic cloud result")
        #expect(saved.progressByWorkItem["synthetic-work"]?.statusLine == "Synthetic cloud result")
        #expect(page.items[0].text == raw, "Normalization must not mutate the received transport page")
    }

    @Test @MainActor func persistedLegacyEnvelopesNormalizeWithoutResettingCursorOrReceipts() throws {
        let suite = "SyntheticCloudDisplay.Restore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = MacGatewayConnection(gatewayId: "synthetic-gateway", name: "Synthetic", addrs: ["example.invalid"],
                                              port: 443, fingerprint: "synthetic-fingerprint", deviceId: "synthetic-device")
        let raw = #"{"structured_summary":{"conclusion":"Synthetic restored result"},"run_ended":true,"session_read":{"offset":0}}"#
        let receipt = MacGatewayCloudDialogueReceipt(eventId: "synthetic-user", requestId: "synthetic-request",
                                                     topicId: "synthetic-topic", workItemIds: ["synthetic-work"],
                                                     state: .received, replayed: false, soulRevision: nil)
        let event = MacGatewayCloudDialogueEvent(seq: 11, id: "synthetic-old-result", kind: .taskResult, role: "assistant",
                                                 text: raw, topicId: "synthetic-topic", workItemId: "synthetic-work",
                                                 outcome: .completed, soulRevision: nil)
        let reply = MacGatewayCloudDialogueEvent(seq: 10, id: "synthetic-old-reply", kind: .assistantReply, role: "assistant",
                                                 text: raw, topicId: "synthetic-topic", workItemId: nil,
                                                 outcome: nil, soulRevision: nil)
        let progress = MacGatewayCloudDialogueWorkItemProgress(workItemId: "synthetic-work", topicId: "synthetic-topic",
                                                               statusLine: raw, processEventCount: 3, lastEventSeq: 11, outcome: .completed)
        let followup = MacGatewayCloudDialogueFollowupRecord(requestId: "synthetic-followup", eventId: nil,
                                                             workItemId: "synthetic-work", topicId: "synthetic-topic",
                                                             text: "Synthetic pending input", state: .received, lastError: nil)
        let old = MacGatewayCloudDialoguePersistedEnvelope(
            gatewayId: connection.gatewayId, deviceId: connection.deviceId, isCloudMainDialogueSelected: true,
            cursor: 11, events: [reply, event], receipts: [receipt.requestId: receipt], followups: [followup],
            progressByWorkItem: ["synthetic-work": progress], submissions: []
        )
        defaults.set(try JSONEncoder().encode(old), forKey: MacGatewayStore.cloudDialogueStateKey)
        let store = MacGatewayStore(defaults: defaults)
        let client = MacGatewayClient(addrs: ["example.invalid"], port: 443, fingerprint: "synthetic-fingerprint",
                                      token: "synthetic-test-token", transport: { _, _ in throw URLError(.unsupportedURL) })
        store.configureForTesting(connection: connection, client: client)
        #expect(store.cloudDialogueCursor == 11)
        #expect(store.isCloudMainDialogueSelected)
        #expect(store.cloudDialogueVisibleEvents.map(\.text) == ["Synthetic restored result", "Synthetic restored result"])
        #expect(store.cloudDialogueProgressByWorkItem["synthetic-work"]?.statusLine == "Synthetic restored result")
        #expect(store.cloudDialogueProgressByWorkItem["synthetic-work"]?.processEventCount == 3)
        #expect(store.cloudDialogueProgressByWorkItem["synthetic-work"]?.lastEventSeq == 11)
        #expect(store.cloudDialogueReceipts == old.receipts)
        #expect(store.cloudDialogueFollowups == old.followups)
        let migratedData = try #require(defaults.data(forKey: MacGatewayStore.cloudDialogueStateKey))
        let migrated = try JSONDecoder().decode(MacGatewayCloudDialoguePersistedEnvelope.self, from: migratedData)
        #expect(migrated.events.map(\.text) == ["Synthetic restored result", "Synthetic restored result"])
        #expect(migrated.progressByWorkItem["synthetic-work"]?.statusLine == "Synthetic restored result")
        #expect(migrated.cursor == 11)
        store.loadPersistedCloudDialogueState()
        #expect(store.cloudDialogueEvents == migrated.events, "Migration must be idempotent at a nonzero cursor")
    }

    @Test func inputAndStopRequestsEncodeStrictContractKeysAndValidate() throws {
        let msgReq = MacGatewayCloudDialogueInputRequest(
            requestId: "550e8400-e29b-41d4-a716-446655440000",
            text: "帮我检查今天的服务状态"
        )
        #expect(msgReq.validationError == nil)
        let msgData = try JSONEncoder().encode(msgReq)
        let msgObj = try #require(JSONSerialization.jsonObject(with: msgData) as? [String: Any])
        #expect(Set(msgObj.keys) == ["requestId", "text"])

        let stopReq = MacGatewayCloudDialogueStopRequest(
            requestId: "770e8400-e29b-41d4-a716-446655440002"
        )
        #expect(stopReq.validationError == nil)
        let stopData = try JSONEncoder().encode(stopReq)
        let stopObj = try #require(JSONSerialization.jsonObject(with: stopData) as? [String: Any])
        #expect(Set(stopObj.keys) == ["requestId"])

        #expect(MacGatewayCloudDialogueInputRequest(requestId: "bad id", text: "ok").validationError != nil)
        #expect(MacGatewayCloudDialogueInputRequest(requestId: "req-1", text: "   ").validationError != nil)
    }

    @Test @MainActor func cloudDialogueContractEndToEndFlowInPlaceProgressAndFollowupCancellation() async throws {
        let suiteName = "MacGatewayCloudDialogueTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        actor MockDialogueGateway {
            var seenRequests: [(method: String, path: String, query: String?, body: String?)] = []
            var phase = 0

            func setPhase(_ value: Int) {
                phase = value
            }

            func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
                let url = request.url!
                let method = request.httpMethod ?? "GET"
                let path = url.path
                let query = url.query
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
                seenRequests.append((method, path, query, body))

                func respond(_ status: Int, _ json: String) -> (Data, URLResponse) {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (Data(json.utf8), response)
                }

                switch (method, path) {
                case ("POST", "/v2/dialogue/messages"):
                    let count = seenRequests.filter { $0.path == "/v2/dialogue/messages" }.count
                    let replayed = count > 1
                    return respond(replayed ? 200 : 202, """
                    {"eventId":"evt-msg-1","requestId":"550e8400-e29b-41d4-a716-446655440000","topicId":"topic-1","workItemIds":["work:1"],"state":"received","replayed":\(replayed)}
                    """)

                case ("POST", "/v2/work-items/work:1/inputs"):
                    if let body, body.contains("660e8400-e29b-41d4-a716-446655440001") {
                        return respond(202, #"""
                        {"eventId":"evt-in-1","requestId":"660e8400-e29b-41d4-a716-446655440001","topicId":"topic-1","workItemIds":["work:1"],"state":"received","replayed":false}
                        """#)
                    }
                    if let body, body.contains("660e8400-e29b-41d4-a716-446655440002") {
                        return respond(202, #"""
                        {"eventId":"evt-in-2","requestId":"660e8400-e29b-41d4-a716-446655440002","topicId":"topic-1","workItemIds":["work:1"],"state":"received","replayed":false}
                        """#)
                    }
                    if phase >= 3 {
                        return respond(409, #"{"code":"task_terminal","error":"task_terminal"}"#)
                    }
                    return respond(409, #"{"code":"request_id_conflict","error":"request_id_conflict"}"#)

                case ("POST", "/v2/work-items/work:1/stop"):
                    return respond(200, #"""
                    {"eventId":"evt-stop-1","requestId":"770e8400-e29b-41d4-a716-446655440002","topicId":"topic-1","workItemIds":["work:1"],"state":"consumed","replayed":false}
                    """#)

                case ("GET", "/v2/dialogue/receipts/660e8400-e29b-41d4-a716-446655440001"):
                    return respond(200, #"""
                    {"eventId":"evt-in-1","requestId":"660e8400-e29b-41d4-a716-446655440001","topicId":"topic-1","workItemIds":["work:1"],"state":"consumed","replayed":true}
                    """#)

                case ("GET", "/v2/dialogue/receipts/660e8400-e29b-41d4-a716-446655440002"):
                    return respond(200, #"""
                    {"eventId":"evt-in-2","requestId":"660e8400-e29b-41d4-a716-446655440002","topicId":"topic-1","workItemIds":["work:1"],"state":"cancelled","replayed":true}
                    """#)

                case ("GET", "/v2/dialogue/events"):
                    if phase == 0 {
                        return respond(200, #"""
                        {
                          "items": [
                            {"seq":1,"id":"evt-msg-1","kind":"user_message","role":"user","text":"帮我检查今天的服务状态","topicId":"topic-1","workItemId":"work:1","outcome":null},
                            {"seq":2,"id":"evt-proc-1","kind":"process_event","role":"assistant","text":"正在连接服务节点…","topicId":"topic-1","workItemId":"work:1","outcome":null},
                            {"seq":3,"id":"evt-proc-2","kind":"process_event","role":"assistant","text":"正在采集 CPU 与磁盘指标…","topicId":"topic-1","workItemId":"work:1","outcome":null}
                          ],
                          "nextCursor": 3
                        }
                        """#)
                    } else if phase == 1 {
                        // Empty page must not advance cursor
                        return respond(200, #"{"items":[],"nextCursor":3}"#)
                    } else if phase == 2 {
                        return respond(200, #"""
                        {
                          "items": [
                            {"seq":4,"id":"evt-in-1","kind":"followup","role":"user","text":"补充：重点看磁盘空间","topicId":"topic-1","workItemId":"work:1","outcome":null},
                            {"seq":5,"id":"evt-consumed-1","kind":"input_consumed","role":"assistant","text":"补充：重点看磁盘空间","topicId":"topic-1","workItemId":"work:1","outcome":null},
                            {"seq":6,"id":"evt-proc-3","kind":"process_event","role":"assistant","text":"已根据补充聚焦磁盘空间…","topicId":"topic-1","workItemId":"work:1","outcome":null},
                            {"seq":7,"id":"evt-in-2","kind":"followup","role":"user","text":"再补充：顺便看归档日志","topicId":"topic-1","workItemId":"work:1","outcome":null}
                          ],
                          "nextCursor": 7
                        }
                        """#)
                    } else {
                        return respond(200, #"""
                        {
                          "items": [
                            {"seq":8,"id":"evt-stop-1","kind":"stop_requested","role":"user","text":"停止任务","topicId":"topic-1","workItemId":"work:1","outcome":"cancelled"},
                            {"seq":9,"id":"evt-cancel-2","kind":"input_cancelled","role":"assistant","text":"再补充：顺便看归档日志","topicId":"topic-1","workItemId":"work:1","outcome":"cancelled"},
                            {"seq":10,"id":"evt-res-1","kind":"task_result","role":"assistant","text":"任务已按请求停止","topicId":"topic-1","workItemId":"work:1","outcome":"cancelled"}
                          ],
                          "nextCursor": 10
                        }
                        """#)
                    }

                default:
                    return respond(404, #"{"error":"not found"}"#)
                }
            }
        }

        let server = MockDialogueGateway()
        let client = MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            token: "paired-token-dialogue",
            transport: { request, _ in
                try await server.handle(request)
            }
        )
        let connection = MacGatewayConnection(
            gatewayId: "gw-cloud",
            name: "Amber Cloud",
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            deviceId: "device-dialogue-1"
        )
        let store = MacGatewayStore(defaults: defaults)
        store.configureForTesting(connection: connection, client: client)

        // Default is false until user explicitly selects Paired Cloud Main Dialogue
        #expect(!store.isCloudMainDialogueSelected)
        store.setCloudMainDialogueSelected(true)
        store.stopCloudDialoguePolling()
        #expect(store.isCloudMainDialogueSelected)

        // 1. Send message + idempotent replay with same requestId
        let msgReqId = "550e8400-e29b-41d4-a716-446655440000"
        let firstMsg = try await store.sendCloudDialogueMessage(text: "帮我检查今天的服务状态", requestId: msgReqId).get()
        store.stopCloudDialoguePolling()
        #expect(firstMsg.workItemIds == ["work:1"])
        #expect(!firstMsg.replayed)

        let replayedMsg = try await store.sendCloudDialogueMessage(text: "帮我检查今天的服务状态", requestId: msgReqId).get()
        store.stopCloudDialoguePolling()
        #expect(replayedMsg.replayed)
        #expect(replayedMsg.eventId == "evt-msg-1")

        // 2. Poll events: 2 process_events collapse into 1 in-place progress entry for work:1
        _ = try await store.pollCloudDialogueEvents().get()
        #expect(store.cloudDialogueCursor == 3)
        let progress1 = try #require(store.cloudDialogueProgressByWorkItem["work:1"])
        #expect(progress1.statusLine == "正在采集 CPU 与磁盘指标…")
        #expect(progress1.processEventCount == 2)
        #expect(progress1.isLive)
        #expect(store.cloudDialogueVisibleEvents.count == 1, "process_events must not be rendered as separate cards/rows")

        // 3. Empty page does not advance cursor
        await server.setPhase(1)
        _ = try await store.pollCloudDialogueEvents().get()
        #expect(store.cloudDialogueCursor == 3)

        // 4. Send two follow-up inputs to work:1; first is consumed at reasoning boundary, second remains received before stop
        let in1 = try await store.sendCloudWorkItemInput(
            workItemId: "work:1",
            text: "补充：重点看磁盘空间",
            requestId: "660e8400-e29b-41d4-a716-446655440001"
        ).get()
        store.stopCloudDialoguePolling()
        #expect(in1.state == .received)
        #expect(store.cloudDialogueFollowups.first(where: { $0.requestId == "660e8400-e29b-41d4-a716-446655440001" })?.isShownAsExecuted == false)

        _ = try await store.sendCloudWorkItemInput(
            workItemId: "work:1",
            text: "再补充：顺便看归档日志",
            requestId: "660e8400-e29b-41d4-a716-446655440002"
        ).get()
        store.stopCloudDialoguePolling()

        await server.setPhase(2)
        _ = try await store.pollCloudDialogueEvents().get()
        #expect(store.cloudDialogueCursor == 7)

        let followup1AfterReasoning = try #require(store.cloudDialogueFollowups.first(where: { $0.requestId == "660e8400-e29b-41d4-a716-446655440001" }))
        #expect(followup1AfterReasoning.state == .consumed)
        #expect(followup1AfterReasoning.isShownAsExecuted == true)

        let followup2BeforeStop = try #require(store.cloudDialogueFollowups.first(where: { $0.requestId == "660e8400-e29b-41d4-a716-446655440002" }))
        #expect(followup2BeforeStop.state == .received)
        #expect(followup2BeforeStop.isShownAsExecuted == false)

        // 5. Stop work:1 before followup2 is consumed -> followup2 is marked cancelled and NEVER shown as executed
        let stopReceipt = try await store.stopCloudWorkItem(
            workItemId: "work:1",
            requestId: "770e8400-e29b-41d4-a716-446655440002"
        ).get()
        store.stopCloudDialoguePolling()
        #expect(stopReceipt.state == .consumed)
        #expect(store.cloudDialogueProgressByWorkItem["work:1"]?.displaySingleLine == "已请求停止")
        #expect(store.cloudDialogueProgressByWorkItem["work:1"]?.outcome == nil)

        let followup2AfterStop = try #require(store.cloudDialogueFollowups.first(where: { $0.requestId == "660e8400-e29b-41d4-a716-446655440002" }))
        #expect(followup2AfterStop.state == .cancelled)
        #expect(followup2AfterStop.isShownAsExecuted == false)
        #expect(followup2AfterStop.state.displayBadgeText == "已取消（未执行）")

        // Verify GET /v2/dialogue/receipts/{requestId} also confirms consumed vs cancelled
        let queried1 = try await store.refreshCloudDialogueReceipt(requestId: "660e8400-e29b-41d4-a716-446655440001").get()
        #expect(queried1.state == .consumed)
        let queried2 = try await store.refreshCloudDialogueReceipt(requestId: "660e8400-e29b-41d4-a716-446655440002").get()
        #expect(queried2.state == .cancelled)

        await server.setPhase(3)
        _ = try await store.pollCloudDialogueEvents().get()
        #expect(store.cloudDialogueCursor == 10)
        #expect(store.cloudDialogueProgressByWorkItem["work:1"]?.outcome == .cancelled)
        #expect(store.cloudDialogueProgressByWorkItem["work:1"]?.isLive == false)

        // Sending a new follow-up to a terminal task surfaces 409 task_terminal
        let terminalInputResult = await store.sendCloudWorkItemInput(
            workItemId: "work:1",
            text: "终态后补充",
            requestId: "880e8400-e29b-41d4-a716-446655440009"
        )
        if case .failure(let error) = terminalInputResult {
            #expect(error as? MacGatewayError == .conflict("task_terminal"))
        } else {
            Issue.record("Expected 409 task_terminal conflict")
        }
    }

    @Test @MainActor func cloudDialogueSessionHealthAndMainTurnPendingReplyLifecycle() async throws {
        let suiteName = "MacGatewayCloudDialogueTests.Health.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        actor HealthGateway {
            enum Mode {
                case legacyGatewayNoV2Dialogue
                case cloudDaemonMissingKey
                case cloudDaemonReadyBeforeReply
                case cloudDaemonReadyAfterReply
            }

            var mode: Mode = .legacyGatewayNoV2Dialogue

            func setMode(_ newMode: Mode) {
                mode = newMode
            }

            func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
                let url = request.url!
                let method = request.httpMethod ?? "GET"
                let path = url.path

                func respond(_ status: Int, _ json: String) -> (Data, URLResponse) {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (Data(json.utf8), response)
                }

                switch (method, path) {
                case ("GET", "/v1/status"):
                    return respond(200, #"""
                    {"gatewayId":"gw-cloud","hostname":"Amber-Mac","osVersion":"macOS","cpuLoad":0.1,"memUsedBytes":1024,"memTotalBytes":2048,"diskFreeBytes":4096,"uptimeSeconds":100,"activeTasks":0,"scheduledCount":0}
                    """#)
                case ("GET", "/v2/configuration"):
                    switch mode {
                    case .legacyGatewayNoV2Dialogue:
                        return respond(404, #"{"error":"not found"}"#)
                    case .cloudDaemonMissingKey:
                        return respond(200, #"""
                        {"gatewayId":"gw-cloud","revision":1,"model":{"provider":"openai","modelId":"gpt-5.4","baseUrl":"https://api.openai.com/v1"},"search":{"sources":["duckduckgo"],"mode":"fallback"},"credentials":{"modelApiKey":{"configured":false},"exaApiKey":{"configured":false},"braveApiKey":{"configured":false}},"supportedModelProviders":["openai","claude"],"supportedSearchSources":["duckduckgo","bing","exa","brave"]}
                        """#)
                    case .cloudDaemonReadyBeforeReply, .cloudDaemonReadyAfterReply:
                        return respond(200, #"""
                        {"gatewayId":"gw-cloud","revision":2,"model":{"provider":"openai","modelId":"gpt-5.4","baseUrl":"https://api.openai.com/v1"},"search":{"sources":["duckduckgo"],"mode":"fallback"},"credentials":{"modelApiKey":{"configured":true},"exaApiKey":{"configured":false},"braveApiKey":{"configured":false}},"supportedModelProviders":["openai","claude"],"supportedSearchSources":["duckduckgo","bing","exa","brave"]}
                        """#)
                    }
                case ("POST", "/v2/dialogue/messages"):
                    return respond(202, #"""
                    {"eventId":"evt-user-1","requestId":"990e8400-e29b-41d4-a716-446655440000","topicId":"topic-main","workItemIds":[],"state":"received","replayed":false}
                    """#)
                case ("GET", "/v2/dialogue/events"):
                    switch mode {
                    case .legacyGatewayNoV2Dialogue:
                        return respond(404, #"{"error":"not found"}"#)
                    case .cloudDaemonMissingKey:
                        return respond(200, #"{"items":[],"nextCursor":0}"#)
                    case .cloudDaemonReadyBeforeReply:
                        return respond(200, #"""
                        {"items":[{"seq":1,"id":"evt-user-1","kind":"user_message","role":"user","text":"你好，云端在吗？","topicId":"topic-main","workItemId":null,"outcome":null}],"nextCursor":1}
                        """#)
                    case .cloudDaemonReadyAfterReply:
                        return respond(200, #"""
                        {"items":[{"seq":2,"id":"evt-reply-1","kind":"assistant_reply","role":"assistant","text":"我在，云端对话已就绪。","topicId":"topic-main","workItemId":null,"outcome":null}],"nextCursor":2}
                        """#)
                    }
                default:
                    return respond(404, #"{"error":"not found"}"#)
                }
            }
        }

        let server = HealthGateway()
        let client = MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            token: "paired-token-health",
            transport: { request, _ in
                try await server.handle(request)
            }
        )
        let connection = MacGatewayConnection(
            gatewayId: "gw-cloud",
            name: "Amber Cloud",
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            deviceId: "device-health-1"
        )
        let store = MacGatewayStore(defaults: defaults)
        store.configureForTesting(connection: connection, client: client)

        // Before first refresh, health is .checking (never falsely .ready)
        #expect(store.cloudDialogueSessionHealth == .checking)

        // 1. When /v1/status is 200 OK but /v2/dialogue/events returns 404 (legacy amber-gateway),
        // health must report .unavailable instead of claiming online!
        _ = await store.pollCloudDialogueEvents()
        if case .unavailable(let reason) = store.cloudDialogueSessionHealth {
            #expect(reason.contains("/v2/dialogue"))
        } else {
            Issue.record("Expected .unavailable when /v2/dialogue/events returns 404")
        }

        // 2. When /v2/dialogue/events succeeds but cloudConfig has keyConfigured == false,
        // health must report .actionRequired
        await server.setMode(.cloudDaemonMissingKey)
        await store.refreshCloudConfig()
        _ = await store.pollCloudDialogueEvents()
        if case .actionRequired(let reason) = store.cloudDialogueSessionHealth {
            #expect(reason.contains("API Key"))
        } else {
            Issue.record("Expected .actionRequired when model API Key is not configured")
        }

        // 3. When model key is configured and /v2/dialogue/events is healthy, health becomes .ready
        await server.setMode(.cloudDaemonReadyBeforeReply)
        await store.refreshCloudConfig()
        _ = try await store.sendCloudDialogueMessage(
            text: "你好，云端在吗？",
            requestId: "990e8400-e29b-41d4-a716-446655440000"
        ).get()
        store.stopCloudDialoguePolling()
        #expect(store.cloudDialogueSessionHealth.isReady)
        // Before poll returns evt-user-1, unmerged submission is tracked and awaiting reply is true
        #expect(store.isAwaitingCloudMainReply)

        // Poll phase 1: user_message arrives, submission merges into visible events, still awaiting assistant reply
        _ = try await store.pollCloudDialogueEvents().get()
        #expect(store.unmergedCloudMainSubmissions.isEmpty)
        #expect(store.isAwaitingCloudMainReply)

        // Poll phase 2: assistant_reply arrives, awaiting reply clears and receipt transitions to .consumed
        await server.setMode(.cloudDaemonReadyAfterReply)
        _ = try await store.pollCloudDialogueEvents().get()
        #expect(!store.isAwaitingCloudMainReply)
        let savedSubmission = try #require(store.cloudDialogueSubmissions.first { $0.requestId == "990e8400-e29b-41d4-a716-446655440000" })
        #expect(savedSubmission.receipt?.state == .consumed)
    }

    @Test @MainActor func cloudSessionHealthAndReplyStateReflectGatewayState() throws {
        let suiteName = "MacGatewayCloudDialogueTests.health.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MacGatewayStore(defaults: defaults)
        #expect(store.cloudSessionHealth == .unpaired)

        let connection = MacGatewayConnection(
            gatewayId: "gw-health",
            name: "Amber Cloud",
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            deviceId: "device-health-1"
        )
        let client = MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            token: "paired-token-health",
            transport: { request, _ in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data(#"{"items":[],"nextCursor":0}"#.utf8), response)
            }
        )
        store.configureForTesting(connection: connection, client: client)

        // Paired but reachability not yet checked -> checking
        store.isReachable = nil
        #expect(store.cloudSessionHealth == .checking)

        // Reachable with configured cloud model -> healthy
        store.isReachable = true
        store.cloudConfig = IOSCloudConfigSnapshot(
            gatewayId: "gw-health",
            revision: 1,
            model: IOSCloudConfigSnapshot.Model(
                provider: "openai",
                modelId: "gpt-5",
                baseUrl: "https://api.openai.com/v1",
                keyConfigured: true
            ),
            search: [],
            searchSources: [],
            searchMode: "fallback",
            supportedModelProviders: ["openai", "claude"],
            supportedSearchSources: ["bing", "duckduckgo", "exa", "brave"]
        )
        #expect(store.cloudSessionHealth == .healthy)
        #expect(store.cloudSessionHealth.badgeText == "在线")

        // Missing active model -> modelUnconfigured
        store.cloudConfig?.model = nil
        if case .modelUnconfigured = store.cloudSessionHealth {
            #expect(store.cloudSessionHealth.badgeText == "待配置模型")
        } else {
            Issue.record("Expected modelUnconfigured state when model is nil")
        }

        // Reply state diagnostics for unanswered vs stalled vs answered user_message
        let userEvent = MacGatewayCloudDialogueEvent(
            seq: 1,
            id: "evt-u1",
            kind: .userMessage,
            role: "user",
            text: "你好",
            topicId: "t1",
            workItemId: "work:u1",
            outcome: nil
        )
        store.cloudDialogueEvents = [userEvent]
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        store.cloudDialogueFirstSeenAtByEventId["evt-u1"] = t0

        // Unconfigured model immediately surfaces stalled diagnostic
        if case .stalled(let reason) = store.cloudDialogueReplyState(for: userEvent, now: t0.addingTimeInterval(2)) {
            #expect(reason.contains("尚未配置对话模型"))
        } else {
            Issue.record("Expected stalled state when cloud model is unconfigured")
        }

        // Restore healthy model -> within 18s shows waiting, after 18s shows stalled
        store.cloudConfig?.model = IOSCloudConfigSnapshot.Model(
            provider: "openai",
            modelId: "gpt-5",
            baseUrl: "https://api.openai.com/v1",
            keyConfigured: true
        )
        #expect(store.cloudDialogueReplyState(for: userEvent, now: t0.addingTimeInterval(3)) == .waiting)

        if case .stalled(let timeoutMsg) = store.cloudDialogueReplyState(for: userEvent, now: t0.addingTimeInterval(20)) {
            #expect(timeoutMsg.contains("响应超时"))
        } else {
            Issue.record("Expected stalled state after 18s without process_event or reply")
        }

        // Adding assistant reply marks userEvent as answered
        let replyEvent = MacGatewayCloudDialogueEvent(
            seq: 2,
            id: "evt-a1",
            kind: .assistantReply,
            role: "assistant",
            text: "收到，一切正常。",
            topicId: "t1",
            workItemId: "work:u1",
            outcome: .completed
        )
        store.cloudDialogueEvents = [userEvent, replyEvent]
        #expect(store.cloudDialogueReplyState(for: userEvent, now: t0.addingTimeInterval(25)) == .answered)
    }

    @Test @MainActor func persistsSendIntentBeforeReceiptAndRecoversOnColdStartViaReceiptOrResend() async throws {
        let suiteName = "MacGatewayCloudDialogueTests.Recovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        actor RecoveryGateway {
            var serverAcceptedMessageIds: Set<String> = []
            var postMessageAttemptsByRequestId: [String: Int] = [:]
            var receiptQueriesByRequestId: [String: Int] = [:]
            var hangPostForRequestIds: Set<String> = []

            func configure(hangRequestIds: Set<String>, preAcceptedRequestIds: Set<String>) {
                hangPostForRequestIds = hangRequestIds
                serverAcceptedMessageIds = preAcceptedRequestIds
            }

            func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
                let url = request.url!
                let method = request.httpMethod ?? "GET"
                let path = url.path
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""

                func respond(_ status: Int, _ json: String) -> (Data, URLResponse) {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (Data(json.utf8), response)
                }

                switch (method, path) {
                case ("POST", "/v2/dialogue/messages"):
                    let reqId = body.contains("00000000-0000-4000-8000-000000000301")
                        ? "00000000-0000-4000-8000-000000000301"
                        : "00000000-0000-4000-8000-000000000302"
                    postMessageAttemptsByRequestId[reqId, default: 0] += 1
                    if hangPostForRequestIds.remove(reqId) != nil {
                        try await Task.sleep(for: .seconds(30))
                    }
                    let alreadyAccepted = !serverAcceptedMessageIds.insert(reqId).inserted
                    if reqId == "00000000-0000-4000-8000-000000000301" {
                        return respond(alreadyAccepted ? 200 : 202, #"""
                        {"eventId":"evt-claim-301","requestId":"00000000-0000-4000-8000-000000000301","topicId":"topic-301","workItemIds":["work:301"],"state":"received","replayed":\#(alreadyAccepted)}
                        """#)
                    } else {
                        return respond(alreadyAccepted ? 200 : 202, #"""
                        {"eventId":"evt-resend-302","requestId":"00000000-0000-4000-8000-000000000302","topicId":"topic-302","workItemIds":["work:302"],"state":"received","replayed":\#(alreadyAccepted)}
                        """#)
                    }

                case ("GET", "/v2/dialogue/receipts/00000000-0000-4000-8000-000000000301"):
                    receiptQueriesByRequestId["00000000-0000-4000-8000-000000000301", default: 0] += 1
                    return respond(200, #"""
                    {"eventId":"evt-claim-301","requestId":"00000000-0000-4000-8000-000000000301","topicId":"topic-301","workItemIds":["work:301"],"state":"consumed","replayed":true}
                    """#)

                case ("GET", "/v2/dialogue/receipts/00000000-0000-4000-8000-000000000302"):
                    receiptQueriesByRequestId["00000000-0000-4000-8000-000000000302", default: 0] += 1
                    if serverAcceptedMessageIds.contains("00000000-0000-4000-8000-000000000302") {
                        return respond(200, #"""
                        {"eventId":"evt-resend-302","requestId":"00000000-0000-4000-8000-000000000302","topicId":"topic-302","workItemIds":["work:302"],"state":"received","replayed":true}
                        """#)
                    }
                    return respond(404, #"{"error":"receipt_not_found"}"#)

                case ("GET", "/v2/dialogue/events"):
                    var items: [String] = [
                        #"{"seq":1,"id":"evt-claim-301","kind":"user_message","role":"user","text":"合成消息：服务端已受理但回执未达","topicId":"topic-301","workItemId":"work:301","outcome":null}"#,
                        #"{"seq":2,"id":"evt-res-301","kind":"task_result","role":"assistant","text":"合成结果：任务 301 已完成","topicId":"topic-301","workItemId":"work:301","outcome":"completed"}"#
                    ]
                    var nextCursor = 2
                    if serverAcceptedMessageIds.contains("00000000-0000-4000-8000-000000000302") {
                        items.append(#"{"seq":3,"id":"evt-resend-302","kind":"user_message","role":"user","text":"合成消息：服务端未受理需补发","topicId":"topic-302","workItemId":"work:302","outcome":null}"#)
                        items.append(#"{"seq":4,"id":"evt-res-302","kind":"task_result","role":"assistant","text":"合成结果：任务 302 已完成","topicId":"topic-302","workItemId":"work:302","outcome":"completed"}"#)
                        nextCursor = 4
                    }
                    return respond(200, """
                    {"items":[\(items.joined(separator: ","))],"nextCursor":\(nextCursor)}
                    """)

                default:
                    return respond(404, #"{"error":"not found"}"#)
                }
            }
        }

        let reqAcceptedId = "00000000-0000-4000-8000-000000000301"
        let reqUnacceptedId = "00000000-0000-4000-8000-000000000302"
        let server = RecoveryGateway()
        await server.configure(
            hangRequestIds: [reqAcceptedId, reqUnacceptedId],
            preAcceptedRequestIds: [reqAcceptedId]
        )

        let connection = MacGatewayConnection(
            gatewayId: "gw-recovery",
            name: "Amber Cloud",
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            deviceId: "device-recovery-1"
        )
        let client1 = MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            token: "paired-token-recovery",
            transport: { request, _ in try await server.handle(request) }
        )
        let storeBeforeExit = MacGatewayStore(defaults: defaults)
        storeBeforeExit.configureForTesting(connection: connection, client: client1)

        // Start two sends whose responses do not return before the app exits.
        let inFlightAccepted = Task { @MainActor in
            await storeBeforeExit.sendCloudDialogueMessage(
                text: "合成消息：服务端已受理但回执未达",
                requestId: reqAcceptedId
            )
        }
        let inFlightUnaccepted = Task { @MainActor in
            await storeBeforeExit.sendCloudDialogueMessage(
                text: "合成消息：服务端未受理需补发",
                requestId: reqUnacceptedId
            )
        }
        for _ in 0..<50 {
            let count = await server.postMessageAttemptsByRequestId.count
            if count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        // Verify send intent was persisted to disk BEFORE the POST response returned.
        let persistedBeforeReceiptData = try #require(defaults.data(forKey: MacGatewayStore.cloudDialogueStateKey))
        let persistedBeforeReceipt = try JSONDecoder().decode(MacGatewayCloudDialoguePersistedEnvelope.self, from: persistedBeforeReceiptData)
        #expect(Set(persistedBeforeReceipt.submissions.map(\.requestId)) == [reqAcceptedId, reqUnacceptedId])
        #expect(persistedBeforeReceipt.submissions.allSatisfy { $0.receipt == nil })

        // Simulate app exit before receipt arrives.
        inFlightAccepted.cancel()
        inFlightUnaccepted.cancel()
        storeBeforeExit.stopCloudDialoguePolling()

        // Cold-start a fresh MacGatewayStore with the same UserDefaults and connection.
        let client2 = MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            token: "paired-token-recovery",
            transport: { request, _ in try await server.handle(request) }
        )
        let storeAfterRelaunch = MacGatewayStore(defaults: defaults)
        storeAfterRelaunch.configureForTesting(connection: connection, client: client2)
        defer { storeAfterRelaunch.stopCloudDialoguePolling() }

        _ = try await storeAfterRelaunch.pollCloudDialogueEvents().get()
        storeAfterRelaunch.stopCloudDialoguePolling()

        // 1. reqAcceptedId was claimed via GET /v2/dialogue/receipts/{requestId} without re-POSTing.
        #expect(await server.receiptQueriesByRequestId[reqAcceptedId] == 1)
        #expect(await server.postMessageAttemptsByRequestId[reqAcceptedId] == 1)

        // 2. reqUnacceptedId got 404 receipt_not_found and was re-sent with the same requestId and text.
        #expect(await server.receiptQueriesByRequestId[reqUnacceptedId] == 1)
        #expect(await server.postMessageAttemptsByRequestId[reqUnacceptedId] == 2)

        // 3. Both local bubbles merged with server events (no duplicate unmerged bubbles left).
        #expect(storeAfterRelaunch.unmergedCloudMainSubmissions.isEmpty)
        let visibleUserTexts = storeAfterRelaunch.cloudDialogueVisibleEvents.filter { $0.kind == .userMessage }.map(\.text)
        #expect(visibleUserTexts == ["合成消息：服务端已受理但回执未达", "合成消息：服务端未受理需补发"])
        #expect(storeAfterRelaunch.cloudDialogueProgressByWorkItem["work:301"]?.outcome == .completed)
        #expect(storeAfterRelaunch.cloudDialogueProgressByWorkItem["work:302"]?.outcome == .completed)
    }

    @Test @MainActor func stopRequestShowsIntermediateStateAndPreservesCompletedSettlementInRaceAndDuplicatePages() throws {
        let suiteName = "MacGatewayCloudDialogueTests.StopRace.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MacGatewayStore(defaults: defaults)
        let connection = MacGatewayConnection(
            gatewayId: "gw-race",
            name: "Amber Cloud",
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            deviceId: "device-race-1"
        )
        let client = MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            token: "paired-token-race",
            transport: { _, _ in throw URLError(.unsupportedURL) }
        )
        store.configureForTesting(connection: connection, client: client)

        // Step 1: Ingest two process events and a stop_requested event (before task_result).
        let page1 = MacGatewayCloudDialogueEventsPage(
            items: [
                MacGatewayCloudDialogueEvent(
                    seq: 1, id: "evt-p1", kind: .processEvent, role: "assistant",
                    text: "正在执行步骤 1…", topicId: "topic-race", workItemId: "work:race",
                    outcome: nil, soulRevision: nil
                ),
                MacGatewayCloudDialogueEvent(
                    seq: 2, id: "evt-p2", kind: .processEvent, role: "assistant",
                    text: "正在执行步骤 2…", topicId: "topic-race", workItemId: "work:race",
                    outcome: nil, soulRevision: nil
                ),
                MacGatewayCloudDialogueEvent(
                    seq: 3, id: "evt-stop-req", kind: .stopRequested, role: "user",
                    text: "停止任务", topicId: "topic-race", workItemId: "work:race",
                    outcome: nil, soulRevision: nil
                )
            ],
            nextCursor: 3,
            soulRevision: nil
        )
        store.ingestCloudDialogueEventsPage(page1, requestedAfter: 0)

        let stoppingProgress = try #require(store.cloudDialogueProgressByWorkItem["work:race"])
        #expect(stoppingProgress.displaySingleLine == "已请求停止")
        #expect(stoppingProgress.outcome == nil, "stop_requested alone must show intermediate '已请求停止' rather than final outcome")
        #expect(stoppingProgress.processEventCount == 2)

        // Re-ingesting the live page before settlement must not double-count processEventCount.
        store.ingestCloudDialogueEventsPage(page1, requestedAfter: 0)
        #expect(store.cloudDialogueProgressByWorkItem["work:race"]?.processEventCount == 2)

        // Step 2: Executor finishes with completed task_result interleaved with stop_requested.
        let page2 = MacGatewayCloudDialogueEventsPage(
            items: [
                MacGatewayCloudDialogueEvent(
                    seq: 4, id: "evt-res-complete", kind: .taskResult, role: "assistant",
                    text: "合成结果：已在停止生效前完成汇总", topicId: "topic-race", workItemId: "work:race",
                    outcome: .completed, soulRevision: nil
                ),
                MacGatewayCloudDialogueEvent(
                    seq: 5, id: "evt-stop-late", kind: .stopRequested, role: "user",
                    text: "停止任务", topicId: "topic-race", workItemId: "work:race",
                    outcome: .cancelled, soulRevision: nil
                )
            ],
            nextCursor: 5,
            soulRevision: nil
        )
        store.ingestCloudDialogueEventsPage(page2, requestedAfter: 3)

        let settledProgress = try #require(store.cloudDialogueProgressByWorkItem["work:race"])
        #expect(settledProgress.outcome == .completed, "Authoritative completed task_result must not be overwritten by stop_requested")
        #expect(settledProgress.displaySingleLine == "已完成 · 合成结果：已在停止生效前完成汇总")
        #expect(settledProgress.processEventCount == 2)

        // Step 3: Re-ingesting duplicate / overlapping pages must keep settlement and processEventCount identical.
        let duplicatePage = MacGatewayCloudDialogueEventsPage(
            items: page1.items + page2.items,
            nextCursor: 5,
            soulRevision: nil
        )
        store.ingestCloudDialogueEventsPage(duplicatePage, requestedAfter: 0)

        let afterDuplicate = try #require(store.cloudDialogueProgressByWorkItem["work:race"])
        #expect(afterDuplicate.outcome == .completed)
        #expect(afterDuplicate.processEventCount == 2, "Duplicate event pages must not double-count process_event items")
        #expect(afterDuplicate.displaySingleLine == "已完成 · 合成结果：已在停止生效前完成汇总")
        #expect(store.cloudDialogueCursor == 5)

        // Step 4: Late page containing an unseen earlier historical event preserves historical order without re-applying seen events.
        let lateHistoricalEvent = MacGatewayCloudDialogueEvent(
            seq: 1, id: "evt-user-origin", kind: .userMessage, role: "user",
            text: "合成起源消息", topicId: "topic-race", workItemId: "work:race",
            outcome: nil, soulRevision: nil
        )
        store.ingestCloudDialogueEventsPage(
            MacGatewayCloudDialogueEventsPage(items: [lateHistoricalEvent] + page2.items, nextCursor: 5, soulRevision: nil),
            requestedAfter: 5
        )
        #expect(store.cloudDialogueVisibleEvents.first?.id == "evt-user-origin")
        #expect(store.cloudDialogueProgressByWorkItem["work:race"]?.processEventCount == 2)
        #expect(store.cloudDialogueCursor == 5)
    }

    @Test @MainActor func staleClient401AndOrdinaryErrorsNeverUnpairOrPolluteReplacementConnection() async throws {
        let suiteName = "MacGatewayCloudDialogueTests.P107.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        actor Gate {
            private var continuations: [CheckedContinuation<Void, Never>] = []
            private(set) var arrivedCount = 0

            func waitForRelease() async {
                arrivedCount += 1
                await withCheckedContinuation { cont in
                    continuations.append(cont)
                }
            }

            func releaseAll() {
                let pending = continuations
                continuations.removeAll()
                for cont in pending {
                    cont.resume()
                }
            }
        }

        let gate = Gate()
        let oldConnection = MacGatewayConnection(
            gatewayId: "gw-old", name: "Old Cloud", addrs: ["old.example"],
            port: 443, fingerprint: "fp-old", deviceId: "device-old"
        )
        let oldClient = MacGatewayClient(
            addrs: ["old.example"], port: 443, fingerprint: "fp-old", token: "old-token",
            transport: { request, _ in
                await gate.waitForRelease()
                let url = request.url!
                if url.path.contains("/v2/dialogue/messages") {
                    let resp = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
                    return (Data(#"{"error":"unauthorized"}"#.utf8), resp)
                }
                throw URLError(.cannotConnectToHost)
            }
        )

        let newConnection = MacGatewayConnection(
            gatewayId: "gw-new", name: "New Cloud", addrs: ["new.example"],
            port: 443, fingerprint: "fp-new", deviceId: "device-new"
        )
        let newClient = MacGatewayClient(
            addrs: ["new.example"], port: 443, fingerprint: "fp-new", token: "new-token",
            transport: { request, _ in
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(#"{"items":[],"nextCursor":0}"#.utf8), resp)
            }
        )

        let store = MacGatewayStore(defaults: defaults)
        store.configureForTesting(connection: oldConnection, client: oldClient)

        // Launch in-flight requests on oldClient that will later fail with 401 and unreachable.
        let staleSendTask = Task { @MainActor in
            await store.sendCloudDialogueMessage(
                text: "旧连接在途消息",
                requestId: "00000000-0000-4000-8000-000000000701"
            )
        }
        let stalePollTask = Task { @MainActor in
            await store.pollCloudDialogueEvents()
        }
        for _ in 0..<50 {
            if await gate.arrivedCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        // Switch pairing to newConnection + newClient before old requests fail.
        store.configureForTesting(connection: newConnection, client: newClient)
        store.isReachable = true
        store.cloudDialogueTransportState = .healthy
        store.notice = nil

        // Now let oldClient's 401 and unreachable errors land.
        await gate.releaseAll()
        _ = await staleSendTask.value
        _ = await stalePollTask.value

        #expect(store.connection == newConnection, "Late 401 from old client must not unpair the new connection")
        #expect(store.client === newClient)
        #expect(store.isReachable == true, "Late unreachable from old client must not mark new connection offline")
        #expect(store.cloudDialogueTransportState == .healthy, "Late error from old client must not pollute new transport state")
        #expect(store.notice == nil, "Late 401 from old client must not post a revoked notice on the new connection")
        #expect(store.cloudDialogueSubmissions.allSatisfy { $0.gatewayId == newConnection.gatewayId })
    }

    @Test @MainActor func editingDraftOrChangingTargetDuringCloudSendPreservesNewDraftAndTargetAndIgnoresStaleFailure() throws {
        var composerState = ChatComposerLocalState()
        var currentInputText = "初始消息 A"
        var selectedWorkItemId: String? = "work:1"

        // 1. Start send #1 for ("初始消息 A", "work:1")
        let send1 = composerState.beginCloudDialogueSubmit(
            text: currentInputText,
            targetWorkItemId: selectedWorkItemId
        )
        #expect(composerState.isSubmittingCloudDialogue)

        // While send #1 is awaiting response, user edits draft and switches target to "work:2".
        currentInputText = "等待期间新编辑的草稿 B"
        selectedWorkItemId = "work:2"

        let receipt1 = MacGatewayCloudDialogueReceipt(
            eventId: "evt-1", requestId: send1.requestId, topicId: "topic-1",
            workItemIds: ["work:1"], state: .received, replayed: false, soulRevision: nil
        )
        composerState.finishCloudDialogueSubmit(
            generation: send1.generation,
            submittedText: "初始消息 A",
            submittedTargetWorkItemId: "work:1",
            submittedFingerprint: send1.fingerprint,
            currentInputText: &currentInputText,
            selectedWorkItemId: &selectedWorkItemId,
            result: .success(receipt1)
        )

        #expect(currentInputText == "等待期间新编辑的草稿 B", "Old send success receipt must not clear a newly edited draft")
        #expect(selectedWorkItemId == "work:2", "Old send success receipt must not clear a newly selected target WorkItem")
        #expect(!composerState.isSubmittingCloudDialogue)

        // 2. Start send #2 for ("等待期间新编辑的草稿 B", "work:2"), then user edits draft and starts send #3 before send #2 fails.
        let send2 = composerState.beginCloudDialogueSubmit(
            text: currentInputText,
            targetWorkItemId: selectedWorkItemId
        )
        currentInputText = "再次修改后的草稿 C"
        selectedWorkItemId = nil
        let send3 = composerState.beginCloudDialogueSubmit(
            text: currentInputText,
            targetWorkItemId: selectedWorkItemId
        )
        #expect(send3.requestId != send2.requestId)

        // Stale send #2 fails late: must not clear isSubmittingCloudDialogue for send #3 or pollute cloudDialogueErrorMessage.
        composerState.finishCloudDialogueSubmit(
            generation: send2.generation,
            submittedText: "等待期间新编辑的草稿 B",
            submittedTargetWorkItemId: "work:2",
            submittedFingerprint: send2.fingerprint,
            currentInputText: &currentInputText,
            selectedWorkItemId: &selectedWorkItemId,
            result: .failure(MacGatewayError.server("旧请求超时"))
        )
        #expect(composerState.isSubmittingCloudDialogue, "Stale failure must not clear in-flight state of a newer submission")
        #expect(composerState.cloudDialogueErrorMessage == nil, "Stale failure must not attach an error banner to a newer draft/submission")
        #expect(currentInputText == "再次修改后的草稿 C")
    }

    @Test @MainActor func cloudMainDialogueMountsWaveDotsAndSingleLineStatusShimmerAtConversationTail() async throws {
        let suiteName = "MacGatewayCloudDialogueTests.StatusMotion.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MacGatewayStore(defaults: defaults)
        let connection = MacGatewayConnection(
            gatewayId: "gw-motion",
            name: "Amber Cloud",
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp-motion",
            deviceId: "device-motion"
        )
        let client = MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp-motion",
            token: "token-motion",
            transport: { request, _ in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(#"{"items":[],"nextCursor":10}"#.utf8), response)
            }
        )
        store.configureForTesting(connection: connection, client: client)
        store.isCloudMainDialogueSelected = true
        store.cloudDialogueTransportState = .healthy
        store.isReachable = true

        // Seed synthetic multi-turn history so the scroll view is taller than one viewport,
        // plus a completed historical WorkItem and a new turn with a persona waiting acknowledgement.
        var initialEvents: [MacGatewayCloudDialogueEvent] = []
        for turn in 1...4 {
            initialEvents.append(
                MacGatewayCloudDialogueEvent(
                    seq: Int64(turn * 2 - 1),
                    id: "evt-hist-u-\(turn)",
                    kind: .userMessage,
                    role: "user",
                    text: "合成历史提问 \(turn)：请梳理模块架构与关键路径。",
                    topicId: "topic-hist-\(turn)",
                    workItemId: "work:hist-\(turn)",
                    outcome: nil
                )
            )
            initialEvents.append(
                MacGatewayCloudDialogueEvent(
                    seq: Int64(turn * 2),
                    id: "evt-hist-a-\(turn)",
                    kind: .taskResult,
                    role: "assistant",
                    text: "合成历史回答 \(turn)：已完成第一阶段与第二阶段的链路核对，各项指标平稳运行，无异常阻断。",
                    topicId: "topic-hist-\(turn)",
                    workItemId: "work:hist-\(turn)",
                    outcome: .completed
                )
            )
        }
        let activeUserEvent = MacGatewayCloudDialogueEvent(
            seq: 9,
            id: "evt-live-user",
            kind: .userMessage,
            role: "user",
            text: "合成当前提问：请继续检查实时同步状态。",
            topicId: "topic-live",
            workItemId: nil,
            outcome: nil
        )
        let personaAckEvent = MacGatewayCloudDialogueEvent(
            seq: 10,
            id: "evt-live-persona-ack",
            kind: .assistantReply,
            role: "assistant",
            text: "正在处理，请稍候。",
            topicId: "topic-live",
            workItemId: nil,
            outcome: nil
        )
        initialEvents.append(contentsOf: [activeUserEvent, personaAckEvent])
        store.cloudDialogueSubmissions = [
            MacGatewayCloudDialoguePersistedSubmission(
                gatewayId: connection.gatewayId,
                deviceId: connection.deviceId,
                kind: .mainMessage,
                requestId: "00000000-0000-4000-8000-000000000901",
                workItemId: "work:live",
                text: activeUserEvent.text,
                receipt: MacGatewayCloudDialogueReceipt(
                    eventId: activeUserEvent.id,
                    requestId: "00000000-0000-4000-8000-000000000901",
                    topicId: "topic-live",
                    workItemIds: ["work:live"],
                    state: .received,
                    replayed: false,
                    soulRevision: nil
                ),
                lastError: nil,
                updatedAt: Date()
            )
        ]
        store.ingestCloudDialogueEventsPage(
            MacGatewayCloudDialogueEventsPage(items: initialEvents, nextCursor: 10, soulRevision: nil),
            requestedAfter: 0
        )

        // Upfront persona waiting feedback ("正在处理，请稍候。") must remain a visible bubble AND keep awaiting state active.
        #expect(personaAckEvent.isUpfrontAcknowledgement)
        #expect(store.isAwaitingCloudMainReply, "Upfront persona acknowledgement must not prematurely end awaiting state before WorkItem progress or final reply arrives")
        #expect(store.cloudDialogueVisibleEvents.contains(where: { $0.id == "evt-live-persona-ack" }))

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(
            rootView: AmberInlineCloudMainDialogueView(
                store: store,
                topInset: 64,
                isInputFocused: false,
                onOpenPairingSettings: {}
            )
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
            store.stopCloudDialoguePolling()
        }

        try await Task.sleep(for: .milliseconds(260))
        host.view.layoutIfNeeded()

        func findSubviews<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
            var matches: [T] = []
            if let typed = root as? T {
                matches.append(typed)
            }
            for child in root.subviews {
                matches.append(contentsOf: findSubviews(of: type, in: child))
            }
            return matches
        }

        // Phase 1: While awaiting cloud reply (after persona ack, before first process_event),
        // the three-dot wave (ChatTaskWaveLayerView) and single-line shimmer (ChatTaskShimmerLayerView) must be mounted at the tail.
        let waveViewsPhase1 = findSubviews(of: ChatTaskWaveLayerView.self, in: host.view)
        let shimmerViewsPhase1 = findSubviews(of: ChatTaskShimmerLayerView.self, in: host.view)
        #expect(!waveViewsPhase1.isEmpty, "Cloud Amber awaiting state must render ChatTaskProgressDot three-dot wave (ChatTaskWaveLayerView)")
        #expect(!shimmerViewsPhase1.isEmpty, "Cloud Amber awaiting state must render ChatTaskProgressTextShimmer single-line shimmer (ChatTaskShimmerLayerView)")

        // Phase 2: Ingest live process_event updates and verify the status row stays at the bottom tail of the viewport.
        store.ingestCloudDialogueEventsPage(
            MacGatewayCloudDialogueEventsPage(
                items: [
                    MacGatewayCloudDialogueEvent(
                        seq: 11,
                        id: "evt-live-p1",
                        kind: .processEvent,
                        role: "assistant",
                        text: "正在检索合成资料…",
                        topicId: "topic-live",
                        workItemId: "work:live",
                        outcome: nil
                    )
                ],
                nextCursor: 11,
                soulRevision: nil
            ),
            requestedAfter: 10
        )
        try await Task.sleep(for: .milliseconds(380))
        host.view.layoutIfNeeded()

        let waveViewsPhase2 = findSubviews(of: ChatTaskWaveLayerView.self, in: host.view)
        let shimmerViewsPhase2 = findSubviews(of: ChatTaskShimmerLayerView.self, in: host.view)
        #expect(waveViewsPhase2.count == 1, "Only the active live cloud status row should mount a wave indicator")
        #expect(!shimmerViewsPhase2.isEmpty, "Active live cloud status row must keep a shimmer indicator mounted")
        #expect(store.liveCloudDialogueProgressItems.first?.displaySingleLine == "正在检索合成资料…")
        if let waveView = waveViewsPhase2.first {
            let waveFrame = waveView.convert(waveView.bounds, to: window)
            #expect(waveFrame.midY > window.bounds.height * 0.45, "Live cloud status row must be rendered at the bottom tail of the conversation, not scrolled off at the top")
        }
    }

    @Test @MainActor func cloudBottomSuggestionStripAppearingAsynchronouslyNeverOverlapsLastMessageBubble() async throws {
        let suiteName = "MacGatewayCloudDialogueTests.SuggestionInset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MacGatewayStore(defaults: defaults)
        let connection = MacGatewayConnection(
            gatewayId: "gw-suggest",
            name: "Amber Cloud",
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp-suggest",
            deviceId: "device-suggest"
        )
        let client = MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp-suggest",
            token: "token-suggest",
            transport: { request, _ in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(#"{"items":[],"nextCursor":12}"#.utf8), response)
            }
        )
        store.configureForTesting(connection: connection, client: client)
        store.isCloudMainDialogueSelected = true
        store.cloudDialogueTransportState = .healthy
        store.isReachable = true

        var events: [MacGatewayCloudDialogueEvent] = []
        for idx in 1...5 {
            events.append(
                MacGatewayCloudDialogueEvent(
                    seq: Int64(idx * 2 - 1),
                    id: "evt-s-u-\(idx)",
                    kind: .userMessage,
                    role: "user",
                    text: "合成对话提问 \(idx)",
                    topicId: "topic-s-\(idx)",
                    workItemId: nil,
                    outcome: nil
                )
            )
            events.append(
                MacGatewayCloudDialogueEvent(
                    seq: Int64(idx * 2),
                    id: "evt-s-a-\(idx)",
                    kind: .assistantReply,
                    role: "assistant",
                    text: "合成云端回复段落 \(idx)：用于验证多轮对话滚动到底部后，异步生成的底部建议胶囊条不会压住最后一条回复气泡的正文或底边。包含充足文本高度以撑满视口。",
                    topicId: "topic-s-\(idx)",
                    workItemId: nil,
                    outcome: .completed
                )
            )
        }
        store.ingestCloudDialogueEventsPage(
            MacGatewayCloudDialogueEventsPage(items: events, nextCursor: 10, soulRevision: nil),
            requestedAfter: 0
        )

        @MainActor
        final class SuggestionInsetHarnessModel: ObservableObject {
            @Published var suggestions: [String] = []
        }

        struct SuggestionInsetHarness: View {
            let store: MacGatewayStore
            @ObservedObject var model: SuggestionInsetHarnessModel

            var body: some View {
                ZStack {
                    AmberInlineCloudMainDialogueView(
                        store: store,
                        topInset: 64,
                        isInputFocused: false,
                        onOpenPairingSettings: {}
                    )
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !model.suggestions.isEmpty {
                            ChatSuggestionStrip(suggestions: model.suggestions) { _ in }
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(AmberTheme.surfaceElevated)
                            .frame(height: 92)
                    }
                    .padding(.horizontal, ChatLayout.contentHorizontalInset)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .animation(.easeOut(duration: 0.2), value: model.suggestions.isEmpty)
                }
            }
        }

        let model = SuggestionInsetHarnessModel()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: SuggestionInsetHarness(store: store, model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
            store.stopCloudDialoguePolling()
        }

        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()

        func findScrollViews(in root: UIView) -> [UIScrollView] {
            var result: [UIScrollView] = []
            if let sv = root as? UIScrollView {
                result.append(sv)
            }
            for sub in root.subviews {
                result.append(contentsOf: findScrollViews(in: sub))
            }
            return result
        }

        let verticalScrollView = try #require(
            findScrollViews(in: host.view).first { $0.contentSize.height > $0.bounds.height }
        )
        let bottomOffsetBefore = max(
            -verticalScrollView.adjustedContentInset.top,
            verticalScrollView.contentSize.height - verticalScrollView.bounds.height + verticalScrollView.adjustedContentInset.bottom
        )
        verticalScrollView.setContentOffset(CGPoint(x: 0, y: bottomOffsetBefore), animated: false)
        host.view.layoutIfNeeded()

        // Simulate async suggestion generation completing after the assistant reply is already on screen at the bottom.
        model.suggestions = [
            "合成建议一：继续展开说明细节，看看下一步怎么安排更稳妥",
            "合成建议二：整理成简明清单"
        ]
        try await Task.sleep(for: .milliseconds(380))
        host.view.layoutIfNeeded()

        let horizontalSuggestionScroll = try #require(
            findScrollViews(in: host.view).first { $0 !== verticalScrollView && $0.bounds.height < 80 }
        )
        let suggestionFrameInWindow = horizontalSuggestionScroll.convert(horizontalSuggestionScroll.bounds, to: window)

        // Check how far verticalScrollView is from the new bottom target after suggestions appeared:
        let bottomOffsetAfter = max(
            -verticalScrollView.adjustedContentInset.top,
            verticalScrollView.contentSize.height - verticalScrollView.bounds.height + verticalScrollView.adjustedContentInset.bottom
        )
        let uncompensatedInsetGrowth = bottomOffsetAfter - verticalScrollView.contentOffset.y
        // Also compute the last bubble's bottom Y in window coordinates:
        // In AmberInlineCloudMainDialogueView, the bottom anchor spacer is 12pt + 14pt spacing = 26pt below the last bubble.
        let contentBottomInWindow = verticalScrollView.convert(
            CGPoint(x: 0, y: verticalScrollView.contentSize.height - 26),
            to: window
        ).y

        #expect(
            uncompensatedInsetGrowth <= 1.0,
            "When ChatSuggestionStrip appears asynchronously, cloud ScrollView must re-anchor to bottom (uncompensated growth was \(uncompensatedInsetGrowth)pt)"
        )
        #expect(
            contentBottomInWindow <= suggestionFrameInWindow.minY - 4.0,
            "Last cloud message bubble bottom (\(contentBottomInWindow)) must stay above ChatSuggestionStrip top (\(suggestionFrameInWindow.minY))"
        )
    }
}
