import XCTest
import SwiftUI
import Shared
@testable import iosApp

@MainActor
final class IOSPhoneToolPresentationVisualEvidenceTests: XCTestCase {
    func testCaptureDeepSeekFlashThinkingLevels() async throws {
        let languageKey = IOSAppLanguagePreference.defaultsKey
        let previousLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("zh-Hans", forKey: languageKey)
        defer {
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: languageKey) }
            else { UserDefaults.standard.removeObject(forKey: languageKey) }
        }
        let panel = ComposerThinkingPanel(selectedOption: .constant(.low),
                                           options: [.off, .low, .high, .max],
                                           isAvailable: true, onPick: { _ in })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(24)
            .background(AmberTheme.background)
        try await capture(panel, name: "phone-deepseek-flash-thinking-levels", size: CGSize(width: 393, height: 420))
        try await capture(panel, name: "phone-deepseek-flash-thinking-levels-narrow-AX3",
                          type: .accessibility3, size: CGSize(width: 320, height: 420))
    }

    func testCapturePhoneReceiptsAndDetails() async throws {
        let languageKey = IOSAppLanguagePreference.defaultsKey
        let previousLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("zh-Hans", forKey: languageKey)
        defer {
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: languageKey) }
            else { UserDefaults.standard.removeObject(forKey: languageKey) }
        }
        func tool(_ name: String, _ id: String, _ result: String) -> UIMessagePart.Tool {
            UIMessagePart.Tool(toolCallId: id, toolName: name,
                               input: #"{"goal":"private-task-text","text":"private-input-value"}"#,
                               output: [UIMessagePart.Text(text: result, metadata: nil)],
                               approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
        }
        let completed = tool("phone_act", "completed",
                             #"{"outcome":"completed","fresh_observation_available":true,"verification":{"status":"satisfied"}}"#)
        let handback = tool("phone_collect_list", "handback",
                            #"{"status":"handback","outcome":"completed","reason":"当前列表已停止变化，已读取的项目保留，后续请根据最新界面继续。","swipe_count":2,"screen_count":3,"items":[{"text":"private-row"},{"text":"private-row-2"}],"coverage":"observed_screens_only","fresh_observation_available":true}"#)
        let unknown = tool("phone_run_flow", "unknown",
                           #"{"status":"unknown","outcome":"unknown","steps":["open: completed","search: unknown"],"reason":"操作已经发送，但未收到可确认的执行回执。请先查看手机上的实际结果。","retry_safe":false}"#)
        let verification = tool("phone_act", "verification",
                                #"{"outcome":"completed","verification":{"status":"unmet","reason":"预期控件尚未出现"}}"#)
        let steps = [completed, handback, unknown, verification].map(ChatToolStepModel.init(tool:))
        var loadedSubagentStatus = false
        let capsules = ChatToolTimeline(steps: steps, onTapStep: { _ in }, subAgentRunStatusLoader: { _ in
            loadedSubagentStatus = true
            return ["unknown": "completed", "handback": "completed_requires_replan"]
        })
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AmberTheme.background)
        try await capture(capsules, name: "phone-receipt-capsules", size: CGSize(width: 393, height: 340))
        try await capture(capsules, name: "phone-receipt-capsules-narrow-AX3", type: .accessibility3,
                          size: CGSize(width: 320, height: 800))
        XCTAssertFalse(loadedSubagentStatus, "Phone outcomes must not be repainted by child-agent runtime states.")
        for (name, item) in [("unknown", unknown), ("handback", handback)] {
            try await capture(ChatToolDetailSheet(tool: item), name: "phone-receipt-detail-\(name)",
                              size: CGSize(width: 393, height: 852))
            try await capture(ChatToolDetailSheet(tool: item), name: "phone-receipt-detail-\(name)-narrow-AX3",
                              type: .accessibility3, size: CGSize(width: 320, height: 852))
        }
    }

    private func capture<V: View>(_ view: V, name: String, type: DynamicTypeSize = .large,
                                  size: CGSize) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        let host = UIHostingController(rootView: view
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            .environment(\.dynamicTypeSize, type))
        window.rootViewController = host
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(350))
        host.view.layoutIfNeeded()
        XCTAssertEqual(host.view.bounds.width, size.width, accuracy: 0.5)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
