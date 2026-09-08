import Foundation
@preconcurrency import WebKit

enum IOSMiniAppBridgeDocumentPolicy {
    static func allowsMessage(
        isTrustedDocument: Bool,
        isMainFrame: Bool,
        frameURL: URL?,
        mainDocumentURL: URL?
    ) -> Bool {
        guard isTrustedDocument, isMainFrame, frameURL != nil || mainDocumentURL != nil else { return false }
        if let frameURL, !isInitialDocumentURL(frameURL) { return false }
        if let mainDocumentURL, !isInitialDocumentURL(mainDocumentURL) { return false }
        return true
    }

    private static func isInitialDocumentURL(_ url: URL?) -> Bool {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        components.fragment = nil
        return components.string?.caseInsensitiveCompare("about:blank") == .orderedSame
    }
}

/// WKScriptMessageHandler for the iOS MiniApp runner.
/// Dispatches into IOSMiniAppBridgeRuntime, which owns grants, audit, storage,
/// shared store, event bus, and honest errors for unavailable capabilities.
@MainActor
final class MiniAppBridge: NSObject, WKScriptMessageHandler {

    /// Logged bridge messages (for the dev UI). Bounded to avoid unbounded growth.
    private(set) var log: [String] = []
    private let sessionId: String
    private let runtime: IOSMiniAppBridgeRuntime
    private let onLogChanged: ([String]) -> Void
    private weak var webView: WKWebView?
    private var isClosed = false
    private var isTrustedMainDocument = false
    private var trustedDocumentGeneration: UInt64 = 0
    private var eventSubscriptionGenerations: [String: UInt64] = [:]
    private var sensorSubscriptionGenerations: [String: UInt64] = [:]

    private static let knownBridgeMethods: Set<String> = Set([
        "log", "echo", "app.info", "app.capabilities",
        "storage.get", "storage.set", "storage.remove", "toast",
        "host.getTheme", "theme", "clipboard.copy", "clipboard.read",
        "host.updateBoardSummary", "host.getConversationContext",
        "host.sendToConversation", "host.createArtifact", "sharedStore.get",
        "sharedStore.set", "sharedStore.remove", "eventBus.subscribe",
        "eventBus.unsubscribe", "eventBus.publish", "fetch", "search",
        "ai.generate", "launch", "location.getCurrent", "sensor.subscribe",
        "sensor.unsubscribe",
    ]).union(IOSMiniAppBridgeRuntime.systemMethods)

    init(
        runtime: IOSMiniAppBridgeRuntime,
        sessionId: String = UUID().uuidString,
        onLogChanged: @escaping ([String]) -> Void = { _ in }
    ) {
        self.sessionId = sessionId
        self.runtime = runtime
        self.onLogChanged = onLogChanged
        super.init()
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        runtime.setEventEmitter { [weak webView, weak self] type, subscriptionId, payload in
            self?.sendEvent(webView: webView, type: type, subscriptionId: subscriptionId, payload: payload)
        }
    }

    func setTrustedMainDocument(_ trusted: Bool) {
        if isTrustedMainDocument, !trusted {
            isTrustedMainDocument = false
            trustedDocumentGeneration &+= 1
            eventSubscriptionGenerations.removeAll()
            sensorSubscriptionGenerations.removeAll()
            runtime.cancelPendingRequests()
            return
        }
        guard isTrustedMainDocument != trusted else { return }
        isTrustedMainDocument = trusted
        trustedDocumentGeneration &+= 1
        if trusted {
            eventSubscriptionGenerations.removeAll()
            sensorSubscriptionGenerations.removeAll()
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        isTrustedMainDocument = false
        trustedDocumentGeneration &+= 1
        eventSubscriptionGenerations.removeAll()
        sensorSubscriptionGenerations.removeAll()
        webView = nil
        runtime.close()
    }

    /// WKScriptMessageHandler entry — called when the web page invokes
    /// `window.webkit.messageHandlers.amberNative.postMessage(...)`.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !isClosed else { return }
        guard IOSMiniAppBridgeDocumentPolicy.allowsMessage(
            isTrustedDocument: isTrustedMainDocument,
            isMainFrame: message.frameInfo.isMainFrame,
            frameURL: message.frameInfo.request.url,
            mainDocumentURL: message.webView?.url ?? webView?.url
        ) else {
            appendLog("Blocked bridge message from an untrusted document.")
            return
        }
        guard let raw = message.body as? String else { return }
        let documentGeneration = trustedDocumentGeneration
        let targetWebView = message.webView ?? webView
        Task { @MainActor in
            await self.handle(raw, webView: targetWebView, documentGeneration: documentGeneration)
        }
    }

