import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import zlib

struct DesktopImportedDocument: Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, pdf, document, presentation, image }
    struct Image: Equatable, Sendable {
        let dataURL: String
        let thumbnailData: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let mimeType: String
    }
    let id: UUID
    let name: String
    let sourceURL: URL?
    let kind: Kind
    let byteCount: Int
    let text: String
    let image: Image?
    let pageCount: Int?
    let note: String?
}

enum DesktopDocumentImport {
    static let maximumFileBytes = 32 * 1_024 * 1_024

    static func read(_ url: URL) async throws -> DesktopImportedDocument {
        let task = Task.detached(priority: .userInitiated) { try readSynchronously(url) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func readImageData(_ data: Data, name: String) async throws -> DesktopImportedDocument {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard data.count <= maximumFileBytes else { throw failure("图片超过 32 MB 导入上限。") }
            let result = try readImage(data)
            let image = result.image
            let suffix = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"][image.mimeType] ?? "png"
            let base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            let filename = (base.isEmpty ? "粘贴图片" : base) + "." + suffix
            try Task.checkCancellation()
            return DesktopImportedDocument(id: UUID(), name: filename, sourceURL: nil, kind: .image,
                byteCount: result.byteCount, text: "", image: image, pageCount: nil, note: nil)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func readSynchronously(_ url: URL) throws -> DesktopImportedDocument {
        try Task.checkCancellation()
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw failure("请选择普通文件。") }
        if let size = values.fileSize {
            guard size <= maximumFileBytes else { throw failure("文件超过 32 MB 导入上限。") }
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumFileBytes else { throw failure("文件超过 32 MB 导入上限。") }
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        var kind: DesktopImportedDocument.Kind = .text
        var text = ""
        var image: DesktopImportedDocument.Image?
        var pages: Int?
        var note: String?
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"].contains(ext) || type?.conforms(to: .image) == true {
            kind = .image
            image = try readImage(data).image
        } else if ext == "pdf" {
            kind = .pdf
            guard let pdf = PDFDocument(data: data) else { throw failure("无法打开这个 PDF 文件。") }
            guard !pdf.isLocked else { throw failure("PDF 已加密，请解锁后再导入。") }
            pages = pdf.pageCount
            var sections: [String] = []
            var emptyPages = 0
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                let pageText = pdf.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if pageText.isEmpty { emptyPages += 1 }
                else { sections.append("[第 \(index + 1) 页]\n\(pageText)") }
            }
            guard !sections.isEmpty else { throw failure("PDF 没有可提取文字，可能是扫描件；当前导入不会自动执行 OCR。") }
            text = sections.joined(separator: "\n\n")
            if emptyPages > 0 { note = "\(emptyPages) 页没有可提取文字；这些页面未进入文本上下文。" }
        } else if ext == "pptx" {
            kind = .presentation
            let result = try readPresentation(data)
            text = result.text
            pages = result.pages
            if result.emptyPages > 0 { note = "\(result.emptyPages) 张幻灯片没有可提取文字。" }
        } else if ["doc", "docx", "rtf"].contains(ext) {
            kind = .document
            let documentType: NSAttributedString.DocumentType = ext == "docx" ? .officeOpenXML : ext == "doc" ? .docFormat : .rtf
            text = try NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil).string
        } else if ["html", "htm"].contains(ext) {
            kind = .document
            guard let decoded = decodeText(data) else { throw failure("HTML 不是可识别的文本编码。") }
            let html = try XMLDocument(xmlString: decoded, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
            text = html.rootElement().map(htmlText) ?? ""
        } else {
            guard type?.conforms(to: .text) == true || ["txt", "text", "md", "markdown", "json", "jsonl", "csv", "log", "yaml", "yml", "toml", "swift", "kt", "py", "js", "ts", "tsx", "jsx", "sh", "sql", "xml"].contains(ext) else {
                throw failure("暂不支持此格式。可导入文字、PDF、DOC/DOCX/RTF、PPTX 或图片。")
            }
            guard let decoded = decodeText(data), !decoded.contains("\0") else { throw failure("文件不是可识别的文本编码。") }
            text = decoded
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard image != nil || !text.isEmpty else { throw failure("文件中没有可读取的文字。") }
        try Task.checkCancellation()
        return DesktopImportedDocument(id: UUID(), name: url.lastPathComponent, sourceURL: url, kind: kind,
            byteCount: data.count, text: text, image: image, pageCount: pages, note: note)
    }

    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if let text = String(data: data, encoding: .utf8) { return text }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: encoding)
    }

    private static func htmlText(_ node: XMLNode) -> String {
        if node.kind == .text { return node.stringValue ?? "" }
        let name = node.name?.lowercased() ?? ""
        if ["head", "script", "style"].contains(name) { return "" }
        let text = (node.children ?? []).map(htmlText).joined()
        return text + (["p", "div", "li", "br", "h1", "h2", "h3", "tr", "section"].contains(name) ? "\n" : "")
    }

