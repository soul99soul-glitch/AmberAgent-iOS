import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSConversationArtifactStoreTests: XCTestCase {
    func testPinUnpinAndAdoptPersistAcrossStoreInstances() throws {
        let (fileURL, directory) = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snippet = IOSPinnedSnippet(
            id: "message-1",
            messageID: "message-1",
            turn: 1,
            text: "a pinned answer",
            kind: .message
        )
        let store = IOSConversationArtifactStore(fileURL: fileURL)

        try store.pin(snippet, for: "conversation-a")
        try store.adopt(versionID: "version-2", path: "docs/plan.md", for: "conversation-a")

        let reloaded = IOSConversationArtifactStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.snippets(for: "conversation-a"), [snippet])
        XCTAssertEqual(reloaded.adoptedVersions(for: "conversation-a"), ["docs/plan.md": "version-2"])
        XCTAssertEqual(reloaded.adoptedVersionID(for: "conversation-a", path: "docs/plan.md"), "version-2")

        try reloaded.unpin(snippetID: snippet.id, for: "conversation-a")
        let afterUnpin = IOSConversationArtifactStore(fileURL: fileURL)
        XCTAssertEqual(afterUnpin.snippets(for: "conversation-a"), [])
        XCTAssertEqual(afterUnpin.adoptedVersionID(for: "conversation-a", path: "docs/plan.md"), "version-2")
    }

    func testRemoveConversationClearsOnlyItsStoredData() throws {
        let (fileURL, directory) = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationArtifactStore(fileURL: fileURL)
        let first = IOSPinnedSnippet(id: "m1", messageID: "m1", turn: 1, text: "first", kind: .message)
        let second = IOSPinnedSnippet(id: "m2", messageID: "m2", turn: 2, text: "second", kind: .message)

        try store.pin(first, for: "conversation-a")
        try store.pin(second, for: "conversation-b")
        try store.adopt(versionID: "v1", path: "notes.md", for: "conversation-a")
        try store.removeConversation("conversation-a")

        let reloaded = IOSConversationArtifactStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.snippets(for: "conversation-a"), [])
        XCTAssertEqual(reloaded.adoptedVersions(for: "conversation-a"), [:])
        XCTAssertEqual(reloaded.snippets(for: "conversation-b"), [second])
    }

    func testCorruptStoreIsMovedAsideAndStoreStartsEmpty() throws {
        let (fileURL, directory) = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("{\"conversations\": [".utf8)
        try corrupt.write(to: fileURL)

        let store = IOSConversationArtifactStore(fileURL: fileURL)
        let message = try XCTUnwrap(store.storageError?.localizedDescription)
        XCTAssertTrue(message.contains("artifact-shelf-corrupt-"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("artifact-shelf-corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(backups[0].hasSuffix(".bak"), "备份不能是 .json，避免被当成会话")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(backups[0])), corrupt)

        let snippet = IOSPinnedSnippet(id: "m1", messageID: "m1", turn: 1, text: "text", kind: .message)
        try store.pin(snippet, for: "conversation-a")
        try store.removeConversation("conversation-b")
        let reloaded = IOSConversationArtifactStore(fileURL: fileURL)
        XCTAssertNil(reloaded.storageError)
        XCTAssertEqual(reloaded.snippets(for: "conversation-a"), [snippet])
    }

    func testCodeSnippetsFromSameMessageAreStoredSeparately() throws {
        let (fileURL, directory) = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let messages = [UIMessage.companion.user(prompt: "写两段代码"), UIMessage.companion.assistant(prompt: "答复")]
        let messageID = ChatMessageProjector.messageId(for: messages[1])
        let first = try XCTUnwrap(ChatArtifactPinning.snippet(
            messageID: messageID, text: "print(1)", kind: .code, codeLanguage: "swift", messages: messages
        ))
        let second = try XCTUnwrap(ChatArtifactPinning.snippet(
            messageID: messageID, text: "print(2)", kind: .code, codeLanguage: "", messages: messages
        ))
        let whole = try XCTUnwrap(ChatArtifactPinning.snippet(
            messageID: messageID, text: "答复", kind: .message, messages: messages
        ))
        let store = IOSConversationArtifactStore(fileURL: fileURL)

        try store.pin(first, for: "c")
        try store.pin(second, for: "c")
        try store.pin(whole, for: "c")
        try store.pin(whole, for: "c")

        let reloaded = IOSConversationArtifactStore(fileURL: fileURL).snippets(for: "c")
        XCTAssertEqual(reloaded.map(\.text), ["print(1)", "print(2)", "答复"])
        XCTAssertEqual(reloaded.map(\.codeLanguage), ["swift", nil, nil])
        XCTAssertEqual(Set(reloaded.map(\.turn)), [1])
    }

    private func makeStoreURL() -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationArtifactStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (directory.appendingPathComponent("artifact-shelf.json"), directory)
    }
}
