import Foundation

extension NovelPromptCatalog {
    static func completedPolishContent(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lineBreak = trimmed.lastIndex(of: "\n") else { return nil }
        let marker = trimmed[trimmed.index(after: lineBreak)...]
        guard marker == polishCompletionSentinel else { return nil }
        let content = String(trimmed[..<lineBreak])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty,
              !content.contains(polishCompletionSentinel) else {
            return nil
        }
        let normalized = normalizedCandidateProse(content)
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    /// Strips a mistaken outer Markdown code fence from model prose/polish output.
    /// Models (especially Grok) often wrap full chapters in ```html / ```markdown even when
    /// asked for plain manuscript text; Chat's markdown renderer then shows a green code card.
    ///
    /// - If the whole string is one closed fence, returns the inner body.
    /// - If streaming still has only an opening fence of a common wrapper language, drops that line.
    /// - Otherwise returns the text with surrounding whitespace removed.
    static func normalizedCandidateProse(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else {
            return trimmed
        }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return trimmed }
        let firstTrimmed = first.trimmingCharacters(in: .whitespaces)
        guard let opener = fenceOpener(firstTrimmed) else { return trimmed }

        var end = lines.count - 1
        while end > 0, lines[end].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end -= 1
        }
        let endTrimmed = lines[end].trimmingCharacters(in: .whitespaces)
        if end > 0, isFenceCloser(endTrimmed, matching: opener.marker) {
            let body = lines[1..<end].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? trimmed : body
        }

        // Incomplete stream: drop a lone opening fence when it uses a common wrapper
        // language so the first streamed frame is not a green code card labeled "html".
        if shouldStripIncompleteOpener(language: opener.language) {
            return lines.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// Match durable prose's leading trim without touching the raw manuscript.
    /// Keep trailing whitespace during streaming so a partial line does not retract.
    static func normalizedStreamingCandidateProse(_ text: String) -> String {
        guard let first = text.first else { return text }
        if !first.isWhitespace {
            guard text.hasPrefix("```") || text.hasPrefix("~~~") else { return text }
            return normalizedCandidateProse(text)
        }
        let firstVisible = text.drop { $0.isWhitespace }
        guard firstVisible.hasPrefix("```") || firstVisible.hasPrefix("~~~") else {
            return String(firstVisible)
        }
        return normalizedCandidateProse(text)
    }

    private static let spuriousWrapperLanguages: Set<String> = [
        "",
        "html",
        "htm",
        "markdown",
        "md",
        "text",
        "txt",
        "plaintext",
        "plain",
        "novel",
        "prose",
        "chapter",
    ]

    private static func fenceOpener(_ line: String) -> (marker: String, language: String)? {
        if line.hasPrefix("```") {
            let language = String(line.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return ("```", language)
        }
        if line.hasPrefix("~~~") {
            let language = String(line.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return ("~~~", language)
        }
        return nil
    }

    private static func isFenceCloser(_ line: String, matching marker: String) -> Bool {
        line == marker
    }

    private static func shouldStripIncompleteOpener(language: String) -> Bool {
        spuriousWrapperLanguages.contains(language)
    }
}
