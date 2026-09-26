# Chat 顶栏：活动岛 · 跨对话卫星 · 右上角停靠位 / 产物架

状态：执行中（2026-09-26）
范围：`iosApp/iosApp` 聊天页顶栏（`ChatView.topBar`）及其下游。

## 产品定位

- **活动岛** = 当前对话的"现场"：点它回到正在发生的地方，长按停止。
- **右上角停靠位** = "东西送达的地方"：
  - 平时是**产物架**按钮（本对话成果），新产物生成时缩略图"飞进"按钮；
  - 其他对话出现需要注意的事件时，按钮变形成**卫星**；
  - 空对话有其他对话提醒时显示卫星，无提醒才隐藏。
- **新对话**从"点一下"降级到"长按停靠位"菜单 + 对话列表页原有入口。

原则：精准实现，不做过度防御、兜底或额外抽象。沿用现有视觉系统（AmberTheme、ChatToolbarIconButton、玻璃样式），不重写导航或主题。
约束：顶栏的侧边按钮与岛**不能**包进同一个 `GlassEffectContainer`（见 `ChatTopBarView` 的独立玻璃布局）；变形沿用同一圆形玻璃内的内容与颜色过渡。滚动定位不得使用 `scrollTo(y:)`、直接写 `contentOffset` 或魔法高度补偿，走现有 anchor / viewport 机制。

---

## Phase 1 — 跨对话活动中心（数据层）

目标：App 级 `@MainActor @Observable` 的 `ConversationActivityCenter`，汇总**非当前对话**的运行与提醒状态。

1. 调查并在本文件"Phase 1 结论"中记录：
   - 从正在生成的对话切走时，run 是否继续（前台 run 转后台 coordinator / 继续前台 / 被取消）。
   - 如何按对话拿到 running / awaitingUser / failed / completed（`IOSChatBackgroundGenerationCoordinator`、`.amberChatBackgroundJobStateDidChange` / `.amberChatBackgroundJobDidTerminate`、agent run ledger / DAO、pending gate）。
   - 若切走会取消 run：不在本计划内改 run 所有权，只记录；卫星仍覆盖后台 job 与编排子线程外的普通后台完成。
2. 模型：
   - `ConversationActivityNotice { conversationId, title, kind(.awaitingUser/.failed/.completed), preview: String?, occurredAt }`
   - 优先级 awaitingUser > failed > completed；同一对话只保留最新一条。
   - 进入该对话即隐藏；completed/failed 按已读消费，awaitingUser 在离开仍等待的对话后重新提醒；手动 dismiss 抑制同一事件。当前对话不展示 notice。
   - running 不产生提醒；Phase 2 不展示 running 集合，因此不另行维护。
3. 在 AppShell 级注入（与 ChatViewModel 同生命周期），ChatView 读取。
4. 单元测试：事件 → notice 的转换、优先级、清除、当前对话过滤。

## Phase 2 — 顶栏交互：岛可点 + 停靠位 + 卫星

1. **岛可点**（移除 `allowsHitTesting(false)`，命中区 ≥44pt 高且不与两侧按钮重叠）：
   - 点：awaitingUser → 滚到审批/问答卡片；tool/image → 滚到 `toolID` 对应工具块并短暂高亮；失败 terminalHold → 滚到失败工具；thinking/generating/waiting → 回到底部并恢复跟随；title（空闲）→ 无动作。
   - 以**点下那一刻显示的 presentation** 为准；播报期间点击打开被播报的对话。
   - 长按（生成中）：`cancelGeneration()` + 触感。
2. **停靠位 `ChatTopBarTrailingDock`** 取代 `newChatToolbarButton`，三态：
   - `.hidden`：当前对话无消息且无其他对话提醒；
   - `.shelf(count)`：产物架按钮；Phase 2 内点击打开产物架面板骨架（空态），Phase 3 填充内容；
   - `.satellite(notice, extraCount)`：卫星，颜色 = 最高优先级 kind（awaitingUser 琥珀呼吸 / failed 红 / completed 绿勾），多条时角标显示提醒总数。
   - 态间切换为同一圆形玻璃的变形（尺寸不变，内容交叉过渡 + 颜色过渡）。
   - 长按：菜单"新对话"（沿用 `viewModel.startNewConversation()`）。
3. **事件到达**：岛横向轻鼓（~1.06，弹簧）→ 一颗光点飞入停靠位；当前对话空闲时岛借用 2.5s 播报"◉ {标题} · 需要确认/未完成/已完成"，然后恢复；当前对话生成中不播报。离开仍等待的对话后，其提醒重现只更新停靠位，不触发到达效果。触感：awaitingUser `.warning`，completed 轻触，failed 无。
4. **卫星交互**：
   - 点：1 条 → 切到该对话；多条 → 岛下方展开小列表（标题 + 状态 + 一行预览），点行切换。
   - 长按：系统 contextMenu 预览该对话最后一条消息。
   - 上划：dismiss。
   - 切换动画：岛旧标题左滑出、新标题右滑入。
5. 无障碍：停靠位 label 随态切换；notice 到达 VoiceOver 播报；Reduce Motion 时去掉鼓动/飞入/呼吸，改淡入淡出。

## Phase 3 — 产物架面板

1. **`ConversationArtifactIndex`**（纯函数，从当前对话消息的工具 part 派生，天然按对话、带轮次/消息位置）：
   - 图片：`generate_image` 结果；
   - 文件：`workspace_file_write` / `workspace_file_edit`，同路径聚合为多版本；
   - 网页：仅 `scrape_web` / `wm_open` / `wm_extract`，按 URL 去重并保留最新来源；
   - 链接不单独做（除非工具结果已有结构化链接）。
2. **面板**：停靠位圆按钮变形为右上锚定玻璃面板（按内容收高，最大 55% 屏高），正文可见且不穿透面板：
   - 上层横向胶片条：图片；网页仅在工具返回真实缩略图时进入胶片条，目前仅在列表展示；
   - 下层分组紧凑列表（文件 / 网页），每行右侧"第 N 轮 ↗"；
   - 多版本卡：牌堆样式，左右滑切版本；文本文件可切"与上一版对比"（数据可得时）。
   - 单项：预览、分享。
3. **定位**：点"↗"后面板收成顶部细条，正文走现有 anchor 机制滚到目标并高亮；下拉细条恢复面板。
4. **飞入**：新产物出现时（当前对话、非首次加载），缩略图/图标从停靠位附近飞入，按钮轻弹，count +1。
5. 空态：说明文字 + 长按消息可收藏的提示（Phase 4 前只写说明）。

## Phase 4 — 收藏片段 · 基于它继续 · 批量导出

1. 消息长按菜单新增"收进产物架"（文本段/代码块/整条消息）；按对话持久化（iOS 侧小型 JSON store，keyed by conversationId，删对话时清理）。
2. 产物项长按"基于它继续"：图片 → 作为待发送图片附加；文件 → 以 workspace 路径引用插入输入框；片段 → 以引用块插入输入框。
3. 多选：存到相册 / 文件、分享；"导出成果报告"：Markdown（采用版本 + 收藏片段 + 来源轮次）。
4. 多版本卡"采用"标记，未采用版本变淡（持久化同 1 的 store）。

## Phase 5 — 活动岛「回顾」（2026-09-26 追加）

目标：空闲时点岛，从岛向下展开本对话的结构化回顾；关键节点可点击跳回时间线。生成中点岛的行为（跳到现场）与长按停止**不变**。

1. **触发与门槛**：岛处于 `.title`（空闲）且当前分支用户消息 ≥3 条 → 点岛展开回顾卡片；不足门槛维持无动作。再次点岛 / 点卡片外 / 下拉收起。
2. **内容（`ConversationRecap`）**：
   - `overview`：一段话（做了什么、结果、未解决的点），不超过约 120 字；
   - `nodes`：3–8 个关键节点 `{ kind(.decision/.milestone/.failure/.artifact), title, messageRef }`；
   - `nextSteps`：0–3 条待办，点一下填进输入框（不自动发送）。
   - 元数据：`conversationId`、`coveredThroughMessageID`（生成时最后一条消息）、分支标识、`generatedAt`。
3. **生成**：
   - 复用辅助模型链路（`titleModelId` → 当前聊天模型回退，同 `generateConversationTitle` / `ConversationListPreviewGenerator`），`writeBaseline` / `canApplyAuxiliaryResult` 防旧写；结果必须写回发起它的对话。
   - 时机：每轮 run 正常结束且过门槛时后台生成（同对话去抖，进行中不重复发起）；从未生成过的对话，点开时现场生成并显示加载态。
   - 增量：已有回顾时，输入 = 旧回顾 + `coveredThroughMessageID` 之后的新消息；否则输入最近消息（有上下文压缩摘要时拼入摘要）。
   - 输出 JSON；解析失败 → 卡片显示失败与"重试"，不静默。
4. **跳转**：喂给模型的每条消息带短编号（如 `m12`），节点只能引用编号；本地映射回 messageID，编号不在当前分支的节点显示为不可点。点节点 → 卡片收起 → 走现有 `ChatMessageAnchor` 定位并高亮该消息。不用 `scrollTo(y:)` / 写 `contentOffset`。
5. **过时**：回顾之后有新消息或切了分支 → 卡片顶部"有新内容 · 刷新"，内容仍显示旧版；刷新走增量生成。
6. **持久化**：iOS 侧按对话的小型 JSON store（同 `artifact-shelf.json` 的放置与删除清理方式），不进备份（与产物架一致）。
7. **视觉**：卡片从岛的位置下展（玻璃样式，与产物架面板同一套圆角/边距），宽度与产物架面板对齐，按内容收高、最大 55% 屏高可滚动；节点行前有 kind 图标，失败为红色；Reduce Motion 下淡入淡出。
8. 测试：门槛、编号映射与越界、增量输入拼装、过时判定、JSON 解析失败、防旧写；截图：加载态 / 正常 / 过时 / 失败。

---

## 每个 Phase 的验收

- `xcodebuild` 构建通过；新增逻辑有单元测试；触碰滚动/定位时跑 `iosApp/AGENTS.md` 规定的三组测试。
- 模拟器截图/交互证据（iPhone 17 Pro）；真机手感记为待验证。
- 独立 review：逻辑闭环、调用链完整；UI 错位、对齐、边距、尺寸。只修真实问题。

## Phase 1 结论

### 调查结果（2026-09-26）

- **切走不会取消普通聊天 run，也不会因切换本身自动移交后台 coordinator。** `iosApp/iosApp/ChatViewModel.swift` 的 `startNewConversation` / 对话选择入口调用 `prepareForConversationChange(to:)`，这里只处理切换门禁和输入附件状态。`conversationRuns` 按对话保留 `ChatConversationRunState` 和 `ChatKernelRunHost`；`reloadFromStore` 保留 `host.isRunning` 的旧对话，`makeGenerationBindings(state:)` 捕获原对话状态，消息持久化仍传原 `conversationId`。因此切到 B 后 A 可以继续运行、等待审批和完成，回到 A 时恢复其原有状态。
- **退到系统后台是另一条链。** `iosApp/iosApp/AppShell.swift` 的 `handleScenePhaseChange(.background)` → `ChatViewModel.handoffGenerationToBackgroundIfNeeded(honorKeepAliveLease: true)` → 每个活跃 `ChatKernelRunHost.handoffCurrentGenerationToBackground`。持有 keepalive 时可继续原 host，否则按现有 handoff 条件交给 `IOSChatBackgroundGenerationCoordinator`。本轮不改变 run 所有权、取消、过期或恢复机制；本地续跑仍受 iOS 后台执行限制。
- **按对话取状态的真相在既有 `agent_run`。** 普通链为 `ChatKernelRunHost` → `ChatGenerationBindings.recordRun` / `markRunAwaitingPermission` / `resumeRunAfterPermission` → `ChatViewModel` 对应方法 → `IOSDurableRunStore.startChatRun` / `transition` → Room。`IOSDurableRunStore.swift` 在成功写入后发送 `.amberSubAgentRunsDidChange`；名称虽含 SubAgent，实际普通聊天也会发送。活动中心用 `AgentRuntimeDao.listAllRuns` 读取 `chat` / `chat_turn`，按 `conversationId` 和最新 `startedAt` 归并。`IOSAgentRunLedger.swift` 记录的是工具事务/事件，不代替这份 run 状态。
- **等待用户不是 `isLoading == false` 的推断。** `ChatKernelRunHost.swift` 的 `approvalDecider` → `markRunAwaitingPermission` 写入 `.awaitingPermission`（Room wire 值为 `waiting_user`，兼容旧 `awaiting_permission`）→ 保存脱敏审批消息；pending gate 本身保留在 `ChatConversationRunState`，`hasPendingUserGate` 聚合当前对话的审批、`ask_user`、未知工具结果。确认后 `resumeRunAfterPermission` 回到 running。活动中心把 `waiting_user` / `awaiting_permission` / `outcome_unknown` 映射为 awaitingUser，failed 为 failed，completed 为 completed；取消、中断、等待外部结果、等待恢复不伪装成完成。
- **后台通知不含终态。** `IOSChatBackgroundGenerationCoordinator.swift` 的 `publishStateEvent` / `publishTerminalEvent` 只发送 conversationId；`.amberChatBackgroundJobDidTerminate` 不能直接映射 completed。活动中心同时监听这两个通知并重新读账本，覆盖 coordinator 所有的 job；普通隐藏对话的 host 通过上面的账本广播覆盖，无需依赖编排子线程边关系；同样包括非当前的 child conversation，本轮没有额外排除规则。`ChatView.swift` 原有两个 handler 继续只刷新当前对话的内容/活动岛，全局聚合由 App 级中心接收。

