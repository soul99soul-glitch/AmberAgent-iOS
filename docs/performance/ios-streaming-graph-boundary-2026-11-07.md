# iOS 流式局部图与 TextKit 列宽对照（2026-11-07）

**性能目标尚未达到：整轮主线程 <20%、最长帧间隔 <50ms。此文记录阶段改动与被证伪的假设，不是性能验收通过。** 父基线 d07a3f258fddca5474f109d63736d73f4a651873；本轮无新真机连接、安装、采样或日志导出。最后已验证手机是349128d5/seq2872，含46071c9b震动修复；不据此声称手机当前运行状态已重新核实。

## 保留改动

1. Amber 显式使用的 TextKit1 段落返回完整提议列宽。此前返回 glyph used width，会在下一次全列测量时改变容器宽度并重新排版。默认 TextKit2 行为保持。收尾同场景宽度重排633→约63。
2. 固定列宽、追加后没有换行时只重绘；不因字宽增加通知 intrinsic 尺寸失效。真实定点先红1次、再绿0次；正文内容与实际高度均核对。
3. 已处于原生时间线的流式 Pacer/Markdown 子树放入局部 UIHosting 图；原组件、解析器、环境值、动作与0.14s CA生长继续使用。外层收到自然高度变化；当前挂载子树完成后保留身份，历史冷挂载和非原生路径仍使用原方式。收尾外层测量约500→98，外层 root 更新仅2次；子树内部仍有约31%主线程成本。

16ms吐字节拍、最大每拍4字、收尾不加速、0.14s上移、120Hz动效请求、贴底及既有震动设置逻辑均未改。新文件/修改文件均不超过1500行。

## 同一晚间捕获场景

完整1928 UTF-16正文，计时从发送到末字真实可见并贴底几何稳定1秒；所有数据为Simulator，不能代替真机120Hz验收。

| 形态 | 主线程 | 最长间隔 | 端到端 |
|---|---:|---:|---:|
| 对照基线 |39.75%|184.55ms|13.234s|
| 固定列宽 |37.59%|201.85ms|13.272s|
| 再避免未换行失效 |37.87%|197.44ms|13.297s|
| 再隔离局部图，首次 |33.02%|164.28ms|13.262s|
| 同形态 context.environment 复测 |33.40%|192.20ms|13.183s|

不能选164ms这个最好单值宣称最长帧问题解决；后续对照的最长间隔仍在约176–239ms之间。主线程确有约6个百分点改善，帧间隔没有稳定达到50ms。最终回归与连续轮结果另附证据摘要。

## 已撤回的假设

这些候选均完整恢复，不进入产品：

| 实验 | 主线程 / 最长间隔 | 裁决 |
|---|---|---|
| Kotlin批量metadata快照 |33.58% /207.56ms|JVM1+Swift6通过但无整轮收益，撤回跨语言抽象|
| 解析通知并入下一拍 |34.46% /239.17ms|3项通过但无收益，撤回|
| 每拍游标只由文字切片观察 |34.21% /176.06ms|收尾Pacer body降到5次，CPU未降，撤回|
| 普通文本块消除重复发布 |34.19% /204.27ms|2项通过但无收益，撤回|
| 复用子块吐字路径 |33.19% /197.99ms|3项含智能UI/实际可见坐标通过，收益不足，撤回|
| 临时不显示当前文档稳定前缀 |31.18% /203.17ms|仅诊断：少显示内容仍未达标，不能作交付数字，已恢复|
| 临时关闭原生glyph淡入 |33.27% /226.79ms|仅诊断：不是足够大的头部原因，已恢复动画|
| 临时抑制流式解析发布 |33.64% /205.31ms|仅诊断：不是足够大的头部原因，已恢复最终/空闲通知语义|

更早的 heightTracks、用户追加投影、解析叶观察、pending偏好门控、移除fixedSize、块判等等无收益实验也已撤回。没有放宽失败断言或减少正文换取数字。

## 调用链和证据限制

已符号化的sample中，主要剩余为 SwiftUI AttributeGraph update/propagate_dirty 与布局依赖遍历。正文末尾7秒采样：旧main2362样本，propagate_dirty/UpdateStack自耗181/158；局部图main2208样本，约96/97，Subgraph.update约79。次数下降不能等同于因果已完整裁决，也不能用body计数代替布局计数。