    private func handle(
        _ raw: String,
        webView: WKWebView?,
        documentGeneration: UInt64
    ) async {
        guard isCurrentTrustedDocument(documentGeneration) else {
            appendLog("◀ postMessage: discarded stale document")
            return
        }
        // Parse defensively; a malformed request still gets an honest error
        // response (never swallowed silently).
        let parsed: [String: Any]? = (raw.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let request = parsed,
              let id = request["id"],
              let method = request["method"] as? String else {
            appendLog("◀ postMessage: invalid request")
            sendResponse(
                webView: webView,
                id: parsed?["id"] ?? NSNull(),
                error: "invalid request (need id+method)",
                method: "invalid",
                documentGeneration: documentGeneration
            )
            return
        }
        let logMethod = validatedMethodName(method)
        appendLog("◀ postMessage: \(logMethod)")
        if let params = request["params"], !(params is [String: Any]) {
            sendResponse(
                webView: webView,
                id: id,
                error: "invalid request (params must be an object)",
                method: logMethod,
                documentGeneration: documentGeneration
            )
            return
        }
        guard isCurrentTrustedDocument(documentGeneration) else {
            appendLog("◀ postMessage: discarded stale document")
            return
        }
        let params = request["params"] as? [String: Any] ?? [:]
        let result = await runtime.dispatch(method: method, params: params)
        guard isCurrentTrustedDocument(documentGeneration) else {
            appendLog("▶ onResponse: discarded stale document")
            return
        }
        rememberSubscription(
            method: method,
            params: params,
            result: result,
            documentGeneration: documentGeneration
        )
        sendResponse(
            webView: webView,
            id: id,
            result: result,
            method: logMethod,
            documentGeneration: documentGeneration
        )
    }

    private func sendResponse(
        webView: WKWebView?,
        id: Any,
        result: IOSMiniAppBridgeDispatchResult,
        method: String,
        documentGeneration: UInt64
    ) {
        guard isCurrentTrustedDocument(documentGeneration) else {
            appendLog("▶ onResponse: discarded stale document")
            return
        }
        var payload: [String: Any] = ["id": id]
        switch result {
        case .success(let value):
            payload["result"] = value.anyValue
        case .failure(let message):
            payload["error"] = message
        }
        payload["sessionId"] = sessionId
        guard let webView,
              let data = try? JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: payload)) as? [String: Any],
              let jsonString = stringValue(data) else { return }
        let status = result.errorMessage == nil ? "success" : "error"
        appendLog("▶ onResponse: \(method) \(status)")
        webView.evaluateJavaScript("""
        window.AmberBridge && window.AmberBridge._handleNativeResponse && window.AmberBridge._handleNativeResponse(\(jsonString));
        """)
    }

    private func sendResponse(
        webView: WKWebView?,
        id: Any,
        error: String,
        method: String,
        documentGeneration: UInt64
    ) {
        sendResponse(
            webView: webView,
            id: id,
            result: .failure(error),
            method: method,
            documentGeneration: documentGeneration
        )
    }

    private func sendEvent(webView: WKWebView?, type: String, subscriptionId: String?, payload: IOSMiniAppJSONValue) {
        guard isTrustedMainDocument,
              let subscriptionId,
              (type == "eventBus" && eventSubscriptionGenerations[subscriptionId] == trustedDocumentGeneration)
                || (type == "sensor" && sensorSubscriptionGenerations[subscriptionId] == trustedDocumentGeneration) else {
            appendLog("▶ event: discarded stale document")
            return
        }
        var event: [String: Any] = [
            "type": type,
            "payload": payload.anyValue,
        ]
        event["subscriptionId"] = subscriptionId
        guard let webView,
              let jsonString = stringValue(event) else { return }
        appendLog("▶ event: \(type) delivered")
        webView.evaluateJavaScript("""
        window.AmberBridge && window.AmberBridge._emitNativeEvent && window.AmberBridge._emitNativeEvent(\(jsonString));
        """)
    }

    private func isCurrentTrustedDocument(_ generation: UInt64) -> Bool {
        !isClosed && isTrustedMainDocument && trustedDocumentGeneration == generation
    }

    private func validatedMethodName(_ method: String) -> String {
        Self.knownBridgeMethods.contains(method) ? method : "unknown"
    }

    private func rememberSubscription(
        method: String,
        params: [String: Any],
        result: IOSMiniAppBridgeDispatchResult,
        documentGeneration: UInt64
    ) {
        guard isCurrentTrustedDocument(documentGeneration) else { return }
        switch method {
        case "eventBus.subscribe", "sensor.subscribe":
            guard case .success(let value) = result,
                  case .object(let object) = value,
                  let subscriptionValue = object["subscriptionId"],
                  case .string(let subscriptionId) = subscriptionValue else { return }
            if method == "eventBus.subscribe" {
                eventSubscriptionGenerations[subscriptionId] = documentGeneration
            } else {
                sensorSubscriptionGenerations[subscriptionId] = documentGeneration
            }
        case "eventBus.unsubscribe", "sensor.unsubscribe":
            guard case .success = result,
                  let subscriptionId = params["subscriptionId"] as? String else { return }
            eventSubscriptionGenerations.removeValue(forKey: subscriptionId)
            sensorSubscriptionGenerations.removeValue(forKey: subscriptionId)
        default:
            break
        }
    }

    private func appendLog(_ line: String) {
        guard !isClosed else { return }
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        onLogChanged(log)
    }

    /// Serialize a JSON object back to a string safe for evaluateJavaScript.
    private func stringValue(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
