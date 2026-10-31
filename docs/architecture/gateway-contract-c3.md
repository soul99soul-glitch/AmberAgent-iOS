# Amber 跨端契约规范：C3 Gateway 协议、C4 数据保留与 C5 任务看板

- 状态：**FROZEN（Phase 4 M4.1 冻结）**
- 适用端：macOS（`amber-gateway` + `AmberMac`）、iOS（`AmberAgent`）、Android（`AmberAndroid`）、HarmonyOS（`AmberHarmony`）
- 关联计划：`library/amber-four-platform-phase-plan.md` §5 Phase 4（M4.1–M4.5）与 §9 跨端契约（C3 / C4 / C5）

---

## 1. 传输、编码与证书固定（Transport & Pinning）

1. **传输层**：所有手机到 Mac Gateway 的请求均走 HTTPS（TLS 1.2/1.3），默认监听 `0.0.0.0:47821`（可由 `config.json` 的 `port` 配置）。
2. **证书固定（SPKI Pinning）**：
   - Gateway 在首次启动时生成自签名 EC P-256 证书（保存在 `tls-identity.p12`，权限 `0600`）。
   - 客户端**严禁**依赖系统 CA 信任链放行自签名证书，必须提取服务端叶子证书的 `SubjectPublicKeyInfo`（P-256 DER 前缀 `3059301306072a8648ce3d020106082a8648ce3d030107034200` + 65 字节未压缩公钥点），计算 `SHA-256` 并编码为标准 Base64，与配对载荷中的 `fp` 严格比对。
   - 若 `fp` 不匹配，客户端必须立即取消 TLS 握手并提示证书变更（需取消配对后重新扫码）。
3. **JSON 与时间编码**：
   - 请求与响应体均为 UTF-8 JSON（`Content-Type: application/json`）。
   - 所有时间戳（`Date`）在 JSON 中统一使用 **Unix Epoch 秒数**（`secondsSince1970`，数值类型，支持整数或浮点数）。
4. **候选地址重连顺序（`addrs`）**：
   - Gateway 生成配对载荷时按以下顺序排列 `addrs`：
     1. `<LocalHostName>.local`（mDNS，跟随局域网 DHCP 变化）
     2. Tailscale MagicDNS 域名（若本机已安装并登录 Tailscale）
     3. `config.json` 中配置的 `publicAddresses`（公网/DDNS/Frp 地址）
     4. 本机非回环、非 `169.254.*` 的 IPv4 地址
   - 客户端请求时优先尝试上次成功的 `preferredAddress`，失败后按 `addrs` 顺序依次回退。

---

## 2. 配对与鉴权契约（Pairing & Bearer Token）

### 2.1 配对二维码与深链（`amber://gateway/pair`）

- 完整深链格式：`amber://gateway/pair?p=<base64url_no_padding(JSON)>`
- 客户端解析器须同时支持完整 URL（含前后空白）或裸 `p` 参数值，最大允许长度 `4096` 字符。
- 解码后的 JSON 结构（`PairingPayload`）：

```json
{
  "v": 1,
  "id": "8b7d4e20-1234-4abc-9def-0123456789ab",
  "name": "渡光的MacBook Pro",
  "addrs": [
    "duguangdeMacBook-Pro.local",
    "mac.tail1234.ts.net",
    "gw.example.com",
    "192.168.1.10"
  ],
  "port": 47821,
  "fp": "base64_sha256_of_spki",
  "s": "base64url_one_time_secret"
}
```

| 字段 | 类型 | 必填 | 约束与语义 |
| --- | --- | --- | --- |
| `v` | `Int` | 是 | 协议版本，当前固定为 `1`（非 `1` 客户端须拒绝） |
| `id` | `String` | 是 | Gateway 实例持久 UUID（小写） |
| `name` | `String` | 是 | Mac 主机显示名称 |
| `addrs` | `[String]` | 是 | 候选连接地址列表，至少 1 项 |
| `port` | `Int` | 是 | HTTPS 端口，`1...65535` |
| `fp` | `String` | 是 | 服务端证书 SPKI 的 SHA-256 Base64 指纹 |
| `s` | `String` | 是 | 一次性配对密钥（有效期 5 分钟，单次使用即销毁） |

