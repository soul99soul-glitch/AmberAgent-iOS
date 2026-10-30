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

@MainActor
final class IOSWebMountWKRuntime: NSObject, ObservableObject, IOSWebMountRuntimeServicing, WKNavigationDelegate, WKUIDelegate {
    static let automationContentWorld = WKContentWorld.world(name: "app.amber.webmount.automation")

    /// 未挂载时的视口：取当前前台窗口场景的屏幕（iPhone Duo 内外屏不同），
    /// 不用 `UIScreen.main`——双屏设备上它不代表 App 所在的屏幕。
    private static var detachedViewportFrame: CGRect {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.effectiveGeometry.coordinateSpace.bounds
            ?? CGRect(x: 0, y: 0, width: 402, height: 874)
    }

    private var webViewStorage: WKWebView?
    var webView: WKWebView? {
        if let webViewStorage { return webViewStorage }
        guard !isClosed else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Agent-owned sessions can stay detached from SwiftUI's foreground layout.
        // Give those sessions a real viewport; a mounted view will replace this
        // frame through its normal layout pass.
        let webView = WKWebView(frame: Self.detachedViewportFrame, configuration: configuration)
        webViewStorage = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, let webView = self.webViewStorage else { return }
                if let target = self.fragmentNavigationTarget,
                   let pendingLoad = self.pendingLoad,
                   self.verifiedFragmentLoadId == pendingLoad.id,
                   webView.url == target {
                    self.finishNavigation(webView)
                } else if self.snapshot.status == .ready,
                          let currentURL = self.snapshot.currentURL.flatMap(URL.init(string:)),
                          let url = webView.url,
                          let origin = Self.navigationDestinationKey(currentURL),
                          origin == Self.navigationDestinationKey(url) {
                    // History API and hash changes stay within the loaded origin
                    // and may not trigger didCommit/didFinish.
                    self.snapshot.currentURL = IOSWebMountRedactor.redactedURL(url.absoluteString)
                    self.snapshot.canGoBack = webView.canGoBack
                    self.snapshot.canGoForward = webView.canGoForward
                    self.snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
                }
            }
        }
        return webView
    }
    @Published private(set) var snapshot: IOSWebMountRuntimeSnapshot
    @Published private(set) var popupWebViews: [WKWebView] = []
    @Published private(set) var popupNavigationRevision = 0
    @Published private(set) var browserDialog: IOSWebMountBrowserDialog?
    @Published var browserNotice: String?
    private var browserDialogCompletion: ((String?) -> Void)?
    private weak var browserDialogWebView: WKWebView?
    private var browserPresentationHosts: Set<UUID> = []
    private var isClosed = false
    private var popupApprovedDestinations: [ObjectIdentifier: String] = [:]
    private var popupPolicyRevision = 0

    private var loadSequence = 0
    private var pendingLoad: (id: Int, continuation: CheckedContinuation<IOSWebMountRuntimeSnapshot, Never>)?
    private var pendingLoadTimeoutTask: Task<Void, Never>?
    private var navigationPolicy: IOSWebMountURLPolicy?
    private(set) var userBrowsingEnabled = false
    private var effectiveNavigationPolicy: IOSWebMountURLPolicy? {
        userBrowsingEnabled ? navigationPolicy?.allowingPublicUserNavigation() : navigationPolicy
    }

    func setUserBrowsingEnabled(_ enabled: Bool) {
        guard !isClosed || !enabled else { return }
        guard userBrowsingEnabled != enabled else { return }
        userBrowsingEnabled = enabled
        invalidateNavigationDecisions()
        if !enabled {
            cancelBrowserPresentation()
            for popup in popupWebViews { closePopup(popup) }
        }
    }

    func invalidateNavigationDecisions() {
        navigationDecisionSequence += 1
        popupPolicyRevision += 1
        popupApprovedDestinations.removeAll()
        approvedMainFrameDestination = nil
    }

    func closeSession() {
        isClosed = true
        setUserBrowsingEnabled(false)
        invalidateNavigationDecisions()
        browserPresentationHosts.removeAll()
        cancelBrowserPresentation()
        for popup in popupWebViews { closePopup(popup) }
        webViewStorage?.stopLoading()
        webViewStorage?.isUserInteractionEnabled = false
        snapshot.status = .failed
        snapshot.error = "站点会话已关闭。"
        completePendingLoad()
    }

    private var navigationSite: IOSWebMountSite?
    private var navigationHostResolver: IOSWebMountHostResolver = IOSPublicURLPolicy.resolveIPAddresses
    private var navigationDecisionSequence = 0
    private var approvedMainFrameDestination: String?
    private var fragmentNavigationTarget: URL?
    private var verifiedFragmentLoadId: Int?
    private var urlObservation: NSKeyValueObservation?
    private var subframeNavigationDenialCount = 0
    private var lastSubframeNavigationDenial: [String: Any]?
    private static let maxNavigationEvents = 8
    private var navigationEvents: [[String: Any]] = []

    override convenience init() {
        self.init(sessionId: nil)
    }

    init(sessionId: String?) {
        let resolvedSessionId = sessionId?.nilIfBlank
            ?? "ios_wm_" + String(UUID().uuidString.prefix(8))
        self.snapshot = .idle(sessionId: resolvedSessionId)
        super.init()
    }

    func setNavigationPolicy(
        _ policy: IOSWebMountURLPolicy,
        site: IOSWebMountSite?,
        resolveHost: @escaping IOSWebMountHostResolver = IOSPublicURLPolicy.resolveIPAddresses
    ) {
        let policyChanged = navigationPolicy?.allowedSchemes != policy.allowedSchemes
            || navigationPolicy?.allowedHosts != policy.allowedHosts
            || navigationPolicy?.allowUnlistedHosts != policy.allowUnlistedHosts
            || navigationPolicy?.allowFakeIPFallback != policy.allowFakeIPFallback
            || navigationSite != site
        navigationPolicy = policy
        navigationSite = site
        navigationHostResolver = resolveHost
        navigationDecisionSequence += 1
        approvedMainFrameDestination = nil
        if policyChanged {
            invalidateNavigationDecisions()
            resetNavigationDiagnostics()
        }
    }

    func open(_ url: URL, timeoutMillis: UInt64 = 30_000) async -> IOSWebMountRuntimeSnapshot {
        guard !isClosed else { return snapshot }
        guard let webView else {
            snapshot.status = .failed
            snapshot.error = "WKWebView is unavailable"
            return snapshot
        }
        cancelBrowserPresentation()
        for popup in popupWebViews { closePopup(popup) }
        browserNotice = nil
        pendingLoadTimeoutTask?.cancel()
        pendingLoadTimeoutTask = nil
        loadSequence += 1
        let loadId = loadSequence
        pendingLoad?.continuation.resume(returning: snapshot)
        pendingLoad = nil
        fragmentNavigationTarget = nil
        verifiedFragmentLoadId = nil
        if !webView.isLoading, let currentURL = webView.url,
           currentURL != url || url.fragment != nil,
           var currentDocument = URLComponents(url: currentURL, resolvingAgainstBaseURL: true),
           var requestedDocument = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            currentDocument.fragment = nil
            requestedDocument.fragment = nil
            if currentDocument == requestedDocument {
                fragmentNavigationTarget = url
            }
        }
        resetNavigationDiagnostics()
        snapshot = IOSWebMountRuntimeSnapshot(
            sessionId: snapshot.sessionId,
            status: .loading,
            requestedURL: IOSWebMountRedactor.redactedURL(url.absoluteString),
            currentURL: IOSWebMountRedactor.redactedURL(webView.url?.absoluteString),
            title: webView.title,
            estimatedProgress: webView.estimatedProgress,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            error: nil,
            updatedAtMillis: IOSWebMountClock.nowMillis()
        )
        return await withCheckedContinuation { continuation in
            pendingLoad = (loadId, continuation)
            if fragmentNavigationTarget == nil {
                webView.load(URLRequest(url: url))
            } else {
                let decisionSequence = navigationDecisionSequence
                Task { @MainActor [weak self] in
                    guard let self, self.pendingLoad?.id == loadId else { return }
                    // WebKit may omit navigation delegate callbacks for fragments.
                    // Verify these destinations before loading, including no-op retries.
                    if self.fragmentNavigationTarget != nil, let policy = self.effectiveNavigationPolicy {
                        let result = await policy.validateResolvedPublicHost(
                            url.absoluteString,
                            site: self.navigationSite,
                            resolveHost: self.navigationHostResolver
                        )
                        guard self.pendingLoad?.id == loadId else { return }
                        guard self.navigationDecisionSequence == decisionSequence else {
                            self.rejectNavigation(.navigationTargetNotVerified(url.host ?? ""), url: url, webView: webView)
                            return
                        }
                        switch result {
                        case .success(let verifiedURL):
                            self.approvedMainFrameDestination = Self.navigationDestinationKey(verifiedURL)
                        case .failure(let error):
                            self.rejectNavigation(error, url: url, webView: webView)
                            return
                        }
                    }
                    guard self.pendingLoad?.id == loadId else { return }
                    self.verifiedFragmentLoadId = loadId
                    if self.fragmentNavigationTarget != nil, webView.url == url {
                        self.finishNavigation(webView)
                    } else {
                        webView.load(URLRequest(url: url))
                    }
                }
            }
            pendingLoadTimeoutTask = Task { @MainActor [weak self] in
                let nanos = timeoutMillis * 1_000_000
                do {
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    return
                }
                guard let self,
                      let pendingLoad = self.pendingLoad,
                      pendingLoad.id == loadId else { return }
                self.pendingLoadTimeoutTask = nil
                self.snapshot.status = .failed
                self.snapshot.error = "load timed out after \(timeoutMillis)ms"
                self.snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
                self.pendingLoad = nil
                pendingLoad.continuation.resume(returning: self.snapshot)
            }
        }
    }

    func reload() -> IOSWebMountRuntimeSnapshot {
        guard !isClosed else { return snapshot }
        cancelBrowserPresentation()
        // WebKit owns the complete current request. Public snapshots omit
        // query values and fragments and must never become reload targets.
        guard let webView = webViewStorage,
              webView.url != nil,
              webView.reload() != nil else {
            var failed = snapshot
            failed.status = .failed
            failed.error = "当前没有可重新加载的页面，请先打开站点。"
            failed.updatedAtMillis = IOSWebMountClock.nowMillis()
            return failed
        }
        snapshot.status = .loading
        snapshot.requestedURL = IOSWebMountRedactor.redactedURL(webView.url?.absoluteString)
        snapshot.estimatedProgress = webView.estimatedProgress
        snapshot.error = nil
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
        return snapshot
    }

    func state() async throws -> [String: Any] {
        var bridgeState = try await evaluateJSON(IOSWebMountBridgeScripts.state)
        bridgeState["navigation_diagnostics"] = navigationDiagnostics
        return bridgeState.merging(snapshot.dictionary(redactURLs: true)) { page, _ in page }
    }

    func observe(maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        var observation = try await evaluateJSON(
            IOSWebMountBridgeScripts.extract(
                mode: "snapshot",
                maxChars: maxChars,
                maxLinks: maxLinks
            )
        )
        var page = (observation["page"] as? [String: Any] ?? [:])
            .merging(snapshot.dictionary(redactURLs: true)) { page, _ in page }
        page["navigation_diagnostics"] = navigationDiagnostics
        observation["page"] = page
        observation["navigation_diagnostics"] = navigationDiagnostics
        observation["observation_consistency"] = "atomic"
        return observation
    }

    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        try await evaluateJSON(
            IOSWebMountBridgeScripts.extract(
                mode: mode,
                maxChars: maxChars,
                maxLinks: maxLinks
            )
        )
    }

    func get(
        selector: String?,
        target: String?,
        kind: String,
        attrName: String?,
        maxChars: Int
    ) async throws -> [String: Any] {
        try await evaluateJSON(
            IOSWebMountBridgeScripts.get(
                selector: selector,
                target: target,
                kind: kind,
                attrName: attrName,
                maxChars: maxChars
            )
        )
    }

    /// Drives a page interaction (click/type/scroll/keys/select/find/wait) via a
    /// restricted JS bridge. Android WebMountInteractionTools parity. Only the
    /// listed methods are permitted; arbitrary JS eval stays disabled.
    func interact(method: String, selector: String?, text: String?, options: [String: Any]) async throws -> [String: Any] {
        if method.lowercased() == "wait" {
            var waitOptions = options
            let selectorTarget = selector?.nilIfBlank
            let optionSelector = (waitOptions["selector"] as? String)?.nilIfBlank
            let optionTarget = (options["target"] as? String)?.nilIfBlank
            let providedTargets = [selectorTarget, optionSelector, optionTarget].compactMap { $0 }
            if Set(providedTargets).count > 1 {
                return [
                    "ok": false,
                    "method": "wait",
                    "error_code": "conflicting_target_arguments",
                    "matched": false,
                    "dispatched": false,
                    "navigation_diagnostics": navigationDiagnostics
                ]
            }
            if optionSelector == nil, let selectorTarget {
                waitOptions["selector"] = selectorTarget
            }
            if (waitOptions["selector"] as? String)?.nilIfBlank == nil, let optionTarget {
                waitOptions["selector"] = optionTarget
            }
            var result = await waitForCondition(options: waitOptions)
            result["navigation_diagnostics"] = navigationDiagnostics
            return result
        }
        var result = try await evaluateJSON(
            IOSWebMountBridgeScripts.interact(
                method: method,
                selector: selector,
                text: text,
                options: options
            )
        )
        result["navigation_diagnostics"] = navigationDiagnostics
        return result
    }

    private func waitForCondition(options: [String: Any]) async -> [String: Any] {
        let condition = ((options["condition"] as? String)?.nilIfBlank ?? "dom_stable").lowercased()
        let supported = Set([
            "dom_stable", "selector", "text", "url_contains", "ready_state", "delay",
            "document_changed", "url_changed"
        ])
        guard supported.contains(condition) else {
            return [
                "ok": false,
                "method": "wait",
                "error_code": "unsupported_wait_condition",
                "condition": condition
            ]
        }
        let beforeDocumentId = (options["before_document_id"] as? String)?.nilIfBlank
        let beforeURL = (options["before_url"] as? String)?.nilIfBlank
        let beforeURLRevision = (options["before_url_revision"] as? Int)
            ?? (options["before_url_revision"] as? NSNumber)?.intValue
            ?? (options["before_url_revision"] as? Double).map(Int.init)
        let beforeDOMRevision = (options["before_dom_revision"] as? Int)
            ?? (options["before_dom_revision"] as? NSNumber)?.intValue
            ?? (options["before_dom_revision"] as? Double).map(Int.init)
        let requirePageChange = options["require_page_change"] as? Bool ?? false
        let requiredArgument: String?
        switch condition {
        case "selector": requiredArgument = (options["selector"] as? String)?.nilIfBlank
        case "text": requiredArgument = (options["text"] as? String)?.nilIfBlank
        case "url_contains": requiredArgument = (options["url_contains"] as? String)?.nilIfBlank
        case "ready_state": requiredArgument = (options["ready_state"] as? String)?.nilIfBlank
        case "document_changed": requiredArgument = beforeDocumentId
        case "url_changed": requiredArgument = beforeURL != nil || (beforeURLRevision != nil && beforeDocumentId != nil) ? "baseline" : nil
        default: requiredArgument = "not-required"
        }
        guard requiredArgument != nil else {
            return [
                "ok": false,
                "method": "wait",
                "condition": condition,
                "error_code": ["document_changed", "url_changed"].contains(condition)
                    ? "missing_wait_baseline"
                    : "missing_wait_argument",
                "matched": false
            ]
        }
        if requirePageChange && beforeDocumentId == nil && beforeURL == nil && beforeURLRevision == nil && beforeDOMRevision == nil {
            return [
                "ok": false,
                "method": "wait",
                "condition": condition,
                "error_code": "missing_wait_baseline",
                "matched": false,
                "require_page_change": true
            ]
        }
        if condition == "ready_state",
           !["interactive", "complete"].contains(requiredArgument?.lowercased() ?? "") {
            return [
                "ok": false,
                "method": "wait",
                "condition": condition,
                "error_code": "invalid_ready_state",
                "matched": false
            ]
        }

        let rawTimeout = (options["wait_ms"] as? Int)
            ?? (options["timeout_ms"] as? Int)
            ?? (options["wait_ms"] as? NSNumber)?.intValue
            ?? (options["timeout_ms"] as? NSNumber)?.intValue
            ?? 5_000
        let timeoutMillis = rawTimeout.clamped(to: 100...30_000)
        let stableMillis = ((options["stable_ms"] as? Int)
            ?? (options["stable_ms"] as? NSNumber)?.intValue
            ?? 400).clamped(to: 100...2_000)
        let startedAt = Date()

        if condition == "delay" {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeoutMillis) * 1_000_000)
                return [
                    "ok": true,
                    "method": "wait",
                    "condition": condition,
                    "elapsed_ms": timeoutMillis,
                    "matched": true
                ]
            } catch {
                return [
                    "ok": false,
                    "method": "wait",
                    "condition": condition,
                    "error_code": "cancelled",
                    "matched": false
                ]
            }
        }

        var lastSnapshotId: String?
        var stableSince: Date?
        var lastProbe: [String: Any] = [:]
        var lastError: String?

        while true {
            if Task.isCancelled {
                return [
                    "ok": false,
                    "method": "wait",
                    "condition": condition,
                    "error_code": "cancelled",
                    "matched": false
                ]
            }

            do {
                let probe = try await evaluateJSON(IOSWebMountBridgeScripts.waitProbe(condition: condition, options: options))
                lastProbe = probe
                lastError = nil
                if let errorCode = (probe["error_code"] as? String)?.nilIfBlank {
                    var result = boundedWaitProbe(probe)
                    result["ok"] = false
                    result["method"] = "wait"
                    result["condition"] = condition
                    result["error_code"] = errorCode
                    result["matched"] = false
                    result["elapsed_ms"] = Int(Date().timeIntervalSince(startedAt) * 1_000)
                    return result
                }
                if condition == "dom_stable" {
                    let snapshotId = probe["snapshot_id"] as? String
                    let readyState = probe["ready_state"] as? String
                    let pageChanged = probe["page_changed"] as? Bool ?? false
                    if snapshotId == lastSnapshotId,
                       readyState != "loading",
                       !requirePageChange || pageChanged {
                        stableSince = stableSince ?? Date()
                        if let stableSince,
                           Date().timeIntervalSince(stableSince) * 1_000 >= Double(stableMillis) {
                            var result = boundedWaitProbe(probe)
                            result["ok"] = true
                            result["method"] = "wait"
                            result["condition"] = condition
                            result["matched"] = true
                            result["elapsed_ms"] = Int(Date().timeIntervalSince(startedAt) * 1_000)
                            return result
                        }
                    } else {
                        lastSnapshotId = snapshotId
                        stableSince = nil
                    }
                } else if probe["matched"] as? Bool == true {
                    var result = boundedWaitProbe(probe)
                    result["ok"] = true
                    result["method"] = "wait"
                    result["condition"] = condition
                    result["elapsed_ms"] = Int(Date().timeIntervalSince(startedAt) * 1_000)
                    return result
                }
            } catch {
                // A navigation can transiently replace the JS context. Keep polling
                // within the same bounded deadline and report the last error on timeout.
                lastError = error.localizedDescription
            }

            let elapsedMillis = Int(Date().timeIntervalSince(startedAt) * 1_000)
            if elapsedMillis >= timeoutMillis {
                return [
                    "ok": false,
                    "method": "wait",
                    "condition": condition,
                    "error_code": "wait_timeout",
                    "matched": false,
                    "elapsed_ms": elapsedMillis,
                    "last_snapshot_id": lastProbe["snapshot_id"] as? String ?? "",
                    "last_error": IOSWebMountRedactor.redactedText(lastError ?? ""),
                    "last_probe": boundedWaitProbe(lastProbe),
                    "require_page_change": requirePageChange
                ]
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(min(100, timeoutMillis - elapsedMillis)) * 1_000_000)
            } catch {
                return [
                    "ok": false,
                    "method": "wait",
                    "condition": condition,
                    "error_code": "cancelled",
                    "matched": false
                ]
            }
        }
    }

    private func boundedWaitProbe(_ probe: [String: Any]) -> [String: Any] {
        let allowedKeys: Set<String> = [
            "ok", "matched", "error_code", "ready_state", "url", "document_id",
            "page_revision", "dom_revision", "snapshot_id", "document_changed",
            "url_revision", "url_changed", "dom_changed", "page_changed", "condition_matched", "require_page_change",
            "before_document_id", "before_url", "before_url_revision", "before_dom_revision"
        ]
        var result: [String: Any] = [:]
        for (key, value) in probe where allowedKeys.contains(key) {
            if key == "url" || key == "before_url", let rawURL = value as? String {
                result[key] = IOSWebMountRedactor.redactedURL(rawURL) ?? ""
            } else {
                result[key] = value
            }
        }
        return result
    }

    func screenshot() async throws -> IOSWebMountScreenshotCapture {
        guard let webView else { throw IOSWebMountRuntimeError.webViewUnavailable }
#if canImport(UIKit)
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: IOSWebMountRuntimeError.invalidBridgePayload)
                }
            }
        }
        guard let data = image.pngData() else {
            throw IOSWebMountRuntimeError.invalidBridgePayload
        }
        return IOSWebMountScreenshotCapture(
            data: data,
            width: Int(image.size.width * image.scale),
            height: Int(image.size.height * image.scale),
            format: "png"
        )
