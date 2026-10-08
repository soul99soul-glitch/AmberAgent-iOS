import SwiftUI

/// App accent swatches. Each pair keeps ≥4.5:1 text contrast on its paper.
enum DeepReadAccent: String, CaseIterable, Identifiable {
    case cinnabar, indigo, pine, wisteria, ink

    var id: Self { self }

    var name: String {
        switch self {
        case .cinnabar: "朱砂"
        case .indigo: "黛蓝"
        case .pine: "松绿"
        case .wisteria: "藤紫"
        case .ink: "墨黑"
        }
    }

    var light: UInt32 {
        switch self {
        case .cinnabar: 0xC8402F
        case .indigo: 0x2F5D8A
        case .pine: 0x2F6B57
        case .wisteria: 0x6B4C9A
        case .ink: 0x2A2320
        }
    }

    var dark: UInt32 {
        switch self {
        case .cinnabar: 0xE67261
        case .indigo: 0x7FA8D6
        case .pine: 0x7DBFA4
        case .wisteria: 0xB39DDB
        case .ink: 0xF1E9DF
        }
    }

    func hex(dark isDark: Bool) -> String { String(format: "#%06X", isDark ? dark : light) }
}

/// Look of the article page. Every style reuses the editorial renderer's markup and only
/// swaps the canvas palette plus a CSS layer, so custom HTML templates are unaffected.
enum DeepReadReaderStyle: String, CaseIterable, Identifiable {
    case classic, scroll, briefing, journal, broadsheet, minimal, academic, colorPage

    var id: Self { self }

    var name: String {
        switch self {
        case .classic: "经典杂志"
        case .scroll: "书卷"
        case .briefing: "简报"
        case .journal: "手账"
        case .broadsheet: "报纸"
        case .minimal: "极简"
        case .academic: "学术"
        case .colorPage: "彩页"
        }
    }

    var detail: String {
        switch self {
        case .classic: "暖纸衬线，留白克制。"
        case .scroll: "古籍书页，首字下沉，段首缩进。"
        case .briefing: "无衬线标题，编号要点，信息密度高。"
        case .journal: "点阵纸、荧光笔与胶带标签。"
        case .broadsheet: "双线报头、粗体大标题，iPad 上分栏。"
        case .minimal: "纯白无衬线，去掉分隔线，只留内容。"
        case .academic: "摘要框、章节编号与编号参考文献。"
        case .colorPage: "主题色报头色块，卡片式脉络，引言反白。"
        }
    }

    struct Canvas {
        let bg: UInt32, fg: UInt32, surface: UInt32, muted: UInt32, border: UInt32
    }

    func canvas(dark: Bool) -> Canvas {
        switch (self, dark) {
        case (.classic, false): Canvas(bg: 0xFBF7F1, fg: 0x2A2320, surface: 0xF2EADE, muted: 0x6E6254, border: 0xDBCEBC)
        case (.classic, true): Canvas(bg: 0x201C19, fg: 0xF1E9DF, surface: 0x2A2520, muted: 0xB9AA98, border: 0x54493D)
        case (.scroll, false): Canvas(bg: 0xF3EBDA, fg: 0x2B2118, surface: 0xEADFC9, muted: 0x6F604C, border: 0xD8C9AE)
        case (.scroll, true): Canvas(bg: 0x1C1813, fg: 0xEADFCB, surface: 0x26201A, muted: 0xA8977F, border: 0x433829)
        case (.briefing, false): Canvas(bg: 0xF6F6F3, fg: 0x141414, surface: 0xECECE7, muted: 0x5E5E58, border: 0xDADAD3)
        case (.briefing, true): Canvas(bg: 0x121212, fg: 0xEDEDEA, surface: 0x1D1D1C, muted: 0x9C9C96, border: 0x343432)
        case (.journal, false): Canvas(bg: 0xFBF8F2, fg: 0x2D2A26, surface: 0xF1ECE2, muted: 0x6E675F, border: 0xE2D9CB)
        case (.journal, true): Canvas(bg: 0x1E1D1B, fg: 0xECE6DC, surface: 0x292724, muted: 0xA39C92, border: 0x3D3A35)
        case (.broadsheet, false): Canvas(bg: 0xF5F1E8, fg: 0x1A1714, surface: 0xEBE5D8, muted: 0x6B645A, border: 0xCFC6B5)
        case (.broadsheet, true): Canvas(bg: 0x171513, fg: 0xE9E3D8, surface: 0x221F1C, muted: 0x9E968A, border: 0x3A3530)
        case (.minimal, false): Canvas(bg: 0xFFFFFF, fg: 0x1C1C1E, surface: 0xF2F2F7, muted: 0x6C6C70, border: 0xE5E5EA)
        case (.minimal, true): Canvas(bg: 0x000000, fg: 0xF2F2F7, surface: 0x1C1C1E, muted: 0x98989F, border: 0x2C2C2E)
        case (.academic, false): Canvas(bg: 0xFDFDFB, fg: 0x222222, surface: 0xF3F2EE, muted: 0x63635D, border: 0xD9D8D2)
        case (.academic, true): Canvas(bg: 0x1A1A1A, fg: 0xE6E6E3, surface: 0x242424, muted: 0x9D9D98, border: 0x3A3A3A)
        case (.colorPage, false): Canvas(bg: 0xFFFCF7, fg: 0x1F1A17, surface: 0xF5EEE4, muted: 0x6B5F55, border: 0xE6DBCD)
        case (.colorPage, true): Canvas(bg: 0x1A1716, fg: 0xF0E8DE, surface: 0x26221F, muted: 0xA89A8C, border: 0x3E3733)
        }
    }

