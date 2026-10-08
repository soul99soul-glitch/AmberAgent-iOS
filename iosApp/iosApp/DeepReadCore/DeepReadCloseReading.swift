import Foundation
@preconcurrency import Shared

/// Close reading: one primary text is the article body, with a guide, type-specific modules
/// (review / news / opinion / general) and notes anchored to paragraph ids. Stored in `structuredJSON` under the
/// `shape` discriminator so the topic-synthesis output keeps its own schema.
struct DeepReadCloseReading: Codable, Equatable {
    static let shapeID = "close_reading"

    var shape = shapeID
    var title: String
    var originalTitle: String
    var url: String?
    var site: String
    var genre: String
    var guide: String
    var focus: Focus?
    var bodyStart: Int
    var bodyEnd: Int
    var heroImageURL: String?
    var paragraphs: [Paragraph]
    var notes: [Note]
    /// Other reports on the same story and how they relate to the original (phase 2).
    var others: [OtherReport]? = nil
    var comparison: Comparison? = nil
    /// The template's own blocks; nil on readings made before templates existed (they keep `focus`).
    var modules: Modules? = nil

    /// The model picks the genre after reading the whole text; the genre picks the template.
    enum Template { case review, news, opinion, general }

    var template: Template {
        switch genre {
        case "review": .review
        case "news", "interview": .news
        case "opinion": .opinion
        default: .general
        }
    }

    struct Modules: Codable, Equatable {
        struct Verdict: Codable, Equatable {
            var line: String
            var goodFor: [String]
            var skipIf: [String]
        }
        struct Spec: Codable, Equatable {
            var name: String
            var value: String
            var change: String
        }
        struct Event: Codable, Equatable {
            var date: String
            var event: String
        }
        struct Party: Codable, Equatable {
            var who: String
            var said: String
        }
        struct Argument: Codable, Equatable {
            var claim: String
            var reasons: [String]
            var counter: [String]
        }
        // review
        var verdict: Verdict?
        var pros: [String]
        var cons: [String]
        var specs: [Spec]
        // news
        var fact: String
        var timeline: [Event]
        var parties: [Party]
        var uncertain: [String]
        // opinion
        var argument: Argument?
        // general
        var points: [String]

        static let empty = Modules(verdict: nil, pros: [], cons: [], specs: [], fact: "", timeline: [], parties: [],
                                   uncertain: [], argument: nil, points: [])
    }

    struct Paragraph: Codable, Equatable {
        enum Kind: String, Codable { case text, heading, image }
        var id: Int
        var kind: Kind
        var text: String
    }

    struct Focus: Codable, Equatable {
        struct Item: Codable, Equatable {
            var label: String
            var text: String
        }
        var title: String
        var items: [Item]
    }

    struct Note: Codable, Equatable {
        enum Kind: String, Codable, CaseIterable { case key, context, verify, data, add, differ }
        var paragraph: Int
        var kind: Kind
        var title: String
        var body: String
        /// `OtherReport.id`s behind an add/differ note.
        var sources: [Int]? = nil
    }

    struct OtherReport: Codable, Equatable {
        enum Stance: String, Codable { case agree, add, differ }
        var id: Int
        var title: String
        var url: String?
        var site: String
        var stance: Stance
        var summary: String
    }

    struct Comparison: Codable, Equatable {
        struct Row: Codable, Equatable {
            var aspect: String
            var primary: String
            /// Keyed by `OtherReport.id` as a string.
            var cells: [String: String]
            var conflict: Bool
        }
        var rows: [Row]
    }

    var bodyParagraphs: [Paragraph] { paragraphs.filter { (bodyStart...bodyEnd).contains($0.id) } }

    /// False for "只读原文" readings (and failed guides): there is nothing but the original to show.
    var hasGuide: Bool { !guide.isEmpty }

    static func decode(_ json: String?) -> DeepReadCloseReading? {
        guard let data = json?.data(using: .utf8),
              let reading = try? JSONDecoder().decode(DeepReadCloseReading.self, from: data),
              reading.shape == shapeID else { return nil }
        return reading
    }

    func encoded() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func genreLabel(_ genre: String) -> String {
        switch genre {
        case "review": "评测"
        case "paper": "论文"
        case "opinion": "观点"
        case "tutorial": "教程"
        case "news": "报道"
        case "interview": "访谈"
        default: "文章"
        }
    }
}

extension DeepReadCloseReading.Note.Kind {
    var label: String {
        switch self {
        case .key: "要点"
        case .context: "背景"
        case .verify: "待核实"
        case .data: "数据"
        case .add: "补充"
        case .differ: "分歧"
        }
    }
}

extension DeepReadCloseReading.OtherReport.Stance {
    var label: String {
        switch self {
        case .agree: "一致"
        case .add: "补充"
        case .differ: "分歧"
        }
    }
}

