# Agent-centric Cloud API — P2.6

本契约面向以后四端接入的云端后端。P2.6 不改变任何端侧 UI。Agent 是专题中心、记忆边界和执行权限的唯一身份，不另建 Hub 模型。主 agent 固定为 `main`（Amber / Router），主时间线继续使用既有 `PRIMARY_CONVERSATION_ID` 存储，客户端无需持有它的 session ID。

## 认证与版本

以下所有 `/v2` 接口复用 C3 配对 Bearer token：`Authorization: Bearer <paired-token>`。未认证返回 `401 {"error":"unauthorized"}`，认证存储损坏返回 500；不存在的 agent / WorkItem 返回 404。无新增权限或外部服务。既有 `/v1` 接口继续保留；其中 session、工具轨迹和审批对象用于诊断与审批下钻，不作为新主导航的数据源。

原生客户端任务闭环现新增 `POST /v2/work-items`、`POST /v2/work-items/{id}/cancel`，并在任务详情中提供持久的 `resultMarkdown`；确切请求、幂等、agent 选择与轮询规则见 [配对客户端任务契约](cloud-native-tasks.md)。IM ingress 仍进入 Router 主时间线；原生任务入口直接复用 WorkItem 队列，GET timeline 不作为发送或单任务流式接口。

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

