import Foundation

enum IOSVChartSpecValidator {
    private static let maxSpecBytes = 51_200
    private static let maxArrayElements = 1_000
    private static let maxStringLength = 500
    private static let maxSlideStringLength = 800
    private static let maxDepth = 12
    private static let supportedSlideLayouts: Set<String> = [
        "cover", "section", "quote", "split", "metrics", "timeline",
        "cards", "image-grid", "comparison", "closing",
    ]
    private static let blockedPatterns = [
        "javascript:", "<script", "</script", "eval(", "Function(",
        "new Function", "__proto__", "constructor[", "prototype.",
        "setTimeout(", "setInterval(", "atob(", "btoa(", "srcdoc",
        "onerror=", "onload=", "data:text/html",
    ]

    struct ValidationResult: Equatable {
        let valid: Bool
        var reason: String?
    }

    static func validateChartSpec(_ specJson: String) -> ValidationResult {
        if specJson.utf8.count > maxSpecBytes {
            return ValidationResult(valid: false, reason: "spec too large: \(specJson.utf8.count) bytes")
        }
        guard let obj = jsonValue(specJson) as? [String: Any] else {
            return ValidationResult(valid: false, reason: "expected JSON object")
        }
        return validateElement(obj, depth: 0, maxStringLength: maxStringLength)
    }

    static func validateSlidesSpec(_ slidesJson: String) -> ValidationResult {
        if slidesJson.utf8.count > maxSpecBytes {
            return ValidationResult(valid: false, reason: "slides too large: \(slidesJson.utf8.count) bytes")
        }
        guard let normalized = normalizeSlidesDeckSpecJson(slidesJson),
              let deck = jsonValue(normalized) as? [String: Any],
              let slides = deck["slides"] as? [Any] else {
            return ValidationResult(valid: false, reason: "expected slides JSON")
        }
        if slides.isEmpty { return ValidationResult(valid: false, reason: "empty slides") }
        if slides.count > 24 { return ValidationResult(valid: false, reason: "too many slides: \(slides.count)") }
        let deckResult = validateElement(deck, depth: 0, maxStringLength: maxSlideStringLength)
        if !deckResult.valid { return deckResult }
        for element in slides {
            if let obj = element as? [String: Any],
               let layout = obj.string("layout")?.lowercased(),
               !supportedSlideLayouts.contains(layout) {
                return ValidationResult(valid: false, reason: "unsupported slide layout: \(layout)")
            }
            let result = validateElement(element, depth: 0, maxStringLength: maxSlideStringLength)
            if !result.valid { return result }
        }
        return ValidationResult(valid: true)
    }

    static func normalizeSlidesSpecJson(_ slidesJson: String) -> String? {
        slidesArrayOrNull(slidesJson).flatMap(jsonString)
    }

    static func normalizeSlidesDeckSpecJson(_ slidesJson: String) -> String? {
        guard let parsed = jsonValue(slidesJson),
              let deck = normalizeSlidesDeckSpec(parsed) else {
            return nil
        }
        return jsonString(deck)
    }

    static func slidesArrayOrNull(_ slidesJson: String) -> [Any]? {
        jsonValue(slidesJson).flatMap(findSlidesSource)?.slides
    }

    private static func normalizeSlidesDeckSpec(_ parsed: Any) -> [String: Any]? {
        guard let source = findSlidesSource(parsed) else { return nil }
        let topLevel = parsed as? [String: Any]
        var deck: [String: Any] = [
            "schemaVersion": topLevel?.int("schemaVersion") ?? source.source?.int("schemaVersion") ?? 2,
            "style": topLevel?.string("style") ?? source.source?.string("style") ?? "system",
            "slides": source.slides,
        ]
        if let accent = topLevel?.string("accent") ?? source.source?.string("accent") { deck["accent"] = accent }
        if let fontPack = topLevel?.string("fontPack") ?? source.source?.string("fontPack") { deck["fontPack"] = fontPack }
        if let title = topLevel?.string("title") ?? source.source?.string("title") { deck["title"] = title }
        return deck
    }

    private struct SlidesSource {
        let source: [String: Any]?
        let slides: [Any]
    }

    private static func findSlidesSource(_ element: Any) -> SlidesSource? {
        if let array = element as? [Any] {
            return SlidesSource(source: nil, slides: array)
        }
        guard let object = element as? [String: Any] else { return nil }
        if let slides = object["slides"] as? [Any] { return SlidesSource(source: object, slides: slides) }
        if let pages = object["pages"] as? [Any] { return SlidesSource(source: object, slides: pages) }
        if let specArray = object["spec"] as? [Any] { return SlidesSource(source: object, slides: specArray) }
        if let specObject = object["spec"] as? [String: Any] { return findSlidesSource(specObject) }
        return nil
    }

    private static func validateElement(_ element: Any, depth: Int, maxStringLength: Int) -> ValidationResult {
        if depth > maxDepth { return ValidationResult(valid: false, reason: "nesting too deep") }
        if let string = element as? String {
            return validateStringValue(string, maxStringLength: maxStringLength)
        }
        if let array = element as? [Any] {
            if array.count > maxArrayElements {
                return ValidationResult(valid: false, reason: "array too large: \(array.count)")
            }
            for child in array {
                let result = validateElement(child, depth: depth + 1, maxStringLength: maxStringLength)
                if !result.valid { return result }
            }
            return ValidationResult(valid: true)
        }
        if let object = element as? [String: Any] {
            for (key, child) in object {
                let keyResult = validateObjectKey(key)
                if !keyResult.valid { return keyResult }
                let result = validateElement(child, depth: depth + 1, maxStringLength: maxStringLength)
                if !result.valid { return result }
            }
        }
        return ValidationResult(valid: true)
    }

    private static func validateObjectKey(_ key: String) -> ValidationResult {
        if key.count > maxStringLength {
            return ValidationResult(valid: false, reason: "object key too long: \(key.count)")
        }
        let lower = key.lowercased()
        if ["__proto__", "constructor", "prototype"].contains(lower) {
            return ValidationResult(valid: false, reason: "blocked object key: \(key)")
        }
        for pattern in blockedPatterns where lower.contains(pattern.lowercased()) {
            return ValidationResult(valid: false, reason: "blocked object key pattern: \(pattern)")
        }
        return ValidationResult(valid: true)
    }

    private static func validateStringValue(_ value: String, maxStringLength: Int) -> ValidationResult {
        if value.count > maxStringLength {
            return ValidationResult(valid: false, reason: "string value too long: \(value.count)")
        }
        let lower = value.lowercased()
        for pattern in blockedPatterns where lower.contains(pattern.lowercased()) {
            return ValidationResult(valid: false, reason: "blocked pattern: \(pattern)")
        }
        if value.containsMatch(pattern: #"^\s*function\s*\(|\=\>"#) {
            return ValidationResult(valid: false, reason: "function or arrow syntax in string value")
        }
        if value.containsMatch(pattern: #"\.innerHTML\s*=|\bdocument\.\w+"#) {
            return ValidationResult(valid: false, reason: "DOM access in string value")
        }
        return ValidationResult(valid: true)
    }
}

