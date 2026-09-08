import Combine
import XCTest
@testable import iosApp

private final class WatchFlowTransport: WatchConnectivityTransporting {
    var isSupported = true
    var isPaired = true
    var isWatchAppInstalled = true
    var isReachable = false
    var actions: [WatchTaskActionRequest] = []
    var queued: [WatchTaskActionRequest] = []
    var lastReply: (([String: Any]) -> Void)?
    var lastError: ((Error) -> Void)?
    func activate() {}
    func updateApplicationContext(_ context: [String: Any]) throws {}
    func transferUserInfo(_ userInfo: [String: Any]) -> String {
        if let data = userInfo[WatchConnectivityPayloadKey.action] as? Data,
           let request = try? WatchTaskCodec.decodeAction(data) { queued.append(request) }
        return UUID().uuidString
    }
    func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?, errorHandler: ((Error) -> Void)?) {
        guard let data = message[WatchConnectivityPayloadKey.action] as? Data,
              let request = try? WatchTaskCodec.decodeAction(data) else { return }
        actions.append(request)
        lastReply = replyHandler
        lastError = errorHandler
    }
}

@MainActor
final class WatchCompanionFlowTests: XCTestCase {
    func testInitialSyncHasLoadingStateUntilPhoneSnapshotArrives() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = WatchFlowTransport()
        transport.isReachable = true
        let bridge = WatchConnectivityBridge()
        bridge.configure(transport: transport)
        let model = WatchTaskViewModel(bridge: bridge, store: WatchLocalStore(fileURL: root.appendingPathComponent("state.json")))
        model.start()
        XCTAssertTrue(model.isRefreshing)
        XCTAssertNil(model.library)
        var ready = WatchTaskSnapshot.idle
        ready.library = WatchLibrarySnapshot(assistantName: "Amber", isConfigured: true,
            quickActions: [], recent: [], updatedAt: Date())
        bridge.publish(ready)
        bridge.onSnapshotUpdated?(bridge.latestSnapshot)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertNotNil(model.library)
    }

    func testOldCancelDialogAndOldChoiceCannotActOnNewRunOrDecision() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = WatchFlowTransport()
        transport.isReachable = true
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000)
        bridge.configure(transport: transport)
        var snapshot = WatchTaskSnapshot.idle
        snapshot.runId = "new-run"
        snapshot.phase = "waitingForUser"
        snapshot.updatedAt = Date()
        snapshot.decision = WatchDecision(id: "new-decision", type: .askUser, title: "Question",
            body: "New question", options: [], riskLevel: .low, allowsVoice: true)
        bridge.publish(snapshot)
        let model = WatchTaskViewModel(bridge: bridge, store: WatchLocalStore(fileURL: root.appendingPathComponent("state.json")))
        model.start()
        model.perform(.cancel, expectedRunId: "old-run")
        model.perform(.choose, optionId: "choice-0", expectedRunId: "new-run", expectedDecisionId: "old-decision")
        model.draftAnswer = "新问题的答案"
        model.submitAnswer(runId: "new-run", decisionId: "old-decision")
        XCTAssertTrue(transport.actions.isEmpty)
        XCTAssertEqual(model.draftAnswer, "新问题的答案")
    }

    func testOfflineNoteFlowWritesOriginalBeforeQueueingAndOnlyAckMarksSynced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("watch.json")
        let store = WatchLocalStore(fileURL: file)
        let transport = WatchFlowTransport()
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000)
        bridge.configure(transport: transport)
        let model = WatchTaskViewModel(bridge: bridge, store: store)
        model.start()
        model.compose(mode: .note)
        store.updateDraftText(key: "note", text: "  一个想法\n第二行原文  ")
        model.submitDraft(key: "note")
        let note = try XCTUnwrap(store.notes.first)
        XCTAssertEqual(note.text, "  一个想法\n第二行原文  ")
        XCTAssertNil(note.syncedAt)
        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertEqual(transport.queued.count, 1)
        XCTAssertEqual(transport.queued.first?.requestId, note.id)
        let restarted = WatchLocalStore(fileURL: file)
        XCTAssertEqual(restarted.notes.first?.text, note.text)
        XCTAssertNil(restarted.notes.first?.syncedAt)
        bridge.onActionResult?(WatchTaskActionResult(
            requestId: note.id, runId: "", accepted: true, message: nil, snapshot: nil
        ))
        XCTAssertNotNil(store.notes.first?.syncedAt)
        XCTAssertNotNil(WatchLocalStore(fileURL: file).notes.first?.syncedAt)
    }

    func testUncertainQuestionRetryUsesIdenticalPayloadAndAcceptedReplyRemovesDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WatchLocalStore(fileURL: root.appendingPathComponent("watch.json"))
        let transport = WatchFlowTransport()
        transport.isReachable = true
        let bridge = WatchConnectivityBridge(actionTimeoutNanoseconds: 2_000_000_000)
        bridge.configure(transport: transport)
        var ready = WatchTaskSnapshot.idle
        ready.library = WatchLibrarySnapshot(assistantName: "Amber", isConfigured: true, quickActions: [], recent: [], updatedAt: Date())
        bridge.publish(ready)
        let model = WatchTaskViewModel(bridge: bridge, store: store)
        model.start()
        model.compose(mode: .ask)
        store.updateDraftText(key: "ask", text: "为什么天空是蓝色的？")
        model.submitDraft(key: "ask")
        let first = try XCTUnwrap(transport.actions.first)
        let timedOut = expectation(description: "uncertain result")
        var observation: AnyCancellable? = model.$isSending.dropFirst().filter { !$0 }.sink { _ in timedOut.fulfill() }
        transport.lastError?(NSError(domain: "WatchFlowTest", code: 1))
        await fulfillment(of: [timedOut], timeout: 1)
        observation?.cancel()
        XCTAssertEqual(store.draft(forKey: "ask")?.deliveryUnknown, true)
        XCTAssertFalse(store.updateDraftText(key: "ask", text: "不能改变已经发送的请求"))
        model.submitDraft(key: "ask")
        XCTAssertEqual(transport.actions.count, 2)
        XCTAssertEqual(transport.actions.last, first)
        let accepted = expectation(description: "accepted query")
        observation = model.$isSending.dropFirst().filter { !$0 }.sink { _ in accepted.fulfill() }
        transport.lastReply?(try WatchTaskCodec.resultMessage(for: WatchTaskActionResult(
            requestId: first.requestId, runId: "started-run", accepted: true,
            message: "已发送", snapshot: nil, conversationId: "conversation"
        )))
        await fulfillment(of: [accepted], timeout: 1)
        observation?.cancel()
        XCTAssertNil(store.draft(forKey: "ask"))
        XCTAssertEqual(model.path, [.task("started-run")])
    }

    func testAnswerDraftSurvivesStalePresentationAndReconnectToSameDecision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = WatchFlowTransport()
        transport.isReachable = true
        let bridge = WatchConnectivityBridge()
        bridge.configure(transport: transport)
        var waiting = WatchTaskSnapshot.idle
        waiting.runId = "answer-run"
        waiting.phase = "waitingForUser"
        waiting.updatedAt = Date()
        waiting.decision = WatchDecision(id: "question-1", type: .askUser, title: "Question",
            body: "Choose a destination", options: [], riskLevel: .low, allowsVoice: true)
        bridge.publish(waiting)
        let model = WatchTaskViewModel(bridge: bridge, store: WatchLocalStore(fileURL: root.appendingPathComponent("state.json")))
        model.start()
        model.draftAnswer = "我已经写好的回答"
        transport.isReachable = false
        waiting.updatedAt = Date().addingTimeInterval(-61)
        bridge.publish(waiting)
        bridge.onSnapshotUpdated?(bridge.latestSnapshot)
        XCTAssertTrue(model.snapshot.isStale)
        XCTAssertNil(model.snapshot.decision)
        transport.isReachable = true
        bridge.onReachabilityChanged?(true)
        XCTAssertEqual(model.draftAnswer, "我已经写好的回答")
        waiting.decision?.id = "question-2"
        bridge.publish(waiting)
        bridge.onSnapshotUpdated?(bridge.latestSnapshot)
        XCTAssertTrue(model.draftAnswer.isEmpty)
    }

    func testWidgetCacheRedactsContentAndAcceptsFirstRevisionAfterIdle() throws {
        let suite = "WatchWidgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(WatchWidgetCache.save(.idle, defaults: defaults))
        var snapshot = WatchTaskSnapshot.idle
        snapshot.runId = "run"
        snapshot.conversationId = "private-conversation"
        snapshot.phase = "waitingForUser"
        snapshot.summary = "private answer"
        snapshot.sequence = 1
        snapshot.library = WatchLibrarySnapshot(assistantName: "private assistant", isConfigured: true,
            quickActions: [WatchQuickAction(id: "private", title: "private", prompt: "private prompt")], recent: [], updatedAt: Date())
        snapshot.decision = WatchDecision(id: "decision", type: .approval, title: "private action", body: "private body", options: [], riskLevel: .high, allowsVoice: false)
        XCTAssertTrue(WatchWidgetCache.save(snapshot, defaults: defaults))
        let restored = try XCTUnwrap(WatchWidgetCache.load(defaults: defaults))
        XCTAssertEqual(restored.runId, "run")
        XCTAssertEqual(restored.sequence, 1)
        XCTAssertNil(restored.library)
        XCTAssertNil(restored.conversationId)
        XCTAssertNil(restored.decision)
        XCTAssertNil(restored.summary)
        var conflicting = snapshot
        conflicting.phase = "running"
        XCTAssertTrue(WatchWidgetCache.save(conflicting, defaults: defaults))
        XCTAssertEqual(WatchWidgetCache.load(defaults: defaults)?.phase, "waitingForUser")
    }
}
