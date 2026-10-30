import XCTest
@testable import AmberMac

final class DesktopWorkspaceLocationsTests: XCTestCase {
    private var roots: [URL] = []
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("amber-locations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url.resolvingSymlinksInPath()
    }
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) } }

    func testWithoutDefaultEverythingStaysInLegacyDirectory() async throws {
        let legacy = try directory(), owner = UUID()
        let files = DesktopWorkspaceFiles(directory: legacy)
        _ = try await files.write(conversationID: owner, path: "a.txt", data: Data("a".utf8))
        XCTAssertEqual(files.locations.kind(of: owner), .legacy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(owner.uuidString + "/a.txt").path))
    }

    func testDefaultRootCreatesTitledFolderOnFirstWriteAndKeepsIt() async throws {
        let legacy = try directory(), root = try directory(), owner = UUID()
        let state = legacy.appendingPathComponent("locations.json")
        let files = DesktopWorkspaceFiles(directory: legacy, locationsFile: state)
        try files.locations.setDefaultRoot(root)
        files.locations.noteTitle("周报/整理", for: owner)
        XCTAssertNil(files.locations.existingDirectory(for: owner))
        let empty = try await files.list(conversationID: owner)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "Listing must not create folders")
        _ = try await files.write(conversationID: owner, path: "out.md", data: Data("x".utf8))
        let folder = root.appendingPathComponent("周报 整理")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("out.md").path))
        XCTAssertEqual(files.locations.kind(of: owner), .managed)
        // Changing the default later does not move existing conversations.
        try files.locations.setDefaultRoot(try directory())
        let reopened = DesktopWorkspaceFiles(directory: legacy, locationsFile: state)
        XCTAssertEqual(reopened.locations.existingDirectory(for: owner)?.path, folder.path)
        let second = UUID()
        reopened.locations.noteTitle("周报/整理", for: second)
        try reopened.locations.setDefaultRoot(root)
        _ = try await reopened.write(conversationID: second, path: "b.md", data: Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("周报 整理 2/b.md").path))
    }

    func testExistingLegacyFilesWinOverNewDefault() async throws {
        let legacy = try directory(), root = try directory(), owner = UUID()
        let files = DesktopWorkspaceFiles(directory: legacy)
        _ = try await files.write(conversationID: owner, path: "old.txt", data: Data())
        try files.locations.setDefaultRoot(root)
        let entries = try await files.list(conversationID: owner)
        XCTAssertEqual(entries.map(\.id), ["old.txt"])
    }

    func testOpenedFolderIsUsedButNeverRemovedOrBackedUp() async throws {
        let legacy = try directory(), project = try directory(), owner = UUID()
        try Data("keep".utf8).write(to: project.appendingPathComponent("README.md"))
        let files = DesktopWorkspaceFiles(directory: legacy)
        try files.locations.bindExternal(project, to: owner)
        XCTAssertTrue(files.isExternal(owner))
        let entries = try await files.list(conversationID: owner)
        XCTAssertEqual(entries.map(\.id), ["README.md"])
        let directory = try await files.commandDirectory(conversationID: owner)
        XCTAssertEqual(directory.path, project.path)
        try await files.removeConversation(owner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("README.md").path))
    }

    func testManagedFolderGoesToTrashOnRemoval() async throws {
        let legacy = try directory(), root = try directory(), owner = UUID()
        let files = DesktopWorkspaceFiles(directory: legacy)
        try files.locations.setDefaultRoot(root)
        _ = try await files.write(conversationID: owner, path: "x.txt", data: Data())
        let folder = try XCTUnwrap(files.locations.existingDirectory(for: owner))
        try await files.removeConversation(owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testListingSkipsDependencyFoldersAndStopsAtLimit() async throws {
        let legacy = try directory(), project = try directory(), owner = UUID()
        let manager = FileManager.default
        try manager.createDirectory(at: project.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("node_modules/pkg/index.js"))
        try manager.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        for index in 0..<5 { try Data().write(to: project.appendingPathComponent("src/f\(index).swift")) }
        let files = DesktopWorkspaceFiles(directory: legacy)
        try files.locations.bindExternal(project, to: owner)
        let all = try await files.listing(conversationID: owner)
        XCTAssertEqual(all.files.count, 5)
        XCTAssertFalse(all.truncated)
        XCTAssertFalse(all.files.contains { $0.id.hasPrefix("node_modules") })
        let limited = try await files.listing(conversationID: owner, limit: 3)
        XCTAssertEqual(limited.files.count, 3)
        XCTAssertTrue(limited.truncated)
    }

    func testRejectsBroadOrMissingFolders() throws {
        let locations = DesktopWorkspaceLocations(legacyRoot: try directory())
        for url in [URL(fileURLWithPath: "/"), FileManager.default.homeDirectoryForCurrentUser,
                    URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")] {
            XCTAssertThrowsError(try locations.bindExternal(url, to: UUID()), url.path)
        }
    }

    func testFolderNameFallsBackToDate() {
        XCTAssertEqual(DesktopWorkspaceLocations.folderName("  a:b  "), "a b")
        XCTAssertTrue(DesktopWorkspaceLocations.folderName("新对话").hasPrefix("对话 "))
        XCTAssertTrue(DesktopWorkspaceLocations.folderName("...").hasPrefix("对话 "))
    }
}
