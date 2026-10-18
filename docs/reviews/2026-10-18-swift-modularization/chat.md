# Chat 架构审查与 <=1500 行拆分建议

只读审查；2026-10-18 当前工作树。已读 iosApp/AGENTS.md。没有运行构建/测试，没有修改产品源码。ChatView.swift、MessageBubbleView.swift 有现存 WIP，实施必须保留。

## 当前生产路径与已有模块

- AppShell.swift:77 创建 App 持有的 ChatViewModel；ChatViewModel.swift:4184–4223 的 generateResponse 总是调用 kernelRunHost.start；Host 在 ChatKernelRunHost.swift:1804 构造 ChatRunKernelAdapter，Adapter.swift:272 构造 IOSAgentToolEngine。不能按旧 CGC 注释认为仍有两套前台模型工具循环。
- ChatView.swift:1568 无条件构造 NativeChatTimelineView；SubAgentConversationView.swift:72 也用它。ChatSwiftUIMessageList 属非默认回归路径，不能替生产列表背书。
- 值得保留的具体 module：ChatKernelProjection.swift（85 行，消息/审批投影）、ChatProviderConfiguration.swift（229 行，provider 解析校验）、ChatContextSupport.swift（742 行，运行时语境/记忆）、ChatGenerationSupport.swift（553 行，共享请求策略）、ChatIntelligentUISupport.swift（215 行，任务 UI 事务输入）、ChatComposerViews.swift（492 行）、ChatArtifactShelfState.swift（37 行）、ChatArtifactActions.swift（170 行）、ChatToolCallParsing.swift（53 行）、ChatStreamPrimitives.swift（256 行）。这些不是都应再包装一层。
- rg 查不到散落的 ChatViewModel/ChatKernelRunHost/ChatView extensions；ChatToolRuntime 只有 NovelCreationAmberBridge.swift:3 的协议符合性。问题主要是大对象仍包揽多个 owner，不能只用 +Foo extensions 分散位置。
- ChatToolRuntime 同时供 foreground、background、NovelDiscussion 消费；应保留既有适配入口和不同执行策略。不能为了复用把后台的批准限制抹平。

## 已证实的结构问题（不等同于已复现的功能 bug）

1. **ViewModel 与 Run Host 的 seam 仍很宽。** ChatGenerationSupport.swift:95–168 的 ChatGenerationBindings 有 40 个闭包字段，包含逐个审批 setter、持久化、run ledger、LiveActivity、MiniApp transaction、上下文注入、steer/mailbox。ChatViewModel.swift:1264–1531 在构造它时解释每个状态写入和会话归属；Host.swift:2229–2245 又依赖这些闭包的顺序执行终态。新增一种审批/终态需要跨 VM、Bindings、Projection、Host、Adapter 同步变更。建议先保留外部 interface，内部收敛为已有 ChatKernelProjection 加会话持久化、上传准备、inbox、run completion 等具体 owner；不要引入另一个 40 字段 dependency bag。

2. **ChatToolRuntime 混合了工具路由和领域执行状态。** ChatToolRuntime.swift:373–480 一并拥有 skill/soul/MCP/recipe/plugin prepared candidates、recipe checkpoints、iSH 授权集、subagent 并发计数、JS cell registry；:1585 为统一分发，:3804 为插件执行，:4712 为 recipe 推进，:6707 为 JS cell 运行。清楚的切口不是每 1000 行切一次，而是 plugin/recipe/JS/session-read 等各自成为带状态的具体 module，runtime 保留验证/分发/适配。prepared candidate 与消费它的 finisher 必须同 owner、toolCallId 单次取走，动态目录仍按 run 固定快照。

3. **Host 的多种生命周期混在同一个对象里。** ChatKernelRunHost.swift:103–177 同时放文本 run、直接生图、durable cursor、审批 continuation、keepalive、终态 claim；:481–982 是直接生图，:1922–2203 是逐轮上传准备，:2222–2869 是终态与收尾。这些不是随意搬走的普通 helper：必须保留 runId 唯一所有权、先 durable 后外部 completion、cancel/late-callback 排他性。推荐把独立生图执行、上传准备、审批等待、durable provider 抽出，终态写入按单一 module 收口；Host 保持编排和 run 身份的唯一 owner。

