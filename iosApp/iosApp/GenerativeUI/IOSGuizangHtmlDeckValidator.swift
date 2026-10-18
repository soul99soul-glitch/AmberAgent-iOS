import Foundation

enum IOSGuizangHtmlDeckValidator {
    static let renderer = "full_html"
    static let legacyRenderer = "guizang_html"
    static let maxHTMLBytes = 1_500_000
    static let localMotionURL = "amber-full-html://runtime/motion.min.js"
    static let localLucideURL = "amber-full-html://runtime/lucide.min.js"
    static let localThreeURL = "amber-full-html://runtime/three.min.js"
    static let remoteResourceScheme = "amber-full-html-resource"
    static let motionAssetPath = "generative-libs/guizang/motion.min.js"
    static let lucideAssetPath = "generative-libs/guizang/lucide.min.js"

    struct DeckSpec: Equatable {
        let html: String
        var source: String?
        var allowRemoteImages = true
        var allowRemoteFonts = true
    }

    struct ValidationResult: Equatable {
        let valid: Bool
        var reason: String?
    }

    enum RuntimeAsset {
        case motion
        case lucide
        case three

        var resourceName: String {
            switch self {
            case .motion: "motion.min"
            case .lucide: "lucide.min"
            case .three: "three.min"
            }
        }
    }

    enum RemoteResourceKind: String, Sendable {
        case image
        case stylesheet
        case font
    }

    static func isRenderer(_ renderer: String?) -> Bool {
        let lower = renderer?.lowercased()
        return lower == Self.renderer || lower == legacyRenderer
    }

    static func normalizeSpecJson(_ specJson: String) -> DeckSpec? {
        guard let obj = jsonObject(specJson),
              let html = obj.string("html")?.nilIfBlank else {
            return nil
        }
        return DeckSpec(
            html: html,
            source: obj.string("source"),
            allowRemoteImages: obj.bool("allowRemoteImages") ?? true,
            allowRemoteFonts: obj.bool("allowRemoteFonts") ?? true
        )
    }

    static func validateSpecJson(_ specJson: String) -> ValidationResult {
        guard let spec = normalizeSpecJson(specJson) else {
            return ValidationResult(valid: false, reason: "expected spec.html")
        }
        return validateDeck(spec)
    }

    static func validateDeck(_ spec: DeckSpec) -> ValidationResult {
        validateHtml(spec.html)
    }

    /// G6: SLIDES 路由（expectSlides）仍要求 slide 结构，deck 校验不变；
    /// 非 slides 的 full_html（单页海报、文章页）放宽为「完整 HTML 即可」——
    /// 按既有结构标记（deck/card-set/poster/slides 等）识别，不再强制 slide。
    static func validateHtml(_ html: String, expectSlides: Bool = false) -> ValidationResult {
        if html.utf8.count > maxHTMLBytes {
            return ValidationResult(valid: false, reason: "html too large: max \(maxHTMLBytes / 1_000)KB")
        }
        let runtimeHtml = prepareRuntimeHtml(html)
        if expectSlides {
            guard hasSlideLikeContent(runtimeHtml) else {
                return ValidationResult(valid: false, reason: "expected at least one slide element: <section class=\"slide ...\">")
            }
        } else {
            guard IOSGenerativeWidgetParser.looksLikeStandaloneHtml(runtimeHtml) else {
                return ValidationResult(valid: false, reason: "expected a complete HTML document or a deck/card-set/poster structure")
            }
        }
        for rule in blockedRules where runtimeHtml.containsMatch(pattern: rule.pattern) {
            return ValidationResult(valid: false, reason: rule.reason)
        }
        return validateExternalScripts(runtimeHtml)
    }

    static func prepareRuntimeHtml(_ html: String) -> String {
        normalizeDeckStructure(rewriteRuntimeUrls(html))
    }

    static func prepareRuntimeHtml(_ spec: DeckSpec) -> String {
        let runtimeHtml = prepareRuntimeHtml(spec.html)
        let resourceScopedHtml = rewriteRemoteResourceUrls(
            runtimeHtml,
            allowRemoteImages: spec.allowRemoteImages,
            allowRemoteFonts: spec.allowRemoteFonts
        )
        return injectResourceContentSecurityPolicy(resourceScopedHtml)
    }

