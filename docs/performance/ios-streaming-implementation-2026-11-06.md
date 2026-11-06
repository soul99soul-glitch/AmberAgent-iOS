# iOS 流式结构优化实施记录

基线 `bfe85cc3`；方案来源为 Opus 的 `docs/perf/structural-plan.md` 第 0、4 节。只在当前分支实现、逐步提交，不推送。按最新授权，P0+P3 和最终版各保数据装机，review 并行。

顺序：P0+P3 设置整数签名/Markdown 连续 UTF-8 → P1 渲染层高度过渡 → P2 尾行独立发布 → P4 历史分块；P5 只在此前结果不达标且有证据时处理 S4/S5/S6。S7/S8 和按真实时间计算吐字节拍不做。

验收复用原两组回放，输入、吐字节奏、末字可见及连续 1 秒贴底条件不变。主线程 <50%、最长显示间隔 <100ms、>50ms 间隔 ≤3、总时长不超过基线且三轮波动 <2s；同时记录全进程 CPU、内存、排空延迟与历史/尾行扇出。模拟器通过不替代真机手感验收。六组行为测试仅最终运行一次。

| 阶段 | 提交 | 三轮总时长 s | 主线程 % | 最长显示间隔 ms | >50ms 次数 | footprint 峰值 MiB |
|---|---|---|---|---|---|---|
| 基线 | bfe85cc3 | 32.88 / 27.75 / 34.89 | 69.03 / 67.72 / 69.79 | 667 / 789 / 750 | 45 / 38 / 41 | 321 / 290 / 287 |

