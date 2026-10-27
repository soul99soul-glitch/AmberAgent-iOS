import AppKit
import CoreText
import Foundation
import ImageIO

enum DesktopReadableExportFormat: CaseIterable, Sendable {
    case markdown, pdf
    var fileExtension: String { self == .markdown ? "md" : "pdf" }
}

extension DesktopConversationExport {
    static func markdown(_ conversation: DesktopConversation) -> String {
        let title = conversation.title.replacingOccurrences(of: "\n", with: " ")
        let messages = conversation.messages.map { message in
            var sections = ["## " + roleTitle(message.role)]
            if !message.reasoning.isEmpty { sections.append("### 思考过程\n\n" + message.reasoning) }
            if !message.text.isEmpty { sections.append(message.text) }
            for (index, image) in message.images.enumerated() {
                let name = imageName(image, index: index).replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "[", with: "\\[")
                    .replacingOccurrences(of: "\n", with: " ")
                let url = image.url.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
                    .replacingOccurrences(of: "\n", with: "%0A").replacingOccurrences(of: "\r", with: "%0D")
                sections.append("![\(name)](<\(url)>)")
            }
            if message.unsupportedPartCount > 0 { sections.append("> 另有 \(message.unsupportedPartCount) 项未渲染内容；请使用完整会话 JSON 保留其原始数据。") }
            if message.state == .cancelled { sections.append("> 已停止；以上为已收到内容。") }
            if message.state == .failed { sections.append("> 生成未完成。") }
            if message.state == .streaming { sections.append("> 生成中；本次导出为当前快照。") }
            return sections.joined(separator: "\n\n")
        }
        return (["# " + title] + messages).joined(separator: "\n\n---\n\n") + "\n"
    }

    static func writeMarkdown(_ conversation: DesktopConversation, to url: URL) async throws {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try Data(markdown(conversation).utf8).write(to: url, options: .atomic)
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func markdown(_ message: DesktopMessage, title: String) -> String {
        markdown(DesktopConversation(title: title, messages: [message]))
    }

    static func writeMarkdown(_ message: DesktopMessage, title: String, to url: URL) async throws {
        try await writeMarkdown(DesktopConversation(title: title, messages: [message]), to: url)
    }

    static func writePDF(_ conversation: DesktopConversation, to url: URL) async throws {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try pdfData(conversation)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func pdfData(_ conversation: DesktopConversation) throws -> Data {
        let text = printableText(conversation)
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox,
                [kCGPDFContextTitle: conversation.title, kCGPDFContextCreator: "Amber"] as CFDictionary) else {
            throw DesktopRuntimeError.message("无法创建 PDF 文档。")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: mediaBox.insetBy(dx: 48, dy: 54), transform: nil)
        var offset = 0
        var page = 1
        while offset < text.length {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            let frame = paginatedFrame(framesetter, text: text, offset: offset, path: path)
            CTFrameDraw(frame, context)
            drawImages(in: frame, context: context)
            let range = CTFrameGetVisibleStringRange(frame)
            guard range.length > 0 else { context.endPDFPage(); context.closePDF(); throw DesktopRuntimeError.message("PDF 文本排版失败。") }
            offset += range.length
            context.textPosition = CGPoint(x: 48, y: 28)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Amber · \(page)", attributes: attributes(size: 9, color: 0.45))), context)
            context.endPDFPage()
            page += 1
        }
        context.closePDF()
        return data as Data
    }

    private static func printableText(_ conversation: DesktopConversation) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: conversation.title + "\n\n", attributes: attributes(size: 23, bold: true)))
        for message in conversation.messages {
            var roleStyle = attributes(size: 13, bold: true)
            roleStyle[keepWithNextKey] = true
            result.append(NSAttributedString(string: roleTitle(message.role) + "\n", attributes: roleStyle))
            if !message.reasoning.isEmpty {
                result.append(NSAttributedString(string: "思考过程\n" + message.reasoning + "\n\n", attributes: attributes(size: 10, color: 0.4)))
            }
            appendBlocks(DesktopMarkdownParser.parse(message.text), to: result)
            appendImages(message.images, to: result)
            if message.unsupportedPartCount > 0 {
                result.append(NSAttributedString(string: "另有 \(message.unsupportedPartCount) 项未渲染内容；原始数据请见完整会话 JSON。\n", attributes: attributes(size: 10, color: 0.4)))
            }
            if message.state != .complete {
                let state = message.state == .cancelled ? "已停止，保留已收到内容。" : message.state == .failed ? "生成未完成。" : "生成中，当前快照。"
                result.append(NSAttributedString(string: state + "\n", attributes: attributes(size: 10, color: 0.4)))
            }
            result.append(NSAttributedString(string: "\n\n", attributes: attributes(size: 11)))
        }
        return result
    }

    private static func appendBlocks(_ blocks: [DesktopMarkdownBlock], to result: NSMutableAttributedString, quoteLevel: Int = 0) {
        for block in blocks {
            switch block {
            case .paragraph(let value): appendInline(value + "\n\n", to: result, indent: quoteLevel * 14)
            case .heading(let value, let level): appendInline(value + "\n\n", to: result, size: level == 1 ? 20 : level == 2 ? 17 : 14, bold: true, indent: quoteLevel * 14)
            case .code(let value, let language):
                if !language.isEmpty { result.append(NSAttributedString(string: language + "\n", attributes: attributes(size: 9, color: 0.4))) }
                result.append(NSAttributedString(string: value + "\n\n", attributes: attributes(size: 10, monospaced: true, indent: quoteLevel * 14)))
            case .math(let value):
                result.append(NSAttributedString(string: "$$\n" + value + "\n$$\n\n", attributes: attributes(size: 11, monospaced: true)))
            case .list(let items):
                for item in items { appendInline(item.marker + " " + item.text + "\n", to: result, indent: quoteLevel * 14 + item.level * 14) }
                result.append(NSAttributedString(string: "\n"))
            case .quote(let nested): appendBlocks(nested, to: result, quoteLevel: quoteLevel + 1)
            case .table(let rows, _):
                guard let headers = rows.first else { continue }
                appendInline(headers.joined(separator: " | ") + "\n", to: result, bold: true)
                for row in rows.dropFirst() {
                    let text = row.enumerated().map { index, value in
                        (index < headers.count ? headers[index] + "：" : "") + value
                    }.joined(separator: "    ")
                    appendInline(text + "\n", to: result)
                }
                result.append(NSAttributedString(string: "\n"))
            case .divider: result.append(NSAttributedString(string: "────────────────\n\n", attributes: attributes(size: 10, color: 0.6)))
            }
        }
    }

    private static func appendInline(_ text: String, to result: NSMutableAttributedString, size: CGFloat = 11, bold: Bool = false, indent: Int = 0) {
        let inline = DesktopMarkdownInline.parse(text)
        for run in inline.runs {
            let strong = bold || run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            let code = run.inlinePresentationIntent?.contains(.code) == true
            var value = String(inline[run.range].characters)
            if let link = run.link { value += " (\(link.absoluteString))" }
            result.append(NSAttributedString(string: value, attributes: attributes(size: size, bold: strong, monospaced: code, indent: indent)))
        }
    }

    private static func attributes(size: CGFloat, bold: Bool = false, monospaced: Bool = false, color: CGFloat = 0.05, indent: Int = 0) -> [NSAttributedString.Key: Any] {
        let font = CTFontCreateWithName((monospaced ? "Menlo" : bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.headIndent = CGFloat(indent)
        paragraph.firstLineHeadIndent = CGFloat(indent)
        return [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): CGColor(gray: color, alpha: 1), .paragraphStyle: paragraph]
    }

    private static func roleTitle(_ role: DesktopMessageRole) -> String {
        switch role {
        case .user: "你"
        case .assistant: "Amber"
        case .system: "系统"
        case .tool: "工具"
        }
    }

    private static func imageName(_ image: DesktopMessageImage, index: Int) -> String {
        image.name.flatMap { $0.isEmpty ? nil : $0 } ?? "图片 \(index + 1)"
    }

    private static let pdfImageKey = NSAttributedString.Key("AmberPDFImage")
    private static let keepWithNextKey = NSAttributedString.Key("AmberKeepWithNext")

    private static func paginatedFrame(_ framesetter: CTFramesetter, text: NSAttributedString, offset: Int, path: CGPath) -> CTFrame {
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        var end = visible.location + visible.length
        guard end < text.length else { return frame }
        let string = text.string as NSString
        while end > offset, let scalar = UnicodeScalar(string.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
        guard end > offset else { return frame }
        var heading = NSRange()
        guard text.attribute(keepWithNextKey, at: end - 1, effectiveRange: &heading) as? Bool == true,
              heading.location > offset else { return frame }
        return CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: heading.location - offset), path, nil)
    }
    private final class PDFImage {
        let image: CGImage
        let size: CGSize
        init(_ image: CGImage) {
            self.image = image
            let scale = min(1, 499 / CGFloat(image.width), 650 / CGFloat(image.height))
            size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        }
    }

    private static func appendImages(_ images: [DesktopMessageImage], to result: NSMutableAttributedString) {
        for (index, image) in images.enumerated() {
            var captionStyle = attributes(size: 10, bold: true)
            captionStyle[keepWithNextKey] = true
            result.append(NSAttributedString(string: imageName(image, index: index) + "\n", attributes: captionStyle))
            if let cgImage = decodedPDFImage(image.url) {
                let attachment = PDFImage(cgImage)
                var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1,
                    dealloc: { Unmanaged<PDFImage>.fromOpaque($0).release() },
                    getAscent: { Unmanaged<PDFImage>.fromOpaque($0).takeUnretainedValue().size.height },
                    getDescent: { _ in 0 },
                    getWidth: { Unmanaged<PDFImage>.fromOpaque($0).takeUnretainedValue().size.width })
                let reference = Unmanaged.passRetained(attachment).toOpaque()
                if let delegate = CTRunDelegateCreate(&callbacks, reference) {
                    var style = attributes(size: 11)
                    style[pdfImageKey] = attachment
                    style[.init(kCTRunDelegateAttributeName as String)] = delegate
                    style[.init(kCTForegroundColorAttributeName as String)] = CGColor(gray: 0, alpha: 0)
                    result.append(NSAttributedString(string: "\u{FFFC}", attributes: style))
                    result.append(NSAttributedString(string: "\n\n", attributes: attributes(size: 11)))
                    continue
                }
                Unmanaged<PDFImage>.fromOpaque(reference).release()
            }
            let notice = image.url.hasPrefix("data:")
                ? "图像数据无法解码；原始数据请见完整会话 JSON。"
                : "远程图片：\(image.url)\nPDF 保留链接，不下载远程图像。"
            result.append(NSAttributedString(string: notice + "\n\n", attributes: attributes(size: 10, color: 0.4)))
        }
    }

    private static func decodedPDFImage(_ url: String) -> CGImage? {
        guard url.hasPrefix("data:image/"), let comma = url.firstIndex(of: ","),
              url[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_950, // 3× the largest PDF presentation dimension.
        ] as CFDictionary)
    }

    private static func drawImages(in frame: CTFrame, context: CGContext) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let frameOrigin = CTFrameGetPath(frame).boundingBox.origin
        for (index, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let style = CTRunGetAttributes(run) as NSDictionary
                guard let attachment = style[pdfImageKey] as? PDFImage else { continue }
                let offset = CTLineGetOffsetForStringIndex(line, CTRunGetStringRange(run).location, nil)
                let origin = CGPoint(x: frameOrigin.x + origins[index].x + offset, y: frameOrigin.y + origins[index].y)
                context.draw(attachment.image, in: CGRect(origin: origin, size: attachment.size))
            }
        }
    }
}
