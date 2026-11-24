import SwiftUI
import Shared
import SwiftStreamingMarkdown

struct ChatGeneratedImageTile: View {
    static let tilePixelLimit = 1200

    let urlString: String
    var display = ChatGeneratedImageRequestDisplay(toolInput: nil)
    var onModify: (String, String, String) -> Void = { _, _, _ in }
    var allowsModify: Bool = true
    var toolCallID: String? = nil
    @Environment(\.chatMessageEditingAllowed) private var messageEditingAllowed

    private var canModify: Bool { allowsModify && messageEditingAllowed }
    @State private var saveState: ChatGeneratedImagePhotoSaveState = .idle
    @State private var saveAlert: ChatGeneratedImageSaveAlert?
    @State private var imageState: ChatDataImageLoadState = .loading
    @State private var previewTarget: ChatGeneratedImagePreviewTarget?
    @State private var editTarget: ChatGeneratedImageEditTarget?

    private var isDataURL: Bool { urlString.hasPrefix("data:") }

    private var url: URL? {
        IOSImageGenerationRepository.resolvedImageURL(from: urlString)
    }

    var body: some View {
        let shareItem = ChatGeneratedImagePreview.shareItem(for: urlString)
        VStack(spacing: 6) {
            Group {
                switch imageState {
                case .success(let tileImage):
                    Image(uiImage: tileImage)
                        .resizable()
                        .scaledToFit()
                        .modifier(ChatGeneratedImageAppearModifier())
                case .loading:
                    ProgressView()
                        .tint(AmberTheme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure:
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(AmberTheme.accentRed)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ChatWidthDrivenAspectRatio(aspectRatio: display.aspectRatio))
            .contentShape(Rectangle())
            .onTapGesture {
                let placeholder: UIImage?
                if case .success(let loadedImage) = imageState {
                    placeholder = loadedImage
                } else {
                    placeholder = nil
                }
                previewTarget = ChatGeneratedImagePreviewTarget(urlString: urlString, image: placeholder)
            }
            .clipShape(RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
            .background(AmberTheme.surface2, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
            }
            .task(id: urlString) {
                imageState = .loading
                if isDataURL {
                    let resolved = await ChatDataImageLoadState.resolve(
                        urlString: urlString,
                        maxPixelSize: Self.tilePixelLimit
                    )
                    guard !Task.isCancelled else { return }
                    imageState = resolved
                } else {
                    do {
                        let loaded = try await ChatMediaImageLoader.shared.image(
                            urlString: urlString,
                            pixelLimit: Self.tilePixelLimit
                        )
                        guard !Task.isCancelled else { return }
                        imageState = .success(loaded)
                    } catch {
                        guard !Task.isCancelled else { return }
                        imageState = .failure
                    }
                }
            }

            if shareItem != nil {
                HStack(spacing: 6) {
                    switch shareItem {
                    case .url(let resolvedURL):
                        ShareLink(item: resolvedURL) {
                            generatedImageShareLabel
                        }
                        .accessibilityLabel("分享图片")
                        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.94, haptic: .lightImpact))
                    case .data(let payload):
                        if case .success(let tileImage) = imageState {
                            let previewThumbnail = Image(uiImage: tileImage)
                            ShareLink(item: payload, preview: SharePreview("生成的图片", image: previewThumbnail)) {
                                generatedImageShareLabel
                            }
                            .accessibilityLabel("分享图片")
                            .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.94, haptic: .lightImpact))
                        } else {
                            // 解码完成前先占住同尺寸的位置，避免出现时挤动保存/修改按钮。
                            generatedImageShareLabel
                                .opacity(0.4)
                                .accessibilityHidden(true)
                        }
                    case nil:
                        EmptyView()
                    }

                    Button {
                        saveImageToPhotos()
                    } label: {
                        ChatGeneratedImageActionLabel(
                            title: saveState.title,
                            systemImage: saveState.systemImage,
                            foreground: saveState == .saved ? AmberTheme.accentGreen : AmberTheme.accent,
                            fill: saveState == .saved ? AmberTheme.accentGreen.opacity(0.10) : AmberTheme.accentTint,
                            isWorking: saveState == .saving
                        )
                    }
                    .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.96, haptic: .lightImpact))
                    .disabled(saveState != .idle)
                    .accessibilityLabel("保存图片到相册")

                    Button {
                        editTarget = ChatGeneratedImageEditTarget(
                            urlString: urlString,
                            aspectRatio: display.aspectRatioTitle
                        )
                    } label: {
                        ChatGeneratedImageActionLabel(
                            title: "修改",
                            systemImage: "wand.and.stars",
                            foreground: canModify ? AmberTheme.accent : AmberTheme.muted,
                            fill: canModify ? AmberTheme.accentTint : AmberTheme.surface2
                        )
                    }
                    .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.96, haptic: .selection))
                    .disabled(!canModify)
                    .accessibilityLabel(canModify ? "修改图片" : (messageEditingAllowed ? "生成中，暂不可修改图片" : "只读会话中不可修改图片"))
                }
            }
        }
        .chatIslandToolAnchorHighlight(
            toolCallID: toolCallID,
            cornerRadius: AmberTheme.radiusXLarge
        )
        .fullScreenCover(item: $previewTarget) { target in
            ChatGeneratedImagePreview(urlString: target.urlString, image: target.image)
        }
        .sheet(item: $editTarget) { target in
            ChatGeneratedImageEditSheet { prompt in
                onModify(target.urlString, prompt, target.aspectRatio)
            }
        }
        .alert(item: $saveAlert) { alert in
            Alert(
                title: Text("保存失败"),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var generatedImageShareLabel: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AmberTheme.accent)
            .frame(width: 36, height: 28)
            .background(AmberTheme.accentTint, in: Capsule())
    }

    private func saveImageToPhotos() {
        guard saveState == .idle else { return }
        saveState = .saving
        Task {
            do {
                try await ChatGeneratedImagePhotoWriter.write(urlString)
                await MainActor.run {
                    saveState = .saved
                    AmberHaptics.trigger(.success)
                }
            } catch {
                await MainActor.run {
                    saveState = .idle
                    saveAlert = ChatGeneratedImageSaveAlert(message: error.localizedDescription)
                    AmberHaptics.trigger(.error)
                }
            }
        }
    }

}

private enum ChatGeneratedImagePhotoSaveState: Equatable {
    case idle
    case saving
    case saved

    var title: String {
        switch self {
        case .idle: "保存"
        case .saving: "保存中"
        case .saved: "已保存"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "square.and.arrow.down"
        case .saving: "arrow.triangle.2.circlepath"
        case .saved: "checkmark"
        }
    }
}

private struct ChatGeneratedImageSaveAlert: Identifiable {
    let id = UUID()
    let message: String
}

private struct ChatGeneratedImagePreviewTarget: Identifiable {
    let id = UUID()
    let urlString: String
    let image: UIImage?
}

private struct ChatGeneratedImageEditTarget: Identifiable {
    let id = UUID()
    let urlString: String
    let aspectRatio: String
}
