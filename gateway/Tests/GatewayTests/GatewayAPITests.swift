import CryptoKit
import Foundation
import Testing
@testable import GatewayCore
@testable import GatewayTransport

/// Phone-side client as the apps implement it: trust = SPKI SHA-256 match, never the system trust store.
final class PinnedClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    let fingerprint: String
    lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              (try? TLSIdentity.spkiFingerprint(of: leaf)) == fingerprint
        else { return completionHandler(.cancelAuthenticationChallenge, nil) }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func call(_ method: String, _ url: URL, token: String? = nil, body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as! HTTPURLResponse).statusCode, json)
    }
}

@Suite("gateway HTTPS API (built binary)", .serialized)
final class GatewayAPITests {
    let bin: URL
    let state: URL
    let paths: GatewayPaths
    let port = TestSupport.freePort()
    var daemon: Process?

    init() throws {
        bin = try TestSupport.binary()
        state = try TestSupport.tempDir()
        paths = GatewayPaths(stateDir: state)
        try TestSupport.payload(["port": Int(port)]).write(to: paths.config)
    }

    deinit {
        // Async tests deinit on a cooperative thread without a run loop, where waitUntilExit never returns.
        if let daemon, daemon.isRunning {
            daemon.terminate()
            _ = TestSupport.eventually { !daemon.isRunning }
        }
        try? FileManager.default.removeItem(at: state)
    }

