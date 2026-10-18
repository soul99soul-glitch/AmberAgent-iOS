import SwiftUI

private func localized(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}

func novelSessionLocalizedNumber(_ value: Int) -> String {
    value.formatted(.number.locale(IOSAppLanguagePreference.selected().resolvedLocale()))
}

struct NovelAskUserCard: View {
    let presentation: NovelAskUserPresentation
    let isSubmittingChapterRevision: Bool
    let blocker: NovelSessionActionBlocker?
    let onSubmit: (String) -> Void

    @State private var selectedOption: String?
    @State private var customValue = ""
    @State private var validationMessage: String?
    @State private var imeBank = NovelIMEFieldBank()

    var body: some View {
        if presentation.prompt.ghostwritePlan != nil {
            NovelGhostwritePlanCard(
                presentation: presentation,
                blocker: blocker,
                onSubmit: onSubmit
            )
        } else if presentation.prompt.chapterRevision != nil {
            NovelChapterRevisionCard(
                presentation: presentation,
                isSubmitting: isSubmittingChapterRevision,
                blocker: blocker,
                onSubmit: onSubmit
            )
        } else if presentation.prompt.workspacePlot != nil {
            NovelWorkspacePlotCard(
                presentation: presentation,
                blocker: blocker,
                onSubmit: onSubmit
            )
        } else if presentation.prompt.manuscriptRevert != nil {
            NovelManuscriptRevertCard(
                presentation: presentation,
                blocker: blocker,
                onSubmit: onSubmit
            )
        } else if presentation.prompt.manuscriptDelete != nil {
            NovelManuscriptDeleteCard(
                presentation: presentation,
                blocker: blocker,
                onSubmit: onSubmit
            )
        } else {
            askUserBody
        }
    }

    private var askUserBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                localized(presentation.isAnswered ? "已回答" : "需要你决定"),
                systemImage: presentation.isAnswered
                    ? "checkmark.circle.fill"
                    : "questionmark.bubble.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(presentation.isAnswered ? AmberTheme.accentGreen : AmberTheme.accent)

            if let response = presentation.response {
                Text(response.answer)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground2)
            } else {
                questionEditor
                    .disabled(blocker != nil)

                if let blocker {
                    Text(localized(blocker.displayName))
                        .font(.caption)
                        .foregroundStyle(AmberTheme.foreground2)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.accentRed)
                }

                Button(localized("确认选择")) {
                    NovelTextInputCommitter.perform(fieldBank: imeBank) { submit() }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
                .disabled(blocker != nil)
            }
        }
        .padding(16)
        .amberGlass(cornerRadius: 18, interactive: false)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.accent.opacity(0.18), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var questionEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(presentation.prompt.question)
                .font(.body.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(presentation.prompt.options, id: \.self) { option in
                Button {
                    select(option)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedOption == option
                            ? "checkmark.circle.fill"
                            : "circle")
                            .foregroundStyle(selectedOption == option
                                ? AmberTheme.accent
                                : AmberTheme.muted)
                        Text(option)
                            .foregroundStyle(AmberTheme.foreground)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(
                        selectedOption == option
                            ? AmberTheme.accentTint
                            : AmberTheme.surface,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }

            NovelIMETextEditor(
                text: customInput,
                placeholder: presentation.prompt.options.isEmpty
                    ? localized("输入你的想法")
                    : localized("或者直接输入自己的选择"),
                isEnabled: blocker == nil,
                minHeight: 72,
                bank: imeBank
            )
            .frame(minHeight: 72)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var answer: String {
        let custom = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? selectedOption ?? "" : custom
    }

    private func select(_ option: String) {
        customValue = ""
        selectedOption = option
        validationMessage = nil
    }

    private func submit() {
        let committedAnswer = answer
        guard !committedAnswer.isEmpty else {
            validationMessage = localized("请选择一个选项或输入你的想法。")
            return
        }
        validationMessage = nil
        onSubmit(committedAnswer)
    }

    private var customInput: Binding<String> {
        Binding(
            get: { customValue },
            set: {
                customValue = $0
                if !$0.isEmpty { selectedOption = nil }
                if !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    validationMessage = nil
                }
            }
        )
    }
}

/// 审批卡「审批 → 结果」原地变形的共享外壳：五张审批卡共用同一条弹簧、
/// 同一套收起过渡与描边转色，保证观感一致。卡片高度随内容收拢，不做额外
/// 高度补偿。成功触感由 ViewModel 在写入落定后发出（卡片本身是乐观变形）。
/// 系统「减弱动态效果」开启时降级为短淡入淡出，不缩放。
private enum NovelApprovalCollapseEdge {
    /// 审批态独有的正文/详情：向上收起。
    case content
    /// 按钮区：向下收起。
    case controls
}

