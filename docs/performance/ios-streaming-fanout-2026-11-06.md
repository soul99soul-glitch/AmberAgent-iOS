# iOS 流式失效范围量化 — 2026-11-06

本阶段仅测量，产品基线为 `46071c9b`，测量起点为 `b8a65d36`。分支 `synara/measure-ios-streaming-performance`；未改变产品逻辑、未推送、未装真机。

**主要结论：稳定流式事件没有让历史行 body 或行布局方法全量重跑，但历史行仍被全量判等，且判等本身有显著成本。** 当前时间线已有的 Equatable 屏障挡住了稳定历史行的 body 更新；这些窗口也没有触发历史行 Layout 回调。不能以“历史行每个 token 都重新渲染”为下一步设计前提。

完整搜索回放仍复现严重停顿：工具与流式阶段主线程 CPU 占用 81.58%，最长显示帧间隔 1050.88ms。本轮没有性能改善交付。

## 测量范围与方法

- Xcode 27.2 / 27B52，arm64 Debug；iPhone 17 Pro 模拟器，iOS 26.5 / 23F77，UDID `F3D5299E-EEA6-4098-BF61-AB1C516933C0`。
- 复用交接的私有捕获：127 条消息，第一个任务从 index 111 开始；任务区间含 24 个 tool part、12 个 reasoning part。媒体已在原夹具中移除。输入 SHA256：`f4aa21b6a29081d14b0d543086c40d304e9848baf3369b3d6cc9c471cf119d96`。
- 使用生产 `NativeChatTimelineView`，挂载在真实 UIWindow / UIHostingController。历史消息共 111 条，其中预热期间观测到 95 条历史消息行参与挂载/布局；后续计数按这些历史消息 ID 区分当前任务。这里的“历史”是本次任务之前的消息，不包括本次任务的上一条回复。
- 初始预热 6s，添加流式尾行后预热 2s，每个事件记录约 300ms。主线程被长工作占住时，窗口会超过 300ms，JSON 保留实际时长。单 token 探针具体是追加一个汉字 `续`，不宣称它等于模型 tokenizer 的一个 token。
- body 计数覆盖行外壳、hosted bubble、MessageBubble、Markdown；布局分别计 `sizeThatFits` 请求、实际调用子 view 的测量、`placeSubviews` 和 cache invalidation。只在测试显式启用时累计，不发布任何可观察状态。
- CADisplayLink 相邻回调之间读取 `CLOCK_THREAD_CPUTIME_ID`，记录主线程 CPU；这不是 GPU render time。首尾区间分别从事件开始/结束截断并明确标记，不能把一个截断区间冒称完整帧。
- 完整搜索回放采用原来的 24 字符 / 30ms 输入节奏；主线程繁忙时事件泵也会被延迟。测量窗口仍不等待所有前台吐字完全排空，所以它不是最终可见吐字验收。

## 单事件结果

最终数据为 `fanout-06-raw.json` / `fanout-06-summary.json`。`fanout-04` 与 `fanout-05` 已取得同样的历史行零重算结论；最终轮补齐布局参与行数与完整的帧边界记录。

| 事件 | 历史行 body 重算（外壳/Message/Markdown） | 历史行 sizeThatFits / 实测 / place 次数 | 实际参与布局的当前任务行数 | 当前行 sizeThatFits / 实测 / place 次数 | 历史行判等次数 |
|---|---:|---:|---:|---:|---:|
| 一个字的流式更新 | 0 / 0 / 0 | 0 / 0 / 0 | 1 | 21 / 21 / 42 | 569 |
| 追加一次真实捕获的工具结果消息 | 0 / 0 / 0 | 0 / 0 / 0 | 2 | 5 / 5 / 10 | 1138 |
| 进度文案切换一次 | 0 / 0 / 0 | 0 / 0 / 0 | 0 | 0 / 0 / 0 | 569 |
| 追加含换行的 75 字符 chunk（补充对照） | 0 / 0 / 0 | 0 / 0 / 0 | 1 | 81 / 81 / 162 | 569 |

单字事件更新一次 timeline body、一次 live-tail body、一次 MessageBubble body、两次 Markdown body；工具事件涉及两条当前任务行，判等失败原因落在 `isLast`、`renderState`、`assistantTurn`、digest，历史行没有这些失败。进度切换只更新一次 timeline body 和一次 progress body。

