import Foundation
import GatewayCore
import GatewayPush
import GatewayTransport

enum PairCommand {
    static func run(_ args: [String]) -> Int32 {
        let paths = GatewayPaths.resolve()
        guard StatusCommand.daemonRunning(paths) else {
            return fail("daemon 未运行：配对请求由 daemon 处理。先运行 amber-gateway install（或前台 amber-gateway daemon）")
        }
        let issued: PairingIssuer.Issued
        do {
            issued = try PairingIssuer.issue(paths: paths)
        } catch {
            return fail("\(error)")
        }
        let payload = issued.payload, port = payload.port
        let devices = DeviceStore(url: paths.devices)
        let known = issued.knownDeviceIds
        if args.contains("--json") {
            print(payload.url)
            return 0
        }
        if let qr = TerminalQR.render(payload.url) { print(qr) }
        print("""
        iPhone：用系统相机扫码，点开「在 Amber 中打开」
        Android：Amber → 设置 → 实验性功能 → Mac Gateway → 扫码配对
        鸿蒙：Amber → 设置 → Mac Gateway → 扫码配对

        无法扫码时，把下面的链接发到手机（AirDrop / 消息）后点开，或粘贴到上述页面：
        \(payload.url)

        网关      \(payload.name)
        地址      \(payload.addrs.joined(separator: ", ")) · 端口 \(port)
        证书指纹  \(payload.fp)
        有效期    5 分钟，仅可使用一次

        等待手机完成配对…（Ctrl-C 可退出，二维码在有效期内仍可使用）
        """)
        while Date() < issued.expiresAt {
            sleep(1)
            guard let device = devices.load().first(where: { !known.contains($0.id) }) else { continue }
            print("\n✓ 已配对 \(device.name)")
            let kind: CredentialKind = switch device.platform { case .ios: .apns; case .android: .fcm; case .harmony: .huawei }
            if CredentialStore(dir: paths.secretsDir).exists(kind) {
                print("发一条测试推送确认能收到：amber-gateway test-push --device \(device.id.prefix(8))")
            } else {
                print("还收不到推送：这台 Mac 尚未导入 \(kind.displayName) 凭据。\n  \(CredsCommand.importUsage(kind))")
            }
            return 0
        }
        print("\n二维码已过期，需要时重新运行 amber-gateway pair")
        return 1
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        return 1
    }
}
