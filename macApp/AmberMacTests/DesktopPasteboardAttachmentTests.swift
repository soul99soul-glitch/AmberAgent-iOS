import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AmberMac

@MainActor final class DesktopPasteboardAttachmentTests: XCTestCase {
    private final class RecordingProvider: DesktopTextProvider {
        var configurations: [DesktopProviderConfiguration] = []
        var requests: [[DesktopMessage]] = []
        var runs: [DesktopGeneration] = []
        var cancelledFlags: [Bool] = []

        func start(configuration: DesktopProviderConfiguration, apiKey: String,
                   messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            let run = DesktopGeneration()
            let index = runs.count
            runs.append(run)
            cancelledFlags.append(false)
            run.installCancellation { [weak self] in
                Task { @MainActor in self?.cancelledFlags[index] = true }
            }
            configurations.append(configuration)
            requests.append(messages)
            return run
        }
    }

    private func makeImageData(type: UTType, width: Int = 32, height: Int = 24, red: CGFloat = 0.9) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeWorkspace(supportsVision: Bool? = true) throws -> (DesktopWorkspace, RecordingProvider, URL) {
        let suite = "amber.pasteboard.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var providerConfig = try XCTUnwrap(settings.selectedProvider)
        providerConfig.name = "OpenAI"
        providerConfig.models = [
            DesktopModelConfiguration(
                modelID: "gpt-4o",
                name: "GPT-4o",
                supportsVision: supportsVision
            )
        ]
        providerConfig.selectedModelID = providerConfig.models.first?.id
        try settings.saveProvider(providerConfig, apiKey: "test-key")

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("amber-paste-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let conversation = DesktopConversation(title: "粘贴测试")
        let provider = RecordingProvider()
        let workspace = DesktopWorkspace(
            settings: settings,
            storage: DesktopMemoryConversationStorage([conversation]),
            provider: provider,
            initialConversations: [conversation],
            files: DesktopWorkspaceFiles(directory: tempRoot.appendingPathComponent("files", isDirectory: true))
        )
        return (workspace, provider, tempRoot)
    }

    private func waitForAttachments(_ workspace: DesktopWorkspace) async {
        let deadline = Date().addingTimeInterval(3)
        while workspace.isReadingAttachments && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        _ = await workspace.flush()
    }

    func testPasteboardPngJpegAndTiffImagesBecomeImageAttachments() async throws {
        let (workspace, _, tempRoot) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let cases: [(UTType, NSPasteboard.PasteboardType, String)] = [
            (.png, .png, "image/png"),
            (.jpeg, NSPasteboard.PasteboardType(UTType.jpeg.identifier), "image/jpeg"),
            (.tiff, .tiff, "image/png"),
        ]

        for (index, item) in cases.enumerated() {
            let pb = NSPasteboard(name: NSPasteboard.Name("amber.test.image.\(UUID().uuidString)"))
            pb.clearContents()
            let data = try makeImageData(type: item.0, width: 40 + index, height: 20 + index)
            XCTAssertTrue(pb.setData(data, forType: item.1))

            XCTAssertTrue(workspace.pasteFromPasteboard(pb))
            await waitForAttachments(workspace)

            XCTAssertEqual(workspace.pendingAttachments.count, index + 1)
            let attachment = try XCTUnwrap(workspace.pendingAttachments.last)
            XCTAssertEqual(attachment.kind, .image)
            let image = try XCTUnwrap(attachment.image)
            XCTAssertEqual(image.mimeType, item.2)
            XCTAssertEqual(image.pixelWidth, 40 + index)
            XCTAssertEqual(image.pixelHeight, 20 + index)
            XCTAssertTrue(image.dataURL.hasPrefix("data:\(item.2);base64,"))
            XCTAssertFalse(image.thumbnailData.isEmpty)
        }
    }

    func testPasteboardFileURLsBeatFinderFilenameStringAndIconTiff() async throws {
        let (workspace, _, tempRoot) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let markdownURL = tempRoot.appendingPathComponent("notes.md")
        try "# 会议纪要\n这是从 Finder 粘贴的文档。".write(to: markdownURL, atomically: true, encoding: .utf8)
        let pngURL = tempRoot.appendingPathComponent("diagram.png")
        try makeImageData(type: .png, width: 64, height: 48).write(to: pngURL)

        let pb = NSPasteboard(name: NSPasteboard.Name("amber.test.finder.\(UUID().uuidString)"))
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([markdownURL as NSURL, pngURL as NSURL]))
        // Finder also places the filename as plain text and a small icon TIFF on the pasteboard.
        pb.setString("notes.md\ndiagram.png", forType: .string)
        pb.setData(try makeImageData(type: .tiff, width: 16, height: 16, red: 0.1), forType: .tiff)

        workspace.draft = "已有草稿"
        XCTAssertTrue(workspace.pasteFromPasteboard(pb))
        await waitForAttachments(workspace)

        XCTAssertEqual(workspace.draft, "已有草稿", "粘贴文件不应改动输入框草稿")
        XCTAssertEqual(workspace.pendingAttachments.map(\.name), ["notes.md", "diagram.png"])
        XCTAssertEqual(workspace.pendingAttachments[0].kind, .text)
        XCTAssertTrue(workspace.pendingAttachments[0].text.contains("这是从 Finder 粘贴的文档。"))
        XCTAssertEqual(workspace.pendingAttachments[1].kind, .image)
        XCTAssertEqual(workspace.pendingAttachments[1].image?.pixelWidth, 64)
        XCTAssertEqual(workspace.pendingAttachments[1].image?.pixelHeight, 48)
    }

