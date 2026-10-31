import Foundation
@preconcurrency import Shared

/// A foreground-only proposal. It contains public host information, never credentials.
struct IOSSSHHostTrustProposal: Equatable, Sendable {
    let route: [IOSSSHProfile]
    let hopIndex: Int
    let fingerprint: String
}

@MainActor
enum IOSSSHHostTrustApproval {
    static func needsProbe(_ output: IOSLocalToolExecutionOutput) -> Bool {
        switch output {
        case .needsUserAction: return true
        case .terminalResult(let text):
            let status = ChatToolCallParsing.jsonObject(text)?["status"] as? String
            return status == "host_key_untrusted" || status == "host_key_changed"
        default: return false
        }
    }

    static func prepare(
        tool: UIMessagePart.Tool,
        store: SettingsStore,
        runtime: IOSTerminalRuntime = .shared,
        runId: String
    ) async throws -> IshHandoffToolApprovalRequest? {
        guard tool.toolName == "terminal_execute" || tool.toolName == "terminal_job_start" else { return nil }
        let args = ChatToolCallParsing.jsonObject(tool.input) ?? [:]
        let requestedId = (args["profile_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = requestedId.flatMap { id in store.sshProfiles.first { $0.id == id } } ?? (requestedId == nil ? store.defaultSSHProfile : nil)
        guard let target else { return nil }
        var route = try store.resolveSSHRoute(for: target)
        var credentials: [String: IOSSSHCredential] = [:]
        for hop in route.dropLast() {
            guard hop.knownHostSHA256 != nil else { break }
            credentials[hop.id] = try store.credentialForSSHProfile(hop)
        }
        route = try store.resolveSSHRoute(for: target.id)
        let probes = try await runtime.testSSHRoute(route: route, credentials: credentials)
        try Task.checkCancellation()
        guard try store.resolveSSHRoute(for: target.id) == route else {
            throw IOSSSHError.invalidProfile("SSH 路由已变化，请重新发起操作。")
        }
        guard let probe = probes.last else { return nil }
        let changed: Bool
        switch probe.trustState {
        case .trusted: return nil
        case .needsTrust: changed = false
        case .mismatch: changed = true
        }
        let hop = route[probe.hopIndex - 1]
        let label = "第 \(probe.hopIndex)/\(route.count) 跳（\(hop.displayName)）"
        return IshHandoffToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: tool), mode: .remoteSSH,
            commandPreview: (args["command"] as? String) ?? tool.input,
            filename: "\(hop.username)@\(hop.host):\(hop.port)",
            reason: changed ? "\(label)主机指纹变化，已拦截。请到设置中人工核对并替换。" : "\(label)首次连接。确认公钥指纹后才能信任；本次不会执行命令。",
            contextLines: route.enumerated().map { "第 \($0.offset + 1) 跳 · \($0.element.displayName) · \($0.element.username)@\($0.element.host):\($0.element.port)" }
                + ["当前指纹：\(probe.fingerprint)"]
                + (changed ? ["原指纹：\(hop.knownHostSHA256 ?? "")"] : []),
            remoteProfileId: target.id, remoteTargetDigest: remoteSSHTargetDigest(route: route),
            runId: runId, allowsApprove: !changed, requiresForegroundApproval: true,
            remoteHostTrust: changed ? nil : IOSSSHHostTrustProposal(route: route, hopIndex: probe.hopIndex, fingerprint: probe.fingerprint)
        )
    }

    static func accept(_ proposal: IOSSSHHostTrustProposal, store: SettingsStore) throws {
        guard let target = proposal.route.last,
              proposal.route.indices.contains(proposal.hopIndex - 1),
              try store.resolveSSHRoute(for: target.id) == proposal.route else {
            throw IOSSSHError.invalidProfile("待信任的 SSH 路由已变化，请重新检查指纹。")
        }
        let hop = proposal.route[proposal.hopIndex - 1]
        guard hop.knownHostSHA256 == nil else {
            throw IOSSSHError.invalidProfile("已保存的主机指纹只能在设置中替换。")
        }
        try store.trustHost(profileId: hop.id, fingerprint: proposal.fingerprint)
    }
}
