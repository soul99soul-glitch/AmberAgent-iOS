import XCTest
import UIKit
import WebKit
import Shared
@testable import iosApp

@MainActor
final class MockWebMountCookieStore: IOSWebMountCookieStoreProtocol {
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
final class MockWebMountRuntime: IOSWebMountRuntimeServicing {
    private static var nextId = 0

    /// Reset the shared session-id counter so each test starts from a known
    /// base. Without this a stale counter shifts the mock ids across tests,
    /// which made `testWebMountTabLifecycleAndClosedSessionFailure` pass in
    /// isolation but fail in the full suite (order-dependent test pollution).
    static func resetSessionCounter() { nextId = 0 }

    var snapshot: IOSWebMountRuntimeSnapshot
    var webView: WKWebView? { nil }
    var openedURLs: [URL] = []
    var lastInteraction: (method: String, selector: String?, text: String?, options: [String: Any])?
    var pageRevision = 0
    var waitMatched = false
    private(set) var observeCallCount = 0
    private(set) var interactionCallCount = 0
    var openResultOverride: IOSWebMountRuntimeSnapshot?
    var suspendsInteraction = false
    var suspendedInteractionMethod: String?
    private(set) var interactionContinuation: CheckedContinuation<Void, Never>?
    var suspendsBack = false
    private(set) var navigationContinuation: CheckedContinuation<Void, Never>?
    /// 文档身份（真实桥 state 返回 document_id）：测试内翻转它可模拟导航。
    var documentId = "mock-document"
    /// interact 结果覆盖钩子：返回非 nil 即用该结果（find 匹配表、导航副作用等）。
    var interactResultProvider: ((String, String?, String?, [String: Any]) -> [String: Any]?)?

    init(sessionId: String? = nil) {
        if let sessionId {
            snapshot = IOSWebMountRuntimeSnapshot.idle(sessionId: sessionId)
        } else {
            Self.nextId += 1
            snapshot = IOSWebMountRuntimeSnapshot.idle(sessionId: "mock-\(Self.nextId)")
        }
    }

    func open(_ url: URL, timeoutMillis: UInt64) async -> IOSWebMountRuntimeSnapshot {
        openedURLs.append(url)
        if let openResultOverride {
            snapshot = openResultOverride
            return snapshot
        }
        snapshot = IOSWebMountRuntimeSnapshot(
            sessionId: snapshot.sessionId,
            status: .ready,
            requestedURL: IOSWebMountRedactor.redactedURL(url.absoluteString),
            currentURL: IOSWebMountRedactor.redactedURL(url.absoluteString),
            title: "Mock Page",
            estimatedProgress: 1,
            canGoBack: openedURLs.count > 1,
            canGoForward: false,
            error: nil,
            updatedAtMillis: 123
        )
        return snapshot
    }

    func state() async throws -> [String: Any] {
        [
            "url": "https://github.com/login?token=secret",
            "title": "Mock Page",
            "ready_state": "complete",
            "document_id": documentId,
            "page_revision": pageRevision,
            "url_revision": documentId == "mock-document" ? 0 : 1,
            "dom_revision": 0,
            "snapshot_id": "\(documentId):\(pageRevision)"
        ]
    }

    func observe(maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        observeCallCount += 1
        return [
            "document_id": "mock-document",
            "page_revision": pageRevision,
            "snapshot_id": "mock-document:\(pageRevision)",
            "page": try await state(),
            "visible_text": "Hello from mock",
            "interactive_elements": [
                ["ref": "css:button", "tag": "button", "text": "Sign in"]
            ],
            "visual_candidates": [
                ["ref": "css:img", "tag": "img", "alt": "Logo", "rect": ["width": 120, "height": 40]]
            ],
            "links": [
                ["href": "https://github.com/settings?token=secret", "text": "settings"]
            ]
        ]
    }

    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        [
            "mode": mode,
            "text": "Hello from mock",
            "nodes": [
                ["ref": "css:button", "tag": "button", "text": "Sign in"]
            ],
            "visual_candidates": [
                ["ref": "css:img", "tag": "img", "alt": "Logo", "rect": ["width": 120, "height": 40]]
            ],
            "links": [
                ["href": "https://github.com/settings?token=secret", "text": "settings"]
            ]
        ]
    }

    func get(selector: String?, target: String?, kind: String, attrName: String?, maxChars: Int) async throws -> [String: Any] {
        [
            "ok": true,
            "selector": selector ?? target ?? "body",
            "kind": kind,
            "value": "Hello from mock"
        ]
    }

    func interact(method: String, selector: String?, text: String?, options: [String: Any]) async throws -> [String: Any] {
        interactionCallCount += 1
        lastInteraction = (method, selector, text, options)
        if suspendsInteraction,
           (suspendedInteractionMethod == nil || suspendedInteractionMethod == method),
           options["_amber_postcondition_probe"] as? Bool != true {
            await withCheckedContinuation { continuation in
                interactionContinuation = continuation
            }
        }
        if method != "find" && method != "wait" {
            pageRevision += 1
        }
        if let override = interactResultProvider?(method, selector, text, options) {
            return override
        }
        var result: [String: Any] = [
            "ok": true,
            "method": method,
            "found": true,
            "snapshot_id": "\(documentId):\(pageRevision)"
        ]
        if method == "wait" { result["matched"] = waitMatched }
        return result
    }

    func resumeInteraction() {
        interactionContinuation?.resume()
        interactionContinuation = nil
        suspendsInteraction = false
        suspendedInteractionMethod = nil
    }

    func screenshot() async throws -> IOSWebMountScreenshotCapture {
        IOSWebMountScreenshotCapture(data: Data([0x89, 0x50, 0x4E, 0x47]), width: 390, height: 844, format: "png")
    }

    func back() async -> IOSWebMountRuntimeSnapshot {
        if suspendsBack {
            await withCheckedContinuation { continuation in
                navigationContinuation = continuation
            }
        }
        snapshot.status = .ready
        return snapshot
    }

    func resumeNavigation() {
        navigationContinuation?.resume()
        navigationContinuation = nil
        suspendsBack = false
    }

    func forward() async -> IOSWebMountRuntimeSnapshot {
        snapshot.status = .ready
        return snapshot
    }
}
