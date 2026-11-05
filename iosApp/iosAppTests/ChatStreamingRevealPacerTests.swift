import Combine
import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class ChatStreamingRevealPacerTests: XCTestCase {
    private final class Stream: ObservableObject {
        @Published var text: String
        @Published var isStreaming = true
        @Published var reduceMotion = false

        init(text: String) {
            self.text = text
        }
    }

    private struct Fixture: View {
        @ObservedObject var stream: Stream

        var body: some View {
            ChatStreamingRevealPacer(
                text: stream.text,
                isStreaming: stream.isStreaming,
                reduceMotion: stream.reduceMotion
            ) { revealedText in
                ChatAssistantMarkdownView(
                    markdown: revealedText,
                    isStreaming: stream.isStreaming,
                    hasEverStreamed: true
                )
            }
            .frame(width: 361)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    func testTextAppendedAfterTableKeepsPacingThroughStreamCompletion() async throws {
        let table = """
        | 方案 | 说明 |
        | --- | --- |
        | A | 表格已经显示 |
        """
        let stream = Stream(text: table)
        let host = UIHostingController(rootView: Fixture(stream: stream))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        try await waitUntil(host: host) { self.tableScrollView(in: host.view) != nil }

        // A real provider may send a whole paragraph in one delta after its table.
        // The terminal event must drain this same paragraph at the original rate.
        let tail = "收尾正文：" + String(repeating: "表后正文继续按原速逐字显示，不能整段跳出。", count: 20) + "全文结束标记"
        stream.text = table + "\n\n" + tail
        try await pump(host: host, milliseconds: 300)

        let receivingText = paragraphText(in: host.view)
        XCTAssertTrue(receivingText.contains("收尾正文："), "表后普通正文必须开始显示")
        XCTAssertFalse(receivingText.contains("全文结束标记"), "检测到表格不能让后续正文绕过逐字节奏")

        stream.isStreaming = false
        try await pump(host: host, milliseconds: 200)
        let drainingText = paragraphText(in: host.view)
        XCTAssertGreaterThan(drainingText.count, receivingText.count, "网络流结束后继续按原节奏排空")
        XCTAssertFalse(drainingText.contains("全文结束标记"), "终态不能一次性刷出尚未显示的正文")

        try await waitUntil(host: host) { self.paragraphText(in: host.view).contains("全文结束标记") }
        XCTAssertEqual(paragraphText(in: host.view), tail, "收尾必须完整保留普通正文")
    }

    func testFinalSnapshotTextAfterTableDrainsAndRespectsReduceMotion() async throws {
        let introduction = "已经显示的介绍正文应保持稳定。"
        let table = """
        | 方案 | 说明 |
        | --- | --- |
        | A | 表格已经显示 |
        """
        let stream = Stream(text: introduction + "\n\n" + table)
        let host = UIHostingController(rootView: Fixture(stream: stream))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitUntil(host: host) { self.tableScrollView(in: host.view) != nil }

        let tail = "最终快照正文：" + String(repeating: "最终快照新增的尾文也需要逐字排空。", count: 20) + "最终快照结尾"
        stream.text += "\n\n" + tail
        stream.isStreaming = false
        try await pump(host: host, milliseconds: 300)

        let drainingText = paragraphText(in: host.view)
        XCTAssertTrue(drainingText.hasPrefix(introduction), "切换分块 pacing 不得重播稳定介绍正文")
        XCTAssertTrue(drainingText.contains("最终快照正文："))
        XCTAssertFalse(drainingText.contains("最终快照结尾"), "最终快照新出现的 text block 也必须排空")

        stream.reduceMotion = true
        try await pump(host: host, milliseconds: 150)
        XCTAssertEqual(paragraphText(in: host.view), introduction + tail, "减弱动画应立即给出完整内容")
    }

    func testFirstStreamingChunkContainingTableAndLongTailPacesTheTail() async throws {
        let table = """
        | 方案 | 说明 |
        | --- | --- |
        | A | 首个 chunk 即包含完整表格 |
        """
        let tail = "首块正文：" + String(repeating: "首个大块里的表后正文也必须逐字显示。", count: 20) + "首块结尾标记"
        let stream = Stream(text: table + "\n\n" + tail)
        let host = UIHostingController(rootView: Fixture(stream: stream))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await pump(host: host, milliseconds: 300)

        let receivingText = paragraphText(in: host.view)
        XCTAssertTrue(receivingText.contains("首块正文："))
        XCTAssertFalse(receivingText.contains("首块结尾标记"), "首快照中的 tail 不能误判成已经显示的正文")
    }

    private func paragraphText(in view: UIView) -> String {
        if let textView = view as? UITextView {
            return textView.text ?? ""
        }
        return view.subviews.map { paragraphText(in: $0) }.joined()
    }

    private func tableScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, !(scrollView is UITextView) {
            return scrollView
        }
        return view.subviews.lazy.compactMap { self.tableScrollView(in: $0) }.first
    }

    private func pump(host: UIViewController, milliseconds: Int) async throws {
        for _ in 0..<max(1, milliseconds / 16) {
            try await Task.sleep(for: .milliseconds(16))
            host.view.layoutIfNeeded()
        }
    }

    private func waitUntil(host: UIViewController, condition: () -> Bool) async throws {
        for _ in 0..<250 {
            host.view.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTFail("流式渲染未在 4 秒内到达预期状态")
    }
}
