# Mac Gateway 并入 Amber 桌面版 + 主动性第 2–4 步 实施计划

日期：2026-10-27 · 分支：`feat/macos` · 前置：定时任务 S1–S6（28323d0…149b8b4）

## 目标

1. **合并**：`amber-gateway`（原独立仓库 soul99soul-glitch/amber-gateway@13d03c2）搬进本仓 `gateway/`，随 Amber.app 打包，在 Amber 设置里一键启用和管理，不再需要终端 `install`/`pair`/`creds`。
2. **主动性第 2 步**：定时任务的开始、等待批准、完成和失败经网关推到手机。
3. **主动性第 3 步**：在手机上批准或拒绝定时任务的工具调用：App 内按钮，加上锁屏通知上的操作按钮。
4. **主动性第 4 步**：在手机上查看、开关、立即运行、新建定时任务。
5. **定时任务 S7**：在对话里让模型起草定时任务（`schedule_*` 工具），永远需要用户批准。

验收主线：Mac 上建「每天 9:00 汇总」任务，关掉窗口。到点后任务运行，碰到要批准的工具时，手机 Amber 的 Mac Gateway 页出现这次调用（工具名和参数摘要），点「批准」后 Mac 上的任务继续，结束时手机收到「已完成」。手机上还能新建、开关、立即运行任务。

## 现状（已读代码确认）

- 网关：SwiftPM 包，约 5000 行，51 项测试全绿。模块有 `GatewayCore`（模型、状态机、注册表、推送决策、hooks 合并、存储）、`HookIngest`、`SessionWatch`、`GatewayTransport`（UDS、HTTPS、配对、TLS）、`GatewayPush`（APNs、FCM、华为），加上可执行文件 `amber-gateway`。状态目录 `~/Library/Application Support/AmberAgent/Gateway`。部署方式是 `install` 把二进制复制到 `~/.local/share/amber-gateway/bin`，软链 `~/.local/bin/amber-gateway`，再写 `~/Library/LaunchAgents/com.amberagent.gateway.plist`。
- 本机未装网关。Mac mini 上有 CLI 方式的部署，CLI 路径必须继续可用。
- iOS 已有 Mac Gateway 客户端（`MacGatewayClient/Store/SettingsView`，在设置 › Mac Gateway）：配对、SPKI pinning、状态、监控开关、APNs token 上报、测试推送。
- Amber 定时任务：`DesktopScheduler`（S3）、`runScheduled`（S2）、`DesktopAgentTasks.unattendedConversations` 和 `decideFromNotification`（S5，高风险不接受远程批准）。
- 本仓 AGENTS.md 规定不得读写兄弟产品仓库，所以 Android/鸿蒙客户端不在本轮范围：它们照常收到通用推送，Amber 任务在列表里显示为普通任务。

## 设计

### 1. 代码归属与打包

- `gateway/` 原样导入（保留 `Package.swift`、Sources、Tests、README），把 `GatewayCore`、`GatewayTransport`、`GatewayPush`、`HookIngest` 暴露为 library product。`swift test --package-path gateway` 照常可用，`macApp/scripts/build.sh test` 一并执行它。
- `macApp/project.yml`：
  - 新增本地 package `AmberGateway`（path `../gateway`）。
  - 新增 `tool` 目标 `amber-gateway`，源码为 `../gateway/Sources/amber-gateway`，依赖上述 4 个库加 `SessionWatch`，以依赖形式嵌入 `Amber.app/Contents/MacOS/`。
  - LaunchAgent plist `app.amber.macos.gateway.plist`（`BundleProgram: Contents/MacOS/amber-gateway`，参数 `daemon`，`KeepAlive`）复制到 `Contents/Library/LaunchAgents/`。
- `build.sh` 重签名时，嵌入的 `amber-gateway` 用与 App 相同的身份签名，并开启 hardened runtime。
- CLI 独立部署路径不变，Mac mini 照用。安装、卸载逻辑从可执行目标下沉到 `GatewayCore.GatewayInstallation`，CLI 和 Amber 共用。

### 2. Amber 内置启用（`DesktopGateway`）

- **启用**：
  1. 迁移旧 CLI 部署：bootout `com.amberagent.gateway`，删除其 plist 和 `~/.local/share/amber-gateway` 副本。
  2. `~/.local/bin/amber-gateway` 软链指向 App 包内二进制。
  3. 合并 Claude/Codex hooks（hook 命令字符串不变，Codex 已有的信任保留）。
  4. `SMAppService.agent(plistName:)` 注册。
