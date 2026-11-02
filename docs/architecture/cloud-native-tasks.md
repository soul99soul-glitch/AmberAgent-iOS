# 配对客户端提交云端任务

在 `c70fb32b` 的模型配置和持久 WorkItem 队列之上补齐「提交任务 → 云端模型执行 → 轮询持久结果」。认证复用 C3 的 `Authorization: Bearer <paired-token>`，候选地址、HTTPS 端口和 SPKI 固定均不变。本文只包含脱敏契约，不包含真实地址、票据或 Key。

## agent 与权限

`GET /v2/agents` 返回 `{ "agents": [{"id":"main","name":"Amber",...}] }`；显示名称不是 ID。

提交时 `agentId` 默认 `main`；指定其他 ID 使用对应 AgentProfile 的指令、记忆作用域、工具权限和模型偏好。没有模型偏好时继承 daemon 模型，偏好配置缺失时明确失败。该入口明确向选定 agent 派任务，不猜测 `@提及` 或焦点中心，也不依赖 Router 是否决定派单。

包括 `main` 在内的任务均交给现有云端受限 Worker。客户端不能指定工具权限、审批策略、Mac 节点或远端主机。沿用现有 Worker 工具门禁；本期不是任意 Shell/文件写入或手机代操作入口。

## 提交：POST /v2/work-items

```json
{
  "requestId": "550e8400-e29b-41d4-a716-446655440000",
  "agentId": "main",
  "title": "整理发布检查项",
  "text": "根据以下资料列出三项发布检查……"
}
```

`requestId`、`text` 必填，`agentId` 默认 `main`，`title` 默认 `云端任务`。requestId 为 1..128 位 ASCII 字母/数字/`._:-`（支持 UUID）；正文最多 24000 字符、标题最多 200 字符且不得为空白，完整 JSON 文本最多 100000 字符（按 Kotlin String.length）；未知 JSON 字段返回 400。

首次接受返回 **202**：

```json
{
  "workItem": {
    "id": "work:<opaque-id>", "agentId": "main", "title": "整理发布检查项",
    "state": "WORKING", "updatedAtMs": 1793500000000
  },
  "replayed": false
}
```

客户端先持久保存 requestId 和完整请求体，再发请求，收到响应后保存 WorkItem ID。网络超时、候选地址回退或 App 重启后以同一 requestId 和请求体重试：同一配对设备的相同请求返回 **200**、`replayed:true` 和原任务当前状态，不重跑模型；同键换正文/标题/agent 返回 **409**。不同设备各自独立；重新配对产生新 device ID，不能依赖原 requestId 去重。

202 表示已持久接受，不保证响应时仍在排队。来源消息、任务指纹和操作结果沿用现有编排数据库与重启恢复，不新增独立任务库或凭据仓。

## 查询：GET /v2/work-items/{id}

```json
{
  "workItem": {
    "id": "work:<opaque-id>", "agentId": "main", "title": "整理发布检查项",
    "state": "COMPLETED", "updatedAtMs": 1793500005000
  },
  "brief": "根据以下资料列出三项发布检查……",
  "sessionArchived": true,
  "resultMarkdown": "# Settlement Report · work:…\n…\n## Summary\n模型结果正文"
}
```

- 状态沿用 `QUEUED | STARTING | WORKING | WAITING | IDLE | COMPLETED | FAILED | CANCELLED`；最后三种为终态。执行失败返回 FAILED 和 failure，不伪造成功。
- `progress`、`failure`、`resultMarkdown` 可缺省/null。resultMarkdown 来自既有持久结算报告，保留最终正文中的 Markdown、代码和 JSON，执行凭据脱敏；不暴露原始 Tool/Reasoning 消息、workerSessionId 或工具参数。状态标签的删代码/短文规则不用于结果正文。
- 前台建议约每秒轮询一次，终态停止；updatedAtMs 是 Unix 毫秒。无 SSE/WebSocket/token 流。
- `/v2/timeline` 仍是 Router 主时间线，不是本入口的单任务结果流；该入口不向其重复插入用户消息。其他配对设备可从 `/v2/agents/{id}/activity` 获得任务 ID 后查询。

## 取消：POST /v2/work-items/{id}/cancel

