import SwiftUI

struct NovelCollectCandidateSheet: View {
    @Environment(\.dismiss) private var dismiss

    let paragraphs: [NovelParagraphRecord]
    let chapters: [NovelSessionChapterOption]
    let nextChapterOrdinal: Int
    /// 非 nil 表示这个候选来自「整章重新生成」,可以替换该章。
    let regenerationTarget: NovelSessionChapterOption?
    let onCompleted: @MainActor (NovelCollectionTarget) -> Void
    let onCollect: @MainActor (
        NovelParagraphSelection,
        NovelCollectionTarget
    ) async -> NovelSessionSheetSubmissionResult
    private let initialSelectedParagraphIDs: Set<NovelParagraphID>
    private let initialEditedText: String
    private let initialTargetChoice: NovelCollectionTargetChoice
    private let initialNextChapterTitle: String

    @State private var selectedParagraphIDs: Set<NovelParagraphID>
    @State private var editedText: String
    @State private var hasEditedText = false
    @State private var targetChoice: NovelCollectionTargetChoice
    @State private var nextChapterTitle: String
    @State private var isSubmitting = false
    @State private var submissionResult: NovelSessionSheetSubmissionResult?
    @State private var isConfirmingDiscard = false
    @State private var imeBank = NovelIMEFieldBank()
    @State private var stamp: NovelInkSealStamp?

