@preconcurrency import WebKit
import XCTest
@testable import iosApp

@MainActor
final class IOSMiniAppDocumentLifecycleTests: XCTestCase {
    func testImageProxySettlesAfterInitialAndDynamicDOMChanges() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            MiniAppImageFixtureHandler(),
            forURLScheme: IOSMiniAppImageSchemeHandler.scheme
        )
        // Stop an observer that feeds its own writes back into its callback so
        // a regression produces an assertion instead of hanging WebKit/XCTest.
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            (function() {
              var NativeObserver = window.MutationObserver;
              window.__imageObserverCallbacks = 0;
              window.__imageObserverRecords = 0;
              window.__imageObserverGuarded = false;
              window.MutationObserver = function(callback) {
                return new NativeObserver(function(records, observer) {
                  window.__imageObserverCallbacks += 1;
                  window.__imageObserverRecords += records.length;
                  if (window.__imageObserverCallbacks > 32 || window.__imageObserverRecords > 64) {
                    window.__imageObserverGuarded = true;
                    observer.disconnect();
                    return;
                  }
                  callback(records, observer);
                });
              };
            })();
            """ + "\n" + IOSMiniAppImageSchemeHandler.bootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer { webView.stopLoading() }
        let html = """
        <!doctype html><html><head>
        <style id="theme">.art{background-image:url('https://example.invalid/theme.png')}</style>
        </head><body>
        <img id="photo" src="https://example.invalid/first.png"
             srcset="https://example.invalid/one.png 1x, https://example.invalid/two.png 2x">
        <div id="plain" style="color:red">Ready</div>
        <script>
        function snapshot() {
          return {
            guarded: window.__imageObserverGuarded,
            callbacks: window.__imageObserverCallbacks,
            src: document.getElementById('photo').getAttribute('src'),
            srcset: document.getElementById('photo').getAttribute('srcset'),
            style: document.getElementById('plain').getAttribute('style'),
            sheet: document.getElementById('theme').textContent
          };
        }
        document.addEventListener('DOMContentLoaded', function() {
          setTimeout(function() {
            window.__initialImageState = snapshot();
            var photo = document.getElementById('photo');
            photo.src = 'https://example.invalid/dynamic.png';
            photo.srcset = 'https://example.invalid/dynamic-one.png 1x';
            document.getElementById('plain').style.backgroundImage =
              'url("https://example.invalid/dynamic-bg.png")';
            setTimeout(function() { window.__dynamicImageState = snapshot(); }, 0);
          }, 0);
        });
        </script></body></html>
        """
        webView.loadHTMLString(
            IOSMiniAppHTMLSandbox.enforceBridgeOnlyNetwork(html, allowExternalImages: true),
            baseURL: nil
        )

        let dynamic = try await waitForObject("window.__dynamicImageState", in: webView)
        let initialValue = try await webView.evaluateJavaScript("window.__initialImageState")
        let initial = try XCTUnwrap(initialValue as? [String: Any])
        for state in [initial, dynamic] {
            XCTAssertEqual(state["guarded"] as? Bool, false,
                "Image rewrites must settle without the test disconnecting the observer")
            XCTAssertLessThan(try XCTUnwrap(state["callbacks"] as? Int), 32)
            XCTAssertTrue(try XCTUnwrap(state["src"] as? String).hasPrefix("amber-miniapp-image://"))
            XCTAssertTrue(try XCTUnwrap(state["srcset"] as? String).contains("amber-miniapp-image://"))
            XCTAssertTrue(try XCTUnwrap(state["sheet"] as? String).contains("amber-miniapp-image://"))
        }
        let initialSrcset = try XCTUnwrap(initial["srcset"] as? String)
        XCTAssertTrue(initialSrcset.contains("one.png 1x"))
        XCTAssertTrue(initialSrcset.hasSuffix("two.png 2x"))
        XCTAssertTrue(try XCTUnwrap(dynamic["src"] as? String).contains("dynamic.png"))
        XCTAssertTrue(try XCTUnwrap(dynamic["srcset"] as? String).hasSuffix("dynamic-one.png 1x"))
        XCTAssertTrue(try XCTUnwrap(dynamic["style"] as? String).contains("amber-miniapp-image://"))
        XCTAssertTrue(try XCTUnwrap(dynamic["style"] as? String).contains("dynamic-bg.png"))
    }

    func testTrustLossReleasesDocumentSubscriptionsAndAllowsANewDocument() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniapp-document-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = IOSMiniAppRepository(baseDirectory: directory, seedOnMissingStore: false)
        let app = try repository.saveGenerated(IOSMiniAppGeneratedOutput(
            title: "Sensor lifecycle", description: "Test", permissions: ["sensor", "eventBus"],
            html: "<!doctype html><html><body>Sensor</body></html>"
        ))
        for permission in app.permissions {
            try repository.setGrant(appId: app.id, permission: permission, decision: .allow)
        }
        var activeSensors = Set<String>()
        var unsubscribed: [String] = []
        let runtime = IOSMiniAppBridgeRuntime(
            appId: app.id,
            repository: repository,
            sensorSubscribeHandler: { id, _, _, _ in _ = activeSensors.insert(id) },
            sensorUnsubscribeHandler: { id in
                activeSensors.remove(id)
                unsubscribed.append(id)
            },
            sensitiveConfirmationHandler: { _, _ in true }
        )
        let bridge = MiniAppBridge(runtime: runtime)
        defer { bridge.close() }
        bridge.setTrustedMainDocument(true)
        let sensor = await runtime.dispatch(method: "sensor.subscribe", params: ["type": "gyroscope"])
        let firstID = try subscriptionID(from: sensor)
        let event = await runtime.dispatch(method: "eventBus.subscribe", params: ["topic": "lifecycle"])
        let eventID = try subscriptionID(from: event)
        XCTAssertEqual(activeSensors, [firstID])

        bridge.setTrustedMainDocument(false)
        XCTAssertTrue(activeSensors.isEmpty, "The old document must release its native sensor")
        XCTAssertEqual(unsubscribed, [firstID])
        let oldEvent = await runtime.dispatch(
            method: "eventBus.unsubscribe", params: ["subscriptionId": eventID]
        )
        XCTAssertEqual(oldEvent.errorMessage, "Unknown EventBus subscription")

        bridge.setTrustedMainDocument(true)
        let nextSensor = await runtime.dispatch(method: "sensor.subscribe", params: ["type": "gyroscope"])
        let nextID = try subscriptionID(from: nextSensor)
        XCTAssertEqual(activeSensors, [nextID], "Trust loss must not permanently close the runtime")
        bridge.close()
        bridge.close()
        XCTAssertTrue(activeSensors.isEmpty)
        XCTAssertEqual(unsubscribed, [firstID, nextID], "Each document subscription is released once")
    }

    private func subscriptionID(from result: IOSMiniAppBridgeDispatchResult) throws -> String {
        guard case .success(.object(let object)) = result else {
            XCTFail("Expected subscription success, got \(result)")
            throw NSError(domain: "MiniAppDocumentLifecycleTests", code: 1)
        }
        return try XCTUnwrap(object["subscriptionId"]?.stringValue)
    }

    private func waitForObject(_ expression: String, in webView: WKWebView) async throws -> [String: Any] {
        for _ in 0..<150 {
            if let value = try? await webView.evaluateJavaScript(expression),
               let object = value as? [String: Any] {
                return object
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("WebKit event loop did not reach \(expression)")
        throw NSError(domain: "MiniAppDocumentLifecycleTests", code: 2)
    }
}

@MainActor
private final class MiniAppImageFixtureHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let data = Data("<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'></svg>".utf8)
        guard let url = urlSchemeTask.request.url else { return }
        urlSchemeTask.didReceive(URLResponse(
            url: url, mimeType: "image/svg+xml", expectedContentLength: data.count, textEncodingName: "utf-8"
        ))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