    func testPlainTextPasteboardReturnsFalseAndLeavesAttachmentsUntouched() throws {
        let (workspace, _, tempRoot) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let pb = NSPasteboard(name: NSPasteboard.Name("amber.test.text.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("普通剪贴板文本", forType: .string)

        XCTAssertFalse(workspace.pasteFromPasteboard(pb))
        XCTAssertTrue(workspace.pendingAttachments.isEmpty)
        XCTAssertNil(workspace.errorMessage)
    }

    func testDropFilesAcceptsFileURLsAndRejectsWebURLs() async throws {
        let (workspace, _, tempRoot) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let webURL = try XCTUnwrap(URL(string: "https://example.com/file.txt"))
        XCTAssertFalse(workspace.dropFiles([webURL]))

        let fileURL = tempRoot.appendingPathComponent("dropped.txt")
        try "拖拽文件内容".write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(workspace.dropFiles([fileURL]))
        await waitForAttachments(workspace)

        XCTAssertEqual(workspace.pendingAttachments.map(\.name), ["dropped.txt"])
        XCTAssertEqual(workspace.pendingAttachments.first?.text, "拖拽文件内容")
    }

    func testOversizedPastedImageOrFileReportsExplicitError() async throws {
        let (workspace, _, tempRoot) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let oversizedData = Data(count: DesktopDocumentImport.maximumFileBytes + 1)
        let imagePB = NSPasteboard(name: NSPasteboard.Name("amber.test.oversize.img.\(UUID().uuidString)"))
        imagePB.clearContents()
        imagePB.setData(oversizedData, forType: .png)

        XCTAssertTrue(workspace.pasteFromPasteboard(imagePB))
        await waitForAttachments(workspace)
        XCTAssertTrue(workspace.pendingAttachments.isEmpty)
        XCTAssertEqual(workspace.errorMessage, "图片超过 32 MB 导入上限。")

        let bigFileURL = tempRoot.appendingPathComponent("huge.txt")
        try oversizedData.write(to: bigFileURL)
        let filePB = NSPasteboard(name: NSPasteboard.Name("amber.test.oversize.file.\(UUID().uuidString)"))
        filePB.clearContents()
        XCTAssertTrue(filePB.writeObjects([bigFileURL as NSURL]))

        XCTAssertTrue(workspace.pasteFromPasteboard(filePB))
        await waitForAttachments(workspace)
        XCTAssertTrue(workspace.pendingAttachments.isEmpty)
        XCTAssertEqual(workspace.errorMessage, "文件超过 32 MB 导入上限。")
    }

    func testSendingPastedImageUsesVisionFallbackOrReportsTextOnlyModel() async throws {
        let (workspace, provider, tempRoot) = try makeWorkspace(supportsVision: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let pb = NSPasteboard(name: NSPasteboard.Name("amber.test.vision.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setData(try makeImageData(type: .png), forType: .png)
        XCTAssertTrue(workspace.pasteFromPasteboard(pb))
        await waitForAttachments(workspace)
        XCTAssertEqual(workspace.pendingAttachments.count, 1)

        workspace.draft = "看图回答"
        workspace.send()
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(workspace.errorMessage, "当前模型仅支持文本，请选择支持图片的模型，或在辅助任务中指定视觉模型。")
        XCTAssertEqual(workspace.pendingAttachments.count, 1, "发送前被拦截时应保留待发附件")

        // Configure a vision auxiliary model and verify automatic routing succeeds.
        var config = try XCTUnwrap(workspace.settings.selectedProvider)
        let visionModel = DesktopModelConfiguration(modelID: "gpt-4o-vision", name: "GPT-4o Vision", supportsVision: true)
        config.models.append(visionModel)
        try workspace.settings.saveProvider(config, apiKey: "test-key")
        workspace.settings.setAuxiliaryModel(visionModel.id, for: .vision)

        workspace.send()
        XCTAssertEqual(provider.configurations.first?.selectedModel?.modelID, "gpt-4o-vision")
        XCTAssertEqual(provider.requests.first?.last?.images.count, 1)
    }

    func testIsPasteShortcutRecognizesCommandVOnly() {
        XCTAssertTrue(DesktopPasteboardImport.isPasteShortcut(modifierFlags: [.command], charactersIgnoringModifiers: "v", keyCode: 9))
        XCTAssertTrue(DesktopPasteboardImport.isPasteShortcut(modifierFlags: [.command, .capsLock], charactersIgnoringModifiers: "V", keyCode: 9))
        XCTAssertFalse(DesktopPasteboardImport.isPasteShortcut(modifierFlags: [.command, .shift], charactersIgnoringModifiers: "v", keyCode: 9))
        XCTAssertFalse(DesktopPasteboardImport.isPasteShortcut(modifierFlags: [.control], charactersIgnoringModifiers: "v", keyCode: 9))
        XCTAssertFalse(DesktopPasteboardImport.isPasteShortcut(modifierFlags: [], charactersIgnoringModifiers: "v", keyCode: 9))
        XCTAssertFalse(DesktopPasteboardImport.isPasteShortcut(modifierFlags: [.command], charactersIgnoringModifiers: "c", keyCode: 8))
    }

    func testCrossSessionPasteAndConcurrentSendIsolation() async throws {
        let (workspace, provider, tempRoot) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let firstID = try XCTUnwrap(workspace.selectedID)
        workspace.createConversation()
        let secondID = try XCTUnwrap(workspace.selectedID)
        workspace.select(firstID)

        // 1. 会话A发起流式生成
        workspace.draft = "会话A的问题"
        workspace.send()
        XCTAssertTrue(workspace.isSelectedConversationGenerating)
        XCTAssertEqual(provider.requests.count, 1)

        // 2. 切换到会话B，验证粘贴图片、保留独立草稿与附件，并发起会话B的请求
        workspace.select(secondID)
        XCTAssertFalse(workspace.isSelectedConversationGenerating)
        workspace.draft = "为什么这里这么乱，能改吗"

        let pb = NSPasteboard(name: NSPasteboard.Name("amber.test.cross-session.\(UUID().uuidString)"))
        pb.clearContents()
        XCTAssertTrue(pb.setData(try makeImageData(type: .png, width: 20, height: 20), forType: .png))

        XCTAssertTrue(workspace.pasteFromPasteboard(pb))
        XCTAssertNil(workspace.errorMessage, "切换离开生成中的会话A后，会话B粘贴图片不应报『请等待当前回复结束或停止后再粘贴图片。』")
        await waitForAttachments(workspace)
        XCTAssertEqual(workspace.pendingAttachments.count, 1)
        XCTAssertEqual(workspace.draft, "为什么这里这么乱，能改吗")

        workspace.send()
        XCTAssertEqual(provider.requests.count, 2, "会话B应在会话A生成期间独立发起请求")
        XCTAssertTrue(workspace.isSelectedConversationGenerating)
        XCTAssertTrue(workspace.isConversationGenerating(firstID))
        XCTAssertTrue(workspace.isConversationGenerating(secondID))

        // 3. 同一正在生成的会话B内，只有明确选中当前任务作为「补充」时才拦截图片粘贴并排队文本；
        //    默认未选中补充时，允许直接发送新问题或粘贴附件开启新任务。
        let activeTaskB = try XCTUnwrap(workspace.selectedConversationActiveTasks.first)
        workspace.selectSupplementTarget(activeTaskB.token)
        XCTAssertTrue(workspace.pasteFromPasteboard(pb))
        XCTAssertEqual(workspace.errorMessage, "补充运行中任务仅支持纯文本，请取消选中补充目标后再粘贴图片。")
        workspace.draft = "会话B的排队追问"
        workspace.send()
        XCTAssertEqual(workspace.selectedQueuedMessages.map(\.text), ["会话B的排队追问"])

        // 4. 会话A的流式输出与工具调用只落入会话A，不串入当前选中的会话B
        let runA = try XCTUnwrap(provider.runs.first)
        let runB = try XCTUnwrap(provider.runs.last)
        let toolCall = DesktopToolCall(id: "call-a", name: "read_file", input: "{\"path\":\"a.txt\"}", output: "A-content", status: .complete)
        runA.yield(.snapshot(text: "会话A的流式回答", reasoning: "A的思考", canonicalJSON: nil, unsupportedPartCount: 0, tools: [toolCall]))
        workspace.apply(runA.drain(), for: firstID)

        runB.yield(.snapshot(text: "会话B的流式回答", reasoning: "", canonicalJSON: nil, unsupportedPartCount: 0, tools: []))
        workspace.apply(runB.drain(), for: secondID)

        let messagesB = try XCTUnwrap(workspace.selectedConversation?.messages)
        XCTAssertEqual(messagesB.last?.text, "会话B的流式回答")
        XCTAssertTrue(messagesB.last?.tools.isEmpty ?? false)

        // 5. 来回切换A与B，各自展示自身消息与运行状态
        workspace.select(firstID)
        XCTAssertTrue(workspace.isSelectedConversationGenerating)
        XCTAssertTrue(workspace.selectedQueuedMessages.isEmpty, "会话B的排队消息不应出现在会话A")
        let messagesA = try XCTUnwrap(workspace.selectedConversation?.messages)
        XCTAssertEqual(messagesA.last?.text, "会话A的流式回答")
        XCTAssertEqual(messagesA.last?.tools.map(\.id), ["call-a"])

        // 6. 切回会话B并点击停止：仅取消会话B，会话A继续运行并正常完成
        workspace.select(secondID)
        workspace.stop()
        await Task.yield()
        XCTAssertTrue(provider.cancelledFlags[1], "停止当前会话B时应取消B的run")
        XCTAssertFalse(provider.cancelledFlags[0], "停止会话B绝不能取消后台仍在生成的会话A")
        XCTAssertFalse(workspace.isConversationGenerating(secondID))
        XCTAssertTrue(workspace.isConversationGenerating(firstID))
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.state, .cancelled)

        runA.yield(.complete)
        workspace.apply(runA.drain(), for: firstID)
        XCTAssertFalse(workspace.isConversationGenerating(firstID))
        XCTAssertFalse(workspace.isGenerating)

        workspace.select(firstID)
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.state, .complete)
        XCTAssertEqual(workspace.selectedConversation?.messages.last?.text, "会话A的流式回答")
    }

    func testInterleavedTextAndPastedImagesPreserveExactSegmentOrder() async throws {
        let (workspace, provider, tempRoot) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // 1. 输入第一段文字，粘贴单张图片
        workspace.draft = "这是修改前的截图："
        let pb1 = NSPasteboard(name: NSPasteboard.Name("amber.test.interleaved.1.\(UUID().uuidString)"))
        pb1.clearContents()
        XCTAssertTrue(pb1.setData(try makeImageData(type: .png, width: 48, height: 32, red: 0.8), forType: .png))
        XCTAssertTrue(workspace.pasteFromPasteboard(pb1))
        await waitForAttachments(workspace)

        // 2. 继续输入第二段文字，连续粘贴两张图片
        workspace.draft = "这是修改前的截图：\n这是修改后的两组对比："
        let img2URL = tempRoot.appendingPathComponent("after-1.png")
        let img3URL = tempRoot.appendingPathComponent("after-2.png")
        try makeImageData(type: .png, width: 60, height: 40, red: 0.2).write(to: img2URL)
        try makeImageData(type: .png, width: 60, height: 40, red: 0.4).write(to: img3URL)
        let pb2 = NSPasteboard(name: NSPasteboard.Name("amber.test.interleaved.2.\(UUID().uuidString)"))
        pb2.clearContents()
        XCTAssertTrue(pb2.writeObjects([img2URL as NSURL, img3URL as NSURL]))
        XCTAssertTrue(workspace.pasteFromPasteboard(pb2))
        await waitForAttachments(workspace)

        XCTAssertEqual(workspace.pendingAttachments.count, 3)

        // 3. 发送并检查用户消息的顺序段：文字 -> 单图 -> 文字 -> 多图
        workspace.send()
        let userMsg = try XCTUnwrap(provider.requests.first?.last(where: { $0.role == .user }))
        XCTAssertEqual(userMsg.images.count, 3)
        let blocks = userMsg.orderedDisplayBlocks(streaming: false)
        XCTAssertEqual(blocks.count, 4)
        if case .text(let firstText) = blocks[0] {
            XCTAssertEqual(firstText, "这是修改前的截图：")
        } else {
            XCTFail("Expected first block to be .text, got \(blocks[0])")
        }
        if case .images(let firstImages) = blocks[1] {
            XCTAssertEqual(firstImages.count, 1)
        } else {
            XCTFail("Expected second block to be single .images, got \(blocks[1])")
        }
        if case .text(let secondText) = blocks[2] {
            XCTAssertEqual(secondText, "这是修改后的两组对比：")
        } else {
            XCTFail("Expected third block to be .text, got \(blocks[2])")
        }
        if case .images(let secondImages) = blocks[3] {
            XCTAssertEqual(secondImages.count, 2)
            XCTAssertEqual(secondImages.map(\.name), ["after-1.png", "after-2.png"])
        } else {
            XCTFail("Expected fourth block to be 2 .images, got \(blocks[3])")
        }
    }
}
