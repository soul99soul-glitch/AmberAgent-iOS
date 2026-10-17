import AVKit
import Observation
import SwiftUI
@preconcurrency import Shared

struct ChatVideoDescriptor: Equatable, Identifiable, Sendable {
    let id: String
    let url: String
    var title: String = "视频"
    var posterURL: String? = nil
    var sourceURL: String? = nil
    var width: Double? = nil
    var height: Double? = nil
    var duration: Double? = nil

    init(id: String, url: String, title: String = "视频", posterURL: String? = nil,
         sourceURL: String? = nil, width: Double? = nil, height: Double? = nil, duration: Double? = nil) {
        self.id = id; self.url = url; self.title = title; self.posterURL = posterURL
        self.sourceURL = sourceURL; self.width = width; self.height = height; self.duration = duration
    }

    init(part: UIMessagePart.Video, id: String) {
        let bridge = IosToolOutputJsonBridge.shared
        func value(_ key: String) -> String? { bridge.metadataString(part: part, key: "app.amber.media.\(key)") }
        self.init(id: id, url: part.url, title: value("title") ?? "视频", posterURL: value("posterURL"),
                  sourceURL: value("sourceURL"), width: value("width").flatMap(Double.init),
                  height: value("height").flatMap(Double.init), duration: value("duration").flatMap(Double.init))
    }

    var aspectRatio: CGFloat {
        guard let width, let height, width.isFinite, height.isFinite, width > 0, height > 0 else { return 16 / 9 }
        return CGFloat(min(max(width / height, 0.5), 2))
    }

    var playbackURL: URL? {
        guard let result = URL(string: url), let scheme = result.scheme?.lowercased() else { return nil }
        if scheme == "file" { return result }
        return ["https", "http"].contains(scheme) && result.host != nil ? result : nil
    }

    var durationLabel: String? {
        guard let duration, duration.isFinite, duration >= 0, duration < Double(Int.max) else { return nil }
        let seconds = Int(duration)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct ChatVideoCard: View {
    let video: ChatVideoDescriptor
    @State private var selected: ChatVideoDescriptor?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { selected = video } label: {
                ZStack {
                    AmberTheme.surface2
                    if let poster = video.posterURL {
                        ChatMediaImage(url: poster, contentMode: .fill, showsStatus: false)
                            .allowsHitTesting(false)
                    }
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 52))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.5))
                    if let duration = video.durationLabel {
                        VStack {
                            Spacer()
                            HStack { Spacer(); Text(duration).font(.caption.monospacedDigit())
                                    .padding(5).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5)) }
                        }
                        .foregroundStyle(.white).padding(10)
                    }
                }
                .modifier(ChatWidthDrivenAspectRatio(aspectRatio: video.aspectRatio))
                .clipShape(RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge))
            }
            .buttonStyle(.plain)
            .disabled(video.playbackURL == nil)
            .accessibilityLabel("播放\(video.title)")
            Text(video.playbackURL == nil ? "视频地址不可用" : video.title)
                .font(.caption).foregroundStyle(AmberTheme.muted).lineLimit(2)
            if let source = video.sourceURL, let url = ChatMediaURL.external(source) {
                Link(destination: url) { Label("查看来源", systemImage: "arrow.up.right") }
                    .font(.caption).foregroundStyle(AmberTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fullScreenCover(item: $selected) { video in ChatVideoPlayerScreen(video: video) }
    }
}

@MainActor @Observable
final class ChatVideoPlayback {
    private(set) var player: AVPlayer?
    private(set) var failure: String?
    private var statusObservation: NSKeyValueObservation?
    private var failureObservation: NSObjectProtocol?
    private var preparationID: UUID?
    private var audioOwner: String?
    private let audio: AudioDependencies

    @MainActor struct AudioDependencies {
        let suspend: (String) -> Void
        let resume: (String) -> Void
        let activate: () throws -> Void
        let deactivate: () -> Void
        let run: BackgroundAudioKeepAlive.BlockingAudioWorkRunner

        static let live = Self(
            suspend: { BackgroundAudioKeepAlive.shared.suspend(for: $0) },
            resume: { BackgroundAudioKeepAlive.shared.resume(for: $0) },
            activate: ChatVideoPlayback.activateMovieAudio,
            deactivate: ChatVideoPlayback.deactivateMovieAudio,
            run: BackgroundAudioKeepAlive.defaultBlockingAudioWorkRunner
        )
    }

    private nonisolated static func activateMovieAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
        BackgroundAudioKeepAlive.recordMediaSessionActivation()
    }

    private nonisolated static func deactivateMovieAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    init(audio: AudioDependencies = .live) {
        self.audio = audio
    }

    func prepare(url: URL) async {
        stop()
        failure = nil
        let attempt = UUID()
        preparationID = attempt
        do {
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else { throw URLError(.cannotDecodeContentData) }
            try Task.checkCancellation()
            guard preparationID == attempt else { return }
            let owner = "video-\(attempt.uuidString)"
            audioOwner = owner
            audio.suspend(owner)
            // Use keep-alive's serial queue so its pending teardown finishes
            // before movie playback takes over the shared audio session.
            let activateAudio = audio.activate
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audio.run({
                    do {
                        try activateAudio()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }, {})
            }
            try Task.checkCancellation()
            guard preparationID == attempt else { return }
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            self.player = player
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let reason = item.error?.localizedDescription ?? "视频暂时无法播放"
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, self.player?.currentItem === item else { return }
                    self.stop()
                    self.failure = reason
                }
            }
            failureObservation = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] notification in
                let reason = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                    ?? "视频播放中断，请重试"
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, self.player?.currentItem === item else { return }
                    self.stop()
                    self.failure = reason
                }
            }
            player.play()
        } catch {
            guard preparationID == attempt else { return }
            stop()
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }

    func stop() {
        preparationID = nil
        statusObservation = nil
        if let failureObservation { NotificationCenter.default.removeObserver(failureObservation) }
        failureObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        guard let owner = audioOwner else { return }
        audioOwner = nil
        let resumeAudio = audio.resume
        audio.run(audio.deactivate) { resumeAudio(owner) }
    }
}

struct ChatVideoPlayerScreen: View {
    let video: ChatVideoDescriptor
    @State private var playback = ChatVideoPlayback()
    @State private var retry = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let failure = playback.failure {
                VStack(spacing: 16) {
                    Text("视频无法播放").font(.headline)
                    Text(failure).font(.subheadline).multilineTextAlignment(.center)
                    Button("重试") { retry += 1 }.buttonStyle(.bordered)
                    if let source = video.sourceURL, let url = ChatMediaURL.external(source) {
                        Link("打开来源", destination: url)
                    }
                }
                .foregroundStyle(.white).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let player = playback.player {
                ChatSystemVideoPlayer(player: player).ignoresSafeArea()
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .tint(.white).padding(16).accessibilityLabel("关闭视频")
        }
        .task(id: retry) {
            guard let url = video.playbackURL else { return }
            await playback.prepare(url: url)
        }
        .onDisappear { playback.stop() }
    }
}

private struct ChatSystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }
}
