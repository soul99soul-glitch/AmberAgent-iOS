import AppKit
import iosMath
import SwiftUI

struct DesktopMathBlock: View {
    let source: String
    let fontSize: Double
    var body: some View {
        let parsed = MTMathUILabel()
        let _ = { parsed.latex = source }()
        if parsed.error != nil {
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

    func makeNSView(context: Context) -> MTMathUILabel { MTMathUILabel() }
    func updateNSView(_ view: MTMathUILabel, context: Context) {
        view.fontSize = fontSize
        view.textColor = scheme == .dark ? .white : .black
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
