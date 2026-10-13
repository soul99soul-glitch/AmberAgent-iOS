import SwiftUI
import WebKit
import XCTest
@testable import iosApp

@MainActor
final class IOSUIGenerationMotionTests: XCTestCase {
    func testExplicitTargetWinsOverLargeAppAncestor() async throws {
        try await withRuntime { webView in
            _ = try await webView.evaluateJavaScript("""
            const main = document.querySelector('main'); main.setAttribute('data-amber-reveal', '');
            const app = document.createElement('div'); app.id = 'app'; app.style.height = '1400px';
            main.before(app); app.appendChild(main); true;
            """)
            IOSUIGenerationMotion.play(in: webView, selector: "[data-amber-reveal], main, #app", reduceMotion: false)
            try await self.wait(in: webView, for: "document.querySelector('.t-gen') !== null")
            let target = try await webView.evaluateJavaScript("!!document.querySelector('main').__tGen && !document.querySelector('#app').__tGen") as? Bool
            XCTAssertEqual(target, true)
        }
    }

    func testSlowImageWaitsWithoutHidingOrConsumingResult() async throws {
        try await withRuntime(imageDelay: 1.8) { webView in
            _ = try await webView.evaluateJavaScript("""
            const img = document.createElement('img'); img.width = 40; img.height = 40;
            img.src = 'amber-motion-test://image'; document.querySelector('main').appendChild(img); true;
            """)
            var consumed = false
            IOSUIGenerationMotion.play(in: webView, selector: "main", reduceMotion: false) { consumed = $0 }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertFalse(consumed)
            let visible = try await webView.evaluateJavaScript("document.querySelector('main').style.opacity === '0.9' && document.querySelector('.t-gen') === null && !document.querySelector('img').complete") as? Bool
            XCTAssertEqual(visible, true)
            try await self.wait(in: webView, for: "document.querySelector('.t-gen') !== null && document.querySelector('img').complete")
            XCTAssertTrue(consumed)
        }
    }

    func testHiddenDocumentWaitsUntilVisibleBeforeConsuming() async throws {
        try await withRuntime { webView in
            _ = try await webView.evaluateJavaScript("window.testHidden = true; Object.defineProperty(document, 'hidden', {get: () => window.testHidden}); true;")
            var consumed = false
            IOSUIGenerationMotion.play(in: webView, selector: "main", reduceMotion: false) { consumed = $0 }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(consumed)
            _ = try await webView.evaluateJavaScript("window.testHidden = false; document.dispatchEvent(new Event('visibilitychange'));")
            try await self.wait(in: webView, for: "document.querySelector('.t-gen') !== null")
            XCTAssertTrue(consumed)
        }
    }

