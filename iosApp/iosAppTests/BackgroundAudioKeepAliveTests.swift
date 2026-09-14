import AVFoundation
import XCTest
@testable import iosApp

@MainActor
final class BackgroundAudioKeepAliveTests: XCTestCase {
    private final class PlayerSpy: BackgroundAudioKeepAlivePlayer {
        var numberOfLoops = 0
        var volume: Float = 0
        var isPlaying = false
        var playCount = 0

        @discardableResult
        func prepareToPlay() -> Bool { true }

        @discardableResult
        func play() -> Bool {
            playCount += 1
            isPlaying = true
            return true
        }

        func stop() {
            isPlaying = false
        }
    }

    func testInterruptionEndedReactivatesSessionBeforeResumingPlayer() async {
        let session = AVAudioSession.sharedInstance()
        let player = PlayerSpy()
        var activationCount = 0
        let keepAlive = BackgroundAudioKeepAlive(
            session: session,
            playerFactory: { player },
            activateSessionOverride: { _ in activationCount += 1 }
        )

        keepAlive.start()
        XCTAssertTrue(keepAlive.isActive)
        XCTAssertEqual(activationCount, 1)

        // Recovery is delayed and rebuilds the driver after reacquiring the
        // session. Wait for the observable recovery rather than a fixed frame.
        player.isPlaying = false
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: session,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue
            ]
        )
        let deadline = Date().addingTimeInterval(2)
        while !keepAlive.isActive, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(activationCount, 2)
        XCTAssertEqual(player.playCount, 2)
        XCTAssertTrue(keepAlive.isActive)
        keepAlive.stop()
    }

    func testStoppedKeepAliveDoesNotRestartAfterLateInterruptionEnded() async {
        let session = AVAudioSession.sharedInstance()
        let player = PlayerSpy()
        var activationCount = 0
        let keepAlive = BackgroundAudioKeepAlive(
            session: session,
            playerFactory: { player },
            activateSessionOverride: { _ in activationCount += 1 }
        )

        keepAlive.start()
        keepAlive.stop()
        let playCountAfterStop = player.playCount

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: session,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue
            ]
        )
        await settleMainActorCallback()

        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(player.playCount, playCountAfterStop)
        XCTAssertFalse(keepAlive.isActive)
    }

    func testHealthCheckRecoversStoppedPlayer() async throws {
        let player = PlayerSpy()
        let keepAlive = BackgroundAudioKeepAlive(
            playerFactory: { player },
            activateSessionOverride: { _ in }
        )
        defer { keepAlive.stop() }
        keepAlive.start()
        XCTAssertTrue(keepAlive.isActive)
        player.stop()

        // Exercise the real DispatchSource callback; the crash occurred at its
        // actor-isolation check, before its inner MainActor task could run.
        let deadline = Date().addingTimeInterval(4)
        while player.playCount < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(player.playCount, 2)
        XCTAssertTrue(keepAlive.isActive)
    }

    private func settleMainActorCallback() async {
        try? await Task.sleep(for: .milliseconds(650))
    }
}
