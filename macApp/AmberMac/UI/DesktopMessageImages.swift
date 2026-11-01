import AppKit
import SwiftUI

@MainActor
final class DesktopRemoteImageCache {
    static let shared = DesktopRemoteImageCache()
    private var memoryCache: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    func cachedImage(for raw: String) -> NSImage? {
        if let hit = memoryCache[raw] { return hit }
        if let decoded = Self.decodeImmediateImage(from: raw) {
            memoryCache[raw] = decoded
            return decoded
        }
        return nil
    }

    func loadImage(from raw: String) async -> NSImage? {
        if let immediate = cachedImage(for: raw) {
            return immediate
        }
        if let task = inFlight[raw] {
            return await task.value
        }
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }
        let task = Task<NSImage?, Never> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count <= 25 * 1024 * 1024,
                  let image = NSImage(data: data),
                  image.size.width > 0, image.size.height > 0 else {
                return nil
            }
            return image
        }
        inFlight[raw] = task
        let result = await task.value
        inFlight[raw] = nil
        if let result {
            memoryCache[raw] = result
        }
        return result
    }

    static func decodeImmediateImage(from raw: String) -> NSImage? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("data:image/"),
           let comma = trimmed.firstIndex(of: ",") {
            let base64 = String(trimmed[trimmed.index(after: comma)...])
            if let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
               let image = NSImage(data: data),
               image.size.width > 0, image.size.height > 0 {
                return image
            }
            return nil
        }
        if let url = URL(string: trimmed), url.isFileURL {
            if let data = try? Data(contentsOf: url),
               let image = NSImage(data: data),
               image.size.width > 0, image.size.height > 0 {
                return image
            }
            return nil
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") {
            let fileURL = URL(fileURLWithPath: trimmed)
            if let data = try? Data(contentsOf: fileURL),
               let image = NSImage(data: data),
               image.size.width > 0, image.size.height > 0 {
                return image
            }
        }
        return nil
    }

    @discardableResult
    func copyImageToPasteboard(from raw: String) -> Bool {
        guard let image = cachedImage(for: raw) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([image])
    }
}

struct DesktopMessageImageView: View {
    let image: DesktopMessageImage
    var maxWidth: CGFloat = 360
    var maxHeight: CGFloat = 240
    var alignment: Alignment = .leading

    init(image: DesktopMessageImage, maxWidth: CGFloat = 360, maxHeight: CGFloat = 240, alignment: Alignment = .leading) {
        self.image = image
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.alignment = alignment
    }

    init(source: DesktopMessageImage, maxWidth: CGFloat = 360, maxHeight: CGFloat = 240, alignment: Alignment = .leading) {
        self.init(image: source, maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
    }

    @State private var showingPreview = false
    @Environment(\.openURL) private var openURL

    static let cornerRadius: CGFloat = 12

    /// Computes the exact aspect-fitted display size so the rounded-corner clip shape and border
    /// hug all 4 edges of the rendered image rather than an oversized outer container.
    static func fittedSize(for imageSize: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let clampedMaxW = max(96, maxWidth)
        let clampedMaxH = max(72, maxHeight)
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: min(240, clampedMaxW), height: min(160, clampedMaxH))
        }
        let widthRatio = clampedMaxW / imageSize.width
        let heightRatio = clampedMaxH / imageSize.height
        let scale = min(1.0, min(widthRatio, heightRatio))
        let fittedW = max(min(clampedMaxW, 88), round(imageSize.width * scale))
        let fittedH = max(min(clampedMaxH, 66), round(imageSize.height * scale))
        return CGSize(width: fittedW, height: fittedH)
    }

    var body: some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 5) {
            Button {
                showingPreview = true
            } label: {
                DesktopMessageImageContent(
                    source: image.url,
                    maxWidth: maxWidth,
                    maxHeight: maxHeight
                )
            }
            .buttonStyle(.plain)
            .help(image.displayTitle)
            .accessibilityLabel(image.displayTitle)
            .accessibilityIdentifier("amber.chat.imageCard")

            HStack(spacing: 8) {
                if let name = (image.title ?? image.name)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty {
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let rawSource = image.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !rawSource.isEmpty,
                   let sourceURL = URL(string: rawSource) {
                    Button {
                        openURL(sourceURL)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "link")
                                .font(.system(size: 9, weight: .semibold))
                            Text(sourceURL.host ?? "来源")
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(DesktopTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .help(rawSource)
                }
            }
            .frame(maxWidth: maxWidth, alignment: alignment)
        }
        .sheet(isPresented: $showingPreview) {
            DesktopMessageImagePreview(images: [image], initialIndex: 0)
        }
    }
}

struct DesktopMessageImageGallery: View {
    let images: [DesktopMessageImage]
    var maxWidth: CGFloat = 520
    var alignment: Alignment = .leading

