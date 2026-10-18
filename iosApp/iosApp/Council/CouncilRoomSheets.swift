import SwiftUI
@preconcurrency import Shared

struct CouncilDiscussionDetailSheet: View {
    let detail: CouncilDiscussionDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(IOSAppLocalization.string("议会详情", defaultValue: "议会详情"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(detail.statusLine)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                }

                CouncilDetailGroup(
                    title: IOSAppLocalization.string("目标", defaultValue: "目标"),
                    bodyText: detail.objective
                )
                CouncilDetailGroup(
                    title: IOSAppLocalization.string("席位", defaultValue: "席位"),
                    bodyText: detail.participantSummary
                )
                CouncilDetailGroup(
                    title: IOSAppLocalization.string("运行", defaultValue: "运行"),
                    bodyText: detail.budgetSummary
                )
                CouncilDetailGroup(
                    title: IOSAppLocalization.string("记录", defaultValue: "记录"),
                    bodyText: detail.transcript
                )
            }
            .padding(20)
        }
        .background(AmberTheme.background)
    }
}

private struct CouncilDetailGroup: View {
    let title: String
    let bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted)
            Text(bodyText.isEmpty
                 ? IOSAppLocalization.string("暂无", defaultValue: "暂无")
                 : bodyText)
                .font(.footnote)
                .foregroundStyle(AmberTheme.foreground2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
    }
}

enum CouncilMembersCopy {
    static func seatSectionFooter(isRunning: Bool, dynamicSeatGeneration: Bool) -> String {
        if isRunning {
            return IOSAppLocalization.string(
                "本轮议会运行中，模式与席位下一轮生效。",
                defaultValue: "本轮议会运行中，模式与席位下一轮生效。"
            )
        }
        if dynamicSeatGeneration {
            return IOSAppLocalization.string(
                "席位由主持人按议题联网调研后动态组建。",
                defaultValue: "席位由主持人按议题联网调研后动态组建。"
            )
        }
        return IOSAppLocalization.string(
            "席位来自设置中已添加的固定角色。",
            defaultValue: "席位来自设置中已添加的固定角色。"
        )
    }
}

