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

    /// Runs the blocking work and its completion inline, on the calling thread,
    /// before returning — matching the pre-refactor fully-synchronous
    /// `recoverPlayback()` so assertions right after `start()` keep working
    /// unchanged. Production instead hops to a private queue and back
    /// (`BackgroundAudioKeepAlive.defaultBlockingAudioWorkRunner`).
    private static let synchronousBlockingAudioWorkRunner: BackgroundAudioKeepAlive.BlockingAudioWorkRunner = { work, completion in
        work()
        MainActor.assumeIsolated { completion() }
    }

    func testInterruptionEndedReactivatesSessionBeforeResumingPlayer() async {
        let session = AVAudioSession.sharedInstance()
        let player = PlayerSpy()
        var activationCount = 0
        let keepAlive = BackgroundAudioKeepAlive(
            session: session,
            playerFactory: { player },
            activateSessionOverride: { _ in activationCount += 1 },
            blockingAudioWorkRunner: Self.synchronousBlockingAudioWorkRunner
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
            activateSessionOverride: { _ in activationCount += 1 },
            blockingAudioWorkRunner: Self.synchronousBlockingAudioWorkRunner
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
            activateSessionOverride: { _ in },
            blockingAudioWorkRunner: Self.synchronousBlockingAudioWorkRunner
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

    /// `recoverPlayback()` dispatches session activation + engine construction
    /// off the main thread and only applies the result on the main actor once
    /// it verifies the attempt is still current. This exercises exactly that
    /// window: `stop()` lands while the attempt is in flight (its blocking work
    /// already ran, but its completion hasn't been delivered back yet), and the
    /// result must be discarded — including tearing the just-built engine back
    /// down — rather than resurrecting a player nobody wants anymore.
    func testStopDuringInFlightStartDiscardsResult() {
        let player = PlayerSpy()
        var deliverCompletion: (() -> Void)?
        let keepAlive = BackgroundAudioKeepAlive(
            playerFactory: { player },
            activateSessionOverride: { _ in },
            blockingAudioWorkRunner: { work, completion in
                work()
                deliverCompletion = { MainActor.assumeIsolated { completion() } }
            }
        )

        keepAlive.start()
        XCTAssertTrue(keepAlive.isStartingOrActive)
        XCTAssertFalse(keepAlive.isActive)
        XCTAssertEqual(player.playCount, 1)

        keepAlive.stop()
        XCTAssertFalse(keepAlive.isStartingOrActive)

        deliverCompletion?()

        XCTAssertFalse(keepAlive.isActive)
        XCTAssertFalse(keepAlive.isStartingOrActive)
        // The discarded attempt's engine must still be torn down, not leaked
        // running in the background.
        XCTAssertFalse(player.isPlaying)
    }

    private func settleMainActorCallback() async {
        try? await Task.sleep(for: .milliseconds(650))
    }

    /// Records activate/deactivate calls in submission order. `@unchecked
    /// Sendable` + a lock because `activateSessionOverride` /
    /// `deactivateSessionOverride` run on `BackgroundAudioKeepAlive`'s real
    /// private serial queue in `testStopThenRestartDuringInFlightFirstAttemptDoesNotDeactivateNewSession`,
    /// not on the main thread.
    private final class SessionEventRecorder: @unchecked Sendable {
        enum Event: Equatable { case activate, deactivate }
        private let lock = NSLock()
        private var _events: [Event] = []
        var events: [Event] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }
        func recordActivate() {
            lock.lock(); _events.append(.activate); lock.unlock()
        }
        func recordDeactivate() {
            lock.lock(); _events.append(.deactivate); lock.unlock()
        }
    }

    /// Creates a fresh `PlayerSpy` per call and records creation order, so a
    /// test can tell the first attempt's player apart from the second's.
    /// `@unchecked Sendable` + a lock for the same reason as
    /// `SessionEventRecorder`: `playerFactory` runs on the real serial queue.
    private final class PlayerFactorySpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _createdPlayers: [PlayerSpy] = []
        var createdPlayers: [PlayerSpy] {
            lock.lock(); defer { lock.unlock() }
            return _createdPlayers
        }
        func makePlayer() -> BackgroundAudioKeepAlivePlayer {
            let player = PlayerSpy()
            lock.lock(); _createdPlayers.append(player); lock.unlock()
            return player
        }
    }

    /// Regression test for the ordering bug the `sessionActivationEpoch` guard
    /// fixes. Unlike the other tests in this file, this one injects the real
    /// `BackgroundAudioKeepAlive.defaultBlockingAudioWorkRunner` (a genuine
    /// private serial `DispatchQueue`), not `synchronousBlockingAudioWorkRunner`
    /// — the bug only reproduces with a real queue hop between the blocking
    /// work and its main-actor completion.
    ///
    /// Sequence: `start()` dispatches attempt #1's blocking work onto the
    /// queue. Before its completion can land back on main (that hop is
    /// asynchronous), the test calls `stop()` then `start()` synchronously —
    /// both run to completion on main without yielding, so attempt #2's
    /// blocking work is enqueued onto the *same* serial queue strictly after
    /// attempt #1's, before attempt #1's completion has had any chance to run.
    /// The queue therefore always finishes attempt #1 before starting attempt
    /// #2, `sessionActivationEpoch` bumped once for each. Only once attempt
    /// #1's completion later runs on main (finding its generation stale) does
    /// `discardStartResult` enqueue attempt #1's discard cleanup onto that same
    /// queue — necessarily *after* attempt #2's activation, since its enqueue
    /// causally depends on attempt #1 having already finished. This ordering
    /// holds regardless of real wall-clock timing, so the test is
    /// deterministic despite using a real queue.
    ///
    /// Before the epoch guard existed, that discard cleanup deactivated the
    /// session unconditionally whenever `result.sessionActivated` was true,
    /// with no check of whether a newer attempt had since reactivated it. Since
    /// the cleanup provably runs after attempt #2's activation, it would have
    /// torn down the session attempt #2 had just stood up — a stray
    /// `.deactivate` event landing after both `.activate` events. The player
    /// (`player?.isPlaying`) and `isActive` would still look fine either way
    /// (only the *session* deactivation was unconditional, not the leaked
    /// player's `.stop()`), so only observing the deactivate call itself, as
    /// this test does via `deactivateSessionOverride`, actually catches the
    /// regression.
    func testStopThenRestartDuringInFlightFirstAttemptDoesNotDeactivateNewSession() async {
        let recorder = SessionEventRecorder()
        let playerFactorySpy = PlayerFactorySpy()
        let keepAlive = BackgroundAudioKeepAlive(
            playerFactory: { playerFactorySpy.makePlayer() },
            activateSessionOverride: { _ in recorder.recordActivate() },
            deactivateSessionOverride: { recorder.recordDeactivate() }
        )
        defer { keepAlive.stop() }

        keepAlive.start()
        keepAlive.stop()
        keepAlive.start()

        let deadline = Date().addingTimeInterval(3)
        while !keepAlive.isActive, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Give the first attempt's now-stale completion (and its discard
        // cleanup) a further window to land; it races the second attempt's
        // completion on main but always loses the queue-ordering race above.
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(keepAlive.isActive)
        XCTAssertEqual(playerFactorySpy.createdPlayers.count, 2)
        XCTAssertFalse(playerFactorySpy.createdPlayers[0].isPlaying)
        XCTAssertTrue(playerFactorySpy.createdPlayers[1].isPlaying)
        XCTAssertEqual(
            recorder.events, [.activate, .activate],
            "the stale first attempt's discard cleanup must not deactivate the session the second attempt just activated"
        )
    }
}
