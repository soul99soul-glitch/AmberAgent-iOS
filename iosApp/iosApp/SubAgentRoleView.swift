import SwiftUI
import Shared

struct SubAgentRoleView: View {
    let sharedSettings: IOSSharedSettingsStore
    @Environment(\.dismiss) private var dismiss
    private let roleId: String
    private let name: String
    @State private var promptDraft: String
    @State private var modelId: String
    @State private var reasoning: String
    @State private var useDefaultTools: Bool
    @State private var selectedTools: Set<String>
    @State private var selectedSkills: Set<String>
    @State private var tab = RoleTab.configuration
    @State private var installedSkills: [String] = []
    @State private var toolQuery = ""

    private enum RoleTab: String, CaseIterable {
        case configuration = "配置"
        case tools = "工具"
        case skills = "技能"
    }

    init(sharedSettings: IOSSharedSettingsStore, name: String, roleId: String) {
        self.sharedSettings = sharedSettings
        self.name = name
        self.roleId = roleId
        let role = IOSSubAgentRoleCatalog.resolve(roleId: roleId)
        let saved = sharedSettings.snapshot.agentRuntime.subAgent.overrides[roleId]
        _promptDraft = State(initialValue: saved?.systemPrompt ?? role?.systemPrompt ?? "")
        _modelId = State(initialValue: saved?.modelId?.toHexDashString() ?? "")
        _reasoning = State(initialValue: saved?.reasoningLevel.map { ComposerReasoningOption(reasoningLevel: $0).rawValue } ?? "inherit")
        _useDefaultTools = State(initialValue: saved?.toolAllowlist == nil)
        _selectedTools = State(initialValue: saved?.toolAllowlist ?? Set(role?.toolAllowlist ?? []))
        _selectedSkills = State(initialValue: Set(saved?.defaultSkillNames ?? []))
    }

    private var role: IOSSubAgentRoleDescriptor? { IOSSubAgentRoleCatalog.resolve(roleId: roleId) }

