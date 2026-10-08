import SwiftUI
@preconcurrency import WebKit

struct DeepReadArticleWebView: UIViewRepresentable {
    let html: String
    @Binding var error: String?
    var allowsRemoteImages = false

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(IOSDeepReadFontSchemeHandler(), forURLScheme: IOSDeepReadFontSchemeHandler.scheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let document = IOSDeepReadHTMLSecurity.hardenedDocument(html, allowsRemoteImages: allowsRemoteImages)
        guard context.coordinator.loadedHTML != document else { return }
        context.coordinator.loadedHTML = document
        context.coordinator.awaitingDocument = true
        view.loadHTMLString(document, baseURL: URL(string: IOSDeepReadFontSchemeHandler.documentBaseURL))
    }

    func makeCoordinator() -> Coordinator { Coordinator(error: $error) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        var awaitingDocument = false
        let error: Binding<String?>
        init(error: Binding<String?>) { self.error = error }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if awaitingDocument && action.navigationType == .other && action.targetFrame?.isMainFrame == true
                && (url.absoluteString == IOSDeepReadFontSchemeHandler.documentBaseURL || url.absoluteString == "about:blank") {
                awaitingDocument = false
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated && ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { error.wrappedValue = failure.localizedDescription }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) { error.wrappedValue = failure.localizedDescription }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error.wrappedValue = "阅读页面加载中断，请返回后重新打开。" }
    }
}

struct DeepReadActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
