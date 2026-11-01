import SwiftUI

/// 「手动更新」云端配置：直接编辑云端模型与搜索项。
/// Key 输入框留空表示保留云端已存值；删除 Key 是独立的勾选操作。
/// 保存冲突（云端被其它设备改动）时草稿保留，可重新读取后再提交。
struct DesktopCloudConfigSheet: View {
    @Bindable var store: DesktopCloudSelfStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = DesktopCloudConfigDraft()
    @State private var loaded = false
    @State private var requestId = UUID().uuidString
    @State private var saving = false
    @State private var error: String?
    @State private var conflicted = false

    private static let cloudProviders = ["openai", "claude"]
    private static let cloudSources = ["bing", "duckduckgo", "exa", "brave"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("更新云端配置").font(.system(size: 16, weight: .semibold))
                Text("直接写入云端 amberd 的运行配置。Key 输入框留空则保留云端已存值。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modelSection
                    searchSection
                    secretSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .background(DesktopTheme.paper)
        .task { await loadDraft() }
    }

    private func loadDraft() async {
        if store.remoteConfig == nil { await store.refreshRemoteConfig() }
        if let config = store.remoteConfig {
            draft = DesktopCloudConfigDraft(
                modelProvider: config.model.provider.isEmpty ? "openai" : config.model.provider,
                modelId: config.model.modelId, modelBaseURL: config.model.baseURL,
                searchSources: config.search.sources, searchMode: config.search.mode,
                baseRevision: config.revision)
        }
        loaded = true
    }

    private var providerOptions: [String] {
        let supported = store.remoteConfig?.supportedModelProviders ?? []
        return supported.isEmpty ? Self.cloudProviders : supported
    }

    private var sourceOptions: [String] {
        let supported = store.remoteConfig?.supportedSearchSources ?? []
        return supported.isEmpty ? Self.cloudSources : supported
    }

    // MARK: sections

    private var modelSection: some View {
        section("模型") {
            LabeledContent("服务商") {
                Picker("", selection: $draft.modelProvider) {
                    ForEach(providerOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 160)
            }
            LabeledContent("模型标识") { TextField("例如 gpt-5-mini", text: $draft.modelId).textFieldStyle(.desktop) }
            LabeledContent("接口地址") { TextField("https://…", text: $draft.modelBaseURL).textFieldStyle(.desktop) }
            LabeledContent("模型 Key") {
                SecureField(store.remoteConfig?.model.keyConfigured == true ? "已保存 · 留空保持不变" : "粘贴 API Key", text: $draft.modelApiKey)
                    .textFieldStyle(.desktop)
            }
        }
    }

    private var searchSection: some View {
        section("搜索") {
            ForEach(sourceOptions, id: \.self) { source in
                Toggle(isOn: Binding(
                    get: { draft.searchSources.contains(source) },
                    set: { on in
                        if on { draft.searchSources.append(source) } else { draft.searchSources.removeAll { $0 == source } }
                    }
                )) { Text(source).font(.system(size: 13)) }
                .toggleStyle(.checkbox)
            }
            LabeledContent("执行方式") {
                Picker("", selection: $draft.searchMode) {
                    Text("按顺序回退").tag("fallback")
                    Text("并行聚合").tag("aggregate")
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 200)
            }
            if draft.searchSources.contains("exa") || store.remoteConfig?.search.exaKeyConfigured == true {
                LabeledContent("Exa Key") {
                    SecureField(store.remoteConfig?.search.exaKeyConfigured == true ? "已保存 · 留空保持不变" : "粘贴 Exa Key", text: $draft.exaKey)
                        .textFieldStyle(.desktop)
                }
            }
            if draft.searchSources.contains("brave") || store.remoteConfig?.search.braveKeyConfigured == true {
                LabeledContent("Brave Key") {
                    SecureField(store.remoteConfig?.search.braveKeyConfigured == true ? "已保存 · 留空保持不变" : "粘贴 Brave Key", text: $draft.braveKey)
                        .textFieldStyle(.desktop)
                }
            }
        }
    }

    @ViewBuilder private var secretSection: some View {
        let remoteSecrets = (store.remoteConfig?.configuredSecrets ?? []).sorted()
        if !remoteSecrets.isEmpty {
            section("移除云端已存 Key（独立操作，谨慎）") {
                ForEach(remoteSecrets, id: \.self) { key in
                    Toggle(isOn: Binding(
                        get: { draft.deletes.contains(key) },
                        set: { on in if on { draft.deletes.insert(key) } else { draft.deletes.remove(key) } }
                    )) {
                        HStack {
                            Text(DesktopCloudSelfStore.secretDisplayName(key)).font(.system(size: 12))
                            Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(DesktopTheme.inkTertiary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 10) {
            if conflicted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(DesktopTheme.danger)
                    Text("云端配置刚被其它来源更新。草稿已保留，重新读取后再保存。")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkSecondary)
                    Spacer()
                    Button("重新读取") { Task { await reloadKeepingDraft() } }
                }
            } else if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(DesktopTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存到云端") { Task { await save() } }
                    .buttonStyle(.desktopProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || !loaded)
            }
        }
        .padding(16)
    }

    private func reloadKeepingDraft() async {
        await store.refreshRemoteConfig()
        if let config = store.remoteConfig { draft.baseRevision = config.revision }
        conflicted = false
    }

    private func save() async {
        saving = true
        defer { saving = false }
        error = nil
        if let failure = await store.applyRemoteConfig(draft, requestId: requestId) {
            if case .conflict = failure { conflicted = true } else { error = failure.localizedDescription }
            return
        }
        dismiss()
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DesktopTheme.inkSecondary)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesktopTheme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.hairline))
        }
    }
}
