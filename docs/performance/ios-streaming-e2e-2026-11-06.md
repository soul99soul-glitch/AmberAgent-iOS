# iOS 流式回放：端到端、内存与连续三轮补测

接续 [失效范围与 Instruments 报告](ios-streaming-fanout-2026-11-06.md) 和提交 `fc383529`，本轮只增加测试侧测量，没有改产品逻辑。三轮均完成前台吐字与真实贴底检查，测量用例 Passed；性能仍然较差，不能将测试通过当作性能验收通过。

**同进程连续三轮总耗时为 32.88 / 27.75 / 34.89 秒，主线程占用为 69.03% / 67.72% / 69.79%。未观察到随轮数单调恶化，但波动明显，每轮仍有数十个超过 50ms 的显示间隔。** 回放源关闭到最后文字实际可见仍相差 0.60–6.21 秒；只测源关闭会漏掉实质等待。

## 起止点与范围

- 环境仍为 Xcode 27.2 / 27B52、arm64 Debug、iPhone 17 Pro 模拟器、iOS 26.5 / 23F77。三轮 PID 都为 `96980`，未重启进程、未清理缓存。每轮新建同样的时间线，从同一份历史重新开始，不把上一轮消息累加到下一轮。
- 输入仍是同一份 127 条记录的私有捕获，前 111 条为历史；本次完整场景含 **两个用户回合、24 个工具 part**。第一个回合是搜索及 2404 UTF-16 单元的最终答复；第二个回合是后续请求及 3535 UTF-16 单元的答复。初始历史加载、解码、6 秒预热在计时外，发送后的更新、字符串构造、工具回放、Markdown、前台排空及贴底全部计入。
- 起点在第一条用户消息进入生产时间线前。工具按 150ms 间隔回放，文字按 24 字符 / 30ms 输入；事件泵被主线程工作阻塞时，其延迟留在总耗时里。没有用理论输入时间替代实际 wall time。
- 每个回合用生产 `ChatCompletionFeedback` 收到完整文本的解析/排空确认，再检查实际 `ParagraphUIView` 已包含结尾文字、末尾 caret 位于可见视口内。随后要求真实 `UIScrollView` 距离底部不超过 1pt，offset / contentSize / viewport 连续 1 秒稳定（单次变化不超过 0.5pt）。不写滚动偏移，不强迫贴底，也不以固定等候时间冒充完成信号。
- 表中的“贴底停稳”包含这 1 秒确认窗口；两个回合各确认一次。完整场景总时长包含两次确认。最后字可见时间另列，便于区分渲染耗时和确认窗口。
- **这是生产时间线入口的 UI 端到端回放，不是从真实输入框到 provider、网络、存储再返回的全 App 端到端。** 网络等待按固定节奏替代；本轮未测全 App shell、真实 provider 或物理设备。回放源关闭是测试发送 `generationCompleted` 的时刻，不是实测服务器结束时间。
- 新夹具以正常 `initialLoad` 加载历史，采用默认窗口；此前单事件探针的挂载状态与新窗口不同。旧报告的 24.729 秒还排除了前台排空，不能拿新旧 CPU 占比或时长直接做优化前后比较。本轮没有实施优化。

## 三轮完整场景

| 轮次 | 发送至最终停稳 s | 主线程 CPU s / 占用 | 全进程 CPU s | >50ms 间隔数（每秒） | >100ms 间隔数 | 最长显示间隔 ms |
|---|---:|---:|---:|---:|---:|---:|
| 1 | 32.877 | 22.695 / 69.03% | 25.714 | 45（1.37） | 26 | 666.85 |
| 2 | 27.749 | 18.793 / 67.72% | 19.804 | 38（1.37） | 20 | 788.74 |
| 3 | 34.890 | 24.349 / 69.79% | 26.966 | 41（1.18） | 26 | 749.61 |

全进程 CPU 使用 `getrusage(RUSAGE_SELF)` 的 user + system；主线程 CPU 使用 `CLOCK_THREAD_CPUTIME_ID`。因此后台线程的 CPU 工作没有被忽略，但这些数值不包含 GPU 时间。显示间隔来自 CADisplayLink，不将阈值计数冒称 Instruments 的正式 hitch 指标。

| 轮次 | 完整显示回调区间数 | 区间主线程 CPU P50 ms | P95 ms | 最大 ms |
|---|---:|---:|---:|---:|
| 1 | 1336 | 8.37 | 33.49 | 540.17 |
| 2 | 1108 | 7.98 | 35.48 | 614.88 |
| 3 | 1392 | 8.54 | 32.74 | 617.84 |

P50/P95 采用 nearest-rank，排除首尾截断区间。上表是回调间实际主线程 CPU，上一表是显示时间戳间隔，两者含义不同。原始 JSON 保留每个 CPU 区间的 wall / CPU / uptime 与首尾标记。

## 每个用户回合的可见完成

各列从该回合用户消息进入时间线前计时。

