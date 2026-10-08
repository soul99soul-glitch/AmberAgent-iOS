import XCTest
@preconcurrency import Shared
@testable import AmberDeepRead

@MainActor
final class DeepReadCloseReadingTests: XCTestCase {
    private struct EmptyCredentials: DeepReadCredentialStorage {
        func read(account: String) throws -> String? { nil }
        func write(_ value: String, account: String) throws {}
    }

    private let article = """
    Title: iPhone 18 Pro Review
    URL Source: https://example.com/review

    Markdown Content:
    [Home](https://example.com) [Reviews](https://example.com/r)
    iPhone 18 Pro Review
    ====================
    ![Image 1: hero](https://img.example.com/hero.jpg)
    The **variable aperture** is the headline change, with [four stops](https://example.com/a).
    ## Battery
    It lasted a 25-hour travel day with 12% left.
    - Charges to 50% in 15 minutes
    [Home](https://example.com) [Reviews](https://example.com/r)
    """

    func testJinaMarkdownIsSegmentedIntoNumberedBlocks() {
        let page = DeepReadCloseReader.parseJina(article)
        XCTAssertEqual(page.title, "iPhone 18 Pro Review")
        XCTAssertNil(page.heroImageURL, "Jina's first image is often a logo; the article's images stay inline instead")
        let blocks = DeepReadCloseReader.segment(page.text)
        XCTAssertEqual(blocks.map(\.id), Array(1...blocks.count))
        XCTAssertEqual(blocks.map(\.kind), [.text, .heading, .image, .text, .heading, .text, .text])
        XCTAssertEqual(blocks[0].text, "Home Reviews", "links keep their text; the repeated menu is dropped once seen")
        XCTAssertEqual(blocks[1].text, "iPhone 18 Pro Review", "setext underline promotes the title")
        XCTAssertEqual(blocks[3].text, "The **variable aperture** is the headline change, with four stops.")
        XCTAssertEqual(blocks[6].text, "• Charges to 50% in 15 minutes")
    }

    func testHTMLFallbackKeepsBlocksHeadingsAndImages() {
        let html = """
        <html><head><title>T</title><script>evil()</script></head><body><nav>Menu</nav>
        <article><h2>Camera</h2><p>First paragraph.</p><img src="https://img.example.com/a.jpg"><p>Second&nbsp;&amp;   last.</p></article>
        <footer>Copyright</footer></body></html>
        """
        let blocks = DeepReadCloseReader.segment(DeepReadCloseReader.readableText(fromHTML: html))
        XCTAssertEqual(blocks.map(\.text), ["Camera", "First paragraph.", "https://img.example.com/a.jpg", "Second & last."])
        XCTAssertEqual(blocks.map(\.kind), [.heading, .text, .image, .text])
    }

