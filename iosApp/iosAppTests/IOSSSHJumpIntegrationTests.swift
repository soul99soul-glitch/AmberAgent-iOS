import CryptoKit
import NIOCore
import NIOPosix
import NIOSSH
import XCTest
@testable import iosApp

final class IOSSSHJumpIntegrationTests: XCTestCase {
    func testNestedDirectTCPIPAndChangedSecondHopStopsBeforeAuthenticationOrTargetContact() async throws {
        let fixture = try await JumpFixture.start()
        do {
            let backend = IOSSSHRuntimeBackend()
            let result = try await backend.executeRoute(command: "echo test", route: fixture.route,
                credentials: fixture.credentials, timeout: 5, output: { _ in })
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.stdout, "ok [redacted] [redacted]\n")
            XCTAssertEqual(fixture.jump.sessionRequests, 0, "Jump hosts never need a shell")
            XCTAssertEqual(fixture.middle.sessionRequests, 0)
            let targetConnections = fixture.target.connections
            let middleAuth = fixture.middle.authAttempts
            var changed = fixture.route
            changed[1].knownHostSHA256 = "SHA256:changed"
            do {
                _ = try await backend.executeRoute(command: "must-not-run", route: changed,
                    credentials: fixture.credentials, timeout: 5, output: { _ in })
                XCTFail("Changed host key must block")
            } catch IOSSSHError.hopFailure(let failure) {
                XCTAssertEqual(failure.status, "host_key_changed")
                XCTAssertEqual(failure.hopIndex, 2)
                XCTAssertEqual(failure.profileId, changed[1].id)
            }
            XCTAssertEqual(fixture.middle.authAttempts, middleAuth)
            XCTAssertEqual(fixture.target.connections, targetConnections)
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }

    @MainActor
    func testSequentialTOFUProbesStopAtEachUntrustedHopAndCancellationClosesWholeRoute() async throws {
        let fixture = try await JumpFixture.start()
        do {
            let backend = IOSSSHRuntimeBackend()
            var route = fixture.route
            for i in route.indices { route[i].knownHostSHA256 = nil }
            for i in route.indices {
                let probes = try await backend.probeRoute(route: route, credentials: fixture.credentials)
                XCTAssertEqual(probes.count, i + 1)
                XCTAssertEqual(probes.last?.hopIndex, i + 1)
                XCTAssertEqual(probes.last?.trustState, .needsTrust(fingerprint: fixture.route[i].knownHostSHA256!))
                route[i].knownHostSHA256 = fixture.route[i].knownHostSHA256
            }
            let runtime = IOSTerminalRuntime(sshBackend: backend)
            let started = await runtime.startJob(command: "hold", runtime: .remoteSSH,
                experimentalEnabled: false, sshProfile: route.last,
                sshCredential: fixture.credentials["target"], sshRoute: route,
                sshRouteCredentials: fixture.credentials, timeoutSeconds: 5)
            XCTAssertEqual(started.status, IOSTerminalJobStatus.running.rawValue)
            for _ in 0..<100 {
                if fixture.target.sessionRequests > 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let stopped = runtime.stopJob(id: started.id)
            XCTAssertEqual(stopped?.status, IOSTerminalJobStatus.cancelled.rawValue)
            for _ in 0..<100 {
                if fixture.activeConnections == 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(fixture.activeConnections, 0)
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }
}

private struct JumpFixture {
    let group: MultiThreadedEventLoopGroup
    let target: JumpTestServer
    let middle: JumpTestServer
    let jump: JumpTestServer
    let route: [IOSSSHProfile]
    let credentials: [String: IOSSSHCredential]
    var activeConnections: Int { target.activeConnections + middle.activeConnections + jump.activeConnections }

    static func start() async throws -> JumpFixture {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let identity = try IOSSSHPrivateKey.generate()
        let accepted = try NIOSSHPublicKey(openSSHPublicKey: identity.publicKey)
        let target = JumpTestServer(acceptedKey: accepted, password: "target-secret", final: true)
        let middle = JumpTestServer(acceptedKey: accepted, password: "jump-secret", final: false)
        let jump = JumpTestServer(acceptedKey: accepted, password: nil, final: false)
        do {
            try await target.listen(group: group)
            middle.forwards = ["target": target.port]
            try await middle.listen(group: group)
            jump.forwards = ["middle": middle.port]
            try await jump.listen(group: group)
            func profile(_ server: JumpTestServer, id: String, host: String, port: Int, via: String?, auth: IOSSSHAuthMethod) throws -> IOSSSHProfile {
                IOSSSHProfile(id: id, name: id, host: host, port: port, username: "test", authMethod: auth,
                    jumpProfileId: via, knownHostSHA256: try IOSSSHPrivateKey.fingerprintSHA256(publicKey: server.hostKey.publicKey),
                    knownHostHost: host, knownHostPort: port, knownHostViaJump: via)
            }
            return JumpFixture(group: group, target: target, middle: middle, jump: jump,
                route: [try profile(jump, id: "jump", host: "127.0.0.1", port: jump.port, via: nil, auth: .privateKey),
                    try profile(middle, id: "middle", host: "middle", port: 22, via: "jump", auth: .password),
                    try profile(target, id: "target", host: "target", port: 22, via: "middle", auth: .password)],
                credentials: ["jump": .privateKey(identity.privateKey), "middle": .password("jump-secret"), "target": .password("target-secret")])
        } catch {
            try? await jump.close(); try? await middle.close(); try? await target.close()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func close() async throws {
        try await jump.close(); try await middle.close(); try await target.close()
        try await group.shutdownGracefully()
    }
}

private final class JumpTestServer: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    let acceptedKey: NIOSSHPublicKey
    let password: String?
    let final: Bool
    var forwards: [String: Int] = [:]
    private var listener: Channel?
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: Channel] = [:]
    private var connectionCount = 0
    private var authenticationCount = 0
    private var sessions = 0
    var connections: Int { lock.withLock { connectionCount } }
    var authAttempts: Int { lock.withLock { authenticationCount } }
    var sessionRequests: Int { lock.withLock { sessions } }
    var activeConnections: Int { lock.withLock { clients.count } }
    var port: Int { listener!.localAddress!.port! }
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.publicKey, .password] }

    init(acceptedKey: NIOSSHPublicKey, password: String?, final: Bool) {
        self.acceptedKey = acceptedKey; self.password = password; self.final = final
    }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        lock.withLock { authenticationCount += 1 }
        switch request.request {
        case .publicKey(let offer): responsePromise.succeed(offer.publicKey == acceptedKey ? .success : .failure)
        case .password(let offer): responsePromise.succeed(offer.password == password ? .success : .failure)
        default: responsePromise.succeed(.failure)
        }
    }
    func listen(group: EventLoopGroup) async throws {
        listener = try await ServerBootstrap(group: group).childChannelInitializer { [self] channel in
            lock.withLock { clients[ObjectIdentifier(channel)] = channel; connectionCount += 1 }
            channel.closeFuture.whenComplete { [self] _ in
                _ = lock.withLock { clients.removeValue(forKey: ObjectIdentifier(channel)) }
            }
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .server(.init(hostKeys: [self.hostKey], userAuthDelegate: self)),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { [self] child, type in
                        if case .directTCPIP(let destination) = type,
                           let port = self.forwards[destination.targetHost], destination.targetPort == 22 {
                            return child.pipeline.addHandler(SSHDirectTCPIPDataWrapperHandler()).flatMap {
                                ClientBootstrap(group: child.eventLoop).channelInitializer { remote in
                                    remote.pipeline.addHandler(JumpPipe(peer: child))
                                }.connect(host: "127.0.0.1", port: port)
                            }.flatMap { remote in child.pipeline.addHandler(JumpPipe(peer: remote)) }
                        }
                        if type == .session { self.lock.withLock { self.sessions += 1 } }
                        guard type == .session, self.final else {
                            return child.eventLoop.makeFailedFuture(IOSSSHError.commandFailed("forward denied or shell disabled"))
                        }
                        return child.pipeline.addHandler(JumpExec())
                    }
                ))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
    }
    func close() async throws {
        let snapshot = lock.withLock { Array(clients.values) }
        for client in snapshot { try? await client.close().get() }
        if let listener { try await listener.close().get(); self.listener = nil }
    }
}

private final class JumpPipe: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let peer: Channel
    init(peer: Channel) { self.peer = peer }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) { peer.close(promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(promise: nil); context.close(promise: nil)
    }
}

private final class JumpExec: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let request = event as? SSHChannelRequestEvent.ExecRequest else { context.fireUserInboundEventTriggered(event); return }
        if request.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        guard request.command != "hold" else { return }
        let channel = context.channel
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(channel.allocator.buffer(string: "ok jump-secret target-secret\n")))).flatMap {
            channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0))
        }.whenComplete { _ in channel.close(promise: nil) }
    }
}
