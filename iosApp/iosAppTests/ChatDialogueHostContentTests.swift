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

    func testDialogueHostEnvironmentPausesHiddenChatAnimationsWithoutPausingTopBar() throws {
        let chatViewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("iosApp/ChatView.swift")
        let source = try String(contentsOf: chatViewURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains(".environment(\\.amberIsUnderlyingSheetPresented, isAnyFloatingSheetPresented)"),
            "顶栏仍必须仅受 isAnyFloatingSheetPresented 控制，切到任务/中心页时顶栏头像动画不得被误停"
        )
        XCTAssertTrue(
            source.contains("isAnyFloatingSheetPresented || composerState.activeDuetTab != .chat"),
            "ChatDialogueHostContent 必须在切离对话面板时注入 amberIsUnderlyingSheetPresented = true 以暂停被遮挡的 30fps 空态动画"
        )

        final class PauseProbeBox {
            var topBarPaused: Bool = false
            var dialoguePaused: Bool = false
        }
        struct EnvProbeView: View {
            @Environment(\.amberIsUnderlyingSheetPresented) private var paused
            let onReport: (Bool) -> Void
            var body: some View {
                let _ = onReport(paused)
                Color.clear.frame(width: 10, height: 10)
            }
        }
        struct ShellHarness: View {
            var activeTab: AmberDuetModeTab
            var sheetPresented: Bool
            let box: PauseProbeBox
            var body: some View {
                VStack {
                    EnvProbeView { box.topBarPaused = $0 }
                    ChatDialogueHostContent(isCloudSelected: false) {
                        EnvProbeView { box.dialoguePaused = $0 }
                    } cloud: {
                        Color.clear
                    }
                    .environment(\.amberIsUnderlyingSheetPresented, sheetPresented || activeTab != .chat)
                }
                .environment(\.amberIsUnderlyingSheetPresented, sheetPresented)
            }
        }

        let box = PauseProbeBox()
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let host = UIHostingController(rootView: ShellHarness(activeTab: .chat, sheetPresented: false, box: box))
        fixture.window.rootViewController = host
        fixture.window.layoutIfNeeded()
        pump(seconds: 0.05)
        XCTAssertFalse(box.topBarPaused)
        XCTAssertFalse(box.dialoguePaused)

        host.rootView = ShellHarness(activeTab: .tasks, sheetPresented: false, box: box)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        pump(seconds: 0.05)
        XCTAssertFalse(box.topBarPaused, "切到任务页时顶栏头像不应暂停")
        XCTAssertTrue(box.dialoguePaused, "切到任务页时隐藏的对话区必须暂停空态动画")

        host.rootView = ShellHarness(activeTab: .chat, sheetPresented: false, box: box)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        pump(seconds: 0.05)
        XCTAssertFalse(box.topBarPaused)
        XCTAssertFalse(box.dialoguePaused, "切回对话页后空态动画必须恢复")
    }
}
