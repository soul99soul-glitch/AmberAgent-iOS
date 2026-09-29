import AVFoundation
import Foundation
import UIKit

extension Notification.Name {
    static let amberBackgroundAudioKeepAliveChanged = Notification.Name("app.amber.ios.backgroundAudioKeepAliveChanged")
}

@MainActor
protocol BackgroundAudioKeepAliveControlling: AnyObject {
    var isActive: Bool { get }
    /// True once a recovery attempt has been dispatched but not yet verified,
    /// in addition to `isActive`. Callers that must not treat "haven't checked
    /// yet" as "definitely failed" (e.g. deciding whether to submit a system
    /// continued-processing task) should read this instead of `isActive`.
    var isStartingOrActive: Bool { get }
    func start()
    func stop()
}

protocol BackgroundAudioKeepAlivePlayer: AnyObject {
    var isPlaying: Bool { get }
    @discardableResult func play() -> Bool
    func stop()
}

/// The engine renders a silent loop. Its actual engine/node state, rather than
/// a cached intent flag, tells the assertion owner whether playback is alive.
private final class BackgroundKeepAliveAudioEngine: BackgroundAudioKeepAlivePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer

    init() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100),
              let samples = buffer.floatChannelData?[0] else {
            throw CocoaError(.coderInvalidValue)
        }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { samples[index] = 0 }
        self.buffer = buffer
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        node.volume = 0.001
    }

    var isPlaying: Bool { engine.isRunning && node.isPlaying }

    func play() -> Bool {
        if isPlaying { return true }
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: .loops)
        do {
            engine.prepare()
            if !engine.isRunning { try engine.start() }
            node.play()
            return isPlaying
        } catch {
            NSLog("[AmberAudioKeepAlive] engine start failed: %@", String(describing: error))
            return false
        }
    }

    func stop() {
        node.stop()
        engine.stop()
    }
}

/// Wraps a plain closure so it can cross into `@Sendable`-typed Dispatch APIs
/// without requiring its captures to be individually `Sendable`.
///
/// This is safe here specifically because every wrapped closure is handed to
/// exactly one serial queue for exactly one execution, and nothing on the
/// capturing (main) side touches the same state concurrently with it — the
/// handoff itself, not per-capture Sendability, is what keeps this data-race
/// free. See `BackgroundAudioKeepAlive.blockingAudioWorkRunner`.
private struct UncheckedSendableWork: @unchecked Sendable {
    let run: () -> Void
}

private struct UncheckedSendableMainWork: @unchecked Sendable {
    let run: @MainActor () -> Void
}

/// 只在音频工作队列上读写：最近一次会话激活的序号。丢弃过期的启动结果时，仅当其
/// 激活之后没有更新的激活才反激活，避免 stop 后立即 start 时关掉新一代刚激活的会话。
private final class SessionActivationEpoch: @unchecked Sendable {
    var value = 0
}

private let sessionActivationEpoch = SessionActivationEpoch()

/// Shared by all run leases. Playback demand survives a temporary audio failure;
/// user stop and foreground speech owners always take precedence over recovery.
@MainActor
final class BackgroundAudioKeepAlive: BackgroundAudioKeepAliveControlling {
    static let shared = BackgroundAudioKeepAlive()

    /// Runs `work` (which must perform only blocking, non-actor-isolated work —
    /// no touching `self`) off the caller, then delivers `completion` back on
    /// the main actor. Production hops to a private serial queue and back to
    /// the main queue so AVFoundation's blocking calls (session activate,
    /// engine construct/start/stop) never run on the main thread. Tests inject
    /// a fully synchronous variant so existing assertions that read state
    /// immediately after `start()` keep working unchanged — the entire
    /// operation, `completion` included, finishes before `start()` returns.
    typealias BlockingAudioWorkRunner = (
        _ work: @escaping () -> Void,
        _ completion: @escaping @MainActor () -> Void
    ) -> Void

    private static let workQueue = DispatchQueue(label: "app.amber.backgroundAudioKeepAlive", qos: .userInitiated)

