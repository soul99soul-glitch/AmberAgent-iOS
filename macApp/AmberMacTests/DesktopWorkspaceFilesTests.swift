import XCTest
@testable import AmberMac

final class DesktopWorkspaceFilesTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("amber-files-test-" + UUID().uuidString) }

    func testWriteReopenAndOwnerIsolation() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), other = UUID()
        let files = DesktopWorkspaceFiles(directory: root)
        let written = try await files.write(conversationID: owner, path: "outputs/result.md", data: Data("result".utf8))
        XCTAssertEqual(written.id, "outputs/result.md")
        XCTAssertEqual(written.byteCount, 6)
        let reopened = DesktopWorkspaceFiles(directory: root)
        let data = try await reopened.read(conversationID: owner, path: written.id)
        XCTAssertEqual(String(data: data, encoding: .utf8), "result")
        let entries = try await reopened.list(conversationID: owner)
        XCTAssertEqual(entries.map(\.id), ["outputs/result.md"])
        let otherFiles = try await reopened.list(conversationID: other)
        XCTAssertTrue(otherFiles.isEmpty)
        do { _ = try await reopened.read(conversationID: other, path: written.id); XCTFail("Other owner must not read file") }
        catch {}
    }

    func testRejectsAbsoluteTraversalAndSymlinkPaths() async throws {
        let root = directory(), outside = directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let owner = UUID()
        let files = DesktopWorkspaceFiles(directory: root)
        for path in ["../outside.txt", "/tmp/outside.txt", "nested/../../outside.txt", "a//b", "a/./b", "a\\b"] {
            do { _ = try await files.write(conversationID: owner, path: path, data: Data()); XCTFail(path) } catch {}
        }
        _ = try await files.write(conversationID: owner, path: "safe.txt", data: Data())
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent(owner.uuidString).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do { _ = try await files.write(conversationID: owner, path: "link/escape.txt", data: Data()); XCTFail("Symlink escape") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.txt").path))
        let dangling = root.appendingPathComponent(owner.uuidString).appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: outside.appendingPathComponent("missing"))
        do { _ = try await files.write(conversationID: owner, path: "dangling", data: Data()); XCTFail("Dangling symlink") } catch {}
    }

    func testImportsAvoidOverwriteAndTemporaryExportIsAnIndependentCopy() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let files = DesktopWorkspaceFiles(directory: root)
        let first = try await files.importData(conversationID: owner, name: "notes.txt", data: Data("one".utf8))
        let second = try await files.importData(conversationID: owner, name: "notes.txt", data: Data("two".utf8))
        XCTAssertEqual(first.id, "notes.txt")
        XCTAssertEqual(second.id, "notes-2.txt")
        let url = try await files.temporaryURL(conversationID: owner, path: first.id)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await files.delete(conversationID: owner, path: first.id)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one")
        do { _ = try await files.read(conversationID: owner, path: first.id); XCTFail("Deleted file") } catch {}
    }

    func testDeletedOwnerRejectsLateToolWriteAndMissingReadIsReported() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let files = DesktopWorkspaceFiles(directory: root)
        do { _ = try await files.read(conversationID: owner, path: "missing.txt"); XCTFail("Missing file") } catch {}
        _ = try await files.write(conversationID: owner, path: "before.txt", data: Data())
        try await files.removeConversation(owner)
        do { _ = try await files.write(conversationID: owner, path: "late.txt", data: Data()); XCTFail("Deleted owner write") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(owner.uuidString).path))
    }

    func testOverwriteRequiresExplicitPermissionWhenRequestedByTool() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let files = DesktopWorkspaceFiles(directory: root)
        _ = try await files.write(conversationID: owner, path: "result.txt", data: Data("first".utf8), overwrite: false)
        do { _ = try await files.write(conversationID: owner, path: "result.txt", data: Data("second".utf8), overwrite: false); XCTFail("Overwrite must be explicit") } catch {}
        let first = try await files.read(conversationID: owner, path: "result.txt")
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "first")
        _ = try await files.write(conversationID: owner, path: "result.txt", data: Data("second".utf8), overwrite: true)
        let second = try await files.read(conversationID: owner, path: "result.txt")
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "second")
    }

    func testWriteFailureDoesNotPublishSuccess() async throws {
        let root = directory()
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = DesktopWorkspaceFiles(directory: root)
        do { _ = try await files.write(conversationID: UUID(), path: "result.txt", data: Data()); XCTFail("Not a directory") } catch {}
    }
}
