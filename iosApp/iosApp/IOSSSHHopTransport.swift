import Foundation

#if canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOSSH)
import NIOCore
import NIOPosix
import NIOSSH

/// Bridges an `SSHChildChannel` opened with `.directTCPIP` (which speaks `SSHChannelData`)
/// to a nested client `NIOSSHHandler` (which speaks `ByteBuffer`).
final class SSHDirectTCPIPDataWrapperHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel,
              case .byteBuffer(let buffer) = channelData.data else {
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(wrapOutboundOut(channelData), promise: promise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, case .inputClosed = channelEvent {
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}
#endif

enum IOSSSHMultiHopClient {
    static let maximumHopConnectTimeout: TimeInterval = 15

    static func hopDisplay(_ profile: IOSSSHProfile) -> String {
        "\(profile.displayName) (\(profile.username)@\(profile.host):\(profile.port))"
    }

    /// Pre-flight validation before any network packets are sent:
    /// 1. Validates each hop profile.
    /// 2. Ensures every hop has a pinned `knownHostSHA256` (otherwise throws `host_key_untrusted`).
    /// 3. Ensures every hop has a valid credential for its auth method.
    static func preflightValidate(
        route: [IOSSSHProfile],
        credentials: [String: IOSSSHCredential]
    ) throws -> [IOSSSHProfile] {
        guard !route.isEmpty else {
            throw IOSSSHError.noDefaultProfile
        }
        guard route.count <= IOSSSHRouteResolver.maxTotalHops else {
            throw IOSSSHRouteError.jumpChainTooLong(maxJumpHosts: 3, actualJumpHosts: route.count - 1)
        }
        let hopCount = route.count
        var validatedRoute: [IOSSSHProfile] = []
        validatedRoute.reserveCapacity(hopCount)

        for (idx, rawHop) in route.enumerated() {
            let hopNumber = idx + 1
            let hop = try rawHop.validated()
            let display = hopDisplay(hop)
            guard let pin = hop.knownHostSHA256, !pin.isEmpty else {
                throw IOSSSHError.hopFailure(
                    IOSSSHHopFailure(
                        status: "host_key_untrusted",
                        hopIndex: hopNumber,
                        hopCount: hopCount,
                        profileId: hop.id,
                        display: display,
                        message: "第 \(hopNumber)/\(hopCount) 跳（\(hop.displayName)）尚未信任主机指纹（Run Test Connection and Trust Host first）。"
                    )
                )
            }
            guard let credential = credentials[hop.id] else {
                throw IOSSSHError.hopFailure(
                    IOSSSHHopFailure(
                        status: "hop_auth_failed",
                        hopIndex: hopNumber,
                        hopCount: hopCount,
                        profileId: hop.id,
                        display: display,
                        message: "第 \(hopNumber)/\(hopCount) 跳（\(hop.displayName)）缺少已保存的 SSH 凭证。"
                    )
                )
            }
            do {
                _ = try credential.validated(for: hop)
            } catch {
                throw IOSSSHError.hopFailure(
                    IOSSSHHopFailure(
                        status: "hop_auth_failed",
                        hopIndex: hopNumber,
                        hopCount: hopCount,
                        profileId: hop.id,
                        display: display,
                        message: "第 \(hopNumber)/\(hopCount) 跳（\(hop.displayName)）凭证无效：\(error.localizedDescription)"
                    )
                )
            }
            validatedRoute.append(hop)
        }
        return validatedRoute
    }

    #if canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOSSH)
    static func probeRoute(
        route: [IOSSSHProfile],
        credentials: [String: IOSSSHCredential],
        timeout: TimeInterval,
        registry: IOSSSHActiveSessionRegistry
    ) throws -> [IOSSSHHopProbeResult] {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        // Includes TCP/KEX/authentication/channel-open, before the exec timeout exists.
        let deadlineTask = group.next().scheduleTask(in: .milliseconds(Int64(max(timeout, 1) * 1000))) {
            registry.expire()
        }
        defer { deadlineTask.cancel() }

        let hopCount = route.count
        let deadline = Date().addingTimeInterval(max(timeout, 1))
        var activeChannels: [Channel] = []
        defer {
            for ch in activeChannels.reversed() {
                registry.unregister(ch)
                try? ch.close().wait()
            }
        }

        var results: [IOSSSHHopProbeResult] = []
        for (idx, hop) in route.enumerated() {
            let hopNumber = idx + 1
            let isLastHop = idx == hopCount - 1
            let hasTrustedPin = (hop.knownHostSHA256?.isEmpty == false)
            let credential = isLastHop ? nil : credentials[hop.id]
            let shouldAbortAfterHostKey = isLastHop || !hasTrustedPin || credential == nil

            let remaining = max(deadline.timeIntervalSinceNow, 0.01)
            let hopTimeout = min(remaining, maximumHopConnectTimeout)
            let hopDeadline = group.next().scheduleTask(in: .milliseconds(Int64(hopTimeout * 1000))) { registry.expire() }
            defer { hopDeadline.cancel() }

            let authDelegate = try IOSSSHAuthDelegate(
                username: hop.username,
                credential: shouldAbortAfterHostKey ? nil : credential
            )
            let hostDelegate = IOSSSHHostKeyDelegate(
                expectedFingerprint: hop.knownHostSHA256,
                enforceHostKey: !shouldAbortAfterHostKey,
                abortAfterHostKey: shouldAbortAfterHostKey
            )

            let hopChannel: Channel
            if idx == 0 {
                hopChannel = try connectRootHop(
                    hop: hop,
                    hopNumber: hopNumber,
                    hopCount: hopCount,
                    group: group,
                    authDelegate: authDelegate,
                    hostDelegate: hostDelegate,
                    timeout: hopTimeout,
                    registry: registry
                )
            } else {
                let prevHop = route[idx - 1]
                let prevChannel = activeChannels[idx - 1]
                hopChannel = try openDirectTCPIPChannel(
                    parentChannel: prevChannel,
                    fromHop: prevHop,
                    fromHopNumber: idx,
                    toHop: hop,
                    toHopNumber: hopNumber,
                    hopCount: hopCount,
                    authDelegate: authDelegate,
                    hostDelegate: hostDelegate,
                    registry: registry
                )
            }
            activeChannels.append(hopChannel)

            guard let probe = waitForHostKeyResult(
                from: hostDelegate,
                channel: hopChannel,
                timeout: hopTimeout
            ) else {
                if registry.isCancelled { throw IOSSSHError.commandCancelled }
                throw IOSSSHError.hopFailure(
                    IOSSSHHopFailure(
                        status: "jump_target_unreachable",
                        hopIndex: hopNumber,
                        hopCount: hopCount,
                        profileId: hop.id,
                        display: hopDisplay(hop),
                        message: "第 \(hopNumber)/\(hopCount) 跳（\(hop.displayName)）密钥交换超时或连接中断。"
                    )
                )
            }

            results.append(
                IOSSSHHopProbeResult(
                    hopIndex: hopNumber,
                    hopCount: hopCount,
                    profileId: hop.id,
                    host: hop.host,
                    port: hop.port,
                    fingerprint: probe.fingerprint,
                    trustState: probe.trustState
                )
            )

            if shouldAbortAfterHostKey {
                break
            }
            guard case .trusted = probe.trustState else {
                break
            }
        }
        return results
    }

    static func executeRoute(
        command: String,
        route: [IOSSSHProfile],
        credentials: [String: IOSSSHCredential],
        timeout: TimeInterval,
        output: @escaping @Sendable (IOSSSHOutputChunk) -> Void,
        registry: IOSSSHActiveSessionRegistry
    ) throws -> IOSSSHCommandResult {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        // Includes TCP/KEX/authentication/channel-open, before the exec timeout exists.
        let deadlineTask = group.next().scheduleTask(in: .milliseconds(Int64(max(timeout, 1) * 1000))) {
            registry.expire()
        }
        defer { deadlineTask.cancel() }

        let hopCount = route.count
        let deadline = Date().addingTimeInterval(max(timeout, 1))
        let routeCredentials = route.compactMap { credentials[$0.id] }

        var activeChannels: [Channel] = []
        var authDelegates: [IOSSSHAuthDelegate] = []
        defer {
            for ch in activeChannels.reversed() {
                registry.unregister(ch)
                try? ch.close().wait()
            }
        }

        for (idx, hop) in route.enumerated() {
            let hopNumber = idx + 1
            let display = hopDisplay(hop)
            let remaining = max(deadline.timeIntervalSinceNow, 0.01)
            let hopTimeout = min(remaining, maximumHopConnectTimeout)
            let hopDeadline = group.next().scheduleTask(in: .milliseconds(Int64(hopTimeout * 1000))) { registry.expire() }
            defer { hopDeadline.cancel() }

            guard let credential = credentials[hop.id] else {
                throw IOSSSHError.hopFailure(
                    IOSSSHHopFailure(
                        status: "hop_auth_failed",
                        hopIndex: hopNumber,
                        hopCount: hopCount,
                        profileId: hop.id,
                        display: display,
                        message: "第 \(hopNumber)/\(hopCount) 跳（\(hop.displayName)）缺少有效 SSH 凭证。"
                    )
                )
            }

            let authDelegate = try IOSSSHAuthDelegate(username: hop.username, credential: credential)
            authDelegates.append(authDelegate)
            let hostDelegate = IOSSSHHostKeyDelegate(
                expectedFingerprint: hop.knownHostSHA256,
                enforceHostKey: true,
                abortAfterHostKey: false
            )

            let hopChannel: Channel
            if idx == 0 {
                hopChannel = try connectRootHop(
                    hop: hop,
                    hopNumber: hopNumber,
                    hopCount: hopCount,
                    group: group,
                    authDelegate: authDelegate,
                    hostDelegate: hostDelegate,
                    timeout: hopTimeout,
                    registry: registry
                )
            } else {
                let prevHop = route[idx - 1]
                let prevChannel = activeChannels[idx - 1]
                let prevAuth = authDelegates[idx - 1]
                do {
                    hopChannel = try openDirectTCPIPChannel(
                        parentChannel: prevChannel,
                        fromHop: prevHop,
                        fromHopNumber: idx,
                        toHop: hop,
                        toHopNumber: hopNumber,
                        hopCount: hopCount,
                        authDelegate: authDelegate,
                        hostDelegate: hostDelegate,
                        registry: registry
                    )
                } catch {
                    if registry.isCancelled { throw IOSSSHError.commandCancelled }
                    if prevAuth.didFailAuthentication {
                        throw IOSSSHError.hopFailure(
                            IOSSSHHopFailure(
                                status: "hop_auth_failed",
                                hopIndex: idx,
                                hopCount: hopCount,
                                profileId: prevHop.id,
                                display: hopDisplay(prevHop),
                                message: "第 \(idx)/\(hopCount) 跳（\(prevHop.displayName)）SSH 认证失败。"
                            )
                        )
                    }
                    throw error
                }
            }
            activeChannels.append(hopChannel)

            guard let probe = waitForHostKeyResult(
                from: hostDelegate,
                channel: hopChannel,
                timeout: hopTimeout
            ) else {
                if registry.isCancelled { throw IOSSSHError.commandCancelled }
                throw IOSSSHError.hopFailure(
                    IOSSSHHopFailure(
                        status: "jump_target_unreachable",
                        hopIndex: hopNumber,
                        hopCount: hopCount,
                        profileId: hop.id,
                        display: display,
                        message: "第 \(hopNumber)/\(hopCount) 跳（\(hop.displayName)）无法完成 SSH 密钥交换。"
                    )
                )
            }

            switch probe.trustState {
            case .trusted:
                break
            case .needsTrust(let fingerprint):
                throw IOSSSHError.hopFailure(
                    IOSSSHHopFailure(
                        status: "host_key_untrusted",
                        hopIndex: hopNumber,
                        hopCount: hopCount,
                        profileId: hop.id,
                        display: display,
                        presentedFingerprint: fingerprint,
                        message: "第 \(hopNumber)/\(hopCount) 跳（\(hop.displayName)）主机指纹尚未信任：\(fingerprint)"
                    )
                )
            case .mismatch(let expected, let actual):
                throw IOSSSHError.hopFailure(
                    IOSSSHHopFailure(
                        status: "host_key_changed",
                        hopIndex: hopNumber,
                        hopCount: hopCount,
                        profileId: hop.id,
                        display: display,
                        expectedFingerprint: expected,
                        presentedFingerprint: actual,
                        message: "第 \(hopNumber) 跳（\(hop.displayName)）主机指纹变化，已拦截。请在设置中核对后处理。"
                    )
                )
            }
        }

        let targetHop = route[hopCount - 1]
        let targetChannel = activeChannels[hopCount - 1]
        let targetAuth = authDelegates[hopCount - 1]
        let execRemaining = max(deadline.timeIntervalSinceNow, 0.5)

        let resultPromise = targetChannel.eventLoop.makePromise(of: IOSSSHCommandResult.self)
        let sessionChannel: Channel
        let sessionDeadline = targetChannel.eventLoop.scheduleTask(in: .milliseconds(Int64(min(execRemaining, maximumHopConnectTimeout) * 1000))) { registry.expire() }
        defer { sessionDeadline.cancel() }
        do {
            sessionChannel = try targetChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let promise = targetChannel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(IOSSSHClientError.invalidChannelType)
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        let sync = childChannel.pipeline.syncOperations
                        try sync.addHandler(
                            IOSSSHExecHandler(
                                command: command,
                                credentials: routeCredentials,
                                output: output,
                                completePromise: resultPromise,
                                timeout: execRemaining
                            )
                        )
                        try sync.addHandler(IOSSSHErrorHandler())
                    }
                }
                return promise.futureResult
            }.wait()
        } catch {
            resultPromise.fail(error)
            if registry.isCancelled { throw IOSSSHError.commandCancelled }
            if targetAuth.didFailAuthentication || (error as? IOSSSHClientError) == .authenticationFailed {
                throw IOSSSHError.hopFailure(
                    IOSSSHHopFailure(
                        status: "hop_auth_failed",
                        hopIndex: hopCount,
                        hopCount: hopCount,
                        profileId: targetHop.id,
                        display: hopDisplay(targetHop),
                        message: "第 \(hopCount)/\(hopCount) 跳（\(targetHop.displayName)）SSH 认证失败。"
                    )
                )
            }
            throw error
        }

        sessionDeadline.cancel()
        defer { try? sessionChannel.close().wait() }
        guard registry.register(sessionChannel) else {
            throw IOSSSHError.commandCancelled
        }
        defer { registry.unregister(sessionChannel) }

        let commandResult: IOSSSHCommandResult
        do {
            commandResult = try resultPromise.futureResult.wait()
        } catch {
            if registry.isCancelled { throw IOSSSHError.commandCancelled }
            if targetAuth.didFailAuthentication {
                throw IOSSSHError.hopFailure(
                    IOSSSHHopFailure(
                        status: "hop_auth_failed",
                        hopIndex: hopCount,
                        hopCount: hopCount,
                        profileId: targetHop.id,
                        display: hopDisplay(targetHop),
                        message: "第 \(hopCount)/\(hopCount) 跳（\(targetHop.displayName)）SSH 认证失败。"
                    )
                )
            }
            throw error
        }
        if registry.isCancelled {
            throw IOSSSHError.commandCancelled
        }
        try? sessionChannel.closeFuture.wait()
        return commandResult
    }

    private static func connectRootHop(
        hop: IOSSSHProfile,
        hopNumber: Int,
        hopCount: Int,
        group: EventLoopGroup,
        authDelegate: IOSSSHAuthDelegate,
        hostDelegate: IOSSSHHostKeyDelegate,
        timeout: TimeInterval,
        registry: IOSSSHActiveSessionRegistry
    ) throws -> Channel {
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    guard registry.register(channel) else { throw IOSSSHError.commandCancelled }
                    let ssh = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: authDelegate,
                                serverAuthDelegate: hostDelegate
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(ssh)
                    try sync.addHandler(IOSSSHErrorHandler())
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelOption(
                ChannelOptions.connectTimeout,
                value: .milliseconds(Int64(max(min(timeout, maximumHopConnectTimeout), 0.1) * 1000))
            )

        let channel: Channel
        do {
            channel = try bootstrap.connect(host: hop.host, port: hop.port).wait()
        } catch {
            if registry.isCancelled { throw IOSSSHError.commandCancelled }
            throw IOSSSHError.hopFailure(
                IOSSSHHopFailure(
                    status: "jump_target_unreachable",
                    hopIndex: hopNumber,
                    hopCount: hopCount,
                    profileId: hop.id,
                    display: hopDisplay(hop),
                    message: "第 \(hopNumber)/\(hopCount) 跳（\(hop.displayName)）无法建立 TCP 连接：\(error.localizedDescription)"
                )
            )
        }
        guard registry.register(channel) else {
            throw IOSSSHError.commandCancelled
        }
        return channel
    }

    private static func openDirectTCPIPChannel(
        parentChannel: Channel,
        fromHop: IOSSSHProfile,
        fromHopNumber: Int,
        toHop: IOSSSHProfile,
        toHopNumber: Int,
        hopCount: Int,
        authDelegate: IOSSSHAuthDelegate,
        hostDelegate: IOSSSHHostKeyDelegate,
        registry: IOSSSHActiveSessionRegistry
    ) throws -> Channel {
        let originator = parentChannel.localAddress
            ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))!
        let directTCPIP = SSHChannelType.DirectTCPIP(
            targetHost: toHop.host,
            targetPort: toHop.port,
            originatorAddress: originator
        )

        let childChannel: Channel
        do {
            childChannel = try parentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .directTCPIP(directTCPIP)) { child, channelType in
                    guard case .directTCPIP = channelType else {
                        return child.eventLoop.makeFailedFuture(IOSSSHClientError.invalidChannelType)
                    }
                    return child.eventLoop.makeCompletedFuture {
                        let nestedSSH = NIOSSHHandler(
                            role: .client(
                                .init(
                                    userAuthDelegate: authDelegate,
                                    serverAuthDelegate: hostDelegate
                                )
                            ),
                            allocator: child.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        let sync = child.pipeline.syncOperations
                        try sync.addHandler(SSHDirectTCPIPDataWrapperHandler())
                        try sync.addHandler(nestedSSH)
                        try sync.addHandler(IOSSSHErrorHandler())
                    }
                }
                return promise.futureResult
            }.wait()
        } catch {
            if registry.isCancelled { throw IOSSSHError.commandCancelled }
            if let nioError = error as? NIOSSHError, nioError.type == .channelSetupRejected {
                let text = String(describing: nioError).lowercased()
                if text.contains("reason: 2") || text.contains("connect failed") {
                    throw IOSSSHError.hopFailure(
                        IOSSSHHopFailure(
                            status: "jump_target_unreachable",
                            hopIndex: toHopNumber,
                            hopCount: hopCount,
                            profileId: toHop.id,
                            display: hopDisplay(toHop),
                            message: "跳板机（\(fromHop.displayName)）无法连接到第 \(toHopNumber)/\(hopCount) 跳（\(toHop.displayName)）。"
                        )
                    )
                }
                throw IOSSSHError.hopFailure(
                    IOSSSHHopFailure(
                        status: "jump_forward_denied",
                        hopIndex: fromHopNumber,
                        hopCount: hopCount,
                        profileId: fromHop.id,
                        display: hopDisplay(fromHop),
                        message: "第 \(fromHopNumber)/\(hopCount) 跳（\(fromHop.displayName)）拒绝了 TCP 转发（AllowTcpForwarding / PermitOpen 限制）。"
                    )
                )
            }
            throw error
        }

        guard registry.register(childChannel) else {
            throw IOSSSHError.commandCancelled
        }
        return childChannel
    }

    private static func waitForHostKeyResult(
        from hostDelegate: IOSSSHHostKeyDelegate,
        channel: Channel,
        timeout: TimeInterval
    ) -> IOSSSHConnectionProbeResult? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = hostDelegate.probeResult {
                return result
            }
            if !channel.isActive {
                return hostDelegate.probeResult
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return hostDelegate.probeResult
    }
    #endif
}
