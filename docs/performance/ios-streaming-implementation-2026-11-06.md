# iOS 流式结构优化实施记录

基线 `bfe85cc3`；方案来源为 Opus 的 `docs/perf/structural-plan.md` 第 0、4 节。只在当前分支实现、逐步提交，不推送、不装真机，完成后交给 Opus review。

顺序：P0+P3 设置整数签名/Markdown 连续 UTF-8 → P1 渲染层高度过渡 → P2 尾行独立发布 → P4 历史分块；P5 只在此前结果不达标且有证据时处理 S4/S5/S6。S7/S8 和按真实时间计算吐字节拍不做。

验收复用原两组回放，输入、吐字节奏、末字可见及连续 1 秒贴底条件不变。主线程 <50%、最长显示间隔 <100ms、>50ms 间隔 ≤3、总时长不超过基线且三轮波动 <2s；同时记录全进程 CPU、内存、排空延迟与历史/尾行扇出。模拟器通过不替代真机手感验收。六组行为测试仅最终运行一次。

| 阶段 | 提交 | 三轮总时长 s | 主线程 % | 最长显示间隔 ms | >50ms 次数 | footprint 峰值 MiB |
|---|---|---|---|---|---|---|
| 基线 | bfe85cc3 | 32.88 / 27.75 / 34.89 | 69.03 / 67.72 / 69.79 | 667 / 789 / 750 | 45 / 38 / 41 | 321 / 290 / 287 |

P0+P3：设置签名按不可变 KMP 对象引用缓存为 Int，行比较和投影结构 key 不再比较大段描述字符串；renderStateRevision 独立纳入 digest。Markdown AST 缓存同时保留连续 UTF-8 源，切片与表格哈希复用该源，独立数学公式入口也保证连续存储。[Swift 连续 UTF-8 的复杂度说明](https://developer.apple.com/documentation/swift/string/iscontiguousutf8)。

定点验证 `p03-focused-03.xcresult`：102 通过、3 失败。只将这 3 项在未改的 `bfe85cc3` 产品源码上复跑，`p03-baseline-failures-02.xcresult` 同样失败，失败集合一致；没有删减断言。涉及既有表格源码断言、工具结果变为纯状态行后的全量投影、工具轮续答标识。不是全绿，当前未新增失败。

安装授权已更新：P0+P3 与最终版各通过 iosAppExperimentalGPL / app.amber.ios 保数据覆盖指定 iPhone 18 Pro，允许无线，锁屏/不可达时停止安装并回报。基线包含 `46071c9b` 的设置开关与前台排空后震动修复；本阶段未改这条链路。

每个阶段提交后运行 `bash iosApp/scripts/perf/run-structural-phase.sh <唯一阶段名>`，归档同场景数据。最后一次运行六组行为回归。
