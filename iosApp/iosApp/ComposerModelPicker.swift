import SwiftUI
import UIKit
import Shared

struct ComposerModelSheet: View {
    @Environment(\.dismiss) private var dismiss

    let sharedSettings: any IOSSettingsSnapshotSource
    let currentModel: String
    let title: String
    let fallbackTitle: String?
    let onFallback: (() -> Void)?
    let dismissesAfterFallback: Bool
    let pendingSelectionID: String?
    let isSelectionInFlight: Bool
    let isFallbackInFlight: Bool
    let onPick: (ComposerModelOption) -> Void

    @State private var expandedProviderIDs: Set<String>

    private var providers: [ComposerProviderGroup] {
        _ = sharedSettings.revision
        return ComposerProviderGroup.currentConfiguration(sharedSettings: sharedSettings, currentModel: currentModel)
    }

    init(
        sharedSettings: any IOSSettingsSnapshotSource,
        currentModel: String,
        title: String = "选择模型",
        fallbackTitle: String? = nil,
        onFallback: (() -> Void)? = nil,
        dismissesAfterFallback: Bool = true,
        pendingSelectionID: String? = nil,
        isSelectionInFlight: Bool = false,
        isFallbackInFlight: Bool = false,
        onPick: @escaping (ComposerModelOption) -> Void
    ) {
        self.sharedSettings = sharedSettings
        self.currentModel = currentModel
        self.title = title
        self.fallbackTitle = fallbackTitle
        self.onFallback = onFallback
        self.dismissesAfterFallback = dismissesAfterFallback
        self.pendingSelectionID = pendingSelectionID
        self.isSelectionInFlight = isSelectionInFlight
        self.isFallbackInFlight = isFallbackInFlight
        self.onPick = onPick
        let selectedProviderID = Self.selectedProviderID(
            for: currentModel,
            providers: ComposerProviderGroup.currentConfiguration(sharedSettings: sharedSettings, currentModel: currentModel)
        )
        self._expandedProviderIDs = State(initialValue: Set([selectedProviderID]))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AmberTheme.foreground)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AmberTheme.foreground2)
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("关闭模型选择")
                .disabled(isSelectionInFlight)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Divider()
                .overlay(AmberTheme.borderSoft)

            ScrollView {
                if let fallbackTitle, let onFallback {
                    Button {
                        onFallback()
                        if dismissesAfterFallback {
                            dismiss()
                        }
                    } label: {
                        Label {
                            Text(fallbackTitle)
                        } icon: {
                            ZStack {
                                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                                    .opacity(isFallbackInFlight ? 0 : 1)
                                if isFallbackInFlight {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(AmberTheme.accent)
                                }
                            }
                            .frame(width: 18, height: 18)
                        }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AmberTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSelectionInFlight)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                }

                if providers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "cpu")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(AmberTheme.accent)
                        Text("还没有可用模型")
                            .font(.headline)
                            .foregroundStyle(AmberTheme.foreground)
                        Text("请先在服务商详情自动获取或手动添加模型。")
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 38)
                    .padding(.horizontal, 16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                            ComposerProviderGroupView(
                                provider: provider,
                                currentModel: currentModel,
                                isExpanded: expandedProviderIDs.contains(provider.id),
                                pendingSelectionID: pendingSelectionID,
                                isSelectionInFlight: isSelectionInFlight,
                                onToggle: {
                                    toggleProvider(provider.id)
                                },
                                onPick: { model in
                                    onPick(model)
                                }
                            )

                            if index < providers.count - 1 {
                                Divider()
                                    .overlay(AmberTheme.borderSoft)
                            }
                        }
                    }
                    .background(AmberTheme.glass)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .interactiveDismissDisabled(isSelectionInFlight)
        .onAppear {
            expandedProviderIDs = Set([Self.selectedProviderID(for: currentModel, providers: providers)])
        }
    }

    private func toggleProvider(_ id: String) {
        withAnimation(.snappy(duration: 0.25)) {
            if expandedProviderIDs.contains(id) {
                expandedProviderIDs.remove(id)
            } else {
                expandedProviderIDs.insert(id)
            }
        }
    }

    private static func selectedProviderID(for currentModel: String, providers: [ComposerProviderGroup]) -> String {
        providers.first { provider in
            provider.models.contains { $0.matches(currentModel) }
        }?.id ?? providers.first?.id ?? "current"
    }
}