`id` 是稳定身份，`revision` 是服务端乐观锁版本；显示名称不能作为主键。这里的 `tags` 是中心的人工话题路由标签；对话自动 Supertag、模板与合集使用下文独立投影。列表仅返回公开投影，省略 instructions、toolScope、模型配置及所有 session 身份。名称和标签经过凭据脱敏及工具名清洗。

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
  "sessionArchived":true,
  "resultMarkdown":"# Settlement Report · work:abc\n…\n## Summary\n最终结果"
}
```

用于从活动下钻到脱敏的任务摘要及终态结算报告。`resultMarkdown` 为可选字段，保留最终结果中的 Markdown/代码/JSON，并做凭据脱敏；不采用 activity 的删代码规则。省略 targetNode、workerSessionId、toolScope、activeToolName、原始工具轨迹、源消息溯源与内部文件路径。需要精确取证时由 Router 使用既有 session 诊断工具读取，前端不用这些内部 session API 组织日常交互。提交/取消/重试与状态轮询见 [原生任务契约](cloud-native-tasks.md)。

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

验证命令：`HOME=/Users/arquiel JAVA_HOME=/opt/homebrew/opt/openjdk@21 ./gradlew :cloud-daemon:jvmTest :cloud-daemon:fatJar`。测试使用临时目录、假凭据及确定性模型；不证明真实 provider、生产云服务器或四端 App 行为验收。

## Supertag 与中心后端扩展

中心仍以非 `main` 的 AgentProfile 为唯一身份，`hubId == agentId`；复用同一个 revision、instructions、toolScope 和 AgentMemoryPolicy。新增的 `hubTemplate` 默认 `GENERAL`，也可为 `CODING | NOVEL | RESEARCH`，在中心 API 中投影为 `template`。这里只提供类型，不读取工作区、不迁移小说文件，也不改变四端入口。

本节所有接口继续要求 C3 配对 Bearer token。管理动作视为已配对主人的明确操作，Worker/模型没有对应写工具。缺对象返回 404，字段/类型无效返回 400，revision 或状态冲突返回 409。时间均为 Unix 毫秒。

### 中心及专注状态

| 方法与路径 | 请求/响应 |
| --- | --- |
| `GET /v2/hubs` | `{hubs:[{id,name,memoryPolicy,template,tags,revision}]}`；不含指令、模型和权限配置 |
| `GET /v2/hubs/{id}` | 中心管理详情 `{id,name,instructions,memoryPolicy,template,tags,routingKeywords,revision}` |
| `POST /v2/hubs` | `{expectedRevision,hub:{id,name,instructions,memoryPolicy,template,tags,routingKeywords}}`；创建 revision 0，更新须传当前 revision；返回新详情 |
| `GET /v2/hub-focus` | `{hubId:null}` 或 `{hubId:"coding"}` |
| `POST /v2/hub-focus` | `{hubId:"coding"}` 进入中心，`{hubId:null}` 返回自动路由；返回同结构 |

中心管理接口保留已有 agent 的工具与模型配置；创建中心的默认 toolScope 为空，不能由一个中心模板获得额外执行权限。修改指令和隔离策略即更新同一 AgentProfile。`/v2/agents` 管理入口与本节互通，旧 JSON 没有 hubTemplate 时按 GENERAL 读取。

专注状态持久保存在 SQLite，作用于跨通道共享的主时间线。路由优先级为：显式 @提及（多目标仍由主 Router 澄清）→ 当前专注中心 → 唯一 routingKeywords/中心 tags 子串命中 → 现有路由模型选择。自动模式只把候选名称与关键词交给路由模型，不提供其他中心记忆。选中中心后交给带 agentId 的现有受管 Worker，挂载该中心指令和记忆；外部回复仍从主 Router 发出。

`SHARED_WITH_GLOBAL` 的召回结果先排本中心，再补 CORE/USER/pinned 全局偏好；`HUB_ISOLATED` 仅读取本中心记忆并使用固定安全身份说明。没有另建记忆库或隔离枚举。指令仅经主人管理接口修改，自动打标和模板整理不能写指令。

### 对话标签

| 方法与路径 | 请求/响应 |
| --- | --- |
| `GET /v2/tags?hubId=<id>&conversationId=<uuid>` | `{tags:[ConversationTag]}`；两个筛选都可省略；无 hubId 时只读 global 标签 |
| `POST /v2/conversations/{id}/tags` | `{hubId:null,tag:{name,templateId:null,attributes:{...}}}`；人工添加/修正，返回锁定的 ConversationTag |
| `DELETE /v2/conversations/{id}/tags` | JSON body `{hubId:null,name:"dev/amber"}`，返回 `{removed:true}`；用 body 支持包含 `/` 的标签名 |

示例：

```json
{
  "conversationId":"conversation-uuid",
  "scopeId":"coding",
  "name":"dev/amber",
  "templateId":"bug",
  "attributes":{
    "repo":{"type":"TEXT","value":"amber"},
    "status":{"type":"STATUS","value":"排查中"},
    "link":{"type":"LINK","value":"https://example.org/issues/42"}
  },
  "userModified":false,
  "updatedAtMs":1793460000000
}
```

名称执行 NFKC、去首个 `#`、转小写、空白转 `-`，限 1..80 字符、最多两级，字符为 Unicode 字母/数字和 `._-`。每次自动提取最多 3 个标签，每个标签最多 12 个属性。属性类型为 `TEXT | DATE | STATUS | PERSON | LINK | NUMBER`：日期必须为 ISO 日期，链接仅 http(s) 且无 userInfo，数字必须是有限 JSON 数值。属性键和字符串值先经 CredentialRedactor；敏感键、已脱敏值、无效类型不会进入属性存储。存在模板时只保留模板中类型匹配的字段。

主人修正以 `(conversationId,scopeId,name)` 锁定，后续模型不得覆盖。删除标签同时删除该对话的旧抽取证据并写负反馈屏蔽；模型不能加回同名标签。主人主动再次 POST 可解除这条删除屏蔽并重新锁定。人工属性修正也替换旧抽取证据，避免旧值继续参与模板统计。

完成普通 Router 对话、同步兼容入口的纯文本回复、或受管 Worker 成功结束时，后台队列通过现有 CloudModelClient 提取标签。只送最近一轮 user/assistant 的 Text，不送 Tool、Reasoning 或原始输出；模型没有工具。Worker 标签写入所属 agent 作用域，Worker 汇总不再提取到 global。DISABLED/POLLUTED 会话不调用标签模型；写入前再次检查当前模式。已处理 assistant turn ID 持久去重，空提取也去重。

