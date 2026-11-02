# Amber 异步 ReAct / Thread 有界只读核对

2026-11-01；源码根 `/Users/arquiel/.synara/worktrees/8eddb6c10d7d`，分支 `synara/hub-supertag-backend`，HEAD `d752de94ce641f6c85fc259dad5ca4345080180a`。核对开始工作区干净；`a60523b1`、`4deec03e` 均为当前 HEAD 祖先。本文是本轮唯一新增文件，不改实现、不构建、不部署、不读取真实凭据。

**结论：已有 Router/Worker 后台并发与部分话题直通；尚未完成 DSH 式异步 ReAct 和 iOS/macOS 持续云主对话闭环。** “收到”是接收确认；任务 202 是受理回执；它们均不能证明新指令已被模型消费或目标已完成。

对照原文：Library `research/deepseek-super-agent-article.md`，来源 https://mp.weixin.qq.com/s/zoS7GlReWPhfCjENGxXCdg （2026-10-31 归档）。本轮实际读取归档正文，重点为第 2 节、第 3.2 节（归档行55–63）和第 4.1 节（行81–86）：稳定话题的后续事件直通订阅 Worker；耗时工具 start 立即返回，完成另投事件；新输入在推理步结束后消费，不必等后台工具完成。原文亦说明其异步机制当时尚未默认开启，不能把论文描述当作 Amber 验收。

锚点前缀：`C = cloud-daemon/src/jvmMain/kotlin/app/amber/cloud/`；`IM = cloud-channels/src/jvmMain/kotlin/app/amber/cloud/`；行号均对应上述 HEAD。

| 对照项 | 状态 | 当前真实行为 / 边界 | 关键锚点 |
|---|---|---|---|
| 飞书、Telegram 生产入口 | 已实现（代码） | Main 注册连接器到 CloudRouterIngress；保存主历史与 source 后返回模板 ACK，Router 后台决定。未实测真实 IM 时延。 | `C/Main.kt:58`；`C/runtime/CloudAgentKernel.kt:371`；`C/runtime/CloudRouterIngress.kt:27` |
| Router 与 Worker 并发 | 已实现基础，部分 | Router 不等 Worker 模型/工具或空闲槽位；默认3槽，溢出排队。但 Router 语义回合全局串行，新的语义回答仍等前一 Router 回合及其只读调用/通道发送。 | `C/orchestration/CloudRouter.kt:273`；`OrchestrationWorkQueueCoordinator.kt:327`；`DefaultCloudOrchestrationKernel.kt:123` |
| 原生持续主对话 | 缺失 | 后端无原生主对话 POST/跟进入口；`POST /v2/work-items` 直接建任务，绕过 RouterIngress，也不把用户文字追加到主历史。不能将其解释成主对话已上云。 | `C/gateway/NativeTaskApi.kt:36`；`AgentCentricRoutes.kt:55`、`:68` |
| Worker 新输入消费 | 部分 | steer/Thread 直通会保存消息；Worker 只在下一次循环顶端重读历史。正在推理/同步长工具时不消费；若本步直接 task_finish 或无工具结束，尚未消费的补充也无自动再唤醒。 | `C/orchestration/OrchestrationModelAdapters.kt:138`；`OrchestrationRouterBridge.kt:86`；`OrchestrationWorkQueueCoordinator.kt:391` |
| 耗时工具 start/stop 与完成事件 | 部分，生产闭环缺失 | process_run(background=true) 真能立即返回进程ID，可 wait/stop；但完成仅进内存 Deferred，无自动完成事件/Worker 唤醒。旧 startAsyncTool 有完成事件，但无实际工具注册/start 调用者，不能以其测试证明生产贯通。 | `C/tasks/TaskExecutionTools.kt:28`；`TaskProcessRunner.kt:45`；`C/orchestration/OrchestrationWorkQueueCoordinator.kt:447` |
| 稳定 Thread / Agent / Session 复用 | 部分 | 多对多订阅真实可达；同 agent、重叠话题的已结算 session 可复用。私聊通常无 threadKey，跨通道没有任务话题映射；无 thread 群用整群 key，不能自动保证新话题另派。 | `C/orchestration/OrchestrationRouterBridge.kt:21`；`WorkerSessionLifecycle.kt:5`；`C/agents/AgentRouterCoordinator.kt:47` |
| 快速叫停 | 部分 | 原生 `/cancel` 绕过 Router 模型，可取消 Worker Job，finally 清理任务进程；自然语言“停止”没有独立控制快路径。Router 的 async_tool_stop 控制旧 async 句柄，不是 task process ID 或 WorkItem 取消。 | `C/gateway/AgentCentricRoutes.kt:80`；`C/orchestration/DefaultCloudOrchestrationKernel.kt:199`；`CloudRouter.kt:588`；`C/runtime/CloudAgentKernel.kt:254` |
| 幂等 / 重启 / 结果归位 | 部分 | 原生 task requestId、WorkItem/订阅、历史、结算文档持久化；Router 待消费队列/路由地址、async/process句柄为内存。重启恢复任务不等于恢复 ACK 后未消费事件及结果投递。 | `C/gateway/NativeTaskApi.kt:43`；`C/orchestration/OrchestrationRouterBridge.kt:18`；`CloudRouter.kt:194`；`OrchestrationWorkQueueCoordinator.kt:81` |
| 双端 UI 与整条交互验收 | 未完成 / 未验证 | iOS 是独立任务提交、轮询、取消；macOS 当前交付的出站云客户端是配对/配置管理。未验证“长任务→问别的→补充→叫停→结果归位”。 | 下文客户端快照与证据 |

