import SwiftUI
import UIKit
import Shared
import PhotosUI

struct ComposerIconButton: View {
    enum Glyph {
        case system(String)
        case koboyo(ChatKoboyoMark)
    }

    let glyph: Glyph
    let accessibilityLabel: String
    var size: CGFloat = 34
    var symbolSize: CGFloat = 15
    var tint: Color = AmberTheme.foreground2
    var prominent = false
    let action: () -> Void

    init(
        systemImage: String,
        accessibilityLabel: String,
        size: CGFloat = 34,
        symbolSize: CGFloat = 15,
        tint: Color = AmberTheme.foreground2,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.glyph = .system(systemImage)
        self.accessibilityLabel = accessibilityLabel
        self.size = size
        self.symbolSize = symbolSize
        self.tint = tint
        self.prominent = prominent
        self.action = action
    }

    init(
        koboyo: ChatKoboyoMark,
        accessibilityLabel: String,
        size: CGFloat = 34,
        symbolSize: CGFloat = 15,
        tint: Color = AmberTheme.foreground2,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.glyph = .koboyo(koboyo)
        self.accessibilityLabel = accessibilityLabel
        self.size = size
        self.symbolSize = symbolSize
        self.tint = tint
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                switch glyph {
                case .system(let name):
                    Image(systemName: name)
                        .font(.system(size: symbolSize, weight: .semibold))
                case .koboyo(let mark):
                    ChatKoboyoIcon(mark, size: symbolSize)
                }
            }
            .foregroundStyle(prominent ? Color.white : tint)
            .frame(width: size, height: size)
            // 与输入条/发送键统一为原生 Liquid Glass:中性按钮用无色调玻璃,prominent 时染 tint。
            .modifier(ComposerDockCircleGlass(tint: prominent ? tint : nil))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Circle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.9, haptic: .selection))
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The composer is inset, but suggestions scroll through the screen edges.
struct ChatSuggestionStrip: View {
    let suggestions: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(suggestions.prefix(4).enumerated()), id: \.offset) { index, suggestion in
                    Button { onSelect(suggestion) } label: {
                        Text(suggestion)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.foreground2)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                    }
                    .buttonStyle(.plain)
                    .amberGlass(cornerRadius: 13, interactive: false)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("chat-suggestion-\(index)")
                }
            }
            .padding(.vertical, 3)
        }
        .contentMargins(.horizontal, ChatLayout.contentHorizontalInset, for: .scrollContent)
        .padding(.horizontal, -ChatLayout.contentHorizontalInset)
    }
}

struct ChatToolbarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var size: CGFloat
    var symbolSize: CGFloat
    /// Top-bar chrome stays theme ink, not accent — accent is for primary CTAs.
    var tint: Color = AmberTheme.foreground
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                circleGlass

                Image(systemName: systemImage)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Circle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.9, haptic: .lightImpact))
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var circleGlass: some View {
        if #available(iOS 26.0, *) {
            Circle()
                .fill(AmberTheme.glass.opacity(0.16))
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Circle()
                        .stroke(AmberTheme.border.opacity(0.28), lineWidth: 0.5)
                }
        }
    }
}

enum ComposerReasoningOption: String, CaseIterable, Identifiable {
    case off
    case auto
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var title: String {
        let key: String = switch self {
        case .off: "关闭"
        case .auto: "自动"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "极高"
        case .max: "最高"
        }
        return IOSAppLocalization.string(key, defaultValue: key)
    }

    var reasoningLevel: ReasoningLevel {
        switch self {
        case .off: .off
        case .auto: .auto_
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .xhigh: .xhigh
        case .max: .max
        }
    }

    init(reasoningLevel: ReasoningLevel) {
        switch reasoningLevel.name.lowercased() {
        case "auto": self = .auto
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "xhigh": self = .xhigh
        case "max": self = .max
        default: self = .off
        }
    }
}

struct ComposerThinkingPanel: View {
    @Binding var selectedOption: ComposerReasoningOption
    let options: [ComposerReasoningOption]
    let isAvailable: Bool
    let onPick: (ComposerReasoningOption) -> Void