### 2.2 `POST /v1/pair`（无需 Bearer Token）

- **请求体**：
  ```json
  {
    "secret": "base64url_one_time_secret",
    "platform": "ios",
    "deviceName": "渡光的 iPhone"
  }
  ```
  - `secret`（必填，`String`）：配对载荷中的 `s`。
  - `platform`（必填，`String`）：枚举值 `"ios"` | `"android"` | `"harmony"`。
  - `deviceName`（可选，`String`）：设备名称，服务端截断至最多 64 字符；旧版客户端省略时默认回退为 `platform` 字符串。
- **成功响应 `200 OK`**：
  ```json
  {
    "deviceId": "d290f1ee-6c54-4b01-90e6-d701748f0851",
    "token": "base64url_32_bytes_bearer_token",
    "gatewayId": "8b7d4e20-1234-4abc-9def-0123456789ab",
    "gatewayName": "渡光的MacBook Pro"
  }
  ```
- **安全不变量**：
  - 配对票据（`pairing.json`）在验证通过后**立即删除**，同一 `secret` 第二次调用必返回 `403`。
  - 服务端 `devices.json` **只持久化 `tokenHash = sha256_hex(token)`**，绝不落盘明文 `token`。
- **错误码**：
  - `400`：缺少 `secret` 或 `platform` 不在 `ios / android / harmony` 之中。
  - `403`：配对码错误、已过期（> 5 分钟）或已被使用。
  - `500`：`devices.json` 写入失败。

### 2.3 Bearer Token 鉴权与 `POST /v1/unpair`

- 除 `POST /v1/pair` 外，所有 `/v1/*` 接口必须携带请求头：
  `Authorization: Bearer <token>`
- **鉴权状态码语义**：
  - `401 {"error": "unauthorized"}`：缺少 Token、Token 不匹配或设备已被 Mac 端吊销（`amber-gateway devices revoke`）。客户端收到 `401` 时应将本地配对状态标记为已吊销/需重新配对。
  - `500 {"error": "devices.json 无法解析: ..."}`：服务端设备存储文件损坏。**客户端收到 `500` 时严禁自动清除本地配对或 Token**，以免因服务端可修复的文件故障导致所有手机掉线。
- **`POST /v1/unpair`**：
  - 请求体：`{}`
  - 响应：`200 {}`，服务端从 `devices.json` 移除当前设备并记录 `unpair` 审计事件；此后该 Token 立即失效（返回 `401`）。

---

## 3. 状态查询、会话模型与审批风险矩阵（Status & M4.2 Approval Matrix）

### 3.1 `GET /v1/status`

- **成功响应 `200 OK`**：
  ```json
  {
    "gateway": {
      "id": "8b7d4e20-1234-4abc-9def-0123456789ab",
      "name": "渡光的MacBook Pro"
    },
    "device": {
      "id": "d290f1ee-6c54-4b01-90e6-d701748f0851",
      "name": "渡光的 iPhone",
      "pushRegistered": true
    },
    "serverTime": 1793445600,
    "health": {
      "sampledAt": 1793445590,
      "diskFreeBytes": 64424509440,
      "batteryPercent": 85,
      "onBattery": false,
      "memoryPressure": "normal",
      "thermal": "nominal"
    },
    "synaraURL": "https://synara.example.com",
    "sessions": [
      {
        "key": "amber:3b9d7a10-0000-4000-8000-000000000001",
        "agent": "amber",
        "subject": "每日汇总",
        "summary": "每日汇总",
        "origin": "headless",
        "host": null,
        "state": "waiting",
        "waitReason": "permission",
        "abnormal": false,
        "monitored": true,
        "updatedAt": 1793445595,
        "pendingApproval": {
          "toolCallId": "call-1",
          "tool": "workspace_file_write",
          "detail": "{ \"path\": \"notes/daily.md\" }",
          "highRisk": false
        }
      }
    ]
  }
  ```

