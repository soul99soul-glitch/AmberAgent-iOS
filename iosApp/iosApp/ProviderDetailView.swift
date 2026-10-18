import SwiftUI
import Shared

struct ProviderDetailView: View {
    @Bindable var settingsStore: SettingsStore
    let providerRegistry: ProviderRegistryStore
    let sharedSettings: IOSSharedSettingsStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let providerId: String

    @State private var selectedTab: ProviderDetailTab = .config
    @State private var alert: ProviderDetailAlert?
    @State private var connectionStatus: ProviderConnectionStatus = .idle
    @State private var fetchState: ProviderModelFetchState = .idle
    @State private var availableModels: [Model] = []
    @State private var modelFetchTask: Task<Void, Never>?
    @State private var modelFetchRequestID: UUID?
    @State private var modelDraft: ProviderModelDraft?

    @State private var draftName = ""
    @State private var draftEnabled = true
    @State private var draftApiKey = ""
    @State private var draftBaseURL = ""
    @State private var draftChatPath = "/chat/completions"
    @State private var draftUseResponseAPI = false
    @State private var draftPromptCaching = false
    @State private var draftUserAgent = ""
    @State private var draftExtraHeaders: [ProviderHeaderDraft] = []
    @State private var selectedUserAgentPreset: ProviderUserAgentPreset?
    @State private var notice: String?
    @State private var showCodexLogin = false
    @State private var showGrokLogin = false
    @State private var showAntigravityLogin = false

