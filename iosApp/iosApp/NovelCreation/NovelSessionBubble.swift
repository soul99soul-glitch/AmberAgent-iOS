import SwiftUI

private func localized(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}

private func localizedNumber(_ value: Int) -> String {
    value.formatted(.number.locale(IOSAppLanguagePreference.selected().resolvedLocale()))
}

struct NovelSessionBubble: View {
    let messageID: NovelMessageID
    let role: NovelSessionRole
    let kind: NovelSessionMessageKind
    let granularity: NovelGenerationGranularity?
    let content: String
    /// Presentation-only thinking; never mixed into `content` / candidates.
    var reasoningContent: String = ""
    var isReasoningLive: Bool = false
    let isStreaming: Bool
    let transientPhase: NovelSessionTransientTailPhase?
    /// True only for the row that actually streamed in this presentation.
    let hasEverStreamed: Bool
    let runStatus: NovelRunStatus?
    let candidateStatus: NovelCandidateStatus?
    /// 该候选来自「整章重新生成」:收录后替换原章,而不是新开一章。
    /// 判据是 prose 候选带着来源章版本(只有重写会带)。
    let isRegeneration: Bool
    let polishTransactionStatus: NovelPolishTransactionStatus?
    /// 该候选正在被采用（漂移检查模型调用中）。
    let isAdoptingPolish: Bool
    let committedChange: NovelSessionCommittedChangeSummary?
    let askUser: NovelAskUserPresentation?
    var isSubmittingChapterRevision: Bool = false
    var askUserBlocker: NovelSessionActionBlocker? = nil
    var runtimeActionBlocker: NovelSessionActionBlocker? = nil
    var retryingPolishTransactionID: NovelPendingOperationID? = nil
    var onCancelPolishRetry: () -> Void = {}
    let actions: [NovelSessionRowActionAvailability]
    let onAction: (NovelSessionRowAction) -> Void
    let onAnswerAskUser: (NovelMessageID, String) -> Void