- **停用**：反注册，移除 hooks 和软链，保留状态目录（含设备与凭据）。
- **每次启动**：如果已启用而软链指向别处（App 被移动过），重新指向当前 App 包。
- **设置页「Mac Gateway」**：
  - 开关，加上状态（运行中 / 需要在系统设置允许 / 未运行）。
  - 「配对手机」：二维码 sheet，5 分钟倒计时，配对成功后自动关闭。
  - 已配对设备列表和吊销。
  - 推送凭据导入：APNs 选 .p8 并填 Key ID / Team ID / Bundle ID；FCM、华为选 JSON。
  - 测试推送。
  - Codex `/hooks` 信任提示。
- 实现方式：直接链接 `GatewayCore/Transport/Push` 读写状态目录。这和 CLI 的做法一致，设备表本来就有 flock，配对票据和凭据都是 600 文件。

### 3. 定时任务进网关（第 2 步）

- **新增 `AgentKind.amber`**：一次定时运行 = 一个网关会话，key `amber:<运行记录 id>`，标题为任务名，origin `headless`，process 为 Amber 进程身份。Amber 崩溃时，kqueue 把会话置为「意外中断」。
- **事件经现有 hook UDS 和 spool 投递**（网关没运行时先落盘）：

  | 时机 | 事件 |
  | --- | --- |
  | 调度器开始运行 | `runStart` |
  | 进入审批 | `permissionRequest`，带 `tool`、`toolCallId`、`detail`（参数摘要 ≤120 字）、`highRisk` |
  | 做出决定 | `toolDone` |
  | 结束 | `runExit`（完成 0，其余 1） |

- **注册表规则**：`.amber` 的「等你确认」推送不受 D9 只推交互会话的限制，但照样受在场判定约束（人在 Mac 前就不推手机，Mac 本地已有通知）。`.amber` 不做 headless 停滞判定，因为它的结束一定会被观察到。失败的文案为「未完成」。
- **推送正文仍只含元信息**（任务名、状态、工具名）。参数摘要只放在 TLS 的 `/v1/status` 里，不进推送。
  - APNs 对非高风险的 Amber 审批推送加 `category: amber.gateway.approval` 和 `sessionKey`、`toolCallId`。
  - 所有 Amber 推送都带 `deepLink: amber://settings/mac-gateway`。
- **iOS**：任务行显示 Amber 任务（时钟图标），等待批准时展开工具名和参数摘要。

### 4. 手机批准（第 3 步）

- **Amber 本地通道**：启用网关且 Amber 运行时，Amber 在状态目录监听 `amber-app.sock`（600），协议为一请求一响应 JSON，复用 `GatewayTransport` 的 UDS 实现，扩展为可带响应。
- **网关新 API**（Bearer 鉴权，写 `audit.jsonl`）：`POST /v1/amber/decision {sessionKey, toolCallId, allow}`。网关在 daemon 队列外转发给 Amber；Amber 没运行时返回 503「Amber 未运行」。
- **Amber 侧**：按 sessionKey 找到对应定时运行的会话，校验待审批调用的 id，走 `decideFromNotification`，高风险一律拒绝批准。
- **iOS**：
  - App 内：等待行显示「拒绝」「批准」；高风险只显示「拒绝」，并提示「高风险，请在 Mac 上核对后批准」。
  - 通知：注册 `amber.gateway.approval` 类别（拒绝、批准，批准需要解锁），点按钮直接调用 decision API。

### 5. 手机管理定时任务（第 4 步）

- **网关 API**（全部转发给 Amber 本地通道）：
  - `GET /v1/amber/schedules`
  - `POST /v1/amber/schedules`
  - `POST /v1/amber/schedules/{id}/enabled`
  - `POST /v1/amber/schedules/{id}/run`
- **手机新建的任务只能设名称、提示词、时间规则**，审批策略固定为默认（不自动批准）。手机端不能修改任何任务的审批设置：一台被盗的手机不应能把任务改成自动执行终端命令。
- **iOS**：Mac Gateway 页新增「定时任务」分组，含列表（下次运行、上次结果、开关、立即运行）和新建 sheet（名称、提示词、规则）。

### 6. 对话内创建定时任务（S7）

- 新增 3 个工具：
  - `schedule_list`：只读，无需批准。
  - `schedule_create`：永远需要批准，不受任何自动批准策略影响，审批卡片完整显示任务定义。
  - `schedule_update`：同 `schedule_create`。
