import SwiftUI
import Shared
import SwiftStreamingMarkdown

struct ChatGeneratedImagePreview: View {
    let urlString: String
    @Environment(\.dismiss) private var dismiss
    @State private var dataImageState: ChatDataImageLoadState = .loading
    @State private var dragOffset: CGFloat = 0

    init(urlString: String, image: UIImage?) {
        self.urlString = urlString
        _dataImageState = State(initialValue: image.map(ChatDataImageLoadState.success) ?? .loading)
    }

    private var isDataURL: Bool { urlString.hasPrefix("data:") }
    private var url: URL? { IOSImageGenerationRepository.resolvedImageURL(from: urlString) }

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
            guard isDataURL else { return }
            if case .success = dataImageState { return }
            dataImageState = .loading
            let resolved = await ChatDataImageLoadState.resolve(urlString: urlString)
            guard !Task.isCancelled else { return }
            dataImageState = resolved
        }
    }

    @ViewBuilder
    private var previewShareButton: some View {
        if case .success(let image) = dataImageState {
            let sharedImage = Image(uiImage: image)
            ShareLink(item: sharedImage, preview: SharePreview("生成的图片", image: sharedImage)) {
                previewControlLabel(systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分享图片")
        } else if !isDataURL, let url {
            ShareLink(item: url) {
                previewControlLabel(systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分享图片")
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
        if isDataURL {
            switch dataImageState {
            case .success(let decodedDataImage):
                Image(uiImage: decodedDataImage)
                    .resizable()
                    .scaledToFit()
            case .loading:
                ProgressView()
                    .tint(.white)
            case .failure:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
        } else if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                case .empty:
                    ProgressView()
                        .tint(.white)
                @unknown default:
                    EmptyView()
                }
            }
        } else {
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
