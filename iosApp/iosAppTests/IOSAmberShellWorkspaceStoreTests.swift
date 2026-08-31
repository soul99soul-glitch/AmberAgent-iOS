import XCTest
@testable import iosApp

@MainActor
final class IOSAmberShellWorkspaceStoreTests: XCTestCase {
    func testAmberShellFileSequence() async throws {
        let (store, baseDirectory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        try store.amberShellCreateDirectory(path: "/workspace/docs")
        _ = await store.executeTool(
            toolName: "workspace_file_write",
            input: #"{"path":"/workspace/docs/source.txt","content":"hello","overwrite":true}"#
        )
        try await store.amberShellCopy(
            from: "/workspace/docs/source.txt",
            to: "/workspace/docs/copied.txt"
        )
        try await store.amberShellMove(
            from: "/workspace/docs/copied.txt",
            to: "/workspace/docs/moved.txt"
        )

        XCTAssertEqual(
            try store.amberShellReadText(path: "/workspace/docs/moved.txt", maxBytes: 32),
            "hello"
        )
        XCTAssertEqual(try store.amberShellList(path: "/workspace/docs"), ["moved.txt", "source.txt"])
        try store.amberShellRemove(path: "/workspace/docs/moved.txt")
        XCTAssertThrowsError(try store.amberShellReadText(path: "/workspace/docs/moved.txt", maxBytes: 32))
    }

    func testAmberShellTouchPreservesContentAndReloadsMetadata() async throws {
        let (store, baseDirectory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        _ = await store.executeTool(
            toolName: "workspace_file_write",
            input: #"{"path":"/workspace/notes.txt","content":"keep me","overwrite":true}"#
        )
        try await store.amberShellTouch(path: "/workspace/notes.txt")

        XCTAssertEqual(try store.amberShellReadText(path: "/workspace/notes.txt", maxBytes: 32), "keep me")
        let reloaded = IOSWorkspaceStore(baseDirectory: baseDirectory)
        XCTAssertEqual(reloaded.files.first?.workspacePath, "notes.txt")
        XCTAssertEqual(reloaded.files.first?.sizeBytes, Int64("keep me".utf8.count))
    }

    func testAmberShellRejectsTraversalAndSymlinkPaths() async throws {
        let (store, baseDirectory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        _ = await store.executeTool(
            toolName: "workspace_file_write",
            input: #"{"path":"/workspace/seed.txt","content":"seed","overwrite":true}"#
        )
        let workspaceDirectory = try XCTUnwrap(store.files.first.map { store.fileURL(for: $0).deletingLastPathComponent() })
        let outsideDirectory = baseDirectory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let link = workspaceDirectory.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory)

        XCTAssertThrowsError(try store.amberShellList(path: "/workspace/../"))
        XCTAssertThrowsError(try store.amberShellReadText(path: baseDirectory.path, maxBytes: 32))
        XCTAssertThrowsError(try store.amberShellList(path: "/workspace/link"))
        do {
            try await store.amberShellTouch(path: "/workspace/link/escape.txt")
            XCTFail("Expected symlink parent rejection")
        } catch {
            // expected
        }
    }

    private func makeStore() throws -> (IOSWorkspaceStore, URL) {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSAmberShellWorkspaceStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return (IOSWorkspaceStore(baseDirectory: baseDirectory), baseDirectory)
    }
}
