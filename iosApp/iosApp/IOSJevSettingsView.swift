import SwiftUI
@preconcurrency import Shared

// MARK: - Jev 快速判断设置页（Phase 1）
//
// 完成设置闭环的可见控件层：Key 管理（Keychain 写成功才更新 UI）、合成数据
// 连接测试（返回实际模型版本/耗时/错误，不自动启用任何用途）、每用途模式、
// 数据范围、状态与近期开销。阈值留在版本化内部策略（IOSJevPolicy），不做
// 配置中心。Jev 不进入普通聊天 provider/模型列表。

struct IOSJevSettingsView: View {
    let sharedSettings: IOSSharedSettingsStore

    @Environment(\.dismiss) private var dismiss
    @State private var apiKeyInput = ""
    @State private var keyMessage: String?
    @State private var isTestingConnection = false
    @State private var connectionResult: ConnectionTestPresentation?
    @State private var metricsSummary: IOSJevMetricsStore.Summary?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    struct ConnectionTestPresentation: Equatable {
        var succeeded: Bool
        var text: String
    }

    /// 已接线的用途（网页操作随 wm_run_goal 工具接线后开放）。
    private let activeUseCases: [IOSJevUseCase] = [.toolDiscovery, .memoryRecall, .contextSelection, .modelRouting]