### Phase 1 实现边界

- `ConversationActivityCenter.swift` 是 App 级 `@MainActor @Observable` 只读投影，在 `AppShell` 与 `ChatViewModel` 同级持有、注入 environment，在既有启动恢复完成后开始观察；`ChatView` 通过 environment 读取；中心观察 store 的切换路径隐藏当前提醒，页面不再重复调用清除。
- 标题来自 `IOSConversationStore.allSummaries`，预览来自 `messages(for:)` 的最后一条 assistant 消息：等待 `ask_user` 按账本 `inputSnapshotRef = tool_call:<id>` 定位当前 gate，用 `ChatToolApprovalRequestBuilder.askUser(for:)` 解析问题，否则用回答开头，压成一行并截到 160 字符。监听 store 修订补齐“账本先变为 waiting_user、审批消息随后落盘”的预览更新，不新建持久化存储。非 `ask_user` 审批若没有 assistant 正文，预览为 nil，不从工具参数拼造问题。
- 提醒按 awaitingUser > failed > completed 排序，同级较新在前。同一对话的新状态替换旧提醒；running、cancelled、interrupted 均移除提醒，不维护 running 集合。completed/failed 在当前对话中按已读消费；awaitingUser 仅隐藏，离开仍在等待的对话后重新提醒。手动 dismiss 消费同一事件，后续新状态仍可提醒。
- 冷启动不把中心创建前的历史完成/失败批量变成新提醒；仍待用户确认的状态可恢复展示。提醒只在内存保留，不改任务、消息、ledger 或 mailbox。
- Phase 1 初次交付只包含数据层；以下验证记录是该次交付的历史证据，不能代替后续 Phase 2 验收。真实后台权限、provider 网络和真机手感仍需专门验证。

### 验证记录

环境：iPhone 17 Pro 模拟器，实际 destination 为 iOS 27.0 / arm64。已运行 `xcodegen generate --spec iosApp/project.yml`；生成的 `iosApp/AmberAgent.xcodeproj/project.pbxproj` 已包含新增生产文件和测试文件（工程是仓库忽略的生成产物）。独立只读 review 已完成；本轮文件的 diff 检查通过，未提交 Git。

构建命令，exit 0：

```bash
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

首批命令，exit 0，xcresult 确认 **27 passed / 0 failed / 0 skipped**，其中新增 `ConversationActivityCenterTests` 为 6/6。该次 test 重新编译并包含最终的 pendingToken 预览定位实现。

```bash
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:iosAppTests/ConversationActivityCenterTests \
  -only-testing:iosAppTests/ChatViewModelConcurrentConversationTests \
  -only-testing:iosAppTests/IOSChatBackgroundExecutionTests \
  -only-testing:iosAppTests/IOSChatBackgroundSuspensionTests \
  -only-testing:iosAppTests/IOSSubAgentActivityStoreTests \
  -resultBundlePath /tmp/amber-phase1-tests.xcresult test
```

`IOSChatBackgroundSuspensionTests.swift` 内的实际类名是 `IOSChatBackgroundStaleSweepTests`，所以首批未选中这 8 个测试。随后用实际类名执行 `test`，重新编译被工作区中途新增的无关 WIP 阻塞：`IOSAgentToolEngine.swift:172–173` 的 public 默认参数引用 internal `IOSSharedKmpProviders.openAI/claude`（exit 65；日志 `/tmp/amber-phase1-stale-tests.log`）。该文件不是本轮改动，未修改或回滚。

对此前已成功构建的产物补跑，exit 0，**8 passed / 0 failed / 0 skipped**：

```bash
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:iosAppTests/IOSChatBackgroundStaleSweepTests \
  -resultBundlePath /tmp/amber-phase1-stale-replay-tests.xcresult test-without-building
```

合计 35/35；构建日志 `/tmp/amber-phase1-build.log`，测试日志 `/tmp/amber-phase1-tests.log`、`/tmp/amber-phase1-stale-replay-tests.log`。这证明本轮数据层及上述已构建产物的行为，不代表中途变化后的整个工作树已再次构建通过；该处是 Phase 1 初次交付时的阻塞记录；最新构建状态以下方 Phase 2 验证为准。


## Phase 1 review 修复与 Phase 2 实现记录（2026-09-26）

- 数据中心只在启动和 run 通知时查询 `listAllRuns`，缓存按对话归并的 latest map。store 变化仅重算过滤、标题和预览；消息内容按事件与 `ConversationSummary.updateAt`（完整 Instant）缓存。summary 未到达或消息读取失败不会提前消费事件，后续 store 变化可补齐提醒。
- 已补 `IOSSubAgentActivityLayoutTests` 的活动中心环境注入，并检索所有托管 ChatView 的测试。新截图测试同样注入临时 store/center，不使用用户数据或生产造数。
- `ChatTopBarView` 独立负责停靠位交互、提醒列表、到达鼓动/飞入、2.5 秒借用播报及触感/VoiceOver；`ChatTopBarTrailingDock` 负责三态圆形按钮、呼吸、上划 dismiss 和 contextMenu；`ChatArtifactShelfPanel` 只有玻璃空态，不实现 Phase 3 的索引与 Phase 4 收藏。
- 两侧视觉直径沿用 `toolbarButtonDiameter = 38`，命中框为 44pt；每侧留 56pt，岛可用宽度再除以最大鼓动系数 1.06。标题切换只在岛内裁剪滑动，不让过渡内容跨入侧键。Reduce Motion 使用淡入淡出并停用鼓动、飞入和呼吸。
- 岛按下时捕获 `ChatIslandPresentation`，纯函数按 `displayedState` 映射目标；工具按当前分支消息中的实际 toolCallID 校验，找不到则不操作。通过带请求 token 的 `ChatMessageAnchor` → `NativeTimelineMessageAnchorPolicy` → 已有 `ScrollPosition.scrollTo(id:)` 定位，完成后工具或图片块短暂高亮。没有锚点请求时在扫描消息前返回。
- 审批/问答卡实际位于输入区的固定 safe-area inset，不是 ScrollView 内容。点等待态会校验当时展示的 gate ID、收键盘并高亮现有卡片；不为这张固定卡片制造 y 坐标滚动。thinking/generating/waiting 则复用 `scrollToBottomTrigger` 和 `.button` intent 回底并恢复既有跟随机制。
- 切换提醒对话沿用现有选择/子会话路由和 run 门禁；失败保持提醒并显示既有错误通道。Phase 2 的 shelf count 为 0，后续 Phase 3 才填充实际产物索引。


### 首次验证（A 修复 + Phase 2）

- `xcodegen generate --spec iosApp/project.yml` 已将新文件加入生成工程。
- 最新 `build-for-testing` 构建通过（exit 0），日志 `/tmp/amber-topbar-last-build.log`。过程中曾遇到无关 `IOSLocalToolExecutor.swift` JavaScript 字符串转义错误，未修改该文件；工作区其他更新修正后构建通过。
- 为避开其他任务在默认模拟器上同时测试，最终使用 iPhone 17 Pro / iOS 26.5 / arm64，UDID `E26720E3-CBE3-4178-A469-1DFA9154395A`。
- 下表按各用例最后一次有效结果汇总；不是一次全绿的总回归。新增/本轮功能测试合计 22/22，通过的滚动 core、viewport、原有托管布局测试未重复扩跑。

| 测试类 | 最新结果 |
| --- | --- |
| ConversationActivityCenterTests | 10/10 |
| ChatTopBarDockTests | 3/3 |
| ChatIslandNavigationTests | 8/8 |
| ChatTopBarLayoutTests | 1/1 |
| IOSSubAgentActivityLayoutTests | 3/3 |
| NativeTimelineScrollCoreTests | 53/53 |
| ChatViewportPolicyTests | 4/4 |
| HomeDesignContractTests | 13/16，3 项旧约定失败 |
| ChatSwiftUIStreamReplayTests | 33/36，3 项流式性能门禁失败 |

构建与完整定点回归命令：

```bash
xcodebuild -quiet -disableAutomaticPackageResolution \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=E26720E3-CBE3-4178-A469-1DFA9154395A' \
  build-for-testing

xcodebuild -quiet -disableAutomaticPackageResolution \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=E26720E3-CBE3-4178-A469-1DFA9154395A' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:iosAppTests/ConversationActivityCenterTests \
  -only-testing:iosAppTests/IOSSubAgentActivityLayoutTests \
  -only-testing:iosAppTests/HomeDesignContractTests \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests \
  -only-testing:iosAppTests/ChatTopBarDockTests \
  -only-testing:iosAppTests/ChatIslandNavigationTests \
  -only-testing:iosAppTests/ChatTopBarLayoutTests test
```

Home 的中文断言需要 App 自身语言也为中文，单独 `-testLanguage zh-Hans` 没有覆盖这份模拟器里的 App 偏好。复查使用原始 xctestrun 的临时副本，给测试进程 `CommandLineArguments` 追加 `-app.amber.ios.language zh-Hans`，不修改用户持久化设置。可复用的无截图等待副本是 `/tmp/amber-topbar-verify.xctestrun`：

```bash
xcodebuild -quiet -xctestrun /tmp/amber-topbar-verify.xctestrun \
  -destination 'platform=iOS Simulator,id=E26720E3-CBE3-4178-A469-1DFA9154395A' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:iosAppTests/HomeDesignContractTests test-without-building
```

证据包：完整首轮 `/tmp/amber-topbar-final-tests.xcresult`；流式失败项复查 `/tmp/amber-topbar-recheck.xcresult`；中文 Home 复查 `/tmp/amber-topbar-ui-final.xcresult`；最终顶栏托管与系统截图 `/tmp/amber-topbar-accessibility-final.xcresult`（1/1）。首次截图辅助代码对 UIKit `NSNotFound` 的遍历已移除，375pt 用真实截图检查；没有把 SwiftUI 虚拟无障碍树当作 UIKit 子视图树断言。

遗留回归（未改对应 WIP）：

1. Home 的深度阅读候选现在使用任务标题“年度报告”，旧测试仍期待通用“深度阅读”；细长箭头字形的 80pt 包围盒不满足旧测试的宽高均大于 100 阈值；源码字符串断言仍查无参数 `generateConversationListPreview()`，现有 WIP 已使用 `generateConversationListPreview(state:)`。
2. `testKernelStreamStartsContinuousFollowOnFirstAssistantLine`、`testLongProseViewportFollowStaysLineSizedAtTwentyFourKB`、`testPerfGrowingTableStreamingKeepsDisplayLinkResponsive` 的采样/帧间隔门禁仍未通过。四个初始流式失败用例都使用 `messageAnchor == nil` 且没有工具 part，本轮定位、高亮分支不可达；现有滚动/文本入场 WIP 的因果未作隔离验证，不能据此断言根因。终态迟到布局用例复查已通过。

### 首次截图与实际交互

使用测试专用临时 conversation store、模拟 provider 配置和真实 ChatView/NativeChatTimelineView 注入状态。标准五态为模拟器系统截图（1206×2622）；375pt 为测试托管窗口截图（1125×2436）。产物架在页面挂载后打开，避免夹具的切会话回调把预设面板状态清掉。系统截图等待只在测试环境变量 `AMBER_TOPBAR_SYSTEM_CAPTURE=1` 时启用，普通测试无需宿主脚本。

- `/tmp/amber-topbar/topbar-shelf.png`
- `/tmp/amber-topbar/topbar-satellite-single.png`
- `/tmp/amber-topbar/topbar-satellite-multiple-expanded.png`
- `/tmp/amber-topbar/topbar-empty-hidden.png`
- `/tmp/amber-topbar/topbar-shelf-empty-panel.png`
- `/tmp/amber-topbar/topbar-narrow375.png`
- `/tmp/amber-topbar/topbar-shelf-tap.png`：真实点击停靠位后打开的面板。

独立视觉复核通过：五态齐全，列表标题/状态/预览可读，面板右上锚定，375pt 长标题与两侧按钮无交叠。XcodeBuildMCP 实际快照确认停靠位为 `产物架，0 项 | 0 项成果 | topbar-dock`，实际点击打开面板并点击“关闭产物架”成功。无障碍修饰已放在按钮本身，避免被 contextMenu 包装吞掉而读出 SF Symbol 名称。真机触感、VoiceOver 实际朗读及真实 provider 后台运行不由这些截图代替。


## Phase 2 review 修复与最新验证（2026-09-26）

- 停靠位的上划用高优先级 DragGesture 与 Button tap 互斥；shelf 使用无 preview 的普通 contextMenu，仅卫星保留消息预览。按钮保留默认无障碍动作，按压样式与返回键一致。删除单参与者 matchedGeometryEffect、列表行 contextMenu/历史 loader。
- 面板状态回到 ChatTopBarView 自有 @State，删除 ChatView 的 topBarInteraction 注入与 Observable 类。预览直接用 conversationId；产物架圆角使用 homeCardRadius，审批高亮使用 radiusXLarge，删除普通 VStack 上无效的 accessibilityFocused。
- 到达判定收敛为无副作用的 ChatTopBarArrivalState 值转换：按事件 key 识别新增，生成中不借岛或 VoiceOver 播报，离开仍等待对话后的同一提醒重现不触发效果，切对话清空。动画任务开始与退出复位；读取按下时的 presentation/公告 ID 后立即清空。
- 播报标题可截断，状态独立 fixedSize；列表行状态也保留固有宽度。空对话的 satellite 优先于 hidden。播报期间点岛打开公告中的对话。
- 普通对话和 transcript 路径统一调用 ConversationActivityCenter.didOpenConversation：打开失败不消费；completed/failed 成功进入即消费；awaitingUser 仅在可见期间隐藏，离开后重现。子对话 onDisappear 恢复提醒，离页后异步 loadMessages 不会重新标成可见。异步消息读取结束后也检查事件是否已被消费。

### 构建与测试结果

普通 build-for-testing 遇到无关 WIP 编译错误：ChatToolTimelineWidthOverflowTests.swift:576 构造调用传入不存在的 siteMemoryBaseline 参数。未修改该文件；仅在验证命令中排除该未要求执行的测试源文件。隔离后的最新 build-for-testing exit 0，日志 `/tmp/amber-topbar-review-ready-build.log`；原始失败日志 `/tmp/amber-topbar-review-final-build.log`。新文件已通过 xcodegen 加入生成工程。

```bash
xcodebuild -quiet -disableAutomaticPackageResolution \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=E26720E3-CBE3-4178-A469-1DFA9154395A' \
  EXCLUDED_SOURCE_FILE_NAMES=ChatToolTimelineWidthOverflowTests.swift build-for-testing