- **字段规范**：
  - `sessions` 最多返回 `50` 条（`statusSessionLimit = 50`），按 `(isOpen ? 1 : 0, updatedAt)` 降序排列。
  - `agent`：`"claude"` | `"codex"` | `"run"` | `"amber"`。
  - `origin`：`"interactive"` | `"headless"` | `"host"`。
  - `state`：`"running"` | `"waiting"` | `"stalled"` | `"completed"` | `"stopped"`。
  - `waitReason`（可选）：`"turnEnd"` | `"permission"`。
  - `pendingApproval`（可选）：仅当 `agent == "amber" && state == "waiting" && waitReason == "permission"` 且存在挂起工具调用时返回。

### 3.2 `POST /v1/amber/decision` 与审批风险矩阵（M4.2）

- **请求体**：
  ```json
  {
    "sessionKey": "amber:3b9d7a10-0000-4000-8000-000000000001",
    "toolCallId": "call-1",
    "allow": true
  }
  ```
- **校验与风险矩阵（强制契约）**：

| 场景 | 工具风险等级（`highRisk`） | 手机端请求 `allow` | HTTP 状态码 | 行为与结果 |
| --- | --- | --- | --- | --- |
| 普通风险工具批准 | `false`（如 `workspace_file_write`、`memory_tool`、`subagent_dispatch`、`model_council_run`、`skill_enable`、`skill_disable`） | `true` | `200` | 立即批准该 `toolCallId`，任务恢复 `running`，`pendingApproval` 清空 |
| 普通风险工具拒绝 | `false` | `false` | `200` | 立即拒绝该 `toolCallId`，工具返回拒绝结果，任务继续后续处理 |
| 高风险工具尝试在手机批准 | `true`（`terminal_exec`、`workspace_artifact_delete`、`mcp_call_tool`、`interrupt_agent` 及所有 `sideEffect`/`idempotent` 插件工具如 `plugin__apple_schedule__*` 写入、`plugin__feishu_*` 写入） | `true` | `403` | **拒绝执行**，返回 `{"error": "高风险操作只能在 Mac 上核对后批准"}`，任务保持 `waiting` |
| 高风险工具在手机拒绝 | `true` | `false` | `200` | 允许在手机端直接拒绝，工具调用被取消/拒绝，任务恢复推进 |
| 过期、已结束、旧 run 或重复提交 | 任意 | `true` / `false` | `409` | 返回 `{"error": "这次审批已经结束"}`，**绝不作用于任何当前或新启动的 run** |
| 非 `amber:` 会话或参数缺失 | 任意 | 任意 | `400` | 返回 `{"error": "需要 sessionKey、toolCallId 与 allow"}` |
| Mac 端 Amber 应用未启动 | 任意 | 任意 | `503` | 返回 `{"error": "Amber 未运行：在 Mac 上打开 Amber 后重试"}` |
| Mac 端主线程响应超时（> 4.5s） | 任意 | 任意 | `504` | 返回 `{"error": "Mac 正忙，请稍后刷新查看结果"}` |

- **审计日志契约（`audit.jsonl`）**：
  - 每次审批请求在 `audit.jsonl` 中必须记录：
    - `action`: `"amber-decision"`（网关收到请求）与 `"amber-decision-result"`（Amber 应用裁决结果）
    - `run`: 运行标识（去掉 `amber:` 前缀的 session/run ID 或 agent run UUID）
    - `task`: 完整 `sessionKey`（`amber:<runId>`）
    - `tool`: 工具名称（如 `"workspace_file_write"`、`"terminal_exec"`）
    - `toolCallId`: 工具调用 ID（如 `"call-1"`）
    - `decision`: `"allow"` 或 `"deny"`（布尔字段 `allow`: `"true"` / `"false"` 同步保留）
    - `outcome`: `"approved"` | `"denied"` | `"rejected_high_risk"` | `"stale"`
    - `device`: 发起请求的设备 ID / 名称