    static func rewriteRuntimeUrls(_ html: String) -> String {
        html
            .replacing(pattern: #"https://amberagent\.local/(?:full-html|guizang)/motion\.min\.js"#, with: localMotionURL)
            .replacing(pattern: #"https://amberagent\.local/(?:full-html|guizang)/lucide\.min\.js"#, with: localLucideURL)
            .replacing(pattern: #"https://amberagent\.local/(?:full-html|guizang)/three\.min\.js"#, with: localThreeURL)
            .replacing(pattern: #"https://unpkg\.com/lucide(?:@[^/"'`\s<>]+)?(?:/dist/umd/lucide(?:\.min)?\.js)?"#, with: localLucideURL)
            .replacing(pattern: #"https://cdn\.jsdelivr\.net/npm/lucide(?:@[^/"'`\s<>]+)?(?:/dist/umd/lucide(?:\.min)?\.js)?"#, with: localLucideURL)
            .replacing(pattern: #"https://cdn\.jsdelivr\.net/npm/motion(?:@[^/"'`\s<>]+)?/\+esm"#, with: localMotionURL)
            .replacing(pattern: #"https://unpkg\.com/motion(?:@[^/"'`\s<>]+)?(?:/\+esm)?"#, with: localMotionURL)
            .replacing(pattern: #"(?<=['"])(?:\./)?assets/motion\.min\.js(?=['"])"#, with: localMotionURL)
            .replacing(pattern: #"(?<=['"])(?:\./)?assets/lucide\.min\.js(?=['"])"#, with: localLucideURL)
    }

    static func rewriteRemoteResourceUrls(
        _ html: String,
        allowRemoteImages: Bool,
        allowRemoteFonts: Bool
    ) -> String {
        let rewrittenAttributes = html.replacingMatches(pattern: #"<[a-zA-Z][^>]*>"#) { match, source in
            guard let range = Range(match.range, in: source) else { return "" }
            return rewriteRemoteResourceAttributes(
                in: String(source[range]),
                allowRemoteImages: allowRemoteImages,
                allowRemoteFonts: allowRemoteFonts
            )
        }
        return rewriteCSSRemoteResourceUrls(
            rewrittenAttributes,
            allowRemoteImages: allowRemoteImages,
            allowRemoteFonts: allowRemoteFonts
        )
    }

    static func runtimeAssetForURL(_ url: String) -> RuntimeAsset? {
        let normalized = rewriteRuntimeUrls(url.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
        if normalized == localMotionURL.lowercased() { return .motion }
        if normalized == localLucideURL.lowercased() { return .lucide }
        if normalized == localThreeURL.lowercased() { return .three }
        return nil
    }

    static func isAllowedRemoteImage(_ url: String) -> Bool {
        let lower = url.split(separator: "?", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        return lower.hasPrefix("https://") && [".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif"].contains {
            lower.hasSuffix($0)
        }
    }

    static func isAllowedRemoteFontOrStylesheet(_ url: String) -> Bool {
        let lower = url.split(separator: "?", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        if lower.hasPrefix("https://fonts.googleapis.com/") || lower.hasPrefix("https://fonts.gstatic.com/") {
            return true
        }
        return lower.hasPrefix("https://") && [".css", ".woff", ".woff2", ".ttf", ".otf"].contains {
            lower.hasSuffix($0)
        }
    }

    static func remoteResourceURL(originalURL: String, kind: RemoteResourceKind) -> String? {
        guard let parsed = URL(string: originalURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed.scheme?.lowercased() == "https",
              !parsed.absoluteString.isEmpty else {
            return nil
        }
        let encoded = Data(parsed.absoluteString.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(remoteResourceScheme)://\(kind.rawValue)/\(encoded)"
    }

    static func remoteResourceOriginalURL(from url: URL) -> (kind: RemoteResourceKind, originalURL: String)? {
        guard url.scheme?.lowercased() == remoteResourceScheme,
              let host = url.host?.lowercased(),
              let kind = RemoteResourceKind(rawValue: host) else {
            return nil
        }
        let encoded = url.pathComponents.dropFirst().joined()
        guard !encoded.isEmpty else { return nil }
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        guard let data = Data(base64Encoded: base64),
              let originalURL = String(data: data, encoding: .utf8),
              URL(string: originalURL)?.scheme?.lowercased() == "https" else {
            return nil
        }
        return (kind, originalURL)
    }

    static func isAllowedRemoteResource(kind: RemoteResourceKind, url: String) -> Bool {
        switch kind {
        case .image:
            isAllowedRemoteImage(url)
        case .stylesheet, .font:
            isAllowedRemoteFontOrStylesheet(url)
        }
    }

    private struct BlockedRule {
        let pattern: String
        let reason: String
    }

    private static let blockedRules: [BlockedRule] = [
        BlockedRule(pattern: #"file://"#, reason: "file:// is not allowed"),
        BlockedRule(pattern: #"content://"#, reason: "content:// is not allowed"),
        BlockedRule(pattern: #"intent://"#, reason: "intent:// is not allowed"),
        BlockedRule(pattern: #"\baddJavascriptInterface\b"#, reason: "native bridge access is not allowed"),
        BlockedRule(pattern: #"\bAmberWidget\b"#, reason: "AmberWidget bridge access is not allowed"),
        BlockedRule(pattern: #"\bwindow\.open\s*\("#, reason: "popups are not allowed"),
        BlockedRule(pattern: #"\btarget\s*=\s*(['"])_blank\1"#, reason: "new windows are not allowed"),
        BlockedRule(pattern: #"<a\b[^>]*\bdownload(?:\s|=|>)"#, reason: "downloads are not allowed"),
        BlockedRule(pattern: #"<iframe\b|<object\b|<embed\b"#, reason: "embedded frames are not allowed"),
        BlockedRule(pattern: #"<form\b|<input\b[^>]*\btype\s*=\s*(['"])file\1"#, reason: "form/file input is not allowed"),
        BlockedRule(pattern: #"\bfetch\s*\("#, reason: "network fetch is not allowed"),
        BlockedRule(pattern: #"\bXMLHttpRequest\b"#, reason: "XMLHttpRequest is not allowed"),
        BlockedRule(pattern: #"\bWebSocket\s*\("#, reason: "WebSocket is not allowed"),
        BlockedRule(pattern: #"\bEventSource\s*\("#, reason: "EventSource is not allowed"),
        BlockedRule(pattern: #"\bnavigator\.serviceWorker\b"#, reason: "service workers are not allowed"),
        BlockedRule(pattern: #"\bnavigator\.geolocation\b"#, reason: "geolocation is not allowed"),
        BlockedRule(pattern: #"\bgetUserMedia\s*\("#, reason: "camera/microphone access is not allowed"),
        BlockedRule(pattern: #"\bNotification\.requestPermission\b"#, reason: "notifications are not allowed"),
        BlockedRule(pattern: #"\bmodulepreload\b"#, reason: "module preloads are not allowed"),
    ]

    /// 是否含 slide 结构。被 ChatKernelRunHost 的终态校验（SLIDES 路由）
    /// 复用，因此不设 private。
    static func hasSlideLikeContent(_ html: String) -> Bool {
        html.containsMatch(pattern: #"<(?:section|article|div)\b(?=[^>]*(?:\bclass\s*=\s*(?:"[^"]*\bslide\b[^"]*"|'[^']*\bslide\b[^']*'|[^\s>]*\bslide\b[^\s>]*)|\bdata-slide(?:\s|=|>)))[^>]*>"#)
    }

    private static func rewriteRemoteResourceAttributes(
        in tag: String,
        allowRemoteImages: Bool,
        allowRemoteFonts: Bool
    ) -> String {
        guard let tagName = openTagName(tag) else { return tag }
        return tag.replacingMatches(pattern: #"\s+(src|href|xlink:href)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#) { match, source in
            guard let wholeRange = Range(match.range, in: source),
                  let attrRange = Range(match.range(at: 1), in: source) else {
                return ""
            }
            let original = String(source[wholeRange])
            let attribute = String(source[attrRange]).lowercased()
            let rawValue = (3...5).compactMap { index -> String? in
                guard let valueRange = Range(match.range(at: index), in: source), !valueRange.isEmpty else {
                    return nil
                }
                return String(source[valueRange])
            }.first ?? ""
            guard rawValue.lowercased().hasPrefix("https://") else {
                return original
            }
            guard let kind = remoteResourceKind(
                tagName: tagName,
                attribute: attribute,
                url: rawValue,
                allowRemoteImages: allowRemoteImages,
                allowRemoteFonts: allowRemoteFonts
            ),
                  let rewrittenURL = remoteResourceURL(originalURL: rawValue, kind: kind) else {
                return " data-amber-blocked-\(attribute.replacingOccurrences(of: ":", with: "-"))=\"\""
            }
            return " \(attribute)=\"\(escapeXML(rewrittenURL))\""
        }
    }

    private static func rewriteCSSRemoteResourceUrls(
        _ html: String,
        allowRemoteImages: Bool,
        allowRemoteFonts: Bool
    ) -> String {
        html.replacingMatches(pattern: #"url\(\s*(['"]?)(https://[^'"()\s]+)\1\s*\)"#) { match, source in
            guard let urlRange = Range(match.range(at: 2), in: source) else {
                return #"url("")"#
            }
            let url = String(source[urlRange])
            let kind: RemoteResourceKind?
            if allowRemoteImages, isAllowedRemoteImage(url) {
                kind = .image
            } else if allowRemoteFonts, isAllowedRemoteFontOrStylesheet(url) {
                kind = .font
            } else {
                kind = nil
            }
            guard let kind, let rewrittenURL = remoteResourceURL(originalURL: url, kind: kind) else {
                return #"url("")"#
            }
            return #"url("\#(rewrittenURL)")"#
        }
    }

    private static func remoteResourceKind(
        tagName: String,
        attribute: String,
        url: String,
        allowRemoteImages: Bool,
        allowRemoteFonts: Bool
    ) -> RemoteResourceKind? {
        if allowRemoteImages,
           ["img", "image", "source"].contains(tagName),
           ["src", "href", "xlink:href"].contains(attribute),
           isAllowedRemoteImage(url) {
            return .image
        }
        if allowRemoteFonts,
           tagName == "link",
           attribute == "href",
           isAllowedRemoteFontOrStylesheet(url) {
            return .stylesheet
        }
        return nil
    }

    private static func openTagName(_ tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^<\s*([a-zA-Z][a-zA-Z0-9:-]*)"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else {
            return nil
        }
        return String(tag[range]).lowercased()
    }

    private static func injectResourceContentSecurityPolicy(_ html: String) -> String {
        let contentSecurityPolicy = """
        default-src 'none'; script-src 'unsafe-inline' amber-full-html:; style-src 'unsafe-inline' \(remoteResourceScheme):; img-src data: blob: \(remoteResourceScheme):; font-src data: \(remoteResourceScheme):; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'
        """
        let meta = #"<meta http-equiv="Content-Security-Policy" content="\#(escapeXML(contentSecurityPolicy.compactSpaces()))">"#
        let stripped = html.replacing(
            pattern: #"<meta\b[^>]*http-equiv\s*=\s*(?:"Content-Security-Policy"|'Content-Security-Policy'|Content-Security-Policy)[^>]*>"#,
            with: ""
        )
        guard let regex = try? NSRegularExpression(pattern: #"<head\b[^>]*>"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
              let range = Range(match.range, in: stripped) else {
            return "<head>\(meta)</head>\n" + stripped
        }
        return stripped.replacingCharacters(in: range.upperBound..<range.upperBound, with: "\n\(meta)")
    }

    private static func normalizeDeckStructure(_ html: String) -> String {
        var output = html
        output = output.replacingMatches(pattern: #"<(div|main)\b(?=[^>]*(?:\bid\s*=\s*(?:"deck"|'deck')|\bclass\s*=\s*(?:"[^"]*\b(?:deck|slides)\b[^"]*"|'[^']*\b(?:deck|slides)\b[^']*'|[^\s>]*\b(?:deck|slides)\b[^\s>]*)))[^>]*>"#) { match, source in
            guard let range = Range(match.range, in: source) else { return "" }
            var tag = String(source[range])
            if !tag.containsMatch(pattern: #"\bid\s*="#) {
                tag = appendAttribute("id=\"deck\"", to: tag)
            }
            return tag
        }
        output = output.replacingMatches(pattern: #"<(div|main)\b(?=[^>]*(?:\bid\s*=\s*(?:"card-set"|'card-set')|\bclass\s*=\s*(?:"[^"]*\b(?:card-set|poster-set|social-card-set)\b[^"]*"|'[^']*\b(?:card-set|poster-set|social-card-set)\b[^']*'|[^\s>]*\b(?:card-set|poster-set|social-card-set)\b[^\s>]*)))[^>]*>"#) { match, source in
            guard let range = Range(match.range, in: source) else { return "" }
            var tag = String(source[range])
            if !tag.containsMatch(pattern: #"\bdata-guizang-deck(?:\s|=|>)"#) {
                tag = appendAttribute("data-guizang-deck", to: tag)
            }
            return tag
        }
        output = output.replacingMatches(pattern: #"<(section|article)\b(?=[^>]*\bclass\s*=\s*(?:"[^"]*\b(?:poster|xhs|wide|square|social-card)\b[^"]*"|'[^']*\b(?:poster|xhs|wide|square|social-card)\b[^']*'|[^\s>]*\b(?:poster|xhs|wide|square|social-card)\b[^\s>]*))[^>]*>"#) { match, source in
            guard let range = Range(match.range, in: source) else { return "" }
            return addClassTokens(["slide", "social-card"], to: String(source[range]))
        }
        if output.containsMatch(pattern: #"<(?:div|main)\b(?=[^>]*(?:\bid\s*=\s*(?:"deck"|'deck')|\bclass\s*=\s*(?:"[^"]*\b(?:deck|slides)\b[^"]*"|'[^']*\b(?:deck|slides)\b[^']*'|[^\s>]*\b(?:deck|slides)\b[^\s>]*)))[^>]*>"#) {
            output = output.replacingMatches(pattern: #"<(section|article)\b[^>]*>"#) { match, source in
                guard let range = Range(match.range, in: source) else { return "" }
                return addClassTokens(["slide"], to: String(source[range]))
            }
        }
        return output
    }

    private static func validateExternalScripts(_ html: String) -> ValidationResult {
        let scriptPattern = #"<script\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        if let regex = try? NSRegularExpression(pattern: scriptPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                let url = (1...3).compactMap { idx -> String? in
                    guard let range = Range(match.range(at: idx), in: html), !range.isEmpty else { return nil }
                    return String(html[range])
                }.first ?? ""
                if runtimeAssetForURL(url) == nil {
                    return ValidationResult(valid: false, reason: "external script is not an allowed full_html runtime asset: \(String(url.prefix(80)))")
                }
            }
        }
        for pattern in [#"\bimport\s*\(\s*(['"])(.*?)\1\s*\)"#, #"\bfrom\s*(['"])(.*?)\1"#] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                    guard let range = Range(match.range(at: 2), in: html) else { continue }
                    let url = String(html[range])
                    if looksLikeExternalScriptReference(url), runtimeAssetForURL(url) == nil {
                        return ValidationResult(valid: false, reason: "module import is not an allowed full_html runtime asset: \(String(url.prefix(80)))")
                    }
                }
            }
        }
        return ValidationResult(valid: true)
    }

    private static func looksLikeExternalScriptReference(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("http://") ||
            lower.hasPrefix("https://") ||
            lower.hasSuffix(".js") ||
            lower.hasSuffix(".mjs") ||
            lower.contains("/+esm")
    }

    private static func appendAttribute(_ attribute: String, to openTag: String) -> String {
        guard let end = openTag.lastIndex(of: ">") else { return openTag }
        let insertAt = openTag.index(before: end) >= openTag.startIndex && openTag[openTag.index(before: end)] == "/" ? openTag.index(before: end) : end
        return String(openTag[..<insertAt]) + " " + attribute + String(openTag[insertAt...])
    }

    private static func addClassTokens(_ tokens: [String], to openTag: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\bclass\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: openTag, range: NSRange(openTag.startIndex..., in: openTag)) else {
            return appendAttribute("class=\"\(tokens.joined(separator: " "))\"", to: openTag)
        }
        let existing = (1...3).compactMap { idx -> String? in
            guard let range = Range(match.range(at: idx), in: openTag), !range.isEmpty else { return nil }
            return String(openTag[range])
        }.first ?? ""
        var parts = existing.split(whereSeparator: \.isWhitespace).map(String.init)
        for token in tokens where !parts.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) {
            parts.append(token)
        }
        guard let classRange = Range(match.range, in: openTag) else { return openTag }
        return openTag.replacingCharacters(in: classRange, with: "class=\"\(parts.joined(separator: " "))\"")
    }
}

