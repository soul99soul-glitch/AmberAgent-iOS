import AppKit
import AVFoundation
import AVKit
import Observation
import SwiftUI

enum DesktopMediaURLResolver {
    static func resolve(_ raw: String, defaultExtension: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("data:") {
            return resolveDataURL(trimmed, defaultExtension: defaultExtension)
        }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file"].contains(scheme) {
            return url
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") {
            return URL(fileURLWithPath: trimmed)
        }
        return URL(string: trimmed)
    }

    private static func resolveDataURL(_ raw: String, defaultExtension: String) -> URL? {
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        let header = String(raw[..<comma]).lowercased()
        guard header.contains(";base64") else { return nil }
        let base64 = String(raw[raw.index(after: comma)...])
        guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
            return nil
        }
        let ext: String = {
            if header.contains("audio/mpeg") || header.contains("audio/mp3") { return "mp3" }
            if header.contains("audio/mp4") || header.contains("audio/m4a") || header.contains("audio/aac") { return "m4a" }
            if header.contains("audio/wav") || header.contains("audio/x-wav") { return "wav" }
            if header.contains("audio/ogg") { return "ogg" }
            if header.contains("audio/flac") { return "flac" }
            if header.contains("video/quicktime") { return "mov" }
            if header.contains("video/webm") { return "webm" }
            if header.contains("video/mp4") || header.contains("video/x-m4v") { return "mp4" }
            return defaultExtension
        }()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amber-media-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = raw.utf8.reduce(into: UInt64(1469598103934665603)) { acc, byte in
            acc = (acc ^ UInt64(byte)) &* 1099511628211
        }
        let fileURL = dir.appendingPathComponent("media-\(String(hash, radix: 16)).\(ext)")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return fileURL
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}

@MainActor
private final class DesktopVideoMetadataCache {
    static let shared = DesktopVideoMetadataCache()
    struct Entry {
        let poster: NSImage?
        let duration: Double?
    }
    private var entries: [String: Entry] = [:]

    func get(_ key: String) -> Entry? { entries[key] }
    func set(_ key: String, entry: Entry) { entries[key] = entry }
}

struct DesktopAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

struct DesktopVideoCard: View {
    let video: DesktopVideoMedia
    var maxWidth: CGFloat = 380

    @State private var posterImage: NSImage?
    @State private var durationSeconds: Double?
    @State private var inlinePlayer: AVPlayer?
    @State private var showingModalSheet = false
    @Environment(\.openURL) private var openURL

    private var cardWidth: CGFloat {
        max(220, min(380, maxWidth))
    }

    private var cardHeight: CGFloat {
        round(cardWidth * 9.0 / 16.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.13, green: 0.12, blue: 0.11),
                                Color(red: 0.20, green: 0.17, blue: 0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if let inlinePlayer {
                    DesktopAVPlayerView(player: inlinePlayer)
                } else {
                    if let posterImage {
                        Image(nsImage: posterImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: cardWidth, height: cardHeight)
                            .clipped()
                    } else {
                        Image(systemName: "film.stack")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.28))
                    }

                    LinearGradient(
                        colors: [.black.opacity(0.28), .clear, .black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    Button {
                        startInlinePlayback()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.black.opacity(0.58))
                                .frame(width: 52, height: 52)
                                .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                            Image(systemName: "play.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .offset(x: 1.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("播放视频")
                    .accessibilityLabel("播放视频 \(video.displayTitle)")

                    VStack {
                        HStack(spacing: 6) {
                            Label("视频", systemImage: "video.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.52), in: Capsule())

                            Spacer()

                            if let durationSeconds, durationSeconds > 0 {
                                Text(DesktopMediaURLResolver.formatDuration(durationSeconds))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.52), in: Capsule())
                            }
                        }
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipped()

            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesktopTheme.accent)

                Text(video.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesktopTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if inlinePlayer != nil {
                    Button {
                        stopInlinePlayback()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("停止内嵌播放")
                }

                Button {
                    stopInlinePlayback()
                    showingModalSheet = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("大窗播放")
                .accessibilityLabel("大窗播放 \(video.displayTitle)")

                if let rawSource = video.sourceURL ?? (video.url.lowercased().hasPrefix("http") ? video.url : nil),
                   let externalURL = URL(string: rawSource) {
                    Button {
                        openURL(externalURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DesktopTheme.inkSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("在浏览器中打开来源")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: cardWidth)
            .background(DesktopTheme.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DesktopTheme.hairlineStrong, lineWidth: 1)
        )
        .task(id: video.url) {
            await loadMetadataIfNeeded()
        }
        .onDisappear {
            stopInlinePlayback()
        }
        .sheet(isPresented: $showingModalSheet) {
            DesktopVideoPlayerSheet(video: video)
        }
    }

    private func startInlinePlayback() {
        guard let url = DesktopMediaURLResolver.resolve(video.url, defaultExtension: "mp4") else { return }
        stopInlinePlayback()
        let player = AVPlayer(url: url)
        inlinePlayer = player
        player.play()
    }

    private func stopInlinePlayback() {
        inlinePlayer?.pause()
        inlinePlayer?.replaceCurrentItem(with: nil)
        inlinePlayer = nil
    }

    private func loadMetadataIfNeeded() async {
        let cacheKey = "\(video.url)|\(video.posterURL ?? "")"
        if let cached = DesktopVideoMetadataCache.shared.get(cacheKey) {
            posterImage = cached.poster
            durationSeconds = cached.duration
            return
        }

        if let posterURL = video.posterURL,
           let image = await DesktopRemoteImageCache.shared.loadImage(from: posterURL) {
            posterImage = image
        }

        guard let resolved = DesktopMediaURLResolver.resolve(video.url, defaultExtension: "mp4") else { return }
        let extracted: (NSImage?, Double?) = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: resolved)
            let durationSec: Double? = await {
                guard let duration = try? await asset.load(.duration) else { return nil }
                let sec = CMTimeGetSeconds(duration)
                return (sec.isFinite && sec > 0) ? sec : nil
            }()
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 760, height: 440)
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return (NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), durationSec)
            }
            if let cgImage0 = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                return (NSImage(cgImage: cgImage0, size: NSSize(width: cgImage0.width, height: cgImage0.height)), durationSec)
            }
            return (nil, durationSec)
        }.value

        if posterImage == nil, let frame = extracted.0 {
            posterImage = frame
        }
        if let dur = extracted.1 {
            durationSeconds = dur
        }
        DesktopVideoMetadataCache.shared.set(
            cacheKey,
            entry: .init(poster: posterImage, duration: durationSeconds)
        )
    }
}