private struct NovelApprovalCollapseModifier: ViewModifier {
    let edge: NovelApprovalCollapseEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(transition)
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return switch edge {
        case .content: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
        case .controls: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
        }
    }
}

private struct NovelApprovalMorphModifier: ViewModifier {
    let answer: String?
    let isApproved: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // 与 amberGlass 内部同源的主题圆角，裁剪、玻璃与描边三条边重合。
        let shape = RoundedRectangle(cornerRadius: AmberTheme.controlRadius(18), style: .continuous)
        content
            .padding(16)
            // 收拢过程中正在淡出的内容不得溢出正在缩小的卡片。
            .clipShape(shape)
            .amberGlass(cornerRadius: 18, interactive: false)
            .overlay {
                shape
                    .stroke(
                        isApproved
                            ? AmberTheme.accentGreen.opacity(0.35)
                            : AmberTheme.accent.opacity(0.18),
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            }
            .animation(
                reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.12),
                value: answer
            )
    }
}

private extension View {
    func novelApprovalMorph(answer: String?, isApproved: Bool) -> some View {
        modifier(NovelApprovalMorphModifier(answer: answer, isApproved: isApproved))
    }

    func novelApprovalCollapse(_ edge: NovelApprovalCollapseEdge) -> some View {
        modifier(NovelApprovalCollapseModifier(edge: edge))
    }

    /// 结果文字等按钮区淡出后再浮现，避免与正在收起的控件叠在一起。
    func novelApprovalResultAppear() -> some View {
        transition(.asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)),
            removal: .opacity
        ))
    }

    /// 状态标题的图标在审批 → 结果时上下翻转替换。
    func novelApprovalStatusTransition() -> some View {
        contentTransition(.symbolEffect(.replace.downUp))
    }
}

private struct NovelGhostwritePlanCard: View {
    let presentation: NovelAskUserPresentation
    let blocker: NovelSessionActionBlocker?
    let onSubmit: (String) -> Void

    @State private var selectedChapterCount: Int

    init(
        presentation: NovelAskUserPresentation,
        blocker: NovelSessionActionBlocker?,
        onSubmit: @escaping (String) -> Void
    ) {
        self.presentation = presentation
        self.blocker = blocker
        self.onSubmit = onSubmit
        _selectedChapterCount = State(initialValue: NovelGhostwriteBatch.clamp(
            presentation.prompt.ghostwritePlan?.suggestedChapterCount
                ?? NovelGhostwriteBatch.minChapterCount
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(statusTitle, systemImage: statusSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .novelApprovalStatusTransition()

            if let proposal = presentation.prompt.ghostwritePlan {
                Text(presentation.prompt.question)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)

                if let reason = proposal.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.foreground2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !proposal.outlinePlacement.isEmpty {
                    planTextSection(title: "剧情位置", text: proposal.outlinePlacement)
                }
                planTextSection(title: "本章目标与冲突", text: proposal.goalAndConflict)
                planListSection(title: "本章必须发生", items: proposal.mustHappen)
                if !proposal.mustNotHappen.isEmpty {
                    planListSection(title: "本章不要发生", items: proposal.mustNotHappen)
                }
                if !proposal.endingHook.isEmpty {
                    planTextSection(title: "章末钩子", text: proposal.endingHook)
                }
                if !proposal.visibleFacts.isEmpty {
                    planListSection(title: "视角可知事实", items: proposal.visibleFacts)
                }
                if !proposal.upcomingArc.isEmpty {
                    planListSection(title: "后续剧情参考", items: proposal.upcomingArc)
                }
            }

            if let response = presentation.response {
                Text(response.answer)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground2)
                    .novelApprovalResultAppear()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    chapterCountControl
                        .disabled(blocker != nil)

                    if let blocker {
                        Text(localized(blocker.displayName))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.foreground2)
                    }

                    HStack(spacing: 10) {
                        Button {
                            onSubmit(NovelGhostwritePlanApproval.rejectOption)
                        } label: {
                            Text(verbatim: localized(NovelGhostwritePlanApproval.rejectOption))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .contentShape(Rectangle())

                        Button {
                            onSubmit(NovelGhostwritePlanApproval.approvedAnswer(
                                chapterCount: selectedChapterCount
                            ))
                        } label: {
                            Text(verbatim: IOSAppLocalization.formatted(
                                "开始写 %@ 章",
                                defaultValue: "开始写 %@ 章",
                                arguments: [novelSessionLocalizedNumber(selectedChapterCount)]
                            ))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .contentShape(Rectangle())
                    }
                    .disabled(blocker != nil)
                }
                .novelApprovalCollapse(.controls)
            }
        }
        .novelApprovalMorph(answer: presentation.response?.answer, isApproved: isApproved)
    }

