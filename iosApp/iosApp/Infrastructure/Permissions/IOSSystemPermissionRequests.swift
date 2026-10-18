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

enum IOSLocationRequestMode {
    case whenInUse
    case always
}

// MARK: - Framework status and request implementations

extension IOSSystemPermissionCoordinator {
    func cameraStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(AVFoundation)
        return result(capability, mapAVAuthorizationStatus(AVCaptureDevice.authorizationStatus(for: .video)), "Camera authorization status.", now)
        #else
        return result(capability, .unavailableOnDevice, "AVFoundation is unavailable.", now)
        #endif
    }

    func requestCamera(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(AVFoundation)
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        return result(capability, allowed ? .authorized : .denied, allowed ? "Camera access authorized." : "Camera access denied.", Date())
        #else
        return result(capability, .unavailableOnDevice, "AVFoundation is unavailable.", now)
        #endif
    }

    func microphoneStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(AVFoundation)
        return result(capability, mapAVAuthorizationStatus(AVCaptureDevice.authorizationStatus(for: .audio)), "Microphone authorization status.", now)
        #else
        return result(capability, .unavailableOnDevice, "AVFoundation is unavailable.", now)
        #endif
    }

    func requestMicrophone(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(AVFoundation)
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        return result(capability, allowed ? .authorized : .denied, allowed ? "Microphone access authorized." : "Microphone access denied.", Date())
        #else
        return result(capability, .unavailableOnDevice, "AVFoundation is unavailable.", now)
        #endif
    }

    #if canImport(AVFoundation)
    func mapAVAuthorizationStatus(_ status: AVAuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func externalStorageCaptureStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(AVFoundation)
        if #available(iOS 17.0, *) {
            return result(capability, mapAVAuthorizationStatus(AVExternalStorageDevice.authorizationStatus), "External storage capture authorization status.", now)
        }
        return result(capability, .unavailableOnDevice, "External storage capture authorization requires iOS 17 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "AVFoundation is unavailable.", now)
        #endif
    }

    func requestExternalStorageCapture(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(AVFoundation)
        if #available(iOS 17.0, *) {
            let allowed = await AVExternalStorageDevice.requestAccess()
            return result(capability, allowed ? .authorized : .denied, allowed ? "External storage capture access authorized." : "External storage capture access denied.", Date())
        }
        return result(capability, .unavailableOnDevice, "External storage capture authorization requires iOS 17 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "AVFoundation is unavailable.", now)
        #endif
    }

    func imageCaptureContentsStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        // IMPORTANT: do NOT read `ICDeviceBrowser().contentsAuthorizationStatus` here. Instantiating
        // ICDeviceBrowser / touching ImageCaptureCore authorization triggers a system Camera prompt
        // (via icprefd) even for a passive status read. This status function is hit by the per-send
        // capability sweep (`permissionsStatus`), and because `cachedStatus` never stores the result
        // it fell through here on every send — popping the Camera dialog on every message sent.
        // Status checks must never prompt: report `.notDetermined` and let the real authorization be
        // acquired on demand in `requestImageCaptureContents`, which only runs from the explicit
        // permissions UI.
        result(capability, .notDetermined, "ImageCaptureCore contents authorization is requested on demand.", now)
    }

    func imageCaptureControlStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        // See `imageCaptureContentsStatus`: reading ICDeviceBrowser().controlAuthorizationStatus
        // would prompt for Camera on a passive status check. Report `.notDetermined`; the real
        // request happens on demand in `requestImageCaptureControl` (explicit permissions UI only).
        result(capability, .notDetermined, "ImageCaptureCore control authorization is requested on demand.", now)
    }

    func requestImageCaptureContents(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(ImageCaptureCore)
        if #available(iOS 14.0, *) {
            let browser = ICDeviceBrowser()
            let status = await withCheckedContinuation { continuation in
                browser.requestContentsAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            return result(capability, mapImageCaptureAuthorization(status), "ImageCaptureCore contents authorization request completed.", Date())
        }
        return result(capability, .unavailableOnDevice, "ImageCaptureCore contents authorization requires iOS 14 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "ImageCaptureCore is unavailable.", now)
        #endif
    }

    func requestImageCaptureControl(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(ImageCaptureCore)
        if #available(iOS 14.0, *) {
            let browser = ICDeviceBrowser()
            let status = await withCheckedContinuation { continuation in
                browser.requestControlAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            return result(capability, mapImageCaptureAuthorization(status), "ImageCaptureCore control authorization request completed.", Date())
        }
        return result(capability, .unavailableOnDevice, "ImageCaptureCore control authorization requires iOS 14 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "ImageCaptureCore is unavailable.", now)
        #endif
    }

    #if canImport(ImageCaptureCore)
    @available(iOS 14.0, *)
    func mapImageCaptureAuthorization(_ status: ICAuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func locationStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(CoreLocation)
        let manager = CLLocationManager()
        let status = manager.authorizationStatus
        return result(capability, mapCLAuthorizationStatus(
            status, for: capability, accuracyAuthorization: manager.accuracyAuthorization
        ), "Location authorization status: \(status.rawValue).", now)
        #else
        return result(capability, .unavailableOnDevice, "CoreLocation is unavailable.", now)
        #endif
    }

    func requestLocation(_ capability: IOSPlatformCapability, mode: IOSLocationRequestMode, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(CoreLocation)
        let requester = IOSLocationPermissionRequester()
        locationRequester = requester
        _ = await requester.request(mode: mode)
        locationRequester = nil
        return locationStatus(for: capability, now: Date())
        #else
        return result(capability, .unavailableOnDevice, "CoreLocation is unavailable.", now)
        #endif
    }

    func requestTemporaryPreciseLocation(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(CoreLocation)
        let manager = CLLocationManager()
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else {
            return result(capability, .notDetermined, "Grant location access before requesting temporary precise location.", now)
        }
        guard manager.accuracyAuthorization == .reducedAccuracy else {
            return result(capability, .authorized, "Precise location is already available.", now)
        }
        do {
            try await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "AmberAgentPreciseLocation")
            return result(capability, manager.accuracyAuthorization == .fullAccuracy ? .authorized : .limited, "Temporary precise location request completed.", Date())
        } catch {
            return result(capability, .denied, "Temporary precise location request failed: \(error.localizedDescription)", Date())
        }
        #else
        return result(capability, .unavailableOnDevice, "CoreLocation is unavailable.", now)
        #endif
    }

    #if canImport(CoreLocation)
    func mapCLAuthorizationStatus(
        _ status: CLAuthorizationStatus,
        for capability: IOSPlatformCapability,
        accuracyAuthorization: CLAccuracyAuthorization
    ) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            if capability.id == "ios.location.always", status == .authorizedWhenInUse {
                return .limited
            }
            if capability.id == "ios.location.temporary_precise", accuracyAuthorization == .reducedAccuracy {
                return .limited
            }
            return .authorized
        @unknown default: return .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func speechStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(Speech)
        return result(capability, mapSpeechStatus(SFSpeechRecognizer.authorizationStatus()), "Speech recognition authorization status.", now)
        #else
        return result(capability, .unavailableOnDevice, "Speech framework is unavailable.", now)
        #endif
    }

    func requestSpeechRecognition(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(Speech)
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return result(capability, mapSpeechStatus(status), "Speech recognition request completed.", Date())
        #else
        return result(capability, .unavailableOnDevice, "Speech framework is unavailable.", now)
        #endif
    }

    #if canImport(Speech)
    func mapSpeechStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func personalVoiceStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(AVFAudio)
        return result(capability, mapPersonalVoiceStatus(AVSpeechSynthesizer.personalVoiceAuthorizationStatus), "Personal Voice authorization status.", now)
        #else
        return result(capability, .unavailableOnDevice, "AVFAudio is unavailable.", now)
        #endif
    }

    func requestPersonalVoice(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(AVFAudio)
        let status = await withCheckedContinuation { continuation in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return result(capability, mapPersonalVoiceStatus(status), "Personal Voice request completed.", Date())
        #else
        return result(capability, .unavailableOnDevice, "AVFAudio is unavailable.", now)
        #endif
    }

    #if canImport(AVFAudio)
    func mapPersonalVoiceStatus(_ status: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .unsupported: .unavailableOnDevice
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    #if canImport(Photos)
    func photoStatus(for capability: IOSPlatformCapability, accessLevel: PHAccessLevel, now: Date) -> IOSSystemPermissionResult {
        result(capability, mapPhotoStatus(PHPhotoLibrary.authorizationStatus(for: accessLevel)), "Photo library authorization status.", now)
    }

    func requestPhotoLibrary(_ capability: IOSPlatformCapability, accessLevel: PHAccessLevel, now: Date) async -> IOSSystemPermissionResult {
        let status = await PHPhotoLibrary.requestAuthorization(for: accessLevel)
        return result(capability, mapPhotoStatus(status), "Photo library request completed.", Date())
    }

    func mapPhotoStatus(_ status: PHAuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .unknown
        }
    }
    #else
    func requestPhotoLibrary(_ capability: IOSPlatformCapability, accessLevel: Never, now: Date) async -> IOSSystemPermissionResult {
        result(capability, .unavailableOnDevice, "Photos framework is unavailable.", now)
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func contactsStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(Contacts)
        return result(capability, mapContactStatus(CNContactStore.authorizationStatus(for: .contacts)), "Contacts authorization status.", now)
        #else
        return result(capability, .unavailableOnDevice, "Contacts framework is unavailable.", now)
        #endif
    }

    func requestContacts(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(Contacts)
        do {
            _ = try await contactsAccessRequester()
            return result(
                capability, mapContactStatus(contactsAuthorizationStatus()),
                "Contacts authorization request completed.", Date()
            )
        } catch {
            return result(capability, .denied, "Contacts request failed: \(error.localizedDescription)", Date())
        }
        #else
        return result(capability, .unavailableOnDevice, "Contacts framework is unavailable.", now)
        #endif
    }

    #if canImport(Contacts)
    func mapContactStatus(_ status: CNAuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    #if canImport(EventKit)
    func eventKitStatus(for capability: IOSPlatformCapability, entityType: EKEntityType, now: Date) -> IOSSystemPermissionResult {
        result(capability, mapEventKitStatus(
            EKEventStore.authorizationStatus(for: entityType), for: capability
        ), "EventKit authorization status.", now)
    }

    func requestCalendarFull(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        do {
            let allowed = try await EKEventStore().requestFullAccessToEvents()
            return result(capability, allowed ? .authorized : .denied, allowed ? "Calendar full access authorized." : "Calendar full access denied.", Date())
        } catch {
            return result(capability, .denied, "Calendar full access request failed: \(error.localizedDescription)", Date())
        }
    }

    func requestCalendarWriteOnly(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        do {
            let allowed = try await EKEventStore().requestWriteOnlyAccessToEvents()
            return result(capability, allowed ? .authorized : .denied, allowed ? "Calendar write-only access authorized." : "Calendar write-only access denied.", Date())
        } catch {
            return result(capability, .denied, "Calendar write-only access request failed: \(error.localizedDescription)", Date())
        }
    }

    func requestReminders(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        do {
            let allowed = try await EKEventStore().requestFullAccessToReminders()
            return result(capability, allowed ? .authorized : .denied, allowed ? "Reminders access authorized." : "Reminders access denied.", Date())
        } catch {
            return result(capability, .denied, "Reminders request failed: \(error.localizedDescription)", Date())
        }
    }

    func mapEventKitStatus(
        _ status: EKAuthorizationStatus,
        for capability: IOSPlatformCapability
    ) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized, .fullAccess: .authorized
        case .writeOnly: capability.id == "ios.calendar.full" ? .limited : .authorized
        @unknown default: .unknown
        }
    }
    #else
    func requestCalendarFull(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        result(capability, .unavailableOnDevice, "EventKit is unavailable.", now)
    }
    func requestCalendarWriteOnly(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        result(capability, .unavailableOnDevice, "EventKit is unavailable.", now)
    }
    func requestReminders(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        result(capability, .unavailableOnDevice, "EventKit is unavailable.", now)
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func refreshNotificationStatus(
        for capability: IOSPlatformCapability,
        now: Date
    ) async -> IOSSystemPermissionResult {
        #if canImport(UserNotifications)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return result(capability, mapNotificationStatus(settings.authorizationStatus), "Notification settings refreshed.", Date())
        #else
        return result(capability, .unavailableOnDevice, "UserNotifications is unavailable.", now)
        #endif
    }

    func notificationCachedStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        result(capability, .unknown, "Notification settings require async refresh.", now)
    }

    func requestNotifications(
        _ capability: IOSPlatformCapability,
        options: UNAuthorizationOptions,
        now: Date
    ) async -> IOSSystemPermissionResult {
        #if canImport(UserNotifications)
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return result(capability, mapNotificationStatus(settings.authorizationStatus), allowed ? "Notification authorization request completed." : "Notification authorization denied.", Date())
        } catch {
            return result(capability, .denied, "Notification request failed: \(error.localizedDescription)", Date())
        }
        #else
        return result(capability, .unavailableOnDevice, "UserNotifications is unavailable.", now)
        #endif
    }

    #if canImport(UserNotifications)
    func mapNotificationStatus(_ status: UNAuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional, .ephemeral: .limited
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func liveActivitiesStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(ActivityKit)
        let info = ActivityAuthorizationInfo()
        return result(capability, info.areActivitiesEnabled ? .authorized : .denied, info.areActivitiesEnabled ? "实时活动已开启。" : "实时活动已在系统设置中关闭。", now)
        #else
        return result(capability, .unavailableOnDevice, "ActivityKit is unavailable.", now)
        #endif
    }
}