xcodebuild -quiet -xctestrun /tmp/amber-topbar-review-tests.xctestrun \
  -destination 'platform=iOS Simulator,id=E26720E3-CBE3-4178-A469-1DFA9154395A' \
  -collect-test-diagnostics never -parallel-testing-enabled NO \
  -only-testing:iosAppTests/ConversationActivityCenterTests \
  -only-testing:iosAppTests/ChatTopBarArrivalTests \
  -only-testing:iosAppTests/ChatTopBarDockTests \
  -only-testing:iosAppTests/ChatIslandNavigationTests \
  -only-testing:iosAppTests/ChatTopBarLayoutTests \
  -only-testing:iosAppTests/IOSSubAgentActivityLayoutTests \
  -only-testing:iosAppTests/HomeDesignContractTests \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests \
  -resultBundlePath /tmp/amber-topbar-review-results.xcresult test-without-building
```

临时 xctestrun 复制自这次构建产物，解析 __TESTROOT__ 为原始绝对路径；仅为测试进程设置 App 中文启动参数，未改用户持久化偏好。

| 测试类 | 本轮结果 |
| --- | --- |
| ConversationActivityCenterTests | 13/13 |
| ChatTopBarArrivalTests | 7/7 |
| ChatTopBarDockTests | 5/5 |
| ChatIslandNavigationTests | 8/8 |
| ChatTopBarLayoutTests | 1/1 |
| IOSSubAgentActivityLayoutTests | 3/3 |
| NativeTimelineScrollCoreTests | 53/53 |
| ChatViewportPolicyTests | 4/4 |
| HomeDesignContractTests | 13/16 |
| ChatSwiftUIStreamReplayTests | 35/36 |

合计 142/146。Home 仍为上节列出的 3 个旧约定失败；流式测试本轮仅 testLongProseViewportFollowStaysLineSizedAtTwentyFourKB 失败（高度发布 49pt 超过 40pt 阈值）。未修改相关 WIP，未将失败归因于未经隔离验证的代码。

额外实际手势验证使用测试内 AMBER_TOPBAR_GESTURE_PROBE=1，不增加生产注入：长按成功打开包含“新对话”的预览菜单；上划探针最终 1/1，断言 dismiss=1、tap=0，结果 `/tmp/amber-topbar-swipe-results.xcresult`。首次菜单+上划组合探针等待结束时 dismiss=0；拆开交互后通过。工具在 distance=0.4 时仍发出约 78pt 上划，复查 `/tmp/amber-topbar-short-swipe-results.xcresult` 也通过；这不证明更短距离的模拟器手势覆盖。

### 更新后的截图

均于本轮在 iPhone 17 Pro / iOS 26.5 上通过 UIHostingController 的真实 SwiftUI 渲染更新；PNG best-effort 写入，不以文件写入成功作为测试断言。shelf/satellite/empty 使用完整 ChatView 与临时 store；面板、99+、长公告使用独立生产 ChatTopBarView 的测试夹具，面板初始状态由组件 @State 设置，不再向 ChatView 注入测试控制器。

- `/tmp/amber-topbar/topbar-shelf.png`
- `/tmp/amber-topbar/topbar-satellite-single.png`
- `/tmp/amber-topbar/topbar-satellite-multiple.png`
- `/tmp/amber-topbar/topbar-satellite-multiple-expanded.png`
- `/tmp/amber-topbar/topbar-empty-satellite.png`
- `/tmp/amber-topbar/topbar-empty-hidden.png`
- `/tmp/amber-topbar/topbar-shelf-empty-panel.png`
- `/tmp/amber-topbar/topbar-narrow375-satellite-99plus.png`
- `/tmp/amber-topbar/topbar-narrow375-arrival-awaiting.png`
- `/tmp/amber-topbar/topbar-narrow375-arrival-failed.png`
- `/tmp/amber-topbar/topbar-narrow375-arrival-completed.png`

375pt 三种公告状态与 99+ 均可读且不与两侧重叠；列表与右上玻璃空态正常。真机触感、VoiceOver 实际朗读和真实 provider 后台运行未由本轮测试代替。未提交。

## Phase 3 — 实现记录（2026-09-26）

- `ConversationArtifactIndex.make(from:)` 仅接受 `ChatViewModel.messages`，与 NativeChatTimelineView 的 messagesProvider 同源，不另读历史或其他分支。产物带 messageID / user turn / toolCallID；文件按相对 workspace 路径分组，版本由旧到新。停靠位与标题按产物数计数，同路径多版本文件只计一项；同 URL 网页只计一项。
- 真实结构来源：`ai-core/src/commonMain/kotlin/app/amber/ai/ui/Message.kt` 的 `UIMessagePart.Tool`（toolCallId/toolName/input/output）和 Image.url；`MessageBubbleView` 现有 generate_image 分支只提取工具 output 里的 Image；`DocumentAccessStore` write 回执有 ok/path，edit 回执有 changed/replacements/diff_preview；`IOSSearchExecutor` scrape 回执为 status/url/title/content；`IOSLocalToolExecutor` 的 wm_open/extract 与 `IOSWebMountDesktopBackend` 的 page/current_url/visible_text 提供网页结果。没有新增链接分类，也不把用户上传图片算成产物。
- write 仅在成功工具 input 的完整 content 的 UTF-8 字节数与回执 size_bytes 一致时保留正文；edit 的成功回执没有完整正文，因此仅保留版本与来源，content 为 nil。workspace 会被其他对话和终端改写，不能从本对话旧快照猜测 edit 的新全文；diff_preview 也不能充当全文。不读取当前磁盘文件冒充历史版本。网页沿用工具结果 URL，包括有效 query，不二次更改生产结果。
- `ChatViewModel.artifactUpdateSignal` 只在 load/switch/branch/toolResult 更新，避免文字 chunk 触发全历史索引或覆盖尚未观察到的工具结果事件。支持的前台工具结果经 `ChatKernelProjection.publishAuthoritativeMessages` 或 image 完成分支发布 `.toolResultAppended`；后台内容通过 branch reload 更新。工具结果发布时拍下当前 run 是否运行，避免同一 run loop 的终态先被 UI 读到而漏掉飞入。首次、切换、分支重载和非前台结果不飞入。
- `ChatArtifactShelfPanel` 提供横向图片胶片条、文件与网页分组、文件多版本切换、数据可得时的行级差异、ShareLink；图片大图复用 `ChatGeneratedImagePreview`，历史文本复用只读 `WorkspacePreviewBlock`。`ChatArtifactShelfStrip` 负责定位后的细条和下拉恢复，ChatView 仅接索引信号、当前分支 anchor 和正文点击关闭。
- 定位通过 `ConversationArtifactIndex.anchor` 同时验证当前消息与其 toolCallID，再写入 Phase 2 已有 requestedMessageAnchor，沿原生 viewport/anchor 与工具高亮链执行。找不到原始 part 不定位，也不弹兜底窗口。
- 本轮同时修正后续视觉反馈：卫星角标显示提醒总数（两条为 2）；面板底色遮住正文；产物架采用自定义右对齐浮层，外沿对齐圆形停靠位；面板按内容收高，统一以 55% 为上限。Phase 4 收藏尚未实现，空态不提前承诺收藏操作。

### Phase 3 交互与视觉证据

- 产物架浮层在页面 ZStack 中承载，safeAreaBar 仅保留原有透明占位及 soft edge。原因是模拟器实际复现：超出 safeAreaBar 高度绘制的面板虽可见，但按钮无法命中；迁出后，点来源、展开、关闭均可达。时间线仍使用原生 safe-area / anchor 机制。
- 多版本内容使用系统横向 ScrollView 分页，初始锚在最新一版；不使用高优先级拖动拦截面板竖滑，也不让同时手势误触预览。模拟器实际验证 v2 → v1 不打开详情、卡片区域纵向滚动能露出网页列表、点第 2 轮后收成细条、下拉恢复、点正文关闭。结果 `/tmp/amber-phase3-probe5-results.xcresult`，1/1。
- 独立视觉复核确认：375pt 与 iPhone 17 Pro 面板右缘对齐 dock，不透出正文；空态约 176pt 高；旧版正文和第 2 轮来源一致；两条提醒角标为 2。正文在面板外侧可见是保留的页面背景。
- 图片分享支持既有 resolvedImageURL 和 data URL，data URL 使用既有异步图片解码后通过 ShareLink 分享 Image；没有另造图片查看器、文件历史存储或生产造数入口。

截图由 iPhone 17 Pro / iOS 26.2 的测试夹具生成；指定旧实例被其他任务占用，因此本轮使用 UDID `7A26BB05-833C-4B81-BDB6-F32345048AF4`。375pt 为同一模拟器的 375×812pt 托管窗口；普通面板使用生产组件和注入的产物索引，版本切换/细条/差异图为实际触摸后的系统截图。正常截图测试不依赖 PNG 写入成功，另保留 XCTest attachments。

- `/tmp/amber-topbar/phase3-panel-artifacts-iphone17pro.png`：有产物，默认最新版本。
- `/tmp/amber-topbar/phase3-panel-artifacts-375.png`：375pt 有产物面板。
- `/tmp/amber-topbar/phase3-version-previous.png`：实际横划后的第一版与第 2 轮来源。
- `/tmp/amber-topbar/phase3-version-diff.png`：与上一版的行级差异。
- `/tmp/amber-topbar/phase3-native-page-vertical.png`：卡片区域竖滑后的网页列表。
- `/tmp/amber-topbar/phase3-located-strip.png`：实际点击来源后的细条。
- `/tmp/amber-topbar/phase3-panel-empty-iphone17pro.png`
- `/tmp/amber-topbar/phase3-panel-empty-375.png`
- `/tmp/amber-topbar/topbar-satellite-multiple-expanded.png`、`topbar-shelf-empty-panel.png`：对应用户反馈的两张旧截图已重拍。

### Phase 3 最终验证

`xcodegen generate --spec iosApp/project.yml` 已把全部新 Swift 与测试文件加入生成工程。完整 `build-for-testing` 通过，未排除任何测试源文件；日志 `/tmp/amber-phase3-build-8.log`。前轮无关的 siteMemoryBaseline 编译错误已由其他工作区更新消除，本轮没有修改该调用或相关模型。

```bash
xcodebuild -quiet -disableAutomaticPackageResolution \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=7A26BB05-833C-4B81-BDB6-F32345048AF4' \
  build-for-testing

xcodebuild -quiet -xctestrun /tmp/amber-phase3-tests.xctestrun \
  -destination 'platform=iOS Simulator,id=7A26BB05-833C-4B81-BDB6-F32345048AF4' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:iosAppTests/ConversationArtifactIndexTests \
  -only-testing:iosAppTests/ChatArtifactShelfStateTests \
  -only-testing:iosAppTests/ChatArtifactTextDiffTests \
  -only-testing:iosAppTests/ChatArtifactShelfLayoutTests \
  -only-testing:iosAppTests/ConversationActivityCenterTests \
  -only-testing:iosAppTests/ChatTopBarArrivalTests \
  -only-testing:iosAppTests/ChatTopBarDockTests \
  -only-testing:iosAppTests/ChatIslandNavigationTests \
  -only-testing:iosAppTests/ChatTopBarLayoutTests \
  -only-testing:iosAppTests/IOSSubAgentActivityLayoutTests \
  -only-testing:iosAppTests/HomeDesignContractTests \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests \
  -resultBundlePath /tmp/amber-phase3-final-results.xcresult test-without-building
