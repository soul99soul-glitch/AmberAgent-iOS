import XCTest
@testable import iosApp

/// 单栏 / 双栏（iPhone Duo 合上、展开）之间搬运路由：两种布局的根都是聊天页，
/// 路径里只保留被 push 的页面，`.chat` / `.chatMessage` 永远被根吸收。
@MainActor
final class RouterPathAdaptiveLayoutTests: XCTestCase {

    private func anchor() -> ChatMessageAnchor {
        ChatMessageAnchor(conversationID: "c1", messageID: "m1", toolCallID: "t1")
    }

    func testCompactRootKeepsChatAndNeverStacksIt() {
        let router = RouterPath()
        router.navigate(to: .chat)
        XCTAssertEqual(router.path, [])
        XCTAssertTrue(router.isShowingChat)
    }

    func testPushedPagesStayAboveChatRoot() {
        let router = RouterPath()
        router.path = [.chat, .settings]
        XCTAssertEqual(router.path, [.settings])
        XCTAssertFalse(router.isShowingChat)
    }

    func testNavigateToChatPopsPushedPagesInsteadOfPushing() {
        let router = RouterPath()
        router.path = [.settings, .appearance]
        router.navigate(to: .chat)
        XCTAssertEqual(router.path, [])
        XCTAssertTrue(router.isShowingChat)
    }

    func testChatMessageRouteIsAbsorbedIntoRootAnchor() {
        let router = RouterPath()
        router.navigate(to: .chatMessage(anchor: anchor()))
        XCTAssertEqual(router.path, [])
        XCTAssertEqual(router.detailChatAnchor, anchor())
    }

    func testDeepLinkAssignmentDropsLeadingChat() {
        let router = RouterPath()
        router.path = [.chat]
        XCTAssertEqual(router.path, [])
        router.path = [.settings, .weather]
        XCTAssertEqual(router.path, [.settings, .weather])
    }

    func testSplitBackAtRootTogglesSidebar() {
        let router = RouterPath()
        router.showsSidebarControl = true
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
        router.sidebarOverlaysDetail = true
        router.navigate(to: .chat)
        XCTAssertFalse(router.showsSidebar)
    }

    func testOverlaySidebarCollapsesForDeepLinkIntoChat() {
        let router = RouterPath()
        router.sidebarOverlaysDetail = true
        router.path = [.chat]
        XCTAssertFalse(router.showsSidebar)
    }

    func testOverlaySidebarKeepsOpenForNonChatDeepLink() {
        let router = RouterPath()
        router.sidebarOverlaysDetail = true
        router.path = [.settings, .weather]
        XCTAssertTrue(router.showsSidebar)
    }

    func testTiledSidebarStaysWhenConversationOpens() {
        let router = RouterPath()
        router.sidebarOverlaysDetail = false
        router.navigate(to: .chat)
        XCTAssertTrue(router.showsSidebar)
    }
}
