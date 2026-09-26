# Amber × Jev 升级计划：问题分析、优化建议与执行步骤

版本：1.0。起草日期：2026-09-24。代码核对基线：`4c2e090`（main）。

前置：`jev-integration-execution-plan.md` 三阶段与 `jev-enhancements-execution-plan.md` Phase A–E 均已实现；七个用途默认 off，真实 API 收益从未验证（见 `docs/reviews/jev/final-report.md`）。工作区中另有与 Jev 无关的 provider / Codex 登录改动，执行本计划时不得混入这些文件。

本文是审查结论与执行交接文档，只有收到执行指令后才实施。文中的阈值、并发数、等待时长都是初始实验参数，不是供应商承诺，实测后可调整并升级 `policyVersion`。

## 0. 结论摘要

1. **集成完整，但有两处必须先修的正确性问题**：模型调度的题目 ID 可能重复，一旦重复 App 直接崩溃；工具发现开成 active 后，暴露的工具反而比关键词搜索更多。
2. **架构层面**：每个用途各自单独出站，并串行挡在关键路径上；每个 run 同时只允许 1 个请求，占满就直接跳过；上下文筛选的结果每轮都会变，破坏 prompt 缓存。Jev "同一段 state 批量问多题、低延迟"的特性完全没用上。
3. **效果层面**：多数用途送给 Jev 的信息不足以做出好判断，即使开成 active，收益也会很有限。
4. **升级分六个 phase**：P0 正确性修复与延迟基线 → P1 协调器调度层 → P2 关键路径改造 → P3 逐用途效果调优 → P4 可见性与上手 → P5 shadow 评估与逐用途启用。

## 1. 现状速览

| 用途 | 触发点 | 对主路径的阻塞 | 当前提问方式 |
|---|---|---|---|
| 工具发现 | 主模型调用 `tool_search`（前台、后台、Recipe 三条路径） | active 时阻塞该次工具调用 | 每个候选一道 Score |
| 记忆召回 | 每个模型步骤的上传准备（同一轮内缓存） | active 时阻塞首字 | 每个候选一道 Score；之后对选中集再发一次 Noul 注入筛查 |
| 上下文筛选 | 每个模型步骤的上传准备 | active 时阻塞该步骤 | 最新一段超过 8,000 字的可重读工具输出，每块一道 Score |
| 模型调度 | spawn / followup 允许自动选池的分支 | 阻塞 spawn | 每个候选模型一道 Score |
| 意图路由 | spawn 缺省角色定义时 | 阻塞 spawn，排在模型调度之后串行 | 角色 Choice + 对齐 Noul |
| 审批分诊 | 出现待审批请求 | 不阻塞，标签异步补上 | 三道 Noul |
| 网页操作 | 主模型调用 `wm_run_goal` | 循环内每一步 | 动作 Choice + 注入 Noul |

所有判断都经 `IOSJevDecisionCoordinator.decide` 单一出口，单次 deadline 1.2 秒（网页操作 2.5 秒）。

## 2. 问题分析

级别：P0 = 正确性或崩溃，必须先修；P1 = 显著影响延迟或效果；P2 = 开销、可观测性与产品问题。

### P0-1 模型调度的题目 ID 可重复，一旦重复即崩溃

- **证据**：
  - `IOSJevModelRoutingService.rankedPreferredModelIds` 用 `candidate.model.modelId`（API 模型名）作为题目 ID。
  - `IOSJevClient.decide` 用 `Dictionary(uniqueKeysWithValues:)` 构建题目表，键重复会触发运行时 trap。
  - 模型池条目按模型 UUID 存储（`IOSSubAgentModelPool.candidates`）。同一个 API 模型名挂在两个 provider 下时（例如同时配置了 OpenAI API 和 Codex 登录），会产生两个同名候选。
  - `preferredCandidates` 同样按 API 模型名匹配，同名时只会命中第一个。
- **触发条件**：模型调度非 off、数据范围允许、已配 Key、模型池内存在同名模型。shadow 模式下的后台任务同样会崩溃。
- **影响**：App 崩溃。
- **修复方向**：题目 ID 改用候选 UUID（`Candidate.modelId`），模型名放进 state；客户端在编码前检查重复 ID，返回 `.invalidRequest`，不再 trap（作为所有用途的兜底）。→ Phase 0

### P0-2 工具发现 active 时，暴露的是"关键词结果 ∪ Jev 结果"

- **证据**：
  - `IOSJevToolDiscoveryService.execute` 在发起 Jev 判断之前，就执行了一次 `bridge.executeToolSearch(argumentsJson:)` 作为 `keywordFallback`。
  - 这次调用会经 `exposureState.exposeToolNames` 把命中工具加入暴露集合，而 `ToolSearch.kt` 的 `exposeToolNames` 只增不减。
  - applied 路径随后又调用一次带 `rankingOverride` 的版本，命中结果继续追加。
