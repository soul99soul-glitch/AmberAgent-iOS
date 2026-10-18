import SwiftUI
import Shared

struct ProviderSegmentedControl: View {
    @Binding var selection: ProviderDetailTab
    @Namespace private var selectionIndicator

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ProviderDetailTab.allCases) { tab in
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        selection = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == tab ? AmberTheme.foreground : AmberTheme.foreground2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(AmberTheme.background.opacity(0.92))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .stroke(AmberTheme.borderSoft.opacity(0.9), lineWidth: 0.5)
                                    }
                                    .matchedGeometryEffect(id: "selection", in: selectionIndicator)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            AmberTheme.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
    }
}

struct ProviderModelEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProviderModelDraft
    let onSave: (ProviderModelDraft) -> Bool

    init(draft: ProviderModelDraft, onSave: @escaping (ProviderModelDraft) -> Bool) {
        self._draft = State(initialValue: draft)
        self.onSave = onSave
    }

    // Custom segmented control (Kotlin `ModelType` isn't Hashable in Swift, so a
    // SwiftUI Picker can't bind to it; compare with `==` instead).
    @ViewBuilder
    private func modelTypeButton(_ title: String, _ type: ModelType) -> some View {
        let selected = draft.type == type
        Button {
            draft.type = type
        } label: {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? AmberTheme.foreground : AmberTheme.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    selected ? AmberTheme.surface : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func inputModalityButton(_ title: String, _ modality: Modality) -> some View {
        let selected = draft.inputModalities.contains(modality)
        Button {
            if selected {
                guard draft.inputModalities.count > 1 else { return }
                draft.inputModalities.removeAll { $0 == modality }
            } else {
                draft.inputModalities.append(modality)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                Text(title)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? AmberTheme.foreground : AmberTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        AmberSectionLabel(text: "模型")
                        AmberFormGroup {
                            ProviderEditableTextFieldRow(
                                title: "Model ID",
                                text: $draft.modelId,
                                placeholder: "例如 deepseek-chat",
                                monospace: true
                            )
                            ProviderDetailDivider()
                            ProviderEditableTextFieldRow(
                                title: "显示名称",
                                text: $draft.displayName,
                                placeholder: "留空时使用 Model ID"
                            )
                            ProviderDetailDivider()
                            VStack(alignment: .leading, spacing: 8) {
                                Text("类型")
                                    .font(.subheadline)
                                    .foregroundStyle(AmberTheme.muted)
                                HStack(spacing: 0) {
                                    modelTypeButton("聊天", .chat)
                                    modelTypeButton("生图", .image)
                                    modelTypeButton("嵌入", .embedding)
                                }
                                .padding(3)
                                .background(
                                    AmberTheme.surface2.opacity(0.88),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            ProviderDetailDivider()
                            VStack(alignment: .leading, spacing: 8) {
                                Text(IOSAppLocalization.string("输入能力", defaultValue: "输入能力"))
                                    .font(.subheadline)
                                    .foregroundStyle(AmberTheme.muted)
                                VStack(spacing: 8) {
                                    HStack(spacing: 12) {
                                        inputModalityButton(
                                            IOSAppLocalization.string("文本", defaultValue: "文本"),
                                            .text
                                        )
                                        inputModalityButton(
                                            IOSAppLocalization.string("图片", defaultValue: "图片"),
                                            .image
                                        )
                                    }
                                    HStack(spacing: 12) {
                                        inputModalityButton(
                                            IOSAppLocalization.string("视频", defaultValue: "视频"),
                                            .video
                                        )
                                        inputModalityButton(
                                            IOSAppLocalization.string("音频", defaultValue: "音频"),
                                            .audio
                                        )
                                    }
                                }
                                Text(IOSAppLocalization.string(
                                    "当前附件仅支持图片；视频和音频仅记录模型能力。",
                                    defaultValue: "当前附件仅支持图片；视频和音频仅记录模型能力。"
                                ))
                                    .font(.caption)
                                    .foregroundStyle(AmberTheme.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            ProviderDetailDivider()
                            ProviderEditableTextFieldRow(
                                title: "上下文",
                                text: $draft.contextWindowText,
                                placeholder: IOSAppLocalization.formatted(
                                    "留空使用 %lld",
                                    defaultValue: "留空使用 %lld",
                                    arguments: [Int64(
                                        ChatContextSnapshot.resolvedContextWindowTokens(
                                            modelWindow: nil,
                                            modelId: draft.modelId
                                        ) ?? Int(ChatContextSnapshot.defaultContextWindowTokens)
                                    )]
                                ),
                                monospace: true
                            )
                        }

                        AmberSectionLabel(text: "Headers")
                        AmberFormGroup {
                            if draft.headers.isEmpty {
                                ProviderStaticRow(title: "自定义 Header", subtitle: "当前没有模型级请求头。", value: "无")
                            } else {
                                ForEach($draft.headers) { $header in
                                    VStack(spacing: 8) {
                                        ProviderEditableTextFieldRow(
                                            title: "名称",
                                            text: $header.name,
                                            placeholder: "Header name",
                                            monospace: true
                                        )
                                        ProviderEditableTextFieldRow(
                                            title: "值",
                                            text: $header.value,
                                            placeholder: "Header value",
                                            monospace: true
                                        )
                                    }
                                    .padding(.vertical, 6)
                                }
                            }
                        }

                        Button {
                            draft.headers.append(ProviderHeaderDraft(name: "", value: ""))
                        } label: {
                            ProviderActionRow(systemImage: "plus.circle", title: "添加 Header", tint: AmberTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle(draft.modelUuid == nil ? "添加模型" : "编辑模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if onSave(draft) {
                            dismiss()
                        }
                    }
                }
            }
            .onChange(of: draft.modelId) { _, modelId in
                if draft.modelUuid == nil, providerModelIDLooksLikeImage(modelId) {
                    draft.type = .image
                }
            }
        }
    }
}

struct ProviderActionRow: View {
    let systemImage: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 50)
        .padding(.horizontal, 12)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.13), lineWidth: 0.5)
        }
    }
}

