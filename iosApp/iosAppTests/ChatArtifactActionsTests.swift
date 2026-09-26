import XCTest
@testable import iosApp

final class ChatArtifactActionsTests: XCTestCase {
    func testContinueMappingForImageFileSnippetAndWebPage() {
        let source = ConversationArtifactIndex.Source(messageID: "m1", turn: 2, toolCallID: "call1")
        let image = ConversationArtifactIndex.Image(id: "image1", url: "https://example.test/image.png", prompt: nil, source: source)
        let snippet = IOSPinnedSnippet(
            id: "m2:code:hash",
            messageID: "m2",
            turn: 3,
            text: "first\nsecond",
            kind: .code,
            codeLanguage: "swift"
        )
        let page = ConversationArtifactIndex.WebPage(
            id: "web:https://example.test",
            title: "Example",
            url: "https://example.test",
            preview: nil,
            source: source
        )

        XCTAssertEqual(
            ChatArtifactActions.continuation(for: .image(image)),
            .image(url: "https://example.test/image.png")
        )
        XCTAssertEqual(ChatArtifactActions.continuation(for: .file(path: "docs/plan.md")), .text("/workspace/docs/plan.md"))
        XCTAssertEqual(
            ChatArtifactActions.continuation(for: .snippet(snippet)),
            .text("> first\n> second")
        )
        XCTAssertEqual(
            ChatArtifactActions.continuation(for: .webPage(page)),
            .text("[Example](<https://example.test>)")
        )
    }

    func testReportUsesAdoptedFileAndLatestFallbackAndSourceTurns() {
        let adoptedSource = ConversationArtifactIndex.Source(messageID: "m2", turn: 2, toolCallID: "write1")
        let latestSource = ConversationArtifactIndex.Source(messageID: "m8", turn: 5, toolCallID: "write2")
        let adopted = ConversationArtifactIndex.FileVersion(id: "v1", source: adoptedSource, content: "adopted body")
        let latest = ConversationArtifactIndex.FileVersion(id: "v2", source: latestSource, content: "latest body")
        let selectedFile = ConversationArtifactIndex.FileGroup(path: "docs/adopted.md", versions: [adopted, latest])
        let fallbackFile = ConversationArtifactIndex.FileGroup(
            path: "docs/latest.md",
            versions: [
                .init(id: "old", source: adoptedSource, content: "old fallback"),
                .init(id: "new", source: latestSource, content: "new fallback")
            ]
        )
        let page = ConversationArtifactIndex.WebPage(
            id: "web:https://example.test",
            title: "Example",
            url: "https://example.test",
            preview: nil,
            source: latestSource
        )
        let snippet = IOSPinnedSnippet(
            id: "m9:message",
            messageID: "m9",
            turn: 6,
            text: "keep this line",
            kind: .message
        )
        let index = ConversationArtifactIndex(images: [], files: [selectedFile, fallbackFile], webPages: [page])

        let markdown = ChatArtifactActions.reportMarkdown(
            title: "周报",
            index: index,
            snippets: [snippet],
            adoptedVersions: ["docs/adopted.md": "v1"]
        )

        XCTAssertTrue(markdown.contains("adopted body"))
        XCTAssertFalse(markdown.contains("latest body"))
        XCTAssertTrue(markdown.contains("new fallback"))
        XCTAssertTrue(markdown.contains("第 2 轮"))
        XCTAssertTrue(markdown.contains("第 5 轮"))
        XCTAssertTrue(markdown.contains("第 6 轮"))
        XCTAssertTrue(markdown.contains("[Example](<https://example.test>)"))
        XCTAssertTrue(markdown.contains("> keep this line"))
        XCTAssertTrue(markdown.hasPrefix("# 周报 · 成果报告\n"))
        XCTAssertTrue(markdown.contains("已采用版本 1/2 · 来源：第 2 轮"))
        XCTAssertTrue(markdown.contains("最新版本 2/2 · 来源：第 5 轮"))
        XCTAssertTrue(markdown.contains("```md\nadopted body\n```"))
    }

