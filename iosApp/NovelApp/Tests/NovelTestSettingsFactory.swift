import Foundation
@testable import iosApp

/// Settings source for shared Novel tests that only need a KMP settings
/// snapshot. Amber's test target backs this with `IOSSharedSettingsStore`.
@MainActor
func makeNovelTestSettings(userDefaults: UserDefaults) -> any IOSSettingsSnapshotSource {
    NovelAppSettingsStore(defaults: userDefaults, credentials: MemoryCredentials())
}
