import SwiftUI

struct NovelAppSettingsView: View {
    let settings: NovelAppSettingsStore
    let onOpenWritingSettings: () -> Void
    let onOpenAppearance: () -> Void

    @State private var editingService: NovelModelService?
    @State private var searchKeyDraft = ""
    @State private var saveError: String?

    var body: some View {
        Form {
            if let loadError = settings.loadErrorMessage {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.accentRed)
                }
            }
            Section {
                ForEach(settings.services) { service in
                    Button {
                        editingService = service
                    } label: {
                        serviceRow(service)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteServices)
                Button {
                    editingService = NovelModelService()
                } label: {
                    Label("添加模型服务", systemImage: "plus")
                }
            } header: {
                Text("模型服务")
            } footer: {
                Text("支持 OpenAI 兼容接口、Claude 与 Gemini 的 API Key。密钥只保存在本机钥匙串。")
            }

            if !allModels.isEmpty {
                Section {
                    Picker("默认模型", selection: defaultModelBinding) {
                        ForEach(allModels, id: \.model.id) { item in
                            Text("\(item.model.modelID) · \(item.service)").tag(Optional(item.model.id))
                        }
                    }
                } footer: {
                    Text("创作、剧情同步和审稿选择「跟随默认模型」时使用它。")
                }
            }

            Section {
                navigationRow("写作模型与偏好", systemImage: "text.book.closed", action: onOpenWritingSettings)
            } footer: {
                Text("分别为创作、剧情同步和审稿指定模型，并管理项目。")
            }

            Section {
                navigationRow("外观与主题", systemImage: "paintpalette", action: onOpenAppearance)
            }

            searchSection

            NovelBackgroundKeepAliveSection()

            NovelAboutSection()
        }
        .scrollContentBackground(.hidden)
        .background(AmberTheme.background)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingService) { service in
            NavigationStack {
                NovelModelServiceEditor(
                    service: service,
                    isNew: !settings.services.contains { $0.id == service.id }
                ) { updated in
                    var services = settings.services
                    if let index = services.firstIndex(where: { $0.id == updated.id }) {
                        services[index] = updated
                    } else {
                        services.append(updated)
                    }
                    return save(services: services)
                }
            }
        }
        .alert("设置未保存", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("好") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onAppear { searchKeyDraft = selectedSearch?.apiKey ?? "" }
        // A typed key is kept when leaving the page without tapping save.
        .onDisappear { if searchKeyIsDirty { commitSearchKey() } }
    }

    private func navigationRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(AmberTheme.foreground)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searchSection: some View {
        Section {
            Toggle("讨论时允许联网搜索", isOn: Binding(
                get: { settings.webSearchEnabled },
                set: { report(save(webSearchEnabled: $0)) }
            ))
            .tint(AmberTheme.accentAmber)
            if settings.webSearchEnabled {
                Picker("搜索服务", selection: Binding(
                    get: { selectedSearch?.kind ?? .freeAggregate },
                    set: { selectSearchKind($0) }
                )) {
                    ForEach(NovelSearchKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                if selectedSearch?.kind.needsAPIKey == true {
                    SecureField("API Key", text: $searchKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(commitSearchKey)
                    Button("保存搜索密钥", action: commitSearchKey)
                        .disabled(!searchKeyIsDirty)
                }
                Stepper(value: Binding(
                    get: { settings.resultSize },
                    set: { report(save(resultSize: $0)) }
                ), in: 1...20) {
                    LabeledContent("每次结果数", value: "\(settings.resultSize)")
                }
            }
        } header: {
            Text("联网搜索")
        } footer: {
            Text("讨论里模型可以搜索资料、读取网页。所选服务失败时自动改用免费聚合搜索。")
        }
    }

    private func serviceRow(_ service: NovelModelService) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(service.displayName)
                    .foregroundStyle(service.enabled ? AmberTheme.foreground : AmberTheme.muted)
                Text("\(URL(string: service.resolvedBaseURL)?.host() ?? service.protocolType.title) · \(service.models.count) 个模型")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }
            Spacer(minLength: 8)
            if service.apiKey.isEmpty {
                Text("缺少密钥")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accent)
                    .fixedSize()
            } else if !service.enabled {
                Text("已停用")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize()
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted2)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var allModels: [(model: NovelModelEntry, service: String)] {
        settings.services.filter(\.enabled).flatMap { service in
            service.models.map { (model: $0, service: service.displayName) }
        }
    }

    private var searchKeyIsDirty: Bool {
        searchKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (selectedSearch?.apiKey ?? "")
    }

    private var selectedSearch: NovelSearchService? {
        settings.searchServices.first { $0.id == settings.selectedSearchID } ?? settings.searchServices.first
    }

    private var defaultModelBinding: Binding<UUID?> {
        Binding(
            get: { settings.defaultModelID },
            set: { report(save(defaultModelID: $0)) }
        )
    }

    private func deleteServices(at offsets: IndexSet) {
        var services = settings.services
        services.remove(atOffsets: offsets)
        report(save(services: services))
    }

    /// One search entry per kind; switching kind keeps each kind's own key.
    private func selectSearchKind(_ kind: NovelSearchKind) {
        var search = settings.searchServices
        // Keep a key typed for the previous service before switching away.
        if searchKeyIsDirty, let current = selectedSearch,
           let index = search.firstIndex(where: { $0.id == current.id }) {
            search[index].apiKey = searchKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let target: NovelSearchService
        if let existing = search.first(where: { $0.kind == kind }) {
            target = existing
        } else {
            target = NovelSearchService(kind: kind)
            search.append(target)
        }
        if report(save(searchServices: search, selectedSearchID: target.id)) {
            searchKeyDraft = target.apiKey
        }
    }

    private func commitSearchKey() {
        guard let selected = selectedSearch else { return }
        var search = settings.searchServices
        guard let index = search.firstIndex(where: { $0.id == selected.id }) else { return }
        search[index].apiKey = searchKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        report(save(searchServices: search))
    }

    @discardableResult
    private func report(_ error: String?) -> Bool {
        saveError = error
        return error == nil
    }

    private func save(
        services: [NovelModelService]? = nil,
        defaultModelID: UUID?? = nil,
        searchServices: [NovelSearchService]? = nil,
        selectedSearchID: UUID? = nil,
        resultSize: Int? = nil,
        webSearchEnabled: Bool? = nil
    ) -> String? {
        settings.save(
            services: services ?? settings.services,
            defaultModelID: defaultModelID ?? settings.defaultModelID,
            searchServices: searchServices ?? settings.searchServices,
            selectedSearchID: selectedSearchID ?? settings.selectedSearchID,
            resultSize: resultSize ?? settings.resultSize,
            webSearchEnabled: webSearchEnabled ?? settings.webSearchEnabled
        )
    }
}

struct NovelModelServiceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NovelModelService
    @State private var errorMessage: String?
    let isNew: Bool
    let onSave: (NovelModelService) -> String?

    init(service: NovelModelService, isNew: Bool, onSave: @escaping (NovelModelService) -> String?) {
        var draft = service
        if draft.models.isEmpty { draft.models = [NovelModelEntry()] }
        _draft = State(initialValue: draft)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section {
                Picker("接口类型", selection: $draft.protocolType) {
                    ForEach(NovelModelProtocol.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("名称") {
                    TextField("名称", text: $draft.name, prompt: Text(draft.protocolType.title))
                        .multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("服务地址")
                    TextField("服务地址", text: $draft.baseURL, prompt: Text(draft.protocolType.defaultBaseURL))
                        .font(.callout)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.vertical, 4)
                LabeledContent("API Key") {
                    SecureField("API Key", text: $draft.apiKey, prompt: Text("必填"))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if draft.protocolType == .openAI {
                    Toggle("使用 Responses API", isOn: $draft.useResponsesAPI)
                        .tint(AmberTheme.accentAmber)
                }
                Toggle("启用", isOn: $draft.enabled)
                    .tint(AmberTheme.accentAmber)
            } header: {
                Text("服务")
            }

            Section {
                ForEach($draft.models) { $model in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("模型 ID，如 gpt-4.1", text: $model.modelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("推理模型", isOn: $model.supportsReasoning)
                            .font(.subheadline)
                            .tint(AmberTheme.accentAmber)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { draft.models.remove(atOffsets: $0) }
                Button {
                    draft.models.append(NovelModelEntry())
                } label: {
                    Label("添加模型", systemImage: "plus")
                }
            } header: {
                Text("模型")
            } footer: {
                Text("推理模型会显示思考过程；剧情同步默认不使用推理。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AmberTheme.background)
        .navigationTitle(isNew ? "添加模型服务" : draft.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    var trimmed = draft
                    trimmed.apiKey = trimmed.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    trimmed.models = trimmed.models.filter {
                        !$0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    if let error = onSave(trimmed) {
                        errorMessage = error
                    } else {
                        dismiss()
                    }
                }
            }
        }
        .alert("无法保存", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

/// The same audio / location legs the main app's experimental build uses to
/// keep long generations alive after the system reclaims its own task.
private struct NovelBackgroundKeepAliveSection: View {
    @AppStorage(IOSExecutionPreferenceKeys.audioKeepAlive) private var audioKeepAlive = true
    @AppStorage(IOSExecutionPreferenceKeys.backgroundLocationKeepAlive) private var locationKeepAlive = false
    @State private var locationStatusRevision = 0

    var body: some View {
        let location = BackgroundLocationKeepAlive.shared
        Section {
            Toggle(isOn: Binding(
                get: { audioKeepAlive },
                set: {
                    audioKeepAlive = $0
                    BackgroundGenerationKeepAlive.shared.refreshAudioKeepAlive()
                }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("音频保活")
                        Text("静音播放；任务结束后后台最多保留 60 秒衔接；系统播报期间让出音频。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    }
                } icon: {
                    Image(systemName: "waveform")
                }
            }
            Toggle(isOn: Binding(
                get: { locationKeepAlive },
                set: {
                    locationKeepAlive = $0
                    if $0 { location.requestEnable() } else { location.refreshPreference() }
                }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("定位保活")
                        Text(location.statusText)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    }
                } icon: {
                    Image(systemName: "location.fill")
                }
            }
            .id(locationStatusRevision)
            if locationKeepAlive, location.authorizationStatus == .denied {
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        } header: {
            Text("后台续跑")
        } footer: {
            Text("代笔等长任务切到后台后，系统给的运行时间很短，靠这两项维持。定位保活需主动授权；不记录或上传位置。任务期间会显示系统定位标志，并可能增加耗电。")
        }
        .tint(AmberTheme.accentAmber)
        .onReceive(NotificationCenter.default.publisher(for: .amberBackgroundLocationKeepAliveChanged)) { _ in
            locationStatusRevision &+= 1
        }
    }
}
