import Foundation
import XCTest
@testable import AmberMac

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { self.storage = value }
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.withLock { body(&storage) }
    }
}

@MainActor final class DesktopSearchNativeTests: XCTestCase {
    private func makeSettings(suite: String = "amber.search.native.\(UUID().uuidString)") -> (DesktopSearchSettings, UserDefaults, DesktopMemoryCredentials) {
        let defaults = UserDefaults(suiteName: suite)!
        let credentials = DesktopMemoryCredentials()
        let settings = DesktopSearchSettings(defaults: defaults, credentials: credentials)
        return (settings, defaults, credentials)
    }

    func testURLIdentityPreservesPathCaseQueryCaseAndPortWhileNormalizingHostAndScheme() {
        XCTAssertNotEqual(
            DesktopSearchURLIdentity.dedupeKey(for: "https://en.wikipedia.org/wiki/LaTeX"),
            DesktopSearchURLIdentity.dedupeKey(for: "https://en.wikipedia.org/wiki/Latex")
        )
        XCTAssertNotEqual(
            DesktopSearchURLIdentity.dedupeKey(for: "https://example.com/watch?v=AbCdEf"),
            DesktopSearchURLIdentity.dedupeKey(for: "https://example.com/watch?v=abcdef")
        )
        XCTAssertNotEqual(
            DesktopSearchURLIdentity.dedupeKey(for: "https://example.com/watch?id=Foo/"),
            DesktopSearchURLIdentity.dedupeKey(for: "https://example.com/watch?id=Foo")
        )
        XCTAssertNotEqual(
            DesktopSearchURLIdentity.dedupeKey(for: "https://example.com:8443/docs"),
            DesktopSearchURLIdentity.dedupeKey(for: "https://example.com/docs")
        )
        XCTAssertEqual(
            DesktopSearchURLIdentity.dedupeKey(for: "https://Example.COM/Path/"),
            DesktopSearchURLIdentity.dedupeKey(for: "http://www.example.com/Path")
        )
        XCTAssertEqual(
            DesktopSearchURLIdentity.dedupeKey(for: "https://m.example.com:443/Path/"),
            DesktopSearchURLIdentity.dedupeKey(for: "http://example.com:80/Path")
        )
    }

    func testLegacyV1ConfigMigratesWithoutLosingKeychainAndMultiSourcePersistsWithoutLeakingKeys() throws {
        let suite = "amber.search.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let credentials = DesktopMemoryCredentials()
        try credentials.save("exa-secret-key-123", id: DesktopSearchService.exa.credentialID)
        try credentials.save("tavily-secret-key-456", id: DesktopSearchService.tavily.credentialID)

        let legacyPayload = #"{"service":"exa","resultCount":9}"#.data(using: .utf8)!
        defaults.set(legacyPayload, forKey: "desktop.search.v1")

        let migrated = DesktopSearchSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(migrated.service, .exa)
        XCTAssertEqual(migrated.enabledServices, [.exa])
        XCTAssertEqual(migrated.resultCount, 9)
        XCTAssertEqual(migrated.executionMode, .sequentialFallback)
        XCTAssertEqual(try migrated.apiKey(for: .exa), "exa-secret-key-123")
        XCTAssertEqual(try migrated.apiKey(for: .tavily), "tavily-secret-key-456")

        try migrated.saveConfiguration(
            enabledServices: [.exa, .tavily, .free],
            serviceOrder: [.exa, .tavily, .free, .brave, .serper, .serpapi, .zhipu, .jina],
            executionMode: .parallel,
            resultCount: 12,
            exaOptions: DesktopExaOptions(searchType: .deepLite, contentMode: .highlightsAndText, includeImages: true, imageLinksCount: 4)
        )

        let rawSaved = String(decoding: try XCTUnwrap(defaults.data(forKey: "desktop.search.v1")), as: UTF8.self)
        XCTAssertFalse(rawSaved.contains("exa-secret-key-123"))
        XCTAssertFalse(rawSaved.contains("tavily-secret-key-456"))

        let reloaded = DesktopSearchSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(reloaded.enabledServices, [.exa, .tavily, .free])
        XCTAssertEqual(reloaded.service, .exa)
        XCTAssertEqual(reloaded.executionMode, .parallel)
        XCTAssertEqual(reloaded.resultCount, 12)
        XCTAssertEqual(reloaded.exaOptions.searchType, .deepLite)
        XCTAssertEqual(reloaded.exaOptions.contentMode, .highlightsAndText)
        XCTAssertEqual(reloaded.exaOptions.imageLinksCount, 4)
    }

