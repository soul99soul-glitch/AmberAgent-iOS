import XCTest
@preconcurrency import Shared
@testable import AmberDeepRead

@MainActor
final class DeepReadSourceCollectorTests: XCTestCase {
    private struct EmptyCredentials: DeepReadCredentialStorage {
        func read(account: String) throws -> String? { nil }
        func write(_ value: String, account: String) throws {}
    }
    func testExistingVerifiedContentIsReusedWithoutScrapeOrDuplicateBody() async {
        let source = IOSDeepReadSource(kind: .searchResult, title: "资料", content: "已抓取正文",
                                      url: "https://example.org/article", metadata: ["scrape_status": "ok"])
        var calls = 0
        let result = await DeepReadSourceCollector.enrich([source], settings: nil, scrape: { _, _ in
            calls += 1
            return "{}"
        })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(result, [source])
    }

    func testScrapeStoresTextAndOriginImage() async {
        let source = IOSDeepReadSource(kind: .searchResult, title: "资料", content: "搜索摘要", url: "https://example.org")
        let result = await DeepReadSourceCollector.enrich([source], settings: nil, scrape: { input, _ in
            let request = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]
            XCTAssertEqual(request?["url"] as? String, "https://example.org")
            return #"{"content":"网页正文","images":["https://example.org/cover.jpg"]}"#
        })
        XCTAssertEqual(result.first?.metadata["scrape_status"], "ok")
        XCTAssertEqual(result.first?.metadata["hero_image_url"], "https://example.org/cover.jpg")
        XCTAssertTrue(result.first?.content.contains("网页正文") == true)
        XCTAssertTrue(result.first?.hasUsableGenerationContent == true)
    }

    func testScrapeFailureKeepsExistingTextAndMarksError() async {
        let source = IOSDeepReadSource(kind: .searchResult, title: "资料", content: "有效摘要", url: "https://example.org")
        let result = await DeepReadSourceCollector.enrich([source], settings: nil, scrape: { _, _ in
            throw URLError(.notConnectedToInternet)
        })
        XCTAssertEqual(result.first?.content, "有效摘要")
        XCTAssertEqual(result.first?.metadata["scrape_status"], "scrape_failed_keep_content")
        XCTAssertNotNil(result.first?.metadata["scrape_error"])
    }

    func testFailedSourceIsExcludedAndNeverInventedAsManualContent() async throws {
        let source = try IOSDeepReadSourceNormalizer.searchFailureSource(query: "主题", error: "连接失败")
        var calls = 0
        let result = await DeepReadSourceCollector.enrich([source], settings: nil, scrape: { _, _ in
            calls += 1
            return #"{"content":"不存在的内容"}"#
        })
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(try XCTUnwrap(result.first).hasUsableGenerationContent)
    }

    func testDeduplicationKeepsFirstSourceAndDistinctInputs() {
        let first = IOSDeepReadSource(kind: .searchResult, title: "来源", content: "第一份内容", url: "https://Example.org/a")
        let duplicate = IOSDeepReadSource(kind: .searchResult, title: "重复", content: "重复内容", url: "https://example.org/a")
        let manual = IOSDeepReadSource(kind: .manualText, title: "手动材料", content: "正文")
        XCTAssertEqual(DeepReadSourceCollector.dedupe([first, duplicate, manual]), [first, manual])
    }

    func testSameFilenameWithDifferentContentsKeepsBothInputs() {
        let first = IOSDeepReadSource(kind: .file, title: "notes.txt", content: "第一份文件正文")
        let second = IOSDeepReadSource(kind: .file, title: "notes.txt", content: "第二份文件正文")
        XCTAssertEqual(DeepReadSourceCollector.dedupe([first, second, first]), [first, second])
    }

    func testURLDeduplicationPreservesCaseSensitivePathsAndQueries() {
        let upperPath = IOSDeepReadSource(kind: .webMount, title: "大写路径", content: "正文", url: "https://Example.org/Article?key=A")
        let lowerPath = IOSDeepReadSource(kind: .webMount, title: "小写路径", content: "正文", url: "https://example.org/article?key=A")
        let lowerQuery = IOSDeepReadSource(kind: .webMount, title: "不同参数", content: "正文", url: "https://example.org/Article?key=a")
        XCTAssertEqual(DeepReadSourceCollector.dedupe([upperPath, lowerPath, lowerQuery]), [upperPath, lowerPath, lowerQuery])
    }

    func testSearchConsumesConfiguredResultSizeForEveryAngle() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = DeepReadSettingsStore(defaults: defaults, credentials: EmptyCredentials())
        settings.resultSize = 23
        XCTAssertTrue(settings.save())
        var calls = 0
        _ = await DeepReadSourceCollector.search(title: "阅读主题", settings: settings.searchSettings, execute: { input, _ in
            calls += 1
            let json = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
            XCTAssertEqual(json["max_results"] as? Int, 23)
            return []
        })
        XCTAssertEqual(calls, 7)
    }

    func testSearchTakesResultsRoundRobinAcrossAngles() async {
        var angle = 0
        let sources = await DeepReadSourceCollector.search(title: "阅读主题", settings: nil, execute: { _, _ in
            angle += 1
            return (1...10).map { IOSSearchResult(title: "角度\(angle)-\($0)", url: "https://example.com/\(angle)/\($0)", snippet: "摘要") }
        })
        let angles = Set(sources.compactMap { $0.title.split(separator: "-").first })
        XCTAssertEqual(angles.count, 7, "every angle contributes before any one fills the 12-source cap")
    }

    func testSearchFailureReturnsVisibleSourceWithoutGenerationContent() async throws {
        let sources = await DeepReadSourceCollector.search(title: "阅读主题", settings: nil, execute: { _, _ in
            throw NSError(domain: "search-test", code: 401, userInfo: [NSLocalizedDescriptionKey: "搜索鉴权失败：401 unauthorized"])
        })
        XCTAssertFalse(sources.isEmpty)
        XCTAssertTrue(sources.allSatisfy { $0.metadata["scrape_status"] == "failed" })
        XCTAssertTrue(sources.allSatisfy { $0.metadata["search_query"] != nil && $0.metadata["scrape_error"] != nil })
        XCTAssertTrue(sources.allSatisfy { !$0.hasUsableGenerationContent })
        XCTAssertTrue(try XCTUnwrap(sources.first).content.contains("搜索鉴权失败"))
    }

    func testSearchKeepsDistinctCaseSensitiveResultURLs() async {
        let sources = await DeepReadSourceCollector.search(title: "阅读主题", settings: nil, execute: { _, _ in
            [IOSSearchResult(title: "大写", url: "https://Example.org/Article", snippet: "资料一"),
             IOSSearchResult(title: "小写", url: "https://example.org/article", snippet: "资料二")]
        })
        XCTAssertEqual(sources.count, 2)
    }

    func testSearchAnglesPreserveOfficialTimelineAnalysisAndImages() {
        let queries = DeepReadSourceCollector.searchQueries(from: "OpenAI 模型发布")
        XCTAssertTrue(queries.contains { $0.contains("官方") })
        XCTAssertTrue(queries.contains { $0.contains("时间线") })
        XCTAssertTrue(queries.contains { $0.contains("专家解读") })
        XCTAssertTrue(queries.contains { $0.contains("现场图") })
        XCTAssertTrue(queries.contains { $0.contains("跑分") })
    }

    func testSearchExecutesEveryAngleAndMergesSourcesWithProviderImages() async {
        var queries: [String] = []
        let sources = await DeepReadSourceCollector.search(title: "OpenAI 模型发布", settings: nil, execute: { input, _ in
            let json = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
            let query = json["query"] as! String
            queries.append(query)
            XCTAssertEqual(json["max_results"] as? Int, 4)
            return [IOSSearchResult(title: "来源", url: "https://example.org/shared", snippet: "可靠摘要", images: ["https://example.org/cover.jpg"]),
                    IOSSearchResult(title: query, url: "https://example.org/\(queries.count)", snippet: "各角度摘要")]
        })
        XCTAssertEqual(queries.count, 9)
        XCTAssertEqual(sources.count, 10)
        XCTAssertEqual(sources.filter { $0.url == "https://example.org/shared" }.count, 1)
        XCTAssertEqual(sources.first?.metadata["hero_image_url"], "https://example.org/cover.jpg")
    }
}
