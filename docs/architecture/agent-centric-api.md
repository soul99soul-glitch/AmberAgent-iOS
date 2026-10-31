# Agent-centric Cloud API — P2.6

本契约面向以后四端接入的云端后端。P2.6 不改变任何端侧 UI。Agent 是专题中心、记忆边界和执行权限的唯一身份，不另建 Hub 模型。主 agent 固定为 `main`（Amber / Router），主时间线继续使用既有 `PRIMARY_CONVERSATION_ID` 存储，客户端无需持有它的 session ID。

## 认证与版本

以下所有 `/v2` 接口复用 C3 配对 Bearer token：`Authorization: Bearer <paired-token>`。未认证返回 `401 {"error":"unauthorized"}`，认证存储损坏返回 500；不存在的 agent / WorkItem 返回 404。无新增权限或外部服务。既有 `/v1` 接口继续保留；其中 session、工具轨迹和审批对象用于诊断与审批下钻，不作为新主导航的数据源。

这些是读取与管理接口。用户消息继续由已认证的 IM ingress 进入同一主时间线；App 的消息提交与增量订阅协议尚未在 P2.6 定义，客户端不能把本期 GET 接口当作发送或实时事件接口。

## GET /v2/agents

返回已生效 agent，按 ID 排序。未确认提议不进入列表。

```json
{
  "agents": [
    {"id":"main","name":"Amber","memoryPolicy":"SHARED_WITH_GLOBAL","tags":[],"revision":1},
    {"id":"coding","name":"编码","memoryPolicy":"HUB_ISOLATED","tags":[],"revision":1}
  ]
}
```

`id` 是稳定身份，`revision` 是服务端乐观锁版本；显示名称不能作为主键。`tags` 仅预留人工数据，不做自动打标、模板演化或聚类。列表仅返回公开投影，省略 instructions、toolScope、模型配置及所有 session 身份。名称和标签经过凭据脱敏及工具名清洗。

## GET /v2/agents/{id}/activity

```json
{
  "agentId":"coding",
  "activities":[{"taskId":"work:abc","label":"正在检查项目","phase":"progress","updatedAtMs":1793460000000}],
  "workItems":[{"id":"work:abc","agentId":"coding","title":"编码处理请求","state":"WORKING","progress":"正在检查项目","updatedAtMs":1793460000000}]
}
```

返回该 agent 最多 100 项任务及对应 ActivityStatus，未终结任务优先，各组按更新时间倒序。`phase` 为 `started | progress | done | failed`；完整任务状态为 `QUEUED | STARTING | WORKING | WAITING | IDLE | COMPLETED | FAILED | CANCELLED`。`label` 最多 20 个 Unicode 代码点，使用人话描述，不包含执行工具名、参数、原始输出或推理。`updatedAtMs` 为 Unix 毫秒。

这是持久状态快照，重启后仍可恢复；无需依赖 IM 消息编辑是否成功。`WAITING` 的审批详情仍从既有 C3 审批接口下钻，不能根据 ActivityStatus 自动批准。

## GET /v2/timeline?limit=50&before=<cursor>

返回唯一主时间线，条目按从旧到新排序；不传游标时取最新一页。`limit` 为 1..100，默认 50。无效 limit 或游标返回 400。

```json
{
  "items":[
    {"id":"message-uuid-1","role":"user","agentId":"main","text":"@编码 检查实现"},
    {"id":"message-uuid-2","role":"assistant","agentId":"main","text":"这批任务结束：1 项完成。"}
  ],
  "nextCursor":"message-uuid-1"
}
```

`nextCursor` 表示下一页更早消息的排他边界，无更多数据时为 null。客户端应把游标当作不透明值。用户与助手消息共用稳定 message ID。所有对外助手消息仍由主 Router 发出，因此这里的 `agentId` 固定为 `main`；实际执行归属以 WorkItem.agentId 为准，不能把回复条目误作细分 agent 的独立对话窗口。

