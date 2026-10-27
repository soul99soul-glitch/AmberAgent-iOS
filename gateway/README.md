# Amber Gateway

macOS 常驻守护进程：监控 Codex / Claude Code 任务状态与电脑健康，推送到各端 Amber App（iOS / Android / 鸿蒙），并提供受限上行控制（任务推送开关、测试推送、取消配对）。

**设计文档（权威）**：[docs/architecture/mac-gateway.md](../docs/architecture/mac-gateway.md)（v0.4）。2026-10-27 起源码并入本仓 `gateway/`，随 Amber 桌面版打包（`Amber.app/Contents/MacOS/amber-gateway`），并入计划见 [docs/plans/2026-10-27-gateway-integration.md](../docs/plans/2026-10-27-gateway-integration.md)。独立 CLI 部署（`install`）照常可用。

## 当前进度：G1–G4、G6 已实现（G5 不在本期范围）

| 模块 | 内容 |
| --- | --- |
| `GatewayCore` | 事件模型、会话状态机、推送策略（在场判定、范围、去重）、注册表 / 设备 / 配对票据持久化、spool、outbox、hooks 安装合并 |
| `HookIngest` | Claude Code / Codex hook 载荷解析（只取元信息）、进程树定位（PID + 启动时间）、启动方式分类 |
| `SessionWatch` | kqueue 进程退出监听、在场探针、心跳（磁盘 / 电量 / 内存压力 / 温度） |
| `GatewayTransport` | hook → daemon 的 Unix domain socket；手机 → Mac 的 HTTPS（自签 P-256 证书，客户端按 SPKI SHA-256 pinning） |
| `GatewayPush` | APNs（ES256）、FCM v1（RS256 → OAuth）、华为 Push Kit v3（PS256 服务账号 JWT）三个发送器与按平台派发 |
| `amber-gateway` | `daemon` / `hook` / `run` / `status` / `install` / `uninstall` / `pair` / `devices` / `creds` / `test-push` |

客户端：iOS `MacGatewaySettingsView`（设置 → Mac Gateway，支持系统相机扫码深链）、Android `SettingExperimentalMacGatewayPage`（设置 → 实验性功能 → Mac Gateway）、鸿蒙 `SettingMacGatewayPage`（设置 → 高级功能 → Mac Gateway）。

## 用法

```bash
swift build -c release
.build/out/Products/Release/amber-gateway install --dry-run   # 先看会改什么
.build/out/Products/Release/amber-gateway install              # 软链到 ~/.local/bin、合并 hooks（先备份）、注册 LaunchAgent
amber-gateway status                                           # 任务列表、心跳、最近推送；--json 供 SSH 查询
amber-gateway run -- make test                                 # 任意命令作为任务上报，拿得到真实退出码
amber-gateway pair                                             # 终端二维码 + 链接，5 分钟单次有效；等到手机配对成功，并提示缺哪种推送凭据
amber-gateway devices                                          # 已配对设备；devices revoke <ID 或唯一前缀> 立即吊销
amber-gateway test-push                                        # 向已上报 token 的设备发测试推送
amber-gateway uninstall                                        # 只移除 gateway 自己的 hook 分组
```

安装后需在 Codex 里执行 `/hooks` 手动信任 gateway 的 hook（Codex 的安全机制，无法代劳）。`PostToolUse` 以后台模式挂载（用于得知权限框已被批准），需要 Codex ≥ 0.148。

### 在外网使用（G6）

状态目录的 `config.json` 里两项可选配置（改完 `pair` 重新生成二维码即可，`synaraURL` 下次刷新状态生效）：

```json
{
  "publicAddresses": ["103.201.130.63"],
  "synaraURL": "https://<VPS 域名>:8944/?gate=<口令>"
}
```

- `publicAddresses`：从外网能到达本机 47821 端口的主机名或 IP（只写主机，不带协议和端口），通常是 VPS 反向隧道 `ssh -N -R 0.0.0.0:47821:127.0.0.1:47821 <vps>`，VPS 防火墙放行 47821。它进二维码候选地址，排在 `.local` 之后、局域网 IP 之前；TLS 仍在本机终止，证书指纹 pinning 不变。已配对的手机要重新扫码才会拿到新地址。
- `synaraURL`：Synara 网页的外网地址。配置后手机「任务」区出现「在 Synara 中回复或确认」，用浏览器打开 Synara 处理 Synara 里的任务（首次需在该浏览器完成 Synara 自己的配对）。Synara 托管的任务在列表里标注「Synara」。
- 终端里直接运行的 Claude Code 会话不经过 Synara，远程回复用 Claude Code 自带的 `claude --remote-control`（在手机的 Claude App 里继续）。

