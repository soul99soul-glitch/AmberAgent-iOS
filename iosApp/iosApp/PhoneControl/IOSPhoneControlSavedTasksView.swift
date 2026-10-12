import SwiftUI

struct IOSPhoneControlSavedTaskDraft: Identifiable {
    let id: String
    let actionID: String?
    var title: String
    var prompt: String

    init(action: WatchQuickAction? = nil, title: String = "", prompt: String = "") {
        id = action?.id ?? UUID().uuidString
        actionID = action?.id
        self.title = action?.title ?? title
        self.prompt = action?.prompt ?? prompt
    }
}

struct IOSPhoneControlSavedTasksView: View {
    @Environment(\.dismiss) private var dismiss
    private let sharedSettings: IOSSharedSettingsStore
    private let inbox: IOSDeepLinkInbox
    @State private var actions: [WatchQuickAction] = []
    @State private var sheet: TaskSheet?
    @State private var pendingURL: URL?
    @State private var pendingDeletion: WatchQuickAction?
    @State private var errorMessage: String?

    private enum TaskSheet: Identifiable {
        case editor(IOSPhoneControlSavedTaskDraft)
        case input(WatchQuickAction)

        var id: String {
            switch self {
            case .editor(let draft): "editor-\(draft.id)"
            case .input(let action): "input-\(action.id)"
            }
        }
    }

    init(sharedSettings: IOSSharedSettingsStore, inbox: IOSDeepLinkInbox = .shared) {
        self.sharedSettings = sharedSettings
        self.inbox = inbox
    }

