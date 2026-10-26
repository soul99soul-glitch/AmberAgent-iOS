import AppKit
import SwiftUI

/// Lets the transcript offer pinning for code blocks without coupling Markdown rendering to the shelf.
struct DesktopCodePinning {
    let isPinned: @MainActor (String) -> Bool
    let toggle: @MainActor (_ code: String, _ language: String) -> Void
}

extension EnvironmentValues {
    @Entry var desktopCodePinning: DesktopCodePinning?
}

struct DesktopMarkdown: View {
    let text: String
    var fontFamily: DesktopMessageFontFamily = .system
    var fontSize: Double = 15
    @State private var blocks: [DesktopMarkdownBlock] = []

    var body: some View {
        DesktopMarkdownBlocks(blocks: blocks, fontFamily: fontFamily, fontSize: fontSize)
            .font(fontFamily.swiftUIFont(size: fontSize))
            .onChange(of: text, initial: true) { _, value in blocks = DesktopMarkdownParser.parse(value) }
    }
}

private struct DesktopMarkdownBlocks: View {
    let blocks: [DesktopMarkdownBlock]
    let fontFamily: DesktopMessageFontFamily
    let fontSize: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    DesktopMathText.render(text, fontSize: fontSize, scheme: scheme)
                        .textSelection(.enabled)
                        .lineSpacing(fontSize / 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .heading(let text, let level):
                    DesktopMathText.render(text, fontSize: fontSize + (level == 1 ? 9 : level == 2 ? 6 : 2), scheme: scheme)
                        .font(fontFamily.swiftUIFont(size: fontSize + (level == 1 ? 9 : level == 2 ? 6 : 2), weight: .semibold))
                        .textSelection(.enabled)
                        .padding(.top, 8)
                case .code(let text, let language):
                    DesktopCodeBlock(text: text, language: language, fontSize: fontSize)
                case .math(let source):
                    ScrollView(.horizontal) {
                        DesktopMathBlock(source: source, fontSize: fontSize + 3)
                            .fixedSize()
                            .padding(.vertical, 4)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .table(let rows, let alignments):
                    DesktopMarkdownTable(rows: rows, alignments: alignments, fontFamily: fontFamily, fontSize: fontSize)
                case .list(let items):
                    DesktopMarkdownList(items: items, fontFamily: fontFamily, fontSize: fontSize)
                case .quote(let blocks):
                    DesktopMarkdownBlocks(blocks: blocks, fontFamily: fontFamily, fontSize: fontSize)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(DesktopTheme.border(scheme))
                                .frame(width: 2)
                        }
                case .divider:
                    Divider()
                }
            }
        }
    }
}

private struct DesktopMarkdownList: View {
    let items: [DesktopMarkdownListItem]
    let fontFamily: DesktopMessageFontFamily
    let fontSize: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let markerWidth = CGFloat(items.map { $0.marker.count }.max() ?? 1) * fontSize * 0.6 + 4
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.marker)
                        .font(.system(size: fontSize - 1, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: markerWidth, alignment: .trailing)
                    DesktopMathText.render(item.text, fontSize: fontSize, scheme: scheme)
                        .font(fontFamily.swiftUIFont(size: fontSize))
                        .textSelection(.enabled)
                        .lineSpacing(fontSize / 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.level) * 18)
            }
        }
    }
}

private struct DesktopCodeBlock: View {
    let text: String
    let language: String
    let fontSize: Double
    @Environment(\.colorScheme) private var scheme
    @Environment(\.desktopCodePinning) private var pinning
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let pinning {
                    let pinned = pinning.isPinned(text)
                    Button { pinning.toggle(text, language) } label: {
                        Label(pinned ? "已固定" : "固定", systemImage: pinned ? "pin.fill" : "pin").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(pinned ? "从产物架移除" : "固定到产物架")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制代码", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("复制代码")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            Divider()
            ScrollView(.horizontal) {
                Text(DesktopCodeHighlights.highlight(text.isEmpty ? " " : text, language: language, fontSize: fontSize - 2))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(14)
            }
        }
        .background(DesktopTheme.surface(scheme), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.border(scheme)))
        .onChange(of: text) { copied = false }
    }
}

private struct DesktopMarkdownTable: View {
    let rows: [[String]]
    let alignments: [DesktopMarkdownColumnAlignment]
    var fontFamily: DesktopMessageFontFamily = .system
    var fontSize: Double = 15
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let widths = columnWidths
        ScrollView(.horizontal) {
            DesktopMarkdownTableLayout(widths: widths) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        ForEach(0..<(rows.map(\.count).max() ?? 0), id: \.self) { column in
                            DesktopMathText.render(column < row.count ? row[column] : "", fontSize: fontSize - 1, scheme: scheme)
                                .font(fontFamily.swiftUIFont(size: fontSize - 1, weight: rowIndex == 0 ? .semibold : .regular))
                                .textSelection(.enabled)
                                .multilineTextAlignment(textAlignment(column))
                                .frame(width: widths[column] - 28, alignment: alignment(column))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .frame(maxHeight: .infinity, alignment: alignment(column))
                                .background(rowIndex == 0 ? DesktopTheme.surface(scheme) : .clear)
                                .border(DesktopTheme.border(scheme), width: 0.5)
                        }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var columnWidths: [CGFloat] {
        (0..<(rows.map(\.count).max() ?? 0)).map { column in
            let ideal = rows.enumerated().map { index, row in
                let text = column < row.count ? String(DesktopMarkdownInline.parse(row[column]).characters) : ""
                return NSAttributedString(string: text, attributes: [.font: tableFont(bold: index == 0)]).size().width
            }.max() ?? 0
            return min(280, max(110, ceil(ideal) + 28))
        }
    }

    private func tableFont(bold: Bool) -> NSFont {
        let size = fontSize - 1
        let weight: NSFont.Weight = bold ? .semibold : .regular
        switch fontFamily {
        case .system: return .systemFont(ofSize: size, weight: weight)
        case .mono: return .monospacedSystemFont(ofSize: size, weight: weight)
        case .serif:
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            return font.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? font
        }
    }

    private func alignment(_ column: Int) -> Alignment {
        switch column < alignments.count ? alignments[column] : .leading {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch column < alignments.count ? alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

// Measure each finite-width cell before assigning its row's shared natural height.
private struct DesktopMarkdownTableLayout: Layout {
    let widths: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: widths.reduce(0, +), height: rowHeights(subviews).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = rowHeights(subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            var x = bounds.minX
            for column in widths.indices {
                let index = row * widths.count + column
                guard index < subviews.count else { continue }
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: widths[column], height: height))
                x += widths[column]
            }
            y += height
        }
    }

    private func rowHeights(_ subviews: Subviews) -> [CGFloat] {
        guard !widths.isEmpty else { return [] }
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + widths.count - 1) / widths.count)
        for index in subviews.indices {
            let row = index / widths.count
            heights[row] = max(heights[row], subviews[index].sizeThatFits(ProposedViewSize(width: widths[index % widths.count], height: nil)).height)
        }
        return heights
    }
}