```

临时 xctestrun 仍仅设置测试进程的中文启动参数并解析原始 TESTROOT；测试使用本次最新构建产物。

| 测试类 | 最终结果 |
| --- | --- |
| ConversationArtifactIndexTests | 7/7 |
| ChatArtifactShelfStateTests | 2/2 |
| ChatArtifactTextDiffTests | 2/2 |
| ChatArtifactShelfLayoutTests | 1/1 |
| ConversationActivityCenterTests | 13/13 |
| ChatTopBarArrivalTests | 7/7 |
| ChatTopBarDockTests | 5/5 |
| ChatIslandNavigationTests | 8/8 |
| ChatTopBarLayoutTests | 1/1 |
| IOSSubAgentActivityLayoutTests | 3/3 |
| ChatSwiftUIStreamReplayTests | 36/36 |
| NativeTimelineScrollCoreTests | 53/53 |
| ChatViewportPolicyTests | 4/4 |
| HomeDesignContractTests | 13/16 |

新增测试 12/12、Phase 2 相关测试 37/37、三组滚动测试 93/93 全部通过。合计 155/158，只有 Home 的三个既有失败：年度报告/深度阅读标题断言、细长箭头包围盒 >100 阈值、旧无参数 generateConversationListPreview() 源码字符串断言。没有修改这些无关 WIP，也未把整组结果写成全绿。最后的实际交互探针另为 1/1；`git diff --check` 通过。

源消息定位由纯 anchor 映射、生产接线和既有滚动测试覆盖；截图/实际触摸使用测试产物数据，不代表真实 provider 或真机手感验证。未 commit。

## 顶栏视觉补修（2026-09-26，04:49 截图）

- 提醒角标继续显示总数，只有一条时隐藏；提醒列表和产物架均保留不透明主题底色，下面的文字及用户气泡不透进面板。
- 产物架增加与圆形停靠位中心对齐的圆润指向箭头，右缘仍与停靠位右缘齐平。空态在组件自身按内容测量，同时遵守 55% 高度上限；不再使用 280pt 最小高度。非空面板仍使用 55% 展示区。
- 提醒行本身直接显示 notice.title，没有拼接状态。截图中重复的“等待确认”来自测试对话的字面标题，夹具已改为“图片方案”“报告整理”等；不剥离用户真实对话标题中的文字。
- iPhone 17 Pro 的硬截断根因是 ChatView.conversationTitleForIsland 在进入 Text 前调用 compactIslandText(limit:14)，compactText 返回前 14 字而不带省略号。标题路径现保留全文，仅合并换行，由已有 lineLimit(1)/truncationMode(.tail) 与宽度约束处理。未保留额外自定义 Layout；ChatActivityIslandView 本轮内容未变。
- 已覆盖原文件名：topbar-satellite-multiple-expanded.png、topbar-shelf-empty-panel.png、topbar-satellite-single.png、topbar-narrow375.png，以及普通五态、375pt 播报与 Phase 3 面板/版本/差异/细条截图。

验证：完整 build-for-testing 通过，日志 `/tmp/amber-topbar-visual-build-verified.log`。首轮 `/tmp/amber-topbar-visual-results.xcresult` 为 99/100，仅空态独立 sizeThatFits 仍占满上限；将内容贴合放回面板自身后，两个布局测试在 `/tmp/amber-topbar-visual-layout-final.xcresult` 复测 2/2 通过，含模拟器实际横划切版、点来源收条、下拉恢复和差异截图。最终按各测试类最新结果为 100/100：三组滚动 93/93、ChatTopBarDockTests 5/5、两个布局类 2/2。已通过且未受最后一行空态尺寸修改影响的滚动类未重复运行。

```bash
xcodebuild -quiet -disableAutomaticPackageResolution \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=7A26BB05-833C-4B81-BDB6-F32345048AF4' build-for-testing

xcodebuild -quiet -xctestrun /tmp/amber-topbar-visual-tests.xctestrun \
  -destination 'platform=iOS Simulator,id=7A26BB05-833C-4B81-BDB6-F32345048AF4' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:iosAppTests/ChatTopBarLayoutTests \
  -only-testing:iosAppTests/ChatArtifactShelfLayoutTests \
  -only-testing:iosAppTests/ChatTopBarDockTests \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests test-without-building
```

最后两类布局用现有 `/tmp/amber-phase3-probe.xctestrun` 执行同样的 test-without-building；仅该副本开启测试内交互探针。独立截图复核确认两种宽度都显示省略号、无侧键重叠，箭头与 dock 中心对齐，空态内容贴合。`git diff --check` 通过；未 commit、未修改无关 WIP。


## 合并请求续接验收（2026-09-26，05:05）

此次合并消息作为当前唯一清单处理，未重复实现已经完成的 Phase 2、视觉和 Phase 3 UI。构建严格按要求传入 `EXCLUDED_SOURCE_FILE_NAMES=ChatToolTimelineWidthOverflowTests.swift`；未编辑该既有 WIP 文件。构建日志 `/tmp/amber-resume-build.log`，exit 0。

1. **Phase 2 与真实短上划**：重新执行相关 37 项、三组滚动 93 项，均通过；Home 13/16，仍只有此前三项既有断言失败。结果 `/tmp/amber-resume-phase2.xcresult`，143/146。短上划独立结果 `/tmp/amber-resume-short-swipe.xcresult`，1/1：当前 accessibility tree 中按钮 frame 为 (340,80,44,44)，通过 Simulator HID 从 (362,118) 滑至 (362,86)，32pt/200ms，起止点都在按钮命中区内；测试断言 dismiss=1、tap=0。该证据替代此前仅验证约 78pt 手势的限制。
2. **视觉及高亮**：总数角标、单条无角标、不透明底色、右缘与箭头对齐、空态收高与 55% 上限、标题/状态分离、完整标题交给 Text 省略均已保留。`ChatIslandToolAnchorHighlightModifier` 只在 isHighlighted 分支创建 stroke/shadow，环境值没有进入行 Equatable 或 digest。普通截图本轮已覆盖；此前已经验证且未改 UI 的版本切换/细条系统截图继续有效。
3. **Phase 3 补修**：独立核对发现 edit 全文重建不可靠：AppShell 向所有对话 run 注入同一 IOSWorkspaceStore/IOSLocalToolExecutor；终端也能通过 IOSAmberShell 重定向和 amberShellWriteText 写同路径。DocumentAccessStore 的 fileEdit 从执行时磁盘读取正文，回执无基线 hash 或完整新正文。因此删除 `editedVersion` 推断函数，edit 只列版本；完整 write 快照仍可对比与分享。仅调整已有版本测试，没有新增测试矩阵。`/tmp/amber-resume-phase3.xcresult` 12/12，通过构建与四个 Phase 3 测试类。

两部分标准回归合计 155/158，另有短上划探针 1/1。无关 Home 三项仍为“年度报告/深度阅读”标题、细箭头包围盒阈值、旧无参数 generateConversationListPreview() 字符串断言。没有修改它们。真机手感仍未验证，未 commit。

### 相关改动文件分组（包含前轮已完成部分）

- Phase 2 review：`ConversationActivityCenter.swift`、`SubAgentConversationView.swift`、`ChatTopBarArrivalState.swift`、`ChatTopBarView.swift`、`ChatTopBarTrailingDock.swift`、`ChatView.swift`；对应 `ConversationActivityCenterTests.swift`、`ChatTopBarArrivalTests.swift`、`ChatTopBarDockTests.swift`、`ChatTopBarLayoutTests.swift`、`IOSSubAgentActivityLayoutTests.swift`。
- 岛定位与高亮：`ChatIslandNavigation.swift`、`ChatMessageProjection.swift`、`ChatCollectionMessageList.swift`、`ChatToolTimelineView.swift`、`MessageBubbleView.swift`，以及 `ChatIslandNavigationTests.swift`。仅本任务相关 hunk，不包含这些文件内原有其他 WIP。
- 视觉：上述顶栏文件，加 `ChatActivityIslandView.swift`、`ChatArtifactShelfPanel.swift`；截图夹具在 `ChatTopBarLayoutTests.swift`。最后的省略号修复只改 ChatView 标题入口，没有保留额外 Layout。
- Phase 3：`ConversationArtifactIndex.swift`、`ChatArtifactShelfState.swift`、`ChatArtifactTextDiff.swift`、`ChatArtifactShelfStrip.swift`、`ChatArtifactShelfPanel.swift`、`ChatTopBarView.swift`、`ChatTopBarTrailingDock.swift`、`ChatView.swift`、`ChatViewModel.swift`；`MessageBubbleView.swift` 和 `PlaceholderViews.swift` 开放既有预览组件复用。对应 `ConversationArtifactIndexTests.swift`、`ChatArtifactShelfStateTests.swift`、`ChatArtifactTextDiffTests.swift`、`ChatArtifactShelfLayoutTests.swift`。
- 记录：本计划文件。新 Swift 文件已加入生成工程；本轮新增生产修改仅为索引去掉 edit 全文推断。

复用现有构建产物的测试配置仅设置中文启动参数。Phase 2：

```bash
xcodebuild -quiet -xctestrun /tmp/amber-resume-tests.xctestrun \
  -destination 'platform=iOS Simulator,id=7A26BB05-833C-4B81-BDB6-F32345048AF4' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:iosAppTests/ConversationActivityCenterTests \
  -only-testing:iosAppTests/ChatTopBarArrivalTests \
  -only-testing:iosAppTests/ChatTopBarDockTests \
  -only-testing:iosAppTests/ChatIslandNavigationTests \
  -only-testing:iosAppTests/ChatTopBarLayoutTests \
  -only-testing:iosAppTests/IOSSubAgentActivityLayoutTests \
  -only-testing:iosAppTests/HomeDesignContractTests \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests test-without-building
```

Phase 3 重新构建并测试的命令：

```bash
xcodebuild -quiet -disableAutomaticPackageResolution \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=7A26BB05-833C-4B81-BDB6-F32345048AF4' \
  EXCLUDED_SOURCE_FILE_NAMES=ChatToolTimelineWidthOverflowTests.swift \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:iosAppTests/ConversationArtifactIndexTests \
  -only-testing:iosAppTests/ChatArtifactShelfStateTests \
  -only-testing:iosAppTests/ChatArtifactTextDiffTests \
  -only-testing:iosAppTests/ChatArtifactShelfLayoutTests test
```


## Phase 3 独立 review 修复验收（2026-09-26，06:10）

此节为当前结论；前文各时间点的测试结果仅为历史记录。

- 网页只索引 `scrape_web` / `wm_open` / `wm_extract`，按 URL 合并，保留最新来源；文件按路径计一件产物。网页刷新与文件新增版本不重复飞入。工具去重键改为 messageID + toolCallID，避免跨消息复用 call_0 被吞掉；input JSON 只在产物分支解析。
- write 正文必须通过 `utf8.count == size_bytes`。edit 延续前轮只记录版本、不推算正文的决定：字节数相同仍不能证明跨对话/终端写入后的基线相同。没有正文的版本不能打开预览、对比或分享。
- 卫星长按增加“产物架”；dock 状态变化不关闭 shelf / shelfCollapsed 或当前预览。模拟器实际验证了预览打开期间提醒到达、关闭预览后面板仍在，以及从卫星菜单重新打开产物架。
- 面板测量内容高度并以 55% 为上限，溢出显示滚动指示与底部渐隐。外层固定高度仅为透明承载空间；面板自身背景贴合内容，空态与单网页的实际几何测试均通过。胶片条仅放图片，网页仅在列表；版本叠层放在背景、两侧缩进并下移 6pt。删除随网页胶片条存在的固定 9pt 字体，图片圆角为外卡圆角减内边距。
- diff 按位置输出、去除 CR、空旧版不产生空删除行，每侧分别限额；仅当前选择版本计算 diff。
- 工具/图片原生 anchor ID 同样带 messageID，定位分类与高亮限于来源消息；高亮环境值仍不进入行 Equatable 或 digest。保留原生 center 对齐；实测首条工具会因顶部边界钳制被细条盖住，因此把细条的实测高度加入既有 safeAreaBar 占位，未写 contentOffset 或引入 magic-height 滚动。真实 NativeChatTimelineView 截图确认首条工具已位于细条下方。

### 当前构建与测试

构建通过：`/tmp/amber-p3-review-verified-build.log`。按用户要求排除既有 WIP 编译错误所在 `ChatToolTimelineWidthOverflowTests.swift`，没有修改该文件。新测试已通过 xcodegen 加入生成工程。

```bash
xcodegen generate --spec iosApp/project.yml
xcodebuild -quiet -disableAutomaticPackageResolution \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=7A26BB05-833C-4B81-BDB6-F32345048AF4' \
  EXCLUDED_SOURCE_FILE_NAMES=ChatToolTimelineWidthOverflowTests.swift build-for-testing

xcodebuild -quiet -xctestrun /tmp/amber-p3-review-tests.xctestrun \
  -destination 'platform=iOS Simulator,id=7A26BB05-833C-4B81-BDB6-F32345048AF4' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:iosAppTests/ConversationArtifactIndexTests \
  -only-testing:iosAppTests/ChatArtifactShelfStateTests \
  -only-testing:iosAppTests/ChatArtifactTextDiffTests \
  -only-testing:iosAppTests/ChatArtifactShelfLayoutTests \
  -only-testing:iosAppTests/ChatArtifactAnchorLayoutTests \
  -only-testing:iosAppTests/ChatIslandNavigationTests \
  -only-testing:iosAppTests/ChatMessageProjectionTests \
  -only-testing:iosAppTests/ChatRowContentHashCacheTests \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests \
  -resultBundlePath /tmp/amber-p3-review-final-results.xcresult test-without-building