    func testCancelWhileHiddenAndWaitingForImageCompletesRequest() async throws {
        try await withRuntime(imageDelay: 1.8) { webView in
            _ = try await webView.evaluateJavaScript("""
            const img = document.createElement('img'); img.width = 40; img.height = 40;
            img.src = 'amber-motion-test://image'; document.querySelector('main').appendChild(img); true;
            """)
            var consumed = false
            IOSUIGenerationMotion.play(in: webView, selector: "main", reduceMotion: false) { consumed = $0 }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertFalse(consumed)
            _ = try await webView.evaluateJavaScript("Object.defineProperty(document, 'hidden', {get: () => true}); document.dispatchEvent(new Event('visibilitychange')); true;")
            IOSUIGenerationMotion.cancel(in: webView)
            for _ in 0..<20 where !consumed { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(consumed)
            let visible = try await webView.evaluateJavaScript("document.querySelector('.t-gen') === null && document.querySelector('main').style.opacity === '0.9'") as? Bool
            XCTAssertEqual(visible, true)
        }
    }

    func testStalledImageEndsAttemptWithoutHidingResult() async throws {
        try await withRuntime(imageDelay: 6) { webView in
            _ = try await webView.evaluateJavaScript("""
            const img = document.createElement('img'); img.width = 40; img.height = 40;
            img.src = 'amber-motion-test://image'; document.querySelector('main').appendChild(img); true;
            """)
            var consumed = false
            IOSUIGenerationMotion.play(in: webView, selector: "main", reduceMotion: false) { consumed = $0 }
            for _ in 0..<90 where !consumed { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(consumed)
            let visible = try await webView.evaluateJavaScript("document.querySelector('.t-gen') === null && document.querySelector('main').style.opacity === '0.9' && !document.querySelector('img').complete") as? Bool
            XCTAssertEqual(visible, true)
        }
    }

    func testFullHTMLRevealsRealPageAndHistoryDoesNotReplay() async throws {
        let model = MotionCardFixture()
        let host = UIHostingController(rootView: MotionFullHTMLFixtureView(model: model))
        let (window, previous) = try show(host)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let preview = try await findWebView(in: host.view)
        try await wait(in: preview, for: "document.querySelector('#root svg') !== null")
        model.streaming = false
        model.complete = true
        try await Task.sleep(for: .milliseconds(150))
        let actual = try await openFullHTML(from: preview, host: host)
        try await wait(in: actual, for: "document.querySelector('main h2')?.textContent === 'Actual result' && document.querySelector('.t-gen') !== null")
        try await capture(actual, name: "amber-full-html-wireframe")
        try await wait(in: actual, for: "document.querySelector('.t-gen') === null && document.querySelector('main').style.opacity === ''")

        host.dismiss(animated: false)
        window.rootViewController = nil
        let historicalHost = UIHostingController(rootView: MotionFullHTMLFixtureView(model: model))
        window.rootViewController = historicalHost
        let historicalPreview = try await findWebView(in: historicalHost.view)
        try await wait(in: historicalPreview, for: "document.querySelector('#root svg') !== null")
        let historicalPage = try await openFullHTML(from: historicalPreview, host: historicalHost)
        try await wait(in: historicalPage, for: "document.querySelector('main h2') !== null")
        try await Task.sleep(for: .milliseconds(400))
        let noReplay = try await historicalPage.evaluateJavaScript("document.querySelector('.t-gen') === null && document.querySelector('main').style.opacity === ''") as? Bool
        XCTAssertEqual(noReplay, true)
    }

    private func openFullHTML(from preview: WKWebView, host: UIViewController) async throws -> WKWebView {
        _ = try await preview.evaluateJavaScript("window.webkit.messageHandlers.amberWidget.postMessage({type:'tap'}); true;")
        for _ in 0..<80 {
            if let presented = host.presentedViewController { return try await findWebView(in: presented.view) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "MotionTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "Full HTML presentation missing"])
    }

    func testOnlyLiveCompletedResultsRevealOnce() {
        var history = IOSUIGenerationRevealState()
        XCTAssertFalse(history.update(isStreaming: false, complete: true))
        var live = IOSUIGenerationRevealState()
        XCTAssertFalse(live.update(isStreaming: true, complete: false))
        XCTAssertFalse(live.update(isStreaming: true, complete: true))
        XCTAssertTrue(live.update(isStreaming: false, complete: true))
        XCTAssertFalse(live.update(isStreaming: false, complete: true))
        var partial = IOSUIGenerationRevealState()
        XCTAssertFalse(partial.update(isStreaming: true, complete: false))
        XCTAssertFalse(partial.update(isStreaming: false, complete: false))
    }

    func testLiveCardCompletionRevealsWithoutResizingAndHistoryDoesNotReplay() async throws {
        let model = MotionCardFixture()
        let host = UIHostingController(rootView: MotionCardFixtureView(model: model))
        let (window, previous) = try show(host)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let webView = try await findWebView(in: host.view)
        try await wait(in: webView, for: "document.querySelector('#root h2') !== null")
        for _ in 0..<40 where webView.frame.height < 260 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(webView.frame.height, 260)
        let initialHeight = webView.frame.height
        model.streaming = false
        model.complete = true
        try await wait(in: webView, for: "document.querySelector('.t-gen') !== null")
        XCTAssertEqual(webView.frame.height, initialHeight, accuracy: 2)
        try await Task.sleep(for: .milliseconds(700))
        try await capture(webView, name: "amber-ui-wireframe")
        try await wait(in: webView, for: "document.querySelector('.t-gen') === null && document.querySelector('#root').style.opacity === ''")
        XCTAssertEqual(webView.frame.height, initialHeight, accuracy: 2)
        try await capture(webView, name: "amber-ui-result")

        let historicalHost = UIHostingController(rootView: MotionCardFixtureView(model: model))
        window.rootViewController = historicalHost
        let historicalWebView = try await findWebView(in: historicalHost.view)
        try await wait(in: historicalWebView, for: "document.querySelector('#root h2') !== null")
        try await Task.sleep(for: .milliseconds(400))
        let noAnimation = try await historicalWebView.evaluateJavaScript("document.querySelector('.t-gen') === null && document.querySelector('#root').style.opacity === ''") as? Bool
        XCTAssertEqual(noAnimation, true)
    }

    func testInteractionCancelsAndRestoresStylesWithoutReplay() async throws {
        try await withRuntime { webView in
            IOSUIGenerationMotion.play(in: webView, selector: "main", reduceMotion: false)
            try await self.wait(in: webView, for: "document.querySelector('.t-gen') !== null")
            _ = try await webView.evaluateJavaScript("window.dispatchEvent(new Event('pointerdown')); document.querySelector('button').click();")
            try await self.wait(in: webView, for: "document.querySelector('.t-gen') === null")
            let restored = try await webView.evaluateJavaScript("document.querySelector('main').style.opacity === '0.9' && document.querySelector('button').textContent === 'Done'") as? Bool
            XCTAssertEqual(restored, true)
            IOSUIGenerationMotion.play(in: webView, selector: "main", reduceMotion: false)
            try await Task.sleep(for: .milliseconds(350))
            let noReplay = try await webView.evaluateJavaScript("document.querySelector('.t-gen') === null") as? Bool
            XCTAssertEqual(noReplay, true)
        }
    }

    func testReducedMotionLeavesContentVisible() async throws {
        try await withRuntime { webView in
            IOSUIGenerationMotion.play(in: webView, selector: "main", reduceMotion: true)
            try await Task.sleep(for: .milliseconds(350))
            let visible = try await webView.evaluateJavaScript("document.querySelector('.t-gen') === null && document.querySelector('main').style.opacity === '0.9'") as? Bool
            XCTAssertEqual(visible, true)
        }
    }

    func testResizeCancelsOverlayAndRestoresResult() async throws {
        try await withRuntime { webView in
            IOSUIGenerationMotion.play(in: webView, selector: "main", reduceMotion: false)
            try await self.wait(in: webView, for: "document.querySelector('.t-gen') !== null")
            _ = try await webView.evaluateJavaScript("document.querySelector('main').style.height = '360px';")
            try await self.wait(in: webView, for: "document.querySelector('.t-gen') === null && document.querySelector('main').style.opacity === '0.9'")
        }
    }

    private func withRuntime(imageDelay: TimeInterval = 0, _ body: (WKWebView) async throws -> Void) async throws {
        let config = WKWebViewConfiguration()
        IOSUIGenerationMotion.install(in: config.userContentController)
        if imageDelay > 0 { config.setURLSchemeHandler(MotionTestImageHandler(delay: imageDelay), forURLScheme: "amber-motion-test") }
        let webView = WKWebView(frame: .zero, configuration: config)
        let controller = UIViewController()
        controller.view = webView
        let (window, previous) = try show(controller)
        defer { webView.stopLoading(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        webView.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:16px;font:16px -apple-system}main{height:280px;padding:20px;background:#eee;border-radius:16px;box-sizing:border-box}button{height:44px}</style>
        </head><body><main style="opacity:0.9"><h2>Result</h2><p>A generated card</p><button onclick="this.textContent='Done'">Continue</button></main></body></html>
        """, baseURL: nil)
        try await wait(in: webView, for: "typeof window.__amberGenerationPlay === 'function'")
        try await body(webView)
    }

    private func show(_ controller: UIViewController) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 780)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        return (window, previous)
    }

    private func findWebView(in view: UIView) async throws -> WKWebView {
        func find(_ node: UIView) -> WKWebView? {
            if let webView = node as? WKWebView { return webView }
            return node.subviews.lazy.compactMap(find).first
        }
        for _ in 0..<100 {
            if let webView = find(view) { return webView }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "MotionTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Card WebView missing"])
    }

    private func wait(in webView: WKWebView, for condition: String) async throws {
        for _ in 0..<120 {
            if (try? await webView.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out: \(condition)")
        throw NSError(domain: "MotionTest", code: 2)
    }

    private func capture(_ webView: WKWebView, name: String) async throws {
        let image = try await webView.takeSnapshot(configuration: nil)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("UI_GENERATION_EVIDENCE \(url.path)")
    }
}

@MainActor
private final class MotionTestImageHandler: NSObject, WKURLSchemeHandler {
    let delay: TimeInterval
    private var pending: [ObjectIdentifier: DispatchWorkItem] = [:]
    init(delay: TimeInterval) { self.delay = delay }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        let work = DispatchWorkItem { [weak self] in
            guard self?.pending.removeValue(forKey: id) != nil else { return }
            let data = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { context in
                UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            task.didReceive(URLResponse(url: task.request.url!, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }
        pending[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        pending.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }
}

private struct MotionFullHTMLFixtureView: View {
    let model: MotionCardFixture
    private let spec = #"{"html":"<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:16px;font:16px -apple-system}main{height:240px;padding:24px;border-radius:16px;background:#eee;box-sizing:border-box}</style></head><body><main data-amber-reveal><h2>Actual result</h2><p>Interactive page content</p><button onclick='this.textContent=42'>Continue</button></main></body></html>"}"#
    var body: some View {
        IOSGenerativeWidgetCard(widget: IOSGenerativeWidget(id: "full-html-motion", title: "Full HTML",
            widgetCode: IOSGenerativeWidgetRenderer().render(renderer: "full_html", specJson: spec)!,
            complete: model.complete, renderer: "full_html", specJson: spec), isStreaming: model.streaming)
        .padding(16)
    }
}

@MainActor @Observable
private final class MotionCardFixture {
    var streaming = true
    var complete = false
}

private struct MotionCardFixtureView: View {
    let model: MotionCardFixture
    var body: some View {
        IOSGenerativeWidgetCard(widget: IOSGenerativeWidget(id: "motion-test", title: "活动概览", widgetCode: """
        <section style="padding:24px;background:#f7f8fa;border-radius:16px;height:260px;box-sizing:border-box;font-family:-apple-system">
        <h2 style="margin:0;font-size:18px">本周活动</h2><p style="font-size:42px;margin:16px 0">8,240 <span style="font-size:14px">步</span></p>
        <div style="display:flex;gap:8px;align-items:end;height:70px"><div style="width:40px;height:32px;background:#5f83ef;border-radius:5px"></div><div style="width:40px;height:54px;background:#5f83ef;border-radius:5px"></div><div style="width:40px;height:68px;background:#5f83ef;border-radius:5px"></div><div style="width:40px;height:44px;background:#5f83ef;border-radius:5px"></div></div>
        </section>
        """, complete: model.complete), isStreaming: model.streaming)
        .padding(16)
    }
}
