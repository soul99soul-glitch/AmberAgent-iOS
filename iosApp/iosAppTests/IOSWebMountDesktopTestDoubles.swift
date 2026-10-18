import Foundation
import SwiftUI
import UIKit
import XCTest
import WebKit
@testable import iosApp

final class DesktopHostResolverGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let blockOnCall: Int
    private var callCount = 0
    private var started = false
    private var blocked = false

    init(blockOnCall: Int = 1) {
        self.blockOnCall = blockOnCall
    }

    var hasStarted: Bool {
        lock.withLock { started }
    }

    var hasBlocked: Bool {
        lock.withLock { blocked }
    }

    func resolve(_ host: String) throws -> [String] {
        let blocks = lock.withLock { () -> Bool in
            started = true
            callCount += 1
            if callCount == blockOnCall {
                blocked = true
                return true
            }
            return false
        }
        if blocks { semaphore.wait() }
        return ["93.184.216.34"]
    }

    func resume() {
        semaphore.signal()
    }
}

@MainActor
final class DesktopMcpClientFake: IOSMcpClienting {
    struct Call {
        let name: String
        let arguments: [String: Any]
    }

    let tools: [IOSMcpTool]
    let callError: Error?
    let callResult: String?
    var callResultsByTool: [String: String]
    var callResultQueuesByTool: [String: [String]]
    var suspendedToolName: String?
    private(set) var connectedConfigs: [IOSMcpServerConfig] = []
    private(set) var listToolsCallCount = 0
    private(set) var calls: [Call] = []
    private(set) var disconnectCallCount = 0
    private(set) var callContinuation: CheckedContinuation<Void, Never>?
    private var lastSemanticResult: String?

    init(
        tools: [IOSMcpTool],
        callError: Error? = nil,
        callResult: String? = nil,
        callResultsByTool: [String: String] = [:],
        callResultQueuesByTool: [String: [String]] = [:]
    ) {
        self.tools = tools
        self.callError = callError
        self.callResult = callResult
        self.callResultsByTool = callResultsByTool
        self.callResultQueuesByTool = callResultQueuesByTool
    }

    func connect(config: IOSMcpServerConfig) async throws -> Bool {
        connectedConfigs.append(config)
        return true
    }

    func listTools() async throws -> [IOSMcpTool] {
        listToolsCallCount += 1
        return tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        calls.append(Call(name: name, arguments: arguments))
        if suspendedToolName == name {
            await withCheckedContinuation { continuation in
                callContinuation = continuation
            }
        }
        if let callError { throw callError }
        if var queue = callResultQueuesByTool[name], !queue.isEmpty {
            let next = queue.removeFirst()
            callResultQueuesByTool[name] = queue
            return next
        }
        if let result = callResultsByTool[name] { return result }
        if let callResult { return callResult }
        if name == "browser_snapshot", let lastSemanticResult {
            return lastSemanticResult
        }
        if name == "browser_find", let text = arguments["text"] as? String {
            let node: [String: Any]
            switch text {
            case "Email":
                node = [
                    "ref": "wm:email",
                    "role": "textbox",
                    "name": "Email",
                    "input_type": "email",
                    "tag": "input",
                    "visible": true
                ]
            case "Focused Email":
                node = [
                    "ref": "wm:focused-email",
                    "role": "textbox",
                    "name": "Email",
                    "input_type": "email",
                    "tag": "input",
                    "visible": true,
                    "focused": true
                ]
            case "Password":
                node = [
                    "ref": "wm:password-field",
                    "role": "textbox",
                    "name": "Password",
                    "input_type": "password",
                    "tag": "input",
                    "visible": true
                ]
            case "OTP":
                node = [
                    "ref": "wm:otp",
                    "role": "textbox",
                    "name": "otp",
                    "input_type": "text",
                    "tag": "input",
                    "visible": true,
                    "focused": true
                ]
            case "Continue":
                node = ["ref": "wm:continue", "role": "button", "name": "Continue", "tag": "button", "visible": true]
            case "Visible":
                node = [
                    "ref": "wm:visible",
                    "role": "button",
                    "name": "Visible",
                    "tag": "button",
                    "visible": true
                ]
            case "Hidden":
                node = [
                    "ref": "wm:hidden",
                    "role": "textbox",
                    "name": "Hidden",
                    "input_type": "text",
                    "tag": "input",
                    "visible": false
                ]
            case "Opaque":
                node = ["ref": "wm:opaque"]
            default:
                node = ["ref": "wm:button", "role": "button", "name": text, "tag": "button", "visible": true]
            }
            let object: [String: Any] = [
                "ok": true,
                "contract_version": "webmount.semantic.v2",
                "document_id": "fake-document",
                "matches": [node]
            ]
            let data = try XCTUnwrap(JSONSerialization.data(withJSONObject: object, options: []))
            let result = try XCTUnwrap(String(data: data, encoding: .utf8))
            lastSemanticResult = result
            return result
        }
        return #"{"ok":true,"page":"desktop"}"#
    }

    func resumeCall() {
        callContinuation?.resume()
        callContinuation = nil
        suspendedToolName = nil
    }

    func disconnect() {
        disconnectCallCount += 1
    }
}

@MainActor
final class DesktopControllerRuntimeFake: IOSWebMountRuntimeServicing {
    var snapshot: IOSWebMountRuntimeSnapshot
    var webView: WKWebView? { nil }
    private(set) var openCallCount = 0
    private(set) var stateCallCount = 0
    private(set) var interactCallCount = 0

    init(sessionId: String) {
        snapshot = .idle(sessionId: sessionId)
    }

    func open(_ url: URL, timeoutMillis: UInt64) async -> IOSWebMountRuntimeSnapshot {
        openCallCount += 1
        return snapshot
    }

    func state() async throws -> [String: Any] {
        stateCallCount += 1
        return [:]
    }

    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any] { [:] }

    func get(
        selector: String?,
        target: String?,
        kind: String,
        attrName: String?,
        maxChars: Int
    ) async throws -> [String: Any] { [:] }

    func interact(
        method: String,
        selector: String?,
        text: String?,
        options: [String: Any]
    ) async throws -> [String: Any] {
        interactCallCount += 1
        return ["ok": true]
    }

    func screenshot() async throws -> IOSWebMountScreenshotCapture {
        IOSWebMountScreenshotCapture(data: Data(), width: 0, height: 0, format: "png")
    }

    func back() async -> IOSWebMountRuntimeSnapshot { snapshot }
    func forward() async -> IOSWebMountRuntimeSnapshot { snapshot }
}

@MainActor
final class DesktopTestCookieStore: IOSWebMountCookieStoreProtocol {
    func summary(for site: IOSWebMountSite) async -> IOSWebMountCookieSummary {
        IOSWebMountCookieSummary(
            siteId: site.id,
            cookieCount: 0,
            cookieNames: [],
            domains: [],
            hasLoginCookie: nil,
            redacted: true
        )
    }

    func clearSession(for site: IOSWebMountSite) async -> IOSWebMountCookieClearResult {
        IOSWebMountCookieClearResult(siteId: site.id, deletedCookieCount: 0, clearedWebsiteDataRecords: 0)
    }
}
