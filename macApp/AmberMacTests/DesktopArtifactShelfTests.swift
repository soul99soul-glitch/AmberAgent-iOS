import XCTest
@testable import AmberMac

@MainActor final class DesktopArtifactShelfTests: XCTestCase {
    private func temporaryFile() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amber-shelf-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("artifact-shelf.json")
    }

    func testPinsPersistPerConversationAndReload() throws {
        let url = temporaryFile()
        let first = UUID(), second = UUID(), message = UUID()
        let shelf = DesktopArtifactShelf(fileURL: url)
        shelf.pin(messageID: message, kind: .message, text: "整条回答", in: first)
        shelf.pin(messageID: message, kind: .code, text: "print(1)", codeLanguage: "swift", in: first)
        shelf.pin(messageID: message, kind: .code, text: "print(1)", codeLanguage: "swift", in: first)
        shelf.pin(messageID: UUID(), kind: .message, text: "另一会话", in: second)

        let reloaded = DesktopArtifactShelf(fileURL: url)
        XCTAssertEqual(reloaded.pins(for: first).map(\.kind), [.code, .message])
        XCTAssertEqual(reloaded.pins(for: first).first?.codeLanguage, "swift")
        XCTAssertEqual(reloaded.pins(for: second).map(\.text), ["另一会话"])
        XCTAssertNil(reloaded.errorMessage)

        let code = try XCTUnwrap(reloaded.pinnedSnippet(messageID: message, kind: .code, text: "print(1)", in: first))
        reloaded.unpin(code.id, in: first)
        reloaded.removeConversation(second)
        let afterRemoval = DesktopArtifactShelf(fileURL: url)
        XCTAssertEqual(afterRemoval.pins(for: first).map(\.text), ["整条回答"])
        XCTAssertTrue(afterRemoval.pins(for: second).isEmpty)
    }

    func testUnreadableFileIsKeptAside() throws {
        let url = temporaryFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: url)
        let shelf = DesktopArtifactShelf(fileURL: url)
        XCTAssertNotNil(shelf.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(siblings.count, 1)
    }

    func testDeletingConversationRemovesItsPins() async throws {
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.shelf.\(UUID().uuidString)")!, credentials: DesktopMemoryCredentials())
        let kept = DesktopConversation(title: "保留", messages: [DesktopMessage(role: .assistant, text: "保留内容")])
        let removed = DesktopConversation(title: "删除", messages: [DesktopMessage(role: .assistant, text: "删除内容")])
        let url = temporaryFile()
        let workspace = DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage([kept, removed]),
            provider: NoProvider(), initialConversations: [kept, removed], artifactShelf: DesktopArtifactShelf(fileURL: url))
        workspace.artifactShelf.pin(messageID: kept.messages[0].id, kind: .message, text: "保留内容", in: kept.id)
        workspace.artifactShelf.pin(messageID: removed.messages[0].id, kind: .message, text: "删除内容", in: removed.id)

        workspace.delete(removed.id)
        _ = await workspace.flush()

        XCTAssertTrue(workspace.artifactShelf.pins(for: removed.id).isEmpty)
        XCTAssertEqual(DesktopArtifactShelf(fileURL: url).pins(for: kept.id).map(\.text), ["保留内容"])
        XCTAssertTrue(DesktopArtifactShelf(fileURL: url).pins(for: removed.id).isEmpty)
    }

    func testBackupCarriesPinsToRestoredCopy() async throws {
        let directory = temporaryFile().deletingLastPathComponent()
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.shelf.backup.\(UUID().uuidString)")!, credentials: DesktopMemoryCredentials())
        let original = DesktopConversation(title: "原会话", messages: [DesktopMessage(role: .assistant, text: "固定内容")])
        let shelf = DesktopArtifactShelf()
        shelf.pin(messageID: original.messages[0].id, kind: .message, text: "固定内容", in: original.id)
        let coordinator = DesktopBackupCoordinator(storage: DesktopMemoryConversationStorage([original]),
            files: DesktopWorkspaceFiles(directory: directory.appendingPathComponent("files")),
            insights: DesktopConversationInsights(), settings: settings,
            knowledge: DesktopKnowledgeStore(directory: directory.appendingPathComponent("knowledge")), artifactShelf: shelf)
        let payload = try DesktopBackup.decode(DesktopBackup.encode(try await coordinator.snapshot(current: [original]), password: nil), password: nil)
        XCTAssertEqual(payload.conversations.first?.pins?.map(\.text), ["固定内容"])
        let result = try await coordinator.restore(payload)
        let restored = try XCTUnwrap(result.conversations.first { $0.title == "原会话" })
        XCTAssertNotEqual(restored.id, original.id)
        XCTAssertEqual(shelf.pins(for: restored.id).map(\.messageID), [original.messages[0].id])
    }

    func testFindMatchesVisibleTextCaseInsensitivelyAndWraps() {
        let messages = [
            DesktopMessage(role: .user, text: "Swift 并发"),
            DesktopMessage(role: .assistant, text: "无关内容", reasoning: "swift 只在思考过程里"),
            DesktopMessage(role: .assistant, text: "使用 SWIFT actor"),
            DesktopMessage(role: .user, text: "结束"),
        ]
        XCTAssertEqual(DesktopConversationFind.matches("swift", in: messages), [messages[0].id, messages[2].id])
        XCTAssertTrue(DesktopConversationFind.matches("   ", in: messages).isEmpty)

        var find = DesktopConversationFind()
        find.update("swift", messages: messages)
        XCTAssertEqual(find.label, "1/2")
        XCTAssertEqual(find.currentMessageID, messages[0].id)
        find.step(1)
        XCTAssertEqual(find.currentMessageID, messages[2].id)
        find.step(1)
        XCTAssertEqual(find.currentMessageID, messages[0].id)
        find.step(-1)
        XCTAssertEqual(find.label, "2/2")

        // A refined query keeps the current message when it still matches.
        find.update("swift actor", messages: messages)
        XCTAssertEqual(find.label, "1/1")
        XCTAssertEqual(find.currentMessageID, messages[2].id)
        find.update("不存在", messages: messages)
        XCTAssertEqual(find.label, "0/0")
        XCTAssertNil(find.currentMessageID)
        find.step(1)
        XCTAssertNil(find.currentMessageID)
    }

    func testSingleMessageMarkdownExport() async throws {
        let message = DesktopMessage(role: .assistant, text: "## 结论\n\n```swift\nprint(1)\n```", reasoning: "先确认目标", state: .cancelled)
        let markdown = DesktopConversationExport.markdown(message, title: "规划\n会话")
        XCTAssertEqual(markdown, "# 规划 会话\n\n---\n\n## Amber\n\n### 思考过程\n\n先确认目标\n\n## 结论\n\n```swift\nprint(1)\n```\n\n> 已停止；以上为已收到内容。\n")

        let url = temporaryFile().deletingLastPathComponent().appendingPathComponent("message.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await DesktopConversationExport.writeMarkdown(message, title: "规划\n会话", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), markdown)
    }

    private final class NoProvider: DesktopTextProvider {
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            DesktopGeneration()
        }
    }
}
