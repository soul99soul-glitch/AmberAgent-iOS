import SwiftUI

/// 「从本机导入」预览：选择要复用到云端的模型服务商与搜索 Key，逐项列出将替换的云端配置。
/// 预览不含任何 Key 明文；确认后由 store 一次性读入内存并加密上传。
struct DesktopCloudImportSheet: View {
    @Bindable var store: DesktopCloudSelfStore
    @Environment(\.dismiss) private var dismiss

    @State private var catalog: DesktopCloudImportCatalog?
    @State private var providerID: UUID?
    @State private var searchServices: Set<DesktopSearchService> = []
    @State private var searchMode: DesktopSearchExecutionMode = .sequentialFallback
    @State private var deletes: Set<String> = []
    @State private var error: String?
    @State private var conflicted = false
    @State private var mergedNote: String?
    @State private var showDeletes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modelSection
                    searchSection
                    replacementSection
                    deleteSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
        .background(DesktopTheme.paper)
        .task {
            let built = store.importCatalog()
            catalog = built
            providerID = built.providers.first(where: { $0.selectable && $0.selectedLocally })?.id
            searchServices = Set(built.search.filter { $0.supported && ($0.enabledLocally || $0.id == .free) }.map(\.id))
            searchMode = built.executionMode
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("导入云端配置").font(.system(size: 16, weight: .semibold))
            Text("只会上传你勾选的项目。Key 从本机钥匙串读取后在内存中加密封装，经已配对的 HTTPS 通道送达云端；未勾选的云端配置保持不变。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    // MARK: model

    private var modelSection: some View {
        section("云端模型（单选）") {
            if let catalog {
                ForEach(catalog.providers) { provider in
                    providerRow(provider)
                }
            }
        }
    }

    private func providerRow(_ provider: DesktopCloudImportCatalog.ProviderItem) -> some View {
        let selected = providerID == provider.id
        return Button {
            if provider.selectable { providerID = selected ? nil : provider.id }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? DesktopTheme.accent : DesktopTheme.inkTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name).font(.system(size: 13, weight: .medium))
                    Text([provider.kindTitle, provider.modelDisplay, provider.baseURL]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if !provider.selectable {
                    Text(provider.note ?? "不可导入").font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary)
                } else {
                    keyBadge(configured: provider.hasAPIKey)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(selected ? DesktopTheme.honeySoft : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? DesktopTheme.honeyEdge : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!provider.selectable)
    }

    // MARK: search

    private var searchSection: some View {
        section("云端搜索（可多选）") {
            if let catalog {
                ForEach(catalog.search) { service in
                    searchRow(service)
                }
                if !searchServices.isEmpty {
                    HStack {
                        Text("执行方式").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary)
                        Picker("", selection: $searchMode) {
                            Text("按顺序回退").tag(DesktopSearchExecutionMode.sequentialFallback)
                            Text("并行聚合").tag(DesktopSearchExecutionMode.parallel)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 260)
                    }
                    .padding(.horizontal, 12).padding(.top, 4)
                }
            }
        }
    }

    private func searchRow(_ service: DesktopCloudImportCatalog.SearchItem) -> some View {
        let selected = searchServices.contains(service.id)
        return Button {
            if service.supported {
                if selected { searchServices.remove(service.id) } else { searchServices.insert(service.id) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? DesktopTheme.accent : DesktopTheme.inkTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.title).font(.system(size: 13, weight: .medium))
                    Text(service.supported
                        ? "云端来源：" + service.cloudSources.joined(separator: " + ")
                        : "云端暂不支持此来源")
                        .font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary)
                }
                Spacer()
                if service.secretKey != nil {
                    keyBadge(configured: service.hasAPIKey)
                } else {
                    Text("无需 Key").font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(selected ? DesktopTheme.honeySoft : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? DesktopTheme.honeyEdge : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!service.supported)
    }

    // MARK: replacements

    private var replacementSection: some View {
        section("将替换的云端配置") {
            let items = replacementItems
            if items.isEmpty {
                Text("尚未选择导入项").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items, id: \.self) { item in
                        Label(item, systemImage: "arrow.right.circle")
                            .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary)
                    }
                }
            }
        }
    }

    private var replacementItems: [String] {
        var items: [String] = []
        if providerID != nil {
            items += ["模型服务商与接口地址", "云端模型标识", "模型 API Key"]
        }
        if !searchServices.isEmpty {
            items.append("搜索来源与执行方式")
            if searchServices.contains(.exa) { items.append("Exa API Key") }
            if searchServices.contains(.brave) { items.append("Brave API Key") }
        }
        items += deletes.sorted().map { "移除云端已存：\(DesktopCloudSelfStore.secretDisplayName($0))" }
        return items
    }

