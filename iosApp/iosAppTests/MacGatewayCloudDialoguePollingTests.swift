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
}
