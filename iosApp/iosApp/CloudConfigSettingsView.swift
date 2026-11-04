import SwiftUI

/// Settings › Amber · 云端 › 云端配置 — prioritizes selecting/switching the cloud's
/// active provider/model as the primary task with explicit "当前 → 目标" comparison,
/// while keeping "从本机导入配置" as an independent secondary entry over the paired
/// HTTPS/SPKI channel per docs/architecture/cloud-configuration-api.md.
struct CloudConfigSettingsView: View {
    let sharedSettings: IOSSharedSettingsStore
    private let store = MacGatewayStore.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(RouterPath.self) private var router

    @State private var draft: IOSCloudImportDraft?
    @State private var presentingModelPreview = false
    @State private var presentingLocalImport = false
    @State private var manualSheet: ManualSheet?
    @State private var importError: String?
    @State private var previewSnapshot: IOSCloudConfigSnapshot?
    @State private var manualSnapshot: IOSCloudConfigSnapshot?

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        if store.connection == nil {
                            notPairedSection
                        } else {
                            feedbackBanner
                            remoteModelSection
                            switchModelSection
                            remoteSearchSection
                            importEntrySection
                        }
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .tint(AmberTheme.accent)
        .task {
            draft = IOSCloudImportDraft.make(from: sharedSettings)
            await store.refreshCloudConfig()
        }
        .task(id: sharedSettings.revision) {
            guard let draft else { return }
            self.draft = draft.rebuilt(from: sharedSettings)
        }
        .sheet(isPresented: $presentingModelPreview) {
            if let modelDraft = draft?.modelOnlyDraft {
                CloudImportPreviewSheet(
                    draft: modelDraft,
                    remote: previewSnapshot,
                    latestRemote: store.cloudConfig,
                    isLoadingRemote: store.cloudConfigLoading,
                    error: importError,
                    importing: store.cloudImporting,
                    onReview: { previewSnapshot = store.cloudConfig; importError = nil },
                    onRefresh: { Task { await store.refreshCloudConfig() } },
                    onConfirm: { expectedRevision in
                        Task {
                            let error = await store.applyCloudImport(
                                draft: modelDraft,
                                sharedSettings: sharedSettings,
                                expectedRevision: expectedRevision
                            )
                            if let error {
                                importError = error
                            } else {
                                importError = nil
                                presentingModelPreview = false
                            }
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $presentingLocalImport) {
            if let binding = Binding($draft) {
                CloudLocalImportSheet(
                    draft: binding,
                    remote: previewSnapshot,
                    latestRemote: store.cloudConfig,
                    isLoadingRemote: store.cloudConfigLoading,
                    error: $importError,
                    importing: store.cloudImporting,
                    onReview: { previewSnapshot = store.cloudConfig; importError = nil },
                    onRefresh: { Task { await store.refreshCloudConfig() } },
                    onConfirm: { currentDraft, expectedRevision in
                        Task {
                            let error = await store.applyCloudImport(
                                draft: currentDraft,
                                sharedSettings: sharedSettings,
                                expectedRevision: expectedRevision
                            )
                            if let error {
                                importError = error
                            } else {
                                importError = nil
                                presentingLocalImport = false
                            }
                        }
                    }
                )
            }
        }
        .sheet(item: $manualSheet) { sheet in
            switch sheet {
            case .model:
                CloudManualModelSheet(
                    remote: manualSnapshot,
                    latestRemote: store.cloudConfig,
                    isLoadingRemote: store.cloudConfigLoading,
                    error: importError,
                    importing: store.cloudImporting,
                    onReview: { manualSnapshot = store.cloudConfig; importError = nil },
                    onRefresh: { Task { await store.refreshCloudConfig() } },
                    onApply: { section, extras, expectedRevision in
                        Task {
                            await applyManual(
                                bundle: .init(model: section, search: [], freeSources: [], extraCredentials: extras),
                                expectedRevision: expectedRevision
                            )
                        }
                    }
                )
            case .searchKey:
                CloudManualSearchSheet(
                    remote: manualSnapshot,
                    latestRemote: store.cloudConfig,
                    isLoadingRemote: store.cloudConfigLoading,
                    error: importError,
                    importing: store.cloudImporting,
                    onReview: { manualSnapshot = store.cloudConfig; importError = nil },
                    onRefresh: { Task { await store.refreshCloudConfig() } },
                    onApply: { entry, extras, expectedRevision in
                        Task {
                            await applyManual(
                                bundle: .init(model: nil, search: entry.map { [$0] } ?? [], freeSources: [], extraCredentials: extras),
                                expectedRevision: expectedRevision
                            )
                        }
                    }
                )
            }
        }
    }

    private func applyManual(bundle: IOSCloudConfigBundle, expectedRevision: Int?) async {
        if let error = await store.applyCloudBundle(
            bundle,
            expectedRevision: expectedRevision ?? manualSnapshot?.revision ?? store.cloudConfig?.revision
        ) {
            importError = error
        } else {
            importError = nil
            manualSheet = nil
        }
    }

    // MARK: - Header & Feedback Banner

    private var header: some View {
        HStack(spacing: 8) {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer(minLength: 0)
            Text(verbatim: macGatewayL("云端配置"))
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            refreshButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        if let notice = store.notice {
            AmberFormGroup {
                HStack(spacing: 12) {
                    MacGatewayIconPlate(
                        icon: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                        tint: notice.isError ? .orange : AmberTheme.accentGreen
                    )
                    Text(verbatim: notice.text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(notice.isError ? .orange : AmberTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .padding(.bottom, 4)
        } else if let error = store.cloudConfigError {
            AmberFormGroup {
                HStack(spacing: 12) {
                    MacGatewayIconPlate(icon: "exclamationmark.triangle.fill", tint: .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: error)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: macGatewayL("可点击右上角刷新按钮重新读取云端状态。"))
                            .font(.caption2)
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - Not paired

    private var notPairedSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("云端配置"))
            AmberFormGroup {
                MacGatewayRow(icon: "desktopcomputer", title: macGatewayL("先配对 Amber · 云端"),
                              detail: macGatewayL("云端配置通过已配对的加密连接管理"),
                              action: { dismiss() }) {
                    MacGatewayChevron()
                }
            }
            MacGatewaySectionFooter(text: macGatewayL("回到上一页扫码或粘贴配对链接。"))
        }
    }

    // MARK: - Current Cloud Model Status

    private var remoteModelSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("云端当前模型"))
            AmberFormGroup {
                if let model = store.cloudConfig?.model,
                   !model.provider.isEmpty || !model.modelId.isEmpty {
                    valueRow(
                        icon: "cpu",
                        title: macGatewayL("当前服务商"),
                        value: IOSCloudConfigWire.providerDisplayName(for: model.provider)
                    )
                    MacGatewayRowDivider()
                    valueRow(icon: "sparkles", title: macGatewayL("当前模型"), value: model.modelId)
                    MacGatewayRowDivider()
                    valueRow(
                        icon: "network",
                        title: "Base URL",
                        value: IOSCloudConfigWire.displayBaseUrl(provider: model.provider, baseUrl: model.baseUrl)
                    )
                    MacGatewayRowDivider()
                    HStack(spacing: 12) {
                        MacGatewayIconPlate(icon: "key")
                        Text(verbatim: "API Key")
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                        Spacer(minLength: 8)
                        Text(verbatim: model.keyConfigured ? macGatewayL("已配置") : macGatewayL("缺少 Key"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(model.keyConfigured ? AmberTheme.accentGreen : AmberTheme.accentAmber)
                    }
                    .frame(minHeight: 52)
                    .padding(.horizontal, 14)
                } else {
                    MacGatewayRow(icon: "cpu", title: macGatewayL("云端尚未设置模型"),
                                  detail: remoteHint) {
                        if store.cloudConfigLoading {
                            ProgressView()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Primary Task: Switch Cloud Provider & Model

    private var switchModelSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("切换云端服务商与模型"))
            AmberFormGroup {
                if let draft, !draft.exportableProviders.isEmpty {
                    primaryProviderMenuRow(draft)
                    if let selectedProvider = draft.selectedProvider {
                        MacGatewayRowDivider()
                        modelPickerRow(selectedProvider, draft: draft)
                        if let transition = draft.modelOnlyDraft.modelTransitionSummary(remote: store.cloudConfig) {
                            MacGatewayRowDivider()
                            inlineTransitionSummaryRow(transition)
                            MacGatewayRowDivider()
                            switchSelectedModelActionRow(
                                selectedProvider: selectedProvider,
                                selectedModel: draft.selectedModel,
                                transition: transition
                            )
                        }
                    }
                    MacGatewayRowDivider()
                } else if draft != nil {
                    MacGatewayRow(
                        icon: "info.circle",
                        title: macGatewayL("本机暂无可直接切换的服务商"),
                        detail: macGatewayL("需在本机启用 OpenAI / Claude 协议服务商并填写 API Key，也可使用下方手动切换")
                    ) {
                        EmptyView()
                    }
                    MacGatewayRowDivider()
                }

                MacGatewayRow(
                    icon: "slider.horizontal.3",
                    title: macGatewayL("手动切换云端模型"),
                    detail: macGatewayL("自定义服务商协议、模型 ID、Base URL 与 API Key"),
                    action: { openManualSheet(.model) }
                ) {
                    MacGatewayChevron()
                }
            }
            MacGatewaySectionFooter(
                text: macGatewayL("选择目标服务商与模型后点击「切换并使用」即可生效；云端仅保存 Key 状态，不回显密钥内容。")
            )
        }
    }

    private func primaryProviderMenuRow(_ draft: IOSCloudImportDraft) -> some View {
        let currentName = draft.selectedProvider?.name ?? macGatewayL("选择本机可用服务商")
        return Menu {
            ForEach(draft.exportableProviders) { provider in
                Button {
                    var next = draft
                    next.providerId = provider.providerId
                    next.modelUuid = provider.defaultModelUuid
                    self.draft = next
                } label: {
                    HStack {
                        Text(verbatim: "\(provider.name) · \(provider.kind.rawValue)")
                        if draft.providerId == provider.providerId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                MacGatewayIconPlate(icon: "arrow.triangle.2.circlepath")
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: macGatewayL("目标服务商"))
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                    Text(verbatim: macGatewayL("从本机已就绪的服务商中选择"))
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                }
                Spacer(minLength: 8)
                Text(verbatim: currentName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AmberTheme.accent)
                MacGatewayChevron()
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
    }

    private func modelPickerRow(_ provider: IOSCloudProviderExportItem, draft: IOSCloudImportDraft) -> some View {
        let current = draft.selectedModel?.displayName ?? macGatewayL("选择模型")
        return Menu {
            ForEach(provider.chatModels) { model in
                Button {
                    var next = draft
                    next.modelUuid = model.uuid
                    self.draft = next
                } label: {
                    HStack {
                        Text(verbatim: "\(model.displayName) (\(model.modelId))")
                        if draft.selectedModel?.uuid == model.uuid {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                MacGatewayIconPlate(icon: "sparkles")
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: macGatewayL("目标模型")).font(.body).foregroundStyle(AmberTheme.foreground)
                    Text(verbatim: provider.name).font(.caption).foregroundStyle(AmberTheme.muted)
                }
                Spacer(minLength: 8)
                Text(verbatim: current).font(.subheadline.weight(.medium)).foregroundStyle(AmberTheme.accent)
                MacGatewayChevron()
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
    }

    private func inlineTransitionSummaryRow(_ transition: IOSCloudModelTransitionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: macGatewayL("当前："))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AmberTheme.muted)
                Text(verbatim: transition.currentSummaryLine)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }
            HStack(spacing: 6) {
                Text(verbatim: macGatewayL("目标："))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                Text(verbatim: transition.targetSummaryLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func switchSelectedModelActionRow(
        selectedProvider: IOSCloudProviderExportItem,
        selectedModel: IOSCloudProviderExportItem.ChatModel?,
        transition: IOSCloudModelTransitionSummary
    ) -> some View {
        let modelName = selectedModel?.displayName ?? selectedModel?.modelId ?? ""
        let buttonTitle = transition.changesEndpointOrModel
            ? macGatewayL("切换并使用「\(selectedProvider.name) · \(modelName)」")
            : macGatewayL("重新同步「\(selectedProvider.name) · \(modelName)」与 Key")
        let buttonDetail = transition.changesEndpointOrModel
            ? macGatewayL("核对「当前 → 目标」配置并加密同步到云端")
            : macGatewayL("当前所选与云端一致；可点此重新同步本机 Key，或在上方选择其他服务商/模型")
        return MacGatewayRow(
            icon: "checkmark.circle.fill",
            title: buttonTitle,
            detail: buttonDetail,
            action: {
                previewSnapshot = store.cloudConfig
                importError = nil
                presentingModelPreview = true
            }
        ) {
            if store.cloudImporting {
                ProgressView()
            } else {
                Text(verbatim: macGatewayL("切换并使用"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AmberTheme.accentTint, in: Capsule())
            }
        }
    }

    // MARK: - Cloud search

    private var remoteSearchSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("云端联网搜索"))
            AmberFormGroup {
                if let config = store.cloudConfig {
                    if !config.searchSources.isEmpty {
                        valueRow(icon: "magnifyingglass", title: macGatewayL("启用搜索源"),
                                 value: config.searchSources
                                    .map(IOSCloudConfigWire.sourceDisplayName(for:)).joined(separator: " → "))
                        MacGatewayRowDivider()
                        valueRow(icon: "arrow.triangle.swap", title: macGatewayL("调用策略"),
                                 value: config.searchMode == "aggregate" ? macGatewayL("聚合所有源") : macGatewayL("按顺序回退"))
                    } else {
                        MacGatewayRow(icon: "magnifyingglass", title: macGatewayL("云端未配置搜索"),
                                      detail: remoteHint) {
                            EmptyView()
                        }
                    }
                    let keySearchItems = config.search.filter(\.requiresKey)
                    if !keySearchItems.isEmpty {
                        MacGatewayRowDivider()
                        valueRow(
                            icon: "key.horizontal",
                            title: macGatewayL("付费搜索 Key"),
                            value: keySearchItems.map { item in
                                "\(item.name) " + (item.keyConfigured ? macGatewayL("已配置") : macGatewayL("未配置"))
                            }.joined(separator: " · ")
                        )
                    }
                } else {
                    MacGatewayRow(icon: "magnifyingglass", title: macGatewayL("云端未配置搜索"),
                                  detail: remoteHint) {
                        EmptyView()
                    }
                }
                MacGatewayRowDivider()
                MacGatewayRow(icon: "key.horizontal", title: macGatewayL("更新 Exa / Brave 搜索 Key"),
                              detail: macGatewayL("支持长按「粘贴」或 ⌘V 填入长 API Key"),
                              action: { openManualSheet(.searchKey) }) {
                    MacGatewayChevron()
                }
            }
            MacGatewaySectionFooter(text: macGatewayL("Bing 与 DuckDuckGo 免 Key 可用；Exa / Brave 按需配置云端 Key。"))
        }
    }

    // MARK: - Secondary Entry: Import from this device

    private var importEntrySection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("批量配置同步"))
            AmberFormGroup {
                if let draft {
                    MacGatewayRow(
                        icon: "square.and.arrow.up",
                        title: macGatewayL("从本机批量导入配置"),
                        detail: localImportEntrySummary(for: draft),
                        action: {
                            previewSnapshot = store.cloudConfig
                            importError = nil
                            presentingLocalImport = true
                        }
                    ) {
                        if store.cloudImporting {
                            ProgressView()
                        } else {
                            MacGatewayChevron()
                        }
                    }
                } else {
                    MacGatewayRow(icon: "square.and.arrow.up", title: macGatewayL("读取本机配置…"), detail: "") {
                        ProgressView()
                    }
                }
            }
            if let importError {
                MacGatewaySectionFooter(text: importError, color: .orange)
            } else {
                MacGatewaySectionFooter(text: macGatewayL("将本机已配置的服务商、模型与联网搜索一并同步到云端；Key 仅在确认时加密上传。"))
            }
            if store.cloudImportKeyChanged {
                AmberFormGroup {
                    MacGatewayRow(icon: "exclamationtriangle.triangle", title: macGatewayL("重新信任并导入"),
                                  detail: macGatewayL("清除已固定的旧公钥，下次导入重新验证"),
                                  action: { store.resetCloudImportKeyTrust() }) {
                        Text(verbatim: macGatewayL("重置"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func localImportEntrySummary(for draft: IOSCloudImportDraft) -> String {
        let providerCount = draft.exportableProviders.count
        let searchCount = draft.exportableSearches.count
        if providerCount == 0 && searchCount == 0 {
            let blockedCount = draft.blockedSummaries.reduce(0) { $0 + $1.itemNames.count }
            return blockedCount > 0
                ? macGatewayL("本机暂无可直接导出的配置（\(blockedCount) 项需补齐 Key 或协议受限）")
                : macGatewayL("本机暂无可导出的服务商或搜索配置")
        }
        return macGatewayL("可导入 \(providerCount) 个模型服务商 · \(searchCount) 项联网搜索")
    }

    // MARK: - Helpers

    private func openManualSheet(_ sheet: ManualSheet) {
        manualSnapshot = store.cloudConfig
        importError = nil
        manualSheet = sheet
    }

    private var remoteHint: String {
        if store.cloudConfigLoading { return macGatewayL("正在读取云端配置…") }
        if !store.cloudConfigAvailable { return macGatewayL("云端接口待接入，等待服务端更新") }
        if let error = store.cloudConfigError { return error }
        return macGatewayL("云端还没有保存配置")
    }

    private var refreshButton: some View {
        Button { Task { await store.refreshCloudConfig() } } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AmberTheme.accent)
        .accessibilityLabel(Text(verbatim: macGatewayL("刷新")))
    }

    private func valueRow(icon: String, title: String, value: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                MacGatewayIconPlate(icon: icon)
                Text(verbatim: title).font(.body).foregroundStyle(AmberTheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(verbatim: value).font(.subheadline).foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 40 : 0)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
        .accessibilityElement(children: .combine)
    }

    private enum ManualSheet: Identifiable {
        case model
        case searchKey
        var id: Int { self == .model ? 0 : 1 }
    }
}

// MARK: - Secondary local import sheet (in-place selection + preview)

private struct CloudLocalImportSheet: View {
    @Binding var draft: IOSCloudImportDraft
    let remote: IOSCloudConfigSnapshot?
    let latestRemote: IOSCloudConfigSnapshot?
    let isLoadingRemote: Bool
    @Binding var error: String?
    let importing: Bool
    let onReview: () -> Void
    let onRefresh: () -> Void
    let onConfirm: (IOSCloudImportDraft, Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingPreviewStep = false
    @State private var showingBlockedSummary = false

    private var exportableProviders: [IOSCloudProviderExportItem] { draft.exportableProviders }
    private var exportableSearches: [IOSCloudSearchExportItem] { draft.exportableSearches }
    private var blockedSummaries: [IOSCloudBlockedCategorySummary] { draft.blockedSummaries }
    private var blockedItemCount: Int { blockedSummaries.reduce(0) { $0 + $1.itemNames.count } }

    private var previewReadiness: IOSCloudConfigActionReadiness {
        let transition = draft.modelTransitionSummary(remote: remote ?? latestRemote)
        let blocker: IOSCloudConfigActionReadiness.FormBlocker?
        if !draft.hasSelection {
            blocker = .noSelection
        } else if transition?.requiresNewKeyForDestinationChange == true {
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
                    if showingPreviewStep {
                        previewContent
                    } else {
                        selectionContent
                    }
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(showingPreviewStep ? macGatewayL("确认切换与同步") : macGatewayL("从本机导入配置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if showingPreviewStep {
                        Button(macGatewayL("上一步")) {
                            withAnimation(.snappy(duration: 0.2)) {
                                showingPreviewStep = false
                            }
                        }
                    } else {
                        Button(macGatewayL("关闭")) { dismiss() }
                    }
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

    private var selectionContent: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("可导入的模型服务商"))
            AmberFormGroup {
                if !exportableProviders.isEmpty {
                    ForEach(exportableProviders) { provider in
                        providerRow(provider)
                        if provider.id != exportableProviders.last?.id || draft.selectedProvider != nil {
                            MacGatewayRowDivider()
                        }
                    }
                    if let selectedProvider = draft.selectedProvider {
                        modelPickerRow(selectedProvider)
                    }
                } else {
                    MacGatewayRow(
                        icon: "cpu",
                        title: macGatewayL("本机暂无可导出的模型服务商"),
                        detail: macGatewayL("需为 OpenAI 或 Claude 协议且已在本机填写 API Key")
                    ) {
                        EmptyView()
                    }
                }
            }

            AmberSectionLabel(verbatim: macGatewayL("可导入的联网搜索"))
            AmberFormGroup {
                if !exportableSearches.isEmpty {
                    ForEach(exportableSearches) { search in
                        searchRow(search)
                        if search.id != exportableSearches.last?.id {
                            MacGatewayRowDivider()
                        }
                    }
                } else {
                    MacGatewayRow(
                        icon: "magnifyingglass",
                        title: macGatewayL("本机暂无可导出的搜索服务"),
                        detail: macGatewayL("支持 Bing / DuckDuckGo 免费源或已配置 Key 的 Exa / Brave")
                    ) {
                        EmptyView()
                    }
                }
            }

            if !blockedSummaries.isEmpty {
                blockedSummarySection
            }

            if let error {
                MacGatewaySectionFooter(text: error, color: .orange)
            } else {
                MacGatewaySectionFooter(text: macGatewayL("默认仅勾选本机当前使用的服务商与搜索源；Key 仅在下一步确认后加密上传，不回显密钥。"))
            }

            AmberFormGroup {
                Button {
                    error = nil
                    onReview()
                    withAnimation(.snappy(duration: 0.2)) {
                        showingPreviewStep = true
                    }
                } label: {
                    Text(verbatim: macGatewayL("继续并核对切换项"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(draft.hasSelection && !importing ? AmberTheme.accent : AmberTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!draft.hasSelection || importing)
            }
            .padding(.top, 16)

            if !draft.hasSelection {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: macGatewayL("无法继续：尚未勾选任何要导入的模型或搜索配置"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(verbatim: macGatewayL("下一步：请在上方至少勾选一个模型服务商或联网搜索服务。"))
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .padding(.bottom, 24)
    }

    private func providerRow(_ provider: IOSCloudProviderExportItem) -> some View {
        let selected = draft.providerId == provider.providerId
        let hostText = IOSCloudConfigWire.displayBaseUrl(provider: provider.kind.rawValue, baseUrl: provider.baseUrl)
        let detail = [provider.kind.rawValue, hostText].filter { !$0.isEmpty }.joined(separator: " · ")
        return MacGatewayRow(
            icon: "cpu",
            title: provider.name,
            detail: detail,
            action: { toggleProvider(provider) }
        ) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? AmberTheme.accent : AmberTheme.muted)
        }
    }

    private func toggleProvider(_ provider: IOSCloudProviderExportItem) {
        if draft.providerId == provider.providerId {
            draft.providerId = nil
            draft.modelUuid = nil
        } else {
            draft.providerId = provider.providerId
            draft.modelUuid = provider.defaultModelUuid
        }
    }

    private func modelPickerRow(_ provider: IOSCloudProviderExportItem) -> some View {
        let current = draft.selectedModel?.displayName ?? macGatewayL("选择模型")
        return Menu {
            ForEach(provider.chatModels) { model in
                Button("\(model.displayName) (\(model.modelId))") {
                    draft.modelUuid = model.uuid
                }
            }
        } label: {
            HStack(spacing: 12) {
                MacGatewayIconPlate(icon: "sparkles")
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: macGatewayL("目标模型")).font(.body).foregroundStyle(AmberTheme.foreground)
                    Text(verbatim: provider.name).font(.caption).foregroundStyle(AmberTheme.muted)
                }
                Spacer(minLength: 8)
                Text(verbatim: current).font(.subheadline).foregroundStyle(AmberTheme.accent)
                MacGatewayChevron()
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
    }

    private func searchRow(_ search: IOSCloudSearchExportItem) -> some View {
        let selected = draft.selectedSearchIds.contains(search.serviceId)
        let mappedSources = search.cloudSources.map(IOSCloudConfigWire.sourceDisplayName(for:)).joined(separator: "、")
        let detail = search.isSelected
            ? "\(mappedSources) · \(macGatewayL("本机当前使用"))"
            : mappedSources
        return MacGatewayRow(
            icon: "magnifyingglass",
            title: search.name,
            detail: detail,
            action: { toggleSearch(search) }
        ) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? AmberTheme.accent : AmberTheme.muted)
        }
    }

    private func toggleSearch(_ search: IOSCloudSearchExportItem) {
        if draft.selectedSearchIds.contains(search.serviceId) {
            draft.selectedSearchIds.remove(search.serviceId)
        } else {
            draft.selectedSearchIds.insert(search.serviceId)
        }
    }

    private var blockedSummarySection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("不可导出项说明"))
            AmberFormGroup {
                MacGatewayRow(
                    icon: "info.circle",
                    title: macGatewayL("已略过 \(blockedItemCount) 项不可导出的本机配置"),
                    detail: showingBlockedSummary
                        ? macGatewayL("收起分类说明")
                        : macGatewayL("按需查看不支持协议、缺 API Key 或 OAuth 仅限本机的项目"),
                    action: {
                        withAnimation(.snappy(duration: 0.2)) {
                            showingBlockedSummary.toggle()
                        }
                    }
                ) {
                    Image(systemName: showingBlockedSummary ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted)
                }

                if showingBlockedSummary {
                    ForEach(blockedSummaries) { group in
                        MacGatewayRowDivider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "\(group.title)：\(group.itemNames.joined(separator: "、"))")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AmberTheme.foreground)
                            Text(verbatim: group.explanation)
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private var previewContent: some View {
        let effectiveRemote = previewReadiness.effectiveReviewed
        let entries = draft.previewEntries(remote: effectiveRemote)
        let transition = draft.modelTransitionSummary(remote: effectiveRemote)
        let actionTitle = transition != nil
            ? macGatewayL("切换并使用")
            : macGatewayL("导入并启用所选搜索")
        return VStack(spacing: 0) {
            if let transition {
                CloudModelTransitionGroup(transition: transition)
            }
            AmberSectionLabel(verbatim: macGatewayL("将同步的项目"))
            AmberFormGroup {
                ForEach(entries) { entry in
                    CloudImportPreviewEntryRow(entry: entry)
                    if entry.id != entries.last?.id {
                        MacGatewayRowDivider()
                    }
                }
            }
            MacGatewaySectionFooter(
                text: macGatewayL("来源：本机 · 标记「替换」的项目会覆盖云端现有配置；Key 在内存中加密封装后经已配对连接上传，云端只保存状态不回显。")
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
                title: actionTitle,
                readiness: previewReadiness,
                isSubmitting: importing,
                onRefresh: onRefresh
            ) {
                onConfirm(draft, previewReadiness.effectiveExpectedRevision)
            }
        }
        .padding(.bottom, 24)
    }
}
