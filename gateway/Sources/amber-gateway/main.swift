import Foundation
import GatewayCore

let arguments = Array(CommandLine.arguments.dropFirst())
let rest = Array(arguments.dropFirst())

switch arguments.first {
case "hook":
    HookCommand.run(rest)
case "daemon":
    let paths = GatewayPaths.resolve()
    // Under SMAppService (Amber app) launchd gives no StandardErrorPath; keep the same log file as the CLI plist.
    if isatty(STDERR_FILENO) == 0, (try? paths.ensureDirectories()) != nil {
        _ = freopen(paths.log.path, "a", stderr)
    }
    Daemon(paths: paths).run()
case "run":
    exit(RunCommand.run(rest))
case "status":
    exit(StatusCommand.run(rest))
case "install":
    exit(InstallCommand.install(rest))
case "uninstall":
    exit(InstallCommand.uninstall(rest))
case "pair":
    exit(PairCommand.run(rest))
case "devices":
    exit(DevicesCommand.run(rest))
case "creds":
    exit(CredsCommand.run(rest))
case "test-push":
    exit(TestPushCommand.run(rest))
default:
    let asked = arguments.isEmpty || ["help", "-h", "--help"].contains(arguments[0])
    if !asked { print("未知命令：\(arguments[0])\n") }
    print("""
    用法: amber-gateway <命令>

      install [--dry-run] [--no-launchd] [--home DIR]
                                  安装 hooks 与 LaunchAgent
      uninstall [--dry-run] [--home DIR]
      status [--json]             查看任务状态、本机状况与最近的推送
      pair                        生成配对二维码（5 分钟单次有效）
      devices [revoke <ID>]       查看 / 吊销已配对设备
      creds [import|delete ...]   管理 APNs / FCM / 华为推送凭据
      test-push [--device <ID>]   向已配对设备发送测试推送
      run -- <cmd> [args...]      包装任意命令，作为任务上报开始与结局
      daemon                      前台运行守护进程（通常由 launchd 拉起）
      hook claude|codex           agent hook 入口（从 stdin 读事件，无任何输出）

    状态目录: \(GatewayPathsDescription.current)
    """)
    exit(asked ? 0 : 64)
}
