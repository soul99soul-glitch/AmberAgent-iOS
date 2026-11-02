import AppKit
import SwiftUI
import XCTest
@testable import AmberMac

final class DesktopConversationPresentationTests: XCTestCase {
    func testSummaryRemovesMarkdownSyntaxButPreservesCodeAndTableContent() {
        let text = """
        ## **结果**
        - [x] 阅读 [文档](https://example.com)
        > `snake_case` 与 *重点*
        | 方式 | 状态 |
        | --- | :---: |
        | 流式 | 完成 |
        ```swift
        let value = "a|b"
        ```
        """
        XCTAssertEqual(DesktopConversationPresentation.cleanSummary(text, limit: 200),
            "结果 阅读 文档 snake_case 与 重点 方式 状态 流式 完成 let value = \"a|b\"")
    }

    func testSummaryHandlesUnfinishedFenceWhitespaceAndCharacterLimit() {
        XCTAssertEqual(DesktopConversationPresentation.cleanSummary("~~~swift\n  let value = 1\n\nprint(value)"), "let value = 1 print(value)")
        XCTAssertEqual(DesktopConversationPresentation.cleanSummary(" \n\t "), "")
        XCTAssertEqual(DesktopConversationPresentation.cleanSummary("👨‍👩‍👧‍👦中文摘要", limit: 4), "👨‍👩‍👧‍👦中文…")
        XCTAssertEqual(DesktopConversationPresentation.cleanSummary("内容", limit: 0), "")
        XCTAssertEqual(DesktopConversationPresentation.cleanSummary("A | B 与 C:\\temp"), "A | B 与 C:\\temp")
    }

