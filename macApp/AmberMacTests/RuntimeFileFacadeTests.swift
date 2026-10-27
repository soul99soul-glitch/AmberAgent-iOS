import XCTest
@testable import AmberMac

@MainActor final class RuntimeFileFacadeTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration { DesktopGeneration() }
    }
    private func workspace(_ values: [DesktopConversation], files: DesktopWorkspaceFiles = DesktopWorkspaceFiles()) -> DesktopWorkspace {
        DesktopWorkspace(settings: DesktopSettings(defaults: UserDefaults(suiteName: "amber.files.facade.\(UUID().uuidString)")!, credentials: DesktopMemoryCredentials()),
            storage: DesktopMemoryConversationStorage(values), provider: Provider(), initialConversations: values, files: files)
    }

    func testFileFailureIsRetainedWithOriginalOwnerAfterSwitching() async throws {
        let first = DesktopConversation(title: "first"), second = DesktopConversation(title: "second")
        let value = workspace([first, second])
        let deletion = value.deleteWorkspaceFile("missing.txt")
        value.select(second.id)
        await deletion?.value
        XCTAssertNil(value.fileErrorMessage)
        value.select(first.id)
        await value.reloadFiles()?.value
        XCTAssertTrue(value.fileErrorMessage?.contains("删除文件失败") == true)
        _ = try await value.files.write(conversationID: first.id, path: "exists.txt", data: Data())
        await value.deleteWorkspaceFile("exists.txt")?.value
        XCTAssertNil(value.fileErrorMessage)
    }

    func testAttachmentCopyStaysWithOriginalOwnerAndSurvivesSourceDeletion() async throws {
        let first = DesktopConversation(title: "first"), second = DesktopConversation(title: "second")
        let value = workspace([first, second])
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("source text".utf8).write(to: source)
        let imported = value.addAttachments([source])
        value.select(second.id)
        XCTAssertFalse(value.isReadingAttachments)
        await imported?.value
        XCTAssertTrue(value.pendingAttachments.isEmpty)
        value.select(first.id)
        XCTAssertEqual(value.pendingAttachments.first?.text, "source text")
        try FileManager.default.removeItem(at: source)
        let saved = try await value.files.read(conversationID: first.id, path: source.lastPathComponent)
        XCTAssertEqual(String(data: saved, encoding: .utf8), "source text")
        let otherFiles = try await value.files.list(conversationID: second.id)
        XCTAssertTrue(otherFiles.isEmpty)
    }

    func testFlushWaitsForAcceptedAttachmentCopy() async throws {
        let conversation = DesktopConversation()
        let value = workspace([conversation])
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("accepted file".utf8).write(to: source)
        value.addAttachments([source])
        _ = await value.flush()
        XCTAssertFalse(value.isReadingAttachments)
        XCTAssertEqual(value.pendingAttachments.count, 1)
        let saved = try await value.files.read(conversationID: conversation.id, path: source.lastPathComponent)
        XCTAssertEqual(String(decoding: saved, as: UTF8.self), "accepted file")
    }

    func testWorkspacePreviewDoesNotExposeDeletedTemporarySourceURL() async throws {
        let conversation = DesktopConversation()
        let value = workspace([conversation])
        _ = try await value.files.write(conversationID: conversation.id, path: "notes.txt", data: Data("preview text".utf8))
        await value.previewWorkspaceFile("notes.txt")?.value
        XCTAssertEqual(value.filePreview?.name, "notes.txt")
        XCTAssertEqual(value.filePreview?.text, "preview text")
        XCTAssertNil(value.filePreview?.sourceURL)
        XCTAssertNil(value.filePreviewErrorMessage)
    }

    func testFlushWaitsForAcceptedWorkspaceImportWithOriginalOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("original.txt")
        try Data("accepted copy".utf8).write(to: source)
        let first = DesktopConversation(), second = DesktopConversation()
        let filesRoot = root.appendingPathComponent("files")
        let value = workspace([first, second], files: DesktopWorkspaceFiles(directory: filesRoot))
        value.importWorkspaceFiles([source])
        value.select(second.id)
        let flushed = await value.flush()
        XCTAssertTrue(flushed)
        let imported = filesRoot.appendingPathComponent(first.id.uuidString).appendingPathComponent(source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: imported), Data("accepted copy".utf8))
        let other = try await value.files.list(conversationID: second.id)
        XCTAssertTrue(other.isEmpty)
    }

    func testFlushWaitsForAcceptedWorkspaceDeleteAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let conversation = DesktopConversation()
        let value = workspace([conversation], files: DesktopWorkspaceFiles(directory: root.appendingPathComponent("files")))
        let content = Data("workspace artifact".utf8)
        _ = try await value.files.write(conversationID: conversation.id, path: "notes.txt", data: content)
        _ = try await value.files.write(conversationID: conversation.id, path: "remove.txt", data: Data())
        let destination = root.appendingPathComponent("export.txt")
        value.exportWorkspaceFile("notes.txt", to: destination)
        value.deleteWorkspaceFile("remove.txt")
        let flushed = await value.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(try Data(contentsOf: destination), content)
        let removed = root.appendingPathComponent("files").appendingPathComponent(conversation.id.uuidString).appendingPathComponent("remove.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
    }

    func testFlushWaitsForKnowledgeAndConversationImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let value = workspace([DesktopConversation()])
        _ = try await value.files.write(conversationID: try XCTUnwrap(value.selectedID), path: "SOUL.md", data: Data("concise replies".utf8))
        let source = root.appendingPathComponent("conversation.json")
        let imported = DesktopConversation(title: "imported", messages: [DesktopMessage(role: .user, text: "retained")])
        try DesktopJSON.encode(DesktopConversationExport(conversation: imported)).write(to: source, atomically: true, encoding: .utf8)
        value.importKnowledgeFromWorkspaceFile("SOUL.md")
        value.importConversation(from: source)
        let flushed = await value.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(value.knowledge.soulMarkdown, "concise replies")
        XCTAssertEqual(value.conversations.first(where: { $0.title == "imported" })?.messages.first?.text, "retained")
    }

    func testAcceptedConversationExportsFinishWithoutWaitingOnThemselves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let value = workspace([DesktopConversation(title: "exported", messages: [DesktopMessage(role: .user, text: "kept")])])
        let json = root.appendingPathComponent("conversation.json"), markdown = root.appendingPathComponent("conversation.md")
        value.exportConversation(to: json)
        value.exportReadableConversation(to: markdown, format: .markdown)
        let flushed = await value.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(try DesktopJSON.decode(DesktopConversationExport.self, from: String(contentsOf: json, encoding: .utf8)).conversation.title, "exported")
        XCTAssertTrue(try String(contentsOf: markdown, encoding: .utf8).contains("kept"))
    }

    func testOldFileOperationErrorDoesNotPreventSuccessfulFlush() async throws {
        let value = workspace([DesktopConversation()])
        await value.deleteWorkspaceFile("missing.txt")?.value
        XCTAssertNotNil(value.fileErrorMessage)
        let flushed = await value.flush()
        XCTAssertTrue(flushed)
    }
}