| 事件 | 实际窗口 ms | 窗口主线程 CPU ms | 完整帧区间 CPU P50 / P95 ms | 最大 CPU 区间 ms（含首尾截断） |
|---|---:|---:|---:|---:|
| 进度动画空闲 | 301.80 | 76.61 | 3.61 / 8.51 | 8.51 |
| 进度文案切换 | 303.67 | 82.42 | 2.96 / 4.42 | 36.87 |
| 流式尾行空闲 | 309.40 | 82.48 | 3.67 / 9.41 | 9.41 |
| 单字更新 | 307.30 | 104.17 | 4.04 / 6.48 | 33.22 |
| 换行 chunk | 305.81 | 212.60 | 11.20 / 17.47 | 34.29 |
| 工具事件 | 302.48 | 115.06 | 2.79 / 6.75 | 74.60 |

这些是带插桩的单次窗口，不能把窗口 CPU 全归于该事件：动画和应用其他主线程工作仍在运行。空闲窗口就是对此的对照。全部逐帧原始值、时间戳、首尾标记在 raw JSON 的 `frames` 内。

首轮 `fanout-03` 预热仅 3s，初始化没有收敛：其空闲窗口也有历史 Markdown/Message 更新，添加 live tail 后空闲与单字窗口都出现 95 行外壳重算。它保留为原始证据，但不用于稳定事件归因。随后延长预热并增加深层 body ID 与判等失败计数，消除了把初始化活动误归因于 token 的问题。

**方法调用为零不代表 SwiftUI 内部依赖图工作为零。** 95 条历史行仍参加判等；框架可以检查缓存、传播 dirty、遍历布局依赖，而不进入这些行的 body 或自定义 Layout 方法。Time Profiler 无法把这部分内部遍历精确分配到每个历史消息 ID，本报告不虚构该数字。

## 完整回放与 Instruments 热点

`profile-replay.xcresult` 通过；Time Profiler trace 录于 2026-11-06 07:28:01.790–07:28:42.547 +08:00。分析窗口根据测试写入的 epoch 时间与 trace start-date 对齐。

| 阶段 | wall s | 主线程 CPU s | CPU 占用 | 最大显示帧间隔 ms | >50ms 间隔数 |
|---|---:|---:|---:|---:|---:|
| 进度动画运行 | 5.004 | 1.248 | 24.94% | 16.67 | 0 |
| 进度装饰动画暂停（诊断对照） | 5.011 | 0.786 | 15.69% | 16.67 | 0 |
| 24 工具与流式文本 | 24.729 | 20.174 | 81.58% | 1050.88 | 70 |

动画暂停仅为既有回放的诊断对照，没有修改产品的动画行为。完整阶段的 589 个完整 CADisplayLink CPU 区间中，P50 约 6.16ms，P95 约 79.62ms，最大约 1051.42ms。CPU 区间与 display-link timestamp 间隔不是同一个指标，数值可略有差别。

工具与流式窗口在 trace 相对时间 14.545688–39.274969s，主线程采样权重 20,149ms（1ms 采样）。含 `AG::Graph::UpdateStack::update` 或 `GraphHost.flushTransactions` 的样本共 17,455ms，86.63%。以下列出排除 XCTest/RunLoop 外壳后的三个主要应用调用栈；均为**包含子调用**的权重，彼此可能重叠，不能相加。

1. **行布局测量：4589ms，22.78%。** `ChatTimelineRowLayout.sizeThatFits → LayoutSubview.sizeThatFits → LayoutEngineBox / StackLayout / FrameLayout 的尺寸与对齐计算`。稳定单字只涉及当前 1 行，却在约 300ms 内实际测量 21 次；换行 chunk 为 81 次。这支持继续检查当前行的高度/布局传播。完整场景包括新工具行、段落、表格和结束转换，不能把所有这 4589ms 都归给单字窗口，或宣称其中历史行占比已单独测得。
2. **历史在内的行判等：2199ms，10.91%。** `AGDispatchEquatable → NativeTimelineMessageBubble.== → _stringCompareSlow → _StringGutsSlice._slowCompare → Unicode NFC/NFD → _CFStringCheckAndGetCharacterAtIndex`。与单次更新产生 569 次历史判等直接对应，说明“body 被挡住”仍有成本。
3. **Markdown 内联文本构建：832ms，4.13%。** `AmberMarkdownView.renderTableCell → buildInlineText → buildInlineAttrString → sliceSource → String.UTF8View.index(offsetBy:) → foreign String / CFString 字符访问`。稳定探针中历史 Markdown body 为零，当前尾行 Markdown 随吐字变化；完整回放确实包含表格单元格构建。这个采样是渲染/切片成本，不是持久化或网络请求成本。

