# iOS 性能计划（2026-09-29）

前序：`3425d77`（发送气泡上屏与入场动画不再被同步计算阻塞）。本计划在独立 worktree
`ios-perf`（分支 `perf/send-path-smoothness`）推进，不触碰主工作区 `main`（其他线程在用）。

## 硬约束

- 不降帧、不减动画、不降画质、不放慢流式节拍、不改布局与间距（除非修复错位）。
- 只删除重复、不可见或放错线程的工作；保持既有行为契约（`iosApp/AGENTS.md`）。
- 精准下手：不加无消费者的兜底、不引入新协调层，除非该项必须。
- 测量先行：改动前后用同一方法对比；无法测量的不宣称改善。
- 资源：同时最多 2 个 xcodebuild，`-jobs 4`，各用独立 `-derivedDataPath`；
  禁用 xctrace `SwiftUI` 模板（单次可吃 19 GB 内存），只用 Time Profiler。

## 已知问题清单（来源：真机 trace 与代码审查）

| # | 问题 | 证据 | 归属阶段 |
|---|---|---|---|
| Q1 | 发送时 `withAnimation` 插入消息后又在事务外清空输入框，逼 SwiftUI 在点击回调里同步整页重算 | 每次约 25ms（Debug） | P1 |
| Q2 | 首页行携带 4 个闭包，无法跳过重算；语义图标每行每次按标题扫描关键词表 | 每次发送后首页重算 5 轮以上 | P1（行/图标）+ P4（可见性） |
| Q3 | `ChatView` 空闲时读 `viewModel.messages` 计算回顾是否可用、是否过期，每条消息都触发整页重算 | 代码审查 | P1 |
| Q4 | `ConversationActivityCenter` 每次刷新都用 `listAllRuns` 全表查询 | 代码审查 | P1 |
| Q5 | `weightedTokenChars` 按 Unicode 标量遍历 Kotlin 桥接字符串（foreign string） | trace 中出现 `foreignErrorCorrectedScalar` | P1 |
| Q6 | `AmberTableLayout.makeCache` 在动画帧里重建 | 动画窗口内 8 个样本 | P1（先查因） |
| Q7 | 8 个原本就失败或不稳定的测试，干扰回归判断 | 基线复跑 | P0 |
| Q8 | 音频保活同步激活会话并启动 `AVAudioEngine`（阻塞 75～110ms）；Live Activity 在 500ms 时同步做 IPC | trace | P2 |
| Q9 | 每轮工具调用都在主线程上跑 `prepareUploadMessages`（缓存后约 44 个样本） | trace，每轮约 10 秒一次 | P3 |
| Q10 | 屏幕 body 直接读原始可观察集合、在 body 里做 IO；被聊天页压住的首页仍随数据重算 | 多处 | P4 |
| Q11 | 提交阶段中文可变字体光栅化（`ItemVariationStore`、Clipper 轮廓裁剪、`drawGlyphs`）占比高 | trace | P5（评估） |

## 阶段

### P0 测量基础设施与测试基线
- `iosApp/scripts/perf/`：`record.sh`（真机或模拟器 attach 录 Time Profiler）、`analyze.py`
  （主线程时间线 25ms 分格、区间包含样本 top、两份 trace 以锚点函数对齐 A/B）。
- `ChatPerfTrace` signpost：发送、生成启动、请求准备、首个 delta、终态。
- Q7：逐个判定是测试过时、时序不稳定，还是真实缺陷，分别处理（改测试或修代码），不跳过。
- 验收：脚本可对现有 trace 复现本轮结论；Q7 中的用例稳定通过（不稳定的连跑 3 次）。

### P1 小改动批量（按文件归属并行）
- G1 `ChatViewModel`/`ChatView`：Q1、Q3。
- G2 首页（`PlaceholderViews.swift`）：Q2 的行可判等与图标缓存。
- G3 `ConversationActivityCenter`、`IOSContextCompactionCoordinator` 字符串扩展：Q4、Q5。
- G4 Markdown 表格：Q6 先查因，确认后再改。
- 验收：行为不变；各项有前后对比（模拟器回放或单元级计时）。

### P2 运行启动编排
- 音频保活的会话激活与引擎启动移到后台串行队列。保活状态区分“启动中”和“已播放”；
  系统长任务的抑制以“启动中或已播放”为准，启动失败再提交系统任务。
- Live Activity 的 request/update IPC 移出主线程，runId 所有权与深链/Watch 判定不变。
- 生成启动的延后继续以 `userMessageSendSpring.duration` 为界，不另设第二套时钟。
- 验收：点击发送到动画落位期间主线程无系统 IPC；`BackgroundAudioKeepAliveTests`、
  `BackgroundGenerationKeepAliveTests`、`AgentActivityDeepLinkTests` 通过并补齐新状态的用例。