接受轮次时先在同一个 SQLite 文件的 `pending_tag_turns` 写入 `(turnId,scopeId)` 唯一记录，保存对话 ID、原作用域、脱敏后的本轮 Text 与接受时间，不保存整段历史、Tool 或 Reasoning。随后只用内存信号唤醒后台消费者。冷启动会恢复未完成项；标签、观察、`tagged_turns` 完成标记和待处理项删除在同一事务中结算，空提取也结算。处理中取消/退出保留待处理记录，完成的轮次不因重复回调或再次启动重新请求。重放按原接受时间参与 14/30 天统计，不把重启当成新观察。

恢复时及落库前再次检查会话记忆模式；已删除或禁用记忆的对话丢弃待处理项。用户锁定与删除负反馈继续优先，合集升级确认同步转移其待处理项；旧作用域的在途返回不能写回旧中心。模型/解析失败保留记录，只写不含原始响应的诊断，本进程不反复请求，下一次重启可再次尝试。

Main 通过现有 CloudConfigLoader、EnvelopeCredentialVault 和 KmpProviderModelClient 创建配置客户端：`model.provider / model.id / model.base_url / model.api_key` 对应 `AMBER_MODEL_PROVIDER / AMBER_MODEL_ID / AMBER_MODEL_BASE_URL / AMBER_MODEL_API_KEY`。支持 `openai`（含兼容协议）及 `claude`，Key 缺失或配置无效时在网关开放前报错；不会隐式回显。`model.provider=echo` 仅为显式开发选择，不生成智能标签。主密钥需通过既有主密钥变量/文件/systemd credential 明确配置，Main 拒绝隐式开发默认主密钥。同一生产适配器调用链用于 Router、默认 Worker、标签提取和同义模板整理；有工具的请求同时带 TOOL 能力标志，标签请求不声明工具。具体启动说明见 [cloud-daemon README](../../cloud-daemon/README.md#21-本地-jvm-启动)。

云端当前没有标题/图标辅助调用，仍在完成后单独提取，会增加辅助模型调用；标题生成捎带先保留为后续优化。本地验证使用 loopback HTTP stub、假 Key 和临时库，覆盖两种生产 provider 协议、处理中取消/重建内核补跑及幂等；未调用真实 provider，未做操作系统强杀或生产磁盘故障验收。

### 模板与演化

| 方法与路径 | 请求/响应 |
| --- | --- |
| `GET /v2/tag-templates?hubId=<id>&includeInactive=true` | `{templates:[TagTemplate]}`；默认只返回活跃模板，中心读取本作用域与全局种子/模板 |
| `POST /v2/tag-templates/{id}` | `{expectedRevision,name?,archived?}`；只改名/归档状态，无字段编辑器；返回新模板 |
| `DELETE /v2/tag-templates/{id}` | `{expectedRevision}`；持久删除标记，保留负反馈及历史，返回新模板 |
| `POST /v2/tag-templates/{id}/merge` | `{targetId,sourceRevision,targetRevision}`；主人合并同作用域模板；返回目标模板 |

TagTemplate 字段为 `id,scopeId,name,fields:[{name,type}],aliases,aiSuggested,userModified,archived,deleted,mergedInto,revision,createdAtMs,lastUsedAtMs`。六个初始种子为 task/bug/decision/trip/reading/watch，使用与演化模板完全相同的存储和生命周期。`aiSuggested:true` 是客户端显示「AI 建议」的依据，不是待批准状态；生成后立即生效。

现有 proactive 巡检周期检查持久调度时间：

1. 每天归档 60 天未使用的活跃模板，再进行确定性演化。同一自由标签在同一作用域近 30 天至少有 5 次观察；自动提取按 completed turn 去重，人工修正替换该对话旧证据，重复回调不计数。字段名与类型在至少 60% 观察中一致才算稳定；至少 60% 观察同时具有两个这样的稳定字段时，直接建立带类型模板。现存自动标签会按字段类型重新分类，人工标签不改写。活跃模板总上限为 30（含种子和所有中心）。
2. 每周调用现有模型抽象识别同义模板，各作用域分别请求。模型只能合并名称语义相同且字段集合完全一致的未被用户修改模板；实际落库再次检查 revision 和 userModified。主人合并可取兼容字段的并集，同名字段类型冲突返回 400。
3. 主人改名保留旧名为别名；合并保留源别名与 tombstone；删除保留 tombstone。AI 不得把主人改名、合并或删除的模板再生成回来。主人编辑刷新 lastUsedAtMs；60 天归档只改变活跃状态，不改名或改字段，不自动复活。人工标签和模板编辑优先于并发模型快照。

本期合集按同作用域的规范标签精确聚合，不引入 embedding、图数据库或混合语义聚类。

### 合集、升级提示与事件

| 方法与路径 | 请求/响应 |
| --- | --- |
| `GET /v2/collections?hubId=<id>` | `{collections:[{id,scopeId,tag,conversationIds,promotionId,promotedHubId}]}`；最近 14 天按标签聚合的视图 |
| `GET /v2/hub-promotions?hubId=<id>` | `{promotions:[{id,collectionId,scopeId,tag,conversationIds,createdAtMs,hubId:null}]}`；仍满足阈值且未确认的提示 |
| `POST /v2/hub-promotions/{id}/confirm` | 无 body；主人明确确认，返回带 hubId 的升级结果；重复调用返回同一结果 |
| `GET /v2/supertag-events?after=0` | `{events:[{sequence,kind,subjectId,createdAtMs}],nextCursor}`；按序最多 100 条；下次以 nextCursor 作为 after，无长连接 |

某合集近 14 天有至少 4 个不同 conversationId 时，落库一次 `hub.promotion_suggested`。主时间线始终只算一个对话，不能靠重复聊天凑满四个。不会因阈值满足自动建立中心。确认时重新检查当前窗口，不足四个返回 409；用当前成员建立确定性中心 ID，继承来源中心的隔离策略（global 来源默认 SHARED_WITH_GLOBAL）。

确认后转移窗口内成员的标签、负反馈、关联记忆和对话归属，防止旧 agent 再复用已转移的 Worker session。跨存储步骤以确定性 ID 实现可重入，重复确认不建第二个中心。不会转移无关记忆，也不会给新中心增加工具授权。主时间线的对话身份和全局历史记忆始终保留；即使它出现在合集，也不把整个主时间线绑定到新中心。来源中心的专有模板不跨作用域复制，转移标签保留带类型属性并退为自由标签，后续按新作用域规则演化。

事件还包括 `conversation.tags_updated`、`tag_template.created/updated/merged/archived` 和 `hub.promoted`。事件只给对象 ID 与时间，客户端经相应受认证接口读取详情；这是本期 SQLite 轮询事件，不宣称实现 P4 HLC 同步。

本期不实现四端 UI、小说/工作区文件迁移、中心决策账本、embedding 聚类或真实云部署。定点验证：

```bash
HOME=/Users/arquiel JAVA_HOME=/opt/homebrew/opt/openjdk@21 ./gradlew :cloud-daemon:jvmTest \
  --tests 'app.amber.cloud.supertags.*' \
  --tests 'app.amber.cloud.AgentRegistryAndMemoryTest' \
  --tests 'app.amber.cloud.AgentCentricApiTest' \
  --tests 'app.amber.cloud.CloudRouterIngressTest'
HOME=/Users/arquiel JAVA_HOME=/opt/homebrew/opt/openjdk@21 ./gradlew :cloud-daemon:fatJar
```