## 1. 入口与快速响应的实际等待范围

Telegram `IM/channels/TelegramChannel.kt:157–186`、飞书 `FeishuChannel.kt:271–311` 经去重/主人门禁后调用附加 ingress，再发送返回的 ACK；飞书 webhook 的 HTTP 200 在这些动作后返回，不能等同于独立的持久队列 ACK。`CloudRouterIngress.kt:33–49` 先持久主历史，`OrchestrationRouterBridge.kt:57` 再存 source，入内存事件队列后 kick。这里没有等待 Worker 完工。

Router 的 `running`/`loopMutex` 在 `CloudRouter.kt:273–295` 覆盖整个 drain/processTurn；`ModelRouterBrain.decide` 的模型及只读工具执行在 `OrchestrationModelAdapters.kt:36–95` 串行等待。新消息可入队并返回 ACK，语义回复却不会抢占当前 Router 推理。`CloudRouterIngress.kt:25` 还有全局 conversationMutex，覆盖历史读写/确定性压缩/记忆准备，未持有到模型推理期间。数据库同步锁、提交 mutex、通道 I/O 仍可能增加延迟，不能承诺硬性毫秒级响应。

任务提交持久化后 pump 队列并后台 launch，槽满则 QUEUED，不等槽位释放。提交 mutex 覆盖派单及初始 activity 回调，activity/status 发送也不是持久独立 outbox；不应声称所有入口已完全脱离慢通道 I/O。Router 本身不占 Worker 槽位。

## 2. Worker ReAct、steer 与停止

生产 runner 每步 `loadConversation → generateReply → 逐个 executeWorkerTool → appendWorkerMessage`（`OrchestrationModelAdapters.kt:138–182`）。输入在已发出的模型请求中不会热注入，也没有在模型结束后、执行本批工具前再消费输入的控制检查。steer 给活跃任务追加历史并尝试 launch；`activeWorkerJobs[workItemId]` 已活跃时 launch 直接返回（`DefaultCloudOrchestrationKernel.kt:123–146`），不会并发启动第二个同任务推理。

长工具通常仍同步 await：process_run 默认同步，process_wait 可等待至60秒，HTTP/搜索/工具安装亦由当前工具调用等待。background=true 能让脚本继续运行而模型进入下一步，但它没有完成事件的收件箱/消费游标。Worker 若选择 process_wait，仍要等该调用返回才能看补充。后台完成后没有生产代码自动唤醒已闲置 Worker。文件历史投递与模型已消费是两件事，尤其最后一步结算前没有未消费输入屏障。

旧 `startAsyncTool/stopAsyncTool`（`OrchestrationWorkQueueCoordinator.kt:447–541`）确实有 Started、Job取消和完成事件，但当前源码的 start 调用只见于内核包装/测试，无 Worker 注册工具消费。其完成事件投到 Router 队列且 conversationId 是传入 sessionId，并不等于继续对应 Worker；句柄/状态也未持久化。不能用该测试替代实际 process/HTTP 的异步验收。

