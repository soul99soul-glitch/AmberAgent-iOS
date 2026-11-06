# iOS 21:15 真机卡顿：贴底策略重建与进度动效

基线 `1d4ccda3`，包含办公机新增的41e33cce、c01407eb、fb78ace7及黑匣子插桩。原始日志、实际对话及回放输入保留在 ignored 的 `iosApp/build/StreamingPerfEvidence/evening-2115/`，没有提交或上传私有对话。

## 真机证据

从指定 iPhone 18 Pro 的 Documents/amber-perf-live.jsonl 取回314行，覆盖北京时间21:15:30.362–21:17:06.431，包含89个摘要窗口和224个异常区间。实际消息时间确认本轮用户消息始于21:15:37，最后结果于21:16:24落盘。日志的startup.commit是源码写死的fb78ace7，不能作为实际安装SHA证明。

| 阶段（摘要窗口边界） | 主线程CPU | 最长间隔ms | >50ms帧 |
|---|---:|---:|---:|
| 任务启动候选 21:15:37.011–39.161 | 73.52% | 414.27 | 8 |
| 工具与间歇输出 21:15:39.161–21:16:16.851 | 41.13% | 267.05 | 55 |
| 集中正文流式 21:16:16.851–23.920 | 83.29% | 131.45 | 5 |
| 终态与收尾 21:16:23.920–27.374 | 61.25% | 483.79 | 9 |
| 完成后的交互候选 21:16:27.374–40.660 | 52.58% | 1615.01 | 11 |
| 随后空闲 21:16:40.660–56.679 | 0.67% | 26.89 | 0 |

日志没有发送、键盘或切页动作标记，边界由计数变化与消息时间推断；摘要P50/P95不能平均成全段分位数。完整分布、计数与异常区间见本机flight-analysis.json及analyze-flight.py。

21:16:39.658的最长区间主线程CPU1494.68ms，message/markdown各54次、实测324次，尾行更新、流式解析调度、pacer及growth计数均为0。初次模拟器符号化Time Profiler中，视口变化区间37.38%的主线程样本包含ChatTimelineRowLayout.sizeThatFits；其下还包含ParagraphView.makeUIView及静态Markdown构造。初次采样的历史窗偏大，仅用于定位链路；最终对照已纠正为生产初始60条历史窗口。

用户随后通过USB完成滚动、键盘与切页操作。22:13:40后的记录出现235.11ms和324.03ms异常区间，分别重新渲染44行、测量270/276次；208.37ms区间只有布局遍历。物理设备Time Profiler的按PID/名称attach失败，全进程录制也断连，没有取得真机CPU调用栈。这里没有把计数共现当作最终归因。

## 已证实的原因与修复

### 贴底开关改变了整个滚动视图的身份

ChatSizeChangesPinModifier原先用if/else包裹content。跟随策略变化时，条件分支替换了UIScrollView及其已挂载历史，测量缓存和Markdown视图随之重建。

最初身份诊断用例在原实现上真实失败：切换跟随策略后，fixture.scrollView不再是原对象。最终回归testViewportResizePreservesMountedScrollViewAndHistory直接模拟4次视口变化，要求保持同一UIScrollView且历史行body为0。普通跟随对话让结构始终为defaultScrollAnchor(enabled ? .bottom : nil, for: .sizeChanges)，只更新锚定值。

显式messageAnchor定位和关闭跟随的模式保留原分支：直接把无条件修饰符推广到这些模式，会使图片内部精确锚点用例退回底部；旧分支对照通过，收窄应用范围后的图片定位及视口身份两项均通过。没有修改图片定位流程或增加重试。[Apple的按角色设置滚动锚点接口](https://developer.apple.com/documentation/swiftui/view/defaultscrollanchor(_:for:))分别控制初始位置、尺寸变化和小内容对齐，不能仅凭接口形状假定不同路径行为等价。

### 进度动画每拍更新SwiftUI子树

三点波浪和文字扫光原先各使用30Hz TimelineView。改由独立Core Animation图层驱动，沿用原waveMetrics、点径/间距、相位、透明度、缩放和1.8秒扫光周期；模态覆盖暂停图层时钟，Reduce Motion与固定时间快照继续使用原静态路径。没有改变文字吐出节拍。

## 相同输入的分步对照

iPhone 17 Pro模拟器/iOS26.5/Debug，真实晚间对话146条消息作为输入，初始只挂载尾部60条。视口600/852pt交替4次，输入、等待与测量方式一致。手机为iOS27.2，模拟器数值不等于真机体验。

| 版本 | 视口变化主线程CPU | 最大间隔ms | 历史行body | 实测次数 |
|---|---:|---:|---:|---:|
| 基线，correct-window-before | 46.39% | 583.11 | 175 | 352 |
| 仅进度CA，layers-after | 47.32% | 571.02 | 175 | 352 |
| CA+稳定滚动身份，pin-identity-after | 22.79% | 61.42 | 0 | 0 |

进度动效用live/paused/live夹测：基线CPU为26.87/12.32/25.22%，仅CA后为18.83/17.14/19.95%；最终为12.58/13.71/13.24%，最终没有观察到高于暂停态的稳定CPU增量。测试App自身存在基础动画，绝对CPU数值含该背景成本，不以它宣称整机收益百分比。

收窄视口hash/读取的实验无收益，已撤回。保留行尺寸缓存的实验仍有831ms长帧并引入20pt高度误差，也已撤回。最终不包含这两个实验或相关探针开关。

实际晚间单轮回放从发送至最后字可见且贴底稳定1秒共13.294秒；源关闭6.328秒、最后字可见12.255秒。峰值footprint约241.4MiB，主线程59.52%，最长间隔328.09ms，>50ms共6次。因此本轮没有宣称整体流式性能已达标，也没有用减少吐字或省略贴底条件换数字。

## 验证与复现

定点包pin-identity-after.xcresult覆盖稳定滚动身份、图层几何/暂停、同输入动效/视口对照，以及实际晚间单轮前台排空和贴底。受影响六组、pacer、完成反馈、原生进度形象及扇出统一运行一次；定位接缝收窄后只复跑受影响的历史、完成、流式UI三组与新定点。结果保留在final-regression.xcresult、scoped-pin-after.xcresult、final-scoped-ui.xcresult与交付清单。未再跑三轮e2e；正常回放无messageAnchor，收窄分支不改变该已验证路径。

复现命令（需本机私有输入，未配置时诊断用例跳过）：

```sh
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0' \
  -derivedDataPath iosApp/build/StreamingPerfBaseline -parallel-testing-enabled NO \
  -only-testing:iosAppTests/ChatTimelineAnimationIsolationTests \
  -only-testing:iosAppTests/ChatSearchEndToEndReplayTests/testEveningCapturedRoundThroughVisibleCompletion test
```

手机安装及发布结果以云端daily/2026-11-06-ios-streaming-perf.md最新晚间交付节与本机evening-2115交付清单为准。完成震动修复、匀速吐字与Liquid Glass代码均保留；真机最终手感仍需单独核对。
