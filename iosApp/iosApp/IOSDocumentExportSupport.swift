import Foundation
import UIKit
@preconcurrency import WebKit

/// 分享用的临时文件：每次导出一个独立目录，文件名保留可读标题；顺带清掉一小时前的旧导出。
enum IOSShareFileWriter {
    static let rootDirectoryName = "AmberShareExport"
    static let retention: TimeInterval = 60 * 60

    static func write(
        _ data: Data,
        fileName: String,
        pathExtension: String,
        root: URL = FileManager.default.temporaryDirectory.appendingPathComponent(rootDirectoryName, isDirectory: true)
    ) throws -> URL {
        pruneExpired(in: root)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(sanitized(fileName)).appendingPathExtension(pathExtension)
        try data.write(to: url, options: [.atomic])
        return url
    }

    /// 分享面板可能仍在读取刚写的文件，只删除超过保留时长的目录。
    static func pruneExpired(in root: URL, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        for child in children {
            let created = (try? child.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if now.timeIntervalSince(created) > retention {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    static func sanitized(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        var cleaned = name.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 前导点会变成隐藏文件。
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return "Amber" }
        // 文件名上限按 UTF-8 字节计（255），为扩展名留余量；按完整字符截断，不拆开 emoji。
        var result = ""
        for character in cleaned {
            guard result.utf8.count + String(character).utf8.count <= 200 else { break }
            result.append(character)
        }
        return result
    }
}

/// HTML → 分页 A4 PDF。沿用深读的安全策略：禁用 JS、非持久数据存储、CSP 只放行内联样式与 data 图片。
@MainActor
final class IOSHTMLPDFRenderer: NSObject, WKNavigationDelegate {
    static let paperRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    static let loadTimeout: Duration = .seconds(30)

    enum RenderError: LocalizedError {
        case timedOut
        case webContentTerminated
        case empty

        var errorDescription: String? {
            switch self {
            case .timedOut: "生成 PDF 超时，请稍后重试。"
            case .webContentTerminated: "生成 PDF 时渲染进程意外退出，请稍后重试。"
            case .empty: "PDF 没有生成任何页面。"
            }
        }
    }

    private var continuation: CheckedContinuation<Void, Error>?

    static func render(html: String) async throws -> Data {
        try await IOSHTMLPDFRenderer().run(html: html)
    }

    nonisolated static let printCSS = "pre,blockquote,tr,img,figure{break-inside:avoid}h1,h2,h3{break-after:avoid}"

    /// 给外部生成的 HTML（深读版式、自定义模板）补上分页规则，避免代码块、表格行被切开、标题落在页尾。
    nonisolated static func printFriendly(_ html: String) -> String {
        let style = "<style>\(printCSS)</style>"
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: range, with: style + "</head>")
        }
        return style + html
    }

    nonisolated static func document(body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body{font-family:-apple-system,"PingFang SC",sans-serif;font-size:11pt;line-height:1.6;color:#1d1d1f;margin:0;overflow-wrap:anywhere;-webkit-print-color-adjust:exact}
        .doc-title{font-size:18pt;line-height:1.3;margin:0 0 4pt}
        .body h1{font-size:14pt;margin:12pt 0 6pt}.body h2{font-size:13pt;margin:10pt 0 5pt}.body h3{font-size:12pt;margin:8pt 0 4pt}
        .meta{font-size:9pt;color:#8e8e93;margin:0 0 14pt}
        .msg{margin:0 0 16pt}
        .role{font-size:9pt;font-weight:600;color:#8e8e93;letter-spacing:.04em;margin-bottom:4pt}
        .user .body{background:#f2f2f7;border-radius:8pt;padding:2pt 10pt}
        pre{background:#fafafa;border:.5pt solid #e5e5ea;padding:8pt;border-radius:6pt;white-space:pre-wrap;word-break:break-word}
        code{font-family:Menlo,monospace;font-size:9.5pt}
        :not(pre)>code{background:#e9e9ee;padding:0 3pt;border-radius:3pt}
        table{width:100%;table-layout:fixed;border-collapse:collapse;margin:6pt 0}td,th{border:.5pt solid #c7c7cc;padding:3pt 6pt;vertical-align:top}
        blockquote{border-left:2.5pt solid #d1d1d6;margin:0;padding-left:10pt;color:#555}
        img{max-width:100%}
        \(printCSS)
        </style></head><body>\(body)</body></html>
        """
    }

    private func run(html: String) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: Self.paperRect, configuration: configuration)
        webView.navigationDelegate = self
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.loadTimeout)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(RenderError.timedOut))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.loadHTMLString(IOSDeepReadHTMLSecurity.hardenedDocument(html), baseURL: nil)
        }

        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let printable = Self.paperRect.insetBy(dx: 42, dy: 48)
        renderer.setValue(NSValue(cgRect: Self.paperRect), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, Self.paperRect, nil)
        let pageCount = renderer.numberOfPages
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pageCount))
        for page in 0..<pageCount {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        guard pageCount > 0 else { throw RenderError.empty }
        return data as Data
    }

    /// 所有结束路径（完成、失败、进程退出、超时）只 resume 一次。
    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(RenderError.webContentTerminated))
    }
}

