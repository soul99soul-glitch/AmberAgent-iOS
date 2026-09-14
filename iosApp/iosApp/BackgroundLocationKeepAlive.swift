@preconcurrency import CoreLocation
import Foundation
import UIKit

extension Notification.Name {
    static let amberBackgroundLocationKeepAliveChanged = Notification.Name(
        "app.amber.ios.backgroundLocationKeepAliveChanged"
    )
}

@MainActor
protocol BackgroundLocationKeepAliveControlling: AnyObject {
    var isActive: Bool { get }
    func setNeeded(_ needed: Bool)
}

/// Optional experimental background activity support for long-running work.
///
/// This object never stores, formats, or uploads a coordinate. Core Location is
/// used only as a user-visible system assertion: an active lease may create a
/// foreground `CLBackgroundActivitySession`, then start a coarse location
/// service after the App has remained in the background for a short grace
/// period. The session and location service are both torn down as soon as the
/// lease, preference, authorization, or background capability disappears.
@MainActor
final class BackgroundLocationKeepAlive: NSObject,
    BackgroundLocationKeepAliveControlling,
    @preconcurrency CLLocationManagerDelegate {
    static let shared = BackgroundLocationKeepAlive()

    private static let backgroundDelayNanoseconds: UInt64 = 15_000_000_000
    private static let sessionActiveKey = "app.amber.ios.execution.backgroundLocationSessionActive"

    private let defaults: UserDefaults
    private let locationManager: CLLocationManager
    private var backgroundActivitySession: CLBackgroundActivitySession?
    private var locationStartTask: Task<Void, Never>?
    private var observerTokens: [NSObjectProtocol] = []
    private var needed = false
    private var locationUpdatesStarted = false
    private var receivedLocationUpdate = false
    private var preferenceEnabled = false

    init(
        defaults: UserDefaults = .standard,
        locationManager: CLLocationManager = CLLocationManager()
    ) {
        self.defaults = defaults
        self.locationManager = locationManager
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .other
        locationManager.pausesLocationUpdatesAutomatically = false
        if hasLocationBackgroundMode {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }
        installObservers()
        refreshPreference()
        if UIApplication.shared.applicationState == .active {
            handleDidBecomeActive()
        }
    }

    isolated deinit {
        locationStartTask?.cancel()
        locationManager.stopUpdatingLocation()
        backgroundActivitySession?.invalidate()
        defaults.set(false, forKey: Self.sessionActiveKey)
        for observer in observerTokens {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isActive: Bool {
        locationUpdatesStarted && receivedLocationUpdate && backgroundActivitySession != nil
    }

    var isPreferenceEnabled: Bool {
        preferenceEnabled
    }

    var hasLocationBackgroundMode: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?
            .contains("location") == true
    }

    var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    var statusText: String {
        guard hasLocationBackgroundMode else {
            return IOSAppLocalization.string(
                "当前构建未启用定位后台模式。",
                defaultValue: "当前构建未启用定位后台模式。"
            )
        }
        guard preferenceEnabled else {
            return IOSAppLocalization.string(
                "已关闭；不会申请定位权限。",
                defaultValue: "已关闭；不会申请定位权限。"
            )
        }
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if isActive {
                return IOSAppLocalization.string(
                    "后台定位保活已运行；不记录位置；系统显示定位标志并增加耗电。",
                    defaultValue: "后台定位保活已运行；不记录位置；系统显示定位标志并增加耗电。"
                )
            }
            return IOSAppLocalization.string(
                "已授权；不记录位置；有后台任务时切到后台 15 秒后启用，可能增加耗电并显示定位标志。",
                defaultValue: "已授权；不记录位置；有后台任务时切到后台 15 秒后启用，可能增加耗电并显示定位标志。"
            )
        case .denied, .restricted:
            return IOSAppLocalization.string(
                "定位权限未授权，请在系统设置中允许“使用 App 期间”。",
                defaultValue: "定位权限未授权，请在系统设置中允许“使用 App 期间”。"
            )
        case .notDetermined:
            return IOSAppLocalization.string(
                "打开后只会在前台申请“使用 App 期间”的定位权限；默认不会自动授权。",
                defaultValue: "打开后只会在前台申请“使用 App 期间”的定位权限；默认不会自动授权。"
            )
        @unknown default:
            return IOSAppLocalization.string(
                "定位权限状态未知。",
                defaultValue: "定位权限状态未知。"
            )
        }
    }

    /// Called by the settings UI. This is the only path that requests the
    /// system permission prompt; startup and lease changes never prompt.
    func requestEnable() {
        guard hasLocationBackgroundMode else {
            defaults.set(false, forKey: IOSExecutionPreferenceKeys.backgroundLocationKeepAlive)
            preferenceEnabled = false
            stop()
            return
        }
        defaults.set(true, forKey: IOSExecutionPreferenceKeys.backgroundLocationKeepAlive)
        preferenceEnabled = true
        if authorizationStatus == .notDetermined,
           UIApplication.shared.applicationState == .active {
            locationManager.requestWhenInUseAuthorization()
        }
        refreshPreference()
    }

    /// Re-read the explicit preference after the settings toggle changes.
    func refreshPreference() {
        preferenceEnabled = defaults.bool(forKey: IOSExecutionPreferenceKeys.backgroundLocationKeepAlive)
        guard preferenceEnabled else {
            stop()
            return
        }
        guard hasLocationBackgroundMode, isAuthorized else {
            stop()
            publishStateChange()
            return
        }
        prepareForegroundSessionIfNeeded()
        publishStateChange()
    }

    func setNeeded(_ needed: Bool) {
        self.needed = needed
        guard needed else {
            stop()
            return
        }
        refreshPreference()
    }

    // MARK: - Core Location delegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === locationManager else { return }
        guard isAuthorized else {
            stop()
            publishStateChange()
            return
        }
        if needed, preferenceEnabled {
            prepareForegroundSessionIfNeeded()
        }
        publishStateChange()
    }

    /// Deliberately discard every coordinate. A received update only confirms
    /// that the system has activated the service; no location crosses this
    /// class boundary or reaches persistence/network code.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === locationManager, !locations.isEmpty else { return }
        if !receivedLocationUpdate {
            receivedLocationUpdate = true
            publishStateChange()
        }
    }

    // MARK: - Lifecycle

    private var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observerTokens.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleDidEnterBackground() }
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleWillEnterForeground() }
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleDidBecomeActive() }
            }
        )
    }

    private func handleDidEnterBackground() {
        guard needed, preferenceEnabled, hasLocationBackgroundMode, isAuthorized else { return }
        guard backgroundActivitySession != nil else {
            // A new CLBackgroundActivitySession must be created in the
            // foreground. The next foreground transition will prepare it.
            return
        }
        scheduleLocationStart()
    }

    private func handleWillEnterForeground() {
        locationStartTask?.cancel()
        locationStartTask = nil
        stopLocationUpdates()
        invalidateCurrentSession()
        if needed, preferenceEnabled, hasLocationBackgroundMode, isAuthorized {
            prepareForegroundSessionIfNeeded()
        }
        publishStateChange()
    }

    private func handleDidBecomeActive() {
        guard hasLocationBackgroundMode, isAuthorized else { return }
        if (!needed || !preferenceEnabled), backgroundActivitySession == nil {
            cleanupOrphanedSessionIfNeeded()
        }
        if needed, preferenceEnabled {
            prepareForegroundSessionIfNeeded()
        }
        publishStateChange()
    }

    private func cleanupOrphanedSessionIfNeeded() {
        guard defaults.bool(forKey: Self.sessionActiveKey),
              backgroundActivitySession == nil,
              UIApplication.shared.applicationState == .active else { return }
        // A process restart cannot retain the old object. Recreate the marker
        // in the foreground and invalidate it immediately, without requesting
        // authorization or starting location updates.
        let orphanedSession = CLBackgroundActivitySession()
        orphanedSession.invalidate()
        defaults.set(false, forKey: Self.sessionActiveKey)
    }

    private func prepareForegroundSessionIfNeeded() {
        guard needed,
              preferenceEnabled,
              hasLocationBackgroundMode,
              isAuthorized,
              UIApplication.shared.applicationState == .active,
              backgroundActivitySession == nil else { return }
        // Apple requires a new session to be created while the app is in the
        // foreground. It is held here until the background grace period ends.
        backgroundActivitySession = CLBackgroundActivitySession()
        defaults.set(true, forKey: Self.sessionActiveKey)
    }

    private func scheduleLocationStart() {
        guard locationStartTask == nil, !locationUpdatesStarted else { return }
        locationStartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.backgroundDelayNanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.needed,
                  self.preferenceEnabled,
                  self.hasLocationBackgroundMode,
                  self.isAuthorized,
                  self.backgroundActivitySession != nil,
                  UIApplication.shared.applicationState == .background else { return }
            self.startLocationUpdates()
        }
    }

    private func startLocationUpdates() {
        guard !locationUpdatesStarted else { return }
        receivedLocationUpdate = false
        locationManager.startUpdatingLocation()
        locationUpdatesStarted = true
        publishStateChange()
    }

    private func stopLocationUpdates() {
        guard locationUpdatesStarted else { return }
        locationManager.stopUpdatingLocation()
        locationUpdatesStarted = false
        receivedLocationUpdate = false
        publishStateChange()
    }

    private func stop() {
        locationStartTask?.cancel()
        locationStartTask = nil
        stopLocationUpdates()
        invalidateCurrentSession()
        publishStateChange()
    }

    private func invalidateCurrentSession() {
        guard let session = backgroundActivitySession else { return }
        session.invalidate()
        backgroundActivitySession = nil
        defaults.set(false, forKey: Self.sessionActiveKey)
    }

    private func publishStateChange() {
        NotificationCenter.default.post(
            name: .amberBackgroundLocationKeepAliveChanged,
            object: self
        )
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard manager === locationManager else { return }
        locationUpdatesStarted = false
        receivedLocationUpdate = false
        publishStateChange()
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        guard manager === locationManager else { return }
        locationUpdatesStarted = true
        receivedLocationUpdate = false
        publishStateChange()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === locationManager else { return }
        locationManager.stopUpdatingLocation()
        locationUpdatesStarted = false
        receivedLocationUpdate = false
        publishStateChange()
    }
}
