# Amber Mac Gateway 设计（v0.4，实施中）

状态：实施中，代码在 `~/Downloads/AI/amber-gateway`（独立 SwiftPM 包）。v0.4（2026-09-27）把 G1 实施中经运行时证据修正的设计、G2–G4 的三端落地清单与分期验收写回本文，偏差逐条列在修订记录。v0.2（2026-09-27）按评审修订：配对改二维码 + 证书 pinning、本地传输改 TLS、hook 通道改 Unix domain socket、Codex 接入改 hooks 体系、停滞检测改进程监听、明确单开发者自用定位。v0.3（2026-09-27）修正进程监听的可行性边界（退出码仅子进程可得、进程树定位、多会话宿主）、hook 时延预算、推送在场判定、凭据与设备吊销、iOS entitlement 缺口。修订记录见文末。与 `cross-device-collaboration.md` 的关系：本文是其「事件 + 推送 + 受限控制」纵切的先行实现，不是替代。

## 1. 定位与目标

**一句话**：Mac 上低占用常驻守护进程，把「Codex / Claude Code 任务进行到什么状态」和「电脑健康状态」推送到手机，并提供手机 → Mac 的受限控制；替代目前「单向 SSH 上去查」的模式。

- **产品边界**：Gateway 是「手机订阅 Mac 事件 + 下发受限控制」的单主机模型，不做对等协同、不做会话内容同步。
- **v1 定位：单开发者自用**（决策 D8）。APNs `.p8` 是 team 级密钥、FCM 服务账号是项目级凭据，只能装在自己的 Mac 上；一旦 App 分发给其他用户，每台 Gateway 都等于公开这些凭据——那之前必须先建一个极薄的推送中继来承载凭据（v2 范围）。
- **非目标（v1）**：对话内容同步、跨设备工具借用、中继服务、Mac 上运行 amber agent 本体（决策 D5 相关演进见 G5）。

## 2. 当前基线

| 问题 | 决策 |
| --- | --- |
| 平台与形态 | macOS（Apple Silicon）用户级 LaunchAgent 常驻 + 同一可执行文件的 CLI 子命令 |
| 资源目标 | 空闲 RSS < 30MB，空闲 CPU ≈ 0 |
| 心跳 | 60s 本地采集，只做本地阈值判定，越限才通知；不做远程仪表盘 |
| 任务定义 | 一个任务 = 一次 agent 会话（session_id + 项目 cwd），或 `amber-gateway run -- <cmd>` 包装的任意进程。v1 内置 Codex 与 Claude Code 会话；自定义任务经 run 包装器 |
| 监控对象范围 | 用户级 hooks 作用于所有宿主拉起的会话（含 Cursor、Synara 等）；v1 默认全部登记、按项目 cwd 分组展示，但**只对交互会话推送「等你回复」**，非交互宿主（自动化线程、headless）只推完成/异常且单独限流；提供 exclude 列表（决策 D9） |
| 上行控制面 | v1 就有：手机可指定监控哪些任务、查看状态、请求测试推送。作用范围 = 局域网或 Tailscale 组网（5.1）；跨网不依赖公网可达 |
| 接收端 | 各端 Amber App 本身（iOS / Android / 鸿蒙），不做独立 Gateway App |
| 推送通道 | Mac 直连 APNs / FCM HTTP v1 / 华为 Push Kit，不自建服务器；一次性准备三套凭据 |
| 推送正文 | 只含元信息（agent 名、任务/项目名、状态），不含代码与对话内容。v1 无端到端加密，推送云视为不可信，此为硬约束 |
| 时延指标 | 事件类推送（等待你处理、headless 已完成、异常停止）从「满足推送条件」起 → 送达 ≤ 5s（P95）。「等你回复」的推送条件含在场判定（3.5），人在 Mac 前时的延后不计入此指标；心跳类与掉线提示不适用 |

## 3. 监控机制

### 3.1 机制 A：hooks（首选，事件驱动）

Gateway 提供统一入口 `amber-gateway hook <source>`，经 Unix domain socket 交付事件（见 3.4）：