    private var mcpServers: [IOSMcpServerConfig] {
        let local = IOSMcpConfigStore.shared.servers
        let names = Set(local.map(\.name))
        return local + sharedSettings.snapshot.mcpServers.compactMap(IOSMcpServerConfig.init)
            .filter { !names.contains($0.name) }
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回子代理", size: 44, symbolSize: 20) { dismiss() }
                    Spacer()
                    Text(name).font(.headline).foregroundStyle(AmberTheme.foreground)
                    Spacer()
                    Button("保存") { save(); dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AmberTheme.accent)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("subagentRole.save")
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Picker("角色设置", selection: $tab) {
                    ForEach(RoleTab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 0) {
                        switch tab {
                        case .configuration: configuration
                        case .tools: tools
                        case .skills: skills
                        }
                    }
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { installedSkills = IOSSkillFileStore().listSkillDirNames().sorted() }
        .onChange(of: modelId) { _, _ in reasoning = "inherit" }
    }

    private var configuration: some View {
        VStack(spacing: 0) {
            note(role?.summary ?? "配置这个子代理的执行方式。")
            AmberSectionLabel(text: "模型")
            AmberFormGroup {
                HStack {
                    Text("默认模型").foregroundStyle(AmberTheme.foreground)
                    Spacer(minLength: 12)
                    Picker("默认模型", selection: $modelId) {
                        Text("跟随主代理").tag("")
                        ForEach(sharedSettings.availableChatModels()) { model in
                            Text("\(model.displayName) · \(model.providerName)").tag(model.id)
                        }
                        if !modelId.isEmpty && !sharedSettings.availableChatModels().contains(where: { $0.id == modelId }) {
                            Text("已移除的模型，请重新选择").tag(modelId)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(AmberTheme.accent)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                Divider().padding(.leading, 14)
                HStack {
                    Text("推理强度").foregroundStyle(AmberTheme.foreground)
                    Spacer(minLength: 12)
                    Picker("推理强度", selection: $reasoning) {
                        Text("跟随主代理").tag("inherit")
                        ForEach(reasoningOptions) { option in Text(option.title).tag(option.rawValue) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(AmberTheme.accent)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
            }
            AmberSectionLabel(text: "提示词")
            AmberFormGroup {
                TextEditor(text: $promptDraft)
                    .font(.subheadline)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 230)
                    .padding(10)
                    .accessibilityLabel("子代理提示词")
            }
            note("任务目标和主代理选取的上下文会另行传入。这里定义角色的职责和做事方式。")
            if let role { note(role.routing) }
            Button("恢复角色默认配置") {
                promptDraft = role?.systemPrompt ?? ""
                modelId = ""
                reasoning = "inherit"
                useDefaultTools = true
                selectedTools = Set(role?.toolAllowlist ?? [])
                selectedSkills = []
            }
            .foregroundStyle(AmberTheme.accent)
            .frame(minHeight: 48)
            .padding(.top, 12)
        }
    }

    private var reasoningOptions: [ComposerReasoningOption] {
        sharedSettings.subAgentReasoningLevels(modelId: modelId.isEmpty ? nil : modelId)
            .map(ComposerReasoningOption.init)
    }

    private var tools: some View {
        VStack(spacing: 0) {
            AmberFormGroup {
                Toggle("使用角色默认工具", isOn: $useDefaultTools)
                    .tint(AmberTheme.accent)
                    .padding(14)
            }
            note(useDefaultTools
                 ? "当前角色默认选择 \(defaultToolNames.count) 个工具。关闭上方开关可自行选择。"
                 : "已选择 \(selectedTools.count) 个工具。未选择任何工具时，只使用模型完成任务。")
            AmberFormGroup {
                TextField("搜索工具", text: $toolQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
            }
            AmberSectionLabel(text: "应用工具")
            toolGroup(matchingTools(appToolNames))
            ForEach(mcpServers) { server in
                AmberSectionLabel(text: "MCP · \(server.name)\(server.enabled ? "" : " · 已禁用")")
                let names = server.tools.map { ToolKt.expandedMcpToolName(server: server.name, tool: $0.name) }
                toolGroup(matchingTools(names))
            }
            if !missingMcpToolNames.isEmpty {
                AmberSectionLabel(text: "已移除的 MCP 工具")
                toolGroup(matchingTools(missingMcpToolNames))
            }
            note("只能调用主代理当前可用且已授权的工具；选中工具不会开启已关闭的服务器或跳过审批。")
        }
        .onChange(of: useDefaultTools) { wasDefault, isDefault in
            if wasDefault && !isDefault { selectedTools = Set(defaultToolNames) }
        }
    }

    private var defaultToolNames: [String] {
        let mcpNames = mcpServers.filter(\.enabled).flatMap { server in
            server.tools.filter(\.enabled).map { ToolKt.expandedMcpToolName(server: server.name, tool: $0.name) }
        }
        return IOSSubAgentRoleCatalog.defaultToolNames(
            roleId: roleId, availableToolNames: ToolKt.iosToolDeclarationNames() + mcpNames,
            mcpServers: mcpServers
        )
    }

    private var appToolNames: [String] {
        if useDefaultTools { return defaultToolNames.filter { !ToolKt.isExpandedMcpToolName(name: $0) } }
        let builtIn = Set(ToolKt.iosToolDeclarationNames()).subtracting([
            "subagent_dispatch", "subagent_report", "mcp_call"
        ])
        return builtIn.union(selectedTools.filter { !ToolKt.isExpandedMcpToolName(name: $0) }).sorted()
    }

    private func matchingTools(_ names: [String]) -> [String] {
        names.filter { toolQuery.isEmpty || $0.localizedCaseInsensitiveContains(toolQuery) }
    }

    private var missingMcpToolNames: [String] {
        let configured = Set(mcpServers.flatMap { server in
            server.tools.map { ToolKt.expandedMcpToolName(server: server.name, tool: $0.name) }
        })
        return selectedTools.filter { ToolKt.isExpandedMcpToolName(name: $0) && !configured.contains($0) }.sorted()
    }

    private func toolGroup(_ names: [String]) -> some View {
        AmberFormGroup {
            if names.isEmpty {
                Text(toolQuery.isEmpty ? "尚无可用工具" : "没有匹配的工具")
                    .font(.caption).foregroundStyle(AmberTheme.muted).padding(14)
            }
            ForEach(Array(names.enumerated()), id: \.element) { index, tool in
                Toggle(isOn: Binding(
                    get: { useDefaultTools ? defaultToolNames.contains(tool) : selectedTools.contains(tool) },
                    set: { enabled in
                        if enabled { selectedTools.insert(tool) } else { selectedTools.remove(tool) }
                    }
                )) {
                    Text(tool).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                }
                .tint(AmberTheme.accent)
                .disabled(useDefaultTools)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                if index < names.count - 1 { Divider().padding(.leading, 14) }
            }
        }
    }

    private var skills: some View {
        VStack(spacing: 0) {
            note("子代理启动时会加载所选技能的完整提示词，用于当前任务。技能中的工具调用仍受上一个标签页的选择约束。")
            AmberSectionLabel(text: "默认技能")
            AmberFormGroup {
                if installedSkills.isEmpty && selectedSkills.isEmpty {
                    Text("还没有安装技能。请先在设置的「技能」中添加。")
                        .font(.subheadline).foregroundStyle(AmberTheme.muted).padding(14)
                }
                let names = Set(installedSkills).union(selectedSkills).sorted()
                ForEach(Array(names.enumerated()), id: \.element) { index, skill in
                    Toggle(isOn: Binding(
                        get: { selectedSkills.contains(skill) },
                        set: { enabled in
                            if enabled { selectedSkills.insert(skill) } else { selectedSkills.remove(skill) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill).font(.body)
                            if !installedSkills.contains(skill) {
                                Text("技能已移除，启动前需要重新安装或取消选择")
                                    .font(.caption).foregroundStyle(AmberTheme.accentAmber)
                            } else if !sharedSettings.isSkillEnabled(skill) {
                                Text("请先在当前助手的技能设置中启用")
                                    .font(.caption).foregroundStyle(AmberTheme.muted)
                            }
                        }
                    }
                    .tint(AmberTheme.accent)
                    .disabled(!sharedSettings.isSkillEnabled(skill) && !selectedSkills.contains(skill))
                    .padding(14)
                    if index < names.count - 1 { Divider().padding(.leading, 14) }
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(AmberTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func save() {
        if promptDraft == role?.systemPrompt, modelId.isEmpty, reasoning == "inherit",
           useDefaultTools, selectedSkills.isEmpty {
            sharedSettings.resetSubAgentRole(roleId)
            return
        }
        sharedSettings.configureSubAgentRole(
            roleId: roleId,
            systemPrompt: promptDraft,
            modelId: modelId.isEmpty ? nil : modelId,
            reasoningLevel: ComposerReasoningOption(rawValue: reasoning)?.reasoningLevel,
            toolAllowlist: useDefaultTools ? nil : selectedTools,
            defaultSkillNames: selectedSkills.sorted()
        )
    }
}

#Preview {
    NavigationStack {
        SubAgentRoleView(sharedSettings: IOSSharedSettingsStore(), name: "Oracle", roleId: "oracle")
    }
}
