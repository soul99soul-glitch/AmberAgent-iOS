import Foundation

struct IOSDeepReadTemplateValidationResult: Equatable, Sendable {
    var ok: Bool
    var error: String?

    static let valid = IOSDeepReadTemplateValidationResult(ok: true, error: nil)
}

enum IOSDeepReadHTMLSecurity {
    static let contentSecurityPolicy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data: amberfont:; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"

    static func hardenedDocument(_ html: String) -> String {
        let escapedPolicy = contentSecurityPolicy.replacingOccurrences(of: "\"", with: "&quot;")
        let meta = #"<meta http-equiv="Content-Security-Policy" content="\#(escapedPolicy)">"#
        if let head = tagRanges(named: "head", in: html).first(where: {
            !isClosingTag(String(html[$0]))
        }) {
            var hardened = html
            hardened.insert(contentsOf: meta, at: head.upperBound)
            return hardened
        }
        if let htmlTag = tagRanges(named: "html", in: html).first(where: {
            !isClosingTag(String(html[$0]))
        }) {
            var hardened = html
            hardened.insert(contentsOf: "<head>\(meta)</head>", at: htmlTag.upperBound)
            return hardened
        }
        return "<head>\(meta)</head>\(html)"
    }

    static func containsMetaRefresh(in html: String) -> Bool {
        tags(named: "meta", in: normalizedForInspection(html)).contains { tag in
            attributeValues(named: "http-equiv", in: tag).contains { value in
                value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "refresh"
            }
        }
    }

    static func containsExternalURLAttribute(in html: String) -> Bool {
        let normalized = normalizedForInspection(html)
        return tags(named: nil, in: normalized).contains { tag in
            ["href", "src"].contains { name in
                attributeValues(named: name, in: tag).contains(where: isExternalURLValue)
            }
        }
    }

    private static func normalizedForInspection(_ html: String) -> String {
        let numericUnescaped = decodeNumericCharacterReferences(in: html)
        return [
            "&colon;": ":",
            "&sol;": "/",
            "&Tab;": "\t",
            "&NewLine;": "\n",
        ].reduce(numericUnescaped) { partial, replacement in
            partial.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }

    private static func decodeNumericCharacterReferences(in html: String) -> String {
        let pattern = #"&#(?:(?:x|X)([0-9a-fA-F]+)|([0-9]+));?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let mutable = NSMutableString(string: html)
        let matches = regex.matches(
            in: html,
            range: NSRange(location: 0, length: (html as NSString).length)
        )
        for match in matches.reversed() {
            let hexRange = match.range(at: 1)
            let decimalRange = match.range(at: 2)
            let digits: String
            let radix: Int
            if hexRange.location != NSNotFound {
                digits = (html as NSString).substring(with: hexRange)
                radix = 16
            } else if decimalRange.location != NSNotFound {
                digits = (html as NSString).substring(with: decimalRange)
                radix = 10
            } else {
                continue
            }
            guard let value = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(value) else {
                continue
            }
            mutable.replaceCharacters(in: match.range, with: String(Character(scalar)))
        }
        return mutable as String
    }

    private static func isExternalURLValue(_ rawValue: String) -> Bool {
        let canonical = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .lowercased()
        if canonical.hasPrefix("//") { return true }
        return ["http:", "https:", "file:", "content:"].contains { canonical.hasPrefix($0) }
    }

    private static func tags(named name: String?, in html: String) -> [String] {
        tagRanges(named: name, in: html).map { String(html[$0]) }
    }

    private static func tagRanges(named name: String?, in html: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = html.startIndex
        while let opening = html[searchStart...].firstIndex(of: "<") {
            var cursor = html.index(after: opening)
            var quote: Character?
            var closing: String.Index?
            while cursor < html.endIndex {
                let character = html[cursor]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    closing = cursor
                    break
                }
                cursor = html.index(after: cursor)
            }
            guard let closing else { break }
            let upperBound = html.index(after: closing)
            let range = opening..<upperBound
            let tag = String(html[range])
            if let parsedName = parsedTagName(tag), name == nil || parsedName == name?.lowercased() {
                result.append(range)
            }
            searchStart = upperBound
        }
        return result
    }

    private static func parsedTagName(_ tag: String) -> String? {
        var body = tag.dropFirst().dropLast()
            .drop(while: { $0.isWhitespace })
        if body.first == "/" {
            body = body.dropFirst().drop(while: { $0.isWhitespace })
        }
        guard let first = body.first, first.isLetter else { return nil }
        return String(body.prefix(while: { character in
            character.isLetter || character.isNumber || character == ":" || character == "-"
        })).lowercased()
    }

    private static func isClosingTag(_ tag: String) -> Bool {
        tag.dropFirst().drop(while: { $0.isWhitespace }).first == "/"
    }

    private static func attributeValues(named name: String, in tag: String) -> [String] {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?is)\b\#(escapedName)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = tag as NSString
        return regex.matches(in: tag, range: NSRange(location: 0, length: source.length)).compactMap { match in
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                return source.substring(with: match.range(at: index))
            }
            return nil
        }
    }

}

enum IOSDeepReadTemplateValidator {
    static let maxHTMLBytes = 96 * 1024

    static func validateHTML(_ html: String, requirePlaceholders: Bool = true) -> IOSDeepReadTemplateValidationResult {
        let byteCount = html.data(using: .utf8)?.count ?? 0
        if byteCount > maxHTMLBytes {
            return .init(ok: false, error: "模板过大：\(byteCount) bytes。")
        }
        if html.range(of: #"(?is)<\s*(html\b|!doctype\s+html)"#, options: .regularExpression) == nil {
            return .init(ok: false, error: "模板必须包含 <html> 或 <!DOCTYPE html>。")
        }
        let blocked: [(String, String)] = [
            (#"(?is)<\s*script\b"#, "模板不允许 JavaScript。"),
            (#"(?is)\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, "模板不允许事件处理器。"),
            (#"(?is)<\s*(iframe|object|embed|form|input|button|textarea|select)\b"#, "模板不允许交互或嵌入元素。"),
            (#"(?is)<\s*(svg|canvas|math|audio|video|source|picture|track)\b"#, "模板不允许媒体、Canvas 或 SVG。"),
            (#"(?is)\b(srcset|poster)\s*="#, "模板不允许响应式或媒体资源属性。"),
            (#"(?is)@import\b"#, "模板不允许 CSS import。"),
            (#"(?is)url\s*\("#, "模板不允许 CSS URL。"),
            (#"(?is)\b(fetch|XMLHttpRequest|WebSocket|EventSource|localStorage|sessionStorage|indexedDB|eval)\b"#, "模板不允许浏览器 API。")
        ]
        for (pattern, message) in blocked where html.range(of: pattern, options: .regularExpression) != nil {
            return .init(ok: false, error: message)
        }
        if IOSDeepReadHTMLSecurity.containsMetaRefresh(in: html) {
            return .init(ok: false, error: "模板不允许 meta refresh 导航。")
        }
        if IOSDeepReadHTMLSecurity.containsExternalURLAttribute(in: html) {
            return .init(ok: false, error: "模板不允许硬编码外部链接或资源。")
        }
        if requirePlaceholders {
            let requiredPlaceholders = [
                "{{title}}",
                "{{summary}}",
                "{{analysis_html}}",
                "{{extended_reading_html}}",
                "{{font_css}}"
            ]
            if let missing = requiredPlaceholders.first(where: { !html.contains($0) }) {
                return .init(ok: false, error: "模板缺少必要占位符：\(missing)。")
            }
        }
        return .valid
    }
}
