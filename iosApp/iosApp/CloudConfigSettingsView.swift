import SwiftUI

/// Settings › Amber · 云端 › 云端配置 — focuses the primary card strictly on
/// viewing/switching the cloud's active provider & model without duplicate text,
/// keeps "从本机同步" and "联网搜索" as calm secondary sections, and demotes
/// manual configuration & protocol/Base URL metadata to the bottom "高级" section.
struct CloudConfigSettingsView: View {
    let sharedSettings: IOSSharedSettingsStore
    var store: MacGatewayStore = .shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(RouterPath.self) private var router

    @State private var switchDraft: IOSCloudImportDraft?
    @State private var importDraft: IOSCloudImportDraft?
    @State private var hasEditedSwitchSelection = false
    @State private var presentingLocalImport = false
    @State private var showingConnectionDetails = false
    @State private var manualSheet: ManualSheet?
    @State private var switchError: String?
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
                            primarySwitchSection
                            localSyncSection
                            remoteSearchSection
                            advancedSection
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
            #if DEBUG
            if Self.isUsingDebugFixture {
                let fixture = Self.makeDebugFixtureDraft()
                importDraft = fixture
                switchDraft = fixture.alignedForPrimarySwitch(remote: store.cloudConfig)
                return
            }
            #endif
            let base = IOSCloudImportDraft.make(from: sharedSettings)
            importDraft = base
            switchDraft = base.alignedForPrimarySwitch(remote: store.cloudConfig)
            await store.refreshCloudConfig()
            if !hasEditedSwitchSelection, let currentSwitch = switchDraft {
                switchDraft = currentSwitch.alignedForPrimarySwitch(remote: store.cloudConfig)
            }
        }
        .task(id: sharedSettings.revision) {
            #if DEBUG
            if Self.isUsingDebugFixture { return }
            #endif
            if let importDraft {
                self.importDraft = importDraft.rebuilt(from: sharedSettings)
            }
            if let switchDraft {
                let rebuilt = switchDraft.rebuilt(from: sharedSettings)
                self.switchDraft = hasEditedSwitchSelection
                    ? rebuilt
                    : rebuilt.alignedForPrimarySwitch(remote: store.cloudConfig)
            }
        }
        .onChange(of: store.cloudConfig) { _, newValue in
            guard !hasEditedSwitchSelection, let currentSwitch = switchDraft else { return }
            switchDraft = currentSwitch.alignedForPrimarySwitch(remote: newValue)
        }
        .sheet(isPresented: $presentingLocalImport) {
            if let binding = Binding($importDraft) {
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
                                hasEditedSwitchSelection = false
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
            hasEditedSwitchSelection = false
            manualSheet = nil
        }
    }

    private func performDirectModelSwitch(using draft: IOSCloudImportDraft) {
        switchError = nil
        #if DEBUG
        if Self.isUsingDebugFixture {
            guard let provider = draft.selectedProvider, let model = draft.selectedModel else { return }
            store.applyDebugFixtureModelSwitch(
                provider: provider.kind.rawValue,
                providerName: provider.name,
                modelId: model.modelId,
                baseUrl: provider.baseUrl
            )
            hasEditedSwitchSelection = false
            return
        }
        #endif
        Task {
            let error = await store.applyCloudImport(
                draft: draft.modelOnlyDraft,
                sharedSettings: sharedSettings,
                expectedRevision: store.cloudConfig?.revision
            )
            if let error {
                switchError = error
            } else {
                switchError = nil
                hasEditedSwitchSelection = false
            }
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
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        if let notice = store.notice {
            AmberFormGroup {
                HStack(spacing: 10) {
                    Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(notice.isError ? .orange : AmberTheme.accentGreen)
                    Text(verbatim: notice.text)
                        .font(.subheadline)
                        .foregroundStyle(notice.isError ? .orange : AmberTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .padding(.bottom, 4)
        } else if let error = store.cloudConfigError {
            AmberFormGroup {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .padding(.bottom, 4)
        }
        if store.cloudImportKeyChanged {
            AmberFormGroup {
                quietActionRow(
                    title: macGatewayL("重新信任云端加密公钥"),
                    trailingText: macGatewayL("重置"),
                    trailingColor: .orange,
                    showsChevron: false
                ) {
                    store.resetCloudImportKeyTrust()
                    switchError = nil
                    importError = nil
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - Not paired

    private var notPairedSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("云端配置"))
            AmberFormGroup {
                quietActionRow(title: macGatewayL("先配对 Amber · 云端")) {
                    dismiss()
                }
            }
            MacGatewaySectionFooter(text: macGatewayL("回到上一页扫码或粘贴配对链接。"))
        }
    }

    // MARK: - Primary Section: 云端模型

    private var primarySwitchSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("云端模型"))
            AmberFormGroup {
                if let draft = switchDraft, !draft.exportableProviders.isEmpty {
                    providerPickerRow(draft)
                    if let selectedProvider = draft.selectedProvider {
                        plainRowDivider
                        modelPickerRow(selectedProvider, draft: draft)
                        if let transition = draft.modelOnlyDraft.modelTransitionSummary(
                            remote: store.cloudConfig,
                            localProviders: draft.providers
                        ) {
                            plainRowDivider
                            primarySwitchStatusRow(draft: draft, transition: transition)
                        }
                    }
                } else if switchDraft != nil {
                    if let remoteModel = store.cloudConfig?.model,
                       !remoteModel.provider.isEmpty || !remoteModel.modelId.isEmpty {
                        quietValueRow(title: macGatewayL("模型"), value: remoteModel.modelId)
                        plainRowDivider
                        quietValueRow(
                            title: macGatewayL("状态"),
                            value: remoteModel.keyConfigured ? macGatewayL("已在使用") : macGatewayL("已在使用 · 缺少 Key"),
                            valueColor: remoteModel.keyConfigured ? AmberTheme.muted : AmberTheme.accentAmber
                        )
                    } else {
                        HStack(spacing: 12) {
                            Text(verbatim: remoteHint)
                                .font(.subheadline)
                                .foregroundStyle(AmberTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if store.cloudConfigLoading {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(minHeight: 50)
                        .padding(.horizontal, 16)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(verbatim: macGatewayL("正在读取配置…"))
                            .font(.subheadline)
                            .foregroundStyle(AmberTheme.muted)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 50)
                    .padding(.horizontal, 16)
                }
            }
            if let switchError {
                MacGatewaySectionFooter(text: switchError, color: .orange)
            } else if let draft = switchDraft, draft.exportableProviders.isEmpty {
                MacGatewaySectionFooter(text: macGatewayL("本机暂无可直接切换的 API Key 服务商，可在下方「手动配置」设置。"))
            }
        }
    }

    private func providerPickerRow(_ draft: IOSCloudImportDraft) -> some View {
        let currentName = draft.selectedProvider?.name ?? macGatewayL("选择")
        return Menu {
            ForEach(draft.exportableProviders) { provider in
                Button {
                    var next = draft
                    next.providerId = provider.providerId
                    next.modelUuid = provider.defaultModelUuid
                    hasEditedSwitchSelection = true
                    switchError = nil
                    store.notice = nil
                    self.switchDraft = next
                } label: {
                    HStack {
                        Text(verbatim: provider.name)
                        if draft.providerId == provider.providerId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            pickerRowContent(title: macGatewayL("服务商"), value: currentName, truncation: .tail)
        }
    }

    private func modelPickerRow(_ provider: IOSCloudProviderExportItem, draft: IOSCloudImportDraft) -> some View {
        let current = draft.selectedModel?.displayName ?? macGatewayL("选择")
        return Menu {
            ForEach(provider.chatModels) { model in
                Button {
                    var next = draft
                    next.modelUuid = model.uuid
                    hasEditedSwitchSelection = true
                    switchError = nil
                    store.notice = nil
                    self.switchDraft = next
                } label: {
                    HStack {
                        let menuLabel = model.displayName == model.modelId
                            ? model.modelId
                            : "\(model.displayName) (\(model.modelId))"
                        Text(verbatim: menuLabel)
                        if draft.selectedModel?.uuid == model.uuid {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            pickerRowContent(title: macGatewayL("模型"), value: current, truncation: .middle)
        }
    }

    private func pickerRowContent(
        title: String,
        value: String,
        truncation: Text.TruncationMode
    ) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(verbatim: title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: true, vertical: false)

            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 12)
            }

            HStack(spacing: 6) {
                Text(verbatim: value)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(truncation)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
                    .fixedSize()
            }
        }
        .frame(minHeight: 50)
        .padding(.horizontal, 16)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func primarySwitchStatusRow(
        draft: IOSCloudImportDraft,
        transition: IOSCloudModelTransitionSummary
    ) -> some View {
        let state = IOSCloudPrimarySwitchState.resolve(
            transition: transition,
            remote: store.cloudConfig,
            isLoadingRemote: store.cloudConfigLoading,
            isSubmitting: store.cloudImporting
        )
        switch state {
        case .switching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: macGatewayL("正在切换…"))
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.muted)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 48)
            .padding(.horizontal, 16)

        case .inUse(let missingKey):
            quietValueRow(
                title: macGatewayL("状态"),
                value: missingKey ? macGatewayL("已在使用 · 缺少 Key") : macGatewayL("已在使用"),
                titleFont: .subheadline,
                titleColor: AmberTheme.muted,
                valueColor: missingKey ? AmberTheme.accentAmber : AmberTheme.muted,
                minHeight: 46
            )

        case .readyToSwitch(let changeHint):
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: changeHint)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    primarySwitchButton(draft: draft, fullWidth: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                HStack(spacing: 12) {
                    Text(verbatim: changeHint)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    primarySwitchButton(draft: draft, fullWidth: false)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
                .frame(minHeight: 52)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    private func primarySwitchButton(draft: IOSCloudImportDraft, fullWidth: Bool) -> some View {
        let isWaitingInitialSnapshot = store.cloudConfigLoading && store.cloudConfig == nil
        return Button {
            performDirectModelSwitch(using: draft)
        } label: {
            Text(verbatim: macGatewayL("切换并使用"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 34)
                .background(AmberTheme.accent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isWaitingInitialSnapshot)
        .opacity(isWaitingInitialSnapshot ? 0.5 : 1)
    }

    // MARK: - Secondary Section: 从本机同步

    private var localSyncSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("本机同步"))
            AmberFormGroup {
                if importDraft != nil {
                    quietActionRow(
                        title: macGatewayL("从本机同步"),
                        showsProgress: store.cloudImporting
                    ) {
                        previewSnapshot = store.cloudConfig
                        importError = nil
                        presentingLocalImport = true
                    }
                } else {
                    HStack(spacing: 10) {
                        Text(verbatim: macGatewayL("从本机同步"))
                            .font(.body)
                            .foregroundStyle(AmberTheme.muted)
                        Spacer(minLength: 8)
                        ProgressView().controlSize(.small)
                    }
                    .frame(minHeight: 50)
                    .padding(.horizontal, 16)
                }
            }
            if let importError {
                MacGatewaySectionFooter(text: importError, color: .orange)
            } else {
                MacGatewaySectionFooter(text: macGatewayL("批量上传本机当前模型、联网搜索与 API Key，确认后覆盖云端现有设置。"))
            }
        }
    }

    // MARK: - Secondary Section: 联网搜索

    private var remoteSearchSection: some View {
        let searchSummary: String = {
            guard let config = store.cloudConfig else { return remoteHint }
            if config.searchSources.isEmpty { return macGatewayL("未启用") }
            return config.searchSources
                .map(IOSCloudConfigWire.sourceDisplayName(for:))
                .joined(separator: " → ")
        }()
        let configuredPaidKeys: String? = {
            guard let config = store.cloudConfig else { return nil }
            let names = config.search.filter { $0.requiresKey && $0.keyConfigured }.map(\.name)
            return names.isEmpty ? nil : names.joined(separator: " · ") + " " + macGatewayL("已配置")
        }()

        return VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("联网搜索"))
            AmberFormGroup {
                quietValueRow(title: macGatewayL("搜索源"), value: searchSummary)
                plainRowDivider
                quietActionRow(
                    title: macGatewayL("配置搜索 Key"),
                    trailingText: configuredPaidKeys
                ) {
                    openManualSheet(.searchKey)
                }
            }
        }
    }

    // MARK: - Bottom Section: 高级（手动配置 + 连接详情）

    private var advancedSection: some View {
        let remoteModel = store.cloudConfig?.model
        let hasRemoteDetails = remoteModel.map { !$0.provider.isEmpty || !$0.modelId.isEmpty } ?? false

        return VStack(spacing: 0) {
            AmberSectionLabel(verbatim: macGatewayL("高级"))
            AmberFormGroup {
                quietActionRow(title: macGatewayL("手动配置")) {
                    openManualSheet(.model)
                }
                if hasRemoteDetails, let config = store.cloudConfig, let model = config.model {
                    plainRowDivider
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            showingConnectionDetails.toggle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(verbatim: macGatewayL("连接详情"))
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                            Spacer(minLength: 8)
                            Image(systemName: showingConnectionDetails ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AmberTheme.muted2)
                        }
                        .frame(minHeight: 50)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showingConnectionDetails {
                        plainRowDivider
                        VStack(spacing: 8) {
                            detailPairRow(
                                label: macGatewayL("协议类型"),
                                value: IOSCloudConfigWire.providerDisplayName(for: model.provider)
                            )
                            detailPairRow(
                                label: "Base URL",
                                value: IOSCloudConfigWire.displayBaseUrl(provider: model.provider, baseUrl: model.baseUrl)
                            )
                            detailPairRow(
                                label: "API Key",
                                value: model.keyConfigured ? macGatewayL("已配置") : macGatewayL("缺少 Key")
                            )
                            detailPairRow(
                                label: macGatewayL("配置版本"),
                                value: "#\(config.revision)"
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    // MARK: - Quiet Row Primitives & Helpers

    private var plainRowDivider: some View {
        Divider()
            .overlay(AmberTheme.borderSoft)
            .padding(.leading, 16)
    }

    private func quietValueRow(
        title: String,
        value: String,
        titleFont: Font = .body,
        titleColor: Color = AmberTheme.foreground,
        valueColor: Color = AmberTheme.muted,
        minHeight: CGFloat = 50
    ) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(verbatim: title)
                .font(titleFont)
                .foregroundStyle(titleColor)
                .fixedSize(horizontal: true, vertical: false)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 12)
            }
            Text(verbatim: value)
                .font(.subheadline)
                .foregroundStyle(valueColor)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
        .frame(minHeight: minHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
        .accessibilityElement(children: .combine)
    }

    private func quietActionRow(
        title: String,
        trailingText: String? = nil,
        trailingColor: Color = AmberTheme.muted,
        showsChevron: Bool = true,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(verbatim: title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    if let trailingText, !trailingText.isEmpty {
                        Text(verbatim: trailingText)
                            .font(.subheadline)
                            .foregroundStyle(trailingColor)
                            .lineLimit(1)
                    }
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted2)
                    }
                }
            }
            .frame(minHeight: 50)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(showsProgress)
    }

    private func detailPairRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(.caption)
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private func openManualSheet(_ sheet: ManualSheet) {
        manualSnapshot = store.cloudConfig
        importError = nil
        manualSheet = sheet
    }

    private var remoteHint: String {
        if store.cloudConfigLoading { return macGatewayL("正在读取云端配置…") }
        if !store.cloudConfigAvailable { return macGatewayL("云端接口待接入，等待服务端更新") }
        if let error = store.cloudConfigError { return error }
        return macGatewayL("云端尚未设置模型")
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

    private enum ManualSheet: Identifiable {
        case model
        case searchKey
        var id: Int { self == .model ? 0 : 1 }
    }

    #if DEBUG
    private static var isUsingDebugFixture: Bool {
        ProcessInfo.processInfo.environment["AMBER_CLOUD_CONFIG_FIXTURE"] == "1"
    }

    private static func makeDebugFixtureDraft() -> IOSCloudImportDraft {
        let openCode = IOSCloudProviderExportItem(
            providerId: "fixture-opencode",
            name: "opencode go",
            kind: .openAI,
            baseUrl: "https://opencode.ai/zen/v1",
            chatModels: [
                .init(uuid: "m-ds-flash", modelId: "deepseek-v4.1-flash", displayName: "deepseek-v4.1-flash"),
                .init(
                    uuid: "m-long-preview",
                    modelId: "deepseek-r1-distill-qwen-32b-preview-202611",
                    displayName: "deepseek-r1-distill-qwen-32b-preview-202611"
                ),
            ],
            defaultModelUuid: "m-ds-flash",
            hasApiKey: true,
            managedAuthLabel: nil,
            enabled: true
        )
        let anthropic = IOSCloudProviderExportItem(
            providerId: "fixture-claude",
            name: "Claude",
            kind: .claude,
            baseUrl: "https://api.anthropic.com/v1",
            chatModels: [
                .init(uuid: "m-sonnet", modelId: "claude-sonnet-4-5", displayName: "claude-sonnet-4-5"),
            ],
            defaultModelUuid: "m-sonnet",
            hasApiKey: true,
            managedAuthLabel: nil,
            enabled: true
        )
        return IOSCloudImportDraft(
            providers: [openCode, anthropic],
            searches: [
                IOSCloudSearchExportItem(
                    serviceId: "fixture-free",
                    name: "Bing 聚合",
                    typeLabel: "bing_local",
                    requiresKey: false,
                    hasApiKey: false,
                    enabled: true,
                    isSelected: true
                ),
            ],
            providerId: openCode.providerId,
            modelUuid: "m-ds-flash",
            selectedSearchIds: ["fixture-free"],
            enableWebSearch: true,
            freeSources: ["bing", "duckduckgo"]
        )
    }
    #endif
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
            .navigationTitle(showingPreviewStep ? macGatewayL("确认同步") : macGatewayL("从本机同步"))
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
        return selectableSheetRow(
            icon: "cpu",
            title: provider.name,
            detail: detail,
            selected: selected
        ) {
            toggleProvider(provider)
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
                Text(verbatim: macGatewayL("模型")).font(.body).foregroundStyle(AmberTheme.foreground)
                Spacer(minLength: 8)
                Text(verbatim: current)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
            }
            .frame(minHeight: 50)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
    }

    private func searchRow(_ search: IOSCloudSearchExportItem) -> some View {
        let selected = draft.selectedSearchIds.contains(search.serviceId)
        let mappedSources = search.cloudSources.map(IOSCloudConfigWire.sourceDisplayName(for:)).joined(separator: "、")
        let detail = search.isSelected
            ? "\(mappedSources) · \(macGatewayL("本机当前使用"))"
            : mappedSources
        return selectableSheetRow(
            icon: "magnifyingglass",
            title: search.name,
            detail: detail,
            selected: selected
        ) {
            toggleSearch(search)
        }
    }

    private func selectableSheetRow(
        icon: String,
        title: String,
        detail: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                MacGatewayIconPlate(icon: icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                        .lineLimit(2)
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selected ? AmberTheme.accent : AmberTheme.muted)
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        showingBlockedSummary.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        MacGatewayIconPlate(icon: "info.circle")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: macGatewayL("已略过 \(blockedItemCount) 项不可导出的本机配置"))
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                            Text(verbatim: showingBlockedSummary
                                ? macGatewayL("收起分类说明")
                                : macGatewayL("按需查看不支持协议、非 HTTPS 地址、缺 Key 或 OAuth 项目"))
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: showingBlockedSummary ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .frame(minHeight: 52)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
