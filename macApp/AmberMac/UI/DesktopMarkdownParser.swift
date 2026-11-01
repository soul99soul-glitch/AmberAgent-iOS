import Foundation

enum DesktopMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String, Int)
    case code(String, String)
    case math(String)
    case table([[String]], alignments: [DesktopMarkdownColumnAlignment] = [])
    case list([DesktopMarkdownListItem])
    case quote([DesktopMarkdownBlock])
    case divider
    case images([DesktopMessageImage])
    case video(DesktopVideoMedia)
    case audio(DesktopAudioMedia)
}

enum DesktopMarkdownColumnAlignment: Equatable { case leading, center, trailing }

struct DesktopMarkdownListItem: Equatable {
    let marker: String
    var text: String
    let level: Int
}

enum DesktopMarkdownInline {
    static func parse(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

enum DesktopMarkdownParser {
    static func parse(_ text: String, streaming: Bool = false) -> [DesktopMarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var result: [DesktopMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        func appendBlock(_ block: DesktopMarkdownBlock) {
            if case .images(let incoming) = block,
               case .images(let existing) = result.last {
                result[result.count - 1] = .images(existing + incoming)
            } else {
                result.append(block)
            }
        }
        func flush() {
            if !paragraph.isEmpty {
                let raw = paragraph.joined(separator: "\n")
                for block in splitParagraphMedia(raw, streaming: streaming) {
                    appendBlock(block)
                }
                paragraph.removeAll(keepingCapacity: true)
            }
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let marker = trimmed.first!
                let markerLength = trimmed.prefix(while: { $0 == marker }).count
                let language = String(trimmed.dropFirst(markerLength)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !isClosingFence(lines[index], marker: marker, length: markerLength) {
                    code.append(lines[index])
                    index += 1
                }
                result.append(.code(code.joined(separator: "\n"), language))
            } else if let math = DesktopMathTokenizer.block(lines: lines, at: index) {
                flush()
                result.append(.math(math.source))
                index = math.end + 1
                continue
            } else if index + 1 < lines.count, line.contains("|"),
                      let alignments = tableAlignments(lines[index + 1]),
                      tableCells(line).count == alignments.count {
                flush()
                var rows = [tableCells(line)]
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                result.append(.table(rows, alignments: alignments))
                continue
            } else if trimmed.isEmpty {
                flush()
            } else if isDivider(trimmed) {
                flush()
                result.append(.divider)
            } else if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count {
                    let value = lines[index].trimmingCharacters(in: .whitespaces)
                    guard value.hasPrefix(">") else { break }
                    let content = value.dropFirst()
                    quote.append(String(content.first == " " ? content.dropFirst() : content))
                    index += 1
                }
                result.append(.quote(parse(quote.joined(separator: "\n"), streaming: streaming)))
                continue
            } else if listMarker(line) != nil {
                flush()
                var items: [DesktopMarkdownListItem] = []
                var counters: [Int: Int] = [:]
                let initialIndent = indentation(line)
                while index < lines.count {
                    let value = lines[index]
                    if let item = listMarker(value), !isDivider(value.trimmingCharacters(in: .whitespaces)) {
                        let indent = indentation(value)
                        var marker = "•"
                        if let number = item.number {
                            let current = counters[indent] ?? number
                            counters[indent] = current + 1
                            marker = "\(current)."
                        } else { counters[indent] = nil }
                        for key in counters.keys where key > indent { counters[key] = nil }
                        items.append(.init(marker: marker, text: item.text, level: max(0, (indent - initialIndent) / 2)))
                        index += 1
                    } else if value.trimmingCharacters(in: .whitespaces).isEmpty,
                              index + 1 < lines.count, listMarker(lines[index + 1]) != nil {
                        index += 1
                    } else if !value.trimmingCharacters(in: .whitespaces).isEmpty,
                              indentation(value) > initialIndent, !items.isEmpty {
                        items[items.count - 1].text += "\n" + value.trimmingCharacters(in: .whitespaces)
                        index += 1
                    } else { break }
                }
                result.append(.list(items))
                continue
            } else {
                let count = trimmed.prefix(while: { $0 == "#" }).count
                if (1...6).contains(count), trimmed.dropFirst(count).first == " " {
                    flush()
                    result.append(.heading(String(trimmed.dropFirst(count + 1)), count))
                } else {
                    paragraph.append(line)
                }
            }
            index += 1
        }
        flush()
        return result
    }

    static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var codeDelimiterLength = 0
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", codeDelimiterLength == 0 {
                if index + 1 < characters.count {
                    let next = characters[index + 1]
                    if next != "|" { cell.append("\\") }
                    cell.append(next)
                    index += 2
                    continue
                }
                cell.append("\\")
            } else if character == "`" {
                let start = index
                while index < characters.count, characters[index] == "`" { index += 1 }
                let count = index - start
                if codeDelimiterLength == 0, hasClosingCodeDelimiter(in: characters, from: index, length: count) {
                    codeDelimiterLength = count
                }
                else if codeDelimiterLength == count { codeDelimiterLength = 0 }
                cell += String(repeating: "`", count: count)
                continue
            } else if character == "|", codeDelimiterLength == 0 {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            index += 1
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|"), cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func hasClosingCodeDelimiter(in characters: [Character], from start: Int, length: Int) -> Bool {
        var index = start
        while index < characters.count {
            guard characters[index] == "`" else { index += 1; continue }
            let runStart = index
            while index < characters.count, characters[index] == "`" { index += 1 }
            if index - runStart == length { return true }
        }
        return false
    }

    private static func tableAlignments(_ line: String) -> [DesktopMarkdownColumnAlignment]? {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return nil }
        var result: [DesktopMarkdownColumnAlignment] = []
        for cell in cells {
            var value = cell[...]
            let leading = value.first == ":"
            let trailing = value.last == ":"
            if leading { value = value.dropFirst() }
            if trailing, !value.isEmpty { value = value.dropLast() }
            guard value.count >= 3, value.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(leading && trailing ? .center : trailing ? .trailing : .leading)
        }
        return result
    }

