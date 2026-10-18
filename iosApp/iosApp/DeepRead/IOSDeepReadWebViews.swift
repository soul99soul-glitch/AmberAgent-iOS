import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
@preconcurrency import WebKit
#endif
@preconcurrency import Network
@preconcurrency import Shared
#if canImport(WebKit)
enum IOSDeepReadNavigationPolicy {
    static func allowsInitialDocument(
        url: URL?,
        isMainFrame: Bool,
        isOtherNavigation: Bool,
        isAwaitingInitialDocument: Bool,
        allowedDocumentURLs: [String] = ["about:blank"]
    ) -> Bool {
        guard isAwaitingInitialDocument, isMainFrame, isOtherNavigation, let url else { return false }
        return allowedDocumentURLs.contains {
            $0.caseInsensitiveCompare(url.absoluteString) == .orderedSame
        }
    }
}

struct IOSDeepReadTemplateWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let validation = IOSDeepReadTemplateValidator.validateHTML(html, requirePlaceholders: false)
        let safeHTML = validation.ok ? html : "<html><body><p>模板校验失败：\(validation.error ?? "未知错误")</p></body></html>"
        context.coordinator.prepareForInitialDocument()
        webView.loadHTMLString(IOSDeepReadHTMLSecurity.hardenedDocument(safeHTML), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var isAwaitingInitialDocument = false

        func prepareForInitialDocument() {
            isAwaitingInitialDocument = true
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let shouldAllow = IOSDeepReadNavigationPolicy.allowsInitialDocument(
                url: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
                isOtherNavigation: navigationAction.navigationType == .other,
                isAwaitingInitialDocument: isAwaitingInitialDocument
            )
            if shouldAllow {
                isAwaitingInitialDocument = false
            }
            decisionHandler(shouldAllow ? .allow : .cancel)
        }
    }
}
#else
struct IOSDeepReadTemplateWebView: View {
    let html: String

    var body: some View {
        Text("当前平台不支持 HTML 模板预览。")
            .font(.caption)
            .foregroundStyle(AmberTheme.muted)
    }
}
#endif

