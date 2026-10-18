import Foundation
import Security
import UIKit

#if canImport(AlarmKit)
import AlarmKit
#endif
#if canImport(ActivityKit)
import ActivityKit
#endif
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(AVFAudio)
import AVFAudio
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Contacts)
import Contacts
#endif
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(CoreMotion)
import CoreMotion
#endif
#if canImport(CoreNFC)
import CoreNFC
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(FinanceKit)
import FinanceKit
#endif
#if canImport(GameKit)
import GameKit
#endif
#if canImport(HealthKit)
import HealthKit
#endif
#if canImport(ImageCaptureCore)
import ImageCaptureCore
#endif
#if canImport(Intents)
import Intents
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if canImport(Messages)
import Messages
#endif
#if canImport(Network)
import Network
#endif
#if canImport(PassKit)
import PassKit
#endif
#if canImport(Photos)
import Photos
#endif
#if canImport(ReplayKit)
import ReplayKit
#endif
#if canImport(Speech)
import Speech
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(VideoSubscriberAccount)
import VideoSubscriberAccount
#endif
#if canImport(WiFiInfrastructure)
import WiFiInfrastructure
#endif
#if canImport(WorkoutKit)
@preconcurrency import WorkoutKit
#endif

enum IOSSystemPermissionStatus: String, CaseIterable, Identifiable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted
    case unavailableOnDevice
    case requiresEntitlement
    case requiresExtensionTarget
    case requiresSystemSettings
    case missingUsageDescription
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notDetermined: "Not determined"
        case .authorized: "Authorized"
        case .limited: "Limited"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .unavailableOnDevice: "Unavailable on device"
        case .requiresEntitlement: "Requires entitlement"
        case .requiresExtensionTarget: "Requires extension target"
        case .requiresSystemSettings: "Requires Settings"
        case .missingUsageDescription: "Missing usage description"
        case .unknown: "Unknown"
        }
    }
}

struct IOSSystemPermissionResult: Equatable {
    let capabilityId: String
    let status: IOSSystemPermissionStatus
    let message: String
    let updatedAt: Date
}

@MainActor
@Observable
final class IOSSystemPermissionCoordinator {
    static let implementedRequestCapabilityIds: Set<String> = [
        "ios.location.when_in_use",
        "ios.location.always",
        "ios.location.temporary_precise",
        "ios.camera.capture",
        "ios.microphone.record",
        "ios.speech.recognition",
        "ios.speech.personal_voice",
        "ios.files.external_storage_capture",
        "ios.image_capture.contents",
        "ios.image_capture.control",
        "ios.photos.library_read",
        "ios.photos.library_add",
        "ios.contacts.full",
        "ios.contacts.limited",
        "ios.calendar.full",
        "ios.calendar.write_only",
        "ios.reminders.full",
        "ios.health.read",
        "ios.motion.fitness",
        "ios.workoutkit.scheduler",
        "ios.finance.financekit",
        "ios.alarmkit.alarms",
        "ios.notifications.alerts",
        "ios.notifications.provisional",
        "ios.notifications.critical",
        "ios.tracking.app_tracking",
        "ios.authentication.face_id",
        "ios.focus.status",
        "ios.authentication.passkeys_platform_credentials",
        "ios.media.apple_music",
        "ios.video_subscriber.account",
        "ios.bluetooth.ble",
        "ios.network.local",
        "ios.wallet.pass_library"
    ]

    private(set) var results: [String: IOSSystemPermissionResult] = [:]
    var locationRequester: IOSLocationPermissionRequester?
    var bluetoothProbe: IOSBluetoothPermissionProbe?
    #if canImport(Contacts)
    @ObservationIgnored var contactsAccessRequester: () async throws -> Bool = {
        try await CNContactStore().requestAccess(for: .contacts)
    }
    @ObservationIgnored var contactsAuthorizationStatus: () -> CNAuthorizationStatus = {
        CNContactStore.authorizationStatus(for: .contacts)
    }
    #endif

    func cachedStatus(for capability: IOSPlatformCapability, now: Date = Date()) -> IOSSystemPermissionResult {
        if let cached = results[capability.id] {
            return cached
        }
        return staticStatus(for: capability, now: now)
    }

