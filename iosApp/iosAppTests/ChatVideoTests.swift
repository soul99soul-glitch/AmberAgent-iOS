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

    func testVideoCardsFitNarrowWidthAndAccessibilityText() throws {
        for (name, ratio) in [("landscape", CGSize(width: 1920, height: 1080)), ("portrait", CGSize(width: 1080, height: 1920))] {
            let video = ChatVideoDescriptor(id: name, url: "https://example.com/video.mp4", title: "可独立播放的视频及完整来源标题",
                                            sourceURL: "https://example.com/article", width: ratio.width, height: ratio.height, duration: 92)
            let host = UIHostingController(rootView: ChatVideoCard(video: video).dynamicTypeSize(.accessibility2).padding(16))
            let size = host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(size.width, 320)
            XCTAssertGreaterThan(size.height, 180)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: ceil(size.height) + 40))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            window.layoutIfNeeded()
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "video-\(name)-320pt"
            attachment.lifetime = .keepAlways
            add(attachment)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("amber-video-\(name).png")
            try screenshot.pngData()?.write(to: path)
            print("MEDIA_SCREENSHOT=\(path.path)")
        }
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
