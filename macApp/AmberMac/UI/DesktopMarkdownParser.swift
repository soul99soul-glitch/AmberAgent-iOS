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
    static func parse(_ text: String) -> [DesktopMarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var result: [DesktopMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
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
                result.append(.quote(parse(quote.joined(separator: "\n"))))
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
}