- **Claude Code**：`~/.claude/settings.json` 配置 hooks：`SessionStart`、`UserPromptSubmit`（新回合开始，取消待推送）、`PermissionRequest`（即时）、`Notification`（`permission_prompt` 约 6s / `idle_prompt` 约 60s / `elicitation_*`）、`Stop`（回合结束）、`StopFailure`（回合因 API 错误结束）、`SessionEnd`。
- **Codex**：采用与 Claude Code 同构的 hooks 体系（`~/.codex/hooks.json`），v1 接 `SessionStart`、`UserPromptSubmit`、`PermissionRequest`、`Stop`、`Interrupt`、`SessionEnd`（`SessionEnd` hook 超时上限 3s，入口 200ms 内返回不受影响）。**不使用顶层 `notify`**：它只发 `agent-turn-complete` 一种事件；openai/codex#19921 中维护者表示顶层 `notify` 将被 hooks 取代、不再扩展（尚无时间表）。
- **覆盖缺口（G1 实测）**：Codex plan 模式的 `request_user_input` 提问目前未见对应 hook，这类「等待」可能只能由随后的 `Stop` 间接反映，或完全漏掉；G1 实测后在 3.3 词表中标注。
- **v1 不挂 `PreToolUse` / `PostToolUse`**：它们每次工具调用同步触发，daemon 一旦卡住会拖慢每次调用。「运行中」由 `SessionStart` / `UserPromptSubmit` 给出，停滞判定见 3.3（v0.4 取消 JSONL 尾读，D11）。若后续确需挂载，Codex 侧必须用后台 hook 模式。
- **信任审核（Codex 特有）**：非托管 hook 须由用户在 `/hooks` 里信任后才会执行；Codex 按 **hook 定义**（命令字符串等配置内容）的哈希记录信任，而非二进制内容。安装流程把这一步作为显式手动步骤交付（给出精确指引）；hook 命令指向固定路径 `~/.local/bin/amber-gateway`（软链到真实二进制），重建二进制不改变定义、无需重新信任。**不加 shim 层**：它不改变信任行为，反而多一层中间进程（影响 3.2 进程树定位）。G1 实测确认。
- **Gateway hook 行为硬约束**：v1 所挂事件中，Codex 的 `PermissionRequest`（allow/deny）和两端的 `Stop`（block / continue）都可返回决策。Gateway 的 hook 入口**只读不写**：不产生任何 stdout/stderr、不返回任何决策，解析后立即退出，绝不影响 agent 行为。此约束有专项测试。
- **安装器（`amber-gateway install` / `uninstall`）**：修改 `~/.claude/settings.json` 与 `~/.codex/hooks.json` 时幂等合并——用户已有的 hooks/notify 串联保留、不覆盖；写前备份；`uninstall` 还原。

### 3.2 机制 B：进程监听（兜底，替代 mtime 判停滞）

用 kqueue `EVFILT_PROC`/`NOTE_EXIT` 监听会话进程退出：零 CPU，`kill -9` 秒级感知。

**定位会话进程**：hook 命令由 agent 经 `sh -c` 拉起，`getppid()` 拿到的是瞬时 shell，不可直接使用。hook 入口用 `proc_pidinfo`（`PROC_PIDTBSDINFO`）沿进程树向上查找，直到命中 agent 进程，把该 PID 连同 hook 事件一起交给 daemon。匹配规则（G1 实测修正）：Claude 原生安装的可执行文件以版本号命名（`~/.local/share/claude/versions/2.1.283`），按路径含 `/claude/versions/` 或 node 进程参数含 `claude-code` 识别；Codex 按文件名 `codex`。

**会话来源**（按 agent 进程启动参数判定）：Codex `app-server` / `mcp-server`、Claude `--input-format stream-json` → 宿主（host）；Codex `exec`、Claude `-p/--print` → headless；其余 → 交互。

**防 PID 复用**：登记键为 (PID, 进程启动时间 `pbi_start_tvsec/usec`)；daemon 注册 kqueue 前校验两者一致，不一致视为已退出；注册返回 `ESRCH` 同样视为已退出。

**退出码只对子进程可得**：macOS 的 `NOTE_EXITSTATUS` 仅对调用方的子进程有效，daemon 对用户在终端拉起的 agent 只能知道「退出了」，拿不到退出码。因此结局判定分两类：

| 任务来源 | 判定方式 |
| --- | --- |
| `amber-gateway run -- <cmd>` | `run` 是 cmd 的父进程，自行 `waitpid` 拿退出码并上报：exit 0 → 「已完成」，非 0 / 信号 → 「已停止（异常）」 |
| `claude -p` / `codex exec` 等外部进程 | 组合判定：退出前收到过 `Stop` 或 `SessionEnd` → 「已完成」；未收到即退出 → 「已停止（异常）」 |

**多会话宿主**：Cursor、Synara、ChatGPT 桌面端等宿主通过 Codex app-server 或 Claude Agent SDK 在一个进程里跑多个会话，此时「进程退出 ≠ 某会话结束」「进程存活 ≠ 会话存活」。规则：会话来源为 host 时，会话状态以 hook 事件为准；进程退出时把其下所有未结束会话统一置「已停止（异常）」并合并为一条推送，进程监听只作兜底。**v0.4 修正**：不再用「同一 PID 登记多个 session_id」推断宿主——G1 实测 `codex exec` 会在同一进程内跑一个内部记忆会话（cwd `~/.codex/memories`），该推断会把普通 headless 任务误判为宿主。宿主只按启动参数判定，`~/.codex/memories` 默认进 exclude 列表。

