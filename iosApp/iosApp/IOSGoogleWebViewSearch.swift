import Foundation
import WebKit

enum IOSGoogleWebViewSearchError: LocalizedError, Equatable {
    case blocked
    case timeout
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .blocked: "Google 返回了验证或同意页面"
        case .timeout: "Google 页面加载超时"
        case .loadFailed(let reason): "Google 页面加载失败：\(reason)"
        }
    }
}

/// 免费聚合结果过少时的最后兜底：在不显示的 WKWebView 中打开 Google 搜索页，
/// 页面脚本执行完后从 DOM 提取结果。Google 的无 JS 页面已不返回结果，所以必须用 WebView。
@MainActor
final class IOSGoogleWebViewSearch: NSObject, WKNavigationDelegate {
    /// 结果标题都是 `a > h3`；摘要容器的 class 经常变，这里只取结果块内最长的一段文字。
    /// WebView 不在窗口中不参与布局，innerText 会返回空串，必须用 textContent。
    /// 结果链接是加密的 /goto?url= 跳转（2026-09 实测），真实地址由 `resolveRedirect` 解析。
    static let extractionScript = """
    (() => {
      const out = [];
      const seen = new Set();
      for (const h3 of document.querySelectorAll('a h3')) {
        const a = h3.closest('a');
        if (!a || !a.href || !a.href.startsWith('http')) continue;
        const link = new URL(a.href);
        const isRedirect = link.hostname.endsWith('google.com') && (link.pathname === '/goto' || link.pathname === '/url');
        if ((link.hostname.endsWith('google.com') && !isRedirect) || seen.has(a.href)) continue;
        seen.add(a.href);
        const title = (h3.textContent || '').trim();
        if (!title) continue;
        const block = a.closest('div[data-hveid], div.g, div.MjjYud') || a.parentElement;
        let snippet = '';
        for (const el of block ? block.querySelectorAll('div, span') : []) {
          const text = (el.textContent || '').trim();
          if (text.length > snippet.length && text.length < 600 && !text.includes(title)) snippet = text;
        }
        out.push({ title, url: a.href, snippet });
      }
      return JSON.stringify(out);
    })();
    """

    private static var active: Set<IOSGoogleWebViewSearch> = []

    private let webView: WKWebView
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768), configuration: configuration)
        // 桌面 UA 让 Google 返回结构稳定的桌面结果页。
        webView.customUserAgent = IOSFreeSearchAggregator.desktopUserAgent
        super.init()
        webView.navigationDelegate = self
    }

    static func search(query: String, maxResults: Int, timeout: TimeInterval = 12) async throws -> [IOSSearchResult] {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "hl", value: IOSFreeSearchAggregator.containsCJK(query) ? "zh-CN" : "en"),
            URLQueryItem(name: "num", value: "10"),
        ]
        let searcher = IOSGoogleWebViewSearch()
        active.insert(searcher)
        defer { active.remove(searcher) }
        let json = try await searcher.load(components.url!, timeout: timeout)
        let extracted = parseExtraction(json, maxResults: maxResults)
        let tasks = extracted.map { result in
            Task { await resolveRedirect(result.url) }
        }
        var resolved: [IOSSearchResult] = []
        for (result, task) in zip(extracted, tasks) {
            guard let url = await task.value else { continue }
            resolved.append(IOSSearchResult(title: result.title, url: url, snippet: result.snippet))
        }
        return resolved
    }

    /// 请求 Google 跳转链接但不跟随重定向，取 302 的 Location 作为真实地址；非跳转链接原样返回。
    nonisolated static func resolveRedirect(_ url: String) async -> String? {
        guard let components = URLComponents(string: url),
              components.host?.hasSuffix("google.com") == true else { return url }
        if components.path == "/url",
           let target = components.queryItems?.first(where: { $0.name == "q" })?.value,
           target.hasPrefix("http") {
            return target
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 6
        guard let (_, response) = try? await URLSession.shared.data(for: request, delegate: NoRedirectDelegate()),
              let http = response as? HTTPURLResponse,
              (300...399).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              location.hasPrefix("http"),
              URL(string: location)?.host?.hasSuffix("google.com") == false else { return nil }
        return location
    }

    static func parseExtraction(_ json: String, maxResults: Int) -> [IOSSearchResult] {
        guard let data = json.data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return items.prefix(maxResults).compactMap { item in
            let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = item["url"] as? String ?? ""
            guard !title.isEmpty, url.hasPrefix("http") else { return nil }
            return IOSSearchResult(title: title, url: url, snippet: item["snippet"] as? String ?? "")
        }
    }

    private func load(_ url: URL, timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
#if DEBUG
                    let info = (try? await self?.webView.evaluateJavaScript(
                        "document.title + ' | ' + location.href + ' | h3=' + document.querySelectorAll('h3').length"
                    )) as? String
                    NSLog("%@", "[AmberSearch] google-webview timeout: \(info ?? "-")")
#endif
                    self?.finish(.failure(IOSGoogleWebViewSearchError.timeout))
                }
                self.webView.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        pollTask?.cancel()
        webView.stopLoading()
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard pollTask == nil else { return }
        // didFinish 时结果还没由页面脚本渲染出来，轮询提取直到结果稳定或超时。
        pollTask = Task { @MainActor [weak self] in
            var previous = ""
            while let self, self.continuation != nil, !Task.isCancelled {
                let host = webView.url?.host ?? ""
                if host.hasPrefix("consent.") || (webView.url?.path ?? "").hasPrefix("/sorry") {
                    self.finish(.failure(IOSGoogleWebViewSearchError.blocked))
                    return
                }
                let json = (try? await webView.evaluateJavaScript(Self.extractionScript)) as? String ?? "[]"
                // 结果分批渲染：两次轮询结果一致（渲染稳定）才收口。
                if json != "[]", json == previous {
                    self.finish(.success(json))
                    return
                }
                previous = json
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(IOSGoogleWebViewSearchError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(IOSGoogleWebViewSearchError.loadFailed(error.localizedDescription)))
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
