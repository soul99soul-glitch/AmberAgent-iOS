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

/// Shares work while retaining cancellation ownership for each visible consumer.
actor ChatMediaImageRequests {
    private struct Flight {
        let id: UUID
        let task: Task<UIImage, Error>
        var waiters: Set<UUID>
    }
    private var flights: [String: Flight] = [:]

    func image(key: String, load: @escaping @Sendable () async throws -> UIImage) async throws -> UIImage {
        try Task.checkCancellation()
        let waiter = UUID()
        if flights[key] == nil {
            flights[key] = Flight(id: UUID(), task: Task { try await load() }, waiters: [])
        }
        flights[key]!.waiters.insert(waiter)
        let flight = flights[key]!
        return try await withTaskCancellationHandler {
            defer { release(key: key, flightID: flight.id, waiter: waiter) }
            let image = try await flight.task.value
            try Task.checkCancellation()
            return image
        } onCancel: {
            Task { await self.release(key: key, flightID: flight.id, waiter: waiter) }
        }
    }

    private func release(key: String, flightID: UUID, waiter: UUID) {
        guard var flight = flights[key], flight.id == flightID,
              flight.waiters.remove(waiter) != nil else { return }
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            flight.task.cancel()
        } else {
            flights[key] = flight
        }
    }
}

/// Stores display-sized thumbnails, never full videos. Disk work stays off the UI actor.
actor ChatMediaThumbnailDiskCache {
    static let shared = ChatMediaThumbnailDiskCache()
    private let directory: URL
    private let byteLimit: Int
    private var storedBytes: Int?

    init(directory: URL = URL.cachesDirectory.appendingPathComponent("chat-media-thumbnails-v1", isDirectory: true),
         byteLimit: Int = 128 * 1024 * 1024) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    private func file(for key: String) -> URL {
        directory.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).description + ".png")
    }

    func image(key: String, pixelLimit: Int) -> UIImage? {
        let url = file(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let image = try? ChatMediaImageLoader.decode(data: data, pixelLimit: pixelLimit) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    func store(_ image: UIImage, key: String) {
        guard let data = image.pngData(), data.count <= byteLimit else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if storedBytes == nil { storedBytes = try entries().reduce(0) { $0 + $1.size } }
            let url = file(for: key)
            let previous = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try data.write(to: url, options: .atomic)
            storedBytes = (storedBytes ?? 0) + data.count - previous
            if (storedBytes ?? 0) > byteLimit {
                let files = try entries().sorted { $0.date < $1.date }
                storedBytes = files.reduce(0) { $0 + $1.size }
                for entry in files where (storedBytes ?? 0) > byteLimit {
                    try manager.removeItem(at: entry.url)
                    storedBytes = (storedBytes ?? 0) - entry.size
                }
            }
        } catch {
            // Optional cache writes must not turn a successfully loaded image into an error.
            storedBytes = nil
        }
    }

    private func entries() throws -> [(url: URL, size: Int, date: Date)] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            .compactMap { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
    }
}

