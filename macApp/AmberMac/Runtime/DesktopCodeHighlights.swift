import AppKit
import Foundation

enum DesktopCodeHighlights {
    static func highlight(_ source: String, language: String, fontSize: Double) -> AttributedString {
        let result = NSMutableAttributedString(string: source, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), .foregroundColor: NSColor.labelColor,
        ])
        let language = language.lowercased().split(separator: " ").first.map(String.init) ?? ""
        let keywords: String
        let comment: String
        switch language {
        case "swift": keywords = "actor|async|await|break|case|catch|class|continue|default|defer|do|else|enum|extension|false|for|func|guard|if|import|in|init|is|let|nil|private|protocol|public|return|self|some|static|struct|switch|throw|throws|true|try|var|while"; comment = #"//[^\n]*|/\*[\s\S]*?\*/"#
        case "js", "javascript", "ts", "typescript": keywords = "async|await|break|case|catch|class|const|continue|default|delete|else|export|extends|false|for|from|function|if|import|in|instanceof|let|new|null|of|return|static|super|switch|this|throw|true|try|typeof|undefined|var|void|while|yield"; comment = #"//[^\n]*|/\*[\s\S]*?\*/"#
        case "python", "py": keywords = "and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|not|or|pass|raise|return|True|try|while|with|yield"; comment = #"#[^\n]*"#
        case "bash", "sh", "zsh": keywords = "case|do|done|elif|else|esac|export|fi|for|function|if|in|local|return|then|while"; comment = #"#[^\n]*"#
        case "json": keywords = "true|false|null"; comment = #"(?!)"#
        default: return AttributedString(result)
        }
        let pattern = "(?<comment>" + comment + #")|(?<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?<keyword>\b(?:"# + keywords + #")\b)|(?<number>\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return AttributedString(result) }
        let colors: [(String, NSColor)] = [("comment", .secondaryLabelColor), ("string", .systemRed), ("keyword", .systemBlue), ("number", .systemPurple)]
        regex.enumerateMatches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) { match, _, _ in
            guard let match else { return }
            for (name, color) in colors {
                let range = match.range(withName: name)
                if range.location != NSNotFound { result.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
        return AttributedString(result)
    }
}
