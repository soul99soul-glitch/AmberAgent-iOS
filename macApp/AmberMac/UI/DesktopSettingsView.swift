import SwiftUI

struct DesktopSettingsView: View {
    @Bindable var settings: DesktopSettings
    private let catalog: any DesktopModelCatalog
    private let onOpenBackup: (() -> Void)?
    private let mcp: DesktopMCPManager?
    private let syncWorkspace: DesktopWorkspace?
    private let notifications: DesktopNotifications?
    private let onOpenStorage: (() -> Void)?
    private let speech: DesktopSpeechPlayer?
    @State private var speechPreviewID = UUID()
    @State private var login: DesktopCodexLogin
    @State private var catalogRequest = DesktopCatalogRequest()
    @State private var tab = 0
    @State private var previousTab = 0
    @State private var editingID: UUID?
    @State private var draft = Self.emptyProvider()
    @State private var savedDraft: DesktopProviderConfiguration?
    @State private var apiKey = ""
    @State private var savedKey = ""
    @State private var parameters: [UUID: ModelParameters] = [:]
    @State private var savedParameters: [UUID: ModelParameters] = [:]
    @State private var modelBeingEdited: UUID?
    @State private var selectedCatalogIDs: Set<String> = []
    @State private var status: String?
    @State private var failed = false
    @State private var credentialLoadFailed = false
    @State private var confirmsDelete = false
    @State private var pendingDestination: Destination?
    @State private var confirmsSwitch = false
    @State private var didLoad = false
    @State private var deleting = false
    @State private var grokSignedIn = false

    private enum Destination { case provider(UUID?), tab(Int) }
    private struct ModelParameters: Equatable {
        var context: String
        var temperature: String
        var output: String
        var headers: String
        var body: String
        init(_ model: DesktopModelConfiguration) {
            context = model.contextWindowTokens.map(String.init) ?? ""
            temperature = model.temperature.map { String($0) } ?? ""
            output = model.maxOutputTokens.map(String.init) ?? ""
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            headers = model.customHeaders.isEmpty ? "" : (try? String(decoding: encoder.encode(model.customHeaders), as: UTF8.self)) ?? ""
            body = model.customBody ?? ""
        }
    }

    init(settings: DesktopSettings, catalog: any DesktopModelCatalog, oauth: any DesktopCodexAuthorizer,
        onOpenBackup: (() -> Void)? = nil, mcp: DesktopMCPManager? = nil, syncWorkspace: DesktopWorkspace? = nil,
        notifications: DesktopNotifications? = nil, onOpenStorage: (() -> Void)? = nil, speech: DesktopSpeechPlayer? = nil) {
        self.settings = settings
        self.catalog = catalog
        self.onOpenBackup = onOpenBackup
        self.mcp = mcp
        self.syncWorkspace = syncWorkspace
        self.notifications = notifications
        self.onOpenStorage = onOpenStorage
        self.speech = speech
        _login = State(initialValue: DesktopCodexLogin(authorizer: oauth))
    }
    private var hasUnsavedChanges: Bool {
        draft != savedDraft || apiKey != savedKey || parameters != savedParameters
    }
    private var canSave: Bool {
        !credentialLoadFailed && !deleting && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var requestIdentity: [String] {
        [draft.id.uuidString, draft.kind.rawValue, draft.authMode.rawValue, draft.baseURL, apiKey]
    }

    var body: some View {
        observedTabs
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            apply(.provider(settings.selectedProviderID ?? settings.providers.first?.id))
        }
        .onDisappear {
            catalogRequest.cancel(); login.cancel()
            if speech?.currentMessageID == speechPreviewID { speech?.stop() }
        }
        .confirmationDialog("有尚未保存的配置", isPresented: $confirmsSwitch, titleVisibility: .visible) {
            Button("保存并继续") {
                let destination = pendingDestination
                if save(), let destination { apply(destination) }
            }.disabled(!canSave)
            Button("放弃修改", role: .destructive) { if let destination = pendingDestination { apply(destination) } }
            Button("取消", role: .cancel) { pendingDestination = nil }
        } message: { Text("请先保存或放弃当前服务商及模型的修改。") }
        .confirmationDialog("移除这个服务商？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("移除服务商", role: .destructive) { deleteProvider() }
        } message: { Text("API Key 和登录凭证也会从钥匙串移除。已有会话会保留。") }
    }