    static let defaultBlockingAudioWorkRunner: BlockingAudioWorkRunner = { work, completion in
        let boxedWork = UncheckedSendableWork(run: work)
        let boxedCompletion = UncheckedSendableMainWork(run: completion)
        workQueue.async {
            boxedWork.run()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    boxedCompletion.run()
                }
            }
        }
    }

    /// Holds one attempt's outcome across the queue hop. `@unchecked Sendable`
    /// for the same single-owner-handoff reason as `UncheckedSendableWork`.
    private final class RecoveryResult: @unchecked Sendable {
        var player: BackgroundAudioKeepAlivePlayer?
        var sessionActivated = false
        var activationEpoch = 0
        var error: Error?
    }

    var isActive: Bool { wantsPlayback && player?.isPlaying == true }
    var isStartingOrActive: Bool { isStarting || isActive }

    private var wantsPlayback = false
    private var interrupted = false
    private var mediaOwners: Set<String> = []
    private var ownsSession = false
    private var lastAppliedExclusive: Bool?
    private var player: BackgroundAudioKeepAlivePlayer?
    private var observerTokens: [NSObjectProtocol] = []
    private var retryTask: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    private var healthTimer: DispatchSourceTimer?
    private var recoveryAttempts = 0
    private let maximumRecoveryAttempts = 3
    /// True from the moment a recovery attempt is dispatched until its result
    /// (success, failure, or discard because it was superseded) is applied.
    private var isStarting = false
    /// Bumped by every call that changes what "the current attempt" means
    /// (`stop`, `suspend`, interruption began/ended, media services reset).
    /// A completion whose captured generation no longer matches is stale and
    /// gets torn down instead of applied.
    private var startGeneration = 0
    private let session: AVAudioSession
    private let playerFactory: () throws -> BackgroundAudioKeepAlivePlayer
    private let activateSessionOverride: ((Bool) throws -> Void)?
    /// Mirrors `activateSessionOverride` for the deactivate side. Production
    /// leaves this `nil`, in which case `performDeactivateSession` falls back
    /// to its prior behavior (real `session.setActive(false)`, or a no-op
    /// when `activateSessionOverride` is set — deactivation was never
    /// observable through that override alone). Tests that need to observe
    /// deactivation while still avoiding the real `AVAudioSession` supply
    /// both overrides.
    private let deactivateSessionOverride: (() -> Void)?
    private let blockingAudioWorkRunner: BlockingAudioWorkRunner

    init(
        session: AVAudioSession = .sharedInstance(),
        playerFactory: @escaping () throws -> BackgroundAudioKeepAlivePlayer = { try BackgroundKeepAliveAudioEngine() },
        activateSessionOverride: ((Bool) throws -> Void)? = nil,
        deactivateSessionOverride: (() -> Void)? = nil,
        blockingAudioWorkRunner: @escaping BlockingAudioWorkRunner = BackgroundAudioKeepAlive.defaultBlockingAudioWorkRunner
    ) {
        self.session = session
        self.playerFactory = playerFactory
        self.activateSessionOverride = activateSessionOverride
        self.deactivateSessionOverride = deactivateSessionOverride
        self.blockingAudioWorkRunner = blockingAudioWorkRunner
    }

    func start() {
        installObserversIfNeeded()
        if !wantsPlayback { recoveryAttempts = 0 }
        wantsPlayback = true
        startHealthCheckIfNeeded()
        guard mayPlay, !isActive, !isStarting, retryTask == nil else { return }
        recoverPlayback()
    }

    func stop() {
        wantsPlayback = false
        invalidateInFlightAttempt()
        retryTask?.cancel()
        retryTask = nil
        foregroundTask?.cancel()
        foregroundTask = nil
        healthTimer?.cancel()
        healthTimer = nil
        recoveryAttempts = 0
        destroyPlayer()
        deactivateOwnedSession()
        IOSBackgroundLifecycleLog.record("audioKeepAliveStop")
    }

    /// A key belongs to one utterance/media owner. A late callback can only
    /// release its own key; it cannot resume over a newer utterance.
    func suspend(for owner: String) {
        guard mediaOwners.insert(owner).inserted else { return }
        invalidateInFlightAttempt()
        retryTask?.cancel()
        retryTask = nil
        destroyPlayer()
        deactivateOwnedSession()
        IOSBackgroundLifecycleLog.record("audioKeepAliveMediaSuspended", detail: playbackDetail)
    }

    func resume(for owner: String) {
        guard mediaOwners.remove(owner) != nil, mediaOwners.isEmpty, wantsPlayback else { return }
        scheduleRecovery(resetAttempts: true)
    }

    private var mayPlay: Bool { wantsPlayback && !interrupted && mediaOwners.isEmpty }
    private var shouldBeExclusive: Bool { UIApplication.shared.applicationState == .background }

    /// Bumps the generation token and clears `isStarting` synchronously so a
    /// call made right after (e.g. `start()` right after `stop()`) is free to
    /// begin a fresh attempt instead of being blocked by a stale in-flight one,
    /// and so a stale completion that lands later is recognized as superseded.
    private func invalidateInFlightAttempt() {
        startGeneration += 1
        isStarting = false
    }

    private func recoverPlayback() {
        guard mayPlay, !isActive, !isStarting, recoveryAttempts < maximumRecoveryAttempts else { return }
        recoveryAttempts += 1
        isStarting = true
        startGeneration += 1
        let generation = startGeneration
        let exclusive = shouldBeExclusive
        let priorPlayer = player
        player = nil
        let override = activateSessionOverride
        let sessionRef = session
        let factory = playerFactory
        let result = RecoveryResult()

        blockingAudioWorkRunner({
            priorPlayer?.stop()
            do {
                try Self.performActivateSession(exclusive: exclusive, override: override, session: sessionRef)
                result.sessionActivated = true
                sessionActivationEpoch.value += 1
                result.activationEpoch = sessionActivationEpoch.value
                let candidate = try factory()
                guard candidate.play() else { throw CocoaError(.coderInvalidValue) }
                result.player = candidate
            } catch {
                result.error = error
            }
        }, { [weak self] in
            self?.completeRecovery(generation: generation, exclusive: exclusive, result: result)
        })
    }

    private func completeRecovery(generation: Int, exclusive: Bool, result: RecoveryResult) {
        guard generation == startGeneration else {
            discardStartResult(result)
            return
        }
        isStarting = false
        guard mayPlay else {
            discardStartResult(result)
            return
        }
        if let candidate = result.player, result.error == nil {
            if result.sessionActivated {
                ownsSession = true
                lastAppliedExclusive = exclusive
            }
            player = candidate
            recoveryAttempts = 0
            IOSBackgroundLifecycleLog.record("audioKeepAliveStart", detail: playbackDetail)
            NotificationCenter.default.post(name: .amberBackgroundAudioKeepAliveChanged, object: self)
            // 启动在途时前后台已切换（applySessionForCurrentState 在途期间空转）：按当前状态重投类别。
            if exclusive != shouldBeExclusive {
                reapplySessionCategory(exclusive: shouldBeExclusive)
            }
        } else {
            discardStartResult(result)
            let error = result.error ?? CocoaError(.coderInvalidValue)
            IOSBackgroundLifecycleLog.record(
                "audioKeepAliveStartFailed(attempt=\(recoveryAttempts))",
                detail: String(describing: error)
            )
            // scheduleRecovery posts .amberBackgroundAudioKeepAliveChanged itself
            // once attempts are exhausted, so BackgroundGenerationKeepAlive can
            // fall back to a system continued-processing task if one is owed.
            scheduleRecovery(resetAttempts: false)
        }
    }

    /// Tears down a start attempt's result that must not be applied (superseded
    /// generation, or intent changed while it was in flight). Still runs the
    /// blocking teardown off the main thread.
    private func discardStartResult(_ result: RecoveryResult, keepPlayer: Bool = false) {
        let candidate = keepPlayer ? nil : result.player
        guard candidate != nil || result.sessionActivated else { return }
        let override = activateSessionOverride
        let deactivateOverride = deactivateSessionOverride
        let sessionRef = session
        let sessionActivated = result.sessionActivated
        let epoch = result.activationEpoch
        blockingAudioWorkRunner({
            candidate?.stop()
            if sessionActivated, sessionActivationEpoch.value == epoch {
                Self.performDeactivateSession(override: override, deactivateOverride: deactivateOverride, session: sessionRef)
            }
        }, {})
    }

    /// One retry slot after a failed attempt. Returns whether a retry was
    /// actually scheduled; when attempts are exhausted (and nothing is already
    /// pending) this is a definitive failure, so callers care about the
    /// distinction to decide whether to fall back to another keep-alive leg.
    @discardableResult
    private func scheduleRecovery(resetAttempts: Bool) -> Bool {
        guard mayPlay else { return false }
        if resetAttempts { recoveryAttempts = 0 }
        guard retryTask == nil else { return false }
        guard recoveryAttempts < maximumRecoveryAttempts else {
            NotificationCenter.default.post(name: .amberBackgroundAudioKeepAliveChanged, object: self)
            return false
        }
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            self.recoverPlayback()
        }
        return true
    }

    private func startHealthCheckIfNeeded() {
        guard healthTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.mayPlay, !self.isActive, !self.isStarting, self.retryTask == nil else { return }
                self.recoverPlayback()
            }
        }
        healthTimer = timer
        timer.resume()
    }

    private func installObserversIfNeeded() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, valueKey: String? = nil,
                     _ action: @escaping @MainActor @Sendable (UInt?) -> Void) {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let value = valueKey.flatMap { notification.userInfo?[$0] as? UInt }
                Task { @MainActor in action(value) }
            })
        }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] _ in
            guard let self else { return }
            self.foregroundTask?.cancel()
            self.foregroundTask = nil
            self.applySessionForCurrentState()
        }
        observe(UIApplication.didBecomeActiveNotification) { [weak self] _ in
            guard let self else { return }
            self.foregroundTask?.cancel()
            self.foregroundTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(1_500)) } catch { return }
                guard let self, !self.shouldBeExclusive else { return }
                self.applySessionForCurrentState()
            }
        }
        observe(AVAudioSession.interruptionNotification, valueKey: AVAudioSessionInterruptionTypeKey) { [weak self] value in
            guard let self, let value,
                  let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
            self.interrupted = type == .began
            self.invalidateInFlightAttempt()
            self.retryTask?.cancel()
            self.retryTask = nil
            self.destroyPlayer()
            if type == .began {
                self.ownsSession = false // The system has already withdrawn it.
                IOSBackgroundLifecycleLog.record("audioKeepAliveInterrupted", detail: self.playbackDetail)
            } else {
                self.scheduleRecovery(resetAttempts: true)
            }
        }
        observe(AVAudioSession.routeChangeNotification, valueKey: AVAudioSessionRouteChangeReasonKey) { [weak self] value in
            guard let self, self.mayPlay else { return }
            let reason = value.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            if !self.isActive {
                self.scheduleRecovery(resetAttempts: reason != .categoryChange)
            }
        }
        observe(.AVAudioEngineConfigurationChange) { [weak self] _ in
            guard let self, self.mayPlay, self.player != nil, !self.isActive else { return }
            self.scheduleRecovery(resetAttempts: self.recoveryAttempts == 0)
        }
        observe(AVAudioSession.silenceSecondaryAudioHintNotification, valueKey: AVAudioSessionSilenceSecondaryAudioHintTypeKey) { [weak self] value in
            guard let self, let value,
                  let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: value) else { return }
            if type == .begin { self.suspend(for: "system-secondary-audio") }
            else { self.resume(for: "system-secondary-audio") }
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            guard let self else { return }
            self.ownsSession = false
            self.invalidateInFlightAttempt()
            self.destroyPlayer()
            self.interrupted = false
            self.scheduleRecovery(resetAttempts: true)
        }
    }

    /// Foreground/background transitions: an already-playing engine only needs
    /// its session category re-applied (exclusive vs. mixable); a stopped one
    /// goes through the normal recovery path. Both keep AVFoundation's blocking
    /// calls off the main thread.
    private func applySessionForCurrentState() {
        guard mayPlay else { return }
        recoveryAttempts = 0
        if isActive {
            reapplySessionCategory(exclusive: shouldBeExclusive)
        } else if !isStarting {
            recoverPlayback()
        }
    }

    private func reapplySessionCategory(exclusive: Bool) {
        let override = activateSessionOverride
        let sessionRef = session
        let result = RecoveryResult()
        blockingAudioWorkRunner({
            do {
                try Self.performActivateSession(exclusive: exclusive, override: override, session: sessionRef)
                result.sessionActivated = true
                sessionActivationEpoch.value += 1
                result.activationEpoch = sessionActivationEpoch.value
            } catch {
                result.error = error
            }
        }, { [weak self] in
            self?.completeReapply(exclusive: exclusive, result: result)
        })
    }

    private func completeReapply(exclusive: Bool, result: RecoveryResult) {
        guard mayPlay else {
            discardStartResult(result, keepPlayer: true)
            return
        }
        if result.sessionActivated {
            ownsSession = true
            lastAppliedExclusive = exclusive
        } else {
            destroyPlayer()
            deactivateOwnedSession()
            scheduleRecovery(resetAttempts: false)
        }
    }

    private nonisolated static func performActivateSession(
        exclusive: Bool,
        override: ((Bool) throws -> Void)?,
        session: AVAudioSession
    ) throws {
        if let override {
            try override(exclusive)
        } else {
            try session.setCategory(.playback, mode: .default, options: exclusive ? [] : [.mixWithOthers])
            try session.setActive(true)
        }
    }

    private nonisolated static func performDeactivateSession(
        override: ((Bool) throws -> Void)?,
        deactivateOverride: (() -> Void)?,
        session: AVAudioSession
    ) {
        if let deactivateOverride {
            deactivateOverride()
            return
        }
        guard override == nil else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func destroyPlayer() {
        guard let existing = player else { return }
        player = nil
        blockingAudioWorkRunner({ existing.stop() }, {})
    }

    private func deactivateOwnedSession() {
        guard ownsSession else { return }
        ownsSession = false
        let override = activateSessionOverride
        let deactivateOverride = deactivateSessionOverride
        let sessionRef = session
        blockingAudioWorkRunner({
            Self.performDeactivateSession(override: override, deactivateOverride: deactivateOverride, session: sessionRef)
        }, {})
    }

    private var playbackDetail: String {
        "exclusive=\(lastAppliedExclusive == true ? 1 : 0) playing=\(isActive ? 1 : 0) mediaOwners=\(mediaOwners.count)"
    }
}