**不采用文件 mtime 判停滞，v0.4 也不做 JSONL 尾读（D11）**：hooks 已覆盖全部状态转移；JSONL 每行混有对话内容，尾读带来的只是「首次安装回填历史会话」这一低价值功能，却要长期跟随两家私有格式变化。停滞判定改为「headless 会话超过阈值无任何事件」（3.3）。

### 3.3 状态词汇表 v2

| 状态 | 来源事件 |
| --- | --- |
| 运行中 | `SessionStart` / `UserPromptSubmit` / `run` 启动 |
| 等待你处理 | `PermissionRequest`；Claude Code 权限/空闲 `Notification`；交互会话回合结束（`Stop` / `StopFailure` / `Interrupt`）立即转入此状态，推送受在场判定约束（3.5） |
| 已完成 | 仅 headless 场景：`run` 包装任务以 exit 0 为准；外部 `claude -p` / `codex exec` 以「先 `Stop`/`SessionEnd` 后退出」为准（3.2） |
| 已停止 | `SessionEnd`（交互会话）；会话进程退出（NOTE_EXIT 秒级感知）；异常退出标注「（异常）」 |
| 疑似停滞 | headless 会话处于「运行中」且超过 `headlessStallMinutes`（默认 60）无任何事件，由 60s 心跳检查；只推一次，下一个事件恢复「运行中」。交互会话空闲是正常行为，不判停滞 |

v0.1 的「判稳 90s 窗口」移除：交互模式下新回合只由用户输入触发，固定窗口只会无差别延迟推送。「已完成」不再用于交互会话——回合结束本身就是用户最需要的信号；「人是否在 Mac 前」由 3.5 的在场判定处理。

### 3.4 hook → daemon 传输

- **Unix domain socket**（`~/Library/Application Support/AmberAgent/Gateway/gateway.sock`，目录 700、socket 600），不用 `127.0.0.1` TCP：文件权限天然限制调用方，堵住「本机任意进程可 POST」的问题。
- hook 进程必须快速退出：UDS 连接 + 写入硬超时 **200ms**（非阻塞 socket）；daemon 不在线、拒绝连接或超时，一律把事件写入本地 spool 目录后立即返回退出码 0，**绝不阻塞 agent**；daemon 启动及每次恢复连接时回放 spool。hook 进程总耗时预算（含进程启动与进程树查找）P95 < 50ms，G1 实测。

### 3.5 推送在场判定

交互会话每个回合结束都会进入「等待你处理」，而「等待你处理」不去重；人坐在 Mac 前来回对话时若每回合都推，手机会被刷屏。规则：

- **人不在**（屏幕已锁定，或 IOKit `HIDIdleTime` ≥ 在场阈值，默认 60s）：立即推送。
- **人在**：不推，挂起为待推送；若仍处于「等待你处理」且空闲时间达到阈值或屏幕锁定，补推一次；期间用户回复（新回合开始）则取消。
- Claude Code 自带的空闲 `Notification`（等待输入约 60s 后触发）与此语义一致，可作为同一待推送项的确认信号，不重复推。
- 权限请求类（Codex `PermissionRequest`、Claude Code 权限 `Notification`）同样适用在场判定，但阈值可单独配置得更短。
- 非交互宿主的会话不推「等你回复」（第 2 节 D9）。

## 4. 推送管道

三通道同为「HTTPS + 自签 JWT」形态：`GatewayPush` 目标下三个适配器，`URLSession` 实现（APNs 需 HTTP/2，URLSession 经 ALPN 自动协商），签名用 CryptoKit / Security.framework，不引第三方 SDK：

| 通道 | 凭据 | 鉴权 | 接收端 |
| --- | --- | --- | --- |
| APNs | Apple `.p8` + Key ID + Team ID + bundle id（topic） | ES256 JWT（约 50 分钟复用） | iPhone / iPad |
| FCM HTTP v1 | Firebase 服务账号 JSON | RS256 JWT 换 OAuth access token（`firebase.messaging` scope，按过期时间复用） | Android |
| 华为 Push Kit v3 | AGC 服务账号密钥 JSON（`key_id`、`sub_account`、`private_key`）+ projectId | PS256 JWT 直接作 Bearer（HarmonyOS 5+ 不再支持 OAuth 客户端模式） | 鸿蒙 NEXT |

