import Foundation
import Observation
@preconcurrency import Shared

@Observable @MainActor
final class DeepReadDiscoveryPreferences {
    static let shared = DeepReadDiscoveryPreferences()
    struct Configuration: Codable, Hashable {
        var enabledSources = IOSHotlistProviders.iOSDefaultProviderIds.intersection(IOSHotlistProviders.supportedProviderIds)
        var keywords = ""
        var filterMode = "all"
        var refreshMinutes = 30
        var wifiOnly = false
        var translateToChinese = false
    }
    var configuration: Configuration {
        didSet {
            guard configuration != oldValue else { return }
            if let data = try? JSONEncoder().encode(configuration) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "deepread.discovery.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
    }

    var boardSetting: TodayBoardSetting {
        let base = IosSettingsDefaults.shared.defaultSeededSettings().agentRuntime.todayBoard
        return TodayBoardSetting(
            enabled: true, boardModelId: nil, enabledSources: base.enabledSources,
            triggerHours: base.triggerHours, incrementalSignalThreshold: base.incrementalSignalThreshold,
            hotListRefreshIntervalMinutes: Int32(configuration.refreshMinutes),
            hotListWifiOnly: configuration.wifiOnly,
            hotListEnabledSources: configuration.enabledSources,
            hotListFocusKeywords: configuration.keywords.components(separatedBy: CharacterSet(charactersIn: "、,，\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            hotListFilterMode: TodayBoardHotListFilterMode.companion.fromWireName(raw: configuration.filterMode),
            hotListTranslateToChinese: configuration.translateToChinese,
            deepReadFirstUseConfirmed: true, boardReadingFontMode: base.boardReadingFontMode,
            boardReadingFontPackId: nil, deepReadFontScale: 1, deepReadTemplateId: IOSDeepReadTemplate.defaultId,
            density: base.density, backgroundStrategy: base.backgroundStrategy,
            foregroundCompensationGapMs: base.foregroundCompensationGapMs
        )
    }
}