```

| 测试类 | 当前结果 |
| --- | --- |
| ConversationArtifactIndexTests | 10/10 |
| ChatArtifactShelfStateTests | 3/3 |
| ChatArtifactTextDiffTests | 5/5 |
| ChatArtifactShelfLayoutTests | 1/1 |
| ChatArtifactAnchorLayoutTests | 1/1 |
| ChatIslandNavigationTests | 8/8 |
| ChatMessageProjectionTests | 91/91 |
| ChatRowContentHashCacheTests | 12/12 |
| NativeTimelineScrollCoreTests | 55/55 |
| ChatViewportPolicyTests | 4/4 |
| ChatSwiftUIStreamReplayTests | 35/36 |

合计 225/226。唯一失败 `testPerfGrowingTableStreamingKeepsDisplayLinkResponsive` 的帧间隔 p95 为 44.67ms（阈值 40ms）；单独复测仍失败，p95 为 98.53ms，结果 `/tmp/amber-p3-review-scroll-recheck.xcresult`。保留此性能门禁失败，不修改无关滚动实现或阈值；本轮证据不足以判定其根因。实际交互探针 `/tmp/amber-p3-review-ui-final.xcresult` 与卫星菜单探针 `/tmp/amber-p3-review-menu.xcresult` 各 1/1。

### 同构建截图

`/tmp/amber-topbar/phase3-*.png` 全部重新生成，无旧构建截图沿用；另增深色面板。当前 `iosApp.debug.dylib` 构建时间 05:57:55，SHA-256 `641b298e4fd5a85419da10b5f04a7971addae5e1737ae6938728f05386770204`。截图时间 05:59–06:06，列表与用途见 `/tmp/amber-topbar/README.md`。

- 有产物：`phase3-panel-artifacts-iphone17pro.png`、`phase3-panel-artifacts-375.png`、`phase3-panel-artifacts-dark.png`。
- 切版/差异：`phase3-version-previous.png`、`phase3-version-diff.png`。
- 网页滚动可达：`phase3-native-page-vertical.png`。
- 收条/真实时间线定位：`phase3-located-strip.png`、`phase3-panel-located-strip-after-interaction.png`、`phase3-native-anchor.png`。
- 空态：`phase3-panel-empty-iphone17pro.png`、`phase3-panel-empty-375.png`。

模拟器为 iPhone 17 Pro / iOS 26.2；375pt 为同设备托管窄窗口。数据来自测试夹具，没有增加生产造数逻辑；截图写文件成功与否不作为测试通过条件。尚无真机手感及真实 provider 验收。未 commit，保留无关 WIP。


## Phase 3 续接核验（2026-09-26）

面板布局测试的修复已在当前构建中：`ChatArtifactShelfLayoutTests.assertPanelSizes` 将 `onGeometryChange` 挂在面板自身，读取实际 CGSize；不再使用包含宿主安全区的 sizeThatFits 高度。测试分别检查空态、单网页和完整产物在两种宽度下的实际高度。

| Review 项 | 状态 | 处理 |
| --- | --- | --- |
| 1 网页膨胀 | 完成 | 仅收 scrape_web / wm_open / wm_extract，URL 去重、最新来源 |
| 2 历史正文可靠性 | 调整方案 | write 校验 UTF-8 字节数；edit 不重建，字节数相等不足以证明基线可靠 |
| 3 卫星访问产物架 | 完成 | 长按菜单入口；提醒到达保留面板、细条及预览 |
| 4 面板高度与溢出 | 完成 | 测量内容、最大55%；指示器与底部渐隐；测试排除安全区 |
| 5 版本叠层 | 完成 | 背景同圆角卡片，两侧缩进、向下6pt |
| 6 网页重复展示 | 完成 | 胶片条仅图片，网页列表；真实回执没有可复用网页缩略图 |
| 7 input JSON 开销 | 完成 | 仅产物分支解析 |
| 8 diff 顺序与限额 | 完成 | 按位置、每侧限额、去CR、空版本无空删除行，已有5项测试 |
| 9 非当前版本 diff | 完成 | 仅选中版本计算 |
| 10 无正文预览 | 完成 | 静态说明，不提供预览/分享/差异按钮 |
| 11 toolCallID 重复 | 完成 | 索引及定位使用 messageID + toolCallID |
| 12 字体与圆角 | 调整方案 | 删除网页胶片条及其中9pt文字；保留文字使用动态字体；图片圆角减内边距 |
| 产品：计数 | 完成 | 产物数，多版本文件计1 |
| 产品：定位遮挡 | 完成 | 原生center anchor + 细条实测高度接入现有safeAreaBar，无像素滚动 |

没有跳过的 review 项。此次续接没有再次修改生产或测试源码；确认二进制 SHA-256 与上一节一致，所有 Swift 源码均早于该构建。此前重拍的全部15张 phase3截图（包括深色及实际交互图）均对应当前代码，不沿用不同构建的差异截图。完整回归还会再次生成普通面板、深色、空态及原生定位图。

续接完整回归结果：`/tmp/amber-p3-review-resume-all.xcresult`，266/271。Phase 3五类20/20（索引10、状态3、diff5、布局1、真实anchor布局1），Phase 2功能37/37（活动中心13、arrival7、dock5、island8、topbar布局1、subagent布局3），消息投影与缓存103/103；三组滚动为 NativeTimelineScrollCore55/55、Viewport4/4、StreamReplay34/36；Home13/16。

失败项：Home三个既有断言（年度报告/深度阅读、箭头高度80<100、预览源码契约）；流式表格帧间隔p95为47.15ms>40ms；长文高度发布出现49pt>40pt。后者单独复测结果见下文。未改动这些无关实现或阈值。

命令沿用上一节 xctestrun / destination / 串行参数和全部测试类，并追加 `ConversationActivityCenterTests`、`ChatTopBarArrivalTests`、`ChatTopBarDockTests`、`ChatTopBarLayoutTests`、`IOSSubAgentActivityLayoutTests`、`HomeDesignContractTests`，resultBundlePath 改为 `/tmp/amber-p3-review-resume-all.xcresult`。日志 `/tmp/amber-p3-review-resume-all.log`。本轮布局测试再次覆盖了普通面板、375pt、深色、空态与真实anchor截图；交互截图已于05:59–06:04由同一当前构建拍摄，无需重复造数或修改源码。

长文单独复测 `/tmp/amber-p3-review-resume-prose.xcresult` 仍失败（0/1），此次是可见文本发布次数38<45；首轮为高度49pt>40pt。保留两次具体结果，不把失败归因于本次产物架改动或宣称已排除因果。没有继续重复跑测或修改无关滚动实现。`git diff --check` 通过，未 commit。


## Phase 4 验证（2026-09-26，续接）

前一执行者在 Phase 4 中途因认证错误中断。续接时核对实际代码：store、持久化、消息与代码块的"收进产物架"、"基于它继续"与"采用"均已接线，但新文件**从未加入生成工程、也从未编译**（首次构建失败：`ChatArtifactPinAction` 的 EnvironmentKey 默认值不满足 Sendable）。多选的分享要先弹中间 sheet 再点一次 ShareLink；图片读取和临时文件写入都在主线程同步进行；导出报告没有 URL 时会退到一个只报错的按钮。

### 本轮补完

- **编译**：`ChatArtifactPinAction` 改为 `@MainActor` 闭包类型；代码块收藏同时带上语言，片段的 `codeLanguage` 实际落盘（代码块入口的最终形式见下方 review 修复第 2 项）。
- **多选导出**（新增 `ChatArtifactShelfExport.swift`）：选择变化后，`.task(id:)` 在 `Task.detached` 中读图片、写临时文件和报告。每批导出使用独立目录，替换或面板消失时删除；如果选择已经变化，就丢弃这批过期结果。底栏直接放三项：存到相册（沿用 `ChatGeneratedImagePhotoWriter` 已有的 addOnly 权限路径；成功时有触感和"已存入相册 N 张"，部分失败会注明已保存几张）、`ShareLink(items:)` 多项分享、导出成果报告（`ShareLink` 临时 .md）。状态行显示"已选 N 项 / 正在准备… / N 个文件无正文，仅写入报告"。选择以当前索引为准，分支切换后消失的项不参与导出。多选时点网页行改为切换选择。
- **成果报告**（纯函数 `ChatArtifactActions.reportMarkdown(title:…)`）：标题为"{对话} · 成果报告"。文件取采用版本，未采用时取最新版本，并标注"已采用版本 i/n"或"最新版本 i/n"、来源轮次，按扩展名加代码围栏语言。收藏片段中，文本转为引用块，代码转为带语言的围栏（遇到反引号会自动加长围栏）。图片只嵌入 http(s) 地址；本地文件和 data URL 只写说明，不把 base64 塞进报告。
- **采用**：版本卡打开时先显示已采用的版本，初始横向锚点按 i/(n-1) 对齐分页，其余版本变淡。
- **细节**：复制片段有触感；"收进产物架"成功有触感；收藏原消息不在当前分支时，定位会给出错误说明，不再静默失败。空态文案补充"长按消息可收进产物架"。

### 文件

- 新增生产文件：`ChatArtifactActions.swift`、`ChatArtifactComposerSupport.swift`、`ChatArtifactPinAction.swift`、`ChatArtifactPinning.swift`、`ChatArtifactShelfExport.swift`、`ChatGeneratedImagePhotoWriter.swift`（从 MessageBubbleView 原样迁出的相册写入路径）、`IOSConversationArtifactStore.swift`。
- 修改：`ChatArtifactShelfPanel.swift`、`ChatTopBarView.swift`、`ChatView.swift`（只做接线）、`MessageBubbleView.swift`、`MarkdownView.swift`（代码块 headerAccessory）、`IOSConversationStore.swift`（artifactStore 持有、读取错误上报、删除提交后与备份恢复后清理）、`IOSSyncBackup.swift`（备份排除 artifact-shelf.json）、vendor `BlockView.swift`（可选 headerAccessory 提供者，默认 nil）；vendor `CodeBlockView.swift` 已恢复原样。
- 测试：`ChatArtifactActionsTests.swift`、`IOSConversationArtifactStoreTests.swift`、`ChatArtifactIntegrationTests.swift`、`ChatArtifactShelfLayoutTests.swift`（新增 Phase 4 用例和夹具参数）。

### 命令

```bash
xcodegen generate --spec iosApp/project.yml
xcodebuild -quiet -disableAutomaticPackageResolution \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=7A26BB05-833C-4B81-BDB6-F32345048AF4' \
  EXCLUDED_SOURCE_FILE_NAMES=ChatToolTimelineWidthOverflowTests.swift build-for-testing

xcodebuild -quiet -xctestrun /tmp/amber-phase4-tests.xctestrun \
  -destination 'platform=iOS Simulator,id=7A26BB05-833C-4B81-BDB6-F32345048AF4' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:iosAppTests/ChatArtifactActionsTests \
  -only-testing:iosAppTests/IOSConversationArtifactStoreTests \
  -only-testing:iosAppTests/ChatArtifactIntegrationTests \
  -only-testing:iosAppTests/ChatArtifactShelfLayoutTests \
  -only-testing:iosAppTests/ConversationArtifactIndexTests \
  -only-testing:iosAppTests/ChatArtifactShelfStateTests \
  -only-testing:iosAppTests/ChatArtifactTextDiffTests \
  -only-testing:iosAppTests/ChatArtifactAnchorLayoutTests \
  -only-testing:iosAppTests/ConversationActivityCenterTests \
  -only-testing:iosAppTests/ChatTopBarArrivalTests \
  -only-testing:iosAppTests/ChatTopBarDockTests \
  -only-testing:iosAppTests/ChatIslandNavigationTests \
  -only-testing:iosAppTests/ChatTopBarLayoutTests \
  -only-testing:iosAppTests/IOSSubAgentActivityLayoutTests \
  -only-testing:iosAppTests/ChatMessageProjectionTests \
  -only-testing:iosAppTests/ChatRowContentHashCacheTests \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests \
  -only-testing:iosAppTests/HomeDesignContractTests \
  -resultBundlePath /tmp/amber-phase4-final.xcresult test-without-building