    private static func isDivider(_ line: String) -> Bool {
        let markers = line.filter { !$0.isWhitespace }
        guard let marker = markers.first, ["-", "*", "_"].contains(marker), markers.count >= 3 else { return false }
        return markers.allSatisfy { $0 == marker }
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func listMarker(_ line: String) -> (number: Int?, text: String)? {
        let value = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = value.first else { return nil }
        if ["-", "+", "*"].contains(first) {
            let content = value.dropFirst()
            guard content.first?.isWhitespace == true else { return nil }
            return (nil, String(content.drop(while: \.isWhitespace)))
        }
        let digits = value.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        let suffix = value.dropFirst(digits.count)
        guard suffix.first == "." || suffix.first == ")", suffix.dropFirst().first?.isWhitespace == true else { return nil }
        return (number, String(suffix.dropFirst().drop(while: \.isWhitespace)))
    }

    private static func isClosingFence(_ line: String, marker: Character, length: Int) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        let count = value.prefix(while: { $0 == marker }).count
        return count >= length && value.dropFirst(count).isEmpty
    }

    // MARK: - Interleaved Markdown Media Parsing (Images, Linked Images, Video, Audio)

    enum MediaKind: Equatable {
        case image
        case video
        case audio
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg", "avif", "ico"
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "m3u8", "webm", "ogv"
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "ogg", "flac", "opus", "caf"
    ]

    static func classifyMediaURL(_ rawURL: String, explicitImageSyntax: Bool) -> MediaKind? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("data:image/") { return .image }
        if lower.hasPrefix("data:video/") { return .video }
        if lower.hasPrefix("data:audio/") { return .audio }

