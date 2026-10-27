import Foundation
import GatewayCore
import GatewayPush
import GatewayTransport

/// Phone-facing HTTPS API (design doc 5.1). Runs on the daemon queue, so it reads and mutates the
/// registry directly.
extension Daemon {
    struct StatusResponse: Encodable {
        struct Gateway: Encodable { var id: String; var name: String }
        struct Device: Encodable { var id: String; var name: String; var pushRegistered: Bool }
        struct Session: Encodable {
            var key: String
            var agent: AgentKind
            var subject: String
            var origin: SessionOrigin
            var host: String?
            var state: TaskState
            var waitReason: WaitReason?
            var abnormal: Bool
            var monitored: Bool
            var updatedAt: Date
            /// Amber scheduled runs waiting on a tool call: what the phone shows and answers.
            var pendingApproval: PendingApproval?
        }
        struct PendingApproval: Encodable {
            var toolCallId: String
            var tool: String
            var detail: String?
            var highRisk: Bool
        }

        var gateway: Gateway
        var device: Device
        var serverTime: Date
        var health: HealthSnapshot?
        var synaraURL: String?
        var sessions: [Session]
    }

    static let statusSessionLimit = 50

    func handleAPI(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        if request.method == "POST", request.path == "/v1/pair" {
            return respond(pair(body))
        }
        let found: PairedDevice?
        do {
            found = try request.bearerToken.flatMap { try devices.device(forToken: $0) }
        } catch {
            // A 401 would make every phone drop its pairing over a file that may be fixable.
            return respond(.error(500, "devices.json 无法解析: \(error)"))
        }
        guard var device = found else {
            return respond(.error(401, "unauthorized"))
        }
        let now = Date()
        if now.timeIntervalSince(device.lastSeenAt) > 60 {
            device.lastSeenAt = now
            updateDevice(device.id) { $0.lastSeenAt = now }
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/status"):
            respond(status(for: device, now: now))
        case ("POST", "/v1/push-token"):
            respond(registerPushToken(body, device: device))
        case ("POST", "/v1/unpair"):
            do {
                try devices.update { $0.removeAll { $0.id == device.id } }
            } catch {
                return respond(.error(500, "\(error)"))
            }
            audit.record("unpair", ["device": device.id, "name": device.name])
            log("device \(device.id) unpaired itself")
            respond(.json(200, [:]))
        case ("POST", "/v1/test-push"):
            guard device.pushToken != nil else { return respond(.error(409, "设备尚未上报推送 token")) }
            let intent = PushIntent(kind: .test, subject: "test", createdAt: now)
            deliver(intent, to: [device]) { results in
                switch results.first?.result {
                case .delivered: respond(.json(200, ["delivered": true]))
                case .invalidToken(let reason): respond(.error(502, "推送 token 已失效: \(reason)"))
                case .failed(let reason): respond(.error(502, reason))
                case nil: respond(.error(500, "no result"))
                }
            }
        case ("POST", "/v1/amber/decision"):
            guard let key = body["sessionKey"] as? String, key.hasPrefix("amber:"), let call = body["toolCallId"] as? String,
                  let allow = body["allow"] as? Bool
            else { return respond(.error(400, "需要 sessionKey、toolCallId 与 allow")) }
            audit.record("amber-decision", ["device": device.id, "task": key, "allow": String(allow)])
            forwardToAmber(.init(action: .decide, sessionKey: key, toolCallId: call, allow: allow, deviceName: device.name), respond: respond)
        case ("GET", "/v1/amber/schedules"):
            forwardToAmber(.init(action: .listSchedules, deviceName: device.name), respond: respond)
        case ("POST", "/v1/amber/schedules"):
            guard let data = try? JSONSerialization.data(withJSONObject: body),
                  let draft = try? GatewayJSON.decoder().decode(AmberControl.ScheduleDraft.self, from: data)
            else { return respond(.error(400, "需要 name、prompt 与 rule")) }
            audit.record("amber-schedule-create", ["device": device.id, "name": draft.name])
            forwardToAmber(.init(action: .createSchedule, draft: draft, deviceName: device.name), respond: respond)
        case ("POST", let path) where path.hasPrefix("/v1/amber/schedules/"):
            let parts = path.dropFirst("/v1/amber/schedules/".count).split(separator: "/").map(String.init)
            guard parts.count == 2, let id = parts[0].removingPercentEncoding else { return respond(.error(404, "not found")) }
            switch parts[1] {
            case "enabled":
                guard let enabled = body["enabled"] as? Bool else { return respond(.error(400, "需要 enabled 布尔值")) }
                audit.record("amber-schedule-enabled", ["device": device.id, "schedule": id, "enabled": String(enabled)])
                forwardToAmber(.init(action: .setScheduleEnabled, scheduleId: id, enabled: enabled, deviceName: device.name), respond: respond)
            case "run":
                audit.record("amber-schedule-run", ["device": device.id, "schedule": id])
                forwardToAmber(.init(action: .runSchedule, scheduleId: id, deviceName: device.name), respond: respond)
            default:
                respond(.error(404, "not found"))
            }
        case ("POST", let path) where path.hasPrefix("/v1/tasks/") && path.hasSuffix("/monitor"):
            let raw = path.dropFirst("/v1/tasks/".count).dropLast("/monitor".count)
            guard let key = String(raw).removingPercentEncoding, let monitored = body["monitored"] as? Bool else {
                return respond(.error(400, "需要 monitored 布尔值"))
            }
            guard registry.setMonitored(key, monitored) else { return respond(.error(404, "任务不存在")) }
            persist()
            updatePendingTimer()
            audit.record("monitor", ["device": device.id, "task": key, "monitored": String(monitored)])
            respond(.json(200, ["monitored": monitored]))
        default:
            respond(.error(404, "not found"))
        }
    }

