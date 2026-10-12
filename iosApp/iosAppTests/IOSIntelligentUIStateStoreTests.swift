import XCTest
@testable import iosApp

@MainActor
final class IOSIntelligentUIStateStoreTests: XCTestCase {
    func testUntouchedDraftIsNotSavedOrMadeActive() async throws {
        let (fileURL, directory) = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSIntelligentUIStateStore(fileURL: fileURL)
        let card = definition()
        let origin = source()

        store.register(source: origin, definition: card)
        XCTAssertNil(store.draft(for: origin, definition: card).selectedOptionID)
        try store.update(source: origin, definition: card, selectedOptionID: nil, values: [:])
        try await store.flush()

        XCTAssertEqual(store.revision, 0)
        XCTAssertNil(store.activeSource(for: origin.conversationID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testConversationMessageVariantAndPartIdentityAreIndependent() throws {
        let store = IOSIntelligentUIStateStore()
        let card = definition()
        let sources = [
            source(),
            source(conversationID: "other"),
            source(messageID: "variant-b"),
            source(textPartIndex: 1)
        ]
        for (index, origin) in sources.enumerated() {
            try store.update(
                source: origin, definition: card, selectedOptionID: index.isMultiple(of: 2) ? "a" : "b",
                values: ["constraints": "value-\(index)"]
            )
        }
        for (index, origin) in sources.enumerated() {
            let draft = store.draft(for: origin, definition: card)
            XCTAssertEqual(draft.values["constraints"], "value-\(index)")
            XCTAssertEqual(draft.selectedOptionID, index.isMultiple(of: 2) ? "a" : "b")
        }
        XCTAssertEqual(store.activeSource(for: "conversation"), sources[3])
        XCTAssertEqual(store.activeSource(for: "other"), sources[1])
    }

    func testRepeatedUpdatesDoNotPublishOrAdvanceDraftRevision() throws {
        let store = IOSIntelligentUIStateStore()
        let card = definition()
        let origin = source()
        try store.update(source: origin, definition: card, selectedOptionID: "a", values: ["constraints": "保留"])
        let previousRevision = store.revision
        let previousDraft = store.draft(for: origin, definition: card)
        try store.update(source: origin, definition: card, selectedOptionID: "a", values: ["constraints": "保留"])

        XCTAssertEqual(store.revision, previousRevision)
        XCTAssertEqual(store.draft(for: origin, definition: card), previousDraft)
    }

    func testDefinitionChangeInvalidatesWithoutMigratingOldChoiceAndInputs() throws {
        let store = IOSIntelligentUIStateStore()
        let origin = source()
        let original = definition()
        try store.update(source: origin, definition: original, selectedOptionID: "a", values: ["constraints": "old"])
        let oldRevision = store.revision
        let changed = definition(question: "改成另一个问题")
        store.register(source: origin, definition: changed)

        XCTAssertTrue(store.hasDefinitionChanged(for: origin, definition: changed))
        XCTAssertNil(store.draft(for: origin, definition: changed).selectedOptionID)
        XCTAssertEqual(store.draft(for: origin, definition: changed).values, [:])
        XCTAssertEqual(store.revision, oldRevision, "注册定义不写用户状态")

        try store.update(source: origin, definition: changed, selectedOptionID: "b", values: [:])
        XCTAssertFalse(store.hasDefinitionChanged(for: origin, definition: changed))
        XCTAssertEqual(store.draft(for: origin, definition: changed).revision, 2)
    }

    func testUnknownFieldsAreFilteredAndUnknownOptionsRejected() throws {
        let store = IOSIntelligentUIStateStore()
        let card = definition()
        let origin = source()
        try store.update(
            source: origin, definition: card, selectedOptionID: "a",
            values: ["constraints": "known", "unknown": "untrusted", "empty": ""]
        )
        XCTAssertEqual(store.draft(for: origin, definition: card).values, ["constraints": "known"])
        let revision = store.revision
        XCTAssertThrowsError(try store.update(source: origin, definition: card, selectedOptionID: "missing", values: [:]))
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.draft(for: origin, definition: card).selectedOptionID, "a")
        XCTAssertThrowsError(try store.update(
            source: source(cardID: "wrong"), definition: card, selectedOptionID: "a", values: [:]
        ))
    }

    func testLatestDraftAndActiveSourceRestoreAfterRapidWrites() async throws {
        let (fileURL, directory) = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSIntelligentUIStateStore(fileURL: fileURL)
        let card = definition()
        let origin = source()
        for value in 0..<40 {
            try store.update(
                source: origin, definition: card, selectedOptionID: "a",
                values: ["constraints": "\(value)"]
            )
        }
        try await store.flush()

        let restored = IOSIntelligentUIStateStore(fileURL: fileURL)
        restored.register(source: origin, definition: card)
        XCTAssertNil(restored.storageError)
        XCTAssertEqual(restored.draft(for: origin, definition: card), store.draft(for: origin, definition: card))
        XCTAssertEqual(restored.draft(for: origin, definition: card).values, ["constraints": "39"])
        XCTAssertEqual(restored.activeSource(for: origin.conversationID), origin)
    }

    func testWriteFailureKeepsMemoryAndReportsUnsavedState() async throws {
        let (fileURL, directory) = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("blocked directory".utf8).write(to: directory)
        let store = IOSIntelligentUIStateStore(fileURL: fileURL)
        let card = definition()
        let origin = source()
        try store.update(source: origin, definition: card, selectedOptionID: "b", values: ["constraints": "keep"])

        do {
            try await store.flush()
            XCTFail("写入失败必须可见")
        } catch {
            XCTAssertTrue(try XCTUnwrap(store.storageError).contains("尚未保存"))
        }
        XCTAssertEqual(store.draft(for: origin, definition: card).selectedOptionID, "b")
        XCTAssertEqual(store.draft(for: origin, definition: card).values["constraints"], "keep")
    }

    func testCorruptLoadPreservesOriginalFileAndDoesNotOverwriteOnEdit() async throws {
        let (fileURL, directory) = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("{broken json".utf8)
        try corrupt.write(to: fileURL)
        let store = IOSIntelligentUIStateStore(fileURL: fileURL)
        XCTAssertNotNil(store.storageError)
        try store.update(source: source(), definition: definition(), selectedOptionID: "a", values: [:])
        do {
            try await store.flush()
            XCTFail("无法读取的原文件不能被后续写入覆盖")
        } catch {
            XCTAssertNotNil(store.storageError)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
        XCTAssertEqual(store.draft(for: source(), definition: definition()).selectedOptionID, "a")
    }

    func testRemoveConversationClearsOnlyItsDraftsAndActiveSourceDurably() async throws {
        let (fileURL, directory) = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSIntelligentUIStateStore(fileURL: fileURL)
        let card = definition()
        let first = source()
        let second = source(conversationID: "other")
        try store.update(source: first, definition: card, selectedOptionID: "a", values: [:])
        try store.update(source: second, definition: card, selectedOptionID: "b", values: [:])
        store.removeConversation(first.conversationID)
        let afterRemoval = store.revision
        store.removeConversation(first.conversationID)
        XCTAssertEqual(store.revision, afterRemoval)
        try await store.flush()

        let restored = IOSIntelligentUIStateStore(fileURL: fileURL)
        restored.register(source: first, definition: card)
        restored.register(source: second, definition: card)
        XCTAssertNil(restored.activeSource(for: first.conversationID))
        XCTAssertNil(restored.draft(for: first, definition: card).selectedOptionID)
        XCTAssertEqual(restored.activeSource(for: second.conversationID), second)
        XCTAssertEqual(restored.draft(for: second, definition: card).selectedOptionID, "b")
    }

    private func source(
        conversationID: String = "conversation", messageID: String = "variant-a",
        textPartIndex: Int = 0, cardID: String = "card"
    ) -> IOSIntelligentUISource {
        .init(conversationID: conversationID, messageID: messageID, textPartIndex: textPartIndex, cardID: cardID)
    }

    private func definition(question: String = "请选择") -> IOSIntelligentUICardDefinition {
        .init(
            cardID: "card", goal: "确定方向", question: question,
            options: [
                .init(id: "a", title: "A", summary: "方案 A", tradeoffs: nil, recommended: nil),
                .init(id: "b", title: "B", summary: "方案 B", tradeoffs: nil, recommended: nil)
            ],
            fields: [.init(id: "constraints", label: "约束", required: false, placeholder: nil, type: nil)],
            submit: .init(label: "继续", intent: "continue")
        )
    }

    private func makeStoreURL() -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSIntelligentUIStateStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (directory.appendingPathComponent("task-ui-drafts.json"), directory)
    }
}
