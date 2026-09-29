import XCTest
@testable import iosApp

/// P7-2：`record()` 的落盘/读盘挪到后台串行队列后，锁住三条契约——
/// 1) 内存态（lastLine/recentEntries）仍然同步、即时可见（不依赖磁盘往返）；
/// 2) 落盘异步完成后，磁盘内容与内存态一致且顺序保持不变（FIFO 串行队列）；
/// 3) bootstrap() 补齐上一进程历史时，顺序是「历史在前、本进程新记录在后」，
///    不会因为异步竞态丢失或错序。
@MainActor
final class IOSBackgroundLifecycleLogTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await IOSBackgroundLifecycleLog.flushPendingPersistenceForTesting()
        IOSBackgroundLifecycleLog.resetForTesting()
    }

    override func tearDown() async throws {
        await IOSBackgroundLifecycleLog.flushPendingPersistenceForTesting()
        IOSBackgroundLifecycleLog.resetForTesting()
        try await super.tearDown()
    }

    func testRecordUpdatesInMemoryStateSynchronouslyWithoutWaitingForDisk() {
        IOSBackgroundLifecycleLog.record("unitTestTransitionA")
        // No flush/await here: lastLine and recentEntries must already reflect
        // the call before any background persistence has had a chance to run.
        XCTAssertEqual(IOSBackgroundLifecycleLog.lastLine?.contains("unitTestTransitionA"), true)
        XCTAssertEqual(IOSBackgroundLifecycleLog.recentEntries.last?.line.contains("unitTestTransitionA"), true)
    }

    func testPersistedRingMatchesInMemoryRingAndPreservesOrderAfterFlush() async {
        IOSBackgroundLifecycleLog.record("first")
        IOSBackgroundLifecycleLog.record("second")
        IOSBackgroundLifecycleLog.record("third")
        await IOSBackgroundLifecycleLog.flushPendingPersistenceForTesting()

        let persistedLines = IOSBackgroundLifecycleLog.recentEntries.map(\.line)
        XCTAssertEqual(persistedLines.count, 3)
        // Order must match call order: first, second, third.
        XCTAssertTrue(persistedLines[0].contains("first"))
        XCTAssertTrue(persistedLines[1].contains("second"))
        XCTAssertTrue(persistedLines[2].contains("third"))

        // Independently reload straight from UserDefaults (bypassing the
        // in-memory ring) to prove the background write actually landed on
        // disk in the same order, not just in memory.
        IOSBackgroundLifecycleLog.resetForTestingKeepingDisk()
        await IOSBackgroundLifecycleLog.bootstrapForTesting()
        let reloadedLines = IOSBackgroundLifecycleLog.recentEntries.map(\.line)
        XCTAssertEqual(reloadedLines, persistedLines)
    }

    func testBootstrapMergesPersistedHistoryBeforeEntriesRecordedDuringLoad() async {
        // Seed a persisted "previous process" entry, then simulate a fresh
        // process: reset in-memory state but keep what's on disk.
        IOSBackgroundLifecycleLog.record("previousProcessEntry")
        await IOSBackgroundLifecycleLog.flushPendingPersistenceForTesting()
        IOSBackgroundLifecycleLog.resetForTestingKeepingDisk()

        // record() calls that happen before bootstrap's disk read completes
        // must not be lost, and must still land after the restored history.
        // Calling record() inside the continuation's operation closure (right
        // after kicking off bootstrap, before awaiting it) reproduces that
        // interleaving deterministically.
        await withCheckedContinuation { continuation in
            IOSBackgroundLifecycleLog.bootstrap { continuation.resume() }
            IOSBackgroundLifecycleLog.record("newProcessEntry")
        }
        await IOSBackgroundLifecycleLog.flushPendingPersistenceForTesting()

        let lines = IOSBackgroundLifecycleLog.recentEntries.map(\.line)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("previousProcessEntry"))
        XCTAssertTrue(lines[1].contains("newProcessEntry"))
    }
}
