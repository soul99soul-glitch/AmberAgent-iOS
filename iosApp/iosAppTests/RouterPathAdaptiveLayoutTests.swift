import XCTest
@testable import iosApp

/// iPhone Duo 合上 / 展开时，RouterPath 在单栏栈与双栏（聊天为详情根）之间搬运路由。
@MainActor
final class RouterPathAdaptiveLayoutTests: XCTestCase {

    private func anchor() -> ChatMessageAnchor {
        ChatMessageAnchor(conversationID: "c1", messageID: "m1", toolCallID: "t1")
    }

    func testCompactLayoutKeepsChatOnStack() {
        let router = RouterPath()
        router.navigate(to: .chat)
        XCTAssertEqual(router.path, [.chat])
        XCTAssertTrue(router.isShowingChat)
    }

    func testUnfoldingAbsorbsChatRootAndKeepsPushedPages() {
        let router = RouterPath()
        router.path = [.chat, .settings]
        router.chatIsDetailRoot = true
        XCTAssertEqual(router.path, [.settings])
        XCTAssertFalse(router.isShowingChat)
    }

    func testFoldingRestoresChatUnderneath() {
        let router = RouterPath()
        router.chatIsDetailRoot = true
        router.path = [.settings]
        router.chatIsDetailRoot = false
        XCTAssertEqual(router.path, [.chat, .settings])
    }

    func testFoldingRestoresMessageAnchor() {
        let router = RouterPath()
        router.chatIsDetailRoot = true
        router.navigate(to: .chatMessage(anchor: anchor()))
        XCTAssertEqual(router.path, [])
        XCTAssertEqual(router.detailChatAnchor, anchor())
        router.chatIsDetailRoot = false
        XCTAssertEqual(router.path, [.chatMessage(anchor: anchor())])
    }

    func testSplitNavigateToChatPopsDetailStackInsteadOfPushing() {
        let router = RouterPath()
        router.chatIsDetailRoot = true
        router.path = [.settings, .appearance]
        router.navigate(to: .chat)
        XCTAssertEqual(router.path, [])
        XCTAssertTrue(router.isShowingChat)
    }

    func testSplitDeepLinkAssignmentDropsLeadingChat() {
        let router = RouterPath()
        router.chatIsDetailRoot = true
        router.path = [.chat]
        XCTAssertEqual(router.path, [])
        router.path = [.settings, .weather]
        XCTAssertEqual(router.path, [.settings, .weather])
    }

    func testSplitBackAtRootTogglesSidebar() {
        let router = RouterPath()
        router.chatIsDetailRoot = true
        XCTAssertTrue(router.showsSidebar)
        router.goBack()
        XCTAssertFalse(router.showsSidebar)
        router.goBack()
        XCTAssertTrue(router.showsSidebar)
    }

    func testCompactBackAtRootDoesNotTouchSidebar() {
        let router = RouterPath()
        router.goBack()
        XCTAssertTrue(router.showsSidebar)
        XCTAssertEqual(router.path, [])
    }

    func testOverlaySidebarCollapsesWhenConversationOpens() {
        let router = RouterPath()
        router.chatIsDetailRoot = true
        router.sidebarOverlaysDetail = true
        router.navigate(to: .chat)
        XCTAssertFalse(router.showsSidebar)
    }

    func testOverlaySidebarCollapsesForDeepLinkIntoChat() {
        let router = RouterPath()
        router.chatIsDetailRoot = true
        router.sidebarOverlaysDetail = true
        router.path = [.chat]
        XCTAssertFalse(router.showsSidebar)
    }

    func testOverlaySidebarKeepsOpenForNonChatDeepLink() {
        let router = RouterPath()
        router.chatIsDetailRoot = true
        router.sidebarOverlaysDetail = true
        router.path = [.settings, .weather]
        XCTAssertTrue(router.showsSidebar)
    }

    func testTiledSidebarStaysWhenConversationOpens() {
        let router = RouterPath()
        router.chatIsDetailRoot = true
        router.sidebarOverlaysDetail = false
        router.navigate(to: .chat)
        XCTAssertTrue(router.showsSidebar)
    }
}
