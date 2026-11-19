# Pi iOS 对话审查定点修复交付

## 结论

仅在 `/Users/arquiel/.synara/worktrees/ce201253131e` 修复 F1、F2、F3、S3、S4。五项定点与受影响缓存/增量投影回归最终 **33 passed / 0 failed / 0 skipped**，`xcodebuild` exit 0。

相邻额外运行的 `ChatMessagePresentationTests/testAgentResultsUseStaticAgentCardsWhileInternalProgressStaysOutOfTimeline` 仍有两处 continuation 标题断言失败；不在本次五项内，未修改该判断。不能宣称全部聊天测试或所有相邻检查通过。

## 工作区与边界

- 接手及收尾 HEAD：`84176fde736d3056e7a30fb1df66e44b7d378f5c`。
- 保留 MERGE_HEAD：`6e89805b2667098e8ef523545915ca77c7b5f4a2`。
- 保留两个 UU：`MessageBubbleView.swift`、`ChatTimelineReviewRegressionTests.swift`。索引 stage 1/2/3 指纹 SHA-1 前后一致：`17ad4fc4e9af9f7d617516ad1f85a8db904d1f59`。
- 保留原 staged/unstaged/WIP，没有 add、commit、push、reset 或 merge 收尾。未修改主仓、记忆树、面板树；无真实 Key、付费模型或线上 provider 请求。
- 原工作区源码指纹连续核对稳定，未见原对话线程并发写入。构建产物和测试证据均在本 worktree 的 `iosApp/build/`。
- 本次使用 diagnosing-bugs、implement 和 SwiftUI 数据流边界指导；未委派子代理或自行发起复审。

## 五项闭环与实际修改文件

以下路径均以本 worktree 为根；这里只列 Pi 本轮触碰文件，不能把相对 HEAD 的全部 WIP diff 归为本轮新增。

### F1 / P1：首 token 等待与 queued 任务被误取消

根因：`startOrEnqueueTaskSlot` 调用清理函数时，把“无正文/无工具”的 active/queued 槽当成 stalled 并 cancel。

- `iosApp/iosApp/Chat/Session/ChatAsyncTaskIsolation.swift`：清理只遍历**明确终态**的旧槽；等待首 token、reasoning 和 queued 不再成为取消依据。显式取消、分支孤儿清理等既有所有权路径保留。
- `iosApp/iosAppTests/ChatAsyncReActLoopTests.swift`：新增真实 `sendMessage` 入口用例，受控合成 provider 让 A 等首 token，独立 B 入队，再发送 C；断言 A 未取消、B 未退休，并最终交付 A/B/C。原“仅无正文即应退休”测试改为先验证 live 不退休，再显式 terminal 后清理。

结果：新用例在修复前失败、修复后通过；整个 `ChatAsyncReActLoopTests` 最终通过。

### F2 / P1：新阶段首段被 dropFirst 丢弃

根因：开场接话与新阶段正文共用数组；新阶段数组首项是本阶段正文，但继续合并仍无条件 dropFirst。

- `ChatAsyncTaskIsolation.swift`：显式记录当前阶段数组是否包含开场接话，只有该情况下合并才去掉开场项；阶段切换和重置同步更新此标记。
- `ChatAsyncReActLoopTests.swift`：在切入新 web 阶段后再追加同阶段碎片；同时验证合并气泡、`slot.currentTranscript`、会话 `state.messages` 及再次 splice 后均保留阶段首段和续片。

结果：原样生产 coalescer 对新增续片断言先红后绿。新增 transcript 断言曾因 `toText()` 的既有工具尾换行失败，已仅对测试比较做首尾空白归一化；没有因此修改生产正文。

### F3 / P2：方括号开头 Markdown 被误判为 JSON

根因：任何 `[` 开头正文均进入 JSON 失败即丢弃的分支，包含链接和普通标签。

