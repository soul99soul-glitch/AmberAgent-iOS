import Foundation
import XCTest
@preconcurrency import GatewayCore
@testable import AmberMac

@MainActor
final class DesktopMacDialogueTests: XCTestCase {
    // Mirror of iosApp/iosApp/MacGatewayCloudDialogue.swift Codable models for strict wire-contract decoding verification.
    private struct IOSReceiptMirror: Codable, Equatable {
        enum State: String, Codable { case received, consumed, cancelled }
        var eventId: String
        var requestId: String
        var topicId: String
        var workItemIds: [String]
        var state: State
        var replayed: Bool
        var soulRevision: Int64?
        var conversationId: String?
        var causedByInputId: String?
        var causedByRequestId: String?
        var parentRunId: String?
        var executorKind: String?
        var executorId: String?
        var epoch: Int64?
        var observedSeq: Int64?
        var ledgerId: String?
        var outcomeUnknown: Bool?
    }

    private struct IOSEventMirror: Codable, Equatable {
        enum Kind: String, Codable {
            case userMessage = "user_message"
            case followup = "followup"
            case stopRequested = "stop_requested"
            case stopTooLate = "stop_too_late"
            case assistantReply = "assistant_reply"
            case inputConsumed = "input_consumed"
            case inputCancelled = "input_cancelled"
            case processEvent = "process_event"
            case taskResult = "task_result"
            case unknown
            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Self(rawValue: raw) ?? .unknown
            }
        }
        enum Outcome: String, Codable {
            case completed, blocked, failed, cancelled, unknown
            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Self(rawValue: raw) ?? .unknown
            }
        }
        var seq: Int64
        var id: String
        var kind: Kind
        var role: String
        var text: String
        var topicId: String
        var workItemId: String?
        var outcome: Outcome?
        var soulRevision: Int64?
        var conversationId: String?
        var causedByInputId: String?
        var causedByRequestId: String?
        var parentRunId: String?
        var executorKind: String?
        var executorId: String?
        var epoch: Int64?
        var observedSeq: Int64?
        var ledgerId: String?
        var outcomeUnknown: Bool?
        var sourceRefs: [String]?
        var sourcePaths: [String]?
    }

    private struct IOSPageMirror: Codable, Equatable {
        var items: [IOSEventMirror]
        var nextCursor: Int64
        var soulRevision: Int64?
    }

    private func tempDir(_ prefix: String = "mac-dialogue") -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func encodeJSON(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 1. Contract Invariants, Persistence, Soul Revision & iOS Wire Compatibility

    func testIdempotencyConflictStaleEpochTerminalProtectionAndRestartPersistence() async throws {
        let dir = tempDir()
        let stateFile = dir.appendingPathComponent("mac-dialogue-state.json")
        let soulStore = DesktopAgentSoulStore(directory: dir.appendingPathComponent("soul", isDirectory: true))
        _ = try soulStore.update(displayName: "MacAmber", tagline: "本地执行者", source: "test")
        XCTAssertEqual(soulStore.revision, 1)

        let paths = GatewayPaths(stateDir: dir.appendingPathComponent("gw", isDirectory: true))
        let tasks = DesktopAgentTasks(defaults: UserDefaults(suiteName: "amber.dialogue.test.\(UUID().uuidString)")!)
        await tasks.waitUntilLoaded()
        let reporter = DesktopGatewayReporter(paths: paths, isEnabled: { false }, process: nil)

        let coordinator = DesktopMacDialogueCoordinator(
            fileURL: stateFile,
            executorId: "mac-node-test",
            soulRevisionProvider: { soulStore.revision }
        )
        let control = DesktopGatewayControl(paths: paths, tasks: tasks, reporter: reporter, scheduler: nil)
        control.soulStore = soulStore
        control.dialogue = coordinator

        // 1. Submit message (v1) -> 202 + decodes cleanly into iOS mirror
        let msgBody = try encodeJSON(["requestId": "req-msg-1", "text": "帮我检查工程", "conversationId": "conv-1", "epoch": 2])
        let msgResp = await control.handle(.init(
            action: .dialogueMessage, deviceName: "iPhone", deviceId: "dev-1",
            dialogueVersion: "1", rawBody: msgBody
        ))
        XCTAssertEqual(msgResp.status, 202)
        let msgReceipt = try JSONDecoder().decode(IOSReceiptMirror.self, from: Data(try XCTUnwrap(msgResp.rawJSON).utf8))
        XCTAssertEqual(msgReceipt.requestId, "req-msg-1")
        XCTAssertEqual(msgReceipt.state, .received)
        XCTAssertFalse(msgReceipt.replayed)
        XCTAssertEqual(msgReceipt.executorKind, "mac")
        XCTAssertEqual(msgReceipt.executorId, "mac-node-test")
        XCTAssertEqual(msgReceipt.soulRevision, 1)
        XCTAssertEqual(msgReceipt.conversationId, "conv-1")
        let workItemId = try XCTUnwrap(msgReceipt.workItemIds.first)

        // 2. Replay same (deviceId, requestId, payload) -> 200 replayed=true
        let replayResp = await control.handle(.init(
            action: .dialogueMessage, deviceName: "iPhone", deviceId: "dev-1",
            dialogueVersion: "1", rawBody: msgBody
        ))
        XCTAssertEqual(replayResp.status, 200)
        let replayedReceipt = try JSONDecoder().decode(IOSReceiptMirror.self, from: Data(try XCTUnwrap(replayResp.rawJSON).utf8))
        XCTAssertTrue(replayedReceipt.replayed)
        XCTAssertEqual(replayedReceipt.eventId, msgReceipt.eventId)

        // 3. Same (deviceId, requestId) with different payload -> 409 request_id_conflict
        let conflictResp = await control.handle(.init(
            action: .dialogueMessage, deviceName: "iPhone", deviceId: "dev-1",
            dialogueVersion: "1", rawBody: try encodeJSON(["requestId": "req-msg-1", "text": "篡改内容", "conversationId": "conv-1", "epoch": 2])
        ))
        XCTAssertEqual(conflictResp.status, 409)
        XCTAssertEqual(conflictResp.error, "request_id_conflict")

        // 4. Stale epoch (< 2) -> 409 stale_epoch
        let staleResp = await control.handle(.init(
            action: .dialogueFollowup, deviceName: "iPhone", deviceId: "dev-1",
            dialogueVersion: "1", workItemId: workItemId,
            rawBody: try encodeJSON(["requestId": "req-stale", "text": "旧代际补充", "epoch": 1])
        ))
        XCTAssertEqual(staleResp.status, 409)
        XCTAssertEqual(staleResp.error, "stale_epoch")

        // 5. Missing workItemId / missing receipt / invalid cursor
        let missingTask = await control.handle(.init(
            action: .dialogueFollowup, deviceName: "iPhone", deviceId: "dev-1",
            dialogueVersion: "1", workItemId: "work:nope",
            rawBody: try encodeJSON(["requestId": "req-nf", "text": "hi"])
        ))
        XCTAssertEqual(missingTask.status, 404)
        XCTAssertEqual(missingTask.error, "task_not_found")

        let missingReceipt = await control.handle(.init(
            action: .dialogueReceipt, deviceName: "iPhone", deviceId: "dev-1",
            dialogueVersion: "1", requestId: "req-unknown"
        ))
        XCTAssertEqual(missingReceipt.status, 404)
        XCTAssertEqual(missingReceipt.error, "receipt_not_found")

        let badCursor = await control.handle(.init(
            action: .dialogueEvents, deviceName: "iPhone", deviceId: "dev-1",
            dialogueVersion: "1", after: -1, limit: 10
        ))
        XCTAssertEqual(badCursor.status, 400)
        XCTAssertEqual(badCursor.error, "invalid_cursor")

        // 6. Settle as completed, then test late followup (v1 vs legacy) and stop_too_late (v1 vs legacy)
        coordinator.settle(workItemId: workItemId, outcome: "completed", text: "已完成检查。")

        // v1 followup after completion -> 200 + state=cancelled + input_cancelled with causedByInputId/causedByRequestId
        let lateFollowupV1 = await control.handle(.init(
            action: .dialogueFollowup, deviceName: "iPhone", deviceId: "dev-1",
            dialogueVersion: "1", workItemId: workItemId,
            rawBody: try encodeJSON(["requestId": "req-late-f-v1", "text": "迟到的补充"])
        ))
        XCTAssertEqual(lateFollowupV1.status, 200)
        let lateFollowupReceipt = try JSONDecoder().decode(IOSReceiptMirror.self, from: Data(try XCTUnwrap(lateFollowupV1.rawJSON).utf8))
        XCTAssertEqual(lateFollowupReceipt.state, .cancelled)

        // legacy followup after completion -> 409 task_terminal
        let lateFollowupLegacy = await control.handle(.init(
            action: .dialogueFollowup, deviceName: "iPhone", deviceId: "dev-1",
            dialogueVersion: nil, workItemId: workItemId,
            rawBody: try encodeJSON(["requestId": "req-late-f-legacy", "text": "旧端迟到补充"])
        ))
        XCTAssertEqual(lateFollowupLegacy.status, 409)
        XCTAssertEqual(lateFollowupLegacy.error, "task_terminal")

        // v1 stop after completion -> 200 + state=cancelled + stop_too_late; completed state preserved!
        let lateStopV1 = await control.handle(.init(
            action: .dialogueStop, deviceName: "iPhone", deviceId: "dev-1",
            dialogueVersion: "1", workItemId: workItemId,
            rawBody: try encodeJSON(["requestId": "req-late-stop-v1"])
        ))
        XCTAssertEqual(lateStopV1.status, 200)
        let lateStopReceipt = try JSONDecoder().decode(IOSReceiptMirror.self, from: Data(try XCTUnwrap(lateStopV1.rawJSON).utf8))
        XCTAssertEqual(lateStopReceipt.state, .cancelled)
        XCTAssertEqual(coordinator.workItem(workItemId)?.lifecycle, .completed, "stop_too_late must never overwrite completed state")

        // 7. Verify v1 events page decodes cleanly into IOSPageMirror with causal IDs & soulRevision
        let pageResp = await control.handle(.init(
            action: .dialogueEvents, deviceName: "iPhone", deviceId: "dev-1",
            dialogueVersion: "1", after: 0, limit: 100
        ))
        XCTAssertEqual(pageResp.status, 200)
        let v1Page = try JSONDecoder().decode(IOSPageMirror.self, from: Data(try XCTUnwrap(pageResp.rawJSON).utf8))
        XCTAssertEqual(v1Page.soulRevision, 1)
        let cancelledEvent = try XCTUnwrap(v1Page.items.first { $0.kind == .inputCancelled && $0.causedByRequestId == "req-late-f-v1" })
        XCTAssertEqual(cancelledEvent.causedByInputId, lateFollowupReceipt.eventId)
        let stopTooLateEvent = try XCTUnwrap(v1Page.items.first { $0.kind == .stopTooLate })
        XCTAssertEqual(stopTooLateEvent.causedByInputId, lateStopReceipt.eventId)
        XCTAssertEqual(stopTooLateEvent.causedByRequestId, "req-late-stop-v1")

        // Legacy events page omits stop_too_late, run_finished, and the closed-on-arrival stop_requested
        let legacyPageResp = await control.handle(.init(
            action: .dialogueEvents, deviceName: "iPhone", deviceId: "dev-1",
            dialogueVersion: nil, after: 0, limit: 100
        ))
        let legacyPage = try JSONDecoder().decode(IOSPageMirror.self, from: Data(try XCTUnwrap(legacyPageResp.rawJSON).utf8))
        XCTAssertFalse(legacyPage.items.contains { $0.kind == .stopTooLate || $0.kind == .stopRequested })

        // 8. Restart persistence: reload coordinator from disk and query receipt + paginated events
        let reloaded = DesktopMacDialogueCoordinator(
            fileURL: stateFile,
            executorId: "mac-node-test",
            soulRevisionProvider: { soulStore.revision }
        )
        let persistedReceipt = try XCTUnwrap(reloaded.receipt(deviceId: "dev-1", requestId: "req-msg-1"))
        XCTAssertEqual(persistedReceipt.eventId, msgReceipt.eventId)
        XCTAssertTrue(persistedReceipt.replayed)
        let reloadedPage = try reloaded.page(after: 0, limit: 100)
        XCTAssertEqual(reloadedPage.items.count, v1Page.items.count)
        XCTAssertEqual(reloadedPage.nextCursor, v1Page.nextCursor)
    }

    // MARK: - 2. Local Agent Bridge: Missing Provider Fails Clearly (Never Stalls)

    func testMissingProviderProducesClearFailedTaskResult() async throws {
        let dir = tempDir("no-provider")
        let settings = DesktopSettings(
            defaults: UserDefaults(suiteName: "amber.dialogue.noprovider.\(UUID().uuidString)")!,
            credentials: DesktopMemoryCredentials()
        )
        let provider = StubDialogueProvider()
        let workspace = DesktopWorkspace(
            settings: settings,
            storage: DesktopMemoryConversationStorage(),
            provider: provider,
            initialConversations: []
        )
        let coordinator = DesktopMacDialogueCoordinator(
            fileURL: dir.appendingPathComponent("state.json"),
            executorId: "mac-local",
            soulRevisionProvider: { workspace.agentSoul.revision }
        )
        workspace.attachMacDialogue(coordinator)

        let (status, receipt) = try coordinator.submit(
            deviceId: "ios-1", requestId: "req-no-provider", text: "运行构建", kind: "message"
        )
        XCTAssertEqual(status, 202)
        let workItemId = try XCTUnwrap(receipt.workItemIds.first)

        try await waitUntil {
            coordinator.workItem(workItemId)?.lifecycle == .failed
        }
        let page = try coordinator.page(after: 0, limit: 50)
        let result = try XCTUnwrap(page.items.first { $0.kind == "task_result" && $0.workItemId == workItemId })
        XCTAssertEqual(result.outcome, "failed")
        XCTAssertEqual(result.executorKind, "mac")
        XCTAssertTrue(result.text.contains("尚未配置") || result.text.contains("API Key") || result.text.contains("Model ID"))
        XCTAssertTrue(page.items.contains { $0.kind == "run_finished" && $0.outcome == "failed" })
    }

    // MARK: - 3. Local Agent Bridge: Followup Consumption, Completion & Live Stop

    func testLocalAgentBridgeConsumesFollowupAndCompletesThenSupportsStopCancellation() async throws {
        let dir = tempDir("bridge")
        let settings = DesktopSettings(
            defaults: UserDefaults(suiteName: "amber.dialogue.bridge.\(UUID().uuidString)")!,
            credentials: DesktopMemoryCredentials()
        )
        var providerConfig = try XCTUnwrap(settings.selectedProvider)
        providerConfig.modelID = "stub-model"
        try settings.saveProvider(providerConfig, apiKey: "test-key")

        let provider = StubDialogueProvider()
        let workspace = DesktopWorkspace(
            settings: settings,
            storage: DesktopMemoryConversationStorage(),
            provider: provider,
            initialConversations: []
        )
        let coordinator = DesktopMacDialogueCoordinator(
            fileURL: dir.appendingPathComponent("state.json"),
            executorId: "mac-bridge",
            soulRevisionProvider: { workspace.agentSoul.revision }
        )
        workspace.attachMacDialogue(coordinator)

        // Scenario A: submit message -> enqueue followup while active -> provider completes -> followup consumed & completed
        let (_, msgReceipt) = try coordinator.submit(
            deviceId: "ios-1", requestId: "req-run-1", text: "分析日志", kind: "message", conversationId: "conv-a"
        )
        let work1 = try XCTUnwrap(msgReceipt.workItemIds.first)
        try await waitUntil { provider.startedRuns.count == 1 }

        let (fStatus, fReceipt) = try coordinator.submit(
            deviceId: "ios-1", requestId: "req-follow-1", text: "顺便输出结论摘要", kind: "followup", workItemId: work1
        )
        XCTAssertEqual(fStatus, 202)
        XCTAssertEqual(fReceipt.state, .received)

        // Finish first turn -> workspace drains pending followup, emits input_consumed, and runs continuation turn
        provider.startedRuns[0].yield(.snapshot(text: "初步分析完成", reasoning: ""))
        provider.startedRuns[0].yield(.complete)

        try await waitUntil { provider.startedRuns.count == 2 }
        provider.startedRuns[1].yield(.snapshot(text: "最终结论摘要：一切正常。", reasoning: ""))
        provider.startedRuns[1].yield(.complete)

        try await waitUntil { coordinator.workItem(work1)?.lifecycle == .completed }
        let pageA = try coordinator.page(after: 0, limit: 100)
        let consumed = try XCTUnwrap(pageA.items.first { $0.kind == "input_consumed" && $0.causedByRequestId == "req-follow-1" })
        XCTAssertEqual(consumed.causedByInputId, fReceipt.eventId)
        let resultA = try XCTUnwrap(pageA.items.first { $0.kind == "task_result" && $0.workItemId == work1 })
        XCTAssertEqual(resultA.outcome, "completed")
        XCTAssertEqual(resultA.text, "最终结论摘要：一切正常。")
        XCTAssertEqual(resultA.executorKind, "mac")

        // Scenario B: submit second task -> queue followup -> send stop -> task cancelled & pending followup abandoned
        let (_, msg2) = try coordinator.submit(
            deviceId: "ios-1", requestId: "req-run-2", text: "长任务", kind: "message", conversationId: "conv-b"
        )
        let work2 = try XCTUnwrap(msg2.workItemIds.first)
        try await waitUntil { provider.startedRuns.count == 3 }

        let (_, pendingFollowup) = try coordinator.submit(
            deviceId: "ios-1", requestId: "req-follow-2", text: "未执行的补充", kind: "followup", workItemId: work2
        )
        let (stopStatus, _) = try coordinator.submit(
            deviceId: "ios-1", requestId: "req-stop-2", text: "", kind: "stop", workItemId: work2
        )
        XCTAssertEqual(stopStatus, 200)

        try await waitUntil { coordinator.workItem(work2)?.lifecycle == .cancelled }
        let pageB = try coordinator.page(after: pageA.nextCursor, limit: 100)
        let cancelledFollowup = try XCTUnwrap(pageB.items.first { $0.kind == "input_cancelled" && $0.causedByRequestId == "req-follow-2" })
        XCTAssertEqual(cancelledFollowup.causedByInputId, pendingFollowup.eventId)
        let resultB = try XCTUnwrap(pageB.items.first { $0.kind == "task_result" && $0.workItemId == work2 })
        XCTAssertEqual(resultB.outcome, "cancelled")
    }

    private func waitUntil(timeout: TimeInterval = 3, condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date().timeIntervalSince(deadline) >= 0 {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - Minimal Test Doubles

@MainActor
private final class StubDialogueProvider: DesktopTextProvider {
    var startedRuns: [DesktopGeneration] = []

    func userMessage(id: UUID, text: String, attachments: [DesktopMessageAttachment]) throws -> DesktopMessage {
        DesktopMessage(id: id, role: .user, text: text)
    }

    func start(
        configuration: DesktopProviderConfiguration,
        apiKey: String,
        messages: [DesktopMessage],
        responseID: UUID
    ) throws -> DesktopGeneration {
        let run = DesktopGeneration()
        startedRuns.append(run)
        return run
    }
}