struct ProviderDetailDivider: View {
    var body: some View {
        Rectangle()
            .fill(AmberTheme.borderSoft)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}

struct ProviderStaticRow: View {
    let title: String
    let subtitle: String
    let value: String
    var valueStyle: ProviderRowValueStyle = .body

    var body: some View {
        ProviderRowContent(title: title, subtitle: subtitle, value: value, valueStyle: valueStyle, showsChevron: false)
    }
}

struct ProviderEditableTextFieldRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var isSecure = false
    var monospace = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    titleLabel
                    textInput(alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    titleLabel.frame(width: 86, alignment: .leading)
                    textInput(alignment: .trailing)
                }
            }
        }
        .frame(minHeight: 50)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var titleLabel: some View {
        Text(title)
            .font(.body)
            .foregroundStyle(AmberTheme.foreground)
    }

    @ViewBuilder
    private func textInput(alignment: TextAlignment) -> some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text, axis: .vertical)
            }
        }
        .font(monospace ? .system(size: 13, weight: .regular, design: .monospaced) : .body)
        .foregroundStyle(AmberTheme.foreground)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .multilineTextAlignment(alignment)
    }
}

struct ProviderToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
        }
        .toggleStyle(.switch)
        .frame(minHeight: 50)
        .padding(.horizontal, 14)
    }
}

struct ProviderConnectionResultRow: View {
    let status: ProviderConnectionStatus
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
            Text(message)
                .font(.footnote)
                .foregroundStyle(AmberTheme.foreground2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
        }
    }

    private var icon: String {
        switch status {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        default: "info.circle"
        }
    }

    private var color: Color {
        switch status {
        case .success: AmberTheme.accentGreen
        case .failure: AmberTheme.accentAmber
        default: AmberTheme.muted
        }
    }
}

struct ProviderDetailFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(AmberTheme.muted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
    }
}

enum ProviderRowValueStyle {
    case body
    case mono
    case accent
}

struct ProviderRowContent: View {
    let title: String
    let subtitle: String
    let value: String
    var valueStyle: ProviderRowValueStyle = .body
    var showsChevron = true
    var stacksValueOnAccessibility = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if stacksValueOnAccessibility && dynamicTypeSize.isAccessibilitySize {
            accessibilityRow
        } else {
            standardRow
        }
    }

    private var standardRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
            }
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var accessibilityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(font)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if showsChevron {
                    chevron
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 58)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AmberTheme.muted2)
    }

    private var font: Font {
        switch valueStyle {
        case .body, .accent:
            .body
        case .mono:
            .system(size: 13, weight: .regular, design: .monospaced)
        }
    }

    private var color: Color {
        switch valueStyle {
        case .body, .mono:
            AmberTheme.muted
        case .accent:
            AmberTheme.accent
        }
    }
}

struct ProviderModelRow: View {
    let systemImage: String
    let name: String
    let badge: String
    let summary: String
    let isCurrent: Bool
    let canSetCurrent: Bool
    let setCurrentTitle: String
    let onEdit: () -> Void
    let onSetCurrent: () -> Void
    let onDelete: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityRow
            } else {
                standardRow
            }
        }
        .frame(minHeight: 64)
        .padding(.horizontal, 14)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 4)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AmberTheme.accentGreen.opacity(0.045))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onEdit()
        }
    }

    private var standardRow: some View {
        HStack(spacing: 12) {
            modelIcon
            modelText
            ProviderModelBadge(text: badge, isCurrent: isCurrent)
            actionsMenu
        }
    }

    private var accessibilityRow: some View {
        HStack(alignment: .top, spacing: 12) {
            modelIcon
            VStack(alignment: .leading, spacing: 8) {
                modelText
                ProviderModelBadge(text: badge, isCurrent: isCurrent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actionsMenu
        }
    }

    private var modelIcon: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isCurrent ? AmberTheme.accentGreen : AmberTheme.accent)
            .frame(width: 36, height: 36)
            .background(
                isCurrent ? AmberTheme.accentGreen.opacity(0.12) : AmberTheme.accentTint,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke((isCurrent ? AmberTheme.accentGreen : AmberTheme.accent).opacity(0.13), lineWidth: 0.5)
            }
    }

    private var modelText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.body.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            Text(summary)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionsMenu: some View {
        Menu {
            Button("编辑", action: onEdit)
            if canSetCurrent && !isCurrent {
                Button(setCurrentTitle, action: onSetCurrent)
            }
            Button("删除", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AmberTheme.muted)
                .frame(
                    width: dynamicTypeSize.isAccessibilitySize ? 44 : 32,
                    height: dynamicTypeSize.isAccessibilitySize ? 44 : 32
                )
                .background(AmberTheme.surface2.opacity(0.8), in: Circle())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

private struct ProviderModelBadge: View {
    let text: String
    let isCurrent: Bool

    var body: some View {
        Text(text)
            .font(isCurrent ? .caption2.weight(.semibold) : .system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(isCurrent ? AmberTheme.accentGreen : AmberTheme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                (isCurrent ? AmberTheme.accentGreen : AmberTheme.muted).opacity(0.10),
                in: Capsule()
            )
    }
}
