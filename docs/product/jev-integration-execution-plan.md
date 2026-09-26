# Amber × Jev：三步完整执行计划

版本：2.0。代码与官方接口核对日期：2026-09-17。

当前状态：仅完成规划，未实现、未调用真实 Jev API、未验证收益。本文中的新增符号、文件、预算和验收阈值是实施约定，不代表现有能力或供应商保证。

## 目标与三步范围

将 Jev 作为 Amber 内部的快速判断服务，在三个完整阶段中落地：

| 阶段 | 交付范围 | 完成后 Amber 的能力 |
|---|---|---|
| **Phase 1：工具发现与记忆召回** | API 客户端、设置/凭据、评估基础、工具语义发现、记忆语义召回 | 更准确地找到工具和相关记忆，并在下一轮真实使用 |
| **Phase 2：上下文筛选** | 长工具结果筛选、原文恢复、压缩与引用接线 | 将相关证据交给主模型，减少无关内容，同时保持原文完整 |
| **Phase 3：模型调度与网页自动化** | 子任务模型适配、并发预留、有界网页操作循环、全链路验收 | 将任务交给合适模型，并让明确的网页操作减少主模型往返 |

严格保持这三个 phase。API、配置、观察模式、测试和上线检查都是阶段内部步骤，不再拆出额外 phase。本轮范围不包含自动记忆整理、通用代码审查、独立答案审查器、通用停滞判断服务或对外 Jev MCP。

**最终架构：** Jev 返回有限候选的评分和选择；Amber 代码负责过滤范围、预算、执行与权限；现有生成模型负责规划、文本/代码生成、摘要以及复杂情况恢复。

## 执行 AI 必须遵守的约定

1. 执行根目录是 `/Users/mi/Downloads/AI/AmberAgent/ios`。先读取根 `AGENTS.md` 和 `iosApp/AGENTS.md`，不得读取兄弟产品仓库。不得改动小说模块、vendor、无关发布文件。
2. 先查看 `git status --short` 并保护已有修改。本文核对时发布清单、Info.plist 和发布检查脚本已有修改；执行时以实际工作区为准。
3. 本计划是实现任务的交接文档。只有收到执行指令后才实施；实施不包含发布应用、商店上传、安装第三方示例仓库或修改用户现有模型配置。
4. 每步先核对真实调用链，补保护性定点测试，再实现和验证。保持原行为可回退，不只完成一个未被调用的类。
5. 可以将独立文件、测试或只读核查交给 Codex 原生子代理；公共客户端、设置 store、runtime 入口由主代理统一整合。
6. 未配置 Key 时继续所有可进行的离线工作。分别记录代码完成、离线验证、真实 API 验证、真机验证和启用状态；不得用 mock 成功冒充真实收益。
7. API Key 从用户在应用设置页配置的 Keychain 项读取；不要让用户把 Key 写在计划或聊天里，不打印 Key。真实测试先使用合成或公开数据，私人聊天、记忆、文件和网页需符合应用中用户选择的数据外发范围。
8. 第一版使用 Swift `URLSession`、`Codable`、现有 Keychain 和现有测试设施，不引入 SDK、数据库、MCP 服务或通用工作流框架。Jev 不进入普通聊天 provider/模型列表。
9. iOS 网络与设置在 Swift；共享工具目录和暴露仍由现有 KMP 模块拥有。当前 `Shared.framework` 仍由本仓 Gradle 生成，不假设 Core 已独立发布。
10. 修改 KMP 后同时验证对应模块测试、Shared.framework 生成和 Swift 消费；UI 设置必须完成可见控件、持久化和运行时消费闭环。
11. 无需对已授权、可逆的工程步骤反复询问。没有凭据/真机等外部条件时记录具体缺口，继续独立工作，保持未验证用途禁用。
12. 如创建分支用 `codex/` 前缀；提交仅包含本任务改动，并使用仓库要求的 Lore commit 格式。

## 三步共同使用的契约

### A. Jev API 与结果语义

