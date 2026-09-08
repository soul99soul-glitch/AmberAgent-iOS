import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSWatchCompanionServiceTests: XCTestCase {
    private func makeStore(
        _ root: URL,
        suiteName: String = "IOSWatchCompanionServiceTests",
        resetDefaults: Bool = true
    ) -> IOSWatchCompanionService {
        let defaults = UserDefaults(suiteName: suiteName)!
        if resetDefaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return IOSWatchCompanionService(baseDirectory: root, defaults: defaults)
    }

    func testUnknownRecoveryRemovesOnlyFalseFailureAndPersistsCorrection() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        for (run, phase) in [("unknown", "failed"), ("done", "completed"), ("stopped", "cancelled"), ("other", "failed")] {
            XCTAssertTrue(store.recordTerminalActivity(WatchRecentActivity(
                id: run, runId: run, kind: "workflow", phase: phase,
                title: run, summary: phase, updatedAt: Date(timeIntervalSince1970: 100)
            )))
        }
        let coordinator = WatchTaskCoordinator(bridge: WatchConnectivityBridge(), companionService: store)
        XCTAssertTrue(coordinator.publishOutcomeUnknown(runId: "unknown", conversationId: "original"))
        XCTAssertEqual(Set(store.recentActivities.compactMap(\.runId)), ["done", "stopped", "other"])
        XCTAssertFalse(store.discardFailedActivityForUnresolvedRun("done"))
        XCTAssertFalse(store.discardFailedActivityForUnresolvedRun("stopped"))
        let reloaded = makeStore(root, resetDefaults: false)
        XCTAssertEqual(reloaded.recentActivities, store.recentActivities)
    }

    func testNotePersistsOriginalTextAndReplayIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-notes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let note = WatchNote(
            id: UUID().uuidString,
            text: "  原文保留\n下一行  ",
            createdAt: Date(timeIntervalSince1970: 123)
        )
        let store = makeStore(root)
        XCTAssertTrue(store.saveNote(note))
        XCTAssertEqual(store.notes.first?.text, note.text)
        XCTAssertTrue(store.saveNote(note))
        XCTAssertEqual(store.notes.count, 1)

        let reloaded = makeStore(root, suiteName: "IOSWatchCompanionServiceTests-reload")
        XCTAssertEqual(reloaded.notes.first, note)
    }

    func testCorruptNoteFileIsNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notesURL = root.appendingPathComponent("notes.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: notesURL)

        let store = makeStore(root)
        XCTAssertNotNil(store.storageError)
        XCTAssertFalse(store.saveNote(WatchNote(
            id: UUID().uuidString,
            text: "不会覆盖损坏源",
            createdAt: Date()
        )))
        XCTAssertEqual(try Data(contentsOf: notesURL), corrupt)
    }

    func testTerminalActivityPersistsAcrossRestartAndKeepsFirstTerminalTimestamp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-activities-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "IOSWatchCompanionServiceTests-activities-\(UUID().uuidString)"
        let completedAt = Date(timeIntervalSince1970: 123)
        let store = makeStore(root, suiteName: suite)
        XCTAssertTrue(store.recordTerminalActivity(WatchRecentActivity(
            id: "caller-id",
            runId: "run-history-1",
            conversationId: "conversation-1",
            kind: "response",
            phase: "completed",
            title: "一项任务",
            summary: "结果正文",
            updatedAt: completedAt
        )))

        // A repeated terminal publish is an acknowledgement of the same run,
        // rather than a new event or a mutable completion timestamp.
        XCTAssertTrue(store.recordTerminalActivity(WatchRecentActivity(
            id: "another-id",
            runId: "run-history-1",
            conversationId: "conversation-1",
            kind: "response",
            phase: "failed",
            title: "旧标题",
            summary: "旧状态",
            updatedAt: completedAt.addingTimeInterval(30)
        )))
        XCTAssertEqual(store.recentActivities.count, 1)
        XCTAssertEqual(store.recentActivities.first?.id, "run:run-history-1")
        XCTAssertEqual(store.recentActivities.first?.phase, "completed")
        XCTAssertEqual(store.recentActivities.first?.updatedAt, completedAt)

        let reloaded = makeStore(root, suiteName: suite, resetDefaults: false)
        XCTAssertEqual(reloaded.recentActivities, store.recentActivities)
    }

    func testRecoveredCompletionReplacesEarlierFailureAndCannotRegress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "WatchRecoveredCompletion.\(UUID().uuidString)"
        let service = makeStore(root, suiteName: suite)
        let failed = WatchRecentActivity(id: "ignored", runId: "recovered", conversationId: "original",
            kind: "response", phase: "failed", title: "原任务", summary: "回复已完成，但保存失败。",
            updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(service.recordTerminalActivity(failed))
        var completed = failed
        completed.phase = "completed"
        completed.summary = "恢复后已保存的真实结果"
        completed.updatedAt = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(service.recordTerminalActivity(completed))
        var lateFailure = failed
        lateFailure.updatedAt = Date(timeIntervalSince1970: 300)
        XCTAssertTrue(service.recordTerminalActivity(lateFailure))
        let reloaded = makeStore(root, suiteName: suite, resetDefaults: false)
        XCTAssertEqual(reloaded.recentActivities.count, 1)
        XCTAssertEqual(reloaded.recentActivities.first?.phase, "completed")
        XCTAssertEqual(reloaded.recentActivities.first?.summary, completed.summary)
        XCTAssertEqual(reloaded.recentActivities.first?.updatedAt, completed.updatedAt)
        XCTAssertEqual(reloaded.recentActivities.first?.conversationId, "original")
    }

    func testDurableRecoveryPromotesSavedResultButPreservesCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeStore(root)
        let failed = WatchRecentActivity(id: "run:saved", runId: "saved", kind: "response",
            phase: "failed", title: "保存待恢复", summary: "保存失败", updatedAt: Date(timeIntervalSince1970: 100))
        var cancelled = failed
        cancelled.id = "run:cancelled"
        cancelled.runId = "cancelled"
        cancelled.phase = "cancelled"
        XCTAssertTrue(service.recordTerminalActivity(failed))
        XCTAssertTrue(service.recordTerminalActivity(cancelled))
        var completed = failed
        completed.phase = "completed"
        completed.summary = "已完成"
        completed.updatedAt = Date(timeIntervalSince1970: 200)
        var staleCancelledCompletion = completed
        staleCancelledCompletion.id = cancelled.id
        staleCancelledCompletion.runId = cancelled.runId
        XCTAssertTrue(service.restoreTerminalActivities([completed, staleCancelledCompletion]))
        XCTAssertEqual(service.recentActivities.first(where: { $0.runId == "saved" })?.phase, "completed")
        XCTAssertEqual(service.recentActivities.first(where: { $0.runId == "cancelled" }), cancelled)
    }

    func testNoteProjectsAsDistinctActivityAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-note-activity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "IOSWatchCompanionServiceTests-note-activity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let note = WatchNote(
            id: "note-history-1",
            text: "首行标题\n完整记事原文",
            createdAt: Date(timeIntervalSince1970: 456)
        )
        let store = IOSWatchCompanionService(baseDirectory: root, defaults: defaults)
        XCTAssertTrue(store.saveNote(note))

        let library = await store.makeLibrarySnapshot(
            sharedSettings: settings,
            conversationStore: nil,
            now: Date(timeIntervalSince1970: 500)
        )
        let activity = try XCTUnwrap(library.activities?.first)
        XCTAssertEqual(activity.id, "note:note-history-1")
        XCTAssertNil(activity.runId)
        XCTAssertEqual(activity.kind, "note")
        XCTAssertEqual(activity.phase, "saved")
        XCTAssertEqual(activity.title, "首行标题")
        XCTAssertTrue(activity.summary.contains("完整记事原文"))

        let reloaded = IOSWatchCompanionService(baseDirectory: root, defaults: defaults)
        let reloadedLibrary = await reloaded.makeLibrarySnapshot(
            sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
            conversationStore: nil,
            now: Date(timeIntervalSince1970: 501)
        )
        XCTAssertEqual(reloadedLibrary.activities?.first, activity)
    }

    func testOldLibraryPayloadDecodesWithoutRecentActivities() throws {
        let payload = Data("""
        {
          "assistantName": "Amber",
          "isConfigured": true,
          "quickActions": [],
          "recent": [],
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(WatchLibrarySnapshot.self, from: payload)
        XCTAssertNil(library.activities)
    }

    func testOldActivityPayloadDecodesWithoutResultTitle() throws {
        let payload = Data("""
        {
          "id": "run:legacy",
          "runId": "legacy",
          "conversationId": "conversation-legacy",
          "kind": "response",
          "phase": "completed",
          "title": "旧会话标题",
          "summary": "旧结果",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let activity = try decoder.decode(WatchRecentActivity.self, from: payload)
        XCTAssertNil(activity.resultTitle)
    }

    func testResultTitleSurvivesConversationTitleProjectionAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-result-title-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "WatchResultTitle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = IOSWatchCompanionService(baseDirectory: root, defaults: defaults)
        let conversationStore = IOSConversationStore(
            baseDirectory: root.appendingPathComponent("conversations", isDirectory: true)
        )
        let didCreateConversation = await conversationStore.newConversation()
        XCTAssertTrue(didCreateConversation)
        let conversationID = try XCTUnwrap(conversationStore.currentConversation?.id)
        await conversationStore.renameConversation(
            id: conversationID,
            title: "开发一个扎小人的小应用，尽量精美，有完整交互"
        )
        let activity = WatchRecentActivity(
            id: "ignored-id",
            runId: "result-title-run",
            conversationId: conversationID.toHexDashString(),
            kind: "response",
            phase: "completed",
            title: "生产者活动标题",
            resultTitle: "扎小人",
            summary: "小应用已保存",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertTrue(service.recordTerminalActivity(activity))

        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let projectedLibrary = await service.makeLibrarySnapshot(
            sharedSettings: settings,
            conversationStore: conversationStore,
            now: Date(timeIntervalSince1970: 200)
        )
        let projected = try XCTUnwrap(projectedLibrary.activities?.first)
        XCTAssertEqual(projected.resultTitle, "扎小人")
        XCTAssertEqual(projected.title, "生产者活动标题")

        let reloaded = IOSWatchCompanionService(baseDirectory: root, defaults: defaults)
        let reloadedLibrary = await reloaded.makeLibrarySnapshot(
            sharedSettings: settings,
            conversationStore: conversationStore,
            now: Date(timeIntervalSince1970: 300)
        )
        let reloadedProjected = try XCTUnwrap(reloadedLibrary.activities?.first)
        XCTAssertEqual(reloadedProjected.resultTitle, "扎小人")
    }

    func testOlderTerminalPublishIsRecordedWithoutReplacingCurrentRun() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-old-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "IOSWatchCompanionServiceTests-old-run-\(UUID().uuidString)"
        let service = makeStore(root, suiteName: suite)
        let coordinator = WatchTaskCoordinator(
            bridge: WatchConnectivityBridge(),
            companionService: service
        )
        coordinator.registerRun(runId: "run-old", startedAt: 100)
        coordinator.registerRun(runId: "run-current", startedAt: 200)
        XCTAssertTrue(coordinator.publish(
            runId: "run-current",
            conversationId: "conversation-current",
            presentation: .generatingResponse(modelName: "model")
        ))
        XCTAssertFalse(coordinator.publish(
            runId: "run-old",
            conversationId: "conversation-old",
            presentation: .failed(retryable: true),
            summary: "旧任务的真实失败结果"
        ))

        XCTAssertEqual(coordinator.currentSnapshot().runId, "run-current")
        XCTAssertEqual(coordinator.currentSnapshot().phase, "running")
        XCTAssertEqual(service.recentActivities.map(\.runId), ["run-old"])
        XCTAssertEqual(service.recentActivities.first?.summary, "旧任务的真实失败结果")
    }

    func testDurableRecoveryKeepsMatchingCachedTerminalSummary() async throws {
        let runId = "watch-cached-history-\(UUID().uuidString)"
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let dao = IosDatabaseFactory.shared.createDatabase().agentRuntimeDao()
        let run = AgentRunEntity(
            runId: runId,
            parentRunId: nil,
            agentDescriptorId: IOSDurableRunStore.Descriptor.chat,
            agentVersion: "1",
            conversationId: nil,
            messageNodeId: nil,
            producesMessageId: nil,
            assistantId: nil,
            status: "completed",
            inputDigest: "watch-cached-history",
            inputSnapshotRef: nil,
            inputSchemaVersion: 1,
            startedAt: now,
            finishedAt: KotlinLong(value: now),
            interruptedReason: nil,
            terminalReason: nil,
            providerId: nil,
            modelId: nil,
            promptVersion: nil,
            toolCatalogVersion: nil,
            capabilitySnapshot: nil
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dao.insertRunIfAbsent(run: run) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-cached-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "IOSWatchCompanionServiceTests-cached-history-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = IOSWatchCompanionService(baseDirectory: root, defaults: defaults)
        XCTAssertTrue(service.recordTerminalActivity(WatchRecentActivity(
            id: "run:\(runId)",
            runId: runId,
            kind: "response",
            phase: "failed",
            title: "旧会话标题",
            resultTitle: "冷恢复成果",
            summary: "保存失败",
            updatedAt: Date(timeIntervalSince1970: 100)
        )))
        let bridge = WatchConnectivityBridge()
        var cached = WatchTaskSnapshot.idle
        cached.runId = runId
        cached.phase = "completed"
        cached.summary = "这是真实缓存的完成摘要"
        cached.updatedAt = Date()
        bridge.publish(cached)
        let coordinator = WatchTaskCoordinator(
            bridge: bridge,
            companionService: service
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        coordinator.attach(chatViewModel: viewModel)
        await coordinator.refreshWatchSnapshot()

        XCTAssertEqual(
            service.recentActivities.first(where: { $0.runId == runId })?.summary,
            "这是真实缓存的完成摘要"
        )
        XCTAssertEqual(
            service.recentActivities.first(where: { $0.runId == runId })?.resultTitle,
            "冷恢复成果"
        )
    }

    func testClaimThenFinalizeReceiptStoresNoSnapshotLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-receipts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = WatchTaskActionRequest(
            requestId: UUID().uuidString,
            runId: "",
            conversationId: nil,
            decisionId: nil,
            action: .ask,
            optionId: nil,
            text: "问一个问题",
            createdAt: Date()
        )
        let store = makeStore(root, suiteName: "IOSWatchCompanionServiceTests-claim")
        XCTAssertTrue(store.claimReceipt(request: request))
        XCTAssertFalse(store.claimReceipt(request: request))
        XCTAssertEqual(store.receipt(for: request.requestId)?.result.deliveryUnknown, true)

        var snapshot = WatchTaskSnapshot.idle
        snapshot.library = WatchLibrarySnapshot(
            assistantName: "Amber",
            isConfigured: true,
            quickActions: [],
            recent: [],
            updatedAt: Date()
        )
        let final = WatchTaskActionResult(
            requestId: request.requestId,
            runId: "run-1",
            accepted: true,
            message: "已发送",
            snapshot: snapshot,
            conversationId: "conversation-1"
        )
        XCTAssertTrue(store.recordReceipt(request: request, result: final))
        let reloaded = makeStore(root, suiteName: "IOSWatchCompanionServiceTests-final-reload")
        let receipt = reloaded.receipt(for: request.requestId)
        XCTAssertEqual(receipt?.result.accepted, true)
        XCTAssertEqual(receipt?.result.conversationId, "conversation-1")
        XCTAssertNil(receipt?.result.snapshot)
    }

    func testCoordinatorSavesNoteWithoutAttachmentAndReplaysOneDurableNote() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-coordinator-note-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = makeStore(root, suiteName: "IOSWatchCompanionServiceTests-coordinator-note")
        let coordinator = WatchTaskCoordinator(
            bridge: WatchConnectivityBridge(),
            companionService: service
        )
        let request = WatchTaskActionRequest(
            requestId: UUID().uuidString,
            runId: "",
            conversationId: nil,
            decisionId: nil,
            action: .saveNote,
            optionId: nil,
            text: "  离线原文\n保留空格  ",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let first = await coordinator.handleWatchAction(request)
        let replay = await coordinator.handleWatchAction(request)

        XCTAssertTrue(first.accepted)
        XCTAssertTrue(replay.accepted)
        XCTAssertEqual(service.notes.filter { $0.id == request.requestId }.count, 1)
        XCTAssertEqual(service.notes.first?.text, request.text)
    }

    func testFailedNoteWriteCanRetryWithSameRequestIdAfterStorageRecovers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-note-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockedDirectory = root.appendingPathComponent("blocked")
        try Data("blocked".utf8).write(to: blockedDirectory)

        let defaults = UserDefaults(suiteName: "IOSWatchCompanionServiceTests-note-retry")!
        defaults.removePersistentDomain(forName: "IOSWatchCompanionServiceTests-note-retry")
        let service = IOSWatchCompanionService(
            baseDirectory: blockedDirectory,
            defaults: defaults
        )
        let coordinator = WatchTaskCoordinator(
            bridge: WatchConnectivityBridge(),
            companionService: service
        )
        let request = WatchTaskActionRequest(
            requestId: UUID().uuidString,
            runId: "",
            conversationId: nil,
            decisionId: nil,
            action: .saveNote,
            optionId: nil,
            text: "恢复后仍写入同一条",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let failed = await coordinator.handleWatchAction(request)
        XCTAssertFalse(failed.accepted)
        XCTAssertTrue(service.notes.isEmpty)

        try FileManager.default.removeItem(at: blockedDirectory)
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        let succeeded = await coordinator.handleWatchAction(request)

        XCTAssertTrue(succeeded.accepted)
        XCTAssertEqual(service.notes.first?.text, request.text)
    }

    func testRestartedAskClaimReturnsUnknownWithoutStartingAnotherRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-claim-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = WatchTaskActionRequest(
            requestId: UUID().uuidString,
            runId: "",
            conversationId: nil,
            decisionId: nil,
            action: .ask,
            optionId: nil,
            text: "只执行一次",
            createdAt: Date()
        )
        let firstStore = makeStore(root, suiteName: "IOSWatchCompanionServiceTests-claim-restart")
        XCTAssertTrue(firstStore.claimReceipt(request: request))

        let restartedStore = makeStore(root, suiteName: "IOSWatchCompanionServiceTests-claim-restart-reload")
        let coordinator = WatchTaskCoordinator(
            bridge: WatchConnectivityBridge(),
            companionService: restartedStore
        )
        let replay = await coordinator.handleWatchAction(request)

        XCTAssertFalse(replay.accepted)
        XCTAssertEqual(replay.deliveryUnknown, true)
        XCTAssertEqual(coordinator.currentSnapshot().runId, "")
    }

    func testExplicitEmptyQuickSelectionStaysEmptyAfterRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-quick-selection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = makeStore(root, suiteName: "IOSWatchCompanionServiceTests-empty-selection")
        let settingsDefaults = UserDefaults(suiteName: "IOSWatchCompanionServiceTests-empty-selection-settings")!
        settingsDefaults.removePersistentDomain(forName: "IOSWatchCompanionServiceTests-empty-selection-settings")
        let settings = IOSSharedSettingsStore(userDefaults: settingsDefaults)
        XCTAssertNotNil(service.saveQuickAction(title: "给我一个灵感", prompt: "请给我一个写作练习", sharedSettings: settings))
        let before = await service.makeLibrarySnapshot(
            sharedSettings: settings,
            conversationStore: nil
        )
        XCTAssertFalse(before.quickActions.isEmpty)

        service.setSelectedQuickActionIDs([])
        let after = await service.makeLibrarySnapshot(
            sharedSettings: settings,
            conversationStore: nil
        )
        let reloaded = makeStore(
            root,
            suiteName: "IOSWatchCompanionServiceTests-empty-selection",
            resetDefaults: false
        )
        let afterReload = await reloaded.makeLibrarySnapshot(
            sharedSettings: settings,
            conversationStore: nil
        )

        XCTAssertTrue(service.hasConfiguredQuickActionSelection)
        XCTAssertTrue(reloaded.hasConfiguredQuickActionSelection)
        XCTAssertTrue(after.quickActions.isEmpty)
        XCTAssertTrue(afterReload.quickActions.isEmpty)
    }

    func testQuickActionsCanBeCreatedEditedReloadedAndDeletedWithoutRoutingOnlySeeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "WatchQuickEdit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let service = IOSWatchCompanionService(baseDirectory: root, defaults: defaults)
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let existingMessages = settings.snapshot.quickMessages.count
        XCTAssertNil(service.saveQuickAction(title: "Route only", prompt: "[ROUTE:image]\n", sharedSettings: settings))
        let initialLibrary = await service.makeLibrarySnapshot(sharedSettings: settings, conversationStore: nil)
        XCTAssertTrue(initialLibrary.quickActions.isEmpty)
        let action = try XCTUnwrap(service.saveQuickAction(title: "灵感", prompt: "给我一个写作灵感", sharedSettings: settings))
        XCTAssertEqual(settings.snapshot.quickMessages.count, existingMessages + 1)
        let edited = try XCTUnwrap(service.saveQuickAction(id: action.id, title: "换个灵感", prompt: "给我一个户外活动的灵感", sharedSettings: settings))
        XCTAssertEqual(edited.id, action.id)
        let restored = IOSSharedSettingsStore(userDefaults: defaults)
        let library = await service.makeLibrarySnapshot(sharedSettings: restored, conversationStore: nil)
        XCTAssertEqual(library.quickActions.first?.prompt, edited.prompt)
        XCTAssertEqual(library.quickActions.count, 1)
        XCTAssertTrue(service.deleteQuickAction(id: action.id, sharedSettings: restored))
        XCTAssertFalse(restored.snapshot.quickMessages.contains { $0.id.toHexDashString() == action.id })
        XCTAssertEqual(restored.snapshot.quickMessages.count, existingMessages)
    }

    func testWatchQuestionRejectsExistingPhoneDraftAndKeepsDraftText() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-draft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = IOSConversationStore(baseDirectory: root)
        let viewModel = ChatViewModel(settingsStore: SettingsStore())
        viewModel.conversationStore = store
        viewModel.inputText = "手机正在编辑的原文草稿"

        let result = await viewModel.startWatchQuestion(text: "来自手表的问题")

        XCTAssertFalse(result.started)
        XCTAssertEqual(viewModel.inputText, "手机正在编辑的原文草稿")
        XCTAssertTrue(result.failureMessage?.contains("草稿") == true)
    }
}
