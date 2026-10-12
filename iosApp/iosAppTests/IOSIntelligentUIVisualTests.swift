import SwiftUI
import XCTest
import Vision
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSIntelligentUIVisualTests: XCTestCase {
    func testDecisionCardFitsCompactAndAccessibilityWidths() async throws {
        let definition = try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.exampleJSON)
        for (name, width, textSize, dark) in [
            ("compact-light", CGFloat(320), DynamicTypeSize.large, false),
            ("compact-dark", CGFloat(320), DynamicTypeSize.large, true),
            ("accessibility", CGFloat(320), DynamicTypeSize.accessibility3, false)
        ] {
            let card = IOSIntelligentUICard(
                definition: definition,
                selectedOptionID: .constant("native"),
                values: .constant(["constraints": "保留已有可视化路径，先完成选择、保存和继续的闭环。"]),
                isSubmitEnabled: true,
                status: "选择仅保存在本地；提交后将用于下一轮。"
            )
            .padding(12)
            .frame(width: width)
            .background(AmberTheme.background)
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.colorScheme, dark ? .dark : .light)
            .ignoresSafeArea()
            let host = UIHostingController(rootView: card)
            let fit = host.sizeThatFits(in: CGSize(width: width, height: 5_000))
            XCTAssertLessThanOrEqual(fit.width, width + 1)
            XCTAssertGreaterThan(fit.height, 300)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: CGSize(width: width, height: fit.height))
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            let attachment = XCTAttachment(image: image)
            attachment.name = "task-ui-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("task-ui-\(name).png")
            try XCTUnwrap(image.pngData()).write(to: file)
            print("TASK_UI_VISUAL_EVIDENCE \(file.path)")
        }
    }

    func testTaskCardUsesDefaultNativeTimeline() async throws {
        let text = "先比较两条实现路径。\n```task-ui\n\(IOSIntelligentUIProtocol.exampleJSON)\n```\n选择后再继续。"
        let seed = UIMessage.companion.assistant(prompt: text)
        let message = try XCTUnwrap(IOSIntelligentUITerminal.markCompleted([seed], baseline: [], runID: "visual-run").first)
        let definition = try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.exampleJSON)
        let source = IOSIntelligentUISource(conversationID: "visual-conversation", messageID: message.id.toHexDashString(),
                                            textPartIndex: 0, cardID: definition.cardID)
        let drafts = IOSIntelligentUIStateStore()
        drafts.register(source: source, definition: definition)
        try drafts.update(source: source, definition: definition, selectedOptionID: "native", values: ["constraints": "保留现有 SVG / Three.js 展示能力。"])
        let taskHost = IOSIntelligentUIHost(stateStore: drafts, action: { _ in .saved })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaskUIVisual-\(UUID().uuidString)")
        let workspace = IOSWorkspaceStore(baseDirectory: directory)
        let settings = IOSSharedSettingsStore(userDefaults: UserDefaults(suiteName: "TaskUIVisual-\(UUID().uuidString)")!)
        let timeline = NativeChatTimelineView(
            signal: ChatMessageUpdateSignal(revision: 0, reason: .initialLoad),
            configurationIssue: nil, isGenerationActive: false, isLoading: false,
            isRecognizingImages: false, contextCompactState: .idle, followGeneration: true,
            displaySetting: settings.snapshot.displaySetting,
            generativeUiSetting: settings.snapshot.agentRuntime.generativeUi,
            reasoningLevelLabel: nil, workspaceStore: workspace,
            scrollToBottomTrigger: 0, scrollToBottomSource: .button,
            messageAnchor: nil, currentConversationID: "visual-conversation",
            messagesProvider: { [message] }, variantInfoProvider: { _ in nil },
            onAction: { _ in }, onViewportStateChange: { _ in }, onDismissKeyboard: {}
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: timeline
            .environment(\.intelligentUIHost, taskHost)
            .environment(\.intelligentUIConversationID, source.conversationID))
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(350))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "task-ui-native-timeline"
        attachment.lifetime = .keepAlways
        add(attachment)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("task-ui-native-timeline.png")
        try XCTUnwrap(image.pngData()).write(to: file)
        print("TASK_UI_VISUAL_EVIDENCE \(file.path)")
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let visibleText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        XCTAssertTrue(visibleText.contains("原生任务卡"), "默认 timeline 必须实际展示原生任务卡选项")
        XCTAssertTrue(visibleText.contains("补充约束"), "默认 timeline 必须展示卡片输入区")
    }
}