- 模型可设名称、提示词、规则、工具开关、结果去向；**不能设置审批策略**，新建任务的审批一律为默认。
- 定时任务自己的运行里不暴露 `schedule_*`，避免任务自我复制。

## 实施顺序

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| P1 | gateway 进仓库、库化、随 Amber.app 打包、安装逻辑下沉 | gateway `swift test` 全绿；Mac 全量测试全绿；`Amber.app/Contents/MacOS/amber-gateway` 和 LaunchAgent plist 存在且签名有效；CLI `install --dry-run` 行为不变 |
| P2 | Amber 内置启用与管理 | 单测（安装、迁移、软链修复）；实测：设置页启用 → `launchctl` 可见 agent 在运行 → 生成二维码 → iOS 模拟器扫码配对成功 → 设备出现在列表 → 吊销后模拟器提示失效；浅色、深色截图 |
| P3 | 定时任务事件进网关 | gateway 单测（amber 规则、推送载荷、status 字段）；Amber 单测（事件序列）；实测：Mac 跑一次定时任务，模拟器列表出现该任务及状态变化 |
| P4 | 手机批准 | gateway API 集成测试（假 Amber socket）、Amber 通道单测（高风险拒绝、过期 id 拒绝）；实测：模拟器上点「批准」，Mac 上的任务继续并完成 |
| P5 | 手机管理定时任务 | API 与通道单测；实测：模拟器新建、开关、立即运行，Mac 列表同步 |
| P6 | `schedule_*` 工具 | 单测：create/update 永远需要批准、定时运行内不暴露、不能设置审批策略；fake provider 端到端 |

每个阶段：跑全量测试（Mac `build.sh test`，含 gateway；涉及 iOS 时加 iOS 受影响测试和编译）→ subagent review（逻辑闭环、调用链路、UI 细节）→ 精准修复 → 单独提交。

## 不在本轮范围

- Android/鸿蒙客户端（独立仓库，本仓规定不得改动）。
- 推送中继、多用户分发（设计文档 D8：单开发者自用）。
- 由记忆驱动的任务建议：没有足够明确的产品定义，不做。
- 模型迁入 KMP：手机经网关远程管理后，已没有这个必要。
- 真实推送送达：需要 APNs `.p8`，以请求构造单测加 outbox 验证，真机送达列为用户执行项。

## 实施结果（2026-10-27）

P1–P6 全部完成，提交 d027e6c、c599d02、89fdb68、40f3be7（P4 与 P5 改动交织在相同文件里，合并为一次提交）、9796954。每个阶段都跑了全量测试，并经 subagent review 后修复。最终结果：gateway 60 项全绿；Mac 394 项，其中 369 项通过、0 失败、25 项跳过（外部账号、基准测试和需要手动配合的真机用例默认跳过）；iOS 的 MacGatewayTests 与 IOSAppDeepLinkTests 共 14 项全绿。

本机实测：
- Amber 设置页启用后，SMAppService 注册了 `app.amber.macos.gateway`，launchd 显示在运行。
- iOS 模拟器通过 `amber://` 深链完成配对，上报了 sandbox 推送 token。
- 一次真实的定时运行在网关中以 amber 会话出现，状态从 waiting 变为 completed。
- 在模拟器上点「批准」后，Mac 上的定时运行继续执行并写出了文件。
- 在模拟器上，定时任务列表、立即运行、停用、新建每周任务都经真实 daemon 生效。

和设计的偏差：
- **APNs 默认 Bundle ID**：iOS 实际为 `app.amber.ios`。
- **控制通道**：Amber 一直监听 `amber-app.sock`，启用网关后不需要重启 Amber。
- **忙时应答**：Amber 忙时回 504「Mac 正忙」，不让 daemon 误报「Amber 未运行」。
- **对话里修改任务**：开启了无人值守自动批准的任务，不能在对话里通过 `schedule_update` 修改。
- **间隔上限**：间隔规则加了 7 天上限，防止远程请求触发日期计算溢出。

需要用户执行的项：
- **推送凭据与真机送达**：导入 APNs `.p8`，在真机上验证锁屏送达和通知上的「批准」按钮。
- **Codex hooks**：在 Codex `/hooks` 中信任 gateway 的 hook。
- **Mac mini**：原有 CLI 部署照常使用；如果改用 Amber 内置的网关，在 Amber 中启用时会自动迁移。
