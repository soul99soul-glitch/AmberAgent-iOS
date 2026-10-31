import SwiftUI
import UIKit
import XCTest
@testable import iosApp

/// 竖条启用条件：高度必须按实际按钮数计算，低于内容高度时整条让位，
/// 不能只判断能放下两个按钮。
final class AmberSideRailLayoutTests: XCTestCase {

    func testRequiredHeightCountsEveryButtonAndTheMiddleSpacer() {
        // Home 外屏：搜索 / 设置 / 账户 + 底部新对话。
        XCTAssertEqual(AmberSideRailMetrics.requiredHeight(topCount: 3, bottomCount: 1), 218)
        // Chat 外屏：返回 / 新对话，无底部动作。
        XCTAssertEqual(AmberSideRailMetrics.requiredHeight(topCount: 2, bottomCount: 0), 116)
        // 生成中的 Chat 外屏：返回 / 新对话 + 停止。
        XCTAssertEqual(AmberSideRailMetrics.requiredHeight(topCount: 2, bottomCount: 1), 160)
        XCTAssertEqual(AmberSideRailMetrics.requiredHeight(topCount: 0, bottomCount: 1), 58)
    }

    func testEmptyRailRequiresNoHeight() {
        XCTAssertEqual(AmberSideRailMetrics.requiredHeight(topCount: 0, bottomCount: 0), 0)
    }

    func testMinimumRailWidthFitsADiameterWithBreathingRoom() {
        XCTAssertGreaterThanOrEqual(
            AmberSideRailMetrics.minimumRailWidth,
            AmberSideRailMetrics.buttonDiameter + 16
        )
    }

    func testEmptyRailIsInactiveEvenWithRoom() {
        XCTAssertFalse(AmberSideRailMetrics.isActive(topCount: 0, bottomCount: 0, availableHeight: 1_000))
    }

    func testActivationRequiresTheFullReservedHeight() {
        XCTAssertFalse(AmberSideRailMetrics.isActive(topCount: 3, bottomCount: 1, availableHeight: 217.9))
        XCTAssertTrue(AmberSideRailMetrics.isActive(topCount: 3, bottomCount: 1, availableHeight: 218))
    }

    /// 底部按钮随滚动出现/消失时，启用阈值不能跟着变，否则整条（含返回键）会闪烁。
    func testScrollToBottomAppearingDoesNotChangeActivation() {
        for height in stride(from: 100.0, through: 220.0, by: 2) {
            XCTAssertEqual(
                AmberSideRailMetrics.isActive(topCount: 2, bottomCount: 0, availableHeight: height),
                AmberSideRailMetrics.isActive(topCount: 2, bottomCount: 1, availableHeight: height),
                "height \(height)"
            )
        }
    }

    // MARK: - Phase 5: Modified UI Light / Dark & Accessibility Layout Verification

    @MainActor
    func testPhase5ModifiedViewsRenderLightDarkAndAccessibilityWithoutOverflow() async throws {
        let store = MacGatewayStore.shared
        store.loadBoardFixture()
        defer { store.resetBoardFixtureForTesting() }

        let suite = "Phase5Layout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let permissionStore = IOSPermissionStore(userDefaults: defaults, taskStore: nil)
        let coordinator = IOSSystemPermissionCoordinator()

        let pages: [(name: String, makeView: @MainActor () -> AnyView)] = [
            ("mac-tasks-board", {
                AnyView(
                    NavigationStack {
                        MacTasksBoardView()
                            .environment(RouterPath())
                    }
                )
            }),
            ("mac-gateway-settings", {
                AnyView(
                    NavigationStack {
                        MacGatewaySettingsView()
                            .environment(RouterPath())
                    }
                )
            }),
            ("apple-integrations", {
                AnyView(
                    NavigationStack {
                        IOSAppleIntegrationsView(systemPermissionCoordinator: coordinator)
                            .environment(RouterPath())
                    }
                    .defaultAppStorage(defaults)
                )
            }),
            ("permissions-approval", {
                AnyView(
                    NavigationStack {
                        PermissionsApprovalView(permissionStore: permissionStore)
                            .environment(RouterPath())
                    }
                    .defaultAppStorage(defaults)
                )
            })
        ]

        let outputDir = URL(fileURLWithPath: "/tmp/amber-ios-phase5-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)

        for page in pages {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let styleName = style == .dark ? "dark" : "light"
                let scheme: ColorScheme = style == .dark ? .dark : .light
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
                window.overrideUserInterfaceStyle = style
                window.traitOverrides.preferredContentSizeCategory = .large
                let controller = UIHostingController(
                    rootView: page.makeView()
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, .large)
                        .environment(\.locale, Locale(identifier: "zh_Hans"))
                )
                window.rootViewController = controller
                window.makeKeyAndVisible()
                controller.view.frame = window.bounds
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                window.layoutIfNeeded()

                let scrolls = collectScrollViews(in: controller.view)
                let mainScroll = try XCTUnwrap(scrolls.max { $0.contentSize.height < $1.contentSize.height },
                                               "\(page.name)-\(styleName) must mount a ScrollView")
                XCTAssertLessThanOrEqual(
                    mainScroll.contentSize.width,
                    mainScroll.bounds.width + 1,
                    "\(page.name)-\(styleName) must not overflow horizontally"
                )

                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let pngData = try XCTUnwrap(image.pngData())
                XCTAssertGreaterThan(pngData.count, 10_000, "\(page.name)-\(styleName) screenshot must be non-empty")
                try pngData.write(to: outputDir.appendingPathComponent("\(page.name)-\(styleName).png"), options: .atomic)

                window.isHidden = true
                window.rootViewController = nil
            }

            // Verify Accessibility Dynamic Type (.accessibility3) at standard 393pt width has no horizontal overflow
            let axFixture = try SwiftModularizationHostingFixture(
                root: page.makeView(),
                width: 393,
                height: 852,
                type: .accessibility3
            )
            try await axFixture.settle()
            let axScroll = try XCTUnwrap(axFixture.mainScrollView(), "\(page.name) ax3 scroll missing")
            axFixture.assertNoHorizontalOverflow(axScroll)
            axFixture.close()
        }

        previousKey?.makeKey()
    }

    private func collectScrollViews(in view: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        if let scroll = view as? UIScrollView, !(scroll is UITextView) {
            result.append(scroll)
        }
        for subview in view.subviews {
            result.append(contentsOf: collectScrollViews(in: subview))
        }
        return result
    }
}