```

构建日志 `/tmp/amber-phase4-build-final.log`，exit 0；仍按先前做法排除既有 WIP 编译错误所在的 `ChatToolTimelineWidthOverflowTests.swift`，未修改该文件。xctestrun 复制自本次构建，解析 `__TESTROOT__`，只追加中文启动参数。

| 测试类 | 结果 |
| --- | --- |
| ChatArtifactActionsTests | 6/6（继续映射、报告采用/最新/轮次、选择过滤、图片与代码围栏、后台导出命名与内容、文件名去重） |
| IOSConversationArtifactStoreTests | 4/4（跨实例读写、删除只清本对话、损坏文件阻止写入且不覆盖、同消息多代码块分存及语言） |
| ChatArtifactIntegrationTests | 2/2（删除失败时保留、提交后清理；真实 ChatView 中保留草稿追加引用块、data URL 图片进入待发送图片） |
| ChatArtifactShelfLayoutTests | 2/2（含 Phase 4：333/17 Pro 宽度多选态面板不超宽、不超 55%） |
| ConversationArtifactIndexTests / ShelfState / TextDiff / AnchorLayout | 10/10、3/3、5/5、1/1 |
| ActivityCenter / Arrival / Dock / Island / TopBarLayout / SubAgentLayout | 13/13、7/7、5/5、8/8、1/1、3/3 |
| ChatMessageProjectionTests / ChatRowContentHashCacheTests | 91/91、12/12 |
| NativeTimelineScrollCoreTests / ChatViewportPolicyTests | 55/55、4/4 |
| ChatSwiftUIStreamReplayTests | 34/36 |
| HomeDesignContractTests | 13/16 |

合计 279/284。5 项失败都是先前记录过的既有问题：Home 的三项断言（年度报告/深度阅读、箭头高度 80<100、预览源码契约）；流式长文高度发布 48pt>40pt；表格帧间隔 p95 46.27ms>40ms。未修改相关实现或阈值。

### 截图（iPhone 17 Pro / iOS 26.5 模拟器，测试夹具；375pt 为 375×812 托管窗口）

- `/tmp/amber-topbar/phase4-panel-snippets-iphone17pro.png`：片段分组（前四行、第 N 轮 ↗、复制、取消收藏）与已采用的第 1 版。
- `/tmp/amber-topbar/phase4-panel-snippets-375.png`、`phase4-panel-snippets-dark.png`
- `/tmp/amber-topbar/phase4-version-unadopted.png`：未采用时显示最新版和"采用"按钮。
- `/tmp/amber-topbar/phase4-multiselect-iphone17pro.png`、`phase4-multiselect-375.png`：多选勾选、状态行、三项底栏在 375pt 下等分、不截断。
- `/tmp/amber-topbar/phase4-composer-continue.png`：真实 ChatView 中，"基于它继续"后原草稿保留，引用块追加在其后，待发送图片出现（"请先选择模型"是夹具未配置模型的提示）。

多选截图按 ChatTopBarView 的面板位置直接渲染面板，多选状态通过 internal `@State` 注入；生产代码没有造数入口。首张 composer 截图在输入框增高动画进行中拍摄，已把等待时间延长到 2s 后重拍。

### 遗留

- "变淡的未采用版本"需要横划到相邻页才能看到，没有做模拟器横划探针截图；透明度逻辑与 Phase 3 横划分页复用同一路径。
- 系统分享面板、相册权限弹窗、contextMenu 长按手感和 VoiceOver 朗读都未做真机验证；ShareLink 与相册写入只在代码路径和单元层面覆盖。
- 片段按收藏顺序展示；原消息不在当前分支的片段隐藏（仍保留在 store），切回原分支后重新出现。
- **产品决定：产物架收藏（片段、采用标记）不进入备份**；恢复备份时，被覆盖会话在本机的收藏会被清掉。
- "会话在图片准备期间被切换"这条路径只能靠竞态触发，没有自动化测试；该路径会抛出"已切换对话，未附加图片。"并经由产物架错误通道提示。
- 未 commit；未修改无关 WIP。


### Phase 4 独立 review 修复（2026-09-26）

| # | 项 | 状态 | 处理 |
| --- | --- | --- | --- |
| 1 | 收藏后备份恢复失败 | 完成 | `conversationMetadataEntries` 排除 `artifact-shelf.json`；`importConversationDocuments` 导入成功后清掉被覆盖会话的收藏；`IOSP1BackupTests.testBackupRestoreSucceedsAfterPinningSnippet` |
| 2 | 代码块嵌套 contextMenu 吞掉消息菜单 | 完成 | vendor `CodeBlockView.swift` 恢复原样；代码块头部在"复制"旁放图钉按钮（`ChatCodeBlockHeaderAccessory`）：稳定渲染路径 `AmberMarkdownView` 直接传 headerAccessory，流式 block 渲染路径由 vendor `BlockView` 的可选 `swiftStreamingMarkdownCodeBlockHeaderAccessory`（默认 nil）传入同一插槽。没有收藏动作的场景 headerAccessory 仍为 nil |
| 3 | 准备期间沿用旧导出 | 完成 | `ChatArtifactShelfExportState.begin()` 先清空 export，两按钮在准备完成前禁用 |
| 4 | 任意索引刷新都重导并删除分享中的目录 | 完成 | task 只随所选 ID 与所选文件的导出版本 ID 变化；替换结果时不删除目录，面板消失时统一删除 |
| 5 | 单项失败中断整次导出；重复弹窗；失败目录遗留 | 完成 | 单项失败跳过并计入 `skippedCount`（状态行"N 项无法读取，已跳过"）；主文件名按 UTF-8 截到 180 字节以内；整体失败时删除该批目录；同一条失败信息只弹一次 |
| 6 | 退出多选后列表仍偏短 | 完成 | 纯函数 `ChatArtifactShelfPanel.scrollHeight` 只在多选时计入底栏高度 |
| 7 | 失效的采用 ID 让所有版本变淡 | 完成 | `ChatArtifactActions.adoptedVersionID` 只承认仍在 versions 中的 ID；面板、导出和报告统一使用 |
| 8 | 静默返回 | 完成 | 图片准备期间切换会话时抛出"已切换对话，未附加图片。"；图片达到上限时面板照常关闭，由 `addPendingImage` 已有的输入区错误提示说明；`updateArtifactShelf` 的无会话 guard 实际不可达（只有已有消息的会话才能打开面板或收藏），保留不动 |
| 9 | 分支过滤 | 完成 | `ChatArtifactPinning.visibleSnippets` 在 ChatView 接线处过滤，角标和面板都用过滤后的列表 |
| 10 | 切换会话时关闭面板、清空选择 | 已满足 | ChatTopBarView 在 conversationID 变化时已设 `panel = nil`；选择状态属于面板视图，随面板一并销毁，未改代码 |
| 11 | 收藏文件损坏 | 完成（调整方案） | 损坏文件改名为 `artifact-shelf-corrupt-<ts>.bak` 另存（不用 .json，避免再次被备份或会话扫描当作会话），从空状态开始且可写；只在启动时提示一次 |
| 12 | 报告 Markdown | 完成 | 围栏长度取行首最多 3 个空格内最长反引号串 +1；标题和 alt 文本折叠空白、转义 `]`；URL 写成 `(<url>)`；拆引用前统一 \r\n 与 \r |
| 13 | UI | 完成 | 片段的定位、复制、取消收藏点击区 ≥44pt；多选时隐藏复制、取消收藏、采用、分享；多选时整张卡片点按切换选择（辅助功能入口仍是勾选圈）；图片勾选圈移到左上；底部渐隐 36pt；底栏文字与状态行允许两行 |
| 14 | 冗余的 defaultScrollAnchor / scrollPosition | 调整方案 | 实测去掉 defaultScrollAnchor 后，未采用卡片显示第 1 版正文而计数为 2/2，可见两者并不重复：`scrollPosition(id:)` 负责跟踪当前页，`defaultScrollAnchor(i/(n-1))` 负责首帧定位。两者都保留并加了注释 |

新增或调整的测试：备份排除与恢复（IOSP1BackupTests）；准备期间清空导出、同一失败只弹一次、目录在面板关闭时才删除（`testExportStateClearsPreviousResultWhilePreparingAndAlertsOnce`）；退出多选后列表高度（`testListHeightIgnoresFooterAfterLeavingSelectMode`）；失效采用 ID（`testStaleAdoptedVersionIsIgnored`）；代码块不再挂 contextMenu、收藏走 headerAccessory（源码契约测试，长按手感无法自动化）；单项失败不中断导出与长文件名（`testExporterSkipsFailingItemsAndCapsLongNames`）；分支过滤（`testSnippetsOutsideCurrentBranchAreHiddenButKept`）；报告转义、换行统一与围栏长度；损坏文件另存后可写；图片达到上限时不抛错、输入区给出提示。

构建 `/tmp/amber-phase4r-build-final.log`，exit 0（仍排除 `ChatToolTimelineWidthOverflowTests.swift`）。测试使用同一 `/tmp/amber-phase4-tests.xctestrun`，在上一节命令基础上追加 `-only-testing:iosAppTests/IOSP1BackupTests`，结果 `/tmp/amber-phase4r-final.xcresult`：**297/300**。

| 测试类 | 结果 |
| --- | --- |
| ChatArtifactActionsTests | 12/12 |
| IOSConversationArtifactStoreTests | 4/4 |
| ChatArtifactIntegrationTests | 3/3 |
| ChatArtifactShelfLayoutTests | 2/2 |
| IOSP1BackupTests | 9/9 |
| Phase 3（Index 10、State 3、TextDiff 5、AnchorLayout 1） | 19/19 |
| Phase 2（ActivityCenter 13、Arrival 7、Dock 5、Island 8、TopBarLayout 1、SubAgentLayout 3） | 37/37 |
| ChatMessageProjectionTests / ChatRowContentHashCacheTests | 91/91、12/12 |
| ChatSwiftUIStreamReplayTests / NativeTimelineScrollCoreTests / ChatViewportPolicyTests | 36/36、55/55、4/4 |
| HomeDesignContractTests | 13/16（三项既有失败） |

本轮两项流式门禁均通过；上一轮失败的长文与表格门禁属于时序抖动，没有改动相关代码。

重拍截图（同一构建）：`phase4-panel-snippets-iphone17pro.png`、`phase4-panel-snippets-375.png`、`phase4-panel-snippets-dark.png`、`phase4-version-unadopted.png`（最新版正文与 2/2 一致）、`phase4-multiselect-iphone17pro.png`、`phase4-multiselect-375.png`（勾选圈在左上，多选时隐藏逐项分享与采用）、`phase4-composer-continue.png`（新增代码块消息，头部"复制"旁显示图钉按钮；角标 1 为过滤后的片段数）。未 commit；未修改无关 WIP。

## Phase 5 实现记录（2026-09-26）

### 实现与文件

- 新增 `iosApp/iosApp/ConversationRecap.swift`：回顾模型、3 条用户消息门槛、当前分支编号、增量输入、过时判断和 JSON 解析。首次取最近 32 条有效消息，并拼入可用的压缩摘要；工具名称、输入和文本回执也进入输入。已有回顾沿覆盖点追加新消息；换分支或覆盖点消失时，保留旧回顾作为待校正上下文，附当前分支最近消息，旧节点按来源 ID 重编号，不存在的来源不进入引用映射。
- 新增 `iosApp/iosApp/ConversationRecapGenerator.swift`：复用 `titleModelId → 当前聊天模型` 和辅助请求参数；正常完成后按对话 300ms 去抖，进行中不重复请求；点开首次生成、刷新和重试共用入口。请求显式接收现有 `sharedSettings`，按发起对话捕获消息、分支和 `writeBaseline`，结果通过 token 和 `canApplyAuxiliaryResult` 后写回原对话。持久化的压缩边界覆盖冷开与后台路径。
- 新增 `iosApp/iosApp/IOSConversationRecapStore.swift`：在 `conversations/conversation-recaps.json` 按对话保存小型 JSON。
- 新增 `iosApp/iosApp/ChatRecapPanel.swift`：从岛下展的玻璃卡片，340pt 最大宽度、16pt 内边距、现有主题圆角，内容收高且最多 55% 屏高；节点图标、红色失败节点、不可定位说明、待办填入输入框、失败重试与过时刷新。标题区下拉、再次点岛、点外部或关闭按钮收起；Reduce Motion 下淡入淡出。
- 修改 `iosApp/iosApp/ChatTopBarView.swift`、`ChatView.swift`：只在点下时显示 `.title` 且过门槛时打开回顾；保留播报、活动定位、长按停止、侧边玻璃独立以及用户已有的产物架原生 popover 改动。节点定位复用 `ChatMessageAnchor`；待办不自动发送。
- 修改 `iosApp/iosApp/ChatCollectionMessageList.swift`：普通消息 anchor 定位完成后高亮 1.2 秒，沿用既有居中定位与历史窗口机制，没有像素滚动或高度补偿。
- 修改 `iosApp/iosApp/ChatViewModel.swift`、`IOSChatBackgroundGenerationCoordinator.swift`：前台以及后台两条正常完成路径调度回顾。前台入口在原有纯文本检查之前，覆盖纯工具/图片成功结果；失败、取消不在这些成功入口内。
- 修改 `iosApp/iosApp/IOSConversationStore.swift`、`IOSSyncBackup.swift`：删除提交后清理本对话及后代，恢复后清理被覆盖对话并使旧请求失效；有旧回顾/请求的恢复场景留下可见重试说明。回顾 JSON 与产物架一致不进备份。
- 新增测试 `iosApp/iosAppTests/ConversationRecapTests.swift`（6 项）、`IOSConversationRecapStoreTests.swift`（8 项）、`ChatRecapLayoutTests.swift`（1 项）：门槛、编号与越界、工具与摘要增量、跨分支重编号、过时、JSON 失败、按原对话写回、恢复/删除防旧写、清理、备份排除、去抖/去重及四态截图与面板尺寸。
- `iosApp/project.yml` 的 `path: iosApp` / `path: iosAppTests` 已覆盖这些新文件；运行 `xcodegen generate --spec iosApp/project.yml`，并核实生成工程包含全部 7 个新增 Swift 文件，无需重复添加显式 source 条目。

### 构建与命令

```bash
xcodegen generate --spec iosApp/project.yml
xcodebuild -quiet -disableAutomaticPackageResolution \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  EXCLUDED_SOURCE_FILE_NAMES=ChatToolTimelineWidthOverflowTests.swift build-for-testing
```

构建通过，日志 `/tmp/amber-phase5-build-final.log`（exit 0）。首次构建发现本轮 `toHexDashString()` 被误写为方法 key path，已改成闭包后通过。仅按任务要求排除 `ChatToolTimelineWidthOverflowTests.swift`，未修改该文件。

用户要求避免多余测试后，保留已经通过的结果，只补尚未完成的新增逻辑、顶栏/产物架相关测试及三组滚动；不再运行 Home 或重跑已通过的消息投影/缓存。补测复用构建产物：

```bash
xcodebuild -quiet \
  -xctestrun /Users/arquiel/Library/Developer/Xcode/DerivedData/AmberAgent-dszqlrkdzmllcpgtkmzneptukbka/Build/Products/iosApp_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:iosAppTests/ConversationRecapTests \
  -only-testing:iosAppTests/IOSConversationRecapStoreTests \
  -only-testing:iosAppTests/ChatTopBarArrivalTests \
  -only-testing:iosAppTests/ChatTopBarDockTests \
  -only-testing:iosAppTests/ChatTopBarLayoutTests \
  -only-testing:iosAppTests/ConversationActivityCenterTests \
  -only-testing:iosAppTests/ConversationArtifactIndexTests \
  -only-testing:iosAppTests/IOSConversationArtifactStoreTests \
  -only-testing:iosAppTests/IOSSubAgentActivityLayoutTests \
  -only-testing:iosAppTests/IOSP1BackupTests \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests \
  -resultBundlePath /tmp/amber-phase5-required.xcresult test-without-building
