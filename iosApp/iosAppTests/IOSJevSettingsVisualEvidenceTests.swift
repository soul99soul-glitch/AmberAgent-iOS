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
        jev.setMode(.shadow, for: .phoneVerification)
        jev.setMode(.active, for: .phoneActions)
        settings.updateJevSettings(jev)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)

        func capture<V: View>(
            _ view: V,
            name: String,
            type: DynamicTypeSize = .large,
            size: CGSize = CGSize(width: 393, height: 852),
            language: String = "zh-Hans",
            captureAllPages: Bool = false,
            storage: UserDefaults? = nil
        ) async throws {
            UserDefaults.standard.set(language, forKey: languageKey)
            let window = UIWindow(windowScene: scene)
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            let host = UIHostingController(rootView: NavigationStack { view }
                .environment(RouterPath())
                .environment(\.locale, Locale(identifier: language))
                .environment(\.dynamicTypeSize, type)
                .defaultAppStorage(storage ?? defaults))
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            window.overrideUserInterfaceStyle = .light
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            func savePage(name: String) throws {
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
            try savePage(name: name)
            if captureAllPages {
                let scrollView = try XCTUnwrap(firstScrollView(in: host.view))
                let pageHeight = scrollView.bounds.height
                    - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom
                XCTAssertGreaterThan(pageHeight, 0)
                guard pageHeight > 0 else { return }
                var page = 2
                while scrollView.contentOffset.y + pageHeight < scrollView.contentSize.height - 1 {
                    let oldOffset = scrollView.contentOffset.y
                    scrollView.scrollRectToVisible(
                        CGRect(x: 0, y: oldOffset + pageHeight, width: scrollView.bounds.width, height: pageHeight),
                        animated: false
                    )
                    try await Task.sleep(for: .milliseconds(120))
                    host.view.layoutIfNeeded()
                    guard scrollView.contentOffset.y > oldOffset else { break }
                    try savePage(name: "\(name)-page-\(page)")
                    page += 1
                }
                XCTAssertGreaterThan(page, 2, "手机用途位于初始视口下方，必须捕获滚动页")
            }
        }

        // 入口行（运行环境页内的 Jev 行）。
        try await capture(
            ExecutionSettingsView(sharedSettings: settings),
            name: "jev-entry-row"
        )
        // Jev 设置页：默认字号、辅助功能大字号、窄屏。
        try await capture(
            IOSJevSettingsView(sharedSettings: settings),
            name: "jev-settings",
            captureAllPages: true
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
            size: CGSize(width: 320, height: 640),
            captureAllPages: true
        )
        // 长翻译配合辅助功能字号，检查新用途名称、范围说明和模式菜单。
        try await capture(
            IOSJevSettingsView(sharedSettings: settings),
            name: "jev-settings-russian-accessibility",
            type: .accessibility1,
            size: CGSize(width: 320, height: 640),
            language: "ru",
            captureAllPages: true
        )
        // 加高画幅用于快速浏览；滚动页负责覆盖下方全部用途。
        try await capture(
            IOSJevSettingsView(sharedSettings: settings),
            name: "jev-settings-tall",
            size: CGSize(width: 393, height: 2_700)
        )

        // 每种状态独立存储，前一窗口延后的 onDisappear 提交不能覆盖下一组 fixture。
        func capturePhoneSettings(_ fixture: IOSJevSettings, name: String,
                                  type: DynamicTypeSize = .large, width: CGFloat = 393) async throws {
            let fixtureSuite = "\(suite).\(name)"
            let fixtureDefaults = try XCTUnwrap(UserDefaults(suiteName: fixtureSuite))
            defer { fixtureDefaults.removePersistentDomain(forName: fixtureSuite) }
            let fixtureSettings = IOSSharedSettingsStore(userDefaults: fixtureDefaults)
            fixtureSettings.updateJevSettings(fixture)
            try await capture(
                IOSJevSettingsView(sharedSettings: fixtureSettings),
                name: name,
                type: type,
                size: CGSize(width: width, height: 852),
                captureAllPages: true,
                storage: fixtureDefaults
            )
            // 先让窗口退出回调完成，再清理该场景的独立存储。
            await Task.yield()
            for useCase in [IOSJevUseCase.phoneVerification, .phoneActions] {
                XCTAssertEqual(fixtureSettings.jevSettings.effectiveMode(for: useCase),
                               fixture.effectiveMode(for: useCase),
                               "渲染期间不得被上一窗口的退出提交改写有效模式")
                XCTAssertEqual(fixtureSettings.jevSettings.allowedScopes(for: useCase),
                               fixture.allowedScopes(for: useCase))
            }
        }

        let phoneUseCases: [IOSJevUseCase] = [.phoneVerification, .phoneActions]
        var phoneOff = jev
        for useCase in phoneUseCases {
            phoneOff.setMode(.off, for: useCase)
            phoneOff.setScopes([], for: useCase)
        }
        try await capturePhoneSettings(phoneOff, name: "jev-settings-phone-off")

        var phoneActive = jev
        phoneActive.setPinnedModelVersion("jev-fixed-visual-fixture")
        for useCase in phoneUseCases {
            phoneActive.setMode(.active, for: useCase)
            phoneActive.setScopes(useCase.defaultDataScopes, for: useCase)
            XCTAssertEqual(phoneActive.effectiveMode(for: useCase), .active,
                           "固定版本 fixture 必须展示实际 Active，而非再次降为 Shadow")
        }
        try await capturePhoneSettings(phoneActive, name: "jev-settings-phone-active")

        var phoneMissingScope = phoneActive
        phoneMissingScope.setScopes([.selectedTaskText], for: .phoneVerification)
        phoneMissingScope.setScopes([.phoneContent], for: .phoneActions)
        for useCase in phoneUseCases {
            XCTAssertFalse(phoneMissingScope.canSend(useCase: useCase, required: useCase.defaultDataScopes),
                           "缺范围 fixture 必须确实阻止该用途出站")
        }
        try await capturePhoneSettings(phoneMissingScope, name: "jev-settings-phone-missing-scope")
        var phoneUnpinnedMissingScope = phoneMissingScope
        phoneUnpinnedMissingScope.setPinnedModelVersion(nil)
        try await capturePhoneSettings(phoneUnpinnedMissingScope, name: "jev-settings-phone-unpinned-missing-scope")
        try await capturePhoneSettings(phoneUnpinnedMissingScope, name: "jev-settings-phone-unpinned-missing-scope-accessibility",
                                       type: .accessibility3, width: 320)

        let context = ChatContextSnapshot(
            messageCount: 8, modelId: "demo", supportsReasoning: true,
            pendingSelectedFileName: nil, pendingSelectedFileBytesText: nil,
            promptTokens: 1_200, completionTokens: 300, totalTokens: 1_500,
            cachedTokens: 600, tokensPerSecond: 45,
            contextWindowTokens: 128_000, currentContextTokens: 1_500
        )
        let jevSummary = IOSJevMetricsStore.RunSummary(
            decisions: 4, memorySelected: 3, memoryInjectionHits: 1,
            hiddenCharacters: 1_200, selectedModelId: "123e4567-e89b-12d3-a456-426614174000",
            firstVisibleDeltaMs: 350, modelSteps: 2, cacheHitRatio: 0.5
        )
        try await capture(
            ComposerContextPanel(snapshot: context, jevRunSummary: jevSummary),
            name: "jev-composer-summary",
            size: CGSize(width: 393, height: 640)
        )
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }
}
