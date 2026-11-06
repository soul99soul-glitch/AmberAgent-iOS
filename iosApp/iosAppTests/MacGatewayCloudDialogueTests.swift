import Foundation
import Testing
@testable import iosApp

@Suite("Mac Gateway Cloud Dialogue v1")
struct MacGatewayCloudDialogueTests {

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
        #expect(stopReceipt.state == .consumed)

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
}