- **凭据存放（v0.4 修正，D12）**：`amber-gateway creds import <apns|fcm|huawei> ...` 把凭据复制到状态目录 `secrets/`（目录 700、文件 600），不进 Keychain。原因：唯一可用的签名证书已吊销，二进制只能 ad-hoc 签名；旧式文件 Keychain 的 ACL 绑定 cdhash，每次升级二进制都会弹授权框并阻塞无界面的 daemon。600 文件与 Claude Code / Codex 保存自身凭据的方式同级。有 Developer ID 后可再迁回 Keychain。**不自动删除原文件**（`.p8` 只能下载一次），`--delete-source` 显式选择。
- token 上报携带 environment 字段：APNs 分 sandbox（Xcode 开发构建）与 production（TestFlight / App Store），Gateway 按设备各自的环境选择主机。APNs 返回 410 / `BadDeviceToken`、FCM 返回 `UNREGISTERED`、华为返回 token 无效时删除该推送 token。
- 只发 **alert**（锁屏可见，只含元信息）。静默推送不实现：系统限流、强退后不达，面板数据以前台直连拉取为准。
- 「等待你处理」用 `interruption-level: time-sensitive`（APNs）/ 高优先级（FCM `android.priority=HIGH`）。iOS 需 `com.apple.developer.usernotifications.time-sensitive` entitlement（G2 补齐）。
- 华为通知必须带 `category`：未申请自分类权益时只能用 `MARKETING`（资讯营销，静默展示、有频控：每台设备每日仅少量条数）；申请到「工作事项提醒」等权益后，`creds import huawei --category WORK` 切换。测试推送带 `pushOptions.testMessage: true`，不占设备的 MARKETING 频控。
- 去重与限流：同一 `(任务, 状态)` 10 分钟窗口内不重复推送；「等待你处理」不去重。
- 推送派发在独立串行队列异步执行，不阻塞 hook 接收与状态机；每条推送写 `outbox.jsonl`（`status` 可查）。
- **Live Activity** 不进 v1（仓库现有 `AgentLiveActivityController` 为本地更新，改推送更新需 `pushType: .token` 与 `liveactivity` push type，收益不抵成本）。

## 5. 连接、配对与控制通道

### 5.1 通道分层

| 通道 | 用途 | 范围 |
| --- | --- | --- |
| 本地 HTTPS（自签证书 + 公钥 pinning），端口 47821 | 配对、任务列表、监控开关、token 上报、测试推送 | 局域网 |
| Tailscale / WireGuard 组网（**推荐路径**） | 装入后同一 API 全网可用 | 全网 |
| SSH 只读兜底 | `amber-gateway status --json` | 全网 |
| 云推送（APNs / FCM / 华为） | 事件通知 | 全网 |
| 中继 | 跨网控制与协作 | v2 |

**全程 TLS**：daemon 首次启动用系统自带 `/usr/bin/openssl` 生成 EC P-256 自签证书（有效期 10 年），PKCS#12 存于 `secrets/tls.p12`，运行时 `SecPKCS12Import(kSecImportToMemoryOnly)` 得到 `SecIdentity` 交给 `NWListener`。v0.3 的 `swift-certificates` 依赖取消：只为一张自签证书引入三个包不划算。

- **pinning 对象 = 证书公钥的 SPKI SHA-256（base64）**，而非整张证书的哈希：鸿蒙 `http` 的 `certificatePinning.publicKeyHash`、OkHttp 惯例都以 SPKI 为准，三端统一。客户端在 TLS 握手中取叶子证书公钥比对，不走系统信任链；pinning 绑定密钥而非地址，地址变化不影响信任。
- **不做 Bonjour（v0.4，D13）**：二维码候选地址已含 `<LocalHostName>.local`（mDNS 解析，IP 变化自动跟随）、当前局域网 IPv4 与 Tailscale MagicDNS 名；再加 Bonjour 广播只多一个 macOS 本地网络隐私弹窗点，不增加可达性。
- 最小 HTTP/1.1 服务（每请求一连接，`Connection: close`，请求体上限 64KB），JSON 接口：

| 方法与路径 | 鉴权 | 作用 |
| --- | --- | --- |
| `POST /v1/pair` `{secret, deviceName, platform}` | 一次性 secret | 换取 `{deviceId, token, gatewayId, gatewayName}` |
| `GET /v1/status` | Bearer | 任务列表 + 心跳快照 + 本设备推送状态 |
| `POST /v1/tasks/{key}/monitor` `{monitored}` | Bearer | 开/关某任务监控 |
| `POST /v1/push-token` `{token, platform, environment}` | Bearer | 上报/更新推送 token（`platform` ∈ ios/android/harmony） |
| `POST /v1/test-push` | Bearer | 向本设备发一条测试推送，同步返回投递结果 |
| `POST /v1/unpair` | Bearer | 手机端取消配对，网关同步删除本设备 |

控制命令 v1 白名单即上表；「停止 agent 任务」不进 v1（D6）。所有配对、吊销、凭据导入写 `audit.jsonl`。

