import Foundation
import PDFKit
import UniformTypeIdentifiers

/// The standalone target keeps the same pure document payload consumed by the
/// shared source normalizer; it has no dependency on chat/tool document grants.
struct SelectedDocumentReadResult: Hashable, Sendable {
    let fileName: String
    let fileType: String
    let totalBytes: Int64
    let bytesRead: Int
    let characterCount: Int
    let preview: String
    let isTruncated: Bool
    let note: String?
}

enum DocumentAccessError: LocalizedError, Equatable {
    case missingGrant, grantMismatch, expiredGrant, fileMissing, fileTooLarge
    case unknownFileSize, alreadyReading
    case unsupportedFileType(String)
    case noReadableText(String)
    case readFailed(String)

    var errorDescription: String? { IOSDeepReadUserFacingText.fromError(self) }
}

enum DeepReadFileImporter {
    static let maxReadableBytes = 20 * 1024 * 1024
    static let maxSourceCharacters = 40_000
    static let supportedTypes: [UTType] = [
        .plainText, .utf8PlainText, .json, .commaSeparatedText, .pdf,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "docx") ?? .data
    ]

    /// Only URLs explicitly chosen by the user are passed here. The security
    /// scope stays open until the detached read completes, and is never persisted.
    static func read(url: URL) async throws -> IOSDeepReadSource {
        let preview = try await preview(url: url)
        return try IOSDeepReadSourceNormalizer.fileSource(preview)
    }

    static func preview(url: URL) async throws -> SelectedDocumentReadResult {
        try await Task.detached(priority: .utility) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path) else { throw DocumentAccessError.fileMissing }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
                throw DocumentAccessError.unknownFileSize
            }
            guard size <= maxReadableBytes else { throw DocumentAccessError.fileTooLarge }
            let ext = url.pathExtension.lowercased()
            let text: String
            var truncated = false
            switch ext {
            case "pdf":
                let result = try readPDF(url: url)
                text = result.text
                truncated = result.truncated
            case "docx":
                text = try readDOCX(url: url)
            case "txt", "md", "markdown", "json", "csv", "tsv", "log", "xml", "html", "htm", "yaml", "yml":
                let data = try Data(contentsOf: url)
                guard let decoded = decodeText(data) else {
                    throw DocumentAccessError.unsupportedFileType("此文件不是可解码的文本，无法作为文件上下文读取。")
                }
                text = decoded
            default:
                throw DocumentAccessError.unsupportedFileType("支持 txt、md、json、csv、pdf、docx 文本文件。")
            }
            let normalized = normalizeText(text)
            guard !normalized.isEmpty else { throw DocumentAccessError.noReadableText("文件中没有可读取文本。") }
            truncated = truncated || normalized.count > maxSourceCharacters
            let content = String(normalized.prefix(maxSourceCharacters))
            return SelectedDocumentReadResult(
                fileName: url.lastPathComponent,
                fileType: UTType(filenameExtension: ext)?.preferredMIMEType ?? ext,
                totalBytes: size, bytesRead: Int(size), characterCount: content.count,
                preview: content, isTruncated: truncated,
                note: truncated ? "内容已截断：每个来源最多保存 \(maxSourceCharacters) 字符。" : nil
            )
        }.value
    }

    private static func readPDF(url: URL) throws -> (text: String, truncated: Bool) {
        guard let document = PDFDocument(url: url) else {
            throw DocumentAccessError.unsupportedFileType("无法打开此 PDF 文件。")
        }
        var chunks: [String] = []
        var characters = 0
        var truncated = false
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            chunks.append(text)
            characters += text.count + 2
            if characters > maxSourceCharacters { truncated = true; break }
        }
        guard !chunks.isEmpty else {
            throw DocumentAccessError.noReadableText("PDF 中没有可提取文本；扫描版 PDF 需要 OCR。")
        }
        return (chunks.joined(separator: "\n\n"), truncated)
    }

    private static func readDOCX(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let entryNames = ["word/document.xml", "word/footnotes.xml", "word/endnotes.xml"]
        let chunks = try entryNames.compactMap { name -> String? in
            guard let entry = try DeepReadDocumentZipReader.entry(named: name, in: data),
                  let xml = String(data: entry, encoding: .utf8) else { return nil }
            return extractDOCXText(xml)
        }
        guard !chunks.isEmpty else {
            throw DocumentAccessError.noReadableText("DOCX 中没有找到 word/document.xml，无法提取正文。")
        }
        return chunks.joined(separator: "\n\n")
    }

    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        return String(data: data, encoding: gb18030)
    }

    private static func normalizeText(_ text: String) -> String {
        IOSDeepReadSourceNormalizer.cleanMultiline(text.replacingOccurrences(of: "\u{0}", with: ""))
    }

    private static func extractDOCXText(_ xml: String) -> String {
        let prepared = xml
            .replacingOccurrences(of: "<w:tab/>", with: "<w:t>\t</w:t>")
            .replacingOccurrences(of: "<w:tab />", with: "<w:t>\t</w:t>")
            .replacingOccurrences(of: "<w:br/>", with: "<w:t>\n</w:t>")
            .replacingOccurrences(of: "<w:br />", with: "<w:t>\n</w:t>")
            .replacingOccurrences(of: "</w:p>", with: "<w:t>\n</w:t>")
            .replacingOccurrences(of: "</w:tr>", with: "<w:t>\n</w:t>")
        guard let regex = try? NSRegularExpression(pattern: #"<w:t(?:\s[^>]*)?>(.*?)</w:t>"#,
                                                  options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return "" }
        let pieces = regex.matches(in: prepared, range: NSRange(prepared.startIndex..., in: prepared))
            .compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: prepared) else { return nil }
                return decodeXMLEntities(String(prepared[range]))
            }
        return normalizeText(pieces.joined())
    }

    private static func decodeXMLEntities(_ text: String) -> String {
        var decoded = text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) else { return decoded }
        for match in regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)).reversed() {
            guard let fullRange = Range(match.range(at: 0), in: decoded),
                  let valueRange = Range(match.range(at: 1), in: decoded) else { continue }
            let value = String(decoded[valueRange])
            let hex = value.lowercased().hasPrefix("x")
            guard let code = UInt32(hex ? String(value.dropFirst()) : value, radix: hex ? 16 : 10),
                  let scalar = UnicodeScalar(code) else { continue }
            decoded.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return decoded
    }
}