    @discardableResult
    func refreshStatus(for capability: IOSPlatformCapability, now: Date = Date()) async -> IOSSystemPermissionResult {
        if let preflight = preflightFailure(for: capability, now: now) {
            results[capability.id] = preflight
            return preflight
        }

        let result: IOSSystemPermissionResult
        switch capability.id {
        case "ios.workoutkit.scheduler":
            result = await refreshWorkoutKitSchedulerStatus(for: capability, now: now)
        case "ios.finance.financekit":
            result = await refreshFinanceKitStatus(for: capability, now: now)
        case "ios.notifications.alerts", "ios.notifications.provisional", "ios.notifications.critical", "ios.notifications.time_sensitive":
            result = await refreshNotificationStatus(for: capability, now: now)
        case "ios.video_subscriber.account":
            result = await requestVideoSubscriber(capability, now: now)
        default:
            result = staticStatus(for: capability, now: now)
        }
        results[capability.id] = result
        return result
    }

    @discardableResult
    func request(_ capability: IOSPlatformCapability, now: Date = Date()) async -> IOSSystemPermissionResult {
        if let preflight = preflightFailure(for: capability, now: now) {
            results[capability.id] = preflight
            return preflight
        }

        let result: IOSSystemPermissionResult
        switch capability.id {
        case "ios.location.when_in_use":
            result = await requestLocation(capability, mode: .whenInUse, now: now)
        case "ios.location.always":
            result = await requestLocation(capability, mode: .always, now: now)
        case "ios.location.temporary_precise":
            result = await requestTemporaryPreciseLocation(capability, now: now)
        case "ios.camera.capture":
            result = await requestCamera(capability, now: now)
        case "ios.microphone.record":
            result = await requestMicrophone(capability, now: now)
        case "ios.speech.recognition":
            result = await requestSpeechRecognition(capability, now: now)
        case "ios.speech.personal_voice":
            result = await requestPersonalVoice(capability, now: now)
        case "ios.files.external_storage_capture":
            result = await requestExternalStorageCapture(capability, now: now)
        case "ios.image_capture.contents":
            result = await requestImageCaptureContents(capability, now: now)
        case "ios.image_capture.control":
            result = await requestImageCaptureControl(capability, now: now)
        case "ios.photos.library_read":
            result = await requestPhotoLibrary(capability, accessLevel: .readWrite, now: now)
        case "ios.photos.library_add":
            result = await requestPhotoLibrary(capability, accessLevel: .addOnly, now: now)
        case "ios.contacts.full", "ios.contacts.limited":
            result = await requestContacts(capability, now: now)
        case "ios.calendar.full":
            result = await requestCalendarFull(capability, now: now)
        case "ios.calendar.write_only":
            result = await requestCalendarWriteOnly(capability, now: now)
        case "ios.reminders.full":
            result = await requestReminders(capability, now: now)
        case "ios.notifications.alerts":
            result = await requestNotifications(capability, options: [.alert, .sound, .badge], now: now)
        case "ios.notifications.provisional":
            result = await requestNotifications(capability, options: [.alert, .sound, .badge, .provisional], now: now)
        case "ios.notifications.critical":
            result = await requestNotifications(capability, options: [.alert, .sound, .badge, .criticalAlert], now: now)
        case "ios.notifications.live_activities":
            result = liveActivitiesStatus(for: capability, now: now)
        case "ios.tracking.app_tracking":
            result = await requestTracking(capability, now: now)
        case "ios.authentication.face_id":
            result = await requestFaceID(capability, now: now)
        case "ios.focus.status":
            result = await requestFocusStatus(capability, now: now)
        case "ios.authentication.passkeys_platform_credentials":
            result = await requestPlatformPasskeys(capability, now: now)
        case "ios.media.apple_music":
            result = await requestMediaLibrary(capability, now: now)
        case "ios.motion.fitness":
            result = await requestMotionFitness(capability, now: now)
        case "ios.workoutkit.scheduler":
            result = await requestWorkoutKitScheduler(capability, now: now)
        case "ios.finance.financekit":
            result = await requestFinanceKit(capability, now: now)
        case "ios.alarmkit.alarms":
            result = await requestAlarmKit(capability, now: now)
        case "ios.bluetooth.ble":
            result = await requestBluetooth(capability, now: now)
        case "ios.network.local":
            result = await requestLocalNetworkProbe(capability, now: now)
        case "ios.health.read":
            result = await requestHealthKit(capability, now: now)
        case "ios.nfc.reader":
            result = nfcStatus(for: capability, now: now)
        case "ios.replaykit.record":
            result = replayKitStatus(for: capability, now: now)
        case "ios.wallet.pass_library":
            result = await requestPassLibrary(capability, now: now)
        case "ios.wallet.apple_pay":
            result = passKitStatus(for: capability, now: now)
        case "ios.video_subscriber.account":
            result = await requestVideoSubscriber(capability, now: now)
        default:
            result = staticStatus(for: capability, now: now)
        }

        results[capability.id] = result
        return result
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    static func canRequestInApp(
        for capability: IOSPlatformCapability,
        systemStatus: IOSSystemPermissionStatus
    ) -> Bool {
        implementedRequestCapabilityIds.contains(capability.id) &&
            !systemStatusBlocksInAppRequest(systemStatus) &&
            capability.status != .unsupported &&
            capability.requestKind != .extensionTargetRequired &&
            capability.requestKind != .entitlementAndExtensionRequired &&
            capability.requestKind != .settingsOnly &&
            capability.requestKind != .diagnosticOnly &&
            capability.requestKind != .unsupported
    }

    private func preflightFailure(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult? {
        if capability.status == .unsupported {
            return result(capability, .unavailableOnDevice, capability.unavailableReason ?? "This capability is unavailable on iOS.", now)
        }
        let missingKeys = capability.requiredInfoPlistKeys.filter { !Self.hasInfoPlistDeclaration($0) }
        if !missingKeys.isEmpty {
            return result(capability, .missingUsageDescription, "Missing Info.plist declaration: \(missingKeys.joined(separator: ", "))", now)
        }
        let missingModes = capability.requiredBackgroundModes.filter { !Self.hasBackgroundMode($0) }
        if !missingModes.isEmpty {
            return result(capability, .missingUsageDescription, "Missing UIBackgroundModes entries: \(missingModes.joined(separator: ", "))", now)
        }
        if requiresExtensionTarget(capability) {
            return result(capability, .requiresExtensionTarget, "Requires extension target: \(capability.requiredExtensionTargets.joined(separator: ", "))", now)
        }
        if !missingEntitlements(for: capability).isEmpty {
            return result(capability, .requiresEntitlement, "Requires entitlement: \(missingEntitlements(for: capability).joined(separator: ", "))", now)
        }
        if capability.requestKind == .settingsOnly {
            return result(capability, .requiresSystemSettings, "需要在系统设置中管理。", now)
        }
        return nil
    }

    private func staticStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        if let preflight = preflightFailure(for: capability, now: now) {
            return preflight
        }

        switch capability.id {
        case "ios.location.when_in_use", "ios.location.always", "ios.location.temporary_precise":
            return locationStatus(for: capability, now: now)
        case "ios.camera.capture":
            return cameraStatus(for: capability, now: now)
        case "ios.microphone.record":
            return microphoneStatus(for: capability, now: now)
        case "ios.speech.recognition":
            return speechStatus(for: capability, now: now)
        case "ios.speech.personal_voice":
            return personalVoiceStatus(for: capability, now: now)
        case "ios.files.external_storage_capture":
            return externalStorageCaptureStatus(for: capability, now: now)
        case "ios.image_capture.contents":
            return imageCaptureContentsStatus(for: capability, now: now)
        case "ios.image_capture.control":
            return imageCaptureControlStatus(for: capability, now: now)
        case "ios.photos.library_read":
            return photoStatus(for: capability, accessLevel: .readWrite, now: now)
        case "ios.photos.library_add":
            return photoStatus(for: capability, accessLevel: .addOnly, now: now)
        case "ios.contacts.full", "ios.contacts.limited":
            return contactsStatus(for: capability, now: now)
        case "ios.calendar.full":
            return eventKitStatus(for: capability, entityType: .event, now: now)
        case "ios.calendar.write_only":
            return eventKitStatus(for: capability, entityType: .event, now: now)
        case "ios.reminders.full":
            return eventKitStatus(for: capability, entityType: .reminder, now: now)
        case "ios.notifications.alerts", "ios.notifications.provisional", "ios.notifications.critical", "ios.notifications.time_sensitive":
            return notificationCachedStatus(for: capability, now: now)
        case "ios.notifications.live_activities":
            return liveActivitiesStatus(for: capability, now: now)
        case "ios.tracking.app_tracking":
            return trackingStatus(for: capability, now: now)
        case "ios.authentication.face_id":
            return faceIDStatus(for: capability, now: now)
        case "ios.focus.status":
            return focusStatus(for: capability, now: now)
        case "ios.authentication.passkeys_platform_credentials":
            return platformPasskeysStatus(for: capability, now: now)
        case "ios.media.apple_music":
            return mediaLibraryStatus(for: capability, now: now)
        case "ios.motion.fitness":
            return motionStatus(for: capability, now: now)
        case "ios.workoutkit.scheduler":
            return workoutKitSchedulerStatus(for: capability, now: now)
        case "ios.finance.financekit":
            return financeKitStatus(for: capability, now: now)
        case "ios.alarmkit.alarms":
            return alarmKitStatus(for: capability, now: now)
        case "ios.bluetooth.ble":
            return bluetoothStatus(for: capability, now: now)
        case "ios.health.read":
            return healthStatus(for: capability, now: now)
        case "ios.nfc.reader":
            return nfcStatus(for: capability, now: now)
        case "ios.replaykit.record":
            return replayKitStatus(for: capability, now: now)
        case "ios.wallet.pass_library":
            return passLibraryStatus(for: capability, now: now)
        case "ios.wallet.apple_pay":
            return passKitStatus(for: capability, now: now)
        default:
            return diagnosticStatus(for: capability, now: now)
        }
    }

    func result(
        _ capability: IOSPlatformCapability,
        _ status: IOSSystemPermissionStatus,
        _ message: String,
        _ now: Date
    ) -> IOSSystemPermissionResult {
        IOSSystemPermissionResult(
            capabilityId: capability.id,
            status: status,
            message: message,
            updatedAt: now
        )
    }

    private func diagnosticStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        switch capability.requestKind {
        case .entitlementRequired:
            result(capability, .requiresEntitlement, "Requires entitlement before this capability can be requested.", now)
        case .extensionTargetRequired:
            result(capability, .requiresExtensionTarget, "Requires extension target before this capability can be used.", now)
        case .entitlementAndExtensionRequired:
            result(capability, .requiresExtensionTarget, "Requires entitlement and extension target before this capability can be used.", now)
        case .settingsOnly:
            result(capability, .requiresSystemSettings, "需要在系统设置中管理。", now)
        case .foregroundSystemUI, .foregroundSession, .authenticationOperation, .picker:
            result(capability, .unknown, "Requires foreground system UI: \(capability.requestEntryPoint)", now)
        case .directSystemPrompt, .diagnosticOnly:
            result(capability, .unknown, "No additional status API is exposed for this capability.", now)
        case .unsupported:
            result(capability, .unavailableOnDevice, capability.unavailableReason ?? "Unavailable on iOS.", now)
        }
    }

