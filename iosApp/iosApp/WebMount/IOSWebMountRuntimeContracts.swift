import Foundation
import Darwin
import CryptoKit
import Combine
import Observation
import OSLog
import WebKit
#if canImport(UIKit)
import UIKit
#endif

struct IOSWebMountRuntimeSnapshot: Codable, Equatable, Sendable {
    let sessionId: String
    var status: IOSWebMountRuntimeStatus
    var requestedURL: String?
    var currentURL: String?
    var title: String?
    var estimatedProgress: Double
    var canGoBack: Bool
    var canGoForward: Bool
    var error: String?
    var updatedAtMillis: Int64

    static func idle(sessionId: String) -> IOSWebMountRuntimeSnapshot {
        IOSWebMountRuntimeSnapshot(
            sessionId: sessionId,
            status: .idle,
            requestedURL: nil,
            currentURL: nil,
            title: nil,
            estimatedProgress: 0,
            canGoBack: false,
            canGoForward: false,
            error: nil,
            updatedAtMillis: 0
        )
    }
}

struct IOSWebMountScreenshotCapture: Equatable {
    let data: Data
    let width: Int
    let height: Int
    let format: String
}

typealias IOSWebMountVisualReadHandler = @MainActor (IOSWebMountScreenshotCapture, String) async throws -> String

@MainActor
protocol IOSWebMountRuntimeServicing: AnyObject {
    var snapshot: IOSWebMountRuntimeSnapshot { get }
    var webView: WKWebView? { get }
    func open(_ url: URL, timeoutMillis: UInt64) async -> IOSWebMountRuntimeSnapshot
    func state() async throws -> [String: Any]
    func observe(maxChars: Int, maxLinks: Int) async throws -> [String: Any]
    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any]
    func get(selector: String?, target: String?, kind: String, attrName: String?, maxChars: Int) async throws -> [String: Any]
    func interact(method: String, selector: String?, text: String?, options: [String: Any]) async throws -> [String: Any]
    func screenshot() async throws -> IOSWebMountScreenshotCapture
    func back() async -> IOSWebMountRuntimeSnapshot
    func forward() async -> IOSWebMountRuntimeSnapshot
}

extension IOSWebMountRuntimeServicing {
    func observe(maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        let page = try await state()
        let readable = try await extract(mode: "readable", maxChars: maxChars, maxLinks: maxLinks)
        let interactive = try await extract(mode: "interactive", maxChars: 0, maxLinks: 80)
        let visual = try await extract(mode: "snapshot", maxChars: 0, maxLinks: 80)
        return [
            "observation_consistency": "legacy_multi_read",
            "document_id": interactive["document_id"] ?? page["document_id"] ?? "",
            "page_revision": interactive["page_revision"] ?? page["page_revision"] ?? 0,
            "dom_revision": interactive["dom_revision"] ?? page["dom_revision"] ?? 0,
            "url_revision": interactive["url_revision"] ?? page["url_revision"] ?? 0,
            "snapshot_id": interactive["snapshot_id"] ?? page["snapshot_id"] ?? "",
            "page": page,
            "visible_text": readable["text"] ?? "",
            "links": readable["links"] ?? [],
            "interactive_elements": interactive["nodes"] ?? [],
            "visual_candidates": visual["visual_candidates"] ?? []
        ]
    }
}

@MainActor
struct IOSWebMountBrowserDialog: Identifiable {
    enum Kind { case alert, confirm, prompt }
    let id = UUID()
    let kind: Kind
    let message: String
    let host: String
    let defaultText: String
}

extension IOSWebMountRuntimeSnapshot {
    func dictionary(redactURLs: Bool) -> [String: Any] {
        [
            "session_id": sessionId,
            "status": status.rawValue,
            "requested_url": redactURLs ? (IOSWebMountRedactor.redactedURL(requestedURL) ?? "") : (requestedURL ?? ""),
            "current_url": redactURLs ? (IOSWebMountRedactor.redactedURL(currentURL) ?? "") : (currentURL ?? ""),
            "title": redactURLs ? IOSWebMountRedactor.redactedText(title ?? "") : (title ?? ""),
            "estimated_progress": estimatedProgress,
            "can_go_back": canGoBack,
            "can_go_forward": canGoForward,
            "error": redactURLs ? IOSWebMountRedactor.redactedText(error ?? "") : (error ?? ""),
            "updated_at_ms": updatedAtMillis
        ]
    }
}