    private func pair(_ body: [String: Any]) -> HTTPResponse {
        guard let secret = body["secret"] as? String,
              let platform = (body["platform"] as? String).flatMap(DevicePlatform.init(rawValue:))
        else { return .error(400, "需要 secret 与 platform（ios / android / harmony）") }
        guard let data = try? Data(contentsOf: paths.pairing),
              let ticket = try? GatewayJSON.decoder().decode(PairingTicket.self, from: data),
              ticket.expiresAt > Date(), ticket.secretHash == Secrets.sha256(secret)
        else { return .error(403, "配对码无效或已过期，请在 Mac 上重新运行 amber-gateway pair") }
        // Single use: burn the ticket before issuing anything.
        try? FileManager.default.removeItem(at: paths.pairing)

        let name = String((body["deviceName"] as? String ?? platform.rawValue).prefix(64))
        let token = Secrets.random(bytes: 32)
        let device = PairedDevice(id: UUID().uuidString.lowercased(), name: name, platform: platform,
                                  tokenHash: Secrets.sha256(token), pairedAt: Date())
        do {
            try devices.update { $0.append(device) }
        } catch {
            return .error(500, "无法保存设备: \(error)")
        }
        audit.record("pair", ["device": device.id, "name": name, "platform": platform.rawValue])
        log("paired device \(device.id) [\(name), \(platform.rawValue)]")
        return .json(200, ["deviceId": device.id, "token": token, "gatewayId": identity.id, "gatewayName": identity.name])
    }

    private func status(for device: PairedDevice, now: Date) -> HTTPResponse {
        let sessions = registry.sessions.values
            .sorted { ($0.isOpen ? 1 : 0, $0.updatedAt) > ($1.isOpen ? 1 : 0, $1.updatedAt) }
            .prefix(Self.statusSessionLimit)
            .map {
                StatusResponse.Session(key: $0.key, agent: $0.agent, subject: Registry.subject(for: $0), origin: $0.origin,
                                       host: $0.host, state: $0.state, waitReason: $0.waitReason, abnormal: $0.abnormal,
                                       monitored: $0.monitored, updatedAt: $0.updatedAt,
                                       pendingApproval: Self.pendingApproval($0))
            }
        let response = StatusResponse(
            gateway: .init(id: identity.id, name: identity.name),
            device: .init(id: device.id, name: device.name, pushRegistered: device.pushToken != nil),
            serverTime: now,
            health: registry.health,
            synaraURL: config.synaraURL,
            sessions: Array(sessions)
        )
        guard let data = try? GatewayJSON.encoder().encode(response) else { return .error(500, "encode failed") }
        return HTTPResponse(status: 200, body: data)
    }

    /// The Amber app owns scheduled tasks; it answers on its own socket while running. Done off the daemon queue
    /// so a slow app never stalls hooks, then the reply is relayed as-is.
    private func forwardToAmber(_ request: AmberControl.Request, respond: @escaping (HTTPResponse) -> Void) {
        let socket = paths.amberSocket.path
        let queue = queue
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = (try? GatewayJSON.encoder().encode(request))
                .flatMap { UnixSocketClient.request($0, to: socket, timeout: AmberControl.timeout) }
            queue.async {
                guard let reply, let decoded = try? GatewayJSON.decoder().decode(AmberControl.Response.self, from: reply) else {
                    return respond(.error(503, "Amber 未运行：在 Mac 上打开 Amber 后重试"))
                }
                guard decoded.status < 300 else { return respond(.error(decoded.status, decoded.error ?? "操作未完成")) }
                respond(HTTPResponse(status: decoded.status, body: reply))
            }
        }
    }

    static func pendingApproval(_ rec: SessionRecord) -> StatusResponse.PendingApproval? {
        guard rec.agent == .amber, rec.state == .waiting, rec.waitReason == .permission,
              let id = rec.waitingToolCallId, let tool = rec.waitingTool else { return nil }
        return .init(toolCallId: id, tool: tool, detail: rec.waitingDetail, highRisk: rec.waitingHighRisk ?? true)
    }

    private func registerPushToken(_ body: [String: Any], device: PairedDevice) -> HTTPResponse {
        guard let token = body["token"] as? String, !token.isEmpty, token.count <= 4096,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ":_-.+/=".contains($0)) })
        else { return .error(400, "token 非法") }
        let environment = (body["environment"] as? String).flatMap(PushEnvironment.init(rawValue:))
        if device.platform == .ios, environment == nil {
            return .error(400, "iOS 需要 environment（sandbox / production）")
        }
        do {
            // Re-pairing the same phone leaves an older record holding this token; keep only this one.
            try devices.update { list in
                for i in list.indices where list[i].pushToken == token { list[i].pushToken = nil }
                if let i = list.firstIndex(where: { $0.id == device.id }) {
                    list[i].pushToken = token
                    list[i].pushEnvironment = environment
                }
            }
        } catch {
            return .error(500, "无法保存推送 token: \(error)")
        }
        log("push token registered for \(device.id) (\(device.platform.rawValue)\(environment.map { ", \($0.rawValue)" } ?? ""))")
        return .json(200, [:])
    }

    func updateDevice(_ id: String, _ change: (inout PairedDevice) -> Void) {
        do {
            try devices.update { list in
                if let i = list.firstIndex(where: { $0.id == id }) { change(&list[i]) }
            }
        } catch {
            log("devices.json write failed: \(error)")
        }
    }
}