enum DeepReadCloseReader {
    /// Marks the one source that becomes the article body.
    static let roleKey = "role"
    static let primaryRole = "primary"
    /// Set when the user gave no title, so the fetched article title replaces the link's host.
    static let titlePendingKey = "title_pending"
    /// Set by "只读原文": fetch and typeset the original only, no model call until the reader asks.
    static let originalOnlyKey = "original_only"
    /// Stored original text cap; the model sees a shorter window.
    static let maxStoredChars = 40_000
    static let maxPromptChars = 20_000
    static let missingSection = "导读与批注"

    static func isPrimary(_ source: IOSDeepReadSource) -> Bool { source.metadata[roleKey] == primaryRole }

    // MARK: Fetch

    struct Page: Equatable {
        var title: String
        var text: String
        var heroImageURL: String?
    }

    /// Full article text for the primary link. Jina Reader returns clean Markdown with
    /// headings and images; the direct page is the fallback (and the only path when the
    /// user turned Jina off). Neither goes through the 12k-char tool-output cap.
    @MainActor
    static func fetch(url rawURL: String, settings: Settings?,
                      transport: any IOSSearchHTTPTransport = IOSURLSessionSearchHTTPTransport()) async throws -> Page {
        let url = try IOSSearchExecutor.scrapeRequest(from: rawURL).url
        if settings?.searchBuiltinJinaEnabled != false,
           let page = try? await fetchViaJina(url: url, transport: transport), !page.text.isEmpty {
            return page
        }
        return try await fetchDirect(url: url, transport: transport)
    }

