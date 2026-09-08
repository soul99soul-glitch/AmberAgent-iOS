import Foundation
import OSLog
#if os(watchOS)
import WidgetKit
#endif

/// The small, privacy-safe handoff between the Watch app and its WidgetKit
/// extension. The cache intentionally stores status metadata only; task
/// summaries, decisions, and user content never cross this boundary.
enum WatchWidgetCache {
    static let appGroupInfoKey = "AmberWatchAppGroupIdentifier"
    static let cacheKey = "amber.watch.widget.snapshot.v1"

    private static let logger = Logger(
        subsystem: "app.amber.ios.watch",
        category: "widget-cache"
    )

    /// Writes the latest safe snapshot to the Watch app's App Group.
    ///
    /// A `false` result means that the cache could not be encoded, the App
    /// Group was not configured, or the in-process write could not be read
    /// back. This is a best-effort cache, not a durability guarantee; callers
    /// must keep their own UI state independent of this result.
    @discardableResult
    static func save(_ snapshot: WatchTaskSnapshot, defaults injectedDefaults: UserDefaults? = nil) -> Bool {
        guard let defaults = injectedDefaults ?? sharedDefaults else {
            logger.error("Unable to save snapshot: App Group is not configured")
            return false
        }

        let safeSnapshot = privacySafeSnapshot(from: snapshot)
        let languageChanged = load(from: defaults)?.languageCode != safeSnapshot.languageCode
        if let existing = load(from: defaults) {
            if safeSnapshot == existing {
                return true
            }
            if isOlder(safeSnapshot, than: existing) {
                // A delayed WatchConnectivity delivery must not move the
                // widget back to an older run or state. The already stored
                // value is the requested state, so this is a successful no-op.
                return true
            }
        }

        do {
            let data = try WatchTaskCodec.encodeSnapshot(safeSnapshot)
            defaults.set(data, forKey: cacheKey)
            guard defaults.data(forKey: cacheKey) == data else {
                logger.error("Unable to read back saved snapshot")
                return false
            }
            #if os(watchOS)
            if languageChanged {
                WidgetCenter.shared.reloadAllTimelines()
            } else {
                WidgetCenter.shared.reloadTimelines(ofKind: "AmberWatchCurrentTaskWidget")
            }
            #endif
            return true
        } catch {
            logger.error("Unable to encode snapshot: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Loads only the redacted snapshot shared with the WidgetKit extension.
    /// Corrupt or missing data is treated as unavailable and never surfaced as
    /// a successful task state.
    static func load(defaults injectedDefaults: UserDefaults? = nil) -> WatchTaskSnapshot? {
        guard let defaults = injectedDefaults ?? sharedDefaults else {
            logger.error("Unable to load snapshot: App Group is not configured")
            return nil
        }
        return load(from: defaults)
    }

    static func clear() {
        sharedDefaults?.removeObject(forKey: cacheKey)
        #if os(watchOS)
        WidgetCenter.shared.reloadTimelines(ofKind: "AmberWatchCurrentTaskWidget")
        #endif
    }

    private static func load(from defaults: UserDefaults) -> WatchTaskSnapshot? {
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        do {
            return privacySafeSnapshot(from: try WatchTaskCodec.decodeSnapshot(data))
        } catch {
            logger.error("Unable to decode cached snapshot: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static var appGroupIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
              !value.isEmpty,
              !value.contains("$("),
              value.hasPrefix("group.") else {
            return nil
        }
        return value
    }

    private static var sharedDefaults: UserDefaults? {
        guard let appGroupIdentifier else { return nil }
        return UserDefaults(suiteName: appGroupIdentifier)
    }

    private static func privacySafeSnapshot(from snapshot: WatchTaskSnapshot) -> WatchTaskSnapshot {
        var safe = snapshot
        // The widget only needs a stable target and generic lifecycle state.
        // In particular, do not persist conversation identifiers, summaries,
        // decision bodies, metric text, or action payloads in the App Group.
        safe.conversationId = nil
        safe.library = nil
        safe.headline = "Amber"
        safe.detail = nil
        safe.summary = nil
        safe.metricText = nil
        safe.decision = nil
        safe.actions = []
        return safe
    }

    private static func isOlder(
        _ incoming: WatchTaskSnapshot,
        than existing: WatchTaskSnapshot
    ) -> Bool {
        guard incoming != existing else { return false }
        return !WatchSnapshotOrdering.accepts(incoming, after: existing)
    }
}
