import SwiftUI

/// Settings › Amber · 云端 › 云端配置 — prioritizes selecting the cloud's active
/// provider/model as the primary task, while keeping "从本机导入配置" as an
/// independent secondary entry over the paired HTTPS/SPKI channel per
/// docs/architecture/cloud-configuration-api.md (JWE-sealed payloads, kid
/// pinning, explicit key delete actions, never echoing secrets).
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
                            remoteModelSection
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
                    error: importError,
                    importing: store.cloudImporting,
                    onReview: { previewSnapshot = store.cloudConfig; importError = nil },
                    onConfirm: {
                        Task {
                            let error = await store.applyCloudImport(
                                draft: modelDraft, sharedSettings: sharedSettings,
                                expectedRevision: previewSnapshot?.revision)
                            if let error { importError = error } else { presentingModelPreview = false }
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
                    error: $importError,
                    importing: store.cloudImporting,
                    onReview: { previewSnapshot = store.cloudConfig; importError = nil },
                    onConfirm: { currentDraft in
                        Task {
                            let error = await store.applyCloudImport(
                                draft: currentDraft, sharedSettings: sharedSettings,
                                expectedRevision: previewSnapshot?.revision)
                            if let error {
                                importError = error
                            } else {
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
                    error: importError,
                    importing: store.cloudImporting,
                    onReview: { manualSnapshot = store.cloudConfig; importError = nil },
                    onApply: { section, extras in
                        Task { await applyManual(bundle: .init(model: section, search: [], freeSources: [], extraCredentials: extras)) }
                    }
                )
            case .searchKey:
                CloudManualSearchSheet(
                    remote: manualSnapshot,
                    latestRemote: store.cloudConfig,
                    error: importError,
                    importing: store.cloudImporting,
                    onReview: { manualSnapshot = store.cloudConfig; importError = nil },
                    onApply: { entry, extras in
                        Task { await applyManual(bundle: .init(model: nil, search: entry.map { [$0] } ?? [], freeSources: [], extraCredentials: extras)) }
                    }
                )
            }
        }
    }

    private func applyManual(bundle: IOSCloudConfigBundle) async {
        if let error = await store.applyCloudBundle(
            bundle, expectedRevision: manualSnapshot?.revision) {
            importError = error
        } else {
            manualSheet = nil
        }
    }

    // MARK: - Header

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

    // MARK: - Primary Task: Cloud Provider & Model Selection

    private var remoteModelSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("云端当前模型"))
            AmberFormGroup {
                if let model = store.cloudConfig?.model,
                   !model.provider.isEmpty || !model.modelId.isEmpty {
                    valueRow(icon: "cpu", title: macGatewayL("当前服务商"), value: providerDisplayName(model.provider))
                    MacGatewayRowDivider()
                    valueRow(icon: "sparkles", title: macGatewayL("当前模型"), value: model.modelId)
                    MacGatewayRowDivider()
                    valueRow(icon: "network", title: "Base URL", value: host(of: model.baseUrl))
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

                if let draft, !draft.exportableProviders.isEmpty {
                    MacGatewayRowDivider()
                    primaryProviderMenuRow(draft)
                    if let selectedProvider = draft.selectedProvider {
                        MacGatewayRowDivider()
                        modelPickerRow(selectedProvider, draft: draft)
                        if shouldShowApplySelectedModel(selectedProvider: selectedProvider, selectedModel: draft.selectedModel) {
                            MacGatewayRowDivider()
                            applySelectedModelRow(selectedProvider: selectedProvider, selectedModel: draft.selectedModel)
                        }
                    }
                }

                MacGatewayRowDivider()
                MacGatewayRow(icon: "slider.horizontal.3",
                              title: macGatewayL("手动设置云端模型"),
                              detail: macGatewayL("自定义云端 Provider、模型 ID、Base URL 与 API Key"),
                              action: { openManualSheet(.model) }) {
                    MacGatewayChevron()
                }
            }
            footerForCloudSection(fallback: macGatewayL("优先在此选择或切换云端当前使用的 provider / model；云端仅保存 Key 配置状态，不回显密钥内容。"))
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
                    Text(verbatim: macGatewayL("快速切换服务商"))
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                    Text(verbatim: macGatewayL("来自本机已就绪的兼容服务商"))
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                }
                Spacer(minLength: 8)
                Text(verbatim: currentName)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.accent)
                MacGatewayChevron()
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
    }

    private func shouldShowApplySelectedModel(
        selectedProvider: IOSCloudProviderExportItem,
        selectedModel: IOSCloudProviderExportItem.ChatModel?
    ) -> Bool {
        guard let selectedModel else { return false }
        guard let remoteModel = store.cloudConfig?.model else { return true }
        return remoteModel.provider.lowercased() != selectedProvider.kind.rawValue
            || remoteModel.modelId != selectedModel.modelId
            || !remoteModel.keyConfigured
    }

    private func applySelectedModelRow(
        selectedProvider: IOSCloudProviderExportItem,
        selectedModel: IOSCloudProviderExportItem.ChatModel?
    ) -> some View {
        let modelName = selectedModel?.displayName ?? selectedModel?.modelId ?? ""
        return MacGatewayRow(
            icon: "checkmark.circle",
            title: macGatewayL("将「\(selectedProvider.name) · \(modelName)」设为云端模型"),
            detail: macGatewayL("核对并加密同步该服务商与模型到云端"),
            action: {
                previewSnapshot = store.cloudConfig
                importError = nil
                presentingModelPreview = true
            }
        ) {
            if store.cloudImporting {
                ProgressView()
            } else {
                MacGatewayChevron()
            }
        }
    }

    private func providerDisplayName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "openai": return "OpenAI 兼容 (openai)"
        case "claude": return "Claude (claude)"
        default: return raw
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
                MacGatewayRow(icon: "key.horizontal", title: macGatewayL("手动更新搜索 Key"),
                              detail: macGatewayL("为 Exa 或 Brave 单独设置或清理云端 API Key"),
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
            AmberSectionLabel(verbatim: macGatewayL("配置同步"))
            AmberFormGroup {
                if let draft {
                    MacGatewayRow(
                        icon: "square.and.arrow.up",
                        title: macGatewayL("从本机导入配置"),
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
                MacGatewaySectionFooter(text: macGatewayL("将本机已配置的服务商、模型与联网搜索批量导入到云端；Key 仅在确认时加密上传。"))
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
                        Text(verbatim: model.displayName)
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
                    Text(verbatim: macGatewayL("选择模型")).font(.body).foregroundStyle(AmberTheme.foreground)
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

    private func footerForCloudSection(fallback: String) -> some View {
        Group {
            if let notice = store.notice {
                MacGatewaySectionFooter(text: notice.text, color: notice.isError ? .orange : AmberTheme.muted)
            } else if let error = store.cloudConfigError {
                MacGatewaySectionFooter(text: error, color: .orange)
            } else {
                MacGatewaySectionFooter(text: fallback)
            }
        }
    }

    private func host(of baseUrl: String) -> String {
        let trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return macGatewayL("默认") }
        return URLComponents(string: trimmed)?.host ?? trimmed
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

// MARK: - Secondary local import sheet (in-place selection + preview, no nested sheet)

private struct CloudLocalImportSheet: View {
    @Binding var draft: IOSCloudImportDraft
    let remote: IOSCloudConfigSnapshot?
    let latestRemote: IOSCloudConfigSnapshot?
    @Binding var error: String?
    let importing: Bool
    let onReview: () -> Void
    let onConfirm: (IOSCloudImportDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingPreviewStep = false
    @State private var showingBlockedSummary = false

    private var exportableProviders: [IOSCloudProviderExportItem] {
        draft.exportableProviders
    }

    private var exportableSearches: [IOSCloudSearchExportItem] {
        draft.exportableSearches
    }

    private var blockedSummaries: [IOSCloudBlockedCategorySummary] {
        draft.blockedSummaries
    }

    private var blockedItemCount: Int {
        blockedSummaries.reduce(0) { $0 + $1.itemNames.count }
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
            .navigationTitle(showingPreviewStep ? macGatewayL("确认导入") : macGatewayL("从本机导入配置"))
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
                    withAnimation(.snappy(duration: 0.2)) {
                        showingPreviewStep = true
                    }
                } label: {
                    Text(verbatim: macGatewayL("继续并核对导入项"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(draft.hasSelection ? AmberTheme.accent : AmberTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!draft.hasSelection || importing)
            }
            .padding(.top, 16)
        }
        .padding(.bottom, 24)
    }

    private func providerRow(_ provider: IOSCloudProviderExportItem) -> some View {
        let selected = draft.providerId == provider.providerId
        let hostText = host(of: provider.baseUrl)
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
                Button(model.displayName) {
                    draft.modelUuid = model.uuid
                }
            }
        } label: {
            HStack(spacing: 12) {
                MacGatewayIconPlate(icon: "sparkles")
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: macGatewayL("导入模型")).font(.body).foregroundStyle(AmberTheme.foreground)
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
        let entries = draft.previewEntries(remote: remote)
        return VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("将导入的项目"))
            AmberFormGroup {
                ForEach(entries) { entry in
                    previewEntryRow(entry)
                    if entry.id != entries.last?.id {
                        MacGatewayRowDivider()
                    }
                }
            }
            MacGatewaySectionFooter(text: macGatewayL("来源：本机 · 标记「替换」的项目会覆盖云端现有配置；Key 在内存中加密封装后经已配对连接上传，云端只保存状态不回显。"))
            CloudConfigRevisionNotice(reviewed: remote, latest: latestRemote, error: error, onReview: onReview)
            AmberFormGroup {
                Button {
                    onConfirm(draft)
                } label: {
                    ZStack {
                        if importing {
                            ProgressView()
                        } else {
                            Text(verbatim: macGatewayL("加密并导入"))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AmberTheme.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(importing || remote?.hasSameVersion(as: latestRemote) != true)
            }
            .padding(.top, 20)
        }
        .padding(.bottom, 24)
    }

    private func previewEntryRow(_ entry: IOSCloudImportPreviewEntry) -> some View {
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

    private func host(of baseUrl: String) -> String {
        let trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return macGatewayL("默认") }
        return URLComponents(string: trimmed)?.host ?? trimmed
    }
}

// MARK: - Import preview sheet

/// Confirmation step: shows only names, model, source ("本机") and which cloud
/// slots get replaced — never key material. Confirm is the explicit user action
/// that resolves credentials and uploads.
private struct CloudImportPreviewSheet: View {
    let draft: IOSCloudImportDraft
    let remote: IOSCloudConfigSnapshot?
    let latestRemote: IOSCloudConfigSnapshot?
    let error: String?
    let importing: Bool
    let onReview: () -> Void
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let entries = draft.previewEntries(remote: remote)
        return NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        AmberSectionLabel(verbatim: macGatewayL("将导入的项目"))
                        AmberFormGroup {
                            ForEach(entries) { entry in
                                entryRow(entry)
                                if entry.id != entries.last?.id {
                                    MacGatewayRowDivider()
                                }
                            }
                        }
                        MacGatewaySectionFooter(text: macGatewayL("来源：本机 · 标记「替换」的项目会覆盖云端现有配置；Key 在内存中加密封装后经已配对连接上传，云端只保存状态不回显。"))
                        CloudConfigRevisionNotice(reviewed: remote, latest: latestRemote, error: error, onReview: onReview)
                        confirmGroup
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(macGatewayL("确认导入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(macGatewayL("取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func entryRow(_ entry: IOSCloudImportPreviewEntry) -> some View {
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

    private var confirmGroup: some View {
        AmberFormGroup {
            Button(action: onConfirm) {
                ZStack {
                    if importing {
                        ProgressView()
                    } else {
                        Text(verbatim: macGatewayL("加密并导入"))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AmberTheme.accent)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(importing || remote?.hasSameVersion(as: latestRemote) != true)
        }
        .padding(.top, 20)
    }
}

// MARK: - Manual sheets

private struct CloudManualModelSheet: View {
    let remote: IOSCloudConfigSnapshot?
    let latestRemote: IOSCloudConfigSnapshot?
    let error: String?
    let importing: Bool
    let onReview: () -> Void
    /// (model patch, standalone credential actions). A nil model patch means
    /// only the credentials change — e.g. the explicit key deletion.
    let onApply: (IOSCloudConfigBundle.ModelSection?, [String: IOSCloudConfigBundle.CredentialAction]) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The contract accepts openai/claude protocols only.
    private static let kinds: [IOSCloudProviderKind] = [.openAI, .claude]

    @State private var kind: IOSCloudProviderKind
    @State private var baseUrl: String
    @State private var modelId: String
    @State private var apiKey = ""
    @State private var confirmingDelete = false

    init(remote: IOSCloudConfigSnapshot?, latestRemote: IOSCloudConfigSnapshot?, error: String?, importing: Bool, onReview: @escaping () -> Void, onApply: @escaping (IOSCloudConfigBundle.ModelSection?, [String: IOSCloudConfigBundle.CredentialAction]) -> Void) {
        self.remote = remote
        self.latestRemote = latestRemote
        self.error = error
        self.importing = importing
        self.onReview = onReview
        self.onApply = onApply
        _kind = State(initialValue: (remote?.model?.provider).flatMap(IOSCloudProviderKind.init(rawValue:)) ?? .openAI)
        _baseUrl = State(initialValue: remote?.model?.baseUrl ?? "")
        _modelId = State(initialValue: remote?.model?.modelId ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        AmberSectionLabel(verbatim: macGatewayL("云端模型"))
                        AmberFormGroup {
                            kindMenu
                            MacGatewayRowDivider()
                            CloudConfigFieldRow(title: "Base URL", text: $baseUrl,
                                                placeholder: "https://api.openai.com/v1", monospace: true)
                            MacGatewayRowDivider()
                            CloudConfigFieldRow(title: macGatewayL("模型 ID"), text: $modelId,
                                                placeholder: "deepseek-flash", monospace: true)
                            MacGatewayRowDivider()
                            CloudConfigFieldRow(title: "API Key", text: $apiKey,
                                                placeholder: macGatewayL("留空则保留云端现有 Key"), isSecure: true)
                        }
                        MacGatewaySectionFooter(text: macGatewayL("Key 在内存中加密封装后上传；留空不会改变云端已保存的 Key。切换服务商或地址时云端会要求同时提供新 Key 或删除旧 Key。"))
                        CloudConfigRevisionNotice(reviewed: remote, latest: latestRemote, error: error, onReview: onReview)
                        applyGroup(disabled: modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if remote?.model?.keyConfigured == true {
                            deleteGroup
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(macGatewayL("手动更新模型"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(macGatewayL("取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var kindMenu: some View {
        Menu {
            ForEach(Self.kinds, id: \.rawValue) { option in
                Button(option.rawValue) { kind = option }
            }
        } label: {
            HStack(spacing: 12) {
                MacGatewayIconPlate(icon: "cpu")
                Text(verbatim: macGatewayL("Provider")).font(.body).foregroundStyle(AmberTheme.foreground)
                Spacer(minLength: 8)
                Text(verbatim: kind.rawValue).font(.subheadline).foregroundStyle(AmberTheme.accent)
                MacGatewayChevron()
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
    }

    private func applyGroup(disabled: Bool) -> some View {
        AmberFormGroup {
            Button {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                onApply(IOSCloudConfigBundle.ModelSection(
                    providerKind: kind.rawValue,
                    modelId: modelId.trimmingCharacters(in: .whitespacesAndNewlines),
                    baseUrl: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                    credential: trimmed.isEmpty ? .keep : .replace(trimmed)
                ), [:])
            } label: {
                ZStack {
                    if importing { ProgressView() }
                    else { Text(verbatim: macGatewayL("加密并更新")).font(.body.weight(.semibold)).foregroundStyle(AmberTheme.accent) }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled || importing || remote?.hasSameVersion(as: latestRemote) != true)
        }
        .padding(.top, 20)
    }

    /// Explicit key deletion — a separate contract action, never conflated with
    /// an empty field. The cloud keeps working; tasks report "未配置".
    private var deleteGroup: some View {
        AmberFormGroup {
            Button(role: .destructive) { confirmingDelete = true } label: {
                Text(verbatim: macGatewayL("删除云端已保存的模型 Key"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(importing || remote?.hasSameVersion(as: latestRemote) != true)
            .confirmationDialog(macGatewayL("删除云端模型 Key？配置保持不变，后续任务会报告未配置。"),
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button(macGatewayL("删除 Key"), role: .destructive) {
                    onApply(nil, [IOSCloudConfigWire.modelCredentialKey: .delete])
                }
            }
        }
        .padding(.top, 12)
    }
}

private struct CloudManualSearchSheet: View {
    let remote: IOSCloudConfigSnapshot?
    let latestRemote: IOSCloudConfigSnapshot?
    let error: String?
    let importing: Bool
    let onReview: () -> Void
    /// (search entry, standalone credential actions). The entry is key-only:
    /// `includeInConfiguration = false` keeps the cloud's source list as is.
    let onApply: (IOSCloudConfigBundle.SearchEntry?, [String: IOSCloudConfigBundle.CredentialAction]) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Key-carrying sources in the contract's whitelist (bing/duckduckgo are
    /// free and take no key).
    private static let supportedTypes: [(type: String, name: String)] = [
        ("exa", "Exa"), ("brave", "Brave"),
    ]

    @State private var type = "exa"
    @State private var apiKey = ""
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        AmberSectionLabel(verbatim: macGatewayL("搜索服务"))
                        AmberFormGroup {
                            typeMenu
                            MacGatewayRowDivider()
                            CloudConfigFieldRow(title: "API Key", text: $apiKey,
                                                placeholder: macGatewayL("输入该服务的 API Key"), isSecure: true)
                        }
                        MacGatewaySectionFooter(text: remoteKeyState + macGatewayL(" · Key 在内存中加密封装后上传，云端只保存状态不回显。"))
                        CloudConfigRevisionNotice(reviewed: remote, latest: latestRemote, error: error, onReview: onReview)
                        applyGroup(disabled: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if remoteKeyConfigured {
                            deleteGroup
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(macGatewayL("手动更新搜索 Key"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(macGatewayL("取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var typeMenu: some View {
        Menu {
            ForEach(Self.supportedTypes, id: \.type) { option in
                Button(option.name + " · " + option.type) { type = option.type }
            }
        } label: {
            HStack(spacing: 12) {
                MacGatewayIconPlate(icon: "magnifyingglass")
                Text(verbatim: macGatewayL("服务")).font(.body).foregroundStyle(AmberTheme.foreground)
                Spacer(minLength: 8)
                Text(verbatim: name(for: type)).font(.subheadline).foregroundStyle(AmberTheme.accent)
                MacGatewayChevron()
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
    }

    private var remoteKeyConfigured: Bool {
        remote?.search.first { $0.type == type }?.keyConfigured == true
    }

    private var remoteKeyState: String {
        remoteKeyConfigured ? macGatewayL("云端已有 Key，将替换") : macGatewayL("云端未配置该服务 Key")
    }

    private func name(for type: String) -> String {
        Self.supportedTypes.first { $0.type == type }?.name ?? type
    }

    private func applyGroup(disabled: Bool) -> some View {
        AmberFormGroup {
            Button {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                onApply(IOSCloudConfigBundle.SearchEntry(
                    type: type,
                    name: name(for: type),
                    enabled: false,
                    credential: trimmed.isEmpty ? .keep : .replace(trimmed),
                    includeInConfiguration: false
                ), [:])
            } label: {
                ZStack {
                    if importing { ProgressView() }
                    else { Text(verbatim: macGatewayL("加密并更新")).font(.body.weight(.semibold)).foregroundStyle(AmberTheme.accent) }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled || importing || remote?.hasSameVersion(as: latestRemote) != true)
        }
        .padding(.top, 20)
    }

    /// Explicit deletion of the cloud's stored key for this source — a separate
    /// contract action, not an empty replace.
    private var deleteGroup: some View {
        AmberFormGroup {
            Button(role: .destructive) { confirmingDelete = true } label: {
                Text(verbatim: macGatewayL("删除云端已保存的 \(name(for: type)) Key"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(importing || remote?.hasSameVersion(as: latestRemote) != true)
            .confirmationDialog(macGatewayL("删除云端 \(name(for: type)) Key？该源将因缺少 Key 而不可用。"),
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button(macGatewayL("删除 Key"), role: .destructive) {
                    if let key = IOSCloudConfigWire.credentialKey(for: type) {
                        onApply(nil, [key: .delete])
                    }
                }
            }
        }
        .padding(.top, 12)
    }
}

/// Labeled text/secure field row matching the gateway form style.
private struct CloudConfigFieldRow: View {
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
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(monospace ? .system(size: 14, weight: .regular, design: .monospaced) : .body)
            .foregroundStyle(AmberTheme.foreground)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 58)
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
    }
}

/// A refresh may reveal a conflict, but only this explicit action accepts its revision.
/// The editor's fields (including a typed Key and its destination) remain intact.
private struct CloudConfigRevisionNotice: View {
    let reviewed: IOSCloudConfigSnapshot?
    let latest: IOSCloudConfigSnapshot?
    let error: String?
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Text(verbatim: error).font(.caption).foregroundStyle(.orange)
            }
            if reviewed?.hasSameVersion(as: latest) != true {
                if let latest {
                    Text(verbatim: macGatewayL("云端配置已变化，请核对后继续"))
                        .font(.subheadline.weight(.semibold))
                    if let reviewed, reviewed.gatewayId != latest.gatewayId {
                        Text(verbatim: macGatewayL("云端连接已更换，请核对当前配对主机。"))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let reviewed {
                        Text(verbatim: macGatewayL("之前：") + summary(reviewed))
                            .font(.caption).foregroundStyle(AmberTheme.muted)
                    }
                    Text(verbatim: macGatewayL("当前：") + summary(latest)).font(.caption)
                    Text(verbatim: macGatewayL("继续后仍提交本页编辑；模型 Key 发送到本页填写的地址。"))
                        .font(.caption).foregroundStyle(AmberTheme.muted)
                    Button(macGatewayL("确认此版本，保留编辑"), action: onReview)
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text(verbatim: macGatewayL("尚未读取云端状态，请返回配置页刷新后重试。"))
                        .font(.caption).foregroundStyle(AmberTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, error != nil || reviewed?.hasSameVersion(as: latest) != true ? 12 : 0)
    }

    private func summary(_ snapshot: IOSCloudConfigSnapshot) -> String {
        let model = snapshot.model.map {
            [$0.provider, $0.modelId, $0.baseUrl.isEmpty ? macGatewayL("默认地址") : $0.baseUrl]
                .joined(separator: " · ")
        } ?? macGatewayL("未配置模型")
        let keys = [("modelApiKey", "模型 Key"), ("exaApiKey", "Exa Key"), ("braveApiKey", "Brave Key")].map {
            macGatewayL($0.1) + ": " + (snapshot.keyConfigured(forCredentialKey: $0.0) ? macGatewayL("已配置") : macGatewayL("未配置"))
        }.joined(separator: " · ")
        let mode = snapshot.searchMode == "aggregate" ? macGatewayL("聚合所有源") : macGatewayL("按顺序回退")
        return model + "\n" + snapshot.searchSources.joined(separator: " → ") + " · " + mode + "\n" + keys
    }
}
