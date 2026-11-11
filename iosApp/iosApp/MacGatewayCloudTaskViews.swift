import SwiftUI
import UIKit

/// Section embedded in `MacTasksBoardView` (and reachable from `MacGatewaySettingsView`) for
/// submitting tasks to Cloud Self (`/v2/work-items`), polling status, viewing `resultMarkdown`, and cancelling.
struct MacGatewayCloudTasksSection: View {
    let store: MacGatewayStore
    @State private var presentingCompose = false
    @State private var presentingCloudMainDialogue = false
    @State private var selectedTaskSelection: SelectedCloudTask?

    struct SelectedCloudTask: Identifiable, Equatable {
        let id: String
    }

    var body: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "云端任务")
            AmberFormGroup {
                MacGatewayRow(
                    icon: "bubble.left.and.bubble.right",
                    title: macGatewayL("已配对云主对话"),
                    detail: macGatewayL("直接向已配对云主对话发送消息、补充或停止运行中任务（独立于本机对话）"),
                    action: {
                        store.setCloudMainDialogueSelected(true)
                        presentingCloudMainDialogue = true
                    }
                ) {
                    MacGatewayCapsuleButton(title: macGatewayL("进入")) {
                        store.setCloudMainDialogueSelected(true)
                        presentingCloudMainDialogue = true
                    }
                }
                MacGatewayRowDivider()
                MacGatewayRow(
                    icon: "paperplane",
                    title: macGatewayL("交给云端执行"),
                    detail: macGatewayL("向云端 Agent 派发任务，持久执行并查看结果"),
                    action: { presentingCompose = true }
                ) {
                    MacGatewayCapsuleButton(title: macGatewayL("新建")) {
                        presentingCompose = true
                    }
                }
                ForEach(store.cloudTasks) { record in
                    MacGatewayRowDivider()
                    cloudTaskRow(record)
                }
            }
        }
        .task(id: store.hasActiveCloudTasks) {
            if store.hasActiveCloudTasks {
                store.startCloudTaskPollingIfNeeded()
            }
        }
        .sheet(isPresented: $presentingCloudMainDialogue, onDismiss: {
            store.setCloudMainDialogueSelected(false)
        }) {
            MacGatewayCloudDialogueSheet(store: store)
        }
        .sheet(isPresented: $presentingCompose) {
            MacGatewayCloudTaskComposeSheet(store: store) { submittedRequestId in
                selectedTaskSelection = SelectedCloudTask(id: submittedRequestId)
            }
        }
        .sheet(item: $selectedTaskSelection) { selected in
            MacGatewayCloudTaskDetailSheet(store: store, requestId: selected.id)
        }
    }

    private func cloudTaskRow(_ record: MacGatewayCloudTaskRecord) -> some View {
        let isBusy = store.busyCloudTaskIds.contains(record.requestId)
        let agentName = store.agentDisplayName(for: record.agentId)
        let detail = "\(agentName) · \(record.summaryLine)"
        let icon = record.state?.iconName ?? (record.needsSubmissionRetry ? "exclamationmark.arrow.circlepath" : "clock")
        return MacGatewayRow(
            icon: icon,
            title: record.displayTitle,
            detail: detail,
            action: { selectedTaskSelection = SelectedCloudTask(id: record.requestId) }
        ) {
            if isBusy {
                ProgressView().frame(minHeight: 44)
            } else if record.needsSubmissionRetry {
                MacGatewayCapsuleButton(title: macGatewayL("重试")) {
                    Task { _ = await store.retryCloudTask(requestId: record.requestId) }
                }
            } else if record.canCancel, let workItemId = record.workItemId {
                MacGatewayCapsuleButton(title: macGatewayL("取消")) {
                    Task { await store.cancelCloudTask(workItemId: workItemId) }
                }
            } else {
                MacGatewayChevron()
            }
        }
    }
}