```

### 测试结果

按同一最终源码的各类最后一次有效结果合并，要求范围内 **221/222**；这是分批结果，不是一次全绿的总回归。

| 范围 | 结果 | 证据 |
| --- | --- | --- |
| 新增逻辑与存储 | 14/14 | `/tmp/amber-phase5-required.xcresult` |
| 新增回顾四态布局/截图 | 1/1 | `/tmp/amber-phase5-tests.xcresult`，iOS 27.0 |
| 产物架 Actions / AnchorLayout / Integration / ShelfLayout / ShelfState / TextDiff | 12/12、1/1、3/3、2/2、3/3、5/5 | 首轮已通过，未重复跑 |
| IslandNavigation / IslandPresentation | 8/8、26/26 | 首轮已通过，未重复跑 |
| Arrival / Dock / TopBarLayout / ActivityCenter / SubAgentLayout | 7/7、5/5、1/1、13/13、3/3 | 最后补测 |
| ArtifactIndex / ArtifactStore / P1Backup | 10/10、4/4、9/9 | 最后补测 |
| ChatSwiftUIStreamReplayTests | 35/36 | 最后补测 |
| NativeTimelineScrollCoreTests / ChatViewportPolicyTests | 55/55、4/4 | 最后补测 |

最后补测使用 iPhone 17 Pro / iOS 26.5（`E26720E3-CBE3-4178-A469-1DFA9154395A`），160/161，日志 `/tmp/amber-phase5-required.log`。唯一失败为 `ChatSwiftUIStreamReplayTests.testLongProseViewportFollowStaysLineSizedAtTwentyFourKB`：第 1773 行断言测得 36，门槛 24。该既有长文时序测试在本计划前面的记录中也有失败历史；本轮未修改相关实现或阈值，未做因果隔离，因此不声明根因。按照不多余测试的要求，没有再次重跑刷绿。

过程记录：原始 `name=iPhone 17 Pro` 命令自动选到 iOS 27.0。首轮日志缓冲被误判为停滞而中断，完整结果实际为 178/180；两项失败为 `testContinuousProseGrowthStaysLineSizedWhileFollowingBottom` 和 `testEveryGenerationTerminalReleasesBottomOwnershipAfterLateLayoutSettle`，二者最后在 iOS 26.5 均通过。首轮的 61 项本任务相关已通过结果被保留；额外执行过的消息投影 93/93、缓存 12/12 不计入上表要求范围，也未再次运行。后续一条 iOS 26.5 命令被对话中断，另一条在用户要求收窄后停止，均不计为测试通过。最终仅补尚未完成的要求项，没有继续运行 Home 或扩展用例。

### 截图与视觉检查

测试夹具渲染生产 `ChatTopBarView` 和 `ChatRecapPanel`，iPhone 17 Pro / iOS 27.0；与最终源码一致。截图已由主代理逐张打开查看，不以成功写文件代替视觉检查。

- `/tmp/amber-topbar/phase5-loading.png`
- `/tmp/amber-topbar/phase5-normal.png`
- `/tmp/amber-topbar/phase5-stale.png`
- `/tmp/amber-topbar/phase5-failure.png`

检查：岛与两侧圆按钮独立、无重叠；卡片从岛下方展开，宽度、左右内边距、标题与关闭按钮位置一致。加载与失败态按内容收高；正常与过时态达到 55% 上限，其余节点/待办保留在 ScrollView 中。长节点自然换行，失败节点为红色；刷新、重试文字完整。测试另实测 340pt 与 300pt 面板宽度及 55% 高度上限，没有尺寸溢出。

### 遗留与范围

- 上述 1 项既有长文时序门禁失败，未改阈值或扩展排查。
- 真实 provider 的回顾质量、真机手感及 VoiceOver 实际朗读未验收；辅助请求和原对话写回通过注入 provider 的单元测试验证，截图只证明模拟器布局。
- 独立 review 确认并修复了跨分支旧引用、异步分支错标、冷开压缩摘要遗漏及恢复后的空白卡片路径。没有遗留已确认的 Phase 5 功能缺陷。
- 保留进入任务时所有无关 WIP；逐文件比对确认产物架面板、首页及其既有测试的原 diff 未改变。未修改 `ChatToolTimelineWidthOverflowTests.swift`；未 commit。

## Phase 5 review 修复（2026-09-26）

仅处理独立 review 指出的 11 项；保留本轮开始时的无关 WIP，不 commit。

| # | 修复 | 处理 |
| --- | --- | --- |
| 1 | 解析过严 | 使用现有 `IOSDeepReadDraftGenerator.extractJSONObject` 提取围栏/前后说明中的 JSON；未知 kind 仅丢弃该节点，有效节点保留前 8 条、至少 1 条；补解析用例。 |
| 2 | 输入无上限 | 每条消息总长最多 1500 字符，工具输入/输出各最多 300；首次和增量 transcript 都最多最近 32 条；补长度与增量用例。 |
| 3 | 面板透底 | 删除卡片上的自定义 glassEffect 背景，复用原生 popover，设置不透明 `AmberTheme.background`。 |
| 4 | 边缘与系统行为 | popover 挂在岛上、箭头朝上，与产物架同宽 340；iPhone 保持 popover，删除自定义外点捕获层和下拉手势，使用系统外点关闭与模态无障碍行为。 |
| 5 | 流式重算 | 生成中短路全部回顾相关输入；空闲时只计算一次 currentRecap；删除额外消息 ID Set。 |
| 6 | 首次点开沿用后台失败 | 没有已存回顾且不在加载时，点开总是请求生成，不再被旧 error 阻止。 |
| 7 | 待办覆盖草稿 | 先取输入控制器的当前草稿，非空则换行追加，空时直接填入；仍不发送。 |
| 8 | 命中区 | 刷新和重试的 label 内设置 minHeight 44 与 Rectangle contentShape。 |
| 9 | 无障碍 | 节点忽略装饰子视图，朗读“中文类型：标题”，可定位时给出“定位到原消息”hint；缺失来源给出不可定位说明。 |
| 10 | 对齐、滚动提示与高亮 | 节点按 firstTextBaseline 对齐，移除额外 6pt 竖向 padding，保留 44pt；添加与产物架一致的 canScrollDown 底部渐隐；恢复 panel 状态动画，使产物架细条淡入淡出；高亮从时间线整行移到实际消息内容。 |
| 11 | 重复判定与转发 | 保留引用投影置 nil 和点击时的可见错误，删除面板 currentMessageIDs；删 generator 的 eligible/isStale 包装，调用 Logic。 |

本轮修改：`ConversationRecap.swift`、`ConversationRecapGenerator.swift`、`ChatRecapPanel.swift`、`ChatTopBarView.swift`、`ChatView.swift`、`ChatCollectionMessageList.swift`、`MessageBubbleView.swift`、`ChatIslandNavigation.swift`；测试为 `ConversationRecapTests.swift`、`ChatRecapLayoutTests.swift`。未修改其他已有 WIP。

### 命令

构建与测试合在一次 `xcodebuild test` 中完成，固定 iPhone 17 Pro / OS 26.5，仅选择 Phase 5 三类测试、ChatTopBar/ChatArtifact 九类测试与三组滚动测试。仍按用户要求排除既有编译问题文件 `ChatToolTimelineWidthOverflowTests.swift`，未修改该文件。

```bash
xcodegen generate --spec iosApp/project.yml
xcodebuild -quiet -disableAutomaticPackageResolution \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  EXCLUDED_SOURCE_FILE_NAMES=ChatToolTimelineWidthOverflowTests.swift \
  -only-testing:iosAppTests/ConversationRecapTests \
  -only-testing:iosAppTests/IOSConversationRecapStoreTests \
  -only-testing:iosAppTests/ChatRecapLayoutTests \
  -only-testing:iosAppTests/ChatTopBarArrivalTests \
  -only-testing:iosAppTests/ChatTopBarDockTests \
  -only-testing:iosAppTests/ChatTopBarLayoutTests \
  -only-testing:iosAppTests/ChatArtifactActionsTests \
  -only-testing:iosAppTests/ChatArtifactAnchorLayoutTests \
  -only-testing:iosAppTests/ChatArtifactIntegrationTests \
  -only-testing:iosAppTests/ChatArtifactShelfLayoutTests \
  -only-testing:iosAppTests/ChatArtifactShelfStateTests \
  -only-testing:iosAppTests/ChatArtifactTextDiffTests \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests \
  -resultBundlePath /tmp/amber-phase5-review.xcresult test

```

### 结果

构建成功；同一次 iPhone 17 Pro / iOS 26.5（`E26720E3-CBE3-4178-A469-1DFA9154395A`）回归为 **152 通过、1 失败、0 跳过**。结果包 `/tmp/amber-phase5-review.xcresult`，日志 `/tmp/amber-phase5-review.log`。

| 范围 | 结果 |
| --- | --- |
| ConversationRecapTests | 10/10（本轮新增 4 项解析与输入限额用例） |
| IOSConversationRecapStoreTests / ChatRecapLayoutTests | 8/8、1/1 |
| ChatTopBarArrival / Dock / Layout | 7/7、5/5、1/1 |
| ChatArtifactActions / AnchorLayout / Integration | 12/12、1/1、3/3 |
| ChatArtifactShelfLayout / ShelfState / TextDiff | 2/2、3/3、5/5 |
| ChatSwiftUIStreamReplayTests | 35/36 |
| NativeTimelineScrollCoreTests / ChatViewportPolicyTests | 55/55、4/4 |

唯一失败：`ChatSwiftUIStreamReplayTests.testPerfGrowingTableStreamingKeepsDisplayLinkResponsive`，80 行长表格流式期间帧间隔 p95 为 **46.4527ms > 40ms**。该性能门禁在前面阶段有失败历史；本轮不改相关阈值、不重复刷绿，未做因果隔离，不能据此认定根因。上一轮失败的 24KB 长文测试本次通过。

### 重拍截图与检查

四张均由本轮构建在 **iPhone 17 Pro / iOS 26.5** 用测试夹具重新生成，主代理已逐张打开查看：

- `/tmp/amber-topbar/phase5-loading.png`
- `/tmp/amber-topbar/phase5-normal.png`
- `/tmp/amber-topbar/phase5-stale.png`
- `/tmp/amber-topbar/phase5-failure.png`

原生 popover 箭头对准岛，宽度/背景与产物架使用同一配置，系统负责外部遮罩与边距；卡片内未见正文透底。正常态节点和两条待办可见，长失败节点自然换行、箭头对齐首行；过时态底部渐隐可见，表示仍有可滚动内容。加载/失败态按内容收高，重试按钮完整。没有额外制作截图状态或扩大测试范围。

`git diff --check` 通过。除本节列出的修复文件与计划记录外，开始本轮时的其余 WIP 保持原样；未 commit。


## 停靠位面板改自绘（2026-09-27）

### 修改

- `ChatTopBarView.swift`：移除停靠位上的系统 popover，产物架与多条提醒列表共用右上 overlay 容器。背景为 `RoundedRectangle(cornerRadius: AmberTheme.homeCardRadius, style: .continuous)`，不透明 `AmberTheme.background`、0.5pt `AmberTheme.border` 描边，以及黑色 0.12 / radius 12 / y 5 的轻阴影；不使用 glassEffect 或带尖角的 Shape。
- 宽度沿用 `min(340, geometry.size.width - (44 - toolbarButtonDiameter))`，右侧 padding 沿用 `(44 - toolbarButtonDiameter) / 2`，顶部为 controlsHeight + 8。产物架定位后的 shelfCollapsed 使用相同宽度和右侧计算，原有定位、测量 inset、下拉恢复与关闭接线保留。展开使用 topTrailing scale + opacity，Reduce Motion 使用 opacity。
- `ChatView.swift`：把原先仅挂在消息列表的点按观察移到页面级 `SpatialTapGesture`，与现有手势同时识别；按实测全局边界排除面板和停靠位本身，其余点按发出关闭信号。不增加全屏透明命中层，不用拖动手势截获时间线滚动。面板空白区单独接收点按，避免误触下方消息；停靠位再次点按可收起面板。
- 自绘容器增加 `.isModal`、VoiceOver escape 关闭动作和 screenChanged 通知。面板内容、产物架 header、导出/详情 sheet 等均保持原样。
- 回顾的岛上原生 popover 保持原配置；`ChatRecapPanel.swift` 与本轮开始时字节一致，保留用户删除 x / ↗、24pt 图标列及“接下来”行对齐的改动，没有恢复 onClose 参数。
- 仅在现有 `ChatArtifactShelfLayoutTests.swift`、`ChatTopBarLayoutTests.swift`、`ChatRecapLayoutTests.swift` 的截图保存处增加 dockpanel 文件名；没有新增测试类、重复截图等待或扩展测试矩阵。

### 命令与结果

```bash
xcodegen generate --spec iosApp/project.yml
xcodebuild -quiet -disableAutomaticPackageResolution \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  EXCLUDED_SOURCE_FILE_NAMES=ChatToolTimelineWidthOverflowTests.swift \
  -only-testing:iosAppTests/ConversationRecapTests \
  -only-testing:iosAppTests/IOSConversationRecapStoreTests \
  -only-testing:iosAppTests/ChatRecapLayoutTests \
  -only-testing:iosAppTests/ChatTopBarArrivalTests \
  -only-testing:iosAppTests/ChatTopBarDockTests \
  -only-testing:iosAppTests/ChatTopBarLayoutTests \
  -only-testing:iosAppTests/ChatArtifactActionsTests \
  -only-testing:iosAppTests/ChatArtifactAnchorLayoutTests \
  -only-testing:iosAppTests/ChatArtifactIntegrationTests \
  -only-testing:iosAppTests/ChatArtifactShelfLayoutTests \
  -only-testing:iosAppTests/ChatArtifactShelfStateTests \
  -only-testing:iosAppTests/ChatArtifactTextDiffTests \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests \
  -resultBundlePath /tmp/amber-dockpanel.xcresult test