    // MARK: explicit deletion

    /// Slots the current selections will replace with a fresh key — their delete toggles are
    /// meaningless in this same request (a slot can't be replaced and deleted at once).
    private func willReplace(_ key: String) -> Bool {
        switch key {
        case "modelApiKey": providerID != nil
        case "exaApiKey": searchServices.contains(.exa)
        case "braveApiKey": searchServices.contains(.brave)
        default: false
        }
    }

    @ViewBuilder private var deleteSection: some View {
        let remoteSecrets = (store.remoteConfig?.configuredSecrets ?? []).sorted()
        if !remoteSecrets.isEmpty {
            DisclosureGroup("移除云端已存 Key（独立操作，谨慎）", isExpanded: $showDeletes) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(remoteSecrets, id: \.self) { key in
                        Toggle(isOn: Binding(
                            get: { deletes.contains(key) },
                            set: { on in if on { deletes.insert(key) } else { deletes.remove(key) } }
                        )) {
                            HStack {
                                Text(DesktopCloudSelfStore.secretDisplayName(key)).font(.system(size: 12))
                                Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(DesktopTheme.inkTertiary)
                                if willReplace(key) {
                                    Text("本次将替换").font(.system(size: 11)).foregroundStyle(DesktopTheme.accent)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(willReplace(key))
                    }
                    Text("勾选的 Key 会在本次上传中从云端保管库删除，本机不受影响。已勾选导入的项以新 Key 替换为准。")
                        .font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary)
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12, weight: .semibold))
            .tint(DesktopTheme.inkSecondary)
        }
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 10) {
            if conflicted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(DesktopTheme.danger)
                    Text("云端配置刚被其它来源更新。你的选择已保留，可重新读取后再试。")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary)
                    Spacer()
                    Button("重新读取") { Task { await rereadRemote() } }
                }
            }
            if let mergedNote {
                Text(mergedNote).font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !conflicted, let error {
                Text(error).font(.system(size: 12)).foregroundStyle(DesktopTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if !store.canSyncConfig {
                    Text("云端配置接口待接入，当前可预览选择").font(.system(size: 11)).foregroundStyle(DesktopTheme.inkTertiary)
                }
                Spacer()
                if store.isImporting { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("上传到云端") { Task { await upload() } }
                    .buttonStyle(.desktopProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(providerID == nil && searchServices.isEmpty && deletes.isEmpty
                              || store.isImporting || !store.canSyncConfig)
            }
        }
        .padding(16)
    }

    /// 409 恢复：重新读取云端，并把「远端变了什么」显式呈现——未选择的模型/搜索区块在上传时
    /// 会以刚读到的远端值重建，选择区不受影响。
    private func rereadRemote() async {
        let before = store.remoteConfig
        await store.refreshRemoteConfig()
        guard let fresh = store.remoteConfig else {
            mergedNote = store.remoteConfigError ?? "云端暂时不可达，稍后再试"
            return
        }
        var changed: [String] = []
        if fresh.model.provider != before?.model.provider { changed.append("服务商") }
        if fresh.model.modelId != before?.model.modelId { changed.append("模型标识") }
        if fresh.model.baseURL != before?.model.baseURL { changed.append("接口地址") }
        if fresh.search.sources != before?.search.sources { changed.append("搜索来源") }
        if fresh.search.mode != before?.search.mode { changed.append("执行方式") }
        if fresh.configuredSecrets != before?.configuredSecrets { changed.append("已存 Key 状态") }
        mergedNote = changed.isEmpty
            ? "已重新读取到云端最新版本（r\(fresh.revision)），字段无变化。"
            : "云端变化：\(changed.joined(separator: "、"))（r\(before?.revision ?? 0) → r\(fresh.revision)）。你的导入选择保持不变。"
        conflicted = false
    }

    private func upload() async {
        guard let catalog else { return }
        error = nil
        let plan = DesktopCloudImportPlan(providerID: providerID, searchServices: searchServices,
                                          searchMode: searchMode, deletes: deletes)
        if let failure = await store.import(plan, catalog: catalog) {
            if case .conflict = failure { conflicted = true } else { error = failure.localizedDescription }
            return
        }
        dismiss()
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DesktopTheme.inkSecondary)
            VStack(spacing: 2) { content() }
        }
    }

    private func keyBadge(configured: Bool) -> some View {
        Text(configured ? "本机已存 Key" : "本机无 Key")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(configured ? DesktopTheme.inkSecondary : DesktopTheme.danger)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().strokeBorder(DesktopTheme.hairline, lineWidth: 1))
    }
}
