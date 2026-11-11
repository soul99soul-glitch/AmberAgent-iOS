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
}