extension IOSSystemPermissionCoordinator {
    func trackingStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(AppTrackingTransparency)
        return result(capability, mapTrackingStatus(ATTrackingManager.trackingAuthorizationStatus), "App Tracking Transparency status.", now)
        #else
        return result(capability, .unavailableOnDevice, "AppTrackingTransparency is unavailable.", now)
        #endif
    }

    func requestTracking(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(AppTrackingTransparency)
        let status = await ATTrackingManager.requestTrackingAuthorization()
        return result(capability, mapTrackingStatus(status), "App Tracking Transparency request completed.", Date())
        #else
        return result(capability, .unavailableOnDevice, "AppTrackingTransparency is unavailable.", now)
        #endif
    }

    #if canImport(AppTrackingTransparency)
    func mapTrackingStatus(_ status: ATTrackingManager.AuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func focusStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(Intents)
        return result(capability, mapFocusStatus(INFocusStatusCenter.default.authorizationStatus), "Focus Status authorization status.", now)
        #else
        return result(capability, .unavailableOnDevice, "Intents framework is unavailable.", now)
        #endif
    }

    func requestFocusStatus(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(Intents)
        let status = await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return result(capability, mapFocusStatus(status), "Focus Status request completed.", Date())
        #else
        return result(capability, .unavailableOnDevice, "Intents framework is unavailable.", now)
        #endif
    }

    func platformPasskeysStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(AuthenticationServices)
        if #available(iOS 17.4, *) {
            let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
            return result(capability, mapPlatformPasskeyAuthorization(manager.authorizationStateForPlatformCredentials), "Platform passkey authorization status.", now)
        }
        return result(capability, .unavailableOnDevice, "Platform passkey authorization requires iOS 17.4 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "AuthenticationServices is unavailable.", now)
        #endif
    }

    func requestPlatformPasskeys(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(AuthenticationServices)
        if #available(iOS 17.4, *) {
            let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
            let status = await manager.requestAuthorizationForPublicKeyCredentials()
            return result(capability, mapPlatformPasskeyAuthorization(status), "Platform passkey authorization request completed.", Date())
        }
        return result(capability, .unavailableOnDevice, "Platform passkey authorization requires iOS 17.4 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "AuthenticationServices is unavailable.", now)
        #endif
    }

    #if canImport(Intents)
    func mapFocusStatus(_ status: INFocusStatusAuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }
    #endif

    #if canImport(AuthenticationServices)
    @available(iOS 17.4, *)
    func mapPlatformPasskeyAuthorization(
        _ status: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState
    ) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func faceIDStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return result(capability, .authorized, "Biometric authentication is available.", now)
        }
        return result(capability, .unavailableOnDevice, error?.localizedDescription ?? "Biometric authentication is unavailable.", now)
        #else
        return result(capability, .unavailableOnDevice, "LocalAuthentication is unavailable.", now)
        #endif
    }

    func requestFaceID(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return result(capability, .unavailableOnDevice, error?.localizedDescription ?? "Biometric authentication is unavailable.", now)
        }
        do {
            let allowed = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Authorize AmberAgent to verify Face ID availability.")
            return result(capability, allowed ? .authorized : .denied, allowed ? "Face ID authentication succeeded." : "Face ID authentication failed.", Date())
        } catch {
            return result(capability, .denied, "Face ID authentication failed: \(error.localizedDescription)", Date())
        }
        #else
        return result(capability, .unavailableOnDevice, "LocalAuthentication is unavailable.", now)
        #endif
    }
}