对第二项进一步做了源码地址定位。trace 与本地 `iosApp.debug.dylib` UUID 同为 `5EEF0EF8-5914-37C6-BE72-753CD8093899`。`atos` 将地址 `0x1163c7357` 定位到 `ChatTimelineRows.swift:133`：

```swift
lhs.generativeUiSettingSignature == rhs.generativeUiSettingSignature
```

该地址累计 1,899 个样本，约占判等栈的 86.36%、主线程窗口的 9.42%。对应值每次在 `NativeChatTimelineView.swift:170` 由 `String(describing: generativeUiSetting)` 构造。profile 可直接看到 Foundation/foreign String 的 Unicode 慢比较；不需要假设历史消息内容变了，也不需要先重写列表才能处理这个确定成本。

应用符号可解析，关键判等地址已核对到源码行。系统框架存在 `<deduplicated_symbol>` 和少量地址符号，所以不把系统内部匿名帧命名为具体业务原因。禁用计数时 `ChatRenderProbe.record` 出现在 16ms 的样本中，约 0.08%；这不是所有插桩开销的精确上界。原始 trace 有一条 instrument table 缺少输入源的 warning；time-profile 表正常导出，采样权重与独立线程 CPU 读数接近。

## 扩散源与证据边界

- **单字/工具事件的回放直接驱动源**是 `HarnessModel.signal`（`@Published`）；`Harness.body` 读取 signal，传给 `NativeChatTimelineView`。messages 在该测试模型中是普通数组，不能把测试结果误说成直接测得生产 `@Observable messages` 的全部通知。
- **生产对应路径**已从代码核实：`ChatTimelineSignalHost.body` 读取 `ChatViewModel.messageUpdateSignal`；`ChatView.messageList` 传入 `{ viewModel.messages }`；时间线根 body 调用它。`ChatViewModel.messages` 转发到 `@Observable ChatConversationRunState.messages`。因此根时间线仍是原始消息集合/信号的观察和投影入口。全历史参与判等在回放中已有计数证据。
- **当前回复的局部源**是 `ChatLiveTailModel.objectWillChange`，由 `ChatLiveTailBubble.@ObservedObject` 消费；随后 `ChatStreamingRevealPacer` 的 `@State revealedUTF16Count/contentHeight/displayedHeight` 推进文字和高度。单字/换行探针中的局部 body 与多次布局调用对应这条链。
- **进度源**在回放中是 `HarnessModel.activity`（`@Published`），生产中来自 `currentTimelineActivity`，读取 focused task 和屏幕信号。文案变化作为整个时间线的输入，导致时间线 body 与历史判等。进度行自己的 `now` 时钟已经被限制在局部；没有证据支持再把它认定为每帧全量 body 重算源。
- 本轮没有观察到某个环境值变化绕过 Equatable 导致稳定历史全量 body 失效；不能凭环境注入的存在认定它有错。`generativeUiSettingSignature` 是普通比较输入，不是环境广播。
- 本回放未挂载完整 ChatView shell、真实 provider、存储/网络发布或真机 120Hz 路径。父级 chrome、真实异步 task slot 的通知是否额外扩散，仍需在那条路径采样。这里的结论只能落到本次生产时间线入口和明确的代码对应关系。

建议协调者与结构设计结果合并时，优先处理已定位的设置签名慢比较，再验证当前流式行的重复测量与 Markdown foreign-string 切片；同时收窄 timeline 的高频投影/判等边界。不要以本轮证据宣布必须更换整个列表实现，也不要再追加只针对历史行 body 的补丁。最终优化仍须用相同测量窗口做前后比较，并单独进行真机验收。

## 可复现命令与证据