---

## 4. 推送 Token 注册与多通道推送载荷契约（Push Contract）

### 4.1 `POST /v1/push-token` 与 `POST /v1/test-push`

- **`POST /v1/push-token` 请求体**：
  ```json
  {
    "token": "apns_or_fcm_or_hms_token",
    "platform": "ios",
    "environment": "sandbox"
  }
  ```
  - `token`：必填，非空 ASCII 字符串，长度 `1...4096`，仅允许字母、数字及 `:_-.+/=`。
  - `environment`：当配对设备 `platform == "ios"` 时必填 `"sandbox"` 或 `"production"`（缺失返回 `400`）；`android` 与 `harmony` 可省略。
  - **去重契约**：同一台手机重新配对后再次上报相同 `pushToken` 时，服务端自动清空旧设备记录上的同名 `pushToken`，保证每台物理设备对同一事件只收到一次推送。
- **`POST /v1/test-push`**：
  - 若设备尚未上报 `pushToken`，返回 `409 {"error": "设备尚未上报推送 token"}`。
  - 推送成功返回 `200 {"delivered": true}`；上游通道拒绝或凭证缺失返回 `502 {"error": "..."}`。

### 4.2 锁屏隐私硬约束与推送载荷（APNs / FCM / Huawei）

- **隐私硬约束**：任何推送通知的 `title`、`body` 与自定义字段中**严禁包含对话正文、提示词、代码片段或工具参数**（`detail` 只在 TLS 加密的 `/v1/status` 与 `/v1/amber/board` 中传输）。
- **APNs（iOS）载荷规范**：
  ```json
  {
    "aps": {
      "alert": {
        "title": "Amber 定时任务 · 每日汇总",
        "body": "等你确认"
      },
      "sound": "default",
      "thread-id": "amber:3b9d7a10-0000-4000-8000-000000000001",
      "interruption-level": "time-sensitive",
      "category": "amber.gateway.approval"
    },
    "deepLink": "amber://settings/mac-gateway",
    "sessionKey": "amber:3b9d7a10-0000-4000-8000-000000000001",
    "toolCallId": "call-1"
  }
  ```
  - **普通风险审批（`highRisk == false`）**：
    - `aps.category = "amber.gateway.approval"`（iOS 客户端展示「批准 / 拒绝」快捷操作）
    - 顶层携带 `deepLink = "amber://settings/mac-gateway"`、`sessionKey`、`toolCallId`
  - **高风险审批（`highRisk == true`）**：
    - `aps.alert.body = "等你确认（高风险，请在 Mac 上核对）"`
    - **不携带** `aps.category`，**不携带** `toolCallId`（从载荷层杜绝锁屏直接批准高风险调用）
    - 顶层仅携带 `deepLink = "amber://settings/mac-gateway"` 与 `sessionKey`
- **FCM v1（Android）与 Huawei Push Kit v3（HarmonyOS）**：
  - 使用与 APNs 完全一致的 `PushContent.render` 标题和正文，以及相同的 `PushMessage.userInfo`（`deepLink`、`sessionKey`，仅普通风险含 `toolCallId`）。

---

## 5. 任务看板契约（C5 Task Board）与远程定时任务接口

### 5.1 `GET /v1/amber/board`（C5 统一看板状态模型）

- **成功响应 `200 OK`**：
  ```json
  {
    "board": [
      {
        "id": "run:7c9e6679-7425-40de-944b-e07fc1f90ae7",
        "kind": "run",
        "column": "needsYou",
        "title": "每日汇总",
        "detail": "等你确认 · workspace_file_write",
        "updatedAt": 1793445595,
        "scheduleId": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
        "conversationId": "a1b2c3d4-0000-4000-8000-000000000000",
        "nextRunAt": null,
        "waitingForReply": false,
        "failed": false,
        "approval": {
          "sessionKey": "amber:3b9d7a10-0000-4000-8000-000000000001",
          "toolCallId": "call-1",
          "tool": "workspace_file_write",
          "detail": "{ \"path\": \"notes/daily.md\" }",
          "highRisk": false
        }
      }
    ]
  }
  ```

