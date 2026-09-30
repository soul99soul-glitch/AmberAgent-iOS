import XCTest
@testable import iosApp

@MainActor
final class IOSFreeSearchAggregatorTests: XCTestCase {
    override func setUp() async throws {
        IOSFreeSearchAggregator.resetCooldowns()
    }

    // MARK: - Parsers (fixtures trimmed from real 2026-09 result pages)

    func testParsesDuckDuckGoHTMLAndSkipsAds() {
        let html = """
        <div class="result"><h2 class="result__title">
        <a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad_domain=x">Ad</a></h2></div>
        <div class="result"><h2 class="result__title">
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fone&amp;rut=1">First &amp; Result</a>
        </h2><a class="result__snippet" href="x">Snippet with <b>markup</b>.</a></div>
        """

        let results = IOSFreeSearchAggregator.parseDuckDuckGoHTML(html)

        XCTAssertEqual(results.map(\.url), ["https://example.com/one"])
        XCTAssertEqual(results.first?.title, "First & Result")
        XCTAssertEqual(results.first?.snippet, "Snippet with markup.")
    }

    func testParsesBraveHTMLAndSkipsBraveLinks() {
        let html = """
        <div class="snippet svelte-jmfu5f" data-pos="0" data-type="web" data-keynav="true"><div class="result-content">
        <a href="https://zhuanlan.zhihu.com/p/677935286" target="_self" class="l1"><div class="site-name">Zhihu</div>
        <div class="title search-snippet-title line-clamp-2 svelte-14r20fy" title="大模型幻觉产生原因及解决方案 - 知乎">大模型幻觉产生原因及解决方案 - 知乎</div></a>
        <div class="generic-snippet"><div class="content desktop-default-regular t-primary"><!---->数据分布不一致导致幻觉。<!----></div></div>
        </div></div>
        <div class="snippet" data-type="web"><a href="https://search.brave.com/goggles">Goggles</a><div class="title" title="Goggles">Goggles</div></div>
        """

        let results = IOSFreeSearchAggregator.parseBraveHTML(html)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, "https://zhuanlan.zhihu.com/p/677935286")
        XCTAssertEqual(results.first?.title, "大模型幻觉产生原因及解决方案 - 知乎")
        XCTAssertEqual(results.first?.snippet, "数据分布不一致导致幻觉。")
    }

    func testParses360HTMLPrefersRealURLAndSkipsOwnPages() {
        let html = """
        <ul><li class="res-list"><h3 class="res-title"><a href="https://www.so.com/link?m=abc" data-mdurl="https://www.toutiao.com/article/1/"><em>大模型</em>为什么会出现幻觉</a></h3>
        <p class="res-desc">幻觉的成因与缓解。</p></li>
        <li class="res-list"><h3 class="res-title"><a href="https://wenku.so.com/d/6ccd">360文库</a></h3>
        <span class="res-list-summary">文库摘要</span></li></ul>
        """

        let results = IOSFreeSearchAggregator.parse360HTML(html)

        XCTAssertEqual(results.map(\.url), ["https://www.toutiao.com/article/1/"])
        XCTAssertEqual(results.first?.title, "大模型为什么会出现幻觉")
        XCTAssertEqual(results.first?.snippet, "幻觉的成因与缓解。")
    }

    func testParsesQuarkHydrateJSON() {
        let html = """
        <script type="application/json" id="s-data-1" data-used-by="hydrate">{"extraData":{"sc":"ss_text"},"data":{"initialData":{"titleProps":{"content":"大模型幻觉详解-<em>稀土掘金</em>"},"sourceProps":{"dest_url":"https://juejin.cn/post/1"},"summaryProps":{"content":"模型无依据编造内容。"}}}}</script>
        <script type="application/json" id="s-data-2" data-used-by="hydrate">{"extraData":{"sc":"text_recommend"},"data":{"initialData":{"title":"相关推荐"}}}</script>
        """

        let results = IOSFreeSearchAggregator.parseQuarkHTML(html)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "大模型幻觉详解-稀土掘金")
        XCTAssertEqual(results.first?.url, "https://juejin.cn/post/1")
        XCTAssertEqual(results.first?.snippet, "模型无依据编造内容。")
    }

    func testParsesWikipediaInSearchOrderAndSkipsDisambiguation() {
        let body = """
        {"query":{"pages":[
          {"title":"Hallucination (disambiguation)","index":2,"fullurl":"https://en.wikipedia.org/wiki/H","extract":"Hallucination may refer to:"},
          {"title":"Hallucination (artificial intelligence)","index":1,"fullurl":"https://en.wikipedia.org/wiki/AI_H","extract":"A response that contains false information."}
        ]}}
        """

        let results = IOSFreeSearchAggregator.parseWikipediaJSON(body)

        XCTAssertEqual(results.map(\.title), ["Hallucination (artificial intelligence)"])
    }

    func testParsesHackerNewsFallsBackToDiscussionURL() {
        let body = #"{"hits":[{"objectID":"42","title":"Ask HN: LLM hallucinations","url":null,"points":10,"num_comments":3}]}"#

        let results = IOSFreeSearchAggregator.parseHackerNewsJSON(body)

        XCTAssertEqual(results.first?.url, "https://news.ycombinator.com/item?id=42")
        XCTAssertTrue(results.first?.snippet.contains("10 分") == true)
    }

    func testBingUnwrapsCkTrackingLinks() {
        let target = "https://example.com/article?id=1"
        let encoded = Data(target.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let html = """
        <li class="b_algo"><h2><a href="https://www.bing.com/ck/a?!&amp;&amp;p=abc&amp;u=a1\(encoded)&amp;ntb=1">Title</a></h2><p>Body</p></li>
        """

        XCTAssertEqual(IOSSearchExecutor.parseBingHTML(html: html, maxResults: 5).first?.url, target)
    }

    // MARK: - Aggregation

    func testRoundRobinMergeInterleavesEnginesAndDedupes() {
        let merged = IOSFreeSearchAggregator.roundRobinMerge(
            [
                .bing: [result("https://a.com/1"), result("https://a.com/2"), result("https://a.com/3")],
                .brave: [result("https://www.a.com/1/"), result("https://b.com/1")],
            ],
            order: [.bing, .brave],
            limit: 10
        )

        XCTAssertEqual(merged.map(\.url), ["https://a.com/1", "https://a.com/2", "https://b.com/1", "https://a.com/3"])
    }

    func testChineseQueryUsesChineseWikipediaAndSkipsHackerNews() async throws {
        let transport = HostMockTransport(responses: [:])

        _ = try? await IOSFreeSearchAggregator.search(
            query: "大模型 幻觉", maxResults: 5, googleFallbackEnabled: false, transport: transport
        )

        let hosts = Set(transport.requests.compactMap { $0.url?.host })
        XCTAssertTrue(hosts.contains("zh.wikipedia.org"))
        XCTAssertFalse(hosts.contains("hn.algolia.com"))
    }

    func testOneEngineFailingDoesNotFailTheSearch() async throws {
        let transport = HostMockTransport(responses: [
            "www.bing.com": .init(status: 500, body: ""),
            "html.duckduckgo.com": .init(status: 200, body: IOSSearchExecutorTests.duckDuckGoHTML(url: "https://example.com/ddg", title: "DDG")),
        ])

        let results = try await IOSFreeSearchAggregator.search(
            query: "swift", maxResults: 5, googleFallbackEnabled: false, transport: transport
        )

        XCTAssertEqual(results.map(\.url), ["https://example.com/ddg"])
    }

    func testBlockedEngineCoolsDownAndIsSkippedOnNextSearch() async throws {
        let transport = HostMockTransport(responses: [
            "html.duckduckgo.com": .init(status: 202, body: "anomaly"),
            "www.bing.com": .init(status: 200, body: IOSSearchExecutorTests.bingHTML(url: "https://example.com/b", title: "B")),
        ])
        var clock = Date(timeIntervalSince1970: 1_000)

        _ = try await IOSFreeSearchAggregator.search(
            query: "swift", maxResults: 5, googleFallbackEnabled: false, transport: transport, now: { clock }
        )
        transport.requests.removeAll()
        _ = try await IOSFreeSearchAggregator.search(
            query: "swift", maxResults: 5, googleFallbackEnabled: false, transport: transport, now: { clock }
        )
        XCTAssertFalse(transport.requests.contains { $0.url?.host == "html.duckduckgo.com" })

        clock = clock.addingTimeInterval(IOSFreeSearchAggregator.blockedCooldown + 1)
        transport.requests.removeAll()
        _ = try await IOSFreeSearchAggregator.search(
            query: "swift", maxResults: 5, googleFallbackEnabled: false, transport: transport, now: { clock }
        )
        XCTAssertTrue(transport.requests.contains { $0.url?.host == "html.duckduckgo.com" })
    }

    func testGoogleFallbackRunsOnlyWhenResultsAreWeak() async throws {
        let weak = HostMockTransport(responses: [
            "www.bing.com": .init(status: 200, body: IOSSearchExecutorTests.bingHTML(url: "https://example.com/b", title: "B")),
        ])
        var googleCalls = 0
        let fallback: (String, Int) async throws -> [IOSSearchResult] = { _, _ in
            googleCalls += 1
            return [IOSSearchResult(title: "G", url: "https://example.com/g", snippet: "")]
        }

        let results = try await IOSFreeSearchAggregator.search(
            query: "swift", maxResults: 5, googleFallbackEnabled: true, transport: weak, googleFallback: fallback
        )
        XCTAssertEqual(results.map(\.url), ["https://example.com/b", "https://example.com/g"])

        _ = try await IOSFreeSearchAggregator.search(
            query: "swift", maxResults: 5, googleFallbackEnabled: false, transport: weak, googleFallback: fallback
        )
        XCTAssertEqual(googleCalls, 1, "开关关闭时不启用 Google 兜底")
    }

    func testAllEnginesEmptyThrowsGuidanceError() async {
        let transport = HostMockTransport(responses: [:])

        do {
            _ = try await IOSFreeSearchAggregator.search(
                query: "swift", maxResults: 5, googleFallbackEnabled: false, transport: transport
            )
            XCTFail("Expected freeSearchExhausted")
        } catch {
            guard case .freeSearchExhausted = error as? IOSSearchExecutorError else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("Tavily"))
        }
    }

    // MARK: - Jina Reader

    func testScrapeFallsBackToJinaReaderWhenEnabled() async throws {
        let defaults = UserDefaults(suiteName: "FreeSearch-\(UUID().uuidString)")!
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        store.setSearchBuiltinJinaEnabled(true)
        let transport = HostMockTransport(responses: [
            "zhuanlan.zhihu.com": .init(status: 403, body: "forbidden"),
            "r.jina.ai": .init(status: 200, body: "Title: 知乎文章\n\nURL Source: https://zhuanlan.zhihu.com/p/1\n\nMarkdown Content:\n正文内容"),
        ])

        let output = try await IOSSearchExecutor.execute(
            toolName: "scrape_web",
            toolInput: #"{"url":"https://zhuanlan.zhihu.com/p/1"}"#,
            settings: store.snapshot,
            transport: transport
        )

        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(payload["via"] as? String, "jina_reader")
        XCTAssertEqual(payload["title"] as? String, "知乎文章")
        XCTAssertEqual(payload["content"] as? String, "正文内容")
        let jinaRequest = try XCTUnwrap(transport.requests.first { $0.url?.host == "r.jina.ai" })
        XCTAssertEqual(jinaRequest.url?.absoluteString, "https://r.jina.ai/https://zhuanlan.zhihu.com/p/1")
        XCTAssertFalse(jinaRequest.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") ?? true)

        store.setSearchBuiltinJinaEnabled(false)
        do {
            _ = try await IOSSearchExecutor.execute(
                toolName: "scrape_web",
                toolInput: #"{"url":"https://zhuanlan.zhihu.com/p/1"}"#,
                settings: store.snapshot,
                transport: transport
            )
            XCTFail("关闭 Jina 后直连失败应直接报错")
        } catch {}
    }

    // MARK: - Live checks (opt-in; real network)

    func testLiveEachFreeEngineReturnsResultsWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AMBER_LIVE_FREE_SEARCH"] == "1" else {
            throw XCTSkip("Set AMBER_LIVE_FREE_SEARCH=1 to run the real free-search check.")
        }
        var report: [String] = []
        for query in ["大模型 幻觉", "LLM hallucination survey"] {
            for engine in IOSFreeSearchEngine.allCases {
                IOSFreeSearchAggregator.resetCooldowns()
                let started = Date()
                do {
                    let results = try await IOSFreeSearchAggregator.searchSingleEngineForTesting(engine, query: query)
                    report.append("\(query) | \(engine.rawValue) | \(results.count) | \(Int(Date().timeIntervalSince(started) * 1000))ms | \(results.first?.url ?? "-")")
                } catch {
                    report.append("\(query) | \(engine.rawValue) | ERROR \(error) | \(Int(Date().timeIntervalSince(started) * 1000))ms")
                }
            }
            let google = try? await IOSGoogleWebViewSearch.search(query: query, maxResults: 10)
            report.append("\(query) | google_webview | \(google?.count ?? -1) | \(google?.first?.url ?? "-") | \(google?.first?.title ?? "") | \(google?.first?.snippet.prefix(80) ?? "")")
            let merged = try await IOSFreeSearchAggregator.search(
                query: query, maxResults: 10, googleFallbackEnabled: false, transport: IOSURLSessionSearchHTTPTransport()
            )
            report.append("\(query) | AGGREGATE | \(merged.count)")
            XCTAssertGreaterThanOrEqual(merged.count, 5)
        }
        print("FREE_SEARCH_LIVE_REPORT\n" + report.joined(separator: "\n"))
    }

    private func result(_ url: String) -> IOSSearchResult {
        IOSSearchResult(title: url, url: url, snippet: "")
    }
}

private final class HostMockTransport: IOSSearchHTTPTransport {
    struct Response {
        let status: Int
        let body: String
    }

    private let responses: [String: Response]
    var requests: [URLRequest] = []

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        requests.append(request)
        let response = request.url?.host.flatMap { responses[$0] } ?? Response(status: 200, body: "")
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        return (http, Data(response.body.utf8))
    }
}
