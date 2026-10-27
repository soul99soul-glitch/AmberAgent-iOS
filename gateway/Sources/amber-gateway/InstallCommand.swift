import Darwin
import Foundation
import GatewayCore
import GatewayPush

enum InstallCommand {
    static let launchdLabel = GatewayInstallation.cliLaunchdLabel

    struct Options {
        var dryRun = false
        var launchd = true
        var home = FileManager.default.homeDirectoryForCurrentUser
        var isRealHome = true

        /// Strict: this command rewrites dotfiles and LaunchAgents, so a typo must not fall through to a real install.
        init(_ args: [String]) throws {
            var it = args.makeIterator()
            while let arg = it.next() {
                switch arg {
                case "--dry-run": dryRun = true
                case "--no-launchd": launchd = false
                case "--home":
                    guard let dir = it.next(), !dir.hasPrefix("-") else { throw InstallCommand.message("--home 需要一个目录") }
                    home = URL(fileURLWithPath: dir, isDirectory: true)
                    isRealHome = false
                default: throw InstallCommand.message("未知参数 \(arg)（可用：--dry-run --no-launchd --home <目录>）")
                }
            }
        }

        /// A fake home gets its own state dir so the plist never points into the real one.
        var paths: GatewayPaths {
            let override = ProcessInfo.processInfo.environment[GatewayPaths.stateDirEnv] ?? ""
            guard !isRealHome, override.isEmpty else { return GatewayPaths.resolve() }
            return GatewayPaths(stateDir: home.appendingPathComponent("Library/Application Support/AmberAgent/Gateway", isDirectory: true))
        }

        var installation: GatewayInstallation { GatewayInstallation(home: home) }
        var link: URL { installation.link }
        var installedBinary: URL { installation.cliBinary }
        var plist: URL { installation.cliPlist }
        /// launchctl only makes sense against the logged-in user's real home.
        var manageLaunchd: Bool { launchd && isRealHome && !dryRun }

        func hookCommand(_ source: String) -> String { installation.hookCommand(source) }
    }

    static func install(_ args: [String]) -> Int32 {
        guard let o = parse(args) else { return 64 }
        let prefix = o.dryRun ? "[dry-run] " : ""
        do {
            guard let binary = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
                throw message("无法定位自身可执行文件")
            }
            // The daemon runs from a private copy so `swift build` can't swap the binary under launchd.
            // Hooks point at a stable symlink so the hook definition (trusted in Codex `/hooks`) never changes.
            try GatewayInstallation.copyBinary(binary, to: o.installedBinary, dryRun: o.dryRun)
            try o.installation.linkBinary(o.installedBinary, dryRun: o.dryRun)
            print("\(prefix)安装 \(o.installedBinary.path)，软链 \(o.link.path)")

            try o.installation.installHooks(dryRun: o.dryRun) { change in
                print("\(prefix)\(change.url.path): \(change.changed ? "已合并 \(change.events) 个事件" : "无变化")\(change.backup.map { "（备份 \($0.lastPathComponent)）" } ?? "")")
            }

            if o.launchd {
                try writePlist(o, dryRun: o.dryRun)
                print("\(prefix)LaunchAgent \(o.plist.path)")
                if o.manageLaunchd {
                    let uid = getuid()
                    _ = GatewayInstallation.launchctl(["bootout", "gui/\(uid)/\(launchdLabel)"])
                    guard GatewayInstallation.launchctl(["bootstrap", "gui/\(uid)", o.plist.path]) == 0 else {
                        throw message("launchctl bootstrap 失败")
                    }
                    print("已通过 launchctl 启动 daemon")
                }
            }

            let store = CredentialStore(dir: o.paths.secretsDir)
            let missing = CredentialKind.allCases.filter { !store.exists($0) }
            var steps: [String] = []
            if missing.count == CredentialKind.allCases.count {
                steps.append("导入推送凭据（只需你手机对应的那一种）：\n" + missing.map { "       \(CredsCommand.importUsage($0))" }.joined(separator: "\n"))
            }
            steps.append("配对手机：amber-gateway pair")
            steps.append("""
            用 Codex 的话：打开 codex，输入 /hooks，信任 \(HookInstaller.codexEvents.count) 条命令为 \(o.hookCommand("codex")) 的 hook
                 （Codex 的安全机制，无法代劳；之后重建二进制不需要重新信任）
            """)
            print("\n下一步:")
            for (i, step) in steps.enumerated() { print("  \(i + 1). \(step)") }
            return 0
        } catch {
            FileHandle.standardError.write(Data("安装失败: \(error)\n".utf8))
            return 1
        }
    }

    private static func parse(_ args: [String]) -> Options? {
        do {
            return try Options(args)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return nil
        }
    }

    static func uninstall(_ args: [String]) -> Int32 {
        guard let o = parse(args) else { return 64 }
        let prefix = o.dryRun ? "[dry-run] " : ""
        do {
            try o.installation.removeHooks(dryRun: o.dryRun) { change in
                print("\(prefix)\(change.url.path): \(change.changed ? "已移除 gateway hooks" : "无变化")\(change.backup.map { "（备份 \($0.lastPathComponent)）" } ?? "")")
            }
            if o.manageLaunchd {
                _ = GatewayInstallation.launchctl(["bootout", "gui/\(getuid())/\(launchdLabel)"])
            }
            if !o.dryRun {
                try? FileManager.default.removeItem(at: o.plist)
                try o.installation.removeLink()
                try? FileManager.default.removeItem(at: o.installedBinary)
            }
            print("\(prefix)已移除 LaunchAgent、二进制与软链。状态目录（含配对设备与推送凭据）保留，需要时手动删除: \(o.paths.stateDir.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("卸载失败: \(error)\n".utf8))
            return 1
        }
    }

    private static func writePlist(_ o: Options, dryRun: Bool) throws {
        let log = o.paths.log.path
        let plist: [String: Any] = [
            "Label": launchdLabel,
            "ProgramArguments": [o.link.path, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardErrorPath": log,
            "StandardOutPath": log,
        ]
        if dryRun { return }
        try o.paths.ensureDirectories()
        try FileManager.default.createDirectory(at: o.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: o.plist, options: .atomic)
    }

    private struct Message: Error, CustomStringConvertible { let description: String }
    private static func message(_ s: String) -> Error { Message(description: s) }
}
