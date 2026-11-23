import Foundation

extension Notification.Name {
    static let amberWatchRemoteStateDidChange = Notification.Name("app.amber.ios.watch.remoteStateDidChange")
}

/// Decoupled, read-only decision projection coming from a paired Cloud or Mac host.
/// Designed so future multi-slot (Cloud + Mac simultaneous) stores can feed the same type.
struct WatchRemotePendingDecision: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case approval(sessionKey: String, toolCallId: String, tool: String)
        case askUser(options: [String])
    }

    var id: String
    var origin: WatchExecutionOrigin
    var hostName: String
    var kind: Kind
    var title: String
    var body: String
    var riskLevel: WatchRiskLevel
    var localApprovalOnly: Bool
    var workItemId: String?
    var conversationId: String?
}

/// Decoupled, read-only task projection coming from a paired Cloud or Mac host.
struct WatchRemoteTaskProjection: Equatable, Sendable {
    var runId: String
    var origin: WatchExecutionOrigin
    var hostName: String
    var workItemId: String?
    var sessionKey: String?
    var conversationId: String?
    var phase: String
    var headline: String
    var detail: String?
    var summary: String?
    var updatedAt: Date
    var isLive: Bool
    var needsAttention: Bool
    var canCancel: Bool
    var decision: WatchRemotePendingDecision?
}

/// Read-only multi-device projection consumed by `WatchTaskCoordinator`.
struct WatchRemoteExecutionProjection: Equatable, Sendable {
    var isPaired: Bool = false
    var isOnline: Bool = false
    var remoteOrigin: WatchExecutionOrigin? = nil
    var remoteHostName: String? = nil
    /// The execution target currently selected by the user on iPhone (`本机` / `云端` / `Mac`).
    var selectedExecutionTarget: WatchExecutionOrigin = .local
    /// Highest-priority remote task (pending decision > active running > recent terminal).
    var primaryTask: WatchRemoteTaskProjection? = nil
    /// Recent completed/failed Cloud or Mac task summaries for the Watch activity feed.
    var recentActivities: [WatchRecentActivity] = []

    static let unpaired = WatchRemoteExecutionProjection()
}

struct WatchRemoteDispatchOutcome: Equatable, Sendable {
    var accepted: Bool
    var message: String
    var runId: String?
    var conversationId: String?
    var deliveryUnknown: Bool = false
}

/// Narrow projection & routing boundary between `WatchTaskCoordinator` and `MacGatewayStore`.
/// Keeping this protocol separate lets Scheme 2 (Cloud + Mac dual-slot) plug in cleanly.
@MainActor
protocol WatchRemoteExecutionRouting: AnyObject {
    func currentProjection() -> WatchRemoteExecutionProjection
    func submitQuestion(
        text: String,
        requestId: String,
        origin: WatchExecutionOrigin
    ) async -> WatchRemoteDispatchOutcome
    func resolveApproval(
        origin: WatchExecutionOrigin,
        sessionKey: String,
        toolCallId: String,
        allow: Bool
    ) async -> (accepted: Bool, message: String)
    func submitAskUserReply(
        origin: WatchExecutionOrigin,
        workItemId: String?,
        conversationId: String?,
        text: String,
        requestId: String
    ) async -> (accepted: Bool, message: String)
    func cancelRemoteTask(
        origin: WatchExecutionOrigin,
        workItemId: String?,
        requestId: String?
    ) async -> (accepted: Bool, message: String)
    func openRemoteDeepLink(
        workItemId: String?,
        origin: WatchExecutionOrigin
    ) -> IOSAppDeepLink.Destination
}

/// Dual-slot adapter backed by `MacGatewayStore` (Cloud slot + independent Mac slot).
@MainActor
final class MacGatewayWatchExecutionAdapter: WatchRemoteExecutionRouting {
    private let store: MacGatewayStore

    init(store: MacGatewayStore = .shared) {
        self.store = store
    }

    @MainActor
    private struct PairedSlot {
        let origin: WatchExecutionOrigin
        let slot: MacGatewayStore
        let connection: MacGatewayConnection

        var hostName: String {
            let trimmed = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? origin.defaultTitle : trimmed
        }

        var isOnline: Bool {
            slot.isReachable == true
        }
    }

    private var pairedSlots: [PairedSlot] {
        var result: [PairedSlot] = []
        if let cloudConnection = store.connection {
            result.append(PairedSlot(origin: .cloud, slot: store, connection: cloudConnection))
        }
        if let macSlot = store.macSlot, let macConnection = macSlot.connection {
            result.append(PairedSlot(origin: .mac, slot: macSlot, connection: macConnection))
        }
        return result
    }