    func testParseKeepsOnlyNotesOnRealBodyParagraphs() throws {
        let paragraphs = DeepReadCloseReader.segment("Menu\n# Title\nBody one.\nBody two.\nFooter links")
        let reply = """
        ```json
        {"genre":"review","title":"中文标题","guide":"导读内容","body_start":2,"body_end":4,
         "focus":{"title":"值不值得买","items":[{"label":"适合","text":"老用户"},{"label":"","text":"丢弃"}]},
         "notes":[{"paragraph":3,"kind":"context","title":"背景","body":"解释"},
                  {"paragraph":5,"kind":"data","title":"页脚","body":"不在正文"},
                  {"paragraph":4,"kind":"rumor","title":"未知类型","body":"丢弃"},
                  {"paragraph":"4","kind":"verify","title":"待核实","body":"存疑"}]}
        ```
        """
        let page = DeepReadCloseReader.Page(title: "Original", text: "", heroImageURL: nil)
        let reading = try XCTUnwrap(DeepReadCloseReader.parse(reply, page: page, url: "https://example.com", site: "example.com", paragraphs: paragraphs))
        XCTAssertEqual(reading.title, "中文标题")
        XCTAssertEqual(reading.originalTitle, "Original")
        XCTAssertEqual(reading.bodyParagraphs.map(\.id), [2, 3, 4])
        XCTAssertEqual(reading.notes.map(\.paragraph), [3, 4])
        XCTAssertEqual(reading.notes.map(\.kind), [.context, .verify])
        XCTAssertEqual(reading.focus?.items.map(\.label), ["适合"])
        XCTAssertNil(DeepReadCloseReader.parse(#"{"genre":"review","guide":""}"#, page: page, url: nil, site: "", paragraphs: paragraphs),
                     "a reply without a guide is not an annotation")
    }

    func testPromptNumbersParagraphsAndStopsAtBudget() {
        let long = (1...400).map { "第\($0)段" + String(repeating: "字", count: 80) }.joined(separator: "\n")
        let prompt = DeepReadCloseReader.prompt(title: "标题", site: "example.com", paragraphs: DeepReadCloseReader.segment(long))
        XCTAssertTrue(prompt.contains("[1] 第1段"))
        XCTAssertFalse(prompt.contains("[400] "))
        XCTAssertTrue(prompt.contains("以下段落因篇幅省略"))
    }

    func testRendererAnchorsNotesAndEscapesText() throws {
        let reading = DeepReadCloseReading(
            title: "标题 <script>", originalTitle: "Original", url: "https://example.com", site: "example.com", genre: "review",
            guide: "导读", focus: nil, bodyStart: 1, bodyEnd: 2, heroImageURL: nil,
            paragraphs: [.init(id: 1, kind: .text, text: "第一段 <b>x</b>"), .init(id: 2, kind: .heading, text: "小标题"),
                         .init(id: 3, kind: .text, text: "页脚")],
            notes: [.init(paragraph: 1, kind: .verify, title: "存疑", body: "需要确认")])
        let html = DeepReadCloseReadingRenderer.html(reading, palette: .init(accent: "#C8402F", bg: "#FBF7F1", fg: "#2A2320", surface: "#F2EADE", muted: "#6E6254", border: "#DBCEBC", dark: false),
                                                     fontMode: "serif", styleCSS: "", scale: 1)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains(#"<span class="n">1</span><div class="text"><p>"#))
        XCTAssertTrue(html.contains(#"<sup class="fn">1</sup></p>"#), "the paragraph carries its footnote mark")
        XCTAssertTrue(html.contains(#"<ol class="footnotes"><li><details><summary><span class="no">1</span><span class="kind">待核实</span><span class="t">存疑</span>"#))
        let printed = DeepReadCloseReadingRenderer.html(reading, palette: .init(accent: "#C8402F", bg: "#FBF7F1", fg: "#2A2320", surface: "#F2EADE", muted: "#6E6254", border: "#DBCEBC", dark: false),
                                                        fontMode: "serif", styleCSS: "", scale: 1, expandNotes: true)
        XCTAssertTrue(printed.contains("<li><details open>"), "a PDF cannot be tapped, so footnotes print expanded")
        XCTAssertFalse(html.contains("页脚"), "paragraphs outside the body range are not shown")
        XCTAssertTrue(DeepReadCloseReader.markdown(reading).contains("> 【待核实】存疑：需要确认"))
    }

    // MARK: Runtime

    private func configuredSettings() -> DeepReadSettingsStore {
        let settings = DeepReadSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: EmptyCredentials())
        var model = DeepReadModelConfiguration()
        model.apiKey = "test-model-key"
        settings.models = [model]
        settings.selectedModelID = model.id
        XCTAssertTrue(settings.save(), settings.errorMessage ?? "")
        return settings
    }

    private final class Probe {
        var fetched: [String] = []
        var searches = 0
        var reportSearches: [String] = []
        var reports: [IOSDeepReadSource] = []
        var unreachable: Set<String> = []
    }

    private func runtime(_ store: IOSDeepReadStore, provider: DeepReadPipelineTests.StageProvider, probe: Probe,
                         settings: DeepReadSettingsStore? = nil) -> DeepReadRuntime {
        DeepReadRuntime(settings: settings ?? configuredSettings(), store: store, provider: provider,
            searchSources: { _, _ in probe.searches += 1; return [] },
            enrichSources: { sources, _, _ in
                sources.map { source in
                    var read = source
                    let failed = source.url.map(probe.unreachable.contains) == true
                    if !failed { read.content += "\n网页正文：\(source.title) 的报道正文" }
                    read.metadata["scrape_status"] = failed ? "failed" : "ok"
                    return read
                }
            },
            fetchPrimary: { url, _ in
                probe.fetched.append(url)
                return DeepReadCloseReader.parseJina(self.article)
            },
            searchReports: { title, _ in probe.reportSearches.append(title); return probe.reports },
            beginBackgroundTask: { _, _ in .invalid }, endBackgroundTask: { _ in })
    }

    private func waitForFinish(_ runtime: DeepReadRuntime) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !runtime.activeTaskIds.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(runtime.activeTaskIds.isEmpty, "Runtime did not finish")
    }

    func testSingleLinkCloseReadingFetchesOriginalWithoutTopicSearch() async throws {
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let provider = DeepReadPipelineTests.StageProvider([
            #"{"genre":"review","title":"iPhone 18 Pro 评测","guide":"一篇评测的导读。","body_start":2,"body_end":7,"notes":[{"paragraph":4,"kind":"context","title":"可变光圈","body":"解释"}]}"#
        ])
        let probe = Probe()
        let runtime = runtime(store, provider: provider, probe: probe)
        let link = IOSDeepReadSource(kind: .searchResult, title: "example.com", content: "https://example.com/review", url: "https://example.com/review")
        let id = try runtime.create(title: "", sources: [link], primaryIndex: 0)
        await waitForFinish(runtime)

        let task = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(task.status, .succeeded)
        XCTAssertEqual(task.title, "iPhone 18 Pro Review", "the fetched title replaces the link's host")
        XCTAssertNil(task.missingSections)
        XCTAssertEqual(probe.fetched, ["https://example.com/review"])
        XCTAssertEqual(probe.searches, 0, "close reading never runs the topic search")
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertTrue(provider.userPrompts.first?.contains("[4] The **variable aperture**") == true)
        let reading = try XCTUnwrap(DeepReadCloseReading.decode(task.structuredJSON))
        XCTAssertEqual(reading.title, "iPhone 18 Pro 评测")
        XCTAssertEqual(reading.notes.map(\.paragraph), [4])
        XCTAssertEqual(task.sources.first?.metadata["scrape_status"], "ok")
        XCTAssertNil(task.sources.first?.metadata[DeepReadCloseReader.titlePendingKey])
        XCTAssertTrue(task.resultMarkdown.contains("导读：一篇评测的导读。"))
    }

    func testFailedGuideSkipsTheComparisonAndKeepsUncomparedSources() async throws {
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let provider = DeepReadPipelineTests.StageProvider(["not json"])
        let probe = Probe()
        probe.reports = [IOSDeepReadSource(kind: .searchResult, title: "别家", content: "摘要", url: "https://example.org/other")]
        let runtime = runtime(store, provider: provider, probe: probe)
        var sources = (1...7).map { hotSource("来源\($0)", provider: "hacker_news", rank: $0 + 1, url: "https://example.com/\($0)") }
        sources.insert(hotSource("IT 之家报道", provider: "newsnow:ithome", rank: 1, url: "https://www.ithome.com/0/1.htm"), at: 0)
        let id = try runtime.create(title: "话题", sources: sources, primaryIndex: 0)
        await waitForFinish(runtime)

        let task = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(provider.callCount, 1, "no comparison without a guide to hang it on")
        XCTAssertEqual(task.missingSections, [DeepReadCloseReader.missingSection])
        XCTAssertEqual(Set(task.sources.map(\.title)), Set((1...7).map { "来源\($0)" }).union(["iPhone 18 Pro Review"]),
                       "all seven topic inputs survive although only five were compared; the primary carries the fetched title")
    }

    func testFailedAnnotationStillKeepsReadableOriginalMarkedPartial() async throws {
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let provider = DeepReadPipelineTests.StageProvider(["not json"])
        let probe = Probe()
        let runtime = runtime(store, provider: provider, probe: probe)
        let text = IOSDeepReadSource(kind: .manualText, title: "粘贴的文章", content: "第一段正文。\n第二段正文。")
        let id = try runtime.create(title: "", sources: [text], primaryIndex: 0)
        await waitForFinish(runtime)

        let task = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(task.status, .succeeded)
        XCTAssertEqual(task.missingSections, [DeepReadCloseReader.missingSection])
        let reading = try XCTUnwrap(DeepReadCloseReading.decode(task.structuredJSON))
        XCTAssertEqual(reading.bodyParagraphs.map(\.text), ["第一段正文。", "第二段正文。"])
        XCTAssertTrue(reading.notes.isEmpty)
        XCTAssertTrue(probe.fetched.isEmpty, "pasted text needs no fetch")
    }

    private func hotSource(_ title: String, provider: String, rank: Int, url: String?) -> IOSDeepReadSource {
        IOSDeepReadSource(kind: .hotTopic, title: title, content: title, url: url,
                          metadata: ["provider_id": provider, "provider_name": provider, "rank": String(rank)])
    }

    func testPrimaryIsBestRankedArticleNeverADiscussion() {
        let zhihu = hotSource("知乎问题", provider: "newsnow:zhihu", rank: 1, url: "https://www.zhihu.com/question/1")
        let ithome = hotSource("IT 之家", provider: "newsnow:ithome", rank: 4, url: "https://www.ithome.com/0/1.htm")
        let hn = hotSource("HN", provider: "hacker_news", rank: 2, url: "https://example.com/hn")
        XCTAssertEqual(DeepReadCloseReader.primaryIndex(in: [zhihu, ithome, hn]), 2)
        XCTAssertNil(DeepReadCloseReader.primaryIndex(in: [zhihu]), "a discussion page is not an original to read")
        // Every provider that links to an article qualifies, including ones added later (sspai was missed by an allowlist).
        let sspai = hotSource("少数派", provider: "newsnow:sspai", rank: 3, url: "https://sspai.com/post/115061")
        XCTAssertEqual(DeepReadCloseReader.primaryIndex(in: [sspai]), 0)
        for discussion in ["newsnow:weibo", "newsnow:douyin", "newsnow:bilibili-hot-search", "newsnow:xueqiu-hotstock"] {
            XCTAssertNil(DeepReadCloseReader.primaryIndex(in: [hotSource("话题", provider: discussion, rank: 1, url: "https://example.com/s")]), discussion)
        }
        XCTAssertNil(DeepReadCloseReader.primaryIndex(in: [hotSource("无链接", provider: "hacker_news", rank: 1, url: nil)]))
    }

    private let guideReply = #"{"genre":"review","title":"iPhone 18 Pro 评测","guide":"导读。","body_start":2,"body_end":7,"notes":[{"paragraph":4,"kind":"context","title":"光圈","body":"解释"}]}"#

    func testTopicCloseReadingComparesOtherReports() async throws {
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let compareReply = """
        {"others":[{"source":2,"stance":"differ","summary":"续航结论更保守"},{"source":3,"stance":"add","summary":"补充了散热数据"},{"source":9,"stance":"add","summary":"不存在"}],
         "notes":[{"paragraph":6,"kind":"differ","sources":[2],"title":"续航","body":"Gizmodo 说剩 35%"},
                  {"paragraph":6,"kind":"add","sources":[7],"title":"无效来源","body":"丢弃"},
                  {"paragraph":99,"kind":"add","sources":[3],"title":"无效段落","body":"丢弃"}],
         "comparison":{"rows":[{"aspect":"续航","primary":"剩 12%","cells":{"2":"剩 35%","5":"无效"},"conflict":true}]}}
        """
        let provider = DeepReadPipelineTests.StageProvider([guideReply, compareReply])
        let probe = Probe()
        probe.reports = [IOSDeepReadSource(kind: .searchResult, title: "搜索到的评测", content: "摘要", url: "https://example.org/other"),
                         IOSDeepReadSource(kind: .searchResult, title: "原文换了个地址", content: "摘要", url: "https://ithome.com/0/1.htm/?utm_source=hot")]
        let runtime = runtime(store, provider: provider, probe: probe)
        let sources = [
            hotSource("知乎讨论", provider: "newsnow:zhihu", rank: 1, url: "https://www.zhihu.com/question/1"),
            hotSource("IT 之家报道", provider: "newsnow:ithome", rank: 2, url: "https://www.ithome.com/0/1.htm"),
            hotSource("HN 链接", provider: "hacker_news", rank: 5, url: "https://example.com/hn"),
        ]
        let id = try runtime.create(title: "iPhone 18 Pro 评测", sources: sources, primaryIndex: DeepReadCloseReader.primaryIndex(in: sources))
        await waitForFinish(runtime)

        let task = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(task.status, .succeeded)
        XCTAssertNil(task.missingSections)
        XCTAssertEqual(probe.fetched, ["https://www.ithome.com/0/1.htm"])
        XCTAssertEqual(probe.reportSearches, ["iPhone 18 Pro 评测"])
        XCTAssertEqual(probe.searches, 0)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertTrue(provider.userPrompts.last?.contains("[S3] 来源：example.org｜搜索到的评测") == true)
        XCTAssertEqual(task.sources.count, 4, "primary plus the three other reports are kept as sources")
        XCTAssertFalse(task.sources.contains { $0.title == "原文换了个地址" }, "the original found again under another URL is not an other report")
        let reading = try XCTUnwrap(DeepReadCloseReading.decode(task.structuredJSON))
        XCTAssertEqual(reading.others?.map(\.id), [2, 3])
        XCTAssertEqual(reading.others?.first?.site, "example.com")
        XCTAssertEqual(reading.notes.filter { $0.kind == .differ }.map(\.sources), [[2]])
        XCTAssertFalse(reading.notes.contains { $0.title.hasPrefix("无效") })
        XCTAssertEqual(reading.comparison?.rows.first?.cells, ["2": "剩 35%"])
        XCTAssertTrue(task.resultMarkdown.contains("## 多家对照"))
        XCTAssertTrue(task.resultMarkdown.contains("【分歧 · example.com】续航"))
    }

    func testFailedComparisonKeepsGuideAndMarksOtherReportsMissing() async throws {
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let provider = DeepReadPipelineTests.StageProvider([guideReply, "not json"])
        let probe = Probe()
        probe.reports = [IOSDeepReadSource(kind: .searchResult, title: "别家", content: "摘要", url: "https://example.org/other")]
        let runtime = runtime(store, provider: provider, probe: probe)
        let link = IOSDeepReadSource(kind: .searchResult, title: "example.com", content: "https://example.com/review", url: "https://example.com/review")
        let id = try runtime.create(title: "", sources: [link], primaryIndex: 0)
        await waitForFinish(runtime)

        let task = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(task.status, .succeeded)
        XCTAssertEqual(task.missingSections, [DeepReadCloseReader.compareMissingSection])
        XCTAssertEqual(provider.callCount, 2, "the comparison was attempted")
        let reading = try XCTUnwrap(DeepReadCloseReading.decode(task.structuredJSON))
        XCTAssertEqual(reading.guide, "导读。")
        XCTAssertNil(reading.others)
    }

    func testUnreachableSearchReportIsNotKeptSoARetryCanScrapeItAgain() async throws {
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let provider = DeepReadPipelineTests.StageProvider([guideReply, #"{"others":[{"source":1,"stance":"add","summary":"补充"}],"notes":[]}"#])
        let probe = Probe()
        var unreachable = IOSDeepReadSource(kind: .searchResult, title: "抓取失败的报道", content: "摘要", url: "https://example.net/down")
        unreachable.metadata["search_query"] = "iPhone 18 Pro Review"
        var reachable = IOSDeepReadSource(kind: .searchResult, title: "别家", content: "摘要", url: "https://example.org/other")
        reachable.metadata["search_query"] = "iPhone 18 Pro Review"
        probe.reports = [unreachable, reachable]
        probe.unreachable = ["https://example.net/down"]
        let runtime = runtime(store, provider: provider, probe: probe)
        let link = IOSDeepReadSource(kind: .searchResult, title: "example.com", content: "https://example.com/review", url: "https://example.com/review")
        let id = try runtime.create(title: "", sources: [link], primaryIndex: 0)
        await waitForFinish(runtime)

        let task = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(task.status, .succeeded)
        XCTAssertEqual(task.sources.map(\.title), ["iPhone 18 Pro Review", "别家"])
    }

    func testRendererShowsComparisonAndOtherReports() {
        let reading = DeepReadCloseReading(
            title: "标题", originalTitle: "标题", url: nil, site: "bgr.com", genre: "review", guide: "导读", focus: nil,
            bodyStart: 1, bodyEnd: 1, heroImageURL: nil, paragraphs: [.init(id: 1, kind: .text, text: "正文")],
            notes: [.init(paragraph: 1, kind: .differ, title: "重量", body: "说法不同", sources: [1])],
            others: [.init(id: 1, title: "Gizmodo 评测", url: "https://gizmodo.com/r", site: "gizmodo.com", stance: .differ, summary: "更保守")],
            comparison: .init(rows: [.init(aspect: "增重", primary: "5 克", cells: ["1": "16 克"], conflict: true)]))
        let html = DeepReadCloseReadingRenderer.html(reading, palette: .init(accent: "#C8402F", bg: "#FBF7F1", fg: "#2A2320", surface: "#F2EADE", muted: "#6E6254", border: "#DBCEBC", dark: false),
                                                     fontMode: "serif", styleCSS: "", scale: 1)
        XCTAssertTrue(html.contains("<th>本文</th><th>gizmodo.com</th>"))
        XCTAssertTrue(html.contains(#"<td class="mark">16 克</td>"#))
        XCTAssertTrue(html.contains(#"<span class="from">gizmodo.com</span>"#))
        XCTAssertTrue(html.contains(#"<span class="stance s-differ">分歧</span>"#))
    }

    // MARK: Templates

    private let templatePage = DeepReadCloseReader.Page(title: "Original", text: "", heroImageURL: nil)
    private lazy var templateParagraphs = DeepReadCloseReader.segment("第一段正文。\n第二段正文。")

    private func reading(_ json: String) throws -> DeepReadCloseReading {
        try XCTUnwrap(DeepReadCloseReader.parse(json, page: templatePage, url: nil, site: "example.com", paragraphs: templateParagraphs))
    }

    private func html(_ reading: DeepReadCloseReading) -> String {
        DeepReadCloseReadingRenderer.html(reading, palette: .init(accent: "#C8402F", bg: "#FBF7F1", fg: "#2A2320", surface: "#F2EADE", muted: "#6E6254", border: "#DBCEBC", dark: false),
                                         fontMode: "serif", styleCSS: "", scale: 1)
    }

    private func assertOrder(_ html: String, _ markers: [String], file: StaticString = #filePath, line: UInt = #line) {
        let positions = markers.map { html.range(of: $0)?.lowerBound }
        XCTAssertFalse(positions.contains(nil), "missing \(zip(markers, positions).filter { $0.1 == nil }.map(\.0))", file: file, line: line)
        let found = positions.compactMap { $0 }
        XCTAssertEqual(found, found.sorted(), "blocks out of order", file: file, line: line)
    }

    func testReviewTemplateKeepsOnlyReviewBlocksInOrder() throws {
        let review = try reading("""
        {"genre":"review","guide":"导读","verdict":{"line":"值得升级","good_for":["老用户"],"skip_if":["上代用户"]},
         "pros":["续航好","屏幕好","a","b","c","超出上限"],"cons":["贵"],
         "specs":[{"name":"续航","value":"18 小时","change":""},{"name":"","value":"丢弃"}],
         "fact":"不该出现的新闻字段","points":["不该出现"]}
        """)
        XCTAssertEqual(review.template, .review)
        let m = try XCTUnwrap(review.modules)
        XCTAssertEqual(m.pros.count, 5)
        XCTAssertEqual(m.specs.map(\.name), ["续航"])
        XCTAssertTrue(m.fact.isEmpty && m.points.isEmpty, "only the chosen template's blocks are kept")
        let page = html(review)
        assertOrder(page, ["值不值得买", "优缺点", "关键规格", #"<p class="section">原文</p>"#])
        XCTAssertFalse(page.contains("<th>变化</th>"), "the change column hides when no spec has one")
    }

    func testNewsTemplatePutsOpenQuestionsBeforeTheOriginal() throws {
        let news = try reading("""
        {"genre":"interview","guide":"导读","fact":"苹果发布新表","timeline":[{"date":"9月10日","event":"发布会"}],
         "parties":[{"who":"苹果","said":"续航不变"}],"uncertain":["精度提升 60 倍的说法"]}
        """)
        XCTAssertEqual(news.template, .news, "interviews use the news template")
        assertOrder(html(news), ["一句话事实", "事件脉络", "各方说法", "待核实", #"<p class="section">原文</p>"#])
        XCTAssertTrue(DeepReadCloseReader.markdown(news).contains("## 待核实\n- 精度提升 60 倍的说法"))
    }

    func testOpinionAndGeneralTemplates() throws {
        let opinion = try reading(#"{"genre":"opinion","guide":"导读","argument":{"claim":"主张","reasons":["论据"],"counter":["反方"]}}"#)
        assertOrder(html(opinion), ["论点地图", "主张", "论据", "反方会说", #"<p class="section">原文</p>"#])
        let general = try reading(#"{"genre":"paper","guide":"导读","points":["要点一","要点二"]}"#)
        XCTAssertEqual(general.template, .general)
        assertOrder(html(general), [#"<p class="section">要点</p>"#, #"<p class="section">原文</p>"#])
    }

    func testReadingsFromBeforeTemplatesKeepTheirFocusBlock() throws {
        var legacy = try reading(#"{"genre":"review","guide":"导读","focus":{"title":"值不值得买","items":[{"label":"适合","text":"老用户"}]}}"#)
        legacy.modules = nil
        let page = html(legacy)
        XCTAssertTrue(page.contains(#"<section class="focus">"#))
        XCTAssertFalse(page.contains(#"<section class="verdict">"#))
    }

    // MARK: Original only

    func testOriginalOnlySkipsTheModelUntilAskedThenAnnotates() async throws {
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let provider = DeepReadPipelineTests.StageProvider([guideReply])
        let probe = Probe()
        let runtime = runtime(store, provider: provider, probe: probe)
        let link = IOSDeepReadSource(kind: .searchResult, title: "example.com", content: "https://example.com/review", url: "https://example.com/review")
        let id = try runtime.create(title: "", sources: [link], primaryIndex: 0, originalOnly: true)
        await waitForFinish(runtime)

        var task = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(task.status, .succeeded)
        XCTAssertNil(task.missingSections, "reading only the original is a finished article, not a partial one")
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertTrue(probe.reportSearches.isEmpty)
        XCTAssertEqual(task.title, "iPhone 18 Pro Review")
        var reading = try XCTUnwrap(DeepReadCloseReading.decode(task.structuredJSON))
        XCTAssertFalse(reading.hasGuide)
        XCTAssertEqual(reading.bodyParagraphs.count, DeepReadCloseReader.segment(DeepReadCloseReader.parseJina(article).text).count)

        try runtime.annotate(taskId: id)
        await waitForFinish(runtime)
        task = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(probe.fetched.count, 1, "the stored original is reused, not fetched again")
        XCTAssertEqual(probe.reportSearches, ["iPhone 18 Pro Review"])
        XCTAssertNil(task.sources.first?.metadata[DeepReadCloseReader.originalOnlyKey])
        reading = try XCTUnwrap(DeepReadCloseReading.decode(task.structuredJSON))
        XCTAssertTrue(reading.hasGuide)
    }

    func testOriginalModeShowsOnlyTheTypesetOriginal() throws {
        var full = try reading(#"{"genre":"review","guide":"导读","pros":["优点"],"body_start":1,"body_end":2,"notes":[{"paragraph":1,"kind":"context","title":"背景","body":"解释"}]}"#)
        full.others = [.init(id: 1, title: "别家", url: nil, site: "other.com", stance: .add, summary: "补充")]
        let page = DeepReadCloseReadingRenderer.html(full, palette: .init(accent: "#C8402F", bg: "#FBF7F1", fg: "#2A2320", surface: "#F2EADE", muted: "#6E6254", border: "#DBCEBC", dark: false),
                                                     fontMode: "serif", styleCSS: "", scale: 1, originalOnly: true)
        XCTAssertTrue(page.contains("<p>第一段正文。</p><p>第二段正文。</p>"))
        for aiPart in ["导读", "优缺点", "<details", #"class="n""#, "别家怎么说"] {
            XCTAssertFalse(page.contains(aiPart), aiPart)
        }
        XCTAssertTrue(page.contains(#"<p class="kicker">原文</p><h1>Original</h1>"#), "original mode titles the page with the original title")
    }

    func testOriginalOnlyNeedsNoModelConfigured() async throws {
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let unconfigured = DeepReadSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: EmptyCredentials())
        let runtime = runtime(store, provider: DeepReadPipelineTests.StageProvider([guideReply]), probe: Probe(), settings: unconfigured)
        let link = IOSDeepReadSource(kind: .searchResult, title: "example.com", content: "https://example.com/review", url: "https://example.com/review")
        let id = try runtime.create(title: "", sources: [link], primaryIndex: 0, originalOnly: true)
        await waitForFinish(runtime)
        XCTAssertEqual(store.task(id: id)?.status, .succeeded, store.task(id: id)?.failureMessage ?? "")

        try runtime.annotate(taskId: id)
        await waitForFinish(runtime)
        let task = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(task.status, .succeeded, "asking for a guide without a model keeps the original")
        XCTAssertEqual(runtime.error(for: id), "请在设置中配置服务商、选择可用的阅读模型，并点击“保存并应用”。")
        XCTAssertNotNil(DeepReadCloseReading.decode(task.structuredJSON))
    }
}

// MARK: Phase 1 review fixes

@MainActor
final class DeepReadCloseReadingReviewFixTests: XCTestCase {
    func testSegmentKeepsNumbersSeparatesRulesFromSetextAndJoinsHardWraps() {
        let text = """
        Steps
        -----

        1. Open the box
        2. Plug it in

        A paragraph that was
        hard wrapped at eighty columns.

        * * *

        Before a rule

        ---

        中文段落被硬换行
        拆成了两行。
        """
        let blocks = DeepReadCloseReader.segment(text)
        XCTAssertEqual(blocks.map(\.text), [
            "Steps", "1. Open the box", "2. Plug it in",
            "A paragraph that was hard wrapped at eighty columns.",
            "Before a rule", "中文段落被硬换行拆成了两行。",
        ])
        XCTAssertEqual(blocks.map(\.kind), [.heading, .text, .text, .text, .text, .text], "a rule after a blank line is not a Setext underline")
        // Line-per-block text (scraped HTML) has no blank lines and is never joined.
        XCTAssertEqual(DeepReadCloseReader.segment("第一段\n第二段").count, 2)
    }

    func testLongTextBodyExtendsPastThePromptWindow() throws {
        let paragraphs = DeepReadCloseReader.segment((1...400).map { "第\($0)段" + String(repeating: "字", count: 80) }.joined(separator: "\n"))
        let window = DeepReadCloseReader.promptWindow(paragraphs)
        XCTAssertTrue(window.truncated)
        let reply = #"{"genre":"other","guide":"导读","body_start":1,"body_end":\#(window.lastId),"notes":[]}"#
        let reading = try XCTUnwrap(DeepReadCloseReader.parse(reply, page: .init(title: "T", text: "", heroImageURL: nil), url: nil, site: "", paragraphs: paragraphs))
        XCTAssertEqual(reading.bodyEnd, 400, "ending at the last visible paragraph means the model could not see further")
        let giant = DeepReadCloseReader.promptWindow([.init(id: 1, kind: .text, text: String(repeating: "长", count: 30_000))])
        XCTAssertEqual(giant.lines.count, 1, "an oversized first paragraph is cut, not dropped")
    }

    func testSameArticleIgnoresTrackingAndHostPrefixes() {
        XCTAssertTrue(DeepReadCloseReader.sameArticle("https://www.ithome.com/0/1.htm?utm_source=x#top", "https://m.ithome.com/0/1.htm/"))
        XCTAssertFalse(DeepReadCloseReader.sameArticle("https://ithome.com/0/1.htm", "https://ithome.com/0/2.htm"))
        XCTAssertFalse(DeepReadCloseReader.sameArticle("https://news.example.com/article?id=1", "https://news.example.com/article?id=2"),
                       "sites that address articles by query keep the query")
        XCTAssertTrue(DeepReadCloseReader.sameArticle("https://news.example.com/article?id=1&utm_medium=x", "https://news.example.com/article?id=1&spm=a.b"))
    }

    func testSegmentEdgeCasesFromReview() {
        // Line-per-paragraph text with a few blank lines between sections keeps its paragraphs.
        XCTAssertEqual(DeepReadCloseReader.segment("第一段。\n第二段。\n\n第三段。\n第四段。\n\n第五段。").count, 5)
        // Wrapped Latin text outside ASCII still gets its space; CJK never does.
        XCTAssertEqual(DeepReadCloseReader.segment("Un café\nau lait\n\nNext\n\nEnd").first?.text, "Un café au lait")
        XCTAssertEqual(DeepReadCloseReader.segment("iPhone\n很好用\n\nNext\n\nEnd").first?.text, "iPhone很好用")
        // A rule under a line that produced no block does not promote an earlier paragraph.
        let ruled = DeepReadCloseReader.segment("Menu\n\nBody text.\nMenu\n---\n\nEnd")
        XCTAssertEqual(ruled.map(\.kind), [.text, .text, .text])
        // Fenced code keeps one block per line instead of being joined into prose.
        let code = DeepReadCloseReader.segment("Intro.\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nOutro.")
        XCTAssertEqual(code.map(\.text), ["Intro.", "let a = 1", "let b = 2", "Outro."])
        // A decorative tilde rule or an unclosed fence does not turn the rest of the article into code.
        let ruledByTildes = DeepReadCloseReader.segment("Intro.\n\n~~~~~~~~~~~~~~~~\n\nA wrapped\nline.\n\n## Head")
        XCTAssertEqual(ruledByTildes.last?.kind, .heading)
        XCTAssertTrue(ruledByTildes.contains { $0.text == "A wrapped line." })
        XCTAssertTrue(DeepReadCloseReader.segment("Intro.\n\n```\nA wrapped\nline.\n\nEnd.").contains { $0.text == "A wrapped line." })
        // Korean separates words with spaces, so a wrap inside it keeps one.
        XCTAssertEqual(DeepReadCloseReader.segment("안녕하세요 세계\n입니다 정말\n\nNext\n\nEnd").first?.text, "안녕하세요 세계 입니다 정말")
    }

    func testNumberedParagraphKeepsItsFootnoteInline() {
        let reading = DeepReadCloseReading(
            title: "T", originalTitle: "T", url: nil, site: "s", genre: "", guide: "导读", focus: nil, bodyStart: 1, bodyEnd: 1,
            heroImageURL: nil, paragraphs: [.init(id: 1, kind: .text, text: "3. Plug **it** in")],
            notes: [.init(paragraph: 1, kind: .key, title: "要点", body: "b")])
        let palette = DeepReadCloseReadingRenderer.Palette(accent: "#C8402F", bg: "#FBF7F1", fg: "#2A2320", surface: "#F2EADE", muted: "#6E6254", border: "#DBCEBC", dark: false)
        let html = DeepReadCloseReadingRenderer.html(reading, palette: palette, fontMode: "serif", styleCSS: "", scale: 1)
        XCTAssertTrue(html.contains(#"<p>3. Plug <strong>it</strong> in<sup class="fn">1</sup></p>"#), "the item keeps its own number and its mark")
        let printed = DeepReadCloseReadingRenderer.html(reading, palette: palette, fontMode: "serif", styleCSS: "", scale: 1, expandNotes: true)
        XCTAssertTrue(printed.contains(".footnotes details[open] summary::after{content:none;}"),
                      "a printed footnote has no 展开/收起 toggle text (the rule must outrank the [open] one)")
        // Code lines kept from a fence are text, not Markdown blocks; a lone item number stays text too.
        let code = DeepReadCloseReading(
            title: "T", originalTitle: "T", url: nil, site: "s", genre: "", guide: "", focus: nil, bodyStart: 1, bodyEnd: 4,
            heroImageURL: nil, paragraphs: [.init(id: 1, kind: .text, text: "# install deps"), .init(id: 2, kind: .text, text: "- name: build"),
                                            .init(id: 3, kind: .text, text: "1."), .init(id: 4, kind: .text, text: "**Bold** start")],
            notes: [])
        let codeHTML = DeepReadCloseReadingRenderer.html(code, palette: palette, fontMode: "serif", styleCSS: "", scale: 1)
        XCTAssertTrue(codeHTML.contains("<p># install deps</p>"))
        XCTAssertTrue(codeHTML.contains("<p>- name: build</p>"))
        XCTAssertTrue(codeHTML.contains("<p>1.</p>"))
        XCTAssertTrue(codeHTML.contains("<p><strong>Bold</strong> start</p>"))
        let large = DeepReadCloseReadingRenderer.html(reading, palette: palette, fontMode: "serif", styleCSS: "", scale: 1.5)
        XCTAssertTrue(large.contains("(min-width:1140px)"), "the side-note layout needs the zoomed width, not the raw viewport")
    }

    func testAllOffTopicReportsIsAValidComparison() throws {
        let paragraphs = DeepReadCloseReader.segment("第一段。\n第二段。")
        let reading = DeepReadCloseReader.unannotated(page: .init(title: "T", text: "", heroImageURL: nil), url: nil, site: "s", paragraphs: paragraphs)
        let others = [DeepReadCloseReader.OtherInput(id: 1, source: IOSDeepReadSource(kind: .searchResult, title: "无关", content: "x", url: "https://a.com"))]
        let merged = try XCTUnwrap(DeepReadCloseReader.mergeComparison(#"{"others":[],"notes":[],"comparison":{"rows":[{"aspect":"价格","primary":"贵"}]}}"#, into: reading, others: others))
        XCTAssertEqual(merged.others, [])
        XCTAssertNil(merged.comparison, "no reports leaves nothing to compare")
        XCTAssertNil(DeepReadCloseReader.mergeComparison(#"{"notes":[]}"#, into: reading, others: others), "a reply without others is still a failure")
        XCTAssertNil(DeepReadCloseReader.mergeComparison(#"{"others":[{"source":7,"stance":"agree"}],"notes":[]}"#, into: reading, others: others),
                     "reports that all fail to parse are a failure, not an all-off-topic answer")
    }
}