/// Decode at the requested display size off the main actor. The timeline is eager,
/// so callers load near the viewport instead of using onAppear as visibility.
actor ChatMediaImageLoader {
    static let shared = ChatMediaImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let requests = ChatMediaImageRequests()
    private let diskCache: ChatMediaThumbnailDiskCache

    init(diskCache: ChatMediaThumbnailDiskCache = .shared) {
        self.diskCache = diskCache
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func image(urlString: String, pixelLimit: Int) async throws -> UIImage {
        try Task.checkCancellation()
        let key = "image:\(SHA256.hash(data: Data(urlString.utf8)).description):\(pixelLimit)"
        if let image = cache.object(forKey: key as NSString) { return image }
        return try await requests.image(key: key) {
            try await self.load(urlString: urlString, pixelLimit: pixelLimit, key: key)
        }
    }

    private func load(urlString: String, pixelLimit: Int, key: String) async throws -> UIImage {
        // Local files can be replaced at the same path; they already live on disk.
        let persist = ChatMediaURL.external(urlString) != nil
        if persist, let image = await diskCache.image(key: key, pixelLimit: pixelLimit) {
            try Task.checkCancellation()
            cache.setObject(image, forKey: key as NSString, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
            return image
        }
        let image: UIImage
        if urlString.hasPrefix("data:image/"), let comma = urlString.firstIndex(of: ","),
           let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])) {
            image = try Self.decode(data: data, pixelLimit: pixelLimit)
        } else {
            guard let url = ChatGeneratedImageURL.resolvedImageURL(from: urlString),
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
            cache.setObject(image, forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
        }
        if persist { await diskCache.store(image, key: key) }
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

/// Preload one viewport ahead and keep decoded media until it is two viewports away.
/// Bounds are expressed in the media view's coordinates, independently for each scroll axis.
enum ChatMediaViewport: Equatable {
    case loading, retained, distant

    static func position(size: CGSize, vertical: CGRect?, horizontal: CGRect?) -> Self? {
        guard size.width > 0, size.height > 0 else { return nil }
        var positions: [Self] = []
        if let vertical {
            guard vertical.height > 0 else { return nil }
            positions.append(position(start: vertical.minY, end: vertical.maxY,
                                      viewportLength: vertical.height, itemLength: size.height))
        }
        if let horizontal {
            guard horizontal.width > 0 else { return nil }
            positions.append(position(start: horizontal.minX, end: horizontal.maxX,
                                      viewportLength: horizontal.width, itemLength: size.width))
        }
        if positions.contains(.distant) { return .distant }
        return positions.contains(.retained) ? .retained : .loading
    }

    private static func position(start: CGFloat, end: CGFloat, viewportLength: CGFloat, itemLength: CGFloat) -> Self {
        if end + viewportLength < 0 || start - viewportLength > itemLength {
            return end + 2 * viewportLength < 0 || start - 2 * viewportLength > itemLength ? .distant : .retained
        }
        return .loading
    }
}

struct ChatMediaImage: View {
    private struct Resource: Equatable {
        let url: String
        let pixelLimit: Int
    }
    private struct LoadRequest: Equatable {
        let resource: Resource
        let viewport: ChatMediaViewport
        let retry: Int
    }
    let url: String
    var contentMode: ContentMode = .fit
    var pixelLimit = 1000
    var showsStatus = true
    @State private var loaded: (resource: Resource, image: UIImage)?
    @State private var failure: Resource?
    @State private var viewport = ChatMediaViewport.retained
    @State private var retry = 0

    private var resource: Resource { Resource(url: url, pixelLimit: pixelLimit) }

    var body: some View {
        ZStack {
            AmberTheme.surface2
            if let loaded, loaded.resource == resource {
                Image(uiImage: loaded.image).resizable().aspectRatio(contentMode: contentMode)
            } else if failure == resource && showsStatus {
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
        .onGeometryChange(for: ChatMediaViewport?.self) { proxy in
            ChatMediaViewport.position(size: proxy.size,
                                      vertical: proxy.bounds(of: .scrollView(axis: .vertical)),
                                      horizontal: proxy.bounds(of: .scrollView(axis: .horizontal)))
        } action: { if let position = $0 { viewport = position } }
        .task(id: LoadRequest(resource: resource, viewport: viewport, retry: retry)) {
            if loaded?.resource != resource { loaded = nil }
            if failure != resource { failure = nil }
            guard viewport != .distant else { loaded = nil; return }
            guard viewport == .loading, loaded == nil else { return }
            failure = nil
            do {
                let loaded = try await ChatMediaImageLoader.shared.image(urlString: url, pixelLimit: pixelLimit)
                try Task.checkCancellation()
                self.loaded = (resource, loaded)
            } catch {
                guard !Task.isCancelled else { return }
                failure = resource
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

struct ChatMediaGalleryPreview: View {
    let items: [ChatMediaItem]
    @State private var selectedID: String
    private enum ShareContent {
        case url(URL)
        case image(UIImage)
        case failure
    }
    @State private var preparedShare: (url: String, content: ShareContent)?
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
                        shareButton(for: item)
                    }
                }
            }
            .task(id: items.first(where: { $0.id == selectedID })?.url) {
                guard let item = items.first(where: { $0.id == selectedID }) else { return }
                let content: ShareContent
                if item.url.hasPrefix("data:") {
                    if case .success(let image) = await ChatDataImageLoadState.resolve(urlString: item.url) {
                        content = .image(image)
                    } else {
                        content = .failure
                    }
                } else if let url = ChatGeneratedImageURL.resolvedImageURL(from: item.url) {
                    content = .url(url)
                } else {
                    content = .failure
                }
                guard !Task.isCancelled else { return }
                preparedShare = (item.url, content)
            }
            .alert("无法分享图片", isPresented: Binding(get: { shareFailure != nil }, set: { if !$0 { shareFailure = nil } })) {
                Button("好", role: .cancel) { shareFailure = nil }
            } message: { Text(shareFailure ?? "") }
        }
    }

    @ViewBuilder
    private func shareButton(for item: ChatMediaItem) -> some View {
        if let preparedShare, preparedShare.url == item.url {
            switch preparedShare.content {
            case .url(let url):
                ShareLink(item: url) { Label("分享图片", systemImage: "square.and.arrow.up") }
            case .image(let image):
                let sharedImage = Image(uiImage: image)
                ShareLink(item: sharedImage, preview: SharePreview(item.title.nilIfBlank ?? "图片", image: sharedImage)) {
                    Label("分享图片", systemImage: "square.and.arrow.up")
                }
            case .failure:
                Button("分享图片", systemImage: "square.and.arrow.up") {
                    shareFailure = "图片无法读取，请重新加载后重试。"
                }
            }
        } else {
            ProgressView().accessibilityLabel("正在准备图片分享")
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
