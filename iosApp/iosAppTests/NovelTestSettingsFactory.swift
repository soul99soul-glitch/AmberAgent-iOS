import Foundation
@testable import iosApp

/// Settings source for Novel tests that only need a KMP settings snapshot.
/// The standalone Novel app's test target provides its own version.
@MainActor
func makeNovelTestSettings(userDefaults: UserDefaults) -> any IOSSettingsSnapshotSource {
    IOSSharedSettingsStore(userDefaults: userDefaults)
}
