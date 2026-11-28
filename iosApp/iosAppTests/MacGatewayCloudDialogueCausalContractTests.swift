import Foundation
import Testing
@testable import iosApp

@Suite("MacGatewayCloudDialogueCausalContractTests", .serialized)
struct MacGatewayCloudDialogueCausalContractTests {
    @MainActor
    private func makeTestStore(
        suiteSuffix: String,
        transport: @escaping MacGatewayClient.Transport = { _, _ in
            throw URLError(.unsupportedURL)
        }
    ) throws -> (store: MacGatewayStore, defaults: UserDefaults, suiteName: String) {
        let suiteName = "MacGatewayCloudDialogueCausalContractTests.\(suiteSuffix).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let connection = MacGatewayConnection(
            gatewayId: "gw-causal",
            name: "Amber Cloud",
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            deviceId: "device-causal-1"
        )
        let client = MacGatewayClient(
            addrs: ["cloud.example"],
            port: 443,
            fingerprint: "fp",
            token: "paired-token-causal",
            transport: transport
        )
        let store = MacGatewayStore(defaults: defaults)
        store.configureForTesting(connection: connection, client: client)
        return (store, defaults, suiteName)
    }

    private static func jsonResponse(url: URL, status: Int, json: String) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(json.utf8), response)
    }

    // MARK: - 1. Core Regression: Duplicate Text Follow-ups + causedByInputId + Disconnect Replay

    @Test @MainActor func duplicateTextFollowupsConsumeOnlyExactTargetViaCausedByInputIdAndSurviveReplay() async throws {
        let req1 = "110e8400-e29b-41d4-a716-446655440001"
        let req2 = "110e8400-e29b-41d4-a716-446655440002"
        let (store, defaults, suiteName) = try makeTestStore(suiteSuffix: "DuplicateText") { request, _ in
            let url = request.url!
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if body.contains(req1) {
                return Self.jsonResponse(
                    url: url, status: 202,
                    json: #"{"eventId":"evt-in-1","requestId":"110e8400-e29b-41d4-a716-446655440001","topicId":"topic-dup","workItemIds":["work:dup"],"state":"received","replayed":false}"#
                )
            }
            return Self.jsonResponse(
                url: url, status: 202,
                json: #"{"eventId":"evt-in-2","requestId":"110e8400-e29b-41d4-a716-446655440002","topicId":"topic-dup","workItemIds":["work:dup"],"state":"received","replayed":false}"#
            )
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = try await store.sendCloudWorkItemInput(workItemId: "work:dup", text: "按第二版", requestId: req1).get()
        store.stopCloudDialoguePolling()
        _ = try await store.sendCloudWorkItemInput(workItemId: "work:dup", text: "按第二版", requestId: req2).get()
        store.stopCloudDialoguePolling()

        // Use an opaque event id without `consumed:` prefix so Priority 1 (`causedByInputId`) is proven directly.
        let consumedPageJSON = #"""
        {
          "items": [
            {"seq":1,"id":"evt-in-1","kind":"followup","role":"user","text":"按第二版","topicId":"topic-dup","workItemId":"work:dup","causedByRequestId":"110e8400-e29b-41d4-a716-446655440001"},
            {"seq":2,"id":"evt-in-2","kind":"followup","role":"user","text":"按第二版","topicId":"topic-dup","workItemId":"work:dup","causedByRequestId":"110e8400-e29b-41d4-a716-446655440002"},
            {"seq":3,"id":"evt-consumed-v1-2","kind":"input_consumed","role":"system","text":"补充已被任务消费","topicId":"topic-dup","workItemId":"work:dup","causedByInputId":"evt-in-2","causedByRequestId":"110e8400-e29b-41d4-a716-446655440001"}
          ],
          "nextCursor": 3
        }
        """#
        let page = try JSONDecoder().decode(MacGatewayCloudDialogueEventsPage.self, from: Data(consumedPageJSON.utf8))
        store.ingestCloudDialogueEventsPage(page, requestedAfter: 0)

        let first = try #require(store.cloudDialogueFollowups.first(where: { $0.requestId == req1 }))
        let second = try #require(store.cloudDialogueFollowups.first(where: { $0.requestId == req2 }))
        #expect(first.state == .received, "First identical-text follow-up must stay pending when only second was consumed")
        #expect(first.isShownAsExecuted == false)
        #expect(second.state == .consumed, "Second follow-up must transition to consumed")
        #expect(second.isShownAsExecuted == true)
        #expect(store.cloudDialogueReceipts[req1]?.state == .received)
        #expect(store.cloudDialogueReceipts[req2]?.state == .consumed)
        #expect(store.cloudDialogueSubmissions.first { $0.requestId == req1 }?.receipt?.state == .received)

        // Strict causal lookup for rendering never confuses identical text rows
        let evt1 = try #require(store.cloudDialogueEvents.first(where: { $0.id == "evt-in-1" }))
        let evt2 = try #require(store.cloudDialogueEvents.first(where: { $0.id == "evt-in-2" }))
        #expect(store.cloudDialogueFollowup(for: evt1)?.requestId == req1)
        #expect(store.cloudDialogueFollowup(for: evt2)?.requestId == req2)

        // Disconnect replay of the same batch must preserve exact state without duplicating follow-up records
        store.ingestCloudDialogueEventsPage(page, requestedAfter: 0)
        #expect(store.cloudDialogueFollowups.count == 2)
        #expect(store.cloudDialogueFollowups.first(where: { $0.requestId == req1 })?.state == .received)
        #expect(store.cloudDialogueFollowups.first(where: { $0.requestId == req2 })?.state == .consumed)
        #expect(store.cloudDialogueReceipts[req1]?.state == .received)
        #expect(store.cloudDialogueReceipts[req2]?.state == .consumed)

        // A GET sampled before consumption can return after the event was applied.
        _ = try await store.refreshCloudDialogueReceipt(requestId: req2).get()
        store.loadPersistedCloudDialogueState()
        #expect(store.cloudDialogueFollowups.first { $0.requestId == req2 }?.state == .consumed)
        #expect(store.cloudDialogueReceipts[req2]?.state == .consumed)
        #expect(store.cloudDialogueSubmissions.first { $0.requestId == req2 }?.receipt?.state == .consumed)
    }

    // MARK: - 2. Causal Priority 2 (causedByRequestId) & Priority 3 (consumed:<id> / cancelled:<id>)

    @Test @MainActor func causalPriorityMatchesByRequestIdAndDeterministicPrefixWithoutTextGuessing() async throws {
        let req1 = "120e8400-e29b-41d4-a716-446655440001"
        let req2 = "120e8400-e29b-41d4-a716-446655440002"
        let req3 = "120e8400-e29b-41d4-a716-446655440003"
        let (store, defaults, suiteName) = try makeTestStore(suiteSuffix: "CausalPriorities") { request, _ in
            let url = request.url!
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if body.contains(req1) {
                return Self.jsonResponse(
                    url: url, status: 202,
                    json: #"{"eventId":"evt-p-1","requestId":"120e8400-e29b-41d4-a716-446655440001","topicId":"topic-p","workItemIds":["work:p"],"state":"received","replayed":false}"#
                )
            }
            if body.contains(req2) {
                return Self.jsonResponse(
                    url: url, status: 202,
                    json: #"{"eventId":"evt-p-2","requestId":"120e8400-e29b-41d4-a716-446655440002","topicId":"topic-p","workItemIds":["work:p"],"state":"received","replayed":false}"#
                )
            }
            return Self.jsonResponse(
                url: url, status: 202,
                json: #"{"eventId":"evt-p-3","requestId":"120e8400-e29b-41d4-a716-446655440003","topicId":"topic-p","workItemIds":["work:p"],"state":"received","replayed":false}"#
            )
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = try await store.sendCloudWorkItemInput(workItemId: "work:p", text: "按第二版", requestId: req1).get()
        store.stopCloudDialoguePolling()
        _ = try await store.sendCloudWorkItemInput(workItemId: "work:p", text: "按第二版", requestId: req2).get()
        store.stopCloudDialoguePolling()
        _ = try await store.sendCloudWorkItemInput(workItemId: "work:p", text: "按第二版", requestId: req3).get()
        store.stopCloudDialoguePolling()

        // The visible status belongs to the second input. A late cancellation for
        // another input on the same work item must leave that status in place.
        store.cloudPersonaRequestID = req2
        store.cloudPersonaWorkItemID = "work:p"
        // Priority 2: causedByRequestId targets req2 only
        // Priority 3: deterministic prefix `cancelled:evt-p-3` targets req3 only
        // req1 must stay `.received`
        let pageJSON = #"""
        {
          "items": [
            {"seq":1,"id":"evt-opaque-by-req","kind":"input_consumed","role":"system","text":"补充已被任务消费","topicId":"topic-p","workItemId":"work:p","causedByRequestId":"120e8400-e29b-41d4-a716-446655440002"},
            {"seq":2,"id":"cancelled:evt-p-3","kind":"input_cancelled","role":"system","text":"任务已停止，这条补充未执行","topicId":"topic-p","workItemId":"work:p"}
          ],
          "nextCursor": 2
        }
        """#
        let page = try JSONDecoder().decode(MacGatewayCloudDialogueEventsPage.self, from: Data(pageJSON.utf8))
        store.ingestCloudDialogueEventsPage(page, requestedAfter: 0)

        #expect(store.cloudDialogueFollowups.first(where: { $0.requestId == req1 })?.state == .received)
        #expect(store.cloudDialogueFollowups.first(where: { $0.requestId == req2 })?.state == .consumed)
        #expect(store.cloudDialogueFollowups.first(where: { $0.requestId == req3 })?.state == .cancelled)
        #expect(store.cloudDialogueReceipts[req1]?.state == .received)
        #expect(store.cloudDialogueReceipts[req2]?.state == .consumed)
        #expect(store.cloudDialogueReceipts[req3]?.state == .cancelled)
        #expect(store.cloudPersonaRequestID == req2)

        func ingest(_ id: String, _ kind: MacGatewayCloudDialogueEventKind, seq: Int64,
                    workItem: String? = "work:p", request: String? = nil) {
            let event = MacGatewayCloudDialogueEvent(seq: seq, id: id, kind: kind, role: "assistant",
                text: "正在处理", topicId: "topic-p", workItemId: workItem, causedByRequestId: request)
            store.ingestCloudDialogueEventsPage(.init(items: [event], nextCursor: seq), requestedAfter: seq - 1)
        }
        ingest("ack:evt-p-2", .assistantReply, seq: 3)
        #expect(store.cloudPersonaRequestID == req2)
        ingest("older-reply", .assistantReply, seq: 4, workItem: nil, request: req1)
        #expect(store.cloudPersonaRequestID == req2)
        ingest("tool-start", .processEvent, seq: 5)
        #expect(store.cloudPersonaRequestID == nil)
    }

    // MARK: - 3. Legacy Degradation: Missing Causal IDs Never Guess & Reconcile via Receipt

    @Test @MainActor func legacyConsumedWithoutCausalIdsNeverGuessesAndReconcilesViaReceipt() async throws {
        let req1 = "220e8400-e29b-41d4-a716-446655440001"
        let req2 = "220e8400-e29b-41d4-a716-446655440002"
        actor ReceiptProbe {
            var queriedPaths: [String] = []
            func record(_ path: String) { queriedPaths.append(path) }
            func allPaths() -> [String] { queriedPaths }
        }
        let probe = ReceiptProbe()
        let (store, defaults, suiteName) = try makeTestStore(suiteSuffix: "LegacyNoGuess") { request, _ in
            let url = request.url!
            let method = request.httpMethod ?? "GET"
            let path = url.path
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if method == "POST", path == "/v2/work-items/work:leg/inputs" {
                if body.contains(req1) {
                    return Self.jsonResponse(
                        url: url, status: 202,
                        json: #"{"eventId":"evt-leg-1","requestId":"220e8400-e29b-41d4-a716-446655440001","topicId":"topic-leg","workItemIds":["work:leg"],"state":"received","replayed":false}"#
                    )
                }
                return Self.jsonResponse(
                    url: url, status: 202,
                    json: #"{"eventId":"evt-leg-2","requestId":"220e8400-e29b-41d4-a716-446655440002","topicId":"topic-leg","workItemIds":["work:leg"],"state":"received","replayed":false}"#
                )
            }
            if method == "GET", path == "/v2/dialogue/receipts/\(req1)" {
                await probe.record(path)
                return Self.jsonResponse(
                    url: url, status: 200,
                    json: #"{"eventId":"evt-leg-1","requestId":"220e8400-e29b-41d4-a716-446655440001","topicId":"topic-leg","workItemIds":["work:leg"],"state":"received","replayed":true}"#
                )
            }
            if method == "GET", path == "/v2/dialogue/receipts/\(req2)" {
                await probe.record(path)
                return Self.jsonResponse(
                    url: url, status: 200,
                    json: #"{"eventId":"evt-leg-2","requestId":"220e8400-e29b-41d4-a716-446655440002","topicId":"topic-leg","workItemIds":["work:leg"],"state":"consumed","replayed":true}"#
                )
            }
            if method == "GET", path == "/v2/dialogue/events", url.query == "after=1&limit=100" {
                return Self.jsonResponse(url: url, status: 200, json: #"""
                    {"items":[
                      {"seq":2,"id":"opaque-final","kind":"input_cancelled","role":"system","text":"","topicId":"topic-leg","workItemId":"work:leg"},
                      {"seq":3,"id":"result","kind":"task_result","role":"assistant","text":"已完成","topicId":"topic-leg","workItemId":"work:leg","outcome":"completed"}
                    ],"nextCursor":3}
                    """#)
            }
            return Self.jsonResponse(url: url, status: 404, json: #"{"error":"not_found"}"#)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = try await store.sendCloudWorkItemInput(workItemId: "work:leg", text: "按第二版", requestId: req1).get()
        store.stopCloudDialoguePolling()
        _ = try await store.sendCloudWorkItemInput(workItemId: "work:leg", text: "按第二版", requestId: req2).get()
        store.stopCloudDialoguePolling()

        // Legacy server emits an input_consumed with matching text but NO causal id and NO `consumed:<id>` prefix
        let legacyPageJSON = #"""
        {
          "items": [
            {"seq":1,"id":"evt-legacy-consumed-opaque","kind":"input_consumed","role":"system","text":"按第二版","topicId":"topic-leg","workItemId":"work:leg"}
          ],
          "nextCursor": 1
        }
        """#
        let page = try JSONDecoder().decode(MacGatewayCloudDialogueEventsPage.self, from: Data(legacyPageJSON.utf8))
        store.ingestCloudDialogueEventsPage(page, requestedAfter: 0)

        let first = try #require(store.cloudDialogueFollowups.first(where: { $0.requestId == req1 }))
        let second = try #require(store.cloudDialogueFollowups.first(where: { $0.requestId == req2 }))
        #expect(first.state == .received, "Legacy event without causal id must NOT guess and mark first follow-up consumed")
        #expect(second.state == .received, "Legacy event without causal id must NOT guess and mark second follow-up consumed")
        #expect(first.needsReceiptReconciliation == true)
        #expect(second.needsReceiptReconciliation == true)
        #expect(store.followupsNeedingReceiptReconciliation.count == 2)
        #expect(store.cloudDialogueReceipts[req1]?.state == .received)
        #expect(store.cloudDialogueReceipts[req2]?.state == .received)

        // Explicit reconciliation queries original requestIds and resolves exact server truth
        await store.reconcilePendingCloudDialogueSubmissionsIfNeeded()
        let queried = await probe.allPaths()
        #expect(queried.contains("/v2/dialogue/receipts/\(req1)"))
        #expect(queried.contains("/v2/dialogue/receipts/\(req2)"))
        #expect(store.cloudDialogueFollowups.first(where: { $0.requestId == req1 })?.state == .received)
        #expect(store.cloudDialogueFollowups.first(where: { $0.requestId == req2 })?.state == .consumed)
        #expect(store.cloudDialogueFollowups.first(where: { $0.requestId == req1 })?.needsReceiptReconciliation == false)
        #expect(store.cloudDialogueFollowups.first(where: { $0.requestId == req2 })?.needsReceiptReconciliation == false)

        // The final page must finish its own receipt check when the user has switched back to local.
        _ = try await store.pollCloudDialogueEvents().get()
        #expect(store.activeCloudDialogueWorkItemIds.isEmpty)
        #expect(await probe.allPaths() == queried + ["/v2/dialogue/receipts/\(req1)"])
    }

    // MARK: - 4. stop_too_late State Transitions

    @Test @MainActor func stopTooLateMarksCompletedBeforeStopRatherThanCancelled() async throws {
        let stopReqId = "330e8400-e29b-41d4-a716-446655440001"
        let (store, defaults, suiteName) = try makeTestStore(suiteSuffix: "StopTooLate") { request, _ in
            if request.url?.path == "/v2/work-items/legacy/stop" {
                return Self.jsonResponse(url: request.url!, status: 409, json: #"{"error":"task_terminal"}"#)
            }
            return Self.jsonResponse(
                url: request.url!, status: 200,
                json: #"{"eventId":"evt-stop-req","requestId":"330e8400-e29b-41d4-a716-446655440001","topicId":"topic-stl","workItemIds":["work:stl"],"state":"consumed","replayed":false}"#
            )
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let livePageJSON = #"""
        {
          "items": [
            {"seq":1,"id":"evt-stl-proc","kind":"process_event","role":"system","text":"正在收尾输出…","topicId":"topic-stl","workItemId":"work:stl"}
          ],
          "nextCursor": 1
        }
        """#
        store.ingestCloudDialogueEventsPage(
            try JSONDecoder().decode(MacGatewayCloudDialogueEventsPage.self, from: Data(livePageJSON.utf8)),
            requestedAfter: 0
        )

        _ = try await store.stopCloudWorkItem(workItemId: "work:stl", requestId: stopReqId).get()
        store.stopCloudDialoguePolling()
        #expect(store.cloudDialogueProgressByWorkItem["work:stl"]?.isStopRequested == true)
        #expect(store.cloudDialogueProgressByWorkItem["work:stl"]?.displaySingleLine == "已请求停止")

        // Server reports stop_too_late: task already finished before stop took effect
        let stopTooLatePageJSON = #"""
        {
          "items": [
            {
              "seq": 2,
              "id": "evt-stop-too-late",
              "kind": "stop_too_late",
              "role": "system",
              "text": "停止请求到达前任务已完成",
              "topicId": "topic-stl",
              "workItemId": "work:stl",
              "causedByRequestId": "330e8400-e29b-41d4-a716-446655440001",
              "conversationId": "conv-stl",
              "epoch": 2
            }
          ],
          "nextCursor": 2
        }
        """#
        let stlPage = try JSONDecoder().decode(MacGatewayCloudDialogueEventsPage.self, from: Data(stopTooLatePageJSON.utf8))
        #expect(stlPage.items.first?.kind == .stopTooLate)
        store.ingestCloudDialogueEventsPage(stlPage, requestedAfter: 1)

        let progress = try #require(store.cloudDialogueProgressByWorkItem["work:stl"])
        #expect(progress.isStopTooLate == true)
        #expect(progress.isStopRequested == false)
        #expect(progress.outcome == .completed, "stop_too_late must settle as completed rather than misreporting cancelled")
        #expect(progress.isLive == false)
        #expect(progress.displaySingleLine.contains("已完成"))
        #expect(!progress.displaySingleLine.contains("已停止"))
        #expect(!progress.displaySingleLine.contains("已请求停止"))

        // A late stop_requested event arriving afterwards must NOT overwrite the completed settlement
        let lateStopPageJSON = #"""
        {
          "items": [
            {"seq":3,"id":"evt-stop-late","kind":"stop_requested","role":"user","text":"停止任务","topicId":"topic-stl","workItemId":"work:stl","outcome":"cancelled"}
          ],
          "nextCursor": 3
        }
        """#
        store.ingestCloudDialogueEventsPage(
            try JSONDecoder().decode(MacGatewayCloudDialogueEventsPage.self, from: Data(lateStopPageJSON.utf8)),
            requestedAfter: 2
        )
        let afterLateStop = try #require(store.cloudDialogueProgressByWorkItem["work:stl"])
        #expect(afterLateStop.outcome == .completed)
        #expect(afterLateStop.isStopRequested == false)
        #expect(afterLateStop.isStopTooLate == true)

        // An old node can confirm that work ended without reporting how it ended.
        _ = await store.stopCloudWorkItem(workItemId: "legacy")
        let legacy = try #require(store.cloudDialogueProgressByWorkItem["legacy"])
        #expect(!legacy.isStopRequested)
        #expect(legacy.outcome == nil && legacy.needsOutcomeUnknownAction)
    }

    // MARK: - 5. outcomeUnknown State & Callable Actions (Recheck / Retry / Abandon)

    @Test @MainActor func outcomeUnknownPreservesExplicitStateAndSupportsRecheckRetryAndAbandon() async throws {
        actor MockOutcomeServer {
            var retryBodies: [String] = []
            func recordRetryBody(_ body: String) { retryBodies.append(body) }
            func allRetryBodies() -> [String] { retryBodies }
        }
        let server = MockOutcomeServer()
        let retryReqId = "440e8400-e29b-41d4-a716-446655440099"

        let (store, defaults, suiteName) = try makeTestStore(suiteSuffix: "OutcomeUnknown") { request, _ in
            let url = request.url!
            let method = request.httpMethod ?? "GET"
            let path = url.path
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""

            if method == "GET", path == "/v2/dialogue/events" {
                return Self.jsonResponse(url: url, status: 200, json: #"{"items":[],"nextCursor":10}"#)
            }
            if method == "GET", path == "/v2/work-items/work:unk-1" {
                return Self.jsonResponse(
                    url: url, status: 200,
                    json: """
                    {
                      "workItem": {
                        "id": "work:unk-1",
                        "agentId": "main",
                        "title": "核对任务 1",
                        "state": "COMPLETED",
                        "progress": "已核对完成",
                        "updatedAtMs": 1793500040000,
                        "conversationId": "conv-unk-main",
                        "outcomeUnknown": false
                      },
                      "brief": "检查日志",
                      "failure": null,
                      "sessionArchived": false,
                      "resultMarkdown": "核对后确认已完成",
                      "outcomeUnknown": false
                    }
                    """
                )
            }
            if method == "POST", path == "/v2/dialogue/messages" {
                await server.recordRetryBody(body)
                return Self.jsonResponse(
                    url: url, status: 202,
                    json: """
                    {
                      "eventId": "evt-retry-msg",
                      "requestId": "\(retryReqId)",
                      "topicId": "topic-retry",
                      "workItemIds": ["work:retry-2"],
                      "state": "received",
                      "replayed": false,
                      "conversationId": "conv-unk-main"
                    }
                    """
                )
            }
            return Self.jsonResponse(url: url, status: 404, json: #"{"error":"not_found"}"#)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let unknownPageJSON = #"""
        {
          "items": [
            {"seq":1,"id":"evt-u2-origin","kind":"user_message","role":"user","text":"重跑第二份报表","topicId":"topic-unk-2","workItemId":"work:unk-2","conversationId":"conv-unk-main"},
            {
              "seq": 2,
              "id": "evt-unk-1",
              "kind": "task_result",
              "role": "assistant",
              "text": "进程异常中断，结果状态未确认",
              "topicId": "topic-unk-1",
              "workItemId": "work:unk-1",
              "conversationId": "conv-unk-main",
              "parentRunId": "run-parent-1",
              "executorKind": "worker",
              "executorId": "worker-1",
              "epoch": 7,
              "observedSeq": 42,
              "ledgerId": "ledger-unk-1",
              "outcomeUnknown": true
            },
            {
              "seq": 3,
              "id": "evt-unk-2",
              "kind": "task_result",
              "role": "assistant",
              "text": "写入远端超时，需确认结果",
              "topicId": "topic-unk-2",
              "workItemId": "work:unk-2",
              "conversationId": "conv-unk-main",
              "outcomeUnknown": true
            },
            {
              "seq": 4,
              "id": "evt-unk-3",
              "kind": "process_event",
              "role": "system",
              "text": "状态丢失，请决定是否放弃",
              "topicId": "topic-unk-3",
              "workItemId": "work:unk-3",
              "conversationId": "conv-unk-main",
              "outcomeUnknown": true
            }
          ],
          "nextCursor": 4,
          "conversationId": "conv-unk-main"
        }
        """#
        store.ingestCloudDialogueEventsPage(
            try JSONDecoder().decode(MacGatewayCloudDialogueEventsPage.self, from: Data(unknownPageJSON.utf8)),
            requestedAfter: 0
        )

        let unk1 = try #require(store.cloudDialogueProgressByWorkItem["work:unk-1"])
        #expect(unk1.isOutcomeUnknown == true)
        #expect(unk1.needsOutcomeUnknownAction == true)
        #expect(unk1.outcome == nil, "outcomeUnknown must never fabricate a terminal completed/cancelled outcome")
        #expect(unk1.displaySingleLine.contains("结果待确认"))
        #expect(unk1.parentRunId == "run-parent-1")
        #expect(unk1.executorKind == "worker")
        #expect(unk1.executorId == "worker-1")
        #expect(unk1.epoch == 7)
        #expect(unk1.observedSeq == 42)
        #expect(unk1.ledgerId == "ledger-unk-1")
        #expect(store.outcomeUnknownCloudDialogueProgressItems.count == 3)
        #expect(store.prepareCloudDialogueTaskInput(workItemId: "work:unk-1") == false)

        // Action 1: Recheck -> resolves work:unk-1 from authoritative GET /v2/work-items/work:unk-1
        let rechecked = try await store.recheckOutcomeUnknownCloudWorkItem(workItemId: "work:unk-1").get()
        #expect(rechecked?.isOutcomeUnknown == false)
        #expect(rechecked?.outcome == .completed)
        #expect(rechecked?.outcomeUnknownResolution == .rechecked)
        #expect(rechecked?.isLive == false)

        // Action 2: Retry -> submits new requestId with stable conversationId and exits unknown state on work:unk-2
        let retryReceipt = try await store.retryOutcomeUnknownCloudWorkItem(
            workItemId: "work:unk-2",
            requestId: retryReqId
        ).get()
        store.stopCloudDialoguePolling()
        #expect(retryReceipt.requestId == retryReqId)
        let retryBody = try #require(await server.allRetryBodies().first)
        let retryJSON = try #require(JSONSerialization.jsonObject(with: Data(retryBody.utf8)) as? [String: Any])
        #expect(retryJSON["requestId"] as? String == retryReqId)
        #expect(retryJSON["conversationId"] as? String == "conv-unk-main")
        #expect(retryJSON["text"] as? String == "重跑第二份报表")
        let retriedProgress = try #require(store.cloudDialogueProgressByWorkItem["work:unk-2"])
        #expect(retriedProgress.outcomeUnknownResolution == .retried)
        #expect(retriedProgress.needsOutcomeUnknownAction == false)
        #expect(retriedProgress.isLive == false)

        // Action 3: Abandon -> explicitly resolves work:unk-3 without getting stuck
        let abandoned = store.abandonOutcomeUnknownCloudWorkItem(workItemId: "work:unk-3")
        #expect(abandoned == true)
        let abandonedProgress = try #require(store.cloudDialogueProgressByWorkItem["work:unk-3"])
        #expect(abandonedProgress.outcomeUnknownResolution == .abandoned)
        #expect(abandonedProgress.needsOutcomeUnknownAction == false)
        #expect(abandonedProgress.isLive == false)
        #expect(abandonedProgress.displaySingleLine.contains("已放弃"))
        #expect(store.outcomeUnknownCloudDialogueProgressItems.isEmpty)
        #expect(!store.activeCloudDialogueWorkItemIds.contains("work:unk-3"))

        // A different, late uncertainty event survives event-ID deduplication.
        let late = (1...3).map { n in
            MacGatewayCloudDialogueEvent(seq: 1, id: "late-unknown-\(n)", kind: .taskResult, role: "assistant",
                text: "仍待确认", topicId: "topic-unk-\(n)", workItemId: "work:unk-\(n)", outcomeUnknown: true)
        }
        store.ingestCloudDialogueEventsPage(.init(items: late, nextCursor: 4), requestedAfter: 0)
        store.persistCloudDialogueState(immediately: true)
        store.loadPersistedCloudDialogueState()
        #expect(store.outcomeUnknownCloudDialogueProgressItems.isEmpty)
        #expect(store.cloudDialogueProgressByWorkItem["work:unk-1"]?.outcome == .completed)
        #expect(store.cloudDialogueProgressByWorkItem["work:unk-2"]?.outcomeUnknownResolution == .retried)
        #expect(store.cloudDialogueProgressByWorkItem["work:unk-3"]?.outcomeUnknownResolution == .abandoned)
        _ = await store.retryOutcomeUnknownCloudWorkItem(workItemId: "work:unk-2")
        #expect(await server.allRetryBodies().count == 1)
    }

    @Test @MainActor func lostRetryResponseRecoversTheSameRequestAfterRelaunch() async throws {
        actor Server {
            var posts: [String] = []
            func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
                let url = try #require(request.url)
                guard request.httpMethod == "POST" else {
                    return MacGatewayCloudDialogueCausalContractTests.jsonResponse(url: url, status: 200, json: #"{"items":[],"nextCursor":1}"#)
                }
                let body = try JSONDecoder().decode(MacGatewayCloudDialogueInputRequest.self, from: #require(request.httpBody))
                posts.append(body.requestId)
                if posts.count == 1 { throw URLError(.networkConnectionLost) }
                return MacGatewayCloudDialogueCausalContractTests.jsonResponse(url: url, status: 200, json: """
                    {"eventId":"retried","requestId":"\(body.requestId)","topicId":"retry-topic","workItemIds":[],"state":"received","replayed":true}
                    """)
            }
        }
        let server = Server()
        let (store, defaults, suiteName) = try makeTestStore(suiteSuffix: "LostRetry") { req, _ in
            try await server.handle(req)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let unknown = MacGatewayCloudDialogueEvent(seq: 1, id: "uncertain", kind: .taskResult,
            role: "assistant", text: "结果待确认", topicId: "original", workItemId: "w", outcomeUnknown: true)
        store.ingestCloudDialogueEventsPage(.init(items: [unknown], nextCursor: 1), requestedAfter: 0)
        _ = await store.retryOutcomeUnknownCloudWorkItem(workItemId: "w", text: "重试原任务", requestId: "first-retry")
        store.resetCloudDialogueMemoryState()
        store.loadPersistedCloudDialogueState()
        _ = try await store.retryOutcomeUnknownCloudWorkItem(workItemId: "w", text: "重试原任务", requestId: "another-id").get()
        store.stopCloudDialoguePolling()
        #expect(await server.posts == ["first-retry", "first-retry"])
        #expect(store.cloudDialogueProgressByWorkItem["w"]?.outcomeUnknownResolution == .retried)
    }

    // MARK: - 6. Stable conversationId Propagation on Message / Followup / Stop Requests

    @Test @MainActor func requestsCarryStableConversationIdOnceKnownAndOmitWhenAbsent() async throws {
        // Without conversationId, legacy strict keys remain unchanged
        let legacyMsgData = try JSONEncoder().encode(
            MacGatewayCloudDialogueInputRequest(requestId: "req-legacy-msg", text: "你好")
        )
        let legacyMsgObj = try #require(JSONSerialization.jsonObject(with: legacyMsgData) as? [String: Any])
        #expect(Set(legacyMsgObj.keys) == ["requestId", "text"])

        let legacyStopData = try JSONEncoder().encode(
            MacGatewayCloudDialogueStopRequest(requestId: "req-legacy-stop")
        )
        let legacyStopObj = try #require(JSONSerialization.jsonObject(with: legacyStopData) as? [String: Any])
        #expect(Set(legacyStopObj.keys) == ["requestId"])

        // Once server establishes conversationId, message/followup/stop requests carry stable conversationId + unique requestId
        actor CaptureServer {
            var bodiesByPath: [(path: String, data: Data)] = []
            func record(path: String, data: Data?) {
                if let data {
                    bodiesByPath.append((path, data))
                }
            }
            func all() -> [(path: String, data: Data)] { bodiesByPath }
        }
        let capture = CaptureServer()
        let (store, defaults, suiteName) = try makeTestStore(suiteSuffix: "ConvId") { request, _ in
            let url = request.url!
            await capture.record(path: url.path, data: request.httpBody)
            switch url.path {
            case "/v2/dialogue/messages":
                return Self.jsonResponse(
                    url: url, status: 202,
                    json: #"{"eventId":"evt-c-msg","requestId":"550e8400-e29b-41d4-a716-446655440010","topicId":"topic-c","workItemIds":["work:c"],"state":"received","replayed":false,"conversationId":"conv-main-001"}"#
                )
            case "/v2/work-items/work:c/inputs":
                return Self.jsonResponse(
                    url: url, status: 202,
                    json: #"{"eventId":"evt-c-in","requestId":"550e8400-e29b-41d4-a716-446655440011","topicId":"topic-c","workItemIds":["work:c"],"state":"received","replayed":false,"conversationId":"conv-main-001"}"#
                )
            case "/v2/work-items/work:c/stop":
                return Self.jsonResponse(
                    url: url, status: 200,
                    json: #"{"eventId":"evt-c-stop","requestId":"550e8400-e29b-41d4-a716-446655440012","topicId":"topic-c","workItemIds":["work:c"],"state":"consumed","replayed":false,"conversationId":"conv-main-001"}"#
                )
            default:
                return Self.jsonResponse(url: url, status: 404, json: #"{"error":"not_found"}"#)
            }
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = try await store.sendCloudDialogueMessage(
            text: "启动主对话任务",
            requestId: "550e8400-e29b-41d4-a716-446655440010"
        ).get()
        store.stopCloudDialoguePolling()
        #expect(store.cloudDialogueConversationId == "conv-main-001")

        // The event stream contains all paired conversations, including another device's history.
        let foreign = MacGatewayCloudDialogueEvent(seq: 10, id: "foreign-progress", kind: .processEvent, role: "system",
            text: "另一个会话的任务", topicId: "foreign-topic", workItemId: "work:other", conversationId: "conv-other")
        store.ingestCloudDialogueEventsPage(.init(items: [foreign], nextCursor: 10), requestedAfter: 0)
        #expect(store.cloudDialogueConversationId == "conv-main-001")

        _ = try await store.sendCloudWorkItemInput(
            workItemId: "work:c",
            text: "补充一条要求",
            requestId: "550e8400-e29b-41d4-a716-446655440011"
        ).get()
        store.stopCloudDialoguePolling()

        _ = try await store.stopCloudWorkItem(
            workItemId: "work:c",
            requestId: "550e8400-e29b-41d4-a716-446655440012"
        ).get()
        store.stopCloudDialoguePolling()

        // Replaying the first POST must keep its omitted conversationId, even after its receipt supplied one.
        _ = try await store.sendCloudDialogueMessage(
            text: "启动主对话任务", requestId: "550e8400-e29b-41d4-a716-446655440010"
        ).get()
        store.stopCloudDialoguePolling()

        let capturedRaw = await capture.all()
        let captured = try capturedRaw.map { entry -> (path: String, json: [String: Any]) in
            let obj = try #require(JSONSerialization.jsonObject(with: entry.data) as? [String: Any])
            return (entry.path, obj)
        }
        #expect(captured.count == 4)
        // First message had no conversationId yet -> omitted for legacy server compatibility
        #expect(captured[0].json["conversationId"] == nil)
        #expect(captured[0].json["requestId"] as? String == "550e8400-e29b-41d4-a716-446655440010")
        // Follow-up & stop carry the established stable conversationId + distinct requestIds
        #expect(captured[1].json["conversationId"] as? String == "conv-main-001")
        #expect(captured[1].json["requestId"] as? String == "550e8400-e29b-41d4-a716-446655440011")
        #expect(captured[2].json["conversationId"] as? String == "conv-main-001")
        #expect(captured[2].json["requestId"] as? String == "550e8400-e29b-41d4-a716-446655440012")
        #expect(captured[3].json["conversationId"] == nil)

        // Persisted conversationId survives cold reload
        store.persistCloudDialogueState(immediately: true)
        store.resetCloudDialogueMemoryState()
        #expect(store.cloudDialogueConversationId == nil)
        store.loadPersistedCloudDialogueState()
        #expect(store.cloudDialogueConversationId == "conv-main-001")

        // Hold an older queued write while the next conversation's send intent is saved synchronously.
        let gate = DispatchSemaphore(value: 0)
        MacGatewayStore.persistenceQueue.async { gate.wait() }
        store.persistCloudDialogueState(forceAsync: true)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { gate.signal() }
        store.cloudDialogueConversationId = "conv-next"
        store.persistCloudDialogueState(immediately: true)
        MacGatewayStore.persistenceQueue.sync {}
        store.loadPersistedCloudDialogueState()
        #expect(store.cloudDialogueConversationId == "conv-next")
    }

    // MARK: - 7. Legacy JSON Backward Compatibility & Full Contract v1 Decoding

    @Test func legacyJSONWithoutV1FieldsAndFullV1JSONBothDecodeCleanly() throws {
        // Legacy dialogue page (zero v1 fields)
        let legacyPageJSON = #"""
        {
          "items": [
            {
              "seq": 1,
              "id": "evt-old-1",
              "kind": "user_message",
              "role": "user",
              "text": "旧版服务端消息",
              "topicId": "topic-old"
            }
          ],
          "nextCursor": 1
        }
        """#
        let legacyPage = try JSONDecoder().decode(MacGatewayCloudDialogueEventsPage.self, from: Data(legacyPageJSON.utf8))
        #expect(legacyPage.items.count == 1)
        #expect(legacyPage.conversationId == nil)
        #expect(legacyPage.epoch == nil)
        #expect(legacyPage.observedSeq == nil)
        let oldEvt = legacyPage.items[0]
        #expect(oldEvt.conversationId == nil)
        #expect(oldEvt.causedByInputId == nil)
        #expect(oldEvt.causedByRequestId == nil)
        #expect(oldEvt.parentRunId == nil)
        #expect(oldEvt.executorKind == nil)
        #expect(oldEvt.executorId == nil)
        #expect(oldEvt.epoch == nil)
        #expect(oldEvt.observedSeq == nil)
        #expect(oldEvt.ledgerId == nil)
        #expect(oldEvt.outcomeUnknown == nil)

        // Legacy receipt (zero v1 fields)
        let legacyReceiptJSON = #"""
        {"eventId":"evt-old-1","requestId":"req-old-1","topicId":"topic-old","workItemIds":[],"state":"received","replayed":false}
        """#
        let legacyReceipt = try JSONDecoder().decode(MacGatewayCloudDialogueReceipt.self, from: Data(legacyReceiptJSON.utf8))
        #expect(legacyReceipt.conversationId == nil)
        #expect(legacyReceipt.outcomeUnknown == nil)

        // Legacy CloudTasks models (zero v1 fields)
        let legacyWorkItemJSON = #"""
        {"id":"work-old","agentId":"main","title":"旧任务","state":"WORKING","progress":"运行中","updatedAtMs":1793500000000}
        """#
        let legacyWorkItem = try JSONDecoder().decode(MacGatewayCloudWorkItem.self, from: Data(legacyWorkItemJSON.utf8))
        #expect(legacyWorkItem.conversationId == nil)
        #expect(legacyWorkItem.parentRunId == nil)
        #expect(legacyWorkItem.outcomeUnknown == nil)

        let legacyDetailJSON = #"""
        {"workItem":\#(legacyWorkItemJSON),"brief":"旧 brief","failure":null,"sessionArchived":false,"resultMarkdown":null}
        """#
        let legacyDetail = try JSONDecoder().decode(MacGatewayCloudWorkDetail.self, from: Data(legacyDetailJSON.utf8))
        #expect(legacyDetail.ledgerId == nil)

        let legacyTaskReceiptJSON = #"""
        {"workItem":\#(legacyWorkItemJSON),"replayed":false}
        """#
        let legacyTaskReceipt = try JSONDecoder().decode(MacGatewayCloudTaskReceipt.self, from: Data(legacyTaskReceiptJSON.utf8))
        #expect(legacyTaskReceipt.causedByRequestId == nil)

        let legacyTimelineJSON = #"""
        {"id":"tl-1","role":"assistant","agentId":"main","text":"旧时间线"}
        """#
        let legacyTimeline = try JSONDecoder().decode(MacGatewayCloudTimelineEntry.self, from: Data(legacyTimelineJSON.utf8))
        #expect(legacyTimeline.executorKind == nil)

        // Legacy persisted envelope (zero v1 fields on progress/followup/submission/envelope)
        let legacyEnvelopeJSON = #"""
        {
          "gatewayId": "gw-1",
          "deviceId": "dev-1",
          "isCloudMainDialogueSelected": true,
          "cursor": 5,
          "events": [],
          "receipts": {},
          "followups": [
            {"requestId":"r1","eventId":"e1","workItemId":"w1","topicId":"t1","text":"旧补充","state":"received","lastError":null}
          ],
          "progressByWorkItem": {
            "w1": {"workItemId":"w1","topicId":"t1","statusLine":"运行中","processEventCount":1,"lastEventSeq":5,"outcome":null}
          },
          "submissions": [
            {"gatewayId":"gw-1","deviceId":"dev-1","kind":"mainMessage","requestId":"m1","workItemId":"w1","text":"hello","receipt":null,"lastError":null,"updatedAt":0}
          ]
        }
        """#
        let legacyEnvelope = try JSONDecoder().decode(MacGatewayCloudDialoguePersistedEnvelope.self, from: Data(legacyEnvelopeJSON.utf8))
        #expect(legacyEnvelope.conversationId == nil)
        #expect(legacyEnvelope.followups.first?.needsReceiptReconciliation == false)
        #expect(legacyEnvelope.followups.first?.isOutcomeUnknown == false)
        #expect(legacyEnvelope.progressByWorkItem["w1"]?.isStopTooLate == false)
        #expect(legacyEnvelope.progressByWorkItem["w1"]?.isOutcomeUnknown == false)
        #expect(legacyEnvelope.submissions.first?.isAbandoned == false)

        // Full Contract v1 JSON decodes every incremental field accurately
        let fullV1EventJSON = #"""
        {
          "seq": 99,
          "id": "evt-v1-full",
          "kind": "stop_too_late",
          "role": "system",
          "text": "停止前已完成",
          "topicId": "topic-v1",
          "workItemId": "work-v1",
          "outcome": "completed",
          "soulRevision": 4,
          "conversationId": "conv-v1",
          "causedByInputId": "in-v1",
          "causedByRequestId": "req-v1",
          "parentRunId": "run-v1",
          "executorKind": "worker",
          "executorId": "exec-v1",
          "epoch": 12,
          "observedSeq": 98,
          "ledgerId": "ledger-v1",
          "outcomeUnknown": false
        }
        """#
        let fullV1Event = try JSONDecoder().decode(MacGatewayCloudDialogueEvent.self, from: Data(fullV1EventJSON.utf8))
        #expect(fullV1Event.kind == .stopTooLate)
        #expect(fullV1Event.conversationId == "conv-v1")
        #expect(fullV1Event.causedByInputId == "in-v1")
        #expect(fullV1Event.causedByRequestId == "req-v1")
        #expect(fullV1Event.parentRunId == "run-v1")
        #expect(fullV1Event.executorKind == "worker")
        #expect(fullV1Event.executorId == "exec-v1")
        #expect(fullV1Event.epoch == 12)
        #expect(fullV1Event.observedSeq == 98)
        #expect(fullV1Event.ledgerId == "ledger-v1")
        #expect(fullV1Event.outcomeUnknown == false)
    }
}
