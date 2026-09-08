import Combine
import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class ChatStreamingTableLayoutTests: XCTestCase {
    private final class Stream: ObservableObject {
        @Published var text = ""
    }

    private struct Fixture: View {
        @ObservedObject var stream: Stream
        var body: some View {
            ChatAssistantMarkdownView(markdown: stream.text, isStreaming: true)
                .frame(width: 361)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    func testGrowingTableDoesNotShrinkOrReplaceDisplayedTable() async throws {
        let stream = Stream()
        let host = UIHostingController(rootView: Fixture(stream: stream))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let text = """
        | 方案 | 说明 |
        | --- | --- |
        | A | 简短 |
        | 逐渐变长的方案名称 | 说明文字不断增加，足够长时需要换行显示，已经显示的表格应当保持稳定。 |
        | B | 最后一行 |
        """
        var previous: UIScrollView?
        var heights: [CGFloat] = []
        let characters = Array(text)
        for end in stride(from: 24, through: characters.count + 3, by: 4) {
            stream.text = String(characters.prefix(min(end, characters.count)))
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(16))
                host.view.layoutIfNeeded()
                if let table = scrollView(in: host.view) {
                    if let previous { XCTAssertTrue(previous === table, "追加文本不应重建表格") }
                    previous = table
                    heights.append(table.frame.height)
                } else if previous != nil {
                    XCTFail("已经显示的表格不能在增量解析期间退回纯文本")
                }
            }
        }
        XCTAssertGreaterThan(heights.count, 5)
        for (before, after) in zip(heights, heights.dropFirst()) {
            XCTAssertGreaterThanOrEqual(after + 0.5, before, "追加表格内容时旧表格不应收缩")
        }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, !(scroll is UITextView) { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}
