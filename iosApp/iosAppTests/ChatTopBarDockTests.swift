import XCTest
@testable import iosApp

@MainActor
final class ChatTopBarDockTests: XCTestCase {
    func testEmptyConversationShowsSatelliteWhenAnotherConversationHasNotice() {
        let notice = ConversationActivityNotice(
            conversationId: "conversation-1",
            title: "等待确认",
            kind: .awaitingUser,
            preview: "要继续吗？",
            occurredAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            ChatTopBarDockState.resolve(hasMessages: false, notices: [notice], artifactCount: 3),
            .satellite(notice: notice, extraCount: 0)
        )
    }

    func testEmptyConversationWithoutNoticeHidesDock() {
        XCTAssertEqual(
            ChatTopBarDockState.resolve(hasMessages: false, notices: [], artifactCount: 3),
            .hidden
        )
    }

    func testConversationWithArtifactsMapsToShelf() {
        XCTAssertEqual(
            ChatTopBarDockState.resolve(hasMessages: true, notices: [], artifactCount: 4),
            .shelf(count: 4)
        )
        XCTAssertEqual(
            ChatTopBarDockState.resolve(hasMessages: true, notices: []),
            .shelf(count: 0)
        )
    }

    func testFirstNoticeMapsToSatelliteAndRemainingNoticesBecomeBadgeCount() {
        let primary = ConversationActivityNotice(
            conversationId: "conversation-1",
            title: "等待确认",
            kind: .awaitingUser,
            preview: "要继续吗？",
            occurredAt: Date(timeIntervalSince1970: 1)
        )
        let second = ConversationActivityNotice(
            conversationId: "conversation-2",
            title: "已经完成",
            kind: .completed,
            preview: "已写好。",
            occurredAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(
            ChatTopBarDockState.resolve(hasMessages: true, notices: [primary, second], artifactCount: 5),
            .satellite(notice: primary, extraCount: 1)
        )
    }

    func testSatelliteBadgeCapsAt99Plus() {
        XCTAssertEqual(ChatTopBarTrailingDock.badgeText(100), "99+")
    }
}