- **影响**：active 模式下，Jev 判为无关的工具仍然暴露，下一轮带的工具定义变多。"语义排序"只改变了返回给主模型的列表顺序，暴露面反而扩大。shadow 路径不受影响。
- **修复方向**：备用结果延迟到确实需要回退时才执行；applied 且排序有效时只执行一次 ranked 版本。补一条测试：active 暴露集合必须等于 ranked 结果（含相关工具展开）。→ Phase 0

### P1-1 每个 run 并发上限 1，占满即跳过

- **证据**：
  - `IOSJevDecisionCoordinator.acquireSlot` 的上限是 App 总计 3、每个 runId 1，拿不到槽位直接返回 `.skipped(reason: "concurrency_limit")`。
  - 各用途的 shadow 路径用 `Task(priority: .utility)` 在后台发起，和同一 run 的 active 判断共用槽位。
  - 并行 spawn 多个子代理时，模型调度和意图路由都使用同一个 parentRunId。
- **影响**：shadow 观测会挤掉 active 判断；并行 spawn 时只有一个子代理能拿到判断。指标上这些情况只显示为"回退"，和"Jev 判断失败"无法区分。
- **修复方向**：拆成 active 与 shadow 两条通道；提高 active 每个 run 的上限，并允许在等待预算内短暂排队；shadow 通道满了就丢弃，不占 active 槽位。→ Phase 1

### P1-2 关键路径上串行等待

- **证据**：
  - `ChatKernelRunHost.prepareUploadMessages` 每个模型步骤都会被调用（作为 kernel 的 `prepareUploadMessages` 绑定），其中依次 await：上下文筛选 → 记忆召回（`prepareTurnSelection`）→ 注入筛查（`screenForInjection`，第二次独立请求）。每次 deadline 1.2 秒。
  - spawn 分支先 await `jevPreferredModelIds`，再 await `jevSubAgentIntent`。两者的 state 都是同一段子任务文本。
- **影响**：
  - active 时首字最坏晚 3.6 秒（三项都触发）。
  - 工具循环中出现新的长工具输出时，该步骤晚 1.2 秒。
  - spawn 最坏晚 2.4 秒。
  - 增强计划 Phase D 约定"注入筛查顺路并入已有调用"，实际实现成了第二次请求。
- **修复方向**：互不依赖的判断并行启动；同一时机的判断合并成一次请求；关键路径只等"等待预算"。→ Phase 1、Phase 2

### P1-3 上下文筛选破坏 prompt 缓存

- **证据**：
  - `candidateBlocks` 从后往前找，只投影"最新一段"可筛长输出。每次上传准备都从 canonical 历史重新投影。
  - 出现更新的长输出后，上一段恢复成全文。
  - 新的用户轮次会用新的任务文本重新判断，隐藏的块可能不同。
  - 缓存 TTL 5 分钟并按 runId 隔离，长 run 内过期后也会重新判断。
  - Claude provider 开启了 `cache_control`（`ClaudeKmpProvider`），OpenAI 走前缀缓存。
- **影响**：较早消息的内容一变，其后的全部前缀缓存失效。筛选节省的输入 token 可能被缓存失效抵消，甚至倒亏。现有 Phase 2 验收门槛只比较输入 token，没有计入缓存命中。
- **修复方向**：结果"首次使用即固定"。每段输出只判断一次，按 conversationId + toolCallId + 输出哈希 + 策略版本记录隐藏块；之后每次准备都对所有已判断的输出重放同一投影；未能判断成功的固定为"不投影"。验收加入缓存命中比例。→ Phase 2

### P1-4 送给 Jev 的信息不足以做出好判断

- **模型调度**：候选只有模型名和上下文长度，instructions 却要求"不因标识中出现熟悉名称而加分"。已有的事实，如 `Model.abilities`、`Candidate.supportedReasoning`、provider，都没有送出。结果容易接近平分，首选集合基本不改变选择。
- **工具发现**：state 里只有主模型写的 `query`（通常是几个关键词）。该用途已经要求了 `selectedTaskText` 范围，用户原话却没有放进 state。
- **上下文筛选**：
  - 每块只送前 300 字。
  - 每块一题，最多 32 题，长文档只有前 32 段参与评估，后半部分永远不会被隐藏。
  - 强保留信号是任意子串匹配（`todo`、`cursor`、`continuation`、`error:` 等），代码和技术文档里大量块因此被强制保留。
- **审批分诊**："只读"和"可逆"由 Jev 凭工具名和最多 200 字的摘要去猜。实际上 `ToolRegistry` 已有 `mutates` / `risk` 静态元数据，工作区审批的调用点甚至已经知道这次是读还是写（`isWrite`），只是拼成摘要文字交给 Jev 再判一次，两者可能矛盾。MCP 和 council 审批只送工具名，这三道题都缺少依据。
- **网页操作**：state 只列前 30 个元素，候选动作却来自全部元素（上限 64），部分选项在 state 里没有上下文；instructions 写着"不确定时选择 scroll"，形成偏向滚动的倾向。
- **修复方向**：→ Phase 3