### P3 请求准备移出主线程（拆分：P3a 在 P2 后执行；P3b 放到 P7 之后）
- P3a（不触碰压缩协调器）：技能文件按路径+修改时间缓存（每轮请求都在主线程列目录、读 Markdown）；
  记忆召回每次请求只计算一次并复用（现有 `memoryRecallOverride` 通道）；KMP 系统时区缓存
  （每个 `UIMessage` 构造都重新解析时区文件）。
- P3b：`editPreparedContext` 等压缩路径的纯计算移出主线程。主工作区另一线程对
  `IOSContextCompactionCoordinator.swift` 有约 586 行未提交重构，待其提交后基于其结果执行，
  否则记为阻塞项。

- 主线程只取不可变快照（消息、设置、记忆记录、工具目录、压缩记录），纯计算（token 估算、
  压缩规划、记忆召回打分、运行时注入、PromptTranscript 准备）在后台执行，结果按 runId 验收。
- 与主工作区的上下文压缩重构（另一线程）存在文件重叠：开工前先同步其已提交内容。
- 验收：请求内容与改动前逐字节一致（现有请求快照测试）；流式多轮期间主线程无 `prepareUploadMessages`。

### P4 页面投影与规范
- 首页：由 model 维护可判等投影，首页不可见（被导航压住）时不刷新投影，回到首页时刷新一次；
  body 内不做 IO。
- 聊天顶栏与输入栏：只读投影，不直接读 `viewModel.messages`。
- 规范写入 `iosApp/AGENTS.md`：环境值可判等或身份稳定；可观察集合“有变化才发布”；
  body 内禁 IO/解码；交互事件内禁同步系统 IPC。配一个源码卫生测试覆盖可静态识别的条目。

### P5 回归防护与字体评估
- 发送路径行为测试：`sendMessage(startsGenerationAfterInsertion: true)` 返回时 run 未同步启动，
  入场时长后启动；窗口期内停止/再发送作用于本轮 run。
- 字体：量化可变字体与同字重静态实例的光栅化成本，字形一致且收益显著才替换。

### P6 多子代理并发场景（P0–P5 完成后开始）
- 目标：多个子代理同时运行（流式输出、工具调用、像素头像与活动岛、子线程会话、mailbox）时，
  主线程不因并发叠加而掉帧，视觉效果不降级。
- 先测量：用 P0 脚本在 2–4 个子代理并发时录制，定位每个 run 叠加的主线程成本（每轮请求准备、
  流式 bump、活动广播、子线程持久化、头像动画），以及跨 run 的重复工作。
- 再分类：每个问题判定为小改、小重构或架构调整，出完整计划后执行，同样走 review 闭环。

### P7 小说创作与模型议会（P6 完成后开始）
- 覆盖：小说创作（项目列表、工作区、会话流式生成、候选稿、设定集）与模型议会（多席位并行发言、
  讨论轮次、存档检查点、续接）两条链路的关键交互。
- 先读 `iosApp/iosApp/NovelCreation/AGENTS.md` 的候选稿、项目状态、注入与生成终态契约；
  已有的 `docs/novel-performance-plan.md`（主工作区未提交）与 9 月 25 日计划 Phase 4 的执行记录作为输入，避免重复。
- 同样先测量、再分类（小改 / 小重构 / 架构调整）、出计划、执行、review 闭环。

## 每阶段闭环
实现 → 独立 review 子代理（逻辑闭环、调用链、UI 错位/对齐/间距/尺寸）→ 精准修复 → 受影响测试
（聊天三件套 `ChatSwiftUIStreamReplayTests`、`NativeTimelineScrollCoreTests`、
`ChatViewportPolicyTests` + 定点）→ 本文件追加执行记录 → 提交。

## 执行记录

### 2026-09-29 P0 + P1
- P0：`iosApp/scripts/perf/`（record.sh、analyze.py、README）用既有 trace 复现了发送卡顿全部结论；
  `ChatPerfTrace` 增加 SendTap、GenerationKickoff、PrepareUpload、FirstDelta、RunTerminal。
- P0 基线测试：
  - 权限快照、顶栏源码断言、首页两条源码断言、字形尺寸假设、续接卡首行、工具声明 parity（`subagent_dispatch` 自 bf53f8e 由
    `spawn_agent` 系列替代且经 tool_search 暴露）按有意的产品变更更新测试；
  - WebMount 点击在不挂窗口的 WKWebView 中不派发 focus/focusin（撤掉补发后轮询 3 秒仍失败，证实是缺失而非延迟），
    改为“本次新聚焦且无原生事件”时补发；
  - 时序阈值用例在机器空闲时通过；`testPerfGrowingTableStreamingKeepsDisplayLinkResponsive` 的单帧 max 在构建并发时
    曾到 81ms（阈值 80ms），p95 24–27ms；
  - 已知未解：`testTerminalBeforeFirstAttach…`、`testEveryGenerationTerminal…`（终态后晚到大幅内容增长时，系统把滚动
    位置合成到新底部；驱动器与 defaultScrollAnchor 均已排除，未定位写入方），留待 P4 处理滚动相关代码时再查。