extension IOSSystemPermissionCoordinator {
    func mediaLibraryStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(MediaPlayer)
        return result(capability, mapMediaStatus(MPMediaLibrary.authorizationStatus()), "Media library authorization status.", now)
        #else
        return result(capability, .unavailableOnDevice, "MediaPlayer is unavailable.", now)
        #endif
    }

    func requestMediaLibrary(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(MediaPlayer)
        let status = await MPMediaLibrary.requestAuthorization()
        return result(capability, mapMediaStatus(status), "Media library request completed.", Date())
        #else
        return result(capability, .unavailableOnDevice, "MediaPlayer is unavailable.", now)
        #endif
    }

    #if canImport(MediaPlayer)
    func mapMediaStatus(_ status: MPMediaLibraryAuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func motionStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(CoreMotion)
        return result(capability, mapMotionStatus(CMMotionActivityManager.authorizationStatus()), "Core Motion authorization status.", now)
        #else
        return result(capability, .unavailableOnDevice, "CoreMotion is unavailable.", now)
        #endif
    }

    func requestMotionFitness(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(CoreMotion)
        guard CMPedometer.isStepCountingAvailable() else {
            return result(capability, .unavailableOnDevice, "Pedometer step counting is unavailable on this device.", now)
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                CMPedometer().queryPedometerData(from: Date().addingTimeInterval(-60), to: Date()) { data, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            return motionStatus(for: capability, now: Date())
        } catch {
            return result(capability, mapMotionStatus(CMMotionActivityManager.authorizationStatus()), "Motion request completed: \(error.localizedDescription)", Date())
        }
        #else
        return result(capability, .unavailableOnDevice, "CoreMotion is unavailable.", now)
        #endif
    }

    #if canImport(CoreMotion)
    func mapMotionStatus(_ status: CMAuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func bluetoothStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(CoreBluetooth)
        return result(capability, mapBluetoothAuthorization(CBManager.authorization), "Bluetooth authorization status.", now)
        #else
        return result(capability, .unavailableOnDevice, "CoreBluetooth is unavailable.", now)
        #endif
    }

    func requestBluetooth(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(CoreBluetooth)
        let probe = IOSBluetoothPermissionProbe()
        bluetoothProbe = probe
        let authorization = await probe.request()
        bluetoothProbe = nil
        return result(capability, mapBluetoothAuthorization(authorization), "Bluetooth authorization status.", Date())
        #else
        return result(capability, .unavailableOnDevice, "CoreBluetooth is unavailable.", now)
        #endif
    }

    #if canImport(CoreBluetooth)
    func mapBluetoothAuthorization(_ authorization: CBManagerAuthorization) -> IOSSystemPermissionStatus {
        switch authorization {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .allowedAlways: .authorized
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func workoutKitSchedulerStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(WorkoutKit)
        if #available(iOS 17.0, *) {
            guard WorkoutScheduler.isSupported else {
                return result(capability, .unavailableOnDevice, "WorkoutKit scheduled workouts require a supported Apple Watch.", now)
            }
            return result(capability, .unknown, "WorkoutKit scheduler authorization status requires async refresh.", now)
        }
        return result(capability, .unavailableOnDevice, "WorkoutKit scheduler authorization requires iOS 17 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "WorkoutKit is unavailable.", now)
        #endif
    }

    func refreshWorkoutKitSchedulerStatus(for capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(WorkoutKit)
        if #available(iOS 17.0, *) {
            guard WorkoutScheduler.isSupported else {
                return result(capability, .unavailableOnDevice, "WorkoutKit scheduled workouts require a supported Apple Watch.", now)
            }
            let status = await WorkoutScheduler.shared.authorizationState
            return result(capability, mapWorkoutAuthorization(status), "WorkoutKit scheduler authorization status.", Date())
        }
        return result(capability, .unavailableOnDevice, "WorkoutKit scheduler authorization requires iOS 17 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "WorkoutKit is unavailable.", now)
        #endif
    }

    func requestWorkoutKitScheduler(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(WorkoutKit)
        if #available(iOS 17.0, *) {
            guard WorkoutScheduler.isSupported else {
                return result(capability, .unavailableOnDevice, "WorkoutKit scheduled workouts require a supported Apple Watch.", now)
            }
            let status = await WorkoutScheduler.shared.requestAuthorization()
            return result(capability, mapWorkoutAuthorization(status), "WorkoutKit scheduler authorization request completed.", Date())
        }
        return result(capability, .unavailableOnDevice, "WorkoutKit scheduler authorization requires iOS 17 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "WorkoutKit is unavailable.", now)
        #endif
    }

    #if canImport(WorkoutKit)
    @available(iOS 17.0, *)
    func mapWorkoutAuthorization(_ status: WorkoutScheduler.AuthorizationState) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func financeKitStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(FinanceKit)
        if #available(iOS 17.4, *) {
            return result(capability, .unknown, "FinanceKit authorization status requires async refresh.", now)
        }
        return result(capability, .unavailableOnDevice, "FinanceKit authorization requires iOS 17.4 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "FinanceKit is unavailable.", now)
        #endif
    }

    func refreshFinanceKitStatus(for capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(FinanceKit)
        if #available(iOS 17.4, *) {
            do {
                let status = try await FinanceStore.shared.authorizationStatus()
                return result(capability, mapFinanceAuthorization(status), "FinanceKit authorization status.", Date())
            } catch {
                return result(capability, .unknown, "FinanceKit authorization status failed: \(error.localizedDescription)", Date())
            }
        }
        return result(capability, .unavailableOnDevice, "FinanceKit authorization requires iOS 17.4 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "FinanceKit is unavailable.", now)
        #endif
    }

    func requestFinanceKit(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(FinanceKit)
        if #available(iOS 17.4, *) {
            do {
                let status = try await FinanceStore.shared.requestAuthorization()
                return result(capability, mapFinanceAuthorization(status), "FinanceKit authorization request completed.", Date())
            } catch {
                return result(capability, .denied, "FinanceKit authorization request failed: \(error.localizedDescription)", Date())
            }
        }
        return result(capability, .unavailableOnDevice, "FinanceKit authorization requires iOS 17.4 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "FinanceKit is unavailable.", now)
        #endif
    }

    #if canImport(FinanceKit)
    @available(iOS 17.4, *)
    func mapFinanceAuthorization(_ status: FinanceKit.AuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func alarmKitStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            return result(capability, mapAlarmAuthorization(AlarmManager.shared.authorizationState), "AlarmKit authorization status.", now)
        }
        return result(capability, .unavailableOnDevice, "AlarmKit authorization requires iOS 26 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "AlarmKit is unavailable.", now)
        #endif
    }

    func requestAlarmKit(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do {
                let status = try await AlarmManager.shared.requestAuthorization()
                return result(capability, mapAlarmAuthorization(status), "AlarmKit authorization request completed.", Date())
            } catch {
                return result(capability, .denied, "AlarmKit authorization request failed: \(error.localizedDescription)", Date())
            }
        }
        return result(capability, .unavailableOnDevice, "AlarmKit authorization requires iOS 26 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "AlarmKit is unavailable.", now)
        #endif
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    func mapAlarmAuthorization(_ status: AlarmManager.AuthorizationState) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func requestLocalNetworkProbe(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(Network)
        let params = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: "_amberagent._tcp", domain: nil), using: params)
        browser.start(queue: .main)
        try? await Task.sleep(nanoseconds: 900_000_000)
        browser.cancel()
        return result(capability, .unknown, "Local Network has no public status API; a Bonjour probe was started to trigger the system prompt if needed.", Date())
        #else
        return result(capability, .unavailableOnDevice, "Network framework is unavailable.", now)
        #endif
    }
}