    func testReportKeepsOnlyPublicImageURLsAndFencesCodeSnippets() {
        let source = ConversationArtifactIndex.Source(messageID: "m1", turn: 3, toolCallID: "call1")
        let remote = ConversationArtifactIndex.Image(id: "remote", url: "https://example.test/a.png", prompt: "海报", source: source)
        let local = ConversationArtifactIndex.Image(id: "local", url: "data:image/png;base64,AAAA", prompt: nil, source: source)
        let code = IOSPinnedSnippet(
            id: "m2:code:hash", messageID: "m2", turn: 4,
            text: "let fence = \"```\"\nprint(fence)", kind: .code, codeLanguage: "swift"
        )
        let markdown = ChatArtifactActions.reportMarkdown(
            title: "对话", index: ConversationArtifactIndex(images: [remote, local], files: [], webPages: []),
            snippets: [code], adoptedVersions: [:]
        )

        XCTAssertTrue(markdown.contains("- 第 3 轮：海报\n\n  ![海报](<https://example.test/a.png>)"))
        XCTAssertTrue(markdown.contains("- 第 3 轮：生成图片"))
        XCTAssertFalse(markdown.contains("data:image"))
        XCTAssertTrue(markdown.contains("```swift\nlet fence = \"```\"\nprint(fence)\n```"))
    }

    func testExporterWritesSelectedItemsOffMainWithUniqueNames() async throws {
        let source = ConversationArtifactIndex.Source(messageID: "m1", turn: 2, toolCallID: "call1")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let image = ConversationArtifactIndex.Image(
            id: "image1", url: "data:image/png;base64,\(png.base64EncodedString())", prompt: nil, source: source
        )
        let written = ConversationArtifactIndex.FileGroup(path: "docs/plan.md", versions: [
            .init(id: "v1", source: source, content: "第一版"),
            .init(id: "v2", source: source, content: "第二版")
        ])
        let edited = ConversationArtifactIndex.FileGroup(path: "other/plan.md", versions: [
            .init(id: "e1", source: source, content: nil)
        ])
        let page = ConversationArtifactIndex.WebPage(
            id: "web1", title: "Example", url: "https://example.test", preview: nil, source: source
        )
        let snippet = IOSPinnedSnippet(id: "s1", messageID: "m3", turn: 3, text: "收藏", kind: .message)
        let index = ConversationArtifactIndex(images: [image], files: [written, edited], webPages: [page])
        let selected: Set<String> = [
            ChatArtifactActions.selectionID(for: image), ChatArtifactActions.selectionID(for: written),
            ChatArtifactActions.selectionID(for: edited), ChatArtifactActions.selectionID(for: page),
            ChatArtifactActions.selectionID(for: snippet)
        ]

        let prepared = try await ChatArtifactShelfExporter.prepare(
            index: index, snippets: [snippet], adoptedVersions: ["docs/plan.md": "v1"],
            selectedIDs: selected, title: "旅行/计划"
        )
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        XCTAssertEqual(prepared.export.shareURLs.count, 4)
        XCTAssertEqual(
            prepared.export.shareURLs.filter(\.isFileURL).map(\.lastPathComponent),
            ["图片-第2轮-1.png", "plan.md", "片段-第3轮.md"]
        )
        XCTAssertEqual(try Data(contentsOf: prepared.export.shareURLs[0]), png)
        XCTAssertEqual(try String(contentsOf: prepared.export.shareURLs[1], encoding: .utf8), "第一版")
        XCTAssertEqual(prepared.export.shareURLs[2], URL(string: "https://example.test"))
        XCTAssertEqual(prepared.export.reportOnlyCount, 1)
        XCTAssertEqual(prepared.export.reportURL.lastPathComponent, "旅行-计划-成果报告.md")
        let report = try String(contentsOf: prepared.export.reportURL, encoding: .utf8)
        XCTAssertTrue(report.contains("第一版"))
        XCTAssertTrue(report.contains("### `other/plan.md`\n\n最新 · 来源：第 2 轮\n\n此版本未保留正文。"))
    }

