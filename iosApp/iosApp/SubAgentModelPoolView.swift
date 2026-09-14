import SwiftUI
@preconcurrency import Shared

struct SubAgentModelPoolView: View {
    let sharedSettings: IOSSharedSettingsStore

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedModelIDs: Set<String>
    @State private var reasoningValues: [String: String]

    init(sharedSettings: IOSSharedSettingsStore) {
        self.sharedSettings = sharedSettings
        let saved = sharedSettings.subAgentModelPool
        _selectedModelIDs = State(initialValue: Set(saved.map { $0.modelId.toHexDashString() }))
        _reasoningValues = State(initialValue: saved.reduce(into: [String: String]()) { values, entry in
            let id = entry.modelId.toHexDashString()
            values[id] = entry.reasoningLevel
                .map { ComposerReasoningOption(reasoningLevel: $0).rawValue }
                ?? "inherit"
        })
    }

    private var availableModels: [IOSSharedSettingsStore.ChatModelOption] {
        let providers = sharedSettings.snapshot.providers
        return sharedSettings.availableChatModels().filter { option in
            guard let model = providers
                .flatMap(\.models)
                .first(where: { $0.id.toHexDashString().caseInsensitiveCompare(option.id) == .orderedSame }),
                  let provider = ChatProviderConfiguration.provider(for: model, providers: providers) else {
                return false
            }
            return provider.enabled && ChatProviderConfiguration.issue(for: model, provider: provider) == nil
        }
    }