### 推送凭据

凭据只存在本机状态目录的 `secrets/`（目录 700、文件 600），不进仓库：

```bash
amber-gateway creds import apns   --key AuthKey_XXXX.p8 --key-id XXXX --team-id YYYY --topic <iOS bundle id>
amber-gateway creds import fcm    --service-account firebase-sa.json
amber-gateway creds import huawei --service-account agc-sa.json [--project-id ID] [--category MARKETING]
amber-gateway creds                                            # 查看导入状态
```

- **鸿蒙**：安装包必须在 AppGallery Connect 开通推送服务，并在 `entry/src/main/module.json5` 的 `metadata` 里配置 `client_id`，否则 App 拿不到 Push Token（错误码 1000900010），页面会给出中文提示。
- **华为消息分类**：默认 `MARKETING`，未申请自分类权益时每台设备每天只能收到很少几条（华为限额）；申请到服务与通讯类权益后用 `--category` 指定。测试推送带 `pushOptions.testMessage`（走项目级每日 1000 条的独立额度），不占真实提醒的频控；被频控的消息华为仍返回成功，故 `test-push` 成功只代表已被华为接受。
- **Android**：需要 Firebase 项目与 `google-services.json` 对应的 App；token 存在 App 私有 DataStore。

开发调试时设置 `AMBER_GATEWAY_STATE_DIR=/tmp/xxx` 可把状态目录（socket、注册表、设备、凭据、证书）整体隔离；`install --home DIR --no-launchd` 可对临时 home 演练安装。

## 测试

`swift test`：46 项（8 个 suite）。覆盖：
- 34 条 golden 状态向量（`Tests/GatewayTests/Fixtures/golden/state-vectors.json`）与 hook 映射表。
- hook 零输出约束，以及 kqueue 秒级退出感知。
- 安装器合并与幂等。
- 真实 daemon 端到端：run 结局、kill -9、spool 回放、重启持久化。
- HTTPS API 与配对：单次票据、pin 不匹配时不泄露 secret、吊销立即 401；重复配对不产生重复推送、`devices.json` 损坏时返回 500 且不覆盖。
- 三家推送发送器的请求构造、签名校验与错误分类。

## 实测记录（2026-09-27，macOS 27.2，M 系列）

- hook 进程端到端耗时（含进程启动）：daemon 在线 P95 6.8ms，daemon 不在线写 spool P95 7.6ms（预算 50ms）。
- 真实 `claude -p` / `codex exec`：结局判定正确，中途 `kill -9` 0.17s 判定「已停止（异常）」。
- Android 客户端（JVM 直连真实 daemon）：
  - 地址回退正常，配对票据单次有效。
  - status / 健康信息解码正确，push-token 上报成功。
  - pin 错误时报「证书不一致」，取消配对后返回 401。
- 鸿蒙真机（HUAWEI Pura X Max）：
  - `.local` 主机名在鸿蒙上无法解析，自动回退到 IP 后配对成功。
  - RCP 证书公钥锁定使用纯 base64 的 SPKI 指纹。
  - 状态、健康、任务列表正常渲染。
  - 未配置 `client_id` 时拿不到 Push Token，页面给出中文提示。

## 已知限制

- 真实推送送达需要你自己的 APNs / FCM / 华为凭据和真机，本仓库只验证到服务端请求构造与错误分类。
- Mac 睡眠、合盖或断网时无法推送；睡眠期间的行为未做长时间实测。
- 鸿蒙不解析 `.local`，配置 `publicAddresses` 后在家也会经 VPS 连接（能用，延迟更高）；VPS 隧道重连期间（最长约 3 分钟）请求可能先卡住再失败。
- Codex ≥ 0.157 的终端会话运行在 CLI 托管的 app-server 守护进程里，多个终端会话共用这个进程：按代码推断，直接关掉终端窗口且没有结束事件时，任务会停在最后的状态（未实测）。
- Synara 里的 Codex 会话读的是 Synara 的覆盖目录，装好 hooks 后要等 Synara 下次拉起 Codex 才会生效。
- 鸿蒙端「证书不一致」依赖 RCP 的错误码 1007900090（对应 curl 的 PINNEDPUBKEYNOTMATCH），尚未在真机上触发验证；不匹配时至少会报「无法连接」，不会误连。
