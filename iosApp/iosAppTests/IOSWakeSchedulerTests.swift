import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSWakeSchedulerTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let conversationID = UUID().uuidString

    private func makeStore(
        write: ((Data, URL) throws -> Void)? = nil
    ) throws -> (IOSWakeTaskStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tasks.json")
        if let write { return (IOSWakeTaskStore(fileURL: url, now: { self.date }, write: write), url) }
        return (IOSWakeTaskStore(fileURL: url, now: { self.date }), url)
    }

    @discardableResult
    private func plan(
        _ store: IOSWakeTaskStore, request: String = UUID().uuidString,
        fireAt: Date? = nil, event: String? = nil, foreground: Bool = false
    ) throws -> IOSWakeTask {
        try store.schedule(
            conversationID: conversationID, sourceRunID: "authorized-run",
            origin: IOSWakeOrigin(userMessageID: "user-message", userText: "等待研究结果后继续整理。"),
            title: "整理研究结果", prompt: "检查结果，并在这段对话里交付。",
            fireAt: fireAt, event: event, requiresForeground: foreground, requestID: request
        )
    }

    func testDiskRoundTripKeepsMultiplePlansAndIdempotentReceipt() throws {
        let (store, url) = try makeStore()
        let first = try plan(store, request: "call-1", fireAt: date)
        let second = try plan(store, request: "call-2", event: "research-ready")
        let restored = IOSWakeTaskStore(fileURL: url, now: { self.date })
        XCTAssertEqual(restored.tasks, [first, second])
        XCTAssertEqual(try plan(restored, request: "call-1", fireAt: date), first)
        XCTAssertEqual(restored.tasks.count, 2)
        let claimed = try restored.claim(id: first.id, runID: "wake-run")
        XCTAssertEqual(claimed.origin, first.origin)
        XCTAssertThrowsError(try restored.claim(id: first.id, runID: "duplicate"))
        XCTAssertNil(try restored.finish(runID: "stale-run", status: .completed, message: nil))
        XCTAssertEqual(restored.task(id: first.id)?.status, .running)
        _ = try restored.finish(runID: "wake-run", status: .completed, message: nil)
        XCTAssertEqual(IOSWakeTaskStore(fileURL: url).task(id: first.id)?.status, .completed)
    }

    func testCorruptArchiveIsPreservedAndWritesFailClosed() throws {
        let (_, url) = try makeStore()
        let original = Data("unreadable archive".utf8)
        try original.write(to: url)
        let store = IOSWakeTaskStore(fileURL: url)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try plan(store, fireAt: date))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testFailedWritesNeverPublishSchedulingOrCancellation() throws {
        var rejectWrite = false
        let (store, _) = try makeStore { data, url in
            if rejectWrite { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
        rejectWrite = true
        XCTAssertThrowsError(try plan(store, fireAt: date))
        XCTAssertTrue(store.tasks.isEmpty)
        rejectWrite = false
        let task = try plan(store, fireAt: date)
        rejectWrite = true
        XCTAssertThrowsError(try store.cancel(id: task.id))
        XCTAssertEqual(store.task(id: task.id)?.status, .scheduled)
    }

    func testEventIsDurableWhileBusyAndFirstPayloadWins() async throws {
        let (store, url) = try makeStore()
        let task = try plan(store, event: "research-ready")
        let scheduler = IOSWakeScheduler(store: store, now: { self.date }, startRun: { _, _ in
            .deferred("用户正在运行另一个任务。")
        })
        let unrelated = await scheduler.runDueTasks(event: "another-event", content: "忽略")
        XCTAssertEqual(unrelated.startedCount, 0)
        let report = await scheduler.runDueTasks(event: "research-ready", content: "第一份资料")
        XCTAssertEqual(report.deferredCount, 1)
        _ = await scheduler.runDueTasks(event: "research-ready", content: "后续重复通知")
        let restored = IOSWakeTaskStore(fileURL: url)
        XCTAssertEqual(restored.task(id: task.id)?.eventContent, "第一份资料")
        XCTAssertNotNil(restored.task(id: task.id)?.eventReceivedAt)
        XCTAssertEqual(restored.task(id: task.id)?.status, .scheduled)
        XCTAssertEqual(restored.task(id: task.id)?.lastMessage, "用户正在运行另一个任务。")
    }

    func testForegroundTaskWaitsThenRunsOnceAndTerminalIsDurable() async throws {
        let (store, url) = try makeStore()
        var active = false
        var runIDs: [String] = []
        let task = try plan(store, fireAt: date, foreground: true)
        let scheduler = IOSWakeScheduler(
            store: store, now: { self.date }, isForeground: { active },
            startRun: { claimed, runID in
                XCTAssertEqual(claimed.conversationID, self.conversationID)
                XCTAssertEqual(claimed.executionRunID, runID)
                runIDs.append(runID)
                return .started
            }
        )
        let waiting = await scheduler.runDueTasks()
        XCTAssertEqual(waiting.deferredCount, 1)
        XCTAssertTrue(runIDs.isEmpty)
        active = true
        let started = await scheduler.runDueTasks()
        XCTAssertEqual(started.startedCount, 1)
        XCTAssertEqual(runIDs.count, 1)
        _ = await scheduler.runDueTasks()
        XCTAssertEqual(runIDs.count, 1)
        await scheduler.recordRunTerminal(runID: "old-unrelated", status: "completed")
        XCTAssertEqual(store.task(id: task.id)?.status, .running)
        await scheduler.recordRunTerminal(runID: runIDs[0], status: "completed")
        XCTAssertEqual(IOSWakeTaskStore(fileURL: url).task(id: task.id)?.status, .completed)
    }

    func testConcurrentTriggersAndCancellationDuringPreparationDoNotStartAgain() async throws {
        let (store, _) = try makeStore()
        let task = try plan(store, fireAt: date)
        var resume: CheckedContinuation<Void, Never>?
        var starts = 0
        var cancelled: [String] = []
        let scheduler = IOSWakeScheduler(
            store: store, now: { self.date },
            startRun: { _, _ in
                starts += 1
                await withCheckedContinuation { resume = $0 }
                return Task.isCancelled ? .deferred("已取消") : .started
            },
            cancelRun: { cancelled.append($0) }
        )
        let first = Task { await scheduler.runDueTasks() }
        for _ in 0..<100 where resume == nil { await Task.yield() }
        XCTAssertNotNil(resume)
        let second = await scheduler.runDueTasks()
        XCTAssertEqual(second.startedCount, 0)
        XCTAssertEqual(starts, 1)
        let runID = try XCTUnwrap(store.task(id: task.id)?.executionRunID)
        try await scheduler.cancel(id: task.id, conversationID: conversationID)
        resume?.resume()
        let report = await first.value
        XCTAssertEqual(report.startedCount, 0)
        XCTAssertEqual(store.task(id: task.id)?.status, .cancelled)
        XCTAssertEqual(cancelled, [runID])
        await scheduler.recordRunTerminal(runID: runID, status: "completed")
        XCTAssertEqual(store.task(id: task.id)?.status, .cancelled)
    }

    func testExplicitRetryDoesNotReplayCompletedOrCancelledTask() async throws {
        let (store, _) = try makeStore()
        let task = try plan(store, fireAt: date)
        var starts = 0
        let scheduler = IOSWakeScheduler(store: store, now: { self.date }, startRun: { _, _ in
            starts += 1
            return starts == 1 ? .failed("服务商请求失败") : .started
        })
        _ = await scheduler.runDueTasks()
        XCTAssertEqual(store.task(id: task.id)?.status, .failed)
        _ = await scheduler.runDueTasks()
        XCTAssertEqual(starts, 1)
        let retry = await scheduler.runTask(id: task.id)
        XCTAssertEqual(retry.startedCount, 1)
        let runID = try XCTUnwrap(store.task(id: task.id)?.executionRunID)
        await scheduler.recordRunTerminal(runID: runID, status: "completed")
        let completed = await scheduler.runTask(id: task.id)
        XCTAssertEqual(completed.failedCount, 1)
        XCTAssertEqual(starts, 2)
    }

    func testBackgroundSubmissionFailureKeepsPlanAndEventOrTimeCanTriggerIt() async throws {
        let (store, _) = try makeStore()
        let scheduler = IOSWakeScheduler(
            store: store, now: { self.date }, startRun: { _, _ in .started },
            submitSystem: { _ in throw CocoaError(.featureUnsupported) }
        )
        let task = try await scheduler.schedule(
            conversationID: conversationID, sourceRunID: "authorized-run",
            origin: IOSWakeOrigin(userMessageID: "original", userText: "等结果后继续"),
            title: "等待结果", prompt: "收集结果", fireAt: date, event: "ready",
            requiresForeground: false, requestID: "plan"
        )
        XCTAssertEqual(store.task(id: task.id)?.status, .scheduled)
        XCTAssertTrue(scheduler.schedulingStatus.contains("计划已保存"))
        let report = await scheduler.runDueTasks()
        XCTAssertEqual(report.startedCount, 1)
        XCTAssertNotNil(store.task(id: task.id)?.executionRunID)
    }

    func testWakeLinksRoundTripAndRejectForeignOrInvalidTask() {
        let destinations: [IOSAppDeepLink.Destination] = [.wakeTasks, .wakeDueTasks, .wakeTask(id: UUID().uuidString)]
        for destination in destinations {
            XCTAssertEqual(IOSAppDeepLink.url(for: destination).flatMap { IOSAppDeepLink.parse($0) }, destination)
        }
        XCTAssertNil(IOSAppDeepLink.parse(URL(string: "amber://wake/not-a-task")!))
        XCTAssertNil(IOSAppDeepLink.parse(URL(string: "https://wake/due")!))
        XCTAssertNil(IOSAppDeepLink.parse(URL(string: "amber://wake/due?prompt=injected")!))
    }

    func testEventWaitingForForegroundGetsOneReminderAndCancelKeepsOtherPlans() async throws {
        let (store, _) = try makeStore()
        let eventTask = try plan(store, event: "ready", foreground: true)
        let timeTask = try plan(store, fireAt: date.addingTimeInterval(600))
        let center = WakeNotificationCenter()
        let scheduler = IOSWakeScheduler(
            store: store, now: { self.date }, isForeground: { false }, notifications: center,
            startRun: { _, _ in XCTFail("A foreground task cannot start in the background"); return .started }
        )
        await scheduler.refreshScheduling()
        XCTAssertEqual(center.addCount, 1)
        _ = await scheduler.runDueTasks(event: "ready", content: "收到回复")
        XCTAssertEqual(center.addCount, 2)
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertTrue(center.requests.values.contains { IOSAppDeepLink.parse($0.deepLink) == .wakeTask(id: eventTask.id) })
        center.requests.removeValue(forKey: "amber.wake.\(eventTask.id)")
        await scheduler.refreshScheduling()
        XCTAssertEqual(center.addCount, 2, "Dismissing a reminder must not recreate it on every scan")
        try await scheduler.cancel(id: eventTask.id)
        XCTAssertNotNil(center.requests["amber.wake.\(timeTask.id)"])
        XCTAssertEqual(store.task(id: eventTask.id)?.status, .cancelled)
    }

    func testFastTerminalCallbackStillReportsTheRunThatActuallyStarted() async throws {
        let (store, _) = try makeStore()
        let task = try plan(store, fireAt: date)
        var owner: IOSWakeScheduler!
        owner = IOSWakeScheduler(store: store, now: { self.date }, startRun: { _, runID in
            await owner.recordRunTerminal(runID: runID, status: "completed")
            return .started
        })
        let report = await owner.runDueTasks()
        XCTAssertEqual(report.startedCount, 1)
        XCTAssertEqual(store.task(id: task.id)?.status, .completed)
    }

    func testSystemWindowStaysOpenThroughActualTerminalAndExpirationDoesNotReplay() async throws {
        let (store, _) = try makeStore()
        let task = try plan(store, fireAt: date)
        var cancelled: [String] = []
        var starts = 0
        let scheduler = IOSWakeScheduler(
            store: store, now: { self.date },
            startRun: { _, _ in starts += 1; return .started },
            cancelRun: { cancelled.append($0) }
        )
        let window = Task { await scheduler.performBackgroundWake() }
        for _ in 0..<100 where store.task(id: task.id)?.status != .running { await Task.yield() }
        let runID = try XCTUnwrap(store.task(id: task.id)?.executionRunID)
        XCTAssertEqual(store.task(id: task.id)?.status, .running)
        window.cancel()
        let success = await window.value
        XCTAssertFalse(success)
        XCTAssertEqual(cancelled, [runID])
        XCTAssertEqual(store.task(id: task.id)?.status, .interrupted)
        _ = await scheduler.runDueTasks()
        XCTAssertEqual(starts, 1, "Expiration must never automatically replay side effects")
    }

    func testSystemDeliveryAdoptsAnAlreadyPreparingShortcutRun() async throws {
        let (store, _) = try makeStore()
        let task = try plan(store, fireAt: date)
        var resume: CheckedContinuation<Void, Never>?
        var cancelled: [String] = []
        let scheduler = IOSWakeScheduler(
            store: store, now: { self.date },
            startRun: { _, _ in
                await withCheckedContinuation { resume = $0 }
                return Task.isCancelled ? .deferred("已取消") : .started
            },
            cancelRun: { cancelled.append($0) }
        )
        let shortcut = Task { await scheduler.runDueTasks() }
        for _ in 0..<100 where resume == nil { await Task.yield() }
        let system = Task { await scheduler.performBackgroundWake() }
        await Task.yield()
        resume?.resume()
        let report = await shortcut.value
        XCTAssertEqual(report.startedCount, 1)
        let runID = try XCTUnwrap(store.task(id: task.id)?.executionRunID)
        system.cancel()
        let success = await system.value
        XCTAssertFalse(success)
        XCTAssertEqual(cancelled, [runID], "The second trigger must retain the existing queue owner's execution")
        XCTAssertEqual(store.task(id: task.id)?.status, .interrupted)
    }

    func testColdRecoveryRestoresCompletedResultFromItsOriginalConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversations = IOSConversationStore(baseDirectory: directory.appendingPathComponent("conversations"))
        await conversations.bootstrap()
        let conversation = try XCTUnwrap(conversations.currentConversation?.id)
        let original = UIMessage.companion.user(prompt: "等研究结果后整理")
        let url = directory.appendingPathComponent("tasks.json")
        let queue = IOSWakeTaskStore(fileURL: url, now: { self.date })
        let task = try queue.schedule(
            conversationID: conversation.toHexDashString(), sourceRunID: "source",
            origin: IOSWakeOrigin(userMessageID: original.id.toHexDashString(), userText: original.toText()),
            title: "恢复结果", prompt: "整理研究", fireAt: date,
            event: nil, requiresForeground: false, requestID: "schedule"
        )
        let claimed = try queue.claim(id: task.id, runID: "completed-before-queue-write")
        let marker = try ChatViewModel.scheduledWakeMessage(claimed)
        let expected = String(repeating: "这是本次任务的完整研究结果。", count: 300)
        let saved = await conversations.save(messages: [
            original, marker, IOSChatForegroundFixtures.assistantText(expected),
            UIMessage.companion.user(prompt: "另一个独立问题"),
            IOSChatForegroundFixtures.assistantText("后续问题的回答不属于旧任务")
        ], to: conversation)
        XCTAssertTrue(saved)
        let restored = IOSWakeTaskStore(fileURL: url, now: { self.date })
        let scheduler = IOSWakeScheduler(store: restored, now: { self.date }, isForeground: { true })
        let defaults = UserDefaults(suiteName: "WakeRecovery-\(UUID().uuidString)")!
        let db = IosDatabaseFactory.shared.createDatabase(atFilePath: directory.appendingPathComponent("runtime.db").path)
        let model = ChatViewModel(
            settingsStore: SettingsStore(userDefaults: defaults),
            sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
            agentRuntimeDao: db.agentRuntimeDao(), wakeScheduler: scheduler
        )
        model.conversationStore = conversations
        scheduler.attach(chatViewModel: model)
        _ = try await model.runStore.startRun(
            runId: "completed-before-queue-write", descriptorId: IOSDurableRunStore.Descriptor.chat,
            conversationId: conversation.toHexDashString(), startedAt: 1, inputDigest: "original-task"
        )
        _ = try await model.runStore.transitionFromAnyActive(runId: "completed-before-queue-write", to: .completed)
        _ = await scheduler.runDueTasks()
        XCTAssertEqual(restored.task(id: task.id)?.status, .completed)
        XCTAssertEqual(restored.task(id: task.id)?.resultText, expected)
        XCTAssertEqual(IOSWakeTaskStore(fileURL: url).task(id: task.id)?.resultText, expected)
        let cancelled = try await scheduler.cancel(id: task.id)
        XCTAssertEqual(cancelled.status, .completed, "A completed task must not report that it was cancelled")
    }

    func testTerminalWriteFailureReconcilesOnTheNextTriggerWithoutRestartingScheduler() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversations = IOSConversationStore(baseDirectory: directory.appendingPathComponent("conversations"))
        await conversations.bootstrap()
        let conversation = try XCTUnwrap(conversations.currentConversation?.id)
        let url = directory.appendingPathComponent("tasks.json")
        var rejectWrite = false
        let queue = IOSWakeTaskStore(fileURL: url, now: { self.date }, write: { data, url in
            if rejectWrite { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let scheduler = IOSWakeScheduler(store: queue, now: { self.date })
        let suite = "WakeTerminalWriteRecovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let db = IosDatabaseFactory.shared.createDatabase(atFilePath: directory.appendingPathComponent("runtime.db").path)
        let model = ChatViewModel(
            settingsStore: SettingsStore(userDefaults: defaults),
            sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
            agentRuntimeDao: db.agentRuntimeDao(), wakeScheduler: scheduler
        )
        model.conversationStore = conversations
        scheduler.attach(chatViewModel: model)
        _ = await scheduler.runDueTasks()

        let original = UIMessage.companion.user(prompt: "等研究结果后整理")
        let task = try queue.schedule(
            conversationID: conversation.toHexDashString(), sourceRunID: "source",
            origin: IOSWakeOrigin(userMessageID: original.id.toHexDashString(), userText: original.toText()),
            title: "恢复已完成结果", prompt: "整理研究", fireAt: date,
            event: nil, requiresForeground: false, requestID: "schedule"
        )
        let runID = "terminal-write-failed-once"
        let claimed = try queue.claim(id: task.id, runID: runID)
        let marker = try ChatViewModel.scheduledWakeMessage(claimed)
        let expected = "已完成的研究结果，不应重新执行。"
        let saved = await conversations.save(messages: [
            original, marker, IOSChatForegroundFixtures.assistantText(expected)
        ], to: conversation)
        XCTAssertTrue(saved)
        _ = try await model.runStore.startRun(
            runId: runID, descriptorId: IOSDurableRunStore.Descriptor.chat,
            conversationId: conversation.toHexDashString(), startedAt: 1, inputDigest: "original-task"
        )
        _ = try await model.runStore.transitionFromAnyActive(runId: runID, to: .completed)

        rejectWrite = true
        await scheduler.recordRunTerminal(runID: runID, status: "completed", result: expected)
        XCTAssertEqual(queue.task(id: task.id)?.status, .running)
        XCTAssertNotNil(scheduler.lastError)
        rejectWrite = false

        let report = await scheduler.runDueTasks()
        XCTAssertEqual(report.startedCount, 0, "An already completed durable run must only be reconciled.")
        XCTAssertEqual(queue.task(id: task.id)?.status, .completed)
        XCTAssertEqual(queue.task(id: task.id)?.resultText, expected)
        XCTAssertEqual(IOSWakeTaskStore(fileURL: url).task(id: task.id)?.status, .completed)
        XCTAssertEqual(IOSWakeTaskStore(fileURL: url).task(id: task.id)?.resultText, expected)
    }

    func testEventReplacesAFutureFallbackReminderWithoutWaitingForThatDate() async throws {
        let (store, _) = try makeStore()
        let task = try plan(store, fireAt: date.addingTimeInterval(600), event: "ready", foreground: true)
        let center = WakeNotificationCenter()
        let scheduler = IOSWakeScheduler(
            store: store, now: { self.date }, isForeground: { false }, notifications: center,
            startRun: { _, _ in XCTFail("Foreground work must wait"); return .started }
        )
        await scheduler.refreshScheduling()
        XCTAssertEqual(center.requests["amber.wake.\(task.id)"]?.fireDate, date.addingTimeInterval(600))
        _ = await scheduler.runDueTasks(event: "ready")
        XCTAssertEqual(center.requests["amber.wake.\(task.id)"]?.fireDate, date.addingTimeInterval(1))
        XCTAssertEqual(center.addCount, 2)
    }

    func testLegacyArchiveDecodingAndRecurringWatchSilentRenewalThenTriggeredCompletion() async throws {
        let (_, legacyURL) = try makeStore()
        let legacyID = UUID().uuidString
        let legacyJSON = """
        {
          "version": 1,
          "tasks": [
            {
              "id": "\(legacyID)",
              "requestID": "legacy-req-1",
              "conversationID": "\(conversationID)",
              "sourceRunID": "legacy-run-1",
              "origin": {
                "userMessageID": "msg-1",
                "userText": "老版本保存的单次提醒"
              },
              "title": "旧版单次任务",
              "prompt": "到期后执行一次",
              "createdAt": 800000000,
              "fireAt": 800003600,
              "requiresForeground": false,
              "status": "scheduled"
            }
          ]
        }
        """
        try Data(legacyJSON.utf8).write(to: legacyURL)
        let decodedLegacyStore = IOSWakeTaskStore(fileURL: legacyURL, now: { self.date })
        XCTAssertNil(decodedLegacyStore.loadError)
        let legacyTask = try XCTUnwrap(decodedLegacyStore.task(id: legacyID))
        XCTAssertFalse(legacyTask.isRecurringWatch)
        XCTAssertNil(legacyTask.intervalMinutes)
        XCTAssertNil(legacyTask.watchCondition)
        XCTAssertTrue(legacyTask.stopWhenTriggered)
        XCTAssertEqual(legacyTask.checkCount, 0)
        XCTAssertNil(legacyTask.lastCheckedAt)
        XCTAssertNil(legacyTask.lastCheckSummary)

        var currentNow = date
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recurring-tasks.json")
        let store = IOSWakeTaskStore(fileURL: url, now: { currentNow })
        let watchTask = try store.schedule(
            conversationID: conversationID,
            sourceRunID: "watch-source-run",
            origin: IOSWakeOrigin(userMessageID: "user-oil", userText: "帮我盯着国内油价调价窗口，有变动告诉我"),
            title: "盯国内油价调价窗口",
            prompt: "查询国内成品油调价窗口与预计涨跌幅",
            fireAt: nil,
            event: nil,
            requiresForeground: false,
            requestID: "oil-watch-1",
            intervalMinutes: 360,
            watchCondition: "国内油价调价窗口开启或预计涨跌超 50 元/吨",
            stopWhenTriggered: true
        )
        XCTAssertTrue(watchTask.isRecurringWatch)
        XCTAssertEqual(watchTask.fireAt, date.addingTimeInterval(360 * 60))

        let scheduler = IOSWakeScheduler(
            store: store,
            now: { currentNow },
            isForeground: { true },
            startRun: { _, _ in .started }
        )

        // Advance to first check window -> silent renewal
        currentNow = date.addingTimeInterval(360 * 60)
        let firstReport = await scheduler.runDueTasks()
        XCTAssertEqual(firstReport.startedCount, 1)
        let firstRunID = try XCTUnwrap(firstReport.runIDs.first)
        await scheduler.recordRunTerminal(
            runID: firstRunID,
            status: "completed",
            result: "[WATCH_SILENT] 第 1 次巡检：当前处于计价周期第 6 个工作日，暂未开启调价窗口"
        )

        let afterSilent = try XCTUnwrap(store.task(id: watchTask.id))
        XCTAssertEqual(afterSilent.status, .scheduled)
        XCTAssertEqual(afterSilent.checkCount, 1)
        XCTAssertEqual(afterSilent.lastCheckedAt, currentNow)
        XCTAssertEqual(afterSilent.lastCheckSummary, "第 1 次巡检：当前处于计价周期第 6 个工作日，暂未开启调价窗口")
        XCTAssertEqual(afterSilent.fireAt, currentNow.addingTimeInterval(360 * 60))
        XCTAssertNil(afterSilent.executionRunID)
        XCTAssertEqual(afterSilent.attemptNumber, 1)

        // Advance to second check window -> condition triggered & completed
        currentNow = currentNow.addingTimeInterval(360 * 60)
        let secondReport = await scheduler.runDueTasks()
        XCTAssertEqual(secondReport.startedCount, 1)
        let secondRunID = try XCTUnwrap(secondReport.runIDs.first)
        await scheduler.recordRunTerminal(
            runID: secondRunID,
            status: "completed",
            result: "[WATCH_TRIGGERED] 调价窗口今晚 24 时开启，预计汽柴油上调 85 元/吨，建议提前加油"
        )

        let afterTriggered = try XCTUnwrap(store.task(id: watchTask.id))
        XCTAssertEqual(afterTriggered.status, .completed)
        XCTAssertEqual(afterTriggered.checkCount, 2)
        XCTAssertEqual(afterTriggered.lastCheckedAt, currentNow)
        XCTAssertEqual(afterTriggered.lastCheckSummary, "调价窗口今晚 24 时开启，预计汽柴油上调 85 元/吨，建议提前加油")
        XCTAssertTrue(afterTriggered.resultText?.contains("调价窗口今晚 24 时开启") == true)

        // Continuous watch with stopWhenTriggered == false keeps rolling after trigger
        let continuousTask = try store.schedule(
            conversationID: conversationID,
            sourceRunID: "watch-source-run-2",
            origin: IOSWakeOrigin(userMessageID: "user-repo", userText: "持续盯着仓库发版，每次发版都提醒我"),
            title: "持续盯仓库 Release",
            prompt: "检查是否有新 Release",
            fireAt: currentNow,
            event: nil,
            requiresForeground: false,
            requestID: "repo-watch-continuous",
            intervalMinutes: 60,
            watchCondition: "发布新版本",
            stopWhenTriggered: false
        )
        let thirdReport = await scheduler.runDueTasks()
        let thirdRunID = try XCTUnwrap(thirdReport.runIDs.first)
        await scheduler.recordRunTerminal(
            runID: thirdRunID,
            status: "completed",
            result: "[WATCH_TRIGGERED] 已发布 v2.1.0",
            conditionTriggered: true
        )
        let afterContinuousTrigger = try XCTUnwrap(store.task(id: continuousTask.id))
        XCTAssertEqual(afterContinuousTrigger.status, .scheduled)
        XCTAssertEqual(afterContinuousTrigger.checkCount, 1)
        XCTAssertEqual(afterContinuousTrigger.fireAt, currentNow.addingTimeInterval(60 * 60))
        XCTAssertTrue(afterContinuousTrigger.resultText?.contains("已发布 v2.1.0") == true)
    }
}

@MainActor
private final class WakeNotificationCenter: IOSLocalNotificationCenter {
    var requests: [String: IOSLocalNotificationRequest] = [:]
    var addCount = 0
    func authorization() async -> IOSLocalNotificationAuthorization { .allowed }
    func requestAuthorization() async throws -> Bool { true }
    func add(_ request: IOSLocalNotificationRequest) async throws {
        requests[request.identifier] = request
        addCount += 1
    }
    func pendingRequestIdentifiers() async -> [String] { Array(requests.keys) }
    func removePendingRequests(identifiers: [String]) { for id in identifiers { requests.removeValue(forKey: id) } }
    func deliveredRequestIdentifiers() async -> [String] { [] }
    func removeDeliveredRequests(identifiers: [String]) {}
    func updateTaskCompletionSound(enabled: Bool) async throws {
        for id in requests.keys where id.hasPrefix("amber.task-complete.") {
            requests[id]?.playsSound = enabled
        }
    }
}
