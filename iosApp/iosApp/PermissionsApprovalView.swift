import SwiftUI

struct PermissionsApprovalView: View {
    @Bindable var permissionStore: IOSPermissionStore

    @Environment(RouterPath.self) private var router
    @Environment(\.dismiss) private var dismiss

    @AppStorage("app.amber.ios.globalAutoApprove") private var globalAutoApprove = false
    @AppStorage("app.amber.ios.highRiskAutoApprove") private var highRiskAutoApprove = false

    private var approvalCapabilities: [IOSPlatformCapability] {
        [
            "ios.files.selected_read",
            "ios.workspace.file_read",
            "ios.workspace.file_write",
            "ios.local.ambershell",
            "ios.agent.memory_write",
            "ios.network.search_tools",
            "ios.mcp.tool_call",
            "ios.webmount.browser",
            "ios.remote.command",
            "ios.agent.model_council_run"
        ].compactMap { id in
            IOSCapabilityRegistry.capabilities.first { $0.id == id }
        }
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 0) {
                        Text("管理 Agent 使用文件、记忆和网页会话前是否需要确认。")
                            .font(.footnote)
                            .foregroundStyle(AmberTheme.muted)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)

                        systemPermissionsSection
                        globalApprovalSection
                        approvalPolicySection
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            normalizeDisplayedPolicies()
        }
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回设置", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            Text("权限与批准")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)

            Spacer()

            Color.clear
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }

    private var systemPermissionsSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "系统权限")
            AmberFormGroup {
                AmberFormRow(
                    systemImage: "checkmark.shield",
                    iconColor: AmberTheme.accentCyan,
                    title: IOSAppLocalization.string("权限与能力", defaultValue: "权限与能力"),
                    subtitle: IOSAppLocalization.string(
                        "按能力管理：文件 / 媒体 / 健康 / 定位 / 通讯录等",
                        defaultValue: "按能力管理：文件 / 媒体 / 健康 / 定位 / 通讯录等"
                    ),
                    showsChevron: true
                ) {
                    router.navigate(to: .capabilities)
                }
            }
        }
    }

    /// 全局自动批准 + 高风险自动批准开关。
    private var globalApprovalSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "快速批准")
            AmberFormGroup {
                AmberFormRow(
                    systemImage: globalAutoApprove ? "checkmark.shield.fill" : "shield",
                    iconColor: globalAutoApprove ? AmberTheme.accentGreen : AmberTheme.muted,
                    title: IOSAppLocalization.string("全局自动批准", defaultValue: "全局自动批准"),
                    subtitle: IOSAppLocalization.string("普通工具自动放行", defaultValue: "普通工具自动放行"),
                    trailing: nil,
                    showsChevron: false
                ) {
                    withAnimation { globalAutoApprove.toggle() }
                }
                .overlay(alignment: .trailing) {
                    Image(systemName: globalAutoApprove ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(globalAutoApprove ? AmberTheme.accentGreen : AmberTheme.muted2)
                        .padding(.trailing, 14)
                }

                Divider().overlay(AmberTheme.borderSoft).padding(.leading, 58)

                AmberFormRow(
                    systemImage: highRiskAutoApprove ? "exclamationmark.shield.fill" : "exclamationmark.triangle",
                    iconColor: highRiskAutoApprove ? AmberTheme.accentRed : AmberTheme.muted,
                    title: IOSAppLocalization.string("高风险自动批准", defaultValue: "高风险自动批准"),
                    subtitle: IOSAppLocalization.string(
                        "含任意公网网站、远程命令等",
                        defaultValue: "含任意公网网站、远程命令等"
                    ),
                    trailing: nil,
                    showsChevron: false
                ) {
                    withAnimation { highRiskAutoApprove.toggle() }
                }
                .overlay(alignment: .trailing) {
                    Image(systemName: highRiskAutoApprove ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(highRiskAutoApprove ? AmberTheme.accentRed : AmberTheme.muted2)
                        .padding(.trailing, 14)
                }
            }
        }
    }

    private var approvalPolicySection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "工具批准")
            AmberFormGroup {
                ForEach(Array(approvalCapabilities.enumerated()), id: \.element.id) { index, capability in
                    PermissionPolicyRow(
                        capability: capability,
                        policy: displayedPolicy(for: capability),
                        availablePolicies: displayedPolicies(for: capability),
                        decisionSummary: displayedDecisionSummary(for: capability),
                        lastApprovalSummary: displayedLastApprovalSummary(for: capability)
                    ) { policy in
                        permissionStore.setPolicy(policy, for: capability)
                    }

                    if index < approvalCapabilities.count - 1 {
                        Divider()
                            .overlay(AmberTheme.borderSoft)
                            .padding(.leading, 58)
                    }
                }
            }

        }
    }

    private func displayedPolicies(for capability: IOSPlatformCapability) -> [IOSAgentPermissionPolicy] {
        let policies = permissionStore.availablePolicies(for: capability).filter { $0 != .allowOncePerRun }
        guard capability.id == "ios.local.ambershell" else { return policies }
        return policies.filter { $0 == .disabled || $0 == .askEveryTime }
    }

    private func displayedDecisionSummary(for capability: IOSPlatformCapability) -> String {
        switch displayedPolicy(for: capability) {
        case .disabled:
            "禁用"
        case .askEveryTime, .allowOncePerRun:
            "询问"
        case .autoApprove:
            "自动"
        case .autoApproveHighRisk:
            "自动·高风险"
        }
    }

    private func displayedPolicy(for capability: IOSPlatformCapability) -> IOSAgentPermissionPolicy {
        let policy = permissionStore.policy(for: capability)
        if capability.id == "ios.local.ambershell",
           policy != .disabled,
           policy != .askEveryTime {
            return .askEveryTime
        }
        return policy == .allowOncePerRun ? .askEveryTime : policy
    }

    private func displayedLastApprovalSummary(for capability: IOSPlatformCapability) -> String? {
        guard let record = permissionStore.latestApproval(for: capability) else { return nil }
        return "最近：\(record.action.title) · \(record.toolName)"
    }

    private func normalizeDisplayedPolicies() {
        for capability in approvalCapabilities {
            let policy = permissionStore.policy(for: capability)
            if policy == .allowOncePerRun ||
                (capability.id == "ios.local.ambershell" && policy != .disabled && policy != .askEveryTime) {
                permissionStore.setPolicy(.askEveryTime, for: capability)
            }
        }
    }
}