        let ext = mediaPathExtension(from: trimmed)
        if videoExtensions.contains(ext) || hasMediaQueryHint(trimmed, prefix: "video") {
            return .video
        }
        if audioExtensions.contains(ext) || hasMediaQueryHint(trimmed, prefix: "audio") {
            return .audio
        }
        if imageExtensions.contains(ext) || hasMediaQueryHint(trimmed, prefix: "image") {
            return explicitImageSyntax ? .image : nil
        }
        if explicitImageSyntax {
            if let scheme = URL(string: trimmed)?.scheme?.lowercased(),
               ["http", "https", "file", "attachment"].contains(scheme) {
                return .image
            }
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") {
                return .image
            }
        }
        return nil
    }

    private static func mediaPathExtension(from rawURL: String) -> String {
        if let components = URLComponents(string: rawURL), !components.path.isEmpty {
            return (components.path as NSString).pathExtension.lowercased()
        }
        let withoutQuery = rawURL.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawURL
        let withoutFragment = withoutQuery.split(separator: "#", maxSplits: 1).first.map(String.init) ?? withoutQuery
        return (withoutFragment as NSString).pathExtension.lowercased()
    }

    private static func hasMediaQueryHint(_ rawURL: String, prefix: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let items = components.queryItems else { return false }
        for item in items {
            let key = item.name.lowercased()
            guard ["mime", "mimetype", "type", "content_type", "content-type", "format"].contains(key),
                  let val = item.value?.lowercased() else { continue }
            if val.hasPrefix("\(prefix)/") { return true }
            if prefix == "video" && videoExtensions.contains(val) { return true }
            if prefix == "audio" && audioExtensions.contains(val) { return true }
            if prefix == "image" && imageExtensions.contains(val) { return true }
        }
        return false
    }

    static func splitParagraphMedia(_ text: String, streaming: Bool = false) -> [DesktopMarkdownBlock] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }

        var blocks: [DesktopMarkdownBlock] = []
        var textBuffer = ""
        var hadAnyMedia = false
        var index = 0
        var codeDelimiterLength = 0

        func flushTextBuffer() {
            guard !textBuffer.isEmpty else { return }
            let cleaned = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            textBuffer.removeAll(keepingCapacity: true)
            guard !cleaned.isEmpty else { return }
            blocks.append(.paragraph(cleaned))
        }

        func appendMediaBlock(_ block: DesktopMarkdownBlock) {
            hadAnyMedia = true
            if case .images(let incoming) = block,
               case .images(let existing) = blocks.last {
                blocks[blocks.count - 1] = .images(existing + incoming)
            } else {
                blocks.append(block)
            }
        }

        while index < chars.count {
            let ch = chars[index]
            if ch == "`" {
                let start = index
                while index < chars.count, chars[index] == "`" { index += 1 }
                let count = index - start
                if codeDelimiterLength == 0, hasClosingCodeDelimiter(in: chars, from: index, length: count) {
                    codeDelimiterLength = count
                } else if codeDelimiterLength == count {
                    codeDelimiterLength = 0
                }
                textBuffer += String(repeating: "`", count: count)
                continue
            }

            if codeDelimiterLength == 0 {
                if let matched = matchMediaToken(in: chars, at: index) {
                    flushTextBuffer()
                    appendMediaBlock(matched.block)
                    index = matched.nextIndex
                    continue
                }
                if streaming, isIncompleteTrailingMediaToken(in: chars, at: index) {
                    hadAnyMedia = true
                    break
                }
            }

            textBuffer.append(ch)
            index += 1
        }

        if hadAnyMedia {
            let cleaned = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                blocks.append(.paragraph(cleaned))
            }
        } else if !textBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.paragraph(textBuffer))
        }
        return blocks
    }

    private static func isIncompleteTrailingMediaToken(in chars: [Character], at start: Int) -> Bool {
        let remaining = chars[start...]
        guard remaining.starts(with: Array("![")) || remaining.starts(with: Array("[![")) else {
            return false
        }
        return !remaining.contains("\n")
    }

    private static func matchMediaToken(in chars: [Character], at start: Int) -> (block: DesktopMarkdownBlock, nextIndex: Int)? {
        // 1. Linked image/media: [![alt](innerURL "title")](outerURL)
        if start + 3 < chars.count, chars[start] == "[", chars[start + 1] == "!", chars[start + 2] == "[" {
            if let inner = parseBracketedLink(in: chars, bracketStart: start + 2),
               inner.nextIndex < chars.count, chars[inner.nextIndex] == "]",
               inner.nextIndex + 1 < chars.count, chars[inner.nextIndex + 1] == "(",
               let outer = parseParenDestination(in: chars, parenStart: inner.nextIndex + 1),
               let kind = classifyMediaURL(inner.url, explicitImageSyntax: true) {
                let displayTitle = inner.title ?? (inner.label.isEmpty ? nil : inner.label)
                let sourceURL = outer.url.isEmpty ? nil : outer.url
                let block = makeMediaBlock(
                    kind: kind,
                    url: inner.url,
                    alt: inner.label,
                    title: displayTitle,
                    sourceURL: sourceURL
                )
                return (block, outer.nextIndex)
            }
        }

        // 2. Explicit Markdown image/media: ![alt](url "title")
        if start + 1 < chars.count, chars[start] == "!", chars[start + 1] == "[" {
            if let parsed = parseBracketedLink(in: chars, bracketStart: start + 1),
               let kind = classifyMediaURL(parsed.url, explicitImageSyntax: true) {
                let displayTitle = parsed.title ?? (parsed.label.isEmpty ? nil : parsed.label)
                let block = makeMediaBlock(
                    kind: kind,
                    url: parsed.url,
                    alt: parsed.label,
                    title: displayTitle,
                    sourceURL: nil
                )
                return (block, parsed.nextIndex)
            }
        }

        // 3. Direct media link (without `!`): [title](video_or_audio_url)
        if chars[start] == "[", (start == 0 || chars[start - 1] != "!") {
            if let parsed = parseBracketedLink(in: chars, bracketStart: start),
               let kind = classifyMediaURL(parsed.url, explicitImageSyntax: false),
               kind == .video || kind == .audio {
                let displayTitle = parsed.title ?? (parsed.label.isEmpty ? nil : parsed.label)
                let block = makeMediaBlock(
                    kind: kind,
                    url: parsed.url,
                    alt: parsed.label,
                    title: displayTitle,
                    sourceURL: parsed.url
                )
                return (block, parsed.nextIndex)
            }
        }

        return nil
    }

    private static func makeMediaBlock(
        kind: MediaKind,
        url: String,
        alt: String,
        title: String?,
        sourceURL: String?
    ) -> DesktopMarkdownBlock {
        let cleanAlt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .image:
            return .images([
                DesktopMessageImage(
                    url: url,
                    name: cleanAlt.isEmpty ? nil : cleanAlt,
                    title: (cleanTitle?.isEmpty == false) ? cleanTitle : nil,
                    sourceURL: sourceURL
                )
            ])
        case .video:
            return .video(
                DesktopVideoMedia(
                    url: url,
                    title: (cleanTitle?.isEmpty == false) ? cleanTitle : (cleanAlt.isEmpty ? nil : cleanAlt),
                    posterURL: nil,
                    sourceURL: sourceURL ?? (url.lowercased().hasPrefix("http") ? url : nil)
                )
            )
        case .audio:
            let fileName = URL(string: url)?.lastPathComponent ?? ""
            return .audio(
                DesktopAudioMedia(
                    url: url,
                    fileName: fileName,
                    title: (cleanTitle?.isEmpty == false) ? cleanTitle : (cleanAlt.isEmpty ? nil : cleanAlt)
                )
            )
        }
    }

    private static func parseBracketedLink(
        in chars: [Character],
        bracketStart: Int
    ) -> (label: String, url: String, title: String?, nextIndex: Int)? {
        guard bracketStart < chars.count, chars[bracketStart] == "[" else { return nil }
        var idx = bracketStart + 1
        var depth = 1
        var labelChars: [Character] = []
        while idx < chars.count, depth > 0 {
            let c = chars[idx]
            if c == "\n" { return nil }
            if c == "\\" && idx + 1 < chars.count {
                labelChars.append(chars[idx + 1])
                idx += 2
                continue
            }
            if c == "[" {
                depth += 1
                labelChars.append(c)
            } else if c == "]" {
                depth -= 1
                if depth > 0 { labelChars.append(c) }
            } else {
                labelChars.append(c)
            }
            idx += 1
        }
        guard depth == 0, idx < chars.count, chars[idx] == "(" else { return nil }
        guard let dest = parseParenDestination(in: chars, parenStart: idx) else { return nil }
        return (String(labelChars), dest.url, dest.title, dest.nextIndex)
    }

    private static func parseParenDestination(
        in chars: [Character],
        parenStart: Int
    ) -> (url: String, title: String?, nextIndex: Int)? {
        guard parenStart < chars.count, chars[parenStart] == "(" else { return nil }
        var idx = parenStart + 1
        while idx < chars.count, chars[idx].isWhitespace, chars[idx] != "\n" { idx += 1 }
        guard idx < chars.count else { return nil }

        var urlChars: [Character] = []
        if chars[idx] == "<" {
            idx += 1
            while idx < chars.count, chars[idx] != ">", chars[idx] != "\n" {
                urlChars.append(chars[idx])
                idx += 1
            }
            guard idx < chars.count, chars[idx] == ">" else { return nil }
            idx += 1
        } else {
            var parenDepth = 0
            while idx < chars.count {
                let c = chars[idx]
                if c == "\n" { return nil }
                if c.isWhitespace && parenDepth == 0 { break }
                if c == "(" {
                    parenDepth += 1
                    urlChars.append(c)
                } else if c == ")" {
                    if parenDepth == 0 { break }
                    parenDepth -= 1
                    urlChars.append(c)
                } else {
                    urlChars.append(c)
                }
                idx += 1
            }
        }

        let url = String(urlChars).trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return nil }

        while idx < chars.count, chars[idx].isWhitespace, chars[idx] != "\n" { idx += 1 }
        var title: String?
        if idx < chars.count, chars[idx] == "\"" || chars[idx] == "'" {
            let quote = chars[idx]
            idx += 1
            var titleChars: [Character] = []
            while idx < chars.count, chars[idx] != quote, chars[idx] != "\n" {
                if chars[idx] == "\\" && idx + 1 < chars.count {
                    titleChars.append(chars[idx + 1])
                    idx += 2
                    continue
                }
                titleChars.append(chars[idx])
                idx += 1
            }
            guard idx < chars.count, chars[idx] == quote else { return nil }
            idx += 1
            title = String(titleChars)
            while idx < chars.count, chars[idx].isWhitespace, chars[idx] != "\n" { idx += 1 }
        }

        guard idx < chars.count, chars[idx] == ")" else { return nil }
        return (url, title, idx + 1)
    }
}

