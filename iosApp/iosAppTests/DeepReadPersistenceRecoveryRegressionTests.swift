import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class DeepReadPersistenceRecoveryRegressionTests: XCTestCase {
    func testCorruptedHistoryRejectsNewTaskAndPreservesOriginalBytes() throws {
        let root = try temporaryDirectory()
        let historyDirectory = root.appendingPathComponent("deep_read", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let historyFile = historyDirectory.appendingPathComponent("tasks.json")
        let original = Data(#"[{"id":"recoverable-reading","status":"succeeded","resultMarkdown":"old article""#.utf8)
        try original.write(to: historyFile)
        let store = IOSDeepReadStore(baseDirectory: root)
        XCTAssertNotNil(store.loadError, "历史入口必须能显示加载失败，不能展示成首次空库")

        XCTAssertThrowsError(try store.createTask(title: "New reading", sources: [source])) { error in
            XCTAssertFalse(error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "新建入口必须给出可见错误，不能把加载失败当作空库")
        }

        XCTAssertEqual(try Data(contentsOf: historyFile), original, "加载失败后不得覆盖可恢复的原文件")
    }

    func testFailedSectionRetryRestoresWorkspaceWarningAndAllowsWorkspaceOnlyRetry() async throws {
        let root = try temporaryDirectory()
        let suite = "DeepReadPersistenceRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let store = IOSDeepReadStore(baseDirectory: root)
        let task = try store.createTask(title: "Existing article", sources: [source])
        let originalMarkdown = "# Existing article\n\nSaved reading content."
        let originalJSON = #"{"summary":"prior"}"#
        let originalWarning = "Workspace export unavailable"
        XCTAssertTrue(store.complete(id: task.id, markdown: originalMarkdown,
                                     structuredJSON: originalJSON, missingSections: ["深度分析"]))
        XCTAssertTrue(store.markWorkspaceSyncFailed(id: task.id, message: originalWarning))
        let original = try XCTUnwrap(store.task(id: task.id))
        let prior = IOSDeepReadPriorCompletion(
            markdown: original.resultMarkdown, structuredJSON: original.structuredJSON,
            missingSections: original.missingSections ?? [],
            workspaceSyncFailed: original.workspaceSyncFailed
        )
        XCTAssertTrue(store.prepareRetry(id: task.id, preservingResult: true))
        var generatedWorkspaceSaves = 0
        let didComplete = await IOSDeepReadLauncher.runExistingTask(
            taskId: task.id, sharedSettings: settings, store: store,
            workspaceArtifactSaver: { _, _, _, _, _ in generatedWorkspaceSaves += 1 },
            targetStages: ["深度分析"], priorCompletion: prior
        )

        XCTAssertFalse(didComplete, "未配置模型时，补齐运行应失败并恢复原文章")
        XCTAssertEqual(generatedWorkspaceSaves, 0)
        let restoredStore = IOSDeepReadStore(baseDirectory: root)
        let restored = try XCTUnwrap(restoredStore.task(id: task.id))
        XCTAssertEqual(restored.status, .succeeded)
        XCTAssertEqual(restored.resultMarkdown, originalMarkdown)
        XCTAssertEqual(restored.structuredJSON, originalJSON)
        XCTAssertEqual(restored.missingSections, ["深度分析"])
        XCTAssertEqual(restored.workspaceSyncFailed, originalWarning,
                       "恢复的是同一篇原文章，它尚未保存 Workspace 的状态也必须恢复")
        let workspace = IOSWorkspaceStore(baseDirectory: root)
        var statuses: [(String, Bool)] = []

        IOSDeepReadLauncher.retryWorkspaceSync(
            taskId: task.id, store: restoredStore, workspaceStore: workspace,
            onStatus: { statuses.append(($0, $1)) }
        )

        XCTAssertEqual(workspace.artifacts.count, 1, "仅重试保存必须实际创建原文章的 Workspace artifact")
        let artifact = try XCTUnwrap(workspace.artifacts.first)
        XCTAssertEqual(artifact.sourceId, task.id)
        XCTAssertEqual(try workspace.artifactContent(id: artifact.id), originalMarkdown)
        XCTAssertNil(restoredStore.task(id: task.id)?.workspaceSyncFailed)
        XCTAssertEqual(statuses.last?.1, false)
    }

    private var source: IOSDeepReadSource {
        IOSDeepReadSource(kind: .manualText, title: "Source", content: "Existing source text for this reading.")
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepReadPersistenceRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
