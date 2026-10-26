import XCTest
@testable import iosApp

@MainActor
final class IOSSearchNetworkRegressionTests: XCTestCase {
    override func setUp() async throws {
        IOSFreeSearchAggregator.resetCooldowns()
    }

    func testSatisfiedSmallResultLimitDoesNotStartGoogleFallback() async throws {
        let body = #"{"query":{"pages":[{"title":"One","index":1,"fullurl":"https://example.com/1","extract":"one"},{"title":"Two","index":2,"fullurl":"https://example.com/2","extract":"two"},{"title":"Three","index":3,"fullurl":"https://example.com/3","extract":"three"}]}}"#
        for limit in [1, 2, 3] {
            var fallbackCalls = 0
            let results = try await IOSFreeSearchAggregator.search(
                query: "swift", maxResults: limit, googleFallbackEnabled: true,
                transport: SearchNetworkMockTransport(wikipediaBody: body),
                googleFallback: { _, _ in
                    fallbackCalls += 1
                    return []
                }
            )
            XCTAssertEqual(results.count, limit)
            XCTAssertEqual(fallbackCalls, 0, "The requested result count is already satisfied")
        }
    }

    func testDedupePreservesPathAndQueryCaseWhileNormalizingHost() {
        let urls = [
            "https://EXAMPLE.com/Case?token=AB",
            "https://example.com/case?token=AB",
            "https://example.com/Case?token=ab",
            "https://example.com/Case?token=AB"
        ]
        let results = IOSFreeSearchAggregator.roundRobinMerge(
            [.bing: urls.map { IOSSearchResult(title: "Page", url: $0, snippet: "") }],
            order: [.bing], limit: 10
        )
        XCTAssertEqual(results.map(\.url), Array(urls.prefix(3)))
    }

    func testDedupeTrimsOnlyPathSeparatorsPreservingQueryAndFragmentSuffixes() {
        let urls = [
            "https://EXAMPLE.com/page/?next=/",
            "https://example.com/page?next=",
            "https://example.com/page?next=/",
            "https://example.com/page#section/",
            "https://example.com/page#section"
        ]
        let results = IOSFreeSearchAggregator.roundRobinMerge(
            [.bing: urls.map { IOSSearchResult(title: "Page", url: $0, snippet: "") }],
            order: [.bing], limit: 10
        )
        XCTAssertEqual(results.map(\.url), [urls[0], urls[1], urls[3], urls[4]])
    }

    func testCancelledFallbackCannotReturnSuccessfulAggregate() async throws {
        let enteredFallback = expectation(description: "Fallback started")
        let task = Task {
            try await IOSFreeSearchAggregator.search(
                query: "swift", maxResults: 5, googleFallbackEnabled: true,
                transport: SearchNetworkMockTransport(),
                googleFallback: { _, _ in
                    enteredFallback.fulfill()
                    let child = Task {
                        try await Task.sleep(for: .milliseconds(100))
                        return [IOSSearchResult(title: "Late", url: "https://example.com/late", snippet: "")]
                    }
                    return try await child.value
                }
            )
        }
        await fulfillment(of: [enteredFallback], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled search must not turn a late fallback into success")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testBraveHTMLDecodesEntitiesInResultURL() {
        let html = #"<div data-type="web"><a href="https://example.com/watch?v=ABC&amp;vl=en"><div class="title" title="Video">Video</div></a></div>"#
        let result = IOSFreeSearchAggregator.parseBraveHTML(html).first
        XCTAssertEqual(result?.url, "https://example.com/watch?v=ABC&vl=en")
    }

    func testDuckDuckGoFormPreservesLiteralPlusSigns() async throws {
        let transport = SearchNetworkMockTransport()
        _ = try await IOSFreeSearchAggregator.searchSingleEngineForTesting(
            .duckDuckGo, query: "C++ pointers", transport: transport
        )
        let request = try XCTUnwrap(transport.requests.first)
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(body, "q=C%2B%2B%20pointers&b=")
    }

    func testPublicTransportDNSCancellationAndTimeoutDoNotWaitForResolver() async {
        for shouldCancel in [true, false] {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            // Keep a regression failure finite even when the DNS waiter is broken.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release.signal() }
            defer { release.signal() }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SearchNetworkNoLoadingURLProtocol.self]
            let transport = IOSURLSessionSearchHTTPTransport(
                session: URLSession(configuration: configuration),
                resolveHost: { _ in
                    entered.signal()
                    release.wait()
                    return ["93.184.216.34"]
                }
            )
            var request = URLRequest(url: URL(string: "https://public.example/page")!)
            request.timeoutInterval = shouldCancel ? 30 : 0.2
            let started = Date()
            let task = Task { try await transport.sendPublic(request, maximumResponseBytes: 1_024) }
            let waitForEntry: @Sendable () -> Bool = { entered.wait(timeout: .now() + 1) == .success }
            let didEnter = await Task.detached { waitForEntry() }.value
            XCTAssertTrue(didEnter)
            if shouldCancel { task.cancel() }
            do {
                _ = try await task.value
                XCTFail("The DNS wait must end without waiting for the synchronous resolver")
            } catch {
                if shouldCancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        }
    }

    func testVerifiedPublicHTTPSUsesOneDeadlineAcrossBothDNSChecks() async {
        let resolver = SearchNetworkSlowPublicDNS()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchNetworkNoLoadingURLProtocol.self]
        let transport = IOSURLSessionSearchHTTPTransport(
            session: URLSession(configuration: configuration),
            resolveHost: { resolver.resolve($0) }
        )
        var request = URLRequest(url: URL(string: "https://public.example/page")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        let started = Date()
        do {
            _ = try await transport.sendVerifiedHTTPSGET(request, maximumResponseBytes: 1_024)
            XCTFail("Both DNS checks must share the original scrape deadline")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(resolver.calls, 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.6)
    }
}

private final class SearchNetworkSlowPublicDNS: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    func resolve(_ host: String) -> [String] {
        let call = lock.withLock {
            count += 1
            return count
        }
        Thread.sleep(forTimeInterval: call == 1 ? 1 : 4)
        return ["93.184.216.34"]
    }
}

@MainActor
private final class SearchNetworkMockTransport: IOSSearchHTTPTransport {
    private let wikipediaBody: String
    private(set) var requests: [URLRequest] = []

    init(wikipediaBody: String = "") {
        self.wikipediaBody = wikipediaBody
    }

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        requests.append(request)
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let body = url.host?.contains("wikipedia.org") == true ? wikipediaBody : ""
        return (response, Data(body.utf8))
    }
}

private final class SearchNetworkNoLoadingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.badURL)) }
    override func stopLoading() {}
}