#else
        throw IOSWebMountRuntimeError.webViewUnavailable
#endif
    }

    func back() async -> IOSWebMountRuntimeSnapshot {
        guard let webView, webView.canGoBack else {
            snapshot.canGoBack = webView?.canGoBack ?? false
            snapshot.canGoForward = webView?.canGoForward ?? false
            snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
            return snapshot
        }
        webView.goBack()
        snapshot.status = .loading
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
        return snapshot
    }

    func forward() async -> IOSWebMountRuntimeSnapshot {
        guard let webView, webView.canGoForward else {
            snapshot.canGoBack = webView?.canGoBack ?? false
            snapshot.canGoForward = webView?.canGoForward ?? false
            snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
            return snapshot
        }
        webView.goForward()
        snapshot.status = .loading
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
        return snapshot
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard !isClosed else { decisionHandler(.cancel); return }
        if webView !== self.webView {
            validatePopupNavigation(navigationAction.request.url, in: webView,
                                    mainFrame: navigationAction.targetFrame?.isMainFrame == true) { allowed in
                decisionHandler(allowed ? .allow : .cancel)
            }
            return
        }
        if let target = navigationAction.request.url?.absoluteString,
           (navigationAction.targetFrame == nil && target == "about:blank") ||
            (navigationAction.targetFrame?.isMainFrame == false && ["about:blank", "about:srcdoc"].contains(target)) {
            // Local documents used to bootstrap login windows and embedded forms
            // have no network host; their subsequent navigations still use policy.
            decisionHandler(.allow)
            return
        }
        guard let policy = effectiveNavigationPolicy,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let site = navigationSite
        let resolver = navigationHostResolver
        let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
        if isMainFrame {
            navigationDecisionSequence += 1
        }
        let decisionSequence = navigationDecisionSequence
        Task { @MainActor [weak self] in
            guard let self else {
                decisionHandler(.cancel)
                return
            }
            switch await policy.validateResolvedPublicHost(
                url.absoluteString,
                site: site,
                resolveHost: resolver
            ) {
            case .success(let verifiedURL):
                guard decisionSequence == self.navigationDecisionSequence else {
                    decisionHandler(.cancel)
                    return
                }
                if isMainFrame {
                    self.approvedMainFrameDestination = Self.navigationDestinationKey(verifiedURL)
                }
                decisionHandler(.allow)
            case .failure(let error):
                if isMainFrame, decisionSequence == self.navigationDecisionSequence {
                    self.rejectNavigation(error, url: url, webView: webView)
                } else if !isMainFrame, decisionSequence == self.navigationDecisionSequence {
                    self.recordNavigationEvent(
                        kind: "navigation_policy_denied",
                        decision: "cancel",
                        url: url,
                        errorCode: error.errorCode,
                        reason: error.localizedDescription,
                        frame: "subframe"
                    )
                    self.recordSubframeNavigationDenial(error, url: url)
                }
                decisionHandler(.cancel)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard popupWebViews.count < 4 else {
            reportPopupFailure("打开的窗口过多，请先关闭不用的窗口。", url: navigationAction.request.url,
                               errorCode: "popup_limit_reached")
            return nil
        }
        // WebKit's supplied configuration preserves window.opener, POST bodies
        // and the opener's cookie store; loading this URL in the parent breaks SSO.
        let popup = WKWebView(frame: webView.bounds, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.allowsBackForwardNavigationGestures = true
        popupWebViews.append(popup)
        recordNavigationEvent(kind: "new_window_request", decision: "opened", url: navigationAction.request.url)
        return popup
    }

    func closePopup(_ popup: WKWebView) {
        guard popupWebViews.contains(where: { $0 === popup }) else { return }
        if browserDialogWebView === popup { cancelBrowserPresentation() }
        popup.stopLoading()
        popup.navigationDelegate = nil
        popup.uiDelegate = nil
        popupApprovedDestinations.removeValue(forKey: ObjectIdentifier(popup))
        popupWebViews.removeAll { $0 === popup }
    }

    func cancelBrowserPresentation() {
        resolveBrowserDialog(nil)
    }

    func setBrowserPresentationAvailable(_ available: Bool, hostID: UUID) {
        guard !isClosed else { return }
        if available {
            browserPresentationHosts.insert(hostID)
        } else {
            browserPresentationHosts.remove(hostID)
            if browserPresentationHosts.isEmpty { cancelBrowserPresentation() }
        }
    }

    func cancelPopupDialogs() {
        if browserDialogWebView != nil && browserDialogWebView !== webView { resolveBrowserDialog(nil) }
    }

    func resolveBrowserDialog(_ response: String?, dialogID: UUID? = nil) {
        if let dialogID, browserDialog?.id != dialogID { return }
        let completion = browserDialogCompletion
        browserDialogCompletion = nil
        browserDialogWebView = nil
        browserDialog = nil
        completion?(response)
    }

    private func presentBrowserDialog(
        kind: IOSWebMountBrowserDialog.Kind,
        webView: WKWebView,
        message: String,
        frame: WKFrameInfo,
        defaultText: String = "",
        completion: @escaping (String?) -> Void
    ) {
        guard userBrowsingEnabled, !browserPresentationHosts.isEmpty else {
            browserNotice = userBrowsingEnabled
                ? "网页需要你确认或输入，请返回页面后重新操作。"
                : "网页需要你确认或输入，请接管页面后重新操作。"
            recordNavigationEvent(kind: "javascript_dialog", decision: "requires_user_control",
                                  url: frame.request.url, errorCode: "user_control_required")
            completion(nil)
            return
        }
        guard browserDialog == nil else {
            completion(nil)
            return
        }
        browserDialogCompletion = completion
        browserDialogWebView = webView
        browserDialog = IOSWebMountBrowserDialog(
            kind: kind, message: message, host: frame.securityOrigin.host, defaultText: defaultText
        )
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable () -> Void) {
        presentBrowserDialog(kind: .alert, webView: webView, message: message, frame: frame) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        presentBrowserDialog(kind: .confirm, webView: webView, message: message, frame: frame) { completionHandler($0 != nil) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        presentBrowserDialog(kind: .prompt, webView: webView, message: prompt, frame: frame,
                             defaultText: defaultText ?? "", completion: completionHandler)
    }

    func webViewDidClose(_ webView: WKWebView) {
        closePopup(webView)
    }

    private func validatePopupNavigation(
        _ url: URL?, in popup: WKWebView, mainFrame: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard popupWebViews.contains(where: { $0 === popup }), let url else {
            completion(false)
            return
        }
        // A newly created window needs its inherited, empty document before a
        // login script can assign its URL. Every network destination is checked.
        if url.absoluteString == "about:blank" || (!mainFrame && url.absoluteString == "about:srcdoc") {
            completion(true)
            return
        }
        guard let policy = effectiveNavigationPolicy else {
            completion(true)
            return
        }
        let site = navigationSite
        let revision = popupPolicyRevision
        let resolver = navigationHostResolver
        Task { @MainActor [weak self, weak popup] in
            let result = await policy.validateResolvedPublicHost(url.absoluteString, site: site, resolveHost: resolver)
            guard let self, let popup,
                  self.popupWebViews.contains(where: { $0 === popup }),
                  revision == self.popupPolicyRevision else {
                completion(false)
                return
            }
            switch result {
            case .success(let verifiedURL):
                if mainFrame {
                    self.popupApprovedDestinations[ObjectIdentifier(popup)] = Self.navigationDestinationKey(verifiedURL)
                }
                completion(true)
            case .failure(let error):
                self.reportPopupFailure(error.localizedDescription, url: url, errorCode: error.errorCode)
                completion(false)
            }
        }
    }

    private func reportPopupFailure(_ message: String, url: URL?, errorCode: String? = nil) {
        browserNotice = "登录窗口：" + IOSWebMountRedactor.redactedText(message)
        recordNavigationEvent(kind: "popup_navigation", decision: "cancel", url: url,
                              errorCode: errorCode, reason: message, frame: "popup")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard !isClosed else { decisionHandler(.cancel); return }
        if webView !== self.webView {
            guard navigationResponse.canShowMIMEType else {
                reportPopupFailure("此窗口不支持下载文件。", url: navigationResponse.response.url)
                decisionHandler(.cancel)
                return
            }
            validatePopupNavigation(navigationResponse.response.url, in: webView,
                                    mainFrame: navigationResponse.isForMainFrame) { allowed in
                decisionHandler(allowed ? .allow : .cancel)
            }
            return
        }
        if !navigationResponse.canShowMIMEType {
            recordNavigationEvent(
                kind: "download",
                decision: "cancel",
                url: navigationResponse.response.url,
                errorCode: "download_unsupported",
                reason: "WebMount does not automatically download navigation responses."
            )
            decisionHandler(.cancel)
            return
        }
        guard navigationResponse.isForMainFrame else {
            decisionHandler(.allow)
            return
        }
        guard let policy = effectiveNavigationPolicy else {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationResponse.response.url else {
            decisionHandler(.cancel)
            return
        }
        let site = navigationSite
        let resolver = navigationHostResolver
        let decisionSequence = navigationDecisionSequence
        Task { @MainActor [weak self] in
            guard let self else {
                decisionHandler(.cancel)
                return
            }
            switch await policy.validateResolvedPublicHost(
                url.absoluteString,
                site: site,
                resolveHost: resolver
            ) {
            case .success(let verifiedURL):
                guard decisionSequence == self.navigationDecisionSequence else {
                    decisionHandler(.cancel)
                    return
                }
                self.approvedMainFrameDestination = Self.navigationDestinationKey(verifiedURL)
                decisionHandler(.allow)
            case .failure(let error):
                if decisionSequence == self.navigationDecisionSequence {
                    self.rejectNavigation(error, url: url, webView: webView)
                }
                decisionHandler(.cancel)
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isClosed else { return }
        if browserDialogWebView === webView { cancelBrowserPresentation() }
        guard webView === self.webView else { return }
        snapshot.status = .loading
        snapshot.currentURL = IOSWebMountRedactor.redactedURL(webView.url?.absoluteString)
        snapshot.estimatedProgress = webView.estimatedProgress
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.error = nil
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !isClosed else { return }
        if webView !== self.webView {
            objectWillChange.send()
            guard let policy = effectiveNavigationPolicy, let url = webView.url,
                  url.absoluteString != "about:blank" else { return }
            guard case .success = policy.validate(url.absoluteString, site: navigationSite),
                  let destination = Self.navigationDestinationKey(url),
                  popupApprovedDestinations[ObjectIdentifier(webView)] == destination else {
                webView.stopLoading()
                reportPopupFailure("窗口跳转尚未通过验证。", url: url, errorCode: "navigation_target_not_verified")
                return
            }
            return
        }
        guard committedNavigationIsAllowed(webView) else { return }
        snapshot.currentURL = IOSWebMountRedactor.redactedURL(webView.url?.absoluteString)
        snapshot.estimatedProgress = webView.estimatedProgress
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed else { return }
        guard webView === self.webView else {
            popupNavigationRevision += 1
            return
        }
        finishNavigation(webView)
    }

    private func finishNavigation(_ webView: WKWebView) {
        if let target = fragmentNavigationTarget, let pendingLoad {
            guard verifiedFragmentLoadId == pendingLoad.id, webView.url == target else { return }
        }
        guard committedNavigationIsAllowed(webView) else { return }
        snapshot.status = .ready
        snapshot.currentURL = IOSWebMountRedactor.redactedURL(webView.url?.absoluteString)
        snapshot.title = webView.title
        snapshot.estimatedProgress = 1
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.error = nil
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
        completePendingLoad()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView !== self.webView {
            if (error as NSError).code != NSURLErrorCancelled {
                reportPopupFailure(error.localizedDescription, url: webView.url)
            }
            return
        }
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView !== self.webView {
            if (error as NSError).code != NSURLErrorCancelled {
                reportPopupFailure(error.localizedDescription, url: webView.url)
            }
            return
        }
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView !== self.webView {
            closePopup(webView)
            reportPopupFailure("窗口进程已退出，请重新打开登录窗口。", url: webView.url)
            return
        }
        cancelBrowserPresentation()
        fail(NSError(
            domain: WKErrorDomain,
            code: WKError.Code.webContentProcessTerminated.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Web content process terminated. Reopen the page before continuing."]
        ))
    }

    private func fail(_ error: Error) {
        recordNavigationEvent(
            kind: "navigation_failure",
            decision: "failed",
            url: webView?.url,
            errorCode: nil,
            reason: error.localizedDescription
        )
        snapshot.status = .failed
        snapshot.currentURL = IOSWebMountRedactor.redactedURL(webView?.url?.absoluteString)
        snapshot.title = webView?.title
        snapshot.estimatedProgress = webView?.estimatedProgress ?? 0
        snapshot.canGoBack = webView?.canGoBack ?? false
        snapshot.canGoForward = webView?.canGoForward ?? false
        snapshot.error = error.localizedDescription
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
        completePendingLoad()
    }

    private var navigationDiagnostics: [String: Any] {
        var diagnostics: [String: Any] = [
            "open_window_count": popupWebViews.count,
            "dialog_pending": browserDialog != nil,
            "subframe_navigation_denied_count": subframeNavigationDenialCount,
            "recent_events": navigationEvents
        ]
        if let lastSubframeNavigationDenial {
            diagnostics["last_subframe_navigation_denial"] = lastSubframeNavigationDenial
        }
        return diagnostics
    }

    private func recordSubframeNavigationDenial(
        _ error: IOSWebMountURLPolicyError,
        url: URL
    ) {
        subframeNavigationDenialCount += 1
        browserNotice = "网页内嵌页面被阻止：" + (url.host ?? "") + " · " + error.localizedDescription
        lastSubframeNavigationDenial = [
            "frame": "subframe",
            "decision": "cancel",
            "url": IOSWebMountRedactor.redactedURL(url.absoluteString) ?? "",
            "host": IOSWebMountURLPolicy.normalizedHost(url.host) ?? "",
            "error_code": error.errorCode,
            "reason": error.localizedDescription,
            "count": subframeNavigationDenialCount
        ]
    }

    private func recordNavigationEvent(
        kind: String,
        decision: String,
        url: URL?,
        errorCode: String? = nil,
        reason: String? = nil,
        frame: String? = nil
    ) {
        var event: [String: Any] = [
            "kind": kind,
            "decision": decision,
            "at_ms": IOSWebMountClock.nowMillis()
        ]
        if let url {
            event["url"] = IOSWebMountRedactor.redactedURL(url.absoluteString) ?? ""
            event["host"] = IOSWebMountURLPolicy.normalizedHost(url.host) ?? ""
        }
        if let errorCode = errorCode?.nilIfBlank {
            event["error_code"] = errorCode
        }
        if let reason = reason?.nilIfBlank {
            event["reason"] = IOSWebMountRedactor.redactedText(reason)
        }
        if let frame = frame?.nilIfBlank {
            event["frame"] = frame
        }
        navigationEvents.append(event)
        if navigationEvents.count > Self.maxNavigationEvents {
            navigationEvents.removeFirst(navigationEvents.count - Self.maxNavigationEvents)
        }
    }

    private func resetNavigationDiagnostics() {
        subframeNavigationDenialCount = 0
        lastSubframeNavigationDenial = nil
        navigationEvents.removeAll(keepingCapacity: true)
    }

    private func committedNavigationIsAllowed(_ webView: WKWebView) -> Bool {
        guard let policy = effectiveNavigationPolicy, let url = webView.url else { return true }
        guard case .failure(let error) = policy.validate(url.absoluteString, site: navigationSite) else {
            guard Self.navigationDestinationKey(url) == approvedMainFrameDestination else {
                webView.stopLoading()
                rejectNavigation(
                    .navigationTargetNotVerified(url.host ?? "unknown"),
                    url: url,
                    webView: webView
                )
                return false
            }
            return true
        }
        webView.stopLoading()
        rejectNavigation(error, url: url, webView: webView)
        return false
    }

    private static func navigationDestinationKey(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = IOSWebMountURLPolicy.normalizedHost(url.host) else {
            return nil
        }
        let port = url.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : -1))
        return "\(scheme)://\(host):\(port)"
    }

    private func rejectNavigation(
        _ error: IOSWebMountURLPolicyError,
        url: URL,
        webView: WKWebView
    ) {
        recordNavigationEvent(
            kind: "navigation_policy_denied",
            decision: "cancel",
            url: url,
            errorCode: error.errorCode,
            reason: error.localizedDescription,
            frame: "main"
        )
        snapshot.status = .failed
        snapshot.requestedURL = IOSWebMountRedactor.redactedURL(url.absoluteString)
        snapshot.currentURL = IOSWebMountRedactor.redactedURL(webView.url?.absoluteString)
        snapshot.title = webView.title
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.error = error.localizedDescription
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
        completePendingLoad()
    }

    private func completePendingLoad() {
        pendingLoadTimeoutTask?.cancel()
        pendingLoadTimeoutTask = nil
        guard let pendingLoad else { return }
        self.pendingLoad = nil
        fragmentNavigationTarget = nil
        pendingLoad.continuation.resume(returning: snapshot)
    }

    private func evaluateJSON(_ script: String) async throws -> [String: Any] {
        guard !isClosed else { return ["ok": false, "error_code": "session_closed", "reason": "站点会话已关闭。"] }
        guard browserDialog == nil else {
            return ["ok": false, "error_code": "user_dialog_pending",
                    "reason": "网页正在等待用户处理确认或输入框，请在 WebMount 中接管处理。"]
        }
        guard let webView else { throw IOSWebMountRuntimeError.webViewUnavailable }
        let value = try await webView.evaluateJavaScript(
            script,
            contentWorld: Self.automationContentWorld
        )
        let jsonString: String
        if let value = value as? String {
            jsonString = value
        } else if let value {
            jsonString = String(describing: value)
        } else {
            jsonString = "{}"
        }
        guard let data = jsonString.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IOSWebMountRuntimeError.invalidBridgePayload
        }
        return object
    }
}

enum IOSWebMountRuntimeError: Error {
    case webViewUnavailable
    case invalidBridgePayload
}