extension DesktopMessage {
    /// Produces the ordered visual blocks for a message, coalescing consecutive images into galleries
    /// and splitting inline Markdown media in user messages so `文字 → 图片 → 文字 → 多图` renders in exact order.
    func orderedDisplayBlocks(streaming: Bool = false) -> [DesktopMessageDisplayBlock] {
        var blocks: [DesktopMessageDisplayBlock] = []
        func append(_ block: DesktopMessageDisplayBlock) {
            if case .images(let incoming) = block,
               case .images(let existing) = blocks.last {
                blocks[blocks.count - 1] = .images(existing + incoming)
            } else {
                blocks.append(block)
            }
        }

        for part in orderedContentParts {
            switch part.kind {
            case .reasoning:
                break
            case .text:
                guard let text = part.text, !text.isEmpty else { continue }
                if role == .user {
                    let parsed = DesktopMarkdownParser.splitParagraphMedia(text, streaming: streaming)
                    for item in parsed {
                        switch item {
                        case .paragraph(let segment):
                            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { append(.text(trimmed)) }
                        case .images(let imgs):
                            append(.images(imgs))
                        case .video(let vid):
                            append(.video(vid))
                        case .audio(let aud):
                            append(.audio(aud))
                        default:
                            append(.text(text))
                        }
                    }
                } else {
                    append(.text(text))
                }
            case .image:
                if let image = part.image { append(.images([image])) }
            case .video:
                if let video = part.video { append(.video(video)) }
            case .audio:
                if let audio = part.audio { append(.audio(audio)) }
            case .tool:
                if let tool = part.tool { append(.tool(tool)) }
            }
        }
        return blocks
    }
}

