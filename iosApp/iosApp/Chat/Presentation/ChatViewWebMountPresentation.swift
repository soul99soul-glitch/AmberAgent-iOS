import SwiftUI
import Shared
import UIKit
import UniformTypeIdentifiers
import PhotosUI

extension ChatView {

    private var activeWebMountSession: IOSWebMountSessionRecord? {
        guard let conversationId = currentConversationIdString else { return nil }
        let recentUserTurnStartMillis = chatListSummary.webMountRecentUserTurnStartMillis
        return webMountController.sessionStore.records
            .filter { record in
                Self.webMountSessionIsRetained(
                    record,
                    conversationId: conversationId,
                    recentUserTurnStartMillis: recentUserTurnStartMillis
                ) &&
                    webMountSessionIsOpenable(record)
            }
            .max { $0.lastActivityMillis < $1.lastActivityMillis }
    }

    /// Card retention follows the same user-turn boundary as tool exposure.
    /// Agent rounds and retries update activity inside this window without
    /// creating another user message, so they do not consume a turn.
    static func webMountRecentUserTurnStartMillis(from messages: [UIMessage]) -> Int64? {
        messages.reversed()
            .filter { $0.role == MessageRole.user }
            // recentToolsForExposure scans assistant messages until it sees
            // the sixth user message. Use that same boundary so the session
            // used by the previous turn remains visible for all five next
            // user turns.
            .prefix(6)
            .last
            .flatMap { ChatContextSnapshot.epochMillis(from: $0.createdAt) }
    }

    static func webMountSessionIsRetained(
        _ record: IOSWebMountSessionRecord,
        conversationId: String,
        recentUserTurnStartMillis: Int64?
    ) -> Bool {
        guard record.ownerConversationId == conversationId, !record.cardHidden else { return false }
        return record.ownerRunId?.nilIfBlank != nil ||
            record.controlOwner == .user ||
            (recentUserTurnStartMillis.map { record.lastActivityMillis >= $0 } ?? false)
    }

    var displayedWebMountSession: IOSWebMountSessionRecord? {
        guard let record = activeWebMountSession,
              viewModel.pendingWebMountApproval?.sessionId != record.id else { return nil }
        return record
    }

    var compactWebMountSession: IOSWebMountSessionRecord? {
        guard !composerState.isAttachExpanded, !collapsesComposerForSiteMemoryApproval,
              let record = displayedWebMountSession,
              webMountSessionIsCompact(record) else { return nil }
        return record
    }

    func webMountSessionIsCompact(_ record: IOSWebMountSessionRecord) -> Bool {
        browserState.collapsedWebMountSessionId == record.id ||
            (record.ownerRunId?.nilIfBlank == nil && record.controlOwner != .user && browserState.expandedWebMountSessionId != record.id)
    }

    static func browserTaskTitleCandidate(messages: [UIMessage]) -> String? {
        guard let message = messages.last(where: ChatMessageProjector.isConversationMessage),
              message.role == MessageRole.assistant,
              let tool = message.parts.compactMap({ $0 as? UIMessagePart.Tool })
                .last(where: { $0.toolName.hasPrefix("wm_") }) else { return nil }
        return ChatToolStepModel(tool: tool).title.nilIfBlank
    }

    var scrollToBottomBottomPadding: CGFloat {
        10 + (compactWebMountSession == nil ? 0 : 52)
    }

    private func webMountSessionIsOpenable(_ record: IOSWebMountSessionRecord) -> Bool {
        record.backend != .local ||
            WebMountSiteRoute(watching: record, registry: webMountController.registry) != nil
    }

    func webMountSessionAction(sessionId: String?) -> (() -> Void)? {
        guard let sessionId = sessionId?.nilIfBlank,
              let record = webMountController.sessionStore.record(sessionId: sessionId) else {
            return nil
        }
        if !webMountSessionIsOpenable(record) {
            return nil
        }
        return { openWebMountSession(sessionId: sessionId) }
    }

    func openWebMountSession(sessionId: String) {
        let controller = webMountController
        guard let record = controller.sessionStore.record(sessionId: sessionId) else { return }
        if record.needsReopen {
            guard controller.sessionStore.reopen(sessionId: sessionId) != nil else {
                conversationStore.publishUserVisibleError(IOSUserVisibleError(
                    title: IOSAppLocalization.string(
                        "浏览器任务无法重新打开",
                        defaultValue: "浏览器任务无法重新打开"
                    ),
                    message: IOSAppLocalization.string(
                        "此会话已回收，当前无法创建新的页面；请先关闭其他浏览器会话后重试。",
                        defaultValue: "此会话已回收，当前无法创建新的页面；请先关闭其他浏览器会话后重试。"
                    ),
                    severity: .warning
                ))
                return
            }
        }
        controller.sessionStore.showCard(sessionId: sessionId)
        browserState.collapsedWebMountSessionId = nil
        browserState.expandedWebMountSessionId = sessionId
        if record.backend == .local {
            guard let route = WebMountSiteRoute(watching: record, registry: controller.registry) else { return }
            router.navigate(to: .webMountSite(site: route))
        } else {
            browserState.focusedRemoteWebMountSessionId = record.id
            Task { @MainActor in
                browserState.showWebMountDesktopBackends = true
            }
        }
    }

}