    var css: String {
        switch self {
        case .classic:
            ""
        case .scroll:
            """
            .markdown-body p,.summary p,.para .text p,.flow p{text-align:justify;}
            .headline{text-align:center;padding-top:14px;}
            .kicker{letter-spacing:.5em;}
            h1{font-weight:700;font-size:30px;line-height:1.3;letter-spacing:.04em;margin:12px 0 6px;}
            .headline h1::after{content:"❦";display:block;color:var(--deep-read-accent);font-size:18px;font-weight:400;margin:10px 0 4px;}
            .headline .summary{text-align:left;}
            p.section{text-align:center;font-size:12px;letter-spacing:.6em;color:var(--deep-read-accent);margin:0 0 16px;}
            p.section::before,p.section::after{content:"—";letter-spacing:0;margin:0 .8em;color:var(--deep-read-border);}
            section .markdown-body>p,.para .text p,.flow p{text-indent:2em;}
            .summary>p:first-child::first-letter,.headline+section>.markdown-body>p:first-child::first-letter{float:left;font-size:3.2em;line-height:.9;margin:.06em .12em 0 0;font-weight:700;color:var(--deep-read-accent);}
            .headline+section>.markdown-body>p:first-child{text-indent:0;}
            .timeline-marker{border-radius:0;transform:rotate(45deg);width:10px;height:10px;margin:7px 0 0 4px;}
            blockquote{border-left:0;text-align:center;font-style:italic;padding:6px 8px;}
            """
        case .briefing:
            """
            h1,h2,p.section,.timeline-date,blockquote{font-family:var(--deep-read-sans);}
            .headline{padding-top:10px;}
            .kicker{display:inline-block;background:var(--deep-read-accent);color:var(--deep-read-bg);padding:3px 8px;border-radius:4px;letter-spacing:.2em;font-weight:700;}
            h1{font-weight:800;font-size:30px;line-height:1.15;letter-spacing:-.01em;}
            h2{font-weight:700;}
            .headline .summary{background:var(--deep-read-surface);border-left:4px solid var(--deep-read-accent);padding:14px 16px;border-radius:0 12px 12px 0;}
            p.section{color:var(--deep-read-fg);font-weight:800;font-size:13px;letter-spacing:.08em;border-top:3px solid var(--deep-read-fg);padding-top:8px;margin-bottom:12px;}
            section{counter-reset:point;}
            .core-point{counter-increment:point;position:relative;padding-left:46px;}
            .core-point::before{content:counter(point,decimal-leading-zero);position:absolute;left:0;top:9px;font-family:var(--deep-read-sans);font-weight:800;font-size:24px;color:var(--deep-read-accent);}
            .timeline-marker{border:0;border-radius:3px;background:var(--deep-read-accent);width:12px;height:12px;margin-top:6px;}
            .reading-link{border-top:0;background:var(--deep-read-surface);border-radius:10px;padding:10px 12px;margin:0 0 8px;}
            blockquote,blockquote.markdown-body p{border-left-width:4px;font-weight:600;font-size:17px;}
            """
        case .journal:
            """
            html,body{background-image:radial-gradient(var(--deep-read-border) 1px,transparent 1.3px);background-size:18px 18px;}
            .headline{padding-top:12px;}
            .headline h1{display:inline;font-weight:700;font-size:28px;line-height:1.45;-webkit-box-decoration-break:clone;box-decoration-break:clone;background:linear-gradient(transparent 60%,color-mix(in srgb,var(--deep-read-accent) 28%,transparent) 60%);}
            .headline .summary{margin-top:20px;background:var(--deep-read-surface);padding:14px 16px;border-radius:14px;transform:rotate(-.4deg);box-shadow:0 2px 0 var(--deep-read-border);}
            p.section{display:inline-block;background:color-mix(in srgb,var(--deep-read-accent) 20%,var(--deep-read-bg));color:var(--deep-read-fg);padding:4px 12px;border-radius:2px;transform:rotate(-1.5deg);letter-spacing:.2em;font-weight:600;margin:0 0 14px;}
            .markdown-body strong,.markdown-body b{background:linear-gradient(transparent 58%,color-mix(in srgb,var(--deep-read-accent) 30%,transparent) 58%);}
            .timeline-item,.core-point,.reading-link{border-top:1px dashed var(--deep-read-border);}
            .timeline-marker{border:2px dashed var(--deep-read-accent);}
            blockquote{border-left:0;background:var(--deep-read-surface);padding:12px 14px 12px 38px;border-radius:12px;position:relative;}
            blockquote::before{content:"“";position:absolute;left:10px;top:-2px;font-size:42px;line-height:1;color:var(--deep-read-accent);}
            """
        case .broadsheet:
            """
            .headline{margin:10px 22px 0;padding:10px 0 14px;border-top:4px double var(--deep-read-fg);border-bottom:1px solid var(--deep-read-fg);}
            .kicker{text-align:center;letter-spacing:.4em;color:var(--deep-read-fg);font-weight:700;}
            h1{font-weight:900;font-size:34px;line-height:1.08;letter-spacing:-.01em;text-align:center;margin:8px 0 14px;}
            .markdown-body p,.para .text p,.flow p{text-align:justify;}
            p.section{color:var(--deep-read-fg);font-weight:800;letter-spacing:.3em;text-align:center;border-top:2px solid var(--deep-read-fg);border-bottom:1px solid var(--deep-read-fg);padding:5px 0;margin:0 0 14px;}
            .summary>p:first-child::first-letter,.headline+section>.markdown-body>p:first-child::first-letter{float:left;font-size:3.4em;line-height:.85;margin:.06em .1em 0 0;font-weight:900;}
            .timeline-marker{border-radius:0;background:var(--deep-read-fg);border:0;width:8px;height:8px;margin-top:8px;}
            blockquote{border-left:0;border-top:1px solid var(--deep-read-fg);border-bottom:1px solid var(--deep-read-fg);padding:10px 0;text-align:center;font-weight:700;}
            @media (min-width:640px){
              .summary,.headline+section>.markdown-body{column-count:2;column-gap:28px;column-rule:1px solid var(--deep-read-border);}
            }
            """
        case .minimal:
            """
            :root{--deep-read-serif:var(--deep-read-sans);}
            h1{font-weight:700;font-size:28px;line-height:1.2;letter-spacing:-.01em;}
            .kicker,p.section{text-transform:none;letter-spacing:.06em;font-weight:600;font-size:12px;color:var(--deep-read-fg);}
            .headline .summary{color:var(--deep-read-muted);}
            section,.diagram-block{margin-top:40px;}
            .timeline-item,.core-point,.reading-link,.takeaways li{border-top:0;}
            .timeline-marker{width:6px;height:6px;border:0;background:var(--deep-read-muted);margin:8px 0 0 6px;}
            .timeline-item.highlight .timeline-marker{background:var(--deep-read-accent);}
            .diagram-frame{border:0;border-radius:14px;}
            blockquote{border-left-width:2px;}
            blockquote,blockquote.markdown-body p{font-size:17px;}
            .entities span{border:0;background:var(--deep-read-surface);}
            """
        case .academic:
            """
            body{counter-reset:chapter;}
            .headline{text-align:center;}
            h1{font-weight:600;font-size:26px;line-height:1.35;}
            .headline .summary{text-align:justify;font-size:14px;border-top:1px solid var(--deep-read-fg);border-bottom:1px solid var(--deep-read-fg);padding:12px 4px;margin-top:14px;}
            .headline .summary::before{content:"摘要";display:block;text-align:center;font-family:var(--deep-read-sans);font-weight:700;font-size:12px;letter-spacing:.3em;margin-bottom:8px;}
            .entities{justify-content:center;}
            p.section{counter-increment:chapter;font-family:var(--deep-read-serif);font-weight:700;font-size:15px;letter-spacing:.04em;text-transform:none;color:var(--deep-read-fg);}
            p.section::before{content:counter(chapter) ". ";}
            .markdown-body p,.para .text p,.flow p{text-align:justify;}
            section{counter-reset:reference;}
            .reading-link{counter-increment:reference;}
            .reading-link p::before{content:"[" counter(reference) "] ";color:var(--deep-read-accent);}
            .timeline-marker{width:8px;height:8px;margin:7px 0 0 5px;}
            """
        case .colorPage:
            """
            .headline{background:var(--deep-read-accent);padding:24px 22px 22px;}
            .headline,.headline h1,.headline .kicker,.headline .summary,.headline .summary p{color:var(--deep-read-bg);}
            .headline h1{font-weight:800;}
            .headline .entities span{border-color:color-mix(in srgb,var(--deep-read-bg) 45%,transparent);color:var(--deep-read-bg);}
            .headline .summary{background:transparent;padding:0;}
            .headline .byline,.headline .byline a,.headline .orig-title,.headline .note-counts{color:var(--deep-read-bg);border-color:color-mix(in srgb,var(--deep-read-bg) 40%,transparent);}
            p.section{display:inline-block;background:var(--deep-read-fg);color:var(--deep-read-bg);padding:4px 10px;letter-spacing:.2em;font-weight:700;margin-bottom:12px;}
            .timeline-item,.core-point{border-top:0;background:color-mix(in srgb,var(--deep-read-accent) 8%,var(--deep-read-bg));border-radius:12px;padding:12px;margin:0 0 8px;}
            .core-point h2{color:var(--deep-read-accent);}
            blockquote{border-left:0;background:var(--deep-read-accent);color:var(--deep-read-bg);padding:14px 16px;border-radius:12px;}
            blockquote p,blockquote a,blockquote small,.camp blockquote small{color:inherit;}
            """
        }
    }
}

