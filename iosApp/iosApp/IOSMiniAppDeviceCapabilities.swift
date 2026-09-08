import AVFAudio
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

#if canImport(CoreHaptics)
import CoreHaptics
#endif

enum IOSMiniAppDeviceCapabilitiesError: LocalizedError, Equatable {
    case closed
    case invalidMethod(String)
    case invalidParameter(String)
    case unsupported(String)
    case unavailable(String)
    case notForeground
    case busy(String)

    var errorDescription: String? {
        switch self {
        case .closed:
            return "MiniApp device capabilities are closed."
        case .invalidMethod(let method):
            return "Unknown MiniApp device method: \(method)"
        case .invalidParameter(let message):
            return "Invalid MiniApp device parameter: \(message)"
        case .unsupported(let message):
            return message
        case .unavailable(let message):
            return message
        case .notForeground:
            return "MiniApp device capability requires its runner to be foreground-active."
        case .busy(let message):
            return message
        }
    }
}

/// Native, owner-scoped capabilities exposed to one MiniApp runner.
///
/// The class is deliberately independent from the bridge's permission/grant
/// policy. The root runtime owns that policy and calls this object only after
/// it has decided that the MiniApp may use the requested capability.
@MainActor
final class IOSMiniAppDeviceCapabilities: ObservableObject {
    /// The view whose window owns this runner. No global window fallback is
    /// used: presenting from another MiniApp's scene would be a lifecycle bug.
    weak var presentationAnchor: UIView?

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var isClosed = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var hapticTimes: [TimeInterval] = []

    private static weak var transientResourceOwner: IOSMiniAppDeviceCapabilities?

    private weak var leasedScreen: UIScreen?
    private var originalBrightness: CGFloat?
    private var lastBrightness: CGFloat?
    private var originalKeepAwake: Bool?
    private var lastKeepAwake: Bool?

    private var presentedShareController: UIActivityViewController?
    private var shareContinuation: CheckedContinuation<IOSMiniAppJSONValue, Error>?
    private var shareRequestID: UUID?