- `iosApp/iosApp/IOSSubAgentOutput.swift`：区分对象/数组协议载荷和 Markdown。合法 JSON 数组、截断对象数组仍 fail closed；普通链接/方括号标签保留。相同判定用于 Structured Digest/Raw Output 与摘要接缝，已知数组 envelope 也进入净化，不回退展示内部整包 JSON。
- `iosApp/iosAppTests/ChatMessagePresentationTests.swift`：合成链接、标签、`child run ended` trailer、Structured Digest/Raw Output；覆盖提取、实际 KMP mailbox message、卡片构造/投影正文与 exporter `shareText`；另覆盖内部数组/损坏 JSON 不泄漏。

结果：修复前真实 mailbox/导出接缝丢正文，修复后保留；原 host envelope、云端 ingestion 和不泄漏 JSON 用例也通过。未进行视觉布局验收或真实 mailbox 服务请求。

### S3 / P2：父级直接扫描高频 messages

- `iosApp/iosApp/Chat/Presentation/ChatScreenValues.swift`：在既有可判等 `ChatListSummarySnapshot` 中计算末尾角色与最近 user 前的消息 ID 集合，提供纯摘要锚点选择。
- `iosApp/iosApp/Chat/Presentation/ChatViewScreenSignals.swift`：事件刷新摘要时填充锚点数据；`currentTimelineActivity` 只消费投影，不再读取 `viewModel.messages`。点击/事件路径的既有读取未动。
- `ChatMessagePresentationTests.swift`：验证独立新问题、定向补充、mailbox 非会话 user、分支移除，以及同 ID 流式正文变化不改变锚点摘要。
- `iosApp/iosAppTests/PerformanceHygieneTests.swift`：源码接缝回归约束父级属性不读原始集合；修复前失败、修复后通过。

### S4 / P2：气泡重算同步净化/JSON 解码

- `IOSSubAgentOutput.swift`：提供接收边界按 part index 生成的不可变展示正文，以及完全不解码的未准备 fallback；不修改原始协议消息。
- `iosApp/iosApp/Chat/Timeline/ChatTimelineUpdates.swift`：消息事件 owner 在 `publish` 通知任何观察者/尾行消费者之前准备展示正文，持有并复用原有 `NativeTimelineProjectionCache`，没有新建第二套缓存类。
- `iosApp/iosApp/Chat/Timeline/NativeTimelineProjectionCache.swift`：在事件路径 `prepareDisplayTexts` 用既有 facts/identity 精确复用；body-side `projection` 只读已准备 facts，不调用解码器。历史首帧 reset 保留该事件已经准备的 facts，下一消息事件按当前消息集合裁剪。
- `iosApp/iosApp/Chat/Timeline/Projection/NativeTimelineProjection.swift`：展示正文作为既有 message facts 的字段；全量与 streaming-tail entry 都携带快照。无事件快照的冷路径仅使用不解码、安全留空的 fallback。
- `iosApp/iosApp/Chat/Timeline/Projection/ChatMessageProjection.swift`：行模型传递展示快照，未准备的非默认调用者只使用不解码 fallback。
- `iosApp/iosApp/Chat/Timeline/ChatRenderState.swift`：既有 live-tail owner 只保存接收边界已准备的展示快照，初始化/更新均不解码。缓存的准确性由上游既有 `ChatMessageContentIdentity` 检查；新正文即使 ID、长度相同也重新准备。
- `iosApp/iosApp/Chat/Timeline/NativeChatTimelineView.swift`、`ChatTimelineRows.swift`：把投影或 live-tail 的当前展示快照传到气泡。
- `iosApp/iosApp/Chat/Message/MessageBubbleView.swift`：两个正文 renderer 与结果卡只查快照；不调用 sanitization、提取或 JSON 解码。未投影的 preview 调用者可显示普通文本，但已知 envelope 安全留空，不能回退为原包。
- `iosApp/iosApp/ChatSubAgentResultCard.swift`：接受已投影 `displayText` 的构造器不再做 envelope 解码。显式 `init(message:)` 保留一次边界提取，生产气泡改走已投影构造器。
- `ChatMessagePresentationTests.swift`：通过真实 `ChatTimelineUpdates.publish` → 首帧 reset → 缓存投影验证原始协议不变、全量/尾行投影、live-tail 快照复用、同 ID 同长度但正文变化时更新；同时确认没有事件准备的冷路径不会解码 envelope。包含 500 次旧 helper 调用与 500 次新快照读取的输出等价对照；没有可靠留存分项耗时，因此不报告性能倍数，不把它当作 UI 帧耗时证据。
- `PerformanceHygieneTests.swift`：锁住气泡渲染源码无 sanitizer、提取器或 JSONSerialization，并约束 body-side facts/行投影/live-tail 不能重新调用准备函数；实际准备入口必须在消息发布路径。