/// Order and emphasis of the article's sections. Same content, different reading path.
enum DeepReadReaderLayout: String, CaseIterable, Identifiable {
    case classic, brief, timeline, debate

    var id: Self { self }

    var name: String {
        switch self {
        case .classic: "经典"
        case .brief: "速读"
        case .timeline: "时间线"
        case .debate: "观点对照"
        }
    }

    var detail: String {
        switch self {
        case .classic: "要点速览、时间轴、脉络、分析依次展开。"
        case .brief: "先看关键脉络和争议，时间轴放到后面。"
        case .timeline: "以时间轴为主线，事件串成一条竖线。"
        case .debate: "各方立场做成卡片，核心争议放大。"
        }
    }

    var symbol: String {
        switch self {
        case .classic: "doc.richtext"
        case .brief: "bolt"
        case .timeline: "clock.arrow.circlepath"
        case .debate: "person.2.wave.2"
        }
    }

    var order: [IOSDeepReadStructuredRenderer.Section] {
        switch self {
        case .classic: IOSDeepReadStructuredRenderer.Section.standard
        case .brief: [.corePoints, .analysis, .uncertainties, .diagram, .timeline, .extendedReading, .references]
        case .timeline: [.timeline, .diagram, .corePoints, .analysis, .uncertainties, .extendedReading, .references]
        case .debate: [.analysis, .uncertainties, .corePoints, .timeline, .diagram, .extendedReading, .references]
        }
    }

