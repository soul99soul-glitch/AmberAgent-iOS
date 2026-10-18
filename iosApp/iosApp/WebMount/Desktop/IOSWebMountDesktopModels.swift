import Foundation
import Observation
import WebKit


enum IOSWebMountBackendKind: String, Codable, CaseIterable, Identifiable {
    case local
    case moli
    case playwright_mcp
    case steel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local:
            IOSAppLocalization.string("本地 WKWebView", defaultValue: "本地 WKWebView")
        case .moli:
            IOSAppLocalization.string("Moli", defaultValue: "Moli")
        case .playwright_mcp:
            IOSAppLocalization.string("Playwright MCP", defaultValue: "Playwright MCP")
        case .steel:
            IOSAppLocalization.string("Steel", defaultValue: "Steel")
        }
    }
}

enum IOSWebMountDesktopEndpointPolicyError: Error, Equatable, LocalizedError {
    case disabled
    case unsupportedTransport
    case invalidURL
    case httpsRequired
    case missingHost
    case userInfoNotAllowed
    case loopbackHost

    var errorDescription: String? {
        switch self {
        case .disabled: "Desktop WebMount MCP server is disabled."
        case .unsupportedTransport: "Desktop WebMount requires Streamable HTTP."
        case .invalidURL: "Desktop WebMount endpoint is invalid."
        case .httpsRequired: "Desktop WebMount endpoint must use HTTPS."
        case .missingHost: "Desktop WebMount endpoint has no host."
        case .userInfoNotAllowed: "Desktop WebMount endpoint must not contain URL userinfo."
        case .loopbackHost: "A mobile device cannot reach a desktop through localhost or loopback."
        }
    }
}

struct IOSWebMountDesktopEndpointPolicy {
    func validate(_ config: IOSMcpServerConfig) throws -> URL {
        guard config.enabled else { throw IOSWebMountDesktopEndpointPolicyError.disabled }
        guard case .streamableHTTP = config else {
            throw IOSWebMountDesktopEndpointPolicyError.unsupportedTransport
        }
        guard let components = URLComponents(
            string: config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        ), let url = components.url else {
            throw IOSWebMountDesktopEndpointPolicyError.invalidURL
        }
        guard components.scheme?.lowercased() == "https" else {
            throw IOSWebMountDesktopEndpointPolicyError.httpsRequired
        }
        guard let host = components.host?.lowercased().nilIfBlank else {
            throw IOSWebMountDesktopEndpointPolicyError.missingHost
        }
        guard components.user == nil, components.password == nil else {
            throw IOSWebMountDesktopEndpointPolicyError.userInfoNotAllowed
        }
        guard !Self.isLoopback(host) else {
            throw IOSWebMountDesktopEndpointPolicyError.loopbackHost
        }
        return url
    }

    private static func isLoopback(_ rawHost: String) -> Bool {
        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
            .lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" {
            return true
        }
        if host.hasPrefix("127.") || host == "0.0.0.0" || host == "::" {
            return true
        }
        if host.hasPrefix("::ffff:") {
            return isLoopback(String(host.dropFirst(7)))
        }
        return false
    }
}

enum IOSWebMountDesktopBackendStatus: Equatable {
    case idle
    case connecting
    case connected
    case needsReopen
    case failed(String)
    case closed

    var code: String {
        switch self {
        case .idle: "idle"
        case .connecting: "connecting"
        case .connected: "connected"
        case .needsReopen: "needs_reopen"
        case .failed: "failed"
        case .closed: "closed"
        }
    }

    var title: String {
        switch self {
        case .idle:
            IOSAppLocalization.string("未连接", defaultValue: "未连接")
        case .connecting:
            IOSAppLocalization.string("连接中", defaultValue: "连接中")
        case .connected:
            IOSAppLocalization.string("已连接", defaultValue: "已连接")
        case .needsReopen:
            IOSAppLocalization.string("需要重新连接", defaultValue: "需要重新连接")
        case .failed:
            IOSAppLocalization.string("连接失败", defaultValue: "连接失败")
        case .closed:
            IOSAppLocalization.string("已关闭", defaultValue: "已关闭")
        }
    }
}

struct IOSWebMountDesktopCapability: Equatable, Identifiable {
    let amberToolName: String
    let remoteToolName: String
    let available: Bool

    var id: String { amberToolName }
}

enum IOSWebMountDesktopBackendError: Error, Equatable, LocalizedError {
    case localBackend
    case missingConfiguration
    case invalidArguments(String)
    case mappingUnsupported(String)
    case unsafeBrowserTool(String)
    case gatewayToolMissing(String)
    case minimumCapabilitiesMissing
    case notConnected(String)
    case sensitiveFieldRequiresHuman
    case staleSnapshot
    case controlUnavailable

