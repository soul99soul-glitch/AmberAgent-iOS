import XCTest
import UIKit
import SwiftUI
@testable import iosApp

/// iOS 26 隐藏导航栏页面的侧滑返回回归测试。
///
/// 背景：所有 push 页面用 `navigationBarBackButtonHidden(true)` +
/// `toolbar(.hidden, for: .navigationBar)` 自绘 header。iOS 26 上 UIKit 通过
/// SwiftUI 私有子类 UIKitNavigationController 上的私有 delegate 钩子
/// （`_gestureRecognizer:shouldReceiveTouch:`）否决返回手势；把 nav 自己设成
/// delegate 的旧修复因此失效。现在 delegate 换成不实现私有钩子的
/// `IOSInteractivePopGestureDelegate`，且同时接管 iOS 26 新增的
/// `interactiveContentPopGestureRecognizer`（限制在左缘带）。
final class IOSInteractivePopGestureTests: XCTestCase {

    @MainActor
    func testPopGestureDelegatesInstalledAndGated() throws {
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.loadViewIfNeeded()

        let edge = try XCTUnwrap(nav.interactivePopGestureRecognizer)
        // delegate 必须是专用对象，而不是 nav 自己（nav 私有实现了否决钩子）。
        let edgeDelegate = try XCTUnwrap(edge.delegate as? IOSInteractivePopGestureDelegate)
        XCTAssertFalse(edge.delegate === nav)

        // 根页面（count=1）不放行。
        XCTAssertFalse(edgeDelegate.gestureRecognizerShouldBegin(edge))

        nav.pushViewController(UIViewController(), animated: false)
        // push 后（count=2）边缘手势放行。
        XCTAssertTrue(edgeDelegate.gestureRecognizerShouldBegin(edge))

        if #available(iOS 26.0, *) {
            let content = try XCTUnwrap(nav.interactiveContentPopGestureRecognizer)
            let contentDelegate = try XCTUnwrap(content.delegate as? IOSInteractivePopGestureDelegate)
            // 同一个 delegate 实例管理两个识别器。
            XCTAssertTrue(contentDelegate === edgeDelegate)
        }
    }

    /// 识别器 delegate 被外部覆盖/重置后，layout 时必须重新装上我们的 delegate。
    @MainActor
    func testPopGestureDelegateReappliedOnLayout() throws {
        final class DummyDelegate: NSObject, UIGestureRecognizerDelegate {}
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.loadViewIfNeeded()
        let edge = try XCTUnwrap(nav.interactivePopGestureRecognizer)

        let dummy = DummyDelegate()
        edge.delegate = dummy
        XCTAssertTrue(edge.delegate === dummy)

        nav.viewWillLayoutSubviews()
        XCTAssertTrue(edge.delegate is IOSInteractivePopGestureDelegate)
    }

    /// 真实 App 进程内：SwiftUI NavigationStack 底层 nav 的两个识别器都应已接管。
    @MainActor
    func testLiveAppNavigationGestureState() throws {
        func findNavs(in view: UIView, into result: inout [UINavigationController]) {
            var responder: UIResponder? = view.next
            while let r = responder {
                if let nav = r as? UINavigationController {
                    if !result.contains(where: { $0 === nav }) { result.append(nav) }
                    break
                }
                responder = r.next
            }
            for sub in view.subviews { findNavs(in: sub, into: &result) }
        }

        var navs: [UINavigationController] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows {
                if let root = window.rootViewController?.view {
                    findNavs(in: root, into: &navs)
                }
            }
        }
        let nav = try XCTUnwrap(navs.first, "live app should have a UINavigationController")

        let edge = try XCTUnwrap(nav.interactivePopGestureRecognizer)
        XCTAssertTrue(edge.delegate is IOSInteractivePopGestureDelegate,
                      "live app edge delegate = \(type(of: edge.delegate))")
        XCTAssertTrue(edge.isEnabled)

        if #available(iOS 26.0, *) {
            let content = try XCTUnwrap(nav.interactiveContentPopGestureRecognizer)
            XCTAssertTrue(content.delegate is IOSInteractivePopGestureDelegate,
                          "live app content delegate = \(type(of: content.delegate))")
        }
    }
}