当前Simulator不支持Instruments SwiftUI布局追踪；TimeProfiler有CPU样本但缺image UUID映射，精确dSYM不能匹配，first-party帧仍是原始地址；host直接attach又报告找不到Simulator进程。这些trace不作为有效的已符号化调用链证据。未将旧手机trace、Simulator测试fixture崩溃或旧IPS冒充349之后的新手机CPU/崩溃证据。

原始忽略目录：iosApp/build/StreamingPerfEvidence/promotion-120/。输入正文仅在本机evening-2115/replay-2115-private.json；不进入Git、Library或云端记忆。current-width-drain.sample.txt、current-send.sample.txt、graph-host-drain.sample.txt是当前有效Simulator采样。DIAGNOSTIC文件显式标记非交付；INVALID-stale-copy-plain-block-build-failed.json是编译失败时误复制的旧输出，明确排除。

## 未验证与下一步边界

完整App并发任务/存储/provider负载、真机120Hz手感、关闭完成震动后完全不震、新图边界的实际主题/选择交互和长时内存仍未做真机验收。没有新增手机操作；重新连接仍等明确授权。

后续优先量化Pacer到实际ParagraphUIView更新之间的高频SwiftUI图成本，以及发送时原尾消息26个Markdown正文子树的重建；不会再仅以减少body计数作为采用依据。替换列表、重写解析/存储、削减可见动效或限制子代理数量均不在本轮改动内。目标继续保持未完成。

## 最终有限验证

- 受影响六组及列宽/可见完成：103通过、5既有失败；24KB计时用例此次通过，不把它说成旧计时失败已稳定修复。五个失败为续答间距、胶囊间距、长推理终态、离底解冻、推理收起单调性，均有基线记录；无新增失败、无放宽断言。
- 捕获扇出另1项通过：95条历史行中，单字、单次工具、进度切换、换行增长的历史body/实际测量/placement均0。
- 最终晚间完整场景：13.221s、33.58%主线程、203.96ms最长间隔、>50ms7次/>100ms1次、峰值214.77MiB（与六组共进程，内存不拿来宣称同比收益）。
- 三轮生命周期核对只增加测量字段，没有新增测试断言或改变产品行为；每轮末字实际可见、真实贴底完成。如下是独立进程的三轮同场景，每轮两个用户事项，不能与晚间一个事项的13秒直接比较：

| 轮次 | 主线程 | 最长间隔 | >50/>100ms | 端到端 | 峰值MiB | 退出后MiB | 图创建/释放 |
|---|---:|---:|---:|---:|---:|---:|---:|
|1|38.77%|206.41ms|20/4|24.801s|279.69|143.97|4/4|
|2|35.69%|192.75ms|14/3|24.665s|300.50|171.85|4/4|
|3|37.69%|206.79ms|15/3|24.620s|283.63|182.69|4/4|

CPU/最长间隔没有随轮数单调恶化；每轮局部图4创建/4释放。退出后footprint仍上升，这只排除了局部Controller实例未释放，不能等同于排除所有内存问题或证明峰值下降。前一混合回归进程三轮退出后161.16→166.50→198.24MiB的上升也保留在原始结果中，没有隐去。

原始结果包：followup-bounded-regression.xcresult、followup-fanout-final.xcresult、followup-graph-lifetime.xcresult；对应JSON：e2e-followup-bounded.json、fanout-followup-final.json、three-rounds-graph-lifetime.json。功能用例通过仅确认其原断言，**这些用例没有20%/50ms性能阈值断言，不代表性能验收通过**。

复现：同一Simulator F3D5299E-EEA6-4098-BF61-AB1C516933C0，scheme iosApp，DerivedData iosApp/build/StreamingPerfBaseline，关闭并行测试；选ChatSearchEndToEndReplayTests/testEveningCapturedRoundThroughVisibleCompletion、/testThreeConsecutiveCapturedRoundsThroughVisibleCompletion，以及ChatSearchCaptureReplayTests/testCapturedInvalidationFanout。六组入口沿iosApp/AGENTS.md，已跑一次不再重复。