**设备管理（Mac 本地 CLI，不开放给远程）**：`amber-gateway devices` 列出已配对设备（名称、平台、推送通道、配对时间、最后活跃）；`amber-gateway devices revoke <id>` 立即删除设备记录（API 返回 401、不再推送）。设备 token 只存 SHA-256。

### 5.2 配对（二维码 + 公钥 pinning）

1. `amber-gateway pair` 生成 128-bit secret（只落盘其 SHA-256，5 分钟单次有效），在终端用半格字符渲染二维码并打印同内容链接：`amber://gateway/pair?p=<base64url(JSON {v, id, name, addrs[], port, fp, s})>`。
2. App 获得 payload → 按候选地址顺序连接 → 校验 SPKI 指纹 → `POST /v1/pair` → 保存 {gatewayId、名称、候选地址、端口、指纹、设备 token}（设备 token：iOS 进 Keychain；Android 存 App 私有 DataStore；鸿蒙存 App 私有 KV 存储）→ 立即申请通知权限并上报推送 token。
3. 获得 payload 的途径：
   - **iOS**：用系统相机扫码，二维码内容即 `amber://` 深链，直接唤起 App（stable 构建 scheme 为 `amber`）；另可在设置页粘贴链接。无需 App 内扫码器。
   - **Android**：设置页内置扫码（复用现有 Quickie 扫码组件）或粘贴链接。Android 注册的 scheme 是 `amberagent://`，不接系统深链——扫码与粘贴都在 App 内解析，与 scheme 无关。
   - **鸿蒙**：同 Android，不接系统深链；设置页用 Scan Kit 扫码或粘贴链接。
   - **鸿蒙**：设置页用 Scan Kit `scanBarcode.startScanForResult` 扫码或粘贴链接。
4. 放弃 v0.1 的 6 位短码派生密钥（理由见 v0.2 修订记录），短码场景未来用 SPAKE2。

## 6. 数据、心跳与已知局限

- 本地状态目录 `~/Library/Application Support/AmberAgent/Gateway/`：`registry.json`（任务注册表 + 心跳快照 + 当前健康告警）、`devices.json`、`pairing.json`、`outbox.jsonl`、`audit.jsonl`、`spool/`、`secrets/`、`config.json`（可选）、`daemon.log`，全部落盘，daemon 重启不丢。
- 60s 心跳：磁盘可用 < 20GB；电池 < 20% 且未接电源（仅笔记本）；内存压力 critical（DispatchSource，事件驱动）；热状态 serious/critical。**只在进入越限状态时推一次**，恢复静默清除，重新越限再推；告警集合持久化，daemon 重启不重复推。
- 事件保留 7 天。

**已知局限：Mac 掉线不可推送**。无自建服务器，Mac 合盖、睡眠或断网时，手机无法区分「一切正常」与「Mac 失联」。缓解：

1. 睡眠前提示：IOKit `IORegisterForSystemPower` 监听 `kIOMessageSystemWillSleep`，仍有未结束任务时尽力发一条「即将睡眠」再 `IOAllowPowerChange`；睡眠前网络可能已断开，允许失败。
2. 可选 `preventIdleSleepWhileRunning`：有 headless 任务运行时持有 `IOPMAssertion` 阻止**空闲**睡眠（挡不住合盖睡眠）。
3. App 面板在线时显示最近心跳时间；连不上时显示「无法连接」并提示 Mac 可能睡眠或断网（未实现「超过 3 分钟标失联」，连不上即视为失联）。

## 7. 安全

- 威胁模型：局域网内其他设备不可信；推送云不可信；宿主机其他用户/进程不可信（UDS 文件权限约束）。
- 本地 API 全程 TLS + 公钥 pinning；配对 secret 高熵、单次、5 分钟；设备 token 只存哈希；hook 入口走 UDS，目录 700、socket 600。
- 推送正文仅元信息（第 2 节硬约束）。
- 控制命令白名单 + 审计日志；已配对设备可在 Mac 本地随时吊销。
- 凭据在 `secrets/`（600），原文件由用户确认后删除（第 4 节，D12）。
- 部署：二进制复制到 `~/.local/share/amber-gateway/bin/` 由 LaunchAgent 拉起，`~/.local/bin/amber-gateway` 软链供 hooks 与 CLI 使用；`swift build` 不会替换正在运行的 daemon。首次监听 47821 端口时 macOS 防火墙（若开启）可能弹入站提示。

## 8. 工程结构与代码归属

