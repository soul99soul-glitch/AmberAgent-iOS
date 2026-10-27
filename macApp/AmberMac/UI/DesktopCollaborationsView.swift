import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopCollaborationsView: View {
    @Bindable var workspace: DesktopWorkspace
    let onOpenSavedResult: (UUID, UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var council = true
    @State private var objective = ""
    @State private var members = DesktopCollaborationRole.builtIns.prefix(3).map {
        DesktopCollaborationMember(name: $0.name, rolePrompt: $0.prompt)
    }
    @State private var synthesisModelID: UUID?
    @State private var timeoutSeconds = 180
    @State private var selectedRunID: UUID?
    @State private var error: String?

    private var ownerRuns: [DesktopCollaborationRun] {
        Array(workspace.collaborations.runs.filter { $0.parentConversationID == workspace.selectedID }.reversed())
    }
    private var selectedRun: DesktopCollaborationRun? { ownerRuns.first { $0.id == selectedRunID } }
    private var ownerIsRunning: Bool { ownerRuns.contains { !$0.status.isTerminal } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("多模型协作").font(.system(size: 20, weight: .semibold))
                    Text("各成员只接收本次任务说明与职责。关闭此面板后，正在执行的协作会继续。")
                        .font(.system(size: 13)).foregroundStyle(DesktopTheme.muted(colorScheme)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if workspace.collaborations.isLoading { ProgressView("正在读取协作记录…").controlSize(.small) }
            if let failure = workspace.collaborations.loadError {
                HStack(alignment: .top) {
                    Label(failure, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    Spacer()
                    Button("重新读取") { workspace.collaborations.retryLoad() }
                }
            }
            if let failure = workspace.collaborations.persistenceError {
                HStack(alignment: .top) {
                    Label(failure, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    Spacer()
                    Button("重试保存") { Task { await workspace.collaborations.flush() } }
                        .disabled(workspace.collaborations.runs.contains { !$0.status.isTerminal })
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    configuration
                    if let error { Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    if !ownerRuns.isEmpty {
                        Divider()
                        HStack {
                            Picker("协作记录", selection: $selectedRunID) {
                                ForEach(ownerRuns) { run in
                                    Text(run.objective).lineLimit(1).tag(Optional(run.id))
                                }
                            }
                            if let run = selectedRun {
                                Text(run.status.title).font(.caption).foregroundStyle(.secondary)
                                if !run.status.isTerminal { Button("停止") { workspace.collaborations.cancel(run.id) } }
                                Button("导出结果…") { export(run) }
                                    .disabled(run.outputs.allSatisfy { $0.text.isEmpty })
                            }
                        }
                        if let run = selectedRun {
                            HStack {
                                if workspace.savingCollaborationRuns.contains(run.id) { ProgressView().controlSize(.small) }
                                Button(workspace.savedCollaborationRuns.contains(run.id) ? "已保存到原会话" : "保存到原会话") {
                                    workspace.saveCollaborationResult(runID: run.id)
                                }
                                .disabled(!run.status.isTerminal || workspace.savingCollaborationRuns.contains(run.id)
                                    || workspace.savedCollaborationRuns.contains(run.id) || run.outputs.allSatisfy { $0.text.isEmpty })
                                if workspace.savedCollaborationRuns.contains(run.id) {
                                    Button("查看会话中的结果") { onOpenSavedResult(run.parentConversationID, run.id) }
                                }
                                Spacer()
                            }
                            if let failure = workspace.collaborationSaveErrors[run.id] {
                                Text(failure).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            }
                            if let failure = run.error {
                                Text(failure).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(run.outputs) { output in outputCard(output) }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(24).frame(width: 820, height: 700)
        .background(DesktopTheme.background(colorScheme))
        .tint(DesktopTheme.accent)
        .onAppear { selectedRunID = ownerRuns.first?.id }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("协作方式", selection: $council) {
                Text("子代理 · 并行完成").tag(false)
                Text("议会 · 并行后综合").tag(true)
            }.pickerStyle(.segmented)
            Text("任务说明").font(.system(size: 13, weight: .semibold))
            TextField("这次要完成什么？请提供所需背景和资料。", text: $objective, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...6)
                .accessibilityLabel("协作任务说明")
            Text("协作成员").font(.system(size: 13, weight: .semibold)).padding(.top, 4)
            ForEach($members) { $member in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("成员名称", text: $member.name).textFieldStyle(.roundedBorder).frame(width: 130)
                        modelPicker("成员模型", selection: $member.modelID)
                        Menu("预设职责") {
                            ForEach(DesktopCollaborationRole.builtIns) { role in
                                Button(role.name) { member.name = role.name; member.rolePrompt = role.prompt }
                            }
                        }.fixedSize()
                        Button { let removedID = member.id; members.removeAll { $0.id == removedID } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).disabled(members.count == 1)
                            .accessibilityLabel("移除成员 \(member.name)")
                    }
                    TextField("成员职责", text: $member.rolePrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                        .accessibilityLabel("\(member.name) 的职责")
                }
                .padding(12)
                .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
            }
            HStack {
                Menu("添加成员", systemImage: "plus") {
                    ForEach(DesktopCollaborationRole.builtIns) { role in
                        Button(role.name) { members.append(.init(name: role.name, rolePrompt: role.prompt)) }
                    }
                }.disabled(members.count >= 8)
                Spacer()
                Stepper("每位成员超时 \(timeoutSeconds) 秒", value: $timeoutSeconds, in: 30...600, step: 30)
                    .font(.caption).fixedSize()
            }
            if council { modelPicker("综合模型", selection: $synthesisModelID) }
            HStack {
                Text("同时执行最多 \(workspace.collaborations.maxConcurrent) 个成员，其余按顺序等待。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("开始协作") { start() }.buttonStyle(.borderedProminent)
                    .disabled(ownerIsRunning || workspace.collaborations.isLoading || workspace.collaborations.loadError != nil
                        || workspace.selectedID == nil || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func modelPicker(_ label: String, selection: Binding<UUID?>) -> some View {
        Picker(label, selection: selection) {
            Text("当前会话模型").tag(Optional<UUID>.none)
            ForEach(workspace.settings.modelSelections) { model in
                Text("\(model.providerName) · \(model.modelName)").tag(Optional(model.id))
            }
        }
    }

    private func outputCard(_ output: DesktopCollaborationOutput) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(output.name).font(.system(size: 13, weight: .semibold))
                Text(output.modelName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if output.status == .running || output.status == .queued { ProgressView().controlSize(.mini) }
                Text(output.status.title).font(.caption).foregroundStyle(.secondary)
                if !output.text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).accessibilityLabel("复制 \(output.name) 的结果")
                }
            }
            if !output.text.isEmpty {
                DesktopMarkdown(text: output.text, fontFamily: workspace.settings.messageFontFamily, fontSize: workspace.settings.messageFontSize)
            }
            if let error = output.error { Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(16)
        .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
    }

    private func start() {
        guard let owner = workspace.selectedID else { return }
        do {
            if council {
                selectedRunID = try workspace.collaborations.startCouncil(parentConversationID: owner, objective: objective,
                    seats: members, synthesisModelID: synthesisModelID, timeoutSeconds: timeoutSeconds)
            } else {
                selectedRunID = try workspace.collaborations.startSubagents(parentConversationID: owner, objective: objective,
                    members: members, timeoutSeconds: timeoutSeconds)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func export(_ run: DesktopCollaborationRun) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Amber-协作结果.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let outputs = run.outputs.map { "## \($0.name) · \($0.modelName) · \($0.status.title)\n\n\($0.text)" + ($0.error.map { "\n\n> \($0)" } ?? "") }
        let text = (["# \(run.objective)"] + outputs).joined(separator: "\n\n---\n\n")
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { try Data(text.utf8).write(to: url, options: .atomic) }
        catch { self.error = "导出协作结果失败，请检查目标文件夹权限。" }
    }
}

private extension DesktopCollaborationStatus {
    var title: String {
        switch self {
        case .queued: "等待执行"
        case .running: "执行中"
        case .completed: "已完成"
        case .partial: "部分完成"
        case .failed: "失败"
        case .cancelled: "已停止"
        case .timedOut: "已超时"
        }
    }
}