struct MacGatewayCloudTaskComposeSheet: View {
    let store: MacGatewayStore
    var onSubmitted: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var agentId = "main"
    @State private var title = ""
    @State private var text = ""
    @State private var activeRequestId = UUID().uuidString.lowercased()
    @State private var lastSubmittedFingerprint: String?
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentFingerprint: String {
        "\(agentId)\u{0000}\(MacGatewayCloudTaskRequest.normalizedTitle(title, fallbackFromText: text))\u{0000}\(text)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(macGatewayL("执行角色")) {
                    Picker(macGatewayL("Agent"), selection: $agentId) {
                        ForEach(store.effectiveCloudAgents) { agent in
                            Text(verbatim: agent.displayLabel).tag(agent.id)
                        }
                    }
                }
                Section(macGatewayL("任务内容")) {
                    TextField(macGatewayL("标题（可选，默认云端任务）"), text: $title)
                    TextField(macGatewayL("描述要交给云端执行的任务"), text: $text, axis: .vertical)
                        .lineLimit(4...10)
                }
                Section {
                    Text(verbatim: macGatewayL("任务提交后由云端受限 Worker 持久执行；网络波动时重试会沿用同一请求 ID，不会重复执行模型。"))
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(Text(verbatim: macGatewayL("交给云端执行")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(macGatewayL("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button(macGatewayL("发送")) {
                            submit()
                        }
                        .disabled(trimmedText.isEmpty)
                    }
                }
            }
            .task {
                await store.refreshCloudAgents()
                if !store.effectiveCloudAgents.contains(where: { $0.id == agentId }) {
                    agentId = "main"
                }
            }
        }
        .tint(AmberTheme.accent)
    }

    private func submit() {
        // Keep the same requestId if retrying the exact same payload after a timeout/error;
        // generate a new requestId if the user modified agent/title/text after an earlier attempt.
        if let lastSubmittedFingerprint, lastSubmittedFingerprint != currentFingerprint {
            activeRequestId = UUID().uuidString.lowercased()
        }
        let request = MacGatewayCloudTaskRequest(
            requestId: activeRequestId,
            text: text,
            agentId: agentId,
            title: title
        )
        if let validationError = request.validationError {
            errorMessage = validationError
            return
        }
        lastSubmittedFingerprint = currentFingerprint
        isSubmitting = true
        errorMessage = nil
        Task { @MainActor in
            let result = await store.submitCloudTask(request)
            isSubmitting = false
            switch result {
            case .success(let record):
                let submittedId = record.requestId
                dismiss()
                onSubmitted?(submittedId)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct MacGatewayCloudTaskDetailSheet: View {
    let store: MacGatewayStore
    let requestId: String

    @Environment(\.dismiss) private var dismiss
    @State private var copiedResult = false

    private var record: MacGatewayCloudTaskRecord? {
        store.cloudTasks.first(where: { $0.requestId == requestId })
    }

    var body: some View {
        NavigationStack {
            List {
                if let record {
                    statusSection(record)
                    briefSection(record)
                    if let failure = record.detail?.failure, !failure.isEmpty {
                        Section(macGatewayL("失败原因")) {
                            Text(verbatim: failure)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    } else if let lastError = record.lastError, !lastError.isEmpty {
                        Section(macGatewayL("最近错误")) {
                            Text(verbatim: lastError)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                    resultSection(record)
                } else {
                    Section {
                        Text(verbatim: macGatewayL("任务记录不存在"))
                            .foregroundStyle(AmberTheme.muted)
                    }
                }
            }
            .navigationTitle(Text(verbatim: record?.displayTitle ?? macGatewayL("云端任务")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(macGatewayL("完成")) { dismiss() }
                }
            }
            .task(id: record?.workItemId) {
                guard let workItemId = record?.workItemId else { return }
                await store.refreshCloudTask(workItemId: workItemId)
                while !Task.isCancelled {
                    guard let current = store.cloudTasks.first(where: { $0.requestId == requestId }),
                          let id = current.workItemId,
                          !current.isTerminal else {
                        break
                    }
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { break }
                    await store.refreshCloudTask(workItemId: id)
                }
            }
        }
        .tint(AmberTheme.accent)
    }

    @ViewBuilder
    private func statusSection(_ record: MacGatewayCloudTaskRecord) -> some View {
        Section(macGatewayL("状态")) {
            LabeledContent(macGatewayL("Agent")) {
                Text(verbatim: "\(store.agentDisplayName(for: record.agentId)) (\(record.agentId))")
            }
            LabeledContent(macGatewayL("当前状态")) {
                HStack(spacing: 6) {
                    if !record.isTerminal && record.workItemId != nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(verbatim: record.state?.displayTitle ?? macGatewayL("待提交"))
                }
            }
            if let progress = record.effectiveWorkItem?.progress, !progress.isEmpty {
                LabeledContent(macGatewayL("进度")) {
                    Text(verbatim: progress)
                        .foregroundStyle(AmberTheme.muted)
                }
            }
            LabeledContent(macGatewayL("更新时间")) {
                Text(verbatim: record.updatedAt.formatted(.relative(presentation: .named)))
                    .foregroundStyle(AmberTheme.muted)
            }
            if record.needsSubmissionRetry {
                Button(macGatewayL("重试提交（保持原请求 ID）")) {
                    Task { _ = await store.retryCloudTask(requestId: record.requestId) }
                }
                .disabled(store.busyCloudTaskIds.contains(record.requestId))
            }
            if let workItemId = record.workItemId {
                Button(macGatewayL("刷新状态")) {
                    Task { await store.refreshCloudTask(workItemId: workItemId) }
                }
                if record.canCancel {
                    Button(macGatewayL("取消任务"), role: .destructive) {
                        Task { await store.cancelCloudTask(workItemId: workItemId) }
                    }
                    .disabled(store.busyCloudTaskIds.contains(record.requestId))
                }
            }
        }
    }

    @ViewBuilder
    private func briefSection(_ record: MacGatewayCloudTaskRecord) -> some View {
        Section(macGatewayL("任务描述")) {
            Text(verbatim: record.briefText)
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func resultSection(_ record: MacGatewayCloudTaskRecord) -> some View {
        Section(macGatewayL("执行结果")) {
            if let markdown = AmberUnifiedTaskBuilder.userFacingResultMarkdown(from: record.detail?.resultMarkdown),
               !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Button {
                            UIPasteboard.general.string = markdown
                            copiedResult = true
                        } label: {
                            Label(
                                copiedResult ? macGatewayL("已复制") : macGatewayL("复制结果"),
                                systemImage: copiedResult ? "checkmark" : "doc.on.doc"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    }
                    Text(verbatim: markdown)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(AmberTheme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            } else if record.isTerminal {
                Text(verbatim: macGatewayL("该任务已结束，暂无结果正文"))
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: macGatewayL("云端正在处理，完成后将在此处显示结果…"))
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                }
            }
        }
    }
}
