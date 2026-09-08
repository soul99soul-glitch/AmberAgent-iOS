import SwiftUI
import XCTest
@testable import iosApp

/// Captures production settings at compact widths and large text sizes.
/// Screenshots need visual review; fitting the viewport alone is not sufficient.
@MainActor
final class IOSMiniAppVisualEvidenceTests: XCTestCase {
    func testDisabledSystemPermissionRowsAtCompactWidths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MiniAppGrantsVisual.\(UUID().uuidString)")
        let repository = IOSMiniAppRepository(baseDirectory: root, seedOnMissingStore: false)
        let app = try repository.saveGenerated(IOSMiniAppGeneratedOutput(
            title: "系统能力检查", description: "权限布局",
            permissions: ["haptics", "device", "screen", "speech", "share", "openURL"],
            html: "<!doctype html><html><body>test</body></html>"
        ))
        for permission in app.permissions {
            try repository.setGrant(appId: app.id, permission: permission, decision: .allow)
        }
        let key = IOSMiniAppBridgePolicy.systemCapabilitiesPreferenceKey
        let previousSetting = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            if let previousSetting { UserDefaults.standard.set(previousSetting, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        for (name, typeSize) in [("compact", DynamicTypeSize.large), ("accessibility", .accessibility3)] {
            let runner = MiniAppRunnerView(appId: app.id, repository: repository)
            let size = CGSize(width: 320, height: 780)
            let host = UIHostingController(rootView: ScrollView { runner.grantsSection(app) }
                .background(AmberTheme.background)
                .environment(\.dynamicTypeSize, typeSize))
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            XCTAssertLessThanOrEqual(host.sizeThatFits(in: size).width, size.width + 1)
            try capture(host.view, size: size, name: "miniapp-permissions-\(name)")
        }
    }

    func testSettingsAtCompactWidthsAndAccessibilitySizes() async throws {
        let suite = "MiniAppVisual.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            defaults.removePersistentDomain(forName: suite)
        }
        for (name, width, typeSize, locale) in [
            ("compact", CGFloat(320), DynamicTypeSize.large, "zh_Hans"),
            ("accessibility", CGFloat(320), DynamicTypeSize.accessibility3, "zh_Hans"),
            ("regular", CGFloat(393), DynamicTypeSize.large, "zh_Hans"),
            ("english", CGFloat(320), DynamicTypeSize.large, "en"),
        ] {
            let size = CGSize(width: width, height: 780)
            let host = UIHostingController(rootView: MiniAppSettingsView(sharedSettings: settings)
                .defaultAppStorage(defaults)
                .environment(\.dynamicTypeSize, typeSize)
                .environment(\.locale, Locale(identifier: locale)))
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            XCTAssertLessThanOrEqual(host.sizeThatFits(in: size).width, width + 1)
            try capture(host.view, size: size, name: "miniapp-settings-\(name)")
            if let scroll = firstScrollView(in: host.view) {
                scroll.setContentOffset(CGPoint(x: 0, y: min(size.height * 0.6,
                    max(0, scroll.contentSize.height - scroll.bounds.height))), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                try capture(host.view, size: size, name: "miniapp-settings-\(name)-scrolled")
            }
        }
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }

    private func capture(_ view: UIView, size: CGSize, name: String) throws {
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: output)
        print("MINIAPP_LAYOUT_EVIDENCE \(output.path)")
    }
}
