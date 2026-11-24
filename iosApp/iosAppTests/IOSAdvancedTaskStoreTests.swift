import Foundation
import Testing
@testable import iosApp

@Suite(.serialized)
@MainActor
struct IOSAdvancedTaskStoreTests {
    @Test func migrationCopiesOriginalBytesAndPrefersNewerFileOnRestart() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = URL.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appending(path: "tasks.json")
        let legacy = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let record = legacy.startTask(kind: .modelCouncil, title: "旧任务", objective: "保留元数据", metadata: ["stage": "3"])
        let bytes = try #require(defaults.data(forKey: "tasks"))
        let store = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks", fileURL: url)
        #expect(store.tasks == [record])
        #expect(try Data(contentsOf: url) == bytes)
        #expect(defaults.object(forKey: "tasks") == nil)
        store.appendLog(id: record.id, chunk: "partial")
        let finished = store.updateTask(id: record.id, status: .completed)
        defaults.set(bytes, forKey: "tasks")
        let relaunched = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks", fileURL: url)
        #expect(relaunched.task(id: record.id) == finished)
        #expect(defaults.object(forKey: "tasks") == nil)
    }

    @Test func migrationWriteFailureKeepsReadableLegacyUntilRetry() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = URL.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appending(path: "tasks.json")
        let legacy = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let record = legacy.startTask(kind: .modelCouncil, title: "旧任务", objective: "retry")
        try Data().write(to: directory)
        let blocked = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks", fileURL: url)
        #expect(blocked.tasks == [record])
        #expect(defaults.data(forKey: "tasks") != nil)
        try FileManager.default.removeItem(at: directory)
        let recovered = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks", fileURL: url)
        #expect(recovered.tasks == [record])
        #expect(defaults.data(forKey: "tasks") == nil)
    }

    @Test func burstWritesLatestSnapshotAndTerminalSupersedesPendingWrite() async throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = URL.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appending(path: "tasks.json")
        let store = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks", fileURL: url)
        let record = store.startTask(kind: .remoteCommand, title: "job", objective: "log")
        let first = try #require(store.snapshotFile?.pending)
        for i in 1...100 { store.appendLog(id: record.id, chunk: "row \(i)\n") }
        #expect(first.isCancelled)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await store.snapshotFile?.pending?.value
        #expect(try JSONDecoder().decode([IOSAdvancedTaskRecord].self, from: Data(contentsOf: url)) == store.tasks)
        store.appendLog(id: record.id, chunk: "last row")
        let superseded = try #require(store.snapshotFile?.pending)
        _ = store.updateTask(id: record.id, status: .cancelled)
        await superseded.value
        #expect(superseded.isCancelled)
        #expect(try JSONDecoder().decode([IOSAdvancedTaskRecord].self, from: Data(contentsOf: url)) == store.tasks)
        #expect(store.tasks.first?.status == .cancelled)
        #expect(defaults.object(forKey: "tasks") == nil)
    }

    @Test func streamingMatchesOneShotAcrossEveryCharacterBoundary() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let samples = [
            "普通输出 🐈\n Authorization: Bearer abc123456789.done\n下一行",
            "x Api-Key = 'secret-part' then password=abc and sk-abcdefghijklmnop!",
            "ssh-ed25519 AAAAabcdef1234== from host\nssh-rsa AAAAbbbb",
            "before -----BEGIN OPENSSH PRIVATE KEY-----\nprivate-body\n-----END OPENSSH PRIVATE KEY----- after",
            "to token without delimiter  short Bearer abc"
        ]
        for text in samples {
            let record = store.startTask(kind: .modelCouncil, title: "stream", objective: "redact")
            for ch in text { store.appendLog(id: record.id, chunk: String(ch)) }
            #expect(store.task(id: record.id)?.logTail == IOSAdvancedTaskStore.redactedLog(text))
        }
        let unfinished = store.startTask(kind: .modelCouncil, title: "unfinished PEM", objective: "log")
        let partialMarker = "output -----BEGIN OPENSSH PRIVATE"
        store.appendLog(id: unfinished.id, chunk: partialMarker)
        let terminal = store.updateTask(id: unfinished.id, status: .interrupted)
        #expect(terminal?.logTail == IOSAdvancedTaskStore.redactedLog(partialMarker))

        let record = store.startTask(kind: .modelCouncil, title: "cap", objective: "log")
        let long = String(repeating: "a", count: 4_010)
        store.appendLog(id: record.id, chunk: long)
        #expect(store.task(id: record.id)?.logTail == IOSAdvancedTaskStore.redactedLog(long))
    }
}
