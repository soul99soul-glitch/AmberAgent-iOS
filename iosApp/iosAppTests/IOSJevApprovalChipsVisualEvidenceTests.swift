import SwiftUI
import XCTest
@preconcurrency import Shared
@testable import iosApp

// 审批分诊标签行视觉证据（增强 Phase E）：真实渲染窗口落盘 PNG
// （默认/大字号/窄屏 + 三态组合），供逐像素 UI 审查与回归留档。
// 沿 IOSJevSettingsVisualEvidenceTests 模式。

@MainActor
final class IOSJevApprovalChipsVisualEvidenceTests: XCTestCase {

    func testApprovalChipsLayoutEvidence() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)

        func capture<V: View>(
            _ view: V,
            name: String,
            type: DynamicTypeSize = .large,
            size: CGSize = CGSize(width: 393, height: 120)
        ) async throws {
            let window = UIWindow(windowScene: scene)
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            let host = UIHostingController(rootView: NavigationStack { view }
                .environment(RouterPath())
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .environment(\.dynamicTypeSize, type))
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            window.overrideUserInterfaceStyle = .light
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
            try XCTUnwrap(image.pngData()).write(to: output)
            print("JEV_CHIPS_EVIDENCE \(output.path)")
        }

        // 全确定（是/否/未知各一）。
        try await capture(
            JevApprovalTriageChips(triage: .init(
                requestId: "r1", readonly: .yes, reversible: .no, goalAligned: .unknown
            )),
            name: "jev-chips-mixed"
        )
        // 大字号：胶囊换行/截断检查。
        try await capture(
            JevApprovalTriageChips(triage: .init(
                requestId: "r1", readonly: .yes, reversible: .yes, goalAligned: .yes
            )),
            name: "jev-chips-accessibility2",
            type: .accessibility2,
            size: CGSize(width: 393, height: 200)
        )
        // 窄屏 320。
        try await capture(
            JevApprovalTriageChips(triage: .init(
                requestId: "r1", readonly: .unknown, reversible: .unknown, goalAligned: .unknown
            )),
            name: "jev-chips-narrow",
            size: CGSize(width: 320, height: 120)
        )
        // 最严组合：窄屏 320 + accessibility3（单行必然溢出 → 应垂直堆叠）。
        try await capture(
            JevApprovalTriageChips(triage: .init(
                requestId: "r1", readonly: .yes, reversible: .no, goalAligned: .unknown
            )),
            name: "jev-chips-narrow-a11y3",
            type: .accessibility3,
            size: CGSize(width: 320, height: 320)
        )
    }
}