原生 `/cancel` 是现成可用的显式控制 API；先结算、通知/泵队列，再 `cancelAndJoin`（`DefaultCloudOrchestrationKernel.kt:199–205`），尚无独立于慢通知的停止时延保证。Worker finally 用 NonCancellable stopTask 清理其任务进程；进程工具另有超时和stop清理（`TaskProcessRunner.kt:79–101`）。Router 只有旧句柄 async_tool_stop，没有 cancel_work_item；“停一下”若命中 Thread订阅，会作为普通文字进入 Worker历史，不会立即触发取消。Router dispatch/steer/stop工具当前亦未填写结构化 parameters（`CloudRouter.kt:499–597`；`CloudToolRegistry.kt:44`、`:126`），真实模型控制选参可靠性不能由替身测试证明。

## 3. Thread、任务及跨通道关联

`AgentProfile.id` 是稳定执行/记忆归属；WorkItem 是可查询、可结算的目标记录；workerSessionId 是隐藏的模型历史；活跃执行 Job 以 workItemId 为键。steer 不另建 WorkItem。这里没有一个能持久追踪每次 steer 消费进度的独立 run/inbox 实体；不应把旧直接入口的 AgentRun 状态机当成当前 Worker 已接上的能力。

话题 key 优先 metadata.thread_key，否则 `channel:chatId:threadId`，群无 thread 时退化为整群，私聊无 thread 时为null。Telegram 解析 message_thread_id、飞书解析 root_id（对应连接器`:351`、`:515`）；IM 私聊共享 `PRIMARY_CONVERSATION_ID` 的历史（`IM/channel/ChannelSpi.kt:306`），但共享历史不建立跨 IM / 原生任务的同一话题映射。

已订阅 key 的新消息不含 `@` 就广播给所有活跃订阅任务（含QUEUED），不经 Router 新话题判别；含 `@` 强制回 Router，这也只是粗略分流。非 main agent 路由会自动带入事件 threadKeys；main Router dispatch 是否订阅依赖模型提交 thread_keys（`CloudRouter.kt:612`）；原生 NativeTaskRequest 没有 thread/followup字段，默认订阅为空。因此不能保证每次跟进复用同任务，也不能保证新话题另派。终态任务退订；session复用只允许同agent/重叠话题且无活跃占用。Worker没有可调用的退订/移交入口，原文所述超范围后交回Router仍未完整接线。

## 4. 事件持久性、幂等与结果归位

原生 task 使用 deviceId+requestId 幂等，保存 source/operationResult；任务、订阅与结算均有SQLite/文档存储。IM去重器是进程内最多1000条集合（`IM/channels/ChannelSecurity.kt:460`），source表用原始messageId主键且INSERT OR REPLACE（`C/orchestration/CloudOrchestrationStore.kt:62`、`:187`），不具备完整的 channel/chat/event 身份和持久消费回执。

`pendingRouterBatchQueue` 是内存 ArrayDeque，source保存后没有消费offset/ack/replay；drain先清队列。重启只遍历已有STARTING/WORKING任务重启runner并pump排队（`OrchestrationWorkQueueCoordinator.kt:81–102`），不会从已接收但尚未派单的source重建Router事件，也不会重建process/async句柄。因此可能“历史还在，接收过的指令却没有后续处理”；不能将源码恢复逻辑表述为断电/副作用exactly-once通过。

结算文档和批次wakeClaim可持久保存，终态不回滚（`OrchestrationRollupCoordinator.kt:94–165`、`:188–221`）。IM同进程内有taskAddress/batchAddress，批次结束回Router再由emit写主历史。地址映射、lastOwnerAddress均为内存；原生提交不建立这些映射，也不写主用户消息。`processTurn` 仅在address非空时emit（`CloudRouter.kt:305–307`、`:382`）；新启动的纯原生服务可查询 resultMarkdown，却没有主时间线结果归位保证。`GET /v2/timeline` 只是主历史分页投影（`AgentCentricApi.kt:60`），当前没有SSE/WebSocket/持久向前事件游标或原生跟进API。

## 5. 客户端真实消费与验证证据