- **看板四列与派生规则（M4.3 看板真实性）**：
  1. `needsYou`（等你处理）：
     - 正在等待工具审批的定时任务运行（`kind = "run"`，含 `approval`）；
     - 处于 `waiting` 状态的 Claude Code / Codex 会话（`kind = "agentSession"`，`waitingForReply = (waitReason != .permission)`）。
  2. `running`（运行中）：
     - 正在执行且无挂起审批的定时任务运行（`kind = "run"`）；
     - 处于 `running` 或 `stalled` 状态的 Claude Code / Codex 会话（`kind = "agentSession"`）。
  3. `scheduled`（已计划）：
     - 已启用（`enabled == true`）且当前未在运行的定时任务（`kind = "schedule"`）；若全局暂停则 `nextRunAt = null` 且 `detail` 附加 `" · 已暂停"`。
  4. `done`（近期完成）：
     - 7 天窗口内（`doneWindow = 7 * 86400s`）已完成或失败的定时任务运行（每个定时任务最多保留最近 3 条 `runsPerTask = 3`，`skipped` 状态不进看板）；
     - 7 天窗口内 `completed` 或 `stopped` 的 Claude Code / Codex 会话（`failed = rec.abnormal`）。
- **过期清理与排序规则**：
  - 无进程绑定（`process == nil`）且超过 24 小时未更新的孤儿开放会话（`orphanTimeout = 24 * 3600s`）自动清理，不出现在 `needsYou` 或 `running`。
  - 排序固定在 Mac 端完成：按列顺序 `needsYou` → `running` → `scheduled` → `done`；`scheduled` 列内按 `nextRunAt` 升序（最近触发优先），其余列按 `updatedAt` 降序（最新动态优先）。

### 5.2 远程定时任务管理与监控开关

- `GET /v1/amber/schedules` → `200 {"schedules": [ScheduleSummary]}`
- `POST /v1/amber/schedules` → 创建定时任务：
  - 请求体：`{"name": String, "prompt": String, "rule": "once"|"daily"|"weekdays"|"weekly"|"interval", "hour"?: Int, "minute"?: Int, "weekdays"?: [Int], "intervalMinutes"?: Int, "at"?: Number}`
  - **安全边界**：远程创建的任务始终使用默认无人值守策略（`autoApproveOrdinary = false, autoApproveHighRisk = false`），手机端无法开启自动批准。
- `POST /v1/amber/schedules/<id>/enabled` → `{"enabled": Bool}`（不存在返回 `404`）
- `POST /v1/amber/schedules/<id>/run` → `{}` 立即触发一次运行（不存在返回 `404`，已在运行或达到并发上限返回 `409`）
- `POST /v1/tasks/<percent-encoded-key>/monitor` → `{"monitored": Bool}` 切换指定会话推送开关（不存在返回 `404`）

---

## 6. 错误码总表与旧版客户端兼容契约

### 6.1 标准错误响应格式

所有非 `2xx` 响应均返回 JSON：
```json
{
  "error": "人类可读的中文错误说明或 unauthorized"
}
```

