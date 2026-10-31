import AppKit
import Foundation
import WebKit

// MARK: - Amber Theme CSS Token Generator & CSP Builder

enum DesktopPluginThemeCSS {
    static func tokenMap(isDark: Bool) -> [String: String] {
        if isDark {
            return [
                "--amber-paper": "#161512",
                "--amber-paper-side": "#1B1916",
                "--amber-paper-deep": "#22201C",
                "--amber-hover": "#282520",
                "--amber-card": "#1E1C18",
                "--amber-field": "#22201C",
                "--amber-ink": "#F0EDE6",
                "--amber-ink-secondary": "#C6C2B8",
                "--amber-ink-tertiary": "#9E998E",
                "--amber-hairline": "rgba(255, 248, 235, 0.08)",
                "--amber-hairline-strong": "rgba(255, 248, 235, 0.14)",
                "--amber-accent": "#DAA972",
                "--amber-accent-ink": "#ECCB9E",
                "--amber-honey": "rgba(213, 160, 100, 0.22)",
                "--amber-honey-soft": "rgba(213, 160, 100, 0.11)",
                "--amber-honey-edge": "rgba(218, 169, 114, 0.32)",
                "--amber-danger": "#E5736B",
                "--amber-success": "#68C78E",
                "--amber-bg-primary": "#161512",
                "--amber-bg-secondary": "#1B1916",
                "--amber-bg-card": "#1E1C18",
                "--amber-bg-elevated": "#22201C",
                "--amber-text-primary": "#F0EDE6",
                "--amber-text-secondary": "#C6C2B8",
                "--amber-text-muted": "#9E998E",
                "--amber-accent-soft": "rgba(213, 160, 100, 0.11)",
                "--amber-border": "rgba(255, 248, 235, 0.08)",
                "--amber-font-sans": "-apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif",
                "--amber-font-serif": "'Songti SC', 'STSong', serif",
                "--amber-font-mono": "ui-monospace, 'SF Mono', Menlo, monospace",
                "--amber-radius-sm": "6px",
                "--amber-radius-md": "10px",
                "--amber-radius-lg": "14px"
            ]
        } else {
            return [
                "--amber-paper": "#FAF8F3",
                "--amber-paper-side": "#F3F0E8",
                "--amber-paper-deep": "#EFECE3",
                "--amber-hover": "#EAE6DB",
                "--amber-card": "#FFFFFF",
                "--amber-field": "#FFFFFF",
                "--amber-ink": "#191815",
                "--amber-ink-secondary": "#45433D",
                "--amber-ink-tertiary": "#68645C",
                "--amber-hairline": "rgba(25, 24, 21, 0.085)",
                "--amber-hairline-strong": "rgba(25, 24, 21, 0.14)",
                "--amber-accent": "#A65E26",
                "--amber-accent-ink": "#784012",
                "--amber-honey": "rgba(222, 150, 72, 0.24)",
                "--amber-honey-soft": "rgba(222, 150, 72, 0.12)",
                "--amber-honey-edge": "rgba(166, 94, 38, 0.30)",
                "--amber-danger": "#B3261E",
                "--amber-success": "#2A7B4C",
                "--amber-bg-primary": "#FAF8F3",
                "--amber-bg-secondary": "#F3F0E8",
                "--amber-bg-card": "#FFFFFF",
                "--amber-bg-elevated": "#FFFFFF",
                "--amber-text-primary": "#191815",
                "--amber-text-secondary": "#45433D",
                "--amber-text-muted": "#68645C",
                "--amber-accent-soft": "rgba(222, 150, 72, 0.12)",
                "--amber-border": "rgba(25, 24, 21, 0.085)",
                "--amber-font-sans": "-apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif",
                "--amber-font-serif": "'Songti SC', 'STSong', serif",
                "--amber-font-mono": "ui-monospace, 'SF Mono', Menlo, monospace",
                "--amber-radius-sm": "6px",
                "--amber-radius-md": "10px",
                "--amber-radius-lg": "14px"
            ]
        }
    }

    static func stylesheet(isDark: Bool) -> String {
        let tokens = tokenMap(isDark: isDark)
            .sorted { $0.key < $1.key }
            .map { "  \($0.key): \($0.value);" }
            .joined(separator: "\n")
        return """
        :root, :root[data-theme="\(isDark ? "dark" : "light")"] {
          color-scheme: \(isDark ? "dark" : "light");
        \(tokens)
        }
        body {
          background-color: var(--amber-paper);
          color: var(--amber-ink);
          font-family: var(--amber-font-sans);
          margin: 0;
        }
        """
    }

    static func contentSecurityPolicy(allowedDomains: [String]) -> String {
        let cleanDomains = allowedDomains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let httpsOrigins = cleanDomains.flatMap { ["https://\($0)", "https://*.\($0)"] }.joined(separator: " ")
        let connectPart = httpsOrigins.isEmpty ? "'self' amber-plugin:" : "'self' amber-plugin: \(httpsOrigins)"
        let imgPart = httpsOrigins.isEmpty ? "'self' data: blob: amber-plugin:" : "'self' data: blob: amber-plugin: \(httpsOrigins)"
        return "default-src 'self' amber-plugin:; script-src 'self' 'unsafe-inline' amber-plugin:; style-src 'self' 'unsafe-inline' amber-plugin:; img-src \(imgPart); connect-src \(connectPart); font-src 'self' data: amber-plugin:; frame-src 'none'; object-src 'none'; base-uri 'self' amber-plugin:;"
    }
}

// MARK: - Custom URL Scheme Handler (`amber-plugin://<pluginID>/<path>`) & WebView Host

