import Foundation

enum DeepReadTextExporter {
    static func text(from markdown: String) -> String {
        guard let data = MarkdownBridge.parse(markdown),
              let root = PackedAstReader(data: data)?.root() else { return markdown }
        return render(root, source: Array(markdown.utf8)).trimmingCharacters(in: .newlines)
    }

    private static func render(_ node: PackedAstNode, source: [UInt8]) -> String {
        let children = node.children
        switch node.type {
        case .root, .blockquote:
            return children.map { render($0, source: source) }.joined(separator: "\n\n")
        case .listUnordered, .listOrdered:
            let start = node.extras.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
            return children.enumerated().map { index, item in
                let marker = node.type == .listOrdered ? "\(start + UInt64(index))." : "-"
                return marker + " " + render(item, source: source).replacingOccurrences(of: "\n", with: "\n  ")
            }.joined(separator: "\n")
        case .listItem:
            let hasBlocks = children.contains { [.paragraph, .listOrdered, .listUnordered, .codeBlock, .blockquote].contains($0.type) }
            return children.map { render($0, source: source) }.joined(separator: hasBlocks ? "\n" : "")
        case .table:
            return children.map { render($0, source: source) }.joined(separator: "\n")
        case .tableHead, .tableRow:
            let separator = children.first?.type == .tableRow ? "\n" : "\t"
            return children.map { render($0, source: source) }.joined(separator: separator)
        case .codeBlock:
            return children.map { slice($0, source: source) }.joined().trimmingCharacters(in: .newlines)
        case .inlineCode, .text:
            let raw = slice(node, source: source)
            let inline = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return inline.map { String($0.characters) } ?? raw
        case .softBreak, .hardBreak:
            return "\n"
        case .taskListMarker:
            return slice(node, source: source) + " "
        case .horizontalRule:
            return "---"
        default:
            return children.isEmpty ? slice(node, source: source) : children.map { render($0, source: source) }.joined()
        }
    }

    private static func slice(_ node: PackedAstNode, source: [UInt8]) -> String {
        String(decoding: source[node.startOffset..<node.endOffset], as: UTF8.self)
    }
}
