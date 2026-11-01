import SwiftUI

/// Settings › Mac Gateway › 云端配置 — shows the cloud's provider/model/search
/// state (non-secret) and imports this device's configuration over the paired
/// HTTPS/SPKI channel per docs/architecture/cloud-configuration-api.md:
/// JWE-sealed payloads, kid pinning, explicit key delete actions.
struct CloudConfigSettingsView: View {
    let sharedSettings: IOSSharedSettingsStore
    private let store = MacGatewayStore.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(RouterPath.self) private var router

    @State private var draft: IOSCloudImportDraft?
    @State private var presentingPreview = false
    @State private var manualSheet: ManualSheet?
    @State private var importError: String?

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
                            importSection
                            manualSection
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
        .sheet(isPresented: $presentingPreview) {
            if let draft {
                CloudImportPreviewSheet(
                    draft: draft,
                    remote: store.cloudConfig,
                    importing: store.cloudImporting,
                    onConfirm: {
                        Task {
                            let error = await store.applyCloudImport(
                                draft: draft, sharedSettings: sharedSettings,
                                expectedRevision: store.cloudConfig?.revision)
                            if let error { importError = error } else { presentingPreview = false }
                        }
                    }
                )
            }
        }
        .sheet(item: $manualSheet) { sheet in
            switch sheet {
            case .model:
                CloudManualModelSheet(
                    remote: store.cloudConfig,
                    importing: store.cloudImporting,
                    onApply: { section, extras in
                        Task { await applyManual(bundle: .init(model: section, search: [], freeSources: [], extraCredentials: extras)) }
                    }
                )
            case .searchKey:
                CloudManualSearchSheet(
                    remote: store.cloudConfig,
                    importing: store.cloudImporting,
                    onApply: { entry, extras in
                        Task { await applyManual(bundle: .init(model: nil, search: entry.map { [$0] } ?? [], freeSources: [], extraCredentials: extras)) }
                    }
                )
            }
        }
    }

    private func applyManual(bundle: IOSCloudConfigBundle) async {
        if let error = await store.applyCloudBundle(
            bundle, expectedRevision: store.cloudConfig?.revision) {
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
            Color.clear.frame(width: 44, height: 44)
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
                MacGatewayRow(icon: "desktopcomputer", title: macGatewayL("先配对 Mac"),
                              detail: macGatewayL("云端配置通过已配对的加密连接管理"),
                              action: { dismiss() }) {
                    MacGatewayChevron()
                }
            }
            MacGatewaySectionFooter(text: macGatewayL("回到上一页扫码或粘贴配对链接。"))
        }
    }

    // MARK: - Cloud model

    private var remoteModelSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("云端模型"))
            AmberFormGroup {
                if let model = store.cloudConfig?.model {
                    valueRow(icon: "cpu", title: macGatewayL("服务商"), value: model.provider)
                    MacGatewayRowDivider()
                    valueRow(icon: "sparkles", title: macGatewayL("模型"), value: model.modelId)
                    MacGatewayRowDivider()
                    valueRow(icon: "network", title: "Base URL", value: host(of: model.baseUrl))
                    MacGatewayRowDivider()
                    valueRow(icon: "key", title: "API Key",
                             value: model.keyConfigured ? macGatewayL("已配置") : macGatewayL("未配置"))
                } else {
                    MacGatewayRow(icon: "cpu", title: macGatewayL("云端未配置模型"),
                                  detail: remoteHint) {
                        refreshButton
                    }
                }
            }
            footerForCloudSection(fallback: macGatewayL("云端只保存 Key 是否已配置的状态，不回显密钥内容。"))
        }
    }

    // MARK: - Cloud search

    private var remoteSearchSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("云端搜索"))
            AmberFormGroup {
                if let config = store.cloudConfig {
                    if !config.searchSources.isEmpty {
                        valueRow(icon: "list.number", title: macGatewayL("源顺序"),
                                 value: config.searchSources
                                    .map(IOSCloudConfigWire.sourceDisplayName(for:)).joined(separator: " → "))
                        MacGatewayRowDivider()
                        valueRow(icon: "arrow.triangle.swap", title: macGatewayL("策略"),
                                 value: config.searchMode == "aggregate" ? macGatewayL("聚合所有源") : macGatewayL("按顺序回退"))
                        MacGatewayRowDivider()
                    }
                    ForEach(config.search) { search in
                        searchRemoteRow(search)
                        if search.id != config.search.last?.id {
                            MacGatewayRowDivider()
                        }
                    }
                    if config.search.isEmpty {
                        MacGatewayRow(icon: "magnifyingglass", title: macGatewayL("云端未配置搜索"),
                                      detail: remoteHint) {
                            EmptyView()
                        }
                    }
                } else {
                    MacGatewayRow(icon: "magnifyingglass", title: macGatewayL("云端未配置搜索"),
                                  detail: remoteHint) {
                        EmptyView()
                    }
                }
            }
            MacGatewaySectionFooter(text: macGatewayL("免费源无需 Key；Exa/Brave 需各自配置 Key。云端只显示配置状态，不回显密钥。"))
        }
    }

    private func searchRemoteRow(_ search: IOSCloudConfigSnapshot.Search) -> some View {
        let status: String = {
            if !search.enabled { return macGatewayL("停用") }
            if !search.requiresKey { return macGatewayL("免费") }
            return search.keyConfigured ? macGatewayL("已配置") : macGatewayL("未配置")
        }()
        return MacGatewayRow(icon: "magnifyingglass", title: search.name,
                             detail: search.type) {
            Text(verbatim: status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(search.enabled && (search.keyConfigured || !search.requiresKey)
                    ? AmberTheme.accent : AmberTheme.muted)
        }
        .opacity(search.enabled ? 1 : 0.55)
    }

    // MARK: - Import from this device

    private var importSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("从本机导入"))
            AmberFormGroup {
                if let draft {
                    providerPickers(draft)
                    searchPickers(draft)
                    previewRow(draft)
                } else {
                    MacGatewayRow(icon: "square.and.arrow.up", title: macGatewayL("读取本机配置…"), detail: "") {
                        ProgressView()
                    }
                }
            }
            if let importError {
                MacGatewaySectionFooter(text: importError, color: .orange)
            } else {
                MacGatewaySectionFooter(text: macGatewayL("默认只选当前使用的模型与搜索；Key 仅在确认后从钥匙串取出，内存中加密封装后经已配对连接上传。"))
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

    @ViewBuilder
    private func providerPickers(_ draft: IOSCloudImportDraft) -> some View {
        if !draft.providers.isEmpty {
            ForEach(draft.providers) { provider in
                providerRow(provider, draft: draft)
                MacGatewayRowDivider()
            }
            if let provider = draft.selectedProvider {
                modelPickerRow(provider, draft: draft)
                MacGatewayRowDivider()
            }
        } else {
            MacGatewayRow(icon: "cpu", title: macGatewayL("本机没有服务商"), detail: "") {
                EmptyView()
            }
            MacGatewayRowDivider()
        }
    }

    private func providerRow(_ provider: IOSCloudProviderExportItem, draft: IOSCloudImportDraft) -> some View {
        let selected = draft.providerId == provider.providerId
        let detail = provider.blockedReason
            ?? [provider.kind.rawValue, host(of: provider.baseUrl)]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        return MacGatewayRow(icon: "cpu", title: provider.name, detail: detail,
                             action: provider.isExportable ? { select(provider, in: draft) } : nil) {
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AmberTheme.accent)
            } else if !provider.isExportable {
                Text(verbatim: provider.blockedReason ?? "")
                    .font(.caption2).foregroundStyle(AmberTheme.muted)
            }
        }
        .opacity(provider.isExportable ? 1 : 0.55)
    }

    /// Tapping a provider toggles its selection — tapping the selected row
    /// clears the model choice entirely so a search-only import (e.g. just
    /// Exa/Brave keys) doesn't drag the model and its key along.
    private func select(_ provider: IOSCloudProviderExportItem, in draft: IOSCloudImportDraft) {
        var next = draft
        if next.providerId == provider.providerId {
            next.providerId = nil
            next.modelUuid = nil
        } else {
            next.providerId = provider.providerId
            next.modelUuid = provider.defaultModelUuid
        }
        self.draft = next
    }

    private func modelPickerRow(_ provider: IOSCloudProviderExportItem, draft: IOSCloudImportDraft) -> some View {
        let current = draft.selectedModel?.displayName ?? macGatewayL("选择模型")
        return Menu {
            ForEach(provider.chatModels) { model in
                Button(model.displayName) {
                    var next = draft
                    next.modelUuid = model.uuid
                    self.draft = next
                }
            }
        } label: {
            HStack(spacing: 12) {
                MacGatewayIconPlate(icon: "sparkles")
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: macGatewayL("模型")).font(.body).foregroundStyle(AmberTheme.foreground)
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

    @ViewBuilder
    private func searchPickers(_ draft: IOSCloudImportDraft) -> some View {
        if !draft.searches.isEmpty {
            ForEach(draft.searches) { search in
                searchRow(search, draft: draft)
                MacGatewayRowDivider()
            }
        }
    }

    private func searchRow(_ search: IOSCloudSearchExportItem, draft: IOSCloudImportDraft) -> some View {
        let selected = draft.selectedSearchIds.contains(search.serviceId)
        var detail = search.typeLabel
        if let blocked = search.blockedReason { detail += " · " + blocked }
        else if search.isSelected { detail += " · " + macGatewayL("本机当前使用") }
        return MacGatewayRow(icon: "magnifyingglass", title: search.name, detail: detail,
                             action: search.isExportable ? { toggle(search, in: draft) } : nil) {
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AmberTheme.accent)
            } else if !search.isExportable {
                Image(systemName: "circle").foregroundStyle(AmberTheme.muted)
            }
        }
        .opacity(search.isExportable ? 1 : 0.55)
    }

    private func toggle(_ search: IOSCloudSearchExportItem, in draft: IOSCloudImportDraft) {
        var next = draft
        if next.selectedSearchIds.contains(search.serviceId) {
            next.selectedSearchIds.remove(search.serviceId)
        } else {
            next.selectedSearchIds.insert(search.serviceId)
        }
        self.draft = next
    }

    private func previewRow(_ draft: IOSCloudImportDraft) -> some View {
        MacGatewayRow(icon: "square.and.arrow.up",
                      title: macGatewayL("预览并导入到云端"),
                      detail: draft.hasSelection
                        ? macGatewayL("查看将上传与替换的项目")
                        : macGatewayL("先在上方勾选服务商或搜索服务"),
                      action: draft.hasSelection ? { presentingPreview = true } : nil) {
            if store.cloudImporting {
                ProgressView()
            } else {
                MacGatewayChevron()
            }
        }
        .opacity(draft.hasSelection ? 1 : 0.55)
    }

    // MARK: - Manual update (advanced)

    private var manualSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("高级"))
            AmberFormGroup {
                MacGatewayRow(icon: "slider.horizontal.3", title: macGatewayL("手动更新模型"),
                              detail: macGatewayL("直接设置云端的 provider、Base URL 与模型"),
                              action: { manualSheet = .model }) {
                    MacGatewayChevron()
                }
                MacGatewayRowDivider()
                MacGatewayRow(icon: "key.horizontal", title: macGatewayL("手动更新搜索 Key"),
                              detail: macGatewayL("为指定搜索服务设置或替换 API Key"),
                              action: { manualSheet = .searchKey }) {
                    MacGatewayChevron()
                }
            }
            MacGatewaySectionFooter(text: macGatewayL("删除云端已保存的 Key 是独立操作，请在 Mac 端确认后执行。"))
        }
    }

    // MARK: - Helpers

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

// MARK: - Import preview sheet

/// Confirmation step: shows only names, model, source ("本机") and which cloud
/// slots get replaced — never key material. Confirm is the explicit user action
/// that resolves credentials and uploads.
private struct CloudImportPreviewSheet: View {
    let draft: IOSCloudImportDraft
    let remote: IOSCloudConfigSnapshot?
    let importing: Bool
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
            .disabled(importing)
        }
        .padding(.top, 20)
    }
}

// MARK: - Manual sheets

private struct CloudManualModelSheet: View {
    let remote: IOSCloudConfigSnapshot?
    let importing: Bool
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

    init(remote: IOSCloudConfigSnapshot?, importing: Bool, onApply: @escaping (IOSCloudConfigBundle.ModelSection?, [String: IOSCloudConfigBundle.CredentialAction]) -> Void) {
        self.remote = remote
        self.importing = importing
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
            .disabled(disabled || importing)
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
            .disabled(importing)
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
    let importing: Bool
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
            .disabled(disabled || importing)
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
            .disabled(importing)
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