@MainActor
final class DesktopPluginURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "amber-plugin"
    private weak var store: DesktopPluginStore?

    init(store: DesktopPluginStore) {
        self.store = store
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let store,
              let url = urlSchemeTask.request.url,
              url.scheme?.lowercased() == Self.scheme,
              let pluginID = url.host?.lowercased() else {
            fail(task: urlSchemeTask, status: 400, message: "无效的插件资源地址")
            return
        }
        do {
            let (data, mimeType, headers) = try store.loadPluginStaticAsset(pluginID: pluginID, rawPath: url.path)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers.merging(["Content-Type": mimeType]) { $1 }
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            fail(task: urlSchemeTask, status: 403, message: error.localizedDescription)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func fail(task: any WKURLSchemeTask, status: Int, message: String) {
        let url = task.request.url ?? URL(string: "amber-plugin://invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain; charset=utf-8"]
        )!
        task.didReceive(response)
        task.didReceive(Data(message.utf8))
        task.didFinish()
    }
}

@MainActor
final class DesktopPluginWebViewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let pluginID: String
    let viewID: String
    private weak var store: DesktopPluginStore?
    weak var webView: WKWebView?

    init(pluginID: String, viewID: String, store: DesktopPluginStore) {
        self.pluginID = pluginID
        self.viewID = viewID
        self.store = store
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "amberBridge",
              let body = message.body as? [String: Any],
              let requestId = body["requestId"] as? String,
              let namespace = body["namespace"] as? String,
              let method = body["method"] as? String else {
            return
        }
        let args = (body["args"] as? [Any]) ?? []
        guard let store else { return }

        Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            do {
                let resultJSON = try await store.dispatchBridgeRPC(
                    pluginID: self.pluginID,
                    viewID: self.viewID,
                    namespace: namespace,
                    method: method,
                    args: args
                )
                let js = "window.__amberBridgeResolve(\(Self.jsQuoted(requestId)), \(resultJSON));"
                _ = try? await self.webView?.evaluateJavaScript(js)
            } catch {
                let code = DesktopPluginBridgeErrorCode.classify(error).rawValue
                let js = "window.__amberBridgeReject(\(Self.jsQuoted(requestId)), \(Self.jsQuoted(error.localizedDescription)), \(Self.jsQuoted(code)));"
                _ = try? await self.webView?.evaluateJavaScript(js)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" {
            decisionHandler(.allow)
            return
        }
        // Strictly allow only `amber-plugin://<pluginID>/...` inside the plugin WebView.
        // `file://`, `http://`, and arbitrary external `https://` top-level/iframe navigations are blocked.
        if scheme == DesktopPluginURLSchemeHandler.scheme,
           url.host?.lowercased() == pluginID.lowercased() {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    func pushEvent(name: String, payloadJSON: String) {
        let js = "if (window.__amberBridgeEmit) { window.__amberBridgeEmit(\(Self.jsQuoted(name)), \(payloadJSON)); }"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private static func jsQuoted(_ text: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [text]),
           let arr = String(data: data, encoding: .utf8),
           arr.count >= 2 {
            return String(arr.dropFirst().dropLast())
        }
        return "\"\""
    }
}

// MARK: - Static Asset Loader for `amber-plugin://<pluginID>/<path>` with Strict CSP & Anti-Traversal Guard

extension DesktopPluginStore {
    func loadPluginStaticAsset(pluginID: String, rawPath: String) throws -> (data: Data, mimeType: String, headers: [String: String]) {
        guard let plugin = plugins.first(where: { $0.id == pluginID }) else {
            throw DesktopRuntimeError.message("找不到插件：\(pluginID)。")
        }
        guard plugin.enabled else {
            throw DesktopRuntimeError.message("插件 \(plugin.manifest.name) 已停用。")
        }
        try requirePermission(plugin: plugin, permission: "ui.views")

        let cleanRelative = rawPath
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? rawPath
        let trimmed = cleanRelative.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let effectiveRelative = trimmed.isEmpty ? "index.html" : trimmed

        let pluginRoot = directory.appendingPathComponent(plugin.id, isDirectory: true)
        let fileURL = try Self.resolveAuthorizedWorkspaceFileURL(
            rootDirectory: pluginRoot,
            relativePath: effectiveRelative,
            allowedPrefixes: ["*"],
            createParents: false
        )
        guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw DesktopRuntimeError.message("插件静态资源不存在：\(effectiveRelative)")
        }

        var data = try Data(contentsOf: fileURL)
        let ext = fileURL.pathExtension.lowercased()
        let mimeType = Self.mimeType(forExtension: ext)
        let allowedDomains = plugin.manifest.capabilities.networkDomains.filter { domain in
            hasPermission(plugin: plugin, permission: "http:\(domain.lowercased())")
        }
        let csp = DesktopPluginThemeCSS.contentSecurityPolicy(allowedDomains: allowedDomains)

        if ext == "html" || ext == "htm", var html = String(data: data, encoding: .utf8) {
            let metaTag = #"<meta http-equiv="Content-Security-Policy" content="\#(csp)">"#
            let themeStyle = #"<style id="amber-theme-tokens">\#(DesktopPluginThemeCSS.stylesheet(isDark: isDarkThemeActive))</style>"#
            if let headRange = html.range(of: "<head>", options: .caseInsensitive) {
                html.insert(contentsOf: "\n\(metaTag)\n\(themeStyle)\n", at: headRange.upperBound)
            } else {
                html = "\(metaTag)\n\(themeStyle)\n" + html
            }
            data = Data(html.utf8)
        }

        return (
            data: data,
            mimeType: mimeType,
            headers: [
                "Content-Security-Policy": csp,
                "X-Content-Type-Options": "nosniff",
                "Cache-Control": "no-store"
            ]
        )
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "application/javascript; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        default: "application/octet-stream"
        }
    }
}