struct DesktopVideoPlayerSheet: View {
    let video: DesktopVideoMedia
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(video.displayTitle, systemImage: "film")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesktopTheme.ink)
                    .lineLimit(1)
                Spacer()
                Button("关闭") {
                    cleanup()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(DesktopTheme.card)

            Divider()

            ZStack {
                Color.black
                if let player {
                    DesktopAVPlayerView(player: player)
                } else {
                    Text("无法加载视频地址")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(minWidth: 720, minHeight: 440)
        }
        .frame(width: 820, height: 520)
        .onAppear {
            if let url = DesktopMediaURLResolver.resolve(video.url, defaultExtension: "mp4") {
                let instance = AVPlayer(url: url)
                player = instance
                instance.play()
            }
        }
        .onDisappear {
            cleanup()
        }
    }

    private func cleanup() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

@MainActor
@Observable
final class DesktopAudioPlayerController {
    var isPlaying = false
    var isLoading = false
    var currentTime: Double = 0
    var duration: Double = 0
    var hasFailed = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadedURLString: String?

    func toggle(urlString: String) {
        if loadedURLString != urlString || player == nil || hasFailed {
            prepareAndPlay(urlString: urlString)
            return
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.15 {
                player.seek(to: .zero)
                currentTime = 0
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to fraction: Double) {
        guard let player, duration > 0 else { return }
        let target = max(0, min(duration, duration * fraction))
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func prepareAndPlay(urlString: String) {
        stopAndCleanup()
        guard let resolved = DesktopMediaURLResolver.resolve(urlString, defaultExtension: "mp3") else {
            hasFailed = true
            return
        }
        loadedURLString = urlString
        hasFailed = false
        isLoading = true

        let item = AVPlayerItem(url: resolved)
        let instance = AVPlayer(playerItem: item)
        player = instance

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = instance.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let sec = CMTimeGetSeconds(time)
                if sec.isFinite, sec >= 0 {
                    self.currentTime = sec
                }
                if let itemDuration = self.player?.currentItem?.duration {
                    let total = CMTimeGetSeconds(itemDuration)
                    if total.isFinite, total > 0 {
                        self.duration = total
                    }
                }
                if self.player?.currentItem?.status == .failed {
                    self.hasFailed = true
                    self.isPlaying = false
                    self.isLoading = false
                } else if self.player?.timeControlStatus == .playing {
                    self.isLoading = false
                    self.isPlaying = true
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.isLoading = false
                self.currentTime = self.duration
            }
        }

        instance.play()
        isPlaying = true
        isLoading = false
    }

    func stopAndCleanup() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
        isLoading = false
    }
}

struct DesktopAudioCard: View {
    let audio: DesktopAudioMedia
    var maxWidth: CGFloat = 360

    @State private var controller = DesktopAudioPlayerController()

    private var cardWidth: CGFloat {
        max(220, min(360, maxWidth))
    }

    private var progressFraction: Double {
        guard controller.duration > 0 else { return 0 }
        return max(0, min(1, controller.currentTime / controller.duration))
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                controller.toggle(urlString: audio.url)
            } label: {
                ZStack {
                    Circle()
                        .fill(controller.hasFailed ? DesktopTheme.danger.opacity(0.16) : DesktopTheme.accent)
                        .frame(width: 36, height: 36)

                    if controller.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: buttonIconName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(controller.hasFailed ? DesktopTheme.danger : .white)
                            .offset(x: (!controller.isPlaying && !controller.hasFailed) ? 1 : 0)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(controller.isPlaying ? "暂停音频" : "播放音频")
            .accessibilityLabel(controller.isPlaying ? "暂停 \(audio.displayTitle)" : "播放 \(audio.displayTitle)")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesktopTheme.accent)
                    Text(audio.displayTitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DesktopTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(timeLabel)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                }

                GeometryReader { geo in
                    let width = max(1, geo.size.width)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(DesktopTheme.paperDeep)
                            .frame(height: 5)
                        Capsule()
                            .fill(DesktopTheme.accent)
                            .frame(width: max(5, width * progressFraction), height: 5)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let fraction = max(0, min(1, Double(value.location.x / width)))
                                controller.seek(to: fraction)
                            }
                    )
                }
                .frame(height: 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: cardWidth)
        .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DesktopTheme.hairlineStrong, lineWidth: 1)
        )
        .onDisappear {
            controller.stopAndCleanup()
        }
    }

    private var buttonIconName: String {
        if controller.hasFailed { return "arrow.clockwise" }
        return controller.isPlaying ? "pause.fill" : "play.fill"
    }

    private var timeLabel: String {
        if controller.hasFailed { return "加载失败" }
        let current = DesktopMediaURLResolver.formatDuration(controller.currentTime)
        if controller.duration > 0 {
            return "\(current) / \(DesktopMediaURLResolver.formatDuration(controller.duration))"
        }
        return current
    }
}