    func testExplicitAllDisabledDoesNotSilentlyFallbackToFreeSearch() async throws {
        let (settings, defaults, credentials) = makeSettings()
        try settings.saveConfiguration(enabledServices: [], executionMode: .sequentialFallback, resultCount: 5)

        let reloaded = DesktopSearchSettings(defaults: defaults, credentials: credentials)
        XCTAssertTrue(reloaded.enabledServices.isEmpty)
        XCTAssertTrue(reloaded.explicitlyConfigured)
        XCTAssertThrowsError(try reloaded.requestJSON())

        let networkCalled = LockedBox(false)
        do {
            _ = try await DesktopSearchEngine.execute(
                name: "search_web",
                input: #"{"query":"Swift 6"}"#,
                settings: reloaded,
                transport: { _ in
                    networkCalled.value = true
                    throw URLError(.badServerResponse)
                },
                freeSearch: { _, _, _ in
                    networkCalled.value = true
                    return [DesktopSearchHit(title: "Unexpected", url: "https://example.com", snippet: "No")]
                }
            )
            XCTFail("Expected an error when all search services are explicitly disabled")
        } catch {
            XCTAssertFalse(networkCalled.value, "Must not silently invoke free search when user disabled all services")
            XCTAssertTrue(error.localizedDescription.contains("未启用任何搜索服务"), error.localizedDescription)
        }
    }

