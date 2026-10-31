# macOS Phase 4 · 跨端任务、审批与数据保留

日期：2026-10-31 · worktree `d104f2c37f52`，分支 `synara/amber-macos-context-safety`，基线 HEAD `e3837594`（未提交）。

## 出口条件对照（计划 §5 P4 & §9 C3 / C4 / C5）

| 计划要求 | 状态 | 证据 |
| :--- | :--- | :--- |
| **M4.1** 网关协议契约（C3/C4/C5）冻结并归档，覆盖配对、令牌、推送载荷、重连、多客户端、错误码、旧版客户端兼容 | **PASS** | [gateway-contract-c3.md](../../../architecture/gateway-contract-c3.md) + `gateway` `swift test` **64 / 64 通过**（10 个套件） |
| **M4.2** 审批风险矩阵：普通风险允许手机批准（`200`）；高风险（内置 + 插件 `sideEffect` / `idempotent` + `apple_schedule` + `feishu`）手机端只能拒绝（批准返回 `403`，拒绝返回 `200`）；过期/旧 run 审批返回 `409` 且不生效；审计记录含 `run` / `tool` / `toolCallId` / `decision` | **PASS** | `DesktopGatewayControlTests`（6 项）+ `DesktopPluginApprovalTests`（4 项）+ `GatewayAPITests`（13 项）+ `PushSenderTests`（8 项） |
| **M4.3** 看板真实性：生产环境绝不使用 fixture；`needsYou` / `running` / `scheduled` / `done` 四列与真实状态一致；过期孤儿会话（>24h）与已关闭会话（>7d）自动清理；通知/深链跳转与会话已删除降级提示 | **PASS** | `DesktopBoardTests`（5 项）+ `DesktopGatewayReporterTests`（5 项）+ `DesktopNotificationRoutingTests` + `RegistryTests` |
| **M4.4** 无人值守安全：定时任务审批策略按任务隔离、通知动作按钮、错过触发唤醒策略（`runOnce` / `skip`）、中断恢复失败回执 | **PASS（代码级）/ CONDITIONAL（硬件级）** | `RuntimeScheduledRunTests`（7 项）+ `DesktopSchedulerTests`（13 项）+ `DesktopScheduleNotificationTests`（7 项）；真实合盖睡眠唤醒与 `SMAppService` 登录项真实系统授权标记为 `CONDITIONAL` |
| **M4.5** 数据保留：压缩摘要只作为请求投影，永不覆盖原始 transcript；导出（`.json` / `.md` / `.pdf`）与备份（`.ambermacbackup`）包含完整原始记录且剥离 API Key；删除会话彻底清理会话文件、洞察、制品架置顶与受管文件，同时保留外部绑定目录 | **PASS** | `DesktopBackupTests`（14 项）+ `RuntimeBackupLifecycleTests`（1 项） |

---

## 实现与加固明细

### M4.1 网关协议契约（C3 / C4 / C5）

- 编写并冻结跨端网关协议契约文档 [docs/architecture/gateway-contract-c3.md](../../../architecture/gateway-contract-c3.md)，同步归档至 Hub Library（`library/gateway-contract-c3.md`），并在 [docs/architecture/mac-gateway.md](../../../architecture/mac-gateway.md) 顶部建立索引链接。
- 契约完整覆盖：
  - **C3 网关与远程审批**：配对票据（`/v1/pair`、120s 有效期、单次消费、提前 5s 过期缓冲）、Bearer 设备令牌、TLS SPKI SHA-256 指纹固定、`/v1/status`、`/v1/board`、`/v1/amber/decision`、`/v1/schedules/*`、`/v1/tasks/*`、`/v1/sessions/*`、重连快照对账、多客户端幂等冲突（首答 `200`、后答 `409`）、旧版客户端向后兼容（忽略未知字段、缺失 `answerKey` 时退化为只读/仅拒绝）。
  - **C4 无人值守推送载荷**：APNs（`category` 动态区分 `AMBER_PERMISSION` 与 `AMBER_HIGH_RISK`、`amber` 自定义字典含 `session` / `tool` / `highRisk` / `answerKey` / `eventId`）、FCM Android、HarmonyOS Push Kit 三端载荷映射与通知动作矩阵。
  - **C5 备份与导出数据保留**：`.ambermacbackup` 归档信封（PBKDF2-HMAC-SHA256 210,000 次迭代 + AES-GCM 256-bit）、密钥剥离约束、压缩不覆盖原文约束、副本式恢复不覆盖本地现有会话。
