import XCTest
@testable import iosApp

@MainActor
final class IOSWorkspaceUndoAndDiffTests: XCTestCase {
    private func makeTempStore() throws -> (store: IOSWorkspaceStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSWorkspaceUndoAndDiffTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = IOSWorkspaceStore(baseDirectory: root)
        return (store, root)
    }

    func testApprovalDiffPreviewForWriteEditAndMove() async throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let newWriteDiff = store.approvalDiffPreview(
            toolName: "workspace_file_write",
            args: ["path": "/workspace/notes/plan.md", "content": "line one\nline two\n"]
        )
        XCTAssertNotNil(newWriteDiff)
        XCTAssertTrue(newWriteDiff?.contains("+++ /workspace/notes/plan.md") == true)
        XCTAssertTrue(newWriteDiff?.contains("+line one") == true)

        _ = await store.executeTool(
            toolName: "workspace_file_write",
            input: #"{"path":"/workspace/notes/plan.md","content":"alpha\nbeta\ngamma\n"}"#
        )

        let editDiff = store.approvalDiffPreview(
            toolName: "workspace_file_edit",
            args: ["path": "notes/plan.md", "find": "beta", "replace": "BETA-2"]
        )
        XCTAssertNotNil(editDiff)
        XCTAssertTrue(editDiff?.contains("-beta") == true)
        XCTAssertTrue(editDiff?.contains("+BETA-2") == true)

        let moveDiff = store.approvalDiffPreview(
            toolName: "workspace_file_move",
            args: ["path": "notes/plan.md", "destination_path": "notes/plan-v2.md"]
        )
        XCTAssertEqual(moveDiff, "--- /workspace/notes/plan.md\n+++ /workspace/notes/plan-v2.md")

        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(),
            documentStore: DocumentAccessStore(),
            workspaceStore: store
        )
        let preview = executor.workspaceApprovalPreview(
            toolName: "workspace_file_edit",
            input: #"{"path":"notes/plan.md","find":"beta","replace":"BETA-2"}"#
        )
        let request = preview.map {
            WorkspaceToolApprovalRequest(
                id: "req-1",
                toolName: $0.toolName,
                action: $0.action,
                target: $0.target,
                isWrite: $0.isWrite,
                reason: "需要修改笔记",
                diffPreview: $0.diffPreview
            )
        }
        XCTAssertTrue(request?.diffPreview?.contains("+BETA-2") == true)
    }

    func testUndoRestoresEditedAndCreatedFilesAndRecordsAudit() async throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let createResult = await store.executeTool(
            toolName: "workspace_file_write",
            input: #"{"path":"drafts/hello.txt","content":"v1 content"}"#
        )
        XCTAssertTrue(createResult.contains(#""ok":true"#))

        let editResult = await store.executeTool(
            toolName: "workspace_file_edit",
            input: #"{"path":"drafts/hello.txt","find":"v1","replace":"v2"}"#
        )
        XCTAssertTrue(editResult.contains(#""ok":true"#))
        XCTAssertEqual(store.undoSnapshots(forPath: "drafts/hello.txt").count, 2)

        // Undo edit -> restores "v1 content"
        let undoEdit = store.undoLastChange(forPath: "drafts/hello.txt")
        XCTAssertEqual(undoEdit["ok"] as? Bool, true)
        let recordAfterEditUndo = try XCTUnwrap(store.fileRecord(idOrPath: "drafts/hello.txt"))
        let contentAfterEditUndo = try String(contentsOf: store.fileURL(for: recordAfterEditUndo), encoding: .utf8)
        XCTAssertEqual(contentAfterEditUndo, "v1 content")

        // Undo initial create -> removes file & record
        let undoCreate = store.undoLastChange(forPath: "drafts/hello.txt")
        XCTAssertEqual(undoCreate["ok"] as? Bool, true)
        XCTAssertNil(store.fileRecord(idOrPath: "drafts/hello.txt"))

        let auditActions = store.undoAuditEntries().map(\.action)
        XCTAssertTrue(auditActions.contains("snapshot_saved"))
        XCTAssertTrue(auditActions.filter { $0 == "undone" }.count == 2)
    }

    func testUndoRefusesOnSHA256Conflict() async throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = await store.executeTool(
            toolName: "workspace_file_write",
            input: #"{"path":"conflict.txt","content":"agent-v1"}"#
        )
        let record = try XCTUnwrap(store.fileRecord(idOrPath: "conflict.txt"))
        // Simulate external modification bypassing Workspace tools.
        try "external-edit".write(to: store.fileURL(for: record), atomically: true, encoding: .utf8)

        let undo = store.undoLastChange(forPath: "conflict.txt")
        XCTAssertEqual(undo["ok"] as? Bool, false)
        XCTAssertEqual(undo["conflict"] as? Bool, true)
        XCTAssertEqual(try String(contentsOf: store.fileURL(for: record), encoding: .utf8), "external-edit")
        XCTAssertTrue(store.undoAuditEntries().contains(where: { $0.action == "undo_conflict" }))
    }

    func testUndoEnforcesPerPath3Cap5MBLimitAnd24hExpiry() async throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // 4 consecutive writes -> only 3 newest snapshots retained
        for step in 1...4 {
            _ = await store.executeTool(
                toolName: "workspace_file_write",
                input: #"{"path":"rolling.txt","content":"step-\#(step)","overwrite":true}"#
            )
        }
        XCTAssertEqual(store.undoSnapshots(forPath: "rolling.txt").count, 3)

        // File > 5 MB skips snapshot cleanly
        let largeText = String(repeating: "A", count: (5 * 1024 * 1024) + 64)
        let largePayload = try JSONSerialization.data(
            withJSONObject: ["path": "big.txt", "content": largeText]
        )
        let largeInput = try XCTUnwrap(String(data: largePayload, encoding: .utf8))
        let bigWrite = await store.executeTool(toolName: "workspace_file_write", input: largeInput)
        XCTAssertTrue(bigWrite.contains(#""ok":true"#))
        XCTAssertEqual(store.undoSnapshots(forPath: "big.txt").count, 0)
        XCTAssertTrue(store.undoAuditEntries().contains(where: {
            $0.workspacePath == "big.txt" && $0.action == "snapshot_skipped"
        }))

        // 24h auto cleanup removes aged snapshots
        store.pruneExpiredUndoSnapshots(now: Date().addingTimeInterval(25 * 3600))
        XCTAssertEqual(store.undoSnapshots().count, 0)
        XCTAssertTrue(store.undoAuditEntries().contains(where: { $0.action == "snapshot_expired" }))
    }
}
