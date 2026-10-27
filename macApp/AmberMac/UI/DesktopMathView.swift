import AppKit
import iosMath
import SwiftUI

struct DesktopMathBlock: View {
    let source: String
    let fontSize: Double
    @State private var validityCache = DesktopMathBlockValidityCache()

    var body: some View {
        if !validityCache.isValid(source) {
            Text(verbatim: "$$\n" + source + "\n$$")
                .font(.system(size: fontSize - 2, design: .monospaced))
                .textSelection(.enabled)
                .help("此公式未能解析，保留原文。")
        } else {
            DesktopMathView(source: source, fontSize: fontSize)
        }
    }
}

struct DesktopMathView: NSViewRepresentable {
    let source: String
    let fontSize: Double
    @Environment(\.colorScheme) private var scheme

    final class Coordinator {
        var source: String?
        var fontSize: Double?
        var dark: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MTMathUILabel { MTMathUILabel() }
    func updateNSView(_ view: MTMathUILabel, context: Context) {
        let dark = scheme == .dark
        guard context.coordinator.source != source || context.coordinator.fontSize != fontSize
            || context.coordinator.dark != dark else { return }
        context.coordinator.source = source
        context.coordinator.fontSize = fontSize
        context.coordinator.dark = dark
        view.fontSize = fontSize
        view.textColor = dark ? .white : .black
        view.labelMode = .display
        view.latex = source
        view.setAccessibilityLabel("公式：" + source)
        view.invalidateIntrinsicContentSize()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return CGSize(width: ceil(size.width), height: ceil(size.height) + 1)
    }
}

private final class DesktopMathBlockValidityCache {
    private var source: String?
    private var valid = false

    @MainActor func isValid(_ source: String) -> Bool {
        if self.source == source { return valid }
        let parsed = MTMathUILabel()
        parsed.latex = source
        self.source = source
        valid = parsed.error == nil
        return valid
    }
}

private final class DesktopMathTextCache {
    private struct Key: Equatable {
        let source: String
        let fontSize: Double
        let dark: Bool
    }

    private var key: Key?
    private var value: Text?

    @MainActor
    func render(source: String, fontSize: Double, dark: Bool) -> Text {
        let next = Key(source: source, fontSize: fontSize, dark: dark)
        if key == next, let value { return value }
        let rendered = DesktopMathText.render(source, fontSize: fontSize, scheme: dark ? .dark : .light)
        key = next
        value = rendered
        return rendered
    }
}

struct DesktopMathTextView: View {
    let source: String
    let fontSize: Double
    @Environment(\.colorScheme) private var scheme
    @State private var cache = DesktopMathTextCache()

    var body: some View {
        cache.render(source: source, fontSize: fontSize, dark: scheme == .dark)
    }
}

@MainActor enum DesktopMathText {
    static func render(_ source: String, fontSize: Double, scheme: ColorScheme) -> Text {
        var result = Text("")
        for segment in DesktopMathTokenizer.inline(source) {
            switch segment {
            case .text(let value): result = result + Text(DesktopMarkdownInline.parse(value))
            case .formula(let value):
                let label = MTMathUILabel()
                label.fontSize = fontSize
                label.labelMode = .text
                label.textColor = scheme == .dark ? .white : .black
                label.latex = value
                let size = label.intrinsicContentSize
                guard label.error == nil, size.width > 0, size.height > 0 else { result = result + Text(verbatim: "$" + value + "$"); continue }
                label.frame = CGRect(origin: .zero, size: CGSize(width: ceil(size.width), height: ceil(size.height) + 1))
                label.layoutSubtreeIfNeeded()
                guard let bitmap = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { result = result + Text(verbatim: value); continue }
                label.cacheDisplay(in: label.bounds, to: bitmap)
                let image = NSImage(size: label.bounds.size)
                image.addRepresentation(bitmap)
                result = result + Text(Image(nsImage: image)).baselineOffset(-CGFloat(label.displayList?.descent ?? 0))
            }
        }
        return result
    }
}
