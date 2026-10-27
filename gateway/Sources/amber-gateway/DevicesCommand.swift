import Foundation
import GatewayCore
import GatewayPush

enum DevicesCommand {
    static func run(_ args: [String]) -> Int32 {
        let paths = GatewayPaths.resolve()
        let store = DeviceStore(url: paths.devices)
        if args.first == "revoke" {
            guard args.count == 2, !args[1].isEmpty else { return usage() }
            let id = args[1]
            var matches = 0
            let removed = (try? store.update { list -> PairedDevice? in
                let hits = list.indices.filter { list[$0].id == id || list[$0].id.hasPrefix(id) }
                matches = hits.count
                guard hits.count == 1 else { return nil }
                return list.remove(at: hits[0])
            }) ?? nil
            guard let removed else {
                let reason = matches > 1 ? "ID 前缀 \(id) 匹配到 \(matches) 台设备，请输入更长的 ID" : "没有 id 为 \(id) 的设备"
                FileHandle.standardError.write(Data("\(reason)\n".utf8))
                return 1
            }
            AuditLog(url: paths.audit).record("revoke", ["device": removed.id, "name": removed.name])
            print("已吊销 \(removed.name)（\(removed.id)）：其访问令牌立即失效，不再向它推送")
            return 0
        }
        guard args.isEmpty else { return usage() }

        let devices = store.load()
        if devices.isEmpty {
            print("（尚无已配对设备，运行 amber-gateway pair 开始配对）")
            return 0
        }
        print("\(StatusCommand.pad("ID", 10)) \(StatusCommand.pad("名称", 22)) \(StatusCommand.pad("平台", 9)) \(StatusCommand.pad("推送", 20)) \(StatusCommand.pad("配对于", 12)) 最后活跃")
        for d in devices.sorted(by: { $0.pairedAt < $1.pairedAt }) {
            let push = d.pushToken == nil ? "未上报" : (d.pushEnvironment.map { "已上报（\($0.rawValue)）" } ?? "已上报")
            print("\(StatusCommand.pad(String(d.id.prefix(8)), 10)) \(StatusCommand.pad(d.name, 22)) \(StatusCommand.pad(d.platform.rawValue, 9)) \(StatusCommand.pad(push, 20)) \(StatusCommand.pad(StatusCommand.relative(d.pairedAt), 12)) \(StatusCommand.relative(d.lastSeenAt))")
        }
        print("\n吊销：amber-gateway devices revoke <ID>")
        return 0
    }

    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data("用法: amber-gateway devices [revoke <ID>]\n".utf8))
        return 64
    }
}

enum TestPushCommand {
    /// Delivers straight from the CLI (not via the daemon) so credential problems show up immediately.
    static func run(_ args: [String]) -> Int32 {
        let paths = GatewayPaths.resolve()
        let store = DeviceStore(url: paths.devices)
        var targets = store.load()
        if let i = args.firstIndex(of: "--device"), i + 1 < args.count {
            targets = targets.filter { $0.id.hasPrefix(args[i + 1]) }
        }
        guard !targets.isEmpty else {
            FileHandle.standardError.write(Data("没有可推送的设备（先 amber-gateway pair）\n".utf8))
            return 1
        }
        let name = (try? Data(contentsOf: paths.identity)).flatMap { try? GatewayJSON.decoder().decode(GatewayIdentity.self, from: $0) }?.name ?? "Mac"
        let message = PushMessage(PushIntent(kind: .test, subject: "test", createdAt: Date()), gatewayName: name)
        let dispatcher = PushDispatcher(store: CredentialStore(dir: paths.secretsDir))

        let done = DispatchSemaphore(value: 0)
        var results: [(device: PairedDevice, result: DeliveryResult)] = []
        Task {
            results = await dispatcher.deliver(message, to: targets)
            done.signal()
        }
        done.wait()

        var failures = 0
        for (device, result) in results {
            switch result {
            case .delivered:
                print("✓ \(device.name)：已送达推送服务")
            case .invalidToken(let reason):
                failures += 1
                print("✗ \(device.name)：推送 token 已失效（\(reason)），已移除，需在手机上重新打开 Amber 上报")
                try? store.update { list in
                    if let i = list.firstIndex(where: { $0.id == device.id }) { list[i].pushToken = nil }
                }
            case .failed(let reason):
                failures += 1
                print("✗ \(device.name)：\(reason)")
            }
        }
        return failures == 0 ? 0 : 1
    }
}