    private static func readImage(_ data: Data) throws -> (image: DesktopImportedDocument.Image, byteCount: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { throw failure("图片无法解码，请选择有效的图片文件。") }
        let thumbnailData = try png(thumbnail)
        let mime: String
        let original: Data
        let supportedMimes = ["public.png": "image/png", "public.jpeg": "image/jpeg", "com.compuserve.gif": "image/gif", "org.webmproject.webp": "image/webp"]
        var outputWidth = width
        var outputHeight = height
        if let supportedMime = supportedMimes[identifier as String] {
            mime = supportedMime
            original = data
        } else {
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary) else {
                throw failure("此图片格式无法转换为模型可用的 PNG。")
            }
            mime = "image/png"
            original = try png(decoded)
            outputWidth = decoded.width
            outputHeight = decoded.height
        }
        return (.init(dataURL: "data:\(mime);base64,\(original.base64EncodedString())", thumbnailData: thumbnailData,
            pixelWidth: outputWidth, pixelHeight: outputHeight, mimeType: mime), original.count)
    }

    private static func png(_ image: CGImage) throws -> Data {
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
            throw failure("无法创建图片预览。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure("图片转换失败。") }
        return result as Data
    }

    private static func readPresentation(_ data: Data) throws -> (text: String, pages: Int, emptyPages: Int) {
        let archive = try DesktopOfficeArchive(data)
        guard let presentation = try archive.entry("ppt/presentation.xml"),
              let relationships = try archive.entry("ppt/_rels/presentation.xml.rels") else {
            throw failure("PPTX 缺少演示文稿目录，无法确认幻灯片顺序。")
        }
        let ids = DesktopOfficeXML(mode: .presentation)
        try ids.parse(presentation)
        let targets = DesktopOfficeXML(mode: .relationships)
        try targets.parse(relationships)
        guard !ids.ids.isEmpty else { throw failure("PPTX 中没有幻灯片。") }
        var sections: [String] = []
        var empty = 0
        for (index, id) in ids.ids.enumerated() {
            try Task.checkCancellation()
            guard let target = targets.targets[id] else { throw failure("PPTX 幻灯片引用不完整。") }
            let name = target.hasPrefix("/") ? String(target.dropFirst()) : ("ppt/" + target as NSString).standardizingPath
            guard name.hasPrefix("ppt/"), let slide = try archive.entry(name) else { throw failure("PPTX 中的幻灯片文件缺失。") }
            let content = DesktopOfficeXML(mode: .text)
            try content.parse(slide)
            let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { empty += 1 }
            else { sections.append("[第 \(index + 1) 张幻灯片]\n\(text)") }
        }
        guard !sections.isEmpty else { throw failure("PPTX 没有可提取文字；图片中的内容不会被自动识别。") }
        return (sections.joined(separator: "\n\n"), ids.ids.count, empty)
    }

    fileprivate static func failure(_ message: String) -> DesktopRuntimeError { .message(message) }
}

/// Extracts file URLs or raw image payloads from `NSPasteboard` for ⌘V in the composer.
/// File URLs always win over image types because Finder writes a file icon TIFF alongside `.fileURL`.
enum DesktopPasteboardImport {
    static func isPasteShortcut(modifierFlags: NSEvent.ModifierFlags, charactersIgnoringModifiers: String?, keyCode: UInt16) -> Bool {
        let modifiers = modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == [.command] else { return false }
        if let chars = charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
            return chars == "v"
        }
        return keyCode == 9
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] {
            urls.append(contentsOf: objects.map { $0 as URL }.filter(\.isFileURL))
        }
        if urls.isEmpty {
            for item in pasteboard.pasteboardItems ?? [] {
                if let data = item.data(forType: .fileURL),
                   let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true),
                   url.isFileURL {
                    urls.append(url)
                } else if let string = item.string(forType: .fileURL),
                          let url = URL(string: string),
                          url.isFileURL {
                    urls.append(url)
                }
            }
        }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0.standardizedFileURL).inserted }
    }

    static func imagePayload(from pasteboard: NSPasteboard) -> (data: Data, name: String)? {
        let preferredTypes: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "剪贴板图片.png"),
            (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "剪贴板图片.jpg"),
            (NSPasteboard.PasteboardType(UTType.gif.identifier), "剪贴板图片.gif"),
            (NSPasteboard.PasteboardType(UTType.webP.identifier), "剪贴板图片.webp"),
            (.tiff, "剪贴板图片.tiff"),
        ]
        for (type, name) in preferredTypes {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return (data, name)
            }
            if let data = pasteboard.pasteboardItems?.lazy.compactMap({ $0.data(forType: type) }).first(where: { !$0.isEmpty }) {
                return (data, name)
            }
        }
        let allTypes = (pasteboard.types ?? []) + (pasteboard.pasteboardItems?.flatMap(\.types) ?? [])
        for type in allTypes {
            guard let imageType = UTType(type.rawValue), imageType.conforms(to: .image) else { continue }
            let data = pasteboard.data(forType: type)
                ?? pasteboard.pasteboardItems?.lazy.compactMap({ $0.data(forType: type) }).first
            if let data, !data.isEmpty {
                return (data, "剪贴板图片." + (imageType.preferredFilenameExtension ?? "png"))
            }
        }
        return nil
    }
}

