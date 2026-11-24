import SwiftUI
import Shared
import SwiftStreamingMarkdown
import UniformTypeIdentifiers

enum ChatGeneratedImageShareItem: Sendable {
    case url(URL)
    case data(ChatGeneratedImageSharePayload)
}

/// Losslessly exports the original encoded image bytes from a `data:` URL when shared,
/// never re-encoding a downsampled preview or card thumbnail.
struct ChatGeneratedImageSharePayload: Transferable, Sendable {
    let urlString: String
    let contentType: UTType

    init?(urlString: String) {
        guard urlString.hasPrefix("data:"), urlString.firstIndex(of: ",") != nil else {
            return nil
        }
        self.urlString = urlString
        self.contentType = Self.contentType(for: urlString)
    }

    func originalImageData() throws -> Data {
        guard let data = ChatDataImageLoadState.rawData(from: urlString), !data.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { try $0.originalImageData() }
            .exportingCondition { $0.contentType == .png }
        DataRepresentation(exportedContentType: .jpeg) { try $0.originalImageData() }
            .exportingCondition { $0.contentType == .jpeg }
        DataRepresentation(exportedContentType: .webP) { try $0.originalImageData() }
            .exportingCondition { $0.contentType == .webP }
        DataRepresentation(exportedContentType: .gif) { try $0.originalImageData() }
            .exportingCondition { $0.contentType == .gif }
        DataRepresentation(exportedContentType: .image) { try $0.originalImageData() }
    }

    private static func contentType(for urlString: String) -> UTType {
        guard let comma = urlString.firstIndex(of: ",") else { return .image }
        let header = urlString[..<comma]
        if let semi = header.firstIndex(of: ";") {
            let mime = String(header[header.index(header.startIndex, offsetBy: 5)..<semi]).lowercased()
            if let resolved = UTType(mimeType: mime), resolved.conforms(to: .image) {
                return resolved
            }
        }
        return .image
    }
}

struct ChatGeneratedImagePreview: View {
    static let previewPixelLimit = 2400

    let urlString: String
    private let placeholderImage: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var displayImageState: ChatDataImageLoadState = .loading
    @State private var dragOffset: CGFloat = 0

    init(urlString: String, image: UIImage?) {
        self.urlString = urlString
        self.placeholderImage = image
    }

    private var isDataURL: Bool { urlString.hasPrefix("data:") }
    private var url: URL? { IOSImageGenerationRepository.resolvedImageURL(from: urlString) }

    static func shareItem(for urlString: String) -> ChatGeneratedImageShareItem? {
        if urlString.hasPrefix("data:") {
            guard let payload = ChatGeneratedImageSharePayload(urlString: urlString) else { return nil }
            return .data(payload)
        }
        guard let resolvedURL = IOSImageGenerationRepository.resolvedImageURL(from: urlString) else {
            return nil
        }
        return .url(resolvedURL)
    }

    static func loadDisplayImage(urlString: String) async -> ChatDataImageLoadState {
        if urlString.hasPrefix("data:") {
            return await ChatDataImageLoadState.resolve(
                urlString: urlString,
                maxPixelSize: previewPixelLimit
            )
        }
        do {
            let loaded = try await ChatMediaImageLoader.shared.image(
                urlString: urlString,
                pixelLimit: previewPixelLimit
            )
            return .success(loaded)
        } catch {
            return .failure
        }
    }

    private var activePreviewUIImage: UIImage? {
        if case .success(let highRes) = displayImageState {
            return highRes
        }
        return placeholderImage
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            imageContent
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: dragOffset)
                .opacity(max(0.45, 1 - abs(dragOffset) / 360))
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            dragOffset = value.translation.height
                        }
                        .onEnded { value in
                            let shouldDismiss = abs(value.translation.height) > 140
                                || abs(value.predictedEndTranslation.height) > 220
                            if shouldDismiss {
                                dismiss()
                            } else {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )

            HStack(spacing: 12) {
                previewShareButton

                Button {
                    dismiss()
                } label: {
                    previewControlLabel(systemImage: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭大图")
            }
            // 36pt 圆放在 44pt 热区内，padding 各减 4，可见圆位置与改动前一致。
            .padding(.top, 16)
            .padding(.trailing, 12)
        }
        .task(id: urlString) {
            displayImageState = .loading
            let resolved = await Self.loadDisplayImage(urlString: urlString)
            guard !Task.isCancelled else { return }
            displayImageState = resolved
        }
    }

    @ViewBuilder
    private var previewShareButton: some View {
        switch Self.shareItem(for: urlString) {
        case .url(let resolvedURL):
            ShareLink(item: resolvedURL) {
                previewControlLabel(systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分享图片")
        case .data(let payload):
            if let previewImage = activePreviewUIImage {
                let previewThumbnail = Image(uiImage: previewImage)
                ShareLink(item: payload, preview: SharePreview("生成的图片", image: previewThumbnail)) {
                    previewControlLabel(systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("分享图片")
            } else {
                ShareLink(item: payload, preview: SharePreview("生成的图片")) {
                    previewControlLabel(systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("分享图片")
            }
        case nil:
            EmptyView()
        }
    }

    private func previewControlLabel(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.white.opacity(0.18), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var imageContent: some View {
        switch displayImageState {
        case .success(let highResImage):
            Image(uiImage: highResImage)
                .resizable()
                .scaledToFit()
        case .loading:
            if let placeholderImage {
                Image(uiImage: placeholderImage)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(.white)
            }
        case .failure:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

}

struct ChatGeneratedImageEditSheet: View {
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @FocusState private var focused: Bool

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("修改要求")
                    .font(.headline)
                    .foregroundStyle(AmberTheme.foreground)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $prompt)
                        .focused($focused)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 160)
                        .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
                        }

                    if prompt.isEmpty {
                        Text("例如：保留构图，把背景改成雪山，把服装改成蓝色。")
                            .font(.body)
                            .foregroundStyle(AmberTheme.muted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .navigationTitle("修改图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("生成") {
                        let value = trimmedPrompt
                        guard !value.isEmpty else { return }
                        onSubmit(value)
                        dismiss()
                    }
                    .disabled(trimmedPrompt.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .task {
            focused = true
        }
    }
}

/// Legacy tile retained for reference; the default timeline uses ChatMediaGallery
/// to keep loading, success and failure at the same size.
/// A user-sent image attachment, right-aligned and width-constrained like a chat bubble
/// (no share/save chrome). Sized to the image's real aspect ratio so the rounded clip
/// hugs the picture (no transparent letterbox). Decodes `data:` base64 URLs.