    private func pairedSlot(for origin: WatchExecutionOrigin) -> PairedSlot? {
        pairedSlots.first { $0.origin == origin }
    }

    func currentProjection() -> WatchRemoteExecutionProjection {
        let slots = pairedSlots
        guard !slots.isEmpty else {
            return .unpaired
        }
        let onlineSlots = slots.filter(\.isOnline)
        let primaryTask = selectPrimaryTask(from: onlineSlots)
        let activities = buildRecentActivities(from: slots)

        let selectedTarget: WatchExecutionOrigin = if store.isCloudMainDialogueSelected && store.hasCloudConnection {
            .cloud
        } else {
            switch store.effectiveComposerTarget {
            case .cloud: .cloud
            case .mac: .mac
            case .local: .local
            }
        }
        let preferredSlot = pairedSlot(for: selectedTarget)
            ?? primaryTask.flatMap { pairedSlot(for: $0.origin) }
            ?? onlineSlots.first
            ?? slots[0]

        return WatchRemoteExecutionProjection(
            isPaired: true,
            isOnline: preferredSlot.isOnline,
            remoteOrigin: preferredSlot.origin,
            remoteHostName: preferredSlot.hostName,
            selectedExecutionTarget: selectedTarget,
            primaryTask: primaryTask,
            recentActivities: activities
        )
    }

    func submitQuestion(
        text: String,
        requestId: String,
        origin: WatchExecutionOrigin
    ) async -> WatchRemoteDispatchOutcome {
        guard let targetSlot = pairedSlot(for: origin)?.slot else {
            return WatchRemoteDispatchOutcome(
                accepted: false,
                message: "所属终端未配对，请在 iPhone 多终端设置中核对",
                runId: nil,
                conversationId: nil
            )
        }
        let normalizedRequestId = requestId.lowercased()
        let result = await targetSlot.sendCloudDialogueMessage(
            text: text,
            requestId: normalizedRequestId
        )
        switch result {
        case .success(let receipt):
            let primaryId = receipt.workItemIds.first ?? receipt.requestId
            return WatchRemoteDispatchOutcome(
                accepted: true,
                message: origin == .mac ? "已发送到 Mac" : "已发送到云端",
                runId: "remote:\(origin.rawValue):\(primaryId)",
                conversationId: receipt.conversationId ?? targetSlot.cloudDialogueConversationId,
                deliveryUnknown: false
            )
        case .failure(let error):
            let isDeterministic = MacGatewayStore.isDeterministicNonExecutionError(error)
            let friendly = targetSlot.cloudDialogueFriendlyErrorMessage(for: error)
            return WatchRemoteDispatchOutcome(
                accepted: false,
                message: friendly.isEmpty ? "远端发送失败，请稍后重试" : friendly,
                runId: nil,
                conversationId: targetSlot.cloudDialogueConversationId,
                deliveryUnknown: !isDeterministic
            )
        }
    }

    func resolveApproval(
        origin: WatchExecutionOrigin,
        sessionKey: String,
        toolCallId: String,
        allow: Bool
    ) async -> (accepted: Bool, message: String) {
        guard let targetSlot = pairedSlot(for: origin)?.slot,
              let card = targetSlot.activeMacApprovalCardItems().first(where: {
                  $0.sessionKey == sessionKey && $0.toolCallId == toolCallId
              }) else {
            return (false, "这个确认步骤已失效")
        }

        // L3 redline enforcement at execution boundary: high-risk / local-only
        // approvals can NEVER be approved remotely from Watch.
        if allow {
            let isL3 = card.riskTier == .l3
                || card.requiresLocalApproval
                || card.highRisk
                || targetSlot.requiresLocalApprovalOnly(sessionKey: sessionKey, toolCallId: toolCallId)
                || targetSlot.isKnownHighRiskApproval(sessionKey: sessionKey, toolCallId: toolCallId)
            if isL3 {
                return (false, "高危操作请在 iPhone 或 Mac 上核对批准")
            }
        }

        // Use `.notification` trust context so L1/L2 decisions work from Watch
        // without requiring iPhone foreground biometrics, while L3 fails closed.
        let ok = await targetSlot.decide(
            sessionKey: sessionKey,
            toolCallId: toolCallId,
            allow: allow,
            source: .notification,
            role: targetSlot.endpointRole
        )
        if ok {
            return (true, allow ? "已允许" : "已拒绝")
        }
        return (false, targetSlot.notice?.text ?? "操作未能完成，请在 iPhone 查看")
    }

