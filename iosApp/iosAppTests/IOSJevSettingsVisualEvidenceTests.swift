import SwiftUI
import XCTest
@preconcurrency import Shared
@testable import iosApp

// Jev 设置页视觉证据：真实渲染窗口并落盘 PNG（默认/辅助功能大字号/窄屏），
// 供逐像素 UI 审查与回归留档。沿 IOSAgentSettingsVisualEvidenceTests 模式。

@MainActor
final class IOSJevSettingsVisualEvidenceTests: XCTestCase {

    func testJevSettingsLayoutEvidence() async throws {
        let suite = "JevSettingsVisual.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let languageKey = IOSAppLanguagePreference.defaultsKey
        let previousLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("zh-Hans", forKey: languageKey)
        defaults.set("zh-Hans", forKey: IOSAppLanguagePreference.defaultsKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: languageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: languageKey)
            }
        }
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        // 预置一个可见状态：shadow 模式 + 全范围，避免全 off 的空白态掩盖布局问题。
        var jev = settings.jevSettings
        jev.setMode(.shadow, for: .toolDiscovery)
        jev.setMode(.shadow, for: .memoryRecall)
        jev.setMode(.active, for: .modelRouting)
        settings.updateJevSettings(jev)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)

        func capture<V: View>(
            _ view: V,
            name: String,
            type: DynamicTypeSize = .large,
            size: CGSize = CGSize(width: 393, height: 852)
        ) async throws {
            let window = UIWindow(windowScene: scene)
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            let host = UIHostingController(rootView: NavigationStack { view }
                .environment(RouterPath())
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .environment(\.dynamicTypeSize, type)
                .defaultAppStorage(defaults))
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            window.overrideUserInterfaceStyle = .light
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
            try XCTUnwrap(image.pngData()).write(to: output)
            print("JEV_SETTINGS_EVIDENCE \(output.path)")
        }

        // 入口行（运行环境页内的 Jev 行）。
        try await capture(
            ExecutionSettingsView(sharedSettings: settings),
            name: "jev-entry-row"
        )
        // Jev 设置页：默认字号、辅助功能大字号、窄屏。
        try await capture(
            IOSJevSettingsView(sharedSettings: settings),
            name: "jev-settings"
        )
        try await capture(
            IOSJevSettingsView(sharedSettings: settings),
            name: "jev-settings-accessibility1",
            type: .accessibility1
        )
        try await capture(
            IOSJevSettingsView(sharedSettings: settings),
            name: "jev-settings-narrow",
            type: .accessibility3,
            size: CGSize(width: 320, height: 640)
        )
    }
}
