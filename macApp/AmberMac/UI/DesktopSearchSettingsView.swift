import SwiftUI

struct DesktopSearchSettingsView: View {
    let settings: DesktopSearchSettings
    @Environment(\.dismiss) private var dismiss

    @State private var serviceOrder: [DesktopSearchService]
    @State private var enabledSet: Set<DesktopSearchService>
    @State private var executionMode: DesktopSearchExecutionMode
    @State private var resultCount: Int
    @State private var exaOptions: DesktopExaOptions
    @State private var apiKeys: [DesktopSearchService: String] = [:]
    @State private var expandedKeyService: DesktopSearchService?
    @State private var showExaAdvanced = false
    @State private var error: String?

    init(settings: DesktopSearchSettings) {
        self.settings = settings
        _serviceOrder = State(initialValue: settings.serviceOrder)
        _enabledSet = State(initialValue: Set(settings.enabledServices))
        _executionMode = State(initialValue: settings.executionMode)
        _resultCount = State(initialValue: settings.resultCount)
        _exaOptions = State(initialValue: settings.exaOptions)
    }

    private var orderedEnabledServices: [DesktopSearchService] {
        serviceOrder.filter { enabledSet.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    strategyCard
                    sourcesCard
                    if enabledSet.contains(.exa) || expandedKeyService == .exa {
                        exaAdvancedCard
                    }
                }
                .padding(.vertical, 2)
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footerButtons
        }
        .padding(24)
        .frame(width: 560, height: 560)
        .task { loadAllKeys() }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("联网搜索")
                    .font(DesktopTheme.serif(size: 22, weight: .semibold))
                Spacer()
                statusBadge
            }
            Text("聊天工具与 Recipe 共用此配置；可同时启用多个搜索源按优先级顺序兜底或并发检索。")
                .font(.system(size: 12.5))
                .foregroundStyle(DesktopTheme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusBadge: some View {
        let active = orderedEnabledServices
        let text = active.isEmpty
            ? "未启用搜索源"
            : active.map(\.title).joined(separator: executionMode == .sequentialFallback ? " → " : " + ")
        return Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(active.isEmpty ? DesktopTheme.danger : DesktopTheme.inkSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(DesktopTheme.canvasElevated)
            )
    }

    private var strategyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通用设置")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesktopTheme.inkSecondary)

            HStack {
                Text("执行策略")
                    .font(.system(size: 13))
                Spacer()
                Picker("", selection: $executionMode) {
                    ForEach(DesktopSearchExecutionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            Text(executionMode.subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(DesktopTheme.inkTertiary)

            Divider()

            HStack {
                Text("单次返回结果上限")
                    .font(.system(size: 13))
                Spacer()
                HStack(spacing: 6) {
                    TextField("", value: $resultCount, format: .number)
                        .textFieldStyle(.desktop)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .onChange(of: resultCount) { _, value in
                            let clamped = min(DesktopSearchSettings.resultLimit, max(1, value))
                            if clamped != value { resultCount = clamped }
                        }
                    Stepper("", value: $resultCount, in: 1...DesktopSearchSettings.resultLimit)
                        .labelsHidden()
                    Text("1–\(DesktopSearchSettings.resultLimit)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DesktopTheme.canvasElevated)
        )
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("搜索源与优先级（从上到下依次执行）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                Spacer()
                Text("凭证仅保存在本机钥匙串")
                    .font(.system(size: 11))
                    .foregroundStyle(DesktopTheme.inkTertiary)
            }

            VStack(spacing: 8) {
                ForEach(Array(serviceOrder.enumerated()), id: \.element.id) { index, service in
                    sourceRow(service: service, index: index)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DesktopTheme.canvasElevated)
        )
    }

    private func sourceRow(service: DesktopSearchService, index: Int) -> some View {
        let isEnabled = enabledSet.contains(service)
        let keyText = (apiKeys[service] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = !service.requiresAPIKey || !keyText.isEmpty
        let showKeyField = service.requiresAPIKey && (isEnabled || expandedKeyService == service)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { on in
                        if on {
                            enabledSet.insert(service)
                            if service.requiresAPIKey && keyText.isEmpty {
                                expandedKeyService = service
                            }
                        } else {
                            enabledSet.remove(service)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(service.title)
                            .font(.system(size: 13, weight: .medium))
                        Text(service.requiresAPIKey ? (hasKey ? "已配置 Key" : "需填写 Key") : "免 Key")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(hasKey ? DesktopTheme.inkSecondary : DesktopTheme.danger)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().strokeBorder(DesktopTheme.hairline, lineWidth: 1))
                    }
                    Text(service.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .lineLimit(1)
                }

                Spacer()

                if service.requiresAPIKey {
                    Button(showKeyField ? "收起" : "配置 Key") {
                        expandedKeyService = (expandedKeyService == service) ? nil : service
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                }

                HStack(spacing: 2) {
                    Button {
                        moveService(at: index, offset: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)

                    Button {
                        moveService(at: index, offset: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == serviceOrder.count - 1)
                }
            }

            if showKeyField {
                SecureField("\(service.title) API Key", text: Binding(
                    get: { apiKeys[service] ?? "" },
                    set: { apiKeys[service] = $0 }
                ))
                .textFieldStyle(.desktop)
                .font(.system(size: 12))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isEnabled ? DesktopTheme.inkSecondary.opacity(0.28) : DesktopTheme.hairline, lineWidth: 1)
        )
    }

    private var exaAdvancedCard: some View {
        DisclosureGroup("Exa 高级检索设置（默认参数）", isExpanded: $showExaAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("默认检索模式")
                        .font(.system(size: 12.5))
                    Spacer()
                    Picker("", selection: $exaOptions.searchType) {
                        ForEach(DesktopExaSearchType.primaryCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }

                HStack {
                    Text("默认内容返回")
                        .font(.system(size: 12.5))
                    Spacer()
                    Picker("", selection: $exaOptions.contentMode) {
                        ForEach(DesktopExaContentMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }

                Toggle("提取并返回网页图片链接（image / richImageLinks）", isOn: $exaOptions.includeImages)
                    .font(.system(size: 12.5))

                Text("Agent 在调用 search_web / exa_contents / exa_answer / exa_find_similar 时仍可按任务动态覆盖 type、category、域名、发布时间、摘要与子页面参数。")
                    .font(.system(size: 11))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DesktopTheme.canvasElevated)
        )
    }

    private var footerButtons: some View {
        HStack {
            Spacer()
            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存") {
                saveConfiguration()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func moveService(at index: Int, offset: Int) {
        let target = index + offset
        guard serviceOrder.indices.contains(index), serviceOrder.indices.contains(target) else { return }
        serviceOrder.swapAt(index, target)
    }

    private func loadAllKeys() {
        var loaded: [DesktopSearchService: String] = [:]
        for svc in DesktopSearchService.allCases where svc.requiresAPIKey {
            if let key = try? settings.apiKey(for: svc) {
                loaded[svc] = key
            }
        }
        apiKeys = loaded
    }

    private func saveConfiguration() {
        do {
            try settings.saveConfiguration(
                enabledServices: orderedEnabledServices,
                serviceOrder: serviceOrder,
                executionMode: executionMode,
                resultCount: resultCount,
                exaOptions: exaOptions,
                apiKeys: apiKeys
            )
            error = nil
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
