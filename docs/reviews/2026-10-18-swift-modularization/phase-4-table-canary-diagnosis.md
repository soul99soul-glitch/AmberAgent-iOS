# Growing-table DisplayLink canary：只读诊断（2026-10-18）

**判断：当前证据不支持 Phase4 新引入了表格渲染回归；支持既有长表格流式路径在模拟器上的帧调度余量不稳定。** 同一测试源码和表格渲染实现下，Phase3 集成 r10 已有 P95 42.571 ms 的失败，Phase4 Main r3 为 44.721 ms；也有多次通过。两次超阈值都是主 RunLoop 的 DisplayLink 回调间隔超出原定 40 ms 门槛，不能算通过，也不能凭现有数据断言是模拟器调度还是表格布局 CPU 单独造成。未修改源码、测试或阈值；未运行构建、测试或复现。

## 结果和可比性

| 已有结果包 | canary | 单例耗时 | 说明 |
|---|---:|---:|---|
| `/tmp/amber-phase3-baseline.xcresult` | 通过 | 3.637 s | 435 项总运行；此 case 通过 |
| `/tmp/amber-phase3-focused.xcresult` | 通过 | 3.706 s | 3 项定点运行 |
| `/tmp/amber-phase3-integration-r10.xcresult` | **P95 42.571 ms，失败** | 4.716 s | Phase3 已复现超 40 ms |
| `/tmp/amber-phase3-scroll-overlay.xcresult` | 通过 | 3.675 s | scroll 回归运行 |
| `/tmp/amber-phase3-scroll-final.xcresult` | 通过 | 3.634 s | 97 项 scroll 运行 |
| `/tmp/amber-phase4-main-r3.xcresult` | **P95 44.721 ms，失败** | 4.828 s | 1254 项 Main 运行，`-parallel-testing-enabled NO` |

这些数值来自已有 xcresult 的测试树和失败消息。测试中 `print("[PERF-HITCH] ...")` 没有保存在上述结果包的 console log，结果也标记 `hasPerformanceMetrics=false`；因此不能从包内核对采样数、最大间隔、间隔发生在哪一行追加、CPU 占用或表格布局耗时。r10 与 r3 均只有 P95 断言失败；其后最大间隔 80 ms 的断言未报告失败，但无法恢复具体最大值。失败运行整体比通过运行约长 1 秒，这与负载或调度波动相容，不是根因证据。435 项的 baseline 也通过，故不能简单用「套件越大必失败」解释。

## canary 实际测什么

`ChatNativeTimelineReplayPerformanceTests.swift:193-264` 在 393×852 的真实 `UIWindow`／`UIHostingController` 中挂载默认 `NativeChatTimelineView`，先加载 12 轮历史、追加一个 80 行三列表格并泵主 RunLoop 2 秒。随后启动独立的 `DisplayLinkGapProbe`，预热 0.2 秒，按 80 ms 节奏追加 12 行，最后再泵 0.4 秒。`ChatNativeTimelineReplayTestCase.swift:111-132` 的探针把连续 `CADisplayLink.timestamp` 差写入数组；测试丢弃最初两项、升序排序，以 `ceil(0.95×样本数)-1` 取 P95，并要求 P95 ≤40 ms、max ≤80 ms。`pump(seconds:)` (`:449-456`) 通过 `.default` 模式每次最多 10 ms 地运行当前 RunLoop；探针注册在 `.common` 模式。可测到主 RunLoop 回调间隔延长，包括应用主线程工作和模拟器／宿主调度的影响。

这不是 CPU 计时，也不直接记录屏幕完成呈现的时间。测试在初始历史后断言到达底部，但 80 行预热后没有再次断言新行已在 viewport 内；因此它是生产列表实际挂窗、随流式更新的可见响应代理，而不是逐行可见性或 GPU 呈现证明。它没有把新增行的主线程 CPU、布局、后台解析和 RunLoop 调度分开计时。

## 可达生产路径与现存成本

`HarnessModel.send(.streamDelta)` 经 `ChatNativeTimelineReplayTestCase.swift:39-45,54-78` 更新 signal，`NativeChatTimelineView.swift:67-112,122-158` 读取 messages，`NativeTimelineProjectionCache.swift:70-100` 在结构未变时替换 streaming tail，`NativeChatTimelineView.swift:755-779,840-870` 建立消息气泡。`MessageBubbleView.swift:415-430` 对正在生成的最后一条 assistant 文本走 `ChatAssistantMarkdownView`。其 `markdownText`／`markdownFragment` (`ChatAssistantMarkdownView.swift:495-540`) 对流式表格选 `ChatStreamingBlockMarkdownView`，`ChatStreamingMarkdownBlocks.swift:90-186` 将更新放进 single-flight、限频且后台解析的块控制器；表格块进入 `ChatStableStreamingMarkdownView`，其 controller 也在 detached task 中解析/转换 (`ChatStableStreamingMarkdown.swift:265-323`)。随后结果在主 actor 发布，由真实 vendor `DocumentView`／`TableView` 负责展示和布局。

这条路径仍有明确的同步布局压力：`TableView.swift:81-94` 的 3 列 grid 对全部行建视图；`TableLayout.makeCache` (`:442-479`) 对每个单元格做两遍 `sizeThatFits`（先求列宽，再求行高）。约 80-92 行加表头意味着每次完整 cache 测量约 486-558 次单元格尺寸查询。该 Layout 没有自定义 `updateCache`。这是值得进一步测量的**既有**主线程 CPU 候选，当前结果没有证明失败帧确由它造成。`NativeTimelineScrollDriver.swift:244-273` 的跟随动画也有独立主线程 DisplayLink；本测试的探针不区分其回调、Markdown 布局和外部调度。没有证据显示本轮产生了新的 table-only 工作。

## 与本轮改动的关系及决策

按 Swift 解析器声明范围，before 快照 `/tmp/amber-phase3-source-baseline/files/iosApp/iosAppTests/ChatSwiftUIStreamReplayTests.swift:697-768` 与当前 canary `ChatNativeTimelineReplayPerformanceTests.swift:193-264` 的完整方法源码 SHA 均为 `0f04e7a3e7d7e14cf33bffe32327aff5f71d52b977f94e52d2b56258a2694074`。`ChatAssistantMarkdownView` 和 `ChatStableStreamingMarkdownController` 的类型源码 SHA 完全相同；`ChatStreamingBlockMarkdownView`、`ChatStableStreamingMarkdownView` 和 block parser 的差异仅为跨文件后首行移除 `private`；`ChatStreamingMarkdownBlockController` 完全相同。`NativeChatTimelineView` 对比 before 只增加空状态顶部 overlay，并将原 `.emptyState` 行换成 `EmptyView`；本 case 一直有历史/用户/助手消息，空状态分支不可达。vendor `TableView.swift` 相对 HEAD 无改动。因此现有差异不能解释表格 canary 在 Phase4 首次退化，且 Phase3 r10 已独立给出超阈值证据。

对本轮交付应如实记为「长表格性能 canary 在 Main r3 未过；Phase3 曾同类失败，独立/scroll 运行曾通过」，不要放宽 40 ms 或写成环境噪音，也不要把这次失败归为已证实的 Phase4 新回归。若要确认 CPU 与调度份额，下一次应在同一二进制与设备条件下记录每个 probe gap 的时间戳、对应追加序号及主线程表格布局/Markdown 发布耗时，再和定点运行对照；现有 xcresult 没有这些归因字段。
