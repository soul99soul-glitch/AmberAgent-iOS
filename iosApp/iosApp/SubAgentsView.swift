import SwiftUI

struct SubAgentsView: View {
    let sharedSettings: IOSSharedSettingsStore

    @Environment(RouterPath.self) private var router
    @Environment(\.dismiss) private var dismiss

    private var roles: [IOSSubAgentRoleDescriptor] {
        IOSSubAgentRoleCatalog.builtIns.filter { $0.id == "browser" }
            + IOSSubAgentRoleCatalog.builtIns.filter { $0.id != "browser" }
    }

    var body: some View {
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