实施时复核官方 [API 文档](https://docs.typesafe.ai/api)、[批量与问题类型](https://docs.typesafe.ai/introduction)、[confidence 文档](https://docs.typesafe.ai/confidence)，把实际模型版本与核对日期写入 Phase 1 报告。

当前请求为 `POST https://api.typesafe.ai/v1/systemone`，Bearer 认证，JSON 包含 `model`、`state`、`questions`。Choice 用于有限选项，Score 用于有序评分，Noul 返回 0～1 的是非概率。Choice/Score 的 confidence 来自分布；Noul 不含 confidence，不能伪造该字段。

同一状态上的独立问题可批量提问；依赖前一步答案的问题分开调用。多个对象可能同时相关时，分别评分，不把总和为 1 的 Choice 分布误当作多个独立相关性概率。问题 ID 不参与模型推理，待评估候选及其含义必须明确进入 state/instructions/criteria。

解码必须核对题目 ID、类型、候选 ID 和数值范围。缺题、未知候选、非有限数值、失效快照均不得成为有效业务结果。结构正确也不意味着事实正确。

### B. 身份、模式和数据范围

每次判断带上用途、问题/策略/模型版本、输入和候选哈希、配置 revision，以及对应的 conversationId、runId、turnRevision、snapshotRevision。无会话的连接测试有独立请求 ID。异步返回后重新核对身份和配置，不能把旧结果应用于新任务。

每种用途独立配置模式：

| 模式 | 网络与实际行为 |
|---|---|
| off | 零 Jev 网络调用，不应用缓存结果，走当前流程 |
| shadow | 仅对允许外发的数据调用，记录建议和指标，不改变业务结果，不阻塞原主路径 |
| active | 离线和真实门槛通过后，该用途才应用判断结果；错误或不确定时回退 |

shadow 同样会把数据发给 TypeSafe，不能视为本地模式。数据范围至少区分工具元数据、选定任务文本、个人记忆、文件/工具输出、网页内容。请求需要的范围全部允许才发送，不能因目录信息公开而附带外发私人任务文本。

主开关、数据范围或 Key 变化时取消不再允许的工作，提交结果前再次验证。使用独立 Jev 配置和现有 `IOSCredentialSideTable`，不修改共享 `ProviderSetting` 枚举，不复用已经成为兼容占位的 capability gate。

### C. 初始预算与失败策略

这些数值是应用初始实验参数，实施报告可以基于实测提出调整，并升级 policyVersion；不是供应商承诺。

- 普通前台单次判断总 deadline 为 1,200 ms，包含排队、网络、重试和解析；超时不再阻塞原路径。
- 同时在途的实际请求：每 run 最多 1 个，App 最多 3 个。这是并发上限，不是整个 run 只能调用一次；分块和网页各步可以顺序请求。网络和大块解析不得阻塞 MainActor。
- 单请求最多 32 个问题、64 个候选、state 48 KiB UTF-8、请求体 64 KiB、响应体 256 KiB，同时服从更严格的官方限制。超限分块或回退，不能静默截掉关键约束。
- 普通单轮共享预算为最多 6 次出站请求、累计 state 256 KiB；网页快速循环也消费该预算。重试计数，缓存命中不重复计费。
- App 日初始预算为 1,000 次出站请求、累计请求体 16 MiB；预算耗尽走原流程。本地预算不冒充供应商或跨设备硬账单上限。
- 400/401/403 不自动重试；暂时性错误最多重试一次，且必须有剩余 deadline；429 尊重 Retry-After，来不及就回退。连续 3 次暂时失败冷却 60 秒；认证失败暂停到凭据变化或显式连接测试。
- 第一版缓存仅内存、有界 128 项、TTL 5 分钟；键包括完整输入/候选、用途、版本、权限范围及 run 隔离信息。网页动作不缓存。清 Key 或收紧权限时失效。
- active 使用经过验收的固定模型版本；`jev-latest` 仅用于连接和实验。版本变化清缓存、回到 shadow，重新评估。
- 记录实际 usage、主模型 token、延迟、回退和任务结果。缺 usage 或取消后可能已计费的请求标为未知，不能算零费用；价格估算带日期。

预算身份约定：run 指现有 App owner/ledger 的 runId；单轮指该 run 内一次用户输入及其工具续跑，主模型再次生成、分块、重试或前后台恢复都不重置该轮预算。沿现有轮次 ID 建立 Jev budget key；没有稳定 ID 时在接收用户输入时生成并随 run checkpoint 保存。用户 steer 使输入版本失效，但不自动清空当前轮的已用预算。真正的新用户轮次才获得新预算，仍受 App 日预算限制。网页循环的 6 次是局部上限，也必须服从该轮剩余请求量，例如前面已用 2 次，则最多剩 4 次出站判断。

| 用途 | 不确定、失败、超时、预算不足、未允许外发时 |
|---|---|
| 工具发现 | 使用现有关键词/别名搜索，仍受当前工具 scope 和策略限制 |
| 记忆召回 | 使用现有排序与预算，不改变记忆内容或持久化状态 |
| 上下文筛选 | 保留原内容，继续现有压缩；原压缩错误仍按原流程处理 |
| 模型调度 | 回到现有显式/继承/角色/模型池规则 |
| 网页操作 | 不执行猜测动作，交回主模型或现有用户处理流程 |

## Phase 1：工具发现与记忆召回

### 1.1 交付目标

在 Amber 里直接接通 Jev，使用户换一种表达也能找到相关工具与记忆。该 phase 包含所有后续复用的 API、配置、身份、指标和评估基础。完成后必须能证明 Jev 选出的合法工具在下一轮可调用，记忆结果真实进入请求且引用/usage 一致。

### 1.2 先读的文件与现状

所有路径均相对执行根目录；按符号定位并核对调用者，不能依赖行号永远不变。

| 文件 / 符号 | 当前事实 |
|---|---|
| `feature/tools/api/src/commonMain/kotlin/app/amber/feature/tools/ToolSearch.kt` / `ToolSearchIndex` | 本地关键词、名字、描述和别名评分；默认 limit 5、上限 20 |
| 同目录 `IosToolExposureBridge.kt` / `executeToolSearch` | 查询与 run 内暴露集合更新耦合，包含相关工具展开和 Recipe 富化 |
| `iosApp/iosApp/ChatToolRuntime.swift` | 前台搜索、后台 executor、Recipe discovery 三处消费 bridge |
| `iosApp/iosApp/ChatContextSupport.swift` / `ChatMemoryContextBuilder` | 本地相关性、置顶、新鲜度、scope、有效期与条数/字符预算 |
| `iosApp/iosApp/ChatViewModel.swift` / `messagesByInjectingRuntimeContext` | 运行时上下文和注入 memory IDs 的实际来源 |
| `iosApp/iosApp/ChatKernelRunHost.swift` | 上传准备、run 归属、注入 IDs 和使用统计 |
| `iosApp/iosApp/IOSMemoryCitationStripper.swift` | 实际注入/成功工具结果建立 citation allowlist |
| `iosApp/iosApp/IOSMemoryPersistence.swift` | memory_tool search/query 的现有本地检索；本 phase 保持其原接口与行为 |
| `iosApp/iosApp/IOSSharedSettingsStore.swift`、`IOSCredentialSideTable.swift`、`ExecutionSettingsView.swift` | 设置持久化、现有凭据保存与 UI 接入位置 |

### 1.3 按顺序执行

**步骤 1：建立原行为和基线。**

- 读取适用规则、记录 commit 与工作区已有修改，核实上表全部入口。
- 运行原有工具暴露、记忆召回/引用和设置定点测试；已有失败单列，禁止掩盖。
- 建立共用合成/公开 fixture，建议 `iosApp/iosAppTests/Fixtures/Jev/`。工具、记忆各至少 40 条，分开阈值调试集与冻结验收集。
- 样本包含弱词面关联、中文同义词、跨语言、否定、无答案、多个正确候选、过期/禁用 scope、置顶、预算拥挤和提示注入文本。每条写正确结果、必须保留项和禁止结果。
- 保存 baseline 输出和预算；不让 Jev 独自给自己的答案打分。

**步骤 2：实现可测试的直接调用。**

- 建议增加 `IOSJevClient.swift`、`IOSJevDecisionCoordinator.swift`、`IOSJevSettings.swift`，按职责组织，不机械增加接口层。
- 用 URLSession/Codable 实现 typed questions、answers 和 `evaluated / skipped / unavailable`，取消单独传播。测试用 URLProtocol/闭包注入，不新增多层 provider 抽象。
- 完成共同契约中的 deadline、预算、并发、重试、短路和缓存。超时必须取消实际任务，不能因底层未结束而继续等待。
- 生产 endpoint 固定官方 HTTPS；测试地址通过测试 transport 注入，不放宽生产 TLS。
- 校验响应及 ID；日志不含 Key、Authorization、原始 state、原始私有响应或完整输入。

**步骤 3：完成设置和真实连接闭环。**

- 在 IOSSharedSettingsStore 内持有独立版本化 Codable Jev 设置，UserDefaults 保存非凭据配置；API Key 存现有 Keychain side-table，旧配置默认 off。
- 设置页提供 Key、合成数据连接测试、每用途模式、数据范围、状态、近期开销、关闭和清 Key。阈值留在版本化内部策略，不做复杂配置中心。
- Keychain 写入成功后才能更新 UI。检查现有 helper 的替换失败语义，必要时做最小修复并补凭据回归，不能丢失原可用 Key。
- 连接测试返回实际模型版本、耗时与错误，不自动启用所有用途。
- 指标只存用途、版本、大小、usage、耗时、回退和是否应用；默认不存业务原文。保存上限 7 天/5 MiB，可清除。
- shadow 使用有 owner、可取消、有 deadline 的任务，不新增 iOS 后台保活。

**步骤 4：接入工具语义发现。**

- 精确工具名查询直接使用原搜索，不调用 Jev。先锁定原输入/结果字段、limit、相关工具扩展和可调用性契约。
- 候选先经过当前 run 的 profile、scope、启用状态、category 与能力策略过滤，再发送元数据和允许的任务文本；不得引入当前 run 之外的工具。
- 候选结合关键词结果和类别补充。大目录先做类别选择，再在合法类别内评分；记录候选覆盖率，不能只重排原 Top 5 后宣称修复漏召回。
- 对候选独立评估相关性，并检查当前候选是否足够。多工具任务允许多个正确结果；低置信度和无足够候选时回退原搜索。
- 在 KMP bridge 中增加最小纯候选快照/验证后暴露入口（如需要）；复用现有 Recipe 富化、相关工具展开与 schema 输出。原同步搜索保留为 fallback。
- 用一个 Swift 异步搜索服务统一前台 `executeToolSearchToolCall`、后台 `tool_search` executor、Recipe discovery 三条路径，不复制三份网络调用。
- 返回后重查目录/权限 revision；仅 active 更新暴露集合，shadow 不暴露任何额外工具。tools_list 保持目录查看语义。
- 验证下一轮 provider 收到真实 schema，且调用继续经过原审批。发现工具不等于授权执行工具。

**步骤 5：接入记忆语义召回。**

- 先执行 memory scope 开关、archived、expiresAt 等硬筛选，再构建外发候选。Jev 不能扩大合法候选范围。
- 保留 ChatMemoryContextBuilder 的同步原行为，在异步请求准备层调用 Jev，再由 builder 根据合法排序结果组装 prompt。
- 候选包含词面匹配、新近记忆及合法 scope 内的补充条目；小集合可全评估，大集合分层/分块并记录覆盖。不能先排除零关键词命中，再指望重排找到它们。
- 使用每条 Noul/同量表 Score 评估相关性；置顶/核心等现有强保留语义继续满足，最后执行原条数和字符预算。
- 输出具体 MemoryRecord.id，不改写记忆文本。为同一 user turn 的工具循环复用结果；steer、内容/范围/配置变化时失效。
- **一次计算选中集合，统一供 prompt、metadata、召回说明、usage marking 与 citation allowlist 使用。** 不得注入 Jev 结果却用旧同步 builder 再计算一次 IDs。
- shadow 不影响注入、不标记已使用、不更新记忆。memory_tool 的主动 search/query 保持现有行为，不在本阶段顺带重构自动提炼或持久化。

**步骤 6：完成阶段验收与交接。**

- 对比 off/shadow/active；确认 off 零调用，shadow 业务无变更，active 超时回退。
- 验证切会话、steer、关闭功能、撤销范围及后台运行时旧结果不会串线。
- 有 Key 时跑合成样本真实 API smoke 与冻结集；没有 Key 时完成离线并标记 live blocked。
- 写 `docs/reviews/jev/phase-1-report.md`，为下一阶段冻结客户端、设置、身份和选中集合契约。

### 1.4 必须执行的检查

新增测试建议：`IOSJevClientTests`、`IOSJevDecisionCoordinatorTests`、`IOSJevSettingsTests`、`IOSJevToolDiscoveryTests`、`IOSJevMemoryRecallTests`。可以按既有测试组织合并，不能省掉行为覆盖。

重点覆盖：三类答案、批量题目映射、未知 ID、错类型/缺题/非法数值、超大响应、401/429、重试截止、队列超时、取消、并发预算竞争、缓存失效、Keychain 失败、旧 run/旧配置结果、前台/后台/Recipe 一致、scope 和 citation 一致。

原有回归至少包括：`IOSToolSearchExposureTests`、`IOSAgentToolEngineKernelHookTests`、`IOSSettingsWiringTests`、`IOSMemoryRecallPolicyTests`、`IOSMemoryCitationTests`、`IOSMemoryUsageMarkingTests`、`IOSMemoryLibraryTests`、`ChatContextSnapshotTests`。KMP 工具目录/bridge 变更运行 tools 模块与 shared 测试，并构建 Shared.framework。

### 1.5 阶段完成门槛与回退

- 非法/越权工具暴露、禁用 scope 注入、虚假 citation、串 run 结果均为 0。
- 精确工具名命中无回归且零额外 Jev 网络；相同 limit 下语义 Recall@5 不低于基线。
- 相同记忆注入字符预算下，必要记忆召回不低于基线，记录弱词面子集与无关注入率。收益需落在真正的最终候选集合，不能只比较 Jev 分数。
- 冻结集若基线仍有明显缺口，工具/记忆弱词面子集目标改善至少 10 个百分点；基线接近满分时报告天花板，不为满足数字修改金标准。
- 超时原路径可用，额外等待不得突破 1,200 ms 总 deadline；报告设备/网络上的真实 p50/p95。
- 配置持久化、重启、清 Key、关闭与真实调用均有证据后，工具发现和记忆召回分别决定 active；否则保持 off/shadow。
- 回退只需关闭对应用途，保留旧搜索和 builder，不迁移或删除记忆/对话。

## Phase 2：上下文筛选

### 2.1 交付目标与依赖

依赖 Phase 1 的客户端、预算、身份、设置、指标和选中集合契约。将新增长工具输出中的必要信息交给主模型，完整历史保留。精确全文任务不筛选。生成式摘要继续使用当前模型。

读取：`IOSAgentToolEngine.swift` 的 `prepareRequestMessages`、`ChatRunKernelAdapter.swift` 的引擎接线、`ChatKernelRunHost.swift` 的 `prepareUploadMessages`、`IOSContextCompactionCoordinator.swift` 的压缩源和请求投影、`IOSAgentRunLedger.swift` 的 request snapshot，以及 conversation_expand 的真实实现。

### 2.2 按顺序执行

**步骤 1：固定基线与可处理范围。**

- 补至少 20 个代表性长文本样本和对应任务，包括多页网页、代码/表格、异常日志、反例、引用、精确翻译和逐段分析。
- 记录未启用时主模型输入 token、压缩触发、产物正确性、总耗时和费用。
- 第一版只处理已完成、超过 8,000 字符的工具文本输出；系统/用户消息、权限、工具参数、待执行调用和当前用户约束不筛。

**步骤 2：建立可恢复的内容块。**

- 按完整段落/结构块切分，携带 messageId、toolCallId、blockId 和真实 sourceRef。JSON、代码块和表格不拆坏；无法安全分割则原样保留。
- 程序先标记必须保留的错误、审批、未知执行状态、未解决待办、后续所需 ID/分页 token、引用依赖和用户明确要求 全文的内容。
- 核实已有 conversation_e、
- xp=a
-
- nkl.， d 或原工具重读是否能精确恢复该结果。实际测试恢复；没有可用恢复路径的类型不启用隐藏。

**步骤 3：批量判断与请求投影。**

- 对剩余块分别判断相关性及是否包含必须保留的证据/限制/反例；分块请求遵守全 run 预算。
- 仅在低相关且没有保留信号时隐藏，不完整/未知/不确定全部保留。不要把失败或缺题解码成 0 分。
- 在请求副本中用简短省略标记与可调用恢复引用替代隐藏段落；不改变工具调用 ID、结果对应关系或原始来源。
- 同一输出和任务版本只判断一次；用户 steer 后重新判断需要变化的块，不反复对省略 marker 筛选。

**步骤 4：与压缩、记忆、账本接线。**

- 明确顺序：现有输入硬策略 → 新增长工具结果的筛选投影 → 本轮预算估算 → 必要时原有压缩 → 统一记忆/运行时上下文注入 → 实际请求快照。
- 该顺序是目标，执行前核实 Host 当前流程，用最小调整保证等价；避免为了顺序重写整套 Host。
- **压缩摘要的来源始终是 canonical 原文和既有 compact，不是 Jev 删段后的副本。** 不把不完整内容永久写为原历史。
- ledger 记录模型实际看到的请求，持久化会话仍保存完整工具输出。重复准备幂等，不重复注入 memory 或 compact。
- 核对前台与后台调用链；子任务若尚未使用同一准备器，必须明确列出支持范围，不能自动声称全部子任务都生效。

**步骤 5：验证恢复和失败路径。**

- 真正执行“筛掉块 → 主模型请求恢复 → 读回完整原文”，验证来源 ID 与内容一致。
- 测取消、过期 run、网络失败、输入超限、字符预算、压缩失败、后台交接和关闭 Jev；失败时保留全文，仍受原上下文上限与压缩策略约束。
- 不改变聊天 UI 中历史原文，不静默把模型已看到的状态覆盖回数据库。

**步骤 6：对照验收。**

- 相同任务交替运行 baseline/Jev，比较真实生成结果、输入 usage、费用和耗时，包含所有失败尝试。
- 写 `docs/reviews/jev/phase-2-report.md`，列出可筛类型、硬保留类型、恢复工具、启用策略和实测结果。

### 2.3 必须执行的检查

新增 `IOSJevContextSelectionTests`。覆盖 must-keep、结构块、无题/低置信度、真实恢复、用户要求全文、请求副本与 canonical 分离、压缩源完整、幂等、引用、token 估算、ledger snapshot、取消和后台恢复。

运行 `IOSContextCompactionCoordinatorTests`、`IOSAgentToolEngineKernelHookTests`、`IOSRunSnapshotTests`、`IOSChatBackgroundExecutionTests`、`IOSMemoryCitationTests` 和受影响的上下文快照测试。若改变消息投影/布局/viewport，执行仓库规定的聊天 UI 回归。

### 2.4 阶段完成门槛与回退

- 冻结集中必要证据、用户约束、错误和审批记录漏失为 0；完整原文恢复率 100%。这些是测试集门槛，不是对所有真实任务的保证。
- 任务正确性不低于基线；适用长文本场景的主模型实际输入 token 中位数减少目标至少 20%。计入 Jev 成本、追加恢复调用和压缩成本后再判断收益。
- 不得通过删除更多内容掩盖答案退步；未达到质量或总收益门槛时保持 off/shadow。
- 关闭筛选后旧流程立即可用，原始会话和工具输出完整，既有摘要仍可读取。

## Phase 3：模型调度与网页自动化

### 3.1 交付目标与依赖

依赖前两阶段的客户端、配置、身份、预算、工具暴露和请求投影契约。包含两个交付部分：先完成子任务模型选择，再完成 WebMount 有界快速循环，最后验证三个 phase 的组合行为。

主聊天模型保持用户选择。自动调度只作用于现有规则允许从模型池选择的子任务启动/followup 边界。网页自动化第一版只覆盖具备语义快照和 revision 校验的桌面 WebMount 后端。

### 3.2 先读的文件

| 文件 / 符号 | 需要保护的行为 |
|---|---|
| `IOSSubAgentModelPool.swift` | 当前负载与轮转、可用候选、并发 reserve/release |
| `IOSThreadOrchestrationToolService.swift` | spawn/followup 的显式模型、继承、角色默认、工具 scope 和思考深度优先级 |
| `SubAgentRunner.swift`、`IOSAgentToolEngine.swift` | 实际子模型执行、取消、工具循环、终态 |
| `IOSWebMountDesktopBackend.swift` | session/page identity、snapshot ID/revision、元素身份和执行策略 |
| `ChatToolRuntime.swift`、工具声明/暴露模块 | 网页工具的真实调用、权限/审批与前后台分发 |
| `IOSToolLoopGuard.swift`、`IOSAgentRunLedger.swift` | 硬循环限制、动作账本、未知结果与恢复 |

`core/agent-runtime/.../ModelRouter.kt` 当前是抽象声明，不能只在这里实现一个类就当成 Swift 模型调度已接线。

### 3.3 按顺序执行：模型调度

**步骤 1：锁定现有优先级与任务数据。**

- 用测试固定显式 model_id/reasoning、角色默认、继承模型和池选择的优先级；Jev 不覆盖用户或既有配置的明确选择。
- 从已创建的子任务说明提取最小任务上下文；所需外发范围未允许时直接使用现有选择。
- 准备至少 20 个任务样本，覆盖文本整理、代码修复、复杂分析、视觉任务、长上下文、工具需求和无合适候选。

**步骤 2：构建合法模型候选。**

- 只使用用户当前启用且配置有效的池中模型，按模态、tools、上下文容量等已知能力做硬过滤。
- 能力描述来自已有 metadata 或明确配置；未知能力/价格标 unknown，不只按名称推断强弱。首版不新增自动模型 benchmark 服务。
- Jev 判断任务所需能力和复杂度，返回适配候选/评分；程序再使用现有负载与轮转选择。不确定或无充足证据时使用现有策略。

**步骤 3：接入实际启动并保护并发。**

- 在原本允许自动选池的分支加入异步判断，不给已有任务每个模型调用都重选。
- 等待网络期间不提前占用名额。返回后在 MainActor 重新验证候选、配置、run 与负载，在不插入 await 的临界段完成 select+reserve。
- 继续原 release 路径，成功、失败、取消、配置失效均不得泄漏预留。
- 保留原显式思考深度；仅在自动选择场景使用候选支持的合法值，不生成 provider 不支持的参数。
- 同一子任务工具循环内保持模型，避免无依据的缓存失效和上下文迁移。

**步骤 4：验证真实执行效果。**

- 不仅验证选中了哪个模型，还要验证实际 provider/model 参数、工具权限和最终任务产物。
- 对样本运行真实 baseline/Jev 对照，统计完成质量、实际 token、缓存、费用和耗时；旧 token 乘新价格只能作为估算，不算节省证明。

### 3.4 按顺序执行：网页自动化

**步骤 5：定义有界工具契约和 dry-run。**

- 增加一个通过现有工具 discovery 暴露的实验性有界网页操作入口，建议名 `wm_run_goal`；实施先查重，若已有等价入口优先复用。
- 输入明确包含当前 session、用户目标、允许的操作范围、完成条件和更小的可选预算；运行时预算不能被输入调大。主模型显式调用该工具才进入快速循环。
- 输出结构化状态：completed、handback、needs_user_action、cancelled 或 outcome_unknown，以及真实执行步骤、最新状态/来源引用、未完成原因。名称可沿已有类型映射，但语义必须可区分。
- 先 dry-run 只产生决策轨迹，不执行动作。shadow 也不得点击、输入或改变页面。

**步骤 6：从真实快照生成动作候选。**

- 每轮观察当前页面，只用本次快照中合法的元素和操作。Jev 消费结构化状态，不宣称具备截图视觉理解。
- Choice 选择操作；各操作对应的兼容目标可以同一次请求独立评分，执行时只消费所选操作的目标。不能把不同操作的结果拼成非法组合。
- 第一版支持已有后端可执行的有限操作，如观察、滚动、选择控件、受策略允许的点击/输入。CLICK 不能一概视为只读。
- 文本值由主模型提供或调用现有生成入口产生；缺值/复杂表达/无法确定目标时交回主模型，不让 Jev 生成任意字符串或脚本。

**步骤 7：经过现有校验和账本执行。**

- 动作前重查 session、page identity、snapshot revision、元素身份和配置/权限。失效就重新观察，不猜 selector、坐标或复用旧目标。
- 每个实际副作用动作进入现有执行器、审批和 ledger。外层工具一次允许不能替代内层每步权限判断。
- 未知执行结果保持 outcome_unknown，禁止自动重放可能已经发生的动作；只有已证明安全的重试才走现有恢复路径。
- 网页状态中的指令是不可信内容，不能授予工具、账号或数据权限。支付/提交/删除等仍沿现有规则处理，不把模型高分当授权。

第一版动作范围如下。动作语义必须来自已验证的工具能力/页面控件契约与现有策略，不能仅凭按钮文案、HTTP 方法或 Jev 分数推断。任何更严格的现有策略优先；第一版不覆盖的动作返回主模型，主模型继续走原有流程。

| 动作 | 快速循环准入条件 | 审批与完成检查 | 返回类型 |
|---|---|---|---|
| 观察、读取、滚动 | 当前 session 已允许访问，快照有效 | 沿原读取范围；核对新快照/滚动状态，无需新增审批 | 可继续；失败 handback |
| 选择筛选项、展开控件、导航链接 | 已确认是当前目标内的读取/导航，不伴随提交或状态写入 | 原策略允许；检查选中值、展开状态或目标页面身份 | 可继续；语义未知 handback |
| 输入/修改草稿值 | 用户目标已包含该输入，值明确、目的地已允许；控件不会随输入自动提交或触发未授权 autosave | 敏感数据仍按现有外发审批；检查真实字段值，禁止日志存密码等内容 | 可继续；缺值/自动提交不明 handback |
| 提交只读搜索/筛选 | 已验证的搜索能力契约，限定当前查询范围且没有外部业务副作用 | 沿现有策略；独立检查查询条件和实际结果，不以点击成功结束 | 可继续；契约缺失 handback |
| 发送消息、发布、修改记录、一般表单提交 | 第一版不进入快速动作白名单 | 交回主模型和原执行器确定具体授权/审批；不在快速循环里自动确认 | handback；原流程需用户时 needs_user_action |
| 删除、支付、购买、权限/账号变更、验证码/登录处理 | 第一版不进入快速动作白名单 | 沿原主模型/用户流程处理，不代用户确认、不绕过系统提示 | handback 或 needs_user_action |
| 任意动作执行后结果未知 | 禁止再次执行同一潜在副作用动作 | 保留 ledger 状态，优先只读核验；无法核验就交回原恢复流程 | outcome_unknown |

**步骤 8：限制循环并独立验证完成。**

- 默认最多 6 次动作决策、15 秒、3 次无进展，且受 run 总预算约束。一次原地等待也计步数/时间，不无限轮询。
- 取消、锁屏/后台、会话切换、权限变化、低置信度、验证码/登录或预算耗尽时，按现有 owner 语义停止执行并交回主模型或用户处理。
- Jev 的 DONE 只是候选终态。完成要由页面/业务状态核验，例如筛选值及列表结果；“点击成功”不能代表任务成功。
- handback 输出给主模型足够的最新状态、已执行动作和剩余目标。通过正常工具结果继续主模型一轮；不得为了等待 Jev 偷增工具轮数或后台保活。

### 3.5 全链路验收步骤

**步骤 9：三个 phase 组合验证。**

至少覆盖以下端到端流程：

1. 自然语言工具搜索 → 语义找到工具 → 下一轮真实调用 → 读长文 → 筛选并恢复引用 → 正确回答。
2. 记忆召回 → 用户 steer/纠正 → 重新准备请求 → 注入和 citation 对应新选择，旧结果无效。
3. 并发子任务 → 模型适配 → 原子预留 → 实际 provider 执行 → 成功/失败/取消释放。
4. 主模型调用网页有界工具 → 页面变化 → 快照失效重观察 → 有界动作 → 独立完成检查或 handback。
5. 前后台切换、网络中断、Key 清除、关闭 Jev → 停止新增请求/动作 → 原有流程可继续。
6. 同一 run 中工具发现、记忆、筛选和网页竞争预算 → 有界降级，不死锁、不超预算、不串会话。

**步骤 10：逐用途启用和最终交接。**

- 每用途分别测试 off/shadow/active、无 Key、401、429、超时、取消、撤销数据范围、过期回调和预算耗尽。
- 真机验证移动网络、弱网、锁屏/后台和取消；模拟器只提供模拟器证据。没有真机时记为待验证，不写“后台稳定”。
- 交替运行 baseline/Jev，报告全部尝试和失败。按固定模型/问题/策略版本分析，升级版本重新验证受影响部分。
- 先工具/记忆，再上下文，再调度/网页，按各用途门槛逐一启用。收益不成立的用途保留 off/shadow，并说明原因；不为了宣布完成强行全开。
- 写 `docs/reviews/jev/phase-3-report.md` 和 `docs/reviews/jev/final-report.md`，包含实现范围、命令、证据、指标、逐用途模式和剩余缺口。发布 App 是独立任务。

### 3.6 必须执行的检查与门槛

新增 `IOSJevSubAgentRoutingTests`、`IOSJevWebMountLoopTests`；沿现有测试模式完成，无需新增测试框架。

原有回归：`IOSSubAgentModelPoolTests`、`IOSSubAgentEngineRunnerTests`、`IOSOrchestrationToolTests`、`IOSSharedSettingsStoreSubAgentOverrideTests`、`IOSWebMountDesktopBackendTests`、`IOSWebMountAutomationContractTests`、`IOSWebMountOutputBudgetTests`、`IOSToolLoopGuardTests`、`IOSAgentToolEngineTests` 及受影响的后台/ledger 测试。

模型调度必须覆盖：显式选择优先、继承、禁用 provider、无 Key、不兼容能力、配置在 await 中变化、并发 reserve、取消 release，以及实际执行参数。

网页必须覆盖：页面跳转、元素换身份、旧快照、外层/内层审批、重复副作用、未知结果、文本值缺失、预算、取消、DONE 误判和 handback。先在受控本地页面真实操作，再测明确授权且无外部副作用的真实站点。

验收门槛：

- 显式模型配置被覆盖、非法模型选择、预留泄漏、越权网页动作、重复副作用、旧状态执行均为 0。
- 至少 20 个代表性子任务、20 个受控网页任务有独立结果检查；相同条件下完成质量/完成率不低于基线，再比较总费用/耗时。
- 启用还需有实际收益：模型调度的总费用中位数至少降低 10%，或端到端耗时中位数至少降低 15%；网页快速循环的端到端耗时中位数至少降低 15%。均计入 Jev、重试、缓存失效与 handback 开销；另一个资源维度的中位数和耗时 p95 不得恶化超过 5%。这些是初始产品门槛，样本不足或价格未知时不能声称成本收益成立；只有质量持平而无收益则保持 off/shadow。
- 所有动作有状态和归属记录，预算耗尽可返回主模型，未知结果不重放。
- 三阶段组合与总开关回退通过；Phase 1/2 的硬门槛仍成立。
- API/真实行为/真机证据缺失时，只能报告代码与离线验证完成，对应 active 仍禁用。小样本成功不等于通用可靠性承诺。

## 构建、测试与证据记录

### 通用执行方法

每个 phase 在首次改变原行为前运行相关旧测试，再运行新增行为测试。阶段内只重复被修改或失败影响的检查；三步结束后做组合回归。报告必须包含实际执行 test count，过滤出 0 个测试不算通过。

新增 Swift/fixtures 后检查 `iosApp/project.yml` 的 source/resource 配置，必要时生成工程：

```bash
cd /Users/mi/Downloads/AI/AmberAgent/ios/iosApp
xcodegen generate
```

生成 `.xcodeproj` 不提交。若缺 native/CPython 制品，沿仓库脚本恢复或记录阻塞，不能关闭预构建校验。

在根目录运行共享工具与 bridge 检查（实际修改时）：

```bash
./gradlew :feature:tools:api:jvmTest :shared:jvmTest
./gradlew :shared:linkDebugFrameworkIosSimulatorArm64
```

Swift 定点测试示例，新增类接入 target 后执行，按各 phase 列表替换：

```bash
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:iosAppTests/IOSJevClientTests \
  -only-testing:iosAppTests/IOSJevDecisionCoordinatorTests \
  -only-testing:iosAppTests/IOSSettingsWiringTests test
```

若修改聊天投影、布局、viewport，按 AGENTS.md 额外运行：

```bash
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests test
```

设置 UI 使用现有视觉系统，完成本地化、辅助功能、错误状态和重启检查，不顺带改主题。

### 每阶段必须留下的报告

报告文件位置：`docs/reviews/jev/phase-1-report.md`、`phase-2-report.md`、`phase-3-report.md`。执行时才创建实际报告，不提前写通过。

```markdown
# Phase N — 阶段名

代码状态：未开始 / 部分完成 / 完成
离线检查：not_run / passed / failed
真实 API：not_run / passed / failed / blocked
真实业务和真机：分别记录
用途模式：逐项 off / shadow / active
基线 commit 与工作区状态：

## 步骤完成情况
逐项对应本计划，标清已完成与剩余步骤。

## 变更文件与理由

## 已执行检查
命令、退出码、测试数、日志/结果路径；未跑项明确写未执行。

## 对照结果
样本量、模型/问题/策略版本、基线与 Jev、失败、漏报/误报、延迟、usage、费用估算日期。

## 阻塞、回退与下一步
影响哪个门槛、目前禁用哪些用途、还可继续什么工作。
```

总体完成要求：三步实施和定点/组合检查完成，每个用途都有可复现证据与明确启用结论。真实验证缺口必须保留，不能用“全部完成”概括未验证用途。

## 直接交给 AI 的执行指令

> 请执行 `/Users/mi/Downloads/AI/AmberAgent/ios/docs/product/jev-integration-execution-plan.md`，严格按三个 phase 推进：1）工具发现与记忆召回，2）上下文筛选，3）模型调度与网页自动化。先读取适用 AGENTS.md 和工作区状态，保护用户已有修改。把每阶段内部的客户端、设置、数据范围、真实调用链、定点测试、回退与报告全部完成，不只新增未接线的类。独立子任务可以使用 Codex 原生子代理，公共入口由主代理整合。没有 Key 或真机时继续可做的离线实现，将对应真实验证单列 blocked，保持未验证用途禁用；不得用 mock 结果冒充真实效果。不要额外扩展记忆整理或通用审查功能，不读取兄弟仓库、不改小说/vendor/无关发布文件、不发布应用。最后按用途报告实际效果、启用状态和剩余缺口。
