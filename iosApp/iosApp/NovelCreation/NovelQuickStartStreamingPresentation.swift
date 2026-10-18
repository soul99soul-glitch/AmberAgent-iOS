import Foundation

enum NovelQuickStartStreamingPresentation {
    static func markdown(from partialJSON: String) -> String {
        let overview = stringValue(for: "overview", in: partialJSON)
        let world = section(for: "world", heading: "世界观", in: partialJSON)
        var characterRanges = objectRanges(inArrayFor: "characters", in: partialJSON)
        if characterRanges.isEmpty,
           let legacyCharacter = objectRange(for: "characters", in: partialJSON) {
            characterRanges = [legacyCharacter]
        }
        let characters = characterRanges
            .compactMap { section(heading: "人物", in: partialJSON, range: $0) }
        let outline = section(for: "masterOutline", heading: "总剧情大纲", in: partialJSON)
        let requirements = section(
            for: "writingRequirements",
            heading: "写作要求",
            in: partialJSON
        )

        var blocks: [String] = []
        if let overview, !overview.isEmpty {
            blocks.append("# 创作建议\n\n\(overview)")
        }
        blocks.append(contentsOf: [world].compactMap { $0 })
        blocks.append(contentsOf: characters)
        blocks.append(contentsOf: [outline, requirements].compactMap { $0 })
        return blocks.joined(separator: "\n\n")
    }

