import AVFoundation
import Foundation
import UIKit

extension Notification.Name {
    static let amberBackgroundAudioKeepAliveChanged = Notification.Name("app.amber.ios.backgroundAudioKeepAliveChanged")
}

@MainActor
protocol BackgroundAudioKeepAliveControlling: AnyObject {
    var isActive: Bool { get }
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

/// Shared by all run leases. Playback demand survives a temporary audio failure;
/// user stop and foreground speech owners always take precedence over recovery.
@MainActor
final class BackgroundAudioKeepAlive: BackgroundAudioKeepAliveControlling {
    static let shared = BackgroundAudioKeepAlive()

    var isActive: Bool { wantsPlayback && player?.isPlaying == true }

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
    private let session: AVAudioSession
    private let playerFactory: () throws -> BackgroundAudioKeepAlivePlayer
    private let activateSessionOverride: ((Bool) throws -> Void)?

    init(
        session: AVAudioSession = .sharedInstance(),
        playerFactory: @escaping () throws -> BackgroundAudioKeepAlivePlayer = { try BackgroundKeepAliveAudioEngine() },
        activateSessionOverride: ((Bool) throws -> Void)? = nil
    ) {
        self.session = session
        self.playerFactory = playerFactory
        self.activateSessionOverride = activateSessionOverride
    }

    func start() {
        installObserversIfNeeded()
        if !wantsPlayback { recoveryAttempts = 0 }
        wantsPlayback = true
        startHealthCheckIfNeeded()
        guard mayPlay, !isActive, retryTask == nil else { return }
        recoverPlayback()
    }

    func stop() {
        wantsPlayback = false
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

    private func recoverPlayback() {
        guard mayPlay, !isActive, recoveryAttempts < maximumRecoveryAttempts else { return }
        recoveryAttempts += 1
        destroyPlayer()
        do {
            try activateSession(exclusive: shouldBeExclusive)
            let candidate = try playerFactory()
            player = candidate
            guard candidate.play() else { throw CocoaError(.coderInvalidValue) }
            recoveryAttempts = 0
            IOSBackgroundLifecycleLog.record("audioKeepAliveStart", detail: playbackDetail)
            NotificationCenter.default.post(name: .amberBackgroundAudioKeepAliveChanged, object: self)
        } catch {
            destroyPlayer()
            deactivateOwnedSession()
            IOSBackgroundLifecycleLog.record(
                "audioKeepAliveStartFailed(attempt=\(recoveryAttempts))",
                detail: String(describing: error)
            )
            scheduleRecovery(resetAttempts: false)
        }
    }

    private func scheduleRecovery(resetAttempts: Bool) {
        guard mayPlay else { return }
        if resetAttempts { recoveryAttempts = 0 }
        guard retryTask == nil, recoveryAttempts < maximumRecoveryAttempts else { return }
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            self.recoverPlayback()
        }
    }

    private func startHealthCheckIfNeeded() {
        guard healthTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.mayPlay, !self.isActive, self.retryTask == nil else { return }
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
            self.destroyPlayer()
            self.interrupted = false
            self.scheduleRecovery(resetAttempts: true)
        }
    }

    private func applySessionForCurrentState() {
        guard mayPlay else { return }
        recoveryAttempts = 0
        do {
            try activateSession(exclusive: shouldBeExclusive)
            if !isActive { recoverPlayback() }
        } catch {
            destroyPlayer()
            deactivateOwnedSession()
            scheduleRecovery(resetAttempts: false)
        }
    }

    private func activateSession(exclusive: Bool) throws {
        if let activateSessionOverride { try activateSessionOverride(exclusive) }
        else {
            try session.setCategory(.playback, mode: .default, options: exclusive ? [] : [.mixWithOthers])
            try session.setActive(true)
        }
        ownsSession = true
        lastAppliedExclusive = exclusive
    }

    private func destroyPlayer() {
        player?.stop()
        player = nil
    }

    private func deactivateOwnedSession() {
        guard ownsSession else { return }
        ownsSession = false
        if activateSessionOverride == nil {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private var playbackDetail: String {
        "exclusive=\(lastAppliedExclusive == true ? 1 : 0) playing=\(isActive ? 1 : 0) mediaOwners=\(mediaOwners.count)"
    }
}
