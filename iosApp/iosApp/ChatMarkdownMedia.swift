import SwiftUI

struct ChatMarkdownMediaSegment: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text(String)
        case images([ChatMediaItem])
        case video(ChatVideoDescriptor)
    }
    let id: String
    var kind: Kind
}

struct ChatMarkdownMediaPlan: Equatable, Sendable {
    var segments: [ChatMarkdownMediaSegment] = []
    var consumedUTF8Count = 0
    var referenceContext = ""
}

/// The Markdown AST owns syntax recognition. Byte ranges are always sliced as UTF8,
/// including linked images whose complete outer link must leave the text together.
enum ChatMarkdownMediaParser {
    static func parse(_ source: String, completedUTF8Count: Int, isStreaming: Bool = false) -> ChatMarkdownMediaPlan {
        guard let data = MarkdownBridge.parse(source), let root = PackedAstReader(data: data)?.root() else { return .init() }
        let bytes = Array(source.utf8)
        func slice(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        var gaps: [String] = []
        var previousEnd = 0
        for block in root.children {
            if previousEnd < block.startOffset { gaps.append(slice(previousEnd..<block.startOffset)) }
            previousEnd = block.endOffset
        }
        if previousEnd < bytes.count { gaps.append(slice(previousEnd..<bytes.count)) }
        // Reference definitions have no rendered AST node. Carry their unrendered
        // source gaps into every fragment so ordinary [label][ref] links still work.
        let referenceContext = gaps.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        var result = ChatMarkdownMediaPlan(referenceContext: referenceContext)
        var cursor = 0
        var galleryBlockStart = 0

        func title(_ node: PackedAstNode) -> String {
            if node.type == .inlineCode {
                let raw = slice(node.startOffset..<node.endOffset)
                let fenceLength = raw.prefix { $0 == "`" }.count
                let code = String(raw.dropFirst(fenceLength).dropLast(fenceLength))
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                if code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                    return String(code.dropFirst().dropLast())
                }
                return code
            }
            if node.children.isEmpty {
                return node.type == .text ? slice(node.startOffset..<node.endOffset) : ""
            }
            return node.children.map { child in
                child.type == .softBreak || child.type == .hardBreak ? " " : title(child)
            }.joined()
        }
        func appendText(until end: Int, replacingImagesIn container: PackedAstNode? = nil) {
            guard cursor < end else { return }
            var content = ""
            var sourceCursor = cursor
            func appendDisplayText(_ node: PackedAstNode) {
                if node.type == .codeBlock || node.type == .inlineCode { return }
                if node.type == .image, let item = imageItem(node) {
                    content += slice(sourceCursor..<node.startOffset)
                    // The native card owns this image. Keep a literal alt label in
                    // its formatted container, without exposing image URL syntax.
                    let label = item.title.isEmpty ? "图片" : item.title
                    content += label.map { "\\`*_{}[]<>#+-.!|~".contains($0) ? "\\" + String($0) : String($0) }.joined()
                    sourceCursor = node.endOffset
                    return
                }
                node.children.forEach(appendDisplayText)
            }
            if let container { appendDisplayText(container) }
            content += slice(sourceCursor..<end)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.segments.append(.init(id: "text:\(cursor)", kind: .text(content)))
            }
            cursor = end
        }
        func imageItem(_ node: PackedAstNode) -> ChatMediaItem? {
            let linkedImage = node.type == .link && node.children.count == 1 && node.children[0].type == .image
            let imageNode = linkedImage ? node.children[0] : node
            guard imageNode.type == .image, let href = imageNode.linkHref(), validImageURL(href) else { return nil }
            var sourceURL = linkedImage ? node.linkHref() : nil
            var ancestor = node.parent
            while sourceURL == nil, let parent = ancestor {
                if parent.type == .link { sourceURL = parent.linkHref() }
                ancestor = parent.parent
            }
            return ChatMediaItem(id: "markdown:image:\(node.startOffset)", url: href,
                                     title: title(imageNode), sourceURL: sourceURL)
        }
        func videoItem(_ node: PackedAstNode) -> ChatVideoDescriptor? {
            guard node.type == .link, let href = node.linkHref(), isVideoURL(href),
                  bytes[node.startOffset] == UInt8(ascii: "[") else { return nil }
            let id = "markdown:video:\(node.startOffset)"
            let label = title(node)
            return .init(id: id, url: href, title: label.isEmpty ? "视频" : label)
        }
        func visit(_ node: PackedAstNode) {
            if node.type == .codeBlock || node.type == .inlineCode { return }
            if let item = imageItem(node) {
                let between = slice(cursor..<node.startOffset)
                if between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   result.segments.count > galleryBlockStart,
                   let last = result.segments.last, case .images(var items) = last.kind {
                    items.append(item)
                    result.segments[result.segments.count - 1].kind = .images(items)
                } else {
                    appendText(until: node.startOffset)
                    result.segments.append(.init(id: item.id, kind: .images([item])))
                }
                cursor = node.endOffset
            } else if let video = videoItem(node) {
                appendText(until: node.startOffset)
                result.segments.append(.init(id: video.id, kind: .video(video)))
                cursor = node.endOffset
            } else {
                node.children.forEach(visit)
            }
        }
        func containerMedia(_ node: PackedAstNode) -> [ChatMarkdownMediaSegment] {
            if node.type == .codeBlock || node.type == .inlineCode { return [] }
            if let item = imageItem(node) { return [.init(id: item.id, kind: .images([item]))] }
            if let video = videoItem(node) { return [.init(id: video.id, kind: .video(video))] }
            var media: [ChatMarkdownMediaSegment] = []
            for child in node.children {
                for segment in containerMedia(child) {
                    if case .images(let items) = segment.kind, let last = media.last, case .images(let previous) = last.kind {
                        media[media.count - 1].kind = .images(previous + items)
                    } else { media.append(segment) }
                }
            }
            return media
        }
        func requiresIntactParagraph(_ node: PackedAstNode) -> Bool {
            let pureLinkedImage = node.type == .link && node.children.count == 1 && node.children[0].type == .image
            if [.emphasis, .strong, .strikethrough, .link].contains(node.type), !pureLinkedImage,
               !node.children.flatMap(containerMedia).isEmpty {
                return true
            }
            return node.children.contains(where: requiresIntactParagraph)
        }
        for (blockIndex, block) in root.children.enumerated() where block.endOffset <= completedUTF8Count {
            // Keep containers and inline formatting across media intact. Native
            // media follows that complete block; ordinary paragraphs split inline.
            let intactParagraph = block.type == .paragraph && requiresIntactParagraph(block)
            if block.type == .paragraph && !intactParagraph {
                // A later paragraph cannot turn an already visible single image
                // into a narrower scrolling gallery while the answer grows.
                galleryBlockStart = result.segments.count
                visit(block)
            } else if intactParagraph || [.listOrdered, .listUnordered, .blockquote, .table, .heading].contains(block.type) {
                // A trailing list/quote may continue across blank lines. Wait for
                // the following root block or completion before promoting its media.
                if !intactParagraph && isStreaming && blockIndex == root.children.count - 1 { continue }
                let media = containerMedia(block)
                if !media.isEmpty {
                    appendText(until: block.endOffset, replacingImagesIn: block)
                    result.segments.append(contentsOf: media)
                }
            }
        }
        result.consumedUTF8Count = cursor
        return result
    }

    static func validImageURL(_ raw: String) -> Bool {
        if raw.hasPrefix("data:image/") { return true }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    static func isVideoURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"), url.host != nil else { return false }
        return ["mp4", "mov", "m4v", "m3u8"].contains(url.pathExtension.lowercased())
    }
}

