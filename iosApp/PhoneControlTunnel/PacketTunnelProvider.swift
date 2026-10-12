// Copyright © 2021 osy. All rights reserved.
// Licensed under the Apache License, Version 2.0.
// See LICENSE-Jitterbug.txt for the license and NOTICE.txt for attribution.
// Modified for Amber: fixed single-peer routing, validated IPv4 reflection,
// and serialized start/stop handling. No external tunnel server is used.

import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let packetQueue = DispatchQueue(label: "app.amber.phone-control-tunnel")
    private var generation: UInt64 = 0
    private var isRunning = false

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        packetQueue.async {
            self.generation &+= 1
            let generation = self.generation
            self.isRunning = false

            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
            let ipv4 = NEIPv4Settings(addresses: ["10.7.1.1"], subnetMasks: ["255.255.255.255"])
            ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")]
            ipv4.excludedRoutes = [.default()]
            settings.ipv4Settings = ipv4

            self.setTunnelNetworkSettings(settings) { error in
                self.packetQueue.async {
                    guard self.generation == generation else {
                        completionHandler(CancellationError())
                        return
                    }
                    guard error == nil else {
                        completionHandler(error)
                        return
                    }
                    self.isRunning = true
                    self.readPackets(generation: generation)
                    completionHandler(nil)
                }
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        packetQueue.async {
            self.isRunning = false
            self.generation &+= 1
            completionHandler()
        }
    }

    private func readPackets(generation: UInt64) {
        packetFlow.readPackets { packets, protocols in
            self.packetQueue.async {
                guard self.isRunning, self.generation == generation else { return }
                var reflectedPackets: [Data] = []
                var reflectedProtocols: [NSNumber] = []
                for (packet, protocolFamily) in zip(packets, protocols) {
                    if let reflected = LocalPacketReflection.reflect(packet, protocolFamily: protocolFamily.int32Value) {
                        reflectedPackets.append(reflected)
                        reflectedProtocols.append(protocolFamily)
                    }
                }
                if !reflectedPackets.isEmpty,
                   !self.packetFlow.writePackets(reflectedPackets, withProtocols: reflectedProtocols) {
                    self.isRunning = false
                    self.cancelTunnelWithError(NSError(
                        domain: "app.amber.phone-control-tunnel",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The local connection could not return its packets."]
                    ))
                    return
                }
                self.readPackets(generation: generation)
            }
        }
    }
}
