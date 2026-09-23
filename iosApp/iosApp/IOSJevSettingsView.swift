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
    @State private var vercelModelInput = ""
    @State private var pinnedModelInput = ""
    @State private var keyMessage: String?
    @State private var isTestingConnection = false
    @State private var connectionResult: ConnectionTestPresentation?
    @State private var metricsSummary: IOSJevMetricsStore.Summary?
    @State private var useCaseMetricsSummaries: [IOSJevMetricsStore.UseCaseSummary] = []
    @State private var isAdvancedSettingsExpanded = true
    @State private var showingRecommendedConfigurationConfirmation = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    struct ConnectionTestPresentation: Equatable {
        var succeeded: Bool
        var text: String
    }

    /// 已接线的用途（七个全部开放；网页操作由 wm_run_goal 工具真实驱动，
    /// 意图路由作用于 spawn_agent 缺省角色定义的边界，审批分诊只标注不授权）。
    private let activeUseCases: [IOSJevUseCase] = [.toolDiscovery, .memoryRecall, .contextSelection, .modelRouting, .webActions, .subagentIntent, .approvalTriage]

    var body: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        apiSection
                        keySection
                        connectionSection
                        recommendedConfigurationSection
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
        .onDisappear {
            commitVercelModel()
            commitPinnedModel()
        }
    }

    private func refreshDynamicState() {
        metricsSummary = IOSJevMetricsStore.summary()
        useCaseMetricsSummaries = IOSJevMetricsStore.useCaseSummaries()
        let stored = sharedSettings.jevSettings.vercelModel
        // 存量配置（apiStyle=vercelGateway 且模型为空）打开页面时展示默认
        // slug；onSubmit/onDisappear/连接测试的既有 commit 路径负责落盘。
        vercelModelInput = stored.isEmpty && sharedSettings.jevSettings.apiStyle == .vercelGateway
            ? IOSJevSettings.vercelDefaultModel
            : stored
        pinnedModelInput = sharedSettings.jevSettings.pinnedModelVersion ?? ""
    }

    // MARK: API 调用方式

    private var apiSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "API")
            AmberFormGroup {
                // 辅助功能大字号下标题与取值垂直堆叠：窄列里 "TypeSafe 原生"
                // 会被逐字符断行（含英文单词中间断开），堆叠后取值有全宽可用。
                let styleMenu = Menu {
                    ForEach(IOSJevAPIStyle.allCases) { style in
                        Button {
                            updateAPIStyle(style)
                        } label: {
                            if style == sharedSettings.jevSettings.apiStyle {
                                Label(style.displayName, systemImage: "checkmark")
                            } else {
                                Text(style.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(IOSAppLocalization.string(
                            sharedSettings.jevSettings.apiStyle.displayName,
                            defaultValue: sharedSettings.jevSettings.apiStyle.displayName
                        ))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(AmberTheme.accent)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted2)
                    }
                }
                .accessibilityLabel("Jev API 调用方式")

                if dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(AmberTheme.foreground2)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(IOSAppLocalization.string("调用方式", defaultValue: "调用方式"))
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            styleMenu
                        }
                    }
                    .frame(minHeight: 58)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(AmberTheme.foreground2)
                            .frame(width: 28, height: 28)
                        Text(IOSAppLocalization.string("调用方式", defaultValue: "调用方式"))
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        styleMenu
                    }
                    .frame(minHeight: 58)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }

                if sharedSettings.jevSettings.apiStyle == .vercelGateway {
                    Divider()
                        .overlay(AmberTheme.borderSoft)
                        .padding(.leading, 14)
                    TextField(
                        IOSAppLocalization.string("评估模型 slug，如 typesafe-ai/jev", defaultValue: "评估模型 slug，如 typesafe-ai/jev"),
                        text: $vercelModelInput
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .onSubmit { commitVercelModel() }
                }

                if sharedSettings.jevSettings.apiStyle == .systemone {
                    Divider()
                        .overlay(AmberTheme.borderSoft)
                        .padding(.leading, 14)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            IOSAppLocalization.string("固定模型版本（连接测试后自动填入）", defaultValue: "固定模型版本（连接测试后自动填入）"),
                            text: $pinnedModelInput
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .onSubmit { commitPinnedModel() }
                        Text(IOSAppLocalization.string(
                            "active 需要已验收的固定版本；留空则一律按 shadow 观测。",
                            defaultValue: "active 需要已验收的固定版本；留空则一律按 shadow 观测。"
                        ))
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private func updateAPIStyle(_ style: IOSJevAPIStyle) {
        guard style != sharedSettings.jevSettings.apiStyle else { return }
        // 先提交两个输入框的未回车文本，再切形态刷新显示（防 typed 值被
        // 持久化值覆盖，也防隐藏字段的 stale 文本在 onDisappear 时串写）。
        commitVercelModel()
        commitPinnedModel()
        var settings = sharedSettings.jevSettings
        settings.setAPIStyle(style)
        sharedSettings.updateJevSettings(settings)
        vercelModelInput = settings.vercelModel
        pinnedModelInput = settings.pinnedModelVersion ?? ""
        connectionResult = nil
        keyMessage = nil
    }

    private func commitVercelModel() {
        var settings = sharedSettings.jevSettings
        let trimmed = vercelModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != settings.vercelModel else { return }
        settings.setVercelModel(trimmed)
        sharedSettings.updateJevSettings(settings)
    }

    private func commitPinnedModel() {
        var settings = sharedSettings.jevSettings
        let trimmed = pinnedModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (settings.pinnedModelVersion ?? "") else { return }
        settings.setPinnedModelVersion(trimmed.isEmpty ? nil : trimmed)
        sharedSettings.updateJevSettings(settings)
    }

    // MARK: Key

    private var hasKey: Bool { sharedSettings.hasJevApiKey() }

    private var keySection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "API Key")
            AmberFormGroup {
                SecureField(
                    IOSAppLocalization.string(
                        sharedSettings.jevSettings.apiStyle.keyPlaceholder,
                        defaultValue: sharedSettings.jevSettings.apiStyle.keyPlaceholder
                    ),
                    text: $apiKeyInput
                )
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
                        connectionResult = nil
                        keyMessage = IOSAppLocalization.string("已清除。", defaultValue: "已清除。")
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
            Text(IOSAppLocalization.string("仅存本机钥匙串。", defaultValue: "仅存本机钥匙串。"))
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
                "保存失败：原 Key 不变。",
                defaultValue: "保存失败：原 Key 不变。"
            )
        }
    }

    // MARK: Connection test

    private var connectionSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "连接")
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
                            Text(IOSAppLocalization.string("测试连接", defaultValue: "测试连接"))
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                            Text(IOSAppLocalization.string("发送一条测试句，不含你的数据。", defaultValue: "发送一条测试句，不含你的数据。"))
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
        // 先落盘未回车的模型/固定版本输入：测试必须打在用户刚填的值上，
        // 也避免结束时的 refreshDynamicState 覆盖未提交文本。
        commitVercelModel()
        commitPinnedModel()
        let startedRevision = sharedSettings.jevSettings.revision
        guard let apiKey = IOSCredentialSideTable.load(key: IOSCredentialSideTable.jevApiKey), !apiKey.isEmpty else {
            connectionResult = ConnectionTestPresentation(
                succeeded: false,
                text: IOSAppLocalization.string("未配置 API Key。", defaultValue: "未配置 API Key。")
            )
            return
        }
        guard sharedSettings.jevSettings.revision == startedRevision else { return }
        isTestingConnection = true
        connectionResult = nil
        Task {
            let result = await IOSJevDecisionCoordinator.shared.runConnectionTest(apiKey: apiKey)
            guard sharedSettings.jevSettings.revision == startedRevision else {
                await MainActor.run {
                    isTestingConnection = false
                    connectionResult = ConnectionTestPresentation(
                        succeeded: false,
                        text: IOSAppLocalization.string("设置或 Key 已变化，请重新测试连接。", defaultValue: "设置或 Key 已变化，请重新测试连接。")
                    )
                    refreshDynamicState()
                }
                return
            }
            let presentation: ConnectionTestPresentation
            if result.succeeded, let model = result.modelVersion {
                var text = IOSAppLocalization.formatted(
                    "连接成功：%@（%d ms）",
                    defaultValue: "连接成功：%@（%d ms）",
                    arguments: [model, result.latencyMs]
                )
                if let input = result.inputTokens, let output = result.outputTokens {
                    text += IOSAppLocalization.formatted(
                        "，%d+%d tokens",
                        defaultValue: "，%d+%d tokens",
                        arguments: [input, output]
                    )
                }
                // systemone：验收通过即把服务端报告的版本落为固定版本（active 前提）；
                // 浮动别名不验收，提示用户手动填具体版本。
                var settings = sharedSettings.jevSettings
                let previousPin = settings.pinnedModelVersion
                settings.acceptVerifiedModelVersion(result.modelVersion)
                if settings.pinnedModelVersion != previousPin {
                    sharedSettings.updateJevSettings(settings)
                    pinnedModelInput = settings.pinnedModelVersion ?? ""
                    text += IOSAppLocalization.string("，已固定为验收版本", defaultValue: "，已固定为验收版本")
                } else if sharedSettings.jevSettings.apiStyle == .systemone,
                          settings.pinnedModelVersion == nil {
                    text += IOSAppLocalization.string("，未提供固定版本（仍按 shadow 观测，可手动输入具体版本名）", defaultValue: "，未提供固定版本（仍按 shadow 观测，可手动输入具体版本名）")
                }
                presentation = ConnectionTestPresentation(succeeded: true, text: text + "。")
            } else {
                let reason = result.errorReason ?? "unknown"
                let hint: String
                if reason == "config_changed" {
                    hint = IOSAppLocalization.string("设置或 Key 已变化，请重新测试。", defaultValue: "设置或 Key 已变化，请重新测试。")
                } else if reason == "http_401" || reason == "http_403" || reason == "missing_key" {
                    hint = IOSAppLocalization.string("请检查 Key。", defaultValue: "请检查 Key。")
                } else if reason == "invalid_request" || reason == "http_400" {
                    hint = sharedSettings.jevSettings.apiStyle == .vercelGateway
                        ? IOSAppLocalization.string("请检查模型 slug。", defaultValue: "请检查模型 slug。")
                        : IOSAppLocalization.string("请检查固定模型版本或服务端配置。", defaultValue: "请检查固定模型版本或服务端配置。")
                } else {
                    hint = ""
                }
                var failureText = IOSAppLocalization.formatted(
                    "连接失败：%@。",
                    defaultValue: "连接失败：%@。",
                    arguments: [reason]
                )
                failureText += hint
                presentation = ConnectionTestPresentation(succeeded: false, text: failureText)
            }
            await MainActor.run {
                isTestingConnection = false
                connectionResult = presentation
                refreshDynamicState()
            }
        }
    }

    // MARK: Per-use-case modes & scopes

    private var recommendedConfigurationSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "推荐配置")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text(IOSAppLocalization.string(
                        "先用 Shadow 观测五个用途，再根据对比结果逐项决定是否启用。",
                        defaultValue: "先用 Shadow 观测五个用途，再根据对比结果逐项决定是否启用。"
                    ))
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)

                    Button {
                        showingRecommendedConfigurationConfirmation = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text(IOSAppLocalization.string("设置推荐配置", defaultValue: "设置推荐配置"))
                                .fontWeight(.semibold)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AmberTheme.muted2)
                        }
                        .foregroundStyle(AmberTheme.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
                    .accessibilityHint("确认后会发送各用途允许的数据供 Shadow 观测。")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            Text(IOSAppLocalization.string(
                "只观测、不应用判断；网页操作与审批分诊保持原设置。",
                defaultValue: "只观测、不应用判断；网页操作与审批分诊保持原设置。"
            ))
            .font(.caption)
            .foregroundStyle(AmberTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.top, 8)
        }
        .confirmationDialog(
            IOSAppLocalization.string("开启推荐配置？", defaultValue: "开启推荐配置？"),
            isPresented: $showingRecommendedConfigurationConfirmation,
            titleVisibility: .visible
        ) {
            Button(IOSAppLocalization.string("确认并开启 Shadow 观测", defaultValue: "确认并开启 Shadow 观测")) {
                applyRecommendedConfiguration()
            }
            Button(IOSAppLocalization.string("取消", defaultValue: "取消"), role: .cancel) {}
        } message: {
            Text(IOSAppLocalization.string(
                "工具发现、记忆召回、上下文筛选、模型调度和意图路由将设为 Shadow，并使用各自默认数据范围。当前任务文本、工具目录信息、候选模型与服务商信息、个人记忆内容或工具输出会按用途发送给 Jev；结果只观测、不应用。网页操作和审批分诊不变。",
                defaultValue: "工具发现、记忆召回、上下文筛选、模型调度和意图路由将设为 Shadow，并使用各自默认数据范围。当前任务文本、工具目录信息、候选模型与服务商信息、个人记忆内容或工具输出会按用途发送给 Jev；结果只观测、不应用。网页操作和审批分诊不变。"
            ))
        }
    }

    private func applyRecommendedConfiguration() {
        var settings = sharedSettings.jevSettings
        settings.applyRecommendedConfiguration()
        sharedSettings.updateJevSettings(settings)
    }

    private var useCaseSection: some View {
        VStack(spacing: 0) {
            DisclosureGroup(isExpanded: $isAdvancedSettingsExpanded) {
                VStack(spacing: 0) {
                    AmberSectionLabel(text: "用途与范围")
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
                    Text(IOSAppLocalization.string("Shadow 只观测不应用；关闭即零网络。", defaultValue: "Shadow 只观测不应用；关闭即零网络。"))
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 30)
                        .padding(.top, 8)
                }
            } label: {
                HStack {
                    Text(IOSAppLocalization.string("高级设置", defaultValue: "高级设置"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Spacer()
                    Text(IOSAppLocalization.string("逐用途模式与数据范围", defaultValue: "逐用途模式与数据范围"))
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                }
                .contentShape(Rectangle())
            }
            .tint(AmberTheme.accent)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
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
                    case .modelRouting: "arrow.triangle.branch"
                    case .webActions: "globe"
                    case .subagentIntent: "signpost.and.arrowtriangle.up"
                    case .approvalTriage: "checklist"
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
                Text(IOSAppLocalization.string("需固定模型版本才会真启用，当前按 Shadow 运行。", defaultValue: "需固定模型版本才会真启用，当前按 Shadow 运行。"))
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
            AmberSectionLabel(text: "用量与状态")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 6) {
                    if let summary = metricsSummary {
                        Text(IOSAppLocalization.string("今日 \(summary.todayRequests) 次（\(formatBytes(summary.todayRequestBytes))）", defaultValue: "今日 \(summary.todayRequests) 次（\(formatBytes(summary.todayRequestBytes))）"))
                        Text(IOSAppLocalization.string("近 24 小时：应用 \(summary.last24hApplied)，回退 \(summary.last24hFallback)", defaultValue: "近 24 小时：应用 \(summary.last24hApplied)，回退 \(summary.last24hFallback)"))
                    } else {
                        Text(IOSAppLocalization.string("暂无记录", defaultValue: "暂无记录"))
                    }
                    statusLine
                    useCaseMetricsSection
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
                    useCaseMetricsSummaries = IOSJevMetricsStore.useCaseSummaries()
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
            Text(IOSAppLocalization.string("不含原文，保留 7 天。", defaultValue: "不含原文，保留 7 天。"))
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 8)
        }
    }

    private var useCaseMetricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(IOSAppLocalization.string("Shadow 对比（近 7 天）", defaultValue: "Shadow 对比（近 7 天）"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
                .padding(.top, 4)

            ForEach(useCaseMetricsSummaries, id: \.useCase) { summary in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(IOSAppLocalization.string(summary.useCase.displayName, defaultValue: summary.useCase.displayName))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                        Spacer(minLength: 8)
                        Text(IOSAppLocalization.formatted("%d 条", defaultValue: "%d 条", arguments: [summary.total]))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AmberTheme.muted)
                    }
                    metricLine("差异率", value: summary.differenceRate.map(formatRate))
                    metricLine("等待 p50", value: summary.waitP50Ms.map(formatMilliseconds))
                    metricLine("等待 p95", value: summary.waitP95Ms.map(formatMilliseconds))
                    if summary.useCase == .webActions {
                        metricLine("目标完成率", value: summary.completionRate.map(formatRate))
                    }
                    fallbackReasonsLine(summary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 5)

                if summary.useCase != useCaseMetricsSummaries.last?.useCase {
                    Divider()
                        .overlay(AmberTheme.borderSoft)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
    }

    private func metricLine(_ label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(IOSAppLocalization.string(label, defaultValue: label))
                .foregroundStyle(AmberTheme.muted)
            Spacer(minLength: 8)
            Text(value ?? IOSAppLocalization.string("暂无数据", defaultValue: "暂无数据"))
                .foregroundStyle(AmberTheme.muted)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func fallbackReasonsLine(_ summary: IOSJevMetricsStore.UseCaseSummary) -> some View {
        if summary.fallbackReasons.isEmpty {
            metricLine(
                "回退原因",
                value: summary.total == 0
                    ? IOSAppLocalization.string("暂无数据", defaultValue: "暂无数据")
                    : IOSAppLocalization.string("无回退记录", defaultValue: "无回退记录")
            )
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(IOSAppLocalization.string("回退原因", defaultValue: "回退原因"))
                    .foregroundStyle(AmberTheme.muted)
                ForEach(sortedFallbackReasons(summary), id: \.key) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.key)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text("×\(entry.value)")
                            .monospacedDigit()
                    }
                    .foregroundStyle(AmberTheme.muted)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sortedFallbackReasons(_ summary: IOSJevMetricsStore.UseCaseSummary) -> [(key: String, value: Int)] {
        summary.fallbackReasons.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        let status = IOSJevDecisionCoordinator.shared.status
        if status.pausedForAuth {
            Text(IOSAppLocalization.string("已暂停：认证失败。换新 Key 或测试成功后恢复。", defaultValue: "已暂停：认证失败。换新 Key 或测试成功后恢复。"))
                .foregroundStyle(AmberTheme.accentRed)
        } else if let cooldown = status.cooldownRemaining, cooldown > 0 {
            Text(IOSAppLocalization.string("冷却中：约 \(Int(cooldown)) 秒后恢复。", defaultValue: "冷却中：约 \(Int(cooldown)) 秒后恢复。"))
                .foregroundStyle(AmberTheme.accentAmber)
        } else {
            Text(IOSAppLocalization.string("正常", defaultValue: "正常"))
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        bytes < 1_024 ? "\(bytes) B" : String(format: "%.1f KiB", Double(bytes) / 1_024)
    }

    private func formatRate(_ rate: Double) -> String {
        String(format: "%.1f%%", rate * 100)
    }

    private func formatMilliseconds(_ milliseconds: Int) -> String {
        "\(milliseconds) ms"
    }
}
