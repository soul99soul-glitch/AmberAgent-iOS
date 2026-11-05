import XCTest
import SwiftUI
import Shared
@testable import iosApp

@MainActor
final class ChatDialogueHostContentTests: ChatNativeTimelineReplayTestCase {
    func testHostSwitchRetainsNativeTimelineAndMeasuresLayout() throws {
        let fixture = makeFixture { model in
            model.messages = (0..<30).flatMap { index in
                [makeUserMessage("问题 \(index)"), makeAssistantMessage(
                    text: "## 答复 \(index)\n" + String(repeating: "这是包含 **重点** 和 `code` 的历史消息。\n\n", count: 4),
                    finished: true
                )]
            }
        }
        defer { fixture.tearDown() }
        let local = fixture.host.rootView
        func content(cloud: Bool) -> some View {
            ChatDialogueHostContent(isCloudSelected: cloud) { local } cloud: {
                Text("云端对话")
            }
        }
        let host = UIHostingController(rootView: content(cloud: false))
        fixture.window.rootViewController = host
        fixture.window.layoutIfNeeded()
        pump(seconds: 0.3)
        let originalScroll = try XCTUnwrap(Fixture.findScrollView(in: host.view))
        var toCloud: [Double] = []
        var toLocal: [Double] = []
        for _ in 0..<5 {
            let startCloud = CACurrentMediaTime()
            host.rootView = content(cloud: true)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            pump(seconds: 0.01)
            toCloud.append((CACurrentMediaTime() - startCloud) * 1_000)
            let startLocal = CACurrentMediaTime()
            host.rootView = content(cloud: false)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            pump(seconds: 0.01)
            toLocal.append((CACurrentMediaTime() - startLocal) * 1_000)
        }
        print("HOST_SWITCH_LAYOUT_MS cloud=\(toCloud) local=\(toLocal)")
        let restoredScroll = try XCTUnwrap(Fixture.findScrollView(in: host.view))
        XCTAssertTrue(originalScroll === restoredScroll, "Host switching must retain the local timeline and its render/scroll caches")
    }
}