extension IOSSystemPermissionCoordinator {
    func healthStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            return result(capability, .unavailableOnDevice, "HealthKit data is unavailable on this device.", now)
        }
        return result(capability, .unknown, "HealthKit read authorization cannot be globally confirmed by public API; request status is tracked by the last request result.", now)
        #else
        return result(capability, .unavailableOnDevice, "HealthKit is unavailable.", now)
        #endif
    }

    func requestHealthKit(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            return result(capability, .unavailableOnDevice, "HealthKit data is unavailable on this device.", now)
        }
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return result(capability, .unavailableOnDevice, "Step count type is unavailable.", now)
        }
        let store = HKHealthStore()
        do {
            try await store.requestAuthorization(toShare: [], read: [stepType])
            return result(capability, .unknown, "HealthKit read request completed. Public API cannot confirm read grants per type until a query succeeds.", Date())
        } catch {
            return result(capability, .denied, "HealthKit request failed: \(error.localizedDescription)", Date())
        }
        #else
        return result(capability, .unavailableOnDevice, "HealthKit is unavailable.", now)
        #endif
    }
}

extension IOSSystemPermissionCoordinator {
    func nfcStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(CoreNFC)
        return result(capability, NFCNDEFReaderSession.readingAvailable ? .unknown : .unavailableOnDevice, NFCNDEFReaderSession.readingAvailable ? "NFC reading is available; opening a reader session must happen in foreground UI." : "NFC reading is unavailable on this device.", now)
        #else
        return result(capability, .unavailableOnDevice, "CoreNFC is unavailable.", now)
        #endif
    }

    func replayKitStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(ReplayKit)
        return result(capability, RPScreenRecorder.shared().isAvailable ? .unknown : .unavailableOnDevice, RPScreenRecorder.shared().isAvailable ? "ReplayKit is available; recording must start from foreground UI." : "ReplayKit is unavailable.", now)
        #else
        return result(capability, .unavailableOnDevice, "ReplayKit is unavailable.", now)
        #endif
    }

    func passKitStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(PassKit)
        return result(capability, PKPaymentAuthorizationController.canMakePayments() ? .unknown : .unavailableOnDevice, PKPaymentAuthorizationController.canMakePayments() ? "PassKit payments are available; authorization happens in a foreground system sheet." : "PassKit payments are unavailable.", now)
        #else
        return result(capability, .unavailableOnDevice, "PassKit is unavailable.", now)
        #endif
    }

    func passLibraryStatus(for capability: IOSPlatformCapability, now: Date) -> IOSSystemPermissionResult {
        #if canImport(PassKit)
        if #available(iOS 26.0, *) {
            let status = PKPassLibrary().authorizationStatus(for: .backgroundAddPasses)
            return result(capability, mapPassLibraryAuthorization(status), "Pass library background-add authorization status.", now)
        }
        return result(capability, .unknown, "Pass library is available; TCC authorization status requires iOS 26 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "PassKit is unavailable.", now)
        #endif
    }

    func requestPassLibrary(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(PassKit)
        if #available(iOS 26.0, *) {
            let library = PKPassLibrary()
            let status = await withCheckedContinuation { continuation in
                library.requestAuthorization(for: .backgroundAddPasses) { status in
                    continuation.resume(returning: status)
                }
            }
            return result(capability, mapPassLibraryAuthorization(status), "Pass library background-add authorization request completed.", Date())
        }
        return result(capability, .unknown, "Pass library authorization request requires iOS 26 or newer.", now)
        #else
        return result(capability, .unavailableOnDevice, "PassKit is unavailable.", now)
        #endif
    }

    #if canImport(PassKit)
    @available(iOS 26.0, *)
    func mapPassLibraryAuthorization(_ status: PKPassLibrary.AuthorizationStatus) -> IOSSystemPermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
    #endif
}

