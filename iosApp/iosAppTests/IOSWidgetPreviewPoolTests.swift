import SwiftUI
import WebKit
import XCTest
@testable import iosApp

@MainActor
final class IOSWidgetPreviewPoolTests: XCTestCase {
    func testPendingSnapshotKeepsItsSlotAndRechecksInteractionOrder() {
        let pool = IOSWidgetPreviewPool()
        let cards = (0..<5).map { _ in PoolClient() }
        cards[1].isActive = true
        cards.forEach(pool.request)
        XCTAssertEqual(cards.filter(\.live).count, 4)
        XCTAssertNotNil(cards[0].completeSnapshot)
        XCTAssertFalse(cards[4].live)

        pool.request(cards[0])
        cards[0].finish(UIImage())
        XCTAssertTrue(cards[0].live)
        XCTAssertNil(cards[1].completeSnapshot)
        XCTAssertNotNil(cards[2].completeSnapshot)

        cards[2].finish(nil)
        XCTAssertTrue(cards[2].live)
        XCTAssertNotNil(cards[3].completeSnapshot)
        cards[3].finish(UIImage())
        XCTAssertFalse(cards[3].live)
        XCTAssertTrue(cards[4].live)
        XCTAssertEqual(cards.filter(\.live).count, 4)
    }

    func testPressureSkipsActiveAndFreshFocusDuringSnapshot() {
        let pool = IOSWidgetPreviewPool()
        let cards = (0..<4).map { _ in PoolClient() }
        cards[2].isActive = true
        cards.forEach(pool.request)
        pool.handleMemoryWarning()
        pool.request(cards[0])
        cards[0].finish(UIImage())
        cards[1].finish(UIImage())
        cards[3].finish(UIImage())
        XCTAssertEqual(cards.map(\.live), [true, false, true, false])

        pool.request(cards[1])
        XCTAssertTrue(cards[1].live)
        XCTAssertEqual(cards[1].mounts, 2)
    }

    func testCardKeepsSnapshotAndHeightUntilReloadAndCountsExpandedView() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let model = CardCount()
        let host = UIHostingController(rootView: Cards(model: model))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await wait {
            let views = self.descendants(WKWebView.self, in: host.view)
            return views.count == 4 && views.allSatisfy { abs($0.bounds.height - 112) < 1.5 }
        }

        model.count = 5
        func snapshots() -> [UIButton] {
            descendants(UIButton.self, in: host.view).filter { !$0.isHidden && $0.currentImage != nil }
        }
        try await wait { snapshots().count == 1 }
        let placeholder = try XCTUnwrap(snapshots().first)
        let surface = try XCTUnwrap(placeholder.superview)
        XCTAssertEqual(placeholder.bounds.height, 112, accuracy: 1.5)
        XCTAssertEqual(descendants(WKWebView.self, in: host.view).count, 4)
        XCTAssertTrue(descendants(WKWebView.self, in: surface).isEmpty)
        let image = try XCTUnwrap(placeholder.currentImage?.cgImage)
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(Int(rgba[2]) - Int(rgba[0]), 60, "Snapshot should contain the blue widget")

        placeholder.accessibilityElementDidBecomeFocused()
        XCTAssertNotNil(placeholder.currentImage)
        try await wait {
            placeholder.isHidden && self.descendants(WKWebView.self, in: surface).count == 1
        }
        XCTAssertEqual(surface.bounds.height, 112, accuracy: 1.5)
        let reloaded = try XCTUnwrap(descendants(WKWebView.self, in: surface).first)
        let hasContent = try await reloaded.evaluateJavaScript("!!document.querySelector('#root section')")
        XCTAssertEqual(hasContent as? Bool, true)

        let next = try XCTUnwrap(snapshots().first)
        next.sendActions(for: .primaryActionTriggered)
        try await wait {
            guard let sheet = host.presentedViewController else { return false }
            return self.descendants(WKWebView.self, in: sheet.view).count == 1
                && self.descendants(WKWebView.self, in: host.view).count == 3
        }
        IOSWidgetPreviewPool.shared.handleMemoryWarning()
        try await wait { self.descendants(WKWebView.self, in: host.view).isEmpty }
        let sheet = try XCTUnwrap(host.presentedViewController)
        let page = try XCTUnwrap(descendants(WKWebView.self, in: sheet.view).first)
        try await wait {
            (try? await page.evaluateJavaScript("!!document.querySelector('#root section')")) as? Bool == true
        }
        XCTAssertEqual(snapshots().count, 5)
    }

    private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func wait(line: UInt = #line, _ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "WidgetPreviewPoolTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the widget transition requested at line \(line)"])
            }
            try await Task.sleep(for: .milliseconds(35))
        }
    }
}

@MainActor
private final class PoolClient: IOSWidgetPreviewClient {
    var live = false
    var mounts = 0
    var isActive = false
    var isVisible = true
    var canSnapshot: Bool { live }
    var completeSnapshot: (@MainActor (UIImage?) -> Void)?

    func mount() {
        live = true
        mounts += 1
    }

    func captureSnapshot(_ completion: @escaping @MainActor (UIImage?) -> Void) {
        completeSnapshot = completion
    }

    func finish(_ image: UIImage?) {
        let completion = completeSnapshot
        completeSnapshot = nil
        completion?(image)
    }

    func suspend(with image: UIImage) { live = false }
}

@MainActor @Observable
private final class CardCount {
    var count = 4
}

private struct Cards: View {
    let model: CardCount

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<model.count, id: \.self) { index in
                IOSGenerativeWidgetCard(widget: IOSGenerativeWidget(
                    id: "test-\(index)",
                    widgetCode: "<section style='height:112px;background:#4172cf'>Preview \(index)</section>",
                    complete: true
                ))
            }
        }
    }
}