- 在 `gateway/Tests/GatewayTests/PushSenderTests.swift` 与 `GatewayAPITests.swift` 新增契约回归测试，消除 `DaemonAPI.swift` 与 `Registry.swift` 中的 `Date` 比较运算符（改用 `timeIntervalSince`）。

### M4.2 审批风险矩阵与审计闭环

- **风险分级**：`DesktopToolRegistry.isHighRisk` 统一判定内置高风险工具（`terminal_exec`、`workspace_artifact_delete`、`mcp_call_tool`、`interrupt_agent`）及所有 `effect == .sideEffect || effect == .idempotent` 的插件工具（含 `plugin__apple_schedule__create_event` / `update_event` / `delete_event` / `complete_reminder`、`plugin__feishu_calendar__create_event` / `bot_send_message` / `bot_create_doc` / `meeting_closeout` 及第三方 `sideEffect` 插件）。
- **双层拦截**：
  1. `amber-gateway` 守护进程层（`DaemonAPI.swift`）：当 `registry.sessions[key]?.highRisk == true && allow == true` 时直接返回 `403 high-risk approval requires Mac`。
  2. `AmberMac` 桌面控制套接字层（`DesktopGatewayControl.swift`）：即使绕过守护进程直连 `control.sock`，当 `allow && DesktopToolRegistry.isHighRisk(match.call.name)` 时同样返回 `rejected_high_risk`（映射为 `403`），绝不触发 `tasks.respond`。
- **过期与旧 Run 隔离**：`decide` 严格校验 `(taskID, runID, toolCallId)` 三元组；针对已结束的旧 `run` 或不匹配的 `toolCallId` 均返回 `stale`（映射为 `409 approval is no longer pending`），不会误放行同一任务的新一轮运行。
- **审计字段补齐**：
  - `gateway/Sources/amber-gateway/DaemonAPI.swift` 的 `amber-decision` 审计条目新增 `run` 与 `tool`（优先取 `registry.sessions[key]?.waitingTool`）及语义化 `decision`（`"allow"` / `"deny"`）。
  - `macApp/AmberMac/Runtime/DesktopGatewayControl.swift` 新增 `amber-decision-result` 审计写入，将桌面端真实执行结果（`outcome`: `approved` / `denied` / `rejected_high_risk` / `stale`）连同 `task`、`run`、`tool`、`toolCallId`、`allow`、`decision`、`device` 一并落盘到 `audit.jsonl`。

### M4.3 看板真实性与陈旧会话清理

- **零 Fixture 保证**：生产入口 `DesktopLiveWorkspace` 的看板数据源由 `DesktopBoard.build(tasks:runs:gateway:now:)` 从真实 `scheduled-tasks.json` 与网关 `registry.json` 构建；`DesktopBoard.fixture()` 仅在 `AMBER_UI_FIXTURE=1` 快照进程中使用。
- **孤儿会话防呆过滤**：在 `DesktopBoard.build` 中新增 `orphanWindow = 24 * 3600` 守卫——即使网关守护进程尚未运行 `prune()`，磁盘 `registry.json` 中超过 24 小时未更新且无关联存活 PID 的未关闭孤儿会话也不会进入 `needsYou` 或 `running` 列；而带存活进程跟踪的会话继续保留。
- **通知与深链跳转**：`DesktopNotificationRouter` 针对存在会话切回聊天并定位会话，针对已删除会话切回聊天并展示可理解提示「该通知对应的对话已被删除。」。

### M4.4 无人值守安全

- **代码与单测已验证**：
  - 定时任务审批策略按任务隔离（`DesktopApprovalPolicy`），非白名单工具仅在无人值守运行中自动拒绝或等待审批（`RuntimeScheduledRunTests`）。
  - 普通审批通知挂载批准/拒绝按钮，高风险审批通知不挂载批准按钮且忽略伪造的批准回调（`DesktopScheduleNotificationTests`）。
  - 睡眠/离线期间错过多次触发时按 `missedRunPolicy`（`.runOnce` 补跑一次 / `.skip` 记录跳过）处理，应用退出中断的运行在重启时标记为 `failed` 并写入可检索错误原因（`DesktopSchedulerTests`）。