### P1-5 记忆注入筛查可能静默删掉用户偏好

- **证据**：`IOSJevInjectionScreening.hitQuestionIds` 以 Noul ≥ 0.5 判定命中；所有选中记忆都会被筛；命中后剔除且不递补，界面上没有任何提示。"回答时用简体中文"这类偏好本身就是写给 AI 的指令。`MemoryRecord` 没有"外部来源"字段，只有 `kind`、`sourceConversationId`、`confidence`。
- **影响**：一旦误报，用户的偏好不生效，而且用户无从得知。
- **修复方向**：阈值移入 policy 并提高（初值 0.8，shadow 期间校准）；命中结果进入指标，并在本轮判断详情中可见；是否按 `kind` 排除筛查，要先核实各 kind 的写入来源再决定。→ Phase 3

### P2-1 指标写入开销

- **证据**：`IOSJevMetricsStore.append` 每写一条记录，都要把全量记录（最多 2,000 条）读出、解码、追加、编码，再整体写回 UserDefaults。网页循环单次最多 100 次决策。
- **修复方向**：改成内存环形缓冲 + 防抖批量落盘，App 进入后台时强制写盘。→ Phase 1

### P2-2 每次判断都重复读 Keychain、解码设置

- **证据**：共享协调器的 `apiKeyProvider` 每次 decide 都读 Keychain；各服务和协调器会多次调用 `loadPersistedJevSettings()`（UserDefaults 读取 + JSON 解码）。
- **修复方向**：设置按 revision 缓存快照；Key 缓存在内存中，保存或清除 Key 时失效。→ Phase 1

### P2-3 缓存无法跨轮复用

- **证据**：`IOSJevRunContext.cacheKey` 包含 `turnBudgetKey`（即 runId）。
- **影响**：同一个查询配同一份工具目录、同一段工具输出，到下一轮都要重新计费。
- **修复方向**：只依赖输入内容的判断（工具相关性、块相关性）改用内容键，键里仍包含用途、模型、范围、策略版本；依赖轮次状态的判断（记忆、网页）保持不变。→ Phase 1

### P2-4 shadow 指标回答不了"要不要启用"

- **证据**：`IOSJevMetricsRecord` 只有工具发现记录了 `suggestedTop1` / `keywordTop1`；记忆、筛选、调度都没有记录与基线的差异。校准（`IOSJevCalibration`）需要 (confidence, correct) 对，而生产环境中没有"正确与否"的来源。
- **修复方向**：逐用途增加不含原文的差异指标（见第 5 节）。→ Phase 1、Phase 4

### P2-5 上手门槛高，效果不可见

- **证据**：启用需要配 Key、（systemone 形态下）通过连接测试固定模型版本，再给七个用途分别设置模式和数据范围。除了审批标签，用户看不到 Jev 做了什么。
- **修复方向**：提供一键"推荐配置"；本轮 Jev 判断摘要可查看。→ Phase 4

## 3. 目标架构

### 3.1 原则

1. **按时机合并，不按用途各发各的。**
2. **提前启动、并行执行。** 关键路径只等"等待预算"；网络 deadline 和等待预算是两个独立参数。
3. **结果首次使用即固定。** 同一轮、同一段输出的判断一经应用就不再改变，以保护 prompt 缓存和注入 / 引用的一致性。
4. **把判断需要的事实交给 Jev。** 题目 ID 必须唯一且稳定。
5. **shadow 搭 active 的便车。** 同一时机已有 active 请求时，shadow 题目并进同一个请求，不单独占资源。
6. **继承全部既有契约**：fail-open；off = 零网络；shadow 不改变业务结果；权限相关永不 fail-closed；指标不存原文。

### 3.2 决策时机

| 时机 | 合并的用途 | 触发 | 等待方式 |
|---|---|---|---|
| T1 本轮准备 | 记忆相关性 + 记忆注入筛查 | 用户轮次的第一个模型步骤 | 与压缩、上下文投影、图片准备并行；等待预算内返回才应用，否则本轮使用本地结果 |
| T2 工具输出进入历史 | 上下文筛选 | 新的长工具输出第一次进入上传准备 | 只判断一次并固定；超时或失败固定为"不投影" |
| T3 spawn | 模型调度 + 角色选择 + 对齐判断 | spawn / followup 允许自动选池或缺省角色的分支 | 合并成一次请求；等待预算内返回才应用 |
| 按需 | 工具发现、审批分诊、网页操作 | 保持各自现有入口 | 接入新的通道和批量入口 |

### 3.3 协调器改造

