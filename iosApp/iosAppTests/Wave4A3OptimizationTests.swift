import BackgroundTasks
import Foundation
import UIKit
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class Wave4A3OptimizationTests: XCTestCase {

    // MARK: - Astra #2: Cloud Dialogue Settled Receipt Short-Circuit

    func testCloudDialogueAwaitingReplyPreservesAllHardContractsAndReceiptOverrides() throws {
        let suite = "Wave4A3.CloudContracts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MacGatewayStore(defaults: defaults)

        func makeReceipt(
            requestId: String,
            eventId: String,
            topicId: String,
            workItemIds: [String] = [],
            state: MacGatewayCloudDialogueReceiptState
        ) -> MacGatewayCloudDialogueReceipt {
            MacGatewayCloudDialogueReceipt(
                eventId: eventId,
                requestId: requestId,
                topicId: topicId,
                workItemIds: workItemIds,
                state: state,
                replayed: false,
                soulRevision: nil
            )
        }

        func makeSubmission(
            requestId: String,
            kind: MacGatewayCloudDialoguePersistedSubmission.Kind = .mainMessage,
            receipt: MacGatewayCloudDialogueReceipt?,
            isConfirmedNotExecuted: Bool = false,
            isAbandoned: Bool = false
        ) -> MacGatewayCloudDialoguePersistedSubmission {
            MacGatewayCloudDialoguePersistedSubmission(
                gatewayId: "gw-test",
                deviceId: "dev-test",
                kind: kind,
                requestId: requestId,
                workItemId: receipt?.workItemIds.first,
                text: "synthetic message \(requestId)",
                receipt: receipt,
                lastError: isConfirmedNotExecuted ? "rejected" : nil,
                updatedAt: Date(),
                isConfirmedNotExecuted: isConfirmedNotExecuted,
                isAbandoned: isAbandoned
            )
        }

        func makeEvent(
            seq: Int64,
            id: String,
            kind: MacGatewayCloudDialogueEventKind,
            role: String,
            topicId: String,
            workItemId: String? = nil,
            text: String = "synthetic body"
        ) -> MacGatewayCloudDialogueEvent {
            MacGatewayCloudDialogueEvent(
                seq: seq,
                id: id,
                kind: kind,
                role: role,
                text: text,
                topicId: topicId,
                workItemId: workItemId,
                outcome: nil,
                soulRevision: nil
            )
        }

        // 1. In-flight request always keeps awaiting true, even when all submissions are settled.
        store.cloudDialogueSubmissions = [
            makeSubmission(
                requestId: "req-settled",
                receipt: makeReceipt(requestId: "req-settled", eventId: "evt-settled", topicId: "t-0", state: .consumed)
            )
        ]
        store.busyCloudDialogueRequestIds = ["req-in-flight"]
        XCTAssertTrue(store.isAwaitingCloudMainReply)
        store.busyCloudDialogueRequestIds = []
        XCTAssertFalse(store.isAwaitingCloudMainReply)

        // 2. Submission without receipt: awaiting confirmation vs deterministically rejected/abandoned.
        store.cloudDialogueSubmissions = [
            makeSubmission(requestId: "req-no-receipt-confirmed-not-exec", receipt: nil, isConfirmedNotExecuted: true),
            makeSubmission(requestId: "req-no-receipt-abandoned", receipt: nil, isAbandoned: true),
        ]
        XCTAssertFalse(store.isAwaitingCloudMainReply)

        store.cloudDialogueSubmissions.append(
            makeSubmission(requestId: "req-no-receipt-pending", receipt: nil)
        )
        XCTAssertTrue(store.isAwaitingCloudMainReply)

        // 3. Receipt dictionary overrides stale submission receipt copy in both directions.
        // 3a. Stale .received on submission overridden by .consumed / .cancelled in dictionary -> false
        // even with zero events (late userEvent would otherwise return true).
        let staleReceived = makeReceipt(
            requestId: "req-override-settled",
            eventId: "evt-missing-1",
            topicId: "t-override-1",
            workItemIds: ["work-1"],
            state: .received
        )
        store.cloudDialogueEvents = []
        store.cloudDialogueSubmissions = [makeSubmission(requestId: "req-override-settled", receipt: staleReceived)]
        store.cloudDialogueReceipts = [
            "req-override-settled": makeReceipt(
                requestId: "req-override-settled",
                eventId: "evt-missing-1",
                topicId: "t-override-1",
                workItemIds: ["work-1"],
                state: .consumed
            )
        ]
        XCTAssertFalse(store.isAwaitingCloudMainReply, ".consumed in receipt dictionary must short-circuit stale .received submission")

        store.cloudDialogueReceipts["req-override-settled"]?.state = .cancelled
        XCTAssertFalse(store.isAwaitingCloudMainReply, ".cancelled in receipt dictionary must short-circuit stale .received submission")

        // 3b. Stale .consumed on submission overridden by .received in dictionary -> true (late event).
        let staleConsumed = makeReceipt(
            requestId: "req-override-active",
            eventId: "evt-late-user",
            topicId: "t-override-2",
            state: .consumed
        )
        store.cloudDialogueSubmissions = [makeSubmission(requestId: "req-override-active", receipt: staleConsumed)]
        store.cloudDialogueReceipts = [
            "req-override-active": makeReceipt(
                requestId: "req-override-active",
                eventId: "evt-late-user",
                topicId: "t-override-2",
                state: .received
            )
        ]
        XCTAssertTrue(store.isAwaitingCloudMainReply, "Receipt dictionary .received must override stale .consumed copy")

        // 4. Upfront acknowledgement alone does NOT clear awaiting, with or without delegated work items.
        let ackReceipt = makeReceipt(
            requestId: "req-ack",
            eventId: "evt-user-ack",
            topicId: "t-ack",
            workItemIds: ["work-ack"],
            state: .received
        )
        store.cloudDialogueSubmissions = [makeSubmission(requestId: "req-ack", receipt: ackReceipt)]
        store.cloudDialogueReceipts = ["req-ack": ackReceipt]
        store.cloudDialogueProgressByWorkItem = [:]
        store.cloudDialogueEvents = [
            makeEvent(seq: 1, id: "evt-user-ack", kind: .userMessage, role: "user", topicId: "t-ack"),
            makeEvent(seq: 2, id: "ack:evt-user-ack", kind: .assistantReply, role: "assistant", topicId: "t-ack", text: "收到，我去查一下。"),
        ]
        XCTAssertTrue(store.isAwaitingCloudMainReply, "Upfront ACK alone must keep awaiting true")

        // 5. Delegated WorkItem progress clears awaiting.
        store.cloudDialogueProgressByWorkItem["work-ack"] = MacGatewayCloudDialogueWorkItemProgress(
            workItemId: "work-ack",
            topicId: "t-ack",
            statusLine: "检索中",
            processEventCount: 1,
            lastEventSeq: 3,
            outcome: nil
        )
        XCTAssertFalse(store.isAwaitingCloudMainReply, "Active WorkItem progress must clear main awaiting")

        // 6. Non-ACK topic activity with delegated WorkItem also clears awaiting even without progress entry.
        store.cloudDialogueProgressByWorkItem = [:]
        store.cloudDialogueEvents.append(
            makeEvent(seq: 3, id: "evt-proc-1", kind: .processEvent, role: "system", topicId: "t-ack", workItemId: "work-ack", text: "步骤 1")
        )
        XCTAssertFalse(store.isAwaitingCloudMainReply)

        // 7. Direct reply without WorkItem: reply on another topic stays true, reply on same topic clears awaiting.
        let directReceipt = makeReceipt(
            requestId: "req-direct",
            eventId: "evt-user-direct",
            topicId: "t-direct",
            state: .received
        )
        store.cloudDialogueSubmissions = [makeSubmission(requestId: "req-direct", receipt: directReceipt)]
        store.cloudDialogueReceipts = ["req-direct": directReceipt]
        store.cloudDialogueEvents = [
            makeEvent(seq: 10, id: "evt-user-direct", kind: .userMessage, role: "user", topicId: "t-direct"),
            makeEvent(seq: 11, id: "evt-other-topic-reply", kind: .assistantReply, role: "assistant", topicId: "t-other", text: "别的话题"),
        ]
        XCTAssertTrue(store.isAwaitingCloudMainReply)

        store.cloudDialogueEvents.append(
            makeEvent(seq: 12, id: "evt-direct-reply", kind: .assistantReply, role: "assistant", topicId: "t-direct", text: "直接答复")
        )
        XCTAssertFalse(store.isAwaitingCloudMainReply)
    }

    func testCloudDialogueSettledSubmissionsShortCircuitLargeHistory() throws {
        let suite = "Wave4A3.CloudShortCircuit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MacGatewayStore(defaults: defaults)
        let settledCount = 400
        let eventCount = 2_000

        store.cloudDialogueEvents = (1...eventCount).map { idx in
            MacGatewayCloudDialogueEvent(
                seq: Int64(idx),
                id: "evt-\(idx)",
                kind: idx.isMultiple(of: 2) ? .assistantReply : .userMessage,
                role: idx.isMultiple(of: 2) ? "assistant" : "user",
                text: "history event \(idx)",
                topicId: "topic-\(idx % 50)",
                workItemId: idx.isMultiple(of: 5) ? "work-\(idx)" : nil,
                outcome: nil,
                soulRevision: nil
            )
        }

        var submissions: [MacGatewayCloudDialoguePersistedSubmission] = []
        var receipts: [String: MacGatewayCloudDialogueReceipt] = [:]
        submissions.reserveCapacity(settledCount)
        for idx in 0..<settledCount {
            let reqId = "req-settled-\(idx)"
            let state: MacGatewayCloudDialogueReceiptState = idx.isMultiple(of: 2) ? .consumed : .cancelled
            // Half have stale .received in submission and settled state in dictionary;
            // half are already settled in submission.
            let storedState: MacGatewayCloudDialogueReceiptState = idx.isMultiple(of: 4) ? .received : state
            let storedReceipt = MacGatewayCloudDialogueReceipt(
                eventId: "evt-missing-settled-\(idx)",
                requestId: reqId,
                topicId: "topic-unmatched-\(idx)",
                workItemIds: ["work-settled-\(idx)"],
                state: storedState,
                replayed: false,
                soulRevision: nil
            )
            submissions.append(
                MacGatewayCloudDialoguePersistedSubmission(
                    gatewayId: "gw-bench",
                    deviceId: "dev-bench",
                    kind: .mainMessage,
                    requestId: reqId,
                    workItemId: "work-settled-\(idx)",
                    text: "settled \(idx)",
                    receipt: storedReceipt,
                    lastError: nil,
                    updatedAt: Date()
                )
            )
            if idx.isMultiple(of: 4) {
                var effective = storedReceipt
                effective.state = state
                receipts[reqId] = effective
            }
        }
        store.cloudDialogueSubmissions = submissions
        store.cloudDialogueReceipts = receipts

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<50 {
            XCTAssertFalse(store.isAwaitingCloudMainReply)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        // Without short-circuit, 50 * 400 * 2000 = 40M event predicate evaluations;
        // with short-circuit, 50 * 400 dictionary checks finish in milliseconds.
        XCTAssertLessThan(elapsed, 0.5, "Settled submissions should short-circuit before scanning cloudDialogueEvents (elapsed=\(elapsed)s)")

        // Adding a single unsettled submission still returns true immediately.
        let activeReceipt = MacGatewayCloudDialogueReceipt(
            eventId: "evt-late-active",
            requestId: "req-active-tail",
            topicId: "topic-active-tail",
            workItemIds: [],
            state: .received,
            replayed: false,
            soulRevision: nil
        )
        store.cloudDialogueSubmissions.append(
            MacGatewayCloudDialoguePersistedSubmission(
                gatewayId: "gw-bench",
                deviceId: "dev-bench",
                kind: .mainMessage,
                requestId: activeReceipt.requestId,
                workItemId: nil,
                text: "active tail",
                receipt: activeReceipt,
                lastError: nil,
                updatedAt: Date()
            )
        )
        XCTAssertTrue(store.isAwaitingCloudMainReply)
    }

    // MARK: - Astra #4: BackgroundGenerationKeepAlive updateTitle Dedup

    private final class FakeContinuedProcessingTask: BackgroundContinuedProcessingTasking, @unchecked Sendable {
        let progress = Progress(totalUnitCount: -1)
        var expirationHandler: (() -> Void)?
        var updateTitleCalls: [(title: String, subtitle: String)] = []
        var completedResults: [Bool] = []

        func updateTitle(_ title: String, subtitle: String) {
            updateTitleCalls.append((title: title, subtitle: subtitle))
        }

        func setTaskCompleted(success: Bool) {
            completedResults.append(success)
        }
    }

    @MainActor
    private final class KeepAliveAudioSpy: BackgroundAudioKeepAliveControlling {
        var isActive = false
        var isStartingOrActive: Bool { isActive }
        func start() { isActive = true }
        func stop() { isActive = false }
    }

    @MainActor
    private final class KeepAliveLocationSpy: BackgroundLocationKeepAliveControlling {
        var isActive = false
        func setNeeded(_ needed: Bool) {}
    }

    private func makeKeepAlive(
        audio: KeepAliveAudioSpy = KeepAliveAudioSpy(),
        location: KeepAliveLocationSpy = KeepAliveLocationSpy(),
        now: @escaping () -> Date = Date.init,
        isAudioEnabled: @escaping () -> Bool = { false }
    ) -> BackgroundGenerationKeepAlive {
        var nextId = 1
        return BackgroundGenerationKeepAlive(
            beginBackgroundTask: { _, _ in
                defer { nextId += 1 }
                return UIBackgroundTaskIdentifier(rawValue: nextId)
            },
            endBackgroundTask: { _ in },
            submitTaskRequest: { _ in },
            cancelTaskRequest: { _ in },
            registerLaunchHandler: { _, _ in true },
            audioKeepAlive: audio,
            locationKeepAlive: location,
            isAudioKeepAliveEnabled: isAudioEnabled,
            now: now
        )
    }

    func testKeepAliveDedupesUpdateTitleWhileAdvancingProgressEveryTick() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let keepAlive = makeKeepAlive(now: { clock })
        let task = FakeContinuedProcessingTask()

        keepAlive.begin("lease-dedup", title: "Amber 生成中", subtitle: "准备阶段")
        keepAlive.updateProgress("lease-dedup", completed: 1, total: -1, subtitle: "思考中")

        let adoptHandle = Task { @MainActor in
            await keepAlive.adoptTask(task, leaseId: "lease-dedup")
        }
        await Task.yield()

        XCTAssertEqual(keepAlive.executionAssertion(for: "lease-dedup"), .adopted)
        XCTAssertEqual(task.updateTitleCalls.count, 1, "Newly adopted task must receive its initial updateTitle")
        XCTAssertEqual(task.updateTitleCalls[0].title, "Amber 生成中")
        XCTAssertEqual(task.updateTitleCalls[0].subtitle, "思考中")
        XCTAssertEqual(task.progress.completedUnitCount, 1)
        XCTAssertEqual(task.progress.totalUnitCount, -1)

        // Heartbeat ticks advance Progress (completed & growing determinate total) every beat
        // without calling updateTitle when title/subtitle are unchanged.
        keepAlive.enableLivenessHeartbeat("lease-dedup")
        for step in 1...10 {
            clock += 10
            XCTAssertTrue(keepAlive.livenessHeartbeatTick("lease-dedup"))
            XCTAssertEqual(task.progress.completedUnitCount, Int64(1 + step))
            XCTAssertEqual(task.progress.totalUnitCount, Int64(101 + step))
        }
        XCTAssertEqual(task.updateTitleCalls.count, 1, "Unchanged heartbeat ticks must not invoke updateTitle")

        // Explicit updateProgress with same subtitle or nil subtitle updates Progress only.
        keepAlive.updateProgress("lease-dedup", completed: 15, subtitle: "思考中")
        XCTAssertEqual(task.progress.completedUnitCount, 15)
        XCTAssertEqual(task.progress.totalUnitCount, 115)
        XCTAssertEqual(task.updateTitleCalls.count, 1)

        keepAlive.updateProgress("lease-dedup", completed: 16, subtitle: nil)
        XCTAssertEqual(task.progress.completedUnitCount, 16)
        XCTAssertEqual(task.updateTitleCalls.count, 1)

        // Subtitle change invokes updateTitle exactly once.
        keepAlive.updateProgress("lease-dedup", completed: 17, subtitle: "正在输出")
        XCTAssertEqual(task.progress.completedUnitCount, 17)
        XCTAssertEqual(task.updateTitleCalls.count, 2)
        XCTAssertEqual(task.updateTitleCalls[1].title, "Amber 生成中")
        XCTAssertEqual(task.updateTitleCalls[1].subtitle, "正在输出")

        // Repeating the new subtitle via advanceProgress skips updateTitle again.
        keepAlive.advanceProgress("lease-dedup", by: 3, subtitle: "正在输出")
        XCTAssertEqual(task.progress.completedUnitCount, 20)
        XCTAssertEqual(task.updateTitleCalls.count, 2)

        keepAlive.end("lease-dedup")
        await adoptHandle.value
        XCTAssertEqual(task.completedResults, [true])
    }

    func testKeepAliveAlwaysWritesInitialTitleAcrossReAdoptionExpirationAndFailedTransfer() async {
        var clock = Date(timeIntervalSince1970: 2_000)
        let audio = KeepAliveAudioSpy()
        audio.isActive = true
        let keepAlive = makeKeepAlive(audio: audio, now: { clock }, isAudioEnabled: { true })

        keepAlive.begin("lease-re", title: "Amber", subtitle: "阶段 A", allowsAudioLeg: true)
        keepAlive.updateProgress("lease-re", completed: 2, total: -1)
        keepAlive.enableLivenessHeartbeat("lease-re")

        // 1. First adoption writes initial title.
        let task1 = FakeContinuedProcessingTask()
        let handle1 = Task { @MainActor in
            await keepAlive.adoptTask(task1, leaseId: "lease-re")
        }
        await Task.yield()
        XCTAssertEqual(task1.updateTitleCalls.count, 1)
        XCTAssertEqual(task1.updateTitleCalls[0].subtitle, "阶段 A")

        // 2. System task expires while audio leg holds the lease -> lease survives, task1 completes(false).
        task1.expirationHandler?()
        await handle1.value
        XCTAssertEqual(task1.completedResults, [false])
        XCTAssertTrue(keepAlive.holdsLease("lease-re"))
        XCTAssertEqual(keepAlive.executionAssertion(for: "lease-re"), .audio)

        // 3. Re-adoption with identical title/subtitle MUST write initial title to task2.
        let task2 = FakeContinuedProcessingTask()
        let handle2 = Task { @MainActor in
            await keepAlive.adoptTask(task2, leaseId: "lease-re")
        }
        await Task.yield()
        XCTAssertEqual(task2.updateTitleCalls.count, 1, "Re-adopted system task must receive initial updateTitle even if text is unchanged")
        XCTAssertEqual(task2.updateTitleCalls[0].title, "Amber")
        XCTAssertEqual(task2.updateTitleCalls[0].subtitle, "阶段 A")

        // Subsequent unchanged update on task2 is deduped while Progress advances.
        keepAlive.updateProgress("lease-re", completed: 5, subtitle: "阶段 A")
        XCTAssertEqual(task2.progress.completedUnitCount, 5)
        XCTAssertEqual(task2.updateTitleCalls.count, 1)

        // 4. Failed transfer ends lease, restores lease with progress & heartbeat, and newly adopted task3 receives initial title.
        let didTransfer = keepAlive.transfer("lease-re") { false }
        await handle2.value
        XCTAssertFalse(didTransfer)
        XCTAssertEqual(task2.completedResults, [true])
        XCTAssertTrue(keepAlive.holdsLease("lease-re"))
        XCTAssertTrue(keepAlive.hasLivenessHeartbeat("lease-re"))
        XCTAssertEqual(keepAlive.reportedProgress(for: "lease-re"), 5)

        let task3 = FakeContinuedProcessingTask()
        let handle3 = Task { @MainActor in
            await keepAlive.adoptTask(task3, leaseId: "lease-re")
        }
        await Task.yield()
        XCTAssertEqual(task3.updateTitleCalls.count, 1, "Task adopted after failed transfer restoration must receive initial updateTitle")
        XCTAssertEqual(task3.updateTitleCalls[0].subtitle, "阶段 A")
        XCTAssertEqual(task3.progress.completedUnitCount, 5)

        clock += 10
        XCTAssertTrue(keepAlive.livenessHeartbeatTick("lease-re"))
        XCTAssertEqual(task3.progress.completedUnitCount, 6)
        XCTAssertEqual(task3.progress.totalUnitCount, 106)
        XCTAssertEqual(task3.updateTitleCalls.count, 1)

        // 5. Direct abandonSystemAssertion(preservingAdoptedTask: false) clears cached title for next adoption.
        keepAlive.abandonSystemAssertion("lease-re", preservingAdoptedTask: false)
        await handle3.value
        XCTAssertEqual(task3.completedResults, [true])

        let task4 = FakeContinuedProcessingTask()
        let handle4 = Task { @MainActor in
            await keepAlive.adoptTask(task4, leaseId: "lease-re")
        }
        await Task.yield()
        XCTAssertEqual(task4.updateTitleCalls.count, 1, "Task adopted after abandonSystemAssertion must receive initial updateTitle")

        keepAlive.end("lease-re")
        await handle4.value
        XCTAssertEqual(task4.completedResults, [true])
    }

    // MARK: - Astra #5: IOSAgentRunLedger WebMount Report Query Pre-Filtering

    private final class CountingAgentRuntimeDao: NSObject, AgentRuntimeDao, @unchecked Sendable {
        private let wrapped: AgentRuntimeDao
        private let lock = NSLock()
        private var _listRunSummariesCalls = 0
        private var _listToolTransactionsRunIds: [String] = []
        private var _listEventsRunIds: [String] = []

        init(wrapping wrapped: AgentRuntimeDao) {
            self.wrapped = wrapped
        }

        func resetCounts() {
            lock.lock()
            defer { lock.unlock() }
            _listRunSummariesCalls = 0
            _listToolTransactionsRunIds = []
            _listEventsRunIds = []
        }

        var listRunSummariesCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return _listRunSummariesCalls
        }

        var listToolTransactionsRunIds: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _listToolTransactionsRunIds
        }

        var listEventsRunIds: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _listEventsRunIds
        }

        func changedRowCount(completionHandler: @escaping (KotlinInt?, (any Error)?) -> Void) {
            wrapped.changedRowCount(completionHandler: completionHandler)
        }

        func countEventsForRun(runId: String, type: String, completionHandler: @escaping (KotlinLong?, (any Error)?) -> Void) {
            wrapped.countEventsForRun(runId: runId, type: type, completionHandler: completionHandler)
        }

        func getRun(id: String, completionHandler: @escaping (AgentRunEntity?, (any Error)?) -> Void) {
            wrapped.getRun(id: id, completionHandler: completionHandler)
        }

        func getToolTransaction(runId: String, toolCallId: String, completionHandler: @escaping (AgentToolTransactionEntity?, (any Error)?) -> Void) {
            wrapped.getToolTransaction(runId: runId, toolCallId: toolCallId, completionHandler: completionHandler)
        }

        func insertPermissionIntent(p: PermissionIntentEntity, completionHandler: @escaping ((any Error)?) -> Void) {
            wrapped.insertPermissionIntent(p: p, completionHandler: completionHandler)
        }

        func insertRunEvent(
            runId: String,
            eventId: String,
            type: String,
            payloadType: String,
            payload: String,
            payloadSchemaVersion: Int32,
            isFinal: Bool,
            ts: Int64,
            turnId: String?,
            stepId: String?,
            toolCallId: String?,
            completionHandler: @escaping (KotlinInt?, (any Error)?) -> Void
        ) {
            wrapped.insertRunEvent(
                runId: runId,
                eventId: eventId,
                type: type,
                payloadType: payloadType,
                payload: payload,
                payloadSchemaVersion: payloadSchemaVersion,
                isFinal: isFinal,
                ts: ts,
                turnId: turnId,
                stepId: stepId,
                toolCallId: toolCallId,
                completionHandler: completionHandler
            )
        }

        func insertRunEventIgnoring(
            runId: String,
            eventId: String,
            type: String,
            payloadType: String,
            payload: String,
            payloadSchemaVersion: Int32,
            isFinal: Bool,
            ts: Int64,
            turnId: String?,
            stepId: String?,
            toolCallId: String?,
            completionHandler: @escaping ((any Error)?) -> Void
        ) {
            wrapped.insertRunEventIgnoring(
                runId: runId,
                eventId: eventId,
                type: type,
                payloadType: payloadType,
                payload: payload,
                payloadSchemaVersion: payloadSchemaVersion,
                isFinal: isFinal,
                ts: ts,
                turnId: turnId,
                stepId: stepId,
                toolCallId: toolCallId,
                completionHandler: completionHandler
            )
        }

        func insertRunIfAbsent(run: AgentRunEntity, completionHandler: @escaping (KotlinLong?, (any Error)?) -> Void) {
            wrapped.insertRunIfAbsent(run: run, completionHandler: completionHandler)
        }

        func insertSpan(span: TraceSpanEntity, completionHandler: @escaping ((any Error)?) -> Void) {
            wrapped.insertSpan(span: span, completionHandler: completionHandler)
        }

        func insertToolTransactionIfAbsent(transaction: AgentToolTransactionEntity, completionHandler: @escaping (KotlinLong?, (any Error)?) -> Void) {
            wrapped.insertToolTransactionIfAbsent(transaction: transaction, completionHandler: completionHandler)
        }

        func listAllRuns(completionHandler: @escaping ([AgentRunEntity]?, (any Error)?) -> Void) {
            wrapped.listAllRuns(completionHandler: completionHandler)
        }

        func listEventsForRun(id: String, completionHandler: @escaping ([AgentEventEntity]?, (any Error)?) -> Void) {
            lock.lock()
            _listEventsRunIds.append(id)
            lock.unlock()
            wrapped.listEventsForRun(id: id, completionHandler: completionHandler)
        }

        func listRecoverable(descriptorIds: [String], completionHandler: @escaping ([AgentRunEntity]?, (any Error)?) -> Void) {
            wrapped.listRecoverable(descriptorIds: descriptorIds, completionHandler: completionHandler)
        }

        func listRunNoticeSummaries(completionHandler: @escaping ([AgentRunNoticeSummary]?, (any Error)?) -> Void) {
            wrapped.listRunNoticeSummaries(completionHandler: completionHandler)
        }

        func listRunSummaries(completionHandler: @escaping ([AgentRunSummary]?, (any Error)?) -> Void) {
            lock.lock()
            _listRunSummariesCalls += 1
            lock.unlock()
            wrapped.listRunSummaries(completionHandler: completionHandler)
        }

        func listRunsForMessageNode(id: String, completionHandler: @escaping ([AgentRunEntity]?, (any Error)?) -> Void) {
            wrapped.listRunsForMessageNode(id: id, completionHandler: completionHandler)
        }

        func listToolTransactionsForRun(runId: String, completionHandler: @escaping ([AgentToolTransactionEntity]?, (any Error)?) -> Void) {
            lock.lock()
            _listToolTransactionsRunIds.append(runId)
            lock.unlock()
            wrapped.listToolTransactionsForRun(runId: runId, completionHandler: completionHandler)
        }

        func observeEvents(id: String) -> any Kotlinx_coroutines_coreFlow {
            wrapped.observeEvents(id: id)
        }

        func observeRun(id: String) -> any Kotlinx_coroutines_coreFlow {
            wrapped.observeRun(id: id)
        }

        func pruneOldSpans(cutoff: Int64, completionHandler: @escaping ((any Error)?) -> Void) {
            wrapped.pruneOldSpans(cutoff: cutoff, completionHandler: completionHandler)
        }

        func transitionRun(
            runId: String,
            expectedStatus: String,
            status: String,
            inputSnapshotRef: String?,
            detail: String?,
            finishedAt: KotlinLong?,
            completionHandler: @escaping (KotlinInt?, (any Error)?) -> Void
        ) {
            wrapped.transitionRun(
                runId: runId,
                expectedStatus: expectedStatus,
                status: status,
                inputSnapshotRef: inputSnapshotRef,
                detail: detail,
                finishedAt: finishedAt,
                completionHandler: completionHandler
            )
        }

        func transitionToolTransaction(
            runId: String,
            toolCallId: String,
            expectedState: String,
            state: String,
            outcome: String?,
            resultPayload: String?,
            updatedAt: Int64,
            completionHandler: @escaping (KotlinInt?, (any Error)?) -> Void
        ) {
            wrapped.transitionToolTransaction(
                runId: runId,
                toolCallId: toolCallId,
                expectedState: expectedState,
                state: state,
                outcome: outcome,
                resultPayload: resultPayload,
                updatedAt: updatedAt,
                completionHandler: completionHandler
            )
        }
    }

    private func makeTempDatabase(_ name: String = #function) -> AgentRuntimeDatabase {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wave4A3-\(name)-\(UUID().uuidString).db")
            .path
        return IosDatabaseFactory.shared.createDatabase(atFilePath: path)
    }

    private func recordToolCall(
        ledger: IOSAgentRunLedger,
        runId: String,
        toolCallId: String,
        toolName: String,
        output: String,
        effectClass: IOSToolEffectClass = .sideEffect
    ) async throws {
        let prep = await ledger.recordToolCallPrepared(
            runId: runId,
            toolCallId: toolCallId,
            toolName: toolName,
            argsDigest: "digest-\(toolCallId)",
            effectClass: effectClass
        )
        XCTAssertEqual(prep, .ready)
        let started = await ledger.recordToolCallStarted(
            runId: runId,
            toolCallId: toolCallId,
            toolName: toolName,
            argsDigest: "digest-\(toolCallId)",
            effectClass: effectClass
        )
        XCTAssertTrue(started)
        let payload = try XCTUnwrap(IosToolOutputJsonBridge.shared.encode(
            parts: [UIMessagePart.Text(text: output, metadata: nil)]
        ))
        let finished = await ledger.recordToolCallTerminal(
            runId: runId,
            toolCallId: toolCallId,
            outcome: "completed",
            resultPayload: payload
        )
        XCTAssertTrue(finished)
    }

    func testWebMountRunReportsPreFiltersUnrelatedRunsReducingQueriesToOnePlusRPlusQ() async throws {
        let db = makeTempDatabase()
        let countingDao = CountingAgentRuntimeDao(wrapping: db.agentRuntimeDao())
        let store = IOSDurableRunStore(dao: countingDao)
        let ledger = IOSAgentRunLedger(dao: countingDao)
        let convId = "wave4a3-conv-\(UUID().uuidString)"

        // R = 6 candidate runs in the same conversation, only Q = 1 matches session "session-target".
        for idx in 1...3 {
            let runId = "run-plain-\(idx)"
            let started = try await store.startChatRun(runId: runId, startedAt: Int64(idx * 1_000), inputDigest: "d", conversationId: convId)
            XCTAssertTrue(started)
            try await recordToolCall(ledger: ledger, runId: runId, toolCallId: "plain-search-\(idx)", toolName: "search_web", output: #"{"ok":true}"#, effectClass: .networkRead)
            let finished = try await store.transition(runId: runId, expected: .running, to: .completed, at: Int64(idx * 1_000 + 500))
            XCTAssertTrue(finished)
        }

        // Historical run with wm_ targeting a different session_id.
        let otherSessionRun = "run-other-session"
        let otherStarted = try await store.startChatRun(runId: otherSessionRun, startedAt: 4_000, inputDigest: "d", conversationId: convId)
        XCTAssertTrue(otherStarted)
        try await recordToolCall(ledger: ledger, runId: otherSessionRun, toolCallId: "other-wm", toolName: "wm_click", output: #"{"ok":true,"session_id":"session-other"}"#)
        let otherFinished = try await store.transition(runId: otherSessionRun, expected: .running, to: .completed, at: 5_000)
        XCTAssertTrue(otherFinished)

        // Historical run with only nested session_id (must NOT be attributed).
        let nestedOnlyRun = "run-nested-only"
        let nestedStarted = try await store.startChatRun(runId: nestedOnlyRun, startedAt: 5_000, inputDigest: "d", conversationId: convId)
        XCTAssertTrue(nestedStarted)
        try await recordToolCall(ledger: ledger, runId: nestedOnlyRun, toolCallId: "nested-wm", toolName: "wm_tab_list", output: #"{"tabs":[{"session_id":"session-target"}]}"#)
        let nestedFinished = try await store.transition(runId: nestedOnlyRun, expected: .running, to: .completed, at: 6_000)
        XCTAssertTrue(nestedFinished)

        // Matching historical run with mixed WebMount (target + other) and non-WebMount tools.
        let matchedRun = "run-matched"
        let matchedStarted = try await store.startChatRun(runId: matchedRun, startedAt: 7_000, inputDigest: "d", conversationId: convId)
        XCTAssertTrue(matchedStarted)
        try await recordToolCall(ledger: ledger, runId: matchedRun, toolCallId: "match-obs", toolName: "wm_observe", output: #"{"ok":true,"session_id":"session-target","url":"https://example.com"}"#)
        try await recordToolCall(ledger: ledger, runId: matchedRun, toolCallId: "match-other-wm", toolName: "wm_click", output: #"{"ok":true,"session_id":"session-other"}"#)
        try await recordToolCall(ledger: ledger, runId: matchedRun, toolCallId: "match-search", toolName: "search_web", output: #"{"ok":true}"#, effectClass: .networkRead)
        let matchedFinished = try await store.transition(runId: matchedRun, expected: .running, to: .completed, at: 11_000)
        XCTAssertTrue(matchedFinished)

        countingDao.resetCounts()

        let reports = await ledger.webMountRunReports(
            sessionId: "session-target",
            ownerConversationId: convId,
            ownerRunId: nil
        )

        // Exact projection contract preserved:
        XCTAssertEqual(reports.map(\.id), [matchedRun])
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.durationMillis, 4_000)
        XCTAssertFalse(report.isRunning)
        XCTAssertEqual(report.totalToolCalls, 3, "Run-wide tool call total must remain intact")
        XCTAssertEqual(report.webMountToolCalls, 1, "Only explicitly matching session_id wm_* step counts")
        XCTAssertTrue(report.steps.contains { $0.id == "match-obs" })
        XCTAssertTrue(report.steps.contains { $0.id == "match-search" }, "Non-WebMount steps must remain in report timeline")
        XCTAssertFalse(report.steps.contains { $0.id == "match-other-wm" }, "Other session's wm_* step must be excluded")

        // Query count strictly reduced from 1 + 2R (13) to 1 + R + Q (8):
        XCTAssertEqual(countingDao.listRunSummariesCalls, 1)
        XCTAssertEqual(countingDao.listToolTransactionsRunIds.count, 6, "R = 6 candidate runs inspected for transactions")
        XCTAssertEqual(countingDao.listEventsRunIds, [matchedRun], "Only Q = 1 matched run should query toolEvents")
    }

    func testWebMountRunReportsStillProjectsCurrentOwnerWithEventOnlyWebMountToolName() async throws {
        let db = makeTempDatabase()
        let countingDao = CountingAgentRuntimeDao(wrapping: db.agentRuntimeDao())
        let store = IOSDurableRunStore(dao: countingDao)
        let ledger = IOSAgentRunLedger(dao: countingDao)
        let convId = "wave4a3-owner-\(UUID().uuidString)"

        // Unrelated historical run (should be skipped before toolEvents).
        let historyRun = "run-history-unrelated"
        let historyStarted = try await store.startChatRun(runId: historyRun, startedAt: 1_000, inputDigest: "d", conversationId: convId)
        XCTAssertTrue(historyStarted)
        try await recordToolCall(ledger: ledger, runId: historyRun, toolCallId: "hist-search", toolName: "search_web", output: #"{"ok":true}"#, effectClass: .networkRead)
        let historyFinished = try await store.transition(runId: historyRun, expected: .running, to: .completed, at: 2_000)
        XCTAssertTrue(historyFinished)

        // Current owner run has NO transactions at all — wm_* toolName exists ONLY on the event side.
        let ownerRun = "run-current-owner-event-only"
        let ownerStarted = try await store.startChatRun(runId: ownerRun, startedAt: 3_000, inputDigest: "d", conversationId: convId)
        XCTAssertTrue(ownerStarted)
        await ledger.recordApprovalDenied(
            runId: ownerRun,
            toolCallId: "owner-denied-wm",
            toolName: "wm_click",
            reason: "User denied web click.",
            capabilityId: "web"
        )

        countingDao.resetCounts()

        let reports = await ledger.webMountRunReports(
            sessionId: "session-target",
            ownerConversationId: convId,
            ownerRunId: ownerRun
        )

        XCTAssertEqual(reports.map(\.id), [ownerRun], "Current owner with event-only wm_* step must still enter original projection")
        let ownerReport = try XCTUnwrap(reports.first)
        XCTAssertTrue(ownerReport.isRunning)
        XCTAssertEqual(ownerReport.totalToolCalls, 1)
        XCTAssertEqual(ownerReport.webMountToolCalls, 0)

        // Unrelated historical run was still pre-filtered out (Q = 1 for current owner only).
        XCTAssertEqual(countingDao.listRunSummariesCalls, 1)
        XCTAssertEqual(countingDao.listToolTransactionsRunIds.count, 2)
        XCTAssertEqual(countingDao.listEventsRunIds, [ownerRun])
    }
}