4. **Adapter 有真实的并发 seam，扩散可见性会增加风险。** ChatRunKernelAdapter.swift:129–168 中 working/snapshotSeq/firstVisibleDeltaRound 使用 nonisolated(unsafe)，:836–858 的 nestedApprovalBusy/continuations 确保并发 exec 一次只显示一张审批。:956–1360 同时承担普通和嵌套审批恢复。建议把审批恢复和嵌套调用各自提取成具体 owner，Adapter 保持 working 权威快照、取消及最终发布序列。不应通过把 private 全改 internal 或新增 unchecked Sendable 让跨文件编译过关。

5. **ChatView 的 UI 生命周期与业务副作用耦合。** ChatView.swift:738–794 包含文件授权 → Workspace import → preview attach 的异步事务；:1208–1306 执行 recap、artifact pin/continuation/export；:1433–1471 计算列表/产物投影；:1614–2306 组织 composer/approval。提取附件导入控制器与 composer 容器有真实 locality 收益，不能把所有 @State 迁到一个巨型屏幕 model。现有 ChatTimelineSignalHost、稳定 artifactPinHandler、可判等 chatListSummary 是明确的渲染约束，应保留。

渲染 6 文件的独立分析已完成，另见 chat-render.md。

## 逐文件拆分映射（目标规模是估算，不是已实施行数）

### ChatViewModel.swift — 5293 行

目录建议 Chat/Session、Chat/Composer、Chat/Generation；保持单个 iOS target，先不额外建 Swift package。

| 目标文件/module | 内容与现有代码位置 | 目标规模 |
|---|---|---:|
| ChatViewModel.swift | 保留屏幕可观察 interface、当前会话选择、用户命令转交、依赖组合 | 900–1300 |
| ChatConversationRunState.swift | :12–95 的 run presentation 与 conversationId；run registry 只持有此对象与 Host | 150–250 |
| ChatConversationRunRegistry.swift | :987–1015 的按会话 Host/state 索引、activeRun 查找，当前选择不能成为异步结果归属来源 | 150–300 |
| ChatConversationPersistence.swift | :1960–2056 的 baseline/CAS、regeneration variant 提交；与 branch mutation 整理至同 owner | 450–650 |
| ChatConversationRecovery.swift | :1566–1958 的 reload、stale search/pending approval、ledger recovery 与 unknown reconcile | 450–600 |
| ChatConversationMutations.swift | :2058–2484 的发送/Watch/直接生图入口及 :3894–4126 的 edit/delete/variant/regenerate；拆出 IntelligentUI 专属提交至既有支持邻近文件 | 650–900 |
| ChatConversationInbox.swift | :2486–2828 的 steer、mailbox、child-result wait/wake；保留先 mailbox 后 steer | 400–550 |
| ChatComposerAttachments.swift | :2830–3101、:3447–3688、:4354–4399 的 selected-file/vision/图片附件任务 token 和回写归属 | 650–850 |
| ChatAuxiliaryGeneration.swift | :3103–3366 的 title/list preview/suggestions；取消 token 与 task 同 owner | 300–400 |
| ChatGenerationRequestBuilder.swift | :4184–4352 的请求上下文与 :4836–5111 的 params/tool exposure 构造；复用 ProviderConfiguration/ContextSupport | 600–800 |
| ChatMiniAppOutputCommitter.swift | :4403–4600 的提交、回滚、workspace 同步，复用 ChatMiniAppOutputApplication | 250–350 |
| ChatRunComposition.swift | :1050–1150、:1235–1531 的 runtime/Host 组合与绑定过渡适配；分组缩窄绑定而非再造大 owner | 450–600 |

