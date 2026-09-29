import XCTest
import Shared
@testable import iosApp

/// P7-2: `recoverTerminalActivitiesIfNeeded()` used to open a brand-new Room
/// database via `IosDatabaseFactory.shared.createDatabase()` instead of
/// reusing the `agentRuntimeDao` already built once at `WatchTaskCoordinator`
/// init (backing `durableRunStore`/`toolLedger`). That was pure waste (a
/// second SQLite open + migration chain registration on the first Watch
/// refresh after attach) and, because it silently pointed at the *default*
/// database path, could in principle diverge from whatever DAO the
/// coordinator was actually constructed with.
///
/// This locks in the fix behaviorally: seed an outcome-unknown run into an
/// isolated, non-default database, construct the coordinator with that exact
/// DAO, and confirm the cold recovery sweep (which only runs once per
/// coordinator, driven by `recoverTerminalActivitiesIfNeeded`) actually finds
/// it. If the code regressed to opening its own default-path database again,
/// it would not see this row and the recovery decision would never publish.
@MainActor
final class WatchTaskCoordinatorAgentRuntimeDaoReuseTests: XCTestCase {
    private func makeIsolatedDao(_ name: String = #function) -> AgentRuntimeDao {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).db")
            .path
        return IosDatabaseFactory.shared.createDatabase(atFilePath: path).agentRuntimeDao()
    }

    func testRecoverySweepUsesTheInjectedDaoNotADefaultDatabase() async throws {
        let dao = makeIsolatedDao()
        let runId = "watch-dao-reuse-\(UUID().uuidString)"
        let conversationId = "conversation-\(UUID().uuidString)"
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let run = AgentRunEntity(
            runId: runId,
            parentRunId: nil,
            agentDescriptorId: "chat",
            agentVersion: "1",
            conversationId: conversationId,
            messageNodeId: nil,
            producesMessageId: nil,
            assistantId: nil,
            status: AgentRunStatus.outcomeUnknown.wireName,
            inputDigest: "watch-dao-reuse",
            inputSnapshotRef: nil,
            inputSchemaVersion: 1,
            startedAt: now,
            finishedAt: nil,
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
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        let suite = "WatchTaskCoordinatorAgentRuntimeDaoReuseTests.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let coordinator = WatchTaskCoordinator(
            bridge: WatchConnectivityBridge(),
            companionService: IOSWatchCompanionService(
                baseDirectory: root, defaults: UserDefaults(suiteName: suite)!
            ),
            deepLinkInbox: IOSDeepLinkInbox(),
            agentRuntimeDao: dao
        )
        let viewModel = ChatViewModel(settingsStore: SettingsStore(), autoGenerateResponses: false)
        coordinator.attach(chatViewModel: viewModel)
        await coordinator.refreshWatchSnapshot()

        let snapshot = coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.runId, runId, "cold recovery must find the run seeded into the injected DAO's database")
        XCTAssertTrue(
            WatchTaskSnapshotBuilder.isPhoneOnlyDecision(snapshot.decision),
            "an outcome-unknown row must publish the phone-only reconciliation decision"
        )
    }
}
