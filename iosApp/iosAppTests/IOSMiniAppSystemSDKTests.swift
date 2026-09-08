import JavaScriptCore
@preconcurrency import WebKit
import XCTest

@testable import iosApp

@MainActor
final class IOSMiniAppSystemSDKTests: XCTestCase {
    func testSystemSDKExecutesBootstrapAndSendsNormalizedBridgeRequests() throws {
        let context = try makeContext()
        context.evaluateScript("""
        Amber.getAppInfo();
        Amber.getCapabilities();
        Amber.haptics.impact({style: 'soft', intensity: 0.25});
        Amber.haptics.notification({type: 'warning'});
        Amber.haptics.selection();
        Amber.device.getInfo();
        Amber.device.getBattery();
        Amber.screen.getBrightness();
        Amber.screen.setBrightness(0.4);
        Amber.screen.setKeepAwake({enabled: true});
        Amber.speech.getVoices();
        Amber.speech.speak('hello');
        Amber.speech.stop();
        Amber.speech.pause();
        Amber.speech.resume();
        Amber.share({text: 'hello', url: 'https://example.com'});
        Amber.openURL('https://example.com');
        Amber.qrcode.generate('hello');
        """)

        let calls = try bridgeCalls(in: context)
        XCTAssertEqual(calls.map { $0["method"] as? String }, [
            "app.info",
            "app.capabilities",
            "haptics.impact",
            "haptics.notification",
            "haptics.selection",
            "device.getInfo",
            "device.getBattery",
            "screen.getBrightness",
            "screen.setBrightness",
            "screen.setKeepAwake",
            "speech.getVoices",
            "speech.speak",
            "speech.stop",
            "speech.pause",
            "speech.resume",
            "share",
            "openURL",
            "qrcode.generate",
        ])

        let impact = calls[2]["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(impact["style"] as? String, "soft")
        XCTAssertEqual((impact["intensity"] as? NSNumber)?.doubleValue, 0.25)
        let brightness = calls[8]["params"] as? [String: Any] ?? [:]
        XCTAssertEqual((brightness["brightness"] as? NSNumber)?.doubleValue, 0.4)
        let keepAwake = calls[9]["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(keepAwake["enabled"] as? Bool, true)
        let speak = calls[11]["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(speak["text"] as? String, "hello")
        XCTAssertNil(speak["rate"], "native owns speech defaults")
        let url = calls[16]["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(url["url"] as? String, "https://example.com")
        let qrCode = calls[17]["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(qrCode["text"] as? String, "hello")
        XCTAssertNil(qrCode["size"], "native owns QR defaults")
    }

    func testSystemSDKRejectsScalarObjectParamsWithoutPostingToNative() throws {
        let context = try makeContext()
        context.evaluateScript("""
        window.__invalidMessage = null;
        Amber.haptics.impact(false).catch(function(error) {
          window.__invalidMessage = String(error && error.message || error);
        });
        """)

        let deadline = Date().addingTimeInterval(0.2)
        var message: String?
        while Date() < deadline {
            message = context.evaluateScript("window.__invalidMessage")?.toString()
            if message != "null" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(message?.hasSuffix("Bridge params must be an object") == true)
        XCTAssertTrue(try bridgeCalls(in: context).isEmpty)
    }

    func testWKBridgeRoundTripRejectsArrayParamsBeforeSystemHandler() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-miniapp-system-sdk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = IOSMiniAppRepository(baseDirectory: directory, seedOnMissingStore: false)
        let app = try repository.saveGenerated(IOSMiniAppGeneratedOutput(
            title: "系统能力",
            description: "测试",
            permissions: ["haptics"],
            html: "<!doctype html><html><body></body></html>"
        ))
        var systemCalls = 0
        let runtime = IOSMiniAppBridgeRuntime(
            appId: app.id,
            repository: repository,
            grantHandler: { _ in true },
            systemHandler: { method, _ in
                XCTAssertEqual(method, "haptics.selection")
                systemCalls += 1
                return .bool(true)
            }
        )
        let bridge = MiniAppBridge(runtime: runtime)
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(bridge, name: "amberNative")
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        bridge.attach(webView: webView)
        bridge.setTrustedMainDocument(true)
        let loaded = expectation(description: "MiniApp document loaded")
        let navigationDelegate = NavigationProbe { loaded.fulfill() }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString("""
        <!doctype html><html><body><script>
        window.__responses = [];
        window.AmberBridge = {_handleNativeResponse: function(response) { window.__responses.push(response); }};
        function send(request) { window.webkit.messageHandlers.amberNative.postMessage(JSON.stringify(request)); }
        </script></body></html>
        """, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 5)

        _ = try await webView.evaluateJavaScript("send({id:'selection',method:'haptics.selection',params:{}});")
        try await waitForResponseCount(1, in: webView)
        XCTAssertEqual(systemCalls, 1)
        let firstResponse = try await webView.evaluateJavaScript("window.__responses[0].result") as? Bool
        XCTAssertEqual(firstResponse, true)

        _ = try await webView.evaluateJavaScript("send({id:'array',method:'haptics.selection',params:[]});")
        try await waitForResponseCount(2, in: webView)
        XCTAssertEqual(systemCalls, 1, "array params must be rejected before native systemHandler")
        let secondError = try await webView.evaluateJavaScript("window.__responses[1].error") as? String
        XCTAssertEqual(secondError, "invalid request (params must be an object)")

        bridge.close()
        webView.stopLoading()
    }

    func testWKBridgeDropsLateHandlerResponseAfterTrustedDocumentChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-miniapp-stale-document-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = IOSMiniAppRepository(baseDirectory: directory, seedOnMissingStore: false)
        let app = try repository.saveGenerated(IOSMiniAppGeneratedOutput(
            title: "迟到响应",
            description: "测试",
            permissions: ["haptics"],
            html: "<!doctype html><html><body></body></html>"
        ))
        let handlerStarted = expectation(description: "system handler started")
        var handlerContinuation: CheckedContinuation<IOSMiniAppJSONValue, Error>?
        let runtime = IOSMiniAppBridgeRuntime(
            appId: app.id,
            repository: repository,
            grantHandler: { _ in true },
            systemHandler: { _, _ in
                handlerStarted.fulfill()
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<IOSMiniAppJSONValue, Error>) in
                    handlerContinuation = continuation
                }
            }
        )
        let bridge = MiniAppBridge(runtime: runtime)
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(bridge, name: "amberNative")
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        bridge.attach(webView: webView)
        bridge.setTrustedMainDocument(true)
        defer {
            if let continuation = handlerContinuation {
                handlerContinuation = nil
                continuation.resume(throwing: CancellationError())
            }
            bridge.close()
            webView.stopLoading()
        }

        let firstLoaded = expectation(description: "first MiniApp document loaded")
        let secondLoaded = expectation(description: "second MiniApp document loaded")
        var loadCount = 0
        let navigationDelegate = NavigationProbe {
            loadCount += 1
            if loadCount == 1 {
                firstLoaded.fulfill()
            } else if loadCount == 2 {
                secondLoaded.fulfill()
            }
        }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString("""
        <!doctype html><html><body><script>
        window.__responses = [];
        window.AmberBridge = {_handleNativeResponse: function(response) { window.__responses.push(response); }};
        function send() { window.webkit.messageHandlers.amberNative.postMessage(JSON.stringify({id:'old-request',method:'haptics.selection',params:{}})); }
        </script></body></html>
        """, baseURL: nil)
        await fulfillment(of: [firstLoaded], timeout: 5)

        _ = try await webView.evaluateJavaScript("send();")
        await fulfillment(of: [handlerStarted], timeout: 5)

        bridge.setTrustedMainDocument(false)
        webView.loadHTMLString("""
        <!doctype html><html><body><script>
        window.__responses = [];
        window.AmberBridge = {_handleNativeResponse: function(response) { window.__responses.push(response); }};
        </script></body></html>
        """, baseURL: nil)
        await fulfillment(of: [secondLoaded], timeout: 5)
        bridge.setTrustedMainDocument(true)

        let continuation = handlerContinuation
        handlerContinuation = nil
        continuation?.resume(returning: .bool(true))
        try await Task.sleep(for: .milliseconds(200))
        let responseCount = try await webView.evaluateJavaScript("window.__responses.length") as? NSNumber
        XCTAssertEqual(responseCount?.intValue, 0, "a request from the previous document must not answer in the new document")

    }

    func testWKBridgeLogsOnlySafeMethodStatusForSensitiveRequestsAndEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-miniapp-safe-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = IOSMiniAppRepository(baseDirectory: directory, seedOnMissingStore: false)
        let app = try repository.saveGenerated(IOSMiniAppGeneratedOutput(
            title: "安全日志",
            description: "测试",
            permissions: ["share", "eventBus"],
            html: "<!doctype html><html><body></body></html>"
        ))
        let runtime = IOSMiniAppBridgeRuntime(
            appId: app.id,
            repository: repository,
            grantHandler: { _ in true },
            systemHandler: { method, _ in
                XCTAssertEqual(method, "share")
                return .object(["secret": .string("SECRET_RESPONSE_PAYLOAD")])
            }
        )
        let bridge = MiniAppBridge(runtime: runtime)
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(bridge, name: "amberNative")
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        bridge.attach(webView: webView)
        bridge.setTrustedMainDocument(true)
        let loaded = expectation(description: "MiniApp document loaded")
        let navigationDelegate = NavigationProbe { loaded.fulfill() }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString("""
        <!doctype html><html><body><script>
        window.__responses = [];
        window.__events = [];
        window.__published = false;
        function send(request) { window.webkit.messageHandlers.amberNative.postMessage(JSON.stringify(request)); }
        window.AmberBridge = {
          _handleNativeResponse: function(response) {
            window.__responses.push(response);
            if (response.id === 'subscribe' && !window.__published) {
              window.__published = true;
              send({id:'publish-secret-request-id',method:'eventBus.publish',params:{topic:'secret-topic',payload:{secret:'SECRET_EVENT_PAYLOAD'}}});
            }
          },
          _emitNativeEvent: function(event) { window.__events.push(event); }
        };
        </script></body></html>
        """, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 5)

        _ = try await webView.evaluateJavaScript("""
        send({id:'share-secret-request-id',method:'share',params:{text:'SECRET_SHARE_TEXT',url:'https://example.com/?token=SECRET_URL_TOKEN'}});
        send({id:'subscribe',method:'eventBus.subscribe',params:{topic:'secret-topic'}});
        send({id:'unknown-secret-request-id',method:'SECRET_METHOD_NAME',params:{secret:'SECRET_UNKNOWN_PAYLOAD'}});
        """)
        try await waitForResponseCount(4, in: webView)
        try await waitForEventCount(1, in: webView)

        let logs = bridge.log.joined(separator: "\n")
        for secret in [
            "share-secret-request-id",
            "SECRET_SHARE_TEXT",
            "SECRET_URL_TOKEN",
            "SECRET_RESPONSE_PAYLOAD",
            "SECRET_EVENT_PAYLOAD",
            "publish-secret-request-id",
            "secret-topic",
            "unknown-secret-request-id",
            "SECRET_METHOD_NAME",
            "SECRET_UNKNOWN_PAYLOAD",
        ] {
            XCTAssertFalse(logs.contains(secret), "bridge log leaked sensitive value: \(secret)")
        }
        XCTAssertTrue(logs.contains("◀ postMessage: share"))
        XCTAssertTrue(logs.contains("▶ onResponse: share success"))
        XCTAssertTrue(logs.contains("◀ postMessage: eventBus.subscribe"))
        XCTAssertTrue(logs.contains("◀ postMessage: unknown"))
        XCTAssertTrue(logs.contains("▶ event: eventBus delivered"))

        bridge.close()
        webView.stopLoading()
    }

    private func waitForResponseCount(_ expected: Int, in webView: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let result = try? await webView.evaluateJavaScript("window.__responses.length")
            let count = (result as? NSNumber)?.intValue ?? (result as? Int ?? 0)
            if count >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(expected) bridge responses")
    }

    private func waitForEventCount(_ expected: Int, in webView: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let result = try? await webView.evaluateJavaScript("window.__events.length")
            let count = (result as? NSNumber)?.intValue ?? (result as? Int ?? 0)
            if count >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(expected) bridge events")
    }

    private func makeContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("bootstrap JavaScript exception: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript("""
        var window = globalThis;
        window.__amberCalls = [];
        window.webkit = {messageHandlers: {amberNative: {
          postMessage: function(message) { window.__amberCalls.push(JSON.parse(message)); }
        }}};
        window.console = {log: function(){}, error: function(){}};
        var console = window.console;
        """)
        context.evaluateScript(try bootstrapSource())
        return context
    }

    private func bridgeCalls(in context: JSContext) throws -> [[String: Any]] {
        let json = try XCTUnwrap(context.evaluateScript("JSON.stringify(window.__amberCalls)")?.toString())
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func bootstrapSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("iosApp/MiniAppRunnerWebView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let opening = try XCTUnwrap(source.range(of: "let bootstrap = \"\"\""))
        let bodyStart = opening.upperBound
        let bodyEnd = try XCTUnwrap(source.range(of: "\"\"\"", range: bodyStart..<source.endIndex))
        var script = String(source[bodyStart..<bodyEnd.lowerBound])
        if script.first == "\n" { script.removeFirst() }
        return script
    }
}

@MainActor
private final class NavigationProbe: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
}
