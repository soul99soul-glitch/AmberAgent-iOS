import AVFoundation
import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class ChatVideoTests: XCTestCase {
    @MainActor private final class AudioHarness {
        var owners: Set<String> = []
        var events: [String] = []
        var queuesWork = false
        var failsActivation = false
        var onQueued: (() -> Void)?
        var onResumed: (() -> Void)?
        var pending: [(() -> Void, @MainActor () -> Void)] = []

        var dependencies: ChatVideoPlayback.AudioDependencies {
            .init(
                suspend: { self.owners.insert($0); self.events.append("suspend") },
                resume: {
                    self.owners.remove($0)
                    self.events.append("resume")
                    self.onResumed?()
                },
                activate: {
                    self.events.append("activate")
                    if self.failsActivation { throw URLError(.cannotConnectToHost) }
                },
                deactivate: { self.events.append("deactivate") },
                run: { work, completion in
                    if self.queuesWork {
                        self.pending.append((work, completion))
                        self.onQueued?()
                    } else {
                        work()
                        completion()
                    }
                }
            )
        }

        func runNext() {
            let (work, completion) = pending.removeFirst()
            work()
            completion()
        }
    }

    func testPlaybackIsCreatedOnlyWhenPreparedAndReleasedOnStop() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = AudioHarness()
        let playback = ChatVideoPlayback(audio: audio.dependencies)
        XCTAssertNil(playback.player)
        await playback.prepare(url: url)
        XCTAssertNil(playback.failure)
        XCTAssertNotNil(playback.player?.currentItem)
        XCTAssertEqual(audio.owners.count, 1)
        playback.stop()
        XCTAssertNil(playback.player)
        XCTAssertTrue(audio.owners.isEmpty)
        XCTAssertEqual(audio.events, ["suspend", "activate", "deactivate", "resume"])
    }

    func testFailedVideoCanBeRetriedWithPlayableResource() async throws {
        let playback = ChatVideoPlayback(audio: AudioHarness().dependencies)
        await playback.prepare(url: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).mp4"))
        XCTAssertNotNil(playback.failure)
        XCTAssertNil(playback.player)
        let url = try await makeVideo()
        defer { playback.stop(); try? FileManager.default.removeItem(at: url) }
        await playback.prepare(url: url)
        XCTAssertNil(playback.failure)
        XCTAssertNotNil(playback.player)
    }

    func testCancelledPreparationCannotStartPlaybackAfterDismiss() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = ChatVideoPlayback(audio: AudioHarness().dependencies)
        let task = Task { await playback.prepare(url: url) }
        task.cancel()
        await task.value
        XCTAssertNil(playback.player)
    }

    func testCancellationDuringAudioActivationReleasesOwner() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = AudioHarness()
        audio.queuesWork = true
        let queued = expectation(description: "Audio activation queued")
        audio.onQueued = { queued.fulfill() }
        let playback = ChatVideoPlayback(audio: audio.dependencies)
        let task = Task { await playback.prepare(url: url) }
        await fulfillment(of: [queued], timeout: 5)
        audio.onQueued = nil
        XCTAssertEqual(audio.owners.count, 1)
        task.cancel()
        audio.runNext()
        await task.value
        XCTAssertNil(playback.player)
        XCTAssertNil(playback.failure)
        XCTAssertEqual(audio.pending.count, 1)
        audio.runNext()
        XCTAssertTrue(audio.owners.isEmpty)
        XCTAssertEqual(audio.events, ["suspend", "activate", "deactivate", "resume"])
    }

    func testOldPreparationAndCleanupCannotReleaseRetryOwner() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = AudioHarness()
        audio.queuesWork = true
        let firstQueued = expectation(description: "First activation queued")
        audio.onQueued = { firstQueued.fulfill() }
        let playback = ChatVideoPlayback(audio: audio.dependencies)
        let first = Task { await playback.prepare(url: url) }
        await fulfillment(of: [firstQueued], timeout: 5)
        audio.onQueued = nil
        let firstOwner = try XCTUnwrap(audio.owners.first)
        playback.stop()
        let retryQueued = expectation(description: "Retry activation queued after old teardown")
        audio.onQueued = { retryQueued.fulfill() }
        let retry = Task { await playback.prepare(url: url) }
        await fulfillment(of: [retryQueued], timeout: 5)
        audio.onQueued = nil
        XCTAssertEqual(audio.owners.count, 2)
        XCTAssertEqual(audio.pending.count, 3)
        audio.runNext()
        await first.value
        XCTAssertNil(playback.player, "Superseded preparation must not create a player")
        audio.runNext()
        XCTAssertEqual(audio.owners.count, 1)
        XCTAssertFalse(audio.owners.contains(firstOwner))
        audio.runNext()
        await retry.value
        XCTAssertNotNil(playback.player)
        XCTAssertNil(playback.failure)
        XCTAssertEqual(audio.owners.count, 1)
        playback.stop()
        audio.runNext()
        XCTAssertTrue(audio.owners.isEmpty)
        XCTAssertEqual(audio.events, ["suspend", "suspend", "activate", "deactivate", "resume", "activate", "deactivate", "resume"])
    }

    func testAudioActivationFailureReleasesOwnerAndCanRetry() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = AudioHarness()
        audio.failsActivation = true
        let playback = ChatVideoPlayback(audio: audio.dependencies)
        await playback.prepare(url: url)
        XCTAssertNotNil(playback.failure)
        XCTAssertNil(playback.player)
        XCTAssertTrue(audio.owners.isEmpty)
        audio.failsActivation = false
        await playback.prepare(url: url)
        XCTAssertNil(playback.failure)
        XCTAssertNotNil(playback.player)
        XCTAssertEqual(audio.owners.count, 1)
        playback.stop()
        XCTAssertTrue(audio.owners.isEmpty)
    }

    func testPlaybackFailureStopsPlayerAndReleasesAudioOwner() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = AudioHarness()
        let playback = ChatVideoPlayback(audio: audio.dependencies)
        await playback.prepare(url: url)
        let item = try XCTUnwrap(playback.player?.currentItem)
        let released = expectation(description: "Playback failure releases audio")
        audio.onResumed = { released.fulfill() }
        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: URLError(.networkConnectionLost)]
        )
        await fulfillment(of: [released], timeout: 5)
        XCTAssertNotNil(playback.failure)
        XCTAssertNil(playback.player)
        XCTAssertTrue(audio.owners.isEmpty)
    }

    func testVideoDescriptorRejectsNonMediaSchemesAndFormatsDuration() {
        XCTAssertNil(ChatVideoDescriptor(id: "a", url: "javascript:alert(1)").playbackURL)
        XCTAssertNil(ChatVideoDescriptor(id: "a", url: "not a url").playbackURL)
        XCTAssertEqual(ChatVideoDescriptor(id: "a", url: "https://example.com/stream", duration: 3661).durationLabel, "1:01:01")
        XCTAssertNil(ChatVideoDescriptor(id: "a", url: "https://example.com/stream", duration: .infinity).durationLabel)
        XCTAssertEqual(ChatVideoDescriptor(id: "a", url: "a", width: 1080, height: 1920).aspectRatio, 0.5625)
    }

    func testVideoCardsFitNarrowWidthAndAccessibilityText() async throws {
        for (name, ratio) in [("landscape", CGSize(width: 1920, height: 1080)), ("portrait", CGSize(width: 1080, height: 1920))] {
            let video = ChatVideoDescriptor(id: name, url: "file:///missing-video-poster-fixture.mp4", title: "可独立播放的视频及完整来源标题",
                                            sourceURL: "https://example.com/article", width: ratio.width, height: ratio.height, duration: 92)
            let host = UIHostingController(rootView: ChatVideoCard(video: video).dynamicTypeSize(.accessibility2).padding(16))
            host.safeAreaRegions = []
            let size = host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(size.width, 320)
            XCTAssertGreaterThan(size.height, 180)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: ceil(size.height) + 40)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height,
                           size.height, accuracy: 1)
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "video-\(name)-320pt"
            attachment.lifetime = .keepAlways
            add(attachment)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("amber-video-\(name).png")
            try screenshot.pngData()?.write(to: path)
            print("MEDIA_SCREENSHOT=\(path.path)")
        }
    }

    func testVideoPosterPrefersProvidedImageWithoutOpeningVideo() async throws {
        let poster = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).pngData { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }
        let video = ChatVideoDescriptor(id: "poster", url: "invalid-video-url",
                                        posterURL: "data:image/png;base64," + poster.base64EncodedString())
        let image = try await ChatVideoPosterLoader().image(video: video, pixelLimit: 20)
        XCTAssertEqual(image.size, CGSize(width: 20, height: 10))
    }

    func testBrokenPosterFallsBackToBoundedVideoFrameAndCachesIt() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let loader = ChatVideoPosterLoader()
        let video = ChatVideoDescriptor(id: "fallback", url: url.absoluteString,
                                        posterURL: "data:image/png;base64,YmFk")
        let first = try await loader.image(video: video, pixelLimit: 80)
        XCTAssertLessThanOrEqual(max(first.size.width, first.size.height), 80)
        XCTAssertGreaterThan(first.size.width, 0)
        let second = try await loader.image(video: video, pixelLimit: 80)
        XCTAssertTrue(first === second)
    }

    func testCancelledVideoPosterDoesNotPublishAnImage() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            try await ChatVideoPosterLoader().image(video: ChatVideoDescriptor(id: "cancel", url: url.absoluteString))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("已取消的封面请求不能返回成功")
        } catch is CancellationError { }
    }

    func testVideoWithoutPosterShowsFrameWithoutChangingCardHeight() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let video = ChatVideoDescriptor(id: "frame", url: url.absoluteString, title: "没有独立封面的视频")
        let host = UIHostingController(rootView: ChatVideoCard(video: video).padding(16))
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let proposal = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        let before = host.sizeThatFits(in: proposal)
        func snapshot() -> UIImage {
            UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
        func redPixels() -> Int {
            guard let image = snapshot().cgImage else { return 0 }
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                                        bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            return stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] > 180 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80
            }.count
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while redPixels() < 20 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(redPixels(), 20, "没有 posterURL 的真实 MP4 必须显示提取的首帧")
        XCTAssertEqual(host.sizeThatFits(in: proposal).height, before.height, accuracy: 1)
        let attachment = XCTAttachment(image: snapshot())
        attachment.name = "video-generated-poster-320pt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testVideoPosterPreloadsBeforeEnteringViewportAndStaysDuringPartialVisibility() async throws {
        let file = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: file) }
        let video = ChatVideoDescriptor(id: "prefetch", url: file.absoluteString, title: "预加载封面")
        let host = UIHostingController(rootView: ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 700)
                ChatVideoCard(video: video)
                Color.clear.frame(height: 1200)
            }
        })
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        func redSamples() -> Int {
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            guard let image = screenshot.cgImage else { return 0 }
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                                        bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            return stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] > 180 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80
            }.count
        }
        let scroll = try XCTUnwrap(scrollView(in: host.view))
        try await Task.sleep(for: .seconds(1))
        try FileManager.default.removeItem(at: file)
        for offset: CGFloat in [650, 750, 810, 850, 810, 750, 650] {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertGreaterThan(redSamples(), 5, "封面应提前加载，部分可见时保持原图，offset=\(offset)")
        }
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "video-poster-viewport-prefetched-and-retained"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 160, 96, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: 160, height: 96,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.setFillColor(UIColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 96))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        for value in 0..<2 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(value), timescale: 1)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }
}
