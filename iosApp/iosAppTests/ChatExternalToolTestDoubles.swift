import XCTest
import WebKit
@preconcurrency import Shared
@testable import iosApp

final class ChatSearchTransport: IOSSearchHTTPTransport {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data

        static func html(_ body: String, status: Int = 200) -> Response {
            Response(
                status: status,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: Data(body.utf8)
            )
        }
    }

    private var responses: [Response]
    private let hostResponses: [String: Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [Response], hostResponses: [String: Response] = [:]) {
        self.responses = responses
        self.hostResponses = hostResponses
    }

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        requests.append(request)
        let response = request.url?.host.flatMap { hostResponses[$0] }
            ?? (responses.isEmpty ? .html("") : responses.removeFirst())
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        return (http, response.body)
    }
}

@MainActor
final class BlockingChatSearchTransport: IOSSearchHTTPTransport {
    private let response: ChatSearchTransport.Response
    private var didStartRequest = false
    private var requestStartedContinuation: CheckedContinuation<Void, Never>?
    private var responseContinuation: CheckedContinuation<(HTTPURLResponse, Data), Error>?
    private(set) var requests: [URLRequest] = []

    init(response: ChatSearchTransport.Response) {
        self.response = response
    }

    func waitUntilRequestStarted() async {
        guard !didStartRequest else { return }
        await withCheckedContinuation { continuation in
            requestStartedContinuation = continuation
        }
    }

    func complete() {
        guard let continuation = responseContinuation else { return }
        responseContinuation = nil
        let requestURL = requests.last?.url ?? URL(string: "https://example.com")!
        let http = HTTPURLResponse(
            url: requestURL,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        continuation.resume(returning: (http, response.body))
    }

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        requests.append(request)
        didStartRequest = true
        requestStartedContinuation?.resume()
        requestStartedContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
        }
    }
}

@MainActor
final class CancellingChatSearchTransport: IOSSearchHTTPTransport {
    private var didStartRequest = false
    private var requestStartedContinuation: CheckedContinuation<Void, Never>?
    private var responseContinuation: CheckedContinuation<(HTTPURLResponse, Data), Error>?
    private(set) var requests: [URLRequest] = []

    func waitUntilRequestStarted() async {
        guard !didStartRequest else { return }
        await withCheckedContinuation { continuation in
            requestStartedContinuation = continuation
        }
    }

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        requests.append(request)
        if requests.count > 1 {
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data("<html><body></body></html>".utf8))
        }

        didStartRequest = true
        requestStartedContinuation?.resume()
        requestStartedContinuation = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                responseContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelFirstRequest()
            }
        }
    }

    private func cancelFirstRequest() {
        guard let continuation = responseContinuation else { return }
        responseContinuation = nil
        continuation.resume(throwing: CancellationError())
    }
}

@MainActor
final class ChatWebMountCookieStore: IOSWebMountCookieStoreProtocol {
    var clearedSiteIds: [String] = []

    func summary(for site: IOSWebMountSite) async -> IOSWebMountCookieSummary {
        IOSWebMountCookieSummary(
            siteId: site.id,
            cookieCount: site.id == "github" ? 1 : 0,
            cookieNames: site.id == "github" ? ["user_session"] : [],
            domains: site.id == "github" ? ["github.com"] : [],
            hasLoginCookie: site.loginCookieName.map { $0 == "user_session" },
            redacted: true
        )
    }

    func clearSession(for site: IOSWebMountSite) async -> IOSWebMountCookieClearResult {
        clearedSiteIds.append(site.id)
        return IOSWebMountCookieClearResult(
            siteId: site.id,
            deletedCookieCount: 1,
            clearedWebsiteDataRecords: 1
        )
    }
}

@MainActor
final class ChatWebMountRuntime: IOSWebMountRuntimeServicing {
    var snapshot = IOSWebMountRuntimeSnapshot.idle(sessionId: "chat-test")
    var webView: WKWebView? { nil }

    func open(_ url: URL, timeoutMillis: UInt64) async -> IOSWebMountRuntimeSnapshot {
        snapshot = IOSWebMountRuntimeSnapshot(
            sessionId: "chat-test",
            status: .ready,
            requestedURL: IOSWebMountRedactor.redactedURL(url.absoluteString),
            currentURL: IOSWebMountRedactor.redactedURL(url.absoluteString),
            title: "Chat Test",
            estimatedProgress: 1,
            canGoBack: false,
            canGoForward: false,
            error: nil,
            updatedAtMillis: 123
        )
        return snapshot
    }

    func state() async throws -> [String: Any] {
        ["title": "Chat Test"]
    }

    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        ["mode": mode, "text": "Chat Test"]
    }

    func get(
        selector: String?,
        target: String?,
        kind: String,
        attrName: String?,
        maxChars: Int
    ) async throws -> [String: Any] {
        ["ok": true, "selector": selector ?? target ?? "body", "kind": kind, "value": "Chat Test"]
    }

    func interact(method: String, selector: String?, text: String?, options: [String: Any]) async throws -> [String: Any] {
        ["ok": true, "method": method, "found": true, "message": "mock interaction"]
    }

    func screenshot() async throws -> IOSWebMountScreenshotCapture {
        IOSWebMountScreenshotCapture(data: Data([0x89, 0x50, 0x4E, 0x47]), width: 320, height: 640, format: "png")
    }

    func back() async -> IOSWebMountRuntimeSnapshot {
        snapshot
    }

    func forward() async -> IOSWebMountRuntimeSnapshot {
        snapshot
    }
}
