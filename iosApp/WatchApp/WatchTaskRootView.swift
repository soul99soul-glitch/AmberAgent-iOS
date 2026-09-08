import SwiftUI

struct WatchTaskRootView: View {
    @ObservedObject var model: WatchTaskViewModel
    @ObservedObject private var store: WatchLocalStore
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var cancelRunId: String?
    @State private var confirmsClear = false
    @State private var discardedDraftKey: String?

    init(model: WatchTaskViewModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.store)
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            VStack(spacing: 4) {
                HStack(spacing: 7) {
                    ZStack {
                        Capsule().frame(width: 5, height: 14).rotationEffect(.degrees(35)).offset(x: -3, y: -1)
                        Circle().frame(width: 8, height: 8).offset(x: 4, y: 3)
                    }
                    .frame(width: 16, height: 18)
                    .scaleEffect(0.9)
                    .foregroundStyle(Color(red: 0.80, green: 0.38, blue: 0.19))
                    .accessibilityHidden(true)
                    Text("Amber").font(.system(size: 18, weight: .medium))
                }
                .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38, alignment: .bottomLeading)
                .padding(.horizontal, 14)
                page(spacing: 4) { home }.clipped()
                askButton.padding(.horizontal, 9)
            }
                .padding(.bottom, 12)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .navigationTitle("")
                .toolbar(.visible, for: .navigationBar)
                .navigationDestination(for: WatchRoute.self) { route in
                    Group {
                    switch route {
                    case .compose(let key): page { composer(key: key) }.navigationTitle(composerTitle(key))
                    case .task(let runId): page { task(runId: runId) }.navigationTitle(t("任务"))
                    case .recent: page { recent }.navigationTitle(t("近期动态"))
                    case .activity(let entry): page { activity(entry) }.navigationTitle(t("成果详情"))
                        .onAppear { store.markViewed(entry) }
                    case .conversation(let id): page { conversation(id: id) }.navigationTitle(t("对话"))
                    case .note(let id): page { note(id: id) }.navigationTitle(t("随手记"))
                    case .settings: page { settings }.navigationTitle(t("设置与连接"))
                    }
                    }
                    .toolbar(.visible, for: .navigationBar)
                }
        }
        .tint(Color(red: 0.83, green: 0.39, blue: 0.20))
        .environment(\.locale, WatchTaskLocalization.language(for: model.snapshot.languageCode).resolvedLocale())
        .confirmationDialog(t("取消当前任务？"), isPresented: Binding(
            get: { cancelRunId != nil }, set: { if !$0 { cancelRunId = nil } }
        ), titleVisibility: .visible) {
            Button(t("取消任务"), role: .destructive) {
                if let runId = cancelRunId { model.perform(.cancel, expectedRunId: runId) }
                cancelRunId = nil
            }
            Button(t("继续任务"), role: .cancel) {}
        } message: { Text(t("已经生成的内容会保留在 iPhone。")) }
        .confirmationDialog(t("清除手表缓存？"), isPresented: $confirmsClear, titleVisibility: .visible) {
            Button(t("清除缓存"), role: .destructive) { model.clearCache() }
        } message: { Text(t("不会删除 iPhone 会话。未同步笔记和未发送草稿会受到保护。")) }
        .confirmationDialog(t("丢弃这份草稿？"), isPresented: Binding(
            get: { discardedDraftKey != nil }, set: { if !$0 { discardedDraftKey = nil } }
        ), titleVisibility: .visible) {
            Button(t("丢弃草稿"), role: .destructive) {
                if let key = discardedDraftKey {
                    store.removeDraft(key: key)
                    if store.draft(forKey: key) == nil, !model.path.isEmpty { model.path.removeLast() }
                }
                discardedDraftKey = nil
            }
        } message: { Text(t("如果发送结果未知，请先在 iPhone 核实；丢弃草稿不会取消已接收的任务。")) }
    }

    private func page<Content: View>(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                if isLuminanceReduced && !store.settings.showContentPreview {
                    Label(t(phaseTitle), systemImage: phaseSymbol).font(.headline)
                    Label(t("抬腕查看内容"), systemImage: "lock.fill").font(.caption)
                } else {
                    if model.isRefreshing { ProgressView(t("正在同步")) }
                    content()
                    if let message = model.statusMessage {
                        Text(message).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("watch.status")
                    }
                    if let error = store.storageError {
                        Label(t(error), systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6).padding(.bottom, 10)
        }
        .contentMargins(.top, 0, for: .scrollContent)
        #if DEBUG
        .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("-amber-watch-scroll-bottom") ? .bottom
                             : ProcessInfo.processInfo.arguments.contains("-amber-watch-scroll-middle") ? .center : nil)
        #endif
    }

    @ViewBuilder private var home: some View {
        if model.showsCurrentTask {
            Button { model.path.append(.task(model.snapshot.runId)) } label: {
                WatchResultCard(status: t(phaseTitle), symbol: phaseSymbol,
                    title: model.snapshot.headline,
                    summary: model.snapshot.summary ?? model.snapshot.detail ?? "",
                    updatedAt: model.snapshot.updatedAt)
            }
            .buttonStyle(.plain).privacySensitive()
            .accessibilityIdentifier("watch.current-task")
        } else if let entry = model.activities.first {
            Button { model.openActivity(entry) } label: {
                WatchResultCard(status: t(entry.statusKey), symbol: entry.statusSymbol,
                    title: entry.resultTitle ?? entry.title, summary: entry.summary, updatedAt: entry.updatedAt)
                    .accessibilityValue(!store.hasViewed(entry) ? t("未读") : "")
            }
            .buttonStyle(.plain).privacySensitive()
            .accessibilityIdentifier("watch.latest-result")
        } else {
            WatchResultCard(status: "Amber", symbol: "sparkles", title: t("准备好了"),
                summary: t("问一个问题，或先记下一点想法。"))
                .accessibilityIdentifier("watch.empty-home")
        }
        Button { model.path.append(.recent) } label: {
            HStack {
                Text(t("近期动态"))
                Spacer(minLength: 4)
                if model.activities.contains(where: { !store.hasViewed($0) }) {
                    Circle().fill(Color.orange).frame(width: 5, height: 5).accessibilityHidden(true)
                }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 28)
            .foregroundStyle(Color.white.opacity(0.66))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(model.activities.contains(where: { !store.hasViewed($0) }) ? t("未读") : "")
        .accessibilityIdentifier("watch.activities")
        Button { model.compose(mode: .note) } label: {
            Label(t("随手记"), systemImage: "square.and.pencil").font(.caption)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("watch.note")
        if model.library == nil || model.library?.isConfigured == false {
            card {
                Text(t("先连接 iPhone 上的 Amber")).font(.caption.weight(.semibold))
                Text(t(model.library?.configurationMessage ?? "在 iPhone 打开 Amber 并配置模型。问题由手机上的助手处理；记事可以先保存在手表。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if let quickActions = model.library?.quickActions, !quickActions.isEmpty {
            sectionTitle("快捷动作")
            ForEach(quickActions) { action in
                Button { model.compose(mode: .ask, quickAction: action) } label: {
                    Label(action.title, systemImage: "bolt.fill").font(.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
                .privacySensitive()
            }
        }
        if !store.drafts.isEmpty {
            sectionTitle("未发送草稿")
            ForEach(store.drafts) { draft in
                navigationButton(t(draft.composerMode == .note ? "记事草稿" : "问题草稿"),
                                 symbol: draft.pendingRequest == nil ? "pencil" : "clock", route: .compose(draft.key))
            }
        }
        navigationButton(t("设置与连接"), symbol: "gearshape", route: .settings)
        Label(connectionTitle,
              systemImage: model.isPhoneReachable ? "iphone.gen3.radiowaves.left.and.right" : "iphone.slash")
            .font(.caption2).foregroundStyle(model.isPhoneReachable ? Color.secondary : Color.orange)
            .frame(maxWidth: .infinity)
    }

    private var askButton: some View {
        Button { model.compose(mode: .ask) } label: {
            Label(t("问 Amber"), systemImage: "mic.fill")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(.white)
                .background(Color(red: 0.82, green: 0.36, blue: 0.17), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch.ask")
    }

    @ViewBuilder private func composer(key: String) -> some View {
        if let draft = store.draft(forKey: key) {
            if draft.conversationId != nil { sectionTitle("继续原对话") }
            if draft.pendingRequest != nil {
                card {
                    Text(t("正在确认是否已接收")).font(.caption.weight(.semibold))
                    Text(t("原文已锁定。重新确认使用同一请求，不会另发一条新问题。"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if draft.pendingRequest != nil || draft.quickActionId != nil {
                Text(draft.text).font(.body).fixedSize(horizontal: false, vertical: true).privacySensitive()
            } else {
                TextField(t("听写或输入文字"), text: Binding(
                    get: { store.draft(forKey: key)?.text ?? "" },
                    set: { store.updateDraftText(key: key, text: $0) }
                ), axis: .vertical)
                .lineLimit(3...8).accessibilityIdentifier("watch.composer")
                if draft.text.isEmpty {
                    Text(t("使用系统听写或文字输入，检查后再发送。"))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    // watchOS renders TextField as a compact input launcher;
                    // show the complete text separately for review before sending.
                    Text(draft.text).font(.body).fixedSize(horizontal: false, vertical: true).privacySensitive()
                }
            }
            Text("\(draft.text.count) / 2000").font(.caption2.monospacedDigit())
                .foregroundStyle(draft.text.count > 2_000 ? Color.red : Color.secondary)
            if model.isSending { ProgressView(t("正在发送")) }
            actionButton(t(draft.composerMode == .note ? "保存记事" : draft.pendingRequest != nil ? "确认接收结果" : "发送问题")) {
                model.submitDraft(key: key)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSending || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.text.count > 2_000)
            .accessibilityIdentifier("watch.submit")
            if draft.composerMode == .ask, !model.isPhoneReachable {
                Text(t("无法连接 iPhone，问题已保留为草稿")).font(.caption2).foregroundStyle(.orange)
            }
            actionButton(t("丢弃草稿"), role: .destructive) { discardedDraftKey = key }
                .disabled(model.isSending)
        } else { Text(t("这份草稿已处理")) }
    }

    @ViewBuilder private func task(runId: String) -> some View {
        if runId != model.snapshot.runId {
            Text(t("这项任务已不在当前快照中")).font(.headline)
            Text(t("请在最近记录或 iPhone 中查看原任务。")).font(.caption)
            navigationButton(t("最近记录"), symbol: "clock", route: .recent)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack {
                    taskPhaseLabel.fixedSize()
                    Spacer(minLength: 4)
                    taskUpdateTime.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    taskPhaseLabel
                    taskUpdateTime
                }
            }
            if !model.snapshot.headline.isEmpty {
                Text(model.snapshot.headline).font(.headline)
                    .fixedSize(horizontal: false, vertical: true).privacySensitive()
            }
            if model.snapshot.decision == nil, !["completed", "failed", "cancelled"].contains(model.snapshot.phase),
               let detail = model.snapshot.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            if let metric = model.snapshot.metricText { Text(metric).font(.caption.monospacedDigit()) }
            if let decision = model.snapshot.decision { decisionCard(decision, runId: runId) }
            if let summary = model.snapshot.summary, !summary.isEmpty {
                card {
                    sectionTitle("回答节选")
                    Text(summary).font(.body).fixedSize(horizontal: false, vertical: true)
                }.privacySensitive()
            }
            if model.isSending { ProgressView(t("正在发送")) }
            if model.snapshot.actions.contains(.retry) {
                actionButton(t("重试")) { model.perform(.retry, expectedRunId: runId) }.disabled(!model.canControl)
            }
            if model.snapshot.actions.contains(.cancel) {
                actionButton(t("取消任务"), role: .destructive) { cancelRunId = runId }.disabled(!model.canControl)
            }
            if ["completed", "failed", "cancelled"].contains(model.snapshot.phase), let id = model.snapshot.conversationId {
                actionButton(t("继续追问")) { model.compose(mode: .ask, conversationId: id) }
            }
            if model.snapshot.actions.contains(.openOnPhone) {
                actionButton(t("在 iPhone 继续")) { model.perform(.openOnPhone, expectedRunId: runId) }.disabled(!model.canControl)
            }
            if !model.isPhoneReachable { Text(t("连接 iPhone 后可继续操作")).font(.caption2).foregroundStyle(.orange) }
            actionButton(t("刷新")) { model.refresh() }.disabled(model.isBusy)
        }
    }

    private var taskPhaseLabel: some View {
        Label(t(phaseTitle), systemImage: phaseSymbol).font(.caption.weight(.semibold))
    }

    @ViewBuilder private var taskUpdateTime: some View {
        if model.snapshot.updatedAt != .distantPast {
            Text(model.snapshot.updatedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func decisionCard(_ decision: WatchDecision, runId: String) -> some View {
        card {
            if !decision.title.isEmpty { Text(decision.title).font(.headline) }
            if decision.type == .approval {
                Label(t(decision.riskLevel == .low ? "低风险" : decision.riskLevel == .medium ? "中等风险" : "高风险"), systemImage: "shield.lefthalf.filled")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(decision.body).font(.body).fixedSize(horizontal: false, vertical: true)
            ForEach(decision.options.filter { $0.style != .dictate }) { option in
                Button {
                    switch option.style {
                    case .approve: model.perform(.approve, optionId: option.id, expectedRunId: runId, expectedDecisionId: decision.id)
                    case .deny: model.perform(decision.type == .approval ? .deny : .choose, optionId: option.id, expectedRunId: runId, expectedDecisionId: decision.id)
                    case .choice: model.perform(.choose, optionId: option.id, expectedRunId: runId, expectedDecisionId: decision.id)
                    case .openOnPhone: model.perform(.openOnPhone, expectedRunId: runId, expectedDecisionId: decision.id)
                    case .dictate: break
                    }
                } label: {
                    Text(option.title).font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                }.disabled(!model.canControl)
            }
            if decision.allowsVoice {
                TextField(t("输入或听写回答"), text: $model.draftAnswer, axis: .vertical)
                    .lineLimit(2...6)
                if !model.draftAnswer.isEmpty {
                    Text(model.draftAnswer).font(.body).fixedSize(horizontal: false, vertical: true)
                }
                actionButton(t("提交回答")) { model.submitAnswer(runId: runId, decisionId: decision.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canControl || model.draftAnswer.count > 2_000 || model.draftAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.privacySensitive()
    }

    @ViewBuilder private var recent: some View {
        if !model.activities.isEmpty {
            sectionTitle("最近发生")
            ForEach(model.activities) { entry in
                Button { model.openActivity(entry) } label: {
                    card {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Label(t(entry.statusKey), systemImage: entry.statusSymbol)
                                .font(.caption2).foregroundStyle(.orange)
                            Spacer(minLength: 0)
                            if !store.hasViewed(entry) {
                                Circle().fill(Color.orange).frame(width: 5, height: 5)
                                    .accessibilityLabel(t("未读"))
                            }
                        }
                        Text(entry.title).font(.caption.weight(.semibold)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if store.settings.showContentPreview, !entry.summary.isEmpty {
                            Text(entry.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(entry.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }.multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain).privacySensitive()
                .accessibilityIdentifier("watch.activity.\(entry.id)")
            }
        }

        if let recent = model.library?.recent, !recent.isEmpty {
            sectionTitle("最近对话")
            ForEach(recent) { entry in
                Button { model.path.append(.conversation(entry.id)) } label: {
                    card {
                        Text(entry.title).font(.caption.weight(.semibold)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if store.settings.showContentPreview, !entry.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(entry.preview).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(entry.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("watch.recent.\(entry.id)")
                .privacySensitive()
            }
        }
        if model.library == nil && model.activities.isEmpty {
            if !model.isRefreshing {
                Text(t("请在 iPhone 打开 Amber 完成首次同步。")).font(.caption).foregroundStyle(.secondary)
            }
            actionButton(t("随手记")) { model.compose(mode: .note) }
        } else if model.library?.recent.isEmpty == true && model.activities.isEmpty {
            Label(t("还没有记录"), systemImage: "tray").font(.headline)
            Text(t("问一个问题，或先记下一点想法。")).font(.caption).foregroundStyle(.secondary)
            actionButton(t("问 Amber")) { model.compose(mode: .ask) }
            actionButton(t("随手记")) { model.compose(mode: .note) }
        }
        actionButton(t("刷新")) { model.refresh() }.disabled(model.isBusy)
    }

    @ViewBuilder private func activity(_ entry: WatchRecentActivity) -> some View {
        Label(t(entry.statusKey), systemImage: entry.statusSymbol)
            .font(.caption.weight(.semibold)).foregroundStyle(.orange)
        Text(entry.title).font(.headline).fixedSize(horizontal: false, vertical: true).privacySensitive()
        updatedAt(entry.updatedAt)
        if !entry.summary.isEmpty {
            sectionTitle("内容节选")
            Text(entry.summary).font(.body).fixedSize(horizontal: false, vertical: true).privacySensitive()
        }
        if let id = entry.conversationId {
            actionButton(t("继续追问")) { model.compose(mode: .ask, conversationId: id) }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            actionButton(t("在 iPhone 继续")) { model.openConversation(id) }
                .frame(maxWidth: .infinity).disabled(!model.isPhoneReachable || model.isSending)
            if !model.isPhoneReachable {
                Text(t("连接 iPhone 后可继续操作")).font(.caption2).foregroundStyle(.orange)
            }
        } else if entry.kind == "note" {
            Text(t("在 iPhone 的设置 → Apple Watch 中查看同步的记事。"))
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            Text(t("在 iPhone 查看完整内容")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func conversation(id: String) -> some View {
        if !model.isPhoneReachable {
            Text(t("连接 iPhone 后可继续操作")).font(.caption2).foregroundStyle(.orange)
        }
        if let entry = model.library?.recent.first(where: { $0.id == id }) {
            Text(entry.title).font(.headline).privacySensitive()
            updatedAt(entry.updatedAt)
            sectionTitle("内容节选")
            Text(entry.preview.isEmpty ? t("在 iPhone 查看完整内容") : entry.preview)
                .font(.body).privacySensitive()
            actionButton(t("继续追问")) { model.compose(mode: .ask, conversationId: id) }
                .buttonStyle(.borderedProminent)
            actionButton(t("在 iPhone 继续")) { model.openConversation(id) }
                .disabled(!model.isPhoneReachable || model.isSending)
        } else {
            Text(t("这条记录已不在最近列表中")).font(.caption)
            actionButton(t("在 iPhone 继续")) { model.openConversation(id) }.disabled(!model.isPhoneReachable)
        }
    }

    @ViewBuilder private func note(id: String) -> some View {
        if let note = store.note(id: id) {
            Label(t(note.syncedAt == nil ? "已存手表，待同步" : "已存 iPhone"),
                  systemImage: note.syncedAt == nil ? "clock" : "checkmark.icloud")
                .font(.caption.weight(.semibold))
            updatedAt(note.createdAt)
            Text(note.text).font(.body).fixedSize(horizontal: false, vertical: true).privacySensitive()
            if let error = model.noteSyncErrors[id] { Text(error).font(.caption2).foregroundStyle(.orange) }
            if note.syncedAt == nil {
                actionButton(t("重试同步")) { model.retryNote(id: id) }
            }
            Text(t("在 iPhone 的设置 → Apple Watch 中查看同步的记事。"))
                .font(.caption2).foregroundStyle(.secondary)
        } else { Text(t("找不到这条记事")) }
    }

    private var connectionTitle: String {
        switch model.connectionPresentation {
        case .connecting: return t("正在连接 iPhone")
        case .waitingForPhone: return t("等待 iPhone 响应")
        case .connected: return t("iPhone 已连接")
        case .offline: return t("iPhone 暂不可达")
        }
    }

    @ViewBuilder private var settings: some View {
        card {
            Label(connectionTitle, systemImage: "iphone")
                .font(.caption.weight(.semibold))
            if let library = model.library {
                Text(library.assistantName).font(.caption).privacySensitive()
                updatedAt(library.updatedAt)
                if let message = library.configurationMessage { Text(t(message)).font(.caption2) }
            } else { Text(t("请在 iPhone 打开 Amber 完成首次同步。")).font(.caption2) }
            actionButton(t("重新同步")) { model.refresh() }.disabled(model.isBusy)
        }
        Toggle(t("触感反馈"), isOn: Binding(
            get: { store.settings.hapticsEnabled }, set: { value in store.updateSettings { $0.hapticsEnabled = value } }
        ))
        Toggle(t("内容预览"), isOn: Binding(
            get: { store.settings.showContentPreview }, set: { value in store.updateSettings { $0.showContentPreview = value } }
        ))
        Text(t("开启后，最近列表和低亮度界面可显示内容。表盘和通知始终使用简短状态。"))
            .font(.caption2).foregroundStyle(.secondary)
        sectionTitle("任务通知")
        Text(t("在 iPhone 的 Amber 设置中开启任务通知，并在 Watch App 中允许通知镜像。"))
            .font(.caption2).foregroundStyle(.secondary)
        actionButton(t("清除缓存"), role: .destructive) { confirmsClear = true }
        Text("Amber \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func actionButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private func navigationButton(_ title: String, symbol: String, route: WatchRoute) -> some View {
        Button { model.path.append(route) } label: {
            Label(title, systemImage: symbol).font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
    private func sectionTitle(_ text: String) -> some View {
        Text(t(text)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
    private func updatedAt(_ date: Date) -> some View {
        Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
    }
    private func composerTitle(_ key: String) -> String {
        t(store.draft(forKey: key)?.composerMode == .note ? "随手记" : "问 Amber")
    }
    private var phaseTitle: String {
        switch model.snapshot.phase {
        case "running": "进行中"
        case "waitingForUser": "等待你"
        case "reconnecting": "重连中"
        case "completed": "已完成"
        case "failed": "需要处理"
        case "cancelled": "已取消"
        case "stale": "状态过期"
        default: "待命"
        }
    }
    private var phaseSymbol: String {
        switch model.snapshot.phase {
        case "running": "waveform"
        case "waitingForUser": "hand.raised.fill"
        case "reconnecting": "arrow.triangle.2.circlepath"
        case "completed": "checkmark.circle.fill"
        case "failed": "exclamationmark.triangle.fill"
        case "cancelled": "stop.circle"
        case "stale": "clock.badge.exclamationmark"
        default: "sparkles"
        }
    }
    private func t(_ key: String) -> String { model.localized(key) }
}