    func submitAskUserReply(
        origin: WatchExecutionOrigin,
        workItemId: String?,
        conversationId: String?,
        text: String,
        requestId: String
    ) async -> (accepted: Bool, message: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "回答不能为空")
        }
        guard let targetSlot = pairedSlot(for: origin)?.slot else { return (false, "所属终端已取消配对") }
        let normalizedRequestId = requestId.lowercased()
        let result: Result<MacGatewayCloudDialogueReceipt, Error>
        if let workItemId, !workItemId.isEmpty {
            result = await targetSlot.sendCloudWorkItemInput(
                workItemId: workItemId,
                text: trimmed,
                requestId: normalizedRequestId,
                conversationId: conversationId
            )
        } else {
            result = await targetSlot.sendCloudDialogueMessage(
                text: trimmed,
                requestId: normalizedRequestId,
                conversationId: conversationId
            )
        }
        switch result {
        case .success:
            return (true, "已提交回答")
        case .failure(let error):
            return (false, targetSlot.cloudDialogueFriendlyErrorMessage(for: error))
        }
    }

    func cancelRemoteTask(
        origin: WatchExecutionOrigin,
        workItemId: String?,
        requestId: String?
    ) async -> (accepted: Bool, message: String) {
        guard let targetSlot = pairedSlot(for: origin)?.slot else { return (false, "所属终端已取消配对") }
        if let workItemId, !workItemId.isEmpty {
            if targetSlot.cloudDialogueProgressByWorkItem[workItemId] != nil {
                switch await targetSlot.stopCloudWorkItem(workItemId: workItemId) {
                case .success: return (true, "已请求停止")
                case .failure(let error): return (false, targetSlot.cloudDialogueFriendlyErrorMessage(for: error))
                }
            }
            if targetSlot.cloudTasks.contains(where: { $0.workItemId == workItemId && $0.canCancel }) {
                let cancelled = await targetSlot.cancelCloudTask(workItemId: workItemId)
                return cancelled ? (true, "已取消") : (false, "取消未获确认，请在 iPhone 查看")
            }
        }
        if let requestId, !requestId.isEmpty {
            let cancelled = await targetSlot.cancelPendingMacSubmission(requestId: requestId, workItemId: workItemId)
            return cancelled ? (true, "已取消") : (false, "当前任务无法从手表取消")
        }
        return (false, "当前任务不支持从手表取消")
    }

    func openRemoteDeepLink(
        workItemId: String?,
        origin: WatchExecutionOrigin
    ) -> IOSAppDeepLink.Destination {
        if let workItemId, !workItemId.isEmpty, origin == .cloud {
            return .cloudTask(workItemId: workItemId)
        }
        return .gatewayTasks(origin == .mac ? .mac : .cloud)
    }

    // MARK: - Projection builders

    private func selectPrimaryTask(from onlineSlots: [PairedSlot]) -> WatchRemoteTaskProjection? {
        guard !onlineSlots.isEmpty else { return nil }

        // 1. Highest priority across all paired slots: pending approvals (L1/L2/L3).
        for entry in onlineSlots {
            let approvals = entry.slot.activeMacApprovalCardItems()
            if let card = approvals.first {
                let isL3 = card.riskTier == .l3 || card.requiresLocalApproval || card.highRisk
                    || entry.slot.isKnownHighRiskApproval(sessionKey: card.sessionKey, toolCallId: card.toolCallId)
                let watchRisk: WatchRiskLevel = switch card.riskTier {
                case .l1: card.highRisk ? .high : .low
                case .l2: card.highRisk ? .high : .medium
                case .l3: .high
                }
                let bodyParts = [
                    card.summary,
                    card.effectivePreviewText.flatMap { WatchTaskText.singleLine($0, maxLength: 100) }
                ].compactMap { $0 }.filter { !$0.isEmpty }
                let decision = WatchRemotePendingDecision(
                    id: card.id,
                    origin: entry.origin,
                    hostName: entry.hostName,
                    kind: .approval(sessionKey: card.sessionKey, toolCallId: card.toolCallId, tool: card.tool),
                    title: card.tool,
                    body: bodyParts.joined(separator: "\n"),
                    riskLevel: watchRisk,
                    localApprovalOnly: isL3,
                    workItemId: card.workItemId,
                    conversationId: card.conversationId
                )
                let updatedAt = entry.slot.boardItems.first(where: {
                    $0.approval?.sessionKey == card.sessionKey && $0.approval?.toolCallId == card.toolCallId
                })?.updatedAt ?? Date()
                return WatchRemoteTaskProjection(
                    runId: "remote:\(entry.origin.rawValue):approval:\(card.toolCallId)",
                    origin: entry.origin,
                    hostName: entry.hostName,
                    workItemId: card.workItemId,
                    sessionKey: card.sessionKey,
                    conversationId: card.conversationId,
                    phase: "waitingForUser",
                    headline: WatchTaskText.singleLine(card.summary, maxLength: 60) ?? card.tool,
                    detail: isL3 ? "高危审批 · 需在主机核对" : "等你确认 · \(card.tool)",
                    summary: nil,
                    updatedAt: updatedAt,
                    isLive: true,
                    needsAttention: true,
                    canCancel: false,
                    decision: decision
                )
            }
        }

        // 2. Waiting-for-reply items on board (e.g. ask_user / session waiting for user reply).
        for entry in onlineSlots {
            if let waitingBoardItem = entry.slot.needsYouItems.first(where: { $0.waitingForReply }) {
                let decision = WatchRemotePendingDecision(
                    id: "remote-reply:\(waitingBoardItem.id)",
                    origin: entry.origin,
                    hostName: entry.hostName,
                    kind: .askUser(options: []),
                    title: "需要你的回复",
                    body: WatchTaskText.clipped("\(waitingBoardItem.title)\n\(waitingBoardItem.detail)", maxLength: 240)
                        ?? waitingBoardItem.title,
                    riskLevel: .low,
                    localApprovalOnly: false,
                    workItemId: nil,
                    conversationId: waitingBoardItem.conversationId
                )
                return WatchRemoteTaskProjection(
                    runId: "remote:\(entry.origin.rawValue):\(waitingBoardItem.id)",
                    origin: entry.origin,
                    hostName: entry.hostName,
                    workItemId: nil,
                    sessionKey: waitingBoardItem.sessionKey,
                    conversationId: waitingBoardItem.conversationId,
                    phase: "waitingForUser",
                    headline: waitingBoardItem.title,
                    detail: waitingBoardItem.detail,
                    summary: nil,
                    updatedAt: waitingBoardItem.updatedAt,
                    isLive: true,
                    needsAttention: true,
                    canCancel: false,
                    decision: decision
                )
            }
        }

        // 3. Live Cloud/Mac Dialogue work items.
        for entry in onlineSlots {
            if let liveProgress = entry.slot.liveCloudDialogueProgressItems.first {
                let latestEvent = entry.slot.cloudDialogueEvents.last(where: { $0.workItemId == liveProgress.workItemId })
                let updatedAt = latestEvent.flatMap { entry.slot.cloudDialogueFirstSeenAtByEventId[$0.id] } ?? Date()
                return WatchRemoteTaskProjection(
                    runId: "remote:\(entry.origin.rawValue):\(liveProgress.workItemId)",
                    origin: entry.origin,
                    hostName: entry.hostName,
                    workItemId: liveProgress.workItemId,
                    sessionKey: nil,
                    conversationId: liveProgress.conversationId,
                    phase: liveProgress.needsOutcomeUnknownAction ? "waitingForUser" : "running",
                    headline: WatchTaskText.singleLine(liveProgress.topicId, maxLength: 60)
                        ?? (entry.origin == .mac ? "Mac 任务" : "云端任务"),
                    detail: liveProgress.displaySingleLine,
                    summary: nil,
                    updatedAt: updatedAt,
                    isLive: true,
                    needsAttention: liveProgress.needsOutcomeUnknownAction,
                    canCancel: liveProgress.isLive && !liveProgress.isStopRequested && !liveProgress.needsOutcomeUnknownAction,
                    decision: nil
                )
            }
        }

        // 4. Active native Cloud/Mac tasks (`/v2/work-items`).
        for entry in onlineSlots {
            if let activeCloudTask = entry.slot.cloudTasks.first(where: { $0.workItemId != nil && !$0.isTerminal }) {
                let item = activeCloudTask.effectiveWorkItem
                return WatchRemoteTaskProjection(
                    runId: "remote:\(entry.origin.rawValue):\(activeCloudTask.workItemId ?? activeCloudTask.requestId)",
                    origin: entry.origin,
                    hostName: entry.hostName,
                    workItemId: activeCloudTask.workItemId,
                    sessionKey: nil,
                    conversationId: item?.conversationId,
                    phase: item?.state == .waiting ? "waitingForUser" : "running",
                    headline: activeCloudTask.displayTitle,
                    detail: activeCloudTask.summaryLine,
                    summary: nil,
                    updatedAt: activeCloudTask.updatedAt,
                    isLive: true,
                    needsAttention: item?.state == .waiting,
                    canCancel: activeCloudTask.canCancel,
                    decision: nil
                )
            }
        }

        // 5. Running board items.
        for entry in onlineSlots {
            if let runningBoard = entry.slot.boardItems.first(where: { $0.column == .running }) {
                return WatchRemoteTaskProjection(
                    runId: "remote:\(entry.origin.rawValue):\(runningBoard.id)",
                    origin: entry.origin,
                    hostName: entry.hostName,
                    workItemId: nil,
                    sessionKey: runningBoard.sessionKey,
                    conversationId: runningBoard.conversationId,
                    phase: "running",
                    headline: runningBoard.title,
                    detail: runningBoard.detail,
                    summary: nil,
                    updatedAt: runningBoard.updatedAt,
                    isLive: true,
                    needsAttention: false,
                    canCancel: false,
                    decision: nil
                )
            }
        }

        return nil
    }

    private func buildRecentActivities(from slots: [PairedSlot]) -> [WatchRecentActivity] {
        var activities: [WatchRecentActivity] = []
        var seen = Set<String>()

        for entry in slots {
            let origin = entry.origin
            let targetSlot = entry.slot

            for record in targetSlot.cloudTasks where record.isTerminal {
                guard let item = record.effectiveWorkItem else { continue }
                let id = "remote:\(origin.rawValue):task:\(item.id)"
                guard seen.insert(id).inserted else { continue }
                let phase: String = switch item.state {
                case .completed: "completed"
                case .failed: "failed"
                case .cancelled: "cancelled"
                default: "completed"
                }
                let rawSummary = record.detail?.resultMarkdown
                    ?? record.detail?.failure
                    ?? item.progress
                    ?? item.state.displayTitle
                activities.append(WatchRecentActivity(
                    id: id,
                    runId: id,
                    conversationId: item.conversationId,
                    kind: "workflow",
                    phase: phase,
                    title: WatchTaskText.singleLine(record.displayTitle, maxLength: 80) ?? (origin == .mac ? "Mac 任务" : "云端任务"),
                    resultTitle: nil,
                    summary: WatchTaskText.clipped(rawSummary, maxLength: 280) ?? item.state.displayTitle,
                    updatedAt: item.updatedAtDate,
                    origin: origin
                ))
            }

            var dialogueCountForSlot = 0
            for event in targetSlot.cloudDialogueEvents.reversed()
            where (event.kind == .taskResult || event.kind == .assistantReply) && !event.isUpfrontAcknowledgement {
                let trimmed = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let id = "remote:\(origin.rawValue):event:\(event.id)"
                guard seen.insert(id).inserted else { continue }
                let phase = event.outcome == .failed ? "failed" : event.outcome == .cancelled ? "cancelled" : "completed"
                let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                activities.append(WatchRecentActivity(
                    id: id,
                    runId: id,
                    conversationId: event.conversationId,
                    kind: event.kind == .taskResult ? "workflow" : "response",
                    phase: phase,
                    title: WatchTaskText.singleLine(firstLine, maxLength: 60) ?? (origin == .mac ? "Mac 回复" : "云端回复"),
                    resultTitle: nil,
                    summary: WatchTaskText.clipped(trimmed, maxLength: 280) ?? "",
                    updatedAt: targetSlot.cloudDialogueFirstSeenAtByEventId[event.id] ?? Date(),
                    origin: origin
                ))
                dialogueCountForSlot += 1
                if dialogueCountForSlot >= 8 { break }
            }

            for item in targetSlot.boardItems where item.column == .done {
                let id = "remote:\(origin.rawValue):board:\(item.id)"
                guard seen.insert(id).inserted else { continue }
                activities.append(WatchRecentActivity(
                    id: id,
                    runId: id,
                    conversationId: item.conversationId,
                    kind: "workflow",
                    phase: item.failed ? "failed" : "completed",
                    title: WatchTaskText.singleLine(item.title, maxLength: 80) ?? item.title,
                    resultTitle: nil,
                    summary: WatchTaskText.clipped(item.detail, maxLength: 280) ?? "",
                    updatedAt: item.updatedAt,
                    origin: origin
                ))
            }
        }

        return Array(activities.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }.prefix(8))
    }
}
