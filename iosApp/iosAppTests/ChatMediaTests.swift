import XCTest
import SwiftUI
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatMediaTests: XCTestCase {
    func testSearchGallerySurvivesToolOutputSerialization() throws {
        let gallery = #"[{"id":"source-1","url":"https://example.com/a.jpg","title":"图片来源","sourceURL":"https://example.com/article"}]"#
        let part = IosToolOutputJsonBridge.shared.mergeTextMetadata(
            part: UIMessagePart.Text(text: "搜索摘要", metadata: nil),
            updates: ["app.amber.media.images": gallery]
        )
        let persisted = IosToolOutputJsonBridge.shared.encode(parts: [part])
        let restored = try IosToolOutputJsonBridge.shared.decode(json: persisted)
        XCTAssertEqual(ChatMediaItem.toolImages(restored), [
            ChatMediaItem(id: "source-1", url: "https://example.com/a.jpg", title: "图片来源", sourceURL: "https://example.com/article")
        ])
    }

    func testThumbnailDecodesWithinPixelBudgetAndRetainsAspect() async throws {
        let data = Self.imageData(size: CGSize(width: 3200, height: 2400))
        let started = ContinuousClock.now
        let image = try await ChatMediaImageLoader.shared.image(urlString: Self.dataURL(data), pixelLimit: 600)
        XCTAssertEqual(image.size.width, 600)
        XCTAssertEqual(image.size.height, 450)
        let originalBytes = 3200 * 2400 * 4
        let thumbnailBytes = try XCTUnwrap(image.cgImage).bytesPerRow * 450
        XCTAssertLessThan(thumbnailBytes, originalBytes / 10)
        print("MEDIA_DECODE originalBytes=\(originalBytes) thumbnailBytes=\(thumbnailBytes) elapsed=\(started.duration(to: .now))")
    }

    func testBadImageProducesLoadFailure() async {
        do {
            _ = try await ChatMediaImageLoader.shared.image(urlString: "data:image/png;base64,YmFk", pixelLimit: 600)
            XCTFail("Invalid image must fail visibly, not render an empty success")
        } catch { }
    }

    func testGalleryKeepsHeightAfterLoadAndFailureAndFitsNarrowWidth() async throws {
        let dataURL = Self.dataURL(Self.imageData(size: CGSize(width: 120, height: 400)))
        for (name, url) in [("success", dataURL), ("failure", "data:image/png;base64,YmFk")] {
            let item = ChatMediaItem(id: name, url: url, title: "图片说明与来源标题", sourceURL: "https://example.com/source")
            let host = UIHostingController(rootView: ChatMediaGallery(items: [item]).padding(16))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 740))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            let proposal = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
            let before = host.sizeThatFits(in: proposal)
            try await Task.sleep(for: .milliseconds(250))
            host.view.layoutIfNeeded()
            let after = host.sizeThatFits(in: proposal)
            XCTAssertEqual(before.height, after.height, accuracy: 1, name)
            XCTAssertLessThanOrEqual(after.width, 320, name)
            XCTAssertGreaterThan(after.height, 200, name)
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
                window.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "media-\(name)-320pt"
            attachment.lifetime = .keepAlways
            add(attachment)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("amber-media-\(name).png")
            try screenshot.pngData()?.write(to: path)
            print("MEDIA_SCREENSHOT=\(path.path)")
        }
    }

    func testAspectRatioHandlesUnknownAndExtremeDimensions() {
        XCTAssertEqual(ChatMediaItem(id: "a", url: "a").aspectRatio, 4 / 3)
        XCTAssertEqual(ChatMediaItem(id: "a", url: "a", width: 1, height: 1000).aspectRatio, 0.5)
        XCTAssertEqual(ChatMediaItem(id: "a", url: "a", width: .infinity, height: 1).aspectRatio, 4 / 3)
    }

    func testHistoricalSearchToolHasMediaHeightOnFirstLayout() async throws {
        let raw = #"[{"id":"image","url":"data:image/png;base64,YmFk","title":"搜索配图","sourceURL":"https://example.com/source"}]"#
        let output = IosToolOutputJsonBridge.shared.mergeTextMetadata(
            part: UIMessagePart.Text(text: "搜索结果", metadata: nil), updates: ["app.amber.media.images": raw])
        let tool = UIMessagePart.Tool(toolCallId: "history-search", toolName: "search_web", input: "{}", output: [output],
                                      approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
        let host = UIHostingController(rootView: ChatToolMediaGallery(tool: tool).padding(16))
        let proposal = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        let first = host.sizeThatFits(in: proposal)
        XCTAssertGreaterThan(first.height, 200, "历史搜索图集必须在首帧预留高度")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 740))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(host.sizeThatFits(in: proposal).height, first.height, accuracy: 1)
    }

    func testGalleryAndUserImageLayoutMatrix() async throws {
        let url = Self.dataURL(Self.imageData(size: CGSize(width: 240, height: 160)))
        let items = (0..<3).map {
            ChatMediaItem(id: "\($0)", url: url, title: "第\($0 + 1)张图片及较长的来源标题说明", sourceURL: "https://example.com/source")
        }
        let user = UIMessage(id: KotlinUuid.companion.random(), role: .user,
                             parts: [UIMessagePart.Image(url: url, metadata: nil)], annotations: [],
                             createdAt: chatNowLocalDateTime(), finishedAt: chatNowLocalDateTime(),
                             modelId: nil, usage: nil, translation: nil)
        let workspace = IOSWorkspaceStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for (name, view) in [
            ("gallery", AnyView(ChatMediaGallery(items: items))),
            ("large-type", AnyView(ChatMediaGallery(items: items).dynamicTypeSize(.accessibility3))),
            ("user", AnyView(MessageBubbleView(message: user).environment(workspace)))
        ] {
            let host = UIHostingController(rootView: view.padding(16))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 740))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            let size = host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(size.width, 320, name)
            XCTAssertLessThan(size.height, 740, name)
            try await Task.sleep(for: .milliseconds(250))
            host.view.layoutIfNeeded()
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "media-\(name)-320pt"
            attachment.lifetime = .keepAlways
            add(attachment)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("amber-media-\(name).png")
            try screenshot.pngData()?.write(to: path)
            print("MEDIA_SCREENSHOT=\(path.path)")
        }
    }

    func testNativeTimelineMediaKeepsContentHeightAfterAsyncLoading() async throws {
        let imageURL = Self.dataURL(Self.imageData(size: CGSize(width: 120, height: 400)))
        let settings = IosSettingsDefaults.shared.defaultSeededSettings()
        let workspace = IOSWorkspaceStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        func message(_ role: MessageRole, _ parts: [UIMessagePart]) -> UIMessage {
            UIMessage(id: KotlinUuid.companion.random(), role: role, parts: parts, annotations: [],
                      createdAt: chatNowLocalDateTime(), finishedAt: chatNowLocalDateTime(), modelId: nil, usage: nil, translation: nil)
        }
        let messages = [
            message(.assistant, [UIMessagePart.Text(text: "图片、视频和文字应保持稳定的纵向排版。", metadata: nil)]),
            message(.user, [UIMessagePart.Image(url: imageURL, metadata: nil)]),
            message(.assistant, [UIMessagePart.Image(url: "data:image/png;base64,YmFk", metadata: nil)]),
            message(.assistant, [UIMessagePart.Video(url: "https://example.com/video.mp4", metadata: nil)])
        ]
        let timeline = NativeChatTimelineView(
            signal: ChatMessageUpdateSignal(revision: 0, reason: .initialLoad), configurationIssue: nil,
            isGenerationActive: false, isLoading: false, isRecognizingImages: false, contextCompactState: .idle,
            followGeneration: false, displaySetting: settings.displaySetting,
            generativeUiSetting: settings.agentRuntime.generativeUi, reasoningLevelLabel: nil,
            workspaceStore: workspace, scrollToBottomTrigger: 0, scrollToBottomSource: .button,
            messageAnchor: nil, currentConversationID: "media-layout-test", messagesProvider: { messages },
            variantInfoProvider: { _ in nil }, onAction: { _ in }, onViewportStateChange: { _ in }, onDismissKeyboard: {}
        )
        let host = UIHostingController(rootView: timeline.environment(workspace))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host.view))
        let before = scroll.contentSize
        XCTAssertGreaterThan(before.height, 400)
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        XCTAssertEqual(scroll.contentSize.height, before.height, accuracy: 1)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, 393)
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("amber-media-native-timeline.png")
        try screenshot.pngData()?.write(to: path)
        print("MEDIA_SCREENSHOT=\(path.path)")
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "native-timeline-media"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func imageData(size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private static func dataURL(_ data: Data) -> String { "data:image/png;base64," + data.base64EncodedString() }
}
