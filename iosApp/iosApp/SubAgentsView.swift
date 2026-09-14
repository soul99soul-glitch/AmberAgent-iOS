import SwiftUI

struct SubAgentsView: View {
    let sharedSettings: IOSSharedSettingsStore
    @State private var activityStore: IOSSubAgentActivityStore

    @Environment(RouterPath.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isModelPoolPresented = false

    init(
        sharedSettings: IOSSharedSettingsStore,
        activityStore: IOSSubAgentActivityStore = .shared
    ) {
        self.sharedSettings = sharedSettings
        _activityStore = State(initialValue: activityStore)
    }

    private var roles: [IOSSubAgentRoleDescriptor] {
        IOSSubAgentRoleCatalog.builtIns.filter { $0.id == "browser" }
            + IOSSubAgentRoleCatalog.builtIns.filter { $0.id != "browser" }
    }

    var body: some View {
        // The KMP snapshot is ObservationIgnored; its revision drives redraws.
        let _ = sharedSettings.revision
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                        dismiss()
                    }
                    Spacer()
                    Text("子代理").font(.headline).foregroundStyle(AmberTheme.foreground)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                ScrollView {
                    VStack(spacing: 0) {
                        Text("把独立任务交给子代理，在当前聊天中继续沟通。任务进度和结果会回到原会话。")
                            .font(.subheadline)
                            .foregroundStyle(AmberTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)

                        AmberSectionLabel(text: "编排")
                        AmberFormGroup {
                            Toggle(isOn: Binding(
                                get: { sharedSettings.allowsDynamicSubAgents },
                                set: { sharedSettings.setDynamicSubAgentsAllowed($0) }
                            )) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("允许动态创建子代理").font(.body.weight(.medium))
                                    Text("按任务定义提示词、上下文、工具和默认技能。关闭后使用下方角色配置。")
                                        .font(.caption)
                                        .foregroundStyle(AmberTheme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .tint(AmberTheme.accent)
                            .padding(14)
                            .accessibilityIdentifier("subagents.allowDynamic")
                        }

                        executionSection

                        AmberSectionLabel(text: "悬浮子代理")
                        AmberFormGroup {
                            Toggle(isOn: Binding(
                                get: { activityStore.isEnabled },
                                set: { activityStore.isEnabled = $0 }
                            )) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("显示悬浮子代理")
                                        .font(.body.weight(.medium))
                                    Text("在聊天输入区上方显示所有会话的子代理。")
                                        .font(.caption)
                                        .foregroundStyle(AmberTheme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .tint(AmberTheme.accent)
                            .padding(14)
                            .accessibilityIdentifier("subagents.activity.enabled")

                            Divider()
                                .overlay(AmberTheme.borderSoft)
                                .padding(.leading, 14)

                            autoDismissSetting
                        }
                        .id("subagents.activity")
                        Text("任务结束后开始计时，阅读详情时暂缓收起。收起不会删除记录，也不影响结果返回。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 30)
                            .padding(.top, 8)

                        AmberSectionLabel(text: "角色")
                        AmberFormGroup {
                            ForEach(Array(roles.enumerated()), id: \.element.id) { index, role in
                                Button {
                                    router.navigate(to: .subAgentRole(name: role.name, roleId: role.id))
                                } label: {
                                    roleRow(role)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("subagents.role.\(role.id)")
                                if index < roles.count - 1 {
                                    Divider().overlay(AmberTheme.borderSoft).padding(.leading, 58)
                                }
                            }
                        }
                        Text("浏览器任务使用已配置的 MCP 或站点工具。切到其他 App 后，运行时间受 iOS 后台调度限制。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isModelPoolPresented) {
            SubAgentModelPoolView(sharedSettings: sharedSettings)
        }
    }

    private var executionSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "执行")
            AmberFormGroup {
                Stepper(value: Binding(
                    get: { sharedSettings.subAgentMaxConcurrentRuns },
                    set: { value in
                        sharedSettings.setSubAgentExecutionLimits(
                            maxConcurrentRuns: value,
                            timeoutMinutes: sharedSettings.subAgentTimeoutMinutes
                        )
                    }
                ), in: 1...10) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("最大并发")
                                .font(.body.weight(.medium))
                                .foregroundStyle(AmberTheme.foreground)
                            Text("同时运行的子代理数量")
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                        }
                        Spacer(minLength: 12)
                        Text("\(sharedSettings.subAgentMaxConcurrentRuns)")
                            .font(.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(AmberTheme.accent)
                            .frame(minWidth: 28, alignment: .trailing)
                    }
                }
                .padding(14)
                .accessibilityIdentifier("subagents.execution.maxConcurrent")

                Divider()
                    .overlay(AmberTheme.borderSoft)
                    .padding(.leading, 14)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("单任务超时")
                            .font(.body.weight(.medium))
                            .foregroundStyle(AmberTheme.foreground)
                        Text("达到时间后结束该子代理")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    }
                    Spacer(minLength: 12)
                    Picker("单任务超时", selection: Binding(
                        get: { sharedSettings.subAgentTimeoutMinutes },
                        set: { value in
                            sharedSettings.setSubAgentExecutionLimits(
                                maxConcurrentRuns: sharedSettings.subAgentMaxConcurrentRuns,
                                timeoutMinutes: value
                            )
                        }
                    )) {
                        ForEach(timeoutOptions, id: \.self) { minutes in
                            Text("\(minutes) 分钟").tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(AmberTheme.accent)
                }
                .padding(14)
                .accessibilityIdentifier("subagents.execution.timeout")

                Divider()
                    .overlay(AmberTheme.borderSoft)
                    .padding(.leading, 14)

                Button {
                    isModelPoolPresented = true
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("模型池")
                                .font(.body.weight(.medium))
                                .foregroundStyle(AmberTheme.foreground)
                            Text(modelPoolSummary)
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted2)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("subagents.execution.modelPool")
            }
            Text("模型池为空时沿用当前聊天模型；选择模型池后，动态子代理会在可用模型之间分散运行。")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 8)
        }
    }

