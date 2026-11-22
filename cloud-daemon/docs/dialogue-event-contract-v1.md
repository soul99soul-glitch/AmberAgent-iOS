# Dialogue Event Contract v1

`schemaVersion = 1` · 平台中立（macOS / iOS / Android / HarmonyOS / Cloud Daemon）

v1 客户端在对话写入、回执查询及事件分页请求上发送 `X-Amber-Dialogue-Version: 1`。省略此头时沿用旧协议。到达时已失效的补充或停止请求保留事务审计，旧端提交和重试得到 `409 task_terminal`，已正常受理的输入仍可重放。旧端分页只包含原有事件种类，并跳过无效的 `stop_requested`；v1 分页返回完整审计。

## 设计原则

- **Local-First 与执行者单写（Single-Writer Per Run）**：每个 run 在同一 `epoch` 内仅由单一执行者推进状态，不中途静默迁移。
- **历史只镜像不迁移**：离线账本通过 `importLedgerEvents` 只读镜像导入，保留原事件 `executorKind` / `executorId`，绝不改写历史 run 属主或推进活跃 `epoch`。
- **事务内强制不变量**：幂等冲突、`stale_epoch`、停后/终态 `followup` 作废与完成后 `stop_too_late` 均在 `DialogueEventStore` 同一 SQLite `BEGIN IMMEDIATE` 事务内强制生效，不依赖客户端自觉。
- **向后兼容**：所有增量字段均带可选默认值；序列化统一启用 `ignoreUnknownKeys = true`，兼容旧 SQLite 载荷与旧版客户端。

## 模型与字段语义

适用于 `DialogueInput`、`DialogueReceipt`、`DialogueEvent`、`DialoguePage` 与 `CloudWorkItemRecord`（各结构按职责携带以下可选扩展字段）：

| 字段 | 类型 | 默认值 | 语义 |
| :--- | :--- | :--- | :--- |
| `schemaVersion` | `Int` | `1` | 契约主版本号 |
| `conversationId` | `String?` | `null` | 跨端共享的逻辑会话 ID；未传时保持旧 `topicId` 行为 |
| `executorKind` | `String?` | `null` | 执行者类型（如 `cloud`、`mac`、`ios`、`android`、`harmony`） |
| `executorId` | `String?` | `null` | 执行者实例标识（如节点 ID、设备 ID 或 worker ID） |
| `epoch` | `Long?` | `null` | 针对同一 `workItemId` 的单调执行代际；用于拒绝过期写入 |
| `causedByInputId` | `String?` | `null` | 触发本回执/系统事件的源输入 `DialogueInput.id`，消除按文本猜匹配 |
| `causedByRequestId` | `String?` | `null` | 触发本回执/系统事件的源请求 `DialogueInput.requestId` |
| `parentRunId` | `String?` | `null` | 父 run / 交办源 run ID |
| `observedSeq` | `Long?` | `null` | 发送端在提交该输入/事件时已观测到的时间线 `seq` |
| `ledgerId` | `String?` | `null` | 离线账本标识（用于镜像导入与审计溯源） |
| `outcomeUnknown` | `Boolean` | `false` | 远端结果暂不可知标记（客户端需提供明确重查/重试/确认出口） |

## 事件类型（`DialogueEvent.kind`）

### 原有事件类型
- `user_message`：用户主对话输入
- `followup`：针对 `workItemId` 的补充指令
- `stop_requested`：针对 `workItemId` 的停止请求
- `input_consumed`：补充已在推理边界被消费（必须携带 `causedByInputId`、`causedByRequestId`）
- `input_cancelled`：补充未执行并已作废（必须携带 `causedByInputId`、`causedByRequestId`）
- `assistant_reply`：助手回复或受理回执
- `process_event`：后台执行状态更新
- `task_result`：任务终态结算结果

### v1 新增/预留事件类型
- `run_started`：执行者启动某 `epoch` 的 run
- `run_finished`：执行者结束 run（带 `outcome`）
- `run_handoff`：跨端/跨执行者显式交接
- `ledger_imported`：离线账本镜像导入审计事件（带 `ledgerId`）
- `stop_too_late`：目标任务已完成之后才到达的停止请求（必须携带 `causedByInputId`、`causedByRequestId`）

## 事务不变量（`DialogueEventStore`）

1. **请求去重与篡改冲突**：按 `(deviceId, requestId)` 幂等；同 `fingerprint` 返回既有输入且 `replayed = true`，异 `fingerprint` 抛出 `DialogueConflict("request_id_conflict")`。
2. **因果回执**：`consume()` 与 `abandonPending()` 生成的 `input_consumed` / `input_cancelled` 必须填充 `causedByInputId = input.id`、`causedByRequestId = input.requestId`，并透传 `conversationId`。
3. **过期 `epoch` 拒绝**：若输入携带 `workItemId` 与 `epoch`，且 `epoch < currentMaxEpoch(workItemId)`，同一事务内直接拒绝并抛出 `DialogueConflict("stale_epoch")`。
4. **停后/终态补充自动作废**：目标 `workItemId` 已处于停止中（`stopping`）或终态（`COMPLETED` / `FAILED` / `CANCELLED`）时收到 `followup`，同一事务内记为 `consumed = 2`（不进入 pending），并写入带 `causedByInputId` 与 `causedByRequestId` 的 `input_cancelled` 事件。
5. **完成后停止留痕**：目标 `workItemId` 已处于 `COMPLETED` 时收到 `stop`，同一事务内记为 `consumed = 2`，写入带 `causedByInputId` 与 `causedByRequestId` 的 `stop_too_late` 事件，不静默丢弃且不改写任务完成态。
6. **离线账本只读镜像**：`importLedgerEvents(ledgerId, events)` 在同一事务内按 `event.id` 幂等接收——同 ID 同内容去重，同 ID 异内容回滚整批并抛出 `DialogueConflict("ledger_event_conflict")`；成功后写入 `ledger_imported` 审计事件，不改动 `work_items`、`dialogue_inputs` 或 `dialogue_work_item_state`。

## 错误码约定

| 错误码 | HTTP 状态码 | 含义 |
| :--- | :---: | :--- |
| `request_id_conflict` | `409` | 同 `(deviceId, requestId)` 载荷指纹不一致 |
| `stale_epoch` | `409` | 输入 `epoch` 小于目标 `workItemId` 当前最高 `epoch` |
| `ledger_event_conflict` | `409` | 离线账本导入出现同 `event.id` 但内容冲突 |
| `task_not_found` | `404` | 目标 `workItemId` 不存在 |
| `receipt_not_found` | `404` | 目标 `requestId` 回执不存在 |
| `invalid_request` | `400` | 请求体格式或字段校验失败 |
| `invalid_cursor` | `400` | 事件分页游标或 `limit` 非法 |
| `unauthorized` | `401` | 设备鉴权失败 |
