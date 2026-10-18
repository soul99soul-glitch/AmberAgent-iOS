import SwiftUI

private func localized(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
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
    var retryingRunID: NovelRunID? = nil
    var cloningCandidateID: NovelCandidateID? = nil
    var undoingCheckpointID: NovelCheckpointID? = nil
    var isStopping: Bool = false
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
    @AppStorage(IOSDisplayPreferenceKeys.autoExpandThinking) private var autoExpandThinking = true

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
                        autoCloseThinking: true,
                        autoExpandThinking: autoExpandThinking
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
                    NovelSessionWindowedMarkdown(
                        fullText: displayedContent,
                        messageID: messageID,
                        isStreaming: isStreaming,
                        hasEverStreamed: hasEverStreamed,
                        showsFullTextEntry: !isStreaming && transientPhase != .terminalAwaitingRefresh,
                        fullTextTitle: localized(kind == .discussion ? "讨论全文" : "正文全文")
                    )
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
        if isStopping {
            EmptyView()
        } else if case .some(.persistenceBlocked) = transientPhase {
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
        if isStopping {
            return localized("正在停止…")
        }
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
            retryingRunID: retryingRunID,
            cloningCandidateID: cloningCandidateID,
            undoingCheckpointID: undoingCheckpointID,
            retryingPolishTransactionID: retryingPolishTransactionID,
            onCancelPolishRetry: onCancelPolishRetry,
            onAction: onAction
        )
    }

    private var effectiveActions: [NovelSessionRowActionAvailability] {
        guard !isStopping else { return [] }
        return actions.map { item in
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