    func startDaemon() throws {
        let p = Process()
        p.executableURL = bin
        p.arguments = ["daemon"]
        p.environment = [GatewayPaths.stateDirEnv: state.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        daemon = p
        try #require(TestSupport.eventually { FileManager.default.fileExists(atPath: self.paths.socket.path) })
    }

    func pairingPayload() throws -> PairingPayload {
        let r = try TestSupport.run(bin, ["pair", "--json"], stateDir: state)
        try #require(r.status == 0, "pair failed: \(String(decoding: r.stderr, as: UTF8.self))")
        return try #require(PairingPayload.parse(url: String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func fingerprintMatchesOpenSSLsSPKIDigest() throws {
        try startDaemon()
        let payload = try pairingPayload()
        let script = """
        /usr/bin/openssl pkcs12 -in '\(paths.tlsIdentity.path)' -nokeys -passin pass:\(TLSIdentity.passphrase) \
        | /usr/bin/openssl x509 -pubkey -noout | /usr/bin/openssl pkey -pubin -outform DER \
        | /usr/bin/openssl dgst -sha256 -binary | /usr/bin/base64
        """
        let r = try TestSupport.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script], stateDir: state)
        #expect(String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == payload.fp)
        #expect(payload.port == port)
        #expect(payload.addrs.first?.hasSuffix(".local") == true)
    }

    /// Off-LAN the phone fails `.local` instantly and should hit the public address next, not wait out LAN IPs.
    @Test(.enabled(if: !CandidateAddresses.ipv4Addresses().isEmpty, "needs a LAN IPv4 to check the ordering"))
    func publicAddressesFollowLocalNameAndPrecedeLANIPs() throws {
        try startDaemon()
        try TestSupport.payload(["port": Int(port), "publicAddresses": ["gw.example.net"]]).write(to: paths.config)
        let addrs = try pairingPayload().addrs
        let index = try #require(addrs.firstIndex(of: "gw.example.net"))
        #expect(addrs[..<index].allSatisfy { !$0.first!.isNumber })
        #expect(addrs[(index + 1)...].allSatisfy { $0.first!.isNumber })
        #expect(addrs.first?.hasSuffix(".local") == true)
    }

    /// Exposed on the internet, idle sockets must not starve the daemon of file descriptors.
    @Test func idleConnectionsAreCappedAndReleased() async throws {
        try startDaemon()
        let payload = try pairingPayload()
        let client = PinnedClient(fingerprint: payload.fp)
        let status = URL(string: "https://127.0.0.1:\(payload.port)/v1/status")!
        var idle: [Int32] = []
        defer { idle.forEach { close($0) } }
        for _ in 0..<HTTPServer.maxConnections {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                   sin_port: payload.port.bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            try #require(connected == 0)
            idle.append(fd)
        }
        try await Task.sleep(for: .milliseconds(300))
        await #expect(throws: (any Error).self) { _ = try await client.call("GET", status) }
        idle.forEach { close($0) }
        idle = []
        var code = 0
        for _ in 0..<30 where code != 401 {
            code = (try? await client.call("GET", status).0) ?? 0
            if code != 401 { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(code == 401, "slots are released once the idle sockets close")
    }

    /// Phone → daemon → Amber app socket. A stand-in app answers; without it the daemon says Amber isn't running.
    @Test func amberRequestsAreForwardedToTheAppSocketAndRelayed() async throws {
        try startDaemon()
        let payload = try pairingPayload()
        let client = PinnedClient(fingerprint: payload.fp)
        let base = URL(string: "https://127.0.0.1:\(payload.port)")!
        let (_, paired) = try await client.call("POST", base.appendingPathComponent("v1/pair"),
                                                body: ["secret": payload.s, "platform": "ios", "deviceName": "测试 iPhone"])
        let token = try #require(paired["token"] as? String)
        let decision = base.appendingPathComponent("v1/amber/decision")
        let body: [String: Any] = ["sessionKey": "amber:run-1", "toolCallId": "c1", "allow": true]

        var (code, json) = try await client.call("POST", decision, token: token, body: body)
        #expect(code == 503)
        #expect((json["error"] as? String)?.contains("Amber 未运行") == true)
        #expect(try await client.call("POST", decision, body: body).0 == 401, "unpaired callers never reach the app")
        #expect(try await client.call("POST", decision, token: token, body: ["sessionKey": "claude:x", "toolCallId": "c", "allow": true]).0 == 400)

        let received = Locked<[AmberControl.Request]>([])
        let queue = DispatchQueue(label: "fake-amber")
        let app = UnixSocketServer(path: paths.amberSocket.path, queue: queue) { data in
            guard let request = try? GatewayJSON.decoder().decode(AmberControl.Request.self, from: data) else { return nil }
            received.mutate { $0.append(request) }
            let response: AmberControl.Response = switch request.action {
            case .decide: request.toolCallId == "c1" ? .init(status: 200) : .failure(409, "这次审批已经结束")
            case .listSchedules: .init(status: 200, schedules: [.init(id: "s1", name: "每日汇总", rule: "每天 09:00", enabled: true, running: false,
                                                                       nextRunAt: nil, lastStatus: "completed", lastRunAt: nil, autoApprovesHighRisk: false)])
            default: .init(status: 200)
            }
            return try? GatewayJSON.encoder().encode(response)
        }
        try app.start()
        defer { app.stop() }

        (code, _) = try await client.call("POST", decision, token: token, body: body)
        #expect(code == 200)
        (code, json) = try await client.call("POST", decision, token: token, body: ["sessionKey": "amber:run-1", "toolCallId": "old", "allow": false])
        #expect(code == 409)
        #expect(json["error"] as? String == "这次审批已经结束")
        (code, json) = try await client.call("GET", base.appendingPathComponent("v1/amber/schedules"), token: token)
        #expect(code == 200)
        #expect(((json["schedules"] as? [[String: Any]])?.first?["name"] as? String) == "每日汇总")
        (code, _) = try await client.call("POST", base.appendingPathComponent("v1/amber/schedules/s1/enabled"), token: token, body: ["enabled": false])
        #expect(code == 200)
        (code, _) = try await client.call("POST", base.appendingPathComponent("v1/amber/schedules"), token: token,
                                          body: ["name": "周报", "prompt": "写周报", "rule": "weekly", "hour": 17, "minute": 0, "weekdays": [6]])
        #expect(code == 200)

        let requests = received.value
        #expect(requests.map(\.action) == [.decide, .decide, .listSchedules, .setScheduleEnabled, .createSchedule])
        #expect(requests[0].sessionKey == "amber:run-1" && requests[0].allow == true && requests[0].deviceName == "测试 iPhone")
        #expect(requests[3].scheduleId == "s1" && requests[3].enabled == false)
        #expect(requests[4].draft?.weekdays == [6])
        let audit = try String(contentsOf: paths.audit, encoding: .utf8)
        #expect(audit.contains("amber-decision") && audit.contains("amber-schedule-create"))
    }

    @Test func pairStatusMonitorPushTokenRevoke() async throws {
        try startDaemon()
        let payload = try pairingPayload()
        let client = PinnedClient(fingerprint: payload.fp)
        let base = URL(string: "https://127.0.0.1:\(payload.port)")!

        var (code, json) = try await client.call("POST", base.appendingPathComponent("v1/pair"), body: ["secret": "wrong", "platform": "ios"])
        #expect(code == 403)
        (code, json) = try await client.call("POST", base.appendingPathComponent("v1/pair"),
                                             body: ["secret": payload.s, "platform": "ios", "deviceName": "测试 iPhone"])
        #expect(code == 200)
        let token = try #require(json["token"] as? String)
        let deviceId = try #require(json["deviceId"] as? String)
        #expect(json["gatewayId"] as? String == payload.id)
        (code, _) = try await client.call("POST", base.appendingPathComponent("v1/pair"), body: ["secret": payload.s, "platform": "ios"])
        #expect(code == 403, "pairing secret is single use")
        #expect(!(try String(contentsOf: paths.devices, encoding: .utf8)).contains(token), "only the token hash is stored")

        (code, _) = try await client.call("GET", base.appendingPathComponent("v1/status"))
        #expect(code == 401)
        #expect(try TestSupport.run(bin, ["run", "--", "true"], stateDir: state).status == 0)
        #expect(TestSupport.eventually { RegistryStore(url: self.paths.registry).load().sessions.values.contains { $0.agent == .run } })
        (code, json) = try await client.call("GET", base.appendingPathComponent("v1/status"), token: token)
        #expect(code == 200)
        #expect((json["device"] as? [String: Any])?["pushRegistered"] as? Bool == false)
        let sessions = try #require(json["sessions"] as? [[String: Any]])
        let task = try #require(sessions.first { $0["agent"] as? String == "run" })
        #expect(task["state"] as? String == "completed")
        #expect(task["subject"] as? String == "true")

        let key = try #require(task["key"] as? String)
        let monitorURL = URL(string: "https://127.0.0.1:\(payload.port)/v1/tasks/\(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)/monitor")!
        (code, _) = try await client.call("POST", monitorURL, token: token, body: ["monitored": false])
        #expect(code == 200)
        #expect(RegistryStore(url: paths.registry).load().sessions[key]?.monitored == false)

        (code, _) = try await client.call("POST", base.appendingPathComponent("v1/push-token"), token: token, body: ["token": "abc123", "platform": "ios"])
        #expect(code == 400, "iOS token needs an APNs environment")
        (code, _) = try await client.call("POST", base.appendingPathComponent("v1/push-token"), token: token,
                                          body: ["token": "abc123", "platform": "ios", "environment": "sandbox"])
        #expect(code == 200)
        let device = try #require(DeviceStore(url: paths.devices).load().first)
        #expect(device.pushToken == "abc123" && device.pushEnvironment == .sandbox)

        (code, json) = try await client.call("POST", base.appendingPathComponent("v1/test-push"), token: token)
        #expect(code == 502)
        #expect((json["error"] as? String)?.contains("APNs") == true, "no credentials imported: the error must say so")

        let revoke = try TestSupport.run(bin, ["devices", "revoke", String(deviceId.prefix(8))], stateDir: state)
        #expect(revoke.status == 0)
        (code, _) = try await client.call("GET", base.appendingPathComponent("v1/status"), token: token)
        #expect(code == 401, "revoked device is locked out immediately")
    }

    /// The phone learns where to reply from the status it already polls; tasks say which app hosts them.
    @Test func statusCarriesSynaraURLAndTaskHost() async throws {
        var rec = SessionRecord(key: "claude:s", agent: .claude, sessionId: "s", cwd: "/w/app", title: nil, origin: .host,
                                state: .waiting, waitReason: .turnEnd, abnormal: false, sawTurnEnd: true, sawFailure: false,
                                process: nil, startedAt: Date(), updatedAt: Date(), monitored: true, pendingPushSince: nil, lastPushAt: [:])
        rec.host = "Synara"
        var registry = Registry()
        registry.sessions[rec.key] = rec
        try RegistryStore(url: paths.registry).save(registry)
        try TestSupport.payload(["port": Int(port), "synaraURL": "https://synara.example/?gate=x"]).write(to: paths.config)
        try startDaemon()
        let payload = try pairingPayload()
        let client = PinnedClient(fingerprint: payload.fp)
        let base = URL(string: "https://127.0.0.1:\(payload.port)")!
        var (_, json) = try await client.call("POST", base.appendingPathComponent("v1/pair"), body: ["secret": payload.s, "platform": "android"])
        let token = try #require(json["token"] as? String)
        (_, json) = try await client.call("GET", base.appendingPathComponent("v1/status"), token: token)
        #expect(json["synaraURL"] as? String == "https://synara.example/?gate=x")
        let task = try #require((json["sessions"] as? [[String: Any]])?.first)
        #expect(task["host"] as? String == "Synara")
    }

    @Test func deviceCanUnpairItself() async throws {
        try startDaemon()
        let payload = try pairingPayload()
        let client = PinnedClient(fingerprint: payload.fp)
        let base = URL(string: "https://127.0.0.1:\(payload.port)")!
        let (_, json) = try await client.call("POST", base.appendingPathComponent("v1/pair"), body: ["secret": payload.s, "platform": "android"])
        let token = try #require(json["token"] as? String)
        var (code, _) = try await client.call("POST", base.appendingPathComponent("v1/unpair"), token: token)
        #expect(code == 200)
        #expect(DeviceStore(url: paths.devices).load().isEmpty)
        (code, _) = try await client.call("GET", base.appendingPathComponent("v1/status"), token: token)
        #expect(code == 401)
    }

    @Test func rePairedPhoneHoldsItsPushTokenOnce() async throws {
        try startDaemon()
        let base = URL(string: "https://127.0.0.1:\(port)")!
        var tokens: [String] = []
        for _ in 0..<2 {
            let payload = try pairingPayload()
            let client = PinnedClient(fingerprint: payload.fp)
            let (_, json) = try await client.call("POST", base.appendingPathComponent("v1/pair"), body: ["secret": payload.s, "platform": "android"])
            let token = try #require(json["token"] as? String)
            let (code, _) = try await client.call("POST", base.appendingPathComponent("v1/push-token"), token: token, body: ["token": "fcm-1"])
            #expect(code == 200)
            tokens.append(token)
        }
        let devices = DeviceStore(url: paths.devices).load()
        #expect(devices.count == 2)
        #expect(devices.filter { $0.pushToken == "fcm-1" }.count == 1, "one phone, one delivery per event")

        let ids = devices.map(\.id)
        let ambiguous = try TestSupport.run(bin, ["devices", "revoke", ""], stateDir: state)
        #expect(ambiguous.status != 0)
        let shared = String(zip(ids[0], ids[1]).prefix { $0 == $1 }.map(\.0))
        if !shared.isEmpty {
            #expect(try TestSupport.run(bin, ["devices", "revoke", shared], stateDir: state).status != 0)
        }
        #expect(DeviceStore(url: paths.devices).load().count == 2, "ambiguous prefixes revoke nothing")

        try Data("not json".utf8).write(to: paths.devices)
        let client = PinnedClient(fingerprint: try pairingPayload().fp)
        let (code, _) = try await client.call("GET", base.appendingPathComponent("v1/status"), token: tokens[0])
        #expect(code == 500, "a broken devices.json must not tell every phone it was revoked")
        #expect(throws: (any Error).self) { try DeviceStore(url: self.paths.devices).update { $0.removeAll() } }
        #expect(try String(contentsOf: paths.devices, encoding: .utf8) == "not json")
    }

    @Test func wrongPinIsRejectedByTheClient() async throws {
        try startDaemon()
        let payload = try pairingPayload()
        let client = PinnedClient(fingerprint: Data(SHA256.hash(data: Data("other".utf8))).base64EncodedString())
        await #expect(throws: (any Error).self) {
            _ = try await client.call("POST", URL(string: "https://127.0.0.1:\(payload.port)/v1/pair")!, body: ["secret": payload.s, "platform": "ios"])
        }
        #expect(FileManager.default.fileExists(atPath: paths.pairing.path), "secret never reached the server")
    }

    @Test func expiredTicketIsRejected() async throws {
        try startDaemon()
        let payload = try pairingPayload()
        let expired = PairingTicket(secretHash: Secrets.sha256(payload.s), expiresAt: Date().addingTimeInterval(-1))
        try GatewayJSON.encoder().encode(expired).write(to: paths.pairing)
        let client = PinnedClient(fingerprint: payload.fp)
        let (code, _) = try await client.call("POST", URL(string: "https://127.0.0.1:\(payload.port)/v1/pair")!, body: ["secret": payload.s, "platform": "android"])
        #expect(code == 403)
    }
}