无 body，返回 **200** 和上述详情。非终态持久化为 CANCELLED、释放槽位并取消本地 Worker 协程；晚到结算不能覆盖终态。重复取消保留终态；完成先于取消时原样返回 COMPLETED/FAILED。重试原提交仍返回原任务，重新执行需要新 requestId。

取消不撤销已发生的副作用，也不保证 provider 尚未计费。

## 错误与身份

400=JSON/字段/长度不合法；401=配对 Token 无效/被撤销；404=agent/任务不存在；409=requestId 内容冲突；500=存储/内部故障（保持原 requestId 重试）。设备共享同一主人的 agent/任务视图，没有新增多租户或每设备私有任务空间。

## iOS 最窄接入（只读建议）

依据已交付 iOS `a4254e26`：

1. `iosApp/iosApp/MacGatewayClient.swift` actor 增加 agents/submitTask/workItem/cancelTask 方法，复用其 send 的 HTTPS、SPKI、Bearer 和地址回退；DTO 可独立文件。requestId 在回退和手动重试中保持不变。
2. `MacGatewayStore.swift` 持有私有 client，提供任务 Store 所需的小入口，复用现有配对/Keychain Token。
3. 从 `MacGatewaySettingsView.swift` 已连接区域打开「云端任务」表单/详情，或由 `MacTasksBoardView.swift` 接入同一任务 Store；显示 agent、正文、状态、结果和取消，保存 requestId/WorkItem ID 以恢复轮询。

该路径不改变 ChatStore 的本地模型选择/会话生成。现有三端 C3 v1 页面尚未消费此契约，后端部署不能替代手机派任务验收；云端线程没有修改客户端。

## runtime 配置与旧数据

沿用既有 `443 TLS reverse proxy → 127.0.0.1:47822`；daemon 保持 HTTP upstream，TLS 代理保留原证书/指纹并转发上述 `/v2` 路径。本轮不更换公网、证书、端口或 SSH 隧道。

| 配置 | 要求 |
|---|---|
| Java | JRE 21；fatJar 自带 Kotlin/Ktor/provider/SQLite，无需 Gradle |
| AMBER_DATA_DIR | a84 实例既有 data 的同一绝对路径 |
| AMBER_HOST / AMBER_PORT | 127.0.0.1 / 47822，对应原 TLS 代理 upstream |
| AMBER_MODEL_PROVIDER | openai 或 claude，匹配真实服务协议 |
| AMBER_MODEL_ID | 该服务可用模型的准确 ID，显式设置 |
| AMBER_MODEL_BASE_URL | API 根地址，含需要的 /v1，不含 /chat/completions、/messages、Key 或查询参数 |
| 主密钥 | 原 AMBER_MASTER_KEY_FILE、AMBER_MASTER_KEY 或 systemd amber_master_key credential；跨重启不变 |
| 模型 Key | runtime 用现有 AMBER_MODEL_API_KEY 或加密凭据库提供；不写入本文或产物包 |

无模型 Key 明确拒绝启动；echo 只作为显式开发模式，不用于验收。已有 secrets.enc.json 必须复用原主密钥；不能删除旧库掩盖解密失败。旧实例若从未写凭据库，首次导入模型 Key 时用稳定主密钥初始化。

runtime 更新：停原 daemon 并确认退出，备份完整旧 data（含 SQLite/WAL、配对文件、证书、加密库）、旧 JAR 和原启动命令，再以同一 data/凭据来源启动新包。保留 identity.json、devices.json、tls-identity.p12，不重新配对。本轮无破坏性 schema 迁移；相对 a84 延续 c70 的 CREATE TABLE IF NOT EXISTS pending_tag_turns。

```sh
# 仅为脱敏启动模板，由 runtime 在更新窗口执行。
java -jar /path/to/new/amberd-all.jar \
  --data-dir /existing/absolute/data --host 127.0.0.1 --port 47822
```

回滚：停新 daemon，换回备份旧 JAR/启动配置，身份和证书保持原路径。若需严格数据回滚，停止所有写入者后将完整备份恢复到同一绝对 data 路径；此操作会丢弃更新后的任务/结果，由 runtime 判断。a84 没有原生派任务接口且仍为旧 echo，回滚不能视为任务能力可用。

JAR 路径、SHA256、本地 HTTP stub 证据及未验收项见本轮交付记录。真实 provider、远端更新与手机任务验收分别由 runtime 和客户端线程负责。
