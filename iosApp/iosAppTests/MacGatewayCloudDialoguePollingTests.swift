import Foundation
import Testing
@testable import iosApp

@Suite("Cloud dialogue idle delivery")
struct MacGatewayCloudDialoguePollingTests {
    @Test(arguments: [false, true])
    @MainActor
    func receivesDelayedResultsWithoutAnotherSend(switchToLocal: Bool) async throws {
        let suite = "CloudDialoguePolling.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        actor Gateway {
            var deliverResult = false
            var polls = 0
            var sends = 0

            func finish() { deliverResult = true }
            func handle(_ request: URLRequest) -> (Data, URLResponse) {
                let url = request.url!
                let json: String
                if request.httpMethod == "POST" {
                    sends += 1
                    json = #"{"eventId":"user-1","requestId":"request-1","topicId":"topic-1","workItemIds":["work:1"],"state":"received","replayed":false}"#
                } else {
                    polls += 1
                    if deliverResult {
                        json = #"{"items":[{"seq":1,"id":"result-1","kind":"task_result","role":"assistant","text":"任务执行失败，请稍后重试","topicId":"topic-1","workItemId":"work:1","outcome":"failed"}],"nextCursor":1}"#
                    } else {
                        json = #"{"items":[],"nextCursor":0}"#
                    }
                }
                return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let gateway = Gateway()
        let store = MacGatewayStore(defaults: defaults)
        let client = MacGatewayClient(addrs: ["cloud.example"], port: 443, fingerprint: "fp", token: "test",
                                      transport: { request, _ in await gateway.handle(request) })
        store.configureForTesting(
            connection: MacGatewayConnection(gatewayId: "test", name: "Cloud", addrs: ["cloud.example"],
                                             port: 443, fingerprint: "fp", deviceId: "test"),
            client: client
        )
        defer { store.stopCloudDialoguePolling() }
        store.setCloudMainDialogueSelected(true)
        _ = try await store.sendCloudDialogueMessage(text: "检查状态", requestId: "request-1").get()
        // Let the independent poller observe an empty page before the result exists.
        for _ in 0..<100 {
            if await gateway.polls > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gateway.polls > 0)
        if switchToLocal { store.setCloudMainDialogueSelected(false) }
        await gateway.finish()

        for _ in 0..<150 {
            if store.cloudDialogueCursor == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.cloudDialogueCursor == 1)
        #expect(store.cloudDialogueVisibleEvents.last?.text == "任务执行失败，请稍后重试")
        #expect(store.cloudDialogueProgressByWorkItem["work:1"]?.outcome == .failed)
        #expect(await gateway.sends == 1, "Delivery must not depend on another user send")
        #expect(store.isCloudMainDialogueSelected == !switchToLocal)
    }

    @Test @MainActor
    func cancelledPollCannotClearItsReplacement() async throws {
        let suite = "CloudDialoguePolling.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacGatewayStore(defaults: defaults)
        let client = MacGatewayClient(addrs: ["cloud.example"], port: 443, fingerprint: "fp", token: "test",
                                      transport: { request, _ in
            try await Task.sleep(for: .seconds(1))
            return (Data(#"{"items":[],"nextCursor":0}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        store.configureForTesting(
            connection: MacGatewayConnection(gatewayId: "test", name: "Cloud", addrs: ["cloud.example"],
                                             port: 443, fingerprint: "fp", deviceId: "test"),
            client: client
        )
        defer { store.stopCloudDialoguePolling() }
        store.setCloudMainDialogueSelected(true)
        await Task.yield()
        store.stopCloudDialoguePolling()
        store.startCloudDialoguePollingIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.cloudDialoguePollTask != nil, "A cancelled poll must not erase the replacement task handle")
    }

    @Test @MainActor
    func upfrontAcknowledgementBeforeWorkItemKeepsPollingAfterSwitchingToLocalAndDirectReplySettlesImmediately() async throws {
        let suite = "CloudDialoguePolling.AckBeforeWork.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        actor AckGateway {
            var stage = 0
            func setStage(_ value: Int) { stage = value }

            func handle(_ request: URLRequest) -> (Data, URLResponse) {
                let url = request.url!
                let path = url.path
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let json: String
                if request.httpMethod == "POST", path == "/v2/dialogue/messages" {
                    if body.contains("00000000-0000-4000-8000-000000000401") {
                        // Initial receipt before Router finishes has empty workItemIds
                        json = #"{"eventId":"evt-u-401","requestId":"00000000-0000-4000-8000-000000000401","topicId":"topic-401","workItemIds":[],"state":"received","replayed":false}"#
                    } else {
                        json = #"{"eventId":"evt-u-402","requestId":"00000000-0000-4000-8000-000000000402","topicId":"topic-402","workItemIds":[],"state":"received","replayed":false}"#
                    }
                } else if path.hasPrefix("/v2/dialogue/receipts/00000000-0000-4000-8000-000000000401") {
                    if stage >= 1 {
                        json = #"{"eventId":"evt-u-401","requestId":"00000000-0000-4000-8000-000000000401","topicId":"topic-401","workItemIds":["work:401"],"state":"consumed","replayed":true}"#
                    } else {
                        json = #"{"eventId":"evt-u-401","requestId":"00000000-0000-4000-8000-000000000401","topicId":"topic-401","workItemIds":[],"state":"received","replayed":true}"#
                    }
                } else if path.hasPrefix("/v2/dialogue/receipts/00000000-0000-4000-8000-000000000402") {
                    json = #"{"eventId":"evt-u-402","requestId":"00000000-0000-4000-8000-000000000402","topicId":"topic-402","workItemIds":[],"state":"consumed","replayed":true}"#
                } else {
                    if stage == 0 {
                        // Upfront acknowledgement arrives BEFORE workItemId exists
                        json = #"""
                        {
                          "items": [
                            {"seq":1,"id":"evt-u-401","kind":"user_message","role":"user","text":"派发后台巡检","topicId":"topic-401","workItemId":null,"outcome":null},
                            {"seq":2,"id":"ack:evt-u-401","kind":"assistant_reply","role":"assistant","text":"收到，我来处理。完成或遇到问题都会在这里告诉你。","topicId":"topic-401","workItemId":null,"outcome":null}
                          ],
                          "nextCursor": 2
                        }
                        """#
                    } else if stage == 1 {
                        json = #"""
                        {
                          "items": [
                            {"seq":3,"id":"result:work:401","kind":"task_result","role":"assistant","text":"合成巡检结果：全部服务正常","topicId":"topic-401","workItemId":"work:401","outcome":"completed"}
                          ],
                          "nextCursor": 3
                        }
                        """#
                    } else {
                        json = #"""
                        {
                          "items": [
                            {"seq":4,"id":"evt-u-402","kind":"user_message","role":"user","text":"直接问一句状态","topicId":"topic-402","workItemId":null,"outcome":null},
                            {"seq":5,"id":"ack:evt-u-402","kind":"assistant_reply","role":"assistant","text":"收到，我来处理。完成或遇到问题都会在这里告诉你。","topicId":"topic-402","workItemId":null,"outcome":null},
                            {"seq":6,"id":"reply:evt-u-402:0","kind":"assistant_reply","role":"assistant","text":"当前一切正常，无需开启后台任务。","topicId":"topic-402","workItemId":null,"outcome":null}
                          ],
                          "nextCursor": 6
                        }
                        """#
                    }
                }
                return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let gateway = AckGateway()
        let store = MacGatewayStore(defaults: defaults)
        let client = MacGatewayClient(
            addrs: ["cloud.example"], port: 443, fingerprint: "fp", token: "test",
            transport: { request, _ in await gateway.handle(request) }
        )
        store.configureForTesting(
            connection: MacGatewayConnection(
                gatewayId: "test", name: "Cloud", addrs: ["cloud.example"],
                port: 443, fingerprint: "fp", deviceId: "test"
            ),
            client: client
        )
        defer { store.stopCloudDialoguePolling() }

        store.setCloudMainDialogueSelected(true)
        _ = try await store.sendCloudDialogueMessage(
            text: "派发后台巡检",
            requestId: "00000000-0000-4000-8000-000000000401"
        ).get()

        // Wait until stage 0 (upfront ack "收到，我来处理...") has been ingested while WorkItem is not yet created.
        for _ in 0..<100 {
            if store.cloudDialogueCursor == 2 { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(store.cloudDialogueCursor == 2)
        #expect(store.isAwaitingCloudMainReply, "Upfront ack before WorkItem appears must keep awaiting state alive")

        // User switches back to local mode BEFORE WorkItem appears; polling must continue and receive stage 1 settlement.
        store.setCloudMainDialogueSelected(false)
        await gateway.setStage(1)

        for _ in 0..<150 {
            if store.cloudDialogueCursor == 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.cloudDialogueCursor == 3)
        #expect(store.cloudDialogueProgressByWorkItem["work:401"]?.outcome == .completed)
        #expect(!store.isAwaitingCloudMainReply)
        #expect(store.activeCloudDialogueWorkItemIds.isEmpty)

        // Direct reply path: once a non-ack assistant_reply arrives without any WorkItem, waiting ends immediately.
        await gateway.setStage(2)
        store.setCloudMainDialogueSelected(true)
        _ = try await store.sendCloudDialogueMessage(
            text: "直接问一句状态",
            requestId: "00000000-0000-4000-8000-000000000402"
        ).get()
        store.stopCloudDialoguePolling()
        _ = try await store.pollCloudDialogueEvents().get()
        #expect(store.cloudDialogueCursor == 6)
        #expect(!store.isAwaitingCloudMainReply, "Ordinary direct reply must end waiting immediately without hanging on a non-existent task")
        #expect(store.activeCloudDialogueWorkItemIds.isEmpty)
    }

    @Test @MainActor
    func idlePollingBacksOffToCapAndSuspendsOnlyWhenBackgroundIdle() async throws {
        let suite = "CloudDialoguePolling.Backoff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        actor PollCounter {
            var count = 0
            var emitEventOnce = false
            func requestNextEvent() { emitEventOnce = true }
            func reset() { count = 0 }
            func handle(_ request: URLRequest) -> (Data, URLResponse) {
                count += 1
                let json: String
                if emitEventOnce {
                    emitEventOnce = false
                    json = #"{"items":[{"seq":1,"id":"evt-1","kind":"assistant_reply","role":"assistant","text":"新事件","topicId":"topic-1","workItemId":null,"outcome":null}],"nextCursor":1}"#
                } else {
                    json = #"{"items":[],"nextCursor":0}"#
                }
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let counter = PollCounter()
        let store = MacGatewayStore(defaults: defaults)
        let client = MacGatewayClient(
            addrs: ["cloud.example"], port: 443, fingerprint: "fp", token: "test",
            transport: { req, _ in await counter.handle(req) }
        )
        store.configureForTesting(
            connection: MacGatewayConnection(
                gatewayId: "test", name: "Cloud", addrs: ["cloud.example"],
                port: 443, fingerprint: "fp", deviceId: "test"
            ),
            client: client
        )
        defer { store.stopCloudDialoguePolling() }

        // Default foreground backoff ladder: 1s -> 2s -> 3s -> 5s (capped at 5s).
        #expect(store.currentCloudDialoguePollInterval() == .seconds(1))
        store.cloudDialogueIdlePollStreak = 1
        #expect(store.currentCloudDialoguePollInterval() == .seconds(2))
        store.cloudDialogueIdlePollStreak = 2
        #expect(store.currentCloudDialoguePollInterval() == .seconds(3))
        store.cloudDialogueIdlePollStreak = 3
        #expect(store.currentCloudDialoguePollInterval() == .seconds(5))
        store.cloudDialogueIdlePollStreak = 99
        #expect(store.currentCloudDialoguePollInterval() == .seconds(5))

        // Active work item keeps polling at 1s regardless of streak.
        store.cloudDialogueEvents = [
            MacGatewayCloudDialogueEvent(
                seq: 1, id: "evt-live-1", kind: .processEvent, role: "assistant",
                text: "执行中", topicId: "t-live", workItemId: "work:live"
            )
        ]
        store.cloudDialogueProgressByWorkItem["work:live"] = MacGatewayCloudDialogueWorkItemProgress(
            workItemId: "work:live", topicId: "t-live", statusLine: "执行中",
            processEventCount: 1, lastEventSeq: 1, outcome: nil
        )
        #expect(store.currentCloudDialoguePollInterval() == .seconds(1))
        store.cloudDialogueEvents.removeAll()
        store.cloudDialogueProgressByWorkItem.removeAll()

        // Use accelerated steps to verify real loop progression, reset, background pause, and foreground resume.
        store.cloudDialoguePollStepDurations = [.milliseconds(15), .milliseconds(30), .milliseconds(45), .milliseconds(80)]
        store.cloudDialogueIdlePollStreak = 0
        store.setCloudMainDialogueSelected(true)
        for _ in 0..<100 {
            if store.cloudDialogueIdlePollStreak >= 3 { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(store.cloudDialogueIdlePollStreak == 3)

        // Delivering a new event resets backoff streak to 0.
        await counter.requestNextEvent()
        for _ in 0..<100 {
            if store.cloudDialogueCursor == 1 { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(store.cloudDialogueCursor == 1)
        #expect(store.cloudDialogueIdlePollStreak <= 1)

        // Entering background while idle pauses polling completely.
        store.setAppInBackground(true)
        #expect(store.cloudDialoguePollTask == nil)
        await counter.reset()
        try await Task.sleep(for: .milliseconds(60))
        #expect(await counter.count == 0, "Background idle must suspend cloud dialogue polling")

        // Returning to foreground resets backoff and performs an immediate catch-up poll.
        store.setAppInBackground(false)
        #expect(store.cloudDialoguePollTask != nil)
        #expect(store.cloudDialogueIdlePollStreak == 0)
        for _ in 0..<50 {
            if await counter.count >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await counter.count >= 1)

        // Entering background with an active workItem must NOT pause polling.
        store.cloudDialogueProgressByWorkItem["work:active-bg"] = MacGatewayCloudDialogueWorkItemProgress(
            workItemId: "work:active-bg", topicId: "t-bg", statusLine: "运行中",
            processEventCount: 1, lastEventSeq: 2, outcome: nil
        )
        store.cloudDialogueEvents.append(
            MacGatewayCloudDialogueEvent(
                seq: 2, id: "evt-bg-work", kind: .processEvent, role: "assistant",
                text: "运行中", topicId: "t-bg", workItemId: "work:active-bg"
            )
        )
        store.setAppInBackground(true)
        #expect(store.shouldPollCloudDialogue, "Active workItem in background must keep polling alive")
        #expect(store.cloudDialoguePollTask != nil)
    }

    @Test @MainActor
    func memoryWindowTrimsTerminalHistoryWhileExemptingUnsettledAndOutcomeUnknownRecords() async throws {
        let suite = "CloudDialoguePolling.WindowTrim.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MacGatewayStore(defaults: defaults)
        let connection = MacGatewayConnection(
            gatewayId: "gw-trim", name: "Cloud", addrs: ["cloud.example"],
            port: 443, fingerprint: "fp", deviceId: "dev-trim"
        )
        let client = MacGatewayClient(
            addrs: ["cloud.example"], port: 443, fingerprint: "fp", token: "test",
            transport: { req, _ in
                (Data(#"{"error":"not_found"}"#.utf8), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        )
        store.configureForTesting(connection: connection, client: client)

        let now = Date()
        var events: [MacGatewayCloudDialogueEvent] = []
        // Early protected records (seq 1..4) that must survive window trimming:
        events.append(MacGatewayCloudDialogueEvent(
            seq: 1, id: "evt-live-work", kind: .userMessage, role: "user",
            text: "活跃任务", topicId: "topic-live", workItemId: "work:live"
        ))
        events.append(MacGatewayCloudDialogueEvent(
            seq: 2, id: "evt-unknown", kind: .taskResult, role: "assistant",
            text: "结果待确认", topicId: "topic-unknown", workItemId: "work:unknown", outcomeUnknown: true
        ))
        events.append(MacGatewayCloudDialogueEvent(
            seq: 3, id: "evt-unconfirmed-receipt", kind: .followup, role: "user",
            text: "待对账补充", topicId: "topic-followup", workItemId: "work:done-old", causedByRequestId: "req-followup-pending"
        ))
        events.append(MacGatewayCloudDialogueEvent(
            seq: 4, id: "evt-pending-sub", kind: .userMessage, role: "user",
            text: "待确认主消息", topicId: "topic-sub-pending"
        ))

        // 450 ordinary settled terminal events.
        for seq in Int64(5)...Int64(454) {
            events.append(MacGatewayCloudDialogueEvent(
                seq: seq, id: "evt-settled-\(seq)", kind: .assistantReply, role: "assistant",
                text: "历史回复 \(seq)", topicId: "topic-settled-\(seq)"
            ))
        }

        store.cloudDialogueEvents = events
        for evt in events {
            store.cloudDialogueFirstSeenAtByEventId[evt.id] = now
            store.cloudDialogueEntranceEventIds.insert(evt.id)
        }
        store.cloudDialogueProgressByWorkItem["work:live"] = MacGatewayCloudDialogueWorkItemProgress(
            workItemId: "work:live", topicId: "topic-live", statusLine: "运行中",
            processEventCount: 1, lastEventSeq: 1, outcome: nil
        )
        store.cloudDialogueProgressByWorkItem["work:unknown"] = MacGatewayCloudDialogueWorkItemProgress(
            workItemId: "work:unknown", topicId: "topic-unknown", statusLine: "待核实",
            processEventCount: 1, lastEventSeq: 2, outcome: nil, isOutcomeUnknown: true
        )
        store.cloudDialogueFollowups = [
            MacGatewayCloudDialogueFollowupRecord(
                requestId: "req-followup-pending", eventId: "evt-unconfirmed-receipt",
                workItemId: "work:done-old", topicId: "topic-followup",
                text: "待对账补充", state: .received, lastError: nil, needsReceiptReconciliation: true
            )
        ]
        store.cloudDialogueSubmissions = [
            MacGatewayCloudDialoguePersistedSubmission(
                gatewayId: connection.gatewayId, deviceId: connection.deviceId,
                kind: .mainMessage, requestId: "req-sub-pending", workItemId: nil,
                text: "待确认主消息", receipt: nil, lastError: nil, updatedAt: now
            )
        ]
        store.cloudDialogueReceipts["req-sub-pending"] = MacGatewayCloudDialogueReceipt(
            eventId: "evt-pending-sub", requestId: "req-sub-pending",
            topicId: "topic-sub-pending", workItemIds: [], state: .received, replayed: false
        )

        let didTrim = store.trimCloudDialogueMemoryWindowIfNeeded(maxEvents: 400)
        #expect(didTrim)

        let keptIds = Set(store.cloudDialogueEvents.map(\.id))
        // Window keeps 400 tail events + 4 protected early events = 404.
        #expect(store.cloudDialogueEvents.count == 404)
        #expect(keptIds.contains("evt-live-work"))
        #expect(keptIds.contains("evt-unknown"))
        #expect(keptIds.contains("evt-unconfirmed-receipt"))
        #expect(keptIds.contains("evt-pending-sub"))
        #expect(!keptIds.contains("evt-settled-5"), "Old settled events outside the 400-event window should be trimmed")
        #expect(keptIds.contains("evt-settled-454"))
        #expect(store.cloudDialogueFirstSeenAtByEventId["evt-settled-5"] == nil)
        #expect(!store.cloudDialogueEntranceEventIds.contains("evt-settled-5"))
        #expect(store.cloudDialogueFirstSeenAtByEventId["evt-live-work"] != nil)
        #expect(store.cloudDialogueSubmissions.contains { $0.requestId == "req-sub-pending" })
        #expect(store.cloudDialogueReceipts["req-sub-pending"] != nil)
        #expect(store.cloudDialogueFollowups.contains { $0.requestId == "req-followup-pending" })

        // Verify terminal cloudTask with detail == nil backs off and stops retrying after maxTerminalDetailBackfillRetries.
        let terminalItem = MacGatewayCloudWorkItem(
            id: "work:terminal-missing-detail", agentId: "main", title: "旧任务",
            state: .completed, updatedAtMs: Int64(now.timeIntervalSince1970 * 1_000)
        )
        store.cloudTasks = [
            MacGatewayCloudTaskRecord(
                gatewayId: connection.gatewayId, deviceId: connection.deviceId,
                request: MacGatewayCloudTaskRequest(requestId: "req-term-1", text: "旧任务"),
                workItemId: terminalItem.id, workItem: terminalItem, detail: nil,
                replayed: false, lastError: nil, createdAt: now, updatedAt: now
            )
        ]
        await store.refreshActiveCloudTasks(now: now)
        #expect(store.terminalCloudTaskDetailRetryState[terminalItem.id]?.failureCount == 1)
        // Immediate retry before backoff expires is skipped.
        await store.refreshActiveCloudTasks(now: now)
        #expect(store.terminalCloudTaskDetailRetryState[terminalItem.id]?.failureCount == 1)
        // Advance time past each retry until hitting maxTerminalDetailBackfillRetries.
        for step in 2...MacGatewayStore.maxTerminalDetailBackfillRetries {
            await store.refreshActiveCloudTasks(now: now.addingTimeInterval(Double(step) * 30))
            #expect(store.terminalCloudTaskDetailRetryState[terminalItem.id]?.failureCount == step)
        }
        // Further automatic refreshes stop permanently after hitting the retry cap.
        await store.refreshActiveCloudTasks(now: now.addingTimeInterval(600))
        #expect(store.terminalCloudTaskDetailRetryState[terminalItem.id]?.failureCount == MacGatewayStore.maxTerminalDetailBackfillRetries)
    }
}