#if canImport(WebKit)
/// A WKWebView host for the Deep Read editorial reader that grows to its content
/// height instead of scrolling internally — so the whole magazine article scrolls
/// as part of the detail page (no nested scroll). Reports the laid-out content
/// height through `contentHeight`; tapped source links open in the system browser.
struct IOSDeepReadEditorialWebView: UIViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat
    var allowsRemoteImages = false

    /// Document height the frame must give the article (internal scroll is off). Measures to
    /// the article's bottom edge, not its height: the first section's top margin collapses
    /// outside the article, so `height` alone under-measures and clips the last line.
    static let measureHeightScript = """
    (function() {
      var article = document.querySelector('article');
      if (article) {
        var r = article.getBoundingClientRect();
        return Math.ceil(r.bottom + window.scrollY);
      }
      var body = document.body;
      if (!body) return 0;
      return Math.ceil(Math.max(body.scrollHeight, body.offsetHeight, 1));
    })();
    """

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Needed so we can measure `article` height after load (static HTML only).
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        // Serve the app-bundled reader fonts (Noto Serif SC / JetBrains Mono) to the
        // page's @font-face via a custom scheme.
        configuration.setURLSchemeHandler(IOSDeepReadFontSchemeHandler(), forURLScheme: IOSDeepReadFontSchemeHandler.scheme)
        // Content that changes height after load (a close reading's footnotes open and close)
        // reports its new height; the fixed 0/280/800ms remeasure only covers the first paint.
        configuration.userContentController.add(context.coordinator, name: Coordinator.heightMessage)
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            new ResizeObserver(function() {
              window.webkit.messageHandlers.\(Coordinator.heightMessage).postMessage(\(Self.measureHeightScript.trimmingCharacters(in: CharacterSet(charactersIn: " \n;"))));
            }).observe(document.body);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false   // the detail page scrolls the article
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        context.coordinator.lastHeight = 0
        webView.stopLoading()
        context.coordinator.prepareForInitialDocument()
        // Load from a handler-less origin so the main frame is NOT routed to the font
        // scheme handler (a registered scheme as the document base URL gets the main
        // request handed to the handler → fail → blank page). Fonts then load
        // cross-origin via the handler's Access-Control-Allow-Origin: * response.
        webView.loadHTMLString(
            IOSDeepReadHTMLSecurity.hardenedDocument(html, allowsRemoteImages: allowsRemoteImages),
            baseURL: URL(string: IOSDeepReadFontSchemeHandler.documentBaseURL)
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onHeight: { [binding = $contentHeight] in binding.wrappedValue = $0 })
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let heightMessage = "deepReadHeight"
        private let onHeight: @MainActor (CGFloat) -> Void
        var loadedHTML: String?
        var lastHeight: CGFloat = 0
        private var remeasureTask: Task<Void, Never>?
        private var isAwaitingInitialDocument = false

        init(onHeight: @escaping @MainActor (CGFloat) -> Void) {
            self.onHeight = onHeight
        }

        func prepareForInitialDocument() {
            isAwaitingInitialDocument = true
        }

        /// Prefer measuring the laid-out `article` via JS. UIScrollView.contentSize
        /// often stays at the *frame* height when the SwiftUI host starts tall, so
        /// short articles leave a large empty gap above the native「相关报道」block.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            scheduleRemeasure(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // Avoid leaving the host at height 1 after a failed load.
            publishHeight(max(120, webView.scrollView.contentSize.height))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            publishHeight(max(120, webView.scrollView.contentSize.height))
        }

        private func scheduleRemeasure(_ webView: WKWebView) {
            remeasureTask?.cancel()
            // 0 / 280 / 800ms: first paint + font reflow, no continuous observer.
            remeasureTask = Task { @MainActor [weak self, weak webView] in
                for delayNs: UInt64 in [0, 280_000_000, 800_000_000] {
                    if delayNs > 0 {
                        try? await Task.sleep(nanoseconds: delayNs)
                    }
                    guard !Task.isCancelled, let self, let webView else { return }
                    self.publishMeasuredHeight(from: webView)
                }
            }
        }

        private func publishMeasuredHeight(from webView: WKWebView) {
            webView.evaluateJavaScript(IOSDeepReadEditorialWebView.measureHeightScript) { [weak self] result, _ in
                let measured: CGFloat
                if let number = result as? NSNumber {
                    measured = CGFloat(truncating: number)
                } else if let value = result as? Double {
                    measured = CGFloat(value)
                } else if let value = result as? Int {
                    measured = CGFloat(value)
                } else {
                    measured = webView.scrollView.contentSize.height
                }
                Task { @MainActor [weak self] in
                    self?.publishHeight(max(1, measured.rounded(.up)))
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let height = (message.body as? NSNumber).map({ CGFloat(truncating: $0) }), height > 0 else { return }
            publishHeight(height.rounded(.up))
        }

        private func publishHeight(_ height: CGFloat) {
            guard abs(height - lastHeight) > 0.5 else { return }
            lastHeight = height
            onHeight(height)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url,
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            let shouldAllow = IOSDeepReadNavigationPolicy.allowsInitialDocument(
                url: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
                isOtherNavigation: navigationAction.navigationType == .other,
                isAwaitingInitialDocument: isAwaitingInitialDocument,
                allowedDocumentURLs: ["about:blank", IOSDeepReadFontSchemeHandler.documentBaseURL]
            )
            if shouldAllow {
                isAwaitingInitialDocument = false
            }
            decisionHandler(shouldAllow ? .allow : .cancel)
        }
    }
}
#else
struct IOSDeepReadEditorialWebView: View {
    let html: String
    @Binding var contentHeight: CGFloat
    var allowsRemoteImages = false

    var body: some View {
        Text("当前平台不支持 HTML 阅读器。")
            .font(.caption)
            .foregroundStyle(AmberTheme.muted)
    }
}
#endif