- **批量入口 `decideBatch`**：
  - 输入多个 part，每个 part 包含用途、所需数据范围、state 分节、题目。
  - 协调器逐个 part 判定模式和范围。off 或范围不允许的 part，其 state 分节和题目都不进入请求。
  - 剩余 part 合并后一次出站，答案按题目前缀分回各自的 part。
  - 每个 part 单独记一条指标：延迟共享，字节数按题数分摊。
  - 所有 part 都被排除时零网络。
  - 单用途的 `decide` 保留，内部改为调用单 part 的 `decideBatch`。
- **两条通道**：
  - active 通道：每个 run 上限 3、App 上限 6（初值，Phase 0 实测后调整）。满时在调用方的等待预算内排队。
  - shadow 通道：App 上限 2，满即丢弃并记为 `shadow_dropped`，不占 active 槽位。
- **两个时间参数**：
  - `waitBudgetMs`：关键路径最多等多久，按时机分别配置。
  - `deadlineMs`：网络请求最长多久。
  - 等待预算到期后，调用方先用本地结果继续。网络请求可以继续跑到 deadline，结果只写入缓存和指标（记为 `late`），不回头修改已经发出的请求。
- **快照缓存**：设置按 revision 缓存；Key 缓存在内存中，保存或清除时失效。
- **缓存键**：内容型判断去掉 runId；轮次型判断保持不变。
- **指标**：改成内存环形缓冲 + 批量落盘；新增字段见第 5 节。

### 3.4 题目与 state 规范

- 题目 ID 只用本地生成、稳定且唯一的标识（UUID、记录 ID、块序号），不用展示名。客户端出站前拒绝重复 ID。
- 批量请求中，题目 ID 带用途前缀（如 `mem.`、`inj.`、`route.`、`role.`），避免不同 part 之间冲突；分回答案时去掉前缀。
- state 分节带标题（如"## 记忆候选"），每节只放该 part 已获允许的数据范围。
- 题数超过 `policy.maxQuestions` 时拆成多个请求并行发出，不再串行。执行前先查官方文档核实单请求题数上限（当前的 32 是本地策略值，不是官方限制）。

## 4. 逐用途调优建议

### 4.1 工具发现

- 修复 P0-2 的暴露并集问题。
- state 增加用户最新一条消息（截断到 1,000 字符）。该用途本来就要求 `selectedTaskText` 范围，不新增外发类别。
- 增加一道 Noul："候选中是否有能完成该查询意图的工具"。结果为否时直接回退关键词结果，不做无依据的重排。
- 内容型缓存键：同一查询、同一份目录快照在跨轮时复用结果。
- 验收：active 暴露集合 ⊆ ranked 结果及其相关工具展开；精确工具名查询仍然零 Jev 网络；前台、后台、Recipe 三条路径行为一致。

### 4.2 记忆召回

- 放在时机 T1：从 `prepareUploadMessages` 入口就启动，和压缩、上下文投影并行，在注入前 await，最多等待预算的时长。
- 相关性 Score 与注入筛查 Noul 合并成一次请求：候选集合在请求前就已确定，对每个候选同时提出两题。题数超出上限时，先把候选池缩到上限的一半，或拆成两个并行请求。
- 注入筛查阈值移入 policy（`memoryInjectionMinProbability`，初值 0.8）；命中数写进指标，并在本轮判断详情中可见。
- 保持"一次计算选中集合"的契约：本轮第一个步骤确定选中集合后，本轮内不再更改。迟到的结果只写入缓存和指标。
- 验收：首字前等待不超过 T1 的等待预算；注入、usage 标记与引用白名单仍然使用同一个集合；超时或失败时与基线行为一致。

### 4.3 上下文筛选

- 改为时机 T2 + 结果固定：
  - 新增按会话隔离的投影决策表，键为 conversationId + toolCallId + 输出内容哈希 + policyVersion，值为隐藏块序号，或"不投影"。
  - 每次上传准备时，对历史中所有已经有决策的输出重放同一投影；只对还没有决策的新输出发起判断。
  - 判断超时、失败或低置信时，记为"不投影"并固定下来。
  - 决策表保存在内存中，有条数上限；App 重启后丢失，只会重新判断一次，不需要持久化。
- 分块改为"先合并再评估"：
  - 相邻段落合并到每块约 1,500～2,000 字，使 32 道题能覆盖整篇文档。
  - 围栏代码块和表格仍然不拆开。
- 每块送检内容从 300 字提高到约 1,000 字；超长块取开头和结尾各一半。整个 state 仍然受 48 KiB 上限约束。
- 强保留信号改为结构化匹配，例如 JSON 键 `"ok": false`、`"has_more": true`、`next_cursor`、`page_token`，或行首的 `TODO:` / `Traceback`。去掉 `todo`、`cursor`、`continuation`、`error:` 这类任意子串匹配。
- 验收：
  - 同一段输出在后续轮次中的投影逐字节一致。
  - 出现更新的长输出后，较早输出的投影保持不变。
  - 冻结集中必要证据漏失为 0。
  - 同一任务开启筛选后，`cachedTokens` 占输入 token 的比例不低于关闭时。

