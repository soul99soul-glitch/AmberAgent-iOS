import SwiftUI

struct NovelPendingCommittedUndo {
    let checkpointID: NovelCheckpointID
    let kind: NovelCandidateKind
}

struct NovelSessionListSignal: Equatable {
    let sessionID: NovelSessionID?
    let rowCount: Int
    let activeTailID: NovelMessageID?
    let activeTailDigest: NovelSessionRowDigest?
    let activeTailPhase: NovelSessionTransientTailPhase?
    let activeRunRowCount: Int
    let lastRowDigest: NovelSessionRowDigest?
}

struct NovelSessionTranscriptScope<Content: View>: View {
    let workspace: NovelCreationViewModel
    let viewModel: NovelSessionViewModel
    let expandedArchiveIDs: Set<NovelMessageID>
    let onInitialRows: (NovelSessionListSignal) -> Void
    let onSignalChange: (NovelSessionListSignal, NovelSessionListSignal) -> Void
    let content: (NovelSessionListModel?, NovelSessionListSignal) -> Content

    var body: some View {
        let _ = Self._logChanges() // TEMP-DIAG
        let listModel = viewModel.loadStage >= .coreTranscript ? projectedListModel() : nil
        let listSignal = Self.makeListSignal(from: listModel)

        content(listModel, listSignal)
            .task(id: listSignal.sessionID) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                onInitialRows(listSignal)
            }
            .onChange(of: listSignal) { oldValue, newValue in
                onSignalChange(oldValue, newValue)
            }
    }

    private func projectedListModel() -> NovelSessionListModel? {
        guard let project = workspace.projectSnapshot,
              let branch = workspace.branchSnapshot else { return nil }
        return viewModel.projectedListModel(
            project: project,
            branch: branch,
            expandedArchiveIDs: expandedArchiveIDs
        )
    }

    private static func makeListSignal(
        from model: NovelSessionListModel?
    ) -> NovelSessionListSignal {
        let tail = model?.activeTailRow
        return NovelSessionListSignal(
            sessionID: model?.sessionID,
            rowCount: model?.rowCount ?? 0,
            activeTailID: model?.activeTailID,
            activeTailDigest: tail?.digest,
            activeTailPhase: tail?.transientPhase,
            activeRunRowCount: model?.activeRunRows.count ?? 0,
            lastRowDigest: model?.lastRowDigest
        )
    }
}

struct NovelSessionScrollGeometrySignal: Equatable {
    let contentHeight: CGFloat
    let isAtBottom: Bool
    let isNearBottom: Bool
}

struct NovelSessionRowView: View, Equatable {
    let row: NovelSessionRowModel
    /// The row contains localized failure copy; rebuild it when the in-app
    /// language changes even though the durable row digest is unchanged.
    let languageCode: String
    /// True only for the row that actually streamed in this presentation.
    var hasEverStreamed: Bool = false
    let adoptingPolishCandidateID: NovelCandidateID?
    let retryingRunID: NovelRunID?
    let cloningCandidateID: NovelCandidateID?
    let undoingCheckpointID: NovelCheckpointID?
    let isStopping: Bool
    let isSubmittingChapterRevision: Bool
    let askUserBlocker: NovelSessionActionBlocker?
    let runtimeActionBlocker: NovelSessionActionBlocker?
    let polishRetryTransactionID: NovelPendingOperationID?
    let onAction: (NovelSessionRowAction) -> Void
    let onCancelPolishRetry: () -> Void
    let onAnswerAskUser: (NovelMessageID, String) -> Void
    let onToggleArchive: (NovelDiscussionArchivePresentation) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row.id == rhs.row.id && lhs.row.digest == rhs.row.digest &&
            lhs.languageCode == rhs.languageCode &&
            lhs.hasEverStreamed == rhs.hasEverStreamed &&
            lhs.adoptingPolishCandidateID == rhs.adoptingPolishCandidateID &&
            lhs.retryingRunID == rhs.retryingRunID &&
            lhs.cloningCandidateID == rhs.cloningCandidateID &&
            lhs.undoingCheckpointID == rhs.undoingCheckpointID &&
            lhs.isStopping == rhs.isStopping &&
            lhs.isSubmittingChapterRevision == rhs.isSubmittingChapterRevision &&
            lhs.askUserBlocker == rhs.askUserBlocker &&
            lhs.runtimeActionBlocker == rhs.runtimeActionBlocker &&
            lhs.polishRetryTransactionID == rhs.polishRetryTransactionID
    }

    var body: some View {
        let _ = Self._logChanges() // TEMP-DIAG
        if let archive = row.archive {
            NovelDiscussionArchiveCard(archive: archive) {
                onToggleArchive(archive)
            }
        } else {
            NovelSessionBubble(
                messageID: row.id,
                role: row.role,
                kind: row.kind,
                granularity: row.granularity,
                content: row.content,
                reasoningContent: row.reasoningContent,
                isReasoningLive: row.isReasoningLive,
                isStreaming: row.isStreaming,
                transientPhase: row.transientPhase,
                hasEverStreamed: hasEverStreamed,
                runStatus: row.runStatus,
                candidateStatus: row.candidate?.status,
                isRegeneration: row.candidate?.kind == .prose
                    && row.candidate?.sourceChapterVersionID != nil,
                polishTransactionStatus: row.candidate?.polishTransactionStatus,
                isAdoptingPolish: row.candidate?.id == adoptingPolishCandidateID,
                retryingRunID: retryingRunID,
                cloningCandidateID: cloningCandidateID,
                undoingCheckpointID: undoingCheckpointID,
                isStopping: isStopping,
                committedChange: row.committedChange,
                askUser: row.askUser,
                isSubmittingChapterRevision: isSubmittingChapterRevision,
                askUserBlocker: askUserBlocker,
                runtimeActionBlocker: runtimeActionBlocker,
                retryingPolishTransactionID: polishRetryTransactionID,
                onCancelPolishRetry: onCancelPolishRetry,
                actions: row.actions,
                onAction: onAction,
                onAnswerAskUser: onAnswerAskUser
            )
        }
    }
}

struct NovelSessionStreamingTailVisibilityModifier: ViewModifier {
    let active: Bool
    let onVisibilityChanged: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content
                .onGeometryChange(for: Bool?.self) { proxy in
                    guard let viewportBounds = proxy.bounds(of: .scrollView) else { return nil }
                    return proxy.frame(in: .local).intersects(viewportBounds)
                } action: { isVisible in
                    guard let isVisible else { return }
                    onVisibilityChanged(isVisible)
                }
                .onDisappear {
                    onVisibilityChanged(false)
                }
        } else {
            content
        }
    }
}

struct NovelDiscussionArchiveCard: View {
    let archive: NovelDiscussionArchivePresentation
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 8) {
                Label(archive.title, systemImage: "archivebox.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                Text(archive.summary)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.foreground2)
                    .multilineTextAlignment(.leading)
                Label(
                    IOSAppLocalization.string(
                        archive.isExpanded ? "收起讨论" : "展开讨论",
                        defaultValue: archive.isExpanded ? "收起讨论" : "展开讨论"
                    ),
                    systemImage: archive.isExpanded ? "chevron.up" : "chevron.down"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .amberGlass(cornerRadius: 8, interactive: true)
        }
        .buttonStyle(.plain)
    }
}
