import SwiftUI

struct DeepReadSettingsView: View {
    @Bindable var store: DeepReadSettingsStore
    @State private var saved = false
    @State private var savedCount = 0

    var body: some View {
        Form {
            Group {
                Section {
                    DeepReadAccentPicker()
                    NavigationLink { DeepReadTemplatesView(settings: store) } label: {
                        LabeledContent("版式与样式", value: "\(DeepReadAppearance.shared.readerLayout.name) · \(DeepReadAppearance.shared.readerStyle.name)")
                    }
                } header: {
                    Text("外观")
                } footer: {
                    Text("即时生效，文章里的强调色也会同步更换。")
                }
                if let error = store.errorMessage {
                    Section {
                        Text(error).foregroundStyle(DeepReadPalette.danger)
                        Button("重新读取凭据") { store.reloadCredentials() }
                    }
                }
                Section {
                    Picker("生成模型", selection: $store.selectedModelID) {
                        Text("请选择模型").tag(UUID?.none)
                        ForEach(store.models) { model in
                            Text("\(model.name) · \(model.modelID)").tag(Optional(model.id))
                        }
                    }
                    // Menu pickers are UIKit-backed and keep the tint they were created with.
                    .id(DeepReadAppearance.shared.accent)
                    ForEach($store.models) { $model in
                        NavigationLink {
                            DeepReadModelEditor(model: $model)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(model.name)
                                Text(model.modelID).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indices in store.models.remove(atOffsets: indices) }
                    Menu("添加模型服务", systemImage: "plus") {
                        Button("OpenAI 兼容 API") { addModel(.openAI) }
                        Button("Claude API") { addModel(.claude) }
                    }
                } header: { Text("文章生成") }
                footer: { Text("使用你自己的 API 凭据。当前支持 OpenAI 兼容和 Claude API；凭据保存在本应用的 Keychain 中。") }

                Section {
                    Picker("首选搜索服务", selection: $store.selectedSearchID) {
                        Text("请选择服务").tag(UUID?.none)
                        ForEach(store.searchServices) { service in
                            Text(service.kind.title).tag(Optional(service.id))
                        }
                    }
                    .id(DeepReadAppearance.shared.accent)
                    ForEach($store.searchServices) { $service in
                        NavigationLink {
                            DeepReadSearchEditor(service: $service)
                        } label: {
                            HStack {
                                Text(service.kind.title)
                                Spacer()
                                Text(service.enabled ? "启用" : "停用")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indices in store.searchServices.remove(atOffsets: indices) }
                    Menu("添加搜索服务", systemImage: "plus") {
                        ForEach(DeepReadSearchKind.allCases) { kind in
                            Button(kind.title) {
                                var service = DeepReadSearchConfiguration()
                                service.kind = kind
                                store.searchServices.append(service)
                                store.selectedSearchID = service.id
                            }
                        }
                    }
                    Stepper("每次搜索最多 \(store.resultSize) 条", value: $store.resultSize, in: 1...50)
                } header: { Text("多来源搜索") }
                footer: {
                    Text("优先使用选中的搜索服务；不可用时，选择其他已启用的可用服务。部分服务目前仅支持保存配置，尚不能执行搜索。")
                }
                Section("免费聚合与正文读取") {
                    Toggle("DuckDuckGo", isOn: $store.searchBuiltinDuckDuckGoEnabled)
                    Toggle("Bing", isOn: $store.searchBuiltinBingEnabled)
                    Toggle("Jina 搜索与正文补充读取", isOn: $store.searchBuiltinJinaEnabled)
                    Toggle("Wikipedia", isOn: $store.searchBuiltinWikipediaEnabled)
                    Toggle("Hacker News", isOn: $store.searchBuiltinHackerNewsEnabled)
                    Toggle("Google 网页补充搜索", isOn: $store.searchGoogleWebViewFallbackEnabled)
                }
                Section("阅读与排版") {
                    Picker("字体", selection: $store.fontMode) {
                        Text("衬线字体").tag("serif")
                        Text("系统字体").tag("system")
                    }
                    .id(DeepReadAppearance.shared.accent)
                    LabeledContent("字号", value: "\(Int((store.fontScale * 100).rounded()))%")
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Slider(value: $store.fontScale, in: 0.7...1.8, step: 0.05)
                        .accessibilityLabel("字号")
                        .accessibilityValue("\(Int((store.fontScale * 100).rounded()))%")
                    Picker("生成模板", selection: $store.templateId) {
                        let customs = IOSDeepReadTemplateStore.shared.templates
                        ForEach(DeepReadSynthesisTemplate.options, id: \.id) { Text($0.name).tag($0.id) }
                        ForEach(customs) { Text($0.name).tag($0.id) }
                        if !DeepReadSynthesisTemplate.options.contains(where: { $0.id == store.templateId }),
                           !customs.contains(where: { $0.id == store.templateId }) {
                            Text("当前自定义模板").tag(store.templateId)
                        }
                    }
                    .id(DeepReadAppearance.shared.accent)
                    NavigationLink("管理与创建模板") { DeepReadTemplatesView(settings: store) }
                }
                    Section {
                    Button {
                        saved = store.save()
                        if saved { savedCount += 1 }
                    } label: {
                        Label("保存并应用", systemImage: "checkmark.circle")
                            .labelStyle(.titleAndIcon)
                            .symbolEffect(.bounce, value: savedCount)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    if saved {
                        Text("已保存，下一次生成将使用此配置。")
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .listRowBackground(DeepReadPalette.card)
        }
        .scrollContentBackground(.hidden)
        .modifier(DeepReadTabVisibility())
        .background { DeepReadPaperBackground(night: DeepReadMoment.isNight(.now)) }
        .animation(.snappy, value: saved)
        .sensoryFeedback(.success, trigger: savedCount)
        // The confirmation is about the last tap; it must not linger over later, unsaved edits.
        .task(id: savedCount) {
            guard saved, (try? await Task.sleep(for: .seconds(3))) != nil else { return }
            saved = false
        }
        .navigationTitle("设置")
    }

    private func addModel(_ kind: DeepReadModelProtocol) {
        var model = DeepReadModelConfiguration()
        model.protocolType = kind
        if kind == .claude {
            model.name = "Claude"
            model.baseURL = "https://api.anthropic.com/v1"
            model.modelID = "claude-sonnet-4-5"
        }
        store.models.append(model)
        store.selectedModelID = model.id
    }
}

private struct DeepReadModelEditor: View {
    @Binding var model: DeepReadModelConfiguration

    var body: some View {
        Form {
            Section("模型与服务") {
                TextField("名称", text: $model.name)
                Picker("协议", selection: $model.protocolType) {
                    ForEach(DeepReadModelProtocol.allCases) { kind in Text(kind.title).tag(kind) }
                }
                Toggle("启用", isOn: $model.enabled)
                TextField("服务地址", text: $model.baseURL).urlInput()
                TextField("模型 ID", text: $model.modelID).rawInput()
                SecureField("API Key", text: $model.apiKey).rawInput()
            }
            if model.protocolType == .openAI {
                Section("OpenAI 请求") {
                    Toggle("使用 Responses API", isOn: $model.useResponsesAPI)
                    if !model.useResponsesAPI {
                        TextField("Chat Completions 路径", text: $model.chatCompletionsPath).rawInput()
                    }
                }
            } else {
                Section("Claude 请求") { Toggle("Prompt Caching", isOn: $model.promptCaching) }
            }
            Section {
                Text("返回设置页后，点击“保存并应用”。API Key 认证支持自定义服务地址；OAuth 登录尚未接入此独立应用。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(model.name.isEmpty ? "模型配置" : model.name)
    }
}

private struct DeepReadSearchEditor: View {
    @Binding var service: DeepReadSearchConfiguration

    var body: some View {
        Form {
            Section("服务") {
                Text(service.kind.title)
                Toggle("启用", isOn: $service.enabled)
                if service.kind != .bingLocal && service.kind != .searxng {
                    SecureField(service.kind == .jina ? "API Key（可选）" : "API Key", text: $service.apiKey).rawInput()
                }
                if !service.kind.executable {
                    Text("此服务目前仅支持保存配置，尚不能执行搜索。搜索时会使用其他已启用的可用服务。")
                        .foregroundStyle(DeepReadPalette.warn)
                }
            }
            options
            Section { Text("返回设置页后，点击“保存并应用”。").foregroundStyle(.secondary) }
        }
        .navigationTitle(service.kind.title)
    }

    @ViewBuilder private var options: some View {
        switch service.kind {
        case .searxng:
            Section("SearXNG") {
                field("地址", key: "url")
                field("搜索引擎", key: "engines")
                field("语言", key: "language")
                field("用户名", key: "username")
                SecureField("密码", text: $service.password).rawInput()
            }
        case .tavily, .linkup, .amberAgent:
            Section("搜索深度") {
                Picker("深度", selection: fieldBinding("depth", fallback: service.kind == .tavily ? "advanced" : "standard")) {
                    Text("标准").tag(service.kind == .tavily ? "basic" : "standard")
                    Text("深入").tag(service.kind == .tavily ? "advanced" : "deep")
                }
            }
        case .perplexity:
            Section("可选限制") {
                field("最大 Token 数", key: "maxTokens")
                field("每页最大 Token 数", key: "maxTokensPerPage")
            }
        case .jina:
            Section("Jina 地址") {
                field("搜索地址", key: "searchUrl", fallback: "https://s.jina.ai/")
                field("正文读取地址", key: "scrapeUrl", fallback: "https://r.jina.ai/")
            }
        case .bocha:
            Section("结果") {
                Toggle("包含摘要", isOn: Binding(
                    get: { service.fields["summary"] != "false" },
                    set: { service.fields["summary"] = $0 ? "true" : "false" }
                ))
            }
        case .grok:
            Section("Grok 搜索") {
                field("模型", key: "model", fallback: "grok-4-1-fast-non-reasoning")
                field("地址", key: "customUrl", fallback: "https://api.x.ai/v1/responses")
                field("系统提示词", key: "systemPrompt")
            }
        default: EmptyView()
        }
    }

    private func field(_ title: String, key: String, fallback: String = "") -> some View {
        TextField(title, text: fieldBinding(key, fallback: fallback)).rawInput()
    }
    private func fieldBinding(_ key: String, fallback: String = "") -> Binding<String> {
        Binding(get: { service.fields[key] ?? fallback }, set: { service.fields[key] = $0 })
    }
}

private extension View {
    func rawInput() -> some View { textInputAutocapitalization(.never).autocorrectionDisabled() }
    func urlInput() -> some View { rawInput().keyboardType(.URL) }
}

/// Swatch row for the app accent. The ring glides to the chosen color.
private struct DeepReadAccentPicker: View {
    @Bindable private var appearance = DeepReadAppearance.shared
    @Namespace private var ring

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DeepReadAccent.allCases) { accent in
                let selected = appearance.accent == accent
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { appearance.accent = accent }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            if selected {
                                Circle().strokeBorder(DeepReadPalette.adaptive(light: accent.light, dark: accent.dark), lineWidth: 2)
                                    .frame(width: 42, height: 42)
                                    .matchedGeometryEffect(id: "ring", in: ring)
                            }
                            Circle().fill(DeepReadPalette.adaptive(light: accent.light, dark: accent.dark))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if selected {
                                        Image(systemName: "checkmark").font(.caption.weight(.bold))
                                            .foregroundStyle(DeepReadPalette.paper)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                .scaleEffect(selected ? 1 : 0.9)
                        }
                        .frame(width: 44, height: 44)
                        Text(accent.name).font(.caption2.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? DeepReadPalette.ink : DeepReadPalette.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accent.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: appearance.accent)
    }
}
