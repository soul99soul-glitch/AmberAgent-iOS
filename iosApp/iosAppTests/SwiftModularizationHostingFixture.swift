import SwiftUI
import UIKit
import WebKit
import XCTest

/// A real scene-backed window for layout probes shared by the Phase 5 UI tests.
@MainActor
final class SwiftModularizationHostingFixture {
    let window: UIWindow
    private let previousKeyWindow: UIWindow?

    var windowBounds: CGRect { window.convert(window.bounds, to: nil) }

    var currentView: UIView {
        var controller = window.rootViewController!
        while let presented = controller.presentedViewController { controller = presented }
        return controller.view
    }

    init<Content: View>(root: Content, width: CGFloat, height: CGFloat,
                        type: DynamicTypeSize) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = .light
        window.traitOverrides.preferredContentSizeCategory = type.isAccessibilitySize
            ? .accessibilityExtraLarge : .large
        window.rootViewController = UIHostingController(rootView: root
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            .environment(\.dynamicTypeSize, type))
        window.makeKeyAndVisible()
        window.rootViewController?.view.frame = window.bounds
        window.layoutIfNeeded()
    }

    func close() {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
    }

    func scrollViews() -> [UIScrollView] {
        views(in: currentView).compactMap { $0 as? UIScrollView }
            .filter { !($0 is UITextView) }
    }

    func mainScrollView() -> UIScrollView? {
        scrollViews().max { $0.contentSize.height < $1.contentSize.height }
    }

    func textFields() -> [UITextField] {
        views(in: currentView).compactMap { $0 as? UITextField }
    }

    func textViews() -> [UITextView] {
        views(in: currentView).compactMap { $0 as? UITextView }
    }

    func webViews() -> [WKWebView] {
        views(in: currentView).compactMap { $0 as? WKWebView }
    }

    func scrollToBottom(_ scroll: UIScrollView) {
        scroll.scrollRectToVisible(CGRect(x: 0, y: max(0, scroll.contentSize.height - 1),
                                        width: scroll.bounds.width, height: 1), animated: false)
        window.layoutIfNeeded()
    }

    func scroll(_ scroll: UIScrollView, to view: UIView) {
        scroll.scrollRectToVisible(view.convert(view.bounds, to: scroll), animated: false)
        window.layoutIfNeeded()
    }

    func visibleBounds(of scroll: UIScrollView) -> CGRect {
        scroll.convert(scroll.bounds, to: nil).intersection(windowBounds)
    }

    func assertNoHorizontalOverflow(_ scroll: UIScrollView,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let viewport = visibleBounds(of: scroll)
        XCTAssertGreaterThan(viewport.width, 0, "Scroll viewport is not mounted", file: file, line: line)
        XCTAssertGreaterThan(viewport.height, 0, "Scroll viewport is not mounted", file: file, line: line)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1,
                                 "Scroll content requires horizontal panning", file: file, line: line)
    }

    func capturePNG(_ name: String, in testCase: XCTestCase) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true),
                          "Scene content must be composited")
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
        let directory = URL(fileURLWithPath: "/tmp/amber-phase5-layout-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"),
                                               options: .atomic)
    }

    private func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }
}
