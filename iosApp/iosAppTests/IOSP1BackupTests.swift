import XCTest
@preconcurrency import Shared
@testable import iosApp

/// P1-8 backup conversations tests. Verifies the conversations bundle is
/// included in the export payload and can be round-tripped on restore.
@MainActor
final class IOSP1BackupTests: XCTestCase {

    private func makeTempDir(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testConversationsZipReturnsNilForEmptyDirectory() throws {
        let dir = try makeTempDir("EmptyConv")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(try IOSSyncBackup.conversationsZip(fromDirectory: dir))
    }

    func testConversationsZipBundlesJsonFiles() throws {
        let dir = try makeTempDir("Conv")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{\"id\":\"a\"}".data(using: .utf8)!.write(to: dir.appendingPathComponent("a.json"))
        try "{\"id\":\"b\"}".data(using: .utf8)!.write(to: dir.appendingPathComponent("b.json"))
        try "[]".data(using: .utf8)!.write(to: dir.appendingPathComponent("index.json"))
        // A non-json file must be excluded.
        try "ignore".data(using: .utf8)!.write(to: dir.appendingPathComponent("notes.txt"))

        let zip = try XCTUnwrap(IOSSyncBackup.conversationsZip(fromDirectory: dir))
        // Round-trip into a fresh dir via the public restore helper and assert
        // both json files reappear (and notes.txt does not).
        let dest = try makeTempDir("ConvDest")
        defer { try? FileManager.default.removeItem(at: dest) }
        let written = try IOSSyncBackup.restoreConversations(zipData: zip, intoDirectory: dest)
        XCTAssertEqual(written, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("b.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("index.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("notes.txt").path))

        let documents = try IOSSyncBackup.conversationDocuments(zipData: zip)
        XCTAssertEqual(Set(documents), ["{\"id\":\"a\"}", "{\"id\":\"b\"}"])
    }

    func testConversationBackupExcludesListMetadataSidecars() throws {
        let dir = try makeTempDir("ConvSidecars")
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"id":"conversation-1"}"#.write(
            to: dir.appendingPathComponent("conversation-1.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"conversation-1":"preview"}"#.write(
            to: dir.appendingPathComponent("list-previews.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"conversation-1":"sparkles"}"#.write(
            to: dir.appendingPathComponent("list-icons.json"),
            atomically: true,
            encoding: .utf8
        )

        let zip = try XCTUnwrap(IOSSyncBackup.conversationsZip(fromDirectory: dir))

        XCTAssertEqual(try IOSSyncBackup.conversationDocuments(zipData: zip), [#"{"id":"conversation-1"}"#])
    }

    func testConversationBackupExcludesConversationContainingHealthToolCall() throws {
        let dir = try makeTempDir("ConvHealthPrivacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"id":"safe","messageNodes":[]}"#.write(
            to: dir.appendingPathComponent("safe.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"id":"health","messageNodes":[{"parts":[{"type":"tool","toolName":"health_summary_read","output":[{"type":"text","text":"private"}]}]}]}"#.write(
            to: dir.appendingPathComponent("health.json"),
            atomically: true,
            encoding: .utf8
        )

        let zip = try XCTUnwrap(IOSSyncBackup.conversationsZip(fromDirectory: dir))

        XCTAssertEqual(try IOSSyncBackup.conversationDocuments(zipData: zip), [#"{"id":"safe","messageNodes":[]}"#])
    }

    func testConversationBackupReturnsNilWhenOnlyHealthConversationExists() throws {
        let dir = try makeTempDir("OnlyHealthPrivacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"parts":[{"tool_name":"health_summary_read"}]}"#.write(
            to: dir.appendingPathComponent("health.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertNil(try IOSSyncBackup.conversationsZip(fromDirectory: dir))
    }

    func testRestoreConversationsRoundTripsIntoDirectory() throws {
        let sourceDir = try makeTempDir("ConvSrc")
        let destDir = try makeTempDir("ConvDest")
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: destDir)
        }
        try "{\"title\":\"hello\"}".data(using: .utf8)!.write(to: sourceDir.appendingPathComponent("conv1.json"))
        let zip = try XCTUnwrap(IOSSyncBackup.conversationsZip(fromDirectory: sourceDir))

        let written = try IOSSyncBackup.restoreConversations(zipData: zip, intoDirectory: destDir)
        XCTAssertEqual(written, 1)
        let restored = try String(contentsOf: destDir.appendingPathComponent("conv1.json"), encoding: .utf8)
        XCTAssertTrue(restored.contains("hello"))
    }

    func testConversationThreadEdgesRoundTripAndLegacyBundleHasNoSidecar() throws {
        let sourceDir = try makeTempDir("ConvEdges")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let parentID = "11111111-1111-1111-1111-111111111111"
        let childID = "22222222-2222-2222-2222-222222222222"
        try #"{"id":"\#(parentID)","messageNodes":[]}"#.write(
            to: sourceDir.appendingPathComponent("\(parentID).json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"id":"\#(childID)","messageNodes":[]}"#.write(
            to: sourceDir.appendingPathComponent("\(childID).json"),
            atomically: true,
            encoding: .utf8
        )
        let edge = IOSConversationThreadEdge(
            childThreadId: childID,
            parentThreadId: parentID,
            agentPath: "/root/research",
            nickname: nil,
            roleAssistantId: nil,
            forkTurns: "all",
            status: "Open",
            createdAt: 1
        )

        let zip = try XCTUnwrap(
            IOSSyncBackup.conversationsZip(fromDirectory: sourceDir, threadEdges: [edge])
        )
        XCTAssertEqual(try IOSSyncBackup.conversationThreadEdges(zipData: zip), [edge])
        XCTAssertEqual(try IOSSyncBackup.conversationDocuments(zipData: zip).count, 2)

        let emptyRelationZip = try XCTUnwrap(
            IOSSyncBackup.conversationsZip(fromDirectory: sourceDir, threadEdges: [])
        )
        XCTAssertEqual(try IOSSyncBackup.conversationThreadEdges(zipData: emptyRelationZip), [])

        let legacyZip = try XCTUnwrap(IOSSyncBackup.conversationsZip(fromDirectory: sourceDir))
        XCTAssertNil(try IOSSyncBackup.conversationThreadEdges(zipData: legacyZip))

        let parentFile = sourceDir.appendingPathComponent("\(parentID).json")
        try #"{"id":"\#(parentID)","toolName":"health_summary_read"}"#.write(to: parentFile, atomically: true, encoding: .utf8)
        let privateParentZip = try XCTUnwrap(IOSSyncBackup.conversationsZip(fromDirectory: sourceDir, threadEdges: [edge]))
        XCTAssertEqual(try IOSSyncBackup.conversationThreadEdges(zipData: privateParentZip), [])
        try FileManager.default.removeItem(at: parentFile)
        let retainedChildZip = try XCTUnwrap(IOSSyncBackup.conversationsZip(fromDirectory: sourceDir, threadEdges: [edge]))
        XCTAssertEqual(try IOSSyncBackup.conversationThreadEdges(zipData: retainedChildZip), [edge])
        XCTAssertEqual(try IOSSyncBackup.conversationDocuments(zipData: retainedChildZip).count, 1)
    }

    func testExportWithConversationsIncludesConversationsDataset() throws {
        let dir = try makeTempDir("ConvExport")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{\"id\":\"x\"}".data(using: .utf8)!.write(to: dir.appendingPathComponent("x.json"))
        let convZip = try XCTUnwrap(IOSSyncBackup.conversationsZip(fromDirectory: dir))

        let settings = IosSettingsDefaults.shared.defaultSeededSettings()
        let data = try IOSSyncBackup.export(settings: settings, passphrase: "pw", conversationsZip: convZip)
        XCTAssertGreaterThan(data.count, 0)
        // The full import path decrypts and reads the payload manifest, which
        // must list a conversations dataset. (restorePreview can't see into the
        // encrypted payload, so use `import` to verify the dataset is present.)
        let restored = try IOSSyncBackup.import(data: data, passphrase: "pw")
        XCTAssertTrue(restored.preview.datasets.contains { $0.id == "conversations" })
        XCTAssertTrue(restored.preview.datasets.contains { $0.id == "settings" })
    }

    /// 收藏片段后备份/恢复仍可用：产物架 sidecar 不进入备份，恢复覆盖的会话清掉本机旧收藏。
    func testBackupRestoreSucceedsAfterPinningSnippet() async throws {
        let sourceDir = try makeTempDir("ConvPinnedSource")
        let targetDir = try makeTempDir("ConvPinnedTarget")
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: targetDir)
        }
        let source = IOSConversationStore(baseDirectory: sourceDir)
        await source.bootstrap()
        let id = try XCTUnwrap(source.currentConversation?.id).toHexDashString()
        let answer = UIMessage.companion.assistant(prompt: "收藏这段")
        let messages = [UIMessage.companion.user(prompt: "问题"), answer]
        await source.saveCurrent(messages: messages)
        let snippet = try XCTUnwrap(ChatArtifactPinning.snippet(
            messageID: ChatMessageProjector.messageId(for: answer), text: "收藏这段", kind: .message, messages: messages
        ))
        try source.artifactStore.pin(snippet, for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceDir.appendingPathComponent("artifact-shelf.json").path))

        let zip = try XCTUnwrap(IOSSyncBackup.conversationsZip(fromDirectory: sourceDir))
        let documents = try IOSSyncBackup.conversationDocuments(zipData: zip)
        XCTAssertEqual(documents.count, 1)
        XCTAssertFalse(documents.contains { $0.contains("adoptedVersions") })

        // 目标设备上同一会话已有旧收藏：恢复后该会话的收藏被清掉。
        let target = IOSConversationStore(baseDirectory: targetDir)
        await target.bootstrap()
        try target.artifactStore.pin(snippet, for: id)
        let restored = try await target.importConversationDocuments(documents)
        XCTAssertEqual(restored, 1)
        XCTAssertTrue(target.artifactStore.snippets(for: id).isEmpty)
        XCTAssertTrue(target.allSummaries.contains { $0.id.toHexDashString() == id })
    }
}
