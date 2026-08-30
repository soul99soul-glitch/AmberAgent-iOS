import AVFoundation
import Foundation
import UIKit

/// 生成期间的第三条后台执行腿：循环播放一段听不见、但能量非零的音频。
///
/// iOS 只把「正在播放」当成可长期保活的理由。全零静音会被系统当没在播并挂起，
/// 所以这里用 18 kHz、极低振幅的正弦波，手机扬声器听不见，看门狗也读得到能量。
///
/// 前台用 `mixWithOthers`，不抢用户正在听的歌；进入后台后改成独占 playback，
/// 这是目前能拿到的最狠合法窗口。生成结束立刻停，不常驻。
@MainActor
protocol BackgroundAudioKeepAliveControlling: AnyObject {
    var isActive: Bool { get }
    func start()
    func stop()
}

@MainActor
final class BackgroundAudioKeepAlive: BackgroundAudioKeepAliveControlling {
    static let shared = BackgroundAudioKeepAlive()

    private(set) var isActive = false

    private var player: AVAudioPlayer?
    private var observerTokens: [NSObjectProtocol] = []
    private let session: AVAudioSession
    private let toneData: Data

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        self.toneData = NearSilentKeepAliveTone.wavData()
    }

    func start() {
        installObserversIfNeeded()
        guard !isActive else {
            resumePlaybackIfNeeded()
            return
        }
        do {
            try activateSession(exclusive: shouldBeExclusive)
            if player == nil {
                let player = try AVAudioPlayer(data: toneData)
                player.numberOfLoops = -1
                player.volume = 1
                player.prepareToPlay()
                self.player = player
            }
            guard player?.play() == true else {
                NSLog("[AmberAudioKeepAlive] AVAudioPlayer.play() returned false")
                deactivateSessionAfterFailedStart()
                return
            }
            isActive = true
            IOSBackgroundLifecycleLog.record("audioKeepAliveStart", detail: exclusiveDetail)
        } catch {
            NSLog("[AmberAudioKeepAlive] start failed: \(error)")
            deactivateSessionAfterFailedStart()
        }
    }

    func stop() {
        guard isActive else { return }
        player?.stop()
        isActive = false
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("[AmberAudioKeepAlive] deactivate failed: \(error)")
        }
        IOSBackgroundLifecycleLog.record("audioKeepAliveStop")
    }

    // MARK: - 前后台

    private var shouldBeExclusive: Bool {
        UIApplication.shared.applicationState == .background
    }

    private func installObserversIfNeeded() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default
        observerTokens.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleDidEnterBackground() }
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleWillEnterForeground() }
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor in self?.handleInterruption(typeValue: typeValue) }
            }
        )
    }

    private func handleDidEnterBackground() {
        guard isActive else { return }
        applySession(exclusive: true)
    }

    private func handleWillEnterForeground() {
        guard isActive else { return }
        applySession(exclusive: false)
    }

    private func handleInterruption(typeValue: UInt?) {
        guard isActive else { return }
        let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        if type == .ended {
            resumePlaybackIfNeeded()
        }
    }

    private func applySession(exclusive: Bool) {
        do {
            try activateSession(exclusive: exclusive)
            resumePlaybackIfNeeded()
            IOSBackgroundLifecycleLog.record(
                exclusive ? "audioKeepAliveExclusive" : "audioKeepAliveMix",
                detail: exclusiveDetail
            )
        } catch {
            NSLog("[AmberAudioKeepAlive] session update failed: \(error)")
            resumePlaybackIfNeeded()
        }
    }

    private func activateSession(exclusive: Bool) throws {
        let options: AVAudioSession.CategoryOptions = exclusive ? [] : [.mixWithOthers]
        try session.setCategory(.playback, mode: .default, options: options)
        try session.setActive(true)
    }

    /// `play()` / player 构造失败时 `isActive` 仍为 false，`stop()` 进不去；
    /// 这里把已经抢到的 playback session 还回去，避免用户音乐被挂起后收不回。
    private func deactivateSessionAfterFailedStart() {
        player?.stop()
        player = nil
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("[AmberAudioKeepAlive] deactivate after failed start failed: \(error)")
        }
    }

    private func resumePlaybackIfNeeded() {
        guard isActive, player?.isPlaying != true else { return }
        _ = player?.play()
    }

    private var exclusiveDetail: String {
        "exclusive=\(shouldBeExclusive ? 1 : 0)"
    }
}

/// 1 秒 18 kHz 正弦环，振幅约 -66 dBFS：听不见，但不是全零。
enum NearSilentKeepAliveTone {
    static func wavData(
        sampleRate: Int = 44_100,
        durationSeconds: Int = 1,
        frequency: Double = 18_000,
        amplitude: Int16 = 24
    ) -> Data {
        let sampleCount = sampleRate * durationSeconds
        let dataSize = sampleCount * MemoryLayout<Int16>.size
        var data = Data()
        data.reserveCapacity(44 + dataSize)

        func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLittleEndian(UInt32(16))
        appendLittleEndian(UInt16(1))
        appendLittleEndian(UInt16(1))
        appendLittleEndian(UInt32(sampleRate))
        appendLittleEndian(UInt32(sampleRate * 2))
        appendLittleEndian(UInt16(2))
        appendLittleEndian(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        appendLittleEndian(UInt32(dataSize))

        let twoPi = 2.0 * Double.pi
        for index in 0..<sampleCount {
            let sample = sin(twoPi * frequency * Double(index) / Double(sampleRate))
            appendLittleEndian(Int16((sample * Double(amplitude)).rounded()))
        }
        return data
    }

    static func containsAudibleEnergy(_ data: Data) -> Bool {
        guard data.count > 44 else { return false }
        let samples = data.dropFirst(44)
        return samples.contains { $0 != 0 }
    }
}