    init(settingsStore: SettingsStore, providerRegistry: ProviderRegistryStore,
         sharedSettings: IOSSharedSettingsStore, providerId: String,
         initiallyShowsModels: Bool = false) {
        self.settingsStore = settingsStore
        self.providerRegistry = providerRegistry
        self.sharedSettings = sharedSettings
        self.providerId = providerId
        _selectedTab = State(initialValue: initiallyShowsModels ? .models : .config)
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                chrome

                ZStack {
                    if provider == nil {
                        missingProviderPanel
                    } else {
                        switch selectedTab {
                        case .config:
                            configPanel
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        case .models:
                            modelsPanel
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: loadDraft)
        .onChange(of: sharedSettings.revision) { _, _ in loadDraft() }
        .onDisappear { cancelModelFetch() }
        .alert(item: Binding(
            get: { modelDraft == nil ? alert : nil },
            set: { alert = $0 }
        ), content: makeAlert)
        .sheet(item: $modelDraft) { draft in
            ProviderModelEditorSheet(
                draft: draft,
                onSave: saveModelDraft
            )
            .alert(item: $alert, content: makeAlert)
        }
        .sheet(isPresented: $showCodexLogin) {
            CodexLoginView(
                providerId: providerId,
                onAuthModeChange: { mode in
                    cancelModelFetch(clearAvailableModels: true)
                    _ = sharedSettings.setOpenAIAuthMode(providerId: providerId, authMode: mode)
                    if isCurrentProvider {
                        sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
                    }
                },
                onModelsFetched: { models in
                    guard let provider,
                          IOSCodexProviderResolver.isCodexProvider(provider),
                          IOSCodexProviderResolver.isSignedIn(provider) else { return }
                    cancelModelFetch()
                    availableModels = IOSCodexModelCatalog.models(discovered: models)
                    fetchState = .success("已刷新 Codex 聊天模型；GPT Image 生图预设可在模型页单独添加。")
                    selectedTab = .models
                }
            )
        }
        .sheet(isPresented: $showGrokLogin) {
            GrokWebLoginView(
                providerId: providerId,
                providerBackup: grokProviderBackup,
                onSignedIn: {
                    cancelModelFetch(clearAvailableModels: true)
                    let previousUuid = currentModel?.id.description()
                    let previousModelId = currentModel?.modelId
                    let currentWasThisProvider = provider?.models.contains {
                        $0.id.description() == previousUuid
                    } == true
                    _ = sharedSettings.updateProviderEndpoint(
                        providerId: providerId,
                        baseUrl: IOSGrokWebConstants.cliProxyBaseUrl,
                        chatCompletionsPath: "/chat/completions",
                        useResponseApi: true,
                        promptCaching: false
                    )
                    let updated = sharedSettings.adoptGrokOAuthChatCatalog(
                        providerId: providerId,
                        models: IOSGrokWebConstants.fallbackModels,
                        dropModelIds: Array(IOSGrokWebConstants.legacyWebModelIds)
                    )
                    if currentWasThisProvider {
                        let stillThere = updated?.models.contains {
                            $0.id.description() == previousUuid
                        } == true
                        let wasLegacy = IOSGrokWebConstants.legacyWebModelIds.contains(previousModelId ?? "")
                        if !stillThere || wasLegacy,
                           let grok46 = updated?.models.first(where: {
                               $0.type == ModelType.chat && $0.modelId == "grok-4.6"
                           }) {
                            sharedSettings.selectChatModelAsDefault(grok46.id.description())
                        }
                    }
                    if isCurrentProvider {
                        sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
                    }
                    loadDraft()
                },
                onLoggedOut: { backup in
                    cancelModelFetch(clearAvailableModels: true)
                    if let backup {
                        _ = sharedSettings.updateProviderEndpoint(
                            providerId: providerId,
                            baseUrl: backup.baseUrl,
                            chatCompletionsPath: backup.chatCompletionsPath,
                            useResponseApi: backup.useResponseApi,
                            promptCaching: false
                        )
                    }
                    if isCurrentProvider {
                        sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
                    }
                    loadDraft()
                }
            )
        }
        .sheet(isPresented: $showAntigravityLogin) {
            AntigravityLoginView(
                providerId: providerId,
                onAuthModeChange: { mode in
                    cancelModelFetch(clearAvailableModels: true)
                    _ = sharedSettings.setGoogleAuthMode(providerId: providerId, authMode: mode)
                    if isCurrentProvider {
                        sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
                    }
                    loadDraft()
                },
                onSignedIn: {
                    cancelModelFetch(clearAvailableModels: true)
                    let shouldSeedModels = provider?.models.contains { $0.type == ModelType.chat } != true
                    if shouldSeedModels {
                        guard sharedSettings.updateProviderChatModels(
                            providerId: providerId,
                            models: IOSGeminiConstants.fallbackModels
                        ) != nil else {
                            showModelSaveFailure()
                            return
                        }
                    }
                    if isCurrentProvider {
                        sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
                    }
                    loadDraft()
                },
                onLoggedOut: {
                    cancelModelFetch(clearAvailableModels: true)
                    if isCurrentProvider {
                        sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
                    }
                    loadDraft()
                }
            )
        }
    }

    private var provider: ProviderSetting? {
        _ = sharedSettings.revision
        return sharedSettings.snapshot.providers.first { $0.id.description() == providerId }
    }

    private var providerName: String {
        provider?.name ?? "服务商"
    }

    private var isCodexProvider: Bool {
        guard let provider else { return false }
        return IOSCodexProviderResolver.isCodexProvider(provider)
    }

    var currentModel: Model? {
        _ = sharedSettings.revision
        return sharedSettings.snapshot.getCurrentChatModel()
    }

    private var isCurrentProvider: Bool {
        guard let provider, let currentModel else { return false }
        return currentModel.findProvider(providers: sharedSettings.snapshot.providers, checkOverwrite: true)?.id == provider.id
    }

    private var protocolOption: ProviderProtocolOption? {
        ProviderProtocolOption.option(for: provider)
    }

    private var chatModels: [Model] {
        provider?.models.filter { $0.type == ModelType.chat } ?? []
    }

    private var enabledModels: [Model] {
        provider?.models ?? []
    }

    var imageGenerationModel: Model? {
        _ = sharedSettings.revision
        let selectedId = sharedSettings.snapshot.imageGenerationModelId
        return provider?.models.first {
            $0.type == ModelType.image && $0.id == selectedId
        }
    }

    private var chrome: some View {
        VStack(spacing: 10) {
            HStack {
                AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回服务商", size: 44, symbolSize: 20) {
                    dismiss()
                }

                Spacer()

                Text(providerName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)

                Spacer()

                AmberGlassIconButton(
                    systemImage: "checkmark",
                    accessibilityLabel: "保存服务商",
                    size: 44,
                    symbolSize: 17,
                    tint: AmberTheme.accent,
                    prominent: true
                ) {
                    commitPendingTextInput {
                        if saveConfig(showSuccess: false) {
                            dismiss()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            ProviderSegmentedControl(selection: $selectedTab)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
    }

    private var missingProviderPanel: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AmberTheme.accentAmber)
            Text("找不到这个服务商")
                .font(.headline)
                .foregroundStyle(AmberTheme.foreground)
            Text("它可能已经被删除，请返回服务商列表重新选择。")
                .font(.footnote)
                .foregroundStyle(AmberTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var configPanel: some View {
        ScrollView {
            VStack(spacing: 0) {
                AmberSectionLabel(text: "配置")
                AmberFormGroup {
                    ProviderToggleRow(title: "启用", isOn: $draftEnabled)
                    ProviderDetailDivider()
                    ProviderEditableTextFieldRow(
                        title: "名称",
                        text: $draftName,
                        placeholder: "Provider"
                    )
                    ProviderDetailDivider()
                    protocolRow
                }

                AmberSectionLabel(text: "连接")
                AmberFormGroup {
                    if let openAI = provider as? ProviderSetting.OpenAI,
                       tokenPlanMode(for: openAI.brand) != nil {
                        tokenPlanSection
                        ProviderDetailDivider()
                    }
                    if provider is ProviderSetting.Google {
                        geminiAuthModeSection
                        ProviderDetailDivider()
                    }
                    if !isGeminiOAuth {
                        ProviderEditableTextFieldRow(
                            title: "API Key",
                            text: $draftApiKey,
                            placeholder: apiKeyPlaceholder,
                            isSecure: true,
                            monospace: true
                        )
                        ProviderDetailDivider()
                    }
                    if let openAI = provider as? ProviderSetting.OpenAI, isCodingPlan(openAI.authMode), openAI.brand != OpenAIBrand.mimo {
                        ProviderStaticRow(title: "API 地址", subtitle: "", value: draftBaseURL, valueStyle: .mono)
                    } else if isGeminiOAuth {
                        ProviderStaticRow(
                            title: "API 地址",
                            subtitle: "",
                            value: IOSGeminiConstants.cloudcodePaBaseUrl,
                            valueStyle: .mono
                        )
                    } else {
                        ProviderEditableTextFieldRow(
                            title: "API 地址",
                            text: $draftBaseURL,
                            placeholder: protocolOption?.defaultBaseURL ?? "https://api.openai.com/v1",
                            monospace: true
                        )
                    }
                    if provider is ProviderSetting.OpenAI {
                        ProviderDetailDivider()
                        ProviderEditableTextFieldRow(
                            title: "路径",
                            text: $draftChatPath,
                            placeholder: "/chat/completions",
                            monospace: true
                        )
                    }
                }
                if let openAI = provider as? ProviderSetting.OpenAI, isCodingPlan(openAI.authMode), openAI.brand != OpenAIBrand.mimo {
                    ProviderDetailFooter("已钉到该品牌官方 Coding Plan 地址。")
                } else if isGeminiOAuth {
                    ProviderDetailFooter("已钉到 Antigravity Gemini 官方地址。")
                }

                legacyKeyImportSection

                grokSection

                codexSection

                antigravitySection

                if provider is ProviderSetting.Claude {
                    AmberSectionLabel(text: "选项")
                    AmberFormGroup {
                        ProviderToggleRow(title: "Prompt Caching", isOn: $draftPromptCaching)
                    }
                }

                headerDisguiseSection

                if let notice {
                    ProviderDetailFooter(notice)
                }

                configActions
            }
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var protocolRow: some View {
        if provider is ProviderSetting.Google {
            ProviderStaticRow(title: "接口协议", subtitle: "", value: "Gemini")
        } else {
        Menu {
            ForEach(ProviderProtocolOption.switchableCases, id: \.self) { option in
                Button {
                    switchProtocol(to: option)
                } label: {
                    if option == protocolOption {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            ProviderRowContent(
                title: "接口协议",
                subtitle: "",
                value: protocolOption?.title ?? "待移植",
                valueStyle: .body,
                showsChevron: provider is ProviderSetting.OpenAI || provider is ProviderSetting.Claude,
                stacksValueOnAccessibility: true
            )
        }
        .buttonStyle(.plain)
        .disabled(!(provider is ProviderSetting.OpenAI || provider is ProviderSetting.Claude))
        }
    }

    @ViewBuilder
    private var tokenPlanSection: some View {
        if let openAI = provider as? ProviderSetting.OpenAI,
           let tokenPlan = tokenPlanMode(for: openAI.brand) {
            HStack(spacing: 0) {
                tokenPlanModeButton("API Key", selected: openAI.authMode == OpenAIAuthMode.apiKey) {
                    switchAuthMode(to: OpenAIAuthMode.apiKey)
                }
                tokenPlanModeButton("Token Plan", selected: openAI.authMode == tokenPlan) {
                    switchAuthMode(to: tokenPlan)
                }
            }
            .padding(3)
            .background(
                AmberTheme.surface2.opacity(0.88),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func tokenPlanModeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? AmberTheme.foreground : AmberTheme.muted)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(
                    selected ? AmberTheme.surface : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private var apiKeyPlaceholder: String {
        if protocolOption == .anthropic { return "sk-ant-..." }
        if protocolOption == .google { return "AIza..." }
        return "sk-..."
    }

    /// Gemini auth-mode switch: API Key vs Antigravity (Google account) OAuth.
    @ViewBuilder
    private var geminiAuthModeSection: some View {
        if let google = provider as? ProviderSetting.Google {
            HStack(spacing: 0) {
                geminiAuthModeButton("API Key", selected: google.authMode == GoogleAuthMode.apiKey) {
                    switchGoogleAuthMode(to: GoogleAuthMode.apiKey)
                }
                geminiAuthModeButton("Antigravity", selected: google.authMode == GoogleAuthMode.antigravityOauth) {
                    switchGoogleAuthMode(to: GoogleAuthMode.antigravityOauth)
                }
            }
            .padding(3)
            .background(
                AmberTheme.surface2.opacity(0.88),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func geminiAuthModeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? AmberTheme.foreground : AmberTheme.muted)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(
                    selected ? AmberTheme.surface : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func switchGoogleAuthMode(to mode: GoogleAuthMode) {
        guard saveConfig(showSuccess: false) else { return }
        cancelModelFetch(clearAvailableModels: true)
        _ = sharedSettings.setGoogleAuthMode(providerId: providerId, authMode: mode)
        if isCurrentProvider {
            sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
        }
        connectionStatus = .idle
        loadDraft()
        notice = mode == GoogleAuthMode.antigravityOauth
            ? IOSAppLocalization.string(
                "已切换到 Antigravity 登录模式。",
                defaultValue: "已切换到 Antigravity 登录模式。"
            )
            : IOSAppLocalization.string(
                "已切回 API Key 模式。",
                defaultValue: "已切回 API Key 模式。"
            )
    }

    /// Antigravity (Google account) sign-in entry for the Gemini provider in
    /// OAuth mode.
    @ViewBuilder
    private var antigravitySection: some View {
        if let google = provider as? ProviderSetting.Google,
           IOSGeminiProviderResolver.isAntigravityOAuth(google) {
            AmberSectionLabel(text: "Antigravity 登录 (Gemini)")
            AmberFormGroup {
                Button {
                    commitPendingTextInput {
                        guard saveConfig(showSuccess: false) else { return }
                        showAntigravityLogin = true
                    }
                } label: {
                    ProviderRowContent(
                        title: antigravitySignedIn ? "已登录 Antigravity" : "用 Google 账号登录",
                        subtitle: antigravitySubtitle,
                        value: antigravitySignedIn ? "管理" : "登录",
                        valueStyle: .accent,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var isGeminiOAuth: Bool {
        (provider as? ProviderSetting.Google).map {
            IOSGeminiProviderResolver.isAntigravityOAuth($0)
        } == true
    }

    private var antigravitySignedIn: Bool {
        _ = sharedSettings.revision
        return IOSAntigravityAuthStore.load(providerId: providerId) != nil
    }

    private var antigravitySubtitle: String {
        if let tokens = IOSAntigravityAuthStore.load(providerId: providerId) {
            let email = tokens.email ?? ""
            let tier = tokens.onboardedTier.map { " · \($0)" } ?? ""
            return email.isEmpty ? "已登录\(tier)" : "\(email)\(tier)"
        }
        return "Antigravity 是 Google 的 Gemini 产品，无需 API Key"
    }

    @ViewBuilder
    private var headerDisguiseSection: some View {
        if let current = provider as? ProviderSetting.OpenAI,
           !IOSCodexProviderResolver.isCodexProvider(current),
           !IOSGrokWebProviderResolver.isGrokWebProvider(current) {
            AmberSectionLabel(text: "请求伪装")
            AmberFormGroup {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ProviderUserAgentPreset.allCases) { preset in
                            Button {
                                applyUserAgentPreset(preset)
                            } label: {
                                Text(preset.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(
                                        selectedUserAgentPreset == preset
                                            ? AmberTheme.foreground
                                            : AmberTheme.foreground2
                                    )
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 44)
                                    .background(
                                        selectedUserAgentPreset == preset
                                            ? AmberTheme.background.opacity(0.92)
                                            : AmberTheme.surface2.opacity(0.7),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                ProviderDetailDivider()
                ProviderEditableTextFieldRow(
                    title: "User-Agent",
                    text: $draftUserAgent,
                    placeholder: OpenAICompatUserAgents.shared.OPENCODE,
                    monospace: true
                )
                .onChange(of: draftUserAgent) { _, value in
                    selectedUserAgentPreset = ProviderUserAgentPreset.matching(userAgent: value)
                }
                ForEach($draftExtraHeaders) { $header in
                    ProviderDetailDivider()
                    ProviderEditableTextFieldRow(
                        title: "名称",
                        text: $header.name,
                        placeholder: "Header name",
                        monospace: true
                    )
                    ProviderEditableTextFieldRow(
                        title: "值",
                        text: $header.value,
                        placeholder: "Header value",
                        monospace: true
                    )
                }
            }
            Button {
                draftExtraHeaders.append(ProviderHeaderDraft(name: "", value: ""))
            } label: {
                ProviderActionRow(systemImage: "plus.circle", title: "添加 Header", tint: AmberTheme.accent)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
    }

    /// Codex (ChatGPT account) sign-in entry, shown for the official OpenAI brand
    /// or a provider already switched to Codex OAuth.
    @ViewBuilder
    private var codexSection: some View {
        if let openAI = provider as? ProviderSetting.OpenAI,
           openAI.brand == OpenAIBrand.openai || openAI.authMode == OpenAIAuthMode.codexOauth {
            AmberSectionLabel(text: "ChatGPT 登录 (Codex)")
            AmberFormGroup {
                Button {
                    commitPendingTextInput {
                        guard saveConfig(showSuccess: false) else { return }
                        showCodexLogin = true
                    }
                } label: {
                    ProviderRowContent(
                        title: codexSignedIn ? "已登录 Codex" : "用 ChatGPT 登录",
                        subtitle: codexSubtitle,
                        value: codexSignedIn ? "管理" : "登录",
                        valueStyle: .accent,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var codexSignedIn: Bool {
        _ = sharedSettings.revision
        return IOSCodexAuthStore.load(providerId: providerId) != nil
    }

    private var codexSubtitle: String {
        if let tokens = IOSCodexAuthStore.load(providerId: providerId) {
            let email = tokens.email ?? ""
            let plan = tokens.planType.map { " · \($0)" } ?? ""
            return email.isEmpty ? "已登录\(plan)" : "\(email)\(plan)"
        }
        return "用 ChatGPT Plus/Pro/Team 账号,无需 API Key"
    }

    @ViewBuilder
    private var grokSection: some View {
        if IOSGrokWebProviderResolver.isXAIProvider(provider) {
            AmberSectionLabel(text: "Grok 登录")
            AmberFormGroup {
                Button {
                    commitPendingTextInput {
                        guard saveConfig(showSuccess: false) else { return }
                        showGrokLogin = true
                    }
                } label: {
                    ProviderRowContent(
                        title: grokSignedIn ? "已登录 Grok" : "用 Grok 账号登录",
                        subtitle: grokSubtitle,
                        value: grokSignedIn ? "管理" : "登录",
                        valueStyle: .accent,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var grokSignedIn: Bool {
        _ = sharedSettings.revision
        guard let provider else { return false }
        return IOSGrokWebProviderResolver.isSignedIn(provider)
    }

    private var grokSubtitle: String {
        if let email = IOSGrokOAuthAuthStore.load(providerId: providerId)?.email, !email.isEmpty {
            return email
        }
        if grokSignedIn {
            return "已登录"
        }
        return "用 SuperGrok 账号登录，调用 Grok 4.6，无需 API Key"
    }

    private var grokProviderBackup: IOSGrokWebProviderBackup? {
        if let stored = IOSGrokOAuthAuthStore.loadBackup(providerId: providerId) {
            return stored
        }
        if let fromTokens = IOSGrokOAuthAuthStore.load(providerId: providerId)?.providerBackup {
            return fromTokens
        }
        guard let openAI = provider as? ProviderSetting.OpenAI else { return nil }
        return IOSGrokWebProviderBackup(
            baseUrl: openAI.baseUrl,
            chatCompletionsPath: openAI.chatCompletionsPath,
            useResponseApi: openAI.useResponseApi
        )
    }

    @ViewBuilder
    private var legacyKeyImportSection: some View {
        let oldKey = settingsStore.currentApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerKey = apiKey(of: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        if !oldKey.isEmpty, providerKey.isEmpty, !isGeminiOAuth {
            Button {
                draftApiKey = oldKey
                saveConfig(showSuccess: false)
                notice = IOSAppLocalization.string(
                    "旧 API Key 已写入当前服务商。",
                    defaultValue: "旧 API Key 已写入当前服务商。"
                )
            } label: {
                ProviderRowContent(
                    title: "导入旧 API Key",
                    subtitle: "",
                    value: "导入",
                    valueStyle: .accent,
                    showsChevron: false
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    private var configActions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    commitPendingTextInput {
                        testConnection()
                    }
                } label: {
                    ProviderActionRow(
                        systemImage: connectionStatus.isTesting ? "hourglass" : "bolt.horizontal",
                        title: connectionStatus.isTesting ? "正在测试" : "测试连接",
                        tint: AmberTheme.accentAmber
                    )
                }
                .buttonStyle(.plain)
                .disabled(connectionStatus.isTesting)
                .opacity(connectionStatus.isTesting ? 0.65 : 1)

                if sharedSettings.canRemoveProvider(providerId: providerId) {
                    Button(role: .destructive) {
                        alert = .deleteProvider(providerName)
                    } label: {
                        ProviderActionRow(
                            systemImage: "trash",
                            title: "删除",
                            tint: .red
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let message = connectionStatus.message {
                ProviderConnectionResultRow(status: connectionStatus, message: message)
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
    }

    private func makeAlert(_ alert: ProviderDetailAlert) -> Alert {
        switch alert {
        case .deleteProvider:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .destructive(Text("删除"), action: deleteProvider),
                secondaryButton: .cancel(Text("取消"))
            )
        default:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private func deleteProvider() {
        guard sharedSettings.removeProvider(providerId: providerId) else {
            alert = .providerDeleteFailed
            return
        }
        sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
        dismiss()
    }

    private var modelsPanel: some View {
        ScrollView {
            VStack(spacing: 0) {
                AmberSectionLabel(text: "已启用模型")
                AmberFormGroup {
                    if enabledModels.isEmpty {
                        ProviderStaticRow(
                            title: "没有模型",
                            subtitle: "可自动获取模型，也可手动添加服务商文档中的 Model ID。",
                            value: "空"
                        )
                    } else {
                        ForEach(Array(enabledModels.enumerated()), id: \.offset) { index, model in
                            let selection = modelDefaultSelection(for: model)
                            ProviderModelRow(
                                systemImage: selection == nil ? modelSystemImage(for: model) : "checkmark.circle.fill",
                                name: displayName(for: model),
                                badge: selection ?? modelTypeTitle(for: model),
                                summary: modelSummary(model),
                                isCurrent: selection != nil,
                                canSetCurrent: model.type == ModelType.chat || model.type == ModelType.image,
                                setCurrentTitle: model.type == ModelType.image ? "设为生图默认" : "设为聊天默认",
                                onEdit: {
                                    modelDraft = ProviderModelDraft(model: model)
                                },
                                onSetCurrent: {
                                    setCurrent(model)
                                },
                                onDelete: {
                                    deleteModel(model)
                                }
                            )
                            .accessibilityIdentifier("provider.model.\(model.modelId)")
                            if index < enabledModels.count - 1 {
                                ProviderDetailDivider()
                            }
                        }
                    }
                }

                modelActions

                if !availableModels.isEmpty {
                    AmberSectionLabel(text: isCodexProvider ? "可用聊天模型与 GPT Image 生图预设" : "可用模型")
                    AmberFormGroup {
                        ForEach(Array(availableModels.enumerated()), id: \.offset) { index, model in
                            let enabledModel = enabledModels.first {
                                $0.modelId == model.modelId && $0.type == model.type
                            }
                            let selection = enabledModel.flatMap { modelDefaultSelection(for: $0) }
                            let isEmbedding = model.type == ModelType.embedding
                            Button {
                                if let enabledModel {
                                    if !isEmbedding {
                                        setCurrent(enabledModel)
                                    }
                                } else {
                                    addFetchedModel(model)
                                }
                            } label: {
                                ProviderRowContent(
                                    // Drop the duplicate ID line when the model has no
                                    // custom display name (name == id) — the big title
                                    // already shows it; printing it twice is pure clutter.
                                    title: displayName(for: model),
                                    subtitle: displayName(for: model) == model.modelId ? "" : model.modelId,
                                    value: selection ?? (enabledModel == nil ? "添加" : (isEmbedding ? "已添加" : "使用")),
                                    valueStyle: selection == nil && enabledModel == nil ? .accent : .body,
                                    showsChevron: false,
                                    stacksValueOnAccessibility: true
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(selection != nil || (isEmbedding && enabledModel != nil))

                            if index < availableModels.count - 1 {
                                ProviderDetailDivider()
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
    }

    private var modelActions: some View {
        VStack(spacing: 10) {
            modelActionButtons
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if let message = fetchState.message {
                ProviderDetailFooter(message)
            }
        }
    }

    @ViewBuilder
    private var modelActionButtons: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                fetchModelsButton
                addModelButton
            }
        } else {
            HStack(spacing: 10) {
                fetchModelsButton
                addModelButton
            }
        }
    }

    private var fetchModelsButton: some View {
        Button {
            fetchModels()
        } label: {
            ProviderActionRow(
                systemImage: fetchState.isLoading ? "hourglass" : "arrow.down.circle",
                title: fetchState.isLoading ? "正在获取" : "自动获取",
                tint: AmberTheme.accent
            )
        }
        .buttonStyle(.plain)
        .disabled(fetchState.isLoading)
    }

    private var addModelButton: some View {
        Button {
            modelDraft = ProviderModelDraft()
        } label: {
            ProviderActionRow(systemImage: "plus.circle", title: "手动添加", tint: AmberTheme.accent)
        }
        .buttonStyle(.plain)
    }

    private func loadDraft() {
        guard let provider else { return }
        draftName = provider.name
        draftEnabled = provider.enabled
        if let openAI = provider as? ProviderSetting.OpenAI {
            draftApiKey = openAI.apiKey
            draftBaseURL = openAI.baseUrl
            draftChatPath = openAI.chatCompletionsPath
            draftUseResponseAPI = openAI.useResponseApi
            draftPromptCaching = false
            let stored = IOSProviderRequestHeaderStore.record(for: providerId)
            draftUserAgent = stored.userAgent ?? ""
            draftExtraHeaders = stored.extra.map { ProviderHeaderDraft(name: $0.name, value: $0.value) }
            selectedUserAgentPreset = ProviderUserAgentPreset.matching(userAgent: stored.userAgent)
        } else if let claude = provider as? ProviderSetting.Claude {
            draftApiKey = claude.apiKey
            draftBaseURL = claude.baseUrl
            draftChatPath = "/messages"
            draftUseResponseAPI = false
            draftPromptCaching = claude.promptCaching
        } else if let google = provider as? ProviderSetting.Google {
            draftApiKey = google.apiKey
            draftBaseURL = google.baseUrl
            draftChatPath = ""
            draftUseResponseAPI = false
            draftPromptCaching = false
        }
    }

    @discardableResult
    private func saveConfig(showSuccess: Bool, forceEnabled: Bool = false) -> Bool {
        guard let provider else { return false }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? provider.name : draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = normalizedBaseURL(draftBaseURL)
        guard isValidHTTPBaseURL(baseURL) else {
            alert = .invalidBaseURL
            return false
        }
        let path = draftChatPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/chat/completions" : draftChatPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = forceEnabled || draftEnabled
        let previousHeaderRecord = IOSProviderRequestHeaderStore.record(for: providerId)
        let requestConfigurationChanged: Bool
        if let openAI = provider as? ProviderSetting.OpenAI {
            requestConfigurationChanged = openAI.apiKey != draftApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                || openAI.baseUrl != baseURL
                || openAI.chatCompletionsPath != path
                || openAI.useResponseApi != draftUseResponseAPI
                || openAI.enabled != enabled
        } else if let claude = provider as? ProviderSetting.Claude {
            requestConfigurationChanged = claude.apiKey != draftApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                || claude.baseUrl != baseURL
                || claude.enabled != enabled
        } else if let google = provider as? ProviderSetting.Google {
            requestConfigurationChanged = google.apiKey != draftApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                || google.baseUrl != baseURL
                || google.enabled != enabled
        } else {
            requestConfigurationChanged = true
        }
        guard persistRequestHeaders() else {
            alert = .requestHeadersSaveFailed
            return false
        }
        let headersChanged = previousHeaderRecord != IOSProviderRequestHeaderStore.record(for: providerId)
        cancelModelFetch(clearAvailableModels: requestConfigurationChanged || headersChanged)
        guard sharedSettings.updateProviderConfiguration(
            providerId: providerId, name: name, enabled: enabled,
            apiKey: draftApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            baseUrl: baseURL, chatCompletionsPath: path,
            useResponseApi: draftUseResponseAPI, promptCaching: draftPromptCaching
        ) else {
            let restoredHeaders = IOSProviderRequestHeaderStore.save(
                providerId: providerId, userAgent: previousHeaderRecord.userAgent, extra: previousHeaderRecord.extra
            )
            var message = sharedSettings.credentialPersistenceError ?? "服务商配置未能保存。"
            if !restoredHeaders { message += "请求头未能恢复，请重新保存。" }
            alert = .configurationSaveFailed(message)
            return false
        }
        if forceEnabled { draftEnabled = true }
        if isCurrentProvider {
            sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
        }
        if showSuccess {
            notice = IOSAppLocalization.string(
                "服务商配置已保存。",
                defaultValue: "服务商配置已保存。"
            )
        }
        return true
    }

    private func persistRequestHeaders() -> Bool {
        guard provider is ProviderSetting.OpenAI else { return true }
        let extra = draftExtraHeaders.map {
            IOSProviderRequestHeaderStore.Item(name: $0.name, value: $0.value)
        }
        return IOSProviderRequestHeaderStore.save(
            providerId: providerId,
            userAgent: draftUserAgent,
            extra: extra
        )
    }

    private func applyUserAgentPreset(_ preset: ProviderUserAgentPreset) {
        selectedUserAgentPreset = preset
        if let value = preset.userAgent {
            draftUserAgent = value
        }
    }

    private func tokenPlanMode(for brand: OpenAIBrand?) -> OpenAIAuthMode? {
        guard let brand else { return nil }
        if brand == OpenAIBrand.zhipu { return .zhipuCodingPlan }
        if brand == OpenAIBrand.kimi { return .kimiCodingPlan }
        if brand == OpenAIBrand.mimo { return .mimoCodingPlan }
        if brand == OpenAIBrand.minimax { return .minimaxTokenPlan }
        return nil
    }

    private func switchAuthMode(to mode: OpenAIAuthMode) {
        guard saveConfig(showSuccess: false) else { return }
        cancelModelFetch(clearAvailableModels: true)
        _ = sharedSettings.setOpenAIAuthMode(providerId: providerId, authMode: mode)
        if !isCodingPlan(mode) {
            let stored = IOSProviderRequestHeaderStore.record(for: providerId)
            if stored.userAgent == OpenAICompatUserAgents.shared.OPENCODE {
                IOSProviderRequestHeaderStore.save(
                    providerId: providerId,
                    userAgent: nil,
                    extra: stored.extra
                )
            }
        }
        if isCurrentProvider {
            sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
        }
        connectionStatus = .idle
        loadDraft()
        notice = isCodingPlan(mode)
            ? IOSAppLocalization.string("已切换到 Token Plan。", defaultValue: "已切换到 Token Plan。")
            : IOSAppLocalization.string("已切回 API Key 模式。", defaultValue: "已切回 API Key 模式。")
    }

    private func isCodingPlan(_ mode: OpenAIAuthMode) -> Bool {
        mode == .zhipuCodingPlan
            || mode == .kimiCodingPlan
            || mode == .mimoCodingPlan
            || mode == .minimaxTokenPlan
    }

    private func commitPendingTextInput(then action: @escaping () -> Void) {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        DispatchQueue.main.async(execute: action)
    }

    private func switchProtocol(to option: ProviderProtocolOption) {
        guard option != protocolOption else { return }
        guard provider is ProviderSetting.OpenAI || provider is ProviderSetting.Claude else {
            alert = .unsupportedProtocol
            return
        }
        guard saveConfig(showSuccess: false) else { return }
        guard sharedSettings.switchProviderProtocol(providerId: providerId, protocolOption: option) != nil else {
            alert = .protocolSwitchFailed
            return
        }
        cancelModelFetch(clearAvailableModels: true)
        connectionStatus = .idle
        loadDraft()
    }

    private func fetchModels(
        saveBeforeFetch: Bool = true,
        revealModels: Bool = false,
        reportsConnectionStatus: Bool = false
    ) {
        cancelModelFetch()
        notice = nil
        if saveBeforeFetch {
            guard saveConfig(showSuccess: false) else { return }
        }
        guard let provider else { return }
        if reportsConnectionStatus {
            connectionStatus = .testing
        }
        if revealModels {
            selectedTab = .models
        }
        guard ChatProviderConfiguration.supportsChatStreaming(provider) else {
            let message = IOSAppLocalization.string(
                "这个 Provider 类型的 iOS 模型获取尚未移植。",
                defaultValue: "这个 Provider 类型的 iOS 模型获取尚未移植。"
            )
            fetchState = .failure(message)
            if reportsConnectionStatus { connectionStatus = .failure(message) }
            return
        }
        guard hasConnectionCredential(provider) else {
            let message = connectionCredentialIssue(provider).message
            fetchState = .failure(message)
            if reportsConnectionStatus { connectionStatus = .failure(message) }
            return
        }
        let headersAtStart = IOSProviderRequestHeaderStore.headers(for: providerId)
        let requestID = UUID()
        modelFetchRequestID = requestID
        fetchState = .loading
        modelFetchTask = Task { @MainActor in
            defer {
                if modelFetchRequestID == requestID {
                    modelFetchRequestID = nil
                    modelFetchTask = nil
                }
            }
            do {
                let models: [Model]
                let successMessage: String?
                if IOSCodexProviderResolver.isCodexProvider(provider),
                   let openAI = provider as? ProviderSetting.OpenAI {
                    let discovered = try await IOSCodexOAuthClient(
                        providerId: IOSCodexProviderResolver.providerKey(openAI)
                    ).fetchCodexModelsOrThrow()
                    models = IOSCodexModelCatalog.models(discovered: discovered)
                    successMessage = "已获取 Codex 聊天模型；GPT Image 生图预设可在下方单独添加。"
                } else if IOSGrokWebProviderResolver.isGrokWebProvider(provider),
                          let openAI = provider as? ProviderSetting.OpenAI,
                          IOSGrokOAuthAuthStore.load(providerId: IOSGrokWebProviderResolver.providerKey(openAI)) != nil {
                    let discovered = try await IOSGrokOAuthClients.shared(
                        providerId: IOSGrokWebProviderResolver.providerKey(openAI)
                    ).fetchGrokModelsOrThrow()
                    models = discovered.map { item in
                        Model(
                            modelId: item.modelId,
                            displayName: item.displayName,
                            id: KotlinUuid.companion.random(),
                            type: ModelType.chat,
                            customHeaders: [],
                            customBodies: [],
                            inputModalities: [],
                            outputModalities: [],
                            abilities: [],
                            tools: Set<BuiltInTools>(),
                            contextWindowTokens: nil,
                            providerOverwrite: nil
                        )
                    }
                    successMessage = nil
                } else if IOSGrokWebProviderResolver.isGrokWebProvider(provider) {
                    models = provider.models.filter { $0.type == ModelType.chat }
                    successMessage = IOSAppLocalization.string(
                        "Grok 登录凭据已就绪；服务器可用性会在发送消息时验证。",
                        defaultValue: "Grok 登录凭据已就绪；服务器可用性会在发送消息时验证。"
                    )
                } else if let google = provider as? ProviderSetting.Google {
                    if IOSGeminiProviderResolver.isAntigravityOAuth(google) {
                        models = try await IOSGeminiClient(provider: google).listModelsOrThrow()
                        successMessage = IOSAppLocalization.string(
                            "已载入官方常用模型。",
                            defaultValue: "已载入官方常用模型。"
                        )
                    } else {
                        models = try await IOSGeminiClient(provider: google).listModelsOrThrow()
                        successMessage = nil
                    }
                } else if let openAI = provider as? ProviderSetting.OpenAI {
                    models = try await OpenAIKmpProvider().listModelsWithHeadersOrThrow(
                        providerSetting: openAI,
                        extraHeaders: headersAtStart
                    )
                    successMessage = nil
                } else if let claude = provider as? ProviderSetting.Claude {
                    models = try await ClaudeKmpProvider().listModelsOrThrow(providerSetting: claude)
                    successMessage = nil
                } else {
                    models = []
                    successMessage = nil
                }
                guard !Task.isCancelled, modelFetchRequestID == requestID else { return }
                availableModels = models
                let message = successMessage ?? (models.isEmpty
                    ? IOSAppLocalization.string(
                        "连接成功，但服务商没有返回可列出的模型。可手动添加 Model ID。",
                        defaultValue: "连接成功，但服务商没有返回可列出的模型。可手动添加 Model ID。"
                    )
                    : IOSAppLocalization.formatted(
                        "连接成功，服务商返回 %lld 个模型。",
                        defaultValue: "连接成功，服务商返回 %lld 个模型。",
                        arguments: [Int64(models.count)]
                    ))
                fetchState = .success(message)
                if reportsConnectionStatus { connectionStatus = .success(message) }
            } catch {
                guard !Task.isCancelled, modelFetchRequestID == requestID else { return }
                let message = ChatViewModel.userFacingGenerationError(error.localizedDescription, modelId: nil)
                fetchState = .failure(message)
                if reportsConnectionStatus { connectionStatus = .failure(message) }
            }
        }
    }

    private func cancelModelFetch(clearAvailableModels: Bool = false) {
        modelFetchTask?.cancel()
        modelFetchTask = nil
        modelFetchRequestID = nil
        if clearAvailableModels || fetchState.isLoading { fetchState = .idle }
        if clearAvailableModels || connectionStatus.isTesting { connectionStatus = .idle }
        if clearAvailableModels { availableModels = [] }
    }

    private func addFetchedModel(_ model: Model) {
        guard saveConfig(showSuccess: false, forceEnabled: true) else { return }
        let existing = enabledModels.first(where: { $0.modelId == model.modelId })
        let fetchedDisplayName = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingDisplayName = existing?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = existingDisplayName.isEmpty
            ? (fetchedDisplayName.isEmpty ? model.modelId : fetchedDisplayName)
            : existingDisplayName
        let existingUuid = existing?.id.description()
        guard let updatedProvider = sharedSettings.upsertProviderChatModel(
            providerId: providerId,
            modelUuid: existingUuid,
            modelId: model.modelId,
            displayName: displayName,
            contextWindowTokens: intValue(existing?.contextWindowTokens ?? model.contextWindowTokens),
            modelType: model.type,
            inputModalities: existing?.inputModalities ?? model.inputModalities,
            headers: (existing?.customHeaders ?? model.customHeaders).map { ($0.name, $0.value) }
        ) else {
            showModelSaveFailure()
            return
        }
        guard let savedModel = updatedProvider.models.first(where: {
            $0.type == model.type && $0.modelId == model.modelId
        }) else { return }
        setDefault(for: savedModel, showAlert: true)
    }

    @discardableResult
    private func saveModelDraft(_ draft: ProviderModelDraft) -> Bool {
        let modelId = draft.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelId.isEmpty else {
            alert = .modelRequired
            return false
        }
        let modelType = draft.type == ModelType.chat && providerModelIDLooksLikeImage(modelId)
            ? ModelType.image
            : draft.type
        // A manual add with an existing wire ID should update that model in place.
        // This also repairs an older gpt-image-* entry that was mistakenly saved as CHAT.
        let targetModelUuid = draft.modelUuid ?? provider?.models.first {
            $0.modelId == modelId
        }?.id.description()
        let isManualAdd = draft.modelUuid == nil
        let wasCurrentChat = targetModelUuid != nil && currentModel?.id.description() == targetModelUuid
        let wasDefaultImage = targetModelUuid != nil && imageGenerationModel?.id.description() == targetModelUuid

        if wasCurrentChat,
           modelType != ModelType.chat,
           !chatModels.contains(where: { $0.id.description() != targetModelUuid }) {
            alert = .chatModelRequired
            return false
        }

        let shouldSelectChat = modelType == ModelType.chat && (isManualAdd || wasCurrentChat)
        let shouldSelectImage = modelType == ModelType.image && (isManualAdd || wasDefaultImage || wasCurrentChat)
        guard saveConfig(
            showSuccess: false,
            forceEnabled: isManualAdd || wasCurrentChat || wasDefaultImage
        ) else { return false }
        let displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? modelId : draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let updatedProvider = sharedSettings.upsertProviderChatModel(
            providerId: providerId,
            modelUuid: targetModelUuid,
            modelId: modelId,
            displayName: displayName,
            contextWindowTokens: draft.contextWindowTokens,
            modelType: modelType,
            inputModalities: draft.inputModalities,
            headers: draft.headers.map { ($0.name, $0.value) }
        ) else {
            showModelSaveFailure()
            return false
        }

        guard let savedModel = updatedProvider.models.first(where: {
            if let targetModelUuid {
                return $0.id.description() == targetModelUuid
            }
            return $0.type == modelType && $0.modelId == modelId
        }) else { return false }

        if wasCurrentChat && modelType != ModelType.chat,
           let fallback = updatedProvider.models.first(where: { $0.type == ModelType.chat }) {
            selectCurrent(fallback, showAlert: false)
        }
        if modelType == ModelType.chat {
            if wasDefaultImage {
                sharedSettings.setImageGenerationModelId("")
            }
            if shouldSelectChat {
                selectCurrent(savedModel, showAlert: isManualAdd)
            }
        } else if modelType == ModelType.image {
            if shouldSelectImage {
                selectImageGenerationModel(savedModel, showAlert: true)
            }
        } else if wasDefaultImage {
            sharedSettings.setImageGenerationModelId("")
        }
        modelDraft = nil
        return true
    }

    private func showModelSaveFailure() {
        alert = .configurationSaveFailed(sharedSettings.credentialPersistenceError ?? "模型配置未能保存，请重试。")
    }

    private func setCurrent(_ model: Model) {
        guard model.type == ModelType.chat || model.type == ModelType.image else {
            notice = IOSAppLocalization.string(
                "嵌入模型不能作为聊天或生图默认模型。",
                defaultValue: "嵌入模型不能作为聊天或生图默认模型。"
            )
            return
        }
        guard saveConfig(showSuccess: false, forceEnabled: true) else { return }
        setDefault(for: model, showAlert: true)
    }

    private func setDefault(for model: Model, showAlert: Bool) {
        if model.type == ModelType.image {
            selectImageGenerationModel(model, showAlert: showAlert)
        } else if model.type == ModelType.chat {
            selectCurrent(model, showAlert: showAlert)
        }
    }

    private func selectCurrent(_ model: Model, showAlert: Bool) {
        sharedSettings.selectChatModelAsDefault(model.id.description())
        sharedSettings.syncLegacySettingsStoreForCurrentChat(settingsStore)
        if showAlert {
            notice = IOSAppLocalization.formatted(
                "新的聊天会默认使用 %@。",
                defaultValue: "新的聊天会默认使用 %@。",
                arguments: [model.modelId]
            )
        }
    }

    private func selectImageGenerationModel(_ model: Model, showAlert: Bool) {
        sharedSettings.setImageGenerationModelId(model.id.description())
        if showAlert {
            notice = IOSAppLocalization.formatted(
                "对话生图会默认使用 %@。",
                defaultValue: "对话生图会默认使用 %@。",
                arguments: [model.modelId]
            )
        }
    }

    private func deleteModel(_ model: Model) {
        guard saveConfig(showSuccess: false) else { return }
        let wasCurrentChat = currentModel?.id == model.id
        let wasDefaultImage = imageGenerationModel?.id == model.id
        guard sharedSettings.removeProviderChatModel(providerId: providerId, modelUuid: model.id.description()) != nil else {
            showModelSaveFailure()
            return
        }
        if wasDefaultImage {
            sharedSettings.setImageGenerationModelId("")
        }
        if wasCurrentChat {
            alert = .currentModelDeleted
        }
    }

    private func testConnection() {
        notice = nil
        guard saveConfig(showSuccess: false) else { return }
        guard let provider else { return }
        guard ChatProviderConfiguration.supportsChatStreaming(provider) else {
            connectionStatus = .failure(ChatConfigurationIssue.unsupportedProvider.message)
            return
        }
        guard hasConnectionCredential(provider) else {
            connectionStatus = .failure(connectionCredentialIssue(provider).message)
            return
        }
        guard isValidHTTPBaseURL(baseURL(of: provider)) else {
            connectionStatus = .failure(ChatConfigurationIssue.invalidBaseURL.message)
            return
        }
        fetchModels(saveBeforeFetch: false, reportsConnectionStatus: true)
    }

}