| 轮次 / 回合 | 回放源关闭 s | 最后文字可见 s | 贴底停稳 s | 源关闭后仍需等待可见 s |
|---|---:|---:|---:|---:|
| 1 / 搜索 | 13.843 | 17.460 | 18.512 | 3.617 |
| 1 / 后续请求 | 8.038 | 13.318 | 14.364 | 5.280 |
| 2 / 搜索 | 13.241 | 16.751 | 17.758 | 3.510 |
| 2 / 后续请求 | 8.393 | 8.990 | 9.990 | 0.597 |
| 3 / 搜索 | 13.723 | 17.305 | 18.355 | 3.583 |
| 3 / 后续请求 | 9.280 | 15.494 | 16.535 | 6.215 |

搜索回合的排空延迟约 3.5–3.6 秒，三轮接近；后续长答复为 0.6–6.2 秒，波动是总耗时差异的重要组成部分。这是观测相关性，尚未单独确定波动由哪一个调度/缓存环节造成，不能据此断言第三轮出现泄漏或热降频。

## 内存

独立 utility 队列每 10ms 读取 `TASK_VM_INFO`，避免主线程卡住时采样也完全停顿。每轮分别取得 3290 / 2777 / 3491 次样本，读取失败均为 0。以下均为 **MiB（1024² 字节）**，是整个测试宿主进程的内存，包括 KMP、测试和 UI，不是某个视图的独占大小。

| 轮次 | 预热后 footprint | 本轮采样峰值 footprint | 本轮采样峰值 RSS | 结束 footprint | 拆除夹具后 1s footprint |
|---|---:|---:|---:|---:|---:|
| 1 | 187.85 | 321.46 | 956.06 | 242.00 | 144.39 |
| 2 | 201.38 | 290.32 | 888.59 | 235.67 | 142.96 |
| 3 | 201.27 | 286.63 | 918.12 | 241.16 | 145.32 |

内核的**进程生命周期** footprint 高水位在第 1 轮从 236.67 增至 322.58 MiB，后两轮仍为 322.58 MiB。它无法按轮重置，所以不伪称是每轮精确峰值。第 1 轮内核峰值比采样峰值高约 1.13 MiB，证明 10ms 采样可能漏过短尖峰；每轮列应按“采样峰值”解释。RSS 与 footprint 计量不同，不能相减推断泄漏。

三轮中 footprint 峰值未逐轮上升，拆除夹具后的读数在约 143–145 MiB。这个短序列没有显示持续累积，不能代替长时泄漏验证。模拟器数据也不能推断真机内存压力或热管理效果。

## 复现与证据

在当前 worktree 根执行，复用已有 Python / KMP 配套构建制品。输入仅保留在 ignored 的本机证据目录；不得提交或上传私有捕获。

```sh
xcodegen generate --spec iosApp/project.yml
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0' \
  -derivedDataPath iosApp/build/StreamingPerfBaseline -parallel-testing-enabled NO \
  -only-testing:iosAppTests/ChatSearchEndToEndReplayTests/testThreeConsecutiveCapturedRoundsThroughVisibleCompletion \
  -resultBundlePath iosApp/build/StreamingPerfEvidence/NEW-e2e.xcresult test
python3 iosApp/scripts/perf/summarize-e2e-replay.py \
  iosApp/build/StreamingPerfEvidence/end-to-end-three-rounds.json
```

用例一次启动后连续跑三轮，不要拆成三次 xcodebuild。输出文件每轮更新，完成后应另存为唯一名称再开始下一次比较。本轮归档：

- `iosApp/build/StreamingPerfEvidence/e2e-three-rounds-02-raw.json`：三轮全部原始数据，包括逐帧 CPU 和每个回合的排空确认。
- `e2e-three-rounds-02-summary.json`：由上述脚本生成，分位数、MiB 和延迟均可重新计算。
- `e2e-three-rounds-02.xcresult`、`e2e-three-rounds-02-test-summary.json`：1 个定点用例 Passed、0 failed、0 skipped；实际断言覆盖两回合完整源文本、前台可见完成和真实 bottom settling。
- raw SHA256：`356c30bf7f90c3dae2b69fecbc20d7f2c868f8e2e9662e58112d474ed483889d`。
- input SHA256：`f4aa21b6a29081d14b0d543086c40d304e9848baf3369b3d6cc9c471cf119d96`，与前一报告一致。

首次构建因锁闭包返回非 Sendable 字典而停止；改为在锁内读取 Sendable 快照、锁外组装 JSON 后构建和定点测量通过。收尾仅检查本次测试侧 diff，并验证摘要脚本与三轮原始值一致。没有重跑全量套件、推送或安装真机。

后续产品改造应同时复用这份端到端窗口和前一报告的单事件/Time Profiler 证据：分别判断局部 CPU、整个可见流程、进程 CPU 与峰值内存，保留相同输入节奏与完成条件，不能用缩短前台排空或省掉贴底确认制造“变快”。