    @State private var selectedPreviewIndex: Int?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if images.count == 1, let single = images.first {
            DesktopMessageImageView(
                image: single,
                maxWidth: min(360, maxWidth),
                maxHeight: 240,
                alignment: alignment
            )
        } else if images.count > 1 {
            let columnsCount = images.count == 2 ? 2 : min(3, max(2, Int(maxWidth / 168)))
            let spacing: CGFloat = 8
            let tileWidth = max(110, min(200, floor((min(maxWidth, 540) - CGFloat(columnsCount - 1) * spacing) / CGFloat(columnsCount))))
            let tileHeight = round(tileWidth * 0.78)
            let rows = stride(from: 0, to: images.count, by: columnsCount).map { start in
                Array(images.enumerated().dropFirst(start).prefix(columnsCount))
            }

            VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: spacing) {
                        ForEach(row, id: \.offset) { index, item in
                            VStack(alignment: .leading, spacing: 4) {
                                Button {
                                    selectedPreviewIndex = index
                                } label: {
                                    DesktopMessageImageTile(
                                        source: item.url,
                                        width: tileWidth,
                                        height: tileHeight
                                    )
                                }
                                .buttonStyle(.plain)
                                .help(item.displayTitle)
                                .accessibilityLabel(item.displayTitle)
                                .accessibilityIdentifier("amber.chat.galleryTile.\(index)")

                                if let label = (item.title ?? item.name)?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !label.isEmpty {
                                    Text(label)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(DesktopTheme.inkSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(width: tileWidth, alignment: .leading)
                                }
                            }
                        }
                    }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { selectedPreviewIndex != nil },
                    set: { if !$0 { selectedPreviewIndex = nil } }
                )
            ) {
                DesktopMessageImagePreview(images: images, initialIndex: selectedPreviewIndex ?? 0)
            }
        }
    }
}

private struct DesktopMessageImageContent: View {
    let source: String
    var maxWidth: CGFloat = 360
    var maxHeight: CGFloat = 240

    @State private var loadedImage: NSImage?
    @State private var loadFailed = false

    private var activeImage: NSImage? {
        loadedImage ?? DesktopRemoteImageCache.shared.cachedImage(for: source)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesktopMessageImageView.cornerRadius, style: .continuous)
        Group {
            if let nsImage = activeImage {
                let pixelSize = Self.logicalImageSize(nsImage)
                let fitted = DesktopMessageImageView.fittedSize(
                    for: pixelSize,
                    maxWidth: maxWidth,
                    maxHeight: maxHeight
                )
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: fitted.width, height: fitted.height)
                    .clipped()
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(DesktopTheme.hairlineStrong, lineWidth: 1))
            } else if loadFailed {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    Text("图片无法显示")
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(DesktopTheme.card, in: shape)
                .overlay(shape.strokeBorder(DesktopTheme.hairlineStrong, lineWidth: 1))
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载图片…")
                        .font(.system(size: 12))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                }
                .frame(width: min(220, maxWidth), height: min(132, maxHeight))
                .background(DesktopTheme.card, in: shape)
                .overlay(shape.strokeBorder(DesktopTheme.hairlineStrong, lineWidth: 1))
            }
        }
        .task(id: source) {
            guard activeImage == nil else { return }
            if let remote = await DesktopRemoteImageCache.shared.loadImage(from: source) {
                loadedImage = remote
                loadFailed = false
            } else {
                loadFailed = true
            }
        }
    }

    private static func logicalImageSize(_ image: NSImage) -> CGSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            let w = image.size.width > 0 ? image.size.width : CGFloat(rep.pixelsWide)
            let h = image.size.height > 0 ? image.size.height : CGFloat(rep.pixelsHigh)
            return CGSize(width: w, height: h)
        }
        return image.size
    }
}

private struct DesktopMessageImageTile: View {
    let source: String
    let width: CGFloat
    let height: CGFloat

    @State private var loadedImage: NSImage?
    @State private var loadFailed = false

    private var activeImage: NSImage? {
        loadedImage ?? DesktopRemoteImageCache.shared.cachedImage(for: source)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesktopMessageImageView.cornerRadius, style: .continuous)
        ZStack {
            DesktopTheme.card
            if let nsImage = activeImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else if loadFailed {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                    Text("无法显示")
                        .font(.system(size: 11))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DesktopTheme.hairlineStrong, lineWidth: 1))
        .task(id: source) {
            guard activeImage == nil else { return }
            if let remote = await DesktopRemoteImageCache.shared.loadImage(from: source) {
                loadedImage = remote
                loadFailed = false
            } else {
                loadFailed = true
            }
        }
    }
}

private struct DesktopMessageImagePreview: View {
    let images: [DesktopMessageImage]
    @State private var currentIndex: Int
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(images: [DesktopMessageImage], initialIndex: Int) {
        self.images = images
        _currentIndex = State(initialValue: max(0, min(images.count - 1, initialIndex)))
    }

    private var currentImage: DesktopMessageImage {
        images[max(0, min(images.count - 1, currentIndex))]
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text(currentImage.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesktopTheme.ink)
                    .lineLimit(1)

                if images.count > 1 {
                    Text("\(currentIndex + 1) / \(images.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DesktopTheme.inkSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(DesktopTheme.paperDeep, in: Capsule())
                }

                Spacer()

                if let rawSource = currentImage.sourceURL, let url = URL(string: rawSource) {
                    Button("打开来源") {
                        openURL(url)
                    }
                }

                Button(copied ? "已复制" : "复制图片") {
                    if DesktopRemoteImageCache.shared.copyImageToPasteboard(from: currentImage.url) {
                        copied = true
                    }
                }

                if images.count > 1 {
                    Button {
                        currentIndex = max(0, currentIndex - 1)
                        copied = false
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(currentIndex == 0)

                    Button {
                        currentIndex = min(images.count - 1, currentIndex + 1)
                        copied = false
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(currentIndex >= images.count - 1)
                }

                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            DesktopMessageImageContent(
                source: currentImage.url,
                maxWidth: 780,
                maxHeight: 540
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 420)
        .background(DesktopTheme.paper)
    }
}
