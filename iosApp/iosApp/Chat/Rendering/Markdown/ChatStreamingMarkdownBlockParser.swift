import SwiftUI
import Shared
import SwiftStreamingMarkdown

struct ChatStreamingMarkdownFenceState {
    private struct Fence {
        let marker: Character
        let runLength: Int
    }

    private var activeFence: Fence?

    var isInsideFence: Bool { activeFence != nil }

    mutating func consumesCodeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activeFence {
            let runLength = trimmed.prefix { $0 == activeFence.marker }.count
            // A shorter run or a line with an info string remains code content.
            if runLength >= activeFence.runLength,
               trimmed.dropFirst(runLength).allSatisfy(\.isWhitespace) {
                self.activeFence = nil
            }
            return true
        }

        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return false }
        let runLength = trimmed.prefix { $0 == marker }.count
        guard runLength >= 3 else { return false }
        activeFence = Fence(marker: marker, runLength: runLength)
        return true
    }
}

enum ChatStreamingMarkdownBlockParser {
    static func containsTable(in text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return false }
        var fenceState = ChatStreamingMarkdownFenceState()

        for index in 0..<(lines.count - 1) {
            let line = lines[index]
            if fenceState.consumesCodeLine(line) { continue }
            let headers = splitTableCells(line)
            if headers.count >= 2,
               isDelimiterLine(lines[index + 1], expectedCount: headers.count) {
                return true
            }
        }
        return false
    }

    static func startsWithTable(in text: String) -> Bool {
        let firstLines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard firstLines.count >= 2 else { return false }
        let headers = splitTableCells(String(firstLines[0]))
        return headers.count >= 2 &&
            isDelimiterLine(String(firstLines[1]), expectedCount: headers.count)
    }

    static func blocks(
        in text: String,
        includeTrailingPartialTableRow: Bool = true,
        includeParsedTableCells: Bool = false
    ) -> [ChatStreamingMarkdownBlock] {
        parseBlocks(
            in: text,
            includeTrailingPartialTableRow: includeTrailingPartialTableRow,
            includeParsedTableCells: includeParsedTableCells
        )
    }

    private static func parseBlocks(
        in text: String,
        includeTrailingPartialTableRow: Bool,
        includeParsedTableCells: Bool
    ) -> [ChatStreamingMarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [ChatStreamingMarkdownBlock] = []
        var textStart = 0
        var index = 0
        var blockOrdinal = 0
        var fenceState = ChatStreamingMarkdownFenceState()

        func flushText(until end: Int) {
            guard textStart < end else { return }
            let content = lines[textStart..<end].joined(separator: "\n")
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                textStart = end
                return
            }
            blocks.append(ChatStreamingMarkdownBlock(
                id: "text-\(blockOrdinal)",
                kind: .text(content)
            ))
            blockOrdinal += 1
            textStart = end
        }

        while index < lines.count {
            let line = lines[index]
            if fenceState.consumesCodeLine(line) {
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let parsedTable = parseTable(
                lines: lines,
                start: index,
                sourceEndsWithNewline: text.hasSuffix("\n"),
                includeTrailingPartialTableRow: includeTrailingPartialTableRow,
                includeParsedTableCells: includeParsedTableCells
               ) {
                flushText(until: index)
                blocks.append(ChatStreamingMarkdownBlock(
                    id: "table-\(blockOrdinal)",
                    kind: .table(parsedTable.table)
                ))
                blockOrdinal += 1
                index += parsedTable.consumedLineCount
                textStart = index
                continue
            }

            index += 1
        }

        flushText(until: lines.count)
        return blocks
    }

    private static func parseTable(
        lines: [String],
        start: Int,
        sourceEndsWithNewline: Bool,
        includeTrailingPartialTableRow: Bool,
        includeParsedTableCells: Bool
    ) -> ChatStreamingMarkdownParsedTable? {
        guard start + 1 < lines.count else { return nil }
        let headers = splitTableCells(lines[start])
        guard headers.count >= 2, isDelimiterLine(lines[start + 1], expectedCount: headers.count) else {
            return nil
        }

        var rows: [[String]] = []
        var renderedLines: [String] = [lines[start], lines[start + 1]]
        var index = start + 2
        var renderedEndIndex = start + 2
        let headerUsesLeadingPipe = lines[start]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("|")
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let isTrailingPartialLine = !includeTrailingPartialTableRow &&
                !sourceEndsWithNewline &&
                index == lines.count - 1
            let canBeNoLeadingPipePartialRow = isTrailingPartialLine && !headerUsesLeadingPipe
            guard !trimmed.isEmpty,
                  line.contains("|") || canBeNoLeadingPipePartialRow,
                  !isDelimiterLine(line, expectedCount: headers.count) else {
                break
            }
            // 含管道的尾行流式期立即渲染为部分行（缺的单元格补空渲染），消除
            // 完成瞬间「最后一行成批出现」的排版重排。无管道尾行保持只消费不
            // 渲染（防「文本↔表格行」中途互变——guard 的
            // `line.contains("|") || canBeNoLeadingPipePartialRow` 已做形状判别）。
            if isTrailingPartialLine {
                if line.contains("|") {
                    if includeParsedTableCells {
                        let cells = ChatStreamingMarkdownTableRowCache.shared.cells(
                            for: line,
                            expectedCount: headers.count
                        ) {
                            normalizedRow(splitTableCells(line), count: headers.count)
                        }
                        rows.append(cells)
                    }
                    renderedLines.append(
                        renderedRowLine(line, columnCount: headers.count, leadingPipe: headerUsesLeadingPipe)
                    )
                    renderedEndIndex = index + 1
                }
                index += 1
                break
            }
            if includeParsedTableCells {
                let cells = ChatStreamingMarkdownTableRowCache.shared.cells(
                    for: line,
                    expectedCount: headers.count
                ) {
                    normalizedRow(splitTableCells(line), count: headers.count)
                }
                rows.append(cells)
            }
            renderedLines.append(
                renderedRowLine(line, columnCount: headers.count, leadingPipe: headerUsesLeadingPipe)
            )
            renderedEndIndex = index + 1
            index += 1
        }
        let consumedLineCount = index - start

        return ChatStreamingMarkdownParsedTable(
            table: ChatStreamingMarkdownTable(
                id: "table-\(start)",
                markdown: renderedLines.joined(separator: "\n"),
                headers: includeParsedTableCells ? normalizedRow(headers, count: headers.count) : [],
                rows: rows
            ),
            consumedLineCount: consumedLineCount
        )
    }

    /// 行单元格数与表头一致时保留原始行文本；调整列数时仍保留 `\|`，
    /// 避免字面管道重新变成列分隔符。不足时补空单元格到表头列数——
    /// vendor 的 `Table+.swift` 会过滤「列数 ≠ 表头列数」的行，不补空则流式期
    /// 渲染出的部分行会在完成时被静默丢弃，形成「行消失」差分。
    private static func renderedRowLine(
        _ line: String,
        columnCount: Int,
        leadingPipe: Bool
    ) -> String {
        let cells = splitTableCells(line, preservingPipeEscapes: true)
        guard cells.count != columnCount else { return line }
        let padded = normalizedRow(cells, count: columnCount)
        let body = padded.joined(separator: " | ")
        return leadingPipe ? "| \(body) |" : body
    }

    private static func splitTableCells(_ line: String, preservingPipeEscapes: Bool = false) -> [String] {
        let characters = Array(line.trimmingCharacters(in: .whitespacesAndNewlines))
        var cells: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\",
               index + 1 < characters.count,
               characters[index + 1] == "|" {
                if preservingPipeEscapes { current.append("\\") }
                current.append("|")
                index += 2
                continue
            }
            if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        if cells.first?.isEmpty == true {
            cells.removeFirst()
        }
        if cells.last?.isEmpty == true {
            cells.removeLast()
        }
        return cells
    }

    private static func normalizedRow(_ cells: [String], count: Int) -> [String] {
        if cells.count == count {
            return cells
        }
        if cells.count > count {
            return Array(cells.prefix(count))
        }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    private static func isDelimiterLine(_ line: String, expectedCount: Int) -> Bool {
        let cells = splitTableCells(line)
        guard cells.count == expectedCount else { return false }
        return cells.allSatisfy { cell in
            let normalized = cell.replacingOccurrences(of: ":", with: "")
            return normalized.count >= 3 && normalized.allSatisfy { $0 == "-" }
        }
    }

    static func tableHeaderColumnCountForDetection(in line: String) -> Int? {
        let count = splitTableCells(line).count
        return count >= 2 ? count : nil
    }

    static func isDelimiterLineForDetection(_ line: String, expectedCount: Int) -> Bool {
        isDelimiterLine(line, expectedCount: expectedCount)
    }
}