struct CouncilMembersSheet: View {
    @Binding var selectedMode: CouncilDiscussionMode
    let participants: [CouncilParticipant]
    let currentModelId: String
    let stateProvider: (CouncilParticipant) -> CouncilParticipantState
    let failedSpeakerIds: Set<String>
    let isRunning: Bool
    let dynamicSeatGeneration: Bool
    let restartAction: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(
                        IOSAppLocalization.string("讨论模式", defaultValue: "讨论模式"),
                        selection: $selectedMode
                    ) {
                        ForEach(CouncilDiscussionMode.allCases) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isRunning)
                    .listRowBackground(AmberTheme.surface)
                } header: {
                    Text(IOSAppLocalization.string("模式", defaultValue: "模式"))
                } footer: {
                    Text(selectedMode.localizedIntent)
                }

                Section {
                    ForEach(participants) { participant in
                        HStack(spacing: 12) {
                            Image(systemName: participant.systemImage)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(participant.tint)
                                .frame(width: 32, height: 32)
                                .background(participant.tint.opacity(0.13), in: Circle())

                            VStack(alignment: .leading, spacing: 3) {
                                Text(participant.displayNameForDisplay)
                                    .font(.body.weight(.semibold))
                                Text(participant.isHost
                                     ? IOSAppLocalization.formatted(
                                         "主持 · %@",
                                         defaultValue: "主持 · %@",
                                         arguments: [currentModelId]
                                     )
                                     : IOSAppLocalization.string(
                                         participant.roleDescription,
                                         defaultValue: participant.roleDescription
                                     ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(failedSpeakerIds.contains(participant.id)
                                 ? IOSAppLocalization.string("失败", defaultValue: "失败")
                                 : stateProvider(participant).localizedLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(failedSpeakerIds.contains(participant.id) ? Color.red : .secondary)
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(AmberTheme.surface)
                    }
                } header: {
                    Text(IOSAppLocalization.formatted(
                        "席位成员（%lld）",
                        defaultValue: "席位成员（%lld）",
                        arguments: [Int64(participants.count)]
                    ))
                } footer: {
                    Text(CouncilMembersCopy.seatSectionFooter(
                        isRunning: isRunning,
                        dynamicSeatGeneration: dynamicSeatGeneration
                    ))
                }
            }
            // 隐藏系统 grouped 背景(那层会随 sheet 拉伸在冷灰之间切换,与暖色主题冲突),
            // 统一用主题底色,颜色不再随高度变化。
            .scrollContentBackground(.hidden)
            .background(AmberTheme.background)
            .navigationTitle(IOSAppLocalization.string("模型议会", defaultValue: "模型议会"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(IOSAppLocalization.string("完成", defaultValue: "完成")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // 纯文字「重开」:清空当前议会、回到空白开场(即便正在运行也先停掉再清),
                    // 不再用刷新图标,也不再是「重跑上一题」(那个会因 lastRunObjective 为空而点了没反应)。
                    Button(
                        IOSAppLocalization.string("重开", defaultValue: "重开"),
                        role: .destructive
                    ) {
                        restartAction()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct CouncilRoomSettingsSheet: View {
    @Bindable var roomSettingsStore: IOSCouncilRoomSettingsStore
    let sharedSettings: IOSSharedSettingsStore
    let availableModelIds: [String]
    let currentModelId: String
    let isReadOnly: Bool

    @State private var connectivityState: CouncilModelConnectivityViewState = .idle
    @State private var connectivityTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(IOSAppLocalization.string("议会设置", defaultValue: "议会设置"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(IOSAppLocalization.string(
                        isReadOnly ? "运行中只读，下一轮生效。" : "设置会保存到本机，下一轮议会使用。",
                        defaultValue: isReadOnly ? "运行中只读，下一轮生效。" : "设置会保存到本机，下一轮议会使用。"
                    ))
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                }

                settingsGroup(
                    title: IOSAppLocalization.string("模型连通性", defaultValue: "模型连通性")
                ) {
                    Button(action: testCurrentCouncilModels) {
                        HStack(spacing: 10) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AmberTheme.accent)
                                .frame(width: 28)
                            Text(IOSAppLocalization.string(
                                connectivityState.isTesting ? "正在测试当前议会模型" : "测试当前议会模型",
                                defaultValue: connectivityState.isTesting ? "正在测试当前议会模型" : "测试当前议会模型"
                            ))
                                .font(.body.weight(.medium))
                                .foregroundStyle(AmberTheme.foreground)
                            Spacer(minLength: 8)
                            Text(connectivityState.summary)
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(connectivityState.isTesting)

                    switch connectivityState {
                    case .idle, .testing:
                        EmptyView()
                    case .failure(let message):
                        Divider().overlay(AmberTheme.borderSoft)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.accentRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    case .results(let results):
                        ForEach(results) { result in
                            Divider().overlay(AmberTheme.borderSoft)
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: result.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.isReachable ? Color.green : AmberTheme.accentRed)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.configuredModelId)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(AmberTheme.foreground)
                                    Text(result.detail)
                                        .font(.caption)
                                        .foregroundStyle(result.isReachable ? AmberTheme.muted : AmberTheme.accentRed)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                }

                settingsGroup(
                    title: IOSAppLocalization.string("主持人", defaultValue: "主持人")
                ) {
                    modelMenu(
                        title: IOSAppLocalization.string("主持模型", defaultValue: "主持模型"),
                        value: roomSettingsStore.settings.host.modelId,
                        setValue: { roomSettingsStore.updateHost(modelId: $0) }
                    )
                    Divider().overlay(AmberTheme.borderSoft)
                    reasoningMenu(
                        title: IOSAppLocalization.string("思考档位", defaultValue: "思考档位"),
                        value: roomSettingsStore.settings.host.reasoning,
                        setValue: { roomSettingsStore.updateHost(reasoning: $0) }
                    )
                    Divider().overlay(AmberTheme.borderSoft)
                    TextField(IOSAppLocalization.string("主持人提示词", defaultValue: "主持人提示词"), text: Binding(
                        get: { roomSettingsStore.settings.host.prompt },
                        set: { roomSettingsStore.updateHost(prompt: $0) }
                    ), axis: .vertical)
                    .lineLimit(2...5)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.foreground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .disabled(isReadOnly)
                }

                settingsGroup(
                    title: IOSAppLocalization.string("动态席位生成", defaultValue: "动态席位生成")
                ) {
                    Toggle(isOn: Binding(
                        get: { roomSettingsStore.dynamicSeatGeneration },
                        set: { roomSettingsStore.dynamicSeatGeneration = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(IOSAppLocalization.string("主持人动态生成席位", defaultValue: "主持人动态生成席位"))
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                            Text(IOSAppLocalization.string(
                                roomSettingsStore.dynamicSeatGeneration
                                    ? "开：主持人按议题联网调研后自由组建席位。"
                                    : "关：只在下方你添加的席位中选择角色。",
                                defaultValue: roomSettingsStore.dynamicSeatGeneration
                                    ? "开：主持人按议题联网调研后自由组建席位。"
                                    : "关：只在下方你添加的席位中选择角色。"
                            ))
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(AmberTheme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .disabled(isReadOnly)
                }

                settingsGroup(
                    title: IOSAppLocalization.string("席位联网查证", defaultValue: "席位联网查证")
                ) {
                    Toggle(isOn: Binding(
                        get: { roomSettingsStore.seatWebSearch },
                        set: { roomSettingsStore.seatWebSearch = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(IOSAppLocalization.string("允许席位联网搜索", defaultValue: "允许席位联网搜索"))
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                            Text(IOSAppLocalization.string(
                                roomSettingsStore.seatWebSearch
                                    ? "开：每位议员发言前先联网查证一轮，更慢更耗；需同时开启全局联网搜索。"
                                    : "关：议员纯推理发言（推荐，速度更快）。",
                                defaultValue: roomSettingsStore.seatWebSearch
                                    ? "开：每位议员发言前先联网查证一轮，更慢更耗；需同时开启全局联网搜索。"
                                    : "关：议员纯推理发言（推荐，速度更快）。"
                            ))
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(AmberTheme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .disabled(isReadOnly)
                }

                settingsGroup(title: IOSAppLocalization.formatted(
                    "席位（%lld）",
                    defaultValue: "席位（%lld）",
                    arguments: [Int64(roomSettingsStore.settings.seats.count)]
                )) {
                    if roomSettingsStore.settings.seats.isEmpty {
                        Text(IOSAppLocalization.string(
                            roomSettingsStore.dynamicSeatGeneration
                                ? "未添加固定席位。动态生成开启时由主持人按议题组建。"
                                : "还没有添加席位。点下方「添加席位」从预制角色中选择。",
                            defaultValue: roomSettingsStore.dynamicSeatGeneration
                                ? "未添加固定席位。动态生成开启时由主持人按议题组建。"
                                : "还没有添加席位。点下方「添加席位」从预制角色中选择。"
                        ))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(roomSettingsStore.settings.seats) { seat in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(IOSAppLocalization.string(seat.name, defaultValue: seat.name))
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(AmberTheme.foreground)
                                    Text(IOSAppLocalization.string(seat.rolePrompt, defaultValue: seat.rolePrompt))
                                        .font(.caption)
                                        .foregroundStyle(AmberTheme.muted)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    roomSettingsStore.removeSeat(id: seat.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(AmberTheme.accentRed)
                                }
                                .buttonStyle(.plain)
                                .disabled(isReadOnly)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            Divider().overlay(AmberTheme.borderSoft)
                        }
                    }

                    Menu {
                        if availablePresets.isEmpty {
                            Text(IOSAppLocalization.string("预制角色已全部添加", defaultValue: "预制角色已全部添加"))
                        } else {
                            ForEach(availablePresets) { preset in
                                Button {
                                    roomSettingsStore.addOrUpdateSeat(preset.asSeat(), currentModelId: currentModelId)
                                } label: {
                                    Text("\(IOSAppLocalization.string(preset.name, defaultValue: preset.name)) · \(IOSAppLocalization.string(preset.rolePrompt, defaultValue: preset.rolePrompt))")
                                }
                            }
                        }
                    } label: {
                        Label(
                            IOSAppLocalization.string("添加席位", defaultValue: "添加席位"),
                            systemImage: "plus.circle.fill"
                        )
                            .font(.body.weight(.medium))
                            .foregroundStyle(AmberTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                    .disabled(isReadOnly)
                }

                settingsGroup(
                    title: IOSAppLocalization.string("功能限制", defaultValue: "功能限制")
                ) {
                    Stepper(
                        IOSAppLocalization.formatted(
                            "最大席位 %lld",
                            defaultValue: "最大席位 %lld",
                            arguments: [Int64(roomSettingsStore.settings.limits.maxSeats)]
                        ),
                        value: Binding(
                            get: { roomSettingsStore.settings.limits.maxSeats },
                            set: { roomSettingsStore.updateLimits(maxSeats: $0) }
                        ),
                        in: 2...8
                    )
                    .disabled(isReadOnly)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Divider().overlay(AmberTheme.borderSoft)

                    Stepper(
                        IOSAppLocalization.formatted(
                            "默认轮数 %lld",
                            defaultValue: "默认轮数 %lld",
                            arguments: [Int64(roomSettingsStore.settings.limits.defaultRounds)]
                        ),
                        value: Binding(
                            get: { roomSettingsStore.settings.limits.defaultRounds },
                            set: { roomSettingsStore.updateLimits(defaultRounds: $0) }
                        ),
                        in: 1...5
                    )
                    .disabled(isReadOnly)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Divider().overlay(AmberTheme.borderSoft)

                    Stepper(
                        IOSAppLocalization.formatted(
                            "单次模型无输出超时 %llds",
                            defaultValue: "单次模型无输出超时 %llds",
                            arguments: [Int64(roomSettingsStore.settings.limits.seatTimeoutSeconds)]
                        ),
                        value: Binding(
                            get: { roomSettingsStore.settings.limits.seatTimeoutSeconds },
                            set: { roomSettingsStore.updateLimits(seatTimeoutSeconds: $0) }
                        ),
                        in: 15...180,
                        step: 15
                    )
                    .disabled(isReadOnly)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Divider().overlay(AmberTheme.borderSoft)

                    Stepper(
                        IOSAppLocalization.formatted(
                            "输出预算 %lld",
                            defaultValue: "输出预算 %lld",
                            arguments: [Int64(roomSettingsStore.settings.limits.outputBudgetCharacters)]
                        ),
                        value: Binding(
                            get: { roomSettingsStore.settings.limits.outputBudgetCharacters },
                            set: { roomSettingsStore.updateLimits(outputBudgetCharacters: $0) }
                        ),
                        in: 2_000...40_000,
                        step: 2_000
                    )
                    .disabled(isReadOnly)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .padding(20)
        }
        .background(AmberTheme.background)
        .onDisappear {
            connectivityTask?.cancel()
            connectivityTask = nil
        }
    }

    @ViewBuilder
    /// 预制角色里尚未添加的部分(按 id 和名称去重),供「添加席位」菜单展示。
    private var availablePresets: [IOSCouncilSeatPreset] {
        let addedIds = Set(roomSettingsStore.settings.seats.map(\.id))
        let addedNames = Set(roomSettingsStore.settings.seats.map { $0.name.lowercased() })
        return IOSCouncilSeatPreset.all.filter {
            !addedIds.contains($0.id) && !addedNames.contains($0.name.lowercased())
        }
    }

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted)
            VStack(spacing: 0) {
                content()
            }
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous))
        }
    }

    private func modelMenu(title: String, value: String, setValue: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(availableModelIds, id: \.self) { modelId in
                Button(modelId) { setValue(modelId) }
            }
        } label: {
            settingsRow(
                title: title,
                value: value.trimmedOr(currentModelId),
                systemImage: "cpu"
            )
        }
        .buttonStyle(.plain)
        .disabled(isReadOnly || availableModelIds.isEmpty)
    }

    private func reasoningMenu(title: String, value: IOSCouncilReasoningPreset, setValue: @escaping (IOSCouncilReasoningPreset) -> Void) -> some View {
        Menu {
            ForEach(IOSCouncilReasoningPreset.allCases) { option in
                Button(IOSAppLocalization.string(option.title, defaultValue: option.title)) { setValue(option) }
            }
        } label: {
            settingsRow(
                title: title,
                value: IOSAppLocalization.string(value.title, defaultValue: value.title),
                systemImage: "brain.head.profile"
            )
        }
        .buttonStyle(.plain)
        .disabled(isReadOnly)
    }

    private func settingsRow(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AmberTheme.accent)
                .frame(width: 30, height: 30)
            Text(title)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted2)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private func testCurrentCouncilModels() {
        connectivityTask?.cancel()
        guard let provider = sharedSettings.resolveCurrentProviderSetting() else {
            connectivityState = .failure(IOSAppLocalization.string(
                "当前没有可用的聊天服务商或模型。",
                defaultValue: "当前没有可用的聊天服务商或模型。"
            ))
            return
        }
        let settings = roomSettingsStore.settings
        let dynamicSeatGeneration = roomSettingsStore.dynamicSeatGeneration
        let modelId = currentModelId
        connectivityState = .testing
        connectivityTask = Task { @MainActor in
            let tester = IOSCouncilModelConnectivityTester()
            do {
                let results = try await tester.test(
                    settings: settings,
                    dynamicSeatGeneration: dynamicSeatGeneration,
                    providerSetting: provider,
                    currentModelId: modelId
                )
                guard !Task.isCancelled else { return }
                connectivityState = .results(results)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                connectivityState = .failure(error.localizedDescription)
            }
            connectivityTask = nil
        }
    }
}


// MARK: - 历史议会 sheet

/// 列出可重开的历史议会(仅含已归档快照的任务),点任意一场以只读方式重开。
struct CouncilHistorySheet: View {
    let tasks: [IOSAdvancedTaskRecord]
    let activeTaskId: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AmberTheme.background.ignoresSafeArea()
                if tasks.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        AmberFormGroup {
                            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                                Button {
                                    onSelect(task.id)
                                    dismiss()
                                } label: {
                                    row(task)
                                }
                                .buttonStyle(.plain)
                                if index < tasks.count - 1 {
                                    Divider()
                                        .overlay(AmberTheme.borderSoft)
                                        .padding(.leading, 14)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle(IOSAppLocalization.string("历史议会", defaultValue: "历史议会"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IOSAppLocalization.string("完成", defaultValue: "完成")) { dismiss() }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(AmberTheme.muted2)
            Text(IOSAppLocalization.string("暂无可重开的历史议会", defaultValue: "暂无可重开的历史议会"))
                .font(.subheadline)
                .foregroundStyle(AmberTheme.muted)
            Text(IOSAppLocalization.string(
                "完成一场议会后，这里会列出可重开的讨论。",
                defaultValue: "完成一场议会后，这里会列出可重开的讨论。"
            ))
                .font(.caption)
                .foregroundStyle(AmberTheme.muted2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    private func row(_ task: IOSAdvancedTaskRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: task.status))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconColor(for: task.status))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                Text("\(CouncilDisplayCopy.localized(task.status.title)) · \(task.objective)")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if task.id == activeTaskId {
                Image(systemName: "eye.fill")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accent)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted2)
            }
        }
        .frame(minHeight: 56)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func icon(for status: IOSAdvancedTaskStatus) -> String {
        switch status {
        case .completed: "checkmark.seal.fill"
        case .failed, .timedOut, .interrupted: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        default: "bubble.left.and.bubble.right.fill"
        }
    }

    private func iconColor(for status: IOSAdvancedTaskStatus) -> Color {
        switch status {
        case .completed: AmberTheme.accentGreen
        case .failed, .timedOut, .interrupted: AmberTheme.accentRed
        case .cancelled: AmberTheme.muted2
        default: AmberTheme.accent
        }
    }
}

private extension String {
    func trimmedOr(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