    private var observedTabs: some View {
        tabs
        .onChange(of: draft) { clearSavedStatus() }
        .onChange(of: apiKey) { clearSavedStatus() }
        .onChange(of: parameters) { clearSavedStatus(); invalidateModelTest() }
        .onChange(of: draft.models) {
            invalidateModelTest()
            let selected = draft.selectedModel?.id
            if draft.selectedModelID != selected { draft.selectedModelID = selected }
        }
        .onChange(of: draft.selectedModelID) { invalidateModelTest() }
        .onChange(of: requestIdentity) { catalogRequest.cancel(); selectedCatalogIDs = [] }
        .onChange(of: draft.kind) { old, value in
            if draft.baseURL == old.defaultBaseURL { draft.baseURL = value.defaultBaseURL }
            if draft.authMode == .codexOAuth && value != .responses { draft.authMode = .apiKey }
            if draft.authMode == .antigravityOAuth && value != .gemini { draft.authMode = .apiKey }
            if draft.authMode == .grokOAuth && value != .openAI { draft.authMode = .apiKey }
        }
    }

    private var tabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                Text("设置").font(DesktopTheme.serif(size: 22, weight: .semibold)).foregroundStyle(DesktopTheme.ink)
                Spacer()
                DesktopSegmented(options: [(0, "服务商"), (1, "通用")] + (mcp != nil ? [(2, "MCP")] : []) + (syncWorkspace != nil ? [(3, "同步")] : []),
                    selection: Binding(get: { tab }, set: { request(.tab($0)) }))
                    .accessibilityLabel("设置分类")
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 18)
            Rectangle().fill(DesktopTheme.hairline).frame(height: 1)
            ZStack {
                switch tab {
                case 1: general.modifier(DesktopTabTransition(forward: tab > previousTab))
                case 2: if let mcp { DesktopMCPSettingsView(manager: mcp).modifier(DesktopTabTransition(forward: tab > previousTab)) }
                case 3: if let syncWorkspace { DesktopWebDAVSettingsView(workspace: syncWorkspace).modifier(DesktopTabTransition(forward: tab > previousTab)) }
                default: providers.modifier(DesktopTabTransition(forward: tab > previousTab))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onChange(of: tab) { old, _ in previousTab = old }
        }
        .background(DesktopTheme.paper)
        .frame(width: 880, height: 700)
        .tint(DesktopTheme.accent)
        .preferredColorScheme(DesktopTheme.colorScheme(for: settings.appearance))
    }

    private var providers: some View {
        HSplitView {
            VStack(spacing: 0) {
                // Selection is the amber glow, not the system highlight (which turns rows blue and kills ink contrast).
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(settings.providers) { provider in
                            DesktopSelectableRow(selected: editingID == provider.id, action: { request(.provider(provider.id)) }) {
                                HStack(spacing: 10) {
                                    Circle().fill(settings.selectedProviderID == provider.id ? DesktopTheme.accent : DesktopTheme.hairlineStrong)
                                        .frame(width: 6, height: 6)
                                        .help(settings.selectedProviderID == provider.id ? "当前对话使用的服务商" : "")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(provider.name).font(.system(size: 14)).foregroundStyle(DesktopTheme.ink).lineLimit(1)
                                        Text("\(provider.models.filter(\.enabled).count) 个启用模型").font(.system(size: 12)).foregroundStyle(editingID == provider.id ? DesktopTheme.inkSecondary : DesktopTheme.inkTertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                HStack {
                    Button { request(.provider(nil)) } label: { Image(systemName: "plus").frame(width: 26, height: 26) }
                        .help("添加服务商").accessibilityLabel("添加服务商")
                    Button { confirmsDelete = true } label: { Image(systemName: "minus").frame(width: 26, height: 26) }
                        .disabled(editingID == nil).help("移除服务商").accessibilityLabel("移除服务商")
                    Spacer()
                }.buttonStyle(DesktopQuietButtonStyle()).padding(.horizontal, 10).frame(height: 40)
                .overlay(alignment: .top) { Rectangle().fill(DesktopTheme.hairline).frame(height: 1) }
            }.frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
            VStack(spacing: 0) {
                Form {
                    providerConfiguration
                    if draft.authMode == .codexOAuth { codexAuthentication }
                    #if !AMBER_MAC_PREVIEW
                    if draft.authMode == .grokOAuth {
                        DesktopGrokAuthentication(providerID: editingID, baseURL: $draft.baseURL,
                            hasUnsavedChanges: hasUnsavedChanges, signedIn: $grokSignedIn)
                            .id(editingID)
                    }
                    #endif
                    models
                    if !catalogRequest.models.isEmpty { catalogModels }
                }.formStyle(.grouped).scrollContentBackground(.hidden)
                statusFooter
            }.frame(minWidth: 560, maxWidth: .infinity)
        }.disabled(deleting)
    }

    private var providerConfiguration: some View {
        Section(editingID == nil ? "添加服务商" : "服务商配置") {
            TextField("名称", text: $draft.name, prompt: Text("例如：OpenAI / 本地模型")).accessibilityIdentifier("provider-name")
            Picker("协议", selection: $draft.kind) {
                ForEach(DesktopProviderKind.allCases) { Text($0.title).tag($0) }
            }
            TextField("API 地址", text: $draft.baseURL).accessibilityIdentifier("provider-base-url")
            Picker("认证方式", selection: $draft.authMode) {
                Text("API Key").tag(DesktopProviderAuthMode.apiKey)
                if draft.kind == .responses { Text("ChatGPT / Codex 登录").tag(DesktopProviderAuthMode.codexOAuth) }
                if draft.kind == .openAI { Text("Grok / xAI 登录").tag(DesktopProviderAuthMode.grokOAuth) }
                if draft.authMode == .antigravityOAuth { Text("已有 Antigravity 登录").tag(DesktopProviderAuthMode.antigravityOAuth) }
            }
            if draft.authMode == .apiKey {
                SecureField("API Key", text: $apiKey).accessibilityIdentifier("provider-api-key")
            }
            Text("基础地址须使用 HTTPS；本机模型支持 localhost 回环地址。认证方式与协议分别保存。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            HStack {
                Button("获取模型列表") { fetchModels(testOnly: false) }
                Button("测试模型生成") { fetchModels(testOnly: true) }.disabled(draft.selectedModel == nil)
                if catalogRequest.isLoading {
                    ProgressView().controlSize(.small)
                    Button("取消") { catalogRequest.cancel() }.buttonStyle(.borderless)
                }
            }.disabled(credentialLoadFailed || (draft.authMode == .codexOAuth && (editingID == nil || login.account == nil))
                || (draft.authMode == .grokOAuth && (editingID == nil || !grokSignedIn)))
            if let message = catalogRequest.status { statusText(message, failed: catalogRequest.failed) }
        }
    }

    private var codexAuthentication: some View {
        Section("ChatGPT / Codex 登录") {
            if let account = login.account {
                let label = [account.email, account.plan].compactMap { $0 }.joined(separator: " · ")
                LabeledContent("已登录", value: label.isEmpty ? "ChatGPT 账号" : label)
            }
            Text("先保存服务商，再获取登录码。Codex 使用 https://chatgpt.com/backend-api/codex；更换服务地址请先保存。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).textSelection(.enabled)
            if draft.baseURL != "https://chatgpt.com/backend-api/codex" {
                Button("使用 Codex 服务地址") { draft.baseURL = "https://chatgpt.com/backend-api/codex" }
            }
            if let authorization = login.authorization {
                LabeledContent("设备码") {
                    Text(authorization.userCode).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                Link("在浏览器中打开登录页", destination: authorization.verificationURL)
            }
            HStack {
                if login.isBusy {
                    ProgressView().controlSize(.small)
                    Button("取消登录") { login.cancel() }
                } else {
                    Button(login.account == nil ? "获取登录码" : "重新登录") { if let id = editingID { login.login(id) } }
                        .disabled(editingID == nil || hasUnsavedChanges)
                }
                if login.account != nil || login.isBusy {
                    Button("退出登录") { if let id = editingID { login.logout(id) } }.disabled(editingID == nil)
                }
            }
            if hasUnsavedChanges { Text("保存当前配置后即可登录。模型可在登录后从目录添加。").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary) }
            if let message = login.status { statusText(message, failed: login.failed) }
        }
    }

    private var models: some View {
        Section("模型") {
            if draft.models.isEmpty {
                Text("填好地址和 API Key 后，点「获取模型列表」勾选要用的模型；服务商不提供列表时再手动添加。")
                    .font(.system(size: 13)).foregroundStyle(DesktopTheme.inkTertiary)
            } else {
                ForEach(draft.models) { model in
                    HStack(spacing: 10) {
                        Toggle("启用 \(model.displayName)", isOn: modelBinding(model.id, \.enabled, fallback: true))
                            .labelsHidden().toggleStyle(.checkbox)
                        Button { modelBeingEdited = model.id } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName.isEmpty ? "新模型" : model.displayName).lineLimit(1)
                                if !model.name.isEmpty { Text(model.modelID).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).lineLimit(1) }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if draft.selectedModelID == model.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(DesktopTheme.accent).help("当前模型") }
                        Button { removeModel(model.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(DesktopTheme.inkTertiary)
                            .help("移除模型").accessibilityLabel("移除 \(model.displayName)")
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(modelBeingEdited == model.id ? DesktopTheme.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Button("手动输入模型 ID", systemImage: "plus") {
                let model = DesktopModelConfiguration(modelID: "")
                draft.models.append(model); parameters[model.id] = ModelParameters(model)
                modelBeingEdited = model.id
                if draft.selectedModelID == nil { draft.selectedModelID = model.id }
            }
            if let id = modelBeingEdited, let model = draft.models.first(where: { $0.id == id }) {
                modelEditor(id: id, model: model)
            }
        }
    }

    @ViewBuilder private func modelEditor(id: UUID, model: DesktopModelConfiguration) -> some View {
        TextField("模型 ID", text: modelBinding(id, \.modelID, fallback: ""), prompt: Text("服务商提供的精确 ID")).accessibilityIdentifier("provider-model-id")
        TextField("显示名称", text: modelBinding(id, \.name, fallback: ""), prompt: Text("可留空"))
        TextField("上下文窗口", text: parameterBinding(id, \.context), prompt: Text("可留空，单位 token"))
        TextField("Temperature", text: parameterBinding(id, \.temperature), prompt: Text(draft.kind == .claude ? "默认，或 0–1" : "默认，或 0–2"))
        TextField("最大输出", text: parameterBinding(id, \.output), prompt: Text("可留空，单位 token"))
        Picker("推理强度", selection: modelBinding(id, \.reasoning, fallback: .off)) {
            ForEach(DesktopReasoningLevel.allCases) { Text($0.title).tag($0) }
        }
        Picker("图片理解", selection: modelBinding(id, \.supportsVision, fallback: nil)) {
            Text("自动识别能力").tag(nil as Bool?)
            Text("支持图片").tag(Optional(true))
            Text("仅文本").tag(Optional(false))
        }
        DisclosureGroup("自定义请求覆盖") {
            VStack(alignment: .leading, spacing: 8) {
                Text("请求头 · JSON 字符串字典").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                TextEditor(text: parameterBinding(id, \.headers)).font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 70, maxHeight: 140).desktopEditor().accessibilityLabel("自定义请求头 JSON")
                Text("请求体 · JSON 对象").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                TextEditor(text: parameterBinding(id, \.body)).font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 90, maxHeight: 180).desktopEditor().accessibilityLabel("自定义请求体 JSON")
                Text("留空使用默认值；填写后覆盖同名请求字段。覆盖会随模型配置备份；API Key 请使用上方钥匙串字段。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            }.padding(.top, 6)
        }
        Button(draft.selectedModelID == id ? "当前模型" : "保存并使用此模型") {
            draft.selectedModelID = id
            if save() { settings.selectModel(id) }
        }.disabled(!model.enabled || !canSave)
    }

    private var catalogModels: some View {
        Section("可添加的模型") {
            Text("添加会保留已有模型的标识、名称和参数。").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            ForEach(catalogRequest.models) { model in
                Toggle(isOn: Binding(get: { selectedCatalogIDs.contains(model.id) }, set: {
                    if $0 { selectedCatalogIDs.insert(model.id) } else { selectedCatalogIDs.remove(model.id) }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name.isEmpty ? model.modelID : model.name)
                        if model.name != model.modelID { Text(model.modelID).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary) }
                    }
                    if draft.models.contains(where: { $0.modelID == model.modelID }) {
                        Spacer()
                        Text("已添加").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    }
                }.toggleStyle(.checkbox).disabled(draft.models.contains(where: { $0.modelID == model.modelID }))
            }
            Button("添加所选模型（\(selectedCatalogIDs.count)）") {
                draft.models.removeAll { $0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if let selected = draft.selectedModelID, !draft.models.contains(where: { $0.id == selected }) { draft.selectedModelID = nil }
                if let editing = modelBeingEdited, !draft.models.contains(where: { $0.id == editing }) { modelBeingEdited = nil }
                let previous = Set(draft.models.map(\.id))
                draft.models = DesktopModelCatalogMerge.merge(catalogRequest.models.filter { selectedCatalogIDs.contains($0.id) }, into: draft.models)
                for model in draft.models where !previous.contains(model.id) { parameters[model.id] = ModelParameters(model) }
                if draft.selectedModelID == nil { draft.selectedModelID = draft.models.first(where: \.enabled)?.id }
                if modelBeingEdited == nil { modelBeingEdited = draft.selectedModelID }
                catalogRequest.cancel(); selectedCatalogIDs = []
            }.disabled(selectedCatalogIDs.isEmpty)
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status {
                HStack(alignment: .top) {
                    statusText(status, failed: failed)
                    if credentialLoadFailed { Button("重新读取") { load(editingID) }.buttonStyle(.borderless) }
                }
            }
            HStack {
                Text(hasUnsavedChanges ? "有未保存的修改" : "凭证仅保存到系统钥匙串").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                Spacer()
                Button("保存配置") { save() }.buttonStyle(.desktopProminent).disabled(!canSave)
                    .keyboardShortcut("s", modifiers: .command).accessibilityIdentifier("save-provider")
            }
        }.padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var general: some View {
        Form {
            Section("外观") {
                LabeledContent("主题") {
                    DesktopSegmented(options: [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")], selection: $settings.appearance)
                }
            }
            Section("系统提示词") {
                Text("用于之后发送的请求。已有消息会保留原样。").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                TextEditor(text: $settings.systemPrompt).font(.system(size: 13)).frame(minHeight: 140)
                    .desktopEditor()
                    .accessibilityLabel("系统提示词")
            }
            Section("聊天显示") {
                Picker("字体", selection: $settings.messageFontFamily) {
                    ForEach(DesktopMessageFontFamily.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("字号") {
                    HStack {
                        Slider(value: $settings.messageFontSize, in: 12...22, step: 1).frame(maxWidth: 220)
                        Text("\(Int(settings.messageFontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                TextField("助手称呼", text: $settings.assistantName, prompt: Text("Amber"))
                TextField("用户昵称", text: $settings.userNickname, prompt: Text("你"))
                Toggle("默认展开思考内容", isOn: $settings.reasoningExpandedByDefault)
                Toggle("生成时自动跟随", isOn: $settings.automaticallyFollowGeneration)
                Text("自动跟随仅在你已位于对话底部时生效；查看历史消息时不会抢回滚动位置。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            }
            Section("辅助任务模型") {
                ForEach(DesktopAuxiliaryModelTask.allCases) { task in
                    Picker(task.title, selection: Binding(get: { settings.auxiliaryModelIDs[task.rawValue] }, set: { settings.setAuxiliaryModel($0, for: task) })) {
                        Text(task == .imageGeneration ? "未配置" : task == .vision ? "不自动回退" : "跟随当前模型").tag(nil as UUID?)
                        ForEach(settings.modelSelections) { model in
                            Text("\(model.providerName) · \(model.modelName)").tag(Optional(model.id))
                        }
                    }
                }
                Text("仅显示已启用模型。图片生成必须明确选择生图模型；当前模型未标为支持图片时使用已配置的回退模型。").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            }
            if let speech {
                Section("系统朗读") {
                    Picker("声音", selection: $settings.speechVoiceIdentifier) {
                        Text("系统默认").tag("")
                        ForEach(speech.availableVoices) { voice in
                            Text("\(voice.name) · \(voice.language)").tag(voice.id)
                        }
                        if !settings.speechVoiceIdentifier.isEmpty,
                           !speech.availableVoices.contains(where: { $0.id == settings.speechVoiceIdentifier }) {
                            Text("已选声音暂不可用").tag(settings.speechVoiceIdentifier)
                        }
                    }
                    HStack {
                        Text("语速")
                        Text("慢").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                        Slider(value: $settings.speechRate, in: 0.2...0.6, step: 0.05).frame(maxWidth: 240)
                        Text("快").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    }
                    HStack {
                        Button("试听") {
                            speech.speak(text: "你好，我是\(settings.assistantDisplayName)。这是系统朗读试听。", messageID: speechPreviewID)
                        }
                        Button("停止朗读") { speech.stop() }.disabled(!speech.isSpeaking)
                        if speech.isLoadingVoices { ProgressView().controlSize(.small) }
                    }
                    if let error = speech.error { Text(error).font(.system(size: 12)).foregroundStyle(DesktopTheme.accent) }
                    Text("使用这台 Mac 已安装的系统声音；消息操作菜单可朗读正文。").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                }.task { await speech.loadVoices() }
            }
            if let notifications {
                Section("任务通知") {
                    Toggle("完成或失败时通知", isOn: Binding(get: { settings.notificationsEnabled }, set: { enabled in
                        Task { await notifications.setEnabled(enabled) }
                    })).disabled(notifications.isRequestingAuthorization)
                    if notifications.isRequestingAuthorization { ProgressView().controlSize(.small) }
                    if let message = notifications.authorizationMessage {
                        Text(message).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    }
                    if let error = notifications.lastDeliveryError {
                        Text(error).font(.system(size: 12)).foregroundStyle(DesktopTheme.accent)
                    }
                    Text("默认关闭。启用后会向系统请求权限；通知不包含会话内容。")
                        .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                }.task { await notifications.refreshAuthorization() }
            }
            Section("数据与凭证") {
                Text("会话保存在这台 Mac。API Key 和登录凭证保存在系统钥匙串，不包含在会话导出文件里。")
                    .font(.system(size: 13)).foregroundStyle(DesktopTheme.inkTertiary)
                if let onOpenBackup { Button("备份与恢复…", action: onOpenBackup) }
                if let onOpenStorage { Button("存储用量…", action: onOpenStorage) }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }

    private func statusText(_ message: String, failed: Bool) -> some View {
        Label(message, systemImage: failed ? "exclamationmark.circle" : "info.circle")
            .font(.system(size: 13)).foregroundStyle(failed ? DesktopTheme.danger : DesktopTheme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private func modelBinding<Value>(_ id: UUID, _ path: WritableKeyPath<DesktopModelConfiguration, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { draft.models.first(where: { $0.id == id })?[keyPath: path] ?? fallback }, set: { value in
            if let index = draft.models.firstIndex(where: { $0.id == id }) { draft.models[index][keyPath: path] = value }
        })
    }
    private func parameterBinding(_ id: UUID, _ path: WritableKeyPath<ModelParameters, String>) -> Binding<String> {
        Binding(get: { parameters[id]?[keyPath: path] ?? "" }, set: { value in
            guard var fields = parameters[id] else { return }
            fields[keyPath: path] = value; parameters[id] = fields
        })
    }
    private func configuredDraft() throws -> DesktopProviderConfiguration {
        var value = draft
        // A row added by「手动添加模型」and never filled carries no meaning; drop it rather than block saving.
        value.models.removeAll { $0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let selected = value.selectedModelID, !value.models.contains(where: { $0.id == selected }) {
            value.selectedModelID = value.models.first(where: \.enabled)?.id
        }
        for index in value.models.indices {
            guard let fields = parameters[value.models[index].id] else { continue }
            func integer(_ input: String, label: String) throws -> Int? {
                let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { return nil }
                guard let number = Int(text) else { throw DesktopRuntimeError.message("\(label)须为正整数。") }
                return number
            }
            value.models[index].contextWindowTokens = try integer(fields.context, label: "上下文窗口")
            value.models[index].maxOutputTokens = try integer(fields.output, label: "最大输出")
            let temperature = fields.temperature.trimmingCharacters(in: .whitespacesAndNewlines)
            if temperature.isEmpty { value.models[index].temperature = nil }
            else if let number = Double(temperature) { value.models[index].temperature = number }
            else { throw DesktopRuntimeError.message("Temperature 须为数字。") }
            let headers = fields.headers.trimmingCharacters(in: .whitespacesAndNewlines)
            if headers.isEmpty { value.models[index].customHeaders = [:] }
            else if let data = headers.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data),
                    let headers = object as? [String: String] { value.models[index].customHeaders = headers }
            else { throw DesktopRuntimeError.message("自定义请求头须为 JSON 字符串字典。") }
            value.models[index].customBody = fields.body
        }
        return value
    }
    private func removeModel(_ id: UUID) {
        draft.models.removeAll { $0.id == id }; parameters[id] = nil
        if draft.selectedModelID == id { draft.selectedModelID = draft.models.first(where: \.enabled)?.id }
        if modelBeingEdited == id { modelBeingEdited = draft.models.first?.id }
    }
    private func clearSavedStatus() {
        if hasUnsavedChanges && !credentialLoadFailed { status = nil; failed = false }
    }
    private func invalidateModelTest() {
        if catalogRequest.isTestingConnection { catalogRequest.cancel() }
    }
    private func request(_ destination: Destination) {
        guard !deleting else { return }
        if case .provider(let id) = destination, id == editingID, id != nil { return }
        if case .tab(let value) = destination, value == tab { return }
        if hasUnsavedChanges { pendingDestination = destination; confirmsSwitch = true }
        else { apply(destination) }
    }
    private func apply(_ destination: Destination) {
        pendingDestination = nil
        switch destination {
        case .provider(let id): load(id)
        case .tab(let value):
            if hasUnsavedChanges { load(editingID) }
            tab = value
        }
    }
    private func load(_ id: UUID?) {
        catalogRequest.cancel(); selectedCatalogIDs = []
        editingID = id
        draft = settings.providers.first(where: { $0.id == id }) ?? Self.emptyProvider()
        // The first-run template carries one empty model slot; models come from「获取模型列表」, so hide it.
        draft.models.removeAll { $0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let selected = draft.selectedModelID, !draft.models.contains(where: { $0.id == selected }) { draft.selectedModelID = nil }
        status = nil; failed = false; credentialLoadFailed = false; apiKey = ""
        if let id {
            do { apiKey = try settings.apiKey(for: id) }
            catch { credentialLoadFailed = true; status = error.localizedDescription; failed = true }
        }
        parameters = Dictionary(uniqueKeysWithValues: draft.models.map { ($0.id, ModelParameters($0)) })
        modelBeingEdited = draft.selectedModel?.id ?? draft.models.first?.id
        savedDraft = draft; savedKey = apiKey; savedParameters = parameters
        login.selectProvider(id)
        #if !AMBER_MAC_PREVIEW
        grokSignedIn = id.map { IOSGrokOAuthAuthStore.load(providerId: $0.uuidString.lowercased()) != nil } ?? false
        #endif
    }
    @discardableResult private func save() -> Bool {
        do {
            let value = try configuredDraft()
            try settings.saveProvider(value, apiKey: apiKey)
            load(value.id)
            status = "已保存"; failed = false
            return !credentialLoadFailed
        } catch { status = error.localizedDescription; failed = true; return false }
    }
    private func fetchModels(testOnly: Bool) {
        do {
            let value: DesktopProviderConfiguration
            if testOnly { value = try configuredDraft() } else { value = draft }
            try DesktopSettings.validateEndpoint(value.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            if testOnly {
                guard let model = value.selectedModel else { throw DesktopRuntimeError.message("请先添加并启用一个模型。") }
                _ = try model.validated(for: value.kind)
            }
            selectedCatalogIDs = []
            catalogRequest.fetch(configuration: value, apiKey: apiKey, catalog: catalog, testOnly: testOnly)
        } catch { status = error.localizedDescription; failed = true }
    }
    private func deleteProvider() {
        guard let id = editingID else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                try await login.removeCredentials(id)
                try settings.deleteProvider(id)
                load(settings.providers.first?.id)
            } catch { status = "移除服务商失败，请解锁钥匙串后重试。"; failed = true }
        }
    }
    private static func emptyProvider() -> DesktopProviderConfiguration {
        DesktopProviderConfiguration(name: "", kind: .openAI, baseURL: DesktopProviderKind.openAI.defaultBaseURL, models: [])
    }
}

#if !AMBER_MAC_PREVIEW
/// Grok (SpaceXAI OAuth) section; reuses the iOS PKCE + loopback login model and mirrors the Codex section layout.
private struct DesktopGrokAuthentication: View {
    let providerID: UUID?
    @Binding var baseURL: String
    let hasUnsavedChanges: Bool
    @Binding var signedIn: Bool
    @StateObject private var model: GrokWebLoginModel

    init(providerID: UUID?, baseURL: Binding<String>, hasUnsavedChanges: Bool, signedIn: Binding<Bool>) {
        self.providerID = providerID
        _baseURL = baseURL
        self.hasUnsavedChanges = hasUnsavedChanges
        _signedIn = signedIn
        _model = StateObject(wrappedValue: GrokWebLoginModel(
            providerId: providerID?.uuidString.lowercased() ?? "unsaved", providerBackup: nil))
    }

    private var isBusy: Bool {
        switch model.phase {
        case .requesting, .awaitingAuthorization, .signingIn: true
        default: false
        }
    }

    var body: some View {
        Section("Grok / xAI 登录") {
            if case .signedIn(let email) = model.phase {
                LabeledContent("已登录", value: email.flatMap { $0.isEmpty ? nil : $0 } ?? "Grok 账号")
            }
            Text("先保存服务商，再在浏览器完成 xAI 授权。Grok 登录使用 \(IOSGrokOAuthConstants.cliProxyBaseUrl)，无需 API Key。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary).textSelection(.enabled)
            if baseURL != IOSGrokOAuthConstants.cliProxyBaseUrl {
                Button("使用 Grok 服务地址") { baseURL = IOSGrokOAuthConstants.cliProxyBaseUrl }
            }
            HStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                    Button("取消登录") { model.cancelLogin() }
                } else {
                    Button(model.isSignedIn ? "重新登录" : "登录") {
                        model.startLogin { signedIn = true }
                    }.disabled(providerID == nil || hasUnsavedChanges)
                }
                if model.isSignedIn || isBusy {
                    Button("退出登录") { model.logout { _ in signedIn = false } }.disabled(providerID == nil)
                }
            }
            if hasUnsavedChanges { Text("保存当前配置后即可登录。模型可在登录后从目录添加。").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary) }
            switch model.phase {
            case .awaitingAuthorization: statusText("在浏览器完成登录后，此处会自动更新。", failed: false)
            case .failed(let message): statusText(message, failed: true)
            default: EmptyView()
            }
        }
        .onDisappear { model.cancelLogin() }
    }

    private func statusText(_ message: String, failed: Bool) -> some View {
        Label(message, systemImage: failed ? "exclamationmark.circle" : "info.circle")
            .font(.system(size: 13)).foregroundStyle(failed ? DesktopTheme.danger : DesktopTheme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}
#endif
