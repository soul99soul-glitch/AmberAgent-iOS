import SwiftUI
@preconcurrency import UserNotifications

/// iPhone companion settings for the Amber Watch surface.
///
/// The page owns only Watch-specific choices. Provider credentials and the
/// active assistant remain in the existing model settings, while note text is
/// owned by IOSWatchCompanionService.
@MainActor
struct IOSWatchSettingsView: View {
    let sharedSettings: IOSSharedSettingsStore
    let conversationStore: IOSConversationStore
    @Bindable var service: IOSWatchCompanionService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(IOSAppleIntegrationPreferenceKeys.completionNotificationsEnabled)
    private var completionNotificationsEnabled = false
    @State private var notificationAuthorization: IOSLocalNotificationAuthorization = .notDetermined
    @State private var notificationMessage: String?
    @State private var isRequestingNotifications = false
    @State private var isRefreshing = false
    @State private var notificationRequestRevision = 0
    @State private var selectedNote: WatchNote?
    @State private var showsNotes = false
    @State private var showsConfigurationIssue = false
    @State private var noteToDelete: WatchNote?
    @State private var noteError: String?
    @State private var connectionRefreshTask: Task<Void, Never>?
    @State private var connectionRevision = 0
    @State private var showsQuickActionEditor = false
    @State private var editingActionID: String?
    @State private var actionTitle = ""
    @State private var actionPrompt = ""
    @State private var actionError = false
    @State private var confirmsActionDeletion = false

    init(
        sharedSettings: IOSSharedSettingsStore,
        conversationStore: IOSConversationStore,
        service: IOSWatchCompanionService = .shared,
        initiallyShowsNotes: Bool = false
    ) {
        self.sharedSettings = sharedSettings
        self.conversationStore = conversationStore
        self._service = Bindable(service)
        self._showsNotes = State(initialValue: initiallyShowsNotes)
    }

    private var availableQuickActions: [WatchQuickAction] {
        let settings = sharedSettings.snapshot
        return settings.quickMessages.compactMap { message in
            let id = message.id.toHexDashString()
            let title = message.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !title.isEmpty, WatchQuickAction.supports(prompt: prompt) else { return nil }
            return WatchQuickAction(id: id, title: title, prompt: prompt)
        }
    }

    private var selectedAssistantName: String {
        let name = sharedSettings.snapshot.getCurrentAssistant().name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Amber" : name
    }

    private var configurationIssue: ChatConfigurationIssue? {
        guard let model = sharedSettings.snapshot.getCurrentChatModel() else {
            return .missingModel
        }
        return ChatProviderConfiguration.issue(
            for: model,
            provider: sharedSettings.resolveCurrentProviderSetting()
        )
    }

    private var watchIsAvailable: Bool {
        _ = connectionRevision
        return WatchConnectivityBridge.shared.isCompanionReachable
    }

    private func isQuickActionSelected(_ action: WatchQuickAction) -> Bool {
        if service.hasConfiguredQuickActionSelection {
            return service.selectedQuickActionIDs.contains {
                $0.caseInsensitiveCompare(action.id) == .orderedSame
            }
        }
        return availableQuickActions.prefix(IOSWatchCompanionService.maxQuickActions).contains {
            $0.id.caseInsensitiveCompare(action.id) == .orderedSame
        }
    }

    private func setQuickAction(_ action: WatchQuickAction, enabled: Bool) {
        let availableIDs = Set(availableQuickActions.map { $0.id.lowercased() })
        var ids = service.hasConfiguredQuickActionSelection
            ? service.selectedQuickActionIDs.filter { availableIDs.contains($0.lowercased()) }
            : Array(availableQuickActions.prefix(IOSWatchCompanionService.maxQuickActions).map(\.id))
        ids.removeAll { $0.caseInsensitiveCompare(action.id) == .orderedSame }
        if enabled { ids.append(action.id) }
        service.setSelectedQuickActionIDs(ids)
        Task { @MainActor in
            await WatchTaskCoordinator.shared.refreshWatchSnapshot()
        }
    }

    private var selectedQuickActionCount: Int {
        availableQuickActions.filter { isQuickActionSelected($0) }.count
    }