/// Only newly appended bytes are scanned on ordinary deltas. AST parsing is needed
/// when a candidate's paragraph ends, and once more for the authoritative final text.
struct ChatMarkdownMediaScan {
    private var processedCount = 0
    private var checkpoint: [UInt8] = []
    private var previousWasNewline = false
    private var lineContainsOnlyWhitespace = true
    private(set) var hasCandidate = false
    private(set) var completedUTF8Count = 0
    private(set) var totalScannedUTF8Count = 0
    private(set) var didReset = false

    mutating func update(_ source: String, isStreaming: Bool) -> Bool {
        let utf8 = source.utf8
        let count = utf8.count
        let checkpointStart = max(0, processedCount - checkpoint.count)
        let isAppend = count >= processedCount && Array(utf8.dropFirst(checkpointStart).prefix(checkpoint.count)) == checkpoint
        didReset = !isAppend
        if !isAppend {
            processedCount = 0; checkpoint = []; previousWasNewline = false
            lineContainsOnlyWhitespace = true; hasCandidate = false; completedUTF8Count = 0
        }
        let oldCompleted = completedUTF8Count
        var offset = processedCount
        for byte in utf8.dropFirst(processedCount) {
            offset += 1
            totalScannedUTF8Count += 1
            if byte == UInt8(ascii: "[") { hasCandidate = true }
            if byte == 10 {
                if previousWasNewline && lineContainsOnlyWhitespace { completedUTF8Count = offset }
                previousWasNewline = true
                lineContainsOnlyWhitespace = true
            } else if byte != 13 && byte != 32 && byte != 9 {
                previousWasNewline = false
                lineContainsOnlyWhitespace = false
            }
        }
        processedCount = count
        checkpoint = Array(utf8.suffix(32))
        if !isStreaming { completedUTF8Count = count }
        return hasCandidate && (!isStreaming || !isAppend || completedUTF8Count != oldCompleted)
    }
}