收尾发现原投影本身由 SwiftUI body 调用，因此没有停在“把解码移进投影构造器”；额外前移到消息发布事件，并补跑 `ChatTimelineUpdatesTests` 全类（4 项）。这沿用既有 facts 缓存、消息 identity 与 live-tail owner，未新增全局缓存体系。上述合计 13 个生产文件、3 个已有测试文件。

## 实际验证命令与结果

设备由 `device_list` 读取，使用已 booted 的 iPhone 17 Pro / iOS 26.5 / arm64 Simulator：`F3D5299E-EEA6-4098-BF61-AB1C516933C0`。未 boot 新设备、未真机安装或发布；`xcodebuild test` 正常运行模拟器测试宿主。

### 初次红灯

通用参数与最终命令相同（没有 `-resultBundlePath`），仅选择以下 5 个用例，并将日志重定向到 `iosApp/build/review-targeted-red.log`：

```text
-only-testing:iosAppTests/ChatAsyncReActLoopTests/testIndependentQuestionsPreserveFirstTokenWaitAndQueuedTasksAtSendEntry
-only-testing:iosAppTests/ChatAsyncReActLoopTests/testCommentaryCoalescesSameStageFragmentsPreservesPublishedProseAndSplitsOnMilestone
-only-testing:iosAppTests/ChatMessagePresentationTests/testBracketLeadingMarkdownSurvivesMailboxCardAndExportBoundaries
-only-testing:iosAppTests/PerformanceHygieneTests/testTimelineActivityConsumesSummaryInsteadOfRawMessages
-only-testing:iosAppTests/PerformanceHygieneTests/testMessageBubbleDoesNotDecodeOrSanitizeProtocolEnvelopesDuringRendering
```

实际 `xcodebuild ... test` exit **65 / TEST FAILED**；失败列表包含全部 5 个用例。早期 xcresult 被 Xcode 日志轮转清除，红灯文本日志仍保留。

### 最终定点集

从指定 worktree 运行，精确命令：

```bash
cd /Users/arquiel/.synara/worktrees/ce201253131e
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0' \
  -derivedDataPath iosApp/build/ReviewTargetedTests \
  -clonedSourcePackagesDirPath iosApp/build/ExperimentalDeviceBuild/SourcePackages \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  -resultBundlePath iosApp/build/ReviewTargetedEventBoundary.xcresult \
  -only-testing:iosAppTests/ChatAsyncReActLoopTests \
  -only-testing:iosAppTests/ChatMessagePresentationTests/testBracketLeadingMarkdownSurvivesMailboxCardAndExportBoundaries \
  -only-testing:iosAppTests/ChatMessagePresentationTests/testTimelineActivityAnchorSummaryTracksStructureNotStreamingText \
  -only-testing:iosAppTests/ChatMessagePresentationTests/testDisplayTextSnapshotsKeepRawProtocolAndInvalidateOnExactBodyChanges \
  -only-testing:iosAppTests/ChatMessagePresentationTests/testSubAgentResultExtractionStripsHostEnvelopePreservesMarkdownAndNeverFallsBackToRawJSON \
  -only-testing:iosAppTests/PerformanceHygieneTests/testTimelineActivityConsumesSummaryInsteadOfRawMessages \
  -only-testing:iosAppTests/PerformanceHygieneTests/testMessageBubbleDoesNotDecodeOrSanitizeProtocolEnvelopesDuringRendering \
  -only-testing:iosAppTests/ChatRowContentHashCacheTests \
  -only-testing:iosAppTests/ChatTimelineReviewRegressionTests/testP1IncrementalProjectionMatchesFullBuildAndSkipsHistoricalBridging \
  -only-testing:iosAppTests/ChatTimelineUpdatesTests \
  test > iosApp/build/review-targeted-event-boundary.log 2>&1

xcrun xcresulttool get test-results summary \
  --path iosApp/build/ReviewTargetedEventBoundary.xcresult --format json \
  > iosApp/build/review-targeted-event-boundary-summary.json
```