只输出 user / assistant 的 Text 部分。Reasoning、Tool 部分、参数、输出及 system prompt 均不进入主时间线响应；文本再次执行 CredentialRedactor 与 OutwardTextSanitizer。此投影不是原始会话导出，工具名和部分技术内容会被移除；原始诊断走原有受认证下钻入口。

## GET /v2/work-items/{id}

```json
{
  "workItem":{"id":"work:abc","agentId":"coding","title":"编码处理请求","state":"COMPLETED","progress":"处理完成","updatedAtMs":1793460000000},
  "brief":"检查实现",
  "failure":null,
  "sessionArchived":true
}
```

用于从活动下钻到脱敏的任务执行摘要。只暴露任务标题、简报、进度、失败说明与逻辑归档状态。省略 targetNode、workerSessionId、toolScope、activeToolName、原始工具轨迹、源消息溯源与文件路径。需要精确取证时由 Router 使用既有 session 诊断工具读取，前端不用这些内部 session API 组织日常交互。

## Agent 管理与确认

### POST /v2/agents

已配对主人可直接创建或完整替换细分 agent。创建使用 `expectedRevision: 0`，更新使用上次读取的 revision。冲突返回 409，字段、模型或权限无效返回 400。请求里的 `profile.revision` 不参与锁判断，服务端返回新 revision。

```json
{
  "expectedRevision":0,
  "profile":{
    "id":"coding",
    "name":"编码",
    "instructions":"只读检查当前项目，说明证据。",
    "memoryPolicy":"HUB_ISOLATED",
    "toolScope":["history_search"],
    "modelPreference":null,
    "routingKeywords":["编译","代码检查"],
    "tags":[]
  }
}
```

成功返回与 `/v2/agents` 中单项相同的 PublicAgent。ID 匹配 `[a-z][a-z0-9.-]{0,63}`，`main` 不可通过此接口修改，`global` 保留。toolScope 必须是宿主主人授权范围的子集：由 `CloudAgentKernel.ownerToolScope` 与当前已启用并实际注册的能力取交集；未提供 ownerToolScope 时沿用现有宿主能力授权。细分 agent 的有效范围再与其 toolScope 取交集。所有 Worker 仍使用 SUBAGENT 执行域，高风险、写操作及默认关闭能力继续受既有内层门禁控制，不因加入 toolScope 获得豁免。

modelPreference 只接受宿主注入 `modelClients` 中的已配置别名；null 使用默认客户端，不接受任意 URL、Key 或未配置模型。此接口不创建凭据。当前 daemon 默认客户端的既有行为不在本期变更范围内。

### 主 Router 提议创建

Router 的 `propose_agent` 只能保存候选，不能创建生效 agent。候选以不可变 proposal ID 存 SQLite，并关联 SourceMessageProvenance 的真实主人消息。Worker、自动化和外部发送者不能提议、创建或确认。

`GET /v2/agent-proposals` 是受认证的管理投影，返回未确认提议的 `{id,profile,sourceMessageIds,createdAtMs}` 数组，供主人查看完整配置。该管理接口包含工具范围和指令，不能混入公开 agent 列表或主时间线。配置写入前经过凭据脱敏。

主人通过已认证 ingress 发出新的原文：`确认创建 agent <完整 proposal ID>`。服务端必须解析这条独立消息的 OWNER_HUMAN 溯源，确认它来自提议之后、没有复用原始任务消息，并且精确指向该不可变提议。确认后原子创建 revision 1 并消费提议，重复确认返回冲突。主 Router 在入站处理中完成确认，也提供管理接口 `POST /v2/agent-proposals/{id}/confirm`，请求 `{"sourceMessageId":"已落库的独立主人确认消息ID"}`；它不能用请求体文字冒充已认证主人消息。

## 路由、记忆与 session 的服务端规则