### 4.4 模型调度与意图路由（合并）

- 修复 P0-1：题目 ID 改用候选 UUID。
- 候选描述补充已有事实，缺失的一律标 unknown，不编造：
  - 模型名与 provider 名
  - `abilities`（推理、视觉、工具等）
  - 上下文长度
  - 支持的思考档位（`supportedReasoning`）
  - 用户在模型池里为该模型配置的思考档位
- instructions 改为"以能力事实为主，模型名只作辅助参考"，符合原计划"不只按名称推断强弱"的约定。
- 时机 T3：模型适配 Score、角色 Choice、对齐 Noul 放进同一个请求，state 共用同一段子任务文本。两个用途的模式和范围仍按 part 分别判定。
- 并行 spawn 走 active 通道，不再因为共用 parentRunId 而互相跳过。
- 验收：同名模型分属两个 provider 时不崩溃，且都能被选中；显式 model_id 和角色优先级不变；每次 spawn 最多出站一次。

### 4.5 审批分诊

- "只读"和"可逆"优先使用静态事实：
  - 工作区审批用 `isWrite`。
  - 注册工具用 `ToolRegistry` 的 `mutates` / `risk`。
  
  只有静态信息缺失时（如 MCP、recipe）才问 Jev。
- Jev 的重点是"是否服务于用户最新请求"。在该用途的数据范围允许时，state 附上参数摘要（字段名 + 截断值，不含密钥或凭据字段）；不允许时，这一题标为未知，不硬猜。
- UI 契约不变：只显示中性事实标签，不自动批准或拒绝，不改动按钮。
- 验收：静态事实与标签不再矛盾；MCP 审批在缺少参数时显示"未知"。

### 4.6 网页操作

- state 里列出的元素和候选动作对齐：列出所有出现在候选里的元素（上限 64，每个 label 截断），不再固定取前 30 个。
- 删掉"不确定时选择 scroll"；Choice 里加一个 `handback` 选项，表示"交回主模型"，不确定时选它。
- 更新 `wm_run_goal` 的工具说明，写清楚适用场景（目标明确、动作是只读或草稿类）和不适用场景，让主模型愿意调用、也不滥用。当前上限 100 步 / 600 秒是熔断值，说明里不要写成"快速"。
- 验收：`IOSJevWebMountLoopTests` 与 `JevWebTaskFixtures` 全部通过；因不确定而 handback 时，理由会透传给主模型。

## 5. 度量

### 5.1 端到端指标（只存数值）

- 首字时间：从发送到第一个流式 chunk。
- 每个任务的主模型步骤数。
- prompt 缓存命中比例：`Usage.cachedTokens / inputTokens`。
- Jev 在关键路径上的实际等待时长（按时机分开统计）。
- `late` 比例和 `shadow_dropped` 次数。

### 5.2 逐用途差异指标（不含原文）

| 用途 | 指标 |
|---|---|
| 工具发现 | Jev 首选与关键词首选不一致的比例；active 暴露工具数与关键词路径暴露数之比；下一步是否调用了新暴露的工具 |
| 记忆召回 | Jev 选中集与基线选中集的重合比例（只按 ID 计数）；注入筛查命中数 |
| 上下文筛选 | 隐藏字符占比；块被隐藏后主模型重读同一工具的次数（过度隐藏的信号） |
| 模型调度 | 首选集合大小；最终选择是否因 Jev 改变；子任务成功、失败、超时 |
| 意图路由 | 建议角色与最终角色；对齐判定为偏离的比例 |
| 网页操作 | 每个目标的决策次数；handback 原因分布；完成率 |

## 6. 升级计划

每个 phase 收尾时：定点测试 + 受影响的回归测试 → 子代理对抗审查（逻辑闭环、调用链完整；有 UI 改动时加查对齐、间距、字号）→ 精准修复 → 按 Lore 格式提交。新增文件后检查 `iosApp/project.yml` 并执行 `xcodegen generate`。

### Phase 0：正确性修复与延迟基线

**交付**

1. **P0-1**：
   - `IOSJevModelRouting.swift` 的题目 ID 改用候选 UUID；`preferredCandidates` 按 UUID 匹配。
   - `IOSJevClient.decide` 在编码前检查题目 ID 是否重复，重复时抛出 `.invalidRequest("duplicate question id")`（本地拒绝，不计费）。
2. **P0-2**：`IOSJevToolDiscovery.swift` 的备用关键词结果改成惰性执行；applied 路径只执行一次 ranked 版本。
3. **延迟基线**（需要 Key；没有 Key 时记为 blocked，其余步骤照常推进）：
   - 用合成数据分别测 1、8、32 题的请求，Wi-Fi 和蜂窝网络各 30 次，记录 p50 / p95，两种 API 形态分别测。
   - 结果写入报告，作为 Phase 1 等待预算和并发上限的依据。