    private var filteredModels: [IOSSharedSettingsStore.ChatModelOption] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return availableModels }
        return availableModels.filter { model in
            [model.displayName, model.modelId, model.providerName, model.id]
                .contains { $0.lowercased().contains(normalized) }
        }
    }

    private var unavailableModelIDs: [String] {
        selectedModelIDs
            .filter { id in !availableModels.contains(where: { $0.id == id }) }
            .sorted()
    }

    private var selectedAvailableModels: [IOSSharedSettingsStore.ChatModelOption] {
        availableModels.filter { selectedModelIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        VStack(spacing: 0) {
                            intro
                            modelPoolSection
                            reasoningSection
                        }
                        .padding(.bottom, 28)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        HStack {
            Button("取消") { dismiss() }
                .font(.body)
                .foregroundStyle(AmberTheme.muted)
                .frame(minWidth: 56, minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("subagents.modelPool.cancel")
            Spacer()
            Text("模型池")
                .font(.headline)
                .foregroundStyle(AmberTheme.foreground)
            Spacer()
            Button("保存") { save(); dismiss() }
                .font(.body.weight(.semibold))
                .foregroundStyle(AmberTheme.accent)
                .frame(minWidth: 56, minHeight: 44, alignment: .trailing)
                .accessibilityIdentifier("subagents.modelPool.save")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var intro: some View {
        Text("选择可用聊天模型组成子代理模型池。模型池为空时，子代理沿用当前聊天模型。")
            .font(.subheadline)
            .foregroundStyle(AmberTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
    }

    private var modelPoolSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "模型池")
            AmberFormGroup {
                TextField("搜索模型或服务商", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .accessibilityIdentifier("subagents.modelPool.search")

                Divider()
                    .overlay(AmberTheme.borderSoft)
                    .padding(.leading, 14)

                if filteredModels.isEmpty && unavailableModelIDs.isEmpty {
                    Text("没有匹配的可用聊天模型")
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    ForEach(filteredModels) { model in
                        modelRow(model)
                        if model.id != filteredModels.last?.id || !unavailableModelIDs.isEmpty {
                            Divider()
                                .overlay(AmberTheme.borderSoft)
                                .padding(.leading, 58)
                        }
                    }

                    if !unavailableModelIDs.isEmpty {
                        Text("已停用或移除")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                        ForEach(unavailableModelIDs, id: \.self) { id in
                            unavailableModelRow(id: id)
                        }
                    }
                }
            }
            Text(selectedModelIDs.isEmpty
                 ? "尚未选择模型，运行时会跟随当前聊天模型。"
                 : "已选择 \(selectedModelIDs.count) 个模型。点击模型可加入或移除。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 8)
        }
    }

    private var reasoningSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "模型推理强度")
            AmberFormGroup {
                if selectedAvailableModels.isEmpty && unavailableModelIDs.isEmpty {
                    Text("选择模型后，可分别设置它们的推理强度。")
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    ForEach(selectedAvailableModels) { model in
                        reasoningRow(model)
                        if model.id != selectedAvailableModels.last?.id || !unavailableModelIDs.isEmpty {
                            Divider()
                                .overlay(AmberTheme.borderSoft)
                                .padding(.leading, 14)
                        }
                    }
                    if !unavailableModelIDs.isEmpty {
                        Text("不可用模型的推理设置会保留；移除模型后将一并清除。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                    }
                }
            }
        }
    }

    private func modelRow(_ model: IOSSharedSettingsStore.ChatModelOption) -> some View {
        Button {
            toggle(model.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedModelIDs.contains(model.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selectedModelIDs.contains(model.id) ? AmberTheme.accent : AmberTheme.muted2)
                    .frame(width: 32, height: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(AmberTheme.foreground)
                    Text("\(model.providerName) · \(model.modelId)")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("subagents.modelPool.model.\(model.id)")
        .accessibilityValue(selectedModelIDs.contains(model.id) ? "已选择" : "未选择")
    }

    private func unavailableModelRow(id: String) -> some View {
        let configured = sharedSettings.availableChatModels().first { $0.id == id }
        return HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AmberTheme.accentAmber)
                .frame(width: 32, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(configured?.displayName ?? "已移除的模型")
                    .font(.body.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                Text(configured.map { "\($0.providerName) · 配置不可用" } ?? id)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("移除", role: .destructive) {
                selectedModelIDs.remove(id)
                reasoningValues.removeValue(forKey: id)
            }
            .font(.caption.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("subagents.modelPool.removeUnavailable.\(id)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func reasoningRow(_ model: IOSSharedSettingsStore.ChatModelOption) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                Text(model.providerName)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker("\(model.displayName) 推理强度", selection: reasoningBinding(for: model)) {
                Text("模型默认").tag("inherit")
                if let saved = reasoningValues[model.id],
                   saved != "inherit",
                   let option = ComposerReasoningOption(rawValue: saved),
                   !reasoningOptions(for: model).contains(option) {
                    Text("\(option.title)（已不支持）").tag(saved).disabled(true)
                }
                ForEach(reasoningOptions(for: model), id: \.rawValue) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(AmberTheme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityIdentifier("subagents.modelPool.reasoning.\(model.id)")
    }

    private func reasoningBinding(for model: IOSSharedSettingsStore.ChatModelOption) -> Binding<String> {
        Binding(
            get: { reasoningValues[model.id] ?? "inherit" },
            set: { reasoningValues[model.id] = $0 }
        )
    }

    private func reasoningOptions(for model: IOSSharedSettingsStore.ChatModelOption) -> [ComposerReasoningOption] {
        sharedSettings.subAgentReasoningLevels(modelId: model.id)
            .map(ComposerReasoningOption.init)
    }

    private func toggle(_ id: String) {
        if selectedModelIDs.contains(id) {
            selectedModelIDs.remove(id)
        } else {
            selectedModelIDs.insert(id)
            if reasoningValues[id] == nil { reasoningValues[id] = "inherit" }
        }
    }

    private func save() {
        let orderedIDs = availableModels
            .filter { selectedModelIDs.contains($0.id) }
            .map(\.id) + unavailableModelIDs
        sharedSettings.setSubAgentModelPool(modelIds: orderedIDs)
        for id in orderedIDs {
            let level = reasoningValues[id].flatMap { raw -> ReasoningLevel? in
                guard raw != "inherit" else { return nil }
                return ComposerReasoningOption(rawValue: raw)?.reasoningLevel
            }
            sharedSettings.setSubAgentPoolReasoning(modelId: id, reasoningLevel: level)
        }
    }
}

#Preview {
    SubAgentModelPoolView(sharedSettings: IOSSharedSettingsStore())
}