extension IOSSystemPermissionCoordinator {
    func requestVideoSubscriber(_ capability: IOSPlatformCapability, now: Date) async -> IOSSystemPermissionResult {
        #if canImport(VideoSubscriberAccount)
        let manager = VSAccountManager()
        let status = await withCheckedContinuation { continuation in
            manager.checkAccessStatus(options: [:]) { status, _ in
                continuation.resume(returning: status)
            }
        }
        switch status {
        case .granted:
            return result(capability, .authorized, "Video subscriber account access granted.", Date())
        case .denied:
            return result(capability, .denied, "Video subscriber account access denied.", Date())
        case .restricted:
            return result(capability, .restricted, "Video subscriber account access restricted.", Date())
        case .notDetermined:
            return result(capability, .notDetermined, "Video subscriber account access not determined.", Date())
        @unknown default:
            return result(capability, .unknown, "Unknown video subscriber account status.", Date())
        }
        #else
        return result(capability, .unavailableOnDevice, "VideoSubscriberAccount framework is unavailable.", now)
        #endif
    }
}

#if canImport(CoreLocation)
@MainActor
final class IOSLocationPermissionRequester: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func request(mode: IOSLocationRequestMode) async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            switch mode {
            case .whenInUse:
                manager.requestWhenInUseAuthorization()
            case .always:
                manager.requestAlwaysAuthorization()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: manager.authorizationStatus)
    }
}
#endif

#if canImport(CoreBluetooth)
@MainActor
final class IOSBluetoothPermissionProbe: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var centralManager: CBCentralManager?
    private var continuation: CheckedContinuation<CBManagerAuthorization, Never>?

    func request() async -> CBManagerAuthorization {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.centralManager = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: CBManager.authorization)
        centralManager = nil
    }
}
#endif
