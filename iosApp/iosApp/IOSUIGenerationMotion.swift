import Foundation
@preconcurrency import WebKit

/// Host-owned decoration; generated HTML never needs script or network privileges.
@MainActor
enum IOSUIGenerationMotion {
    // Upstream assets are unchanged at Jakubantalik/transitions.dev a0c6e7bbf603a0a46588e37c6c6a4d0af3290d52.
    private static let script: String? = {
        func read(_ name: String, _ ext: String) -> String? {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "generative-libs")
                ?? Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        guard let runtime = read("ui-generation", "js"),
              let css = read("ui-generation", "css"),
              let host = read("amber-ui-generation", "js"),
              let encodedCSS = try? JSONEncoder().encode(css),
              let cssLiteral = String(data: encodedCSS, encoding: .utf8) else {
            NSLog("Amber UI generation assets missing; showing content without decoration")
            return nil
        }
        // WKUserScript is a classic script; only remove the two ES module export keywords.
        return """
        (() => {
        const style = document.createElement('style');
        style.textContent = \(cssLiteral) + '\\n.t-gen { overflow: clip; contain: layout paint; }';
        document.head.appendChild(style);
        \(runtime.replacingOccurrences(of: "export function ", with: "function "))
        \(host)
        })();
        """
    }()

    static func install(in controller: WKUserContentController) {
        guard let script else { return }
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    static func play(in webView: WKWebView, selector: String, reduceMotion: Bool,
                     completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        webView.callAsyncJavaScript(
            "return await window.__amberGenerationPlay?.(selector, reduceMotion);",
            arguments: ["selector": selector, "reduceMotion": reduceMotion],
            in: nil, in: .page
        ) { result in
            switch result {
            case .success(let value): completion(value as? Bool == true)
            case .failure(let error):
                NSLog("Amber UI reveal failed: %@", error.localizedDescription)
                completion(false)
            }
        }
    }

    static func cancel(in webView: WKWebView) {
        webView.evaluateJavaScript("window.__amberGenerationCancel?.();", completionHandler: nil)
    }
}

/// History starts complete and must never replay an entrance animation.
struct IOSUIGenerationRevealState {
    private var sawStreaming = false
    private var consumed = false

    mutating func update(isStreaming: Bool, complete: Bool) -> Bool {
        sawStreaming = sawStreaming || isStreaming
        guard sawStreaming, !isStreaming, complete, !consumed else { return false }
        consumed = true
        return true
    }
}
