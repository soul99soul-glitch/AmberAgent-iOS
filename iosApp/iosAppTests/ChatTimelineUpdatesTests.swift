import XCTest
import Shared
@testable import iosApp

@MainActor
final class ChatTimelineUpdatesTests: ChatNativeTimelineReplayTestCase {
    func testOnlyMountedPlainTextDeltasBypassStructureAndEverySignalIsDelivered() {
        let channel = ChatTimelineUpdates()
        let id = KotlinUuid.companion.random()
        let initial = makeAssistantMessage(id: id, text: "hello", finished: false)
        var delivered: [Int] = []
        let subscription = channel.signals.sink { delivered.append($0.revision) }
        defer { subscription.cancel() }
        var consumed = 0
        let owner = UUID()
        channel.attach(owner: owner) { _, _ in consumed += 1; return true }
        XCTAssertTrue(channel.publish(.init(revision: 1, reason: .streamDelta), messages: [initial]))
        let next = makeAssistantMessage(id: id, text: "hello again", finished: false)
        XCTAssertFalse(channel.publish(.init(revision: 2, reason: .streamDelta), messages: [next]))
        XCTAssertEqual(consumed, 1)
        XCTAssertTrue(channel.publish(.init(revision: 3, reason: .toolResultAppended), messages: [next]))
        channel.detach(owner: owner)
        XCTAssertTrue(channel.publish(.init(revision: 4, reason: .streamDelta), messages: [next]))
        XCTAssertEqual(delivered, [1, 2, 3, 4])
    }

    func testFirstVisibleTextAndChangedHistoryRequireStructuralPublication() {
        let channel = ChatTimelineUpdates()
        let id = KotlinUuid.companion.random()
        let oldHistory = makeAssistantMessage(text: "old history", finished: true)
        let empty = makeAssistantMessage(id: id, text: "", finished: false)
        channel.publish(.init(revision: 1, reason: .streamDelta), messages: [oldHistory, empty])
        channel.attach(owner: UUID()) { _, _ in true }
        let visible = makeAssistantMessage(id: id, text: "first", finished: false)
        XCTAssertTrue(channel.publish(.init(revision: 2, reason: .streamDelta), messages: [oldHistory, visible]))
        let editedHistory = makeAssistantMessage(id: oldHistory.id, text: "edited history", finished: true)
        let next = makeAssistantMessage(id: id, text: "first next", finished: false)
        XCTAssertTrue(channel.publish(.init(revision: 3, reason: .streamDelta), messages: [editedHistory, next]))
        XCTAssertTrue(channel.structuralMessages.first === editedHistory)
    }

    func testChunkMembershipSurvivesPrependingHistory() {
        let messages = (0..<35).map { makeAssistantMessage(text: "row \($0)", finished: true) }
        let short = NativeTimelineProjector.build(messages: messages, event: .conversationLoaded, startIndex: 23)
        let expanded = NativeTimelineProjector.build(messages: messages, event: .conversationLoaded, startIndex: 3)
        func membership(_ projection: NativeTimelineProjection) -> [String: String] {
            Dictionary(uniqueKeysWithValues: NativeTimelineChunk.group(projection.entries).flatMap { chunk in
                chunk.entries.map { ($0.id, chunk.id) }
            })
        }
        let original = membership(short), larger = membership(expanded)
        for (row, chunk) in original { XCTAssertEqual(larger[row], chunk) }
        XCTAssertEqual(Set(NativeTimelineChunk.group(expanded.entries).map(\.id)).count,
                       NativeTimelineChunk.group(expanded.entries).count)
    }
}
