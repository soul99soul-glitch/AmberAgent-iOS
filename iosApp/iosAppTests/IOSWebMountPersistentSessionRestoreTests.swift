import XCTest
@testable import iosApp

@MainActor
final class IOSWebMountPersistentSessionRestoreTests: IOSWebMountToolTestCase {
    func testRestartRetainsEveryPersistentLocalSessionAndItsCurrentSelection() throws {
        let defaults = isolatedDefaults()
        var nextSession = 0
        let store = IOSWebMountSessionStore(
            initialRuntime: MockWebMountRuntime(sessionId: "initial-ephemeral"),
            runtimeFactory: {
                nextSession += 1
                return MockWebMountRuntime(sessionId: "persistent-local-\(nextSession)")
            },
            restoredRuntimeFactory: { MockWebMountRuntime(sessionId: $0) },
            userDefaults: defaults
        )
        let sites = IOSWebMountSite.seeds()
        let firstSite = try XCTUnwrap(sites.first { $0.id == "github" })
        let secondSite = try XCTUnwrap(sites.first { $0.id == "hackernews" })
        let first = try store.newSession(site: firstSite, persistent: true)
        let second = try store.newSession(site: secondSite, persistent: true)
        for session in [first, second] {
            _ = try store.acquireAgentControl(
                sessionId: session.id,
                runId: "before-restart",
                conversationId: "persistent-conversation"
            )
        }
        store.touch(sessionId: second.id)
        XCTAssertEqual(store.currentSessionId, second.id)

        let restored = IOSWebMountSessionStore(
            runtimeFactory: { MockWebMountRuntime() },
            restoredRuntimeFactory: { MockWebMountRuntime(sessionId: $0) },
            userDefaults: defaults
        )
        let expectedIDs = Set([first.id, second.id])
        XCTAssertEqual(Set(restored.records.map(\.id)), expectedIDs)
        XCTAssertEqual(restored.currentSessionId, second.id)
        for (session, site) in [(first, firstSite), (second, secondSite)] {
            let record = try XCTUnwrap(restored.record(sessionId: session.id))
            XCTAssertEqual(record.siteId, site.id)
            XCTAssertEqual(record.ownerConversationId, "persistent-conversation")
            XCTAssertNil(record.ownerRunId)
            XCTAssertEqual(record.controlOwner, .none)
            XCTAssertTrue(record.persistentOptIn)
            XCTAssertTrue(record.needsReopen)
            let runtime = try XCTUnwrap(
                restored.runtimeIfPresent(sessionId: session.id) as? MockWebMountRuntime
            )
            XCTAssertEqual(runtime.snapshot.status, .idle)
            XCTAssertNil(runtime.snapshot.currentURL)
            XCTAssertTrue(runtime.openedURLs.isEmpty)
        }

        // An ordinary activity write must not permanently erase another
        // opted-in session from the next launch's persisted metadata.
        restored.touch(sessionId: second.id)
        let restoredAgain = IOSWebMountSessionStore(
            runtimeFactory: { MockWebMountRuntime() },
            restoredRuntimeFactory: { MockWebMountRuntime(sessionId: $0) },
            userDefaults: defaults
        )
        XCTAssertEqual(Set(restoredAgain.records.map(\.id)), expectedIDs)
        XCTAssertEqual(restoredAgain.currentSessionId, second.id)
    }
}