    func testReportEscapesTitlesNormalizesLineEndingsAndLengthensFences() {
        let source = ConversationArtifactIndex.Source(messageID: "m1", turn: 1, toolCallID: "call1")
        let page = ConversationArtifactIndex.WebPage(
            id: "web1", title: "Swift [指南]\n  第二行", url: "https://example.test/a b", preview: nil, source: source
        )
        let quoteSnippet = IOSPinnedSnippet(id: "q", messageID: "m2", turn: 2, text: "第一行\r\n第二行", kind: .message)
        let codeSnippet = IOSPinnedSnippet(
            id: "c", messageID: "m3", turn: 3, text: "   ````\ninner\n    ``````", kind: .code, codeLanguage: nil
        )
        let markdown = ChatArtifactActions.reportMarkdown(
            title: "对话", index: ConversationArtifactIndex(images: [], files: [], webPages: [page]),
            snippets: [quoteSnippet, codeSnippet], adoptedVersions: [:]
        )

        XCTAssertTrue(markdown.contains("- [Swift [指南\\] 第二行](<https://example.test/a b>)（第 1 轮）"))
        XCTAssertTrue(markdown.contains("> 第一行\n> 第二行\n"))
        XCTAssertFalse(markdown.contains("\r"))
        // 行首 3 个空格内的 4 个反引号可闭合围栏，需 5 个；4 个空格缩进的不算。
        XCTAssertTrue(markdown.contains("`````\n   ````\ninner\n    ``````\n`````"))
    }

    func testStaleAdoptedVersionIsIgnored() {
        let source = ConversationArtifactIndex.Source(messageID: "m1", turn: 1, toolCallID: "call1")
        let file = ConversationArtifactIndex.FileGroup(path: "a.md", versions: [
            .init(id: "v1", source: source, content: "一"), .init(id: "v2", source: source, content: "二")
        ])
        XCTAssertNil(ChatArtifactActions.adoptedVersionID(for: file, adoptedVersions: ["a.md": "gone"]))
        XCTAssertEqual(ChatArtifactActions.selectedVersion(for: file, adoptedVersions: ["a.md": "gone"])?.id, "v2")
        XCTAssertEqual(ChatArtifactActions.adoptedVersionID(for: file, adoptedVersions: ["a.md": "v1"]), "v1")
        let markdown = ChatArtifactActions.reportMarkdown(
            title: "t", index: ConversationArtifactIndex(images: [], files: [file], webPages: []),
            snippets: [], adoptedVersions: ["a.md": "gone"]
        )
        XCTAssertTrue(markdown.contains("最新版本 2/2"))
    }

