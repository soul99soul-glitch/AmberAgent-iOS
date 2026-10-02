@preconcurrency import Shared

/// Read-only settings surface for features that only consume the KMP settings
/// snapshot (model pickers, Novel). Amber's `IOSSharedSettingsStore` and the
/// standalone Novel app's settings store both provide it. `revision` changes on
/// every snapshot update so observing views can refresh.
protocol IOSSettingsSnapshotSource: AnyObject {
    var snapshot: Settings { get }
    var revision: Int { get }
}
