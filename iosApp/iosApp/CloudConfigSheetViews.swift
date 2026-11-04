import SwiftUI

// MARK: - Current → Target Comparison Card

/// Displays an explicit "当前 → 目标（服务商 / 模型 / Base URL）" comparison
/// so the user always sees what the cloud is currently running vs what it will switch to.
struct CloudModelTransitionGroup: View {
    let transition: IOSCloudModelTransitionSummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("当前 → 目标配置对比"))
            AmberFormGroup {
                comparisonRow(
                    icon: "cpu",
                    title: macGatewayL("服务商"),
                    currentValue: transition.current?.providerLabel ?? macGatewayL("未设置"),
                    targetValue: transition.target.providerLabel
                )
                MacGatewayRowDivider()
                comparisonRow(
                    icon: "sparkles",
                    title: macGatewayL("模型"),
                    currentValue: transition.current?.modelId ?? macGatewayL("未设置"),
                    targetValue: transition.target.modelId
                )
                MacGatewayRowDivider()
                comparisonRow(
                    icon: "network",
                    title: "Base URL",
                    currentValue: transition.current?.baseUrlDisplay ?? macGatewayL("未设置"),
                    targetValue: transition.target.baseUrlDisplay
                )
                MacGatewayRowDivider()
                comparisonRow(
                    icon: "key",
                    title: "API Key",
                    currentValue: transition.current?.keyStatusLabel ?? macGatewayL("未配置"),
                    targetValue: transition.target.keyStatusLabel
                )
            }
        }
    }

    private func comparisonRow(
        icon: String,
        title: String,
        currentValue: String,
        targetValue: String
    ) -> some View {
        let changed = currentValue != targetValue
        return HStack(alignment: .top, spacing: 12) {
            MacGatewayIconPlate(icon: icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                if dynamicTypeSize.isAccessibilitySize {
                    Text(verbatim: macGatewayL("当前：") + currentValue)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                    Text(verbatim: macGatewayL("目标：") + targetValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(changed ? AmberTheme.accent : AmberTheme.foreground)
                } else {
                    HStack(spacing: 6) {
                        Text(verbatim: currentValue)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(changed ? AmberTheme.accent : AmberTheme.muted)
                        Text(verbatim: targetValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(changed ? AmberTheme.accent : AmberTheme.foreground)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Primary Action Button & Disabled Guidance

/// Primary submit button group for cloud configuration sheets.
/// Visually distinguishes enabled vs disabled states and always shows the concrete
/// reason + next step right below the button whenever disabled.
struct CloudPrimaryActionGroup: View {
    let title: String
    let readiness: IOSCloudConfigActionReadiness
    let isSubmitting: Bool
    var onRefresh: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AmberFormGroup {
                Button(action: action) {
                    ZStack {
                        if isSubmitting {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(verbatim: macGatewayL("正在同步到云端…"))
                                    .font(.subheadline)
                                    .foregroundStyle(AmberTheme.muted)
                            }
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: readiness.canSubmit ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .font(.body.weight(.semibold))
                                Text(verbatim: title)
                                    .font(.body.weight(.semibold))
                            }
                            .foregroundStyle(readiness.canSubmit ? AmberTheme.accent : AmberTheme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!readiness.canSubmit)
            }
            .padding(.top, 16)

            if !readiness.canSubmit, let reason = readiness.disabledReason {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: reason)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if let nextStep = readiness.nextStep, !nextStep.isEmpty {
                        Text(verbatim: nextStep)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if readiness.effectiveReviewed == nil, !isSubmitting, let onRefresh {
                        Button(action: onRefresh) {
                            Label(macGatewayL("刷新云端状态"), systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(AmberTheme.accentTint, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AmberTheme.accent)
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - Quick Switch / Import Confirmation Sheet

/// Confirmation sheet for switching the cloud's active provider & model.
/// Shows explicit "当前 → 目标" comparison and uses task-oriented "切换并使用" wording.
struct CloudImportPreviewSheet: View {
    let draft: IOSCloudImportDraft
    let remote: IOSCloudConfigSnapshot?
    let latestRemote: IOSCloudConfigSnapshot?
    let isLoadingRemote: Bool
    let error: String?
    let importing: Bool
    let onReview: () -> Void
    let onRefresh: () -> Void
    let onConfirm: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss

    private var readiness: IOSCloudConfigActionReadiness {
        let transition = draft.modelTransitionSummary(remote: remote ?? latestRemote)
        let blocker: IOSCloudConfigActionReadiness.FormBlocker? =
            transition?.requiresNewKeyForDestinationChange == true ? .missingDestinationApiKey : nil
        return IOSCloudConfigActionReadiness.evaluate(
            reviewed: remote,
            latest: latestRemote,
            isLoading: isLoadingRemote,
            isSubmitting: importing,
            formBlocker: blocker
        )
    }

    var body: some View {
        let effectiveRemote = readiness.effectiveReviewed
        let entries = draft.previewEntries(remote: effectiveRemote)
        let transition = draft.modelTransitionSummary(remote: effectiveRemote)
        return NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        if let transition {
                            CloudModelTransitionGroup(transition: transition)
                        }
                        AmberSectionLabel(verbatim: macGatewayL("同步明细"))
                        AmberFormGroup {
                            ForEach(entries) { entry in
                                CloudImportPreviewEntryRow(entry: entry)
                                if entry.id != entries.last?.id {
                                    MacGatewayRowDivider()
                                }
                            }
                        }
                        MacGatewaySectionFooter(
                            text: macGatewayL("来源：本机 · Key 在内存中加密封装后经已配对连接上传，云端只保存配置状态、不回显密钥。")
                        )
                        CloudConfigRevisionNotice(
                            reviewed: remote,
                            latest: latestRemote,
                            isLoading: isLoadingRemote,
                            error: error,
                            onReview: onReview,
                            onRefresh: onRefresh
                        )
                        CloudPrimaryActionGroup(
                            title: macGatewayL("切换并使用"),
                            readiness: readiness,
                            isSubmitting: importing,
                            onRefresh: onRefresh
                        ) {
                            onConfirm(readiness.effectiveExpectedRevision)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(macGatewayL("确认切换云端模型"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(macGatewayL("取消")) { dismiss() }
                }
            }
            .onAppear {
                if remote == nil, latestRemote != nil {
                    onReview()
                }
            }
            .onChange(of: latestRemote) { _, newValue in
                if remote == nil, newValue != nil {
                    onReview()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct CloudImportPreviewEntryRow: View {
    let entry: IOSCloudImportPreviewEntry

    var body: some View {
        HStack(spacing: 12) {
            MacGatewayIconPlate(icon: entry.section == .model ? "cpu" : "magnifyingglass")
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.title).font(.body).foregroundStyle(AmberTheme.foreground)
                Text(verbatim: entry.detail).font(.caption).foregroundStyle(AmberTheme.muted)
                if let warning = entry.warning {
                    Text(verbatim: warning)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: entry.replacesRemote ? macGatewayL("替换") : macGatewayL("新增"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(entry.replacesRemote ? .orange : AmberTheme.accent)
                if entry.includesSecret {
                    Image(systemName: "key.fill")
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.muted)
                        .accessibilityLabel(Text(verbatim: macGatewayL("携带 API Key")))
                }
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
    }
}

// MARK: - Manual Model Switch Sheet

struct CloudManualModelSheet: View {
    let remote: IOSCloudConfigSnapshot?
    let latestRemote: IOSCloudConfigSnapshot?
    let isLoadingRemote: Bool
    let error: String?
    let importing: Bool
    let onReview: () -> Void
    let onRefresh: () -> Void
    /// (model patch, standalone credential actions, expectedRevision).
    let onApply: (IOSCloudConfigBundle.ModelSection?, [String: IOSCloudConfigBundle.CredentialAction], Int?) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The contract accepts openai/claude protocols only.
    private static let kinds: [IOSCloudProviderKind] = [.openAI, .claude]

    @State private var kind: IOSCloudProviderKind
    @State private var baseUrl: String
    @State private var modelId: String
    @State private var apiKey = ""
    @State private var confirmingDelete = false
    @State private var hasEditedFields = false

    init(
        remote: IOSCloudConfigSnapshot?,
        latestRemote: IOSCloudConfigSnapshot?,
        isLoadingRemote: Bool,
        error: String?,
        importing: Bool,
        onReview: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onApply: @escaping (IOSCloudConfigBundle.ModelSection?, [String: IOSCloudConfigBundle.CredentialAction], Int?) -> Void
    ) {
        self.remote = remote
        self.latestRemote = latestRemote
        self.isLoadingRemote = isLoadingRemote
        self.error = error
        self.importing = importing
        self.onReview = onReview
        self.onRefresh = onRefresh
        self.onApply = onApply
        let seed = remote ?? latestRemote
        _kind = State(initialValue: (seed?.model?.provider).flatMap(IOSCloudProviderKind.init(rawValue:)) ?? .openAI)
        _baseUrl = State(initialValue: seed?.model?.baseUrl ?? "")
        _modelId = State(initialValue: seed?.model?.modelId ?? "")
    }

    private var transition: IOSCloudModelTransitionSummary {
        IOSCloudModelTransitionSummary.forManualEdit(
            remote: remote ?? latestRemote,
            providerKind: kind,
            modelId: modelId,
            baseUrl: baseUrl,
            hasNewApiKey: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private var readiness: IOSCloudConfigActionReadiness {
        let trimmedModelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocker: IOSCloudConfigActionReadiness.FormBlocker?
        if trimmedModelId.isEmpty {
            blocker = .missingModelId
        } else if transition.requiresNewKeyForDestinationChange {
            blocker = .missingDestinationApiKey
        } else {
            blocker = nil
        }
        return IOSCloudConfigActionReadiness.evaluate(
            reviewed: remote,
            latest: latestRemote,
            isLoading: isLoadingRemote,
            isSubmitting: importing,
            formBlocker: blocker
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        AmberSectionLabel(verbatim: macGatewayL("目标云端模型"))
                        AmberFormGroup {
                            kindMenu
                            MacGatewayRowDivider()
                            CloudConfigFieldRow(
                                title: "Base URL",
                                text: $baseUrl,
                                placeholder: kind == .claude ? "https://api.anthropic.com/v1" : "https://api.openai.com/v1",
                                monospace: true
                            )
                            MacGatewayRowDivider()
                            CloudConfigFieldRow(
                                title: macGatewayL("模型 ID"),
                                text: $modelId,
                                placeholder: "deepseek-chat",
                                monospace: true
                            )
                            MacGatewayRowDivider()
                            CloudConfigFieldRow(
                                title: "API Key",
                                text: $apiKey,
                                placeholder: macGatewayL("支持长按「粘贴」或 ⌘V；留空则保留云端现有 Key"),
                                monospace: true,
                                isSecure: true
                            )
                        }
                        MacGatewaySectionFooter(
                            text: macGatewayL("Key 仅在主动粘贴或输入时读取，在内存中加密封装后上传；切换服务商或 Base URL 时需同时填写新服务的 API Key。")
                        )

                        CloudModelTransitionGroup(transition: transition)

                        CloudConfigRevisionNotice(
                            reviewed: remote,
                            latest: latestRemote,
                            isLoading: isLoadingRemote,
                            error: error,
                            onReview: onReview,
                            onRefresh: onRefresh
                        )
                        CloudPrimaryActionGroup(
                            title: macGatewayL("切换并使用"),
                            readiness: readiness,
                            isSubmitting: importing,
                            onRefresh: onRefresh
                        ) {
                            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            onApply(
                                IOSCloudConfigBundle.ModelSection(
                                    providerKind: kind.rawValue,
                                    modelId: modelId.trimmingCharacters(in: .whitespacesAndNewlines),
                                    baseUrl: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                                    credential: trimmedKey.isEmpty ? .keep : .replace(trimmedKey)
                                ),
                                [:],
                                readiness.effectiveExpectedRevision
                            )
                        }
                        if (remote ?? latestRemote)?.model?.keyConfigured == true {
                            deleteGroup
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(macGatewayL("手动切换云端模型"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(macGatewayL("取消")) { dismiss() }
                }
            }
            .onAppear {
                if remote == nil, latestRemote != nil {
                    onReview()
                }
            }
            .onChange(of: latestRemote) { _, newValue in
                if remote == nil, let newValue {
                    if !hasEditedFields, let remoteModel = newValue.model {
                        if let resolvedKind = IOSCloudProviderKind(rawValue: remoteModel.provider) {
                            kind = resolvedKind
                        }
                        if baseUrl.isEmpty { baseUrl = remoteModel.baseUrl }
                        if modelId.isEmpty { modelId = remoteModel.modelId }
                    }
                    onReview()
                }
            }
            .onChange(of: baseUrl) { _, _ in hasEditedFields = true }
            .onChange(of: modelId) { _, _ in hasEditedFields = true }
            .onChange(of: apiKey) { _, _ in hasEditedFields = true }
        }
        .presentationDetents([.medium, .large])
    }

    private var kindMenu: some View {
        Menu {
            ForEach(Self.kinds, id: \.rawValue) { option in
                Button(IOSCloudConfigWire.providerDisplayName(for: option.rawValue)) {
                    hasEditedFields = true
                    kind = option
                }
            }
        } label: {
            HStack(spacing: 12) {
                MacGatewayIconPlate(icon: "cpu")
                Text(verbatim: macGatewayL("目标服务商协议")).font(.body).foregroundStyle(AmberTheme.foreground)
                Spacer(minLength: 8)
                Text(verbatim: IOSCloudConfigWire.providerDisplayName(for: kind.rawValue))
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.accent)
                MacGatewayChevron()
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
    }

    /// Explicit key deletion — a separate contract action, never conflated with an empty field.
    private var deleteGroup: some View {
        let deleteReadiness = IOSCloudConfigActionReadiness.evaluate(
            reviewed: remote,
            latest: latestRemote,
            isLoading: isLoadingRemote,
            isSubmitting: importing,
            formBlocker: nil
        )
        return AmberFormGroup {
            Button(role: .destructive) { confirmingDelete = true } label: {
                Text(verbatim: macGatewayL("删除云端已保存的模型 Key"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(deleteReadiness.canSubmit ? .red : AmberTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!deleteReadiness.canSubmit)
            .confirmationDialog(
                macGatewayL("删除云端模型 Key？配置保持不变，后续任务会报告未配置。"),
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button(macGatewayL("删除 Key"), role: .destructive) {
                    onApply(nil, [IOSCloudConfigWire.modelCredentialKey: .delete], deleteReadiness.effectiveExpectedRevision)
                }
            }
        }
        .padding(.top, 12)
    }
}

// MARK: - Manual Search Key Sheet (Exa / Brave)

struct CloudManualSearchSheet: View {
    let remote: IOSCloudConfigSnapshot?
    let latestRemote: IOSCloudConfigSnapshot?
    let isLoadingRemote: Bool
    let error: String?
    let importing: Bool
    let onReview: () -> Void
    let onRefresh: () -> Void
    /// (search entry, standalone credential actions, expectedRevision).
    let onApply: (IOSCloudConfigBundle.SearchEntry?, [String: IOSCloudConfigBundle.CredentialAction], Int?) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let supportedTypes: [(type: String, name: String)] = [
        ("exa", "Exa"), ("brave", "Brave"),
    ]

    @State private var type = "exa"
    @State private var apiKey = ""
    @State private var confirmingDelete = false

    private var serviceDisplayName: String {
        Self.supportedTypes.first { $0.type == type }?.name ?? type
    }

    private var readiness: IOSCloudConfigActionReadiness {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocker: IOSCloudConfigActionReadiness.FormBlocker? =
            trimmed.isEmpty ? .missingSearchApiKey(serviceName: serviceDisplayName) : nil
        return IOSCloudConfigActionReadiness.evaluate(
            reviewed: remote,
            latest: latestRemote,
            isLoading: isLoadingRemote,
            isSubmitting: importing,
            formBlocker: blocker
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        AmberSectionLabel(verbatim: macGatewayL("搜索服务与密钥"))
                        AmberFormGroup {
                            typeMenu
                            MacGatewayRowDivider()
                            CloudConfigFieldRow(
                                title: "\(serviceDisplayName) API Key",
                                text: $apiKey,
                                placeholder: macGatewayL("长按选择「粘贴」或按 ⌘V 填入长 API Key"),
                                monospace: true,
                                isSecure: true
                            )
                        }
                        MacGatewaySectionFooter(
                            text: remoteKeyState + macGatewayL(" · 仅在主动粘贴时读取剪贴板并自动去除首尾空白/换行；在内存中加密封装后上传，不回显密钥。")
                        )
                        CloudConfigRevisionNotice(
                            reviewed: remote,
                            latest: latestRemote,
                            isLoading: isLoadingRemote,
                            error: error,
                            onReview: onReview,
                            onRefresh: onRefresh
                        )
                        CloudPrimaryActionGroup(
                            title: macGatewayL("保存并使用 \(serviceDisplayName) Key"),
                            readiness: readiness,
                            isSubmitting: importing,
                            onRefresh: onRefresh
                        ) {
                            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            onApply(
                                IOSCloudConfigBundle.SearchEntry(
                                    type: type,
                                    name: serviceDisplayName,
                                    enabled: false,
                                    credential: trimmed.isEmpty ? .keep : .replace(trimmed),
                                    includeInConfiguration: false
                                ),
                                [:],
                                readiness.effectiveExpectedRevision
                            )
                        }
                        if remoteKeyConfigured {
                            deleteGroup
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(macGatewayL("更新搜索 API Key"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(macGatewayL("取消")) { dismiss() }
                }
            }
            .onAppear {
                if remote == nil, latestRemote != nil {
                    onReview()
                }
            }
            .onChange(of: latestRemote) { _, newValue in
                if remote == nil, newValue != nil {
                    onReview()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var typeMenu: some View {
        Menu {
            ForEach(Self.supportedTypes, id: \.type) { option in
                Button(option.name + " · " + option.type) { type = option.type }
            }
        } label: {
            HStack(spacing: 12) {
                MacGatewayIconPlate(icon: "magnifyingglass")
                Text(verbatim: macGatewayL("目标搜索服务")).font(.body).foregroundStyle(AmberTheme.foreground)
                Spacer(minLength: 8)
                Text(verbatim: serviceDisplayName).font(.subheadline).foregroundStyle(AmberTheme.accent)
                MacGatewayChevron()
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
    }

    private var remoteKeyConfigured: Bool {
        (remote ?? latestRemote)?.search.first { $0.type == type }?.keyConfigured == true
    }

    private var remoteKeyState: String {
        remoteKeyConfigured
            ? macGatewayL("当前云端：已配置 \(serviceDisplayName) Key → 提交后将替换为新 Key")
            : macGatewayL("当前云端：未配置 \(serviceDisplayName) Key → 提交后将保存新 Key")
    }

    private var deleteGroup: some View {
        let deleteReadiness = IOSCloudConfigActionReadiness.evaluate(
            reviewed: remote,
            latest: latestRemote,
            isLoading: isLoadingRemote,
            isSubmitting: importing,
            formBlocker: nil
        )
        return AmberFormGroup {
            Button(role: .destructive) { confirmingDelete = true } label: {
                Text(verbatim: macGatewayL("删除云端已保存的 \(serviceDisplayName) Key"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(deleteReadiness.canSubmit ? .red : AmberTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!deleteReadiness.canSubmit)
            .confirmationDialog(
                macGatewayL("删除云端 \(serviceDisplayName) Key？该源将因缺少 Key 而不可用。"),
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button(macGatewayL("删除 Key"), role: .destructive) {
                    if let key = IOSCloudConfigWire.credentialKey(for: type) {
                        onApply(nil, [key: .delete], deleteReadiness.effectiveExpectedRevision)
                    }
                }
            }
        }
        .padding(.top, 12)
    }
}

// MARK: - Field Row & Structured Revision/Error Notice

/// Labeled text/secure field row matching the gateway form style.
/// Uses `AmberSecureKeyInput` for secure fields so long-press「粘贴」and `⌘V` always work.
struct CloudConfigFieldRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var monospace = false
    var isSecure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
            if isSecure {
                AmberSecureKeyInput(
                    placeholder: placeholder,
                    text: $text,
                    font: monospace
                        ? .monospacedSystemFont(ofSize: 14, weight: .regular)
                        : .preferredFont(forTextStyle: .body),
                    accessibilityLabel: title
                )
            } else {
                TextField(placeholder, text: $text)
                    .font(monospace ? .system(size: 14, weight: .regular, design: .monospaced) : .body)
                    .foregroundStyle(AmberTheme.foreground)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 58)
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
    }
}

/// Structured conflict & error card.
/// Never blocks the user with an unstyled red text link: only renders a version
/// conflict card when a previously reviewed snapshot was genuinely superseded by a
/// newer remote revision, and presents a clear full-width confirmation button row.
struct CloudConfigRevisionNotice: View {
    let reviewed: IOSCloudConfigSnapshot?
    let latest: IOSCloudConfigSnapshot?
    var isLoading = false
    let error: String?
    let onReview: () -> Void
    var onRefresh: (() -> Void)? = nil

    private var hasRealVersionConflict: Bool {
        guard let reviewed, let latest else { return false }
        return !reviewed.hasSameVersion(as: latest)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                AmberFormGroup {
                    HStack(alignment: .top, spacing: 12) {
                        MacGatewayIconPlate(icon: "exclamationmark.triangle.fill", tint: .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: macGatewayL("操作未完成（已保留你填写的内容）"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AmberTheme.foreground)
                            Text(verbatim: error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .padding(.top, 12)
            }

            if hasRealVersionConflict, let reviewed, let latest {
                AmberSectionLabel(verbatim: macGatewayL("云端版本更新确认"))
                AmberFormGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: macGatewayL("云端配置刚在其他终端更新，请核对最新状态后继续"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                        if reviewed.gatewayId != latest.gatewayId {
                            Text(verbatim: macGatewayL("注意：云端配对连接已更换，请确认目标主机。"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text(verbatim: macGatewayL("之前版本 (#\(reviewed.revision))：") + summary(reviewed))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                        Text(verbatim: macGatewayL("最新云端 (#\(latest.revision))：") + summary(latest))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.foreground)
                        Text(verbatim: macGatewayL("确认后将基于最新云端版本提交，你在本页已选或已填的内容不会丢失。"))
                            .font(.caption2)
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    MacGatewayRowDivider()

                    Button(action: onReview) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.body.weight(.semibold))
                            Text(verbatim: macGatewayL("确认最新云端版本并继续（保留已填内容）"))
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(AmberTheme.accent)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(AmberTheme.accentTint)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func summary(_ snapshot: IOSCloudConfigSnapshot) -> String {
        let model = snapshot.model.map {
            [$0.provider, $0.modelId, IOSCloudConfigWire.displayBaseUrl(provider: $0.provider, baseUrl: $0.baseUrl)]
                .joined(separator: " · ")
        } ?? macGatewayL("未配置模型")
        let keys = [("modelApiKey", "模型 Key"), ("exaApiKey", "Exa Key"), ("braveApiKey", "Brave Key")].map {
            macGatewayL($0.1) + ": " + (snapshot.keyConfigured(forCredentialKey: $0.0) ? macGatewayL("已配置") : macGatewayL("未配置"))
        }.joined(separator: " · ")
        return model + " | " + keys
    }
}
