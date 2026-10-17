import SwiftUI
import ImageIO
import CryptoKit
@preconcurrency import Shared

enum ChatMediaURL {
    static func external(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}

struct ChatMediaItem: Identifiable, Equatable, Sendable, Decodable {
    let id: String
    let url: String
    var title: String = ""
    var sourceURL: String? = nil
    var width: Double? = nil
    var height: Double? = nil

    var aspectRatio: CGFloat {
        guard let width, let height, width.isFinite, height.isFinite, width > 0, height > 0 else { return 4 / 3 }
        return CGFloat(min(max(width / height, 0.5), 2))
    }

    static func image(_ part: UIMessagePart.Image, id: String) -> Self {
        let bridge = IosToolOutputJsonBridge.shared
        return Self(id: id, url: part.url,
                    title: bridge.metadataString(part: part, key: "app.amber.media.title") ?? "",
                    sourceURL: bridge.metadataString(part: part, key: "app.amber.media.sourceURL"))
    }

    static func toolImages(_ output: [UIMessagePart]) -> [Self] {
        var items: [Self] = []
        for (index, part) in output.enumerated() {
            if let image = part as? UIMessagePart.Image {
                items.append(.image(image, id: "image:\(index)"))
            } else if let raw = IosToolOutputJsonBridge.shared.metadataString(part: part, key: "app.amber.media.images"),
                      let data = raw.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([Self].self, from: data) {
                items.append(contentsOf: decoded)
            }
        }
        return items
    }
}

/// Decode at the requested display size off the main actor. The timeline is eager,
/// so callers load only within the viewport instead of using onAppear as visibility.
actor ChatMediaImageLoader {
    static let shared = ChatMediaImageLoader()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.totalCostLimit = 32 * 1024 * 1024 }

    func image(urlString: String, pixelLimit: Int) async throws -> UIImage {
        let key = "\(SHA256.hash(data: Data(urlString.utf8)).description):\(pixelLimit)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let image: UIImage
        if urlString.hasPrefix("data:image/"), let comma = urlString.firstIndex(of: ","),
           let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])) {
            image = try Self.decode(data: data, pixelLimit: pixelLimit)
        } else {
            guard let url = IOSImageGenerationRepository.resolvedImageURL(from: urlString),
                  ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.badURL) }
            if url.isFileURL {
                image = try Self.decode(file: url, pixelLimit: pixelLimit)
            } else {
                let (file, response) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: file) }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                image = try Self.decode(file: file, pixelLimit: pixelLimit)
            }
        }
        try Task.checkCancellation()
        if let cgImage = image.cgImage {
            cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        }
        return image
    }

    static func decode(data: Data, pixelLimit: Int) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        return try thumbnail(source, pixelLimit: pixelLimit)
    }

    private static func decode(file: URL, pixelLimit: Int) throws -> UIImage {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        return try thumbnail(source, pixelLimit: pixelLimit)
    }

    private static func thumbnail(_ source: CGImageSource, pixelLimit: Int) throws -> UIImage {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, pixelLimit)
        ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        return UIImage(cgImage: image)
    }
}

struct ChatMediaImage: View {
    private struct LoadRequest: Equatable {
        let url: String
        let visible: Bool
        let retry: Int
        let pixelLimit: Int
    }
    let url: String
    var contentMode: ContentMode = .fit
    var pixelLimit = 1000
    var showsStatus = true
    @State private var image: UIImage?
    @State private var failed = false
    @State private var visible = false
    @State private var retry = 0

