import SwiftUI
import Shared
import SwiftStreamingMarkdown

enum ChatStreamingMarkdownTypography {
    static let baseHeadingSizes: [CGFloat] = [22, 19.5, 17.5, 16.5, 15.5, 14.5]

    static func bodyFonts(chatFont: IOSChatFont, pointSize: CGFloat) -> SwiftStreamingMarkdown.TextFonts {
        let regular = UIFont.systemFont(ofSize: pointSize, weight: .regular)
        let semibold = UIFont.systemFont(ofSize: pointSize, weight: .semibold)
        return SwiftStreamingMarkdown.TextFonts(
            normal: applyingChatFont(chatFont, to: regular),
            italic: applyingChatFont(chatFont, to: regular.withItalicTrait()),
            bold: applyingChatFont(chatFont, to: semibold),
            boldItalic: applyingChatFont(chatFont, to: semibold.withItalicTrait()),
            preferredLetterSpacing: 0,
            preferredLineHeight: nil
        )
    }

    static func headingFonts(chatFont: IOSChatFont, pointSize: CGFloat) -> SwiftStreamingMarkdown.TextFonts {
        let bold = UIFont.systemFont(ofSize: pointSize, weight: .bold)
        return SwiftStreamingMarkdown.TextFonts(
            normal: applyingChatFont(chatFont, to: bold),
            italic: applyingChatFont(chatFont, to: bold.withItalicTrait()),
            bold: applyingChatFont(chatFont, to: bold),
            boldItalic: applyingChatFont(chatFont, to: bold.withItalicTrait()),
            preferredLetterSpacing: 0,
            preferredLineHeight: nil
        )
    }

    static func inlineCodeFont(pointSize: CGFloat) -> UIFont {
        let codeSize = max(12, round(pointSize * 0.90 * 10) / 10)
        return UIFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
    }

    static func applyingChatFont(
        _ chatFont: IOSChatFont,
        to style: SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownHeadingTextStyle,
        pointSize: CGFloat = IOSChatFont.defaultBodyPointSize
    ) -> SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownHeadingTextStyle {
        let ratio = max(0.75, pointSize / IOSChatFont.defaultBodyPointSize)
        let scaled = baseHeadingSizes.map { headingFonts(chatFont: chatFont, pointSize: $0 * ratio) }
        return SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownHeadingTextStyle(
            h1Font: scaled[0],
            h2Font: scaled[1],
            h3Font: scaled[2],
            h4Font: scaled[3],
            h5Font: scaled[4],
            h6Font: scaled[5],
            textColor: style.textColor
        )
    }

    private static func applyingChatFont(
        _ chatFont: IOSChatFont,
        to fonts: SwiftStreamingMarkdown.TextFonts
    ) -> SwiftStreamingMarkdown.TextFonts {
        SwiftStreamingMarkdown.TextFonts(
            normal: applyingChatFont(chatFont, to: fonts.normal),
            italic: fonts.italic.map { applyingChatFont(chatFont, to: $0) },
            bold: fonts.bold.map { applyingChatFont(chatFont, to: $0) },
            boldItalic: fonts.boldItalic.map { applyingChatFont(chatFont, to: $0) },
            preferredLetterSpacing: fonts.preferredLetterSpacing,
            preferredLineHeight: fonts.preferredLineHeight
        )
    }

    private static func applyingChatFont(_ chatFont: IOSChatFont, to font: UIFont) -> UIFont {
        chatFont.applying(to: font)
    }
}

#if DEBUG
enum ChatStreamingMarkdownTypographyTestSupport {
    static func bodyFontName(chatFont: IOSChatFont) -> String {
        bodyFonts(chatFont: chatFont).normal.fontName
    }

    static func bodyFonts(chatFont: IOSChatFont) -> SwiftStreamingMarkdown.TextFonts {
        ChatStreamingMarkdownTypography.bodyFonts(chatFont: chatFont, pointSize: 17)
    }
}
#endif

private extension UIFont {
    /// 给已有字体叠加斜体符号特征,用于构造流式渲染器排版对齐所需的 boldItalic 变体。
    func withItalicTrait() -> UIFont {
        let traits = fontDescriptor.symbolicTraits.union(.traitItalic)
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
