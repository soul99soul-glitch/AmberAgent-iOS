import CoreGraphics
import Foundation
import PDFKit
@preconcurrency import Shared
import Testing
import UIKit
@testable import iosApp

@Suite("App 内分享与导出")
@MainActor
struct IOSShareSupportTests {
    // MARK: - 对话导出

    @Test func conversationMarkdownLabelsRolesAndImages() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let markdown = IOSConversationExporter.markdown(
            title: "旅行计划",
            entries: [
                .init(role: .user, text: "帮我规划东京三日游", imageCount: 1),
                .init(role: .assistant, text: "**第一天**：浅草寺", imageCount: 0),
            ],
            exportedAt: date
        )
        #expect(markdown.hasPrefix("# 旅行计划\n\n> 导出自 Amber · "))
        #expect(markdown.contains("### 我\n\n*[1 张图片]*\n\n帮我规划东京三日游\n\n---"))
        #expect(markdown.contains("### Amber\n\n**第一天**：浅草寺\n\n---"))
    }

    @Test func shareFileNamesAreSanitized() {
        #expect(IOSShareFileWriter.sanitized("a/b:c?") == "a b c")
        #expect(IOSShareFileWriter.sanitized("  ") == "Amber")
    }

    // MARK: - 渲染

    @Test func conversationPDFRendersPagedDocument() async throws {
        let entries: [IOSConversationExporter.Entry] = (1...40).map {
            .init(role: $0.isMultiple(of: 2) ? .assistant : .user, text: "第 \($0) 条：\(String(repeating: "内容 ", count: 60))", imageCount: 0)
        }
        let data = try await IOSHTMLPDFRenderer.render(html: IOSConversationExporter.html(title: "长对话", entries: entries))
        #expect(data.starts(with: Data("%PDF".utf8)))
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount > 1)
        // 离屏 WebView 必须真的排出了文字，而不是空白页。
        let text = document.string ?? ""
        // PDFKit 提取时会把「长」「自」等字映射成同形的 CJK 部首码位，只断言不受影响的片段。
        #expect(text.contains("对话"), "\(text.prefix(120))")
        #expect(text.contains("Amber"))
        #expect(text.contains("第 40 条"))
    }

    @Test func messageImageRendererProducesBoundedImage() throws {
        let image = try #require(IOSMessageImageRenderer.render(text: String(repeating: "**长**消息 ", count: 2_000), isUser: false))
        #expect(image.size.width == 390)
        #expect(image.scale == 2)
        // 行数/字数上限保证位图不会失控（3000 字的卡片远低于 5000pt）。
        #expect(image.size.height < 5_000)
    }

    @Test func imageTextDropsCodeFencesAndTruncatesByLines() {
        let fenced = IOSMessageImageRenderer.preparedText("前言\n```swift\nlet a = 1\n```\n结尾")
        #expect(fenced == "前言\nlet a = 1\n结尾")

        let manyLines = (1...500).map { "行\($0)" }.joined(separator: "\n")
        let prepared = IOSMessageImageRenderer.preparedText(manyLines)
        #expect(prepared.components(separatedBy: "\n").count == IOSMessageImageRenderer.maxLines + 1)
        #expect(prepared.hasSuffix("…（内容过长，已截断）"))
    }

    // MARK: - 取数

    @Test func entriesKeepOnlyUserAndAssistantWithDisplayText() {
        let messages = [
            IOSChatForegroundFixtures.makeMessage(role: MessageRole.system, parts: [UIMessagePart.Text(text: "系统提示", metadata: nil)]),
            IOSChatForegroundFixtures.userMessage("  你好  "),
            IOSChatForegroundFixtures.assistantText("你好，我是 Amber"),
            IOSChatForegroundFixtures.makeMessage(role: MessageRole.user, parts: [UIMessagePart.Image(url: "data:image/png;base64,AA==", metadata: nil)]),
            IOSChatForegroundFixtures.assistantText("   "),
        ]
        let entries = IOSConversationExporter.entries(from: messages)
        #expect(entries == [
            .init(role: .user, text: "你好", imageCount: 0),
            .init(role: .assistant, text: "你好，我是 Amber", imageCount: 0),
            .init(role: .user, text: "", imageCount: 1),
        ])
    }

    @Test func exportRejectsEmptyConversationAndFallsBackToDefaultTitle() async throws {
        await #expect(throws: IOSConversationExporter.ExportError.self) {
            _ = try await IOSConversationExporter.export(format: .markdown, title: "x", messages: [])
        }
        let url = try await IOSConversationExporter.export(
            format: .markdown, title: "   ", messages: [IOSChatForegroundFixtures.userMessage("hi")]
        )
        #expect(url.lastPathComponent == "Amber 对话.md")
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("# Amber 对话"))
    }

    // MARK: - 文件与状态

    @Test func fileNamesAvoidHiddenFilesAndByteOverflow() {
        #expect(IOSShareFileWriter.sanitized("..hidden") == "hidden")
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 100)
        let cleaned = IOSShareFileWriter.sanitized(emoji)
        #expect(cleaned.utf8.count <= 200)
        #expect(cleaned.allSatisfy { $0 == "👨‍👩‍👧‍👦" })
    }

    @Test func pruneRemovesOnlyExpiredExportDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareExportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try IOSShareFileWriter.write(Data("a".utf8), fileName: "old", pathExtension: "md", root: root)
        let fresh = try IOSShareFileWriter.write(Data("b".utf8), fileName: "fresh", pathExtension: "md", root: root)
        IOSShareFileWriter.pruneExpired(in: root, now: Date().addingTimeInterval(IOSShareFileWriter.retention + 60))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: fresh.path))

        let kept = try IOSShareFileWriter.write(Data("c".utf8), fileName: "kept", pathExtension: "md", root: root)
        IOSShareFileWriter.pruneExpired(in: root)
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test func shareActivityRejectsConcurrentExports() {
        let activity = IOSShareActivity.shared
        activity.resetForTesting()
        #expect(activity.begin("正在生成 PDF…"))
        #expect(!activity.begin("第二次"))
        #expect(activity.status == .working("正在生成 PDF…"))
        activity.end(failure: "失败")
        #expect(activity.status == .failed("失败"))
        #expect(!activity.isWorking)
        activity.end()
        #expect(activity.status == nil)
    }

    @Test func failuresDuringWorkIsQueuedInsteadOfDropped() {
        let activity = IOSShareActivity.shared
        activity.resetForTesting()
        #expect(activity.begin("正在生成 PDF…"))
        activity.flash(failure: "正在导出，请稍后再分享这条消息。")
        #expect(activity.status == .working("正在生成 PDF…"))
        activity.end()
        #expect(activity.status == .failed("正在导出，请稍后再分享这条消息。"))
        activity.end()
        #expect(activity.status == nil)
    }

    @Test func listExportShowsProgressBeforeLoadingAndReportsLoadFailure() async {
        let activity = IOSShareActivity.shared
        activity.resetForTesting()
        var statusWhileLoading: IOSShareActivity.Status?
        await IOSConversationExporter.share(format: .markdown, title: "t") {
            statusWhileLoading = activity.status
            return .failed("无法读取这段对话，可能已被删除或读取失败。")
        }
        #expect(statusWhileLoading == .working("正在导出 Markdown…"))
        // 会话列表上看不到存储层的弹窗，读取失败必须由浮层自己提示。
        #expect(activity.status == .failed("无法读取这段对话，可能已被删除或读取失败。"))
        #expect(!activity.isWorking)
        activity.resetForTesting()
    }

    @Test func busyExportGivesVisibleFeedbackInsteadOfSilentReturn() async {
        let activity = IOSShareActivity.shared
        activity.resetForTesting()
        #expect(activity.begin("正在生成 PDF…"))
        await IOSConversationExporter.share(format: .markdown, title: "t") { .failed("x") }
        // 忙碌提示立即显示，不排队到当前任务结束后才冒出来。
        #expect(activity.notice == IOSConversationExporter.busyMessage)
        #expect(activity.status == .working("正在生成 PDF…"))
        activity.end()
        #expect(activity.status == nil)
        activity.resetForTesting()
    }

    @Test func explicitAndQueuedFailuresAreMergedNotOverwritten() {
        let activity = IOSShareActivity.shared
        activity.resetForTesting()
        #expect(activity.begin("正在生成 PDF…"))
        activity.flash(failure: "排队的失败")
        activity.end(failure: "当前任务失败")
        #expect(activity.status == .failed("当前任务失败；排队的失败"))
        activity.end()
    }

    @Test func shareSheetThatIsNoLongerOnScreenDoesNotSwallowFailures() {
        let activity = IOSShareActivity.shared
        activity.resetForTesting()
        // 面板引用存在但已不在屏幕上（例如被程序化移除且没有回调）：不能继续挡住失败提示。
        let orphan = UIViewController()
        activity.shareSheetDidAppear(orphan)
        activity.flash(failure: "面板消失后的失败")
        #expect(activity.status == .failed("面板消失后的失败"))
        activity.resetForTesting()
    }

    @Test func mergedFailuresAreCappedAndDurationScalesWithLength() {
        let activity = IOSShareActivity.shared
        activity.resetForTesting()
        #expect(activity.begin("x"))
        for index in 1...5 { activity.flash(failure: "失败\(index)") }
        activity.end()
        #expect(activity.status == .failed("失败1；失败2；失败3"))
        #expect(IOSShareActivity.displayDuration(for: "短") == .seconds(3))
        #expect(IOSShareActivity.displayDuration(for: String(repeating: "长", count: 60)) == .seconds(5))
        activity.resetForTesting()
    }

    @Test func instantTasksHoldTheLockWithoutShowingProgress() {
        let activity = IOSShareActivity.shared
        activity.resetForTesting()
        #expect(activity.begin())
        #expect(activity.isWorking)
        #expect(activity.status == nil)
        #expect(!activity.begin("第二个"))
        activity.end()
        #expect(!activity.isWorking)
    }

    @Test func printFriendlyInjectsPaginationRules() {
        let withHead = IOSHTMLPDFRenderer.printFriendly("<html><head><title>x</title></HEAD><body></body></html>")
        #expect(withHead.contains("<style>\(IOSHTMLPDFRenderer.printCSS)</style></head>"))
        let bare = IOSHTMLPDFRenderer.printFriendly("<p>x</p>")
        #expect(bare.hasPrefix("<style>"))
    }
}