以下命令在当前 worktree 根执行。私有输入留在 ignored `iosApp/build/StreamingPerfEvidence/`，不提交、不上传。需要本项目既有的 Python.xcframework 及其配套 receipt、KMP 构建依赖；这轮使用原交接工作树相同制品，并保留正常校验。

```sh
xcodegen generate --spec iosApp/project.yml
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0' \
  -derivedDataPath iosApp/build/StreamingPerfBaseline -parallel-testing-enabled NO \
  -only-testing:iosAppTests/ChatSearchCaptureReplayTests/testCapturedInvalidationFanout \
  -resultBundlePath iosApp/build/StreamingPerfEvidence/NEW-fanout.xcresult test
python3 iosApp/scripts/perf/summarize-fanout.py \
  iosApp/build/StreamingPerfEvidence/invalidation-fanout.json
```

完整回放将 `-only-testing` 替换为 `iosAppTests/ChatSearchCaptureReplayTests/testCapturedSearchProgressAndStream`。已有本轮测试构建时使用 `test-without-building`。每轮输出后立即将 `invalidation-fanout.json` 或 `captured-replay-metrics.json` 复制为独立文件，避免下一轮覆盖。

本轮自动附加采样的实际命令、PID 与退出码保存在 `profile-replay-invocation.json`；附加脚本为证据目录内 `profile-replay.py`。等测试 host 启动后，等效 Instruments 命令为：

```sh
xcrun xctrace record --template 'Time Profiler' \
  --device F3D5299E-EEA6-4098-BF61-AB1C516933C0 --attach <当前测试host的PID> \
  --time-limit 90s --output iosApp/build/StreamingPerfEvidence/NEW-search.trace
# 测试进程退出时结束采样，保留完整 trace。
xcrun xctrace export --input iosApp/build/StreamingPerfEvidence/search-replay.trace \
  --toc --output iosApp/build/StreamingPerfEvidence/search-replay-toc.xml
xcrun xctrace export --input iosApp/build/StreamingPerfEvidence/search-replay.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output iosApp/build/StreamingPerfEvidence/search-time-profile.xml
python3 iosApp/scripts/perf/analyze-captured-replay.py \
  iosApp/build/StreamingPerfEvidence/search-time-profile.xml \
  iosApp/build/StreamingPerfEvidence/search-replay-toc.xml \
  iosApp/build/StreamingPerfEvidence/profile-replay-metrics.json
```

源码地址确认（仅对本次 UUID 匹配的二进制有效）：

```sh
xcrun atos -arch arm64 \
  -o iosApp/build/StreamingPerfBaseline/Build/Products/Debug-iphonesimulator/iosApp.app/iosApp.debug.dylib \
  -l 0x11556c000 0x1163c7357
```

证据目录：`iosApp/build/StreamingPerfEvidence/`。

- `fanout-06-raw.json`、`fanout-06-summary.json`：最终单事件数据；`fanout-03/04/05-raw.json` 保留演进与初始化干扰证据。
- `profile-replay-metrics.json`：完整回放的三个阶段及逐帧 CPU。
- `search-replay.trace`、`search-time-profile.xml`、`search-profile-summary.json`、`search-profile-stacks.json`：原始采样、加权汇总与代表调用栈。
- `equality-addresses.json`、`equality-source-lines.txt`：判等地址采样计数与源码定位。
- `fanout-06.xcresult`、`profile-replay.xcresult` 以及两个 `*-test-summary.json`：两个目标测量用例均 Passed，最终断言包括输入/挂载、真实 bottom-follow 和完整 source 文本。通过只表示测量路径与这些断言成立，绝不表示性能达标。

首次两次构建因新工作树缺少配套 Python receipt 而在测试前停止；补齐后构建和测量通过，没有绕过校验。只跑本阶段必要的定点测量，没有重跑聊天全量套件；本轮只改诊断插桩，项目六组行为回归和真机体验验收仍属于后续产品改造阶段。

收尾审查只补了消息 ID 计数语句的 `#if DEBUG` 包围，避免 Release 求值该诊断参数；DEBUG 执行语句未改变，复用上述运行证据，并分别通过 DEBUG / 非 DEBUG 语法解析。两个分析脚本通过语法与真实证据一致性检查。