private final class ChatStreamingMarkdownTableRowCache: @unchecked Sendable {
    static let shared = ChatStreamingMarkdownTableRowCache()

    private final class Box {
        let cells: [String]

        init(_ cells: [String]) {
            self.cells = cells
        }
    }

    private let cache = NSCache<NSString, Box>()
#if DEBUG
    private let metricsLock = NSLock()
    private var hitCount = 0
    private var missCount = 0
#endif

    private init() {
        cache.countLimit = 512
    }

    func cells(for line: String, expectedCount: Int, build: () -> [String]) -> [String] {
        let key = "\(expectedCount):\(line)" as NSString
        if let cached = cache.object(forKey: key) {
#if DEBUG
            recordHit()
#endif
            return cached.cells
        }
        let cells = build()
        cache.setObject(Box(cells), forKey: key)
#if DEBUG
        recordMiss()
#endif
        return cells
    }

#if DEBUG
    private func recordHit() {
        metricsLock.lock()
        hitCount += 1
        metricsLock.unlock()
    }

    private func recordMiss() {
        metricsLock.lock()
        missCount += 1
        metricsLock.unlock()
    }

    func resetForTesting() {
        cache.removeAllObjects()
        metricsLock.lock()
        hitCount = 0
        missCount = 0
        metricsLock.unlock()
    }

