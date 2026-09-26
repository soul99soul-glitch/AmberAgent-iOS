import XCTest
@testable import iosApp

final class ChatTopBarArrivalTests: XCTestCase {
    private func notice(_ id: String = "other", kind: ConversationActivityNotice.Kind = .awaitingUser,
                        time: TimeInterval = 1, preview: String = "问题") -> ConversationActivityNotice {
        .init(conversationId: id, title: "对话", kind: kind, preview: preview,
              occurredAt: Date(timeIntervalSince1970: time))
    }

    private func input(_ notices: [ConversationActivityNotice], id: String = "current",
                       generating: Bool = false, awaiting: Bool = false) -> ChatTopBarArrivalState.Input {
        .init(conversationID: id, isAwaitingUser: awaiting, isGenerating: generating, notices: notices)
    }

    func testNewEventArrivesButInitialSnapshotAndPreviewUpdatesDoNot() {
        var state = ChatTopBarArrivalState()
        XCTAssertNil(state.update(input([])))
        XCTAssertEqual(state.update(input([notice()])), notice())
        XCTAssertEqual(state.announcement, notice())
        XCTAssertNil(state.update(input([notice(preview: "更新后的预览")])))
        XCTAssertNotNil(state.update(input([notice(kind: .completed, time: 2)])))
    }

    func testGenerationAllowsArrivalEffectsButDoesNotBorrowIsland() {
        var state = ChatTopBarArrivalState()
        _ = state.update(input([], generating: true))
        XCTAssertNotNil(state.update(input([notice()], generating: true)))
        XCTAssertNil(state.announcement)
        XCTAssertNil(state.update(input([notice()])))
        XCTAssertNil(state.announcement, "停止生成后不补播旧事件")
    }

    func testLeavingWaitingConversationSuppressesReplayOnly() {
        var state = ChatTopBarArrivalState()
        _ = state.update(input([], id: "A", awaiting: true))
        _ = state.update(input([], id: "B"))
        XCTAssertNil(state.update(input([notice("A")], id: "B")))
        XCTAssertNil(state.arrival)
        XCTAssertNil(state.announcement)
        XCTAssertNotNil(state.update(input([notice("A", kind: .completed, time: 2)], id: "B")))
    }

    func testReplayCoalescedWithNavigationDoesNotMuteNextRealQuestion() {
        var state = ChatTopBarArrivalState()
        _ = state.update(input([], id: "A", awaiting: true))
        XCTAssertNil(state.update(input([notice("A")], id: "B")))
        XCTAssertNotNil(state.update(input([notice("A", time: 2)], id: "B")))
    }

    func testLeavingGeneratingConversationDoesNotMuteAFutureQuestion() {
        var state = ChatTopBarArrivalState()
        _ = state.update(input([], id: "A", generating: true))
        _ = state.update(input([], id: "B"))
        XCTAssertNotNil(state.update(input([notice("A")], id: "B")))
    }

    func testSwitchClearsArrivalAndAnnouncementEvenWithIncomingNotice() {
        var state = ChatTopBarArrivalState()
        _ = state.update(input([]))
        _ = state.update(input([notice()]))
        XCTAssertNil(state.update(input([notice(time: 2)], id: "new")))
        XCTAssertNil(state.arrival)
        XCTAssertNil(state.announcement)
    }

    func testGenerationStartingClearsAnnouncement() {
        var state = ChatTopBarArrivalState()
        _ = state.update(input([]))
        _ = state.update(input([notice()]))
        _ = state.update(input([notice()], generating: true))
        XCTAssertNil(state.announcement)
    }
}