    private var chapterCountControl: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localized("这批代笔"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                Text(localized("批内尚未完成时会自动规划下一章，有后续参考时优先采用"))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.foreground2)
            }
            Spacer(minLength: 8)
            Text(verbatim: IOSAppLocalization.formatted(
                "%@ 章",
                defaultValue: "%@ 章",
                arguments: [novelSessionLocalizedNumber(selectedChapterCount)]
            ))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(AmberTheme.accent)
            Stepper(
                localized("代笔章数"),
                value: $selectedChapterCount,
                in: NovelGhostwriteBatch.minChapterCount...NovelGhostwriteBatch.maxChapterCount
            )
            .labelsHidden()
            .accessibilityLabel(localized("代笔章数"))
            .accessibilityValue(IOSAppLocalization.formatted(
                "%@ 章",
                defaultValue: "%@ 章",
                arguments: [novelSessionLocalizedNumber(selectedChapterCount)]
            ))
        }
        .padding(12)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func planTextSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(localized(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func planListSection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(localized(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("• \(item)")
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isApproved: Bool {
        presentation.response.map {
            NovelGhostwritePlanApproval.approvedChapterCount(from: $0.answer) != nil
        } ?? false
    }

    private var statusTitle: String {
        guard let answer = presentation.response?.answer else { return localized("代笔计划审批") }
        if let count = NovelGhostwritePlanApproval.approvedChapterCount(from: answer) {
            return IOSAppLocalization.formatted(
                "已开始代笔 %@ 章",
                defaultValue: "已开始代笔 %@ 章",
                arguments: [novelSessionLocalizedNumber(count)]
            )
        }
        if answer == NovelGhostwritePlanApproval.rejectOption { return localized("已暂不开始") }
        return localized("已回答")
    }

    private var statusSymbol: String {
        guard let answer = presentation.response?.answer else { return "list.clipboard" }
        if NovelGhostwritePlanApproval.approvedChapterCount(from: answer) != nil {
            return "checkmark.circle.fill"
        }
        if answer == NovelGhostwritePlanApproval.rejectOption { return "pause.circle.fill" }
        return "questionmark.circle.fill"
    }

    private var statusColor: Color {
        guard let answer = presentation.response?.answer else { return AmberTheme.accent }
        if NovelGhostwritePlanApproval.approvedChapterCount(from: answer) != nil {
            return AmberTheme.accentGreen
        }
        return AmberTheme.foreground2
    }
}

private struct NovelChapterRevisionCard: View {
    let presentation: NovelAskUserPresentation
    let isSubmitting: Bool
    let blocker: NovelSessionActionBlocker?
    let onSubmit: (String) -> Void

    private var isApproved: Bool {
        presentation.response?.answer == NovelChapterRevisionApproval.approveOption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(statusTitle, systemImage: statusSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .novelApprovalStatusTransition()

            if let revision = presentation.prompt.chapterRevision {
                Text(rangeCaption(revision))
                    .font(.body.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)

                if let reason = revision.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.foreground2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if presentation.response == nil {
                    VStack(alignment: .leading, spacing: 14) {
                        revisionBlock(title: "原文", text: revision.oldText)
                        revisionBlock(title: "改为", text: revision.newText)
                    }
                    .novelApprovalCollapse(.content)
                }
            }

            if let response = presentation.response,
               response.answer != NovelChapterRevisionApproval.approveOption,
               response.answer != NovelChapterRevisionApproval.rejectOption {
                Text(response.answer)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground2)
                    .novelApprovalResultAppear()
            }

            if presentation.response == nil {
                approvalControls
                    .novelApprovalCollapse(.controls)
            }
        }
        .novelApprovalMorph(answer: presentation.response?.answer, isApproved: isApproved)
    }

    @ViewBuilder
    private var approvalControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            // DEAD-CODE?: answerAskUser 在提交前就乐观写入 response，此控件区随即收起，
            // 提交中这一分支实际不可见。仅标记，删除需授权。
            if isSubmitting {
                ProgressView("正在保存改写")
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
            } else if let blocker {
                Text(localized(blocker.displayName))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.foreground2)
            }
            HStack(spacing: 10) {
                Button {
                    onSubmit(NovelChapterRevisionApproval.rejectOption)
                } label: {
                    Text(verbatim: localized(NovelChapterRevisionApproval.rejectOption))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .contentShape(Rectangle())

                Button {
                    onSubmit(NovelChapterRevisionApproval.approveOption)
                } label: {
                    Text(verbatim: localized(NovelChapterRevisionApproval.approveOption))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .contentShape(Rectangle())
            }
            .disabled(blocker != nil || isSubmitting)
        }
    }

    private var statusTitle: String {
        guard let answer = presentation.response?.answer else { return localized("改正文审批") }
        if answer == NovelChapterRevisionApproval.approveOption { return localized("已写入正文") }
        if answer == NovelChapterRevisionApproval.rejectOption { return localized("已拒绝这次修改") }
        return localized("已回答")
    }

    private var statusSymbol: String {
        switch presentation.response?.answer {
        case NovelChapterRevisionApproval.approveOption: "checkmark.circle.fill"
        case NovelChapterRevisionApproval.rejectOption: "xmark.circle.fill"
        default: "square.and.pencil"
        }
    }

    private var statusColor: Color {
        switch presentation.response?.answer {
        case NovelChapterRevisionApproval.approveOption: AmberTheme.accentGreen
        case NovelChapterRevisionApproval.rejectOption: AmberTheme.foreground2
        default: AmberTheme.accent
        }
    }

    private func rangeCaption(_ revision: NovelChapterRevisionProposal) -> String {
        let range = revision.startParagraph == revision.endParagraph
            ? IOSAppLocalization.formatted(
                "第 %@ 段",
                defaultValue: "第 %@ 段",
                arguments: [novelSessionLocalizedNumber(revision.startParagraph)]
            )
            : IOSAppLocalization.formatted(
                "第 %@–%@ 段",
                defaultValue: "第 %@–%@ 段",
                arguments: [
                    novelSessionLocalizedNumber(revision.startParagraph),
                    novelSessionLocalizedNumber(revision.endParagraph)
                ]
            )
        return IOSAppLocalization.formatted(
            "第 %@ 章 · %@ · %@",
            defaultValue: "第 %@ 章 · %@ · %@",
            arguments: [
                novelSessionLocalizedNumber(revision.chapterOrdinal),
                revision.chapterTitle,
                range
            ]
        )
    }

    private func revisionBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
            ScrollView {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AmberTheme.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}

private struct NovelWorkspacePlotCard: View {
    let presentation: NovelAskUserPresentation
    let blocker: NovelSessionActionBlocker?
    let onSubmit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(statusTitle, systemImage: statusSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .novelApprovalStatusTransition()

            Text(presentation.prompt.question)
                .font(.body.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = presentation.prompt.workspacePlot?.reason, !reason.isEmpty {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if presentation.response == nil {
                VStack(alignment: .leading, spacing: 14) {
                    if let blocker {
                        Text(localized(blocker.displayName))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.foreground2)
                    }
                    HStack(spacing: 10) {
                        Button {
                            onSubmit(NovelWorkspacePlotApproval.rejectOption)
                        } label: {
                            Text(verbatim: localized(NovelWorkspacePlotApproval.rejectOption))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .contentShape(Rectangle())

                        Button {
                            onSubmit(NovelWorkspacePlotApproval.approveOption)
                        } label: {
                            Text(verbatim: localized(NovelWorkspacePlotApproval.approveOption))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .contentShape(Rectangle())
                    }
                    .disabled(blocker != nil)
                }
                .novelApprovalCollapse(.controls)
            }
        }
        .novelApprovalMorph(answer: presentation.response?.answer, isApproved: isApproved)
    }

    private var isApproved: Bool {
        presentation.response?.answer == NovelWorkspacePlotApproval.approveOption
    }

    private var statusTitle: String {
        guard let answer = presentation.response?.answer else { return localized("写剧情审批") }
        if answer == NovelWorkspacePlotApproval.approveOption { return localized("已写入剧情") }
        if answer == NovelWorkspacePlotApproval.rejectOption { return localized("已拒绝这次修改") }
        return localized("已回答")
    }

    private var statusSymbol: String {
        switch presentation.response?.answer {
        case NovelWorkspacePlotApproval.approveOption: "checkmark.circle.fill"
        case NovelWorkspacePlotApproval.rejectOption: "xmark.circle.fill"
        default: "doc.text"
        }
    }

    private var statusColor: Color {
        switch presentation.response?.answer {
        case NovelWorkspacePlotApproval.approveOption: AmberTheme.accentGreen
        case NovelWorkspacePlotApproval.rejectOption: AmberTheme.foreground2
        default: AmberTheme.accent
        }
    }
}

private struct NovelManuscriptRevertCard: View {
    let presentation: NovelAskUserPresentation
    let blocker: NovelSessionActionBlocker?
    let onSubmit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(statusTitle, systemImage: statusSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .novelApprovalStatusTransition()

            Text(presentation.prompt.question)
                .font(.body.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = presentation.prompt.manuscriptRevert?.reason, !reason.isEmpty {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if presentation.response == nil {
                VStack(alignment: .leading, spacing: 14) {
                    if let blocker {
                        Text(localized(blocker.displayName))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.foreground2)
                    }
                    HStack(spacing: 10) {
                        Button {
                            onSubmit(NovelManuscriptRevertApproval.rejectOption)
                        } label: {
                            Text(verbatim: localized(NovelManuscriptRevertApproval.rejectOption))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .contentShape(Rectangle())

                        Button {
                            onSubmit(NovelManuscriptRevertApproval.approveOption)
                        } label: {
                            Text(verbatim: localized(NovelManuscriptRevertApproval.approveOption))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .contentShape(Rectangle())
                    }
                    .disabled(blocker != nil)
                }
                .novelApprovalCollapse(.controls)
            }
        }
        .novelApprovalMorph(answer: presentation.response?.answer, isApproved: isApproved)
    }

    private var isApproved: Bool {
        presentation.response?.answer == NovelManuscriptRevertApproval.approveOption
    }

    private var statusTitle: String {
        guard let answer = presentation.response?.answer else { return localized("回退章节审批") }
        if answer == NovelManuscriptRevertApproval.approveOption { return localized("已回退这几章") }
        if answer == NovelManuscriptRevertApproval.rejectOption { return localized("已取消回退") }
        return localized("已回答")
    }

    private var statusSymbol: String {
        switch presentation.response?.answer {
        case NovelManuscriptRevertApproval.approveOption: "checkmark.circle.fill"
        case NovelManuscriptRevertApproval.rejectOption: "xmark.circle.fill"
        default: "arrow.uturn.backward"
        }
    }

    private var statusColor: Color {
        switch presentation.response?.answer {
        case NovelManuscriptRevertApproval.approveOption: AmberTheme.accentGreen
        case NovelManuscriptRevertApproval.rejectOption: AmberTheme.foreground2
        default: AmberTheme.accent
        }
    }
}

private struct NovelManuscriptDeleteCard: View {
    let presentation: NovelAskUserPresentation
    let blocker: NovelSessionActionBlocker?
    let onSubmit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(statusTitle, systemImage: statusSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .novelApprovalStatusTransition()

            Text(presentation.prompt.question)
                .font(.body.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = presentation.prompt.manuscriptDelete?.reason, !reason.isEmpty {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if presentation.response == nil {
                VStack(alignment: .leading, spacing: 14) {
                    if let blocker {
                        Text(localized(blocker.displayName))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.foreground2)
                    }
                    HStack(spacing: 10) {
                        Button {
                            onSubmit(NovelManuscriptDeleteApproval.rejectOption)
                        } label: {
                            Text(verbatim: localized(NovelManuscriptDeleteApproval.rejectOption))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .contentShape(Rectangle())

                        Button {
                            onSubmit(NovelManuscriptDeleteApproval.approveOption)
                        } label: {
                            Text(verbatim: localized(NovelManuscriptDeleteApproval.approveOption))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .contentShape(Rectangle())
                    }
                    .disabled(blocker != nil)
                }
                .novelApprovalCollapse(.controls)
            }
        }
        .novelApprovalMorph(answer: presentation.response?.answer, isApproved: isApproved)
    }

    private var isApproved: Bool {
        presentation.response?.answer == NovelManuscriptDeleteApproval.approveOption
    }

    private var statusTitle: String {
        guard let answer = presentation.response?.answer else { return localized("抽章审批") }
        if answer == NovelManuscriptDeleteApproval.approveOption { return localized("已从正文目录删除") }
        if answer == NovelManuscriptDeleteApproval.rejectOption { return localized("已取消这次删除") }
        return localized("已回答")
    }

    private var statusSymbol: String {
        switch presentation.response?.answer {
        case NovelManuscriptDeleteApproval.approveOption: "checkmark.circle.fill"
        case NovelManuscriptDeleteApproval.rejectOption: "xmark.circle.fill"
        default: "trash"
        }
    }

    private var statusColor: Color {
        switch presentation.response?.answer {
        case NovelManuscriptDeleteApproval.approveOption: AmberTheme.accentGreen
        case NovelManuscriptDeleteApproval.rejectOption: AmberTheme.foreground2
        default: AmberTheme.accent
        }
    }
}
