import XCTest
import SwiftUI
import UIKit
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatArtifactAnchorLayoutTests: XCTestCase {
    private final class FixtureModel: ObservableObject {
        let messages: [UIMessage]
        let artifacts: ConversationArtifactIndex
        @Published var messageAnchor: ChatMessageAnchor?
        @Published var shelfStripHeight: CGFloat = 0
        @Published private(set) var locatedSource: ConversationArtifactIndex.Source?

        init() {
            messages = Self.makeMessages()
            artifacts = ConversationArtifactIndex.make(from: messages)
        }

        func locate(_ source: ConversationArtifactIndex.Source) -> Bool {
            guard let anchor = ConversationArtifactIndex.anchor(
                for: source,
                conversationID: "phase3-native-anchor",
                messages: messages,
                requestToken: UUID()
            ) else { return false }
            locatedSource = source
            messageAnchor = anchor
            return true
        }

        private static func makeMessages() -> [UIMessage] {
            let content = "第一条工具消息是当前分支的文件产物。"
            var messages = [message(
                role: MessageRole.assistant,
                parts: [UIMessagePart.Tool(
                    toolCallId: "call_0",
                    toolName: "workspace_file_write",
                    input: #"{"path":"first.md","content":"\#(content)"}"#,
                    output: [UIMessagePart.Text(
                        text: #"{"ok":true,"path":"/workspace/first.md","size_bytes":\#(content.utf8.count)}"#,
                        metadata: nil
                    )],
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                )]
            )]

            let longText = Array(repeating:
                "这是后续的普通长文本，用来让首条工具消息确实受到顶部滚动边界限制，同时让 NativeChatTimelineView 有足够的内容完成锚点定位。",
                count: 14
            ).joined(separator: "\n\n")
            for turn in 0..<5 {
                messages.append(message(
                    role: MessageRole.user,
                    parts: [UIMessagePart.Text(text: "后续问题 \(turn + 1)：继续说明布局行为。", metadata: nil)]
                ))
                messages.append(message(
                    role: MessageRole.assistant,
                    parts: [UIMessagePart.Text(text: longText, metadata: nil)]
                ))
            }
            return messages
        }

        private static func message(role: MessageRole, parts: [UIMessagePart]) -> UIMessage {
            UIMessage(
                id: KotlinUuid.companion.random(),
                role: role,
                parts: parts,
                annotations: [],
                createdAt: chatNowLocalDateTime(),
                finishedAt: chatNowLocalDateTime(),
                modelId: nil,
                usage: nil,
                translation: nil
            )
        }
    }

    private struct FixtureView: View {
        @ObservedObject var model: FixtureModel
        let workspaceStore: IOSWorkspaceStore
        let displaySetting: DisplaySetting
        let generativeUiSetting: GenerativeUiSetting
        let startsWithShelfOpen: Bool
        let appliesMeasuredInset: Bool
        let showsProbeMarker: Bool
        let panelHeight: CGFloat

        var body: some View {
            ZStack {
                AmberThemePageBackground(surface: .app)
                NativeChatTimelineView(
                    signal: ChatMessageUpdateSignal(),
                    configurationIssue: nil,
                    isGenerationActive: false,
                    isLoading: false,
                    isRecognizingImages: false,
                    contextCompactState: .idle,
                    followGeneration: false,
                    displaySetting: displaySetting,
                    generativeUiSetting: generativeUiSetting,
                    reasoningLevelLabel: nil,
                    workspaceStore: workspaceStore,
                    scrollToBottomTrigger: 0,
                    scrollToBottomSource: .button,
                    messageAnchor: model.messageAnchor,
                    currentConversationID: "phase3-native-anchor",
                    messagesProvider: { model.messages },
                    variantInfoProvider: { _ in nil },
                    onAction: { _ in },
                    onViewportStateChange: { _ in },
                    onDismissKeyboard: {}
                )
                .safeAreaBar(edge: .top, spacing: 0) {
                    Color.clear
                        .frame(height: ChatTopBarLayout.controlsHeight + ChatTopBarLayout.softEdgeExtension +
                               (appliesMeasuredInset ? model.shelfStripHeight : 0))
                        .allowsHitTesting(false)
                }

                ChatTopBarView(
                    presentation: .idle(.conversationTitle("Phase 3 定位测试")),
                    conversationID: "phase3-native-anchor",
                    hasMessages: true,
                    isGenerating: false,
                    notices: [],
                    shelfHeight: panelHeight,
                    onBack: {},
                    onIslandTap: { _ in },
                    onCancel: {},
                    onOpenConversation: { _ in true },
                    onDismiss: { _ in },
                    onNewConversation: {},
                    loadPreview: { _ in nil },
                    previewRevision: { _ in nil },
                    artifacts: model.artifacts,
                    onLocateArtifact: { model.locate($0) },
                    onShelfStripHeightChange: { model.shelfStripHeight = $0 },
                    panel: startsWithShelfOpen ? .shelf : .shelfCollapsed
                )
            }
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            .overlay(alignment: .bottomLeading) {
                if showsProbeMarker {
                    Text("Phase 3 定位测试")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(AmberTheme.background, in: Capsule())
                        .accessibilityIdentifier("phase3-native-anchor-probe-title")
                        .accessibilityValue(appliesMeasuredInset ? "使用实测细条高度" : "未增加细条高度")
                        .padding(12)
                }
            }
        }
    }

    func testFirstWorkspaceArtifactUsesNativeAnchorWithMeasuredStripInset() async throws {
        let environment = ProcessInfo.processInfo.environment
        let probeMode = environment["AMBER_PHASE3_ANCHOR_PROBE"] == "1"
        let appliesMeasuredInset = environment["AMBER_PHASE3_ANCHOR_NO_INSET"] != "1"
        let model = FixtureModel()
        let source = try XCTUnwrap(model.artifacts.files.first?.versions.first?.source)
        XCTAssertEqual(model.artifacts.count, 1)
        XCTAssertEqual(model.artifacts.files.first?.path, "first.md")
        XCTAssertEqual(source.messageID, ChatMessageProjector.messageId(for: model.messages[0]))
        XCTAssertEqual(source.turn, 1, "产物前没有 user 消息时仍映射到第一轮")

        let settingsSuite = "ChatArtifactAnchorLayout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: settingsSuite)!
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        defer { defaults.removePersistentDomain(forName: settingsSuite) }
        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatArtifactAnchorLayout-\(UUID().uuidString)", isDirectory: true)
        let workspaceStore = IOSWorkspaceStore(
            baseDirectory: workspaceDirectory
        )
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: scene.coordinateSpace.bounds.size)
        window.rootViewController = UIHostingController(rootView: FixtureView(
            model: model,
            workspaceStore: workspaceStore,
            displaySetting: settings.displaySetting,
            generativeUiSetting: settings.agentRuntime.generativeUi,
            startsWithShelfOpen: probeMode,
            appliesMeasuredInset: appliesMeasuredInset,
            showsProbeMarker: probeMode,
            panelHeight: scene.coordinateSpace.bounds.height * 0.55
        ))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }

        if probeMode {
            let deadline = ContinuousClock.now + .seconds(90)
            while model.locatedSource != source && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(model.locatedSource, source, "请在测试窗口点击第 1 轮 ↗ 以完成真实定位")
        } else {
            try await waitUntil { model.shelfStripHeight > 0 }
            XCTAssertGreaterThan(model.shelfStripHeight, 0, "折叠细条应回传实际测量高度")
            XCTAssertTrue(model.locate(source))
        }

        try await Task.sleep(for: .seconds(1))
        window.layoutIfNeeded()
        let anchor = try XCTUnwrap(model.messageAnchor)
        XCTAssertEqual(anchor.conversationID, "phase3-native-anchor")
        XCTAssertEqual(anchor.messageID, source.messageID)
        XCTAssertEqual(anchor.toolCallID, source.toolCallID)
        XCTAssertEqual(
            NativeTimelineMessageAnchorPolicy.targetEntryID(
                request: anchor,
                consumed: nil,
                currentConversationID: "phase3-native-anchor",
                availableMessageIDs: Set(model.messages.map { ChatMessageProjector.messageId(for: $0) }),
                availableToolCallIDsByMessageID: [source.messageID: [source.toolCallID]]
            ),
            ChatToolCallAnchorTarget.id(messageID: source.messageID, toolCallID: source.toolCallID)
        )

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "phase3-native-anchor"
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: "/tmp/amber-topbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = image.pngData() {
            try? data.write(to: directory.appendingPathComponent("phase3-native-anchor.png"), options: [.atomic])
        }
        if probeMode {
            try await Task.sleep(for: .seconds(5))
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
