import Foundation

/// Close-reading page: guide, focus block, then the original paragraphs with notes that
/// read as footnotes: a superscript in the text, a numbered list under the paragraph (phone) or in
/// the margin (iPad) that expands in place. No script needed: notes use <details>.
enum DeepReadCloseReadingRenderer {
    struct Palette {
        var accent, bg, fg, surface, muted, border: String
        var dark: Bool
    }

    /// `originalOnly` shows just the typeset original: no numbers, notes or AI blocks.
    static func html(_ reading: DeepReadCloseReading, palette p: Palette, fontMode: String, styleCSS: String, scale: Double,
                     originalOnly: Bool = false, expandNotes: Bool = false) -> String {
        let notes = Dictionary(grouping: reading.notes, by: \.paragraph)
        let reports = Dictionary((reading.others ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A printed footnote is always open, so its 展开/收起 hint would only mislead.
        var b = head(palette: p, fontMode: fontMode, styleCSS: styleCSS, scale: scale,
                     extraCSS: expandNotes ? ".footnotes summary::after,.footnotes details[open] summary::after{content:none;}" : "") + #"<article class="close-reading">"#

        // The original's own images sit inline; a separate hero would repeat the first one.
        if let hero = reading.heroImageURL, !hero.isEmpty, !reading.bodyParagraphs.contains(where: { $0.kind == .image }) {
            b += #"<figure class="hero"><img src=""# + esc(hero) + #""/></figure>"#
        }
        let kicker = originalOnly ? "原文" : "精读 · " + DeepReadCloseReading.genreLabel(reading.genre)
        b += #"<section class="headline"><p class="kicker">"# + esc(kicker) + "</p>"
        b += "<h1>" + esc(originalOnly && !reading.originalTitle.isEmpty ? reading.originalTitle : reading.title) + "</h1>"
        if !originalOnly, !reading.originalTitle.isEmpty, reading.originalTitle != reading.title {
            b += #"<p class="orig-title">"# + esc(reading.originalTitle) + "</p>"
        }
        b += #"<p class="byline"><span>"# + esc(reading.site) + "</span>"
        if let url = reading.url { b += #"<a href=""# + esc(url) + #"">\#(originalOnly ? "原网页" : "阅读原文") ↗</a>"# }
        b += "</p>"
        if originalOnly {
            b += #"</section><section class="flow">"#
            for paragraph in reading.bodyParagraphs {
                switch paragraph.kind {
                case .heading: b += "<h2>" + itemText(paragraph.text) + "</h2>"
                case .image: b += #"<figure><img src=""# + esc(paragraph.text) + #""/></figure>"#
                case .text: b += "<p>" + itemText(paragraph.text) + "</p>"
                }
            }
            b += #"</section><p class="source-note">原文来自 "# + esc(reading.site) + "，版权归原作者所有。</p></article></body></html>"
            return b
        }
        if !reading.guide.isEmpty {
            b += #"<div class="summary markdown-body"><p>"# + inline(reading.guide) + "</p></div>"
            let counts = DeepReadCloseReading.Note.Kind.allCases.compactMap { kind -> String? in
                let count = reading.notes.filter { $0.kind == kind }.count
                return count == 0 ? nil : "\(kind.label) \(count)"
            }
            if !counts.isEmpty { b += #"<p class="note-counts">批注　"# + counts.joined(separator: " · ") + "</p>" }
        }
        b += "</section>"

        if let modules = reading.modules {
            b += templateHTML(reading.template, modules)
        } else if let focus = reading.focus {
            // Readings from before templates keep their single focus block.
            b += #"<section class="focus"><p class="section">"# + esc(focus.title) + #"</p><div class="focus-grid">"#
            for item in focus.items { b += "<div><b>" + esc(item.label) + "</b><p>" + inline(item.text) + "</p></div>" }
            b += "</div></section>"
        }

        if let rows = reading.comparison?.rows, !rows.isEmpty {
            let ids = (reading.others ?? []).map(\.id).filter { id in rows.contains { $0.cells[String(id)] != nil } }
            b += #"<section class="compare"><p class="section">多家对照</p><div class="table-wrap"><table><tr><th></th><th>本文</th>"#
            b += ids.map { "<th>" + esc(reports[$0]?.site ?? "") + "</th>" }.joined() + "</tr>"
            for row in rows {
                let mark = row.conflict ? #" class="mark""# : ""
                b += "<tr><td>" + esc(row.aspect) + "</td><td\(mark)>" + esc(row.primary.isEmpty ? "—" : row.primary) + "</td>"
                b += ids.map { "<td\(row.cells[String($0)] == nil ? "" : mark)>" + esc(row.cells[String($0)] ?? "—") + "</td>" }.joined() + "</tr>"
            }
            b += #"</table></div><p class="table-note">“≠”表示来源之间的数据或结论不一致。</p></section>"#
        }

        if reading.template == .news, let open = reading.modules?.uncertain, !open.isEmpty {
            b += #"<section class="uncertain"><p class="section">待核实</p><ul>"# + open.map { "<li>" + inline($0) + "</li>" }.joined() + "</ul></section>"
        }

        b += #"<section class="original"><p class="section">原文</p>"#
        var footnote = 0
        for paragraph in reading.bodyParagraphs {
            let attached = notes[paragraph.id] ?? []
            let numbers = attached.indices.map { footnote + $0 + 1 }
            footnote += attached.count
            let marks = numbers.isEmpty ? "" : #"<sup class="fn">"# + numbers.map(String.init).joined(separator: ",") + "</sup>"
            b += #"<div class="para"# + (paragraph.kind == .heading ? " h" : "") + #""><span class="n">"# + (paragraph.kind == .image ? "" : String(paragraph.id)) + #"</span><div class="text">"#
            switch paragraph.kind {
            case .heading: b += "<h2>" + itemText(paragraph.text) + marks + "</h2>"
            case .image: b += #"<figure><img src=""# + esc(paragraph.text) + #""/></figure>"# + marks
            case .text: b += "<p>" + itemText(paragraph.text) + marks + "</p>"
            }
            b += "</div>"
            if !attached.isEmpty {
                b += #"<ol class="footnotes">"#
                for (note, number) in zip(attached, numbers) {
                    let from = (note.sources ?? []).compactMap { reports[$0]?.site }.joined(separator: " · ")
                    b += "<li><details\(expandNotes ? " open" : "")><summary><span class=\"no\">\(number)</span><span class=\"kind\">\(note.kind.label)</span><span class=\"t\">" + esc(note.title) + "</span>"
                    if !from.isEmpty { b += #"<span class="from">"# + esc(from) + "</span>" }
                    b += #"</summary><div class="body">"# + inline(note.body) + "</div></details></li>"
                }
                b += "</ol>"
            }
            b += "</div>"
        }
        b += "</section>"
        if let others = reading.others, !others.isEmpty {
            b += #"<section class="others"><p class="section">别家怎么说</p>"#
            for report in others {
                b += #"<div class="other"><span class="stance s-\#(report.stance.rawValue)">\#(report.stance.label)</span><div><p>"#
                b += esc(report.site) + "：" + inline(report.summary) + "</p>"
                if let url = report.url { b += #"<a href=""# + esc(url) + #"">"# + esc(report.title) + "</a>" } else { b += "<small>" + esc(report.title) + "</small>" }
                b += "</div></div>"
            }
            b += "</section>"
        }
        b += #"<p class="source-note">原文来自 "# + esc(reading.site) + "，版权归原作者所有。</p>"
        b += "</article></body></html>"
        return b
    }

    /// The template's own blocks, in reading order; empty modules are skipped.
    private static func templateHTML(_ template: DeepReadCloseReading.Template, _ m: DeepReadCloseReading.Modules) -> String {
        func list(_ items: [String], ordered: Bool = false) -> String {
            let tag = ordered ? "ol" : "ul"
            return "<\(tag)>" + items.map { "<li>" + inline($0) + "</li>" }.joined() + "</\(tag)>"
        }
        var b = ""
        switch template {
        case .review:
            if let verdict = m.verdict {
                b += #"<section class="verdict"><p class="section">值不值得买</p><p class="line">"# + inline(verdict.line) + "</p>"
                if !verdict.goodFor.isEmpty || !verdict.skipIf.isEmpty {
                    b += #"<div class="pair">"#
                    if !verdict.goodFor.isEmpty { b += #"<div class="good"><b>适合</b>"# + list(verdict.goodFor) + "</div>" }
                    if !verdict.skipIf.isEmpty { b += #"<div class="bad"><b>可以跳过</b>"# + list(verdict.skipIf) + "</div>" }
                    b += "</div>"
                }
                b += "</section>"
            }
            if !m.pros.isEmpty || !m.cons.isEmpty {
                b += #"<section class="proscons"><p class="section">优缺点</p><div class="pair">"#
                if !m.pros.isEmpty { b += #"<div class="good"><b>优点</b>"# + list(m.pros) + "</div>" }
                if !m.cons.isEmpty { b += #"<div class="bad"><b>缺点</b>"# + list(m.cons) + "</div>" }
                b += "</div></section>"
            }
            if !m.specs.isEmpty {
                let showChange = m.specs.contains { !$0.change.isEmpty }
                b += #"<section class="specs"><p class="section">关键规格</p><div class="table-wrap"><table><tr><th>项目</th><th>参数</th>"#
                b += (showChange ? "<th>变化</th>" : "") + "</tr>"
                for spec in m.specs {
                    b += "<tr><td>" + esc(spec.name) + "</td><td>" + esc(spec.value) + "</td>"
                    if showChange { b += #"<td class="change">"# + esc(spec.change.isEmpty ? "—" : spec.change) + "</td>" }
                    b += "</tr>"
                }
                b += "</table></div></section>"
            }
        case .news:
            if !m.fact.isEmpty {
                b += #"<section class="fact"><p class="section">一句话事实</p><p class="line">"# + inline(m.fact) + "</p></section>"
            }
            if !m.timeline.isEmpty {
                b += #"<section class="events"><p class="section">事件脉络</p><ol>"#
                for event in m.timeline {
                    b += #"<li><span class="date">"# + esc(event.date) + "</span><p>" + inline(event.event) + "</p></li>"
                }
                b += "</ol></section>"
            }
            if !m.parties.isEmpty {
                b += #"<section class="parties"><p class="section">各方说法</p>"#
                b += m.parties.map { #"<div class="party"><b>"# + esc($0.who) + "</b><p>" + inline($0.said) + "</p></div>" }.joined()
                b += "</section>"
            }
        case .opinion:
            if let argument = m.argument {
                b += #"<section class="argument"><p class="section">论点地图</p><div class="claim"><b>主张</b><p>"# + inline(argument.claim) + "</p></div>"
                b += #"<div class="pair">"#
                if !argument.reasons.isEmpty { b += #"<div class="good"><b>论据</b>"# + list(argument.reasons, ordered: true) + "</div>" }
                if !argument.counter.isEmpty { b += #"<div class="bad"><b>反方会说</b>"# + list(argument.counter) + "</div>" }
                b += "</div></section>"
            }
        case .general:
            if !m.points.isEmpty {
                b += #"<section class="points"><p class="section">要点</p>"# + list(m.points, ordered: true) + "</section>"
            }
        }
        return b
    }

    /// Document head shared by every built-in DeepRead page (close reading and template syntheses):
    /// palette, note colors, fonts, the reader style and the font scale. `extraCSS` comes before the
    /// reader style so styles can still restyle it.
    static func head(palette p: Palette, fontMode: String, styleCSS: String, scale: Double, extraCSS: String = "") -> String {
        var b = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>"
        b += #"<meta name="referrer" content="no-referrer">"#
        b += "<style>\n:root{--deep-read-accent:\(p.accent);--deep-read-bg:\(p.bg);--deep-read-fg:\(p.fg);--deep-read-surface:\(p.surface);--deep-read-muted:\(p.muted);--deep-read-border:\(p.border);"
        b += p.dark
            ? "--note-context:#7FA8D6;--note-verify:#E2A75A;--note-data:#B39DDB;--note-add:#8DBB98;--note-differ:#FF7B6E;}\n"
            : "--note-context:#2F5D8A;--note-verify:#8F5A10;--note-data:#6B4C9A;--note-add:#3F6A4A;--note-differ:#A8261F;}\n"
        // body zoom does not change what media queries measure, so the wide layout waits for the zoomed width.
        b += (css + "\n" + extraCSS).replacingOccurrences(of: "(min-width:760px)", with: "(min-width:\(Int(760 * scale))px)")
        if fontMode == "system" { b += #":root{--deep-read-serif:"PingFang SC","Source Han Sans SC",system-ui,sans-serif;}"# }
        b += "\n\(styleCSS)\nbody{zoom:\(scale)}\n</style></head><body>"
        return b
    }

    private static func esc(_ s: String) -> String { IOSDeepReadEditorialRenderer.esc(s) }
    private static func inline(_ s: String) -> String { IOSDeepReadEditorialRenderer.markdownToInlineHTML(s) }

    /// A leading item number ("3. ") or, in kept code lines, "# ", "- ", "> " or "---" is text, not
    /// Markdown block syntax: as a block it would renumber or restyle the line and push the
    /// footnote mark out of the paragraph.
    private static func itemText(_ s: String) -> String {
        let lead = s.firstMatch(of: /^(\d+[.)](\s+|$)|#{1,6}(\s+|$)|>\s*|[-+*]\s+|[-*_]{3,}$)/).map { String($0.output.0) } ?? ""
        return esc(lead) + inline(String(s.dropFirst(lead.count)))
    }

    private static let css = """
    @font-face{font-family:"AmberDeepReadSerif";src:url("amberfont://deepread/serif.otf") format("opentype");font-weight:200 900;font-display:swap;}
    :root{--deep-read-serif:"AmberDeepReadSerif","Noto Serif SC","Songti SC",serif;--deep-read-sans:"PingFang SC","Source Han Sans SC",system-ui,sans-serif;}
    html,body{margin:0;padding:0;background:var(--deep-read-bg);color:var(--deep-read-fg);font-family:var(--deep-read-serif);-webkit-user-select:text;overflow-wrap:anywhere;}
    article{padding-bottom:16px;display:block;}
    img:not([src]),img[src=""]{display:none!important;}
    .hero{margin:0 0 8px;background:var(--deep-read-surface);}
    .hero img{display:block;width:100%;max-height:300px;object-fit:cover;}
    .headline,section{padding:0 22px;}
    section{margin-top:28px;}
    .kicker,.section,small,summary,.badge,.byline,.n,.source-note{font-family:var(--deep-read-sans);}
    .kicker{letter-spacing:.24em;color:var(--deep-read-accent);font-size:10px;margin:22px 0 10px;}
    p.section{letter-spacing:.18em;color:var(--deep-read-muted);font-size:10px;margin:0 0 12px;}
    h1{font-weight:600;font-size:28px;line-height:1.25;margin:0 0 8px;}
    .orig-title{font-size:13px;color:var(--deep-read-muted);font-style:italic;margin:0 0 10px;}
    .byline{display:flex;flex-wrap:wrap;gap:8px;align-items:center;font-size:12px;color:var(--deep-read-muted);padding-bottom:14px;border-bottom:1px solid var(--deep-read-border);margin:0;}
    .byline a{color:var(--deep-read-accent);text-decoration:none;margin-left:auto;}
    p{font-size:15px;line-height:1.75;margin:0;}
    .summary{background:var(--deep-read-surface);border-radius:14px;padding:14px 16px;margin-top:18px;}
    .note-counts{font-family:var(--deep-read-sans);font-size:12px;color:var(--deep-read-muted);margin:10px 0 0;}
    .badge{font-size:11px;padding:3px 9px;border-radius:999px;border:1px solid currentColor;}
    .focus-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;}
    .focus-grid div{border:1px solid var(--deep-read-border);border-radius:12px;padding:12px 14px;}
    .focus-grid b{display:block;font-family:var(--deep-read-sans);font-size:11px;letter-spacing:.12em;color:var(--deep-read-accent);margin-bottom:6px;}
    .focus-grid p{font-size:14px;line-height:1.6;}
    .para{display:grid;grid-template-columns:22px minmax(0,1fr);gap:4px 8px;margin:0 0 16px;}
    .para .n{font-size:10px;color:var(--deep-read-muted);padding-top:6px;text-align:right;}
    .para h2{font-size:18px;font-weight:600;line-height:1.4;margin:10px 0 0;}
    .flow p{margin:0 0 16px;}
    .flow h2{font-size:19px;font-weight:600;line-height:1.4;margin:26px 0 12px;}
    .flow figure{margin:6px 0 18px;}
    .flow figure img{display:block;width:100%;border-radius:8px;}
    .para.h .n{padding-top:15px;}
    .para figure{margin:4px 0;}
    .para figure img{display:block;width:100%;border-radius:8px;}
    .fn{font-family:var(--deep-read-sans);font-size:10px;line-height:0;color:var(--deep-read-accent);margin-left:2px;}
    .footnotes{grid-column:2;list-style:none;margin:6px 0 0;padding:6px 0 0;border-top:0.5px solid var(--deep-read-border);}
    .footnotes li{margin:0 0 4px;}
    .footnotes summary{list-style:none;display:flex;gap:6px;align-items:baseline;font-family:var(--deep-read-sans);font-size:12px;line-height:1.55;color:var(--deep-read-muted);}
    .footnotes summary::-webkit-details-marker{display:none;}
    .footnotes .no{color:var(--deep-read-accent);min-width:10px;}
    .footnotes .kind{font-weight:600;white-space:nowrap;}
    .footnotes .t{color:var(--deep-read-fg);min-width:0;}
    .footnotes .from{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:40%;}
    .footnotes summary::after{content:"展开";margin-left:auto;padding-left:8px;font-size:10px;white-space:nowrap;}
    .footnotes details[open] summary::after{content:"收起";}
    .footnotes .body{font-size:13px;line-height:1.7;color:var(--deep-read-muted);padding:2px 0 6px 16px;}
    section .line{font-size:19px;line-height:1.5;font-weight:600;margin:0 0 12px;}
    .fact .line{border-left:3px solid var(--deep-read-accent);padding-left:12px;}
    .pair{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;}
    .pair>div{border:1px solid var(--deep-read-border);border-radius:12px;padding:12px 14px;}
    .pair b,.claim b,.party b{display:block;font-family:var(--deep-read-sans);font-size:11px;letter-spacing:.12em;margin-bottom:6px;}
    .pair ul,.pair ol,.points ol,.uncertain ul{margin:0;padding-left:1.2em;}
    .pair li,.points li{font-size:14px;line-height:1.6;margin:0 0 4px;}
    .good b{color:var(--note-add);} .bad b{color:var(--note-differ);}
    .claim{background:var(--deep-read-surface);border-radius:12px;padding:12px 14px;margin-bottom:10px;}
    .claim b{color:var(--deep-read-accent);}
    .claim p{font-size:16px;line-height:1.6;}
    td.change{color:var(--deep-read-accent);}
    .events ol{list-style:none;margin:0;padding:0;}
    .events li{display:grid;grid-template-columns:96px minmax(0,1fr);gap:10px;padding:9px 0;border-top:1px solid var(--deep-read-border);}
    .events .date{font-family:var(--deep-read-sans);font-size:12px;font-weight:600;color:var(--deep-read-accent);padding-top:2px;}
    .events li p{font-size:14px;line-height:1.6;}
    .party{padding:10px 0;border-top:1px solid var(--deep-read-border);}
    .party b{color:var(--deep-read-accent);letter-spacing:.04em;font-size:12px;}
    .party p{font-size:14px;line-height:1.6;}
    .uncertain ul{list-style:none;padding:12px 14px;border:1px dashed var(--deep-read-border);border-radius:12px;background:var(--deep-read-surface);}
    .uncertain li{position:relative;padding-left:22px;font-size:14px;line-height:1.6;margin:0 0 8px;}
    .uncertain li:last-child{margin-bottom:0;}
    .uncertain li::before{content:"?";position:absolute;left:0;top:2px;width:15px;height:15px;border-radius:50%;border:1px solid var(--note-verify);color:var(--note-verify);font-family:var(--deep-read-sans);font-size:10px;font-weight:700;line-height:15px;text-align:center;}
    .stance{font-family:var(--deep-read-sans);font-size:12px;font-weight:600;white-space:nowrap;padding-top:2px;}
    .s-add,.s-agree{color:var(--note-add);}
    .s-differ{color:var(--note-differ);}
    .table-wrap{overflow-x:auto;}
    table{width:100%;border-collapse:collapse;font-family:var(--deep-read-sans);font-size:12px;line-height:1.5;}
    th{font-weight:600;text-align:left;color:var(--deep-read-muted);font-size:11px;padding:8px 6px;border-bottom:1.5px solid var(--deep-read-fg);white-space:nowrap;}
    td{padding:9px 6px;border-bottom:1px solid var(--deep-read-border);vertical-align:top;}
    td:first-child{font-weight:600;white-space:nowrap;}
    td.mark{background:color-mix(in srgb,var(--note-differ) 10%,transparent);}
    td.mark::after{content:" ≠";color:var(--note-differ);font-weight:700;}
    .table-note{font-family:var(--deep-read-sans);font-size:11px;color:var(--deep-read-muted);margin-top:8px;}
    .other{display:grid;grid-template-columns:auto minmax(0,1fr);gap:10px;align-items:start;padding:12px 0;border-top:1px solid var(--deep-read-border);}
    .other p{font-size:14px;line-height:1.6;}
    .other a,.other small{display:block;font-family:var(--deep-read-sans);font-size:11px;color:var(--deep-read-muted);margin-top:3px;text-decoration:none;}
    .source-note{font-size:11px;color:var(--deep-read-muted);padding:16px 22px 0;margin:0;}
    @media (min-width:760px){
      .para{grid-template-columns:28px minmax(0,1fr) 270px;gap:4px 22px;}
      .footnotes{grid-column:3;grid-row:1;margin-top:0;border-top:0;padding-top:4px;}
    }
    """
}