| 状态码 | 触发场景 | 客户端处理要求 |
| --- | --- | --- |
| `200` | 请求成功 | 正常解码业务字段 |
| `400` | JSON 格式非法、缺少必填参数、规则校验失败（如间隔 < 15 分钟） | 提示具体输入错误，不重试 |
| `401` | 缺少 Bearer Token、Token 无效或设备已被吊销 | 标记配对失效，引导用户重新配对 |
| `403` | 配对码无效/过期/已使用；或手机尝试批准 `highRisk == true` 工具 | 提示权限受限或需在 Mac 上核对批准 |
| `404` | 未知路径、找不到指定的 `taskKey` 或 `scheduleId` | 刷新列表状态 |
| `409` | 审批已结束/旧 run 审批/重复审批；任务已在运行；未注册推送 Token 时调用 `test-push` | 提示状态已变更并立即刷新 `/v1/status` 或 `/v1/amber/board` |
| `500` | 服务端文件读写异常或 `devices.json` 损坏 | 展示服务端错误，**严禁清除本地配对状态** |
| `502` | APNs / FCM / Huawei 推送上游返回失败或凭证缺失 | 展示推送通道错误详情 |
| `503` | Mac 上 Amber.app 未运行（`amber-app.sock` 不可连）或子系统未就绪 | 提示“Amber 未运行：在 Mac 上打开 Amber 后重试” |
| `504` | Mac 上 Amber.app 主线程繁忙超时（> 4.5s） | 提示“Mac 正忙，请稍后刷新查看结果” |

### 6.2 旧版与跨端客户端前向/后向兼容规则

1. **忽略未知字段**：各端 JSON 解码器必须忽略未知字段（如 Mac 端 `BoardItem.conversationId` 在 iOS/Android/Harmony 端可忽略）。
2. **可选字段容错**：
   - 旧版客户端调用 `POST /v1/pair` 不传 `deviceName` 时，服务端默认使用 `platform` 名称。
   - 非 iOS 客户端调用 `POST /v1/push-token` 不传 `environment` 时，服务端正常接受。
   - 客户端解码 `Session`、`BoardItem`、`ScheduleSummary` 时，对 `summary`、`host`、`waitReason`、`pendingApproval`、`health`、`synaraURL`、`scheduleId`、`nextRunAt`、`lastStatus`、`lastRunAt`、`approval`、`paused` 等可选字段均须容忍 `null` 或缺省。

---

## 7. 数据保留与上下文压缩不变量契约（C4 Data Retention）

1. **原始对话永不覆盖**：
   - 手动或自动上下文压缩（`compact`）仅生成独立的检查点投影记录（macOS 存储在 `conversation-insights/<id>.json`，覆盖前序消息并在模型请求组装时注入摘要与 `history_search` / `history_fetch` 提示）。
   - 会话主存储（`conversations/<id>.json` 及内存中的 `conversation.messages`）**始终保留全部原始未压缩消息**，绝不用摘要替换原始消息。
2. **导出与备份完整性**：
   - 会话导出（`.json` 完整文档、`.md` Markdown、`.pdf` PDF）始终输出完整原始消息序列。
   - 备份（`.ambermacbackup` / `.amberbackup`）同时包含完整原始会话 JSON、上下文压缩/洞察检查点（`insights`）、产物架固定项（`pins`）及受管工作区文件（`files`）。
   - 备份与恢复显式剥离 API Key / OAuth 凭证（凭证仅驻留系统安全存储如 Keychain），恢复时始终创建新会话副本而不覆盖现有会话。
3. **显式删除语义**：
   - 删除会话时，同步清理会话主存储文件、`conversation-insights` 记录、`artifact-shelf` 固定项以及 Amber 受管工作区目录；
   - 若会话绑定了用户打开的**外部文件夹（External Workspace Folder）**，删除会话仅解除绑定，**绝不删除用户外部文件夹中的任何文件**。

---

## 8. C3 v2 草案：云端本体（Cloud Self）与授信端前台审批规则变更

- 状态：**DRAFT（Cloud Self Phase 1 起生效）**
- 适用端：云端守护进程（`amberd` / `:cloud-daemon`）、macOS（`AmberMac`）、iOS（`AmberAgent`）、Android（`AmberAndroid`）、HarmonyOS（`AmberHarmony`）及 IM 连接器（Telegram / 飞书）

### 8.1 拓扑演进：从局域网 Mac 单主到云端本体星型拓扑