    var errorCode: String {
        switch self {
        case .localBackend: "invalid_backend"
        case .missingConfiguration: "desktop_backend_not_configured"
        case .invalidArguments: "invalid_arguments"
        case .mappingUnsupported: "mapping_unsupported"
        case .unsafeBrowserTool: "unsafe_tool_blocked"
        case .gatewayToolMissing, .minimumCapabilitiesMissing: "desktop_gateway_tool_missing"
        case .notConnected: "desktop_gateway_unavailable"
        case .sensitiveFieldRequiresHuman: "sensitive_field_requires_human"
        case .staleSnapshot: "stale_snapshot"
        case .controlUnavailable: "control_unavailable"
        }
    }

    var errorDescription: String? {
        switch self {
        case .localBackend: "The local backend does not use the desktop MCP adapter."
        case .missingConfiguration: "Desktop WebMount has no MCP server configuration."
        case .invalidArguments(let message): message
        case .mappingUnsupported(let tool): "No safe desktop mapping exists for \(tool)."
        case .unsafeBrowserTool(let tool): "Unsafe browser tool is blocked: \(tool)."
        case .gatewayToolMissing(let tool): "Desktop gateway did not advertise \(tool)."
        case .minimumCapabilitiesMissing: "Desktop gateway must advertise browser_navigate and browser_snapshot."
        case .notConnected: "Desktop WebMount session is not connected."
        case .sensitiveFieldRequiresHuman: "Sensitive fields stay in local, user-controlled WebMount."
        case .staleSnapshot: "Observe the page again before mutating this desktop session."
        case .controlUnavailable: "WebMount control changed before the desktop action was dispatched."
        }
    }
}

enum IOSWebMountRemoteRuntimeError: Error, LocalizedError {
    case localOperationUnavailable

    var errorDescription: String? {
        "This logical desktop session has no local WKWebView."
    }
}

@MainActor
final class IOSWebMountRemotePlaceholderRuntime: IOSWebMountRuntimeServicing {
    let webView: WKWebView? = nil
    private(set) var snapshot: IOSWebMountRuntimeSnapshot

    init(sessionId: String? = nil) {
        let resolved = sessionId?.nilIfBlank ?? "ios_remote_" + String(UUID().uuidString.prefix(8))
        snapshot = .idle(sessionId: resolved)
    }

    func apply(resultText: String, toolName: String, requestedURL: String? = nil) {
        let object = resultText.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let ok = object?["ok"] as? Bool == true
        snapshot.status = ok ? .ready : .failed
        if let requestedURL {
            snapshot.requestedURL = IOSWebMountRedactor.redactedURL(requestedURL)
        }
        if ok {
            snapshot.currentURL = IOSWebMountRedactor.redactedURL(object?["current_url"] as? String)
                ?? snapshot.requestedURL
        }
        snapshot.title = ok ? "Desktop · \(toolName)" : snapshot.title
        snapshot.error = ok ? nil : IOSWebMountRedactor.redactedText(object?["error"] as? String ?? "Desktop gateway failed")
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
    }

    func open(_ url: URL, timeoutMillis: UInt64) async -> IOSWebMountRuntimeSnapshot {
        snapshot.status = .failed
        snapshot.error = IOSWebMountRemoteRuntimeError.localOperationUnavailable.localizedDescription
        return snapshot
    }

    func state() async throws -> [String: Any] { throw IOSWebMountRemoteRuntimeError.localOperationUnavailable }
    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any] { throw IOSWebMountRemoteRuntimeError.localOperationUnavailable }
    func get(selector: String?, target: String?, kind: String, attrName: String?, maxChars: Int) async throws -> [String: Any] { throw IOSWebMountRemoteRuntimeError.localOperationUnavailable }
    func interact(method: String, selector: String?, text: String?, options: [String: Any]) async throws -> [String: Any] { throw IOSWebMountRemoteRuntimeError.localOperationUnavailable }
    func screenshot() async throws -> IOSWebMountScreenshotCapture { throw IOSWebMountRemoteRuntimeError.localOperationUnavailable }
    func back() async -> IOSWebMountRuntimeSnapshot { await open(URL(string: "about:blank")!, timeoutMillis: 0) }
    func forward() async -> IOSWebMountRuntimeSnapshot { await open(URL(string: "about:blank")!, timeoutMillis: 0) }
}