状态/可见性：ChatConversationRunState 继续 @MainActor @Observable；ViewModel 可观察属性沿原 interface 转接，不复制 messages、approval 或 isLoading。附件 task/token 由附件 module 独占；run registry 为 App 持有，退出 ChatView 只解除观察。跨会话持久化一直携带原 conversationId/state/baseline。现有 DEBUG 测试入口可暂时转发，后续测试逐步跨真实 module interface，不能把保存顺序拆散为多个无约束 setter。

验证：ChatViewModelConcurrentConversationTests、ChatSendDeferredGenerationTests、ChatViewModelSelectedFileContextTests、ChatViewModelGenerationParamsTests、IOSSteerQueueTests、IOSMailboxDeliveryTests、IOSChatKernelLoopRoutingTests；branch/persistence 变动加 IOSConversationStoreTests/BranchingTests、MiniApp transaction 定点测试。

### ChatToolRuntime.swift — 7705 行

目录建议 Chat/Tools，领域执行复用现有 IOS*ToolService/Executor。下列是内部 implementation 文件/具体 owner，**不是每项都加 protocol 或新的可替换层**。

| 目标文件/module | 内容 | 目标规模 |
|---|---|---:|
| ChatToolRuntime.swift | 验参、冻结执行策略、统一 dispatch、外部 foreground/background/novel interface、具体 owner 组合 | 800–1200 |
| ChatToolInvocation.swift | :1–372 的 pending/result/prompt/recipe 状态值，按所属领域再下放 | 250–400 |
| ChatToolExecutorAdapters.swift | :716–1397 的 foreground/background/novel 注册与 :7568–7705 的 executor adapter；后台限制保持显式 | 850–1100 |
| ChatToolApprovalCompletion.swift | :1746–2226 的通用批准/拒绝完成、:7031–7164 的 ledger/result 回填；具体 prepared state 归领域 owner | 600–800 |
| ChatLocalToolOperations.swift | search/workspace/terminal/memory/image 的入口适配与批准策略，复用已有 executor；不重新实现工具本体 | 800–1200 |
| ChatDynamicToolLifecycle.swift | :3326–3802 的 import/lifecycle 分发与 prepared candidate 接线，复用既有 skill/soul/recipe/plugin stores | 600–900 |
| ChatPluginExecution.swift | :3804–4589 的 pinned plugin、JS/remote host invocation、capability/health/outcome unknown；plugin candidates 同 owner | 850–1100 |
| ChatRecipeExecution.swift | :4590–5770 的推进/暂停/恢复/checkpoint/ledger，步骤 gate 另见下一项 | 900–1200 |
| ChatRecipeApprovalPolicy.swift | recipeStepGate 与 workspace/webmount/Apple preflight；作为 recipe implementation，接受具体既有依赖 | 250–400 |
| ChatSessionReadTool.swift | :2581–2968 的 search/read/page/JSON 限制 | 400–500 |
| ChatRuntimeStatusTool.swift | :2969–3120 的运行时状态投影 | 180–250 |
| ChatWebGoalTool.swift | :5940–6202 的 bounded web goal loop 与 probe/action 映射 | 300–400 |
| ChatJavaScriptTool.swift | :1640–1721 的注入白名单/scope + :6683–6860 的 exec/wait；会话 cell registry 仍为既有独立 owner | 300–450 |
| ChatSubAgentToolAdapter.swift | dispatchAdvanced 中 subagent/council/orchestration 与 :6861–7030 parent tool/approval；保留已有 runner/pool | 450–700 |
| ChatMcpToolAdapter.swift | :7149–7240 MCP 扩展名字/调用/网络策略 | 150–250 |

状态/可见性：Runtime 与这些拥有可变审批/执行状态的 module 仍 @MainActor；IOSExecutionPolicyContext 的 TaskLocal 继续在真实入口与审批 finisher 周围包裹。锁保护的 prompt box 保留原线程契约。不会为了拆文件把所有方法扩为 internal：只暴露 execute/resume/take/discard 等真实 interface，domain prepared maps 私有。新 module 的输入是冻结 request/context/descriptor，不反向持有整个 ChatViewModel 或 Host。确定未使用代码只标记，不删。

