import XCTest
import CryptoKit
import NIOCore
import NIOPosix
import NIOSSH
@testable import iosApp

final class IOSSSHBackendIntegrationTests: XCTestCase {
    func testInterleavedByteFramesPreserveUTF8AndRedactSecretsInCallbacksAndResult() async throws {
        let identity = try IOSSSHPrivateKey.generate()
        let auth = LoopbackSSHAuthentication(acceptedKey: try NIOSSHPublicKey(openSSHPublicKey: identity.publicKey))
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .server(.init(hostKeys: [hostKey], userAuthDelegate: auth)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, type in
                            guard type == .session else { return child.eventLoop.makeFailedFuture(IOSSSHError.authenticationFailed) }
                            return child.eventLoop.makeCompletedFuture {
                                try child.pipeline.syncOperations.addHandler(LoopbackSSHCommandHandler())
                            }
                        }
                    ))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        do {
            let backend = IOSSSHRuntimeBackend()
            var profile = IOSSSHProfile(host: "127.0.0.1", port: try XCTUnwrap(listener.localAddress?.port),
                                        username: "amber-test", authMethod: .privateKey)
            let probe = try await backend.testConnection(profile: profile)
            profile.knownHostSHA256 = probe.fingerprint
            profile.knownHostHost = profile.host
            profile.knownHostPort = profile.port
            let captured = CapturedSSHOutput()
            let result = try await backend.execute(
                command: "amber-byte-frames", profile: profile,
                credential: .privateKey(identity.privateKey), timeout: 5,
                output: { captured.append($0) }
            )
            let expectedStdout = "中文🙂前\n[redacted]\n终🙂"
            let expectedStderr = "错误🚀前\n[redacted]\n尾🚀"
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.stdout, expectedStdout, "UTF-8 scalars split across SSH messages must survive")
            XCTAssertEqual(result.stderr, expectedStderr, "stderr must keep its own partial UTF-8 sequence")
            let chunks = captured.chunks
            XCTAssertEqual(chunks.filter { !$0.isStderr }.map(\.text).joined(), expectedStdout)
            XCTAssertEqual(chunks.filter(\.isStderr).map(\.text).joined(), expectedStderr)
            for text in chunks.map(\.text) + [result.stdout, result.stderr] {
                XCTAssertFalse(text.contains("byte-frame-secret"))
                XCTAssertFalse(text.contains("PRIVATE KEY"))
            }
            try await listener.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await listener.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func testPrivateKeyAuthenticationOverLoopbackRequiresHostTrust() async throws {
        let identity = try IOSSSHPrivateKey.generate()
        let acceptedKey = try NIOSSHPublicKey(openSSHPublicKey: identity.publicKey)
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let auth = LoopbackSSHAuthentication(acceptedKey: acceptedKey)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .server(.init(hostKeys: [hostKey], userAuthDelegate: auth)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, type in
                            guard type == .session else { return child.eventLoop.makeFailedFuture(IOSSSHError.authenticationFailed) }
                            return child.eventLoop.makeCompletedFuture {
                                try child.pipeline.syncOperations.addHandler(LoopbackSSHCommandHandler())
                            }
                        }
                    ))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        do {
            let backend = IOSSSHRuntimeBackend()
            var profile = IOSSSHProfile(host: "127.0.0.1", port: try XCTUnwrap(listener.localAddress?.port),
                                        username: "amber-test", authMethod: .privateKey)
            let probe = try await backend.testConnection(profile: profile)
            XCTAssertEqual(probe.trustState, .needsTrust(fingerprint: probe.fingerprint))
            XCTAssertEqual(auth.publicKeyAttempts, 0, "Host discovery must not offer a user credential")

            profile.knownHostSHA256 = "SHA256:wrong-host"
            profile.knownHostHost = profile.host
            profile.knownHostPort = profile.port
            do {
                _ = try await backend.execute(command: "amber-test", profile: profile,
                                              credential: .privateKey(identity.privateKey), timeout: 5, output: { _ in })
                XCTFail("An untrusted host must not receive authentication")
            } catch IOSSSHError.hostKeyMismatch { }
            XCTAssertEqual(auth.publicKeyAttempts, 0)

            profile.knownHostSHA256 = probe.fingerprint
            let result = try await backend.execute(command: "amber-test", profile: profile,
                                                   credential: .privateKey(identity.privateKey), timeout: 5, output: { _ in })
            XCTAssertEqual(result.stdout, "amber-key-auth-ok\n")
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(auth.publicKeyAttempts, 1)

            // The BEGIN marker would fall outside the backend's 128 KiB tail
            // if sanitization happened after buffering/truncation.
            let redacted = try await backend.execute(command: "amber-redaction-test", profile: profile,
                                                     credential: .privateKey(identity.privateKey), timeout: 5, output: { _ in })
            XCTAssertEqual(redacted.stdout, "prefix\n[redacted]\nsuffix\n")
            let wrongIdentity = try IOSSSHPrivateKey.generate()
            do {
                _ = try await backend.execute(command: "amber-test", profile: profile,
                                              credential: .privateKey(wrongIdentity.privateKey), timeout: 5, output: { _ in })
                XCTFail("The server must reject a key that is not authorized")
            } catch IOSSSHError.authenticationFailed { }
            XCTAssertEqual(auth.publicKeyAttempts, 3, "Each connection offers its credential only once")
            try await listener.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await listener.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private final class CapturedSSHOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storedChunks: [IOSSSHOutputChunk] = []
    var chunks: [IOSSSHOutputChunk] { lock.withLock { storedChunks } }
    func append(_ chunk: IOSSSHOutputChunk) { lock.withLock { storedChunks.append(chunk) } }
}

