# iOS 性能优化执行计划（2026-09-25）

硬约束：不降帧、不减动画、不降分辨率/画质、不放慢流式发布节拍、不改布局与间距。只删除重复或不可见的工作。
不做过度防御：不加无消费者的兜底分支、不引入新协调层，除非该项必须。每项改动保持现有行为契约（见 `iosApp/AGENTS.md`）。

来源：4 路只读审计（聊天流式、视觉效果、主线程/IO、SwiftUI 失效）+ 人工抽查核实。

## Phase 1 — 明确的主线程/重算浪费（低至中风险）

1. `contextSnapshot` → `nextTurnOccupancyTokens` 每次读取都同步 `Data(contentsOf:)` 解码 compact sidecar 并建全量消息 ID Set。改为按会话缓存 compact 列表（写入/删除时更新），一次视图更新内复用同一快照。
2. `ChatView` 根 `body` 读取 `messageUpdateSignal`（流式约 21 次/秒）导致顶栏、输入栏随之失效。把读取与 onChange 处理下沉到时间线子视图。
3. 选图/拍照路径 `UIImage(data:)` + `ChatImageEncoder.encode` 在 MainActor 上执行。编码移到后台，输出字节与参数不变，仍按原会话 ID 与原顺序提交。
4. `IOSLocalToolExecutor` 初始化即取 `IOSWebMountController.shared` 导致冷启动创建 `WKWebView`。改为首次使用本地 runtime 时再创建，会话元数据照常恢复。
5. 思考球/边缘光 display link 在 App 非 active 时仍绘制；图片生成占位卡 30fps Canvas 未接可见/运行状态。接入 scenePhase 与已有 `isAnimating`，恢复时按绝对时间取相位。
6. 首页 `ConversationGeneratingRing`（不限速 `TimelineView(.animation)`）与 `CurrentConversationAvatarGlow`（30fps 重建 blur）改为 Core Animation 驱动，曲线/周期/颜色一致。

## Phase 2 — 流式 Markdown 与表格增量

1. 流式分块器（`MessageBubbleView` 分块实现）保留已闭合块边界与围栏/表格状态，只扫描追加尾部；非追加更新回退全量。
2. 活动表格：按行内容 + 配置缓存单元格 attributed string 与测量结果；列宽变化按原算法重测。

## Phase 3 — 持久化与会话切换移出主线程

1. KMP `saveConversation` 读改写切到 `Dispatchers.Default`（保留 `operationMutex`、字段合并语义）。
2. 切会话时 steer 队列/compact sidecar 的同步读取移到后台，按会话 ID + 修订号验收结果。
3. 输入栏待发图片缩略图按附件 ID 缓存 `UIImage`，不在 body 中反复解码。

## Phase 4 — 其他页面根失效与空闲轮询

1. 小说页、议会页：流式尾行读取下沉到 transcript 子视图；小说行投影只替换活动尾行，不复制过滤全表。
2. `NativeTimelineScrollViewResolver.Coordinator` 常驻 60Hz display link 改为 KVO（contentSize/bounds/adjustedContentInset）事件驱动，保持回调合并语义。

## 每个 Phase 的闭环

实现 → 独立 review 子代理（逻辑闭环、调用链、UI 错位/对齐/间距/尺寸）→ 精准修复 → 受影响测试：

- 聊天相关：`ChatSwiftUIStreamReplayTests`、`NativeTimelineScrollCoreTests`、`ChatViewportPolicyTests`，按需 `ChatMessageProjectionTests`、`ChatRowContentHashCacheTests`
- 存储：`IOSConversationStoreTests`、`IOSConversationStoreBranchingTests` + 对应 Gradle 测试

## 执行记录

（每个 Phase 完成后追加）

- 2026-09-25 Phase 1：完成 compact 会话缓存、聊天视图失效范围收窄、图片后台编码与顺序/会话绑定、WebMount 首用创建、图片占位动画停帧、首页旋转及光晕动画改造。思考球和边缘光的 App inactive 暂停方案经 review 撤回：inactive 时仍可能可见。
- iPhone 17 Pro 模拟器最终范围测试 139 项中 135 通过、4 失败；其中 3 项首页断言与本轮改动无关，24KB 长文回放单独复测通过。`IOSContextCompactionCoordinatorTests`、`ChatContextSnapshotTests`、3 项 WebMount 定点测试及光效接线测试全部通过。未进行真机视觉、帧时或能耗测量。