**文件**：`IOSJevModelRouting.swift`、`IOSJevClient.swift`、`IOSJevToolDiscovery.swift`；测试写在 `IOSJevSubAgentModelRoutingTests`、`IOSJevClientTests`、`IOSJevToolDiscoveryTests`、`IOSToolSearchExposureTests`。

**测试**

- 同名模型分属两个 provider：shadow 和 active 都不崩溃，两者都能进入首选集合。
- 重复题目 ID 被本地拒绝，不计入预算。
- active 暴露集合等于 ranked 结果（含相关工具展开）；fallback 路径的暴露集合与改动前一致。

**验收**：以上测试通过；`IOSJevToolDiscoveryTests`、`IOSJevSubAgentModelRoutingTests`、`IOSToolSearchExposureTests`、`IOSOrchestrationToolTests` 全部通过。

**回退**：单独 revert 该提交即可，不涉及数据。

### Phase 1：协调器调度层

**交付**

1. 通道拆分：active / shadow 各自独立计数；active 支持在等待预算内排队；shadow 满即丢弃。
2. `decideBatch` 批量入口：分 part 判定模式和范围、题目加前缀、答案分回、逐 part 记指标；`decide` 改为调用单 part 版本。
3. 在 `IOSJevPolicy` 中增加：
   - 按时机的 `waitBudgetMs`：T1、T2、T3、按需四个字段，初值按 Phase 0 实测的 p50 设置；没有实测数据时暂用 400 ms。
   - 通道上限字段：active 每个 run 上限、active App 上限、shadow App 上限。
   - `decodeIfPresent` 兼容旧数据；`policyVersion` 升到 3。按现有迁移逻辑，存量策略会整体重置为默认值，但用途模式不会跟着改。policy 注释约定"调整后回到 shadow"，因此迁移中要显式把已是 active 的用途降为 shadow，并补一条迁移测试。
4. 等待预算与 deadline 分离：新增 `late` 结果码；迟到的结果只写入缓存和指标。
5. 设置快照按 revision 缓存；Key 缓存在内存中，保存或清除时失效（接入 store 现有的失效钩子）。
6. 缓存键区分内容型和轮次型：工具发现、上下文筛选使用内容键。
7. 指标改成内存环形缓冲 + 防抖落盘（5 秒或 50 条，先到为准），进入后台时强制写盘；增加第 5 节的数值字段。

**文件**：`IOSJevDecisionCoordinator.swift`、`IOSJevClient.swift`、`IOSJevSettings.swift`（policy 与 metrics）、`IOSSharedSettingsStore.swift`（只动 Jev 相关的失效钩子）。

**测试**（`IOSJevDecisionCoordinatorTests`、`IOSJevSettingsTests`、`IOSJevClientTests`）

- shadow 占满时 active 仍能拿到槽位；同一 run 并发 3 个 active 都能执行；超出上限时在等待预算内排队，超时后返回 skipped。
- 批量请求中，范围不允许的 part 零外发；全部 part 被排除时零网络；答案分回正确；未知前缀的答案被丢弃。
- off 模式仍是零网络、零缓存、零指标。
- 配置 revision 在请求途中变化时，整批结果丢弃。
- 迟到结果不改变调用方已经拿到的返回值，并能被下一次同键请求命中。
- 指标防抖落盘，重启后可读取；7 天 / 5 MiB 上限不变。

**验收**：以上测试通过，既有 Jev 测试套件全部通过。

**回退**：`policyVersion` 回退，通道参数恢复为 1 / 3。

### Phase 2：关键路径改造

**交付**

1. **T1**：`ChatKernelRunHost.prepareUploadMessages` 在入口就启动记忆召回任务，与压缩、上下文投影并行，在注入前 await（最多等 T1 的等待预算）。`IOSJevMemoryRecallService` 改为通过 `decideBatch` 在一次请求中同时提交相关性和注入筛查两个 part。
2. **T2**：`IOSJevContextSelectionService` 增加投影决策表并对所有已决策输出重放；对历史中所有还没有决策的可筛输出发起判断（每个输出一次，受 T2 等待预算约束），不再只看最新一段。
3. **T3**：新增一个 spawn 判断入口，一次 `decideBatch` 同时提交模型调度和意图路由两个 part；`IOSThreadOrchestrationToolService` 的 spawn / followup 分支改成只 await 一次。followup 分支不做意图判断，保持现状。

**文件**：`ChatKernelRunHost.swift`、`IOSJevMemoryRecall.swift`、`IOSJevContextSelection.swift`、`IOSJevModelRouting.swift`、`IOSJevSubAgentIntent.swift`、`IOSThreadOrchestrationToolService.swift`。

**测试**

- 记忆（`IOSJevMemoryRecallTests`、`IOSMemoryCitationTests`、`IOSMemoryUsageMarkingTests`）：
  - 本轮只发一次请求。
  - 超过等待预算时回到基线，且本轮后续步骤不会改用迟到的结果。
  - 注入、usage 标记与引用白名单使用同一个集合。
