import SwiftUI
import XCTest
import CryptoKit
@testable import iosApp

@MainActor
final class IOSPhoneControlSettingsVisualTests: XCTestCase {
    func testSettingsAtNormalAndAccessibilityWidths() async throws {
        let suite = "PhoneSettingsVisual.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let languageKey = IOSAppLanguagePreference.defaultsKey
        let previousLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("zh-Hans", forKey: languageKey)
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: languageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: languageKey)
            }
        }
        defaults.set(true, forKey: IOSPhoneControlController.enabledPreferenceKey)
        defaults.set(["com.example.long.application.identifier", "com.apple.mobilenotes"],
                     forKey: IOSPhoneControlController.selectedBundleIDsPreferenceKey)
        let tunnel = PhoneControlTunnelStub()
        let fixture = ReadinessHTTPFixture(bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
        defer { fixture.unregister() }
        let session = ReadinessSessionStub(fixture: fixture)
        let controller = IOSPhoneControlController(defaults: defaults, credentials: VisualPairing(), session: session,
                                                   applications: VisualApplications(), localTunnel: tunnel, onHandoffChange: { _, _ in })
        _ = try await controller.loadInstalledApplications()
        try await controller.addInstalledApplication(bundleID: "com.apple.mobilenotes")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            defaults.removePersistentDomain(forName: suite)
        }
        for (name, width, type, style, prepared, expanded, verified) in [
            ("phone-settings-normal", 393.0, DynamicTypeSize.large, UIUserInterfaceStyle.dark, true, false, false),
            ("phone-settings-accessibility", 320.0, .accessibility3, .light, true, false, false),
            ("phone-settings-setup-normal", 393.0, .large, .dark, false, false, false),
            ("phone-settings-setup-accessibility", 320.0, .accessibility3, .light, false, false, false),
            ("phone-settings-advanced-normal", 393.0, .large, .dark, true, true, false),
            ("phone-settings-advanced-accessibility", 320.0, .accessibility3, .light, true, true, false),
            ("phone-settings-verified-normal", 393.0, .large, .dark, true, false, true),
            ("phone-settings-verified-accessibility", 320.0, .accessibility3, .light, true, false, true),
            ("phone-settings-failure-normal", 393.0, .large, .dark, true, false, false),
            ("phone-settings-failure-accessibility", 320.0, .accessibility3, .light, true, false, false)
        ] {
            tunnel.isPrepared = prepared
            tunnel.state = prepared ? .ready : .unprepared
            if verified { try await controller.checkReadiness() }
            if name.contains("failure") {
                tunnel.startOperation = { _ in
                    throw NSError(domain: "NEVPNErrorDomain", code: 5, userInfo: [NSLocalizedDescriptionKey:
                        "等待 VPN 连接失败（NEVPNStatus=disconnected）：扩展连接中断，系统原因 NEVPNErrorDomain code=5。请根据本次连接阶段检查原因。"])
                }
                try await controller.checkReadiness()
                tunnel.startOperation = nil
                XCTAssertNotNil(controller.readinessReport?.failureMessage)
            }
            window.overrideUserInterfaceStyle = style
            window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            window.rootViewController = UIHostingController(rootView:
                IOSPhoneControlSettingsView(controller: controller, advancedPreparationExpanded: expanded)
                    .environment(\.locale, Locale(identifier: "zh_Hans"))
                    .environment(\.dynamicTypeSize, type))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            try capture(window, name: name)
            try await captureRemainingSettingsPages(window, name: name)
        }
        tunnel.isPrepared = true
        tunnel.state = .ready
        for state in [IOSPhoneControlHandoffState.automated, .pausing, .paused, .resuming] {
            for (suffix, width, type) in [
                ("normal", 393.0, DynamicTypeSize.large),
                ("accessibility", 320.0, .accessibility3)
            ] {
                let runID = "visual-handoff"
                XCTAssertTrue(controller.claim(runID: runID, onStop: {}))
                var lease: IOSPhoneControlToolLease?
                if state == .pausing { lease = try controller.beginPhoneTool(runID: runID) }
                if state != .automated { try controller.requestHumanTakeover(runID: runID) }
                if state == .resuming { try controller.resumeAutomation(runID: runID) }
                XCTAssertEqual(controller.handoffState(runID: runID), state)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                window.overrideUserInterfaceStyle = suffix == "normal" ? .dark : .light
                window.rootViewController = UIHostingController(rootView:
                    IOSPhoneControlSettingsView(controller: controller)
                        .environment(\.locale, Locale(identifier: "zh_Hans"))
                        .environment(\.dynamicTypeSize, type))
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(400))
                window.layoutIfNeeded()
                let name = "phone-settings-handoff-\(state.rawValue)-\(suffix)"
                try capture(window, name: name)
                try await captureRemainingSettingsPages(window, name: name)
                if let lease { controller.endPhoneTool(lease) }
                await controller.stop(runID: runID)
            }
        }
        for (name, width, type) in [
            ("phone-app-picker-normal", 393.0, DynamicTypeSize.large),
            ("phone-app-picker-accessibility", 320.0, .accessibility3)
        ] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            window.rootViewController = UIHostingController(rootView:
                IOSPhoneControlAppPicker(controller: controller)
                    .environment(\.locale, Locale(identifier: "zh_Hans"))
                    .environment(\.dynamicTypeSize, type))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            try capture(window, name: name)
        }
    }

    func testConnectionModesAtNarrowAndAccessibilityWidths() async throws {
        let languageKey = IOSAppLanguagePreference.defaultsKey
        let previousLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("zh-Hans", forKey: languageKey)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: languageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: languageKey)
            }
        }
        for (name, mode, width, type, expanded, verified) in [
            ("phone-settings-embedded-normal", IOSPhoneControlConnectionMode.embedded, 393.0, DynamicTypeSize.large, false, false),
            ("phone-settings-embedded-narrow", .embedded, 320.0, .large, false, false),
            ("phone-settings-embedded-accessibility", .embedded, 320.0, .accessibility3, false, false),
            ("phone-settings-existing-vpn-normal", .existingVPN, 393.0, .large, false, false),
            ("phone-settings-existing-vpn-narrow", .existingVPN, 320.0, .large, false, false),
            ("phone-settings-existing-vpn-accessibility", .existingVPN, 320.0, .accessibility3, false, false),
            ("phone-settings-existing-vpn-advanced-accessibility", .existingVPN, 320.0, .accessibility3, true, false),
            ("phone-settings-existing-vpn-verified-normal", .existingVPN, 393.0, .large, false, true),
            ("phone-settings-existing-vpn-verified-accessibility", .existingVPN, 320.0, .accessibility3, false, true),
            ("phone-settings-existing-vpn-failure-normal", .existingVPN, 393.0, .large, false, false),
            ("phone-settings-existing-vpn-failure-accessibility", .existingVPN, 320.0, .accessibility3, false, false)
        ] {
            let suite = "PhoneSettingsConnectionVisual.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: IOSPhoneControlController.enabledPreferenceKey)
            if mode == .existingVPN {
                defaults.set(mode.rawValue, forKey: IOSPhoneControlController.connectionModePreferenceKey)
            }
            defaults.set(["com.apple.mobilenotes"], forKey: IOSPhoneControlController.selectedBundleIDsPreferenceKey)
            let tunnel = PhoneControlTunnelStub()
            tunnel.isPrepared = false
            // A stale built-in failure must not appear as the external VPN's state.
            tunnel.state = mode == .existingVPN ? .failed("旧内置连接错误") : .unprepared
            let fixture = ReadinessHTTPFixture(bundleID: try XCTUnwrap(Bundle.main.bundleIdentifier))
            defer { fixture.unregister() }
            let failed = name.contains("failure")
            let controller = IOSPhoneControlController(
                defaults: defaults, credentials: VisualPairing(),
                session: ReadinessSessionStub(fixture: fixture, failStartup: failed),
                applications: VisualApplications(), localTunnel: tunnel, onHandoffChange: { _, _ in }
            )
            await controller.refreshPreparation()
            XCTAssertEqual(controller.connectionMode, mode)
            if verified || failed { try await controller.checkReadiness() }
            if verified {
                XCTAssertNotNil(controller.readinessReport?.connectionVerifiedAt)
                XCTAssertNotNil(controller.readinessReport?.uiReadAt)
            } else {
                XCTAssertNil(controller.readinessReport?.connectionVerifiedAt)
            }
            if failed { XCTAssertNotNil(controller.readinessReport?.failureMessage) }
            if mode == .existingVPN {
                XCTAssertEqual(tunnel.refreshCount, 0)
                XCTAssertTrue(tunnel.startOwners.isEmpty)
                XCTAssertTrue(tunnel.stopOwners.isEmpty)
            }
            window.overrideUserInterfaceStyle = type.isAccessibilitySize ? .light : .dark
            window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            window.rootViewController = UIHostingController(rootView:
                IOSPhoneControlSettingsView(controller: controller, advancedPreparationExpanded: expanded)
                    .environment(\.locale, Locale(identifier: "zh_Hans"))
                    .environment(\.dynamicTypeSize, type))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            try capture(window, name: name)
            try await captureRemainingSettingsPages(window, name: name)
        }
    }

    private func captureRemainingSettingsPages(_ window: UIWindow, name: String) async throws {
        let scrollView = try XCTUnwrap(firstScrollView(in: window))
        let pageHeight = scrollView.bounds.height
            - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom
        XCTAssertGreaterThan(pageHeight, 0)
        guard pageHeight > 0 else { return }
        var page = 2
        while scrollView.contentOffset.y + pageHeight < scrollView.contentSize.height - 1 {
            let oldOffset = scrollView.contentOffset.y
            let nextPage = CGRect(x: 0, y: oldOffset + pageHeight,
                                  width: scrollView.bounds.width, height: pageHeight)
            // Capture every viewport so the connection setup below the app list
            // and expanded advanced preparation are reviewed at both text sizes.
            scrollView.scrollRectToVisible(nextPage, animated: false)
            try await Task.sleep(for: .milliseconds(120))
            window.layoutIfNeeded()
            guard scrollView.contentOffset.y > oldOffset else { break }
            try capture(window, name: "\(name)-page-\(page)")
            page += 1
        }
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }

    private func capture(_ window: UIWindow, name: String) throws {
        var hierarchyComplete = false
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            hierarchyComplete = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("PHONE_SETTINGS_EVIDENCE \(url.path)")
        XCTAssertTrue(hierarchyComplete, "Incomplete hierarchy snapshot: \(name)")
    }
}

private actor VisualPairing: IOSPhoneControlCredentialStoring {
    func loadPairing() throws -> Data? {
        let key = Curve25519.Signing.PrivateKey()
        return try PropertyListSerialization.data(fromPropertyList: [
            "public_key": key.publicKey.rawRepresentation,
            "private_key": key.rawRepresentation,
            "identifier": UUID().uuidString
        ], format: .xml, options: 0)
    }
    func savePairing(_ data: Data) {}
    func deletePairing() {}
}

private struct VisualApplications: PhoneControlApplicationDiscovering {
    func installedApplications(pairing: Data, connectionMode: IOSPhoneControlConnectionMode) async throws -> [PhoneControlInstalledApp] {
        [
            .init(bundleID: "com.apple.mobilenotes", name: "备忘录", isSystem: true),
            .init(bundleID: "com.example.office", name: "小米办公 Pro", isSystem: false),
            .init(bundleID: "com.example.long.application.identifier", name: "用于检查长名称换行和边距的示例应用", isSystem: false)
        ]
    }
}
