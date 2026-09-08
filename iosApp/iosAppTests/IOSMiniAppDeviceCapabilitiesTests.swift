import Foundation
import CoreImage
import UIKit
import XCTest
@testable import iosApp

@MainActor
final class IOSMiniAppDeviceCapabilitiesTests: XCTestCase {
    func testValidatedOpenURLAllowsOnlySupportedPublicForms() throws {
        XCTAssertEqual(
            try IOSMiniAppDeviceCapabilities.validatedOpenURL("https://example.com/path#part").scheme,
            "https"
        )
        XCTAssertEqual(
            try IOSMiniAppDeviceCapabilities.validatedOpenURL("mailto:hello@example.com?subject=Hi").scheme,
            "mailto"
        )
        XCTAssertEqual(
            try IOSMiniAppDeviceCapabilities.validatedOpenURL("tel:+8613800138000").scheme,
            "tel"
        )

        for value in [
            "http://example.com",
            "javascript:alert(1)",
            "custom://example.com",
            "https://user:password@example.com",
            "https://127.0.0.1/admin",
            "https://localhost/admin",
            "tel:",
        ] {
            XCTAssertThrowsError(
                try IOSMiniAppDeviceCapabilities.validatedOpenURL(value),
                value
            )
        }
    }

    func testDeviceInfoAndBatteryHaveStablePrivacyBoundedShape() async throws {
        let capabilities = IOSMiniAppDeviceCapabilities()
        let info = try await capabilities.dispatch(method: "device.getInfo", params: [:])
        guard case .object(let object) = info else {
            return XCTFail("device.getInfo must return an object")
        }
        XCTAssertNotNil(object["systemVersion"])
        XCTAssertNotNil(object["deviceType"])
        XCTAssertNotNil(object["language"])
        XCTAssertNotNil(object["timezone"])
        XCTAssertNotNil(object["lowPowerMode"])
        XCTAssertNotNil(object["accessibility"])
        XCTAssertNil(object["name"])
        XCTAssertNil(object["identifier"])

        let battery = try await capabilities.dispatch(method: "device.getBattery", params: [:])
        guard case .object(let batteryObject) = battery,
              case .string(let state)? = batteryObject["state"] else {
            return XCTFail("device.getBattery must return level and state")
        }
        XCTAssertTrue(["unknown", "unplugged", "charging", "full"].contains(state))
        if case .number(let level)? = batteryObject["level"] {
            XCTAssertTrue((0...1).contains(level))
        } else {
            XCTAssertEqual(batteryObject["level"], .null)
        }
    }

