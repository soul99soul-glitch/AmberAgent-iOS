import SwiftUI
import Shared
import SwiftStreamingMarkdown

enum ChatStreamingMarkdownTypography {
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

    static func applyingChatFont(
        _ chatFont: IOSChatFont,
        to style: SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownHeadingTextStyle
    ) -> SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownHeadingTextStyle {
        SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownHeadingTextStyle(
            h1Font: applyingChatFont(chatFont, to: style.h1Font),
            h2Font: applyingChatFont(chatFont, to: style.h2Font),
            h3Font: applyingChatFont(chatFont, to: style.h3Font),
            h4Font: applyingChatFont(chatFont, to: style.h4Font),
            h5Font: applyingChatFont(chatFont, to: style.h5Font),
            h6Font: applyingChatFont(chatFont, to: style.h6Font),
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