- 上下文筛选（`IOSJevContextSelectionTests`、`IOSContextCompactionCoordinatorTests`）：
  - 同一段输出在第 N 轮和第 N+1 轮的投影逐字节一致。
  - 出现更新的长输出后，较早输出的投影不变。
  - 判断失败后固定为全文。
  - 压缩摘要的来源仍是 canonical 原文。
- spawn（`IOSOrchestrationToolTests`、`IOSJevSubAgentIntentTests`、`IOSJevSubAgentModelRoutingTests`）：
  - 每次 spawn 最多出站一次。
  - 显式 model_id / role_id 时零判断。
  - 并行 spawn 互不跳过。
  - 预留在成功、失败、取消各路径下都不泄漏。
- 后台与 ledger：`IOSChatBackgroundExecutionTests`、`IOSRunSnapshotTests`。

**验收**：

- 模拟器下 fake transport 注入 1.2 秒延迟时，首字前 Jev 等待不超过 T1 等待预算 + 50 ms。
- spawn 前等待不超过 T3 等待预算 + 50 ms。

**回退**：各用途关闭即回到原流程；决策表只在内存中，无需迁移。

### Phase 3：逐用途效果调优

**交付**：按第 4 节逐项实现。

1. 工具发现：state 加入用户原话；增加"有无合适工具"Noul；内容型缓存键。
2. 记忆召回：注入筛查阈值移入 policy（初值 0.8）；命中写入指标。按 `kind` 排除筛查前，先核实写入来源，并把结论写进报告。
3. 上下文筛选：合并分块、扩大送检长度、结构化强保留信号。
4. 模型调度：补充候选事实，改写 instructions。
5. 审批分诊：静态事实优先，Jev 专注目标相关；数据范围允许时附参数摘要。
6. 网页操作：state 与候选对齐、加入 `handback` 选项、更新 `wm_run_goal` 工具说明。

**文件**：各用途的服务文件；审批改动涉及 `ChatViewModel.swift` 的 `triagePendingApproval` 调用点（只加静态事实参数，不改审批状态机）。`wm_run_goal` 的工具说明有两处：模型可见的声明在 KMP `ai-core/src/commonMain/kotlin/app/amber/ai/core/Tool.kt`（`createWebMountRunGoalToolDeclaration`），本地目录描述在 `IOSLocalToolExecutor.swift` 的 `IOSWebMountToolCatalog`。两处要同步修改；改 KMP 后运行 `:ai-core:jvmTest` 并重建 `Shared.framework`，再验证 Swift 消费入口。

**测试**

- 各用途定点测试和离线语料：`IOSJevBaselineCorpusTests`、`JevTaskFixtures`、`JevWebTaskFixtures`。补充以下样本：
  - 上下文筛选：尾部才有关键信息的长文档；含大量 `TODO` 和 `cursor` 的代码文件。
  - 模型调度：同名模型。
  - 记忆筛查：偏好类记忆作为误报对照。
- 审批：`IOSJevApprovalTriageTests`；标签视觉证据用 `IOSJevApprovalChipsVisualEvidenceTests` 复验。

**验收**：

- 离线语料在非 Jev 路径上的基线输出不变。
- 有 Key 时，冻结集上逐用途对比改动前后的 Jev 输出，记录弱词面子集的变化；没有 Key 时记为 blocked。

**回退**：阈值和字段都在版本化 policy 中；逐用途关闭即可。

### Phase 4：可见性与上手

**交付**

1. **推荐配置**：设置页新增一键开启，把工具发现、记忆召回、上下文筛选、模型调度、意图路由设为 shadow，数据范围取各用途默认值。网页操作和审批分诊不包含在内。用户确认后才生效；高级区保留逐用途设置。
2. **本轮判断摘要**：按 runId 汇总本轮 Jev 做了什么（例如记忆选中 3 条、筛查剔除 1 条、隐藏 12,000 字、子任务选了某模型），只存数值和 ID。优先放进已有的消息详情或用量信息面板；如果放进聊天时间线，必须额外运行 `iosApp/AGENTS.md` 规定的聊天 UI 回归。
3. **shadow 对比面板**：设置页"用量与状态"区增加逐用途差异率、等待时长 p50 / p95、回退原因分布，数据来自第 5 节的指标。

**文件**：`IOSJevSettingsView.swift`、`IOSJevSettings.swift`，以及摘要展示所在的视图。

**测试**：`IOSJevSettingsTests`、`IOSSettingsWiringTests`（推荐配置的控件、持久化和运行时消费闭环）；视觉证据用 `IOSJevSettingsVisualEvidenceTests`，覆盖默认字号、AX3、320pt 宽度。

**验收**：视觉审查通过；推荐配置重启后仍然保持；关闭后回到原流程。

### Phase 5：shadow 评估与逐用途启用

**前提**：已有 Key；Phase 0–4 已完成。

