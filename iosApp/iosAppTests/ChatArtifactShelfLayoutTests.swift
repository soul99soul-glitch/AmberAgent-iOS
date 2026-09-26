import XCTest
import SwiftUI
import UIKit
import Observation
@testable import iosApp

@MainActor
final class ChatArtifactShelfLayoutTests: XCTestCase {
    func testArtifactShelfLayoutsAndCapturePhase3Evidence() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        func show<Content: View>(_ content: Content, width: CGFloat? = nil, height: CGFloat? = nil) {
            window.rootViewController?.dismiss(animated: false)
            let screenSize = scene.screen.bounds.size
            window.frame = CGRect(
                x: 0,
                y: 0,
                width: width ?? screenSize.width,
                height: height ?? screenSize.height
            )
            window.rootViewController = UIHostingController(rootView: content)
            window.makeKeyAndVisible()
        }

        func capture(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(650))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)

            let directory = URL(fileURLWithPath: "/tmp/amber-topbar", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = image.pngData() {
                try? data.write(to: directory.appendingPathComponent("\(name).png"), options: [.atomic])
                let dockName = [
                    "phase3-panel-artifacts-iphone17pro": "dockpanel-shelf",
                    "phase3-panel-empty-iphone17pro": "dockpanel-empty"
                ][name]
                if let dockName {
                    try? data.write(to: directory.appendingPathComponent("\(dockName).png"), options: [.atomic])
                }
            }
            print("CHAT_ARTIFACT_SHELF_EVIDENCE \(directory.appendingPathComponent("\(name).png").path)")
        }

        let artifacts = fixtureArtifacts()
        XCTAssertEqual(artifacts.count, 3)
        let deviceSize = scene.screen.bounds.size
        await assertPanelSizes(artifacts, window: window, width: min(340, deviceSize.width - 6), screenHeight: deviceSize.height)
        await assertPanelSizes(artifacts, window: window, width: 333, screenHeight: 812)

        show(ChatArtifactShelfLayoutPreview(artifacts: artifacts, panel: .shelf))
        await capture("phase3-panel-artifacts-iphone17pro")

        show(ChatArtifactShelfLayoutPreview(artifacts: artifacts, panel: .shelf), width: 375, height: 812)
        await capture("phase3-panel-artifacts-375")

        window.overrideUserInterfaceStyle = .dark
        show(ChatArtifactShelfLayoutPreview(artifacts: artifacts, panel: .shelf)
            .environment(\.colorScheme, .dark))
        await capture("phase3-panel-artifacts-dark")
        window.overrideUserInterfaceStyle = .light

        show(ChatArtifactShelfLayoutPreview(
            artifacts: ConversationArtifactIndex(images: [], files: [], webPages: []), panel: .shelf
        ))
        await capture("phase3-panel-empty-iphone17pro")

        show(ChatArtifactShelfLayoutPreview(
            artifacts: ConversationArtifactIndex(images: [], files: [], webPages: []), panel: .shelf
        ), width: 375, height: 812)
        await capture("phase3-panel-empty-375")

        show(ChatArtifactShelfLayoutPreview(artifacts: artifacts, panel: .shelfCollapsed))
        await capture("phase3-panel-located-strip")

        // 默认选择最新版本。交互探针会把真实面板留在前台，供模拟器横划切到旧版、
        // 点定位并检查收起后的细条；普通回归不等待外部操作。
        guard ProcessInfo.processInfo.environment["AMBER_PHASE3_INTERACTION_PROBE"] == "1" else { return }

        let fixture = ChatArtifactShelfLayoutFixture()
        show(ChatArtifactShelfLayoutPreview(
            artifacts: artifacts,
            panel: .shelf,
            fixture: fixture
        ))
        await capture("phase3-interaction-ready")
        print("CHAT_PHASE3_PROBE_READY")

        let deadline = Date().addingTimeInterval(90)
        var capturedLocatedStrip = false
        while Date() < deadline {
            if fixture.locatedSource != nil, !capturedLocatedStrip {
                capturedLocatedStrip = true
                await capture("phase3-panel-located-strip-after-interaction")
                print("CHAT_PHASE3_LOCATE_RECEIVED")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(fixture.locatedSource, "模拟器探针需点一次产物定位按钮")
    }

    func testPhase4SnippetsSelectionAndAdoptedVersionLayouts() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        let artifacts = fixtureArtifacts()
        let snippets = fixtureSnippets()
        let adopted = ["reports/phase3-plan.md": "phase3-version-1"]
        let fileAndSnippets = ConversationArtifactIndex(images: [], files: artifacts.files, webPages: [])
        let allIDs = Set(
            artifacts.images.map(ChatArtifactActions.selectionID(for:))
                + artifacts.files.map(ChatArtifactActions.selectionID(for:))
                + snippets.map(ChatArtifactActions.selectionID(for:))
        )

        // 375pt：多选底栏三项等分，面板仍不超过 55% 上限。
        for (width, screenHeight) in [(CGFloat(333), CGFloat(812)), (min(340, scene.screen.bounds.width - 6), scene.screen.bounds.height)] {
            let maxHeight = screenHeight * 0.55
            var measured = CGSize.zero
            let panel = ChatArtifactShelfPanel(
                artifacts: artifacts, maxHeight: maxHeight, onLocate: { _ in }, onClose: {},
                snippets: snippets, adoptedVersions: adopted, conversationTitle: "海边旅行",
                isSelecting: true, selectedArtifactIDs: allIDs
            )
            .frame(width: width)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 }
            window.frame = CGRect(x: 0, y: 0, width: width + 42, height: screenHeight)
            window.rootViewController = UIHostingController(rootView: panel)
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            window.layoutIfNeeded()
            XCTAssertLessThanOrEqual(measured.width, width + 1)
            XCTAssertLessThanOrEqual(measured.height, maxHeight + 1)
            XCTAssertGreaterThan(measured.height, maxHeight * 0.5)
        }

        show(ChatArtifactShelfLayoutPreview(
            artifacts: fileAndSnippets, panel: .shelf, snippets: snippets, adoptedVersions: adopted
        ), in: window, scene: scene)
        await capture("phase4-panel-snippets-iphone17pro", window: window)

        show(ChatArtifactShelfLayoutPreview(
            artifacts: fileAndSnippets, panel: .shelf, snippets: snippets, adoptedVersions: adopted
        ), in: window, scene: scene, width: 375, height: 812)
        await capture("phase4-panel-snippets-375", window: window)

        show(ChatArtifactShelfLayoutPreview(
            artifacts: fileAndSnippets, panel: .shelf, snippets: snippets, adoptedVersions: [:]
        ), in: window, scene: scene)
        await capture("phase4-version-unadopted", window: window)

        show(ChatArtifactShelfLayoutPreview(
            artifacts: artifacts, panel: nil, snippets: snippets, adoptedVersions: adopted,
            selectedIDs: Set([ChatArtifactActions.selectionID(for: artifacts.images[0])]
                + snippets.map(ChatArtifactActions.selectionID(for:)))
        ), in: window, scene: scene)
        await capture("phase4-multiselect-iphone17pro", window: window)

        show(ChatArtifactShelfLayoutPreview(
            artifacts: artifacts, panel: nil, snippets: snippets, adoptedVersions: adopted,
            selectedIDs: allIDs
        ), in: window, scene: scene, width: 375, height: 812)
        await capture("phase4-multiselect-375", window: window)

        window.overrideUserInterfaceStyle = .dark
        show(ChatArtifactShelfLayoutPreview(
            artifacts: fileAndSnippets, panel: .shelf, snippets: snippets, adoptedVersions: adopted
        ).environment(\.colorScheme, .dark), in: window, scene: scene)
        await capture("phase4-panel-snippets-dark", window: window)
    }

    private func show<Content: View>(
        _ content: Content, in window: UIWindow, scene: UIWindowScene,
        width: CGFloat? = nil, height: CGFloat? = nil
    ) {
        window.rootViewController?.dismiss(animated: false)
        let screenSize = scene.screen.bounds.size
        window.frame = CGRect(x: 0, y: 0, width: width ?? screenSize.width, height: height ?? screenSize.height)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
    }

    private func capture(_ name: String, window: UIWindow) async {
        try? await Task.sleep(for: .milliseconds(900))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: "/tmp/amber-topbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: directory.appendingPathComponent("\(name).png"), options: [.atomic])
    }

    private func fixtureSnippets() -> [IOSPinnedSnippet] {
        [
            IOSPinnedSnippet(
                id: "phase4-message", messageID: "phase4-message", turn: 2,
                text: "先沿河边散步，再去老街喝咖啡。\n傍晚去码头看日落，晚饭选海鲜排档。\n行程留白，慢慢发现城市。\n第四行\n第五行不显示",
                kind: .message
            ),
            IOSPinnedSnippet(
                id: "phase4-message:code:hash", messageID: "phase4-message", turn: 3,
                text: "let palette = [\"#1F4E79\", \"#73C5B8\"]\nprint(palette)",
                kind: .code, codeLanguage: "swift"
            )
        ]
    }

    private func assertPanelSizes(
        _ artifacts: ConversationArtifactIndex,
        window: UIWindow,
        width: CGFloat,
        screenHeight: CGFloat
    ) async {
        let maxHeight = screenHeight * 0.55
        func measuredHeight(for artifacts: ConversationArtifactIndex) async -> CGSize {
            var measured = CGSize.zero
            let panel = ChatArtifactShelfPanel(
                artifacts: artifacts,
                maxHeight: maxHeight,
                onLocate: { _ in },
                onClose: {}
            )
            .frame(width: width)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 }
            let host = UIHostingController(rootView: panel)
            window.rootViewController = host
            window.makeKeyAndVisible()
            try? await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            return measured
        }

        let empty = await measuredHeight(for: ConversationArtifactIndex(images: [], files: [], webPages: []))
        let populated = await measuredHeight(for: artifacts)
        let singlePage = await measuredHeight(for: ConversationArtifactIndex(
            images: [], files: [], webPages: Array(artifacts.webPages.prefix(1))
        ))
        XCTAssertLessThan(singlePage.height, maxHeight * 0.75, "少量产物也应贴合内容，而不是占满上限")
        XCTAssertGreaterThan(empty.height, 0)
        XCTAssertGreaterThan(singlePage.height, 0)
        XCTAssertLessThanOrEqual(empty.width, width + 1)
        XCTAssertLessThanOrEqual(populated.width, width + 1)
        XCTAssertLessThan(empty.height, maxHeight * 0.55, "空态应使用内容高度，不应占满面板高度")
        XCTAssertGreaterThan(populated.height, empty.height + 40)
        XCTAssertLessThanOrEqual(populated.height, maxHeight + 1)
    }

    private func fixtureArtifacts() -> ConversationArtifactIndex {
        let firstSource = ConversationArtifactIndex.Source(
            messageID: "phase3-file-message-v1", turn: 2, toolCallID: "phase3-file-v1"
        )
        let latestSource = ConversationArtifactIndex.Source(
            messageID: "phase3-file-message-v2", turn: 4, toolCallID: "phase3-file-v2"
        )
        let imageSource = ConversationArtifactIndex.Source(
            messageID: "phase3-image-message", turn: 3, toolCallID: "phase3-image"
        )
        let webSource = ConversationArtifactIndex.Source(
            messageID: "phase3-web-message", turn: 4, toolCallID: "phase3-web"
        )
        let imageURL = fixtureImageDataURL()
        return ConversationArtifactIndex(
            images: [
                .init(
                    id: "phase3-image",
                    url: imageURL,
                    prompt: "海边配色方案",
                    source: imageSource
                )
            ],
            files: [
                .init(
                    path: "reports/phase3-plan.md",
                    versions: [
                        .init(
                            id: "phase3-version-1",
                            source: firstSource,
                            content: "# 第一版\n保留初始计划和原始数据。"
                        ),
                        .init(
                            id: "phase3-version-2",
                            source: latestSource,
                            content: "# 更新后的计划\n加入产物索引、版本切换和定位说明。"
                        )
                    ]
                )
            ],
            webPages: [
                .init(
                    id: "phase3-web",
                    title: "SwiftUI 工具布局参考",
                    url: "https://example.com/swiftui-layout",
                    preview: "面板使用顶部锚定布局并保持内容可读。",
                    source: webSource
                )
            ]
        )
    }

    private func fixtureImageDataURL() -> String {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160))
        let image = renderer.image { context in
            UIColor(red: 0.13, green: 0.26, blue: 0.42, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
            UIColor(red: 0.45, green: 0.77, blue: 0.72, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 116, y: 12, width: 142, height: 142)).fill()
            UIColor(red: 0.96, green: 0.74, blue: 0.40, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 18, y: 88, width: 132, height: 54), cornerRadius: 20).fill()
        }
        return "data:image/png;base64,\(image.pngData()?.base64EncodedString() ?? "")"
    }
}

