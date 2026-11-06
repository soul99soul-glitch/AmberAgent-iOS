import XCTest
import Shared
@testable import iosApp

@MainActor
final class NativeTimelineSettingsCacheTests: XCTestCase {
    func testReplacementSettingsAndFontPreferencesInvalidateSignatures() {
        let cache = NativeTimelineSettingsCache()
        func setting(actions: Bool) -> GenerativeUiSetting {
            GenerativeUiSetting(enabled: true, maxWidgetCodeChars: 12_000, maxWidgetHeightDp: 720,
                enableActions: actions, enableStructuredRenderers: true, enableInteractiveCharts: true,
                slidesMagazineFontPack: "source-han-serif-sc-regular", slidesSwissFontPack: "source-han-sans-sc-regular")
        }
        let enabled = setting(actions: true)
        let first = cache.generative(enabled)
        XCTAssertEqual(first, cache.generative(enabled))
        XCTAssertEqual(first, cache.generative(setting(actions: true)))
        XCTAssertNotEqual(first, cache.generative(setting(actions: false)))

        let defaults = UserDefaults(suiteName: "TimelineSettings-\(UUID().uuidString)")!
        let display = IOSSharedSettingsStore(userDefaults: defaults).displaySetting
        let base = cache.display(display, fontScale: 1, chatFont: "default", agentName: true)
        XCTAssertEqual(base, cache.display(display, fontScale: 1, chatFont: "default", agentName: true))
        XCTAssertNotEqual(base, cache.display(display, fontScale: 1.2, chatFont: "default", agentName: true))
        XCTAssertNotEqual(base, cache.display(display, fontScale: 1, chatFont: "serif", agentName: true))
        XCTAssertNotEqual(base, cache.display(display, fontScale: 1, chatFont: "default", agentName: false))
    }
}
