import XCTest
@preconcurrency import Shared
@testable import iosApp

/// 对话入口与遗留路由的启动契约：两种布局的根都是聊天页，旧首页只在显式入口下被压入。
///
/// 覆盖用户实测的「启动先看到老首页，过一会才跳到对话页」：
/// - 有历史会话时，首帧所需的当前会话必须在 `bootstrap()` 返回时就绪（骨架随即让位给真实时线）；
/// - 无会话时根状态也必须是一个确定的空会话，而不是靠延迟 push 掩盖跳页。
@MainActor
final class ConversationEntryRoutingTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationEntryRouting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 已有可用会话：冷启动引导必须直接选中最近一条，让对话页首帧就有内容。
    func testColdStartWithHistorySelectsMostRecentConversation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let seed = IOSConversationStore(baseDirectory: directory)
        await seed.bootstrap()
        await seed.saveCurrent(messages: [UIMessage.companion.user(prompt: "较早的话题")])
        let olderID = try XCTUnwrap(seed.currentConversation?.id)

        await seed.newConversation()
        await seed.saveCurrent(messages: [UIMessage.companion.user(prompt: "最近的话题")])
        let newestID = try XCTUnwrap(seed.currentConversation?.id)
        XCTAssertNotEqual(olderID, newestID)

        // 模拟新进程：全新 store 的冷启动引导。
        let store = IOSConversationStore(baseDirectory: directory)
        XCTAssertFalse(store.isBootstrapped, "引导前不能假装首帧已就绪")
        await store.bootstrap()

        XCTAssertTrue(store.isBootstrapped)
        XCTAssertEqual(store.currentConversation?.id, newestID)
        XCTAssertFalse(store.summaries.isEmpty)
    }

    /// 无会话：引导结束后必须落在一个确定的空会话根状态，而不是等待页面跳转。
    func testColdStartWithoutHistoryReachesStableConversationRoot() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()

        XCTAssertTrue(store.isBootstrapped)
        XCTAssertNotNil(store.currentConversation)
        XCTAssertTrue(store.currentMessages.isEmpty)
    }

    /// 单一根路由真相：`.chat` 永远被根吸收，旧首页只能作为被压入的页面存在。
    func testHomeIsPushedAboveChatRootAndChatPopsBackToRoot() {
        let router = RouterPath()
        XCTAssertTrue(router.isShowingChat, "首帧根状态就是对话页")

        router.navigate(to: .home)
        XCTAssertEqual(router.path, [.home])
        XCTAssertFalse(router.isShowingChat)

        router.navigate(to: .chat)
        XCTAssertEqual(router.path, [])
        XCTAssertTrue(router.isShowingChat)

        router.navigate(to: .settings)
        router.navigate(to: .home)
        XCTAssertEqual(router.path, [.settings, .home])
        router.navigate(to: .chat)
        XCTAssertEqual(router.path, [], "回到对话根时一次清空整条遗留栈")
    }
}