    func testExporterSkipsFailingItemsAndCapsLongNames() async throws {
        let source = ConversationArtifactIndex.Source(messageID: "m1", turn: 1, toolCallID: "call1")
        let missing = ConversationArtifactIndex.Image(
            id: "missing", url: "file:///tmp/amber-missing-\(UUID().uuidString).png", prompt: nil, source: source
        )
        let longName = String(repeating: "很长的文件名", count: 60) + ".md"
        let file = ConversationArtifactIndex.FileGroup(path: "docs/\(longName)", versions: [
            .init(id: "v1", source: source, content: "正文")
        ])
        let index = ConversationArtifactIndex(images: [missing], files: [file], webPages: [])
        let prepared = try await ChatArtifactShelfExporter.prepare(
            index: index, snippets: [], adoptedVersions: [:],
            selectedIDs: [ChatArtifactActions.selectionID(for: missing), ChatArtifactActions.selectionID(for: file)],
            title: String(repeating: "标题", count: 200)
        )
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        XCTAssertEqual(prepared.export.skippedCount, 1)
        XCTAssertEqual(prepared.export.shareURLs.count, 1)
        let written = try XCTUnwrap(prepared.export.shareURLs.first)
        XCTAssertLessThanOrEqual(written.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(written.lastPathComponent.hasSuffix(".md"))
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "正文")
        XCTAssertLessThanOrEqual(prepared.export.reportURL.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.export.reportURL.path))
    }

    func testExportStateClearsPreviousResultWhilePreparingAndAlertsOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let export = ChatArtifactShelfExport(
            shareURLs: [directory], reportURL: directory.appendingPathComponent("r.md"),
            reportOnlyCount: 0, skippedCount: 0
        )
        var state = ChatArtifactShelfExportState()
        state.finish(export, directory: directory)
        XCTAssertEqual(state.export, export)

        state.begin()
        XCTAssertNil(state.export, "准备新选择期间不能分享上一批结果")
        XCTAssertTrue(state.isPreparing)
        XCTAssertTrue(state.fail("失败"))
        XCTAssertFalse(state.fail("失败"), "同一失败随选择变化不重复弹窗")
        XCTAssertTrue(state.fail("另一个失败"))

        // 替换结果不删除旧目录（可能仍在分享面板中），面板关闭时统一删除。
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        state.removeDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testListHeightIgnoresFooterAfterLeavingSelectMode() {
        let selecting = ChatArtifactShelfPanel.scrollHeight(
            maxHeight: 500, headerHeight: 44, footerHeight: 90, sectionsHeight: 1_000, isSelecting: true
        )
        let normal = ChatArtifactShelfPanel.scrollHeight(
            maxHeight: 500, headerHeight: 44, footerHeight: 90, sectionsHeight: 1_000, isSelecting: false
        )
        XCTAssertEqual(selecting, 500 - 44 - 90 - 28 - 32 - 8)
        XCTAssertEqual(normal, 500 - 44 - 14 - 32 - 8)
    }

    /// 代码块不再挂自己的 contextMenu（否则长按代码会吞掉整条消息菜单），收藏走 headerAccessory。
    func testCodeBlockPinUsesHeaderAccessoryWithoutNestedContextMenu() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let codeBlock = try String(
            contentsOf: root.appendingPathComponent("vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/CodeBlockView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(codeBlock.contains(".contextMenu"))
        let blockView = try String(
            contentsOf: root.appendingPathComponent("vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/BlockView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(blockView.contains("headerAccessory: codeBlockHeaderAccessory?(code, language)"))
        let markdownView = try String(contentsOf: root.appendingPathComponent("iosApp/MarkdownView.swift"), encoding: .utf8)
        XCTAssertTrue(markdownView.contains("ChatCodeBlockHeaderAccessory("))
        let pinAction = try String(contentsOf: root.appendingPathComponent("iosApp/ChatArtifactPinAction.swift"), encoding: .utf8)
        XCTAssertFalse(pinAction.contains(".contextMenu"))
    }

    func testUniqueNameKeepsExtensionAndStripsSeparators() {
        var taken = Set<String>()
        XCTAssertEqual(ChatArtifactShelfExporter.uniqueName("a/b.md", taken: &taken), "a-b.md")
        XCTAssertEqual(ChatArtifactShelfExporter.uniqueName("a/b.md", taken: &taken), "a-b-2.md")
        XCTAssertEqual(ChatArtifactShelfExporter.uniqueName("notes", taken: &taken), "notes")
        XCTAssertEqual(ChatArtifactShelfExporter.uniqueName("notes", taken: &taken), "notes-2")
    }

    func testReportSelectionIncludesOnlySelectedItems() {
        let source = ConversationArtifactIndex.Source(messageID: "m1", turn: 1, toolCallID: "call1")
        let image = ConversationArtifactIndex.Image(id: "image1", url: "https://example.test/i.png", prompt: nil, source: source)
        let page = ConversationArtifactIndex.WebPage(
            id: "web:https://example.test",
            title: "Unselected page",
            url: "https://example.test",
            preview: nil,
            source: source
        )
        let snippet = IOSPinnedSnippet(id: "m2:message", messageID: "m2", turn: 2, text: "selected", kind: .message)
        let index = ConversationArtifactIndex(images: [image], files: [], webPages: [page])

        let markdown = ChatArtifactActions.reportMarkdown(
            title: "对话",
            index: index,
            snippets: [snippet],
            adoptedVersions: [:],
            selectedIDs: [
                ChatArtifactActions.selectionID(for: image),
                ChatArtifactActions.selectionID(for: snippet)
            ]
        )

        XCTAssertTrue(markdown.contains("https://example.test/i.png"))
        XCTAssertTrue(markdown.contains("> selected"))
        XCTAssertFalse(markdown.contains("Unselected page"))
    }
}