    private var timeoutOptions: [Int] {
        Array(Set([1, 3, 5, 10, 15, 20, 30, 45, 60, sharedSettings.subAgentTimeoutMinutes])).sorted()
    }

    private var modelPoolSummary: String {
        let count = sharedSettings.subAgentModelPool.count
        return count == 0 ? "未选择，跟随当前模型" : "已选择 \(count) 个模型"
    }

    private var autoDismissSetting: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text("完成后自动收起")
                .font(.body.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Picker("完成后自动收起", selection: Binding(
                get: { activityStore.autoDismissDelay },
                set: { activityStore.autoDismissDelay = $0 }
            )) {
                ForEach(IOSSubAgentAutoDismissDelay.allCases) { delay in
                    Text(delay.title).tag(delay)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(AmberTheme.accent)
            .accessibilityIdentifier("subagents.activity.autoDismissDelay")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func roleRow(_ role: IOSSubAgentRoleDescriptor) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(for: role.id))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AmberTheme.accent)
                .frame(width: 32, height: 36)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(role.name).font(.body.weight(.semibold)).foregroundStyle(AmberTheme.foreground)
                    if sharedSettings.snapshot.agentRuntime.subAgent.overrides[role.id] != nil {
                        Text("已自定义").font(.caption2).foregroundStyle(AmberTheme.accent)
                    }
                }
                Text(role.summary)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    static func symbol(for roleId: String) -> String {
        switch roleId {
        case "browser": "globe"
        case "explorer": "magnifyingglass"
        case "historian": "clock.arrow.circlepath"
        case "oracle": "sparkle.magnifyingglass"
        case "designer": "paintpalette"
        case "writer": "pencil.line"
        default: "wrench.and.screwdriver"
        }
    }
}

#Preview {
    NavigationStack {
        SubAgentsView(sharedSettings: IOSSharedSettingsStore())
            .environment(RouterPath())
    }
}