    func testWhitespaceQueryReturnsPinnedThenRecentWithStableTieBreak() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = DesktopConversation(id: firstID, title: "较早", updatedAt: Date(timeIntervalSince1970: 1))
        let second = DesktopConversation(id: secondID, title: "较新", updatedAt: Date(timeIntervalSince1970: 2))
        let pinned = DesktopConversation(title: "置顶", updatedAt: Date(timeIntervalSince1970: 0), isPinned: true)
        let results = DesktopConversationPresentation.search([first, second, pinned], query: " \n\t")
        XCTAssertEqual(results.map(\.conversationID), [pinned.id, second.id, first.id])
        XCTAssertTrue(results.allSatisfy { $0.kind == .recent && $0.messageID == nil && $0.matchRange == nil })
        let sameDate = DesktopConversation(id: secondID, title: "同时间", updatedAt: first.updatedAt)
        XCTAssertEqual(DesktopConversationPresentation.search([sameDate, first], query: "").map(\.conversationID), [firstID, secondID])
    }

    func testTitleMatchesSortBeforeMessageMatchesAndLatestMatchingMessageWins() throws {
        let older = DesktopMessage(role: .user, text: "最初的 Swift 内容")
        let latest = DesktopMessage(role: .assistant, text: "最新的 **SWIFT** 内容")
        let byMessage = DesktopConversation(title: "编程", updatedAt: Date(timeIntervalSince1970: 20), messages: [older, latest], isPinned: true)
        let byTitle = DesktopConversation(title: "swift 计划", updatedAt: Date(timeIntervalSince1970: 1))
        let results = DesktopConversationPresentation.search([byMessage, byTitle], query: "sWiFt")
        XCTAssertEqual(results.map(\.kind), [.title, .message])
        XCTAssertEqual(results.last?.messageID, latest.id)
        let result = try XCTUnwrap(results.last)
        XCTAssertEqual(String(result.snippet[try XCTUnwrap(result.matchRange)]), "SWIFT")
        XCTAssertEqual(result.messageCount, 2)
    }

    func testChineseEmojiAndNormalizedWhitespaceHighlightsUseSnippetStringIndices() throws {
        let message = DesktopMessage(role: .assistant, text: String(repeating: "前文👨‍👩‍👧‍👦", count: 20) + " 中文\n\t重点 " + String(repeating: "后文", count: 30))
        let conversation = DesktopConversation(title: "测试", messages: [message])
        let result = try XCTUnwrap(DesktopConversationPresentation.search([conversation], query: " 中文   重点 ", snippetLimit: 32).first)
        XCTAssertLessThanOrEqual(result.snippet.count, 32)
        XCTAssertEqual(String(result.snippet[try XCTUnwrap(result.matchRange)]), "中文 重点")
        XCTAssertTrue(result.snippet.hasPrefix("…"))
        XCTAssertTrue(result.snippet.hasSuffix("…"))
    }

    func testLongQueryProducesBoundedHighlightedSnippetAndSystemTextIsNotSearchable() throws {
        let query = String(repeating: "中文", count: 20)
        let conversation = DesktopConversation(title: "测试", messages: [
            DesktopMessage(role: .system, text: "系统秘密"),
            DesktopMessage(role: .user, text: "前文" + query + "后文")
        ])
        let result = try XCTUnwrap(DesktopConversationPresentation.search([conversation], query: query, snippetLimit: 12).first)
        XCTAssertLessThanOrEqual(result.snippet.count, 12)
        XCTAssertFalse(result.snippet[try XCTUnwrap(result.matchRange)].isEmpty)
        XCTAssertTrue(DesktopConversationPresentation.search([conversation], query: "系统秘密").isEmpty)
        XCTAssertEqual(result.messageCount, 2)
    }

    func testRecentSummarySkipsEmptyAndSystemMessages() {
        let conversation = DesktopConversation(messages: [
            DesktopMessage(role: .user, text: "## 保留 **内容**"),
            DesktopMessage(role: .assistant, text: " \n "),
            DesktopMessage(role: .system, text: "不展示的系统消息")
        ])
        XCTAssertEqual(DesktopConversationPresentation.summary(for: conversation), "保留 内容")
        XCTAssertEqual(DesktopConversationPresentation.summary(for: DesktopConversation()), "还没有消息")
    }

    func testLiquidMotionTransformAndReduceMotionBranches() {
        // 1. Short resting state (inspector expanded -> extensionProgress = 0.0):
        let shortRest = DesktopLiquidMotion.toolbarCapsuleTransform(extensionProgress: 0.0, extraItemCount: 5, reduceMotion: false)
        XCTAssertEqual(shortRest, .init(
            width: 80.0, baseHeight: 32.0, scaleY: 1.0, waistPinch: 0.0, cornerRadius: 16.0, specularOpacity: 0.0
        ))

        // 2. Long resting state (inspector collapsed -> extensionProgress = 1.0):
        let longRest = DesktopLiquidMotion.toolbarCapsuleTransform(extensionProgress: 1.0, extraItemCount: 5, reduceMotion: false)
        XCTAssertEqual(longRest, .init(
            width: 260.0, baseHeight: 32.0, scaleY: 1.0, waistPinch: 0.0, cornerRadius: 16.0, specularOpacity: 0.0
        ))

        // 3. Mid-stretch / mid-contraction (extensionProgress = 0.50):
        // Width is halfway (170pt), vertical height pinches thinner (scaleY < 0.88) with concave liquid waist (waistPinch > 0.18).
        let midMorph = DesktopLiquidMotion.toolbarCapsuleTransform(extensionProgress: 0.50, extraItemCount: 5, reduceMotion: false)
        XCTAssertEqual(midMorph.width, 170.0, accuracy: 0.5)
        XCTAssertLessThan(midMorph.scaleY, 0.88)
        XCTAssertGreaterThan(midMorph.waistPinch, 0.18)
        XCTAssertGreaterThan(midMorph.specularOpacity, 0.80)

        // 4. Lengthening overshoot (extensionProgress = 1.12, when inspector collapses and top bar stretches past longRest):
        let longOvershoot = DesktopLiquidMotion.toolbarCapsuleTransform(extensionProgress: 1.12, extraItemCount: 5, reduceMotion: false)
        XCTAssertGreaterThan(longOvershoot.width, 275.0)
        XCTAssertGreaterThan(longOvershoot.scaleY, 1.08)
        XCTAssertLessThan(longOvershoot.waistPinch, -0.05)

        // 5. Shortening overshoot (extensionProgress = -0.12, when inspector expands and top bar slams short with vertical Q-弹 bulge):
        let shortOvershoot = DesktopLiquidMotion.toolbarCapsuleTransform(extensionProgress: -0.12, extraItemCount: 5, reduceMotion: false)
        XCTAssertLessThan(shortOvershoot.width, 66.0)
        XCTAssertGreaterThan(shortOvershoot.scaleY, 1.12)
        XCTAssertLessThan(shortOvershoot.waistPinch, -0.08)

        // 6. Toolbar icons maintain uniform 1:1 scale (never non-uniformly stretched) and stagger from trailing to leading:
        let trailingIconMid = DesktopLiquidMotion.toolbarItemTransform(index: 4, totalCount: 5, extensionProgress: 0.35, reduceMotion: false)
        let leadingIconMid = DesktopLiquidMotion.toolbarItemTransform(index: 0, totalCount: 5, extensionProgress: 0.35, reduceMotion: false)
        XCTAssertGreaterThan(trailingIconMid.opacity, leadingIconMid.opacity)
        XCTAssertGreaterThan(trailingIconMid.scale, leadingIconMid.scale)

        // 7. Reduce Motion disables overshoot, vertical squash/bulge, concave waist necking, and specular flash:
        let reducedMid = DesktopLiquidMotion.toolbarCapsuleTransform(extensionProgress: 0.50, extraItemCount: 5, reduceMotion: true)
        XCTAssertEqual(reducedMid.width, 170.0, accuracy: 0.001)
        XCTAssertEqual(reducedMid.scaleY, 1.0, accuracy: 0.001)
        XCTAssertEqual(reducedMid.waistPinch, 0.0, accuracy: 0.001)
        XCTAssertEqual(reducedMid.specularOpacity, 0.0, accuracy: 0.001)
    }
}