    func testQRCodeReturnsRequestedPNGDimensions() async throws {
        let capabilities = IOSMiniAppDeviceCapabilities()
        let result = try await capabilities.dispatch(
            method: "qrcode.generate",
            params: ["text": "Amber MiniApp", "size": 192]
        )
        guard case .object(let object) = result,
              case .string(let dataURL)? = object["dataURL"],
              case .number(let width)? = object["width"],
              case .number(let height)? = object["height"] else {
            return XCTFail("qrcode.generate returned an invalid payload")
        }
        XCTAssertTrue(dataURL.hasPrefix("data:image/png;base64,"))
        let encoded = String(dataURL.dropFirst("data:image/png;base64,".count))
        let png = try XCTUnwrap(Data(base64Encoded: encoded))
        let image = try XCTUnwrap(UIImage(data: png))
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(width, Double(cgImage.width))
        XCTAssertEqual(height, Double(cgImage.height))
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(options: nil),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: CIImage(cgImage: cgImage)) as? [CIQRCodeFeature]
        XCTAssertEqual(features?.first?.messageString, "Amber MiniApp")
    }

    func testBooleanAndRangeValidationDoesNotCoerceNumbers() async {
        let capabilities = IOSMiniAppDeviceCapabilities()

        do {
            _ = try await capabilities.dispatch(method: "screen.setKeepAwake", params: ["enabled": 1])
            XCTFail("numeric enabled must not be accepted as a boolean")
        } catch let error as IOSMiniAppDeviceCapabilitiesError {
            XCTAssertEqual(error, .invalidParameter("enabled must be a boolean"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        do {
            _ = try await capabilities.dispatch(method: "qrcode.generate", params: ["text": "x", "size": 127])
            XCTFail("out-of-range QR size must be rejected")
        } catch let error as IOSMiniAppDeviceCapabilitiesError {
            XCTAssertTrue(error.localizedDescription.contains("128...1024"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let invalidSizes: [Any] = [1e300, Double.nan, true]
        for value in invalidSizes {
            do {
                _ = try await capabilities.dispatch(method: "qrcode.generate", params: ["text": "x", "size": value])
                XCTFail("invalid QR size must be rejected: \(value)")
            } catch let error as IOSMiniAppDeviceCapabilitiesError {
                XCTAssertTrue(error.localizedDescription.contains("size"))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSpeechNeedsTheRunnerSceneToBeForegroundActive() async {
        let capabilities = IOSMiniAppDeviceCapabilities()
        for (method, params) in [
            ("speech.speak", ["text": "hello" as Any]),
            ("speech.resume", [:]),
        ] {
            do {
                _ = try await capabilities.dispatch(method: method, params: params)
                XCTFail("speech method must reject without an active runner anchor")
            } catch let error as IOSMiniAppDeviceCapabilitiesError {
                XCTAssertEqual(error, .notForeground)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testCloseStopsFurtherDispatch() async throws {
        let capabilities = IOSMiniAppDeviceCapabilities()
        capabilities.close()
        do {
            _ = try await capabilities.dispatch(method: "device.getInfo", params: [:])
            XCTFail("closed capabilities must reject late calls")
        } catch let error as IOSMiniAppDeviceCapabilitiesError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testScreenOwnershipHandoffAndSceneDeactivationRestoreState() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let anchor = try XCTUnwrap(window.rootViewController?.view)
        let initialKeepAwake = UIApplication.shared.isIdleTimerDisabled
        let initialBrightness = scene.screen.brightness
        let first = IOSMiniAppDeviceCapabilities()
        let second = IOSMiniAppDeviceCapabilities()
        first.presentationAnchor = anchor
        second.presentationAnchor = anchor
        defer {
            first.close()
            second.close()
            UIApplication.shared.isIdleTimerDisabled = initialKeepAwake
            scene.screen.brightness = initialBrightness
            window.isHidden = true
            previousWindow?.makeKey()
        }
        UIApplication.shared.isIdleTimerDisabled = false
        _ = try await first.dispatch(method: "screen.setBrightness", params: ["brightness": 0.37])
        _ = try await first.dispatch(method: "screen.setKeepAwake", params: ["enabled": true])
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        _ = try await second.dispatch(method: "screen.setKeepAwake", params: ["enabled": true])
        XCTAssertEqual(scene.screen.brightness, initialBrightness, accuracy: 0.01)
        first.close()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "closing an old owner must not undo the new owner")
        second.suspend()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        _ = try await second.dispatch(method: "screen.setKeepAwake", params: ["enabled": true])
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        for _ in 0..<50 where UIApplication.shared.isIdleTimerDisabled {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "scene deactivation must release keep-awake")
    }

    func testSharePresentsAfterPermissionAlertDismissalAndCloseResolvesRequest() async throws {
        try await checkSharePresentation(withPermissionTransition: true)
    }

    func testSharePresentsWithoutPermissionTransition() async throws {
        try await checkSharePresentation(withPermissionTransition: false)
    }

    func testShareAnchorsToTheCoveringModalPresenter() async throws {
        try await checkSharePresentation(withPermissionTransition: false, withCoveringModal: true)
    }

    private func checkSharePresentation(withPermissionTransition: Bool, withCoveringModal: Bool = false) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let appeared = expectation(description: "presentation host appeared")
        let root = MiniAppPresentationTestController { appeared.fulfill() }
        window.rootViewController = root
        window.makeKeyAndVisible()
        await fulfillment(of: [appeared], timeout: 2)
        let capabilities = IOSMiniAppDeviceCapabilities()
        capabilities.presentationAnchor = root.view
        defer {
            capabilities.close()
            window.isHidden = true
            previousWindow?.makeKey()
        }
        let presenter: UIViewController
        if withCoveringModal {
            let modalAppeared = expectation(description: "covering modal appeared")
            let modal = MiniAppPresentationTestController { modalAppeared.fulfill() }
            modal.modalPresentationStyle = .pageSheet
            modal.view.backgroundColor = .systemBackground
            await withCheckedContinuation { continuation in
                root.present(modal, animated: false) { continuation.resume() }
            }
            await fulfillment(of: [modalAppeared], timeout: 2)
            presenter = modal
        } else {
            presenter = root
        }
        if withPermissionTransition {
            let alert = UIAlertController(title: "允许分享？", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "允许", style: .default))
            await withCheckedContinuation { continuation in
                root.present(alert, animated: false) { continuation.resume() }
            }
            alert.dismiss(animated: true)
        }
        let request = Task { try await capabilities.dispatch(method: "share", params: ["text": "MiniApp share test"]) }
        var presented = false
        for _ in 0..<300 {
            if let controller = presenter.presentedViewController as? UIActivityViewController,
               controller.viewIfLoaded?.window != nil, !controller.isBeingPresented {
                presented = true
                // Compact-width activity sheets adapt their source view to a
                // UIKit transition container. Check the actual popover anchor
                // in a regular-width presentation; both layouts must appear.
                if withCoveringModal, presenter.traitCollection.horizontalSizeClass == .regular,
                   let popover = controller.popoverPresentationController {
                    XCTAssertTrue(popover.sourceView === presenter.view,
                        "source: \(String(describing: popover.sourceView)); expected: \(String(describing: presenter.view)); root: \(String(describing: root.view))")
                    XCTAssertEqual(popover.sourceRect, presenter.view.bounds)
                }
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(presented, "share must appear; observed controller: \(String(describing: presenter.presentedViewController))")
        capabilities.close()
        let result = try await request.value
        XCTAssertEqual(result, .object(["completed": .bool(false)]))
    }
}

@MainActor
private final class MiniAppPresentationTestController: UIViewController {
    private var onFirstAppearance: (() -> Void)?

    init(onFirstAppearance: @escaping () -> Void) {
        self.onFirstAppearance = onFirstAppearance
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let callback = onFirstAppearance
        onFirstAppearance = nil
        callback?()
    }
}
