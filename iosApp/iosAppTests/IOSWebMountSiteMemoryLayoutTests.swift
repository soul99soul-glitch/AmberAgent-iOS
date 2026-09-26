import XCTest
import SwiftUI
import Shared
@testable import iosApp

@MainActor
final class IOSWebMountSiteMemoryLayoutTests: XCTestCase {
    func testSiteMemorySheetAndApprovalCardRenderAcrossAppearanceAndTextSize() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "site-memory-layout-\(UUID().uuidString)"))
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        registry.replaceSiteMemory(host: "github.com", entries: [
            .init(id: "page", kind: .pages, name: "很长的项目订单查询页面名称，需要在较大字号下完整换行",
                  detail: "用于查看订单与最新处理状态。页面内容变化时以实际页面为准。",
                  urlPattern: "https://github.com/example/project/orders/history/very-long-path",
                  locatorJSON: nil, updatedAtMillis: 1_790_000_000_000, source: .agent),
            .init(id: "action", kind: .actions, name: "打开筛选菜单",
                  detail: "先用 locator 找到当前 ref，再执行点击。",
                  urlPattern: nil,
                  locatorJSON: #"{"role":"button","name":"筛选","url_pattern":"https://github.com/example/project/orders","stable_attributes":{"aria-label":"按订单状态筛选项目结果","data-testid":"project-order-status-filter","name":"order_status","placeholder":"选择需要查看的项目订单状态"},"landmarks":[{"role":"navigation","name":"项目侧边导航"},{"role":"main","name":"项目订单列表"}],"same_role_index":2}"#,
                  updatedAtMillis: 1_790_000_000_000, source: .user)
        ])
        let approval = WebMountToolApprovalRequest(
            id: "site-memory-approval", toolName: "wm_site_memory", siteId: "github",
            siteName: "GitHub", host: "github.com", backend: "local", mcpServerName: nil,
            redactedURL: "https://github.com", snapshotId: nil, target: nil,
            action: "修改站点记忆", consequence: "批准后会将卡片列出的条目变更保存到本机站点记忆。",
            screenshotRetentionWarning: nil,
            siteMemoryChanges: [
                "新增 [pages] 项目订单查询页面：用于查看最新处理状态 · https://github.com/example/project/orders",
                "修改 [actions] 打开筛选菜单：旧说明 → [actions] 打开筛选菜单：先用 locator 找到当前 ref"
            ],
            siteMemoryBaseline: "layout-fixture",
            requiresHumanHandoff: false, reason: "站点记忆修改需要逐次用户确认。",
            sessionId: nil, runId: nil
        )
        for style in [UIUserInterfaceStyle.light, .dark] {
            for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
                let suffix = "\(style == .dark ? "dark" : "light")-\(category == .large ? "normal" : "large")"
                try render(WebMountSiteMemorySheet(host: "github.com", registry: registry, onClose: {}),
                           name: "site-memory-\(suffix)", style: style, category: category)
                try render(WebMountToolApprovalCard(request: approval, onOpenSession: nil,
                                                    onApprove: {}, onDeny: {}),
                           name: "approval-\(suffix)", style: style, category: category)
            }
        }
    }

    private func render<V: View>(_ view: V, name: String, style: UIUserInterfaceStyle,
                                 category: UIContentSizeCategory) throws {
        let controller = UIHostingController(rootView: view
            .environment(\.colorScheme, style == .dark ? .dark : .light)
            .environment(\.dynamicTypeSize, category == .large ? .large : .accessibility5))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.overrideUserInterfaceStyle = style
        window.traitOverrides.preferredContentSizeCategory = category
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 10_000, name)
        let directory = URL(fileURLWithPath: "/tmp/amber-webmount-stage2-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        if category != .large {
            let scroll = try XCTUnwrap(scrollViews(in: controller.view).max(by: {
                $0.contentSize.height - $0.bounds.height < $1.contentSize.height - $1.bounds.height
            }))
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height, name)
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
            scroll.layoutIfNeeded()
            let bottom = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(bottom.pngData()).write(to: directory.appendingPathComponent("\(name)-bottom.png"))
        }
        window.isHidden = true
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollViews(in:))
    }
}