private struct PermissionPolicyRow: View {
    let capability: IOSPlatformCapability
    let policy: IOSAgentPermissionPolicy
    let availablePolicies: [IOSAgentPermissionPolicy]
    let decisionSummary: String
    let lastApprovalSummary: String?
    let onSelect: (IOSAgentPermissionPolicy) -> Void

    var body: some View {
        Menu {
            ForEach(availablePolicies) { option in
                Button(option.localizedTitle) {
                    onSelect(option)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: capability.localizedTitle)
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                    Text(verbatim: permissionSummary)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted2)
                        .lineLimit(capability.id == "ios.local.ambershell" ? 2 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(verbatim: policy.localizedTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(policy == .disabled ? AmberTheme.muted : AmberTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(policy == .disabled ? AmberTheme.surface2 : AmberTheme.accentTint, in: Capsule())

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
            }
            .frame(minHeight: 64)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .disabled(availablePolicies.count <= 1)
        .opacity(availablePolicies.count <= 1 ? 0.72 : 1)
        .accessibilityLabel("\(capability.localizedTitle)，\(policy.localizedTitle)")
    }

    private var systemImage: String {
        switch capability.risk {
        case .normal: "checkmark.circle"
        case .sensitive: "hand.raised"
        case .high: "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch capability.risk {
        case .normal: AmberTheme.accentGreen
        case .sensitive: AmberTheme.accentAmber
        case .high: AmberTheme.accentRed
        }
    }

    private var permissionSummary: String {
        // 只显示简短说明（capability.summary 已是短句）。
        // 右侧胶囊已显示策略状态（禁用/询问/自动），这里不再重复拼接。
        switch capability.id {
        case "ios.files.selected_read":
            return IOSAppLocalization.string("读取用户选取的文件", defaultValue: "读取用户选取的文件")
        case "ios.workspace.file_read":
            return IOSAppLocalization.string("读取文件和产出", defaultValue: "读取文件和产出")
        case "ios.workspace.file_write":
            return IOSAppLocalization.string("写入文件、删除产出", defaultValue: "写入文件、删除产出")
        case "ios.local.ambershell":
            return IOSAppLocalization.string("在 /workspace 执行受限本地命令", defaultValue: "在 /workspace 执行受限本地命令")
        case "ios.agent.memory_write":
            return IOSAppLocalization.string("新增、编辑或删除记忆", defaultValue: "新增、编辑或删除记忆")
        case "ios.network.search_tools":
            return IOSAppLocalization.string("联网搜索和网页抓取", defaultValue: "联网搜索和网页抓取")
        case "ios.mcp.tool_call":
            return IOSAppLocalization.string("调用已配置的 MCP 服务", defaultValue: "调用已配置的 MCP 服务")
        case "ios.webmount.browser":
            return IOSAppLocalization.string("读取或操作网页会话", defaultValue: "读取或操作网页会话")
        case "ios.remote.command":
            return IOSAppLocalization.string("SSH 远程执行单条命令", defaultValue: "SSH 远程执行单条命令")
        case "ios.agent.model_council_run":
            return "发起议会讨论"
        default:
            return capability.summary
        }
    }
}