private final class DesktopOfficeXML: NSObject, XMLParserDelegate {
    enum Mode { case presentation, relationships, text }
    let mode: Mode
    var ids: [String] = []
    var targets: [String: String] = [:]
    var text = ""
    private var readingText = false
    init(mode: Mode) { self.mode = mode }
    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else { throw DesktopDocumentImport.failure("Office 文档中的 XML 已损坏。") }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch mode {
        case .presentation:
            if name == "sldId", let id = attributes.first(where: { $0.key.hasSuffix(":id") })?.value { ids.append(id) }
        case .relationships:
            if name == "Relationship", attributes["TargetMode"] != "External", let id = attributes["Id"], let target = attributes["Target"] { targets[id] = target }
        case .text:
            if name == "t" { readingText = true }
            if name == "br" { text += "\n" }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if readingText { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "t" { readingText = false }
        if mode == .text, name == "p" { text += "\n" }
    }
}

// Adapted from this repository's IOSDocumentZipReader. No paths are extracted to disk.
private struct DesktopOfficeArchive {
    struct Entry { let method: UInt16; let offset: Int; let compressed: Int; let expanded: Int; let crc: UInt32 }
    let data: Data
    var entries: [String: Entry] = [:]
    init(_ data: Data) throws {
        self.data = data
        guard let end = data.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards,
            in: max(0, data.count - 65_557)..<data.count)?.lowerBound,
            try data.officeUInt16(end + 4) == 0, try data.officeUInt16(end + 6) == 0,
            end + 22 + Int(try data.officeUInt16(end + 20)) == data.count else { throw Self.badArchive() }
        let count = Int(try data.officeUInt16(end + 10))
        var cursor = Int(try data.officeUInt32(end + 16))
        guard count < 65_535, cursor < end else { throw Self.badArchive() }
        for _ in 0..<count {
            guard try data.officeUInt32(cursor) == 0x02014b50,
                  try data.officeUInt16(cursor + 8) & 1 == 0 else { throw Self.badArchive() }
            let nameLength = Int(try data.officeUInt16(cursor + 28))
            let extraLength = Int(try data.officeUInt16(cursor + 30))
            let commentLength = Int(try data.officeUInt16(cursor + 32))
            let nameStart = cursor + 46
            let next = nameStart + nameLength + extraLength + commentLength
            guard next <= end, let name = String(data: data[nameStart..<(nameStart + nameLength)], encoding: .utf8) else { throw Self.badArchive() }
            let expanded = Int(try data.officeUInt32(cursor + 24))
            guard expanded <= 64 * 1_024 * 1_024 else { throw DesktopDocumentImport.failure("Office 文档单个文本条目超过 64 MB，无法导入。") }
            entries[name] = Entry(method: try data.officeUInt16(cursor + 10), offset: Int(try data.officeUInt32(cursor + 42)),
                compressed: Int(try data.officeUInt32(cursor + 20)), expanded: expanded, crc: try data.officeUInt32(cursor + 16))
            cursor = next
        }
    }
    func entry(_ name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        guard try data.officeUInt32(entry.offset) == 0x04034b50 else { throw Self.badArchive() }
        let start = entry.offset + 30 + Int(try data.officeUInt16(entry.offset + 26)) + Int(try data.officeUInt16(entry.offset + 28))
        let end = start + entry.compressed
        guard start >= 0, end <= data.count else { throw Self.badArchive() }
        let compressed = Data(data[start..<end])
        let result: Data
        switch entry.method {
        case 0: result = compressed
        case 8:
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Self.badArchive() }
            defer { inflateEnd(&stream) }
            var output = Data(count: max(entry.expanded, 1))
            let status = output.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.expanded else { throw Self.badArchive() }
            result = Data(output.prefix(entry.expanded))
        default: throw DesktopDocumentImport.failure("Office 文档使用了暂不支持的 ZIP 压缩方式。")
        }
        let checksum = result.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(result.count)) }
        guard result.count == entry.expanded, UInt32(truncatingIfNeeded: checksum) == entry.crc else { throw Self.badArchive() }
        return result
    }
    private static func badArchive() -> DesktopRuntimeError { DesktopDocumentImport.failure("Office 文档 ZIP 已损坏、加密或使用了不支持的格式。") }
}

private extension Data {
    func officeUInt16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else { throw DesktopDocumentImport.failure("Office 文档 ZIP 读取越界。") }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func officeUInt32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else { throw DesktopDocumentImport.failure("Office 文档 ZIP 读取越界。") }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