    var body: some View {
        switch role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .system:
            systemMessage
        }
    }

    /// Candidate manuscript should never render as Chat code cards when the model
    /// mistakenly wraps it in ```html / ```markdown fences.
    ///
    /// Streaming tails already enter the buffer pre-normalized (same string the
    /// pacer advances). Only durable/completed rows still need a full strip.
    private static func displayMarkdown(
        _ content: String,
        kind: NovelSessionMessageKind,
        isStreaming: Bool
    ) -> String {
        switch kind {
        case .proseCandidate, .polishCandidate, .interruptedDraft:
            return isStreaming
                ? content
                : NovelPromptCatalog.normalizedCandidateProse(content)
        case .discussion, .userInput, .error:
            return content
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 44)
            ChatUserBubble(text: content)
                .frame(maxWidth: ChatLayout.userMaxWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.vertical, ChatLayout.userMessageRowVerticalPadding)
    }

    private var hasVisibleReasoning: Bool {
        ChatReasoningCard.hasVisibleText(reasoningContent)
    }

    private var displayedContent: String {
        guard kind == .error ||
                (kind == .interruptedDraft && runStatus == .failed) else {
            return content
        }
        return NovelPresentation.localizedCachedErrorMessage(content)
    }

    @ViewBuilder
    private var assistantBubble: some View {
        if isStreaming && content.isEmpty && !hasVisibleReasoning {
            ChatAssistantPendingResponseView(label: { elapsed in
                NovelSessionPendingPresentation.label(for: transientPhase, elapsed: elapsed)
            })
        } else {
            ChatAssistantStack {
                ChatAgentName()

                if hasVisibleReasoning {
                    ChatReasoningCard(
                        bodyText: reasoningContent,
                        isThinking: isReasoningLive,
                        autoCloseThinking: true
                    )
                }

                if content.isEmpty, askUser == nil, !hasVisibleReasoning {
                    ChatAssistantText {
                        Text(emptyAssistantText)
                            .foregroundStyle(AmberTheme.muted)
                    }
                } else if !displayedContent.isEmpty {
                    // Always parse markdown — never show raw `**` / `#` markers.
                    // Match Chat: isStreaming drives animation; hasEverStreamed (from
                    // parent sticky IDs) keeps block renderer across complete.
                    let markdown = Self.displayMarkdown(
                        displayedContent,
                        kind: kind,
                        isStreaming: isStreaming
                    )
                    ChatAssistantMarkdownView(
                        markdown: markdown,
                        renderCacheNamespace: "novel:session:\(messageID)",
                        isStreaming: isStreaming,
                        hasEverStreamed: hasEverStreamed
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let askUser {
                    NovelAskUserCard(
                        presentation: askUser,
                        isSubmittingChapterRevision: isSubmittingChapterRevision,
                        blocker: askUserBlocker
                    ) { answers in
                        onAnswerAskUser(messageID, answers)
                    }
                }

                statusLine
                    .font(.caption)

                if !effectiveActions.isEmpty {
                    actionBar
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if case .some(.persistenceBlocked) = transientPhase {
            Label(localized("回复已生成，等待重试保存"), systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(AmberTheme.foreground2)
        } else if transientPhase == .terminalAwaitingRefresh {
            // Prose/polish (incl. regenerate): dock strip owns this caption.
            // Discussion and other kinds have no strip — keep the bubble cue.
            if kind != .proseCandidate && kind != .polishCandidate {
                Label(localized("正在保存创作记录"), systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(AmberTheme.muted)
            }
        } else if representsFailure {
            Label(
                localized(content.isEmpty
                    ? "生成失败 · 正文与剧情状态未改变"
                    : "生成失败 · 已保留草稿，正文与剧情状态未改变"),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(AmberTheme.accentRed)
        } else if transientPhase == .interrupted ||
                    runStatus == .interrupted ||
                    kind == .interruptedDraft {
            let canCollect = effectiveActions.contains {
                if case .collectProse = $0.action { return $0.isEnabled }
                return false
            }
            Label(
                localized(canCollect ? "生成已中断 · 可收录已生成部分" : "生成已中断"),
                systemImage: "pause.circle"
            )
            .foregroundStyle(AmberTheme.foreground2)
        } else {
            switch kind {
            case .proseCandidate:
                if committedChange != nil {
                    Label(localized("已收录为正式正文"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AmberTheme.accentGreen)
                } else if !isStreaming {
                    // 生成中不在气泡里挂候选状态行:它跟在不断增长的正文下方,
                    // 每次增长都要重新布局并被跟随逻辑推着走,表现为小幅上下抖动。
                    // 生成期间改由输入框上方的常驻状态条承担(NovelSessionView)。
                    proseCandidateStatus
                }
            case .polishCandidate:
                if committedChange != nil {
                    Label(localized("润色版已采用"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(AmberTheme.accentGreen)
                } else if !isStreaming {
                    // 与正文候选同一理由:生成中状态行跟在增长的正文下方会被
                    // 反复重新布局并被跟随逻辑推动,表现为小幅上下抖动。
                    polishCandidateStatus
                }
            case .discussion, .userInput, .interruptedDraft, .error:
                EmptyView()
            }
        }
    }

    private var emptyAssistantText: String {
        if representsFailure {
            return localized("生成失败，未输出正文")
        }
        if transientPhase == .interrupted || kind == .interruptedDraft {
            return localized("生成在输出内容前已中断")
        }
        return localized("正在准备回复")
    }

    private var representsFailure: Bool {
        if runStatus == .failed || kind == .error { return true }
        if case .some(.failed) = transientPhase { return true }
        return false
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    actionButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    actionButtons
                }
            }

            if let blocker = Self.sharedActionBarBlocker(effectiveActions) {
                Text(localized(blocker.displayName))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.foreground2)
            } else if committedChange?.branchSyncStatus == .synchronized {
                // committedChange is only non-nil for a committed row, so this never
                // renders on discussion/plain-message rows. See branchSyncStatus's doc
                // comment in NovelSessionPresentation.swift for why this is a
                // branch-level fact (shared by every committed row) rather than a
                // per-row history stamp.
                Label(localized("剧情状态已同步"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentGreen)
            }
        }
        .padding(.top, 2)
    }

    private var actionButtons: some View {
        NovelSessionActionButtons(
            actions: effectiveActions,
            granularity: granularity,
            retryingPolishTransactionID: retryingPolishTransactionID,
            onCancelPolishRetry: onCancelPolishRetry,
            onAction: onAction
        )
    }

    private var effectiveActions: [NovelSessionRowActionAvailability] {
        actions.map { item in
            guard item.blocker == nil,
                  item.action.requiresMutation,
                  let runtimeActionBlocker else { return item }
            return NovelSessionRowActionAvailability(
                action: item.action,
                blocker: runtimeActionBlocker
            )
        }
    }

    /// Don't pin a disabled sibling's reason under a still-enabled action
    /// (collect can stay open while retry waits for plot-relink).
    nonisolated static func sharedActionBarBlocker(
        _ actions: [NovelSessionRowActionAvailability]
    ) -> NovelSessionActionBlocker? {
        let enabledMutation = actions.contains {
            $0.blocker == nil && $0.action.requiresMutation
        }
        guard !enabledMutation else { return nil }
        return actions.compactMap(\.blocker).first
    }

    @ViewBuilder
    private var proseCandidateStatus: some View {
        switch candidateStatus {
        case .collected:
            Label(localized("已收录为正式正文"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(AmberTheme.accentGreen)
        case .inheritedReadOnly:
            Label(localized("继承的历史候选 · 仅供参考"), systemImage: "clock.arrow.circlepath")
                .foregroundStyle(AmberTheme.muted)
        case .superseded:
            Label(localized("候选已过期"), systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(AmberTheme.foreground2)
        case .interrupted:
            Label(localized("候选生成已中断"), systemImage: "pause.circle")
                .foregroundStyle(AmberTheme.foreground2)
        case .available, .adopted, nil:
            Label(proseCandidateLabel, systemImage: "doc.text")
                .foregroundStyle(AmberTheme.muted)
        }
    }

    private var proseCandidateLabel: String {
        if isRegeneration { return localized("重写本章 · 收录后替换原文") }
        switch granularity {
        case .continuation:
            return localized("正文片段 · 收录后进入本章")
        case .wholeChapter:
            return localized("完整章节 · 收录后成为新章")
        case nil:
            return localized("正文候选 · 收录后才进入正式剧情")
        }
    }

    @ViewBuilder
    private var polishCandidateStatus: some View {
        if isAdoptingPolish || isRetryingPolish {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(localized("正在检查剧情一致性…"))
            }
            .font(.footnote)
            .foregroundStyle(AmberTheme.muted)
        } else {
            polishTransactionStatusView
        }
    }

    private var isRetryingPolish: Bool {
        guard let retryingPolishTransactionID else { return false }
        return actions.contains {
            $0.action == .retryPolish(retryingPolishTransactionID)
        }
    }

    @ViewBuilder
    private var polishTransactionStatusView: some View {
        switch polishTransactionStatus {
        case .incompatible:
            Label(localized("检测到剧情漂移 · 不能按润色采用"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(AmberTheme.accentRed)
        case .retryable:
            Label(localized("剧情一致性检查失败 · 可以重试"), systemImage: "arrow.clockwise.circle")
                .foregroundStyle(AmberTheme.foreground2)
        case .blocked:
            Label(localized("剧情一致性检查已阻止采用"), systemImage: "hand.raised.fill")
                .foregroundStyle(AmberTheme.accentRed)
        case .pending:
            Label(localized("正在检查剧情一致性"), systemImage: "checkmark.shield")
                .foregroundStyle(AmberTheme.muted)
        case .abandoned:
            Label(localized("已放弃这次润色"), systemImage: "xmark.circle")
                .foregroundStyle(AmberTheme.muted)
        case .completed, nil:
            polishCandidateStatusByCandidate
        }
    }

    @ViewBuilder
    private var polishCandidateStatusByCandidate: some View {
        switch candidateStatus {
        case .adopted:
            Label(localized("润色版已采用"), systemImage: "checkmark.seal.fill")
                .foregroundStyle(AmberTheme.accentGreen)
        case .superseded:
            Label(localized("润色候选已过期"), systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(AmberTheme.foreground2)
        case .interrupted:
            Label(localized("润色生成已中断"), systemImage: "pause.circle")
                .foregroundStyle(AmberTheme.foreground2)
        case .inheritedReadOnly:
            Label(localized("继承的历史润色候选"), systemImage: "clock.arrow.circlepath")
                .foregroundStyle(AmberTheme.muted)
        case .available, .collected, nil:
            Label(localized("整章润色候选"), systemImage: "wand.and.sparkles")
                .foregroundStyle(AmberTheme.accent)
        }
    }

    private var systemMessage: some View {
        Text(content)
            .font(.caption.weight(.medium))
            .foregroundStyle(AmberTheme.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(AmberTheme.surface, in: Capsule())
            .frame(maxWidth: .infinity)
            .accessibilityLabel(content)
    }
}

private struct NovelSessionActionButtons: View {
    let actions: [NovelSessionRowActionAvailability]
    let granularity: NovelGenerationGranularity?
    let retryingPolishTransactionID: NovelPendingOperationID?
    let onCancelPolishRetry: () -> Void
    let onAction: (NovelSessionRowAction) -> Void

    @State private var pendingAbandonTransactionID: NovelPendingOperationID?

    var body: some View {
        ForEach(actions, id: \.action) { item in
            if item.action.isPrimary {
                actionButton(item)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            } else {
                actionButton(item)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ item: NovelSessionRowActionAvailability) -> some View {
        if case .retryPolish(let transactionID) = item.action,
           retryingPolishTransactionID == transactionID {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Button(localized("停止检查")) {
                    onCancelPolishRetry()
                }
                .frame(minHeight: 44)
            }
        } else if case .abandonPolish(let transactionID) = item.action {
            baseButton(item) {
                pendingAbandonTransactionID = transactionID
            }
            .confirmationDialog(
                localized("放弃这次润色？"),
                isPresented: Binding(
                    get: { pendingAbandonTransactionID == transactionID },
                    set: { presented in
                        if !presented { pendingAbandonTransactionID = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(localized("放弃润色"), role: .destructive) {
                    pendingAbandonTransactionID = nil
                    onAction(item.action)
                }
                Button(localized("取消"), role: .cancel) {
                    pendingAbandonTransactionID = nil
                }
            } message: {
                Text(localized("候选气泡会保留在创作记录中，但不能再作为润色版采用。"))
            }
        } else {
            baseButton(item) {
                onAction(item.action)
            }
        }
    }

    private func baseButton(
        _ item: NovelSessionRowActionAvailability,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(
                item.action.displayTitle(granularity: granularity),
                systemImage: item.action.systemImage
            )
            .font(.footnote.weight(.semibold))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small)
        .disabled(!item.isEnabled)
        .accessibilityHint(item.blocker.map { localized($0.displayName) } ?? "")
    }
}

private struct NovelAskUserCard: View {
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
            } else {
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
                            arguments: [localizedNumber(selectedChapterCount)]
                        ))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .contentShape(Rectangle())
                }
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
                arguments: [localizedNumber(selectedChapterCount)]
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
                arguments: [localizedNumber(selectedChapterCount)]
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

    private var statusTitle: String {
        guard let answer = presentation.response?.answer else { return localized("代笔计划审批") }
        if let count = NovelGhostwritePlanApproval.approvedChapterCount(from: answer) {
            return IOSAppLocalization.formatted(
                "已开始代笔 %@ 章",
                defaultValue: "已开始代笔 %@ 章",
                arguments: [localizedNumber(count)]
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(statusTitle, systemImage: statusSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)

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
                    revisionBlock(title: "原文", text: revision.oldText)
                    revisionBlock(title: "改为", text: revision.newText)
                }
            }

            if let response = presentation.response,
               response.answer != NovelChapterRevisionApproval.approveOption,
               response.answer != NovelChapterRevisionApproval.rejectOption {
                Text(response.answer)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground2)
            }

            if presentation.response == nil {
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
        .padding(16)
        .amberGlass(cornerRadius: 18, interactive: false)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.accent.opacity(0.18), lineWidth: 0.75)
                .allowsHitTesting(false)
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
                arguments: [localizedNumber(revision.startParagraph)]
            )
            : IOSAppLocalization.formatted(
                "第 %@–%@ 段",
                defaultValue: "第 %@–%@ 段",
                arguments: [
                    localizedNumber(revision.startParagraph),
                    localizedNumber(revision.endParagraph)
                ]
            )
        return IOSAppLocalization.formatted(
            "第 %@ 章 · %@ · %@",
            defaultValue: "第 %@ 章 · %@ · %@",
            arguments: [
                localizedNumber(revision.chapterOrdinal),
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
        }
        .padding(16)
        .amberGlass(cornerRadius: 18, interactive: false)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.accent.opacity(0.18), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
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
        }
        .padding(16)
        .amberGlass(cornerRadius: 18, interactive: false)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.accent.opacity(0.18), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
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
        }
        .padding(16)
        .amberGlass(cornerRadius: 18, interactive: false)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.accent.opacity(0.18), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
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

private extension NovelSessionRowAction {
    var requiresMutation: Bool {
        if case .viewSettingProposals = self { return false }
        return true
    }

    func displayTitle(granularity: NovelGenerationGranularity?) -> String {
        switch self {
        case .collectProse:
            switch granularity {
            case .continuation: localized("收录到本章")
            case .wholeChapter: localized("作为新章收录")
            case nil: localized("收录正文")
            }
        case .adoptPolish: localized("采用润色版")
        case .retryGeneration: localized("重新生成")
        case .retryTerminalPersistence: localized("重试保存")
        case .retryPending: localized("继续收录")
        case .retryPolish: localized("重试检查")
        case .abandonPolish: localized("放弃润色")
        case .convertPolishToManualRewrite: localized("保存为剧情改写")
        case .cloneCollectedProse: localized("再次收录")
        case .forkFromCheckpoint: localized("从这里 Fork")
        case .viewSettingProposals: localized("查看并确认设定建议")
        case .undoCommittedChange(_, let kind):
            localized(kind == .polish ? "撤销润色" : "撤销收录")
        }
    }

    var systemImage: String {
        switch self {
        case .collectProse: "text.badge.checkmark"
        case .adoptPolish: "checkmark.seal"
        case .retryGeneration, .retryTerminalPersistence, .retryPending, .retryPolish:
            "arrow.clockwise"
        case .abandonPolish: "xmark.circle"
        case .convertPolishToManualRewrite: "square.and.pencil"
        case .cloneCollectedProse: "doc.on.doc"
        case .forkFromCheckpoint: "arrow.triangle.branch"
        case .viewSettingProposals: "books.vertical"
        case .undoCommittedChange: "arrow.uturn.backward"
        }
    }

    var isPrimary: Bool {
        switch self {
        case .collectProse, .adoptPolish, .viewSettingProposals: true
        default: false
        }
    }
}

extension NovelSessionActionBlocker {
    var displayName: String {
        switch self {
        case .projectReadOnly: "项目当前只读"
        case .reloadRequired: "请先重新载入项目"
        case .branchInactive: "分支已不可编辑"
        case .branchNeedsSync: "剧情状态同步未完成"
        case .chapterPlanRequired: "代笔写整章前，请先确认本章计划"
        case .ghostwriteReviewRequired: "代笔稿需通过审核后由代笔流程收录"
        case .ghostwriteRequirementsMissing: "代笔条件尚未满足"
        case .generationRunning: "请先停止当前生成"
        case .pendingOperation: "有正文操作正在处理"
        case .transactionInProgress: "操作正在处理"
        case .transactionBlocked: "操作已被阻止"
        case .staleCandidate: "当前剧情已变化，候选已过期"
        case .sourceChapterChanged: "源章节版本已经变化"
        case .failureNotRetryable: "该失败不能直接重试"
        }
    }
}