1. 在 C3 v2 架构下，常驻守护进程 `amberd`（`:cloud-daemon`）作为中心网关与唯一权威状态源运行，100% 向下兼容 C3 v1 的全部 REST 端点（`/v1/pair`、`/v1/unpair`、`/v1/status`、`/v1/push-token`、`/v1/test-push`、`/v1/amber/decision`、`/v1/amber/board`、`/v1/amber/schedules`、`/v1/tasks/<key>/monitor`）与 `amber://gateway/pair?p=` 配对深链。
2. `POST /v1/pair` 扩展支持 `platform` 枚举 `"ios" | "android" | "harmony" | "macos" | "linux"`，以及可选字段 `protocolVersion`（`1 | 2`）、`nodeRole`（`"viewer" | "executor" | "hybrid"`）、`trustedApprovalSurface`（`Bool`）。旧版 C3 v1 客户端省略扩展字段时仍完全合法。

### 8.2 高风险审批规则变更（Trusted Foreground Approval Surface）

C3 v1 §3.2 原定“高风险操作只能在 Mac 上核对后批准，手机端一律拒绝 `allow=true`”。在云端本体场景下，用户外出时 Mac 可能处于离线或睡眠状态，因此 C3 v2 将高风险审批信任边界更新为 **「仅限已配对、已解锁的原生 App 前台批准；一切非可信或非前台来源只能拒绝」**：

| 审批发起端 / 交互表面 | 普通风险工具（`highRisk == false`） | 高风险工具（`highRisk == true`） | 网关裁决与返回码 |
| --- | --- | --- | --- |
| **已配对且已解锁的原生 App 前台**<br>（macOS / iOS / Android / 鸿蒙 App 前台详情页，携带已配对设备 Bearer Token + 前台解锁证明 `X-Amber-Trusted-Foreground: true` 或请求体 `trustedForeground: true`） | 允许 `allow=true` / `allow=false`（`200`） | **允许批准 `allow=true`（`200`）** 或拒绝 `allow=false`（`200`） | 审计记录 `approved` / `denied` |
| **锁屏、通知中心横幅、灵动岛、手表、未带前台解锁证明的移动端远端请求** | 允许批准或拒绝（`200`） | **严禁批准！** `allow=true` 必须在入口拒绝；仅允许 `allow=false`（`200`） | `allow=true` 返回 `403 {"error": "高风险操作只能在已配对且已解锁的原生 App 前台核对后批准"}`，审计记录 `rejected_high_risk` |
| **IM 渠道（Telegram / 飞书私聊或群聊卡片按钮）** | 仅主人私聊允许批准或拒绝 | **严禁批准！** 卡片只渲染「拒绝」按钮；若收到 `allow=true` 回调直接在入口拒绝 | `allow=true` 返回 `403`，审计记录 `rejected_high_risk` |
| **云端本体自身（无人值守后台任务 / 子代理 / Council / JS 沙箱）** | 按任务无人值守策略 | **严禁云端自批！** 子代理/Council/JS 沙箱物理剥离高风险写工具；无人值守默认挂起进 `needsYou` | `allow=true` 返回 `403`，审计记录 `rejected_high_risk` |

### 8.3 Phase 1 网关执行硬约束

1. 在 `POST /v1/amber/decision` 入口处，当目标挂起审批的 `highRisk == true` 且请求 `allow == true` 时：
   - 网关检查请求是否同时满足：① 来自已配对的原生客户端设备（有效 Bearer Token 且 `device.trustedApprovalSurface == true`）；② 显式声明处于已解锁原生 App 前台（请求头 `X-Amber-Trusted-Foreground: true` 或 JSON 字段 `"trustedForeground": true`）。
   - **任何不满足上述条件的非可信来源（含旧版未声明前台解锁的远程调用、锁屏/通知快捷动作、IM 渠道、云端内部自调用）请求 `allow=true` 时，网关立即返回 `HTTP 403`，任务保持 `waiting` 状态，并写入 `audit.jsonl`（`outcome = "rejected_high_risk"`）。**
2. 任何来源请求 `allow=false`（拒绝高风险操作）始终放行并返回 `200 OK`。
