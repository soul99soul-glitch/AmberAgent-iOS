import Observation
import SwiftUI

struct NovelSessionChapterOption: Identifiable, Equatable {
    let selection: NovelChapterSelection
    let version: NovelChapterVersionRecord
    let ordinal: Int

    var id: NovelChapterID { selection.chapterID }

    var displayTitle: String {
        NovelPresentation.chapterDisplayTitle(
            storedTitle: version.title,
            content: version.content,
            ordinal: ordinal
        )
    }
}

enum NovelSessionSheetSubmissionResult: Equatable {
    case completed
    case pending(message: String)
    case failed(message: String)
}

enum NovelDiscussionArchivePreparationResult: Equatable {
    case ready(NovelDiscussionArchiveDraft)
    case failed(String)
}

private struct NovelDiscussionArchiveEditingSnapshot: Equatable {
    let decisions: [NovelDiscussionArchiveDraftDecision]
    let selectedDecisionIDs: Set<UUID>
    let summary: String
}

struct NovelDiscussionArchiveOfferSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Distill requires a synchronized, idle branch; collection always leaves needsSync.
    let isReady: Bool
    let needsSync: Bool
    let isSyncing: Bool
    let syncFailureMessage: String?
    let onRetrySync: () -> Void
    let onContinue: () -> Void

    @State private var contentHeight: CGFloat?

    var body: some View {
        // 短内容贴内容高度；避免导航容器把 sheet 撑成大白页。
        // `.fitted` 只作用于 iPad 表单，iPhone 上按量得的高度给 detent。
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AmberTheme.accent)
                Text("收录完成")
                    .font(.headline)
                Spacer(minLength: 0)
            }

            Text("正文已进书。可选把本章已确认的讨论整理成长期记忆，先给你确认再写入。")
                .font(.subheadline)
                .foregroundStyle(AmberTheme.foreground2)
                .fixedSize(horizontal: false, vertical: true)

            if isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("同步剧情中…")
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                }
            } else if let syncFailureMessage {
                Label {
                    Text(syncFailureMessage)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(AmberTheme.accentRed)
                Button("重试同步") { onRetrySync() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            } else if needsSync {
                Label("同步完成后可归档", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
                Button("开始同步") { onRetrySync() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            } else if !isReady {
                Label("其他操作结束后可归档", systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
            }

            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Text("暂不归档")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                Button {
                    onContinue()
                } label: {
                    Text("归档讨论")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isReady)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .presentationDetents(contentHeight.map { [.height($0)] } ?? [.medium])
        .presentationSizing(.fitted)
        .presentationDragIndicator(.visible)
    }
}

struct NovelDiscussionArchiveSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onPrepare: @MainActor () async -> NovelDiscussionArchivePreparationResult
    let onConfirm: @MainActor (
        NovelDiscussionArchiveDraft,
        [NovelDiscussionArchiveDraftDecision],
        String
    ) async -> Bool

    @State private var draft: NovelDiscussionArchiveDraft?
    @State private var decisions: [NovelDiscussionArchiveDraftDecision] = []
    @State private var selectedDecisionIDs: Set<UUID> = []
    @State private var summary = ""
    @State private var preparationFailureMessage: String?
    @State private var submissionFailureMessage: String?
    @State private var isPreparing = false
    @State private var isSubmitting = false
    @State private var preparationTask: Task<Void, Never>?
    @State private var editingBaseline: NovelDiscussionArchiveEditingSnapshot?
    @State private var isConfirmingDiscard = false
    @State private var imeBank = NovelIMEFieldBank()

    var body: some View {
        NavigationStack {
            Form {
                if isPreparing {
                    Section {
                        ProgressView("正在整理本轮讨论")
                    }
                } else if let preparationFailureMessage {
                    Section("整理失败") {
                        Label(preparationFailureMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AmberTheme.accentRed)
                        Button("重新整理") { prepare() }
                    }
                } else if draft != nil {
                    if let submissionFailureMessage {
                        Section("归档未保存") {
                            Label(submissionFailureMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(AmberTheme.accentRed)
                        }
                    }

                    Section("讨论摘要") {
                        NovelIMETextEditor(
                            text: $summary,
                            placeholder: IOSAppLocalization.string(
                                "讨论摘要",
                                defaultValue: "讨论摘要"
                            ),
                            minHeight: 90,
                            bank: imeBank
                        )
                        .frame(minHeight: 90)
                        Text("\(summary.count)/300")
                            .font(.caption)
                            .foregroundStyle(summary.count <= 300 ? AmberTheme.muted : AmberTheme.accentRed)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    Section("确认决定") {
                        ForEach($decisions) { $decision in
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle(
                                    "收录此决定",
                                    isOn: selectionBinding(for: decision.id)
                                )
                                NovelIMETextField(
                                    text: $decision.topic,
                                    placeholder: IOSAppLocalization.string(
                                        "决定主题",
                                        defaultValue: "决定主题"
                                    ),
                                    bank: imeBank
                                )
                                .frame(minHeight: 36)
                                NovelIMETextEditor(
                                    text: $decision.decision,
                                    placeholder: IOSAppLocalization.string(
                                        "决定内容",
                                        defaultValue: "决定内容"
                                    ),
                                    minHeight: 72,
                                    bank: imeBank
                                )
                                .frame(minHeight: 72)
                                Button(role: .destructive) {
                                    removeDecision(decision.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .disabled(isSubmitting)
            .scrollContentBackground(.hidden)
            .background(AmberTheme.background)
            .navigationTitle("归档讨论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        NovelTextInputCommitter.perform(fieldBank: imeBank) { requestDismiss() }
                    }
                        .disabled(isSubmitting)
                        .confirmationDialog(
                            "放弃归档调整？",
                            isPresented: $isConfirmingDiscard,
                            titleVisibility: .visible
                        ) {
                            Button("放弃更改", role: .destructive) {
                                cancelPreparationAndDismiss()
                            }
                            Button("继续编辑", role: .cancel) {}
                        } message: {
                            Text("尚未归档的摘要和决定修改会丢失。")
                        }
                }
                if draft != nil, preparationFailureMessage == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmedDecisions.isEmpty
                            ? "取消归档"
                            : (submissionFailureMessage == nil ? "确认归档" : "重试保存")) {
                            NovelTextInputCommitter.perform(fieldBank: imeBank) { submit() }
                        }
                        .disabled(isSubmitting)
                    }
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView("正在保存归档")
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear { prepare() }
        .onDisappear { preparationTask?.cancel() }
    }

    private var confirmedDecisions: [NovelDiscussionArchiveDraftDecision] {
        decisions.filter { selectedDecisionIDs.contains($0.id) }
    }

    private var canSubmit: Bool {
        if confirmedDecisions.isEmpty { return true }
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedSummary.isEmpty &&
            trimmedSummary.count <= 300 &&
            confirmedDecisions.allSatisfy {
                !$0.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !$0.decision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    private var hasUnsavedChanges: Bool {
        guard let editingBaseline else { return false }
        return editingBaseline != NovelDiscussionArchiveEditingSnapshot(
            decisions: decisions,
            selectedDecisionIDs: selectedDecisionIDs,
            summary: summary
        )
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedDecisionIDs.contains(id) },
            set: { selected in
                if selected {
                    selectedDecisionIDs.insert(id)
                } else {
                    selectedDecisionIDs.remove(id)
                }
            }
        )
    }

    private func removeDecision(_ id: UUID) {
        decisions.removeAll { $0.id == id }
        selectedDecisionIDs.remove(id)
    }

    private func prepare() {
        guard !isPreparing else { return }
        isPreparing = true
        preparationFailureMessage = nil
        preparationTask = Task { @MainActor in
            let result = await onPrepare()
            guard !Task.isCancelled else {
                isPreparing = false
                preparationTask = nil
                return
            }
            isPreparing = false
            preparationTask = nil
            switch result {
            case .ready(let prepared):
                draft = prepared
                decisions = prepared.decisions
                selectedDecisionIDs = Set(prepared.decisions.map(\.id))
                summary = prepared.summary
                editingBaseline = NovelDiscussionArchiveEditingSnapshot(
                    decisions: prepared.decisions,
                    selectedDecisionIDs: Set(prepared.decisions.map(\.id)),
                    summary: prepared.summary
                )
            case .failed(let message):
                preparationFailureMessage = message
            }
        }
    }

    private func cancelPreparationAndDismiss() {
        preparationTask?.cancel()
        preparationTask = nil
        dismiss()
    }

    private func requestDismiss() {
        if hasUnsavedChanges {
            isConfirmingDiscard = true
        } else {
            cancelPreparationAndDismiss()
        }
    }

    private func submit() {
        guard let draft else { return }
        let confirmed = confirmedDecisions
        guard !confirmed.isEmpty else {
            dismiss()
            return
        }
        guard canSubmit else {
            submissionFailureMessage = "请填写完整的讨论摘要和决定内容。"
            return
        }
        isSubmitting = true
        submissionFailureMessage = nil
        Task { @MainActor in
            let succeeded = await onConfirm(draft, confirmed, summary)
            isSubmitting = false
            if succeeded {
                dismiss()
            } else {
                submissionFailureMessage = "归档没有保存，请检查项目状态后重试。"
            }
        }
    }
}