    init(
        paragraphs: [NovelParagraphRecord],
        chapters: [NovelSessionChapterOption],
        nextChapterOrdinal: Int,
        regenerationTarget: NovelSessionChapterOption? = nil,
        suggestedGranularity: NovelGenerationGranularity,
        onCompleted: @escaping @MainActor (NovelCollectionTarget) -> Void = { _ in },
        onCollect: @escaping @MainActor (
            NovelParagraphSelection,
            NovelCollectionTarget
        ) async -> NovelSessionSheetSubmissionResult
    ) {
        self.paragraphs = paragraphs
        self.chapters = chapters
        self.nextChapterOrdinal = nextChapterOrdinal
        self.regenerationTarget = regenerationTarget
        self.onCompleted = onCompleted
        self.onCollect = onCollect
        let paragraphIDs = Set(paragraphs.map(\.id))
        let candidateText = paragraphs.map(\.text).joined(separator: "\n\n")
        let targetChoice = NovelCollectionTargetChoice.initial(
            chapterCount: chapters.count,
            granularity: suggestedGranularity,
            hasRegenerationTarget: regenerationTarget != nil
        )
        let nextOrdinal = nextChapterOrdinal
        let nextTitle = NovelPresentation.chapterDisplayTitle(
            storedTitle: "第 \(nextOrdinal) 章",
            content: candidateText,
            ordinal: nextOrdinal
        )
        self.initialSelectedParagraphIDs = paragraphIDs
        self.initialEditedText = candidateText
        self.initialTargetChoice = targetChoice
        self.initialNextChapterTitle = nextTitle
        self._selectedParagraphIDs = State(initialValue: paragraphIDs)
        self._editedText = State(initialValue: candidateText)
        self._targetChoice = State(initialValue: targetChoice)
        self._nextChapterTitle = State(initialValue: nextTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                submissionSection
                paragraphSection
                    .disabled(isSubmitting || hasDurablePending)
                previewSection
                    .disabled(isSubmitting || hasDurablePending)
                targetSection
                    .disabled(isSubmitting || hasDurablePending)
            }
            .disabled(isSubmitting)
            // The workspace refreshes the inputs once the collection lands; fade the
            // form so that reflow stays behind the seal.
            .opacity(stamp == nil ? 1 : 0.3)
            .animation(.easeOut(duration: 0.2), value: stamp)
            .scrollContentBackground(.hidden)
            .background(AmberTheme.background)
            .navigationTitle("收录正文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        NovelTextInputCommitter.perform(fieldBank: imeBank) { requestDismiss() }
                    }
                        .disabled(isSubmitting)
                        .confirmationDialog(
                            "放弃本次收录调整？",
                            isPresented: $isConfirmingDiscard,
                            titleVisibility: .visible
                        ) {
                            Button("放弃更改", role: .destructive) { dismiss() }
                            Button("继续编辑", role: .cancel) {}
                        } message: {
                            Text("尚未收录的正文编辑、段落选择和章节位置会丢失。")
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("收录") {
                        NovelTextInputCommitter.perform(fieldBank: imeBank) { collect() }
                    }
                        .disabled(isSubmitting || hasDurablePending || !canCollect)
                }
            }
            .overlay {
                if let stamp {
                    NovelInkSealView(stamp: stamp)
                } else if isSubmitting {
                    ProgressView("正在更新正文与剧情状态")
                }
            }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var submissionSection: some View {
        switch submissionResult {
        case .pending(let message):
            Section {
                Label(message, systemImage: "externaldrive.badge.checkmark")
                    .foregroundStyle(AmberTheme.foreground2)
                Button("返回创作页继续") { dismiss() }
            } header: {
                Text("正文已安全保留")
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AmberTheme.accentRed)
            } header: {
                Text("收录未完成")
            }
        case .completed, nil:
            EmptyView()
        }
    }

    private var paragraphSection: some View {
        Section {
            ForEach(paragraphs, id: \.id) { paragraph in
                Button {
                    toggle(paragraph.id)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: selectedParagraphIDs.contains(paragraph.id)
                            ? "checkmark.square.fill"
                            : "square")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(
                                selectedParagraphIDs.contains(paragraph.id)
                                    ? AmberTheme.accent
                                    : AmberTheme.muted
                            )
                            .frame(width: 24)

                        Text(paragraph.text)
                            .font(.subheadline)
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(paragraph.text)
                .accessibilityValue(
                    IOSAppLocalization.string(
                        selectedParagraphIDs.contains(paragraph.id) ? "已选择" : "未选择",
                        defaultValue: selectedParagraphIDs.contains(paragraph.id) ? "已选择" : "未选择"
                    )
                )
            }
        } header: {
            HStack {
                Text("选择段落")
                Spacer()
                Button(allSelected ? "取消全选" : "全选") {
                    setAllSelected(!allSelected)
                }
                .textCase(nil)
            }
        } footer: {
            if hasEditedText {
                Text(IOSAppLocalization.string(
                    "调整段落后会保留你的编辑；如需按当前选择重新生成正文，请点“按当前选择重置”。",
                    defaultValue: "调整段落后会保留你的编辑；如需按当前选择重新生成正文，请点“按当前选择重置”。"
                ))
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(IOSAppLocalization.string(
                    "默认收录全部段落。未选择的段落仍保留在聊天气泡中。",
                    defaultValue: "默认收录全部段落。未选择的段落仍保留在聊天气泡中。"
                ))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var previewSection: some View {
        Section {
            NovelIMETextEditor(
                text: editedTextBinding,
                placeholder: IOSAppLocalization.string(
                    "收录前编辑",
                    defaultValue: "收录前编辑"
                ),
                isEnabled: !selectedParagraphIDs.isEmpty && !isSubmitting,
                minHeight: 190,
                bank: imeBank
            )
            .frame(minHeight: 190)
            .accessibilityLabel("收录前编辑")

            if hasEditedText {
                Button {
                    resetEditedText()
                } label: {
                    Label("按当前选择重置", systemImage: "arrow.counterclockwise")
                }
                .disabled(selectedParagraphIDs.isEmpty || isSubmitting)
            }
        } header: {
            Text("收录前编辑")
        } footer: {
            Text(IOSAppLocalization.string(
                "这里的修改只影响本次收录，不会改写原聊天气泡。",
                defaultValue: "这里的修改只影响本次收录，不会改写原聊天气泡。"
            ))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var targetSection: some View {
        Section("章节位置") {
            if !chapters.isEmpty {
                Picker("收录方式", selection: $targetChoice) {
                    if let regenerationTarget {
                        Text(IOSAppLocalization.formatted(
                            "替换%@",
                            defaultValue: "替换%@",
                            arguments: [regenerationTarget.displayTitle]
                        ))
                            .tag(NovelCollectionTargetChoice.replaceChapter)
                    }
                    Text(appendCurrentLabel).tag(NovelCollectionTargetChoice.appendCurrent)
                    Text(IOSAppLocalization.formatted(
                        "新开第 %lld 章",
                        defaultValue: "新开第 %lld 章",
                        arguments: [nextChapterOrdinal]
                    ))
                        .tag(NovelCollectionTargetChoice.createNext)
                }
                .pickerStyle(.segmented)
                .disabled(isSubmitting)
            }

            if targetChoice == .replaceChapter, let regenerationTarget {
                LabeledContent("将替换", value: regenerationTarget.displayTitle)
                Text("原版本会保留在该章的版本历史里。因为重写允许改变剧情，"
                    + "回到旧版本需要在版本历史里用「以手工编辑恢复」，不能直接回滚。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            } else if targetChoice == .appendCurrent, let chapter = chapters.last {
                LabeledContent("当前章节", value: chapter.displayTitle)
            } else {
                NovelIMETextField(
                    text: $nextChapterTitle,
                    placeholder: IOSAppLocalization.string(
                        "章节标题",
                        defaultValue: "章节标题"
                    ),
                    isEnabled: !isSubmitting,
                    bank: imeBank
                )
                .frame(minHeight: 36)
            }
        }
    }

    private var allSelected: Bool {
        !paragraphs.isEmpty && selectedParagraphIDs.count == paragraphs.count
    }

    private var canCollect: Bool {
        guard !selectedParagraphIDs.isEmpty,
              !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if targetChoice == .createNext {
            return !nextChapterTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if targetChoice == .replaceChapter {
            return regenerationTarget != nil
        }
        return chapters.last != nil
    }

    private var hasDurablePending: Bool {
        if case .pending = submissionResult { return true }
        return false
    }

    private var shouldConfirmDiscard: Bool {
        hasUnsavedChanges && !hasDurablePending
    }

    private var hasUnsavedChanges: Bool {
        selectedParagraphIDs != initialSelectedParagraphIDs ||
            editedText != initialEditedText ||
            targetChoice != initialTargetChoice ||
            nextChapterTitle != initialNextChapterTitle
    }

    private var appendCurrentLabel: String {
        guard let chapter = chapters.last else {
            return IOSAppLocalization.string("并入当前章", defaultValue: "并入当前章")
        }
        let title = chapter.version.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == "第 \(chapter.ordinal) 章" {
            return IOSAppLocalization.formatted(
                "并入第 %lld 章",
                defaultValue: "并入第 %lld 章",
                arguments: [chapter.ordinal]
            )
        }
        return IOSAppLocalization.formatted(
            "并入第 %lld 章《%@》",
            defaultValue: "并入第 %lld 章《%@》",
            arguments: [chapter.ordinal, title]
        )
    }

    private var selectedText: String {
        paragraphs
            .filter { selectedParagraphIDs.contains($0.id) }
            .map(\.text)
            .joined(separator: "\n\n")
    }

    private var editedTextBinding: Binding<String> {
        Binding(
            get: { editedText },
            set: { value in
                editedText = value
                hasEditedText = value != selectedText
            }
        )
    }

    private func toggle(_ paragraphID: NovelParagraphID) {
        if selectedParagraphIDs.contains(paragraphID) {
            selectedParagraphIDs.remove(paragraphID)
        } else {
            selectedParagraphIDs.insert(paragraphID)
        }
        refreshEditedTextAfterSelectionChange()
    }

    private func setAllSelected(_ selected: Bool) {
        selectedParagraphIDs = selected ? Set(paragraphs.map(\.id)) : []
        refreshEditedTextAfterSelectionChange()
    }

    private func refreshEditedTextAfterSelectionChange() {
        guard !hasEditedText else { return }
        // Mid-IME composition may not yet be reflected in `editedText`, so
        // hasEditedText is still false. Resetting here would clobber the
        // TextEditor and drop the last marked glyphs.
        if imeBank.hasAnyMarkedText || NovelTextInputCommitter.hasMarkedText() {
            NovelTextInputCommitter.perform(fieldBank: imeBank) {
                if editedText != selectedText {
                    hasEditedText = true
                } else {
                    resetEditedText()
                }
            }
            return
        }
        resetEditedText()
    }

    private func resetEditedText() {
        editedText = selectedText
        hasEditedText = false
    }

    private func collect() {
        guard canCollect else {
            submissionResult = .failed(message: "请选择正文并填写完整的章节信息。")
            return
        }
        let orderedIDs = paragraphs
            .filter { selectedParagraphIDs.contains($0.id) }
            .map(\.id)
        let selection = NovelParagraphSelection(
            paragraphIDs: orderedIDs,
            editedText: editedText == selectedText ? nil : editedText
        )
        let target: NovelCollectionTarget
        switch targetChoice {
        case .appendCurrent:
            guard let chapterID = chapters.last?.selection.chapterID else { return }
            target = .appendToChapter(chapterID)
        case .replaceChapter:
            guard let chapterID = regenerationTarget?.selection.chapterID else { return }
            target = .replaceChapter(chapterID)
        case .createNext:
            target = .createNextChapter(
                chapterID: NovelChapterID(),
                title: nextChapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        isSubmitting = true
        submissionResult = nil
        let previousTotal = manuscriptCharacterCount
        let newTotal = manuscriptCharacterCount(after: target)
        Task { @MainActor in
            let result = await onCollect(selection, target)
            submissionResult = result
            guard result == .completed else {
                isSubmitting = false
                return
            }
            if let stamp = NovelInkSealStamp.after(
                collecting: target,
                previousTotal: previousTotal,
                newTotal: newTotal,
                nextChapterOrdinal: nextChapterOrdinal
            ) {
                // Stays submitting so the form remains locked while the seal lands.
                self.stamp = stamp
                // Long enough for VoiceOver to finish the announcement.
                try? await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 3 : 1.3))
            }
            isSubmitting = false
            onCompleted(target)
            dismiss()
        }
    }

    private var manuscriptCharacterCount: Int {
        chapters.reduce(0) { $0 + $1.version.content.count }
    }

    private func manuscriptCharacterCount(after target: NovelCollectionTarget) -> Int {
        guard case .replaceChapter(let chapterID) = target else {
            return manuscriptCharacterCount + editedText.count
        }
        let replaced = chapters.first { $0.selection.chapterID == chapterID }?.version.content.count ?? 0
        return manuscriptCharacterCount - replaced + editedText.count
    }

    private func requestDismiss() {
        if shouldConfirmDiscard {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

}

enum NovelCollectionTargetChoice: String, Hashable {
    case appendCurrent
    case createNext
    /// 「整章重新生成」专用:替换来源章节,而不是追加或新建。
    case replaceChapter

    static func initial(
        chapterCount: Int,
        granularity: NovelGenerationGranularity,
        hasRegenerationTarget: Bool
    ) -> NovelCollectionTargetChoice {
        // 重新生成的候选默认就是替换来源章——那是发起这次生成的本意。
        if hasRegenerationTarget { return .replaceChapter }
        guard chapterCount > 0 else { return .createNext }
        return granularity == .wholeChapter ? .createNext : .appendCurrent
    }
}
