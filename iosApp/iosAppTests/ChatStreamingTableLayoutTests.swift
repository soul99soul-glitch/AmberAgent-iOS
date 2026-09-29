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

    // MARK: - Measure cache vs. full-measure equivalence

    /// `AmberTableLayout.updateCache` reuses measurements only while the content
    /// fingerprint is unchanged; a table grown character by character must land
    /// on exactly the layout of the finished markdown rendered once
    /// (`AmberMarkdownView`, the historical-message table renderer). Row heights
    /// are recovered from each row's bottom hairline overlay: its y is the
    /// cumulative row height, so equal sequences prove equal heights row by row.
    func testTableMeasureCacheMatchesFullMeasureRowByRow() async throws {
        let table = """
        | 方案 | 说明 | 状态 |
        | --- | --- | --- |
        | A | 简短 | ok |
        | 逐渐变长的方案名称用于测试列宽变化 | 这一列的说明文字足够长，需要在渲染时换行显示，用来验证列宽变化后同列其它单元格是否也被正确重新测量 | pending |
        | B | 最后一行 | done |
        | C | 追加的新行，验证增量测量的末尾追加场景 | live |
        """

        let incremental = try await growIncrementally(table)
        defer { incremental.tearDown() }
        let full = try await renderOnce(table)
        defer { full.tearDown() }

        let incrementalTable = try XCTUnwrap(scrollView(in: incremental.host.view), "增量渲染必须产出表格")
        let fullTable = try XCTUnwrap(scrollView(in: full.host.view), "全量渲染必须产出表格")

        XCTAssertEqual(
            incrementalTable.contentSize.width, fullTable.contentSize.width, accuracy: 0.5,
            "增量测量得到的表格总宽度（列宽之和）必须与全量测量一致"
        )
        XCTAssertEqual(
            incrementalTable.contentSize.height, fullTable.contentSize.height, accuracy: 0.5,
            "增量测量得到的表格总高度（行高之和）必须与全量测量一致"
        )

        let incrementalHairlines = rowHairlineYPositions(in: incremental.host.view)
        let fullHairlines = rowHairlineYPositions(in: full.host.view)
        XCTAssertFalse(fullHairlines.isEmpty, "测试夹具应至少产生一条行分隔线")
        XCTAssertEqual(incrementalHairlines.count, fullHairlines.count, "行分隔线数量应一致（行数、列数一致）")
        for (incrementalY, fullY) in zip(incrementalHairlines, fullHairlines) {
            XCTAssertEqual(incrementalY, fullY, accuracy: 0.5, "逐行行高（分隔线累计位置）必须与全量测量逐一相等")
        }
    }

    private struct StableFixture: View {
        @ObservedObject var stream: Stream
        var body: some View {
            AmberMarkdownView(markdown: stream.text)
                .frame(width: 361)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private struct HostedFixture {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        @MainActor func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    @MainActor
    private func makeHostedWindow(_ view: some View) throws -> (host: UIHostingController<AnyView>, window: UIWindow) {
        let host = UIHostingController(rootView: AnyView(view))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (host, window)
    }

    private func growIncrementally(_ table: String) async throws -> HostedFixture {
        let stream = Stream()
        let (host, window) = try makeHostedWindow(StableFixture(stream: stream))
        let characters = Array(table)
        for end in stride(from: 24, through: characters.count, by: 4) {
            stream.text = String(characters.prefix(min(end, characters.count)))
            for _ in 0..<2 {
                try await Task.sleep(for: .milliseconds(8))
                host.view.layoutIfNeeded()
            }
        }
        stream.text = table
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(16))
            host.view.layoutIfNeeded()
        }
        return HostedFixture(host: host, window: window)
    }

    private func renderOnce(_ table: String) async throws -> HostedFixture {
        let (host, window) = try makeHostedWindow(
            AmberMarkdownView(markdown: table)
                .frame(width: 361)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
        )
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(16))
            host.view.layoutIfNeeded()
        }
        return HostedFixture(host: host, window: window)
    }

    /// Bottom-hairline row separators (`renderTableCell`'s
    /// `.overlay(alignment: .bottom) { Rectangle()...frame(height: 0.5) }`) are
    /// the only 0.5pt-tall painted rects in this fixture. SwiftUI composites
    /// plain shape fills as `CALayer`s rather than individual `UIView`s, so this
    /// walks the layer tree (not `subviews`) filtering by bounds height, and
    /// recovers every row boundary's y position in window space.
    private func rowHairlineYPositions(in root: UIView) -> [CGFloat] {
        guard let window = root.window else { return [] }
        var matches: [CGFloat] = []
        func walk(_ layer: CALayer) {
            if (0.3...0.7).contains(layer.bounds.height), layer.bounds.width > 4 {
                let converted = layer.convert(layer.bounds, to: window.layer)
                matches.append(converted.minY)
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(root.layer)
        return matches.sorted()
    }

}
