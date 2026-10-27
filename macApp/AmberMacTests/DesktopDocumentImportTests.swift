import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import AmberMac

final class DesktopDocumentImportTests: XCTestCase {
    private func temporary(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    private func fixture(_ name: String, ext: String) throws -> URL {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        return try XCTUnwrap(bundle.url(forResource: name, withExtension: ext))
    }

    func testTextEncodingAndSourceMetadata() async throws {
        let url = temporary("txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try XCTUnwrap("中文 UTF16\n第二行".data(using: .utf16))
        try data.write(to: url)
        let document = try await DesktopDocumentImport.read(url)
        XCTAssertEqual(document.kind, .text)
        XCTAssertEqual(document.text, "中文 UTF16\n第二行")
        XCTAssertEqual(document.name, url.lastPathComponent)
        XCTAssertEqual(document.sourceURL, url)
        XCTAssertEqual(document.byteCount, data.count)
        XCTAssertNil(document.image)
    }

    func testNativeRTFAndDOCXTextExtraction() async throws {
        let url = temporary("rtf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{\rtf1\ansi First paragraph\par Second paragraph}"#.utf8).write(to: url)
        let rtf = try await DesktopDocumentImport.read(url)
        XCTAssertEqual(rtf.kind, .document)
        XCTAssertTrue(rtf.text.contains("First paragraph"))
        XCTAssertTrue(rtf.text.contains("Second paragraph"))
        let docx = try await DesktopDocumentImport.read(fixture("SimpleDocument", ext: "docx"))
        XCTAssertTrue(docx.text.contains("Office document text"))
        XCTAssertTrue(docx.text.contains("中文段落与数值 123"))
    }

    func testPPTXStoredAndDeflatedArchivesUsePresentationOrder() async throws {
        for name in ["DeflatedOrder", "StoredOrder"] {
            let document = try await DesktopDocumentImport.read(fixture(name, ext: "pptx"))
            XCTAssertEqual(document.kind, .presentation)
            XCTAssertEqual(document.pageCount, 2)
            let first = try XCTUnwrap(document.text.range(of: "File two appears first"))
            let second = try XCTUnwrap(document.text.range(of: "File one appears second & 保留中文"))
            XCTAssertLessThan(first.lowerBound, second.lowerBound)
            XCTAssertTrue(document.text.contains("Second paragraph"))
            XCTAssertNil(document.note)
        }
    }

    func testCorruptPPTXReturnsReadableFailure() async throws {
        let url = temporary("pptx")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: url)
        do {
            _ = try await DesktopDocumentImport.read(url)
            XCTFail("A corrupt archive must not become empty successful text")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Office")) }
    }

    func testHTMLExtractsReadableBlocksWithoutScriptOrStyle() async throws {
        let url = temporary("html")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("<html><head><style>secret-style</style><script>secret-script</script></head><body><p>你好 &amp; world</p><p>下一段</p></body></html>".utf8).write(to: url)
        let document = try await DesktopDocumentImport.read(url)
        XCTAssertTrue(document.text.contains("你好 & world"), document.text)
        XCTAssertTrue(document.text.contains("下一段"), document.text)
        XCTAssertFalse(document.text.contains("secret"))
    }

    func testImagePreservesOriginalPNGAndConvertsTIFFWithRealThumbnail() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let image = try XCTUnwrap(context.makeImage())
        for type in [UTType.png, .tiff] {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let url = temporary(type.preferredFilenameExtension!)
            defer { try? FileManager.default.removeItem(at: url) }
            try (data as Data).write(to: url)
            let document = try await DesktopDocumentImport.read(url)
            let imported = try XCTUnwrap(document.image)
            XCTAssertEqual(document.kind, .image)
            XCTAssertEqual(imported.pixelWidth, 64)
            XCTAssertEqual(imported.pixelHeight, 32)
            XCTAssertEqual(imported.mimeType, "image/png")
            XCTAssertTrue(imported.dataURL.hasPrefix("data:image/png;base64,"))
            let thumbnail = try XCTUnwrap(CGImageSourceCreateWithData(imported.thumbnailData as CFData, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(thumbnail, 0, nil))
            if type == .png {
                XCTAssertEqual(Data(base64Encoded: String(imported.dataURL.dropFirst("data:image/png;base64,".count))), data as Data)
            }
            let pasted = try await DesktopDocumentImport.readImageData(data as Data, name: "粘贴图片." + type.preferredFilenameExtension!)
            XCTAssertNil(pasted.sourceURL)
            XCTAssertEqual(pasted.image, imported)
            XCTAssertEqual(pasted.name, "粘贴图片.png")
            XCTAssertEqual(pasted.byteCount, Data(base64Encoded: String(imported.dataURL.dropFirst("data:image/png;base64,".count)))?.count)
        }
    }

    func testPDFTextExtractionAndScannedDocumentFailure() async throws {
        let conversation = DesktopConversation(title: "PDF 源", messages: [DesktopMessage(role: .assistant, text: "可以提取的中文与数值 987")])
        let url = temporary("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try await DesktopConversationExport.writePDF(conversation, to: url)
        let document = try await DesktopDocumentImport.read(url)
        XCTAssertEqual(document.kind, .pdf)
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.text.contains("987"))
        let blank = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: blank)), mediaBox: &box, nil))
        context.beginPDFPage(nil); context.fill(box); context.endPDFPage(); context.closePDF()
        try (blank as Data).write(to: url)
        do { _ = try await DesktopDocumentImport.read(url); XCTFail("Scans must not appear as extracted text") }
        catch { XCTAssertTrue(error.localizedDescription.contains("扫描件")) }
    }

    func testReadableExportsKeepSelectedPathAndPaginateRealPDF() async throws {
        let uniqueEnd = "最终完整内容 24680"
        let conversation = DesktopConversation(title: "导出验收", messages: [
            DesktopMessage(role: .user, text: "问题"),
            DesktopMessage(role: .assistant, text: "## 结果\n\n" + String(repeating: "这是一段应分页且可提取的文字。\n\n", count: 220) + uniqueEnd,
                reasoning: "保留思考", state: .cancelled, unsupportedPartCount: 2),
        ])
        let markdown = DesktopConversationExport.markdown(conversation)
        XCTAssertTrue(markdown.contains("# 导出验收"))
        XCTAssertTrue(markdown.contains("保留思考"))
        XCTAssertTrue(markdown.contains("2 项未渲染内容"))
        XCTAssertTrue(markdown.contains("已停止"))
        let data = try DesktopConversationExport.pdfData(conversation)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains(uniqueEnd) == true)
        XCTAssertTrue(pdf.string?.contains("保留思考") == true)
        let url = temporary("md")
        defer { try? FileManager.default.removeItem(at: url) }
        try await DesktopConversationExport.writeMarkdown(conversation, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), markdown)
    }

    func testImageOnlyAndMixedMessagesKeepActualMarkdownImagesAndExplicitPDFLinks() throws {
        let conversation = DesktopConversation(title: "图片导出", messages: [
            DesktopMessage(role: .user, text: "", images: [.init(url: "data:image/png;base64,AA==", name: "原图.png")]),
            DesktopMessage(role: .user, text: "请比较这张图", images: [.init(url: "https://example.com/a.png", name: nil)]),
        ])
        let markdown = DesktopConversationExport.markdown(conversation)
        XCTAssertTrue(markdown.contains("原图.png"))
        XCTAssertTrue(markdown.contains("图片 1"))
        XCTAssertTrue(markdown.contains("![原图.png](<data:image/png;base64,AA==>)"))
        XCTAssertTrue(markdown.contains("![图片 1](<https://example.com/a.png>)"))
        let pdf = try XCTUnwrap(PDFDocument(data: DesktopConversationExport.pdfData(conversation)))
        XCTAssertTrue(pdf.string?.contains("原图.png") == true)
        XCTAssertTrue(pdf.string?.contains("https://example.com/a.png") == true)
        XCTAssertTrue(pdf.string?.contains("无法解码") == true)
        XCTAssertTrue(pdf.string?.contains("完整会话 JSON") == true)
    }

    func testReadablePDFEmbedsRealImagePixelsAndKeepsFollowingText() throws {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 2400, height: 4000, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 2400, height: 4000))
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let dataURL = "data:image/png;base64," + (png as Data).base64EncodedString()
        let conversation = DesktopConversation(title: "原图导出", messages: [
            DesktopMessage(role: .user, text: "请看这张图", images: [.init(url: dataURL, name: "红色原图.png")]),
            DesktopMessage(role: .assistant, text: "图片之后的完整内容 24680"),
        ])
        XCTAssertTrue(DesktopConversationExport.markdown(conversation).contains(dataURL))
        let data = try DesktopConversationExport.pdfData(conversation)
        let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
        let readablePDF = try XCTUnwrap(PDFDocument(data: data))
        var redPixels = 0, embeddedPixelSizes: [Int] = []
        for page in 1...document.numberOfPages {
            let beforeImages = embeddedPixelSizes.count
            let pdfPage = try XCTUnwrap(document.page(at: page))
            var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(pdfPage.dictionary!, "Resources", &resources))
            if let resources, CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects {
                withUnsafeMutablePointer(to: &embeddedPixelSizes) { sizes in
                    CGPDFDictionaryApplyFunction(objects, { _, object, rawSizes in
                        var stream: CGPDFStreamRef?
                        guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
                        var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                        if CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height) {
                            rawSizes!.assumingMemoryBound(to: [Int].self).pointee.append(max(width, height))
                        }
                    }, sizes)
                }
            }
            let pageText = readablePDF.page(at: page - 1)?.string ?? ""
            if pageText.contains("红色原图.png") {
                XCTAssertGreaterThan(embeddedPixelSizes.count, beforeImages, "An image caption must stay on the same page as its image.")
            }
            if pageText.contains("Amber\n") { XCTAssertTrue(pageText.contains("24680"), "A role heading must stay with the following message.") }
            let rendered = try XCTUnwrap(CGContext(data: nil, width: 595, height: 842, bitsPerComponent: 8,
                bytesPerRow: 595 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            rendered.drawPDFPage(try XCTUnwrap(document.page(at: page)))
            let pixels = try XCTUnwrap(rendered.data).assumingMemoryBound(to: UInt8.self)
            for pixel in 0..<(595 * 842) where pixels[pixel * 4] > 200 && pixels[pixel * 4 + 1] < 50 && pixels[pixel * 4 + 2] < 50 {
                redPixels += 1
            }
        }
        XCTAssertFalse(embeddedPixelSizes.isEmpty)
        XCTAssertLessThanOrEqual(embeddedPixelSizes.max() ?? Int.max, 1_950, "Large source images must be downsampled to the PDF presentation size.")
        XCTAssertGreaterThan(redPixels, 100_000, "The PDF must draw actual image pixels, rather than only an image caption.")
        let readable = readablePDF.string ?? ""
        XCTAssertTrue(readable.contains("红色原图.png"))
        XCTAssertTrue(readable.contains("24680"))
    }

    func testGeneratedImageArtifactsKeepCapturedOwnerAndActualImageEncoding() async throws {
        let root = temporary("workspace")
        let source = temporary("bin")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let tiff = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        try (tiff as Data).write(to: source)
        let files = DesktopWorkspaceFiles(directory: root), owner = UUID(), other = UUID()
        let first = try await files.importGeneratedImage(conversationID: owner, from: source)
        let second = try await files.importGeneratedImage(conversationID: owner, from: source)
        XCTAssertEqual(first.document.name, first.file.name)
        XCTAssertTrue(first.file.name.hasSuffix(".png"))
        XCTAssertNil(first.document.sourceURL)
        XCTAssertEqual(first.document.image?.mimeType, "image/png")
        XCTAssertNotEqual(first.file.id, second.file.id)
        let bytes = try await files.read(conversationID: owner, path: first.file.id)
        XCTAssertEqual(first.document.byteCount, bytes.count)
        XCTAssertEqual(first.document.image?.dataURL, "data:image/png;base64," + bytes.base64EncodedString())
        let untouched = try await files.list(conversationID: other)
        XCTAssertTrue(untouched.isEmpty)
        try await files.removeConversation(owner)
        do {
            _ = try await files.importGeneratedImage(conversationID: owner, from: source)
            XCTFail("A deleted owner must never receive late generation output.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("已删除")) }
    }
}
