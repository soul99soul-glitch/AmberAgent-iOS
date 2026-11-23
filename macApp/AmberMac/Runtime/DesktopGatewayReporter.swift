import CryptoKit
import Foundation
@preconcurrency import GatewayCore
@preconcurrency import GatewayTransport
@preconcurrency import HookIngest

/// Reports scheduled runs to the Mac Gateway as `amber` sessions (key `amber:<run record id>`), so the phone sees
/// them and gets pushed when one waits for approval or ends. The gateway watches this process, so a crashed
/// Amber marks its runs 意外中断. Delivery uses the same socket-or-spool path as hooks, off the main actor.
@MainActor final class DesktopGatewayReporter {
    private let paths: GatewayPaths
    private let isEnabled: @MainActor () -> Bool
    private let process: ProcessIdentity?
    private let queue = DispatchQueue(label: "amber.gateway.reporter")
    /// Runs in flight: conversation → run metadata, so approval callbacks can find their run without blocking local Q&A.
    private struct RunMetadata {
        var session: String
        var name: String
        var parentRunId: String?
        var remoteConversationId: String?
        var workItemId: String?
        var sourceRefs: [String] = []
        var sourcePaths: [String] = []
    }
    private var runs: [UUID: RunMetadata] = [:]
    /// `toolDone` must name the call it answers: the last one asked per conversation.
    private var pendingCall: [UUID: (tool: String, id: String)] = [:]

    static let detailLimit = 120

    init(paths: GatewayPaths = .resolve(), isEnabled: @escaping @MainActor () -> Bool,
         process: ProcessIdentity? = ProcessTree.identity(pid: getpid())) {
        self.paths = paths; self.isEnabled = isEnabled; self.process = process
    }

    /// Gateway session key of a run in flight, if the gateway saw it start.
    func sessionKey(forConversation conversation: UUID) -> String? {
        runs[conversation].map { "amber:" + $0.session }
    }

    /// Conversation of a reported run, from its gateway session key (`amber:<run id>`).
    func conversation(forSessionKey key: String) -> UUID? {
        runs.first { "amber:" + $0.value.session == key }?.key
    }

    /// Whether a run is reported is decided once, here: a run the gateway saw start always gets its end,
    /// even if the gateway is switched off meanwhile, so no session is left open on the phone.
    func runStarted(runID: UUID, conversationID: UUID, taskName: String, parentRunId: String? = nil, workItemId: String? = nil, remoteConversationId: String? = nil) {
        guard workItemId != nil || isEnabled() else { return }
        runs[conversationID] = RunMetadata(session: runID.uuidString.lowercased(), name: taskName, parentRunId: parentRunId, remoteConversationId: remoteConversationId, workItemId: workItemId)
        send(.runStart, conversationID: conversationID)
    }

    func approval(conversationID: UUID, _ approval: DesktopToolApproval?) {
        if let approval {
            let meta = DesktopToolRegistry.approvalMetadata(for: approval.name, arguments: approval.arguments)
            send(.permissionRequest, conversationID: conversationID) {
                $0.tool = approval.name
                $0.toolCallId = approval.id
                $0.detail = Self.excerpt(approval.arguments)
                $0.highRisk = meta.riskLevel == .l3
                $0.riskLevel = meta.riskLevel.rawValue
                $0.targetDevice = meta.targetDevice
                $0.targetSummary = meta.targetSummary
                $0.diffPreview = meta.diffPreview
                $0.requiresLocalApproval = meta.requiresLocalApproval
            }
        } else {
            send(.toolDone, conversationID: conversationID) { _ in }
        }
    }

    func recordRead(conversationID: UUID, path: String, text: String) {
        guard var run = runs[conversationID] else { return }
        let safePath = DesktopHistoryRedaction.redact(path)
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let reference = "\(safePath) · sha256:\(digest)"
        if !run.sourcePaths.contains(safePath) { run.sourcePaths.append(safePath) }
        if !run.sourceRefs.contains(reference) { run.sourceRefs.append(reference) }
        runs[conversationID] = run
    }

    func sources(forConversation conversationID: UUID) -> (refs: [String], paths: [String]) {
        guard let run = runs[conversationID] else { return ([], []) }
        return (run.sourceRefs, run.sourcePaths)
    }

    /// `quiet`: completed with nothing new, so the gateway records it without pushing (failures push regardless).
    func runFinished(
        conversationID: UUID?,
        succeeded: Bool,
        cancelled: Bool = false,
        quiet: Bool = false
    ) {
        guard let conversationID, let run = runs[conversationID] else { return }
        send(.runExit, conversationID: conversationID) {
            $0.exitCode = succeeded ? 0 : 1
            if cancelled { $0.cancelled = true }
            if quiet { $0.quiet = true }
            if !run.sourceRefs.isEmpty { $0.sourceRefs = run.sourceRefs }
            if !run.sourcePaths.isEmpty { $0.sourcePaths = run.sourcePaths }
        }
        runs[conversationID] = nil
        pendingCall[conversationID] = nil
    }

    private func send(_ kind: EventKind, conversationID: UUID, _ fill: (inout GatewayEvent) -> Void = { _ in }) {
        guard let run = runs[conversationID] else { return }
        var event = GatewayEvent(agent: .amber, kind: kind, sessionId: run.session, process: process, origin: .headless, title: run.name)
        event.conversationId = conversationID.uuidString.lowercased()
        if run.workItemId != nil {
            // Only the summary is private display data. The title also goes to push providers.
            event.title = "Mac 委派任务"
            event.summary = run.name
            event.remoteConversationId = run.remoteConversationId
        }
        event.parentRunId = run.parentRunId
        event.workItemId = run.workItemId
        fill(&event)
        if kind == .permissionRequest, let tool = event.tool, let id = event.toolCallId { pendingCall[conversationID] = (tool, id) }
        if kind == .toolDone, let call = pendingCall.removeValue(forKey: conversationID) {
            event.tool = call.tool
            event.toolCallId = call.id
        }
        let paths = paths
        let delivered = event
        queue.async { EventDelivery.deliver(delivered, paths: paths) }
    }

    /// Whitespace-collapsed argument excerpt. Over TLS only (`/v1/status`), never in a push body.
    static func excerpt(_ arguments: String) -> String? {
        var maskedCredential = false
        let redacted = IOSCredentialRedactor.redact(arguments) { _, _ in maskedCredential = true }
        let safe = DesktopHistoryRedaction.redact(maskedCredential ? redacted : arguments)
        let collapsed = safe.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty, collapsed != "{}" else { return nil }
        return collapsed.count > detailLimit ? String(collapsed.prefix(detailLimit - 1)) + "…" : collapsed
    }
}
