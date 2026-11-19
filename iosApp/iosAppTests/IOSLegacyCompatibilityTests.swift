import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSLegacyCompatibilityTests: XCTestCase {
    func testWorkspaceStoreDecodesLegacyDeepReadArtifactAsNoteWithoutDroppingState() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSLegacyWorkspace-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = tempRoot.appendingPathComponent("AmberWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let legacyJSON = """
        {
          "files": [],
          "artifacts": [
            {
              "id": "art-deepread-1",
              "title": "旧深读报告",
              "type": "deepRead",
              "contentPath": "artifacts/art-deepread-1.md",
              "contentBytes": 128,
              "summary": "旧摘要",
              "createdAtMillis": 1700000000000,
              "updatedAtMillis": 1700000001000,
              "sourceKind": "deep_read",
              "sourceId": "dr-1"
            },
            {
              "id": "art-note-2",
              "title": "普通笔记",
              "type": "note",
              "contentPath": "artifacts/art-note-2.md",
              "contentBytes": 64,
              "summary": "笔记",
              "createdAtMillis": 1700000002000,
              "updatedAtMillis": 1700000003000,
              "sourceKind": "chat",
              "sourceId": null
            }
          ]
        }
        """
        try Data(legacyJSON.utf8).write(to: workspaceDir.appendingPathComponent("workspace.json"))

        let store = IOSWorkspaceStore(baseDirectory: tempRoot)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.artifacts.count, 2)
        XCTAssertEqual(store.artifacts.first?.id, "art-deepread-1")
        XCTAssertEqual(store.artifacts.first?.type, .note)
        XCTAssertEqual(store.artifacts.last?.type, .note)
    }

    func testAmberHubStoreDecodesLegacyNovelTemplateAsGeneralPreservingMemoryPolicy() throws {
        let suiteName = "IOSLegacyHub-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let hubsJSON = """
        [
          {
            "id": "hub-novel-1",
            "slug": "novel-space",
            "title": "旧小说空间",
            "thesis": "隔离测试",
            "template": "NOVEL",
            "memoryPolicy": "HUB_ISOLATED",
            "pinnedSupertags": ["#creative/novel"],
            "conversationIds": ["conv-1"],
            "taskIds": [],
            "memoryCountHint": 2,
            "documentCountHint": 1,
            "statusSummaryOverride": null,
            "createdAtMs": 1700000000000,
            "updatedAtMs": 1700000001000
          }
        ]
        """
        let collectionsJSON = """
        [
          {
            "id": "col-novel-1",
            "title": "小说创作",
            "primaryTag": "#creative/novel",
            "itemCount": 3,
            "conversationIds": ["conv-1"],
            "memoryCount": 1,
            "digest": "自动聚合",
            "template": "NOVEL",
            "promotionSuggested": true
          }
        ]
        """
        defaults.set(Data(hubsJSON.utf8), forKey: "app.amber.ios.hubs.v1")
        defaults.set(Data(collectionsJSON.utf8), forKey: "app.amber.ios.hubs.collections.v1")

        let store = AmberHubStore(userDefaults: defaults)
        XCTAssertEqual(store.hubs.count, 1)
        XCTAssertEqual(store.hubs.first?.template, .general)
        XCTAssertEqual(store.hubs.first?.memoryPolicy, .hubIsolated)
        XCTAssertEqual(store.smartCollections.count, 1)
        XCTAssertEqual(store.smartCollections.first?.template, .general)

        // An unrelated save and reload must preserve the legacy collection's promotion policy.
        store.createHub(title: "通用中心", makeActive: false)
        let reloaded = AmberHubStore(userDefaults: defaults)
        let promoted = try XCTUnwrap(reloaded.promoteSmartCollectionToHub("col-novel-1"))
        XCTAssertEqual(promoted.memoryPolicy, .hubIsolated)
    }

    func testAgentActivityPresentationDecodesLegacyDeepReadKindAsResearch() throws {
        let json = """
        {
          "kind": "deepRead",
          "phase": "running",
          "stage": "readingSources",
          "metric": { "none": {} }
        }
        """
        let presentation = try JSONDecoder().decode(AgentActivityPresentation.self, from: Data(json.utf8))
        XCTAssertEqual(presentation.kind, .research)
        XCTAssertEqual(presentation.phase, .running)
        XCTAssertEqual(presentation.stage, .readingSources)
    }

    func testIosSettingsJsonBridgeIgnoresLegacyTodayBoardField() throws {
        let baseSettings = IosSettingsDefaults.shared.defaultSeededSettings()
        let baseJSON = IosSettingsJsonBridge.shared.encode(settings: baseSettings)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(baseJSON.utf8)) as? [String: Any])
        var agentRuntime = (obj["agentRuntime"] as? [String: Any]) ?? [:]
        agentRuntime["todayBoard"] = ["enabled": true, "refreshHour": 8]
        obj["agentRuntime"] = agentRuntime
        let legacyData = try JSONSerialization.data(withJSONObject: obj)
        let legacyJSON = String(decoding: legacyData, as: UTF8.self)

        let decoded = try IosSettingsJsonBridge.shared.decode(json: legacyJSON)
        XCTAssertEqual(decoded.agentRuntime.enableShortTermMemory, baseSettings.agentRuntime.enableShortTermMemory)
        XCTAssertEqual(decoded.agentRuntime.enableLongTermMemory, baseSettings.agentRuntime.enableLongTermMemory)
    }
}