```

构建通过；同一轮固定 iPhone 17 Pro / iOS 26.5（`E26720E3-CBE3-4178-A469-1DFA9154395A`）测试为 **151 通过、2 失败、0 跳过**。结果包 `/tmp/amber-dockpanel.xcresult`，日志 `/tmp/amber-dockpanel.log`。仍仅在编译命令中排除既有问题文件 `ChatToolTimelineWidthOverflowTests.swift`，未修改它。

| 范围 | 结果 |
| --- | --- |
| ChatTopBar Arrival / Dock / Layout | 7/7、5/5、1/1 |
| ChatArtifact Actions / AnchorLayout / Integration | 12/12、1/1、3/3 |
| ChatArtifact ShelfLayout / ShelfState / TextDiff | 2/2、3/3、5/5 |
| ChatRecapLayout / ConversationRecap / IOSConversationRecapStore | 1/1、10/10、8/8 |
| NativeTimelineScrollCore / ChatViewportPolicy | 55/55、4/4 |
| ChatSwiftUIStreamReplay | 34/36 |

失败名与证据：

1. `ChatSwiftUIStreamReplayTests.testLongProseViewportFollowStaysLineSizedAtTwentyFourKB`：可见文本发布次数 42 < 45。
2. `ChatSwiftUIStreamReplayTests.testPerfGrowingTableStreamingKeepsDisplayLinkResponsive`：帧间隔 p95 为 54.9387ms > 40ms。

两项都是此前出现过的既有时序门禁；本轮未隔离因果，不认定根因，也没有修改滚动实现、阈值或重复跑测刷绿。

### 截图检查

以下四张均为本轮构建在 iPhone 17 Pro / iOS 26.5 上用现有夹具重新生成，主代理已逐张打开查看：

- `/tmp/amber-topbar/dockpanel-shelf.png`：有内容的产物架。
- `/tmp/amber-topbar/dockpanel-empty.png`：空态。
- `/tmp/amber-topbar/dockpanel-notices.png`：多条提醒列表。
- `/tmp/amber-topbar/dockpanel-recap.png`：回顾正常态。

检查结果：两种停靠位面板右上角均为连续圆角，没有尖角；右缘对齐停靠位圆形按钮，顶部有间隔，阴影轻且连续，正文仅在面板外可见，没有透入面板内部。空态按内容收高；提醒列表沿用原内容和最大 320pt 滚动区。回顾仍保留居中尖角和用户修改后的图标/文字布局。截图和单元测试不代替真机 VoiceOver 操作验收。

`git diff --check` 通过；本轮之外的 WIP 保留，未 commit。


## 未达门槛点岛提示（2026-09-27）

### 实现

- `ChatTopBarView.swift`：点下时显示 `.title`、未达到回顾门槛且当前未生成时，触发提示、`UIImpactFeedbackGenerator(style: .light)` 和 VoiceOver announcement“再聊几轮就能回顾”。已达门槛的展开/收起与生成中的原导航分支保持原样。
- 提示复用现有 `ChatActivityIslandView` 的标题渲染与过渡，临时标题为“再聊几轮就能回顾”；轻鼓复用 `islandScale` 的 1.06 倍、0.2s / 0.65 弹簧，160ms 后用原 0.32s / 0.8 弹簧恢复。Reduce Motion 下跳过鼓动。未达门槛的 accessibilityHint 改为“再聊几轮后可展开对话回顾”。
- `ChatTopBarArrivalState.swift`：在现有岛播报状态中记录提示的 1.8 秒截止时间；到期后移除临时标题、恢复当前对话标题。提醒播报优先并取消提示，播报期间不再插入提示；切换对话、开始生成或离开页面时清掉提示，旧动画任务不回写新播报的缩放。
- `ChatTopBarLayoutTests.swift`：仅增加 `testIneligibleIslandTapShowsHintThenRestoresTitle` 一项，覆盖提示事件→标题替换→1.8 秒到期恢复，并检查播报优先/切换取消。同一测试使用该事件后的状态渲染生产顶栏并保存截图；这是状态单元断言与布局夹具，不把它表述为真机点击、触感或 VoiceOver 实测。

### 命令与结果

```bash
xcodegen generate --spec iosApp/project.yml
xcodebuild -quiet -disableAutomaticPackageResolution \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  EXCLUDED_SOURCE_FILE_NAMES=ChatToolTimelineWidthOverflowTests.swift \
  -only-testing:iosAppTests/ChatTopBarArrivalTests \
  -only-testing:iosAppTests/ChatTopBarDockTests \
  -only-testing:iosAppTests/ChatTopBarLayoutTests \
  -only-testing:iosAppTests/ChatIslandNavigationTests \
  -only-testing:iosAppTests/ChatIslandPresentationTests \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests \
  -resultBundlePath /tmp/amber-island-hint.xcresult test
```

构建通过。固定 iPhone 17 Pro / iOS 26.5（`E26720E3-CBE3-4178-A469-1DFA9154395A`）单轮 **143 通过、0 失败、0 跳过**；未扩展到无关存储、产物或 Home 测试。

| 测试 | 结果 |
| --- | --- |
| ChatTopBarArrival / Dock / Layout | 7/7、5/5、2/2（含新增用例） |
| ChatIslandNavigation / ChatIslandPresentation | 8/8、26/26 |
| ChatSwiftUIStreamReplay / NativeTimelineScrollCore / ChatViewportPolicy | 36/36、55/55、4/4 |

日志 `/tmp/amber-island-hint.log`，结果包 `/tmp/amber-island-hint.xcresult`。仍只在命令中排除既有编译问题文件 `ChatToolTimelineWidthOverflowTests.swift`，未修改该文件。未修改滚动实现或测试阈值，通过后没有重复跑测。

### 截图

`/tmp/amber-topbar/island-recap-hint.png`，由本轮构建的 iPhone 17 Pro / iOS 26.5 夹具生成。主代理已打开查看：“再聊几轮就能回顾”完整显示，无省略号、无裁切，岛与两侧按钮无重叠。

只修改上述三个 Swift 文件及本计划记录；无关 WIP 保留，未 commit。真机触感和 VoiceOver 实际播读未验收。


## 面板收高与内边距修正（2026-09-27）

- 提醒列表测量 header 与行内容高度，滚动区取 `min(内容高度, shelfHeight - header - 间距 - 上下 padding)`，两条提醒不再占满固定 320pt，长列表仍限制在 shelfHeight 内滚动。
- 提醒列表、产物架、回顾统一删除多余的 12pt trailing scrollContent margin，使用外层左右各 16pt 内边距；提醒 header 的“清除”胶囊与状态文字右缘对齐。
- 核对产物架后确认，旧的额外 top 8pt / available -8 已不存在。本次把普通态的底部 16pt 从滚动区外移入滚动内容，scrollHeight 不再重复扣除这段 padding；视口和渐隐延伸至面板底边，并按现有圆角裁剪内容。内容不足时总高度保持贴合，空态与多选底栏的原有留白保留。
- 只修改 `ChatTopBarView.swift`、`ChatArtifactShelfPanel.swift`、`ChatRecapPanel.swift`，并调整现有 `ChatArtifactActionsTests` 高度断言、`ChatTopBarLayoutTests` 的少量/溢出提醒高度检查；没有新增测试类或扩展矩阵。

验证命令（脚本内是 xcodegen + xcodebuild test，固定 iPhone 17 Pro / OS=26.5）：

```bash
zsh /tmp/amber-panel-fit-tests.sh
```

选择的相关测试仅为 `ChatTopBarLayoutTests`、`ChatArtifactActionsTests`、`ChatArtifactShelfLayoutTests`、`ChatArtifactAnchorLayoutTests`、`ChatRecapLayoutTests`，以及指定三组 `ChatSwiftUIStreamReplayTests` / `NativeTimelineScrollCoreTests` / `ChatViewportPolicyTests`。继续只在编译命令中排除 `ChatToolTimelineWidthOverflowTests.swift`，未修改该文件。

构建通过；单轮 **111 通过、2 失败、0 跳过**。相关测试 **18/18**，三组滚动分别 **34/36、55/55、4/4**。结果包 `/tmp/amber-panel-fit.xcresult`，日志 `/tmp/amber-panel-fit.log`。失败：

- `ChatSwiftUIStreamReplayTests.testLongProseViewportFollowStaysLineSizedAtTwentyFourKB`：发布次数 34 < 45。
- `ChatSwiftUIStreamReplayTests.testPerfGrowingTableStreamingKeepsDisplayLinkResponsive`：长表格追加停顿指标 97.9628ms > 80ms。

两项均为此前出现过的时序门禁；未隔离因果，不认定根因，不修改阈值或重复刷绿。

本轮重新生成并逐张查看：`/tmp/amber-topbar/dockpanel-shelf.png`、`dockpanel-empty.png`、`dockpanel-notices.png`、`phase5-normal.png`（均在同一目录）。检查确认：提醒列表下方大块空白消失，右侧 header/状态对齐；文件卡片左右内边距相等，底部操作行完整，下一组内容在面板底边渐隐；空态正常，回顾正文宽度恢复且无裁切。保留原有圆角、右缘位置、不透明背景以及用户的回顾图标列/去箭头改动。

`git diff --check` 通过；无关 WIP 保持原样，未 commit。

## 停靠位面板卡顿与收起动画（2026-09-27）

- 原因：面板/停靠位用 `onGeometryChange(.global)` 把区域写入 ChatTopBarView 的 `@State` 并回调到 ChatView 的 `@State dockInteractionRegions`；展开/收起的 scale 过渡与停靠位弹跳期间逐帧变化，导致整个聊天页逐帧重算（其中 `visibleSnippets`、回顾门槛、过时判定都遍历全部消息），长对话明显卡顿。页面级点按也在面板未打开时每次递增 `artifactShelfDismissRevision`，引发一次整页重算。
- 修复：新增非观察的 `ChatDockTapRegions`（ChatTopBarView.swift），几何回调直接写入，点按时读取；只有面板打开时点外部才递增关闭信号。
- 收起：改为非对称过渡，收起用 0.96 缩放 + 淡出、`easeOut(0.22)`，展开保持原弹簧。
- 圆角：停靠位面板改为 `ChatTopBarLayout.dockPanelCornerRadius = 30`，与岛上回顾 popover 一致；回顾与产物架的横向内边距移入滚动内容，滚动条贴面板右缘。
- 验证：ChatTopBar Layout/Dock/Arrival、ChatArtifact ShelfLayout/Integration/AnchorLayout、ChatRecapLayout 通过（iPhone 17 Pro / iOS 26.5）。两项流式计时门禁在 HEAD 基线（worktree 构建）同样失败（表格 p95 40.6–79ms、长文 2/3 失败），确认非本轮引入。
