import Foundation
import XCTest
import Shared
@testable import iosApp

@MainActor
final class WatchLocalStoreTests: XCTestCase {
    func testNoteIsDurableAndOnlyAcceptedResultMarksItSynced() throws {
        let url = makeURL("note-state.json")
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let note = WatchNote(id: "note-1", text: "记下这件事", createdAt: createdAt)

        let first = WatchLocalStore(fileURL: url)
        XCTAssertTrue(first.saveNote(note))
        XCTAssertEqual(first.note(id: note.id)?.syncedAt, nil)

        let relaunched = WatchLocalStore(fileURL: url)
        XCTAssertEqual(relaunched.note(id: note.id)?.text, note.text)
        XCTAssertNil(relaunched.note(id: note.id)?.syncedAt)

        XCTAssertTrue(relaunched.markNoteSynced(id: note.id, at: createdAt.addingTimeInterval(3)))
        XCTAssertNotNil(WatchLocalStore(fileURL: url).note(id: note.id)?.syncedAt)
    }

    func testFailedAtomicWriteDoesNotPublishOrSendNote() throws {
        let blockedParent = makeURL("cannot-write")
        try Data("not a directory".utf8).write(to: blockedParent)
        let store = WatchLocalStore(fileURL: blockedParent.appendingPathComponent("state.json"))
        XCTAssertNil(store.storageError)
        let note = WatchNote(id: "note-failure", text: "仍要保留", createdAt: Date())

        XCTAssertFalse(store.saveNote(note))
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertFalse(store.hasUnsyncedNotes)
        XCTAssertNotNil(store.storageError)
    }

    func testCorruptSourceIsPreservedAndCannotBeOverwrittenByEmptyState() throws {
        let url = makeURL("corrupt-state.json")
        let original = Data("this is not amber state".utf8)
        try original.write(to: url, options: .atomic)

        let store = WatchLocalStore(fileURL: url)
        XCTAssertNotNil(store.storageError)
        XCTAssertFalse(store.saveNote(WatchNote(
            id: "note-corrupt",
            text: "不要覆盖损坏源",
            createdAt: Date()
        )))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testPendingRequestKeepsExactPayloadAcrossUnknownAndRotatesAfterRejection() throws {
        let url = makeURL("draft-state.json")
        let store = WatchLocalStore(fileURL: url)
        let draft = store.ensureDraft(key: "ask:new", mode: .ask, initialText: "原始问题")
        let request = WatchTaskActionRequest(
            requestId: draft.requestId,
            runId: "",
            conversationId: nil,
            decisionId: nil,
            action: .ask,
            optionId: nil,
            text: draft.text,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(store.beginSending(key: draft.key, request: request))
        XCTAssertEqual(store.draft(forKey: draft.key)?.pendingRequest, request)
        XCTAssertFalse(store.updateDraftText(key: draft.key, text: "不能改写已发送内容"))

        let unknown = WatchTaskActionResult(
            requestId: request.requestId,
            runId: "",
            accepted: false,
            message: "正在确认是否已接收",
            snapshot: nil,
            conversationId: nil,
            deliveryUnknown: true
        )
        XCTAssertTrue(store.applyResult(unknown))
        let unknownDraft = try XCTUnwrap(store.draft(forKey: draft.key))
        XCTAssertTrue(unknownDraft.deliveryUnknown)
        XCTAssertEqual(unknownDraft.pendingRequest, request)
        XCTAssertFalse(store.beginSending(key: draft.key, request: request.withText("改过的问题")))

        let rejected = WatchTaskActionResult(
            requestId: request.requestId,
            runId: "",
            accepted: false,
            message: "手机拒绝处理",
            snapshot: nil,
            conversationId: nil,
            deliveryUnknown: false
        )
        XCTAssertTrue(store.applyResult(rejected))
        let released = try XCTUnwrap(store.draft(forKey: draft.key))
        XCTAssertNil(released.pendingRequest)
        XCTAssertFalse(released.deliveryUnknown)
        XCTAssertNotEqual(released.requestId, request.requestId)
        XCTAssertTrue(store.updateDraftText(key: draft.key, text: "编辑后再问"))

        let secondRequest = WatchTaskActionRequest(
            requestId: released.requestId,
            runId: "",
            conversationId: nil,
            decisionId: nil,
            action: .ask,
            optionId: nil,
            text: "编辑后再问",
            createdAt: Date()
        )
        XCTAssertTrue(store.beginSending(key: draft.key, request: secondRequest))
        XCTAssertTrue(store.applyResult(WatchTaskActionResult(
            requestId: secondRequest.requestId,
            runId: "",
            accepted: true,
            message: nil,
            snapshot: nil,
            conversationId: "conversation-1",
            deliveryUnknown: false
        )))
        XCTAssertNil(store.draft(forKey: draft.key))
    }

    func testStartedNoteIsImmutableUntilAccepted() throws {
        let url = makeURL("note-transfer.json")
        let store = WatchLocalStore(fileURL: url)
        let note = WatchNote(id: "note-transfer", text: "原文", createdAt: Date())
        XCTAssertTrue(store.saveNote(note))
        XCTAssertTrue(store.markNoteTransferStarted(id: note.id))
        XCTAssertFalse(store.saveNote(WatchNote(
            id: note.id,
            text: "试图覆盖原文",
            createdAt: note.createdAt
        )))
        XCTAssertEqual(store.note(id: note.id)?.text, note.text)
        XCTAssertTrue(store.markNoteSynced(id: note.id))
        XCTAssertFalse(store.hasUnsyncedNotes)
    }

    func testSavedNoteIsImmutableBeforeTransferAndIdenticalSaveCanRetry() {
        let store = WatchLocalStore(fileURL: makeURL("immutable-note.json"))
        let note = WatchNote(id: "original", text: "原文", createdAt: Date())
        XCTAssertTrue(store.saveNote(note))
        XCTAssertFalse(store.saveNote(WatchNote(id: note.id, text: "新内容", createdAt: note.createdAt)))
        XCTAssertTrue(store.saveNote(note))
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.text, note.text)
    }

    func testCacheClearProtectsDraftsAndUnsyncedNotes() {
        let store = WatchLocalStore(fileURL: makeURL("clear-cache.json"))
        let draft = store.ensureDraft(key: "ask", mode: .ask, initialText: "未发送")
        XCTAssertFalse(store.clearCache())
        XCTAssertNotNil(store.draft(forKey: draft.key))
        XCTAssertTrue(store.removeDraft(key: draft.key))
        let note = WatchNote(id: "pending", text: "待同步", createdAt: Date())
        XCTAssertTrue(store.saveNote(note))
        XCTAssertFalse(store.clearCache())
        XCTAssertTrue(store.markNoteSynced(id: note.id))
        XCTAssertTrue(store.clearCache())
        XCTAssertTrue(store.notes.isEmpty)
    }

    private func makeURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-watch-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }
}

private extension WatchTaskActionRequest {
    func withText(_ text: String) -> WatchTaskActionRequest {
        var copy = self
        copy.text = text
        return copy
    }
}