    var body: some View {
        let _ = sharedSettings.revision
        ZStack {
            AmberTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        deviceSection
                        quickActionsSection
                        captureSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .tint(AmberTheme.accent)
        .task {
            await refreshNotificationAuthorization()
            connectionRefreshTask?.cancel()
            connectionRefreshTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    if !Task.isCancelled { connectionRevision &+= 1 }
                }
            }
        }
        .onDisappear {
            connectionRefreshTask?.cancel()
            connectionRefreshTask = nil
        }
        .onChange(of: completionNotificationsEnabled) { _, enabled in
            notificationRequestRevision &+= 1
            let revision = notificationRequestRevision
            Task { @MainActor in
                guard enabled else {
                    await IOSLocalNotificationService.shared.cancelTaskCompletionNotifications()
                    return
                }
                guard notificationRequestRevision == revision else { return }
                requestNotificationsIfNeeded(revision: revision)
            }
        }
        .alert("当前助手", isPresented: $showsConfigurationIssue) {
            Button("好", role: .cancel) {}
        } message: {
            Text(configurationIssue?.message ?? "")
        }
        .sheet(item: $selectedNote) { note in
            noteDetail(note)
        }
        .sheet(isPresented: $showsQuickActionEditor) { quickActionEditor }
        .confirmationDialog(
            "删除这条记事？",
            isPresented: Binding(
                get: { noteToDelete != nil },
                set: { if !$0 { noteToDelete = nil } }
            ),
            presenting: noteToDelete
        ) { note in
            Button("删除", role: .destructive) {
                deleteNote(note)
            }
            Button("取消", role: .cancel) { noteToDelete = nil }
        } message: { _ in
            Text("删除后无法从 Amber Watch 设置中恢复。")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }
            Spacer(minLength: 0)
            Text("Apple Watch")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Color.clear
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var deviceSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "设备与助手")
            AmberFormGroup {
                settingsRow(icon: "applewatch", title: "连接状态",
                    detail: watchIsAvailable ? "Apple Watch 已连接" : "Apple Watch 暂不可达") {
                    Button { refreshConnection() } label: {
                        Image(systemName: isRefreshing ? "hourglass" : "arrow.clockwise")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AmberTheme.accent)
                    .disabled(isRefreshing)
                    .accessibilityLabel("刷新 Apple Watch 状态")
                }
                rowDivider
                settingsRow(icon: "sparkles", title: selectedAssistantName, detail: "当前助手",
                    action: configurationIssue == nil ? nil : { showsConfigurationIssue = true }) {
                    Text(LocalizedStringKey(configurationIssue == nil ? "已配置" : "未配置"))
                        .font(.caption)
                        .foregroundStyle(configurationIssue == nil ? AmberTheme.muted : .orange)
                }
            }
        }
    }

    private func refreshConnection() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            await WatchTaskCoordinator.shared.refreshWatchSnapshot()
            connectionRevision &+= 1
            isRefreshing = false
        }
    }

    private var quickActionsSection: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AmberSectionLabel(text: "快捷动作")
                Text("\(selectedQuickActionCount)/4")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AmberTheme.muted)
                    .padding(.trailing, 16)
                    .padding(.top, 20).padding(.bottom, 7)
            }
            AmberFormGroup {
                AmberFormRow(systemImage: "plus", iconUsesAccentPlate: true,
                    title: "添加快捷动作", showsChevron: true) { editQuickAction(nil) }
                ForEach(availableQuickActions) { action in
                    rowDivider
                    settingsRow(icon: "bolt", title: action.title, detail: action.prompt,
                        action: { editQuickAction(action) }) {
                        Toggle("", isOn: Binding(
                            get: { isQuickActionSelected(action) },
                            set: { setQuickAction(action, enabled: $0) }
                        ))
                        .labelsHidden()
                        .tint(AmberTheme.accent)
                        .disabled(selectedQuickActionCount >= IOSWatchCompanionService.maxQuickActions && !isQuickActionSelected(action))
                        .accessibilityLabel(Text(verbatim: action.title))
                    }
                }
            }
            if availableQuickActions.isEmpty {
                sectionFooter("将常用问题放到手表，点一下即可提问。")
            }
        }
    }

    private var captureSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "记事与提醒")
            AmberFormGroup {
                settingsRow(icon: "note.text", title: "随手记",
                    detail: service.notes.isEmpty ? "暂无记事" : "从手表同步的记事",
                    action: { withAnimation { showsNotes.toggle() } }) {
                    Button { withAnimation { showsNotes.toggle() } } label: {
                        HStack(spacing: 8) {
                            if !service.notes.isEmpty {
                                Text(service.notes.count.formatted()).font(.subheadline.monospacedDigit())
                            }
                            Image(systemName: showsNotes ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AmberTheme.muted)
                    .accessibilityLabel("随手记")
                }
                if showsNotes { noteRows }
                rowDivider
                settingsRow(icon: "bell", title: "任务提醒",
                    detail: notificationAuthorization == .denied ? "通知未授权" : "完成任务或需要你回答时") {
                    if isRequestingNotifications {
                        ProgressView().frame(width: 51)
                    } else {
                        Toggle("", isOn: $completionNotificationsEnabled)
                            .labelsHidden().tint(AmberTheme.accent)
                            .accessibilityLabel("任务完成或需要回答时提醒")
                    }
                }
            }
            if let message = noteError ?? service.storageError ?? notificationMessage {
                sectionFooter(message, color: .orange)
            } else if notificationAuthorization == .denied {
                sectionFooter("通知权限已拒绝，请到系统设置 > Amber > 通知中开启。")
            }
        }
    }

    private var rowDivider: some View {
        Divider().overlay(AmberTheme.borderSoft).padding(.leading, 54)
    }

    private func settingsRow<Trailing: View>(icon: String, title: String, detail: String,
        action: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if let action {
                Button(action: action) { rowContent(icon: icon, title: title, detail: detail) }
                    .buttonStyle(.plain)
            } else {
                rowContent(icon: icon, title: title, detail: detail)
            }
            if dynamicTypeSize.isAccessibilitySize {
                HStack { Spacer(minLength: 0); trailing() }
            } else {
                trailing().fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 12 : 4)
    }

    private func rowContent(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AmberTheme.accent)
                .frame(width: 28, height: 28)
                .background(AmberTheme.accentTint, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.body).foregroundStyle(AmberTheme.foreground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(LocalizedStringKey(detail)).font(.caption).foregroundStyle(AmberTheme.muted)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func editQuickAction(_ action: WatchQuickAction?) {
        editingActionID = action?.id
        actionTitle = action?.title ?? ""
        actionPrompt = action?.prompt ?? ""
        actionError = false
        showsQuickActionEditor = true
    }

    private var quickActionEditor: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $actionTitle)
                TextField("完整问题", text: $actionPrompt, axis: .vertical)
                    .lineLimit(4...12)
                Text("名称最多 40 字，问题最多 2000 字。保存后仍需在手表确认发送。")
                    .font(.caption).foregroundStyle(.secondary)
                if actionError { Text("无法保存快捷动作，请检查内容后重试。").foregroundStyle(.orange) }
                if editingActionID != nil {
                    Button("删除", role: .destructive) { confirmsActionDeletion = true }
                }
            }
            .navigationTitle("快捷动作")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showsQuickActionEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let action = service.saveQuickAction(id: editingActionID, title: actionTitle,
                            prompt: actionPrompt, sharedSettings: sharedSettings) else { actionError = true; return }
                        if editingActionID == nil, selectedQuickActionCount < IOSWatchCompanionService.maxQuickActions {
                            setQuickAction(action, enabled: true)
                        }
                        Task { await WatchTaskCoordinator.shared.refreshWatchSnapshot() }
                        showsQuickActionEditor = false
                    }
                    .disabled(actionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || actionTitle.count > 40 || !WatchQuickAction.supports(prompt: actionPrompt))
                }
            }
            .confirmationDialog("删除快捷动作？", isPresented: $confirmsActionDeletion, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    guard let id = editingActionID,
                          service.deleteQuickAction(id: id, sharedSettings: sharedSettings) else { actionError = true; return }
                    Task { await WatchTaskCoordinator.shared.refreshWatchSnapshot() }
                    showsQuickActionEditor = false
                }
            }
        }
    }

    @ViewBuilder private var noteRows: some View {
        if service.notes.isEmpty {
            Text("手表保存的记事会显示在这里，不会自动发送给 Amber。")
                .font(.caption).foregroundStyle(AmberTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 54).padding(.trailing, 14).padding(.bottom, 12)
        } else {
            ForEach(service.notes) { note in
                rowDivider
                HStack(spacing: 8) {
                    Button { selectedNote = note } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(note.text).font(.body).foregroundStyle(AmberTheme.foreground)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Text(LocalizedStringKey(note.syncedAt == nil ? "待同步" : "已保存到 iPhone"))
                                .font(.caption).foregroundStyle(AmberTheme.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive) { noteToDelete = note } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless).accessibilityLabel("删除记事")
                }
                .padding(.leading, 54).padding(.trailing, 14).padding(.vertical, 8)
            }
        }
    }

    private func deleteNote(_ note: WatchNote) {
        noteError = nil
        guard service.deleteNote(id: note.id) else {
            noteError = service.storageError ?? "记事删除失败，请稍后重试。"
            noteToDelete = nil
            return
        }
        noteToDelete = nil
    }

    private func sectionFooter(_ text: String, color: Color = AmberTheme.muted) -> some View {
        Text(LocalizedStringKey(text))
            .font(.caption2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func refreshNotificationAuthorization() async {
        notificationAuthorization = await IOSLocalNotificationService.shared.authorization()
    }

    private func requestNotificationsIfNeeded(revision: Int) {
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true
        notificationMessage = nil
        Task { @MainActor in
            let granted = await IOSLocalNotificationService.shared.requestAuthorization()
            guard notificationRequestRevision == revision else {
                isRequestingNotifications = false
                return
            }
            notificationAuthorization = await IOSLocalNotificationService.shared.authorization()
            completionNotificationsEnabled = granted
            if !granted {
                notificationMessage = "通知权限未开启，任务提醒不会显示。"
            }
            isRequestingNotifications = false
        }
    }

    private func noteDetail(_ note: WatchNote) -> some View {
        NavigationStack {
            ScrollView {
                Text(note.text)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .navigationTitle("Watch 记事")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { selectedNote = nil }
                }
            }
        }
    }
}