- **硬件与系统级未验证项（标记为 `CONDITIONAL`）**：
  - 真实物理合盖睡眠与唤醒（Clamshell Sleep / Wake）下的系统时钟跳变与网络恢复时序。
  - macOS 系统设置中 `SMAppService.mainApp` 登录项的真实系统弹窗与用户批准流程。
  - 真实 APNs / FCM / HarmonyOS Push Kit 远端推送网关在真机锁屏状态下的到达延迟与回执。

### M4.5 数据保留、导出、备份与删除清理

- **压缩不毁原文**：`DesktopConversationInsights.prepare(messages:conversationID:)` 仅在构造模型请求时将压缩检查点投影为前缀消息；`DesktopConversation.messages` 原始数组在内存、磁盘 JSON、三种导出格式（`.json` / `.md` / `.pdf`）与 `.ambermacbackup` 备份归档中始终完整保留。
- **备份剥离凭证**：`DesktopBackupCoordinator.snapshot` 仅导出 `DesktopProviderConfiguration` 元数据（不含 Keychain 中的 API Key），恢复时导入为新副本并提示「配置不含密钥，请在设置中填写后使用」。
- **删除清理边界**：`deleteConversation` 同步清理会话存储文件、`insights` 记录、`artifactShelf` 置顶片段及应用受管工作区目录（`WorkspaceFiles/<conversationID>`），但绝不删除用户绑定的外部文件夹（`workspaceFolderPath`）。

---

## 命令与测试计数

| 命令 | 结果 |
| :--- | :--- |
| `cd gateway && swift test` | **64 / 64 通过**（10 个测试套件，0 失败） |
| `./macApp/scripts/test-runtime.sh -j 6 --filter "DesktopGatewayControlTests\|DesktopBoardTests\|DesktopGatewayReporterTests\|DesktopScheduleNotificationTests\|RuntimeScheduledRunTests\|DesktopSchedulerTests\|DesktopBackupTests\|RuntimeBackupLifecycleTests"` | **58 / 58 通过**（0 失败） |
| **阶段末全量** `./macApp/scripts/test-runtime.sh -j 6` | **502 项通过，2 跳过，0 失败**（耗时 12.09s；P3 结束时为 485 项） |

---

## 截图说明

- 本阶段（Phase 4）全部改动位于 `gateway/` 与 `macApp/AmberMac/Runtime/`、`macApp/AmberMacTests/` 及契约文档，**未修改任何 UI 视图文件（`macApp/AmberMac/UI/*`）**。
- 遵循阶段审查规范（`2026-10-31-phase-review.md`：「只截本阶段改动的界面，未改动的页面禁止重截」），本阶段不重截未改动的 UI 页面。

---

## 交接要点

1. **C3/C4/C5 契约已冻结**：手机端（iOS / Android / 鸿蒙）可直接依据工作树内的 [docs/architecture/gateway-contract-c3.md](../../../architecture/gateway-contract-c3.md) 或 Hub Library 归档副本 `/Users/arquiel/.synara/userdata/project-context/0f3f2134-3ef9-4137-8b75-6d1496ff94d1/library/gateway-contract-c3.md` 对接网关状态、看板、远程审批、APNs/FCM/PushKit 载荷及备份格式。
2. **审计日志双记录**：`audit.jsonl` 现同时包含守护进程收到的 `amber-decision` 请求与桌面端实际执行的 `amber-decision-result` 结果，字段均含 `task`、`run`、`tool`、`toolCallId`、`allow`、`decision`（`allow`/`deny`）与 `outcome`（`approved`/`denied`/`rejected_high_risk`/`stale`）。
3. **Xcode 27 `Date` 比较陷阱已全面清除**：本轮把 `gateway/` 与 `macApp/AmberMac/Runtime/`、`macApp/AmberMacTests/` 中残余的 `Date < Date` / `Date > Date` 全部替换为 `timeIntervalSince`，全量 502 项测试现在可在 12 秒内稳定跑完。后续新增代码请继续使用 `timeIntervalSince`。
4. **工作树状态**：所有改动均保留在 `/Users/arquiel/.synara/worktrees/d104f2c37f52`（未提交、未推送），P1–P3 及更早的 UI 未提交改动均完好保留。