- P1：
  - Q3 聊天顶栏的回顾可用/过期/投影改读 `ChatListSummarySnapshot`（userMessageCount、lastMessageID、recapBranchID），
    body 不再观察 `messages`；
  - Q2 首页行 Equatable（只比较显示字段）并 `.equatable()`，语义图标按入参缓存；
  - Q6 `AmberTableLayout.updateCache` 以内容指纹（表格源文本、样式、动态字号、粗体、列数）加子视图数复用测量；
  - Q1 不做：提前的图更新计算的是气泡帧本身，消除它需把清空输入/附件并入弹簧事务，会改变附件托盘的视觉；
  - Q4 不做：`listAllRuns` 在 Room 后台调度器执行，所有 trace 中该路径样本为 0；
  - Q5 不做：token 估算加缓存后仅剩 7 个样本；请求准备剩余成本为 `editPreparedContext`（约 50%）与运行时注入，归 P3。
- Review（子代理）：采纳终态落盘失败路径补 RunTerminal、清理过时注释；首页行环境值（@Environment 独立失效，不受 `.equatable()`
  拦截）与相对时间（改动前后一致）判定无需修改；WebMount 重复触发的前提（事件延迟到达）经实验证伪。

### 2026-09-29 P2
- 音频保活：session 激活/反激活、AVAudioEngine 构造/启动/停止移到私有串行队列（可注入 runner），主线程以代次号验收；
  新增“启动中”状态与 `isStartingOrActive`。`BackgroundGenerationKeepAlive` 中 begin 抑制系统任务、首 token 升级、
  提交守卫、UIKit 短窗到期判定改用“启动中或播放中”（到期判定若仍用 isActive 会把启动中的 run 当场终止）；对外断言、
  日志、放弃系统任务、空闲保留仍用“确认在播”。音频最终启动失败经变更通知在前台补交系统任务（排除已挂一次性重试的租约，
  否则会重复提交）。
- Live Activity：授权查询、`Activity.activities` 枚举、`Activity.request` 放到后台（ActivityKit 接口未标注 @MainActor）；
  去掉 5ea1795 的 500ms 延迟与 willResignActive 补做；`pendingStarts` 改为“请求在途”，在途 update 刷新展示、end/stopCurrent
  记录撤销，落地后撤销则立即结束卡片，否则补一次最新展示的 update；在途时再次 start 清除撤销。增加测试注入点与在途状态用例。
- Review 修复：stop 后立即 start 时旧一代清理会在串行队列上反激活新一代刚激活的会话 → 队列内会话激活序号，仅序号未更新时反激活；
  启动在途切后台导致落地使用过期的 exclusive → 落地时按当前状态重投类别；Live Activity 在途撤销后再 start 未清撤销标记。
- 流式表格：尖峰测试走 vendor `TableLayout`（非 AmberTableLayout）。给 vendor 加内容指纹缓存后，计数实测整个用例仅 5 次整表测量、
  累计 24ms（命中 18 次），p95/max 与改前无可测差异 → 回退 vendor 改动；另一“增量 vs 全量”测试经对照实验证明对原版同样失败
  （读取到中间帧），删除。流式表格帧尖峰（约 70–116ms，单帧）的真实来源待 P5 用 Time Profiler 定位。
- 已知：`testPerfGrowingTableStreamingKeepsDisplayLinkResponsive` 在基线与本阶段均在阈值附近波动（max 67–116ms）。

### 2026-09-29 P3a
- 技能目录列表与 SKILL.md 按路径缓存、mtime 失效、store 写入主动失效（每轮请求准备不再在主线程列目录读文件）。
- 记忆召回：基线注入与最终注入各算一次（原三处各算），最终注入仍在压缩与投影之后现算（审查指出复用开头快照会在 await 期间
  错过记忆写入，已改回原时机），usage marking 复用最终注入结果。
- ai-core `Message.kt`：`TimeZone.currentSystemDefault()` 60 秒快照缓存；前台期间改时区至多 60 秒内的时间戳沿用旧时区（接受）。
- 验证：iOS 161 项定点测试；`:ai-core:jvmTest`、`:ai-core:iosSimulatorArm64Test`。

### 2026-09-29 P4
- `iosApp/AGENTS.md` 新增“SwiftUI 失效与主线程纪律”（环境值可判等、被观察集合有变化才写、body 禁 IO/解码/权限查询、
  交互事件禁同步系统 IPC、父视图读投影、自定义 Layout 需 updateCache、重复纯计算须缓存并附测量）。
- `PerformanceHygieneTests` 锁住本轮修复点。审查发现同类遗留：`MessageBubbleView` 流式 Markdown 与 `ChatSubAgentResultCard`
  每次 body 新建 `OpenURLAction` 注入 `\.openURL` → 改为常量 `ChatMarkdownOpenURLPolicy.openURLAction` 并纳入测试。
- 聊天页 body 复核：剩余 `viewModel.messages` 读取均在点击/事件闭包；首页被导航压住时冻结观察——P1 后首页单次重算成本已低，
  冻结需维护快照与返回时同步，风险大于收益，不做。