验证：IOSToolRuntimeTests、IOSForegroundToolExecutorsTests、IOSToolArgumentsFailClosedTests、IOSExecNestedToolTests、IOSRecipeIntegrationTests（尤其双 mutation pause、checkpoint 失败、v1 pinned manifest/v2 promotion）、IOSPluginCommandTests、IOSMcpExpandedToolTests、IOSSessionReadToolTests、IOSRuntimeStatusToolTests；foreground/background 两路都必须过，不把同一条注册表强行复用。

### ChatKernelRunHost.swift — 3117 行

| 目标文件/module | 内容 | 目标规模 |
|---|---|---:|
| ChatKernelRunHost.swift | runId/phase/task 的唯一 owner、start/cancel/handoff 编排、与 Adapter 连接 | 800–1100 |
| ChatImageToolRun.swift | :481–982 的直接生图 start/ledger/取消/unknown、image task/token/claim | 550–700 |
| ChatRunUploadPreparation.swift | :1894–2204 的每轮上下文、压缩、image prompt、memory recall；GenerativeUI repair 状态与请求计划 | 450–650 |
| ChatRunApprovalSession.swift | :1408–1628、:1807–1893 的 request/run 匹配、continuation 单次恢复与 UI prompt 发布 | 350–500 |
| ChatRunTerminalCommit.swift | :2220–2870 的 persist → durable terminal → 系统展示/收尾顺序；显式结果回 Host 清理 | 650–850 |
| ChatKernelDurableTextProvider.swift | :1311–1407、:2949–3117 的 streaming provider cursor/checkpoint/detach adapter | 300–450 |
| ChatRunProgressPresentation.swift | phone progress/Jev/keepalive 展示，仅在 current run 验证之后调用 | 200–350 |

注意：不要分裂 durable status 与 Host lifecycle 的所有权；terminal module 返回结果，Host 单次提交 phase/identity 清理，不能同时让多个对象各有 didFinalize。模型轮次临时变量与快照随请求对象走，@MainActor 延续，KMP 类型跨 actor 的现有盒必须保留使用契约。

验证：IOSChatKernelRunHostTests 已有 completed terminal sequence、CAS fail suppress external completion、cancel during approval、exact stream tail、handoff persistence in flight、direct image ledger failure、noncooperative tool cancel；加 IOSChatBackgroundExecutionTests/SuspensionTests 的相关子集，真实 background/LiveActivity 仍需设备。

### ChatRunKernelAdapter.swift — 1686 行

| 目标文件/module | 内容 | 目标规模 |
|---|---|---:|
| ChatRunKernelAdapter.swift | run/cancel/detach、driver、working 与 snapshot 发布顺序、engine hooks | 850–1150 |
| ChatKernelApprovalResolver.swift | :935–1511 的 candidate take、Started → claim → finish → Finished、rePause/outcomeUnknown | 550–700 |
| ChatNestedToolRunner.swift | :688–928 的 nested synthetic call、ledger、FIFO 审批队列 | 250–350 |
| ChatKernelTransferValues.swift | :1597–1686 的预算、锁盒与 narrow Sendable carriers，优先按使用归入上述文件 | 100–150 |

Adapter 继续是 working/取消/终态唯一 owner；ApprovalResolver 不直接持有全部 Adapter；nested owner 只持有 FIFO 等待队列，其 completion 返回 typed result 由 Adapter 应用。不能同时移动 actor 与改处理顺序。保留 Callbacks/RunRequest 外部形状作为迁移接口，内部减小上下文后再改调用端。

验证：IOSChatKernelLoopRoutingTests、IOSChatKernelRunHostTests、IOSAgentToolEngineKernelHookTests、IOSExecNestedToolTests（parallel approvals once each）、IOSRecipeIntegrationTests（approval resumes next tool catalog）、IOSToolLoopGuardTests。

### ChatView.swift — 2390 行（已有 WIP）

