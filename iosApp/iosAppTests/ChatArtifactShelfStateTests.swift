import XCTest
@testable import iosApp

final class ChatArtifactShelfStateTests: XCTestCase {
    private func index(_ ids: [String]) -> ConversationArtifactIndex {
        .init(images: ids.map {
            .init(id: $0, url: "https://example.com/\($0).png", prompt: nil,
                  source: .init(messageID: "message", turn: 1, toolCallID: $0))
        }, files: [], webPages: [])
    }

    private func fileIndex(_ versions: [String]) -> ConversationArtifactIndex {
        .init(
            images: [],
            files: versions.isEmpty ? [] : [
                .init(path: "notes.md", versions: versions.enumerated().map { offset, id in
                    .init(id: id, source: .init(messageID: "message-\(offset)", turn: offset + 1, toolCallID: id), content: nil)
                })
            ],
            webPages: []
        )
    }

    func testArrivalOnlyForNewArtifactsInTheForegroundRun() {
        var state = ChatArtifactShelfState()
        state.update(index(["old"]), conversationID: "A", isForegroundRunning: true, allowArrival: true)
        XCTAssertNil(state.arrival)
        state.update(index(["old", "new"]), conversationID: "A", isForegroundRunning: true, allowArrival: true)
        XCTAssertEqual(state.arrival?.id, "new")
        XCTAssertEqual(state.index.count, 2)
        state.update(index(["old", "new"]), conversationID: "A", isForegroundRunning: false, allowArrival: true)
        XCTAssertEqual(state.arrival?.id, "new", "收尾快照不取消已开始的飞入")
        state.update(index(["old", "new", "background"]), conversationID: "A", isForegroundRunning: false, allowArrival: true)
        XCTAssertNil(state.arrival)
    }

    func testConversationAndBranchReloadsDoNotAnimateHistoricalArtifacts() {
        var state = ChatArtifactShelfState()
        state.update(index([]), conversationID: "A", isForegroundRunning: true, allowArrival: true)
        state.update(index(["history"]), conversationID: "B", isForegroundRunning: true, allowArrival: true)
        XCTAssertNil(state.arrival)
        state.update(index(["branch"]), conversationID: "B", isForegroundRunning: true, allowArrival: false)
        XCTAssertNil(state.arrival)
        XCTAssertEqual(state.index.images.map(\.id), ["branch"])
    }

    func testAddingAFileVersionDoesNotCountOrAnimateAsANewArtifact() {
        var state = ChatArtifactShelfState()
        state.update(fileIndex(["write-1"]), conversationID: "A", isForegroundRunning: true, allowArrival: true)
        XCTAssertEqual(state.index.count, 1)
        XCTAssertNil(state.arrival)

        state.update(fileIndex(["write-1", "edit-2"]), conversationID: "A", isForegroundRunning: true, allowArrival: true)

        XCTAssertEqual(state.index.count, 1)
        XCTAssertNil(state.arrival)
    }
}