    @MainActor
    private static func fetchViaJina(url: URL, transport: any IOSSearchHTTPTransport) async throws -> Page {
        guard let readerURL = URL(string: "https://r.jina.ai/" + url.absoluteString) else { throw IOSSearchExecutorError.invalidURL }
        var request = URLRequest(url: readerURL)
        // A browser UA is challenged by Jina's Cloudflare front.
        request.setValue("AmberAgent-iOS/1.0 (reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25
        let (response, data) = try await get(request, transport: transport)
        guard (200...299).contains(response.statusCode) else { throw IOSSearchExecutorError.httpStatus("Jina Reader", response.statusCode) }
        return parseJina(String(decoding: data, as: UTF8.self))
    }

    static func parseJina(_ raw: String) -> Page {
        let title = raw.components(separatedBy: "\n").first { $0.hasPrefix("Title:") }
            .map { String($0.dropFirst("Title:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
        var body = raw
        if let marker = raw.range(of: "Markdown Content:") { body = String(raw[marker.upperBound...]) }
        let text = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxStoredChars))
        // No hero: Jina's first image is often a site logo, and the article's own images stay inline.
        return Page(title: title, text: text, heroImageURL: nil)
    }

    @MainActor
    private static func fetchDirect(url: URL, transport: any IOSSearchHTTPTransport) async throws -> Page {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 AmberAgent-iOS Scrape", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.3", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (response, data) = try await get(request, transport: transport)
        guard (200...299).contains(response.statusCode) else { throw IOSSearchExecutorError.httpStatus("网页", response.statusCode) }
        let html = String(decoding: data, as: UTF8.self)
        let title = firstMatch(#"(?is)<title[^>]*>(.*?)</title>"#, in: html).map(IOSSearchExecutor.plainText(fromHTML:)) ?? ""
        let text = String(readableText(fromHTML: html).prefix(maxStoredChars))
        guard !text.isEmpty else { throw IOSSearchExecutorError.emptyResponse("网页") }
        return Page(title: title, text: text, heroImageURL: IOSSearchExecutor.extractHeroImageURLs(from: html).first)
    }

    /// The verified HTTPS path also works behind Fake-IP proxy DNS, where the plain public
    /// check rejects every host (Jina included) as non-public.
    @MainActor
    private static func get(_ request: URLRequest, transport: any IOSSearchHTTPTransport) async throws -> (HTTPURLResponse, Data) {
        if let verified = transport as? any IOSVerifiedHTTPScrapeTransport {
            return try await verified.sendVerifiedHTTPSGET(request, maximumResponseBytes: 1_024 * 1_024)
        }
        return try await transport.sendPublic(request, maximumResponseBytes: 1_024 * 1_024)
    }

    /// Keeps block boundaries, headings and images so the text can be segmented into paragraphs.
    static func readableText(fromHTML html: String) -> String {
        var t = html
        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside"] {
            t = replace(#"(?is)<\#(tag)\b[^>]*>.*?</\#(tag)>"#, in: t, with: " ")
        }
        if let article = firstMatch(#"(?is)<article\b[^>]*>(.*)</article>"#, in: t) { t = article }
        t = replace(#"(?is)<h[1-6]\b[^>]*>(.*?)</h[1-6]>"#, in: t, with: "\n## $1\n")
        t = replace(#"(?is)<img\b[^>]*\bsrc=["'](https?://[^"']+)["'][^>]*>"#, in: t, with: "\n![]($1)\n")
        t = replace(#"(?i)</(p|li|div|section|blockquote|figcaption|tr)>|<br\s*/?>"#, in: t, with: "\n")
        // Not IOSSearchExecutor.plainText: its whitespace collapse also folds newlines, losing every block break.
        t = IOSSearchExecutor.decodeEntities(replace(#"<[^>]+>"#, in: t, with: " "))
        return t.components(separatedBy: "\n")
            .map { replace(#"[ \t\x{00A0}]+"#, in: $0, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: Segment

    /// Numbered blocks from Markdown-ish text: headings, images and text lines; link
    /// syntax is reduced to its text and exact repeats (menus, share bars) are dropped.
    static func segment(_ text: String) -> [DeepReadCloseReading.Paragraph] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // Text that separates paragraphs with blank lines (Markdown, most txt) may also hard-wrap
        // inside them; those wrapped lines are joined unless the line before ends a sentence.
        // Line-per-block text (scraped HTML) is not joined.
        let blankSeparated = lines.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
        var blocks: [DeepReadCloseReading.Paragraph] = []
        var seen = Set<String>()
        var previousBlank = true
        var joinable = false
        var fence: Character? // the open fence's marker while inside a code block
        func closes(_ line: String, _ mark: Character) -> Bool { line.count >= 3 && line.allSatisfy { $0 == mark } }
        for (index, raw) in lines.enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                previousBlank = true
                joinable = false
                continue
            }
            defer { previousBlank = false }
            // Fenced code keeps one block per line; the fence markers themselves are dropped.
            if let mark = fence {
                if closes(line, mark) { fence = nil } else { blocks.append(.init(id: 0, kind: .text, text: line)) }
                continue
            }
            // A fence opens only when a matching one closes it later; an unmatched one or a long
            // ~~~~ rule is decoration and dropped like a thematic break.
            if let mark = line.first, mark == "`" || mark == "~", line.hasPrefix(String(repeating: mark, count: 3)) {
                if line.prefix(while: { $0 == mark }).count <= 4, !line.drop(while: { $0 == mark }).contains(mark),
                   lines[(index + 1)...].contains(where: { closes($0.trimmingCharacters(in: .whitespaces), mark) }) {
                    fence = mark
                }
                joinable = false
                continue
            }
            // Thematic breaks (---, ***, * * *, ___). A ===/--- line directly under text is a Setext heading underline.
            let marks = line.filter { !$0.isWhitespace }
            if marks.count >= 3, let mark = marks.first, "-*_=".contains(mark), marks.allSatisfy({ $0 == mark }) {
                if joinable, mark == "=" || mark == "-", let last = blocks.indices.last {
                    blocks[last].kind = .heading
                }
                joinable = false
                continue
            }
            if let image = firstMatch(#"^!\[[^\]]*\]\((https?://[^)\s]+)[^)]*\)$"#, in: line) {
                if seen.insert(image).inserted { blocks.append(.init(id: 0, kind: .image, text: image)) }
                joinable = false
                continue
            }
            var kind = DeepReadCloseReading.Paragraph.Kind.text
            if let heading = firstMatch(#"^#{1,6}\s+(.+)$"#, in: line) {
                kind = .heading
                line = heading
            }
            // Bullets become "•"; numbered items keep their numbers.
            let structured = kind == .heading || line.hasPrefix("|") || firstMatch(#"^([-*+]|\d+[.)])\s"#, in: line) != nil
            line = replace(#"^>\s*"#, in: line, with: "")
            line = replace(#"^[-*+]\s+"#, in: line, with: "• ")
            line = replace(#"!\[[^\]]*\]\([^)]*\)"#, in: line, with: "")
            line = replace(#"\[([^\]]*)\]\([^)]*\)"#, in: line, with: "$1")
            if kind == .heading { line = replace(#"\s+#+$"#, in: line, with: "") }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                joinable = false
                continue
            }
            if blankSeparated, joinable, !structured, !previousBlank, let last = blocks.indices.last,
               !endsSentence(blocks[last].text) {
                blocks[last].text += (needsSpace(blocks[last].text.last, line.first) ? " " : "") + line
                continue
            }
            guard line.count >= 2, seen.insert(line).inserted else {
                joinable = false
                continue
            }
            blocks.append(.init(id: 0, kind: kind, text: line))
            joinable = kind == .text && !structured
        }
        return blocks.enumerated().map { index, block in
            var numbered = block
            numbered.id = index + 1
            return numbered
        }
    }

    /// Words joined across a wrap need a space unless either side is CJK, kana or full-width
    /// (Korean separates words with spaces, so hangul keeps one).
    private static func needsSpace(_ left: Character?, _ right: Character?) -> Bool {
        guard let left, let right else { return false }
        func wide(_ c: Character) -> Bool {
            guard let v = c.unicodeScalars.first?.value else { return false }
            return (0x2E80...0xA4CF).contains(v) || (0xF900...0xFAFF).contains(v)
                || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFFEF).contains(v) || v >= 0x20000
        }
        return !wide(left) && !wide(right)
    }

    private static func endsSentence(_ text: String) -> Bool {
        text.last.map { "。！？!?.…;；”」』".contains($0) } ?? false
    }

    /// The paragraphs the model sees, cut at `maxPromptChars`; the first one is always included.
    static func promptWindow(_ paragraphs: [DeepReadCloseReading.Paragraph]) -> (lines: [String], truncated: Bool, lastId: Int) {
        var lines: [String] = []
        var used = 0
        var lastId = 0
        for paragraph in paragraphs {
            var line = paragraph.kind == .image ? "[\(paragraph.id)] （图片）" : "[\(paragraph.id)] \(paragraph.kind == .heading ? "## " : "")\(paragraph.text)"
            if used + line.count > maxPromptChars {
                guard lines.isEmpty else { return (lines, true, lastId) }
                line = String(line.prefix(maxPromptChars))
            }
            used += line.count
            lines.append(line)
            lastId = paragraph.id
        }
        return (lines, false, lastId)
    }

    // MARK: Prompt

    static func prompt(title: String, site: String, paragraphs: [DeepReadCloseReading.Paragraph]) -> String {
        var b = "你是深度阅读的精读编辑。用户要精读下面这篇原文，原文按段落编号给出（[编号] 开头）。\n"
        b += "## 任务\n"
        b += "1. genre：判断体裁，取 review（产品或服务评测）、paper（论文或研究）、opinion（评论或观点）、tutorial（教程或指南）、news（新闻报道）、interview（访谈）、other。\n"
        b += "2. title：原文标题的简体中文版本；原文是中文就原样保留。\n"
        b += "3. guide：80-200 字简体中文导读，说明这篇讲了什么、核心结论、读的时候要注意什么；不要复述目录。\n"
        b += "4. 按 genre 选模板，只填写该模板的模块，其余省略：\n"
        b += "   - review（产品、服务、数码评测）：verdict{line 一句话结论≤40字, good_for 适合谁≤3条, skip_if 不适合谁或替代选择≤3条}；pros 优点≤5条、cons 缺点≤5条，每条≤30字；specs 3-8行{name≤10字, value≤24字, change 与上代或竞品相比的变化≤20字，没有就空字符串}，只写原文提到的规格。\n"
        b += "   - news / interview（新闻报道、发布、访谈）：fact 一句话事实≤60字（谁、何时、做了什么）；timeline 3-8条{date, event≤50字}，按时间先后，只用原文出现的时间点；parties 2-6条{who≤12字, said≤60字}，各方说了什么；uncertain 0-4条≤60字，原文中尚未确认的说法。\n"
        b += "   - opinion（评论、观点、分析）：argument{claim 作者核心主张≤60字, reasons 论据2-5条≤40字, counter 反方可能怎么说1-3条≤40字}。\n"
        b += "   - paper / tutorial / other：points 要点3-5条，每条≤40字。\n"
        b += "5. body_start / body_end：正文第一段和最后一段的编号，用来去掉导航、广告、版权声明、相关推荐等非正文内容。\n"
        b += "6. notes：4-12 条段落批注，只挂在真正值得解释的段落上，paragraph 必须是正文范围内存在的编号。kind 取 key（要点：这段的关键判断及其意义）、context（背景：术语、前情、人物或产品背景）、verify（待核实：缺少证据、可能夸大或需要官方确认的说法）、data（数据：解读数字，给出换算、对比基准或单位说明）。title 不超过 16 字，body 不超过 120 字；不要复述原文，不要编造原文和公认常识之外的事实，不确定就用 verify 指出。\n"
        b += "所有面向读者的文字用简体中文。只输出合法 JSON 对象，不要代码围栏和解释。\n\n"
        b += #"## 输出 JSON（以 review 为例）{"genre":"review","title":"中文标题","guide":"导读","verdict":{"line":"…","good_for":["…"],"skip_if":["…"]},"pros":["…"],"cons":["…"],"specs":[{"name":"…","value":"…","change":"…"}],"body_start":1,"body_end":20,"notes":[{"paragraph":3,"kind":"context","title":"…","body":"…"}]}"#
        b += "\n\n## 原文（来源：\(site)）\n标题：\(title)\n"
        let window = promptWindow(paragraphs)
        b += window.lines.joined(separator: "\n") + "\n"
        if window.truncated { b += "（以下段落因篇幅省略，只为已给出的段落写批注。）\n" }
        return b
    }

    // MARK: Parse

    /// Accepts the model's JSON leniently but keeps only notes that point at real body paragraphs.
    static func parse(_ text: String, page: Page, url: String?, site: String,
                      paragraphs: [DeepReadCloseReading.Paragraph]) -> DeepReadCloseReading? {
        guard let json = IOSDeepReadDraftGenerator.extractJSONObject(text) ?? IOSDeepReadDraftGenerator.repairTruncatedJSON(text),
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let lastId = paragraphs.last?.id else { return nil }
        func string(_ value: Any?) -> String { ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func int(_ value: Any?) -> Int? { (value as? Int) ?? (value as? Double).flatMap { Int(exactly: $0.rounded()) } ?? (value as? String).flatMap(Int.init) }
        let guide = string(object["guide"])
        guard !guide.isEmpty else { return nil }
        var start = min(max(int(object["body_start"]) ?? 1, 1), lastId)
        var end = min(max(int(object["body_end"]) ?? lastId, 1), lastId)
        // The model only saw a window of a long text; an end at the window's edge means "to the end".
        let window = promptWindow(paragraphs)
        if window.truncated, end >= window.lastId { end = lastId }
        if end < start { (start, end) = (1, lastId) }
        var focus: DeepReadCloseReading.Focus?
        if let raw = object["focus"] as? [String: Any] {
            let items = ((raw["items"] as? [[String: Any]]) ?? []).compactMap { item -> DeepReadCloseReading.Focus.Item? in
                let label = string(item["label"]), text = string(item["text"])
                return label.isEmpty || text.isEmpty ? nil : .init(label: label, text: text)
            }
            let title = string(raw["title"])
            if !title.isEmpty, !items.isEmpty { focus = .init(title: title, items: Array(items.prefix(4))) }
        }
        let bodyIds = Set(paragraphs.filter { (start...end).contains($0.id) && $0.kind != .image }.map(\.id))
        let notes = ((object["notes"] as? [[String: Any]]) ?? []).compactMap { note -> DeepReadCloseReading.Note? in
            guard let paragraph = int(note["paragraph"]), bodyIds.contains(paragraph),
                  let kind = DeepReadCloseReading.Note.Kind(rawValue: string(note["kind"])),
                  ![.add, .differ].contains(kind) else { return nil }
            let title = string(note["title"]), body = string(note["body"])
            guard !title.isEmpty || !body.isEmpty else { return nil }
            return .init(paragraph: paragraph, kind: kind, title: title, body: body)
        }
        let originalTitle = page.title.isEmpty ? string(object["title"]) : page.title
        var reading = DeepReadCloseReading(
            title: string(object["title"]).isEmpty ? originalTitle : string(object["title"]),
            originalTitle: originalTitle, url: url, site: site, genre: string(object["genre"]),
            guide: guide, focus: focus, bodyStart: start, bodyEnd: end, heroImageURL: page.heroImageURL,
            paragraphs: paragraphs, notes: Array(notes.prefix(16))
        )
        reading.modules = modules(from: object, template: reading.template)
        return reading
    }

    /// Keeps only the chosen template's blocks, each capped, so a chatty reply cannot mix templates.
    private static func modules(from object: [String: Any], template: DeepReadCloseReading.Template) -> DeepReadCloseReading.Modules {
        func string(_ value: Any?) -> String { ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func strings(_ value: Any?, _ limit: Int) -> [String] {
            Array(((value as? [Any]) ?? []).map(string).filter { !$0.isEmpty }.prefix(limit))
        }
        func objects(_ value: Any?) -> [[String: Any]] { (value as? [[String: Any]]) ?? [] }
        var modules = DeepReadCloseReading.Modules.empty
        switch template {
        case .review:
            if let raw = object["verdict"] as? [String: Any], !string(raw["line"]).isEmpty {
                modules.verdict = .init(line: string(raw["line"]), goodFor: strings(raw["good_for"], 3), skipIf: strings(raw["skip_if"], 3))
            }
            modules.pros = strings(object["pros"], 5)
            modules.cons = strings(object["cons"], 5)
            modules.specs = Array(objects(object["specs"]).compactMap { raw in
                string(raw["name"]).isEmpty || string(raw["value"]).isEmpty ? nil
                    : DeepReadCloseReading.Modules.Spec(name: string(raw["name"]), value: string(raw["value"]), change: string(raw["change"]))
            }.prefix(8))
        case .news:
            modules.fact = string(object["fact"])
            modules.timeline = Array(objects(object["timeline"]).compactMap { raw in
                string(raw["event"]).isEmpty ? nil : DeepReadCloseReading.Modules.Event(date: string(raw["date"]), event: string(raw["event"]))
            }.prefix(8))
            modules.parties = Array(objects(object["parties"]).compactMap { raw in
                string(raw["who"]).isEmpty || string(raw["said"]).isEmpty ? nil
                    : DeepReadCloseReading.Modules.Party(who: string(raw["who"]), said: string(raw["said"]))
            }.prefix(6))
            modules.uncertain = strings(object["uncertain"], 4)
        case .opinion:
            if let raw = object["argument"] as? [String: Any], !string(raw["claim"]).isEmpty {
                modules.argument = .init(claim: string(raw["claim"]), reasons: strings(raw["reasons"], 5), counter: strings(raw["counter"], 3))
            }
        case .general:
            modules.points = strings(object["points"], 5)
        }
        return modules
    }

    /// Original text only, for when the guide/notes call fails: the article is still readable.
    static func unannotated(page: Page, url: String?, site: String, paragraphs: [DeepReadCloseReading.Paragraph]) -> DeepReadCloseReading {
        DeepReadCloseReading(title: page.title, originalTitle: page.title, url: url, site: site, genre: "",
                             guide: "", focus: nil, bodyStart: 1, bodyEnd: paragraphs.last?.id ?? 1,
                             heroImageURL: page.heroImageURL, paragraphs: paragraphs, notes: [])
    }

    // MARK: Other reports

    /// Hot-list providers whose links are discussions, search pages or videos rather than
    /// an article. Everything else with a link is read as an original, so newly added
    /// article sources (sspai, juejin, 36kr…) qualify without being listed.
    static let discussionProviderIds: Set<String> = [
        "newsnow:zhihu", "newsnow:weibo", "newsnow:douyin", "newsnow:bilibili-hot-search", "newsnow:xueqiu-hotstock",
    ]

    static func isArticle(providerId: String?, url: String?) -> Bool {
        guard let providerId, !discussionProviderIds.contains(providerId), let url, url.hasPrefix("http") else { return false }
        return true
    }

    /// The source to read in full: an article-like entry, best-ranked first.
    static func primaryIndex(in sources: [IOSDeepReadSource]) -> Int? {
        sources.indices
            .filter { isArticle(providerId: sources[$0].metadata["provider_id"], url: sources[$0].url) }
            .min { Int(sources[$0].metadata["rank"] ?? "") ?? .max < Int(sources[$1].metadata["rank"] ?? "") ?? .max }
    }

    /// Host without "www." for bylines and table headers.
    static func siteName(_ url: String?) -> String? {
        guard let host = url.flatMap({ URL(string: $0)?.host() }) else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static let maxOtherReports = 5

    /// Whether two links point at the same article despite tracking parameters, fragments,
    /// a trailing slash or a www./m. host prefix.
    static func sameArticle(_ a: String?, _ b: String?) -> Bool {
        func key(_ raw: String?) -> String? {
            guard let raw, var components = URLComponents(string: raw), var host = components.host?.lowercased() else { return nil }
            for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
            // Tracking parameters differ between shares; others (?id=…) may be the article itself.
            let kept = (components.queryItems ?? []).filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !["spm", "from", "fbclid", "gclid", "ref"].contains(name)
            }
            components.queryItems = kept.isEmpty ? nil : kept.sorted { $0.name < $1.name }
            components.fragment = nil
            var path = components.path
            while path.hasSuffix("/") { path.removeLast() }
            return host + path + (components.query.map { "?" + $0 } ?? "")
        }
        guard let left = key(a), let right = key(b) else { return false }
        return left == right
    }
    static let compareMissingSection = "别家说法"

    struct OtherInput {
        var id: Int
        var source: IOSDeepReadSource
        var site: String { DeepReadCloseReader.siteName(source.url) ?? source.metadata["provider_name"] ?? source.title }
    }

    static func comparePrompt(reading: DeepReadCloseReading, others: [OtherInput]) -> String {
        var b = "你是深度阅读的精读编辑。下面是一篇原文（按段落编号）和几篇其他来源对同一话题的报道（[S编号]）。\n"
        b += "## 任务\n"
        b += "1. others：逐篇判断与原文的关系，stance 取 agree（结论一致）、add（补充了原文没有的信息）、differ（结论或数据与原文不同）；summary 一句话（不超过 40 字）概括它的观点或独有信息。与话题无关的来源直接省略。\n"
        b += "2. notes：2-8 条挂在原文段落上的批注，kind 取 add（别家补充的细节）或 differ（别家说法不同），paragraph 为原文段落编号，sources 为来源编号数组；title 不超过 16 字，body 不超过 120 字，写清是哪家、说了什么、与原文差在哪。只写来源里真实存在的内容。\n"
        b += "3. comparison：原文与别家有可并排比较的数据或结论（价格、续航、跑分、日期、数量、评价等）时，给 3-6 行：aspect 不超过 8 字，primary 是原文的说法，cells 的键是来源编号字符串、值是该来源的说法（各不超过 30 字，没提到就省略），数据或结论互相矛盾时 conflict 为 true。没有可比内容就为 null。\n"
        b += "所有面向读者的文字用简体中文。只输出合法 JSON 对象，不要代码围栏和解释。\n\n"
        b += #"## 输出 JSON{"others":[{"source":1,"stance":"add","summary":"…"}],"notes":[{"paragraph":3,"kind":"differ","sources":[1],"title":"…","body":"…"}],"comparison":{"rows":[{"aspect":"续航","primary":"…","cells":{"1":"…"},"conflict":false}]}}"#
        b += "\n\n## 原文（来源：\(reading.site)）\n标题：\(reading.originalTitle)\n"
        var used = 0
        for paragraph in reading.bodyParagraphs where paragraph.kind != .image {
            let line = "[\(paragraph.id)] \(paragraph.kind == .heading ? "## " : "")\(paragraph.text)"
            if used + line.count > 12_000 { b += "（以下段落省略。）\n"; break }
            used += line.count
            b += line + "\n"
        }
        b += "\n## 其他报道\n"
        for other in others {
            b += "[S\(other.id)] 来源：\(other.site)｜\(other.source.title)\n"
            b += IOSDeepReadSourceNormalizer.cleanMultiline(other.source.content).deepReadPrefixString(1_500) + "\n\n"
        }
        return b
    }

    /// Merges the comparison reply; notes must point at body paragraphs and real report ids.
    static func mergeComparison(_ text: String, into reading: DeepReadCloseReading, others: [OtherInput]) -> DeepReadCloseReading? {
        guard let json = IOSDeepReadDraftGenerator.extractJSONObject(text) ?? IOSDeepReadDraftGenerator.repairTruncatedJSON(text),
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        func string(_ value: Any?) -> String { ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func int(_ value: Any?) -> Int? {
            (value as? Int) ?? (value as? Double).flatMap { Int(exactly: $0.rounded()) }
                ?? (value as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "Ss"))) }
        }
        let inputs = Dictionary(uniqueKeysWithValues: others.map { ($0.id, $0) })
        let reports = ((object["others"] as? [[String: Any]]) ?? []).compactMap { raw -> DeepReadCloseReading.OtherReport? in
            guard let id = int(raw["source"]), let input = inputs[id],
                  let stance = DeepReadCloseReading.OtherReport.Stance(rawValue: string(raw["stance"])) else { return nil }
            return .init(id: id, title: input.source.title, url: input.source.url, site: input.site, stance: stance, summary: string(raw["summary"]))
        }
        // "others": [] is a valid answer (every other report was off topic); a reply without the key,
        // or whose reports all fail to parse, is not.
        guard let rawOthers = object["others"] as? [Any], rawOthers.isEmpty || !reports.isEmpty else { return nil }
        let reportIds = Set(reports.map(\.id))
        let bodyIds = Set(reading.bodyParagraphs.filter { $0.kind != .image }.map(\.id))
        let notes = ((object["notes"] as? [[String: Any]]) ?? []).compactMap { raw -> DeepReadCloseReading.Note? in
            guard let paragraph = int(raw["paragraph"]), bodyIds.contains(paragraph),
                  let kind = DeepReadCloseReading.Note.Kind(rawValue: string(raw["kind"])), [.add, .differ].contains(kind) else { return nil }
            let sources = ((raw["sources"] as? [Any]) ?? []).compactMap(int).filter(reportIds.contains)
            let title = string(raw["title"]), body = string(raw["body"])
            guard !sources.isEmpty, !body.isEmpty else { return nil }
            return .init(paragraph: paragraph, kind: kind, title: title, body: body, sources: sources)
        }
        var comparison: DeepReadCloseReading.Comparison?
        if let rows = (object["comparison"] as? [String: Any])?["rows"] as? [[String: Any]] {
            let parsed = rows.compactMap { raw -> DeepReadCloseReading.Comparison.Row? in
                let aspect = string(raw["aspect"]), primary = string(raw["primary"])
                var cells: [String: String] = [:]
                for (key, value) in (raw["cells"] as? [String: Any]) ?? [:] {
                    if let id = int(key), reportIds.contains(id), !string(value).isEmpty { cells[String(id)] = string(value) }
                }
                guard !aspect.isEmpty, !primary.isEmpty || !cells.isEmpty else { return nil }
                return .init(aspect: aspect, primary: primary, cells: cells, conflict: (raw["conflict"] as? Bool) ?? false)
            }
            if !parsed.isEmpty { comparison = .init(rows: Array(parsed.prefix(6))) }
        }
        var merged = reading
        merged.others = reports
        merged.notes += notes.prefix(8)
        merged.comparison = reports.isEmpty ? nil : comparison
        return merged
    }

    // MARK: Export

    static func markdown(_ reading: DeepReadCloseReading) -> String {
        var b = "# \(reading.title)\n\n"
        if !reading.guide.isEmpty { b += "> 导读：\(reading.guide)\n\n" }
        if let m = reading.modules {
            func bullets(_ items: [String]) -> String { items.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            if let verdict = m.verdict {
                b += "## 值不值得买\n\n**\(verdict.line)**\n\n"
                if !verdict.goodFor.isEmpty { b += "适合：\n" + bullets(verdict.goodFor) }
                if !verdict.skipIf.isEmpty { b += "可以跳过：\n" + bullets(verdict.skipIf) }
            }
            if !m.pros.isEmpty { b += "## 优点\n" + bullets(m.pros) }
            if !m.cons.isEmpty { b += "## 缺点\n" + bullets(m.cons) }
            if !m.specs.isEmpty {
                b += "## 关键规格\n\n| 项目 | 参数 | 变化 |\n| --- | --- | --- |\n"
                b += m.specs.map { "| \($0.name) | \($0.value) | \($0.change.isEmpty ? "—" : $0.change) |" }.joined(separator: "\n") + "\n\n"
            }
            if !m.fact.isEmpty { b += "## 一句话事实\n\n\(m.fact)\n\n" }
            if !m.timeline.isEmpty { b += "## 事件脉络\n" + bullets(m.timeline.map { "**\($0.date)** \($0.event)" }) }
            if !m.parties.isEmpty { b += "## 各方说法\n" + bullets(m.parties.map { "**\($0.who)**：\($0.said)" }) }
            if !m.uncertain.isEmpty { b += "## 待核实\n" + bullets(m.uncertain) }
            if let argument = m.argument {
                b += "## 论点地图\n\n**主张**：\(argument.claim)\n\n"
                if !argument.reasons.isEmpty { b += "论据：\n" + bullets(argument.reasons) }
                if !argument.counter.isEmpty { b += "反方会说：\n" + bullets(argument.counter) }
            }
            if !m.points.isEmpty { b += "## 要点\n" + bullets(m.points) }
        } else if let focus = reading.focus {
            b += "## \(focus.title)\n" + focus.items.map { "- **\($0.label)**：\($0.text)" }.joined(separator: "\n") + "\n\n"
        }
        let others = Dictionary((reading.others ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let rows = reading.comparison?.rows, !rows.isEmpty {
            let ids = (reading.others ?? []).map(\.id).filter { id in rows.contains { $0.cells[String(id)] != nil } }
            b += "## 多家对照\n\n| | 本文 | " + ids.map { others[$0]?.site ?? "" }.joined(separator: " | ") + " |\n"
            b += "|" + String(repeating: " --- |", count: ids.count + 2) + "\n"
            for row in rows {
                b += "| \(row.aspect)\(row.conflict ? " ≠" : "") | \(row.primary) | " + ids.map { row.cells[String($0)] ?? "—" }.joined(separator: " | ") + " |\n"
            }
            b += "\n"
        }
        b += "## 原文\n\n"
        let notes = Dictionary(grouping: reading.notes, by: \.paragraph)
        for paragraph in reading.bodyParagraphs {
            switch paragraph.kind {
            case .heading: b += "### \(paragraph.text)\n\n"
            case .image: b += "![](\(paragraph.text))\n\n"
            case .text: b += "\(paragraph.text)\n\n"
            }
            for note in notes[paragraph.id] ?? [] {
                let from = (note.sources ?? []).compactMap { others[$0]?.site }.joined(separator: "、")
                b += "> 【\(note.kind.label)\(from.isEmpty ? "" : " · \(from)")】\(note.title)：\(note.body)\n\n"
            }
        }
        if let reports = reading.others, !reports.isEmpty {
            b += "## 别家怎么说\n\n"
            for report in reports {
                b += "- 【\(report.stance.label)】\(report.site)：\(report.summary)" + (report.url.map { "（[原文](\($0))）" } ?? "") + "\n"
            }
            b += "\n"
        }
        if let url = reading.url { b += "原文：[\(reading.site)](\(url))\n" }
        return b
    }

    // MARK: Regex helpers

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let group = match.numberOfRanges > 1 ? 1 : 0
        return Range(match.range(at: group), in: text).map { String(text[$0]) }
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
