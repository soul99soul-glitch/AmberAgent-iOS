import XCTest
@testable import AmberMac

final class DesktopStorageUsageTests: XCTestCase {
    func testActualFilesAreCountedAndMemoryConversationIsNotEstimatedAsDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspaces/owner")
        let knowledge = root.appendingPathComponent("Knowledge")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        try Data("1234".utf8).write(to: workspace.appendingPathComponent("result.txt"))
        try Data("abc".utf8).write(to: knowledge.appendingPathComponent("SOUL.md"))
        let result = try await DesktopStorageUsage.measure(DesktopStorageUsage.sources(amberRoot: root,
            knowledgeDirectory: knowledge, conversationsOnDisk: false))
        XCTAssertEqual(result.totalBytes, 7)
        XCTAssertEqual(result.totalFileCount, 2)
        XCTAssertEqual(result.areas.first?.byteCount, 0)
        XCTAssertTrue(result.areas.first?.note?.contains("内存") == true)
        XCTAssertEqual(result.areas.first { $0.id == "workspaces" }?.byteCount, 4)
        XCTAssertEqual(result.areas.first { $0.id == "knowledge" }?.fileCount, 1)
    }

    func testSymlinksAreNotFollowedAndDuplicateRootsAreNotDoubleCounted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: outside)
        try Data("own".utf8).write(to: root.appendingPathComponent("owned.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("missing"))
        let result = try await DesktopStorageUsage.measure([.init(id: "files", title: "Files", directories: [root, root])])
        XCTAssertEqual(result.totalBytes, 3)
        XCTAssertEqual(result.totalFileCount, 1)
        XCTAssertNotNil(result.areas.first?.note)
        let unavailable = try await DesktopStorageUsage.measure([.init(id: "preview", title: "Preview", directories: nil)])
        XCTAssertNil(unavailable.areas.first?.byteCount)
    }

    func testCancelledMeasurementThrowsInsteadOfPublishingEmptySuccess() async throws {
        let task = Task { try await DesktopStorageUsage.measure([]) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }
}
