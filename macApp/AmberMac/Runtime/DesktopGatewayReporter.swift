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
    /// Runs in flight: conversation → (session id, task name), so approval callbacks can find their run.
    private var runs: [UUID: (session: String, name: String)] = [:]
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
    func runStarted(runID: UUID, conversationID: UUID, taskName: String) {
        guard isEnabled() else { return }
        runs[conversationID] = (runID.uuidString.lowercased(), taskName)
        send(.runStart, conversationID: conversationID)
    }

    func approval(conversationID: UUID, _ approval: DesktopToolApproval?) {
        if let approval {
            send(.permissionRequest, conversationID: conversationID) {
                $0.tool = approval.name
                $0.toolCallId = approval.id
                $0.detail = Self.excerpt(approval.arguments)
                $0.highRisk = DesktopToolRegistry.isHighRisk(approval.name)
            }
        } else {
            send(.toolDone, conversationID: conversationID) { _ in }
        }
    }

    /// `quiet`: completed with nothing new, so the gateway records it without pushing (failures push regardless).
    func runFinished(conversationID: UUID?, succeeded: Bool, quiet: Bool = false) {
        guard let conversationID else { return }
        send(.runExit, conversationID: conversationID) {
            $0.exitCode = succeeded ? 0 : 1
            if quiet { $0.quiet = true }
        }
        runs[conversationID] = nil
        pendingCall[conversationID] = nil
    }

    private func send(_ kind: EventKind, conversationID: UUID, _ fill: (inout GatewayEvent) -> Void = { _ in }) {
        guard let run = runs[conversationID] else { return }
        var event = GatewayEvent(agent: .amber, kind: kind, sessionId: run.session, process: process, origin: .headless, title: run.name)
        fill(&event)
        if kind == .permissionRequest, let tool = event.tool, let id = event.toolCallId { pendingCall[conversationID] = (tool, id) }
        if kind == .toolDone, let call = pendingCall.removeValue(forKey: conversationID) {
            event.tool = call.tool
            event.toolCallId = call.id
        }
        let paths = paths
        queue.async { EventDelivery.deliver(event, paths: paths) }
    }

    /// Whitespace-collapsed argument excerpt. Over TLS only (`/v1/status`), never in a push body.
    static func excerpt(_ arguments: String) -> String? {
        let collapsed = arguments.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty, collapsed != "{}" else { return nil }
        return collapsed.count > detailLimit ? String(collapsed.prefix(detailLimit - 1)) + "…" : collapsed
    }
}
