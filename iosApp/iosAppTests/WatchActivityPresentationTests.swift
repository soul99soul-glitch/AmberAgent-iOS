import Foundation
import XCTest
@testable import iosApp

@MainActor
final class WatchActivityPresentationTests: XCTestCase {
    func testStateWithoutUnusedErrorDetailSettingKeepsNotesAndReadMarkers() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("old-settings.json")
        let entry = activity(id: "run:kept", runId: "kept", phase: "completed", updatedAt: Date(timeIntervalSince1970: 100))
        let original = WatchLocalStore(fileURL: url)
        XCTAssertTrue(original.saveNote(WatchNote(id: "kept", text: "保留记事", createdAt: entry.updatedAt)))
        XCTAssertTrue(original.markViewed(entry))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["settings"] = ["hapticsEnabled": false, "showContentPreview": true]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let restored = WatchLocalStore(fileURL: url)
        XCTAssertNil(restored.storageError)
        XCTAssertEqual(restored.note(id: "kept")?.text, "保留记事")
        XCTAssertFalse(restored.settings.hapticsEnabled)
        XCTAssertTrue(restored.settings.showContentPreview)
        XCTAssertTrue(restored.hasViewed(entry))
        XCTAssertTrue(restored.saveNote(WatchNote(id: "new", text: "继续保存", createdAt: entry.updatedAt)))
    }

    func testViewedActivityKeepsSubsecondVersionAcrossRestart() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("state.json")
        let entry = activity(id: "run:fractional", runId: "fractional", phase: "completed",
                             updatedAt: Date(timeIntervalSince1970: 1_700_000_000.375))
        let store = WatchLocalStore(fileURL: url)
        XCTAssertTrue(store.markViewed(entry))
        XCTAssertTrue(WatchLocalStore(fileURL: url).hasViewed(entry))
    }

    func testDevelopmentISOReadMarkersMigrateWithoutBlockingNotes() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("legacy-date.json")
        let entry = activity(id: "run:legacy-date", runId: "legacy-date", phase: "completed",
                             updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let first = WatchLocalStore(fileURL: url)
        XCTAssertTrue(first.saveNote(WatchNote(id: "kept", text: "保留原文", createdAt: entry.updatedAt)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["viewedActivities"] = [entry.id: "2023-11-14T22:13:20Z"]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let restored = WatchLocalStore(fileURL: url)
        XCTAssertNil(restored.storageError)
        XCTAssertEqual(restored.note(id: "kept")?.text, "保留原文")
        XCTAssertTrue(restored.hasViewed(entry))
        XCTAssertTrue(restored.saveNote(WatchNote(id: "new", text: "还能保存", createdAt: entry.updatedAt)))
        XCTAssertTrue(WatchLocalStore(fileURL: url).hasViewed(entry))
    }

    func testLegacyLibraryRecentPreviewDoesNotCountAsCompletionEvidence() {
        let library = WatchLibrarySnapshot(
            assistantName: "Amber",
            isConfigured: true,
            quickActions: [],
            recent: [WatchRecentConversation(
                id: "conversation-1",
                title: "旧聊天",
                preview: "这只是聊天列表预览",
                updatedAt: Date(timeIntervalSince1970: 100)
            )],
            activities: nil,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let activities = WatchActivityPresentation.activities(library: library, notes: [])
        XCTAssertTrue(activities.isEmpty)

        var snapshot = WatchTaskSnapshot.idle
        snapshot.runId = "run-1"
        snapshot.conversationId = "conversation-1"
        snapshot.phase = "completed"
        XCTAssertTrue(WatchActivityPresentation.showsCurrentTask(snapshot, activities: activities))
    }

    func testNonTerminalCurrentTaskAlwaysWinsOverMatchingHistory() {
        let history = [activity(
            id: "run:run-1",
            runId: "run-1",
            phase: "completed",
            updatedAt: Date(timeIntervalSince1970: 100)
        )]

        for phase in ["running", "waitingForUser", "reconnecting"] {
            var snapshot = WatchTaskSnapshot.idle
            snapshot.runId = "run-1"
            snapshot.phase = phase
            XCTAssertTrue(
                WatchActivityPresentation.showsCurrentTask(snapshot, activities: history),
                "non-terminal phase \(phase) must keep the current task card"
            )
        }
    }

    func testSameRunTerminalHistoryLetsCurrentCardYield() {
        let current = activity(
            id: "run:run-current",
            runId: "run-current",
            phase: "completed",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let old = activity(
            id: "run:run-old",
            runId: "run-old",
            phase: "failed",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let activities = WatchActivityPresentation.activities(
            library: library(activities: [old, current]),
            notes: []
        )

        var snapshot = WatchTaskSnapshot.idle
        snapshot.runId = "run-current"
        snapshot.phase = "completed"
        XCTAssertFalse(WatchActivityPresentation.showsCurrentTask(snapshot, activities: activities))
        XCTAssertEqual(Set(activities.compactMap(\.runId)), Set(["run-current", "run-old"]))
    }

    func testHistoryKeepsOlderRunsAlongsideTheNewestRun() async throws {
        let root = try makeDirectory()
        let suite = "WatchActivityHistory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = IOSWatchCompanionService(baseDirectory: root, defaults: defaults)
        let settings = IOSSharedSettingsStore(userDefaults: defaults)

        XCTAssertTrue(service.recordTerminalActivity(activity(
            id: "ignored-old-id",
            runId: "old",
            phase: "cancelled",
            updatedAt: Date(timeIntervalSince1970: 200)
        )))
        XCTAssertTrue(service.recordTerminalActivity(activity(
            id: "ignored-new-id",
            runId: "new",
            phase: "completed",
            updatedAt: Date(timeIntervalSince1970: 300)
        )))

        let library = await service.makeLibrarySnapshot(
            sharedSettings: settings,
            conversationStore: nil,
            now: Date(timeIntervalSince1970: 400)
        )
        let activities = WatchActivityPresentation.activities(library: library, notes: [])

        XCTAssertEqual(activities.map(\.runId), ["new", "old"])
        XCTAssertEqual(activities.count, 2)
    }

    func testPendingLocalNoteDeduplicatesPhoneNoteWithoutBeingMarkedCompleted() async throws {
        let root = try makeDirectory()
        let suite = "WatchActivityNotes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = IOSWatchCompanionService(baseDirectory: root, defaults: defaults)
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let phoneNote = WatchNote(
            id: "note-1",
            text: "手机已看到的原文",
            createdAt: Date(timeIntervalSince1970: 200),
            syncedAt: Date(timeIntervalSince1970: 201)
        )
        XCTAssertTrue(service.saveNote(phoneNote))

        let phoneLibrary = await service.makeLibrarySnapshot(
            sharedSettings: settings,
            conversationStore: nil,
            now: Date(timeIntervalSince1970: 400)
        )
        let pending = WatchNote(
            id: phoneNote.id,
            text: phoneNote.text,
            createdAt: Date(timeIntervalSince1970: 300),
            syncedAt: nil
        )
        let activities = WatchActivityPresentation.activities(library: phoneLibrary, notes: [pending])

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.id, "note:note-1")
        XCTAssertEqual(activities.first?.kind, "note")
        XCTAssertEqual(activities.first?.phase, "pending")
    }

    func testActivityOrderingIsStableForEqualDatesAndDifferentInputOrder() {
        let sameDate = Date(timeIntervalSince1970: 500)
        let first = activity(id: "z", runId: "run-z", phase: "completed", updatedAt: sameDate)
        let second = activity(id: "a", runId: "run-a", phase: "completed", updatedAt: sameDate)
        let third = activity(id: "m", runId: "run-m", phase: "failed", updatedAt: sameDate.addingTimeInterval(-1))

        let orderOne = WatchActivityPresentation.activities(
            library: library(activities: [first, second, third]), notes: []
        ).map(\.id)
        let orderTwo = WatchActivityPresentation.activities(
            library: library(activities: [third, first, second]), notes: []
        ).map(\.id)

        XCTAssertEqual(orderOne, ["a", "z", "m"])
        XCTAssertEqual(orderTwo, orderOne)
    }

    func testViewedActivitiesPersistAcrossRestartAndKeepEveryRecord() throws {
        let url = try makeURL("viewed.json")
        let firstActivity = activity(
            id: "run:first",
            runId: "first",
            phase: "completed",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let secondActivity = activity(
            id: "run:second",
            runId: "second",
            phase: "failed",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let store = WatchLocalStore(fileURL: url)

        XCTAssertTrue(store.markViewed(firstActivity))
        XCTAssertTrue(store.markViewed(secondActivity))
        XCTAssertTrue(store.hasViewed(firstActivity))
        XCTAssertTrue(store.hasViewed(secondActivity))

        let relaunched = WatchLocalStore(fileURL: url)
        XCTAssertTrue(relaunched.hasViewed(firstActivity))
        XCTAssertTrue(relaunched.hasViewed(secondActivity))
        XCTAssertEqual(relaunched.viewedActivities.count, 2)
    }

    func testViewedRevisionMustReachTheActivityBeforeItCountsAsRead() throws {
        let url = try makeURL("viewed-revision.json")
        let old = activity(
            id: "run:revision",
            runId: "revision",
            phase: "completed",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = activity(
            id: old.id,
            runId: old.runId,
            phase: "completed",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let store = WatchLocalStore(fileURL: url)

        XCTAssertTrue(store.markViewed(old))
        XCTAssertFalse(store.hasViewed(newer))
        XCTAssertTrue(store.markViewed(newer))
        XCTAssertTrue(store.hasViewed(newer))
    }

    func testExistingStoreWritesPreserveViewedActivities() throws {
        let url = try makeURL("viewed-through-writes.json")
        let viewed = activity(
            id: "run:preserved",
            runId: "preserved",
            phase: "completed",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let store = WatchLocalStore(fileURL: url)
        XCTAssertTrue(store.markViewed(viewed))

        let note = WatchNote(
            id: "note-preserved",
            text: "持久化写入",
            createdAt: Date(timeIntervalSince1970: 101)
        )
        XCTAssertTrue(store.saveNote(note))
        _ = store.ensureDraft(key: "ask", mode: .ask, initialText: "草稿")
        store.updateSettings { $0.hapticsEnabled = false }
        XCTAssertTrue(store.removeDraft(key: "ask"))
        XCTAssertTrue(store.markNoteSynced(id: note.id, at: Date(timeIntervalSince1970: 102)))
        XCTAssertTrue(store.clearCache())

        let relaunched = WatchLocalStore(fileURL: url)
        XCTAssertTrue(relaunched.hasViewed(viewed))
        XCTAssertEqual(relaunched.viewedActivities[viewed.id], viewed.updatedAt)
    }

    func testLegacyJSONWithoutViewedActivitiesLoadsWithEmptyReadState() throws {
        let url = try makeURL("legacy.json")
        let note = WatchNote(
            id: "legacy-note",
            text: "旧格式仍应读取",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let original = WatchLocalStore(fileURL: url)
        XCTAssertTrue(original.saveNote(note))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object.removeValue(forKey: "viewedActivities")
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try legacyData.write(to: url, options: .atomic)

        let reloaded = WatchLocalStore(fileURL: url)
        XCTAssertNil(reloaded.storageError)
        XCTAssertEqual(reloaded.note(id: note.id)?.text, note.text)
        XCTAssertTrue(reloaded.viewedActivities.isEmpty)
        XCTAssertFalse(reloaded.hasViewed(activity(
            id: "run:legacy",
            runId: "legacy",
            phase: "completed",
            updatedAt: Date(timeIntervalSince1970: 100)
        )))
    }

    func testCorruptStateBlocksViewedWriteAndPreservesOriginalBytes() throws {
        let url = try makeURL("corrupt.json")
        let original = Data("not-json-state".utf8)
        try original.write(to: url, options: .atomic)
        let store = WatchLocalStore(fileURL: url)
        let viewed = activity(
            id: "run:corrupt",
            runId: "corrupt",
            phase: "completed",
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNotNil(store.storageError)
        XCTAssertFalse(store.markViewed(viewed))
        XCTAssertFalse(store.saveNote(WatchNote(
            id: "note-corrupt",
            text: "不能覆盖原文件",
            createdAt: Date(timeIntervalSince1970: 101)
        )))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private func activity(
        id: String,
        runId: String? = nil,
        kind: String = "response",
        phase: String,
        updatedAt: Date
    ) -> WatchRecentActivity {
        WatchRecentActivity(
            id: id,
            runId: runId,
            conversationId: runId.map { "conversation-\($0)" },
            kind: kind,
            phase: phase,
            title: id,
            summary: phase,
            updatedAt: updatedAt
        )
    }

    private func library(activities: [WatchRecentActivity]) -> WatchLibrarySnapshot {
        WatchLibrarySnapshot(
            assistantName: "Amber",
            isConfigured: true,
            quickActions: [],
            recent: [],
            activities: activities,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeURL(_ name: String) throws -> URL {
        try makeDirectory().appendingPathComponent(name)
    }
}