- 2026-09-25 Phase 2：先用同一 iPhone 17 Pro 模拟器和 Debug 回放夹具测量，再尝试仅在 Amber 流式路径启用表格单元格富文本与布局测量缓存。缓存键实现曾因直接调用 `Table.Cell.format()` 触发 swift-markdown 的 fatal；改为内联 AST 结构键后回放可完成，但总成本明显退化。流式分块和整段 Markdown 解析未改：前者在表格回放的累计成本较小，后者在长正文回放中并非主要热点，跨围栏、强调、公式与表格增量截断风险过高。
- 增长表格同夹具累计耗时中位数（优化前 5 次／修复版 4 次）：`TableConvert` **172.35 → 214.47 ms**，`TableLayoutMeasure` **75.06 → 447.58 ms**，新增 `TableKeyBuild` **18.34 ms**；三项合计约 **247.41 → 680.39 ms**。长表格用例 P95 帧间隔中位数（三次）**51.61 → 82.59 ms**；24KB 混合 Markdown 的主线程 CPU **优化前中位 89.78 ms/增量（三个有效样本）**，优化后两个有效样本为 **121.03、136.92 ms/增量**，另一重复运行异常退出。长正文夹具三次回放的 `MarkdownParse` **28.19 → 34.71 ms**、`MarkdownConvert` **22.22 → 32.64 ms**、分块 **8.89 → 7.98 ms**（均为累计耗时中位数）。
- 按“总成本下降才保留”规则，已回退本轮 vendor 缓存、Amber opt-in 和全部临时计时探针。六个涉及的代码文件与 Phase 1 快照 `88392b9bfe65b3ea048fab7f2f6758724ef37219` 无 diff；保留其他未提交改动。原始测量日志位于 `/tmp/amber-phase2-before-*`、`/tmp/amber-phase2-after-fixed-*` 和 `/tmp/amber-phase2-after-focused.log`。回退后按本轮明确要求不再跑测试。

- 2026-09-25 Phase 3：`JsonConversationStorage.saveConversation` 在原有 mutex 内转到 `Dispatchers.Default` 执行读改写；iOS conversation store 在异步保存前预留写序号，供返回时识别并发写入。steer 队列 sidecar 在后台读取，按会话状态修订号验收；输入栏图片缩略图按附件 id 持有已解码图片。compact sidecar 的重复读取已由 Phase 1 会话缓存覆盖，本期未再改动。
- 验证：指定 iPhone 17 Pro 模拟器的 `IOSConversationStoreTests`、`IOSConversationStoreBranchingTests`、`IOSSteerQueueTests`、`ChatViewportPolicyTests`、`ChatSwiftUIStreamReplayTests`、`NativeTimelineScrollCoreTests` **165/165 通过**；`core/conversation-storage` 的 `JsonConversationStorageTest` JVM **22/22 通过**。未遇到需修复的 Phase 3 失败；这两层结果不代表真机性能测量。

- 2026-09-26 Phase 4：小说转录与议会转录把逐拍读取收进子视图，原生滚动探针按布局事件驱动。独立 review 后修复四处闭环：`terminalAwaitingRefresh` 恢复可观察，Council 的讨论轮次与消息非空状态仅在消息数量变化时更新并由根视图读取，`NovelSessionReplayTests` 的源码断言改为 `onInitialRows(listSignal)`，原生 Chat 的 `onScrollGeometryChange` 在可视高度或上下 inset 改变时通知 scroll driver。集成编译另修了小说投影 `lastRowDigest` 的两个缺失 `return`，并把滚动通知从旧 SwiftUI 列表移到生产 `NativeChatTimelineView`。
- 指定模拟器合并运行 4 个聊天类及检索到的 47 个 Novel/Council 类：**1258 项中 1236 通过、20 失败、2 跳过**；聊天、Council 和 `NovelSessionReplayTests` 无失败。按方法在 Phase 3 worktree（独立 DerivedData）重跑这 20 项：**18 项同败、2 项通过**。两项基线通过的 AskUser 与后台续跑，在主工作树隔离运行分别有通过记录；后者在 Phase 3 基线再次单跑也失败，主/基线的 `NovelGenerationLifecycle.swift`、`NovelActions.swift` 与测试源码逐字相同，失败位于测试固定 1 秒等待处。主工作树的两项加 `NovelSessionReplayTests` 定点复跑 **51 项中 50 通过、仅后台续跑失败**。因此未确认稳定的 Phase 4 独有行为失败，没有改动小说生命周期或其它既有失败路径；基线 worktree 源码未编辑。该 worktree 还保留 Phase 2 vendor/计时探针的未提交差异，此对照仅用于本批方法的失败归因，不代表两边构建内容完全相同。