@MainActor
final class ChatMarkdownMediaController: ObservableObject {
    @Published private(set) var plan = ChatMarkdownMediaPlan()
    private var scan = ChatMarkdownMediaScan()
    private var pending: (String, Int, Int, Bool)?
    private var revision = 0
    private var lastParsedFinalText: String?
    private var task: Task<Void, Never>?
    init(text: String = "", isStreaming: Bool = true) {
        if !isStreaming, scan.update(text, isStreaming: false) {
            // StateObject's autoclosure runs once for a historical fragment. Its
            // first measured height already includes media, like the text renderer.
            plan = ChatMarkdownMediaParser.parse(text, completedUTF8Count: text.utf8.count)
            lastParsedFinalText = text
        }
    }

    deinit { task?.cancel() }

    func update(_ source: String, isStreaming: Bool) {
        if !isStreaming, lastParsedFinalText == source { return }
        lastParsedFinalText = isStreaming ? nil : source
        let shouldParse = scan.update(source, isStreaming: isStreaming)
        if scan.didReset {
            revision += 1
            pending = nil
            if plan != ChatMarkdownMediaPlan() { plan = .init() }
        }
        guard shouldParse else { return }
        pending = (source, scan.completedUTF8Count, revision, isStreaming)
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { task = nil }
            while let next = pending, !Task.isCancelled {
                pending = nil
                let parsed = await Task.detached(priority: .userInitiated) {
                    ChatMarkdownMediaParser.parse(next.0, completedUTF8Count: next.1, isStreaming: next.3)
                }.value
                guard !Task.isCancelled else { return }
                if next.2 == revision, parsed != plan { plan = parsed }
            }
        }
    }
}

struct ChatMarkdownMediaContent<TextContent: View>: View {
    let text: String
    let isStreaming: Bool
    @ViewBuilder var renderText: (String, String) -> TextContent
    @StateObject private var controller: ChatMarkdownMediaController

    init(text: String, isStreaming: Bool, @ViewBuilder renderText: @escaping (String, String) -> TextContent) {
        self.text = text
        self.isStreaming = isStreaming
        self.renderText = renderText
        _controller = StateObject(wrappedValue: ChatMarkdownMediaController(text: text, isStreaming: isStreaming))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(displaySegments) { segment in
                switch segment.kind {
                case .text(let content): renderText(withReferences(content), segment.id)
                case .images(let items): ChatMediaGallery(items: items)
                case .video(let video): ChatVideoCard(video: video)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { controller.update(text, isStreaming: isStreaming) }
        .onChange(of: text) { _, value in controller.update(value, isStreaming: isStreaming) }
        .onChange(of: isStreaming) { _, value in controller.update(text, isStreaming: value) }
    }

    private var displaySegments: [ChatMarkdownMediaSegment] {
        var segments = controller.plan.segments
        let consumed = min(controller.plan.consumedUTF8Count, text.utf8.count)
        let tail = consumed == 0 ? text : String(decoding: text.utf8.dropFirst(consumed), as: UTF8.self)
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.init(id: "text:\(consumed)", kind: .text(tail)))
        }
        return segments
    }

    private func withReferences(_ content: String) -> String {
        guard controller.plan.consumedUTF8Count > 0, !controller.plan.referenceContext.isEmpty else { return content }
        return content + "\n\n" + controller.plan.referenceContext
    }
}
