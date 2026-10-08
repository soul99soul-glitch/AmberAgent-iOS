import Foundation

enum DeepReadArticleRenderer {
    /// `forPrint` expands every footnote, since a PDF cannot be tapped.
    @MainActor
    static func html(task: IOSDeepReadTask, settings: DeepReadSettingsStore, dark: Bool = false, originalOnly: Bool = false,
                     forPrint: Bool = false) throws -> String {
        let appearance = DeepReadAppearance.shared
        let style = appearance.readerStyle
        let canvas = style.canvas(dark: dark)
        let scale = min(1.8, max(0.7, settings.fontScale))
        func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }
        let palette = DeepReadCloseReadingRenderer.Palette(
            accent: appearance.accent.hex(dark: dark), bg: hex(canvas.bg), fg: hex(canvas.fg),
            surface: hex(canvas.surface), muted: hex(canvas.muted), border: hex(canvas.border), dark: dark)

        if let reading = DeepReadCloseReading.decode(task.structuredJSON) {
            return DeepReadCloseReadingRenderer.html(reading, palette: palette, fontMode: settings.fontMode,
                                                     styleCSS: style.css, scale: scale, originalOnly: originalOnly, expandNotes: forPrint)
        }
        if let article = DeepReadTemplateArticle.decode(task.structuredJSON) {
            return DeepReadTemplateArticleRenderer.html(article, palette: palette, fontMode: settings.fontMode,
                                                        styleCSS: style.css, scale: scale)
        }
        if let template = IOSDeepReadTemplateStore.shared.template(id: task.templateId) {
            return try IOSDeepReadHTMLTemplateRenderer.render(task: task, template: template, fontScale: Float(settings.fontScale), fontModeWireName: settings.fontMode)
        }
        let structured = task.structuredJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(IOSDeepReadOutput.self, from: $0) }
        let links = task.sources.compactMap { source -> IOSDeepReadEditorialRenderer.SourceLink? in
            guard let url = source.url else { return nil }
            return .init(title: source.title, url: url, source: source.kind.title)
        }
        let layout = appearance.readerLayout
        // 斜切图文 is the illustrated edition (slanted hero + inline photos); 默认杂志 reads as text only.
        let illustrated = task.templateId == IOSDeepReadTemplate.editorial.id
        let result = IOSDeepReadEditorialRenderer.renderHTML(.init(
            title: task.title,
            markdown: task.resultMarkdown,
            heroImageURL: illustrated ? structured?.heroImageUrl ?? task.sources.compactMap { $0.metadata["hero_image_url"] }.first : nil,
            heroCaption: illustrated ? structured?.heroCaption : nil,
            sources: links,
            dark: dark,
            structured: structured,
            sectionOrder: layout.order,
            accentHex: palette.accent,
            fontMode: settings.fontMode,
            bgHex: palette.bg,
            fgHex: palette.fg,
            surfaceHex: palette.surface,
            mutedHex: palette.muted,
            borderHex: palette.border
        ))
        let textOnly = illustrated ? "" : "figure{display:none!important;}\n"
        // The page's synthetic origin is sent as Referer, which hotlink-protected image hosts reject (403).
        return result.replacingOccurrences(of: "</head>", with: "<meta name=\"referrer\" content=\"no-referrer\"><style>\(textOnly)\(layout.css)\n\(style.css)\nbody{zoom:\(scale)}</style></head>")
    }
}