1. 仅主 Router 拥有选 agent 和派单权限。主时间线先匹配 `@名称` / `@id`，再匹配 routingKeywords（不区分大小写的子串规则）。显式提及以空白或常见标点结束，避免 `@编码助手` 误命中 `@编码`。多个显式目标交主 Router 澄清；规则唯一命中才生效，否则模型仅从现有 ID 中选择，无效结果交主 Router。模型仅看到当前消息与候选名称/关键词，不接触其他 agent 记忆。每次决策以 `agent_routed` 诊断事件保存 agentId、method、reason 和源消息 ID。
2. 细分 agent 的每次授权任务落为带 agentId 的 WorkItem。只有真实主人原始消息能授权新任务；其他 agent 无直接通信或派单通道。快速确认和结果始终经 Router 统一出口返回。
3. `SHARED_WITH_GLOBAL` 先召回本 agent 记忆，再补全局偏好（CORE、USER 或 pinned）；不混入其他 agent 或全局普通项目笔记。`HUB_ISOLATED` 仅召回本 agent 记忆，并使用固定安全身份说明，不读取用户的全局 SOUL.md。显式“记住”在选中 agent 后写入相应作用域。默认主 Router 的既有全局记忆行为保留。旧 memories.json 作为全局存量导入 agent-memories.json，原文件保留；损坏数据报错，不默默清空。
4. Worker session 由队列创建；同 agent 且共享订阅话题的后续新 WorkItem，可复用已结束且未被占用的 session。终态逻辑归档，原始数据保留，订阅停止直通。跨 agent 永不复用。显式 @提及绕过旧话题直通，重新经 Router。每个新 WorkItem 保有独立结算与 Rollup。Worker 的历史工具强制限制在当前受管 session，不能借参数读取主时间线。
5. 高风险审批继续走 C3 v2：IM 仅可拒绝；批准要求已配对的受信原生 App、前台解锁证明、明确成功的生物识别证明，锁屏/通知/IM surface 均拒绝批准。HTTP 证明属于既有配对客户端信任边界，不是硬件远程认证协议。缺少生物识别证明现在返回 403，客户端须发送 `X-Amber-Biometric-Verified: true` 或 `biometricVerified: true`。

## 本期九项自查

| 检查项 | 实现与验证入口 |
| --- | --- |
| 1. 非受信来源不能批准 | C3 foreground/surface/biometric 门禁；E2E 增加缺少生物识别证明的拒绝断言 |
| 2. 待审批凭据终态清理 | 沿用 vault 与 P1 六条清理路径；既有 E2E |
| 3. 历史、导出、摘要及公开投影脱敏 | CredentialRedactor 保留；新增 HTTP agents/timeline 与 Worker 作用域测试 |
| 4. 占位符不能覆盖凭据 | 沿用 vault / tool gate / memory 拒绝；既有九项缺陷 E2E |
| 5. 子代理权限与创建边界 | Worker 工具声明和执行双层收窄，注册表拒绝 Worker 自建、提议和确认；定点测试 |
| 6. 压缩触发频率与保真 | 未改变 ContextManager；既有 minDelta / force 断言 |
| 7. 固定系统前缀与预算 | 未改变主 Router 预算实现；Worker 的身份与作用域系统消息置于历史之前 |
| 8. 默认关闭能力不能旁路 | effectiveTools 与原有能力 gate 叠加；既有 JS/Recipe E2E |
| 9. 声明和实际能力一致 | 注册工具交集 + SUBAGENT 声明 + executeWorkerTool 内层校验，模型偏好必须已配置；伪造调用定点回归 |

验证命令：`JAVA_HOME=/opt/homebrew/opt/openjdk@21 ./gradlew :cloud-daemon:jvmTest :cloud-daemon:fatJar`。测试使用临时目录、假凭据及确定性模型；不证明真实 provider、生产云服务器或四端 App 行为验收。
