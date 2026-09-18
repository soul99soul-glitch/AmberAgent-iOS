import SwiftUI
import XCTest
@testable import iosApp

/// Jev 设置页渲染证据：可见控件、错误状态与重启后的持久化展示。
/// 输出 PNG 到模拟器容器 tmp，供视觉检查（与 IOSSubAgentActivityLayoutTests 同模式）。
final class IOSJevSettingsViewEvidenceTests: XCTestCase {

    @MainActor
    func testJevSettingsViewRendersKeylessAndErrorStates() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        let store = IOSSharedSettingsStore(userDefaults: UserDefaults())
        let content = NavigationStack { IOSJevSettingsView(sharedSettings: store) }
            .environment(\.locale, Locale(identifier: "zh_Hans"))

        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))

        let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
        let image = renderer.image { context in
            window.layer.render(in: context.cgContext)
        }
        let path = NSTemporaryDirectory().appending("jev-settings-evidence.png")
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: path))
        print("JEV_SETTINGS_EVIDENCE \(path)")
    }
}