private final class LoopbackSSHAuthentication: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let acceptedKey: NIOSSHPublicKey
    private let lock = NSLock()
    private var attempts = 0
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.publicKey] }
    var publicKeyAttempts: Int { lock.withLock { attempts } }

    init(acceptedKey: NIOSSHPublicKey) { self.acceptedKey = acceptedKey }

    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        guard case .publicKey(let key) = request.request else {
            responsePromise.succeed(.failure)
            return
        }
        lock.withLock { attempts += 1 }
        responsePromise.succeed(request.username == "amber-test" && key.publicKey == acceptedKey ? .success : .failure)
    }
}

private final class LoopbackSSHCommandHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let request = event as? SSHChannelRequestEvent.ExecRequest else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        if request.command == "amber-byte-frames" {
            if request.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            let secret = "-----BEGIN OPENSSH PRIVATE KEY-----\nbyte-frame-secret\n-----END OPENSSH PRIVATE KEY-----"
            let stdout = Array("中文🙂前\n\(secret)\n终🙂".utf8)
            let stderr = Array("错误🚀前\n\(secret)\n尾🚀".utf8)
            let channel = context.channel
            var writes = channel.eventLoop.makeSucceededFuture(())
            for index in 0..<max(stdout.count, stderr.count) {
                if index < stdout.count {
                    let data = SSHChannelData(type: .channel, data: .byteBuffer(channel.allocator.buffer(bytes: [stdout[index]])))
                    writes = writes.flatMap { channel.writeAndFlush(data) }
                }
                if index < stderr.count {
                    let data = SSHChannelData(type: .stdErr, data: .byteBuffer(channel.allocator.buffer(bytes: [stderr[index]])))
                    writes = writes.flatMap { channel.writeAndFlush(data) }
                }
            }
            writes.flatMap {
                channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0))
            }.whenComplete { _ in channel.close(promise: nil) }
            return
        }
        let response: String
        switch request.command {
        case "amber-test": response = "amber-key-auth-ok\n"
        case "amber-redaction-test":
            response = "prefix\n-----BEGIN OPENSSH PRIVATE KEY-----\n"
                + String(repeating: "private-material\n", count: 10_000)
                + "-----END OPENSSH PRIVATE KEY-----\nsuffix\n"
        default: context.close(promise: nil); return
        }
        if request.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        let channel = context.channel
        let data = SSHChannelData(type: .channel, data: .byteBuffer(channel.allocator.buffer(string: response)))
        channel.writeAndFlush(data).flatMap {
            channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0))
        }.whenComplete { _ in channel.close(promise: nil) }
    }
}