```
~/Downloads/AI/amber-gateway/          # 独立 SwiftPM 包，macOS 15+
  Sources/amber-gateway/               # CLI：daemon | hook | run | status | install | uninstall | pair | devices | creds | test-push
  Sources/GatewayCore/                 # 模型、状态机、注册表与推送决策、心跳判定、配置、存储、推送文案
  Sources/HookIngest/                  # hook 载荷解析 + 进程树定位与来源判定
  Sources/SessionWatch/                # kqueue 进程监听、在场探测、健康采样、睡眠监听
  Sources/GatewayTransport/            # UDS hook 通道 + spool、TLS 身份、HTTP API、配对与设备表
  Sources/GatewayPush/                 # APNs / FCM / 华为适配器、JWT 签名、凭据、派发器
  Tests/GatewayTests/                  # golden 状态向量、hook 零输出、端到端 daemon、API 与推送请求构造
```

**依赖策略（D5）**：纯 Swift，无第三方依赖；不链接 `Shared.framework`。

**iOS（amberagent-ios，stable 构建）**：
- 新增 `MacGatewayClient.swift`：payload 解析、SPKI pinning 的 `URLSessionDelegate`、四个 API 调用；`MacGatewayStore`（`@Observable`）持有配对信息（设备 token 进 Keychain，复用 `IOSCredentialSideTable`），负责申请通知权限、`registerForRemoteNotifications`、上报 APNs token。
- `AmberAppDelegate.didRegisterForRemoteNotificationsWithDeviceToken` 在转发给现有 backend coordinator 之外，同时交给 `MacGatewayStore`。
- 深链：`IOSAppDeepLink` 增加 `gatewayPair(payload:)`，路由到设置 → Mac Gateway 并自动发起配对。
- 设置页：`Route.macGateway`，设置首页加一行；`MacGatewaySettingsView` 沿用 `IOSWatchSettingsView` 的页面骨架与 `AmberFormGroup`/`AmberFormRow` 组件：配对状态、推送状态、测试推送、任务列表（监控开关）、粘贴配对、取消配对。
- `AmberAgent.entitlements` 增加 time-sensitive，同步 `AmberAgentConfiguredEntitlements` 镜像与 `IOSReleaseConfigurationTests`。
- 新文案进 `Localizable.xcstrings`（key 为中文原文，补 en / zh-Hant / ja / ko / ru）。

**Android（amberagent-Android）**：
- 加 `firebase-messaging`；`MacGatewayMessagingService : FirebaseMessagingService`（`onNewToken` 上报、前台 `onMessageReceived` 自行展示）；通知渠道 `mac_gateway`。
- `MacGatewayRepository`：payload 解析、OkHttp 自定义 `X509TrustManager` 做 SPKI pinning、四个 API；配对信息存 App 私有 DataStore（未用已废弃的 EncryptedSharedPreferences）。
- 设置页：`Screen.SettingExperimentalMacGateway`，挂在实验设置下（与 Synara 同级），用 `ExperimentSectionCard` 等现有组件；Quickie 扫码。
- 文案按 `scripts/check_android_localization.py` 要求补齐 6 种语言。
- debug 包名 `app.amber.agent.graphite` 不在 `google-services.json` 中，拿不到真实 FCM token；验证推送用 `graphite` 构建类型（包名 `app.amber.agent`）。

**鸿蒙（amber-harmony-preview/harmony，ArkTS，API 12）**：
- `platform_impl/MacGatewayClient.ets`：RCP（`@kit.RemoteCommunicationKit`）`remoteValidation: 'skip'` + `certificatePinning`（公钥 SPKI SHA-256，纯 base64，真机验证）；配对信息存 App 私有 KV 存储；`pushService.getToken()` 上报，启动时补报。`module.json5` 需 AGC `client_id` 元数据（须用户在 AGC 开通 Push Kit 后填入），缺失时 getToken 报 1000900010，页面给出中文提示。
- `pages/SettingMacGatewayPage.ets`：登记 `main_pages.json`，`SettingPage` 高级功能组加一行 `CardRow`；Scan Kit 扫码。
- 真机实测：鸿蒙不解析 `.local`，客户端按候选地址顺序回退到 IP。
- 遵守仓库 `harmony-arkts` 铁律；Android 源码只读。

## 9. 分期计划与验收标准

**G0：凭据准备（用户操作，不阻塞开发）**
Apple `.p8`（同 team）、Firebase 服务账号 JSON、AGC 服务账号密钥 + 开通 Push Kit（拿到 `client_id`）。凭据到位前，推送适配器以请求构造单测 + 本地模拟服务验证，真实投递列为待用户执行的验收项。

