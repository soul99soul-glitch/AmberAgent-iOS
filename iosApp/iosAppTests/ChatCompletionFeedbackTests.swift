import Combine
import Shared
import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class ChatCompletionFeedbackTests: XCTestCase {
    private final class Stream: ObservableObject {
        @Published var text: String
        @Published var isStreaming = true
        let feedback: ChatCompletionFeedback

        init(text: String, feedback: ChatCompletionFeedback) {
            self.text = text
            self.feedback = feedback
        }
    }

    private struct Fixture: View {
        @ObservedObject var stream: Stream

        var body: some View {
            ChatStreamingRevealPacer(
                text: stream.text, isStreaming: stream.isStreaming, reduceMotion: false,
                completionFeedback: stream.feedback, messageID: "reply", textPartIndex: 0
            ) { text in
                ChatAssistantMarkdownView(markdown: text, isStreaming: stream.isStreaming, hasEverStreamed: true)
            }
            .id(stream.feedback.runID)
            .frame(width: 361)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    func testRealTableAndFinalSnapshotRevealMustDrainBeforeSingleCompletionFeedback() async throws {
        let defaults = UserDefaults.standard
        let key = IOSDisplayPreferenceKeys.completionHaptic
        let previous = defaults.object(forKey: key)
        var events: [AmberHapticEvent] = []
        AmberHaptics.onTriggerForTesting = { events.append($0) }
        defer {
            AmberHaptics.onTriggerForTesting = nil
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let owner = ChatCompletionFeedback()
        owner.setForegroundVisible(true)
        owner.begin(runID: "off")
        defaults.set(false, forKey: key)
        let stream = Stream(text: "关闭开关时这段正文完成也不能振动。", feedback: owner)
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
        try await pump(host, milliseconds: 120)
        stream.isStreaming = false
        owner.complete(runID: "off", messageID: "reply", textParts: [0: stream.text])
        try await waitUntil(host) { self.paragraphText(in: host.view).contains("完成也不能振动") }
        try await pump(host, milliseconds: 160)
        XCTAssertTrue(events.isEmpty)

        defaults.set(true, forKey: key)
        owner.begin(runID: "table")
        let table = """
        | 方案 | 说明 |
        | --- | --- |
        | A | 表格已经显示 |
        """
        stream.text = table
        stream.isStreaming = true
        try await pump(host, milliseconds: 180)
        let middle = "表后第一段：" + String(repeating: "这一段也必须排空。", count: 6)
        let secondTable = """
        | 方案 | 说明 |
        | --- | --- |
        | B | 第二张表 |
        """
        let tail = "最终快照正文：" + String(repeating: "尾段按原速显示。", count: 16) + "最后正文标记"
        stream.text = table + "\n\n" + middle + "\n\n" + secondTable + "\n\n" + tail
        stream.isStreaming = false
        owner.complete(runID: "table", messageID: "reply", textParts: [0: stream.text])
        try await pump(host, milliseconds: 180)
        XCTAssertTrue(events.isEmpty, "provider 终态和表格排完不能越过两段正文 pacer")
        XCTAssertFalse(paragraphText(in: host.view).contains("最后正文标记"))

        try await waitUntil(host) { events == [.rigidImpact] }
        XCTAssertTrue(paragraphText(in: host.view).contains("最后正文标记"), "触感必须晚于最终可见正文")
        owner.complete(runID: "table", messageID: "reply", textParts: [0: stream.text])
        try await pump(host, milliseconds: 160)
        XCTAssertEqual(events, [.rigidImpact])
    }

    func testCompletionOffIsSilentAndOnWaitsForEveryFinalPartExactlyOnce() {
        withRecordedHaptics { events, defaults in
            let owner = ChatCompletionFeedback()
            owner.setForegroundVisible(true)
            defaults.set(false, forKey: IOSDisplayPreferenceKeys.completionHaptic)
            owner.begin(runID: "off")
            owner.complete(runID: "off", messageID: "reply", textParts: [0: "正文"])
            owner.didDrain(runID: "off", messageID: "reply", partIndex: 0, text: "正文")
            XCTAssertTrue(events.values.isEmpty)

            defaults.set(true, forKey: IOSDisplayPreferenceKeys.completionHaptic)
            owner.begin(runID: "on")
            owner.complete(runID: "on", messageID: "reply", textParts: [0: "正文", 2: "最终尾文"])
            XCTAssertTrue(events.values.isEmpty, "provider 完成时不能提前震动")
            owner.didDrain(runID: "off", messageID: "reply", partIndex: 2, text: "最终尾文")
            owner.didDrain(runID: "on", messageID: "reply", partIndex: 0, text: "正文")
            owner.didDrain(runID: "on", messageID: "reply", partIndex: 2, text: "最终")
            XCTAssertTrue(events.values.isEmpty, "旧 run、其他 part 或旧快照不能代替当前尾文排空")
            owner.didDrain(runID: "on", messageID: "reply", partIndex: 2, text: "最终尾文")
            XCTAssertEqual(events.values, [.rigidImpact])
            owner.complete(runID: "on", messageID: "reply", textParts: [0: "正文"])
            owner.didDrain(runID: "on", messageID: "reply", partIndex: 2, text: "最终尾文")
            XCTAssertEqual(events.values, [.rigidImpact], "重复 terminal / reveal 回调只能触发一次")
        }
    }

    func testEmptyFailedCancelledAndHiddenRepliesDoNotReplayFeedback() {
        var count = 0
        let owner = ChatCompletionFeedback(trigger: { count += 1 })
        owner.setForegroundVisible(true)
        owner.begin(runID: "empty")
        owner.complete(runID: "empty", messageID: "reply", textParts: [:])
        owner.didDrain(runID: "empty", messageID: "reply", partIndex: 0, text: "")
        for runID in ["failed", "cancelled"] {
            owner.begin(runID: runID)
            owner.finishWithoutFeedback(runID: runID)
            owner.didDrain(runID: runID, messageID: "reply", partIndex: 0, text: "部分正文")
            owner.complete(runID: runID, messageID: "reply", textParts: [0: "部分正文"])
        }
        owner.begin(runID: "hidden")
        owner.complete(runID: "hidden", messageID: "reply", textParts: [0: "正文"])
        owner.setForegroundVisible(false)
        owner.setForegroundVisible(true)
        owner.didDrain(runID: "hidden", messageID: "reply", partIndex: 0, text: "正文")
        owner.begin(runID: "new")
        owner.complete(runID: "hidden", messageID: "reply", textParts: [0: "正文"])
        owner.didDrain(runID: "hidden", messageID: "reply", partIndex: 0, text: "正文")
        XCTAssertEqual(count, 0)
    }

    func testPreferenceIsReadWhenRevealDrains() {
        withRecordedHaptics { events, defaults in
            let owner = ChatCompletionFeedback()
            owner.setForegroundVisible(true)
            owner.begin(runID: "changed-setting")
            defaults.set(true, forKey: IOSDisplayPreferenceKeys.completionHaptic)
            owner.complete(runID: "changed-setting", messageID: "reply", textParts: [0: "正文"])
            defaults.set(false, forKey: IOSDisplayPreferenceKeys.completionHaptic)
            owner.didDrain(runID: "changed-setting", messageID: "reply", partIndex: 0, text: "正文")
            XCTAssertTrue(events.values.isEmpty)
            AmberHaptics.trigger(.selection)
            XCTAssertEqual(events.values, [.selection], "普通点击触感继续独立工作")
        }
    }

    func testCloudHostRetainsLocalViewButCancelsItsPendingFeedback() async throws {
        var count = 0
        var localDisappearances = 0
        let owner = ChatCompletionFeedback(trigger: { count += 1 })
        func content(cloud: Bool) -> some View {
            ChatDialogueHostContent(isCloudSelected: cloud) {
                Text("本机对话")
                    .modifier(ChatCompletionFeedbackVisibility(owner: owner, isVisible: !cloud))
                    .onDisappear { localDisappearances += 1 }
            } cloud: {
                Text("云端对话")
            }
        }
        let host = UIHostingController(rootView: content(cloud: false))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_200)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await pump(host, milliseconds: 48)
        owner.begin(runID: "draining")
        owner.complete(runID: "draining", messageID: "reply", textParts: [0: "正文"])
        host.rootView = content(cloud: true)
        try await pump(host, milliseconds: 48)
        XCTAssertEqual(localDisappearances, 0, "切云端保留本机视图，不能依赖 onDisappear 清理触感")
        host.rootView = content(cloud: false)
        try await pump(host, milliseconds: 48)
        owner.didDrain(runID: "draining", messageID: "reply", partIndex: 0, text: "正文")
        XCTAssertEqual(count, 0, "从云端返回不能补发此前丢弃的完成触感")

        host.rootView = content(cloud: true)
        try await pump(host, milliseconds: 48)
        owner.begin(runID: "hidden-terminal")
        owner.complete(runID: "hidden-terminal", messageID: "reply", textParts: [0: "正文"])
        host.rootView = content(cloud: false)
        try await pump(host, milliseconds: 48)
        owner.didDrain(runID: "hidden-terminal", messageID: "reply", partIndex: 0, text: "正文")
        XCTAssertEqual(count, 0)
        owner.begin(runID: "visible-terminal")
        owner.complete(runID: "visible-terminal", messageID: "reply", textParts: [0: "正文"])
        owner.didDrain(runID: "visible-terminal", messageID: "reply", partIndex: 0, text: "正文")
        XCTAssertEqual(count, 1)
    }

    private final class Events {
        var values: [AmberHapticEvent] = []
    }

    private func paragraphText(in view: UIView) -> String {
        if let textView = view as? UITextView { return textView.text ?? "" }
        return view.subviews.map { paragraphText(in: $0) }.joined()
    }

    private func pump(_ host: UIViewController, milliseconds: Int) async throws {
        for _ in 0..<max(1, milliseconds / 16) {
            try await Task.sleep(for: .milliseconds(16))
            host.view.layoutIfNeeded()
        }
    }

    private func waitUntil(_ host: UIViewController, condition: () -> Bool) async throws {
        for _ in 0..<375 {
            host.view.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTFail("完成触感/正文未在 6 秒内到达预期状态")
    }

    private func withRecordedHaptics(_ body: (Events, UserDefaults) -> Void) {
        let defaults = UserDefaults.standard
        let key = IOSDisplayPreferenceKeys.completionHaptic
        let previous = defaults.object(forKey: key)
        let events = Events()
        AmberHaptics.onTriggerForTesting = { events.values.append($0) }
        defer {
            AmberHaptics.onTriggerForTesting = nil
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        body(events, defaults)
    }
}