    var metricsForTesting: (hits: Int, misses: Int) {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return (hitCount, missCount)
    }
#endif
}

#if DEBUG
struct ChatStreamingMarkdownBlockParserTestBlock: Equatable {
    let kind: String
    let text: String
    let markdown: String
    let headers: [String]
    let rows: [[String]]
}

enum ChatStreamingMarkdownBlockParserTestSupport {
    static func containsTable(in text: String) -> Bool {
        ChatStreamingMarkdownBlockParser.containsTable(in: text)
    }

    static func blocks(
        in text: String,
        includeTrailingPartialTableRow: Bool
    ) -> [ChatStreamingMarkdownBlockParserTestBlock] {
        ChatStreamingMarkdownBlockParser.blocks(
            in: text,
            includeTrailingPartialTableRow: includeTrailingPartialTableRow,
            includeParsedTableCells: true
        ).map { block in
            switch block.kind {
            case .text(let content):
                return ChatStreamingMarkdownBlockParserTestBlock(
                    kind: "text",
                    text: content,
                    markdown: content,
                    headers: [],
                    rows: []
                )
            case .table(let table):
                return ChatStreamingMarkdownBlockParserTestBlock(
                    kind: "table",
                    text: "",
                    markdown: table.markdown,
                    headers: table.headers,
                    rows: table.rows
                )
            }
        }
    }

    static func productionTableCellCounts(in text: String) -> (headers: Int, rows: Int)? {
        for block in ChatStreamingMarkdownBlockParser.blocks(in: text) {
            if case .table(let table) = block.kind {
                return (table.headers.count, table.rows.count)
            }
        }
        return nil
    }

    static func resetRowCache() {
        ChatStreamingMarkdownTableRowCache.shared.resetForTesting()
    }

    static var rowCacheMetrics: (hits: Int, misses: Int) {
        ChatStreamingMarkdownTableRowCache.shared.metricsForTesting
    }
}

#endif
