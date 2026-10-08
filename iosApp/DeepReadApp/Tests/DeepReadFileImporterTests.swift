import XCTest
import UIKit
@testable import AmberDeepRead

@MainActor
final class DeepReadFileImporterTests: XCTestCase {
    private func file(ext: String, data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url)
        return url
    }

    func testUTF16TextCreatesUsableFileSource() async throws {
        let url = try file(ext: "txt", data: try XCTUnwrap("中文文件\n第二段".data(using: .utf16)))
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await DeepReadFileImporter.read(url: url)
        XCTAssertEqual(source.kind, .file)
        XCTAssertEqual(source.content, "中文文件\n第二段")
        XCTAssertEqual(source.metadata["truncated"], "false")
        XCTAssertTrue(source.hasUsableGenerationContent)
    }

    func testCSVAndJSONRemainLiteralSourceText() async throws {
        for (ext, text) in [("csv", "姓名,结果\n甲,完成"), ("json", #"{"主题":"中文"}"#)] {
            let url = try file(ext: ext, data: Data(text.utf8))
            defer { try? FileManager.default.removeItem(at: url) }
            let source = try await DeepReadFileImporter.read(url: url)
            XCTAssertEqual(source.content, text)
        }
    }

    func testGB18030DecodesChineseAndKeepsParagraphBreak() async throws {
        // Literal bytes from GB18030, so encoding support cannot fake this
        // decoder test by quietly creating a UTF-8 fixture.
        let data = Data([214, 208, 206, 196, 215, 202, 193, 207, 10, 181, 218, 182, 254, 182, 206])
        let url = try file(ext: "txt", data: data)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await DeepReadFileImporter.read(url: url)
        XCTAssertEqual(source.content, "中文资料\n第二段")
    }

    func testTruncationMetadataMatchesPersistedSourceLimit() async throws {
        let url = try file(ext: "md", data: Data(String(repeating: "文", count: 40_010).utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await DeepReadFileImporter.read(url: url)
        XCTAssertEqual(source.content.count, 40_000)
        XCTAssertEqual(source.metadata["truncated"], "true")
        let preview = try await DeepReadFileImporter.preview(url: url)
        XCTAssertTrue(preview.note?.contains("截断") == true)
    }

    func testPDFExtractsSelectableText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            ("Selectable PDF source" as NSString).draw(at: CGPoint(x: 48, y: 48), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
        let source = try await DeepReadFileImporter.read(url: url)
        XCTAssertTrue(source.content.contains("Selectable PDF source"))
        XCTAssertEqual(source.kind, .file)
    }

    func testCompressedDOCXExtractsChineseBody() async throws {
        // ZIP_DEFLATED document.xml from a standard ZIP writer, rather than an
        // uncompressed fixture that would skip the production decompression path.
        let compressed = "UEsDBBQAAAAIAMi6Ql2OxC+wNQAAAEkAAAARAAAAd29yZC9kb2N1bWVudC54bWyzKbdKyU8uzU3NK7GzKbcqABFFIKLE7mn/+hfLFz/t6362dvGzae02+iBBEFkEJgvAJFwzAFBLAQIUAxQAAAAIAMi6Ql2OxC+wNQAAAEkAAAARAAAAAAAAAAAAAACAAQAAAAB3b3JkL2RvY3VtZW50LnhtbFBLBQYAAAAAAQABAD8AAABkAAAAAAA="
        let url = try file(ext: "docx", data: try XCTUnwrap(Data(base64Encoded: compressed)))
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await DeepReadFileImporter.read(url: url)
        XCTAssertEqual(source.content, "可解压正文")
        XCTAssertTrue(source.hasUsableGenerationContent)
    }

    func testDOCXPreservesParagraphBreaksAndIncludesFootnotes() async throws {
        let compressed = "UEsDBBQAAAAIACS8Ql0sDJEePAAAAHkAAAARAAAAd29yZC9kb2N1bWVudC54bWyzKbdKyU8uzU3NK7GzKbcqABFFIKLE7tnaxc+mtT9fs+bJjoZn67ba6IMEQWQRmCzArX5XD3b1+kiWAQBQSwMEFAAAAAgAJLxCXTbn9/YwAAAARQAAABIAAAB3b3JkL2Zvb3Rub3Rlcy54bWyzKbdKy88vycsvSS22sym3KgARRSCixO5Fy6xnm1c8W7fVRh/EBZFFYLIATCL0AQBQSwECFAMUAAAACAAkvEJdLAyRHjwAAAB5AAAAEQAAAAAAAAAAAAAAgAEAAAAAd29yZC9kb2N1bWVudC54bWxQSwECFAMUAAAACAAkvEJdNuf39jAAAABFAAAAEgAAAAAAAAAAAAAAgAFrAAAAd29yZC9mb290bm90ZXMueG1sUEsFBgAAAAACAAIAfwAAAMsAAAAAAA=="
        let url = try file(ext: "docx", data: try XCTUnwrap(Data(base64Encoded: compressed)))
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await DeepReadFileImporter.read(url: url)
        XCTAssertEqual(source.content, "正文第一段\n正文第二段\n\n脚注段")
    }

    func testUnsupportedFilesReturnReadableError() async throws {
        let url = try file(ext: "png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await DeepReadFileImporter.read(url: url)
            XCTFail("Unsupported image must not become a fabricated source")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("支持"))
        }
    }

    func testImageOnlyPDFDoesNotPretendToHaveOCRText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 20, y: 20, width: 160, height: 160))
        }
        do {
            _ = try await DeepReadFileImporter.read(url: url)
            XCTFail("Image-only PDF must report missing text")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("OCR"))
        }
    }
}