    func testExaSearchBuildsNativePayloadAndExtractsRichImagesAndMetadata() async throws {
        let (settings, _, _) = makeSettings()
        try settings.saveConfiguration(
            enabledServices: [.exa],
            executionMode: .sequentialFallback,
            resultCount: 5,
            apiKeys: [.exa: "exa-fixture-token"]
        )

        let capturedRequest = LockedBox<URLRequest?>(nil)
        let capturedBodyJSON = LockedBox<String>("{}")

        let input = #"""
        {
          "query": "transformer attention mechanism",
          "max_results": 3,
          "type": "deep-lite",
          "category": "research paper",
          "include_domains": ["arxiv.org", "openreview.net"],
          "exclude_domains": ["spam.example.com"],
          "start_published_date": "2025-01-01T00:00:00.000Z",
          "end_published_date": "2026-10-01T00:00:00.000Z",
          "additional_queries": ["multi-head attention", "flash attention"],
          "highlights": true,
          "highlights_query": "scaling complexity",
          "include_full_text": true,
          "text_max_characters": 3000,
          "include_summary": true,
          "summary_query": "Core contribution",
          "max_age_hours": 24,
          "subpages": 1,
          "subpage_target": ["appendix"],
          "include_images": true,
          "image_links": 2
        }
        """#

        let output = try await DesktopSearchEngine.execute(
            name: "search_web",
            input: input,
            settings: settings,
            transport: { request in
                capturedRequest.value = request
                if let data = request.httpBody {
                    capturedBodyJSON.value = String(decoding: data, as: UTF8.self)
                }
                let responseJSON: [String: Any] = [
                    "resolvedSearchType": "deep-lite",
                    "results": [
                        [
                            "id": "https://arxiv.org/abs/2501.00001",
                            "title": "FlashAttention-Next",
                            "url": "https://arxiv.org/abs/2501.00001",
                            "publishedDate": "2025-06-15T00:00:00.000Z",
                            "author": "Tri Dao",
                            "summary": "Hardware-aware attention with linear scaling.",
                            "highlights": ["Achieves 2.4x speedup on H100 GPUs."],
                            "text": "Full paper text describing IO-aware tiling.",
                            "image": "https://arxiv.org/html/2501.00001/fig1.png",
                            "extras": [
                                "richImageLinks": [
                                    [
                                        "url": "https://arxiv.org/html/2501.00001/fig1.png",
                                        "alt": "Figure 1: Throughput comparison across sequence lengths"
                                    ],
                                    [
                                        "url": "https://arxiv.org/html/2501.00001/fig2.png",
                                        "alt": "Figure 2: Memory bandwidth utilization"
                                    ]
                                ],
                                "imageLinks": [
                                    "https://arxiv.org/html/2501.00001/fig3.png"
                                ]
                            ],
                            "subpages": [
                                [
                                    "title": "Appendix A: Benchmarks",
                                    "url": "https://arxiv.org/abs/2501.00001/appendix",
                                    "summary": "Detailed latency tables."
                                ]
                            ]
                        ]
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: responseJSON)
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, http)
            }
        )

        let capturedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(capturedBodyJSON.value.utf8)) as? [String: Any])
        XCTAssertEqual(capturedRequest.value?.url?.absoluteString, "https://api.exa.ai/search")
        XCTAssertEqual(capturedRequest.value?.value(forHTTPHeaderField: "x-api-key"), "exa-fixture-token")
        XCTAssertEqual(capturedBody["query"] as? String, "transformer attention mechanism")
        XCTAssertEqual(capturedBody["numResults"] as? Int, 3)
        XCTAssertEqual(capturedBody["type"] as? String, "deep-lite")
        XCTAssertEqual(capturedBody["category"] as? String, "publication", "research paper alias should normalize to publication")
        XCTAssertEqual(capturedBody["includeDomains"] as? [String], ["arxiv.org", "openreview.net"])
        XCTAssertEqual(capturedBody["excludeDomains"] as? [String], ["spam.example.com"])
        XCTAssertEqual(capturedBody["startPublishedDate"] as? String, "2025-01-01T00:00:00.000Z")
        XCTAssertEqual(capturedBody["endPublishedDate"] as? String, "2026-10-01T00:00:00.000Z")
        XCTAssertEqual(capturedBody["additionalQueries"] as? [String], ["multi-head attention", "flash attention"])

        let contents = try XCTUnwrap(capturedBody["contents"] as? [String: Any])
        XCTAssertEqual((contents["highlights"] as? [String: Any])?["query"] as? String, "scaling complexity")
        XCTAssertEqual((contents["text"] as? [String: Any])?["maxCharacters"] as? Int, 3000)
        XCTAssertEqual((contents["summary"] as? [String: Any])?["query"] as? String, "Core contribution")
        XCTAssertEqual(contents["maxAgeHours"] as? Int, 24)
        XCTAssertEqual(contents["subpages"] as? Int, 1)
        XCTAssertEqual(contents["subpageTarget"] as? String, "appendix")
        let extras = try XCTUnwrap(contents["extras"] as? [String: Any])
        XCTAssertEqual(extras["imageLinks"] as? Int, 2)
        XCTAssertEqual(extras["richImageLinks"] as? Int, 2)

        XCTAssertEqual(output.results.count, 1)
        XCTAssertEqual(output.images.count, 3)
        XCTAssertEqual(output.images[0].url, "https://arxiv.org/html/2501.00001/fig1.png")
        XCTAssertEqual(output.images[0].alt, "Figure 1: Throughput comparison across sequence lengths")
        XCTAssertEqual(output.images[0].sourceURL, "https://arxiv.org/abs/2501.00001")
        XCTAssertEqual(output.images[1].url, "https://arxiv.org/html/2501.00001/fig2.png")
        XCTAssertEqual(output.images[2].url, "https://arxiv.org/html/2501.00001/fig3.png")

        let mediaMeta = try XCTUnwrap(output.mediaMetadataEntries)
        XCTAssertEqual(mediaMeta["app.amber.media.origin"], "search")
        let decodedImages = try JSONDecoder().decode([DesktopSearchImage].self, from: Data(try XCTUnwrap(mediaMeta["app.amber.media.images"]).utf8))
        XCTAssertEqual(decodedImages.count, 3)
        XCTAssertEqual(decodedImages[0].alt, "Figure 1: Throughput comparison across sequence lengths")
        XCTAssertTrue(output.text.contains("![Figure 1: Throughput comparison across sequence lengths](https://arxiv.org/html/2501.00001/fig1.png)"))
    }

    func testExaLiteAndCategoryConstraintsOmitUnsupportedFieldsToAvoidHTTP400() {
        let liteParams = DesktopExaParameters.parse(from: [
            "type": "lite",
            "category": "people",
            "exclude_domains": ["example.com"],
            "start_published_date": "2025-01-01T00:00:00.000Z",
            "additional_queries": ["extra"],
            "include_summary": true,
            "max_age_hours": 12,
            "subpages": 2,
            "include_images": true
        ])
        let body = DesktopExaClient.buildSearchBody(
            query: "AI researcher",
            maxResults: 5,
            parameters: liteParams,
            defaults: DesktopExaOptions(searchType: .lite, contentMode: .highlights, includeImages: true)
        )
        XCTAssertEqual(body["type"] as? String, "lite")
        XCTAssertEqual(body["category"] as? String, "people")
        XCTAssertNil(body["excludeDomains"], "people category does not support excludeDomains on Exa")
        XCTAssertNil(body["startPublishedDate"], "people category does not support startPublishedDate on Exa")
        XCTAssertNil(body["additionalQueries"], "lite mode does not support additionalQueries on Exa")

        let contents = body["contents"] as? [String: Any] ?? [:]
        XCTAssertEqual(contents["highlights"] as? Bool, true)
        XCTAssertNil(contents["summary"], "lite mode rejects contents.summary with 400")
        XCTAssertNil(contents["extras"], "lite mode rejects contents.extras with 400")
        XCTAssertNil(contents["maxAgeHours"], "lite mode rejects contents.maxAgeHours with 400")
        XCTAssertNil(contents["subpages"], "lite mode rejects contents.subpages with 400")
    }

    func testExaContentsAnswerAndFindSimilarEndpointsWorkNatively() async throws {
        let (settings, _, _) = makeSettings()
        try settings.saveConfiguration(
            enabledServices: [.exa],
            resultCount: 4,
            apiKeys: [.exa: "exa-key"]
        )

        let seenPaths = LockedBox<[String]>([])
        let contentsBodyJSON = LockedBox<String>("{}")
        let transport: DesktopSearchHTTPHandler = { request in
            let path = request.url?.path ?? ""
            seenPaths.withValue { $0.append(path) }
            let responseDict: [String: Any]
            switch path {
            case "/contents":
                if let data = request.httpBody {
                    contentsBodyJSON.value = String(decoding: data, as: UTF8.self)
                }
                responseDict = [
                    "results": [
                        [
                            "url": "https://example.com/article",
                            "title": "Deep Dive Article",
                            "text": "Full extracted body text from Exa contents.",
                            "image": "https://example.com/cover.jpg"
                        ]
                    ],
                    "statuses": [
                        ["id": "https://example.com/article", "status": "success"]
                    ]
                ]
            case "/answer":
                responseDict = [
                    "answer": "Exa is an AI-native search engine.",
                    "citations": [
                        [
                            "id": "https://exa.ai/blog",
                            "url": "https://exa.ai/blog",
                            "title": "Exa Blog",
                            "text": "Exa provides neural web search.",
                            "image": "https://exa.ai/og.png"
                        ]
                    ]
                ]
            case "/findSimilar":
                responseDict = [
                    "results": [
                        [
                            "url": "https://similar.example.com/post",
                            "title": "Similar Post",
                            "highlights": ["Related research topic."]
                        ]
                    ]
                ]
            default:
                XCTFail("Unexpected endpoint path: \(path)")
                responseDict = [:]
            }
            let data = try JSONSerialization.data(withJSONObject: responseDict)
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, http)
        }

        let contentsOut = try await DesktopSearchEngine.execute(
            name: "exa_contents",
            input: #"{"urls":["https://example.com/article"],"include_summary":true,"max_age_hours":0}"#,
            settings: settings,
            transport: transport
        )
        let contentsBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsBodyJSON.value.utf8)) as? [String: Any])
        XCTAssertEqual(contentsBody["urls"] as? [String], ["https://example.com/article"])
        XCTAssertEqual(contentsBody["summary"] as? Bool, true, "Exa /contents places content options at the top level")
        XCTAssertEqual(contentsBody["maxAgeHours"] as? Int, 0)
        XCTAssertTrue(contentsOut.text.contains("Full extracted body text"))
        XCTAssertEqual(contentsOut.images.first?.url, "https://example.com/cover.jpg")

        let answerOut = try await DesktopSearchEngine.execute(
            name: "exa_answer",
            input: #"{"query":"What is Exa?","model":"exa-pro"}"#,
            settings: settings,
            transport: transport
        )
        XCTAssertTrue(answerOut.text.contains("Exa is an AI-native search engine."))
        XCTAssertEqual(answerOut.results.first?.url, "https://exa.ai/blog")
        XCTAssertEqual(answerOut.images.first?.url, "https://exa.ai/og.png")

        let similarOut = try await DesktopSearchEngine.execute(
            name: "exa_find_similar",
            input: #"{"url":"https://example.com/article","exclude_source_domain":true}"#,
            settings: settings,
            transport: transport
        )
        XCTAssertEqual(similarOut.results.first?.url, "https://similar.example.com/post")
        XCTAssertEqual(seenPaths.value, ["/contents", "/answer", "/findSimilar"])
    }

    func testSequentialFallbackMovesToSecondaryOnFailureAndRedactsSecretKey() async throws {
        let (settings, _, _) = makeSettings()
        try settings.saveConfiguration(
            enabledServices: [.exa, .tavily, .free],
            executionMode: .sequentialFallback,
            resultCount: 5,
            apiKeys: [.exa: "super-secret-exa-key", .tavily: "super-secret-tavily-key"]
        )

        let callOrder = LockedBox<[String]>([])
        let output = try await DesktopSearchEngine.execute(
            name: "search_web",
            input: #"{"query":"macOS Liquid Glass"}"#,
            settings: settings,
            transport: { request in
                let host = request.url?.host ?? ""
                callOrder.withValue { $0.append(host) }
                if host == "api.exa.ai" {
                    let errData = #"{"error":"Invalid key super-secret-exa-key"}"#.data(using: .utf8)!
                    let http = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                    return (errData, http)
                }
                if host == "api.tavily.com" {
                    let okData = try JSONSerialization.data(withJSONObject: [
                        "images": [
                            ["url": "https://cdn.example.com/liquid-glass.png", "description": "Liquid Glass capsule toolbar"]
                        ],
                        "results": [
                            [
                                "title": "Liquid Glass Design Guide",
                                "url": "https://developer.example.com/liquid-glass",
                                "content": "Dynamic refraction and specular highlights."
                            ]
                        ]
                    ])
                    let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (okData, http)
                }
                XCTFail("Free search should not be called after Tavily succeeded")
                throw URLError(.cannotConnectToHost)
            },
            freeSearch: { _, _, _ in
                callOrder.withValue { $0.append("free") }
                return []
            }
        )

        XCTAssertEqual(callOrder.value, ["api.exa.ai", "api.tavily.com"])
        XCTAssertEqual(output.sources.count, 2)
        XCTAssertFalse(output.sources[0].succeeded)
        XCTAssertTrue(output.sources[1].succeeded)
        XCTAssertFalse(output.text.contains("super-secret-exa-key"), "API key must be redacted from fallback message")
        XCTAssertTrue(output.fallbackReason?.contains("[REDACTED]") == true)
        XCTAssertTrue(output.fallbackReason?.contains("已自动回退至 Tavily") == true)
        XCTAssertEqual(output.images.first?.url, "https://cdn.example.com/liquid-glass.png")
        XCTAssertEqual(output.images.first?.alt, "Liquid Glass capsule toolbar")
    }

    func testParallelExecutionMergesPartialSuccessesDeduplicatesURLsAndPreservesImages() async throws {
        let (settings, _, _) = makeSettings()
        try settings.saveConfiguration(
            enabledServices: [.exa, .tavily, .brave],
            executionMode: .parallel,
            resultCount: 10,
            apiKeys: [.exa: "k-exa", .tavily: "k-tavily", .brave: "k-brave"]
        )

        let output = try await DesktopSearchEngine.execute(
            name: "search_web",
            input: #"{"query":"Kotlin Multiplatform"}"#,
            settings: settings,
            transport: { request in
                let host = request.url?.host ?? ""
                switch host {
                case "api.exa.ai":
                    let data = try JSONSerialization.data(withJSONObject: [
                        "results": [
                            [
                                "title": "Kotlin Multiplatform Docs",
                                "url": "https://kotlinlang.org/docs/multiplatform.html",
                                "highlights": ["Share code across iOS, Android, and Desktop."],
                                "image": "https://kotlinlang.org/assets/kmp-hero.png"
                            ],
                            [
                                "title": "Case Sensitive Wiki LaTeX",
                                "url": "https://en.wikipedia.org/wiki/LaTeX",
                                "highlights": ["Document preparation system."]
                            ]
                        ]
                    ])
                    return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)

                case "api.tavily.com":
                    let data = try JSONSerialization.data(withJSONObject: [
                        "results": [
                            [
                                "title": "Kotlin Multiplatform Docs",
                                "url": "http://www.kotlinlang.org/docs/multiplatform.html/",
                                "content": "Official JetBrains KMP guide with comprehensive targets.",
                                "images": [
                                    ["url": "https://kotlinlang.org/assets/kmp-architecture.png", "description": "KMP architecture diagram"]
                                ]
                            ],
                            [
                                "title": "Case Sensitive Wiki Latex",
                                "url": "https://en.wikipedia.org/wiki/Latex",
                                "content": "Natural rubber dispersion."
                            ]
                        ]
                    ])
                    return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)

                default:
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
                }
            }
        )

        XCTAssertEqual(output.executionMode, .parallel)
        XCTAssertEqual(output.results.count, 3)
        let mergedKMP = try XCTUnwrap(output.results.first { $0.url.contains("kotlinlang.org") })
        XCTAssertEqual(mergedKMP.sourceService, "Exa, Tavily")
        XCTAssertEqual(mergedKMP.images.count, 2, "Images from both Exa and Tavily on the same URL must be merged")
        XCTAssertTrue(output.fallbackReason?.contains("Brave") == true)
    }

    func testCancellationDoesNotTriggerFallback() async throws {
        let (settings, _, _) = makeSettings()
        try settings.saveConfiguration(
            enabledServices: [.exa, .free],
            executionMode: .sequentialFallback,
            resultCount: 5,
            apiKeys: [.exa: "k-exa"]
        )

        let freeCalled = LockedBox(false)
        do {
            _ = try await DesktopSearchEngine.execute(
                name: "search_web",
                input: #"{"query":"cancel test"}"#,
                settings: settings,
                transport: { _ in
                    throw CancellationError()
                },
                freeSearch: { _, _, _ in
                    freeCalled.value = true
                    return [DesktopSearchHit(title: "Fallback", url: "https://example.com", snippet: "Should not run")]
                }
            )
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            XCTAssertFalse(freeCalled.value, "Cancellation must propagate immediately without falling back to next source")
        }
    }

    func testScrapeWebPreservesRecipeJSONContractAndExtractsHeroImagesIntoMediaMetadata() async throws {
        let (settings, _, _) = makeSettings()
        let html = """
        <!doctype html>
        <html>
        <head>
          <title>Exa 2.0 Release Notes</title>
          <meta property="og:image" content="https://exa.ai/assets/exa-2-hero.png" />
          <meta name="twitter:image" content="https://exa.ai/assets/exa-2-card.png" />
        </head>
        <body>
          <article><p>Exa 2.0 introduces instant and deep-lite search modes.</p></article>
        </body>
        </html>
        """

        let output = try await DesktopSearchEngine.execute(
            name: "scrape_web",
            input: #"{"url":"https://exa.ai/blog/exa-2"}"#,
            settings: settings,
            transport: { request in
                let http = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                return (Data(html.utf8), http)
            }
        )

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertEqual(json["url"] as? String, "https://exa.ai/blog/exa-2")
        XCTAssertEqual(json["title"] as? String, "Exa 2.0 Release Notes")
        XCTAssertTrue((json["content"] as? String)?.contains("Exa 2.0 introduces instant") == true)
        XCTAssertEqual(json["images"] as? [String], [
            "https://exa.ai/assets/exa-2-hero.png",
            "https://exa.ai/assets/exa-2-card.png"
        ])

        let mediaMeta = try XCTUnwrap(output.mediaMetadataEntries)
        XCTAssertEqual(mediaMeta["app.amber.media.origin"], "search")
        let decodedImages = try JSONDecoder().decode([DesktopSearchImage].self, from: Data(try XCTUnwrap(mediaMeta["app.amber.media.images"]).utf8))
        XCTAssertEqual(decodedImages.count, 2)
        XCTAssertEqual(decodedImages[0].url, "https://exa.ai/assets/exa-2-hero.png")
        XCTAssertEqual(decodedImages[0].title, "Exa 2.0 Release Notes")
        XCTAssertEqual(decodedImages[0].sourceURL, "https://exa.ai/blog/exa-2")
    }

    func testSearchToolDeclarationsExposeValidJSONSchemaAndNetworkReadEffects() throws {
        let searchTools = ["search_web", "scrape_web", "exa_contents", "exa_answer", "exa_find_similar"]
        for name in searchTools {
            let decl = try XCTUnwrap(DesktopToolRegistry.declarations.first { $0.name == name }, "Missing declaration for \(name)")
            XCTAssertFalse(decl.needsApproval, "\(name) must be read-only without approval")
            XCTAssertEqual(DesktopToolRegistry.effect(for: name, arguments: "{}"), .networkRead)
            XCTAssertFalse(DesktopToolRegistry.isHighRisk(name))
            let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(decl.parametersJSON.utf8)) as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(schema["properties"] as? [String: Any])
        }
    }
}
