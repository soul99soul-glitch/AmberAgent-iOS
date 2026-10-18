import Foundation
import SwiftUI
import UIKit
import XCTest
import WebKit
@testable import iosApp

@MainActor
final class IOSWebMountDesktopVisualTests: IOSWebMountDesktopTestCase {
    func testDesktopCreationViewVisualEvidence() async throws {
        let client = DesktopMcpClientFake(
            tools: stockPlaywrightTools,
            callResultsByTool: [
                "browser_navigate": stockPlaywrightPageState(url: "https://news.ycombinator.com/")
            ]
        )
        let (controller, _) = try await connectedRemoteController(client: client)
        let suite = "WebMountDesktopVisual.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configStore = IOSMcpConfigStore(userDefaults: defaults)
        configStore.add(makeConfig(tools: stockPlaywrightTools))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        defer { previousWindow?.makeKey() }

        for size in [CGSize(width: 393, height: 852), CGSize(width: 320, height: 640)] {
            let manager = IOSMcpManager(
                serverProvider: { configStore.servers },
                clientFactory: { _ in DesktopMcpClientFake(tools: self.stockPlaywrightTools) }
            )
            let view = WebMountDesktopBackendsView(
                controller: controller,
                configStore: configStore,
                initialBackend: .playwright_mcp,
                mcpManager: manager
            )
            let host = UIHostingController(rootView: NavigationStack { view }
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .environment(\.dynamicTypeSize, .large)
                .defaultAppStorage(defaults))
            let window = UIWindow(windowScene: scene)
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousWindow?.makeKey()
            }
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            window.overrideUserInterfaceStyle = .light
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            XCTAssertEqual(window.bounds.size, size)
            XCTAssertEqual(host.view.bounds.size, size)

            func capture(_ position: String) throws {
                let name = "webmount-desktop-creation-\(Int(size.width))-\(position)"
                let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
                try XCTUnwrap(image.pngData()).write(to: output)
                print("WEBMOUNT_DESKTOP_EVIDENCE width=\(Int(size.width)) path=\(output.path) bounds=\(window.bounds)")
            }
            try capture("top")
            let scrollView = try XCTUnwrap(firstScrollView(in: host.view))
            XCTAssertLessThanOrEqual(scrollView.contentSize.width, window.bounds.width + 1)
            let maximumOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            scrollView.setContentOffset(
                CGPoint(x: 0, y: min(maximumOffset, size.height * 0.75)),
                animated: false
            )
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
            try capture("creation-controls")
        }
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for child in view.subviews {
            if let scrollView = firstScrollView(in: child) { return scrollView }
        }
        return nil
    }

}
