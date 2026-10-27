import Foundation
import GatewayCore

/// Routes a push to every paired device over its platform's channel. Credentials are re-read on each
/// delivery so `creds import` takes effect without restarting the daemon; senders (and their cached
/// auth tokens) are rebuilt only when the credentials actually change.
public final class PushDispatcher: @unchecked Sendable {
    public struct Endpoints: Sendable {
        public var apns: [PushEnvironment: URL] = [.production: APNsSender.production, .sandbox: APNsSender.sandbox]
        public var fcm = FCMSender.api
        public var huawei = HuaweiSender.api

        public init() {}
    }

    let store: CredentialStore
    let session: URLSession
    let endpoints: Endpoints
    private let lock = NSLock()
    private var apns: (APNsCredentials, APNsSender)?
    private var fcm: (FCMCredentials, FCMSender)?
    private var huawei: (HuaweiCredentials, HuaweiSender)?

    public init(store: CredentialStore, session: URLSession = .shared, endpoints: Endpoints = Endpoints()) {
        self.store = store
        self.session = session
        self.endpoints = endpoints
    }

    public func deliver(_ message: PushMessage, to devices: [PairedDevice]) async -> [(device: PairedDevice, result: DeliveryResult)] {
        await withTaskGroup(of: (PairedDevice, DeliveryResult).self) { group in
            for device in devices {
                group.addTask { (device, await self.deliver(message, to: device)) }
            }
            var results: [(device: PairedDevice, result: DeliveryResult)] = []
            for await r in group { results.append(r) }
            return results
        }
    }

    public func deliver(_ message: PushMessage, to device: PairedDevice) async -> DeliveryResult {
        guard let token = device.pushToken else { return .failed("设备尚未上报推送 token") }
        switch device.platform {
        case .ios:
            guard let sender = sender(.apns, &apns, make: { APNsSender(credentials: $0, session: self.session, hosts: self.endpoints.apns) })
            else { return .failed("未导入 APNs 凭据（amber-gateway creds import apns）") }
            return await sender.send(message, to: token, environment: device.pushEnvironment ?? .production)
        case .android:
            guard let sender = sender(.fcm, &fcm, make: { FCMSender(credentials: $0, session: self.session, apiBase: self.endpoints.fcm) })
            else { return .failed("未导入 FCM 凭据（amber-gateway creds import fcm）") }
            return await sender.send(message, to: token)
        case .harmony:
            guard let sender = sender(.huawei, &huawei, make: { HuaweiSender(credentials: $0, session: self.session, apiBase: self.endpoints.huawei) })
            else { return .failed("未导入华为推送凭据（amber-gateway creds import huawei）") }
            return await sender.send(message, to: token)
        }
    }

    private func sender<C: Decodable & Equatable, S>(_ kind: CredentialKind, _ slot: inout (C, S)?, make: (C) -> S) -> S? {
        guard let creds = store.load(kind, as: C.self) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let (cached, sender) = slot, cached == creds { return sender }
        let sender = make(creds)
        slot = (creds, sender)
        return sender
    }
}
