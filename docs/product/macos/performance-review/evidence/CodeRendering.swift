import AppKit
import Foundation

enum CurrentHighlights {
    private static let warm = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.85, green: 0.75, blue: 0.60, alpha: 1) : NSColor(red: 0.48, green: 0.35, blue: 0.23, alpha: 1)
    }
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
        default: return AttributedString(result)
        }
        let pattern = "(?<comment>" + comment + #")|(?<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?<keyword>\b(?:"# + keywords + #")\b)|(?<number>\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return AttributedString(result) }
        let colors: [(String, NSColor)] = [("comment", .tertiaryLabelColor), ("string", Self.warm), ("keyword", .labelColor), ("number", Self.warm)]
        let bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        regex.enumerateMatches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) { match, _, _ in
            guard let match else { return }
            for (name, color) in colors {
                let range = match.range(withName: name)
                if range.location != NSNotFound {
                    result.addAttribute(.foregroundColor, value: color, range: range)
                    if name == "keyword" { result.addAttribute(.font, value: bold, range: range) }
                }
            }
        }
        return AttributedString(result)
    }
}

struct OneEntryCache {
    var key: (String, String, Double, Bool)?
    var value: AttributedString?
    mutating func highlight(_ source: String, language: String, fontSize: Double, dark: Bool) -> AttributedString {
        let next = (source, language, fontSize, dark)
        if let key, key.0 == next.0, key.1 == next.1, key.2 == next.2, key.3 == next.3, let value { return value }
        let value = CurrentHighlights.highlight(source, language: language, fontSize: fontSize)
        key = next; self.value = value
        return value
    }
}

let source = (0..<120).map { "let value\($0) = \($0) + 1 // repeat code for highlighting" }.joined(separator: "\n")
let iterations = 1_000
let coldStart = DispatchTime.now().uptimeNanoseconds
for _ in 0..<iterations { _ = CurrentHighlights.highlight(source, language: "swift", fontSize: 13) }
let cold = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1_000_000
var cache = OneEntryCache()
let warmStart = DispatchTime.now().uptimeNanoseconds
for _ in 0..<iterations { _ = cache.highlight(source, language: "swift", fontSize: 13, dark: false) }
let warm = Double(DispatchTime.now().uptimeNanoseconds - warmStart) / 1_000_000
print("CODE source_chars=\(source.count) iterations=\(iterations) cold_ms=\(String(format: "%.2f", cold)) one_entry_cache_ms=\(String(format: "%.2f", warm))")
