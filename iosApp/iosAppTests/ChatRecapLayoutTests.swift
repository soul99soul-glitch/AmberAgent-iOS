import XCTest
import SwiftUI
import UIKit
@testable import iosApp

@MainActor
final class ChatRecapLayoutTests: XCTestCase {
    func testRecapStatesFitAndCaptureEvidence() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        let recap = ConversationRecap(
            overview: "已确定离线优先的笔记方案，完成数据结构和导出样例。同步冲突的处理仍需确认，接下来验证多设备编辑。",
            nodes: [
                .init(kind: .decision, title: "采用离线优先，联网后同步", messageRef: "m2", messageID: "message-2"),
                .init(kind: .milestone, title: "完成笔记与标签的数据结构", messageRef: "m4", messageID: "message-4"),
                .init(kind: .failure, title: "首次同步验证未通过，冲突规则待定", messageRef: "m6", messageID: "message-6"),
                .init(kind: .artifact, title: "生成 Markdown 导出样例", messageRef: "m8", messageID: "message-8")
            ],
            nextSteps: ["确认多设备编辑时的冲突规则", "补充离线导出的验收步骤"],
            conversationID: "recap-layout", coveredThroughMessageID: "message-8",
            branchID: "main", generatedAt: Date(timeIntervalSince1970: 1)
        )
        let directory = URL(fileURLWithPath: "/tmp/amber-topbar", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, value, loading, stale, error) in [
            ("loading", nil, true, false, nil),
            ("normal", recap, false, false, nil),
            ("stale", recap, false, true, nil),
            ("failure", nil, false, false, "模型返回的内容不是有效的回顾 JSON，请重试。")
        ] as [(String, ConversationRecap?, Bool, Bool, String?)] {
            let size = scene.screen.bounds.size
            window.rootViewController?.dismiss(animated: false)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = UIHostingController(rootView: RecapPreview(
                recap: value, loading: loading, stale: stale, failure: error,
                maxHeight: size.height * 0.55
            ))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(800))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "phase5-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("phase5-\(name).png"), options: .atomic)
            if name == "normal" {
                try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("dockpanel-recap.png"), options: .atomic)
            }
        }

        // 实测生产面板自身，排除宿主窗口安全区；同时覆盖窄屏和长节点文本。
        for width: CGFloat in [340, 300] {
            var measured = CGSize.zero
            let panel = ChatRecapPanel(
                recap: recap, isLoading: false, failure: nil, isStale: true,
                maxHeight: 812 * 0.55,
                onRefresh: {}, onLocate: { _ in }, onNextStep: { _ in }
            )
            .frame(width: width)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 }
            window.rootViewController?.dismiss(animated: false)
            window.rootViewController = UIHostingController(rootView: VStack { panel; Spacer() })
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(measured.width, width, accuracy: 1)
            XCTAssertGreaterThan(measured.height, 100)
            XCTAssertLessThanOrEqual(measured.height, 812 * 0.55 + 1)
        }
    }
}

private struct RecapPreview: View {
    let recap: ConversationRecap?
    let loading: Bool
    let stale: Bool
    let failure: String?
    let maxHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            AmberTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                Text("请整理一下刚才确定的笔记方案。")
                    .padding(16)
                    .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusMedium))
                Text("已完成数据结构与导出样例。接下来，我们可以继续确认多设备编辑时如何处理冲突。")
                    .foregroundStyle(AmberTheme.muted)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, ChatTopBarLayout.controlsHeight + 30)
            ChatTopBarView(
                presentation: .idle(.conversationTitle("离线笔记方案")),
                conversationID: "recap-layout", hasMessages: true, isGenerating: false,
                notices: [], shelfHeight: maxHeight, onBack: {}, onIslandTap: { _ in },
                onCancel: {}, onOpenConversation: { _ in true }, onDismiss: { _ in },
                onNewConversation: {}, loadPreview: { _ in nil }, previewRevision: { _ in nil },
                recapEligible: true, recap: recap, recapLoading: loading,
                recapFailure: failure, recapStale: stale,
                panel: .recap
            )
        }
        .environment(\.locale, Locale(identifier: "zh_Hans"))
        .environment(\.dynamicTypeSize, .large)
    }
}
