import SwiftUI
import UIKit
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ConversationArtifactIndexTests: XCTestCase {
    func testGeneratedImagesKeepPromptAndExcludeUserUploads() {
        let userImage = UIMessagePart.Image(url: "file:///user-upload.png", metadata: nil)
        let user = userMessage(parts: [UIMessagePart.Text(text: "参考这张图", metadata: nil), userImage])
        let generated = toolMessage(
            id: "image-call",
            name: "generate_image",
            input: #"{"prompt":"A quiet garden"}"#,
            output: [UIMessagePart.Image(url: "https://images.example/generated.png", metadata: nil)]
        )

        let index = ConversationArtifactIndex.make(from: [user, generated])

        XCTAssertEqual(index.images.count, 1)
        XCTAssertEqual(index.images[0].url, "https://images.example/generated.png")
        XCTAssertEqual(index.images[0].prompt, "A quiet garden")
        XCTAssertEqual(index.images[0].source.turn, 1)
        XCTAssertEqual(index.images[0].source.toolCallID, "image-call")
        XCTAssertEqual(index.count, 1)
    }

    func testIndexesMarkdownImagesWithoutPromotingLinksOrCode() throws {
        let text = """
        ![坐像](https://images.example/one.jpg)

        [![半身像](https://images.example/two.jpg)](https://museum.example/item)

        ![册页][portrait]

        [portrait]: https://images.example/three.jpg

        [普通链接](https://images.example/link.jpg)
        `![代码](https://images.example/inline.jpg)`
        ```markdown
        ![代码块](https://images.example/fenced.jpg)
        ```
        ![未完成](https://images.example/incomplete.jpg
        """
        let assistant = message(role: .assistant, parts: [UIMessagePart.Text(text: text, metadata: nil)])
        var settings = IOSGenerativeWidgetSettings()
        settings.enabled = false
        let index = ConversationArtifactIndex.make(from: [userMessage(), assistant], widgetSettings: settings)
        XCTAssertEqual(index.images.map(\.url), [
            "https://images.example/one.jpg", "https://images.example/two.jpg", "https://images.example/three.jpg"
        ])
        XCTAssertEqual(index.images.map(\.prompt), ["坐像", "半身像", "册页"])
        let image = try XCTUnwrap(index.images.first)
        XCTAssertNil(image.source.toolCallID)
        XCTAssertNotNil(ConversationArtifactIndex.anchor(for: image.source, conversationID: "c", messages: [assistant]))
        XCTAssertNil(ConversationArtifactIndex.anchor(for: image.source, conversationID: "c", messages: []))
    }

    func testIndexesAssistantAndSearchImagesOnceWithStableIdentity() throws {
        let url = "https://images.example/portrait.jpg"
        let search = toolMessage(id: "search", name: "search", input: "{}", output: [
            IosToolOutputJsonBridge.shared.mergeTextMetadata(part: UIMessagePart.Text(text: "search result", metadata: nil), updates: [
                "app.amber.media.images": #"[{"id":"search-portrait","url":"https://images.example/portrait.jpg","title":"馆藏画像"}]"#
            ])
        ])
        let assistant = message(role: .assistant, parts: [
            UIMessagePart.Text(text: "![同一张](\(url))", metadata: nil),
            UIMessagePart.Image(url: "file:///assistant.png", metadata: nil)
        ])
        let index = ConversationArtifactIndex.make(from: [userMessage(), search, assistant])
        XCTAssertEqual(index.images.map(\.url), [url, "file:///assistant.png"])
        let first = try XCTUnwrap(index.images.first)
        XCTAssertEqual(first.prompt, "馆藏画像")
        XCTAssertEqual(first.source.toolCallID, "search")
        XCTAssertNotNil(ConversationArtifactIndex.anchor(for: first.source, conversationID: "c", messages: [search]))
        let markdownOnly = ConversationArtifactIndex.make(from: [assistant])
        XCTAssertEqual(markdownOnly.images.first?.id, first.id)
        XCTAssertTrue(ConversationArtifactIndex.make(from: []).images.isEmpty)
    }

    func testGroupsFileWritesAndEditsAsVersionsWithAvailableContent() {
        let user = userMessage()
        let write = toolMessage(
            id: "write-call",
            name: "workspace_file_write",
            input: #"{"path":"notes.md","content":"alpha"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/notes.md","size_bytes":5}"#
        )
        let secondWrite = toolMessage(
            id: "write-again",
            name: "workspace_file_write",
            input: #"{"path":"notes.md","content":"alpha\nextra"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/notes.md","size_bytes":11}"#
        )
        let edit = toolMessage(
            id: "edit-call",
            name: "workspace_file_edit",
            input: #"{"path":"/workspace/notes.md","find":"alpha","replace":"beta"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/notes.md","changed":true,"replacements":1,"diff_preview":"-alpha\n+beta"}"#
        )

        let index = ConversationArtifactIndex.make(from: [user, write, secondWrite, userMessage(text: "再修改"), edit])

        XCTAssertEqual(index.files.count, 1)
        XCTAssertEqual(index.files[0].path, "notes.md")
        // edit 回执没有完整正文，即便有旧快照也不能猜测执行时的文件内容。
        XCTAssertEqual(index.files[0].versions.map(\.content), ["alpha", "alpha\nextra", nil])
        XCTAssertEqual(index.files[0].versions.map(\.source.toolCallID), ["write-call", "write-again", "edit-call"])
        XCTAssertEqual(index.files[0].versions.map(\.source.turn), [1, 1, 2])
        XCTAssertEqual(index.count, 1, "多版本文件仍算一个产物")
    }

    func testIndexesScrapeAndWebMountPagesFromTheirStructuredResults() {
        let user = userMessage()
        let scrape = toolMessage(
            id: "scrape-call",
            name: "scrape_web",
            input: #"{"url":"https://example.com/article?id=123"}"#,
            outputJSON: #"{"status":"ok","url":"https://example.com/article?id=123","title":"Article","content":"Readable article text"}"#
        )
        let webMount = toolMessage(
            id: "open-call",
            name: "wm_open",
            input: #"{"session_id":"session-1"}"#,
            outputJSON: #"{"ok":true,"page":{"url":"https://example.com/page","title":"Mounted page"},"visible_text":"Visible page text"}"#
        )

        let index = ConversationArtifactIndex.make(from: [user, scrape, webMount])

        XCTAssertEqual(index.webPages.map(\.title), ["Article", "Mounted page"])
        XCTAssertEqual(index.webPages.map(\.url), ["https://example.com/article?id=123", "https://example.com/page"])
        XCTAssertEqual(index.webPages.map(\.preview), ["Readable article text", "Visible page text"])
        XCTAssertEqual(index.webPageGroups.count, 1)
        XCTAssertEqual(index.count, 1, "同轮检索与打开的多个网页归为一个检索轮次组")
    }

    func testWebMountSessionCallsDeduplicateByURLAndKeepLatestSource() throws {
        let open = toolMessage(
            id: "call_0",
            name: "wm_open",
            input: "{}",
            outputJSON: #"{"ok":true,"page":{"url":"https://example.com/page","title":"Opened"},"visible_text":"Open text"}"#
        )
        let extract = toolMessage(
            id: "call_0",
            name: "wm_extract",
            input: "{}",
            outputJSON: #"{"ok":true,"page":{"url":"https://example.com/page","title":"Extracted"},"visible_text":"Latest text"}"#
        )
        let ignoredCalls = ["wm_state", "wm_observe", "wm_back", "wm_forward", "wm_get"].enumerated().map { index, name in
            toolMessage(
                id: "ignored-\(index)",
                name: name,
                input: "{}",
                outputJSON: #"{"ok":true,"page":{"url":"https://example.com/\#(index)","title":"Transient state"}}"#
            )
        }

        let index = ConversationArtifactIndex.make(from: [open, extract] + ignoredCalls)
        let page = try XCTUnwrap(index.webPages.first)

        XCTAssertEqual(index.webPages.count, 1)
        XCTAssertEqual(page.id, "web:https://example.com/page")
        XCTAssertEqual(page.title, "Extracted")
        XCTAssertEqual(page.preview, "Latest text")
        XCTAssertEqual(page.source.toolCallID, "call_0")
        XCTAssertEqual(page.source.messageID, ChatMessageProjector.messageId(for: extract))
    }

    func testWriteContentIsKeptOnlyWhenReceiptByteCountMatches() throws {
        let matching = toolMessage(
            id: "matching-write",
            name: "workspace_file_write",
            input: #"{"path":"matching.txt","content":"café"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/matching.txt","size_bytes":5}"#
        )
        let mismatched = toolMessage(
            id: "mismatched-write",
            name: "workspace_file_write",
            input: #"{"path":"mismatched.txt","content":"same length?"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/mismatched.txt","size_bytes":1}"#
        )
        let missingSize = toolMessage(
            id: "missing-size-write",
            name: "workspace_file_write",
            input: #"{"path":"missing-size.txt","content":"content"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/missing-size.txt"}"#
        )

        let index = ConversationArtifactIndex.make(from: [matching, mismatched, missingSize])

        XCTAssertEqual(index.files.first(where: { $0.path == "matching.txt" })?.versions.first?.content, "café")
        XCTAssertNil(index.files.first(where: { $0.path == "mismatched.txt" })?.versions.first?.content)
        XCTAssertNil(index.files.first(where: { $0.path == "missing-size.txt" })?.versions.first?.content)
    }

    func testReusedToolCallIDInDifferentMessagesKeepsBothArtifacts() {
        let first = toolMessage(
            id: "call_0",
            name: "generate_image",
            input: "{}",
            output: [UIMessagePart.Image(url: "image://first", metadata: nil)]
        )
        let second = toolMessage(
            id: "call_0",
            name: "generate_image",
            input: "{}",
            output: [UIMessagePart.Image(url: "image://second", metadata: nil)]
        )

        let index = ConversationArtifactIndex.make(from: [first, second])

        XCTAssertEqual(index.images.map(\.url), ["image://first", "image://second"])
        XCTAssertNotEqual(index.images[0].source.messageID, index.images[1].source.messageID)
    }

    func testEditWithoutKnownContentKeepsVersionButDoesNotUseDiffPreviewAsText() {
        let edit = toolMessage(
            id: "edit-without-base",
            name: "workspace_file_edit",
            input: #"{"path":"notes.md","find":"before","replace":"after"}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/notes.md","changed":true,"replacements":1,"diff_preview":"-before\n+after"}"#
        )

        let index = ConversationArtifactIndex.make(from: [userMessage(), edit])

        XCTAssertEqual(index.files.first?.versions.count, 1)
        XCTAssertNil(index.files.first?.versions.first?.content)
        XCTAssertEqual(index.count, 1)
    }

    func testIndexesOnlyMessagesFromTheProvidedCurrentBranch() {
        let branchA = [
            userMessage(text: "分支 A"),
            toolMessage(
                id: "a-call",
                name: "workspace_file_write",
                input: #"{"path":"a.md","content":"A"}"#,
                outputJSON: #"{"ok":true,"path":"/workspace/a.md"}"#
            )
        ]
        let branchB = [
            userMessage(text: "分支 B"),
            toolMessage(
                id: "b-call",
                name: "workspace_file_write",
                input: #"{"path":"b.md","content":"B"}"#,
                outputJSON: #"{"ok":true,"path":"/workspace/b.md"}"#
            )
        ]

        let indexA = ConversationArtifactIndex.make(from: branchA)
        let indexB = ConversationArtifactIndex.make(from: branchB)

        XCTAssertEqual(indexA.files.map(\.path), ["a.md"])
        XCTAssertEqual(indexB.files.map(\.path), ["b.md"])
    }

    func testNoArtifactsAndUnsuccessfulWritesProduceAnEmptyIndex() {
        let messages = [
            userMessage(parts: [UIMessagePart.Image(url: "file:///user.png", metadata: nil)]),
            toolMessage(id: "search-call", name: "search_web", input: "{}", outputJSON: #"{"ok":true}"#),
            toolMessage(
                id: "failed-write",
                name: "workspace_file_write",
                input: #"{"path":"failed.md","content":"no"}"#,
                outputJSON: #"{"ok":false,"error":"denied"}"#
            )
        ]

        let index = ConversationArtifactIndex.make(from: messages)

        XCTAssertTrue(index.images.isEmpty)
        XCTAssertTrue(index.files.isEmpty)
        XCTAssertTrue(index.webPages.isEmpty)
        XCTAssertEqual(index.count, 0)
    }

    func testAnchorRequiresBothMessageAndToolToRemainInCurrentBranch() throws {
        let message = toolMessage(
            id: "anchor-call",
            name: "generate_image",
            input: "{}",
            output: [UIMessagePart.Image(url: "image://result", metadata: nil)]
        )
        let source = try XCTUnwrap(ConversationArtifactIndex.make(from: [message]).images.first?.source)

        let anchor = ConversationArtifactIndex.anchor(
            for: source,
            conversationID: "conversation-1",
            messages: [message],
            requestToken: UUID()
        )

        XCTAssertEqual(anchor?.conversationID, "conversation-1")
        XCTAssertEqual(anchor?.messageID, source.messageID)
        XCTAssertEqual(anchor?.toolCallID, source.toolCallID)
        XCTAssertNil(ConversationArtifactIndex.anchor(
            for: .init(messageID: source.messageID, turn: 1, toolCallID: "missing-tool"),
            conversationID: "conversation-1",
            messages: [message]
        ))
        XCTAssertNil(ConversationArtifactIndex.anchor(
            for: .init(messageID: "missing-message", turn: 1, toolCallID: source.toolCallID),
            conversationID: "conversation-1",
            messages: [message]
        ))
    }

    func testIndexesGenerativeHtmlAndMiniAppsFromAssistantMessages() throws {
        let deckHTML = #"<!DOCTYPE html><html><body><canvas id="saturn"></canvas></body></html>"#
        let widgetText = """
        来了——土星 · 环之帝国。
        ```show-widget
        {"title":"土星 · 环之帝国","renderer":"full_html","spec":{"html":\(jsonLiteral(deckHTML))}}
        ```
        环的视觉是怎么堆出来的：
        ```show-widget
        {"title":"环系结构","widget_code":"<svg viewBox=\\"0 0 680 240\\"><text x=\\"24\\" y=\\"48\\">C 环、B 环、卡西尼缝、A 环、恩克缝与 F 环</text></svg>"}
        ```
        """
        let user = userMessage(text: "做一个 three.js 土星")
        let widgets = message(role: MessageRole.assistant, parts: [UIMessagePart.Text(text: widgetText, metadata: nil)])
        let miniApp = message(role: MessageRole.assistant, parts: [UIMessagePart.MiniApp(
            appId: "app-avg", title: "雨夜侦探 AVG", description: "文字冒险",
            iconEmoji: "🕵️", category: "game", permissions: [], htmlHash: "h1", version: 2, metadata: nil
        )])
        // 用户自己粘贴的 HTML 不是产物。
        let pasted = userMessage(text: widgetText)

        let index = ConversationArtifactIndex.make(from: [user, widgets, pasted, miniApp])

        XCTAssertEqual(index.htmlPages.map(\.title), ["土星 · 环之帝国", "环系结构", "雨夜侦探 AVG"])
        XCTAssertEqual(index.htmlPages.map(\.source.turn), [1, 1, 2])
        XCTAssertEqual(Set(index.htmlPages.map(\.id)).count, 3)
        let deck = try XCTUnwrap(index.htmlPages.first?.widget)
        XCTAssertEqual(deck.renderer, IOSGuizangHtmlDeckValidator.renderer)
        XCTAssertEqual(index.htmlPages[0].exportHTML, deckHTML)
        XCTAssertEqual(index.htmlPages[2].miniAppID, "app-avg")
        XCTAssertNil(index.htmlPages[2].exportHTML)
        XCTAssertEqual(index.count, 3)

        var disabledSettings = IOSGenerativeWidgetSettings()
        disabledSettings.enabled = false
        let disabled = ConversationArtifactIndex.make(from: [user, widgets, miniApp], widgetSettings: disabledSettings)
        XCTAssertEqual(disabled.htmlPages.map(\.title), ["雨夜侦探 AVG"])

        // 修改后的小程序沿用同一 appId，只保留最新卡片。
        let revised = message(role: MessageRole.assistant, parts: [UIMessagePart.MiniApp(
            appId: "app-avg", title: "雨夜侦探 AVG（加长版）", description: "",
            iconEmoji: nil, category: "game", permissions: [], htmlHash: "h2", version: 3, metadata: nil
        )])
        let revisedIndex = ConversationArtifactIndex.make(from: [user, miniApp, userMessage(text: "再长一点"), revised])
        XCTAssertEqual(revisedIndex.htmlPages.map(\.title), ["雨夜侦探 AVG（加长版）"])
        XCTAssertEqual(revisedIndex.htmlPages.first?.source.turn, 2)
    }

    func testSkipsWidgetsTheChatCardCannotOpenAndExportsStandaloneHTML() throws {
        // 超过 maxWidgetCodeChars 的卡片在气泡里退化为代码块，不算产物。
        let oversized = String(repeating: "环", count: IOSGenerativeWidgetSettings().maxWidgetCodeChars + 10)
        let text = """
        ```show-widget
        {"title":"太大","widget_code":"<div>\(oversized)</div>"}
        ```
        ```show-widget
        {"title":"小卡片","widget_code":"<div><h3>土星环</h3><p>C 环、B 环、卡西尼缝、A 环与 F 环的结构示意</p></div>"}
        ```
        """
        let assistant = message(role: MessageRole.assistant, parts: [UIMessagePart.Text(text: text, metadata: nil)])

        let index = ConversationArtifactIndex.make(from: [userMessage(), assistant])

        XCTAssertEqual(index.htmlPages.map(\.title), ["小卡片"])
        let html = try XCTUnwrap(index.htmlPages.first?.exportHTML)
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains(#"<meta charset="utf-8">"#))
        XCTAssertTrue(html.contains("<h3>土星环</h3>"))
    }

    func testWidgetCacheReusesParsedMessagesAndDropsStaleEntries() {
        let cache = ConversationArtifactContentCache()
        let settings = IOSGenerativeWidgetSettings()
        var computeCount = 0
        let widget = IOSGenerativeWidget(id: "w", title: "T", widgetCode: "<div>x</div>", complete: true)
        func lookup(_ text: String) -> [IOSGenerativeWidget] {
            cache.widgets(key: "m:0", text: text, settings: settings) {
                computeCount += 1
                return [widget]
            }
        }

        _ = lookup("a"); cache.prune()
        _ = lookup("a"); cache.prune()
        XCTAssertEqual(computeCount, 1, "正文未变不重解析")
        _ = lookup("ab"); cache.prune()
        XCTAssertEqual(computeCount, 2, "正文变化重解析")
        cache.prune()
        _ = lookup("ab")
        XCTAssertEqual(computeCount, 3, "未访问的条目在 prune 时被淘汰")
    }

    func testImageCacheReusesTextAndDropsChangedOrStaleEntries() {
        let cache = ConversationArtifactContentCache()
        var computeCount = 0
        func lookup(_ text: String) -> [ChatMediaItem] {
            cache.images(key: "message:0", text: text) {
                computeCount += 1
                return [ChatMediaItem(id: text, url: text)]
            }
        }
        XCTAssertEqual(lookup("one").first?.url, "one")
        cache.prune()
        _ = lookup("one")
        cache.prune()
        XCTAssertEqual(computeCount, 1)
        XCTAssertEqual(lookup("two").first?.url, "two")
        cache.prune()
        XCTAssertEqual(computeCount, 2)
        cache.prune()
        _ = lookup("two")
        XCTAssertEqual(computeCount, 3)
    }

    func testExportInlinesBundledFullHtmlRuntime() {
        let html = #"<!DOCTYPE html><html><body><script src="https://amberagent.local/full-html/three.min.js"></script><script>new THREE.Scene()</script></body></html>"#

        let exported = ChatArtifactShelfExporter.inliningLocalRuntimes(in: html)

        XCTAssertFalse(exported.contains("amberagent.local"))
        XCTAssertGreaterThan(exported.utf8.count, 100_000, "three.min.js 已内联")
        XCTAssertTrue(exported.hasSuffix("<script>new THREE.Scene()</script></body></html>"))
    }

    func testMessageOnlySourceAnchorsWhileMessageRemainsInBranch() throws {
        let assistant = message(role: MessageRole.assistant, parts: [UIMessagePart.MiniApp(
            appId: "app", title: "计时器", description: "", iconEmoji: nil, category: nil,
            permissions: [], htmlHash: nil, version: 1, metadata: nil
        )])
        let source = try XCTUnwrap(ConversationArtifactIndex.make(from: [assistant]).htmlPages.first?.source)
        XCTAssertNil(source.toolCallID)

        let anchor = ConversationArtifactIndex.anchor(for: source, conversationID: "c", messages: [assistant])
        XCTAssertEqual(anchor?.messageID, source.messageID)
        XCTAssertNil(anchor?.toolCallID)
        XCTAssertNil(ConversationArtifactIndex.anchor(for: source, conversationID: "c", messages: []))
    }

    func testMultiTurnWebSearchDeduplicatesCanonicalItemsGroupsByTurnAndPreservesDeliverablesAt54PlusScale() async throws {
        var messages: [UIMessage] = []

        // Turn 1: 20 scraped web pages (item-0 .. item-19) + 1 image with tracking/fragment query.
        messages.append(userMessage(text: "第 1 轮：检索第一批架构资料"))
        for idx in 0..<20 {
            let rawURL = idx == 0
                ? "https://Example.com/research/item-0/?utm_source=search&b=2&a=1#overview"
                : "https://example.com/research/item-\(idx)?utm_medium=organic#section-\(idx)"
            messages.append(toolMessage(
                id: "t1-scrape-\(idx)",
                name: "scrape_web",
                input: #"{"url":"\#(rawURL)"}"#,
                outputJSON: #"{"status":"ok","url":"\#(rawURL)","title":"资料条目 \#(idx)","content":"第 1 轮脱敏摘要 \#(idx)"}"#
            ))
        }
        messages.append(message(
            role: .assistant,
            parts: [UIMessagePart.Text(
                text: "![架构图](https://Images.Example.com/diagrams/arch.png?utm_campaign=v1#hero)",
                metadata: nil
            )]
        ))

        // Turn 2: re-scrapes item-0 with different scheme/port/query-order/tracking (canonical duplicate),
        // plus 19 new pages (item-20 .. item-38), and writes a deliverable file.
        messages.append(userMessage(text: "第 2 轮：补充核查并生成报告文件"))
        let duplicateItem0URL = "http://example.com:80/research/item-0?a=1&b=2&spm=1001.20"
        messages.append(toolMessage(
            id: "t2-scrape-dup-0",
            name: "scrape_web",
            input: #"{"url":"\#(duplicateItem0URL)"}"#,
            outputJSON: #"{"status":"ok","url":"\#(duplicateItem0URL)","title":"资料条目 0（二次核对）","content":""}"#
        ))
        for idx in 20..<39 {
            let rawURL = "https://example.com/research/item-\(idx)/"
            messages.append(toolMessage(
                id: "t2-scrape-\(idx)",
                name: "scrape_web",
                input: #"{"url":"\#(rawURL)"}"#,
                outputJSON: #"{"status":"ok","url":"\#(rawURL)","title":"资料条目 \#(idx)","content":"第 2 轮脱敏摘要 \#(idx)"}"#
            ))
        }
        let reportContent = "# 最终核查报告\n\n这是用户显式要求生成的真实文件成果。"
        messages.append(toolMessage(
            id: "t2-write-report",
            name: "workspace_file_write",
            input: #"{"path":"reports/final-deliverable.md","content":\#(jsonLiteral(reportContent))}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/reports/final-deliverable.md","size_bytes":\#(reportContent.utf8.count)}"#
        ))

        // Turn 3: re-opens item-20 via wm_open with port/fragment/trailing-slash (canonical duplicate),
        // plus 15 new pages (item-39 .. item-53), repeats the same image URL and identical file write,
        // and user pins a key conclusion snippet.
        messages.append(userMessage(text: "第 3 轮：深读剩余页面并沉淀结论"))
        messages.append(toolMessage(
            id: "t3-wm-dup-20",
            name: "wm_open",
            input: "{}",
            outputJSON: #"{"ok":true,"page":{"url":"https://EXAMPLE.COM:443/research/item-20/#part2","title":"资料条目 20（深读）"},"visible_text":"第 3 轮深读正文 20"}"#
        ))
        for idx in 39..<54 {
            let rawURL = "https://example.com/research/item-\(idx)?from=timeline"
            messages.append(toolMessage(
                id: "t3-scrape-\(idx)",
                name: "scrape_web",
                input: #"{"url":"\#(rawURL)"}"#,
                outputJSON: #"{"status":"ok","url":"\#(rawURL)","title":"资料条目 \#(idx)","content":"第 3 轮脱敏摘要 \#(idx)"}"#
            ))
        }
        messages.append(toolMessage(
            id: "t3-write-report-identical",
            name: "workspace_file_write",
            input: #"{"path":"/workspace/reports/final-deliverable.md","content":\#(jsonLiteral(reportContent))}"#,
            outputJSON: #"{"ok":true,"path":"/workspace/reports/final-deliverable.md","size_bytes":\#(reportContent.utf8.count)}"#
        ))
        let finalAssistant = message(
            role: .assistant,
            parts: [UIMessagePart.Text(
                text: "已完成全部 54 篇资料核对，核心结论如下。\n\n![架构图复核](https://images.example.com/diagrams/arch.png)",
                metadata: nil
            )]
        )
        messages.append(finalAssistant)

        let index = ConversationArtifactIndex.make(from: messages)

        // 1. Canonical deduplication: 56 raw web calls -> 54 unique logical webPages;
        //    2 canonical-equivalent images -> 1 image; 2 identical file writes -> 1 file version.
        XCTAssertEqual(index.webPages.count, 54, "同规范 URL 跨轮检索必须去重为单个逻辑网页项")
        let item0 = try XCTUnwrap(index.webPages.first { $0.url == "https://example.com/research/item-0?a=1&b=2" })
        XCTAssertEqual(item0.title, "资料条目 0（二次核对）")
        XCTAssertEqual(item0.preview, "第 1 轮脱敏摘要 0", "后一轮未返回摘要时应保留已提取的摘要内容")
        XCTAssertEqual(item0.source.turn, 2)

        let item20 = try XCTUnwrap(index.webPages.first { $0.url == "https://example.com/research/item-20" })
        XCTAssertEqual(item20.title, "资料条目 20（深读）")
        XCTAssertEqual(item20.source.turn, 3)

        XCTAssertEqual(index.images.count, 1, "同一规范 URL 的图片跨轮出现只保留一项")
        XCTAssertEqual(index.files.count, 1)
        XCTAssertEqual(index.files[0].versions.count, 1, "完全相同内容的重复写入不产生冗余文件版本")

        // 2. Turn grouping & shelf count: 54 web pages across 3 turns group into 3 turn groups (newest turn first).
        XCTAssertEqual(index.webPageGroups.map(\.turn), [3, 2, 1])
        XCTAssertEqual(index.webPageGroups.map { $0.pages.count }, [16, 19, 19])
        XCTAssertEqual(
            index.count,
            5,
            "产物架顶栏与标题计数应按逻辑成果计（1 图 + 1 文件 + 3 个检索轮次组 = 5），不能被 54 条原始检索链接撑到 56+"
        )

        // 3. Default collapsed old/raw web groups & on-demand expand access.
        XCTAssertTrue(
            ChatArtifactShelfPanel.visibleWebPages(in: index, expandedTurns: []).isEmpty,
            "多轮/多条检索网页默认收起为轮次组卡片，不默认平铺展开 54 条原始链接"
        )
        let expandedTurn1Pages = ChatArtifactShelfPanel.visibleWebPages(in: index, expandedTurns: [1])
        XCTAssertEqual(expandedTurn1Pages.count, 19, "展开旧轮次（第 1 轮）后可完整访问该轮保留的 19 条网页来源")
        for page in expandedTurn1Pages {
            let anchor = ConversationArtifactIndex.anchor(
                for: page.source,
                conversationID: "conv-54",
                messages: messages
            )
            XCTAssertNotNil(anchor, "展开后的每条旧轮次网页来源都必须能定位回原消息与 toolCallID")
            XCTAssertEqual(page.source.turn, 1)
        }

        // 4. Explicit user pins & real deliverables preserved; selection/delete/report/scroll work in 54+ scenario.
        let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("Shelf54-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = IOSConversationArtifactStore(fileURL: storeDir.appendingPathComponent("shelf.json"))
        let pinned = try XCTUnwrap(ChatArtifactPinning.snippet(
            messageID: ChatMessageProjector.messageId(for: finalAssistant),
            text: "已完成全部 54 篇资料核对，核心结论如下。",
            kind: .message,
            messages: messages
        ))
        try store.pin(pinned, for: "conv-54")
        XCTAssertEqual(ChatArtifactPinning.visibleSnippets(store.snippets(for: "conv-54"), messages: messages), [pinned])

        let report = ChatArtifactActions.reportMarkdown(
            title: "检索综述",
            index: index,
            snippets: store.snippets(for: "conv-54"),
            adoptedVersions: [:],
            selectedIDs: [
                ChatArtifactActions.selectionID(for: index.files[0]),
                ChatArtifactActions.selectionID(for: pinned),
                ChatArtifactActions.selectionID(for: item20)
            ]
        )
        XCTAssertTrue(report.contains("reports/final-deliverable.md"))
        XCTAssertTrue(report.contains("已完成全部 54 篇资料核对"))
        XCTAssertTrue(report.contains("https://example.com/research/item-20"))
        XCTAssertFalse(report.contains("https://example.com/research/item-1"))

        try store.unpin(snippetID: pinned.id, for: "conv-54")
        XCTAssertTrue(store.snippets(for: "conv-54").isEmpty, "取消收藏删除能力不回归")

        // Hosted ChatArtifactShelfPanel verification for 54+ items: default collapsed scroll height vs expanded old turn.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
            previousWindow?.makeKey()
        }

        func findVerticalScrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.alwaysBounceVertical || scroll.contentSize.height > scroll.bounds.height || scroll.bounds.height > 120 {
                return scroll
            }
            for sub in view.subviews {
                if let found = findVerticalScrollView(in: sub) { return found }
            }
            return nil
        }

        let collapsedHost = UIHostingController(rootView: ChatArtifactShelfPanel(
            artifacts: index,
            maxHeight: 468,
            onLocate: { _ in },
            onClose: {},
            snippets: [pinned]
        ).frame(width: 340))
        window.rootViewController = collapsedHost
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(250))
        collapsedHost.view.layoutIfNeeded()
        let collapsedScroll = try XCTUnwrap(findVerticalScrollView(in: collapsedHost.view))
        let collapsedContentHeight = collapsedScroll.contentSize.height
        XCTAssertLessThan(collapsedContentHeight, 750, "默认收起 3 个检索轮次组时面板滚动内容高度应保持紧凑，不平铺 54 条网页")

        let expandedHost = UIHostingController(rootView: ChatArtifactShelfPanel(
            artifacts: index,
            maxHeight: 468,
            onLocate: { _ in },
            onClose: {},
            snippets: [pinned],
            expandedWebGroupTurns: [1]
        ).frame(width: 340))
        window.rootViewController = expandedHost
        try await Task.sleep(for: .milliseconds(250))
        expandedHost.view.layoutIfNeeded()
        let expandedScroll = try XCTUnwrap(findVerticalScrollView(in: expandedHost.view))
        XCTAssertGreaterThan(
            expandedScroll.contentSize.height,
            collapsedContentHeight + 600,
            "展开第 1 轮检索组后滚动内容高度应显著增长并支持完整滚动访问该轮 19 条网页"
        )

        // 5. Ordinary no-search conversation is unaffected.
        let ordinaryMessages = [
            userMessage(text: "帮我写一份配置"),
            toolMessage(
                id: "ordinary-write",
                name: "workspace_file_write",
                input: #"{"path":"config.json","content":"{}"}"#,
                outputJSON: #"{"ok":true,"path":"/workspace/config.json","size_bytes":2}"#
            ),
            message(role: .assistant, parts: [UIMessagePart.Text(text: "已写入配置。", metadata: nil)])
        ]
        let ordinaryIndex = ConversationArtifactIndex.make(from: ordinaryMessages)
        XCTAssertTrue(ordinaryIndex.webPages.isEmpty)
        XCTAssertTrue(ordinaryIndex.webPageGroups.isEmpty)
        XCTAssertEqual(ordinaryIndex.files.count, 1)
        XCTAssertEqual(ordinaryIndex.count, 1)
    }

    private func jsonLiteral(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private func userMessage(
        text: String = "hello",
        parts: [UIMessagePart]? = nil
    ) -> UIMessage {
        message(role: MessageRole.user, parts: parts ?? [UIMessagePart.Text(text: text, metadata: nil)])
    }

    private func toolMessage(
        id: String,
        name: String,
        input: String,
        outputJSON: String? = nil,
        output: [UIMessagePart] = []
    ) -> UIMessage {
        let outputParts: [UIMessagePart]
        if let outputJSON {
            outputParts = [UIMessagePart.Text(text: outputJSON, metadata: nil)]
        } else {
            outputParts = output
        }
        return message(
            role: MessageRole.assistant,
            parts: [UIMessagePart.Tool(
                toolCallId: id,
                toolName: name,
                input: input,
                output: outputParts,
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )]
        )
    }

    private func message(role: MessageRole, parts: [UIMessagePart]) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(), role: role, parts: parts,
            annotations: [], createdAt: chatNowLocalDateTime(), finishedAt: chatNowLocalDateTime(),
            modelId: nil, usage: nil, translation: nil
        )
    }

}
