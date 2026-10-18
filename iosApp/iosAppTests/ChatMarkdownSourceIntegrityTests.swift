import XCTest
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class ChatMarkdownSourceIntegrityTests: XCTestCase {
    func testTableRowPaddingPreservesEscapedPipeThroughRealRenderer() async throws {
        let markdown = """
        | 表达式 | 含义 |
        | --- | --- |
        | a \\| b |
        """

        for includeTrailingPartialTableRow in [false, true] {
            let block = try tableBlock(
                in: markdown,
                includeTrailingPartialTableRow: includeTrailingPartialTableRow
            )

            XCTAssertTrue(block.markdown.contains("a \\| b"))
            XCTAssertEqual(block.rows, [["a | b", ""]])
            let cells = try await renderedTableCells(in: block.markdown)
            XCTAssertEqual(cells, [["a | b", ""]])
        }
    }

    func testTableRowTruncationPreservesEscapedPipeThroughRealRenderer() async throws {
        let markdown = """
        | 表达式 | 含义 |
        | --- | --- |
        | a \\| b | retained | ignored |
        """

        for includeTrailingPartialTableRow in [false, true] {
            let block = try tableBlock(
                in: markdown,
                includeTrailingPartialTableRow: includeTrailingPartialTableRow
            )

            XCTAssertTrue(block.markdown.contains("a \\| b"))
            XCTAssertFalse(block.markdown.contains("ignored"))
            XCTAssertEqual(block.rows, [["a | b", "retained"]])
            let cells = try await renderedTableCells(in: block.markdown)
            XCTAssertEqual(cells, [["a | b", "retained"]])
        }
    }

    func testShorterFenceInsideFourBacktickCodeBlockDoesNotExposeTable() {
        let markdown = """
        ````markdown
        ```text
        | A | B |
        | --- | --- |
        | one | two |
        ```
        ````
        """

        assertTableRemainsInsideCodeFence(markdown)
    }

    func testFenceWithInfoCannotCloseCodeBlockAndExposeTable() {
        let markdown = """
        ```markdown
        ```not-a-closing-fence
        | A | B |
        | --- | --- |
        | one | two |
        ```
        """

        assertTableRemainsInsideCodeFence(markdown)
    }

    func testLongerClosingFenceWithTrailingWhitespaceReenablesTableDetection() throws {
        let markdown = [
            "````markdown",
            "| hidden A | hidden B |",
            "| --- | --- |",
            "| hidden one | hidden two |",
            "`````   ",
            "| visible A | visible B |",
            "| --- | --- |",
            "| visible one | visible two |"
        ].joined(separator: "\n")

        XCTAssertTrue(ChatStreamingMarkdownBlockParserTestSupport.containsTable(in: markdown))
        for includeTrailingPartialTableRow in [false, true] {
            let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
                in: markdown,
                includeTrailingPartialTableRow: includeTrailingPartialTableRow
            )
            XCTAssertEqual(blocks.map(\.kind), ["text", "table"])
            let table = try XCTUnwrap(blocks.last)
            XCTAssertEqual(table.headers, ["visible A", "visible B"])
            XCTAssertEqual(table.rows, [["visible one", "visible two"]])
        }
        XCTAssertTrue(
            ChatStreamingTableDetectionTestSupport.replay(cumulativeLinePrefixes(of: markdown)).containsTable
        )
    }

    private func tableBlock(
        in markdown: String,
        includeTrailingPartialTableRow: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ChatStreamingMarkdownBlockParserTestBlock {
        let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
            in: markdown,
            includeTrailingPartialTableRow: includeTrailingPartialTableRow
        )
        XCTAssertEqual(blocks.count, 1, file: file, line: line)
        let block = try XCTUnwrap(blocks.first, file: file, line: line)
        XCTAssertEqual(block.kind, "table", file: file, line: line)
        return block
    }

    private func renderedTableCells(
        in markdown: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [[String]] {
        let parsed = await MarkdownParserImpl().parse(text: markdown)
        let rendered = await RenderableDocument(document: parsed, config: .default)
        XCTAssertEqual(rendered.renderables.count, 1, file: file, line: line)
        guard case let .table(_, headers, rows, _) = try XCTUnwrap(
            rendered.renderables.first,
            file: file,
            line: line
        ) else {
            XCTFail("Expected a rendered table", file: file, line: line)
            return []
        }
        XCTAssertEqual(headers.count, 2, file: file, line: line)
        return rows.map { $0.map { $0.attributedString.string } }
    }

    private func assertTableRemainsInsideCodeFence(
        _ markdown: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            ChatStreamingMarkdownBlockParserTestSupport.containsTable(in: markdown),
            file: file,
            line: line
        )
        for includeTrailingPartialTableRow in [false, true] {
            let blocks = ChatStreamingMarkdownBlockParserTestSupport.blocks(
                in: markdown,
                includeTrailingPartialTableRow: includeTrailingPartialTableRow
            )
            XCTAssertEqual(blocks.map(\.kind), ["text"], file: file, line: line)
            XCTAssertEqual(blocks.first?.text, markdown, file: file, line: line)
        }
        XCTAssertFalse(
            ChatStreamingTableDetectionTestSupport.replay(cumulativeLinePrefixes(of: markdown)).containsTable,
            file: file,
            line: line
        )
    }

    private func cumulativeLinePrefixes(of markdown: String) -> [String] {
        var text = ""
        return markdown.components(separatedBy: "\n").enumerated().map { index, line in
            if index > 0 { text.append("\n") }
            text.append(line)
            return text
        }
    }
}