- iOS稳定交付对象 `cc717edb`（云任务能力来自cc7189af）：`iosApp/iosApp/MacGatewayCloudTasks.swift:302–341` 有agents、任务提交/查询/取消、activity及timeline方法；实际store消费activity、任务detail，并每秒轮询活跃任务（`:418`、`:434`、`:557`、`:585`）。timeline方法未找到UI/store调用者。独立compose sheet在 `MacGatewaySettingsView.swift:53`；这是任务入口，不是主对话Router入口。
- iOS当前redesign树 `/Users/arquiel/.synara/worktrees/9432c2aa6f66`，HEAD `af92b304`，本轮只读时干净：`Chat/Composer/ChatViewComposer.swift:276–278` 的后台交办按钮打开任务中心；`ChatView.swift:310` 呈现该sheet。主发送仍进 `Chat/Session/ChatConversationMutations.swift:19` 的本地生成/steer队列，不向CloudRouter提交。UI变化不构成新增云对话API。
- macOS云配置交付对象 `6d26cdf4`：`macApp/AmberMac/Runtime/DesktopCloudSelf.swift:160–168` 为pair/status/unpair；`DesktopCloudConfigSync.swift:299`、`:336`、`:357` 为配置GET/POST/公钥。该交付对象未找到/v2/work-items、agents、timeline消费。当前e08工作树有别人的store/tests修改，本轮仅参考已提交对象、未改写；本机Gateway/本机AgentTasks不等于出站云任务消费。
- 历史P2.5/P2.6曾有替身测试通过记录：ACK在挂起模型前返回、线程多对多直通、内核async start/stop、Router忙期batch。当前源码 `CloudRouterIngressTest.kt:83` 仍有2秒ACK断言，但`:93`仍期望普通无工具回答COMPLETED，与8809438b新增必须task_finish的当前runner语义不一致；不能将旧套件总绿当作当前完整验收。
- 本地现有 `cloud-daemon/build/task-tool-delivery/evidence/jvmTest/TEST-app.amber.cloud.NativeTaskHttpTest.xml`（2026-11-01T06:53Z，4项无失败）覆盖假OpenAI/Claude任务、请求幂等/重启结果和token复用、鉴权取消及终态不回滚、provider拒绝。AgentCentricApiTest同目录有通过记录；d752阶段已有受影响回归及实际fatJar+loopback provider/真实CSV进程产物证据。这些只证明各自路径，未覆盖本轮整条异步场景。
- 本轮未运行测试/探针/构建，未访问云主机、真实IM或付费模型，未装客户端；线上版本与行为不在本次证据内。Linux执行隔离依赖也不因本报告而视为已验收。

## 最短补齐建议（仅建议，不是本轮实施）

1. **统一原生主对话与话题控制入口。** 在现有配对鉴权上增加主对话消息提交、指定workItem/topic的补充与显式停止；iOS/macOS主对话消费同一Router入口与主时间线。新任务与跟进通过稳定topic/workItem关联；跨通道显式绑定，保留现有独立task API兼容。先补全实际Router控制工具schema，不另建协调层。
2. **把现有进程后台模式接到Worker事件消费。** 复用process_run(background)/wait/stop，完成/失败/停止投到所属任务收件箱并唤醒；在推理边界消费补充，结算前确认无未消费输入。长工具采用start+完成事件，停止控制先触发取消/子进程清理，再处理慢通知。无需重写模型框架。
3. **补接收/消费/结果投递的持久回执。** 用现有SQLite补事件唯一身份、待消费/已消费状态和投递目标；ACK后可恢复，事件幂等消费；Worker结果先持久归主时间线，再异步通知并提供客户端增量查询。复用现有WorkItem/订阅/wakeClaim，不建设新消息平台。

一条端到端验收：已配对客户端主对话提交受控长CSV任务A（进程保持运行）→A未结束时问无关问题B（先收到持久ACK，再有独立语义回答，不等A完成/槽位）→明确补充A“再输出平均值”（相同workItem/session，记录补充已消费，不创建重复Worker）→主对话显式叫停A（不等同步长工具返回，确认进程与后代停止）→A取消结果、实际已有产物和B回答归各自任务及主时间线。中途断开客户端并重连/重启daemon一次，重送同requestId验证无重复任务、补充不丢、终态不变；另用假provider挂起推理验证补充在步边界消费，不能只验证模板ACK。时延门槛在实施前固定，分别测ACK、语义回复、补充消费、物理停止，不能以一个数字概括。