    var body: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        keySection
                        connectionSection
                        useCaseSection
                        metricsSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(IOSAppLocalization.string("Jev 快速判断", defaultValue: "Jev 快速判断"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IOSAppLocalization.string("完成", defaultValue: "完成")) { dismiss() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .onAppear(perform: refreshDynamicState)
    }

    private func refreshDynamicState() {
        metricsSummary = IOSJevMetricsStore.summary()
    }

    // MARK: Key

    private var hasKey: Bool { sharedSettings.hasJevApiKey() }

    private var keySection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "API Key")
            AmberFormGroup {
                SecureField(IOSAppLocalization.string("粘贴 TypeSafe API Key", defaultValue: "粘贴 TypeSafe API Key"), text: $apiKeyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                Divider()
                    .overlay(AmberTheme.borderSoft)
                    .padding(.leading, 14)

                // 极端字号下按钮换到第二行：图标+按钮的固定宽度会把文本列挤到
                // 单字宽（320pt AX3 实测缺陷）；常规字号保持单行（与其他行一致）。
                let buttons = HStack(spacing: 16) {
                    Button {
                        saveKey()
                    } label: {
                        Text(IOSAppLocalization.string("保存", defaultValue: "保存"))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(apiKeyInput.isEmpty ? AmberTheme.muted2 : AmberTheme.accent)
                    .disabled(apiKeyInput.isEmpty)

                    Button {
                        sharedSettings.clearJevApiKey()
                        apiKeyInput = ""
                        keyMessage = IOSAppLocalization.string("已清除 Key；所有 Jev 用途回到未配置状态。", defaultValue: "已清除 Key；所有 Jev 用途回到未配置状态。")
                    } label: {
                        Text(IOSAppLocalization.string("清除", defaultValue: "清除"))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(hasKey ? AmberTheme.accentRed : AmberTheme.muted2)
                    .disabled(!hasKey)

                    Spacer()
                }

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                keyIcon
                                keyText
                            }
                            buttons.padding(.leading, 40)
                        }
                    } else {
                        HStack(spacing: 12) {
                            keyIcon
                            keyText
                            buttons
                        }
                    }
                }
                .frame(minHeight: 58)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            if let keyMessage {
                Text(keyMessage)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 30)
                    .padding(.top, 8)
            }
        }
    }

    private var keyIcon: some View {
        Image(systemName: hasKey ? "checkmark.seal.fill" : "key")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(hasKey ? AmberTheme.accentGreen : AmberTheme.foreground2)
            .frame(width: 28, height: 28)
    }

    private var keyText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(IOSAppLocalization.string(hasKey ? "已保存到钥匙串" : "未配置", defaultValue: hasKey ? "已保存到钥匙串" : "未配置"))
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
            Text(IOSAppLocalization.string("Key 仅存本机钥匙串；不会写入备份或日志。", defaultValue: "Key 仅存本机钥匙串；不会写入备份或日志。"))
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveKey() {
        // Keychain 写入成功才更新 UI（store 内部保证原可用 Key 不被失败覆盖）。
        if sharedSettings.storeJevApiKey(apiKeyInput) {
            apiKeyInput = ""
            keyMessage = IOSAppLocalization.string("Key 已保存。", defaultValue: "Key 已保存。")
            connectionResult = nil
        } else {
            keyMessage = IOSAppLocalization.string(
                "保存失败：Key 为空或钥匙串写入未成功，原 Key 保持不变。",
                defaultValue: "保存失败：Key 为空或钥匙串写入未成功，原 Key 保持不变。"
            )
        }
    }

    // MARK: Connection test

    private var connectionSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "连接测试")
            AmberFormGroup {
                Button {
                    runConnectionTest()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(AmberTheme.foreground2)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(IOSAppLocalization.string("使用合成数据测试连接", defaultValue: "使用合成数据测试连接"))
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                            Text(IOSAppLocalization.string("发送一条与用户数据无关的句子验证连通性；不会启用任何用途。", defaultValue: "发送一条与用户数据无关的句子验证连通性；不会启用任何用途。"))
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if isTestingConnection {
                            ProgressView()
                        }
                    }
                    .frame(minHeight: 58)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
                .disabled(isTestingConnection || !hasKey)
            }
            if let connectionResult {
                Text(connectionResult.text)
                    .font(.caption)
                    .foregroundStyle(connectionResult.succeeded ? AmberTheme.accentGreen : AmberTheme.accentRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 30)
                    .padding(.top, 8)
            }
        }
    }

    private func runConnectionTest() {
        guard let apiKey = IOSCredentialSideTable.load(key: IOSCredentialSideTable.jevApiKey), !apiKey.isEmpty else {
            connectionResult = ConnectionTestPresentation(
                succeeded: false,
                text: IOSAppLocalization.string("未配置 API Key。", defaultValue: "未配置 API Key。")
            )
            return
        }
        isTestingConnection = true
        connectionResult = nil
        Task {
            let result = await IOSJevDecisionCoordinator.shared.runConnectionTest(apiKey: apiKey)
            let presentation: ConnectionTestPresentation
            if result.succeeded, let model = result.modelVersion {
                var text = IOSAppLocalization.formatted(
                    "连接成功：模型 %@，耗时 %d ms",
                    defaultValue: "连接成功：模型 %@，耗时 %d ms",
                    arguments: [model, result.latencyMs]
                )
                if let input = result.inputTokens, let output = result.outputTokens {
                    text += IOSAppLocalization.formatted(
                        "，tokens %d+%d",
                        defaultValue: "，tokens %d+%d",
                        arguments: [input, output]
                    )
                }
                presentation = ConnectionTestPresentation(succeeded: true, text: text + IOSAppLocalization.string("。", defaultValue: "。"))
            } else {
                presentation = ConnectionTestPresentation(
                    succeeded: false,
                    text: IOSAppLocalization.formatted(
                        "连接失败（%@，%d ms）。401/403 时请检查 Key。",
                        defaultValue: "连接失败（%@，%d ms）。401/403 时请检查 Key。",
                        arguments: [result.errorReason ?? "unknown", result.latencyMs]
                    )
                )
            }
            await MainActor.run {
                isTestingConnection = false
                connectionResult = presentation
                refreshDynamicState()
            }
        }
    }

    // MARK: Per-use-case modes & scopes

    private var useCaseSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "用途与数据范围")
            AmberFormGroup {
                ForEach(Array(activeUseCases.enumerated()), id: \.element) { index, useCase in
                    if index > 0 {
                        Divider()
                            .overlay(AmberTheme.borderSoft)
                            .padding(.leading, 58)
                    }
                    useCaseRow(useCase)
                }
            }
            Text(IOSAppLocalization.string("Shadow 同样会把允许外发的数据发送给 TypeSafe 评分，只是不应用结果。关闭 = 零 Jev 网络调用。", defaultValue: "Shadow 同样会把允许外发的数据发送给 TypeSafe 评分，只是不应用结果。关闭 = 零 Jev 网络调用。"))
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func useCaseRow(_ useCase: IOSJevUseCase) -> some View {
        let settings = sharedSettings.jevSettings
        let configuredMode = settings.mode(for: useCase)
        let effectiveMode = settings.effectiveMode(for: useCase)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: {
                    switch useCase {
                    case .toolDiscovery: "magnifyingglass"
                    case .memoryRecall: "brain"
                    case .contextSelection: "doc.text.magnifyingglass"
                    default: "arrow.triangle.branch"
                    }
                }())
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AmberTheme.foreground2)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(IOSAppLocalization.string(useCase.displayName, defaultValue: useCase.displayName))
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)
                    Text(IOSAppLocalization.string(effectiveMode.detail, defaultValue: effectiveMode.detail))
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    ForEach(IOSJevMode.allCases) { mode in
                        Button {
                            updateMode(mode, for: useCase)
                        } label: {
                            if mode == configuredMode {
                                Label(mode.displayName, systemImage: "checkmark")
                            } else {
                                Text(mode.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(IOSAppLocalization.string(configuredMode.displayName, defaultValue: configuredMode.displayName))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(configuredMode == .off ? AmberTheme.muted : AmberTheme.accent)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted2)
                    }
                }
                .accessibilityLabel("\(useCase.displayName)模式")
            }
            // 数据范围：请求需要的范围全部允许才发送。
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(requiredScopes(for: useCase).sorted { $0.displayName < $1.displayName }), id: \.self) { scope in
                    Button {
                        toggleScope(scope, for: useCase)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: settings.allowedScopes(for: useCase).contains(scope) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 14))
                                .foregroundStyle(settings.allowedScopes(for: useCase).contains(scope) ? AmberTheme.accent : AmberTheme.muted2)
                            Text(IOSAppLocalization.string(scope.displayName, defaultValue: scope.displayName))
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 40)
                }
            }
            if configuredMode == .active && effectiveMode == .shadow {
                Text(IOSAppLocalization.string("active 需要固定模型版本验收后才会真正生效，当前按 shadow 执行。", defaultValue: "active 需要固定模型版本验收后才会真正生效，当前按 shadow 执行。"))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentAmber)
                    .padding(.leading, 40)
            }
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func requiredScopes(for useCase: IOSJevUseCase) -> Set<IOSJevDataScope> {
        switch useCase {
        case .toolDiscovery: [.toolMetadata, .selectedTaskText]
        case .memoryRecall: [.selectedTaskText, .personalMemory]
        case .contextSelection: [.selectedTaskText, .toolOutput]
        default: useCase.defaultDataScopes
        }
    }

    private func updateMode(_ mode: IOSJevMode, for useCase: IOSJevUseCase) {
        var settings = sharedSettings.jevSettings
        settings.setMode(mode, for: useCase)
        sharedSettings.updateJevSettings(settings)
    }

    private func toggleScope(_ scope: IOSJevDataScope, for useCase: IOSJevUseCase) {
        var settings = sharedSettings.jevSettings
        var scopes = settings.allowedScopes(for: useCase)
        if scopes.contains(scope) {
            scopes.remove(scope)
        } else {
            scopes.insert(scope)
        }
        settings.setScopes(scopes, for: useCase)
        sharedSettings.updateJevSettings(settings)
    }

    // MARK: Metrics

    private var metricsSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "状态与开销")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 6) {
                    if let summary = metricsSummary {
                        Text(IOSAppLocalization.string("今日出站判断 \(summary.todayRequests) 次（累计请求 \(formatBytes(summary.todayRequestBytes))）", defaultValue: "今日出站判断 \(summary.todayRequests) 次（累计请求 \(formatBytes(summary.todayRequestBytes))）"))
                        Text(IOSAppLocalization.string("近 24 小时：应用 \(summary.last24hApplied) 次，回退/跳过 \(summary.last24hFallback) 次", defaultValue: "近 24 小时：应用 \(summary.last24hApplied) 次，回退/跳过 \(summary.last24hFallback) 次"))
                    } else {
                        Text(IOSAppLocalization.string("暂无记录", defaultValue: "暂无记录"))
                    }
                    statusLine
                }
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider()
                    .overlay(AmberTheme.borderSoft)
                    .padding(.leading, 14)

                Button {
                    IOSJevMetricsStore.clear()
                    metricsSummary = IOSJevMetricsStore.summary()
                } label: {
                    HStack {
                        Text(IOSAppLocalization.string("清除使用记录", defaultValue: "清除使用记录"))
                            .font(.subheadline)
                            .foregroundStyle(AmberTheme.accentRed)
                        Spacer()
                    }
                    .frame(minHeight: 44)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(IOSAppLocalization.string("指标只含用途、大小、耗时与用量，不含业务原文；最多保留 7 天。", defaultValue: "指标只含用途、大小、耗时与用量，不含业务原文；最多保留 7 天。"))
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        let status = IOSJevDecisionCoordinator.shared.status
        if status.pausedForAuth {
            Text(IOSAppLocalization.string("状态：认证失败已暂停，保存新 Key 或连接测试成功后恢复。", defaultValue: "状态：认证失败已暂停，保存新 Key 或连接测试成功后恢复。"))
                .foregroundStyle(AmberTheme.accentRed)
        } else if let cooldown = status.cooldownRemaining, cooldown > 0 {
            Text(IOSAppLocalization.string("状态：连续失败冷却中，约 \(Int(cooldown)) 秒后恢复。", defaultValue: "状态：连续失败冷却中，约 \(Int(cooldown)) 秒后恢复。"))
                .foregroundStyle(AmberTheme.accentAmber)
        } else {
            Text(IOSAppLocalization.string("状态：正常", defaultValue: "状态：正常"))
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        bytes < 1_024 ? "\(bytes) B" : String(format: "%.1f KiB", Double(bytes) / 1_024)
    }
}