    var css: String {
        switch self {
        case .classic:
            ""
        case .brief:
            """
            .timeline-item{padding:7px 0;}
            .timeline-item figure,.core-point figure{display:none;}
            .core-point h2{font-size:17px;}
            """
        case .timeline:
            """
            .timeline-item{position:relative;border-top:0;padding:10px 0 14px;}
            .timeline-item:not(:last-child)::before{content:"";position:absolute;left:9px;top:28px;bottom:-6px;width:1px;background:var(--deep-read-border);}
            .timeline-date{font-size:12px;font-weight:700;}
            .timeline-copy p{font-size:16px;}
            """
        case .debate:
            """
            section blockquote,section blockquote.markdown-body p{font-size:21px;line-height:1.45;}
            section blockquote{border-left-width:4px;}
            .perspective{background:var(--deep-read-surface);border-left:3px solid var(--deep-read-accent);border-radius:12px;padding:12px 14px;margin:0 0 10px;}
            .perspective .holder{color:var(--deep-read-accent);font-weight:700;font-size:12px;letter-spacing:.06em;text-transform:none;margin:0 0 6px;}
            .perspective .markdown-body p{margin:0;}
            .quote .quote-text{font-size:17px;font-style:italic;}
            """
        }
    }
}

/// Appearance choices that apply immediately (no save step) and persist across launches.
@MainActor
@Observable
final class DeepReadAppearance {
    static let shared = DeepReadAppearance()

    var accent: DeepReadAccent {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }
    var readerStyle: DeepReadReaderStyle {
        didSet { defaults.set(readerStyle.rawValue, forKey: Keys.readerStyle) }
    }
    var readerLayout: DeepReadReaderLayout {
        didSet { defaults.set(readerLayout.rawValue, forKey: Keys.readerLayout) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let accent = "deepread.appearance.accent"
        static let readerStyle = "deepread.appearance.readerStyle"
        static let readerLayout = "deepread.appearance.readerLayout"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accent = defaults.string(forKey: Keys.accent).flatMap(DeepReadAccent.init) ?? .cinnabar
        readerStyle = defaults.string(forKey: Keys.readerStyle).flatMap(DeepReadReaderStyle.init) ?? .classic
        readerLayout = defaults.string(forKey: Keys.readerLayout).flatMap(DeepReadReaderLayout.init) ?? .classic
    }
}