| 目标文件/module | 内容 | 目标规模 |
|---|---|---:|
| ChatView.swift | 屏幕组合、Navigation/environment、事件接线、messageList，不直接承接附件 IO | 700–1000 |
| ChatComposerContainer.swift | :1614–2306 的输入/审批/工具开关面板；复用 ChatComposerViews、已有审批卡 | 750–1000 |
| ChatAttachmentImportController.swift | :738–887、:1062 附件 importer/photo/camera 的来源会话、grant、任务与错误归属 | 250–400 |
| ChatScreenPresentation.swift | :1–169 的值/编辑sheet + :890–1061 的 browser projection + :1315–1561 的 summary/island policy | 500–700 |
| ChatArtifactPresentation.swift | :1208–1306 recap/artifact actions，接现有 ArtifactShelfState/Actions/Export；只提取本屏幕协调 | 150–250 |

@State 留在真正持有的子 View/控制器，使用绑定或可判等值；不把流式 messages 提升到根 View body，保持 ChatTimelineSignalHost 与稳定 environment handler。composer focus、picker presentation、scroll intent 的 ownership 明确，抽子 View 不能额外重建 controller、丢输入框身份或带动全列表失效。

验证：三项项目强制列表测试 + ChatTopBarLayoutTests/ChatTopBarDockTests、IOSChatBottomOverlayLayoutTests、ChatArtifact*、ChatSendDeferredGenerationTests、ChatViewModelSelectedFileContextTests；模拟器输入/切会话/附件完成后回原会话；键盘、安全区、120Hz、LiveActivity 行为仍需真机。

## 建议实施顺序与 gate

1. 在当前 dirty 工作树审查基础上先保留 WIP；正式实施采用明确的集成分支/工作树来源，不复制遗漏本地更改。先固定当前生产流程测试基线，保存物理行数清单。
2. **低耦合先行**：渲染混文件、值类型、SessionRead/RuntimeStatus/WebGoal 等已可看出输入输出的模块先拆；每个 PR/批次仍能编译、跑相关现有测试。一个文件完成就 <=1500，通常目标 600–1200 留增长空间。
3. **工具领域执行**：Plugin/Recipe/JS + executor adapters，按领域状态 owner 拆。foreground/background/novel 三入口对照，防止策略漂移。
4. **Host/Adapter**：先抽 provider/upload/image，后审批/terminal。每次只变一个状态 owner，保留事件顺序的现有测试，不并行修改同一大文件。
5. **ViewModel/ChatView**：在下层接口稳定后下放 inbox、attachments、persistence、request builder，最后收窄组合层。高频观察/输入框身份单独验证。
6. 物理行数 CI 限制（所有受管 Swift 文件，排除策略由总体审查确定）；扩展文件也计入。禁止靠删注释、挤多语句、重复巨大共享 state 或大量宽可见性满足门槛。最后仅对本次 diff 做一次可维护性检查。

成功标准不是“拆成 X 个文件”，而是：所有纳入范围 Swift <=1500；UI/runtime/storage/provider 的 owner 可定位；同一 run/conversation 的状态不复制；原生产调用链和真实错误/审批/终态契约通过；没有增加权限、删行为、偷偷切渲染默认路径。这里未执行这些验证，只给出了应复用的测试证据入口。


## 对 40 个 bindings 的二次判断：保留有效隔离，不为了数字缩接口

这是**值得收窄的混合 seam，不是 40 个闭包天然有错**。当前生产只有 ChatViewModel.swift:1265 一个 construction site，另两个是 IOSChatForegroundTestHarness.swift:438 和 IOSChatKernelRunHostTests.swift:280。测试可录制持久化、审批、terminal、LiveActivity 顺序，是现有深度和真实替换能力；不应把这一缝塞回 Host 的全局单例访问。

