import Foundation
import XCTest
@preconcurrency import GatewayCore
@testable import AmberMac

@MainActor
final class DesktopAgentSoulTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("amber-soul-tests-" + UUID().uuidString, isDirectory: true)
    }

    final class FakeCloudSoulSync: DesktopCloudSoulSync, @unchecked Sendable {
        var remote = AmberControl.SoulState()
        var fetchCalls = 0
        var putRequests: [AmberControl.SoulPutRequest] = []
        var simulatedError: (any Error)?

        func fetchSoul() async throws -> AmberControl.SoulState {
            fetchCalls += 1
            if let simulatedError { throw simulatedError }
            return remote
        }

        func putSoul(_ request: AmberControl.SoulPutRequest) async throws -> AmberControl.SoulState {
            putRequests.append(request)
            if let simulatedError { throw simulatedError }
            let reset = request.isDefault == true
            let nextRev = remote.revision + 1
            let snap = AmberControl.SoulSnapshot(
                id: "snap_\(max(0, remote.updatedAtMs))",
                displayName: remote.displayName,
                tagline: remote.tagline,
                soulMarkdown: remote.soulMarkdown,
                updatedAtMs: remote.updatedAtMs,
                source: remote.source
            )
            let updated = AmberControl.SoulState(
                revision: nextRev,
                updatedAtMs: max(remote.updatedAtMs + 1, request.updatedAtMs ?? 1_000),
                displayName: reset ? "Amber" : (request.displayName ?? remote.displayName),
                tagline: reset ? "" : (request.tagline ?? remote.tagline),
                soulMarkdown: reset ? "" : (request.soulMarkdown ?? remote.soulMarkdown),
                isDefault: reset ? true : (request.isDefault ?? false),
                source: request.source ?? "remote_put",
                history: Array(([snap] + remote.history).prefix(8))
            )
            remote = updated
            return updated
        }
    }

    func testCrudHistoryCapRollbackResetAndLegacyMigration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let knowledgeDir = root.appendingPathComponent("Knowledge", isDirectory: true)
        try FileManager.default.createDirectory(at: knowledgeDir, withIntermediateDirectories: true)
        try Data("说话简练果断，像宋太祖赵匡胤。".utf8).write(to: knowledgeDir.appendingPathComponent("SOUL.md"))

        let revFile = root.appendingPathComponent("gateway/soul-revision.txt")
        let knowledge = DesktopKnowledgeStore(directory: knowledgeDir)
        var nowMs: Int64 = 1_700_000_000_000
        let soulStore = DesktopAgentSoulStore(
            knowledge: knowledge,
            gatewayRevisionFile: revFile,
            clockMs: { nowMs }
        )

        // Legacy SOUL.md migrates automatically on first init
        XCTAssertFalse(soulStore.isDefault)
        XCTAssertEqual(soulStore.revision, 1)
        XCTAssertEqual(soulStore.source, "legacy_migration")
        XCTAssertEqual(soulStore.soulMarkdown, "说话简练果断，像宋太祖赵匡胤。")
        XCTAssertEqual(try String(contentsOf: revFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "1")

        // System prompt decouples immutable host discipline from mutable persona and never uses banned wording
        let prompt = try knowledge.stableContext()
        XCTAssertTrue(prompt.contains("<host-core-discipline>"))
        XCTAssertTrue(prompt.contains("<agent-soul is_default=\"false\" revision=\"1\">"))
        XCTAssertTrue(prompt.contains("agent_soul_update"))
        XCTAssertFalse(prompt.contains("化身"))

        // 10 updates cap history at 8 snapshots with monotonic revisions
        for index in 1...10 {
            nowMs += 1_000
            _ = try soulStore.update(
                displayName: "角色\(index)",
                tagline: "签名\(index)",
                soulMarkdown: "口吻\(index)",
                source: "macos_ui"
            )
        }
        XCTAssertEqual(soulStore.revision, 11)
        XCTAssertEqual(soulStore.displayName, "角色10")
        XCTAssertEqual(soulStore.history.count, 8)
        XCTAssertEqual(soulStore.history.first?.displayName, "角色9")

        // Rollback to an earlier snapshot bumps revision monotonically
        let targetSnap = try XCTUnwrap(soulStore.history.first { $0.displayName == "角色6" })
        nowMs += 1_000
        _ = try soulStore.restore(snapshotID: targetSnap.id)
        XCTAssertEqual(soulStore.revision, 12)
        XCTAssertEqual(soulStore.displayName, "角色6")
        XCTAssertEqual(soulStore.tagline, "签名6")

        // Reset to default preserves previous custom persona in history and bumps revision
        nowMs += 1_000
        _ = try soulStore.resetToDefault()
        XCTAssertTrue(soulStore.isDefault)
        XCTAssertEqual(soulStore.displayName, "Amber")
        XCTAssertEqual(soulStore.soulMarkdown, "")
        XCTAssertEqual(soulStore.revision, 13)
        XCTAssertEqual(soulStore.history.first?.displayName, "角色6")

        // Reload from disk preserves full state
        let reopenedKnowledge = DesktopKnowledgeStore(directory: knowledgeDir)
        let reopenedSoul = DesktopAgentSoulStore(knowledge: reopenedKnowledge)
        XCTAssertEqual(reopenedSoul.state, soulStore.state)
    }

    func testChatSelfUpdateToolsAndCoreRegistryExposure() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let knowledge = DesktopKnowledgeStore(directory: root)
        let soulStore = DesktopAgentSoulStore(knowledge: knowledge)

        // Core registry declarations & skill scope permissions
        let decls = DesktopToolRegistry.agentDeclarations(toolsEnabled: true, subagentsEnabled: false)
        XCTAssertTrue(decls.contains { $0.name == "agent_soul_get" && !$0.needsApproval })
        XCTAssertTrue(decls.contains { $0.name == "agent_soul_update" && !$0.needsApproval })
        XCTAssertEqual(DesktopToolRegistry.effect(for: "agent_soul_get", arguments: "{}"), .pure)
        XCTAssertEqual(DesktopToolRegistry.effect(for: "agent_soul_update", arguments: "{}"), .idempotent)
        XCTAssertFalse(DesktopToolRegistry.isHighRisk("agent_soul_update"))

        var scope = DesktopSkillToolScope()
        scope.apply(["workspace_file_read"])
        XCTAssertTrue(scope.permits("agent_soul_get"))
        XCTAssertTrue(scope.permits("agent_soul_update"))

        // Tool update via snake_case
        let updateJSON = try knowledge.executeTool(
            name: "agent_soul_update",
            argumentsJSON: #"{"display_name":"赵匡胤","tagline":"杯酒释兵权","soul_markdown":"朕与卿平心而论，直抒胸臆。"}"#
        )
        let parsedUpdate = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(updateJSON.utf8)) as? [String: Any])
        XCTAssertEqual(parsedUpdate["ok"] as? Bool, true)
        XCTAssertEqual(parsedUpdate["displayName"] as? String, "赵匡胤")
        XCTAssertEqual(soulStore.displayName, "赵匡胤")
        XCTAssertEqual(soulStore.revision, 1)

        // Tool get
        let getJSON = try knowledge.executeTool(name: "agent_soul_get", argumentsJSON: "{}")
        let parsedGet = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(getJSON.utf8)) as? [String: Any])
        XCTAssertEqual(parsedGet["displayName"] as? String, "赵匡胤")
        XCTAssertEqual(parsedGet["tagline"] as? String, "杯酒释兵权")

        // Tool reset via camelCase alias
        _ = try knowledge.executeTool(name: "agent_soul_update", argumentsJSON: #"{"resetToDefault":true}"#)
        XCTAssertTrue(soulStore.isDefault)
        XCTAssertEqual(soulStore.revision, 2)
    }

    func testTwoWayCloudSyncIsLoopFreeAndOfflineResilient() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "test.soulSync.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let knowledge = DesktopKnowledgeStore(directory: root)
        let soulStore = DesktopAgentSoulStore(knowledge: knowledge)
        let fakeSync = FakeCloudSoulSync()
        let coordinator = DesktopCloudSoulCoordinator(soulStore: soulStore, defaults: defaults)
        coordinator.attach(gatewayId: "cloud-gw-1", sync: fakeSync)

        // 1. Remote updates to revision 4 (e.g., from iOS or Feishu): Mac pulls GET once and sends ZERO PUTs!
        fakeSync.remote = AmberControl.SoulState(
            revision: 4,
            updatedAtMs: 2_000,
            displayName: "诸葛孔明",
            tagline: "鞠躬尽瘁",
            soulMarkdown: "凡事预则立，不预则废。",
            isDefault: false,
            source: "ios_ui",
            history: []
        )
        await coordinator.reconcile(remoteRevisionHint: 4)
        XCTAssertEqual(soulStore.displayName, "诸葛孔明")
        XCTAssertEqual(soulStore.revision, 4)
        XCTAssertEqual(fakeSync.fetchCalls, 1)
        XCTAssertEqual(fakeSync.putRequests.count, 0, "Adopting remote persona must NEVER bounce back a PUT /v2/soul")

        // 2. Subsequent /v1/status poll with unchanged soulRevision=4 makes ZERO GET and ZERO PUT calls!
        await coordinator.reconcile(remoteRevisionHint: 4)
        XCTAssertEqual(fakeSync.fetchCalls, 1)
        XCTAssertEqual(fakeSync.putRequests.count, 0)

        // 3. Local chat self-update on Mac pushes exactly 1 PUT /v2/soul and adopts server revision 5
        _ = try knowledge.executeTool(
            name: "agent_soul_update",
            argumentsJSON: #"{"display_name":"苏东坡","tagline":"一蓑烟雨任平生","soul_markdown":"豁达风趣，兼通诗词与工程。"}"#
        )
        await coordinator.reconcile(remoteRevisionHint: fakeSync.remote.revision)
        XCTAssertEqual(fakeSync.putRequests.count, 1)
        XCTAssertEqual(fakeSync.putRequests.first?.displayName, "苏东坡")
        XCTAssertEqual(soulStore.revision, 5)
        XCTAssertFalse(coordinator.hasPendingLocalPush)

        // 4. Next poll with matching revision 5 makes ZERO extra GET or PUT calls
        let fetchesAfterPush = fakeSync.fetchCalls
        await coordinator.reconcile(remoteRevisionHint: 5)
        XCTAssertEqual(fakeSync.fetchCalls, fetchesAfterPush)
        XCTAssertEqual(fakeSync.putRequests.count, 1)

        // 5. Offline edit retains hasPendingLocalPush and flushes once when reachable again
        fakeSync.simulatedError = DesktopCloudError.unreachable
        _ = try soulStore.update(displayName: "辛弃疾", tagline: "醉里挑灯看剑", soulMarkdown: "豪放直率")
        await coordinator.reconcile(remoteRevisionHint: 5)
        XCTAssertTrue(coordinator.hasPendingLocalPush)

        fakeSync.simulatedError = nil
        await coordinator.reconcile(remoteRevisionHint: 5)
        XCTAssertFalse(coordinator.hasPendingLocalPush)
        XCTAssertEqual(fakeSync.remote.displayName, "辛弃疾")
        XCTAssertEqual(soulStore.revision, fakeSync.remote.revision)
    }

    func testGatewayControlGetAndPutSoulForwarding() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = GatewayPaths(stateDir: root.appendingPathComponent("gw", isDirectory: true))
        let tasks = DesktopAgentTasks(directory: root.appendingPathComponent("tasks", isDirectory: true))
        let reporter = DesktopGatewayReporter { false }
        let control = DesktopGatewayControl(paths: paths, tasks: tasks, reporter: reporter, scheduler: nil)
        let soulStore = DesktopAgentSoulStore(directory: root.appendingPathComponent("soul", isDirectory: true))
        control.soulStore = soulStore

        let initialReply = await control.handle(AmberControl.Request(action: .getSoul))
        XCTAssertEqual(initialReply.status, 200)
        XCTAssertEqual(initialReply.soul?.isDefault, true)

        let putReply = await control.handle(
            AmberControl.Request(
                action: .putSoul,
                deviceName: "iPhone",
                soulPut: AmberControl.SoulPutRequest(
                    displayName: "李太白",
                    tagline: "天生我材必有用",
                    soulMarkdown: "浪漫飘逸",
                    source: "ios_paired_gateway"
                )
            )
        )
        XCTAssertEqual(putReply.status, 200)
        XCTAssertEqual(putReply.soul?.displayName, "李太白")
        XCTAssertEqual(putReply.soul?.revision, 1)
        XCTAssertEqual(soulStore.displayName, "李太白")
    }
}