**步骤**

1. 用推荐配置跑 shadow 3～7 天，覆盖日常对话、长文阅读、子任务、网页任务。
2. 按用途汇总第 5 节的指标，并用 `IOSJevCalibration` 结合冻结集结果校准各用途的置信阈值。
3. 逐用途判断是否启用，门槛沿用原计划并补充以下几条：
   - 开启后首字时间 p95 的增加不超过 T1 等待预算。
   - prompt 缓存命中比例不低于关闭时。
   - 上下文筛选的"隐藏后重读"次数占隐藏块数的比例低于 5%。
   - 其他收益门槛（Recall@5、token 降幅、费用或耗时降幅）沿用 `jev-integration-execution-plan.md` 的定义。
4. 启用顺序：工具发现 → 记忆召回 → 模型调度与意图路由 → 上下文筛选 → 审批分诊 → 网页操作。没达到门槛的用途保持 shadow，并在报告中写明原因。
5. 真机验证：蜂窝网络、弱网、锁屏 / 后台下的等待时长与回退行为。没有真机时如实记为"待验证"。

**产出**：`docs/reviews/jev/upgrade-report.md`，逐用途列出代码状态、离线验证、真实 API、真机证据、启用结论和剩余缺口。

## 7. 新增全局契约

在既有契约之上增加：

1. 关键路径上的 Jev 等待不得超过该时机的 `waitBudgetMs`；超出时使用本地结果，迟到的结果不改变已经发出的请求。
2. 判断结果首次使用即固定：同一轮的记忆选中集合、同一段输出的投影，在其生命周期内不改变。
3. 批量请求中，每个用途的模式和范围独立判定；不被允许的用途，其数据不得出现在 state 里。
4. 题目 ID 必须本地唯一且稳定，不得使用可能重复的展示名；客户端对重复 ID 本地拒绝。
5. shadow 不得占用 active 的并发资源。

## 8. 不在本计划内

- **新能力**："思考深度自动"和"发送时预先暴露工具"。Phase 1 的批量入口和时机 T1 完成后，可以低成本加入 T1 的批量请求，届时另立计划。
- 不引入 SDK、数据库或通用工作流框架；Jev 不进入聊天 provider / 模型列表。
- 不改变主聊天模型的选择；不做任何自动批准或拒绝。
- 不改动小说模块、vendor 或发布配置。

## 9. 验证命令

```bash
cd iosApp && xcodegen generate   # 新增文件后
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO -resultBundlePath /tmp/jev_upgrade_<phase>.xcresult \
  -only-testing:iosAppTests/<定点测试类> test
xcrun xcresulttool get test-results summary --path /tmp/jev_upgrade_<phase>.xcresult

# Jev 全套回归（每个 phase 收尾）
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:iosAppTests/IOSJevClientTests \
  -only-testing:iosAppTests/IOSJevDecisionCoordinatorTests \
  -only-testing:iosAppTests/IOSJevSettingsTests \
  -only-testing:iosAppTests/IOSJevToolDiscoveryTests \
  -only-testing:iosAppTests/IOSJevMemoryRecallTests \
  -only-testing:iosAppTests/IOSJevContextSelectionTests \
  -only-testing:iosAppTests/IOSJevSubAgentModelRoutingTests \
  -only-testing:iosAppTests/IOSJevSubAgentIntentTests \
  -only-testing:iosAppTests/IOSJevApprovalTriageTests \
  -only-testing:iosAppTests/IOSJevInjectionScreeningTests \
  -only-testing:iosAppTests/IOSJevWebMountLoopTests \
  -only-testing:iosAppTests/IOSJevCalibrationTests \
  -only-testing:iosAppTests/IOSJevBaselineCorpusTests \
  -only-testing:iosAppTests/IOSToolSearchExposureTests \
  -only-testing:iosAppTests/IOSOrchestrationToolTests \
  -only-testing:iosAppTests/IOSContextCompactionCoordinatorTests \
  -only-testing:iosAppTests/IOSSettingsWiringTests test

# 改动 KMP 时（预期只有 Phase 3 的 wm_run_goal 说明；Phase 0 的暴露修复若需要改 bridge 也要跑）
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
./gradlew :ai-core:jvmTest :feature:tools:api:jvmTest :shared:jvmTest
./gradlew :shared:linkDebugFrameworkIosSimulatorArm64
```

报告里必须写明实际执行的测试数，过滤后为 0 个测试不算通过。

## 10. 完成定义

- Phase 0–4 已实现，定点测试和回归测试通过，每个 phase 的审查问题已修复。
- 两个 P0 问题有测试锁定。
- 首字前和 spawn 前的 Jev 等待被等待预算约束；上下文筛选的投影跨轮稳定。
- 第 5 节的指标可以在设置页查看。
- Phase 5 按用途给出启用结论。没有 Key 或真机时，对应项如实记为 blocked 或待验证，不声称未经验证的收益。
