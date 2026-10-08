import Foundation

/// Page for template syntheses. Shares the close-reading head (palette, fonts, reader style)
/// and its block styles; adds Q&A, camps, citations and the numbered source list.
enum DeepReadTemplateArticleRenderer {
    static func html(_ a: DeepReadTemplateArticle, palette: DeepReadCloseReadingRenderer.Palette,
                     fontMode: String, styleCSS: String, scale: Double) -> String {
        var b = DeepReadCloseReadingRenderer.head(palette: palette, fontMode: fontMode, styleCSS: styleCSS, scale: scale, extraCSS: css)
        b += #"<article class="template">"#
        b += #"<section class="headline"><p class="kicker">"# + esc(a.kind.name) + "</p><h1>" + esc(a.title) + "</h1>"
        if !a.lede.isEmpty { b += #"<div class="summary markdown-body"><p>"# + inline(a.lede) + "</p></div>" }
        b += "</section>"

        if let brief = a.brief {
            b += section("要点", #"<ol class="numbered">"# + brief.points.map { "<li>" + inline($0) + "</li>" }.joined() + "</ol>")
            if !brief.background.isEmpty { b += section("背景", block(brief.background)) }
            if !brief.impact.isEmpty { b += section("影响", block(brief.impact)) }
            if !brief.uncertain.isEmpty {
                b += #"<section class="uncertain"><p class="section">待核实</p><ul>"# + brief.uncertain.map { "<li>" + inline($0) + "</li>" }.joined() + "</ul></section>"
            }
        }
        if let qa = a.qa {
            b += #"<section class="qa">"#
            for (index, item) in qa.enumerated() {
                b += #"<div class="qa-item"><p class="q"><span class="qn">Q\#(index + 1)</span><span>"# + inline(item.question) + "</span></p>"
                b += #"<div class="a">"# + block(item.answer, cite: item.sources) + "</div></div>"
            }
            b += "</section>"
        }
        if let debate = a.debate {
            if !debate.dispute.isEmpty { b += #"<section class="fact"><p class="section">核心争议</p><p class="line">"# + inline(debate.dispute) + "</p></section>" }
            b += #"<section class="camps"><p class="section">各方阵营</p>"#
            for camp in debate.camps {
                let stanceLabel = ["pro": "支持", "con": "反对"][camp.stance] ?? "中立"
                b += #"<div class="camp \#(camp.stance)"><p class="camp-head"><span class="badge">\#(stanceLabel)</span><b>"# + esc(camp.label) + "</b></p>"
                if !camp.holders.isEmpty { b += #"<p class="holders">"# + esc(camp.holders.joined(separator: "、")) + "</p>" }
                b += block(camp.argument, cite: camp.sources)
                if !camp.quote.isEmpty {
                    b += #"<blockquote><p>“"# + esc(camp.quote) + "”</p>" + (camp.quoteBy.isEmpty ? "" : "<small>—— " + esc(camp.quoteBy) + "</small>") + "</blockquote>"
                }
                b += "</div>"
            }
            b += "</section>"
            if !debate.takeaway.isEmpty {
                b += #"<section class="argument"><div class="claim"><b>你可以怎么看</b>"# + block(debate.takeaway) + "</div></section>"
            }
        }
        if let timeline = a.timeline {
            b += #"<section class="events"><p class="section">时间线</p><ol>"#
            for event in timeline.events {
                b += #"<li\#(event.turning ? #" class="turn""# : "")><span class="date">"# + esc(event.date) + "</span><p>" + inline(event.event) + cite(event.sources) + "</p></li>"
            }
            b += "</ol></section>"
            if !timeline.turns.isEmpty {
                b += #"<section class="parties"><p class="section">转折点</p>"#
                b += timeline.turns.map { #"<div class="party"><b>"# + esc($0.date) + "</b>" + block($0.why) + "</div>" }.joined()
                b += "</section>"
            }
        }
        if let review = a.review {
            let sites = Dictionary(a.sources.map { ($0.id, $0.site) }, uniquingKeysWith: { first, _ in first })
            b += #"<section class="verdict"><p class="section">结论</p><p class="line">"# + inline(review.verdict) + "</p></section>"
            if !review.consensus.isEmpty {
                b += #"<section class="proscons"><p class="section">各家共识</p><div class="pair"><div class="good"><b>一致认为</b><ul>"#
                b += review.consensus.map { "<li>" + inline($0) + "</li>" }.joined() + "</ul></div></div></section>"
            }
            for split in review.splits {
                b += #"<section class="parties"><p class="section">分歧 · "# + esc(split.topic) + "</p>"
                b += split.views.map { #"<div class="party"><b>"# + esc(sites[$0.source] ?? "") + "</b><p>" + inline($0.view) + cite([$0.source]) + "</p></div>" }.joined()
                b += "</section>"
            }
            if !review.specs.isEmpty {
                b += #"<section class="specs"><p class="section">关键规格</p><div class="table-wrap"><table>"#
                b += review.specs.map { "<tr><td>" + esc($0.name) + "</td><td>" + esc($0.value) + "</td></tr>" }.joined() + "</table></div></section>"
            }
            if !review.scores.isEmpty {
                b += #"<section class="scores"><p class="section">打分对照</p><div class="score-grid">"#
                b += review.scores.map { #"<div><span class="score">"# + esc($0.score) + "</span><b>" + esc(sites[$0.source] ?? "") + "</b>" + ($0.note.isEmpty ? "" : "<small>" + esc($0.note) + "</small>") + "</div>" }.joined()
                b += "</div></section>"
            }
            if !review.conclusion.isEmpty {
                b += #"<section class="argument"><div class="claim"><b>买不买</b>"# + block(review.conclusion) + "</div></section>"
            }
        }

        if !a.sources.isEmpty {
            b += #"<section class="refs"><p class="section">来源</p><ol>"#
            for source in a.sources {
                b += #"<li><span class="n">[\#(source.id)]</span><div>"#
                b += source.url.map { #"<a href=""# + esc($0) + #"">"# + esc(source.title) + "</a>" } ?? esc(source.title)
                b += "<small>" + esc(source.site) + "</small></div></li>"
            }
            b += "</ol></section>"
        }
        b += "</article></body></html>"
        return b
    }

    private static func section(_ title: String, _ body: String) -> String {
        #"<section><p class="section">"# + esc(title) + "</p>" + body + "</section>"
    }

    /// Long fields may hold lists or several paragraphs, so they render as blocks; citations
    /// trail the last paragraph instead of dropping onto a line of their own.
    private static func block(_ text: String, cite ids: [Int] = []) -> String {
        let html = IOSDeepReadEditorialRenderer.markdownToHTML(text)
        let marks = cite(ids)
        guard !marks.isEmpty else { return html }
        if let close = html.range(of: "</p>", options: .backwards), html[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return html.replacingCharacters(in: close, with: marks + "</p>")
        }
        return html + "<p>" + marks + "</p>"
    }

    private static func cite(_ ids: [Int]) -> String {
        ids.isEmpty ? "" : #"<sup class="cite">"# + ids.map { "[\($0)]" }.joined() + "</sup>"
    }

    private static func esc(_ s: String) -> String { IOSDeepReadEditorialRenderer.esc(s) }
    private static func inline(_ s: String) -> String { IOSDeepReadEditorialRenderer.markdownToInlineHTML(s) }

    private static let css = """
    section p{margin:0 0 10px;}
    .numbered{margin:0;padding-left:1.4em;}
    .numbered li{font-size:15px;line-height:1.65;margin:0 0 8px;}
    .cite{font-family:var(--deep-read-sans);font-size:10px;color:var(--deep-read-accent);margin-left:2px;}
    .qa-item{padding:14px 0;border-top:1px solid var(--deep-read-border);}
    .qa-item .q{font-size:17px;line-height:1.5;font-weight:600;margin:0 0 8px;display:flex;gap:10px;}
    .qa-item .q .qn{font-family:var(--deep-read-sans);font-size:12px;font-weight:700;color:var(--deep-read-accent);padding-top:3px;}
    .qa-item .a{padding-left:30px;}
    .qa-item .a p{font-size:15px;line-height:1.75;}
    .camp{border:1px solid var(--deep-read-border);border-left:4px solid var(--note-color);border-radius:12px;padding:12px 14px;margin:0 0 10px;}
    .camp.pro{--note-color:var(--note-add);} .camp.con{--note-color:var(--note-differ);} .camp.neutral{--note-color:var(--deep-read-muted);}
    .camp-head{display:flex;gap:8px;align-items:center;margin:0 0 4px;}
    .camp-head .badge{color:var(--note-color);}
    .camp-head b{font-size:16px;}
    .camp p{font-size:15px;line-height:1.7;}
    .camp p.holders{font-family:var(--deep-read-sans);font-size:12px;color:var(--deep-read-muted);margin:0 0 8px;}
    .camp p.camp-head{margin:0 0 4px;}
    .camp blockquote{margin:8px 0 0;padding-left:10px;border-left:2px solid var(--deep-read-border);}
    .camp blockquote p{font-style:italic;margin:0;}
    .camp blockquote::before{content:none;}
    .camp blockquote small{font-family:var(--deep-read-sans);font-size:11px;color:var(--deep-read-muted);}
    .events li.turn .date::before{content:"● ";color:var(--deep-read-accent);}
    .events li.turn p{font-weight:600;}
    .score-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(110px,1fr));gap:10px;}
    .score-grid div{border:1px solid var(--deep-read-border);border-radius:12px;padding:12px;text-align:center;}
    .score-grid .score{display:block;font-size:26px;font-weight:700;color:var(--deep-read-accent);}
    .score-grid b{display:block;font-family:var(--deep-read-sans);font-size:12px;margin-top:2px;}
    .score-grid small{display:block;font-family:var(--deep-read-sans);font-size:11px;color:var(--deep-read-muted);margin-top:4px;}
    .refs ol{list-style:none;margin:0;padding:0;}
    .refs li{display:grid;grid-template-columns:30px minmax(0,1fr);gap:6px;padding:8px 0;border-top:1px solid var(--deep-read-border);}
    .refs .n{font-family:var(--deep-read-sans);font-size:11px;color:var(--deep-read-accent);padding-top:2px;}
    .refs a{font-size:14px;line-height:1.5;color:var(--deep-read-fg);text-decoration:none;}
    .refs small{display:block;font-family:var(--deep-read-sans);font-size:11px;color:var(--deep-read-muted);}
    """
}