    var body: some View {
        savedTaskPage {
            savedTaskHeader("常用任务", backLabel: "返回手机自主控制") { dismiss() }
            ScrollView {
                VStack(spacing: 16) {
                    if let errorMessage { savedTaskError(errorMessage) }
                    AmberFormGroup {
                        savedTaskAction("创建任务", systemImage: "plus") {
                            sheet = .editor(IOSPhoneControlSavedTaskDraft())
                        }
                        .accessibilityIdentifier("phoneSavedTaskCreate")
                    }
                    if actions.isEmpty {
                        AmberFormGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("还没有常用任务").font(.headline)
                                Text("把重复使用的目标和完成条件保存下来，运行时会在新对话中交给 Amber。")
                                    .font(.body).foregroundStyle(AmberTheme.muted)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .accessibilityIdentifier("phoneSavedTaskEmpty")
                        }
                    } else {
                        ForEach(actions) { action in taskCard(action) }
                    }
                    savedTaskFootnote("常用任务与手表快捷动作共用同一份内容。请写清要使用的 App、目标和完成条件；实际运行仍使用当前的手机控制配置。")
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: reloadActions)
        .onChange(of: sharedSettings.revision) { _, _ in reloadActions() }
        .sheet(item: $sheet, onDismiss: submitPendingTask) { destination in
            switch destination {
            case .editor(let draft):
                IOSPhoneControlSavedTaskEditor(sharedSettings: sharedSettings, draft: draft)
            case .input(let action):
                IOSPhoneControlSavedTaskRunInput(sharedSettings: sharedSettings, action: action, inbox: inbox,
                                                onPrepared: { url in
                                                    pendingURL = url
                                                    sheet = nil
                                                })
            }
        }
        .confirmationDialog("删除常用任务？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { action in
            Button("删除“\(action.title)”", role: .destructive) { delete(action) }
        } message: { _ in
            Text("删除后，手表中选择的对应快捷动作也会移除。")
        }
    }

    private func taskCard(_ action: WatchQuickAction) -> some View {
        AmberFormGroup {
            VStack(alignment: .leading, spacing: 7) {
                Text(verbatim: action.title).font(.headline)
                    .accessibilityIdentifier("phoneSavedTaskTitle-\(action.id)")
                Text(verbatim: action.prompt).font(.body).foregroundStyle(AmberTheme.muted)
                if action.isTemplate {
                    Text("运行前填写输入").font(.caption).foregroundStyle(AmberTheme.accent)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            savedTaskDivider
            savedTaskAction("运行任务", systemImage: "play.fill") { run(action) }
                .accessibilityLabel("运行 \(action.title)")
                .accessibilityIdentifier("phoneSavedTaskRun-\(action.id)")
            savedTaskDivider
            savedTaskAction("编辑任务", systemImage: "pencil") {
                sheet = .editor(IOSPhoneControlSavedTaskDraft(action: action))
            }
            .accessibilityLabel("编辑 \(action.title)")
            .accessibilityIdentifier("phoneSavedTaskEdit-\(action.id)")
            savedTaskDivider
            savedTaskAction("删除任务", systemImage: "trash", color: AmberTheme.accentRed) {
                pendingDeletion = action
            }
            .accessibilityLabel("删除 \(action.title)")
            .accessibilityIdentifier("phoneSavedTaskDelete-\(action.id)")
        }
    }

    private func reloadActions() {
        let latest = sharedSettings.savedQuickActions()
        if actions != latest { actions = latest }
    }

    private func run(_ action: WatchQuickAction) {
        errorMessage = nil
        if action.isTemplate {
            sheet = .input(action)
        } else {
            do { try IOSPhoneControlSavedTaskLaunch.submit(id: action.id, input: nil, store: sharedSettings, inbox: inbox) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func submitPendingTask() {
        guard let url = pendingURL else { return }
        // Clear ownership before the inbox can synchronously change root navigation.
        pendingURL = nil
        inbox.submit(url)
    }

    private func delete(_ action: WatchQuickAction) {
        do {
            try sharedSettings.deleteQuickAction(id: action.id)
            pendingDeletion = nil
            errorMessage = nil
            reloadActions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct IOSPhoneControlSavedTaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let sharedSettings: IOSSharedSettingsStore
    @State private var draft: IOSPhoneControlSavedTaskDraft
    @State private var errorMessage: String?

    init(sharedSettings: IOSSharedSettingsStore, draft: IOSPhoneControlSavedTaskDraft) {
        self.sharedSettings = sharedSettings
        _draft = State(initialValue: draft)
    }

    var body: some View {
        savedTaskPage {
            savedTaskHeader(draft.actionID == nil ? "创建任务" : "编辑任务", backLabel: "取消编辑") { dismiss() }
            ScrollView {
                VStack(spacing: 16) {
                    if let errorMessage { savedTaskError(errorMessage) }
                    AmberFormGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("任务标题").font(.headline)
                            TextField("如：整理本周待办", text: $draft.title, axis: .vertical)
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("phoneSavedTaskEditorTitle")
                        }.padding(14)
                        savedTaskDivider
                        VStack(alignment: .leading, spacing: 8) {
                            Text("目标与完成条件").font(.headline)
                            TextField("描述使用哪个 App、需要做什么，以及如何确认完成", text: $draft.prompt, axis: .vertical)
                                .lineLimit(5...12)
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("phoneSavedTaskEditorPrompt")
                        }.padding(14)
                    }
                    savedTaskFootnote("标题最多 40 字，任务内容最多 2000 字。需要每次填写内容时，在任务中写入 {输入}；也支持 {輸入} 和 {input}，它们共用同一项输入。")
                    AmberFormGroup {
                        savedTaskAction("保存任务", systemImage: "checkmark") { save() }
                            .accessibilityIdentifier("phoneSavedTaskSave")
                    }
                }.padding(.bottom, 36)
            }.scrollIndicators(.hidden)
        }
    }

    private func save() {
        do {
            _ = try sharedSettings.saveQuickAction(id: draft.actionID, title: draft.title, prompt: draft.prompt)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct IOSPhoneControlSavedTaskRunInput: View {
    @Environment(\.dismiss) private var dismiss
    private let sharedSettings: IOSSharedSettingsStore
    private let action: WatchQuickAction
    private let inbox: IOSDeepLinkInbox
    private let onPrepared: (URL) -> Void
    @State private var input: String
    @State private var errorMessage: String?
    @State private var hasPreparedHandoff = false

    init(sharedSettings: IOSSharedSettingsStore, action: WatchQuickAction,
         inbox: IOSDeepLinkInbox = .shared, input: String = "", onPrepared: @escaping (URL) -> Void = { _ in }) {
        self.sharedSettings = sharedSettings
        self.action = action
        self.inbox = inbox
        self.onPrepared = onPrepared
        _input = State(initialValue: input)
    }

    var body: some View {
        savedTaskPage {
            savedTaskHeader("填写任务输入", backLabel: "取消运行") { dismiss() }
            ScrollView {
                VStack(spacing: 16) {
                    if let errorMessage { savedTaskError(errorMessage) }
                    AmberFormGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: action.title).font(.headline)
                            Text(verbatim: action.prompt).font(.body).foregroundStyle(AmberTheme.muted)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        savedTaskDivider
                        VStack(alignment: .leading, spacing: 8) {
                            Text("本次输入").font(.headline)
                            TextField("填写任务中的 {输入}", text: $input, axis: .vertical)
                                .lineLimit(3...8)
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("phoneSavedTaskRunInput")
                        }.padding(14)
                    }
                    savedTaskFootnote("这项输入会填入模板中的所有输入占位符。运行后，Amber 会在新对话中处理本次目标。")
                    AmberFormGroup {
                        savedTaskAction("运行任务", systemImage: "play.fill") { run() }
                            .disabled(hasPreparedHandoff)
                            .accessibilityIdentifier("phoneSavedTaskRunWithInput")
                    }
                }.padding(.bottom, 36)
            }.scrollIndicators(.hidden)
        }
    }

    private func run() {
        guard !hasPreparedHandoff else { return }
        do {
            let url = try IOSPhoneControlSavedTaskLaunch.prepare(id: action.id, input: input, store: sharedSettings, inbox: inbox)
            hasPreparedHandoff = true
            onPrepared(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
enum IOSPhoneControlSavedTaskLaunch {
    static func prepare(id: String, input: String?, store: IOSSharedSettingsStore, inbox: IOSDeepLinkInbox) throws -> URL {
        let prompt = try store.resolvedQuickActionPrompt(id: id, input: input)
        guard let destination = inbox.preparePromptHandoff(prompt), let url = IOSAppDeepLink.url(for: destination) else {
            throw NSError(domain: "IOSPhoneControlSavedTaskLaunch", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法运行任务，请检查任务内容后重试。"])
        }
        return url
    }

    static func submit(id: String, input: String?, store: IOSSharedSettingsStore, inbox: IOSDeepLinkInbox) throws {
        inbox.submit(try prepare(id: id, input: input, store: store, inbox: inbox))
    }
}

@MainActor
private func savedTaskPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ZStack {
        AmberTheme.background.ignoresSafeArea()
        VStack(spacing: 0, content: content)
    }
    .foregroundStyle(AmberTheme.foreground)
    .tint(AmberTheme.accent)
}

@MainActor
private func savedTaskHeader(_ title: String, backLabel: String, action: @escaping () -> Void) -> some View {
    HStack(spacing: 8) {
        AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: backLabel,
                               size: 44, symbolSize: 20, action: action)
        Spacer(minLength: 0)
        Text(verbatim: title).font(.title2.weight(.bold))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Color.clear.frame(width: 44, height: 44)
    }
    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 18)
}

@MainActor
private func savedTaskAction(_ title: String, systemImage: String, color: Color = AmberTheme.accent,
                             action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 20))
                .frame(width: 24, height: 24).accessibilityHidden(true)
            Text(verbatim: title).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.body).foregroundStyle(color)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 6).contentShape(Rectangle())
    }.buttonStyle(.plain)
}

@MainActor
private var savedTaskDivider: some View {
    Rectangle().fill(AmberTheme.border).frame(height: 0.5).padding(.leading, 50)
}

@MainActor
private func savedTaskFootnote(_ text: String, color: Color = AmberTheme.muted) -> some View {
    Text(verbatim: text).font(.caption).foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
}

@MainActor
private func savedTaskError(_ text: String) -> some View {
    savedTaskFootnote(text, color: AmberTheme.accentRed)
        .accessibilityIdentifier("phoneSavedTaskError")
}