struct ComposerProviderGroupView: View {
    let provider: ComposerProviderGroup
    let currentModel: String
    let isExpanded: Bool
    let pendingSelectionID: String?
    let isSelectionInFlight: Bool
    let onToggle: () -> Void
    let onPick: (ComposerModelOption) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Text(provider.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(providerContainsSelection ? AmberTheme.accent : AmberTheme.foreground)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted2)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(provider.name) 模型分组")
            .accessibilityValue(isExpanded ? "已展开" : "已收起")

            if isExpanded {
                Divider()
                    .overlay(AmberTheme.borderSoft)
                    .padding(.leading, 16)

                VStack(spacing: 0) {
                    ForEach(Array(provider.models.enumerated()), id: \.element.id) { index, model in
                        if index > 0 {
                            Divider()
                                .overlay(AmberTheme.borderSoft)
                                .padding(.leading, 36)
                        }

                        ComposerModelRow(
                            model: model,
                            isSelected: model.matches(currentModel),
                            isPending: model.id == pendingSelectionID,
                            isDisabled: isSelectionInFlight
                        ) {
                            onPick(model)
                        }
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var providerContainsSelection: Bool {
        provider.models.contains { $0.matches(currentModel) }
    }
}

struct ComposerModelRow: View {
    let model: ComposerModelOption
    let isSelected: Bool
    var isPending = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(model.name)
                    .font(.subheadline.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? AmberTheme.foreground : AmberTheme.foreground2)
                    .lineLimit(1)

                if let context = model.context {
                    Text(context)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AmberTheme.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AmberTheme.surface2.opacity(0.72), in: Capsule())
                        .layoutPriority(1)
                }

                Spacer(minLength: 8)

                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AmberTheme.accent)
                        .frame(width: 16, height: 16)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(width: 16, height: 16)
                } else {
                    Color.clear
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.leading, 36)
            .padding(.trailing, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel("选择模型 \(model.name)")
        .accessibilityValue(isPending ? "正在保存" : isSelected ? "已选" : "未选")
    }
}

struct ComposerProviderGroup: Identifiable {
    let id: String
    let name: String
    let models: [ComposerModelOption]

    static func currentConfiguration(sharedSettings: any IOSSettingsSnapshotSource, currentModel: String) -> [ComposerProviderGroup] {
        sharedSettings.snapshot.providers.compactMap { provider in
            guard provider.enabled, ChatProviderConfiguration.supportsChatStreaming(provider) else { return nil }
            let models = provider.models
                .filter { $0.type == ModelType.chat }
                .map { model in
                    ComposerModelOption(
                        id: model.id.description(),
                        name: displayName(for: model),
                        modelId: model.modelId,
                        context: contextLabel(for: model)
                    )
                }
            guard !models.isEmpty else { return nil }
            return ComposerProviderGroup(id: provider.id.description(), name: provider.name, models: models)
        }
    }

    private static func displayName(for model: Model) -> String {
        let name = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? model.modelId : name
    }

    private static func contextLabel(for model: Model) -> String? {
        guard let tokens = model.contextWindowTokens else { return nil }
        return formatContextWindow(Int(truncating: tokens))
    }

    /// 紧凑显示上下文窗口:≥100万写 1M(必要时带一位小数),≥1000 写 XK,否则原数。
    static func formatContextWindow(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return trimmedDecimal(Double(tokens) / 1_000_000) + "M"
        }
        if tokens >= 1_000 {
            return "\(Int((Double(tokens) / 1_000).rounded()))K"
        }
        return "\(tokens)"
    }

    private static func trimmedDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))"
        }
        return String(
            format: "%.1f",
            locale: IOSAppLanguagePreference.selected().resolvedLocale(),
            rounded
        )
    }
}

struct ComposerModelOption: Identifiable, Hashable {
    let id: String
    let name: String
    let modelId: String
    let context: String?

    func matches(_ value: String) -> Bool {
        let normalizedValue = Self.normalize(value)
        return Self.normalize(id) == normalizedValue ||
            Self.normalize(name) == normalizedValue ||
            Self.normalize(modelId) == normalizedValue
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