    var body: some View {
        ComposerPopoverSurface(width: 180) {
            if isAvailable {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        ComposerPopoverDivider(index: index)

                        Button {
                            selectedOption = option
                            onPick(option)
                        } label: {
                            HStack {
                                Text(option.title)
                                    .font(.subheadline.weight(option == selectedOption ? .semibold : .regular))
                                    .foregroundStyle(option == selectedOption ? AmberTheme.accent : AmberTheme.foreground)

                                Spacer()

                                if option == selectedOption {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(AmberTheme.accent)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reasoning 未启用")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)

                    Text("当前模型未标记支持 Reasoning")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
        }
    }
}

// MARK: - Shared composer attachment controls (Chat + Council)

/// 输入胶囊左侧「+」：展开时旋转 45° 变 ×，解析中可换成 paperclip。
/// Chat / 模型议会共用同一触感与尺寸，避免两套 + 键。
struct ComposerAttachToggleButton: View {
    var isExpanded: Bool
    var isBusy: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isBusy ? "paperclip.circle.fill" : "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AmberTheme.muted)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
                .rotationEffect(.degrees(isExpanded ? 45 : 0))
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.88, haptic: .lightImpact))
        .disabled(isDisabled)
        .accessibilityLabel(isExpanded ? "关闭附件" : "添加附件")
    }
}

/// Liquid Glass 附件菜单：拍照 / 照片 / 文件（与 Chat 一致）。
struct ComposerAttachmentGlassPanel: View {
    var isDisabled: Bool = false
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void
    /// 选中某一行后由父级收起展开态。
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            row(title: "拍照", icon: "camera", action: onCamera)
            divider
            row(title: "照片", icon: "photo.on.rectangle", action: onPhotos)
            divider
            row(title: "文件", icon: "doc", action: onFiles)
        }
        .frame(width: 220)
        .clipShape(.rect(cornerRadius: 22))
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 2)
        .padding(.bottom, 2)
    }

    private var divider: some View {
        Divider().overlay(AmberTheme.borderSoft).padding(.leading, 52)
    }

    private func row(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.bouncy(duration: 0.36, extraBounce: 0.1)) { onDismiss() }
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 24)
                Text(IOSAppLocalization.string(title, defaultValue: title))
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(AmberTheme.foreground)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

/// 待发送图片：56pt 圆角缩略图 + 右上角删除（Chat 同款）。
struct ComposerPendingImageStrip: View {
    struct Item: Identifiable {
        let id: UUID
        let previewData: Data
    }

    let items: [Item]
    let onRemove: (UUID) -> Void
    /// Optional status under the strip (blocked / fallback / preparing).
    var status: ComposerAttachmentStatus? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        ComposerPendingImageThumbnail(item: item, onRemove: onRemove)
                    }
                }
                .padding(.horizontal, 2)
            }
            if let status {
                ComposerAttachmentStatusLabel(status: status)
            }
        }
    }
}

private struct ComposerPendingImageThumbnail: View {
    let item: ComposerPendingImageStrip.Item
    let onRemove: (UUID) -> Void
    @StateObject private var preview: ComposerPendingImagePreview

    init(item: ComposerPendingImageStrip.Item, onRemove: @escaping (UUID) -> Void) {
        self.item = item
        self.onRemove = onRemove
        _preview = StateObject(wrappedValue: ComposerPendingImagePreview(data: item.previewData))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let ui = preview.image {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
            }
            Button {
                onRemove(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .padding(3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除图片")
        }
    }
}

private final class ComposerPendingImagePreview: ObservableObject {
    let image: UIImage?

    init(data: Data) {
        image = UIImage(data: data)
    }
}

/// 待发送文件卡片：文件名 + 字节摘要 + 可选脚注（Chat 同款 thinMaterial）。
struct ComposerPendingFileCard: View {
    let fileName: String
    var byteSummary: String? = nil
    var isTruncated: Bool = false
    var footnote: String? = nil
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Label(fileName, systemImage: "doc.text")
                    .font(.caption)
                    .lineLimit(1)
                if let byteSummary {
                    Text(isTruncated ? "\(byteSummary) · 已截断" : byteSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除文件 \(fileName)")
            }
            if let footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

enum ComposerAttachmentStatus: Equatable {
    case muted(String, systemImage: String = "info.circle")
    case warning(String, systemImage: String = "exclamationmark.triangle.fill")
    case error(String)
    case preparing(String)
}

struct ComposerAttachmentStatusLabel: View {
    let status: ComposerAttachmentStatus

    var body: some View {
        switch status {
        case let .muted(message, systemImage):
            Label(message, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(2)
                .padding(.horizontal, 2)
        case let .warning(message, systemImage):
            Label(message, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(AmberTheme.accentAmber)
                .lineLimit(2)
                .padding(.horizontal, 2)
        case let .error(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .padding(.horizontal, 2)
        case let .preparing(message):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }
            .padding(.horizontal, 2)
        }
    }
}
