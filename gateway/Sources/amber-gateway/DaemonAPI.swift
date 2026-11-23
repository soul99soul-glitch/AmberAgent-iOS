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
            /// Opening words of the first prompt; the phone shows it in place of `subject` when present.
            var summary: String?
            var origin: SessionOrigin
            var host: String?
            var state: TaskState
            var waitReason: WaitReason?
            var abnormal: Bool
            var monitored: Bool
            var updatedAt: Date
            /// Amber scheduled runs waiting on a tool call: what the phone shows and answers.
            var pendingApproval: PendingApproval?
            var sourceRefs: [String]?
            var sourcePaths: [String]?
        }
        struct PendingApproval: Encodable {
            var toolCallId: String
            var tool: String
            var detail: String?
            var highRisk: Bool
            var summary: String?
            var targetDeviceName: String?
            var riskLevel: String?
            var targetDevice: String?
            var targetSummary: String?
            var diffPreview: String?
            var requiresLocalApproval: Bool?
        }

        var gateway: Gateway
        var device: Device
        var serverTime: Date
        var health: HealthSnapshot?
        var synaraURL: String?
        var soulRevision: Int64
        var sessions: [Session]
    }

    static let statusSessionLimit = 50
    static let maxDialogueBodyBytes = 100_000

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
            var auditFields: [String: String] = [
                "device": device.id,
                "task": key,
                "run": String(key.dropFirst("amber:".count)),
                "toolCallId": call,
                "allow": String(allow),
                "decision": allow ? "allow" : "deny"
            ]
            if let tool = registry.sessions[key]?.waitingTool ?? (body["tool"] as? String), !tool.isEmpty {
                auditFields["tool"] = tool
            }
            audit.record("amber-decision", auditFields)
            forwardToAmber(.init(action: .decide, sessionKey: key, toolCallId: call, allow: allow, deviceName: device.name), respond: respond)
        case ("GET", "/v1/amber/board"):
            forwardToAmber(.init(action: .board, deviceName: device.name), respond: respond)
        case ("GET", "/v2/soul"):
            forwardSoulToAmber(.init(action: .getSoul, deviceName: device.name), respond: respond)
        case ("PUT", "/v2/soul"):
            let payloadData = request.body.isEmpty ? Data("{}".utf8) : request.body
            guard let soulPut = try? JSONDecoder().decode(AmberControl.SoulPutRequest.self, from: payloadData) else {
                return respond(.error(400, "请求格式无法解析"))
            }
            audit.record("amber-soul-put", ["device": device.id, "source": soulPut.source ?? "remote"])
            forwardSoulToAmber(.init(action: .putSoul, deviceName: device.name, soulPut: soulPut), respond: respond)
        case ("POST", "/v2/dialogue/messages"):
            guard request.body.count <= Self.maxDialogueBodyBytes,
                  let rawBody = String(data: request.body, encoding: .utf8) else {
                return respond(.error(400, "invalid_request"))
            }
            let dialogueVersion = request.headers["x-amber-dialogue-version"]
            audit.record("amber-dialogue-message", Self.dialogueAuditFields(device: device, body: body, version: dialogueVersion))
            forwardDialogueToAmber(
                .init(action: .dialogueMessage, deviceName: device.name, deviceId: device.id,
                      dialogueVersion: dialogueVersion, rawBody: rawBody),
                respond: respond
            )
        case ("POST", let path) where path.hasPrefix("/v2/work-items/"):
            let suffix = String(path.dropFirst("/v2/work-items/".count))
            let parts = suffix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty,
                  let workItemId = parts[0].removingPercentEncoding, !workItemId.isEmpty else {
                return respond(.error(404, "not found"))
            }
            let dialogueVersion = request.headers["x-amber-dialogue-version"]
            switch parts[1] {
            case "inputs":
                guard request.body.count <= Self.maxDialogueBodyBytes,
                      let rawBody = String(data: request.body, encoding: .utf8) else {
                    return respond(.error(400, "invalid_request"))
                }
                audit.record("amber-dialogue-followup", Self.dialogueAuditFields(device: device, body: body, workItemId: workItemId, version: dialogueVersion))
                forwardDialogueToAmber(
                    .init(action: .dialogueFollowup, deviceName: device.name, deviceId: device.id,
                          dialogueVersion: dialogueVersion, workItemId: workItemId, rawBody: rawBody),
                    respond: respond
                )
            case "stop":
                guard request.body.count <= Self.maxDialogueBodyBytes,
                      let rawBody = String(data: request.body, encoding: .utf8) else {
                    return respond(.error(400, "invalid_request"))
                }
                audit.record("amber-dialogue-stop", Self.dialogueAuditFields(device: device, body: body, workItemId: workItemId, version: dialogueVersion))
                forwardDialogueToAmber(
                    .init(action: .dialogueStop, deviceName: device.name, deviceId: device.id,
                          dialogueVersion: dialogueVersion, workItemId: workItemId, rawBody: rawBody),
                    respond: respond
                )
            default:
                respond(.error(404, "not found"))
            }
        case ("GET", let path) where path.hasPrefix("/v2/dialogue/receipts/"):
            let rawSegment = String(path.dropFirst("/v2/dialogue/receipts/".count))
            guard !rawSegment.isEmpty, !rawSegment.contains("/"),
                  let requestId = rawSegment.removingPercentEncoding, !requestId.isEmpty else {
                return respond(.error(404, "not found"))
            }
            let dialogueVersion = request.headers["x-amber-dialogue-version"]
            forwardDialogueToAmber(
                .init(action: .dialogueReceipt, deviceName: device.name, deviceId: device.id,
                      dialogueVersion: dialogueVersion, requestId: requestId),
                respond: respond
            )
        case ("GET", "/v2/dialogue/events"), ("GET", "/v2/dialogue/timeline"):
            let params = request.queryParameters
            let after: Int64
            if let rawAfter = params["after"] {
                guard let parsed = Int64(rawAfter), parsed >= 0 else {
                    return respond(.error(400, "invalid_cursor"))
                }
                after = parsed
            } else {
                after = 0
            }
            let limit: Int
            if let rawLimit = params["limit"] {
                guard let parsed = Int(rawLimit), (1...100).contains(parsed) else {
                    return respond(.error(400, "invalid_cursor"))
                }
                limit = parsed
            } else {
                limit = 100
            }
            let dialogueVersion = request.headers["x-amber-dialogue-version"]
            forwardDialogueToAmber(
                .init(action: .dialogueEvents, deviceName: device.name, deviceId: device.id,
                      dialogueVersion: dialogueVersion, after: after, limit: limit),
                respond: respond
            )
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
              ticket.expiresAt.timeIntervalSince(Date()) > 0, ticket.secretHash == Secrets.sha256(secret)
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
            .sorted { ($0.isOpen ? 1 : 0, $0.updatedAt.timeIntervalSince1970) > ($1.isOpen ? 1 : 0, $1.updatedAt.timeIntervalSince1970) }
            .prefix(Self.statusSessionLimit)
            .map {
                StatusResponse.Session(key: $0.key, agent: $0.agent, subject: Registry.subject(for: $0), summary: $0.generatedTitle ?? $0.summary, origin: $0.origin,
                                       host: $0.host, state: $0.state, waitReason: $0.waitReason, abnormal: $0.abnormal,
                                       monitored: $0.monitored, updatedAt: $0.updatedAt,
                                       pendingApproval: Self.pendingApproval($0), sourceRefs: $0.sourceRefs, sourcePaths: $0.sourcePaths)
            }
        let response = StatusResponse(
            gateway: .init(id: identity.id, name: identity.name),
            device: .init(id: device.id, name: device.name, pushRegistered: device.pushToken != nil),
            serverTime: now,
            health: registry.health,
            synaraURL: config.synaraURL,
            soulRevision: Self.readSoulRevision(paths: paths),
            sessions: Array(sessions)
        )
        guard let data = try? GatewayJSON.encoder().encode(response) else { return .error(500, "encode failed") }
        return HTTPResponse(status: 200, body: data)
    }

    private static func readSoulRevision(paths: GatewayPaths) -> Int64 {
        guard let text = try? String(contentsOf: paths.soulRevision, encoding: .utf8) else { return 0 }
        return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func dialogueAuditFields(device: PairedDevice, body: [String: Any], workItemId: String? = nil, version: String?) -> [String: String] {
        var fields: [String: String] = [
            "device": device.id,
            "version": version ?? "legacy"
        ]
        if let workItemId, !workItemId.isEmpty { fields["workItemId"] = workItemId }
        if let requestId = body["requestId"] as? String, !requestId.isEmpty { fields["requestId"] = String(requestId.prefix(128)) }
        if let conversationId = body["conversationId"] as? String, !conversationId.isEmpty { fields["conversationId"] = String(conversationId.prefix(128)) }
        return fields
    }

    private func forwardDialogueToAmber(_ request: AmberControl.Request, respond: @escaping (HTTPResponse) -> Void) {
        let socket = paths.amberSocket.path
        let queue = queue
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = (try? GatewayJSON.encoder().encode(request))
                .flatMap { UnixSocketClient.request($0, to: socket, timeout: AmberControl.timeout) }
            queue.async {
                guard let reply, let decoded = try? GatewayJSON.decoder().decode(AmberControl.Response.self, from: reply) else {
                    return respond(.error(503, "Amber 未运行：在 Mac 上打开 Amber 后重试"))
                }
                if let rawJSON = decoded.rawJSON {
                    return respond(HTTPResponse(status: decoded.status, body: Data(rawJSON.utf8)))
                }
                guard decoded.status < 300 else {
                    return respond(.error(decoded.status, decoded.error ?? "internal_error"))
                }
                respond(.error(500, "empty_response"))
            }
        }
    }

    private func forwardSoulToAmber(_ request: AmberControl.Request, respond: @escaping (HTTPResponse) -> Void) {
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
                guard let soul = decoded.soul, let encoded = try? JSONEncoder().encode(soul) else {
                    return respond(.error(500, "无法编码形象人设状态"))
                }
                respond(HTTPResponse(status: decoded.status, body: encoded))
            }
        }
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
                guard decoded.status < 300 else {
                    if decoded.requiresLocalApproval != nil || decoded.riskLevel != nil || decoded.targetDevice != nil || decoded.targetSummary != nil {
                        var payload: [String: Any] = ["error": decoded.error ?? "操作未完成"]
                        if let requiresLocalApproval = decoded.requiresLocalApproval { payload["requiresLocalApproval"] = requiresLocalApproval }
                        if let riskLevel = decoded.riskLevel { payload["riskLevel"] = riskLevel }
                        if let targetDevice = decoded.targetDevice { payload["targetDevice"] = targetDevice }
                        if let targetSummary = decoded.targetSummary { payload["targetSummary"] = targetSummary }
                        if let diffPreview = decoded.diffPreview { payload["diffPreview"] = diffPreview }
                        return respond(.json(decoded.status, payload))
                    }
                    return respond(.error(decoded.status, decoded.error ?? "操作未完成"))
                }
                respond(HTTPResponse(status: decoded.status, body: reply))
            }
        }
    }

    static func pendingApproval(_ rec: SessionRecord) -> StatusResponse.PendingApproval? {
        guard rec.agent == .amber, rec.state == .waiting, rec.waitReason == .permission,
              let id = rec.waitingToolCallId, let tool = rec.waitingTool else { return nil }
        let highRisk = rec.waitingHighRisk ?? true
        return .init(
            toolCallId: id,
            tool: tool,
            detail: rec.waitingDetail,
            highRisk: highRisk,
            summary: rec.waitingTargetSummary,
            targetDeviceName: rec.waitingTargetDevice,
            riskLevel: rec.waitingRiskLevel ?? (highRisk ? "L3" : "L2"),
            targetDevice: rec.waitingTargetDevice,
            targetSummary: rec.waitingTargetSummary,
            diffPreview: rec.waitingDiffPreview,
            requiresLocalApproval: rec.waitingRequiresLocalApproval ?? highRisk
        )
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
