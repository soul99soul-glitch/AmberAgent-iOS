import Combine
import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class ChatTimelineRowLayoutTests: XCTestCase {
    private final class ContentState: ObservableObject {
        @Published var text = "一行正文"
    }

    private struct UpdatingRow: View {
        @ObservedObject var state: ContentState
        var body: some View { Text(state.text).fixedSize(horizontal: false, vertical: true) }
    }

    func testChildStateAndWidthChangesInvalidateMeasuredRowSize() async throws {
        let state = ContentState()
        let host = UIHostingController(rootView: ChatTimelineRowLayout { UpdatingRow(state: state) })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let proposal = CGSize(width: 300, height: 2_000)
        let short = host.sizeThatFits(in: proposal)
        XCTAssertEqual(host.sizeThatFits(in: proposal), short)

        // The child changes itself after mounting; the layout's input value stays identical.
        state.text = String(repeating: "异步正文继续增长，旧高度不能把内容裁掉。", count: 24)
        try await Task.sleep(for: .milliseconds(80))
        host.view.layoutIfNeeded()
        let long = host.sizeThatFits(in: proposal)
        XCTAssertGreaterThan(long.height, short.height + 100)
        let narrow = host.sizeThatFits(in: CGSize(width: 150, height: 2_000))
        XCTAssertGreaterThan(narrow.height, long.height)
        XCTAssertEqual(host.sizeThatFits(in: proposal), long)
    }
}