    init() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.presentationAnchor?.window?.windowScene?.activationState != .foregroundActive else {
                    return
                }
                self.handleWillResignActive()
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIScene.willDeactivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let scene = notification.object as? UIScene else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.presentationAnchor?.window?.windowScene === scene else {
                    return
                }
                self.handleWillResignActive()
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillResignActive()
            }
        })
    }

    isolated deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func dispatch(method: String, params: [String: Any]) async throws -> IOSMiniAppJSONValue {
        guard !isClosed else { throw IOSMiniAppDeviceCapabilitiesError.closed }
        try Task.checkCancellation()

        switch method {
        case "haptics.impact":
            let style = try stringParam("style", params, defaultValue: "medium")
            guard ["light", "medium", "heavy", "soft", "rigid"].contains(style) else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter(
                    "style must be light, medium, heavy, soft, or rigid"
                )
            }
            let intensity = try numberParam("intensity", params, defaultValue: 1, range: 0...1)
            try requireForeground()
            try playHapticImpact(style: style, intensity: intensity)
            return ok()

        case "haptics.notification":
            let type = try stringParam("type", params, defaultValue: "success")
            guard ["success", "warning", "error"].contains(type) else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter(
                    "type must be success, warning, or error"
                )
            }
            try requireForeground()
            try playHapticNotification(type: type)
            return ok()

        case "haptics.selection":
            try requireForeground()
            try playHapticSelection()
            return ok()

        case "device.getInfo":
            return deviceInfo()

        case "device.getBattery":
            return batteryInfo()

        case "screen.getBrightness":
            let screen = try activeMainScreen()
            return .number(Double(screen.brightness))

        case "screen.setBrightness":
            let brightness = try numberParam("brightness", params, range: 0...1)
            let screen = try activeMainScreen()
            acquireBrightnessLease(for: screen)
            screen.brightness = CGFloat(brightness)
            lastBrightness = CGFloat(brightness)
            return ok()

        case "screen.setKeepAwake":
            let enabled = try boolParam("enabled", params)
            _ = try activeWindow()
            acquireKeepAwakeLease()
            UIApplication.shared.isIdleTimerDisabled = enabled
            lastKeepAwake = enabled
            return ok()

        case "speech.getVoices":
            return speechVoices()

        case "speech.speak":
            let text = try requiredString("text", params)
            guard !text.isEmpty, text.count <= 4_000 else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter(
                    "text must contain 1...4000 characters"
                )
            }
            let language = try optionalString("language", params)
            let rate = try numberParam("rate", params, defaultValue: 0.5, range: 0...1)
            let pitch = try numberParam("pitch", params, defaultValue: 1, range: 0.5...2)
            let volume = try numberParam("volume", params, defaultValue: 1, range: 0...1)
            try requireForeground()
            try speak(text: text, language: language, rate: rate, pitch: pitch, volume: volume)
            return .object(["speaking": .bool(true)])

        case "speech.stop":
            return .object(["stopped": .bool(speechSynthesizer.stopSpeaking(at: .immediate))])

        case "speech.pause":
            return .object(["paused": .bool(speechSynthesizer.pauseSpeaking(at: .word))])

        case "speech.resume":
            try requireForeground()
            return .object(["resumed": .bool(speechSynthesizer.continueSpeaking())])

        case "share":
            let items = try shareItems(params)
            try requireForeground()
            return try await presentShare(items: items)

        case "openURL":
            let rawURL = try requiredString("url", params)
            let url = try Self.validatedOpenURL(rawURL)
            try requireForeground()
            let opened = await UIApplication.shared.open(url, options: [:])
            return .object([
                "opened": .bool(opened),
                "url": .string(url.absoluteString),
            ])

        case "qrcode.generate":
            let text = try requiredString("text", params)
            guard !text.isEmpty, Data(text.utf8).count <= 1_024 else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter(
                    "text must contain 1...1024 UTF-8 bytes"
                )
            }
            let size = try integerParam("size", params, defaultValue: 256, range: 128...1_024)
            return try generateQRCode(text: text, size: size)

        default:
            throw IOSMiniAppDeviceCapabilitiesError.invalidMethod(method)
        }
    }

    /// Closes this runner's transient resources. A closed coordinator is not
    /// reused by the runner; keeping the flag makes late bridge calls fail
    /// instead of touching restored global state.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        handleWillResignActive()
        presentationAnchor = nil
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    /// Stops transient activity while retaining this coordinator for a
    /// foreground reload. The root runtime may call this when the trusted
    /// document is torn down before the coordinator itself is closed.
    func suspend() {
        guard !isClosed else { return }
        handleWillResignActive()
    }

    /// Validates the exact URL that the root runtime should show in its
    /// confirmation prompt before dispatching `openURL`.
    nonisolated static func validatedOpenURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("url is empty")
        }
        guard trimmed.utf8.count <= 4_096 else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("url is too long")
        }
        guard !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0)
              }),
              let components = URLComponents(string: trimmed),
              let rawScheme = components.scheme else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("url is malformed")
        }

        let scheme = rawScheme.lowercased()
        switch scheme {
        case "https":
            guard let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !host.isEmpty,
                  components.user == nil,
                  components.password == nil else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter(
                    "HTTPS URL needs a public host and may not contain credentials"
                )
            }
            let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
            guard !normalizedHost.hasSuffix(".localhost"),
                  !normalizedHost.hasSuffix(".local"),
                  normalizedHost != "localhost",
                  IOSSearchExecutor.publicHostAllowed(normalizedHost) else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter(
                    "HTTPS URL must target a public host"
                )
            }
        case "mailto":
            guard components.host == nil,
                  components.port == nil,
                  components.user == nil,
                  components.password == nil,
                  !components.path.isEmpty,
                  !components.path.hasPrefix("/"),
                  components.fragment == nil else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("mailto URL is malformed")
            }
        case "tel":
            let allowedTelephoneCharacters = CharacterSet(charactersIn: "+*#0123456789-().")
            guard components.host == nil,
                  components.port == nil,
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  !components.path.isEmpty,
                  !components.path.hasPrefix("/"),
                  components.path.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }),
                  components.path.unicodeScalars.allSatisfy({ allowedTelephoneCharacters.contains($0) }) else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("tel URL is malformed")
            }
        default:
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter(
                "Only public HTTPS, mailto, and tel URLs are allowed"
            )
        }

        var normalized = components
        normalized.scheme = scheme
        guard let url = normalized.url else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("url is malformed")
        }
        return url
    }

    private func ok() -> IOSMiniAppJSONValue {
        .object(["ok": .bool(true)])
    }

    private func requireForeground() throws {
        _ = try activeWindow()
    }

    private func activeWindow() throws -> UIWindow {
        guard let anchor = presentationAnchor,
              let window = anchor.window,
              let scene = window.windowScene,
              scene.activationState == .foregroundActive,
              !window.isHidden,
              window.alpha > 0,
              window.rootViewController != nil else {
            throw IOSMiniAppDeviceCapabilitiesError.notForeground
        }
        return window
    }

    private func activeMainScreen() throws -> UIScreen {
        let window = try activeWindow()
        guard let scene = window.windowScene,
              scene.session.role == .windowApplication else {
            throw IOSMiniAppDeviceCapabilitiesError.unsupported(
                "Screen brightness is only available on the main screen."
            )
        }
        return scene.screen
    }

    private func visibleViewController(from root: UIViewController) -> UIViewController {
        if let presented = root.presentedViewController,
           !presented.isBeingDismissed {
            return visibleViewController(from: presented)
        }
        if let navigation = root as? UINavigationController,
           let visible = navigation.visibleViewController {
            return visibleViewController(from: visible)
        }
        if let tab = root as? UITabBarController,
           let selected = tab.selectedViewController {
            return visibleViewController(from: selected)
        }
        if let split = root as? UISplitViewController,
           let last = split.viewControllers.last {
            return visibleViewController(from: last)
        }
        return root
    }

    private func presentationViewController() throws -> UIViewController {
        let window = try activeWindow()
        guard let root = window.rootViewController else {
            throw IOSMiniAppDeviceCapabilitiesError.unavailable("MiniApp presentation host is unavailable.")
        }
        let presenter = visibleViewController(from: root)
        guard presenter.viewIfLoaded?.window === window,
              !presenter.isBeingDismissed,
              !presenter.isBeingPresented else {
            throw IOSMiniAppDeviceCapabilitiesError.unavailable("MiniApp presentation host is unavailable.")
        }
        return presenter
    }

    private func playHapticImpact(style: String, intensity: Double) throws {
        try checkHapticAvailability()
        try consumeHapticBudget()
        let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case "light": feedbackStyle = .light
        case "medium": feedbackStyle = .medium
        case "heavy": feedbackStyle = .heavy
        case "soft": feedbackStyle = .soft
        case "rigid": feedbackStyle = .rigid
        default:
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("unknown haptic style")
        }
        let generator = UIImpactFeedbackGenerator(style: feedbackStyle)
        generator.prepare()
        generator.impactOccurred(intensity: CGFloat(intensity))
    }

    private func playHapticNotification(type: String) throws {
        try checkHapticAvailability()
        try consumeHapticBudget()
        let feedbackType: UINotificationFeedbackGenerator.FeedbackType
        switch type {
        case "success": feedbackType = .success
        case "warning": feedbackType = .warning
        case "error": feedbackType = .error
        default:
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("unknown notification type")
        }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(feedbackType)
    }

    private func playHapticSelection() throws {
        try checkHapticAvailability()
        try consumeHapticBudget()
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    private func checkHapticAvailability() throws {
        #if canImport(CoreHaptics)
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            throw IOSMiniAppDeviceCapabilitiesError.unsupported("Haptic hardware is unavailable on this device.")
        }
        #else
        throw IOSMiniAppDeviceCapabilitiesError.unsupported("Haptic hardware is unavailable on this platform.")
        #endif
    }

    private func consumeHapticBudget() throws {
        let now = Date().timeIntervalSince1970
        hapticTimes.removeAll { now - $0 > 1 }
        guard hapticTimes.count < 10 else {
            throw IOSMiniAppDeviceCapabilitiesError.busy("MiniApp haptics are being rate limited.")
        }
        hapticTimes.append(now)
    }

    private func deviceInfo() -> IOSMiniAppJSONValue {
        let idiom: String
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: idiom = "phone"
        case .pad: idiom = "pad"
        case .mac: idiom = "mac"
        case .tv: idiom = "tv"
        case .vision: idiom = "vision"
        default: idiom = "unknown"
        }

        return .object([
            "systemVersion": .string(UIDevice.current.systemVersion),
            "deviceType": .string(idiom),
            "language": .string(Locale.preferredLanguages.first ?? Locale.current.identifier),
            "timezone": .string(TimeZone.autoupdatingCurrent.identifier),
            "lowPowerMode": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled),
            "accessibility": .object([
                "voiceOverEnabled": .bool(UIAccessibility.isVoiceOverRunning),
                "switchControlEnabled": .bool(UIAccessibility.isSwitchControlRunning),
                "assistiveTouchEnabled": .bool(UIAccessibility.isAssistiveTouchRunning),
                "boldTextEnabled": .bool(UIAccessibility.isBoldTextEnabled),
                "buttonShapesEnabled": .bool(UIAccessibility.buttonShapesEnabled),
                "closedCaptioningEnabled": .bool(UIAccessibility.isClosedCaptioningEnabled),
                "darkerSystemColorsEnabled": .bool(UIAccessibility.isDarkerSystemColorsEnabled),
                "differentiateWithoutColor": .bool(UIAccessibility.shouldDifferentiateWithoutColor),
                "grayscaleEnabled": .bool(UIAccessibility.isGrayscaleEnabled),
                "guidedAccessEnabled": .bool(UIAccessibility.isGuidedAccessEnabled),
                "invertColorsEnabled": .bool(UIAccessibility.isInvertColorsEnabled),
                "reduceMotionEnabled": .bool(UIAccessibility.isReduceMotionEnabled),
                "reduceTransparencyEnabled": .bool(UIAccessibility.isReduceTransparencyEnabled),
                "monoAudioEnabled": .bool(UIAccessibility.isMonoAudioEnabled),
                "speakScreenEnabled": .bool(UIAccessibility.isSpeakScreenEnabled),
                "speakSelectionEnabled": .bool(UIAccessibility.isSpeakSelectionEnabled),
            ]),
        ])
    }

    private func batteryInfo() -> IOSMiniAppJSONValue {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        if !wasMonitoring {
            device.isBatteryMonitoringEnabled = true
        }
        defer {
            if !wasMonitoring {
                device.isBatteryMonitoringEnabled = false
            }
        }

        let level: IOSMiniAppJSONValue
        if device.batteryLevel >= 0, device.batteryLevel <= 1 {
            level = .number(Double(device.batteryLevel))
        } else {
            level = .null
        }
        let state: String
        switch device.batteryState {
        case .unplugged: state = "unplugged"
        case .charging: state = "charging"
        case .full: state = "full"
        case .unknown: state = "unknown"
        @unknown default: state = "unknown"
        }
        return .object(["level": level, "state": .string(state)])
    }

    private func speechVoices() -> IOSMiniAppJSONValue {
        let voices = AVSpeechSynthesisVoice.speechVoices().map { voice in
            IOSMiniAppJSONValue.object([
                "identifier": .string(voice.identifier),
                "name": .string(voice.name),
                "language": .string(voice.language),
                "quality": .number(Double(voice.quality.rawValue)),
                "gender": .number(Double(voice.gender.rawValue)),
                "voiceTraits": .number(Double(voice.voiceTraits.rawValue)),
            ])
        }
        return .array(voices)
    }

    private func speak(
        text: String,
        language: String?,
        rate: Double,
        pitch: Double,
        volume: Double
    ) throws {
        let utterance = AVSpeechUtterance(string: text)
        if let language {
            guard let voice = AVSpeechSynthesisVoice(language: language) else {
                throw IOSMiniAppDeviceCapabilitiesError.unavailable(
                    "No speech voice is available for language \(language)."
                )
            }
            utterance.voice = voice
        }
        utterance.rate = Float(rate)
        utterance.pitchMultiplier = Float(pitch)
        utterance.volume = Float(volume)
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(utterance)
    }

    private func shareItems(_ params: [String: Any]) throws -> [Any] {
        var items: [Any] = []
        if let rawText = params["text"] {
            guard let text = rawText as? String else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("text must be a string")
            }
            guard text.count <= 20_000 else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("text must contain at most 20000 characters")
            }
            if !text.isEmpty {
                items.append(text)
            }
        }
        if let rawURL = params["url"] {
            guard let urlString = rawURL as? String, !urlString.isEmpty else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("url must be a non-empty string")
            }
            items.append(try Self.validatedOpenURL(urlString))
        }
        guard !items.isEmpty else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("share needs text or url")
        }
        return items
    }

    private func presentShare(items: [Any]) async throws -> IOSMiniAppJSONValue {
        let window = try activeWindow()
        if let transition = window.rootViewController?.presentedViewController?.transitionCoordinator {
            await withCheckedContinuation { continuation in
                let registered = transition.animate(alongsideTransition: nil) { _ in
                    continuation.resume()
                }
                if !registered { continuation.resume() }
            }
        }
        try Task.checkCancellation()
        guard !isClosed else { throw IOSMiniAppDeviceCapabilitiesError.closed }
        guard shareContinuation == nil else {
            throw IOSMiniAppDeviceCapabilitiesError.busy("A MiniApp share sheet is already presented.")
        }
        let presenter = try presentationViewController()
        guard !(presenter is UIAlertController), presenter.presentedViewController == nil else {
            throw IOSMiniAppDeviceCapabilitiesError.busy("Finish the current dialog before sharing.")
        }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            guard let anchor = presentationAnchor else {
                throw IOSMiniAppDeviceCapabilitiesError.notForeground
            }
            let sourceView = anchor.isDescendant(of: presenter.view) ? anchor : presenter.view!
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
            popover.permittedArrowDirections = []
        }
        presentedShareController = controller
        let requestID = UUID()
        shareRequestID = requestID

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<IOSMiniAppJSONValue, Error>) in
                guard !Task.isCancelled, !isClosed else {
                    shareRequestID = nil
                    presentedShareController = nil
                    continuation.resume(throwing: isClosed ? IOSMiniAppDeviceCapabilitiesError.closed : CancellationError())
                    return
                }
                shareContinuation = continuation
                controller.completionWithItemsHandler = { [weak self] _, completed, _, activityError in
                    Task { @MainActor [weak self] in
                        self?.finishShare(requestID: requestID, completed: completed, error: activityError)
                    }
                }
                presenter.present(controller, animated: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishShare(requestID: requestID, completed: false, error: nil)
            }
        }
    }

    private func finishShare(
        requestID: UUID? = nil,
        completed: Bool,
        error: Error? = nil
    ) {
        if let requestID, shareRequestID != requestID { return }
        guard let continuation = shareContinuation else {
            shareRequestID = nil
            let controller = presentedShareController
            presentedShareController = nil
            if controller?.presentingViewController != nil {
                controller?.dismiss(animated: false)
            }
            return
        }
        shareContinuation = nil
        shareRequestID = nil
        let controller = presentedShareController
        presentedShareController = nil
        if controller?.presentingViewController != nil {
            controller?.dismiss(animated: false)
        }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: .object(["completed": .bool(completed)]))
        }
    }

    private func generateQRCode(text: String, size: Int) throws -> IOSMiniAppJSONValue {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else {
            throw IOSMiniAppDeviceCapabilitiesError.unavailable("QR code generation is unavailable on this device.")
        }

        let extent = outputImage.extent.integral
        guard extent.width > 0, extent.height > 0,
              extent.width == extent.height else {
            throw IOSMiniAppDeviceCapabilitiesError.unavailable("QR code generation returned an empty image.")
        }
        let context = CIContext(options: nil)
        guard let qrImage = context.createCGImage(outputImage, from: extent) else {
            throw IOSMiniAppDeviceCapabilitiesError.unavailable("QR code image encoding is unavailable.")
        }

        // Draw at an integral module size onto an opaque white canvas. This
        // leaves at least a four-module quiet zone and avoids interpolating
        // QR modules, while retaining the requested size whenever possible.
        let moduleCount = max(qrImage.width, qrImage.height)
        let unitCount = moduleCount + 8
        let moduleScale = max(1, size / unitCount)
        let canvasSide = max(size, unitCount * moduleScale)
        let codeSide = moduleCount * moduleScale
        let margin = (canvasSide - codeSide) / 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: canvasSide, height: canvasSide),
            format: format
        ).image { rendererContext in
            UIColor.white.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide))
            rendererContext.cgContext.interpolationQuality = .none
            rendererContext.cgContext.draw(
                qrImage,
                in: CGRect(x: margin, y: margin, width: codeSide, height: codeSide)
            )
        }
        guard let pngData = image.pngData() else {
            throw IOSMiniAppDeviceCapabilitiesError.unavailable("QR code image encoding is unavailable.")
        }
        return .object([
            "dataURL": .string("data:image/png;base64,\(pngData.base64EncodedString())"),
            "width": .number(Double(canvasSide)),
            "height": .number(Double(canvasSide)),
        ])
    }

    private func acquireBrightnessLease(for screen: UIScreen) {
        claimTransientResourceOwnership()
        if let leasedScreen, leasedScreen !== screen {
            restoreBrightnessIfOwned()
        }
        if originalBrightness == nil {
            leasedScreen = screen
            originalBrightness = screen.brightness
        }
    }

    private func acquireKeepAwakeLease() {
        claimTransientResourceOwnership()
        if originalKeepAwake == nil {
            originalKeepAwake = UIApplication.shared.isIdleTimerDisabled
        }
    }

    private func restoreBrightnessIfOwned() {
        guard let screen = leasedScreen,
              let originalBrightness,
              let lastBrightness,
              abs(screen.brightness - lastBrightness) < 0.0001 else {
            leasedScreen = nil
            originalBrightness = nil
            lastBrightness = nil
            return
        }
        screen.brightness = originalBrightness
        leasedScreen = nil
        self.originalBrightness = nil
        self.lastBrightness = nil
    }

    private func restoreKeepAwakeIfOwned() {
        guard let originalKeepAwake,
              let lastKeepAwake,
              UIApplication.shared.isIdleTimerDisabled == lastKeepAwake else {
            self.originalKeepAwake = nil
            self.lastKeepAwake = nil
            return
        }
        UIApplication.shared.isIdleTimerDisabled = originalKeepAwake
        self.originalKeepAwake = nil
        self.lastKeepAwake = nil
    }

    private func handleWillResignActive() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        finishShare(completed: false)
        if Self.transientResourceOwner === self {
            restoreBrightnessIfOwned()
            restoreKeepAwakeIfOwned()
            Self.transientResourceOwner = nil
        }
        hapticTimes.removeAll()
    }

    private func claimTransientResourceOwnership() {
        guard Self.transientResourceOwner !== self else { return }
        Self.transientResourceOwner?.releaseTransientResources()
        Self.transientResourceOwner = self
    }

    private func releaseTransientResources() {
        restoreBrightnessIfOwned()
        restoreKeepAwakeIfOwned()
        if Self.transientResourceOwner === self {
            Self.transientResourceOwner = nil
        }
    }

    private func requiredString(_ key: String, _ params: [String: Any]) throws -> String {
        guard let value = params[key] else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("missing \(key)")
        }
        guard let string = value as? String else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("\(key) must be a string")
        }
        return string
    }

    private func optionalString(_ key: String, _ params: [String: Any]) throws -> String? {
        guard let value = params[key] else { return nil }
        guard let string = value as? String else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("\(key) must be a string")
        }
        guard !string.isEmpty else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("\(key) must not be empty")
        }
        return string
    }

    private func stringParam(
        _ key: String,
        _ params: [String: Any],
        defaultValue: String
    ) throws -> String {
        guard let value = params[key] else { return defaultValue }
        guard let string = value as? String else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("\(key) must be a string")
        }
        return string
    }

    private func boolParam(_ key: String, _ params: [String: Any]) throws -> Bool {
        guard let value = params[key] else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("missing \(key)")
        }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("\(key) must be a boolean")
            }
            return number.boolValue
        }
        guard let bool = value as? Bool else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("\(key) must be a boolean")
        }
        return bool
    }

    private func numberParam(
        _ key: String,
        _ params: [String: Any],
        defaultValue: Double? = nil,
        range: ClosedRange<Double>
    ) throws -> Double {
        guard let value = params[key] else {
            guard let defaultValue else {
                throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("missing \(key)")
            }
            return defaultValue
        }
        guard let number = strictNumber(value), range.contains(number) else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter(
                "\(key) must be a number in \(range.lowerBound)...\(range.upperBound)"
            )
        }
        return number
    }

    private func integerParam(
        _ key: String,
        _ params: [String: Any],
        defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let value = params[key] else { return defaultValue }
        guard let number = strictNumber(value), number.rounded() == number else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter("\(key) must be an integer")
        }
        guard (Double(range.lowerBound)...Double(range.upperBound)).contains(number) else {
            throw IOSMiniAppDeviceCapabilitiesError.invalidParameter(
                "\(key) must be an integer in \(range.lowerBound)...\(range.upperBound)"
            )
        }
        let integer = Int(number)
        return integer
    }

    private func strictNumber(_ value: Any) -> Double? {
        guard let number = value as? NSNumber else {
            if let value = value as? Double, value.isFinite { return value }
            if let value = value as? Float, value.isFinite { return Double(value) }
            if let value = value as? Int { return Double(value) }
            if let value = value as? Int64 { return Double(value) }
            return nil
        }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }
}