**G1：Gateway 单机可用（已完成）**
daemon + launchd 安装、hooks 接入双 agent、UDS hook 入口 + spool、进程树定位与进程监听、在场判定、状态机、`run` 包装器、`status`；心跳（磁盘/电池/内存压力/热状态）与越限告警、headless 停滞检测、睡眠前提示、可选防空闲睡眠。
验收（已实测）：交互会话回合结束 → 等待你处理，人在不推、离开补推、回复取消；`run -- true/false/kill -9` 结局正确；外部 `claude -p` / `codex exec` 正常结束 → 已完成，`kill -9` 秒级 → 已停止（异常）；进程树命中 agent；PID 复用不误判；宿主进程退出合并推送；hook 零输出、daemon 挂起时 200ms 内落 spool、P95 < 50ms（实测 6.8ms）；install 幂等且保留已有 hooks、uninstall 还原；重启不丢状态、spool 回放；RSS < 30MB（实测约 8MB）、空闲 CPU ≈ 0；golden 向量全绿。

**G2：Mac 推送与控制面 + iPhone 接入**
Mac：TLS 身份、HTTP API、`pair` 二维码、`devices` 列表/吊销、`creds` 导入、APNs 适配器、推送派发、`test-push`、审计日志。iOS：上一节清单。
验收：
- Mac：配对 → 状态查询 → 监控开关 → token 上报 → 吊销后 401，全链路以集成测试覆盖（真实 TLS + pinning）；secret 过期/重放被拒。
- APNs 请求构造（主机、头、JWT 可用公钥验签、正文字段）单测；410 删除 token。
- iOS：解析/深链/pinning 单测；stable 构建编译通过；模拟器上设置页视觉检查（对齐、间距、尺寸）；真机扫码配对与锁屏送达、time-sensitive 穿透专注模式、sandbox/production 两套环境——需真机与 `.p8`，列为用户执行项。

**G3：Android 接入**
FCM 适配器（RS256 → OAuth → v1 send，`UNREGISTERED` 删除 token）+ Android 清单。
验收：FCM 请求构造与 token 交换以本地模拟服务测试；Android `compileDebugKotlin` 与单测通过、本地化审计 PASS；真机送达需服务账号与设备，列为用户执行项。D4（国行 GMS）结论：v1 只做 FCM，国行无 GMS 设备走鸿蒙/厂商通道留待需求出现。

**G4：鸿蒙接入**
华为 Push Kit v3 适配器（PS256 JWT）+ 鸿蒙清单。
验收：请求构造与 PSS 签名可验签单测；ArkTS lint 与构建通过；真机送达需 AGC `client_id` 与服务账号，列为用户执行项。

**G5（可选，不在本轮范围）：并入对等协同**
事件模型迁入 `core/collab`、信封协议、Ed25519 挑战-应答配对、中继。依赖 collab 草案与中继部署决策（D7），v1 单开发者定位下没有收益，不做。

## 10. 决策表

| # | 问题 | 当前取向 | 状态 |
| --- | --- | --- | --- |
| D1 | 控制通道可达性 | 局域网 TLS API；跨网推荐 Tailscale/WireGuard；SSH 只读可选；中继 v2 | 已确认 |
| D2 | 配对方式 | 二维码 + 公钥 pinning + 高熵 secret；粘贴兜底；iOS 系统相机直接唤起深链 | 已确认，v0.4 pinning 对象改为 SPKI |
| D3 | 分期口径 | iPhone → Android → 鸿蒙 | 已确认 |
| D4 | 国行安卓 GMS 现状 | v1 只做 FCM；厂商通道按需再议 | v0.4 定 |
| D5 | v1 不链接 Shared.framework，纯 Swift 独立包 | CLI 版 amber 愿景移到 G5 | 已确认 |
| D6 | 「停止任务」不进 v1 控制面 | v1 控制面 = 查询 + 配置 | 已确认 |
| D7 | collab 草案遗留问题 | 随 G5 处理 | 搁置 |
| D8 | v1 定位 | 单开发者自用；分发前须建推送中继 | 已确认 |
| D9 | 全局 hooks 宿主范围 | 全部登记；只对交互会话推「等你回复」；exclude 列表（默认含 `~/.codex/memories`） | v0.4 补默认排除 |
| D10 | 「等你回复」推送时机 | 在场判定（3.5） | 已实现 |
| D11 | JSONL 尾读 | 取消；停滞改为 headless 无事件超时 | v0.4 新增 |
| D12 | 凭据存放 | `secrets/` 600 文件，不用 Keychain（ad-hoc 签名下 Keychain 每次升级弹框阻塞 daemon） | v0.4 新增，有 Developer ID 后可迁回 |
| D13 | Bonjour | 不做；候选地址含 `.local` 主机名 | v0.4 新增 |

## 修订记录