extension DesktopToolCall {
    /// Combines explicit tool media images with any Markdown images or JSON `images` arrays in `output`.
    var resolvedImages: [DesktopMessageImage] {
        var result: [DesktopMessageImage] = []
        var seen = Set<String>()
        func add(_ image: DesktopMessageImage) {
            guard !image.url.isEmpty, seen.insert(image.url).inserted else { return }
            result.append(image)
        }
        for image in images { add(image) }
        guard !output.isEmpty else { return result }

        for block in DesktopMarkdownParser.parse(output) {
            if case .images(let imgs) = block {
                for img in imgs { add(img) }
            }
        }
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawImages = json["images"] as? [Any] {
            for item in rawImages {
                if let str = item as? String {
                    add(DesktopMessageImage(url: str))
                } else if let dict = item as? [String: Any], let url = dict["url"] as? String {
                    add(DesktopMessageImage(
                        url: url,
                        name: dict["name"] as? String,
                        title: dict["title"] as? String,
                        sourceURL: dict["sourceURL"] as? String ?? dict["source_url"] as? String
                    ))
                }
            }
        }
        return result
    }

    var resolvedVideos: [DesktopVideoMedia] {
        var result = videos
        var seen = Set(result.map(\.url))
        for block in DesktopMarkdownParser.parse(output) {
            if case .video(let video) = block, seen.insert(video.url).inserted {
                result.append(video)
            }
        }
        return result
    }

    var resolvedAudios: [DesktopAudioMedia] {
        var result = audios
        var seen = Set(result.map(\.url))
        for block in DesktopMarkdownParser.parse(output) {
            if case .audio(let audio) = block, seen.insert(audio.url).inserted {
                result.append(audio)
            }
        }
        return result
    }
}