实际结果：exit **0**，summary 为 **Passed / 33 tests / 0 failures / 0 skipped**，总 action 时间约 65.6 秒。包含实际 Swift 编译链接与本仓 Shared.framework 消费，不只是抽取函数或 stub 探针。

注意：`-resultBundlePath` 必须指定尚不存在的目录；复跑时换一个新证据目录，不要覆盖已有证据。

### 相邻未通过项

在上一轮定点命令中额外加入：

```text
-only-testing:iosAppTests/ChatMessagePresentationTests/testAgentResultsUseStaticAgentCardsWhileInternalProgressStaysOutOfTimeline
```

实际该用例在 full projection 与 fast-tail replacement 上各有一处 continuation 标题断言失败。该轮总计 29 项：27 passed / 2 failed；另一个失败是本轮 F2 新 transcript 断言的工具尾换行比较，后者已修正并在最终集通过。

未通过的标题用例未被修改或标 skip。涉及的 `NativeTimelineProjector` continuation 判断与 HEAD 一致，本轮只给该文件新增展示快照字段及传递；但没有执行干净 HEAD 对照，故仅报告为“相邻未解决失败”，不把既有逻辑一致当成已执行的基线证明。最终 33 项定点集没有包含此标题用例，不能用最终绿灯抹去它。

### 静态检查

- 对本轮修改文件执行定点 diff whitespace 检查无新问题；整个 WIP 的 `git diff --check` 仍报告 `ChatAsyncTaskIsolation.swift` 既有 EOF 空行。保留既有内容未顺手清理。
- SourceKit LSP 定点 probe 不能替构建背书：4 文件中 3 个超时，另 1 个报缺 Shared 模块。实际 Xcode 编译/链接与测试已通过。
- 构建日志存在 Xcode 的 `command failed with exit code 0 but produced no further output` 噪声；最终 xcodebuild exit 0 与 xcresult 33/0 为实际测试结论，不将这些日志行误报成未编译成功。

## 未验证与下一步

- 未跑全量测试、长流式回放集；按本轮明确范围只执行受影响接缝。
- 默认 Native timeline 经消息发布入口准备完整正文。未接入该事件 owner 的 legacy/preview 调用者会对已知 envelope 安全留空；普通正文不受影响。本轮没有扩展非默认 renderer 的事件接线，不能据此宣称其 envelope 展示已验证。
- Library 归档工具拒绝 worktree 报告路径，称不在调用线程的宿主 workspace。未为绕过该边界复制到主仓或直接写 Library；报告保留在唯一指定 worktree，可供协调者读取。
- 未做真实 provider、网络 mailbox、后台续跑、云端服务或真机交互验证。
- 未做完整 Native timeline 的视觉/手感、首帧、滚动、键盘、安全区或大字号验收。
- 未整合记忆/面板树、未解决 merge 索引、未提交。原 UU 与所有既有 WIP 留给协调者后续集成。
- 建议协调者按原计划安排原 Codex xhigh 对五项修复定点复核，并单独决定相邻 continuation 标题失败是否纳入下一范围。本线程没有自行发起复审。

本地主要证据：

- [最终测试摘要](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/review-targeted-event-boundary-summary.json)
- [最终 xcresult](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ReviewTargetedEventBoundary.xcresult)
- [首次红灯日志](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/review-targeted-red.log)
- [包含相邻失败的摘要](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/review-targeted-green-summary.json)