- **v0.1 → v0.2（2026-09-27，按评审）**：① 本地 API 全程 TLS（自签证书 + 配对时指纹 pinning），Bearer token 只在 TLS 上传输；② 配对主路径改二维码 + 高熵 secret，废除 6 位短码派生密钥（被动抓包即可离线枚举），深链兜底写明须经 AirDrop/iMessage 转发；③ Codex 接入改用 hooks 体系（`PermissionRequest` 等），弃用顶层 notify，写入 `/hooks` 内容哈希信任流程与稳定 shim 规避；④ 移除「判稳 90s」，交互回合结束立即推「等你回复」，「已完成」限定 headless；⑤ 停滞检测由 mtime 改为 kqueue 进程监听，kill -9 秒级感知；⑥ 明确 v1 单开发者自用（D8）；⑦ hook 通道改 Unix domain socket + spool 快速返回；⑧ 不复用 `AmberBackendBaseURL`，新增独立 `GatewayClient`；⑨ 心跳指标换内存压力 + 热状态；⑩ 新增「Mac 掉线不可推送」已知局限与缓解；⑪ 跨网推荐 Tailscale（D1 简化）；⑫ 静默推送降为尽力而为，不进验收；⑬ 事实修正：token 回调行号 456→499。
- **v0.2 → v0.3（2026-09-27，按第二轮评审）**：① 退出码仅子进程可得（`NOTE_EXITSTATUS` 限制）：`run` 包装任务用 `waitpid`，外部 headless 改为「先 `Stop`/`SessionEnd` 后退出」组合判定；② 会话进程改为沿进程树定位（跳过 `sh -c` 等中间层），登记键为 PID + 启动时间防复用；③ 新增多会话宿主规则：状态以 hook 为准，进程监听兜底；④ v1 不挂 `PreToolUse`/`PostToolUse`，活性改由 JSONL 提供；UDS 超时 2s → 200ms，hook 总耗时 P95 < 50ms；⑤ 新增 3.5 推送在场判定（D10），D9 收窄为只对交互会话推「等你回复」；⑥ 撤销「自动删除凭据原文件」（`.p8` 只能下载一次），改为用户确认后删除；开发期即固定签名身份，避免 Keychain 反复授权；⑦ 新增 `devices list/revoke`；⑧ 删除 shim：Codex 按 hook 定义哈希记录信任，与二进制内容无关；⑨ 标注 Codex plan 模式 `request_user_input` 可能无 hook 覆盖；⑩ 睡眠监听改 IOKit `IORegisterForSystemPower`，注明 `IOPMAssertion` 挡不住电池合盖睡眠；⑪ 二维码携带候选地址列表（含 Tailscale MagicDNS）；⑫ TLS 服务端实现路径（`NWListener` + `swift-certificates`）；⑬ iOS：补 time-sensitive entitlement 及其镜像/测试同步、推送仅 stable 构建、Live Activity 需 `pushType: .token`；⑭ 事实修正：openai/codex#19921 中维护者已表示顶层 `notify` 将被 hooks 取代，v0.2 的「废弃说法未获证实」撤回。
- **v0.3 → v0.4（2026-09-27，G1 实施后）**：① hook 事件补 `UserPromptSubmit`、`StopFailure`、`Interrupt` 与 Claude `PermissionRequest`；② Claude 原生安装按 `/claude/versions/` 路径识别（运行时证据）；③ 宿主只按启动参数判定，撤销「同 PID 多会话 = 宿主」（`codex exec` 内部记忆会话反例），`~/.codex/memories` 默认排除；④ 取消 JSONL 尾读，停滞改为 headless 无事件超时（D11）；⑤ 凭据改存 600 文件（D12）；⑥ TLS 证书改用系统 openssl 生成，取消 `swift-certificates`；pinning 对象改 SPKI SHA-256；⑦ 取消 Bonjour（D13）；⑧ iOS 配对主路径改为系统相机扫码直接唤起深链，Android / 鸿蒙 App 内扫码；⑨ install 复制二进制到固定位置；⑩ 鸿蒙确认为 ArkTS 工程，华为通道按 Push Kit v3（PS256 JWT）；⑪ D4 定为 v1 只做 FCM；⑫ Live Activity 移出 v1；⑬ G5 明确不在本轮范围。

- **v0.4 实施偏差（2026-09-27，G2–G4 落地与 review 后）**：① Android token 存 DataStore、鸿蒙存 KV 存储（原写 EncryptedSharedPreferences / Preferences）；② 鸿蒙网络栈用 RCP 而非 `http`，入口挂在设置 → 高级功能；③ Android / 鸿蒙均不接系统深链；④ 同一 push token 只保留在最新上报的设备记录上，避免重复配对后重复推送；⑤ `devices.json` 损坏时 API 返回 500、不覆盖文件（原会让所有手机收到 401 后自行解绑）；⑥ 推送请求 8s 超时、HTTPS 连接上限 20s、客户端读超时 25s，保证 test-push 慢时不被换地址重发；⑦ APNs `DeviceTokenNotForTopic` 视为 topic 配置错误，不删 token；⑧ `devices revoke` 前缀必须唯一；⑨ 失联判定简化为「连不上即失联」。