    private static func hasInfoPlistDeclaration(_ key: String) -> Bool {
        if key == "NSLocationTemporaryUsageDescriptionDictionary" {
            return Bundle.main.object(forInfoDictionaryKey: key) is [String: String]
        }
        if key == "NSBonjourServices" {
            return Bundle.main.object(forInfoDictionaryKey: key) is [String]
        }
        return Bundle.main.object(forInfoDictionaryKey: key) != nil
    }

    private static func hasBackgroundMode(_ mode: String) -> Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains(mode)
    }

    private func missingEntitlements(for capability: IOSPlatformCapability) -> [String] {
        capability.requiredEntitlements.filter { Self.entitlementValue($0) == nil }
    }

    private func requiresExtensionTarget(_ capability: IOSPlatformCapability) -> Bool {
        capability.requestKind == .extensionTargetRequired ||
            capability.requestKind == .entitlementAndExtensionRequired
    }

    private static func entitlementValue(_ key: String) -> Any? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil as UnsafeMutablePointer<Unmanaged<CFError>?>?)
        #else
        let infoKey = Bundle.main.bundleIdentifier?.contains(".experimental-gpl") == true
            ? "AmberAgentExperimentalConfiguredEntitlements"
            : "AmberAgentConfiguredEntitlements"
        let declaredEntitlements = Bundle.main.object(forInfoDictionaryKey: infoKey) as? [String] ?? []
        return declaredEntitlements.contains(key) ? true : nil
        #endif
    }

    private static func systemStatusBlocksInAppRequest(_ status: IOSSystemPermissionStatus) -> Bool {
        switch status {
        case .requiresEntitlement,
             .requiresExtensionTarget,
             .requiresSystemSettings,
             .missingUsageDescription,
             .unavailableOnDevice:
            true
        case .notDetermined,
             .authorized,
             .limited,
             .denied,
             .restricted,
             .unknown:
            false
        }
    }
}