    static func characterProposalMarkdown(from partialJSON: String) -> String {
        var blocks: [String] = []
        if let range = objectRange(for: "character", in: partialJSON) {
            let title = stringValue(for: "title", in: partialJSON, searchRange: range) ?? ""
            let content = stringValue(for: "content", in: partialJSON, searchRange: range) ?? ""
            if !title.isEmpty || !content.isEmpty {
                let heading = title.isEmpty ? "# 人物建议" : "# 人物建议：\(title)"
                blocks.append(content.isEmpty ? heading : heading + "\n\n" + content)
            }
        }
        for range in objectRanges(inArrayFor: "relatedSuggestions", in: partialJSON) {
            let kind = stringValue(for: "kind", in: partialJSON, searchRange: range) ?? ""
            let title = stringValue(for: "title", in: partialJSON, searchRange: range) ?? ""
            let content = stringValue(for: "content", in: partialJSON, searchRange: range) ?? ""
            guard !title.isEmpty || !content.isEmpty else { continue }
            let label = switch kind {
            case "relationship": "人物关系"
            case "world": "世界观"
            case "plot": "剧情"
            default: "相关设定"
            }
            let heading = title.isEmpty ? "## \(label)" : "## 相关\(label)：\(title)"
            blocks.append(content.isEmpty ? heading : heading + "\n\n" + content)
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func section(
        for key: String,
        heading: String,
        in text: String
    ) -> String? {
        guard let range = objectRange(for: key, in: text) else { return nil }
        return section(heading: heading, in: text, range: range)
    }

    private static func section(
        heading: String,
        in text: String,
        range: Range<String.Index>
    ) -> String? {
        let title = stringValue(for: "title", in: text, searchRange: range) ?? ""
        let content = stringValue(for: "content", in: text, searchRange: range) ?? ""
        guard !title.isEmpty || !content.isEmpty else { return nil }
        if title.isEmpty { return "## \(heading)\n\n\(content)" }
        if content.isEmpty { return "## \(heading)：\(title)" }
        return "## \(heading)：\(title)\n\n\(content)"
    }

    private static func stringValue(
        for key: String,
        in text: String,
        searchRange: Range<String.Index>? = nil
    ) -> String? {
        let range = searchRange ?? text.startIndex..<text.endIndex
        guard let keyRange = unescapedKeyRange(key, in: text, searchRange: range),
              let colon = text[keyRange.upperBound..<range.upperBound].firstIndex(of: ":") else {
            return nil
        }
        var cursor = text.index(after: colon)
        skipWhitespace(in: text, cursor: &cursor, limit: range.upperBound)
        guard cursor < range.upperBound, text[cursor] == "\"" else { return nil }
        return decodeJSONString(in: text, openingQuote: cursor, limit: range.upperBound)
    }

    private static func objectRange(for key: String, in text: String) -> Range<String.Index>? {
        guard let keyRange = unescapedKeyRange(
            key,
            in: text,
            searchRange: text.startIndex..<text.endIndex
        ), let colon = text[keyRange.upperBound...].firstIndex(of: ":") else {
            return nil
        }
        var cursor = text.index(after: colon)
        skipWhitespace(in: text, cursor: &cursor, limit: text.endIndex)
        guard cursor < text.endIndex, text[cursor] == "{" else { return nil }
        return containerRange(in: text, start: cursor, opening: "{", closing: "}")
    }

    private static func objectRanges(
        inArrayFor key: String,
        in text: String
    ) -> [Range<String.Index>] {
        guard let keyRange = unescapedKeyRange(
            key,
            in: text,
            searchRange: text.startIndex..<text.endIndex
        ), let colon = text[keyRange.upperBound...].firstIndex(of: ":") else {
            return []
        }
        var cursor = text.index(after: colon)
        skipWhitespace(in: text, cursor: &cursor, limit: text.endIndex)
        guard cursor < text.endIndex, text[cursor] == "[" else { return [] }

        var ranges: [Range<String.Index>] = []
        var index = text.index(after: cursor)
        var inString = false
        var escaped = false
        var arrayDepth = 1
        while index < text.endIndex, arrayDepth > 0 {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "[" {
                arrayDepth += 1
            } else if character == "]" {
                arrayDepth -= 1
            } else if character == "{", arrayDepth == 1 {
                let range = containerRange(
                    in: text,
                    start: index,
                    opening: "{",
                    closing: "}"
                )
                ranges.append(range)
                index = range.upperBound
                continue
            }
            index = text.index(after: index)
        }
        return ranges
    }

    private static func containerRange(
        in text: String,
        start: String.Index,
        opening: Character,
        closing: Character
    ) -> Range<String.Index> {
        var index = start
        var depth = 0
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return start..<text.index(after: index)
                }
            }
            index = text.index(after: index)
        }
        return start..<text.endIndex
    }

    private static func unescapedKeyRange(
        _ key: String,
        in text: String,
        searchRange: Range<String.Index>
    ) -> Range<String.Index>? {
        let marker = "\"\(key)\""
        var lowerBound = searchRange.lowerBound
        while lowerBound < searchRange.upperBound,
              let match = text.range(
                  of: marker,
                  range: lowerBound..<searchRange.upperBound
              ) {
            var slashCount = 0
            var cursor = match.lowerBound
            while cursor > searchRange.lowerBound {
                let previous = text.index(before: cursor)
                guard text[previous] == "\\" else { break }
                slashCount += 1
                cursor = previous
            }
            if slashCount.isMultiple(of: 2) { return match }
            lowerBound = match.upperBound
        }
        return nil
    }

    private static func skipWhitespace(
        in text: String,
        cursor: inout String.Index,
        limit: String.Index
    ) {
        while cursor < limit, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
    }

    private static func decodeJSONString(
        in text: String,
        openingQuote: String.Index,
        limit: String.Index
    ) -> String {
        var result = ""
        var index = text.index(after: openingQuote)
        while index < limit {
            let character = text[index]
            guard character != "\"" else { break }
            guard character == "\\" else {
                result.append(character)
                index = text.index(after: index)
                continue
            }

            let escape = text.index(after: index)
            guard escape < limit else { break }
            switch text[escape] {
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "/": result.append("/")
            case "b": result.append("\u{8}")
            case "f": result.append("\u{c}")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "u":
                var hex = ""
                var hexIndex = text.index(after: escape)
                for _ in 0..<4 where hexIndex < limit {
                    hex.append(text[hexIndex])
                    hexIndex = text.index(after: hexIndex)
                }
                guard hex.count == 4,
                      let value = UInt32(hex, radix: 16),
                      let scalar = Unicode.Scalar(value) else {
                    return result
                }
                result.unicodeScalars.append(scalar)
                index = hexIndex
                continue
            default:
                return result
            }
            index = text.index(after: escape)
        }
        return result
    }
}