@MainActor
@Observable
private final class ChatArtifactShelfLayoutFixture {
    var locatedSource: ConversationArtifactIndex.Source?
    var notices: [ConversationActivityNotice] = []

    func deliverNotice() async {
        try? await Task.sleep(for: .seconds(3))
        notices = [.init(conversationId: "other-conversation", title: "另一份报告",
                         kind: .completed, preview: "已经整理完成。", occurredAt: .now)]
    }
}

@MainActor
private struct ChatArtifactShelfLayoutPreview: View {
    let artifacts: ConversationArtifactIndex
    let panel: ChatTopBarPanel?
    var fixture: ChatArtifactShelfLayoutFixture? = nil
    var snippets: [IOSPinnedSnippet] = []
    var adoptedVersions: [String: String] = [:]
    /// 非 nil 时按 ChatTopBarView 的面板位置直接渲染多选态面板。
    var selectedIDs: Set<String>? = nil
    @State private var dismissRevision = 0
    @State private var stripHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("正文内容会从面板后方延伸，用于检查玻璃面板顶部是否遮住文字。")
                            .font(.title3.weight(.semibold))
                            .accessibilityIdentifier(fixture == nil ? "" : "phase3-interaction-probe")
                        ForEach(0..<12, id: \.self) { index in
                            Text("第 \(index + 1) 段正文：这里保留足够长的对话内容，方便观察面板是否透出背景文字。")
                                .font(.body)
                                .foregroundStyle(AmberTheme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .background(AmberTheme.background.ignoresSafeArea())
                .simultaneousGesture(TapGesture().onEnded { dismissRevision &+= 1 })
                .safeAreaBar(edge: .top, spacing: 0) {
                    Color.clear
                        .frame(height: ChatTopBarLayout.controlsHeight + ChatTopBarLayout.softEdgeExtension + stripHeight)
                        .allowsHitTesting(false)
                }
                ChatTopBarView(
                    presentation: .idle(.conversationTitle("产物架截图对话")),
                    conversationID: "phase3-artifact-layout",
                    hasMessages: true,
                    isGenerating: false,
                    notices: fixture?.notices ?? [],
                    shelfHeight: geometry.size.height * 0.55,
                    onBack: { if let fixture { Task { await fixture.deliverNotice() } } },
                    onIslandTap: { _ in },
                    onCancel: {},
                    onOpenConversation: { _ in true },
                    onDismiss: { _ in },
                    onNewConversation: {},
                    loadPreview: { _ in nil },
                    previewRevision: { _ in nil },
                    artifacts: artifacts,
                    snippets: snippets,
                    adoptedVersions: adoptedVersions,
                    conversationTitle: "海边旅行",
                    onLocateArtifact: { source in
                        fixture?.locatedSource = source
                        return true
                    },
                    dismissShelfRevision: dismissRevision,
                    onShelfStripHeightChange: { stripHeight = $0 },
                    panel: panel
                )
                if let selectedIDs {
                    ChatArtifactShelfPanel(
                        artifacts: artifacts, maxHeight: geometry.size.height * 0.55,
                        onLocate: { _ in }, onClose: {},
                        snippets: snippets, adoptedVersions: adoptedVersions, conversationTitle: "海边旅行",
                        isSelecting: true, selectedArtifactIDs: selectedIDs
                    )
                    .frame(width: min(340, geometry.size.width - 36 - (44 - ChatTopBarLayout.toolbarButtonDiameter)))
                    .frame(height: geometry.size.height * 0.55, alignment: .top)
                    .padding(.trailing, 18 + (44 - ChatTopBarLayout.toolbarButtonDiameter) / 2)
                    .padding(.top, ChatTopBarLayout.controlsHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .environment(\.locale, Locale(identifier: "zh_Hans"))
        .environment(\.dynamicTypeSize, .large)
    }
}
