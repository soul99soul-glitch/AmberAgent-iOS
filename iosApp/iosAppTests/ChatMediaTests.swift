import ImageIO
import os
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatMediaTests: XCTestCase {
    func testDiskThumbnailSurvivesCacheRecreationAndRejectsCorruptEntry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ChatMediaThumbnailDiskCache(directory: directory)
        let image = try ChatMediaImageLoader.decode(data: Self.imageData(size: CGSize(width: 80, height: 60)), pixelLimit: 80)
        await first.store(image, key: "remote-image:80")
        let restored = await ChatMediaThumbnailDiskCache(directory: directory).image(key: "remote-image:80", pixelLimit: 80)
        XCTAssertEqual(restored?.size, image.size)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("broken-thumbnail".utf8).write(to: file)
        let corrupt = await first.image(key: "remote-image:80", pixelLimit: 80)
        XCTAssertNil(corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDiskThumbnailCacheEvictsOldEntriesWithinBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try ChatMediaImageLoader.decode(data: Self.imageData(size: CGSize(width: 80, height: 60)), pixelLimit: 80)
        let size = try XCTUnwrap(image.pngData()).count
        let cache = ChatMediaThumbnailDiskCache(directory: directory, byteLimit: size + size / 2)
        await cache.store(image, key: "old")
        let oldFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: oldFile.path)
        await cache.store(image, key: "new")
        let old = await cache.image(key: "old", pixelLimit: 80)
        let new = await cache.image(key: "new", pixelLimit: 80)
        XCTAssertNil(old)
        XCTAssertNotNil(new)
        let bytes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, size + size / 2)
    }

    func testConcurrentThumbnailRequestsShareWorkAndAllowOneConsumerToCancel() async throws {
        actor Loads {
            var count = 0
            func run(_ image: UIImage) async throws -> UIImage {
                count += 1
                try await Task.sleep(for: .milliseconds(150))
                return image
            }
        }
        let loads = Loads()
        let requests = ChatMediaImageRequests()
        let image = try ChatMediaImageLoader.decode(data: Self.imageData(size: CGSize(width: 80, height: 60)), pixelLimit: 80)
        let first = Task { try await requests.image(key: "same") { try await loads.run(image) } }
        // Keep both consumers alive across the network suspension point.
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { try await requests.image(key: "same") { try await loads.run(image) } }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        let loaded = try await second.value
        XCTAssertTrue(loaded === image)
        do {
            _ = try await first.value
            XCTFail("Cancelled consumers must not publish an image")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let count = await loads.count
        XCTAssertEqual(count, 1)
    }

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
            let window = try await Self.makeWindow(size: CGSize(width: 320, height: 740))
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
        // Compare the media's content proposal before and after attachment; the
        // simulator's status-bar inset is a separate window-layout input.
        host.safeAreaRegions = []
        let proposal = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        let first = host.sizeThatFits(in: proposal)
        XCTAssertGreaterThan(first.height, 200, "历史搜索图集必须在首帧预留高度")
        let window = try await Self.makeWindow(size: CGSize(width: 320, height: 740))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(250))
        let after = host.sizeThatFits(in: proposal)
        XCTAssertEqual(after.height, first.height, accuracy: 1)
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
            let window = try await Self.makeWindow(size: CGSize(width: 320, height: 740))
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
        let window = try await Self.makeWindow(size: CGSize(width: 393, height: 852))
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while Self.tealSampleCount(in: window) < 5 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
        }
        XCTAssertGreaterThanOrEqual(Self.tealSampleCount(in: window), 5,
                                    "可见的本地图片必须实际显示，不能只验证占位框高度稳定")
        XCTAssertEqual(scroll.contentSize.height, before.height, accuracy: 1)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, 393)
        let screenshot = Self.renderWindow(window)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("amber-media-native-timeline.png")
        try screenshot.pngData()?.write(to: path)
        print("MEDIA_SCREENSHOT=\(path.path)")
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "native-timeline-media"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testGalleryPreloadsBeforeEnteringViewportAndKeepsPartiallyVisibleImage() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("viewport-\(UUID()).png")
        try Self.imageData(size: CGSize(width: 160, height: 120)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let gallery = ChatMediaGallery(items: [ChatMediaItem(id: "prefetch", url: file.absoluteString)])
        let host = UIHostingController(rootView: ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 700)
                gallery
                Color.clear.frame(height: 1200)
            }
        })
        host.safeAreaRegions = []
        let window = try await Self.makeWindow(size: CGSize(width: 320, height: 500))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host.view))
        // The image starts 200pt below the viewport. Removing the source after
        // this window makes a successful reveal observable proof of prefetch.
        try await Task.sleep(for: .milliseconds(500))
        try FileManager.default.removeItem(at: file)
        scroll.setContentOffset(CGPoint(x: 0, y: 650), animated: false)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(Self.tealSampleCount(in: window), 40, "图片进入屏幕前应已加载")
        for offset: CGFloat in [750, 850, 900, 850, 750, 650] {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertGreaterThan(Self.tealSampleCount(in: window), 5,
                                 "图片仍有可见部分时不能清空，offset=\(offset)")
        }
        let attachment = XCTAttachment(image: Self.renderWindow(window))
        attachment.name = "gallery-viewport-prefetched-and-retained"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMediaViewportPreloadsBothScrollAxesAndIgnoresTransientEmptyGeometry() {
        let size = CGSize(width: 220, height: 165)
        let vertical = CGRect(x: 0, y: -700, width: 320, height: 500)
        XCTAssertEqual(ChatMediaViewport.position(size: size, vertical: vertical, horizontal: nil), .loading)
        XCTAssertEqual(ChatMediaViewport.position(size: size, vertical: CGRect(x: 0, y: -1100, width: 320, height: 500), horizontal: nil), .retained)
        XCTAssertEqual(ChatMediaViewport.position(size: size, vertical: CGRect(x: 0, y: -1600, width: 320, height: 500), horizontal: nil), .distant)
        XCTAssertEqual(ChatMediaViewport.position(size: size, vertical: vertical,
                                                 horizontal: CGRect(x: -500, y: 0, width: 320, height: 165)), .loading)
        XCTAssertEqual(ChatMediaViewport.position(size: size, vertical: vertical,
                                                 horizontal: CGRect(x: -1100, y: 0, width: 320, height: 165)), .distant)
        XCTAssertNil(ChatMediaViewport.position(size: .zero, vertical: vertical, horizontal: nil))
        XCTAssertNil(ChatMediaViewport.position(size: size, vertical: .zero, horizontal: nil))
    }

    func testNativeTimelineKeepsImageWhileScrollingThroughPartialVisibility() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("native-viewport-\(UUID()).png")
        try Self.imageData(size: CGSize(width: 160, height: 120)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        func message(_ parts: [UIMessagePart]) -> UIMessage {
            UIMessage(id: KotlinUuid.companion.random(), role: .assistant, parts: parts, annotations: [],
                      createdAt: chatNowLocalDateTime(), finishedAt: chatNowLocalDateTime(),
                      modelId: nil, usage: nil, translation: nil)
        }
        let messages = [
            message([UIMessagePart.Image(url: file.absoluteString, metadata: nil)]),
            message([UIMessagePart.Text(text: Array(repeating: "后续历史消息保持滚动空间。", count: 100).joined(separator: "\n"), metadata: nil)])
        ]
        let settings = IosSettingsDefaults.shared.defaultSeededSettings()
        let workspace = IOSWorkspaceStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let timeline = NativeChatTimelineView(
            signal: ChatMessageUpdateSignal(revision: 0, reason: .initialLoad), configurationIssue: nil,
            isGenerationActive: false, isLoading: false, isRecognizingImages: false, contextCompactState: .idle,
            followGeneration: false, displaySetting: settings.displaySetting,
            generativeUiSetting: settings.agentRuntime.generativeUi, reasoningLevelLabel: nil,
            workspaceStore: workspace, scrollToBottomTrigger: 0, scrollToBottomSource: .button,
            messageAnchor: ChatMessageAnchor(conversationID: "media-viewport-test",
                                             messageID: ChatMessageProjector.messageId(for: messages[0])),
            currentConversationID: "media-viewport-test", messagesProvider: { messages },
            variantInfoProvider: { _ in nil }, onAction: { _ in }, onViewportStateChange: { _ in }, onDismissKeyboard: {}
        )
        let host = UIHostingController(rootView: timeline.environment(workspace))
        host.safeAreaRegions = []
        let window = try await Self.makeWindow(size: CGSize(width: 320, height: 500))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host.view))
        XCTAssertGreaterThan(scroll.contentSize.height, 1000)
        // Enter history through the same anchor path as the app, so the initial
        // bottom positioning cannot race the test's first manual scroll.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while Self.tealSampleCount(in: window) < 40 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
        }
        XCTAssertGreaterThan(Self.tealSampleCount(in: window), 40)
        let contentHeight = scroll.contentSize.height
        for offset: CGFloat in [50, 100, 150, 100, 50, 0] {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertGreaterThan(Self.tealSampleCount(in: window), 5,
                                 "生产 timeline 内部分可见的图片应保持显示，offset=\(offset)")
            XCTAssertEqual(scroll.contentSize.height, contentHeight, accuracy: 1)
            if offset == 150 {
                let attachment = XCTAttachment(image: Self.renderWindow(window))
                attachment.name = "native-timeline-media-partially-visible"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private static func tealSampleCount(in window: UIWindow) -> Int {
        let screenshot = renderWindow(window)
        guard let image = screenshot.cgImage else { return 0 }
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32,
                                          bitsPerComponent: 8, bytesPerRow: 32 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] < 100 && pixels[$0 + 1] > 130 && pixels[$0 + 2] > 130
        }.count
    }

    private static func renderWindow(_ window: UIWindow) -> UIImage {
        // Capture composited SwiftUI content after the attached window's screen update.
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private static func makeWindow(size: CGSize) async throws -> UIWindow {
        func activeScene() -> UIWindowScene? {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while activeScene() == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let scene = try XCTUnwrap(activeScene(), "媒体视觉测试需要实际处于前台的 window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        return window
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

    func testImageIODownsampleRespectsMaxPixelSizePreservesEXIFOrientationAndAlpha() throws {
        // 1) EXIF orientation = 6 (90° CW): raw 400x200 landscape buffer with red left half
        //    becomes 200x400 portrait after transform, then downsampled to 100x200 (<= 200px).
        let rawSize = CGSize(width: 400, height: 200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rawImage = UIGraphicsImageRenderer(size: rawSize, format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        }
        let cgRaw = try XCTUnwrap(rawImage.cgImage)
        let orientedData = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(orientedData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgRaw, [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let downsampledJPEG = try XCTUnwrap(
            ChatImageEncoder.downsampledImage(from: orientedData as Data, maxPixelSize: 200)
        )
        let downsampledCG = try XCTUnwrap(downsampledJPEG.cgImage)
        XCTAssertEqual(downsampledCG.width, 100)
        XCTAssertEqual(downsampledCG.height, 200)
        XCTAssertEqual(downsampledJPEG.imageOrientation, .up)
        // After 90° CW rotation, the red half (originally left) moves to the top half.
        let topPixel = try XCTUnwrap(Self.rgbaPixel(in: downsampledCG, x: 50, y: 20))
        let bottomPixel = try XCTUnwrap(Self.rgbaPixel(in: downsampledCG, x: 50, y: 180))
        XCTAssertGreaterThan(topPixel.r, 180)
        XCTAssertLessThan(topPixel.b, 80)
        XCTAssertGreaterThan(bottomPixel.b, 180)
        XCTAssertLessThan(bottomPixel.r, 80)

        // 2) Transparent PNG preserves alpha channel without flattening to JPEG.
        let alphaFormat = UIGraphicsImageRendererFormat()
        alphaFormat.scale = 1
        alphaFormat.opaque = false
        let alphaPNG = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: alphaFormat).pngData { ctx in
            ctx.cgContext.clear(CGRect(x: 0, y: 0, width: 300, height: 400))
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 300, y: 0, width: 300, height: 400))
        }
        let downsampledPNG = try XCTUnwrap(
            ChatImageEncoder.downsampledImage(from: alphaPNG, maxPixelSize: 300)
        )
        let pngCG = try XCTUnwrap(downsampledPNG.cgImage)
        XCTAssertEqual(pngCG.width, 300)
        XCTAssertEqual(pngCG.height, 200)
        let clearPixel = try XCTUnwrap(Self.rgbaPixel(in: pngCG, x: 50, y: 100))
        let opaquePixel = try XCTUnwrap(Self.rgbaPixel(in: pngCG, x: 250, y: 100))
        XCTAssertEqual(clearPixel.a, 0)
        XCTAssertEqual(opaquePixel.a, 255)
    }

    func testDataImageLoaderBucketsByMaxPixelSizeAndPreviewSharePreservesOriginalDimensions() async throws {
        let originalData = Self.imageData(size: CGSize(width: 2048, height: 1536))
        let dataURL = Self.dataURL(originalData)

        let decodeCounter = OSAllocatedUnfairLock(initialState: 0)
        let loader = ChatDataImageLoader(onDecode: {
            decodeCounter.withLock { $0 += 1 }
        })

        guard case .success(let tileImage) = await loader.resolve(
            urlString: dataURL,
            maxPixelSize: ChatGeneratedImageTile.tilePixelLimit
        ) else {
            return XCTFail("Expected tile downsampled decode to succeed")
        }
        XCTAssertEqual(tileImage.cgImage?.width, 1200)
        XCTAssertEqual(tileImage.cgImage?.height, 900)

        guard case .success(let previewImage) = await loader.resolve(
            urlString: dataURL,
            maxPixelSize: ChatGeneratedImagePreview.previewPixelLimit
        ) else {
            return XCTFail("Expected preview high-res decode to succeed")
        }
        XCTAssertEqual(previewImage.cgImage?.width, 2048)
        XCTAssertEqual(previewImage.cgImage?.height, 1536)
        XCTAssertEqual(decodeCounter.withLock { $0 }, 2, "Distinct maxPixelSize buckets must cache independently")

        // Second lookup on the same bucket hits memory cache without re-decoding.
        guard case .success = await loader.resolve(
            urlString: dataURL,
            maxPixelSize: ChatGeneratedImageTile.tilePixelLimit
        ) else {
            return XCTFail("Expected cached tile lookup to succeed")
        }
        XCTAssertEqual(decodeCounter.withLock { $0 }, 2)

        // Preview display loader & ShareLink payload must preserve original full dimensions.
        guard case .success(let displayImage) = await ChatGeneratedImagePreview.loadDisplayImage(urlString: dataURL) else {
            return XCTFail("Expected preview display load to succeed")
        }
        XCTAssertEqual(displayImage.cgImage?.width, 2048)
        XCTAssertEqual(displayImage.cgImage?.height, 1536)

        guard case .data(let payload) = ChatGeneratedImagePreview.shareItem(for: dataURL) else {
            return XCTFail("Expected data URL share item to produce lossless data payload")
        }
        let exportedData = try await payload.exported(as: payload.contentType)
        XCTAssertEqual(exportedData, originalData)
        let exportedImage = try XCTUnwrap(UIImage(data: exportedData)?.cgImage)
        XCTAssertEqual(exportedImage.width, 2048)
        XCTAssertEqual(exportedImage.height, 1536)

        // File URL share item must return the original file URL directly.
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("generated-share-\(UUID().uuidString).png")
        try originalData.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        guard case .url(let sharedURL) = ChatGeneratedImagePreview.shareItem(for: tempFile.absoluteString) else {
            return XCTFail("Expected file URL share item to share original URL")
        }
        XCTAssertEqual(sharedURL.standardizedFileURL, tempFile.standardizedFileURL)
    }

    private static func rgbaPixel(in image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