    var body: some View {
        #if DEBUG
        let _ = print("MEDIA_BODY image=\(image != nil) failed=\(failed) visible=\(visible) bytes=\(url.utf8.count)")
        #endif
        ZStack {
            AmberTheme.surface2
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed && showsStatus {
                Button { retry += 1 } label: {
                    Label("重新加载", systemImage: "arrow.clockwise")
                        .font(.caption).padding(12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("图片加载失败，重新加载")
            } else if showsStatus {
                ProgressView().tint(AmberTheme.accent)
            }
        }
        .clipped()
        .onGeometryChange(for: Bool.self) { proxy in
            guard let viewport = proxy.bounds(of: .scrollView(axis: .vertical)) ?? proxy.bounds(of: .scrollView) else { return true }
            #if DEBUG
            print("MEDIA_VISIBILITY viewport=\(viewport) imageSize=\(proxy.size) intersects=\(viewport.intersects(CGRect(origin: .zero, size: proxy.size)))")
            #endif
            return viewport.intersects(CGRect(origin: .zero, size: proxy.size))
        } action: {
            #if DEBUG
            print("MEDIA_ACTION visible=\($0) bytes=\(url.utf8.count)")
            #endif
            visible = $0
        }
        .task(id: LoadRequest(url: url, visible: visible, retry: retry, pixelLimit: pixelLimit)) {
            #if DEBUG
            print("MEDIA_TASK start visible=\(visible) bytes=\(url.utf8.count) cancelled=\(Task.isCancelled)")
            #endif
            guard visible else { image = nil; return }
            image = nil
            failed = false
            do {
                let loaded = try await ChatMediaImageLoader.shared.image(urlString: url, pixelLimit: pixelLimit)
                #if DEBUG
                print("MEDIA_TASK loaded size=\(loaded.size) bytes=\(url.utf8.count) cancelled=\(Task.isCancelled)")
                #endif
                try Task.checkCancellation()
                image = loaded
            } catch {
                #if DEBUG
                print("MEDIA_TASK failure bytes=\(url.utf8.count) cancelled=\(Task.isCancelled) error=\(String(describing: type(of: error)))")
                #endif
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}

struct ChatMediaGallery: View {
    let items: [ChatMediaItem]
    var compact = false
    @State private var selected: ChatMediaItem?

    var body: some View {
        Group {
            if items.count == 1, let item = items.first {
                tile(item)
                    .frame(maxWidth: compact ? 220 : .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(items) { item in tile(item).frame(width: 220) }
                    }
                }
            }
        }
        .fullScreenCover(item: $selected) { item in
            ChatMediaGalleryPreview(items: items, initialID: item.id)
        }
    }

    private func tile(_ item: ChatMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ChatMediaImage(url: item.url)
                .modifier(ChatWidthDrivenAspectRatio(aspectRatio: items.count > 1 ? 4 / 3 : item.aspectRatio))
                .clipShape(RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge))
                .contentShape(Rectangle())
                .onTapGesture { selected = item }
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: "查看大图") { selected = item }
                .accessibilityLabel(item.title.isEmpty ? "图片" : item.title)
                .accessibilityAddTraits(.isButton)
            if !item.title.isEmpty || item.sourceURL != nil {
                if let source = item.sourceURL, let url = ChatMediaURL.external(source) {
                    Link(destination: url) {
                        Label(item.title.isEmpty ? (url.host ?? "查看来源") : item.title, systemImage: "arrow.up.right")
                            .lineLimit(1)
                    }
                    .font(.caption).foregroundStyle(AmberTheme.muted)
                } else {
                    Text(item.title).font(.caption).foregroundStyle(AmberTheme.muted).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private final class ChatToolMediaProjection: ObservableObject {
    @Published private(set) var items: [ChatMediaItem]
    private var toolIdentity: ObjectIdentifier

    init(tool: UIMessagePart.Tool) {
        toolIdentity = ObjectIdentifier(tool)
        items = ChatMediaItem.toolImages(tool.output)
    }

    func update(tool: UIMessagePart.Tool) {
        guard toolIdentity != ObjectIdentifier(tool) else { return }
        toolIdentity = ObjectIdentifier(tool)
        let next = ChatMediaItem.toolImages(tool.output)
        if next != items { items = next }
    }
}

struct ChatToolMediaGallery: View, @MainActor Equatable {
    let tool: UIMessagePart.Tool
    @StateObject private var projection: ChatToolMediaProjection

    init(tool: UIMessagePart.Tool) {
        self.tool = tool
        // StateObject evaluates this seed once per row, before its first layout.
        _projection = StateObject(wrappedValue: ChatToolMediaProjection(tool: tool))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.tool === rhs.tool }

    var body: some View {
        VStack(spacing: 0) {
            if !projection.items.isEmpty { ChatMediaGallery(items: projection.items) }
        }
        .task(id: ObjectIdentifier(tool)) {
            projection.update(tool: tool)
        }
    }
}

private struct ChatMediaGalleryPreview: View {
    let items: [ChatMediaItem]
    @State private var selectedID: String
    @State private var preparingShare = false
    @State private var shareFailure: String?
    @Environment(\.dismiss) private var dismiss

    init(items: [ChatMediaItem], initialID: String) {
        self.items = items
        _selectedID = State(initialValue: initialID)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedID) {
                ForEach(items) { item in
                    ChatMediaPreviewPage(url: item.url)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
            .background(AmberTheme.surface2)
            .navigationTitle("\((items.firstIndex { $0.id == selectedID } ?? 0) + 1) / \(items.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭", systemImage: "xmark") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let item = items.first(where: { $0.id == selectedID }) {
                        if let source = item.sourceURL, let url = ChatMediaURL.external(source) {
                            Link("来源", destination: url)
                        }
                        Button("分享图片", systemImage: "square.and.arrow.up") { share(item) }
                            .disabled(preparingShare)
                    }
                }
            }
            .alert("无法分享图片", isPresented: Binding(get: { shareFailure != nil }, set: { if !$0 { shareFailure = nil } })) {
                Button("好", role: .cancel) { shareFailure = nil }
            } message: { Text(shareFailure ?? "") }
        }
    }

    private func share(_ item: ChatMediaItem) {
        guard IOSShareActivity.shared.begin() else {
            shareFailure = IOSConversationExporter.busyMessage
            return
        }
        preparingShare = true
        Task { @MainActor in
            defer { preparingShare = false; IOSShareActivity.shared.end() }
            let content: Any
            if item.url.hasPrefix("data:") {
                guard case .success(let image) = await ChatDataImageLoadState.resolve(urlString: item.url) else {
                    shareFailure = "图片无法读取，请重新加载后重试。"
                    return
                }
                content = image
            } else if let url = IOSImageGenerationRepository.resolvedImageURL(from: item.url) {
                content = url
            } else {
                shareFailure = "图片地址不可用。"
                return
            }
            if !(await IOSShareSheet.present([content])) { shareFailure = "当前无法弹出分享面板，请稍后重试。" }
        }
    }
}

private struct ChatMediaPreviewPage: View {
    let url: String
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                ChatMediaImage(url: url, pixelLimit: 2400)
                    .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                    .scaleEffect(pinch)
                    .gesture(MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { zoom = min(max(zoom * $0.magnification, 1), 4) })
                    .onTapGesture(count: 2) { zoom = zoom > 1 ? 1 : 2 }
            }
            .scrollIndicators(.hidden)
        }
    }
}