P0+P3：设置签名按不可变 KMP 对象引用缓存为 Int，行比较和投影结构 key 不再比较大段描述字符串；renderStateRevision 独立纳入 digest。Markdown AST 缓存同时保留连续 UTF-8 源，切片与表格哈希复用该源，独立数学公式入口也保证连续存储。[Swift 连续 UTF-8 的复杂度说明](https://developer.apple.com/documentation/swift/string/iscontiguousutf8)。

定点验证 `p03-focused-03.xcresult`：102 通过、3 失败。只将这 3 项在未改的 `bfe85cc3` 产品源码上复跑，`p03-baseline-failures-02.xcresult` 同样失败，失败集合一致；没有删减断言。涉及既有表格源码断言、工具结果变为纯状态行后的全量投影、工具轮续答标识。不是全绿，当前未新增失败。

安装授权已更新：P0+P3 与最终版各通过 iosAppExperimentalGPL / app.amber.ios 保数据覆盖指定 iPhone 18 Pro，允许无线，锁屏/不可达时停止安装并回报。基线包含 `46071c9b` 的设置开关与前台排空后震动修复；本阶段未改这条链路。

按 09:00 最新提速要求：P1/P2/P4 每步仅快速 fanout；全部完成后统一三轮 e2e 与六组行为回归。P0+P3 不追加三轮回放。

P0+P3 已于 09:04 无线覆盖并成功启动：`edde3c5c23c941438c1ec8c6afa02632744634a0`，databaseSequenceNumber **2736**。签名及安装证据为本地 `p03-device-manifest.json`、`p03-device-install.json`、`p03-device-launch.json`。

| 定点阶段 | token 历史判等 / timeline body | 工具历史判等 | 进度历史判等 | 当前行测量：单字 / 换行 | token窗口主线程 CPU ms |
|---|---|---|---|---|---|
| 基线 | 569 / 1 | 1138 | 569 | 21 / 81 | 见 fanout-06 |
| P1 `5a505c13` | 569 / 1 | 1138 | 569 | 20 / 63 | 145.93 |
| P2 `e8714fa1` | 0 / 0 | 1138 | 569 | 24 / 85 | 94.85 |
| P4 | 0 / 0 | 12（另28次块比较） | 6（另14次块比较） | 23 / 86 | 87.36 |

三类事件的历史行 body / sizeThatFits / placeSubviews 始终为 0。P2 阻断了 token 到时间线的广播；P4 把结构事件限制在受影响的块。P1 当前行测量目标尚未达到；3 次自然高度变化仍对应 86 次测量，不能把 body 隔离误报为布局已解决。所有计数保留在 `p1/p2/p4-fanout-raw.json` 与相应 xcresult。

## 整轮结果与验收边界

同一输入、同一 24 字/30ms 源回放、相同前台 pacer、两轮回复各等到末字可见且贴底连续稳定 1 秒。下表不是固定时长截断的 CPU 抽样。

| 阶段 / 轮次 | 总时长 s | 主线程 % | 全进程 CPU s | >50ms 帧 | 最长帧间隔 ms | 峰值 footprint MiB |
|---|---:|---:|---:|---:|---:|---:|
| p4-final / 1 | 26.108 | 55.29 | 17.476 | 8 | 233.1 | 291.25 |
| p4-final / 2 | 25.970 | 55.53 | 16.915 | 6 | 233.5 | 287.80 |
| p4-final / 3 | 25.900 | 55.63 | 16.906 | 6 | 211.9 | 286.25 |
| p5-final / 1 | 28.212 | 55.07 | 18.735 | 10 | 614.1 | 292.80 |
| p5-final / 2 | 26.001 | 56.07 | 17.048 | 6 | 219.1 | 291.89 |
| p5-final / 3 | 25.844 | 55.63 | 16.876 | 6 | 228.8 | 300.24 |

**尚未达到四项同时通过。** P4 已把总时长稳定到 25.90–26.11 秒，但主线程仍约 55%，最长间隔仍超过 100ms，超过 50ms 的帧仍多于 3 次。P5 没有给出进一步稳定收益，首轮出现 614ms 间隔；不能仅用后两轮掩盖首轮。最终 P5 三轮时长波动 2.37 秒，也未达到 <2 秒目标。

P5 的单字历史判等/body/layout 仍为 0；工具历史判等 12，进度 6。当前行测量单字 23、换行 89，仍高于 ≤3 的目标。自然高度变化仅 3 次，说明布局失效并不全来自高度过渡。代码上可见 `ParagraphUIView.updateTextViewWithCurrentAnimations` 每帧编辑 `textStorage` 的 foregroundColor；这只是后续定位候选，未凭静态阅读宣称它已被运行时证明，更未取消文字淡入来换取数字。

P5 三轮峰值 footprint 292.8 / 291.9 / 300.2 MiB，均低于原上限 321 MiB，未连续递增；拆除后为 151.46 / 149.75 / 151.52 MiB，三轮没有持续累积的证据。第三轮高于第二轮仍如实保留，三轮测试不能证明不存在长期泄漏。

源关闭到末字可见：P4 第一回合 3.18–3.22s、第二回合 4.31–4.39s；P5 第一回合 3.16–3.22s、第二回合 4.21–6.02s。仍保持原速排空，P5 第二回合跨轮波动未达到 <0.5s。

P5 仅处理 S5 的几何回调消息桥接与 S6 的双滚动驱动。S4 未做：回放输入约 33Hz，不满足“显著高于 30Hz”前提；未为此新增排队延迟。成果架/主对话摘要未在此直接 timeline 回放中测为热点，未扩散修改。S7/S8、真实时间补偿吐字、热管理或硬件策略均未实施。

## 复现

```sh
# 私有录制输入仅放在 ignored 的 iosApp/build/StreamingPerfEvidence/replay-input-private.json
bash iosApp/scripts/perf/run-structural-phase.sh <新的唯一阶段名>
# 两个用例：ChatSearchEndToEndReplayTests/testThreeConsecutiveCapturedRoundsThroughVisibleCompletion
#           ChatSearchCaptureReplayTests/testCapturedInvalidationFanout
```

同一模拟器 UDID `F3D5299E-EEA6-4098-BF61-AB1C516933C0`，Debug、并发测试关闭。每个阶段的 `*-head.txt`、`*-e2e-raw.json`、`*-fanout-raw.json`、summary、xcresult 可核对；`p4-final` 对应 `2664cc5b`，`p5-final` 对应 `da8eabfe`。后续 `c7a39e25` 只补活动块对可变 taskSlot.currentRoundAssistantMessageId 的失效，不改变该录制场景（taskSlot 为 nil），复用上述回放结果；回归和签名包使用修正后的 HEAD。

首次量化的三个热点调用栈及扩散源详见 `ios-streaming-fanout-2026-11-06.md`。本轮没有以更多全量采样替代尚未完成的真机视觉验收。

最终定点窗口的逐帧主线程 CPU（300ms 窗口；P50/P95 排除首尾不完整帧，末列保留边界峰值）：

| 事件 | 历史 body / 实测行数 / place 行数 | 帧 CPU P50 ms | P95 ms | 含边界最大 CPU ms |
|---|---|---:|---:|---:|
| progress-change | 0 / 0 / 0 | 4.04 | 5.30 | 23.83 |
| single-token-update | 0 / 0 / 0 | 4.42 | 6.45 | 20.03 |
| single-tool-event | 0 / 0 / 0 | 2.82 | 6.59 | 44.66 |

## 行为回归与包交付

`final-required.xcresult` 为六组回归 + 新接线/震动/通知检查的一次统一运行：125 项中 115 通过、10 失败。其中 9 个在已有基线失败清单；新增的首两行过渡断言以自然 `contentOffset` 的中间值代表视觉动画，而 P1 正是将过渡从布局移到渲染层。

该用例改为采样最后一条稳定历史段落的实际 CALayer presentation 坐标，仍要求至少 2 个中间位置、P95 ≤40ms、最大 ≤80ms，并保留自然 contentSize 和 contentOffset 必须前进的断言。`final-presentation-canary.xcresult` 定点复跑通过；没有删除或放宽行为阈值。相当于 116 项通过、9 项基线失败，不能称为全绿。新增路由/分块 3 项、完成反馈 5 项、通知 13 项均通过。失败集合对比在 `final-required-comparison.json`。

有限维护性检查仅修正了引用回调的清理、独立装饰块 ID 和活动轮次失效；未做第二轮架构审查。最终源码包含 `46071c9b` 震动修复，设置开关与前台排空等待未被修改。

09:32 读取指定设备状态：UDID `00008160-001939111420000A`、paired，但 tunnelState 为 unavailable，ddiServicesAvailable 为 false。按最新授权停止装机尝试，准备签名包；手机当前已安装的仍是 P0+P3 `edde3c5c` / databaseSequenceNumber **2736**，本轮未卸载、清数据或重配对。