- **合理且要保留的隔离**：`recordRun` / permission claim / message baseline & persistence 隔离数据库副作用，`saveMiniAppIfPresent` 隔离带 rollback 的事务，`startLiveActivity` 隔离系统副作用，inbox drain 隔离邮箱/队列。它们不能被一个 `apply(event)` 事件总线或“session.snapshot”取代，否则 async 成功/失败与先后约束会被隐藏。
- **有实证可局部收窄的部分**：9 个 `setPending...Approval` 在 ChatKernelProjection.swift:46–83 重复 switch，VM:1282–1375 又各自补 triage。可以把“呈现、清除审批及 triage token”放进现有 per-conversation presentation owner，Projection 调用少量具名操作；UI 的 typed pending properties 继续作为投影，第一阶段不强改它们为全新 enum 存储。`setIsLoading` 还隐含 `clearChildResultWait`（VM:1278），应在 owner 内用具名操作表明关系，而非让几个 setter 在调用端凑顺序。
- **上下文适合做不可变值的部分**：Host 已有 runId/start time/provider/params/冻结 settings/execution policy/input digest。可在实现时收成小的不可变 run context 或沿现有 RunRequest 传递，避免重复长参数列表；它不拥有 messages/task/approval/ledger，不复制到每个 module 里。不要把 bindings 所有字段搬进 `ChatSessionContext`，那只是改名后的 god object。
- **顺序必须继续显式**：审批持久化 → 发卡 → 用户决定 → Started → claim → executor → Finished；terminal 持久化 → durable terminal → 系统完成；mailbox → steer。Host/Adapter/engine 层级保持，取消、snapshot FIFO 的 owner 保持。优先在已有测试记录点对照下提取 1 个职责，证明行为没变，再缩调用 interface。
- **因此优先级**：40 闭包本身列“中等结构改进”，不是立刻重写整个消息架构的理由。先把独立完整类型迁走拿到安全收益，后对明确的 approval presentation、upload preparation、persistence 做职责抽取；若迁移后某组回调仍有必要且测试清楚，保留即可。

## 变更类别：第一波完整类型迁出，第二波状态职责抽取

**A 类，立即可做的组织变更（仍需编译和相关回归）**

- NativeChatTimelineView 完整迁到独立文件：原类型约 1237 行，已符合上限；ChatSwiftUIMessageList 完整迁到 Regression 目录。不要重写滚动算法或 State。
- MessageBubble 中 GeneratedImageGrid/Tile/Preview 完整类型迁出；MessageBubble 保留约 740 行。
- Markdown 的 controller/parser/cache 按完整类型成组迁出；private 跨文件访问仅按所需类型/方法最小提升，不移动 actor。
- ChatMessageProjection 的各枚举/struct、phone grouping、OutputAnalysis/Approval model/OutputBudget 完整迁出。
- ChatConversationRunState、ChatPendingToolApproval、ChatToolRuntime 的独立值类型、Kernel transfer boxes、ChatKernelDurableTextProvider 作为完整类型迁出。其中 durable provider 必须保留 private 使用边界和 callbacks，不顺便改变 checkpoint 机制。
- A 类本质是让 module 的现成 implementation 有自己的位置，不声称大对象职责已经全部解决。

**B 类，需要行为对照的职责抽取**

- VM 的 persistence/branch commit、attachments async 归属、inbox/child wake、auxiliary task cancellation；这些方法当前直接访问 VM 状态，不能靠 extension 获得模块化。
- ToolRuntime 的 Plugin/Recipe prepared candidates、暂停/恢复/checkpoint/ledger、JS scope、前后台 executor 策略；state 跟随具体 owner，入口与 finisher 不能分家。
- Host 的直接生图、审批 continuation、terminal commit、keepalive/handoff；每次只移动一个 owner，Host 保持 run 生命周期决策。
- Adapter 的 nested approval queue 与 typed approval resolution；保留 snapshotSeq/driver cancellation/FIFO，不把 Task/actor 改造混在同波。
- ChatView 的附件授权/import/preview 异步流程、composer focus/安全区与 summary 更新事件。不能把 @State 全移到一个 model。

B 类应在提取前用已有生产入口测试录制主要顺序/结果，提取后保持相同断言；不是按新实现逐个补 helper mock 测试。第一波完全不需要创建 package、protocol hierarchy 或通用 event bus。
